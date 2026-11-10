# Lab 11 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

Three of the eight faults produce **no symptom at all** in the steady state.
They are only visible if you either compare devices against each other or
deliberately fail something that is currently carrying no traffic. If your
method is "run verify, fix what is red, repeat", you will stop at five.

Two more faults **mask each other**. Fixing one will appear to make things
worse, because it exposes the second.

One fault is invisible to every ping you would normally run, and visible
immediately to a ping you probably would not.

The method that works: collect the same five pieces of state from every
device into a table before changing anything. Control plane session counts.
VNI mappings. Installed next hops. Route-table entries for a prefix you care
about. What the far side of each external session is actually holding. The
outliers are the faults.

## Per fault

### fault 1
Everything reachable is reachable. Nothing that works stops working. Ask what
you have never tested, rather than what has failed.

### fault 2
The control plane for this is flawless. Every route is present, every
attribute correct, every session up. Compare what a device has learned
against what it is able to do with it.

### fault 3
Nothing is wrong today. Make something be wrong, in a way you control, and
watch what does not take over.

### fault 4
A host cannot reach things it should, and can reach things it should not.
Those are the same fault, not two.

### fault 5
One tenant lost the outside world and the other did not. The thing that
differs between them is four characters long.

### fault 6
Count something on one device and the same thing on its twin.

### fault 7
As fault 6. Different device, different thing to count, same method.

### fault 8
Two hosts in the same VRF, one works and one does not, and the one that does
not is behind a device whose BGP table is completely correct. Something is
winning that is not BGP.
