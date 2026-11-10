# Lab 11 Solutions (spoilers)

Eight faults. Three produce no steady-state symptom, two mask each other, one is
size-dependent, one is a security finding rather than an outage.

## The faults

**Fault 1 — leaf2's uplinks set to MTU 1500.**
Steady-state symptom: none. Every ping passes.
Found by: `./lab.sh sizes h2 10.10.20.1`. The ceiling drops to around 1450 inner,
because 1450 inner plus 14 inner Ethernet plus 50 bytes of VXLAN is 1514 on the
wire, and a 1500-byte link carries exactly 1514.
Fix: `mtu 9214` on leaf2's Ethernet1 and Ethernet2.
Why it is hard: this is the PMTU black hole. Small packets pass, large ones
vanish, and the user reports it as "the application hangs" rather than as a
network fault. Nothing in reachability monitoring touches it.

**Fault 2 — leaf1 no longer maps VLAN 10 to VNI 10010.**
Symptom: h1 cannot reach h2. Everything else works.
Found by: `show vxlan vni` on leaf1 versus leaf2. The EVPN control plane is
flawless: type-2 routes present on both sides with correct route-targets, the
VTEP list correct, the MAC table correct. leaf1 simply has nowhere to put the
traffic.
Fix: `vxlan vlan 10 vni 10010` under Vxlan1.
Why it is hard: every control-plane check you would run passes. The gap between
"the route is correct" and "the device can act on it" is the whole lesson, and
it is the same gap Lab 05's VTEP-count assertion fell into.

**Fault 3 — bleaf2's BLUE egress route-map matches the RED prefix-list.**
Steady-state symptom: **none**. bleaf1 is primary for both VRFs, so bleaf2 is
carrying nothing and its broken policy is never exercised.
Found by: `./lab.sh drain bleaf1`, then checking BLUE reachability. Or by
`show ip bgp 10.30.30.0/24` on wan, which holds one path where it should hold
two.
Fix: `match ip address prefix-list PL-BLUE-TENANT` on `RM-BLUE-OUT`.
Why it is hard: a backup that has never carried traffic is a backup nobody has
tested. This is the most common real-world version of this fault, and it is
always discovered during the incident the backup was supposed to cover.

**Fault 4 — leaf3's Vlan30 SVI moved into VRF RED.**
Symptom: h3 cannot reach the WAN, and h3 **can** reach RED hosts.
Found by: the two isolation assertions in `verify` going red at the same time as
h3's WAN test.
Fix: `interface Vlan30` / `vrf BLUE` / `ip address virtual 10.30.30.1/24`.
Note that changing a VRF clears the address, so both commands are needed.
Why it is hard: it presents as a routing problem and is a VRF-membership
problem. The two symptoms look unrelated and are the same fault. Also, half of
it is not an outage at all: a BLUE host reaching RED is a tenant-isolation
breach that no availability monitoring would ever flag.

**Fault 5 — bleaf1's `PL-RED-TENANT` lost its `le 24`.**
Symptom: RED hosts cannot reach the WAN. BLUE can.
Found by: comparing the RED and BLUE prefix-lists on bleaf1, or by looking at
what wan holds for 10.10.10.0/24 versus 10.30.30.0/24.
Fix: `ip prefix-list PL-RED-TENANT seq 10 permit 10.10.0.0/16 le 24`.
Why it is hard: a prefix-list that permits `10.10.0.0/16` matches that prefix
and nothing else. The tenant subnets are /24s and no /16 is ever advertised, so
the list permits a prefix that does not exist and denies every one that does.
Four characters, and the symptom is on a different device from the cause.

**Fault 6 — spine1 dropped leaf3 from its EVPN peer group.**
Steady-state symptom: **none**. leaf3's overlay works through spine2.
Found by: counting EVPN sessions on spine1 and spine2. One shows 4, its twin
shows 5.
Fix: `neighbor 10.0.0.13 peer group EVPN` on spine1.
Why it is hard: there is nothing to detect by reachability, because reachability
is fine. It is only visible by comparing a device against its twin, or by
draining spine2 and watching leaf3 fall off the fabric.

**Fault 7 — spine2's `PL-LOOPBACKS` no longer permits the VTEP range.**
Steady-state symptom: **none**. Every VTEP is reachable via spine1.
Found by: counting installed next hops to a remote VTEP on any leaf. Two
expected, one present.
Fix: `ip prefix-list PL-LOOPBACKS seq 20 permit 10.0.1.0/24 eq 32` on spine2.
Why it is hard: the sibling of fault 6, found by the same method and a different
counter. Note the pairing: fault 6 removes overlay redundancy for one leaf,
fault 7 removes underlay redundancy for every leaf, and neither costs a packet
until something else fails.

**Fault 8 — a static route to Null0 on leaf1 for the WAN prefix in VRF RED.**
Symptom: h1 cannot reach 203.0.113.10. h2 can, and both are in VRF RED.
Found by: `show ip route vrf RED 203.0.113.0/24` on leaf1, which shows Null0,
next to `show ip bgp vrf RED 203.0.113.0/24`, which shows a perfectly good path.
Fix: `no ip route vrf RED 203.0.113.0/24 Null0`.
Why it is hard: BGP is completely correct and completely irrelevant. A static
route has administrative distance 1 and beats eBGP's 20, so the FIB and the BGP
table disagree and only one of them decides where packets go. Checking `show ip
bgp` and concluding the routing is fine is the trap.

## The interactions

**Faults 5 and 8 mask each other.** Fault 5 breaks RED's WAN reachability for
*every* RED host, which hides the fact that fault 8 has separately broken it for
h1 specifically. Fix 5 and h2 starts working while h1 still does not, which
looks like your fix made things inconsistent. It did not; it revealed the second
fault. The shape to recognise: "my fix worked for some hosts and not others" is
usually two faults, not a bad fix.

**Faults 1 and 2 both involve the h1-to-h2 path.** Fault 2 kills it outright, so
the size-dependent fault 1 cannot be observed on that path at all until 2 is
fixed. `verify` tests large frames on three paths rather than one precisely so
fault 1 stays findable.

**Faults 3, 6 and 7 are the three with no symptom.** They are deliberately
spread across three different places (a border's egress policy, a spine's
overlay peering, a spine's underlay policy) and found by three different
methods (drain a border, compare spine session counts, count installed next
hops). There is no single command that finds all three, which is the point.

## Part C

**1 Monitoring for the latent three.**

- Fault 3: advertised-prefix count per eBGP session per VRF, alerting when a
  session that should carry N carries zero. "bleaf2 BLUE is advertising nothing"
  is a metric; "make sure backups work" is not.
- Fault 6: BGP session count per device compared against the expected topology,
  per address family. Not session state, session **count**, and per AFI, because
  the underlay session was up the whole time.
- Fault 7: installed next-hop count per remote VTEP per leaf, alerting below the
  expected fabric width. This also catches fault 1's cousin and most ECMP
  regressions.

All three are counts, and all three are compared against an expected value that
comes from the intended design rather than from yesterday's observation.
Baselining against yesterday would have accepted all three.

**2 Size-dependent failures.** The class is the PMTU black hole: handshakes
complete, small requests work, anything past the ceiling disappears. It is
reported as an application problem because every network test the reporter knows
how to run passes, and because it correlates with payload size rather than with
destination, which looks like an application behaviour.

Add to turn-up testing: a maximum-size test with DF set, end to end, in both
directions, on every path, as a pass/fail gate. One line, run once, catches a
class of fault that otherwise takes days to attribute.

**3 Structuring against masking.** Fix one thing at a time and re-verify after
each, which you will be tempted to skip. Keep a written list of every symptom
observed at the start, and tick a symptom off only when you can explain which
fix resolved it. A symptom that disappears without a fix you can name is a
symptom that was masked, and a fix that resolves fewer symptoms than you
expected means another fault is sitting underneath.

Record, as you go: the symptom, the hypothesis, the command that confirmed it,
the change, and what re-verify showed. That record is also your runbook entry
afterwards, which is the only reason anyone ever writes one.

**4 The isolation breach.** No availability monitoring catches it because
nothing became unavailable; something became *more* available. Availability
monitoring is built entirely around the question "can A reach B", and the answer
got better.

The check is a negative reachability test: a scheduled probe that asserts
specific pairs **cannot** reach each other, failing when they can. The same
shape as Lab 07's `matrix`. It needs an authoritative statement of what should
not talk to what, which most organisations do not have written down anywhere,
which is the real reason this class of fault survives for years.

**5 What "verified" means.** Something like: *"Verified means every configured
reachability and control-plane assertion passed. It does not mean the design is
intact: redundancy that is not currently carrying traffic was not exercised, and
no assertion tests that traffic which should be blocked still is."*

To make it mean more: add drain-and-test to the verification itself, so backups
are exercised rather than assumed, and add negative assertions so the absence of
reachability is checked as well as its presence. Both are things a script can do
and neither is something a human will remember to do at 2am.

**6 The runbook entry.** For fault 8, which is the one most people find last:

> **Symptom:** one host in a VRF cannot reach a destination; another host in the
> same VRF, behind a different leaf, can.
> **Check:** `show ip route vrf <vrf> <prefix>` on the leaf behind the failing
> host, and compare with `show ip bgp vrf <vrf> <prefix>` on the same device.
> **Cause if they disagree:** something with a lower administrative distance is
> winning. A static route has AD 1 and beats eBGP's 20.
> **Fix:** remove the static, or correct it.
> **Why it is missed:** the BGP table is correct, so checking BGP and stopping
> there confirms the wrong thing.
