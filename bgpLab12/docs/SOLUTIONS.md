# Lab 12 Solutions

Do not read this first.

---

## Part A — Baseline

### A2. Accounting for the matrix

**1. `rail1 → gpu1` is 1 while `gpu1 → gpu2` is 2.**

rail1 has exactly one way to reach gpu1: the direct link on Ethernet3. It has
no second path, and this is the important part — **it cannot have one.** Both
rails are in AS 65101. A route to gpu1 arriving at rail1 from a spine carries
AS path `65100 65101 65201`, which contains rail1's own AS. rail1 drops it on
AS-path loop detection before best-path selection ever runs.

So rail locality here is not a preference the fabric expresses. It is a
structural consequence of the shared rail ASN. That is a stronger guarantee
than a route-map, and it is one of the real reasons the design is built this
way.

gpu1 → gpu2, by contrast, has two genuinely distinct paths: `65101 65202` via
rail1 and `65101 65202` via rail2. Identical in content, distinct in next hop.

**2. `spine1 → storage` is 1.** stor1 is single-attached to each spine, so
spine1 has one link to it. Same reason as (1), minus the loop detection: there
simply is one link.

**3. Width lives on the device, not in the fabric.** nfs1 has one link to
stor1, therefore one next hop, therefore width 1 — and no amount of ECMP
upstream changes that. stor1 reads 2 because stor1 has two spine links.

What it means operationally: a single-attached server inherits whatever
redundancy the fabric provides on its behalf, and inherits none of the
redundancy it would have had from a second NIC. nfs1 survives a spine failure
because stor1 does. It does not survive stor1 failing, or its own link
failing, and no BGP convergence anywhere helps. That is the risk profile you
accept for storage and refuse for compute, which is why every GPU here has two
NICs and nfs1 has one.

**4. The diagonal is a local route.** gpu1's route to 10.10.0.1 is its own
Loopback1 — a receive route, not a forwarding decision, with no next hop to
count. Printing `0` there would read as a fault, so the matrix prints `-`. The
`w()` helper counts lines matching `via 10.1.` or `via 10.2.`, which is to say
next hops reached over a fabric link, and a local route has none.

### A3. Rail locality

**5. gpu2 → gpu1 is two hops:** gpu2 → rail1 (or rail2) → gpu1. One switch in
the middle, never a spine.

**6. gpu1 → storage is three hops:** gpu1 → rail → spine → stor1 → nfs1, so
four hops to the server itself. Storage is not on a rail, so it can only be
reached across the spine layer. In a real fabric this asymmetry is deliberate:
collectives get one hop, storage gets three, and storage does not care.

**7. Why rail1 never considers the spine path.** As (1): AS-path loop
detection, not best-path selection. Verify it:

```
rail1# show ip bgp 10.10.0.1/32
rail1# show ip bgp neighbors 10.1.1.0 received-routes | include 10.10.0.1
```

The route is *received* from spine1 and never makes it into the BGP table.

### A4. The BGP table

**8. What makes the two paths eligible for multipath.** Everything that has to
match, in order:

| Attribute | gpu1's two paths to 10.10.0.2 |
|---|---|
| Weight | both 0 |
| Local preference | both 100 (default, nothing sets it) |
| Locally originated | neither |
| AS path **length** | both 2 |
| AS path **content** | both `65101 65202` — identical, which is the whole trick |
| Origin | both incomplete (redistribute connected) |
| MED | both 0 |
| eBGP vs iBGP | both eBGP |
| IGP metric to next hop | both directly connected |

Then `maximum-paths 8 ecmp 8` installs both.

**9. If rail1 were 65101 and rail2 were 65102.** The two paths become
`65101 65202` and `65102 65202`. Same length, different content. Standard BGP
multipath requires the AS path to be *identical*, not merely the same length,
so gpu1 would install **one** path and the matrix would read 1 everywhere for
every server. Every GPU would use one NIC and the fabric would run at half
width while every check in this lab except `width` passed.

The command is `bgp bestpath as-path multipath-relax`, under `router bgp` on
**every device that needs to multipath across differing AS paths** — which is
every server and every spine, not just the leaves.

This lab deliberately does not use it, because its behaviour across EOS
releases is something I would want to verify on the actual target version
rather than assume. Which is itself the lesson: a design that needs
multipath-relax has a dependency on a knob; a design with a shared rail ASN
does not.

**10. Endpoint on Loopback1 versus on the NIC.**

On a NIC-addressed server, losing NIC1 takes the address with it. Anything
holding an ARP entry or a route to that address blackholes until it ages out,
and the peer has to reconnect to a different address — which means the
application needs two addresses and a policy for choosing between them.

With the endpoint on a loopback, NIC1 going down withdraws one BGP path and
leaves the address exactly where it was. Convergence is a BGP withdrawal,
typically sub-second and faster with BFD. The application sees one address,
always, and never learns a NIC failed. This is the single most important
design choice in the lab, and it is why servers run BGP at all.

### A5. Frame size

**11. Two MTUs, two layers.** The EOS `mtu 9214` is the forwarding MTU the
agent uses. The veth's MTU is the kernel's, and the kernel wins: a frame
larger than the veth MTU never leaves the container, regardless of what EOS
believes. If only the EOS side were right you would see every size above
roughly 1472 fail on every link, uniformly, which looks like a fabric-wide
misconfiguration and is actually the lab environment.

This is why `bgp-lab12.clab.yml` uses the extended link format with
`mtu: 9214` on every link. See the README.

---

## Part B — The eight faults

### Fault 1 — gpu2 `maximum-paths 1`

**Symptom.** The entire gpu2 row of the width matrix reads 1. gpu1 and gpu3
rows read 2. Every ping passes.

**Find it.**
```
gpu2# show ip bgp 10.10.0.1/32      <- two paths present
gpu2# show ip route 10.10.0.1       <- one next hop installed
gpu2# show running-config section bgp | include maximum-paths
```
Two paths known, one installed. That gap is the signature of a maximum-paths
problem and distinguishes it from everything else in this lab.

**Fix.** `router bgp 65202` / `maximum-paths 8 ecmp 8`

**Production.** Nothing alerts. No session changed state, no interface went
down, no prefix was lost. This is the fault class the whole lab exists for.
You catch it with a config audit (`maximum-paths` present and correct on every
device, asserted in CI against the intended value) or with the width poll from
C2 question 20.

---

### Fault 2 — rail2 filters gpu3's endpoint toward the spines

**Symptom, once fault 7 is fixed.** `spine1 → gpu3` and `spine2 → gpu3` both
read 1 where they should read 2. Everything below the spines looks fine:
stor1 → gpu3 still reads 2, because stor1 has two paths (one per spine) and
both of them happen to go through rail1.

**Masked until then.** While fault 7 is live, rail2 has no route to gpu3 at
all, so a filter on advertising that route changes nothing. **Fix 7 first and
this appears.**

**Find it.**
```
spine1# show ip bgp 10.10.0.3/32                           <- one path, via rail1
rail2#  show ip bgp 10.10.0.3/32                           <- present in the table
rail2#  show ip bgp neighbors 10.1.1.2 advertised-routes   <- 10.10.0.3 missing
rail2#  show running-config section bgp | include route-map
```
The route is in rail2's table and not in what rail2 advertises. That narrows
it to outbound policy immediately.

**Fix.**
```
router bgp 65101
   no neighbor FABRIC route-map RM-F2 out
no route-map RM-F2
no ip prefix-list PL-NOG3
```

**Production.** Nothing alerts, and it is worse than fault 1 because the
damage is one tier away from the device that caused it. Catch it by comparing
advertised prefix counts between twins: rail1 and rail2 should advertise the
identical set, and any difference is a finding.

---

### Fault 3 — spine2 filters all compute prefixes toward stor1

**Symptom.** `stor1 → gpu1`, `gpu2` and `gpu3` all read 1. Storage can still
reach every GPU. A training job reading from NFS runs at half its ingest
bandwidth.

**Paired with fault 8.** Fault 8 (`stor1 maximum-paths 1`) produces the exact
same number in the exact same cells. Fixing either one alone changes nothing,
which is the most demoralizing experience in this lab. The discriminator:

```
stor1# show ip bgp 10.10.0.1/32
```
- **One path** present → the route never arrived → fault 3, upstream.
- **Two paths** present, one installed → the route arrived and was declined →
  fault 8, local.

With both live you see one path, so fault 3 is what you find first. Fix it,
look again, now you see two paths and one installed, and fault 8 is exposed.

**Find it.**
```
stor1#  show ip bgp 10.10.0.1/32
spine2# show ip bgp neighbors 10.1.2.5 advertised-routes   <- no 10.10.x
spine2# show running-config section bgp | include route-map
```

**Fix.**
```
router bgp 65100
   no neighbor 10.1.2.5 route-map RM-F3 out
no route-map RM-F3
no ip prefix-list PL-NOGPU
```

---

### Fault 4 — rail1 Ethernet1 MTU 1500

**Symptom.** Nothing in the width matrix. Every width correct, every ping at
default size passes, every session up. The 8000-byte checks in `verify` fail
for **some** GPUs and pass for others.

**Why some and not others.** The 1500 MTU sits on one leg of rail1's two-way
ECMP bundle toward the spines. Whether a given flow breaks depends on where it
hashes. ICMP from a fixed source hashes the same way every time, so the set of
failing GPUs is stable across runs while looking arbitrary — which is exactly
how MTU faults present in production and exactly why they are hated.

**Its visibility depends on fault 6.** While fault 6 (`rail1 maximum-paths 1`)
is live, rail1 installs a single path to storage. Both spine paths are equal
through every tiebreak until router ID, where spine1 (10.0.0.1) beats spine2
(10.0.0.2) — and spine1 is reached over Ethernet1, the 1500-MTU link. So with
fault 6 live, **every** large frame transiting rail1 fails, deterministically.
Fix fault 6 and the same fault becomes intermittent. Noting that inversion is
worth more than finding either fault.

**Find it.**
```bash
./lab.sh sizes gpu1 10.20.0.1
```
```
rail1# show interfaces | include MTU
rail1# show interfaces Ethernet1 | include MTU
```
Then the one command that finds it without any ping at all:
```
rail1# show running-config section ^interface | include mtu
```
Four interfaces at 9214, one at 1500.

**Fix.** `interface Ethernet1` / `mtu 9214`

**Production.** This is the one fault here that a real monitoring system does
catch, and it is still usually caught by a user. An interface MTU audit across
the fabric is cheap and should be in CI. `show interfaces | include MTU` on
every device, assert one value, fail the build.

---

### Fault 5 — gpu1 wrong remote-as toward rail2

**Symptom.** Two numbers move. gpu1's session count drops to 1 (expected 2)
and rail2's drops to 4 (expected 5). The whole gpu1 row of the width matrix
reads 1.

This is the only fault in the lab that announces itself. A session is down and
anything watching BGP session state will say so.

**Find it.**
```
gpu1#  show ip bgp summary                 <- 10.2.2.0 not Established
rail2# show ip bgp summary                 <- 10.2.1.1 ... wait, wrong address
rail2# show logging | include BGP
```
The log is unambiguous: a notification about an AS mismatch, naming both the
expected and received AS.

**Fix.**
```
router bgp 65201
   neighbor 10.2.2.0 remote-as 65101
```

**Production.** Alerts within seconds. Include it because a lab where nothing
alerts teaches the wrong instinct: the skill is separating the one fault that
pages you from the seven that do not, not assuming there are none of either.

---

### Fault 6 — rail1 `maximum-paths 1`

**Symptom.** `rail1 → storage` reads 1 where it should read 2.
`rail2 → storage` reads 2. The rail1 row's GPU cells are unchanged at 1,
because they were always 1 — which is why this is easy to miss. You are
looking for the one cell in that row that moved.

**Find it.**
```
rail1# show ip bgp 10.20.0.1/32     <- two paths
rail1# show ip route 10.20.0.1      <- one next hop
rail1# show running-config section bgp | include maximum-paths
```

**Fix.** `router bgp 65101` / `maximum-paths 8 ecmp 8`

**Secondary effect.** See fault 4. This one changes another fault's behaviour
from intermittent to total.

---

### Fault 7 — gpu3 does not advertise its endpoint to rail2

**Symptom, and it is the interesting one.** The gpu3 **column** and the gpu3
**row** disagree:

- `gpu1 → gpu3` reads 1, `gpu2 → gpu3` reads 1 — the column is narrow
- `gpu3 → gpu1`, `gpu3 → gpu2`, `gpu3 → storage` all read 2 — the row is fine

gpu3 can use both of its NICs to send. Nobody can use both to reach it.
Traffic to gpu3 goes out over rail1; traffic from gpu3 may come back over
either. A collective involving gpu3 runs at half speed in one direction, and
gpu3's own counters look perfect.

**Root cause.** rail2 has **no route at all** to 10.10.0.3. Not from gpu3,
which no longer advertises it, and not via the spines either, because that
path carries AS 65101 — rail2's own AS — and loop detection drops it. The
shared rail ASN that gives you free rail locality also means a rail cannot
heal a missing server route through the fabric. That trade is worth sitting
with; it is question 18.

**Find it.**
```
gpu1#  show ip route 10.10.0.3                             <- one next hop, via rail1
rail2# show ip route 10.10.0.3                             <- not in the table
rail2# show ip bgp neighbors 10.2.2.5 received-routes      <- empty
gpu3#  show ip bgp neighbors 10.2.2.4 advertised-routes    <- own endpoint missing
gpu3#  show running-config section bgp | include route-map
```
Note the direction of travel: you start at a device that is *not* broken
(gpu1), move to the device with the missing route (rail2), confirm it was
never received, then cross the session to the device that should have sent it.

**Fix.**
```
router bgp 65203
   no neighbor 10.2.2.4 route-map RM-F7 out
no route-map RM-F7
no ip prefix-list PL-NOEP
```

**Fixing this exposes fault 2.** rail2 now has the route and declines to pass
it to the spines.

**Production.** Nothing alerts. This is the fault I would most expect to
survive a year in a real fabric. A per-server check — "every compute endpoint
is advertised to every attached rail, and every rail has a route to every
compute endpoint" — is six lines of Python against the BGP API and it is the
only thing that finds this.

---

### Fault 8 — stor1 `maximum-paths 1`

**Symptom.** `stor1 → gpu1`, `gpu2`, `gpu3` read 1. Identical to fault 3.

**Find it.** See fault 3 for the discriminator: paths known versus paths
installed. Once fault 3 is fixed, `show ip bgp 10.10.0.1/32` on stor1 shows
two paths and `show ip route 10.10.0.1` shows one next hop.

**Fix.** `router bgp 65103` / `maximum-paths 8 ecmp 8`

**Why three copies of the same fault.** Faults 1, 6 and 8 are `maximum-paths 1`
on a server, a leaf and a storage leaf. The symptom reads completely
differently on each: on gpu2 the whole row collapses; on rail1 only one cell
moves, because the rest of the row was legitimately 1 already; on stor1 it is
indistinguishable from an upstream filter. Same misconfiguration, three
different investigations. That is question 13.

---

## Part B2 — The questions

**12. Survival time, longest first.**

1. **Fault 7** (gpu3 not advertised to rail2) — asymmetric, server-side, and
   the affected server's own view is perfect. Nothing in a standard monitoring
   stack looks at this. Years.
2. **Fault 2** (rail2 filters gpu3 to the spines) — one tier removed from its
   cause, and invisible from both the server and the storage side.
3. **Fault 1 / 6 / 8** (`maximum-paths 1`) — survive until someone profiles a
   job or runs a config audit.
4. **Fault 3** (spine2 filters compute to stor1) — survives until someone
   measures storage ingest bandwidth against its theoretical maximum.
5. **Fault 4** (MTU) — hours to days. Someone's large transfer hangs and they
   complain, which is how most MTU faults are found.
6. **Fault 5** (wrong remote-as) — seconds. It pages.

The pattern: **the faults that survive are the ones where no state changed.**
Session up, interface up, prefix present, ping passes. Everything a
conventional NMS watches is a state transition, and width is not a state.

**13.** Faults 1, 6 and 8. Covered under fault 8 above.

**14.** Fault 4, the MTU. The width matrix cannot see it because nothing about
routing changed. `./lab.sh sizes` finds it, and
`show running-config section ^interface | include mtu` finds it without
sending a packet. Its visibility inverts with fault 6: deterministic while 6
is live, intermittent once 6 is fixed.

**15.** Fault 2 is the latent one in the strict sense — while fault 7 is live
it has no effect whatsoever. The event that makes it matter is somebody fixing
fault 7, which is to say: **a repair.** Latent faults in real fabrics are
usually exposed by maintenance, not by failure.

**16.** Two pairs.

- **gpu3 pair: 7 masks 2.** 7 is upstream (rail2 has no route) and 2 is
  downstream (rail2 would not advertise it anyway). Fix 7, then 2 appears.
- **stor1 pair: 3 and 8 are indistinguishable by width.** Neither fix alone
  changes the number. The single distinguishing command is
  `show ip bgp 10.10.0.1/32` on stor1: one path means upstream (3), two paths
  with one installed means local (8).

What it implies: **in a multi-fault fabric, fix in the direction of the
control plane, from the source of the advertisement toward the consumer, and
re-measure after every single change.** Batching fixes is how you end up
unable to attribute any of them. And never conclude a fix did not work from
the fact that the number did not move — check whether a second fault is
sitting on the same number.

---

## Part C — Design review

### C1. ASN allocation

**17.** It removes the need for the AS path **content** comparison in the
multipath eligibility test. Paths from both rails are not merely equal in
length, they are byte-identical, so standard multipath installs both. Without
it you need `bgp bestpath as-path multipath-relax` on every device that
multipaths across differing AS paths.

**18. The case against a shared rail ASN.**

- **No loop prevention between rails via the fabric.** You get rail locality
  for free, but you also lose the ability for one rail to learn a server route
  through the spines when its direct session is gone. Fault 7 is exactly this:
  rail2 cannot heal, and the lack of a route becomes permanent rather than
  transitional.
- **Blast radius.** A misconfiguration under `router bgp 65101` is a
  misconfiguration in two devices' worth of identity. Any automation keyed on
  ASN cannot tell them apart.
- **No per-rail policy.** You cannot match on AS path to express "prefer
  rail1" or "drain rail2", because the two are indistinguishable in the path.
  Draining a rail means touching every server session or using local
  preference, which servers do not usually set.
- **Attribution.** `show ip bgp` tells you a route came from 65101. It does
  not tell you which rail. In a fabric with eight rails that is a real
  operational cost — you lose the AS path as a traceroute for the control
  plane.

**19.** One ASN per leaf is the default because loop prevention via AS path is
how a Clos keeps a leaf from transiting another leaf's traffic, and because
per-device ASNs make the control plane self-documenting. This lab deviates for
a specific, narrow reason: it makes multipath work without a knob whose
behaviour I did not verify on this EOS version.

I would stop deviating at the point where either (a) you need per-rail policy
for drains and maintenance, which is roughly the first time you do a rolling
upgrade, or (b) the fabric is large enough that losing per-device attribution
in the AS path makes troubleshooting slower than the knob is risky. In
practice that is small — single-digit rails. Treat the shared ASN as a lab
simplification, not a recommendation.

### C2. Width as the service level

**20. The monitoring rule.**

Not an interface-state trap. Poll the routing table.

- **Where it runs:** off-box, against eBGP-API or gNMI on every device.
- **What it polls:** for each device and each endpoint prefix, the count of
  installed next hops, plus the count of BGP paths known. Both numbers.
- **The assertion:** installed next hops equal the intended width from a
  declared model — the same model that generated the configs. Not "greater
  than 1". The intended value.
- **Thresholds:** alert on any deviation, immediately, no flap damping, at a
  severity below "page" and above "ticket". A width drop is never transient
  in a healthy fabric.

Polling both numbers is what makes it diagnostic rather than merely alarming:
paths known below intended means upstream, paths known correct with installs
below means local. That is faults 3 and 8 separated automatically.

Add two cheap config audits in CI: `maximum-paths` equals the intended value
on every device, and every interface MTU equals the fabric MTU. Between them
they catch four of this lab's eight faults before deployment.

**21. Mismatched link speeds, width 2.** Every check passes because width is a
count, not a capacity. The job runs at roughly 2/3 of expected bandwidth —
hashing sends about half the flows down a link with a quarter of the capacity,
and the collective waits for them. You would see it in interface utilization
compared against negotiated speed per member, and in negotiated-speed
inventory against intended speed. The general lesson: **width is necessary and
not sufficient. Equal-cost is not equal-capacity, and BGP has no idea.**

**22. Flow polarization.** Per-flow hashing distributes well when there are
many flows. An all-reduce opens a handful — on the order of the rank count —
and each one is enormous and long-lived. With few flows, the hash does not
average out: two 400 Gbps flows can land on the same member while another sits
idle, and the collective runs at the speed of the congested member. Worse, the
same hash inputs produce the same decision at every tier, so a collision at
the leaf is reproduced at the spine.

Two mitigations: **packet spraying or flowlet switching**, which break the
per-flow invariant and reorder deliberately, relying on the NIC to reassemble
(this is what Spectrum-X and Ultra Ethernet do); and **hash seed diversity per
tier**, so a collision at one tier is not reproduced at the next. A third,
cruder one: per-packet load balancing on a fabric where everything is the same
length, accepting the reordering. A fourth, upward: have the collective library
open more flows than ranks so the hash has something to work with.

### C3. Scaling

**23. 8 rails, 16 spines, 128 servers.**

- **ASN plan:** one per device. Spines 65100–65115, rails 65200–65207,
  storage leaves from 65300. Servers from 4-byte private space, 4200000000+,
  one per server, allocated from the inventory. Abandon the shared-ASN trick
  and add `multipath-relax` on the servers and spines, having verified it.
- **IP plan:** `10.0.0.0/16` loopbacks, one /32 per device.
  `10.1.0.0/16` spine-to-leaf /31s, indexed by spine and leaf.
  `10.2.0.0/16` rail-to-server /31s, indexed by rail and slot.
  `10.10.0.0/16` compute endpoints, one /32 per server.
  `10.20.0.0/16` storage. Keep the endpoint space summarizable per pod, because
  at this size you want to aggregate toward storage and the WAN.
- **Ports:** each rail needs 128 downlinks plus 16 uplinks — 144 ports, so a
  64-port switch does not do it and you are into a modular box or two rails
  per index. Each spine needs 8 rails plus storage leaves, which is small.
  Each server needs 8 NICs plus storage.
- **Oversubscription:** 128 downlinks at 400G is 51.2 Tbps down; 16 uplinks at
  400G is 6.4 Tbps up. 8:1. For collectives that is fine, because
  rail-optimized traffic does not use the uplinks. For storage it is not.
- **Binding constraint:** **port count on the rail switch.** The ASN plan is
  bookkeeping and the IP plan is arithmetic. Radix is physics, and it is what
  actually decides the shape of the fabric.

**24. BGP on the host at 128 servers.** 

For: failure detection in BGP time rather than ARP time; the endpoint address
never moves; multipath is explicit and auditable; no FHRP, no bonding, no LACP
anywhere.

Against: 128 servers × 8 rails is 1024 sessions on the rail layer, which is
fine on the control plane and not fine on the operational one. You are now
managing BGP config on 128 machines whose lifecycle is owned by a different
team, with a different change cadence, and a rolling OS upgrade means 128
sessions flapping in sequence. Every server is a device that can advertise a
prefix it should not.

What I would do: keep BGP on the host, and make it non-negotiable that the
server config is generated from the same inventory as the switch config and
deployed by the same pipeline. The failure mode of host BGP is not technical,
it is organizational — two teams, two sources of truth. Add strict inbound
prefix-lists on every rail session so a server can advertise exactly its own
endpoint and nothing else, and `maximum-routes 1` on the server peer group.

**25. A second tenant.** Cheapest first:

- **Separate endpoint prefix plus inbound filters** on the rail sessions.
  Free, no new protocol, and it isolates routing, not forwarding — the two
  tenants still share every link and can still reach each other if either side
  misconfigures. Fine for two trusted internal teams.
- **VRFs on the rails with no leaking**, separate loopback spaces, separate
  server sessions per VRF. Real isolation, no overlay, and it stops scaling
  somewhere around the point where you need VRFs on the spines too.
- **Give up and build Lab 07** when: the tenants need to be reachable from
  overlapping address space, or you need more than a handful of them, or you
  need any tenant to span pods, or the isolation has a compliance requirement
  attached to it. At that point EVPN's RT-based isolation is cheaper than the
  policy you would otherwise hand-maintain, and the encapsulation cost is
  something you accept because the alternative is worse.

The honest answer to "when do you add an overlay to an AI fabric" is: when you
have stopped being an AI fabric and started being a datacenter.

**26. Why storage wants a different shape.** Collective traffic is
east-west, synchronous, bursty, latency-critical and rail-local by
construction — it wants one hop and no oversubscription on that hop.
Storage traffic is many-to-one, throughput-critical, latency-tolerant, and by
definition crosses the fabric because the storage nodes are not on anybody's
rail. Optimizing one shape for both means either over-building the spine layer
for collectives that never use it, or under-building it for storage that does.
So: rails for compute at 1:1 on the rail, a thinner spine layer sized for
storage and cross-rail, and storage attached to its own leaves where its
oversubscription can be chosen independently.

### C4. What this lab cannot show

**27. Three failure modes, and what each would need.**

1. **Congestion collapse under PFC.** Pause frames propagating upstream,
   head-of-line blocking, and in the pathological case a PFC deadlock that
   takes the fabric down with every link up and every session established.
   Needs real ASICs with real buffers and real priority groups. Containers
   have no buffers to fill, no lossless queues, and nothing to pause.
2. **ECN tuning and DCQCN oscillation.** Marking thresholds set wrong, so
   senders either never back off or oscillate. Needs ASIC marking behaviour
   and RDMA NICs implementing the reaction. Software forwarding does not
   mark, and there is no congestion-control loop to destabilize.
3. **Hash collision on a real collective.** Flow polarization needs real
   flows at real rates to show up. Needs line-rate traffic across a real
   bundle with real hashing hardware. `ping` cannot produce it; even iperf
   across veths cannot, because the bottleneck is the host CPU and not the
   fabric.

What they have in common: all three are **data-plane** properties, and
containerized network OSes model the control plane. This lab teaches the
routing design that has to be correct before any of that matters. It does not
teach the part that makes AI fabrics hard.
