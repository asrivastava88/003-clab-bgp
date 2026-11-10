# Lab 14 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

Every session is Established. Every OSPF adjacency is full. Every circuit is
healthy. `show ip bgp summary` and `show ip ospf neighbor` will tell you the
network is perfect, and on both counts they are right.

The method is diffing four tool outputs against your Part A copies:

1. `./lab.sh potato` — outbound. Which exit, and how much of our backbone.
2. `./lab.sh inbound` — where the outside world enters. Two faults live only
   here, and one of them is only visible on a device we do not operate.
3. `./lab.sh anycast` — one fault lives only here.
4. `./lab.sh latency` — one fault lives only here.

Then two habits:

- **The four PoPs run generated, symmetric policy.** Any difference between
  them is a finding, and five of the eight faults are a single PoP disagreeing
  with its three siblings.
- **When an exit is wrong, walk best-path order attribute by attribute.**
  Local-pref, then AS-path length, then MED, then eBGP over iBGP, then IGP
  metric. Three faults are one wrong number, and from the routing table alone
  all three look the same.

One fault is an OSPF cost. OSPF cost is per interface and therefore per
direction, so check the return path before you conclude anything.

## Per fault

### fault 1
Our own tables are fine. A transit router is entering our network on the wrong
continent for one prefix, and the number that told it to is one we announce.

### fault 2
A free interconnect at two PoPs stopped being used by anyone. The PoP that
caused it is not either of those two, and the attribute involved is compared
before everything else.

### fault 3
Nothing moved. Something that was absent is now present, on the device
furthest from us.

### fault 4
Not in `potato`, not in `inbound`. One number, and the path it changed is
asymmetric — the way back is unaffected, which is what makes it confusing.

### fault 5
One PoP stopped using the interconnect in its own building and reaches it the
long way round instead. Another fault hides this one, so expect it to appear
only after you have fixed that one.

### fault 6
Every reachability check passes. One region receives no anycast traffic at
all. Only one tool shows it, and what it shows you is a count.

### fault 7
One PoP stopped using the exit in its own building for the one destination
class that is supposed to be handled locally. Compare its inbound policy
against the other three.

### fault 8
Nothing is wrong today. We have fewer ways in than we think, and the only
evidence is a number on a device we do not operate.
