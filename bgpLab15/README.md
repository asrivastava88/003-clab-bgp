# BGP Lab 15: A Dual-Stack Carrier Edge, and What Happens When the Two Address Families Stop Agreeing

**Level:** carrier / peering architect | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F ×7

AS 65010 runs two border routers, buys two transits, peers with one network in both address families and with another in **IPv6 only**, and sells transit to one customer. Every external relationship is **two BGP sessions**, one per address family — which is what most networks actually run, and is exactly why the two families drift apart.

## The premise

**A dual-stack network is two networks that happen to share a chassis.** It is configured twice, changed twice, and monitored once — in IPv4.

Every fault in this lab is an IPv4/IPv6 divergence. None of them breaks IPv4. If you work this lab the way most networks are operated — check the sessions, check a few routes, ping something — you will conclude it is healthy, because in IPv4 it is.

## Two tools, and the contrast between them is the lesson

**`./lab.sh afi`** is a state check. For every relationship it puts IPv4 and IPv6 side by side: session state, prefixes accepted after policy, prefixes advertised. Anything that differs is a place where the two families were changed at different times.

```
  relationship     v4 state  v6 state  v4 recv   v6 recv   v4 adv    v6 adv
  ----------------------------------------------------------------------------
  edge1:t1         up        up        2         2         3         3
  edge1:p1         up        DOWN      1         0         3         3
  edge1:cu         up        up        1         1         3         2
```

**`./lab.sh parity`** is a **config** audit. It reads the running configuration off both borders and compares every IPv4 construct against its IPv6 twin — route-map clause counts, local-pref values, prepend lengths, communities, prefix-list entry counts, neighbour activation, policy attachment, next-hop-self, and whether both borders offer the same relationships.

```
  edge1
    LOCAL-PREF    RM-P1-IN sets [200], RM-P1-IN6 sets [80]
    ROUTE-MAP     RM-DRAIN-OUT6 has no permit clause at all, so it denies everything
```

The contrast is the point of the lab. `afi` finds what has already broken. `parity` finds divergence **before it has caused a symptom**, including policy that is only reachable during a maintenance window. One of the eight faults produces no symptom at all until you drain a border — and `parity` names it on a healthy network.

The convention that makes the audit possible is enforced by the generator: every IPv4 route-map `RM-FOO` has an IPv6 twin `RM-FOO6`, and every prefix-list `PL-FOO` has a `PL6-FOO`. A naming convention is not cosmetics; it is what makes a structural audit possible at all.

### Declared exceptions

An audit with no exception list is an audit nobody reads, because the intentional divergences drown the real ones. This one declares four and prints them separately:

- `peer2` is IPv6-only, so `RM-P2-IN6` has no IPv4 twin by design
- `transit2` is deliberately single-homed to `edge2`
- `cust1` is single-homed to `edge1`, by the customer's choice

In production that list comes from your peering database and your design docs, and every entry has to be justified out loud. That requirement is the control.

## Topology

```
     AS 65100 transit1 (dual stack)            AS 65200 transit2 (dual stack)
          +------------+                            +------------+
          |  transit1  |                            |  transit2  |
          +------------+                            +------------+
            E1      E2                                    E1
            |        |                                    |
   +--------+        +--------+                           |
   |                          |                           |
+---------------+      +---------------+ <-----------------+
|     edge1     |======|     edge2     |  9100 internal
|  10.255.0.1   |      |  10.255.0.2   |
| db8:ffff:ff::1|      | db8:ffff:ff::2|
+---------------+      +---------------+
  E2    E3    E4         E3    E4
  |     |     |          |     |
  |     |     +-- cust1 (AS 65400, dual stack, single-homed)
  |     |                |
  |     +----------------+--- peer2 (AS 65301, IPv6 ONLY)
  +----------------------+--- peer1 (AS 65300, dual stack PNI)

  our space        198.18.0.0/23 + 198.18.2.0/23     (RFC 2544, as /23s)
                   2001:db8:10::/44 + 2001:db8:20::/44 (RFC 3849, as /44s)
  customer         198.51.100.0/24 + 2001:db8:40::/48
```

The aggregates are /23s and /44s on purpose, so that a **more-specific of our own space exists**. `transit1` announces `198.18.1.0/24` and `2001:db8:18::/48` deliberately — both inside our own space, both short enough to pass the DFZ prefix-length bound, so the only thing that stops them is the explicit "never accept our own space" guard. One fault removes that guard in IPv6 and leaves it in IPv4: the same attack, caught in one family and not the other.

### Policy, identical in both families

| Relationship | Local-pref | Both families? |
|---|---|---|
| transit customer | 400 | yes |
| settlement-free peer | 200 | yes |
| transit1, primary | 100 | yes |
| transit2, backup | 90 | yes |

Outbound, every external session gets our two aggregates plus our customer's prefixes and nothing else. Toward `transit2` we prepend twice so inbound prefers `transit1`. All of it is supposed to be true twice.

## Maintenance, and the drain that only half works

`./lab.sh drain edge1` applies pre-staged drain policy to every external session on that border, in both families: prepend our AS three times outbound, set local-pref 50 inbound, and tag the announcement with **`65535:0`** — the RFC 8326 `GRACEFUL_SHUTDOWN` well-known community. Then it waits and checks the result at the transit, in both families:

```
  IPv4  paths at transit1: 2, both still present   best via: 10.1.2.1 (edge2)
  IPv6  paths at transit1: 1, expected 2           best via: ...12::1 (edge2)
```

**A correct drain leaves the path present and de-preferred**, so the drained border is still a backup. A drain that *withdraws* the path is not a drain, it is an outage with extra steps — and that is what an empty IPv6 drain route-map produces, because a route-map with no permit clause denies everything. Both lines must be green. One green and one red means the maintenance is safe for one address family and not the other.

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy
./lab.sh verify          # clean baseline
./lab.sh afi             # save this
./lab.sh exits           # save this
./lab.sh parity          # should report only the four declared exceptions
./lab.sh drain edge1     # watch both families move, then
./lab.sh undrain
./lab.sh break           # all 8 faults
```

RAM: 7 cEOS nodes, roughly 9–10 GB. The lightest lab in the series since 01.

## Rules

- `verify` reports observed versus expected. No hints.
- `./lab.sh break` injects all eight at once. `break <n>` for isolated practice.
- **No fault breaks IPv4.** Every one of the eight is an IPv4/IPv6 divergence.
- One fault has no symptom at all until you drain a border.
- Two faults compound so that one makes the other unobservable; fix order matters.
- `./lab.sh hint` exists.

## Caveats, and what this lab cannot teach

- **No PMTUD black holes.** IPv6 routers do not fragment, so IPv6 depends on ICMPv6 Packet Too Big getting through, and filtering it is one of the most common real dual-stack failures. Reproducing it needs a filtering middlebox this lab does not have. The MTU asymmetry here (9100 internal, 1500 on handoffs) is realistic but no fault exploits it.
- **No neighbour discovery or SLAAC faults.** `ipv6 nd ra suppress all` is set on every point-to-point link, which is correct practice and also removes a whole family of real problems — rogue RAs, address autoconfiguration on infrastructure links, ND cache exhaustion as a denial of service.
- **No link-local eBGP peering.** Every IPv6 session here uses global addresses. Peering on link-local is common and has its own failure modes; Lab 05 covers the unnumbered case.
- **No RPKI or IRR**, and no `maximum-prefix` behaviour under a real full table. Lab 13 covers prefix hygiene; this lab assumes it.
- **`GRACEFUL_SHUTDOWN` is sent as the raw value `65535:0`**, which is what the wire carries. Whether a given peer acts on it is their configuration, not ours, and the transits here do not. Part C question 32 is about what that means for planning a maintenance.
- **The parity audit is syntactic.** It compares structure, not meaning: two route-maps with matching clause counts and matching local-pref values can still match the wrong prefixes. It narrows where to look; it does not prove correctness.
- cEOS forwards in software.

## Files

```
bgp-lab15.clab.yml      topology, extended link format with per-link MTU
lab.sh                  deploy | verify | afi | exits | parity | drain | break | ...
tools/parity.py         the address-family config audit. The tool that matters.
tools/gen_configs.py    one data model renders all seven configs, twice over
configs/solution/       the working network. There is no base mode.
docs/TASKS.md           Part A analysis, Part B the eight faults, Part C design
docs/HINTS.md           spoilers, served by ./lab.sh hint
docs/SOLUTIONS.md       the answers
```

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
| 10 | BGP security at an internet edge: bogons, hijacks, leaks, loops |
| 11 | Capstone: eight faults that do not announce themselves |
| 12 | Rail-optimized AI/HPC fabric: no overlay, BGP to the host, ECMP width |
| 13 | Carriers, dark fibre, exchanges, cloud interconnect, long haul and subsea |
| 14 | Global backbone TE: hot potato, cold potato, MED, anycast |
| 15 | Dual-stack carrier edge: IPv4/IPv6 policy parity and graceful drain (this lab) |
