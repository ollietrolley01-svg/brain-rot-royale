# task/armed-cars: fewer armed cars in battle royale (task 29)

Cut from origin/main at d1e4f73. What this branch changes from that commit:

- `ReplicatedStorage/Shared/VehicleModels.lua`: `Pick` takes a new option, `opts.armedShare`. When it's
  set, the armed models' weights (models with a turret in `VehicleModels.Mounts`) are scaled together so
  armed cars make up that share of the pick. The armoured pair stays rarest. Without the option the
  weights stand. A pick still takes one roll either way.
- `ServerScriptService/Modules/VehicleService.lua`: `Create` passes `options.armedShare` on to `Pick`.
  `ParkInTowns` takes an optional trailing `armedShare` and passes it to each of its `Create` calls.
- `ServerScriptService/Modules/MapGenerator.lua`: `ARMED_SHARE = 0.25`, passed at all three places the
  map parks drivables (the car parks, the verge, the car-park top-up).
- `tools/armed_car_share_check.py` (new): runs the real `Pick` 100,000 times per case, then builds every
  map with the real `MapGenerator` and `ParkInTowns`. Four planted faults.

Armed cars in battle royale: 81% of cars before, 25% after. Team base vehicles, kerbside props and the
weights are unchanged.
