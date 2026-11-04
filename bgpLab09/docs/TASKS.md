# Lab 09 Tasks

## Part A: Measure the untuned fabric (deploy `base`)

The fabric forwards. Nothing about its failure detection or path redundancy has been configured: default 60/180 timers, no BFD, `maximum-paths 1`. Before you read anything else, find out what that costs.

```bash
./lab.sh deploy base
./lab.sh verify          # everything forwards
./lab.sh measure hard
./lab.sh measure grey
./lab.sh measure wan
./lab.sh measure drain
```

| # | Task | Record |
|---|---|---|
| A1 | Run all four scenarios and write down packets lost for each. Each lost packet is about 200ms. | four numbers |
| A2 | `grey` will run past the end of the ping. Work out why, and what number it would have been if the ping had been long enough. | the real number |
| A3 | Explain why `hard` and `grey` differ so much when the traffic outcome is identical. | one paragraph |
| A4 | `drain` should cost nothing and does not. Explain what it is actually waiting for. | one paragraph |

Questions:

1. `hard` and `grey` both mean "traffic to spine1 disappears." Name what detects each one, and say why one of them has no detector at all in `base` mode.
2. With `maximum-paths 1`, what does a leaf do with the second path it has learned and not installed? Is it in BGP? Is it in the FIB? What has to happen before it is used?
3. The default hold time is 180 seconds. Where does that number come from, and what is the relationship between hold time and keepalive?
4. `drain` prepends spine1's advertisements and traffic still stops. In `base` mode, name the specific reason the prepend did not help.

## Part B: Tune it (still on `base`, or deploy `solution` to compare)

Build the tuned configuration yourself on `base`, then compare against `solution`.

| # | Task | Done when |
|---|---|---|
| B1 | Fast detection on every fabric session, both directions. | BFD peers Up on all five switches, counts matching the topology. |
| B2 | A sane fallback for when detection is not available. | Negotiated hold times are 30s or less on the fabric sessions. |
| B3 | Path redundancy that is actually installed, not just learned. | Each leaf shows two underlay next hops to a remote VTEP. |
| B4 | The same, inside the VRF. The global setting does not cover it. | The default route in VRF RED resolves via two VTEP next hops, one per border. |
| B5 | Both edge sessions too. They are not in the fabric peer group and were not tuned by B1 or B2. | Each border's WAN session has detection and a short hold time. |
| B6 | Re-measure all four scenarios. | Four new numbers, next to the Part A numbers. |

Questions:

5. BFD without ECMP and ECMP without BFD both leave you with an outage, for different reasons. Describe each.
6. You configured BFD at 300ms x 3. Justify that number, then say what you would actually deploy on hardware carrying production traffic and why it is different.
7. The two ends of a BGP session negotiate the hold time. If one end says 9 and the other says 180, what is used? What does that mean for a change you can only make on your own side?
8. After B1 to B5, `drain` should cost close to nothing. Explain the mechanism, and why draining is categorically different from failing.

## Part C: Eight faults, all at once (deploy `solution`)

```bash
./lab.sh deploy solution
./lab.sh verify          # clean baseline
./lab.sh break           # all eight
./lab.sh verify
```

Every fault is a regression from the baseline you just verified. They interact: two hide behind a third, and one is only visible on a device that reports no problem of its own.

Rules:

- `verify` is your progress bar and nothing more. It states what it observed against what it expected. It will not tell you what to change.
- Before touching any config, collect the observed state from every device into a table: detection state, negotiated timers, installed path counts. Do this once, properly. The outliers are the work.
- Write the root cause of each fault in one sentence before you fix it.
- `./lab.sh hint` exists. Using it is a choice, not a step.

Target: all eight in 45 minutes. A reasonable first attempt is 90.

When you are done, re-run all four `measure` scenarios. If any of them is slower than your Part B numbers, you missed one.

## Part D: Design review (no config)

1. Your production fabric has 120 leaves. You are asked to deploy BFD on every underlay session. Give the numbers you would propose (interval, multiplier), the control-plane cost you are accepting, and how you would roll it out.
2. BFD and short BGP timers both speed up detection. Explain why you would deploy BFD and leave BGP timers longer rather than just setting BGP timers to 1/3 everywhere.
3. A vendor tells you their platform supports BFD in hardware on some ports and in software on others. Describe how you would find out which, and what you would change in your design if the answer were "software on the uplinks."
4. Write the maintenance procedure for taking a spine out of service in this fabric. Every step, including verification, including what you check before you touch anything and how you know the drain worked.
5. Your monitoring alerts on BGP session state. Name three convergence problems in this lab that it would not catch, and the metric you would add for each.
6. A grey failure took 180 seconds to detect and the post-incident review asks why the network did not notice. Explain, to a non-network audience, why carrier-up-but-traffic-gone is a different problem from a cable being unplugged, and what you are proposing to fix it.
