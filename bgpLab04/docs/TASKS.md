# Lab 04 Tasks

## Part A: Build the overlay (deploy `base`)

OSPF is converged and every loopback is reachable. VLANs, SVIs, the VRF and the Vxlan1 interface exist. There is no BGP anywhere. Build it.

| # | Task | Done when |
|---|---|---|
| A1 | On both spines, bring up an iBGP EVPN peer group in AS 65000, sourced from Loopback0, with every leaf and border as a **route reflector client**. Send extended communities. | `show bgp evpn summary` on each spine shows 4 Established. |
| A2 | On the four clients, peer to both spine Loopback0s. No client-to-client sessions. | `show bgp evpn summary` on each client shows 2 Established. |
| A3 | MAC-VRFs: VLAN 10 on leaf1 and leaf2, VLAN 20 on leaf2, with the RD/RT scheme from the README and `redistribute learned`. | h1 pings h2. |
| A4 | IP-VRF: VRF RED with the L3VNI, RD and RTs on all four clients. Borders carry the L3VNI only, no VLANs. | h1 pings h3. |
| A5 | Border egress: eBGP from each border to wan inside VRF RED, accepting only the default and 203.0.113.0/24 inbound, advertising only tenant /24s outbound. | h1 and h3 reach 203.0.113.10. |
| A6 | End to end. | `./lab.sh verify` all PASS. Note the final assertions: leaf1 holds **two** BGP paths for the default, one from each reflector, but installs only **one** VTEP next hop, because both reflectors chose the same border. |

Questions to answer before Part B. These are the ones that separate this design from labs 01 to 03:

1. In labs 01 to 03 the spines needed `neighbor EVPN next-hop-unchanged`. Here they need nothing. Why, and what single line on a spine would break every VTEP in the fabric?
2. Labs 01 to 03 used `redistribute connected` with a prefix-list to put loopbacks into BGP. This lab has none of that. Where do the loopbacks come from, and what breaks first if OSPF loses a link but the overlay session stays up?
3. Clients peer only to the spines, never to each other, yet leaf1 learns leaf2's MAC routes. Name the attributes the reflector adds when it does this, and say what each one is for.
4. Both borders learn an identical default from wan. Walk the best-path comparison on spine1 and name the tiebreaker that actually decides it.
5. leaf1 holds two BGP paths for the default and still has only one usable exit. Explain both halves of that: why there are two paths, and why they are not two exits. Then say why it is a correctness problem rather than just a capacity one.

## Part B: Add-path (deploy `solution`)

The overlay works. Both borders advertise a default. Clients see one.

**B1 Prove the hiding.** Run `./lab.sh paths`. Write down, in order: what each border originates, what each reflector holds, what each reflector advertises to leaf1, and what leaf1 ends up with in BGP and in the FIB. Identify exactly where the second path disappears.

**B2 Measure the cost.** With a continuous ping from h1 to 203.0.113.10, shut the WAN-facing interface on whichever border leaf1 is currently using. Time the outage. Explain which devices had to do work before traffic recovered, and why the other border being perfectly healthy did not help immediately.

**B3 Turn on add-path.** Enable it on the reflectors and on the clients. Verify that leaf1 now has two BGP paths and two VTEP next hops in the FIB. Repeat B2 and compare.

**B4 Scope it.** `send any` is the blunt setting. Read what the alternatives do on your build (`bgp additional-paths send ?`) and decide which you would run in production for an EVPN fabric with 40 leaves. Justify it in terms of what the reflector has to hold and send.

**B5 The alternative you did not use.** Add-path is not the only way to get two exits. Name at least two other designs that solve the same problem, and say what each costs. One of them involves no new BGP features at all.

When B3 is done, `./lab.sh verify` should match the `addpath` reference.

## Part C: Troubleshooting (deploy `addpath`)

```bash
./lab.sh verify          # baseline all PASS
./lab.sh break random    # or a number 1-8
```

Symptoms in `docs/TICKETS.md`. `./lab.sh paths` is the fastest first move for anything involving the default route. Rules as before: written hypothesis before any config diff, 10 minutes per ticket.

Two of these eight live in the underlay. Decide which plane you are in before you start typing.

## Part D: Design review (no config)

1. You have inherited this fabric and are asked whether to convert it to eBGP-everywhere like Lab 01. Give the honest case for each, including the operational reasons a team might keep iBGP even in greenfield.
2. The spines are route reflectors and also the only transit path. Someone proposes moving the RR function to two dedicated servers running a BGP daemon, off the data path. What improves, what gets worse, and what has to be true about the underlay for it to work at all?
3. At 40 leaves, the fabric has 40 iBGP sessions per spine and every type-2 route lands on both reflectors. Name the two scaling limits you would hit first and the mitigation for each.
4. A second data center is coming. Explain why a single ASN across both sites is usually the wrong answer, and what you would put at the boundary instead.
