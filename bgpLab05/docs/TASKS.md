# Lab 05 Tasks

## Part A: Build it (deploy `base`)

IPv6 is enabled on the fabric links. VLANs, SVIs, the VRF and Vxlan1 exist. There is no BGP. Build the underlay unnumbered, then the overlay.

Do **not** add IPv4 addresses to Ethernet1 or Ethernet2 on anything. If you find yourself wanting to, that is the habit this lab is for.

| # | Task | Done when |
|---|---|---|
| A1 | Confirm the links have link-local IPv6 and nothing else, and that each device can see its neighbors. | `show ipv6 interface brief` shows `fe80::` on Et1/Et2; `show ipv6 neighbors` lists 2 on each leaf and 3 on each spine. |
| A2 | Underlay: interface-based eBGP in a peer group. Leaves to AS 65100, spines to the matching leaf ASN. | `show ip bgp summary` Established everywhere, peers shown by interface rather than address. |
| A3 | Advertise both loopbacks with a route-map on `redistribute connected`. | Sessions carry prefixes, but check the next hop before you celebrate. |
| A4 | Make the IPv4 loopbacks usable across the fabric. | `show ip route 10.0.1.12` on leaf1 resolves through an `fe80::` next hop, and `ping 10.0.1.12 source 10.0.1.11` works. |
| A5 | Overlay: eBGP EVPN between Loopback0s, multihop, spines preserving the next hop. | `show bgp evpn summary` Established; `show vxlan vtep` on leaf1 lists two leaf Lo1 addresses and no spine. |
| A6 | MAC-VRFs and the IP-VRF with the RD/RT scheme from the README. | `./lab.sh verify` all PASS. |

A3 and A4 are deliberately separate. Getting prefixes into BGP and making them forwardable are two different problems here, and the gap between them is the whole subject of the lab.

Questions before Part B:

1. No interface on the fabric has an IPv4 address, yet `ping 10.0.1.12 source 10.0.1.11` works. Walk the packet: what is in the outer header, what MAC does it leave with, and which table supplied that MAC?
2. `ipv6 unicast-routing` is on, and the fabric routes no IPv6 prefixes at all. What exactly does that command enable here?
3. A leaf needs one line to define both underlay neighbors. A spine needs three. Why, and what EOS feature's absence causes it?
4. The EVPN overlay stanza is identical in `numbered` and `unnumbered` mode. Why does the overlay not care, and what would have to change if the overlay rode the interface sessions instead of the loopbacks?
5. Run `./lab.sh diff leaf`. List everything that differs between leaf1 and leaf2, then say which of those a templating tool would have to supply per device.

## Part B: Mechanics (deploy `unnumbered`)

**B1 Trace the chain.** Run `./lab.sh nexthops` and write the five steps in your own words. Then find, with your own commands, the point at which an IPv4 destination becomes an Ethernet frame on a specific port.

**B2 Compare the two builds.** Deploy `numbered`, run `./lab.sh verify`, then deploy `unnumbered` and verify again. Both should pass. Now run `./lab.sh diff modes` and answer: of the lines that changed, which ones are a reduction in per-device state and which are simply a different spelling of the same thing?

**B3 Prove or disprove the uniformity claim.** The argument for unnumbered is that leaf configs become interchangeable. Using `./lab.sh diff leaf`, quantify it: how many lines differ, and how many of those would also differ in a numbered fabric? Decide whether the claim holds, and say what still needs per-device allocation.

**B4 Break the resolution, not the session.** With the fabric healthy, find a way to leave every BGP session Established while making a remote VTEP unreachable. There are at least three. Then pick the one you would be least likely to catch with your current monitoring and say what alert you would add.

**B5 Grow the fabric.** Write out, line for line, the complete config you would add to bring up a fourth leaf (leaf4, AS 65104, Lo0 10.0.0.14, Lo1 10.0.1.14, Ethernet3 on both spines). Count the lines that touch the spines and compare with what the numbered build would need. That number is the operational argument for unnumbered.

## Part C: Troubleshooting (deploy `unnumbered`)

```bash
./lab.sh verify          # baseline all PASS
./lab.sh break random    # or a number 1-8
```

Symptoms in `docs/TICKETS.md`. `./lab.sh nexthops` is the fastest first move for anything involving reachability.

A warning specific to this lab: several of these tickets produce *no error message anywhere*. An unnumbered session that fails to form does not tell you what it was looking for. Get used to checking `show ipv6 neighbors` before `show ip bgp summary`.

## Part D: Design review (no config)

1. Give the honest case for and against unnumbered underlays. Include the operational arguments, not just the technical ones, and name the environments where you would not use it.
2. The overlay here peers on loopbacks. Cumulus and FRR commonly run EVPN on the interface sessions themselves, with no loopback peering and no multihop. Explain what has to be true about next-hop handling for that to work, why it is harder with eBGP than iBGP, and what you would test first on EOS before trying it.
3. Your monitoring currently alerts on BGP session state and interface state. In this fabric, name three failures that both would miss, and the check you would add for each.
4. A vendor's unnumbered implementation interoperates with yours for the sessions but delivers next hops your platform cannot resolve. Describe how you would isolate that to the sending or receiving side, and what you would ask each vendor for.
5. Someone proposes going further: IPv6-only underlay *and* IPv6 VTEPs, so the outer VXLAN header is IPv6 too. What changes in the EVPN control plane, and what would you check for support before committing?
