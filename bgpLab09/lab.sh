#!/usr/bin/env bash
# bgp-lab09 control script  (convergence and resiliency)
#
#   ./lab.sh deploy <base|solution>   stage configs and deploy (one mode)
#   ./lab.sh destroy                  tear down
#   ./lab.sh verify                   state checks only; reports what it saw
#   ./lab.sh measure <scenario>       time a failure. hard | grey | wan | drain
#   ./lab.sh grey on|off              100% loss spine1 -> leaf1, carrier stays up
#   ./lab.sh break                    inject ALL faults at once
#   ./lab.sh break <n>                inject one fault, for isolated practice
#   ./lab.sh reveal                   how many faults are active
#   ./lab.sh restore                  back to the deployed baseline
#   ./lab.sh hint [n]                 diagnostic pointers. Spoils the exercise.
#   ./lab.sh cli <node>               Cli on any node
#   ./lab.sh status
#
# verify states observed vs expected and nothing else. It never names a
# command, a config line or a likely cause. That is what hint is for.
set -uo pipefail
LAB=bgp-lab09; TOPO=bgp-lab09.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(spine1 spine2 leaf1 leaf2 bleaf1 bleaf2 wan h1 h2 h3)
SWITCHES=(spine1 spine2 leaf1 leaf2 bleaf1 bleaf2 wan)
FABRIC=(leaf1 leaf2 bleaf1 bleaf2)
NFAULTS=8
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
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
  local m=${1:-solution}
  [[ -d configs/$m ]] || { echo "mode: base|solution"; exit 1; }
  cp -f configs/"$m"/*.cfg configs/active/; echo "$m" > "$DIR/.mode"
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  wait_nodes
  echo -e "${Y}[i] mode=$m. Allow ~90s, then ./lab.sh verify${N}"
}

reaches() { eos "$1" "ping $2 repeat 2 timeout 1" | grep -qE '[1-9][0-9]* received'; }
ping_t()  { if reaches "$2" "$3"; then ok "$1"; else nok "$1"; fi; }

bfd_up()  { eos "$1" "show bfd peers" | grep -cw Up; }
# negotiated hold time on a given neighbour
holdtime() { eos "$1" "show ip bgp neighbors $2" | grep -oiE 'hold time is [0-9]+' | grep -oE '[0-9]+' | head -1; }
# how many next hops the FIB installed for a prefix
nh_count() { eos "$1" "show ip route $2" | grep -cE 'via 10\.1\.|via [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+,'; }
vtep_nh()  { eos "$1" "show ip route vrf $VRFN $2" | grep -c "via VTEP"; }
VRFN=RED

verify() {
  local m; m=$(mode); echo -e "${Y}mode: $m${N}"

  echo "== Sessions =="
  for n in spine1 spine2; do u=$(eos $n "show ip bgp summary" | grep -c Estab); e=$(eos $n "show bgp evpn summary" | grep -c Estab)
    [[ $u -eq 4 && $e -eq 4 ]] && ok "$n underlay $u/4 evpn $e/4" || nok "$n underlay $u/4 evpn $e/4"; done
  for n in "${FABRIC[@]}"; do u=$(eos $n "show ip bgp summary" | grep -c Estab); e=$(eos $n "show bgp evpn summary" | grep -c Estab)
    [[ $u -eq 2 && $e -eq 2 ]] && ok "$n underlay $u/2 evpn $e/2" || nok "$n underlay $u/2 evpn $e/2"; done
  for n in bleaf1 bleaf2; do w=$(eos $n "show ip bgp summary vrf $VRFN" | grep -c Estab)
    [[ ${w:-0} -eq 1 ]] && ok "$n WAN session $w/1" || nok "$n WAN session ${w:-0}/1"; done

  echo "== Data plane =="
  ping_t "h1 -> h2  same subnet across the fabric"  h1 10.10.10.102
  ping_t "h1 -> h3  routed across the fabric"       h1 10.10.20.103
  ping_t "h1 -> 203.0.113.10 via the border"        h1 203.0.113.10
  ping_t "h3 -> 203.0.113.10 via the border"        h3 203.0.113.10

  [[ $m == base ]] && {
    echo -e "${Y}[i] base mode: the fabric forwards, and nothing about its"
    echo -e "    failure detection or path redundancy has been configured.${N}"
    echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
    return; }

  echo "== Failure detection =="
  for n in leaf1 leaf2 bleaf1 bleaf2; do
    b=$(bfd_up $n); want=2; [[ $n == bleaf* ]] && want=3
    [[ ${b:-0} -ge $want ]] && ok "$n BFD peers Up: ${b:-0}, expected $want" \
      || nok "$n BFD peers Up: ${b:-0}, expected $want"
  done
  for n in spine1 spine2; do b=$(bfd_up $n)
    [[ ${b:-0} -ge 4 ]] && ok "$n BFD peers Up: ${b:-0}, expected 4" \
      || nok "$n BFD peers Up: ${b:-0}, expected 4"; done
  b=$(eos wan "show bfd peers" | grep -cw Up)
  [[ ${b:-0} -ge 2 ]] && ok "wan BFD peers Up: ${b:-0}, expected 2" || nok "wan BFD peers Up: ${b:-0}, expected 2"

  echo "== Hold timers =="
  for pair in "leaf1 10.1.1.0" "leaf2 10.1.1.2" "bleaf1 10.1.1.4"; do
    set -- $pair
    h=$(holdtime "$1" "$2")
    [[ ${h:-999} -le 30 ]] && ok "$1 hold time toward $2 is ${h:-unknown}s, expected 30s or less" \
      || nok "$1 hold time toward $2 is ${h:-unknown}s, expected 30s or less"
  done

  echo "== Path redundancy =="
  for n in leaf1 leaf2; do
    c=$(nh_count $n 10.0.1.14)
    [[ ${c:-0} -ge 2 ]] && ok "$n installs ${c:-0} underlay next hops to 10.0.1.14, expected 2" \
      || nok "$n installs ${c:-0} underlay next hops to 10.0.1.14, expected 2"
  done
  for n in leaf1 leaf2; do
    c=$(vtep_nh $n 0.0.0.0/0)
    [[ ${c:-0} -ge 2 ]] && ok "$n installs ${c:-0} VTEP next hops for the default in $VRFN, expected 2" \
      || nok "$n installs ${c:-0} VTEP next hops for the default in $VRFN, expected 2"
  done
  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
}

grey() {
  if [[ $1 == on ]]; then
    $CLAB tools netem set -n "$P-spine1" -i eth1 --loss 100 >/dev/null \
      && echo "[*] grey failure ON: spine1 -> leaf1 100% loss, carrier stays up"
  else
    $CLAB tools netem set -n "$P-spine1" -i eth1 >/dev/null
    echo "[*] grey failure OFF"
  fi
}

# run a flood ping from $1 to $2 for the duration of whatever $3 does
measure() {
  local what=${1:?hard|grey|wan|drain} src dst out pid
  case $what in
    hard)  src=h1; dst=10.10.20.103; act="shut leaf1 Ethernet1 (carrier down), then unshut" ;;
    grey)  src=h1; dst=10.10.20.103; act="100% loss spine1->leaf1 with carrier up, then clear" ;;
    wan)   src=h1; dst=203.0.113.10; act="shut bleaf1 Ethernet3, then unshut" ;;
    drain) src=h1; dst=10.10.20.103; act="drain spine1 with an AS-path prepend, then undo" ;;
    *) echo "measure hard|grey|wan|drain"; exit 1 ;;
  esac
  out="/tmp/${LAB}-${what}.txt"
  echo -e "${C}[*] $what: $act${NC:-$N}"
  echo "[*] 150 pings at 200ms from $src to $dst while it happens"
  docker exec "$P-$src" Cli -p 15 -c "ping $dst repeat 150 interval 0.2 timeout 1" > "$out" 2>&1 &
  pid=$!
  sleep 4
  case $what in
    hard)  eoscfg leaf1 "interface Ethernet1" "shutdown" ;;
    grey)  grey on >/dev/null ;;
    wan)   eoscfg bleaf1 "interface Ethernet3" "shutdown" ;;
    drain) eoscfg spine1 "route-map RM-DRAIN permit 10" "set as-path prepend 65100 65100 65100" \
                         "router bgp 65100" "neighbor UNDERLAY route-map RM-DRAIN out" ;;
  esac
  sleep 14
  case $what in
    hard)  eoscfg leaf1 "interface Ethernet1" "no shutdown" ;;
    grey)  grey off >/dev/null ;;
    wan)   eoscfg bleaf1 "interface Ethernet3" "no shutdown" ;;
    drain) eoscfg spine1 "router bgp 65100" "no neighbor UNDERLAY route-map RM-DRAIN out" ;;
  esac
  wait $pid
  echo "--- result ---"; tail -5 "$out"
  echo -e "${Y}[i] each lost packet is about 200ms. Run the same scenario in both"
  echo -e "    modes and compare the numbers.${N}"
  sleep 5
}

# ---- faults. break with no argument injects every one of them. ----
fault() {
  case $1 in
    1) eoscfg leaf1  "router bgp 65101" "no neighbor UNDERLAY bfd" ;;
    2) eoscfg leaf2  "router bgp 65102" "no neighbor UNDERLAY timers 3 9" ;;
    3) eoscfg leaf1  "router bgp 65101" "maximum-paths 1" ;;
    4) eoscfg leaf2  "router bgp 65102" "vrf RED" "maximum-paths 1" ;;
    5) eoscfg bleaf1 "router bgp 65104" "vrf RED" "no neighbor 172.16.1.2 bfd" ;;
    6) eoscfg spine2 "interface Ethernet1" "bfd interval 3000 min-rx 3000 multiplier 3"
       eoscfg spine2 "interface Ethernet2" "bfd interval 3000 min-rx 3000 multiplier 3" ;;
    7) eoscfg leaf2  "interface Ethernet1" "bfd interval 300 min-rx 300 multiplier 50" ;;
    8) eoscfg spine1 "router bgp 65100" "no neighbor UNDERLAY bfd" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  [[ $(mode) == solution ]] || echo -e "${Y}[!] faults are regressions from the solution baseline${N}"
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"
    : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo
    echo "[*] done. Allow ~60s, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"
    echo "[*] fault $1 injected"
  fi
}
restore() {
  local m; m=$(mode); [[ -d configs/$m ]] || m=solution
  grey off >/dev/null 2>&1
  for n in "${SWITCHES[@]}"; do
    docker cp "configs/$m/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored ($m)"
  done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~60s, then verify."
}

hint() {
  echo -e "${Y}These are spoilers. Close the window if you did not mean to run this.${N}"
  echo
  if [[ -n ${1:-} ]]; then sed -n "/^### fault $1\$/,/^### /p" docs/HINTS.md | head -n -1
  else cat docs/HINTS.md; fi
}

case ${1:-} in
  deploy)  deploy "${2:-solution}" ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DIR/.mode" ;;
  verify)  verify ;;
  measure) measure "${2:-hard}" ;;
  grey)    grey "${2:?on|off}" ;;
  break)   do_break "${2:-}" ;;
  reveal)  [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active" ;;
  restore) restore ;;
  hint)    hint "${2:-}" ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,17p' "$0" ;;
esac
