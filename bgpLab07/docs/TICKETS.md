# Lab 07 Tickets (symptoms only, `solution` baseline)

Inject with `./lab.sh break <n>`, restore with `./lab.sh restore`.

`./lab.sh matrix` after `./lab.sh verify` will usually show you the shape of the problem faster than reading config.

| # | Reported by | Symptom |
|---|---|---|
| 1 | Internal audit | Our quarterly isolation review found that hosts in GREEN can reach hosts in RED. Nothing is down and no user has complained. The change log for this week shows a route-target edit on two leaves. |
| 2 | App team | BLUE hosts cannot use the shared DNS server. They can get a reply from their own gateway, and the RED and GREEN teams report no problems with DNS. |
| 3 | App team | Nobody can reach the shared services host from any tenant. Hosts in VLAN 100 can still reach it, and it can still reach its own gateway. |
| 4 | App team | RED hosts on leaf2 lost access to RED subnets that live on leaf1. Same-subnet traffic between the two leaves is fine. |
| 5 | Security | RED and BLUE can no longer reach each other. The fusion sessions are up on both sides and the fusion device has the prefixes in its table. |
| 6 | App team | RED and BLUE stopped reaching each other this morning. Nothing else changed and shared services still work from both. |
| 7 | App team | Everything attached to leaf2 lost its default gateway at the same time, across three different tenants. leaf1's hosts are unaffected. |
| 8 | App team | The two RED hosts in 10.10.10.0/24 cannot reach each other, even though they are in the same subnet. Both can reach the shared services host and both can reach 10.10.11.1. |
