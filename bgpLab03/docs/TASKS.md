# Lab 03 Tasks

## Part A: Build both designs (deploy `base`)

The fabric, EVPN, VRF and orphan ports work. Both Port-Channels exist with member ports in `mode active`, and nothing else. The hosts already have their bonds configured. Build the two redundancy designs.

### A1 to A4: EVPN multihoming on leaf1 + leaf2

| # | Task | Done when |
|---|---|---|
| A1 | Give Port-Channel1 the same LACP system-id on both leaves so hm1 sees one partner. | `docker exec clab-bgp-lab03-hm1 cat /proc/net/bonding/bond0` shows both slaves up with one aggregator. |
| A2 | Configure the ethernet segment: same ESI on both leaves, plus the ES-import route-target. | `show evpn ethernet-segment` lists the ESI on both leaves with the peer discovered. |
| A3 | Confirm type-4 and type-1 routes exist. | leaf3 shows type-1 A-D routes from both 10.0.1.11 and 10.0.1.12. |
| A4 | Confirm exactly one leaf is DF for VLAN 10. | `show evpn ethernet-segment detail` on both leaves agrees on one DF. |

### A5 to A8: MLAG on leaf3 + leaf4

| # | Task | Done when |
|---|---|---|
| A5 | Build the peer link: trunk group on Port-Channel1000, peer VLAN 4094 in that group, SVI with `no autostate`, STP off for that VLAN. | `show interfaces Vlan4094` is up/up on both. |
| A6 | Configure the MLAG domain: matching domain-id, local-interface, peer-address, peer-link. | `show mlag` state active, negotiation connected, peer-link up. |
| A7 | Put Port-Channel2 into the MLAG. | `show mlag interfaces` shows Po2 as active-full. |
| A8 | Make the pair present one VTEP to the fabric. | leaf1 `show vxlan vtep` lists 10.0.1.34 once and never 10.0.1.13 or .14. |

Then: `./lab.sh verify` should be all PASS.

Questions to answer before moving on:

1. leaf1 and leaf2 have different ASNs and no link between them. How does leaf1 learn that leaf2 is on the same ethernet segment?
2. leaf3 and leaf4 share AS 65134. What happens to a route leaf3 originates when it arrives at leaf4 through a spine, and why does the lab add a BGP session across the peer link?
3. hm1's MAC is learned on exactly one of leaf1/leaf2 at any moment. How does leaf3 send traffic to that MAC across both VTEPs anyway? Name the route type.
4. Why does the MLAG pair need a shared VTEP IP while the ES pair must not share one?
5. What does the DF do that the non-DF does not? What breaks if both think they are DF?

## Part B: Behavior under failure (deploy `solution`)

**B1 Convergence comparison.**
```bash
./lab.sh converge hm1    # ESI-LAG side
./lab.sh converge hm2    # MLAG side
```
Record packets lost for each. Explain the difference in terms of what the remote leaf has to do in each case before it can forward again. One design makes the remote leaf re-run best path; the other hides the failure from it entirely.

**B2 Mass withdraw.** With a continuous ping running from hs2 to hm1, capture what leaf3 receives when leaf1's host link drops:
```
show bgp evpn route-type auto-discovery
show bgp evpn route-type mac-ip 10.10.10.101
```
Count the updates. Explain why pulling a segment with thousands of MACs behind it costs one update rather than thousands, and which type-1 subtype does it.

**B3 Aliasing proof.** On leaf3, find which leaf actually learned hm1's MAC (`show vxlan address-table vlan 10` on leaf1 and leaf2), then look at leaf3's forwarding entry for that MAC. Show that leaf3 load-balances to both VTEPs even though only one of them ever saw the frame.

**B4 DF behavior.** Start a continuous broadcast or multicast stream toward VLAN 10 from hs2 and watch both ES leaves with `tcpdump` on their host-facing port. Confirm only one forwards it. Then shut the DF's uplinks and confirm the other takes over, and time it.

**B5 Split brain.** Shut the MLAG peer link (`interface Port-Channel1000 / shutdown` on leaf3) while leaving both uplinks up. Describe what happens to Po2 on each peer and why. Compare with the ES side, where there is no peer link to lose. Unshut when done.

## Part C: Troubleshooting (deploy `solution`)

```bash
./lab.sh verify          # baseline all PASS
./lab.sh break random    # or a number 1-8
```

Symptoms in `docs/TICKETS.md`. `./lab.sh compare` is the fastest way to see both designs' state at once. Rules as before: written hypothesis before any config diff, 10 minutes per ticket.

## Part D: Design review (no config)

1. You are standardizing a new fabric. Give the honest case for MLAG and the honest case for EVPN MH, including the cases where MLAG is still the right answer.
2. EVPN MH scales past two leaves; MLAG does not. Name what actually breaks at three or four, and what type-1 and type-4 do differently with more peers.
3. Your storage team wants single-active multihoming for a device that cannot tolerate out-of-order frames. How does that change the ES config, and what happens to aliasing?
4. A server team reports intermittent duplicate packets on a dual-homed host. List the three causes you would check first in each design, in order.
