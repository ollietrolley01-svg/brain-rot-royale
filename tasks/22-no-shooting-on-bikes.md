# Task 22: players and bots can shoot while riding a bike

**Files you own for this task:** `CombatService.IsDriving` (CombatService line 1083) and the matching
`drivingVehicle` in `StarterPlayerScripts/CombatClient.client.lua` (line 733); in `BotService.lua`,
`Vehicles.pickSeat`'s passenger branch and `Vehicles.passengerThink` (line 4381) only; and a new check
under `tools/`. **Read only:** `VehicleService.lua`, `VehicleModels.lua`, `ProjectileService.lua`,
`RangeService.lua`.

## What was reported

Players and bots can fire their guns while riding bikes. Oliver, relayed by Jacob.

## How seats block weapons now

A gun is refused only in the driving seat. `CombatService.IsDriving` is true when the humanoid's
`SeatPart` is a `VehicleSeat`, and three places read it: `CombatService.Fire` (line 1133),
`ProjectileService` throws (line 638) and `RangeService`. The client mirrors it in `drivingVehicle`.
Passenger seats are plain `Seat`s, and a car passenger firing out of the window is intended ("as a
player passenger may", BotService line 4379).

`VehicleService.Create` gives a bike the same seats as a car (lines 1300-1309). The rider is a
`VehicleSeat`, and each bike has one pillion seat, a plain `Seat` (`passengers` in `VehicleModels`,
for example `PatapimScrambler`, line 1167). So the likely cause is the pillion: it gets a car
passenger's rules. Bots take it through `pickSeat` ("passenger", line 4535) and shoot from it in
`passengerThink`. Confirm whether the bike's rider can also fire, for example through a thrown item
or an ability that skips `IsDriving`.

## Default

No weapon fire, aiming or throwing from any seat on a bike, for players and bots. Bots stop taking a
bike's pillion seat to fight from it. Car passengers keep their guns. A seat can be told apart by its
model's `VehicleKind` (or `VehicleModels.Models[id].kind`).

## Conflicts

`pc/lag-bug-sweep` changes `Vehicles.pickSeat` in five hunks, and `CombatService` and
`ProjectileService` elsewhere. `task/bot-gunner-wait` (PR #58) and `task/blast-parachuters` are stacked
on it. PR #64 (`task/device-compat`) changes `CombatClient`. Oliver's 03:00 rule applies: an outside
claimant writes the diagnosis, the check and the exact before/after text, and the build machine applies
game-file changes unless Oliver says otherwise.

## Proof

Offline, with lupa: run the real `IsDriving` (or its replacement) and the bot seat choice against a
mocked car and bike, every seat on each. Show that no seat on a bike can fire and that a car
passenger still can. Plant a fault aimed at the invariant (a car passenger always can fire, a bike
seat never can) and show it goes red. The client side needs a Studio **Play** test with a client on a
bike's pillion. The coordinator runs it.

Status: ready to start
