# Lab 01 Tasks

## Part A: Build (deploy `base`)

Base configs contain only hostnames, P2P addressing, loopbacks and `ip routing`. Build the rest. Constraints: no IGP, no static routes, all policy by prefix-list and route-map, configs must be reusable across leaves (peer groups).

| # | Task | Done when |
|---|---|---|
| A1 | eBGP underlay. Spines AS 65100, leaves per the ASN table. Advertise only Loopback0/Loopback1 with a route-map on `redistribute connected`. Enable 4-way ECMP. | Every leaf has every remote `10.0.1.x/32` with 2 next hops. |
| A2 | EVPN overlay sessions between Loopback0s (leaf to spine, eBGP multihop). Spines must not rewrite next hop. | `show bgp evpn summary` Established on all nodes. |
| A3 | VLANs 10/20/30 on the right leaves, access ports, MAC-VRFs with the RD/RT scheme, `redistribute learned`. | Type-3 IMET from every VTEP that shares the VNI; h1 pings h2; h5 pings h4. |
| A4 | VRFs RED/BLUE, L3VNIs 50001/50002, anycast gateway (`ip address virtual`) with the shared virtual MAC. | Type-2 MAC-IP carry 2 RTs + router-MAC; h1 pings h3. |
| A5 | Border: VRF-lite to isp1 per VRF, eBGP to AS 65000 in each VRF. | `show ip route vrf RED 0.0.0.0/0` on leaf1 points to VTEP 10.0.1.14; h1 and h4 ping 203.0.113.10. |
| A6 | Inter-tenant via fusion. isp1 is preconfigured. Explain why it works without `allowas-in` anywhere. | h1 pings h4; `./lab.sh verify` is all PASS. |

Questions to answer in your notebook before moving on:

1. Why do both spines share one ASN while each leaf gets its own? What breaks if spines have unique ASNs?
2. Why `next-hop-unchanged` on spines for EVPN but not for the underlay?
3. Why does a type-2 MAC-IP route carry two route targets and a router-MAC extended community?
4. leaf2 has no VLAN 20. How does h2 reach h3?
5. Trace the AS_PATH of 10.10.10.0/24 from leaf1 to the BLUE table on leaf3. Which knob on isp1 makes this loop-free?

## Part B: Troubleshooting (deploy `solution`)

```bash
./lab.sh verify          # baseline all PASS
./lab.sh break random    # or: ./lab.sh break 4
```

Read the matching symptom in `docs/TICKETS.md` (blind mode: work only from `verify` output). Rules: no `show running-config` diffs against the reference until you have a written hypothesis. Target time per ticket: 10 minutes.

## Part C: Traffic engineering and design (deploy `solution`)

**TE-1 Spine maintenance.** Drain spine2 so no VXLAN traffic transits it, without dropping a single BGP session. Prove it with route tables on two leaves. Then explain why you drained the underlay and not the EVPN sessions.

**TE-2 WAN hygiene.** isp1 currently learns every tenant /32 host route. Send only tenant subnets (/24 and shorter) to the WAN in both VRFs. Do not touch isp1. Compare an outbound route-map against `aggregate-address ... summary-only` and pick one.

**TE-3 Tenant segmentation.** Security says: RED_WEB (10.10.10.0/24) may talk to BLUE; RED_DB (10.10.20.0/24) must never reach BLUE. Implement it and prove it with pings in both directions. Warning: the obvious answer fails. Find out why.

**TE-4 Design review (no config).** An app team wants RED traffic to use spine1 and BLUE traffic to use spine2. Answer: is this possible in this fabric, why or why not, and what would you propose instead.

**TE-5 Design review (no config).** The border leaf is a single point of failure for both VRFs and for inter-tenant traffic. Propose the target design (devices, sessions, policy) and state what changes on isp1.
