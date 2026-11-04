# Lab 06 Tasks

## Part A: Build the policy (deploy `base`)

OSPF is up, the iBGP full mesh is up with next-hop-self on the edges, and all four eBGP sessions are Established. There is no policy of any kind. We accept everything from everyone and re-announce it to everyone, which means right now we are providing free transit between transitA and transitB.

Run `./lab.sh verify` first and read the Findings block. Then run `./lab.sh leaks` and look at what we are sending transitB. That is the problem.

| # | Task | Done when |
|---|---|---|
| A1 | Ingress tagging. Tag every route by the type of neighbor it came from, and set LOCAL_PREF so customer beats peer beats transit. | `show ip bgp 10.202.0.0/16` on edge1 shows LOCAL_PREF 150; `10.200.0.0/16` shows 100. |
| A2 | Customer ingress filter. Accept only `10.5.0.0/16` from cust1. Their other two announcements are not registered to them. | `show ip bgp 10.5.100.0/24` on edge2 is empty. |
| A3 | Egress to transits and the peer. Default deny. Announce our own space and our customer's, nothing else. | `./lab.sh leaks` shows exactly two prefixes on each transit and peer session. |
| A4 | Egress to the customer. Give them a default. | cust1 has `0.0.0.0/0` and can reach 10.6.0.1. |
| A5 | Aggregation. One prefix leaves our AS, not four. | transitA receives `10.100.0.0/16` and none of the /20s. |
| A6 | Prefix limits. Size each session for what the neighbor should reasonably send. | Configured, with headroom. Say out loud what number you chose for the customer and why. |
| A7 | End to end. | `./lab.sh verify` all PASS, including every leak check. |

Questions before Part B:

1. Why does the egress policy match on a community rather than on the session the route arrived from? Give the concrete scenario where the session-based version breaks.
2. `aggregate-address 10.100.0.0/16 summary-only` suppresses the component /20s toward **every** neighbor, iBGP included. Why does our fabric still work, and what would break if `core` had not originated them itself?
3. Our customer pays us. A peer is free. A transit costs money. Map those three facts onto the LOCAL_PREF values and explain why that order is about money rather than about path length.
4. A route arrives from transitA and also from peerX with the same AS_PATH length. Walk the best-path comparison and name the exact step that decides it.
5. On `core`, both edges offer a path to `10.6.0.0/16`. If you equalized LOCAL_PREF, which step would decide, and what in this lab's design makes that step deterministic rather than a coin flip?

## Part B: Best path and the attributes (deploy `solution`)

**B1 Walk the algorithm.** Run `./lab.sh bestpath 10.6.0.0/16`. Three paths exist in our AS: via transitA, via transitB, via peerX. Write down which attribute decides at each router and why the answer differs between edge1, edge2 and core.

**B2 Force each tie-breaker.** Working on `core` and `edge1`, make each of the following be the deciding step for `10.6.0.0/16`, one at a time, verifying each before moving on. Undo each change before the next.

1. WEIGHT
2. LOCAL_PREF
3. AS_PATH length
4. ORIGIN
5. MED
6. eBGP over iBGP
7. IGP metric to the next hop
8. Lowest router-id

For step 5, note which pair of paths MED can even be compared between and why. For step 7, the OSPF costs are 10 via edge1 and 30 via edge2; prove the metric is what decided and not something earlier in the list.

**B3 Multipath.** Make our AS load-share to `10.6.0.0/16` across both transits. The AS_PATHs are the same length but different content, which matters. Find the knob, confirm it on your build with `?`, and verify with `show ip route 10.6.0.0/16`. Then say why you would or would not run this toward two different upstreams in production.

**B4 AS_PATH filtering.** Our customer filter is prefix-based today. A real provider also wants "nothing whose AS_PATH contains a transit ASN," so a customer cannot leak us the internet. Build it. `match as-path <list-name>` and `match as-path length <op> <n>` both exist on EOS; find the command that creates the list with `ip as-path ?` and write it down. Then test it by having cust1 announce `10.6.0.0/16` and confirming we reject it.

**B5 Conditional advertisement.** We want `10.100.32.0/20` announced to transitB **only while** our transitA path is down, as a traffic-engineering backstop. Arista supports conditional advertisement; find the syntax on your build, implement it, and test it by shutting edge1's `Ethernet3`. If you cannot find it, say what you would use instead and what that alternative costs.

**B6 Graceful shutdown.** edge1 needs maintenance. Drain it without dropping a session: set LOCAL_PREF 0 and attach the well-known GRACEFUL_SHUTDOWN community on egress. EOS has a named flag for that community in `set community`. Verify that core moves to edge2 and that no session ever leaves Established. Explain what the community asks the far side to do and why you set LOCAL_PREF as well rather than relying on it.

## Part C: Troubleshooting (deploy `solution`)

```bash
./lab.sh verify          # baseline all PASS
./lab.sh break random    # or a number 1-8
```

Symptoms in `docs/TICKETS.md`. `./lab.sh leaks` is the fastest first move for anything that smells like a policy problem, and `./lab.sh bestpath <prefix>` for anything about path choice.

Four of these eight produce no reachability failure at all. Some cost money, one gives away free transit, and one is a hijack we propagate. Working out *whether* there is an outage is part of each ticket.

## Part D: Design review (no config)

1. A customer calls and asks you to announce a /24 out of a /16 that someone else holds. Describe what you verify before accepting it, and what you do if you cannot verify it.
2. You have two upstreams and want inbound traffic balanced. Rank the tools available to influence inbound, from most to least reliable, and say why the ranking is that way.
3. `remove-private-as` is pointless in this lab because every ASN here is private. Describe the real situation where it is necessary, and the failure it prevents.
4. Your eBGP sessions have no authentication and no TTL security. Explain what each protects against, confirm the GTSM command on your build, and say which you would deploy first and why.
5. Your aggregate is a /16 and a customer inside it wants their /24 announced only to transitA. Describe how you would do it without losing the aggregate, and what goes wrong if you simply stop suppressing that /24.
6. A leak like ticket 2 made it to production and you were free transit for ninety minutes. Write the three controls you would add: one preventive, one detective, one that limits blast radius.
