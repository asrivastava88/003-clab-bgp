# Lab 04 Solutions (spoilers)

Reference configs: `configs/solution/` (Part A) and `configs/addpath/` (Part B).

## Part A

### Spines, route reflectors only

```
router bgp 65000
   router-id 10.0.0.1
   no bgp default ipv4-unicast
   neighbor OVERLAY peer group
   neighbor OVERLAY remote-as 65000
   neighbor OVERLAY update-source Loopback0
   neighbor OVERLAY route-reflector-client
   neighbor OVERLAY send-community extended
   neighbor OVERLAY maximum-routes 0
   neighbor 10.0.0.11 peer group OVERLAY
   neighbor 10.0.0.12 peer group OVERLAY
   neighbor 10.0.0.14 peer group OVERLAY
   neighbor 10.0.0.15 peer group OVERLAY
   !
   address-family evpn
      neighbor OVERLAY activate
```

Note what is absent: no VTEP, no VRF, no VXLAN, no `next-hop-unchanged`, no `redistribute connected`. A spine in this design is a control-plane relay and an IP transit hop, nothing else.

### Clients

```
router bgp 65000
   router-id 10.0.0.11
   no bgp default ipv4-unicast
   maximum-paths 4 ecmp 4
   neighbor OVERLAY peer group
   neighbor OVERLAY remote-as 65000
   neighbor OVERLAY update-source Loopback0
   neighbor OVERLAY send-community extended
   neighbor 10.0.0.1 peer group OVERLAY
   neighbor 10.0.0.2 peer group OVERLAY
   !
   vlan 10
      rd 10.0.0.11:10010
      route-target both 10010:10010
      redistribute learned
   !
   address-family evpn
      neighbor OVERLAY activate
   !
   vrf RED
      rd 10.0.0.11:50001
      route-target import evpn 50001:50001
      route-target export evpn 50001:50001
      router-id 10.0.0.11
      maximum-paths 4 ecmp 4
      redistribute connected
```

Borders add, inside `vrf RED`:
```
      neighbor 172.16.1.2 remote-as 65100
      neighbor 172.16.1.2 route-map RM-WAN-IN in
      neighbor 172.16.1.2 route-map RM-WAN-OUT out
      neighbor 172.16.1.2 maximum-routes 1000
      !
      address-family ipv4
         neighbor 172.16.1.2 activate
```

### Answers

**Q1 Next hop.** iBGP does not change the next hop when advertising to another iBGP peer, so the originating VTEP's Loopback1 survives reflection untouched. In labs 01 to 03 every spine-to-leaf session was eBGP, and eBGP rewrites the next hop to self by default, which is why `next-hop-unchanged` was mandatory there.

The one line that breaks everything here is `neighbor OVERLAY next-hop-self` inside `address-family evpn` on a spine. Clients then install the spine's Loopback0 as a VTEP, VXLAN tunnels point at a device that is not a VTEP, and east-west forwarding dies while every session stays green. That is ticket 2.

**Q2 Loopback distribution.** OSPF area 0 carries both Loopback0 (overlay peering) and Loopback1 (VTEP). The overlay never redistributes anything into the default IPv4 table.

The thing that breaks first is **VTEP reachability**, not the session. The overlay session rides Loopback0 and will survive on whichever path OSPF still has; if OSPF loses a path to a remote Loopback1 entirely, EVPN routes still arrive and still look perfect, but their next hop is unresolvable and nothing forwards. The lesson is the same one Lab 01 ticket 6 made: alert on VTEP reachability, not just on session state. Here it is OSPF's job rather than BGP's.

**Q3 What the reflector adds.** `ORIGINATOR_ID`, carrying the router-id of the client that originated the route, and `CLUSTER_LIST`, which the reflector prepends its cluster-id to. Both exist for loop prevention, because iBGP has no AS_PATH to work with inside the AS: a client drops a route whose ORIGINATOR_ID is its own router-id, and a reflector drops a route whose CLUSTER_LIST already contains its own cluster-id. Confirm with `show bgp evpn route-type mac-ip <ip> detail` on leaf1 and look for both.

By default a spine's cluster-id is its router-id, so the two spines have different cluster-ids. That is fine here because the spines do not peer with each other.

**Q4 Best path on the reflector.** Both defaults arrive with the same local-preference (100, untouched), the same AS_PATH (`65100`), the same origin, and the same MED. The comparison runs down to:
1. eBGP over iBGP: both are iBGP as seen by the spine, so no help.
2. Lowest IGP metric to the next hop: both borders are one hop from each spine with identical OSPF cost, so no help.
3. **Lowest router-id**, which picks bleaf1 (10.0.0.14) over bleaf2 (10.0.0.15).

That is the tiebreaker, and it is the reason both reflectors independently choose the same border. Check with `show bgp evpn route-type ip-prefix ipv4 0.0.0.0/0 detail` on spine1.

**Q5 Why one path, and why it is a correctness problem.** A BGP speaker advertises only its best path per prefix. Each reflector picks bleaf1 and sends only that, so leaf1 receives one path from spine1 and an identical one from spine2. Both name bleaf1 as the next hop. leaf1 has no knowledge that bleaf2 exists as an exit.

It is a correctness problem because failover now depends on the control plane propagating a withdraw and a fresh advertisement through the reflector before any client can use the other exit. Until that completes, leaf1 is blackholing traffic toward a border that cannot forward it, even though a perfectly good second exit was online the whole time. Capacity is the smaller half of the complaint.

## Part B

### B1 Where the path disappears

At the reflector's best-path selection, before anything is advertised. `./lab.sh paths` makes the sequence visible:

- Each border holds and originates its own default. Both are correct.
- Each spine holds **two** type-5 routes for 0.0.0.0/0 (one per border) and marks one best.
- Each spine advertises **one** to leaf1.
- leaf1's BGP table has one path, FIB has one VTEP next hop.

The reflector is not misconfigured. This is BGP behaving exactly as specified; the specification simply does not fit a fabric that wants every client to see every exit.

### B2 Cost of hiding, measured

Shut bleaf1's `Ethernet3`. The sequence that has to complete before h1's traffic moves:

1. bleaf1's eBGP session to wan drops (hold timer, or immediately on carrier loss here).
2. bleaf1 withdraws its type-5 default into EVPN.
3. Each spine removes it, re-runs best path, selects bleaf2, advertises the new path.
4. leaf1 receives it, re-runs best path, reprograms the FIB.

Four control-plane steps across three devices. bleaf2 was healthy and reachable throughout; leaf1 simply had no path to install. Typical loss here is seconds, and in production with scale and timers it is longer.

### B3 Add-path

Reflectors, inside `address-family evpn`:
```
      bgp additional-paths send any
      bgp additional-paths receive
```
Clients, inside `address-family evpn`:
```
      bgp additional-paths receive
```
Clients also need `maximum-paths` in the VRF to install more than one, which the reference already sets (`maximum-paths 4 ecmp 4` under `vrf RED`).

Verify:
```
show ip bgp 0.0.0.0/0 vrf RED          # two paths on leaf1
show ip route vrf RED 0.0.0.0/0        # two "via VTEP" next hops, 10.0.1.14 and 10.0.1.15
```
Repeat B2: the loss collapses, because leaf1 already has the second path installed and only has to drop the failed next hop. Nothing has to be advertised to it first.

If the address-family form is rejected on your build, use `neighbor OVERLAY additional-paths send any` and `neighbor OVERLAY additional-paths receive`. Check with `bgp additional-paths ?` inside the EVPN address family.

### B4 Scoping it

`send any` tells the reflector to advertise every path it holds for every prefix. On 40 leaves with full EVPN state that multiplies the reflector's outbound table and every client's inbound table by the number of redundant paths, for all route types, not just the handful you actually wanted.

What to run instead depends on what your build offers. The useful shapes are:
- **`send backup`** or equivalent: best path plus one alternate. That is all this problem needs. Two exits, one spare.
- **`send ecmp`**: only paths that are already equal-cost, which is exactly the dual-border case and nothing else.
- **`send limit N`**: a hard cap, useful as a safety belt alongside either of the above.

For a 40-leaf EVPN fabric: cap it, and prefer the ecmp or backup variant over `any`. Then apply it per peer group rather than globally if your platform allows, so the blast radius is the borders' prefixes and not every type-2 in the fabric. Run `bgp additional-paths send ?` and pick from what is actually there rather than from this list.

### B5 The alternatives

1. **Anycast the exit.** Give both borders the same Loopback1 VTEP IP, as the MLAG pair did in Lab 03. The fabric then sees one VTEP reachable over two underlay paths, and OSPF ECMP does the load sharing. No add-path, no extra BGP state, and failover is an IGP event rather than a BGP one. Cost: you give up per-border visibility, and asymmetric return paths become possible, which matters if anything stateful sits at the edge.
2. **Make the paths unequal on purpose and accept it.** Set local-preference so every leaf prefers bleaf1 and treat bleaf2 as cold standby. No new features at all. Cost: half your egress capacity sits idle, and failover is still the four-step control-plane sequence from B2.
3. **Peer clients to the borders directly**, bypassing the reflector for the default. Real, and genuinely used for a small number of prefixes. Cost: a session mesh that defeats the reason you deployed reflectors.
4. **Dedicated RRs off the data path**, which does not solve path hiding by itself but is the design in which add-path's state cost stops mattering.

The right answer for most fabrics is 1 for the border pair and add-path, scoped, for anything that genuinely needs per-path visibility.

## Part C tickets

**T1 leaf2 is no longer a reflector client.** `route-reflector-client` removed for 10.0.0.12 on both spines.
Isolate: leaf2's sessions are Established and it is sending routes, but `show bgp evpn summary` on leaf1 shows nothing from leaf2, and `show bgp evpn neighbors 10.0.0.12 advertised-routes` on spine1 is empty. A plain iBGP peer's routes are never re-advertised to other iBGP peers, so the spine accepts leaf2's routes and relays nothing in either direction.
Fix: `neighbor 10.0.0.12 route-reflector-client` on both spines.
Lesson: this is the iBGP failure that has no eBGP equivalent. Reflection is opt-in per neighbor, and forgetting it produces a device that looks completely healthy from its own CLI.

**T2 spine1 rewrites the EVPN next hop.** `next-hop-self` added under `address-family evpn`.
Isolate: leaf1 `show vxlan vtep` now lists 10.0.0.1, which is a spine Loopback0 and not a VTEP. `show bgp evpn route-type mac-ip <ip> detail` shows a path with next hop 10.0.0.1 winning. Half the fabric's paths now point at a device with no Vxlan1 interface.
Fix: `no neighbor OVERLAY next-hop-self` in the EVPN address family on spine1.
Lesson: the mirror image of Lab 01 ticket 8. There, eBGP rewrote the next hop unless told not to; here, iBGP preserves it unless told to break it. Same symptom, opposite cause, and the same tell: a VTEP list entry that is not a leaf Loopback1.

**T3 leaf1's OSPF adjacency to spine1 made passive.**
Isolate: `show ip ospf neighbor` on leaf1 shows one neighbor instead of two. `show ip route 10.0.1.12` still resolves, via spine2 only. The EVPN sessions both stay up because Loopback0 is still reachable the long way round. Everything works at reduced capacity, which is why it was reported as a capacity ticket and not an outage.
Fix: `no passive-interface Ethernet1` under `router ospf 1`.
Lesson: `passive-interface default` is the right pattern, and it means every new fabric link needs an explicit exception. A missing exception degrades silently.

**T4 OSPF area mismatch on leaf2's Ethernet2.** The `10.1.0.0/16 area 0` statement was replaced with per-link statements, one of which lands Ethernet2 in area 0.0.0.9.
Isolate: `show ip ospf neighbor` on leaf2 has one neighbor; `show ip ospf interface Ethernet2` reports area 0.0.0.9 while spine2 has it in 0.0.0.0. Pings across the link work because the interfaces are addressed and up; OSPF just refuses to form an adjacency across an area mismatch.
Fix: put Ethernet2 back in area 0.0.0.0.
Lesson: "the link is up and pings fine" rules out almost nothing in the underlay. Compare the protocol's view on both ends, not the interface's.

**T5 leaf1 stopped sending extended communities.**
Isolate: leaf2 `show bgp evpn route-type mac-ip <leaf1 host> detail` shows leaf1's routes with no route-target, so nothing imports them into any MAC-VRF or IP-VRF.
Fix: `neighbor OVERLAY send-community extended` on leaf1.
Lesson: third appearance of this root cause in the series, after Lab 01 ticket 4 and Lab 03 ticket 8. Note what changed: the peer group name, the address family, and nothing else. Route-targets are extended communities and a session that does not carry them produces routes that arrive and do nothing.

**T6 add-path send disabled on spine2.**

Answer the reporter's question first: yes, it is a problem, and no, nothing is broken today. That combination is the whole point of this ticket.

Isolate: leaf1 `show ip bgp 0.0.0.0/0 vrf RED` holds **three** paths rather than four. spine1 contributes two (both borders), spine2 contributes one (its best, bleaf1). Read the cluster list on each path to see which reflector sent it. The FIB still has two VTEP next hops, so ECMP is intact and users see nothing.

What breaks if you leave it: the moment spine1 goes away, for maintenance or otherwise, leaf1 drops to spine2's single best path and loses the second exit entirely. You have silently converted a redundant design into one that depends on a specific reflector. The outage arrives during the next planned spine maintenance, which is the worst time to discover it.

Fix: `bgp additional-paths send any` under `address-family evpn` on spine2.

Lesson: add-path has to be on both reflectors or your path redundancy is only as good as one of them, and the damage is latent. This is also why `verify` asserts an exact path count of four rather than just "more than one": a count of three passes every reachability and ECMP check you would normally run. Treat reflector configuration as a pair and diff the two after every change.

**T7 `maximum-paths 1` in VRF RED on leaf1.**
Isolate: the giveaway is in the ticket text. `show ip bgp 0.0.0.0/0 vrf RED` shows two valid paths; `show ip route vrf RED 0.0.0.0/0` shows one VTEP. BGP selected both; the VRF refused to install more than one.
Fix: `maximum-paths 4 ecmp 4` under `vrf RED`.
Lesson: add-path gets paths into the table. `maximum-paths` is what gets them into the FIB, and it is per-VRF. Two separate knobs, and only the second one shows up in a route table.

**T8 bleaf2's VRF RED export RT changed to 50001:50099.**
Isolate: bleaf2 looks perfect from its own CLI: eBGP up, default in `show ip route vrf RED`, type-5 originated. But no leaf imports it, because the RT on it no longer matches anything. `show bgp evpn route-type ip-prefix ipv4 0.0.0.0/0 detail` on spine1 shows two routes with different RTs.
Fix: `route-target export evpn 50001:50001`.
Lesson: an export RT mismatch is invisible from the device that has it wrong. Always verify an import on a remote device, never an export on the local one.

## Part D

**1 Convert to eBGP-everywhere, or keep iBGP?**

| | iBGP + RR + IGP (this lab) | eBGP everywhere (Lab 01) |
|---|---|---|
| Protocols to run | two, IGP and BGP | one |
| Next-hop handling | preserved by default | must configure `next-hop-unchanged` |
| Loopback distribution | IGP, fast and simple | BGP, needs a redistribute policy |
| Path visibility | one best path per prefix, needs add-path | every leaf sees every path natively |
| Loop prevention | ORIGINATOR_ID and CLUSTER_LIST | AS_PATH |
| Config per leaf | identical, no per-device ASN | per-device ASN to allocate and track |
| Scaling limit | reflector state and session count | none meaningful |
| Failure modes | reflection and cluster subtleties | AS-path and RT subtleties |

Keep iBGP when: the team already runs an IGP well and knows it, the fabric is modest, you want identical leaf configs with no ASN allocation scheme, or you are brownfield and the IGP is already carrying other things. Go eBGP when: the fabric is large, you want one protocol, or you want every leaf to see every path without add-path. The honest summary is that eBGP-everywhere is the better greenfield default at scale, and that is not a strong enough reason on its own to convert a working fabric.

**2 Dedicated reflectors off the data path.**

Improves: reflector CPU and memory stop competing with forwarding; you can scale RR capacity independently; a reflector failure stops being a transit failure; you can run more than two for redundancy without adding spine ports.

Gets worse: the reflectors' best-path choices are now made by devices with a different IGP view of the fabric than the clients, so their notion of "closest exit" can diverge from the clients'. You add infrastructure to monitor and patch. And the control plane now depends on reachability to boxes that carry no traffic, which is a dependency that is easy to under-monitor.

What has to be true: the underlay must reach the reflectors' loopbacks from every client with the same reliability as it reaches the spines, which in practice means the RRs hang off the spines with redundant paths and are in the same IGP area. Also set a shared cluster-id across reflectors serving the same clients so they do not reflect each other's routes back and forth.

**3 Two scaling limits at 40 leaves.**

- **Reflector state and outbound churn.** Every type-2 in the fabric lands on both reflectors and is advertised to 40 clients. The limit you hit is advertisement CPU during a large flap, not table size. Mitigations: scope add-path rather than `send any`, use `maximum-routes` with warning thresholds, enable update grouping (peer groups already give you this), and consider ARP suppression on the leaves to cut type-2 volume at the source.
- **Session count and convergence fan-out on the spines.** 40 sessions per spine, each needing keepalives and each receiving the same update. Mitigations: move the RR function off the spines (question 2), split into multiple clusters with a shared cluster-id per cluster, and keep BFD for the underlay rather than tightening BGP timers on 40 sessions.

**4 Second data center.**

A single ASN across two sites means one iBGP domain, which means a MAC flap in site A is a control-plane event in site B, the two sites share one failure domain for reflection, and there is no natural policy boundary to filter at. It also means the DCI inherits the fabric's loop-prevention mechanism, which was designed for a single fabric.

At the boundary, put a pair of EVPN gateways that terminate the overlay and re-originate: a separate ASN per site, eBGP between them, and type-5 re-origination so each site exports summarized prefixes rather than every host route. Keep L2 extension to the VNIs that genuinely need it and nothing else. That gives you a place to apply policy, a blast-radius boundary, and a point to summarize. Lab 07 builds this.
