# Lab 16 Tasks — The Model Is the Network

Three parts. Part A is reading a generated network and understanding what the
rules bought. Part B is eight drifts, two of which are in the model. Part C is
design.

There is no `base` mode. The network deploys from the model.

---

## Part A — What generation buys you

### A1. Read the plan before the routers

```bash
./lab.sh plan
./lab.sh addresses
./lab.sh links
./lab.sh deploy
./lab.sh verify
./lab.sh audit
```

1. From `addresses`: `10.3.0.2` belongs to which region and which router, and
   how did you know without looking anything up? State the rule you applied.
2. The loopback rule is `10.{R}.0.{N}/32`. Work out how many regions and how
   many routers per region this scheme supports before it breaks, and name the
   first thing that breaks.
3. Link ids are assigned in the order the model lists links. Explain why that
   makes the scheme stable when a region is added, and name the one editing
   operation on `model/network.yml` that would renumber half the network.
4. The interface assignment rule is "backbone links sorted by the far end's
   name, then external links". `est-r1` has `Ethernet3` to `wst-r1`. Derive
   that from the rule, then say what would have to change for it to become
   `Ethernet2`.
5. `ospf_cost_inter` is the measured RTT. Give one real advantage and one real
   risk of a cost that is a measurement rather than a design decision.

### A2. What the model does not say

6. `model/network.yml` describes topology and `model/policy.yml` describes
   intent, and they are separate files. Give the operational reason, in terms
   of who changes each one and how often.
7. `./lab.sh render` rewrites the configs and pushes nothing. `./lab.sh
   remediate` pushes one device and asks you to confirm. Explain why those are
   two commands rather than one.
8. Run `./lab.sh show est-r1` and compare it to `./lab.sh cli est-r1` then
   `show running-config`. They are not textually identical even with no drift.
   Name three reasons, and say why the audit compares parsed structure rather
   than text.
9. `./lab.sh audit` on a clean network reports nothing. What class of error
   would it still miss entirely? Give a concrete example on this network.

### A3. The running network

10. Every inter-region shortest path is the direct link. Prove it for
    `wst-r1 -> eur-r1` from the costs in `./lab.sh links`, and say what the
    margin is.
11. `est-r2` is a route reflector client and holds the only peering session.
    Trace how `peer1`'s prefix reaches `wst-r2`, naming every router, every
    session type, and every place the next hop is rewritten.
12. `wst-r1` has two paths to the transit-only prefix and `est-r1` has one.
    Account for the difference.

---

## Part B — The eight drifts

```bash
./lab.sh break
./lab.sh verify
./lab.sh audit
```

**Work Part B in three passes. Keep them separate.**

**Pass one: state.** Using only `verify` and the routers, find what you can.
Write down how many of the eight you found.

**Pass two: audit.** Run `./lab.sh audit`. It will report more than pass one
found, and in more precise language.

**Pass three, and this is the lab:** for every finding, decide **which side is
wrong** before you touch anything. The audit tells you the model and the
network disagree. It does not tell you whether to fix the router or fix the
model, and for two of the eight the answer is the model.

Questions to ask of each finding, in order:

- Does the physical world agree with the model? A model that describes a link
  nobody ever cabled is not a drift, it is a wish.
- Is the device's value *defensible*? Not "does it work" — plenty of drift
  works — but could somebody have had a reason?
- When was the model last changed, and by whom? (This lab has no git history;
  Part C asks you to design that in.)
- If you remediate and you are wrong, what breaks and how fast would you know?

Rules of engagement:

- Several drifts change nothing `verify` can see.
- `./lab.sh restore` puts the devices **and** the model back.
- `./lab.sh remediate` asks you to type the device name. That prompt exists
  because it is the point of the lab; do not reflexively answer it.
- `./lab.sh hint [n]` exists. `./lab.sh reveal` lists active drifts.

### B1. Resolve them

For each drift: the finding, which side was wrong, the evidence you used to
decide, and the action. You are done when `audit` is clean **and** `verify` is
clean — and note that getting one of those two clean is easy and wrong.

### B2. Then answer these

13. How many of the eight did pass one find? For each one state monitoring
    missed, say precisely why it could not see it.
14. Two drifts are in the model. Name them, and for each one give the single
    piece of evidence that settles which side is wrong.
15. One drift would have been **caught by the audit and fixed incorrectly** by
    somebody who reflexively remediated. Which one, what would remediating
    have done, and how long before anybody noticed?
16. One drift is a hand-allocated address that works perfectly. Argue the case
    for leaving it, then say why you would still change it.
17. One drift adds a BGP neighbour the model does not describe, and it is
    administratively shut. Explain why `verify` cannot see it, why the audit
    can, and what the right disposition is for something labelled
    "temp_do_not_remove".
18. One drift changes an IGP cost on one side of a link only. Describe the
    resulting path asymmetry precisely, and name the command on which router
    proves it.
19. Rank the eight by how long each would survive in production. Which one
    survives longest, and is it a model drift or a network drift?
20. Of the eight, how many would a CI gate have caught **before** they reached
    a device? Describe the gate.

---

## Part C — Design

No configuration.

### C1. Making the model authoritative

21. Design the change-control pipeline this lab is missing. State what a change
    is (a diff against what), the gates it passes, and the single way config
    reaches a device. Name what you would block in CI.
22. The audit cannot tell which side is wrong. Design the metadata that would
    let it make a recommendation — what you would record, where, and at what
    moment.
23. Somebody has to fix a production outage at 3am and the pipeline takes 20
    minutes. Write the break-glass policy: what they are allowed to do, what is
    recorded, and what happens to their change afterwards.
24. Argue both sides of "the model should be generated from the network" —
    discovery-first — against "the network should be generated from the model".
    Say which you would pick for a greenfield build and which for a network
    that is already twenty years old.

### C2. Addressing at scale

25. Extend this scheme to 40 regions and 8 routers per region, with a DC fabric
    behind each region. Give the full plan: loopbacks, P2P, fabric space,
    ASNs. State which part of the current scheme breaks first.
26. Hyperscalers run point-to-point links unnumbered. Rework this network to
    use BGP unnumbered and say what disappears from `model/network.yml`, what
    disappears from the audit, and what new failure mode you have bought.
27. Argue for and against deriving addresses algorithmically versus allocating
    from an IPAM with an API. Cover: renumbering, mergers, delegation to a
    regional team, and what happens when somebody needs an exception.
28. A region is decommissioned. Describe exactly what happens to its address
    space, its link ids, and its ASN, and say which of the three you can safely
    reuse and when.

### C3. Drift in general

29. Name four sources of drift that are not a human typing on a router, and say
    which of them an audit against a model can and cannot catch.
30. This audit runs on demand. Design the continuous version: cadence, what it
    runs against, where findings go, and how you stop it becoming an alert
    nobody reads.
31. You inherit a network with no model. Describe how you would build one
    without a maintenance window, and name the point at which you would switch
    the source of truth from the network to the model.

### C4. What this lab cannot show

32. Name three drift-related failure modes this lab is structurally incapable
    of reproducing, and say what each one would need.
