# Lab 18 Solutions

Do not read this first.

---

## Part A — The design

**1. Ashburn's aggregate, arriving at a Seattle leaf.** `10.12.0.0/16`, hop by
hop:

| At | AS path | Tier that added the last ASN |
|---|---|---|
| originated at `est-b1` / `est-b2` | — | region border, 65209 |
| at `wan1` | `65209` | carrier A, 65500 |
| at `wst-b1` | `65500 65209` | |
| at `wst-ss1` | `65109 65500 65209` | Seattle border, 65109 |
| at `wst-p1-s1` | `65100 65109 65500 65209` | Seattle super-spine, 65100 |
| at `wst-p1-l1` | `65101 65100 65109 65500 65209` | Seattle pod-1 spine, 65101 |

Five ASNs and five tiers, and every one of them is doing a job: the leaf's own
ASN would make a sixth if the route went any further, which is what stops it.

**2. Why the protection survives inside a region and dies between them.**

*Inside:* `wst-p1-l1` cannot pass that route to `wst-p1-s2`, because it would
arrive carrying `65111 65101 …` and `wst-p1-s2` is 65101. Its own ASN, so it
drops it. Free.

*Between:* `wst-b1` passing it to `wan2` sends `65109 65500 65209`. `wan2` is
**65600**. Nothing in that path belongs to `wan2`, so `wan2` accepts it.

**The property that breaks it is that the two carriers are different ASes.**
Loop detection only protects a network from paths that have already been
through *that* network. Carrier B has never seen this route, so it has no
reason to refuse it, and Seattle has just offered itself as a path between
Ashburn and London.

**3. If both carriers were one AS.** Then `wan2` would be 65500, the leaked
path `65109 65500 65209` would contain its own ASN, and it would drop it.
**Region transit would be prevented by numbering again**, exactly as inside a
region.

And no, you would not therefore buy both circuits from one carrier. You would
be trading a real, frequent, expensive risk — a carrier outage taking both of
your DCI paths at once — for protection against a misconfiguration you can
prevent with one route-map. Lab 13's whole subject is that shared fate is the
thing that actually kills you. Buy two carriers and write the policy.

**4. A border announces two prefixes: the region aggregate and the anycast
prefix.**

The region's loopbacks are not among them because **nothing outside the region
needs to reach them**. A pod's loopbacks go to the super-spines because the
super-spines and borders are inside the same region and genuinely need to reach
those devices — for management, for BGP next-hop resolution, for an overlay if
one is added later. Across a WAN, none of that applies: no carrier and no other
region has any business reaching a Seattle spine's loopback.

The general rule: **infrastructure addressing stops at the boundary of the
failure domain it belongs to.** Letting loopbacks cross the WAN would mean 38
extra prefixes in the carriers' tables and 38 extra things to filter.

**5. The two aggregation boundaries.**

| Boundary | Originator | Far side should see | If it stopped summarising |
|---|---|---|---|
| pod → super-spine | the pod's two spines, `Null0` + `network` | one /17 per pod | 8 server /24s per pod instead of 1 prefix — 16 per region |
| region → carrier | the region's two borders | one /16 per region | 2 /17s instead of 1, or 16 /24s if both boundaries failed |

**6. Is `RM-WAN-IN deny 5` load-bearing or decorative?** Load-bearing, and the
argument is the same one Lab 17 made about the leaf filter.

Today it catches nothing, because nothing should be sending Seattle its own
space. But the circumstances in which it fires are exactly the circumstances in
which you most need it: somebody has leaked your space, or a carrier has
misconfigured, or your own border has leaked and the route has come back round.
In every one of those cases, accepting your own aggregate from a carrier means
**sending your own internal traffic out to the WAN**, which converts somebody
else's mistake into your outage.

A filter whose value is zero in the normal case and enormous in the abnormal
one is not decorative. It is insurance, and the premium is one route-map clause.

**7. Distinct physical paths, Seattle leaf to Ashburn leaf.** 2 spine uplinks ×
2 super-spine uplinks × 2 border uplinks × 2 carriers × 2 borders at the far
end × 2 super-spines × 2 spines = **128 distinct physical paths.**

Any single router knows about **2**. Each tier sees only its own next hop, and
the fabric's path diversity never appears in any one routing table. That
decomposition is the reason a Clos scales and the reason a width of 1 anywhere
is worth alarming on: it is not one lost path, it is half the paths below that
point.

**8. Anycast works on AS-path length.** Every region originates `10.100.0.0/24`
from its own pod-1 leaf, so a Seattle leaf sees the local copy at path length 2
(`65101 65111`) and the remote copies at length 6 or more. Shortest path wins
and every region serves itself.

**What would break it:** a border setting local-preference on routes learned
from the carriers. Local-pref is compared *before* AS-path length, so a border
that set local-pref 250 inbound would make the remote anycast copies beat the
local one, and the whole region would cross an ocean to reach a service in its
own building. The borders here set local-pref 100 — the default — on purpose.

---

## Part B — The twelve faults

### Fault 1 — a border leaks what a carrier told it

**Symptom.** `transit` shows `wst-b1` advertising **8 or more** prefixes to
each carrier where a border's role permits 2. `regions` shows, at `wan2`, a
path to Ashburn containing `65109 65500` — Seattle's border ASN followed by
carrier A's.

**Alone, it changes no traffic.** `wan2` already has a direct path to Ashburn
at AS-path length 1 (`65209`); the leaked one is length 3. It loses best-path
selection everywhere and is never used.

**What it is.** `wst-b1`'s outbound route-map toward both carriers was replaced
with a permit-all, so it re-announces everything it knows — including both
other regions' aggregates, learned from the carriers.

**Find it.**
```
wan2#    show ip bgp 10.12.0.0/16          <- a path via 65109
wst-b1#  show ip bgp neighbors <wan2> advertised-routes   <- 8+, should be 2
wst-b2#  show ip bgp neighbors <wan2> advertised-routes   <- 2, the control
wst-b1#  show running-config section bgp | include route-map
```

**Fix.** Restore `RM-WAN-OUT` on both carrier peer groups and remove `RM-ALL`.

**Production.** Nothing in your own network changes, so nothing alerts. The
control is an **advertised-prefix count per external session, asserted against
a constant** — a border's number is 2 and never changes. That check is three
lines and it is the single most valuable alarm at a region border, because the
thing it catches is the thing that ends careers.

---

### Fault 2 — a carrier stops believing a region

**Symptom.** Nothing obviously wrong, and that is the trap. `wan2` has lost its
direct path to Ashburn, so the only path it has is **the leaked one through
Seattle**. Ashburn is still reachable from everywhere, and London's traffic to
Ashburn over carrier B now crosses Seattle's fabric.

**What it is.** `wan2` has an inbound filter denying `10.12.0.0/16` from
Ashburn's borders. It is in a network you do not operate.

**The traffic that flows when 1 and 2 are both live.** London to Ashburn, via
carrier B: `eur-b* → wan2 → wst-b1 → wst-ss* → wst-b* → wan1 → est-b*`. Seattle
carries it across its own super-spine tier and pays for it twice — once on the
circuit in and once on the circuit out — for traffic between two other regions.

**The AS path that proves it,** read on `eur-b1`:
```
eur-b1# show ip bgp 10.12.0.0/16
   65600 65109 65500 65209
```
A region ASN sandwiched between two carrier ASNs. There is no legitimate
reading of that path.

**Why you must fix 1 before 2 — and what happens if you only fix 1.** Fixing
fault 1 removes the leak, and `wan2` then has **no path to Ashburn at all**.
Anything whose best path to Ashburn ran through carrier B loses it. So:

1. Confirm the blast radius first: `show ip bgp 10.12.0.0/16` on both carriers.
2. Fix fault 1 anyway — you do not leave a leak running to paper over somebody
   else's filter.
3. Open the carrier ticket at the same moment, not after.

**Find it.**
```
wan2#   show ip bgp 10.12.0.0/16                              <- only the leaked path
wan1#   show ip bgp 10.12.0.0/16                              <- two direct paths
est-b1# show ip bgp neighbors <wan2> advertised-routes        <- we ARE sending it
```
Our side advertises it and their side does not have it: that pair of facts is
the whole diagnosis, and it is also exactly what you paste into the ticket.

**What to send the carrier:** the session, the prefix, our `advertised-routes`
output showing we announce it on both borders, and their looking-glass or your
own `show ip bgp` at an adjacent vantage showing they do not have it. **What to
change meanwhile:** nothing clever. Do not re-leak it. If the capacity loss
matters, shift traffic deliberately with a prepend toward carrier B rather than
leaving an accidental transit path running.

---

### Fault 3 — a border rejects one region inbound

**Symptom.** `width` shows London's leaves and borders with **1** next hop to
Seattle's aggregate instead of 2. Everything is reachable.

**What it is.** `eur-b2`'s `RM-WAN-IN` gained a match that denies
`10.11.0.0/16`, so that border discards Seattle's aggregate from both carriers.
London reaches Seattle through `eur-b1` only.

**Find it.**
```
eur-b1# show ip bgp 10.11.0.0/16     <- two paths
eur-b2# show ip bgp 10.11.0.0/16     <- none
eur-b2# show ip bgp neighbors <wan1> received-routes | include 10.11
eur-b2# show running-config section route-map RM-WAN-IN
eur-b1# show running-config section route-map RM-WAN-IN    <- the control
```
Received and not kept localises it to inbound policy in one step.

**Fix.** Restore `RM-WAN-IN` to the generated form.

**Production.** A width poll at the border tier, compared between the two
borders of a region. Asymmetry between a pair that should be identical is the
cheapest fabric alarm there is.

---

### Fault 4 — one spine stops originating a pod aggregate

**Symptom.** `verify` fails on `est-ss1/2 paths to 10.12.128.0/17: 1, expected
2`. Nothing else. Ashburn pod 2 is fully reachable.

**What it is.** `est-p2-s2` no longer originates `10.12.128.0/17`. The pod is
announced to the super-spine tier by one spine instead of two.

**Why it matters.** The day `est-p2-s1` reboots, **Ashburn pod 2 vanishes from
the rest of the fabric** — not degraded, gone — while `est-p2-s2` and all its
leaves are perfectly healthy. A pod with two spines has silently become a pod
with one.

**Find it.**
```
est-ss1#   show ip bgp 10.12.128.0/17                <- one path
est-ss1#   show ip bgp 10.12.0.0/17                  <- two, the control
est-p2-s2# show running-config section bgp | include network
est-p2-s1# show running-config section bgp | include network   <- the control
```

**Fix.** `router bgp 65202` / `address-family ipv4` / `network 10.12.128.0/17`.

**Production.** Path count per pod aggregate at the super-spine tier, asserted
against the number of spines in that pod. A constant that only changes when you
build.

---

### Fault 5 — a border leaks pod aggregates to the carriers

**Symptom.** `table` shows both carriers holding **/17s** where the count
should be 0. `verify` fails on `pod aggregates held`.

**What it is.** `wst-b2`'s `PL-REGION-OUT` gained an entry permitting
`10.11.0.0/16 ge 17 le 17`, so the two Seattle pod aggregates now pass the
outbound filter.

**Why only one border leaks.** The filter is per-device. `wst-b1` is unchanged,
and so are all four borders in the other regions. That asymmetry is how you
find it — and it has a second effect worth noticing: because the /17s are
**more specific** than the /16, all inbound Seattle traffic from the carriers
now prefers `wst-b2`. Longest-prefix match beats everything, so one border is
carrying the region's entire inbound load.

**Find it.**
```
wan1#   show ip bgp | include 10.11.
wst-b2# show ip prefix-list PL-REGION-OUT
wst-b1# show ip prefix-list PL-REGION-OUT       <- the control
```

**Fix.** `no ip prefix-list PL-REGION-OUT seq 5`.

**Production.** Prefix count at the carrier-facing boundary, asserted against a
constant derived from the region count. Same check as fault 1, same two lines,
and it catches both.

---

### Fault 6 — a server subnet disappears behind two aggregates

**Symptom.** `verify` fails on `wst reaches 10.12.6.1`. Everything else passes.
**Three tiers** above that address still hold a route that covers it: the
Seattle leaf has `10.12.0.0/16`, the carriers have `10.12.0.0/16`, and
Ashburn's super-spines have `10.12.0.0/17`.

**What it is.** `est-p1-l2` no longer originates `10.12.6.0/24`.

**Where the packet dies.** At `est-p1-s1` or `est-p1-s2` — the pod spines,
which originate `10.12.0.0/17` to `Null0` and no longer have the specific. That
is **eight hops** from the Seattle leaf that sent it, past two aggregation
boundaries, in a device that is working correctly.

Compare Lab 17, where the same fault died three hops away past one boundary.
**Every aggregation boundary you add moves the blackhole further from the
sender and makes it harder to find** — which is the cost of the thing that
makes the fabric scale, and it is worth being explicit about that trade.

**Find it.** Walk down, do not guess:
```
wst-p1-l1#  show ip route 10.12.6.1     <- covered, looks fine
wst-b1#     show ip route 10.12.6.1     <- covered, looks fine
wan1#       show ip route 10.12.6.1     <- covered, looks fine
est-b1#     show ip route 10.12.6.1     <- covered by the /16 it originates
est-ss1#    show ip route 10.12.6.1     <- covered by the /17
est-p1-s1#  show ip route 10.12.6.1     <- Null0. Here.
est-p1-l2#  show running-config section bgp | include network
```
The rule: **the first router whose `show ip route` returns `Null0` for a
destination that is not its own is the aggregation boundary where the specific
went missing.**

**Fix.** `router bgp 65212` / `address-family ipv4` / `network 10.12.6.0/24`.

**Production.** Nothing above the pod will ever report it. A per-pod
specific-prefix count asserted against an inventory, which is the Lab 16
model-versus-reality check applied to server subnets.

---

### Fault 7 — `maximum-paths 1` at a super-spine

**Symptom.** `width` shows `eur-ss1` with **1** next hop everywhere `eur-ss2`
shows 2.

**Find it.**
```
eur-ss1# show ip bgp 10.11.0.0/16        <- two paths known
eur-ss1# show ip route 10.11.0.0/16      <- one installed
eur-ss1# show running-config section bgp | include maximum-paths
eur-ss2# show running-config section bgp | include maximum-paths   <- the control
```
**Paths known versus paths installed** is the signature, and it is what
separates this from fault 3 (the route never arrived) and fault 8 (BGP is not
the source of the installed route).

**Fix.** `router bgp 65300` / `maximum-paths 8 ecmp 8`.

---

### Fault 8 — a static route beats BGP on one leaf

**Symptom.** `width` shows `wst-p1-l2` with **1** next hop to Ashburn's
aggregate. `show ip bgp` on that leaf shows two healthy paths.

**What it is.** `ip route 10.12.0.0/16 <spine>` — administrative distance 1
against eBGP's 20. The static wins and all Ashburn traffic leaves on one uplink.

**The command that distinguishes it from fault 7:**
```
wst-p1-l2# show ip route 10.12.0.0/16
```
On fault 7 the source is BGP and there is one next hop. Here the source is
**static**. One command, two different answers, two different faults.

**Fix.** `no ip route 10.12.0.0/16 <address>`.

**Production.** A config audit asserting that no fabric device has a static
route other than a management default. The correct set is empty, so the check
is trivial and catches a whole class.

---

### Fault 9 — a region stops originating the anycast prefix

**Symptom.** `anycast` shows `eur-p2-l1`'s best path to `10.100.0.0/24` with a
**carrier ASN in it**. London's users are crossing an ocean to reach a service
that is supposed to exist in London.

**What it is.** `eur-p1-l1` no longer originates `10.100.0.0/24`. London's
local copy is gone, so the next shortest path is Seattle's or Ashburn's,
through a carrier.

**Find it.**
```
eur-p2-l1#  show ip bgp 10.100.0.0/24      <- AS path contains 65500 or 65600
wst-p2-l1#  show ip bgp 10.100.0.0/24      <- stays in region, the control
eur-p1-l1#  show running-config section bgp | include network
```

**Fix.** `router bgp 65311` / `address-family ipv4` / `network 10.100.0.0/24`.

**Production.** Nothing alerts — the service is reachable, just from the wrong
continent. The control is a per-region probe that resolves and connects to the
anycast address and asserts **which instance answered**, which is the only
check that sees this from the user's point of view. Latency alone would also
catch it, which is the cheap version.

---

### Fault 10 — a border prepends itself out of the inbound path

**Symptom.** Invisible from inside Ashburn. At the carriers, `10.12.0.0/16` has
two paths but one carries `65209 65209 65209`, so both carriers install **one**
next hop and send all inbound Ashburn traffic to `est-b1`.

**What it is.** `est-b2`'s `RM-WAN-OUT` gained `set as-path prepend 65209
65209`.

**Why nothing inside the region can see it.** Inbound traffic engineering is
decided by what the *other side* does with what you announce. Ashburn's own
routing tables are unchanged; `est-b2` is up, has all its routes, and is
carrying its share of outbound. Only the carriers know, and you do not operate
them.

**Find it.**
```
wan1#    show ip bgp 10.12.0.0/16                         <- one path prepended
est-b2#  show ip bgp neighbors <wan1> advertised-routes detail
est-b2#  show running-config section route-map RM-WAN-OUT
est-b1#  show running-config section route-map RM-WAN-OUT   <- the control
```

**Fix.** `no set as-path prepend` under `RM-WAN-OUT permit 10` on `est-b2`.

**Production.** This needs an **external view**: a looking glass, RIS,
RouteViews, or the carriers' own portals, checking that your prefixes carry the
AS paths you intended from the outside. Internally the best you can do is
per-border inbound traffic counters and alarm on a large asymmetry between a
pair — which catches it, slowly, and only if somebody looks.

---

### Fault 11 — a leaf is quietly single-homed

**Symptom.** None. `verify` catches it only because it asserts session counts:
`wst-p2-s1 Established: 3, expected 4`.

**What it is.** `wst-p2-s1` no longer has a session to `wst-p2-l2`. That leaf
has one uplink where every other leaf in the fabric has two.

**Why you count on the spine, not the leaf.** The leaf's own session count is
2 if you count configured neighbours and 1 if you count Established — easy to
misread. The spine is unambiguous: it should have four sessions (two leaves,
two super-spines) and it has three.

**What turns it into an outage.** Anything that takes `wst-p2-s2` out — a
failure, a reload, a routine upgrade. At that moment `wst-p2-l2` and every rack
behind it is isolated, while a perfectly healthy spine sits beside it.

**Find it.**
```
wst-p2-s1# show ip bgp summary                 <- three sessions
wst-p2-s2# show ip bgp summary                 <- four, the control
wst-p2-l2# show ip bgp summary                 <- one
wst-p2-s1# show running-config section bgp | include neighbor
```

**Fix.** Restore the `LEAF-65114` peer group and its neighbour.

**Production.** Session count per device asserted against the intended
topology — the Lab 16 check. In a fabric this regular the intended count is a
function of the tier, so the assertion writes itself.

---

### Fault 12 — a carrier session is gone

**Symptom.** Loud. `eur-b1 Established: 3, expected 4`. `eur-b1` has lost its
session to carrier A entirely.

**What it is.** The `CARRIER-65500` peer group was removed from `eur-b1`.

**Find it.** `show ip bgp summary` on any border, compared against any other.

**Fix.** Restore the peer group, its policy and its neighbour.

**Why it is in the lab.** Because a real incident starts with something loud,
and the skill being tested is **not letting it absorb the evening**. It is one
of twelve, it is the easiest, and the other eleven are still there when you
have fixed it. Finding fault 12 and declaring victory is the most common way a
real multi-fault incident goes wrong.

---

## Part B2 — The questions

**9, 10.** Covered under faults 1 and 2 above.

**11.** Fault 6. The packet dies at Ashburn's pod-1 spines, eight hops from the
sender, past two aggregation boundaries. In Lab 17 the same fault died three
hops away past one. **Each aggregation boundary moves the blackhole further
from whoever notices it.**

**12.** Fault 5. `table` shows it — the carriers' `/17s` column goes from 0 to
2. The other Seattle border does not leak because the filter is per-device, and
that asymmetry is what makes it findable.

**13.** Faults 7 and 8. The command is `show ip route <prefix>` on the affected
device: fault 7 shows **one BGP route** where two paths exist, fault 8 shows a
route whose **source is static, not BGP**. Same symptom in `width`, completely
different cause, and one command separates them.

**14.** Fault 10, and the mechanism is **AS-path prepend on outbound
announcements**. You observe it at the carriers. Nothing inside Ashburn can see
it because inbound traffic engineering is decided entirely by what other people
do with what you announce.

**15.** Fault 9, shown by `anycast` — a best path to the anycast prefix
containing a carrier ASN means that region is not serving itself.

**16.** Fault 11. It becomes an outage when `wst-p2-s2` is taken out, and it
takes out every rack behind `wst-p2-l2` — in this lab 4 server subnets, in a
real pod 40-odd racks.

**17. Survival, longest first.**

1. **Fault 2** — in somebody else's network, and masked by your own fault 1.
   You would discover it only by fixing fault 1 and watching something break.
2. **Fault 4** — no symptom. Latent until one specific spine reboots.
3. **Fault 11** — no symptom. Latent until one specific spine reboots.
4. **Fault 1** — no traffic change at all. It is a count nobody counts, and it
   is the most dangerous thing on the list.
5. **Fault 10** — invisible from inside your own AS. Needs an external view.
6. **Fault 9** — the service works, from the wrong continent. Latency, if
   anybody is measuring it per region.
7. **Fault 5** — a prefix count at the carrier boundary moves.
8. **Fault 8** — a halved width on one leaf, and `show ip bgp` says it is fine.
9. **Fault 3** — a halved width on one region's border pair.
10. **Fault 7** — a halved width at a super-spine, found by comparing a pair.
11. **Fault 6** — a destination is unreachable. A ticket today.
12. **Fault 12** — a session is down. Minutes.

The longest-surviving one is in **somebody else's network**, which is the
uncomfortable lesson: once you depend on carriers, part of your fault surface
is outside your reach and outside your monitoring, and the only way you see it
is by watching what *they* believe about *you*.

**18. What a Lab 16-style config audit catches before deployment.**

| Fault | What the audit asserts |
|---|---|
| 1 | every border's carrier-facing out-policy is `RM-WAN-OUT` |
| 3 | `RM-WAN-IN` is structurally identical on all six borders |
| 4 | every spine originates its pod aggregate |
| 5 | `PL-REGION-OUT` has exactly two entries on every border |
| 7 | `maximum-paths` equals the intended value everywhere |
| 8 | no fabric device has a static route |
| 9 | the anycast prefix is originated once per region |
| 10 | no `set as-path prepend` exists outside the intended set |
| 11 | session count per device matches the topology model |
| 12 | same check as 11 |

**Ten of twelve.** The two it cannot catch are **fault 2**, which is in a
network you do not configure, and **fault 6**, which is a withdrawal of
something the model may legitimately not know about unless your model also
describes server subnets.

That ratio — ten of twelve catchable before anything reaches a device — is the
argument for Lab 16's discipline, stated in the only way that is convincing:
by counting.

---

## Part C — Design at this size

**19. The region border outbound policy, as handed to whoever builds region
four.**

```
Permit, toward every carrier:
  our region aggregate        because it is what we exist to advertise
  the anycast prefix          because the service is in every region

Deny, implicitly, everything else, and specifically:
  any other region's space    announcing it makes us transit between them
  any pod aggregate           it is more specific than our /16 and would pin
                              all inbound traffic to whichever border leaked it
  any loopback                nobody outside the region needs to reach a spine
  anything learned from a carrier   that is the definition of a route leak
```

The last line is the one to put in bold in the runbook. The others are
hygiene; that one is the difference between a datacentre and an accidental
transit provider.

**20. The alarm that catches fault 1 in minutes.**

- **Polls:** `advertised-routes` count on every carrier-facing session of every
  border, every 60 seconds.
- **From:** off-box, against the eAPI on your own borders. No carrier
  cooperation needed.
- **Compares against:** the constant 2. Not a baseline, not a trend — a
  constant, because the correct number is fixed by design and changes only when
  the design changes.
- **Severity:** page. A route leak is minutes-to-matter.

**Why it cannot be built from inside your own AS alone:** that is the catch,
and it is why this question is phrased the way it is. The advertised-count
alarm *is* buildable from inside and it catches fault 1 — but it does not catch
fault 10, or a leak originating at a carrier, or your prefixes appearing with
an AS path you did not intend. For those you need an external view: RIS,
RouteViews, a looking glass, or a commercial monitoring service. **Build both.
The internal one is fast and free; the external one is the only one that sees
what the internet actually believes about you.**

**21. The failure matrix.**

| Failure | Lost | Still working |
|---|---|---|
| one border (e.g. `wst-b1`) | half Seattle's DCI capacity | both carriers reachable via `wst-b2`; all regions reachable |
| one carrier entirely | half of every region's DCI capacity | the other carrier reaches all three regions; nothing is isolated |
| one region's pair of circuits to one carrier | that region reachable via the other carrier only | everything, at reduced capacity |
| one super-spine | half the region's north-south capacity | everything |
| one spine | half a pod's capacity | everything |
| a region's **both** borders | that region isolated from the other two | the region's internal traffic; the other two regions reach each other |
| **both** carriers | all inter-region traffic | each region internally |

The two rows that should bother you are the last two, and only one of them is
addressable with money: a third carrier, or your own backbone. The other needs
border diversity you already have.

**22. Two mechanisms that would prevent region transit independently.**

1. **RFC 9234 BGP roles and the Only-To-Customer attribute.** Each session is
   declared as provider / customer / peer, and the protocol itself refuses to
   propagate a route in a way that violates the relationship. Cost: both sides
   must support and configure it, which in practice means your carriers must
   agree, and many will not yet.
2. **A no-export-style community applied to everything learned from a carrier**,
   with an outbound filter that drops anything carrying it. Cost: it is yours
   alone to maintain, it depends on the inbound tagging never being missed, and
   it is one more thing that can be deleted by the same person who deleted the
   first filter.

A third, cruder one worth naming: **a hard outbound prefix-count limit** on
every carrier session. It does not prevent the leak, it stops it at 3 prefixes
instead of 3,000, which is the difference between an incident and a catastrophe.

**23. When to stop buying carriers and build your own backbone.**

The inputs, not the answer:

- **Cost crossover.** Carrier DCI is priced per circuit per month; your own
  backbone is capex plus operations plus the staff to run it. The crossover
  moves with your traffic, and you want the comparison at projected volume 24
  months out, not today's.
- **Latency you cannot buy.** If the path you need does not exist commercially
  — a specific low-latency route, a specific landing station — you cannot
  procure it and that settles the question.
- **Control.** Fault 2 in this lab is a carrier's mistake that you can only
  escalate. On your own backbone, it is a ticket you own. Price that.
- **Diversity.** A backbone you build is one fate; two carriers are two. Most
  operators who build a backbone keep a carrier as a third path, which means
  the decision is rarely "either".
- **Capability.** A backbone needs optical engineers, an NOC, and the whole
  apparatus of Labs 13 and 14. If you do not have them, the honest answer is
  that the carrier is cheaper than hiring them.

**24. Anycast with no health check.** What breaks: the prefix is originated by
the leaf regardless of whether the service behind it is running, so a region
whose service is down still attracts all of its own users and black-holes them.
Anycast fails *towards* the broken instance, which is the worst possible
direction.

The control: **the service originates the prefix, not the leaf.** A daemon on
the server (or a route-health-injection mechanism) runs the health check and
announces `10.100.0.0/24` over BGP to the leaf only while healthy. When it
stops, the leaf withdraws, and the region falls back to the next shortest path
— another region, over a carrier, which is exactly what you want.

Speed: the health check interval plus BGP convergence across three tiers plus
the carrier's propagation. Seconds to tens of seconds, and existing TCP
connections break regardless — so this is correct for stateless services and
needs more thought for anything else.

**25. Adding Singapore, 180 ms from London.**

*Changes:* a fourth region's ASNs on the existing pattern (`654xx`), a fourth
`/16`, two borders, circuits to both carriers, and the carriers' configuration
to accept the new region.

*Does not change:* any existing region. No existing ASN, aggregate, filter or
border policy is touched.

*The one thing that would force a change to an existing region:* **the anycast
prefix.** Singapore must originate `10.100.0.0/24` too, and at 180 ms from
London the AS-path-length tie-breaking that works between Seattle, Ashburn and
London may now send some users a very long way. You would need to look at
whether AS-path length still selects sensibly, and if it does not, you are into
MED or communities with the carriers — which is Lab 14, and it is the one part
of this expansion that is not just addition.

**26. Three failure modes this lab cannot reproduce.**

1. **Carrier-side path selection.** Each carrier here is one router with one
   best path. A real carrier is a continent doing hot-potato routing, and your
   traffic's path through it changes with *their* internal topology, which you
   cannot see and they will not explain. Lab 14 models that from the customer
   side; nothing models it from inside.
2. **Convergence at real scale.** Three regions, 48 server subnets and a few
   hundred prefixes converge in seconds. At 8 pods per region and 40 regions,
   the question is whether a region failure's withdrawal storm crosses the WAN
   faster than the carriers' MRAI timers let it, and whether your borders' CPUs
   keep up. That needs scale this lab cannot reach.
3. **Partial and asymmetric circuit failure.** A DCI circuit that passes BGP
   and drops 2% of packets; one that works in one direction; one whose MTU
   changed after a carrier groomed it. These are the failures that actually
   consume a NOC's year, and containerlab's veths are perfect in both
   directions, always.
