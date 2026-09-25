# What is claimed, and what is free

Maintained by the GitHub coordinator (Oliver's Claude on the build machine; it took over from
claude-43). **Read this before you pick anything up.** A claim listed here is a claim, even if the
task file or the OLIVER_LIST row has not been updated yet.

Last updated: 2026-09-25 01:08 (EDT).

## What changed since 2026-09-22

- **The 09-22 STOP is over.** `STOP.md` was removed on main (ffc0e1c). Work is running again.
- **The game is now called Brainrot Battles** (menu title on main, f9ddce2). Saved data keeps its old
  internal key, so nobody loses progress.
- **The 14-agent fleet is gone.** The build machine now works in **`pc/*` branches** (one feature per
  branch) and merges each into main when it's done. Every `pc/*` branch pushed so far is already on main.
  Cloud sessions (`claude/*` branches, PRs #15-#28) landed a lot of OLIVER_LIST rows on 09-23/24. Those
  rows are marked **"in tree, unproven"**. 64 rows carry that mark.
- **Tasks 01-07 are all claimed or done.** `tasks/` has nothing open. The open work now is proving the
  "in tree, unproven" rows (see below).
- Playtest releases are on GitHub Releases. The latest is `playtest-2026-09-24-2000` (main 8f16a5f).

## Claimed right now

| Who | What | Branch | State |
|---|---|---|---|
| Jacob (bimjom) | #84/#109 car-bounce proof | `task/prove-car-bounce` (PR #31) | **Merged to main 09-25 (36aa63a).** #84/#109 stays unproven until a playtest `[VehicleJolt]` count |
| Jacob (bimjom) | #97 hit-registration proof | `task/prove-hitreg` (PR #33) | **Merged to main 09-25.** Both fire-rate faults fixed on main (1e964ca); new bugs F3 (phantom end-of-mag shots) and F4 (vehicle guns still quantised) reported |
| Jacob (bimjom) | #76/#77 playtime + daily-streak proof | `task/prove-playtime-streak` (PR #34) | **Merged to main 09-25.** Payouts hold; spectators barely paid since a2ba3b4 (design question for Oliver) |
| Jacob (bimjom) | #122 explosive-ammo proof | `task/prove-explosive-ammo` | Claimed 09-25 01:01 (PR #32) |
| Jacob (bimjom) | #107 vote-menu-mid-match proof | `task/prove-vote-menu` | Claimed 09-25 01:03 (2731d7a, merged with PR #32). After #122 |
| Dalton | Brainrot Battles icon: a 4x4 grid of candidates | `art/icon/` or mailbox | Asked 09-22 20:46, no reply yet |

## Recently changed on main: expect these to move under you

The build machine touched these in the last day. Read-only is fine; if a proof needs a change here,
report it in the mailbox and don't edit.

- Vehicles: `VehicleService.lua`, `VehicleDynamics.lua` (parked-rest a1eb7a8, base-vehicle respawn b5cbc05)
- Bots: `BotService.lua`, `BotGunner.lua` (new), `BotDriveTactics.lua`, `MountedGun*`
- Team modes: `ModeTeams.lua`, `TeamBattleground.lua`, `MatchConfig.lua`
- Lobby, roundabouts, interiors, wall durability, shed loot (the `pc/*` names on the branch list)

## The rule that hasn't changed

**Contributors from outside don't edit game files.** You write reports, checks, probes and new files. A
bug you find goes in the mailbox with the file and line. The build machine owns the fix. Proofs that
end in "no bug, here is the evidence" count as much as fixes do.

## Good next work: only NEW, USEFUL work (Oliver, 2026-09-25)

Every OLIVER_LIST row has been built. **Don't build anything that's already on main.** The useful
work is proving rows marked "in tree, unproven" and reporting bugs nobody has found yet. Before
claiming, check STATUS, `git log origin/main --grep`, and the row itself (see
`messages/2026-09-25-0120-oliver-jacob-only-new-useful-work.md`). Priority order:

1. #122 explosive ammo (6ef6a52), claimed, Jacob
2. #107 game-choosing menu mid-match (81c1263, fefa725), claimed, Jacob (after #122)
3. #57/#110 roadkill (32de759, 41631ba)
4. #113/#126 bot lag, #99 movement looks low-fps

Claim a row with a one-line mailbox message before you start, as before.
