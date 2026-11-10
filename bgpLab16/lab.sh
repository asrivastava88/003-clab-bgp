#!/usr/bin/env bash
# bgp-lab16 control script  (the model is the network: generation, drift, triage)
#
#   ./lab.sh deploy                deploy from the rendered model
#   ./lab.sh destroy               tear down
#   ./lab.sh verify                state checks only; observed vs expected
#   ./lab.sh plan                  the whole computed plan
#   ./lab.sh addresses | links     parts of it
#   ./lab.sh render                model -> configs + topology (writes files)
#   ./lab.sh show <device>         the config the model says that device should have
#   ./lab.sh audit                 running network vs model. Classifies drift.
#   ./lab.sh remediate <device>    push the model's config at one device
#   ./lab.sh break                 inject ALL drifts at once
#   ./lab.sh break <n>             inject one, for isolated practice
#   ./lab.sh reveal | restore      restore puts BOTH the devices and the model back
#   ./lab.sh hint [n]              spoilers
#   ./lab.sh cli <node>
#   ./lab.sh status
set -uo pipefail
LAB=bgp-lab16; TOPO=bgp-lab16.clab.yml; P="clab-${LAB}"
DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
OURS=(wst-r1 wst-r2 est-r1 est-r2 eur-r1 eur-r2)
NODES=("${OURS[@]}" transit1 peer1)
NFAULTS=8
STATE="$DIR/.active_faults"; CLAB="sudo containerlab"
G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
pass=0; fail=0
ok()  { printf "  ${G}PASS${N} %s\n" "$1"; pass=$((pass+1)); }
nok() { printf "  ${R}FAIL${N} %s\n" "$1"; fail=$((fail+1)); }
eos()    { local n=$1; shift; docker exec "$P-$n" Cli -p 15 -c "$*" 2>/dev/null; }
eoscfg() { local n=$1; shift; local c; c=$(printf '%s\n' configure "$@" end); docker exec "$P-$n" Cli -p 15 -c "$c" >/dev/null; }

nh()     { eos "$1" "show ip route $2" | grep -oE 'via 10\.[0-9]+\.[0-9]+\.[0-9]+' | sed 's/via //' | head -1; }
estab()  { eos "$1" "show ip bgp summary" | grep -c Estab; }
ospfnb() { eos "$1" "show ip ospf neighbor" | grep -c FULL; }
check_eq()  { [[ "$2" == "$3" ]] && ok "$1: $2, expected $3" || nok "$1: ${2:-<empty>}, expected $3"; }
check_num() { [[ "${2:-x}" == "$3" ]] && ok "$1: ${2:-0}, expected $3" || nok "$1: ${2:-0}, expected $3"; }

# ---------------------------------------------------------------- verify
verify() {
  echo -e "${B}== Sessions ==${N}"
  for spec in "wst-r1 4" "est-r1 3" "eur-r1 4" "wst-r2 1" "est-r2 2" "eur-r2 1" \
              "transit1 2" "peer1 1"; do
    set -- $spec; check_num "$1 BGP Established" "$(estab $1)" "$2"
  done
  for n in "${OURS[@]}"; do check_num "$n OSPF full adjacencies" "$(ospfnb $n)" 3; done

  echo -e "${B}== Every inter-region path is the direct link ==${N}"
  check_eq "wst-r1 next hop to eur-r1" "$(nh wst-r1 10.3.0.1)" 10.254.3.1
  check_eq "eur-r1 next hop to wst-r1" "$(nh eur-r1 10.1.0.1)" 10.254.3.0
  check_eq "est-r1 next hop to eur-r1" "$(nh est-r1 10.3.0.1)" 10.254.2.1
  check_eq "wst-r2 next hop to eur-r2" "$(nh wst-r2 10.3.0.2)" 10.254.6.0
  check_eq "est-r2 next hop to wst-r2" "$(nh est-r2 10.1.0.2)" 10.254.4.0

  echo -e "${B}== Every region's prefix is in every router's table ==${N}"
  for n in "${OURS[@]}"; do
    c=0
    for p in 198.18.1.0/24 198.18.2.0/24 198.18.3.0/24; do
      eos "$n" "show ip route $p" | grep -qE 'via 10\.|directly connected|Null0' && c=$((c+1))
    done
    check_num "$n holds all three region prefixes" "$c" 3
  done

  echo -e "${B}== The peer beats the transit, from everywhere ==${N}"
  check_eq "est-r2 next hop for the peer's space" "$(nh est-r2 100.110.0.0/16)" 10.254.12.1
  check_eq "wst-r1 next hop for the peer's space" "$(nh wst-r1 100.110.0.0/16)" 10.254.1.1
  check_eq "eur-r1 next hop for the peer's space" "$(nh eur-r1 100.110.0.0/16)" 10.254.2.0
  check_eq "wst-r2 next hop for the peer's space" "$(nh wst-r2 100.110.0.0/16)" 10.254.7.0
  check_num "wst-r1 paths to the transit-only prefix" \
    "$(eos wst-r1 'show ip bgp 100.200.0.0/16' | grep -oE 'Paths: [0-9]+' | grep -oE '[0-9]+' | head -1)" 2

  echo -e "${B}== Reachability ==${N}"
  for spec in "wst-r1 100.110.0.1" "eur-r2 100.110.0.1" "est-r2 100.100.0.1" \
              "wst-r2 100.200.0.1" "peer1 198.18.3.0" "transit1 198.18.2.0"; do
    set -- $spec
    if eos "$1" "ping $2 repeat 3 timeout 2" | grep -qE '[1-9][0-9]* received'; then
      ok "$1 to $2"; else nok "$1 to $2"; fi
  done

  echo -e "== Result: ${G}${pass} pass${N}, ${R}${fail} fail${N}"
  [[ -f $STATE ]] && echo -e "${Y}[i] $(wc -w < "$STATE") drift(s) injected (./lab.sh reveal | restore)${N}"
  return 0
}

# ---------------------------------------------------------------- model tools
audit() {
  local tmp; tmp=$(mktemp -d)
  for n in "${OURS[@]}"; do eos "$n" "show running-config" > "$tmp/$n.cfg"; done
  python3 "$DIR/tools/audit.py" "$tmp"/*.cfg
  local rc=$?; rm -rf "$tmp"; return $rc
}

remediate() {
  local d=${1:?usage: ./lab.sh remediate <device>}
  [[ -f "configs/solution/$d.cfg" ]] || { echo "no rendered config for $d"; exit 1; }
  echo -e "${Y}About to replace the running configuration of $d with what the model"
  echo -e "says it should be. If the model is the thing that is wrong, this pushes"
  echo -e "the error into the network. Triage first.${N}"
  read -r -p "Type the device name to continue: " c
  [[ "$c" == "$d" ]] || { echo "aborted"; exit 1; }
  docker cp "configs/solution/$d.cfg" "$P-$d:/mnt/flash/model.cfg" >/dev/null
  docker exec "$P-$d" Cli -p 15 -c "configure replace flash:model.cfg" >/dev/null \
    && echo "[*] $d now matches the model. Allow ~45s, then ./lab.sh audit"
}

render() {
  python3 "$DIR/tools/render.py"
  echo -e "${Y}[i] configs/solution and the topology have been rewritten from the model."
  echo -e "    Nothing has been pushed to any device. ./lab.sh audit compares them,"
  echo -e "    ./lab.sh remediate <device> pushes one.${N}"
}

# ---------------------------------------------------------------- drifts
fault() {
  case $1 in
    1) eoscfg wst-r2 "interface Loopback0" "ip address 10.1.0.22/32"
       eoscfg wst-r2 "router ospf 1" "no network 10.1.0.2/32 area 0.0.0.0" \
                     "network 10.1.0.22/32 area 0.0.0.0" ;;
    2) eoscfg est-r1 "interface Ethernet2" "ip ospf cost 200" ;;
    3) eoscfg wst-r1 "router bgp 65010" "address-family ipv4" \
                     "no neighbor 10.1.0.2 route-reflector-client" ;;
    4) eoscfg est-r2 "router bgp 65010" "neighbor 10.99.9.9 remote-as 64999" \
                     "neighbor 10.99.9.9 description temp_do_not_remove" \
                     "neighbor 10.99.9.9 shutdown" ;;
    5) eoscfg eur-r2 "interface Ethernet1" "ip address 10.254.55.1/31"
       eoscfg eur-r2 "router ospf 1" "no network 10.254.5.0/31 area 0.0.0.0" \
                     "network 10.254.55.0/31 area 0.0.0.0" ;;
    6) eoscfg est-r2 "route-map RM-PEER-IN permit 10" "set local-preference 150" ;;
    7) python3 - <<'PY'
import re
f='model/network.yml'; s=open(f).read()
s=s.replace("{a: eur-r1, b: wst-r1, rtt: 130}", "{a: eur-r1, b: wst-r1, rtt: 142}")
open(f,'w').write(s)
PY
       ;;
    8) python3 - <<'PY'
f='model/network.yml'; s=open(f).read()
s=s.replace("  - {device: est-r2, peer: peer1,    asn: 65300, kind: peer}",
            "  - {device: est-r2, peer: peer1,    asn: 65300, kind: peer}\n"
            "  - {device: wst-r2, peer: peer1,    asn: 65300, kind: peer}")
open(f,'w').write(s)
PY
       ;;
    *) echo "drifts: 1-$NFAULTS"; exit 1 ;;
  esac
}
do_break() {
  if [[ -z ${1:-} ]]; then
    echo "[*] injecting all $NFAULTS drifts"; : > "$STATE"
    for i in $(seq 1 $NFAULTS); do fault "$i" && printf '%s ' "$i" >> "$STATE"; done
    echo; echo "[*] done. Allow ~45s, then ./lab.sh verify and ./lab.sh audit"
  else
    fault "$1" && printf '%s ' "$1" >> "$STATE"; echo "[*] drift $1 injected"
  fi
}
restore() {
  echo "[*] restoring the model"
  cp -f model/.baseline/network.yml model/.baseline/policy.yml model/
  python3 tools/render.py >/dev/null
  echo "[*] restoring the devices"
  for n in "${NODES[@]}"; do
    docker cp "configs/solution/$n.cfg" "$P-$n:/mnt/flash/golden.cfg" >/dev/null
    docker exec "$P-$n" Cli -p 15 -c "configure replace flash:golden.cfg" >/dev/null && echo "  $n restored"
  done
  rm -f "$STATE"; echo "[*] baseline restored. Allow ~45s, then verify."
}
hint() {
  echo -e "${Y}These are spoilers. Close the window if you did not mean to run this.${N}"; echo
  if [[ -n ${1:-} ]]; then sed -n "/^### drift $1\$/,/^### /p" docs/HINTS.md | head -n -1
  else cat docs/HINTS.md; fi
}
deploy() {
  python3 tools/render.py >/dev/null
  cp -f configs/solution/*.cfg configs/active/
  $CLAB deploy -t "$TOPO" --reconfigure || exit 1
  printf "[*] waiting for cEOS nodes"
  for n in "${NODES[@]}"; do
    for _ in $(seq 1 60); do docker exec "$P-$n" Cli -c "show version" >/dev/null 2>&1 && break; printf "."; sleep 5; done
  done; echo " ok"
  echo -e "${Y}[i] allow ~45s for OSPF and BGP, then ./lab.sh verify${N}"
}

case ${1:-} in
  deploy)   deploy ;;
  destroy)  $CLAB destroy -t "$TOPO" --cleanup; rm -f "$STATE" ;;
  verify)   verify ;;
  plan)     python3 tools/model.py plan ;;
  addresses) python3 tools/model.py addresses ;;
  links)    python3 tools/model.py links ;;
  render)   render ;;
  show)     python3 tools/render.py --stdout "${2:?device}" ;;
  audit)    audit ;;
  remediate) remediate "${2:-}" ;;
  break)    do_break "${2:-}" ;;
  reveal)   [[ -f $STATE ]] && echo "active drifts: $(cat "$STATE")" || echo "no drifts active" ;;
  restore)  restore ;;
  hint)     hint "${2:-}" ;;
  cli)      docker exec -it "$P-${2:?node}" Cli ;;
  status)   $CLAB inspect -t "$TOPO" ;;
  *) sed -n '2,22p' "$0" ;;
esac
