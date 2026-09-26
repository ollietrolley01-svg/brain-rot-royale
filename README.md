# proof/lobby-gates: renders for task 19 (PR "Task 19: lobby declutter, gates clear of the booths")

**Proof only. Never merge this branch.** It is an orphan branch holding images, and the task branch commits none.

Each image is a pair: left is `origin/main` at `d1e4f73`, right is `task/lobby-gates` at `ebae0f1`.
Both were rendered in Roblox Studio with the Linux gallery harness, from `lobby_booths_gallery.lua`
(in this branch), each on its own `build_place.py` build. The gallery builds the real lobby with
`LobbyService.Build`. Studio counted 3586 lobby parts before and 3504 after.

| File | What it shows |
|---|---|
| `00_overview.png` | The whole island. |
| `01_cosmetics_walkup.png` | The Cosmetics stall from the plaza in front of it, at eye height. Before: the MARKET ROW gate fills the left of the frame. After: the stall has only the lamp post beside it (Island code, outside this task). |
| `02_crate_altar_walkup.png` | The Crate Altar from 28 studs out. Before: a CRATES + SPIN pillar stands dead centre over the crate keys. After: all seven keys and the altar's sign are in view. |
| `03_daily_spin_walkup.png` | The Daily Spin from the plaza. No gate stood here before either; it shows the Spin is still clear. |
| `04_trade_board_walkup.png` | The Trading Hall's counter from the plaza. Still clear. |
| `05_row_from_the_pitch_road.png` | Walking south down the road from the pitch. After: the one MARKET ROW gate stands over the road before the row, and its board names all four booths. |
| `06_row_from_the_plaza.png` | The row from the plaza near the tree. Before: two gates in front of the hall, the stall and the altar. After: none. |
| `07_row_overhead.png` | The row from above. Before: two gates on the arc. After: one gate on the straight, west of the row. |
