# Lab 06 Solutions (spoilers)

Reference config: `configs/solution/`. `configs/base/` is the unpoliced starting point.

## Part A

### Ingress: tag and rank by neighbor type

```
ip community-list CL-TRANSIT permit 65100:100
ip community-list CL-PEER permit 65100:150
ip community-list CL-CUSTOMER permit 65100:200
!
ip prefix-list PL-CUST1 seq 10 permit 10.5.0.0/16
!
route-map RM-FROM-TRANSIT permit 10
   set local-preference 100
   set community 65100:100 additive
!
route-map RM-FROM-PEER permit 10
   set local-preference 150
   set community 65100:150 additive
!
route-map RM-FROM-CUSTOMER permit 10
   match ip address prefix-list PL-CUST1
   set local-preference 200
   set community 65100:200 additive
```

`additive` matters on every one of these. Without it you discard whatever the neighbor sent, including communities you may be using for other purposes, and you convert a tag into a replacement.

The customer map has a `match` and the other two do not. That is the asymmetry of the triangle: you filter tightly what a customer may announce, and you accept whatever a transit sends you.

### Egress: default deny

```
ip prefix-list PL-OURS seq 10 permit 10.100.0.0/16
ip prefix-list PL-DEFAULT seq 10 permit 0.0.0.0/0
!
route-map RM-TO-TRANSIT permit 10
   match ip address prefix-list PL-OURS
route-map RM-TO-TRANSIT permit 20
   match community CL-CUSTOMER
!
route-map RM-TO-PEER permit 10
   match ip address prefix-list PL-OURS
route-map RM-TO-PEER permit 20
   match community CL-CUSTOMER
!
route-map RM-TO-CUSTOMER permit 10
   match ip address prefix-list PL-DEFAULT
route-map RM-TO-CUSTOMER permit 20
   match ip address prefix-list PL-OURS
route-map RM-TO-CUSTOMER permit 30
   match community CL-TRANSIT
route-map RM-TO-CUSTOMER permit 40
   match community CL-PEER
```

There is no final permit on the transit and peer maps, and that is the whole safety property. A route that matches nothing is dropped. Add a catch-all and you have ticket 7.

### Sessions

```
router bgp 65100
   neighbor IBGP next-hop-self          ! on the edges only
   neighbor IBGP send-community         ! the tags must survive iBGP
   neighbor 172.16.12.2 route-map RM-FROM-TRANSIT in
   neighbor 172.16.12.2 route-map RM-TO-TRANSIT out
   neighbor 172.16.12.2 maximum-routes 5000
   neighbor 172.16.15.2 route-map RM-FROM-CUSTOMER in
   neighbor 172.16.15.2 route-map RM-TO-CUSTOMER out
   neighbor 172.16.15.2 maximum-routes 50
   aggregate-address 10.100.0.0/16 summary-only
```

A6's customer number: 50 against 3 announced. You want enough headroom that normal growth does not page you, and a low enough ceiling that a full-table leak from the customer trips the limit instead of filling your RIB. For a single-prefix customer, somewhere in the tens. For a customer with their own downstreams, size it off what they have registered and revisit it annually.

### Answers

**Q1 Why communities and not the session.** Because the decision is made on a different router from the one that learned the route. cust1 peers with edge2. edge1 is the one that has to decide whether to announce 10.5.0.0/16 to transitA, and from edge1's point of view that route arrived over an iBGP session from edge2 along with transit routes, peer routes and everything else. The session tells edge1 nothing.

You could try to rebuild the knowledge from the AS_PATH, but that breaks the moment a customer has their own downstream customers, and it breaks completely for your own originated space. Tag once at the edge where the fact is known, and every other router inherits it. This is also exactly what ticket 8 breaks.

**Q2 summary-only toward iBGP.** It works because `core` originates the /20s itself, from connected Loopbacks plus `network` statements, so it never needed to learn them from an edge. edge1 and edge2 each suppress the components toward all neighbors, but each still has them in its own table from core.

If `core` had not originated them, say the /20s were learned from some fourth internal router that peered only with edge1, then edge1 would suppress them toward edge2 and core, those two would have only the /16 aggregate pointing back at edge1, and you would have built a routing black hole for any part of the /16 that was not actually covered. The general rule: `summary-only` on a device that is not the origin of the components is a trap, and the fix is an `attribute-map` or doing the aggregation where origination happens.

**Q3 LOCAL_PREF is a billing decision.** Customer 200, peer 150, transit 100. A customer pays you to carry their traffic, so you want it; a peer costs nothing, so it is better than paying; a transit costs money per bit, so it is the last resort. None of that has anything to do with which path is shorter or faster. BGP's default behavior would compare AS_PATH length and could easily hand you a two-hop paid path over a three-hop free one, which is why LOCAL_PREF sits above AS_PATH in the algorithm and why you set it on ingress at every edge.

**Q4 transitA versus peerX, same AS_PATH length.** Both arrive at edge1 directly over eBGP. WEIGHT is equal (default). The next step is LOCAL_PREF, and that is where it ends: peerX's path is 150, transitA's is 100, so peerX wins. Nothing below LOCAL_PREF is ever consulted. That is the design working as intended; if you had not set LOCAL_PREF, the comparison would have fallen through to AS_PATH length, tied again, and eventually been decided by something arbitrary like the lowest neighbor address.

**Q5 On core with LOCAL_PREF equalized.** Both paths are iBGP, both have the same AS_PATH length if you pick the two transit paths, MED is not comparable across different neighbor ASes, and neither is locally originated. The deciding step is **lowest IGP metric to the next hop**: 10 to edge1's Loopback0 versus 30 to edge2's. That is deterministic because the OSPF costs were set deliberately, not left at the bandwidth-derived default where both links would have tied and the decision would have dropped through to router-id.

## Part B

**B1 Three paths, three different answers.** edge1 holds the transitA path (LP 100) and the peerX path (LP 150) and picks peerX. edge2 holds only the transitB path (LP 100) and picks it, having nothing to compare. core holds edge1's best (peerX, LP 150) and edge2's best (transitB, LP 100) and picks the peerX path via edge1. The answers differ because each router only ever sees its neighbors' *best* paths, not the full set, which is the same property Lab 04 made you confront with route reflectors.

**B2 Forcing each step.** The method matters more than the commands: after each change, confirm from `show ip bgp <prefix>` that the step you intended is the one that decided, by checking that everything above it in the list is still tied. The order to work down is weight, local-pref, locally originated, AS_PATH length, origin, MED, eBGP over iBGP, IGP metric, age, router-id, cluster length, neighbor address.

Two notes. **MED** is only compared between paths from the same neighbor AS unless you turn on always-compare-med, so in this topology there is no natural pair to compare it between; create one by having far's prefix arrive twice from the same upstream, or accept that you have to enable the global knob to see it work and understand that doing so in production changes decisions you did not intend. **IGP metric** is the step people skip, and it is the one the OSPF costs in this lab exist to let you demonstrate.

**B3 Multipath.** The two transit paths have equal AS_PATH length but different content (65200 65600 versus 65300 65600). Plain multipath requires the AS_PATH to match, not just its length, so you need the relax knob. Confirm the exact form with `bgp bestpath ?` and `bgp bestpath as-path ?` on your build, then verify with `show ip route 10.6.0.0/16` showing two next hops.

Would you run it toward two upstreams in production? Usually not for everything. You lose the ability to reason about which provider carries which traffic, your return path becomes whatever the far side chooses regardless of what you did, and billing becomes unpredictable across two 95th-percentile commitments. Where it earns its place is inside your own AS, or toward two links to the *same* provider.

**B4 AS_PATH filtering.** The structure is: build a list that permits only the customer's own ASN and their cone (`^65500$` and `^65500_` style patterns), deny everything else, and reference it with `match as-path <list-name>` alongside the existing prefix match. Find the creation syntax with `ip as-path ?`.

The test is the valuable part: have cust1 announce 10.6.0.0/16 and confirm you reject it. Prefix filtering alone would have caught that one too, because 10.6.0.0/16 is not in PL-CUST1, which is why real providers run both. The prefix list protects against the prefixes you know about; the AS_PATH filter protects against the shape of a leak, including prefixes you have never heard of.

**B5 Conditional advertisement.** If you find it: the shape is an advertise-map naming what to send, and a non-exist-map naming the prefix whose absence triggers it, attached per neighbor. Test by shutting edge1's Ethernet3 and watching 10.100.32.0/20 appear on transitB.

If you cannot find it on your build, the honest alternatives are: announce the backup prefix all the time with a long AS_PATH prepend or a provider's de-pref community, which costs you nothing operationally but means the prefix is always visible; or script it off a session-state hook, which is fragile and belongs nowhere near a production edge. The first is what most networks actually do, and it is worth knowing that conditional advertisement is often a solution to a problem that prepending already solves well enough.

**B6 Graceful shutdown.** On edge1's egress to both eBGP neighbors, set LOCAL_PREF 0 and add the GRACEFUL_SHUTDOWN community (EOS has a named flag for it in `set community`, alongside `no-export` and the rest). Verify core moves to edge2 and that `show ip bgp summary` never shows a session leaving Established.

The community (RFC 8326, well-known value 65535:0) asks the receiving side to set its own LOCAL_PREF to the lowest value for those routes, so the far end de-prefers you *before* you stop forwarding. You set LOCAL_PREF 0 as well because the community only works if the far side honors it, and you cannot assume they do. The community handles the half of the problem you do not control; your own LOCAL_PREF handles the half you do.

## Part C tickets

**T1 `next-hop-self` removed from edge2's iBGP peer group.**
Not a policy problem. Isolate: core holds the prefixes but `show ip bgp 10.201.0.0/16` on core shows a next hop of 172.16.13.2, which is on edge2's eBGP link and is not in OSPF. The path is received but not valid, so it is never best. Everything via edge1 still works, which is why the report says "through edge2."
Fix: `neighbor IBGP next-hop-self` on edge2.
Lesson: an iBGP route keeps the eBGP next hop unless you rewrite it. A router with no eBGP sessions of its own has no route to any eBGP link, and in this design that is `core` by construction.

**T2 A catch-all permit added to `RM-TO-TRANSIT` on edge2.**
This is the leak, and nothing is down. Isolate: `./lab.sh leaks` shows the edge2-to-transitB session carrying far more than two prefixes, including 10.200.0.0/16, which belongs to transitA. `show route-map RM-TO-TRANSIT` shows the extra clause.
Fix: remove the catch-all clause.
Lesson: the absence of a final permit *is* the policy. Someone adds a permissive clause "temporarily" to debug something, forgets it, and you are free transit between two upstreams. Alert on advertised-prefix count per eBGP session; it would have caught this in minutes. This is the small version of the leaks that make the news.

**T3 `PL-CUST1` broadened to permit everything.**
A hijack we propagate. Isolate: `show ip bgp 10.6.0.0/16` on edge2 now has a path with AS_PATH 65500 and LOCAL_PREF 200, which beats every legitimate path we have, so we prefer the hijack ourselves *and* announce it to both upstreams because it carries the customer tag. `show ip prefix-list PL-CUST1` shows the extra entry.
Fix: restore the prefix-list to permit only 10.5.0.0/16.
Lesson: customer ingress filters are the single highest-value filter on an internet edge, because the customer tag gives whatever gets through the best LOCAL_PREF in your network and an automatic ticket to every peer. The order of damage is worth noticing: you break it for yourself first, then for everyone who believes you.

**T4 Peer ingress LOCAL_PREF changed from 150 to 50.**
Costs money, breaks nothing. Isolate: `./lab.sh bestpath 10.6.0.0/16` now shows core choosing a transit path. `show ip bgp 10.202.0.0/16` on edge1 shows the peer's own prefix at LOCAL_PREF 50, below transit's 100, so even traffic destined to the peer takes a paid path.
Fix: `set local-preference 150` in `RM-FROM-PEER`.
Lesson: a one-digit change with no alarm and a monthly invoice. The second-order effect is worse than the first: traffic to the peer's *own* prefixes now transits an upstream, which is both expensive and embarrassing when they notice. Monitor traffic ratios per session, not just session state.

**T5 `summary-only` dropped from the aggregate on edge1.**
Isolate: transitA now receives 10.100.0.0/16 plus the four /20s. `show ip bgp neighbors 172.16.12.2 advertised-routes` shows five of our prefixes where there should be one. The aggregate is still there, which is why nobody noticed immediately.
Fix: `aggregate-address 10.100.0.0/16 summary-only`.
Lesson: the aggregate forming and the components being suppressed are two separate behaviors of one command. Seeing your aggregate in a looking glass proves nothing about whether you are also leaking the pieces. Count what you advertise.

**T6 `maximum-routes 2` on the cust1 session, against 3 announced.**
Isolate: `show ip bgp summary` shows the session cycling, and `show ip bgp neighbors 172.16.15.2` reports the prefix limit being exceeded. The customer genuinely changed nothing; the limit is below what they have been announcing all along.
Fix: set the limit with real headroom.
Lesson: same root cause as Lab 02 ticket 7, in a context where it is far more likely. Prefix limits on customer sessions are mandatory and are also the most common cause of self-inflicted customer outages. Size from what they have registered, set a warning threshold well below the hard limit, and alert on the warning.

**T7 A catch-all permit added to `RM-TO-PEER` on edge1.**
The peer-facing sibling of T2. Isolate: `./lab.sh leaks` shows the peerX session carrying transit-learned prefixes. peerX's complaint is accurate.
Fix: remove the catch-all.
Lesson: a peer notices faster than a transit does, because a transit is happy to carry your mistake and bill someone for it while a peer is suddenly receiving traffic it gets nothing for. The fix is identical; what differs is who tells you.

**T8 `send-community` removed from edge2's iBGP peer group.**
Isolate: edge2 still has 10.5.0.0/16 with the customer tag, and transitB still receives it, because edge2 learned and tagged it locally. But on edge1 the same route now arrives from edge2 with no communities, so `RM-TO-TRANSIT` clause 20 does not match and clause 10 does not either, and edge1 drops it. The customer disappears from transitA only. `show ip bgp 10.5.0.0/16 detail` on edge1 shows no community list where there should be 65100:200.
Fix: `neighbor IBGP send-community` on edge2.
Lesson: this is the fourth appearance of a missing `send-community` in the series, after Lab 01 ticket 4, Lab 03 ticket 8 and Lab 04 ticket 5. Note what is different here: the communities are plain standard communities carrying your own policy, not route-targets, and the failure is partial rather than total. Half the internet reaching a customer is harder to spot than none of it. If a community decides your egress policy, the session that carries it between your own routers is load-bearing infrastructure.

## Part D

**1 A customer asks you to announce a /24 you cannot attribute to them.** Verify before accepting: an IRR route object or RPKI ROA authorizing that ASN to originate that prefix; a letter of authority from the holder if the registry does not show it; and whether the covering block's holder is someone you can contact. If you cannot verify, you do not announce it. The cost of saying no is an unhappy customer; the cost of saying yes is a hijack with your ASN in the path, which costs you your reputation with every peer who filters on IRR data, and increasingly it simply will not propagate because your upstreams filter too.

**2 Influencing inbound, most to least reliable.**

1. **Which provider you announce to at all.** Total control, blunt instrument. Announce a prefix only to transitA and all its inbound arrives there.
2. **More-specific announcements.** A longer prefix beats any policy anyone else has, because longest-match wins before BGP policy is consulted. Reliable to the point of being rude, and it costs table slots everywhere.
3. **Your provider's traffic-engineering communities.** They publish a menu, you tag, they act. Reliable because it is a contract, but it only affects that provider's network.
4. **AS_PATH prepending.** Works on networks that have not overridden it with LOCAL_PREF, which is most of the far internet but almost never your own provider's direct customers. Lab 02's TE-2 is exactly this disappointment.
5. **MED.** Only meaningful between two sessions to the same AS, and only if they compare it.

The ranking is that way because each step down the list depends on more of someone else's policy being default, and LOCAL_PREF in a stranger's network beats anything you can put in an attribute.

**3 Where `remove-private-as` belongs.** When you give a customer a private ASN, or they use one, and you are their upstream. Their routes arrive with a private ASN in the path, and if you pass that on, the rest of the internet sees a path containing an ASN that is not globally unique. Two different customers of two different providers can hold 65000 at once, so a third party may see an apparent AS_PATH loop and drop a legitimate route, or may stitch two unrelated networks into one apparent path. Stripping it on egress leaves the path as yours and makes the route globally usable.

The failure it prevents, concretely, is the one Lab 01's fusion ticket 7 reproduced: a private ASN coming back around and being dropped as a loop.

**4 Authentication and TTL security.** MD5 or TCP-AO on the session protects against an attacker who can inject TCP segments into the session's path, which gets them session resets at minimum. GTSM (TTL security) protects against an off-path attacker spoofing session packets from more than one hop away, by requiring an arriving TTL of 255 so anything that has transited a router is discarded.

Deploy GTSM first on directly connected eBGP sessions. It is cheap, needs no key management, and shuts down the entire class of remote spoofing attacks. Authentication costs you a key to distribute, rotate and coordinate with the far side, which is real operational weight for a threat model that GTSM has already largely closed on a point-to-point link. On multihop sessions, where GTSM is weaker, authentication becomes the more important of the two. Confirm the EOS command on your build; the manual has a "Configuring GTSM for BGP" section.

**5 A customer /24 inside your aggregate, announced to one upstream only.** Keep `summary-only` and use an `unsuppress-map` on the transitA neighbor naming that /24, so the component is released on that one session while staying suppressed everywhere else. Confirm the exact option with `neighbor ?` and `aggregate-address ?` on your build.

What goes wrong if you simply stop suppressing it: it is released to every neighbor, so transitB and peerX get it too, and you have lost the single-provider steering you were asked for. Worse, the more-specific now beats your aggregate everywhere in the internet, so *all* inbound traffic for that /24 follows it rather than your intended paths, and you have accidentally done the thing from question 2 item 2 without meaning to.

**6 Three controls after a ninety-minute leak.**

- **Preventive:** egress prefix-count limits per eBGP session, so a session that should carry two prefixes cannot carry forty thousand. Pair it with the policy itself being default-deny, which it already is, and with a config-review rule that no route-map facing a transit or peer may contain a clause with no `match`.
- **Detective:** alert on advertised-prefix count per session crossing a baseline, which catches T2, T5 and T7 within a polling interval, and subscribe to an external route-leak feed so you hear about it from outside as well as inside.
- **Blast radius:** make the "temporary debugging clause" impossible to leave behind. Any permissive change to an egress policy goes in with an expiry, whether that is a scheduled rollback job, a config-audit check that fails on an unexpected clause, or simply the discipline that such changes are made in a maintenance window with a revert committed before the change. The leak was not caused by someone being careless once; it was caused by a change that had no mechanism to undo itself.
