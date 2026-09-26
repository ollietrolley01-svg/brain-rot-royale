# task/bot-driving

Tasks 13 (bots drive into props and get stuck) and 23 (bots struggle to drive across bridges), in one
branch because both edit BotNav's DRIVING section. Cut from `origin/pc/lag-bug-sweep` at cf35aa3 (live
as v8); the PR is against `pc/lag-bug-sweep`. Briefs: `tasks/13-*` and `tasks/23-*` on
`task/playtest-briefs` (PR #68).

## What changed from cf35aa3

**`ServerScriptService/Modules/BotNav.lua`, DRIVING section only** (`NewDrive`, `DriveSense`,
`DriveControl`, nine new `DRIVE_*` constants):

- The sweeps and feelers look past what nothing collides with (`RespectCanCollide` on the drive's sweep
  params, set in `NewDrive`). A cast reports only its first hit, and a sign's board, a road marking or
  another car's chassis box in front of a post hid the post.
- The sweep box follows the ground: it climbs at the grade the last look's ground probe found ahead,
  taken only from the terrain or a road's slab and at most 15% (`DRIVE_SWEEP_GRADE`; a roof or a tree's
  leaves under the ray tipped it up over what was in the way). Level, it met a 5% road 26 studs on and
  saw nothing past it. On ground steeper than 8 degrees
  (`DRIVE_SWEEP_TILT`: a bank, a dune) it lies along the chassis. Not along the chassis on gentler
  ground, where the nose dips under the brakes.
- A face the front sweep meets side-on, standing clear of the way the car steers (a bridge parapet met
  by a sweep a few degrees off the road), is neither braked for nor gone round (`DRIVE_SIDE_ON`,
  `DRIVE_BESIDE`, `DRIVE_BESIDE_TURN`). A face across the way always counts.
- A corner feeler's hit standing 4 studs or more clear of the car's side (`DRIVE_FEELER_BESIDE`: a lamp
  post on the far parapet) no longer makes it ease away.
- Going round something, the way back is swept along itself unless it is within 2 degrees of where the
  car points (`DRIVE_BACK_SAME`; it was 10, and the car turned back into what it went round). On a road,
  what that sweep meets past the lane's verge side (a lamp by the road) isn't taken as in the lane.
- While a detour is still turning onto its way round (over 15 degrees off it), 14 studs/s
  (`DRIVE_DETOUR_TURN_SPEED`, `DRIVE_DETOUR_SIGHT`).

**`tools/bot_driving_sim.py`:** a real bridge (MapDecor.Bridge's deck, parapets and lamp posts at a
grade), a prop course built from the sizes the maps probe logged (lamp post, hedge, fence, a sign with
its board, a rock, a pebble, a low wall, a block at bumper height, a trunk on a slope and on a bank,
car-park clutter), balls in the casts and the physics, thin posts in the contacts, `RespectCanCollide`
and tilted boxes in the casts, seeded runs (`--measure crossing|props --seeds N`, `--botnav FILE` for a
before), and three planted faults aimed at invariants.

**`tools/bot_driving_maps_probe.lua` (new):** real maps in Run mode. Every reversing manoeuvre and
"stuck" report logged with what was in front of the car and what the front sweep met first on each of
the 8 looks before; bridge crossings from each map's `BridgeDeck` parts; stuck reports and recoveries
per driving bot-minute.

**`coordination/messages/2026-09-26-1715-bimjom-claim-13-23-botnav-driving.md`:** the claim brief 13
asked for.

Nothing else: no BotService, BotDriveTactics, VehicleDynamics, VehicleModels, MapDecor or RoadNetwork.
