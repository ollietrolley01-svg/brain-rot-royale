# task/bot-gunners (task 20: bot gunners engage better)

**Cut from `origin/pc/lag-bug-sweep` at cf35aa3, not from main, and the PR targets `pc/lag-bug-sweep`** (PR #58's
precedent): the sweep rewrites `Vehicles.gunnerThink` and takes bots off vehicle guns in the battle royale, so
this only makes sense on top of it. After the sweep merges, it matters in the team modes and on the stationary
guns (the emplacements), which is where bots man guns.

## What changed from cf35aa3

- `ServerScriptService/Modules/BotService.lua`
  - `Vehicles.gunReach` (new): a mount's reach is its spec's `range`, never less than `BotVisionRange` (a
    launcher's spec has no range, so launchers keep 260).
  - `Vehicles.gunnerTarget` (new): the gunner's target is `findTarget`'s pick; when that finds nobody and the gun
    reaches further, the nearest enemy past vision range, inside the mount's arc and in sight, out to the reach
    (whoever is shooting at it first). At most two fresh sight rays a think; `findTarget` is untouched.
  - `Vehicles.gunnerThink`: uses `gunnerTarget`, and turns the turret to where its shot will go
    (`VehicleWeapons.BotAimPoint` for a rolled hit: a round's lead and a lob's arc), not to where the target stands.
  - `Vehicles.vehicleHitChance`: the hand-gun distance falloff is stretched over the gun's reach
    (`distance * BotVisionRange / gunReach`). A gun with the vision range, and every launcher, is the old dial exactly.
  - `Vehicles.vehicleTrigger`: bursts are sized to the gun's `fireRate` (about a second of fire, 6 bullets at
    least; 2-3 rounds), and rests are three to five shots' worth at that rate (1.5-2.5 rounds' worth) instead of
    a flat `BotBurstRest` 0.48-0.83 s or 1.0-1.8 s. The belt's cooling is unchanged.
  - `Vehicles.considerVehicle` / `Vehicles.fightOnTheWay` (new), task 21's finding: a bot walking to a seat
    shoots whoever it sees within its gun's range on the way, and gives the walk up once someone it doesn't
    share a vehicle with has got into that vehicle. `considerVehicle` now takes `head`.
- `ServerScriptService/Modules/VehicleWeapons.lua`: `BOT_LEAD` 0.7 -> 1. The hit roll already decides a miss,
  so leading only 70% of a runner's move was a second penalty (the orchestrator's call, option A).
- `tools/bot_gunner_engage_check.py` (new): the offline proof, before/after table and 11 planted faults.
- `tools/bot_gunner_probe.lua` (new): the Studio probe and gallery (Run mode; bots board by themselves).
- `tools/bot_driving_combat.py`: loads `gunReach`; `DIAL` compares against the stretched on-foot dial; `BURSTS`
  counts rests of three shots' worth at the gun's rate; the "no rest" plant matches the new line.
