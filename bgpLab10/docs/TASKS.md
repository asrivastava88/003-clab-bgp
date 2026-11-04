# Lab 10 Tasks

## Part A: Look at what you accepted (deploy `base`)

Sessions are up and there is no policy anywhere. Before building anything, find out what an unprotected edge actually holds.

```bash
./lab.sh deploy base
./lab.sh inbound
./lab.sh outbound
```

| # | Task | Record |
|---|---|---|
| A1 | List every prefix in edge1's and edge2's tables that has no business being there. | the list |
| A2 | For each one, say which neighbour sent it and what category of junk it is. | a table |
| A3 | One prefix in cust2's announcement is rejected even with no policy configured. Find it and explain why. | the prefix and the mechanism |
| A4 | Look at what `transit` and `peer1` now hold. You are leaking. Say exactly what you are leaking to whom, and what it would cost you if this were real. | two sentences |
| A5 | `cust1` is holding the full table. Say why that is a commercial problem as well as a technical one. | one sentence |

Questions:

1. You can write a prefix-list of everything `cust1` is allowed to announce. You cannot write one for `transit`. Explain the difference, and say what you filter on an upstream session instead.
2. `cust2` is announcing your own address space. Name two independent controls that should stop it, and say which one would still work if `cust2` were announcing a *third party's* space instead.
3. A4 showed you leaking. Name the single property of an egress policy that prevents every leak in this lab, and say what the opposite looks like in config.
4. Which of the junk prefixes would a prefix limit have caught, and which would it have missed? What does that tell you about where a prefix limit belongs in the order of defences?

## Part B: Build the edge (still on `base`)

| # | Task | Done when |
|---|---|---|
| B1 | Bogon deny on every eBGP ingress, no exceptions. | `10.0.0.0/8` and `192.168.50.0/24` are absent from edge1. |
| B2 | Own-space deny on every eBGP ingress. | `203.0.0.0/16` has no externally-learned path on edge2. |
| B3 | Registered prefix filter on customer ingress only. | edge2 holds `207.0.0.0/16` and its two registered more-specifics, and nothing else from cust2. |
| B4 | Egress default-deny toward transit and peers, and a default only toward customers. | `transit` holds no `205.0.0.0/16` from us; `cust1` holds one prefix. |
| B5 | Prefix limits sized per neighbour class. Find out what the warning threshold option is called on your build and set it. | configured, with a number you can justify |
| B6 | **Research.** Session authentication. Find the command with `?`, work out the argument form, and apply it to one session end to end. | the session stays up with authentication on both ends |
| B7 | **Research.** TTL security / GTSM. Find out whether your build has it and what it is called. Apply it to a directly-connected eBGP session. | applied, or a written finding that it is unavailable |
| B8 | **Research.** AS-path filtering. Find the command that creates an AS-path list, then build a filter that rejects any path longer than 20 ASes. | a long-path announcement is rejected |

Questions:

5. B6 and B7 both protect the session rather than the routes. Explain what each defends against, and which you would deploy first on a directly-connected eBGP session.
6. B5 asked you to justify a number. Justify it: what happens if it is too high, what happens if it is too low, and which failure would you rather have at 3am?
7. Your bogon list is static. Name the maintenance problem that creates and two ways real networks deal with it.
8. You now have five layers. Put them in the order BGP evaluates them for an inbound route, and say which ones never run if an earlier one matches.

## Part C: Eight faults, all at once (deploy `solution`)

```bash
./lab.sh deploy solution
./lab.sh verify          # clean baseline
./lab.sh break           # all eight
./lab.sh verify
```

Rules:

- `verify` reports observed versus expected. It will not tell you what to change.
- **Four of the eight are invisible from your own tables.** `./lab.sh outbound` checks at the receiver. Use it early.
- Two pairs are the same mistake applied to two different neighbour classes. Fixing one and moving on leaves you half done.
- Write the root cause of each in one sentence before fixing it.
- `./lab.sh hint` exists. Using it is a choice.

Target: all eight in 45 minutes.

## Part D: Design review (no config)

1. Write the inbound policy you would apply to a brand-new transit provider on day one, before you know anything about them. Then write the inbound policy for a brand-new customer. Explain every difference.
2. RPKI route origin validation would have caught one thing in this lab that none of your filters did. Identify it, explain what ROV checks, and name what it does **not** check.
3. Your bogon list will be wrong within a year. Design the process that keeps it right, including who owns it and how you know it drifted.
4. A customer calls at 2am: their session is down and they say they changed nothing. Your prefix limit tripped. Walk through what you check, what you tell them, and what you do if they are right that they changed nothing.
5. You have 400 eBGP customers. Describe how the policy in this lab is applied at that scale without 400 hand-written route-maps, and what the generated-config approach costs you when something is wrong.
6. RFC 9234 defines BGP roles and the Only-To-Customer attribute, which makes leaks like faults 6 and 7 detectable by the protocol rather than by policy. Explain the idea, find out whether your build supports it, and say whether it would replace or supplement what you built in Part B.
7. Two of this lab's faults are a leftover permit clause added "temporarily" during a change. Design the control that makes that class of mistake impossible to leave behind, and be specific about what enforces it.
