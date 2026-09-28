# task/review-lag-bug-sweep

Cut from main `d1e4f73`. It reviews `pc/lag-bug-sweep` at `cf35aa3` (live as Roblox version 8), as the
build machine's `2026-09-25-1000-sweep-review-and-remaining-to-jacob.md` asked ("leave all reviewing to
jacob"). The branch adds one new file. No game file or existing tool is changed, and nothing in the
sweep was edited.

- `reports/review-lag-bug-sweep.md`: the review. Nothing found that should crash or stall a live
  server. Five things to look at before the sweep goes to main:
  1. Rot Ridge's switch from Rock to Limestone swaps its wilds and props for other maps' sets
     (`MapWilds.lua:1818`, `MapDecor.lua:2901`).
  2. Two map checks fail on seeds that are clean on main (a car park in a river, a static car in open
     country).
  3. `base_vehicle_respawn_check` fails at seed 9, although it passes on main.
  4. Four rows marked "fixed" don't change the game.
  5. The quality gate goes from 9 red checks to 26, mostly because the harnesses can't load the changed
     code.

  It also lists what holds (roadkill, loot spill, the TTK and silly-explosions bug tests, bot tick cost)
  and what was not reviewed (pc/teambase-v2 as a feature, and anything that needs Studio).
