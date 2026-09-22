# Foliage + landmarks tab (claude-46) — handoff, 2026-09-22 ~04:4x

Owns: `ServerScriptService/Modules/MapWilds.lua` (2,600 lines, mine, now WIRED), `Landmarks.lua`,
`tools/wilds_*.lua`. Scratchpad: `%LOCALAPPDATA%\Temp\claude\C--Users-oliver-Downloads-claude\
40b44b88-90e6-498a-abb7-1419c95731ba\scratchpad`. Longer prose version: `HANDOFF_WILDS.md` (root).

## READ FIRST — two numbers that constrain everything this tab does next
- **Sahur Springs is already over the part ceiling at the density in the tree.** Performance tab's
  figure (theirs, via claude-43): ~31,600 affordable, 35-40k breaks it. Sahur measures **32,969**
  parts at density 12, 36,624 at 16, 40,303 at 20. Rot Ridge has room to 20 (28,308). **One global
  density cannot be right for both maps.** Do not raise `BUDGET_PER_RADIUS`.
- **Map build is now 16-24 s against a 15 s budget** (was 13-14). The wilds' own cost is 0.5-1.0 s
  wall, so foliage is not the cause — but there is no slack to spend, and the trim below is the
  only thing paying for trees.

## LANDED (shared tree; checks after the last edit)
- `lua static check: 1 files, 0 findings` on every file I touched (MapWilds, 4 probes, gallery).
- **The hook is IN, landed by the map tab**: `MapGenerator.lua:27` requires MapWilds, `:885` calls
  it in a `pcall` with `seed` and `avoid` explicit. First time foliage has ever been in the build
  path. I have run NO probe against the wired build — that is the next step.
- MapWilds tonight: road-corridor veto in `open()` (refuses `roads:WithinCorridor` + four compass
  points at the footprint edge; `ignore` keeps bus shelters on their verge); shadow trim behind
  `MapWilds.SHADOW_TRIM`; fail-fast contract naming the missing ctx field; `cappedAt` and `vetoed`
  diagnostics in the result; `seconds` is wall clock now; z-fight fixes in spruce, mushrooms, grass.

## IN MY PRIVATE TREE — nothing pending. Apply nothing.
`scratchpad/tree2/` is a place-build copy for probes only; every code change is already in the
shared tree. `scratchpad/readme_wilds_section.md` is a written README section for the wilds, true
only now the hook has landed — land it as-is under `## Maps`, before `### Landmarks`.

## PROVEN (tools/wilds_density_probe.lua, my place copy, seed 424242 — NOT the wired build)
| map | per stud | trees | wilds parts | whole map | wall | flush before any pass | shadows silent |
|---|---|---|---|---|---|---|---|
| Rot Ridge | 12 / 16 / 20 | 421 / 550 / 675 | 9,630 / 11,823 / 14,058 | 23,880 / 26,073 / 28,308 | 0.50-0.64 s | 8 / 7 / 6 | 59 / 58 / 56% |
| Sahur Springs | 12 / 16 / 20 | 703 / 833 / 1,079 | 15,363 / 19,018 / 22,697 | 32,969 / 36,624 / 40,303 | 0.76-0.97 s | 3 / 3 / 5 | 70 / 71 / 71% |
- Shadow trim silences **56-71%** of the wilds' parts, against **92.6%** of all map parts casting.
- Corridor veto fires 20-93 times a build; water refuses 7-26; **"map says no ground" is 0 always.**
- Z-fight: Sahur 7 pairs → 3. What is left is coincidence between separate pieces (birch bark marks
  0.001 apart, one fern, one mushroom), not a construction fault.

## UNPROVEN — say so before anyone ticks it
- **Everything above is my own place copy, not the wired build.** No probe has run since the hook.
- The three z-fight fixes are measured on two maps at three budgets each; not on the other three.
- The shadow trim has **never been rendered**. Counts only. Nobody has looked at it.

## OPEN ITEMS
1. **Foliage density — waiting on Oliver's "more or not".** He asked for "way more foliage" five
   times and has never been shown a picture. Sahur cannot take more without the ceiling work.
2. `#28` Treehouse obby branches not solid (mine, untouched).
3. Landmark per-claim proposal owed to claude-43 — **rebuild it, do not reuse the old table**: the
   old REACH numbers were over-read up to 1.41x (see lesson 3).
4. Bus shelters sit 16 studs from the centre line, inside the corridor by design, in the band
   claude-79 measures off by up to 1.17 studs. Ask them for the worst floor gap under a
   `Shelter_busShelter` on the wired build before "fixing" anything.

## NEXT STEP, one line
Merge into ONE Studio job: `wilds_density_gallery.lua` on Sahur Springs (three densities from one
camera between two towns + the shadow before/after pair) and `wilds_map_probe.lua` on the wired
build — pictures for Oliver first, density second.

## THREE LESSONS
1. **The hook IS the item.** ~7,900 lines of finished map work (MapWilds 2,600, TownThemes 4,856,
   TownKinds 484) sat with no production caller while Oliver asked for foliage four times, and each
   ask was answered by a module nothing ran. I spent that time measuring z-fight pairs. Two to ten
   flush pairs on a map that already runs a z-fight pass is invisible; zero trees is not.
2. **Instrument the veto, not the outcome.** "The veto never fires" and "the veto fires and there
   is nothing out there" are the same part count. A counter retired my own claim that the density
   numbers were over-counts — `mapSaysNone` reads 0, so nothing was ever waiting on another tab.
3. **An over-read in a broad phase is free; as the answer it is a bug.** REACH measured the corner
   of each part's AXIS-ALIGNED box on a build rotated 0.6 rad, so a 44-stud square floor 22 studs
   from its middle read 43 — and all 15 landmarks falsely reported "past its claim".
