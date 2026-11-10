# Lab 14 Tasks — Global Backbone Traffic Engineering

Three parts. Part A is reading a working network and accounting for every
path. Part B is the eight faults. Part C is design.

There is no `base` mode. The network deploys working, because the skill is not
building it — it is knowing whose backbone is carrying what, and noticing when
that quietly changes.

---

## Part A — Account for every path

### A1. Baseline

```bash
./lab.sh deploy
./lab.sh verify
./lab.sh dist
./lab.sh med
./lab.sh gttmed
./lab.sh potato
./lab.sh inbound
./lab.sh anycast
./lab.sh latency
```

Save `potato`, `inbound`, `anycast` and `latency`. `./lab.sh restore` is the
only way back.

### A2. The ring

1. From `./lab.sh dist`: why is `ash -> sin` 235ms rather than the 175+65=240ms
   the other way round the ring? Name both candidate paths and their costs.
2. The ring has four spans and six PoP pairs, so two pairs have no direct
   span. Which two, and which PoP does each transit through?
3. Each span's RTT is used as the netem delay, the OSPF cost **and** the MED.
   Give one concrete advantage and one concrete risk of tying all three to one
   number.
4. OSPF cost is configured per interface and therefore per direction. Pick any
   span and describe what an asymmetric cost would do that a symmetric one
   would not — and which of the tools in this lab would show it.

### A3. Outbound: hot potato against cold potato

5. In `potato`, every PoP exits at `sin` for `100.150.0.0/16` but each PoP
   exits at **itself** for `100.200.0.0/16`. Both are transit prefixes at
   local-pref 100. Explain the difference from `./lab.sh gttmed`, naming the
   best-path step that decides it.
6. `lhr` carries traffic 160ms to Singapore for `100.150.0.0/16`. Work out
   what the transit's own backbone would have carried if we had hot-potatoed
   it instead, using `gttmed`. Who saves, and how much?
7. Total the backbone milliseconds in `potato`. Then state, in one sentence,
   what we bought with them.
8. `sea` exits at `lhr` for the CDN — 140ms of our backbone to reach a free
   peer, instead of 0ms to reach paid transit. Name the two BGP attributes
   that produce that outcome, in the order they are compared.
9. For the CDN prefix, `sea` chooses `lhr` (140ms) over `sin` (175ms). Both
   are iBGP paths at local-pref 200 with equal MED and equal AS path. Which
   best-path step breaks the tie, and what would happen if the two were
   equidistant?
10. Every PoP exits at `lhr` for `100.140.0.0/16`, including Singapore, which
    carries it 160ms. The same prefix is available from the transit at
    Singapore with MED 160. Why does the peer win, and at what traffic volume
    would you revisit that?

### A4. Inbound: the half you cannot see

11. In `inbound`, `gtte` enters at `via-gttw` for `198.51.100.0/24`. Explain
    what the transit is doing with that traffic and why it agreed to.
12. `gttw` enters at `via-gtte` for `203.0.113.0/24`, and `gtte` enters at
    `lhr` for the same prefix. Both are correct. Account for both from the MED
    table and the best-path order.
13. Run `show ip bgp 198.51.100.0/24` on `gtte`. It has three paths, not four,
    even though all four of our PoPs announce it. Why three?
14. Our MED only works because something is true about the transit. State it
    precisely, and say what would have to change in our configuration if the
    four handoffs belonged to four different ASes.
15. Nothing in our own routing table would tell us if a PoP stopped announcing
    one of our prefixes. Name two ways to detect it from inside, and one from
    outside.

### A5. Anycast

16. `anycast` shows two entry points at `gttw`, two at `gtte`, two at `cdn`,
    and one at `peereu`. Account for each number.
17. The anycast prefix is MED 0 from all four PoPs on purpose, which is the
    opposite of what we do for every unicast prefix. Explain why equal MED is
    the correct choice for anycast, in terms of where each source enters.
18. What would happen to anycast traffic if we applied the unicast MED scheme
    to it — MED 0 at one PoP and the ring distance elsewhere? Be specific
    about which users would be hurt.
19. `198.18.1.0/24` is absent from `cdn` and `peereu` and present at both
    transit routers. Name the mechanism, say which direction it does and does
    not restrict, and explain why the prefix is announced from one PoP only.

---

## Part B — The faults

```bash
./lab.sh break
./lab.sh verify
./lab.sh potato
./lab.sh inbound
./lab.sh anycast
./lab.sh latency
```

Eight faults. **All eight leave every BGP session Established and every OSPF
adjacency full.** Nothing goes down and nothing pages. Four are invisible in
our own routing table, and two of those four can only be seen from outside
our AS.

Rules of engagement:

- Diff `potato`, `inbound`, `anycast` and `latency` against your Part A
  copies. That is the whole method.
- The four PoPs run generated, symmetric policy. Any asymmetry between them
  is a finding, and five of the eight faults are one PoP disagreeing with its
  three siblings.
- When an exit is wrong, read `show ip bgp <prefix>` and compare the paths
  attribute by attribute, in best-path order. Three faults are a single
  attribute with a wrong value, and they look identical from the routing table.
- Two faults produce the same symptom in the same cell, and one masks the
  other.
- One fault is an OSPF cost, and because cost is per direction its effect is
  asymmetric. Check both directions before concluding anything.
- `./lab.sh hint [n]` exists. `./lab.sh reveal` lists active faults.

For each fault write down: the symptom as the tooling showed it, the device,
the command that proves it, the fix, the milliseconds or risk it cost, and
**what would have alerted on it in production — and if nothing would have,
what you would build.**

### B1. Fix them

You are done when `verify` is clean and all four tool outputs match Part A.

### B2. Then answer these

20. Rank the eight by how long each would survive in production before anybody
    noticed. Which survives longest, and what makes it invisible?
21. Four faults are one wrong number in one route-map clause. Name them and
    the attribute each one touches, then say why the same class of error
    produces four completely different symptoms. Then name the four that are
    not of that class, and what each of those is instead.
22. Two faults hit the same cell of `potato`. Name them, name the single
    command that separates them, and say which must be fixed first.
23. One fault costs a whole region its anycast traffic while every reachability
    check still passes. Which one, and which tool shows it?
24. One fault makes us advertise a prefix we had deliberately scoped. Which
    one, who can see it that could not before, and why does the mechanism not
    stop it inside the transit's own AS?
25. One fault moves work off the transit's backbone and onto ours. One moves
    work off a free interconnect and onto a paid one. Name both, say who pays
    in each case and in what currency, and say which of the two you would
    escalate first.
26. One fault leaves our routing tables entirely correct and is only visible
    from a device we do not operate. Which one, what do we lose, and how would
    you monitor for it with no access to that device?

---

## Part C — Design

No configuration.

### C1. Potato policy

27. Write the policy for when this network should accept a transit's MED and
    when it should strip it. Give the rule, then the two exceptions.
28. MED is only comparable between paths from the same neighbouring AS.
    Explain what `always-compare-med` changes, the specific failure it is
    famous for, and why most large networks leave it off.
29. You are a transit provider rather than a content network. Does your potato
    policy invert? Work through it for an eyeball network and for a content
    network as your customer.
30. Our backbone carries a total from `potato` in milliseconds. Convert that
    into the question a capacity planner actually asks, and name the data you
    would need that this lab cannot produce.

### C2. Inbound traffic engineering

31. Rank the tools for steering inbound traffic — MED, AS-path prepend,
    selective announcement, more-specific announcement, communities offered by
    the upstream — by how reliable each is and how blunt each is.
32. A peer ignores your MED. Give three ways to achieve the same result, and
    the cost of each.
33. You need 70% of inbound traffic at `lhr` and 30% at `ash`, from one
    transit. Design it, and say why the result will not be 70/30.
34. Describe what you would have to build to know, without asking anyone,
    which of your PoPs the internet is actually entering at.

### C3. Anycast

35. Give the three failure modes of BGP anycast that prefix announcement alone
    cannot address, and the mechanism that addresses each.
36. A PoP's service is broken but the router is healthy. Describe the full
    withdrawal path, from health check to the internet converging, and the
    worst case for how long it takes.
37. Anycast against DNS-based steering against both. Compare on convergence
    time, granularity, client correctness and operational risk.
38. You run anycast from four PoPs and one is in a region with poor transit.
    Traffic lands there and is slow. Give three fixes, in increasing order of
    how much you give up.

### C4. What this lab cannot show

39. Name three backbone TE failure modes this lab is structurally incapable of
    reproducing, and say what each would need.
40. The ring in this lab has four nodes and four spans. Name what changes
    qualitatively — not just in degree — when it has forty nodes, and which of
    the tools in this lab would stop being useful.
