# Lab 05 Tickets (symptoms only, `unnumbered` baseline)

Inject with `./lab.sh break <n>`, restore with `./lab.sh restore`.

Note: in this lab a broken session usually produces no error text at all. Several of these look identical from `show ip bgp summary` and are told apart only by looking a layer lower.

| # | Reported by | Symptom |
|---|---|---|
| 1 | NOC | leaf2 lost both underlay sessions after a change. Both links are up, and nothing in the logs says why. |
| 2 | NOC | leaf3 is down to one underlay session. The interface is up and the far side shows no error. |
| 3 | App team | Nothing behind leaf1 is reachable from anywhere in the fabric. Every session on leaf1 is Established and leaf1 is advertising its loopbacks. |
| 4 | Change review | One of spine2's three underlay sessions will not come up after a change window. The interface is up. |
| 5 | Capacity | leaf2's underlay sessions are both Established and have been for an hour. It has learned zero prefixes from either of them. |
| 6 | App team | Hosts behind leaf3 are unreachable. All sessions Established, OSPF n/a, and leaf1 can see leaf3's host routes in EVPN. |
| 7 | NOC | leaf1's EVPN sessions are both down. Its underlay is perfect and it can ping both spine loopbacks. |
| 8 | NOC | East-west traffic across the fabric fails after a spine1 change. Every session is up and the leaves are learning routes normally. |
