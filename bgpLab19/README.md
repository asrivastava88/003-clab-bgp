# BGP Lab 19: Multi-Tenant EVPN Across Three Regions — and the One Sentence That Must Stay True

**Level:** multi-tenant fabric architect | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F ×38

Three regions. Three tenant VRFs on a hub-and-spoke route-target plan. Twelve faults, one of which is a tenancy breach living on exactly one of eighteen identically generated devices.

Same node count and resource profile as Lab 18 — **38 nodes, 72 links, roughly 55 GB** — so the cost is already known. The new dimension is tenancy.

## One honest framing note

You asked for hyperscaler. **Multi-VRF EVPN is not really a hyperscaler pattern.** Google, Meta and Microsoft mostly run flat L3 fabrics and do tenant isolation in software on the host — a VRF per tenant in the switching fabric is something they deliberately avoid, because it puts tenant state in a place that is hard to change quickly.

Multi-VRF EVPN with route-target leaking is the **Fortune 500 pattern**, and it is what an Apstra-managed fabric does. So this lab is that, built with hyperscaler *discipline* — everything generated from one model, algorithmic addressing, nothing hand-typed. The scale and the rigour are hyperscaler; the design is the one you actually operate.

## The invariant

```
  PROD    exports 1:50001   imports 1:50001, 1:50003
  DEV     exports 1:50002   imports 1:50002, 1:50003
  SHARED  exports 1:50003   imports 1:50003, 1:50001, 1:50002
```

PROD reaches SHARED. DEV reaches SHARED. **PROD never reaches DEV.**

That last sentence is a security control, a compliance statement and probably a contract. It is also enforced by nothing but a list of route-targets, repeated on eighteen devices, and it breaks on **one device at a time**. `./lab.sh isolation` tests it from every VTEP in all three regions:

```
  from (PROD)  -> DEV         -> SHARED       verdict
  wst-p1-l1    no             yes             correct
  wst-p1-l2    YES            yes             ISOLATION BREACH
  wst-p2-l1    no             yes             correct
```

Seventeen correct rows do not make the eighteenth acceptable. They are the reason nobody noticed.

## Design, and why it differs from Labs 17 and 18

| Layer | Choice | Why |
|---|---|---|
| underlay | **OSPF**, area 0 per region | Labs 17 and 18 covered the eBGP Clos and its ASN plan at length. This lab's subject is tenancy, and an OSPF underlay removes eBGP next-hop handling from the picture so the VRF dimension is the only hard thing. |
| overlay | **iBGP EVPN**, super-spines as route reflectors, one AS per region | no `next-hop-unchanged` to get wrong; the overlay is a clean three-tier reflection |
| spines | **no BGP at all** | pure underlay transit. A spine that carries no tenant state cannot break one. |
| tenants | **L3VNI only, no L2VNIs** | stretched layer 2 adds MAC learning and anycast gateways without adding anything to the tenancy question |
| inter-region | **per-VRF eBGP on dot1q sub-interfaces** to two carriers | EVPN stops at the region boundary, which is what almost everyone actually does — stretching EVPN across a WAN is a much larger commitment than handing off a VRF |

That last row is worth sitting with. Each tenant crosses the WAN as its own BGP session, on its own sub-interface, to a carrier that keeps it in its own VRF. **A tenant can therefore be broken across regions while being perfectly healthy inside each one**, and two of the twelve faults are exactly that.

## Topology

```
   per region (x3):                              wan1 AS 65500   wan2 AS 65600
                                                   (3 VRFs)        (3 VRFs)
        ss1        ss2     <- EVPN route reflectors    \   /    \   /
       / | \      / | \                                 \ /      \ /
    p1-s1 p1-s2  p2-s1 p2-s2   <- OSPF only, no BGP      b1        b2
      |  \ /  |    |  \ /  |                              \       /
    p1-l1  p1-l2 p2-l1  p2-l2  <- VTEPs                    +--ss--+
                                                      per-VRF eBGP on
   VTEPs: 4 leaves + 2 borders = 6 per region         dot1q 101/102/103

   tenant space    PROD 10.{100+R}.11.x   DEV 10.{100+R}.21.x   SHARED 10.{100+R}.31.x
   L3VNIs          PROD 50001             DEV 50002             SHARED 50003
```

## The tools

| Command | What it answers |
|---|---|
| `./lab.sh isolation` | the invariant, tested from every VTEP in every region |
| `./lab.sh vrf [NAME]` | route count per VRF per VTEP — symmetric by design, so asymmetry is a finding |
| `./lab.sh vtep` | who sees whose VTEP, and which one is missing |
| `./lab.sh wan` | per-VRF inter-region sessions, and whether any region is transiting in any VRF |
| `./lab.sh rt <device>` | the route-target plan as that one device actually has it |

`vtep` earns its place because of a specific confusion this design creates: **a VTEP nobody sees is usually an underlay problem wearing an overlay costume.** The EVPN session is up, the routes are there, and the tunnel never forms because a loopback is not reachable.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy          # 8-12 minutes, ~55 GB
./lab.sh verify
./lab.sh isolation       # save this
./lab.sh vrf ; ./lab.sh vtep ; ./lab.sh wan
./lab.sh break           # all 12
```

### Making it bigger

`tools/gen_configs.py` has two knobs at the top:

```python
PODS_PER_REGION = 2      # 38 nodes
LEAVES_PER_POD  = 2
```

`LEAVES_PER_POD = 3` gives **44 nodes**; `PODS_PER_REGION = 3` gives **50**; both gives **59**. At roughly 1.4–1.5 GB per cEOS node, 59 nodes is about 88 GB, which on a 100 GB box leaves very little for Docker and the host — workable but tight, and the first symptom of running out is nodes that boot and then quietly fail to converge. Change a knob, re-run `./lab.sh deploy`, and the topology, the addressing and the peer map all follow.

## Rules

- `verify` reports observed versus expected. No hints.
- `./lab.sh break` injects all twelve at once. `break <n>` for isolated practice.
- **One fault is a tenancy breach.** Find it first; everything else can wait.
- Several faults break a tenant in one region while leaving it healthy in the other two.
- Two faults look identical in the overlay and have their cause in the underlay.
- `./lab.sh hint` exists.

## Caveats, and what this lab cannot teach

- **One thing to check first if the overlay does not populate.** This design relies on the super-spines reflecting EVPN routes whose route-targets they do not themselves import. EOS does this by default in every deployment I am aware of, but route-target constrained filtering is a real feature and if your image enables it, the symptom is: EVPN sessions Established, zero type-5 routes anywhere, VTEPs invisible. If you see exactly that, check the reflectors before anything else. I have not been able to verify the behaviour on 4.36.0.1F specifically, and I would rather say so than let you debug my assumption.
- **No L2VNIs**, so no MAC mobility, no ARP suppression, no anycast gateway, no type-2 routes. Those are Lab 03's and Lab 07's subjects.
- **No overlapping tenant address space.** Real multi-tenancy usually means two tenants both using 10.0.0.0/8, which is the thing VRFs exist for and which this lab's addressing deliberately avoids so that a leak is visible by inspection. Overlapping space would make `isolation` much harder to write and the lab much harder to read.
- **The carriers are one router each.** A real L3VPN provider has its own PE/P architecture and its own failure modes.
- **No tenant QoS, no per-VRF rate limiting, no security policy.** Isolation here is pure routing, which is necessary and nowhere near sufficient.
- cEOS forwards in software, and EVPN at 38 nodes on 24 cores takes about 90 seconds to settle after a change.

## Files

```
bgp-lab19.clab.yml      topology, generated
lab.sh                  deploy | verify | isolation | vrf | vtep | wan | rt | break | ...
tools/gen_configs.py    one model renders 38 configs, the topology and the peer map
tools/peers.sh          generated peer, tenant-host and VTEP maps
configs/solution/       the working fabric. There is no base mode.
docs/TASKS.md           Part A the design, Part B the twelve faults, Part C tenancy
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
| 18 | Three regions, two carriers: region transit and double aggregation |
| 19 | Multi-tenant EVPN across three regions: the isolation invariant (this lab) |
