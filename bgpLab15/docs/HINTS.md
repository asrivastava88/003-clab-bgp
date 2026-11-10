# Lab 15 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

**No fault breaks IPv4.** Every check you would normally run — session
summary, a few routes, a ping — passes, because in IPv4 the network is
correct. Checking IPv4 tells you nothing at all.

Three habits, in order:

1. **`./lab.sh afi`.** Every IPv4 column should equal its IPv6 column except
   where a relationship is single-family. Six of the eight faults show up as a
   pair of numbers that disagree.
2. **For every IPv6 observation, run the IPv4 equivalent as the control.** You
   are not looking for "is this right", you are looking for "is this the same".
   The IPv4 side is your known-good reference and it is sitting right there.
3. **`./lab.sh parity`** when you have exhausted state. It is a config audit,
   so it names divergence that has not caused a symptom yet — including one
   fault that has no symptom at all on a healthy network.

Two structural notes:

- Two faults compound. One of them makes an IPv6 route unusable at `edge1`,
  which makes every other observation about `edge1`'s IPv6 path selection
  meaningless. Fix that one first.
- One fault only matters during a maintenance. If you never drain, you never
  see it.

## Per fault

### fault 1
A relationship that is up in one family and not the other. The session is
configured. Ask what a session needs besides being configured.

### fault 2
Both families reach the same destination and only one of them uses the free
path. Compare the two inbound policies for that relationship, value by value.

### fault 3
Our customer. Count what we advertise to each upstream, in each family, and
compare against the other border.

### fault 4
Our own routers are all correct. Something a transit believes about us is true
in one family and not the other, and what it believes concerns the length of
a path.

### fault 5
Nothing is broken. A relationship exists on one border and not on the other,
and because it has no IPv4 half, nothing in an IPv4-shaped audit would ever
have looked for it.

### fault 6
A transit is announcing a piece of our own space on purpose. In one family we
drop it and in the other we install it. Two separate things reject it in IPv4
and you need to work out which of the two is missing.

### fault 7
No symptom. Not in `afi`, not in `exits`, not in `verify`. It appears the
moment you drain a border, and the audit names it without draining anything.

### fault 8
One family has the path in BGP and nothing in the routing table. Compare the
two iBGP sessions attribute by attribute.
