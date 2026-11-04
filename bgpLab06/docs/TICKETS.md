# Lab 06 Tickets (symptoms only, `solution` baseline)

Inject with `./lab.sh break <n>`, restore with `./lab.sh restore`.

Half of these are not outages. Deciding whether anything is actually broken, and what it is costing, is part of the work.

| # | Reported by | Symptom |
|---|---|---|
| 1 | NOC | `core` can see external prefixes in BGP but cannot reach anything outside our AS through edge2. Every session is Established and OSPF is clean. |
| 2 | Peering coordinator | transitB's NOC called. They say they are receiving routes from us that belong to transitA, and they want to know why they are carrying our traffic for free. Nothing is down. |
| 3 | Security | Our customer announced `10.6.0.0/16` this morning and we accepted it. That prefix is not theirs. It is now in our table and we are telling the world about it. |
| 4 | Finance | Our transit bill jumped. Traffic that used to leave over the free peering session is now going out a paid upstream. Everything still works. |
| 5 | Peering coordinator | We are announcing a lot more to transitA than we agreed. The aggregate is there, but so is a pile of more-specifics out of our own space. |
| 6 | Customer | cust1 says their session keeps dropping and coming back. It was stable yesterday and they have not changed anything. |
| 7 | Peering coordinator | peerX says we are announcing them the full table instead of just our own and our customer's prefixes. They are threatening to shut the session. |
| 8 | Customer | cust1 says they are unreachable from about half the internet. Their session to us is up, we have their prefix, and they can reach things through us fine. |
