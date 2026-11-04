# Lab 08 Tickets (symptoms only, `solution` baseline)

Inject with `./lab.sh break <n>`, restore with `./lab.sh restore`.

`./lab.sh tunnels` after `./lab.sh verify` will show you the shape of most of these faster than reading config.

| # | Reported by | Symptom |
|---|---|---|
| 1 | Site B NOC | Site B cannot reach anything in site A, in either subnet. Every session on both gateways is Established and site A reports that everything is fine from their side of the gateway. |
| 2 | Site A NOC | Site A cannot reach anything in site B. The DCI sessions are up, and site B can see site A's prefixes in its own tables. |
| 3 | App team | The stretched VLAN stopped working between sites. Hosts in the site-local subnets still reach each other across the DCI without any trouble. |
| 4 | NOC | The DCI EVPN session will not come up after a change on bgwA. The DCI link is up and the two gateways can ping each other across it. |
| 5 | App team | Site-local subnets can no longer reach each other across the DCI. The stretched VLAN is unaffected and still works in both directions. |
| 6 | App team | Same report as the previous ticket: site-local subnets cannot cross the DCI, stretched VLAN fine. Different cause. |
| 7 | NOC | The DCI EVPN session will not come up after a change on bgwA. The DCI link is up, the gateways can ping each other, and the underlay session between them is Established with the expected prefix. |
| 8 | App team | Hosts in the stretched VLAN at site B cannot reach the ones at site A. Site B hosts can still reach their own gateway and can still reach site A's site-local subnet. |
