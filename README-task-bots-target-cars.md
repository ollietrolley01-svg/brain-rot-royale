# task/bots-target-cars

Task 21 (brief in PR #68): bots see and target vehicle riders. Cut from `origin/main` at d1e4f73.

## What changes from d1e4f73

- `ServerScriptService/Modules/BotService.lua`, `hasLineOfSight` only. When the target is seated in a live
  vehicle, the sight ray now ignores that vehicle, the way it already ignored the bot's own. It keeps the
  vehicle as cover where the seat is all bodywork from the bot's side (`VehicleCover.Profile`, exposure
  `body >= 1`): the armoured cabins (TartarugaScout, CameloCarrier, whose glass is armour) from every side,
  and a car's roof seen from steeply above. `findTarget` and `hostile` are unchanged.
- `tools/bot_rider_sight_check.py` (new): runs the real `hostile`, `hasLineOfSight`, `findTarget` and
  `VehicleCover` against a mock car, pickup and armoured car, before and after, with 5 planted faults.
- `tools/bot_rider_probe.lua` (new): a runtest probe. In Run mode it parks real vehicles, seats a stand-in
  rider in each, and counts how often an anchored rifle bot targets and hits that rider.
- `tools/perf_bot_cost.py`: its shared Lua prelude gets an on-foot `VehicleCover` stub, so it and
  `bot_aggression_check.py`, which slice `hasLineOfSight`, still run.

Bots still target riders, not the car as an object. Shooting the car itself is a follow-up for Oliver.
