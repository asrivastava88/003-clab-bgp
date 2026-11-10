#!/usr/bin/env bash
# bgp-lab18 control script  (three regions, two carriers, 38 nodes)
#
#   ./lab.sh deploy                deploy the fabric (allow 8-12 minutes)
#   ./lab.sh destroy               tear down
#   ./lab.sh verify                state checks only; observed vs expected
#   ./lab.sh regions               inter-region reachability and AS paths
#   ./lab.sh transit               is any device or region carrying what it should not
#   ./lab.sh table                 prefix count per tier, both aggregation levels
#   ./lab.sh width                 installed next hops per tier
#   ./lab.sh anycast               where each region's users land for the anycast prefix
#   ./lab.sh paths <prefix>        AS paths at each tier
#   ./lab.sh break                 inject ALL faults at once
#   ./lab.sh break <n>             inject one, for isolated practice
#   ./lab.sh reveal | restore
#   ./lab.sh hint [n]              spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab18; TOPO=bgp-lab18.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
REGIONS=(wst est eur)
SS=(); SPINES=(); LEAVES=(); BORDERS=()
for r in "${REGIONS[@]}"; do
  SS+=("$r-ss1" "$r-ss2"); BORDERS+=("$r-b1" "$r-b2")
  for p in 1 2; do SPINES+=("$r-p$p-s1" "$r-p$p-s2"); LEAVES+=("$r-p$p-l1" "$r-p$p-l2"); done
done
CARRIERS=(wan1 wan2)
source "$DIR/tools/peers.sh"        # PEER[device:far] and IFOF[device:far], generated
NODES=("${SS[@]}" "${SPINES[@]}" "${LEAVES[@]}" "${BORDERS[@]}" "${CARRIERS[@]}")
NFAULTS=12
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

declare -A AGG=( [wst]=10.11.0.0/16 [est]=10.12.0.0/16 [eur]=10.13.0.0/16 )
declare -A BASN=( [wst]=65109 [est]=65209 [eur]=65309 )
declare -A SSASN=( [wst]=65100 [est]=65200 [eur]=65300 )
ANY=10.100.0.0/24; ANYH=10.100.0.1
# one reachable host per region, on pod 1 leaf 1
declare -A HOST=( [wst]=10.11.1.1 [est]=10.12.1.1 [eur]=10.13.1.1 )
declare -A HOST2=( [wst]=10.11.133.1 [est]=10.12.133.1 [eur]=10.13.133.1 )
# the prefix one fault withdraws, still covered by two aggregates above it
MISSING=10.12.6.0/24; MISSINGH=10.12.6.1

nhcount() { eos "$1" "show ip route $2" | grep -cE 'via 10\.'; }
estab()   { eos "$1" "show ip bgp summary" | grep -c Estab; }
rows() {
  local out; out=$(eos "$1" "$2")
  local n; n=$(echo "$out" | grep -oE 'Paths: [0-9]+' | grep -oE '[0-9]+' | head -1)
  [[ -n $n ]] && { echo "$n"; return; }
  if echo "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+'; then
    echo "$out" | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+'
  elif echo "$out" | grep -qiE 'BGP routing table|Router identifier|local AS'; then echo 0
  else echo x; fi
}
paths_n() { rows "$1" "show ip bgp $2"; }
adv()     { rows "$1" "show ip bgp neighbors $2 advertised-routes"; }
aspath()  { eos "$1" "show ip bgp $2" | grep -oE '^ *[0-9]+( [0-9]+)*' | head -1 | xargs; }
check_num() { [[ "${2:-x}" == "$3" ]] && ok "$1: ${2:-0}, expected $3" || nok "$1: ${2:-0}, expected $3"; }
other_regions() { for r in "${REGIONS[@]}"; do [[ $r != "$1" ]] && echo "$r"; done; }

# ---------------------------------------------------------------- verify
verify() {
  echo -e "${B}== Sessions ==${N}"
  for n in "${SS[@]}";      do check_num "$n Established" "$(estab $n)" 6; done
  for n in "${SPINES[@]}";  do check_num "$n Established" "$(estab $n)" 4; done
  for n in "${LEAVES[@]}";  do check_num "$n Established" "$(estab $n)" 2; done
  for n in "${BORDERS[@]}"; do check_num "$n Established" "$(estab $n)" 4; done
  for n in "${CARRIERS[@]}";do check_num "$n Established" "$(estab $n)" 6; done

  echo -e "${B}== Aggregation level 1: a super-spine sees pods, not servers ==${N}"
  for r in "${REGIONS[@]}"; do
    for i in 1 2; do
      check_num "$r-ss$i paths to its pod-1 aggregate" "$(paths_n $r-ss$i ${AGG[$r]%/16}/17)" 2
      check_num "$r-ss$i server subnets held" \
        "$(eos $r-ss$i 'show ip bgp' | grep -cE '10\.1[123]\.[0-9]+\.0/24')" 0
    done
  done

  echo -e "${B}== Aggregation level 2: a carrier sees regions, not pods ==${N}"
  for w in "${CARRIERS[@]}"; do
    for r in "${REGIONS[@]}"; do
      check_num "$w paths to ${AGG[$r]}" "$(paths_n $w ${AGG[$r]})" 2
    done
    check_num "$w pod aggregates held" \
      "$(eos $w 'show ip bgp' | grep -cE '10\.1[123]\.(0|128)\.0/17')" 0
    check_num "$w paths to $ANY" "$(paths_n $w $ANY)" 6
  done

  echo -e "${B}== No region is a transit path between two others ==${N}"
  for r in "${REGIONS[@]}"; do
    for bi in 1 2; do
      for other in $(other_regions $r); do
        c=$(eos "$r-b$bi" "show ip bgp ${AGG[$other]}" | grep -c "${BASN[$r]}")
        check_num "$r-b$bi advertises nothing of $other onward" "${c:-0}" 0
      done
    done
  done
  for w in "${CARRIERS[@]}"; do
    for r in "${REGIONS[@]}"; do
      n=$(eos "$w" "show ip bgp ${AGG[$r]}" | grep -cE '(65109|65209|65309) +(65500|65600)')
      check_num "$w sees no region transiting for ${AGG[$r]}" "${n:-0}" 0
    done
  done

  echo -e "${B}== Advertisement discipline ==${N}"
  for r in "${REGIONS[@]}"; do
    for bi in 1 2; do
      for w in 1 2; do
        a=$(adv "$r-b$bi" "${PEER[$r-b$bi:wan$w]}")
        check_num "$r-b$bi advertises to wan$w" "${a:-0}" 2
      done
    done
  done

  echo -e "${B}== ECMP width ==${N}"
  for r in "${REGIONS[@]}"; do
    for other in $(other_regions $r); do
      check_num "$r-p1-l1 next hops to ${AGG[$other]}" "$(nhcount $r-p1-l1 ${AGG[$other]})" 2
      check_num "$r-b1 next hops to ${AGG[$other]}"    "$(nhcount $r-b1 ${AGG[$other]})" 2
    done
    check_num "$r-ss1 next hops to ${AGG[$r]%/16}/17" "$(nhcount $r-ss1 ${AGG[$r]%/16}/17)" 2
  done

  echo -e "${B}== Reachability across regions, and inside the aggregates ==${N}"
  for r in "${REGIONS[@]}"; do
    for other in $(other_regions $r); do
      if eos "$r-p1-l1" "ping ${HOST[$other]} source ${HOST[$r]} repeat 2 timeout 2" \
           | grep -qE '[1-9][0-9]* received'; then ok "$r to $other"; else nok "$r to $other"; fi
    done
    if eos "$r-p2-l2" "ping ${HOST2[$(echo $(other_regions $r) | cut -d' ' -f1)]} source ${HOST2[$r]} repeat 2 timeout 2" \
         | grep -qE '[1-9][0-9]* received'; then ok "$r pod 2 reaches a remote pod 2"; else nok "$r pod 2 reaches a remote pod 2"; fi
  done
  if eos wst-p1-l2 "ping $MISSINGH source 10.11.5.1 repeat 2 timeout 2" | grep -qE '[1-9][0-9]* received'; then
    ok "wst reaches $MISSINGH"; else nok "wst reaches $MISSINGH"; fi

  echo -e "${B}== Anycast: every region serves itself ==${N}"
  for r in "${REGIONS[@]}"; do
    check_num "$r-p2-l1 paths to $ANY" "$(paths_n $r-p2-l1 $ANY)" 2
    check_num "$r-p2-l1 anycast best path stays in region" \
      "$(eos "$r-p2-l1" "show ip route $ANY" | grep -cE 'via 10\.254')" 2
  done

  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
  return 0
}
# ---------------------------------------------------------------- regions
regions() {
  echo -e "${B}Inter-region reachability, and whose network carries it${N}"
  echo -e "${C}Inside a region the ASN plan stops a device transiting between its own${N}"
  echo -e "${C}peers. Across regions nothing does, because the two carriers are${N}"
  echo -e "${C}different ASes. Only the border's outbound policy stands in the way.${N}\n"
  printf "  %-8s %-16s %7s  %s\n" "from" "to" "paths" "AS path of the best route"
  printf "  %s\n" "---------------------------------------------------------------------------"
  for r in "${REGIONS[@]}"; do
    for other in $(other_regions $r); do
      n=$(paths_n "$r-b1" "${AGG[$other]}")
      ap=$(eos "$r-b1" "show ip bgp ${AGG[$other]}" | grep -oE '6[0-9]{4}( 6[0-9]{4})*' | head -1)
      bad=""
      for x in "${REGIONS[@]}"; do
        [[ $x == "$r" || $x == "$other" ]] && continue
        echo "$ap" | grep -q "${BASN[$x]}" && bad=" ${R}<- via region $x${N}"
      done
      printf "  %-8s %-16s %7s  %s%b\n" "$r-b1" "${AGG[$other]}" "${n:-0}" "${ap:-none}" "$bad"
    done
  done
  echo
  echo -e "${B}What each carrier believes about each region${N}"
  printf "  %-6s %-16s %7s  %s\n" "at" "region" "paths" "any path with a region AS in the middle"
  printf "  %s\n" "---------------------------------------------------------------------------"
  for w in "${CARRIERS[@]}"; do
    for r in "${REGIONS[@]}"; do
      n=$(paths_n "$w" "${AGG[$r]}")
      t=$(eos "$w" "show ip bgp ${AGG[$r]}" | grep -cE '(65109|65209|65309) +(65500|65600)')
      col=$G; [[ ${t:-0} -gt 0 ]] && col=$R
      printf "  %-6s %-16s %7s  ${col}%s${N}\n" "$w" "${AGG[$r]}" "${n:-0}" "${t:-0}"
    done
  done
  echo
  echo -e "${Y}[i] A region ASN followed by a carrier ASN means that region re-announced${N}"
  echo -e "${Y}    what a carrier told it. That is a route leak, and it is the single${N}"
  echo -e "${Y}    most consequential thing that can go wrong at a region border.${N}"
}

transit() {
  echo -e "${B}Advertisement discipline, per role${N}\n"
  printf "  %-10s %-12s %-16s %8s %9s\n" "device" "role" "to" "advert" "expected"
  printf "  %s\n" "---------------------------------------------------------------------"
  for r in "${REGIONS[@]}"; do
    for l in "$r-p1-l1" "$r-p2-l2"; do
      for i in 1 2; do
        sp=${PEER[$l:$(echo $l | sed 's/-l[12]$/'"-s$i"'/')]}
        [[ -z $sp ]] && continue
        e=5; [[ $l == *p1-l1 ]] && e=6     # pod-1 leaf 1 also originates anycast
        c=$(adv "$l" "$sp"); col=$G; [[ "${c:-x}" != "$e" ]] && col=$R
        printf "  %-10s %-12s %-16s ${col}%8s${N} %9s\n" "$l" "leaf" "$sp" "${c:-0}" "$e"
      done
    done
    for bi in 1 2; do
      for w in 1 2; do
        wp=${PEER[$r-b$bi:wan$w]}
        c=$(adv "$r-b$bi" "$wp"); col=$G; [[ "${c:-x}" != "2" ]] && col=$R
        printf "  %-10s %-12s %-16s ${col}%8s${N} %9s\n" "$r-b$bi" "border up" "wan$w" "${c:-0}" 2
      done
    done
  done
  echo
  echo -e "${Y}[i] A border announces its region aggregate and the anycast prefix. Two.${N}"
  echo -e "${Y}    Any number above that is this region offering itself as a path${N}"
  echo -e "${Y}    between the other two.${N}"
}

table() {
  echo -e "${B}Prefix count by tier. Two aggregation boundaries, two places to leak.${N}\n"
  printf "  %-10s %-12s %9s %9s %9s\n" "device" "tier" "prefixes" "/24s" "/17s"
  printf "  %s\n" "------------------------------------------------------------"
  for n in "${CARRIERS[@]}" "${BORDERS[@]}" "${SS[@]}" "${SPINES[@]:0:4}" "${LEAVES[@]:0:2}"; do
    t=$(case $n in wan*) echo carrier;; *-b*) echo border;; *-ss*) echo superspine;;
                   *-s[12]) echo spine;; *) echo leaf;; esac)
    o=$(eos "$n" "show ip bgp")
    tot=$(echo "$o" | grep -cE '^ *[*>SiaerR ]+ +[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')
    s24=$(echo "$o" | grep -cE '10\.1[123]\.[0-9]+\.0/24')
    s17=$(echo "$o" | grep -cE '10\.1[123]\.(0|128)\.0/17')
    c24=$G; [[ $t == carrier || $t == superspine ]] && [[ ${s24:-0} -gt 0 ]] && c24=$R
    c17=$G; [[ $t == carrier ]] && [[ ${s17:-0} -gt 0 ]] && c17=$R
    printf "  %-10s %-12s %9s ${c24}%9s${N} ${c17}%9s${N}\n" "$n" "$t" "${tot:-0}" "${s24:-0}" "${s17:-0}"
  done
  echo
  echo -e "${Y}[i] A super-spine should see zero /24s. A carrier should see zero /24s${N}"
  echo -e "${Y}    AND zero /17s: at that distance the only correct unit is a region.${N}"
}

width() {
  echo -e "${B}Installed next hops${N}\n"
  printf "  %-10s %-12s" "device" "tier"
  for r in "${REGIONS[@]}"; do printf " %13s" "${AGG[$r]}"; done
  printf " %13s\n" "$ANY"
  printf "  %s\n" "-------------------------------------------------------------------------------------"
  for n in "${CARRIERS[@]}" "${BORDERS[@]}" "${SS[@]}" wst-p1-s1 wst-p1-l1 est-p2-l2; do
    t=$(case $n in wan*) echo carrier;; *-b*) echo border;; *-ss*) echo superspine;;
                   *-s[12]) echo spine;; *) echo leaf;; esac)
    printf "  %-10s %-12s" "$n" "$t"
    for p in "${AGG[wst]}" "${AGG[est]}" "${AGG[eur]}" "$ANY"; do
      c=$(nhcount "$n" "$p")
      if [[ ${c:-0} -ge 2 ]]; then printf "${G}%13s${N}" "$c"
      elif [[ ${c:-0} -eq 1 ]]; then printf "${Y}%13s${N}" "$c"
      else printf "${R}%13s${N}" "0"; fi
    done; echo
  done
  echo
  echo -e "${Y}[i] 0 is correct where the device originates or is inside the prefix.${N}"
}

anycast() {
  echo -e "${B}Anycast: $ANY is originated once per region${N}\n"
  printf "  %-12s %7s  %s\n" "vantage" "paths" "best AS path"
  printf "  %s\n" "-----------------------------------------------------"
  for n in wst-p2-l1 est-p2-l1 eur-p2-l1 wan1 wan2; do
    pn=$(paths_n "$n" "$ANY")
    ap=$(eos "$n" "show ip bgp $ANY" | grep -oE '6[0-9]{4}( 6[0-9]{4})*' | head -1)
    printf "  %-12s %7s  %s\n" "$n" "${pn:-0}" "${ap:-none}"
  done
  echo
  echo -e "${Y}[i] Every region should serve itself: a leaf's best path to the anycast${N}"
  echo -e "${Y}    prefix should never contain a carrier ASN. One that does means that${N}"
  echo -e "${Y}    region's users are crossing a WAN for a service in their own building.${N}"
}

paths() {
  local d=${1:-${AGG[est]}}
  for n in wst-p1-l1 wst-ss1 wst-b1 wan1 est-b1; do
    echo -e "${C}=== $n ===${N}"; eos "$n" "show ip bgp $d" | grep -vE '^$' | head -16
  done
}

# ---------------------------------------------------------------- faults
fault() {
  case $1 in
    1)  eoscfg wst-b1 "route-map RM-ALL permit 10" "router bgp 65109" \
                      "neighbor CARRIER-65500 route-map RM-ALL out" \
                      "neighbor CARRIER-65600 route-map RM-ALL out" ;;
    2)  eoscfg wan2 "ip prefix-list PL-F2 seq 10 deny 10.12.0.0/16" \
                    "ip prefix-list PL-F2 seq 20 permit 0.0.0.0/0 le 32" \
                    "route-map RM-F2 permit 10" "match ip address prefix-list PL-F2" \
                    "router bgp 65600" "neighbor BORDER-65209 route-map RM-F2 in" ;;
    3)  eoscfg eur-b2 "ip prefix-list PL-F3 seq 10 deny 10.11.0.0/16" \
                      "ip prefix-list PL-F3 seq 20 permit 0.0.0.0/0 le 32" \
                      "route-map RM-WAN-IN permit 10" "match ip address prefix-list PL-F3" ;;
    4)  eoscfg est-p2-s2 "router bgp 65202" "address-family ipv4" "no network 10.12.128.0/17" ;;
    5)  eoscfg wst-b2 "ip prefix-list PL-REGION-OUT seq 5 permit 10.11.0.0/16 ge 17 le 17" ;;
    6)  eoscfg est-p1-l2 "router bgp 65212" "address-family ipv4" "no network 10.12.6.0/24" ;;
    7)  eoscfg eur-ss1 "router bgp 65300" "maximum-paths 1" ;;
    8)  eoscfg wst-p1-l2 "ip route 10.12.0.0/16 ${PEER[wst-p1-l2:wst-p1-s2]}" ;;
    9)  eoscfg eur-p1-l1 "router bgp 65311" "address-family ipv4" "no network 10.100.0.0/24" ;;
    10) eoscfg est-b2 "route-map RM-WAN-OUT permit 10" "set as-path prepend 65209 65209" ;;
    11) eoscfg wst-p2-s1 "router bgp 65102" "no neighbor LEAF-65114" ;;
    12) eoscfg eur-b1 "router bgp 65309" "no neighbor CARRIER-65500" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"; : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~90s at this size, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"; echo "[*] fault $1 injected"
  fi
}
restore() {
  echo "[*] restoring 38 devices, this takes a minute"
  for n in "${NODES[@]}"; do
    docker cp "configs/solution/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && printf "."
  done
  echo; rm -f "$STATE"; echo "[*] baseline restored. Allow ~90s, then verify."
}
hint() {
  echo -e "${Y}These are spoilers. Close the window if you did not mean to run this.${N}"; echo
  if [[ -n ${1:-} ]]; then sed -n "/^### fault $1\$/,/^### /p" docs/HINTS.md | head -n -1
  else cat docs/HINTS.md; fi
}
deploy() {
  python3 tools/gen_configs.py >/dev/null
  cp -f configs/solution/*.cfg configs/active/
  echo "[*] 38 cEOS nodes. Expect 8-12 minutes and roughly 55 GB."
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  printf "[*] waiting for cEOS"
  for n in "${NODES[@]}"; do
    for _ in $(seq 1 90); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
  echo -e "${Y}[i] allow ~90s for BGP across three regions, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)  deploy ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" ;;
  verify)  verify ;;
  regions) regions ;;
  transit) transit ;;
  table)   table ;;
  width)   width ;;
  anycast) anycast ;;
  paths)   paths "${2:-}" ;;
  break)   do_break "${2:-}" ;;
  reveal)  [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active" ;;
  restore) restore ;;
  hint)    hint "${2:-}" ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,20p' "$0" ;;
esac
