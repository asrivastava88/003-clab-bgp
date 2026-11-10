# Lab 14 Solutions

Do not read this first.

---

## Part A — Accounting for every path

### A2. The ring

**1. `ash -> sin` is 235ms.** Two candidates: east via London, 75 + 160 = 235;
west via Seattle, 65 + 175 = 240. The eastbound path wins by 5ms, which is
close enough to be worth noticing — a single span measurement changing by 6ms
would flip the whole transatlantic-to-APAC path. Tight margins between ring
directions are normal and are a reason to set backbone costs deliberately
rather than purely from measured latency.

**2.** `sea <-> lhr` transits `ash`; `ash <-> sin` transits `lhr`.

**3. One number for three jobs.**

Advantage: everything is traceable and nothing can disagree. `set metric 160`
in a config and `160` in the OSPF cost and `160ms` on the wire are the same
fact, so reading `show ip bgp` tells you how much backbone somebody is asking
you to carry, in a unit you can defend in a meeting.

Risk: the three jobs have different requirements. OSPF cost should express
capacity and preference as well as latency — a 10G span and a 100G span of
equal length get the same cost here, which is wrong the moment one of them
fills. And MED is visible to everyone you announce to, so a MED of 235 tells
an outsider the shape and scale of your backbone. Finally, if the number is
derived from measurement, a re-measured span silently re-routes your network.
In production you set these from a design document, not from a ping.

**4. Asymmetric cost.** OSPF cost on an interface affects only traffic leaving
that interface, so raising it on one end changes the forward path and leaves
the return path alone. The result is a network where `show ip route` on two
routers tells two different stories and both are correct.

`latency` sees it, because RTT is the sum of both directions — but it cannot
tell you *which* direction is wrong, only that the total is off. To find the
direction you compare `show ip route` from both ends. This is fault 4.

### A3. Hot potato against cold potato

**5. Why one is cold and the other hot.** From `gttmed`:

- `100.150.0.0/16` arrives with MED 0 at Singapore, 160 at London, 175 at
  Seattle, 235 at Ashburn. MED is compared **before** eBGP-over-iBGP, so the
  MED 0 path wins everywhere and every PoP carries the traffic to Singapore.
  Cold potato.
- `100.200.0.0/16` arrives with MED 0 at every handoff. The MED comparison
  ties, so the decision falls through to the next step — **eBGP over iBGP** —
  and each PoP's own local session wins. Hot potato.

One prefix set, one local-pref, two completely different behaviours, decided
by whether the upstream bothered to differentiate its MED.

**6. What cold potato bought us on that flow.** `lhr` carries
`100.150.0.0/16` 160ms to Singapore. Had we hot-potatoed it — handed it to
`gtte` at London — `gttmed` says their own distance from London to their APAC
customer is also 160ms, so they would have carried exactly what we carried.

**In this lab the two backbones are identical by construction, so cold potato
buys no latency at all — only control.** That is worth sitting with, because
it is the honest version of the argument: cold potato improves the user's path
only when your backbone is genuinely better or less congested than theirs. If
it is not, you are paying for capacity to achieve nothing, and the real reason
to do it is that you want the traffic on a path you can see and fix.

**7. Total backbone we carry.**

| Destination | sea | ash | lhr | sin | total |
|---|---|---|---|---|---|
| 100.150.0.0/16 | 175 | 235 | 160 | 0 | 570 |
| 100.151.0.0/16 | 0 | 65 | 140 | 175 | 380 |
| 100.152.0.0/16 | 65 | 0 | 75 | 235 | 375 |
| 100.153.0.0/16 | 140 | 75 | 0 | 160 | 375 |
| 100.200.0.0/16 | 0 | 0 | 0 | 0 | **0** |
| 100.120.0.0/16 | 140 | 75 | 0 | 0 | 215 |
| 100.140.0.0/16 | 140 | 75 | 0 | 160 | 375 |
| | | | | | **2,290** |

What it bought: control of the path for every class except the transit-only
one, and free delivery for the CDN and the European network. The zero row is
the control — it is the only class where we told the transit "your problem".

**8. `sea` exits at `lhr` for the CDN.** Two attributes, in this order:

1. **Local preference** — 200 on the peer paths against 100 on transit. This
   eliminates the local transit exit before distance is considered at all.
2. **IGP metric to the next hop** — among the surviving peer paths, 140ms to
   London beats 175ms to Singapore.

Local-pref is step 2 of best-path and IGP metric is step 8, so the free-versus-paid
decision is made five steps before the near-versus-far one. That ordering is
the whole reason a peering policy works.

**9. The tiebreak is IGP metric to the next hop** (140 against 175). If the
two were equidistant, the next steps are the advertising peer's router ID and
then its peer address — but with `maximum-paths 2` and every attribute equal
including the IGP metric, EOS installs both and load-shares.

**10. Why the peer wins from Singapore.** Local-pref 200 against 100, compared
long before MED or any notion of distance. So Singapore hauls the traffic
160ms to London to hand it to a free peer rather than 0ms to a paid transit.

When to revisit: when the Singapore–London span's cost of carrying that
traffic exceeds the transit cost of the same bits. That is a **capacity**
trigger, not a routing one — you revisit it when you would otherwise have to
buy another 100G on that span, and the arithmetic is the span's cost per bit
against the transit's price per bit. Routing policy should not be the first
place you look.

### A4. Inbound

**11. `gtte` enters at `via-gttw` for the Americas prefix.** Its three paths
are Ashburn (MED 65, eBGP), London (MED 140, eBGP) and `gttw`'s best path
(Seattle, MED 0, iBGP). MED 0 wins, so `gtte` hauls Americas-destined traffic
across its own 70ms internal link to `gttw` and hands it to us at Seattle.

It agreed to because it honours MED, and that is the bargain: we say where we
want traffic delivered and they carry it there. They do it because it is their
product — a transit is paid to deliver bits, and delivering them where the
customer asked is the service.

**12. Both views of the EMEA prefix are correct.**

- `gttw`: Seattle MED 140 (eBGP), Singapore MED 160 (eBGP), `gtte`'s best
  (London, MED 0, iBGP). MED 0 wins → `via-gtte`.
- `gtte`: London MED 0 (eBGP), Ashburn MED 75 (eBGP), `gttw`'s best (MED 0,
  iBGP). Tie at MED 0 → **eBGP beats iBGP** → London.

Same MED table, different answers, because `gtte` has the London handoff
locally and `gttw` does not. Both end up delivering to London, which is what
the MED asked for.

**13. Three paths, not four.** `gtte` has two eBGP paths of its own (Ashburn,
London) and exactly **one** path from `gttw` over iBGP, because `gttw`
advertises only its best path. Singapore's announcement is hidden behind
`gttw`'s own best-path selection. Add-path would expose it; nothing here runs
add-path. This is the same path-hiding behaviour that makes route reflectors
interesting in Lab 04, seen from the other side of a peering.

**14. Our MED works because all four handoffs belong to one AS.** MED is
compared only between paths whose neighbouring AS is the same, so four
handoffs to AS 65100 are directly comparable and the comparison is
meaningful.

If they were four different ASes, MED would not be compared at all by default,
and the entire inbound design would have to change: AS-path prepend at the
PoPs we want de-preferred, selective announcement, or each upstream's own
steering communities. `always-compare-med` is the knob people reach for and
the wrong answer — see question 28.

**15. Detecting a PoP that stopped announcing.**

From inside: count advertised prefixes per external session and assert the
number against the intended set, which catches it in seconds; and audit each
PoP's outbound prefix-lists against the model that generated them, which
catches it before deployment.

From outside: RIS or RouteViews, or the upstream's looking glass, counting the
distinct announcements of your prefix. That is the only check that sees what
the internet actually believes, and it is the one that finds fault 8.

### A5. Anycast

**16. The entry-point counts.**

- `gttw` 2 — Seattle and Singapore, both eBGP, both MED 0, everything else
  equal, so `maximum-paths 2` installs both.
- `gtte` 2 — Ashburn and London, same reasoning.
- `cdn` 2 — London and Singapore, its two PNIs.
- `peereu` 1 — it has one peering session with us (London). Its other path is
  via the transit, AS path length 2 against 1, so it loses on AS-path length.

**17. Why equal MED is right for anycast.** Equal MED gives the upstream no
reason to prefer one of our entry points, so the decision falls to its own
internal metric — which is distance from the **source**. Every source
therefore enters at the handoff nearest itself, which is the entire purpose of
anycast. For anycast, the upstream hot-potatoing is the correct behaviour, and
our job is to get out of its way.

**18. If we applied the unicast MED scheme to anycast**, every source on earth
would enter at the single MED-0 PoP and the other three would receive nothing.
The users hurt are everyone far from it: APAC users would be dragged up to
235ms across our backbone to reach a service that exists 0ms away in
Singapore. Anycast would have degraded into unicast with three idle PoPs and a
much larger backbone bill.

**19. `198.18.1.0/24` is scoped with `no-export`.** It restricts advertisement
to **eBGP** peers outside the local AS. It does **not** restrict iBGP
propagation, which is why both transit routers hold it — `gttw` learned it
from us and passed it to `gtte` over iBGP perfectly legitimately. What it
stops is `gtte` advertising it onward to `peereu`, which is an eBGP peer.

It is announced from Singapore only because the service exists only in
Singapore. Announcing it from four PoPs would create four entry points for a
service with one location: `no-export` would still keep it inside the transit,
but the transit would then haul traffic across the planet to reach a box in
Singapore. Scope is two decisions, not one — **where you announce it** and
**how far it may travel.**

---

## Part B — The eight faults

### Fault 1 — Singapore announces the EMEA prefix with MED 0

**Symptom.** Nothing in our routing tables. In `inbound`, `gttw` changes from
`via-gtte` to `sin` for `203.0.113.0/24`. The transit's western region now
hands us all its Europe-destined traffic in **Singapore**, and we carry it
160ms to London.

**Why.** We told it to. `gttw`'s paths become Singapore (MED 0, eBGP),
Seattle (MED 140), `gtte`'s best (London, MED 0, iBGP). The MED tie at 0 is
broken by eBGP-over-iBGP, so the local Singapore handoff wins.

**Find it.**
```
gttw# show ip bgp 203.0.113.0/24                                 <- sin path, MED 0
sin#  show ip bgp neighbors 10.100.2.2 advertised-routes          <- EMEA at metric 0
sin#  show running-config section route-map RM-GTT-OUT
```
Compare against `./lab.sh med`, which says the value should be 160. Then
compare Singapore's clause 30 against the other three PoPs' — it is the only
one whose EMEA MED equals its APAC MED, which is the shape of a copy-paste.

**Fix.** `route-map RM-GTT-OUT permit 30` / `set metric 160`

**Cost.** 160ms of our backbone for every byte of EU-destined inbound from
the transit's western region, and a worse path for those users, who now enter
in Singapore to reach a service in London.

**Production.** Nothing alerts, because nothing in our AS changed. The control
is to generate MEDs from the topology model rather than typing them — which
is what `tools/gen_configs.py` does and what a fat-fingered hand edit
defeats — plus a periodic check that the announced MED matrix matches the
model, read from `advertised-routes` on every external session.

---

### Fault 2 — Ashburn forces the CDN over paid transit

**Symptom.** In `potato`, the CDN row collapses: all four PoPs exit at `ash`.
London and Singapore stop using the free PNIs in their own buildings.

**Why.** A clause was added to Ashburn's transit inbound map setting
local-preference **250** for the CDN prefix. Local-pref is step 2 of
best-path, so 250 beats the PNI's 200 everywhere, and because local-pref
propagates over iBGP the whole network follows Ashburn.

**Find it.**
```
lhr# show ip bgp 100.120.0.0/16            <- ash iBGP path at LP 250, local eBGP at 200
ash# show running-config section route-map RM-GTT-IN
```
Ashburn has a `permit 7` clause the other three PoPs do not. Any clause whose
local-pref is not one of the three designed numbers (200, 200, 100) is a
finding on sight.

**Fix.** `no route-map RM-GTT-IN permit 7`

**It masks fault 5.** While 250 is live, nothing London does to its own PNI
policy can change the outcome.

**Production.** Nothing alerts; every destination stays reachable and every
session stays up. You find it on the transit invoice, or with a config audit
asserting that the set of local-pref values in use is exactly the designed
set. The second is cheap and should be in CI.

---

### Fault 3 — the scoped prefix loses its `no-export`

**Symptom.** Nothing moved. In `inbound`, `198.18.1.0/24` changes from
`absent` to present at `peereu`. A prefix we deliberately scoped to the
transit's own customers is now in the wider table.

**Find it.**
```
peereu# show ip bgp 198.18.1.0/24                 <- path 65100 65010
gtte#   show ip bgp 198.18.1.0/24 detail          <- no communities
sin#    show running-config section route-map RM-GTT-OUT
```
Clause 50 has lost its `set community no-export additive`.

**Fix.** `route-map RM-GTT-OUT permit 50` / `set community no-export additive`

**Why `no-export` never stopped it inside the transit's AS.** It restricts
eBGP advertisement outside the local AS. `gttw -> gtte` is iBGP inside AS
65100, so both transit routers holding the prefix is correct and expected;
that is not the leak. The leak is `gtte -> peereu`, which is eBGP, and which
`no-export` was the only thing preventing.

**Production.** Alert on the **set of prefixes visible outside your intended
scope**, which in practice means an RIS or RouteViews check that a scoped
prefix is not in the global table. There is no way to see this from inside
your own AS, and there is also a belt-and-braces control: an outbound filter
on every session that explicitly excludes scoped prefixes, so a lost community
is not the only thing standing between you and the DFZ.

---

### Fault 4 — the transatlantic span's OSPF cost

**Symptom.** Nothing in `potato`, nothing in `inbound`. In `latency`,
`ash -> lhr` goes from 75ms to roughly **400ms**, and `sea -> lhr` from 140ms
to roughly 335ms. `verify` reports
`ash next hop to lhr loopback: 10.254.0.0, expected 10.254.0.3`.

**Why.** Ashburn's Ethernet3 cost went from 75 to 500, so the direct
transatlantic span (500) loses to the long way round: ash → sea → sin → lhr,
65 + 175 + 160 = **400**. Traffic from Ashburn to London now crosses the
Pacific.

**The asymmetry is the confusing part.** OSPF cost is per interface and
therefore per direction. London's cost toward Ashburn is untouched at 75, so
**the return path is still the direct span.** `show ip route 10.255.0.3` on
`ash` and `show ip route 10.255.0.2` on `lhr` disagree, and both are correct.
Any analysis that assumes a symmetric path will produce nonsense here.

**Find it.**
```
ash# show ip ospf interface Ethernet3 | include Cost         <- 500
ash# show ip route 10.255.0.3                                <- via sea
lhr# show ip route 10.255.0.2                                <- direct, unchanged
ash# show ip ospf database | include 10.254.0.2
```
Then compare every backbone interface cost against `./lab.sh dist`.

**Fix.** `interface Ethernet3` / `ip ospf cost 75`

**Production.** This one does show up — on any latency graph, instantly, which
is why latency probes between PoPs are the single highest-value backbone
monitoring you can build. The config control is an audit asserting each
interface's OSPF cost against the topology model.

---

### Fault 5 — London de-prefers its own PNI

**Symptom, once fault 2 is fixed.** In `potato`, London exits at `sin` for the
CDN, carrying 160ms, instead of exiting at London for 0ms. It reaches a peer
in its own building by crossing a continent and an ocean.

**Why.** London's PNI inbound local-pref is **90** instead of 200. Its own
eBGP path at 90 loses to Singapore's iBGP path at 200 — and also to its own
transit path at 100, except that 200 beats both.

**Find it.**
```
lhr# show ip bgp 100.120.0.0/16
```
Three paths, three local-prefs: the local eBGP path at 90, Singapore's at 200,
and (while fault 2 is live) Ashburn's at 250. That one command is the whole
diagnosis and also the discriminator against fault 2.
```
lhr# show running-config section route-map RM-PNI-IN
sin# show running-config section route-map RM-PNI-IN         <- the control
```

**Fix.** `route-map RM-PNI-IN permit 10` / `set local-preference 200`

**Production.** Same control as fault 2: assert the set of local-pref values
against the designed set, per session class, in CI. Operationally, alert on a
PNI carrying zero traffic — a free interconnect that is up and idle is either
a mistake or a cancellation waiting to happen.

---

### Fault 6 — London announces the anycast prefix with a MED

**Symptom.** Every reachability check passes. `anycast` shows `gtte` with
**one** entry point instead of two, and the survivor is Ashburn. **London
receives no anycast traffic at all**, from anywhere.

**Why.** London announces `192.0.2.0/24` with MED 100 instead of 0. `gtte`'s
paths become Ashburn (MED 0, eBGP), London (MED 100, eBGP) and `gttw`'s best
(MED 0, iBGP). MED 0 wins, and among the MED 0 paths eBGP beats iBGP, so
Ashburn takes all of it. European users now cross the Atlantic to reach a
service that exists in London.

`gttw` is unaffected — its two handoffs are Seattle and Singapore, both still
MED 0 — which is why only half the picture changes.

**Find it.**
```
gtte# show ip route 192.0.2.0/24                      <- one next hop
gtte# show ip bgp 192.0.2.0/24                        <- lhr at MED 100
lhr#  show running-config section route-map RM-GTT-OUT
```
Clause 10 should be `set metric 0` and is the one clause in the whole lab
where a non-zero MED is wrong.

**Fix.** `route-map RM-GTT-OUT permit 10` / `set metric 0`

**Production.** Nothing alerts, and this is the fault I would most expect to
survive. A region silently receiving no anycast traffic looks exactly like a
quiet region. Two controls: per-PoP ingress traffic counters for the anycast
prefix, alerting on a PoP dropping to zero; and an external check — a probe
network per region resolving and connecting, confirming which PoP answers.
The second is the only one that catches it from the user's point of view.

---

### Fault 7 — Seattle de-prefers its own transit

**Symptom.** In `potato`, Seattle exits at `ash` for `100.200.0.0/16` — the
hot-potato class, which every PoP is supposed to handle locally — and also for
`100.151.0.0/16`, the eyeballs sitting directly behind its own handoff.

**Why.** Seattle's transit inbound local-pref is **50** instead of 100. Its
own eBGP paths at 50 lose to the other three PoPs' iBGP paths at 100, and
among those the IGP metric picks Ashburn at 65ms.

The second row is the sharper one: `100.151.0.0/16` arrives at Seattle with
MED 0, meaning the transit is telling us those users are right there. We now
carry that traffic 65ms east to hand it back to the same AS.

**Find it.**
```
sea# show ip bgp 100.200.0.0/16             <- local eBGP at LP 50, iBGP at 100
sea# show ip bgp 100.151.0.0/16             <- same shape, and MED 0 locally
sea# show running-config section route-map RM-GTT-IN
ash# show running-config section route-map RM-GTT-IN        <- the control
```

**Fix.** `route-map RM-GTT-IN permit 10` / `set local-preference 100`

**Production.** Nothing alerts. Everything is reachable and nothing is down.
The signature worth monitoring is a border session whose **egress** traffic
has gone to near zero while the session is Established and holds a full set of
routes — a transit handoff that is up, populated, and unused.

---

### Fault 8 — Ashburn stops announcing the Americas prefix

**Symptom.** Nothing, anywhere, today. `verify` reports
`gtte paths to 198.51.100.0/24: 2, expected 3`. `inbound` is unchanged,
because `gtte` was already choosing `via-gttw` on MED 0 and still is.

**Why.** A `deny` was inserted at sequence 5 of `PL-AMER` on Ashburn, so the
prefix now matches nothing in any outbound map and is announced to nobody from
that PoP.

**Why it matters anyway.** We have lost our nearest **backup** entry point for
Americas traffic. Today Seattle takes it all on MED 0. If Seattle's handoff
fails, inbound Americas traffic should fall back to Ashburn at MED 65 — a
65ms backbone haul. Instead it will fall back to London at MED 140 or
Singapore at MED 175. The fault converts a cheap failure into an expensive
one, and it will be discovered during the failure, which is the worst possible
time to discover anything.

**Find it.**
```
gtte# show ip bgp 198.51.100.0/24                              <- 2 paths
ash#  show ip bgp neighbors 10.100.3.2 advertised-routes       <- AMER missing
ash#  show ip prefix-list PL-AMER                              <- a deny at seq 5
sea#  show ip prefix-list PL-AMER                              <- the control
```

**Fix.** `no ip prefix-list PL-AMER seq 5`

**Production.** This is the fault that needs an **external** check: the count
of distinct announcements of each of your prefixes, from RIS, RouteViews or
your upstream's looking glass, asserted against the number of PoPs that should
be announcing it. From inside, the buildable version is an advertised-prefix
count per external session asserted against the intended set — which works,
and is the control I would actually deploy, because it needs no third party.

---

## Part B2 — The questions

**20. Survival time, longest first.**

1. **Fault 8** — latent. Nothing is wrong until a failure, and the only direct
   evidence is a path count on a device we do not operate. Years.
2. **Fault 1** — invisible in our own tables. Costs us 160ms of backbone and
   gives European users a worse path, and nothing in our AS changed.
3. **Fault 6** — a whole region receives no anycast traffic while every
   reachability check passes. Looks like a quiet region.
4. **Fault 3** — a scoped prefix in the global table. Nobody notices until
   somebody uses it, and then it is a capacity surprise.
5. **Fault 7** — a transit handoff that is up, populated and unused. Found by
   someone reviewing interface counters, which is not a daily activity.
6. **Fault 5** — a free PNI idle in its own building. Found on the invoice or
   by the same counter review.
7. **Fault 2** — free peering abandoned network-wide for paid transit. The
   invoice moves enough to be noticed within a billing cycle.
8. **Fault 4** — 400ms to London. A user complains today.

The pattern is the same one every lab in this series has arrived at from a
different direction: **what survives is what did not change state.** Session
up, adjacency full, prefix present, ping answered. Everything a conventional
NMS watches is a transition, and none of these eight is one.

**21. Four faults are one wrong number in one route-map clause:**

| Fault | Device | Attribute | Wrong value | Should be |
|---|---|---|---|---|
| 1 | sin | MED | 0 | 160 |
| 5 | lhr | local-pref | 90 | 200 |
| 6 | lhr | MED | 100 | 0 |
| 7 | sea | local-pref | 50 | 100 |

They produce four different symptoms because the two attributes act at
different points and in different directions. **Local-pref is ours alone and
acts outbound** — it decides which exit we use, it never leaves our AS, and it
propagates over iBGP so one PoP's value can override three others' (faults 5
and 7, with 7 hitting the hot-potato class and 5 the peering class). **MED is
a request to somebody else and acts inbound** — it decides where they hand us
traffic, it is only comparable within one neighbouring AS, and its effect is
invisible in our own routing table (faults 1 and 6, with 1 moving a unicast
entry point and 6 removing an anycast one).

The other four are not of that class: **fault 2** is an added clause,
**fault 3** a removed `set`, **fault 4** an interface OSPF cost, and
**fault 8** a prefix-list entry.

**22.** Faults 2 and 5 both hit `potato` at `lhr:100.120.0.0/16`. The single
command that separates them is `show ip bgp 100.120.0.0/16` on `lhr`, which
shows all three local-pref values at once: 250 from Ashburn, 90 locally, 200
from Singapore. **Fix 2 first** — while the 250 is live, nothing about
London's own policy can change the outcome, so fixing 5 first looks like it
did nothing.

**23.** Fault 6, and `./lab.sh anycast` is the only tool that shows it. What it
shows is a **count**: entry points at `gtte` dropping from 2 to 1. No
reachability check can see this, because the service is still reachable — from
the wrong continent.

**24.** Fault 3. `peereu` can now see `198.18.1.0/24`, and so can anything
beyond it. The mechanism, `no-export`, restricts advertisement to eBGP peers
outside the local AS and says nothing about iBGP, so both transit routers
holding the prefix was always correct and was never the leak.

**25.**

- **Fault 1 moves work off the transit's backbone onto ours.** They stop
  carrying Europe-destined traffic from their western region to London and
  hand it to us in Singapore instead. We pay in **backbone milliseconds** —
  160 of them per flow — and European users pay in **latency**.
- **Fault 2 moves work off a free interconnect onto a paid one.** The CDN's
  traffic leaves the PNIs and rides transit. We pay in **money**, and also in
  backbone, since everything now routes via Ashburn.

I would escalate **fault 2** first, on two grounds: it is the one with a
recurring cash cost rather than a capacity cost, and it is network-wide rather
than regional. Fault 1 is arguably the more interesting engineering error, but
the one that shows up on a bill gets fixed.

**26.** Fault 8. We lose our nearest backup inbound path for the Americas
prefix, converting a 65ms failover into a 140ms or 175ms one. With no access
to the transit's routers, the monitor you can actually build from inside is an
**advertised-prefix count per external session**, asserted against the
intended set for that PoP — it catches the fault at the point where it
happened rather than at the point where it is visible. The complete version
adds an external looking-glass or RIS check on the number of distinct
announcements, which is the only thing that sees what the internet believes.

---

## Part C — Design

### C1. Potato policy

**27. When to accept a transit's MED and when to strip it.**

The rule: **accept it when your backbone is the product; strip it when the
other network's backbone is the product.** A content network accepts MED and
does cold potato, because the user's experience is what it sells and a path it
controls is a path it can fix. A transit or eyeball network strips MED and
does hot potato, because it is not paid to haul other people's bits.

Two exceptions:

1. **Strip it on any span that is near capacity, whatever the policy says.**
   Routing policy is not a capacity plan. If the Singapore–London span is at
   80%, you stop volunteering to fill it and you do that before the next
   quarterly review, not after.
2. **Accept it even as a transit when cold potato is a product you sell.** Some
   providers sell exactly this — "we will carry it to the destination region" —
   and then honouring MED is the deliverable rather than a favour.

**28. `always-compare-med`.** By default MED is compared only between paths
whose neighbouring AS is the same, because the values are set by different
organisations with no coordination and comparing AS X's 100 against AS Y's 50
is meaningless. `always-compare-med` removes that restriction.

The famous failure is **MED oscillation**. MED is non-transitive, so with it
enabled best-path selection becomes dependent on the order in which paths are
evaluated, and two routers with identical information can reach different
conclusions. In an iBGP mesh with route reflectors that produces persistent
route churn — the network never settles. `deterministic-med` exists as a
partial mitigation by forcing a consistent evaluation order, and it is a
mitigation rather than a fix.

Most large networks leave it off for a second reason as well: it hands
outsiders influence over path selection between your *unrelated* peers. A
neighbour who sets an aggressive MED can pull traffic away from a peering they
have nothing to do with.

**29. As a transit, the policy inverts.** You are paid per bit delivered, not
to haul.

- **Eyeball customer:** hot potato. Their outbound traffic goes out your
  nearest exit. They are buying reachability, not your backbone, and hauling
  their traffic across your network is unpaid work.
- **Content customer:** cold potato is a **product**. They want their bits on
  your backbone as far as possible because your backbone is better than the
  alternative, and you can charge for it. So you honour their MED and you put
  it in the contract.

The general rule that covers both directions: **whoever's backbone is the
product should carry the traffic.**

**30. From milliseconds to the real question.** `potato`'s 2,290ms is a proxy
for path length, and a capacity planner does not care about path length. The
question they ask is: **how many gigabits per second, at the 95th percentile,
on each span, against that span's capacity and its cost per bit?**

The data needed and absent here: per-span utilisation time series, and
per-prefix traffic volume from flow data (NetFlow, IPFIX or sFlow) joined to
the BGP table, so that a span's load can be attributed to the routing decision
that put it there. Without that join you can see that a span is full and you
cannot see which policy filled it.

### C2. Inbound traffic engineering

**31. Inbound steering tools, most to least reliable.**

1. **Selective announcement** — do not announce it there at all. Nobody can
   override it, because there is nothing to override. Blunt: you lose that
   entry point entirely, including as a backup, which is fault 8 done on
   purpose.
2. **More-specific announcement** — longest-prefix match beats every attribute
   in every network on earth. Reliable to the point of being a weapon. Costs:
   it pollutes the global table, it may be filtered by anyone with a /24
   boundary, and it is the mechanism of prefix hijacking, so it attracts
   attention.
3. **Upstream steering communities** — reliable when documented, and
   surprisingly fine-grained: "prepend twice to AS X", "do not announce to
   region Y". Costs: specific to that upstream, undocumented changes break you
   silently, and it is per-provider work to maintain.
4. **AS-path prepend** — widely honoured, and blunt in a specific way: one
   prepend often moves nothing and two often move everything, because you are
   competing against path lengths you cannot see.
5. **MED** — the most expressive and the least reliable. Only comparable
   within one neighbouring AS, and only if that AS honours it.

**32. A peer ignores your MED. Three options.**

1. **AS-path prepend** on the handoffs you want de-preferred. Cost: it affects
   everyone downstream of that peer, not just the peer, so you are steering a
   much larger population than you meant to.
2. **Selective announcement** — stop announcing at the handoffs you do not
   want used. Cost: you lose those handoffs as backup entry points, and you
   will not notice until you need them.
3. **Their communities**, if they publish any. Cost: per-provider
   documentation to read and maintain, and no recourse when they change it.

The fourth, unglamorous option: **ask them.** A peer ignoring MED is sometimes
a default they would change for a customer, and a conversation is cheaper than
any of the above.

**33. 70/30 between London and Ashburn from one transit.** The honest answer
first: **MED cannot do it.** MED is a strict tiebreak, not a weight. A MED
difference moves 100% of the traffic for a prefix, not 70%.

To approximate it you de-aggregate: announce two more-specifics covering
roughly 70% and 30% of the destination address space, prefer one at London and
the other at Ashburn. The result will not be 70/30, for two reasons that are
both outside your control: **traffic is not uniformly distributed across your
address space**, so the 70% of addresses may carry 40% or 95% of the bits; and
the split is ultimately determined by **where the sources are**, not by what
you announce. You can measure and iterate, and you will be adjusting it
forever.

The better question is usually whether you need 70/30 at all, or whether you
need "not all of it in one place", which selective announcement does cleanly.

**34. Knowing where the internet actually enters, without asking anyone.**

Three layers, in order of how much they lie:

1. **Per-interface ingress counters on every external session.** Ground truth,
   cheap, and the only part that cannot lie. This alone answers the question at
   PoP granularity.
2. **Flow data at every border** (IPFIX or sFlow), with the ingress interface
   recorded, aggregated by source AS and destination prefix. This turns "how
   much" into "whose, and for what", which is what you need to act.
3. **External views** — RIS, RouteViews, upstream looking glasses — to confirm
   what the world is being told, which is the input to the other two.

The common mistake is to build only the third and reason about the first.

### C3. Anycast

**35. Three failure modes prefix announcement alone cannot address.**

1. **The service is down and the router is up.** BGP has no idea. Needs a
   health check that conditionally originates or withdraws the prefix — the
   service speaking BGP itself, or a daemon that withdraws on failed checks.
2. **The PoP is reachable but overloaded.** BGP has no load signal at all and
   never will. Needs either capacity-aware withdrawal (withdraw before you
   collapse, which means deciding a threshold) or a steering layer above BGP.
3. **The client's path to the nearest PoP is bad for reasons outside your
   network** — a congested peer two ASes away. The nearest PoP in AS-path
   terms is not the fastest. BGP anycast cannot express "this source should go
   somewhere else", so this needs DNS steering or application-level redirect.

**36. The withdrawal path, end to end.**

Health check fails → the announcing process stops originating → iBGP withdraw
propagates across your AS → eBGP withdraw to every transit and peer → their
best-path recomputation → their own iBGP propagation → onward to their peers →
the DFZ converges.

The worst case is dominated by two things you do not control: each neighbour's
**MRAI** (minimum route advertisement interval, commonly 30 seconds for eBGP)
and their internal propagation. Add your own health-check detection interval
at the front. Realistically **tens of seconds to a couple of minutes**, and
the long tail is longer than people expect.

The part that matters more than the number: **existing TCP connections to that
PoP break**, withdrawal or not. Anycast failover is not graceful for anything
stateful, which is why anycast is used for DNS and for connection-oriented
services that can tolerate a reconnect, and why "anycast gives us instant
failover" is only true for the next connection.

**37. Anycast, DNS steering, or both.**

| | anycast | DNS steering |
|---|---|---|
| convergence | BGP time: seconds to a couple of minutes | TTL time, plus resolver caches that ignore TTLs |
| granularity | none — you get what the DFZ decides | per-resolver, with weights |
| client correctness | correct for every client, because it is the network | wrong whenever the resolver is not near the client |
| operational risk | high — a mistake is global and immediate | lower — reversible, gradual, testable |

**Both** is the production answer, and the division of labour is the point:
anycast for the fast, automatic failure path, DNS for deliberate steering and
for the decisions that need to be weighted or regional.

**38. One anycast PoP with poor transit, in increasing order of what you give
up.**

1. **Fix the transit** — buy better, or peer more at that PoP. Costs money,
   gives up nothing, and is the right answer more often than engineers like.
2. **Reduce what lands there** — prepend or announce a less attractive path at
   that PoP so some traffic goes elsewhere. Gives up part of the PoP's
   purpose, and is imprecise for the reasons in question 33.
3. **Stop announcing the anycast prefix there** and serve that region from the
   next PoP. Gives up the PoP for that service entirely, and you are now
   paying for a facility that does not serve the thing you built it for.

### C4. What this lab cannot show

**39. Three TE failure modes it cannot reproduce.**

1. **MED oscillation and route churn.** The failure in question 28 needs many
   routers, real update timing, MRAI, and a route-reflector hierarchy. Eight
   containers converge in seconds and stay converged; the pathology is an
   emergent timing property of a large mesh.
2. **Congestion-driven traffic engineering.** The entire reason cold potato is
   a hard decision is that spans fill up, and the right answer changes with
   utilisation. There is no traffic here, no queues, and no ASIC buffers, so
   every decision in this lab is made on topology alone — which is precisely
   the simplification that makes real TE hard.
3. **The DFZ itself.** Where your prefixes are actually entered from is decided
   by thousands of networks with their own policies, their own MED handling and
   their own filters. No lab has an internet. This is why questions 15, 26 and
   34 all end up at the same place: an external view you do not control is a
   mandatory part of the monitoring, not an optional one.

**40. Forty nodes instead of four.** What changes qualitatively:

- **iBGP full mesh stops being possible.** 40 nodes is 780 sessions. You move
  to route reflectors or confederations, and you inherit path hiding — the
  reflector advertises one best path, so PoPs stop seeing alternatives they
  could have used. That is Lab 04's problem arriving in this one, and it
  changes `potato`'s answers.
- **The all-pairs matrix stops being readable.** 40×40 is not a table a human
  diffs. `dist`, `med`, `gttmed` and `potato` all stop being useful as printed
  matrices and have to become a **continuously evaluated model with deviation
  alerts** — the same conclusion Lab 12 reached about ECMP width and Lab 13
  about circuit diversity.
- **MED-equals-IGP-cost needs automation or it decays.** Nobody hand-maintains
  200 MED values. The generator in `tools/` stops being a lab convenience and
  becomes the only way the network is correct.
- **Hot and cold potato stop being one policy.** At four PoPs you can have one
  rule. At forty you have regions, each with its own transit mix, its own
  capacity constraints and its own answer, and the interesting bugs are at the
  boundaries between them.

What stays useful: the idea that MED is milliseconds, and the habit of
diffing the current state against an intended model rather than reading
routing tables and hoping.
