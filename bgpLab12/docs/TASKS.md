# Lab 12 Tasks — Rail-Optimized AI/HPC Fabric

Four parts. Part A establishes what "healthy" looks like, which in this lab is
not a thing you can ping for. Part B is the eight faults. Part C is design.

There is no `base` mode. The fabric deploys working, because the point of this
lab is not building it — it is noticing when a working fabric is running at
half speed.

---

## Part A — Baseline (do this before you break anything)

### A1. Establish the width matrix

```bash
./lab.sh deploy
./lab.sh verify
./lab.sh width
```

**Save the width matrix.** Paste it into a file. It is the only artefact in
this lab that matters, and once you inject faults you cannot get it back
without `./lab.sh restore`.

### A2. Account for every number in it

For each cell, say why it is what it is before you read the table in the
README. Specifically:

1. Why does `rail1 → gpu1` show **1** while `gpu1 → gpu2` shows **2**?
2. Why does `spine1 → storage` show **1**?
3. `nfs1 → gpu1` shows **1** and `stor1 → gpu1` shows **2**. nfs1 sits one hop
   behind stor1. What does that tell you about where ECMP width lives, and
   what it means for a single-attached server in a fabric that is otherwise
   dual-everything?
4. The diagonal cells read `-` rather than `0`. Why is a node's route to its
   own endpoint not a width?

### A3. Confirm rail locality

```bash
./lab.sh rail gpu2 10.10.0.1
```

Read the traceroute. Count the hops. Then:

5. How many hops is gpu2 → gpu1, and which device is in the middle?
6. Now `./lab.sh rail gpu1 10.20.0.1`. How many hops, and why is it different?
7. On rail1, run `show ip route 10.10.0.2`. Nothing in that output mentions a
   spine. Explain, in terms of BGP path selection, why rail1 never considers
   the spine path to a GPU that is directly attached to it.

### A4. Read the BGP table like an AI fabric engineer

```bash
./lab.sh cli gpu1
show ip bgp 10.10.0.2/32
show ip route 10.10.0.2
show ip bgp summary
```

8. `show ip bgp 10.10.0.2/32` lists two paths. What makes them eligible for
   multipath here? Name every attribute that has to match, and check each one.
9. Both rails are in AS 65101. Both spines are in AS 65100. Change nothing,
   but work out: if rail1 were AS 65101 and rail2 were AS 65102, what would
   `show ip route 10.10.0.2` show on gpu1, and why? What single command would
   you need, and on which devices?
10. gpu1 holds its endpoint on Loopback1, not on Ethernet1. Why does that
   matter when a NIC fails? Compare against the same failure on a server whose
   address lives on the NIC.

### A5. Baseline the frame size

```bash
./lab.sh sizes gpu1 10.20.0.1
```

All sizes should pass. Then:

11. `show interfaces Ethernet1 | include MTU` on rail1, and
    `docker exec clab-bgp-lab12-rail1 ip link show eth1` on your host. Two
    different MTUs, two different layers. Which one does the ping actually hit
    first, and what would you see if only the EOS one were right?

---

## Part B — The faults

```bash
./lab.sh break            # all eight at once
./lab.sh verify
./lab.sh width            # diff against your Part A matrix
```

Eight faults. **Seven of them leave every endpoint pingable.** If you work
this lab by pinging things you will find one fault and conclude the other
seven do not exist.

Rules of engagement:

- Work from the width matrix, not from `verify`. `verify` tells you observed
  versus expected and nothing else; it is a scoreboard, not a diagnosis.
- Compare twins. rail1 against rail2. spine1 against spine2. gpu1, gpu2, gpu3
  against each other. A fabric this symmetric means any asymmetry is a finding.
- Compare rows against columns. One fault is a direction.
- Two **pairs** of faults mask each other. When you fix one, a second symptom
  appears that was not there a moment ago. That is not you breaking something.
- When a width is wrong, always separate *how many paths BGP has* from *how
  many it installed*. `show ip bgp <prefix>` answers the first,
  `show ip route <prefix>` the second. Two faults in this lab are
  indistinguishable unless you look at both.
- `./lab.sh hint [n]` exists. `./lab.sh reveal` lists which faults are active,
  which is cheating but occasionally merciful.

For each fault, write down: the symptom as the matrix showed it, the device,
the command that proves it, the fix, and — the part people skip — **what would
have alerted on this in production, and if nothing would have, what you would
add.**

### B1. Fix them

Work through all eight. Re-run `./lab.sh verify` as you go. You are done when
verify is clean and your width matrix matches Part A exactly.

### B2. Then answer these

12. Rank the eight faults by how long each would survive in a production
    fabric before anybody noticed. Which one survives longest, and what makes
    it invisible?
13. Three faults are the same misconfiguration on three different devices.
    Which three? Why does the symptom look different on each?
14. One fault produces no change in the width matrix at all. Which one, and
    what test does find it? Its visibility also depends on another fault
    being live — explain why, and what happens to it once you fix that one.
15. One fault is latent: it changes nothing today. Which one, and what event
    makes it matter?
16. Two faults affect gpu3 and one hides the other. Two more affect stor1 and
    neither one alone changes anything. Identify both pairs. For the gpu3
    pair, say which is upstream. For the stor1 pair, say which single command
    distinguishes them. Then state what this implies about the order you fix
    things in when several faults are live at once.

---

## Part C — Design review

No configuration. These are the questions an interview panel asks.

### C1. ASN allocation

17. This fabric gives both rails the same ASN and both spines the same ASN.
    State the benefit precisely: which BGP comparison does it make
    unnecessary, and what command would you otherwise need?
18. Now argue the other side. What do you lose by sharing an ASN across rails?
    Consider: loop prevention between rails, the blast radius of a
    misconfiguration, your ability to write per-rail policy, and what
    `show ip bgp` tells you about where a route came from.
19. The industry default for a Clos is one ASN per leaf. Why does this lab
    deviate, and under what fabric size would you stop deviating?

### C2. Width as the service level

20. Write the monitoring rule you would actually deploy for this fabric. Not
    "alert on interface down" — a rule that fires on the faults in Part B.
    Where does it run, what does it poll, and what is the threshold?
21. A GPU server has two NICs and shows width 2 to every peer. One NIC is
    running at 100G and the other negotiated 25G. Every check in this lab
    passes. What is the job doing, and what would you have to measure to see
    it?
22. ECMP hashing here is per-flow. An all-reduce between 8 ranks opens a small
    number of long-lived, high-bandwidth flows. Explain flow polarization in
    that context, and name two mitigations a real fabric uses.

### C3. Scaling the design

23. Scale this to 8 rails, 16 spines and 128 GPU servers. Give the ASN plan,
    the IP plan, the per-device port count, and the oversubscription ratio.
    State which of the three is your binding constraint.
24. At that size, would you keep BGP on the host? Argue both ways. Consider
    session count on the rail switches, config management on 128 servers, and
    what happens during a rolling OS upgrade of the compute fleet.
25. This design has no overlay. A second tenant arrives and needs isolation
    from the first. What is the cheapest change that gives it to them, and at
    what point do you give up and build the EVPN fabric from Lab 07?
26. Storage is one leaf with one node. In a real fabric storage is its own
    rail-less pod with its own oversubscription. Why does storage traffic want
    a different fabric shape from collective traffic?

### C4. What this lab cannot show you

27. Name three failure modes of a production AI fabric that this lab is
    structurally incapable of reproducing, and say what you would need to
    reproduce each. Be specific about why containers cannot do it.
