# BGP Lab 06: Pure BGP — A Multi-AS Internet Edge

**Level:** CCIE EI / CCIE SP | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

No EVPN. No VXLAN. No VRFs. Eight routers in six autonomous systems, which is the setting where BGP itself actually gets exercised rather than being plumbing underneath an overlay.

The subject is the **customer / peer / transit policy triangle**: who you may announce what to, how you signal that with communities, and what goes wrong when you get it backwards. Getting it wrong in the real world either costs money or leaks the internet. Both are reproducible here.

## Topology

```
                                +-------------+
                                |     far     |  AS 65600
                                | 10.6.0.0/16 |
                                +-------------+
                                 E1   E2   E3
                                 |    |     |
                 +---------------+    |     +-----------------+
                 |                    |                       |
         +--------------+    +--------------+        +--------------+
         |   transitA   |    |   transitB   |        |    peerX     |
         |   AS 65200   |    |   AS 65300   |        |   AS 65400   |
         | 10.200.0.0/16|    | 10.201.0.0/16|        | 10.202.0.0/16|
         |  + default   |    |  + default   |        |  no default  |
         +--------------+    +--------------+        +--------------+
                E1                  E1                     E1
                |                   |                       |
             (paid)              (paid)                  (free)
                |                   |                       |
               E3                  E3                      E4
         +--------------+    +--------------+               |
         |    edge1     |-E2-|    edge2     |               |
         | 10.100.0.2   | 100| 10.100.0.3   |---------------+
         +--------------+    +--------------+
               E1 cost 10          E1 cost 30          E4
                 \                  /                  |
                  \                /            +--------------+
                   +--------------+             |    cust1     |
                   |     core     |             |   AS 65500   |
                   | 10.100.0.1   |             | 10.5.0.0/16  |
                   | originates   |             +--------------+
                   | 4 x /20      |
                   +--------------+

   AS 65100 is ours: OSPF area 0 internally, iBGP full mesh across all three.
   core holds no eBGP session, which is what makes next-hop-self on the edges
   load-bearing. The OSPF costs (10 via edge1, 30 via edge2) exist so the IGP
   metric to the next hop can be made the deciding tie-breaker.
```

## Addressing

| Item | Value |
|---|---|
| Our ASN | 65100 |
| Our address space | 10.100.0.0/16, de-aggregated as four /20s originated by `core` (10.100.16.0/20, .32.0/20, .48.0/20, .64.0/20) |
| Loopback0 (router-id, iBGP) | core 10.100.0.1, edge1 10.100.0.2, edge2 10.100.0.3 |
| Internal links | 10.100.255.0/31 core-edge1, .2/31 core-edge2, .4/31 edge1-edge2 |
| eBGP links | 172.16.12.0/30 edge1-transitA, .13.0/30 edge2-transitB, .14.0/30 edge1-peerX, .15.0/30 edge2-cust1, .26.0/30 transitA-far, .36.0/30 transitB-far, .46.0/30 peerX-far |

Every external AS has a pingable address inside the space it originates: `10.200.0.1`, `10.201.0.1`, `10.202.0.1`, `10.5.0.1`, `10.6.0.1`.

`cust1` also announces `10.5.100.0/24` and `10.5.101.0/24`, which we have *not* registered and must filter.

## The community scheme

Tag on ingress by neighbor type, decide on egress by the tag. This is how real networks do egress policy, because by the time a route reaches your other edge router the session it arrived on is long forgotten.

| Community | Meaning | LOCAL_PREF |
|---|---|---|
| 65100:200 | learned from a customer | 200 |
| 65100:150 | learned from a settlement-free peer | 150 |
| 65100:100 | learned from a paid upstream | 100 |

Preference order falls out of that: customer beats peer beats transit, because a customer pays us, a peer is free, and a transit costs money.

Egress is default-deny:

| To a | We announce |
|---|---|
| transit | our aggregate, plus customer prefixes |
| peer | our aggregate, plus customer prefixes |
| customer | everything, or at minimum a default |

Announcing a transit-learned or peer-learned route to a transit or a peer is the mistake. It makes you free transit for other people's traffic, and at scale it is a route leak incident.

## Modes

| Mode | What is configured | Use |
|---|---|---|
| `base` | OSPF, iBGP full mesh with next-hop-self, all eBGP sessions up, **zero policy**. We accept and re-announce everything. | Part A. `verify` reports the leaks it finds instead of passing. |
| `solution` | The full triangle: ingress tagging, egress default-deny, customer prefix filter, aggregation, prefix limits. | Part B onward, and the baseline for the 8 tickets. |

External ASes are permissive in both modes, deliberately. You control your policy, not theirs, and a leak only reads as a leak if the far side accepts it.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy solution      # one mode per deploy: base or solution
./lab.sh verify               # sessions, triangle, leak checks, aggregation, data plane
./lab.sh leaks                # everything we advertise, per neighbor, in full
./lab.sh bestpath 10.6.0.0/16 # the decision for one prefix on all three of our routers
./lab.sh break random         # solution baseline; then ./lab.sh reveal or restore
./lab.sh cli edge1
./lab.sh destroy
```

RAM: 8 cEOS nodes, roughly 11 to 13 GB. Boot plus convergence takes 3 to 4 minutes.

## Files

```
bgp-lab06.clab.yml     topology
lab.sh                 deploy | verify | leaks | bestpath | break | restore | cli
configs/base|solution/ rendered configs (external ASes included)
tools/gen_configs.py   one data model, both modes
docs/TASKS.md          Part A build, Part B best path, Part C tickets, Part D design
docs/TICKETS.md        symptoms only
docs/SOLUTIONS.md      spoilers
```

## Caveats, and what I deliberately left out

Three features that belong in a lab like this are **not** in the shipped configs, because I could not confirm their exact EOS syntax and I would rather you discover it with `?` than inherit a guess:

- **Conditional advertisement** (announce a prefix only while some other prefix is absent). Arista does have this feature, but I could not verify the command names. Part B task B5 has you find it.
- **GTSM / TTL security** on the eBGP sessions. The EOS manual lists a "Configuring GTSM for BGP" section; confirm the command on your build. Part D question 4.
- **AS_PATH access-lists and regex** for customer-cone filtering. `match as-path <list-name>` and `match as-path length <op> <n>` both exist on EOS; the syntax for creating the list is what I could not pin down. Part B task B4 uses it.

Everything that *is* shipped uses commands I verified or have already run in labs 01 to 05.

Other notes:

- `maximum-routes` on the customer session is set to 50 against 3 announced prefixes, which is realistic headroom. Ticket 6 drops it below the actual count.
- Our ASNs are all private, so `remove-private-as` would be nonsense here. Part D question 3 covers where it does belong.
- cEOS forwards in software.
- Every node boots from its own `startup-config`. `./lab.sh restore` is the reset.

## Sources

- [EOS 4.36.2F Border Gateway Protocol (BGP), Arista](https://www.arista.com/en/um-eos/eos-border-gateway-protocol-bgp) — large-community set/match syntax, `send-community large`, GTSM section
- [arista.eos.eos_route_maps module](https://docs.ansible.com/ansible/latest/collections/arista/eos/eos_route_maps_module.html) — confirms `match as-path <list>`, `match as-path length`, `set as-path prepend last-as`, `match community ... instances`, and the `graceful-shutdown` community flag
- [Overview of the BGP Conditional Advertisement Feature, Arista Community](https://arista.my.site.com/AristaCommunity/s/article/OVERVIEW-OF-THE-BGP-CONDITIONAL-ADVERTISEMENT-FEATURE) — the feature exists; the article body did not load for me

## Lab series

| Lab | Focus |
|---|---|
| 01 | eBGP Clos, EVPN L2/L3VNI, symmetric IRB, VRF-lite border, fusion routing |
| 02 | Dual-ISP edge: local-pref, MED, prepend, communities, RTBH, BFD |
| 03 | EVPN multihoming (ESI-LAG) vs MLAG |
| 04 | iBGP overlay, spine route reflectors, add-path, OSPF underlay |
| 05 | Unnumbered eBGP underlay, RFC 8950, IPv6 link-local peering |
| 06 | Pure BGP: multi-AS internet edge, the policy triangle, aggregation, leaks (this lab) |
| 07 | Inter-VRF route leaking inside EVPN vs centralized fusion |
| 08 | Multi-site DCI: EVPN gateway, type-5 re-origination, domain path |
| 09 | SONiC as an EVPN leaf in a mixed Arista/SONiC fabric |
| 10 | Convergence engineering: BFD, timers, graceful restart, maintenance mode |
| 11 | BGP security and scale: max-prefix, GTSM, RPKI concepts, policy frameworks |
