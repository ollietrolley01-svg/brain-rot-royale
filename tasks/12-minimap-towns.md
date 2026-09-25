# Task 12: draw the towns better on the minimap

**Files you own for this task:** `StarterPlayerScripts/HudClient.client.lua`, the Minimap section
(from the `-- Minimap` banner at line 2023 through `refreshTownMarkers` and its label-overlap pass,
which ends at line 2487) only. HudClient is a shared file, so make anchored edits inside that section.
**Read only:** `MapGenerator.lua`, `TownThemes.lua`, `RoadNetwork.lua`.

## What Oliver asked for

"the minimap needs improvements on the towns". Playtest, 2026-09-25.

## What the minimap draws now

The minimap is 190 px (`MAP_PX`), scaled so the map's radius fills half of it. `refreshTownMarkers`
draws each town as a 5 px grey dot and a 12 px name at `TownCenter`, and landmarks the same in gold.
It also draws the river. It draws nothing else of a town, and no roads.

`MapGenerator` (lines 253-270) already puts `TownRadius` (spread + 40), `TownSpread` and `TownKind`
on every town, and the minimap reads none of them. A town is often 100 studs or more across, which
is 10 px or more on the minimap. It currently shows as a dot the same size for every town.

## Ask Oliver first

"Improvements" doesn't say what is wrong. Send Oliver a few numbered mockups through the mailbox and
let him pick. For example: each town as a filled area from `TownRadius`, the town's buildings as
small blocks, or the roads through it. If an option needs data the map doesn't publish (building
footprints, the road lines), ask the build machine for it as one attribute through the mailbox. Do
not edit `MapGenerator`.

## Conflicts

`pc/lag-bug-sweep` changes `HudClient` (hunks near lines 1191, 3341 and 3921, outside the Minimap
section) and `MapGenerator`. `pc/teambase-v2` also changes `MapGenerator`. Merge main and check again
before you push.

## Proof

Offline: the geometry. `tools/hud_mock_world.lua` and `tools/hud_layout_check.py` already mock the
HUD. For every map and a few seeds, show that each town's drawn shape lies inside the minimap's frame
and that its size matches `TownRadius` at the minimap's scale. Plant a fault (the scale doubled) and
show it goes red. Report how many towns you checked.

**Whether it looks better cannot be proven offline.** It needs a render, and the coordinator runs
renders (`tools/hud_overlap_gallery.lua` is the nearest existing one). Oliver judges the result.
