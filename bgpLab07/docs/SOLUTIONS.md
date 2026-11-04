# Lab 07 Solutions (spoilers)

Reference config: `configs/solution/`. `configs/base/` is the fully isolated starting point.

## Part A

### Shared services, both directions

Spoke side, on every leaf that instantiates a tenant VRF:
```
router bgp 6510x
   vrf RED
      route-target import evpn 50001:50001
      route-target import evpn 50099:50099      <- the leak
      route-target export evpn 50001:50001
```
Hub side, wherever SHARED is instantiated:
```
   vrf SHARED
      route-target import evpn 50099:50099
      route-target import evpn 50001:50001      <- RED
      route-target import evpn 50002:50002      <- BLUE
      route-target import evpn 50003:50003      <- GREEN
      route-target export evpn 50099:50099
```

Note what is *not* there: no tenant imports another tenant's RT. The isolation is an absence, which is why it is so easy to destroy by addition.

### Fusion handoff

bleaf1, one dot1q subinterface per fused VRF on a single physical link:
```
interface Ethernet3.101
   encapsulation dot1q vlan 101
   vrf RED
   ip address 172.16.1.1/30
!
interface Ethernet3.102
   encapsulation dot1q vlan 102
   vrf BLUE
   ip address 172.16.2.1/30
!
router bgp 65104
   vrf RED
      neighbor 172.16.1.2 remote-as 65200
      neighbor 172.16.1.2 route-map RM-RED-IN in
      neighbor 172.16.1.2 route-map RM-RED-OUT out
```
with `RM-RED-OUT` permitting only 10.10.0.0/16 and `RM-RED-IN` permitting only 10.20.0.0/16, and the mirror for BLUE. fw strips private ASNs on egress toward both.

### Answers

**Q1 Why an import is one-way.** After A1, RED imported 50099:50099, so RED's table had 10.100.100.0/24 and hR1 could build and send a packet. SHARED imported nothing from RED, so SHARED's table had no 10.10.10.0/24 and the reply had nowhere to go. The missing route was in `show ip route vrf SHARED` on leaf2.

An import statement says "accept routes carrying this RT into this VRF." It says nothing about the other direction, because the other direction is a different VRF's import list. Every leak is two configuration changes in two places, and getting one of them is the most common way to build a service that half works.

**Q2 Why SHARED holding both does not connect RED to GREEN.** The behavior being relied on is that EVPN routes imported into an IP-VRF are **not re-originated** into EVPN with that VRF's export route-target. SHARED installs RED's 10.10.10.0/24 in its RIB, but it does not turn around and advertise it as a new type-5 carrying 50099:50099. If it did, every tenant would import every other tenant's prefixes through the hub and the isolation would be gone.

Do not assume it. Verify it, which is what this assertion in `verify` does:
```
show ip route vrf GREEN 10.10.10.0/24      -> must be empty
show ip route vrf RED 10.30.30.0/24        -> must be empty
```
If either returns a route, hub-and-spoke RT leaking is unsafe on that platform and shared services need a fusion device too.

**Q3 Why the fusion is worth it, and what RT leaking cannot do.** RT leaking is an all-or-nothing statement about a route-target. You import the RT and you get everything stamped with it, in full, with no ability to permit some flows and deny others, no statefulness, no logging, and no inspection. The one thing it cannot do is **apply policy to a flow**.

The fusion exists because RED-to-BLUE is traffic between two tenants who do not trust each other, and someone needs to be able to say "RED may reach BLUE's web tier on 443 and nothing else," log it, and change it next quarter. Shared services get the leak because DNS and NTP are not a trust boundary; inter-tenant gets the device because it is.

**Q4 The AS_PATH on the way back.** leaf1 originates 10.10.10.0/24 in RED. bleaf1 imports it via RT 50001:50001, so inside the fabric it arrived over the EVPN overlay with path `65100 65101`. bleaf1 advertises it to fw from VRF RED: `65104 65100 65101`. fw receives it, and would advertise it to bleaf1's BLUE session as `65200 65104 65100 65101`. bleaf1 sees its own ASN 65104 in that path and drops it as a loop, so BLUE never learns RED's prefix.

`remove-private-as all` on fw strips every private ASN before advertising, so BLUE receives it with path `65200` only. Note that `allowas-in` on bleaf1 alone would not fix this: the spines (65100) and leaf1 (65101) are also in that path and would drop it at the next hop.

**Q5 hR2 to 10.10.11.1.** The packet leaves hR2 to its anycast gateway on leaf2, which routes it in VRF RED. leaf2 has 10.10.11.0/24 as an EVPN type-5 from leaf1 with VNI **50001**, RED's L3VNI, and a router-MAC extended community naming leaf1's VTEP MAC. leaf2 encapsulates with VNI 50001 and the inner destination MAC set to **leaf1's router-MAC**, not the host's. leaf1 decapsulates, sees its own router-MAC, routes the inner packet in VRF RED and delivers. That is symmetric IRB.

## Part B

**B1 Tracing a leak.** `./lab.sh leak SHARED 10.10.10.0/24` shows the route in SHARED's table and the EVPN route behind it with RT 50001:50001 in its extended-community list. The line responsible is `route-target import evpn 50001:50001` under `vrf SHARED`. The reverse, `leak RED 10.100.100.0/24`, shows RT 50099:50099 and `route-target import evpn 50099:50099` under `vrf RED`. The first serves hS1-to-tenant; the second serves tenant-to-hS1. Both are required for anything to work.

**B2 Host routes come along.** `show ip route vrf SHARED` on leaf2 holds RED's subnet *and* a /32 for every RED host that has been learned, because type-2 MAC-IP routes carry the L3 RT as well as the L2 RT and the /32 is imported with everything else.

At five hosts this is invisible. At 4000 hosts across 40 leaves, your shared-services VRF is carrying 4000 host routes it has no use for, multiplied by the number of tenants, on every leaf that instantiates SHARED. What to do about it, in order of preference: enable ARP suppression on the leaves so fewer type-2s are generated in the first place; filter the import so only the subnet routes land, if your platform supports an import route-map; or accept it and size the platform, which is the honest answer on a small fabric and the wrong answer on a large one.

**B3 Why RT leaking cannot express the B3 rule.** On fw you add a deny for the single host and permit the rest, which is an ACL or firewall rule on a device that sees the flow. With route-targets you can only choose whether BLUE's prefixes enter RED's table at all; there is no granularity below the prefix, no concept of a port, and no device in the path to enforce anything even if there were.

One sentence: **a route-target decides whether a route exists, not whether a packet is allowed.**

**B4 Overlapping address space.** Both tenants legally use 10.10.10.0/24 because they are isolated, and the fabric carries both as distinct EVPN routes with different RDs. The collision happens on import: SHARED imports RED's RT and GREEN's RT, both carry a 10.10.10.0/24, and SHARED's IP-VRF can hold only one route for that prefix. Best path picks one, almost certainly on router-id, and the other tenant silently loses shared-services reachability in the return direction. The tenant can still reach hS1; hS1 just answers into the wrong tenant.

Three ways out:
1. **Renumber one tenant.** Correct, permanent, and politically the hardest. Costs a maintenance window and a conversation.
2. **Do not leak the overlapping subnet.** Keep the overlap on a VLAN whose prefixes are excluded from the export, or give it an RT nobody imports. Cheap, and it means those hosts have no shared services.
3. **NAT at a fusion device.** Each tenant's overlapping range is translated to a unique range before entering the shared VRF. This is what service providers actually do, and it means the shared-services path now needs a device, which is the thing you were avoiding.

Pick 1 if you can and 3 if you cannot. Picking 2 is choosing to have a tier of hosts with no DNS, which is usually discovered later and badly.

**B5 Adding tenant YELLOW.** Shared services only: on leaf2, a VLAN, an L2VNI, an SVI in the new VRF, `vrf instance YELLOW`, `ip routing vrf YELLOW`, the L3VNI under Vxlan1, the MAC-VRF stanza, and the VRF stanza with its own RT plus the import of 50099:50099. Then **on every leaf that instantiates SHARED**, add `route-target import evpn <yellow RT>`. So: one leaf for the tenant, plus one line on every hub leaf. That second part is what grows.

Adding fusion access to RED as well: a new dot1q subinterface on bleaf1 in VRF YELLOW, a new subinterface and session on fw, prefix-lists and route-maps for the new pair in both directions on both devices, and the YELLOW VRF instantiated on bleaf1 with its L3VNI. That is two devices, four route-maps and two new sessions for one tenant pair, and it scales as the square of the number of pairs you allow. This is the real argument for a firewall with a single pair of legs and VRF-aware policy rather than a per-pair handoff.

**B6 Proving isolation properly.** The data-plane matrix proves nothing about hosts that are down or subnets with no host at all. The control-plane assertion is stronger and cheaper: for every tenant VRF on every leaf, assert that `show ip route vrf <tenant>` contains no prefix belonging to another tenant. Equivalently, assert that the VRF's import list is exactly its own RT plus the hub's.

Turned into something runnable: collect `show ip route vrf <each> | json` and the BGP VRF config from every leaf on a schedule, compare the import lists against the intended matrix held in source control, and alert on any difference. That catches ticket 1 the moment it is committed rather than at the next quarterly audit. The matrix in `tools/gen_configs.py` is already that source of truth; the missing piece is comparing the devices back to it.

## Part C tickets

**T1 RED imports GREEN's route-target, on both leaves.**
A security finding with no outage. Isolate: `./lab.sh matrix` shows GREEN-to-RED and RED-to-GREEN as reachable where the policy says blocked. `./lab.sh rts` shows `route-target import evpn 50003:50003` under `vrf RED` where it has no business being. `show ip route vrf RED 10.30.30.0/24` on leaf1 returns a route.
Fix: remove the import from RED on both leaves.
Lesson: an isolation breach is an *addition*, it fires no alarm, it breaks no service, and nothing in a reachability dashboard will ever show it. The only controls that catch it are a config diff against an intended matrix and a negative test. This is the ticket to take away from the lab.

**T2 SHARED stopped importing BLUE's route-target.**
Isolate: hB1 can reach its own gateway and nothing in SHARED answers. The direction matters: `show ip route vrf BLUE 10.100.100.0/24` on leaf1 still has the route, because BLUE's import of 50099:50099 is untouched, so BLUE's packets leave fine. `show ip route vrf SHARED 10.20.20.0/24` on leaf2 is empty, so the replies have no path. RED and GREEN are unaffected because their imports are separate statements.
Fix: `route-target import evpn 50002:50002` under `vrf SHARED`.
Lesson: the signature of a half-configured leak is one-way traffic, and the tell is that the source can reach its own gateway but gets no reply. Check both tables before touching anything; the broken one is usually not the one the complaint came from.

**T3 SHARED's `redistribute connected` removed on leaf2.**
Isolate: every tenant loses shared services at once, which points at the hub rather than at any spoke. `show ip route vrf RED 10.100.100.0/24` on leaf1 is empty, and on leaf2 `show bgp evpn route-type ip-prefix ipv4 10.100.100.0/24` shows nothing originated. The subnet is still a connected route in SHARED's RIB, which is why hosts in VLAN 100 are fine and the SVI still answers.
Fix: `redistribute connected` under `vrf SHARED`.
Lesson: having a prefix and advertising it are different things. "All tenants lost one service" localizes to the service's own VRF immediately; "one tenant lost everything" would have pointed the other way.

**T4 RED's L3VNI mismatched on leaf2 (50001 changed to 50011).**
Isolate: hR1-to-hR2 still works because that is the stretched L2VNI 10010 and does not touch the L3VNI. hR2-to-10.10.11.1 fails because that is a routed hop across VNI 50001, and leaf2 is now encapsulating with 50011, which leaf1 has no VRF bound to. `show vxlan vni` on both leaves side by side shows it in one line.
Fix: `vxlan vrf RED vni 50001`.
Lesson: an L3VNI mismatch breaks routed inter-subnet traffic while leaving bridged same-subnet traffic perfectly healthy. "Same subnet works, different subnet does not" is the fingerprint, and it is the fastest way to tell an L3VNI problem from an L2VNI problem.

**T5 fw lost `remove-private-as all` on both sessions.**
Isolate: both fusion sessions are Established and fw's table has both tenants' prefixes, which is exactly what the reporter said. The failure is one hop further: `show ip bgp neighbors 172.16.2.1 advertised-routes` on fw shows RED's prefix going out with the fabric ASNs still in the path, and `show ip route vrf BLUE 10.10.10.0/24` on bleaf1 is empty because bleaf1 dropped it on its own ASN.
Fix: re-add `remove-private-as all` on both neighbors.
Lesson: identical to Lab 01 ticket 7, which is the point of including it. A fusion device sits outside your AS and hands your own routes back to you, so the AS_PATH is always the thing to check when a fusion path dies with healthy sessions.

**T6 bleaf1's RED VRF stopped importing RED's own route-target.**
Isolate: RED-to-BLUE is dead in both directions and shared services still work, which rules out anything on the leaves. On bleaf1, `show ip route vrf RED` has no tenant prefixes at all, so it has nothing to advertise to fw, and fw therefore has nothing to give BLUE. `show ip bgp neighbors 172.16.1.2 advertised-routes vrf RED` is empty.
Fix: `route-target import evpn 50001:50001` under `vrf RED` on bleaf1.
Lesson: the border leaf is a participant in the tenant VRF, not just a transit device. It needs to import the tenant's own RT to have anything to hand to the fusion, and that import is easy to overlook because the border originates nothing itself.

**T7 Anycast gateway MAC removed on leaf2.**
Isolate: three tenants lose their gateway simultaneously and only on leaf2, which is the shape of a global command rather than a per-VRF one. `show ip virtual-router` is empty and `show ip interface Vlan30` shows the virtual address inactive. Hosts on leaf1 are unaffected.
Fix: `ip virtual-router mac-address 00:1c:73:00:00:99`.
Lesson: same root cause as Lab 01 ticket 5, and worth repeating here for the blast radius. `ip address virtual` on every SVI in every VRF depends on one global line, so losing it takes out every tenant on that switch at once. "Several unrelated tenants broke together on one device" is a global-config fingerprint.

**T8 VLAN 10's L2 route-target wrong on leaf1 (10010:10010 changed to 10010:10019).**
Isolate: the two hosts are in the same subnet and cannot reach each other, while both reach shared services and both reach 10.10.11.1. That combination says L2 is broken and L3 is fine. `show vxlan flood vtep vlan 10` on leaf2 does not list leaf1's VTEP, and `show bgp evpn route-type imet` shows leaf1's type-3 arriving with an RT nobody imports, so ARP never crosses the fabric. The L3 paths still work because the MAC-IP route's *L3* route-target is a separate value and is untouched.
Fix: `route-target both 10010:10010` under `vlan 10`.
Lesson: L2 and L3 imports are independent, which Lab 01 ticket 2 also made. In a multi-VRF fabric the diagnostic shortcut is sharper: same-subnet broken plus different-subnet working isolates it to the MAC-VRF in one step.

## Part D

**1 Standardizing on one mechanism.**

RT leaking: no device in the path, so no bandwidth bottleneck, no extra latency, no failure domain, and nothing to license. Its ceiling is that it is a reachability switch with no policy, no state and no logging, and it is all-or-nothing per route-target.

Centralized fusion: real policy, inspection, logging, and a place to change the rules without touching the fabric. Its costs are a bottleneck, a failure domain, latency, and the per-pair configuration growth from B5.

Route this way: **shared infrastructure services** (DNS, NTP, AD, monitoring, backup, package mirrors) through RT leaking, because they are not trust boundaries and the traffic volume is high relative to its sensitivity. **Anything between two tenants who do not trust each other**, and anything crossing a compliance boundary such as cardholder or clinical data, through the fusion. If you must pick one for everything, pick the fusion, because you can always add a leak later for a service that outgrows it, but you cannot retrofit inspection onto traffic that never passes a device.

**2 Redundant fusion.** Two fusion devices, each with its own handoff to two border leaves, so you survive the loss of either device or either border. The borders advertise the fused prefixes with equal cost so the fabric can ECMP, or with deliberate preference if you want a predictable active path.

If the fusion is stateful, symmetry stops being a nice property and becomes a requirement: a flow whose forward path crosses firewall A and whose return crosses firewall B will be dropped by B, which never saw the handshake. Your options are an active/standby cluster with state synchronization, or pinning each VRF pair to one device with local-preference and accepting that failover resets established flows. Do not build active/active across two independent stateful devices with ECMP in front of them and hope; that is a well-known way to produce intermittent, flow-dependent failures that look like everything except what they are.

**3 Thirty tenants in the hub.** The two limits:

- **Table size and import processing in the hub VRF.** SHARED imports 30 route-targets and holds every prefix and, per B2, every host route from all 30 tenants, on every leaf that instantiates SHARED. Mitigate by suppressing host routes at the source with ARP suppression, by filtering imports to subnet routes if the platform allows, and by instantiating SHARED only on the leaves that actually need it rather than everywhere.
- **Configuration surface and drift.** Thirty import lines on every hub leaf, each one a place where a typo creates either a broken tenant or an isolation breach. Mitigate by generating the config from a single source of truth, which is exactly what `tools/gen_configs.py` does here, and by auditing devices back against it on a schedule rather than by review.

A third worth naming: the hub becomes a single point of policy for 30 tenants, so a mistake in it is a 30-tenant incident.

**4 The isolation document.** What you assert: that the control plane on each leaf does not contain routes from one tenant inside another tenant's VRF, and that the configured route-target import lists match an approved matrix held in version control. What you attach: the matrix itself; the per-device import lists collected from the running config; per-VRF route tables showing the absence of other tenants' prefixes; and the result of a negative reachability test like `./lab.sh matrix`.

What you explicitly do not claim: that isolation cannot be bypassed by someone with configuration access, since a single added import line defeats it; that the data plane is isolated under all conditions, because you have tested a sample of host pairs and not a proof; that anything is isolated from the shared-services VRF, because by design nothing is; and that this says anything about traffic inside a VRF. Being precise about the last point is what makes the rest credible.

**5 Internet access for a tenant.** It is a third pattern, not a variation on either. Shared services are a *bidirectional* leak between two of your own VRFs. Internet is a default route into one VRF from a border, with return traffic arriving from outside your control, and it needs its own egress point, its own NAT or public addressing, and its own security posture.

Giving each tenant a default route is not the shared-services problem because the destination is not a prefix you own or can enumerate. A default route into a tenant VRF means any packet with no better match leaves that VRF, so your isolation now depends on the border's policy rather than on the absence of an import. The right shape is a per-VRF handoff at the border to a device that does the policy and the translation, which is the fusion pattern again with the internet on the far side. Lab 01 and Lab 02 built that; this lab's fusion is the same mechanism pointed inward.

**6 RT leaking plus per-leaf ACLs instead of a fusion.** Honestly evaluated, they are right about some things. It removes a bottleneck and a failure domain, the enforcement is distributed so it scales with the fabric, and for simple stateless rules on a small number of prefix pairs it is less moving parts than a firewall pair.

Where it falls down: ACLs on leaves are stateless, so you cannot express "RED may initiate to BLUE but not the reverse" without writing and maintaining both halves by hand. The rule must be present on every leaf that could originate the traffic, so correctness depends on completeness across the whole fabric and a single missed leaf is a hole. Hardware ACL capacity on a leaf is finite and shared with everything else using it. There is no logging worth the name, and no session visibility for an investigation. And the rules live in the fabric configuration, so a security policy change becomes a network change with a network change window.

The defensible version of their proposal is: use it for a small, static, stateless set of inter-tenant exceptions, generate the ACLs from the same source of truth as the route-targets so completeness is mechanical rather than manual, and keep a fusion for anything that needs state, logging or a policy owner outside the network team. If their actual goal is removing a device from the bill, the honest answer is that they are moving the cost from hardware to operations rather than removing it.
