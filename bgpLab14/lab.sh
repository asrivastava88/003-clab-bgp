#!/usr/bin/env bash
# bgp-lab14 control script  (global backbone TE: hot/cold potato, MED, anycast)
#
#   ./lab.sh deploy                deploy and apply the per-span latency model
#   ./lab.sh destroy               tear down
#   ./lab.sh verify                state checks only; observed vs expected
#   ./lab.sh potato                exit selection, and whose backbone pays
#   ./lab.sh inbound               where the outside world enters our network
#   ./lab.sh anycast               anycast entry points, per external vantage
#   ./lab.sh latency               measured RTT against the ring model
#   ./lab.sh dist | med | gttmed   the backbone and MED plans
#   ./lab.sh break                 inject ALL faults at once
#   ./lab.sh break <n>             inject one, for isolated practice
#   ./lab.sh reveal | restore
#   ./lab.sh hint [n]              spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab14; TOPO=bgp-lab14.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(sea ash lhr sin gttw gtte cdn peereu)
OURS=(sea ash lhr sin)
NFAULTS=8
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
TP="python3 $DIR/tools/topology.py"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

ANYCAST=192.0.2.0/24; AMER=198.51.100.0/24; EMEA=203.0.113.0/24
APAC=198.18.0.0/24;   REGIONAL=198.18.1.0/24
# a reachable host inside each of our prefixes, and inside every peer's
H_ANY=192.0.2.1; H_AMER=198.51.100.1; H_EMEA=203.0.113.1; H_APAC=198.18.0.1
D_APACEYE=100.150.0.0/16; D_AMERW=100.151.0.0/16; D_AMERE=100.152.0.0/16
D_EUEYE=100.153.0.0/16;   D_TONLY=100.200.0.0/16
D_CDN=100.120.0.0/16;     D_PEEREU=100.140.0.0/16

nh()      { eos "$1" "show ip route $2" | grep -oE 'via 10\.[0-9]+\.[0-9]+\.[0-9]+' | sed 's/via //' | head -1; }
nhcount() { eos "$1" "show ip route $2" | grep -cE 'via 10\.'; }
estab()   { eos "$1" "show ip bgp summary" | grep -c Estab; }
ospfnb()  { eos "$1" "show ip ospf neighbor" | grep -c FULL; }

# Count BGP paths for a prefix, from the "Paths: N available" line. Returns
# "x" when the command gave nothing readable, so a broken command never
# silently reads as "zero paths" and makes an absence check pass for free.
paths() {
  local out n; out=$(eos "$1" "show ip bgp $2")
  n=$(echo "$out" | grep -oE 'Paths: [0-9]+' | grep -oE '[0-9]+' | head -1)
  if [[ -n $n ]]; then echo "$n"
  elif echo "$out" | grep -qE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "$out" | grep -cE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
  elif echo "$out" | grep -qiE 'BGP routing table|Router identifier'; then echo 0
  else echo x; fi
}

# Map a next hop to the PoP the traffic actually leaves our network at.
# Every interconnect has its own /30, and iBGP next-hop-self makes a remote
# PoP's loopback the next hop, so the address alone names the exit.
exitpop() {
  case "$1" in
    10.100.1.2|10.255.0.1) echo sea ;;
    10.100.3.2|10.255.0.2) echo ash ;;
    10.100.4.2|10.150.1.2|10.160.1.2|10.255.0.3) echo lhr ;;
    10.100.2.2|10.150.2.2|10.255.0.4) echo sin ;;
    "") echo none ;;
    *)  echo "unknown" ;;
  esac
}
# Same idea from outside: which of our PoPs does a peer hand traffic to?
entrypop() {
  case "$1" in
    10.100.1.1) echo sea ;; 10.100.3.1) echo ash ;;
    10.100.4.1|10.150.1.1|10.160.1.1) echo lhr ;;
    10.100.2.1|10.150.2.1) echo sin ;;
    10.110.0.1) echo "via-gttw" ;; 10.110.0.2) echo "via-gtte" ;;
    10.160.2.1) echo "via-transit" ;;
    "") echo none ;; *) echo "unknown" ;;
  esac
}

check_eq()  { [[ "$2" == "$3" ]] && ok "$1: $2, expected $3" || nok "$1: ${2:-<empty>}, expected $3"; }
check_num() { [[ "${2:-x}" == "$3" ]] && ok "$1: ${2:-0}, expected $3" || nok "$1: ${2:-0}, expected $3"; }

# ---------------------------------------------------------------- verify
verify() {
  echo -e "${B}== Sessions ==${N}"
  check_num "sea BGP Established"    "$(estab sea)"    4
  check_num "ash BGP Established"    "$(estab ash)"    4
  check_num "lhr BGP Established"    "$(estab lhr)"    6
  check_num "sin BGP Established"    "$(estab sin)"    5
  check_num "gttw BGP Established"   "$(estab gttw)"   3
  check_num "gtte BGP Established"   "$(estab gtte)"   4
  check_num "cdn BGP Established"    "$(estab cdn)"    2
  check_num "peereu BGP Established" "$(estab peereu)" 2
  for n in "${OURS[@]}"; do check_num "$n OSPF full adjacencies" "$(ospfnb $n)" 2; done

  echo -e "${B}== Backbone: shortest path by RTT cost ==${N}"
  check_eq "ash next hop to lhr loopback" "$(nh ash 10.255.0.3)" 10.254.0.3
  check_eq "sea next hop to lhr loopback" "$(nh sea 10.255.0.3)" 10.254.0.1
  check_eq "ash next hop to sin loopback" "$(nh ash 10.255.0.4)" 10.254.0.3
  check_eq "sea next hop to sin loopback" "$(nh sea 10.255.0.4)" 10.254.0.6

  echo -e "${B}== Cold potato: the transit's MED decides our exit ==${N}"
  for spec in "sea $D_APACEYE sin" "ash $D_APACEYE sin" "lhr $D_APACEYE sin" \
              "sea $D_EUEYE lhr"   "sin $D_EUEYE lhr"   "ash $D_AMERE ash" \
              "sin $D_AMERW sea"; do
    set -- $spec
    check_eq "$1 exit for $2" "$(exitpop "$(nh $1 $2)")" "$3"
  done

  echo -e "${B}== Hot potato: equal MED means each PoP exits locally ==${N}"
  for p in "${OURS[@]}"; do
    check_eq "$p exit for $D_TONLY" "$(exitpop "$(nh $p $D_TONLY)")" "$p"
  done

  echo -e "${B}== Peering: free capacity beats paid transit ==${N}"
  check_eq "lhr exit for the CDN" "$(exitpop "$(nh lhr $D_CDN)")" lhr
  check_eq "sin exit for the CDN" "$(exitpop "$(nh sin $D_CDN)")" sin
  check_eq "sea exit for the CDN" "$(exitpop "$(nh sea $D_CDN)")" lhr
  check_eq "ash exit for the CDN" "$(exitpop "$(nh ash $D_CDN)")" lhr
  for p in "${OURS[@]}"; do
    check_eq "$p exit for the European peer" "$(exitpop "$(nh $p $D_PEEREU)")" lhr
  done

  echo -e "${B}== Inbound: our MED decides where the transit enters ==${N}"
  check_eq "gttw entry for $EMEA" "$(entrypop "$(nh gttw $EMEA)")" via-gtte
  check_eq "gtte entry for $EMEA" "$(entrypop "$(nh gtte $EMEA)")" lhr
  check_eq "gtte entry for $AMER" "$(entrypop "$(nh gtte $AMER)")" via-gttw
  check_eq "gttw entry for $AMER" "$(entrypop "$(nh gttw $AMER)")" sea
  check_eq "gttw entry for $APAC" "$(entrypop "$(nh gttw $APAC)")" sin
  check_eq "cdn entry for $EMEA"  "$(entrypop "$(nh cdn $EMEA)")"  lhr
  check_eq "cdn entry for $APAC"  "$(entrypop "$(nh cdn $APAC)")"  sin
  check_num "gtte paths to $AMER" "$(paths gtte $AMER)" 3

  echo -e "${B}== Anycast: equal MED, so the upstream load-shares entry ==${N}"
  check_num "gttw entry points for $ANYCAST" "$(nhcount gttw $ANYCAST)" 2
  check_num "gtte entry points for $ANYCAST" "$(nhcount gtte $ANYCAST)" 2
  check_num "cdn entry points for $ANYCAST"  "$(nhcount cdn $ANYCAST)"  2

  echo -e "${B}== Selective announcement ==${N}"
  check_num "gtte paths to $REGIONAL"   "$(paths gtte $REGIONAL)"   1
  check_num "peereu paths to $REGIONAL" "$(paths peereu $REGIONAL)" 0
  check_num "peereu paths to $EMEA"     "$(paths peereu $EMEA)"     2

  echo -e "${B}== Reachability ==${N}"
  for spec in "sea 100.153.0.1" "sin 100.151.0.1" "lhr 100.150.0.1" "ash 100.120.0.1" \
              "sea 100.140.0.1" "ash 100.200.0.1" "gttw $H_EMEA" "peereu $H_ANY"; do
    set -- $spec
    if eos "$1" "ping $2 repeat 3 timeout 2" | grep -qE '[1-9][0-9]* received'; then
      ok "$1 to $2"; else nok "$1 to $2"; fi
  done

  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
  return 0
}

# ---------------------------------------------------------------- potato
potato() {
  local m=""
  for p in "${OURS[@]}"; do
    for d in $D_APACEYE $D_AMERW $D_AMERE $D_EUEYE $D_TONLY $D_CDN $D_PEEREU; do
      m="$m,$p:$d=$(exitpop "$(nh $p $d)")"
    done
  done
  $TP potato --map "${m#,}"
}

inbound() {
  echo -e "${B}Where the outside world enters our network${N}"
  echo -e "${C}This is the half of BGP policy you cannot see from your own routing${N}"
  echo -e "${C}table. It is decided by the MED and AS path we announce, and only${N}"
  echo -e "${C}if the other side chooses to honour them.${N}\n"
  printf "  %-20s %-12s %-12s %-12s %-12s\n" "our prefix" "gttw" "gtte" "cdn" "peereu"
  for pfx in $ANYCAST $AMER $EMEA $APAC $REGIONAL; do
    printf "  %-20s" "$pfx"
    for v in gttw gtte cdn peereu; do
      c=$(nhcount "$v" "$pfx")
      if [[ ${c:-0} -ge 2 ]]; then printf "${G}%-12s${N}" "${c} entries"
      elif [[ ${c:-0} -eq 1 ]]; then printf "%-12s" "$(entrypop "$(nh $v $pfx)")"
      else printf "${Y}%-12s${N}" "absent"; fi
    done; echo
  done
  echo
  echo -e "${Y}[i] 'via-gttw' and 'via-gtte' mean the transit is carrying the traffic${N}"
  echo -e "${Y}    across its own backbone to reach the handoff our MED asked for.${N}"
  echo -e "${Y}    That is them doing cold potato for us, which is what a MED buys.${N}"
  echo -e "${Y}    'absent' is correct for exactly one prefix in this lab.${N}"
}

anycast() {
  echo -e "${B}Anycast entry points for $ANYCAST${N}\n"
  for v in gttw gtte cdn peereu; do
    c=$(nhcount "$v" "$ANYCAST")
    printf "  %-8s %s entry point(s):\n" "$v" "${c:-0}"
    eos "$v" "show ip route $ANYCAST" | grep -E 'via 10\.' | sed 's/^/      /'
  done
  echo
  echo -e "${Y}[i] A unicast prefix should have ONE entry per vantage, chosen by MED.${N}"
  echo -e "${Y}    An anycast prefix should have as many as the vantage has handoffs,${N}"
  echo -e "${Y}    because every source should enter at the handoff nearest itself.${N}"
  echo -e "${Y}    A '1' here means one region stopped receiving anycast traffic.${N}"
}

latency() {
  echo -e "${B}Measured RTT against the ring model${N}\n"
  printf "  %-26s %10s %10s\n" "path" "expected" "measured"
  probe() {
    local out ms
    out=$(eos "$2" "ping $3 repeat 5 timeout 3" | grep -oE 'min/avg/max = [0-9./]+')
    ms=$(echo "$out" | grep -oE '[0-9.]+/[0-9.]+/' | head -1 | cut -d/ -f2)
    printf "  %-26s %9sms %9sms\n" "$1" "$4" "${ms:-unreachable}"
  }
  probe "sea -> ash"            sea 10.255.0.2 65
  probe "ash -> lhr"            ash 10.255.0.3 75
  probe "lhr -> sin"            lhr 10.255.0.4 160
  probe "sin -> sea"            sin 10.255.0.1 175
  probe "sea -> lhr (via ash)"  sea 10.255.0.3 140
  probe "ash -> sin (via lhr)"  ash 10.255.0.4 235
  probe "sea -> EU eyeballs"    sea 100.153.0.1 140
  probe "sin -> AMER-W eyeballs" sin 100.151.0.1 175
  echo
  echo -e "${Y}[i] A measured RTT far above the model means the traffic is not taking${N}"
  echo -e "${Y}    the path the ring costs intend, in one direction or both. Remember${N}"
  echo -e "${Y}    that OSPF cost is per interface and therefore per direction.${N}"
}

# ---------------------------------------------------------------- faults
fault() {
  case $1 in
    1) eoscfg sin "route-map RM-GTT-OUT permit 30" "set metric 0" ;;
    2) eoscfg ash "route-map RM-GTT-IN permit 7" "match ip address prefix-list PL-CDN" \
                  "set local-preference 250" ;;
    3) eoscfg sin "route-map RM-GTT-OUT permit 50" "no set community no-export additive" ;;
    4) eoscfg ash "interface Ethernet3" "ip ospf cost 500" ;;
    5) eoscfg lhr "route-map RM-PNI-IN permit 10" "set local-preference 90" ;;
    6) eoscfg lhr "route-map RM-GTT-OUT permit 10" "set metric 100" ;;
    7) eoscfg sea "route-map RM-GTT-IN permit 10" "set local-preference 50" ;;
    8) eoscfg ash "ip prefix-list PL-AMER seq 5 deny 198.51.100.0/24" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"; : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~60s, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"; echo "[*] fault $1 injected"
  fi
}
restore() {
  for n in "${NODES[@]}"; do
    docker cp "configs/solution/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored"
  done
  apply_latency
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~60s, then verify."
}
apply_latency() {
  echo "[*] applying the per-span latency model"
  $TP latency | while read -r node ifc delay span; do
    $CLAB tools netem set -n "$P-$node" -i "$ifc" --delay "$delay" >/dev/null 2>&1 \
      && printf "    %-6s %-6s %-8s %s\n" "$node" "$ifc" "$delay" "$span"
  done
}
hint() {
  echo -e "${Y}These are spoilers. Close the window if you did not mean to run this.${N}"; echo
  if [[ -n ${1:-} ]]; then sed -n "/^### fault $1\$/,/^### /p" docs/HINTS.md | head -n -1
  else cat docs/HINTS.md; fi
}
deploy() {
  cp -f configs/solution/*.cfg configs/active/
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  printf "[*] waiting for cEOS nodes"
  for n in "${NODES[@]}"; do
    for _ in $(seq 1 60); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
  apply_latency
  echo -e "${Y}[i] allow ~60s for OSPF and BGP, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)  deploy ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" ;;
  verify)  verify ;;
  potato)  potato ;;
  inbound) inbound ;;
  anycast) anycast ;;
  latency) latency ;;
  dist)    $TP dist ;;
  med)     $TP med ;;
  gttmed)  $TP gttmed ;;
  netem)   apply_latency ;;
  break)   do_break "${2:-}" ;;
  reveal)  [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active" ;;
  restore) restore ;;
  hint)    hint "${2:-}" ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,22p' "$0" ;;
esac
