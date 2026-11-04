#!/usr/bin/env python3
"""
bgp-lab10 config renderer (stdlib only).

BGP security at an internet edge. Every external neighbour in this lab
misbehaves in a different way, on purpose:

  transit  leaks RFC1918 at you alongside its legitimate space
  peer1    leaks RFC1918 at you
  cust1    behaves perfectly, and is the control
  cust2    hijacks YOUR address space, announces bogons, announces
           unregistered more-specifics, and re-announces back to you
           everything you give it

Your edge is supposed to survive all of that without you noticing. The
defences are layered so that each one is independently load-bearing:

  deny bogons        on every eBGP ingress, no exceptions
  deny our own space on every eBGP ingress (nobody outside originates it)
  registered prefix  on customer ingress only (peers and transits announce
                     cones you cannot enumerate)
  maximum-routes     the backstop for everything the filters miss
  egress default-deny so a mistake inbound does not become a leak outbound

Modes:
  base      sessions up, no policy at all. Every bogon, hijack and leak
            lands in your table and goes straight back out.
  solution  the full layered edge.
"""
from pathlib import Path

# ============================ DATA ============================
OUR_ASN = 65100
OUR_SPACE = "203.0.0.0/16"

C_TRANSIT, C_PEER, C_CUSTOMER = f"{OUR_ASN}:100", f"{OUR_ASN}:150", f"{OUR_ASN}:200"
LP = {"transit": 100, "peer": 150, "customer": 200}

# Deliberately not RFC1918-adjacent, so the bogon filter is unambiguous
# about what is ours, theirs and junk.
BOGONS = [
    ("0.0.0.0/8", "this network"),
    ("10.0.0.0/8", "RFC1918"),
    ("100.64.0.0/10", "CGNAT"),
    ("127.0.0.0/8", "loopback"),
    ("169.254.0.0/16", "link local"),
    ("172.16.0.0/12", "RFC1918"),
    ("192.0.2.0/24", "TEST-NET-1"),
    ("192.168.0.0/16", "RFC1918"),
    ("224.0.0.0/4", "multicast"),
    ("240.0.0.0/4", "reserved"),
]

INTERNAL = {
    "core":  {"lo0": "10.0.0.1",
              # originates our public space as two /20s plus the host subnet
              "originate": {1: "203.0.16.1/20", 2: "203.0.32.1/20"},
              "host": (3, "203.0.48.1/24", "h1"),
              "igp": {1: ("edge1", "10.0.255.0/31", 10),
                      2: ("edge2", "10.0.255.2/31", 10)},
              "ext": {}},
    "edge1": {"lo0": "10.0.0.2", "originate": {}, "host": None,
              "igp": {1: ("core",  "10.0.255.1/31", 10),
                      2: ("edge2", "10.0.255.4/31", 100)},
              "ext": {3: ("transit", 65200, "208.0.1.1/30", "208.0.1.2", "transit"),
                      4: ("peer1",   65400, "208.0.2.1/30", "208.0.2.2", "peer")}},
    "edge2": {"lo0": "10.0.0.3", "originate": {}, "host": None,
              "igp": {1: ("core",  "10.0.255.3/31", 10),
                      2: ("edge1", "10.0.255.5/31", 100)},
              "ext": {3: ("cust1", 65500, "208.0.3.1/30", "208.0.3.2", "customer"),
                      4: ("cust2", 65501, "208.0.4.1/30", "208.0.4.2", "customer")}},
}

# registered space per customer: the ONLY thing we will accept from them
CUST_REGISTERED = {"cust1": "206.0.0.0/16", "cust2": "207.0.0.0/16"}

EXTERNAL = {
    "transit": {"asn": 65200, "lo0": "10.255.1.1", "role": "transit", "default_originate": True,
                "link": ("edge1", "208.0.1.2/30", "208.0.1.1"),
                "originate": {1: "204.0.0.1/16"},
                # leaks RFC1918 at us alongside its real space
                "junk": {2: "10.1.1.1/8"}},
    "peer1":   {"asn": 65400, "lo0": "10.255.2.1", "role": "peer", "default_originate": False,
                "link": ("edge1", "208.0.2.2/30", "208.0.2.1"),
                "originate": {1: "205.0.0.1/16"},
                "junk": {2: "192.168.50.1/24"}},
    "cust1":   {"asn": 65500, "lo0": "10.255.3.1", "role": "customer", "default_originate": False,
                "link": ("edge2", "208.0.3.2/30", "208.0.3.1"),
                "originate": {1: "206.0.0.1/16"},
                "junk": {}},
    "cust2":   {"asn": 65501, "lo0": "10.255.4.1", "role": "customer", "default_originate": False,
                "link": ("edge2", "208.0.4.2/30", "208.0.4.1"),
                # its registered /16 plus two more-specifics inside it
                "originate": {1: "207.0.0.1/16", 2: "207.0.1.1/24", 3: "207.0.2.1/24"},
                # a hijack of OUR space, and two bogons
                "junk": {4: "203.0.0.1/16", 5: "192.168.100.1/24", 6: "169.254.1.1/24"},
                # one prefix inside its registered space, announced with OUR
                # ASN already in the path. Clean edges drop it on AS-loop
                # detection; an edge with allowas-in accepts it. Nothing else
                # in the policy touches it, so it isolates that one fault.
                "loop_prefix": ("207.0.9.0/24", 7, "207.0.9.1/24")},
}
# ==============================================================


def header(host, mode):
    return f"""! {host} | bgp-lab10 | {mode} | generated by tools/gen_configs.py
hostname {host}
!
service routing protocols model multi-agent
!
no aaa root
username admin privilege 15 role network-admin secret 0 admin
!
spanning-tree mode none
!
"""


def net_of(ip):
    """'203.0.16.1/20' -> '203.0.16.0/20' ; '10.1.1.1/8' -> '10.0.0.0/8'"""
    addr, length = ip.split("/")
    o = [int(x) for x in addr.split(".")]
    bits = int(length)
    mask = [(0xFFFFFFFF << (32 - bits) >> s) & 0xFF for s in (24, 16, 8, 0)]
    return ".".join(str(o[i] & mask[i]) for i in range(4)) + f"/{length}"


def bogon_list():
    c = ""
    for i, (p, why) in enumerate(BOGONS, start=1):
        c += f"ip prefix-list PL-BOGONS seq {i * 10} permit {p} le 32   ! {why}\n"
    return c + "!\n"


def edge_policy():
    """Layered. Each clause is load-bearing on its own, which is why every
    fault in this lab removes exactly one of them."""
    c = bogon_list()
    c += f"ip prefix-list PL-OURS seq 10 permit {OUR_SPACE}\n!\n"
    c += "ip prefix-list PL-DEFAULT seq 10 permit 0.0.0.0/0\n!\n"
    for cust, pfx in CUST_REGISTERED.items():
        c += f"ip prefix-list PL-{cust.upper()} seq 10 permit {pfx} le 24\n!\n"
    c += f"""ip community-list CL-TRANSIT permit {C_TRANSIT}
ip community-list CL-PEER permit {C_PEER}
ip community-list CL-CUSTOMER permit {C_CUSTOMER}
!
"""
    # ---- ingress, one map per neighbour class ----
    for cls, lp, comm in (("TRANSIT", LP["transit"], C_TRANSIT),
                          ("PEER", LP["peer"], C_PEER)):
        c += f"""route-map RM-FROM-{cls} deny 5
   description nobody outside should be sending us these
   match ip address prefix-list PL-BOGONS
!
route-map RM-FROM-{cls} deny 6
   description nobody outside originates our own space
   match ip address prefix-list PL-OURS
!
route-map RM-FROM-{cls} permit 10
   set local-preference {lp}
   set community {comm} additive
!
"""
    for cust in CUST_REGISTERED:
        u = cust.upper()
        c += f"""route-map RM-FROM-{u} deny 5
   match ip address prefix-list PL-BOGONS
!
route-map RM-FROM-{u} deny 6
   match ip address prefix-list PL-OURS
!
route-map RM-FROM-{u} permit 10
   description a customer gets to announce exactly what they registered
   match ip address prefix-list PL-{u}
   set local-preference {LP['customer']}
   set community {C_CUSTOMER} additive
!
"""
    # ---- egress, default deny ----
    for cls in ("TRANSIT", "PEER"):
        c += f"""route-map RM-TO-{cls} permit 10
   match ip address prefix-list PL-OURS
!
route-map RM-TO-{cls} permit 20
   match community CL-CUSTOMER
!
"""
    c += """route-map RM-TO-CUSTOMER permit 10
   description a default is all they contracted for
   match ip address prefix-list PL-DEFAULT
!
"""
    return c


MAXROUTES = {"transit": 5000, "peer": 2000, "customer": 100}


def internal(name, d, mode):
    c = header(name, mode)
    for port, (peer, ip, cost) in sorted(d["igp"].items()):
        c += (f"interface Ethernet{port}\n   description IGP_{peer}\n"
              f"   no switchport\n   mtu 9214\n   ip address {ip}\n"
              f"   ip ospf network point-to-point\n   ip ospf cost {cost}\n!\n")
    for port, (peer, asn, ip, _, role) in sorted(d["ext"].items()):
        c += (f"interface Ethernet{port}\n   description EBGP_{peer}_AS{asn}_{role}\n"
              f"   no switchport\n   ip address {ip}\n!\n")
    if d["host"]:
        port, ip, h = d["host"]
        c += (f"interface Ethernet{port}\n   description HOST_{h}\n"
              f"   no switchport\n   ip address {ip}\n!\n")
    c += f"interface Loopback0\n   description ROUTER_ID_AND_IBGP\n   ip address {d['lo0']}/32\n!\n"
    for n, ip in sorted(d["originate"].items()):
        c += f"interface Loopback{n}\n   description ORIGINATES_{net_of(ip)}\n   ip address {ip}\n!\n"
    c += "ip routing\n!\n"
    c += f"router ospf 1\n   router-id {d['lo0']}\n   passive-interface default\n"
    for port in sorted(d["igp"]):
        c += f"   no passive-interface Ethernet{port}\n"
    c += ("   network 10.0.0.0/22 area 0.0.0.0\n"
          "   network 10.0.255.0/24 area 0.0.0.0\n"
          "   network 203.0.48.0/24 area 0.0.0.0\n   max-lsa 12000\n!\n")
    if mode == "solution" and d["ext"]:
        c += edge_policy()

    c += f"""router bgp {OUR_ASN}
   router-id {d['lo0']}
   no bgp default ipv4-unicast
   maximum-paths 4 ecmp 4
   distance bgp 20 200 200
   neighbor IBGP peer group
   neighbor IBGP remote-as {OUR_ASN}
   neighbor IBGP update-source Loopback0
   neighbor IBGP send-community
   neighbor IBGP maximum-routes 12000
"""
    if d["ext"]:
        c += "   neighbor IBGP next-hop-self\n"
    for other, od in INTERNAL.items():
        if other != name:
            c += (f"   neighbor {od['lo0']} peer group IBGP\n"
                  f"   neighbor {od['lo0']} description {other}\n")
    for port, (peer, asn, _, peer_ip, role) in sorted(d["ext"].items()):
        c += (f"   neighbor {peer_ip} remote-as {asn}\n"
              f"   neighbor {peer_ip} description {peer}-{role}\n"
              f"   neighbor {peer_ip} send-community\n")
        if mode == "solution":
            rm_in = f"RM-FROM-{peer.upper()}" if role == "customer" else f"RM-FROM-{role.upper()}"
            rm_out = "RM-TO-CUSTOMER" if role == "customer" else f"RM-TO-{role.upper()}"
            c += (f"   neighbor {peer_ip} route-map {rm_in} in\n"
                  f"   neighbor {peer_ip} route-map {rm_out} out\n"
                  f"   neighbor {peer_ip} maximum-routes {MAXROUTES[role]}\n")
        else:
            c += f"   neighbor {peer_ip} maximum-routes 12000\n"
    for n, ip in sorted(d["originate"].items()):
        c += f"   network {net_of(ip)}\n"
    if d["host"]:
        c += f"   network {net_of(d['host'][1])}\n"
    c += "   !\n   address-family ipv4\n      neighbor IBGP activate\n"
    for _, (_, _, _, peer_ip, _) in sorted(d["ext"].items()):
        c += f"      neighbor {peer_ip} activate\n"
    return c + "!\nend\n"


def external(name, d):
    """Someone else's network. Permissive, and identical in both modes.
    The junk each one announces is the lab's input, not a fault."""
    peer_name, my_ip, peer_ip = d["link"]
    c = header(name, "external")
    c += (f"interface Ethernet1\n   description EBGP_{peer_name}_AS{OUR_ASN}\n"
          f"   no switchport\n   ip address {my_ip}\n!\n")
    lo0 = d["lo0"]
    c += f"interface Loopback0\n   description ROUTER_ID\n   ip address {lo0}/32\n!\n"
    for n, ip in sorted(d["originate"].items()):
        c += f"interface Loopback{n}\n   description ORIGINATES_{net_of(ip)}\n   ip address {ip}\n!\n"
    for n, ip in sorted(d["junk"].items()):
        c += (f"interface Loopback{n}\n   description ANNOUNCES_{net_of(ip)}_ON_PURPOSE\n"
              f"   ip address {ip}\n!\n")
    lp = d.get("loop_prefix")
    if lp:
        pfx, n, ip = lp
        c += (f"interface Loopback{n}\n   description ANNOUNCED_WITH_AS{OUR_ASN}_IN_PATH\n"
              f"   ip address {ip}\n!\n"
              f"ip prefix-list PL-LOOPED seq 10 permit {pfx}\n!\n"
              f"route-map RM-OUT permit 10\n"
              f"   description make this one look like it has transited AS {OUR_ASN}\n"
              f"   match ip address prefix-list PL-LOOPED\n"
              f"   set as-path prepend {OUR_ASN}\n!\n"
              f"route-map RM-OUT permit 20\n!\n")
    c += f"ip routing\n!\nrouter bgp {d['asn']}\n   router-id {lo0}\n   no bgp default ipv4-unicast\n"
    c += f"""   maximum-paths 4 ecmp 4
   neighbor {peer_ip} remote-as {OUR_ASN}
   neighbor {peer_ip} description {peer_name}
   neighbor {peer_ip} send-community
   neighbor {peer_ip} maximum-routes 12000
"""
    if d["default_originate"]:
        c += f"   neighbor {peer_ip} default-originate\n"
    if d.get("loop_prefix"):
        c += f"   neighbor {peer_ip} route-map RM-OUT out\n"
    for n, ip in sorted({**d["originate"], **d["junk"]}.items()):
        c += f"   network {net_of(ip)}\n"
    if d.get("loop_prefix"):
        c += f"   network {d['loop_prefix'][0]}\n"
    c += "   !\n   address-family ipv4\n      neighbor " + peer_ip + " activate\n"
    return c + "!\nend\n"


def host(name, ip, gw):
    c = header(name, "endpoint")
    c += (f"interface Ethernet1\n   description UPLINK\n   no switchport\n"
          f"   ip address {ip}\n!\nip routing\n!\nip route 0.0.0.0/0 {gw}\n!\nend\n")
    return c


def main():
    root = Path(__file__).resolve().parent.parent
    for mode in ("base", "solution"):
        out = root / "configs" / mode
        out.mkdir(parents=True, exist_ok=True)
        for n, d in INTERNAL.items():
            (out / f"{n}.cfg").write_text(internal(n, d, mode))
        for n, d in EXTERNAL.items():
            (out / f"{n}.cfg").write_text(external(n, d))
        (out / "h1.cfg").write_text(host("h1", "203.0.48.101/24", "203.0.48.1"))
    print("rendered configs/{base,solution}")


if __name__ == "__main__":
    main()
