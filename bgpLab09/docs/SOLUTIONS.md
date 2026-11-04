# Lab 09 Solutions (spoilers)

Reference configs: `configs/solution/` tuned, `configs/base/` untuned.

## Part A

Expected shape of the numbers in `base` mode. Yours will vary; the ratios should not.

| Scenario | Packets lost | Roughly | Why |
|---|---|---|---|
| `hard` | a handful | under a second | carrier loss is detected by the interface. The session drops immediately. |
| `grey` | **all of them** | the ping ends first | nothing is watching. BGP waits out the 180s hold timer. |
| `wan` | a handful | under a second | carrier loss again |
| `drain` | a handful to tens | seconds | the prepend works, but there is only one path installed to fall back to |

**A2 The real `grey` number.** The ping is 150 packets at 200ms, so 30 seconds. The hold timer is 180 seconds. Traffic is black-holed for the full hold time, so the honest number is roughly 180 seconds, or about 900 packets' worth. The measurement window is deliberately shorter than the outage, because watching it tick past the end of the ping is more memorable than a number.

**A3 Why `hard` and `grey` differ.** The traffic outcome is identical: packets sent toward spine1 are lost. The difference is entirely in what *notices*. A carrier drop is a physical-layer event delivered to the interface, which tears the session down and withdraws the routes in milliseconds. A grey failure produces no event at all; every layer believes the link is fine. BGP's only clue is that keepalives stopped arriving, and it is contractually obliged to wait the full hold time before acting.

**A4 Why `drain` still costs.** The prepend works exactly as intended: spine1's advertisements become less attractive and the leaves re-run best path. But with `maximum-paths 1` there is only one path installed in the FIB at any moment. The drain does not shift traffic onto a path that is already there; it forces a withdrawal and a reinstall. That is a FIB update, not a failover, and you pay for it.

### Answers

**Q1 Detectors.** `hard` is detected by the interface's link state, which is a physical event. `grey` has no detector in `base` mode, because BFD is what detects it and BFD is not configured. The only remaining mechanism is BGP's hold timer, which is not a detector so much as a timeout.

**Q2 The uninstalled path.** It is in BGP. `show ip bgp 10.0.1.14` shows both paths with one marked best. It is not in the FIB; `show ip route 10.0.1.14` shows one next hop. For the second to be used, the first has to be withdrawn, best path has to re-run, and the FIB has to be reprogrammed. Three steps that take time, all of which ECMP would have skipped entirely because the second path was already installed.

**Q3 Where 180 comes from.** RFC 4271 suggests a default hold time of 90 seconds; most vendors ship 180 with a 60-second keepalive, maintaining the 3:1 ratio. The relationship is that the hold timer is reset on every keepalive, so with a 3:1 ratio you tolerate two lost keepalives before declaring the peer dead. The ratio matters more than the absolute values: 3/9 keeps the same tolerance at 20x the speed.

**Q4 Why the prepend did not help.** See A4. A prepend changes which path is *best*; it does nothing about which paths are *installed*. With one installed path, making it less preferred means removing it and installing another, and the gap between those two events is your outage.

## Part B

### The tuned configuration

Interface, on every fabric link and the WAN link:
```
interface Ethernet1
   bfd interval 300 min-rx 300 multiplier 3
```
BGP, on every peer group that carries the underlay, on **both** ends:
```
router bgp <asn>
   maximum-paths 4 ecmp 4
   neighbor UNDERLAY bfd
   neighbor UNDERLAY timers 3 9
```
And inside the VRF, which the global `maximum-paths` does not cover:
```
   vrf RED
      maximum-paths 4 ecmp 4
```
And the edge session, which is not in the UNDERLAY peer group:
```
   vrf RED
      neighbor 172.16.1.2 bfd
      neighbor 172.16.1.2 timers 3 9
```

### Expected numbers after tuning

| Scenario | base | solution |
|---|---|---|
| `hard` | a handful | 0 to 1 |
| `grey` | ~180s | ~1s (3 x 300ms) |
| `wan` | a handful | 0 to 1 |
| `drain` | seconds | 0 |

The `grey` row is the headline: roughly 200:1. That ratio is the entire argument for BFD and it is the one number worth remembering from this lab.

### Answers

**Q5 Each knob alone.** BFD without ECMP: you detect the failure in 900ms and then wait for best path to re-run and the FIB to be reprogrammed, because there was no second path installed. Fast detection, slow recovery. ECMP without BFD: the second path is already in the FIB and would carry traffic immediately, but nothing tells the box to stop using the dead one, so it keeps hashing half the flows into a black hole for 180 seconds. Instant recovery that never starts.

**Q6 Justifying 300ms x 3.** In this lab it gives ~900ms detection, which is fast enough to see clearly against a 200ms ping interval and slow enough that software forwarding in containers does not produce false positives. On hardware, what you deploy depends on whether BFD runs in the forwarding ASIC or on the CPU. Hardware-offloaded BFD at 50ms x 3 is routine. Software BFD at those numbers on a box with 120 sessions will give you flaps under control-plane load, and a BFD flap takes the session with it, which is worse than the failure you were trying to detect. Start at 300ms x 3, watch for flaps for a few weeks, and come down with evidence.

**Q7 Negotiation.** The lower of the two proposed hold times wins. If you set 9 and the far end says 180, the session runs at 9, so a change on your own side does improve your detection. The catch is the reverse direction: your neighbour's keepalive interval is derived from its own configuration, so you can shorten *your* tolerance without the far end sending any faster. In practice both ends should be configured, and on a session you do not control, BFD is the better tool precisely because it does not depend on the far end's BGP configuration being sane.

**Q8 Why draining is different.** A drain is a planned, reversible preference change made while every path is still healthy. Nothing fails, nothing is withdrawn, and the FIB already contains the alternative because ECMP installed it. Traffic shifts as soon as the new best path propagates, with no detection step at all, because there is nothing to detect. A failure is the opposite: unplanned, detected after the fact, and recovered by installing something that was not there. If your drain costs packets, you do not have the redundancy you think you have, and you just found out during a maintenance window instead of during an incident.

## Part C: the eight faults

Order matters. Faults 3 and 4 remove path redundancy, which makes every other symptom worse and some of them invisible. Fix redundancy first, then detection, then timers.

**Fault 1 — leaf1 has no BFD on its underlay peer group.**
Observed: leaf1 reports 0 BFD peers Up where its neighbours report 2 or 3. Its sessions are Established and its hold time is still short.
Fix: `neighbor UNDERLAY bfd` under `router bgp 65101`.
Effect: `measure grey` on leaf1's path falls back to the BGP hold timer. With 3/9 that is 9 seconds rather than 180, which is survivable and therefore easy to miss. This is the fault that teaches you that "we have short timers so BFD is optional" is wrong by an order of magnitude.

**Fault 2 — leaf2's underlay timers reverted to default.**
Observed: leaf2's negotiated hold time toward the spines is 180 where every other leaf shows 9.
Fix: `neighbor UNDERLAY timers 3 9`.
Effect: invisible while BFD is working, because BFD fires first. It only shows up when BFD is also broken on that path, which is exactly the compound failure faults 1 and 7 set up. Defence in depth means the second layer is silent until you need it, which is also why it rots.

**Fault 3 — leaf1 has `maximum-paths 1` globally.**
Observed: leaf1 installs one underlay next hop to 10.0.1.14 where two exist in BGP.
Fix: `maximum-paths 4 ecmp 4` under `router bgp 65101`.
Effect: every failure involving leaf1 becomes a reconvergence event rather than a hash change. Fix this before chasing any timing symptom, because it changes the shape of every other measurement.

**Fault 4 — leaf2 has `maximum-paths 1` inside VRF RED.**
Observed: leaf2's global setting is correct and the default route in VRF RED resolves via one VTEP where two borders are advertising one.
Fix: `maximum-paths 4 ecmp 4` under `vrf RED`.
Effect: the overlay version of fault 3, and the one people miss because the global setting looks right. `maximum-paths` is per address family and per VRF. Checking the global value tells you nothing about the VRF.

**Fault 5 — bleaf1's WAN session has no BFD.**
Observed: bleaf1 reports 2 BFD peers Up where the topology has 3, and bleaf2 reports 3. The missing one is the edge session, not a fabric session.
Fix: `neighbor 172.16.1.2 bfd` under `vrf RED`.
Effect: `measure wan` degrades to the hold timer on a grey failure toward the provider. The edge is not in the UNDERLAY peer group and does not inherit anything from it, which is the general lesson: tuning applied to a peer group covers that peer group and nothing else.

**Fault 6 — spine2's BFD interval raised to 3000ms.**
Observed: spine2's BFD peers are Up and healthy. The negotiated interval is 3000 where every other device shows 300.
Fix: `bfd interval 300 min-rx 300 multiplier 3` on spine2's Ethernet1 and Ethernet2.
Effect: detection on every session through spine2 drops to ~9 seconds. `show bfd peers` says Up, which is the trap. BFD being up tells you it is running, not that it is running fast enough. Alert on the negotiated interval, not just on state.

**Fault 7 — leaf2's BFD multiplier raised to 50.**
Observed: leaf2's BFD interval is correct at 300ms and the multiplier is 50, giving ~15 seconds detection.
Fix: multiplier back to 3.
Effect: the sibling of fault 6 and harder to spot, because the interval is the number people look at. Detection time is interval x multiplier and both halves matter. Together with fault 2, this is the compound case: BFD slow *and* timers long on the same device.

**Fault 8 — spine1 has no BFD on its underlay peer group.**
Observed: spine1 reports 0 BFD peers Up. Every leaf reports one fewer than expected.
Fix: `neighbor UNDERLAY bfd` under `router bgp 65100`.
Effect: BFD is a two-ended protocol and a session needs both ends configured. The device reporting the shortfall is every leaf; the device with the problem is spine1. This is the one that is only visible from somewhere other than where it lives, and it is why collecting the full table before changing anything pays for itself.

### What the compound failure looks like

With all eight live, the honest diagnosis order is:

1. **Redundancy first** (3, 4). Until both paths are installed, every timing measurement is measuring the wrong thing.
2. **Detection presence** (1, 5, 8). Count BFD peers on every device and compare against the topology. The shortfalls point at both ends of each missing session.
3. **Detection quality** (6, 7). Everything is Up. Read the negotiated numbers.
4. **Fallback** (2). Last, because it is silent until the layers above it are right.

Doing it in the other order means re-measuring after every change and chasing symptoms that move.

## Part D

**1 BFD on 120 leaves.** Propose 300ms x 3 if BFD is hardware-offloaded on the platform, 1000ms x 3 if it is not. The control-plane cost you are accepting is one BFD session per BGP session, each generating a packet every interval in both directions: at 300ms and two uplinks per leaf, that is about 7 packets per second per leaf and 800 per second arriving at each spine, which is nothing for the ASIC and is not nothing for a CPU if BFD runs there.

Roll out: one leaf pair first, left for a week under production load, watching specifically for BFD flaps rather than for improved convergence. Then a rack, then a row. Change one variable at a time and never deploy BFD and a timer change in the same window, because when something flaps you will not know which caused it.

**2 BFD rather than aggressive BGP timers.** Three reasons. BFD is a purpose-built, lightweight hello protocol that can be offloaded to hardware; BGP keepalives are TCP messages processed by the BGP daemon, so aggressive BGP timers consume control-plane CPU proportional to session count and are the first thing to suffer when the CPU is busy, which is exactly when you need them. Second, BFD failure is decoupled from BGP state, so a BFD flap can be damped or ignored independently, while a BGP hold expiry tears down the session and discards all its routes. Third, BFD is shared: one BFD session can serve BGP, OSPF and static route tracking at once, where per-protocol timers multiply.

Leave BGP timers moderately short, say 10/30, as a fallback for when BFD itself is misconfigured or unsupported. That is the fault-2 lesson.

**3 Hardware versus software BFD.** Find out by reading the platform's documented scale numbers for BFD sessions and minimum interval, which differ sharply between the two, and by asking the vendor directly for the minimum supported interval at your session count. Then verify empirically: load the control plane and watch for flaps at your intended timers.

If the answer is "software on the uplinks," raise the interval until it is stable with margin, probably 1000ms x 3 giving 3-second detection, and compensate elsewhere: make sure ECMP is installed everywhere so a 3-second detection costs you a hash change rather than an outage, and consider whether link-state-based detection on point-to-point fibre gets you most of the benefit without BFD at all.

**4 Taking a spine out of service.**

Before touching anything: confirm every leaf currently has two installed underlay next hops, not just two sessions. Confirm the other spine has capacity for the full load. Confirm there is no existing fault that is already consuming your redundancy, which is precisely what faults 3 and 4 in this lab are.

Drain: apply an outbound AS-path prepend on the spine toward all its underlay neighbours. Do not shut anything.

Verify the drain: on at least two leaves, confirm the spine being drained is no longer a best path and that traffic counters on its interfaces have fallen to control-plane levels. Confirm every leaf still has a path. Confirm no session dropped.

Only then: do the work. Reload, upgrade, whatever it is.

Return: remove the prepend, confirm sessions re-establish and BFD comes up, confirm two installed next hops on the leaves again, confirm traffic counters recover. Leave it under observation before declaring the window closed.

The two steps people skip are the pre-check that redundancy actually exists, and the post-drain verification that traffic really moved rather than just that the config applied.

**5 Three things session-state monitoring misses.**

- **Path count.** A session can be Established while `maximum-paths 1` means you have no redundancy at all. Faults 3 and 4. Add a metric for installed next hops per prefix on a known set of destinations, and alert when it drops below the expected count.
- **Detection quality.** BFD Up at a 3000ms interval is not the same as BFD Up at 300ms. Faults 6 and 7. Alert on the negotiated interval and multiplier, not on state.
- **Detection presence asymmetry.** A missing `neighbor bfd` on one end means no BFD session at all, and the end reporting the shortfall is the other one. Fault 8. Alert on BFD session count per device against the expected topology, which catches it on whichever side you look.

A fourth worth having: negotiated hold time, which catches fault 2 and costs nothing to collect.

**6 Explaining grey failure to a non-network audience.** When a cable is unplugged, the equipment at both ends knows instantly, the same way you know when you hang up a phone call. The network reroutes in milliseconds because it was told.

A grey failure is the call staying connected while nobody can hear anything. Every indicator says the line is up. The equipment has no reason to think otherwise, so by default it waits three minutes of silence before concluding the other end has gone away, and traffic is discarded for that entire time.

The fix is to add a heartbeat: a small, constant exchange between the two ends whose absence is itself the alarm. That turns a three-minute silent failure into a one-second detected one. It costs a small amount of continuous traffic and some configuration on every link, and it is the difference between an incident customers notice and one they do not.
