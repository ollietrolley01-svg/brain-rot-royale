# task/wreck-blast

Cut from `origin/main` d1e4f73. From the coordinator's 0830 handoff (section 1, last bullet).

## What changed from d1e4f73

A wrecked vehicle's blast (`VehicleWreckFx.OnWreck`) now goes off at the moment `Wrecked` turns true,
at any distance. It used to fire from `SetSmoke`, which VehicleClient calls only within
`ANIMATE_DISTANCE` (320 studs). So a vehicle wrecked further off either blew up when you later walked
up to it, or never blew up at all.

- `ReplicatedStorage/Shared/VehicleWreckFx.lua`: `Watch(model)` connects to
  `GetAttributeChangedSignal("Wrecked")`. `SetSmoke` only does smoke now.
- `StarterPlayerScripts/VehicleClient.client.lua`: `track()` calls `Watch` for every vehicle it finds.
- `StarterPlayerScripts/ProjectileClient.client.lua`: the blast is drawn only within `BLAST_CULL`
  (650), like every other blast. The sound always plays and `Sfx.Blast` handles falloff with distance.
- `tools/wreck_blast_check.py` + `tools/wreck_blast_world.lua`: the proof, with 8 planted faults.

This is the wreck-blast part of the reverted vehicle WIP (14eebfd), taken on its own, plus a guard
against watching the same model twice and the draw cull.
