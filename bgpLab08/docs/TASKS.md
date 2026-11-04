# Lab 08 Tasks

## Part A: Build the DCI (deploy `base`)

Both sites are complete and working on their own. hA1 reaches hA2 across site A's L3VNI, hB1 reaches hB2 across site B's. The DCI link is addressed on both ends and nothing runs over it.

Run `./lab.sh verify` first. The two sites cannot see each other, and that is asserted rather than assumed.

| # | Task | Done when |
|---|---|---|
| A1 | DCI underlay. An eBGP IPv4 session across 172.16.0.0/30 that exchanges exactly one prefix each way: the far gateway's loopback. Nothing else. | `show ip route 10.0.2.14` on bgwA resolves, and `show ip route 10.0.1.11` on bgwB is empty. |
| A2 | Contain it. DCI-learned prefixes must never enter your own site's underlay. | `show ip route 10.0.0.14` on leafB is empty. |
| A3 | DCI overlay. A multihop eBGP EVPN session between the two gateway loopbacks. | `show bgp evpn summary` on each gateway shows 2 Established. |
| A4 | Make it a gateway, not a flat stretch. Rewrite the next hop on **both** EVPN peer groups on each gateway. | `show vxlan vtep` on leafA lists 10.0.0.14 and nothing from site B. |
| A5 | Stitch VLAN 10. A gateway can only stitch a VNI it instantiates. Give both gateways VLAN 10, the L2VNI mapping and the MAC-VRF, and no SVI. | hA1 reaches hB1 in 10.10.10.0/24. |
| A6 | Carry VRF RED across. The gateways need the VRF, the L3VNI and the route-targets. | hA2 reaches hB2 and back. |
| A7 | Confirm nothing else crossed. | `./lab.sh verify` all PASS, including every containment assertion. |

Questions before Part B:

1. The gateways have one loopback where every leaf in this series has had two. Explain what breaks if you give a gateway a separate peering loopback and VTEP, and which of the two addresses ends up in the EVPN next hop.
2. A gateway sets `next-hop-self` on both EVPN peer groups. Describe the two different failures you get from omitting each one, and say which site notices in each case.
3. `show ip route 10.0.1.11` on bgwB is empty, and that is correct. Explain why the far gateway never needs a route to any of your leaves, and what it means for the size of the DCI underlay at ten sites.
4. VLAN 20 exists only at site A and cannot cross the DCI. Name the specific thing that prevents it, and say why that is better than a filter.
5. Follow a broadcast from hA1 to hB1. List every device that replicates it and explain why this is not a full mesh of VTEPs across the WAN.

## Part B: Gateway versus flat stretch (deploy `solution`)

**B1 Watch the stitch.** Run `./lab.sh stretch`. It follows hB1's MAC from leafB to leafA. Write down the next hop at each of the five steps and mark the two places it changes.

**B2 Build the flat stretch and compare.** Change both gateways to `next-hop-unchanged` on the DCI session and advertise every loopback across the DCI instead of just the gateways'. Get it working. Then answer, with evidence from `show vxlan vtep`:

1. How many remote VTEPs does leafA now have?
2. How many prefixes does the DCI underlay carry?
3. What happens at site B if leafA's VTEP becomes unreachable?

Then put it back and say in one sentence what the gateway buys you.

**B3 Scale the thought experiment.** With the gateway model, work out how many VTEPs a leaf tracks and how many prefixes the DCI underlay carries at 2, 5 and 20 sites with 40 leaves each. Do the same for the flat stretch. The two numbers that matter grow very differently.

**B4 Narrow what is extended.** Stretching a VLAN across sites is the expensive choice. Pick VLAN 10 and argue the case for and against extending it, then describe what you would need to change in the application for VLAN 10 to become site-local like 20 and 30.

**B5 Break the DCI, deliberately.** Shut bgwA's `Ethernet3` with a continuous ping running from hA1 to hB1 and from hA2 to hB2. Time both. Explain why the two numbers differ and what each one is waiting for.

**B6 Site survivability.** With the DCI down, confirm that each site still works entirely on its own: hA1 to hA2, hB1 to hB2, both gateways still in their own fabric. Then say what would have been true instead if you had built the flat stretch, and why that is the real argument for the gateway.

## Part C: Troubleshooting (deploy `solution`)

```bash
./lab.sh verify          # baseline all PASS
./lab.sh break random    # or a number 1-8
```

Symptoms in `docs/TICKETS.md`. `./lab.sh tunnels` is the fastest first move for anything where the control plane looks healthy and traffic does not flow, and `./lab.sh stretch` when the L2 extension specifically is broken.

Two of these eight produce a dead data plane with every session Established. Two take a session down and are told apart only by which layer you check. One breaks L2 and leaves L3 working, one does the exact reverse, and that pair is worth doing back to back.

## Part D: Design review (no config)

1. You are asked to justify the gateway model over a flat stretch to someone who thinks it is needless complexity. Make the case in terms of failure domains and underlay size, and concede the cases where they are right.
2. Each site has one gateway, which is a single point of failure. Describe the redundant design with two gateways per site, and name what you now have to prevent that you did not before.
3. A third site is coming. Compare a full mesh of DCI sessions against a hub site, and say at what point you would change your answer.
4. The application team wants VLAN 10 extended to all three sites so they can move VMs between them without renumbering. Give them an honest answer: what it costs, what breaks when the DCI is lost, and what you would propose instead.
5. Your two sites currently use the same route-target scheme. Describe what changes if site B were an acquisition with its own conflicting scheme, and where you would translate.
6. Recent EOS has purpose-built VXLAN-to-VXLAN stitching rather than the `next-hop-self` approach here. Find out whether your build has it, and compare the two: what the dedicated feature gives you that this does not, and what you lose in portability.
