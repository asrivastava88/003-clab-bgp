#!/usr/bin/env python3
"""bgp-lab15 config generator: a dual-stack carrier edge.

AS 65010 runs two border routers and buys two transits, peers with one network
in both address families and with another in IPv6 only, and sells transit to
one customer. Every external relationship is TWO BGP sessions, one per address
family, which is what most networks actually run and is precisely why the two
families drift apart.

Naming is a strict convention so that parity is machine-checkable:
every IPv4 construct FOO has an IPv6 twin named FOO6, and every IPv4
prefix-list PL-X has an IPv6 twin PL6-X. tools/parity.py relies on it.

Our space: 203.0.113.0/24 and 192.0.2.0/24 (RFC 5737) with 2001:db8:10::/48
and 2001:db8:11::/48 (RFC 3849 documentation space). Peer space: 100.64.0.0/10
(RFC 6598) and more 2001:db8. None of it is globally routed. Names are
fictional.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "configs", "solution")
US = 65010
T1, T2, P1, P2, CU = 65100, 65200, 65300, 65301, 65400

# local-pref, identical in both address families. That is the point.
LP = {"cust": 400, "peer": 200, "t1": 100, "t2": 90}
DRAIN_LP = 50          # inbound while a border is drained
DRAIN_PREPEND = 3      # outbound prepends while drained
GSHUT = "65535:0"      # RFC 8326 GRACEFUL_SHUTDOWN, as a raw well-known value

# /23s and /44s, so that a more-specific of our own space EXISTS and the
# "never accept our own space" guard has something to catch that the
# prefix-length bound would not catch on its own.
OUR4 = ["198.18.0.0/23", "198.18.2.0/23"]
OUR6 = ["2001:db8:10::/44", "2001:db8:20::/44"]
CUST4, CUST6 = "198.51.100.0/24", "2001:db8:40::/48"
# what each neighbour is registered to announce
REG = {
    T1: (["100.100.0.0/16", "100.200.0.0/16"], ["2001:db8:100::/48", "2001:db8:200::/48"]),
    T2: (["100.101.0.0/16", "100.200.0.0/16"], ["2001:db8:101::/48", "2001:db8:200::/48"]),
    P1: (["100.110.0.0/16"], ["2001:db8:110::/48"]),
    P2: ([], ["2001:db8:111::/48"]),          # IPv6 only, on purpose
    CU: ([CUST4], [CUST6]),
}
# transit1 announces a more-specific of OUR OWN space, in both families, so the
# "never accept our own space" guard has something real to catch.
# A /24 inside our /23 and a /48 inside our /44: both pass the DFZ length
# bound, so only the guard stops them.
LEAK4, LEAK6 = "198.18.1.0/24", "2001:db8:18::/48"

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

BOGON4 = ["deny 0.0.0.0/0", "deny 0.0.0.0/8 le 32", "deny 10.0.0.0/8 le 32",
          "deny 127.0.0.0/8 le 32", "deny 169.254.0.0/16 le 32",
          "deny 172.16.0.0/12 le 32", "deny 192.168.0.0/16 le 32",
          "deny 224.0.0.0/4 le 32", "deny 240.0.0.0/4 le 32",
          "permit 0.0.0.0/0 ge 8 le 24"]
# The IPv6 equivalent. Shorter, and the maximum length bound is 48 rather than
# 24 because that is the longest prefix generally accepted in the IPv6 DFZ.
BOGON6 = ["deny ::/0", "deny ::/128", "deny ::1/128", "deny fe80::/10 le 128",
          "deny fc00::/7 le 128", "deny ff00::/8 le 128",
          "deny 2001:db8:ffff::/48 le 128",
          "permit ::/0 ge 16 le 48"]

def iface(n, desc, v4, v6, mtu=1500):
    s = f"interface {n}\n   description {desc}\n   no switchport\n   mtu {mtu}\n"
    if v4:
        s += f"   ip address {v4}\n"
    if v6:
        s += f"   ipv6 enable\n   ipv6 address {v6}\n   ipv6 nd ra suppress all\n"
    return s + "!\n"

def lo(n, v4=None, v6=None, desc=""):
    s = f"interface Loopback{n}\n"
    if desc:
        s += f"   description {desc}\n"
    if v4:
        s += f"   ip address {v4}/32\n"
    if v6:
        s += f"   ipv6 address {v6}/128\n"
    return s + "!\n"

def pl4(name, entries):
    return "".join(f"ip prefix-list {name} seq {i*10} {e}\n"
                   for i, e in enumerate(entries, 1)) + "!\n"

def pl6(name, entries):
    return "".join(f"ipv6 prefix-list {name} seq {i*10} {e}\n"
                   for i, e in enumerate(entries, 1)) + "!\n"

def rm_in(name, afi, allow, lp, note):
    """Inbound: refuse our own space, then accept the registered set at lp."""
    m = "ip" if afi == 4 else "ipv6"
    guard = "PL-OUR-ANY" if afi == 4 else "PL6-OUR-ANY"
    return (f"route-map {name} deny 5\n"
            f"   description never accept our own space from anyone\n"
            f"   match {m} address prefix-list {guard}\n!\n"
            f"route-map {name} permit 10\n"
            f"   description {note}\n"
            f"   match {m} address prefix-list {allow}\n"
            f"   set local-preference {lp}\n!\n")

def rm_out(name, afi, ours, cust, prepend=0):
    """Outbound: our aggregates and our customer's prefixes, nothing else."""
    m = "ip" if afi == 4 else "ipv6"
    o = "PL-OUR" if afi == 4 else "PL6-OUR"
    c = "PL-CUST" if afi == 4 else "PL6-CUST"
    pre = f"   set as-path prepend {' '.join([str(US)]*prepend)}\n" if prepend else ""
    return (f"route-map {name} permit 10\n"
            f"   description our own aggregates\n"
            f"   match {m} address prefix-list {o}\n{pre}!\n"
            f"route-map {name} permit 20\n"
            f"   description our customer's prefixes, which we must announce\n"
            f"   match {m} address prefix-list {c}\n{pre}!\n")

def rm_drain_out(name, afi):
    """Pre-staged drain: de-prefer this border without withdrawing anything."""
    m = "ip" if afi == 4 else "ipv6"
    o = "PL-OUR" if afi == 4 else "PL6-OUR"
    c = "PL-CUST" if afi == 4 else "PL6-CUST"
    pre = " ".join([str(US)] * DRAIN_PREPEND)
    s = ""
    for seq, lst, d in ((10, o, "our own aggregates, de-preferred"),
                        (20, c, "our customer's prefixes, de-preferred")):
        s += (f"route-map {name} permit {seq}\n"
              f"   description {d}\n"
              f"   match {m} address prefix-list {lst}\n"
              f"   set as-path prepend {pre}\n"
              f"   set community {GSHUT} additive\n!\n")
    return s

def rm_drain_in(name, afi):
    m = "ip" if afi == 4 else "ipv6"
    b = "PL-BOGON" if afi == 4 else "PL6-BOGON"
    g = "PL-OUR-ANY" if afi == 4 else "PL6-OUR-ANY"
    return (f"route-map {name} deny 5\n"
            f"   match {m} address prefix-list {g}\n!\n"
            f"route-map {name} permit 10\n"
            f"   description drained: prefer the other border for everything\n"
            f"   match {m} address prefix-list {b}\n"
            f"   set local-preference {DRAIN_LP}\n!\n")

# ------------------------------------------------------------------ our edges
EDGE = {
  "edge1": dict(
    rid="10.255.0.1", lo6="2001:db8:ffff:ffff::1",
    ifs=[("Ethernet1","TRANSIT1_handoff","10.1.1.1/30","2001:db8:ffff:11::1/64"),
         ("Ethernet2","PNI_peer1","10.3.1.1/30","2001:db8:ffff:31::1/64"),
         ("Ethernet3","PEER2_ipv6_only",None,"2001:db8:ffff:41::1/64"),
         ("Ethernet4","CUSTOMER_cust1","10.5.1.1/30","2001:db8:ffff:51::1/64"),
         ("Ethernet5","INTERNAL_edge2","10.254.0.0/31","2001:db8:ffff:ff::1/64")],
    hosts=[(1,"198.18.0.1","2001:db8:10::1")],
    originate4=["198.18.0.0/23"], originate6=["2001:db8:10::/44"],
    peers=[("TRANSIT1", T1, "10.1.1.2", "2001:db8:ffff:11::2", "RM-T1-IN", "RM-EXT-OUT", 12000),
           ("PEER1",    P1, "10.3.1.2", "2001:db8:ffff:31::2", "RM-P1-IN", "RM-EXT-OUT", 500),
           ("PEER2",    P2, None,       "2001:db8:ffff:41::2", "RM-P2-IN", "RM-EXT-OUT", 500),
           ("CUST1",    CU, "10.5.1.2", "2001:db8:ffff:51::2", "RM-CU-IN", "RM-EXT-OUT", 500)],
    statics=[("10.255.0.2/32","10.254.0.1"),],
    statics6=[("2001:db8:ffff:ffff::2/128","2001:db8:ffff:ff::2")]),
  "edge2": dict(
    rid="10.255.0.2", lo6="2001:db8:ffff:ffff::2",
    ifs=[("Ethernet1","TRANSIT1_handoff","10.1.2.1/30","2001:db8:ffff:12::1/64"),
         ("Ethernet2","TRANSIT2_handoff","10.2.1.1/30","2001:db8:ffff:21::1/64"),
         ("Ethernet3","PNI_peer1","10.3.2.1/30","2001:db8:ffff:32::1/64"),
         ("Ethernet4","PEER2_ipv6_only",None,"2001:db8:ffff:42::1/64"),
         ("Ethernet5","INTERNAL_edge1","10.254.0.1/31","2001:db8:ffff:ff::2/64")],
    hosts=[(1,"198.18.2.1","2001:db8:20::1")],
    originate4=["198.18.2.0/23"], originate6=["2001:db8:20::/44"],
    peers=[("TRANSIT1", T1, "10.1.2.2", "2001:db8:ffff:12::2", "RM-T1-IN", "RM-EXT-OUT", 12000),
           ("TRANSIT2", T2, "10.2.1.2", "2001:db8:ffff:21::2", "RM-T2-IN", "RM-T2-OUT", 12000),
           ("PEER1",    P1, "10.3.2.2", "2001:db8:ffff:32::2", "RM-P1-IN", "RM-EXT-OUT", 500),
           ("PEER2",    P2, None,       "2001:db8:ffff:42::2", "RM-P2-IN", "RM-EXT-OUT", 500)],
    statics=[("10.255.0.1/32","10.254.0.0"),],
    statics6=[("2001:db8:ffff:ffff::1/128","2001:db8:ffff:ff::1")]),
}

def edge(name):
    d = EDGE[name]
    other = "edge2" if name == "edge1" else "edge1"
    o = EDGE[other]
    s = f"! {name} | bgp-lab15 | AS {US} dual-stack border | generated by tools/gen_configs.py\n"
    s += BASE.format(name=name)
    for n, desc, v4, v6 in d["ifs"]:
        s += iface(n, desc, v4, v6, mtu=9100 if "INTERNAL" in desc else 1500)
    s += lo(0, d["rid"], d["lo6"], "ROUTER_ID / iBGP SOURCE")
    for n, h4, h6 in d["hosts"]:
        s += lo(n, h4, h6, "SERVICE_HOST")
    s += "ip routing\nipv6 unicast-routing\n!\n"
    for p in d["originate4"]:
        s += f"ip route {p} Null0 254\n"
    for pfx, nh in d["statics"]:
        s += f"ip route {pfx} {nh}\n"
    for p in d["originate6"]:
        s += f"ipv6 route {p} Null0 254\n"
    for pfx, nh in d["statics6"]:
        s += f"ipv6 route {pfx} {nh}\n"
    s += "!\n"
    # ---- prefix lists, each v4 list with its v6 twin
    s += pl4("PL-OUR", [f"permit {p}" for p in OUR4])
    s += pl6("PL6-OUR", [f"permit {p}" for p in OUR6])
    s += pl4("PL-OUR-ANY", [f"permit {p} le 32" for p in OUR4])
    s += pl6("PL6-OUR-ANY", [f"permit {p} le 128" for p in OUR6])
    s += pl4("PL-CUST", [f"permit {CUST4}"])
    s += pl6("PL6-CUST", [f"permit {CUST6}"])
    s += pl4("PL-BOGON", BOGON4)
    s += pl6("PL6-BOGON", BOGON6)
    s += pl4("PL-REG-P1", [f"permit {p} le 24" for p in REG[P1][0]])
    s += pl6("PL6-REG-P1", [f"permit {p} le 48" for p in REG[P1][1]])
    s += pl6("PL6-REG-P2", [f"permit {p} le 48" for p in REG[P2][1]])
    s += pl4("PL-REG-CU", [f"permit {p} le 24" for p in REG[CU][0]])
    s += pl6("PL6-REG-CU", [f"permit {p} le 48" for p in REG[CU][1]])
    # ---- route maps, each v4 map with its v6 twin
    s += rm_in("RM-T1-IN", 4, "PL-BOGON", LP["t1"], "transit, full table")
    s += rm_in("RM-T1-IN6", 6, "PL6-BOGON", LP["t1"], "transit, full table")
    if name == "edge2":
        s += rm_in("RM-T2-IN", 4, "PL-BOGON", LP["t2"], "backup transit")
        s += rm_in("RM-T2-IN6", 6, "PL6-BOGON", LP["t2"], "backup transit")
    s += rm_in("RM-P1-IN", 4, "PL-REG-P1", LP["peer"], "settlement-free peer")
    s += rm_in("RM-P1-IN6", 6, "PL6-REG-P1", LP["peer"], "settlement-free peer")
    s += rm_in("RM-P2-IN6", 6, "PL6-REG-P2", LP["peer"], "IPv6-only peer")
    if name == "edge1":
        s += rm_in("RM-CU-IN", 4, "PL-REG-CU", LP["cust"], "our transit customer")
        s += rm_in("RM-CU-IN6", 6, "PL6-REG-CU", LP["cust"], "our transit customer")
    s += rm_out("RM-EXT-OUT", 4, OUR4, CUST4)
    s += rm_out("RM-EXT-OUT6", 6, OUR6, CUST6)
    if name == "edge2":
        s += rm_out("RM-T2-OUT", 4, OUR4, CUST4, prepend=2)
        s += rm_out("RM-T2-OUT6", 6, OUR6, CUST6, prepend=2)
    s += rm_drain_out("RM-DRAIN-OUT", 4)
    s += rm_drain_out("RM-DRAIN-OUT6", 6)
    s += rm_drain_in("RM-DRAIN-IN", 4)
    s += rm_drain_in("RM-DRAIN-IN6", 6)
    # ---- BGP. Two sessions per neighbour, one per address family.
    s += f"router bgp {US}\n   router-id {d['rid']}\n   no bgp default ipv4-unicast\n"
    s += "   distance bgp 20 200 200\n   maximum-paths 2 ecmp 2\n   bgp log-neighbor-changes\n"
    s += f"   neighbor {o['rid']} remote-as {US}\n"
    s += f"   neighbor {o['rid']} description {other}_ibgp_v4\n"
    s += f"   neighbor {o['rid']} update-source Loopback0\n"
    s += f"   neighbor {o['rid']} next-hop-self\n"
    s += f"   neighbor {o['rid']} send-community\n"
    s += f"   neighbor {o['rid']} maximum-routes 12000\n"
    s += f"   neighbor {o['lo6']} remote-as {US}\n"
    s += f"   neighbor {o['lo6']} description {other}_ibgp_v6\n"
    s += f"   neighbor {o['lo6']} update-source Loopback0\n"
    s += f"   neighbor {o['lo6']} send-community\n"
    s += f"   neighbor {o['lo6']} maximum-routes 12000\n"
    for grp, asn, n4, n6, rin, rout, maxr in d["peers"]:
        if n4:
            s += f"   neighbor {n4} remote-as {asn}\n   neighbor {n4} description {grp.lower()}_v4\n"
            s += f"   neighbor {n4} send-community\n   neighbor {n4} maximum-routes {maxr}\n"
        s += f"   neighbor {n6} remote-as {asn}\n   neighbor {n6} description {grp.lower()}_v6\n"
        s += f"   neighbor {n6} send-community\n   neighbor {n6} maximum-routes {maxr}\n"
    s += "   !\n   address-family ipv4\n"
    s += f"      neighbor {o['rid']} activate\n"
    for grp, asn, n4, n6, rin, rout, maxr in d["peers"]:
        if not n4:
            continue
        s += f"      neighbor {n4} activate\n"
        s += f"      neighbor {n4} route-map {rin} in\n"
        s += f"      neighbor {n4} route-map {rout} out\n"
    for p in d["originate4"]:
        s += f"      network {p}\n"
    s += "   !\n   address-family ipv6\n"
    s += f"      neighbor {o['lo6']} activate\n"
    s += f"      neighbor {o['lo6']} next-hop-self\n"
    for grp, asn, n4, n6, rin, rout, maxr in d["peers"]:
        rin6 = rin + "6"
        rout6 = rout + "6"
        s += f"      neighbor {n6} activate\n"
        s += f"      neighbor {n6} route-map {rin6} in\n"
        s += f"      neighbor {n6} route-map {rout6} out\n"
    for p in d["originate6"]:
        s += f"      network {p}\n"
    return s + "!\nend\n"

# ------------------------------------------------------------------ externals
def external(name, role, asn, rid, lo6, ifs, p4, p6, hosts, sessions,
             leak4=None, leak6=None):
    s = f"! {name} | bgp-lab15 | {role} | generated by tools/gen_configs.py\n"
    s += BASE.format(name=name)
    for n, desc, v4, v6 in ifs:
        s += iface(n, desc, v4, v6)
    s += lo(0, rid, lo6, "ROUTER_ID")
    for n, h4, h6 in hosts:
        s += lo(n, h4, h6, "SERVICE_HOST")
    s += "ip routing\nipv6 unicast-routing\n!\n"
    for p in (p4 or []) + ([leak4] if leak4 else []):
        s += f"ip route {p} Null0 254\n"
    for p in (p6 or []) + ([leak6] if leak6 else []):
        s += f"ipv6 route {p} Null0 254\n"
    s += "!\n"
    own4 = (p4 or []) + ([leak4] if leak4 else [])
    own6 = (p6 or []) + ([leak6] if leak6 else [])
    if own4:
        s += pl4("PL-OWN", [f"permit {p} le 25" for p in own4])
    s += pl6("PL6-OWN", [f"permit {p} le 49" for p in own6])
    if own4:
        s += "route-map RM-OWN-ONLY permit 10\n   match ip address prefix-list PL-OWN\n!\n"
    s += "route-map RM-OWN-ONLY6 permit 10\n   match ipv6 address prefix-list PL6-OWN\n!\n"
    s += f"router bgp {asn}\n   router-id {rid}\n   no bgp default ipv4-unicast\n"
    s += "   maximum-paths 2 ecmp 2\n   bgp log-neighbor-changes\n"
    for n4, n6, pasn, desc in sessions:
        if n4:
            s += f"   neighbor {n4} remote-as {pasn}\n   neighbor {n4} description {desc}_v4\n"
            s += f"   neighbor {n4} send-community\n   neighbor {n4} maximum-routes 12000\n"
        s += f"   neighbor {n6} remote-as {pasn}\n   neighbor {n6} description {desc}_v6\n"
        s += f"   neighbor {n6} send-community\n   neighbor {n6} maximum-routes 12000\n"
    if own4:
        s += "   !\n   address-family ipv4\n"
        for n4, n6, pasn, desc in sessions:
            if n4:
                s += f"      neighbor {n4} activate\n      neighbor {n4} route-map RM-OWN-ONLY out\n"
        for p in own4:
            s += f"      network {p}\n"
    s += "   !\n   address-family ipv6\n"
    for n4, n6, pasn, desc in sessions:
        s += f"      neighbor {n6} activate\n      neighbor {n6} route-map RM-OWN-ONLY6 out\n"
    for p in own6:
        s += f"      network {p}\n"
    return s + "!\nend\n"

def build():
    c = {n: edge(n) for n in EDGE}
    c["transit1"] = external(
        "transit1", f"AS {T1} PACRIM, primary transit, dual stack", T1,
        "10.255.1.1", "2001:db8:ffff:ffff::101",
        [("Ethernet1","to_edge1","10.1.1.2/30","2001:db8:ffff:11::2/64"),
         ("Ethernet2","to_edge2","10.1.2.2/30","2001:db8:ffff:12::2/64")],
        REG[T1][0], REG[T1][1],
        [(1,"100.100.0.1","2001:db8:100::1"),(2,"100.200.0.1","2001:db8:200::1")],
        [("10.1.1.1","2001:db8:ffff:11::1",US,"edge1"),
         ("10.1.2.1","2001:db8:ffff:12::1",US,"edge2")],
        leak4=LEAK4, leak6=LEAK6)
    c["transit2"] = external(
        "transit2", f"AS {T2} MERIDIAN, backup transit, dual stack", T2,
        "10.255.2.1", "2001:db8:ffff:ffff::201",
        [("Ethernet1","to_edge2","10.2.1.2/30","2001:db8:ffff:21::2/64")],
        REG[T2][0], REG[T2][1],
        [(1,"100.101.0.1","2001:db8:101::1")],
        [("10.2.1.1","2001:db8:ffff:21::1",US,"edge2")])
    c["peer1"] = external(
        "peer1", f"AS {P1} CASCADE, settlement-free peer, dual stack", P1,
        "10.255.3.1", "2001:db8:ffff:ffff::301",
        [("Ethernet1","PNI_edge1","10.3.1.2/30","2001:db8:ffff:31::2/64"),
         ("Ethernet2","PNI_edge2","10.3.2.2/30","2001:db8:ffff:32::2/64")],
        REG[P1][0], REG[P1][1],
        [(1,"100.110.0.1","2001:db8:110::1")],
        [("10.3.1.1","2001:db8:ffff:31::1",US,"edge1"),
         ("10.3.2.1","2001:db8:ffff:32::1",US,"edge2")])
    c["peer2"] = external(
        "peer2", f"AS {P2} EVERGREEN, IPv6-only peer", P2,
        "10.255.3.2", "2001:db8:ffff:ffff::311",
        [("Ethernet1","PEER_edge1",None,"2001:db8:ffff:41::2/64"),
         ("Ethernet2","PEER_edge2",None,"2001:db8:ffff:42::2/64")],
        [], REG[P2][1],
        [(1,None,"2001:db8:111::1")],
        [(None,"2001:db8:ffff:41::1",US,"edge1"),
         (None,"2001:db8:ffff:42::1",US,"edge2")])
    c["cust1"] = external(
        "cust1", f"AS {CU} NORTHFIELD, our transit customer, dual stack", CU,
        "10.255.4.1", "2001:db8:ffff:ffff::401",
        [("Ethernet1","uplink_edge1","10.5.1.2/30","2001:db8:ffff:51::2/64")],
        REG[CU][0], REG[CU][1],
        [(1,"198.51.100.1","2001:db8:40::1")],
        [("10.5.1.1","2001:db8:ffff:51::1",US,"edge1")])
    return c

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, text in build().items():
        open(os.path.join(OUT, f"{name}.cfg"), "w").write(text)
        print(f"  {name}.cfg  {len(text.splitlines())} lines")
