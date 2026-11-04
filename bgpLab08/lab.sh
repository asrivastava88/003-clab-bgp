#!/usr/bin/env bash
# bgp-lab08 control script  (multi-site EVPN DCI)
#   ./lab.sh deploy <base|solution>  stage configs and deploy (one mode)
#   ./lab.sh destroy                 tear down
#   ./lab.sh verify                  per-site, DCI, and the gateway containment checks
#   ./lab.sh tunnels                 who tunnels to whom: proves the stitch
#   ./lab.sh stretch                 follow one stretched MAC from site A to site B
#   ./lab.sh break <1-8|random>      inject a ticket (solution baseline)
#   ./lab.sh reveal | restore        show / clear the active ticket
#   ./lab.sh cli <node>              Cli on any node
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab08; TOPO=bgp-lab08.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(spineA leafA bgwA spineB leafB bgwB hA1 hA2 hB1 hB2)
STATE="$DIR/.active_ticket"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
mode() { cat "$DIR/.mode" 2>/dev/null || echo unknown; }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

# gateway VTEP = its single loopback; leaf VTEPs live on Loopback1
GW_A=10.0.0.14; GW_B=10.0.2.14
LEAF_A_VTEP=10.0.1.11; LEAF_B_VTEP=10.0.3.11

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
  echo -e "${Y}[i] mode=$m. Allow ~90s for both fabrics and the DCI, then ./lab.sh verify${N}"
}

reaches()  { eos "$1" "ping $2 repeat 2 timeout 1" | grep -qE '[1-9][0-9]* received'; }
ping_t()   { if reaches "$2" "$3"; then ok "$1"; else nok "$1"; fi; }
noping_t() { if reaches "$2" "$3"; then nok "UNEXPECTED REACHABILITY: $1"; else ok "blocked (as designed): $1"; fi; }
estab()    { eos "$1" "show bgp evpn summary" | grep -c Estab; }

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"

  echo "== Site A fabric =="
  u=$(eos spineA "show ip bgp summary" | grep -c Estab); e=$(estab spineA)
  [[ $u -eq 2 && $e -eq 2 ]] && ok "spineA underlay $u/2 evpn $e/2" || nok "spineA underlay $u/2 evpn $e/2"
  e=$(estab leafA); [[ ${e:-0} -eq 1 ]] && ok "leafA evpn $e/1" || nok "leafA evpn ${e:-0}/1"
  echo "== Site B fabric =="
  u=$(eos spineB "show ip bgp summary" | grep -c Estab); e=$(estab spineB)
  [[ $u -eq 2 && $e -eq 2 ]] && ok "spineB underlay $u/2 evpn $e/2" || nok "spineB underlay $u/2 evpn $e/2"
  e=$(estab leafB); [[ ${e:-0} -eq 1 ]] && ok "leafB evpn $e/1" || nok "leafB evpn ${e:-0}/1"

  echo "== Intra-site (must work before the DCI is worth anything) =="
  ping_t "hA1 -> its gateway (site A)"                 hA1 10.10.10.1
  ping_t "hA1 -> hA2  site A, L3VNI 50001"             hA1 10.20.20.101
  ping_t "hB1 -> its gateway (site B)"                 hB1 10.10.10.1
  ping_t "hB1 -> hB2  site B, L3VNI 50001"             hB1 10.30.30.101

  if [[ $m == base ]]; then
    echo "== No DCI yet: the two sites must not see each other =="
    noping_t "hA1 -> hB1  stretched subnet, no DCI"  hA1 10.10.10.102
    noping_t "hA2 -> hB2  L3 across sites, no DCI"   hA2 10.30.30.101
    echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}. Now build the DCI: docs/TASKS.md Part A."
    return
  fi

  echo "== DCI sessions =="
  for n in bgwA bgwB; do
    d=$(eos $n "show ip bgp summary" | grep -c Estab)
    [[ ${d:-0} -eq 2 ]] && ok "$n has 2 IPv4 sessions (spine + DCI underlay)" || nok "$n IPv4 sessions ${d:-0}/2"
    e=$(estab $n)
    [[ ${e:-0} -eq 2 ]] && ok "$n has 2 EVPN sessions (spine + DCI overlay)" || nok "$n EVPN sessions ${e:-0}/2"
  done

  echo "== Gateway containment: the DCI underlay carries two prefixes, not two fabrics =="
  r=$(eos bgwB "show ip route $GW_A" | grep -c "$GW_A")
  [[ ${r:-0} -ge 1 ]] && ok "bgwB has a route to bgwA's loopback $GW_A" || nok "bgwB cannot reach $GW_A"
  r=$(eos bgwB "show ip route $LEAF_A_VTEP" | grep -c "$LEAF_A_VTEP")
  [[ ${r:-0} -eq 0 ]] && ok "bgwB has NO route to leafA's VTEP $LEAF_A_VTEP (correct: it never needs one)" \
    || nok "bgwB has a route to leafA's VTEP; the DCI underlay filter is leaking a whole fabric"
  r=$(eos leafB "show ip route $GW_A" | grep -c "$GW_A")
  [[ ${r:-0} -eq 0 ]] && ok "leafB has NO route to bgwA ($GW_A): site B's underlay stayed local" \
    || nok "leafB has a route into site A's loopback space; RM-SITE-OUT is not containing it"

  echo "== The stitch: a leaf must tunnel to its own gateway, never across the WAN =="
  v=$(eos leafA "show vxlan vtep" | grep -c "$GW_A")
  [[ ${v:-0} -ge 1 ]] && ok "leafA lists its own gateway $GW_A as a VTEP" || nok "leafA does not list $GW_A as a VTEP"
  v=$(eos leafA "show vxlan vtep" | grep -cE "$GW_B|$LEAF_B_VTEP")
  [[ ${v:-0} -eq 0 ]] && ok "leafA lists NO site B VTEP: the tunnel terminates at the gateway" \
    || nok "leafA lists a site B VTEP; this is a flat stretch, not a gateway (next-hop-self missing?)"
  v=$(eos leafB "show vxlan vtep" | grep -cE "$GW_A|$LEAF_A_VTEP")
  [[ ${v:-0} -eq 0 ]] && ok "leafB lists NO site A VTEP" || nok "leafB lists a site A VTEP"

  echo "== Stretched L2 across the DCI (VLAN 10, L2VNI 10010) =="
  ping_t "hA1 -> hB1  same subnet, different site"     hA1 10.10.10.102
  ping_t "hB1 -> hA1  and back"                        hB1 10.10.10.101
  m1=$(eos leafA "show vxlan address-table vlan 10" | grep -c "$GW_A")
  [[ ${m1:-0} -ge 1 ]] && ok "leafA learned the remote MAC behind its own gateway" \
    || nok "leafA did not learn the remote MAC via $GW_A"

  echo "== L3 across the DCI (site-local subnets, type-5) =="
  ping_t "hA2 -> hB2  10.20.20.0/24 to 10.30.30.0/24"  hA2 10.30.30.101
  ping_t "hB2 -> hA2  and back"                        hB2 10.20.20.101
  ping_t "hA1 -> hB2  stretched subnet to site B local" hA1 10.30.30.101
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] ticket active (./lab.sh reveal | restore)${N}"
}

tunnels() {
  echo -e "${C}Who tunnels to whom. In a gateway design each leaf sees exactly one${N}"
  echo -e "${C}remote VTEP, its own site's gateway. If a leaf lists a VTEP from the${N}"
  echo -e "${C}other site, you have built a flat stretch by accident.${N}"
  for n in leafA bgwA bgwB leafB; do
    echo; echo -e "${C}=== $n: show vxlan vtep ===${N}"; eos $n "show vxlan vtep"
  done
  echo; echo -e "${C}=== what each gateway can route to (should be one loopback each way) ===${N}"
  for n in bgwA bgwB; do
    echo "-- $n --"; eos $n "show ip bgp" | grep -E "10\.0\.[0-3]\." || true
  done
}

stretch() {
  echo -e "${C}--- 1. hB1's MAC, learned locally at site B ---${N}"
  eos leafB "show mac address-table vlan 10"
  echo -e "${C}--- 2. leafB originates a type-2 for it ---${N}"
  eos leafB "show bgp evpn route-type mac-ip 10.10.10.102"
  echo -e "${C}--- 3. bgwB re-advertises it across the DCI with ITS OWN next hop ---${N}"
  eos bgwB "show bgp evpn route-type mac-ip 10.10.10.102 detail" | head -30
  echo -e "${C}--- 4. bgwA receives it, re-advertises into site A with its own next hop ---${N}"
  eos bgwA "show bgp evpn route-type mac-ip 10.10.10.102 detail" | head -30
  echo -e "${C}--- 5. leafA installs it behind bgwA, not behind leafB ---${N}"
  eos leafA "show vxlan address-table vlan 10"
  echo -e "${Y}[i] The next hop changes twice, once at each gateway. That is the stitch.${N}"
}

ticket() {
  case $1 in
    1) eoscfg bgwA "router bgp 65104" "no neighbor DCI-EVPN next-hop-self" ;;
    2) eoscfg bgwA "router bgp 65104" "no neighbor EVPN next-hop-self" ;;
    3) eoscfg bgwB "interface Vxlan1" "no vxlan vlan 10 vni 10010" ;;
    4) eoscfg bgwA "ip prefix-list PL-DCI-OUT" "no seq 10" ;;
    5) eoscfg bgwB "interface Vxlan1" "no vxlan vrf RED vni 50001" "vxlan vrf RED vni 50011" ;;
    6) eoscfg bgwB "router bgp 65204" "vrf RED" "no route-target import evpn 50001:50001" ;;
    7) eoscfg bgwA "router bgp 65104" "no neighbor DCI-EVPN ebgp-multihop 3" ;;
    8) eoscfg leafB "router bgp 65201" "vlan 10" "no route-target both 10010:10010" "route-target both 10010:10019" ;;
    *) echo "tickets: 1-8 or random"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == solution ]] || echo -e "${Y}[!] tickets assume the solution baseline${N}"
  local t=$1; [[ $t == random ]] && t=$(( (RANDOM % 8) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  [[ $1 == random ]] && echo "[*] blind ticket injected. Start with ./lab.sh verify, then ./lab.sh tunnels" \
                     || echo "[*] ticket $t injected. See docs/TICKETS.md"
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=solution
  for n in "${NODES[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~60s, then verify."
}

case ${1:-} in
  deploy)  deploy "${2:-solution}" ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)  verify ;;
  tunnels) tunnels ;;
  stretch) stretch ;;
  break)   do_break "${2:?ticket number or random}" ;;
  reveal)  [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore) restore ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,12p' "$0" ;;
esac
