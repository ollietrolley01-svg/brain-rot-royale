# Task 23: bots struggle to drive across bridges

**Files you own for this task:** `ServerScriptService/Modules/BotNav.lua`, the DRIVING section
(`DriveSense`, `blocking`, `DriveControl`, the `DRIVE_*` constants) only, and `tools/bot_driving_sim.py`.
**Read only:** `MapDecor.lua`, `RoadNetwork.lua`, `BotService.lua`, `BotDriveTactics.lua`.

## What was reported

Bots struggle to drive across bridges. Oliver, relayed by Jacob.

## How a bridge is built

`RoadNetwork` lays the road straight across a river, and `MapDecor.Bridge` (line 441) builds what
carries it. The road is 18 studs wide (`RoadNetwork.Width`). The bridge has a deck slab under the
asphalt, a parapet 1 stud wide and 3 tall down each side (inner face 9.5 studs from the centre line),
a lamp post at each end of each parapet on the parapet line, and piers below. The deck tilts with the
road's grade.

## What the bots do there

Routing already knows about bridges. `DriveRoute`'s `offBridge` (line 1454) never joins or leaves the
road within `DRIVE_BRIDGE_CLEAR` (30 studs) of a span. The trouble is likely in `DriveSense` (line
1799):

- The forward sweep is the car's width plus a stud, cast from 1.3 to 3.9 studs above the ground. A bot
  keeps `DRIVE_LANE` (3.5 studs) right of the centre, so a 6-stud-wide car's right side is about 7.5
  studs out. The parapet's inner face is at 9.5, a 2-stud margin. Any angle into the bridge puts a
  parapet in the sweep, and the car brakes or tries a detour (up to `DRIVE_AVOID_TURN`, 150 degrees)
  on a deck with nowhere to go.
- The two corner feelers (28 degrees out) reach the parapets and lamp posts on every bridge.
- The ground ray ahead may read the drop past a parapet or at the deck's end as a `"hazard"`.

`tools/bot_driving_sim.py` can't show any of this. Its bridge is a bare flat box level with the road,
with no parapets, lamps or grade (line 706). Its quick run passes today (10/10 plants). The full run is
red on main for another reason: the CrocodiloRanger lap, from the all-wheel-drive centre split (PR #49).
Say so in the PR rather than count it against this work.

## Conflicts

`pc/lag-bug-sweep` and `pc/teambase-v2` both change BotNav's DRIVING section (`DriveRoute`,
`BlockRoadAt`, a new constant beside `DRIVE_LANE`). Task 13 (bots stuck on props) edits `DriveSense` and
`blocking` too. Agree an order with whoever claims 13, or take both. Cut from `pc/lag-bug-sweep` if it
has merged. Oliver's 03:00 rule applies to game-file edits.

## Proof

Offline: give the sim a real bridge built from `MapDecor.Bridge`'s sizes (deck, parapets, lamps, a 5%
grade), and run each model across it both ways over 10 seeds. Report crossings, stops, reverses,
parapet contacts and seconds per crossing before and after. Plant a fault aimed at an invariant (a
wall across the road is always seen) and show it goes red.

Real physics: `tools/bot_driving_probe.lua` on each map with a bridge, counting bot crossings and stuck
reports over 3 reps. Bots are server-side, so runtest's Run mode is enough. The coordinator runs it.

Status: ready to start
