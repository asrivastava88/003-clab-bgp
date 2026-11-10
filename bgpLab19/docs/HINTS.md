# Lab 19 Hints

Spoilers. `docs/SOLUTIONS.md` has the answers.

## Before you read any of this

**Run `./lab.sh isolation` first.** One of the twelve is a tenancy breach, and
it outranks everything else on the list no matter how much else is broken.
Everything in this lab is a routing problem except that one, which is a
security problem.

Then four tools, each owning a class:

- **`isolation`** — the invariant. One row red is the whole finding.
- **`vrf`** — route count per VRF per VTEP. The tenant space is symmetric by
  design, so a device that is low in **one** VRF has an import problem and a
  device low in **all** of them has an overlay problem. That distinction saves
  you an hour.
- **`vtep`** — who sees whom. A VTEP nobody sees is usually an **underlay**
  problem wearing an overlay costume: EVPN is Established, the routes are
  there, and the tunnel never forms because a loopback is unreachable.
- **`wan`** — per-VRF inter-region. A tenant can be perfect inside every region
  and broken between them, and nothing inside a region will tell you.

One structural habit: eighteen VTEPs run **identical generated policy**. Any
single device that differs from its seventeen siblings is a finding, and nine
of the twelve faults are exactly that.

## Per fault

### fault 1
One device can reach a tenant it must never reach, and traffic comes back too —
which takes two mistakes, not one. Compare that VRF's stanza line for line
against the same VRF on any other device in the fabric.

### fault 2
One tenant on one device cannot reach the shared services every other device
reaches. The opposite edit to fault 1, in the opposite direction.

### fault 3
A VTEP that nobody in its region can see. Its EVPN session is up and its routes
are fine. Ask what has to be true for a tunnel to form, beyond BGP.

### fault 4
The control plane is perfect. The routes are there, the next hop is there, the
VTEP is visible, and one tenant on one device does not pass traffic. Look at
what encapsulates it.

### fault 5
A border is announcing more than its own region's tenant space, in one VRF.
Nothing is broken until you look at what a carrier now believes.

### fault 6
A border has a BGP session down for one tenant only. The other two tenants on
that same border, over that same physical link, are fine. Nothing is
unreachable — count what is left.

### fault 7
Count the distinct VTEPs in one region. There are six devices and fewer
addresses than that. Two devices are answering to one name, so half the traffic
for one of them is being decapsulated by a box that has never heard of the
destination.

### fault 8
One VTEP is talking to one reflector instead of two. Nothing is unreachable,
which is the problem. The missing line is on the reflector, not on the VTEP.

### fault 9
One tenant's routing table on one border has addresses in it that belong to the
WAN, and so does every other device that imports that tenant. Harmless today;
ask what happens when two regions number their WAN links the same way — which,
by design here, they do.

### fault 10
A device's tenant routes have stopped reaching everybody else, and that device
can still reach everybody. Look at the direction nobody checks.

### fault 11
An OSPF adjacency is missing. One leaf has one uplink. Everything still works.

### fault 12
Every VTEP in one region is down to one reflector, and it is one line on one
device rather than six. Still nothing unreachable: the other reflector is
carrying the whole region. The loudest fault in the lab is rarely the important
one, and this is the quietest one that matters most.

### (end)
