# Wilds + landmarks tab (claude-46) — handoff, 2026-09-21 ~23:55

Paused on Oliver's instruction ("stop all agents and all tabs", "pause all work here until next
session reset"). Nothing was mid-landing. Read this top to bottom before touching `MapWilds.lua`.

## READ THIS FIRST: Sahur Springs is already at the part ceiling

The performance tab's figure, via claude-43 and **not measured by me**: roughly **31,600 parts
affordable** once the free savings are banked, with **35,000-40,000 breaking it**. My Sahur Springs
rows are **32,969 parts at density 12**, 36,624 at 16 and 40,303 at 20.

**So Sahur Springs is already at the line at the density that is in the tree right now, and every
step up is past it. Rot Ridge has room all the way to 20 (28,308) and Sahur has none.**

Two consequences for whoever resumes:

- **Do not raise `BUDGET_PER_RADIUS` globally.** One number cannot be right for both maps, because
  they do not have the same headroom. This is what turns the parts-per-radius against
  parts-per-area question from a tidiness argument into a decision: per-radius gives the big maps
  LESS per acre, and the big maps are exactly the ones with no headroom. Whatever replaces it has
  to be per-map or per-area, and that choice is Oliver's and claude-43's, not this tab's.
- **The shadow trim is what pays for trees.** 92.6% of all parts in the map currently cast
  shadows (performance tab, map-wide); the wilds' own trim already silences **56-71%** of what this
  module builds. Those two numbers belong side by side in any density conversation.

**And do the pictures before any of it.** Oliver has asked for screenshots five times and has never
been shown a tree. He cannot judge a table.

## The one thing that changed tonight

**The hook landed.** `MapGenerator.lua:27` requires `MapWilds` and `:885` calls it inside a
`pcall`, passing `seed` and `avoid` explicitly. Foliage is in the build path for the first time
after Oliver asked for it four times. I did not land it and I have not yet run a single probe
against the wired build — see NEXT STEP.

## What is in the tree, mine, all static-checked clean (0 findings)

`ServerScriptService/Modules/MapWilds.lua` (2,600-odd lines):

1. **Density raised.** `BUDGET_PER_RADIUS = 12`, and the attempt counts behind it raised so the
   budget is what binds rather than the attempts (woods 40/area, singles 460/area, undergrowth
   R²/26, meadows 20/area, ground cover 380/area).
2. **Road corridor veto** in `open()`: refuses `roads:WithinCorridor(x, z)` and the four compass
   points at the footprint edge (capped 26 studs). `ignore` is the escape, so bus shelters still
   stand on their verge. Measured firing 20–93 times a build.
3. **Shadow trim** behind `MapWilds.SHADOW_TRIM` (default true): every part under a stud in all
   three directions, plus ferns, flowers, mushrooms and tufts. **Shrubs and long grass keep their
   shadows on purpose** — they are the cover a player crouches in, and cover is read by its shadow.
   That line is the whole argument for "no quality loss"; do not quietly cross it.
4. **Fail-fast contract**: `Build` names the missing argument (`preset`, `radius`, `centers`,
   `townSpread`, `space`) instead of erroring 200 lines in. `tools/wilds_map_probe.lua` plants all
   five faults and demands the error name each one.
5. **Diagnostics in the result**: `cappedAt` (which phase stopped on budget, by name), `vetoed`
   (no ground / water / map-says-none / corridor). Both exist because "the veto never fires" and
   "the veto fires and there is nothing out there" are the same number otherwise.
6. **`seconds` is wall clock** (DateTime), not `os.clock` — CPU time under-read a yielding build
   by 30%.
7. **Z-fight fixes by construction**: spruce lean on a full circle + a per-tree head-clearance
   jitter; mushrooms lean and step by a WHOLE stud not a scaled one; five grass blades at 72° with
   a per-blade roll, feet stepped 0.13 apart (the old 0.012 was six times under ZFight's 0.045
   tolerance, which is why pairs measured 0.000 apart).

`tools/`: `wilds_density_probe.lua` (curve + shadows + vetoes + binding phase),
`wilds_density_gallery.lua` (NEW — three densities from one camera between two towns, plus the
shadow before/after pair; **never yet run**), `wilds_map_probe.lua` (contract self-test, settle
wait), `wilds_landmarks_probe.lua` (reach fixed, see CORRECTIONS).

## Measured, current code, NOT the wired build (my own place copy, seed 424242)

| map | per stud | trees | wilds parts | whole map | wall | flush before any pass | shadows silent |
|---|---|---|---|---|---|---|---|
| Rot Ridge (r880) | 12 | 421 | 9,630 | 23,880 | 0.50s | 8 | 59% |
| Rot Ridge | 16 | 550 | 11,823 | 26,073 | 0.52s | 7 | 58% |
| Rot Ridge | 20 | 675 | 14,058 | 28,308 | 0.64s | 6 | 56% |
| Sahur Springs (r1280) | 12 | 703 | 15,363 | 32,969 | 0.76s | 3 | 70% |
| Sahur Springs | 16 | 833 | 19,018 | 36,624 | 0.85s | 3 | 71% |
| Sahur Springs | 20 | 1,079 | 22,697 | 40,303 | 0.97s | 5 | 71% |

Sahur spends 100% of its budget at 12 and 89% at 20; Rot Ridge 91% and 80%. The woods phase is the
one that stops on budget everywhere. Remaining flush pairs are coincidences between separate
pieces (birch bark marks 0.001 apart, one fern, one mushroom), not construction faults.

## Corrections on the record (both mine, both already sent to claude-43 and claude-79)

- **The density counts were never over-counts.** I said twice they would drop when
  `GroundHeightAt` returns nil. `MapWilds` never asked it for the ground: it casts its own ray and
  refuses no-hit and water. The `mapSaysNone` counter reads **0 at every budget on both maps** —
  that branch has never fired and nothing of mine was waiting on another tab.
- **Landmark REACH was over-read by up to 1.41x.** It measured the corner of each part's
  AXIS-ALIGNED box while the build is rotated 0.6 rad, so a 44-stud square floor 22 studs from its
  own middle read 43 — which is why all 15 landmarks reported "past its claim". Now measured from
  the box's eight real corners. **The per-landmark claim proposal I owe claude-43 is still owed and
  must be rebuilt on the corrected numbers — do not reuse the old table.**

## NEXT STEP, in order

1. **Joint check on the wired build**: `tools/wilds_map_probe.lua` + the footing probe + build wall
   clock, on the seed the Map tab builds with. claude-79 will fold their road audit into a run they
   are making anyway and send three band counts (in corridor / in blend / clear) to sit beside my
   refusal counts. Mine counts refusals, theirs counts escapes — high and zero is agreement.
2. **Run `tools/wilds_density_gallery.lua`** (Sahur Springs, then Rot Ridge). Oliver has asked for
   screenshots five times and has not had one this session. It gives him 12 / 16 / 20 from one
   camera plus the shadow pair. Copies ready under the old scratchpad, but regenerate them.
3. **Then pick the density**, under the part ceiling the performance tab owes claude-43. Open
   game-wide question I raised and did not decide: the budget is parts per stud of RADIUS while
   area goes as the radius squared, so big maps are thinner per acre (Sahur 3.0 parts per 1000
   studs², Rot Ridge 4.3). Parts per AREA would make every map read the same; Sahur at Rot Ridge's
   density would be ~22,000 wilds parts.
4. **Ask claude-79 for the worst floor gap under a `Shelter_busShelter`** on the wired build. Bus
   shelters sit 16 studs from the centre line, inside the corridor by design, and that band
   measures off by up to 1.17 studs on Rot Ridge. If it shows daylight, take their floor from
   `roads:GroundAt(x, z, margin)` instead of my own ray.
5. **`scratchpad/readme_wilds_section.md`** (old session scratchpad; re-draft if gone) is a written
   README section for the wilds, to land now that the hook is in — it was true only once the hook
   landed, which is why it was not landed with the code.
6. Still owed from earlier: the stone terrace steps on landmark sites (private copy only, needs a
   render on the roughest map), and #41 "The Sweaty Incident" is done and handed to another tab.

## Standing constraints (do not relearn these the hard way)

Never run `tools/publish.ps1`. Back up before edits; no deletes, renames or whole-file overwrites
of another tab's work; never edit another tab's file. At most ONE queued Studio job per tab. No
loot in wilds shelters. Brainrot visuals and names stay original. Every render is labelled NOT IN
THE BUILT PLACE until the code is in the tree. Before any finding reaches Oliver it has to survive
"can he see this?". Every audit that can report 0 must first catch a planted fault.
