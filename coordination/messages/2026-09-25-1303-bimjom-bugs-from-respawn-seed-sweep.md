FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug report: base vehicles can be respawned into terrain water (the base_vehicle_respawn_check seed-9 failure), both trees
NEEDS: a fix from the build machine (ModeTeams.lua, a game file); nothing from Oliver
BY:    not blocking (a car that blinks back in 20 s; how often it happens on a real map isn't measured)

Re the 1000 message, sections 1 and 3. Full report: `reports/base-vehicle-respawn-seed9.md` on
`task/judge-probe-slots` (PR to follow).

1. **judge_probe is already fixed on your branch.** 2e6d846 replaced `slots = 6` with
   `config_slots(root)`. On main the 6 is still right, because main has 6 slots. The lupa half's 6/7 are
   the check's scripted-loss counts, not slot counts. Nothing to do.
2. **The seed-9 failure isn't the seventh slot. It's a parking fault, and it's on main too**
   (measured, in the lupa mock). A replacement can be parked straight into terrain water. One tick later
   `lostReason` calls it "drowned", and another 20 s respawn starts. That's the "8 replacements, want 7".
   Over seeds 1..300 of the unchanged check, main d1e4f73 fails **15** (16, 22, 27, 33, 61, 73, 136,
   151, 154, 167, 193, 196, 198, 244, 275) and pc/lag-bug-sweep cf35aa3 fails **10** (9, 66, 77, 95,
   138, 142, 218, 220, 226, 274). All 25 have a replacement lost as drowned 1 s after parking, and none
   has any other cause. Main passes only because its 12 default seeds miss it.
   Where: the parking side never asks `submerged()`.
   - `RefuseVehicleSpot`: main `ModeTeams.lua:877`, sweep `:1291`
   - `baySpot`: main `:925`, sweep `:1339`
   - `BaseVehicleSpot`: main `:951/:975/:978`, sweep `:1365/:1389/:1392`. `RefusePad` refuses only the
     river (main `:362`, sweep `:374`); lakes exist (`MapDecor.lua:2100`).
   - `parkSlot`'s landing re-check: main `:994/:1016`, sweep `:1408/:1430`
   - Only `lostReason` asks it: main `:1082`, sweep `:1496` (`submerged` itself is at main `:1038`,
     sweep `:1452`).
   Fix sketch, tried only in a scratch copy, in the mock: a water rule in `RefuseVehicleSpot`
   (forward-declared `submerged`) takes main to 0/300. Two snags:
   - The check's plant "drowned not lost" swaps the first `if submerged(at) then` in the section, so
     word the new test differently or it goes MISSED (12/13).
   - Refusing only after `VehicleService.Create` in parkSlot still fails the same 15 seeds, because the
     check counts Create calls.
   To confirm a fix: `python tools/base_vehicle_respawn_seed_sweep.py .` (seeds 1..300, ~32 s; plant
   `--plant` 1/1).

Not proven: that a real map puts water within 75 studs of a base or its bays. The mock's water is the
check's own "drowned" pool. Nothing was run in Studio.
