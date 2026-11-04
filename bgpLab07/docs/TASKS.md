# Lab 07 Tasks

## Part A: Build the policy (deploy `base`)

The fabric, the EVPN overlay, all four VRFs, the L2VNIs and the SVIs are up. Every VRF imports only its own route-target, so the tenants are completely isolated: intra-VRF works and nothing else does.

Run `./lab.sh verify` and then `./lab.sh matrix`. The grid should be diagonal. Your job is to turn it into the policy matrix in the README, and not one cell more.

| # | Task | Done when |
|---|---|---|
| A1 | Shared services, spoke side. Every tenant VRF imports SHARED's RT. | `hR1`, `hB1` and `hG1` all reach `10.100.100.10`. |
| A2 | Shared services, hub side. SHARED imports all three tenant RTs. | `hS1` reaches a host in every tenant. Note that A1 alone gave you a one-way service. |
| A3 | Prove you did not break isolation. | `hG1` still cannot reach RED or BLUE. `hR1` still cannot reach GREEN. |
| A4 | Fusion handoff. On bleaf1, a dot1q subinterface per fused VRF toward fw, and eBGP in each VRF. fw is already configured. | Both sessions Established in `show ip bgp summary vrf all`. |
| A5 | Fusion policy. RED hands out only RED's prefixes and accepts only BLUE's, and the mirror for BLUE. | `hR1` reaches `hB1`, and a traceroute shows 172.16.x.2 in the path. |
| A6 | Full matrix. | `./lab.sh verify` all PASS, including every isolation assertion, and `./lab.sh matrix` matches the README table exactly. |

Questions before Part B:

1. After A1 and before A2, a tenant could send packets to the shared-services host and got nothing back. Explain exactly which table was missing which route, and why an import is a one-way statement.
2. SHARED holds RED's prefixes and GREEN's prefixes at the same time. Why does that not give RED a path to GREEN? Name the specific behavior you are relying on, and say how you would verify it rather than assume it.
3. RED and BLUE could have been connected by importing each other's RTs, with no fw and no extra device. That would have been two lines of config instead of a fusion handoff. Give the reason the fusion is worth the complexity, and name the one thing RT leaking cannot do.
4. The fusion depends on `remove-private-as all` on fw. Walk the AS_PATH of 10.10.10.0/24 from leaf1 all the way back into BLUE's table and show where it would be dropped without it.
5. `hR2` is on leaf2 and reaches `10.10.11.1`, which only exists on leaf1. Name the VNI that carries that packet and the MAC that ends up as the inner destination.

## Part B: Leaking versus fusion (deploy `solution`)

**B1 Trace a leaked prefix.** Run `./lab.sh leak SHARED 10.10.10.0/24`. Identify the route-target on the EVPN route and the line of config that caused it to be imported. Then do the same for `./lab.sh leak RED 10.100.100.0/24` and state which direction each import serves.

**B2 Host routes come along too.** Symmetric IRB means type-2 MAC-IP routes carry a /32. Look at `show ip route vrf SHARED` on leaf2 and count what you actually imported from RED: the subnet, or the subnet plus every host. Decide whether that matters at 40 leaves and 4000 hosts, and what you would do about it.

**B3 Make the fusion earn its place.** On fw, block RED from reaching `10.20.20.101` specifically while leaving the rest of BLUE reachable. Then try to express the same rule with route-targets alone. Write down why you cannot, in one sentence. That sentence is the answer to A3's question.

**B4 Overlapping address space.** Add a second GREEN subnet on leaf2 using `10.10.10.0/24`, the same subnet RED already uses, on a new VLAN with its own L2VNI. Both tenants are isolated so this is legal. Now look at `show ip route vrf SHARED` on leaf2 and explain what happened to shared-services reachability for RED and for GREEN. Then give three ways out and pick one, saying what it costs.

**B5 Add a fourth tenant.** Write out every line needed to add tenant YELLOW with one subnet on leaf2, reaching SHARED and nothing else. Count the devices you had to touch. Then write what you would have to touch to give YELLOW fusion access to RED as well, and compare.

**B6 Prove the isolation, properly.** `./lab.sh matrix` tests the data plane from five hosts. That is evidence, not proof. Describe what you would check in the control plane on every leaf to assert that GREEN cannot reach RED, independent of whether a host happens to be up, and turn it into something you could run on a schedule.

## Part C: Troubleshooting (deploy `solution`)

```bash
./lab.sh verify          # baseline all PASS
./lab.sh break random    # or a number 1-8
```

Symptoms in `docs/TICKETS.md`. Start with `./lab.sh verify`, then `./lab.sh matrix` to see the shape of the damage, then `./lab.sh rts` if it smells like a route-target problem.

One of these eight is a security finding with no outage attached. One is a one-way failure, which is the signature of an asymmetric import. The rest break something a user will notice.

## Part D: Design review (no config)

1. You are asked to standardize on one inter-VRF mechanism for a new fabric. Give the honest case for RT leaking and for a centralized fusion, and name the workloads you would route each way.
2. The fusion device is a single point of failure for all RED-to-BLUE traffic. Describe the redundant design, and say what has to be true about traffic symmetry if the fusion is a stateful firewall.
3. At 30 tenants, hub-and-spoke RT leaking means the SHARED VRF imports 30 route-targets and holds every tenant's prefixes. Name the two limits you would hit first and the mitigation for each.
4. Security asks for a document proving tenant isolation. Describe what you would hand them: what you assert, what evidence you attach, and what you explicitly do not claim.
5. A tenant asks for internet access. Explain where that fits relative to the shared-services leak and the fusion, and why giving each tenant its own default route is not the same problem as giving them shared services.
6. Someone proposes replacing the fusion with RT leaking plus ACLs on every leaf, arguing it removes a device. Evaluate that honestly, including the cases where they are right.
