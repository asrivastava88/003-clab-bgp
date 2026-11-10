#!/usr/bin/env python3
"""bgp-lab14 backbone model.

One idea runs through the whole lab: **MED is milliseconds of somebody's
backbone**. Every MED in these configs is the one-way-equivalent RTT cost from
the handoff where it is announced to the PoP that owns the prefix, so when you
read `show ip bgp` you are reading how far somebody is asking you to carry
their traffic.

  topology.py dist                 our backbone distance matrix
  topology.py med                  the MED plan we send to every external peer
  topology.py gttmed               the MED plan the transit sends us
  topology.py latency              per-interface netem delay, for lab.sh
  topology.py potato --map K=V,..  classify observed exits as hot or cold potato
"""
import sys, itertools, argparse

# Our four PoPs, on a ring. Costs are RTT in ms and are used for three things
# at once: the netem delay, the OSPF cost, and the MED. One number, so the
# arithmetic in every tool is traceable back to the fibre.
POPS = ["sea", "ash", "lhr", "sin"]
POP_NAME = {"sea": "Seattle", "ash": "Ashburn", "lhr": "London", "sin": "Singapore"}
SPANS = {("sea", "ash"): 65, ("ash", "lhr"): 75, ("lhr", "sin"): 160, ("sin", "sea"): 175}

# The transit mirrors our geography: gtt-w fronts Seattle and Singapore,
# gtt-e fronts Ashburn and London, with one internal link between them.
GTT_NODE = {"sea": "gttw", "sin": "gttw", "ash": "gtte", "lhr": "gtte"}
GTT_INTERNAL = 70

OUR_AS = 65010
# prefix -> (home PoP, label). The anycast prefix has no single home.
PREFIXES = {
    "192.0.2.0/24":    (None,  "anycast service, all four PoPs"),
    "198.51.100.0/24": ("sea", "Americas unicast"),
    "203.0.113.0/24":  ("lhr", "EMEA unicast"),
    "198.18.0.0/24":   ("sin", "APAC unicast"),
    "198.18.1.0/24":   ("sin", "APAC regional only, no-export"),
}
# Where the transit's customers sit. Their MED to us is their own IGP distance
# from each handoff city to the customer's city.
GTT_CUSTOMERS = {
    "100.150.0.0/16": ("sin", "APAC eyeballs"),
    "100.151.0.0/16": ("sea", "Americas west eyeballs"),
    "100.152.0.0/16": ("ash", "Americas east eyeballs"),
    "100.153.0.0/16": ("lhr", "Europe eyeballs"),
    "100.200.0.0/16": (None,  "transit-only destination, everywhere"),
}
CDN_PREFIX = "100.120.0.0/16"      # PNI at lhr and sin
PEEREU_PREFIX = "100.140.0.0/16"   # peer at lhr only, also a gtt customer

LP = {"pni": 200, "peer": 200, "transit": 100}


def dist():
    """All-pairs shortest path over the ring, by RTT ms."""
    d = {p: {q: (0 if p == q else 10**9) for q in POPS} for p in POPS}
    for (a, b), c in SPANS.items():
        d[a][b] = d[b][a] = c
    for k, i, j in itertools.product(POPS, POPS, POPS):
        if d[i][k] + d[k][j] < d[i][j]:
            d[i][j] = d[i][k] + d[k][j]
    return d


def next_hop_pop(src, dst, D):
    """Which neighbouring PoP src uses to reach dst."""
    if src == dst:
        return None
    for (a, b), c in list(SPANS.items()) + [((b, a), c) for (a, b), c in SPANS.items()]:
        if a == src and c + D[b][dst] == D[src][dst]:
            return b
    return None


def our_med(pop, prefix, D):
    """MED we announce for `prefix` at `pop`: how far we would have to carry it."""
    home = PREFIXES[prefix][0]
    return 0 if home is None else D[pop][home]


def gtt_med(pop, prefix, D):
    """MED the transit announces to us at `pop`, from its own geography."""
    home = GTT_CUSTOMERS[prefix][0]
    if home is None:
        return 0
    return D[pop][home]        # their backbone mirrors ours


def cmd_dist(_a):
    D = dist()
    print("Our backbone, RTT ms. Also the OSPF cost, also the MED.\n")
    print("        " + "".join(f"{q:>8}" for q in POPS))
    for p in POPS:
        print(f"{p:>6}  " + "".join(f"{D[p][q]:>8}" for q in POPS))
    print("\nRing spans:")
    for (a, b), c in SPANS.items():
        print(f"  {a}-{b}  {c}ms")
    print("\nShortest paths that are not the direct span:")
    for p, q in itertools.combinations(POPS, 2):
        via = next_hop_pop(p, q, D)
        if via and via != q:
            print(f"  {p} -> {q}  {D[p][q]}ms via {via}")
    return 0


def cmd_med(_a):
    D = dist()
    print("MED we announce to every external peer, per PoP.")
    print("Read it as: how many ms of OUR backbone we are willing to carry.\n")
    print(f"  {'prefix':<20} {'home':<6} " + "".join(f"{p:>7}" for p in POPS))
    for pfx, (home, label) in PREFIXES.items():
        row = "".join(f"{our_med(p, pfx, D):>7}" for p in POPS)
        print(f"  {pfx:<20} {str(home or '-'):<6} {row}   {label}")
    print("\n  The anycast prefix is 0 from everywhere on purpose. Equal MED means")
    print("  the upstream hot-potatoes it, which for anycast is the correct answer:")
    print("  every source enters at the handoff nearest the source.")
    return 0


def cmd_gttmed(_a):
    D = dist()
    print("MED the transit announces to US, per handoff.")
    print("Read it as: how many ms of THEIR backbone they want us to save them.\n")
    print(f"  {'prefix':<20} {'at':<6} " + "".join(f"{p:>7}" for p in POPS))
    for pfx, (home, label) in GTT_CUSTOMERS.items():
        row = "".join(f"{gtt_med(p, pfx, D):>7}" for p in POPS)
        print(f"  {pfx:<20} {str(home or '-'):<6} {row}   {label}")
    print("\n  Accepting these MEDs is a decision, not a default. It makes us carry")
    print("  their traffic across our backbone to the exit nearest the destination")
    print("  (cold potato). Stripping them makes us dump it at the nearest exit")
    print("  (hot potato) and makes it their problem. ./lab.sh potato shows which.")
    return 0


def cmd_latency(_a):
    """netem delay per interface. Half the RTT on each end."""
    IF = {  # (pop or node, peer) -> container interface
        ("sea", "ash"): "eth2", ("ash", "sea"): "eth2",
        ("ash", "lhr"): "eth3", ("lhr", "ash"): "eth2",
        ("lhr", "sin"): "eth3", ("sin", "lhr"): "eth2",
        ("sin", "sea"): "eth3", ("sea", "sin"): "eth3",
    }
    for (a, b), rtt in SPANS.items():
        half = rtt / 2.0
        s = f"{half:g}ms"
        print(f"{a} {IF[(a,b)]} {s} {a}-{b}")
        print(f"{b} {IF[(b,a)]} {s} {a}-{b}")
    # the transit's internal span, so their hot-potato behaviour is real
    print(f"gttw eth3 {GTT_INTERNAL/2:g}ms gttw-gtte")
    print(f"gtte eth3 {GTT_INTERNAL/2:g}ms gttw-gtte")
    return 0


def cmd_potato(a):
    """Classify observed exits. --map pop:prefix=exitpop,... from lab.sh."""
    D = dist()
    obs = {}
    for kv in (a.map or "").split(","):
        if "=" in kv:
            k, v = kv.split("=", 1)
            obs[k.strip()] = v.strip()
    print("Exit selection, and whose backbone pays for it.\n")
    print(f"  {'from':<6} {'destination':<20} {'exit':<8} {'our ms':>7}  classification")
    print("  " + "-" * 72)
    tot = 0
    for key in sorted(obs):
        pop, pfx = key.split(":", 1)
        exit_pop = obs[key]
        if exit_pop in ("none", "unknown"):
            print(f"  {pop:<6} {pfx:<20} {exit_pop:<8} {'-':>7}  no route")
            continue
        ms = D[pop][exit_pop] if exit_pop in POPS else 0
        tot += ms
        if exit_pop == pop:
            kind = "hot potato, nearest exit"
        elif ms == 0:
            kind = "local exit"
        else:
            kind = f"cold potato, carried {ms}ms to {POP_NAME.get(exit_pop, exit_pop)}"
        print(f"  {pop:<6} {pfx:<20} {exit_pop:<8} {ms:>7}  {kind}")
    print("  " + "-" * 72)
    print(f"  {'total backbone ms we carry across these flows':<43} {tot:>7}")
    print("\n  Cold potato buys control and latency for the destination and costs")
    print("  you backbone. Hot potato is the reverse. Neither is right; the")
    print("  question is whether each line above is the trade you meant to make.")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for n in ("dist", "med", "gttmed", "latency"):
        sub.add_parser(n)
    pp = sub.add_parser("potato"); pp.add_argument("--map", default="")
    a = p.parse_args()
    return {"dist": cmd_dist, "med": cmd_med, "gttmed": cmd_gttmed,
            "latency": cmd_latency, "potato": cmd_potato}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
