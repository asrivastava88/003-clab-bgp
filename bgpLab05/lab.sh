#!/usr/bin/env bash
# bgp-lab05 control script
#   ./lab.sh deploy <base|numbered|unnumbered>  stage configs and deploy (one mode)
#   ./lab.sh destroy                            tear down
#   ./lab.sh verify                             underlay, RFC 8950 next hops, overlay, data plane
#   ./lab.sh nexthops                           show how IPv4 rides IPv6 link-local, end to end
#   ./lab.sh diff [leaf|modes]                  leaf-to-leaf, or numbered-vs-unnumbered, config diff
#   ./lab.sh break <1-8|random>                 inject a ticket (unnumbered baseline)
#   ./lab.sh reveal | restore                   show / clear the active ticket
#   ./lab.sh cli <node>                         Cli on any node (every node is cEOS)
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab05; TOPO=bgp-lab05.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(spine1 spine2 leaf1 leaf2 leaf3 h1 h2 h3)
LEAVES=(leaf1 leaf2 leaf3)
STATE="$DIR/.active_ticket"; CLAB="sudo containerlab"
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
  local m=${1:-unnumbered}
  [[ -d configs/$m ]] || { echo "mode: base|numbered|unnumbered"; exit 1; }
  cp -f configs/"$m"/*.cfg configs/active/; echo "$m" > "$DIR/.mode"
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  wait_nodes
  echo -e "${Y}[i] mode=$m. Allow ~90s for ND, BGP and EVPN to settle, then ./lab.sh verify${N}"
}

ping_t() {
  local out; out=$(eos "$2" "ping $3 repeat 3 timeout 1")
  if echo "$out" | grep -qE '[1-9][0-9]* received'; then ok "$1"; else nok "$1"; fi
}
estab_v4()   { eos "$1" "show ip bgp summary"   | grep -c Estab; }
estab_evpn() { eos "$1" "show bgp evpn summary" | grep -c Estab; }

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"

  if [[ $m == unnumbered ]]; then
    echo "== IPv6 plumbing (no IPv4 on any fabric link) =="
    for n in spine1 leaf1; do
      g=$(eos $n "show running-config | include ^ipv6 unicast-routing" | grep -c "ipv6 unicast-routing")
      [[ ${g:-0} -ge 1 ]] && ok "$n has ipv6 unicast-routing" || nok "$n missing ipv6 unicast-routing"
    done
    for n in "${LEAVES[@]}"; do
      nd=$(eos $n "show ipv6 neighbors" | grep -c "fe80")
      [[ ${nd:-0} -ge 2 ]] && ok "$n has $nd IPv6 link-local neighbors" \
        || nok "$n has ${nd:-0} IPv6 link-local neighbors, want 2 (check: ipv6 enable on Et1-2)"
    done
    v4=$(eos leaf1 "show ip interfaces brief" | grep -cE "^Et[12] ")
    [[ ${v4:-0} -eq 0 ]] && ok "leaf1 fabric links carry no IPv4 address" \
      || nok "leaf1 has IPv4 on a fabric link; this is supposed to be unnumbered"
  fi

  echo "== Underlay eBGP =="
  for n in spine1 spine2; do u=$(estab_v4 $n)
    [[ ${u:-0} -eq 3 ]] && ok "$n underlay $u/3" || nok "$n underlay ${u:-0}/3"; done
  for n in "${LEAVES[@]}"; do u=$(estab_v4 $n)
    [[ ${u:-0} -eq 2 ]] && ok "$n underlay $u/2" || nok "$n underlay ${u:-0}/2"; done

  if [[ $m == unnumbered ]]; then
    echo "== RFC 8950: IPv4 prefixes with IPv6 next hops =="
    r=$(eos leaf1 "show ip route 10.0.1.12" | grep -ci "fe80")
    [[ ${r:-0} -ge 1 ]] && ok "leaf1's route to VTEP 10.0.1.12 resolves via an fe80:: next hop" \
      || nok "leaf1's route to 10.0.1.12 has no fe80:: next hop (check next-hop address-family ipv6 originate)"
    e=$(eos leaf1 "show ip bgp 10.0.1.12/32" | grep -ci "fe80")
    [[ ${e:-0} -ge 1 ]] && ok "the BGP path for 10.0.1.12/32 carries an IPv6 next hop" \
      || nok "the BGP path for 10.0.1.12/32 carries no IPv6 next hop"
  fi

  echo "== Loopback reachability (what VXLAN actually needs) =="
  ping_t "leaf1 -> leaf2 VTEP 10.0.1.12" leaf1 "10.0.1.12 source 10.0.1.11"
  ping_t "leaf1 -> leaf3 VTEP 10.0.1.13" leaf1 "10.0.1.13 source 10.0.1.11"

  [[ $m == base ]] && { echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N} (nothing built yet)"; return; }

  echo "== EVPN overlay (Loopback0 to Loopback0, identical in both modes) =="
  for n in spine1 spine2; do e=$(estab_evpn $n)
    [[ ${e:-0} -eq 3 ]] && ok "$n evpn $e/3" || nok "$n evpn ${e:-0}/3"; done
  for n in "${LEAVES[@]}"; do e=$(estab_evpn $n)
    [[ ${e:-0} -eq 2 ]] && ok "$n evpn $e/2" || nok "$n evpn ${e:-0}/2"; done
  s=$(eos leaf1 "show vxlan vtep" | grep -cE '10\.0\.0\.(1|2)$')
  [[ ${s:-0} -eq 0 ]] && ok "no spine loopback in leaf1's VTEP list" \
    || nok "a spine appears as a VTEP on leaf1 (next-hop-unchanged missing?)"
  # leaf1 and leaf2 share L2VNI 10010. leaf3 has only VLAN 20, so it shares no
  # bridge domain with anyone and leaf1 reaches it through the L3VNI alone.
  # An L3VNI-only peer does not appear in "show vxlan vtep", so test the two
  # tunnel types separately instead of counting one list.
  t=$(eos leaf1 "show vxlan vtep" | grep -c "10.0.1.12")
  [[ ${t:-0} -ge 1 ]] && ok "leaf1 has an L2VNI tunnel to leaf2 (VTEP 10.0.1.12)" \
    || nok "leaf1 has no L2VNI tunnel to leaf2 (check vlan 10 route-target on both)"
  t=$(eos leaf1 "show ip route vrf RED 10.10.20.0/24" | grep -c "10.0.1.13")
  [[ ${t:-0} -ge 1 ]] && ok "leaf1 reaches leaf3 through the L3VNI (VTEP 10.0.1.13)" \
    || nok "leaf1's VRF RED route to 10.10.20.0/24 does not resolve via VTEP 10.0.1.13"

  echo "== Data plane =="
  ping_t "h1 -> h2  same subnet, L2VNI 10010 over VXLAN"  h1 10.10.10.102
  ping_t "h1 -> h3  routed, L3VNI 50001"                  h1 10.10.20.103
  ping_t "h2 -> h3  routed, L3VNI 50001"                  h2 10.10.20.103
  ping_t "h1 -> anycast gateway"                          h1 10.10.10.1
  # ping_t "h1 -> h2  1500-byte IP packet over VXLAN"       h1 "10.10.10.102 size 1472 df-bit"
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] ticket active (./lab.sh reveal | restore)${N}"
}

nexthops() {
  echo -e "${C}--- 1. the link has no IPv4 address, only link-local IPv6 ---${N}"
  eos leaf1 "show ip interfaces brief" | head -8
  eos leaf1 "show ipv6 interface brief" | head -10
  echo -e "${C}--- 2. the BGP session is named by interface, not by address ---${N}"
  eos leaf1 "show ip bgp summary"
  echo -e "${C}--- 3. the IPv4 loopback arrives with an IPv6 link-local next hop ---${N}"
  eos leaf1 "show ip bgp 10.0.1.12/32"
  echo -e "${C}--- 4. the FIB keeps that next hop and resolves it through ND ---${N}"
  eos leaf1 "show ip route 10.0.1.12"
  eos leaf1 "show ipv6 neighbors"
  echo -e "${C}--- 5. VXLAN tunnels to an IPv4 VTEP over that route ---${N}"
  eos leaf1 "show vxlan vtep"
  echo -e "${Y}[i] The outer VXLAN header is still IPv4. Only the next hop is IPv6.${N}"
}

do_diff() {
  case ${1:-leaf} in
    leaf)
      echo -e "${C}leaf1 vs leaf2 in unnumbered mode: everything that differs between two leaves${N}"
      diff configs/unnumbered/leaf1.cfg configs/unnumbered/leaf2.cfg
      echo -e "${Y}[i] Hostname, loopbacks, ASN and RDs. No link addressing, because there is none.${N}" ;;
    modes)
      echo -e "${C}leaf1: numbered vs unnumbered${N}"
      diff configs/numbered/leaf1.cfg configs/unnumbered/leaf1.cfg
      echo -e "${C}spine1: numbered vs unnumbered${N}"
      diff configs/numbered/spine1.cfg configs/unnumbered/spine1.cfg
      echo -e "${Y}[i] Note what does NOT appear in either diff: the whole EVPN overlay stanza.${N}" ;;
    *) echo "diff leaf|modes"; exit 1 ;;
  esac
}

ticket() {
  case $1 in
    1) eoscfg leaf2 "no ipv6 unicast-routing" ;;
    2) eoscfg leaf3 "interface Ethernet2" "no ipv6 enable" ;;
    3) eoscfg leaf1 "router bgp 65101" "address-family ipv4" "no neighbor UNDERLAY next-hop address-family ipv6 originate" ;;
    4) eoscfg spine2 "router bgp 65100" "no neighbor interface Et1 peer-group UNDERLAY" "neighbor interface Et1 peer-group UNDERLAY remote-as 65199" ;;
    5) eoscfg leaf2 "router bgp 65102" "address-family ipv4" "no neighbor UNDERLAY activate" ;;
    6) eoscfg leaf3 "ip prefix-list PL-LOOPBACKS" "no seq 20" ;;
    7) eoscfg leaf1 "router bgp 65101" "no neighbor OVERLAY ebgp-multihop 3" ;;
    8) eoscfg spine1 "router bgp 65100" "no neighbor OVERLAY next-hop-unchanged" ;;
    *) echo "tickets: 1-8 or random"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == unnumbered ]] || echo -e "${Y}[!] tickets assume the unnumbered baseline (./lab.sh deploy unnumbered)${N}"
  local t=$1; [[ $t == random ]] && t=$(( (RANDOM % 8) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  [[ $1 == random ]] && echo "[*] blind ticket injected. Start with ./lab.sh verify" || echo "[*] ticket $t injected. See docs/TICKETS.md"
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=unnumbered
  for n in "${NODES[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  rm -f "$STATE"; echo "[*] baseline restored. ND and BGP need ~60s. Then verify."
}

case ${1:-} in
  deploy)   deploy "${2:-unnumbered}" ;;
  destroy)  $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)   verify ;;
  nexthops) nexthops ;;
  diff)     do_diff "${2:-leaf}" ;;
  break)    do_break "${2:?ticket number or random}" ;;
  reveal)   [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore)  restore ;;
  cli)      docker exec -it "$P-${2:?node}" Cli ;;
  status)   $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,12p' "$0" ;;
esac
