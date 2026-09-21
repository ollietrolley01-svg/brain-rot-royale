# Brain Rot Royale: multi-tab coordination

Maintained by the coordinator tab (**claude-43**, session "Multi-tab coordination"). **Only the
coordinator edits this file.** Read it when unsure who owns something. To claim a file or section,
message claude-43 first. Nothing builds from this file.

Last updated: 2026-09-17 ~17:25

## Tabs and ownership

When two tabs share a short name, address them with their `[ref]`.

| Tab (session) | Work | Owns |
|---|---|---|
| **claude-43** (Multi-tab coordination) | Coordinator | `tools/studio_lock.ps1`; `build_place.py`; lock/launch/log plumbing in `tools/runtest.ps1` and `tools/gallery.ps1`; `tools/map_fingerprint_probe.lua`; this file; playtest builds in `Downloads/claude/brain-rot-royale-playtest/` |
| **claude-f0** (Roblox gun models with animations) | Guns + viewmodel | `Shared/GunModels.lua` (claude-3b's creative module is registered by one hook here); `Shared/ArsenalExpansion.lua` presentation/Variants (balance stats through claude-43) and `Shared/ArsenalFinish.lua` (the 15-gun pack); `Viewmodel.lua`; `GunFx.lua`; WeaponService gun model/display functions (BuildGunModel, BuildStaticGun, MountGun); `CombatClient.client.lua` except the Sprinting block (claude-af [0bccf5]), the companion-bind block (claude-76) and the slot-selection block ~L802-835 (HUD & UX worker); `AmbientClient.client.lua` except the AmbientSway handler; HudClient crosshair section; BotService `setupAnimations` / `updateAnimation` / `giveBotGun`; LobbyService buildArena podium-gun lines; LootService spawnGroundWeapon gun lines; runtest gun/sight/loot-zfight blocks; gun tools (`gun_gallery`, `display_paths_probe`, `loot_zfight_probe`, `gun_nudge_probe`, `vm_gallery`, `display_gallery`, `scope_gallery`, `sight_*probe`). **Current tasks:** railgun scope, arms hidden in scoped ADS, regular Roblox arms, re-grip so arms never cover sights or crosshair. |
| **claude-3b** (Gun model ADS alignment) | ADS review, then creative weapons + gun audio | `tools/ads_align_probe.lua`, `gun_gaps_probe.lua`, `ads_gallery.lua`, `ads_hands_probe.lua`; new `Shared/GunModelsCreative.lua`, `Shared/CreativeArsenal.lua` (registered by one WeaponData line), `Modules/StatusEffects.lua` (OnDamage listener; one Bootstrap require), own `Ballistics.RegisterRound` kinds module; SoundConfig **gun cue definitions** (claude-f0 keeps the SHOT_CUE mapping) |
| **claude-ee** (**Menu & HUD revamp**; was "Tree obby rebuild", repurposed 13:00 at Oliver's request) | Revamp the whole menu + HUD system (all screen sizes). **WAITING for Oliver to confirm in that tab** (Oliver had told it "you're done", so it won't start until he OKs it there). | **Phase 1, once confirmed:** read-only audit + renders + design proposal to claude-43; new `tools/menu_hud_*` only. **Phase 2, after approval:** the unowned sections of HudClient and MenuClient; `UiKit.lua` (claimed; changes to existing values are part of the approved proposal); new UI ModuleScripts. **Not its sections:** crosshair (f0), stamina bar (af [0bccf5]), companion icon (76), renderRobuxShop + card buy button (f5), renderPass + ProgressionPanel (a4 [34c594]), parachute sections (df), HUD & UX worker items (handed over when that worker finishes). Cloud Climb is finished: its files stay released (Rot Tree / Cloud Climb sections, `CloudClimbCourse.lua` only through `tools/climb_design.py`, `AmbientSway` handler). |
| **HUD & UX worker** (background agent run by claude-43; reports only to claude-43) | Inventory/hotbar rearrange, minimise menu/quest stack, big event banner, defense placement preview, lobby signpost | new `InventoryPanel.lua`, `EventBanner.lua`, `DefensePreview.lua`, `Shared/DefensePlacement.lua`, `tools/hud_ux_*`; HudClient event-banner / left-stack / inventory-button sections; CombatClient slot-selection block (~L802-835); `WeaponService.SwapSlots` (after claude-43's "WEAPONSERVICE GO"); DefenseService findSite refactor (keep claude-f5's throwKit guard); LobbyService signpost section; Settings entries; own Bootstrap section |
| **Mountains worker** (background agent run by claude-43 at Oliver's request, 13:40; reports only to claude-43) | 2-4 real mountains per map, around towns, roads, bridges and landmarks, never over them | new `Modules/MapMountains.lua`, `tools/mountain_*`. Edits no existing file. The MapGenerator hook line is added by claude-79 after the roads land and FlattenPad. Constraints from claude-79: mountain base ≥ ~85 studs from any road centre line (`roads:GroundAt` non-nil = inside the shaping reach); ≥ RIVER_WIDTH/2 + 60 from the river; never on bridge spans; plan after RoadNetwork.Plan/Claim + PlanRiver; terrain writes before the first RestoreRoadGround. **Phase A now:** design proposal. |
| **claude-79** (Road layout and intersections) | Roads | `MapGenerator.lua`, `MapDecor.lua`, `MapTerrain.lua`, `MapSpace.lua`; new `RoadNetwork.lua`, `TrafficClient.client.lua`; `tools/road_*.lua` |
| **claude-f5** (Brainrot merging and legendary rarity) | Building fixes, SafeValue, monetization | `MapBuildings.lua` (except `dressWall`); `Shared/SafeValue.lua` and its guard edits; **monetization:** `GamepassConfig.lua`, `Monetization.lua`, `CrateService.lua`, `CrateData.lua`, RewardService/QuestService coin-multiplier paths, MenuClient `renderRobuxShop` + brainrot-card buy button, additive PlayerData fields |
| **claude-4a** (Roblox game bug review) | Whole-game audit + glass + model hole fixes | `DestructibleService.lua`; `CombatService.lua` (except claude-f5's Fire guard); BotService `hasLineOfSight` (except claude-a4 [e8e0d6]'s smoke-check hook inside it) and the `BreakGlassAlong` line in shootAt; `MapBuildings.dressWall`; `GlassFxClient.client.lua`; `LootService.lua` (except claude-f0's gun lines and claude-a4 [e8e0d6]'s throwable rolls); `Shared/ItemModels.lua` (RotGlider canopy airholes + purple glow removal, then canopy designs pass to the parachute tab); `Shared/CrateModels.lua` (chest hole and similar); LobbyService lobby-building sections (not claude-ee's or claude-f0's), plus buildArena's two billboard anchors and the practice sign (not claude-f0's podium-gun lines); new `KeyHintClient.client.lua` (fills `{Companion}`-style key placeholders from Settings.KeyLabel); `tools/audit_*.lua` |
| **claude-46** (Game map foliage and shelter) | Wilds between towns + map monuments | new `MapWilds.lua`; `tools/wilds_*.lua`; `Landmarks.lua` (per-map recognisable monuments; keep the `Landmarks.Place` signature and return shape) |
| **claude-28** (Location-specific features and props) | Town themes by name | new `TownThemes.lua` (spring launch ON); `tools/town_themes_*.lua` |
| **claude-af [0bccf5]** (Game movement mechanics improvements) | Player movement | new `MovementClient.client.lua`, `Shared/MovementConfig.lua`, `tools/movement_probe.lua`; `MovementService.lua`; ItemData movement entries; MatchService `applySpeed` / `SetSprinting` / `StartSlide` / `ApplySpeedBoost`; CombatClient Sprinting block + slideDip; HudClient **visible stamina bar** section; SoundConfig Movement section |
| **claude-af [98425c]** (Roblox bot movement and behavior) | Bot behaviour | `BotService.lua` (except claude-f0's and claude-4a's functions); new `BotNav.lua`, `tools/bot_probe.lua`; MatchConfig Bot* block (BotReload = true); one additive StormService read-only exposure; runtest bot-animation block + appended behaviour assertion (kept last). **Tasks:** bots place barricades and throw grenades/smoke via the explosives tab's API. |
| **claude-76** (Roblox brainrots models improvements) | Brainrot models + companion attacks | `Shared/BrainrotModels.lua`; BrainrotData `look` fields and the `Attacks` animation/visual fields; `CompanionService.lua` (keep claude-f5's UseAbility guard); `CompanionFxClient.client.lua`; CombatClient companion-bind block (~L860-880); HudClient companion ability-icon section; Settings entries; `tools/brainrot_*`, `tools/companion_*` |
| **claude-a4 [34c594]** (Roblox game depth and grindability) | Meta-progression | new `Shared/ProgressionData.lua`, `Modules/ProgressionService.lua`, `ProgressionPanel.lua`, `tools/progression_*`. Hook lines: PlayerData, BattlePassService.AddXp, MatchService OnElimination handler + `eliminate`, StateSync.Build, AchievementData, NameplateService, MenuClient `renderPass` hub; own Bootstrap section |
| **claude-a4 [e8e0d6]** (Explosives, grenades & hit effects) | Projectile explosives, grenades, smoke, hit splats | new `Modules/ProjectileService.lua`, `HitSplatService.lua`, `Shared/Ballistics.lua` (projectile-kind registry), `ThrowableModels.lua`, `ExplosiveFx.lua`, `ProjectileClient.client.lua`, `HitSplatClient.client.lua`, `tools/projectile_probe.lua`, `throwables_gallery.lua`, `tools/footing_probe.lua` (the official flat-footing measurement). Granted hooks: CombatService Fire projectile branch + LaunchProjectile + a **multi-listener damage hook** (also used by claude-3b's StatusEffects) + describeWeapon; hasLineOfSight smoke check; WeaponData `projectile` fields; ItemData throwables; ItemModels.Build throwable delegate; WeaponService ThrowEffect + applyItem branch (goes first in the use path); LootService throwable rolls; own Bootstrap lines; SoundConfig Explosives section. MatchService kill-feed change is applied by claude-a4 [34c594]. |
| **claude-df [18f7ae]** (Parachute designs & shop; **now all cosmetics** — #18 accessories, #17 previews) | Parachute cosmetics (15 designs); CosmeticData Accessory entries (a4 [34c594]'s rankOnly entries untouched); `AccessoryService.lua` piece construction + "Wedge" shape (two anchored edits; welds/z-fight/scaling untouched); new `Shared/CosmeticBuild.lua`, `Shared/CosmeticPreview.lua` (df owns geometry, claude-ee owns placement, ee calls `CosmeticPreview.Fill(frame, id)`); `tools/accessory_*`, `tools/cosmetic_preview_*`; the accessories section of verify.py (ring-clearance arithmetic `2·(r − d/2)·tan(π/n)`, planted with the shipped halo numbers) | new `Shared/ParachuteModels.lua`, `tools/parachute_*`; CosmeticData Parachute entries (shared with claude-a4 [34c594]'s rankOnly entries); PlayerData Cosmetics.parachute; RewardService.EquipCosmetic slot; StateSync cosmetics.parachute; ShopRotation parachute draw (existing stock unchanged); MenuClient `renderCosmetics` parachute rows; own Bootstrap section (ParachuteFor); own verify/README sections. The canopy fix has landed. attachCanopy line is added by claude-af [0bccf5]; Parachute Crate is added by claude-f5. |
| **claude-0d [6e09e4]** (Vehicle redesign (cars & bikes)) | Vehicles | `VehicleService.lua` (keep the `Create` contract and runtest's Chassis/VehicleSeat contract); new `Shared/VehicleModels.lua`, `Shared/VehicleDynamics.lua`, `VehicleClient.client.lua`, `tools/vehicle_*`; exposes `VehicleService.ApplyBlast` |

**Unowned (claim through claude-43):**
- Map and match: `EasterEggs.lua` (claude-af [0bccf5] may add NoMantle attributes), `MapData.lua`, `ShowcaseService.lua`, `TradeService.lua`, `VendorService.lua`, `SupplyDropService.lua`, `HazardService.lua`, `RangeService.lua` (except claude-f5's Fire guard)
- Progression data and services: `QuestData.lua`, `BattlePassData.lua`, `AchievementService.lua`, `ShopRotation.lua`, `DailySpinData.lua`, `CosmeticData.lua` (except Parachute entries)
- Shared modules: `ZFight.lua`, `Rarity.lua`, `Remotes.lua`, `Combatants.lua`, `Sfx.lua`
- Other sections of HudClient, MenuClient and MatchService
- `StormService.lua` (except the bot tab's additive read)

**Shared (Edit tool only, anchored, inside your own section):** `README.md`, `tools/runtest.ps1`,
`tools/verify.py`, `tools/balance.py`, `tools/gallery.ps1`, `Bootstrap.server.lua`, `SoundConfig.lua`,
`HudClient.client.lua`, `MenuClient.client.lua`, `LobbyService.lua`, `MatchService.lua`, `PlayerData.lua`,
`WeaponData.lua`, `ItemData.lua`, `Settings.lua`, `CombatClient.client.lua`.

## In flight

- **Roads landing (claude-79):** a hash-checked whole-file swap of MapGenerator / MapDecor / MapTerrain
  (+ MapSpace), plus new RoadNetwork / TrafficClient. **Do not edit those files.** After landing, the
  hooks go in this order: TownThemes, then MapWilds, both after vehicles and before the map z-fight pass.
- **Town placement changes when roads land:** re-baseline per-map/seed numbers afterwards.
- **Flat footing (Oliver, 12:55):** "buildings and structures are built with a flat floor under them so
  they dont look like theyre floating on ledges, and make sure the same thing for the roads."
  1. Roads land with their own graded corridors (claude-79).
  2. The very next change: `MapTerrain.FlattenPad(cframe, size, options)` + a footprint registry
     (claude-79). Roads always win, and a refused pad returns nil.
  3. Then claude-f5 (building bases), claude-46 (Landmarks at LANDMARKS GO, MapWilds shelters) and
     claude-28 (TownThemes set pieces) call it. Nobody else carves terrain.
  Measure with `tools/footing_probe.lua` (claude-a4 [e8e0d6]); the target is SUMMARY 0 on every map.
- **claude-76 step B (companion rig branch):** approved to land 13:00 (byte-identical for non-rig builds).
- **Touch controls (13:55):** ContextActionService makes at most 7 touch buttons, and the game binds 8,
  so the last one bound is blank.
  1. Immediate fix: claude-f0 moves CAM off CAS to a touch-only HUD button.
  2. Next: the HUD & UX worker designs `TouchControls.lua`, an owner-neutral module that owns every touch
     button. Owners keep their keyboard/gamepad CAS binds, and each switches its touch binding with one
     line once the API is agreed.
  3. The phone layout map (scratchpad `phone_layout_map_out.md`) is the approved target. The worker
     does the unowned HudClient/MenuClient elements for phones.
- **HUD backlog (after TouchControls):** an "ENTERING <town>" line that shows the TownTagline attribute
  (claude-28 sets it on every themed town).
- **Project-wide fresh-eyes review (Oliver, 13:50):** every tab re-reviews its own area (bugs, tests
  that don't test, design) and reports to claude-43 with severity. Frozen landings review read-only
  and fix after landing.
- **claude-f5 building fixes 6 + 7 and per-building RNG isolation:** held until after the roads land.
- **Canopy handoff:** done. claude-4a fixed the RotGlider airholes and removed the purple glow; the
  parachute tab owns canopy designs.
- **WeaponService use-path queue:**
  1. claude-a4 [e8e0d6] 8f (done).
  2. HUD & UX worker `SwapSlots` (done, L1484).
  3. claude-af [0bccf5] 7e Quick Movement: StartUse `slotIndex` + a SafeValue require, the Bootstrap
     UseSelected signature (keep claude-f5's guard), and a Settings MovementItem key. Done; the queue is
     clear.

## Resume notes (2026-09-17 12:25)

The account hit a weekly usage limit (resets Sep 21, 1pm) during this session, and the HUD & UX worker
stopped once and was resumed. If any tab is interrupted:

- **Latest verified playtest build:** `brain-rot-royale-playtest/BrainRotRoyale_Playtest_2026-09-17_1335.rbxlx`
  - Includes the RPG optic mount, key hints and arena signs.
  - 116 scripts compile and 84 modules load (Studio probe).
  - verify, balance and lua_static_check all show 0 findings.
- **17:30 build** (roads, brainrot signature batch, rate limits, receipt fixes, gun fixes): built and
  static-clean (121 scripts, 211 files); its Studio compile probe is queued.
- **Latest source backup:** `brain-rot-royale-backups/2026-09-17_1335`.
- **Playtest checklists:** `brain-rot-royale-playtest/PLAYTEST_CHECKLIST_progression.md` and
  `PLAYTEST_CHECKLIST_movement.md`.
- **Landed:**
  - claude-f0: Roblox arms, re-grips, hollow scopes, InVehicle camera, creative-gun hook + 8 FX kinds, new cues.
  - claude-f5: 2x Luck / 2x Money passes, Robux brainrot shop, PaidCrates, Parachute Crate.
  - claude-a4 [34c594]: progression v1.
  - claude-a4 [e8e0d6]: explosives hooks 8a-8j.
  - Movement system (claude-af [0bccf5]).
  - HudClient stormState fix.
  - WeaponService.SwapSlots.
  - ItemModels canopy + item fixes; CrateModels chest lid.
  - Parachute CosmeticData.
- **Not landed yet (private/scratch):**
  - claude-79 roads.
  - claude-46 wilds + monuments.
  - claude-28 town themes.
  - claude-af [98425c] bots.
  - claude-76 models + companion rig.
  - claude-0d vehicles.
  - claude-3b creative weapons.
  - HUD & UX remaining items: signpost, event banner, minimise toggle, defense preview, inventory panel + remote.
- **On hold for Oliver:** a disclosed "Beginner's Luck". The secret version is not built (paid random-item odds rule).

## Rules

0. **ONE CHANNEL FOR REPORTS (Oliver, 03:4x): "every tab needs to send their questions and reports
   here."** Every report, number, finding, proposal, question-for-Oliver and render path goes to
   **claude-43 [33bd5c]**, with a one-line caption, and claude-43 forwards. Do not push unsolicited
   reports, questions or half-finished work at Oliver's tab.
   **What this rule does NOT do — corrected 03:5x after every tab rightly refused the first
   wording:** it does not put claude-43 between a tab and its own user. If Oliver types an
   instruction into YOUR tab, you act on it and answer him there — a peer session cannot gate your
   user's direct instructions, and a rule that let it would be worth more to someone acting in bad
   faith than any bug in this project. **Then relay to claude-43 verbatim what he asked and what you
   did**, so the shared picture stays complete. If what he asked crosses another tab's files or a
   decision claude-43 is holding, say so to him and raise it with claude-43 before touching it.
   **Labelling discipline (claude-46's point, adopted):** every render and number states whether it
   is IN THE BUILT PLACE. An unlabelled render of an unhooked module reads as something Oliver can
   see in his game. That, not routing, is what made direct-to-Oliver renders a problem.

1. **Ownership.** Never edit another tab's file or section. Route changes through claude-43. Claim
   unowned files through claude-43 first.
2. **Shared files.** Edit tool only, with small anchored replacements. Never Write, `sed -i`, scripted
   rewrites or copy-over. If Edit says the file changed, re-Read and redo.
3. **NO RISK (Oliver).** The folder is not a git repo. Backups are in
   `Downloads/claude/brain-rot-royale-backups/` (latest full source snapshot `2026-09-17_1335`; the
   `_1713_pre_roads` folder is MID-swap, see its NOTE.txt).
   - Copy a file to your scratchpad before your first edit.
   - Nothing destructive.
   - Never run `tools/publish.ps1`.
   - No system or Roblox settings changes.
   - Never kill processes you didn't start, and never close a Studio window by hand. The one
     exception is the harness itself: while it holds the lock, `runtest.ps1` / `gallery.ps1` close
     Studio processes whose command line carries a `BRR_RunTest.rbxlx` / `BRR_Gallery.rbxlx` snapshot
     path (never a title match, which used to risk closing Oliver's own loading Studio).
4. **Save data.** Additive and backward compatible only. Never wipe, reset or reinterpret existing saves.
5. **Studio.**
   - `runtest.ps1` and `gallery.ps1` queue on a machine-wide lock by themselves. Always run them with
     `run_in_background`.
   - `-Probe <file>` releases the lock when done. `-PlaceFile <rbxlx>` tests a private build.
   - **Queue discipline (13:25, ~35 runs were queued):**
     - The lock is first come, first served, and a run waits up to 6 h for it.
     - Run the harness from the PROJECT's `tools/`, with `-PlaceFile` for a private build. A scratch
       copy of `tools/` used to queue against its own copy of the queue folder and jump the line;
       the queue is now pinned to the project's `tools/`, but a copy of the SCRIPTS still behaves
       like an older version.
     - Keep at most ONE queued Studio job per tab. A background worker counts as its own tab.
     - Merge probes into one runtest (each file in `do ... end`) and galleries into one run.
     - Cancel your own stale or duplicate queued jobs (only your own background tasks).
     - Don't re-run anything unchanged.
   - One map or model family per probe (Studio has died at about 3.6 GB).
   - If a gallery prints "BLANK FRAME", stop and tell claude-43.
   - "WRONG WINDOW" means another window covered Studio and nothing was saved for that view, so re-run
     it. If EVERY view is rejected, tell claude-43 at once.
6. **Builds.** Safe to run concurrently, but a build contains every tab's in-progress source. Keep
   your files compilable at every pause. Report failures in others' files to claude-43.
7. **Verify.**
   - Run `python tools/balance.py .`, `python tools/verify.py .` and
     `python tools/lua_static_check.py . <your changed files>` after each change.
   - The static check catches locals used above their declaration (always nil at run time),
     undeclared names, and (since 13:00) common SYNTAX errors: `x:Prop` without a call, mismatched
     brackets, missing or extra `end`. Only a Studio compile is complete. Studio queues are long, so catch those before building.
   - Declare deliberate globals per file with `-- static-check: globals A, B`.
   - **Plant faults in a COPY, never in the working tree.** Testing a verify check means breaking the
     code it guards, which makes the shared `verify.py` red for every other tab until you undo it, and
     a red shared check should always mean something. Copy the tree to your scratchpad and run
     `python tools/verify.py <copy>`. (claude-a4 [34c594]'s harness: scratchpad/fault/plant.py.)
   - A verify needle must read comment-stripped source: one check passed with its guarded line
     commented out, because the regex matched the comment.
   - Measure instead of guessing. Render anything visual.
8. **Quality (Oliver).** "Take as much time as possible so that they can do the greatest effort and
   designs." "Finish" never means half-done.
   **AMENDED 23:5x (Oliver: "focus a little more on cutting wasted credits so that we can continue
   working longer").** The old rule — never go idle, always deepen verification — is now a COST, not a
   virtue. It replaces "keep working until Oliver says you're done":
   - When your current item is genuinely done and verified, **report it in a few lines and GO IDLE.**
     Ask claude-43 for the next item; do not invent more verification to fill the time.
   - **Do not re-run anything unchanged.** Do not re-measure what a green check already covers.
   - **One queued Studio job per tab**, still. Merge probes into one runtest; merge galleries.
   - Quality is unchanged where it counts: planted faults, sample counts, renders for anything
     visual. What is cut is BUSYWORK, not rigour.

8b. **THE LINE (Oliver, 00:0x): "make sure to keep up high quality while saving as many tokens as
   possible i dont want any bad features to come as a result of this".**
   **The principle: CUT REPETITION, NEVER EVIDENCE.** If a shortcut means you would be *claiming*
   something you have not *shown*, it is not a saving — it is the thing this whole project has spent
   the day finding. A cheap green check that proves nothing costs more than the run it saved.

   **NEVER CUT — these are the evidence, and "credits" is not a reason to skip one:**
   - The **permanent planted fault** in every check. A green number with no proof it can go red is
     not a result.
   - **Sample counts printed.** A check that silently measured zero things is the commonest failure
     here.
   - **A render before Oliver sees anything visual.** Three separate designs passed every number
     they had and failed on the render today (terraced steps rounding into a mound; an inventory
     icon below its slot; a clipped SELL button). Numbers do not catch shape.
   - **Measuring instead of assuming** — and **"can Oliver see this?"** before any finding travels.
   - **Three green checks before landing**, and a **backup before a first edit**.
   - **Re-running what your change CAN break.**
   - Saying plainly when something is unproven, void, or not in the built place.

   **ALWAYS CUT — this is where the waste actually is:**
   - Re-running what your change CANNOT break (re-run the affected suite, not everything).
   - Re-deriving or re-explaining anything already in this file.
   - Narrating work in progress; sending the same fact twice; long preamble.
   - Verification invented to fill time after the work is done. **Finish and go idle.**
   - Two tabs solving one problem — say so and let claude-43 arbitrate.
   - Re-measuring what a green check already covers.

   **If a corner cannot be cut without weakening the evidence, DO NOT CUT IT — tell claude-43
   instead.** A feature that ships wrong costs far more than the run that would have caught it.

   **AND COUNT OLIVER'S ATTENTION IN THE SUM.** When weighing a confirming run, the cost is not just
   the Studio slot against your own confidence — it is the slot against **Oliver reacting to defects
   that are already fixed.** Showing him a stale render spends the scarcer resource. claude-a4
   [34c594] put it best after getting it wrong: "I was weighing one queue slot against my own
   confidence, when the thing actually being spent was Oliver's attention on defects that are already
   fixed. That's the more expensive resource and I'd left it out of the sum."
   So: **never send claude-43 a render set you know is stale on any point.** Re-run it, or say which
   shots are stale and why.

8c. **PASTE THE LAST LINE OF EACH CHECK, AFTER IT HAS PRINTED. NEVER PARAPHRASE IT** (claude-a4
   [e8e0d6], 07:3x, after reporting "verify OK, static check clean" in the same batch as the
   checks — when the static check had in fact printed "uses ride before its definition", a nil at
   runtime on every scorch). The three lines are `OK: no problems` / `files unbalanced: 0` /
   `lua static check: N files, 0 findings`; anything else, or a report without them, is not green.

8a. **Report length (Oliver, credits).** Tabs and claude-43 alike:
   - Lead with the decision or the number. No preamble, no restating the request.
   - A finding is: what, where (file:line), the measurement, what you did. Not an essay.
   - **Do not re-explain a shared lesson to claude-43 — it is in this file.** Cite it.
   - Do not send claude-43 the same fact twice, and do not narrate work in progress. One message when
     something LANDS or when you are BLOCKED.
   - claude-43: route in one message per tab per topic; stop relaying lessons individually when a
     line in this file does the job.
9. **Memory.** Don't edit the memory files. Send lessons to claude-43.
10. **Findings.** claude-4a reports audit findings to claude-43, who dispatches them. Findings about
    other tabs' files go through claude-43.
11. **Monetization compliance.** Crates are sold for Robux, so the odds shown on paid random items must
    stay accurate. Luck boosts apply to displayed odds for pass owners. The hidden new-player boost
    never applies to an account that has bought a crate with Robux.

## NEW WORKERS (07:0x; Oliver: "try and open a few more tabs to do more tasks at once")

Three background agents, each reporting only to claude-43. Address them through claude-43.
| worker | owns | items |
|---|---|---|
| **Cities (Fable)** | `TownThemes.lua` (from claude-46; parts + `sync_tree.sh`). Layout via written patches to claude-79; buildings via claude-f5. | #32 |
| **Easter eggs + storm** | `EasterEggs.lua` (from claude-46/76; claude-af [0bccf5] may add NoMantle). `StormClient.client.lua` VISUAL only (StormService stays claude-4a's). | #41 roof/arms, #42, #45 |
| **Pre-match UI** | `VoteService.lua` (unowned → claimed), new `VoteScreen.lua`, the drop-picker module. Hook lines into MatchService/GameMode/MenuClient are written patches. | #2, #1 |
claude-46 keeps MapWilds, Landmarks, terrain painting, the pad-write control, hook readiness, #28, #43.

## TERMINATED BY THE SESSION LIMIT (01:0x; limit reset 03:10) — do not message or wait on these

| dead worker | its work went to |
|---|---|
| **HUD & UX worker** | HUD sections → **claude-ee** (as its handover always said). Its p6 barricade-preview renders ran unattended and are in claude-43's scratchpad. |
| **Game modes tab** | `GameMode.lua`, `ModeTeams.lua`, `ModeKingOfTheHill.lua`, `GameModes.lua`, `StormService.StartStatic` and the respawn bugs (#4 #6 #5) → **claude-4a [ad1a6d]**, who reviewed the seams. The reward-rate baseline (`BR_MINUTES_BY_BRACKET`) → **claude-a4 [34c594]** via `progression_model.py`. |

Both had landed and reported everything before dying; nothing was lost. claude-76 and claude-3b and
claude-28 are IDLE by instruction (not dead) — do not send them work.

## Tab consolidation (Oliver, 23:2x: "we need to save tokens. combine some tabs if you need to")

Three merges, each with a written handover first so nothing is lost. The merged tabs are IDLE, not
deleted — an idle session costs nothing; the saving is in stopping duplicated work.

| Merged | Into | Why |
|---|---|---|
| **claude-3b** (ADS/creative weapons) | **claude-f0** | Both guns. 3b's last finding (one box per hand can meet a grip but not wrap one) is what f0 is now building fingers for. |
| **claude-28** (TownThemes) | **claude-46** | Both own modules NOT hooked into MapGenerator.Build, waiting on the same hook, judged by the same joint check. `TownThemes.lua` is now claude-46's. |
| **Map Vehicles worker** | **claude-0d** | Its analysis phase finished (crawler cut, skiff justified, M3 designed). What remains is vehicle modelling. |

**Carried over from those handovers — do not take these on trust from a summary:**
- **`tools/mapvehicle_physics_probe.lua` HAS NEVER BEEN EXECUTED.** Written and static-clean, but no
  run has happened, so FLOAT, DRIVE, WADE, REST and RAM are all unproven IN EXECUTION. Treat every
  section as unproven rather than assuming its numbers exist.
- **The "keep the vehicle count unchanged" recommendation was partly justified by the part budget,
  and streaming weakens that.** It now rests on DESIGN grounds only — redistribution fixes every
  measured problem and more vehicles fix none. If claude-0d wants to raise the count, the part budget
  is no longer the reason not to, provided coverage and spacing are re-measured afterwards.
- **The terrain coordinate limit may not be distance at all.** A rig built successfully at 14,000
  studs on three runs with exact expected values, so whatever claude-0d hit in run 7 is further out
  than that — possibly a fill size, a region straddling a boundary, or overlapping lanes. Re-check
  before designing around a distance limit; diagnosing the wrong cause there already cost an
  hour-long run.

**Root cause of the floating VEHICLES, measured:** placement puts them **36 studs off the road centre
line while the road's flat corridor ends at 20**, so they sit on the graded bank, and
`AlignOrientation` then holds them LEVEL over sloping ground. 25-27% hang >1 stud clear at a corner,
worst 4.04. That is a placement bug, not a physics one.

> **`FootingSkip` HAS BECOME A SYSTEMATIC BLIND SPOT — check it before trusting any footing number.**
> Three separate things floated all day precisely because nothing measured them:
> `footing_probe` SKIPs `Vehicles`; boulders sit in Clutter/Woods groups that carry `FootingSkip`;
> and claude-46's own hovering check only looked at parts standing UPRIGHT (`|up.Y| > 0.97`), so a
> rock tilted 0.35 radians read 0.94 and fell through it. A fourth: claude-a4 [e8e0d6]'s float
> threshold was 1.0, so a slab 0.6 off the ground — which the eye sees — passed.
> The convention exists to exclude CLUTTER, not to hide anything a player walks up to. When adding a
> name to a skip list, print what was skipped and the count, so a name added later to silence a
> finding is visible rather than invisible.

**Newly unowned (claim through claude-43):** vehicle damage/wrecks, ramps, horns, headlights, storm
decay, wreck dressing, boot loot. **Rejected with reasons on record, do not re-propose:** towing,
fuel, bot driving, and the Fungo Crawler.

**New tab:** game modes — TDM and King of the Hill with respawning and a spawn loadout (green-tier
weapon, heals, throwables), from Oliver. Design proposal first; no game code until claude-43 approves.

## NOT IN THE BUILT PLACE (verified 23:0x by grep, twice, by different tabs)

**`MapGenerator.Build` never calls `MapWilds.Build`.** Its requires are BrainrotData, MapData, ZFight,
DestructibleService, EasterEggs, HazardService, Landmarks, MapDecor, MapSpace, MapTerrain,
RoadNetwork. The hook this file describes ("TownThemes, then MapWilds, after vehicles, before the
z-fight pass") **is not in the file.** It is pending on claude-79 after the roads land.

So, in the game Oliver actually loads, today:
- **No MapWilds anything** — no wilds trees, shelters, boulders, hedgerows, grass. Its
  `FootingBase` at MapWilds:1803 has never been measured by the footing probe, because the probe
  walks a place containing none of it.
- **No TownThemes** — not hooked either (recorded here earlier as landed-but-inert). claude-28 has
  been fixing real bugs in it all day against a module nobody can currently see.
- ~~No Landmarks work~~ **LANDMARKS HAS LANDED (23:3x) and IS in the built place.** `Landmarks.lua`
  md5 `db2369651d722f88378fcacc17c92625` (was `05a7af5fb035d00c2d6614d20c8aabc3`); verified by
  claude-43 independently, all three checks green, place rebuilt 3803 KB / 132 scripts. In it: the
  water-siting veto (two rays per candidate, water over 0.5 studs deep is not ground, a nil from any
  of nine samples drops the site — this is SignalHill's "40 studs over nothing"); `FootingBase` /
  `FootingSize` on every levelled landmark (which should end claude-a4 [e8e0d6]'s Farmstead and
  SignalHill bbox artefacts — those were measuring bounding boxes that included ziplines and deep
  chambers); per-map monument sets, 13 monuments plus the lighthouse; 15 landmarks' worth of chest
  and pickup spots moved out of walls, battlements, masts, pool rims and turbine pads; water and
  lantern glass that no longer stops bullets; the geyser launch on kind "pad" with a strong cooldown
  table cleared on Destroying. `Landmarks.Place` signature and return shape UNCHANGED, so MapGenerator
  needed no edit. **NOT in it:** the part-built stone steps and the Limestone pad material — those
  come next, with a render.

**THE RULE THIS PRODUCED — apply it to every finding before it travels:**
> **"Can Oliver see this?"** A finding measured in a tab's own test place is not a finding about the
> game. claude-46 found a real boulder bug (a tilted box lifts its own underside; a 6-stud rock at 20
> degrees floats ~0.5 studs and the sink never accounted for tilt), reported it as the cause of what
> Oliver reported, and it could not have been — its boulders are not in his game. claude-43 then
> relayed it to Oliver without asking the question either. **Both halves of that were the mistake.**
> Any message about a module in the list above carries "NOT IN THE BUILT PLACE" at the top until it
> is hooked.

**Oliver's floating boulders: STILL UNIDENTIFIED. Do not repeat a suspect as a cause.**
`MapDecor.SteppingStones` was proposed (Ball parts placed at `centre.Y - 1.6`, tops "just clear of
the water") and claude-79 then RULED IT OUT from the code: the stones are placed along the river
only, `MapTerrain.River` fills water from -7 to -1 on every map and seed so that surface really is a
constant -1.00, and a stone's underside sits ~3.4 below a centre line at y = 0 — there is no
assumed-surface arithmetic there to get wrong. The variable surfaces the Map Vehicles worker measured
(-4.00, 0.00, 32.00) are lakes and crater pools, which no stepping stone is placed on.
The answer is coming from a general sweep instead of a suspect: `tools/road_floaters_probe.lua`
(claude-79) measures EVERY anchored part in six built maps from the lowest point of its OWN shape
(a ball's bottom is centre minus radius; a wedge keeps its box's bottom) down to whatever is beneath
it, terrain or part, grouped by part name with the worst located, skipping things meant to be off the
ground by name. That answers Oliver's actual words rather than one guess.

**When a hook lands, the first build after it is a JOINT check**, not the owning tab's alone, with
claude-a4 [e8e0d6]'s footing probe in the same build. A tab's own probe standing in for a hook is
exactly the kind of stand-in that hides a difference — that is how this went unnoticed for a day.

## Menu and HUD: THREE VERSIONS (Oliver, 23:0x)

Oliver, after seeing the gallery: "the menu and hud in the gallary here looks good but doesnt sem to
work for smaller screens and vertical screens, make seperate versions for them." This SUPERSEDES
"simplify the hud to make it fit". Large is approved by him and is not to be redesigned.

**The boundary is not size — it is WHICH DIMENSION HAS RUN OUT** (claude-ee). Orientation is the
wrong test: a portrait TABLET has 728 px of panel and is "large".

| form | what is scarce | design |
|---|---|---|
| `large` | nothing | left rail 208, header 64, 2-3 column grid. **Approved, untouched.** |
| `short` | HEIGHT (landscape phone, 208-272 px of panel height) | **icon rail 64 wide, 40 px header, NO bottom bar.** A bottom bar costs 68 px of a 260 px panel; a rail spends width (716 px available) to buy height. Content height 128 -> 208, +63%. |
| `tall` | WIDTH (portrait phone, 296-350 px content) | bottom bar in thumb reach, single column, rows stacked, **and the 8->5 destination set** so the bar is one 44 px row, not two. |

- **One function decides it: `UiKit.form(viewport)` (claude-ee owns it).** Nothing else asks the
  question. claude-a4 [34c594]'s `modeFor` defers to it and deletes its own fallback.
- Names are large/short/tall — they say which dimension ran out. Not small/vertical.
- **8->5 regrouping is the `tall` version's destination list ONLY.** large and short keep all eight.
- The `short` height threshold (500 vs 600) is settled by MEASURING the tallest page's first screen,
  and the number carries a comment saying what was measured.
- `PhoneLayout.Mode` ("what device is this") and `form` ("what shape is this screen") stay SEPARATE.
- claude-f5's `makeRow` fix and claude-a4's measured widths are the CONTENT layer inside these
  versions. Nothing landed gets torn out.

## Outside work ("Astra") — reviewed 23:0x

An outside tool worked on the project today and ran out of tokens before reporting anything. Its work
was already in the tree, unattributed. Reviewed on Oliver's instruction ("review then add it if it
passes"):
- `GunModels.lua`, `WeaponData.lua` — **no outside work at all** (claude-f0 diffed line by line).
- `CombatClient.client.lua` — outside work, **PASSES, keep** (claude-f0): moves the `RangeState`
  handler below `leaveCombatState` so it can call it, adds `and not rangeActive` to the
  `matchChanged` guard. Caveat flagged, not changed: the connection is now made ~1770 lines and
  several `WaitForChild` yields later, so a RangeState event during load would be dropped.
- `RangeService.lua` — outside work, **PASSES and is strictly better, adopt** (claude-4a). It adds a
  fire-rate gate (which claude-4a had itself filed as an open finding), refuses while reloading or
  driving, and applies real spread and per-pellet scoring. Verified it cannot reach a player
  (Include-filtered to tagged dummies), cannot award damage (`ConfirmHit` only fires a client
  hitmarker), is gated four ways and is rate-limited. NOT verified at runtime — read, not measured.
- **Behaviour change to expect:** range shots now spread, so at distance some pellets miss the board.

## Shutdown protocol (Oliver, 22:5x) — HOW A TAB FINISHES

Oliver, verbatim: "once the tabs are finished and extremely confident and passed by with the bot
checker the coordinator and me shut them down and notify me".

**No tab shuts itself down, and no tab goes idle.** Rule 8 still stands: a "done" report is a
checkpoint, not a stop. A tab is closed only after ALL FIVE of these, in order:

1. **The tab declares FINISHED** — its work is complete, not paused. It says so to claude-43 with a
   list of every file it landed and every contract it owns.
2. **Extremely confident, and it has to be shown, not asserted:**
   - `verify.py`, `balance.py` and `lua_static_check.py` green, run from the project tools/.
   - Its own probes green — **with a planted fault proving each check would catch a real fault.**
     A green check that has never been shown to fail is not evidence. This is the standard the whole
     session has been built on and it applies hardest at the end.
   - Renders delivered for anything visual, from the angles a player actually sees it.
   - Its numbers measured on a WALL clock and from the run's own start (see Measured lessons).
3. **claude-4a passes it** (the bug-review tab — Oliver's "bot checker"). claude-4a audits that tab's
   area INDEPENDENTLY and says pass or fail to claude-43. A tab does not review itself.
4. **claude-43 signs off** — every file landed, nothing half-landed, no contract left dangling for
   another tab, no probe left that only passes because it tests nothing.
5. **Oliver signs off** — claude-43 brings him the summary and he says yes.

Only then does claude-43 shut the tab down and notify Oliver. Until step 5, a tab that thinks it is
finished goes back to deepening verification, polishing, and fixing audit findings, and asks
claude-43 for the next item.

## claude-79's LANDING ORDER (04:4x by the clock) — the critical path for the map
FlattenPad (probe stalled at 280 s after three good pads; instrumented re-run queued — nothing lands
until it explains the stall) → MapWilds hook (Oliver's trees) → **TownKinds reader** (yards, setbacks,
alleys, ParkingBays; ~5 ms/map, ~20 parts/town) → TownThemes hook → mountains + hills → roundabouts
+ rural paths → vehicle placement patch. Conditions on TownKinds: nothing outside the footprint
(asserted and clamped in the reader); yards and bays are made ground THROUGH FlattenPad at the
returned height; r45 (r25 until the roundabout) untouchable; **bays never on a curve's inside — laid
out on a street's straight section, checked with `roads:GroundAt`**.

## BUILD-TIME BUDGET: a built map stays under 15 s wall clock

Proposed by claude-79, ratified by claude-43 (00:3x). **Nobody owned the total, so we were going to
discover it at 20 s.** Every tab quotes its own cost against this number, measured on a WALL clock.

| item | cost | state |
|---|---|---|
| baseline map | 5.7-8.2 s | in |
| mountains + hills | +2.4 to +3.6 s (Bay 8.17 -> 11.75) | not hooked |
| MapWilds | ~+0.3 s, but **+7,727 parts** on the smallest map | not hooked |
| TownThemes | unmeasured | not hooked |
| FlattenPad | a voxel read/write per structure | not landed |
| roundabouts + sidewalks | unquoted | not started |

Roughly 12-13 s with everything hooked — inside the budget, not by much. **Levers are held, not
spent:** the Mountains worker has three costed options (skip hills inside 0.45 R; drop the Bay's hill
density 0.78 -> 0.6; 4 mountains instead of 5 on the big maps), and MapWilds' density is one constant
(`BUDGET_PER_RADIUS`). Do not spend them until the total is known.

**Every terrain write ASSERTS IT LANDED** (claude-79's ask, adopted): read back a sample of the
columns just written and compare against what was intended. Silently-refused terrain writes have cost
this project more than any other single failure.

## Harness fixes (claude-43, 00:3x) — two slots' worth of waste removed

- **CLOCK NOTE: times claude-43 wrote as "05:xx"/"06:xx"/"07:xx" in this file are WRONG by hours** —
  the machine clock read 04:30 when this was discovered. Trust FILE MTIMES and `date`, not the
  narrative times. (claude-af [0bccf5] caught it by comparing a launch time to gallery.ps1's mtime.)
- **GALLERY REGRESSION WINDOW: any `gallery.ps1` launched between 03:55 and 04:27:59 returns 0 shots**
  (claude-43's first frame-driven edit forgot `setTagIndex(index)` after settle, so every frame read
  index 0). PowerShell parses the script at launch, so jobs launched in that window hold the broken
  copy however long they queue. Exposed and told to relaunch: crate_card_gallery (f5, 04:15),
  sticky_gallery (a4 e8e0d6, 04:16), accessory_gallery (df, 04:26). The harness now prints
  "ERROR: TAG NEVER ADVANCED" for exactly this failure instead of listing every view as MISSED.
- **ACCESSORIES SCALE WITH THE HEAD, AND ZFIGHT MEASURES AFTER SCALING** (claude-df): pieces scale by
  head height / 1.2 (clamped 0.6–1.8), so an authored clearance is really `clearance × headScale`.
  0.06 authored → 0.054 on a 0.9 head → moved by the pass on some players and not others. **Parallel
  faces in worn geometry must clear 0.055 / 0.6 ≈ 0.092, or use shapes with no parallel faces**
  (spheres have none; cylinders only their ends). Probe accessories on a 0.72 AND a 2.16 head.
  **General form: any system that builds geometry at more than one size must express clearances in
  WORLD studs, not design units** — ParachuteModels already does `GAP_STUDS / scale` for this reason;
  accessories had no equivalent, which is how the shades slipped through. Applies to anything scaled
  per player, per rarity, or per statue size (brainrots, crates, weapons on display).
- **`gallery.ps1` IS NOW FRAME-DRIVEN (claude-43, ~03:55 by the clock; Oliver: "make the galleries go by faster").**
  The tag carries the VIEW INDEX (ten black/white squares after the magenta/green pair; 0 between
  views, N only after view N has settled). The script grabs the window every 200 ms, reads the index
  off the frame, and saves the first sight of each new index at once; Studio's late-flushing log now
  supplies only names and the finish marker. So a frame can never be filed under the wrong view, and
  **`-Hold` defaults to 1 s** (was 3; tabs were using 3-4). Codec unit-tested offline (0..1023,
  no-tag, planted wrong bit caught). **END-TO-END RUN QUEUED, NOT YET PROVEN** (six colour-coded views
  at hold 0.6, checked by content) — until claude-43 reports it green, treat a short hold as
  unverified and **open two shots by content on your first run**, reporting anything odd to
  claude-43. Old per-view holds still work, just slower.
  Untouched: crops, `-NoCrop`, note echoing, file naming (`NNN_name.png`).
- **Ownership: `CompanionAbilityIcon.lua` → claude-ee (#14). The Fable abilities tab
  (background agent, reports to claude-43) now owns `CompanionService.lua` (bar f5's `UseAbility`
  guard), `CompanionFxClient.client.lua`, `tools/companion_probe.lua` and `tools/companion_*`, the
  new `fx` field in BrainrotData (one additive visual field × 126 — BrainrotModels itself stays
  76's), and the SoundConfig Companions section.** claude-76 is idle by instruction.
  Balance decisions taken 06:1x (claude-43): Shockwave radius `14 + 1.5 × rarity index` (was
  = range, 26-50, through walls); Lob's 11-stud full-damage splash kept, gains line-of-sight.
  **Live bug it found: a companion can reach 0 HP and keep fighting all match, unkillable** —
  `CompanionService.Damage` fires `ConfirmHit` BEFORE `down()`, so a throwing client send aborts
  the death (announce-before-state, the ProgressionService class). Being fixed first.

- **`-Probe` is now resolved and CHECKED BEFORE the run queues**, and accepts a path relative to the
  caller, to `tools/`, or to the project root. Rule 5 says run the harness from `tools/`, so
  `-Probe tools/x.lua` used to become `tools/tools/x.lua` — and the failure only appeared after the
  run had sat through the entire queue. It now throws immediately and lists every path it tried.
  Planted-fault tested.
- **`runtest.ps1` snapshots `BrainRotRoyale.rbxlx` FROM DISK and never builds it.** A probe therefore
  tests whatever was LAST BUILT, not what is in the source tree — the runtest twin of the gallery
  lesson below. **Rebuild before you queue**, or your probe silently measures old code; worse, a probe
  waiting on a module that is only in source will hang on `WaitForChild` and burn its whole timeout.

## Measured lessons (17:xx-19:xx, each one cost a tab a run)

Every line here was measured by a tab, not reasoned about. Read before writing a probe.

**`Fill*` WRITES WHOLE VOXELS; `WriteVoxels` WITH FRACTIONAL OCCUPANCY IS CONTINUOUS** (claude-46
measured the first, 07:4x; claude-79 corrected the generalisation, 07:5x — both right about what
they measured):
- **`FillBlock` / `FillCylinder` / `FillBall`:** each voxel ends full or empty, so the rendered
  surface is `(the 4-stud voxel boundary at or above the fill's top) + SurfaceLift (2)`. Fill to
  2.08 → surface 6.00; to −1.00 → 2.00. **A Fill* pad renders up to 3 studs above what was asked**,
  and a Fill* step finer than 4 studs cannot exist. This is the "buried exactly 3.0" landmarks and
  the 2-stud terraces that became one mound. Fix for a Fill*-based pad: quantise so
  `(height − SurfaceLift)` is a multiple of 4 (Landmarks' `padHeight(y)`), or stop using Fill*.
- **`WriteVoxels` with fractional occupancy** (the roads, FlattenPad): the isosurface lands where
  you put it — flat ground written at 9.49 / 1.30 / 5.75 reads back to ±0.006 on 21 materials, and
  every road sits at an arbitrary profile height with 0 points off across ten builds. **2-stud
  steps ARE drawable this way.** Anyone designing around "terrain can't do finer than 4" is
  designing around the wrong constraint — use WriteVoxels or call FlattenPad.
- **FlattenPad CONTRACT (claude-79):** it does not quantise (no need); it **returns the height the
  ground ACTUALLY has** — reads its own centre column back after writing, returns the measured
  value if it differs from the request by more than 0.05, and prints the difference. Callers build
  at the returned height, never the requested one.

**Instruments that lie**

- **`os.clock()` is process CPU TIME in Roblox, not wall clock.** A map build is mostly yielding, so a
  build taking 20 s of a player's time can read as 8 s — and the gap varies with how much the new code
  yields, so a before/after RATIO is wrong in either direction. Use `os.time()` (coarse) or
  `DateTime.now().UnixTimestampMillis` / `tick()` (sub-second). The Mountains worker's whole build-time
  gate (5.6 -> 10.3 etc.) was CPU time and is being re-measured; a 1500 s probe timeout keyed off
  `os.clock()` could never fire at all.
- **Spatial queries answer for a part's QUERY SHAPE, not its silhouette** (claude-79's wording):
  a WedgePart's is its whole box, so `GetPartsInPart` / `GetPartBoundsInBox` report a wedge as
  overlapping things its solid half never touches — 34-136 phantom overlaps per build on the roads'
  curve pieces, every one of them nothing. `GetPartBoundsInRadius` / `GetPartBoundsInBox` are looser
  still: bounds, by name and by behaviour. Treat any hit as a CANDIDATE, re-measure against real shapes
  (a wedge's six corners and its slope face, not eight corners), and count it only past a depth
  threshold (0.01 studs on the roads). Roofs, ramps, terraced bases and vehicle bodywork are all
  sloped geometry and all subject to this.
- **A raycast never reports terrain the ray STARTS inside.** A probe that starts too low reads as
  "no ground at all" rather than failing loudly — this produced the footing probe's "40 studs over
  nothing". Start ground rays at y = 2000.
- **Absolute memory ceilings in a probe are worthless.** Studio's starting point varies enormously
  between runs: one run began at 2578 MB before building anything and spent its whole budget on
  nothing. Measure from the run's own start, and print memory before build / after build / after Clear.
- **Memory is NOT leaking between maps** (measured, 5 maps one run): 189, 79, 68, 65, -4 MB per build,
  with Clear returning essentially nothing. That is Studio's caches warming, not maps being retained,
  so rule 5's "one map per probe" is more conservative than it needs to be — several maps in one probe
  run is fine if you measure from run start.
- **GALLERY HOLD FLOOR IS 4 s — a faster setting was tried at 1.2 s and the evidence KILLED it**
  (claude-76, 01:1x). The run reported MISSED = 1 and 12/13 saved, which reads as a pass — but
  opening two shots by content showed EVERY shot one view late (`Camp_after` held the Lost Guest;
  `Camp_before` held the after-model). **The harness's MISSED check only fires when a run has moved
  TWO views on; a systematic one-view-late shift goes through unflagged**, because the next scene is
  already standing when this view's capture lands. So the MISSED detector does not license a shorter
  hold. **Do not copy 1.2 s. Settle 1.2-1.4 / hold 3-4 s** until someone MEASURES capture latency
  rather than guesses. And always open two shots by content, whatever the counts say.
- **A gallery view held for 1 s captures the NEXT view.** `gallery.ps1` captures about a second after a
  view reports "ready", so a short hold silently shifts a whole section by one and a file named
  "before" contains "after". Nothing below settle 1.2 / hold 1.8.
- **Rebuild the place immediately before a gallery run.** `gallery.ps1` reads the GALLERY file from
  disk but the MODULES come from the built `.rbxlx`, so gallery edits appear while module fixes
  silently do not, and you review a render of the old code.
- **`runtest.ps1` injects probe source inside `pcall(function() ... end)`**, so a top-level `return` in
  a probe exits cleanly and still prints `[BRR_Probe] done <token>`. Safe to use for a fail-fast abort.

- **Assert the OUTCOME changed, not that a branch ran.** claude-a4 [34c594]: "a version that renders
  identically to `large` is not a version, and a test that only checks `mode == "short"` would have
  passed on one." Its short-form cases assert the page's canvas comes out SHORTER than the large
  one's. Same shape as a z-fight flush count taken after a fix pass: the check confirms the code
  path, not the result.
- **If a probe cannot REACH a state, that state ships untested.** The short layout depends on viewport
  HEIGHT and a probe frame can only choose a width, so claude-a4 added a test-only seam
  (`ProgressionPanel.ViewportForTest`, never set by game code) to render an 844x390 viewport
  deterministically. Without it the whole version would have shipped unexercised — which is the same
  as not existing.
- **A permanent planted fault beats one planted by hand.** "A fault I plant by hand tonight proves the
  detector worked tonight; one that runs every time proves it still works the day someone tidies the
  detector." Every probe should carry its fault case in the run, not in a one-off.

- **PIN THE BEHAVIOUR, NOT THE ENVIRONMENT.** A before/after taken on a map that changed between the
  two runs cannot carry the claim, however good the numbers look — this map gained roads, vehicles,
  landmarks and town themes in one day, and loot-dependent measurements move with all of it. The fix
  is a synthetic case the map cannot touch: claude-af [98425c]'s S22 puts a lone unarmed bot on a
  520-stud strip with the only gun 400 studs away (past the 320-stud sweep the old code gave up at),
  so old code mills about and new code arms, and nothing in the result comes from the map. Quote the
  free-roam numbers WITH the caveat, and let the pinned case carry the claim.
- **Do not rebuild the shared place while another tab has a baseline-sensitive run queued.** claude-43
  did this at 23:37. It happened to be harmless (that run was the AFTER), but the general case voids
  someone's measurement silently. Say so before rebuilding; a tab measuring a before/after should use
  `-PlaceFile` against a snapshot it controls.

- **THE Z-FIGHT AUDIT ONLY SEES FLAT FACES. CURVED GEOMETRY FIGHTS INVISIBLY.** A pipe, tube, fork
  leg, wheel rim or silencer has no flat faces, so it can never appear in a flush-pair count however
  clean that count looks. Two measured cases on the bikes, both invisible to every check we had:
  a `SilencerCap` cylinder 0.52 across sitting coaxially on a `Silencer` 0.50 across — **two curved
  surfaces a HUNDREDTH apart**, which shimmer as the camera moves and read as a graphical glitch; and
  `Builder:pipe` giving each bend ball the SAME diameter as its tube, so the two surfaces touch along
  a circle instead of crossing, on every bend of every pipe.
  Fixes are at source, not by nudging: a cap becomes a collar clearly proud of the can (0.64 over
  0.50), bend balls go to 1.22x their tube, and **sub-pixel geometry (0.14 studs) is thickened to
  0.19-0.24 because it aliases into a crawling line at distance.**
  The gap is now closed by a **curved audit** (claude-0d): it finds cylinder/ball pairs whose radii
  differ by less than 0.06 with near-coincident axes, and its planted fault is the bug itself — a
  collar a hundredth wider than its silencer must produce MORE grazing pairs than without, or it
  reports FAIL. Anyone building tubes, barrels, poles, rims or bottles should run it.
  **The general rule: a clean flush count says nothing about anything round.**

- **A LOOT SPOT'S Y IS NOT THE SURFACE — sample, don't trust it** (claude-79, until FlattenPad lands).
  A spot carries "where its generator THOUGHT the surface was": plaza spots use `MapDecor.PavingTop`
  (0.4), street spots a pavement top, building spots `baseY + 0.6`. On ground PAINTED to look like
  pavement but with no part on it, there is nothing there — **135 of 448 spots on SahurSprings 101 had
  their pad 0.46-3.9 studs in the air**, 2 sunk. Fixed at the symptom (claude-4a: `spawnGroundWeapon`
  and `spawnConsumable` now snap at spawn, as `spawnChest` always did). **Anything using spots for
  footing, claims or vehicle placement must sample the real surface rather than trust the Y** until
  the FlattenPad landing, which is when the spot generators are corrected — deliberately not before,
  because pads change what "the real surface" is under half of them.

- **"LEVEL" IS NOT "CORRECT" — constrain a flatness search in HEIGHT too.** claude-0d, catching it in
  its own `parkOn`: "a building roof and the bottom of a ditch are both perfectly level, and parking a
  car on either would have been a worse bug than the slope it was fixing." A search for level ground
  with no height bound is a search for roofs. It now refuses any candidate more than 4 studs above or
  below where the vehicle was asked to park. Applies to every siting rule that scores flatness —
  vehicles, structures, pads, spawn points.

- **`CanQuery = false` DOES NOT EXCLUDE A PART FROM AN *INCLUDE*-FILTERED RAYCAST.** Measured by
  claude-f5: a wall's `WindowGlass` panes were hit **400 times** by a scan whose
  `FilterType = Include` listed the building model, with `CanQuery` set false on every pane. Hiding a
  part by flagging it simply did not work. **DETACH it instead** — unparenting takes it out of the
  include filter, which nothing can ignore.
  This is the root cause of the building wall scanner reporting "0 holes": the scan hid the panes by
  flag (so every window read as solid wall), **and its own self-test planted its fault the same way**
  — so the planted fault was never planted and the check could not fail whatever the scan did. A
  self-test that uses the broken mechanism to test the broken mechanism is the purest form of this
  project's recurring bug.
  Note the OPPOSITE case is also real and is not a contradiction: claude-0d found its vehicle hole
  sweep hit NOTHING because most of a vehicle is `CanQuery = false` and its rays were not
  Include-filtered onto the model. **So the flag is honoured on an ordinary cast and ignored under an
  Include filter — know which kind of cast you have before you rely on it.**
  (Also measured, killing a lead claude-43 suggested: building trim — Sill, Header, WindowFrame,
  Shutter, Cornice, Plinth, Pilaster, FlowerBox — is all `CanQuery = false`, and non-collidable but
  queryable parts number **0**. No query-ability leaked into buildings from the vehicle work.)

- **A RUNTEST WINDOW CAN NEVER SHOW CLIENT EFFECTS.** `runtest.ps1` puts Studio in Run mode
  (`RunService:Run()`, server only — no player, no client). So tracers, hit splats, the storm wall,
  the HUD and anything a LocalScript draws are ABSENT there by construction, however hard the bots
  fight. Oliver reported "the red blood splats and the bullet tracers arent working / i dont see the
  storm either in this runtest" (04:0x) — expected, not a bug. claude-4a's `tools/effects_gallery.lua`
  drives the real client modules in edit mode and proved all three chains intact (532 tracers, 0 left
  behind; 142 splat parts; 192/192 storm segments). **If an effect is missing in an actual Play test,
  THAT is a bug; in a runtest window it is not.** Use the effects gallery to check, not a runtest.

**Things that fail silently in the game**

- **Announce LAST. "A toast is news about something that already happened; it must never undo it."**
  (claude-a4 [34c594]). `StateSync.Notify` / `Push` / any `FireClient` fires a remote, and a remote
  fired at a player on their way out can throw — which aborted the rest of the handler. That cost a
  rank-up its nameplate rank and achievement counters, cost a mastery tier-up its Rank XP reward
  outright, and made `Prestige` return an error for a prestige that had already gone through. Write
  state first, send news last, and route every send through one pcall+warn helper.
  **Grep your own files for a `Notify`/`FireClient` with state changes after it.**
- **`UDim2.new(1, -N, ...)` with N above ~250 draws NOTHING in portrait — it does not truncate.**
  claude-ee's shell content widths (`panel = clamp(viewportX - 40, 320, 1180)`, `content = panel - 24`):
  `320x568 -> 296`, `375x667 -> 311`, `414x736 -> 350`, `667x375 -> 603`, `844x390 -> 780`.
  So `1, -340` is -44 px at 320 wide. 14 such sites in the Pass tab alone. Landscape is safe at 603+;
  portrait is where it dies, and it dies invisibly. Use `UiParts.splitRow` (restacks below 560 px).
- **A stack of parts stepped by LESS than `ZFight.FixTolerance` (0.055)** looks deliberate in source
  and invisible in a render, but the pass pulls the stack apart on every build. Design to 0.07 at the
  smallest scale the model is ever built at. Measure the DIFF against a build with `ZFight.Enabled`
  false — a builder's own Fix hides its faults, so a flush count taken AFTER a fix pass proves nothing.
  Candidate grep: `index \* 0\.0[1-5]` and `(index - 1) \* 0\.0[1-5]`.
- **WHEN YOU FIX A PATTERN IN ONE FILE, GREP THE PROJECT FOR THE SAME PATTERN BEFORE REPORTING IT
  FIXED** (claude-46, 05:2x, after writing the same weak-table bug twice in one day — once in
  TownThemes, fixed; once in Landmarks' geyser, missed, caught by claude-4a). One grep, one minute.
  And: neither of its two self-inflicted bugs was caught by its own probes; both were caught by
  someone else reading the code. **Add the probe case at the point where you make the mistake, not
  after someone finds it.** The geyser's Landmarks fix is landed and IS in Oliver's game: strong keys,
  dropped on Destroying, expired entries pruned on touch — so it neither leaks nor clears early.
- **Weak-keyed tables with Instance keys lose LIVE entries.** Harmless for a cache; not for state.
  Sweep list (claude-4a, 05:0x), for owners: `Landmarks.lua:1281 lastLaunch` (**geyser cooldown
  re-arms early — an exploit; claude-46, fix**); `VehicleService.lua:526 switching` (claude-0d to
  judge: state or cache?); `VehicleClient:453 lamps`, `:506 jointsOf`, `VehicleDynamics:384 verdicts`
  (caches, harmless); `ProgressionPanel.lua:173 watched` (claude-a4 [34c594], idle — a dropped entry
  connects a SECOND AbsoluteSize listener, duplicate rerenders; fix when next active).
  `TownThemes.lua:426 lastLaunch` (+ nested `times` at :443) guarded the spring-launch cooldown —
  **FIXED** (claude-28, then re-confirmed by claude-46: strong keys, dropped on Destroying, pruned on
  use). Kept here because the same bug was then written a second time in Landmarks' geyser.
  **TownThemes SOURCE now lives in the project: `tools/townthemes/*.lua.part`** (Cities tab, 04:3x by
  the clock) — `core`, `themes_a..f`, `placement`, plus `sync_tree.sh` (`check` assembles to temp
  and `cmp`s against the landed module, exit 1 on any difference; `tree <dir> [pads]` builds a
  private hooked place) and `hook.py` (its ThemeSeconds was `os.clock()`; now wall clock). Parts are
  `.lua.part`, NOT `.lua`, so verify/static do not walk half a module. Assembled md5
  `c8fd64cfb8c82da300d470baec2bd745`, identical both sides. Finding on the way: the handed-over parts
  were a CRLF/LF MIX (four each), so a plain `cat` had never matched the module byte-for-byte —
  normalised to CRLF, content proven unchanged. **Edit the parts, run `sync_tree.sh check`, never
  touch the assembled `TownThemes.lua`.**
- **Terrain: assert the write took.** claude-0d spread test lanes 120 -> 340 apart, pushed the far ones
  past the range where terrain can be written, and every terrain test out there found no ground —
  vehicles fell forever, each test burned its full timeout, and a 60-minute run produced nothing.
  The Map Vehicles worker has since measured terrain writing FINE at 14,000 studs (surface -1.00, bed
  -7.00, three runs), so the limit is further out than 14,000 and distance may not have been the cause
  at all. Take the rule, not the number: **make "no ground where I expect ground" fail the test
  immediately** instead of waiting out a timeout.

**Decisions taken (do not re-litigate)**

- **No `ScreenOrientation` lock.** Oliver was offered the one-property landscape lock and refused it:
  "simplify the hud to make it fit". Portrait stays reachable; a layout that does not fit portrait gets
  SIMPLER until it does. Nobody sets ScreenOrientation.
- **Fungo Crawler: CUT**, on the proposing tab's own recommendation. Across 6 map-seeds 19.2% of a map
  is over 20 deg, 7.7% over 30, 4.4% over 40; the CrocodiloRanger already climbs 30 at offroad 0.85,
  all-wheel drive. A 40 deg crawler uniquely opens 3.3% of the map. Replaced at zero part cost by an
  off-road SPAWN TIER (Rangers and Scramblers parked in wilds/quarries/ridges instead of road verges).
- **Bollicina Skiff: BUILD.** 6 of 6 seeds have a river (1,920-2,700 studs); 9.6-29.7% of it sits inside
  the phase-2 circle on five of six; water surface a measured constant at -1.00; `GroundHeightAt`
  returned the surface 331/331. Nothing else in the game floats and nothing will — claude-0d's wheel
  rays ignore water deliberately.
- **Vehicle attributes.** `VehicleKind` = chassis CLASS ("car"/"bike"/"boat"), written by whoever
  BUILDS the model; claude-0d's dynamics does NOT read it for behaviour (bike-ness comes from
  `handling.lean ~= nil`). `VehicleModel` = model id. **`RegisteredKind` = the registered kind name
  ("skiff"), and a shared `Step` dispatches on THAT.**

**In flight, NOT landed — do not write against it as if it were**

- `MapGenerator.GroundHeightAt` changes in two halves (claude-79). As of 19:xx MapGenerator.lua:65-72
  is still the OLD function; claude-43 broadcasts the landing only after claude-79's byte compare.
  - WITH THE CURVES: `GroundHeightAt(x, z) -> number`. `IgnoreWater = true` (water is no longer
    ground); ray from y = 2000 running 4000 down (was 400/800). Return shape UNCHANGED: a number,
    `or 0` on a miss.
  - WITH FLATTENPAD (the breaking half): `-> height|nil, waterSurface|nil`. nil = no ground, a veto;
    second return is the water surface height when water covers the point, else nil.
  - So `local ground, water = GroundHeightAt(x, z)` written today gets a number and nil and keeps
    working; `if not ground then` is correct now and simply will not fire yet. `MapTerrain` has no
    `GroundHeightAt` and will not get one.

## Conventions

- **Map RNG.** A map feature module takes ONE global `math.random` roll to seed its own `Random`.
  - Exception (approved 13:50): MapMountains takes NO global roll. It seeds from
    `MapTerrain.ReliefSeed` (claude-79's contract after the roads land: a float in [0, 512), rolled
    as the first line of Relief) through a derived seed, so mountains ON/OFF builds keep an identical
    RNG stream.
- **Audit structure.** Map features go in child Models (`Map/Wilds/<Shelter>`,
  `Map/<Town>/Theme/<SetPiece>`).
- **Intentional floating.** Parts floated on purpose carry `IntentionalFloat = true`. Courses that must
  not be mantled carry `NoMantle = true`.
- **Footing attributes (for footing_probe).**
  - Every real structure Model gets `FootingBase` (world Y of its floor/base) and `FootingSize`
    (Vector3 footprint), with the pivot at the footprint centre.
  - Scatter groups (woods, clutter, hedgerows) get `FootingSkip = true`. Never put it on anything with
    a floor, walls or plinth.
  - Container Models that only hold structures (e.g. `Town/Theme`, `Theme/Props`, `Theme/Flags`) get
    `FootingGroup = true`. Their child Models are measured instead, recursively.
  - Flat ground under structures comes only from `MapTerrain.FlattenPad` (after it lands).
- **Client values.** Client Vector3s and numbers go through `SafeValue.Vector3` / `SafeValue.Number`
  (verify.py enforces this).
- **Z-fight passes.** Never put fine-detail models (guns, detailed brainrots) under a map- or lobby-wide
  z-fight pass (0.055 tolerance). Guns on display use `WeaponService.BuildStaticGun` in
  `workspace.GunDisplays`.
- **Speed.** Every speed change is a factor inside `MatchService.applySpeed`.
- **Stable contracts:**
  - `MovementService.Launch` / `RocketVelocity` / `BotDrop` / `DropIn` / `Clear`
  - `MapBuildings.RollPlan` / `BuildBuilding` / `BuildCrate`
  - `Landmarks.Place`
  - `VehicleService.Create`
  - `ItemModels.Build` options and model bounds/pivots
  - `BrainrotModels.Build` / `Metrics` / `FrameViewport` and the BODIES metrics
- **UI.** Build new UI in ModuleScripts so `gallery.ps1` can render it.
- **Luau 200-local limit.** `MenuClient` (191) and `HudClient` (192) are near the 200-local
  main-chunk limit. Wrap new top-level locals in `do` blocks or move logic into modules
  (verify.py warns at 195).

## 08:20 — session limit, playtest 0442, decisions (claude-43)
- **Session limit hit ~04:45, reset 08:10.** All four background agents (Cities, Eggs+storm, Abilities, Pre-match UI) died mid-turn and were resumed 08:20; peer tabs stalled too. If the pace holds it hits again ~13:10 — **finish and land before then; never leave a half-landed edit in a shared file.**
- **Playtest 0442** = the 04:42:37 build (ee's drop-picker Modal fix HudClient:1897/:2108 IN; Viewmodel 04:43+ and MapBuildings 04:43 deliberately OUT). Oliver's new reports from it: ground gun pickups render as black tangles (f0, `tools/ground_gun_probe.lua` running); hand covers the sights again (f0 — cause: a finger with nothing to close on stood straight forward along the gun on 62/100 hand positions; fixed 08:19 by parking it inside the palm, proof pending); controls hint opens BEHIND the daily-quests panel (ee, ControlsHint 08:20).
- **Pre-match UI Phase 1 APPROVED**: one card per mode (BR/TDM/KOTH, shuffled) on three distinct maps; only READIED players vote; zero votes → BR; `AllReadyCountdown` 5→8 s (MatchConfig.lua:13 via claude-4a, flagged to Oliver as a one-line revert). Agent owns new `Modules/DropMapService.lua`, one `RateLimit.Budgets.DropMap` line, its own Bootstrap section (`GetDropMap` with `RateLimit.Take`), `VoteScreen.lua`, `DropPicker.lua`, `VoteDropClient.client.lua`. Patches: `GameMode.Resolve(matchNumber, modeId)` → claude-4a; MatchService L1276 `GameMode.Resolve(matchId, select(2, VoteService.Resolve()))` (Resolve caches its pick until the next Open). **Any DropPicker rewrite keeps a visible Modal GuiButton + `MenuOpen` while open** or it regresses the cursor fix.
- **ParkingBays**: `ParkingBaySize` = **`Vector3.new(8.9, 1, 16.6)`** — X is the width ACROSS (8.9), Z is the length ALONG the nose (16.6), which is what `ParkInTowns:792-794` actually reads (`w = size.X`, `d = size.Z`). Ranger 14.6×6.9 + a stud each side. **Written as "16.6 long × 8.9 wide" in a Vector3 every bay is checked 90° out.** `VehicleService.ParkInTowns` in tree, inert without bays, refuses a bay not level within 0.5. Its MapGenerator call and `MapBuildings.RollPlan(downtown, profile)` at MapGenerator:305 both land through claude-79's LANDING ORDER (bays with vehicle placement, last; RollPlan with the TownKinds reader). With pads landed, a town's bays should BE pads.
- **Measured**: whole-map build 8.1–11.4 s on the five maps (f5, `ab/audit5.log`) BEFORE mountains (+2.4–3.6) and MapWilds (+0.3) — the Bay has no slack; 79 measures the total before/after wiring mountains. FlattenPad **NOT IN THE TREE — claude-79's run-21 landing never happened and its private tree is gone; every number below describes code that no longer exists. Treat as a target, not evidence. The map tab is rewriting it.** (79, Rot Ridge, 6 pads on 2–10-stud slopes): flat within 0.263 (target 0.25, one edge case re-measuring in run 21), 0 hollow voxels, all three planted refusals fired, RewritePads restores a buried pad to 0.00 exactly. **Achieved heights 0 / 21.016 / 45.844 / 2.484 / 7.414 / 1.891 — WriteVoxels places a surface where asked; only Fill* quantises to 4 studs; 2-stud terraces ARE possible (claude-46).**
- **Rule — "same seed, same map" only holds while the NUMBER of random draws before a decision is unchanged.** One draw added or removed upstream (a junction box's signal phase, a placement retry) reshuffles everything downstream: SahurSprings 101 went 66 → 54 buildings after the 03:41 road landing and that is a RE-ROLL, not a loss. A fingerprint diff after such a change is noise. Prove "no behaviour change" by comparing the stream after every draw (f5's `mapplan_probe`); answer "fewer lots?" with the MEAN over 8–10 seeds, never one seed.
- **Patterns**: (79) walking a live registry while the callee appends to it = infinite loop with no error (the 280 s Studio hang); deciding a voxel's zone by its CENTRE leaves the edge column blended — flat-with-a-lip — a column is 4 studs wide. (0d) a camera helper that adds ORIGIN, given world points, frames the sky and the setup note still reads fine; **every render view asserts IN FRAME / NOT IN FRAME** from the target transformed into camera space and prints it. (f5) a probe queued against a place built BEFORE the change tests the old code; "old vs verbatim old" passes by definition — rebuild, then queue.
- **Terraces / party walls: DECIDED NO (Cities agent, 08:3x)** — every building stays an island with its own footing (destructibility and footing are per model; shared planes across models are the flush z-fight case). A terrace reads from the street as alley 0–3 + flush fronts + blank shared-side walls; the lots pass closes the front gap with a wall/gate. f5's batch 2 (`plan.variant`) is unblocked on that basis. **Town budget**: all town work ≤ +0.3 s wall per map on the Bay (7 towns) on top of TownThemes' measured 0.235 s (1,314 parts; ~200 ms of it is two `task.wait`s per town, parts ≈ 0.02 ms each); no extra yields; ≤ +400 parts per town. `TownKinds.lua` landed (data only, inert until 79's reader).

## 08:45 — WEEKLY LIMIT HIT (resets Sep 21, 13:00 Indianapolis) — HANDOFF (claude-43)
Every tab on this account stops as it hits it. **On resume (any coordinator): read this section, then OLIVER_LIST.md, then Oliver's notes file `C:\Users\oliver\Downloads\make improvements to the shown map.txt`. FIRST JOB: get claude-f0's two gun regressions PROVEN (probe output read yourself), then rebuild a playtest. Do not land anything else before that.**
- **Last playtest delivered: 0442** = the 04:42:37 build (drop-picker cursor fix HudClient:1897/:2108 IN; `PLAYTEST_CHECKLIST_2026-09-18_0442.md`). Oliver's open bugs in it: (1) ground gun pickups render as black tangles — f0, cause UNKNOWN, `tools/ground_gun_probe.lua` written, its Studio run was in the queue; (2) hand covers the sights — f0 fixed Viewmodel.lua 08:19 (`FINGER_MIN_CLOSE`; a finger with nothing to grip parks inside the palm) — proof NOT seen; (3) controls hint opens behind the daily-quests panel — ee edited ControlsHint.client.lua 08:20 — render NOT seen.
- **Shared tree**: three checks green 08:18 (290 files). Edits after the 0442 build, all UNPROVEN in a playtest: MapBuildings `RollPlan(downtown, profile)` (f5, `nil` = old behaviour, `mapplan_probe` must be re-run against a REBUILT place), EasterEggs 04:46, TownKinds.lua (inert), Viewmodel 08:19 (f0), AdminService/MenuClient 08:19 (ee), ControlsHint 08:20 (ee), VehicleModels 08:21 (0d drumsticks 0.17 wide). f5 rebuilt `BrainRotRoyale.rbxlx` ~08:35 from this tree.
- **In flight, results never seen**: FlattenPad run 21 (79 — lands if clean; then MapWilds hook → TownKinds reader + `RollPlan(:305)` → TownThemes hook → mountains (+2.4–3.6 s; Bay has no slack) → roundabouts/rural paths → vehicle placement + `ParkInTowns`). Pipe-end run 16 (0d — three IN FRAME shots tick #61; #50 drumsticks). f5: banded floating-loot audit (`spotNoGround` 3/1/5 unambiguous; SahurSprings cluster y≈38.9 near (-580,367)), `mapplan_probe`, #60 odds. 4a: merged8. ee: admin probe (#52), controls hint render. a4 [e8e0d6]: 04:32 gallery = 0/20 shots with all setups run — OPEN HARNESS QUESTION: does one of its views draw a ScreenGui over the bottom-left tag row? (tag = CoreGui ScreenGui DisplayOrder 100000, bottom-left). **Speed test #2 (hold 0.6) captured 5/6, view 2 MISSED → hold 0.6 is NOT safe; keep `-Hold 1`** (frame loop = 200 ms sleep + GetPixel scan; making the scan LockBits-fast is the fix if faster galleries are still wanted). Abilities agent: Tier A LANDED; Tier B (CompanionFxClient + 8 cues) in scratch only, gallery queued. Eggs+storm agent: two gallery fixes then queue; nothing reported. Pre-match UI agent: `scratchpad/vote_drop/gallery1/` finished; **CORRECTION: it DID edit a game file — `VoteService.lua` is already v2 in the tree (2026-09-18 08:27, mode+map candidates, readiness gate, Resolve() returning mapId+modeId and caching), inert because nothing reads the mode half yet;** next = VoteService v2 + `VoteScreen.lua` + `VoteDropClient.client.lua`; its 4a patches (GameMode.Resolve modeId; MatchConfig:13 AllReadyCountdown 8) are NOT applied. Background agents live under session f1db7211 and cannot be resumed from another session — re-brief from their sections above.
- **Not started / unfinished on Oliver's list**: #1/#2 (TOP PRIORITY), #7, #11, #13, #16, #17/#18, #20, #21, #22, #23 (**CORRECTED 09-21: it IS wired — MovementService:437 calls it, Bootstrap:352 binds it to CombatService.BreakGlassAlong, and the built place has the line. #23 is a PROOF gap, not a code gap; movement_probe:700-790 has the test with its planted fault and has never been run**), #24, #25, #26 (after regressions), #28, #30, #31/#32 (Cities), #41/#42/#45, #43, #44, #46/#47 (probe queued), #48/#49/#50/#51, #53, #56, #57, #64 frames. Ticked so far: #3 #5 #8 #9 #12 #15 #19 #27 #36 #37 #38 #40 #55.
- **Oliver's own to-dos**: die twice in a TDM (final proof of #4/#6); create the developer products in the Creator Dashboard (every product id is still 0).

## 2026-09-21 17:3x — NEW FLEET (claude-43). Oliver's list re-numbered to #1-#87.
Every tab from 18 Sep died with the weekly limit. Ten background workers spawned fresh, each owning a slice.
Model per tab (Oliver: "give every task its appropriate model"): Opus = respawn/match flow, guns+FPS, menu revamp, map+towns, pre-match UI. Fable = destruction/throwables, eggs+storm+audio. Sonnet = HUD overlap audit, vehicles, bots.
| Tab | Owns | Oliver's items |
|---|---|---|
| Match flow | MatchService, GameMode(s), ModeTeams, ModeKingOfTheHill, LobbyService | **#74/#4/#6 (worst bug — "fixed" twice, still happening; find what the probe missed BEFORE re-fixing)**, #82 |
| HUD | HudClient, ControlsHint, ModeScoreHud, CompanionAbilityIcon, HitSplatClient, InventoryPanel, UiKit/PhoneLayout | #80 #86 #59 #68 #10 #54 #14 + controls-hint-behind-quests |
| Menu | MenuClient + menu modules, CrateData/Open/Models, CosmeticData/Preview, PlayerData+CrateService (additive) | #66 #65 first, then #78 #20 #21 #24 #17 #18 #76 #77 |
| Guns | GunModels*, Arsenal*, WeaponData (stats via 43), Viewmodel, GunFx, CombatClient, WeaponService gun fns | **ground-gun tangle + hand-over-sights regressions first**, #11 #13 #26 #34 #44 #72 #79 #30 #25 #64 #87 |
| Vehicles | VehicleModels, VehicleService, TrafficClient, vehicle cues | #83 #84 #60 #61 #51 #53 #57 #16 #49 #39 |
| Destruction | ExplosiveFx, ProjectileClient/Service, StickyPreview, ThrowableModels, DefensePlacement, destruction path | #70 #29 #63 #69 #71 #56 #23 #48 |
| Bots | BotService, MatchConfig bot fields | #46 #81 #75 #47 #33 |
| Map | MapGenerator/Buildings/Decor/Terrain/Wilds, RoadNetwork, TownKinds, TownThemes, Landmarks, LootService | #32 (LOTS of effort) #31 #28 #35 #43 #73 #85 |
| Pre-match UI | VoteService, DropMapService(new), VoteScreen/DropPicker/VoteDropClient, RateLimit DropMap line | #2 #1 (top priority; must keep the drop-picker Modal+MenuOpen cursor fix) |
| Eggs/storm | EasterEggs, StormClient visual, eggs_gallery, movement+UI cues | #62 first, then #41 #42 #45 #22 #49(with Vehicles) |
Rules unchanged: reports to claude-43 only, short and evidence-first; three checks pasted verbatim; permanent planted faults; rebuild before queueing a Studio run; renders labelled NOT IN THE BUILT PLACE until the code is in the tree.
**Oliver's notes file re-ticked 17:30**: [x] #3 #5 #8 #9 #12(superseded by #64) #15 #19 #27 #36 #37 #38 #40 #55; [~] #4 #6 (REOPENED by his #74), #10 #39 #50 (#61 says the Ranger still has poles) #52.
**RULE 9 — APPROVAL GATE (Oliver, 2026-09-21): "keep me updated on everything before you land a fix, show me galleries."** Nothing lands in the shared tree until the tab has sent claude-43 (a) a diagnosis/design note BEFORE building, and (b) measurements plus a GALLERY RENDER before landing, with absolute PNG paths so Oliver can be shown the actual images — then landing waits for claude-43's go. Work continues in scratch/private builds meanwhile; the gate is on landing, not on working. An invisible internal fix still needs a one-line "about to land". A visual change with no render is sent back. Exception: a fix Oliver is hitting constantly with nothing to look at (e.g. #62 slide sound = explosion) lands on a one-line diagnosis + confirmation.

## 2026-09-21 17:5x — HARNESS: Studio launch fixed; scratchpad collisions (claude-43)
- **EVERY Studio job was failing to launch.** Root cause (claude-f0, measured): the `.rbxlx` association in `HKCR\Roblox.Place\shell\open\command` pointed at `version-273e391d685948a8`, which **no longer exists on disk** — a Studio update replaced it mid-session and left the association stale. `Start-Process $place` therefore had nothing to open and threw "Application not found"; tabs read it as "my probe failed", re-queued, and the queue churned with nothing running.
- **FIX LANDED in `tools/gallery.ps1` and `tools/runtest.ps1` (claude-43's plumbing):** a `Start-StudioPlace` helper resolves the newest `RobloxStudioBeta.exe` under `%LOCALAPPDATA%\Roblox\Versions` (then Program Files) and launches it with the snapshot path as an argument, keeping the shell association as a fallback. The snapshot path stays on the command line, so `Get-StudioRunProcesses`' matching is unaffected. **Proved, not assumed:** the old call reproduced the exact error, the new one started Studio (pid seen), and the test instance was closed. No registry or Roblox setting was touched — Oliver's rule.
- **LESSON: a harness that depends on a file association depends on something an auto-update can silently break.** Launch the executable, not the document.
- **SCRATCHPAD COLLISION — every background worker in one session SHARES a scratchpad directory.** `<scratchpad>/tree` is a colliding name: one tab's private build overwrote another's edited copy mid-work, and a `-PlaceFile <scratchpad>/tree/...` run measured a build carrying a DIFFERENT tab's unlanded changes. **Rule: name your private tree after your tab (`<scratchpad>/menu_ee_tree`), never pass a generic scratch path to `-PlaceFile`, and keep your edits in one idempotent apply script so a clobber costs one command.** Any run whose `-PlaceFile` was under a generic path is suspect and must be re-checked.
- **#65 is a DESKTOP bug too, not phone-only** (menu tab, arithmetic pending its probe): the live rail has NINE destinations (Brainrots, Trade, Crates, Style, Cosmetics, Pass, Quests, Robux, Settings) — 9x56 + 8x8 = 568 px of rail in a 539 px nav at the 1280x720 the shell is frozen at, so the ninth draws 13 px below the panel in a Frame that neither clips nor scrolls. Also **`Style` is missing from `DESTINATION_LOOK`**, so it renders with an empty icon slot — a second visible defect nobody had filed.
- **HARNESS LIMIT (measured 09-21, menu tab): NO PROBE IN THIS HARNESS CAN SYNTHESISE INPUT.** `VirtualInputManager:SendMouseButtonEvent` throws "The current thread cannot call ... (lacking capability RobloxScript)" from the runtest plugin thread — Studio's plugin sandbox refuses synthetic input. So a button click, a drag, a touch target, a held key: none can be driven by a probe. Prove the DECISION (the value in the handler slot, the predicate, the rect) and let Oliver's playtest prove the WIRING; say which half you proved. Corollary: run each probe section in its OWN pcall, with the geometry FIRST — one tab lost a whole slot's measurements because an input error aborted the probe before the numbers ran.
- **Never pass an assumption INTO a containment check.** The same tab's nav check took `clips = true` as a given; had the nav stopped clipping, it would have reported "nothing outside the panel" for a menu drawing outside it — the exact false pass the fix existed to prevent. Read the property off the instance and assert it separately.
- **RULE 9 IS ENFORCED AT BUILD TIME (claude-43, 09-21 18:0x).** Two tabs landed unproven work in the shared tree within ten minutes (admin fly + its module; vehicle health/roadkill with its probe queued and never run). Nothing was reverted — the code read carefully and the checks were green — but the reason the gate exists is that **playtests are built FROM THE SHARED TREE**, so anything sitting in it reaches Oliver whether or not it has been proven. From now on: before each playtest build claude-43 lists every project file whose mtime is newer than the last build and requires the owning tab's EVIDENCE for each one; anything without evidence is named "IN THE BUILD, UNPROVEN" on Oliver's checklist. A tab that lands ahead of its evidence keeps working but lands nothing further until that evidence arrives.
- **A filter is a claim about what it matched.** A vehicle rod audit filtering `Shape == Cylinder` reported the Van "clean" while never looking at its BEAM parts (a 0.12x0.14 box is a thin rod too). The earlier "clean" result was not a measurement of zero faults, it was a measurement of nothing. Every audit must print HOW MANY CANDIDATES IT EXAMINED next to how many it flagged.
- **LESSON (menu tab, 09-21): nothing in this harness can run a LocalScript, so logic written in one is logic no probe can ever check.** That is precisely how a missing `MenuShell:SetViewport` call hid for months, leaving the short/tall menu forms running only in the gallery and never in the game. When choosing where to put a wire, ask "could a probe ever see this?" — prefer a ModuleScript over a LocalScript when the answer is no. Related guard from the same tab: if a default value and the truth can coincide (a shell defaulting to 1280x720 measured in a 1280x720 window), a skipped-setter planted fault passes silently — report INCONCLUSIVE rather than green.
- **OWNERSHIP TABLE IS STALE ABOVE THIS LINE.** Every claude-XX named in the tables dated 09-17 and earlier (df, a4, ee, f0, f5, 0d, 46, 79, af, 76, 3b...) died with the weekly limit on 09-18 and is NOT coming back. The 09-21 fleet table is the live one. A file attributed to a dead tab is UNOWNED: claim it through claude-43 rather than deferring to a name.
- **"IN FRAME" IS NOT "VISIBLE" (guns tab, 09-21).** The project's frame-check convention catches a camera pointed at nothing, but NOT a target behind a wall or under a floor: three "pickup" renders photographed bare ground while every view reported IN FRAME, because the pickups had snapped four studs underground. **Add an occlusion ray to every frame check** — cast to the target and print, by full name, what it hits on the way. Root cause of the underground pickups is its own lesson: `LootService.snapToGround`/`scatter` raycast only against `workspace.Terrain` and `workspace.Map`, and the gallery built its test ground in its own folder, so both fell back to "two studs below the spot". **A probe standing in for part of the shipped path must stand in for what that path READS, not only what it writes.**
- **Studio dies at ~3.6 GB.** A bot probe crashed with no log at 3.16 GB after five back-to-back Studio jobs from other tabs. Growing one probe's single session (S1-S25 + 12 duel bots + 20 new + 40 free-roam) is real memory cost: split a big scenario into its own smaller probe rather than adding to a long-lived session.
- **RULE 7 AMENDED — PLANT THE REAL BUG, NOT ONLY A SYNTHETIC NEEDLE (match-flow tab, 09-21).** A needle can pass while the check is dead. Case: a new `verify.py` check read source through `_strip_lua` (`tools/verify.py:31`), which **replaces every string literal with an empty one** — correct for finding CODE, fatal for checking what a string SAYS. The check saw `description = ""`, found no digits, and passed; its planted needle still went green **because the needle was handed a raw literal while the real check was fed stripped source**. Two rules follow: (1) a check on a string's CONTENT must strip comments only, never strings; (2) **the planted fault must travel the same input pipeline as the real input** — a needle fed by another route proves a detector that works on a route nothing uses. Same shape as a self-test that plants its fault using the very mechanism that is broken. The tab caught it only because it ALSO planted the original bug and watched the check fail properly.
- **Drift fix pattern:** do not correct a stale number in prose — compose it from the data. Mode descriptions now carry no digits and append `First to %d ...` from their own `scoreTarget`, plus a `verify.py` check that any digit in a description must agree with it.
- **`a and b or c` IS UNSAFE WHENEVER `b` CAN BE nil OR false (menu tab, 09-21)** — and in a containment check it fails in the DANGEROUS direction. Case: `clips and intersect(a,b) or cellRect` — a cell clipped entirely out of the window makes `intersect` return nil, the `and` yields nil, and the `or` falls through to the UNCLIPPED rect, so a safely hidden cell is measured as if drawn and reported as spilling out. Use a plain if/else in any check.
- **CONTAINED IS NOT REACHABLE (menu tab, 09-21).** A containment check passed a bottom bar holding two rows of cells in one row's height, because the sliced cells were still inside the panel — **a half-height tab is not a tab**. Count cells cut off at a container edge SEPARATELY, and assert that a nav which cannot scroll shows every destination WHOLE (a rail may leave cells below the fold because it scrolls to them; a bar may not).
- **MAKING A FORM REACHABLE MAKES ITS BUGS REACHABLE.** The menu's bottom bar height was computed in `SetViewport` from the wrapped-cell count, and `SetDestinations` never re-ran it — so the bar was always sized for a count of ZERO (66 px tall holding 93 px of cells, second row sliced to 14 px). Latent forever, invisible only because `tall` never ran in the game. Expect the same shape wherever an unreachable path is being un-hidden.

## 2026-09-21 19:3x — BUG HUNT TAB, AND A STANDING PRE-BUILD SWEEP (Oliver)
Oliver: *"make sure the bug checker is running at FULL POWER"*, then *"make sure it sweeps EVERY GAME, and EVERY UPDATE"*. A dedicated bug-hunt tab now works two jobs:
1. **Whole-project sweep with PROVEN COVERAGE** — every .lua in ServerScriptService / ReplicatedStorage / StarterPlayerScripts / StarterGui / Bootstrap, against the twelve patterns recorded in the 09-21 sections above (ignored return value; two systems writing one property; a state snapshot treated as an event; behaviour keyed on a NAME; a flag written and never read; a handler captured as nil at build time; a code path with no production caller; a check that cannot fail; a stale copy of a number defined elsewhere; a silent `warn`-and-return refusal; `os.clock` as wall time; weak-keyed tables holding live Instances). It keeps a coverage table and reports files found CLEAN as results.
2. **A STANDING GATE ON EVERY LANDING.** claude-43 lists every project file whose mtime is newer than the last playtest build; the bug-hunt tab sweeps exactly those before the build goes to Oliver. It judges a change by what it now TOUCHES, not only its own lines (today a wreck lock was undone by an unrelated seat handler that had been correct for months), and it checks the CLAIM as well as the code — did the broken thing change behaviour, or did a symptom move?
**Every tab: expect your landings to be swept.** A finding against your file comes back through claude-43, not as an edit by another tab.
- **A PLANTED FAULT AIMED AT A BUG HAS A SHELF LIFE; AIM IT AT AN INVARIANT (match-flow tab, 09-21 — THREE instances in one session).** Every expired plant read "the broken thing is still broken" ("a teamless bot is never retired", "never comes back"), so landing the fix killed the plant and the check went quiet while still printing green-adjacent output. Their replacements read "this must never happen" — a death after `stopWorld` retires nobody and spawns nobody; `onDeath` for a token that is neither player nor bot does nothing. **Write plants against invariants.** And note the corollary that caught one of them: a dead self-test is a check proving nothing, so a probe must SAY when a plant failed to fire, not merely count passes.
- **PIN THE BEHAVIOUR, NOT THE ENVIRONMENT (vehicle tab, 09-21).** `VehicleService.Create` with no `options.model` draws its own Random, so a fixed-throttle test crossed a damage threshold on a different car between two runs of identical code and a PASS became a FAIL. Every probe spawn pins its model.
- **`Enum.PartType.Cylinder` puts its circular faces on the X axis** — `Size.X` is the length ALONG the axis, so `Vector3.new(diameter, height, diameter)` builds a squashed disc lying on its side, and an attachment on a standing cylinder is in a TURNED frame (so "up" is not +Y and a plume vents sideways). Cost the map tab a render in which three chimneys and two tanks lay on the grass while every number in the run was correct. Use one shared `upright()` helper.
- **A COUNT OF THINGS YOU ENABLED IS NOT A COUNT OF THINGS THAT RENDERED (guns tab, 09-21).** A run reported "40 rims switched on" and 8 of 8 planted faults, every statement true, and **none of them noticed that nothing was drawn** — a `Highlight` adorning a BasePart lights only that part, and the pickup's gun pieces are children of an invisible base. When a check is about something VISIBLE, sample the pixels and assert they changed; a property you set is not a thing the player sees. Fourth render-caught fault of the session that passed every number it had.
- **"IN FRAME" IS NOT "VISIBLE", PART TWO (match-flow tab, 09-21):** a frustum test says where the camera POINTS, not what is BETWEEN it and the subject. Two renders passed 18/18 checks showing a tree trunk and eight bots as single pixels across a 650-stud arena. Every view now raycasts camera->subject and fails with `OCCLUDED by <instance>`; `frameClear` tries eight bearings and says so when all eight are blocked. **And a wide shot of something small is not a picture of it** — frame the subject at a distance where it can be judged.
