# BGP Lab 04: iBGP EVPN Overlay, Spine Route Reflectors, and Add-Path

**Level:** CCIE DC | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

Labs 01 to 03 were eBGP everywhere: a unique ASN per leaf, and the overlay riding eBGP sessions. This lab is the other mainstream design, the one you meet in Cisco and Juniper reference architectures and in most brownfield data centers: **one autonomous system**, an IGP underlay, and an iBGP EVPN overlay with the spines acting as route reflectors.

That single change moves a lot of things around. Next-hop preservation becomes free instead of configured. Loopback distribution moves out of BGP and into OSPF. And a new failure mode appears that eBGP fabrics do not have: a route reflector advertises one best path per prefix, so a client with two valid exits sees only one. Fixing that is what add-path is for, and this lab makes you watch it happen before you turn it on.

## Topology

```
                      +----------------+   +----------------+
                      | spine1  RR     |   | spine2  RR     |
                      | 10.0.0.1       |   | 10.0.0.2       |
                      +----------------+   +----------------+
                        E1 E2 E3 E4          E1 E2 E3 E4
            every client: Ethernet1 -> spine1, Ethernet2 -> spine2
       +--------------+--------+----------------+-------------+
       |              |                 |                    |
 +-----------+  +-----------+    +-----------+        +-----------+
 |  leaf1    |  |  leaf2    |    |  bleaf1   |        |  bleaf2   |
 | 10.0.0.11 |  | 10.0.0.12 |    | 10.0.0.14 |        | 10.0.0.15 |
 | VTEP .11  |  | VTEP .12  |    | VTEP .14  |        | VTEP .15  |
 +-----------+  +-----------+    +-----------+        +-----------+
     E3           E3    E4            E3  vrf RED          E3  vrf RED
     |            |     |             172.16.1.1/30        172.16.2.1/30
     h1           h2    h3                 |                    |
  v10 .101    v10 .102  v20 .103           E1                   E2
                                        +--------------------------+
                                        |  wan     AS 65100        |
                                        |  203.0.113.10, default   |
                                        +--------------------------+

  ALL OF 10.0.0.0/24 AND THE LEAVES ARE AS 65000  ->  the overlay is iBGP
  underlay : OSPF area 0, point-to-point on every /31, loopbacks passive
  overlay  : iBGP EVPN, Lo0 to Lo0, spines reflect between clients
  egress   : bleaf1 and bleaf2 each learn a default from wan and originate
             it into EVPN as a type-5. Two equal exits. BOTH reflectors hold
             both, both independently pick bleaf1 (lowest router-id), and
             each sends only that one. leaf1 ends up with two paths and one
             exit. Add-path is what makes the second exit visible.
```

## Addressing

| Item | Value |
|---|---|
| Fabric ASN | 65000 (spines, leaves and borders alike) |
| WAN ASN | 65100 |
| Lo0 (router-id, overlay peering) | spines 10.0.0.1-2, leaf1 .11, leaf2 .12, bleaf1 .14, bleaf2 .15 |
| Lo1 (VTEP) | 10.0.1.11, .12, .14, .15 |
| Underlay P2P | 10.1.*spine*.x/31, spine even, client odd (leaf1 slot 1, leaf2 slot 2, bleaf1 slot 3, bleaf2 slot 4) |
| OSPF | area 0.0.0.0, `network 10.0.0.0/16` and `network 10.1.0.0/16`, `passive-interface default` |
| WAN handoff | bleaf1 172.16.1.1/30 to wan .2; bleaf2 172.16.2.1/30 to wan .2 |

| VLAN | Subnet | L2VNI | Hosts |
|---|---|---|---|
| 10 APP | 10.10.10.0/24 | 10010 | h1 .101 (leaf1), h2 .102 (leaf2) |
| 20 DB | 10.10.20.0/24 | 10020 | h3 .103 (leaf2) |

VRF RED, L3VNI 50001, RT 50001:50001, anycast gateway MAC 00:1c:73:00:00:99. Internet test target 203.0.113.10.

Border leaves carry no VLANs and no L2VNI: they are pure L3 exits with the L3VNI only.

## Modes

| Mode | What is configured | Use |
|---|---|---|
| `base` | OSPF underlay converged, VLANs, SVIs, VRF, VXLAN interface. **No BGP at all.** | Part A: build the entire overlay |
| `solution` | iBGP RR overlay and border eBGP complete. **No add-path.** | Part B: see path hiding, then fix it |
| `addpath` | Everything, add-path on the reflectors and receive on the clients | Part C baseline for the 8 tickets |

`wan`, `h1`, `h2` and `h3` are identical in all three modes.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy addpath   # one mode per deploy: base, solution or addpath
./lab.sh verify           # underlay, overlay, RR behavior, data plane, path count
./lab.sh paths            # the whole path-hiding story on one screen
./lab.sh break random     # addpath baseline; then ./lab.sh reveal or restore
./lab.sh cli spine1       # Cli on any node
./lab.sh destroy
```

RAM: 10 cEOS nodes, roughly 14 to 16 GB. Boot plus OSPF and overlay convergence takes 3 to 5 minutes.

## Files

```
bgp-lab04.clab.yml     topology
lab.sh                 deploy | verify | paths | break | restore | cli
configs/base|solution|addpath/   rendered configs (wan and hosts included)
tools/gen_configs.py   one data model, all three modes
docs/TASKS.md          Part A build, Part B add-path, Part C tickets, Part D design
docs/TICKETS.md        symptoms only
docs/SOLUTIONS.md      spoilers
```

## Caveats, and two things to confirm on your build

- **Add-path syntax.** The reference uses `bgp additional-paths send any` and `bgp additional-paths receive` under `address-family evpn`. If your 4.36 build rejects the address-family form, the per-neighbor variant is `neighbor OVERLAY additional-paths send any`. Check with `bgp additional-paths ?` inside the EVPN address family before assuming the lab is broken. This is the single most release-sensitive command in the lab.
- **Path counting.** `verify` reads `bgpRoutePaths` out of `show ip bgp <prefix> vrf RED | json`. Expected counts for 0.0.0.0/0 on leaf1: `solution` mode 2 paths and 1 VTEP next hop; `addpath` mode 4 paths and 2 VTEP next hops. If the assertions disagree with what `./lab.sh paths` shows on screen, trust the screen and adjust `bgp_paths()` in `lab.sh`.
- cEOS forwards in software. Convergence timings here show relative behavior, not hardware numbers.
- Every node boots from its own `startup-config`. Nothing to bootstrap, nothing to re-run by hand: `./lab.sh restore` is the reset.

## Lab series

Lab 04 was originally advertised as covering unnumbered underlay as well. That turned out not to fit: an unnumbered RFC 8950 underlay belongs with eBGP, where each device has its own ASN, and it does not combine cleanly with a single-ASN iBGP overlay on the same box. It moved to Lab 05.

| Lab | Focus |
|---|---|
| 01 | eBGP Clos, EVPN L2/L3VNI, symmetric IRB, VRF-lite border, fusion routing |
| 02 | Dual-ISP edge: local-pref, MED, prepend, communities, RTBH, BFD |
| 03 | EVPN multihoming (ESI-LAG) vs MLAG |
| 04 | iBGP overlay, spine route reflectors, add-path, OSPF underlay (this lab) |
| 05 | Unnumbered eBGP underlay (RFC 8950), IPv6 link-local peering, peer templates |
| 06 | Inter-VRF route leaking inside EVPN vs centralized fusion |
| 07 | Multi-site DCI: EVPN gateway, type-5 re-origination, domain path |
| 08 | SONiC as an EVPN leaf in a mixed Arista/SONiC fabric |
| 09 | Convergence engineering: BFD, timers, graceful restart, maintenance mode |
| 10 | BGP security and scale: max-prefix, GTSM, RPKI concepts, policy frameworks |
