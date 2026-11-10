# BGP Lab 16: The Model Is the Network — Generation, Drift, and Which Side Is Wrong

**Level:** network automation architect | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F ×8

AS 65010 runs three regions, two routers each, on two planes, with route reflectors, a transit at two sites and a settlement-free peer at one.

None of it is configured by hand. **Every address, ASN, interface assignment, IGP cost and policy value in this lab is computed** from `model/network.yml` and `model/policy.yml`. The topology file is an output of the model too. A human chooses exactly two numbers per device — the region id and the router id — and everything else follows.

## What is actually new here

Labs 11 through 15 each ended at the same place from a different direction: the faults that survive are the ones where nothing changed state, and the thing that finds them is a structural audit against intent. This lab makes that the subject.

So the deliverable skill is not "find the fault". It is **triage**:

> `./lab.sh audit` reports that the model and the network disagree. It cannot tell you which side is wrong.

Six of the eight drifts are the network having moved away from the model — somebody made a CLI change. **Two are the model having moved away from the network**, and for those the correct action is the opposite one. They produce findings that look exactly like the other six. Deciding correctly is the lab.

```
  wst-r2
    ADDRESSING      Loopback0 is 10.1.0.22/32; the model computes 10.1.0.2/32
                    from 10.{R}.0.{N}/32 with R=1, N=2
    INTERFACE       Ethernet4 is absent; the model assigns it to peer1 (link 13)
```

One of those two findings means *fix the router*. The other means *fix the model*. Nothing in the output says which.

## Algorithmic addressing

The rules, in full:

| Rule | Value |
|---|---|
| `loopback4` | `10.{R}.0.{N}/32` |
| `p2p4` | `10.254.{L}.0/31` |
| `router_id` | the loopback |
| `interface_order` | backbone links sorted by the far end's name, then external links |
| `ospf_cost_intra` | 10 |
| `ospf_cost_inter` | the measured RTT, in ms |
| `route_reflector` | r1 of every region |

`{R}` is the region id, `{N}` the router id, `{L}` the link id. `./lab.sh addresses` prints the result and the rules side by side:

```
  device     rgn  region id  router id  loopback         originates
  wst-r1     wst  1          1          10.1.0.1/32      198.18.1.0/24    RR
  est-r2     est  2          2          10.2.0.2/32      198.18.2.0/24
```

Three properties follow, and they are the reason hyperscalers do it this way:

- **You can read an address.** `10.3.0.2` is region 3, router 2 — London, the RR client. No IPAM lookup, no spreadsheet.
- **Link ids are stable under append.** Adding a region does not renumber anything that already exists, because ids are assigned in model order and the model only ever grows at the end.
- **Interface assignment is a rule, not a cabling accident.** `est-r1` has `Ethernet1` to `est-r2`, `Ethernet2` to `eur-r1`, `Ethernet3` to `wst-r1` because that is alphabetical, and it will still be that after somebody re-racks it.

## Topology

```
        plane r1, the reflectors                 plane r2, the clients
                                      
        wst-r1 ----65ms---- est-r1          wst-r2 ----68ms---- est-r2
           \                  /                \                  /
          130ms            75ms              134ms             78ms
             \              /                    \              /
              \--- eur-r1 -/                      \--- eur-r2 -/
                                      
   the planes meet only inside a region:  wst-r1==wst-r2  est-r1==est-r2  eur-r1==eur-r2   (cost 10)

   transit1  AS 65100  ->  wst-r1 and eur-r1       iBGP: r1 of each region is a route
   peer1     AS 65300  ->  est-r2                        reflector; r2 is its client;
                                                         the three RRs are full mesh
```

Every inter-region shortest path is the direct link, with margin — the model's RTTs were chosen so no path ties, which keeps every assertion deterministic.

## Quick start

```bash
chmod +x lab.sh
./lab.sh plan            # read this before anything else
./lab.sh render          # model -> configs + topology
./lab.sh deploy
./lab.sh verify
./lab.sh audit           # should be clean
./lab.sh break           # all 8 drifts
./lab.sh audit           # now triage
```

RAM: 8 cEOS nodes, roughly 11 GB.

| Command | What it is for |
|---|---|
| `./lab.sh plan` / `addresses` / `links` | the computed plan, and the rules that produced it |
| `./lab.sh render` | rewrites `configs/solution/` and the topology from the model. Pushes nothing. |
| `./lab.sh show <device>` | the config the model says one device should have |
| `./lab.sh audit` | running network against the model, classified |
| `./lab.sh remediate <device>` | pushes the model at one device. Asks you to confirm, on purpose. |

`render` and `remediate` are deliberately separate. Rendering is safe and reversible; remediating is neither, and the gap between them is where triage belongs.

## Rules

- `verify` reports observed versus expected. No hints.
- `./lab.sh break` injects all eight at once. `break <n>` for isolated practice.
- **Two of the eight are drifts in the model, not the network.** `./lab.sh restore` puts both the devices *and* the model back.
- Several drifts do not change a single thing `verify` can see. The audit is the only tool that finds them.
- `./lab.sh hint` exists.

## Caveats, and what this lab cannot teach

- **IPv4 only.** Lab 15 is the dual-stack lab; carrying two families here would double every config and add nothing to the model-and-drift subject.
- **The audit is structural, not semantic.** It compares the values the model computes against the values the device reports. Two route-maps with matching local-pref can still match the wrong prefix-list, and the audit will not notice — the same honest limit `parity` had in Lab 15.
- **No change control, no pipeline, no review.** The real discipline is a merge request against `model/`, a CI run of `render` plus a rendered-config audit, and a deploy that is the only way config reaches a device. This lab gives you the two ends and leaves the middle to your own tooling.
- **Six routers is not a backbone.** The algorithmic plan matters because it survives 600 devices, and at six you could have done it by hand — which is exactly why people do, and why their networks drift.
- **`remediate` is a blunt `configure replace`.** Real remediation is incremental, ordered, and has a rollback. Replacing the config of a transit border in one shot is a maintenance, not a command.
- cEOS forwards in software.

## Files

```
model/network.yml       regions, routers, links, rules. The network.
model/policy.yml        local-pref, communities, filters. The intent.
model/.baseline/        a pristine copy, so restore can put the model back too
tools/model.py          turns the rules into a complete plan
tools/render.py         plan -> configs AND bgp-lab16.clab.yml
tools/audit.py          running config vs plan, classified, no verdict
lab.sh                  deploy | verify | plan | render | audit | remediate | break | ...
configs/solution/       rendered. Never edited by hand.
docs/TASKS.md           Part A the model, Part B the eight drifts, Part C design
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
| 14 | Global backbone TE: hot potato, cold potato, MED, anycast |
| 15 | Dual-stack carrier edge: IPv4/IPv6 policy parity and graceful drain |
| 16 | The model is the network: generation, drift, and triage (this lab) |
