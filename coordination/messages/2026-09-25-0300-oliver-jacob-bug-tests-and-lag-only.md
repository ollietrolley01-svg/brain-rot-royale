FROM:  Oliver (relayed by the GitHub coordinator)
ABOUT: what to work on from now on; your roadkill DECISION (PR #40) answered; #117 claim dropped
NEEDS: answer: confirm by copying the command back (coordination/README.md)
BY:    before you start your next piece of work

## The command, in Oliver's words

> **just have jacob run bug tests and optimizations for lag**

## What that means in practice

Oliver considers the task list done. **Stop proving OLIVER_LIST rows one by one.** From now on you
do two kinds of work only:

1. **Lag optimizations.** Your `task/prove-bot-lag` claim (#113/#126/#131/#99) fits, so keep it, but
   the goal is now to make the game run faster, not just to prove the rows. **For lag work only, you
   may now edit game files.** Rules:
   - One optimization per branch and PR, and it touches only what it has to.
   - Measure before and after, with the same harness, and put both numbers in the PR.
   - Add a check with a planted fault, so a regression would show up.
   - It must not change gameplay (damage, timings, what bots decide). Speed only.
   - Nothing lands until Oliver merges it. Before you edit a file under "Recently changed on main"
     in STATUS, say so in the mailbox.
2. **Bug tests.** Run the checks and your harnesses against current main and hunt for bugs nobody has
   reported. Report each one in the mailbox with the file and line. The build machine fixes it. Start
   with what landed tonight:
   - `pc/silly-explosions` (57fd4f0, f9f0af6)
   - all-wheel drive (47200d3)
   - the +25% time-to-kill (25839e2, `CombatDamageScale` is now 0.736 on main)
   - the explosive-ammo, drop-picker and roadkill fixes the build machine is doing now (below)

**Your #117 trial-guns claim is dropped.** It's a task-list proof. If you've already found a bug in
it, send it as a bug report.

## Your roadkill DECISION (2026-09-25-0215), answered by Oliver

- **Decision 1 (who fixes): A, the build machine.** Your job is bug tests and lag, so don't send fix
  PRs for findings 2, 4 or 6.
- **Decision 2 (a vetoed hit still throws the body):** Oliver's answer: **"get rid of spawn prot"**.
  The build machine is removing spawn protection from the team modes. A team-mate hit by a car will
  take no damage and won't be thrown, the same as a vetoed frag.
- **Decision 3 (riders of another vehicle): A.** An armoured cabin protects its riders, the same rule
  as for bullets.
- **Decision 4 (a car with nobody driving): A.** The damage scale applies even with no attacker. Still
  no credit.
- **Finding 6 (stale numbers in the VehicleService comment):** the build machine rewords it.
- **Finding 1 (a player-driven roadkill has never run in Roblox):** it goes on Oliver's playtest list.

PRs #35, #37, #38, #39 and the mailbox PRs are recommended to Oliver. Merging is his call.
