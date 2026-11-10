# Lab 15 Solutions

Do not read this first.

---

## Part A — What parity means

### A2. The audit

**1. The four declared exceptions.**

| Exception | Why it is legitimate | What would end that |
|---|---|---|
| `RM-P2-IN6` has no IPv4 twin (both borders) | `peer2` is an IPv6-only network. There is no IPv4 relationship to write policy for. | They turn on IPv4. Then the missing twin stops being a design choice and becomes a gap. |
| AS 65200 on `edge2` only | The backup transit is deliberately single-homed. A second circuit to a backup transit buys little and costs a port. | The backup becomes load-bearing — if `transit1` were de-rated or the traffic mix changed, single-homing the backup is no longer defensible. |
| AS 65400 on `edge1` only | The customer bought one circuit. Their redundancy is their purchase decision. | They buy a second circuit, or their SLA changes to one that single-homing cannot meet. |

The honest point about the exception list: it exists so that the audit's output
is short enough that somebody reads it. An audit that reports four known things
every run is an audit that gets filtered to `/dev/null` within a month.

**2. Why a naming convention is a prerequisite.** A structural audit has to
pair things up, and the only general way to pair `RM-P1-IN` with its IPv6
counterpart is to agree in advance what that counterpart is called. Without the
convention the tool would need a hand-maintained mapping table, which is
another thing to drift.

Two other things it buys: **grep-ability**, so `show run | section 6$` is a
useful question; and **generation**, because a generator can emit both families
from one data structure, which is how six of this lab's eight faults would have
been impossible.

**3. Why `PL-BOGON` is excluded from the count comparison.** The IPv6 martian
set is genuinely a different length from the IPv4 one — there is no IPv6
equivalent of 127/8 and 169.254/16 as separate entries, and there are IPv6
entries (`fe80::/10`, `fc00::/7`, `ff00::/8`) with no IPv4 counterpart. A count
comparison there would report a divergence on every run, which is exactly the
noise that kills audits.

The risk the exclusion creates: **a missing bogon entry in one family is now
invisible to the audit.** If somebody deletes `deny fc00::/7` the tool says
nothing. The mitigation is a separate, content-based check — assert the IPv6
bogon list against a known-good reference list, which is a different kind of
check and belongs in CI next to this one.

**4. A divergence the audit would miss.** Two route-maps with matching clause
counts, matching local-pref values and matching prepend lengths, where the IPv6
one matches the **wrong prefix-list** — say `RM-P1-IN6` matching `PL6-REG-P2`
instead of `PL6-REG-P1`. Structurally identical, semantically wrong: we would
accept peer2's registered space from peer1 and reject peer1's own.

What catches that is a **state** check: `afi` would show 0 prefixes accepted
from `peer1` in IPv6, because none of what they send matches. The two kinds of
check are complements, not substitutes, and this is the clearest illustration of
why: the audit finds what has no symptom, and state finds what the audit cannot
reason about.

### A3. Dual-stack state

**5. The `edge1:t1` row.**

- **v4 state up / v6 state up** — two separate TCP sessions to two separate
  addresses on the same physical link, each negotiating one AFI.
- **v4 recv 2 / v6 recv 2** — `transit1` announces three prefixes in each
  family; our inbound policy keeps two. See question 6.
- **v4 adv 3 / v6 adv 3** — our two aggregates plus our customer's prefix.
  Three in each family is the whole of our outbound policy working.

**6. The third prefix, and the two mechanisms.** It is `198.18.1.0/24` in IPv4
and `2001:db8:18::/48` in IPv6 — a more-specific of **our own space**, which
`transit1` announces on purpose.

Two things reject it in each family:

1. **The `deny 5` clause** in `RM-T1-IN` / `RM-T1-IN6`, matching
   `PL-OUR-ANY` / `PL6-OUR-ANY`, which permit our aggregates with `le 32` and
   `le 128` and therefore match anything inside them.
2. **Nothing else.** The prefix-length bound in the bogon list (`le 24` for
   IPv4, `le 48` for IPv6) does *not* catch these, because a /24 and a /48 are
   both within the DFZ-acceptable length. That is deliberate — the aggregates
   are /23s and /44s precisely so that a legal-length more-specific exists.

So there is exactly **one** mechanism standing between us and accepting a
more-specific of our own space, in each family, and fault 6 removes it in one.

**7. Fractions, and why a more-specific is worse than a copy.**
`198.18.1.0/24` is **half** of `198.18.0.0/23`. `2001:db8:18::/48` is **one
sixteenth** of `2001:db8:10::/44`.

A copy of your own prefix competes with your own announcement and loses — you
originate it, so your path has the shortest AS path and (locally) the highest
weight. A **more-specific** does not compete at all. Longest-prefix match is
performed before any BGP attribute is consulted, so a /24 at local-pref 100
beats your own /23 at local-pref 400, at weight 32768, with an AS path of zero.
**No policy can out-prefer a more-specific; only a filter can stop it.** That is
the single most important sentence about prefix filtering and it is the reason
`deny 5` exists.

**8. How `transit2`'s IPv6 space becomes usable at `edge1`.**

`edge2` learns `2001:db8:101::/48` from `transit2` over eBGP, with a next hop of
`2001:db8:ffff:21::2` — an address on the `edge2`–`transit2` link, which `edge1`
has no route to. `edge2` then advertises it to `edge1` over the IPv6 iBGP
session and, because of `neighbor 2001:db8:ffff:ffff::1 next-hop-self` **inside
`address-family ipv6`**, rewrites the next hop to its own loopback
`2001:db8:ffff:ffff::2`. `edge1` has a static route to that loopback, so the
route resolves and installs.

The one line it depends on is that `next-hop-self` inside the IPv6
address-family block. The IPv4 one is a separate line at the router level, and
having one without the other is fault 8.

**9. What is harder about a single-family relationship.**

- **Monitoring has no reference.** Every other check in this lab works by
  comparing IPv4 against IPv6. For `peer2` there is nothing to compare against,
  so its policy has to be checked on its own merits — which means somebody has
  to decide what correct looks like rather than reading it off the other family.
- **Tooling built around IPv4 never sees it.** An inventory, an audit or an
  alert keyed on IPv4 sessions does not know AS 65301 exists. Fault 5 is exactly
  this: a relationship silently lost from one border, invisible to anything
  IPv4-shaped. In a network where the IPv4 session list is the de facto source
  of truth, an IPv6-only peer is a relationship nobody is accountable for.

### A4. The maintenance

**10. Why "still present" is the success criterion.** The point of a drain is
to move traffic off a border **while keeping it available as a backup**. If
`transit1` has two paths and one is prepended three times, the drained border is
unused and still there: if `edge2` fails mid-maintenance, traffic returns to
`edge1` automatically.

A count of 1 means the path was **withdrawn**. The drained border is now not a
backup, it is gone. The network is running on a single border with no fallback
at exactly the moment a human has their hands inside the other one. That is the
opposite of graceful.

**11. The three things the drain does.**

1. **`set as-path prepend 65010 65010 65010` outbound** — steers **inbound**
   traffic away from this border. The far end chooses based on AS-path length,
   so this is a request they are very likely to honour but are free to ignore.
2. **`set local-preference 50` inbound** — steers **outbound** traffic away
   from this border's exits. This is entirely ours; nobody else sees it and
   nobody can ignore it.
3. **`set community 65535:0` additive outbound** — a request that the far end
   de-prefer this path themselves. **This is the one the far end can ignore**,
   and here they do.

The division matters: one of the three is enforced by us, one is a strong hint,
and one is a convention. A drain that relies only on the third is not a drain.

**12. `65535:0` is `GRACEFUL_SHUTDOWN`, RFC 8326.** A peer that honours it sets
local-preference on those routes to a value below everything else, so the paths
remain in their table as a last resort and are not used while anything else
exists. That is a cleaner result than prepending, because it does not depend on
competing AS-path lengths you cannot see.

When the peer does not honour it — as here — the community is carried and
ignored, and the drain rests entirely on the prepend and our own local-pref.
Which works, and is why you send all three.

**13. Order of operations for a real maintenance on `edge1`.**

*Before:*
- `./lab.sh parity` — confirm the drain policy exists and is a twin in both
  families. This is the step that catches fault 7, and it is the only step that
  catches it.
- `./lab.sh afi` and `./lab.sh exits` — record the pre-maintenance state so you
  have something to compare against afterwards.
- Confirm `edge2` alone can carry the traffic: capacity, session count, and that
  it holds every relationship `edge1` holds, or knows why not.

*During:*
- `./lab.sh drain edge1`, then read both lines of the drain check. Both green or
  you stop.
- At the transit: `show ip bgp 198.18.0.0/23` and
  `show bgp ipv6 unicast 2001:db8:10::/44` — two paths each, best via `edge2`.
- `./lab.sh afi` — confirm `edge2`'s numbers rose and nothing went to zero.

*After the undrain:*
- `./lab.sh verify` clean, and `afi` / `exits` identical to the records you took
  before. "Identical to before" is the only acceptable end state; "looks fine"
  is how a drain gets left in place for six months.

---

## Part B — The eight faults

### Fault 1 — `peer1`'s IPv6 session at `edge1` is not activated

**Symptom.** `afi` shows `edge1:p1` as `up / DOWN` and `1 / 0` received. The
session is configured with a `remote-as` and is activated in no address family
at all, so it never negotiates anything. `edge1` has no IPv6 path to `peer1`'s
space of its own and falls back to `edge2`'s over iBGP.

**Find it.**
```
edge1# show bgp ipv6 unicast summary                      <- peer1 absent
edge1# show running-config section bgp | section ipv6
edge2# show running-config section bgp | section ipv6     <- the control
```
`parity` names it directly: *neighbor 2001:db8:ffff:31::2 (AS 65300) is
configured and not activated in any address family.*

**Fix.**
```
router bgp 65010
   address-family ipv6
      neighbor 2001:db8:ffff:31::2 activate
```

**Production.** An IPv6 session count alert catches it in seconds — if you have
one. The reason this is fault number one is that most networks do not, and a
configured-but-unactivated neighbour does not appear in a session list at all,
so even an IPv6 session count has to be asserted against an **intended** number
rather than watched for changes.

---

### Fault 2 — `edge2`'s IPv6 local-pref for `peer1` is 80

**Symptom.** In `exits`, `edge2` reaches `peer1`'s space via `p1` in IPv4 and
via `t1` in IPv6. Free capacity in one family, paid transit in the other, for
the same destination.

**Why.** 80 is below `transit1`'s 100, so the peer path loses on local-pref —
step two of best-path, before AS-path length has a chance to save it.

**Find it.**
```
edge2# show bgp ipv6 unicast 2001:db8:110::/48      <- peer path at LP 80
edge2# show running-config section route-map RM-P1-IN6
edge2# show running-config section route-map RM-P1-IN     <- the control, 200
```
`parity`: *RM-P1-IN sets [200], RM-P1-IN6 sets [80]*.

**Fix.** `route-map RM-P1-IN6 permit 10` / `set local-preference 200`

**Production.** Nothing alerts. Every destination is reachable and every
session is up; the cost is a transit bill in one address family. As IPv6 traffic
grows this goes from rounding error to real money without anything changing.
The control is the config audit, or a per-family traffic-by-exit report that
almost nobody builds.

---

### Fault 3 — the customer's IPv6 prefix is filtered outbound at `edge1`

**Symptom.** `afi` shows `edge1:cu` advertising `3 / 2`, and the same on every
other `edge1` session. `verify` reports `transit1 IPv6 paths to 2001:db8:40::/48:
1, expected 2`.

**Why.** A `deny` at sequence 5 of `PL6-CUST` on `edge1`, so clause 20 of
`RM-EXT-OUT6` matches nothing and the customer's IPv6 prefix is announced to
nobody from that border.

**Why the customer is still reachable.** `edge2` learned the prefix from `edge1`
over iBGP — iBGP export carries no outbound policy here — and `edge2`'s own
`PL6-CUST` is intact, so `edge2` announces it to `transit1`, `transit2` and
`peer1`. The customer keeps global IPv6 reachability through one border instead
of two.

**Whose problem it is contractually.** Ours. We sell the customer transit, which
means announcing their prefixes to our upstreams; a redundancy level they are
paying for and not receiving is a breach whether or not they have noticed. The
uncomfortable part is that they cannot detect it from their side: from `cust1`,
IPv6 works.

**Find it.**
```
edge1# show bgp ipv6 unicast neighbors 2001:db8:ffff:11::2 advertised-routes
edge1# show ipv6 prefix-list PL6-CUST
edge1# show ip prefix-list PL-CUST                    <- the control
```
`parity`: *PL-CUST has 1 entry, PL6-CUST has 2* and *PL-CUST has 0 deny
entries, PL6-CUST has 1*.

**Fix.** `no ipv6 prefix-list PL6-CUST seq 5`

**Production.** Alert on **advertised prefix count per session per family**,
asserted against the intended set. For a transit provider this is not optional:
the number of prefixes you announce on a customer's behalf is the product.

---

### Fault 4 — the IPv6 prepend toward `transit2` is gone

**Symptom.** Nothing on our routers. `verify` reports
`transit2 sees our AS prepended twice in IPv6: 0, expected 1`. The IPv4 check
passes.

**Why.** `edge2`'s IPv6 outbound toward `transit2` was switched from
`RM-T2-OUT6` to `RM-EXT-OUT6` — a valid route-map that announces the right
prefixes without the prepend. `transit2` now sees our IPv6 aggregates at AS path
length 1 instead of 3, so it has no reason to prefer `transit1`, and inbound
IPv6 traffic that should arrive over the primary transit arrives over the
backup.

**Find it.**
```
transit2# show bgp ipv6 unicast 2001:db8:10::/44       <- path "65010"
transit2# show ip bgp 198.18.0.0/23                    <- path "65010 65010 65010"
edge2#    show running-config section bgp | section ipv6
```
`parity`: *AS 65200 uses RM-T2-OUT outbound in IPv4 but RM-EXT-OUT6 in IPv6,
which is not its twin.* That is the finding stated more precisely than any state
check could manage — it names the mechanism, not the consequence.

**Fix.**
```
router bgp 65010
   address-family ipv6
      neighbor 2001:db8:ffff:21::2 route-map RM-T2-OUT6 out
```

**Production.** Invisible from inside our AS, which is the recurring lesson of
inbound traffic engineering. You need an external view — a looking glass, RIS,
RouteViews — checking that your prefixes carry the AS paths you intended, **in
both families**. The twin-name check in the audit is the cheap version and it
runs without anybody's cooperation.

---

### Fault 5 — the IPv6-only peer is gone from `edge2`

**Symptom.** `peer2` has one session instead of two. `verify` reports
`peer2 IPv6 Established: 1, expected 2`. Nothing else changes: `edge2` reaches
`peer2`'s space via `edge1` over iBGP, and `peer2` reaches us via `edge1`.

**Why it is the easiest fault in the lab to miss.** `peer2` has **no IPv4
half**. An inventory built from IPv4 sessions does not contain AS 65301. An
audit that compares IPv4 against IPv6 finds nothing, because there is nothing
to compare. The only check that catches it is one that compares **the two
borders against each other** — which is why `parity` does a cross-router pass:
*AS 65301 is configured on edge1 and not on edge2.*

**What turns it into an outage.** `edge1` failing, or being drained for the
maintenance in Part A. At that moment `peer2` has no path to us at all and we
have none to them, and both sides fall back to transit — if they have any. The
fault converts a planned maintenance into a peering outage.

**Find it.**
```
peer2# show bgp ipv6 unicast summary                   <- one session
edge2# show running-config section bgp
edge1# show running-config section bgp                 <- the control
```

**Fix.**
```
router bgp 65010
   neighbor 2001:db8:ffff:42::2 remote-as 65301
   neighbor 2001:db8:ffff:42::2 description peer2_v6
   neighbor 2001:db8:ffff:42::2 send-community
   neighbor 2001:db8:ffff:42::2 maximum-routes 500
   address-family ipv6
      neighbor 2001:db8:ffff:42::2 activate
      neighbor 2001:db8:ffff:42::2 route-map RM-P2-IN6 in
      neighbor 2001:db8:ffff:42::2 route-map RM-EXT-OUT6 out
```

**Production.** Assert the **set** of relationships per border against the
peering database, in both families, and alert on any difference. The database
is the intent and the router is the state; neither one on its own can tell you
a relationship has quietly become single-homed.

---

### Fault 6 — the "never accept our own space" guard is missing in IPv6

**Symptom.** `verify` reports `edge1 IPv6 accepted from transit1: 3, expected 2`
and `edge1 IPv6 paths to 2001:db8:18::/48: 1, expected 0`. The IPv4 equivalents
pass.

**What that means.** `edge1` has installed a route to **a sixteenth of our own
IPv6 address space**, pointing at our transit. Longest-prefix match beats every
attribute, so traffic from `edge1` to anything in `2001:db8:18::/48` leaves our
network, goes to `transit1`, and hits a `Null0`. Our own customers, inside our
own space, unreachable from our own border, with every session up.

**Both mechanisms, and why only one of them matters.** In IPv4 the identical
announcement (`198.18.1.0/24`) is rejected by:

1. the `deny 5` clause matching `PL-OUR-ANY`, and
2. nothing else.

The prefix-length bound in `PL-BOGON` permits `0.0.0.0/0 ge 8 le 24`, and a /24
passes it. In IPv6, `PL6-BOGON` permits `::/0 ge 16 le 48`, and a /48 passes it.
**The length bound was never the control** — it is there to stop de-aggregation,
not to stop a hijack of your own space at a legal length. That is the whole
reason the aggregates in this lab are /23s and /44s rather than /24s and /48s:
to make the distinction testable.

So the answer to "which of the two is missing" is that there was only ever one,
and fault 6 removes it.

**Find it.**
```
edge1# show bgp ipv6 unicast 2001:db8:18::/48           <- installed, LP 100
edge1# show ip bgp 198.18.1.0/24                        <- not present, the control
edge1# show running-config section route-map RM-T1-IN6  <- no deny 5
edge1# show running-config section route-map RM-T1-IN   <- deny 5 present
```
`parity`: *RM-T1-IN has 2 clauses, RM-T1-IN6 has 1.*

**Fix.**
```
route-map RM-T1-IN6 deny 5
   match ipv6 address prefix-list PL6-OUR-ANY
```

**Production.** RPKI route origin validation would reject it independently, in
both families, and is the real answer. Short of that: alert on **any** route to
your own space learned from an external session, which is a two-line check and
should be a page rather than a ticket. And note the generalisation — the same
filter has to exist in both families, and the thing that makes it exist in both
families is generating it from one source.

---

### Fault 7 — the IPv6 drain route-map has no permit clause

**Symptom on a healthy network: none.** Not in `verify`, not in `afi`, not in
`exits`. The route-map is not attached to anything until a drain, so it has no
effect whatsoever.

**Symptom during a maintenance.** `./lab.sh drain edge1` reports:
```
  IPv4  paths at transit1: 2, both still present   best via: 10.1.2.1 (edge2)
  IPv6  paths at transit1: 1, expected 2           best via: ...12::1 (edge2)
```
The IPv4 drain is graceful. The IPv6 drain **withdrew** our prefixes from
`edge1` entirely, because a route-map with no permit clause denies everything.
For the duration of the maintenance, IPv6 is running on a single border with no
fallback — while a human has their hands inside the other one.

**Find it.** Before you drain:
```
edge1# show running-config section route-map RM-DRAIN-OUT6
edge1# show running-config section route-map RM-DRAIN-OUT      <- two permits
```
`parity` names it three ways: *RM-DRAIN-OUT has 2 clauses, RM-DRAIN-OUT6 has 1*;
*RM-DRAIN-OUT has 2 permit clauses, RM-DRAIN-OUT6 has 0*; and
*RM-DRAIN-OUT6 has no permit clause at all, so it denies everything.*

**Fix.**
```
no route-map RM-DRAIN-OUT6 deny 10
route-map RM-DRAIN-OUT6 permit 10
   match ipv6 address prefix-list PL6-OUR
   set as-path prepend 65010 65010 65010
   set community 65535:0 additive
route-map RM-DRAIN-OUT6 permit 20
   match ipv6 address prefix-list PL6-CUST
   set as-path prepend 65010 65010 65010
   set community 65535:0 additive
```

**Production.** **This is the fault that justifies the whole lab.** No state
check can find it, because the state is correct — the broken policy is not in
use. It is found by a config audit, or by a maintenance going wrong at 2am.
The generalisable rule: **policy that is only used during an exceptional
procedure must be audited structurally, because it will never be exercised by
normal traffic.** That covers drain policy, failover policy, RTBH triggers and
every emergency filter you have pre-staged and never tested.

An empty route-map denying everything is also worth remembering on its own
account. It is the single most common way a route-map surprises people.

---

### Fault 8 — `edge2`'s IPv6 iBGP has no `next-hop-self`

**Symptom.** `verify` reports `edge1 IPv6 exit for transit2 space: none,
expected edge2`. `edge1` has the **path** in BGP and nothing in the routing
table. IPv4 is unaffected.

**Why.** Without `next-hop-self` in the IPv6 address family, `edge2` passes
`transit2`'s routes to `edge1` with their original next hop
(`2001:db8:ffff:21::2`), an address on a link `edge1` has no route to. The path
is valid BGP and unresolvable, so it is not installed. IPv4 is fine because its
`next-hop-self` is a separate statement at the router level, which was not
touched.

**It makes fault 1 unobservable, so fix this one first.** Fault 1 leaves
`edge1` with no IPv6 session to `peer1` of its own, so `edge1` depends on
`edge2`'s iBGP path to reach `peer1`'s space. Fault 8 makes that path
unresolvable. The combined symptom is that `edge1` has **no IPv6 route to
peer1's space at all** — which looks like a reachability failure and tells you
nothing about which of two different faults caused it. Fix 8, and fault 1
becomes a clean "the session is not activated" with a working fallback via
`edge2`.

**The two commands that prove it.**
```
edge1# show bgp ipv6 unicast 2001:db8:101::/48     <- path present, next hop db8:ffff:21::2
edge1# show ipv6 route 2001:db8:101::/48           <- nothing
```
Path in BGP, nothing in the table, and the next hop in the first output is an
address that does not appear in `show ipv6 route` — that triple is the whole
diagnosis.

`parity`: *iBGP 2001:db8:ffff:ffff::1 (IPv6) has no next-hop-self.*

**Fix.**
```
router bgp 65010
   address-family ipv6
      neighbor 2001:db8:ffff:ffff::1 next-hop-self
```

**Production.** A BGP path count that does not match a routing table count, per
family, is a cheap and very high-value check — it catches unresolvable next
hops, which is a failure mode with many causes and one signature.

---

## Part B2 — The questions

**14. What pass one can and cannot find.**

State monitoring finds **seven** of the eight: faults 1, 2, 3, 4, 5, 6 and 8 all
produce an observable difference somewhere in `verify`, `afi` or `exits`.

**Fault 7 is invisible to state monitoring**, and the reason is structural
rather than a matter of effort: the broken policy is **not attached to any
session**. There is no state for it to be wrong in. The only ways to find it are
to read the config, to audit the config, or to run the procedure that uses it —
and the procedure is a maintenance, which is the worst possible time.

Two faults are also found *far* more precisely by the audit than by state.
Fault 4 shows up in state as "transit2 does not see our prepend in IPv6", which
tells you the consequence; the audit says "AS 65200 uses `RM-T2-OUT` in IPv4 and
`RM-EXT-OUT6` in IPv6", which tells you the cause. And fault 5 is only found by
state if you happen to know AS 65301 should have two sessions — the audit
derives that from the other border.

**15. Survival time, longest first.**

1. **Fault 7** — no symptom on a healthy network. Survives until a maintenance,
   and then it surfaces as an incident rather than a finding.
2. **Fault 5** — nothing is broken, and the missing relationship has no IPv4
   half for IPv4-shaped tooling to notice. Survives until `edge1` is drained or
   fails.
3. **Fault 4** — invisible from inside our AS. Needs an external view in IPv6,
   which is two layers of thing most networks do not have.
4. **Fault 3** — the customer's IPv6 redundancy halved. The customer cannot
   detect it and we are not watching advertised counts per family.
5. **Fault 2** — a transit bill in one address family. Found when IPv6 traffic
   grows enough to notice, or on an invoice review.
6. **Fault 6** — a sixteenth of our own IPv6 space blackholed. Somebody
   complains, eventually, and it will be hard to believe.
7. **Fault 1** — an IPv6 peering session missing. Caught by an IPv6 session
   count asserted against intent, in seconds, if that exists.
8. **Fault 8** — an IPv6 destination unreachable from one border. The loudest,
   and still only in IPv6.

The ordering says something uncomfortable: the faults that survive longest are
the ones in **policy that is not currently in use** and in **relationships that
have no IPv4 counterpart**. Both are blind spots created by how the network is
monitored, not by how it is configured.

**16. Faults 8 and 1 compound.** Fix **8 first**. While 8 is live, `edge1` has
no usable IPv6 route to `peer1`'s space whether or not its own session exists,
so fault 1 is hidden behind a reachability failure that has a different cause.
Once 8 is fixed, fault 1 presents cleanly: the session is not activated, and
`edge1` reaches `peer1` via `edge2` as a working fallback. Fixing 1 first
changes nothing observable and will look like a failed fix.

**17.** Fault 6. The two mechanisms that *could* reject it in IPv4 are the
`deny 5` guard matching `PL-OUR-ANY`, and the prefix-length bound in
`PL-BOGON`. Only the first one actually does: the bound permits `ge 8 le 24` and
the leak is a /24. In IPv6 the bound permits `ge 16 le 48` and the leak is a
/48, so it passes there too. **The guard is the only control in either family**,
and fault 6 removes the IPv6 copy. The length bound does not save us because it
was never about hijacks — it is there to stop de-aggregation.

**18.** Fault 3. The customer's IPv6 prefix survives via `edge2`, which learned
it over iBGP and announces it normally. It becomes an outage when `edge2` fails
or is drained — at which point the customer loses global IPv6 entirely, and the
cause will be two borders away from the symptom.

Fault 5 is the same shape for a peering relationship rather than a customer one,
and is arguably the better answer to the spirit of the question.

**19.** Fault 3, covered above. Contractually it is ours: announcing a
customer's prefixes to our upstreams is the product they bought, and delivering
it from one border instead of two is a redundancy shortfall they are paying for
and cannot see.

**20.** Fault 4. `transit2` now believes our IPv6 aggregates are one AS hop
away instead of three, so it has no reason to prefer `transit1` and will deliver
inbound IPv6 over the backup circuit. The command is
`show bgp ipv6 unicast 2001:db8:10::/44` **on transit2** — a router we do not
operate — with `show ip bgp 198.18.0.0/23` beside it as the control.

**21.** Fault 8. The mechanism is an **unresolvable next hop**: IPv6 only,
because the IPv4 `next-hop-self` is a separate statement that was not touched.
The two commands are
`show bgp ipv6 unicast 2001:db8:101::/48` (path present, next hop
`2001:db8:ffff:21::2`) and `show ipv6 route 2001:db8:101::/48` (empty).

**22.** A config audit catches **all eight** — every one is a structural
divergence between the two families, and `parity` names each of them on a
running network. State monitoring catches **seven**, and would catch fault 7
only during a maintenance, which is not "catching" it.

That ratio is the argument for the audit, and it should not be overstated in
the other direction: the audit is syntactic, so it would miss the
wrong-prefix-list divergence from question 4, which state finds immediately. The
two are complements. Run both.

---

## Part C — Design

### C1. Running two networks

**23. The policy, in two sentences.**

**Configuration for both address families is generated from one source of truth,
so that a change cannot be made to one family without being made to the other.**
And: **nothing ships until a structural parity audit passes with a declared,
justified exception list.**

Six of the eight faults here — 1, 2, 3, 4, 6, 7 — are impossible under the
first sentence, because they are a human editing one family and not the other.
Fault 5 is caught by the second. Fault 8 is caught by either.

**24. One session for both families, or two.**

*For a single session* (IPv6 transport carrying both AFIs, or IPv4 carrying
both): half the sessions to configure and monitor, so half the places to
diverge. The families fail together, which sounds bad and is operationally
simpler — you cannot have IPv4 up and IPv6 down, which is this entire lab's
fault class. One TCP connection, one hold timer, one convergence event.

*Against it:* the families fail together. An IPv6 transport problem now takes
IPv4 down with it, and a session reset affects both. Capacity and convergence
are shared, so a full-table IPv6 churn delays IPv4 updates. Most peers expect
two sessions and some require them. And the thing that makes this lab's faults
possible — separate policy per family — does not actually go away: you still
write `RM-FOO` and `RM-FOO6` and attach them inside separate address-family
blocks. **A single session reduces the number of places to diverge; it does not
eliminate them.**

*What monitoring sees:* with one session, session-state monitoring stops being
able to tell you which family is broken, so you need per-AFI prefix counts
regardless. That is worth saying plainly, because "one session is simpler to
monitor" is the usual claim and it is only true of the session, not of the
routes.

I would run two sessions, because peer expectations and failure independence
win, and compensate with generation and audit rather than with topology.

**25. Five IPv6 checks, in order.**

1. **IPv6 session count per router, asserted against intent.** Not watched for
   change — asserted. Catches fault 1, where the session does not appear at all.
2. **Accepted prefix count per IPv6 session, asserted against a range.** Catches
   fault 6 (too many) and a peer who stopped announcing (zero), which is the
   most common real event of the two.
3. **Advertised prefix count per IPv6 session, asserted against the intended
   set.** Catches fault 3. For a transit provider this is the product.
4. **BGP path count against routing-table count, per family.** Catches fault 8
   and every other unresolvable-next-hop cause with one check.
5. **External view: our prefixes and their AS paths as seen from outside, in
   IPv6.** Catches fault 4, and nothing else does.

Each one catches something the others cannot. The first four run from inside
and need nobody's cooperation; the fifth needs an external vantage and is the
one people skip.

**26. An IPv6-only peer adds IPv4.** Configuration: an IPv4 session, an IPv4
inbound filter built from their registered IPv4 space, an IPv4 outbound map, a
`maximum-prefix` limit, and an `RM-P2-IN` to pair with `RM-P2-IN6`.

The things that are not configuration, which is the point of the question:
- **Remove the declared exception from the parity audit.** Until you do, the
  tool will keep telling you the missing IPv4 twin is fine. A stale exception
  list is worse than none, because it is trusted.
- **Update the peering database**, which is what the audit's intent is derived
  from.
- **Agree the IPv4 prefix set** with them and get it into IRR or RPKI, because
  the filter has to come from somewhere authoritative.
- **Re-check capacity**: the link was sized for one family's traffic.
- **Tell monitoring**, so the new session is in the asserted session count
  rather than an unexplained increase.

**27. Testing IPv6 end to end, continuously.** Probe from **outside** your
network, because every fault in this lab that is invisible from inside is
invisible for the same reason. Specifically:

- From a set of vantage points in different ASes, over IPv6 only, connect to a
  service address inside each of your aggregates and assert success and latency.
- From the same vantages, resolve and connect over IPv6 to a service behind
  **each customer's** prefix, so you catch fault 3 on their behalf.
- Assert the AS path your prefixes carry at each vantage against the intended
  path, which catches fault 4.
- Probe a destination inside **your own space** from each border, which catches
  fault 6 — the case where your own space has been hijacked back at you.

The last one is the unintuitive and valuable one: the check that your own
address space is still yours, from your own routers.

### C2. IPv6 specifics

**28. No router fragmentation, 9100 core, 1500 handoffs.**

IPv4 routers may fragment a too-large packet that has DF clear. **IPv6 routers
never fragment** — a router that cannot forward a packet drops it and sends
ICMPv6 Packet Too Big, and the **source** is responsible for reducing its
packet size. That makes PMTUD mandatory in IPv6 rather than advisory.

The consequence: if ICMPv6 Packet Too Big is filtered anywhere on the path —
and it very often is, by firewalls configured by people who learned to block
ICMP — you get a **PMTUD black hole**. The signature is distinctive and
infuriating: the TCP handshake completes (small packets), small requests work,
and the first full-size data packet vanishes. The connection opens and then
hangs. People debug it as an application problem for days.

Fixes by layer:
- **Network:** permit ICMPv6 types 1, 2, 3 and 4 everywhere, unconditionally.
  Type 2 is Packet Too Big and filtering it breaks IPv6 by design.
- **TCP:** MSS clamping at the boundary where the MTU drops, so endpoints
  negotiate a segment that fits regardless of whether PMTUD works.
- **Host:** per-route MTU, or just 1500 on interfaces whose traffic leaves.
- **Design:** do not run a 9100 domain with a 1500 exit without clamping. Choose
  the MTU at the boundary deliberately rather than inheriting it.

**29. /48 against /24 in the DFZ.**

*Inbound filters:* your length bound is `le 48` rather than `le 24`, and the
space between an aggregate and the bound is much larger. A /32 holder can emit
65,536 /48s; a /24 holder can emit 256 /32s and will be filtered. So
`maximum-prefix` matters more in IPv6, and the gap between "legal length" and
"reasonable number" is wider.

*`maximum-prefix` limits:* must be set per family and cannot be derived from the
IPv4 number. The IPv6 table is smaller today and growing faster, so a limit set
once will be wrong; it needs a headroom policy and a review cadence, not a
value.

*De-aggregation for traffic engineering:* you have far more room, which is a
trap. Announcing /48s out of a /32 to steer traffic works and is cheap for you
and expensive for everyone else's routing table. The discipline that IPv4
scarcity enforced has to be self-imposed in IPv6.

**30. Three IPv6-specific filter entries with no IPv4 equivalent.**

1. **`fe80::/10`, link-local.** Must never appear in BGP. It is not a global
   prefix and anything announcing it is either broken or probing.
2. **`fc00::/7`, unique local addresses.** The IPv6 answer to RFC 1918, and
   unlike RFC 1918 it is a single large block that people genuinely use
   internally. Accepting it from a peer imports somebody's internal addressing.
3. **`2001:db8::/32`, documentation space.** It appears in examples, in vendor
   defaults, and in configurations copied from blog posts, so it leaks far more
   often than you would expect. (In this lab it is being used *as* real space,
   which is why `PL6-BOGON` denies only the `2001:db8:ffff::/48` link block
   rather than the whole /32 — a deliberate lab compromise, and the README says
   so.)

Honourable mentions: `::/128` and `::1/128`, and `ff00::/8` multicast.

**31. A customer asks you to accept their /56.** No — and the reasoning
matters more than the answer.

A /56 from a /48 assignment is below the length the DFZ generally accepts, so
accepting it does not achieve what they want: your upstreams and peers will
filter it, so the more-specific never propagates and the traffic engineering
does not happen. You would be adding a route to your own table and nothing else.

What to offer instead: they announce the /48 to both of your borders and use
**AS-path prepend or communities** to express the preference, which propagates
because the prefix is of an acceptable length. Or, if they genuinely need two
independent /48s steered differently, assign a second /48 — which is what the
/48-per-site convention is for and costs you nothing out of a /32.

The general principle: **a more-specific is only a traffic-engineering tool if
the internet will carry it.** Below the accepted length it is a local
convenience and a false sense of control.

### C3. Graceful operations

**32. A maintenance procedure that does not depend on `GRACEFUL_SHUTDOWN`.**

The procedure rests on the two things you control:

1. **Inbound steering you own absolutely:** set local-pref low on everything
   learned at the border being drained, so all of *your* outbound traffic moves.
   Nobody can ignore this.
2. **Outbound steering that is very hard to ignore:** prepend your AS three
   times on everything announced from that border. A peer would have to be
   actively overriding AS-path length — which some do, with local-pref — but the
   large majority honour it.
3. **Send `65535:0` as well**, because the peers that honour it give you a
   cleaner result than prepending does: they drop the path to last-resort
   without any dependence on competing path lengths.
4. **Verify, do not assume.** Check at the far end, in both families, that the
   paths are still present and no longer preferred. That is what
   `./lab.sh drain` does and it is the step that distinguishes a procedure from
   a hope.

What the community buys you is **precision where it is honoured** and nothing
where it is not. It is strictly additive, so you always send it, and you never
build the plan on it.

**33. Four ways to drain.**

| Method | Convergence | Blast radius |
|---|---|---|
| local-pref inbound | immediate, our AS only | exactly our outbound traffic. Invisible outside. |
| AS-path prepend outbound | one update cycle per peer, then their internal propagation | everyone downstream of each peer re-decides, including networks you have no relationship with |
| `GRACEFUL_SHUTDOWN` | one update cycle, only at peers who honour it | narrow and precise where honoured, zero where not |
| withdraw | fastest | total. The path is gone, there is no backup, and you have no gradual option |

What I would deploy: **local-pref inbound, plus prepend outbound, plus
`GRACEFUL_SHUTDOWN`, and never withdraw.** The first is enforced, the second is
near-universal, the third is free precision. Withdrawal is for a border that is
actually gone, not one you are working on — and the distinction is the whole
content of question 10.

**34. Twenty minutes into a four-hour window, optics out, IPv6 withdrawn.**

The decision: **continue the maintenance, and do not try to fix the drain
policy while the border is down.**

The reasoning. IPv6 is currently single-homed through `edge2` with no backup —
which is bad, and is also exactly the state you would be in if you aborted,
because the optics are out and `edge1` is not carrying traffic either way.
Aborting does not restore the backup; it just ends the maintenance with the
work half done and the optics on a bench. Meanwhile, editing the drain policy
on a router whose circuits are physically disconnected is a change with no way
to verify it, made under time pressure, which is how a bad night becomes a
worse one.

So: finish the physical work, bring `edge1` back, undrain, verify both families
are present and preferred correctly, and **then** fix `RM-DRAIN-OUT6` with
`edge1` healthy and verifiable. Raise the risk to whoever is on the call so the
decision is shared and recorded, and shorten the window if the work allows.

The thing to escalate is not the fault. It is that **IPv6 is unprotected for the
rest of the window**, so if `edge2` or `transit1` has a problem in the next
three hours, IPv6 is down and the usual fallback is not there.

**35. The pre-maintenance check.**

It asserts that **every route-map, prefix-list and policy attachment used by the
drain procedure exists, is non-empty, and is structurally identical between the
two address families** — specifically that `RM-DRAIN-OUT6` has the same number
of permit clauses as `RM-DRAIN-OUT`, the same prepend length, and the same
community.

It runs in CI against the intended configuration, and again against the live
configuration as the first gate of the maintenance checklist — before anybody
touches anything, and early enough that a failure cancels the window rather
than interrupting it.

**It has to be a config check, and the reason is the whole point of the lab.**
The drain policy is not attached to any session until the drain runs, so it has
no state to be wrong in. There is nothing for a state check to observe. Policy
that is only exercised during an exceptional procedure can only be validated
structurally — which also applies to your failover policy, your RTBH triggers
and every emergency filter you have pre-staged and never fired.

### C4. What this lab cannot show

**36. Three dual-stack failure modes it cannot reproduce.**

1. **PMTUD black holes.** The most common real dual-stack failure, and it needs
   a middlebox filtering ICMPv6 Packet Too Big somewhere on the path. Every
   device here forwards ICMPv6 correctly, so the failure cannot occur. It also
   needs real TCP flows with real data to show the characteristic
   "connects-then-hangs" signature, which `ping` cannot produce.
2. **Neighbour discovery pathologies.** Rogue router advertisements, SLAAC
   addresses appearing on infrastructure links, ND cache exhaustion as a
   denial-of-service against a router with a /64 on a transit LAN. This lab sets
   `ipv6 nd ra suppress all` on every point-to-point link, which is correct
   practice and removes the entire class. Reproducing it needs hosts behaving
   badly on a shared segment.
3. **Divergent operational maturity**, which is the real reason dual-stack
   fails. IPv6 breaks because it was deployed by a project and is operated by
   nobody: the runbook mentions IPv4, the on-call engineer checks IPv4, the
   monitoring was built before IPv6 existed, and the change process has one
   approval step for a change that touches two networks. No lab reproduces an
   organisation. What this lab can do — and the reason it ends with a config
   audit rather than a troubleshooting trophy — is show that the technical
   countermeasure for an organisational problem is **generation plus
   structural audit**, because both of those work while nobody is paying
   attention.
