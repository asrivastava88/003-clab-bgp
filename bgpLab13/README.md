# BGP Lab 13: Carriers, Dark Fibre, Exchanges, Cloud Interconnect, Long Haul and Subsea

**Level:** carrier / interconnect architect | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F ×10, one Linux bridge

AS 65010 "NORTHSTAR" runs three sites and buys every kind of interconnect there is: metro dark fibre on its own optics, two long-haul waves, IP transit at two handoffs plus a third across a transpacific cable, two internet exchange ports, two PNIs to a CDN, and a redundant pair of cloud interconnects.

Everything is fictional. Peer space is `100.64.0.0/10`, which is reserved and never globally routed, standing in for real routable space so nothing here teaches you to filter the wrong thing. Our own space is RFC 5737 documentation prefixes standing in for /20s.

## What makes this lab different from 01–12

The previous twelve labs were all about the control plane. This one is about **the plant and the invoice**, and most of what matters is not in any router's configuration:

- **BGP does not know what a conduit is.** Two circuits from two carriers can be perfectly diverse in `show ip bgp` and share a duct under 4th Avenue. The only record of that is an inventory, so this lab ships one — `inventory/circuits.yml`, with conduits, subsea cables, landing stations, protection type, RTT and monthly cost — and a tool that correlates it against what you believe is diverse.
- **A 1+1 protected circuit hides a fibre cut from BGP completely.** The protection switch is sub-50ms. No session drops, no route withdraws, nothing alerts. The only signature is a latency step. `./lab.sh cut` reproduces exactly that.
- **Most peering mistakes cost money rather than causing outages.** Every destination in this lab is reachable through transit *and* through a peer. Which one wins is policy, and the symptom of getting it wrong is an invoice. `./lab.sh cost` prices the current state against the intended one in dollars per month.

## Topology

```
                     AS 65100 PACRIM transit                AS 65200 TRANSPAC
                       +--------------+                      +------------+
                       |   transit1   |                      |  transit2  |
                       +--------------+                      +------------+
                        E1          E2                             E1
           TRANSIT-1A  /              \  TRANSIT-1B          TRANSIT-2 |  subsea
                      /                \   "diverse"          95ms RTT |  TRANSPAC-1
                     /                  \                              |  $1.10/Mbps
     +--------------------+          +--------------------+------------+
     |       sea1         |  DF-SEA  |       sea2         |
     |  Westin, Seattle   |==========|  Tukwila           |
     |  10.255.0.1        | darkfibre|  10.255.0.2        |
     +--------------------+  0.4ms   +--------------------+
       E2   E3   E4    E6              E2  E3  E4      E6
       |    |    |      \ WAVE-A        |   |   |        \ WAVE-B
       |    |    |       \ 1+1, 65ms    |   |   |         \ unprot, 71ms
       |    |    |        \             |   |   |          \
       |    |    |         +-------------------------------->+------------+
       |    |    |                      |   |   |            |    ash1    |
       |    |    +----------------------|---|---+----------->| Ashburn VA |
       |    |      CLOUD-IC-A/B         |   |    cloudgw     | 10.255.0.3 |
       |    +---------------------------|---+--> cdn1        +------------+
       |           PNI-CDN-A/B          |         AS 65500
       |                                |
       +---------- ixfab (IX L2) -------+
                    |     |     |
                  ixrs ixpeer1 ixpeer2
                 65300  65401   65402
              route srv  RS-only  bilateral-only
```

### The interconnects, and why each one exists

| Circuit | Kind | Protection | RTT | Cost | Why |
|---|---|---|---|---|---|
| DF-SEA-001 | metro dark fibre, our optics | none | 0.4ms | $2,800/mo | our own metro, no carrier in the path |
| WAVE-SEA-ASH-A | long-haul wave, northern route | **1+1** | 65ms | $14,500/mo | the circuit we want internal traffic on |
| WAVE-SEA-ASH-B | long-haul wave, southern route | none | 71ms | $9,800/mo | diverse long haul, cheaper, no protection |
| TRANSIT-1A / 1B | IP transit, two handoffs | none | 0.2 / 0.6ms | $0.38/Mbps | primary transit, sold to us as diverse |
| TRANSIT-2 | IP transit over subsea | restorable | 95ms | $1.10/Mbps | backup, and reach into Asia |
| IX-PORT-A / B | internet exchange ports | none | 0.2 / 0.6ms | $1,200/mo each | free bits with peers |
| PNI-CDN-A / B | private interconnect | none | 0.1 / 0.7ms | $350 / $1,900/mo | the cheapest bits in the building |
| CLOUD-IC-A / B | cloud interconnect pair | none | 1.2 / 1.8ms | $1,650/mo each | private path to the cloud region |

### Peering policy: five numbers

The entire strategy is the local-pref hierarchy, and every route is tagged inbound with where it came from:

| Exit | Local-pref | Community | Marginal cost |
|---|---|---|---|
| cloud interconnect | 400 | 65010:400 | $0 (flat circuit) |
| PNI to the CDN | 300 | 65010:300 | $0 (flat cross connect) |
| internet exchange | 200 | 65010:200 / :201 | $0 (flat port) |
| IP transit, primary | 100 | 65010:100 | $0.38/Mbps |
| IP transit, transpacific | 90 | 65010:101 | $1.10/Mbps |

Inbound, every external session has a prefix filter built from what that peer is registered to announce — in production from IRR AS-SET expansion or RPKI, rebuilt nightly. Outbound, every external session gets our three prefixes and nothing else. `sea2` prepends twice toward transit1, so inbound traffic prefers `sea1` and therefore the protected wave to Ashburn.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy          # deploys, then applies the per-circuit latency model
./lab.sh verify          # clean baseline
./lab.sh routes          # read the inventory before you touch anything
./lab.sh srlg            # the fate-sharing audit. Start here.
./lab.sh exits           # where every traffic class leaves
./lab.sh cost            # what the current state costs per month
./lab.sh break           # all 8 faults
```

RAM: 10 cEOS nodes plus one Alpine container, roughly 14–15 GB. The IX fabric is a Linux bridge rather than an eleventh cEOS node, which is both what an exchange actually is and the reason this fits on one machine.

| Command | What it is for |
|---|---|
| `./lab.sh srlg` | audits every pair you believe is diverse against the conduit and cable data |
| `./lab.sh srlgs` | every shared-risk group, widest blast radius first |
| `./lab.sh cut <SRLG>` | cuts one group. Unprotected circuits drop; 1+1 circuits survive with a latency step. |
| `./lab.sh uncut` | restores everything and reapplies the baseline latency |
| `./lab.sh exits` | per-destination exit class, per site |
| `./lab.sh cost` | prices the current exits against the intended ones |
| `./lab.sh latency` | measured RTT against the inventory |
| `./lab.sh routes` | circuits by kind, with cable, landing station and protection |

## Transport background the lab cannot configure

A container has no optics, so none of the following is in any config file. All of it is in Part C.

### DWDM

The C-band runs roughly 1530–1565nm, about 4.4 THz of usable spectrum. On the ITU-T G.694.1 fixed grid at 50 GHz spacing that is around 80 channels, or about 96 across the extended C-band; at 100 GHz, half that. Flexgrid defines 12.5 GHz slices instead, so a carrier can be 37.5, 75 or 150 GHz wide and you size the slot to the baud rate rather than forcing the signal into a fixed channel.

What decides reach is **OSNR**, not loss. Single-mode fibre is about 0.2 dB/km at 1550nm, so an 80–100 km span is a 20–25 dB budget, and every EDFA you use to recover that loss adds its own noise — a typical amplifier noise figure is around 5 dB. Modulation is the lever: DP-QPSK buys reach at the cost of spectral efficiency, 16QAM the reverse. That is why a 400G wave runs 16QAM across a metro and QPSK on 75 GHz across a continent. Chromatic dispersion, about 17 ps/nm/km on G.652 fibre, used to need dispersion-compensating modules; coherent DSPs correct it electronically, which is why those modules disappeared.

400ZR (an OIF spec) put a tunable DWDM coherent 400G interface into a QSFP-DD at around 80–120 km, and OpenZR+ extends that to hundreds of km with stronger FEC. Together with a dark fibre IRU that is what makes `DF-SEA-001` in this lab realistic: your own transponder, your own wave, somebody else's glass. Doing the same thing on a carrier's *line system* is an **alien wavelength**, and the catch is commercial rather than technical — the line-system owner will not warrant performance, so the OSNR budget becomes yours to prove.

A ROADM's **degree** is how many line directions it has, and a colourless/directionless/contentionless design removes the restrictions on which wavelength can be added or dropped where. It is also where a surprising amount of stranded capacity comes from.

### Subsea

Light travels at about 4.9 µs per kilometre in fibre (n ≈ 1.47). A 9,100 km cable is therefore roughly 45 ms one way and 89 ms round trip before any terminal or backhaul, which is where this lab's 95 ms figure for `TRANSIT-2` comes from. You cannot engineer around that number; you can only decide which side of the ocean your content lives on.

The wet plant is repeaters every 50–100 km, powered from both shore ends over a conductor in the cable, with branching units where a cable serves more than two landings. The dry end is SLTE at the cable landing station. Capacity is sold as whole fibre pairs, as spectrum, or as managed capacity, and modern cables favour many pairs at lower power each (space division multiplexing) over fewer, harder-driven pairs.

The operational fact that matters: **a subsea repair needs a cable ship**, and between mobilisation, weather and permits that is typically one to several weeks, not hours. This is why subsea capacity is bought on two cables — and why the diversity question is not "two cables?" but "**two landing stations?**" Two cables into one CLS share the beach manhole, the terrestrial backhaul and often the power.

### Fibre route analysis

Ask the carrier for the route, not for the diversity checkbox. What you want is GIS or KMZ route data for both circuits, overlaid, looking for the places where physical diversity actually fails:

- the building entrance facility and the single conduit into it
- the meet-me room, which is one room
- bridge, railway and river crossings, where every carrier in the region shares the one structure
- the manhole outside the building
- long-haul routes that follow the same interstate

Then two things nobody plans for. **Carrier mergers destroy diversity retroactively** — two circuits from two carriers quietly become one carrier's circuits, and often one route. And **diversity decays**: a relocated duct or a repaired span can move a route without anyone telling you. Re-validate annually and after every carrier acquisition.

### Peering strategy

Settlement-free peering is a negotiation, not a protocol. Published requirements commonly include a traffic ratio (often around 2:1), a minimum traffic volume, geographic coverage, and peering at several facilities; PeeringDB is where policies (open, selective, restrictive) and facility presence are published. Below the threshold the options are paid peering, partial transit, or an IX port and whoever will peer there.

The economics are what decide it. Transit is priced per Mbps and falls over time. An IX port and a PNI are fixed, so their cost per Mbps falls as your traffic grows — which makes the real question a break-even: at what volume does a $1,200/mo port beat $0.38/Mbps? A route server solves the N² session problem at an exchange and is how you reach the long tail; bilateral sessions are what peers with selective policies require and what you need for per-peer policy. MANRS is the baseline hygiene expectation: filter your customers, filter your peers, do not spoof, keep your IRR and RPKI records accurate.

### Cloud interconnect

Private peering to a cloud region is plain eBGP over a pair of circuits, and the parts people get wrong are consistent: the provider advertises only its own prefixes and will not transit between your two circuits, so the pair is not a path between your own sites; MTU on private peering is 1500; you must not advertise a default or your transit routes to it; and the provider's communities carry region and scope, which is what you steer on. The redundancy question is never "do we have two circuits" — it is **whether the two land on the same provider edge device in the same facility.** In this lab they do, and `./lab.sh srlg` says so.

## Rules

- `verify` reports observed versus expected. No hints.
- `./lab.sh break` injects all eight at once. `break <n>` for isolated practice.
- All eight faults leave every BGP session Established. Four leave every
  destination reachable as well; their only symptoms are latency, circuit
  utilisation, inbound path and risk posture.
- Three faults do break reachability for part of the address space, because
  the transits here blackhole third-party prefixes. In production those three
  would be pure cost, which is the more dangerous version.
- `./lab.sh hint` exists.

## Caveats, and what this lab cannot teach

- **No optics, so no DWDM.** No OSNR, no spans, no amplifiers, no ROADMs, no channel plan. The circuits are veths with netem delay. Everything in the DWDM section above is Part C reading, not something you can configure here.
- **The route server prepends its own ASN.** A real IXP route server is transparent: it does not insert itself into the AS path and it preserves the original next hop. I could not confirm an EOS equivalent for that behaviour on 4.36, so rather than ship a guess the route server here behaves like an ordinary eBGP speaker with `next-hop-self`. Part C question 20 is about what that difference costs you in filtering.
- **The transits blackhole third-party space.** `transit1` and `transit2` originate other networks' prefixes to `Null0` so the peering comparison is real, which means a wrong exit sometimes shows up as unreachable rather than merely expensive. That is a lab artefact, and a useful one: it turns an invoice into a ping.
- **`100.64.0.0/10` is deliberately absent from the bogon list,** because in this lab it stands in for routable space. In production it belongs there. Part C question 23.
- **The cost model is a sketch.** Flat $/Mbps on a 95th-percentile commit, flat MRC on everything else. Real transit contracts have commits, tiers, overage rates and burst terms, and real IX ports have cross-connect fees.
- cEOS forwards in software, so the latency you measure is netem plus whatever the container feels like.

## Files

```
bgp-lab13.clab.yml       topology, extended link format with per-handoff MTU
lab.sh                   deploy | verify | exits | cost | srlg | cut | latency | break | ...
inventory/circuits.yml   the physical and commercial plant. The point of the lab.
tools/transport.py       SRLG correlation, cut planning, cost model
tools/gen_configs.py     one data model renders all ten configs
configs/solution/        the working network. There is no base mode.
docs/TASKS.md            Part A analysis, Part B the eight faults, Part C design
docs/HINTS.md            spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md        the answers
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
| 13 | Carriers, dark fibre, exchanges, cloud interconnect, long haul and subsea (this lab) |
