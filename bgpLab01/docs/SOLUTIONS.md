# Lab 01 Solutions (spoilers)

## Part A answers

**Q1 Shared spine ASN, unique leaf ASNs.** With one spine ASN, a path like spine1 > leafX > spine2 is rejected by AS_PATH loop prevention, so there is no valley routing and no path hunting when a leaf withdraws a prefix. Unique spine ASNs let spine2 re-learn a withdrawn route through another leaf and spine1, which causes slow convergence and transient detours unless you filter. Unique leaf ASNs let leaf routes reach other leaves without `allowas-in`; a shared leaf ASN would force `allowas-in` and weaken loop protection.

**Q2 `next-hop-unchanged`.** The EVPN next hop must stay the originating VTEP, because that is where the VXLAN tunnel terminates. Spines are not VTEPs. Underlay next-hop rewrite is normal hop-by-hop forwarding.

**Q3 Type-2 extended communities.** L2 RT (MAC-VRF import), L3 RT (IP-VRF import of the /32), Router-MAC (inner destination MAC for symmetric IRB), encapsulation type VXLAN. It also carries two labels: L2VNI and L3VNI.

**Q4 h2 to h3 without VLAN 20 on leaf2.** leaf2 imports h3's MAC-IP route into VRF RED via RT 50001:50001 as a /32 (plus leaf3's type-5 for 10.10.20.0/24). It routes into L3VNI 50001 with inner DMAC set to leaf3's router-MAC. Check: `show ip route vrf RED 10.10.20.103` on leaf2.

**Q5 AS_PATH through the fusion.**
leaf1 originates `65101` > spines `65100 65101` > bleaf1 RED to isp1 `65104 65100 65101` > isp1 `remove-private-AS all` strips every private ASN and prepends `65000` > bleaf1 BLUE receives `65000` > EVPN out `65104 65000` > leaf3 sees `65100 65104 65000`. Without the strip, bleaf1 drops it (own ASN). Adding `allowas-in` on bleaf1 alone still fails because the spines (65100) and leaf1 (65101) would drop it next.

## Part B tickets

**T1 leaf3 EVPN sessions lost their source.** `no neighbor EVPN update-source` on leaf3.
Isolate: leaf3 `show bgp evpn summary` (Active/Connect), `show bgp neighbors 10.0.0.1 | include Local`. Spines only accept 179 from 10.0.0.13.
Fix: `router bgp 65103` / `neighbor EVPN update-source Loopback0`.
Lesson: multihop sessions die when the source IP does not match the remote neighbor statement. Underlay stays green, so always check overlay sessions separately.

**T2 L2VNI route-target mismatch on leaf2.** VLAN 10 exports/imports 10010:10011.
Isolate: leaf1 `show bgp evpn route-type imet detail` and `show bgp evpn route-type mac-ip 10.10.10.102 detail` (RT 10010:10011 + 50001:50001), `show vxlan flood vtep vlan 10` (10.0.1.12 missing), `show vxlan address-table`.
Fix: restore `route-target both 10010:10010` under `vlan 10`.
Lesson: L2 and L3 imports are independent. h1 to h3 works because the MAC-IP route still carries the L3 RT; same-subnet traffic fails because ARP never crosses the fabric.

**T3 L3 import RT wrong on leaf3 VRF RED.** Import 50001:50011.
Isolate: leaf3 `show ip route vrf RED` (only local/connected), `show bgp evpn route-type ip-prefix ipv4` (routes present, not imported). Other leaves still import leaf3's exports, so traffic reaches h3 but replies have no route back.
Fix: `route-target import evpn 50001:50001`.
Lesson: asymmetric RT config gives one-way reachability. Ping tells you "broken"; route tables on both ends tell you where.

**T4 leaf1 stopped sending communities.** `no neighbor EVPN send-community`.
Isolate: leaf2 `show bgp evpn route-type mac-ip 10.10.10.101 detail` shows no extended communities. Without RTs nothing imports anywhere.
Fix: `neighbor EVPN send-community`.
Lesson: EOS does not send communities unless configured. RTs are extended communities. "Session up, routes received, nothing works" is the classic signature.

**T5 Anycast gateway MAC removed on leaf3.**
Isolate: `show ip virtual-router`, `show ip interface Vlan20` (virtual address inactive), host `arp -n` shows no gateway entry.
Fix: `ip virtual-router mac-address 00:1c:73:00:00:99`.
Lesson: `ip address virtual` depends on the global virtual MAC. It must be identical on every leaf or host ARP caches break on VM moves.

**T6 VTEP loopback dropped from the underlay on leaf2.** PL-LOOPBACKS seq 20 removed.
Isolate: leaf1 `show ip route 10.0.1.12` (missing), `show bgp evpn route-type mac-ip 10.10.10.102 detail` (next hop 10.0.1.12 unresolved, not best), `show vxlan vtep` (10.0.1.12 absent).
Fix: `ip prefix-list PL-LOOPBACKS seq 20 permit 10.0.1.0/24 eq 32`.
Lesson: EVPN peers on Loopback0, tunnels terminate on Loopback1. Separate loopbacks let the control plane look perfect while the data plane is dead. Alert on VTEP reachability, not just session state.

**T7 Fusion lost `remove-private-AS all`.**
Isolate: isp1 `show bgp ipv4 unicast neighbors 172.16.2.1 advertised-routes` shows RED prefixes with `65000 65104 65100 65101`. bleaf1 `show ip bgp vrf BLUE 10.10.10.0/24` has nothing. Internet still works because the default and 203.0.113.0/24 carry only `65000`.
Fix: re-add `neighbor 172.16.x.1 remove-private-AS all` (or `./lab.sh restore`).
Lesson: see Q5. Production fusion firewalls usually re-originate or summarize, which breaks the AS_PATH for you.

**T8 spine1 rewrites the EVPN next hop.** `no neighbor EVPN next-hop-unchanged`.
Isolate: leaf2 `show bgp evpn route-type mac-ip 10.10.10.101 detail` shows a path with next hop 10.0.0.1 (spine1 Loopback0) winning on lowest router-id. `show vxlan vtep` lists 10.0.0.1 as a VTEP, which is the giveaway.
Fix: `neighbor EVPN next-hop-unchanged` on spine1.
Lesson: eBGP rewrites next hop by default. Any VTEP list entry that is not a leaf Loopback1 is a red flag.

## Part C

### TE-1 Drain spine2

spine2:
```
route-map RM-DRAIN permit 10
   set as-path prepend 65100 65100 65100
!
router bgp 65100
   neighbor UNDERLAY route-map RM-DRAIN out
```
Verify on leaf1 and leaf3: `show ip route 10.0.1.0/24 longer-prefixes` shows one next hop (spine1). `show interfaces counters rates` on spine2 drops to near zero under a ping flood. Undrain: `no neighbor UNDERLAY route-map RM-DRAIN out`.

Why underlay: VXLAN packets follow the underlay route to the remote Loopback1. EVPN next hops never point at a spine, so prepending EVPN changes nothing in the data plane. Prepend instead of shutdown keeps every session up, so rollback is instant and there is no reconvergence storm. EOS also has a maintenance-mode framework that automates the same idea.

### TE-2 Subnets only to the WAN

bleaf1:
```
ip prefix-list PL-RED-SUBNETS seq 10 permit 10.10.0.0/16 le 24
ip prefix-list PL-BLUE-SUBNETS seq 10 permit 10.30.0.0/16 le 24
!
route-map RM-RED-TO-WAN permit 10
   match ip address prefix-list PL-RED-SUBNETS
route-map RM-BLUE-TO-WAN permit 10
   match ip address prefix-list PL-BLUE-SUBNETS
!
router bgp 65104
   vrf RED
      neighbor 172.16.1.2 route-map RM-RED-TO-WAN out
   vrf BLUE
      neighbor 172.16.2.2 route-map RM-BLUE-TO-WAN out
```
Verify: isp1 `show bgp ipv4 unicast neighbors 172.16.1.1 routes` shows only the /24s. Side benefit: the border no longer echoes the other tenant's prefixes or its own /30 back to the WAN.

Pick the route-map. `aggregate-address 10.10.0.0/16 summary-only` inside the VRF also exports the /16 into EVPN as a type-5, so every leaf gets a covering route to bleaf1. A withdrawn /24 then silently falls to the /16 and blackholes at the border's Null0 instead of failing fast. You also lose /24 granularity, which TE-3 needs.

### TE-3 Tenant segmentation (the trap)

Filtering 10.10.20.0/24 out of `RM-TO-BLUE` on isp1 does not work. Both VRFs carry a default route to isp1. h3 to h4: RED has a route (or the default) to isp1, isp1 has h4 via BLUE. Reply: BLUE has no 10.10.20.0/24 but follows its default to isp1, which routes it into RED. Reachability survives.

Routing is not a security control while a default exists. Enforce it in the data plane at the fusion point:

```bash
# lab only: SONiC-VS forwards in the kernel
docker exec clab-bgp-lab01-isp1 iptables -I FORWARD -s 10.10.20.0/24 -d 10.30.0.0/16 -j DROP
docker exec clab-bgp-lab01-isp1 iptables -I FORWARD -s 10.30.0.0/16 -d 10.10.20.0/24 -j DROP
```
Verify: h3 to h4/h5 fails, h1 to h4 works, h3 to 203.0.113.10 works. Production SONiC: an L3 ACL_TABLE bound to Ethernet0/Ethernet4. Real data centers: the fusion is a stateful firewall pair. Keep the route filter as defense in depth, not as the control.

### TE-4 Per-VRF spine pinning

Not possible here. The underlay is VRF-agnostic: every VXLAN packet is outer IP Loopback1 to Loopback1 with a UDP source port hashed from the inner flow. The VNI that identifies the tenant is invisible to underlay ECMP.

Options, best first:
1. Push back. ECMP across all spines is the point of a Clos. Pinning halves capacity per tenant and creates hot spots. If the real need is failure isolation, use separate fabrics or planes.
2. Traffic-engineered underlay: EVPN over SR-MPLS or SRv6 with color/flex-algo steering per VRF.
3. Per-VRF VTEP source addresses with underlay policy per VTEP prefix, only where the platform supports multiple VTEP IPs. Validate on the target platform before proposing.

### TE-5 Remove the border single point of failure

- Two border leaves (bleaf1/bleaf2), same ASN 65104, each a VTEP advertising the same type-5s. Leaves get ECMP for the default and WAN prefixes.
- Each border connects to two WAN/fusion devices. Use 802.1Q subinterfaces per VRF instead of a physical link per VRF.
- BFD on every WAN eBGP session; max-prefix on all VRF peers.
- WAN side: `maximum-paths` toward both borders; ingress and egress policy per VRF.
- If the fusion is a stateful firewall, guarantee symmetry (active/standby cluster with state sync, or pin inter-tenant flows to one path with local-pref/MED). Asymmetric flows through two independent firewalls get dropped.
