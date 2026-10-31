# Lab 03 Tickets (symptoms only, `solution` baseline)

Inject with `./lab.sh break <n>`, restore with `./lab.sh restore`.

| # | Reported by | Symptom |
|---|---|---|
| 1 | Server team | hm1's bond is up on both links, but we see duplicate broadcast and ARP traffic, and the host's MAC keeps moving in the fabric. |
| 2 | Server team | hm1 lost half its bandwidth overnight. Only one bond member is in the aggregator now. No link went down. |
| 3 | Network | Traffic to hm1 from the rest of the fabric all lands on one leaf. The other leaf carries nothing, even though both links are up and the host is active on both. |
| 4 | Capacity | Roughly half of all traffic toward hm2 is being dropped. hm2 itself is fine and both its links are up. |
| 5 | Change review | After a change on leaf4, the MLAG pair is no longer a pair. Both switches are forwarding on their own. |
| 6 | NOC | leaf3 and leaf4 can't agree on MLAG state. The peer link is up and the port-channel is up. |
| 7 | Server team | hm2's bond only has one member in the aggregator. The other port is up but not bundling. |
| 8 | Network | Nothing behind leaf1 is reachable from the rest of the fabric, and leaf1's ethernet segment no longer shows a peer. All BGP sessions are Established. |
