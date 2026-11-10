# BGP Lab 14: Global Backbone Traffic Engineering — Hot Potato, Cold Potato, MED and Anycast

**Level:** backbone / peering architect | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F ×8

AS 65010 is a global content network with four PoPs on a ring. One transit AS peers with it at all four, a CDN peers at two, and a European network at one.

Lab 13 was about the plant and the invoice. This one is about the other half of the domain: **who carries the traffic, and for how many milliseconds.** Every circuit here is healthy. Every session stays up through every fault. What changes is whose backbone pays.

## One idea runs through the whole lab

**MED is milliseconds of somebody's backbone.**

The ring costs are the netem delay, the OSPF cost, and the MED — the same number used three times — so every value in `show ip bgp` traces back to the fibre:

```
       sea ----65ms---- ash ----75ms---- lhr ----160ms---- sin
        |                                                   |
        +---------------------175ms-------------------------+

  shortest paths:  sea->lhr 140 via ash     ash->sin 235 via lhr
```

When Singapore announces the EMEA prefix with MED 160, it is saying: *if you hand this traffic to me, I will carry it 160ms across my own backbone to London.* When the transit announces its European eyeballs to us at Seattle with MED 140, it is saying the same thing in reverse. Reading MED this way makes the whole lab arithmetic rather than lore.

| `./lab.sh dist` | our backbone, all-pairs, RTT ms |
| `./lab.sh med` | the MED we announce per PoP per prefix |
| `./lab.sh gttmed` | the MED the transit announces to us per handoff |

## Topology

```
                 AS 65100, one transit, four handoffs
        +------------------+  70ms  +------------------+
        |      gttw        |========|      gtte        |
        | Seattle/Singapore|        | Ashburn/London   |
        +------------------+        +------------------+
          E1          E2              E1          E2     E4
          |           |               |           |      |
      1500|       1500|           1500|       1500|      | AS 65400
          |           |               |           |      | peereu
   +------+----+ +----+------+ +------+----+ +----+------+  (also a
   |   sea     | |   sin     | |   ash     | |   lhr     |--+ transit
   | 10.255.0.1| |10.255.0.4 | |10.255.0.2 | |10.255.0.3 |    customer)
   +-----------+ +-----------+ +-----------+ +-----------+
        |   \\         |  \\          |              |  |
        |    \\175ms   |   \\160ms    |65ms      75ms|  | PNI
        |     \\       |    \\        |              |  |
        +------\\------+-----\\-------+--------------+  |
                \\            \\                        |
                 \\            +---- cdn AS 65300 -----+
                  +----------------- (PNI at lhr and sin)

   our prefixes          home    announced from
   192.0.2.0/24          -       all four PoPs, MED 0 (anycast)
   198.51.100.0/24       sea     all four, MED = ms to sea
   203.0.113.0/24        lhr     all four, MED = ms to lhr
   198.18.0.0/24         sin     all four, MED = ms to sin
   198.18.1.0/24         sin     sin only, to the transit only, no-export
```

### Local-pref: three numbers

| Exit | Local-pref | Marginal cost |
|---|---|---|
| CDN private interconnect | 200 | free |
| European peer | 200 | free |
| global transit | 100 | paid |

Inbound from the transit we **keep their MED** rather than zeroing it. That is a decision, not a default, and it is the single most consequential line of policy in the lab: it makes us do cold potato, carrying their traffic across our backbone to the exit nearest its destination. `./lab.sh gttmed` shows what we agreed to carry.

## Hot potato against cold potato

The same prefix set, seen two ways:

- **Hot potato** — dump traffic at the nearest exit and let the other network carry it. Cheapest for you, worst for the destination's latency, and you lose control of the path.
- **Cold potato** — carry it across your own backbone to the exit nearest the destination. Costs you backbone, buys you a shorter path for the user and control over where the traffic goes.

Neither is right. `./lab.sh potato` prints every flow, classifies it, and totals the backbone milliseconds you are carrying:

```
  from   destination          exit      our ms  classification
  lhr    100.150.0.0/16       sin          160  cold potato, carried 160ms to Singapore
  sin    100.200.0.0/16       sin            0  hot potato, nearest exit
  sea    100.120.0.0/16       lhr          140  cold potato, carried 140ms to London
```

That last line is the trade in one row: 140ms of our own backbone to reach a **free** peer, rather than 0ms to reach **paid** transit. Whether that is correct is Part C, not Part B.

## Inbound is the half you cannot see

Your local-pref decides where traffic leaves. Where it *enters* is decided by the MED and AS path you announce — and only if the other side honours them. `./lab.sh inbound` looks at your own prefixes from four external vantage points:

```
  our prefix           gttw         gtte         cdn          peereu
  192.0.2.0/24         2 entries    2 entries    2 entries    lhr
  198.51.100.0/24      sea          via-gttw     lhr          lhr
  203.0.113.0/24       via-gtte     lhr          lhr          lhr
  198.18.1.0/24        via-gttw     via-gttw     absent       absent
```

`via-gtte` means the transit is hauling the traffic across *its* backbone to reach the handoff our MED asked for. That is them doing cold potato on our behalf, which is exactly what a MED buys when somebody honours it.

## Anycast behaves backwards, and that is correct

The anycast prefix is announced with **MED 0 from all four PoPs**, deliberately. Equal MED means the upstream cannot prefer one entry point, so it load-shares and every source enters at the handoff nearest *itself*. For anycast that is the right answer — it is hot potato, and hot potato is what anycast wants.

So a unicast prefix should show **one** entry point per vantage, chosen by MED; the anycast prefix should show **as many as that vantage has handoffs**. `./lab.sh anycast` prints both, and a `1` where there should be a `2` means a whole region stopped receiving anycast traffic while every check of reachability still passed.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy
./lab.sh verify          # clean baseline
./lab.sh dist            # the ring. Learn it before anything else.
./lab.sh med; ./lab.sh gttmed
./lab.sh potato          # save this
./lab.sh inbound         # save this too
./lab.sh anycast
./lab.sh latency
./lab.sh break           # all 8 faults
```

RAM: 8 cEOS nodes, roughly 11–12 GB.

## Rules

- `verify` reports observed versus expected. No hints.
- `./lab.sh break` injects all eight at once. `break <n>` for isolated practice.
- **All eight faults leave every BGP session Established and every OSPF adjacency full.** Nothing goes down. Nothing pages.
- Four of the eight are invisible in your own routing table. Two of those are visible only from outside your AS.
- `./lab.sh hint` exists.

## Caveats, and what this lab cannot teach

- **The transit is two routers, not a continent.** `gttw` fronts Seattle and Singapore, `gtte` fronts Ashburn and London, with one 70ms link between them. Their per-handoff MEDs are generated from the same ring model as ours, so the MED arithmetic is faithful; their internal path selection is not. A real transit has dozens of PoPs and its own hot-potato behaviour at each.
- **No traffic, so no congestion.** `potato` totals backbone milliseconds, not gigabits. The real cold-potato decision is made on capacity and cost per bit on each span, and that needs flow data this lab has no way to produce.
- **Only one transit AS.** MED is comparable only between paths from the same neighbouring AS, which is why this topology has one transit at four handoffs. Comparing MEDs across different ASes needs `always-compare-med`, whose behaviour and risks are Part C question 28 rather than shipped config — I would not put that knob in a lab without verifying it on the exact target release.
- **The transits blackhole third-party space.** Each transit router originates its customers' prefixes to `Null0` and holds a test host inside each, so a wrong exit sometimes shows up as unreachable rather than merely slow. That is a lab artefact, and a useful one.
- **Anycast here is BGP-only.** No health checking, no withdrawal on service failure, no DNS steering layer. In production the interesting anycast failures are all in that machinery.
- **No RPKI, no IRR.** Lab 13 covered prefix hygiene; this lab assumes it and concentrates on path selection.
- cEOS forwards in software, so measured latency is netem plus whatever the container feels like.

## Files

```
bgp-lab14.clab.yml      topology, extended link format with per-span MTU
lab.sh                  deploy | verify | potato | inbound | anycast | latency | break | ...
tools/topology.py       the ring, the MED plans, and the hot/cold-potato classifier
tools/gen_configs.py    one data model renders all eight configs
configs/solution/       the working network. There is no base mode.
docs/TASKS.md           Part A analysis, Part B the eight faults, Part C design
docs/HINTS.md           spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md       the answers
```

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
| 09 | Convergence and resiliency: BFD, timers, ECMP, drain |
| 10 | BGP security at an internet edge: bogons, hijacks, leaks, loops |
| 11 | Capstone: eight faults that do not announce themselves |
| 12 | Rail-optimized AI/HPC fabric: no overlay, BGP to the host, ECMP width |
| 13 | Carriers, dark fibre, exchanges, cloud interconnect, long haul and subsea |
| 14 | Global backbone TE: hot potato, cold potato, MED, anycast (this lab) |
