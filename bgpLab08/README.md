# BGP Lab 08: Multi-Site EVPN DCI — Two Domains, One Stitch

**Level:** CCIE DC | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

Two independent EVPN-VXLAN fabrics joined by a pair of DCI gateways. Not one stretched fabric with a long cable: two separate VXLAN domains, stitched at the border, so a failure in one site's overlay stays in that site.

The whole lab turns on one command, and it is a command you have already met as a bug. In Lab 04, `next-hop-self` inside `address-family evpn` on a spine broke the fabric, because a spine is not a VTEP and telling leaves to tunnel to it is nonsense. On a DCI gateway the same command is the entire mechanism, because a gateway *is* a VTEP and terminating the tunnel there is exactly the point.

## Topology

```
          SITE A  (underlay 10.1.1.x)              SITE B  (underlay 10.2.1.x)

            +-----------+                             +-----------+
            |  spineA   |  AS 65100                   |  spineB   |  AS 65200
            | 10.0.0.1  |                             | 10.0.2.1  |
            +-----------+                             +-----------+
              E1     E2                                 E2     E1
              |       |                                 |       |
      +-------+       +-------+                 +-------+       +-------+
      |                       |                 |                       |
 +-----------+          +-----------+      +-----------+          +-----------+
 |   leafA   |          |   bgwA    |      |   bgwB    |          |   leafB   |
 |   65101   |          |   65104   |      |   65204   |          |   65201   |
 | Lo0 .0.11 |          |           |      |           |          | Lo0 .2.11 |
 | VTEP      |          | Lo0 = VTEP|--E3--|Lo0 = VTEP |          | VTEP      |
 | 10.0.1.11 |          | 10.0.0.14 | DCI  | 10.0.2.14 |          | 10.0.3.11 |
 +-----------+          +-----------+ /30  +-----------+          +-----------+
   E3     E4                                                        E3     E4
   |      |                 172.16.0.0/30                           |      |
  hA1    hA2                                                       hB1    hB2
  v10    v20                                                       v10    v30
.10.101 .20.101                                                 .10.102 .30.101

  VLAN 10 is STRETCHED: hA1 and hB1 are in 10.10.10.0/24 in different sites.
  VLAN 20 (site A) and VLAN 30 (site B) are site-local and reach each other
  by L3 only, which is the mix you actually want.
```

One spine per site is a deliberate simplification. Everything in this lab is about the border, and a second spine per site would add two nodes and teach nothing new. Labs 01 to 07 cover spine redundancy.

## Why a gateway collapses its loopbacks

Every leaf in this series has had two loopbacks: Loopback0 for the router-id and EVPN peering, Loopback1 for the VTEP. The gateways here have **one**.

`next-hop-self` rewrites the next hop to the session's update-source. If a gateway peered EVPN from Loopback0 while tunnelling from Loopback1, it would tell the far site to tunnel to Loopback0, which is not a tunnel endpoint. Collapsing both roles onto one interface removes the question. The leaves keep two loopbacks because they never set `next-hop-self` on anything.

## The gateway rewrites both sides

A gateway terminates two domains, so it sets `next-hop-self` on **both** EVPN peer groups:

| Peer group | Direction | Effect |
|---|---|---|
| `EVPN` | toward its own spine | routes arriving from the DCI are handed to local leaves with the gateway's VTEP as the next hop |
| `DCI-EVPN` | toward the far gateway | routes from local leaves cross the DCI with the gateway's VTEP as the next hop |

Drop either one and you get a different, equally confusing failure. Those are tickets 1 and 2.

## Underlay containment

The DCI underlay session exchanges exactly **one prefix each way**: the far gateway's loopback. Nothing else crosses, and the gateway also filters its site-facing underlay session so DCI-learned prefixes never enter its own fabric.

The consequence is the measurable property of this design, and `verify` asserts all three:

- `bgwB` has a route to `10.0.0.14` (bgwA's loopback) and **no** route to `10.0.1.11` (leafA's VTEP).
- `leafB` has **no** route into site A's loopback space at all.
- `leafA` lists exactly one remote VTEP, `10.0.0.14`, and no site B address anywhere.

If a leaf ever lists a VTEP from the other site, you have built a flat stretch by accident, and the blast radius you thought you had is gone.

## Addressing

| Item | Site A | Site B |
|---|---|---|
| Spine ASN | 65100 | 65200 |
| Leaf / gateway ASN | leafA 65101, bgwA 65104 | leafB 65201, bgwB 65204 |
| Loopback0 | spineA 10.0.0.1, leafA 10.0.0.11, bgwA 10.0.0.14 | spineB 10.0.2.1, leafB 10.0.2.11, bgwB 10.0.2.14 |
| Leaf VTEP (Loopback1) | leafA 10.0.1.11 | leafB 10.0.3.11 |
| Gateway VTEP | bgwA 10.0.0.14 (Loopback0) | bgwB 10.0.2.14 (Loopback0) |
| Underlay P2P | 10.1.1.x/31 | 10.2.1.x/31 |
| DCI | 172.16.0.1 (bgwA) | 172.16.0.2 (bgwB) |

| VLAN | Subnet | L2VNI | Where | Crosses the DCI? |
|---|---|---|---|---|
| 10 | 10.10.10.0/24 | 10010 | leafA, leafB, **and both gateways** | yes, stretched L2 |
| 20 | 10.20.20.0/24 | 10020 | leafA only | L3 only |
| 30 | 10.30.30.0/24 | 10030 | leafB only | L3 only |

VRF RED, L3VNI 50001, RT 50001:50001 in both sites. Anycast gateway MAC 00:1c:73:00:00:99 on the leaves; the gateways carry no SVI for VLAN 10, because they stitch it at layer 2 and the anycast gateway lives on the leaves in both sites.

A gateway only stitches the VNIs it instantiates. That is why `STRETCHED = [10]` in `tools/gen_configs.py` is the one list that decides what is extended, and why VLAN 20 and VLAN 30 cannot accidentally cross.

## Modes

| Mode | What is configured | Use |
|---|---|---|
| `base` | Both sites complete and working independently. The DCI link is addressed and nothing runs over it. | Part A. `verify` asserts the sites cannot see each other. |
| `solution` | The DCI built: underlay session with containment filters, multihop EVPN session, `next-hop-self` on both sides, stitched VNIs. | Part B onward, and the baseline for the 8 tickets. |

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy solution   # one mode per deploy: base or solution
./lab.sh verify            # per-site, DCI, containment, stretch and L3
./lab.sh tunnels           # who tunnels to whom, which proves the stitch
./lab.sh stretch           # one MAC followed from site B to site A, next hop by next hop
./lab.sh break random      # solution baseline; then ./lab.sh reveal or restore
./lab.sh cli bgwA
./lab.sh destroy
```

RAM: 10 cEOS nodes, roughly 14 to 16 GB. Boot plus convergence takes 4 to 5 minutes.

`./lab.sh stretch` is the one to run first. It follows hB1's MAC from the moment leafB learns it, through both gateways, to where leafA installs it, and shows the next hop changing twice. That is the lab in five commands.

## Files

```
bgp-lab08.clab.yml     topology
lab.sh                 deploy | verify | tunnels | stretch | break | restore | cli
configs/base|solution/ rendered configs (hosts included)
tools/gen_configs.py   STRETCHED at the top decides what crosses the DCI
docs/TASKS.md          Part A build, Part B gateway vs flat stretch, Part C tickets, Part D design
docs/TICKETS.md        symptoms only
docs/SOLUTIONS.md      spoilers
```

## Caveats

- **The riskiest assumption in this lab** is that `next-hop-self` in `address-family evpn` on a VTEP produces that VTEP's address. Collapsing Loopback0 and the VXLAN source onto one interface on the gateways makes that true regardless of whether EOS derives the next hop from the update-source or from the VXLAN source interface. If the stretch does not work and `./lab.sh tunnels` shows a gateway advertising something other than its own loopback, that assumption is where to look first.
- Arista also offers purpose-built VXLAN-to-VXLAN stitching and multi-domain features in recent EOS. This lab builds the model out of `next-hop-self` because that is portable and because it makes the mechanism visible. If your build has the dedicated feature, Part D question 6 asks you to compare them.
- Domain-path (D-PATH) style loop prevention across domains is not configured here. With two sites and one gateway each there is no loop to prevent. Part D question 2 covers what changes with two gateways per site.
- cEOS forwards in software.
- Every node boots from its own `startup-config`. `./lab.sh restore` is the reset.

## A correction to Lab 04

Lab 04's `docs/SOLUTIONS.md`, Part D answer 4, says "Lab 07 builds this" about multi-site DCI. After Lab 06 was inserted as the pure-BGP lab, DCI moved here, to Lab 08. The mechanism described there is what this lab builds.

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
| 08 | Multi-site EVPN DCI: gateways, next-hop rewrite, underlay containment (this lab) |
| 09 | SONiC as an EVPN leaf in a mixed Arista/SONiC fabric |
| 10 | Convergence engineering: BFD, timers, graceful restart, maintenance mode |
| 11 | BGP security and scale: max-prefix, GTSM, RPKI concepts, policy frameworks |
