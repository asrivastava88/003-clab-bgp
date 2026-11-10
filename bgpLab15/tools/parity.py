#!/usr/bin/env python3
"""bgp-lab15 address-family parity audit.

A dual-stack network is two networks that happen to share a chassis. They are
configured twice, changed twice, and monitored once -- in IPv4. This reads the
running configuration and compares every IPv4 construct against its IPv6 twin.

It is a CONFIG audit, not a state check, which is the point: it finds the
divergence that has not caused a symptom yet, including policy that is only
reachable during a maintenance.

Convention it relies on, enforced by tools/gen_configs.py:
  route-map   RM-FOO   <->  RM-FOO6
  prefix-list PL-FOO   <->  PL6-FOO

  parity.py <config> [<config> ...]
"""
import sys, re, os, collections

C = dict(r="\033[31m", y="\033[33m", g="\033[32m", c="\033[36m", b="\033[1m", n="\033[0m")
def col(k, s): return f"{C[k]}{s}{C['n']}"

# Declared exceptions. An audit with no exception list is an audit nobody
# reads: the intentional divergences drown the real ones. In production this
# list comes from your peering database and your design docs, and every entry
# has to be justified out loud, which is the control.
V6_ONLY_AS = {65301}                     # peers that exist in IPv6 only
V6_ONLY_MAPS = {"RM-P2-IN6"}             # their policy has no IPv4 twin by design
SINGLE_BORDER_AS = {65200: "backup transit, deliberately single-homed to edge2",
                    65400: "transit customer, single-homed to edge1 by their choice"}
# Prefix-lists whose two families must have the SAME number of entries, because
# they enumerate the same things in two notations. Bogon lists are exempt: the
# IPv6 martian set is genuinely a different length from the IPv4 one.
STRUCTURAL_PL = {"OUR", "OUR-ANY", "CUST", "REG-P1", "REG-CU"}


def parse(text):
    d = dict(host="?", pl4={}, pl6={}, rmaps=collections.defaultdict(dict),
             nbr={}, af4=set(), af6=set(), af4map={}, af6map={}, nhs4=set(), nhs6=set())
    af = None          # None | 4 | 6
    rm = None          # (name, seq)
    for raw in text.splitlines():
        line = raw.strip()
        if m := re.match(r"hostname (\S+)", line):
            d["host"] = m.group(1)
        elif m := re.match(r"ip prefix-list (\S+) seq \d+ (.+)", line):
            d["pl4"].setdefault(m.group(1), []).append(m.group(2)); rm = None
        elif m := re.match(r"ipv6 prefix-list (\S+) seq \d+ (.+)", line):
            d["pl6"].setdefault(m.group(1), []).append(m.group(2)); rm = None
        elif m := re.match(r"route-map (\S+) (permit|deny) (\d+)", line):
            rm = (m.group(1), int(m.group(3)))
            d["rmaps"][rm[0]][rm[1]] = dict(action=m.group(2), sets=[], match=None)
        elif rm and line.startswith("match "):
            d["rmaps"][rm[0]][rm[1]]["match"] = line
        elif rm and line.startswith("set "):
            d["rmaps"][rm[0]][rm[1]]["sets"].append(line)
        elif line.startswith("address-family ipv4"):
            af, rm = 4, None
        elif line.startswith("address-family ipv6"):
            af, rm = 6, None
        elif m := re.match(r"neighbor (\S+) remote-as (\d+)", line):
            d["nbr"][m.group(1)] = int(m.group(2)); rm = None
        elif m := re.match(r"neighbor (\S+) activate", line):
            (d["af4"] if af == 4 else d["af6"]).add(m.group(1))
        elif m := re.match(r"neighbor (\S+) next-hop-self", line):
            if af == 6:
                d["nhs6"].add(m.group(1))
            else:
                d["nhs4"].add(m.group(1))
        elif m := re.match(r"neighbor (\S+) route-map (\S+) (in|out)", line):
            tgt = d["af4map"] if af == 4 else d["af6map"]
            tgt.setdefault(m.group(1), {})[m.group(3)] = m.group(2)
        elif line in ("!", "end") or line.startswith("router "):
            rm = None
    return d


def lp_of(clauses):
    out = []
    for seq in sorted(clauses):
        for s in clauses[seq]["sets"]:
            if m := re.match(r"set local-preference (\d+)", s):
                out.append(int(m.group(1)))
    return out

def prepends_of(clauses):
    out = []
    for seq in sorted(clauses):
        for s in clauses[seq]["sets"]:
            if m := re.match(r"set as-path prepend (.+)", s):
                out.append(len(m.group(1).split()))
    return out

def comms_of(clauses):
    out = []
    for seq in sorted(clauses):
        for s in clauses[seq]["sets"]:
            if m := re.match(r"set community (\S+)", s):
                out.append(m.group(1))
    return sorted(out)

def is_v6_name(n):
    return n.endswith("6") and not n.endswith("-6")


def audit_one(d, findings, declared):
    h = d["host"]

    # ---- route-map twins
    for name, clauses in sorted(d["rmaps"].items()):
        if is_v6_name(name):
            continue
        twin = name + "6"
        if twin not in d["rmaps"]:
            findings.append((h, "route-map", f"{name} has no IPv6 twin {twin}"))
            continue
        t = d["rmaps"][twin]
        permits  = [s for s in clauses if clauses[s]["action"] == "permit"]
        permits6 = [s for s in t if t[s]["action"] == "permit"]
        if len(clauses) != len(t):
            findings.append((h, "route-map",
                f"{name} has {len(clauses)} clause(s), {twin} has {len(t)}"))
        if len(permits) != len(permits6):
            findings.append((h, "route-map",
                f"{name} has {len(permits)} permit clause(s), {twin} has {len(permits6)}"))
        if not permits6 and permits:
            findings.append((h, "route-map",
                f"{twin} has no permit clause at all, so it denies everything"))
        if (a := lp_of(clauses)) != (b := lp_of(t)):
            findings.append((h, "local-pref", f"{name} sets {a}, {twin} sets {b}"))
        if (a := prepends_of(clauses)) != (b := prepends_of(t)):
            findings.append((h, "as-path", f"{name} prepends {a}, {twin} prepends {b}"))
        if (a := comms_of(clauses)) != (b := comms_of(t)):
            findings.append((h, "community", f"{name} sets {a}, {twin} sets {b}"))
    for name in sorted(d["rmaps"]):
        if is_v6_name(name) and name[:-1] not in d["rmaps"]:
            if name in V6_ONLY_MAPS:
                declared.append((h, "route-map",
                    f"{name} has no IPv4 twin: serves an IPv6-only peer"))
            else:
                findings.append((h, "route-map", f"{name} has no IPv4 twin {name[:-1]}"))

    # ---- prefix-list twins. Contents differ by family; presence must not, and
    #      for the lists that enumerate the same things, neither must the count.
    for name, ents in sorted(d["pl4"].items()):
        twin = "PL6-" + name[3:] if name.startswith("PL-") else None
        if not twin:
            continue
        if twin not in d["pl6"]:
            findings.append((h, "prefix-list", f"{name} has no IPv6 twin {twin}"))
            continue
        if name[3:] in STRUCTURAL_PL:
            n4, n6 = len(ents), len(d["pl6"][twin])
            if n4 != n6:
                findings.append((h, "prefix-list",
                    f"{name} has {n4} entry/entries, {twin} has {n6}"))
            d4 = sum(1 for e in ents if e.startswith("deny"))
            d6 = sum(1 for e in d["pl6"][twin] if e.startswith("deny"))
            if d4 != d6:
                findings.append((h, "prefix-list",
                    f"{name} has {d4} deny entry/entries, {twin} has {d6}"))
    for name, ents in sorted(d["pl6"].items()):
        twin = "PL-" + name[4:] if name.startswith("PL6-") else None
        if twin and twin not in d["pl4"] and name[4:] not in ("REG-P2",):
            findings.append((h, "prefix-list", f"{name} has no IPv4 twin {twin}"))

    # ---- per-AS presence across the two families
    by_as = collections.defaultdict(lambda: {"4": [], "6": []})
    for ip, asn in d["nbr"].items():
        fam = "6" if ":" in ip else "4"
        by_as[asn][fam].append(ip)
    for asn, fams in sorted(by_as.items()):
        if fams["4"] and not fams["6"]:
            findings.append((h, "session", f"AS {asn} has an IPv4 session and no IPv6 session"))
        if fams["6"] and not fams["4"] and asn not in V6_ONLY_AS:
            findings.append((h, "session", f"AS {asn} has an IPv6 session and no IPv4 session"))

    # ---- activation and policy attachment
    for ip, asn in sorted(d["nbr"].items()):
        fam, act, maps = ("6", d["af6"], d["af6map"]) if ":" in ip else ("4", d["af4"], d["af4map"])
        if ip not in act:
            findings.append((h, "activation",
                f"neighbor {ip} (AS {asn}) is configured and not activated in any address family"))
            continue
        if asn == 65010:
            continue        # iBGP carries no inbound/outbound policy here
        m = maps.get(ip, {})
        for direction in ("in", "out"):
            if direction not in m:
                findings.append((h, "policy",
                    f"neighbor {ip} (AS {asn}, IPv{fam}) has no {direction}bound route-map"))

    # ---- the two families of one relationship must use TWIN policies, not
    #      merely some policy each. This is where a copy-paste lands.
    for asn in sorted(set(d["nbr"].values())):
        if asn == 65010:
            continue
        v4ips = [i for i, a in d["nbr"].items() if a == asn and ":" not in i]
        v6ips = [i for i, a in d["nbr"].items() if a == asn and ":" in i]
        if not v4ips or not v6ips:
            continue
        for direction in ("in", "out"):
            m4 = d["af4map"].get(v4ips[0], {}).get(direction)
            m6 = d["af6map"].get(v6ips[0], {}).get(direction)
            if m4 and m6 and m6 != m4 + "6":
                findings.append((h, "policy",
                    f"AS {asn} uses {m4} {direction}bound in IPv4 but {m6} in IPv6, "
                    f"which is not its twin"))

    # ---- next-hop-self parity on iBGP
    ib4 = [ip for ip, a in d["nbr"].items() if a == 65010 and ":" not in ip]
    ib6 = [ip for ip, a in d["nbr"].items() if a == 65010 and ":" in ip]
    for ip in ib4:
        if ip not in d["nhs4"]:
            findings.append((h, "next-hop", f"iBGP {ip} (IPv4) has no next-hop-self"))
    for ip in ib6:
        if ip not in d["nhs6"]:
            findings.append((h, "next-hop", f"iBGP {ip} (IPv6) has no next-hop-self"))


def audit_cross(parsed, findings, declared):
    """Two borders should offer the same set of relationships."""
    seen = {}
    for d in parsed:
        fams = collections.defaultdict(set)
        for ip, asn in d["nbr"].items():
            if asn == 65010:
                continue
            fams[asn].add("6" if ":" in ip else "4")
        seen[d["host"]] = fams
    hosts = sorted(seen)
    if len(hosts) < 2:
        return
    allas = set().union(*[set(v) for v in seen.values()])
    for asn in sorted(allas):
        present = {h: seen[h].get(asn, set()) for h in hosts}
        where = [h for h in hosts if present[h]]
        if 0 < len(where) < len(hosts):
            missing = [h for h in hosts if not present[h]]
            msg = f"AS {asn} is configured on {', '.join(where)} and not on {', '.join(missing)}"
            if asn in SINGLE_BORDER_AS:
                declared.append(("cross", "redundancy", f"{msg}: {SINGLE_BORDER_AS[asn]}"))
            else:
                findings.append(("cross", "redundancy", msg))
        elif len(where) == len(hosts):
            fams = {h: "".join(sorted(present[h])) for h in hosts}
            if len(set(fams.values())) > 1:
                findings.append(("cross", "redundancy",
                    f"AS {asn} families differ by border: " +
                    ", ".join(f"{h}=IPv{fams[h]}" for h in hosts)))


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    parsed, ours = [], []
    for p in argv:
        d = parse(open(p).read())
        parsed.append(d)
        if 65010 in d["nbr"].values():
            ours.append(d)
    findings, declared = [], []
    for d in ours:
        audit_one(d, findings, declared)
    audit_cross(ours, findings, declared)

    print(col("b", "Address-family parity audit"))
    print("Every IPv4 construct is compared against its IPv6 twin. This is a")
    print("config audit, so it finds divergence that has not caused a symptom yet.\n")
    if declared:
        print(col("y", f"  {len(declared)} declared exception(s), accepted by design:"))
        for h, kind, msg in declared:
            print(f"    {col('y','ok'):<12} {h}: {msg}")
        print()
    if not findings:
        print(col("g", "  No undeclared divergence. The two address families match."))
        return 0
    by_host = collections.defaultdict(list)
    for h, kind, msg in findings:
        by_host[h].append((kind, msg))
    for h in sorted(by_host):
        print(col("c", f"  {h}"))
        for kind, msg in by_host[h]:
            print(f"    {col('r', kind.upper()):<22} {msg}")
        print()
    print(col("b", f"  {len(findings)} divergence(s)."))
    print("  A divergence is not automatically a fault. It is a place where the two")
    print("  families were changed at different times, which is where faults live.")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
