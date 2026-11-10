# BGP Lab 12: Rail-Optimized AI/HPC Fabric

**Level:** CCIE DC / AI fabric design | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

No EVPN. No VXLAN. No VRFs. No overlay of any kind. A pure routed Clos with BGP running all the way down to the compute node.

This is the design most AI training fabrics actually use, and it looks almost nothing like labs 01 to 11. The reason is worth stating plainly: an AI fabric has one tenant, no VM mobility and no need for layer-2 adjacency, so an overlay buys you nothing and costs you encapsulation latency and hash entropy. What it needs instead is width, and the shortest possible path between ranks.

## The property that defines it

**A collective finishes when its slowest rank finishes.** That single fact changes what "broken" means. Losing one of two equal paths does not break anything; every endpoint stays reachable, every ping passes, and the job runs at half speed. There is no outage to alert on.

So this lab is not about reachability. Seven of its eight faults leave every endpoint pingable. It is about **installed next hops**, and the tool is `./lab.sh width`.

## Topology

```
              +-----------+            +-----------+
              |  spine1   |            |  spine2   |      AS 65100 (shared)
              +-----------+            +-----------+
                E1 E2 E3                 E1 E2 E3
        +---------+  |  +-----------+------+  |  +-------+
        |            |              |         |          |
  +-----------+  +-----------+          +-----------+
  |   rail1   |  |   rail2   |          |   stor1   |   AS 65103
  |  AS 65101 |  |  AS 65101 |          +-----------+
  +-----------+  +-----------+                E3
   E3  E4  E5     E3  E4  E5                  |
   |   |   |      |   |   |              +---------+
   |   |   +------|---|---+---- gpu3     |  nfs1   |  AS 65204
   |   +----------|---+-------- gpu2     | 10.20.  |
   +--------------+------------ gpu1     |  0.1    |
                                         +---------+
  every GPU server: NIC1 -> rail1, NIC2 -> rail2
  gpu1 65201 / 10.10.0.1   gpu2 65202 / 10.10.0.2   gpu3 65203 / 10.10.0.3

  Both rails share one ASN. Both spines share another. That makes every
  equal-length path identical in CONTENT too, so standard multipath works
  without relaxing the AS-path comparison. Part D asks what changes if each
  rail gets its own ASN, and it is not a small question.
```

### Why the servers run BGP

Each compute node holds its endpoint address on **Loopback1**, not on a NIC, and advertises it over eBGP to both rails. Three consequences:

- A NIC failure withdraws a path in well under a second. It does not wait for an ARP entry to age out, and the endpoint address never moves.
- The server participates in ECMP as a first-class citizen: it has two next hops to every peer and hashes across them itself.
- There is no first-hop redundancy protocol, no bonding, and no LACP anywhere in the fabric.

### Rail locality

Two endpoints on the same rail index reach each other in **one hop**, through that rail switch, and never touch a spine. `verify` asserts this: a rail switch must have zero spine-crossing next hops to a directly attached GPU. The spine layer exists for compute-to-storage and for cross-rail traffic, not for the collective.

## Expected widths

| From | To gpu1/2/3 | To storage |
|---|---|---|
| a GPU server | 2 (one per rail) | 2 (one per rail) |
| a rail switch | **1** (direct link — this is correct) | 2 (one per spine) |
| a spine | 2 (one per rail) | 1 (direct link) |
| stor1 | 2 (one per spine) | 1 (direct link) |

A rail switch showing 1 to a GPU is the design working. A GPU or a spine showing 1 is a fault. Knowing which is which is most of the lab.

## Addressing

| Item | Value |
|---|---|
| Spines | AS 65100 shared, Lo0 10.0.0.1-2 |
| Rails | AS 65101 shared, Lo0 10.0.0.11-12 |
| Storage leaf | AS 65103, Lo0 10.0.0.13 |
| Compute | gpu1 65201, gpu2 65202, gpu3 65203; endpoints 10.10.0.1-3/32 on Loopback1 |
| Storage node | nfs1 65204, endpoint 10.20.0.1/32 |
| Spine to leaf | 10.1.*spine*.x/31 |
| Rail to server | 10.2.*rail*.x/31 |
| MTU | 9214 everywhere, on the EOS interfaces **and on every veth** |

### A note on the veth MTU

Every link in `bgp-lab12.clab.yml` uses containerlab's extended link format so it can carry `mtu: 9214`:

```yaml
    - type: veth
      endpoints:
        - node: spine1
          interface: eth1
        - node: rail1
          interface: eth1
      mtu: 9214
```

The brief form (`- endpoints: ["spine1:eth1", "rail1:eth1"]`) has no MTU key, so the kernel builds the veth at 1500 and the 8000-byte tests fail everywhere no matter what the EOS interfaces say. This is the same ceiling you hit in Lab 05 at 1451 bytes: 1450 + 8 VXLAN + 8 UDP + 20 IP + 14 Ethernet = 1500 on the wire. If you want to fix Lab 05 permanently, convert its links to this format.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy
./lab.sh verify          # clean baseline
./lab.sh width           # save this matrix. It is the whole lab.
./lab.sh break           # all 8 faults
./lab.sh width           # diff against the clean one
```

RAM: 9 cEOS nodes, roughly 12 to 14 GB.

| Command | What it is for |
|---|---|
| `./lab.sh width` | installed next hops, every source against every destination, colour-coded |
| `./lab.sh rail <src> <dst>` | is this flow staying on-rail or crossing a spine |
| `./lab.sh sizes <src> <dst>` | walks packet sizes to find an MTU ceiling |

## Rules

- `verify` reports observed versus expected. No hints.
- `./lab.sh break` injects all eight at once. `break <n>` for isolated practice.
- Two **pairs** of faults mask each other. One fault is a direction rather than a device.
- `./lab.sh hint` exists.

## Files

```
bgp-lab12.clab.yml     topology
lab.sh                 deploy | verify | width | rail | sizes | break | restore | hint | cli
configs/solution/      the working fabric. There is no base mode.
tools/gen_configs.py   SERVERS and LEAVES at the top define the rails
docs/TASKS.md          Part A baseline, Part B the faults, Part C design
docs/HINTS.md          spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md      the answers
```

## Caveats, and what this lab cannot teach

- **Nothing about congestion.** A real AI fabric lives or dies on PFC, ECN and the tuning between them. cEOS in a container has no congestion to manage and no ASIC buffers to watch, so none of that is here. This lab covers the routing design underneath it, which is a necessary and insufficient part of the problem.
- **Nothing about RoCE itself.** No RDMA, no queue pairs, no DCQCN. The 8000-byte tests stand in for "RDMA uses large frames", and that is as far as it goes.
- **One MTU fault is hash-dependent by design.** When an MTU mismatch sits on one leg of an ECMP bundle, whether a given flow breaks depends on where it hashes. Expect the 8000-byte checks to fail for some GPUs and pass for others, and expect that set to stay the same across runs because ICMP from a fixed source hashes the same way every time. That is not the lab being flaky; it is the single most annoying property of real MTU faults.
- **Two rails, not eight.** Real rail-optimized designs have one rail per GPU, so eight or sixteen. Two is enough to make width visible and small enough to run on one machine. The arithmetic scales; the lessons do not change.
- **Hash behaviour is not modelled.** Flow polarization, entropy and flowlet switching are real and this lab cannot show them. Part C question 4 covers them as a design question.
- cEOS forwards in software.

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
| 12 | Rail-optimized AI/HPC fabric: no overlay, BGP to the host, width (this lab) |
