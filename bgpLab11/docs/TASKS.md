# Lab 11 Tasks

## Part A: Baseline (deploy)

```bash
./lab.sh deploy
./lab.sh verify          # everything green
./lab.sh survey          # save this output somewhere
./lab.sh sizes h2 10.10.20.1
```

| # | Task | Record |
|---|---|---|
| A1 | Save the clean `verify` output. You will want to diff against it. | a file |
| A2 | Save the clean `survey` output, reduced to a table: one row per device, columns for session counts, VNI mappings, installed next hops. | the table |
| A3 | Record the clean packet-size ceiling. | one number |
| A4 | Drain bleaf1 and confirm bleaf2 takes over for both VRFs. Undrain. | confirmed |
| A5 | Drain spine1 and confirm the fabric survives on spine2. Undrain. | confirmed |

A4 and A5 are not busywork. Two of the eight faults are only visible with something drained, and if you have never seen the clean behaviour you cannot tell broken from normal.

## Part B: Eight faults (the lab)

```bash
./lab.sh break
./lab.sh verify
```

Rules:

- `verify` reports observed versus expected and nothing else.
- Collect `survey` again and diff it against your A2 table **before** changing anything.
- Write the root cause of each fault in one sentence before fixing it.
- Fix one at a time and re-verify. Two of these interact, and fixing one will appear to make things worse. That is information, not a mistake.
- `./lab.sh hint` is there. Using it is a choice.

Checkpoints, so you know whether you are on track:

| After | You should have |
|---|---|
| 15 min | the survey diff, and three faults identified from it alone |
| 30 min | five faults fixed, verify mostly green, and a strong feeling you are finished |
| 45 min | the realisation that you are not |
| 90 min | eight |

When `verify` is green, ask yourself these three questions before declaring victory. Each one corresponds to a fault that produces no symptom:

1. If I drain bleaf1 right now, does everything still work for **both** VRFs?
2. If I drain spine1 right now, does every leaf still have full overlay reachability?
3. Does every leaf still have two underlay next hops to every remote VTEP?

If any answer is no, you have a latent fault and your green `verify` is a false negative. That gap, between "nothing is currently broken" and "nothing is broken", is what this lab is about.

## Part C: Design review (no config)

1. Three faults in this lab were invisible until something was drained. Design the monitoring that would have caught each one in production, and be specific about the metric, not the intent.
2. One fault passed every ping and failed only at size. Explain what class of real-world symptom that produces, why it is usually reported as an application problem rather than a network problem, and what you would add to a standard turn-up test to catch it.
3. Two faults masked each other. Describe how you would structure a troubleshooting approach so masking does not cost you an hour, and what you would record as you go.
4. One fault made a host reach something it should not. Explain why no availability monitoring would ever catch it, and what kind of check would.
5. Your `verify` script went green with three faults still live. Write the honest sentence you would put in a change record about what "verified" means, and what you would add to make it mean more.
6. Pick the fault you found last. Write the five-line runbook entry that would let the next engineer find it in ten minutes instead of an hour.
