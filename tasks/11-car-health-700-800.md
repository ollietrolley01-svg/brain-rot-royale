# Task 11: cars destroyable at 700-800 health

**Files you own for this task:** `ReplicatedStorage/Shared/VehicleArmor.lua` (the `Models` table and
`DefaultHealth`) and `tools/vehicle_ttk_check.py` (its bands). **Read only:** `VehicleService.lua`,
`VehicleWreckFx.lua`, `ProjectileClient.client.lua`, `VehicleClient.client.lua`, `VehicleModels.lua`,
`VehicleDynamics.lua`.

## What Oliver asked for

"the cars need to be destroyable with like 400-500 health". Playtest, 2026-09-25. Jacob has since
moved the target to **700-800**, and that is the number this brief works to.

## What already exists

Cars can already be destroyed. `VehicleService.DamageVehicle` (line 1159) takes bullets, heavy rounds
and blasts, and `ApplyBlast` (line 1897) handles area damage. At zero health, `damageVehicle` (line
892) sets `Wrecked`, turns off every prompt and puts the riders out. The car stays where it is, dark
and smoking.

The gap is the numbers. `VehicleArmor.Models` gives cars 1,400-1,650, bikes 600-660, and the two
armoured cars 3,100 and 3,330. Those were set on 09-24 to Oliver's own ask ("not glass cannons but
not juggernauts": a car dies to 8-12 s of a Rare rifle and 3 rockets). On 09-25,
`MatchConfig.CombatDamageScale` 0.736 made every kill 25% slower, so a car now takes 10-15 s of the
rifle. The header of `VehicleArmor.lua` shows the working.

`tools/vehicle_ttk_check.py` on main prints what a car takes now, at 0.736: the Rare rifle (Bananini
Burst) does 171 a second firing and 110 with reloads, about 22.8 a shot and 616 a 27-round magazine,
and one direct rocket (Cappuccina) does 68.4 x 6.5 = 445. Today's cars take 12.1-13.6 s of the rifle
and 4 rockets.

At 700-800 health, worked from the same numbers (the 620-health scooter is 5.6 s in that table):

| Health | Rifle shots | Rifle time | Magazines | Rockets |
|---|---|---|---|---|
| 700 | 31 | about 6.0 s | 1.14 | 2 |
| 800 | 36 | about 6.7 s | 1.30 | 2 |

So a car goes from 4 rockets to 2, and from about 13 s of the rifle to about 6. Confirm these with the
check once the numbers move; they are estimates from its printed rates.

## Ask Oliver before changing numbers

This undoes Oliver's 09-24 health bands, so send him these questions through the mailbox first:

1. Does 700-800 apply to every car, or only the four ordinary ones? What happens to bikes (600-660
   today, which would sit close to a car) and the armoured pair? Should they keep their ratios to a
   car (bikes about 0.45x, armoured 2-2.5x)?
2. Does "destroyable" also mean the wreck should blow apart or disappear? Today a wreck stays
   standing, and PR #51 found that a wrecked drivable blocks its spot for the rest of the match. PR
   #60 (`task/wreck-blast`) makes the wreck blast fire as soon as `Wrecked` turns true. Before that
   fix, a distant wreck blasted late, when someone walked up to it. If playtesters never saw a car
   die, that may be what Oliver is describing.

Crash damage follows health on its own (`VehicleArmor.CollisionScale` divides by `CrashBasis`), so a
crash keeps its share. Bot bail and retreat (`BotDriveTactics.BAIL_HEALTH` 0.15, `RETREAT_HEALTH`
0.35) are shares of health and need no change.

## Conflicts

PR #60 (`task/wreck-blast`) changes `VehicleWreckFx`, `ProjectileClient` and `VehicleClient`.
`pc/lag-bug-sweep` changes `VehicleService` and `VehicleModels`. `pc/vehicle-rest` holds the reverted
14eebfd WIP (`VehicleVisuals`, `VehicleDynamics`, `VehicleModels`, `VehicleClient`). Do not bring any
of it back. `VehicleArmor.lua` itself is on no unmerged branch.

## Proof

This one is fully provable offline. `vehicle_ttk_check.py` recomputes every time-to-kill from
`WeaponData` and fails when a vehicle leaves its band. Set the new bands from Oliver's answers, move
the health, and paste the table before and after. Plant a fault: one car's health set outside the
new band must turn the check red. `mounted_guns_check.py` and `team_vehicles_check.py` also read
vehicle damage, so run them and paste their lines.
