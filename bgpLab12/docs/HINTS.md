# Lab 12 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

Almost nothing in this lab is unreachable. Seven of the eight faults leave
every endpoint pingable. If your instinct is to ping things, you will conclude
the fabric is healthy.

The number that matters is **installed next hops**, and `./lab.sh width` prints
it for every source against every destination. Run it, keep it, and compare
rows against their twins. rail1 against rail2. spine1 against spine2. gpu1
against gpu2 against gpu3.

Two pairs of faults mask each other. In one pair, a route is removed entirely,
which makes a filter on that same route invisible because there is nothing left
for it to filter. In the other pair, two different faults produce the identical
number, and fixing either one on its own changes nothing at all.

One fault is a direction. The row looks right and the column does not.

## Per fault

### fault 1
One row of the matrix is narrower than its neighbours, all the way across. The
device is not missing routes; it is declining to install them.

### fault 2
A column is narrow at one tier and correct at the tier below it. Ask which
device is the last one that still has both paths.

### fault 3
As fault 2, one tier up, and affecting every compute endpoint rather than one.

### fault 4
Nothing in the matrix is wrong. Nothing is unreachable. Ask what you have not
tested rather than what has failed.

### fault 5
A session count, not a width. Compare the device against its two siblings.

### fault 6
One leaf declines to use both of its uplinks. Its twin does not.

### fault 7
Compare the gpu3 row against the gpu3 column. They disagree, and that is the
whole finding.

### fault 8
Forward is fine. The matrix row for the device that answers is not. Another
fault produces the same number on the same device, so the count of paths BGP
has, versus the count it installed, is the only thing that separates them.
