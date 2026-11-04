# BGP Lab 10: Security at an Internet Edge

**Level:** CCIE EI / CCIE SP | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F (every node)

Every external neighbour in this lab misbehaves, on purpose. That is the input, not a fault.

| Neighbour | AS | What it does |
|---|---|---|
| `transit` | 65200 | leaks `10.0.0.0/8` at you alongside its real space |
| `peer1` | 65400 | leaks `192.168.50.0/24` at you |
| `cust1` | 65500 | behaves perfectly. The control. |
| `cust2` | 65501 | hijacks **your** address space, announces two bogons, announces unregistered more-specifics, and announces one prefix with **your own ASN already in the AS path** |

Your edge is supposed to survive all of it without you noticing. Then eight faults remove one layer of defence each, and you find out which layer was load-bearing for what.

As in Lab 09: `verify` gives no hints, and `./lab.sh break` injects every fault at once.

## Topology

```
  204.0.0.0/16              205.0.0.0/16
  + 10.0.0.0/8 (!)          + 192.168.50.0/24 (!)
  +----------------+        +----------------+
  |    transit     |        |     peer1      |
  |    AS 65200    |        |    AS 65400    |
  +----------------+        +----------------+
          | E1                      | E1
      208.0.1.0/30             208.0.2.0/30
          | E3                      | E4
      +--------------------------------+
      |             edge1              |  AS 65100
      +--------------------------------+
                 E1 |        | E2
            10.0.255.0/31    | 10.0.255.4/31
                    |        |
      +---------+   |        |   +--------------------------------+
      |  core   |---+        +---|             edge2              |
      | 203.0.  |                +--------------------------------+
      | 16.0/20 |                      | E3              | E4
      | 32.0/20 |                 208.0.3.0/30      208.0.4.0/30
      +---------+                      | E1              | E1
          | E3                 +----------------+ +----------------+
          h1                   |     cust1      | |     cust2      |
     203.0.48.101              |    AS 65500    | |    AS 65501    |
                               | 206.0.0.0/16   | | 207.0.0.0/16   |
                               | well behaved   | | + 203.0.0.0/16 (!) hijack
                               +----------------+ | + 192.168.100.0/24 (!)
                                                  | + 169.254.1.0/24 (!)
                                                  | + 207.0.9.0/24 with
                                                  |   AS 65100 in the path (!)
                                                  +----------------+
```

Addresses are deliberately well outside RFC1918 so the bogon filter is unambiguous about what is yours, theirs and junk. Our infrastructure (loopbacks, P2P links) stays on 10.x and is never announced externally, which means the bogon filter protects us from an outsider announcing it at us.

## The four layers

Each exists because the one below it has a blind spot, and each fault in this lab removes exactly one.

| Layer | Applies to | Catches | Blind spot |
|---|---|---|---|
| **Bogon deny** | every eBGP ingress | RFC1918, CGNAT, link-local, multicast, reserved | anything that is validly routable but not theirs |
| **Own-space deny** | every eBGP ingress | somebody outside originating your prefixes | a hijack of a third party's space |
| **Registered prefix-list** | customer ingress only | anything a customer did not register | peers and transits, whose cones you cannot enumerate |
| **Egress default-deny** | every eBGP egress | your inbound mistakes becoming a leak | nothing inbound |
| **maximum-routes** | every session | whatever the first four missed | tells you after the fact |

Note what the registered prefix-list does *not* cover. You can enumerate what a customer owns. You cannot enumerate what a transit provider's customers' customers own, which is why upstream sessions get bogon filtering and a prefix limit and nothing more specific.

And one defence needs no configuration at all: **AS-path loop detection**. A route arriving with your own ASN in its path is rejected by default. `cust2` announces one of those deliberately, and one fault switches that default off.

## Addressing

| Item | Value |
|---|---|
| Our ASN | 65100 (core, edge1, edge2) |
| Our space | 203.0.0.0/16, as 203.0.16.0/20, 203.0.32.0/20 and 203.0.48.0/24 |
| Internal | Lo0 10.0.0.1-3, P2P 10.0.255.x/31, OSPF area 0 + iBGP full mesh |
| eBGP links | transit 208.0.1.0/30, peer1 208.0.2.0/30, cust1 208.0.3.0/30, cust2 208.0.4.0/30 (our side always .1) |
| Registered | cust1 206.0.0.0/16 le 24, cust2 207.0.0.0/16 le 24 |

Pingable targets: `204.0.0.1`, `205.0.0.1`, `206.0.0.1`, `207.0.0.1`. Host h1 is `203.0.48.101`.

## Modes

| Mode | What is configured | Use |
|---|---|---|
| `base` | Sessions up, **no policy of any kind**. Every bogon, the hijack and the unregistered prefixes all land in your table, and go straight back out. | Part A. Look at what you accepted before you build anything. |
| `solution` | The full layered edge. | Part B onward, and the baseline the 8 faults regress from. |

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy base       # then: ./lab.sh inbound, and read what you accepted
./lab.sh deploy solution
./lab.sh verify            # no hints
./lab.sh break             # ALL 8 faults at once
./lab.sh verify            # the pass count is your progress bar
./lab.sh inbound cust2     # what one neighbour got past you
./lab.sh outbound          # what each neighbour holds that came from us
./lab.sh hint              # spoilers, if you want them
./lab.sh restore
```

RAM: 8 cEOS nodes, roughly 11 to 13 GB.

**`./lab.sh outbound` checks at the receiver, not at your own edge.** What you believe you advertised is not evidence; what the far side is holding is. Four of the eight faults are invisible from your own tables, which is the single most important habit this lab is trying to build.

## The fault model

`./lab.sh break` injects all eight. Half are about what you accepted and half about what you handed out. Two pairs are the same mistake on two different neighbour classes, so fixing one and declaring victory leaves you half done. `verify` is your progress bar and will not tell you what to change.

## Files

```
bgp-lab10.clab.yml     topology
lab.sh                 deploy | verify | inbound | outbound | break | restore | hint | cli
configs/base|solution/ rendered configs (external ASes and host included)
tools/gen_configs.py   BOGONS and CUST_REGISTERED at the top are the policy
docs/TASKS.md          Part A look, Part B build, Part C the eight faults, Part D design
docs/HINTS.md          spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md      the answers
```

## Deliberately not in the shipped config

Three things belong in a security lab and are **not** here, because I could not confirm their exact EOS syntax and would rather you find it with `?` than inherit a guess that breaks your sessions:

- **MD5 / TCP-AO session authentication.** `neighbor <ip> password ...` almost certainly exists; the argument form (encryption-type digit, placement) I could not verify, and a wrong one leaves sessions down and the lab unusable. Part B task B6.
- **GTSM / TTL security.** The EOS manual lists a "Configuring GTSM for BGP" section but I could not retrieve its body. Part B task B7.
- **AS-path filtering and maximum AS-path length.** `match as-path <list>` and `match as-path length <op> <n>` both exist; the command that *creates* the list is what I could not pin down. Part B task B8.

Everything shipped uses constructs you have already run in labs 01 to 09.

## Caveats

- `maximum-routes` is shipped in its basic form. The `warning-limit` option is part of task B5, including finding out what it is called on your build.
- RPKI and route origin validation need an external validator and are a Part D discussion rather than a configuration exercise.
- cEOS forwards in software.
- Every node boots from its own `startup-config`. `./lab.sh restore` is the reset.

## Sources

- [EOS Border Gateway Protocol (BGP), Arista](https://www.arista.com/en/um-eos/eos-border-gateway-protocol-bgp)
- [BGP Peering: Configuration Best Practices, Arista Community](https://arista.my.site.com/AristaCommunity/s/article/bgp-peering-configuration-best-practices-security-and-manageability)

## Lab series

| Lab | Focus |
|---|---|
| 01 | eBGP Clos, EVPN L2/L3VNI, symmetric IRB, VRF-lite border, fusion routing |
| 02 | Dual-ISP edge: local-pref, MED, prepend, communities, RTBH, BFD |
| 03 | EVPN multihoming (ESI-LAG) vs MLAG |
| 04 | iBGP overlay, spine route reflectors, add-path, OSPF underlay |
| 05 | Unnumbered eBGP underlay, RFC 8950, IPv6 link-local peering |
| 06 | Pure BGP: multi-AS internet edge, the policy triangle, aggregation, leaks |
| 07 | Multi-VRF EVPN: RT leaking, fusion, and proving isolation |
| 08 | Multi-site EVPN DCI: gateways, next-hop rewrite, underlay containment |
| 09 | Convergence and resiliency: BFD, timers, ECMP, drain |
| 10 | BGP security at an internet edge: bogons, hijacks, leaks, loops (this lab) |
| 11 | Mixed-vendor EVPN interop (scope to be agreed before building) |
