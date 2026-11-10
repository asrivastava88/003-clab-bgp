# BGP Lab 11: Capstone — Eight Faults That Do Not Announce Themselves

**Level:** CCIE DC, troubleshooting section | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

Nothing in this topology is new. Two VRFs, a stretched L2 domain, a dual border, a dual-homed WAN, symmetric IRB, ECMP in the underlay and in the overlay. Everything labs 01 to 10 covered, present at once.

What is different is the faults. In the previous labs most faults produced a clean outage: something was unreachable, `verify` went red, you fixed it. Here:

- **Three faults produce no symptom at all** in the steady state. They are latent. The only way to find them is to compare devices against each other, or to deliberately fail something that is currently carrying no traffic.
- **Two faults mask each other.** Fixing one appears to make things worse.
- **One fault is invisible to every ping you would normally run** and obvious to one you probably would not.
- **One fault makes a host reach things it should not**, which is not an outage at all.

There is no `base` mode. The lab ships working. `./lab.sh break` injects all eight.

If your method is "run verify, fix what is red, repeat", you will stop at five and believe you are finished. That is the lab.

## Topology

```
          +-----------+                        +-----------+
          |  spine1   |                        |  spine2   |   AS 65100
          +-----------+                        +-----------+
           E1 E2 E3 E4 E5                       E1 E2 E3 E4 E5
     every leaf: Ethernet1 -> spine1, Ethernet2 -> spine2
   +--------+--------+----------+-----------+------------+
   |        |        |          |           |
+------+ +------+ +------+ +---------+ +---------+
|leaf1 | |leaf2 | |leaf3 | | bleaf1  | | bleaf2  |
|65101 | |65102 | |65103 | | 65104   | | 65105   |
+------+ +------+ +------+ +---------+ +---------+
  E3       E3      E4          E3          E3
  h1       h2      h3      dot1q 101=RED, 102=BLUE
 v10      v10     v30          |           |
 RED      RED     BLUE         E1          E2
.10.101  .10.102 .30.101   +---------------------+
                           |   wan    AS 65200   |
  VLAN 10 is stretched     | default to all four |
  leaf1 <-> leaf2.         | 203.0.113.0/24      |
  VLAN 20 lives on leaf3   +---------------------+
  as an SVI with no host.
```

bleaf2 prepends its own ASN twice on WAN ingress, so **bleaf1 is primary for both VRFs and bleaf2 carries nothing**. That is deliberate. A backup path nobody exercises is a backup path nobody has tested.

## Addressing

| Item | Value |
|---|---|
| Spines | AS 65100 shared, Lo0 10.0.0.1-2 |
| Leaves | leaf1 65101 (.11), leaf2 65102 (.12), leaf3 65103 (.13), bleaf1 65104 (.14), bleaf2 65105 (.15) |
| Lo0 / Lo1 | 10.0.0.*n* / 10.0.1.*n* |
| Underlay | 10.1.*spine*.x/31, spine even, leaf odd, MTU 9214 |
| WAN handoff | bleaf1 RED 172.16.11.1/30, BLUE 172.16.12.1/30; bleaf2 RED 172.16.21.1/30, BLUE 172.16.22.1/30 |

| VLAN | VRF | Subnet | L2VNI | Where |
|---|---|---|---|---|
| 10 | RED | 10.10.10.0/24 | 10010 | leaf1 (h1 .101) **and** leaf2 (h2 .102) |
| 20 | RED | 10.10.20.0/24 | 10020 | leaf3, SVI only |
| 30 | BLUE | 10.30.30.0/24 | 10030 | leaf3 (h3 .101) |

VRF RED L3VNI 50001, VRF BLUE L3VNI 50002. No inter-VRF anywhere: RED and BLUE must never reach each other, and `verify` asserts it.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy
./lab.sh verify          # clean baseline. Read it. You will want it later.
./lab.sh break           # all eight
./lab.sh verify
```

RAM: 11 cEOS nodes, roughly 15 to 17 GB.

### The three commands that find latent faults

| Command | What it is for |
|---|---|
| `./lab.sh survey` | the same five pieces of state from every device, on one screen, for comparison |
| `./lab.sh sizes <src> <dst>` | walks packet sizes from 100 to 8000 and shows where the ceiling is |
| `./lab.sh drain <node>` | prepends a device away so you can see whether its backup actually works |

`survey` is the one to run first. Collect it once, properly, into a table before you change anything. Three of the eight faults are only findable by noticing that one device's number differs from its twin's.

`drain` is how you find the latent ones. A backup that has never carried traffic is a backup you have never tested, and two of the faults in this lab live exactly there.

## Rules

- `verify` reports observed versus expected. It names no command, no config line and no cause.
- `./lab.sh hint` exists. `./lab.sh hint 3` gives one fault's pointer.
- `./lab.sh reveal` tells you how many are left, not which.
- Write the root cause of each in one sentence before fixing it. If you cannot, you have found a symptom and not a cause.

Target: all eight in 90 minutes. Five in 30 and then an hour on the last three is the normal shape, and the last three are the point of the lab.

## Files

```
bgp-lab11.clab.yml     topology
lab.sh                 deploy | verify | survey | sizes | drain | break | restore | hint | cli
configs/solution/      the working fabric. There is no base mode.
tools/gen_configs.py   one data model
docs/TASKS.md          the exercise, and the design review
docs/HINTS.md          spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md      the answers, with the interactions explained
```

## Caveats

- The 4000-byte tests depend on the underlay carrying a 4050-byte frame. If they fail on a clean deploy, your containerlab veth MTU is the ceiling rather than anything in the lab. `./lab.sh sizes h2 10.10.20.1` on a clean fabric tells you where the real ceiling is, and you can lower the test accordingly.
- `drain` reads the local ASN out of `show ip bgp summary`. If your build words that line differently it will fail loudly rather than silently.
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
| 11 | Capstone: eight faults that do not announce themselves (this lab) |
