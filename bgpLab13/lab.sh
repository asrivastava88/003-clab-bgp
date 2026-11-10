#!/usr/bin/env bash
# bgp-lab13 control script  (carriers, dark fibre, IX, cloud IC, long haul, subsea)
#
#   ./lab.sh deploy                deploy and apply the per-circuit latency model
#   ./lab.sh destroy               tear down
#   ./lab.sh verify                state checks only; observed vs expected
#   ./lab.sh exits                 where every traffic class leaves the network
#   ./lab.sh cost                  price the current exit distribution
#   ./lab.sh routes                the circuit inventory by kind
#   ./lab.sh srlg                  fate-sharing audit of intended-diverse pairs
#   ./lab.sh srlgs                 every shared-risk group, by blast radius
#   ./lab.sh cut <SRLG>            cut one shared-risk group. 1+1 circuits survive.
#   ./lab.sh uncut                 undo every cut
#   ./lab.sh latency               measured RTT against the inventory
#   ./lab.sh break                 inject ALL faults at once
#   ./lab.sh break <n>             inject one, for isolated practice
#   ./lab.sh reveal | restore
#   ./lab.sh hint [n]              spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab13; TOPO=bgp-lab13.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(sea1 sea2 ash1 transit1 transit2 ixrs ixpeer1 ixpeer2 cdn1 cloudgw)
NFAULTS=8
STATE="$DIR/.active_faults"; CUTS="$DIR/.active_cuts"; CLAB="sudo containerlab"
TP="python3 $DIR/tools/transport.py"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }
ethname() { echo "${1/eth/Ethernet}"; }

# our three prefixes, and a probe address inside every peer's space
EP_CLOUD=100.130.0.1; EP_CLOUD_B=100.131.0.1
EP_CDN=100.120.0.1;   EP_CDN_HI=100.120.200.1
EP_IXRS=100.110.0.1;  EP_IXBILAT=100.111.0.1
EP_TRANSIT=100.200.0.1; EP_T1=100.100.0.1; EP_T2=100.101.0.1
OUR_SEA=198.51.100.0/24; OUR_ASH=203.0.113.0/24; OUR_ANY=192.0.2.0/24

# ---------------------------------------------------------------- helpers
nh() { eos "$1" "show ip route $2" | grep -oE 'via 10\.[0-9]+\.[0-9]+\.[0-9]+' | sed 's/via //' | head -1; }
nhcount() { eos "$1" "show ip route $2" | grep -cE 'via 10\.'; }
estab()  { eos "$1" "show ip bgp summary" | grep -c Estab; }
ospfnb() { eos "$1" "show ip ospf neighbor" | grep -c FULL; }
# Count prefix rows in a BGP table view. Returns "x" when the command gave
# nothing we can read, so a broken command reports unreadable instead of 0 --
# a 0 would make a "should be empty" check pass for the wrong reason.
bgp_rows() {
  local out; out=$(eos "$1" "$2")
  if echo "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+'; then
    echo "$out" | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+'
  elif echo "$out" | grep -qiE 'BGP routing table|Router identifier|local AS number'; then
    echo 0
  else
    echo x
  fi
}
# prefixes a neighbour sent us that survived policy
accepted() { bgp_rows "$1" "show ip bgp neighbors $2 routes"; }
# prefixes we send a neighbour
advertised() { bgp_rows "$1" "show ip bgp neighbors $2 advertised-routes"; }

# classify an exit by its next hop. Each interconnect has its own /30 or LAN,
# so the next-hop address alone says which circuit a packet leaves on.
cls() {
  case "$1" in
    10.160.1.2|10.160.2.2) echo cloud ;;
    10.150.1.2|10.150.2.2) echo pni ;;
    10.200.0.1|10.200.0.30) echo ix ;;
    10.100.1.2|10.100.2.2) echo transit ;;
    10.201.2.2)            echo transit2 ;;
    10.254.*|10.255.*)     echo internal ;;
    "")                    echo none ;;
    *)                     echo "unknown($1)" ;;
  esac
}

check_eq()  { [[ "$2" == "$3" ]] && ok "$1: $2, expected $3" || nok "$1: ${2:-<empty>}, expected $3"; }
check_num() { [[ ${2:-0} -eq $3 ]] && ok "$1: ${2:-0}, expected $3" || nok "$1: ${2:-0}, expected $3"; }

# ---------------------------------------------------------------- verify
verify() {
  echo -e "${B}== Sessions ==${N}"
  check_num "sea1 BGP Established"     "$(estab sea1)"     7
  check_num "sea2 BGP Established"     "$(estab sea2)"     8
  check_num "ash1 BGP Established"     "$(estab ash1)"     2
  check_num "transit1 BGP Established" "$(estab transit1)" 2
  check_num "ixrs BGP Established"     "$(estab ixrs)"     3
  check_num "ixpeer2 BGP Established"  "$(estab ixpeer2)"  2
  check_num "cdn1 BGP Established"     "$(estab cdn1)"     2
  check_num "cloudgw BGP Established"  "$(estab cloudgw)"  2
  for n in sea1 sea2 ash1; do check_num "$n OSPF full adjacencies" "$(ospfnb $n)" 2; done

  echo -e "${B}== Peering policy: where each class exits, from sea1 ==${N}"
  check_eq "sea1 exit for cloud"            "$(cls "$(nh sea1 $EP_CLOUD)")"     cloud
  check_eq "sea1 exit for CDN"              "$(cls "$(nh sea1 $EP_CDN)")"       pni
  check_eq "sea1 exit for IX route-server"  "$(cls "$(nh sea1 $EP_IXRS)")"      ix
  check_eq "sea1 exit for IX bilateral"     "$(cls "$(nh sea1 $EP_IXBILAT)")"   ix
  check_eq "sea1 exit for transit-only"     "$(cls "$(nh sea1 $EP_TRANSIT)")"   transit

  echo -e "${B}== Peering policy: from sea2 ==${N}"
  check_eq "sea2 exit for cloud"            "$(cls "$(nh sea2 $EP_CLOUD)")"     cloud
  check_eq "sea2 exit for CDN"              "$(cls "$(nh sea2 $EP_CDN)")"       pni
  check_eq "sea2 exit for IX bilateral"     "$(cls "$(nh sea2 $EP_IXBILAT)")"   ix

  echo -e "${B}== Prefix hygiene at the exchange ==${N}"
  check_num "sea1 prefixes accepted from the route server" "$(accepted sea1 10.200.0.1)" 1
  check_num "sea2 prefixes accepted from the route server" "$(accepted sea2 10.200.0.1)" 1
  check_num "sea1 prefixes advertised to the route server" "$(advertised sea1 10.200.0.1)" 3
  check_num "sea2 prefixes advertised to the route server" "$(advertised sea2 10.200.0.1)" 3
  check_num "sea1 prefixes accepted from the CDN PNI"      "$(accepted sea1 10.150.1.2)" 2
  check_num "sea2 prefixes accepted from the CDN PNI"      "$(accepted sea2 10.150.2.2)" 2

  echo -e "${B}== Inbound traffic engineering ==${N}"
  check_num "transit1 next hops to $OUR_ASH" "$(nhcount transit1 $OUR_ASH)" 1
  check_num "transit1 next hops to $OUR_SEA" "$(nhcount transit1 $OUR_SEA)" 1

  echo -e "${B}== Which physical circuit internal traffic rides ==${N}"
  check_eq "sea1 next hop to ash1 loopback" "$(nh sea1 10.255.0.3)" 10.254.0.3
  check_eq "sea2 next hop to ash1 loopback" "$(nh sea2 10.255.0.3)" 10.254.0.0
  check_eq "sea1 next hop to sea2 loopback" "$(nh sea1 10.255.0.2)" 10.254.0.1

  echo -e "${B}== Handoff MTU ==${N}"
  for spec in "sea1 Ethernet5 9100" "sea1 Ethernet2 1500" "sea2 Ethernet7 1500" "sea1 Ethernet3 9100"; do
    set -- $spec
    m=$(eos "$1" "show interfaces $2" | grep -oE 'MTU [0-9]+' | grep -oE '[0-9]+' | head -1)
    check_num "$1 $2 MTU" "${m:-0}" "$3"
  done

  echo -e "${B}== Reachability ==${N}"
  for spec in "sea1 $EP_CLOUD" "sea1 $EP_CDN" "sea1 $EP_CDN_HI" "sea1 $EP_IXRS" \
              "sea1 $EP_IXBILAT" "sea1 $EP_TRANSIT" "ash1 $EP_CDN" "ash1 $EP_CLOUD"; do
    set -- $spec
    if eos "$1" "ping $2 repeat 3 timeout 1" | grep -qE '[1-9][0-9]* received'; then
      ok "$1 to $2"; else nok "$1 to $2"; fi
  done

  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
  [[ -f $CUTS  ]] && echo -e "${Y}[i] fibre cut active: $(cat "$CUTS") (./lab.sh uncut)${N}"
  return 0
}

# ---------------------------------------------------------------- exits
exits() {
  echo -e "${B}Where each traffic class leaves the network${N}"
  echo -e "${C}Every destination below is reachable through transit as well as${N}"
  echo -e "${C}through a peer. Which one wins is policy, and policy is money.${N}\n"
  printf "%-24s %-17s %-9s %-11s %-11s %-11s\n" "destination" "prefix" "intended" "sea1" "sea2" "ash1"
  for row in "cloud region A|$EP_CLOUD|cloud" "cloud region B|$EP_CLOUD_B|cloud" \
             "CDN (low half)|$EP_CDN|pni" "CDN (high half)|$EP_CDN_HI|pni" \
             "IX peer via route srv|$EP_IXRS|ix" "IX peer bilateral|$EP_IXBILAT|ix" \
             "transit-only dest|$EP_TRANSIT|transit" "transit1 own space|$EP_T1|transit" \
             "transit2 own space|$EP_T2|transit"; do
    IFS='|' read -r name pfx want <<< "$row"
    printf "%-24s %-17s %-9s" "$name" "$pfx" "$want"
    for n in sea1 sea2 ash1; do
      c=$(cls "$(nh $n $pfx)")
      if [[ "$c" == "$want" ]]; then printf "${G}%-11s${N}" "$c"
      elif [[ "$c" == internal ]]; then printf "%-11s" "$c"
      else printf "${R}%-11s${N}" "$c"; fi
    done; echo
  done
  echo
  echo -e "${Y}[i] 'intended' is the policy design, not a diagnosis. 'internal' means${N}"
  echo -e "${Y}    this router hands the packet to another of ours, which is normal at${N}"
  echo -e "${Y}    ash1 and worth a second look at sea1 or sea2. A peer-reachable${N}"
  echo -e "${Y}    destination on transit is not an outage, it is an invoice:${N}"
  echo -e "${Y}    ./lab.sh cost prices it.${N}"
}

cost() {
  m="cloud=$(cls "$(nh sea1 $EP_CLOUD)"),cdn=$(cls "$(nh sea1 $EP_CDN)")"
  m="$m,ix_rs=$(cls "$(nh sea1 $EP_IXRS)"),ix_bilat=$(cls "$(nh sea1 $EP_IXBILAT)")"
  m="$m,transit_only=$(cls "$(nh sea1 $EP_TRANSIT)")"
  $TP cost --map "$m"
}

# ---------------------------------------------------------------- latency
latency() {
  echo -e "${B}Measured RTT against the inventory${N}\n"
  printf "%-20s %-30s %10s %10s\n" "circuit" "path" "expected" "measured"
  probe() { # label circuit node dst expected
    local out ms
    out=$(eos "$3" "ping $4 repeat 5 timeout 2" | grep -oE 'min/avg/max = [0-9./]+')
    ms=$(echo "$out" | grep -oE '[0-9.]+/[0-9.]+' | head -1 | cut -d/ -f2)
    [[ -z $ms ]] && ms=$(echo "$out" | awk -F'= ' '{print $2}' | cut -d/ -f2)
    printf "%-20s %-30s %9sms %9sms\n" "$2" "$1" "$5" "${ms:-unreachable}"
  }
  probe "sea1 -> sea2 loopback"  DF-SEA-001      sea1 10.255.0.2 0.4
  probe "sea1 -> ash1 loopback"  WAVE-SEA-ASH-A  sea1 10.255.0.3 65
  probe "sea2 -> ash1 loopback"  via-sea1        sea2 10.255.0.3 65.4
  probe "sea1 -> transit1"       TRANSIT-1A      sea1 $EP_T1     0.2
  probe "sea2 -> transit2"       TRANSIT-2       sea2 $EP_T2     95
  probe "sea1 -> CDN"            PNI-CDN-A       sea1 $EP_CDN    0.1
  probe "sea1 -> cloud"          CLOUD-IC-A      sea1 $EP_CLOUD  1.2
  probe "sea1 -> IX peer"        IX-PORT-A       sea1 $EP_IXRS   0.2
  echo
  echo -e "${Y}[i] A measured RTT far above the inventory means the packet is not on${N}"
  echo -e "${Y}    the circuit you think it is, or a 1+1 circuit has switched to its${N}"
  echo -e "${Y}    protect path. Neither one produces a routing event.${N}"
}

# ---------------------------------------------------------------- fibre cuts
cut() {
  local srlg=${1:?usage: ./lab.sh cut <SRLG>   (./lab.sh srlgs to list)}
  local j; j=$($TP cut "$srlg" --json) || { echo "$j"; exit 1; }
  if echo "$j" | grep -q '"error"'; then $TP cut "$srlg"; exit 1; fi
  $TP cut "$srlg"
  echo
  echo "[*] applying to the running lab"
  echo "$j" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for c in d["down"]:
    for node,ifc in c["ends"]: print("DOWN",node,ifc,c["id"])
for c in d["degrade"]:
    for node,ifc in c["ends"]: print("DEGRADE",node,ifc,c["half_delay"])
' | while read -r act node ifc arg; do
      if [[ $act == DOWN ]]; then
        if [[ $node == ixfab ]]; then
          docker exec "$P-ixfab" ip link set "$ifc" down >/dev/null 2>&1
        else
          eoscfg "$node" "interface $(ethname "$ifc")" "shutdown"
        fi
        echo "    down    $node $ifc"
      else
        $CLAB tools netem set -n "$P-$node" -i "$ifc" --delay "$arg" >/dev/null 2>&1 \
          && echo "    protect $node $ifc -> $arg one way"
      fi
    done
  echo "$srlg" > "$CUTS"
  echo "[*] allow ~30s, then ./lab.sh verify and ./lab.sh latency"
}

uncut() {
  echo "[*] restoring all circuits and the baseline latency model"
  for n in "${NODES[@]}"; do
    for i in 1 2 3 4 5 6 7; do
      eoscfg "$n" "interface Ethernet$i" "no shutdown" 2>/dev/null
    done
  done
  for i in 1 2 3 4 5; do docker exec "$P-ixfab" ip link set "eth$i" up >/dev/null 2>&1; done
  apply_latency
  rm -f "$CUTS"; echo "[*] done. Allow ~30s."
}

apply_latency() {
  echo "[*] applying the per-circuit latency model"
  $TP latency | while read -r node ifc delay cid; do
    $CLAB tools netem set -n "$P-$node" -i "$ifc" --delay "$delay" >/dev/null 2>&1 \
      && printf "    %-9s %-6s %-8s %s\n" "$node" "$ifc" "$delay" "$cid"
  done
}

# ---------------------------------------------------------------- faults
fault() {
  case $1 in
    1) eoscfg sea1 "route-map RM-IXRS-IN permit 10" "no match ip address prefix-list PL-IRR-AS65401" ;;
    2) eoscfg sea2 "route-map RM-LEAK permit 10" "router bgp 65010" "neighbor IXRS route-map RM-LEAK out" ;;
    3) eoscfg sea2 "route-map RM-CLOUD-IN permit 10" "set local-preference 500" ;;
    4) eoscfg sea1 "route-map RM-IXBILAT-IN permit 10" "set local-preference 80"
       eoscfg sea2 "route-map RM-IXBILAT-IN permit 10" "set local-preference 80" ;;
    5) eoscfg sea1 "no ip prefix-list PL-IRR-AS65500" "ip prefix-list PL-IRR-AS65500 seq 10 permit 100.120.0.0/16"
       eoscfg sea2 "no ip prefix-list PL-IRR-AS65500" "ip prefix-list PL-IRR-AS65500 seq 10 permit 100.120.0.0/16" ;;
    6) eoscfg sea2 "interface Ethernet6" "ip ospf cost 10" ;;
    7) eoscfg sea2 "router bgp 65010" "neighbor TRANSIT1 route-map RM-OUR-SPACE-OUT out" ;;
    8) eoscfg sea1 "router ospf 1" "passive-interface Ethernet5" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"; : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~45s, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"; echo "[*] fault $1 injected"
  fi
}
restore() {
  for n in "${NODES[@]}"; do
    docker cp "configs/solution/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored"
  done
  for i in 1 2 3 4 5; do docker exec "$P-ixfab" ip link set "eth$i" up >/dev/null 2>&1; done
  apply_latency
  rm -f "$STATE" "$CUTS"; echo "[*] baseline restored. Allow ~45s, then verify."
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
  echo -e "${Y}[i] allow ~60s for BGP and OSPF, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)  deploy ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$CUTS" ;;
  verify)  verify ;;
  exits)   exits ;;
  cost)    cost ;;
  routes)  $TP routes ;;
  srlg)    $TP srlg ;;
  srlgs)   $TP srlgs ;;
  cut)     cut "${2:-}" ;;
  uncut)   uncut ;;
  latency) latency ;;
  netem)   apply_latency ;;
  break)   do_break "${2:-}" ;;
  reveal)  [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active"
           [[ -f $CUTS ]] && echo "active cut: $(cat "$CUTS")" ;;
  restore) restore ;;
  hint)    hint "${2:-}" ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,24p' "$0" ;;
esac
