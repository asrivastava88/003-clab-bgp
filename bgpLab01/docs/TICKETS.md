# Lab 01 Tickets (symptoms only)

Inject with `./lab.sh break <n>` on a `solution` deployment. Restore with `./lab.sh restore`.

| # | Reported by | Symptom |
|---|---|---|
| 1 | App team | Everything behind leaf3 (h3, h4) is unreachable from other leaves. h3 and h4 can ping their gateway. Underlay looks fine. |
| 2 | Web team | h1 and h2 (both 10.10.10.0/24, different leaves) cannot reach each other. h1 to h3 still works. |
| 3 | DBA | h3 can ping its gateway and nothing else. No other host complains. |
| 4 | NOC | Nothing attached to leaf1 is reachable from any other leaf. Every leaf1 BGP session is Established. |
| 5 | App team | h3 and h4 cannot ping their default gateway. Other hosts are fine. |
| 6 | Change review | Ops "cleaned up a prefix-list" on leaf2. h2 is now unreachable. All BGP sessions Established and leaf1 shows h2's MAC-IP route in EVPN. |
| 7 | Security | Inter-tenant (RED to BLUE) traffic stopped after the WAN team's change window. Internet still works from both VRFs. |
| 8 | NOC | After a spine1 "standardization", east-west VXLAN traffic across the fabric fails. Underlay ECMP and all sessions look healthy. |
