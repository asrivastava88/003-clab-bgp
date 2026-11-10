#!/usr/bin/env bash
# bgp-lab19 control script  (multi-tenant EVPN across three regions, 38 nodes)
#
#   ./lab.sh deploy                deploy (allow 8-12 minutes)
#   ./lab.sh destroy               tear down
#   ./lab.sh verify                state checks only; observed vs expected
#   ./lab.sh isolation             prove PROD cannot reach DEV, from every VTEP
#   ./lab.sh vrf [NAME]            per-VRF route counts and reachability
#   ./lab.sh vtep                  who sees whose VTEP, per region
#   ./lab.sh wan                   per-VRF inter-region sessions and leaks
#   ./lab.sh rt <device>           the route-target plan as that device has it
#   ./lab.sh break                 inject ALL faults at once
#   ./lab.sh break <n>             inject one, for isolated practice
#   ./lab.sh reveal | restore
#   ./lab.sh hint [n]              spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab19; TOPO=bgp-lab19.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
source "$DIR/tools/peers.sh"          # PEER, VHOST, LOOP1 -- generated
REGIONS=(wst est eur); VRFS=(PROD DEV SHARED); CARRIERS=(wan1 wan2)
SS=(); SPINES=(); LEAVES=(); BORDERS=()
for r in "${REGIONS[@]}"; do
  SS+=("$r-ss1" "$r-ss2"); BORDERS+=("$r-b1" "$r-b2")
  for p in 1 2; do SPINES+=("$r-p$p-s1" "$r-p$p-s2"); LEAVES+=("$r-p$p-l1" "$r-p$p-l2"); done
done
VTEPS=("${LEAVES[@]}" "${BORDERS[@]}")
NODES=("${SS[@]}" "${SPINES[@]}" "${LEAVES[@]}" "${BORDERS[@]}" "${CARRIERS[@]}")
NFAULTS=12
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }
declare -A VNI=( [PROD]=50001 [DEV]=50002 [SHARED]=50003 )
declare -A OVASN=( [wst]=65001 [est]=65002 [eur]=65003 )
region_of() { echo "${1%%-*}"; }
vrfping() { # device vrf dst  -- ping from that device's tenant loopback
  eos "$1" "ping vrf $2 $3 source ${VHOST[$1:$2]} repeat 2 timeout 2" \
    | grep -qE '[1-9][0-9]* received'
}
vrfroutes() { eos "$1" "show ip route vrf $2" | grep -cE '^ *B '; }
estab()  { eos "$1" "show ip bgp summary" | grep -c Estab; }
evpnn()  { eos "$1" "show bgp evpn summary" | grep -c Estab; }
ospfnb() { eos "$1" "show ip ospf neighbor" | grep -c FULL; }
vteps()  { eos "$1" "show vxlan vtep" | grep -cE '^ *10\.1\.'; }
check_num() { [[ "${2:-x}" == "$3" ]] && ok "$1: ${2:-0}, expected $3" || nok "$1: ${2:-0}, expected $3"; }

# ---------------------------------------------------------------- verify
verify() {
  echo -e "${B}== Underlay ==${N}"
  for n in "${SS[@]}";     do check_num "$n OSPF adjacencies" "$(ospfnb $n)" 6; done
  for n in "${SPINES[@]}"; do check_num "$n OSPF adjacencies" "$(ospfnb $n)" 4; done
  for n in "${LEAVES[@]}" "${BORDERS[@]}"; do check_num "$n OSPF adjacencies" "$(ospfnb $n)" 2; done

  echo -e "${B}== Overlay: every VTEP peers with both reflectors ==${N}"
  for n in "${VTEPS[@]}"; do check_num "$n EVPN sessions" "$(evpnn $n)" 2; done
  for n in "${SS[@]}";    do check_num "$n EVPN sessions" "$(evpnn $n)" 6; done

  echo -e "${B}== Every VTEP learns every other VTEP in its region ==${N}"
  for n in "${VTEPS[@]}"; do check_num "$n remote VTEPs" "$(vteps $n)" 5; done

  echo -e "${B}== THE INVARIANT: PROD must not reach DEV, anywhere ==${N}"
  for n in "${VTEPS[@]}"; do
    r=$(region_of $n); peer=""
    for o in "${VTEPS[@]}"; do [[ $(region_of $o) == "$r" && $o != "$n" ]] && { peer=$o; break; }; done
    if vrfping "$n" PROD "${VHOST[$peer:DEV]}"; then
      nok "$n PROD must NOT reach $peer DEV"; else ok "$n PROD cannot reach $peer DEV"; fi
  done

  echo -e "${B}== Both tenants reach SHARED, in every region ==${N}"
  for n in "${VTEPS[@]}"; do
    r=$(region_of $n); peer=""
    for o in "${VTEPS[@]}"; do [[ $(region_of $o) == "$r" && $o != "$n" ]] && { peer=$o; break; }; done
    for v in PROD DEV; do
      if vrfping "$n" "$v" "${VHOST[$peer:SHARED]}"; then
        ok "$n $v reaches $peer SHARED"; else nok "$n $v reaches $peer SHARED"; fi
    done
  done

  echo -e "${B}== Each tenant crosses the WAN to the other regions ==${N}"
  for r in "${REGIONS[@]}"; do
    for o in "${REGIONS[@]}"; do
      [[ $o == "$r" ]] && continue
      for v in "${VRFS[@]}"; do
        if vrfping "$r-p1-l1" "$v" "${VHOST[$o-p1-l1:$v]}"; then
          ok "$r $v reaches $o"; else nok "$r $v reaches $o"; fi
      done
    done
  done

  echo -e "${B}== Per-VRF WAN sessions ==${N}"
  for n in "${BORDERS[@]}"; do check_num "$n BGP Established" "$(estab $n)" 8; done
  for w in "${CARRIERS[@]}"; do check_num "$w BGP Established" "$(estab $w)" 18; done

  echo -e "${B}== No region transits for another, in any VRF ==${N}"
  for w in "${CARRIERS[@]}"; do
    for v in "${VRFS[@]}"; do
      t=$(eos "$w" "show ip bgp vrf $v" | grep -cE '(65001|65002|65003) +(65500|65600)')
      check_num "$w sees no region transiting in $v" "${t:-0}" 0
    done
  done

  echo -e "${B}== Every border offers all three tenants to the overlay ==${N}"
  for n in "${BORDERS[@]}"; do
    c=$(eos "$n" "show running-config" | grep -c 'route-target export evpn')
    check_num "$n tenant VRFs offered to the overlay" "${c:-0}" 3
  done

  echo -e "${B}== The underlay stays out of the tenants ==${N}"
  for n in "${BORDERS[@]}" wst-p1-l1; do
    for v in "${VRFS[@]}"; do
      c=$(eos "$n" "show ip route vrf $v" | grep -cE '10\.25[34]\.')
      check_num "$n $v holds no underlay or WAN /31" "${c:-0}" 0
    done
  done

  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") fault(s) active (./lab.sh reveal | restore)${N}"
  return 0
}

# ---------------------------------------------------------------- tools
isolation() {
  echo -e "${B}The invariant: PROD must never reach DEV${N}"
  echo -e "${C}The route-target plan is hub and spoke. PROD and DEV each import${N}"
  echo -e "${C}SHARED; neither imports the other. One extra import anywhere in the${N}"
  echo -e "${C}fabric breaks it, for that device only, which is what makes it hard.${N}\n"
  printf "  %-12s %-14s %-14s %-14s\n" "from (PROD)" "-> DEV" "-> SHARED" "verdict"
  printf "  %s\n" "------------------------------------------------------------"
  for n in "${VTEPS[@]}"; do
    r=$(region_of $n); peer=""
    for o in "${VTEPS[@]}"; do [[ $(region_of $o) == "$r" && $o != "$n" ]] && { peer=$o; break; }; done
    d="no"; sh="no"
    vrfping "$n" PROD "${VHOST[$peer:DEV]}"    && d="YES"
    vrfping "$n" PROD "${VHOST[$peer:SHARED]}" && sh="yes"
    if [[ $d == YES ]]; then v="${R}ISOLATION BREACH${N}"
    elif [[ $sh == no ]]; then v="${Y}shared unreachable${N}"
    else v="${G}correct${N}"; fi
    printf "  %-12s %-14s %-14s %b\n" "$n" "$d" "$sh" "$v"
  done
  echo
  echo -e "${Y}[i] A breach on one VTEP is a breach. The other VTEPs being correct${N}"
  echo -e "${Y}    is not mitigation, it is the reason nobody noticed.${N}"
}

vrfcmd() {
  local only=${1:-}
  echo -e "${B}Per-VRF routes and reach${N}\n"
  printf "  %-12s" "device"
  for v in "${VRFS[@]}"; do [[ -n $only && $v != "$only" ]] && continue; printf " %18s" "$v"; done
  echo; printf "  %s\n" "----------------------------------------------------------------"
  for n in "${VTEPS[@]}"; do
    printf "  %-12s" "$n"
    for v in "${VRFS[@]}"; do
      [[ -n $only && $v != "$only" ]] && continue
      c=$(vrfroutes "$n" "$v")
      if [[ ${c:-0} -ge 10 ]]; then printf "${G}%18s${N}" "$c routes"
      elif [[ ${c:-0} -gt 0 ]]; then printf "${Y}%18s${N}" "$c routes"
      else printf "${R}%18s${N}" "0 routes"; fi
    done; echo
  done
  echo
  echo -e "${Y}[i] Every VTEP should hold a similar count in every VRF: the tenant${N}"
  echo -e "${Y}    space is symmetric by design. A device low in one VRF only has an${N}"
  echo -e "${Y}    import problem; low in all of them has an overlay problem.${N}"
}

vtep() {
  echo -e "${B}VTEP visibility, per region. Each should see the other five.${N}\n"
  printf "  %-12s %-10s %-8s  %s\n" "device" "its VTEP" "sees" "missing"
  printf "  %s\n" "----------------------------------------------------------------"
  for n in "${VTEPS[@]}"; do
    r=$(region_of $n)
    seen=$(eos "$n" "show vxlan vtep" | grep -oE '10\.1\.[0-9]+\.[0-9]+' | sort -u)
    c=$(echo "$seen" | grep -c '10\.1\.')
    miss=""
    for o in "${VTEPS[@]}"; do
      [[ $(region_of $o) == "$r" && $o != "$n" ]] || continue
      echo "$seen" | grep -q "^${LOOP1[$o]}$" || miss="$miss $o"
    done
    col=$G; [[ ${c:-0} -ne 5 ]] && col=$R
    printf "  %-12s %-10s ${col}%-8s${N}  %s\n" "$n" "${LOOP1[$n]}" "${c:-0}" "${miss:-none}"
  done
  echo
  echo -e "${Y}[i] A VTEP nobody sees is usually an underlay problem wearing an${N}"
  echo -e "${Y}    overlay costume: its loopback is not reachable, so the tunnel${N}"
  echo -e "${Y}    never forms even though EVPN looks perfect.${N}"
}

wancmd() {
  echo -e "${B}Per-VRF inter-region handoff${N}\n"
  printf "  %-10s %-8s %-8s %10s  %s\n" "border" "carrier" "vrf" "sessions" "advertises"
  printf "  %s\n" "----------------------------------------------------------------------"
  for n in "${BORDERS[@]}"; do
    for v in "${VRFS[@]}"; do
      up=$(eos "$n" "show ip bgp summary vrf $v" | grep -c Estab)
      adv=$(eos "$n" "show ip bgp vrf $v" | grep -cE '10\.10[123]\.')
      col=$G; [[ ${up:-0} -ne 2 ]] && col=$R
      printf "  %-10s %-8s %-8s ${col}%10s${N}  %s prefixes\n" "$n" "both" "$v" "${up:-0}" "${adv:-0}"
    done
  done
  echo
  echo -e "${B}Does any region appear as transit, per VRF?${N}"
  printf "  %-6s %-8s %10s\n" "at" "vrf" "transit"
  printf "  %s\n" "--------------------------"
  for w in "${CARRIERS[@]}"; do
    for v in "${VRFS[@]}"; do
      t=$(eos "$w" "show ip bgp vrf $v" | grep -cE '(65001|65002|65003) +(65500|65600)')
      col=$G; [[ ${t:-0} -gt 0 ]] && col=$R
      printf "  %-6s %-8s ${col}%10s${N}\n" "$w" "$v" "${t:-0}"
    done
  done
  echo
  echo -e "${Y}[i] A region ASN followed by a carrier ASN inside a VRF means that${N}"
  echo -e "${Y}    region is carrying another region's tenant traffic. It can happen${N}"
  echo -e "${Y}    in one VRF and not the others, which is the part people miss.${N}"
}

rtshow() {
  local d=${1:?usage: ./lab.sh rt <device>}
  echo -e "${B}Route-target plan as $d has it${N}\n"
  eos "$d" "show running-config section bgp" | sed -n '/vrf /,$p' | grep -E 'vrf |rd |route-target'
  echo
  echo -e "${Y}[i] The design: PROD and DEV each import their own plus SHARED.${N}"
  echo -e "${Y}    SHARED imports all three. Four imports in PROD is a breach.${N}"
}

# ---------------------------------------------------------------- faults
fault() {
  case $1 in
    1)  eoscfg wst-p1-l2 "router bgp 65001" "vrf PROD" "route-target import evpn 1:50002" \
                         "route-target export evpn 1:50002" ;;
    2)  eoscfg est-p2-l1 "router bgp 65002" "vrf DEV" "no route-target import evpn 1:50003" ;;
    3)  eoscfg eur-p1-l2 "router ospf 1" "no network 10.1.3.2/32 area 0.0.0.0" ;;
    4)  eoscfg wst-p2-l1 "interface Vxlan1" "no vxlan vrf SHARED vni 50003" ;;
    5)  eoscfg est-b1 "router bgp 65002" "vrf PROD" "no neighbor 10.253.0.25 route-map RM-WAN-OUT out" ;;
    6)  eoscfg eur-b2 "router bgp 65003" "vrf DEV" "no neighbor 10.253.0.69 remote-as 65600" ;;
    7)  eoscfg wst-p1-l1 "interface Loopback1" "ip address 10.1.1.2/32" \
                         "router ospf 1" "no network 10.1.1.1/32 area 0.0.0.0" \
                         "network 10.1.1.2/32 area 0.0.0.0" ;;  # duplicate of wst-p1-l2's VTEP
    8)  eoscfg est-ss2 "router bgp 65002" "no neighbor 10.0.2.32 peer group OVERLAY" ;;
    9)  eoscfg eur-b1 "router bgp 65003" "vrf PROD" "no redistribute connected route-map RM-TENANT" \
                      "redistribute connected" ;;
    10) eoscfg wst-b2 "router bgp 65001" "vrf SHARED" "no route-target export evpn 1:50003" ;;
    11) eoscfg est-p1-s2 "router ospf 1" "no network 10.254.0.56/31 area 0.0.0.0" ;;
    12) eoscfg eur-ss1 "router bgp 65003" "address-family evpn" "no neighbor OVERLAY activate" ;;
    *) echo "faults: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS faults"; : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~90s, then ./lab.sh verify"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"; echo "[*] fault $1 injected"
  fi
}
restore() {
  echo "[*] restoring 38 devices"
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
  echo "[*] 38 cEOS nodes with EVPN. Expect 8-12 minutes and roughly 55 GB."
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  printf "[*] waiting for cEOS"
  for n in "${NODES[@]}"; do
    for _ in $(seq 1 90); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
  echo -e "${Y}[i] allow ~90s for OSPF, EVPN and the WAN, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)    deploy ;;
  destroy)   $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" ;;
  verify)    verify ;;
  isolation) isolation ;;
  vrf)       vrfcmd "${2:-}" ;;
  vtep)      vtep ;;
  wan)       wancmd ;;
  rt)        rtshow "${2:-}" ;;
  break)     do_break "${2:-}" ;;
  reveal)    [[ -f $STATE ]] && echo "active faults: $(cat "$STATE")" || echo "no faults active" ;;
  restore)   restore ;;
  hint)      hint "${2:-}" ;;
  cli)       docker exec -it "$P-${2:?node}" Cli ;;
  status)    $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,20p' "$0" ;;
esac
