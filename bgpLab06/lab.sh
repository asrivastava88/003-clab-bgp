#!/usr/bin/env bash
# bgp-lab06 control script  (pure BGP)
#   ./lab.sh deploy <base|solution>  stage configs and deploy (one mode)
#   ./lab.sh destroy                 tear down
#   ./lab.sh verify                  sessions, policy triangle, leak checks, data plane
#   ./lab.sh leaks                   what each neighbor receives from us, in full
#   ./lab.sh bestpath <prefix>       the decision for one prefix, on every router
#   ./lab.sh break <1-8|random>      inject a ticket (solution baseline)
#   ./lab.sh reveal | restore        show / clear the active ticket
#   ./lab.sh cli <node>              Cli on any node
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab06; TOPO=bgp-lab06.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(core edge1 edge2 transitA transitB peerX cust1 far)
STATE="$DIR/.active_ticket"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
mode() { cat "$DIR/.mode" 2>/dev/null || echo unknown; }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

# our side of each eBGP session, for "what did we send them" questions
# the FAR side of each /30. Our own side is .1; the neighbour is .2.
declare -A PEERIP=( [transitA]=172.16.12.2 [peerX]=172.16.14.2 [transitB]=172.16.13.2 [cust1]=172.16.15.2 )

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
  echo -e "${Y}[i] mode=$m. Allow ~60s for OSPF and BGP, then ./lab.sh verify${N}"
}

ping_t() {
  local out; out=$(eos "$2" "ping $3 repeat 3 timeout 1")
  if echo "$out" | grep -qE '[1-9][0-9]* received'; then ok "$1"; else nok "$1"; fi
}
estab() { eos "$1" "show ip bgp summary" | grep -c Estab; }
# does $1 hold $2 in its BGP table at all
holds() { eos "$1" "show ip bgp $2" | grep -c "$2"; }
# count prefixes we advertise to a given external neighbor
adv_count() { eos "$1" "show ip bgp neighbors ${PEERIP[$2]} advertised-routes" | grep -cE '^ *[*>iS ]*[ ]*[0-9]+\.'; }
# is a specific prefix among what we advertise to that neighbor
adv_has() { eos "$1" "show ip bgp neighbors ${PEERIP[$2]} advertised-routes" | grep -c "$3"; }
# a "must NOT announce" check counting 0 is also satisfied by a failed command.
# Returns 1 when the output is usable, 0 when it is not.
adv_usable() { eos "$1" "show ip bgp neighbors ${PEERIP[$2]} advertised-routes" | grep -qiE 'BGP routing table|Network' && echo 1 || echo 0; }

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"

  echo "== Sessions =="
  o=$(eos core "show ip ospf neighbor" | grep -c FULL)
  [[ ${o:-0} -eq 2 ]] && ok "core OSPF FULL $o/2" || nok "core OSPF FULL ${o:-0}/2"
  for n in edge1 edge2; do o=$(eos $n "show ip ospf neighbor" | grep -c FULL)
    [[ ${o:-0} -eq 2 ]] && ok "$n OSPF FULL $o/2" || nok "$n OSPF FULL ${o:-0}/2"; done
  b=$(estab core);  [[ ${b:-0} -eq 2 ]] && ok "core iBGP $b/2" || nok "core iBGP ${b:-0}/2"
  for n in edge1 edge2; do b=$(estab $n)
    [[ ${b:-0} -eq 4 ]] && ok "$n BGP $b/4 (2 iBGP + 2 eBGP)" || nok "$n BGP ${b:-0}/4"; done

  echo "== Next-hop resolution (core has no route to any eBGP subnet) =="
  u=$(eos core "show ip bgp 10.6.0.0/16" | grep -c "172.16.")
  [[ ${u:-0} -eq 0 ]] && ok "core's paths for 10.6.0.0/16 carry no unresolvable eBGP next hop" \
    || nok "core sees a 172.16.x next hop for 10.6.0.0/16 (next-hop-self missing on an edge?)"
  [[ $(holds core 10.6.0.0/16) -ge 1 ]] && ok "core holds 10.6.0.0/16" || nok "core does not hold 10.6.0.0/16"

  [[ $m == base ]] && {
    echo "== Findings (base mode has no policy) =="
    l1=$(adv_has edge2 transitB 10.200.0.0); l2=$(adv_has edge1 peerX 10.201.0.0)
    echo -e "  ${Y}we advertise transitA's 10.200.0.0/16 to transitB: ${l1:-0} (should be 0)${N}"
    echo -e "  ${Y}we advertise transitB's 10.201.0.0/16 to peerX:    ${l2:-0} (should be 0)${N}"
    echo -e "  ${Y}prefixes we advertise to transitA: $(adv_count edge1 transitA) (should be 2: our aggregate + customer)${N}"
    echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}. Now go build the policy: docs/TASKS.md Part A."
    return; }

  echo "== Policy triangle: preference by neighbor type =="
  p=$(eos core "show ip bgp 10.6.0.0/16" | grep -c "65400 65600")
  [[ ${p:-0} -ge 1 ]] && ok "core reaches far via the free peer, not a paid transit" \
    || nok "core's best path for 10.6.0.0/16 is not via peerX 65400 (check LOCAL_PREF on peer ingress)"
  cp=$(eos edge2 "show ip bgp 10.5.0.0/16" | grep -c "10.5.0.0/16")
  [[ ${cp:-0} -ge 1 ]] && ok "customer prefix 10.5.0.0/16 accepted" || nok "customer prefix not accepted"
  cd2=$(eos edge2 "show ip bgp 10.5.100.0/24" | grep -c "10.5.100.0/24")
  [[ ${cd2:-0} -eq 0 ]] && ok "customer's unregistered 10.5.100.0/24 filtered on ingress" \
    || nok "customer's 10.5.100.0/24 was accepted; the ingress prefix-list is too loose"

  echo "== Leak checks: what we must NOT announce =="
  for pair in "edge2 transitB 10.200.0.0" "edge1 transitA 10.201.0.0" "edge1 peerX 10.200.0.0" "edge1 peerX 10.201.0.0"; do
    set -- $pair
    if [[ $(adv_usable "$1" "$2") -ne 1 ]]; then
      nok "$1 advertised-routes toward $2 unreadable, expected readable"
    else
      n=$(adv_has "$1" "$2" "$3")
      [[ ${n:-0} -eq 0 ]] && ok "$1 announces $3/16 to $2: ${n:-0}, expected 0" \
        || nok "$1 announces $3/16 to $2: ${n:-0}, expected 0"
    fi
  done

  echo "== Aggregation =="
  a=$(adv_has edge1 transitA "10.100.0.0/16")
  [[ ${a:-0} -ge 1 ]] && ok "edge1 announces the 10.100.0.0/16 aggregate to transitA" || nok "aggregate not announced"
  d=$(eos edge1 "show ip bgp neighbors ${PEERIP[transitA]} advertised-routes" | grep -cE "10\.100\.(16|32|48|64)\.0")
  [[ ${d:-0} -eq 0 ]] && ok "the four component /20s are suppressed, not announced" \
    || nok "$d component /20s are leaking alongside the aggregate (summary-only missing?)"

  echo "== Customer announcements =="
  for pair in "edge1 transitA" "edge2 transitB"; do
    set -- $pair
    n=$(adv_has "$1" "$2" "10.5.0.0/16")
    [[ ${n:-0} -ge 1 ]] && ok "$1 announces the customer prefix to $2" \
      || nok "$1 does not announce 10.5.0.0/16 to $2 (community tag lost over iBGP?)"
  done
  n=$(adv_has edge2 cust1 "0.0.0.0/0")
  [[ ${n:-0} -ge 1 ]] && ok "cust1 receives a default from us" || nok "cust1 receives no default"

  echo "== Data plane =="
  ping_t "core -> far 10.6.0.1"            core "10.6.0.1 source 10.100.0.1"
  ping_t "core -> peerX 10.202.0.1"        core "10.202.0.1 source 10.100.0.1"
  ping_t "core -> transitA 10.200.0.1"     core "10.200.0.1 source 10.100.0.1"
  ping_t "core -> customer 10.5.0.1"       core "10.5.0.1 source 10.100.0.1"
  ping_t "cust1 -> far via us"             cust1 "10.6.0.1 source 10.5.0.1"
  ping_t "far -> our aggregate space"      far   "10.100.16.1 source 10.6.0.1"
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] ticket active (./lab.sh reveal | restore)${N}"
}

leaks() {
  echo -e "${C}Everything we advertise, per neighbor. A transit or peer session should${N}"
  echo -e "${C}show only our aggregate and our customer's prefix. Nothing else.${N}"
  for pair in "edge1 transitA" "edge1 peerX" "edge2 transitB" "edge2 cust1"; do
    set -- $pair
    echo
    echo -e "${C}=== $1 -> $2 (${PEERIP[$2]}) ===${N}"
    eos "$1" "show ip bgp neighbors ${PEERIP[$2]} advertised-routes"
  done
}

bestpath() {
  local pfx=${1:?prefix, e.g. 10.6.0.0/16}
  for n in edge1 edge2 core; do
    echo -e "${C}=== $n: show ip bgp $pfx ===${N}"; eos $n "show ip bgp $pfx"
  done
  echo -e "${Y}[i] Compare LOCAL_PREF first, then AS_PATH length, then work down the"
  echo -e "    tie-breakers. On core, the IGP metric to the next hop is 10 via edge1"
  echo -e "    and 30 via edge2, which is the step most people forget.${N}"
}

ticket() {
  case $1 in
    1) eoscfg edge2 "router bgp 65100" "no neighbor IBGP next-hop-self" ;;
    2) eoscfg edge2 "route-map RM-TO-TRANSIT permit 100" "description audit says this was for troubleshooting" ;;
    3) eoscfg edge2 "ip prefix-list PL-CUST1" "seq 20 permit 0.0.0.0/0 le 32" ;;
    4) eoscfg edge1 "route-map RM-FROM-PEER permit 10" "set local-preference 50" ;;
    5) eoscfg edge1 "router bgp 65100" "no aggregate-address 10.100.0.0/16 summary-only" "aggregate-address 10.100.0.0/16" ;;
    6) eoscfg edge2 "router bgp 65100" "neighbor 172.16.15.2 maximum-routes 2" ;;
    7) eoscfg edge1 "route-map RM-TO-PEER permit 100" "description leftover catch-all" ;;
    8) eoscfg edge2 "router bgp 65100" "no neighbor IBGP send-community" ;;
    *) echo "tickets: 1-8 or random"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == solution ]] || echo -e "${Y}[!] tickets assume the solution baseline (./lab.sh deploy solution)${N}"
  local t=$1; [[ $t == random ]] && t=$(( (RANDOM % 8) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  [[ $1 == random ]] && echo "[*] blind ticket injected. Start with ./lab.sh verify" || echo "[*] ticket $t injected. See docs/TICKETS.md"
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=solution
  for n in "${NODES[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  for n in edge1 edge2; do eos $n "clear ip bgp *" >/dev/null 2>&1; done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~60s, then verify."
}

case ${1:-} in
  deploy)   deploy "${2:-solution}" ;;
  destroy)  $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)   verify ;;
  leaks)    leaks ;;
  bestpath) bestpath "${2:-10.6.0.0/16}" ;;
  break)    do_break "${2:?ticket number or random}" ;;
  reveal)   [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore)  restore ;;
  cli)      docker exec -it "$P-${2:?node}" Cli ;;
  status)   $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,12p' "$0" ;;
esac
