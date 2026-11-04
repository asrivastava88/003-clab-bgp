# Lab 10 Hints

Spoilers, one step short of the answer. `docs/SOLUTIONS.md` has the rest.

## Where to look at all

Every external neighbour in this lab misbehaves by design. That is the input,
not a fault. A fault is something on **your** edge that stopped catching it.

The defences are layered, and each layer exists because the one below it has a
blind spot:

1. something that applies to every external session regardless of who they are
2. something that applies only where you can enumerate what the neighbour owns
3. something that stops your own mistakes becoming someone else's problem
4. a backstop for everything the first three missed

Work out which layer a symptom belongs to before reading config. A prefix that
got in from a neighbour you cannot enumerate is a different layer from the same
prefix getting in from one you can.

Two directions. Half the faults are about what you accepted and half about what
you handed out, and the second half is not visible from your own tables at all.

## Per fault

### fault 1
A prefix got in that nobody outside your AS has any business originating. The
filter that should have caught it is not about who sent it.

### fault 2
A customer is announcing more than it did yesterday and all of it was accepted.
Nothing bad got in, which is the problem: the control that defines "more than
they should" stopped defining anything.

### fault 3
Junk from an upstream. You cannot enumerate what an upstream owns, so the only
thing that could have stopped this is the layer that applies everywhere.

### fault 4
Same shape as fault 3, different neighbour class. If you fixed one and not the
other, you fixed a symptom.

### fault 5
A prefix arrived that your edge should have rejected without looking at any
policy at all, because of something BGP does by default. Something switched that
default off for one neighbour. Read the AS path.

### fault 6
Nothing is wrong in your tables. Look at somebody else's.

### fault 7
Same as fault 6, different neighbour. The two are configured separately and
break separately.

### fault 8
A neighbour is holding far more than you agreed to give them. Still not visible
from your side.
