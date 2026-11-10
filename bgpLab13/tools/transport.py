#!/usr/bin/env python3
"""bgp-lab13 transport analysis.

BGP cannot answer any of the questions in this file. Diversity, fate sharing,
cable landings and money are properties of the physical and commercial plant,
and the only record of them is the inventory. This is the tool that reads it.

  transport.py srlg                 fate-sharing analysis of intended-diverse pairs
  transport.py cut <SRLG>           what a cut of one shared-risk group does
  transport.py cut <SRLG> --json    machine readable, for lab.sh to act on
  transport.py routes               circuit inventory by physical route
  transport.py latency              expected RTT per circuit, for netem
  transport.py cost --map K=V,...   price the current exit distribution
  transport.py srlgs                list every shared-risk group
"""
import sys, os, json, argparse
try:
    import yaml
except ImportError:
    sys.exit("pyyaml required: pip3 install --break-system-packages pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))
INV = os.path.join(HERE, "..", "inventory", "circuits.yml")

# Pairs the business believes are diverse, and why it believes it. This is the
# list an auditor would build from purchase orders and carrier KMZ files.
DIVERSE_PAIRS = [
    ("TRANSIT-1A", "TRANSIT-1B",
     "dual-homed to PACRIM at two sites, sold to us as diverse access"),
    ("WAVE-SEA-ASH-A", "WAVE-SEA-ASH-B",
     "two carriers, northern I-90 route against southern I-80 route"),
    ("IX-PORT-A", "IX-PORT-B",
     "two IX ports in two meet-me rooms"),
    ("CLOUD-IC-A", "CLOUD-IC-B",
     "cloud interconnect redundant pair, ordered on diverse paths"),
    ("PNI-CDN-A", "PNI-CDN-B",
     "two PNIs to the same CDN from two of our sites"),
    ("DF-SEA-001", "WAVE-SEA-ASH-A",
     "metro fibre and long-haul wave, different carriers, different services"),
    ("TRANSIT-1A", "TRANSIT-2",
     "two transit providers, one local and one transpacific"),
]

C = dict(r="\033[31m", y="\033[33m", g="\033[32m", c="\033[36m", b="\033[1m", n="\033[0m")
def col(k, s): return f"{C[k]}{s}{C['n']}"

def load():
    with open(INV) as f:
        d = yaml.safe_load(f)
    d["by_id"] = {c["id"]: c for c in d["circuits"]}
    return d

def ends(c):
    return f"{c['a_end']['node']}:{c['a_end']['port']} <-> {c['z_end']['node']}:{c['z_end']['port']}"

# ----------------------------------------------------------------- srlg
def cmd_srlg(d, _a):
    print(col("b", "Fate-sharing analysis"))
    print("Each pair below is believed to be diverse. Shared SRLG entries mean")
    print("it is not, and a single physical event takes both circuits.\n")
    bad = 0
    for a_id, z_id, why in DIVERSE_PAIRS:
        a, z = d["by_id"].get(a_id), d["by_id"].get(z_id)
        if not a or not z:
            continue
        shared = sorted(set(a["srlg"]) & set(z["srlg"]))
        hdr = f"{a_id}  +  {z_id}"
        if shared:
            bad += 1
            print(col("r", f"  SHARED FATE   {hdr}"))
        else:
            print(col("g", f"  diverse       {hdr}"))
        print(f"                believed: {why}")
        if shared:
            for s in shared:
                print(col("y", f"                shares:   {s}"))
            prot = [x["id"] for x in (a, z) if x.get("protection") == "1+1"]
            if prot:
                print(f"                note:     {', '.join(prot)} is 1+1 protected, so a cut")
                print(f"                          of a shared group may still be survivable")
            mrc = (a.get("mrc_usd", 0) or 0) + (z.get("mrc_usd", 0) or 0)
            if mrc:
                print(f"                spend:    ${mrc:,}/mo on a pair that is not diverse")
        print()
    print(col("b", f"{bad} of {len(DIVERSE_PAIRS)} intended-diverse pairs share fate."))
    print("A pair that shares fate is a single point of failure you are paying twice for.")
    return 0

def cmd_srlgs(d, _a):
    groups = {}
    for c in d["circuits"]:
        for s in c["srlg"]:
            groups.setdefault(s, []).append(c["id"])
    print(col("b", "Shared-risk groups, widest blast radius first\n"))
    for s, ids in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        n = len(ids)
        tag = col("r", f"{n:2d} circuits") if n >= 4 else \
              col("y", f"{n:2d} circuits") if n >= 2 else col("g", f"{n:2d} circuit ")
        print(f"  {s:22s} {tag}  {', '.join(sorted(ids))}")
    print(f"\n  {len(groups)} groups across {len(d['circuits'])} circuits.")
    print("  `./lab.sh cut <group>` takes every circuit in one of them down at once.")
    return 0

# ----------------------------------------------------------------- cut
def plan_cut(d, srlg):
    hit, survive = [], []
    for c in d["circuits"]:
        if srlg not in c["srlg"]:
            continue
        if c.get("protection") == "1+1":
            # the protect path may itself be in the cut; here it is not modelled
            # as sharing, so the circuit survives with a longer RTT
            survive.append(c)
        else:
            hit.append(c)
    return hit, survive

def cmd_cut(d, a):
    srlg = a.srlg
    known = {s for c in d["circuits"] for s in c["srlg"]}
    if srlg not in known:
        if a.json:
            print(json.dumps({"error": "unknown srlg", "known": sorted(known)}))
        else:
            print(f"unknown shared-risk group: {srlg}")
            print("known groups: " + ", ".join(sorted(known)))
        return 1
    hit, survive = plan_cut(d, srlg)
    if a.json:
        print(json.dumps({
            "srlg": srlg,
            "down": [{"id": c["id"],
                      "ends": [[e["node"], ctr_iface(e["port"])] for e in (c["a_end"], c["z_end"])]}
                     for c in hit],
            "degrade": [{"id": c["id"],
                         "ends": [[e["node"], ctr_iface(e["port"])] for e in (c["a_end"], c["z_end"])],
                         "half_delay": godur(c.get("protect_rtt_ms", c["rtt_ms"]) / 2.0)}
                        for c in survive],
        }))
        return 0
    print(col("b", f"Fibre cut: {srlg}\n"))
    if hit:
        print(col("r", "  Circuits DOWN (unprotected):"))
        for c in hit:
            print(f"    {c['id']:18s} {ends(c):44s} {c['kind']}")
            print(f"    {'':18s} {c['desc']}")
    if survive:
        print(col("y", "\n  Circuits SURVIVING via 1+1 protection switch:"))
        for c in survive:
            base, prot = c["rtt_ms"], c.get("protect_rtt_ms", c["rtt_ms"])
            print(f"    {c['id']:18s} {ends(c):44s} {base}ms -> {prot}ms")
            print(f"    {'':18s} switch is sub-50ms, so BGP and BFD never notice")
    if not hit and not survive:
        print("  nothing in this group")
    lost = sum(c.get("mrc_usd", 0) or 0 for c in hit)
    if lost:
        print(f"\n  ${lost:,}/mo of circuit spend is carrying nothing while this cut is live.")
    print(col("c", "\n  The signature of a protected circuit in a cut is a latency step with no"))
    print(col("c", "  routing event. If you only watch BGP, you will never see it happen."))
    return 0

# ----------------------------------------------------------------- routes
def cmd_routes(d, _a):
    print(col("b", "Circuits by kind\n"))
    order = ["darkfiber", "wave", "carrier-ethernet", "ip-transit", "ix-port", "cloud-ic"]
    for kind in order:
        cs = [c for c in d["circuits"] if c["kind"] == kind]
        if not cs:
            continue
        print(col("c", f"  {kind}"))
        for c in cs:
            prot = c.get("protection", "none")
            pt = col("g", "1+1") if prot == "1+1" else \
                 col("y", "restorable") if prot == "restorable" else col("r", "unprotected")
            print(f"    {c['id']:18s} {c['rtt_ms']:>6.1f}ms  {pt:22s} {c['capacity']:>5s}  {c['carrier']}")
            if "subsea" in c:
                s = c["subsea"]
                cab = d["subsea_cables"][s["cable"]]
                print(f"    {'':18s} cable {s['cable']} ({cab['route']}, {cab['length_km']}km, "
                      f"{cab['fibre_pairs']} pairs, {cab['year']})")
                print(f"    {'':18s} landing {s['landing']} ({d['landing_stations'][s['landing']]['city']})")
        print()
    mrc = sum(c.get("mrc_usd", 0) or 0 for c in d["circuits"])
    print(col("b", f"  Fixed circuit spend: ${mrc:,}/mo, before any transit usage."))
    return 0

def godur(ms):
    """tc/netem duration string containerlab accepts."""
    return f"{int(round(ms*1000))}us" if ms < 1 else f"{ms:g}ms"

def ctr_iface(port):
    return port.replace("Ethernet", "eth")

def cmd_latency(d, a):
    """One line per interface: node iface delay circuit. Consumed by lab.sh."""
    for c in d["circuits"]:
        half = c["rtt_ms"] / 2.0
        for e in (c["a_end"], c["z_end"]):
            print(f"{e['node']} {ctr_iface(e['port'])} {godur(half)} {c['id']}")
    return 0

# ----------------------------------------------------------------- cost
# Where each traffic class SHOULD exit, and the unit economics of each option.
INTENDED = {"cloud": "cloud", "cdn": "pni", "ix_rs": "ix", "ix_bilat": "ix",
            "transit_only": "transit"}
CLASS_NAME = {"cloud": "cloud egress", "cdn": "CDN fill", "ix_rs": "IX peers via route server",
              "ix_bilat": "IX peers bilateral", "transit_only": "transit-only destinations"}
EXIT_NAME = {"cloud": "cloud interconnect", "pni": "PNI", "ix": "internet exchange",
             "transit": "IP transit (primary)", "transit2": "IP transit (transpacific)",
             "internal": "another of our sites", "none": "no route", "unknown": "unresolved"}

def unit_cost(d, exit_class):
    """Marginal dollars per Mbps per month for one more Mbps out of an exit."""
    t1 = next(c for c in d["circuits"] if c["id"] == "TRANSIT-1A")
    t2 = next(c for c in d["circuits"] if c["id"] == "TRANSIT-2")
    rates = {
        "cloud": 0.0,     # flat-rate circuit, already paid
        "pni": 0.0,       # flat-rate cross connect, already paid
        "ix": 0.0,        # flat-rate port, already paid
        "internal": 0.0,  # leaves from another of our sites, on some flat circuit
        "none": 0.0,      # going nowhere costs nothing and is still wrong
        "transit": t1["usage_usd_mbps"],
        "transit2": t2["usage_usd_mbps"],
    }
    # anything we could not classify is priced as transit, the pessimistic case
    return rates.get(exit_class, t1["usage_usd_mbps"])

def cmd_cost(d, a):
    actual = {}
    if a.map:
        for kv in a.map.split(","):
            if "=" in kv:
                k, v = kv.split("=", 1)
                actual[k.strip()] = v.strip()
    prof = d["traffic_profile"]
    print(col("b", "Egress cost, intended against actual\n"))
    print(f"  {'traffic class':30s} {'Mbps':>7s}  {'should exit':22s} {'does exit':22s} {'$/mo':>9s}")
    print("  " + "-" * 94)
    total_actual = total_intended = 0.0
    wrong = []
    for k, mbps in prof.items():
        want = INTENDED.get(k, "transit")
        got = actual.get(k, "unknown")
        ca = mbps * unit_cost(d, got)
        ci = mbps * unit_cost(d, want)
        total_actual += ca
        total_intended += ci
        line = f"  {CLASS_NAME.get(k,k):30s} {mbps:>7d}  {EXIT_NAME[want]:22s} {EXIT_NAME.get(got,got):22s} {ca:>9,.0f}"
        if got != want:
            wrong.append((k, want, got, ca - ci))
            print(col("r", line))
        else:
            print(col("g", line))
    fixed = sum(c.get("mrc_usd", 0) or 0 for c in d["circuits"])
    print("  " + "-" * 94)
    print(f"  {'usage-based (95th percentile)':30s} {'':7s}  {'':22s} {'':22s} {total_actual:>9,.0f}")
    print(f"  {'fixed circuit MRC':30s} {'':7s}  {'':22s} {'':22s} {fixed:>9,.0f}")
    print(col("b", f"  {'TOTAL':30s} {'':7s}  {'':22s} {'':22s} {total_actual+fixed:>9,.0f}"))
    if wrong:
        delta = total_actual - total_intended
        print(col("r", f"\n  ${delta:,.0f}/mo of avoidable transit, "
                       f"${delta*12:,.0f}/yr, from {len(wrong)} misrouted class(es):"))
        for k, want, got, dd in wrong:
            print(col("y", f"    {CLASS_NAME.get(k,k)}: on {EXIT_NAME.get(got,got)}, "
                           f"should be on {EXIT_NAME[want]}  (+${dd:,.0f}/mo)"))
        if any(g == "none" for _, _, g, _ in wrong):
            print(col("r", "\n  At least one class has no route at all. That is an outage, not a"))
            print(col("r", "  billing problem, and it comes first."))
        elif all(unit_cost(d, g) == 0 for _, _, g, _ in wrong):
            print(col("c", "\n  Nothing here costs more money, and nothing here is right either:"))
            print(col("c", "  traffic is leaving on a circuit the design did not choose."))
        else:
            print(col("c", "\n  None of this need be an outage. Destinations stay reachable and"))
            print(col("c", "  sessions stay up; the symptom is the invoice."))
    else:
        print(col("g", "\n  Every traffic class is exiting where it should."))
    return 0

def main():
    p = argparse.ArgumentParser(add_help=True)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("srlg"); sub.add_parser("srlgs")
    sub.add_parser("routes"); sub.add_parser("latency")
    pc = sub.add_parser("cut"); pc.add_argument("srlg"); pc.add_argument("--json", action="store_true")
    px = sub.add_parser("cost"); px.add_argument("--map", default="")
    a = p.parse_args()
    d = load()
    return {"srlg": cmd_srlg, "srlgs": cmd_srlgs, "cut": cmd_cut,
            "routes": cmd_routes, "latency": cmd_latency, "cost": cmd_cost}[a.cmd](d, a)

if __name__ == "__main__":
    sys.exit(main())
