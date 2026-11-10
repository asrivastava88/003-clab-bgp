# Lab 19 Solutions

Answers. Read after you have worked the faults.

---

## Part A — The design

**1. The route-target plan.**

| VRF | L3VNI | Export | Imports | Count |
|---|---|---|---|---|
| PROD | 50001 | 1:50001 | 1:50001, 1:50003 | 2 |
| DEV | 50002 | 1:50002 | 1:50002, 1:50003 | 2 |
| SHARED | 50003 | 1:50003 | 1:50003, 1:50001, 1:50002 | 3 |

Hub and spoke. Each spoke imports itself and the hub. The hub imports itself and
every spoke. PROD never imports 1:50002, DEV never imports 1:50001, and that
absence is the entire isolation guarantee. There is no ACL anywhere in this lab.

**2. Why SHARED does not join PROD to DEV.**

Because route-target import is not transitive. A route carries the RT its
*originating* VRF exported, and it keeps it. When SHARED imports PROD's
10.101.11.0/24 with RT 1:50001, it installs it in the SHARED table — it does not
re-export it. SHARED exports 1:50003 and only the prefixes it originates itself.
So DEV, importing 1:50003, receives SHARED's own prefixes and nothing SHARED
learned from PROD. Leaking is a property of the route, not of the table it
landed in. The way you break this is by re-originating: `redistribute` the
leaked route, or add an export RT to the importing VRF — which is exactly
fault 1.

**3. Three single-device changes that break the invariant.**

- Add `route-target import evpn 1:50002` to PROD *and* an export of 1:50002
  (fault 1). Detected by `isolation`, because reachability becomes symmetric.
- Add only the import. **`isolation` will not catch this**, because the return
  route does not exist and the ping fails. The device's PROD table contains
  every DEV prefix in the fabric and the breach is invisible to a ping test.
  `./lab.sh rt` and `./lab.sh vrf` catch it; a config audit catches it
  immediately.
- Put an interface in both VRFs' reach: a route-leaking static, a shared
  sub-interface, or a host dual-attached into PROD and DEV with IP forwarding
  on. No BGP change at all, and no fabric tool sees it.

The lesson is that **a reachability test proves a breach, it does not disprove
one.** Half of all RT mistakes are one-directional, and a one-directional leak
is still a disclosure of your whole DEV address plan into PROD.

**4. Spines run no BGP.**

Buys: a spine is pure IP transport. It holds an OSPF database and nothing else —
no VRFs, no EVPN table, no RTs, no tenant state. Tenant churn never touches it,
so a tenant change cannot take a spine down and a spine reload cannot corrupt a
tenant. The config is ~30 lines and identical across twelve devices, which means
it is reviewable at a glance.

Costs: all EVPN reflection moves to the super-spines, so every tenant route in a
region crosses the super-spine layer in the control plane even when the data
path is leaf→spine→leaf. Two super-spines is your entire control-plane
redundancy for a region, and losing both loses overlay convergence region-wide
(existing tunnels keep forwarding). It also means the spine layer cannot ever
terminate a VRF, so a future per-pod service-leaf design has to go somewhere
else.

**5. OSPF + iBGP here, eBGP in Labs 17 and 18.**

eBGP everywhere: one protocol, ASN-per-device loop prevention, hop-by-hop policy
you can see, and a next hop that changes at every hop — which is why EVPN over
eBGP needs `next-hop-unchanged` and careful RR-free design. It scales to
thousands of switches and it is what the hyperscalers run.

OSPF underlay + iBGP overlay: the underlay converges without policy, the overlay
has one AS so the EVPN next hop survives end to end untouched, and route
reflection is the native pattern. It is less operationally uniform and the
flooding domain is a real constraint past a few hundred nodes.

For a new fabric: eBGP underlay, eBGP EVPN overlay, no reflectors. It costs more
thought up front and it never surprises you at 300 nodes. This lab uses OSPF so
the overlay mechanics stay in focus, and the README says so.

**6. Why per-VRF eBGP at the region boundary beats stretching EVPN.**

- **Per-tenant policy at the edge.** Each tenant gets its own session, so you can
  prepend, filter, rate-limit or shut one tenant's inter-region path without
  touching the other two. Fault 6 is exactly that, done by accident.
- **A hard aggregation point.** Each region announces its own /16 per tenant and
  nothing else. A leaf's route churn stops at the border instead of propagating
  into two other regions' EVPN tables.
- **A different failure domain.** A broken RT, a VNI typo or an RD collision
  stays inside one region. With a stretched overlay the RT namespace is global
  and so is the blast radius.

Also: no carrier dependency on VXLAN MTU across the WAN, and no requirement that
the carrier's ASes be transparent to your next hops.

**7. What `redistribute connected` drags in without `RM-TENANT`.**

On a leaf, nothing — the only interface in a tenant VRF is a loopback. On a
**border** it is a different story, because the WAN sub-interfaces live in the
tenant VRFs. Without the route-map, eur-b1's PROD table originates
10.253.0.48/31 and 10.253.0.54/31 into EVPN, which spreads to every PROD VTEP in
the region and across the WAN to the other two regions' PROD tables.

Worse than untidy, because all three regions number their WAN links out of the
same 10.253.0.0/16. Three borders doing this produce overlapping /31s inside one
tenant VRF, and the winner is decided by BGP best path rather than by anyone's
intent. The specific pathology: a tenant can end up with a more-specific route
to another region's carrier link, pulling tenant traffic into the WAN /31 and
black-holing it. This is the single most common EVPN multi-tenant mistake in
production, and it looks harmless in the lab that first catches it.

**8. Five remote VTEPs.**

Six VTEPs per region — four leaves and two borders — so five remotes. Spines and
super-spines are not VTEPs. Four means either a VTEP's loopback is unreachable in
the underlay (fault 3) or two devices are sharing a VTEP address (fault 7). Both
appear identically in `./lab.sh vtep`; `show ip route 10.1.R.x` tells them apart
— no route versus two.

---

## Part B — The twelve faults

| # | Device | What was changed | First tool to show it |
|---|---|---|---|
| 1 | wst-p1-l2 | PROD imports **and exports** 1:50002 | `isolation` |
| 2 | est-p2-l1 | DEV drops import 1:50003 | `verify` / `vrf` |
| 3 | eur-p1-l2 | VTEP loopback out of OSPF | `vtep` |
| 4 | wst-p2-l1 | Vxlan1 loses `vrf SHARED vni 50003` | `verify` |
| 5 | est-b1 | PROD loses `RM-WAN-OUT` outbound to wan1 | `verify` (transit check) |
| 6 | eur-b2 | DEV WAN session to wan2 loses `remote-as` | `verify` (session counts) |
| 7 | wst-p1-l1 | VTEP loopback readdressed to wst-p1-l2's | `vtep` |
| 8 | est-ss2 | one VTEP dropped from the OVERLAY group | `verify` (EVPN counts) |
| 9 | eur-b1 | PROD `redistribute connected` loses `RM-TENANT` | `verify` (containment) |
| 10 | wst-b2 | SHARED drops export 1:50003 | `verify` (RT export count) |
| 11 | est-p1-s2 | one leaf /31 out of OSPF | `verify` (adjacency counts) |
| 12 | eur-ss1 | OVERLAY not activated under address-family evpn | `verify` (EVPN counts) |

**9. The tenancy breach: fault 1.**

`wst-p1-l2`, `router bgp 65001 / vrf PROD`:
```
route-target import evpn 1:50002
route-target export evpn 1:50002
```
The import gives that device's PROD table every DEV prefix in the region and
across the WAN. The export puts that device's PROD prefix into every DEV table.
Reachability is therefore symmetric and PROD on wst-p1-l2 can reach DEV
anywhere. One device, two lines, and the isolation guarantee for a whole tenant
is gone — and it is still gone after you fix it, in the sense that you now have
to assume disclosure for the window it was live.

Without `isolation`: `show bgp evpn route-type ip-prefix ipv4 vrf PROD` and look
for anything out of the DEV range, or diff the RT stanzas across the eighteen
VTEPs — seventeen are identical. The second is faster and is what a config
audit does, which is the real answer: you do not find this by testing, you find
it by not allowing it.

**10. DEV loses SHARED on one device: fault 2.**

`est-p2-l1`, DEV, missing `route-target import evpn 1:50003`. Every other
device in est still works because the import is configured per device per VRF —
there are eighteen independent copies of this plan and seventeen are intact.
Note the asymmetry: SHARED still imports 1:50002, so SHARED has a route *to*
est-p2-l1's DEV host. Traffic leaves and never comes back. The SHARED side sees
nothing wrong at all.

**11. The two VTEP faults.**

- **Fault 3 (underlay):** eur-p1-l2's `network 10.1.3.2/32 area 0.0.0.0` is gone
  from OSPF. The EVPN session is Established (that runs over Loopback0, which is
  still advertised), the type-5 routes are present and correct, the next hop is
  10.1.3.2, and no VTEP in the region has a route to it. The tunnel never forms.
- **Fault 7 (addressing):** wst-p1-l1's Loopback1 is 10.1.1.2/32 — wst-p1-l2's
  address — and OSPF advertises it from both devices. Five distinct VTEP
  addresses for six devices.

Fault 7 is worse. Fault 3 fails closed: one VTEP is unreachable, its tenant
hosts are down, the symptom is total and the finding is obvious. Fault 7 fails
*ambiguously*: whichever device OSPF prefers receives the VXLAN traffic for
both, decapsulates it, finds no route for half the destinations and drops it.
From the far end this looks like intermittent, destination-dependent loss with a
perfectly healthy control plane.

The command: `show ip route 10.1.1.2` — one path is fine, two paths to two
different nexthops is fault 7, `not found` is fault 3.

**12. Control plane perfect, data plane dead: fault 4.**

`wst-p2-l1`'s Vxlan1 no longer maps VRF SHARED to VNI 50003. The VRF exists, the
RTs are right, the EVPN table is right — and there is no VNI to encapsulate
into, so nothing enters or leaves the tunnel for that tenant on that device.
`show vxlan config-sanity` and `show vxlan vni` are the gap: compare the VRF-to-
VNI table against the BGP VRF list and the missing row is the whole finding.
Worth internalising as a class: **the overlay has two independent
configurations, the BGP one and the encapsulation one, and nothing in BGP
validates the second.**

**13. A region becomes transit, in one VRF: fault 5.**

`est-b1`, VRF PROD, lost `neighbor 10.253.0.25 route-map RM-WAN-OUT out`. With
no outbound filter the border re-advertises what it learned — which includes
wst's and eur's PROD /16s, learned over the *other* carrier — so wan1 now sees
those prefixes with est's ASN in the path and may route a wst↔eur PROD flow
through Ashburn. DEV and SHARED are unaffected because the route-map is applied
per neighbor and there are six WAN neighbors per border, one per tenant per
carrier. Nothing is unreachable; you have simply volunteered to carry someone
else's traffic, in one tenant, and you will find out when a link fills up.

**14. Broken between regions, perfect inside every region: fault 6.**

`eur-b2`, VRF DEV, `neighbor 10.253.0.69` lost its `remote-as`, so the session
never comes up. Nothing is unreachable — eur-b1 still has both carriers and
eur-b2 still has wan1 — so DEV has three of four inter-region paths instead of
four. `./lab.sh wan` and the border session counts (7 instead of 8 on eur-b2, 17
instead of 18 on wan2) are what show it. Inside eur, DEV is flawless.

**15. WAN addresses inside a tenant: fault 9.**

`eur-b1`, VRF PROD, `redistribute connected` with no route-map. 10.253.0.48/31
and 10.253.0.54/31 are redistributed into PROD, exported with RT 1:50001,
imported by every PROD VTEP in eur, and announced across the WAN to wst and est.
Second-order problem: all three regions number WAN links out of 10.253.0.0/16,
so if two borders do this the tenant table holds overlapping /31s from different
regions and best path picks the winner. A tenant host whose address happens to
fall in one of those /31s becomes unreachable in a way that has no relationship
to anything in the tenant's own configuration.

**16. The duplicate VTEP: fault 7.**

The winner is whichever advertisement OSPF prefers — here both are intra-area
host routes, so it comes down to cost from the viewer: a VTEP in pod 1 may
prefer one, a VTEP in pod 2 or a border may prefer the other, and different
sources disagree. Traffic for the loser's hosts is delivered to the winner,
which decapsulates correctly (the VNI is valid, the VRF exists) and then has no
route for the destination, so it drops it in the tenant table. The EVPN control
plane reports nothing because nothing in EVPN checks that a next hop is unique —
a VTEP address is just an IP, and advertising it twice is an underlay statement,
not an overlay one.

What makes it impossible: VTEP addresses allocated by a generator from the
device's position in the model, never typed. This lab's own
`tools/gen_configs.py` derives Loopback1 as `10.1.{region}.{index}`, so this
fault cannot be produced by regenerating — only by editing a box by hand, which
is the point.

**17. A missing export is harder than a missing import: fault 10.**

`wst-b2`, VRF SHARED, lost `route-target export evpn 1:50003`.

A missing *import* breaks the device that has the mistake. It is self-announcing:
the operator looking at the broken device is looking at the broken config.

A missing *export* breaks **everybody else's view of** the device that has the
mistake, and the device itself is perfectly healthy. Its own SHARED table is
complete, its sessions are up, its pings out succeed. The symptom lands on
seventeen other devices, each of which is correctly configured, so every
instinct points away from the cause.

Who notices first: nobody, here. wst-b1 exports the same prefixes, so wst's
leaves still learn remote-region SHARED routes and nothing fails. You have lost
half the inter-region SHARED capacity and all of the redundancy, silently. This
is why `verify` counts RT exports per border as a config assertion rather than
waiting for a reachability test — a state test cannot see this fault at all.

**18. Ranked by survival time in production.**

| Survives | # | Why |
|---|---|---|
| Indefinitely | 10 | No symptom. Found only by audit or by a second failure. |
| Indefinitely | 8, 12 | Redundancy only. Found when the other reflector reboots. |
| Weeks | 1 | **No symptom either** — until an audit, or a breach report. |
| Weeks | 5 | Nothing breaks; a traffic bill or a congested WAN link eventually asks why. |
| Weeks | 11 | One leaf on one uplink. Found when the surviving spine is drained. |
| Days | 6, 9 | Capacity and correctness drift; noticed at the next change or failure. |
| Hours | 7 | Intermittent, destination-dependent, blamed on everything else first. |
| Minutes | 2, 3, 4 | A tenant is down. Someone calls. |

**Longest-surviving:** 10 (or 1 — both are symptomless). **Escalate first:** 1.
They are different faults, and that is the right answer precisely because
severity and detectability are independent. Fault 1 is the only one on the list
that is a security incident rather than an outage: it cannot be fixed by
restoring service, it has to be fixed and then reported, and every minute it
stays live widens the disclosure window. Everything louder than it is less
important than it.

**19. What a config audit would have caught.**

All twelve, before deployment. Every one of them is a divergence from what the
generator would render — eleven are a line removed or changed, one (fault 1) is a
line added — and a structural diff against the render catches a divergence
regardless of whether it has a symptom. That is the Lab 16 lesson applied here,
and the stronger form of it is that **in a generated-config fabric none of these
twelve faults can exist**, because no human types any of these lines. The audit matters for the
window between someone's emergency CLI change and the next regeneration.

For the tenancy breach specifically the assertion is three lines:

```
for every device, for every VRF v:
    imports(v) == declared_imports(v)
    exports(v) == declared_exports(v)
    PROD.imports ∩ {DEV.export_rt} == ∅  and  DEV.imports ∩ {PROD.export_rt} == ∅
```

The third line is the invariant stated independently of the plan, so it still
fires if someone changes the plan itself. Both matter: the first two catch drift,
the third catches a bad intent.

---

## Part C — Tenancy at scale

**20. Making the invariant unbreakable.**

- **Source:** one tenant registry — tenant name, VNI, RD scheme, export RT,
  import list, address block. One file, reviewed, versioned. Nobody types an RT.
- **Generation:** configs rendered from the registry plus a topology model, as
  `tools/gen_configs.py` does here. The RT lines in eighteen devices come from
  one expression, so they cannot diverge.
- **Pre-merge test:** assert the RT graph against the policy, not against the
  previous render. For every tenant pair not declared adjacent, assert no RT
  path. Reject the merge, not the deploy.
- **Continuous:** two separate things. A config audit (does the device match the
  render) on a short interval, and a reachability prober that sits in PROD and
  tries to reach DEV and must fail. The prober catches the leak that is not in
  the config — the dual-homed host, the leaking static, the firewall someone
  bridged. The audit catches everything else. Neither covers the other.
- **Change gate:** any diff that touches a `route-target` line requires a second
  reviewer. It is one grep in CI and it is the highest-value gate in the fabric.

**21. A fourth tenant.**

Needs SHARED only — the clean case, and it is just another spoke:
```
TEST: export 1:50004, import 1:50004 + 1:50003
SHARED: add import 1:50004
```
Two files change, nothing else moves.

Needs PROD but not DEV:
```
TEST: export 1:50004, import 1:50004 + 1:50003 + 1:50001
PROD:  add import 1:50004
```
This is the design smell. The first case keeps the hub-and-spoke topology; the
second makes TEST and PROD peers, and the RT graph stops being a star and starts
being an arbitrary mesh. Three consequences: the invariant can no longer be
stated as "spokes import only the hub", every new tenant becomes a judgement
call rather than a template, and the pair count you must test grows as N². When
a tenant needs to reach another tenant, the right answer is almost always a
service in SHARED, or a firewall between them with a policy someone owns — not
an RT.

**22. Where hub-and-spoke stops scaling.**

SHARED imports N route-targets, and every VTEP holds SHARED's table plus its own.
What breaks first is not the import list — it is that **SHARED's table is the
union of everything every tenant chose to export into it**. At N≈20 that is a
review problem; at N≈100 the SHARED VRF is the largest table in the fabric and
is imported by all of them, so one tenant's route churn is felt by every tenant.
Hardware limits (VRF count, L3VNI count, per-VRF route scale) usually bite
earlier than the RT count itself.

Alternatives, in order of preference:
1. **Don't put shared services in a VRF.** Put them behind a firewall or a load
   balancer reached through a default route per tenant. The tenant gets a next
   hop, not a routing table, and N stops mattering.
2. **Downstream VNI / per-tenant service instance** — each tenant imports a
   small, tenant-specific slice rather than the whole hub.
3. **RT constrained route distribution (RFC 4684)** so a VTEP only receives RTs
   it imports. This fixes the distribution cost, not the table-size cost.

**23. Overlapping tenant address space.**

Everything about the handoff changes, and the fabric mostly does not care — VRFs
are already separate tables, and the RD (not the RT) keeps the EVPN NLRIs
distinct, which is why RDs are per-VRF-per-device and derived from the VTEP IP.
What changes:
- SHARED becomes impossible as built. Two tenants with 10.101.11.0/24 cannot both
  leak it into one table. You need NAT at the shared-services edge, or a separate
  SHARED instance per overlapping group.
- The WAN handoff needs per-VRF NAT or per-VRF carrier instances; the carriers
  here hold all three tenants in separate VRFs already, so the sub-interface
  model survives, but any aggregation into a common table does not.
- Any tool keyed on address → tenant breaks. In this lab that is most of them:
  `VHOST` in `tools/peers.sh` maps device:VRF to a unique host address, `verify`
  pings by address, and `PL-TENANT` is a single prefix-list per region. All of it
  assumes addresses identify a tenant. Monitoring, flow records, IPAM and
  firewall rules make the same assumption in production, and that — not the
  routing — is what makes overlapping space expensive.

**24. Isolation in the fabric versus on the host.**

For the fabric: the blast radius of a host-side mistake is one host, but the
blast radius of a *missing* host-side control is everything that host can reach.
Fabric isolation is enforced by a device the tenant does not administer, which is
the whole point for anything regulated. It is auditable as configuration rather
than as the aggregate behaviour of thousands of agents, and it fails closed —
a VRF with no route reaches nothing.

For the host: change velocity. A tenant change is an API call, not a fabric
change, so you decouple application teams from network teams entirely. It scales
past any VRF limit, it follows a workload when it moves, and the policy can be
expressed in terms the application understands (identity, service) rather than
addresses. Microsegmentation does things a VRF cannot: intra-subnet,
per-process, per-identity.

Against the fabric: VRF count and L3VNI scale are hard ceilings, every tenant
addition is a change on dozens of devices, and the thing enforcing your security
boundary is the same thing carrying your traffic — so a routing mistake is a
security mistake, as fault 1 demonstrates.

Against the host: the control plane is enormous and distributed, the enforcement
point is inside the trust boundary it is enforcing, and "prove tenant A cannot
reach tenant B" becomes an argument about agent coverage rather than a
statement about a routing table.

What to do: both, with different jobs. Fabric VRFs for coarse, rarely-changing,
audited boundaries — the ones you must prove to a third party. Host policy for
fine-grained, fast-moving service-to-service rules. Do not try to express
application policy in route-targets, and do not rely on host agents for the
boundary that appears in a compliance report.

**25. Proving PROD cannot reach DEV.**

Evidence to produce:
1. The tenant registry and the generator, with the RT plan, under version
   control, with the review history.
2. A rendered-config assertion across all eighteen VTEPs: PROD imports exactly
   {1:50001, 1:50003}, DEV exactly {1:50002, 1:50003}, and no VRF exports
   another tenant's RT. Signed output, dated, from the live devices rather than
   from the render.
3. The RT reachability graph computed from those configs, showing no path
   PROD→DEV.
4. Continuous prober results: a PROD-attached host attempting DEV destinations
   on a schedule, with the failures logged as successes.
5. Change control showing every RT-touching diff and who approved it.

What it proves: that no *routing* path exists through the fabric, continuously,
over the audit window.

What it does not prove: anything about a path that is not a fabric route. A host
in both VRFs. A firewall or load balancer with interfaces in both. A management
network both tenants reach. Backup or storage infrastructure shared between
them. A hypervisor bridging the two. Compromise of a device that holds both
tables — the super-spine reflects both tenants' routes, and the carriers carry
both.

What to say about the gap: say it first, unprompted, and name each path above
with the control that covers it. An auditor who finds a gap you did not declare
discounts everything you did declare. The accurate claim is narrow and strong:
"no layer-3 path exists through the fabric, verified continuously, and here are
the four non-fabric paths between these tenants and who owns each one."

**26. Stretching EVPN across the WAN.**

For: one control plane, one RT namespace, no per-tenant eBGP sessions to
maintain (eighteen in this lab, growing linearly with tenants × regions ×
carriers), tenant subnets that can exist in more than one region, and a VM that
can move between regions without renumbering. Fault 6 — a tenant down to three
of four paths because one session lost a `remote-as` — simply cannot happen,
because there is no session.

Against: the RT namespace becomes global, so fault 1 leaks a tenant in three
regions instead of one. The failure domain becomes global: a route-reflector
mistake, a VNI collision or an RD collision is now a fleet event. You depend on
the carrier for MTU (VXLAN plus your tenant MTU, end to end, on both carriers,
forever) and on next-hop transparency across their AS. And you lose the
aggregation point — a leaf flap in Seattle is now a control-plane event in
London.

What I would do: keep the boundary. Per-VRF eBGP with per-region aggregation,
as built. The session count is the price of a blast radius that stops at a
region, and the session count is automatable while the blast radius is not.

What would change my mind: a hard requirement for a subnet to exist in two
regions at once — live migration across regions, or an active/active cluster
with a shared L2 adjacency. Then I would stretch that one tenant, with its own
VNI range and its own RT block, and leave the others at the boundary. The second
thing that would change my mind is tenant count: past a few hundred tenants the
per-tenant session model stops being automatable and starts being a scaling
problem of its own.

**27. Three failure modes this lab cannot reproduce.**

- **MAC-level anything.** There are no L2VNIs, no type-2 routes, no ARP
  suppression, no MAC mobility, no duplicate-MAC detection, no MAC move storms.
  Every tenant endpoint here is a routed /32 on a loopback. Reproducing it needs
  L2VNIs, real bridged hosts and at least one host that moves — a different lab,
  and the one where most real EVPN incidents actually live.
- **Scale-driven failure.** Route-target constrained distribution, RIB and
  hardware table exhaustion, reflector CPU under churn, slow convergence from
  table size. Six VTEPs per region holding a dozen prefixes each cannot show it;
  it needs thousands of prefixes and real forwarding hardware.
- **Carrier-side pathology.** The carriers here are single routers with one AS
  each. No MTU mismatch across the WAN, no asymmetric routing between two
  carriers, no route leak *from* the carrier, no flapping circuit, no MPLS
  label-path problem underneath. Needs the carrier modelled as a multi-hop AS
  with its own policy and impairment — Labs 13 and 14 do that for the IP layer,
  and nothing here does it for the tenant layer.
