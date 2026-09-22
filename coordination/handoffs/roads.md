# Roads / river tab — handoff (2026-09-22, at the hourly recycle)

Clean point: nothing half-landed, nothing pending in my private tree, no Studio job queued.

## LANDED (in the real tree, checked)
- `ServerScriptService/Modules/MapTerrain.lua` — FlattenPad, RewritePads, PadAt, PadNear, PadCost,
  ResetPads, PaintPatch. Landed 2026-09-21 22:53:59. Backup: `scratchpad/landing_backup_0921_225359`.
- `tools/road_audit_all.lua` — worst-apron-sample LOCATION now printed; new wilds-in-the-corridor pass.
- `tools/road_gallery.lua` — curve note counts BEND nodes (it divided by every node, so it read
  "26 of 79 bends" on a map whose every bend was curved).
- `tools/road_river_probe.lua`, `tools/road_bank_probe.lua` — new, measurement only.
The three checks, verbatim:
    byte compare: all identical
    OK: no problems                (tools/verify.py .)
    files unbalanced: 0            (tools/balance.py .)

## IN MY PRIVATE TREE
`scratchpad/work/` is a MIRROR only — everything above is already in the real tree, so there is
nothing to apply and no command to run. Rebuild its scratch place with:
    python scratchpad/work/build_place.py scratchpad/work
(It was refreshed from the real tree at 23:02; 322 files had moved since the previous sync.)

## PROVEN (probe + number)
- Roads, `tools/road_audit_all.lua`, 5 maps x 2 seeds, z-fight pass off: holes 0, unjustified ends 0,
  steps 0, doubles 0, overlapping surfaces 0, overlapping markings 0, raw flush pairs 0, ground parts
  floating 0 / buried 0, contacts failing 0, dense ground off >0.25 either way 0/0, no-terrain 0,
  water under a road with no deck 0, lakes dry 0, docks buried 0. Road top over ground 0.38..0.52
  (want 0.40); steepest grade 9.6-10.0% vs a 10% limit; sharpest joint 0.47-0.58 deg; 0 bends left
  square, sharpest turn away from a junction exactly 10 deg; tightest curve radius 36. All three
  planted faults caught.
- Pads, `tools/road_pads_probe.lua`: 20 pads on RotRidge, flatness 0.000 footprint / 0.008
  footprint+margin (target 0.25), 0 hollow voxels, all three refusals fired, buried pad restored
  exactly, 3.6 ms/pad = 0.55 s for 150 structures.
- River, `tools/road_river_probe.lua`, 579 cross-sections: width 34 nominal / 30 wetted CONSTANT;
  depth 4.3 on every run; bed unevenness 0.6; shelf flat to 0.3-2.4 studs between 6 and 30 out;
  ground at 40 vs 120 studs out FLIPS SIGN between maps (-9.4..+11.0) so there is no valley.
- Banks, `tools/road_bank_probe.lua` (planted vertical wall correctly unescapable): a character climbs
  out of water at 50 deg and shallower, NOT at 60/70/90. Swim 12.3 studs/s; rig walk 16.0 (players get
  MatchConfig 18). Today's river averages 60-66 deg, so THE TYPICAL RIVERBANK IS STEEPER THAN A PLAYER
  CAN CLIMB OUT OF. Entry every 100 studs = 4.05 s of swimming worst case; cut entries at 25-35 deg.

## UNPROVEN
- FlattenPad's `space` option: landed unmeasured (MapGenerator.Build does not return its MapSpace, so
  the pads probe passed nil). My first test of it was WRONG — it sampled 16 studs out, inside the pad's
  own flat zone (margin + 2 voxels = 11 past the footprint's 12), and read the pad doing its job as a
  violation. Corrected test (sample 26-50 out, claim circle at centre-38) is written in
  `road_river_probe.lua` and has never been run.
- The informational apron band 13-19 studs out: RotRidge 935/719 samples off by >0.25 (worst 1.17),
  Patapim 188 (worst 3.99), others 22-62. Not an acceptance criterion. The next run prints WHERE.
- Whether the town census generalises: it printed the 26 nearest part names per town and only one
  town's list reached the buildings.

## OPEN ITEMS (Oliver's numbers)
- #73 better rivers and banks — measured, design not yet written. BANKS FIRST, WIDTH SECOND (ruled).
  Width later must be a function of the PLAN (PlanRiver runs before terrain), passed into
  RoadCrossings rather than read from RIVER_WIDTH, and InRiver must answer per point.
- Roundabout in every town centre + sidewalks (Oliver asked directly in the roads tab; parked by the
  coordinator). Plaza furniture reaches 25 studs from centre, first building wall 34-36 = a 9-11 stud
  gap against an 18-stud carriageway. The SIDEWALKS half is open and small: country roads have no
  footway at all; town streets already have kerbs and pavements.
- #31 parking lots / bays — pads exist now (FlattenPad), which is the mechanism a bay needs.
- #16 replace old map cars with the drivable designs, #51 old road cars cannot be destroyed — not
  started here; vehicle placement along straight spans is in MapGenerator (Map tab's file).
- Owed to the foliage tab: worst floor gap under a `Shelter_busShelter` on the first wired build.
- BUILD TIME: map build has gone from 13-14 s to 16-24 s against a 15 s budget. First thing to look at.

## NEXT STEP (one line)
Write the banks design note from the numbers above — entries every 100 studs, cut at 25-35 deg,
justified by the 12.3 studs/s swim speed — and wait for the go before building.

## THREE LESSONS
1. Measure terrain a FRAME after writing it. A fresh WriteVoxels is not raycastable immediately; that
   is how a gallery reported 38 studs of spread on a pad a screenshot showed dead flat.
2. A zero from "nothing was measured" must never look like a zero from "nothing is wrong" — print
   which one it is. Same trap: a guard that reads as nil (`if report then` in a scope with no
   `report`) is indistinguishable from a condition that never fires.
3. Over-reading an axis-aligned box is safe in a BROAD phase (it only adds candidate pairs); it is
   wrong when the over-read number IS the answer or is compared against a round claim.
