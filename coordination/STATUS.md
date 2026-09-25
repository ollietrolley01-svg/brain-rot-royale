# What is claimed, and what is free

Maintained by the GitHub coordinator (Oliver's Claude on the build machine; it took over from
claude-43). **Read this before you pick anything up.** A claim listed here is a claim, even if the
task file or the OLIVER_LIST row has not been updated yet.

Last updated: 2026-09-25 03:00 (EDT).

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
| Jacob (bimjom) | #97 hit-registration proof | `task/prove-hitreg` (PR #33) | **Merged to main 09-25.** Both fire-rate faults fixed on main (1e964ca); F1-F4 **fixed on `pc/hitreg-fixes`** (b254eac, waiting on Oliver's merge) |
| Jacob (bimjom) | #76/#77 playtime + daily-streak proof | `task/prove-playtime-streak` (PR #34) | **Merged to main 09-25.** Payouts hold. Oliver decided spectator pay: **all time in the server counts** (pc/playtime-all-time, on main) |
| Jacob (bimjom) | #122 explosive-ammo proof | `task/prove-explosive-ammo` (PR #35) | **Done, awaiting Oliver's merge.** Players' explosive guns all reach the blast. Found: a bot's Golden Sahur Cannon never explodes (BotService `shootAt`); `explosive_ammo_check.py` crashes on main since d370e62. Row stays unproven for the on-screen look |
| Jacob (bimjom) | #107 vote-menu-mid-match proof | `task/prove-vote-menu` (PR #37) | **Done, awaiting Oliver's merge.** No path opens the vote or team picker over a match. Latent: the failed-start fallback never clears `dropSelect` (build-machine fix) |
| Jacob (bimjom) | playtime proof cut to the all-time rule | `task/playtime-proof-new-rule` (PR #38) | **Done, awaiting Oliver's merge** |
| Jacob (bimjom) | #57/#110 roadkill proof | `task/prove-roadkill` (PR #39) | **Done, awaiting Oliver's merge.** Fires for player and bot drivers. Oliver's calls (03:00 message): spawn protection removed; armour protects riders; the damage scale applies with no driver. The build machine does the fixes |
| Jacob (bimjom) | #113/#126/#131/#99 lag: **optimize**, not just prove | `task/prove-bot-lag` | Claimed 09-25 02:22. Game-file edits allowed for lag work only (rules in the 03:00 message) |

## Recently changed on main: expect these to move under you

The build machine touched these in the last day. Read-only is fine; if a proof needs a change here,
report it in the mailbox and don't edit.

- Vehicles: `VehicleService.lua`, `VehicleDynamics.lua`, `VehicleModels.lua` (parked-rest a1eb7a8, base-vehicle respawn b5cbc05,
  ride lift and rough-ground underside 52a5608, on main at 05437cf)
- **Merged to main since the last update:** `pc/hitreg-fixes` (`LagCompensation.lua`, `CombatService.lua`
  rider cover, `CombatClient.client.lua` round count, `VehicleWeaponClient.client.lua` fire gate, the hitreg tools)
  and `pc/mounted-guns-powerful` (`MountedGunData.lua`, `VehicleWeaponData.lua`, `mounted_guns_check.py`,
  `vehicle_ttk_check.py`: Oliver wants the ground and car guns very powerful)
  and `pc/ttk-plus-25` (stacked on the guns branch: `MatchConfig.CombatDamageScale` 0.92 -> 0.736, so every
  kill of a player, bot, vehicle or mounted gun takes 25% longer; companion caps x0.8; the TTK bands in
  `vehicle_ttk_check`, `mounted_guns_check` and `companion_ability_check` x1.25)
- **Tonight, the build machine:** silly explosions (57fd4f0, f9f0af6), all-wheel drive (47200d3), and now
  fixes to `BotService.lua` (bot cannon blast), `ProjectileService.lua`/`CombatService.lua` (explosive follow-ups),
  `MatchService.lua`/`VoteDropClient` (drop picker), `VehicleService.lua`/`GameModes.lua` (roadkill, spawn protection)
- Bots: `BotService.lua`, `BotGunner.lua` (new), `BotDriveTactics.lua`, `MountedGun*`
- Team modes: `ModeTeams.lua`, `TeamBattleground.lua`, `MatchConfig.lua`
- Lobby, roundabouts, interiors, wall durability, shed loot (the `pc/*` names on the branch list)

## The rule (changed by Oliver, 2026-09-25 03:00)

**Contributors from outside don't edit game files, except for lag optimizations** (one per PR, with
before/after numbers and a check; nothing lands until Oliver merges). Bugs go in the mailbox with the
file and line. The build machine owns the fix.

## What to work on (Oliver, 2026-09-25 03:00: "just have jacob run bug tests and optimizations for lag")

The task list is done. **Don't pick up OLIVER_LIST rows to prove.** Only two kinds of work:

1. **Lag optimizations**: #113/#126/#131 bot lag and #99 movement, claimed by Jacob.
2. **Bug tests on current main**: run the checks and harnesses and report new bugs. Start with what
   landed tonight: silly explosions, all-wheel drive, the +25% time-to-kill (0.736), and the build
   machine's explosive, drop-picker and roadkill fixes when they land.

Claim with a one-line mailbox message before you start, as before.
