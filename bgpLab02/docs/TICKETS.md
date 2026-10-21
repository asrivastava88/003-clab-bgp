# Lab 02 Tickets (symptoms only, `te` baseline)

Inject with `./lab.sh break <n>`, restore with `./lab.sh restore`.

| # | Reported by | Symptom |
|---|---|---|
| 1 | ispA NOC | One of your four sessions to us has been down since this morning's change. Nothing changed on our side. |
| 2 | App team | Hosts on leaf2 reach the Internet fine but cannot reach anything else in the data center. |
| 3 | Capacity | bleaf1 carries zero outbound Internet traffic. bleaf2 carries all of it. Both borders show every WAN session up. |
| 4 | ispA NOC | RED traffic we deliver to you lands on bleaf2. We thought bleaf1 was primary. |
| 5 | ispB NOC | We are delivering RED traffic from our customers straight to you instead of via our upstream, which your backup agreement says we should not. |
| 6 | Users | After ispA reported an issue on the bleaf1 circuit, RED users lost Internet access for about three minutes. The circuit never went down. |
| 7 | Security | After a "prefix-limit hardening" change, one BLUE WAN session is down. It came up briefly after the change, then dropped and has not recovered. |
