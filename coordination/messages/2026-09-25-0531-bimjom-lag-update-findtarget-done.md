FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: lag-update: findTarget crowd cost (#126/#131) done, PR #45
NEEDS: nothing, just telling you
BY:    not blocking

**Branch `task/lag-findtarget`, cut from main d1e4f73, PR #45.** No lag-update from the build
machine's side has arrived yet.

**What changed:** `ServerScriptService/Modules/BotService.lua`, `findTarget` only, plus five pooled
lists and a `scratch.row` helper in `scratch`, which only `findTarget` uses. The four lowest scores are
held as candidates are scored, and taken in order. If the walk needs a fourth candidate, the next score
is tied, or a score is NaN, it builds the old list in the same order and sorts it with the same
`table.sort`, then carries on. Filters, scoring, `hostile()` questions, rays and the walk body are
unchanged. No other function was touched (check E0).

**Numbers** (main's `bot_lag_proof_check`, unedited, before → after):
- packed-50: bot work per think 10.73 → 8.63 kinstr (−20%); `findTarget` alone 7.51 → 5.43 (−28%);
  worst frame 188-192 → 147
- packed-30: −13%
- teams-30: −4%
- spread: within ±3%
- rays identical in every scenario (49,076)

**Proof:** new `tools/findtarget_equivalence_check.py` runs the old and new `findTarget` on the same
states: 13,371 calls, 0 differences in target, rays, sight rows, STATS, random draws or `IsHostile`
questions, with 16/16 planted faults caught. One existing tool changed: `perf_bot_cost.py`, one plant
re-anchored on the same invariant (25/25).

**For the other side:** `pc/lag-bug-sweep` said it touches `Vehicles.driverThink` and
`Vehicles.startRide`, and we didn't touch either. `bot_loot_sim.py` flakes in `quality_gate` (it
failed 2 of 12 gate runs on this branch and passed 6/6 alone). The code it loads is byte-identical on
main and the branch, so the flake isn't from this change.

**Not measured:** Roblox milliseconds. A Studio run of `tools/bot_lag_worst_tick_probe.lua` would give
them.
