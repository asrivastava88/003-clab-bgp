# BGP Lab 02: Dual-Border, Dual-ISP Internet Edge for a Multi-Tenant EVPN Fabric

**Level:** CCIE EI/DC | **Stack:** containerlab 0.79.0, cEOS 4.36.0.1F, SONiC-VS 202511, network-multitool

Lab 01 built the fabric. Lab 02 is about the edge: two border leaves, two ISPs, two tenant VRFs, and a business policy that says RED lives on ISP-A and BLUE lives on ISP-B, each backing up the other. You will learn why local-preference stops at your border, why AS-path prepend does not move your own provider, when MED actually counts, how to drive policy with communities across an EVPN fabric, how to trigger RTBH, and why BFD matters for grey failures.

## Topology

```
                         +-------------------------+
                         |   inet   SONiC / FRR    |  AS 65000
                         |   203.0.113.10 (lo)     |
                         +-------------------------+
                          Ethernet0          Ethernet4
                              |                  |
                     +----------------+  +----------------+
                     | ispA  AS 65010 |  | ispB  AS 65020 |
                     | 192.0.2.1      |  | 198.51.100.1   |
                     +----------------+  +----------------+
                        E1        E2        E1        E2
                         |          \      /          |
                         |           \    /           |     every WAN link is 802.1Q:
                         |            \  /            |       .101 = VRF RED
                         |             \/             |       .102 = VRF BLUE
                         |             /\             |
                        E3     E4 ____/  \____ E3    E4
                     +----------------+  +----------------+
                     | bleaf1  65104  |  | bleaf2  65104  |
                     +----------------+  +----------------+
                               \              /
                         spine1, spine2  (AS 65100)
                               /              \
                     +----------------+  +----------------+
                     | leaf1   65101  |  | leaf2   65102  |
                     +----------------+  +----------------+
                        E3       E4         E3       E4
                        h1       h3         h2       h4
                     RED v10  BLUE v30   RED v20  BLUE v30
```

Cabling: bleaf1 E3 to ispA E1, bleaf1 E4 to ispB E1, bleaf2 E3 to ispA E2, bleaf2 E4 to ispB E2. Every leaf E1 to spine1, E2 to spine2.

## Addressing

| Item | Value |
|---|---|
| Fabric | as Lab 01: spines 65100, Lo0 10.0.0.x, Lo1 (VTEP) 10.0.1.x, P2P 10.1.*spine*.x/31 |
| Leaves | leaf1 65101 (.11), leaf2 65102 (.12), bleaf1 65104 (.14), bleaf2 65104 (.15) |
| WAN /30s | `172.16.<isp><border>.<0 RED / 4 BLUE>/30`, border .1/.5, ISP .2/.6 (ispA=1, ispB=2) |
| Example | bleaf2 to ispB, BLUE: 172.16.22.5 to 172.16.22.6 |
| Upstream | ispA 100.64.1.1 to inet .2, ispB 100.64.2.1 to inet .2 |

| VLAN | VRF | Subnet | L2VNI | Hosts |
|---|---|---|---|---|
| 10 RED_WEB | RED (L3VNI 50001) | 10.10.10.0/24 | 10010 | h1 .101 (leaf1) |
| 20 RED_DB | RED | 10.10.20.0/24 | 10020 | h2 .102 (leaf2) |
| 30 BLUE_APP | BLUE (L3VNI 50002) | 10.30.30.0/24 | 10030 | h3 .103 (leaf1), h4 .104 (leaf2) |

Test targets: `203.0.113.10` (Internet), `192.0.2.1` (ispA's other customer), `198.51.100.1` (ispB's other customer).
Provider policies (communities, RTBH, limits): `docs/ISP-GUIDE.md`.

## Modes

| Mode | What is configured | Use |
|---|---|---|
| `base` | Fabric, EVPN, VRFs, WAN subinterfaces addressed. No WAN BGP. | Part A: build the edge |
| `solution` | Edge baseline: per-VRF eBGP to both ISPs, filtering, no TE | Part B: engineer traffic |
| `te` | Production reference: all TE, communities, MED, RTBH armed, BFD | Part C: tickets |

ISPs and inet are identical in every mode. Treat them as someone else's network: read, never change (except where a task says so).

## Quick start

```bash
chmod +x lab.sh
./lab.sh deploy base | solution | te
./lab.sh verify                 # fabric, edge, and (te) 10 policy assertions
./lab.sh break random           # te only; ./lab.sh reveal; ./lab.sh restore
./lab.sh grey on|off            # grey failure on ispA -> bleaf1
./lab.sh cli bleaf1             # Cli | inet -> vtysh | h1..h4 -> sh
./lab.sh destroy
```

RAM: 8 cEOS + 1 SONiC-VS, roughly 12 to 14 GB. Boot plus convergence takes 3 to 5 minutes.

## Files

```
bgp-lab02.clab.yml     topology
lab.sh                 deploy | verify | break | restore | grey | cli
configs/{base,solution,te}/  rendered configs (ISPs included)
tools/gen_configs.py   one data model -> all modes; TE intent is the PRIMARY/MED dicts
inet/                  SONiC FRR config + bootstrap
docs/TASKS.md          Part A build, Part B TE, Part C tickets
docs/TICKETS.md        symptoms only
docs/SOLUTIONS.md      spoilers
docs/ISP-GUIDE.md      what each provider accepts and honors
```

## Caveats

- cEOS BFD and SONiC-VS forwarding run in software. Timers that work here are not a hardware recommendation.
- `grey` uses `containerlab tools netem`. If your build lacks `netem reset`, the script falls back to `--loss 0`.
- If inet BGP never comes up: `docker exec clab-bgp-lab02-inet bash /inet/inet-setup.sh` after SONiC finishes booting.
