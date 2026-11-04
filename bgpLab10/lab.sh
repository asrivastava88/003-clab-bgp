#!/usr/bin/env bash
# bgp-lab10 control script  (BGP security at an internet edge)
#
#   ./lab.sh deploy <base|solution>   stage configs and deploy (one mode)
#   ./lab.sh destroy                  tear down
#   ./lab.sh verify                   state checks only; reports what it saw
#   ./lab.sh inbound [node]           everything we accepted from each neighbour
#   ./lab.sh outbound                 what each neighbour received FROM us
#   ./lab.sh break                    inject ALL faults at once
#   ./lab.sh break <n>                inject one fault, for isolated practice
#   ./lab.sh reveal                   how many faults are active
#   ./lab.sh restore                  back to the deployed baseline
#   ./lab.sh hint [n]                 spoilers
#   ./lab.sh cli <node>               Cli on any node
#   ./lab.sh status
#
# verify states observed vs expected and nothing else. It never names a
# command, a config line or a likely cause. That is what hint is for.
set -uo pipefail
LAB=bgp-lab10; TOPO=bgp-lab10.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(core edge1 edge2 transit peer1 cust1 cust2 h1)
SWITCHES=(core edge1 edge2 transit peer1 cust1 cust2)
NFAULTS=8
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
mode() { cat "$DIR/.mode" 2>/dev/null || echo unknown; }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

# our side of each external session
declare -A OURIP=( [transit]=208.0.1.1 [peer1]=208.0.2.1 [cust1]=208.0.3.1 [cust2]=208.0.4.1 )
declare -A OUREDGE=( [transit]=edge1 [peer1]=edge1 [cust1]=edge2 [cust2]=edge2 )
OUR_SPACE=203.0.0.0/16

# is a prefix present in a node's BGP table at all
holds() { eos "$1" "show ip bgp $2" | grep -c "$(echo "$2" | cut -d/ -f1)"; }
# how many prefixes a node holds that match a pattern
countp() { eos "$1" "show ip bgp" | grep -cE "$2"; }
# prefixes a given external neighbour received from us, counted at THEIR end
# (checking at the receiver avoids depending on advertised-routes formatting)
recv_from_us() { eos "$1" "show ip bgp" | grep -cE "[ ]65100([ _]|$)"; }

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"

  echo "== Sessions =="
  o=$(eos core "show ip ospf neighbor" | grep -c FULL)
  [[ ${o:-0} -eq 2 ]] && ok "core OSPF FULL: ${o:-0}, expected 2" || nok "core OSPF FULL: ${o:-0}, expected 2"
  for n in edge1 edge2; do b=$(eos $n "show ip bgp summary" | grep -c Estab)
    [[ ${b:-0} -eq 4 ]] && ok "$n BGP Established: ${b:-0}, expected 4" \
      || nok "$n BGP Established: ${b:-0}, expected 4"; done

  echo "== Inbound: bogons =="
  for pair in "edge1 10.0.0.0/8 transit" "edge1 192.168.50.0/24 peer1" \
              "edge2 192.168.100.0/24 cust2" "edge2 169.254.1.0/24 cust2"; do
    set -- $pair
    c=$(eos "$1" "show ip bgp $2" | grep -c "$2")
    [[ ${c:-0} -eq 0 ]] && ok "$1 holds $2 (announced by $3): ${c:-0}, expected 0" \
      || nok "$1 holds $2 (announced by $3): ${c:-0}, expected 0"
  done

  echo "== Inbound: our own space from outside =="
  c=$(eos edge2 "show ip bgp $OUR_SPACE" | grep -cE "65501")
  [[ ${c:-0} -eq 0 ]] && ok "edge2 holds external paths for $OUR_SPACE: ${c:-0}, expected 0" \
    || nok "edge2 holds external paths for $OUR_SPACE: ${c:-0}, expected 0"
  c=$(eos edge2 "show ip bgp 207.0.9.0/24" | grep -c "207.0.9.0")
  [[ ${c:-0} -eq 0 ]] && ok "edge2 holds 207.0.9.0/24: ${c:-0}, expected 0" \
    || nok "edge2 holds 207.0.9.0/24: ${c:-0}, expected 0"

  echo "== Inbound: registered space only =="
  c=$(eos edge2 "show ip bgp" | grep -cE "^.{0,4}20[67]\.")
  [[ ${c:-0} -ge 1 && ${c:-0} -le 5 ]] && ok "edge2 holds ${c:-0} customer prefixes, expected 1 to 5" \
    || nok "edge2 holds ${c:-0} customer prefixes, expected 1 to 5"
  for pair in "edge2 206.0.0.0/16" "edge2 207.0.0.0/16"; do
    set -- $pair
    c=$(eos "$1" "show ip bgp $2" | grep -c "$2")
    [[ ${c:-0} -ge 1 ]] && ok "$1 holds $2: present, expected present" \
      || nok "$1 holds $2: absent, expected present"
  done

  [[ $m == base ]] && {
    echo -e "${Y}[i] base mode has no policy of any kind.${N}"
    echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
    return; }

  echo "== Outbound: measured at the receiver =="
  c=$(eos transit "show ip bgp 205.0.0.0/16" | grep -c "65100")
  [[ ${c:-0} -eq 0 ]] && ok "transit holds 205.0.0.0/16 via us: ${c:-0}, expected 0" \
    || nok "transit holds 205.0.0.0/16 via us: ${c:-0}, expected 0"
  c=$(eos peer1 "show ip bgp 204.0.0.0/16" | grep -c "65100")
  [[ ${c:-0} -eq 0 ]] && ok "peer1 holds 204.0.0.0/16 via us: ${c:-0}, expected 0" \
    || nok "peer1 holds 204.0.0.0/16 via us: ${c:-0}, expected 0"
  for pair in "transit $OUR_SPACE" "transit 206.0.0.0/16" "peer1 $OUR_SPACE"; do
    set -- $pair
    c=$(eos "$1" "show ip bgp $2" | grep -c "$2")
    [[ ${c:-0} -ge 1 ]] && ok "$1 holds $2: present, expected present" \
      || nok "$1 holds $2: absent, expected present"
  done
  c=$(eos cust1 "show ip bgp" | grep -cE "^[ *>iSe]*[ ]*[0-9]+\.")
  [[ ${c:-0} -le 2 ]] && ok "cust1 holds ${c:-0} prefixes from us, expected 1 to 2" \
    || nok "cust1 holds ${c:-0} prefixes from us, expected 1 to 2"

  echo "== Data plane =="
  for t in 204.0.0.1 205.0.0.1 206.0.0.1 207.0.0.1; do
    if eos h1 "ping $t repeat 2 timeout 1" | grep -qE '[1-9][0-9]* received'; then
      ok "h1 reaches $t"; else nok "h1 reaches $t"; fi
  done
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
}

inbound() {
  local only=${1:-}
  echo -e "${C}What we accepted from each external neighbour.${N}"
  for n in transit peer1 cust1 cust2; do
    [[ -n $only && $only != "$n" ]] && continue
    echo; echo -e "${C}=== ${OUREDGE[$n]} <- $n (${OURIP[$n]}) ===${N}"
    eos "${OUREDGE[$n]}" "show ip bgp neighbors ${OURIP[$n]} routes"
  done
}

outbound() {
  echo -e "${C}What each neighbour actually holds that came from us. Checked at${N}"
  echo -e "${C}their end, because what you believe you advertised is not evidence.${N}"
  for n in transit peer1 cust1 cust2; do
    echo; echo -e "${C}=== $n's table ===${N}"; eos "$n" "show ip bgp"
  done
}

fault() {
  case $1 in
    1) eoscfg edge2 "no route-map RM-FROM-CUST2 deny 6" ;;
    2) eoscfg edge2 "ip prefix-list PL-CUST2" "seq 20 permit 0.0.0.0/0 le 32" ;;
    3) eoscfg edge1 "no route-map RM-FROM-TRANSIT deny 5" ;;
    4) eoscfg edge1 "no route-map RM-FROM-PEER deny 5" ;;
    5) eoscfg edge2 "router bgp 65100" "neighbor 208.0.4.2 allowas-in 3" ;;
    6) eoscfg edge1 "route-map RM-TO-TRANSIT permit 100" "description left over from a change window" ;;
    7) eoscfg edge1 "route-map RM-TO-PEER permit 100" "description left over from a change window" ;;
    8) eoscfg edge2 "route-map RM-TO-CUSTOMER permit 100" "description left over from a change window" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == solution ]] || echo -e "${Y}[!] faults are regressions from the solution baseline${N}"
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"
    : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~45s, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"
    echo "[*] fault $1 injected"
  fi
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=solution
  for n in "${SWITCHES[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  for n in edge1 edge2; do eos $n "clear ip bgp *" >/dev/null 2>&1; done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~45s, then verify."
}
hint() {
  echo -e "${Y}These are spoilers. Close the window if you did not mean to run this.${N}"; echo
  if [[ -n ${1:-} ]]; then sed -n "/^### fault $1\$/,/^### /p" docs/HINTS.md | head -n -1
  else cat docs/HINTS.md; fi
}
wait_nodes() {
  printf "[*] waiting for cEOS nodes"
  for n in "${NODES[@]}"; do
    for _ in $(seq 1 60); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
}
deploy() {
  local m=${1:-solution}
  [[ -d configs/$m ]] || { echo "mode: base|solution"; exit 1; }
  cp -f configs/"$m"/*.cfg configs/active/; echo "$m" > "$DIR/.mode"
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  wait_nodes
  echo -e "${Y}[i] mode=$m. Allow ~60s, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)   deploy "${2:-solution}" ;;
  destroy)  $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)   verify ;;
  inbound)  inbound "${2:-}" ;;
  outbound) outbound ;;
  break)    do_break "${2:-}" ;;
  reveal)   [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active" ;;
  restore)  restore ;;
  hint)     hint "${2:-}" ;;
  cli)      docker exec -it "$P-${2:?node}" Cli ;;
  status)   $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,18p' "$0" ;;
esac
