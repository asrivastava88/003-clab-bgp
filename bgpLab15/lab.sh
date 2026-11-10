#!/usr/bin/env bash
# bgp-lab15 control script  (dual-stack carrier edge: IPv4/IPv6 policy parity)
#
#   ./lab.sh deploy                deploy the lab
#   ./lab.sh destroy               tear down
#   ./lab.sh verify                state checks only; observed vs expected
#   ./lab.sh afi                   IPv4 against IPv6, session by session
#   ./lab.sh exits                 chosen exit per destination, per family
#   ./lab.sh parity                config audit: every v4 construct vs its v6 twin
#   ./lab.sh drain <edge1|edge2>   graceful drain, and verify BOTH families moved
#   ./lab.sh undrain               restore normal policy
#   ./lab.sh break                 inject ALL faults at once
#   ./lab.sh break <n>             inject one, for isolated practice
#   ./lab.sh reveal | restore
#   ./lab.sh hint [n]              spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab15; TOPO=bgp-lab15.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
NODES=(edge1 edge2 transit1 transit2 peer1 peer2 cust1)
OURS=(edge1 edge2)
NFAULTS=8
STATE="$DIR/.active_faults"; DRAINED="$DIR/.drained"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

# our space
OUR4_A=198.18.0.0/23; OUR4_B=198.18.2.0/23
OUR6_A=2001:db8:10::/44; OUR6_B=2001:db8:20::/44
# the more-specific of our own space that transit1 announces on purpose
LEAK4=198.18.1.0/24; LEAK6=2001:db8:18::/48
# destinations, paired by family
D_P1_4=100.110.0.0/16;  D_P1_6=2001:db8:110::/48
D_P2_6=2001:db8:111::/48
D_TO_4=100.200.0.0/16;  D_TO_6=2001:db8:200::/48
D_T2_4=100.101.0.0/16;  D_T2_6=2001:db8:101::/48
D_CU_4=198.51.100.0/24; D_CU_6=2001:db8:40::/48
# hosts
H_P1_4=100.110.0.1; H_P1_6=2001:db8:110::1
H_P2_6=2001:db8:111::1
H_TO_4=100.200.0.1; H_TO_6=2001:db8:200::1
H_CU_4=198.51.100.1; H_CU_6=2001:db8:40::1
# neighbour addresses, by family
declare -A NB4=( [edge1:t1]=10.1.1.2 [edge2:t1]=10.1.2.2 [edge2:t2]=10.2.1.2
                 [edge1:p1]=10.3.1.2 [edge2:p1]=10.3.2.2 [edge1:cu]=10.5.1.2 )
declare -A NB6=( [edge1:t1]=2001:db8:ffff:11::2 [edge2:t1]=2001:db8:ffff:12::2
                 [edge2:t2]=2001:db8:ffff:21::2 [edge1:p1]=2001:db8:ffff:31::2
                 [edge2:p1]=2001:db8:ffff:32::2 [edge1:p2]=2001:db8:ffff:41::2
                 [edge2:p2]=2001:db8:ffff:42::2 [edge1:cu]=2001:db8:ffff:51::2 )

nh4() { eos "$1" "show ip route $2" | grep -oE 'via [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed 's/via //' | head -1; }
nh6() { eos "$1" "show ipv6 route $2" | grep -oE 'via [0-9a-fA-F:]+:[0-9a-fA-F:]*' | sed 's/via //' | head -1; }
est4() { eos "$1" "show ip bgp summary" | grep -c Estab; }
est6() { eos "$1" "show bgp ipv6 unicast summary" | grep -c Estab; }

rows() { # node, command -> count of prefix rows, or x when unreadable
  local out; out=$(eos "$1" "$2")
  local n; n=$(echo "$out" | grep -oE 'Paths: [0-9]+' | grep -oE '[0-9]+' | head -1)
  [[ -n $n ]] && { echo "$n"; return; }
  if echo "$out" | grep -qE '^ *[*>SiaerR ]+ +[0-9a-fA-F:.]+/[0-9]+'; then
    echo "$out" | grep -cE '^ *[*>SiaerR ]+ +[0-9a-fA-F:.]+/[0-9]+'
  elif echo "$out" | grep -qiE 'BGP routing table|Router identifier|local AS number'; then echo 0
  else echo x; fi
}
acc4() { rows "$1" "show ip bgp neighbors $2 routes"; }
acc6() { rows "$1" "show bgp ipv6 unicast neighbors $2 routes"; }
adv4() { rows "$1" "show ip bgp neighbors $2 advertised-routes"; }
adv6() { rows "$1" "show bgp ipv6 unicast neighbors $2 advertised-routes"; }
paths4() { rows "$1" "show ip bgp $2"; }
paths6() { rows "$1" "show bgp ipv6 unicast $2"; }

# classify a next hop into the relationship it leaves on
cls() {
  case "$1" in
    10.1.1.2|10.1.2.2|2001:db8:ffff:11::2|2001:db8:ffff:12::2) echo t1 ;;
    10.2.1.2|2001:db8:ffff:21::2)                              echo t2 ;;
    10.3.1.2|10.3.2.2|2001:db8:ffff:31::2|2001:db8:ffff:32::2) echo p1 ;;
    2001:db8:ffff:41::2|2001:db8:ffff:42::2)                   echo p2 ;;
    10.5.1.2|2001:db8:ffff:51::2)                              echo cust ;;
    10.255.0.1|2001:db8:ffff:ffff::1)                          echo edge1 ;;
    10.255.0.2|2001:db8:ffff:ffff::2)                          echo edge2 ;;
    "")                                                        echo none ;;
    *)                                                         echo unknown ;;
  esac
}
check_eq()  { [[ "$2" == "$3" ]] && ok "$1: $2, expected $3" || nok "$1: ${2:-<empty>}, expected $3"; }
check_num() { [[ "${2:-x}" == "$3" ]] && ok "$1: ${2:-0}, expected $3" || nok "$1: ${2:-0}, expected $3"; }

# ---------------------------------------------------------------- verify
verify() {
  echo -e "${B}== Sessions, per address family ==${N}"
  check_num "edge1 IPv4 Established" "$(est4 edge1)" 4
  check_num "edge1 IPv6 Established" "$(est6 edge1)" 5
  check_num "edge2 IPv4 Established" "$(est4 edge2)" 4
  check_num "edge2 IPv6 Established" "$(est6 edge2)" 5
  check_num "transit1 IPv4 Established" "$(est4 transit1)" 2
  check_num "transit1 IPv6 Established" "$(est6 transit1)" 2
  check_num "peer1 IPv4 Established" "$(est4 peer1)" 2
  check_num "peer1 IPv6 Established" "$(est6 peer1)" 2
  check_num "peer2 IPv6 Established" "$(est6 peer2)" 2
  check_num "cust1 IPv4 Established" "$(est4 cust1)" 1
  check_num "cust1 IPv6 Established" "$(est6 cust1)" 1

  echo -e "${B}== Our own space must never be accepted back from anyone ==${N}"
  check_num "edge1 IPv4 accepted from transit1" "$(acc4 edge1 ${NB4[edge1:t1]})" 2
  check_num "edge1 IPv6 accepted from transit1" "$(acc6 edge1 ${NB6[edge1:t1]})" 2
  check_num "edge2 IPv4 accepted from transit1" "$(acc4 edge2 ${NB4[edge2:t1]})" 2
  check_num "edge2 IPv6 accepted from transit1" "$(acc6 edge2 ${NB6[edge2:t1]})" 2
  check_num "edge1 IPv4 paths to $LEAK4" "$(paths4 edge1 $LEAK4)" 0
  check_num "edge1 IPv6 paths to $LEAK6" "$(paths6 edge1 $LEAK6)" 0

  echo -e "${B}== Our customer must be announced to every upstream, in both families ==${N}"
  check_num "edge1 IPv4 advertised to transit1" "$(adv4 edge1 ${NB4[edge1:t1]})" 3
  check_num "edge1 IPv6 advertised to transit1" "$(adv6 edge1 ${NB6[edge1:t1]})" 3
  check_num "edge1 IPv4 advertised to peer1"    "$(adv4 edge1 ${NB4[edge1:p1]})" 3
  check_num "edge1 IPv6 advertised to peer1"    "$(adv6 edge1 ${NB6[edge1:p1]})" 3
  check_num "edge1 IPv6 advertised to peer2"    "$(adv6 edge1 ${NB6[edge1:p2]})" 3
  check_num "transit1 IPv4 paths to $D_CU_4"    "$(paths4 transit1 $D_CU_4)" 2
  check_num "transit1 IPv6 paths to $D_CU_6"    "$(paths6 transit1 $D_CU_6)" 2

  echo -e "${B}== Exit selection must match between families ==${N}"
  check_eq "edge1 IPv4 exit for peer1" "$(cls "$(nh4 edge1 $D_P1_4)")" p1
  check_eq "edge1 IPv6 exit for peer1" "$(cls "$(nh6 edge1 $D_P1_6)")" p1
  check_eq "edge2 IPv4 exit for peer1" "$(cls "$(nh4 edge2 $D_P1_4)")" p1
  check_eq "edge2 IPv6 exit for peer1" "$(cls "$(nh6 edge2 $D_P1_6)")" p1
  check_eq "edge1 IPv6 exit for peer2" "$(cls "$(nh6 edge1 $D_P2_6)")" p2
  check_eq "edge2 IPv6 exit for peer2" "$(cls "$(nh6 edge2 $D_P2_6)")" p2
  check_eq "edge1 IPv4 exit for transit-only" "$(cls "$(nh4 edge1 $D_TO_4)")" t1
  check_eq "edge1 IPv6 exit for transit-only" "$(cls "$(nh6 edge1 $D_TO_6)")" t1
  check_eq "edge2 IPv4 exit for transit2 space" "$(cls "$(nh4 edge2 $D_T2_4)")" t2
  check_eq "edge2 IPv6 exit for transit2 space" "$(cls "$(nh6 edge2 $D_T2_6)")" t2
  check_eq "edge1 IPv4 exit for the customer" "$(cls "$(nh4 edge1 $D_CU_4)")" cust
  check_eq "edge1 IPv6 exit for the customer" "$(cls "$(nh6 edge1 $D_CU_6)")" cust

  echo -e "${B}== IPv6 next hops learned over iBGP must resolve ==${N}"
  check_eq "edge1 IPv6 exit for transit2 space" "$(cls "$(nh6 edge1 $D_T2_6)")" edge2
  check_eq "edge1 IPv4 exit for transit2 space" "$(cls "$(nh4 edge1 $D_T2_4)")" edge2
  check_eq "edge2 IPv6 exit for the customer"   "$(cls "$(nh6 edge2 $D_CU_6)")" edge1
  check_eq "edge2 IPv4 exit for the customer"   "$(cls "$(nh4 edge2 $D_CU_4)")" edge1

  echo -e "${B}== Inbound traffic engineering, both families ==${N}"
  check_num "transit2 IPv4 paths to $OUR4_A" "$(paths4 transit2 $OUR4_A)" 1
  check_num "transit2 IPv6 paths to $OUR6_A" "$(paths6 transit2 $OUR6_A)" 1
  for spec in "4 $OUR4_A" "6 $OUR6_A"; do
    set -- $spec
    if [[ $1 == 4 ]]; then p=$(eos transit2 "show ip bgp $2" | grep -cE '65010 65010 65010')
    else p=$(eos transit2 "show bgp ipv6 unicast $2" | grep -cE '65010 65010 65010'); fi
    check_num "transit2 sees our AS prepended twice in IPv$1" "${p:-0}" 1
  done

  echo -e "${B}== Reachability, both families ==${N}"
  for spec in "edge1 4 $H_P1_4" "edge1 6 $H_P1_6" "edge1 6 $H_P2_6" \
              "edge2 4 $H_TO_4" "edge2 6 $H_TO_6" "edge2 4 $H_CU_4" "edge2 6 $H_CU_6" \
              "cust1 4 $H_P1_4" "cust1 6 $H_P1_6" "cust1 6 $H_P2_6"; do
    set -- $spec
    c=$([[ $2 == 4 ]] && echo "ping $3" || echo "ping ipv6 $3")
    if eos "$1" "$c repeat 3 timeout 2" | grep -qE '[1-9][0-9]* received'; then
      ok "$1 to $3 (IPv$2)"; else nok "$1 to $3 (IPv$2)"; fi
  done

  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]]   && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
  [[ -f $DRAINED ]] && echo -e "${Y}[i] $(cat "$DRAINED") is drained (./lab.sh undrain)${N}"
  return 0
}

# ---------------------------------------------------------------- afi
afi() {
  echo -e "${B}IPv4 against IPv6, session by session${N}"
  echo -e "${C}A dual-stack network is two networks that share a chassis. Anything${N}"
  echo -e "${C}that differs below is a place where the two were changed at different${N}"
  echo -e "${C}times. 'n/a' is correct only where a relationship is single-family.${N}\n"
  printf "  %-16s %-9s %-9s %-9s %-9s %-9s %-9s\n" \
         "relationship" "v4 state" "v6 state" "v4 recv" "v6 recv" "v4 adv" "v6 adv"
  printf "  %s\n" "----------------------------------------------------------------------------------"
  for key in edge1:t1 edge1:p1 edge1:p2 edge1:cu edge2:t1 edge2:t2 edge2:p1 edge2:p2; do
    node=${key%%:*}
    a4=${NB4[$key]:-}; a6=${NB6[$key]:-}
    if [[ -n $a4 ]]; then
      s4=$(eos "$node" "show ip bgp summary" | grep "$a4" | grep -qE 'Estab' && echo up || echo DOWN)
      r4=$(acc4 "$node" "$a4"); v4=$(adv4 "$node" "$a4")
    else s4=n/a; r4=n/a; v4=n/a; fi
    if [[ -n $a6 ]]; then
      s6=$(eos "$node" "show bgp ipv6 unicast summary" | grep "$a6" | grep -qE 'Estab' && echo up || echo DOWN)
      r6=$(acc6 "$node" "$a6"); v6=$(adv6 "$node" "$a6")
    else s6=n/a; r6=n/a; v6=n/a; fi
    printf "  %-16s" "$key"
    for pair in "$s4 $s6" "$r4 $r6" "$v4 $v6"; do
      set -- $pair
      if [[ "$1" == "$2" || "$1" == n/a || "$2" == n/a ]]; then
        printf "${G}%-9s${N}${G}%-9s${N}" "$1" "$2"
      else
        printf "${R}%-9s${N}${R}%-9s${N}" "$1" "$2"
      fi
    done; echo
  done
  echo
  echo -e "${Y}[i] 'recv' is what survived inbound policy, not what arrived. 'adv' is${N}"
  echo -e "${Y}    what we send. A v4/v6 pair that disagrees is the finding; a pair${N}"
  echo -e "${Y}    that agrees can still be wrong in both families at once.${N}"
}

exits() {
  echo -e "${B}Chosen exit per destination, per address family${N}\n"
  printf "  %-14s %-22s %-10s %-22s %-10s\n" "from" "IPv4 prefix" "exit" "IPv6 prefix" "exit"
  printf "  %s\n" "----------------------------------------------------------------------------------"
  show() { # node v4pfx v6pfx label
    local e4 e6 c
    e4=$(cls "$(nh4 "$1" "$2")"); e6=$(cls "$(nh6 "$1" "$3")")
    [[ "$e4" == "$e6" ]] && c=$G || c=$R
    printf "  %-14s %-22s ${c}%-10s${N} %-22s ${c}%-10s${N}\n" "$1" "$2" "$e4" "$3" "$e6"
  }
  for n in edge1 edge2; do
    show "$n" "$D_P1_4" "$D_P1_6"
    show "$n" "$D_TO_4" "$D_TO_6"
    show "$n" "$D_T2_4" "$D_T2_6"
    show "$n" "$D_CU_4" "$D_CU_6"
  done
  echo
  echo -e "${Y}[i] The two columns of exits should be identical everywhere. peer2 is${N}"
  echo -e "${Y}    IPv6 only and has no row here, which is the one case where the${N}"
  echo -e "${Y}    families legitimately cannot match.${N}"
}

# ---------------------------------------------------------------- drain
drain() {
  local t=${1:?usage: ./lab.sh drain <edge1|edge2>}
  [[ $t == edge1 || $t == edge2 ]] || { echo "target must be edge1 or edge2"; exit 1; }
  echo -e "${B}Draining $t${N}"
  echo "[*] applying the pre-staged drain policy in both address families"
  local n4 n6 cmd4=() cmd6=()
  for key in "${!NB4[@]}"; do
    [[ $key == $t:* ]] || continue
    cmd4+=("neighbor ${NB4[$key]} route-map RM-DRAIN-IN in"
           "neighbor ${NB4[$key]} route-map RM-DRAIN-OUT out")
  done
  for key in "${!NB6[@]}"; do
    [[ $key == $t:* ]] || continue
    cmd6+=("neighbor ${NB6[$key]} route-map RM-DRAIN-IN6 in"
           "neighbor ${NB6[$key]} route-map RM-DRAIN-OUT6 out")
  done
  eoscfg "$t" "router bgp 65010" "address-family ipv4" "${cmd4[@]}"
  eoscfg "$t" "router bgp 65010" "address-family ipv6" "${cmd6[@]}"
  echo "$t" > "$DRAINED"
  echo "[*] waiting 45s for the internet to reconverge"; sleep 45
  drain_check "$t"
}

drain_check() {
  local t=$1 other p4 p6 n4 n6 want
  other=$([[ $t == edge1 ]] && echo edge2 || echo edge1)
  echo
  echo -e "${B}Did the drain take effect in BOTH address families?${N}"
  echo -e "${C}A correct drain leaves the path PRESENT and de-preferred, so the${N}"
  echo -e "${C}drained border is still a backup. A drain that withdraws the path is${N}"
  echo -e "${C}not a drain, it is an outage with extra steps.${N}\n"
  for spec in "4 $OUR4_A" "6 $OUR6_A"; do
    set -- $spec
    if [[ $1 == 4 ]]; then
      p=$(paths4 transit1 "$2"); nhx=$(nh4 transit1 "$2")
      want=$([[ $other == edge1 ]] && echo 10.1.1.1 || echo 10.1.2.1)
    else
      p=$(paths6 transit1 "$2"); nhx=$(nh6 transit1 "$2")
      want=$([[ $other == edge1 ]] && echo 2001:db8:ffff:11::1 || echo 2001:db8:ffff:12::1)
    fi
    printf "  IPv%s  paths at transit1: " "$1"
    [[ "${p:-0}" == "2" ]] && printf "${G}%s${N}" "${p}, both still present" \
                           || printf "${R}%s${N}" "${p:-0}, expected 2"
    printf "   best via: "
    [[ "$nhx" == "$want" ]] && printf "${G}%s${N} (%s)\n" "$nhx" "$other" \
                            || printf "${R}%s${N}, expected %s (%s)\n" "${nhx:-none}" "$want" "$other"
  done
  echo
  echo -e "${Y}[i] Both lines must be green. One green and one red means the${N}"
  echo -e "${Y}    maintenance is safe for one address family and not the other.${N}"
}

undrain() {
  echo "[*] restoring normal policy on both borders, both families"
  for t in edge1 edge2; do
    local cmd4=() cmd6=()
    for key in "${!NB4[@]}"; do
      [[ $key == $t:* ]] || continue
      local rin rout; rin=RM-T1-IN; rout=RM-EXT-OUT
      case $key in
        *:t1) rin=RM-T1-IN;  rout=RM-EXT-OUT ;;
        *:t2) rin=RM-T2-IN;  rout=RM-T2-OUT ;;
        *:p1) rin=RM-P1-IN;  rout=RM-EXT-OUT ;;
        *:cu) rin=RM-CU-IN;  rout=RM-EXT-OUT ;;
      esac
      cmd4+=("neighbor ${NB4[$key]} route-map $rin in" "neighbor ${NB4[$key]} route-map $rout out")
    done
    for key in "${!NB6[@]}"; do
      [[ $key == $t:* ]] || continue
      local rin rout; rin=RM-T1-IN6; rout=RM-EXT-OUT6
      case $key in
        *:t1) rin=RM-T1-IN6; rout=RM-EXT-OUT6 ;;
        *:t2) rin=RM-T2-IN6; rout=RM-T2-OUT6 ;;
        *:p1) rin=RM-P1-IN6; rout=RM-EXT-OUT6 ;;
        *:p2) rin=RM-P2-IN6; rout=RM-EXT-OUT6 ;;
        *:cu) rin=RM-CU-IN6; rout=RM-EXT-OUT6 ;;
      esac
      cmd6+=("neighbor ${NB6[$key]} route-map $rin in" "neighbor ${NB6[$key]} route-map $rout out")
    done
    [[ ${#cmd4[@]} -gt 0 ]] && eoscfg "$t" "router bgp 65010" "address-family ipv4" "${cmd4[@]}"
    [[ ${#cmd6[@]} -gt 0 ]] && eoscfg "$t" "router bgp 65010" "address-family ipv6" "${cmd6[@]}"
  done
  rm -f "$DRAINED"; echo "[*] done. Allow ~45s, then ./lab.sh verify"
}

parity() {
  local tmp; tmp=$(mktemp -d)
  for n in "${OURS[@]}"; do eos "$n" "show running-config" > "$tmp/$n.cfg"; done
  python3 "$DIR/tools/parity.py" "$tmp"/*.cfg
  local rc=$?; rm -rf "$tmp"; return $rc
}

# ---------------------------------------------------------------- faults
fault() {
  case $1 in
    1) eoscfg edge1 "router bgp 65010" "address-family ipv6" \
                    "no neighbor ${NB6[edge1:p1]} activate" ;;
    2) eoscfg edge2 "route-map RM-P1-IN6 permit 10" "set local-preference 80" ;;
    3) eoscfg edge1 "ipv6 prefix-list PL6-CUST seq 5 deny 2001:db8:40::/48" ;;
    4) eoscfg edge2 "router bgp 65010" "address-family ipv6" \
                    "neighbor ${NB6[edge2:t2]} route-map RM-EXT-OUT6 out" ;;
    5) eoscfg edge2 "router bgp 65010" "no neighbor ${NB6[edge2:p2]}" ;;
    6) eoscfg edge1 "no route-map RM-T1-IN6 deny 5" ;;
    7) eoscfg edge1 "no route-map RM-DRAIN-OUT6 permit 10" \
                    "no route-map RM-DRAIN-OUT6 permit 20" \
                    "route-map RM-DRAIN-OUT6 deny 10" ;;
    8) eoscfg edge2 "router bgp 65010" "address-family ipv6" \
                    "no neighbor 2001:db8:ffff:ffff::1 next-hop-self" ;;
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
  rm -f "$STATE" "$DRAINED"; echo "[*] baseline restored. Allow ~45s, then verify."
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
  echo -e "${Y}[i] allow ~45s for both address families, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)  deploy ;;
  destroy) $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" "$DRAINED" ;;
  verify)  verify ;;
  afi)     afi ;;
  exits)   exits ;;
  parity)  parity ;;
  drain)   drain "${2:-}" ;;
  undrain) undrain ;;
  break)   do_break "${2:-}" ;;
  reveal)  [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active"
           [[ -f $DRAINED ]] && echo "drained: $(cat "$DRAINED")" ;;
  restore) restore ;;
  hint)    hint "${2:-}" ;;
  cli)     docker exec -it "$P-${2:?node}" Cli ;;
  status)  $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,20p' "$0" ;;
esac
