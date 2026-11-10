#!/usr/bin/env python3
"""bgp-lab18 config generator: three regions, two carriers, 38 nodes.

Each region is a complete five-stage Clos of the kind Lab 17 built: two
super-spines, two pods of two spines and two leaves, plus two border routers
hanging off the super-spine tier. The three regions buy DCI from TWO
independent carriers, which is the detail that makes this lab what it is.

Inside a region, the shared-ASN-per-tier plan prevents a device from becoming
a transit path between its own peers, for free, via AS-path loop detection.

ACROSS regions it does not. A route from Ashburn arriving at Seattle via
carrier A and re-advertised to carrier B carries no ASN that carrier B
recognises as its own, so carrier B accepts it and Seattle is now a transit
path between Ashburn and London -- across Seattle's own fabric and its own
paid DCI circuits. Nothing in the numbering stops that. Only policy does.

Two levels of summarisation:
    pod  /17  originated by the pod's spines, announced to the super-spines
    region /16 originated by the region's borders, announced to the carriers

which means an aggregate can outlive its contents in two different places.

All space is RFC 1918 or documentation. Every name is fictional.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "configs", "solution")
MTU = 9214
WAN = {"wan1": 65500, "wan2": 65600}          # two independent carriers
ANYCAST = "10.100.0.0/24"

REGIONS = {                                    # name -> index
    "wst": dict(idx=1, city="Seattle"),
    "est": dict(idx=2, city="Ashburn"),
    "eur": dict(idx=3, city="London"),
}
PODS = (1, 2)
LEAVES = (1, 2)

def r_base(r):   return 65000 + REGIONS[r]["idx"] * 100
def ss_asn(r):   return r_base(r)                       # 65100 / 65200 / 65300
def sp_asn(r,p): return r_base(r) + p                   # one ASN per pod
def bd_asn(r):   return r_base(r) + 9                   # both borders share it
def lf_asn(r,p,n): return r_base(r) + 10 + (p-1)*2 + n

def srv_region(r): return f"10.{10+REGIONS[r]['idx']}.0.0/16"
def srv_pod(r,p):  return f"10.{10+REGIONS[r]['idx']}.{(p-1)*128}.0/17"
def srv_nets(r,p,n):
    base = (p-1)*128 + (n-1)*4 + 1
    return [f"10.{10+REGIONS[r]['idx']}.{base+i}.0/24" for i in range(4)]

def dev_ss(r,i):    return f"{r}-ss{i}"
def dev_sp(r,p,i):  return f"{r}-p{p}-s{i}"
def dev_lf(r,p,i):  return f"{r}-p{p}-l{i}"
def dev_bd(r,i):    return f"{r}-b{i}"

LO = {}
for r, m in REGIONS.items():
    x = m["idx"]
    LO[dev_ss(r,1)] = f"10.0.{x}.1";  LO[dev_ss(r,2)] = f"10.0.{x}.2"
    for p in PODS:
        LO[dev_sp(r,p,1)] = f"10.0.{x}.{p*10+1}"
        LO[dev_sp(r,p,2)] = f"10.0.{x}.{p*10+2}"
        LO[dev_lf(r,p,1)] = f"10.0.{x}.{30+(p-1)*10+1}"
        LO[dev_lf(r,p,2)] = f"10.0.{x}.{30+(p-1)*10+2}"
    LO[dev_bd(r,1)] = f"10.0.{x}.51"; LO[dev_bd(r,2)] = f"10.0.{x}.52"
LO["wan1"] = "10.0.100.1"; LO["wan2"] = "10.0.100.2"

# ------------------------------------------------------------------ links
PAIRS = []
for r in REGIONS:
    for p in PODS:                                   # spines to super-spines
        for si in (1, 2):
            for ssi in (1, 2):
                PAIRS.append((dev_sp(r,p,si), dev_ss(r,ssi)))
    for p in PODS:                                   # leaves to their pod's spines
        for li in LEAVES:
            for si in (1, 2):
                PAIRS.append((dev_lf(r,p,li), dev_sp(r,p,si)))
    for bi in (1, 2):                                # borders to super-spines
        for ssi in (1, 2):
            PAIRS.append((dev_bd(r,bi), dev_ss(r,ssi)))
for r in REGIONS:                                    # borders to both carriers
    for bi in (1, 2):
        for w in sorted(WAN):
            PAIRS.append((dev_bd(r,bi), w))

LINK = []
for lid, (a, b) in enumerate(PAIRS, start=1):
    off = lid * 2
    net = f"10.254.{off//256}.{off%256}"
    LINK.append(dict(id=lid, a=a, b=b,
                     a4=f"{net}/31",
                     b4=f"10.254.{off//256}.{off%256+1}/31"))

IFACE = {d: {} for d in LO}
for d in LO:
    mine = []
    for l in LINK:
        if l["a"] == d:   mine.append((l["b"], l, "a"))
        elif l["b"] == d: mine.append((l["a"], l, "b"))
    mine.sort(key=lambda t: t[0])
    for n, (far, l, side) in enumerate(mine, start=1):
        IFACE[d][f"Ethernet{n}"] = dict(
            far=far, link=l["id"], v4=l[side+"4"],
            peer=l[("b" if side=="a" else "a")+"4"].split("/")[0])
        l.setdefault("if", {})[d] = f"Ethernet{n}"

def region_of(d): return None if d in WAN else d.split("-")[0]
def tier(d):
    if d in WAN: return "carrier"
    if "-ss" in d: return "superspine"
    if "-b" in d:  return "border"
    return "spine" if "-s" in d else "leaf"
def pod_of(d):
    return int(d.split("-")[1][1]) if tier(d) in ("spine","leaf") else None
def asn(d):
    if d in WAN: return WAN[d]
    r, t = region_of(d), tier(d)
    if t == "superspine": return ss_asn(r)
    if t == "border":     return bd_asn(r)
    p = pod_of(d); i = int(d[-1])
    return sp_asn(r,p) if t == "spine" else lf_asn(r,p,i)
def pod_loopbacks(r,p):
    return [LO[dev_sp(r,p,1)], LO[dev_sp(r,p,2)], LO[dev_lf(r,p,1)], LO[dev_lf(r,p,2)]]
def region_loopbacks(r):
    return [LO[d] for d in LO if region_of(d) == r]

BASE = """hostname {name}
!
service routing protocols model multi-agent
!
no aaa root
username admin privilege 15 role network-admin secret 0 admin
!
spanning-tree mode none
!
"""
def plist(name, entries):
    return "".join(f"ip prefix-list {name} seq {i*10} {e}\n"
                   for i, e in enumerate(entries, 1)) + "!\n"


def render(d):
    t, r, a = tier(d), region_of(d), asn(d)
    p = pod_of(d)
    role = {"superspine": f"super-spine, {REGIONS[r]['city']}" if r else "",
            "spine": f"spine, pod {p}, {REGIONS[r]['city']}" if r else "",
            "leaf": f"leaf, pod {p}, {REGIONS[r]['city']}" if r else "",
            "border": f"region border, {REGIONS[r]['city']}" if r else "",
            "carrier": "DCI carrier"}[t]
    s = (f"! {d} | bgp-lab18 | {role} | AS {a} | generated by tools/gen_configs.py\n")
    s += BASE.format(name=d)
    for ifn in sorted(IFACE[d], key=lambda x: int(x.replace("Ethernet",""))):
        i = IFACE[d][ifn]
        s += (f"interface {ifn}\n   description {tier(i['far']).upper()}_{i['far']}_link{i['link']}\n"
              f"   no switchport\n   mtu {MTU}\n   ip address {i['v4']}\n!\n")
    s += f"interface Loopback0\n   description ROUTER_ID\n   ip address {LO[d]}/32\n!\n"

    originate = [LO[d] + "/32"]
    if t == "leaf":
        nets = srv_nets(r, p, int(d[-1]))
        originate += nets
        for n, net in enumerate(nets, start=1):
            s += (f"interface Loopback{n}\n   description HOST_{net}\n"
                  f"   ip address {net.split('/')[0][:-1]}1/32\n!\n")
        if p == 1 and d.endswith("l1"):          # one anycast origin per region
            originate += [ANYCAST]
            s += (f"interface Loopback9\n   description ANYCAST_SERVICE\n"
                  f"   ip address 10.100.0.1/32\n!\n")
    if t == "spine":  originate += [srv_pod(r, p)]
    if t == "border": originate += [srv_region(r)]
    if t == "carrier":
        originate += [f"10.200.{list(WAN).index(d)}.0/24"]   # a carrier prefix

    s += "ip routing\n!\n"
    for n in originate:
        if not n.endswith("/32"):
            s += f"ip route {n} Null0 254\n"
    s += "!\n"

    # ---------------------------------------------------- outbound policy
    if t == "leaf":
        s += plist("PL-OWN", [f"permit {n}" for n in originate])
        s += ("route-map RM-LEAF-OUT permit 10\n"
              "   description a leaf announces its own space and nothing else\n"
              "   match ip address prefix-list PL-OWN\n!\n")
    elif t == "spine":
        s += plist("PL-POD-UP", [f"permit {srv_pod(r,p)}"] +
                                [f"permit {x}/32" for x in pod_loopbacks(r,p)] +
                                [f"permit {ANYCAST}"])
        s += ("route-map RM-SPINE-UP permit 10\n"
              "   description northbound: one aggregate per pod, pod loopbacks, anycast\n"
              "   match ip address prefix-list PL-POD-UP\n!\n")
        s += "route-map RM-SPINE-DOWN permit 10\n   description southbound: all we know\n!\n"
    elif t == "superspine":
        s += "route-map RM-SS-OUT permit 10\n   description the tier exists to carry pod to pod\n!\n"
    elif t == "border":
        # THE policy of this lab. A border announces the region aggregate and
        # the anycast prefix to the carriers, and nothing else -- above all,
        # nothing it learned FROM a carrier.
        s += plist("PL-REGION-OUT", [f"permit {srv_region(r)}", f"permit {ANYCAST}"])
        s += plist("PL-OUR-REGION", [f"permit {srv_region(r)} le 32"])
        s += ("route-map RM-WAN-OUT permit 10\n"
              "   description our region and anycast only, never what a carrier told us\n"
              "   match ip address prefix-list PL-REGION-OUT\n!\n")
        s += ("route-map RM-WAN-IN deny 5\n"
              "   description never accept our own region's space back from a carrier\n"
              "   match ip address prefix-list PL-OUR-REGION\n!\n"
              "route-map RM-WAN-IN permit 10\n"
              "   set local-preference 100\n!\n")
        s += "route-map RM-FABRIC-OUT permit 10\n   description southbound into the fabric\n!\n"
    else:
        s += "route-map RM-CARRIER-OUT permit 10\n   description a carrier carries\n!\n"

    # ---------------------------------------------------- BGP
    s += (f"router bgp {a}\n   router-id {LO[d]}\n   no bgp default ipv4-unicast\n"
          f"   distance bgp 20 200 200\n   maximum-paths 8 ecmp 8\n"
          f"   bgp log-neighbor-changes\n")
    groups = {}
    for ifn, i in IFACE[d].items():
        ft = tier(i["far"])
        base = {"superspine":"SUPERSPINE","spine":"SPINE","leaf":"LEAF",
                "border":"BORDER","carrier":"CARRIER"}[ft]
        fasn = asn(i["far"])
        groups.setdefault((f"{base}-{fasn}", fasn), []).append((i["peer"], i["far"]))
    for (g, fasn), members in sorted(groups.items()):
        if t == "leaf":        rout, rin = "RM-LEAF-OUT", None
        elif t == "spine":     rout, rin = ("RM-SPINE-UP" if g.startswith("SUPERSPINE")
                                            else "RM-SPINE-DOWN"), None
        elif t == "superspine":rout, rin = "RM-SS-OUT", None
        elif t == "border":    rout, rin = (("RM-WAN-OUT", "RM-WAN-IN") if g.startswith("CARRIER")
                                            else ("RM-FABRIC-OUT", None))
        else:                  rout, rin = "RM-CARRIER-OUT", None
        s += (f"   neighbor {g} peer group\n   neighbor {g} remote-as {fasn}\n"
              f"   neighbor {g} send-community\n"
              f"   neighbor {g} route-map {rout} out\n")
        if rin:
            s += f"   neighbor {g} route-map {rin} in\n"
        s += f"   neighbor {g} maximum-routes 12000\n"
        for ip, far in sorted(members):
            s += f"   neighbor {ip} peer group {g}\n   neighbor {ip} description {far}\n"
    s += "   !\n   address-family ipv4\n"
    for (g, _) in sorted(groups):
        s += f"      neighbor {g} activate\n"
    for n in originate:
        s += f"      network {n}\n"
    return s + "!\nend\n"


def topology():
    o = ["# bgp-lab18 | Three regions, two carriers, 38 nodes.",
         "# GENERATED by tools/gen_configs.py",
         "#",
         "#   Each region: 2 super-spines, 2 pods of (2 spines + 2 leaves), 2 borders.",
         "#   Both borders of every region face BOTH carriers, which are different ASes.",
         "#   That is what makes region transit possible, and policy the only control.",
         "name: bgp-lab18", "", "mgmt:", "  network: clab-bgp-lab18",
         "  ipv4-subnet: 172.31.118.0/24", "", "topology:", "  kinds:",
         "    arista_ceos:", "      image: ceos:4.36.0.1F", "", "  nodes:"]
    order = []
    for r in REGIONS:
        order += [dev_ss(r,1), dev_ss(r,2)]
        for p in PODS:
            order += [dev_sp(r,p,1), dev_sp(r,p,2), dev_lf(r,p,1), dev_lf(r,p,2)]
        order += [dev_bd(r,1), dev_bd(r,2)]
    order += sorted(WAN)
    for d in order:
        o.append(f"    {d+':':12s} {{kind: arista_ceos, startup-config: configs/active/{d}.cfg}}"
                 f"   # AS {asn(d)}, {tier(d)}")
    o += ["", "  links:"]
    for l in LINK:
        o += [f"    # link {l['id']}: {l['a']} <-> {l['b']}",
              "    - type: veth", "      endpoints:",
              f"        - node: {l['a']}",
              f"          interface: {l['if'][l['a']].replace('Ethernet','eth')}",
              f"        - node: {l['b']}",
              f"          interface: {l['if'][l['b']].replace('Ethernet','eth')}",
              f"      mtu: {MTU}"]
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for d in sorted(LO):
        open(os.path.join(OUT, f"{d}.cfg"), "w").write(render(d))
    print(f"  {len(LO)} configs, {len(LINK)} links")
    open(os.path.join(OUT, "..", "..", "bgp-lab18.clab.yml"), "w").write(topology())
    print("  bgp-lab18.clab.yml")
    # a bash-readable peer map, so lab.sh never hardcodes or guesses an address
    T = os.path.join(os.path.dirname(os.path.abspath(__file__)), "peers.sh")
    with open(T, "w") as fh:
        fh.write("# GENERATED by tools/gen_configs.py. PEER[device:far]=address\n")
        fh.write("declare -A PEER=(\n")
        for d in sorted(IFACE):
            for ifn, i in sorted(IFACE[d].items(), key=lambda kv: int(kv[0][8:])):
                fh.write(f'  [{d}:{i["far"]}]={i["peer"]}\n')
        fh.write(")\n")
        fh.write("declare -A IFOF=(\n")
        for d in sorted(IFACE):
            for ifn, i in sorted(IFACE[d].items(), key=lambda kv: int(kv[0][8:])):
                fh.write(f'  [{d}:{i["far"]}]={ifn}\n')
        fh.write(")\n")
    print("  tools/peers.sh")
