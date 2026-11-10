# Lab 13 Solutions

Do not read this first.

---

## Part A — Reading the plant

### A2. The diversity audit

**1. The six shared-fate pairs, and what takes both.**

| Pair | Shares | One event that takes both |
|---|---|---|
| TRANSIT-1A + TRANSIT-1B | `CDT-4TH-AVE`, `WESTIN-MMR-A` | a backhoe in the 4th Avenue duct, or a Westin meet-me-room event |
| WAVE-SEA-ASH-A + B | `CDT-ASHB-E` | a cut in the east duct into the Ashburn building |
| IX-PORT-A + B | `IX-FABRIC-SEA` | the exchange fabric itself — a loop, a maintenance, a bad linecard |
| CLOUD-IC-A + B | `WESTIN-MMR-A`, `CLOUD-PE-SEA01` | the cloud provider's single edge router, or its line card |
| PNI-CDN-A + B | `WESTIN-MMR-A` | a Westin meet-me-room event |
| DF-SEA-001 + WAVE-SEA-ASH-A | `CDT-4TH-AVE` | the 4th Avenue duct |

The pattern worth naming: four of the six share a **facility**, not a route.
Diversity engineering concentrates on the long middle of a circuit, and the
middle is almost never what fails.

**2. Was the carrier lying about TRANSIT-1A/1B?** Probably not, and that is
the lesson. We asked for diverse *access* and got it: two handoffs at two of
our sites, on two of our ports. The carrier made no claim about the route
between its own edge and our second site, because we never asked — the TUKW
handoff is backhauled to the same Westin MMR over the same 4th Avenue duct.

"Diverse" without a stated scope means "two circuit IDs". The scope has to be
in the order: diverse *path*, diverse *entrance facility*, diverse *meet-me
room*, diverse *carrier POP*. Each one costs more and each one has to be named.

**3. WAVE-A and WAVE-B share `CDT-ASHB-E`.** This is **last-mile collapse**,
sometimes called tail diversity failure, and it is almost always found at the
building entrance — the conduit from the street into the building, and the
manhole it passes through. Buying from two carriers does not fix it because
both carriers lease the same entrance facility from the building owner, or
pull through the same duct bank, because there is only one. 4,000 km of
genuine route diversity ends in a single duct, and the circuit is as diverse
as its least diverse metre.

**4. `IX-FABRIC-SEA` is irreducible with ports.** Two ports, two line cards,
two meet-me rooms — still one layer-2 fabric with one set of operators and one
maintenance window. What removes it:

- a **second exchange** in the same metro, which is a second port fee, a second
  set of peering sessions, and a second set of peers to negotiate with
- **PNIs** with the peers that matter, which removes them from the exchange's
  fate entirely and is why large networks migrate volume off exchanges onto
  PNIs as it grows
- accepting it and sizing **transit** to absorb the IX volume, which is the
  cheapest answer and the one that shows up on the invoice the day it happens

The honest architecture answer: an exchange is a single point of failure you
accept deliberately in exchange for cheap bits and many peers, and the control
is making sure transit can take the load.

**5. The ticket to the cloud provider.** One sentence:

> Please confirm whether circuits CLOUD-IC-A and CLOUD-IC-B terminate on
> separate provider edge devices in separate facilities, and if not, provide
> the path to a configuration where they do.

What you are asking them to prove is **device and facility diversity at their
end**, which is the half of the pair you cannot see and cannot test. The answer
is often that a single peering location means a single device pair, and that
true diversity requires a second peering location in a different metro — which
is a design change and a cost, not a ticket.

**6. Widest blast radius.** `CDT-4TH-AVE` and `WESTIN-MMR-A`, seven circuits
each. `CDT-4TH-AVE` takes DF-SEA-001, TRANSIT-1A, TRANSIT-1B, IX-PORT-A,
PNI-CDN-B, CLOUD-IC-A and WAVE-SEA-ASH-A (the last survives on 1+1).

What is left: `sea2` keeps IX-PORT-B, PNI-CDN-A is gone but PNI-CDN-B rides
4th Avenue too, CLOUD-IC-B survives, TRANSIT-2 survives, and WAVE-SEA-ASH-B
survives. So Ashburn stays up, `sea2` keeps the exchange and the cloud, and
**all primary transit is gone** — the entire network is behind a 10G
transpacific circuit at $1.10/Mbps with 95ms of latency. Everything is
reachable and nothing is usable. That is the answer that matters.

### A3. Cutting a cable

**7.** `WAVE-SEA-ASH-B` drops. `WAVE-SEA-ASH-A` survives on its 1+1 protection
switch. **Zero BGP sessions change state** on the surviving path, because a
1+1 switch completes in under 50ms and both BFD and the BGP hold timer are an
order of magnitude longer than that. `verify` before and after is identical
except for whatever rode the B wave.

**8.** The step is **65ms to 78ms**, the `rtt_ms` to `protect_rtt_ms` delta in
the inventory. It is the only evidence because a protection switch happens
below layer 3: no interface changes state, no adjacency drops, no route is
withdrawn, no prefix count moves. The protect path is physically longer — it
has to be, or it would not be diverse — so the latency step is unavoidable and
is therefore the signal.

**9. The monitoring rule.**

- **Where:** off-box, from a prober at each site, not from the routers.
- **What:** continuous RTT to a fixed endpoint across each named circuit,
  recorded per circuit ID, with the inventory's `rtt_ms` as the expected value.
- **Threshold:** alert on a **sustained step** — median RTT shifting more than
  5ms from the circuit's established baseline and holding for 60 seconds. Not a
  fixed ceiling, because the baseline differs per circuit, and not a
  percentile spike, because that is jitter.
- **Severity:** ticket, not page. A protected circuit on its protect path is
  working; what it has lost is its protection, so the clock that matters is
  the carrier's repair SLA, not your incident response.

The reason this rule is worth building: a 1+1 circuit on its protect path is
**unprotected**, and the next cut is an outage. Many networks discover they
have been running unprotected for months when the second cut happens.

**10. Cutting `CDT-4TH-AVE`.** See question 6. The prediction that catches
people out is that `sea1` survives as a router — its loopback stays reachable
via Ashburn — while losing every external circuit except the IX port, which is
also in the group. Inbound traffic arrives through `sea2` over TRANSIT-2 and
IX-PORT-B. Ashburn is reachable over WAVE-SEA-ASH-B, unprotected, with
everything riding one 10G transpacific transit.

### A4. Where the bits go

**11. TRANSIT-2 carrying nothing is correct.** `transit1` advertises
`100.101.0.0/16` with `65200` prepended, so we see it at local-pref 100 with
AS path `65100 65200`; `transit2` advertises it directly at local-pref 90 with
AS path `65200`. Local-pref is compared first, so the longer path through the
cheaper transit wins — and that is the intent, because $0.38/Mbps beats
$1.10/Mbps and 0.2ms beats 95ms. A backup circuit carrying nothing is a backup
circuit working. The thing to do is prove it would carry traffic if asked,
which means a scheduled drain of transit1, not a hope.

**12.** Fixed MRC is $35,050 and usage at the clean baseline is $722, so
roughly **98% of the bill is fixed**. The implication is the opposite of most
people's instinct: tuning policy to shave transit saves very little here,
because the design has already pushed nearly everything onto flat-rate
circuits. The savings are in the **circuit portfolio** — a non-diverse pair you
are paying twice for, a $9,800 wave carrying nothing, a $1,900 backhauled PNI
that duplicates a $350 cross connect. The cheapest circuit is the one you
cancel.

**13. Why `le 24`.** It bounds the length of what a peer can announce inside
its own space. With `le 32` a peer could announce 65,536 /32s out of a /16 and
blow through our `maximum-routes`, or de-aggregate to steer our traffic in
ways we did not agree to. With no bound at all they could also announce a
**more specific of somebody else's space inside their own block**, which is
the fault-1 scenario. /24 is the conventional bound because it is the longest
prefix generally accepted in the DFZ; the real rule is that the bound belongs
in the filter rather than in a trust assumption.

**14. What the route server is sending that we reject.**

- `100.110.0.0/16` — accepted. This is `ixpeer1`'s registered space.
- `100.120.0.0/18` — rejected by `PL-IRR-AS65401`. A more specific of the
  **CDN's** /17, announced by a peer with no authority over it, relayed by the
  route server. This is the one that deserves an email, to the exchange and to
  the CDN.
- `192.0.2.0/24` — rejected by the `deny 5` clause. **One of our own prefixes**,
  coming back at us from a peer. That is either a hijack or a leak of our
  space, and it is also why the `deny 5` clause exists: no legitimate peer has
  any reason to tell you about your own address space.

Received 3, accepted 1. The gap between those two numbers is your filter doing
its job, and it is worth alerting on when it changes.

**15. Route-server transparency.**

(a) **AS-path length.** A transparent route server does not insert itself, so
`100.110.0.0/16` through the exchange would be AS path `65401` — one hop,
against `65100 65401` through transit. In this lab it is `65300 65401`, the
same length as transit, so the comparison is decided entirely by local-pref.
With a real route server the IX path would also win on path length, which
means your policy still works if somebody fat-fingers local-pref. The
transparent version is more robust, not just tidier.

(b) **Inbound filters that match on the neighbouring AS.** They break. With a
transparent route server the first AS in the path is the *peer's*, not the
route server's, so a filter asserting "the leftmost AS must equal the
configured remote-as" rejects everything. This is a real and common
misconfiguration, and it is why route-server sessions need prefix filters
built from IRR or RPKI rather than AS-adjacency assumptions.

### A5. Internal paths

**16 and 17. The OSPF arithmetic.**

| Path | Cost | 
|---|---|
| sea1 → ash1, direct over WAVE-A | 100 |
| sea1 → sea2, direct over the dark fibre | 10 |
| sea2 → ash1, direct over WAVE-B | 120 |
| sea2 → ash1, via sea1 | 10 + 100 = **110** |

So `sea2` reaches Ashburn **through sea1**, over the dark fibre and then the
**1+1 protected** wave, rather than over its own unprotected one. The design
intent is that internal traffic rides the protected circuit, and that the
unprotected wave is a standby that costs $9,800/mo and carries nothing until
the protected one is gone.

What quietly undoes it: **lowering the cost on sea2's Ethernet6 to anything
below 110.** One interface, one number, no alarm. That is fault 6.

---

## Part B — The eight faults

### Fault 1 — sea1's route-server inbound filter lost its IRR match

**Symptom.** `exits` shows `CDN (low half)` leaving `sea1` via `ix` instead of
`pni`, while `CDN (high half)` still goes via `pni`. Half the CDN's space, one
site. `verify` also shows `sea1 prefixes accepted from the route server: 2,
expected 1`, and the ping to `100.120.0.1` fails.

**Why half.** The route server relays `100.120.0.0/18`, which covers
`100.120.0.0`–`100.120.63.255`. The CDN announces `100.120.0.0/17`. Longest
prefix match takes the /18 for everything inside it and leaves the rest on the
/17. **Local-pref never enters it** — the /18 at local-pref 200 beats the /17 at
local-pref 300 not because 200 is better but because the routing table matches
the longer prefix first. Policy cannot defend you from a more specific; only a
filter can.

**Find it.**
```
sea1# show ip route 100.120.0.1                               <- via 10.200.0.1
sea1# show ip bgp 100.120.0.0/18                              <- path 65300 65401
sea1# show ip bgp neighbors 10.200.0.1 received-routes         <- 3 prefixes
sea1# show ip bgp neighbors 10.200.0.1 routes                  <- 2 accepted, should be 1
sea1# show running-config section route-map RM-IXRS-IN
```
Compare the last one against `sea2`, which still has its match clause.

**Fix.**
```
route-map RM-IXRS-IN permit 10
   match ip address prefix-list PL-IRR-AS65401
```

**Production.** Nothing alerts on a prefix count going up by one. Alert on the
**ratio** instead: accepted-against-received per neighbour, and any change in
accepted count on a session whose IRR-derived filter did not change that day.
The deeper control is RPKI route origin validation, which would have marked
`100.120.0.0/18` from AS 65401 as invalid regardless of our prefix list.

---

### Fault 2 — sea2 leaks the full table to the exchange

**Symptom.** Nothing. `exits`, `cost`, `latency` and every routing table on
our network are unchanged, because this fault is purely outbound.

**What it actually is.** `sea2` now advertises everything it knows to the
route server: our three prefixes plus everything learned from transit1,
transit2, the PNI and the cloud — roughly sixteen prefixes instead of three.
Every network at that exchange now believes AS 65010 is a transit path to the
rest of the internet, and some of them will use it. This is the classic IX
route leak, it is the most career-damaging mistake in peering, and it is
measured in minutes before somebody notices.

**Find it.**
```
sea2# show ip bgp neighbors 10.200.0.1 advertised-routes      <- 16, should be 3
sea1# show ip bgp neighbors 10.200.0.1 advertised-routes      <- 3, the control
sea2# show running-config section bgp | include IXRS route-map
```
And from a peer's side, which is what they will quote at you:
```
ixpeer1# show ip bgp 100.100.0.0/16                           <- path 65300 65010 65100
```
That AS path, with us in the middle between the exchange and a transit, is the
whole finding.

**Fix.**
```
router bgp 65010
   neighbor IXRS route-map RM-OUR-SPACE-OUT out
no route-map RM-LEAK
```

**Production.** This is the one fault here that has a universally agreed
control: a **hard outbound prefix count limit and an outbound filter on every
external session**, plus an alert on advertised-prefix count per neighbour.
Three prefixes going to sixteen is a page, not a ticket. MANRS action 1 is
exactly this. The belt-and-braces version is also tagging everything learned
externally with a no-export-to-peers community and filtering on it, so a
missing prefix list is not the only thing standing between you and this.

---

### Fault 3 — sea2 pins the cloud pair to one circuit

**Symptom.** `exits` shows `sea1`'s cloud exit as `internal` rather than
`cloud`. Both sites, and Ashburn, now reach the cloud through `sea2`.
`CLOUD-IC-A` is up, Established, and carrying nothing.

**Why.** `sea2` sets local-pref 500 on its cloud routes. `sea1` has its own
eBGP path at 400 and `sea2`'s iBGP path at 500. **Local-pref is compared before
eBGP-over-iBGP**, so the remote path wins and `sea1` hairpins its cloud traffic
across the metro dark fibre.

**Why it matters more than it looks.** The pair stops being a pair. Both sites
depend on one circuit, which lands on one provider edge device
(`CLOUD-PE-SEA01` — see question 5), and `CLOUD-IC-B` failing now moves 100% of
cloud traffic instead of 50%. You are paying $1,650/mo for an idle circuit and
holding the risk of a single one.

**Find it.**
```
sea1# show ip route 100.130.0.0/16                   <- via 10.255.0.2
sea1# show ip bgp 100.130.0.0/16                     <- two paths, LP 400 and 500
sea1# show interfaces Ethernet4 | include packets    <- the idle circuit
sea2# show running-config section route-map RM-CLOUD-IN
```

**Fix.** `route-map RM-CLOUD-IN permit 10` / `set local-preference 400`

**Production.** Nothing alerts. Catch it with a config audit asserting the
local-pref table is identical on both edges — the five numbers in the README
are the intent, and intent belongs in CI. The operational catch is a per-circuit
utilisation alert for **zero** traffic on a circuit that should be carrying
half of something.

---

### Fault 4 — the bilateral IX peer loses to transit

**Symptom.** `exits` shows `IX peer bilateral` on `transit` at both sites.
`cost` reports **+$912/mo** of avoidable transit. The ping to `100.111.0.1`
fails, because `transit1` blackholes third-party space in this lab.

**Note on why it is on both sites.** Local-pref 80 on one site alone would not
do it: the other site would still have the prefix at 200 and would heal it over
iBGP, leaving only a hairpin. Both sites have to be wrong for the traffic to
reach transit, which is realistically how a templating error presents.

**Find it.**
```
sea1# show ip route 100.111.0.0/16            <- via 10.100.1.2, transit
sea1# show ip bgp 100.111.0.0/16              <- IX path at LP 80, transit at LP 100
sea1# show running-config section route-map RM-IXBILAT-IN
```
Compare local-pref against the other inbound maps on the same router. 80 is
the only value in the config that is not one of the five designed numbers.

**Fix.** `route-map RM-IXBILAT-IN permit 10` / `set local-preference 200`, on
both `sea1` and `sea2`.

**Production.** In a real network this is pure cost and nothing more: the
destination stays reachable through transit, so there is no outage, no alert
and no complaint. You find it with the `cost` discipline — periodically
reconcile where traffic exits against where policy says it should — or you find
it on the invoice a month later.

---

### Fault 5 — the PNI filter rejects everything the CDN sends

**Symptom.** Both PNI sessions Established, **zero prefixes accepted**. `exits`
shows both halves of the CDN space on `transit`. `cost` reports **+$3,344/mo**,
the largest single money fault in the lab. Pings to both CDN addresses fail.

**Why.** The filter was narrowed from `100.120.0.0/16 le 24` to
`100.120.0.0/16`. The CDN announces two /17s and no /16, so the filter now
matches nothing at all. A session that is up and has sent you nothing is the
signature, and it is easy to miss because `show ip bgp summary` shows it
Established with a prefix count of 0, which looks like a quiet peer.

**Find it.**
```
sea1# show ip bgp summary | include 10.150.1.2                 <- Estab, 0 prefixes
sea1# show ip bgp neighbors 10.150.1.2 received-routes         <- 2 prefixes arrived
sea1# show ip bgp neighbors 10.150.1.2 routes                  <- 0 kept
sea1# show ip prefix-list PL-IRR-AS65500
```
Received 2, accepted 0 — the gap localises it to inbound policy in one step.

**Fix.**
```
no ip prefix-list PL-IRR-AS65500
ip prefix-list PL-IRR-AS65500 seq 10 permit 100.120.0.0/16 le 24
```
on both routers.

**Production.** Alert on **accepted prefix count of zero on an Established
external session**. It is a two-line check, it has almost no false positives,
and it catches both this and the far more common version — a peer who stopped
announcing. This is the single highest-value alert in the whole lab.

---

### Fault 6 — the unprotected Ashburn wave becomes attractive

**Symptom.** Nothing in `exits` or `cost`. `verify` shows
`sea2 next hop to ash1 loopback: 10.254.0.5, expected 10.254.0.0`. Internal
Seattle-to-Ashburn traffic from `sea2` now rides the **unprotected** wave
instead of going through `sea1` and over the protected one.

**Why.** Ethernet6's OSPF cost went from 120 to 10, so direct (10) beats via
sea1 (110). See question 17 — this is the single number that undoes the design.

**Why it matters.** You have not lost anything today. What you have lost is
the protection: a cut on `LH-SOUTHERN-I80` is now an outage for that traffic
rather than a non-event, and the $14,500/mo protected circuit you bought for
exactly this is sitting idle. It also compounds with fault 7, which puts half
your **inbound** Ashburn traffic on `sea2`, so both directions end up on the
unprotected circuit.

**Find it.**
```
sea2# show ip route 10.255.0.3
sea2# show ip ospf interface Ethernet6 | include Cost
sea2# show ip ospf neighbor                           <- 2, adjacencies are fine
```
That last command is the discriminator against fault 8.

**Fix.** `interface Ethernet6` / `ip ospf cost 120`

**Production.** Nothing alerts, and no routing protocol thinks anything is
wrong. The control is a config audit that asserts interface OSPF costs against
the intended topology model — the same model that generated these configs —
plus a per-circuit utilisation check that notices a protected circuit going
quiet.

---

### Fault 7 — sea2 stopped de-preferring itself for inbound traffic

**Symptom.** Nothing on any of our routers. `verify` shows
`transit1 next hops to 203.0.113.0/24: 2, expected 1`, and the same for
`198.51.100.0/24`.

**Why.** `sea2`'s outbound map toward transit1 no longer prepends, so transit1
sees AS path `65010` from both of our handoffs instead of `65010` from `sea1`
and `65010 65010 65010` from `sea2`. Equal length, equal everything, and
transit1 has `maximum-paths 4 ecmp 4`, so it installs **both** and splits
inbound traffic across them.

**Why it matters.** Half our inbound Ashburn traffic now arrives at `sea2`,
which is the wrong site for it: it then crosses the metro dark fibre and the
Ashburn wave, or — with fault 6 live — rides the unprotected wave directly.
Inbound traffic engineering is the half of BGP policy you cannot see from your
own routers, and this is the fault that teaches it.

**Find it.**
```
transit1# show ip route 203.0.113.0/24                        <- two next hops
transit1# show ip bgp 203.0.113.0/24                          <- two paths, both "65010"
sea2#     show ip bgp neighbors 10.100.2.2 advertised-routes  <- no prepend visible
sea1#     show ip bgp neighbors 10.100.1.2 advertised-routes  <- the control
sea2#     show running-config section bgp | include TRANSIT1 route-map
```

**Fix.**
```
router bgp 65010
   neighbor TRANSIT1 route-map RM-TRANSIT1-OUT out
```

**Production.** You cannot see this from inside your own AS, which is the
point. The controls are a looking-glass or RIS/RouteViews check that your
prefixes carry the AS paths you intended from the outside, plus an inbound
traffic-share alert per circuit. Both are things networks build only after
being surprised once.

---

### Fault 8 — the metro dark fibre is passive in OSPF

**Symptom.** `verify` shows `sea1 OSPF full adjacencies: 1, expected 2` and
`sea2 OSPF full adjacencies: 1, expected 2`, and
`sea1 next hop to sea2 loopback: 10.254.0.3, expected 10.254.0.1`. `latency`
shows `sea1 -> sea2` at roughly **136ms instead of 0.4ms**.

**Why.** `passive-interface Ethernet5` stops OSPF hellos, the adjacency drops,
and sea1's only remaining path to sea2 is via Ashburn: 100 + 120 = 220.
Seattle-to-Seattle traffic crosses the continent twice. A $2,800/mo dark fibre
carries nothing while two long-haul waves carry metro traffic.

**It masks fault 6.** With the sea1–sea2 adjacency gone, `sea2`'s "via sea1"
path to Ashburn does not exist, so `sea2` goes direct over the unprotected
wave whether or not the cost is wrong. The next hop is `10.254.0.5` either way.

**The discriminator:**

| Command on sea2 | fault 6 | fault 8 |
|---|---|---|
| `show ip ospf neighbor` | 2 adjacencies | 1 adjacency |
| `show ip ospf interface Ethernet6 \| include Cost` | 10 | 120 |

So: **fix fault 8 first**, then re-check the internal paths. Fixing them in
the other order makes it look as though fixing fault 6 did nothing.

**Find it.**
```
sea1# show ip ospf neighbor
sea1# show ip ospf interface Ethernet5                 <- passive
sea1# show ip route 10.255.0.2
sea1# ping 10.255.0.2                                  <- 136ms across the street
```
Note that the interface is up, the link is up, and the subnet is still
advertised into OSPF as a stub — only the adjacency is gone.

**Fix.** `router ospf 1` / `no passive-interface Ethernet5`

**Production.** This one does alert, if you watch OSPF adjacency count rather
than only interface state and BGP. Many networks do not. The latency probe
from question 9 catches it too, and more usefully: 0.4ms to 136ms between two
buildings in one city is unmissable on a graph and invisible in a routing
table.

---

## Part B2 — The questions

**18. Survival time, longest first.**

1. **Fault 7** (missing prepend) — invisible from inside the AS entirely. Needs
   an external looking glass or an inbound traffic-share analysis. Years.
2. **Fault 6** (OSPF cost) — no alarm, no reachability change, and the only
   cost is protection you are not currently using. Until the next cut.
3. **Fault 3** (cloud pinning) — everything works; one circuit is idle. Until
   somebody reviews circuit utilisation, or until CLOUD-IC-B fails and takes
   everything instead of half.
4. **Fault 4** (bilateral local-pref) — in production, pure cost. Survives
   until an invoice review.
5. **Fault 8** (passive interface) — loud on an OSPF adjacency count and on any
   latency graph, silent everywhere else.
6. **Fault 5** (PNI filter) — pure cost in production, and the largest. Found
   by a zero-prefix alert if you have one, by the invoice if you do not.
7. **Fault 1** (IRR match) — a quarter of a destination's traffic goes to a
   network that drops it, so somebody complains.
8. **Fault 2** (outbound leak) — minutes. Other people's monitoring finds it
   and they telephone you.

The pattern: **the faults that survive are the ones where nothing changed
state and nobody else is affected.** Faults that hurt other networks get fixed
fast, because other networks have their own monitoring.

**19.** Avoidable transit totals **$4,256/mo, $51,072/yr** — $3,344 from fault 5
and $912 from fault 4. Fault 1 moves traffic but costs nothing extra, and
faults 3, 6, 7 and 8 cost nothing at all.

If I could fix one, I would fix **fault 2**, on risk, and the criterion is
blast radius outside my own network. Fault 5 is four times the money and
costs me only money; fault 2 is a route leak that damages other people's
traffic, is visible to every network at the exchange, and puts the peering
relationships the whole cost model depends on at risk. The most expensive
fault and the most dangerous one are rarely the same fault, and cost is the
easier argument to make to a CFO precisely because it is the smaller risk.

**20.** Fault 2. On our own router:
`show ip bgp neighbors 10.200.0.1 advertised-routes` on `sea2` — sixteen
prefixes where there should be three. On a peer:
`show ip bgp 100.100.0.0/16` on `ixpeer1`, which shows AS path
`65300 65010 65100` — us, in the middle, between the exchange and somebody
else's transit. That path is what a peer screenshots when they call.

**21.** Faults 6 and 8 both put `sea2`'s route to Ashburn on `10.254.0.5`. The
command that separates them is `show ip ospf neighbor` on `sea2` — one
adjacency means fault 8 removed the sea1 path, two adjacencies means the path
exists and fault 6 made the direct route cheaper. **Fix 8 first**, because
while it is live fault 6 produces no observable difference at all.

**22.** A deliberate version is a **more-specific hijack** (sometimes
sub-prefix hijack), and it is the most effective kind because it does not
compete with the legitimate announcement — it outranks it. Here it captures
`100.120.0.0/18`, which is **half of the CDN's lower /17 and a quarter of its
/16-equivalent space**.

Longest-prefix match makes the local-pref hierarchy irrelevant because
local-pref only decides between paths **to the same prefix**. The /18 and the
/17 are different prefixes, so they are different routing table entries, and
forwarding picks the longest match before any BGP attribute is consulted. This
is the single most important thing to understand about prefix filtering: your
policy cannot out-prefer a more specific, so the filter is the only control
you have.

---

## Part C — Design, economics and the physical layer

### C1. Diversity you can prove

**23. The clause.** Scope the diversity and name the artefact:

> Circuits A and B shall be physically diverse end to end, with no shared
> conduit, duct bank, building entrance facility, meet-me room, manhole,
> bridge or tunnel crossing, or carrier POP. Supplier shall provide GIS route
> data (KMZ) for both circuits at delivery and on request thereafter, and
> shall notify within 30 days of any change of route, including changes
> arising from maintenance, relocation, or corporate reorganisation. Where
> diversity is found to be breached, supplier shall reroute at its own cost or
> the affected circuit may be terminated without penalty.

The artefact is the **KMZ**, re-validated annually and after every carrier
acquisition. The remedy matters as much as the requirement: without a stated
consequence, "we will look into it" is the whole response.

**24. Three ways diversity dies without you touching anything.**

1. **Carrier consolidation.** Two carriers merge and groom your two circuits
   onto one route to save cost. Detect it by re-requesting KMZs annually, and
   by tracking the carriers in your inventory against merger news — which is
   not a joke, it is a real control.
2. **Maintenance and relocation.** A duct is relocated for road works, or a
   damaged span is repaired along a new path. The circuit ID does not change.
   Detect it with the contractual notification clause, and independently with
   a latency baseline — a rerouted circuit almost always changes its RTT.
3. **Grooming.** The carrier moves your wave onto a different line system or a
   different route for its own capacity reasons, within its rights under most
   contracts. Same detection: latency step, no routing event. This is the same
   signal as a protection switch, which is why you need the inventory to tell
   them apart.

**25. KMZ analysis.** Load both routes in GIS, buffer each by about 50 metres
to account for survey error, and intersect. Every intersection is a candidate
shared-risk group. Then inspect, in order of how often they actually fail:

1. the **building entrance facility** and the conduit from the street
2. the **meet-me room**, which is one room however many cabinets it has
3. **bridge, railway and river crossings**, where everyone in the region shares
   the one structure
4. the **manhole** immediately outside each building
5. **long-haul segments following the same right of way** — the same interstate,
   the same railway, the same pipeline easement

Then ask the question GIS cannot answer: **do the two routes share a power
feed, an amplifier hut, or an operations team with one maintenance window?**

### C2. DWDM and the physical layer

**26. 400G over 280 km of your own dark fibre.**

At 0.2 dB/km that is **56 dB of fibre loss**, plus connectors and splices, so
it is not a single span under any circumstances. Split it into three or four
spans of 70–95 km, which means **two or three intermediate amplifier sites** —
and finding huts with power and access on that route is usually the hard part
of the project, not the optics.

A bare **400ZR pluggable is not enough**: it is specified for roughly 80–120 km
of point-to-point unamplified reach and has neither the OSNR margin nor the
FEC for a four-span amplified line. The realistic options are **OpenZR+** with
its stronger FEC and higher launch budget if the span plan is kind, or a
proper line system with EDFAs plus a transponder running **DP-QPSK** rather
than 16QAM — trading spectral efficiency for the OSNR you do not have.

The OSNR concern is cumulative amplifier noise: each EDFA contributes roughly
its noise figure, so three or four of them stack up and the budget is tight
enough that the answer depends on the actual fibre's loss and PMD, measured,
not assumed. The honest engineering answer is that you cannot design this from
a datasheet — you need an OTDR trace and a span-by-span loss budget first.

**27. Alien wavelengths.** You put your own transponder on somebody else's
line system, usually to get a newer generation of optics than the line-system
owner offers, or to avoid buying their transponder at their margin.

The owner will warrant the **line**: span loss, amplifier behaviour, the
spectrum slot they sold you. They will not warrant **your signal** — not the
OSNR you achieve, not the reach, not the FEC margin, and not interoperability
with their management. If the wave does not come up, the failure is yours to
prove.

So what you must be able to do yourself is the full optical budget: span
losses, amplifier noise accumulation, OSNR at the receiver with margin, and
the spectral width your carrier occupies against the slot you were sold. You
also need your own optical monitoring, because theirs will not see your
channel in any useful way.

**28. 96 × 50 GHz against flexgrid at 75 GHz.** For **400G**, the fixed 50 GHz
grid is usually workable with higher-order modulation, and 96 channels of 400G
is nominally 38.4 Tbps. For **800G**, 50 GHz is not enough spectrum for the
baud rate, so the service either does not fit or has to be split.

Flexgrid at 75 GHz gives about 64 carriers in the same C-band — fewer channels,
but each one can carry 800G at a lower-order, longer-reach modulation, for
roughly 51 Tbps. The trade is **flexibility and total capacity against channel
count and operational simplicity**: flexgrid needs a line system and a planning
tool that understand variable slot widths, it makes spectral defragmentation a
real operational problem you did not previously have, and it is harder to
hand a customer "a wavelength" as a product.

**29. "Protected" wave — the three questions.**

1. **Protected against what, where?** Line protection (1+1 OLP within one
   line system) protects against a fibre cut on the protected segment. Card or
   client protection protects against equipment. They are not the same product
   and are often conflated in a quote.
2. **What is the protect path's route, and is it diverse from the working
   path's — and from my other circuits?** A protect path sharing a conduit with
   the working path protects against equipment and nothing else. A protect path
   sharing a conduit with your *other* circuit is worse: your protection and
   your diversity collapse together.
3. **What is the switch time, and is the protection revertive?** Sub-50ms keeps
   it below BGP and BFD. Anything slower is a routing event you need to design
   for. Revertive protection means a second event when the fault clears, at a
   time nobody is watching.

And the follow-up that catches most people: **how will I know I am on the
protect path?** If the answer is "the carrier will tell you", build the latency
probe from question 9.

### C3. Subsea

**30. Ranking the three Tokyo offers.** Best to worst:

1. **One pair each on two cables at different CLSs.** Different wet plant,
   different landing stations, different beach manholes, different terrestrial
   backhaul. A cut, an anchor, a CLS power event or a backhaul failure takes
   one, not both.
2. **One pair each on two cables at the same CLS.** Diverse wet plant, which
   covers the most common failure (an anchor or a trawler in shallow water on
   one cable's route). But the CLS, its power, its beach manhole and usually
   its terrestrial backhaul are shared — and backhaul from a remote landing
   station to a metro is itself often single-routed.
3. **Two pairs on one cable.** Almost worthless as diversity. One cut takes
   both pairs, and a cut is the dominant failure mode. It protects only against
   a single-pair fault or SLTE equipment failure, which are the rare cases.

The general principle: **rank by what actually fails.** For subsea that is
shallow-water damage from anchors and fishing gear, then shore-end and
backhaul, then wet-plant equipment, and only then a single fibre pair.

**31. 9,100 km.** The refractive index of silica at 1550nm is about 1.468, so
the group velocity is 299,792 ÷ 1.468 ≈ **204,200 km/s**, which is 4.9 µs per
kilometre.

- one way: 9,100 × 4.9 µs ≈ **44.6 ms**
- round trip: ≈ **89.2 ms**

The inventory says 95 ms, about 6 ms more. That is accounted for by the SLTE
and transponder DSP at both ends (coherent FEC and framing cost real
microseconds), the terrestrial backhaul from the landing station at Mukilteo
to Seattle and from the Japanese landing to Otemachi, and the router hops at
each end. Six milliseconds of overhead on a transpacific path is unremarkable;
the thing to notice is that **89 ms of it is physics and no amount of money
changes it.**

**32. Subsea cut, realistic timeline.**

Repair is **one to several weeks**, and the three drivers are:

1. **Cable ship availability.** There are few of them, they are shared under
   regional maintenance agreements, and one may already be on another fault.
2. **Permits and weather.** Territorial waters need clearance; a winter North
   Pacific sea state stops work outright.
3. **Fault location and depth.** Locating from both ends, grappling, lifting
   to the surface, splicing and testing. Deep water is slower and shallow
   water is often busier with traffic that caused the fault.

What the network should have done in the **first second**: withdrawn the routes
and converged onto the remaining paths, with BFD or a hold timer sized to the
circuit so it happens without a human. In this lab, BGP on `TRANSIT-2` goes
down and `sea2` falls back to transit1.

What a human decides in the **first hour**: whether to buy emergency restoration
capacity — IP transit, a temporary wave, or a restoration clause already in the
contract — at what will be a bad price, for a duration measured in weeks. That
decision is why the contract should have pre-agreed restoration terms, because
negotiating them during an outage is the worst possible time.

### C4. Peering economics

**33. IX port break-even.** $1,200/mo buys 3,158 Mbps of transit at
$0.38/Mbps. If the port peers away 40% of your traffic, the port pays for
itself when 40% of your traffic is 3,158 Mbps — so at about **7,900 Mbps of
total traffic**, call it 8 Gbps.

Three costs just ignored:

- the **cross connect** to the exchange fabric, plus the port on your own
  router and the optic in it
- **transit commit structure.** You usually cannot shed 40% of your traffic
  off a transit bill, because you are on a committed rate. Peering below your
  commit saves nothing at all until the commit is renegotiated, which is the
  single most commonly missed fact in these calculations.
- **engineering and operational time**: peering negotiation, session setup,
  IRR and RPKI maintenance, and being paged for an exchange you now depend on

A fourth, less obvious: the 40% figure is itself a guess until you have the
port and can measure it. PeeringDB and your own flow data get you an estimate;
the real number arrives after you have committed.

**34. Ratio 4:1 against a 2:1 requirement. Three strategies.**

1. **Pay for it.** Paid peering or partial transit from them. Costs money,
   works immediately, and gives you a direct path with no negotiation about
   ratio. Trade-off: you have monetised a relationship you wanted for free,
   and the price only falls if your leverage grows.
2. **Change the ratio.** Move traffic onto the path deliberately — host
   something they pull from, or shift outbound traffic to other exits so the
   ratio on *their* interface improves. Trade-off: this is engineering your
   network to satisfy somebody else's policy, and it is slow and fragile.
3. **Make the ratio irrelevant.** Peer at more locations so the value to them
   is geographic rather than volumetric, or wait until your traffic is large
   enough that the cost of *not* peering with you exceeds their policy. Trade-off:
   both take time, and the second one is just "grow".

The honest fourth option: **accept transit for that destination** and revisit
annually. Ratio requirements exist to extract payment from networks that need
the peering more than the peer does, and sometimes the correct answer is to
pay the transit bill and stop negotiating.

**35. Route server against bilateral.**

**Route server:** one session reaches the long tail of an exchange, which is
N sessions' worth of value for one session's worth of config. It is how small
and mid-size networks get most of their peering benefit, and it is the only
practical way to reach the hundred networks at an exchange who will never
answer your peering request.

**Bilateral:** per-peer policy — different local-pref, different communities,
different filters, and the ability to drain one peer without touching the
others. Required by any peer with a selective policy. Independent of the
route server's own availability and configuration.

What you lose by being **route-server only**: per-peer policy and per-peer
troubleshooting (one session's state tells you nothing about one peer); the
route server as a single point of failure for all your peering at that
exchange; dependence on the exchange's own filtering quality, which fault 1 in
this lab is exactly about; and you never establish the direct relationship
that becomes a PNI later. The usual answer is both — route server for the
tail, bilateral for the peers that carry volume.

**36. Transit, IX port, PNI as traffic to one network grows.**

| Traffic | Cheapest | What you would actually do |
|---|---|---|
| 100 Mbps | transit ($38/mo) | nothing. Not worth a conversation. |
| 500 Mbps | transit ($190/mo) | nothing, but start measuring. |
| ~3.2 Gbps | **crossover: transit = IX port** | you are probably already at the exchange for other peers, so peer here for free. |
| 3–10 Gbps | IX port (flat $1,200) | peer at the exchange. Watch the port's utilisation. |
| ~10 Gbps+ | **crossover: PNI** ($350 cross connect) | move to a PNI: cheaper than the port's share, removes the exchange from the failure domain, and gives you a dedicated 100G. |

The crossover points are where the arithmetic says, but the real decisions are
made earlier and for other reasons: you join an exchange for the aggregate of
many peers, not for one; and you move a peer to a PNI when their traffic
starts to be a meaningful fraction of your IX port, because at that point the
port becomes a congestion risk rather than a cost question.

### C5. Cloud interconnect

**37. Two circuits, one provider edge device.** In order of cost:

1. **Ask**, and get it in writing. Sometimes a second device is available at
   the same peering location for the asking, and the pair was simply
   provisioned onto one. Free.
2. **Reprovision** one circuit to a different device or different MMR at the
   same location. A provisioning change and a cross-connect fee.
3. **Second peering location in the same metro.** Removes the facility as well
   as the device. Another circuit, another cross connect, another port.
4. **Second region or second peering metro.** Removes the metro. Doubles the
   circuit cost and adds latency to one path, and is the only option that
   survives a metro-level event.
5. **A second cloud provider**, which is a different conversation entirely.

Where I would stop: **step 3** for anything that matters, and step 2 for
anything that does not. Step 4 is justified only when the workload genuinely
cannot tolerate a metro-level outage, and most cannot justify the second
region's cost once somebody prices it honestly. The decision belongs to
whoever owns the application's availability target, not to the network team —
and getting that written down is the actual deliverable.

**38. Advertising a default or your transit routes to a cloud provider.**
Look at the local-pref table: cloud sits at **400**, the top. Everything we
learn from the cloud outranks everything else, which is correct for reaching
cloud prefixes and catastrophic if the scope of what we exchange widens.

Advertising a **default** to them tells the cloud provider that we are a path
to the entire internet. Their traffic for arbitrary destinations arrives on a
10G interconnect sized for our own cloud traffic, congests it instantly, and
we pay transit to carry it. Advertising **our transit routes** is the same leak
with a longer prefix list and is harder to spot.

For them it is a route leak from a private peering, which is why providers
filter it — but filtering is theirs to get right and the failure is ours to
cause. For us it is a congested interconnect, a transit bill for somebody
else's traffic, and a provider relationship that now includes a conversation
about why we advertised a default. The control is the same as fault 2's: an
outbound prefix list of our own space, and nothing else, on every external
session without exception.

**39. 1500 on the interconnect, 9100 on the backbone.**

What breaks: nothing at the handoff itself, because the interconnect's own
interfaces agree at 1500. What breaks is **anything that assumes end-to-end
9100** — a host on our side with a 9000-byte MTU sending to a cloud host,
where the 1500 link is in the middle. If path MTU discovery works, TCP adapts
and you lose a little throughput. If ICMP fragmentation-needed is filtered
anywhere, which is extremely common, you get a **PMTUD black hole**: the TCP
handshake completes, small packets work, and the first full-size data packet
vanishes. The classic symptom is "the connection opens and then hangs", which
people debug as an application problem for days.

Fixes, by layer:

- **Host:** set the MTU to 1500 on interfaces whose traffic crosses the
  interconnect, or use per-route MTU. The only fix that always works.
- **TCP:** MSS clamping on the edge router for traffic toward the
  interconnect, so the endpoints negotiate a segment size that fits regardless
  of PMTUD.
- **Network:** permit ICMP type 3 code 4 everywhere, which you should do
  anyway and which will still not save you from somebody else's firewall.
- **Design:** do not run a 9100 MTU domain that includes a 1500 exit without
  clamping. Pick the MTU at the boundary deliberately rather than inheriting
  it.

### C6. What this lab cannot show

**40. Three failure modes it cannot reproduce.**

1. **Anything optical.** OSNR degradation as an amplifier ages, a dirty
   connector adding 3 dB, PMD on old fibre limiting a 400G wave, spectral
   defragmentation on a flexgrid line system. All of it needs real optics,
   real spans and a real line system. A veth has no OSNR, and netem has no
   concept of a bit error rate rising slowly over a month — which is the way
   these faults actually present.
2. **Partial and grey failures on a carrier circuit.** A wave with 1e-5 errors
   after FEC, a carrier Ethernet circuit policing above its CIR, a subsea
   segment losing 0.5% of packets, a circuit that fails only above a certain
   frame size. netem can inject loss and delay, but what it cannot reproduce
   is the interaction with real FEC, real hardware counters and real carrier
   diagnostics — and locating a grey failure in somebody else's network, with
   their NOC on the phone, is the actual skill.
3. **The commercial and organisational failure modes**, which are the ones that
   caused most of the diversity problems in this lab. A carrier merger
   grooming your circuits onto one route; a provisioning team filling in
   "diverse: yes" because the field was required; a KMZ that does not match
   the ground; a protect path quietly regroomed. These need an inventory, a
   contract, and a carrier — this lab reproduces the *consequence* through
   `srlg` and `cut`, and nothing reproduces the cause.

What all three share: the hardest problems in this domain are **not in the
routers**. The control plane in this lab is a few hundred lines of
configuration, and `inventory/circuits.yml` is where every finding in Part A
actually came from. That is the proportion in the real job, too.
