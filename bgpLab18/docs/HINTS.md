# Lab 18 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

Thirty-eight nodes. You cannot eyeball this one, and that is deliberate.

**Bisect by tier, then by region.** A symptom at a London leaf has six possible
homes: that leaf, its spine, its super-spine, its border, a carrier, or a
border in a region you were not thinking about. Walk the path:

```
leaf -> spine -> super-spine -> border -> carrier -> border -> super-spine -> spine -> leaf
```

At each hop ask only one question: *does this device have the route, and from
whom*. The first hop where the answer changes is where the fault is or where
the evidence is.

Five tools, and each one owns a class:

- **`regions`** — anything about who carries inter-region traffic. Two faults
  live only here, and one of them is in a network you do not operate.
- **`transit`** — advertisement discipline. A border announces exactly 2.
- **`table`** — the two aggregation boundaries. A carrier that holds a /17 or
  a /24 is a leak you can see in one line.
- **`width`** — next hops per tier. Three faults are a 2 that became a 1.
- **`anycast`** — one fault lives only here.

One fault takes a session down. It will be the first thing you find and it is
one of twelve; do not let it eat the evening.

## Per fault

### fault 1
A border is announcing far more than two prefixes to the carriers. On its own
it changes no traffic anywhere, which is exactly why nobody catches these until
the day they matter.

### fault 2
Not in your network. A carrier has stopped believing one region, and the only
reason that region is still reachable through that carrier is fault 1. Fix
fault 1 on its own and something becomes unreachable — work out what, before
you do it.

### fault 3
One region reaches another through only one of its two borders. The border at
fault is the one that is not carrying anything.

### fault 4
Nothing is wrong. A pod aggregate that two spines should both originate is
being originated by one. The day the other one reboots, half a region goes
away.

### fault 5
A carrier can suddenly see pods. Only one region's, through one of its two
borders, which is where to look.

### fault 6
A destination is unreachable and three tiers above it still have a route that
covers it. Find the hop where `show ip route` says `Null0` for something that
is not that device's own.

### fault 7
Every path is there and one device installs half of them. Compare it with the
other device in its tier, in its own region.

### fault 8
`show ip bgp` is perfect and forwarding is not. Something with a better
administrative distance than BGP is in the way, on one leaf.

### fault 9
A service exists in all three regions and one region's users are crossing an
ocean to reach it. Ask what that region stopped saying.

### fault 10
Nothing inside the affected region can see this at all. Inbound traffic for a
whole region is arriving on one border instead of two, and the evidence is on
a device you do not own.

### fault 11
A leaf has one uplink where every other leaf has two. Nothing is broken.
Count sessions on the spine, not on the leaf.

### fault 12
The loud one. A session is gone. Fix it, note it, and move on — there are
eleven others and none of them will announce themselves.
