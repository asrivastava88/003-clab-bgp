# Lab 18 Tasks — Three Regions, Two Carriers

Twelve faults across 38 nodes. Several have their cause in one region and
their symptom in another, which at this size means you cannot find them by
looking. You have to bisect.

---

## Part A — The design

```bash
./lab.sh deploy
./lab.sh verify
./lab.sh regions ; ./lab.sh transit ; ./lab.sh table ; ./lab.sh width ; ./lab.sh anycast
```

Save all five.

1. Write out the AS path a route to Ashburn's aggregate carries when it
   arrives at a Seattle leaf, hop by hop, naming every ASN and what tier it
   belongs to.
2. Lab 17's result was that the ASN plan prevents transit for free. Show, with
   a concrete AS path, why that is still true **inside** a region here and
   **not true between** regions. Name the exact property of the carriers that
   breaks it.
3. If both carriers were the same AS, would region transit still be possible?
   Work it out from loop detection, then say whether you would therefore buy
   both circuits from one carrier.
4. A border announces exactly two prefixes to each carrier. Name them and say
   why the region's loopbacks are not among them, when the pod's loopbacks
   *are* announced to the super-spines.
5. There are two aggregation boundaries. For each one, name who originates the
   aggregate, what the far side should see, and what the far side would see if
   that boundary stopped summarising.
6. `RM-WAN-IN` on every border has a `deny 5` that drops the region's own
   space. Given that the carriers would be sending it back only if somebody
   leaked it, is that clause load-bearing or decorative? Argue it.
7. From `width`: a Seattle leaf has 2 next hops to Ashburn's aggregate. Count
   the distinct physical paths from that leaf to an Ashburn leaf, and say how
   many any single router knows about.
8. From `anycast`: the prefix is originated once per region and every region
   serves itself. Name the attribute that makes that work and the one that
   would break it if a border got it wrong.

---

## Part B — The twelve faults

```bash
./lab.sh break
# wait ~90s, this is 38 nodes
./lab.sh verify ; ./lab.sh regions ; ./lab.sh transit ; ./lab.sh table ; ./lab.sh width ; ./lab.sh anycast
```

Rules of engagement:

- **Bisect by tier, then by region.** A symptom at a leaf in London could have
  its cause at a leaf in London, a spine, a super-spine, a border, a carrier,
  or a border in Seattle. Work down the path; do not guess.
- **Faults 1 and 2 are a pair.** One is a leak that hurts nobody. The other is
  a filtering mistake in somebody else's network. Together they put production
  traffic across a region that never agreed to carry it.
- Exactly one fault takes a session down. Finding it is easy; the discipline is
  not letting it absorb the time the other eleven need.
- Several faults are silent in every sense: reachable, sessions up, no alarm.
- `./lab.sh hint [n]` exists. `./lab.sh reveal` lists active faults.

For each fault: the symptom, the device, the command that proves it, the fix,
and what would have alerted on it in production.

### B1. Fix them

You are done when `verify` is clean and all five tool outputs match Part A.

### B2. Then answer these

9.  Faults 1 and 2: name each one, say what each does alone, and describe the
    traffic that flows when both are live. Which AS path proves it, and on
    which device would you read it?
10. Fault 2 is in a network you do not operate. Describe how you would have
    discovered it, what you would send the carrier, and what you would change
    on your own side in the meantime.
11. One fault makes a destination unreachable while **two** aggregates above it
    still cover it. Trace the packet and name the hop where it dies. Compare
    that distance to the equivalent fault in Lab 17.
12. One fault leaks a pod aggregate to the carriers. Which tool shows it, how
    many extra prefixes, and why does the other border of the same region not
    leak?
13. Two faults halve a width in different ways: one at a super-spine, one with
    something that is not BGP at all. Name both and the command that
    distinguishes them.
14. One fault concentrates inbound traffic for a whole region on one border.
    Name the mechanism, say where you would observe it, and say why nothing
    inside that region can see it.
15. One fault makes one region's users cross a WAN to reach a service that
    exists in their own building. Which one, and which tool shows it?
16. One fault leaves a leaf single-homed. Everything still works. What event
    turns it into an outage, and how many racks does it take out?
17. Rank all twelve by how long each would survive in production. Which
    survives longest, and is it in your network or somebody else's?
18. Of the twelve, how many would the Lab 16 config audit have caught before
    deployment? Name them and what the audit asserts.

---

## Part C — Design at this size

19. Write the outbound policy for a region border as you would hand it to
    somebody building region four. State what it permits, what it denies, and
    the one-line justification for each.
20. Design the alarm that catches fault 1 within minutes. Say what it polls,
    from where, what it compares against, and why it cannot be built from
    inside your own AS alone.
21. You have three regions and two carriers. Draw the failure matrix: for each
    single failure (a border, a carrier, a region's pair of circuits to one
    carrier), say what is lost and what still works.
22. Region transit is prevented by policy here. Name two other mechanisms that
    would prevent it independently, and say what each one costs.
23. At what point would you stop using two carriers and build your own
    backbone between regions? Give the inputs to that decision, not just the
    answer.
24. The anycast prefix is originated in all three regions with no health check.
    Describe what breaks and design the control, including what withdraws the
    prefix and how fast.
25. You are adding region four in Singapore, 180 ms from London. What changes
    in the ASN plan, the address plan, the border policy and the carrier
    contracts? Name the one thing that would force a change to an existing
    region.
26. Name three failure modes of a real three-region network this lab cannot
    reproduce, and what each would need.
