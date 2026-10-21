# Lab 02 Tasks

## Part A: Build the edge (deploy `base`)

The fabric works (`./lab.sh verify` fabric checks pass). Subinterfaces toward both ISPs are addressed. Read `docs/ISP-GUIDE.md` first.

| # | Task | Done when |
|---|---|---|
| A1 | On both borders, bring up eBGP per VRF to ispA and ispB (4 sessions per border). | `show ip bgp summary vrf all` shows 4 Established per border. |
| A2 | Inbound filter: accept only default and the three Internet /24s. | `show ip bgp vrf RED` on a border has exactly 4 prefixes per ISP. |
| A3 | Outbound filter per VRF: tenant subnets only, nothing longer than /24, never the other VRF. | ISP sees only 10.10.x/24 on RED sessions, 10.30.x/24 on BLUE. |
| A4 | Max-prefix protection on every WAN session. | Configured with a value that leaves headroom over the 4 prefixes received. |
| A5 | End to end. | `./lab.sh verify` all PASS in the Fabric and Edge sections. |

Questions:
1. Both borders share AS 65104. What does that do to routes one border learns from the other through the spines? Is that a bug or a feature here?
2. Each border learns the default from two ISPs but advertises only one into EVPN. Why, and what does that imply for where you must apply egress policy?
3. Why is filtering outbound per VRF mandatory, even though the ISP filters inbound too?

## Part B: Traffic engineering (deploy `solution`)

Business policy: **RED uses ispA, BLUE uses ispB, in both directions. Each ISP backs up the other.** Inside the primary ISP, RED should land on bleaf1 and BLUE on bleaf2.

**TE-1 Egress.** On both borders, set local-preference so RED prefers ispA and BLUE prefers ispB. Check leaf1's RED default (`show ip bgp vrf RED 0.0.0.0/0 detail`). It looks right. Now shut bleaf1 `Ethernet3.101` and check leaf1 again. Explain what you see. Then make the leaves honor the border's intent without hardcoding ISP knowledge on the leaves. Hint: the border knows the intent; the leaves only need a signal. Unshut when done.

**TE-2 Ingress, first attempt.** Prepend 65104 three times toward ispB for RED. Check inet's best path for 10.10.10.0/24. Then from ispB run `ping 10.10.10.101 source 198.51.100.1` and trace the path. Explain why ispB's own customer still comes in through ispB.

**TE-3 Ingress, done right.** Use the provider's community menu to fix TE-2 for both VRFs. Remove anything from TE-2 that is no longer needed. Verify on inet, ispA and ispB.

**TE-4 MED.** Make ispA deliver RED to bleaf1 and ispB deliver BLUE to bleaf2, with the other border as standby. Explain why MED works here, and name two situations where it would be ignored.

**TE-5 RTBH.** h1 (10.10.10.101) is under a volumetric attack. Get both providers to drop traffic to it at their edge without touching any other RED host. Build it so the next incident is a one-line change. Prove it, then withdraw it.

**TE-6 Grey failure.** Run `./lab.sh grey on`. The ispA to bleaf1 link stays up but ispA can no longer send to bleaf1. Measure how long RED inbound/outbound traffic suffers (`ping -i 0.2` from h1 to 203.0.113.10, plus `show ip bgp summary vrf all` on bleaf1). Fix it so the outage is under one second. `./lab.sh grey off` when done.

When finished, `./lab.sh verify` should match the `te` reference: 10 policy assertions PASS.

## Part C: Troubleshooting (deploy `te`)

```bash
./lab.sh verify          # all PASS
./lab.sh break random    # or a number 1-7
```

Symptoms are in `docs/TICKETS.md`. Same rules as Lab 01: written hypothesis before any config diff, 10 minutes per ticket.

## Part D: Design review (no config)

1. Leadership asks for "full Internet tables on the borders for better routing." Give the trade-offs for this fabric and your recommendation.
2. Add-path toward the fabric would let leaves see both ISP exits. What problem does it solve that communities and local-pref do not, and what does it cost?
3. ispA offers a second circuit to bleaf2 only. Redesign the inbound policy so a single circuit failure never shifts RED to ispB.
