# Lab 03 Solutions (spoilers)

Reference config: `configs/solution/`.

## Part A

### EVPN multihoming, leaf1 and leaf2 (identical on both)

```
interface Port-Channel1
   description HOST_hm1_ESI_LAG
   switchport access vlan 10
   !
   evpn ethernet-segment
      identifier 0011:1111:1111:1111:1111
      route-target import 00:11:11:11:11:11
   !
   lacp system-id 0011.1111.1111
```

Three things have to match across the pair and nothing else does: the ESI, the ES-import RT, and the LACP system-id. The leaves keep separate ASNs, separate VTEPs, separate everything else. That is the whole design.

### MLAG, leaf3 and leaf4

```
vlan 4094
   name MLAG_PEER
   trunk group MLAGPEER
!
no spanning-tree vlan-id 4094
!
interface Port-Channel1000
   switchport mode trunk
   switchport trunk group MLAGPEER
!
interface Vlan4094
   no autostate
   ip address 10.255.34.0/31        (leaf4: 10.255.34.1/31)
!
interface Port-Channel2
   switchport access vlan 10
   mlag 2
!
interface Loopback1
   ip address 10.0.1.34/32          (the SAME on both peers)
!
mlag configuration
   domain-id MLAG34
   local-interface Vlan4094
   peer-address 10.255.34.1         (leaf4: 10.255.34.0)
   peer-link Port-Channel1000
   reload-delay mlag 330
   reload-delay non-mlag 300
```

Plus a BGP session across the peer link, because the pair shares an ASN:
```
router bgp 65134
   neighbor 10.255.34.1 remote-as 65134
   neighbor 10.255.34.1 next-hop-self
```

### Answers

**Q1 How leaf1 learns about leaf2.** The type-4 ethernet segment route. Each leaf originates one carrying the ESI and its own originating IP, tagged with the ES-import route-target derived from the ESI. That RT is why leaf1 imports leaf2's type-4 and no one else does. The route reaches leaf1 the ordinary way, leaf2 to spine to leaf1, over the same EVPN sessions everything else uses. No direct adjacency is involved, which is the point: the two leaves do not have to be next to each other, or even in the same rack.

**Q2 Shared ASN on the MLAG pair.** leaf3's routes arrive at leaf4 as `65100 65134` and get dropped as an AS-path loop. That is desirable here, since the two should not route to each other through the spines. The peer-link BGP session gives them a direct path for orphan traffic: a packet arriving at leaf4 for hs2 (single-homed on leaf3) has to cross the peer link, and leaf4 needs a route to send it there.

**Q3 Aliasing.** Type-1 per-EVI auto-discovery. Each ES leaf advertises, per EVI, "I can reach anything on this ESI." A remote leaf combines that with the type-2 MAC route from whichever leaf actually learned the MAC, and installs both VTEPs as next hops. Load balancing to a MAC one leaf never saw is exactly the trick.

**Q4 Shared vs unique VTEP.** MLAG's shared VTEP IP is how the pair hides from the fabric: remote leaves see one VTEP and ECMP to it over the underlay, and MLAG sorts out locally which physical box forwards. EVPN MH does the opposite on purpose: each leaf keeps its own VTEP so the fabric can see both, and type-1 tells it they are equivalent. Share a VTEP IP between ES peers and you break per-leaf withdrawal, DF election identity, and the type-4 originating-IP tiebreak all at once.

**Q5 DF role.** The designated forwarder is the only leaf on the segment allowed to forward BIUM (broadcast, unknown unicast, multicast) from the fabric *down* to the host. Both leaves forward known unicast. Without that rule, every broadcast arrives twice. Two DFs means duplicate broadcast and ARP, plus the host's MAC appearing to move between leaves, which is ticket 1's exact symptom.

## Part B

**B1 Convergence.** The ESI side loses more. When leaf1's host link drops, leaf3 must receive the withdraw, re-run best path for every affected MAC, and reprogram. The MLAG side loses almost nothing: the fabric still sees VTEP 10.0.1.34 reachable through both leaves, so no EVPN update is needed at all. leaf4 picks up the traffic locally and leaf3 forwards orphan traffic over the peer link. That difference is the honest trade: MLAG converges faster for this failure because the fabric never learns about it; EVPN MH converges in the control plane, which costs milliseconds but scales and interoperates.

**B2 Mass withdraw.** One type-1 per-ES auto-discovery withdraw covers the entire segment. Remote leaves treat it as "this ES is gone from this VTEP" and drop that next hop for every MAC behind the ESI in one pass, without waiting for thousands of individual type-2 withdraws. Per-ES A-D is the mass-withdraw route; per-EVI A-D is the aliasing route. They are both type-1 and they do different jobs, which is the detail worth keeping.

**B3 Aliasing proof.** Check `show vxlan address-table vlan 10` on leaf1 and leaf2: hm1's MAC appears on exactly one. On leaf3, the same MAC resolves to both 10.0.1.11 and 10.0.1.12. The per-EVI type-1 from the leaf that never learned the MAC is what put the second next hop there.

**B4 DF behavior.** `tcpdump -ni eth3` on both ES leaves while flooding into VLAN 10: only the DF's port carries it. Shut the DF's uplinks and the other leaf takes over after the type-4 withdraw propagates and DF election re-runs. Time it; it is slower than you would like, and the service-carving behavior across VLANs is worth noting if you run many.

**B5 Split brain.** With the peer link down and both uplinks up, EOS's MLAG peer-keepalive logic puts the secondary's MLAG ports down to avoid a forwarding loop and duplicate delivery. Po2 goes down on one peer and hm2 drops to a single member. The ES side has no equivalent failure because there is no peer link: the two leaves only ever coordinate through BGP, and if that is down they are already isolated from the fabric anyway. This is the single strongest structural argument for EVPN MH.

## Part C tickets

**T1 ESI mismatch on leaf2.** `identifier ...:2222`.
Isolate: `show evpn ethernet-segment` on each leaf shows its own ESI with no peer. Two different segments means two DFs, so BIUM is forwarded twice and the host's MAC flaps between VTEPs in `show vxlan address-table`.
Fix: restore `identifier 0011:1111:1111:1111:1111` on leaf2.
Lesson: the duplicate-traffic-plus-MAC-flap signature is the ES-mismatch fingerprint. The bond stays perfectly healthy, which is why the server team reports it and the network team sees nothing wrong in LACP.

**T2 LACP system-id mismatch on leaf2.**
Isolate: `cat /proc/net/bonding/bond0` on hm1 shows two aggregators and one active slave. `show lacp interface Port-Channel1` on each leaf shows a different system-id. The host refuses to bundle ports that report different LACP partners.
Fix: `lacp system-id 0011.1111.1111` on leaf2.
Lesson: this is a host-side symptom with a switch-side cause. Read `/proc/net/bonding/bond0` before touching the fabric.

**T3 ES route-target import removed on leaf2.**
Isolate: leaf2's type-4 is still originated but carries no ES-import RT, so leaf1 never imports it and the peers never discover each other. On leaf3, `show bgp evpn route-type auto-discovery` has fewer A-D routes than expected, and hm1's MAC resolves to a single VTEP.
Fix: `route-target import 00:11:11:11:11:11`.
Lesson: no aliasing, no peer discovery, no DF election, and still no alarm anywhere. Make "both VTEPs present for a dual-homed MAC" something you actually monitor.

**T4 leaf4's VTEP IP made unique.** `10.0.1.44/32`.
Isolate: leaf1 `show vxlan vtep` now lists 10.0.1.34 and 10.0.1.44. Traffic hashing to the .44 VTEP arrives at leaf4, which has no MLAG-consistent view of the fabric's expectation, and a large share of it is dropped.
Fix: `ip address 10.0.1.34/32`.
Lesson: for an MLAG pair the shared VTEP IP is load-bearing, not cosmetic. It is the one address that must be identical and the one most likely to be "corrected" by someone standardizing loopbacks.

**T5 MLAG domain-id mismatch on leaf4.** `MLAG99`.
Isolate: `show mlag` on both shows state inactive or negotiation failed. `show mlag config-sanity` names the mismatch directly.
Fix: `domain-id MLAG34`.
Lesson: `show mlag config-sanity` is the first command for any MLAG complaint, not the fifth.

**T6 Peer VLAN removed from the peer-link trunk group on leaf3.**
Isolate: Port-Channel1000 is up and VLAN 4094 is no longer carried on it, so `show interfaces Vlan4094` loses its peering and MLAG negotiation fails while every physical indicator looks healthy.
Fix: `switchport trunk group MLAGPEER` on Port-Channel1000.
Lesson: "the peer link is up" is about the port-channel, not about whether the peer VLAN actually traverses it. Check the VLAN, not the link.

**T7 `mlag 2` removed from Port-Channel2 on leaf4.**
Isolate: `show mlag interfaces` shows Po2 as a local-only port-channel on leaf4 rather than an MLAG member. hm2 sees two different LACP partners and bundles only one.
Fix: `mlag 2` under Port-Channel2.
Lesson: same host symptom as T2 on the ES side, different mechanism. The MLAG ID is what makes two local port-channels one logical bundle.

**T8 leaf1 stopped sending extended communities.**
Isolate: leaf3 `show bgp evpn route-type mac-ip 10.10.10.101 detail` shows leaf1's routes with no RT and no ES-import RT, so nothing imports them anywhere. leaf2 no longer sees leaf1's type-4, so the segment loses its peer.
Fix: `neighbor EVPN send-community extended` on leaf1.
Lesson: route-targets and the ES-import RT are both extended communities. One missing line takes out MAC import, aliasing and DF election together. This is the same root cause as Lab 01 ticket 4, which is the point: it looks different every time and it is always the same line.

## Part D

**1 Honest comparison.**

| | MLAG | EVPN MH |
|---|---|---|
| Standard | vendor-specific | RFC 7432 / 8365 |
| Peers | exactly 2 | any number |
| Peer link | required, and a failure domain | none |
| Fabric visibility | hidden behind one VTEP | both leaves visible, type-1 ties them |
| Convergence for a host-link loss | local, very fast | control plane, fast but not free |
| Mixed-vendor pair | no | yes |
| Operational familiarity | high | lower, and the failure modes are subtler |

MLAG is still right when: the pair is a single-vendor top-of-rack with a short lifespan, the team already runs it well, the platform's EVPN MH implementation is young, or you need the absolute fastest local failover for a latency-critical workload. Greenfield at scale, with more than two leaves per segment or mixed vendors, EVPN MH wins.

**2 Past two peers.** MLAG has no concept of a third member: the peer link, the domain, and the primary/secondary role are all built around a pair. EVPN MH handles N peers because the type-4 ES route carries each originator's IP and DF election runs over the full list; adding a fourth leaf changes the modulo in the service-carving calculation and nothing else. Type-1 per-EVI simply adds another valid next hop. The practical limits become DF-election convergence time and how evenly service carving distributes VLANs, not the protocol.

**3 Single-active.** Configure the ES for single-active redundancy. One leaf forwards for the segment and the others stay standby, so there is no per-flow spraying and no reordering. Aliasing goes away: per-EVI A-D no longer makes the non-forwarding leaves valid next hops, so remote leaves send everything to the active one. You trade half your bandwidth for strict ordering, and failover becomes a full control-plane event instead of a local hash change.

**4 Duplicate packets on a dual-homed host.**

EVPN MH, in order: two DFs because the ESI does not match across the pair; the ES-import RT missing so peers never discovered each other; DF election inconsistent across VLANs from a service-carving or algorithm mismatch.

MLAG, in order: the peer link down or the peer VLAN not traversing it, so both peers act as primary; an MLAG ID mismatch leaving a port as a local port-channel; MAC learning asymmetry across the peer link combined with an orphan port.

In both, the fourth thing to check is the host: a bond in a balance mode the switch side does not expect produces its own flavor of duplicates.
