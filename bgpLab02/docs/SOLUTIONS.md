# Lab 02 Solutions (spoilers)

Reference configs: `configs/solution/` (Part A) and `configs/te/` (Part B). Everything below is in those files.

## Part A

Edge baseline on each border, per VRF (bleaf1 RED shown):
```
ip prefix-list PL-FROM-ISP seq 10 permit 0.0.0.0/0
ip prefix-list PL-FROM-ISP seq 20 permit 192.0.2.0/24
ip prefix-list PL-FROM-ISP seq 30 permit 198.51.100.0/24
ip prefix-list PL-FROM-ISP seq 40 permit 203.0.113.0/24
ip prefix-list PL-RED-SUBNETS seq 10 permit 10.10.0.0/16 le 24
route-map RM-ISP-IN permit 10
   match ip address prefix-list PL-FROM-ISP
route-map RM-RED-OUT permit 10
   match ip address prefix-list PL-RED-SUBNETS
!
router bgp 65104
   vrf RED
      neighbor 172.16.11.2 remote-as 65010
      neighbor 172.16.11.2 route-map RM-ISP-IN in
      neighbor 172.16.11.2 route-map RM-RED-OUT out
      neighbor 172.16.11.2 maximum-routes 1000
      (same for 172.16.21.2 remote-as 65020)
      address-family ipv4
         neighbor 172.16.11.2 activate
         neighbor 172.16.21.2 activate
```

**Q1 Shared border ASN.** Anything bleaf1 originates arrives at bleaf2 as `65100 65104 ...` and is dropped as a loop. That is the intent: a border never uses the other border as an Internet exit through the fabric, so a border that loses its ISPs cannot attract and hairpin traffic. Cost: you can never put services on a border that need the other border's routes without `allowas-in` or a separate ASN.

**Q2 One default into EVPN.** BGP advertises only its best path unless add-path is on. The border's local decision (local-preference, AS path, router-id) picks which ISP path the fabric ever sees. Egress policy must therefore be decided on the border, at ISP ingress.

**Q3 Outbound per-VRF filtering.** You own what you announce. Without it, the BLUE session would carry RED prefixes (and the reverse) the moment a VRF imports anything extra, and a provider's inbound filter is someone else's control. This is route-leak prevention, not optimization.

## Part B

### TE-1 Egress: local-preference does not cross eBGP

Local-pref lives inside one AS. Leaves peer with the spines over eBGP, so the border's LP never reaches them. In steady state both borders pick ispA for RED, so leaf1 sees two identical paths and it looks correct by coincidence. Shut bleaf1's RED ispA session and bleaf1 now advertises its ispB default (`65100 65104 65020`) while bleaf2 still advertises ispA (`65100 65104 65010`). Same length, different paths: leaf1 picks one by tie-breakers and may send RED out ispB.

Fix: the border tags intent, the leaves turn the tag into local-pref.

Borders (RED shown; BLUE is the mirror):
```
route-map RM-RED-ISPA-IN permit 10
   match ip address prefix-list PL-FROM-ISP
   set local-preference 200
   set community 65104:200
route-map RM-RED-ISPB-IN permit 10
   match ip address prefix-list PL-FROM-ISP
   set local-preference 50
   set community 65104:50
```
Leaves (VRF-agnostic, identical on every leaf):
```
ip community-list CL-PRIMARY permit 65104:200
ip community-list CL-BACKUP permit 65104:50
route-map RM-EVPN-IN permit 10
   match community CL-PRIMARY
   set local-preference 200
route-map RM-EVPN-IN permit 20
   match community CL-BACKUP
   set local-preference 50
route-map RM-EVPN-IN permit 100
!
router bgp 6510x
   address-family evpn
      neighbor EVPN route-map RM-EVPN-IN in
```
Repeat the shut test: leaf1 picks bleaf2 (LP 200) for RED.

Why this pattern: the policy lives in one place (the border), leaves never learn ISP ASNs, and adding a third ISP touches only the border. The spines must pass standard communities (`send-community` on the EVPN peer group, already there).

### TE-2 Ingress: why prepend fails at your own provider

inet now prefers ispA for RED (shorter path). But ispB ranks its customer routes at local-pref 200 and routes from inet at 100. Local-pref is evaluated before AS-path length, so ispB still delivers its own customers' traffic straight to bleaf. Prepend only influences networks that do not override it with local-pref.

### TE-3 Ingress done right: provider communities

RED toward ispB and BLUE toward ispA carry the provider's backup community; communities must actually be sent.
```
route-map RM-RED-ISPB-OUT permit 10
   match ip address prefix-list PL-RED-SUBNETS
   set community 65020:80
route-map RM-BLUE-ISPA-OUT permit 10
   match ip address prefix-list PL-BLUE-SUBNETS
   set community 65010:80
!
router bgp 65104
   vrf RED
      neighbor 172.16.21.2 send-community
      neighbor 172.16.11.2 send-community
   (all four WAN neighbors per border)
```
Remove the TE-2 prepend. Result in ispB: RED from you at LP 80, RED via inet at LP 100, so ispB sends RED via inet to ispA. Since ispB's best path for RED now comes from inet, it does not advertise your RED route back to inet, and inet has only the ispA path. If ispA fails, ispB's LP 80 path is the only one left and takes over.

Verify: `./lab.sh verify` assertions "ingress", "LP80". Manually: ispB `show ip bgp 10.10.10.0/24 detail`, inet `show ip bgp 10.10.10.0/24`.

`65020:903` is the other tool: it makes ispB prepend toward inet. It affects only inet, not ispB's own customers. Use it when you want to shift load but keep ispB as an active path.

### TE-4 MED

```
route-map RM-RED-ISPA-OUT permit 10
   set metric 50        (bleaf1)   / 100 (bleaf2)
route-map RM-BLUE-ISPB-OUT permit 10
   set metric 100       (bleaf1)   / 50  (bleaf2)
```
Works because ispA compares two paths from the same neighbor AS (65104) with equal local-pref and AS-path length. MED is ignored when: the paths come from different neighbor ASes (unless `always-compare-med`); an earlier attribute already differs (local-pref, AS-path length, origin); the provider rewrites or strips MED by policy. MED is also non-transitive, so it never reaches inet.

### TE-5 RTBH

The trigger is armed in the `te` configs: every WAN outbound route-map has a seq 5 that matches `PL-RTBH` and sets the provider's 666 community. The placeholder `10.10.255.255/32` never exists.

Trigger (both borders):
```
ip prefix-list PL-RTBH seq 20 permit 10.10.10.101/32
```
The /32 already exists in VRF RED on the border: it is h1's EVPN type-2 host route imported into the IP-VRF. No static trigger is needed. A classic static-to-Null0 trigger would be exported into EVPN as a type-5 and could blackhole h1 inside your own fabric.

Verify: ispA and ispB `show ip bgp 10.10.10.101/32` with next hop 192.0.2.254 / 198.51.100.254 and no-export; inet has no /32; from inet `ping 10.10.10.101 source 203.0.113.10` fails while `ping 10.10.20.102 source 203.0.113.10` works. Withdraw: `no ip prefix-list PL-RTBH seq 20`.

Order matters: seq 5 must sit before the subnet clause, because the subnet prefix-list (`le 24`) never matches a /32.

### TE-6 Grey failure and BFD

Without BFD, bleaf1 waits for the hold timer (EOS default 180 s) before it drops the ispA sessions. During that window ispA's RED traffic (MED-preferred to bleaf1) is lost and half of RED egress flows hash to bleaf1 and die. ispA's side stays up because bleaf1's keepalives still arrive; it only resets when bleaf1 finally sends a NOTIFICATION.

Fix on both borders (provider side already has BFD):
```
interface Ethernet3.101
   bfd interval 300 min-rx 300 multiplier 3
(all four WAN subinterfaces)
router bgp 65104
   vrf RED
      neighbor 172.16.11.2 bfd
   (all four WAN neighbors)
```
Detection is about 900 ms. Lowering BGP timers (for example 3/9) is the weaker alternative: slower, and it costs control-plane CPU on every session.

## Part C tickets

**T1 802.1Q tag mismatch.** bleaf2 `Ethernet3.101` uses VLAN 111.
Isolate: subinterface is up/up (carrier is fine); `show ip bgp summary vrf RED` shows 172.16.12.2 Active; `ping vrf RED 172.16.12.2` fails; `show arp vrf RED` has no entry; `show interfaces Ethernet3.101` shows the encapsulation.
Fix: `encapsulation dot1q vlan 101`. Lesson: tag mismatches look like L3 problems because nothing goes down.

**T2 Implicit deny at the end of a route-map.** leaf2 `RM-EVPN-IN permit 100` removed.
Isolate: `show bgp evpn summary` (prefixes received but few accepted), `show bgp evpn route-type mac-ip` empty, `show route-map RM-EVPN-IN`. Only routes tagged by the borders survive, so the Internet works and everything else dies.
Fix: `route-map RM-EVPN-IN permit 100`. Lesson: every inbound policy needs an explicit final permit; compare received vs accepted after any policy change.

**T3 bleaf1 stopped sending communities to the spines.**
Isolate: leaf1 `show bgp evpn route-type ip-prefix 0.0.0.0/0 detail`: bleaf1's paths carry no RT and no 65104:200, so nothing imports them. Inbound traffic still lands on bleaf1 (MED), so flows are now asymmetric.
Fix: `neighbor EVPN send-community` on bleaf1. Lesson: asymmetric flows like this break stateful devices first, so check both directions.

**T4 MED regression.** bleaf1 `RM-RED-ISPA-OUT` sets metric 500.
Isolate: ispA `show ip bgp 10.10.10.0/24` shows MED 500 via bleaf1 and 100 via bleaf2. bleaf1 `show ip bgp neighbors 172.16.11.2 advertised-routes vrf RED`.
Fix: `set metric 50`.

**T5 Backup community never sent.** bleaf2 RED to ispB lost `send-community`.
Isolate: ispB `show ip bgp 10.10.10.0/24 detail`: the path from 172.16.22.1 has no 65020:80 and LP 200, so it wins over inet.
Fix: `neighbor 172.16.22.2 send-community`. Lesson: one border, one VRF, one missing line silently undoes the agreement. Use peer groups or templates for WAN neighbors.

**T6 Grey failure without BFD.** BFD removed from bleaf1's ispA neighbors, plus `grey on`.
Isolate: bleaf1 `show bfd peers` has no ispA peers; `show ip bgp neighbors 172.16.11.2 vrf RED` shows hold time 180 and the last-received time climbing; ispA still shows the session Established.
Fix: re-add `neighbor ... bfd` on both, `./lab.sh grey off` (or `./lab.sh restore`).

**T7 Max-prefix set below what the provider sends.** bleaf2 BLUE to ispB has `maximum-routes 2`; ispB sends 4.
Isolate: `show ip bgp neighbors 172.16.22.6 vrf BLUE` shows the session was reset for exceeding the limit.
Fix: set the limit with headroom (the reference uses 1000) and use EOS's warning threshold option for alerts before the hard limit (check exact syntax with `neighbor X maximum-routes ?` on your release). Lesson: max-prefix is a safety net sized for the provider's documented behavior, not for today's count.

## Part D

1. **Full tables on the borders.** Gains: per-destination exit selection and better inbound visibility. Costs: about a million routes per VRF per border, slow convergence, and the fabric still sees only a default unless you redistribute. Recommendation: default plus a partial table (provider-originated and their customers' routes) if you need optimization; full tables only on a dedicated edge router, not on a border leaf.
2. **Add-path toward the fabric.** Leaves see both exits and can fail over without waiting for the border to re-run best path and re-advertise. That is faster convergence and real backup paths. Communities only signal preference on the single path each border chooses. Costs: more EVPN state, and a leaf platform that must support add-path receive.
3. **Second ispA circuit to bleaf2.** Keep RED on ispA with MED (bleaf1 50, new circuit 100); keep `65020:80` toward ispB on every RED session. Add BFD on the new circuit. A single circuit loss then moves RED inbound to the other ispA circuit, never to ispB.
