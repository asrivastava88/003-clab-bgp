# BGP Lab 18: Three Regions, Two Carriers, 38 Nodes — and the Day One Region Becomes Transit for the Other Two

**Level:** production fabric / WAN architect | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F ×38

Three regions, each a complete five-stage Clos of the kind Lab 17 built. Two independent DCI carriers. Twelve faults, several of which have their cause in one region and their symptom in another.

This is the first lab in the series sized for a real machine rather than a laptop: **38 nodes, 72 links, roughly 55 GB and 8–12 minutes to deploy.**

## The sentence the whole lab turns on

> Inside a region, the ASN plan prevents transit for free. Across regions, it does not.

Lab 17's result was that a shared ASN per tier makes a device physically incapable of becoming a transit path between its own peers — a route that tries to come back carries that tier's ASN and dies on loop detection. No filter involved.

Across regions that protection is gone, and it is gone for a specific and very ordinary reason: **you buy DCI from two different carriers.** A route from Ashburn arriving at Seattle via carrier A, re-advertised to carrier B, carries `65109 65500 65209`. Carrier B is AS 65600. It sees nothing of its own in that path, so it accepts it, and Seattle is now a transit path between Ashburn and London — across Seattle's own fabric, over Seattle's own paid circuits.

**Nothing in the numbering stops that. One route-map does.** Fault 1 removes it.

## Topology

```
                         wan1  AS 65500            wan2  AS 65600
                     (carrier A, no link)       (carrier B, no link)
                       /      |      \            /      |      \
         +------------+       |       +----------+       |       +--------+
         |                    |                          |                |
    wst-b1 wst-b2        est-b1 est-b2               eur-b1 eur-b2
      \     /              \     /                     \     /
     wst-ss1 wst-ss2      est-ss1 est-ss2            eur-ss1 eur-ss2     AS 651/652/653 00
       |  \  /  |            |  \  /  |                |  \  /  |
    p1-s1 p1-s2 p2-s1...  (same)                    (same)               one ASN per pod
      |  \/  |
    l1     l2   (x2 pods)                                                unique ASN per leaf

   Seattle 10.11.0.0/16     Ashburn 10.12.0.0/16     London 10.13.0.0/16
   anycast 10.100.0.0/24 originated once in every region
```

Both borders of every region face **both** carriers. The carriers have no link between them — they are competitors, and that is the point.

## Two levels of summarisation, two places to leak

| Boundary | Who originates | What leaves | Count at the far side |
|---|---|---|---|
| pod → super-spine | the pod's two spines | one **/17** per pod | a super-spine sees 0 server /24s |
| region → carrier | the region's two borders | one **/16** per region | a carrier sees 0 /24s **and** 0 /17s |

A carrier should hold three region aggregates and nothing finer. If it holds a /17, somebody's border is leaking a pod. If it holds a /24, something has gone very wrong two tiers down.

And an aggregate can now outlive its contents in **two** different places, three hops apart. One of the twelve faults is exactly that.

## The tools

| Command | What it answers |
|---|---|
| `./lab.sh regions` | inter-region AS paths, and whether any region appears in the middle of one |
| `./lab.sh transit` | advertisement discipline per role — a border announces exactly 2 prefixes |
| `./lab.sh table` | prefix count by tier, with /24 and /17 columns for both aggregation boundaries |
| `./lab.sh width` | installed next hops, every tier against every region |
| `./lab.sh anycast` | where each region's users land for a service that exists in all three |

`regions` is the one that matters:

```
  at     region            paths  any path with a region AS in the middle
  wan2   10.12.0.0/16          3  1
```

A region ASN followed by a carrier ASN in an AS path means that region re-announced what a carrier told it. **That is a route leak**, and at a region border it is the single most consequential thing that can go wrong.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy          # 8-12 minutes, ~55 GB
./lab.sh verify
./lab.sh regions         # save this
./lab.sh transit
./lab.sh table
./lab.sh width
./lab.sh anycast
./lab.sh break           # all 12
```

Resource note: 38 cEOS nodes at roughly 1.4 GB each. On 24 cores, BGP across three regions needs about 90 seconds to settle after a change, not the 45 the smaller labs needed. `restore` takes about a minute because it replaces the configuration of 38 devices.

## Rules

- `verify` reports observed versus expected. No hints.
- `./lab.sh break` injects all twelve at once. `break <n>` for isolated practice.
- **Faults 1 and 2 are a compound pair** — a leak that stays harmless until somebody else's filter goes wrong, which is how leaks become outages in production.
- Several faults have their cause in one region and their symptom in another. Bisect by tier and by region; at 38 nodes you cannot eyeball it.
- Exactly one fault takes a session down. The other eleven leave every session Established.
- `./lab.sh hint` exists.

## Caveats, and what this lab cannot teach

- **No overlay.** No EVPN, no VXLAN, no tenants. Labs 01, 07 and 08 cover that; this is the underlay and the WAN.
- **The carriers are one router each.** A real carrier is a continent with its own hot-potato behaviour, its own MEDs and its own policy, which is Lab 14's subject. Here each one is a single AS with a single best path, so the inter-region path selection is simpler than reality.
- **Two leaves per pod and two pods per region** is enough to make both aggregation levels real and not enough to make the super-spine radix question real. Lab 17's Part C covers what changes at eight pods.
- **No latency model.** Every link is equal cost, so inter-region path selection is decided by AS-path length alone. Adding netem would make `regions` a latency tool as well, and is worth doing yourself.
- **One loud fault.** Eleven of twelve are silent, which is the point of the series — but a real incident usually starts with something loud, and the skill of ignoring the loud thing to find the silent one is not exercised here.
- cEOS forwards in software, and at 38 nodes on 24 cores you will feel it during convergence.

## Files

```
bgp-lab18.clab.yml      topology, generated
lab.sh                  deploy | verify | regions | transit | table | width | anycast | break | ...
tools/gen_configs.py    one data model renders 38 configs, the topology and the peer map
tools/peers.sh          generated peer address map, so lab.sh never hardcodes an address
configs/solution/       the working fabric. There is no base mode.
docs/TASKS.md           Part A the design, Part B the twelve faults, Part C scale
docs/HINTS.md           spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md       the answers
```

## Lab series

| Lab | Focus |
|---|---|
| 01–11 | DC fabric, EVPN-VXLAN, multi-VRF, DCI, convergence, security, capstone |
| 12 | Rail-optimized AI/HPC fabric: no overlay, BGP to the host, ECMP width |
| 13 | Carriers, dark fibre, exchanges, cloud interconnect, long haul and subsea |
| 14 | Global backbone TE: hot potato, cold potato, MED, anycast |
| 15 | Dual-stack carrier edge: IPv4/IPv6 policy parity and graceful drain |
| 16 | The model is the network: generation, drift, and triage |
| 17 | Five-stage Clos: pods, super-spines, and the ASN plan |
| 18 | Three regions, two carriers, 38 nodes: region transit and double aggregation (this lab) |
