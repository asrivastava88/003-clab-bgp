# Lab 05 Solutions (spoilers)

Reference configs: `configs/unnumbered/`, with `configs/numbered/` as the control.

## Part A

### Underlay, leaf (identical on all three leaves)

```
ipv6 unicast-routing
ip routing ipv6 interfaces
!
interface Ethernet1
   description P2P_spine1
   no switchport
   mtu 9214
   ipv6 enable
!
interface Ethernet2
   description P2P_spine2
   no switchport
   mtu 9214
   ipv6 enable
!
ip prefix-list PL-LOOPBACKS seq 10 permit 10.0.0.0/24 eq 32
ip prefix-list PL-LOOPBACKS seq 20 permit 10.0.1.0/24 eq 32
!
route-map RM-CONN-2-BGP permit 10
   match ip address prefix-list PL-LOOPBACKS
!
router bgp 65101
   router-id 10.0.0.11
   no bgp default ipv4-unicast
   neighbor UNDERLAY peer group
   neighbor UNDERLAY send-community
   neighbor UNDERLAY maximum-routes 12000
   neighbor interface Et1-2 peer-group UNDERLAY remote-as 65100
   redistribute connected route-map RM-CONN-2-BGP
   !
   address-family ipv4
      neighbor UNDERLAY activate
      neighbor UNDERLAY next-hop address-family ipv6 originate
```

Spines differ only in needing one interface line per leaf:
```
   neighbor interface Et1 peer-group UNDERLAY remote-as 65101
   neighbor interface Et2 peer-group UNDERLAY remote-as 65102
   neighbor interface Et3 peer-group UNDERLAY remote-as 65103
```

### Overlay, unchanged from a numbered fabric

```
   neighbor OVERLAY peer group
   neighbor OVERLAY remote-as 65100
   neighbor OVERLAY update-source Loopback0
   neighbor OVERLAY ebgp-multihop 3
   neighbor OVERLAY send-community extended
   neighbor OVERLAY maximum-routes 0
   neighbor 10.0.0.1 peer group OVERLAY
   neighbor 10.0.0.2 peer group OVERLAY
   !
   address-family evpn
      neighbor OVERLAY activate
```
Spines add `neighbor OVERLAY next-hop-unchanged`.

### Answers

**Q1 Walk the packet.** `ping 10.0.1.12 source 10.0.1.11` on leaf1:

- The outer header is **IPv4**, source 10.0.1.11, destination 10.0.1.12. Nothing about the payload or the addressing becomes IPv6. Only the next hop does.
- leaf1's FIB entry for 10.0.1.12/32 has a next hop of `fe80::...%Et1` (and a second via Et2 for ECMP).
- That link-local address is resolved to a MAC by **IPv6 neighbor discovery**, visible in `show ipv6 neighbors`. In a numbered fabric that role is ARP's; here ND does it.
- The frame leaves Ethernet1 with that MAC as the destination and an IPv4 ethertype.

So the data plane is IPv4 end to end. IPv6 is doing two jobs only: carrying the BGP session, and supplying the adjacency.

**Q2 What `ipv6 unicast-routing` enables.** It is what makes EOS participate in IPv6 on those interfaces at all, which in turn is what makes it look for and maintain a link-local neighbor. Without it there is no neighbor to peer with, so an interface-based session never forms. It is a prerequisite for the discovery, not a statement about routing IPv6 prefixes. The lab routes zero IPv6 prefixes and still needs it.

**Q3 One line versus three.** A leaf's two uplinks both face AS 65100, so `neighbor interface Et1-2 peer-group UNDERLAY remote-as 65100` covers both. A spine faces three different leaf ASNs and EOS has no `remote-as external`, so each interface neighbor has to name its ASN. If EOS had `remote-as external` a spine would also collapse to one line and the fabric would be fully templated with no per-neighbor BGP config anywhere.

Worth noticing which way the asymmetry falls: the devices you have dozens of get the uniform config, and the handful of spines carry the per-neighbor state. That is the right trade.

**Q4 Why the overlay does not care.** The overlay peers Loopback0 to Loopback0 and relies on one thing from the underlay: that remote Loopback0 and Loopback1 are reachable. How that reachability was built is invisible to it. The EVPN next hop stays an IPv4 VTEP address because the leaf sources it from Loopback1, and `next-hop-unchanged` on the spines preserves it.

To run EVPN on the interface sessions instead, the EVPN next hop would have to end up as the originating leaf's IPv4 VTEP address rather than a link-local, across an eBGP hop that rewrites next hops by default. That means the originating leaf setting the next hop explicitly and the spines not touching it, and it means the address family has to be willing to carry an IPv4 next hop over an IPv6-only session. FRR does this; on EOS it needs testing rather than assuming. Part D question 2.

**Q5 What differs between leaf1 and leaf2.** Hostname, Loopback0, Loopback1, the ASN in `router bgp`, `router-id`, the RDs under the MAC-VRF and IP-VRF, and the host-port description. A templating tool needs to supply: hostname, ASN, two loopback addresses, and the VLAN-to-port mapping. Nothing else, and in particular no link addressing.

In the numbered build you additionally supply two /31 host addresses and two peer addresses per leaf, and you have to keep a /31 allocation scheme that stays consistent as the fabric grows. That is the per-device state unnumbered deletes.

## Part B

**B1 The chain.** `./lab.sh nexthops` walks it: no IPv4 on the link, a session named by interface, an IPv4 prefix arriving with an `fe80::` next hop, that next hop sitting in the FIB, ND resolving it to a MAC, and VXLAN tunnelling IPv4 over the result. The point at which a destination becomes a frame on a port is the ND entry, so the two commands that matter are `show ip route <vtep>` and `show ipv6 neighbors`.

**B2 Reduction versus respelling.** Reductions: the six underlay neighbor lines collapsing to one on each leaf, and the two `ip address` lines disappearing. Respellings: `ipv6 enable` replacing `ip address`, and `next-hop address-family ipv6 originate` being the price of admission rather than a saving. Net effect per leaf is roughly eight lines of per-device state removed and two lines of boilerplate added, where the boilerplate is identical everywhere.

**B3 Does uniformity hold.** It holds for the links and not for identity. You still allocate an ASN and two loopbacks per leaf, and you still map VLANs to ports. What goes away is the link-addressing plan, which is the part that scales with ports rather than with devices and the part most likely to drift. Call the claim substantially true and be precise about what it does not cover.

**B4 Sessions up, VTEP unreachable.** At least four ways:

1. Drop the VTEP range from `PL-LOOPBACKS` (ticket 6). Control plane perfect, Loopback1 never advertised.
2. Remove `next-hop address-family ipv6 originate` (ticket 3). Prefixes advertised with a next hop nobody can use.
3. Remove `neighbor UNDERLAY activate` under `address-family ipv4` (ticket 5). Session Established, zero prefixes.
4. Break ND without breaking the session, by clearing or filtering neighbor discovery on one link.

The one least likely to be caught is 2, because every session is up, the prefix count is non-zero, and the route is present in `show ip bgp`. Only the next hop is wrong, and almost nobody alerts on next-hop resolvability. The alert to add is a synthetic check: from each leaf, ping every remote Loopback1 sourced from its own Loopback1. That single probe catches all four.

**B5 Adding leaf4.** On leaf4, the complete config is the standard leaf template with four substitutions: hostname, `router bgp 65104`, `router-id`/`Loopback0` 10.0.0.14, `Loopback1` 10.0.1.14, plus its MAC-VRF RDs. The underlay stanza is copied verbatim.

On the spines: `interface Ethernet3` with `ipv6 enable` and an MTU, one `neighbor interface Et3 peer-group UNDERLAY remote-as 65104` line, and one overlay neighbor block. **No addressing, and no change to any existing link.**

The numbered build needs, additionally, a /31 allocated and configured on both ends of both new links, plus two peer-address lines on leaf4 and one on each spine. Four addresses and three more config lines, every one of them a thing that can be mistyped or collide with an existing allocation. At three leaves that is noise; at sixty it is the reason unnumbered exists.

## Part C tickets

Before any of these: in this lab, `show ipv6 neighbors` is a more informative first command than `show ip bgp summary`, because an unnumbered session that cannot find a peer reports nothing about what it was looking for.

**T1 `ipv6 unicast-routing` removed globally on leaf2.**
Isolate: both sessions drop to Idle or Active with no explanation. `show ipv6 neighbors` on leaf2 is empty, and `show ipv6 interface brief` shows the interfaces without link-local operation. The spines simply see a peer that stopped answering.
Fix: `ipv6 unicast-routing`.
Lesson: the global knob takes out every session at once and leaves no clue in the BGP output. A leaf that loses all its underlay sessions simultaneously, with healthy links, points at something global rather than per-neighbor.

**T2 `ipv6 enable` removed on leaf3 Ethernet2.**
Isolate: `show ipv6 neighbors` on leaf3 has one entry instead of two; `show ipv6 interface brief` shows Ethernet2 with no link-local address. Ethernet2 itself is up/up, which is why the far side reports nothing wrong.
Fix: `ipv6 enable` on Ethernet2.
Lesson: the per-interface version of T1, and the distinguishing evidence is the same two commands. One session down means per-interface; all sessions down means global.

**T3 `next-hop address-family ipv6 originate` removed on leaf1.**
Isolate: leaf1's sessions are Established and it is advertising prefixes, so every obvious check passes. On leaf2, `show ip bgp 10.0.1.11/32` either shows nothing or shows a path whose next hop cannot be resolved, and `show ip route 10.0.1.11` is missing or unresolved. The giveaway is that the failure is one-directional in origin: it is leaf1's *advertisements* that are unusable, so leaf1 reaching others may still work while nothing reaches leaf1.
Fix: `neighbor UNDERLAY next-hop address-family ipv6 originate` under `address-family ipv4`.
Lesson: this is the signature failure of RFC 8950 and the one from B4 that monitoring misses. Session up, prefix count non-zero, route present, next hop useless.

**T4 Wrong `remote-as` on spine2's Ethernet1 interface neighbor.** Set to 65199 instead of 65101.
Isolate: one of spine2's three sessions never comes up. `show ip bgp neighbors` on spine2 for that interface shows the configured remote AS; leaf1 is sending 65101. On a numbered session you would read the mismatch straight out of a notification; here, check the configured value against the peer's actual ASN. `show ipv6 neighbors` is populated, which is what tells you the problem is above the discovery layer.
Fix: `neighbor interface Et1 peer-group UNDERLAY remote-as 65101`.
Lesson: ND working while BGP does not is the dividing line. Use it to decide whether you are debugging IPv6 or BGP.

**T5 `neighbor UNDERLAY activate` removed under `address-family ipv4` on leaf2.**
Isolate: sessions Established and stable, prefix count zero in both directions. `show ip bgp neighbors 10.1.x` or the interface equivalent shows IPv4 unicast not negotiated.
Fix: `neighbor UNDERLAY activate` under `address-family ipv4`.
Lesson: `no bgp default ipv4-unicast` is the right hygiene and it means activation is explicit for every address family. An Established session that has exchanged nothing for an hour is almost always a missing activation rather than a policy problem.

**T6 VTEP range dropped from `PL-LOOPBACKS` on leaf3.**
Isolate: the overlay is perfect, leaf1 holds leaf3's type-2 routes, and `show vxlan vtep` on leaf1 does not list 10.0.1.13. `show ip route 10.0.1.13` is missing. The EVPN routes point at a next hop the underlay never advertised.
Fix: `ip prefix-list PL-LOOPBACKS seq 20 permit 10.0.1.0/24 eq 32`.
Lesson: identical to Lab 01 ticket 6, and deliberately repeated here because the reason it is hard is unchanged across underlay designs: the control plane is not the data plane, and two loopbacks mean the session can be fine while the tunnel has nowhere to go.

**T7 `ebgp-multihop` removed from leaf1's overlay peer group.**
Isolate: leaf1's underlay is flawless and it pings both spine loopbacks. Its EVPN sessions are down. Loopback-to-loopback is more than one IP hop, so without multihop the TTL on the session's packets is 1 and they are discarded in transit.
Fix: `neighbor OVERLAY ebgp-multihop 3`.
Lesson: "I can ping the peer" does not mean a session can form. eBGP defaults to a TTL of 1, and every loopback-peered eBGP session needs multihop regardless of how the underlay is built.

**T8 spine1 rewrites the EVPN next hop.** `next-hop-unchanged` removed.
Isolate: leaf1 `show vxlan vtep` lists 10.0.0.1, a spine Loopback0 that is not a VTEP. `show bgp evpn route-type mac-ip <ip> detail` shows a path with that next hop winning.
Fix: `neighbor OVERLAY next-hop-unchanged` on spine1.
Lesson: third time in the series after Lab 01 ticket 8 and Lab 04 ticket 2, and the point of repeating it is that the underlay changed completely and this failure did not change at all. Any VTEP list entry that is not a leaf Loopback1 is the same red flag it has always been.

## Part D

**1 For and against unnumbered.**

For: no link-addressing plan, so no IPAM for fabric links and no allocation drift as the fabric grows; leaf configs that are genuinely interchangeable, which makes templating and ZTP simpler; one fewer thing to get wrong when adding a device; no wasted address space; and a smaller blast radius for addressing mistakes because there are no addresses.

Against: the failure modes are quieter. A session that cannot find a peer says nothing about what it was looking for, so troubleshooting leans on `show ipv6 neighbors` and on knowing the four required commands. It depends on the platform's addressless-forwarding support, which is where `ip routing ipv6 interfaces` and its hardware caveats live. Interop across vendors is good for the sessions and less uniformly good for next-hop handling. Operationally, "ping the other end of the link" stops being available as a first diagnostic, which is a real loss for on-call. And your existing tooling, dashboards and runbooks probably assume link addresses exist.

Where not to use it: if the team's troubleshooting muscle memory and monitoring are built on link addresses and you cannot change both; on platforms where addressless forwarding is unsupported or caveated; on links that cross an administrative boundary where you want an addressable demarcation point to test to; and anywhere a device in the path does not support it, since the benefit is all-or-nothing per fabric.

**2 EVPN on the interface sessions.** For this to work, the EVPN next hop must arrive at the remote leaf as the originating leaf's IPv4 VTEP address. Over eBGP that fights the default behavior twice: the originating leaf must set the next hop to Loopback1 rather than the session's address, and every spine must leave it alone. With iBGP the next hop is preserved by default, which is why this pattern is easier in a single-ASN design and why FRR's common deployment shape is the one it is.

What to test first on EOS, in order: whether `address-family evpn` can be activated on an interface neighbor at all; what next hop actually appears on a received type-2 when it can; whether the spines' `next-hop-unchanged` applies to it; and whether `show vxlan vtep` ends up with leaf Loopback1 addresses or link-locals. If step two produces a link-local in the VTEP list, stop: that is the whole problem and no amount of policy fixes it.

**3 Three failures session and interface monitoring both miss.**

- Next hop advertised but unresolvable, as in T3. Add a synthetic check: each leaf pings every remote Loopback1 sourced from its own Loopback1. One probe, catches the whole class.
- A VTEP loopback missing from the underlay while the overlay is healthy, as in T6. Alert on the count of entries in `show vxlan vtep` against the expected fabric size.
- An address family Established but not negotiated, as in T5. Alert on accepted prefix count per session being zero for longer than a convergence window, not just on session state.

A fourth worth having: a spine Loopback0 appearing anywhere in a VTEP list.

**4 Interop isolation.** Decide which side is wrong by looking at the wire and at both tables. On the sending side, confirm what it believes it is advertising (`advertised-routes` for that neighbor) and what next hop it put there. On the receiving side, confirm what arrived. If the sender's advertised next hop is a well-formed link-local for the correct interface and the receiver cannot resolve it, the receiver is at fault; if the sender is emitting something else, such as a global address, a zero next hop, or the wrong link's address, the sender is.

Capture the update itself if you can, because a disagreement about next-hop encoding is a disagreement about bytes, and RFC 8950's predecessor RFC 5549 had encoding ambiguity that implementations handled differently. Ask the sending vendor which RFC's encoding they emit and whether it is configurable; ask the receiving vendor which encodings they accept. Have the packet ready, because both will initially say the other is wrong.

**5 IPv6 VTEPs.** The outer VXLAN header becoming IPv6 changes the control plane in several places: the EVPN next hop becomes an IPv6 address, the type-3 inclusive multicast route's tunnel endpoint encoding changes, and the PMSI tunnel attribute has to carry an IPv6 endpoint. That last one is where interop problems concentrate, and there is active work on exactly that.

Before committing, check: platform support for an IPv6 VXLAN source interface at all; whether your EVPN implementation encodes IPv6 tunnel endpoints in the PMSI attribute the same way your other vendor does; whether hardware VTEPs in the fleet support IPv6 encapsulation or only IPv4; and whether your telemetry, flow collection and ACLs can see inside IPv6-encapsulated VXLAN. Then ask what you are buying. An unnumbered IPv4-VTEP fabric already removes the addressing problem, and IPv6 VTEPs mostly buy address space you were not short of.
