# Lab 15 Tasks — A Dual-Stack Carrier Edge

Three parts. Part A reads a working dual-stack network and establishes what
parity means. Part B is the eight faults, none of which breaks IPv4. Part C is
design.

There is no `base` mode. The network deploys working.

---

## Part A — What parity means

### A1. Baseline

```bash
./lab.sh deploy
./lab.sh verify
./lab.sh afi
./lab.sh exits
./lab.sh parity
```

Save `afi` and `exits`. `./lab.sh restore` is the only way back.

### A2. Read the audit before you read the routers

1. `parity` reports four declared exceptions and no undeclared divergence.
   State each exception and why it is legitimate. For each one, say what would
   have to change in the network for it to stop being legitimate.
2. The audit works because of a naming convention: `RM-FOO` / `RM-FOO6` and
   `PL-FOO` / `PL6-FOO`. Explain why a convention is a prerequisite for a
   structural audit, and name two other operational things it buys you.
3. `parity` compares prefix-list **entry counts** for some lists and not for
   others. Look at `PL-BOGON` against `PL6-BOGON` and explain why that
   exclusion is correct, then name the risk the exclusion creates.
4. The audit is syntactic: it compares structure, not meaning. Give a concrete
   divergence it would miss entirely, and say what would catch that instead.

### A3. Dual-stack state

5. In `afi`, every IPv4 column matches its IPv6 column except where a
   relationship is single-family. Walk the `edge1:t1` row and account for each
   of the six numbers.
6. `edge1` accepts 2 prefixes from `transit1` in each family, but `transit1`
   announces 3 in each. Identify the third and say what stops it, in both
   families, naming both mechanisms that would have.
7. `transit1` announces `198.18.1.0/24` and `2001:db8:18::/48` on purpose. Work
   out what fraction of our own space each one covers, and explain why a
   more-specific of your own space is more dangerous than a copy of it.
8. In `exits`, `edge1` reaches `transit2`'s space via `edge2` in both families.
   Describe the full path that IPv6 route took to become usable at `edge1`,
   naming the one configuration line it depends on.
9. `peer2` has no row in `exits` and no IPv4 twin anywhere. Name two things
   that get harder to operate because a relationship exists in only one
   address family.

### A4. The maintenance

```bash
./lab.sh drain edge1
# read the output carefully
./lab.sh afi
./lab.sh undrain
```

10. The drain output shows paths at `transit1` still at 2 in both families.
    Explain why "still present" is the success criterion rather than "gone",
    and what would be true of the network if the count had dropped to 1.
11. The drain does three things on each session. Name all three, say which
    direction each one steers, and say which of the three the far end can
    choose to ignore.
12. `65535:0` is sent outbound while drained. Name it, say what a peer that
    honours it does, and say what happens when — as here — the peer does not.
13. Write the order of operations for a real maintenance on `edge1`: what you
    do before the drain, what you verify during it, and what you verify after
    the undrain. Give the specific commands for the verification steps.

---

## Part B — The faults

```bash
./lab.sh break
./lab.sh verify
./lab.sh afi
./lab.sh exits
```

**Do Part B in two passes, and keep them separate — the contrast is the
lesson.**

**Pass one: state only.** Do not run `parity` yet. Using `verify`, `afi`,
`exits` and the routers, find as many faults as you can. Write down how many
you found and which ones. Then also write down, for each one you found, what
would have alerted on it in production.

**Pass two: the audit.** Now run `./lab.sh parity`. Note how many faults it
names that pass one missed, and how much more precisely it names the ones you
had already found.

Rules of engagement:

- **No fault breaks IPv4.** Checking IPv4 tells you nothing.
- One fault has no symptom at all on a healthy network. You will only see it
  in the audit, or by running a drain.
- Two faults compound so that one makes the other unobservable. Fix order
  matters, and the order is derivable from what each fault does.
- `./lab.sh hint [n]` exists. `./lab.sh reveal` lists active faults.

### B1. Fix them

You are done when `verify` is clean, `afi` and `exits` match Part A, `parity`
reports only the four declared exceptions, and `./lab.sh drain edge1` comes
back green in both families.

### B2. Then answer these

14. How many of the eight did pass one find? For each one pass one missed, say
    precisely why state monitoring could not see it.
15. Rank the eight by how long each would survive in production. Which
    survives longest, and what makes it invisible?
16. Two faults compound. Name them, say which must be fixed first, and explain
    what the second one looks like while the first is live.
17. One fault means we accept a more-specific of our own space from a transit
    in IPv6 while IPv4 correctly rejects the identical announcement. Name the
    fault, and name **both** mechanisms that reject it in IPv4 — then say
    which of the two is missing in IPv6 and why the other one does not save us.
18. One fault silently halves the redundancy of a relationship rather than
    breaking it. Which one, what is the surviving path, and what event turns
    it into an outage?
19. One fault costs our customer their global IPv6 reachability from one of
    our two borders. Which one, why is the customer still reachable, and whose
    problem is it contractually?
20. One fault reverses an inbound traffic-engineering decision in one family
    only. Name it, say what the far end now believes, and say which command on
    whose router proves it.
21. One fault leaves a BGP path present and the routing table empty. Name the
    mechanism, say which family and why only that family, and give the two
    commands that together prove it.
22. Of the eight, how many would a config audit have caught **before**
    deployment? Of those, how many would a state check ever catch at all?

---

## Part C — Design

No configuration.

### C1. Running two networks

23. Write the policy that would have prevented six of these eight faults. It
    is one sentence about how configuration is produced, and one about what is
    checked before it ships.
24. Argue for and against a **single** BGP session carrying both address
    families, against the two-session-per-peer model this lab uses. Cover
    failure independence, policy divergence, convergence and what your
    monitoring sees.
25. Your monitoring has IPv4 session and prefix-count alerts and nothing for
    IPv6. List, in order, the five IPv6 checks you would add, and say what
    each one catches that the others do not.
26. A peer is IPv6-only today and adds IPv4 next quarter. Describe everything
    that has to change, including the things that are not configuration.
27. Describe how you would test, continuously and without human effort, that
    your IPv6 network actually works end to end. Be specific about what you
    probe, from where, and what you assert.

### C2. IPv6 specifics

28. IPv6 routers do not fragment. Explain the full consequence for a network
    with a 9100 core and 1500 handoffs, the failure signature, and the fix at
    each layer.
29. The IPv6 DFZ accepts /48s and the IPv4 DFZ accepts /24s. Explain what that
    difference does to your inbound filters, your `maximum-prefix` limits, and
    your de-aggregation options for traffic engineering.
30. Name three IPv6-specific things that belong in an inbound filter and have
    no IPv4 equivalent, and say what each one prevents.
31. You hold a /32 and assign /48s to customers. A customer asks you to accept
    their /56 for traffic engineering. Give your answer and the reasoning.

### C3. Graceful operations

32. `GRACEFUL_SHUTDOWN` is a request, not a mechanism. Design a maintenance
    procedure that works even when no peer honours it, and say what the
    community buys you when some do.
33. Compare draining by local-pref, by prepend, by `GRACEFUL_SHUTDOWN`, and by
    withdrawing. Give the convergence behaviour and the blast radius of each,
    and say which combination you would actually deploy.
34. Your drain works in IPv4 and withdraws in IPv6. You are twenty minutes
    into a four-hour maintenance window with the optics already out. Decide
    what to do and justify it.
35. Design the pre-maintenance check that would have caught question 34 before
    the window opened. Say what it asserts, where it runs, and why it has to
    be a config check rather than a state check.

### C4. What this lab cannot show

36. Name three dual-stack failure modes this lab is structurally incapable of
    reproducing, and say what each one would need.
