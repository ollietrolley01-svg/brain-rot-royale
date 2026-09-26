# Task 21: bots don't shoot at cars

**Files you own for this task:** in `ServerScriptService/Modules/BotService.lua`, `hasLineOfSight`
(line 1023) only, plus a new check under `tools/`.
**Read only:** `CombatService.lua`, `VehicleService.lua`, `VehicleArmor.lua`, `VehicleModels.lua`.
`findTarget` is read only too: Jacob's `task/lag-findtarget` changed it.

## What was reported

Bots don't target cars. Jacob relayed this from a 2026-09-25 playtest.

## How target selection works

`findTarget` looks only at combatants from the spatial grid (`combatantsNear`), which are characters
with a humanoid. A vehicle is never a candidate, empty or driven. `hostile` (line 97) drops only the
bot's own fellow riders.

A rider in a car is a candidate, but usually fails the sight check. `hasLineOfSight` casts from the
bot's head to the target's `HumanoidRootPart`. It filters out the bot's **own** vehicle and looks past
window glass (`CombatService.DestructiblePassesThrough`), but the target's car body is not filtered.
A seated rider's root sits inside the car, so the ray usually hits a door or panel first and returns
not visible. An armoured car's glass is named `Armor*` and stops shots, so its riders are never seen.
The "hidden by a barricade" rule inside 120 studs covers barricades, not vehicles.

So the likely cause is that bots treat a car as cover for whoever is inside, and never as a target of
its own. Confirm it with a count of candidates dropped by sight while seated in a vehicle.

## Design questions for Oliver

- Should a bot shoot the **car** (damaging `VehicleHealth` through `VehicleService.DamageVehicle`), or
  only the riders through the glass? Explosives do 6.5x damage to vehicles (`VehicleArmor.Classes`),
  so a bot with a launcher is the natural counter.
- Should an empty car ever be a target? Probably not, apart from denying a base car in team modes.

## Default

Riders only: the target's car body stops blocking the sight ray to its riders, the way window glass already does, except an armoured cabin, which keeps protecting them (Oliver's roadkill decision 3 and the bullet rule). A bot shooting the car itself is a follow-up for Oliver. With this default the task changes `hasLineOfSight`, not `findTarget`, so it doesn't wait on `task/lag-findtarget`.

## Conflicts

Jacob's `task/lag-findtarget` (d96479d, "findTarget holds the four lowest scores instead of sorting
every candidate") rewrites `findTarget`'s sort and is not on main. Build on it. `pc/lag-bug-sweep`
changes many `Vehicles.*` functions but not `hasLineOfSight`, `hostile` or `findTarget`.
`task/bot-gunner-wait` and `task/blast-parachuters` are stacked on the sweep. Task 20 changes the
gunner's trigger in the same file, and its gunners use this same `findTarget`. Oliver's 03:00 rule
applies to game-file edits.

## Proof

Offline, with lupa: run the real `findTarget` and `hasLineOfSight` against a mocked car with a driver
seated inside, glass panes and body panels, at 30, 80 and 150 studs. Report how often the rider is
picked before and after, and that a rider behind a wall, not a car, is still hidden. Plant a fault
aimed at an invariant (a bot never targets its own fellow rider, and never sees through a wall) and
show it goes red. Report how many candidate rays you examined.

Real behaviour: bots are server-side, so a runtest probe with a player-less car driven past a bot
squad can count shots at the car or its driver per pass, over 3 reps. The coordinator runs it.

Status: ready to start
