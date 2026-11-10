# Lab 13 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

Every BGP session stays Established through all eight faults. Nothing pages.
If your instinct is to run `show ip bgp summary` and conclude the network is
healthy, you will find nothing.

Four tools, in this order:

1. `./lab.sh exits` against your Part A copy. It shows the intended exit next
   to the observed one, per site.
2. `./lab.sh cost`. Two faults are visible only here.
3. `./lab.sh latency`. One fault is visible only here.
4. `show ip bgp neighbors X received-routes` against `show ip bgp neighbors X
   routes`. Three faults live in the gap between those two commands.

Two structural habits worth more than any hint below:

- **Compare sea1 against sea2.** The two sites run identical policy by design.
  Any asymmetry is a finding, and three faults are asymmetric.
- **Separate what arrived from what we kept, and what we sent from what we
  meant to send.** Inbound policy, outbound policy and best-path selection
  fail in three different places and look alike from the routing table.

One fault changes nothing you can see from our own routers' routing tables at
all. Two faults produce the same next hop on the same router.

## Per fault

### fault 1
A destination that should leave on a private circuit is leaving at the
exchange instead, and only half of that destination's space does it. Ask what
the route server sent us, not what we have.

### fault 2
Nothing we use is wrong. Look at what we say, not what we hear.

### fault 3
One circuit of a redundant pair is carrying the traffic for both sites, and
the other is carrying nothing. The site with the idle circuit is the one to
look at, but the fault is on the other one.

### fault 4
Both sites agree, which is why it does not look like an asymmetry. Compare
what a peer's route costs us against what the same prefix costs from a peer
one tier away.

### fault 5
A session that is up, and has sent us nothing. Count what arrived.

### fault 6
Not visible in `exits` or `cost`. Two of our three internal paths are supposed
to be unattractive, and one of them stopped being.

### fault 7
Our own routers are all correct. The device that reveals this is not ours, and
what it has too many of is next hops.

### fault 8
Loud, if you look at the right protocol. It is not BGP. It also hides another
fault, so fix this one before you trust what you see about internal paths.
