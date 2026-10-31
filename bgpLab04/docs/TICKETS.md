# Lab 04 Tickets (symptoms only, `addpath` baseline)

Inject with `./lab.sh break <n>`, restore with `./lab.sh restore`.

| # | Reported by | Symptom |
|---|---|---|
| 1 | App team | Nothing behind leaf2 is reachable from anywhere else, and leaf2 cannot reach anything either. Every BGP session on leaf2 is Established and the underlay is clean. |
| 2 | NOC | East-west traffic across the fabric is failing after a change on spine1. Sessions are up, OSPF is clean, and the leaves are learning routes. |
| 3 | Capacity | leaf1 is carrying all its traffic over a single uplink. Both uplinks are physically up and both its BGP sessions are Established. |
| 4 | Change review | leaf2 lost one of its two underlay adjacencies after an OSPF cleanup. The interface is up and pings its neighbor fine. |
| 5 | App team | Nothing behind leaf1 is reachable from the rest of the fabric. All sessions Established, OSPF clean, and leaf1 is advertising its routes. |
| 6 | Config audit | Our two reflectors are advertising a different number of paths for the default route. Internet traffic is working and still load-shares across both borders. Is this actually a problem, and what breaks if we leave it? |
| 7 | Capacity | leaf1 uses only one border for Internet traffic. Its BGP table clearly shows two valid paths for the default. |
| 8 | Capacity | Every leaf now sends Internet traffic through bleaf1 only. bleaf2's eBGP session to wan is up and it has the default in its own VRF table. |
