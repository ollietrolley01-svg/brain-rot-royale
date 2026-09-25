# Lag: findTarget's crowd cost (#126 / #131)

Branch `task/lag-findtarget`. It was started on `origin/merge/2026-09-25-fixes` at `927bc44`, then moved before its first
commit onto main **`d1e4f73`**, as the coordinator's 0406 message asked. `findTarget` is byte-identical at both, and
all numbers below are from main. Nothing was run in Roblox. The
numbers below are Lua instruction counts from lupa (Lua 5.5) running the game's own `BotService.lua`. Each claim
says whether it was measured or reasoned.

## Verdict

**A bot in a crowd no longer sorts every candidate on every think. It decides exactly what it decided before.**
With 50 bots packed together, the bots' whole think costs 20% less (`findTarget` alone 28% less), and the worst
frame goes from 192 to 147 thousand instructions. Rays, targets and the order candidates are sight-tested are all
unchanged. Across 13,375 `findTarget` calls, the old and new functions ran on the same states and matched on
everything: target, rays, sight and seen rows, STATS, RNG draws and hook questions (measured). Bots that are spread
out cost the same as before, within ±3% (measured). These are lupa instruction counts, not Roblox milliseconds.

## What changed

Only `findTarget` in `ServerScriptService/Modules/BotService.lua`, plus two things only it uses: five pooled lists
in the `scratch` table and the `scratch.row` row filler. Git's diff counts 79 lines added and 16 removed, 19 of
the added lines being comments.

Before (`d1e4f73:1340`, the same text as `927bc44:1309`): every candidate the grid returned that was alive, hostile and in range got a pooled row.
The whole list was sorted with `table.sort`, then walked in order until a target was seen and noticed, or three
fresh sight rays were spent. In a crowd the grid returns everyone: at packed-50 that is 50 rows and a 50-item sort
per think, followed by 1.5 rays on average.

After:
1. **The first pass is unchanged apart from one thing: each score goes into flat lists instead of a row.** It keeps
   the same filters in the same order (`token ~= bot`, `Health > 0`, `hostile()`, then range), the same scoring
   lines and the same `STATS.focusFire`. So `hostile()` gets the same questions in the same order. As the scores
   come, the four lowest are kept in order (a short insertion list, `lowScores`/`lowAt`). `pick` and `focus` are
   read once per call instead of once per candidate. They are fields of the bot and of the team's focus row, and
   nothing in the loop writes them.
2. **The walk takes the held candidates one at a time** and makes a row only for each one it takes. The loop body
   (sight test, barricade test, seen rows, the rear-notice delay) is the old one, unchanged.
3. **It falls back to the old sort** in three cases: the walk needs a fourth candidate, the next score is shared
   with the one after it, or a score is NaN. Then it builds the whole list as before, sorts it with the same
   `table.sort` and comparator, and carries on from where it had got to.

### Why the decisions are identical (reasoned; the check below measures it)

- A candidate is taken only when its score is strictly below the next held score. Every score that isn't held is
  at least the fourth held score. So the one taken is strictly below every candidate not yet taken. Any correct
  sort puts it at exactly that position, whatever Lua or Luau's sort does with ties.
- When two scores are equal, their order is whatever `table.sort` makes of the list, and old and new must agree
  on it. The fallback hands `table.sort` the same list the old code sorted: the same candidates, in the same
  (grid) order, with the same scores. The ones already taken had unique scores below everyone else's, so they
  come first in the sorted list, and the walk carries on after them.
- NaN (`Health = MaxHealth = math.huge` for a "weakest" bot gives `inf/inf`) goes straight to the old sort, so
  whatever the old code did with it, the new code does too.
- Row identity is not part of a decision. The returned row is a pooled table, as before, and valid until the
  next call (`fight`, `botVehicleThink` and `quickFirstShot` use it as before). Nothing outside `findTarget` reads
  `scratch.candidates` (grep).
- There is no `math.random` in `findTarget` or the helpers it calls, so the RNG stream is untouched.

## Before and after

### Main's harness (whole BotService + BotNav through `BotService.Start`, 60 Hz)

`tools/bot_lag_proof_check.py` as it is on main (PR #43 plus the build machine's M1-M3 rows and harness fixes),
unedited. Before: `. --rev d1e4f73`. After: the working tree. A small driver called the harness's own
`Harness.run` (health 400, as its `run_all` does) and read its per-frame counters. Each side ran 3 times; the
figures are the mean of 3. Run-to-run noise is about ±5% (Lua's table order). The think, ray and route counts do
not vary. "Hook asks" is PR #43's "candidates examined": the `BotService.IsHostile` calls. The harness sets a
hook in every scenario, including its battle royale ones, which the real battle royale does not have.

| scenario | kinstr / think | findTarget path kinstr / think | worst frame kinstr (range of 3) | hook asks / think | rays / think |
|---|---|---|---|---|---|
| spread-15 | 3.27 → 3.31 (+1%) | 1.12 → 1.14 (+1%) | 26 (25-28) → 24 (23-27) | 5.2 → 5.2 | 3.74 → 3.74 |
| spread-30 | 3.66 → 3.64 (−1%) | 1.33 → 1.36 (+2%) | 40 (40-41) → 44 (43-45) | 7.9 → 7.9 | 4.28 → 4.28 |
| spread-50 | 4.06 → 4.07 (+0%) | 1.75 → 1.78 (+2%) | 72 (70-76) → 70 (68-72) | 12.0 → 12.0 | 4.55 → 4.55 |
| packed-15 | 4.68 → 4.47 (−4%) | 2.47 → 2.21 (−10%) | 28 (27-29) → 30 (30-31) | 13.5 → 13.5 | 4.38 → 4.38 |
| packed-30 | 6.99 → 6.10 (−13%) | 4.43 → 3.53 (−20%) | 78 (76-79) → 69 (67-70) | 26.4 → 26.4 | 4.41 → 4.41 |
| **packed-50** | **10.73 → 8.63 (−20%)** | **7.51 → 5.43 (−28%)** | **192 (190-195) → 147 (144-151)** | 44.4 → 44.4 | 4.64 → 4.64 |
| teams-30 | 6.23 → 5.96 (−4%) | 3.63 → 3.39 (−7%) | 67 (63-69) → 64 (61-67) | 28.6 → 28.6 | 4.37 → 4.37 |
| roam-30 | 1.92 → 1.92 (−0%) | 0 → 0 | 31 (28-33) → 33 (29-36) | 0.4 → 0.3 | 1.60 → 1.60 |
| stress-50 (cap 40) | 12.66 → 10.66 (−16%) | 9.18 → 7.15 (−22%) | 222 (209-231) → 198 (195-201) | 49.4 → 49.4 | 3.12 → 3.12 |

(The spread worst frames move by ±4 in both directions: that is noise, since spread-out bots barely touch the
changed code.) The same measurement on `927bc44` with PR #43's own copy of the harness gave the same picture:
packed-50 10.85 → 8.71 (−20%), worst frame 188 → 152.

Total bot rays were the same in every run of every scenario, before and after (49,076 across the 9). The
harness's own checks give the same result on main and on the new tree:
`bot_lag_proof_check: 9 scenarios, 6240 frames, 12345 thinks, 49076 bot rays examined; 0 failures` and
`bot_lag_proof_check plants: 14/14 caught`.

**Candidates examined didn't change, and that's on purpose.** The grid still returns everyone in a crowd
(`STATS.candidatesExamined` and hook asks are unchanged). Asking about fewer of them would mean reordering the
`hostile()` filter, and in lupa that made team modes slower (it computes distances for team-mates, and a lupa
vector is a table). What went away is the work per candidate after the filter: 50 rows and a sort go down to
about 2 rows and, on 1.5% of thinks, a sort. Shrinking the grid query is not part of this change:
`combatantsNear` has other callers.

### The new check, paired (the same calls on the same states)

`tools/findtarget_equivalence_check.py` runs old and new on each state and counts BotService's own instructions.
Vector maths and the mock world's raycast are left out, because a Luau Vector3 is a native value, not a Lua table.

| scenario | calls | instructions / call | rows / call | table.sort / call | hook asks / call | rays / call |
|---|---|---|---|---|---|---|
| spread-15 | 495 | 1425 → 1445 (1.01) | 2.0 → 0.78 | 0.74 → 0 | 5.5 → 5.5 | 0.80 |
| spread-30 | 982 | 2219 → 2236 (1.01) | 4.1 → 1.06 | 1.00 → 0 | 12.1 → 12.1 | 1.07 |
| spread-50 | 1628 | 2824 → 2808 (0.99) | 6.7 → 1.11 | 1.00 → 0.002 | 18.5 → 18.5 | 1.11 |
| packed-15 | 481 | 3455 → 3371 (0.98) | 16.6 → 4.65 | 1.00 → 0.19 | 16.6 → 16.6 | 2.30 |
| packed-30 | 988 | 5536 → 4845 (0.88) | 31.9 → 1.58 | 1.00 → 0.009 | 31.9 → 31.9 | 1.42 |
| **packed-50** | 1583 | **8144 → 6732 (0.83)** | **50.2 → 2.07** | **1.00 → 0.015** | 50.2 → 50.2 | 1.50 |
| teams-15 | 494 | 3042 → 3133 (1.03) | 9.5 → 5.09 | 1.00 → 0.31 | 17.0 → 17.0 | 3.70 |
| teams-30 | 979 | 4446 → 4500 (1.01) | 16.8 → 7.40 | 1.00 → 0.31 | 31.7 → 31.7 | 3.62 |
| teams-50 | 1645 | 6308 → 6192 (0.98) | 26.9 → 11.75 | 1.00 → 0.35 | 51.9 → 51.9 | 3.81 |

Team fights walk further: hidden enemies' cached rows are passed without spending a ray, so about 31% of team
thinks go past the four held candidates and sort anyway. That is why team modes gain little (−2% to +3%).

## The check: `tools/findtarget_equivalence_check.py`

It runs the whole of `BotService.lua` (the working tree) in `tools/bot_archetype_sim.py`'s mock world. The old
`findTarget` is a copy kept in the check (`REFERENCE_FT`, byte-identical to `927bc44` and `d1e4f73`). `--old REV`
reads it from git instead. It is loaded as a second function inside the same chunk, so it shares every helper
and upvalue. Because the copy is kept in the check, the check still works after this lands on main. On every call, the old function runs first. Everything it touched is
then put back (sight rows, seen rows, hostile cache, every STATS counter, the ray budget's spend) and the new one
runs. The check itself changes the loaded copy in three ways: it logs each `RaycastBudget.Cast`, lets the budget's
spend be put back, and wraps `findTarget`. The game file is not changed.

| id | invariant |
|---|---|
| E0 | with `--base REV` (and in `--plant`): the source outside findTarget's region is REV's. Only findTarget, the `scratch` lists and helper, and comments differ, and every old `scratch` line is still there. Run here with `--base d1e4f73` |
| E1 | the same return: nil, or the same token, character, root, distance, score, throughCover (and the same error, if any) |
| E2 | the same rays, in order (origin, direction, class, granted or refused), and the same budget spend after |
| E3 | the same sight rows (at, visible, cover) and seen rows (since, last) left on the bot |
| E4 | every STATS counter moved by the same amount |
| E5 | the same number of `math.random` draws (none) |
| E6 | `BotService.IsHostile` asked the same questions in the same order |
| C1 | packed-50, paired: rows ≤ 1/4 of the old, `table.sort` on ≤ 5% of calls, instructions ≤ 90% of the old (measured 4%, 1.5%, 83%) |

States, 13,375 calls in all:
- **World:** 9 matches of `updateBot` (spread, packed and teams at 15, 30 and 50 bots). Each has mixed archetypes
  and guns, walls, two players and dummy shooters, and runs for 8 s. Every call is compared.
- **Edge:** 4,100 built states, one think each: candidates on lattices and rings (exact score ties); at exactly
  vision range and just past it; shooters past vision range, at exactly gun range and just past it; dead ones
  (0 and below); team-mates; a hook that errors; a shared ride; players; the hurt, and exactly 40% health;
  `math.huge` health (NaN scores); focus rows; old sight rows (hidden, seen, behind a barricade, behind a shot-down
  barricade); seen rows; smoke; ray caps of 1-8 so refusals land part way through a walk; every archetype.

What the compared calls covered (counts of calls): 2,550 had an exact score tie in the old list, 2,563 used the
new code's sort, 324 had a NaN score, 2,029 had a candidate at exactly vision range, 267 had the shooter past
vision range, 327 had the shooter at exactly gun range, 5,317 had a dead one in reach, 4,920 a team-mate, 11,591 a
player, 497 had a ray refused, 195 returned a target through a barricade, and 9,996 returned a target.

Last lines, verbatim:

```
E0 against d1e4f73: outside findTarget's region the source must be d1e4f73's
findtarget_equivalence_check: 13375 findTarget calls compared (9 world runs, 4100 built states); 0 failures
findtarget_equivalence_check --plant: 16/16 planted faults caught
```

Planted faults (all caught): equal scores taken in grid order, not table.sort's; the shooter past vision range
dropped; players dropped; the dead kept; team-mates kept (hook still asked); the threat's 0.45 skipped; vision
range made exclusive; gun range made exclusive; the first two candidates swapped; the every-think recheck given
to the second candidate; the held list keeping the highest scores; the walk stopping at the held few; the walk
restarting after the sort; the NaN guard dropped; every think sorting the whole list again (caught by C1 only,
since its decisions are right); a change outside findTarget (`LOS_CHECKS_PER_THINK` 3 → 4, caught by E0).

## The other checks (before = main `d1e4f73`, after = this branch)

- `python tools/verify.py .` → `OK: no problems`. `python tools/balance.py .` → `files unbalanced: 0`.
  `python tools/lua_static_check.py .` → `lua static check: 451 files, 0 findings`.
  `tools/local_limit_check.py` → `local_limit_check: 454 files, 0 over the limit`. BotService's main chunk is
  still at 186 live locals: the change adds no top-level local. `tools/clock_ratchet.py .` → `OK: no problems`.
- `python tools/quality_gate.py -k bot --timeout-scale 3` gives the same result before and after:
  `12 checks, 1 failed, 1 skipped; planted faults 86/86 caught`. The one failure is `bot_driving_sim.py`
  (`PROBLEM lap CrocodiloRanger: 1 impacts (worst 5.4 studs/s)`), with output identical line for line before and
  after. That is the known red on main named in the coordinator's 0500 message. It is driving code, not findTarget.
- `tools/perf_bot_cost.py .` → `perf_bot_cost: 0 failures`. `--plant` → `perf_bot_cost plants: 25/25 caught`.
- **One existing tool edited:** `tools/perf_bot_cost.py`. One plant tuple anchored on text this change moved.
  It now targets the same invariant ("a fresh row per candidate per think") in `scratch.row`, and is caught for
  that reason: `B: 7.98 KB allocated per think at N=10, bound 7.00`. Nothing else in the file changed. (Without
  the edit, `--plant` crashed on the missing text.)
- `bot_aggression_check.py --plant` anchors on `candidate.character, now, index == 1)`. The walk's counter is
  still called `index`, so it applies unchanged: 11/11.

## What this does not show

- **Roblox milliseconds.** These are lupa instruction counts. Reasoning, not measured: in Luau, `table.sort` calls
  a Lua comparator about 280 times for 50 items, and with Luau's native vectors and costly Instance property reads
  the sort is probably a larger share of `findTarget` than lupa shows. So the Roblox saving in a crowd is likely no
  smaller than lupa's 20%, but only `tools/bot_lag_worst_tick_probe.lua` / `perf_tick_probe.lua` in Studio can say.
- **Luau's `table.sort` on ties.** The check runs Lua 5.5's sort. The argument doesn't depend on which sort it is,
  because on a tie both versions hand the same list to the same sort. That is reasoning, backed by 2,550 tied
  calls in Lua 5.5.
- **Every possible state.** The equivalence is proved for the states above, not symbolically.
- **Grid cost.** `combatantsNear` still returns everyone in a crowd (17-25% of bot work in packed-50).
- **Other branches.** `pc/teambase-v2` changes BotService only in `Vehicles.driverThink`/`startRide`, as does
  `pc/lag-bug-sweep` according to the coordinator (not pushed, so not seen). Neither overlaps this diff.
  `pc/bot-movement-smooth`, `pc/clock-deadlines`, `pc/ttk-plus-25`, `pc/hitreg-fixes` and
  `pc/mounted-guns-powerful` are already on main.
