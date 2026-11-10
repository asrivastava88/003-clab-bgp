# Lab 19 Tasks — Multi-Tenant EVPN Across Three Regions

Twelve faults across 38 nodes and three tenant VRFs. One of them is a tenancy
breach. Find that one first.

---

## Part A — The design

```bash
./lab.sh deploy ; ./lab.sh verify
./lab.sh isolation ; ./lab.sh vrf ; ./lab.sh vtep ; ./lab.sh wan
./lab.sh rt wst-p1-l1
```

Save all four tool outputs.

1. Write out the route-target plan from memory, then check it with
   `./lab.sh rt`. For each VRF say how many imports it has and why.
2. PROD and DEV both import SHARED, and SHARED imports both. Explain why
   SHARED's imports do not create a path between PROD and DEV, naming the
   mechanism precisely.
3. The invariant is enforced on eighteen devices independently. Name three
   different single-device changes that would break it, and say which of them
   `./lab.sh isolation` would catch.
4. A spine in this fabric runs no BGP at all. State what that buys, and name
   one thing it costs.
5. The overlay is iBGP with the super-spines as reflectors, and the underlay is
   OSPF. Labs 17 and 18 used eBGP for both. Give the trade-off in both
   directions, and say which you would build for a new fabric.
6. Each tenant crosses the WAN as its own eBGP session on its own
   sub-interface. Name three things that become possible because of that which
   would not be possible if EVPN were stretched across the WAN.
7. `redistribute connected` in each VRF carries a route-map. Work out what
   would end up in a tenant's routing table without it, and why that is worse
   than untidy.
8. From `vtep`: every VTEP sees five others. Account for the number, and say
   what a VTEP seeing four would most likely mean.

---

## Part B — The twelve faults

```bash
./lab.sh break
# wait ~90s
./lab.sh verify ; ./lab.sh isolation ; ./lab.sh vrf ; ./lab.sh vtep ; ./lab.sh wan
```

Rules of engagement:

- **Run `isolation` first, every time.** One fault is a tenancy breach and it
  outranks everything else on this list regardless of how many other things are
  broken.
- A tenant can be healthy inside a region and broken between regions, or the
  reverse. Decide which you are looking at before you start.
- Two faults have their cause in the underlay and all their symptoms in the
  overlay. The EVPN session will be Established and the routes will be present.
- Compare across regions and across pods. Eighteen VTEPs run identical
  generated policy, so any one that differs is a finding.
- `./lab.sh hint [n]` exists. `./lab.sh reveal` lists active faults.

### B1. Fix them

Done when `verify` is clean and all four tools match Part A.

### B2. Then answer these

9.  Which fault is the tenancy breach? Name the device, the exact line, what it
    lets through, and say how you would have found it if `isolation` did not
    exist.
10. One fault leaves a tenant unable to reach SHARED from one device only.
    Which VRF, which device, and why does every other device in that region
    still work?
11. Two faults show up in the same tool as a missing VTEP, and neither is a BGP
    problem. One makes a VTEP unreachable; the other makes two devices share
    one VTEP address. Name both, say which one is worse and why, and give the
    command that tells them apart.
12. One fault leaves the control plane perfect and the data plane dead for one
    tenant on one device. Name the mechanism and the command that shows the
    gap.
13. One fault makes a region a transit path for another region's tenant
    traffic — in one VRF only. Which VRF, which border, and why does it not
    affect the other two tenants?
14. One fault breaks a tenant between regions while leaving it perfect inside
    every region. Which one, and which tool shows it?
15. One fault puts WAN addresses inside a tenant's routing table — on one
    border, and from there everywhere that tenant reaches. Which one, what
    lands there, how far it spreads, and name the second-order problem it
    creates given that all three regions number their WAN links out of the same
    block.
16. For the duplicate-VTEP fault: work out which of the two devices wins, what
    happens to traffic destined for the loser, and why the EVPN control plane
    reports nothing wrong. Then say what in a generated-config workflow makes
    this fault impossible.
17. One fault removes an export, not an import. Explain why that is harder to
    find than a missing import, and who notices first.
18. Rank all twelve by how long each would survive in production. Which
    survives longest, and which would you escalate first? They are not the same
    fault, and say why that is the right answer anyway.
19. Of the twelve, how many would a config audit of the kind Lab 16 builds have
    caught before deployment? Name what it asserts for the tenancy breach
    specifically.

---

## Part C — Tenancy at scale

20. Write the control that makes the isolation invariant impossible to break by
    hand. Cover: where the route-targets come from, what generates the config,
    what tests it, and what runs continuously.
21. A fourth tenant arrives and must reach SHARED but not PROD or DEV. Give the
    route-target plan. Then give it again for the case where the new tenant
    must reach PROD but not DEV, and say which of the two is a design smell.
22. The hub-and-spoke RT plan does not scale: with N tenants all needing
    SHARED, SHARED imports N route-targets. At what N does that become a
    problem, what breaks first, and what is the alternative?
23. Two tenants need to use the same address space. Describe everything that
    changes, including what stops working in this lab's tooling.
24. Argue for and against doing tenant isolation in the fabric at all, against
    doing it in software on the host. Cover blast radius, change velocity,
    auditability and who owns the control.
25. You are asked to prove to an auditor that PROD cannot reach DEV. Describe
    the evidence you would produce, what it does and does not prove, and what
    you would say about the gap.
26. EVPN stops at the region boundary here. Make the case for stretching it
    across the WAN instead, then make the case against, then say what you would
    actually do and what would change your mind.
27. Name three multi-tenant failure modes this lab is structurally incapable of
    reproducing, and what each would need.
