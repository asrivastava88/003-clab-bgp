# BGP Lab 07: Multi-VRF EVPN-VXLAN — Route-Target Leaking, Fusion, and Isolation

**Level:** CCIE DC | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

Four VRFs on one fabric, connected three different ways on purpose. Tenants reach shared services through route-target leaking with no device in the path. RED and BLUE reach each other only by crossing an external fusion device, so the traffic can be inspected. GREEN reaches shared services and nothing else, and nothing reaches GREEN.

The thing that makes this lab different from the other six: **it has negative tests.** `verify` asserts that specific pings *fail*, and reports a passing one as an isolation breach. In multi-tenant work, proving traffic cannot flow is the half you get paid for, and it is the half no reachability check ever covers.

## Topology

```
              +-----------+              +-----------+
              |  spine1   |              |  spine2   |      AS 65100
              | 10.0.0.1  |              | 10.0.0.2  |
              +-----------+              +-----------+
                E1 E2 E3                   E1 E2 E3
       every leaf: Ethernet1 -> spine1, Ethernet2 -> spine2
        +----------+-----------+------------+----------+
        |                      |                       |
  +-----------+          +-----------+          +------------+
  |   leaf1   |          |   leaf2   |          |   bleaf1   |
  |   65101   |          |   65102   |          |   65104    |
  | VTEP .11  |          | VTEP .12  |          | VTEP .14   |
  +-----------+          +-----------+          +------------+
    E3     E4            E3   E4   E5                 E3
    |      |             |    |    |            dot1q 101 = RED
   hR1    hB1           hR2  hG1  hS1           dot1q 102 = BLUE
  v10    v20            v10  v30  v100                |
  RED    BLUE           RED  GREEN SHARED        +----------+
 .10.101 .20.101      .10.102 .30.101 .100.10    |    fw    | AS 65200
                                                 | fusion   |
  VLAN 10 is stretched leaf1 <-> leaf2, so       +----------+
  there is a real L2VNI carrying hR1 <-> hR2.

  RED <-> BLUE is the ONLY pair that crosses fw. Everything else is
  either route-target leaking or deliberately blocked.
```

## The policy matrix

This table is the lab. Everything else is implementation.

| from \ to | RED | BLUE | GREEN | SHARED |
|---|---|---|---|---|
| **RED** | yes | via fw | **no** | yes, leaked |
| **BLUE** | via fw | yes | **no** | yes, leaked |
| **GREEN** | **no** | **no** | yes | yes, leaked |
| **SHARED** | yes | yes | yes | yes |

And the route-target configuration that produces it. Hub and spoke: the hub imports every spoke, each spoke imports only the hub.

| VRF | L3VNI | exports | imports |
|---|---|---|---|
| RED | 50001 | 50001:50001 | 50001:50001, **50099:50099** |
| BLUE | 50002 | 50002:50002 | 50002:50002, **50099:50099** |
| GREEN | 50003 | 50003:50003 | 50003:50003, **50099:50099** |
| SHARED | 50099 | 50099:50099 | 50099:50099, **50001:50001, 50002:50002, 50003:50003** |

No tenant imports another tenant's RT. That single omission is what keeps GREEN isolated, and adding one line to the wrong VRF undoes it with no alarm anywhere. That is ticket 1.

## Addressing

| Item | Value |
|---|---|
| Spine ASN | 65100 (shared) |
| Leaf ASNs | leaf1 65101, leaf2 65102, bleaf1 65104; fusion device fw 65200 |
| Lo0 / Lo1 (VTEP) | leaf1 10.0.0.11 / 10.0.1.11, leaf2 .12 / .12, bleaf1 .14 / .14 |
| Underlay P2P | 10.1.*spine*.x/31, spine even, leaf odd |
| Fusion handoff | RED 172.16.1.0/30, BLUE 172.16.2.0/30 (bleaf1 .1, fw .2), dot1q 101 and 102 on one physical link |

| VLAN | VRF | Subnet | L2VNI | Where |
|---|---|---|---|---|
| 10 | RED | 10.10.10.0/24 | 10010 | leaf1 (hR1 .101) **and** leaf2 (hR2 .102) |
| 11 | RED | 10.10.11.0/24 | 10011 | leaf1, SVI only, no host |
| 20 | BLUE | 10.20.20.0/24 | 10020 | leaf1 (hB1 .101) |
| 30 | GREEN | 10.30.30.0/24 | 10030 | leaf2 (hG1 .101) |
| 100 | SHARED | 10.100.100.0/24 | 10100 | leaf2 (hS1 .10, the shared-services host) |

Anycast gateway MAC 00:1c:73:00:00:99 on every leaf.

`10.10.11.1` exists only on leaf1, which makes `hR2 -> 10.10.11.1` a clean test of RED's L3VNI across leaves.

## Modes

| Mode | What is configured | Use |
|---|---|---|
| `base` | Fabric, EVPN overlay, all four VRFs, L2VNIs, SVIs. Every VRF imports **only its own RT**. No leaking, no fusion. | Part A. Intra-VRF works, everything else is blocked, and `verify` asserts that. |
| `solution` | The full matrix plus the fusion handoff and its policy. | Part B onward, and the baseline for the 8 tickets. |

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy solution        # one mode per deploy: base or solution
./lab.sh verify                 # fabric, intra-VRF, leaking, fusion, AND isolation
./lab.sh matrix                 # every host pair tested, printed as a grid
./lab.sh rts                     # the import/export matrix as the devices hold it
./lab.sh leak SHARED 10.10.10.0/24   # which RT carried a prefix into a VRF
./lab.sh break random           # solution baseline; then ./lab.sh reveal or restore
./lab.sh cli leaf2
./lab.sh destroy
```

RAM: 11 cEOS nodes, roughly 15 to 17 GB. Boot plus convergence takes 4 to 5 minutes.

`./lab.sh matrix` is the one to run after any change. It tests all twenty host pairs and prints a grid you compare against the policy table above. A cell that disagrees is either a broken service or a security finding, and the grid does not tell you which.

## Files

```
bgp-lab07.clab.yml     topology
lab.sh                 deploy | verify | matrix | rts | leak | break | restore | cli
configs/base|solution/ rendered configs (fw and hosts included)
tools/gen_configs.py   the VRFS dict at the top IS the policy matrix
docs/TASKS.md          Part A build, Part B leaking vs fusion, Part C tickets, Part D design
docs/TICKETS.md        symptoms only
docs/SOLUTIONS.md      spoilers
```

To change the policy, edit the `VRFS` dict in `tools/gen_configs.py` and re-render. The import lists there are the single source of truth for both modes.

## Caveats

- The fusion path depends on `remove-private-as all` on fw, for the same reason Lab 01's did: a RED prefix comes back toward BLUE with the fabric's private ASNs still in the AS_PATH, and bleaf1 drops its own ASN as a loop. Ticket 5 removes it.
- Whether a hub VRF re-advertises what it imported is platform behavior, not something this config controls. On EOS the imported EVPN routes are not re-originated, which is why GREEN stays isolated even though SHARED holds RED's prefixes. `verify` asserts this rather than assuming it. If that assertion fails on your build, the hub-and-spoke RT pattern is unsafe there and you need a fusion device for shared services too, which is worth knowing.
- Overlapping tenant address space is deliberately absent from the shipped config, because it would make the reference broken by design. Part B task B4 has you create the overlap and deal with it.
- cEOS forwards in software.
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
| 07 | Multi-VRF EVPN: RT leaking, fusion, and proving isolation (this lab) |
| 08 | Multi-site DCI: EVPN gateway, type-5 re-origination, domain path |
| 09 | SONiC as an EVPN leaf in a mixed Arista/SONiC fabric |
| 10 | Convergence engineering: BFD, timers, graceful restart, maintenance mode |
| 11 | BGP security and scale: max-prefix, GTSM, RPKI concepts, policy frameworks |
