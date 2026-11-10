#!/usr/bin/env bash
# bgp-lab12 control script  (rail-optimized AI/HPC fabric)
#
#   ./lab.sh deploy                deploy the working fabric
#   ./lab.sh destroy               tear down
#   ./lab.sh verify                state checks only; observed vs expected
#   ./lab.sh width                 the ECMP width matrix. The core tool.
#   ./lab.sh rail <src> <dst>      is this flow staying on-rail or crossing a spine
#   ./lab.sh sizes <src> <dst>     walk packet sizes to find an MTU ceiling
#   ./lab.sh break                 inject ALL faults at once
#   ./lab.sh break <n>             inject one, for isolated practice
#   ./lab.sh reveal | restore
#   ./lab.sh hint [n]              spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab12; TOPO=bgp-lab12.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(spine1 spine2 rail1 rail2 stor1 gpu1 gpu2 gpu3 nfs1)
NFAULTS=8
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

EP_GPU1=10.10.0.1; EP_GPU2=10.10.0.2; EP_GPU3=10.10.0.3; EP_NFS=10.20.0.1

# installed next hops for a prefix: the number this fabric actually cares about
w() { eos "$1" "show ip route $2" | grep -cE 'via 10\.[12]\.'; }
pingok() { eos "$1" "ping $2 source $3 repeat 3 timeout 1" | grep -qE '[1-9][0-9]* received'; }
ping_t() { if pingok "$2" "$3" "$4"; then ok "$1"; else nok "$1"; fi; }

# expected width, per source and destination
check_w() { # label node prefix expected
  local c; c=$(w "$2" "$3")
  [[ ${c:-0} -eq $4 ]] && ok "$1: ${c:-0}, expected $4" || nok "$1: ${c:-0}, expected $4"
}

verify() {
  echo "== Sessions =="
  for n in spine1 spine2; do b=$(eos $n "show ip bgp summary" | grep -c Estab)
    [[ ${b:-0} -eq 3 ]] && ok "$n Established: ${b:-0}, expected 3" || nok "$n Established: ${b:-0}, expected 3"; done
  for n in rail1 rail2; do b=$(eos $n "show ip bgp summary" | grep -c Estab)
    [[ ${b:-0} -eq 5 ]] && ok "$n Established: ${b:-0}, expected 5" || nok "$n Established: ${b:-0}, expected 5"; done
  b=$(eos stor1 "show ip bgp summary" | grep -c Estab)
  [[ ${b:-0} -eq 3 ]] && ok "stor1 Established: ${b:-0}, expected 3" || nok "stor1 Established: ${b:-0}, expected 3"
  for n in gpu1 gpu2 gpu3; do b=$(eos $n "show ip bgp summary" | grep -c Estab)
    [[ ${b:-0} -eq 2 ]] && ok "$n Established: ${b:-0}, expected 2" || nok "$n Established: ${b:-0}, expected 2"; done

  echo "== ECMP width, compute to compute =="
  check_w "gpu1 next hops to gpu2" gpu1 $EP_GPU2 2
  check_w "gpu2 next hops to gpu1" gpu2 $EP_GPU1 2
  check_w "gpu2 next hops to gpu3" gpu2 $EP_GPU3 2
  check_w "gpu3 next hops to gpu1" gpu3 $EP_GPU1 2

  echo "== ECMP width, compute to storage =="
  for n in gpu1 gpu2 gpu3; do check_w "$n next hops to storage" $n $EP_NFS 2; done
  for n in rail1 rail2; do check_w "$n next hops to storage" $n $EP_NFS 2; done

  echo "== ECMP width, storage back to compute =="
  check_w "stor1 next hops to gpu1" stor1 $EP_GPU1 2
  check_w "stor1 next hops to gpu3" stor1 $EP_GPU3 2
  for n in spine1 spine2; do check_w "$n next hops to gpu3" $n $EP_GPU3 2; done

  echo "== Rail locality: on-rail flows must not reach a spine =="
  for n in rail1 rail2; do
    c=$(eos $n "show ip route $EP_GPU1" | grep -cE 'via 10\.1\.')
    [[ ${c:-0} -eq 0 ]] && ok "$n next hops to gpu1 that cross a spine: ${c:-0}, expected 0" \
      || nok "$n next hops to gpu1 that cross a spine: ${c:-0}, expected 0"
  done

  echo "== Reachability =="
  ping_t "gpu1 to gpu2"      gpu1 $EP_GPU2 $EP_GPU1
  ping_t "gpu2 to gpu3"      gpu2 $EP_GPU3 $EP_GPU2
  ping_t "gpu3 to storage"   gpu3 $EP_NFS  $EP_GPU3
  ping_t "storage to gpu1"   nfs1 $EP_GPU1 $EP_NFS

  echo "== Large frames (RDMA does not send 64-byte packets) =="
  for pair in "gpu1 $EP_NFS $EP_GPU1" "gpu2 $EP_NFS $EP_GPU2" "gpu3 $EP_NFS $EP_GPU3"; do
    set -- $pair
    if eos "$1" "ping $2 source $3 repeat 3 timeout 1 size 8000" | grep -qE '[1-9][0-9]* received'; then
      ok "$1 to storage at 8000 bytes"; else nok "$1 to storage at 8000 bytes"; fi
  done
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
}

width() {
  echo -e "${C}Installed next hops, every source against every destination.${N}"
  echo -e "${C}A collective finishes when its slowest rank finishes, so a 1 where${N}"
  echo -e "${C}there should be a 2 is a job running at half speed, not an outage.${N}"
  printf "\n%-10s %-12s %-12s %-12s %-12s\n" "from \\ to" "gpu1" "gpu2" "gpu3" "storage"
  for s in gpu1 gpu2 gpu3 rail1 rail2 stor1 spine1 spine2 nfs1; do
    printf "%-10s" "$s"
    for d in $EP_GPU1 $EP_GPU2 $EP_GPU3 $EP_NFS; do
      # a node's own endpoint is a local route, not a width
      case "$s:$d" in
        gpu1:$EP_GPU1|gpu2:$EP_GPU2|gpu3:$EP_GPU3|nfs1:$EP_NFS)
          printf "%-12s" "-"; continue ;;
      esac
      c=$(w "$s" "$d")
      if [[ ${c:-0} -ge 2 ]]; then printf "${G}%-12s${N}" "${c}"
      elif [[ ${c:-0} -eq 1 ]]; then printf "${Y}%-12s${N}" "${c}"
      else printf "${R}%-12s${N}" "0"; fi
    done; echo
  done
  echo
  echo -e "${Y}[i] A rail switch showing 1 to a GPU is correct: it has a direct link."
  echo -e "    A GPU or a spine showing 1 is a width fault. Compare twins.${N}"
}

rail() {
  local s=${1:-gpu2} d=${2:-$EP_GPU1}
  echo -e "${C}=== $s route to $d ===${N}"; eos "$s" "show ip route $d"
  echo -e "${C}=== path taken ===${N}"; eos "$s" "traceroute $d"
  echo -e "${Y}[i] 10.2.x next hops are rail-local. 10.1.x means it crossed a spine.${N}"
}

sizes() {
  local s=${1:-gpu1} d=${2:-$EP_NFS} src
  src=$(eos "$s" "show ip interface Loopback1" | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo -e "${C}Walking sizes from $s ($src) to $d.${NC:-$N}"
  for sz in 1000 1500 4000 8000 9000; do
    if eos "$s" "ping $d source $src repeat 2 timeout 1 size $sz" | grep -qE '[1-9][0-9]* received'; then
      printf "  ${G}%5d ok${N}\n" "$sz"; else printf "  ${R}%5d fail${N}\n" "$sz"; fi
  done
}

fault() {
  case $1 in
    1) eoscfg gpu2 "router bgp 65202" "maximum-paths 1" ;;
    2) eoscfg rail2 "ip prefix-list PL-NOG3 seq 10 deny 10.10.0.3/32" "ip prefix-list PL-NOG3 seq 20 permit 0.0.0.0/0 le 32" \
                    "route-map RM-F2 permit 10" "match ip address prefix-list PL-NOG3" \
                    "router bgp 65101" "neighbor FABRIC route-map RM-F2 out" ;;
    3) eoscfg spine2 "ip prefix-list PL-NOGPU seq 10 deny 10.10.0.0/16 le 32" "ip prefix-list PL-NOGPU seq 20 permit 0.0.0.0/0 le 32" \
                     "route-map RM-F3 permit 10" "match ip address prefix-list PL-NOGPU" \
                     "router bgp 65100" "neighbor 10.1.2.5 route-map RM-F3 out" ;;
    4) eoscfg rail1 "interface Ethernet1" "mtu 1500" ;;
    5) eoscfg gpu1 "router bgp 65201" "no neighbor 10.2.2.0 peer group RAILS" \
                   "neighbor 10.2.2.0 peer group RAILS" "neighbor 10.2.2.0 remote-as 65199" ;;
    6) eoscfg rail1 "router bgp 65101" "maximum-paths 1" ;;
    7) eoscfg gpu3 "ip prefix-list PL-NOEP seq 10 deny 10.10.0.3/32" "ip prefix-list PL-NOEP seq 20 permit 0.0.0.0/0 le 32" \
                   "route-map RM-F7 permit 10" "match ip address prefix-list PL-NOEP" \
                   "router bgp 65203" "neighbor 10.2.2.4 route-map RM-F7 out" ;;
    8) eoscfg stor1 "router bgp 65103" "maximum-paths 1" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"; : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~45s, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"; echo "[*] fault $1 injected"
  fi
}
restore() {
  for n in "${NODES[@]}"; do
    docker cp "configs/solution/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored"
  done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~45s, then verify."
}
hint() {
  echo -e "${Y}These are spoilers. Close the window if you did not mean to run this.${N}"; echo
  if [[ -n ${1:-} ]]; then sed -n "/^### fault $1\$/,/^### /p" docs/HINTS.md | head -n -1
  else cat docs/HINTS.md; fi
}
deploy() {
  cp -f configs/solution/*.cfg configs/active/
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  printf "[*] waiting for cEOS nodes"
  for n in "${NODES[@]}"; do
    for _ in $(seq 1 60); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
  echo -e "${Y}[i] allow ~45s, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)  deploy ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" ;;
  verify)  verify ;;
  width)   width ;;
  rail)    rail "${2:-gpu2}" "${3:-$EP_GPU1}" ;;
  sizes)   sizes "${2:-gpu1}" "${3:-$EP_NFS}" ;;
  break)   do_break "${2:-}" ;;
  reveal)  [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active" ;;
  restore) restore ;;
  hint)    hint "${2:-}" ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,16p' "$0" ;;
esac
