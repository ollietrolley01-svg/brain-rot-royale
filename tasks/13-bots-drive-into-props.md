# Task 13: bots drive into props and get stuck

**Files you own for this task:** `ServerScriptService/Modules/BotNav.lua`, the DRIVING section
(`DriveSense`, `blocking`, the `DRIVE_*` constants) only, and `tools/bot_driving_sim.py`. **Read
only:** `BotService.lua` (the lag-bug-sweep session owns `Vehicles.driverThink` and `startRide`),
`BotDriveTactics.lua`, `VehicleDynamics.lua`, `VehicleModels.lua`.

## What Oliver saw

"the bots drive into props and get stuck". Playtest, 2026-09-25.

## Where to look

`BotNav.DriveSense` (line 1799) looks at the world four times a second, with at most four casts. The
first cast is a box the car's width, swept ahead of it, and it is what the car brakes for. It is
centred at `groundHere + 2.6` with a height of 2.6, so it covers 1.3 to 3.9 studs above the ground.
`groundHere` is the chassis height minus `rideHeight`, and `rideHeight` is measured once, at
boarding (`Vehicles.startRide`).

There are two likely causes, and the task is to find out which props they apply to:

1. **Low props aren't seen.** Anything whose top sits under 1.3 studs above the ground is under the
   sweep: a low wall, a kerb-high planter, a crate on its side. On a slope, or with the nose pitched
   down, the gap grows.
2. **Rounded or sloped props read as ground.** `blocking` (line 1785) ignores any hit whose normal
   points more than 0.6 up. A box sweep that meets a rock, a barrel or a wedge high on its curve gets
   an upward normal and drives on.

After three reverses that go nowhere (`DRIVE_STUCK_TRIES`), the drive reports `"stuck"`.
`BotDriveTactics`' unstick then detours once. If the bot gets stuck again within 30 studs, it gives
up the car and shuns it. So a car Oliver saw sitting against a prop may be one a bot abandoned.

Start by finding out which props it is. Log the part name, size and hit normal each time a drive
reports `"stuck"`, over a few matches on each map.

## Conflicts

This area is busy. `pc/lag-bug-sweep` and `pc/teambase-v2` both change BotNav's DRIVING section
(`DriveRoute`, `BlockRoadAt`, a new constant beside `DRIVE_LANE`), and both change `BotDriveTactics`
and `BotService`. PR #58 (`task/bot-gunner-wait`) and `task/blast-parachuters` are stacked on the
sweep. Post a claim in the mailbox addressed to the lag-bug-sweep session before you start, and cut
from whichever of those branches has merged by then. `bot_driving_sim` is already red on main (the
CrocodiloRanger lap, from the all-wheel-drive centre split, PR #49). Say so in the PR rather than
count it against this work.

## Proof

Offline: `bot_driving_sim.py` runs BotNav's DRIVING section in stock Lua. Add scenarios built from
the real prop sizes you logged: a low prop across the route, a rounded one, and one on a slope. Count
stuck reports and contacts per run before and after the fix, over at least 10 seeds. Plant a fault
aimed at an invariant (a solid part in the car's path at bumper height is always seen), not at this
one prop.

Real physics: `tools/bot_driving_probe.lua` on a real map. Bots are server-side, so runtest's Run
mode is enough. Count `"stuck"` reports per bot-minute over 3 reps before and after. The coordinator
runs it.

Status: ready to start
