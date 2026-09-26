# task/lobby-gates (task 19: lobby declutter, gates clear of the booths)

Cut from `origin/main` at `d1e4f73`. Brief: `tasks/19-lobby-clutter-and-gates.md` on `task/playtest-briefs` (PR #68).

## What changes

`ServerScriptService/Modules/LobbyService.lua`, the Wayfinding block and the file header only:

- **MARKET ROW gate moved** off the road arc, where it stood about 18 studs in front of the Cosmetics
  stall, to `(-42.6, -26)`. It now stands over the road's last straight where it turns in from the
  pitch, before the row. Its subtitle now covers the whole row: "Trading Hall - Cosmetics - Crates - Spin".
- **CRATES + SPIN gate removed.** It stood 4 to 15 studs in front of the crate keys. No spot on the row
  (r60, 220 to 280 degrees) is clear of all four booths, and east of the Spin the showcase podium slots
  and a lamp post leave no room.
- **Road studs halved**, 38 to 19 (`STUD_SPACING` 8 to 16).
- **One banner per gate** instead of two, hung from the middle of the lintel.
- **Road arcs built from 5 straight pieces instead of 12** (`arc.segments` replaces `arc.step`).

Wayfinding goes from 231 parts and 5 lights to 149 parts and 4 lights. The whole lobby goes from
3395 to 3313 parts on the offline harness, and from 3586 to 3504 in Studio.

`tools/lobby_layout_check.py`:

- **New check F:** no Wayfinding part above the paving crosses a sight or walk-up line to a booth
  (the Trade Board, the Cosmetics stall, each crate key, the Daily Spin). The lines come from a fan
  of spots in front of each booth: 5 angles by 5 distances, at knee height (swept a player wide),
  chest height and eye height.
- **Two new planted faults:** a gate put back in front of the Cosmetics stall, and a gate put back
  in front of the Crate Altar.
- The "gateway sunk into the Trading Hall" plant now targets the new Market spec.
- **Budgets tightened** to the new counts: lobby 3400, Wayfinding 170.

## Not merged, not for main

Proof images are on the orphan branch `proof/lobby-gates`. Never merge that branch.
