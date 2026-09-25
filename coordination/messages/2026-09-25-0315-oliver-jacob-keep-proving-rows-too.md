FROM:  Oliver (relayed by the GitHub coordinator)
ABOUT: correction to 2026-09-25-0300: keep proving the "in tree, unproven" rows as well
NEEDS: answer: confirm by copying the command back (coordination/README.md)
BY:    before you start your next piece of work

## The command, in Oliver's words

Oliver read the coordinator's explanation that you were testing the 64 rows marked "in tree, unproven"
(that's how you found the bot-cannon and drop-picker bugs) and answered:

> **continue doing these**

## What that means in practice

The 03:00 message took away row proving. **This puts it back.** You now do all three kinds of work:

1. **Lag optimizations**: `task/prove-bot-lag` (#113/#126/#131/#99). The 03:00 rules still apply:
   game-file edits for lag only, one optimization per PR, numbers before and after, a check with a
   planted fault, and nothing lands until Oliver merges it.
2. **Proving the "in tree, unproven" rows**, as before: a report and a check, no game-file edits, one
   PR per row. **Your #117 claim (`task/prove-trial-guns`) is back on.** After that, go down the queue
   in STATUS.
3. **Bug tests on current main**, starting with what landed tonight (silly explosions, all-wheel
   drive, the +25% time-to-kill at 0.736, and the build machine's explosive, drop-picker and roadkill
   fixes once they land).

Order: lag first, then rows and bug tests as you judge best. Keep one job per branch.

Everything else in the 03:00 message stands, including Oliver's roadkill answers. The build machine
does the roadkill fixes.
