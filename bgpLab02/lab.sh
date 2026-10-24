#!/usr/bin/env bash
# bgp-lab02 control script
#   ./lab.sh deploy <base|solution|te>  stage configs and deploy (one mode, e.g. deploy te)
#   ./lab.sh destroy                    tear down
#   ./lab.sh verify                     fabric + edge + (te) policy checks
#   ./lab.sh break <1-7|random>         inject a ticket (te baseline)
#   ./lab.sh reveal | restore           show / clear active ticket
#   ./lab.sh grey on|off                100% loss ispA -> bleaf1, carrier stays up
#   ./lab.sh cli <node>                 Cli on any switch | h1..h4 -> sh
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab02; TOPO=bgp-lab02.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
CEOS=(spine1 spine2 leaf1 leaf2 bleaf1 bleaf2 ispA ispB inet)
STATE="$DIR/.active_ticket"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
mode() { cat "$DIR/.mode" 2>/dev/null || echo unknown; }

eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*"; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

# prints "<nexthop> <aspath>" of the best path from EOS or FRR JSON on stdin
best() { python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
def walk(o):
    if isinstance(o,dict):
        rt=o.get("routeType"); bp=o.get("bestpath")
        if (isinstance(rt,dict) and rt.get("active")) or (isinstance(bp,dict) and bp.get("overall")):
            nh=o.get("nextHop") or ((o.get("nexthops") or [{}])[0].get("ip",""))
            ap=(o.get("asPathEntry") or {}).get("asPath") or (o.get("aspath") or {}).get("string","")
            print(nh, ap or "-"); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(d)'; }

wait_ceos() {
  printf "[*] waiting for cEOS nodes"
  for n in "${CEOS[@]}"; do
    for _ in $(seq 1 60); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
}
deploy() {
  local m=${1:-te}
  [[ -d configs/$m ]] || { echo "mode: base|solution|te"; exit 1; }
  cp -f configs/"$m"/*.cfg configs/active/; echo "$m" > "$DIR/.mode"
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  wait_ceos
  echo -e "${Y}[i] mode=$m. Allow ~90s for convergence, then ./lab.sh verify${N}"
}

ping_t() { if docker exec "$P-$2" ping -c 3 -W 1 -q "$3" >/dev/null 2>&1; then ok "$1"; else nok "$1"; fi; }
estab()  { eos "$1" "$2" 2>/dev/null | grep -c Estab; }

path_t() { # desc host dst regex-of-expected-hop
  local hops; hops=$(docker exec "$P-$2" traceroute -n -w 1 -q 1 -m 6 "$3" 2>/dev/null | awk 'NR>1{print $2}' | tr '\n' ' ')
  [[ $hops =~ $4 ]] && ok "$1 [$hops]" || nok "$1 [$hops]"
}
bestnh_t() { # desc node prefix expected-regex(on "nh aspath")
  local out
  out=$(eos "$2" "show ip bgp $3 | json" 2>/dev/null | best)
  [[ $out =~ $4 ]] && ok "$1 [$out]" || nok "$1 [${out:-no route}]"
}

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"
  echo "== Fabric =="
  for n in spine1 spine2; do u=$(estab $n "show ip bgp summary"); e=$(estab $n "show bgp evpn summary")
    [[ $u -eq 4 && $e -eq 4 ]] && ok "$n underlay $u/4 evpn $e/4" || nok "$n underlay $u/4 evpn $e/4"; done
  for n in leaf1 leaf2 bleaf1 bleaf2; do u=$(estab $n "show ip bgp summary"); e=$(estab $n "show bgp evpn summary")
    [[ $u -eq 2 && $e -eq 2 ]] && ok "$n underlay $u/2 evpn $e/2" || nok "$n underlay $u/2 evpn $e/2"; done
  ping_t "h1 -> h2  RED  L3VNI 50001" h1 10.10.20.102
  ping_t "h3 -> h4  BLUE L2VNI 10030" h3 10.30.30.104
  [[ $m == base ]] && { echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N} (edge not built yet)"; return; }

  echo "== Edge =="
  # count only the 172.16.x WAN peers: "vrf all" also lists the default VRF's
  # IPv4 underlay sessions, which are checked in the Fabric section above
  for n in bleaf1 bleaf2; do v=$(eos $n "show ip bgp summary vrf all" | grep -c '172\.16\..*Estab')
    [[ ${v:-0} -eq 4 ]] && ok "$n WAN sessions $v/4 (RED+BLUE x ispA+ispB)" \
      || nok "$n WAN sessions ${v:-0}/4 (check: show ip bgp summary vrf RED | vrf BLUE)"; done
  b=$(estab inet "show ip bgp summary")
  [[ $b -eq 2 ]] && ok "inet eBGP to ispA+ispB $b/2" || nok "inet eBGP $b/2"
  ping_t "h1 -> 203.0.113.10 RED internet"        h1 203.0.113.10
  ping_t "h3 -> 203.0.113.10 BLUE internet"       h3 203.0.113.10
  ping_t "h2 -> 198.51.100.1 RED to ispB cust"    h2 198.51.100.1
  ping_t "h4 -> 192.0.2.1   BLUE to ispA cust"    h4 192.0.2.1
  [[ $m != te ]] && { echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"; return; }

  echo "== Policy (te) =="
  path_t   "egress RED  exits via ispA"            h1 203.0.113.10 '172\.16\.1[12]\.2'
  path_t   "egress BLUE exits via ispB"            h3 203.0.113.10 '172\.16\.2[12]\.6'
  bestnh_t "ingress RED  inet best via ispA"       inet 10.10.10.0/24 '^100\.64\.1\.1 65010'
  bestnh_t "ingress BLUE inet best via ispB"       inet 10.30.30.0/24 '^100\.64\.2\.1 65020'
  bestnh_t "MED: ispA lands RED on bleaf1"         ispA 10.10.10.0/24 '^172\.16\.11\.1 '
  bestnh_t "MED: ispB lands BLUE on bleaf2"        ispB 10.30.30.0/24 '^172\.16\.22\.5 '
  bestnh_t "LP80: ispB reaches RED via inet"       ispB 10.10.10.0/24 '^100\.64\.2\.2 '
  bestnh_t "LP80: ispA reaches BLUE via inet"      ispA 10.30.30.0/24 '^100\.64\.1\.2 '
  for n in bleaf1 bleaf2; do u=$(eos $n "show bfd peers" 2>/dev/null | grep -cw Up)
    [[ $u -ge 4 ]] && ok "$n BFD peers up $u/4" || nok "$n BFD peers up $u/4"; done
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] ticket active (./lab.sh reveal | restore)${N}"
}

# netem impairments are applied as a complete set: any flag you omit returns to
# its default, so a flagless "set" is the documented way to clear them.
grey() {
  if [[ $1 == on ]]; then
    $CLAB tools netem set -n "$P-ispA" -i eth1 --loss 100 >/dev/null \
      && echo "[*] grey failure ON: ispA->bleaf1 100% loss, carrier stays up"
  else
    $CLAB tools netem set -n "$P-ispA" -i eth1 >/dev/null
    echo "[*] grey failure OFF"
  fi
  $CLAB tools netem show -n "$P-ispA" 2>/dev/null | grep -E 'eth1|Interface' || true
}

ticket() {
  case $1 in
    1) eoscfg bleaf2 "interface Ethernet3.101" "encapsulation dot1q vlan 111" ;;
    2) eoscfg leaf2 "no route-map RM-EVPN-IN permit 100" ;;
    3) eoscfg bleaf1 "router bgp 65104" "no neighbor EVPN send-community" ;;
    4) eoscfg bleaf1 "route-map RM-RED-ISPA-OUT permit 10" "set metric 500" ;;
    5) eoscfg bleaf2 "router bgp 65104" "vrf RED" "no neighbor 172.16.22.2 send-community" ;;
    6) eoscfg bleaf1 "router bgp 65104" "vrf RED" "no neighbor 172.16.11.2 bfd" "vrf BLUE" "no neighbor 172.16.11.6 bfd"; grey on >/dev/null ;;
    7) eoscfg bleaf2 "router bgp 65104" "vrf BLUE" "neighbor 172.16.22.6 maximum-routes 2" ;;
    *) echo "tickets: 1-7 or random"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == te ]] || echo -e "${Y}[!] tickets assume the te baseline (./lab.sh deploy te)${N}"
  local t=$1; [[ $t == random ]] && t=$(( (RANDOM % 7) + 1 ))
  ticket "$t" && echo "$t" > "$STATE"
  [[ $1 == random ]] && echo "[*] blind ticket injected. Start with ./lab.sh verify" || echo "[*] ticket $t injected. See docs/TICKETS.md"
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=te
  grey off >/dev/null
  for n in "${CEOS[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  for n in bleaf1 bleaf2; do eos $n "clear ip bgp vrf all" >/dev/null 2>&1; done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~60s, then verify."
}
cli() { case $1 in h[0-9]) docker exec -it "$P-$1" sh ;; *) docker exec -it "$P-$1" Cli ;; esac; }

case ${1:-} in
  deploy)  deploy "${2:-te}" ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)  verify ;;
  break)   do_break "${2:?ticket number or random}" ;;
  reveal)  [[ -f $STATE ]] && echo "active ticket: $(cat "$STATE")" || echo "no active ticket" ;;
  restore) restore ;;
  grey)    grey "${2:?on|off}" ;;
  cli)     cli "${2:?node}" ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,11p' "$0" ;;
esac
