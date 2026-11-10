# Lab 16 Solutions

Do not read this first.

---

## Part A — What generation buys you

**1. `10.3.0.2`.** Region 3, router 2 — London, the route-reflector client. The
rule is `10.{R}.0.{N}/32`: the second octet is the region id, the fourth is the
router id. No lookup, no spreadsheet, no IPAM call. That is the entire value
proposition of an algorithmic scheme, and you just used it.

**2. Where the loopback rule runs out.** The second octet gives 254 usable
regions and the fourth gives 254 routers per region, so about 64,000 devices —
which sounds like plenty and is not the limit that bites.

The first thing that actually breaks is the **third octet, which is wasted**.
It is always `0`, so `10.{R}.0.0/24` is reserved per region for 254 loopbacks
and 253 addresses in it are unusable for anything else. At scale you want
`10.{R}.{pod}.{N}` with the third octet carrying a pod or site index, and the
moment you need that, every loopback in the region renumbers.

The real answer to this question is therefore: **the rule breaks the first time
the organisation grows a dimension the rule has no field for** — a second site
within a region, a second plane, a separate out-of-band loopback. Leave fields
spare in the rule before you need them, because adding one later is a
renumber.

**3. Why link ids are stable, and the one edit that is not.** Ids are assigned
by position in `model/network.yml`, so **appending** a link gets the next id
and nothing already allocated moves. Adding a region appends.

The operation that renumbers half the network is **inserting or deleting a link
in the middle of the list**. Delete link 3 and every link after it shifts down
by one, which renumbers nine P2P subnets and the external handoffs with them —
a network-wide outage produced by a tidy-up.

Two ways out, both worth knowing: never delete, only mark `decommissioned:
true` and skip it in the renderer; or make the id explicit in the model rather
than positional, so it is allocated once and recorded. Real systems do the
second, and the audit in this lab would then also be able to catch an id that
was reused.

**4. `est-r1` has `Ethernet3` to `wst-r1`.** Its backbone neighbours are
`est-r2`, `eur-r1`, `wst-r1`. Sorted by the far end's name that is
`est-r2` → Ethernet1, `eur-r1` → Ethernet2, `wst-r1` → Ethernet3.

For `wst-r1` to become `Ethernet2`, `eur-r1` would have to sort after it — so
either the rule changes (sort by region id, or by link id, or by RTT), or the
device is renamed. Renaming a device to change its cabling is an absurd thing
to do, which is the point: **under a rule, the interface assignment is a
consequence, not a choice**, and you cannot quietly "just move it to a free
port".

**5. Cost as a measurement.**

*Advantage:* the IGP agrees with physics automatically. Latency-sensitive
traffic takes the lowest-latency path with nobody maintaining a table, and when
a carrier regrooms a circuit the number that should change is obviously the one
that changed.

*Risk:* **capacity is invisible.** A 10G span and a 400G span of equal length
get the same cost, and the IGP will happily fill the small one. Cost should
encode preference, and preference is a function of latency *and* capacity *and*
money. The honest production answer is a cost derived from a formula that
includes all three, with the formula in the model — which is a Part C-shaped
answer to a Part A question, and the right one.

A second risk: if the number comes from a probe, a re-measurement reroutes your
network without a human deciding to.

### A2. What the model does not say

**6. Topology and policy are different files because they have different
change rates and different authors.** Topology changes when you build —
quarterly, with a project and a budget. Policy changes when you negotiate — a
new peer, a changed local-pref, a filter — which can be weekly and is done by a
different team. Splitting them means a peering change does not touch the file
that describes circuits, which keeps review scope small and blast radius
smaller.

**7. `render` and `remediate` are two commands on purpose.** Rendering is
**safe, offline and reversible**: it writes files, touches no device, and a bad
render is discovered by reading a diff. Remediating is **none of those things**.

Putting them in one command would mean every model edit is a deploy, which
removes the only moment at which a human can look at what the model now says
and decide whether they believe it. The gap between the two commands is where
triage lives, and this lab's two model drifts exist to prove it needs to be
there.

**8. Why `show` and `show running-config` differ even with no drift.** Three
reasons:

1. **EOS normalises.** It reorders statements into its own canonical order,
   expands abbreviations and re-renders values its own way.
2. **Defaults are elided or added.** A value equal to the platform default may
   not appear at all; conversely EOS inserts defaults the rendered file never
   mentioned.
3. **The device has state the model does not describe** — management
   addressing, the AAA block containerlab injects, certificates, event handlers.

So a textual diff is mostly noise, and a tool built on one gets ignored within
a month. The audit parses both sides into structure and compares **only the
things the model claims authority over**, which is why it can be silent on a
clean network and precise on a dirty one.

**9. What a clean audit still misses.** It compares values, not meaning. On
this network: change `RM-PEER-IN`'s match from `PL-BOGON` to `PL-OURS`, and the
local-pref, the community, the clause count and the attachment all still match
the model. The audit says nothing. The route-map now accepts only our own
space from the peer, which is to say nothing at all, and `est-r2` silently
stops learning `100.110.0.0/16`.

What catches that is a **state** check — `verify`'s exit assertion — which is
the same complement Lab 15 ended on. Structure finds what has no symptom;
state finds what structure cannot reason about. Run both.

### A3. The running network

**10. `wst-r1 -> eur-r1`.** Direct is 130. The alternative is via `est-r1`:
65 + 75 = 140. Direct wins with a **margin of 10**. The margins were chosen
deliberately — at 140 the two tie exactly, which is physically realistic for a
transatlantic-plus-transcontinental path and useless for a deterministic lab.

**11. How `peer1`'s prefix reaches `wst-r2`.**

1. `est-r2` learns `100.110.0.0/16` over **eBGP** from `peer1`, applies
   `RM-PEER-IN`, sets local-pref 200 and community 65010:200.
2. `est-r2` advertises it over **iBGP** to `est-r1`, its route reflector, with
   `next-hop-self` → next hop becomes `10.2.0.2`.
3. `est-r1` **reflects** it. A route learned from a client is reflected to
   non-clients, so it goes to `wst-r1` and `eur-r1`. `est-r1` also has
   `next-hop-self`, so the next hop is rewritten again → `10.2.0.1`.
4. `wst-r1` receives it, and reflects it to **its** client `wst-r2`, rewriting
   the next hop once more → `10.1.0.1`.
5. `wst-r2` resolves `10.1.0.1` through OSPF over the intra-region link and
   installs the route with a next hop of `10.254.7.0`.

The next hop is rewritten **three times**, once at each iBGP hop, because every
router here is in the forwarding path. On a reflector that is *not* in the
forwarding path, `next-hop-self` would be wrong and would pull traffic through
a box that should only be passing routes.

**12. Two paths at `wst-r1`, one at `est-r1`.** `wst-r1` has its own eBGP
session to `transit1` plus the iBGP path reflected from `eur-r1`'s session, so
two. `est-r1` has no external session of its own; it learns the prefix from
`wst-r1` and `eur-r1` — which would also be two. If you are seeing one, the
reason is that a reflector advertises only its **best** path, so whichever of
the two RRs it prefers is the only one that propagates further. Count at each
router and the pattern follows the reflector hierarchy, not the session count.

---

## Part B — The eight drifts

### Drift 1 — `wst-r2`'s loopback is hand-allocated

**Finding.** `ADDRESSING  Loopback0 is 10.1.0.22/32; the model computes
10.1.0.2/32 from 10.{R}.0.{N}/32 with R=1, N=2`

**Which side is wrong: the network.** The model's value is derivable from the
rule and the device's is not. There is no reading of `R=1, N=2` that produces
`.22`.

**The case for leaving it** — question 16 — is real and worth stating: every
session is up, every route resolves, nothing is unreachable, and changing a
loopback bounces every iBGP session on the box. A change with a cost and no
visible benefit is a hard sell.

**Why you change it anyway.** The value of an algorithmic scheme is that it is
*exceptionless*. One hand-allocated address does not cost you much; it costs
you the ability to say "every loopback is computable", and therefore the
ability to generate, to audit, and to let a script assume. The second exception
is cheaper than the first, and the twentieth is a spreadsheet. You are not
defending `.2` over `.22` — you are defending the absence of a lookup table.

**Fix.** `./lab.sh remediate wst-r2`, in a window, since iBGP will bounce.

---

### Drift 2 — one-sided IGP cost

**Finding.** `IGP-COST  Ethernet2 OSPF cost is 200; the model says 75, which
comes from the measured RTT` on `est-r1`.

**Which side is wrong: the network.** 200 is not a measurement of anything —
the link is 75ms and no rule in the model produces 200.

**The asymmetry, precisely.** OSPF cost is per interface and therefore per
direction. `est-r1 -> eur-r1` is now 200 direct against 65 + 130 = 195 via
`wst-r1`, so it reroutes the long way round, crossing the Atlantic twice.
`eur-r1 -> est-r1` is untouched at 75 and still goes direct.

Traffic between London and Ashburn now takes **different paths in each
direction**, with ~120ms of extra latency one way only. Every RTT measurement
sees half of it, which is why one-sided cost changes produce the most
confusing latency tickets there are.

**The command that proves it:** `show ip route 10.3.0.1` on `est-r1` against
`show ip route 10.2.0.1` on `eur-r1`. Two routers, two different answers, both
correct.

**Fix.** `interface Ethernet2` / `ip ospf cost 75`, or remediate.

---

### Drift 3 — a reflector that stopped reflecting

**Finding.** `BGP-RR  neighbor 10.1.0.2 is a reflector client in the model and
is not configured as one` on `wst-r1`.

**Which side is wrong: the network.** The model makes r1 the reflector in every
region, and the other two regions still do it.

**Why it is quiet.** The session stays Established. `wst-r2` still receives
everything `wst-r1` originates or learns from **eBGP**, because those are
advertised to any iBGP peer. What it stops receiving is everything `wst-r1`
learned from **another iBGP peer** — which, without `route-reflector-client`,
may not be re-advertised. So `wst-r2` loses the routes that came from `est-r1`
and `eur-r1`: the other two regions' prefixes and the peer's space.

`verify` catches it — `wst-r2 holds all three region prefixes` fails — but only
because this lab asserts it. A session-count check sees nothing.

**Fix.** Restore `route-reflector-client` under `address-family ipv4`.

---

### Drift 4 — a neighbour the model does not describe

**Finding.** `BGP-TOPOLOGY  neighbor 10.99.9.9 (AS 64999) is configured and not
in the model` on `est-r2`, with the description `temp_do_not_remove`.

**Which side is wrong: the network** — but read on, because the disposition is
the interesting part.

**Why `verify` cannot see it.** The neighbour is administratively shut, so it
never reaches Established and never appears in a session count. It advertises
nothing, learns nothing, and consumes nothing. By every state measure the
device is perfect.

**Why the audit can.** The audit compares the configured neighbour **set**
against the model's, not the established one. Configuration is intent, and
this is intent nobody agreed to.

**The right disposition for `temp_do_not_remove`.** Not "leave it" and not
"delete it quietly". It is a **question for a human**, and the fact that it is
shut tells you somebody already decided it should not be live. The procedure
is: find out who, and whether the thing it was for still exists; if yes, it
belongs in the model with a reason; if no or nobody knows, remove it.

What you must not do is leave it indefinitely because it is harmless. It is
harmless **while shut**. The failure mode is somebody tidying up six months
later, seeing a shut neighbour, un-shutting it to "test", and establishing a
session with a network nobody vetted. Configuration that nobody can justify is
a liability with a long fuse.

---

### Drift 5 — a renumbered point-to-point

**Finding.** `ADDRESSING  Ethernet1 is 10.254.55.1/31; the model computes
10.254.5.1/31 from 10.254.{L}.0/31 with L=5` on `eur-r2`.

**Which side is wrong: the network.** And the decisive evidence is the **far
end**: `est-r2`'s `Ethernet2` is still `10.254.5.0/31`. The two ends of one
link are in different subnets.

That also tells you what broke. The OSPF adjacency on that link is down, so
`est-r2 <-> eur-r2` has no direct path and the plane-2 triangle is now a line.
`verify` catches it twice — OSPF adjacency count on both routers, and the
`est-r2 next hop to wst-r2` assertion.

This is the one drift where the triage question answers itself: a model cannot
make one end of a cable disagree with the other, so a model edit could not have
produced this.

**Fix.** `interface Ethernet1` / `ip address 10.254.5.1/31`, and fix the OSPF
network statement with it.

---

### Drift 6 — a local-pref that is not one of the two permitted values

**Finding.** `POLICY  RM-PEER-IN sets local-preference 150; model/policy.yml
says 200 for a peer` on `est-r2`.

**Which side is wrong: the network.** `model/policy.yml` defines exactly two
values, 200 for a peer and 100 for a transit. 150 is neither, and no other
router has it.

**What it does.** 150 still beats the transit's 100, so `100.110.0.0/16` still
exits via the peer and nothing is reachable-or-not. The damage is latent: the
hierarchy has lost its meaning. The next person to add a relationship at 150
expecting it to lose to peers will find it does not.

**The general rule worth taking away:** audit the **set** of values in use
against the set the policy permits, not just each value against its intended
one. Any value that is not in the permitted set is a finding on sight, and that
check is three lines and catches a whole class.

**Fix.** `route-map RM-PEER-IN permit 10` / `set local-preference 200`.

---

### Drift 7 — the model's RTT changed and the network did not

**Finding.** Two findings, the same kind, on two different devices:
`IGP-COST  Ethernet3 OSPF cost is 130; the model says 142` on `eur-r1`, and
`IGP-COST  Ethernet2 OSPF cost is 130; the model says 142` on `wst-r1`.

**Which side is wrong: the model is RIGHT, the network is behind.**

**The evidence that settles it.** Two things, and the first is nearly
conclusive on its own:

1. **Both ends disagree with the model in exactly the same way.** A CLI change
   happens on one device. For both ends of a link to drift identically, a human
   would have had to make the same mistake twice, symmetrically. That shape —
   *both ends, same direction, same magnitude* — is the signature of the model
   having moved, not the routers.
2. **The new value is defensible.** 142 is a plausible RTT for that path. It is
   not a typo, a round number, or an obviously wrong magnitude. Somebody
   measured something.

**What happened:** the circuit was regroomed onto a longer route, somebody
updated the model's measured RTT, and the configuration change never shipped.

**The correct action is to change the network**, which here means `render` then
`remediate` both ends.

**And it has a consequence worth predicting before you do it.** At 142 the
direct path loses to via-Ashburn at 140. Remediating **reroutes London–Seattle
traffic through Ashburn**, which is correct — the direct circuit really is
longer now — but it is a traffic shift, not a cosmetic fix, and it belongs in a
window. Confirm it afterwards with `show ip route 10.3.0.1` on `wst-r1`.

---

### Drift 8 — the model describes a circuit nobody ordered

**Findings.** Three, all on `wst-r2`:
`INTERFACE  Ethernet4 is absent; the model assigns it to peer1 (link 13)`,
`BGP-TOPOLOGY  neighbor 10.254.13.1 (AS 65300) is in the model and not
configured`, and a policy finding about the route-map that is not attached.

**Which side is wrong: the model.**

**The evidence that settles it.** `./lab.sh status`, or `bgp-lab16.clab.yml`:
**there is no cable**. `wst-r2` has three interfaces and all three are backbone
links. The model describes a peering session over a physical link that does not
exist and never did.

A model can assert anything. The network cannot invent a port.

**This is question 15's drift — the dangerous one.** Everything about the
finding reads like drift 3 or drift 5: the model says a thing, the device does
not have it, remediate. And remediating is harmless here only because the
interface does not exist, so the config lands and does nothing. In a network
where `Ethernet4` existed and was carrying something else, pushing the model
would have **overwritten a live interface** with a peering session to a network
that never agreed to it.

How long before anyone noticed: if `Ethernet4` were in use, immediately and
loudly. If not — as here — possibly never, leaving a permanent audit finding
that everyone learns to ignore, which is its own slow failure.

**The correct action.** Either remove the entry from `model/network.yml`, or —
if somebody genuinely intends to build this peering — leave it and mark it as
planned, so the audit can exclude it until the circuit is delivered. That
marker is Part C question 22: the model needs a **state** per object, not just
a value.

**Fix.** Remove the `wst-r2 -> peer1` line from `model/network.yml`, re-render,
re-audit.

---

## Part B2 — The questions

**13. What state monitoring finds.** `verify` catches drifts **2, 3 and 5** —
the ones that changed a path, a prefix set or an adjacency. It misses **1, 4, 6,
7 and 8**:

- **1** (loopback) — every session is up and every route resolves. Nothing to
  observe.
- **4** (extra neighbour) — administratively shut, so it has no state at all.
- **6** (local-pref 150) — still beats the transit, so the chosen exit is
  unchanged.
- **7** (model RTT) — the network is self-consistent and converged. There is
  nothing wrong with it; it is just not what the model now says.
- **8** (phantom circuit) — the network cannot have a symptom caused by
  something that does not exist.

Three of those five are invisible because **nothing is wrong with the running
network**, which is a category state monitoring cannot have an opinion about.

**14. The two model drifts, and what settles each.**

- **Drift 7:** *both ends of one link disagree with the model identically*. A
  router-side change happens on one device; symmetric disagreement on two is
  the fingerprint of the model having moved.
- **Drift 8:** *there is no cable*. The topology is ground truth about what
  physically exists, and the model is describing a port that was never built.

**15.** Drift 8. Remediating pushes a peering session onto an interface the
model invented. Here it is inert because `Ethernet4` does not exist. On a real
device with that port in service, `configure replace` would have **replaced a
working interface** with a handoff to AS 65300 — an outage caused by a tool
behaving exactly as designed, because nobody triaged.

**16.** Drift 1. Covered above: the case for leaving it is real, and you change
it anyway because what you are defending is the absence of exceptions, not the
address.

**17.** Drift 4. Covered above. Short version: `verify` cannot see it because
it is shut and therefore stateless; the audit can because it compares
configuration, which is intent; and the right disposition is to find the owner
and either model it or remove it — never to leave unjustifiable configuration
in place because it is currently harmless.

**18.** Drift 2. `est-r1 -> eur-r1` reroutes via `wst-r1` at 195 against the
drifted 200; `eur-r1 -> est-r1` stays direct at 75. Different paths in each
direction, ~120ms of one-way extra latency. Proof:
`show ip route 10.3.0.1` on `est-r1` beside `show ip route 10.2.0.1` on
`eur-r1`.

**19. Survival, longest first.**

1. **Drift 8** (model) — no symptom is possible, so it survives until somebody
   either cleans up the audit output or acts on it wrongly. Indefinitely.
2. **Drift 4** (extra neighbour) — shut, silent, and labelled in a way that
   discourages anyone from touching it.
3. **Drift 1** (loopback) — works perfectly; found only by audit.
4. **Drift 6** (local-pref 150) — works; the damage is to a future change.
5. **Drift 7** (model RTT) — the network is fine, so nothing pages. Survives
   until the audit is read, or until someone wonders why London–Seattle latency
   did not change when the circuit was regroomed.
6. **Drift 3** (reflector) — `wst-r2` loses two regions' prefixes. Loud if you
   assert prefix presence, invisible if you watch sessions.
7. **Drift 2** (IGP cost) — a one-way latency jump. A user complains.
8. **Drift 5** (P2P renumber) — an adjacency is down. The loudest, and the only
   one a conventional NMS finds on its own.

The longest-surviving one is a **model** drift, and that is the uncomfortable
finding: once you adopt a model, the model becomes a place things can be wrong
that nothing in the network will ever contradict.

**20. What a CI gate catches before it ships.** A gate that runs `render` and
then audits the **rendered** configs against the model catches **drifts 7 and
8** — the model-side ones — because they are the only two that exist in the
model at commit time. It catches drift 8 specifically if the gate also
cross-checks the model against the topology, asserting that every modelled link
has a physical endpoint.

It catches **none of 1 through 6**, because those are changes made directly on
devices and never passed through the pipeline at all. Those need the other
control: **make the pipeline the only path to a device**, and alert on any
config change not originated by it. That is question 21.

---

## Part C — Design

### C1. Making the model authoritative

**21. The pipeline.**

A change is a **merge request against `model/`**. Nothing else is a change.

Gates, in order:
1. **Schema validation.** The YAML parses and every required field is present
   and typed. Rejects half-finished edits.
2. **Model self-consistency.** Every link endpoint names a device that exists;
   every modelled link has a physical counterpart; no address collides; no link
   id is reused; every device has the interfaces the rules assign.
3. **Render.** If the renderer throws, the change is rejected.
4. **Audit the rendered output against the model.** This catches a renderer
   and audit that have drifted apart — a real failure, since they are two
   programs that must agree.
5. **Diff review.** A human reads the rendered config diff, not the YAML diff.
   The YAML says `rtt: 142`; the diff says *the OSPF cost on two transatlantic
   links changes, which reroutes London–Seattle through Ashburn*. The second
   is what you are approving.
6. **Blast-radius gate.** Block automatically on: any loopback change, any
   link-id renumber, any change touching more than N devices, any change to a
   transit or peering session. Those need a window, not a merge.

The single way config reaches a device is the deploy job. Everything else —
including the CLI — is an incident.

**22. Metadata that would let the audit recommend.**

Per object in the model, three fields:

- **`state`**: `planned` | `live` | `decommissioning`. Drift 8 becomes a
  non-finding the moment the entry is marked `planned`, and the audit can say
  *"modelled as planned, not yet built — expected"* instead of crying wolf
  forever. This single field is the highest-value one.
- **`changed_at` / `changed_by`** on the model side, from git, plus the
  device's own config-change timestamp. When the model changed after the device
  did, the model is probably ahead and the action is to deploy. When the device
  changed after the model, somebody bypassed the pipeline.
- **`source`**: `designed` | `measured` | `discovered`. A measured value like
  an RTT is expected to move and should trigger a deploy; a designed value that
  moves is a decision somebody made and should trigger a question.

Recorded at **commit time for the model** and **at config-change time for the
device**, which means you need streaming telemetry or config-change events from
the devices — the part most networks skip and then wish they had.

**23. Break-glass at 3am.**

*Allowed:* any change necessary to restore service, made directly on the
device, by anyone on the on-call rotation. No approval, no pipeline. An
availability incident must never wait twenty minutes for CI.

*Recorded:* the engineer declares break-glass in the incident channel before
touching anything — one line, device and reason. The config-change event is
captured automatically. The audit will report the drift at its next run, which
is the backstop if the declaration is forgotten.

*Afterwards:* within one business day, the change is either **reverted** or
**merged into the model**. It does not stay as drift. The audit finding is the
ticket, and it does not close until the model and the device agree again.

The principle: **you cannot stop break-glass and should not try.** What you can
do is make it loud, time-boxed, and automatically reconciled, so the cost of
skipping the pipeline is paperwork rather than permanent divergence.

**24. Discovery-first against model-first.**

*Discovery-first* says: the network is the truth, build the model from it. Its
honest strength is that it is **always correct on day one**, and it is the only
option when nobody knows why anything is configured the way it is. Its weakness
is that it **encodes the mess**, including every exception and every mistake,
and gives you no way to say what *should* be true — so it can tell you the
network changed but never that it is wrong.

*Model-first* says: the model is the truth, generate the network from it. It
gives you intent, which is what makes an audit meaningful and generation
possible. Its weakness is that it is **wrong until proven right**, and this lab
is an eight-item demonstration of what that costs.

**Greenfield: model-first**, without hesitation. There is no legacy to
reconcile and the discipline is cheapest to adopt before the first exception
exists.

**Twenty-year-old network: discovery-first, then converge.** Build the model
by discovery, which is immediately accurate. Then, region by region, replace
discovered values with computed ones — and every difference you find while
doing it is either a bug you just discovered or an exception you now have to
justify in writing. The switch of authority happens per-domain, not globally:
loopbacks first, because they are easiest and highest value, then P2P, then
policy, then topology. Question 31 is the same answer from the other end.

### C2. Addressing at scale

**25. Forty regions, eight routers, a fabric behind each.**

| Domain | Plan |
|---|---|
| Loopbacks | `10.{R}.0.{N}/32` still works — 40 regions, 8 routers |
| Backbone P2P | `10.254.{L}.0/31` gives 256 links and **breaks first** |
| Fabric | a /16 per region out of a separate aggregate, `10.{100+R}.0.0/16` |
| ASNs | backbone one public ASN; fabrics 4-byte private, `4200000000 + R*1000 + device` |

**What breaks first is the P2P space.** `10.254.{L}.0/31` has exactly 256 link
ids. Forty regions at eight routers with two planes and intra-region meshing is
far more than 256 links, and the external handoffs come out of the same block.

The fix is to widen the field before you need it: `10.{252+plane}.{L1}.{L2}/31`
or simply a /16 per region for intra-region links plus a separate block for
inter-region. The general lesson repeats question 2: **leave spare fields in
the rule**, because adding one later is a renumber and a renumber is an
outage.

**26. Unnumbered.** With BGP unnumbered — IPv6 link-local peering plus RFC 8950
for IPv4 NLRI — the P2P addresses vanish entirely.

*Out of `model/network.yml`:* the `p2p4` rule, and with it the whole link-id
allocation problem from question 3 and the exhaustion problem from question 25.
Links become nothing but a pair of endpoints.

*Out of the audit:* every `ADDRESSING` check on an Ethernet interface, and
drift 5 becomes impossible — two ends of a cable can no longer be in different
subnets.

*The new failure mode you have bought:* **you lose the ability to address a
link.** Traceroute output stops naming interfaces usefully, you cannot ping one
end of a span from the other to test it, and correlating an interface in a
monitoring system to a circuit id now depends entirely on descriptions being
right. Operators who adopt unnumbered invariably rebuild that mapping
somewhere, and the place they rebuild it is the model. You have moved the
problem rather than removed it — which is still a win, because the model is a
better place for it than 600 routers.

**27. Algorithmic against IPAM-with-an-API.**

Algorithmic wins on: **derivability** (you can read an address), generation,
auditing, and the absence of a runtime dependency — the renderer works offline,
forever, from a text file in git.

IPAM wins on: **exceptions** (it can allocate anything), mergers (it can absorb
somebody else's space, which no rule can), delegation (a regional team can be
given a block and an API without touching the global rule), and renumbering
(it has a record of what is where).

Where the argument actually lands: **use a rule, and record the result in
IPAM.** The rule generates, IPAM is the registry of record and the place
exceptions live with a justification attached. The failure mode to avoid is an
IPAM that allocates *randomly from a pool*, which gives you a network where no
address means anything and every tool needs a lookup.

And when somebody needs an exception: the exception goes in the model as an
explicit override with a reason and an expiry, so it appears in the audit's
declared-exception list rather than silently defeating the rule. Lab 15's
exception list, applied to addressing.

**28. Decommissioning a region.**

- **Address space:** reusable, but not immediately. Wait out the longest
  cache, route and ACL lifetime anywhere that might still reference it —
  realistically one to two quarters. Reusing a decommissioned region's loopback
  block next week means some forgotten static route or firewall rule now points
  at a live device in a different continent.
- **Link ids:** **never reuse.** Mark them decommissioned and leave the gap.
  Reuse is the exact operation from question 3 that renumbers the network, and
  the id costs nothing to retire.
- **ASN:** reusable soonest of the three if it is private, because it is scoped
  to your own AS and a stale path with it is dropped on loop detection. A
  public ASN goes back to the RIR and is never yours to reuse.

Safest to reuse, in order: ASN, then addresses after a quarantine, and link ids
never.

### C3. Drift in general

**29. Four sources of drift that are not a human on a router.**

1. **A software upgrade changing defaults.** A value that was implicit becomes
   explicit, or vice versa. **Catchable**, if the audit asserts the value
   rather than its presence — which is why the audit here compares computed
   values and skips checks where the device may legitimately elide a default.
2. **A protocol or controller writing config** — dynamic peering, a PCE, an
   SDN agent, automatic VLAN assignment. **Partly catchable**: the audit sees
   the result, but cannot distinguish it from a human, and the model usually
   has no field to express "this subtree is managed by something else". The fix
   is to mark those regions of config as out of scope.
3. **Hardware replacement.** An RMA comes back with a different serial, a
   different port layout, or the configuration of its predecessor's
   predecessor. **Catchable** by the audit, and this is one of its best cases.
4. **The model's inputs changing underneath it** — a carrier regrooms and the
   measured RTT moves, an IRR entry changes, a peering database updates.
   **Not catchable by comparing the model to the network**, because both are
   self-consistent. This is drift 7, and it needs the model's inputs to be
   audited against their own sources, which is a second audit nobody builds.

**30. The continuous version.**

*Cadence:* every 15 minutes for policy and BGP topology, hourly for addressing
and IGP cost, and immediately on any config-change event from a device.

*Against:* the model at the **current commit on the deployment branch**, not
`main` — otherwise every merged-but-undeployed change is a false positive, and
a tool that is wrong every time somebody merges gets ignored in a week.

*Where findings go:* not to an alert channel. To a **drift dashboard with an
owner per finding and an age**, plus a weekly report of findings older than
seven days. The only thing that pages is a finding that appears **within an
hour of a config-change event that did not come from the pipeline** — because
that is somebody on a router right now, which is the one time urgency is real.

*How you stop it being ignored:* two mechanisms. **A declared-exception list**
with a reason and an expiry for everything deliberately divergent, so steady
state is genuinely zero. And **age as the alert, not count** — nobody acts on
"47 findings", everybody acts on "this one has been open 30 days and it is
yours".

**31. Inheriting a network with no model.**

1. **Discover read-only.** Collect every running config and build a model by
   extraction. No change window; nothing is pushed.
2. **Audit the discovered model against itself.** Every place the discovered
   values do not follow an obvious pattern is either an exception or a bug, and
   you now have a list. This is the most valuable artefact of the whole
   exercise and you have it in week one.
3. **Propose the rules.** Write the rule you *wish* described the network and
   measure how many devices already comply. Usually most do.
4. **Converge opportunistically.** Every time a device is touched for another
   reason, bring it into compliance. No dedicated renumbering project — those
   do not get funded.
5. **Switch authority per domain, not globally.** The moment every device
   complies for *loopbacks*, loopbacks become model-first and a deviation
   becomes a finding. Then P2P. Then policy. Then topology.

**The switch point for a domain is when compliance is 100% and the pipeline can
deploy it** — not when it is 95%, because the last 5% is where the exceptions
live and they will eat the policy's credibility if you declare victory early.

### C4. What this lab cannot show

**32. Three drift failure modes it cannot reproduce.**

1. **Drift at a rate humans cannot track.** With six routers you read every
   finding. The real problem is 6,000 devices producing a steady background of
   findings where the signal is the *rate of change* and the *age
   distribution*, not any individual item. That needs scale and a time series,
   and all the interesting engineering — deduplication, ownership routing,
   suppression — only exists above a threshold this lab is far below.
2. **The organisational cause.** Drift is produced by a change process, not by
   a protocol: a pipeline too slow to use under pressure, an on-call rotation
   with root and no alternative, a team that owns a device but not the model,
   an outage where the correct action was to bypass the process. No lab
   reproduces an organisation, and every real drift problem is one.
3. **Partial and failed deploys.** A push that applied to 40 of 60 devices and
   left no record of which; a `configure replace` that errored halfway; a
   device that accepted the config and rolled back after a reload. These make
   the network inconsistent in ways that look like drift and are not, and
   diagnosing them needs real deployment tooling with real failure modes —
   which is the layer this lab deliberately leaves to yours.

What all three share with every lab in this series: the control plane is the
easy part. `model/` is 90 lines and it is the whole network; `tools/audit.py`
is the only thing standing between those 90 lines and 600 routers that have
each been touched once by somebody with a good reason.
