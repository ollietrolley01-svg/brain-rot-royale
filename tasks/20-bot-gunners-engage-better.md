# Task 20: bots in gunner seats should fight better

**Files you own for this task:** in `ServerScriptService/Modules/BotService.lua`, `Vehicles.gunnerThink`
(line 4338), `Vehicles.vehicleTrigger` (line 3905) and `Vehicles.vehicleHitChance` (line 3874) only;
and a new check under `tools/`. **Read only:** `findTarget` (Jacob's `task/lag-findtarget` changed
it), `hasLineOfSight`, `BotGunner.lua`, `VehicleWeapons.lua`, `VehicleWeaponData.lua`.

## What was reported

Bots in the gunner seats should engage enemies better. Jacob relayed this from a 2026-09-25 playtest.

## How a bot gunner works now

- **Target.** `gunnerThink` calls the on-foot `findTarget` (line 1340). Its reach is
  `max(MatchConfig.BotVisionRange, the bot's hand gun's range)`: 260 studs, and it never considers the
  turret's own range (the Rotster Roof Gun's is 320). Candidates are people only. Task 21 covers why
  riders in cars are rarely seen.
- **Aim.** `VehicleWeapons.Aim(bot, candidate.root.Position)` turns the turret at where the target is,
  with no lead. The shot itself goes through `VehicleWeapons.BotAimPoint` (line 581), which leads by
  flight time times `BOT_LEAD`, so only rounds (rockets, grenades) are led.
- **Trigger.** `vehicleTrigger` fires bursts of 6-10 bullets or 1-2 rounds, then rests
  (`MatchConfig.BotBurstRest`, or 1.0-1.8 s for rounds), and stops at 15% of the belt to cool. It
  holds fire outside the mount's arc and inside a round's own splash.
- **Hit chance.** `vehicleHitChance` starts from `accuracyAt(distance)`, the hand-gun falloff, then
  takes 15% off for a fast target and 15% off when its own car goes over 30 studs a second. It
  corrects for the gun's spread cone.
- **Leaving.** A gunner with no target and no driver leaves after `VEHICLE.IDLE`.

Likely weak points, to measure rather than assume: the 260-stud vision cap on a longer-range gun, the
hand-gun accuracy curve on a turret, the long rests between bursts, and the missing lead on the
turret's visible aim.

## Conflicts

`pc/lag-bug-sweep` changes `gunnerThink` itself. **In battle royale it takes bots off vehicle guns
entirely** (`Vehicles.botGunners`), and it adds a storm exit. After it merges, this task is about team
modes and the stationary guns (`BotGunner`). `task/bot-gunner-wait` (PR #58) and
`task/blast-parachuters` are stacked on the sweep, and `pc/teambase-v2` changes `driverThink` and
`startRide`. Cut from the sweep once it merges. Oliver's 03:00 rule applies to game-file edits.

## Proof

Offline: `tools/mounted_guns_check.py`'s BOTS section and `tools/bot_driving_combat.py` already run
parts of this. Add scenarios: a gunner against a target at 100, 250 and 300 studs, standing and
running, and report shots fired, hits and time to kill before and after. Plant a fault aimed at an
invariant (a gunner never fires outside the mount's arc or into its own splash) and show it goes red.

Real behaviour: bots are server-side, so runtest's Run mode is enough for a probe that counts gunner
shots and hits per minute over 3 reps. The coordinator runs it. Whether it feels fair is Oliver's call.

Status: waiting on pc/lag-bug-sweep merging: it rewrites `gunnerThink` and takes bots off vehicle guns in battle royale, so the task's scope isn't known until it lands
