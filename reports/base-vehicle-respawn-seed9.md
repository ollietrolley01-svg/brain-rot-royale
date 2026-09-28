# base_vehicle_respawn_check: the judge_probe slot count, and the seed-9 failure

A report, not a fix. No game file or existing tool is changed. Trees: origin/main **d1e4f73**,
origin/pc/lag-bug-sweep **cf35aa3** (live as v8).

The 1000 handoff (section 3) says `judge_probe` "still assumes 6 slots (it's 7 now)". Section 1 says
`base_vehicle_respawn_check` fails at seed 9 ("abandoned vehicle replaced early", "8 replacements, want
7"). PR #52 (finding 3) put the seed-9 failure down to the seventh slot, without isolating the cause.

## Short version

1. **judge_probe is already fixed on the sweep.** Commit 2e6d846 on `pc/lag-bug-sweep` replaced
   `slots = 6` with `config_slots(root)`, which reads `#MatchConfig.TeamBaseVehicles.Slots`. On main
   the 6 is still right: main has 6 slots. Nothing to do on either tree.
2. **The lupa half's 6 and 7 aren't slot counts.** They count the check's own scripted losses: 6 on
   team 1 (gun, chassis broken, emptied, fell, drowned, removed) and 7 in all (plus team 2's abandoned
   car). They're correct with 6 slots or 7.
3. **Seed 9 is a real game fault, and it's on both trees.** A replacement can be parked straight into
   terrain water. One second later the tick counts it as "drowned" and starts another 20 s respawn.
   That's the extra replacement ("8, want 7"). The seventh slot only moved which seeds hit it. Main
   fails 15 of 300 seeds and the sweep fails 10 of 300, all for this one reason. Main passes the
   check's default run only because its 12 seeds happen to miss it.

## 1. judge_probe (already fixed on the sweep)

| tree | `MatchConfig.TeamBaseVehicles.Slots` | `judge_probe` slot count |
|---|---|---|
| origin/main d1e4f73 | 6 (`MatchConfig.lua:241`) | literal `slots = 6` (`tools/base_vehicle_respawn_check.py:389`): **matches** |
| origin/pc/lag-bug-sweep cf35aa3 | 7 (`MatchConfig.lua:241`, one more `"car"`) | `slots = config_slots(root)`, since 2e6d846: **derived from the config** |

The literal can only go wrong on main if the sweep's seventh slot lands without its tool change, and
both come in the same merge. I didn't port the change to main: a second copy only adds merge risk.

## 2. The literals in the lupa half

`tools/base_vehicle_respawn_check.py:182` (`R.creates - before ~= 6`), `:193` (`~= 6`) and `:195`
(`~= 7`) compare against the `losses` table at `:143-154`. That table has six team-1 entries and one
team-2 entry. They'd go stale if someone added a loss case, not if a slot were added. With 7 slots,
team 1 keeps one untouched vehicle and team 2 keeps four. Nothing in the expected counts changes.

## 3. The real fault: replacements parked in water (measured, in the mock)

### What happens

The check's "drowned" case puts terrain water (radius 6) over one of team 1's parked cars. At
RespawnDelay the tick destroys every lost car and parks six replacements. On some seeds one of the
*other* replacements (seed 9 on the sweep: team 1 slot 6, the "removed" car) is parked inside that
water (the sweep, seed 9; a per-tick trace from a scratch script, trimmed):

```
t=  1.0 team 1 slot 5 (Rotster) drowned  pos 266.7,10.0,252.8
t= 21.0 team 1 slot 6 (CrocodiloRanger) live     pos 267.2,10.0,256.4   <- parked 3.6 studs from the drowned spot
t= 22.0 team 1 slot 6 (CrocodiloRanger) drowned  pos 267.2,10.0,256.4   <- lost again one tick later
t= 42.0 team 1 slot 6 (CrocodiloRanger) live     pos 292.4,10.0,368.2   <- the 8th replacement
```

The eighth replacement lands between the check's "6 replaced" and "abandoned one replaced" marks, so
the check reads it as "the abandoned vehicle was replaced early".

### Why

The parking code never asks whether a spot is under water. Only `lostReason` does, after the car is
already parked:

| what | origin/main d1e4f73 | origin/pc/lag-bug-sweep cf35aa3 |
|---|---|---|
| `RefuseVehicleSpot`: arena, pads, spacing, loot; no water rule | `ModeTeams.lua:877` | `ModeTeams.lua:1291` |
| `baySpot` asks only `RefuseVehicleSpot` of a bay | `:925` | `:1339` |
| `BaseVehicleSpot`: computed spots ask `RefusePad` (the river only, `:362` / `:374`) and `RefuseVehicleSpot` | `:951`, `:975`, `:978` | `:1365`, `:1389`, `:1392` |
| `parkSlot`: the landing re-check is `RefuseVehicleSpot` again | `:994`, `:1016` | `:1408`, `:1430` |
| `submerged()`, the water test | `:1038` | `:1452` |
| `lostReason` calls it, and only there: "drowned" | `:1082-1083` | `:1496-1497` |

`RefusePad` turns away the river (`MapTerrain.InRiver`), but not a lake or pond. Maps do have lakes
(`MapDecor.lua:2100`, "A lake: a sandy shore, water, reeds and a little dock").

### The numbers

Every seed 1..300 of the unchanged check, with every replacement watched
(`tools/base_vehicle_respawn_seed_sweep.py`, below):

| tree | failing seeds | failing seeds | replacements lost within 2 s of parking | reasons | failing seeds with any other cause |
|---|---|---|---|---|---|
| origin/main d1e4f73 | **15 / 300** | 16, 22, 27, 33, 61, 73, 136, 151, 154, 167, 193, 196, 198, 244, 275 | 16 (seed 27 has two) | drowned: 16 | none |
| origin/pc/lag-bug-sweep cf35aa3 | **10 / 300** | 9, 66, 77, 95, 138, 142, 218, 220, 226, 274 | 10 | drowned: 10 | none |

Examined: 5,400 base vehicles on main and 10,500 on the sweep. The sweep counts more because it also
runs its arena-edge section. Every failing seed on both trees has a replacement lost as "drowned" 1 s
after it was parked, and no failing seed has anything else. On main the failures read "the abandoned
vehicle was replaced early" plus "8 replacements, want 7". Seed 27 also trips section 2's re-abandon
lines. Sweep seed 274 reads "bays: 1 vehicles created with nothing lost": the section-1 water is still
there when section 4 lays out its bays.

So the 1000 message was right that this "was already failing before the sweep". It was failing on
seeds the 12-seed run doesn't reach.

### A fix sketch, tried in a scratch copy only (not in this branch)

For the build machine, to show where the fix goes and how the check responds. Neither was committed.

- **Refusing water in `RefuseVehicleSpot`** (forward-declare `submerged`, then `if submerged(at) then
  return "under water" end` after the arena rule): **0 of 300 seeds fail** and nothing is lost at once.
  `base_vehicle_respawn_check` passes, and the sweep's plant is still caught. One snag: the check's
  own plant "drowned not lost" swaps the **first** `if submerged(at) then` in the section. With that
  text now in `RefuseVehicleSpot`, the plant lands there and goes MISSED (12 of 13 caught). The fix
  should word its test differently, e.g. `if submerged(at) == true then`, or the plant should be
  re-aimed.
- **Refusing only in parkSlot's landing re-check** (after `VehicleService.Create`): nothing is lost at
  once, but the same 15 seeds still fail, now as "7 of team 1's 6 losses replaced". The check counts
  `VehicleService.Create` calls, and a car that parkSlot creates and then takes back still counts. So
  the refusal should come before `Create`, as in the first sketch.

## The tool: `tools/base_vehicle_respawn_seed_sweep.py` (new)

It runs `base_vehicle_respawn_check`'s own `run()` and Lua over seeds 1..N, unchanged. It wraps them
from outside (it swaps `CHECKS` for the run and restores it) to watch each slot after every tick. It
passes only when no seed fails and no replacement is lost within 2 s of being parked.

```
/tmp/brr-venv/bin/python tools/base_vehicle_respawn_seed_sweep.py .               # seeds 1..300, ~32 s
/tmp/brr-venv/bin/python tools/base_vehicle_respawn_seed_sweep.py . --seeds 1000
/tmp/brr-venv/bin/python tools/base_vehicle_respawn_seed_sweep.py . --plant       # must print CAUGHT
```

It isn't a `*_check.py`, so `quality_gate.py` doesn't pick it up. It's red on both trees until the
fault is fixed, and it takes 32 s.

**The planted fault**: water is put over every vehicle parked once the tick has started, so every
replacement lands in water. It aims at the invariant "a base never gets a replacement that counts as
lost the tick after it was parked", not at today's seeds. A known-bad seed would stop being bad the
moment the game is fixed, and the plant would quietly prove nothing. This plant fires on the current
game ("the abandoned vehicle was replaced early", plus RELOST lines), and it still fires on the fix
sketch above ("18 of team 1's 6 losses replaced": every spot is refused, so the base never refills).

## What this does NOT prove

- **That a real map puts water inside a base's parking ring.** The mock's water is the check's own
  "drowned" construct: a pool dropped on a car at home. Lakes exist, and `RefusePad` only knows the
  river. Whether a lake ever sits within `Outer` (75 studs) of a compound's base or bays on a real map
  is unmeasured; `team_base_ruins_check` or a Studio probe would say. So this is a real hole in the
  parking rules, measured in the mock. How often it happens in a match is unknown.
- The mock water is a flat disc (centre, radius 6, top). Real terrain water has shores and depth.
- The fix sketch was run only in the lupa mock, in a scratch copy. It isn't a proposal for how to word
  the game change, and nobody has run it in Studio.
- Nothing here was run in Studio.
