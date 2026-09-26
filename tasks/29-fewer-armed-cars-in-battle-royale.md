# Task 29: armed cars rarer in battle royale

**Files you own for this task:** `VehicleModels.Pick` (line 3439) and its options, the battle royale call
site in `MapGenerator.lua` (line 1225, one option added), and a new check under `tools/`. **Read only:**
the `weight` fields in `VehicleModels.lua` (they also feed the kerbside props), `VehicleService.Create`,
`ModeTeams.lua` (team-mode base vehicles), `VehicleWeaponData.lua`.

## What was asked for

Cars with guns should be rarer in battle royale. Oliver, relayed by Jacob.

## The share today

Battle royale parks vehicles in `MapGenerator` (line 1225). Each one is a bike 38% of the time, or a car
(`math.random() < 0.38`). `VehicleService.Create` picks the model with `VehicleModels.Pick(kind, rng, {
drivable = true })`, by weight.

The drivable car weights: Rotster 30, CrocodiloRanger 22, TralalaGT 18, SahurVan 16, TartarugaScout 6
and CameloCarrier 4, a total of 96. Every one except the TralalaGT carries a turret and a driver's gun
(`VehicleWeaponData.ByModel`). So **78 of 96 cars, 81%, are armed**, and about half of all battle royale
vehicles (0.62 x 0.81).

## Default

In battle royale only, armed cars become 25% of cars (about 15% of all vehicles). Add an option to
`Pick` that scales the armed models' weight, pass it from the battle royale call site, and leave team
modes, the kerbside props and the weights themselves alone. Keep the armoured pair rarest.

## Conflicts

`pc/lag-bug-sweep` changes `VehicleModels.lua` (10 lines) and `MapGenerator.lua`. `pc/teambase-v2`
changes `MapGenerator.lua`. PR #65 (`task/vehicle-seams`) changes `VehicleModels.lua`. None of them
touch `Pick` or the battle royale vehicle loop. Oliver's 03:00 rule applies to game-file edits.

## Proof

Offline, with lupa: run the real `Pick` 100,000 times with and without the option, and report each
model's share. Armed cars must land within a stated tolerance of 25% with the option and within the old
81% without it, so team modes and props are unchanged. Plant a fault aimed at that invariant (the
option leaking into the default pick) and show it goes red.

Status: ready to start
