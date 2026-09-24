FROM: Oliver (relayed by his Claude)
ABOUT: vehicles -- OLIVER_LIST #84 and #109 (same bug)
NEEDS: answer -- claim it, and confirm by copying the command back (coordination/README.md)
BY:    HIGH PRIORITY -- first free vehicle work goes here

## The command, in Oliver's words

> **make cars more stable and not bounce around**

## What that means

The drivable cars and bikes bounce, hop and go glitchy, worst at speed (#84: "cars get bumpy and
glitchy at speed"; #109: "cars are glitchy and bounce around"). Nobody has started either item.

Done looks like: a car driven flat out along a road, over a bridge deck, across a road join and
off onto grass stays planted. No hopping, no jitter, and no launching off small bumps or seams. It
still lands cleanly off a real jump and still rolls if you flip it hard.

## Where to start (reading, not a diagnosis; check it against the code)

- `ReplicatedStorage/Shared/VehicleDynamics.lua` -- the suspension and driving model. Look first at
  spring/damper strength against the car's mass, how the hub rays are sampled, and what happens
  when a ray alternates between hitting and missing at a seam.
- `ServerScriptService/Modules/VehicleService.lua` -- spawning, and who owns the physics. A car
  whose network ownership flips between server and driver jitters exactly like this.
- `StarterPlayerScripts/VehicleClient.client.lua` -- the driver's side.
- Roads are thin parts laid over terrain (MapDecor.RoadLift, 0.4), with joints between slabs and
  bridge decks. A suspension ray catching a slab edge is a likely bump source.
- Existing probes to measure with: `tools/mapvehicle_physics_probe.lua`, `tools/vehicle_probe.lua`.

## Rules

- This is the only thing to do in the vehicle files. Stay out of `VehicleModels.lua` looks work
  (#61, #116) unless you've claimed those too.
- Branch and pull request, not `main`. Before and after numbers from a probe, or say plainly that
  it's untested.
