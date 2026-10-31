#!/usr/bin/env bash
# bgp-lab03 control script
#   ./lab.sh deploy [base|solution]  stage configs and deploy
#   ./lab.sh destroy                 tear down
#   ./lab.sh verify                  fabric, bonds, ESI/MLAG state, aliasing, data plane
#   ./lab.sh compare                 print the ESI-LAG vs MLAG state side by side
#   ./lab.sh fail <leaf1|leaf2|leaf3|leaf4>   shut that leaf's host-facing link
#   ./lab.sh unfail <leaf>           bring it back
#   ./lab.sh converge <hm1|hm2>      measure loss across a link failure (uses fail/unfail)
#   ./lab.sh break <1-8|random>      inject a ticket (solution baseline)
#   ./lab.sh reveal | restore        show / clear the active ticket
#   ./lab.sh cli <node>              Cli | hm1,hm2,hs1,hs2 -> sh
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab03; TOPO=bgp-lab03.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
CEOS=(spine1 spine2 leaf1 leaf2 leaf3 leaf4)
STATE="$DIR/.active_ticket"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
mode() { cat "$DIR/.mode" 2>/dev/null || echo unknown; }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

# host-facing port per leaf (ESI members and MLAG members both sit on Ethernet3)
hostport() { echo Ethernet3; }

check_bonding() {
  if ! lsmod 2>/dev/null | grep -q '^bonding' && [ ! -d /sys/class/net/bonding_masters ]; then
    echo -e "${Y}[!] bonding kernel module not loaded. Run: sudo modprobe bonding${N}"
    echo -e "${Y}    Without it hm1/hm2 cannot form bond0 and every multihoming test fails.${N}"
    read -r -p "    Load it now? [Y/n] " a
    [[ ${a:-Y} =~ ^[Yy]$ ]] && sudo modprobe bonding && echo "[*] bonding loaded"
  fi
}

wait_ceos() {
  printf "[*] waiting for cEOS nodes"
  for n in "${CEOS[@]}"; do
    for _ in $(seq 1 60); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
}

deploy() {
  local m=${1:-solution}
  [[ -d configs/$m ]] || { echo "mode: base|solution"; exit 1; }
  check_bonding
  cp -f configs/"$m"/*.cfg configs/active/; echo "$m" > "$DIR/.mode"
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  wait_ceos
  echo -e "${Y}[i] mode=$m. Allow ~90s for LACP, MLAG and EVPN to settle, then ./lab.sh verify${N}"
}

bond_up() { # host -> number of bond members reported active by the kernel
  docker exec "$P-$1" sh -c 'cat /proc/net/bonding/bond0 2>/dev/null | grep -c "MII Status: up"' 2>/dev/null | tr -d '\r'
}
ping_t() { if docker exec "$P-$2" ping -c 3 -W 1 -q "$3" >/dev/null 2>&1; then ok "$1"; else nok "$1"; fi; }

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"
  echo "== Fabric =="
  for n in spine1 spine2; do u=$(eos $n "show ip bgp summary"|grep -c Estab); e=$(eos $n "show bgp evpn summary"|grep -c Estab)
    [[ $u -eq 4 && $e -eq 4 ]] && ok "$n underlay $u/4 evpn $e/4" || nok "$n underlay $u/4 evpn $e/4"; done
  for n in leaf1 leaf2 leaf3 leaf4; do e=$(eos $n "show bgp evpn summary"|grep -c Estab)
    [[ $e -eq 2 ]] && ok "$n evpn $e/2" || nok "$n evpn $e/2"; done

  echo "== Host bonds =="
  for h in hm1 hm2; do b=$(bond_up $h)
    [[ ${b:-0} -ge 3 ]] && ok "$h bond0 both members up" || nok "$h bond0 members up (want 2 slaves + master, got ${b:-0} 'MII Status: up')"; done

  [[ $m == base ]] && { echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N} (redundancy not built yet)"; return; }

  echo "== EVPN multihoming (leaf1 + leaf2) =="
  for n in leaf1 leaf2; do
    es=$(eos $n "show bgp evpn route-type ethernet-segment" | grep -c '0011:1111')
    [[ ${es:-0} -ge 1 ]] && ok "$n sees the type-4 ES route" || nok "$n sees no type-4 ES route"
  done
  n_df=0
  for n in leaf1 leaf2; do
    eos $n "show evpn ethernet-segment" | grep -qiE '\bDF\b|elected' && n_df=$((n_df+1))
  done
  [[ $n_df -ge 1 ]] && ok "DF election has run on the ES" || nok "no DF state on the ES (check: show evpn ethernet-segment)"
  a=$(eos leaf3 "show bgp evpn route-type auto-discovery" | grep -c '0011:1111')
  [[ ${a:-0} -ge 2 ]] && ok "leaf3 imports type-1 A-D routes from both ES peers ($a)" \
                      || nok "leaf3 imports ${a:-0} type-1 A-D routes (want >=2: per-ES + per-EVI from each peer)"

  echo "== MLAG (leaf3 + leaf4) =="
  for n in leaf3 leaf4; do
    s=$(eos $n "show mlag" | awk '/^state/{print $2}')
    ns=$(eos $n "show mlag" | awk '/negotiation status/{print $NF}')
    [[ $s == active || $s == Active ]] && ok "$n MLAG state=$s negotiation=$ns" || nok "$n MLAG state=${s:-unknown}"
    cfg=$(eos $n "show mlag config-sanity" | grep -ciE 'inconsisten')
    [[ ${cfg:-1} -eq 0 ]] && ok "$n MLAG config-sanity clean" || nok "$n MLAG config-sanity reports inconsistencies"
  done
  v=$(eos leaf1 "show vxlan vtep" | grep -c '10.0.1.34')
  [[ ${v:-0} -ge 1 ]] && ok "leaf1 sees the MLAG pair as one shared VTEP 10.0.1.34" || nok "leaf1 does not see VTEP 10.0.1.34"

  echo "== Data plane =="
  ping_t "hm1 -> hm2   ESI-LAG host to MLAG host (L2VNI 10010)" hm1 10.10.10.102
  ping_t "hm1 -> hs1   ESI-LAG host to orphan on leaf1"         hm1 10.10.10.103
  ping_t "hm2 -> hs1   MLAG host to orphan on leaf1"            hm2 10.10.10.103
  ping_t "hm1 -> 10.10.20.104  routed via L3VNI 50001"          hm1 10.10.20.104
  ping_t "hm2 -> 10.10.20.104  routed via L3VNI 50001"          hm2 10.10.20.104
  ping_t "hm1 -> anycast gateway"                               hm1 10.10.10.1
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] ticket active (./lab.sh reveal | restore)${N}"
}

compare() {
  echo -e "${C}======== EVPN multihoming: leaf1 + leaf2 ========${N}"
  echo "--- leaf1 show evpn ethernet-segment ---"; eos leaf1 "show evpn ethernet-segment"
  echo "--- leaf2 show evpn ethernet-segment ---"; eos leaf2 "show evpn ethernet-segment"
  echo "--- type-4 (ES / DF election) seen by leaf1 ---"; eos leaf1 "show bgp evpn route-type ethernet-segment"
  echo "--- type-1 (A-D: aliasing + mass withdraw) seen by leaf3 ---"; eos leaf3 "show bgp evpn route-type auto-discovery"
  echo
  echo -e "${C}======== MLAG: leaf3 + leaf4 ========${N}"
  echo "--- leaf3 show mlag ---"; eos leaf3 "show mlag"
  echo "--- leaf3 show mlag interfaces ---"; eos leaf3 "show mlag interfaces"
  echo "--- leaf3 show mlag config-sanity ---"; eos leaf3 "show mlag config-sanity"
  echo
  echo -e "${C}======== How the rest of the fabric sees each pair ========${N}"
  echo "--- leaf1 VTEP list (MLAG pair should appear once, as 10.0.1.34) ---"; eos leaf1 "show vxlan vtep"
  echo "--- leaf3 VTEP list (ES pair should appear twice, 10.0.1.11 and 10.0.1.12) ---"; eos leaf3 "show vxlan vtep"
}

do_fail()   { eoscfg "$1" "interface $(hostport)" "shutdown"; echo "[*] $1 $(hostport) shut"; }
do_unfail() { eoscfg "$1" "interface $(hostport)" "no shutdown"; echo "[*] $1 $(hostport) no shut"; }

converge() {
  local host=$1 leafa leafb target
  case $host in
    hm1) leafa=leaf1; target=10.10.10.103 ;;   # ESI-LAG host -> orphan on leaf1
    hm2) leafa=leaf3; target=10.10.10.103 ;;   # MLAG host    -> orphan on leaf1
    *) echo "converge hm1|hm2"; exit 1 ;;
  esac
  echo "[*] $host -> $target, 200 pings at 50ms while $leafa's host link drops and returns"
  docker exec -d "$P-$host" sh -c "ping -i 0.05 -c 200 -q $target > /tmp/conv.txt 2>&1"
  sleep 2; do_fail $leafa; sleep 4; do_unfail $leafa; sleep 8
  echo "--- result ---"; docker exec "$P-$host" cat /tmp/conv.txt
  echo -e "${Y}[i] loss here is roughly (packets lost x 50ms). Compare hm1 and hm2.${N}"
}

ticket() {
  case $1 in
    1) eoscfg leaf2 "interface Port-Channel1" "evpn ethernet-segment" "identifier 0011:1111:1111:1111:2222" ;;
    2) eoscfg leaf2 "interface Port-Channel1" "lacp system-id 0022.2222.2222" ;;
    3) eoscfg leaf2 "interface Port-Channel1" "evpn ethernet-segment" "no route-target import" ;;
    4) eoscfg leaf4 "interface Loopback1" "ip address 10.0.1.44/32" ;;
    5) eoscfg leaf4 "mlag configuration" "domain-id MLAG99" ;;
    6) eoscfg leaf3 "interface Port-Channel1000" "no switchport trunk group MLAGPEER" ;;
    7) eoscfg leaf4 "interface Port-Channel2" "no mlag 2" ;;
    8) eoscfg leaf1 "router bgp 65101" "no neighbor EVPN send-community extended" ;;
    *) echo "tickets: 1-8 or random"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == solution ]] || echo -e "${Y}[!] tickets assume the solution baseline${N}"
  local t=$1; [[ $t == random ]] && t=$(( (RANDOM % 8) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  [[ $1 == random ]] && echo "[*] blind ticket injected. Start with ./lab.sh verify" || echo "[*] ticket $t injected. See docs/TICKETS.md"
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=solution
  for n in "${CEOS[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  rm -f "$STATE"; echo "[*] baseline restored. MLAG and LACP need ~60s. Then verify."
}
cli() { case $1 in h*) docker exec -it "$P-$1" sh ;; *) docker exec -it "$P-$1" Cli ;; esac; }

case ${1:-} in
  deploy)   deploy "${2:-solution}" ;;
  destroy)  $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)   verify ;;
  compare)  compare ;;
  fail)     do_fail "${2:?leaf}" ;;
  unfail)   do_unfail "${2:?leaf}" ;;
  converge) converge "${2:?hm1|hm2}" ;;
  break)    do_break "${2:?ticket number or random}" ;;
  reveal)   [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore)  restore ;;
  cli)      cli "${2:?node}" ;;
  status)   $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,14p' "$0" ;;
esac
