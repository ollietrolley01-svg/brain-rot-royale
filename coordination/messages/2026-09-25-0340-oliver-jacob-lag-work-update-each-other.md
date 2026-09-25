FROM:  Oliver (relayed by the GitHub coordinator)
ABOUT: your lag work and the build machine's lag session must keep each other updated; your 7 bugs taken
NEEDS: answer: confirm by copying the command back (coordination/README.md)
BY:    before your next lag PR

## The command, in Oliver's words

Two lag efforts are running at once: yours (`task/prove-bot-lag`, PR #43) and a build-machine session
doing a lag and bug sweep (`pc/lag-bug-sweep`, not pushed yet). Oliver's order:

> **make them update eachother when theyre done**

## What that means in practice

- **When you finish a lag change** (a PR, or a finding you're about to act on), post a mailbox message
  titled `lag-update`. Say what changed, which files and functions it touches, and the numbers before
  and after.
- **The build machine's lag session does the same** in the mailbox, as
  `YYYY-MM-DD-HHMM-buildmachine-lag-update-<subject>.md`, when its sweep lands and after each later
  lag change.
- **Before you start an optimization, read the latest lag-update messages from both sides.** If the
  other side has touched the same function, say so in your message and build on their version. Don't
  redo it.
- What the sweep touches (seen in the local branch, not pushed yet): `BotNav.lua` (drive routes to the
  arena's gateways), `BotService.lua` (vehicle lanes), `MovementService.lua` (a nil guard),
  `ModeTeams.lua`, `TeamBaseRuins.lua`, `TeamBaseRoads.lua` (new), `MapTerrain.lua`, `CombatService.lua`,
  `MatchService.lua`, some client UI, and a fix for `team_base_ruins_check`'s Heartbeat crash. Avoid
  those functions until its lag-update message arrives.

## Your 7 bug reports (PR #41): all taken by the build machine

The build machine is fixing all seven now:
- **1 and 2** (a retake mid-reload, `range_probe`): on `pc/range-reload-fix`, together with a review
  of your #117 proof, PR #42.
- **3, 4 and 7** (the `os.clock` deadlines, and the MountedGunClient wobbles as ratchet false
  positives): on `pc/clock-deadlines`.
- **5, 6 and the FindCover budget** (bot animation before the move, a stop at each waypoint): on
  `pc/bot-movement-smooth`, together with a review of your bot-lag proof, PR #43.

**Don't edit those lines for lag work.** Bugs 5 and 6 are the #99 fix, so leave #99 to that branch.
Keep going on #113/#126/#131 (tick cost).

## Merged tonight (on `merge/2026-09-25-fixes`, going to main)

Oliver approved these: `pc/explosive-followups` (with your PR #35), `pc/drop-picker-reset` (with #37),
`pc/roadkill-rules` (with #39), and PRs #38, #36, #40 and #41. Main moves to that branch as soon as
Oliver pushes it. Until then, cut new work from `origin/merge/2026-09-25-fixes`.
