# Lab 10 Solutions (spoilers)

Reference configs: `configs/solution/` the hardened edge, `configs/base/` the unprotected one.

## Part A

**A1 and A2: what an unprotected edge holds.**

| Prefix | From | Category |
|---|---|---|
| 10.0.0.0/8 | transit | RFC1918 bogon |
| 192.168.50.0/24 | peer1 | RFC1918 bogon |
| 192.168.100.0/24 | cust2 | RFC1918 bogon |
| 169.254.1.0/24 | cust2 | link-local bogon |
| 203.0.0.0/16 | cust2 | **hijack of your own space** |
| 207.0.1.0/24, 207.0.2.0/24 | cust2 | inside its registered block, so legitimate |

**A3 The one rejected without any policy.** `207.0.9.0/24`. cust2 announces it with AS 65100 already in the path, and BGP rejects a route whose AS_PATH contains the receiver's own ASN. That is loop detection, it is on by default, and it is the only defence in this lab that costs nothing to configure. Confirm with `show ip bgp neighbors 208.0.4.2 received-routes` on edge2: it is received and not accepted.

**A4 What you are leaking.** `transit` holds `205.0.0.0/16` (peer1's space) learned from you, and `peer1` holds `204.0.0.0/16` (transit's space) learned from you. You are providing free transit between two networks that pay nothing for it, and carrying the traffic on your own circuits. The cost is directly on your transit bill, and if peer1 notices it is also the end of the peering relationship.

**A5 Why cust1 holding the full table is a commercial problem.** They contracted for a default route. A full table costs them a bigger router and costs you nothing, but it also means they can now make routing decisions you did not sell them, and if they ever re-announce any of it you have a leak that originated in your own over-delivery.

### Answers

**Q1 Why you can filter a customer and not an upstream.** A customer tells you what they own and you verify it against IRR or RPKI, so you can enumerate it. A transit provider sends you their view of the entire internet, which by definition you cannot enumerate. On an upstream session you filter what is *categorically* invalid regardless of who owns it: bogons, your own space, absurd AS-path lengths, absurd prefix lengths, and a prefix count limit. The asymmetry is the entire shape of edge policy.

**Q2 Two controls against the hijack of your own space.** The own-space deny on ingress, and the registered prefix-list for that customer (203.0.0.0/16 is not inside 207.0.0.0/16). If cust2 hijacked a *third party's* space instead, only the customer prefix-list still catches it, because the own-space filter only knows about yours. That gap is exactly what RPKI origin validation fills, and it is Part D question 2.

**Q3 The property that prevents every leak here.** Default deny: the egress route-map has no terminal permit, so a route that matches no clause is dropped. The opposite in config is a clause with no `match`, which permits everything reaching it. Faults 6, 7 and 8 are all exactly that.

**Q4 What a prefix limit would and would not have caught.** It would have caught nothing in this lab, because the junk is six prefixes and any sane limit is higher. It catches volume, not validity. That puts it last in the order: it is the backstop for a filter that failed open or a neighbour that went mad, not a filter in its own right.

## Part B

### The layered ingress

```
ip prefix-list PL-BOGONS seq 10 permit 0.0.0.0/8 le 32
ip prefix-list PL-BOGONS seq 20 permit 10.0.0.0/8 le 32
   ... 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.2/24, 192.168/16, 224/4, 240/4
!
ip prefix-list PL-OURS seq 10 permit 203.0.0.0/16
ip prefix-list PL-CUST2 seq 10 permit 207.0.0.0/16 le 24
!
route-map RM-FROM-CUST2 deny 5
   match ip address prefix-list PL-BOGONS
route-map RM-FROM-CUST2 deny 6
   match ip address prefix-list PL-OURS
route-map RM-FROM-CUST2 permit 10
   match ip address prefix-list PL-CUST2
   set local-preference 200
   set community 65100:200 additive
```

Upstream and peer ingress is the same minus the registered prefix-list, because there is nothing to enumerate.

### The egress

```
route-map RM-TO-TRANSIT permit 10
   match ip address prefix-list PL-OURS
route-map RM-TO-TRANSIT permit 20
   match community CL-CUSTOMER
!
route-map RM-TO-CUSTOMER permit 10
   match ip address prefix-list PL-DEFAULT
```

No terminal permit anywhere. That absence is the control.

### Answers

**Q5 Session authentication versus TTL security.** Authentication proves the far end knows a shared secret, which defeats an attacker who can inject TCP segments into the session's path, most usefully a forged RST that tears the session down. TTL security requires arriving packets to have a TTL of 255, which means they cannot have crossed a router, so it defeats any off-path attacker regardless of what they know.

Deploy TTL security first on a directly-connected session. It needs no key, no rotation, no coordination with the other side beyond agreeing to turn it on, and it closes the whole class of remote spoofing. Authentication costs you key management for a threat that TTL security has mostly already handled on a point-to-point link. On a multihop session the ranking inverts, because TTL security is much weaker there.

**Q6 Justifying the prefix limit.** Too high and it never fires, so a customer who leaks the full table fills your RIB and possibly your FIB before anything stops it. Too low and it fires on normal growth, taking down a working customer session for no reason, usually at the worst time.

Prefer too high, with a warning threshold well below it. A limit that is slightly too high costs you some memory for a few minutes while a human reacts to the warning. A limit that is slightly too low costs you a customer outage and a phone call where you are in the wrong. Size from what they have registered plus generous headroom, alert on the warning, and review annually rather than reacting to each growth event.

**Q7 Maintaining a static bogon list.** The problem is that unallocated space gets allocated. A prefix you reject today becomes a legitimate customer's space next year, and the failure is silent: you simply cannot reach them, and nothing in your monitoring says why.

Two real approaches: restrict the list to prefixes that will *never* be routable (RFC1918, loopback, link-local, multicast, reserved, documentation) and accept that you are not filtering unallocated space at all; or take a bogon feed from a project that tracks allocations, via a BGP feed or a generated config, so the list updates itself. The first is what most enterprises do and it is the right default. The second is for networks large enough to justify the dependency.

**Q8 Evaluation order.** For an inbound route: AS-path loop detection first, before any policy runs at all, which is why fault 5 is invisible to every filter. Then the inbound route-map, clause by clause in sequence, stopping at the first match: bogon deny, own-space deny, registered prefix permit, implicit deny. Then the prefix limit counts what survived.

Clauses after a match never run. That is why the deny clauses are numbered lowest, and why broadening a later permit cannot undo an earlier deny. It is also why fault 2 (broadening the registered prefix-list) does not let bogons in: clause 5 already denied them.

## Part C: the eight faults

Half are inbound and visible from your own tables. Half are outbound and are not. Check both directions before concluding anything.

**Fault 1 — edge2's cust2 ingress lost its own-space deny.**
Observed: edge2 holds `203.0.0.0/16` with an external path, AS_PATH `65501`.
Fix: restore the `deny 6` clause matching `PL-OURS`.
Why it got through: the bogon list does not contain your own space, and the registered prefix-list is a permit, not a deny, so nothing else in the chain was looking for it. Note the AS_PATH, because fault 5 produces the same prefix with a different one.

**Fault 2 — edge2's `PL-CUST2` broadened to permit everything.**
Observed: edge2 holds more prefixes from cust2 than the three registered ones. The bogons and the hijack are still absent, because clauses 5 and 6 ran first.
Fix: restore `PL-CUST2` to `207.0.0.0/16 le 24` only.
Why nothing catastrophic happened: defence in depth worked. This is the fault that teaches you a layer can fail with no visible damage, which is also why it survives to be discovered during an audit rather than an incident.

**Fault 3 — edge1's transit ingress lost its bogon deny.**
Observed: edge1 holds `10.0.0.0/8` from transit.
Fix: restore the `deny 5` clause on `RM-FROM-TRANSIT`.
Why nothing else caught it: there is no registered prefix-list on an upstream session and there cannot be. The bogon filter is the *only* content control on that session, which makes it load-bearing in a way it is not on a customer session.

**Fault 4 — edge1's peer ingress lost its bogon deny.**
Observed: edge1 holds `192.168.50.0/24` from peer1.
Fix: the same clause on `RM-FROM-PEER`.
Why it is a separate ticket: it is a separate route-map. If you fixed fault 3 and assumed peers were covered, you are half done, and this is the first of two such pairs.

**Fault 5 — `allowas-in 3` added to edge2's cust2 session.**
Observed: edge2 holds `207.0.9.0/24`, AS_PATH `65501 65100`.
Fix: remove `allowas-in` from that neighbour.
Why no filter caught it: it is inside the registered block and is not a bogon or your space, so every policy clause permits it. The only thing that ever rejected it was AS-path loop detection, and `allowas-in` exists specifically to switch that off. It has legitimate uses in hub-and-spoke MPLS designs and almost none at an internet edge, where it means you will accept a route that has already passed through you.

**Fault 6 — a catch-all permit added to `RM-TO-TRANSIT`.**
Observed: nothing in your tables. `transit` holds `205.0.0.0/16` with 65100 in the path.
Fix: remove the clause.
Why you cannot see it locally: your own table is what you *accepted*, and this fault is about what you *sent*. `./lab.sh outbound` checks at the receiver. The habit worth building is that the far side's table is the evidence and your own `advertised-routes` output is a claim.

**Fault 7 — a catch-all permit added to `RM-TO-PEER`.**
Observed: `peer1` holds `204.0.0.0/16` with 65100 in the path.
Fix: remove the clause.
The second pair. In the real world a peer notices this before a transit does, because a transit is happy to carry your mistake and bill someone for it.

**Fault 8 — a catch-all permit added to `RM-TO-CUSTOMER`.**
Observed: `cust1` holds far more than the single default it contracted for.
Fix: remove the clause.
Not a security problem in the strict sense and still a real one: you are delivering something you did not sell, the customer may build a dependency on it, and the day you fix it correctly they will experience it as an outage you caused.

### The pattern across faults 6, 7 and 8

All three are a clause with no `match`, added "temporarily", left behind. Part D question 7 asks you to design the control that makes that impossible, and the answer is not "be more careful".

## Part D

**1 Day-one policy, transit versus customer.**

New transit, inbound: deny bogons; deny your own space; deny prefixes longer than /24 (and shorter than /8); deny absurd AS-path lengths; set local-preference lowest of your three classes; tag with a transit community; set a prefix limit with large headroom and a warning threshold. Outbound: your own aggregates and your customers' prefixes only, default deny.

New customer, inbound: everything above, **plus** a prefix-list of exactly what they registered, **plus** an AS-path filter limiting them to their own cone, **plus** a much lower prefix limit. Set local-preference highest. Tag with a customer community. Outbound: a default, or the full table only if they contracted for it.

Every difference comes from one fact: you can enumerate what a customer owns and you cannot enumerate what a transit provider carries. Everything else follows.

**2 What RPKI would have caught.** The case from Q2: cust2 hijacking a *third party's* address space. ROV checks whether the origin AS of a route is authorised by the address holder to originate that prefix, via a signed ROA, and whether the prefix length is within what the ROA permits. A hijack of someone else's space fails origin validation even though it passes every filter you can write by hand, because you do not need to know who owns it; the RPKI does.

What ROV does **not** check: the rest of the AS path. A route with a valid origin can still have been leaked or path-forged by any AS between you and the origin. ROV says "this origin is allowed to announce this prefix"; it says nothing about whether the path it took is real. That gap is what BGPsec was designed for and what ASPA is now addressing more practically.

**3 Keeping the bogon list right.** Ownership belongs to whoever owns the edge policy, and it needs a named owner rather than "the network team", because the failure mode is silence. Put the list in version control with the rest of the generated edge config, and review it on a schedule rather than on an event, because there is no event.

How you know it drifted: you do not, from inside. Two detections worth having. First, log and count denies per prefix-list entry, and alert on an entry that starts matching after years of matching nothing, because that is either an attack or an allocation. Second, periodically resolve a sample of destinations you cannot reach and check whether any of them fall inside your bogon list. If the network is large enough to justify it, replace the static list with a bogon feed and the problem becomes someone else's.

**4 The 2am prefix-limit call.** Check: what the limit is set to, what they are currently announcing, and what they were announcing before, from your own logging or looking-glass history. Then check whether the growth is inside their registered space or outside it.

Tell them: the session is down because the number of prefixes they are announcing crossed a configured limit, give them the number, and give them what they are announcing now versus what you expected.

If they genuinely changed nothing, the likely answers are that an upstream of theirs leaked into them, that a de-aggregation happened automatically somewhere, or that your limit was set below their normal count and today was the first time it mattered. Raise the limit to restore service, then investigate. Restoring a customer is not the same as agreeing they were right, and you can say both.

**5 Policy for 400 customers.** Generate it. One template per neighbour class, one data file per customer holding their ASN, their registered prefixes, their prefix limit and their session addresses, and a renderer that produces the device config. The same approach `tools/gen_configs.py` uses in this lab: the data is the policy and the config is a build artifact.

What it costs you: the running config is no longer the source of truth, so a manual change on a device is invisible until it is overwritten or until drift detection catches it. You need that drift detection or the generation is worse than hand-writing, because people will still make emergency changes at 2am. And a bug in the template is a bug on 400 sessions at once, so the template needs a review process that a single customer's route-map never did.

**6 RFC 9234 roles and OTC.** Each eBGP session is configured with a role: provider, customer, peer, route-server, route-server-client. The Only-To-Customer attribute is set on routes sent to or received from a provider or peer, and a route carrying OTC may only be sent onward to customers. A leak like faults 6 and 7 becomes detectable by the protocol itself rather than by whether you remembered to write the right policy, and critically it is detectable by the *receiver* as well as preventable by the sender.

Check `bgp ?` and `neighbor ?` on your build for role support. Whether it would replace Part B's egress policy: no, supplement it. Roles only help where both ends implement them, which at an internet edge is a long tail you do not control, and they do not address anything inbound. The value is that they turn a class of mistake from undetectable into automatic, which is exactly the shape of control question 7 is asking for.

**7 Making a leftover permit clause impossible.** Being careful is not a control. Three things that are:

- **The config is generated.** A clause that is not in the source data does not survive the next render, so a hand-added debugging clause has a maximum lifetime of one deployment cycle. This alone fixes most of it.
- **Drift detection that fails loudly.** Compare running config against generated config on a schedule and alert on any difference, treating an unexpected clause as an incident rather than a report. Without this, generation just means nobody notices the hand edit.
- **An outbound prefix-count alarm per session.** The symptom of every one of faults 6, 7 and 8 is the same: you are advertising more prefixes than the policy should allow. One threshold per session catches all three within a polling interval, regardless of what caused them, and it also catches the cases you did not anticipate.

The first two prevent, the third detects, and you want all three because the first two depend on process discipline and the third does not.
