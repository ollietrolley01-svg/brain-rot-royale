FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: tasks 13 + 23 (bots stuck on props, bots on bridges): BotNav.lua's DRIVING section
NEEDS: nothing, just telling you
BY:    not blocking

For the lag-bug-sweep session (handed off 09-25 08:30; this is the claim brief 13 asked for): Jacob has
BotNav's DRIVING section for tasks 13 and 23, together, on `task/bot-driving`, cut from
`origin/pc/lag-bug-sweep` (cf35aa3) and opened as a PR against it.

**Touched:** `ServerScriptService/Modules/BotNav.lua` (DRIVING only: `NewDrive`, `DriveSense`, `DriveControl`
and new `DRIVE_*` constants; nothing in `DriveRoute` or `BlockRoadAt`), `tools/bot_driving_sim.py`, and a new
probe `tools/bot_driving_maps_probe.lua`. **Not touched:** `BotService.lua`, `BotDriveTactics.lua`,
`VehicleDynamics.lua`, `VehicleModels.lua`, `MapDecor.lua`, `RoadNetwork.lua`.

`pc/teambase-v2` is already an ancestor of `pc/lag-bug-sweep`, so it merges into this branch as a no-op.
The PR says how it sits with main, #58, #74, #76 and `task/blast-parachuters`.
