#!/usr/bin/env bash
# bgp-lab11 control script  (capstone)
#
#   ./lab.sh deploy                   deploy the working fabric
#   ./lab.sh destroy                  tear down
#   ./lab.sh verify                   state checks only; observed vs expected
#   ./lab.sh survey                   one screen of raw state from every device
#   ./lab.sh sizes <src> <dst>        walk packet sizes to find an MTU ceiling
#   ./lab.sh drain <node>             prepend a device away, to exercise backups
#   ./lab.sh undrain <node>
#   ./lab.sh break                    inject ALL faults at once
#   ./lab.sh break <n>                inject one, for isolated practice
#   ./lab.sh reveal                   how many faults are active
#   ./lab.sh restore                  back to the working baseline
#   ./lab.sh hint [n]                 spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab11; TOPO=bgp-lab11.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(spine1 spine2 leaf1 leaf2 leaf3 bleaf1 bleaf2 wan h1 h2 h3)
SWITCHES=(spine1 spine2 leaf1 leaf2 leaf3 bleaf1 bleaf2 wan)
LEAVES=(leaf1 leaf2 leaf3 bleaf1 bleaf2)
NFAULTS=8
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

pingok()  { eos "$1" "ping $2 repeat 3 timeout 1" | grep -qE '[1-9][0-9]* received'; }
ping_t()   { if pingok "$2" "$3"; then ok "$1"; else nok "$1"; fi; }
noping_t() { if pingok "$2" "$3"; then nok "$1: reachable, expected unreachable"; else ok "$1: unreachable, expected unreachable"; fi; }
# underlay next hops installed for a prefix
nh()      { eos "$1" "show ip route $2" | grep -cE 'via 10\.1\.'; }
# how many BGP paths a node holds for a prefix
bgp_paths() { eos "$1" "show ip bgp $2" | grep -cE '^[ ]*[*>SeEc ]+[ ]+[0-9]+\.'; }

verify() {
  echo "== Control plane =="
  for n in spine1 spine2; do
    u=$(eos $n "show ip bgp summary" | grep -c Estab); e=$(eos $n "show bgp evpn summary" | grep -c Estab)
    [[ $u -eq 5 ]] && ok "$n underlay Established: $u, expected 5" || nok "$n underlay Established: $u, expected 5"
    [[ $e -eq 5 ]] && ok "$n evpn Established: $e, expected 5"     || nok "$n evpn Established: $e, expected 5"
  done
  for n in "${LEAVES[@]}"; do
    e=$(eos $n "show bgp evpn summary" | grep -c Estab)
    [[ ${e:-0} -eq 2 ]] && ok "$n evpn Established: ${e:-0}, expected 2" || nok "$n evpn Established: ${e:-0}, expected 2"
  done
  for n in bleaf1 bleaf2; do
    w=$(eos $n "show ip bgp summary vrf all" | grep -c '172\.16\..*Estab')
    [[ ${w:-0} -eq 2 ]] && ok "$n WAN sessions: ${w:-0}, expected 2" || nok "$n WAN sessions: ${w:-0}, expected 2"
  done

  echo "== Underlay redundancy =="
  for n in leaf1 leaf2 leaf3; do
    c=$(nh $n 10.0.1.14)
    [[ ${c:-0} -ge 2 ]] && ok "$n next hops to VTEP 10.0.1.14: ${c:-0}, expected 2" \
      || nok "$n next hops to VTEP 10.0.1.14: ${c:-0}, expected 2"
  done

  echo "== Overlay, intra-VRF =="
  ping_t "h1 to h2, same subnet across the fabric"            h1 10.10.10.102
  ping_t "h2 to 10.10.20.1, routed within RED"                h2 10.10.20.1
  ping_t "h1 to 10.10.20.1, routed within RED"                h1 10.10.20.1
  ping_t "h3 to its own gateway"                              h3 10.30.30.1

  echo "== Overlay, large frames =="
  for pair in "h2 10.10.20.1" "h1 10.10.20.1" "h1 10.10.10.102"; do
    set -- $pair
    if eos "$1" "ping $2 repeat 3 timeout 1 size 4000" | grep -qE '[1-9][0-9]* received'; then
      ok "$1 to $2 at 4000 bytes"
    else
      nok "$1 to $2 at 4000 bytes"
    fi
  done

  echo "== Tenant isolation =="
  noping_t "h3 (BLUE) to h1 (RED)"  h3 10.10.10.101
  noping_t "h3 (BLUE) to 10.10.20.1 (RED)" h3 10.10.20.1

  echo "== WAN reachability =="
  ping_t "h1 to 203.0.113.10"  h1 203.0.113.10
  ping_t "h2 to 203.0.113.10"  h2 203.0.113.10
  ping_t "h3 to 203.0.113.10"  h3 203.0.113.10

  echo "== WAN sees both borders =="
  for pfx in 10.10.10.0/24 10.10.20.0/24 10.30.30.0/24; do
    c=$(bgp_paths wan $pfx)
    [[ ${c:-0} -ge 2 ]] && ok "wan holds $pfx paths: ${c:-0}, expected 2" \
      || nok "wan holds $pfx paths: ${c:-0}, expected 2"
  done
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
}

survey() {
  echo -e "${C}Raw state from every device. Collect this once, properly, before${N}"
  echo -e "${C}changing anything. The outliers are the work.${N}"
  for n in spine1 spine2; do
    echo; echo -e "${C}=== $n ===${N}"
    eos $n "show bgp evpn summary"; done
  for n in leaf1 leaf2 leaf3; do
    echo; echo -e "${C}=== $n ===${N}"
    eos $n "show vxlan vni"; eos $n "show ip route 10.0.1.14"; done
  for n in bleaf1 bleaf2; do
    echo; echo -e "${C}=== $n ===${N}"
    eos $n "show ip bgp summary vrf all"; done
  echo; echo -e "${C}=== wan: what each border is actually giving us ===${N}"
  eos wan "show ip bgp"
}

sizes() {
  local s=${1:-h2} d=${2:-10.10.20.1}
  echo -e "${C}Walking packet sizes from $s to $d. The last size that passes is${N}"
  echo -e "${C}your effective path MTU, inner. Subtract it from 9214 and ask${N}"
  echo -e "${C}what the difference is made of.${N}"
  for sz in 100 1000 1400 1472 1500 2000 4000 8000; do
    if eos "$s" "ping $d repeat 2 timeout 1 size $sz" | grep -qE '[1-9][0-9]* received'; then
      printf "  ${G}%5d ok${N}\n" "$sz"
    else
      printf "  ${R}%5d fail${N}\n" "$sz"
    fi
  done
}

drain() {
  local n=${1:?node}
  eoscfg "$n" "route-map RM-DRAIN permit 10" "set as-path prepend 65535 65535 65535" \
              "router bgp $(eos "$n" 'show ip bgp summary' | grep -oE 'local AS number [0-9]+' | grep -oE '[0-9]+$')" \
              "address-family evpn" "neighbor EVPN route-map RM-DRAIN out"
  echo "[*] $n drained. ./lab.sh undrain $n to reverse."
}
undrain() {
  local n=${1:?node}
  eoscfg "$n" "router bgp $(eos "$n" 'show ip bgp summary' | grep -oE 'local AS number [0-9]+' | grep -oE '[0-9]+$')" \
              "address-family evpn" "no neighbor EVPN route-map RM-DRAIN out"
  echo "[*] $n undrained."
}

fault() {
  case $1 in
    1) eoscfg leaf2 "interface Ethernet1" "mtu 1500" "interface Ethernet2" "mtu 1500" ;;
    2) eoscfg leaf1 "interface Vxlan1" "no vxlan vlan 10 vni 10010" ;;
    3) eoscfg bleaf2 "route-map RM-BLUE-OUT permit 10" "no match ip address prefix-list PL-BLUE-TENANT" \
                     "match ip address prefix-list PL-RED-TENANT" ;;
    4) eoscfg leaf3 "interface Vlan30" "vrf RED" "ip address virtual 10.30.30.1/24" ;;
    5) eoscfg bleaf1 "no ip prefix-list PL-RED-TENANT" "ip prefix-list PL-RED-TENANT seq 10 permit 10.10.0.0/16" ;;
    6) eoscfg spine1 "router bgp 65100" "no neighbor 10.0.0.13 peer group EVPN" ;;
    7) eoscfg spine2 "ip prefix-list PL-LOOPBACKS" "no seq 20" ;;
    8) eoscfg leaf1 "ip route vrf RED 203.0.113.0/24 Null0" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"; : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~60s, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"; echo "[*] fault $1 injected"
  fi
}
restore() {
  for n in "${SWITCHES[@]}"; do
    docker cp "configs/solution/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored"
  done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~60s, then verify."
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
  echo -e "${Y}[i] allow ~90s for EVPN to settle, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)  deploy ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" ;;
  verify)  verify ;;
  survey)  survey ;;
  sizes)   sizes "${2:-h2}" "${3:-10.10.20.1}" ;;
  drain)   drain "${2:?node}" ;;
  undrain) undrain "${2:?node}" ;;
  break)   do_break "${2:-}" ;;
  reveal)  [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active" ;;
  restore) restore ;;
  hint)    hint "${2:-}" ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,18p' "$0" ;;
esac
