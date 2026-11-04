#!/usr/bin/env bash
# bgp-lab07 control script  (multi-VRF EVPN-VXLAN)
#   ./lab.sh deploy <base|solution>  stage configs and deploy (one mode)
#   ./lab.sh destroy                 tear down
#   ./lab.sh verify                  fabric, leaking, fusion, AND isolation
#   ./lab.sh matrix                  test every host pair, print the real policy matrix
#   ./lab.sh rts                     the import/export matrix as the devices see it
#   ./lab.sh leak <vrf> <prefix>     where a prefix came from and which RT carried it
#   ./lab.sh break <1-8|random>      inject a ticket (solution baseline)
#   ./lab.sh reveal | restore        show / clear the active ticket
#   ./lab.sh cli <node>              Cli on any node
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab07; TOPO=bgp-lab07.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(spine1 spine2 leaf1 leaf2 bleaf1 fw hR1 hB1 hR2 hG1 hS1)
LEAVES=(leaf1 leaf2 bleaf1)
STATE="$DIR/.active_ticket"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
mode() { cat "$DIR/.mode" 2>/dev/null || echo unknown; }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

declare -A HOSTIP=( [hR1]=10.10.10.101 [hB1]=10.20.20.101 [hR2]=10.10.10.102 \
                    [hG1]=10.30.30.101 [hS1]=10.100.100.10 )
declare -A HOSTVRF=( [hR1]=RED [hB1]=BLUE [hR2]=RED [hG1]=GREEN [hS1]=SHARED )

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
  echo -e "${Y}[i] mode=$m. Allow ~90s for EVPN to settle, then ./lab.sh verify${N}"
}

reaches() { eos "$1" "ping $2 repeat 2 timeout 1" | grep -qE '[1-9][0-9]* received'; }
# must work
ping_t()   { if reaches "$2" "$3"; then ok "$1"; else nok "$1"; fi; }
# must NOT work. A multi-tenant design is only correct if these fail.
noping_t() { if reaches "$2" "$3"; then nok "ISOLATION BREACH: $1"; else ok "blocked (as designed): $1"; fi; }

estab() { eos "$1" "show bgp evpn summary" | grep -c Estab; }

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"
  echo "== Fabric =="
  for n in spine1 spine2; do u=$(eos $n "show ip bgp summary" | grep -c Estab); e=$(estab $n)
    [[ $u -eq 3 && $e -eq 3 ]] && ok "$n underlay $u/3 evpn $e/3" || nok "$n underlay $u/3 evpn $e/3"; done
  for n in "${LEAVES[@]}"; do e=$(estab $n)
    [[ ${e:-0} -eq 2 ]] && ok "$n evpn $e/2" || nok "$n evpn ${e:-0}/2"; done

  echo "== Intra-VRF (the baseline that must work before any leaking) =="
  ping_t "hR1 -> hR2   RED, same subnet, L2VNI 10010 stretched"  hR1 10.10.10.102
  ping_t "hR2 -> 10.10.11.1  RED, other subnet, L3VNI 50001"     hR2 10.10.11.1
  ping_t "hR1 -> its anycast gateway"                            hR1 10.10.10.1
  ping_t "hG1 -> its anycast gateway"                            hG1 10.30.30.1

  if [[ $m == base ]]; then
    echo "== Isolation in base mode: every VRF sees only itself =="
    noping_t "hR1 -> hS1 (no leaking configured yet)" hR1 10.100.100.10
    noping_t "hR1 -> hB1 (no fusion configured yet)"  hR1 10.20.20.101
    noping_t "hG1 -> hS1 (no leaking configured yet)" hG1 10.100.100.10
    echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}. Now build the policy: docs/TASKS.md Part A."
    return
  fi

  echo "== Shared services by RT leaking (no device in the path) =="
  ping_t "hR1 -> hS1   RED imports 50099:50099"    hR1 10.100.100.10
  ping_t "hR2 -> hS1   RED, from the other leaf"   hR2 10.100.100.10
  ping_t "hB1 -> hS1   BLUE imports 50099:50099"   hB1 10.100.100.10
  ping_t "hG1 -> hS1   GREEN imports 50099:50099"  hG1 10.100.100.10
  ping_t "hS1 -> hR1   SHARED imports RED's RT"    hS1 10.10.10.101
  ping_t "hS1 -> hB1   SHARED imports BLUE's RT"   hS1 10.20.20.101
  ping_t "hS1 -> hG1   SHARED imports GREEN's RT"  hS1 10.30.30.101

  echo "== Inter-tenant by fusion (RED <-> BLUE, through fw) =="
  ping_t "hR1 -> hB1   RED to BLUE via fw"         hR1 10.20.20.101
  ping_t "hB1 -> hR1   BLUE to RED via fw"         hB1 10.10.10.101
  ping_t "hB1 -> hR2   BLUE to RED on the far leaf" hB1 10.10.10.102
  local hops
  hops=$(eos hR1 "traceroute 10.20.20.101" 2>/dev/null | awk 'NR>1{print $2}' | tr '\n' ' ')
  [[ $hops =~ 172\.16\.[12]\.2 ]] && ok "the RED-to-BLUE path really transits fw [$hops]" \
    || nok "RED-to-BLUE does not transit fw [$hops] - is there a leak shortcut?"

  echo "== Isolation: the half of the design you get paid for =="
  noping_t "hG1 -> hR1   GREEN must not reach RED"             hG1 10.10.10.101
  noping_t "hG1 -> hB1   GREEN must not reach BLUE"            hG1 10.20.20.101
  noping_t "hR1 -> hG1   RED must not reach GREEN"             hR1 10.30.30.101
  noping_t "hB1 -> hG1   BLUE must not reach GREEN"            hB1 10.30.30.101
  r=$(eos leaf2 "show ip route vrf GREEN 10.10.10.0/24" | grep -c "10.10.10.0/24")
  [[ ${r:-0} -eq 0 ]] && ok "GREEN's table has no RED prefix (SHARED does not re-export what it imports)" \
    || nok "GREEN holds a RED prefix: the hub is re-exporting imported routes"
  r=$(eos leaf1 "show ip route vrf RED 10.30.30.0/24" | grep -c "10.30.30.0/24")
  [[ ${r:-0} -eq 0 ]] && ok "RED's table has no GREEN prefix" || nok "RED holds a GREEN prefix"
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] ticket active (./lab.sh reveal | restore)${N}"
}

matrix() {
  local hosts=(hR1 hR2 hB1 hG1 hS1)
  echo -e "${C}Reachability matrix. Rows are sources, columns destinations.${N}"
  echo -e "${C}Compare this against the policy table in the README. Any cell that${N}"
  echo -e "${C}disagrees is either a broken service or a security finding.${N}"
  printf "\n%-22s" "from \\ to"
  for d in "${hosts[@]}"; do printf "%-14s" "$d(${HOSTVRF[$d]:0:3})"; done; echo
  for s in "${hosts[@]}"; do
    printf "%-22s" "$s (${HOSTVRF[$s]})"
    for d in "${hosts[@]}"; do
      if [[ $s == "$d" ]]; then printf "%-14s" "-"
      elif reaches "$s" "${HOSTIP[$d]}"; then printf "${G}%-14s${N}" "reach"
      else printf "${R}%-14s${N}" "blocked"; fi
    done; echo
  done
  echo
  echo -e "${Y}[i] Intended: tenants reach SHARED both ways; RED and BLUE reach each"
  echo -e "    other through fw; GREEN reaches SHARED only; nothing reaches GREEN.${N}"
}

rts() {
  echo -e "${C}The import/export matrix as the devices actually hold it.${N}"
  echo -e "${C}This is the security policy. Read it as one.${N}"
  for n in leaf1 leaf2 bleaf1; do
    echo
    echo -e "${C}=== $n ===${N}"
    eos $n "show running-config section vrf" 2>/dev/null | grep -E "^ *(vrf|route-target)" \
      || eos $n "show running-config | section router bgp" | grep -E "^ *(vrf |route-target)"
  done
  echo
  echo -e "${C}=== VRF route counts per leaf ===${N}"
  for n in leaf1 leaf2; do
    for v in RED BLUE GREEN SHARED; do
      cnt=$(eos $n "show ip route vrf $v summary" 2>/dev/null | grep -iE "^ *bgp|total" | head -2 | tr '\n' ' ')
      [[ -n $cnt ]] && echo "  $n vrf $v: $cnt"
    done
  done
}

leak() {
  local vrf=${1:?vrf} pfx=${2:?prefix}
  echo -e "${C}=== $vrf route table entry for $pfx ===${N}"
  eos leaf2 "show ip route vrf $vrf $pfx"
  echo -e "${C}=== the EVPN route behind it, and the RT that carried it ===${N}"
  eos leaf2 "show bgp evpn route-type ip-prefix ipv4 $pfx detail"
  echo -e "${Y}[i] The extended-community list names the RT. If $vrf imports that RT,"
  echo -e "    the prefix lands here. That one line is the entire access policy.${N}"
}

ticket() {
  case $1 in
    1) eoscfg leaf1 "router bgp 65101" "vrf RED" "route-target import evpn 50003:50003"
       eoscfg leaf2 "router bgp 65102" "vrf RED" "route-target import evpn 50003:50003" ;;
    2) eoscfg leaf2 "router bgp 65102" "vrf SHARED" "no route-target import evpn 50002:50002" ;;
    3) eoscfg leaf2 "router bgp 65102" "vrf SHARED" "no redistribute connected" ;;
    4) eoscfg leaf2 "interface Vxlan1" "no vxlan vrf RED vni 50001" "vxlan vrf RED vni 50011" ;;
    5) eoscfg fw "router bgp 65200" "no neighbor 172.16.1.1 remove-private-as all" "no neighbor 172.16.2.1 remove-private-as all" ;;
    6) eoscfg bleaf1 "router bgp 65104" "vrf RED" "no route-target import evpn 50001:50001" ;;
    7) eoscfg leaf2 "no ip virtual-router mac-address" ;;
    8) eoscfg leaf1 "router bgp 65101" "vlan 10" "no route-target both 10010:10010" "route-target both 10010:10019" ;;
    *) echo "tickets: 1-8 or random"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == solution ]] || echo -e "${Y}[!] tickets assume the solution baseline${N}"
  local t=$1; [[ $t == random ]] && t=$(( (RANDOM % 8) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  [[ $1 == random ]] && echo "[*] blind ticket injected. Start with ./lab.sh verify, then ./lab.sh matrix" \
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
  matrix)  matrix ;;
  rts)     rts ;;
  leak)    leak "${2:-SHARED}" "${3:-10.10.10.0/24}" ;;
  break)   do_break "${2:?ticket number or random}" ;;
  reveal)  [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore) restore ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,12p' "$0" ;;
esac
