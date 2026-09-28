# task/prove-road-cars

Cut from main `d1e4f73` and run on it; line references are to `d1e4f73`. It proves OLIVER_LIST #51 (old
road cars can't be destroyed), with #16/#94's parked designs in scope. New files only; no game file or
existing tool changed.

- `reports/road-cars-proof.md`: the proof. Every parked road car on main (79 over five maps, all real
  designs) is one 240-health pool that bullets, rockets, frags, stickies and barrels break, with no fading
  and nothing left over. Six findings: the same design has two health systems (parked 9 rifle hits,
  drivable 71-84); a wrecked drivable stays, blocks and can't be hurt; the noclip AdminOverride hits a car
  twice per bullet; bots' bullets never hurt a parked car; no ramming or melee path; CombatDamageScale
  doesn't touch the map.
- `tools/road_cars_proof_check.py`: builds whole maps with the real MapGenerator (the world of
  `tools/car_placement_map.py`), then fires through the real CombatService, ProjectileService and
  DestructibleService at every road car. 0 failures on 5 maps; `--plant` 9/9 caught.
- `tools/road_cars_break_gallery.lua`: the picture and a live ray probe, for the coordinator's Studio.
