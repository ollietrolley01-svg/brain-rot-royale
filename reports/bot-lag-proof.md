# #113 / #126 / #131 / #99 bot lag: do the budgets hold, where is the worst tick, why does movement look low-fps?

Jacob's branch `task/prove-bot-lag`, cut from main `f1bb3b4`, then merged with main **`68bb8de`** (after Oliver merged
`pc/ttk-plus-25`, `pc/mounted-guns-powerful`, `pc/hitreg-fixes` and all-wheel drive) and run again: 0 failures, 11/11
plants, and every count the same. Main's only change to `BotService.lua` in that time is at line 6291 (a bot counts
the team kit's other defenses as its pop-up), after every line cited here, so the line references hold for both. Nothing was run in Roblox. I measured things outside Studio (Python + lupa, running the game's own Lua)
or read them from source, and each claim says which. No game file or existing tool was edited.

The rows: #113 "The bots are pretty laggy", #126 "Too many bots in one area = lag", #131 "Fix as much lag as
possible", #99 "Bot and player movement is clippy, like low fps". All four are `[~]` "in tree, unproven". The
commits: 30f6144 (think in quarters, bounded barricade rays, paced route starts), 371c029 (companions take turns),
51251bc (spatial grid, ray budget, route sharing, LOD, pooled rows), 85c3042 (bots re-claim their physics every
second), and #127 (bot counts 30 / 50).

## Verdict

**The budgets those commits describe hold on main, in the whole think loop.** I ran all of `BotService.lua` and
`BotNav.lua` through `BotService.Start`'s own loop, frame by frame at 60 Hz, with 15, 30 and 50 bots, spread out,
packed together and in teams. No frame carries more than a quarter of the bots' thinks. Every bot ray goes through
the budget, and the budget refuses in the order it says. No more than 3 route computes start in a frame, and no more
than 15 are ever in flight. LOD never defers a bot near a player, a fighting bot or a hurt one, and every bot's
physics is re-claimed at least every 1.3 s. **11 checks pass in 9 scenarios, and 11 of 11 planted faults are caught.**

**The "worst tick 32.4 / 42.6 ms" in #113 was measured on a loop that no longer exists.** Nobody has measured the
worst tick on main. Both numbers are from 09-22, before 30f6144 and 51251bc. At that time 20 bots thought in one
slice, up to 15 route computes could start in one slice, and there was no ray budget. On main, the bots' own Lua and
rays per frame are small and bounded (reasoned below). If main still has a 30-40 ms slice, it comes from something
the harness can't see. I wrote a Studio probe that names the cause: `tools/bot_lag_worst_tick_probe.lua`. **It
needs the coordinator's Studio.**

**For #126, packing bots together does not break any budget, but it roughly triples the Lua work per frame.** In a
crowd, the spatial grid returns everyone, so each think scores and sorts every bot around it. Rays per think stay
flat.

**For #99, the harness points at two causes in the bot code, both about what happens between thinks.** A bot's
walk/idle animation is chosen once per think, *before* that think moves it. A bot also sometimes reaches its waypoint
and stands still until the next think. Both are measured with a stand-in Humanoid. Whether they are what Oliver sees
has to be judged by eye in a playtest.

### Problems found, most important first

1. **Main's worst tick has never been measured, and the row's two numbers are from the old loop.** (Reasoned from
   the repo's records.) The 32.4 and 42.6 ms are `tools/bot_probe.lua`'s "worst tick", which is
   `BotService.Stats.maxTick`, the CPU time of one think slice. They come from runs 15a / 15b on 09-22 (40 bots, the
   same seed, `COORDINATION.md:1547`, `coordination/handoffs/bots.md:47`). That loop ran bots in two halves (20
   thinks a slice) and could start up to 15 `ComputeAsync` in one pump (the comment at `BotNav.lua:67-69`). It had
   no ray budget. `tools/perf_tick_probe.lua` (30f6144) was written to measure main. No result from it appears
   anywhere in `coordination/` or `COORDINATION.md`.
   On main, the harness puts a 50-bot frame at 13 thinks, at most 160 rays (the cap is 240), at most 3 route starts,
   and at most about 200 thousand Lua instructions (packed-50) of bot code. That comes to 1-3 ms in lupa. In my
   judgment, that is not a 30-40 ms slice. The likely suspects if one still happens:
   - the synchronous part of `ComputeAsync`. It runs inside `BotNav.Pump`, in the slice: `compute()` spawns the
     thread, and the thread runs until its first yield (`BotNav.lua:346-351`).
   - a garbage collection landing in the slice.
   - a yield inside a think, in a module the think calls. The harness proves no think in BotService or BotNav code
     yields (check Y1), but it does not run DefenseService, ProjectileService, WeaponService or MovementService.

   `tools/bot_lag_worst_tick_probe.lua` times each part of the worst slices in Studio: the pump and its starts, the
   refresh, each think and its branch, GC, and the frame. That separates these suspects.
2. **#126: in a crowd, `findTarget` does quadratic Lua work. That work is not rays.** (Measured.) `findTarget`
   (`BotService.lua:1309`) takes everyone the grid returns within reach (`:1318`). For each of them it calls
   `hostile()` (in a team mode a pcall to the mode's hook, `:128`; the harness sets a hook in every scenario, so
   its battle royale figures include a pcall the real battle royale, which has no hook, doesn't make) and scores them, including `CombatService.GetLastAttacker` for the
   "engaged" archetypes (`:1351`). Then it sorts the whole list (`:1376`), and looks at 3 at most. The grid has
   128-stud cells, so a spread-out bot asks about 6-11 candidates a think, but a packed bot asks about everyone. At N = 50, per think:
   44.5 candidates asked packed against 11.4 spread. That is 10.8-11.2 thousand instructions against 4.0 thousand (2.7-2.8x, across runs),
   and a worst frame of 189-210 thousand against 66-77 thousand. **`findTarget` is 65-70% of all bot work in a
   pack.** Rays per think barely move (4.67 packed, 4.50 spread): the sight cache and `LOS_CHECKS_PER_THINK = 3`
   (`:1190`) hold. So 51251bc's "3-6 candidates examined a think at 30-50 bots" is true for bots spread over the map.
   It does not hold for the bunched bots #126 is about. Per frame, the work grows as N²/4. This is not a budget
   breach. A way out, if the Studio probe shows it matters: keep the best few candidates instead of sorting all of
   them. That is for the build machine to decide. I have not tried it.
3. **#99: a bot's animation reflects the move before the one it's making.** (Measured with a stand-in Humanoid; the
   look needs a playtest.) Bots have no Animate script (`BotService.lua:511-512`). `updateAnimation`
   (`:541`) is the only thing that changes their walk/run/idle track. It is called once per think, at the top of
   `updateBot` (`:5546`), reading `MoveDirection` before this think issues its `MoveTo`. So a bot that stopped and
   is sent on again plays **idle while it walks** for a whole think (0.27 s, or 0.53 s under LOD). A bot that
   reached its point plays **walk while it stands**. Near a player, the walk track plays on 25-42% of the frames a
   bot stands still (fights, teams, roaming). The idle track plays on 5-22% of the frames a bot moves. For bots far
   from every player (LOD), idle plays on 89% of a roaming bot's moving frames. On screen that would be sliding and
   walking on the spot. Nothing adjusts the playback speed either: `walk` above 0.5 studs/s, `run` above 20.
4. **#99: a bot on a route stops at its waypoint until the next think.** (Measured with a stand-in pathfinder.)
   `BotNav.Follow` gives the Humanoid one waypoint at a time (`BotNav.lua:903`) and moves to the next only at a
   think, once within 4 studs (`ADVANCE_FLAT`, `:81`). Roblox spaces waypoints 4 studs apart by default (platform
   knowledge, not measured), and `AGENT` doesn't change it (`:109-116`). At 17 studs/s a bot covers 4.5 studs in a
   think, so it sometimes arrives early and stands. Near a player: stopped on 3.1% of route frames, 162 stops in
   12 s of 30 bots, averaging 53 ms (about 3 frames). Under LOD (a think every 0.53 s, 9 studs): stopped on 27-33% of
   route frames, averaging 166-189 ms. LOD only applies past 300 studs from every player. A player can still see
   that far, for example through a scope.
5. **#99: 85c3042's re-claim holds.** (Measured.) Every living bot calls `SetNetworkOwner(nil)` at most every
   1.28 s (1.55 s under LOD) (`BotService.lua:5541-5544`, check C1, plant caught). What it leaves, by reasoning: after
   a weld change (a gun, a canopy), a client can own the bot for up to that long. Whether ownership still flips in
   live play can't be measured here.
6. **#99: a bot's vault, climb and drop glide are timed on `os.clock()`.** (Reasoned, not measured.)
   `MovementService.TryParkour` places the root every Heartbeat at `Parkour.PositionAt(plan, os.clock() - started)`
   (`MovementService.lua:972-979`). The bot drop is timed the same way (`:650`, `:688`). COORDINATION.md (`:560`) says
   `os.clock()` is CPU time in Roblox. If that runs apart from wall time under load, these moves play too fast
   (skipping frames) or too slow. The clock ratchet has these 6 sites grandfathered (`tools/clock_ratchet.py:51`).
7. **Minor: `FindCover`'s room check is outside the ray budget.** (Measured.)
   `workspace:GetPartBoundsInRadius` (`BotNav.lua:680`) ran 78 times in 12 s of packed-50 (about 6 a second), with
   none in spread. `FindCover` also builds a fresh step-params table and filter each call (`:590`, reasoned). The
   linear scans still left over the whole combatant snapshot came to at most 0.4% of bot work in every scenario:
   `modeObjective` `:1630`, `Loot.enemiesNear` `:5111`, `Loot.threatened` `:5485`, `placeBarricade` `:2435`,
   `tryThrow` `:2721`.

**Nothing on the server moves a player during normal movement.** (Reasoned, from a grep of every `PivotTo`,
`.CFrame =` and velocity write in `ServerScriptService`.) The player-facing ones are spawning, the drop, team-mode
spawns and leaving a mounted gun. So if player movement looks low-fps, it's the client's frame rate or replication,
not server code. That needs a playtest.

## 1. The think loop, end to end (main 68bb8de)

- **Every 4 frames:** `BotService.Start`'s thread wakes (`task.wait(0.25 / 4)`, `BotService.lua:6416`, rounded up to
  4 frames at 60 Hz). `BotNav.Pump()` (`:6429`) starts up to 3 route computes (`BotNav.lua:73`) while fewer than 15
  are in flight (`:64`). A route a neighbour computed in the last 8 s is copied instead.
- **Then:** `refreshCombatants()` (`:6431`) snapshots the living combatants, rebuilds the 128-stud grid and **opens
  the ray budget** (`:1123`).
- **For each bot whose index % 4 matches the slice:** if `BotService.LodDefers` doesn't defer it (`:6434`), it calls
  `pcall(updateBot, bot)` (`:6439`). LOD defers every other think of an idle bot more than 300 studs from every
  player. It never defers one that is fighting, fleeing, dodging, in the storm or just hurt (`:6367-6392`).
- **Inside a think:** the bot re-claims its physics if the last claim is over 1 s old (`:5541`), updates its
  animation (`:5546`), then looks for a target (`findTarget`), fights, or navigates. Every ray goes through
  `RaycastBudget.Cast` (`:932`). It grants combat rays up to the cap (240), navigation to 3/4 of it and idle to half,
  and otherwise returns `nil, false`. `BotNav.CastRay` is the same function (`:965`).

## 2. What I ran, and the numbers

`tools/bot_lag_proof_check.py` loads `BotService.lua` and `BotNav.lua` whole, with `tools/bot_archetype_sim.py`'s mock
map, characters and module mocks, plus `tools/bot_lag_proof_world.lua`. That file adds the real BotNav in place of
the sim's mock, a PathfindingService (straight routes, a waypoint every 4 studs, `ComputeAsync` yields 0.4 s), a
raycast with face normals and a floor, Heartbeat and a thread scheduler. Every bot is a real Spawn table with a
`CrocodiloRifle`. There is one player standing at the centre who can't be hurt. Bots have 400 health, so a crowd
stays a crowd for the 12 s. The profiler counts game-code instructions (one sample per 1000) and attributes them to
the BotService / BotNav function running, and to the path `updateBot` took to it. Milliseconds come from a second,
unprofiled run.

| scenario | worst thinks / frame | worst rays / frame (cap 240) | worst route starts / frame | most in flight | worst k-instr / frame | lupa ms, worst |
|---|---|---|---|---|---|---|
| spread-15 | 4 | 61 | 2 | 8 | 26 | 0.5 |
| spread-30 | 8 | 95 | 3 | 11 | 41 | 0.9 |
| spread-50 | 13 | 160 | 3 | 12 | 73 | 1.3 |
| packed-15 | 4 | 43 | 1 | 4 | 28 | 0.8 |
| packed-30 | 8 | 104 | 2 | 6 | 80 | 1.4 |
| packed-50 | 13 | 135 | 3 | 14 | 196 | 2.9 |
| teams-30 | 8 | 62 | 3 | 15 | 69 | 1.4 |
| roam-30 (unarmed, near the player) | 8 | 33 | 3 | 15 | 28 | 2.5 |
| stress-50 (packed, cap forced to 40) | 13 | 50\* | 3 | 13 | 216 | 7.6 |

\* per frame; per slice it was 40 of 40, with 10,244 rays refused over 120 slices, and no errors.

Run to run, the instruction counts vary by about ±10% (Lua table order) and the lupa milliseconds by more (the
machine's load). The ray, think and route counts don't vary. **lupa milliseconds and instructions are not Roblox
milliseconds.** They show where the work is and how it grows with N and with packing. Luau's vectors are values, not
tables, so the lupa figures overstate `grid.Near`'s share (reasoned).

**Where the work goes (instruction samples, whole run):**
- spread-50: `findTarget` 43%, `fight` 37%, `refreshCombatants` 8%. By function: `grid.Near` 21%, `findTarget`
  13%, `hostile` 8%, `planCombatMove` 7%.
- packed-50: `findTarget` 70%, `fight` 24%, `refreshCombatants` 3%. By function: `findTarget` 30%, `grid.Near` 17%,
  `hostile` 16%, `byScore` (the sort) 13%.
- teams-30: `findTarget` 59%, `fight` 26%. The worst frame in each is `findTarget` + `fight` (together 88-95%).

**Rays by who asked (whole run):** spread-50: `FindCover` 33%, `CanStep` 33%, sight lines (`hasLineOfSight`) 23%,
barricade tests (`coverBetween`) 10%. packed-50: `CanStep` 38%, sight 27%, `FindCover` 23%, barricade 12%. By path,
the `fight` branch casts 66-67% of all rays. **In normal play the cap never engaged:** the most any slice cast was
160 of 240 (spread-50).

**#126, packed against spread, per think:** at N = 15, 30 and 50, candidates asked 5.6 / 8.1 / 11.4 spread against
13.2 / 28.4 / 44.5 packed. Rays 3.9-4.5 against 4.4-4.7. Instructions 3.5-4.0 thousand against 4.8 / 7.6 /
10.8-11.2 thousand.

**#99, movement between thinks.** "Near" means within 300 studs of the player; "far" means LOD applies.

| scenario | route frames stopped at a reached point | mean stop | walk/run track while standing | idle track while moving |
|---|---|---|---|---|
| roam-30 near | 3.1% | 53 ms | 39.6% of standing frames | 19.6% of moving frames |
| roam-30 far | 32.6% | 180 ms | 13.0% | 89.1% |
| spread-50 far | 30.1% | 176 ms | 10.4% | 10.1% |
| packed-50 near (fighting) | (not routed) | | 39.3% | 11.4% |
| teams-30 near (fighting) | 9.1% | 94 ms | 41.9% | 15.3% |

No `MoveTo` was ever issued outside a think (0 in every scenario). A bot's movement command changes only when it
thinks.

## 3. The checks and planted faults

| check | the invariant | planted fault (in a copy of the source) |
|---|---|---|
| T1 | no frame carries more than ceil(N/4) thinks | `THINK_SLICES = 1` |
| T2 | a bot thinks every 16 frames; with an LOD deferral between, every 32 | a fifth, empty slice |
| R1 | every ray from bot code comes through `RaycastBudget.Cast` | sight lines cast with `workspace:Raycast` |
| R2 | no slice grants more than the cap; no idle ray past half, no navigation ray past 3/4 | the cap and shares doubled |
| R3 | a refusal happens only in a slice that spent at least half the cap | the budget never reopened |
| P1 | at most 3 route computes start a frame | `MAX_STARTS_PER_PUMP = 15` |
| P2 | at most 15 in flight (and some scenario reaches 15) | `MAX_CONCURRENT_PATHS = 40` |
| L1 | LOD never defers a bot within 300 of a player, fighting, or hurt | `fight` out of `LodActiveBranches`; LOD ignoring distance |
| Y1 | no think yields part way | a think that sometimes calls `task.wait()` |
| C1 | every living bot is re-claimed at least every 1 s + one think | re-claim every 3 s |
| E1 | no Lua error in any think | (errors from any plant count) |

```
bot_lag_proof_check: 9 scenarios, 6240 frames, 12336 thinks, 49646 bot rays examined; 0 failures
bot_lag_proof_check plants: 11/11 caught
```

Examined: 6,240 frames, 12,336 thinks, 49,646 bot rays (every one attributed), 414 LOD deferrals and 364 route
computes.

## 4. If `pc/teambase-v2` merges

It touches `BotService.lua` (10 lines), `BotNav.lua` (29 lines) and `BotDriveTactics.lua`. All of that is on the
driving path. A base vehicle's first route follows the base's access road (`Vehicles.driverThink`,
`Vehicles.startRide`). `BotNav.DriveRoute` sends a drive into the arena through its nearest gateway, with one nested
`DriveRoute` call. `MatchConfig` goes from 6 to 7 base vehicle slots. I ran the check on
`origin/pc/teambase-v2` (776713a) with `--rev`: **0 failures, 11/11 plants caught, identical think, ray and route
counts**, and instructions within run-to-run noise. The harness has no vehicles, so the changed lines themselves
don't run. By reasoning, `DriveRoute` runs when a ride's route is built, not every frame, and bots at the wheel are
still capped at `BotDriversPerTeam` = 4. No change to the per-frame budgets.

The other `pc/*` branches don't touch BotService or BotNav. `pc/ttk-plus-25` changes `CombatDamageScale` (0.92 →
0.736). The harness mocks `CombatService`, so it applies no damage scale at all. No number here is a damage number,
and damage only decides who dies when.

## 5. For the coordinator: `tools/bot_lag_worst_tick_probe.lua` (never run)

`runtest.ps1 -Probe tools/bot_lag_worst_tick_probe.lua -WaitSeconds 900`. Every line starts with `[BRR_Lag]`. It edits
nothing. It wraps `BotNav.Pump` and `BotService.LodDefers`, which the loop calls through their module tables, and
reads `BotService.Stats`.
- **Part A**, 50 bots spread and 30 in one 30-stud circle. It prints the 8 worst slices and the 8 worst frames. Each
  gets its parts: the pump and how many `ComputeAsync` it started, the refresh, every think with the slowest and its
  branch, whether GC ran, and the frame time. It also groups slices by route starts (0 to 3), with a median and worst
  for each. If the 3-start slices are the worst, `ComputeAsync` is the tick. Plant A: one pump stalled 40 ms. The
  worst slice must be that one, with "pump" as its biggest part.
- **Part B**, 20 bots nobody is hostile to, with LOD off and on. Per Heartbeat, it records routed bots standing still
  and the length of each stop, the walk track while standing, and the idle track while moving. These are the real
  Humanoid's versions of findings 3 and 4. Plant B: one routed bot anchored for 3 s must read stopped on at least 90%
  of those frames.
- It cannot show what a client sees. That needs a playtest with a second client watching bots near and far.

## Outside the brief

- **`tools/clock_ratchet.py` exits 1 on main** (it is in CLAUDE.md's fast set, not one of the three checks
  below). On `f1bb3b4` it flagged `StarterPlayerScripts/MountedGunClient.client.lua` (78ea65d) as having 2
  `os.clock()` deadlines off the baseline, at `:299` and `:562`. Both are `math.sin(os.clock() * k)` wobbles in a
  client animation, not deadlines, so that looks like a ratchet false positive. On `68bb8de` it also flags
  `CombatClient.client.lua`, at 10 deadlines against 8 accepted. The two new ones came with `pc/hitreg-fixes`
  (b254eac): the shot-in-flight age at `:716-721` and the auto-reload retry at `:759-760`. Those are real
  deadlines. Reported in the mailbox as a bug, not fixed.

## What this does NOT prove

- **Any Roblox millisecond.** The worst tick on main is unmeasured. Lua instruction counts and lupa milliseconds
  don't convert to server frame time.
- **Anything that needs a real Humanoid, PathfindingService or replication.** The walk is a stand-in (full speed at
  once, stopping exactly on the point). Routes are straight lines with a fixed latency. The 4-stud spacing is Roblox's
  documented default, not measured. The stop and animation figures predict what the probe's part B should show; they
  are not a picture. **Whether the bots look low-fps is Oliver's to judge by eye.**
- **Vehicles, companions, loot and the storm.** They are not in these scenarios. CompanionService is mocked; its
  slicing (371c029) is covered by `tools/perf_bot_cost.py` section D, which passes on main (0 failures). The
  per-frame vehicle servo (`BotService.lua:3938`) did not run.
- **Player movement for #99.** It's out of the harness. The only claim is the grep above.
- **Memory.** I dropped KB per frame: lupa allocates a table for every Vector3 and Luau does not.
- `tools/perf_bot_cost.py` still passes on main (0 failures). This check adds the whole-loop view; it doesn't replace
  those slice checks.

## After the #99 fix (branch `pc/bot-movement-smooth`)

Findings 3, 4 and 7 are fixed in the game code, and the check now holds them as passing rows (M1, M2, and
R1 without its old GetPartBoundsInRadius exemption), each with a planted fault: 14/14 plants caught.

- **Finding 3 (animation):** `BotService` picks the walk/run/idle/fall/jump track from the Humanoid's own
  `Running` and `StateChanged` events (the ones a player's Animate script uses), hooked up on a bot's first
  think; the think keeps only the gun pose. Harness: the wrong track on 0.0% of standing and moving frames
  in every scenario (was 25-42% / 5-22% near, 89% idle-while-moving under LOD). Bar: at most 2%.
- **Finding 4 (waypoint stops):** `BotNav` continues a route on `MoveToFinished`: a bot that reached the
  waypoint Follow handed it in its latest think walks on to the next Walk waypoint of the same route. Any
  later think, a new route, a detour, a climb, parkour, a seat or a jump waypoint leaves it for the think.
  Harness: 0.0% of route frames in roam-30 near/far and spread-N far (was 3.1% / 27-33%). Bar: at most 1%.
  teams-30 still shows 3.3% on 244 route frames (route ends, which aren't continued), and stress-50 stops
  where the budget refuses, on purpose.
- **Finding 7:** FindCover's room check spends the ray budget (`BotNav.CastSpend`) before its
  `GetPartBoundsInRadius`, and gives up the search as "budget" when refused, like its rays.
- **Cost (M3):** the event handlers run outside the think: 0.7-3.5 events a bot-second, 47-159 VM
  instructions an event including the mocks (a think is about 4000), a frame's events at most 1.3
  thousand instructions against 25-209 thousand of bot work.

Harness fixes made on the way: BotNav's in-flight route count leaked from one scenario to the next
(computes still yielding when the world was reset never finished), so later scenarios ran with fewer
route slots; a thread that errored crashed the scheduler (its error text used as a wait time); the mock
Humanoid had no `ChangeState` (the stuck ladder's hop). None of this is Roblox-measured: whether Running
fires on the server for a server-owned bot as often as assumed, and how it looks, needs Studio / a playtest.
