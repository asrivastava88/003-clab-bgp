# BGP Lab 09: Convergence and Resiliency Engineering

**Level:** CCIE DC | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

An ordinary EVPN-VXLAN fabric. The subject is not whether it forwards, it is how long it takes to notice when something stops forwarding, and what you configure to shorten that.

Two things are different about this lab:

- **`verify` gives no hints.** It reports what it observed against what it expected, and nothing else. No config knob names, no "check X", no cause hypotheses. There is a separate `./lab.sh hint` if you want to be told.
- **`./lab.sh break` injects every fault at once.** Eight faults, all live, interacting. That is the CCIE troubleshooting-section shape and it is also what a real bad afternoon looks like. `break <n>` still exists for isolated practice.

## Topology

```
              +-----------+              +-----------+
              |  spine1   |              |  spine2   |      AS 65100 (shared)
              | 10.0.0.1  |              | 10.0.0.2  |
              +-----------+              +-----------+
                E1 E2 E3                   E1 E2 E3
      every leaf: Ethernet1 -> spine1, Ethernet2 -> spine2
    +--------+-------+--------------+--------------+
    |                |              |              |
+---------+    +---------+    +----------+   +----------+
|  leaf1  |    |  leaf2  |    |  bleaf1  |   |  bleaf2  |
|  65101  |    |  65102  |    |  65104   |   |  65105   |
|VTEP .11 |    |VTEP .12 |    | VTEP .14 |   | VTEP .15 |
+---------+    +---------+    +----------+   +----------+
    E3          E3     E4           E3 vrf RED      E3 vrf RED
    |           |      |      172.16.1.1/30    172.16.2.1/30
    h1          h2     h3            |               |
 v10 .101   v10 .102 v20 .103        E1              E2
                                  +-----------------------+
                                  |    wan    AS 65200    |
                                  | default to both, plus |
                                  |    203.0.113.0/24     |
                                  +-----------------------+

  Two spines, so every leaf has two underlay paths to every other leaf.
  Two borders, so every leaf has two default routes inside VRF RED.
  Whether it USES either pair is the question, and they are separate
  settings that people assume are one.
```

## The three failure classes

| Class | What happens | What detects it | Typical cost untuned |
|---|---|---|---|
| **Hard link failure** | carrier drops | the interface itself, immediately | near zero, **if** ECMP exists |
| **Grey failure** | carrier stays up, traffic disappears | only BFD. BGP will sit on its hold timer | up to the hold time, 180s by default |
| **Planned maintenance** | nothing is broken | nothing, because nothing failed | your own outage, self-inflicted |

The third one is the one people get wrong. A device that is about to be worked on should be drained first, so there is no failure to detect.

## The three knobs

| Knob | What it does | Where it lives |
|---|---|---|
| **BFD** | sub-second detection, independent of BGP | interface timers plus `neighbor ... bfd` |
| **BGP timers** | the fallback when BFD is absent or down | per peer group, negotiated to the lower of the two ends |
| **ECMP** | absorbs the failure so detection speed matters less | global **and** per-VRF, and they are separate settings |

BFD without ECMP means you detect fast and still drop traffic until the control plane reconverges. ECMP without BFD means you have a spare path and take three minutes to start using it. You need both, and the lab makes you measure the difference.

## Addressing

| Item | Value |
|---|---|
| Spine ASN | 65100, shared by both |
| Leaf ASNs | leaf1 65101, leaf2 65102, bleaf1 65104, bleaf2 65105; wan 65200 |
| Lo0 / Lo1 (VTEP) | leaf1 10.0.0.11 / 10.0.1.11, leaf2 .12 / .12, bleaf1 .14 / .14, bleaf2 .15 / .15 |
| Underlay P2P | 10.1.*spine*.x/31, spine even, leaf odd |
| WAN handoff | bleaf1 172.16.1.1/30 to wan .2; bleaf2 172.16.2.1/30 to wan .2 |

| VLAN | Subnet | L2VNI | Hosts |
|---|---|---|---|
| 10 | 10.10.10.0/24 | 10010 | h1 .101 (leaf1), h2 .102 (leaf2) |
| 20 | 10.10.20.0/24 | 10020 | h3 .103 (leaf2) |

VRF RED, L3VNI 50001. Internet test target 203.0.113.10.

## Modes

| Mode | What is configured | Use |
|---|---|---|
| `base` | The fabric forwards. Default 60/180 timers, **no BFD anywhere**, `maximum-paths 1`. Every failure is an outage. | Part A. Measure it before you fix it. |
| `solution` | BFD on every session, 3/9 timers as the fallback, ECMP globally and inside the VRF. | Part B onward, and the baseline the 8 faults regress from. |

Deploying `base` and running `./lab.sh measure grey` before you read anything else is the right way to start. The number you get is the reason the rest of the lab exists.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy base           # measure how bad untuned looks
./lab.sh measure grey          # then hard, wan, drain
./lab.sh deploy solution       # measure the same scenarios again
./lab.sh verify                # state checks, no hints
./lab.sh break                 # ALL 8 faults at once
./lab.sh verify                # watch the pass count as you fix them
./lab.sh hint                  # spoilers, if you want them
./lab.sh restore
./lab.sh destroy
```

RAM: 10 cEOS nodes, roughly 14 to 16 GB. Boot plus convergence takes 3 to 4 minutes.

**`./lab.sh measure <scenario>`** runs 150 pings at 200ms through a failure and prints the loss. Each lost packet is about 200ms of outage. Scenarios:

| Scenario | What it does |
|---|---|
| `hard` | shuts leaf1's Ethernet1, then unshuts |
| `grey` | 100% loss spine1 to leaf1 with carrier up, then clears |
| `wan` | shuts bleaf1's Ethernet3, then unshuts. With VRF ECMP this should cost nothing; without it, it is a reconvergence |
| `drain` | AS-path prepends spine1 away, then undoes it |

`drain` should cost you nothing. If it does, that is the lesson.

## The fault model

`./lab.sh break` injects all eight. They interact: two of them hide behind a third, and one of them is only visible on a device that is not reporting any problem. Fixing them in a sensible order matters, and working out that order from `verify` output alone is the exercise.

`./lab.sh verify` is your progress bar. The pass count climbs as you fix things. It will not tell you what to fix.

`./lab.sh reveal` tells you how many are still injected, not which ones.

## Files

```
bgp-lab09.clab.yml     topology
lab.sh                 deploy | verify | measure | grey | break | restore | hint | cli
configs/base|solution/ rendered configs (wan and hosts included)
tools/gen_configs.py   BFD_IFACE, BGP_TIMERS and ECMP at the top are the tuning
docs/TASKS.md          Part A measure, Part B tune, Part C the eight faults, Part D design
docs/HINTS.md          spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md      the answers
```

## Caveats

- **cEOS forwards in software, so absolute numbers are not hardware numbers.** The ratios are what matter: untuned grey failure against tuned grey failure is roughly 200:1 here and that ratio is real. Do not quote the milliseconds in a design document.
- `measure` uses `ping ... interval 0.2`. If your build rejects a sub-second interval, drop it and the comparison still holds at coarser resolution.
- The BFD timers here (300ms x 3) are a lab value. On real hardware with real control-plane load, start higher and come down with evidence.
- `grey` uses `containerlab tools netem`, which needs the kernel `sch_netem` module. Impairments apply as a complete set, so a flagless `netem set` clears them.
- Every node boots from its own `startup-config`. `./lab.sh restore` is the reset.

## Lab series

| Lab | Focus |
|---|---|
| 01 | eBGP Clos, EVPN L2/L3VNI, symmetric IRB, VRF-lite border, fusion routing |
| 02 | Dual-ISP edge: local-pref, MED, prepend, communities, RTBH, BFD |
| 03 | EVPN multihoming (ESI-LAG) vs MLAG |
| 04 | iBGP overlay, spine route reflectors, add-path, OSPF underlay |
| 05 | Unnumbered eBGP underlay, RFC 8950, IPv6 link-local peering |
| 06 | Pure BGP: multi-AS internet edge, the policy triangle, aggregation, leaks |
| 07 | Multi-VRF EVPN: RT leaking, fusion, and proving isolation |
| 08 | Multi-site EVPN DCI: gateways, next-hop rewrite, underlay containment |
| 09 | Convergence and resiliency: BFD, timers, ECMP, drain (this lab) |
| 10 | BGP security and scale: max-prefix, GTSM, RPKI concepts, policy frameworks |
| 11 | Mixed-vendor EVPN interop (scope to be agreed before building) |
