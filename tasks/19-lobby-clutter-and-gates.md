# Task 19: the new lobby is cluttered and the gates block the booth

**Files you own for this task:** `ServerScriptService/Modules/LobbyService.lua`, the Wayfinding block
(`buildWayfinding`, `buildRoad`, `buildGate` and the gate table, lines 3453-3629) only, and
`tools/lobby_layout_check.py`. **Read only:** the rest of `LobbyService.lua`, `ShowcaseService.lua`,
`tools/showcase_layout_check.py`.

## What was reported

The new lobby update is cluttered, and the gates block the booth. Jacob relayed this from a
2026-09-25 playtest.

## The lobby change

"Lobby v2" landed on main on 09-24: da2e346 ("the Rot Road and district gates") and 6fceb1b. It adds a
Wayfinding set piece of 231 parts and 5 lights: a raised purple road with glowing studs from the pier
to the statue and on to each district, and a gate over each district's way in. Each gate has a
Rotling mascot on top and two swinging banners. The gates are in a table at about line 3490:

| Gate | Where | Span, height |
|---|---|---|
| FIRING RANGE | (31, 0) | 38, 13 |
| PLAY BALL | (-47, 0) | 14, 8 |
| MARKET ROW | 240 degrees, radius 60 | 11, 11 |
| CRATES + SPIN | 270 degrees, radius 60 | 11, 11 |
| ALL ABOARD | (0, 125.5), the gangway | 12, 11 |

## Which booth

Confirm with Jacob, ideally with a screenshot. Two candidates:

- **The Cosmetics stall** (`buildCosmeticsStall`, line 1309), the only market stall. It is at 250
  degrees, radius 74 (`STALL_RADIUS`), 14 wide, facing the centre. The MARKET ROW gate stands about 18
  studs in front of it and a little to one side.
- **The Crate Altar** (`buildCrateAltar`, line 1448), at 270 degrees, radius 84. The CRATES + SPIN gate
  stands directly in line with it, 24 studs in front.

The Daily Spin wheel (292 degrees, `buildDailySpin`, line 1660) is also on that side, and its comment
says it has no booth any more.

`tools/lobby_layout_check.py` checks that every prompt is reachable on foot, but not that it can be
seen from the plaza or that a gate stands in front of it. That is a gap to close in this task.

## Ask Jacob or Oliver

"Cluttered" needs a picture. Propose two or three numbered options from a render: fewer gates, lower
gates, gates moved off the line of sight to each booth, or the road without the gates. Don't move any
interactive piece.

## Conflicts

`pc/lag-bug-sweep` changes `LobbyService` (the ready-pad comment, `buildPitch`, the PlayerRemoving
handler). PR #61 (`task/obby-sound-volume`) changes the Cloud Climb code and PR #64
(`task/device-compat`) changes `buildArena`. None of them touch the Wayfinding block. Task 09 owns
`buildReadyPad` in the same file.

## Proof

Offline: extend `lobby_layout_check.py` with an invariant that no gate part stands between a booth's
prompt and the plaza (a clear line from a fixed viewing point to each prompt), and keep its part
budget. Report the part count before and after. Plant a fault (a gate moved onto a prompt's line) and
show it goes red.

**Clutter cannot be proven offline.** It needs a render. The coordinator runs
`tools/lobby_v2_gallery.lua` before and after, and Oliver judges it.
