#!/usr/bin/env bash
# bgp-lab04 control script
#   ./lab.sh deploy <base|solution|addpath>  stage configs and deploy (one mode)
#   ./lab.sh destroy                         tear down
#   ./lab.sh verify                          underlay, overlay, RR behavior, data plane
#   ./lab.sh paths                           show the path-hiding picture on one screen
#   ./lab.sh break <1-8|random>              inject a ticket (addpath baseline)
#   ./lab.sh reveal | restore                show / clear the active ticket
#   ./lab.sh cli <node>                      Cli on any node (every node is cEOS)
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab04; TOPO=bgp-lab04.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(spine1 spine2 leaf1 leaf2 bleaf1 bleaf2 wan h1 h2 h3)
CLIENTS=(leaf1 leaf2 bleaf1 bleaf2)
STATE="$DIR/.active_ticket"; CLAB="sudo containerlab"
VRF_NAME=RED
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
mode() { cat "$DIR/.mode" 2>/dev/null || echo unknown; }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

wait_nodes() {
  printf "[*] waiting for cEOS nodes"
  for n in "${NODES[@]}"; do
    for _ in $(seq 1 60); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
}

deploy() {
  local m=${1:-addpath}
  [[ -d configs/$m ]] || { echo "mode: base|solution|addpath"; exit 1; }
  cp -f configs/"$m"/*.cfg configs/active/; echo "$m" > "$DIR/.mode"
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  wait_nodes
  echo -e "${Y}[i] mode=$m. Allow ~90s for OSPF and the overlay to settle, then ./lab.sh verify${N}"
}

ping_t() {
  local out; out=$(eos "$2" "ping $3 repeat 3 timeout 1")
  if echo "$out" | grep -qE '[1-9][0-9]* received'; then ok "$1"; else nok "$1"; fi
}
ospf_full() { eos "$1" "show ip ospf neighbor" | grep -c FULL; }
estab()     { eos "$1" "show bgp evpn summary" | grep -c Estab; }

# number of BGP paths a node holds for a prefix in VRF RED
bgp_paths() {
  eos "$1" "show ip bgp $2 vrf $3 | json" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); sys.exit()
def walk(o):
    if isinstance(o,dict):
        if "bgpRoutePaths" in o and isinstance(o["bgpRoutePaths"],list):
            print(len(o["bgpRoutePaths"])); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(d); print(0)' 2>/dev/null
}
# number of VTEP next hops actually installed in the FIB
fib_vteps() { eos "$1" "show ip route vrf $3 $2" | grep -c "via VTEP"; }

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"
  echo "== Underlay (OSPF area 0) =="
  for n in spine1 spine2; do f=$(ospf_full $n)
    [[ ${f:-0} -eq 4 ]] && ok "$n OSPF FULL $f/4" || nok "$n OSPF FULL ${f:-0}/4"; done
  for n in "${CLIENTS[@]}"; do f=$(ospf_full $n)
    [[ ${f:-0} -eq 2 ]] && ok "$n OSPF FULL $f/2" || nok "$n OSPF FULL ${f:-0}/2"; done
  ping_t "leaf1 -> leaf2 VTEP 10.0.1.12 (loopback via OSPF)" leaf1 "10.0.1.12 source 10.0.1.11"
  ping_t "leaf1 -> bleaf2 VTEP 10.0.1.15"                    leaf1 "10.0.1.15 source 10.0.1.11"

  [[ $m == base ]] && { echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N} (overlay not built yet)"; return; }

  echo "== iBGP overlay (spines are route reflectors) =="
  for n in spine1 spine2; do e=$(estab $n)
    [[ ${e:-0} -eq 4 ]] && ok "$n EVPN sessions $e/4 (all clients)" || nok "$n EVPN sessions ${e:-0}/4"; done
  for n in "${CLIENTS[@]}"; do e=$(estab $n)
    [[ ${e:-0} -eq 2 ]] && ok "$n EVPN sessions $e/2 (both RRs)" || nok "$n EVPN sessions ${e:-0}/2"; done
  # a reflected route proves the RR is doing its job: leaf1 learns leaf2's MAC
  r=$(eos leaf1 "show bgp evpn route-type mac-ip" | grep -c "10.0.1.12")
  [[ ${r:-0} -ge 1 ]] && ok "leaf1 holds routes reflected from leaf2" \
    || nok "leaf1 holds no reflected leaf2 routes (check route-reflector-client on the spines)"
  # spines must never appear as a VTEP: iBGP preserves the next hop
  s=$(eos leaf1 "show vxlan vtep" | grep -cE '10\.0\.0\.(1|2)$')
  [[ ${s:-0} -eq 0 ]] && ok "no spine loopback in leaf1's VTEP list" \
    || nok "a spine appears as a VTEP on leaf1 (next-hop-self on an RR?)"

  echo "== Border egress =="
  for n in bleaf1 bleaf2; do v=$(eos $n "show ip bgp summary vrf $VRF_NAME" | grep -c Estab)
    [[ ${v:-0} -eq 1 ]] && ok "$n eBGP to wan up" || nok "$n eBGP to wan ${v:-0}/1"; done

  echo "== Data plane =="
  ping_t "h1 -> h2  same subnet, L2VNI 10010"      h1 10.10.10.102
  ping_t "h1 -> h3  routed, L3VNI 50001"           h1 10.10.20.103
  ping_t "h1 -> 203.0.113.10 via a border"         h1 203.0.113.10
  ping_t "h3 -> 203.0.113.10 via a border"         h3 203.0.113.10

  # What distinguishes the two modes is the number of DISTINCT EXITS, not the
  # number of BGP paths. Without add-path leaf1 still receives two paths, one
  # from each reflector, but both name bleaf1 as the next hop. The path count
  # is printed for context; the VTEP count is the assertion.
  echo "== Path visibility =="
  local bp fv
  bp=$(bgp_paths leaf1 0.0.0.0/0 "$VRF_NAME"); fv=$(fib_vteps leaf1 0.0.0.0/0 "$VRF_NAME")
  echo "  (leaf1 holds ${bp:-0} BGP paths for 0.0.0.0/0 and installs ${fv:-0} VTEP next hops)"
  if [[ $m == addpath ]]; then
    [[ ${fv:-0} -ge 2 ]] && ok "leaf1 installs $fv VTEP next hops: ECMP across both borders" \
      || nok "leaf1 installs ${fv:-0} VTEP next hops, want 2 (add-path on both reflectors?)"
    [[ ${bp:-0} -ge 4 ]] && ok "leaf1 holds $bp paths: both reflectors are sending both borders" \
      || nok "leaf1 holds ${bp:-0} paths, want 4 (2 borders x 2 reflectors) - is add-path on BOTH spines?"
  else
    [[ ${fv:-0} -eq 1 ]] && ok "leaf1 installs 1 VTEP next hop: both reflectors chose the same border" \
      || nok "leaf1 installs ${fv:-0} VTEP next hops, expected exactly 1 without add-path"
    [[ ${bp:-0} -eq 2 ]] && ok "leaf1 holds 2 paths, one per reflector, both naming bleaf1" \
      || nok "leaf1 holds ${bp:-0} paths, expected 2 (one from each reflector)"
  fi
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] ticket active (./lab.sh reveal | restore)${N}"
}

paths() {
  echo -e "${C}--- what each border originates ---${N}"
  for n in bleaf1 bleaf2; do
    echo "== $n: default learned from wan =="; eos $n "show ip bgp 0.0.0.0/0 vrf $VRF_NAME"
  done
  echo -e "${C}--- what the reflectors hold and send ---${N}"
  for n in spine1 spine2; do
    echo "== $n: type-5 default in EVPN =="
    eos $n "show bgp evpn route-type ip-prefix ipv4 0.0.0.0/0"
    echo "== $n: advertised to leaf1 =="
    eos $n "show bgp evpn neighbors 10.0.0.11 advertised-routes" | grep -A2 "0.0.0.0/0" | head -12
  done
  echo -e "${C}--- what a client actually ends up with ---${N}"
  echo "== leaf1: BGP table =="; eos leaf1 "show ip bgp 0.0.0.0/0 vrf $VRF_NAME"
  echo "== leaf1: FIB =="; eos leaf1 "show ip route vrf $VRF_NAME 0.0.0.0/0"
  echo -e "${Y}[i] Without add-path each RR sends one best path, so leaf1 sees one border.${N}"
}

ticket() {
  case $1 in
    1) eoscfg spine1 "router bgp 65000" "no neighbor 10.0.0.12 route-reflector-client"
       eoscfg spine2 "router bgp 65000" "no neighbor 10.0.0.12 route-reflector-client" ;;
    2) eoscfg spine1 "router bgp 65000" "address-family evpn" "neighbor OVERLAY next-hop-self" ;;
    3) eoscfg leaf1 "router ospf 1" "passive-interface Ethernet1" ;;
    4) eoscfg leaf2 "router ospf 1" "no network 10.1.0.0/16 area 0.0.0.0" "network 10.1.1.0/24 area 0.0.0.0" "network 10.1.2.0/24 area 0.0.0.9" ;;
    5) eoscfg leaf1 "router bgp 65000" "no neighbor OVERLAY send-community extended" ;;
    6) eoscfg spine2 "router bgp 65000" "address-family evpn" "no bgp additional-paths send any" ;;
    7) eoscfg leaf1 "router bgp 65000" "vrf RED" "maximum-paths 1" ;;
    8) eoscfg bleaf2 "router bgp 65000" "vrf RED" "no route-target export evpn 50001:50001" "route-target export evpn 50001:50099" ;;
    *) echo "tickets: 1-8 or random"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == addpath ]] || echo -e "${Y}[!] tickets assume the addpath baseline (./lab.sh deploy addpath)${N}"
  local t=$1; [[ $t == random ]] && t=$(( (RANDOM % 8) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  [[ $1 == random ]] && echo "[*] blind ticket injected. Start with ./lab.sh verify" || echo "[*] ticket $t injected. See docs/TICKETS.md"
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=addpath
  for n in "${NODES[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  rm -f "$STATE"; echo "[*] baseline restored. OSPF and the overlay need ~60s. Then verify."
}

case ${1:-} in
  deploy)  deploy "${2:-addpath}" ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)  verify ;;
  paths)   paths ;;
  break)   do_break "${2:?ticket number or random}" ;;
  reveal)  [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore) restore ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,11p' "$0" ;;
esac
