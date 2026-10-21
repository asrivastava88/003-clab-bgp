#!/bin/bash
# Idempotent bootstrap for isp1 (runs inside the SONiC-VS container via lab.sh)
# Lab 01. Path: bgp-lab01/isp/isp-setup.sh
#
# containerlab maps topology ethN -> SONiC Ethernet((N-1)*4):
#   eth1 -> Ethernet0   eth2 -> Ethernet4
# L3 addressing MUST go on the SONiC Ethernet* names. Putting an IP on the raw
# ethN veth leaves the Linux kernel answering for it: pings succeed, but the
# reply has SRC MAC == DST MAC and never traverses the forwarding path.
set -u
ASN=65000

# The SONiC-VS image ships with bgpd disabled. Enable it before anything queries BGP state.
if grep -q '^bgpd=no' /etc/frr/daemons; then
  sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
  supervisorctl restart bgpd >/dev/null 2>&1 || supervisorctl start bgpd >/dev/null 2>&1
fi
for _ in $(seq 1 30); do
  vtysh -c 'show bgp ipv4 unicast summary' >/dev/null 2>&1 && break
  sleep 2
done
if ! vtysh -c 'show bgp ipv4 unicast summary' >/dev/null 2>&1; then
  echo "ERROR: bgpd did not come up. Check: supervisorctl status; grep bgpd /etc/frr/daemons" >&2
fi

# SONiC templates may pre-create "router bgp <default-asn>". Remove it if it is not ours.
CUR=$(vtysh -c 'show running-config' 2>/dev/null | awk '/^router bgp /{print $3; exit}')
if [ -n "${CUR}" ] && [ "${CUR}" != "${ASN}" ]; then
  vtysh -c 'configure terminal' -c "no router bgp ${CUR}"
fi
sonic-db-cli CONFIG_DB HSET 'DEVICE_METADATA|localhost' bgp_asn ${ASN} >/dev/null 2>&1 || true

for p in Ethernet0 Ethernet4; do config interface startup "$p" >/dev/null 2>&1 || true; done
config interface ip add Ethernet0 172.16.1.2/30 >/dev/null 2>&1 || true
config interface ip add Ethernet4 172.16.2.2/30 >/dev/null 2>&1 || true

# Fail loudly if the addresses did not land. "config interface ip add" is silent on error,
# which otherwise yields a box with BGP configured and no IP to peer from.
rc=0
for want in "Ethernet0 172.16.1.2/30" "Ethernet4 172.16.2.2/30"; do
  set -- $want
  if ! show ip interfaces 2>/dev/null | grep -q "^$1[[:space:]].*${2%/*}"; then
    echo "ERROR: $2 is not on $1 (clab ethN -> Ethernet((N-1)*4): eth1=Ethernet0, eth2=Ethernet4)" >&2
    rc=1
  fi
done
[ $rc -eq 0 ] || echo "ERROR: fix interface addressing before trusting BGP state on this node" >&2

# "Internet" test target, answered by the kernel
ip addr replace 203.0.113.10/32 dev lo
sysctl -qw net.ipv4.ip_forward=1

vtysh -f /isp/frr-isp.conf
vtysh -c 'clear ip bgp * soft' >/dev/null 2>&1 || true
echo "isp1 bootstrap done"