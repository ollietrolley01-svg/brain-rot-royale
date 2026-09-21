# Oliver's 58-item list (2026-09-18 ~01:0x)

**Oliver, 01:2x: "try and do this all before our next session limit."** So: PRIORITISE, PARALLELISE,
and do not let the Studio queue serialise cheap work.

**TIER 1 — QUICK WINS. Land WITHOUT a Studio job where the three static checks suffice** (a value
change, a keybind, a sound removed, a rename). Static green + a one-line report = done. Do these FIRST.
#3 crouch=C · #8 stamina drain · #15 lobby stamina · #38 stamina sound · #25 Z zoom + scroll hotbar ·
#19 pass=450 · #10 TDM=100 kills (server) · #41 rename "The Sweaty Incident" · #40 aim nerf (values) ·
#12 shotgun buff (values, after claude-43 approves) · #9 van bat orientation · #29 airburst scorch.

**TIER 2 — CRITICAL BUGS**, need a Studio probe but jump the queue: #4 #6 (respawn), #5 (arena size),
#33 (bots not dropping), #39 (vehicles in ground), #28 (obby branches), #37 (stairs into walls).

**TIER 3 — BIG DESIGN JOBS** (hours each, renders): #32 cities · #20 menu redesign · #52 admin menu ·
#58 sticky bomb · #56 whole map destructible · #21 crates · #17/#18 cosmetics · #46 bot team play ·
#2 voting screen · #26 fingers. These will NOT all land in one window — quality first, in order.

**STUDIO QUEUE DISCIPLINE, tightened:** one job per tab holds; **merge EVERYTHING you have into it**;
never queue a render-only job for something a probe job could capture in the same run.

Source: `Downloads/make improvements to the shown map.txt`. **claude-43 owns this file.**
A box is ticked ONLY when claude-43 has verified it in the tree or in a render — not when a tab says done.

Status key: `[ ]` not started · `[~]` dispatched/in progress · `[x]` verified done

---

## CRITICAL — game-breaking, fix first
- [~] **4. Respawn put me in the LOBBY** — PROVEN AT SEAM LEVEL (merged7, 05:5x): all 5 pads refused by planted enemies → old call returns false (the lobby wait), new call places at once 24 studs from the nearest enemy under protection. Awaiting Oliver's play test. IN TREE. Cause: (a) every pad refused (90-stud clearance, pads only 30 round a base, one enemy refused them all) → body waited on the lobby SpawnLocation up to 4×1 s; (b) StartWorld built pads AFTER the spawn loop → 1 s in lobby at every mode start. Fix: least-bad pad at once under protection; StartWorld before the loop in respawn modes. Probe queued (merged7). **Final proof = Oliver dying twice in a TDM and coming back on a pad both times** — Run mode has no Player.
- [~] **6. Died and never respawned** — IN TREE. Cause: `OnCharacterAdded`'s match branch never re-armed `watchDeath` on the new humanoid, so a respawned player's next death reached nobody. Fix: armed on every match body. Same probe, same final proof.
- [~] 5. TDM/KOTH map area far too small — IN TREE. `clamp(mapRadius×0.50, 450, 650)` (was 0.30, 280..380): Sahur 380→640, Tralala 285→475, Bay 380→650, RotRidge 280→450, Plains 345→575 — 2.5-2.9× the area. Oliver judges in play.

## Game modes
- [~] 2. Game mode voting screen before matches → Pre-match UI tab. **TOP PRIORITY (Oliver, 04:4x): "need to be top priority."** Design fast-tracked; seams to ee/4a jump their lists.
- [~] 1. Drop-location picker map + graphics → Pre-match UI tab. **TOP PRIORITY**, second behind #2.
- [~] 10. TDM first to **100 kills** — SERVER HALF verified `GameModes.lua:194 scoreTarget = 100`; HUD half CODE-LANDED in new `StarterPlayerScripts/ModeScoreHud.client.lua` (197 lines); render in claude-ee's queued job → then tick
- [~] 54. KOTH HUD at top — CODE-LANDED in `ModeScoreHud.client.lua` (match time; "held longest and by how much" said as the leading score and the gap, since KOTH's score IS seconds held); render in claude-ee's queued job → then tick
- [x] 27. Enemies in team modes get a **red aura**, must NOT show through walls — VERIFIED by claude-43 in the render: no wall = visible, behind wall = fully hidden, planted AlwaysOnTop fault = glows through. In tree; lands in the next build.
- [~] 46. Bots in the new modes just circle → DESIGN APPROVED (04:3x): the wander goal becomes the mode objective (the "circles" fix); KOTH contest/hold with bots spread on the ring; TDM rally to the friendly centroid within 80 then push as a group to last-seen. Reads claude-4a's mode state via a lazy loader. Measured: no-objective time, bot hill occupancy, teammate spread at fight start. BUILT (04:4x): reads mode state through one overridable seam `BotService.ModeState` + `IsHostile`; KOTH bots fan round the ring on golden-angle slots (never stack), hold = stand low; TDM rally to friendly centroid within 80 if >40 away, else push to the team's shared last-seen (25 s memory), else sweep. Both hooks nil in the BR half so free-roam numbers stay clean. In the queued probe (11 ahead) → tick on the numbers.
- [~] 47. Bots shoot through walls and barricades → CODED + RECHECKED: bots fire through penetrable cover; a recheck caught that a bot would shoot down its OWN barricade (its wall read as "enemy behind cover") — fixed: bots track structures they built and never fire on them; only RotBarricade (250 hp) counts as shootable cover. In the queued run.
  (#40 note: the 50/43/12% hit rates were inflated ~10% by counting damage ÷ per-hit with 1.9× headshots in the mix; event-count numbers coming. The constants stand.)

## HUD / menu / UI (claude-ee)
- [ ] 1. Improve the map on the drop-location picker and its graphics
- [~] 14. Brainrot ability HUD — CODE VERIFIED by claude-43: position measured off `UiKit.BottomRow.HotbarInset + Gap` (`CompanionAbilityIcon.lua:43`, was a literal x326 in the gutter), `SetStats` readout "24 DPS · 18 dmg / 0.75s · 180 HP" (:167+), called from `HudClient:3981`. Render in claude-ee's queued job → then tick.
- [ ] 20. Polish the menu — cleaner, more concise; full redesign if needed
- [ ] 22. Directional HUD cue for **nearby bullet sounds** (like the damage arrow, different colour)
- [~] 24. "Kill animations" tab in the shop — SLOT DECIDED (04:4x): top-level tab on large/short; inside STYLE on tall (ten flat destinations = 38% of a portrait screen). Same rule for #60: top-level on large/short, tier filter inside CRATES on tall.
- [~] 52. **Admin HUD for Oliver only** — UserId **53193685** (typed by Oliver to claude-43, 05:0x; claude-ee had held for first-hand confirmation — UNBLOCKED 06:3x, the number IS first-hand). Server-authoritative, absent from every other PlayerGui, two permanent planted faults (wrong user gets nothing; wrong constant gives Oliver nothing), every action logged. CODE-LANDED (07:1x): `AdminService.lua:42` UserId in one place; every grant validated against real tables, coins clamped, refusals silent; `AdminHud.client.lua` builds nothing until `AdminHello` fires to the admin alone; `RateLimit.lua:41 AdminAction {burst 10, rate 5}`; both planted faults + nine forged payloads in `tools/admin_probe.lua` (queued); every action logged. "Spawn event" needs `MatchService.SetEvent` → claude-4a. Tick on the probe.
- [ ] 53. Vehicle low-health warning HUD

## Movement / input (claude-af [0bccf5])
- [x] 3. Crouch button = **C** — verified `Settings.lua:26` default "C"; C was the old slide key, now free.
- [~] 7. Potion drinking animation clips into your face — in one merged Studio job with the renders
- [x] 8. Stamina bar should take longer to empty — `SprintDrainPerSecond` 9 → 5.5; 11.1 s → 18.2 s of sprint.
- [x] 15. Infinite stamina in the lobby — was already true both sides (`staminaApplies` gates on InProgress); the dead `LobbyDrains` key removed so nobody trusts it.
- [~] 23. Vaulting should break through windows — **BREAKING HALF MISSING (06:2x, claude-43 grep):** `Parkour.lua:117` says MovementService breaks the pane; MovementService never calls `CombatService.BreakGlassAlong` (:314). Detection in, break not wired. Oliver re-asked ("make sure"). claude-af [0bccf5] landing the call + probe with planted fault, ahead of #7.
- [~] 25. Zoom → hotkey **Z**; mouse **scroll wheel** switches hotbar items — spec written; claude-43 granted claude-af [0bccf5] a one-time edit of f0's wheel block and the (terminated) HUD worker's slot block
- [x] 38. Remove the out-of-stamina sound — no longer played; SoundConfig entry kept defined for a future breath cue.

## Guns / animation (claude-f0)
- [ ] 11. Arm joints look disconnected on long rifles in FPS
- [x] 12. Buff the shotguns a decent amount — VERIFIED in the tree by claude-43 (Pump 13/7/110, Tralala 13/7/110, CleanSweep 12/8/100, Scattergun 13/6/125, Nonna 16/7.5/105, Bonker 13/8/90; falloff note at WeaponData:19). Hip damage at 10 studs: Pump 32→69. Only Nonna crosses the 200 one-shot gate, before and after. In tree; next build.
- [ ] 13. Third-person animations should match the first-person ones
- [ ] 26. Bending fingers on the hands; must not block the crosshair
- [ ] 30. Make gun tracers more visible
- [~] 34. Lag-switch SMG duplicated barrel — SMG FIXED (cocking tube stood 5 mm clear of the handguard for 124 mm, held at one end; now banded at the front, sight line kept). All-guns check: `tools/floating_tube_probe.lua` written with self-test, runs next Studio job.
- [ ] 44. FPS animations should use **your avatar**
- [~] 55. Improve the reloading sounds — LANDED: none of the 14 reload beats had a layer below pitch 1 (all button/click/snap); the 7 CLOSING beats now carry a low layer, opening beats stay light. Volumes untouched (reloads were already louder than shots). **Needs Oliver's ears in a playtest.**

## Vehicles (claude-0d)
- [~] 61. **Exhaust pipe end is see-through** — ROOT CAUSE (05:5x): the exhausts DID NOT JOIN UP (Scrambler header stopped mid-air short of the silencer; Streetfighter headers started outside the barrel; Scoot pipe clear of both ends; Ranger exhaust ended beside the sill). All four joined; every exit has a dark bore set back inside. Open-end audit with planted fault PASSES (3 → 6). `pipeend_<model>` views landed in run13 but **048 (Scrambler) is EMPTY SKY — camera framed nothing**; re-frame from the exhaust pivot with a content assertion; claude-43 checks all three before ticking.
- [x] 9. Bat on top of the van — VERIFIED by claude-43 in `run13/033_rearquarter_SahurVan.png`: raked up on the rack, no longer lying flat. In tree; next build.
- [ ] 16. Replace the old map cars with the new drivable designs
- [ ] 31. Real **parking lots** in the cities for cars to spawn on (with claude-79)
- [~] 39. Some vehicles are stuck in the ground → claude-0d — measured WITH the vehicle loop running (the earlier -1.70 was the loop off; hulls collide, wheels are decoration): 0 buried, mean tyre gap -0.17, body 0.73 (design 1.0 minus suspension). 1 of 13 hangs 1.48 studs on a bank because MapGenerator asks for that spot — fixed by the routed placement patch in claude-79's LANDING ORDER. Tick when that patch is in a build. Related #50: the Van's "black poles" are its two roof DRUMSTICKS (1.72 × 0.10 rods) — thickened to 0.17 with heads; render in run 16.
- [ ] 49. Improve the sound of the carts running
- [~] 50. Car designs have random black poles sticking out — CAUSE FOUND (door seams pushed 0.2 proud by a z-fight fix); fix verified in tree `VehicleModels.lua:855-856, 1247-1248` at 0.02; render pending in run 11
- [ ] 51. Old car models on the roads can't be destroyed
- [ ] 57. Roadkill with cars

## Map / world (claude-79, claude-46)
- [~] 32. **Cities** → Cities tab (Fable). PHASE 1 APPROVED (04:4x): 18 named characters (shuffled onto 4-7 slots/map) in 7 layout kinds (neighbourhood/industrial/downtown/market/rural/campus/harbour); each town gets a claimed YARD block + lot dressing + verge character + palette; +300..560 parts/town; contracts out: `TownKinds` reader → claude-79 (critical path), `RollPlan(downtown, plan)` + palette → claude-f5. Rotville + NPC Nook first. Job 1 measures today's cost + discharges the twelve never-in-Studio fixes.
- [~] 31. Parking lots — CONVERGED with #32 (Oliver re-asked 04:4x: "real parking lots and spaces that make sense instead of random places on the grass"): every town kind declares `ParkingBays`; claude-0d's town tier parks ON them; grass becomes impossible by construction. claude-0d + Cities tab + claude-79.
- [ ] 43. All benches on sidewalks must face the road → claude-46/claude-79
- [ ] 45. Make the storm brainrot-themed → claude-46
- [ ] 28. Treehouse obby branches aren't solid — you fall through → claude-46
- [x] 37. Some buildings have stairs leading into walls → claude-f5 — FIVE MAPS CLEAN on the 04:42 build (`wallHoles=0`; `stairTops` = `flights` 54/55/48/48/51 with no blocked key; self-tests 0 as built → 1 planted, every map). claude-43 read `ab/audit5.log` (08:16) itself. TICKED on Oliver's list.
- [ ] 56. Make the whole map destructible → claude-4a

## Easter eggs (claude-46, inherited from claude-76)
- [~] 41. Improve the arrest egg — roof broken, arms broken — and rename it **"The Sweaty Incident"** — RENAME verified in the 03:23 build (2 refs); roof/arms fix still owed
- [ ] 42. Revamp the other low-quality easter eggs to high quality

## Items / effects
- [~] 29. Explosions leave a giant black circle floating — ground case VERIFIED (`gallery5/001` vs `002`; `003` airburst no mark). **REOPENED by Oliver (06:4x): "what about when its on the second story of a building and destroys the floor under it"** — scorch must land on the upper floor (not the ground below) and must go WITH a destructible surface that the blast removes, or be removed with it. Probe + planted fault (scorch parented to workspace → reported floating) → claude-a4 [e8e0d6]. Tick when both cases are measured.
- [~] 48. Improve the blood splat and add particles → claude-a4 [e8e0d6] — CODED: life hold 3.0 + fade 1.0 = 4.0 s; halo/blot/tongues/droplets/runs, three particle emitters, blue-white sparks on shield; MAX_SPLATS 40→30 so 4 s cannot pile up. Render in its next gallery.
- [~] 58. Sticky bomb (Clingy Crumpet) — CODED end to end, untested until the probe runs: Ballistics kind "sticky", fuse 2.5 s, 110 over 12 studs, 45-part model, rides with what it sticks to, StickyPreview ghost (no text). Probe + gallery queued.
- [ ] 58. **Sticky bomb** — high-quality model and animation, translucent placement preview → claude-a4 [e8e0d6]
- [~] 35. Roof is inaccessible on the legendary barricade → claude-a4 [e8e0d6] — coded (hatch 3.8→5.8 with truss against one edge); opening/headroom measured by raycast in the same job
- [x] 36. A way to drop weapons and ammo from your inventory — server half always existed (DropSlot → TakeSlot → LootService.DropSlot, rate-limited); the missing piece was discoverability. VERIFIED: DROP button `InventoryPanel.lua:289-296` (claude-ee), shown for a selected slot with contents, same remote as right-click. In the 04:00 build. claude-4a's stand-in test of the server half still to come.
- [~] 33. Bots sometimes don't drop their weapons — CAUSE FOUND: in the battle royale drops are fine (measured); in TDM/KOTH `eliminate()` returns at the respawn branch ABOVE `dropLoot`, so NOTHING drops. RULED (06:5x): bots drop their held gun in respawn modes, players don't, coins/XP stay held → claude-4a (seam S7), merged8. Void-fall case could not be reproduced; not claimed.
- [x] 40. Nerf the AI aim a bit — VERIFIED `MatchConfig.lua:103-104` Near 0.66→0.55, Far 0.19→0.15. Measured on a pinned run (~48 shots/range): 50% / 43% / 12% hit at 20 / 60 / 150 studs (old predicted 58 / 43 / 19). Next build.

## ALREADY IN FLIGHT BEFORE THIS LIST — Oliver: "dont forget everything you already have queued up too"
- [x] **Road curves 90-degree fix — LANDED 03:41, verified by claude-43** (`CURVE_MIN_RADIUS = HALF + 5`, `CURVE_STRAIGHT = 12`; run 17: 0 bends left square on all ten builds, sharpest non-junction turn 10°, tightest radius 32). Parked cars moved to the flat verge in the same landing. Next build.
- [~] FlattenPad (floating buildings) → claude-79
- [~] MapWilds hook (trees + grass; Oliver asked twice) → claude-79, readiness claude-46
- [~] TownThemes hook → claude-79; sync-trap lift first → claude-46
- [~] Mountains + hills landing (built, proven, waits on roads) → claude-79 wires it
- [~] Roundabouts in every town centre + rural paths along country roads → claude-79
- [~] Bike pipe fix renders (curved audit) → claude-0d
- [~] Vehicle placement patch (bias fix, verge 36→20 decision, town tier) → claude-79
- [~] Bollicina Skiff + M3 placement → claude-0d
- [~] Four-finger hands (this is list item 26) → claude-f0
- [~] Slipper/Toaster balance edits → claude-f0
- [~] Confirming menu-version render pass (gallery6) → claude-a4 [34c594]
- [~] Barricade preview re-render without captions (p6) → HUD worker (terminated; renders run unattended)
- [~] Target dummies Studio verification → claude-4a
- [~] Wall-scan fix verification (windows=766, self-test PASS) → claude-f5
- [~] Crate card re-render without pity label → claude-f5
- [~] Parachute ropes redesign + CrownOfRot fix → claude-df
- [~] Bot wander-fix numbers (S22 + free roam) → claude-af [98425c]
- [~] Landmark stone steps (parts, not terrain) → claude-46
- [~] Reward-rate baseline for TDM/KOTH (pay nothing until measured) → game modes tab (terminated until 3:10am) / claude-a4 [34c594] for `progression_model.py`
- [~] Boulder sighting — awaiting Oliver's answer on which map / what they looked like

**Oliver, 01:0x: "tell the tabs to take their time."** Quality over speed on every item above. Rule 8b
stands (cut repetition, never evidence); rule 8's "finish and go idle" does NOT mean rush.

## Added by Oliver after the list (typed to claude-43)
- [~] 59. **Dummies RAGDOLL when they die** — MEASURED (arena gallery, 47 checks): corpse moves (fastest part 43 studs/s), at rest after 0.9 s, cleared 4.53 s with the stand empty, fresh body back 5.05 s tagged and full; CanCollide-off planted corpse fell 233 studs and was caught; frames 004/005 show it lying on the marble (a mid-fall frame is not obtainable — the fall is 0.9 s). One FAIL was the measurement (lowest point over 2.5 s caught the 0.37 impact dip before the solver pushed it out); now measures the resting pose, re-run rides with the next gallery → then tick.

- [~] 60. **Cosmetic crates tab** — BUILDING at 69/199/449 R$ beside 8k/25k/60k. Existing-crate repricing DECIDED (05:1x): flatter top 5/10/35/135/499/899/999, Pro bundle contents cut; HELD until Oliver updates the developer products in the Creator Dashboard (list coming to him). DESIGN (04:5x): STYLE 8k / DELUXE 25k (Epic+ pity 10) / PRESTIGE 60k (Legendary+ pity 8), all 65 cosmetics per tier, refunds 35/40/45%, animations 1.6/2.4/3.2 s skippable; tab flat on large/short, segmented inside CRATES on tall. Oliver asked: Robux-direct tiers? → claude-f5 leads; tab in claude-ee's shell; pools from claude-df's CosmeticData; models with claude-4a per the #21 split. Paid random items → accurate odds per tier, wrap not truncate, Beginner's boost never on paid. Design to claude-43 before building.

- [~] 62. **Merge dialog cannot be confirmed on a phone** (found by claude-4a's audit, confirmed by claude-ee, 05:0x): card is 436 tall on a 390 screen, nothing scales it, both buttons ~26 px past the bottom edge. CODE-LANDED (`MergeDialog.lua:163-165`) via `PhoneLayout.PanelScale`, NOT FitPanel — ee found FitPanel was the obvious wrong fix and said why in the comment. Render in its queued phone_reach job → then tick.

- [~] 63. **Brainrot abilities: improve designs and effects** (Oliver, via claude-ee's tab, 05:3x: "make a fable tab that goes through the brainrots abilities and improves their designs and effects") → Fable abilities tab. Phase 1 audit done: 126 brainrots share SIX identical effects and ONE attack sound; 4 of 6 moves do nothing with no target; Lob has no telegraph; Shockwave hits a 50-stud circle through walls; **a 0-HP companion can fight all match (announce-before-state)**. Tiers approved A → B → C. **Tier A CODED (07:2x), probe queued on its private build:** announce-last with one pcall+warn helper for all 7 sends (the undead-companion fix), splash LOS per victim (IgnoreWater true, refusals counted), Chain fork LOS + veto skip, point attacks land for all six, practice demo lands for all six, damageDealt pruned. Shockwave range `14+1.5×RarityIndex` → 14/16/17/19/20/22/23. B4 (Lob telegraph) moved to Tier B as visual.

- [~] 64. **Blood splats coloured by the RARITY of the gun that hit** (Oliver, 07:4x: "recolor the blood splats to the color of the rank of gun the target player or bot gets shot by") → claude-a4 [e8e0d6]. CODED (04:3x): HitSplatService decides the rank server-side from the weapon id (WeaponData, else ItemData, else none) as slot 5 of the hit; client maps to `Rarity.Color`; darker shade for halo/tongues/drips/mist; no-rank (hazard, bite) and shield hits stay plain red / blue-white. Probe SPLATCOLOR: nine guns + a throwable + unknown-id → false + a planted "everything Rare" lookup caught. Frame `splat_rarities` (seven hits, one per rank, labelled) in the relaunched gallery → then tick.

## Shop / cosmetics
- [ ] 17. Previews of every accessory and cosmetic → claude-df
- [ ] 18. Improve the accessory designs **before** making the previews → claude-df
- [x] 19. Brainrot pass = **450 Robux** — verified `GamepassConfig.lua:83` and in the 03:23 build. (claude-43 wrongly chased this as unlanded; it landed 03:17.)
- [~] 21. Redesign and improve the crates and their animations → claude-f5 — ANIMATION LANDED (04:3x): new shared `CrateOpen.lua` (lid swings on claude-4a's hinge instead of tumbling off; called by MenuClient's reveal AND the gallery, so the render is the real animation), per-tier feel (Common 0.34 s light settle → Prestige 0.62 s heavy landing). Models are claude-4a's per the split. Card + open film-strip gallery relaunched on the fixed harness (12 views) → then tick.
