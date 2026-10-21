#!/usr/bin/env bash
# bgp-lab01 control script
#   ./lab.sh deploy [base|solution]   stage configs, deploy, bootstrap isp1
#   ./lab.sh destroy                  tear down (cleanup)
#   ./lab.sh verify                   control-plane + data-plane checks
#   ./lab.sh break <1-8|random>       inject a ticket (solution baseline required)
#   ./lab.sh reveal                   show which ticket is active
#   ./lab.sh restore                  roll every node back to the solution baseline
#   ./lab.sh cli <node>               shell into a node (Cli / vtysh / sh)
#   ./lab.sh status                   containerlab inspect
set -uo pipefail

LAB=bgp-lab01
TOPO=bgp-lab01.clab.yml
P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
CEOS=(spine1 spine2 leaf1 leaf2 leaf3 bleaf1)
LEAVES=(leaf1 leaf2 leaf3 bleaf1)
STATE="$DIR/.active_ticket"
CLAB="sudo containerlab"

G='\033[32m'; R='\033[31m'; Y='\033[33m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*"; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }
vty()    { docker exec "$P-isp1" vtysh "$@"; }

wait_ceos() {
  printf "[*] waiting for cEOS nodes"
  for n in "${CEOS[@]}"; do
    for _ in $(seq 1 60); do
      docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break
      printf "."; sleep 5
    done
  done
  echo " ok"
}

wait_isp() {
  printf "[*] waiting for SONiC (isp1)"
  for _ in $(seq 1 90); do
    if docker exec "$P-isp1" bash -c "redis-cli -n 0 exists PORT_TABLE:Ethernet4 | grep -q 1 && vtysh -c 'show version' >/dev/null 2>&1"; then
      echo " ok"; return 0
    fi
    printf "."; sleep 5
  done
  echo " timeout (check: docker logs $P-isp1)"; return 1
}

isp_setup() { docker exec "$P-isp1" bash /isp/isp-setup.sh; }

deploy() {
  local mode=${1:-solution}
  [[ -d configs/$mode ]] || { echo "mode must be base|solution"; exit 1; }
  cp -f configs/"$mode"/*.cfg configs/active/
  echo "$mode" > "$DIR/.mode"
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  wait_ceos; wait_isp && isp_setup
  echo -e "${Y}[i] mode=$mode. Allow ~60s for BGP/EVPN convergence, then ./lab.sh verify${N}"
}

ping_t() { # desc src dst [size]
  local sz=${4:-56}
  if docker exec "$P-$2" ping -c 3 -W 1 -s "$sz" -q "$3" >/dev/null 2>&1; then ok "$1"; else nok "$1"; fi
}

verify() {
  echo "== Control plane =="
  for n in spine1 spine2; do
    u=$(eos "$n" "show ip bgp summary" 2>/dev/null | grep -c Estab)
    e=$(eos "$n" "show bgp evpn summary" 2>/dev/null | grep -c Estab)
    [[ $u -eq 4 && $e -eq 4 ]] && ok "$n underlay $u/4 evpn $e/4" || nok "$n underlay $u/4 evpn $e/4"
  done
  for n in "${LEAVES[@]}"; do
    u=$(eos "$n" "show ip bgp summary" 2>/dev/null | grep -c Estab)
    e=$(eos "$n" "show bgp evpn summary" 2>/dev/null | grep -c Estab)
    [[ $u -eq 2 && $e -eq 2 ]] && ok "$n underlay $u/2 evpn $e/2" || nok "$n underlay $u/2 evpn $e/2"
  done
  b=$(vty -c "show bgp ipv4 unicast summary" 2>/dev/null | awk '/^172\.16\.[12]\.1/ && $10 ~ /^[0-9]+$/' | wc -l)
  [[ $b -eq 2 ]] && ok "isp1 eBGP to bleaf1 RED+BLUE" || nok "isp1 eBGP to bleaf1 RED+BLUE (check: ./lab.sh cli isp1 -> show bgp summary)"

  echo "== Data plane =="
  ping_t "h1 -> anycast GW 10.10.10.1"                 h1 10.10.10.1
  ping_t "h1 -> h2   RED  L2VNI 10010 (bridged)"       h1 10.10.10.102
  ping_t "h1 -> h3   RED  L3VNI 50001 (symmetric IRB)" h1 10.10.20.103
  ping_t "h2 -> h3   RED  L3VNI 50001"                 h2 10.10.20.103
  ping_t "h5 -> h4   BLUE L2VNI 10030"                 h5 10.30.30.104
  ping_t "h1 -> 203.0.113.10 RED  internet (type-5 default)"  h1 203.0.113.10
  ping_t "h4 -> 203.0.113.10 BLUE internet (type-5 default)"  h4 203.0.113.10
  ping_t "h1 -> h4   RED->BLUE via fusion isp1"        h1 10.30.30.104
  ping_t "h3 -> h5   RED->BLUE via fusion isp1"        h3 10.30.30.105
  ping_t "h1 -> h2   1500B IP packet over VXLAN"       h1 10.10.10.102 1472
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] a ticket is active (./lab.sh reveal | restore)${N}"
}

ticket() {
  case $1 in
    1) eoscfg leaf3 "router bgp 65103" "no neighbor EVPN update-source" ;;
    2) eoscfg leaf2 "router bgp 65102" "vlan 10" "no route-target both 10010:10010" "route-target both 10010:10011" ;;
    3) eoscfg leaf3 "router bgp 65103" "vrf RED" "no route-target import evpn 50001:50001" "route-target import evpn 50001:50011" ;;
    4) eoscfg leaf1 "router bgp 65101" "no neighbor EVPN send-community" ;;
    5) eoscfg leaf3 "no ip virtual-router mac-address" ;;
    6) eoscfg leaf2 "ip prefix-list PL-LOOPBACKS" "no seq 20" ;;
    7) vty -c "configure terminal" -c "router bgp 65000" -c "address-family ipv4 unicast" \
           -c "no neighbor 172.16.1.1 remove-private-AS all" -c "no neighbor 172.16.2.1 remove-private-AS all" \
           -c "end" -c "clear ip bgp * soft out" >/dev/null ;;
    8) eoscfg spine1 "router bgp 65100" "no neighbor EVPN next-hop-unchanged" ;;
    *) echo "tickets: 1-8 or random"; exit 1 ;;
  esac
}

do_break() {
  [[ "$(cat "$DIR/.mode" 2>/dev/null)" == "solution" ]] || echo -e "${Y}[!] tickets assume the solution baseline${N}"
  local t=$1
  [[ $t == random ]] && t=$(( (RANDOM % 8) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  if [[ $1 == random ]]; then echo "[*] blind ticket injected. Symptoms: docs/TICKETS.md. Start with ./lab.sh verify"
  else echo "[*] ticket $t injected. See docs/TICKETS.md"; fi
}

restore() {
  for n in "${CEOS[@]}"; do
    docker cp "configs/solution/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored"
  done
  isp_setup >/dev/null && echo "  isp1 restored"
  rm -f "$STATE"; echo "[*] solution baseline restored. Allow ~30s, then verify."
}

cli() {
  case $1 in
    isp1) docker exec -it "$P-isp1" vtysh ;;
    h[0-9]) docker exec -it "$P-$1" sh ;;
    *) docker exec -it "$P-$1" Cli ;;
  esac
}

case ${1:-} in
  deploy)  deploy "${2:-solution}" ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)  verify ;;
  break)   do_break "${2:?ticket number or random}" ;;
  reveal)  [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore) restore ;;
  cli)     cli "${2:?node}" ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,11p' "$0" ;;
esac
