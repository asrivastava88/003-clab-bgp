#!/usr/bin/env python3
"""bgp-lab16 audit: compare the running network against the model.

This tool reports DIVERGENCE. It does not, and cannot, tell you which side is
wrong. A finding means the model and the network disagree; whether the fix is
to change the router or to change the model is a judgement that needs context
the audit does not have. Remediating without triaging is how a bad model gets
pushed to a good network.

  audit.py <config> [<config> ...]        audit those running-configs
  audit.py --rendered                     audit configs/solution (a CI gate)
"""
import sys, os, re, argparse, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import build

C = dict(r="\033[31m", y="\033[33m", g="\033[32m", c="\033[36m", b="\033[1m", n="\033[0m")
def col(k, s): return f"{C[k]}{s}{C['n']}"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def parse(text):
    d = dict(host="?", ifaces=collections.defaultdict(dict), ospf_nets=set(),
             ospf_rid=None, bgp_asn=None, bgp_rid=None,
             nbr={}, af4=set(), nhs=set(), rrc=set(), rmap_in={}, rmap_out={},
             maxr={}, rmaps=collections.defaultdict(dict), plists=collections.defaultdict(list),
             networks=set())
    cur_if = None; ctx = None; rm = None
    for raw in text.splitlines():
        line = raw.strip()
        if m := re.match(r"hostname (\S+)", line):
            d["host"] = m.group(1)
        elif m := re.match(r"interface (\S+)", line):
            cur_if, ctx, rm = m.group(1), "if", None
        elif m := re.match(r"router ospf", line):
            ctx, cur_if, rm = "ospf", None, None
        elif m := re.match(r"router bgp (\d+)", line):
            ctx, cur_if, rm = "bgp", None, None; d["bgp_asn"] = int(m.group(1))
        elif m := re.match(r"route-map (\S+) (permit|deny) (\d+)", line):
            ctx, cur_if = "rmap", None
            rm = (m.group(1), int(m.group(3)))
            d["rmaps"][rm[0]][rm[1]] = dict(action=m.group(2), sets=[], match=None)
        elif m := re.match(r"ip prefix-list (\S+) seq \d+ (.+)", line):
            d["plists"][m.group(1)].append(m.group(2)); ctx, rm = None, None
        elif ctx == "if" and cur_if:
            if m := re.match(r"ip address (\S+)", line):
                d["ifaces"][cur_if]["ip"] = m.group(1)
            elif m := re.match(r"mtu (\d+)", line):
                d["ifaces"][cur_if]["mtu"] = int(m.group(1))
            elif m := re.match(r"ip ospf cost (\d+)", line):
                d["ifaces"][cur_if]["cost"] = int(m.group(1))
            elif m := re.match(r"description (.+)", line):
                d["ifaces"][cur_if]["desc"] = m.group(1)
        elif ctx == "ospf":
            if m := re.match(r"network (\S+) area", line):
                d["ospf_nets"].add(m.group(1))
            elif m := re.match(r"router-id (\S+)", line):
                d["ospf_rid"] = m.group(1)
        elif ctx == "bgp":
            if m := re.match(r"router-id (\S+)", line):
                d["bgp_rid"] = m.group(1)
            elif m := re.match(r"neighbor (\S+) remote-as (\d+)", line):
                d["nbr"][m.group(1)] = int(m.group(2))
            elif m := re.match(r"neighbor (\S+) maximum-routes (\d+)", line):
                d["maxr"][m.group(1)] = int(m.group(2))
            elif m := re.match(r"neighbor (\S+) activate", line):
                d["af4"].add(m.group(1))
            elif m := re.match(r"neighbor (\S+) next-hop-self", line):
                d["nhs"].add(m.group(1))
            elif m := re.match(r"neighbor (\S+) route-reflector-client", line):
                d["rrc"].add(m.group(1))
            elif m := re.match(r"neighbor (\S+) route-map (\S+) (in|out)", line):
                (d["rmap_in"] if m.group(3) == "in" else d["rmap_out"])[m.group(1)] = m.group(2)
            elif m := re.match(r"network (\S+)", line):
                d["networks"].add(m.group(1))
        elif ctx == "rmap" and rm:
            if line.startswith("set "):
                d["rmaps"][rm[0]][rm[1]]["sets"].append(line)
            elif line.startswith("match "):
                d["rmaps"][rm[0]][rm[1]]["match"] = line
    return d


def audit_device(plan, d, F):
    name = d["host"]
    v = plan["devices"].get(name)
    if not v:
        return
    pol = plan["policy"]
    add = lambda k, m: F.append((name, k, m))

    # ---- identity
    if d["bgp_rid"] != v["lo4"].split("/")[0]:
        add("ROUTER-ID", f"BGP router-id is {d['bgp_rid']}; the model computes "
                         f"{v['lo4'].split('/')[0]} from the loopback rule")
    if "Loopback0" in d["ifaces"]:
        got = d["ifaces"]["Loopback0"].get("ip")
        if got != v["lo4"]:
            add("ADDRESSING", f"Loopback0 is {got}; the model computes {v['lo4']} "
                              f"from 10.{{R}}.0.{{N}}/32 with R={v['region_id']}, N={v['router_id_n']}")

    # ---- interfaces: address, MTU, cost, and the assignment rule itself
    want = v["interfaces"]
    for ifn in sorted(want, key=lambda x: int(x.replace("Ethernet", ""))):
        w = want[ifn]
        g = d["ifaces"].get(ifn)
        if not g:
            add("INTERFACE", f"{ifn} is absent; the model assigns it to {w['far']} "
                             f"(link {w['link_id']})")
            continue
        if g.get("ip") != w["v4"]:
            add("ADDRESSING", f"{ifn} is {g.get('ip')}; the model computes {w['v4']} "
                              f"from 10.254.{{L}}.0/31 with L={w['link_id']}")
        if g.get("mtu") != w["mtu"]:
            add("MTU", f"{ifn} MTU is {g.get('mtu')}; the model says {w['mtu']}")
        if w["kind"] == "bb" and g.get("cost") != w["cost"]:
            src = "intra-region rule" if plan_intra(plan, w["link_id"]) else "the measured RTT"
            add("IGP-COST", f"{ifn} OSPF cost is {g.get('cost')}; the model says "
                            f"{w['cost']}, which comes from {src}")
    for ifn in sorted(d["ifaces"]):
        if ifn.startswith("Ethernet") and ifn not in want:
            add("INTERFACE", f"{ifn} is configured and the model does not describe it")

    # ---- OSPF membership
    want_nets = {v["lo4"]} | {want[i]["net4"] for i in want if want[i]["kind"] == "bb"}
    for n in sorted(want_nets - d["ospf_nets"]):
        add("IGP", f"{n} is not in OSPF; the model expects it")
    for n in sorted(d["ospf_nets"] - want_nets):
        add("IGP", f"{n} is in OSPF and the model does not expect it")

    # ---- BGP neighbour set
    want_nbr = {}
    for p in v["ibgp"]:
        want_nbr[plan["devices"][p["peer"]]["lo4"].split("/")[0]] = (plan["asn"], p)
    for ifn, i in want.items():
        if i["kind"] == "ext":
            want_nbr[i["peer_v4"]] = (i["peer_asn"], None)
    for a in sorted(set(want_nbr) - set(d["nbr"])):
        add("BGP-TOPOLOGY", f"neighbor {a} (AS {want_nbr[a][0]}) is in the model and not configured")
    for a in sorted(set(d["nbr"]) - set(want_nbr)):
        add("BGP-TOPOLOGY", f"neighbor {a} (AS {d['nbr'][a]}) is configured and not in the model")
    for a in sorted(set(want_nbr) & set(d["nbr"])):
        if d["nbr"][a] != want_nbr[a][0]:
            add("BGP-TOPOLOGY", f"neighbor {a} remote-as is {d['nbr'][a]}; the model says {want_nbr[a][0]}")

    # ---- reflector relationships
    want_rrc = {plan["devices"][p["peer"]]["lo4"].split("/")[0]
                for p in v["ibgp"] if p["client"]}
    for a in sorted(want_rrc - d["rrc"]):
        add("BGP-RR", f"neighbor {a} is a reflector client in the model and is not "
                      f"configured as one")
    for a in sorted(d["rrc"] - want_rrc):
        add("BGP-RR", f"neighbor {a} is configured as a reflector client and the model "
                      f"does not make it one")
    want_nhs = {plan["devices"][p["peer"]]["lo4"].split("/")[0] for p in v["ibgp"]}
    for a in sorted(want_nhs - d["nhs"]):
        add("BGP-NEXTHOP", f"iBGP neighbor {a} has no next-hop-self")

    # ---- policy values, from model/policy.yml
    for kind in ("transit", "peer"):
        nm = f"RM-{kind.upper()}-IN"
        cl = d["rmaps"].get(nm)
        if not cl:
            if any(i["kind"] == "ext" and i["ext_kind"] == kind for i in want.values()):
                add("POLICY", f"{nm} is absent; the model needs it for a {kind} session")
            continue
        lps = [int(m.group(1)) for s in cl.values() for x in s["sets"]
               if (m := re.match(r"set local-preference (\d+)", x))]
        if lps and lps[0] != pol["local_pref"][kind]:
            add("POLICY", f"{nm} sets local-preference {lps[0]}; model/policy.yml "
                          f"says {pol['local_pref'][kind]} for a {kind}")
        cms = [m.group(1) for s in cl.values() for x in s["sets"]
               if (m := re.match(r"set community (\S+)", x))]
        if cms and cms[0] != pol["communities"][kind]:
            add("POLICY", f"{nm} sets community {cms[0]}; model/policy.yml says "
                          f"{pol['communities'][kind]}")
    for ifn, i in want.items():
        if i["kind"] != "ext":
            continue
        a = i["peer_v4"]
        exp = pol["filters"][f"max_prefix_{i['ext_kind']}"]
        if a in d["maxr"] and d["maxr"][a] != exp:
            add("POLICY", f"neighbor {a} maximum-routes is {d['maxr'][a]}; "
                          f"model/policy.yml says {exp}")
        if d["rmap_in"].get(a) != f"RM-{i['ext_kind'].upper()}-IN":
            add("POLICY", f"neighbor {a} inbound route-map is {d['rmap_in'].get(a)}; "
                          f"the model attaches RM-{i['ext_kind'].upper()}-IN")
    if v["region4"] not in d["networks"]:
        add("ORIGIN", f"{v['region4']} is not originated; the model computes it from "
                      f"198.18.{{R}}.0/24 with R={v['region_id']}")


def plan_intra(plan, lid):
    for l in plan["links"]:
        if l["id"] == lid:
            return l["intra"]
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("configs", nargs="*")
    ap.add_argument("--rendered", action="store_true")
    a = ap.parse_args()
    paths = a.configs
    if a.rendered or not paths:
        sol = os.path.join(ROOT, "configs", "solution")
        paths = [os.path.join(sol, f) for f in sorted(os.listdir(sol))]
    plan = build()
    F = []
    seen = set()
    for p in paths:
        d = parse(open(p).read())
        if d["host"] in plan["devices"]:
            seen.add(d["host"])
            audit_device(plan, d, F)
    for miss in sorted(set(plan["devices"]) - seen):
        F.append((miss, "DEVICE", "the model describes this device and it was not read"))

    print(col("b", "Drift between the model and the network"))
    print("The model is model/network.yml + model/policy.yml. Every value it is")
    print("compared against was computed, not looked up.\n")
    if not F:
        print(col("g", "  No drift. The running network matches the model exactly."))
        return 0
    by = collections.defaultdict(list)
    for h, k, m in F:
        by[h].append((k, m))
    for h in sorted(by):
        print(col("c", f"  {h}"))
        for k, m in by[h]:
            print(f"    {col('r', k):<24} {m}")
        print()
    kinds = collections.Counter(k for _, k, _ in F)
    print(col("b", f"  {len(F)} finding(s): " + ", ".join(f"{v}x {k}" for k, v in kinds.most_common())))
    print()
    print(col("y", "  This tool reports divergence. It does not know which side is wrong."))
    print(col("y", "  Before remediating, decide for each finding whether the network drifted"))
    print(col("y", "  from the model or the model drifted from the network. Pushing the model"))
    print(col("y", "  at a correct network is the more expensive mistake of the two."))
    return 1


if __name__ == "__main__":
    sys.exit(main())
