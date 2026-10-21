#!/bin/bash
# Idempotent bootstrap for inet (runs inside SONiC-VS via lab.sh)
set -u
ASN=65000
CUR=$(vtysh -c 'show running-config' 2>/dev/null | awk '/^router bgp /{print $3; exit}')
if [ -n "${CUR}" ] && [ "${CUR}" != "${ASN}" ]; then
  vtysh -c 'configure terminal' -c "no router bgp ${CUR}"
fi
sonic-db-cli CONFIG_DB HSET 'DEVICE_METADATA|localhost' bgp_asn ${ASN} >/dev/null 2>&1 || true
for p in Ethernet0 Ethernet4; do config interface startup "$p" >/dev/null 2>&1 || true; done
config interface ip add Ethernet0 100.64.1.2/30 >/dev/null 2>&1 || true
config interface ip add Ethernet4 100.64.2.2/30 >/dev/null 2>&1 || true
ip addr replace 203.0.113.10/32 dev lo
sysctl -qw net.ipv4.ip_forward=1
vtysh -f /inet/frr-inet.conf
echo "inet bootstrap done"
