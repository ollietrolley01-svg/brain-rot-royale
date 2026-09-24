# Cloud session status: the consensus (2026-09-24)

Written by the coordinator for the 09-24 cloud session (Oliver: "make an agent that organizes and
streamlines the work, to make them all work together, coordinated with each other, and gives back a
consensus on the status of the project"). Measured against the working branch
`claude/roblox-game-tasks-wv7n8k` at **58db872** and every worker worktree (committed and uncommitted),
not taken from anyone's own report. Re-run the three checks at the bottom whenever new work lands.

Status words: **merged-to-main** (in origin/main 6bad2f1) · **on-branch** (on the working branch, not
main) · **in-worker-branch** (committed in a worker's worktree, not cherry-picked yet) · **running**
(a worker is on it, uncommitted) · **needs-Studio** (code is in; only a playtest or a probe on Oliver's
machine can prove it) · **declined** (Oliver said no or parked it).

Nothing below is "done" in the ledger's sense until Oliver plays it: every row the session touched is
`[~]` "in tree, unproven (commit X)" in OLIVER_LIST.md.

---

## 1. Oliver's requests this session

| Request (Oliver's words where we have them) | Status | Where |
|---|---|---|
| URGENT: first-person arms/viewmodel missing with an R15 avatar | on-branch, needs-Studio | ac4b982 |
| Bots and other players don't animate | on-branch, needs-Studio | d8cd917 |
| "supply drops still deposit straight to inventory" (#85) | on-branch, needs-Studio | 3441c0f (1 s settle), d508889 |
| "no one's dropping loot in battle royale" | on-branch, needs-Studio (`tools/death_drop_probe.lua`) | 5e2ac79 |
| "make the companions other than Secret ones not one-shot" | on-branch | 9ba776b, 9770fd5 (harness) |
| "improve the rewards for team gamemodes too" | on-branch (v1) + in-worker-branch (v2) | 612dbf0; v2 cefd997 (worktree a4b8) |
| Vehicle gun "the aim to follow your mouse" | on-branch | d9257c2, critic fix f1a2ffb |
| "the guns on the cars HUD is overlapping" (#80) | on-branch | 6639f24, 18b25f0, e184912 |
| Car placements that make sense: kerb, car parks, driveways, verges (#16/#31/#94) | on-branch; roads audit continuing | 951ec86 |
| Team bases: ruined compound, six vehicles in bays, fourteen chests | on-branch, needs-Studio (`team_base_ruins_gallery`) | 8f0b8bd, b186543, 4de048f, a62a419, 1a51602 |
| KOTH objectives fair to both teams | merged-to-main | 258530f |
| Remove crosshair range greying | on-branch | ecec2d2 (reverts 4f503f1) |
| Death effects (#24): 15 effects + DEATH EFFECTS shop with previews | on-branch, needs-Studio (`killanim_gallery`) | df35ef0, 408a8b7, 5ba42e8 |
| Brainrot ability animations/VFX (A5) | on-branch, needs-Studio | 1d344a1 |
| Cracking per material instead of fading (#71) | on-branch, needs-Studio (`crack_gallery`) | 67965f1, e7a3acf |
| Every kerbside car a real design | merged-to-main (watch the part budget) | 9d56860 |
| Hitreg option A, shooter wins (#97) | merged-to-main, needs-Studio (`hitreg_rewind_probe`) | c102b7d, affa05e |
| Explosive ammo: small blast, Golden Sahur Cannon only (#122) | merged-to-main | 6ef6a52 |
| Team arena slightly smaller (#5), codex A-Z (#130), storm text (#45) | merged-to-main | 4918382 |
| Bots drive every vehicle, gunner seat, player takeover | in-worker-branch (WIP, worktree a75ab) | a162b26, dc04372 |
| Bot archetypes: fighting, per-gun behaviour, throwables, defenses | in-worker-branch (worktree ac9f) | ed10cad, cabbdb2 |
| Bot archetypes: looting and rotation | in-worker-branch (worktree a300) | 9294c54 |
| Bot optimisation (ray budget, spatial index, LOD) | in-worker-branch (WIP, worktree a16b) | 26cf878 |
| Gun rework: 20-30 guns, signature flairs, 3-4 new guns | on-branch (batch 1, 16 guns) + running | 7e61c81; worktree aeb4 |
| Central team battleground | running (worktree a762, uncommitted) | TeamBattleground.lua |
| Roads audit: flush and connected | running (worktree a2f8, uncommitted) | |
| Building foundations / placement audit | in-worker-branch (worktree a670) | 25c8c8c, 71e9f9f |
| Foliage spread | running (worktree a7a3, uncommitted) | |
| Defense placement anywhere | running (worktree abcb, uncommitted) | |
| Quality gate + findings | in-worker-branch (worktree a0b4) | 9c65c98, c1ad10b, 0f5638c |
| Critic pass | on-branch | f1a2ffb, 6316d99 |
| Merge the branch to main, build a final playtest, publish | needs-Studio (Oliver: playtest first, then PR, then `tools/publish.ps1`) | |
| Shotgun nerf; barricade click-to-place; bot idle wander; tom pearl; bigger maps; controls legend; lean (#79); crosshair greying | declined | 5465a25 (lean), ecec2d2 |

## 2. OLIVER_LIST items the session touched

All `[~]` in OLIVER_LIST.md with their commits. **On main:** #5 #7 #20 #22 #25 #29 #30 #41 #42 #45 #51
#56 #57 #63 #69 #70 #72 #76 #77 #78 #84 #89 #90 #93 #97 #99 #103 #107 #109 #110 #113 #114 #115 #116
#117 #120 #122 #126 #130 #131 #132. **On the branch only:** #11 #13 #16 #24 #26 #31 #34 #35 #39 #44 #50
#61 #71 #75 #80 #81 #85 #86 #92 #94 #112 A5. **Removed on Oliver's word:** #79 (`[x]`, 5465a25).
Two rows went DOWN from `[x]` to `[~]` because the session changed them after they had been ticked:
**#85** (Oliver reported supply drops still going straight to inventory) and **#115**, plus #5 (arena
resized again). Nothing is `[x]` that Oliver hasn't confirmed or decided.

## 3. Known bugs from playtests, and where their fixes stand

| Bug | Fix | State |
|---|---|---|
| FPS arms/gun missing on R15 avatars | Viewmodel LookOf no longer reads MeshId (ac4b982) | on-branch, needs-Studio |
| Bots / other players frozen in a T-pose-ish stance | GunPoseClient poses only while aiming; bots back on WeldConstraint mounts (d8cd917) | on-branch, needs-Studio |
| Supply-drop loot goes straight into inventory | spill + 1 s settle before it can be taken (3441c0f) | on-branch, needs-Studio |
| No death drops in BR | drops can't be lost silently (5e2ac79); probe `tools/death_drop_probe.lua` | on-branch, needs-Studio |
| Vehicle gun HUD overlaps | 6639f24 | on-branch |
| Vehicle gun cursor fought MenuCursor (#112 regression) | f1a2ffb | on-branch |
| Cars bounce/glitch at speed (#84/#109) | damper reads velocity (3f1d7b6) | merged-to-main, needs-Studio (`vehicle_stability_probe`) |
| Worst server tick 42.6 ms (#131) | quarters + paced routes on main; the ray budget/spatial index is in worktree a16b | partial |

## 4. File ownership and predicted merge conflicts

Measured with `git merge-tree` on a snapshot of every worktree (committed + uncommitted) against 58db872:

| Worker | Worktree | Game files it changes |
|---|---|---|
| vehicles (bots drive) | a75ab | BotService (BOT VEHICLES), BotNav (+1100 lines, DriveRoute), VehicleService, VehicleWeapons, VehicleModels, VehicleClient, MatchConfig |
| archetypes (fighting) | ac9f | BotService (dials at top, BOT ARCHETYPES section, hostile, findTarget, planCombatMove, fight, tryHeal, Clear) |
| looting / rotation | a300 | BotService (LR section, updateBot loot path, tryHeal, holdLoot, FindBaseLoot, STATS) |
| bot optimisation | a16b | BotService (castRay, SpatialQuery, refreshCombatants, findTarget, planCombatMove, STATS, Clear), BotNav (CanStep, FindCover, CastRay) |
| gun rework | aeb4 | WeaponData, Arsenal*, GunModels, GunModelsSignature, SoundConfig, StatusEffects, CombatService, CombatClient, Viewmodel |
| battleground | a762 | TeamBattleground (new), ModeTeams, ModeKingOfTheHill, BotNav (FindCover, CoverHints) |
| roads | a2f8 | RoadNetwork, MapDecor, MapGenerator (`draw`), ParkingLots |
| foundations | a670 | MapBuildings, TownThemes, MapWilds (placeShelter, treeKindFor), MapTerrain (RewritePads), MapGenerator (`placeNext`), Landmarks, EasterEggs |
| foliage | a7a3 | MapWilds (patch, shrub, clearOfTrunks, welcome) |
| defense anywhere | abcb | DefenseService, DefensePlacement, DefensePreview |
| rewards v2 | a4b8 | MatchConfig, CosmeticData, RewardService, ResultsScreen, economy_model.py, verify.py |
| quality gate | a0b4 | HudClient (five locals), tools only |

Predicted conflicts (everything else merges clean, in any order):

| Pair | File | Hunks | Kind |
|---|---|---|---|
| archetypes x botopt | BotService | 5 | **semantic**: findTarget candidate rows, planCombatMove options, CanStep signature, STATS list, Clear |
| archetypes x looting | BotService | 3 | STATS list, tryHeal threshold (both rewrote the same line), both new sections at the same anchor |
| vehicles x archetypes / looting | BotService | 1 each | new sections inserted at the same anchor after `Vehicles.considerVehicle`: keep both |
| looting x botopt | BotService | 1 | STATS list: keep both |
| botopt x battleground | BotNav | 1 | FindCover signature: botopt adds `priority`, battleground adds `BotNav.CoverHints` above it |
| guns x tip | GunModelsSignature, SoundConfig, CombatClient, Viewmodel | - | the worktree is still on 4de048f with batch 1 uncommitted; batch 1 is already on the branch as 7e61c81. The worker must reset onto the tip before its next commit |
| roads x foundations | MapGenerator | 0 (different functions) | clean, but both change build order: land roads first |
| foundations x foliage | MapWilds | 0 (different functions) | clean |

### Merge order (who rebases on whom)

1. **quality gate** (a0b4): tools + five HudClient locals. Independent.
2. **rewards v2** (a4b8), **defense anywhere** (abcb): independent of everything.
3. **gun rework** (aeb4): after it resets onto the tip (batch 1 is already in). Before archetypes, so new gun styles exist when the bots' style tables are checked.
4. **roads** (a2f8), then **foundations** (a670), then **foliage** (a7a3): map pipeline in build order; foundations' grading and foliage's spacing read the final road footprint.
5. **bot optimisation** (a16b): the infrastructure every bot section is told to use (castRay, SpatialQuery, reused rows). It merges clean against the tip.
6. **vehicles** (a75ab): clean on top of 5.
7. **battleground** (a762): rebase on 5 (one BotNav hunk: keep `priority`, add `BotNav.CoverHints` and call it from inside FindCover).
8. **archetypes** (ac9f): rebase on 5+6. Its findTarget / planCombatMove edits must be rewritten onto the pooled rows (see mismatch 2 and 3).
9. **looting** (a300): last, on 8. It reads the archetype hook, so it lands after the thing it reads, and mismatch 1 is fixed as it rebases.

## 5. Contracts (cross-worker interfaces)

| # | Interface | Producer | Consumers | Branch today | In worker branches | Mismatch |
|---|---|---|---|---|---|---|
| K1 | Seat `GunnerSeat` with attribute `Gunner = true`; player attribute `VehicleRole` | VehicleService.makeSeat (vehicles) | VehicleWeaponClient, HudClient, VehicleWeapons.GunnerSeatOf, BotService | consumers only (no maker) | vehicles makes it on the model, as the consumers expect | none once vehicles lands (contracts_check K-note clears itself) |
| K2 | `VehicleGunActive` player attribute | VehicleWeaponClient (client-local) | HudClient, BoonHud | consistent | unchanged | none; must never be set server-side (C7 checks) |
| K3 | `BotService.ArchetypeOf(bot)` + dials | archetypes: returns the archetype TABLE, stores it in `bot.archetype` | looting LR.archetypeOf | not on branch | both | **looting overwrites `bot.archetype` with a string** and reads ARCH's loot keys with other meanings (mismatch 1) |
| K4 | castRay / RaycastBudget / SpatialQuery / BotNav.CastRay, `CanStep(..., priority)` returning `ok, reason`, `FindCover` returning `nil, nil, "budget"` | botopt | every bot section, BotNav | not on branch | vehicles, battleground and archetypes predate it | raw `workspace:Raycast` added by vehicles (+1 BotService, +2 BotNav) and battleground (+1 BotNav); archetypes' pooled-row clash (mismatch 2, 3) |
| K5 | `DefenseService.Deploy(owner, character, itemId, centre, facing)`; new `CheckSite` | defense | archetypes' barricade logic | Deploy unchanged | defense adds CheckSite, Build(…, plan) | none; archetypes may use CheckSite to avoid a wasted Deploy |
| K6 | KOTH objective positions | ModeKingOfTheHill.Objectives (battleground overrides from `ModeTeams.Battleground().objectives`) | BotService.ModeState, ObjectiveZone, HUD | fair-placement 258530f | battleground puts A on the keep FLOOR (raised) | ObjectiveZone.Contains allows 6 below / 22 above, so a raised A works; bots' ring points round A may land outside the keep walls: needs-Studio |
| K7 | `BotNav.CoverHints(origin, radius)` | ModeTeams (battleground) | BotNav.FindCover | absent | battleground | FindCover signature clash with botopt (mismatch 5) |
| K8 | `ModeTeams.BaseVehicleBays` / `BasePads` / `BaseVehicleFolder` | ModeTeams (team bases) | vehicles' BotService (BaseVehicleFolder) | defined | unchanged | none |
| K9 | `LootService.BaseStock`, `FindBaseLoot`, `ClaimForBot`, `ClaimHealForBot` | LootService | GameMode, looting | defined | looting uses existing names | none |
| K10 | CollectionService tags (DestructibleService pools, PracticeDummy, armed vehicles) | map builders, DestructibleService | DestructibleService, CompanionService, RangeService | consistent (contracts_check C3) | foundations/foliage/roads must keep tagging new props | re-run C3 after the map workers land |
| K11 | Road network: `mapInfo.roads` (RoadNetwork methods GroundAt, WithinCorridor, Curves, NearBridge...), parts named `Road` / `RoadCurve` under `Map.Roads` | RoadNetwork / MapGenerator | foliage, foundations, ParkingLots, DropMapService, looting LR.roadPoints, vehicles DriveRoute | stable | roads worker has not changed the API | **nobody calls `BotService.SetRoads`** (mismatch 4) |
| K12 | Weapon ids / `style` | WeaponData, Arsenal* (guns) | GunModels STYLES, LootService + InventoryPanel type words, BOT_WEAPON_HOLD, ARCH.Classes, LR.CLASS_OF_STYLE | 15 styles, all covered | no new style yet | any new style must be added to all five tables (C6 checks the ones on the branch and both bot tables once they land) |
| K13 | Cosmetic kinds (Accessory, Aura, GunSkin, KillAnimation, Parachute) | CosmeticData | PlayerData default `Cosmetics` slots, CrateData `kinds`, menus | consistent (C8) | rewards v2 adds team-only cosmetics | a NEW kind needs a lower-camel slot in PlayerData defaults (additive) and a menu tab |
| K14 | SoundConfig cues | SoundConfig (guns own the gun section) | every Sfx.Play/PlayAt/PlayDistant/Loop | consistent (C4) | guns rewrite 334 lines | re-run C4 after guns land |
| K15 | Remotes by name | server modules | clients | consistent (C2) | vehicles adds none new; VehicleJolt unchanged | none |
| K16 | STATS keys | BotService STATS list | tools/bot_*_sim.py | - | four workers each append keys to the same list | textual conflict only: keep every key |

### Top 10 mismatches and conflict risks, with the exact fix

1. **`bot.archetype` means two things (archetypes vs looting). Crash.** ARCH stores the archetype table in
   `bot.archetype`; `LR.archetypeOf` (looting, BotService) writes the NAME string into the same field,
   after which `ARCH.dialsOf` runs `pairs(archetype)` on a string and the bot's think errors every tick.
   Fix in looting: in `LR.archetypeOf` use its own fields: replace `bot.archetype` with `bot.lootKind`
   and `bot.archetypeAt` with `bot.lootKindAt` throughout the function, and replace
   `bot.archetypeDials = type(result) == "table" and result or nil` with `bot.archetypeDials = nil`.
2. **The same dial names, different meanings.** ARCH.Types carries `lootGreed, preferredWeaponClasses,
   rotateEarly, chestPriority, healPriority`; ARCH's `preferredWeaponClasses` are styles ("shotgun") and
   `rotateEarly` is a boolean, while LR's are buckets ("close") and a 0-1 number. With `archetypeDials`
   dropped (fix 1) LR reads only LR.DIALS. Fix in archetypes: delete those five keys from the six
   ARCH.Types rows and the header comment line "Loot and rotation dials (...) are DEFINED here"; the
   loot dials live in LR.DIALS.
3. **Flank options leak into botopt's pooled option list.** botopt makes `options = scratch.combatOptions`
   (nine reused rows); archetypes appends flank rows with `table.insert(options, …)` every replan, so
   the pooled list grows without bound. Fix when archetypes rebases: before the flank block add
   `for i = #options, 10, -1 do options[i] = nil end`, and build its flank rows as pooled rows
   (`kind = 10/11`) rather than new tables.
4. **Bots never get the road network.** vehicles adds `BotService.SetRoads(network)`; nothing calls it,
   so every bot drive is off-road. Fix (MatchService.lua, unowned): after `BotService.Clear()` in the
   match start (line ~1625) add `if BotService.SetRoads then BotService.SetRoads(mapInfo and mapInfo.roads) end`.
   The same call is needed wherever a team-mode map is built if it bypasses that path.
5. **FindCover signature (botopt x battleground).** Resolve as
   `function BotNav.FindCover(root, character, threatPosition, radii, isAllowed, threatCharacter, priority)`
   with `priority = priority or "navigation"`, keep `BotNav.CoverHints = nil` above it, and try
   `BotNav.CoverHints` points first through `BotNav.CastRay(..., priority)`. Callers must handle the
   third return `"budget"` (retry next think, don't count a search).
6. **Findtarget candidate rows (archetypes x botopt).** botopt reuses `candidatePool[count]` rows;
   archetypes multiplies `score` and then `table.insert`s a fresh table. Keep botopt's row code and put
   archetypes' `targetPick` / team-focus multipliers immediately BEFORE `count += 1`, so they change
   `score` only.
7. **Raw rays bypass the budget.** vehicles adds one `workspace:Raycast` in BotService and two in BotNav;
   battleground one in BotNav. After botopt lands, change each to `castRay(origin, dir, params,
   "navigation")` (BotService) / `BotNav.CastRay(origin, dir, params, "navigation")` (BotNav) and treat
   `granted == false` as "can't drive/step there this think".
8. **Heal threshold written twice (archetypes x looting, tryHeal).** Resolve as
   `local healBelow = (bot.archetype and ARCH.dialsOf(bot).healBelow) or LR.healBelow(bot)`, i.e. the
   fighting personality owns the threshold and the loot stock target is the fallback; delete whichever
   side's line is not this.
9. **Gun worktree is behind its own cherry-pick.** aeb4 is still on 4de048f with batch 1 uncommitted;
   7e61c81 already carries batch 1, so any new commit there conflicts in four files. Fix: the gun worker
   commits, then `git rebase claude/roblox-game-tasks-wv7n8k` (drops the batch-1 duplicate) before
   batch 2. New styles, if any, go into all five style tables (K12) in the same commit.
10. **STATS key lists and same-anchor sections.** Four workers append to one STATS list and three insert
    their new section at the same place (after `Vehicles.considerVehicle`, before `updateBot`). Every one
    of these hunks is "keep both": order the sections VEHICLES, ARCHETYPES, LOOTING & ROTATION and keep
    every STATS key. Also mind BotService's local budget: the file is near Luau's 200-local limit
    (tools/local_limit_check.py in the quality gate); each section hangs off one table (`Vehicles`,
    `ARCH`, `LR`) and must stay that way.

## 6. Risks

- **BotService is edited by four workers at once** (vehicles, archetypes, looting, botopt) and is 3,400+
  lines near the 200-local ceiling. The merge order above is the mitigation; each rebase must run
  `tools/local_limit_check.py` and the three bot sims.
- **None of the bot work has run in a live server.** Everything is lupa-simulated. A bot error in
  `updateBot` stops that bot thinking for the match.
- **Part budget**: every kerbside car detailed, a battleground, ruined bases, more foliage. Nobody has
  measured the total on one map since; `perf_tick_probe` and a part count on Oliver's machine.
- **The four urgent fixes are unconfirmed** (viewmodel, animations, spill, death drops) and the branch
  is 60+ commits ahead of main.
- **Saved data**: rewards v2 and death effects add PlayerData defaults; both must stay additive
  (verify.py checks the default keys).

## 7. Recommended next steps

1. Oliver: playtest 58db872 (`python build_place.py .`) for the four urgent fixes, then the galleries in
   the handoff (vehicle_stability_probe, hitreg_rewind_probe, perf_tick_probe, team_base_ruins_gallery,
   crack_gallery, killanim_gallery).
2. Cherry-pick in the merge order of section 4; after each pick run `python3 tools/contracts_check.py .`,
   `tools/verify.py`, `tools/balance.py`, `tools/lua_static_check.py` (or the quality gate once in).
3. Apply fixes 1-4 as the bot branches land (1 and 2 are crashes / silent misbehaviour; 4 is one line in
   MatchService).
4. Tell the gun worker to rebase before batch 2 (fix 9).
5. When everything is in and Oliver's playtest passes: PR the branch to main, merge, publish with
   `tools/publish.ps1`.

## 8. Re-running this

- File overlap and conflicts: snapshot every worktree and `git merge-tree --write-tree` each against
  the branch tip and each other (the coordinator's scratch `sim.py`; the method is in this file).
- Contracts on the branch: `python3 tools/contracts_check.py .` (0 problems today; three known notes, two
  of which clear themselves when the vehicles worker lands) and `--selftest` (one planted fault per
  contract, each must be caught).
