#!/usr/bin/env python3
"""bgp-lab19: multi-tenant EVPN across three regions, 38 nodes.

Three regions. Each is an OSPF underlay with an iBGP EVPN overlay reflected by
its super-spines. Three tenant VRFs on a hub-and-spoke route-target plan:

    PROD    exports 1:50001   imports 1:50001, 1:50003
    DEV     exports 1:50002   imports 1:50002, 1:50003
    SHARED  exports 1:50003   imports 1:50003, 1:50001, 1:50002

so PROD and DEV each reach SHARED and NEITHER reaches the other. That last
sentence is the invariant the whole lab is built to break and to prove.

EVPN stops at the region boundary. Tenants cross the WAN as per-VRF eBGP on
dot1q sub-interfaces to two carriers, which is what almost everyone actually
does: stretching EVPN across a WAN is a much bigger commitment than handing
off a VRF.

Design notes, stated because they differ from Labs 17 and 18 on purpose:
  * The underlay here is OSPF, not eBGP. Labs 17 and 18 covered the eBGP Clos
    and its ASN plan; this lab's subject is tenancy, and an OSPF underlay with
    an iBGP overlay removes the eBGP next-hop handling from the picture so the
    VRF dimension is the only hard thing.
  * Spines carry NO BGP at all. They are pure underlay transit. The overlay
    runs leaf-to-super-spine over loopbacks.
  * L3VNI only, no L2VNIs. Stretched layer 2 would add MAC learning and anycast
    gateways without adding anything to the tenancy question.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "configs", "solution")
MTU = 9214

# -------- size knobs. 38 nodes at the defaults; see README for the arithmetic.
PODS_PER_REGION = 2
LEAVES_PER_POD  = 2

REGIONS = {"wst": dict(idx=1, city="Seattle"),
           "est": dict(idx=2, city="Ashburn"),
           "eur": dict(idx=3, city="London")}
WAN = {"wan1": 65500, "wan2": 65600}

VRFS = {                      # name -> (l3vni, export RT, imports, dot1q, svi octet)
    "PROD":   dict(vni=50001, rt="1:50001", imports=["1:50001", "1:50003"], dot1q=101, oct=10),
    "DEV":    dict(vni=50002, rt="1:50002", imports=["1:50002", "1:50003"], dot1q=102, oct=20),
    "SHARED": dict(vni=50003, rt="1:50003",
                   imports=["1:50003", "1:50001", "1:50002"],              dot1q=103, oct=30),
}
VRF_ORDER = ["PROD", "DEV", "SHARED"]

def ov_asn(r):  return 65000 + REGIONS[r]["idx"]        # one overlay AS per region
def rx(r):      return REGIONS[r]["idx"]

def dev_ss(r,i):   return f"{r}-ss{i}"
def dev_sp(r,p,i): return f"{r}-p{p}-s{i}"
def dev_lf(r,p,i): return f"{r}-p{p}-l{i}"
def dev_bd(r,i):   return f"{r}-b{i}"

NODES, LO0, LO1 = [], {}, {}
LEAF_IDX = {}                              # device -> 1..N within its region
for r in REGIONS:
    x = rx(r); n = 0
    for i in (1, 2):
        d = dev_ss(r,i); NODES.append(d); LO0[d] = f"10.0.{x}.{i}"
    for p in range(1, PODS_PER_REGION+1):
        for i in (1, 2):
            d = dev_sp(r,p,i); NODES.append(d); LO0[d] = f"10.0.{x}.{10*p+i}"
        for i in range(1, LEAVES_PER_POD+1):
            d = dev_lf(r,p,i); NODES.append(d); n += 1
            LO0[d] = f"10.0.{x}.{30+(p-1)*10+i}"; LO1[d] = f"10.1.{x}.{n}"
            LEAF_IDX[d] = n
    for i in (1, 2):
        d = dev_bd(r,i); NODES.append(d); n += 1
        LO0[d] = f"10.0.{x}.{50+i}"; LO1[d] = f"10.1.{x}.{n}"
        LEAF_IDX[d] = n
for w in sorted(WAN):
    NODES.append(w); LO0[w] = f"10.0.100.{list(sorted(WAN)).index(w)+1}"

def region_of(d): return None if d in WAN else d.split("-")[0]
def tier(d):
    if d in WAN: return "carrier"
    if "-ss" in d: return "superspine"
    if "-b"  in d: return "border"
    return "spine" if "-s" in d else "leaf"
def pod_of(d): return int(d.split("-")[1][1]) if tier(d) in ("spine","leaf") else None
def is_vtep(d): return tier(d) in ("leaf", "border")

# tenant address per region: 10.{100+R}.{oct}.0/24 stretched, and a per-device
# /32 in {oct+1} that is the thing we actually ping
def vrf_subnet(r, v):  return f"10.{100+rx(r)}.{VRFS[v]['oct']}.0/24"
def vrf_host(r, v, d): return f"10.{100+rx(r)}.{VRFS[v]['oct']+1}.{LEAF_IDX[d]}"

# ------------------------------------------------------------------ links
PAIRS = []
for r in REGIONS:
    for p in range(1, PODS_PER_REGION+1):
        for si in (1,2):
            for ssi in (1,2): PAIRS.append((dev_sp(r,p,si), dev_ss(r,ssi)))
        for li in range(1, LEAVES_PER_POD+1):
            for si in (1,2): PAIRS.append((dev_lf(r,p,li), dev_sp(r,p,si)))
    for bi in (1,2):
        for ssi in (1,2): PAIRS.append((dev_bd(r,bi), dev_ss(r,ssi)))
for r in REGIONS:
    for bi in (1,2):
        for w in sorted(WAN): PAIRS.append((dev_bd(r,bi), w))

LINK = []
for lid,(a,b) in enumerate(PAIRS, start=1):
    off = lid*2
    LINK.append(dict(id=lid, a=a, b=b,
                     a4=f"10.254.{off//256}.{off%256}/31",
                     b4=f"10.254.{off//256}.{off%256+1}/31",
                     net=f"10.254.{off//256}.{off%256}/31"))

IFACE = {d: {} for d in LO0}
for d in LO0:
    mine = []
    for l in LINK:
        if l["a"] == d:   mine.append((l["b"], l, "a"))
        elif l["b"] == d: mine.append((l["a"], l, "b"))
    mine.sort(key=lambda t: t[0])
    for n,(far,l,side) in enumerate(mine, start=1):
        IFACE[d][f"Ethernet{n}"] = dict(far=far, link=l["id"], v4=l[side+"4"],
            net=l["net"], peer=l[("b" if side=="a" else "a")+"4"].split("/")[0])
        l.setdefault("if", {})[d] = f"Ethernet{n}"

# per-VRF WAN sub-interface addressing, deterministic
WANSUB = {}
k = 0
for r in REGIONS:
    for bi in (1,2):
        for w in sorted(WAN):
            for v in VRF_ORDER:
                off = k*2; k += 1
                WANSUB[(dev_bd(r,bi), w, v)] = (
                    f"10.253.{off//256}.{off%256}/31",
                    f"10.253.{off//256}.{off%256+1}/31")

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

def render(d):
    t, r = tier(d), region_of(d)
    where = f", {REGIONS[r]['city']}" if r else ""
    s = f"! {d} | bgp-lab19 | {t}{where} | generated by tools/gen_configs.py\n"
    s += BASE.format(name=d)

    if t != "carrier":
        for v in VRF_ORDER:
            s += f"vrf instance {v}\n!\n"

    for ifn in sorted(IFACE[d], key=lambda x: int(x[8:])):
        i = IFACE[d][ifn]
        if tier(i["far"]) == "carrier" or t == "carrier":
            s += (f"interface {ifn}\n   description WAN_{i['far']}_link{i['link']}\n"
                  f"   no switchport\n   mtu {MTU}\n!\n")
            for v in VRF_ORDER:
                key = (d, i["far"], v) if t != "carrier" else (i["far"], d, v)
                a4, b4 = WANSUB[key]
                mine = a4 if t != "carrier" else b4
                s += (f"interface {ifn}.{VRFS[v]['dot1q']}\n"
                      f"   description WAN_{v}_to_{i['far']}\n"
                      f"   encapsulation dot1q vlan {VRFS[v]['dot1q']}\n"
                      f"   vrf {v}\n   ip address {mine}\n!\n")
        else:
            s += (f"interface {ifn}\n   description {tier(i['far']).upper()}_{i['far']}_link{i['link']}\n"
                  f"   no switchport\n   mtu {MTU}\n   ip address {i['v4']}\n!\n")

    s += f"interface Loopback0\n   description ROUTER_ID\n   ip address {LO0[d]}/32\n!\n"
    if is_vtep(d):
        s += f"interface Loopback1\n   description VTEP\n   ip address {LO1[d]}/32\n!\n"
        for n, v in enumerate(VRF_ORDER, start=2):
            s += (f"interface Loopback{n}\n   description TENANT_HOST_{v}\n"
                  f"   vrf {v}\n   ip address {vrf_host(r,v,d)}/32\n!\n")

    s += "ip routing\n"
    if t != "carrier":
        for v in VRF_ORDER:
            s += f"ip routing vrf {v}\n"
    s += "!\n"

    # ------------------------------------------------ VXLAN, on VTEPs only
    if is_vtep(d):
        s += ("interface Vxlan1\n   description TENANT_ENCAP\n"
              f"   vxlan source-interface Loopback1\n   vxlan udp-port 4789\n")
        for v in VRF_ORDER:
            s += f"   vxlan vrf {v} vni {VRFS[v]['vni']}\n"
        s += "!\n"

    # ------------------------------------------------ OSPF underlay
    if t != "carrier":
        s += f"router ospf 1\n   router-id {LO0[d]}\n   network {LO0[d]}/32 area 0.0.0.0\n"
        if is_vtep(d):
            s += f"   network {LO1[d]}/32 area 0.0.0.0\n"
        for ifn in sorted(IFACE[d], key=lambda x: int(x[8:])):
            i = IFACE[d][ifn]
            if tier(i["far"]) != "carrier":
                s += f"   network {i['net']} area 0.0.0.0\n"
        s += "   max-lsa 12000\n!\n"

    # ------------------------------------------------ policy on VTEPs
    if is_vtep(d):
        s += (f"ip prefix-list PL-TENANT seq 10 permit 10.{100+rx(r)}.0.0/16 le 32\n!\n"
              "route-map RM-TENANT permit 10\n"
              "   description tenant space only: never the underlay or a WAN /31\n"
              "   match ip address prefix-list PL-TENANT\n!\n")
    if t == "border":
        s += ("route-map RM-WAN-OUT permit 10\n"
              "   description our region's tenant space only. Never what a carrier\n"
              "   match ip address prefix-list PL-TENANT\n!\n")

    # ------------------------------------------------ BGP
    if t == "spine":
        return s + "!\nend\n"          # spines are pure underlay transit

    if t == "carrier":
        asn = WAN[d]
        s += (f"router bgp {asn}\n   router-id {LO0[d]}\n   no bgp default ipv4-unicast\n"
              f"   maximum-paths 4 ecmp 4\n   bgp log-neighbor-changes\n")
        for v in VRF_ORDER:
            s += f"   !\n   vrf {v}\n"
            for ifn, i in sorted(IFACE[d].items(), key=lambda kv: int(kv[0][8:])):
                a4, b4 = WANSUB[(i["far"], d, v)]
                s += (f"      neighbor {a4.split('/')[0]} remote-as {ov_asn(region_of(i['far']))}\n"
                      f"      neighbor {a4.split('/')[0]} description {i['far']}_{v}\n"
                      f"      neighbor {a4.split('/')[0]} maximum-routes 12000\n")
            s += "      redistribute connected\n"
        return s + "!\nend\n"

    asn = ov_asn(r)
    s += (f"router bgp {asn}\n   router-id {LO0[d]}\n   no bgp default ipv4-unicast\n"
          f"   maximum-paths 4 ecmp 4\n   bgp log-neighbor-changes\n")
    if t == "superspine":
        s += "   neighbor OVERLAY peer group\n"
        s += f"   neighbor OVERLAY remote-as {asn}\n"
        s += "   neighbor OVERLAY update-source Loopback0\n"
        s += "   neighbor OVERLAY send-community extended\n"
        s += "   neighbor OVERLAY route-reflector-client\n"
        s += "   neighbor OVERLAY maximum-routes 12000\n"
        for c in sorted(LO1):
            if region_of(c) == r:
                s += f"   neighbor {LO0[c]} peer group OVERLAY\n   neighbor {LO0[c]} description {c}\n"
        s += "   !\n   address-family evpn\n      neighbor OVERLAY activate\n"
        return s + "!\nend\n"

    # leaf or border: overlay client
    s += "   neighbor OVERLAY peer group\n"
    s += f"   neighbor OVERLAY remote-as {asn}\n"
    s += "   neighbor OVERLAY update-source Loopback0\n"
    s += "   neighbor OVERLAY send-community extended\n"
    s += "   neighbor OVERLAY maximum-routes 12000\n"
    for i in (1, 2):
        ss = dev_ss(r, i)
        s += f"   neighbor {LO0[ss]} peer group OVERLAY\n   neighbor {LO0[ss]} description {ss}\n"
    s += "   !\n   address-family evpn\n      neighbor OVERLAY activate\n"
    for v in VRF_ORDER:
        m = VRFS[v]
        s += f"   !\n   vrf {v}\n      rd {LO1[d]}:{m['vni']}\n"
        for rt in m["imports"]:
            s += f"      route-target import evpn {rt}\n"
        s += f"      route-target export evpn {m['rt']}\n"
        s += "      redistribute connected route-map RM-TENANT\n"
        if t == "border":
            for ifn, i in sorted(IFACE[d].items(), key=lambda kv: int(kv[0][8:])):
                if tier(i["far"]) != "carrier":
                    continue
                a4, b4 = WANSUB[(d, i["far"], v)]
                nb = b4.split('/')[0]
                s += (f"      neighbor {nb} remote-as {WAN[i['far']]}\n"
                      f"      neighbor {nb} description {i['far']}_{v}\n"
                      f"      neighbor {nb} route-map RM-WAN-OUT out\n"
                      f"      neighbor {nb} maximum-routes 12000\n")
    return s + "!\nend\n"


def topology():
    o = ["# bgp-lab19 | Multi-tenant EVPN across three regions. GENERATED.",
         "#   OSPF underlay, iBGP EVPN overlay reflected by the super-spines,",
         "#   three tenant VRFs on a hub-and-spoke route-target plan, and a",
         "#   per-VRF eBGP handoff to two carriers on dot1q sub-interfaces.",
         "name: bgp-lab19", "", "mgmt:", "  network: clab-bgp-lab19",
         "  ipv4-subnet: 172.31.119.0/24", "", "topology:", "  kinds:",
         "    arista_ceos:", "      image: ceos:4.36.0.1F", "", "  nodes:"]
    for d in NODES:
        o.append(f"    {d+':':12s} {{kind: arista_ceos, startup-config: configs/active/{d}.cfg}}"
                 f"   # {tier(d)}")
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
    for d in NODES:
        open(os.path.join(OUT, f"{d}.cfg"), "w").write(render(d))
    print(f"  {len(NODES)} configs, {len(LINK)} links, {len(VRFS)} VRFs")
    open(os.path.join(OUT, "..", "..", "bgp-lab19.clab.yml"), "w").write(topology())
    # peer map for lab.sh
    T = os.path.join(os.path.dirname(os.path.abspath(__file__)), "peers.sh")
    with open(T, "w") as fh:
        fh.write("# GENERATED by tools/gen_configs.py\ndeclare -A PEER=(\n")
        for d in sorted(IFACE):
            for ifn, i in sorted(IFACE[d].items(), key=lambda kv: int(kv[0][8:])):
                fh.write(f'  [{d}:{i["far"]}]={i["peer"]}\n')
        fh.write(")\ndeclare -A VHOST=(\n")
        for d in sorted(LO1):
            for v in VRF_ORDER:
                fh.write(f'  [{d}:{v}]={vrf_host(region_of(d), v, d)}\n')
        fh.write(")\ndeclare -A LOOP1=(\n")
        for d in sorted(LO1):
            fh.write(f'  [{d}]={LO1[d]}\n')
        fh.write(")\n")
    print("  bgp-lab19.clab.yml, tools/peers.sh")
