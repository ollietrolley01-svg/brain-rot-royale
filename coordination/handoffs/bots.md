# Bots tab (claude-af [98425c]) — handoff, 2026-09-22 ~10:00, STOPPING POINT (Oliver: "land everything so far and find a stopping point")

Owns: `ServerScriptService/Modules/BotService.lua` (except claude-f0's setupAnimations/updateAnimation/giveBotGun and
claude-4a's hasLineOfSight + the BreakGlassAlong line), `BotNav.lua`, `tools/bot_probe.lua`, `tools/bot_teamfix_probe.lua`
(granted), `tools/lua_static_check.py`, MatchConfig `Bot*` block, the bot assertion (last) in `tools/runtest.ps1`.
Scratchpad: `%LOCALAPPDATA%\Temp\claude\C--Users-oliver-Downloads-claude\c6975d96-dabe-4e85-9595-df719e2d1e6a\scratchpad`
(logs `run_pin15a.log` / `run_pin15b.log`, snapshots `pin_run15a/b/c.rbxlx`, probe copies `probe15/ probe15b/ probe15c/`,
patch scripts `patch_*.py`). Oliver's items come from the source `.txt` (`make improvements to the shown map.txt`), which
wins over `OLIVER_LIST.md` when they disagree (they do for #75/#81) — say so when you find more drift.

## LANDED (tree; after the last edit: `static 345 files, 0 findings` · `OK: no problems` · `files unbalanced: 0`)
- BotNav.lua:46 `MAX_CONCURRENT_PATHS = 15` — Oliver's call ("cap it at 10", then "no make it 15"). Comment carries the
  A/B (one map, 40 bots: cap 4 worst tick 43.0 ms, cap 6 40.9 ms, both 0 rejections; the cap-16 pass LOST, Studio closed
  itself at 292 s) and the measurement at 15 (run 15a, its own seed: worst tick 32.4 ms, think 38 us, route wait max 0.24 s).
- `MatchConfig.BotFillTarget` 50 → 30 (#127). The coordinator cut Oliver's playtest build from this tree (30 bots, cap 15).
- BotNav.lua:508 `directSafe` never serves a cached "wall" answer (9-stud wall). PROVEN: run 15b S17 over the wall at
  2.3 s, armed 3.1 s, where runs 13/14/15a never got over it; the trace shows the mechanism (fresh wall 1.7, own refusal
  "too high" from standing, then parkourFromJump). Cause: the cached distance aimed the approach inside the wall, it failed
  CanStep, and navigate abandoned the goal.
- `tools/bot_probe.lua`: S25 restores the real ModeState, LOG TRUNCATED sentinel, per-sample swimming/airborne diagnostic;
  `tools/bot_teamfix_probe.lua` same; harness assertion reports the ownership CLAIM.
- Earlier (Sep 18): BotNav (queued paths, floor-checked steps, cover, stuck ladder, parkour handoff), BotService rework
  (LOS + memory, validated combat moves, crouch, heal caps, water-is-not-cover, #47 cover shooting, #46 team objectives,
  IsHostile/SpawnLoadout hooks, far-reach loot), aim nerf #118. By others 03:53 (reviewed, correct): `nextSlot` for
  replacement bots (#98/#125), `isUnderArmed` accepts a SpawnLoadout gun, burst pre-arm, HILL_RADIUS from GameModes.

## HELD — #133 idle wander ("make the bots have an idle wander when the bot count doesnt allow them to move"), NOT landed
- The only dead-still state: `BotNav.Follow`'s direct branch, straight line blocked while the route is still queued —
  `humanoid:MoveTo(root.Position)`, and navigate calls Progress(nil) so the ladder never moves it. The code (`millAbout`,
  hunk 2 of `patch_mill_wall.py`; gated copy `patch_mill_only.py`): short CanStep-checked legs around the spot, bearing =
  slot × 2.399963 + leg × 1.0 (TWO constants — one constant put waiting bots with equal slot+leg on one heading, #125
  again; the coordinator's catch), 12-stud leash, no path slot, dropped the think a route lands. Text read and approved.
- The coordinator's bar: land if the stationary-while-queued share falls and both-waiting alignment stays ~11%; land and
  say so if small but the right direction; do NOT land if drift, persistence after a route lands, or alignment high.
- The measurement FAILED it: run 15a 4.7% stationary (8 of 169 queued samples) → run 15b 6.5% (19 of 292); 66 mill legs
  fired; both-waiting pairs 5. And the metric was confounded (it counted bots holding still for a reason). At cap 15 the
  frozen state is ~0.1% of bot-samples (route wait max 0.24-0.35 s): Oliver's own cap choice removed most of it; the mill
  is a refinement, not a fix. Do not re-propose it without S26 below.
- S26 (BUILT, NOT RUN — `patch_probe_s26.py`, in `probe15c/`, on `pin_run15c.rbxlx` = tree + `patch_mill_only.py` toggles
  `BotNav.MillEnabled` / `BotNav.MaxConcurrentPaths`): 16 bots behind a 14-stud wall, a gun each beyond it, cap forced to
  0 so no route ever lands (Pump has no stale-request discard, checked), samples only when queued AND directBlocked-this-
  think AND not busy, mill OFF then ON with fresh bots, then the cap opens (yield check: route held 1.5 s later). Want:
  off ~100% stationary → on low, alignment ~11, drift < 12, yield all. Free roam in that launch runs mill OFF = tree.

## OPEN, DELIBERATELY — the watch list (one run each way is not a trend)
Wall fix side signal, run 15a → 15b (same seed, 40 bots, 150 s): 90th-percentile time to first gun 14 → 34 s; loot
fixations >25 s 1 → 5; armed 33 → 30 of 40; worst tick 32.4 → 42.6 ms; think 37.7 → 42.9 us; parkourAttempts 4 → 25.
Consistent with the mechanism (bots persist at goals they used to abandon; "abandon" may have been an accidental
fixation timeout) and with seed noise. NEXT RUN reports these beside the climb numbers; if they hold at two runs the
answer is an explicit loot fixation timeout, not a revert of the cache fix. The tree's `tools/bot_probe.lua` already
carries the S17 trace, the queued-and-stationary line and the BreakPane tell (landed 10:07, coordinator's go).

## #75 / #81 — verbatim and ruling, NOT started beyond the design
#75 "make the bots more aggressive." #81 "increase bots reaction speed and their aggressiveness." Ruling (coordinator):
aggression = commitment, not lethality — closing distance, pushing a wounded opponent, taking the fight; reaction speed is
the one dial he named. Hit rate stays at the nerfed values (#40/#118). BASELINE (run 15a): S10 first shot 0.83 s front /
2.09 s behind; rifle duels over in 3.1-4.9 s, popper 7-12 s; free roam engaged 33%. S27 (BUILT, NOT RUN, in `probe15c/`,
`patch_probe_s27.py`, approved): in-launch dial A/B, baseline vs aggressive = BotReactionTime 0.28→0.12, BotRearNoticeTime
1.2→0.7, BotEngagePreferred 70→45, BotRetreatHealth 26→15, BotCoverHealth 0.6→0.35, BotMemorySeconds 6→10; prints flank
first shot, duel first shot, distance fought at, time to finish, hits/shot. UNTOUCHED on purpose: `BotAccuracyNear/Far/
Falloff`, `BotBurstRest`, `BotThinkInterval`. Judge hits/shot AGAINST the distance delta: closing alone buys lethality
through the back door (then engage 50-55); a big distance move with a small hit-rate move means the falloff is working.

## PROVEN earlier (probe on pinned snapshots)
Unarmed wandering fixed (S22 gun 400 studs off targeted 0.4 s, armed 22 s). Aim #118 43/33/12% at 20/60/150 (old 58/43/19).
#46 hill contest/hold, 0 objectiveless. #47 barricade shots. Heal caps. Water not cover. Duck stops hits in one think.
Frag dodge. Crouch while holding. Grinding 20.6% → ~1%, failed paths 45% → 2-4%. BreakPane warn in probes = the HARNESS
(debug.info names MovementService), no bot bug. Run 14's swimming 12.5% / airborne 14% did not reproduce in three runs.

## UNPROVEN: full `runtest.ps1 -MapId` post-landing (harness NO LOG ×3; coordinator's capture fix landed, its recovery
branch never exercised — no `NOTE:` line in 15a/15b); network ownership sticks with a player nearby (playtest item).
#33 in respawn modes (claude-4a's seam) ruled by the coordinator.

## RUN C: PREPARED, NOT LAUNCHED (stopping point). `runtest.ps1 -Probe <scratchpad>\probe15c\bot_probe.lua -PlaceFile
<scratchpad>\pin_run15c.rbxlx -WaitSeconds 900` answers S26, S27 and the watch list in ONE launch. If the tree moved
since 10:07: rebuild the probe copy as tree `tools/bot_probe.lua` + `patch_probe_s26.py` + `patch_probe_s27.py` (NOT
`patch_probe_run15.py`, already landed), and pin_run15c as a tree copy + `patch_mill_only.py`, built with build_place.py.
One launch per tab per hour. Closing a Studio job is allowed now (lesson 4).

## LESSONS
1. A seam a probe overrides is restored to what it WAS, never nil (4,937 crashes voided a run).
2. A truncated log is a silent lie: 5,000-line buffer, error spam evicts results. Assert on the tail.
3. A cached answer about geometry is stale the moment the bot moves toward it. Pin the environment: A/B on one snapshot,
   place built after the edit; numbers that do not move are the tell. Fail your own feature on your own numbers.
4. (Lifted 2026-09-24 by Oliver.) A killed Studio job used to leave an Auto-Recovery modal that silently broke the NEXT
   run. The harness now moves stale `BRR_*` autosaves out of `%LOCALAPPDATA%\Roblox\RobloxStudio\AutoSaves` (the real
   path) before every launch, so closing a job is fine. Stop its script too so the lock frees.
