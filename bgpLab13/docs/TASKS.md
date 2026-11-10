# Lab 13 Tasks — Carriers, Dark Fibre, Exchanges, Long Haul and Subsea

Three parts. Part A is analysis of a working network, and it is the half of
this lab that has nothing to do with BGP. Part B is the eight faults. Part C
is design and economics.

There is no `base` mode. The network deploys working, because the point is not
building it — it is knowing what you bought, whether it is diverse, and what
the current policy costs per month.

---

## Part A — Read the plant before you read the routers

### A1. Baseline

```bash
./lab.sh deploy
./lab.sh verify
./lab.sh routes
./lab.sh exits
./lab.sh cost
./lab.sh latency
```

Save `exits`, `cost` and `latency`. They are your reference, and `./lab.sh
restore` is the only way back to them.

### A2. The diversity audit

```bash
./lab.sh srlg
./lab.sh srlgs
```

1. Six of seven intended-diverse pairs share fate. For each one, name the
   physical thing they share and say in one sentence what event takes both
   circuits.
2. `TRANSIT-1A` and `TRANSIT-1B` were sold to us as diverse access to the same
   carrier, from two of our sites. They share two SRLGs. Was the carrier
   lying? Answer carefully — the answer is not simply yes.
3. `WAVE-SEA-ASH-A` and `WAVE-SEA-ASH-B` are genuinely diverse for 4,000 km
   and share `CDT-ASHB-E`. What is the name for this pattern, where is it
   almost always found, and why does buying from two carriers not fix it?
4. `IX-PORT-A` and `IX-PORT-B` share `IX-FABRIC-SEA`. No amount of port
   diversity removes that. What would, and what does it cost?
5. `CLOUD-IC-A` and `CLOUD-IC-B` share `CLOUD-PE-SEA01`. Write the one
   sentence you would put in a ticket to the cloud provider, and say what you
   are asking them to prove.
6. Which single shared-risk group has the widest blast radius, how many
   circuits are in it, and what is left standing if it goes?

### A3. Cut a cable and watch nothing happen

```bash
./lab.sh cut CDT-ASHB-E
# wait 30s
./lab.sh verify
./lab.sh latency
./lab.sh uncut
```

7. Which circuit dropped and which survived? Compare `verify` before and
   after: how many BGP sessions changed state on the surviving path?
8. `latency` shows a step on the protected circuit. State the exact number,
   and explain why that step is the *only* evidence the cut happened.
9. Now write the monitoring rule that catches this. Where does it run, what
   does it measure, and what is the threshold? Be specific enough that
   somebody could build it.
10. Try `./lab.sh cut CDT-4TH-AVE`, which is the seven-circuit group. Before
    you run `verify`, predict which of our three sites is still reachable from
    the internet and by which path. Then check, and account for any difference.
    Run `./lab.sh uncut` afterwards.

### A4. Where the bits go, and what that costs

11. In `exits`, `transit2 own space` exits via `transit`, not `transit2`. Our
    expensive subsea backup is carrying essentially nothing. Is that correct?
    Justify it from the local-pref table and the per-Mbps rates.
12. `cost` shows every class exiting where it should, and a total. What
    fraction of that total is usage-based and what fraction is fixed? What
    does that ratio tell you about where to look for savings?
13. The CDN announces two /17s and no /16. Our filter permits
    `100.120.0.0/16 le 24`. Why is `le 24` there, what would `le 32` let a
    peer do to us, and what would no length bound at all let them do?
14. On `sea1`, run:
    ```
    show ip bgp neighbors 10.200.0.1 received-routes
    show ip bgp neighbors 10.200.0.1 routes
    ```
    The counts differ. Identify every prefix the route server is sending that
    our policy rejects, and say why each one is rejected. One of them should
    make you want to send an email.
15. The route server's AS appears in the AS path of routes we learn through
    it. A real IXP route server is transparent. Work out what difference that
    makes to (a) AS-path length comparisons against transit, and (b) an
    inbound filter that matches on the neighbouring AS.

### A5. Which circuit is internal traffic actually on

16. On `sea1`, `show ip route 10.255.0.3`. On `sea2`, the same. Explain why
    `sea2` reaches Ashburn through `sea1` rather than over its own direct
    wave, and say which design intent that serves.
17. Work out the OSPF arithmetic for all three internal paths and show that
    the result puts internal traffic on the protected circuit. Then say what
    single cost change would quietly undo it.

---

## Part B — The faults

```bash
./lab.sh break
./lab.sh verify
./lab.sh exits
./lab.sh cost
./lab.sh latency
```

Eight faults. **All eight leave every BGP session Established**, so nothing
pages. Four leave every destination reachable too, and show up only as
latency, circuit utilisation, inbound path or risk. Three do break
reachability for part of the address space, but only because the transits in
this lab blackhole third-party prefixes — in production those three would be
silent and expensive, which is worse. Two of the eight interact, and one
masks the other.

Rules of engagement:

- Work from `exits`, `cost` and `latency`, not from `verify`. `verify` is a
  scoreboard, not a diagnosis.
- Compare `sea1` against `sea2` for everything. The two sites are deliberately
  symmetric in policy, so any asymmetry is a finding.
- Separate *what a neighbour sent us* from *what our policy kept*:
  `show ip bgp neighbors X received-routes` against `... routes`. Several
  faults live in the gap between those two commands.
- One fault is in the outbound direction. Nothing about the routes we *use*
  changes, so it is invisible in `exits`, in `cost` and in the routing table.
  You find it only in what we advertise.
- `./lab.sh hint [n]` exists. `./lab.sh reveal` lists which faults are active.

For each fault write down: the symptom as the tooling showed it, the device,
the command that proves it, the fix, the monthly cost if any, and **what
would have alerted on it in production — and if nothing would have, what you
would build.**

### B1. Fix them

Work through all eight. You are done when `verify` is clean, `exits` matches
Part A, and `cost` reports no avoidable transit.

### B2. Then answer these

18. Rank the eight by how long each would survive in production before
    anybody noticed. Which one survives longest and what makes it invisible?
19. Total the avoidable transit from `cost`. Then say which single fault you
    would fix first if you could only fix one, state whether you chose on
    cost or on risk, and defend the criterion. Note that the most expensive
    fault and the most dangerous one are not the same fault.
20. One fault is dangerous to other networks rather than to us, and would get
    us a phone call from the exchange. Which one, which command on our own
    router shows it, and which command on a peer shows what they now believe
    about us?
21. Two faults produce the same symptom on the same router. Name them, name
    the one command that separates them, and say which one you must fix first.
22. One fault means we accept a more-specific of somebody else's space from a
    peer who has no business announcing it. What is that called when it is
    deliberate, what fraction of the affected traffic does it capture here,
    and why does longest-prefix match make the local-pref hierarchy
    irrelevant?

---

## Part C — Design, economics and the physical layer

No configuration. These are the questions the job interview and the quarterly
review both ask.

### C1. Diversity you can prove

23. Write the diversity clause you would put in a circuit order so that
    `TRANSIT-1A`/`1B` could not have happened. Name the artefact you require
    from the carrier, how often you re-validate, and what the remedy is when
    they are wrong.
24. Two circuits are diverse today. Name three ways they stop being diverse
    without anyone touching your network, and say how you would detect each.
25. You have a KMZ for each of two long-haul routes. Describe the analysis,
    and name the five places where physical diversity most often fails.

### C2. DWDM and the physical layer

26. You hold a 20-year IRU on a dark fibre pair, Seattle to Portland, roughly
    280 km. You want 400G. Work the problem: how many spans, what amplifier
    sites, which modulation, and what is your OSNR concern? Say whether a
    400ZR pluggable alone is enough and why.
27. Explain alien wavelengths: what you gain, what the line-system owner will
    and will not warrant, and what you must be able to prove yourself.
28. 96 channels at 50 GHz against flexgrid at 75 GHz carriers. For a 400G and
    an 800G service, which gives you more usable capacity on the same fibre,
    and what is the trade?
29. Your carrier says a wave is "protected". Name the three things you must
    ask before you believe that it adds any diversity at all.

### C3. Subsea

30. Capacity to Tokyo. One supplier offers two fibre pairs on one cable;
    another offers one pair each on two cables landing at the same CLS; a
    third offers one pair each on two cables at different CLSs. Rank them and
    justify the ranking in terms of what actually fails.
31. The transpacific cable in this lab is 9,100 km. Derive the one-way and
    round-trip latency from first principles, state the propagation constant
    you used, and account for the difference against the 95 ms in the
    inventory.
32. Your subsea path is cut. Give the realistic restoration timeline and the
    three things that drive it. Then say what your network should have done
    automatically in the first second, and what a human has to decide in the
    first hour.

### C4. Peering economics

33. An IX port is $1,200/mo. Transit is $0.38/Mbps. At what monthly traffic
    volume does the port pay for itself, assuming you can peer away 40% of
    your traffic at that exchange? Then list three costs you just ignored.
34. A large network will not peer with you: your ratio is 4:1 against their
    2:1 requirement. Give three strategies, with the trade-off of each.
35. Route server against bilateral. Give the case for each, and say what you
    lose by being on the route server only.
36. Draw the break-even between transit, an IX port and a PNI as traffic to
    one destination network grows from 100 Mbps to 10 Gbps. State the crossover
    points and what you would actually do at each stage.

### C5. Cloud interconnect

37. Your two cloud circuits land on one provider edge device. List what you
    can do about it, in order of cost, and say where you would stop.
38. Explain, in terms of the local-pref table in this lab, why advertising a
    default route or your transit routes to a cloud provider is a serious
    mistake, and what it would do to them and to you.
39. Private peering MTU is 1500 while our backbone is 9100. What breaks, where
    does it break, and what is the fix at each layer?

### C6. What this lab cannot show you

40. Name three failure modes in this problem domain that this lab is
    structurally incapable of reproducing, and say what each one would need.
    Be specific about why containers cannot do it.
