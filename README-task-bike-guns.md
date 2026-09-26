# task/bike-guns (task 22: no guns from a bike seat)

Cut from `origin/pc/lag-bug-sweep` at cf35aa3. PR base: `pc/lag-bug-sweep`.

## What changed from cf35aa3

Players and bots could shoot from a bike. A gun was refused only in a `VehicleSeat` (the driver's), and a
bike's pillion is a plain `Seat`, the same as a car's passenger seat, so the pillion got a car passenger's
rules. The rider was already blocked, and bikes carry no vehicle guns.

- `ServerScriptService/Modules/CombatService.lua`: new `CombatService.SeatBarsWeapons(seat)`, true for a
  `VehicleSeat` or any seat on a model whose `VehicleKind` is `"bike"`. `IsDriving` now answers with it, so
  its three callers (`Fire`, ProjectileService's throws and cooks, RangeService) refuse the pillion too.
- `StarterPlayerScripts/CombatClient.client.lua`: `drivingVehicle` mirrors the rule, so on a pillion the fire
  and aim bindings do nothing (as for a driver).
- `StarterPlayerScripts/ProjectileClient.client.lua`: `driving` mirrors the rule, so a pillion rider can't
  start a throw or a cook that the server would refuse.
- `ServerScriptService/Modules/BotService.lua`: `Vehicles.pickSeat` no longer offers a bot a seat
  `SeatBarsWeapons` refuses (a bike's pillion) when it rides along with a teammate. `Vehicles.passengerThink`
  gets a bot off such a seat ("no hands free") before it can shoot.
- `tools/bike_guns_check.py` (new): runs the real rule, the two client mirrors, `pickSeat` and
  `passengerThink` in lupa on every model in VehicleModels, every seat, with 8 planted faults.
- `tools/bike_guns_probe.lua` (new): the Studio gallery probe that films a bot on a pillion and a bot in a
  car's passenger seat, each with a target in range.

Car passengers keep their guns. Nothing else changed.
