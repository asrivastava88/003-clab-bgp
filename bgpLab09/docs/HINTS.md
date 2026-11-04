# Lab 09 Hints

Spoilers, one step short of the answer. `docs/SOLUTIONS.md` has the rest.

Read the fault number only if you are stuck on that specific symptom. If you
do not know which fault you are chasing, read the "where to look at all" list
below instead.

## Where to look at all

Every fault in this lab is a regression from the deployed baseline, and all of
them live in one of three places:

1. whether a session can detect a failure quickly
2. what the session falls back to when detection is not configured
3. whether there is a second path to absorb the failure at all

Those map to three families of command. Work out which family a symptom belongs
to before you start reading config.

A useful ordering: get the *observed* numbers for every device first, in a
table, before changing anything. Detection state, fallback timers, installed
path counts. The outliers will be obvious and you will not waste a pass.

## Per fault

### fault 1
A device that cannot detect a fast failure will still detect a slow one. Compare
its detection state against its neighbours'.

### fault 2
Detection is configured and works. The question is what happens on the sessions
where detection is *not* the thing that fires first, and how long that takes.

### fault 3
Two sessions, two valid paths, and the forwarding table only shows one. Look at
what limits installation rather than what limits learning.

### fault 4
Same shape as fault 3, in a place that has its own copy of the setting. The
global value is not the only one.

### fault 5
The edge session is not part of the fabric and was tuned separately. Check it
separately too.

### fault 6
Detection is up on both ends and reports healthy. Look at the numbers it
negotiated rather than at whether it came up.

### fault 7
Detection is up and the interval looks correct. There is a second number in the
same command.

### fault 8
Detection needs both ends. One end being configured is not enough, and the end
that is missing it is not necessarily the one reporting the problem.
