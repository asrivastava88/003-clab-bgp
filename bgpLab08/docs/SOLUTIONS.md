# Lab 08 Solutions (spoilers)

Reference config: `configs/solution/`. `configs/base/` is two working, disconnected sites.

## Part A

### The gateway, in full (bgwA; bgwB is the mirror)

```
interface Loopback0
   description ROUTER_ID_EVPN_AND_VTEP
   ip address 10.0.0.14/32
!
interface Ethernet3
   description DCI_bgwB
   no switchport
   mtu 9214
   ip address 172.16.0.1/30
!
vlan 10
!
interface Vxlan1
   vxlan source-interface Loopback0
   vxlan udp-port 4789
   vxlan vlan 10 vni 10010
   vxlan vrf RED vni 50001
!
ip prefix-list PL-DCI-OUT seq 10 permit 10.0.0.14/32
ip prefix-list PL-DCI-IN  seq 10 permit 10.0.2.14/32
!
route-map RM-DCI-OUT permit 10
   match ip address prefix-list PL-DCI-OUT
route-map RM-DCI-IN permit 10
   match ip address prefix-list PL-DCI-IN
route-map RM-SITE-OUT permit 10
   match ip address prefix-list PL-SITE-LOOPBACKS
!
router bgp 65104
   neighbor EVPN next-hop-self                 <- site-facing half
   neighbor 10.1.1.2 route-map RM-SITE-OUT out <- containment
   !
   neighbor 172.16.0.2 remote-as 65204
   neighbor 172.16.0.2 route-map RM-DCI-IN in
   neighbor 172.16.0.2 route-map RM-DCI-OUT out
   !
   neighbor DCI-EVPN peer group
   neighbor DCI-EVPN remote-as 65204
   neighbor DCI-EVPN update-source Loopback0
   neighbor DCI-EVPN ebgp-multihop 3
   neighbor DCI-EVPN next-hop-self              <- DCI-facing half
   neighbor DCI-EVPN send-community extended
   neighbor 10.0.2.14 peer group DCI-EVPN
   !
   vlan 10
      rd 10.0.0.14:10010
      route-target both 10010:10010
      redistribute learned
   !
   vrf RED
      rd 10.0.0.14:50001
      route-target import evpn 50001:50001
      route-target export evpn 50001:50001
```

No SVI for VLAN 10 anywhere on the gateway. It bridges that VNI between two VXLAN domains; the anycast gateway for 10.10.10.0/24 lives on leafA and leafB.

### Answers

**Q1 One loopback, not two.** `next-hop-self` rewrites the next hop to the session's **update-source**. If the gateway peered EVPN from Loopback0 and tunnelled from Loopback1, the far site would receive routes whose next hop is Loopback0, and Loopback0 would not be a tunnel endpoint. The remote leaves would try to build VXLAN tunnels to an address with no Vxlan1 interface behind it, and the data plane would be dead with a perfect control plane.

Collapsing the two roles onto one interface makes the question moot: whichever address EOS derives the next hop from, it is the same address, and it is a real VTEP. Leaves keep two loopbacks because they never set `next-hop-self` on anything.

**Q2 The two halves, and who notices.**

- Drop it on **DCI-EVPN**: site A's routes cross the DCI still carrying leafA's VTEP (10.0.1.11) as the next hop. bgwB has no route to 10.0.1.11, because the DCI underlay carries only gateway loopbacks, so bgwB cannot resolve the next hop, does not install the route, and therefore never advertises it into site B. **Site B notices**, and site A sees nothing wrong at all. That is ticket 1.
- Drop it on **EVPN** (site-facing): routes arriving from the DCI are handed to spineA still carrying bgwB's VTEP (10.0.2.14). spineA has `next-hop-unchanged`, so leafA receives 10.0.2.14, which site A's underlay deliberately does not carry. leafA cannot resolve it. **Site A notices**, and site B is fine. That is ticket 2.

Same missing concept, two opposite blame directions. Which site complains tells you which half.

**Q3 Why the far gateway needs no route to your leaves.** Because no device in site B ever sends a packet to a site A VTEP. Site B's leaves tunnel to bgwB; bgwB tunnels to bgwA; bgwA tunnels to leafA. Each hop is a separate VXLAN tunnel inside one underlay, and the only cross-site tunnel is gateway to gateway.

At ten sites the DCI underlay carries ten gateway loopbacks (or a handful per site with redundant gateways), not ten fabrics' worth of VTEPs. That is the difference between a WAN routing table that grows with the number of sites and one that grows with the number of leaves in every site, which is the number that actually hurts.

**Q4 What stops VLAN 20 crossing.** The gateways do not have VLAN 20, the L2VNI mapping for 10020, or a MAC-VRF for it. A gateway can only bridge a VNI it instantiates, so there is nothing to stitch and the type-2 and type-3 routes for 10020 have no local importer at the border.

That is better than a filter because it is structural rather than configured. A filter is a line someone can broaden by accident, as Lab 06 tickets 2 and 7 demonstrated. Here, extending a VLAN requires deliberately adding it to both gateways, so the default is "not extended" and the change is visible in a diff.

**Q5 A broadcast from hA1 to hB1.** hA1 floods into VLAN 10 on leafA. leafA replicates to the VTEPs it holds for VNI 10010, which is bgwA and nothing else. bgwA decapsulates, floods locally into VLAN 10, and replicates to the VTEPs it holds for 10010, which is bgwB. bgwB decapsulates and replicates to leafB. leafB delivers to hB1.

Three replication steps, each inside one domain. It is not a full mesh across the WAN because no leaf ever has a remote-site VTEP in its flood list; the gateway is the only member of the far domain that either side can see. With a flat stretch, leafA would replicate directly to every leaf in site B, putting one copy per remote leaf on the WAN link for every broadcast frame.

## Part B

**B1 The stitch, five steps.** leafB learns hB1's MAC locally, originates a type-2 with next hop 10.0.3.11 (its own VTEP). bgwB imports it and re-advertises across the DCI with next hop **10.0.2.14** (change one). bgwA receives it, re-advertises into site A with next hop **10.0.0.14** (change two). leafA installs hB1's MAC behind 10.0.0.14. The next hop changes once per domain boundary, which is precisely what "stitched" means.

**B2 Flat stretch, measured.** With `next-hop-unchanged` on the DCI and all loopbacks advertised across it:

1. leafA now has **two** remote VTEPs for VNI 10010: bgwA (for nothing in particular) and leafB. In a real fabric it would have one per remote leaf.
2. The DCI underlay carries every loopback in both sites rather than two.
3. If leafA's VTEP becomes unreachable, site B's leaves hold EVPN routes with an unresolvable next hop and have to re-run best path. Site B's control plane now reacts to a site A device failure, which is the thing the gateway exists to prevent.

One sentence: the gateway converts "every leaf must know every other leaf everywhere" into "every leaf must know its own gateway," and that is a bound on both the underlay and the failure domain.

**B3 The scaling numbers.** Call it *S* sites and *L* leaves per site.

Gateway model: a leaf tracks *L-1* local VTEPs plus 1 gateway, so **L** regardless of *S*. The DCI underlay carries *S* prefixes. At 20 sites and 40 leaves: 40 VTEPs per leaf, 20 prefixes on the WAN.

Flat stretch: a leaf tracks *S × L − 1* VTEPs. The DCI underlay carries *S × L* prefixes. At 20 sites and 40 leaves: 799 VTEPs per leaf and 800 prefixes on the WAN, and every one of those 799 is a device whose failure is now an event in your control plane.

The leaf VTEP count is the number that constrains the hardware. The WAN prefix count is the number that constrains the design. They grow at completely different rates, and that is the entire argument.

**B4 The case for and against extending VLAN 10.** For: live VM mobility between sites with no renumbering, clustered applications that require layer-2 adjacency, and a migration path that does not need the application team to change anything. Against: a broadcast domain spanning the WAN, so a layer-2 problem at one site is a layer-2 problem at both; traffic tromboning when a VM moves but its gateway does not; a dependency on the DCI for intra-subnet traffic; and the fact that you now cannot lose the DCI without partitioning a subnet.

To make VLAN 10 site-local like 20 and 30, the application needs to stop requiring layer-2 adjacency across sites: per-site subnets with DNS or a load balancer directing clients to the right site, state replicated at the application layer rather than assumed shared, and no cluster heartbeat that needs the same broadcast domain. That is an application change, which is why this conversation is usually had with the application team and not inside the network team.

**B5 Breaking the DCI, two numbers.** The L3 path (hA2 to hB2) recovers or fails fast: the route's next hop becomes unreachable when the underlay withdraws the gateway loopback, and it is a single type-5 prefix per subnet. The L2 path (hA1 to hB1) is slower, because it depends on type-2 withdrawals for the individual MACs plus the type-3 flood list changing, and because the hosts' ARP entries stay valid and keep pointing at a MAC that is no longer reachable.

What each one waits for: L3 waits for underlay convergence plus one best-path run; L2 waits for EVPN withdrawals and, at the host, for an ARP entry to age out. That asymmetry is a general property of stretched layer 2 and it is a good reason to prefer L3 across a DCI wherever the application allows.

**B6 Site survivability.** With the DCI down, both sites keep working completely: each spine, leaf and gateway is still in its own fabric, each site's L2VNIs and L3VNI are intact, and hA1 to hA2 and hB1 to hB2 are unaffected. The only loss is cross-site traffic.

With the flat stretch, losing the DCI leaves both sites holding EVPN routes for the other site's VTEPs with unresolvable next hops, and every leaf in both sites has to converge. Worse, if the two sites had been one fabric with a shared spine layer or shared RRs, you would have had a partitioned control plane rather than two independent ones. The gateway model guarantees that a site is a complete, self-sufficient fabric, and that guarantee is the real deliverable.

## Part C tickets

**T1 bgwA lost `next-hop-self` on the DCI session.**
Isolate: every session is Established everywhere. On bgwB, `show bgp evpn route-type mac-ip 10.10.10.101` shows site A's routes arriving with next hop 10.0.1.11, and `show ip route 10.0.1.11` on bgwB is empty, so the paths are received but not valid and bgwB advertises nothing into site B. Site A notices nothing because its own fabric is untouched.
Fix: `neighbor DCI-EVPN next-hop-self` on bgwA.
Lesson: the first half of the gateway rewrite. "One site cannot see the other, and that other site reports no problem" is the fingerprint, and the direction of the complaint tells you which gateway and which peer group.

**T2 bgwA lost `next-hop-self` on the site-facing EVPN peer group.**
Isolate: the mirror of T1. On leafA, `show bgp evpn route-type mac-ip 10.10.10.102` shows site B's routes with next hop 10.0.2.14, and `show ip route 10.0.2.14` on leafA is empty because site A's underlay deliberately does not carry site B loopbacks. `./lab.sh tunnels` shows leafA listing a site B address where it should list only 10.0.0.14.
Fix: `neighbor EVPN next-hop-self` on bgwA.
Lesson: the second half. A gateway terminates two domains and therefore rewrites on both. Do T1 and T2 back to back; the configs differ by one word and the blame points in opposite directions.

**T3 bgwB stopped instantiating L2VNI 10010.**
Isolate: the stretched VLAN is dead and the site-local subnets still cross the DCI fine, which immediately separates L2 extension from L3. `show vxlan vni` on bgwB has no 10010, and `show vxlan flood vtep vlan 10` on leafB does not list bgwB. The type-2 and type-3 routes for 10010 arrive at bgwB and have no local VNI to be bridged into.
Fix: `vxlan vlan 10 vni 10010` under Vxlan1 on bgwB.
Lesson: a gateway stitches only the VNIs it instantiates. This is the same property that keeps VLAN 20 from crossing by accident, seen from the other side: it is a feature when you want containment and the failure when you want extension.

**T4 bgwA's `PL-DCI-OUT` no longer permits its own loopback.**
Isolate: the DCI EVPN session is down. The underlay session is up, and the gateways can ping each other across 172.16.0.0/30, because that is the connected link and not the loopback. The distinguishing command is `show ip route 10.0.0.14` **on bgwB**, which is empty, so bgwB cannot open a TCP session to bgwA's Loopback0.
Fix: restore `ip prefix-list PL-DCI-OUT seq 10 permit 10.0.0.14/32`.
Lesson: do this one next to T7. Both report "the DCI EVPN session will not come up and the link is fine." This one is a missing route to the peer's loopback; T7 is a TTL problem. One command tells them apart, and it is a route lookup rather than anything in BGP.

**T5 bgwB maps VRF RED to VNI 50011.**
Isolate: the site-local subnets stop crossing the DCI and the stretched VLAN is unaffected, which is the exact inverse of T3. `show vxlan vni` on both gateways side by side shows 50001 on one and 50011 on the other. bgwB is encapsulating routed traffic with a VNI bgwA has no VRF bound to.
Fix: `vxlan vrf RED vni 50001`.
Lesson: an L3VNI mismatch breaks routed traffic and leaves bridged traffic healthy. Same lesson as Lab 07 ticket 4, and here it sits beside T3 so you can see the two fingerprints next to each other: "L2 broken, L3 fine" means a MAC-VRF or L2VNI problem, "L3 broken, L2 fine" means the L3VNI or the VRF.

**T6 bgwB's VRF RED stopped importing 50001:50001.**
Isolate: same symptom as T5 and a completely different cause, which is why they are consecutive tickets. Here `show vxlan vni` matches on both gateways. The difference shows up in `show ip route vrf RED` on bgwB, which holds none of site A's prefixes, so bgwB has nothing to re-advertise into site B.
Fix: `route-target import evpn 50001:50001` under `vrf RED` on bgwB.
Lesson: identical symptom, different layer. T5 is an encapsulation mismatch, T6 is an import failure. The discriminator is whether the gateway *has* the routes at all, so check the VRF route table before you check the VNI.

**T7 bgwA lost `ebgp-multihop` on the DCI EVPN session.**
Isolate: the DCI EVPN session is down, the link is up, the gateways ping each other, **and** the underlay session is Established with the expected prefix, so bgwA genuinely has a route to 10.0.2.14. The remaining difference from T4 is TTL: loopback-to-loopback across a routed hop is more than one hop, and eBGP defaults to a TTL of 1.
Fix: `neighbor DCI-EVPN ebgp-multihop 3`.
Lesson: same root cause as Lab 05 ticket 7, and worth meeting again here because the DCI is where people most often forget it. "I can ping the peer" never proves a session can form. Any loopback-peered eBGP session needs multihop, whatever the underlay looks like.

**T8 leafB's VLAN 10 route-target changed to 10010:10019.**
Isolate: site B hosts in the stretched VLAN cannot reach site A, they can reach their own gateway, and they can still reach site A's site-local subnet, which means L3 is fine and only the MAC-VRF is broken. `show vxlan flood vtep vlan 10` on bgwB does not list leafB, and `show bgp evpn route-type imet` shows leafB's type-3 carrying an RT nobody imports.
Fix: `route-target both 10010:10010` under `vlan 10` on leafB.
Lesson: an L2 route-target mismatch inside one site, presenting as a DCI problem because that is where the user noticed it. The route-targets have to agree end to end across both domains, and the failure is reported by whoever is furthest from the cause. The tell that it is site-local rather than a DCI fault: L3 across the DCI still works, so the gateways and the stitch are fine.

## Part D

**1 Gateway versus flat stretch, honestly.** The case for the gateway is the two numbers from B3: a leaf's VTEP count stops growing with the number of sites, and the DCI underlay carries one prefix per gateway instead of one per leaf everywhere. Behind both numbers is the failure domain. With a gateway, a site is a complete fabric that survives on its own and a remote leaf failure is not an event in your control plane.

Where they are right: with two small sites and a reliable DCI, the flat stretch is fewer moving parts, has no next-hop rewrite to get wrong, and has no gateway to be a single point of failure. T1 and T2 do not exist in a flat stretch. If the whole estate is two racks in two buildings and it is never going to be more, the gateway is extra machinery for a problem you do not have. The honest line is that the gateway is the right default because estates grow, not because the flat stretch cannot work.

**2 Two gateways per site.** Both gateways at a site instantiate the same stretched VNIs and the same VRF, peer EVPN with both gateways at the far site, and advertise their own loopbacks across the DCI. Local leaves then see two gateway VTEPs for the stretched VNI and can ECMP to either.

What you now have to prevent that you did not before: a **layer-2 loop across the DCI**. With two gateways per site both bridging the same VNI into the same domain, a BUM frame can enter site A at gateway 1, cross to site B, come back via gateway 2 and re-enter site A. You need a designated forwarder election per VNI so only one gateway per site forwards BUM, which is the same mechanism Lab 03's ESI-LAG used for the same reason. You also want loop protection in the control plane, which is what domain-path (D-PATH) exists for: a route that has already visited your domain carries that fact and is dropped rather than re-imported. With one gateway per site, as here, there is no loop and neither mechanism is needed, which is why this lab configures neither.

The second thing: duplicate delivery of known unicast if both gateways advertise the same MAC with their own next hop. Aliasing behavior and consistent RD/RT configuration across the gateway pair is what keeps that sane.

**3 Three sites: mesh or hub.** A full mesh of DCI sessions is *S(S−1)/2* sessions, so 3 sites is 3 sessions and 6 sites is 15. It gives optimal paths and no dependency on a transit site. A hub gives *S−1* sessions and one place to apply policy, at the cost of all inter-spoke traffic transiting the hub and the hub being a failure domain for cross-site traffic.

At three sites, mesh. The session count is trivial and you gain path optimality for free. The answer changes somewhere around five or six sites, and it changes sooner if the sites are geographically awkward enough that spoke-to-spoke traffic through the hub would take an absurd path, or later if there is already a well-connected hub site with the capacity. The real trigger is not the session count, which stays manageable for a while, but the number of gateway pairs each gateway has to hold EVPN state for.

**4 Extending VLAN 10 to all three sites.** The honest answer is yes it can be done, and here is the bill. You get a broadcast domain spanning three sites, so a layer-2 incident at any one is an incident at all three. Intra-subnet traffic now depends on the DCI, so losing it partitions a subnet rather than merely isolating a site. A VM that moves keeps its gateway's anycast address, which is fine, but its traffic may trombone if any stateful device is pinned to the original site. BUM traffic is replicated across every DCI link for every frame. And you cannot ever take the DCI down for maintenance without an application impact, which means the DCI becomes the thing you are most afraid to touch.

What to propose instead: per-site subnets with the application directing clients to the right site, and L3 across the DCI. If VM mobility is genuinely required, scope the stretch to the specific VLANs that need it and nothing else, accept that those VLANs are a shared failure domain, and be explicit in writing that the DCI is now a production dependency for them. The pattern to avoid is stretching everything because stretching one thing was easy.

**5 Conflicting route-target schemes.** If site B is an acquisition using, say, 60001:60001 for the same tenant, the gateways are exactly where you translate. Each gateway imports the far side's RT and re-originates with its own domain's RT, so each domain keeps its own internally consistent scheme and neither has to renumber.

Translate at the gateway rather than anywhere else, because it is the only place that is in both domains by definition, and because translating at a leaf means every leaf needs to know both schemes. Confirm the exact mechanism on your build: EOS can import a foreign RT and export the local one on the same VRF, which handles the common case, and there are dedicated RT-rewrite features in some releases. Write the mapping down somewhere that is not only the device config, because an RT translation is invisible from either side and the next person will not guess it.

**6 Dedicated stitching versus `next-hop-self`.** A purpose-built VXLAN-to-VXLAN gateway feature typically gives you things this lab cannot: explicit per-VNI control over what is extended, built-in loop prevention and designated-forwarder election for multi-gateway sites, domain-path handling, and operational commands that name the construct so `show` output tells you what the device thinks it is doing rather than making you infer it from next hops.

What you lose by using it: portability, because it is a vendor construct and this lab's approach is just BGP; and visibility, because the mechanism becomes a feature rather than a set of commands you can read. For learning, build it with `next-hop-self` first so the mechanism is in your hands, then use the dedicated feature in production where its loop prevention and DF election are worth having. If you are running multiple gateways per site, prefer the dedicated feature: the parts it adds are precisely the parts that are hard to get right by hand.
