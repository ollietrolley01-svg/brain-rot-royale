# task/lag-findtarget

Cut from main `d1e4f73`. It was started on `origin/merge/2026-09-25-fixes` `927bc44` and moved to main before its
first commit, as the coordinator's 0406 message asked; `findTarget` is the same at both. A lag optimization (OLIVER_LIST #126 / #131): in a crowd,
`findTarget` no longer builds a row for every candidate and sorts them all on every think. It decides exactly what
it decided before. Announced in the mailbox as `2026-09-25-0342-bimjom-lag-update-findtarget-starting` (PR #44).

- `ServerScriptService/Modules/BotService.lua`: `findTarget` only, plus five pooled lists and a `scratch.row`
  helper that only it uses. It holds the four lowest scores as it scores, takes them in order, and falls back to
  the old full sort when the walk needs a fourth, the next score is shared, or a score is NaN.
- `tools/findtarget_equivalence_check.py` (new): runs the old findTarget (a copy kept in the check,
  byte-identical to `927bc44`/`d1e4f73`) and the new one on the same states, 13,375 calls from whole matches and built edge states. It checks the target, rays, sight and seen
  rows, STATS, RNG and hook questions (E0-E6), plus a cost bound for packed-50 (C1). 16/16 planted faults.
- `tools/perf_bot_cost.py` (the one existing tool edited): its plant anchored on text this change moved. Same
  invariant, re-anchored; it is still caught for the allocation reason.
- `reports/lag-findtarget.md`: what changed, why it is equivalent, before/after numbers, and what is not proven.

Measured with main's `tools/bot_lag_proof_check.py`, unedited, mean of 3: packed-50 bot work per think 10.73 → 8.63
thousand instructions (−20%). findTarget alone: 7.51 → 5.43 (−28%). Worst frame 192 → 147. Rays unchanged. Spread-out bots
are within ±3%. These are lupa figures, not Roblox milliseconds.
