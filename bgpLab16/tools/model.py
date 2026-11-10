#!/usr/bin/env python3
"""bgp-lab16 model: turn the rules in model/ into a complete plan.

Nothing here is looked up. Every address, ASN, interface and cost is computed
from (region id, router id, link id), which is the only way an address plan
survives a network you cannot hold in your head.

  model.py plan        the whole computed plan
  model.py addresses   just the address plan
  model.py links       link ids, interfaces and costs
  model.py json        machine readable, for render.py and audit.py
"""
import sys, os, json, ipaddress, argparse
try:
    import yaml
except ImportError:
    sys.exit("pyyaml required: pip3 install --break-system-packages pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))
MDIR = os.path.join(HERE, "..", "model")
C = dict(r="\033[31m", y="\033[33m", g="\033[32m", c="\033[36m", b="\033[1m", n="\033[0m")
def col(k, s): return f"{C[k]}{s}{C['n']}"


def load():
    net = yaml.safe_load(open(os.path.join(MDIR, "network.yml")))
    pol = yaml.safe_load(open(os.path.join(MDIR, "policy.yml")))
    return net, pol


def expand(tpl, **kw):
    out = tpl
    for k, v in kw.items():
        out = out.replace("{" + k + "}", str(v))
    return out


def build(net=None, pol=None):
    if net is None:
        net, pol = load()
    R, RU, RL = net["regions"], net["routers"], net["rules"]
    asn = net["asn"]
    plan = {"asn": asn, "name": net["name"], "devices": {}, "links": [],
            "external": [], "peers": net["peers"], "policy": pol}

    # ---- devices, and their computed identity
    for rg, meta in R.items():
        for i, ru in enumerate(RU, start=1):
            name = f"{rg}-{ru}"
            plan["devices"][name] = {
                "name": name, "region": rg, "region_id": meta["id"],
                "router_id_n": i, "city": meta["city"], "role": ru,
                "is_rr": ru == RL["route_reflector"],
                "lo4": expand(RL["loopback4"], R=meta["id"], N=i),
                "region4": expand(pol["ours"]["region4"], R=meta["id"]),
                "interfaces": {},   # filled below
            }

    # ---- link ids. Deterministic: the order the model lists them, which is
    #      itself sorted by plane then region pair. A link's id never moves.
    for lid, l in enumerate(net["backbone"], start=1):
        a, b = l["a"], l["b"]
        intra = bool(l.get("intra"))
        cost = RL["ospf_cost_intra"] if intra else l["rtt"]
        net4 = ipaddress.ip_network(expand(RL["p2p4"], L=lid))
        plan["links"].append({
            "id": lid, "a": a, "b": b, "intra": intra, "cost": cost,
            "rtt": l.get("rtt"), "mtu": RL["mtu_backbone"],
            "a4": f"{net4[0]}/31", "b4": f"{net4[1]}/31", "net4": str(net4),
        })

    # ---- external edges get link ids after the backbone
    base = len(plan["links"])
    for j, e in enumerate(net["external"], start=1):
        lid = base + j
        net4 = ipaddress.ip_network(expand(RL["p2p4"], L=lid))
        plan["external"].append({
            "id": lid, "device": e["device"], "peer": e["peer"],
            "asn": e["asn"], "kind": e["kind"], "mtu": RL["mtu_handoff"],
            "a4": f"{net4[0]}/31", "b4": f"{net4[1]}/31", "net4": str(net4),
        })

    # ---- interface assignment. The rule is "backbone links sorted by the far
    #      end's name, then external links sorted by peer name". Not by whoever
    #      happened to cable it first.
    for dev in plan["devices"]:
        mine = []
        for l in plan["links"]:
            if l["a"] == dev:
                mine.append((l["b"], "bb", l, "a"))
            elif l["b"] == dev:
                mine.append((l["a"], "bb", l, "b"))
        mine.sort(key=lambda t: t[0])
        ext = [(e["peer"], "ext", e, "a") for e in plan["external"] if e["device"] == dev]
        ext.sort(key=lambda t: t[0])
        for n, (far, kind, obj, side) in enumerate(mine + ext, start=1):
            ifn = f"Ethernet{n}"
            plan["devices"][dev]["interfaces"][ifn] = {
                "far": far, "kind": kind, "link_id": obj["id"],
                "v4": obj[side + "4"], "net4": obj["net4"],
                "mtu": obj["mtu"],
                "cost": obj.get("cost"),
                "peer_v4": obj[("b" if side == "a" else "a") + "4"].split("/")[0],
                "peer_asn": obj.get("asn"),
                "ext_kind": obj.get("kind"),
            }
            obj.setdefault("if", {})[dev] = ifn

    # ---- the far side of every external link needs interfaces too, assigned
    #      by the same rule rather than by whoever racked it
    for peer in sorted(plan["peers"]):
        n = 0
        for e in plan["external"]:
            if e["peer"] != peer:
                continue
            n += 1
            e.setdefault("if", {})[peer] = f"Ethernet{n}"

    # ---- iBGP: RRs full mesh with each other, each r2 to its own region's RR
    rrs = sorted(d for d, v in plan["devices"].items() if v["is_rr"])
    for d, v in plan["devices"].items():
        if v["is_rr"]:
            v["ibgp"] = [dict(peer=o, client=False) for o in rrs if o != d]
            v["ibgp"] += [dict(peer=c, client=True) for c in sorted(plan["devices"])
                          if plan["devices"][c]["region"] == v["region"] and c != d]
        else:
            rr = next(o for o in rrs if plan["devices"][o]["region"] == v["region"])
            v["ibgp"] = [dict(peer=rr, client=False)]
    return plan


# ----------------------------------------------------------------- printing
def cmd_addresses(plan, _a):
    print(col("b", "Computed address plan. Nothing below was typed by a human.\n"))
    print(f"  {'device':<10} {'rgn':<4} {'region id':<10} {'router id':<10} "
          f"{'loopback':<16} {'originates':<16}")
    print("  " + "-" * 86)
    for d in sorted(plan["devices"]):
        v = plan["devices"][d]
        rr = col("c", "RR") if v["is_rr"] else "  "
        print(f"  {d:<10} {v['region']:<4} {v['region_id']:<10} {v['router_id_n']:<10} "
              f"{v['lo4']:<16} {v['region4']:<16} {rr}")
    print()
    print(col("b", "  The rules that produced it:"))
    net, _ = load()
    for k in ("loopback4", "p2p4", "router_id"):
        print(f"    {k:<14} {net['rules'][k]}")
    print("    {R} = region id, {N} = router id, {L} = link id")
    return 0


def cmd_links(plan, _a):
    print(col("b", "Links: id, interfaces and cost, all computed\n"))
    print(f"  {'id':<4} {'a':<10} {'if':<11} {'b':<10} {'if':<11} "
          f"{'prefix':<18} {'cost':>6} {'mtu':>6}")
    print("  " + "-" * 86)
    for l in plan["links"]:
        ia = l.get("if", {}).get(l["a"], "?")
        ib = l.get("if", {}).get(l["b"], "?")
        kind = "intra" if l["intra"] else f"{l['rtt']}ms"
        print(f"  {l['id']:<4} {l['a']:<10} {ia:<11} {l['b']:<10} {ib:<11} "
              f"{l['a4'].split('/')[0]+'/31':<18} {l['cost']:>6} {l['mtu']:>6}   {kind}")
    print()
    for e in plan["external"]:
        ifn = e.get("if", {}).get(e["device"], "?")
        pif = e.get("if", {}).get(e["peer"], "?")
        print(f"  {e['id']:<4} {e['device']:<10} {ifn:<11} {e['peer']:<10} "
              f"{pif:<11} {e['a4'].split('/')[0]+'/31':<18} {'-':>6} {e['mtu']:>6}   "
              f"{e['kind']} AS{e['asn']}")
    return 0


def cmd_plan(plan, a):
    cmd_addresses(plan, a); print(); cmd_links(plan, a)
    print()
    print(col("b", "iBGP: route reflectors full mesh, each region's r2 is a client\n"))
    for d in sorted(plan["devices"]):
        v = plan["devices"][d]
        ps = ", ".join(f"{p['peer']}{'*' if p['client'] else ''}" for p in v["ibgp"])
        print(f"  {d:<10} {'RR' if v['is_rr'] else '  '}  {ps}")
    print("\n  * = this router reflects to that peer")
    return 0


def cmd_json(plan, _a):
    print(json.dumps(plan, indent=1, sort_keys=True))
    return 0


def main():
    p = argparse.ArgumentParser()
    s = p.add_subparsers(dest="cmd", required=True)
    for n in ("plan", "addresses", "links", "json"):
        s.add_parser(n)
    a = p.parse_args()
    return {"plan": cmd_plan, "addresses": cmd_addresses,
            "links": cmd_links, "json": cmd_json}[a.cmd](build(), a)


if __name__ == "__main__":
    sys.exit(main())
