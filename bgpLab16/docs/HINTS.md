# Lab 16 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

The audit will find everything. That is not the hard part and it is not the
point. **For every finding, the question is which side is wrong**, and the
audit's output is identical whether the router drifted or the model did.

Three things decide it, in this order:

1. **Does the physical world agree?** A model that describes an interface with
   no cable behind it is a wish, not a drift. `./lab.sh status` and the
   topology file are ground truth about what exists.
2. **Is the device's value defensible?** Not "does it work" — most drift works
   — but could somebody have had a reason, and is that reason better than the
   rule?
3. **What changed most recently?** This lab gives you no history, which is
   itself the lesson. Part C question 22 is about fixing that.

Two of the eight are model drifts. One of them is dangerous specifically
because remediating looks correct.

## Per drift

### drift 1
A loopback that is not what the rule computes. It works, every session is up,
and nothing is unreachable. Ask what you lose by keeping it rather than what
breaks.

### drift 2
An IGP cost. Check the same link from the other end before you conclude
anything — only one direction moved.

### drift 3
A reflector relationship that is no longer a reflector relationship. The
session is up and the client still has routes, which is what makes it quiet.
Ask what the client stopped receiving rather than whether it is connected.

### drift 4
A neighbour the model does not describe, administratively shut, with a
description that tells you somebody meant to come back for it. Nothing is
broken. Decide its disposition anyway.

### drift 5
A point-to-point address that does not match the link-id rule. Work out
whether the far end agrees, and what that tells you.

### drift 6
A number in a route-map that is not one of the two values `model/policy.yml`
permits. Compare it against the other border that holds the same relationship.

### drift 7
Several findings, all the same kind, all on the same link, both ends. Ask
yourself what single edit produces findings on two devices at once — and then
ask whether a router can even do that.

### drift 8
The model describes a relationship that the network does not have. Before you
build it, check whether the cable exists. `./lab.sh status` and
`bgp-lab16.clab.yml` answer that, and the answer decides everything.
