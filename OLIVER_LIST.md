# Oliver's list — the ledger (#1–#135)

**Rebuilt 2026-09-22 from the handoffs, the two source files and COORDINATION.md.** The previous
version of this file was last written 2026-09-18 08:22, covered #1–#64 only, and had stopped being
true four days before this rebuild. The old copy is at `OLIVER_LIST.md.bak` (gitignored).

**claude-43 owns this file.** This rebuild is a restart of the ledger, not a takeover — take it back
over and keep it current at the hourly pass. It is the ONE place that answers "what is done", and
that question was unanswerable while this file was stale.

**Sources, most recent first:** `coordination/handoffs/*.md` (09-22 ~10:00–10:12) · COORDINATION.md
through the 19:1x pass · `make it easier to see whos an enemy.txt` (09-22 04:29) ·
`make improvements to the shown map.txt` (09-21 18:49) · the old `OLIVER_LIST.md` (09-18 08:22).

**The ticking rule stands: a box is ticked ONLY when it has been verified in the tree or in a render
— not when a tab says done.** Every `[x]` below carries the evidence that earned it. Where the only
evidence is a tab's own claim, the row says so.

---

## ⚠ READ THIS FIRST — #59 to #64 MEAN TWO DIFFERENT THINGS RIGHT NOW

Two numbering schemes are both live in the fleet's own documents, and they collide:

* **`make improvements to the shown map.txt`** numbers by position. #59 is "the splats cover your
  view", #64 is "the shotgun needs a slight nerf". This is provably the right reading of that file:
  items #88–#94 carry their numbers **written into the text**, and they land on exactly those
  ordinals. The fleet's own annotations in that file use it too (#12's note says "SUPERSEDED by your
  #64", meaning the shotgun nerf; #40's note points at #75/#81 for bot aggression).
* **The old `OLIVER_LIST.md`** gave #59–#64 to six items you typed separately to claude-43: dummies
  ragdoll, the cosmetic crates tab, the exhaust pipe, the phone merge dialog, brainrot abilities,
  and rarity-coloured splats. COORDINATION.md and four handoffs still use those numbers.

So **"#64" means the shotgun nerf in one file and rarity-coloured blood splats in another**, and
both are being worked from today. Same for #59, #60, #61, #62 and #63.

**Resolved here:** the positional numbering wins for #1–#94, because it is the one your own file
proves. The six separately-typed items move to **A1–A6** below, with their old numbers recorded so
nothing already written becomes unreadable. **Nothing was renumbered except those six.**

Two further items are mis-numbered in `coordination/handoffs/hud-menu.md` and have no valid number
at all — they are in **"Needs a number from Oliver"** at the bottom. One line from you fixes both.

---

## Status key

| Mark | Means |
|---|---|
| `[ ]` | **NOT STARTED** — no code, or design only |
| `[~]` | **IN PROGRESS** or **IN TREE / unproven** — the row says which |
| `[x]` | **DONE** — verified in the tree or in a render, evidence named |
| `[?]` | **HELD → OLIVER** — built or designed as far as it can go; blocked on your decision or your playtest verdict |

"Playtest" in a row means the code is in the build you are playing and only you can settle it.

## Where it stands, in one table

| | List 1 (#1–#94) | List 2 (#95–#135) | A1–A6 | Total |
|---|---|---|---|---|
| `[x]` done | 22 | 9 | 1 | **32** |
| `[~]` in progress / in tree | 41 | 13 | 4 | **58** |
| `[ ]` not started | 31 | 17 | 0 | **48** |
| `[?]` held → you | 0 | 2 | 1 | **3** |
| **Items** | **94** | **41** | **6** | **141** |

Counted from the rows below, not asserted: every number #1–#135 appears exactly once, no gaps and
no duplicates. Re-check with the row marks any time you doubt this table — if they disagree, the
rows are right and this table is stale.

---

# LIST 1 — #1 to #94

Source: `C:\Users\oliver\Downloads\make improvements to the shown map.txt`.

## #1–#20

- `[~]` **1. Improve the map on the drop-location picker and its graphics.** IN TREE — the picker and
  its cursor fix landed; graphic quality unjudged. "Higher res" is tracked separately as #105. — *pre-match UI*
- `[~]` **2. Add a game mode voting screen before matches.** IN TREE, probe-proven — VoteScreen,
  VoteService, VoteCursor, VoteReveal; prematch probe 8 cases 0 failures, 31 wiring assertions 0 failures.
  Ready-up loop landed 09:53. Playtest decides. — *pre-match UI + bug review*
- `[x]` **3. Make the crouch button C.** `Settings.lua:26` default "C"; C was the old slide key, now free. — *movement*
- `[~]` **4. Respawned me in the lobby.** IN TREE, probe-proven once — least-bad pad at once under
  protection; StartWorld before the spawn loop. **REOPENED by your #74**, which says it still happens.
  Final proof is you dying twice in a TDM. — *bug review*
- `[x]` **5. TDM/KOTH map far too small.** `clamp(mapRadius×0.50, 450, 650)`: 2.5–2.9× the area. Say if it is now too big. — *match flow*
- `[~]` **6. Died and never respawned.** IN TREE — `watchDeath` re-armed on every match body. Same fix and same proof as #4. — *bug review*
- `[ ]` **7. Potion drinking animation clips into your face.** No owner in the current seven tabs. — *unowned*
- `[x]` **8. Stamina bar takes longer to empty.** `SprintDrainPerSecond` 9 → 5.5; 11.1 s → 18.2 s of sprint. — *movement*
- `[x]` **9. Bat on top of the van.** Verified in render `run13/033_rearquarter_SahurVan.png` — raked on the rack, no longer flat. — *vehicles*
- `[~]` **10. TDM to 100 kills + small top HUD.** Server half verified (`GameModes.lua:194`); HUD in
  `ModeScoreHud.client.lua`. Render outstanding. — *HUD*
- `[ ]` **11. Arm joints look disconnected on long rifles in FPS.** — *guns*
- `[x]` **12. Buff the shotguns.** Verified in tree (Pump 13/7/110 … hip damage at 10 studs 32→69).
  **⚠ SUPERSEDED BY #64**, which asks for the opposite. Do not treat both as live. — *guns*
- `[ ]` **13. Third-person animations should match first-person.** — *guns*
- `[~]` **14. Brainrot ability HUD — position and a DPS/health readout.** Code verified
  (`CompanionAbilityIcon.lua:43`, `:167+`, called from `HudClient:3981`). Render outstanding. — *HUD*
- `[x]` **15. Infinite stamina in the lobby.** Already true both sides; the dead `LobbyDrains` key removed so nobody trusts it. — *movement*
- `[ ]` **16. Replace the old map cars with the drivable designs.** Roads tab: "not started here" —
  placement lives in MapGenerator. Pairs with #51 and #94. — *map*
- `[~]` **17. Previews of every accessory and cosmetic.** IN TREE, probe-proven — all 65 build a
  preview including the 18 `OfKind` hides; heaviest 103 parts. Contact sheets not re-run since the
  render pipeline was fixed. — *cosmetics*
- `[~]` **18. Improve the accessory designs before the previews.** IN TREE / **unproven** — detail
  floors raised (PizzaBackpack 6→10, CrownOfRot 22→25), ChefHat off Fabric. No Studio job since the change. — *cosmetics*
- `[x]` **19. Brainrot pass = 450 Robux.** `GamepassConfig.lua:83`, in the 03:23 build. — *shop*
- `[~]` **20. Polish the menu / redesign if needed.** IN TREE — three-version MenuShell, five-destination
  nav, viewport finally wired (the `short` and `tall` versions had never run in the game). The bigger
  restructure is #78. — *menu*

## #21–#40

- `[~]` **21. Redesign the crates and their animations.** IN TREE — shared `CrateOpen.lua`, per-tier
  feel. Card + film-strip gallery outstanding. — *crates*
- `[ ]` **22. Directional HUD cue for nearby bullet sounds.** — *HUD*
- `[x]` **23. Vaulting breaks through windows.** Proven: vaulting a pane breaks it, and with the call
  removed the test fails. Reinforced by the MovementService rewrite (see #119). — *destruction*
- `[~]` **24. Kill-animations tab in the shop.** Slot decided (top-level on large/short, inside STYLE on tall). Not built. — *menu*
- `[~]` **25. Zoom → Z, scroll wheel switches hotbar items.** Spec written, edit granted. No tab
  reported it in the current cycle — **confirm it is still owned.** — *movement / HUD*
- `[ ]` **26. Bending fingers on the hands, not blocking the crosshair.** — *guns*
- `[x]` **27. Enemies get a red aura, not through walls.** Verified in render: no wall = visible,
  behind wall = fully hidden, planted AlwaysOnTop fault glows through. Extended by #95. — *HUD*
- `[x]` **28. Treehouse obby branches not solid.** 11 real holes → 0, 36 exposed bits → 4.
  **⚠ DISAGREEMENT:** `coordination/handoffs/foliage.md` still lists #28 as an open item, "mine,
  untouched". One of the two is wrong — settle before it is re-fixed or wrongly closed. — *map / foliage*
- `[~]` **29. Explosions leave a giant floating black circle.** Ground case verified in render.
  **REOPENED by you:** the second-storey case (blast destroys the floor under it) is unmeasured — the
  scorch must land on the upper floor and go with the surface. Same cause as #70. — *destruction*
- `[ ]` **30. Make gun tracers more visible.** — *guns*
- `[~]` **31. Real parking lots for cars to spawn on.** The mechanism now exists — `MapTerrain.FlattenPad`
  landed and is probe-proven (20 pads, flatness 0.000 footprint, 3.6 ms/pad). Bays themselves not built. Converged with #32. — *roads + vehicles*
- `[~]` **32. Give the cities personalisation.** Phase 1 approved, 18 named characters over 7 layout kinds.
  **BLOCKED ON A HOOK:** `TownThemes` (4,857 lines) and `TownKinds` (485) have **no production caller at
  all** — confirmed independently by the contributors' census. The hook is the item. — *map*
- `[x]` **33. Bots sometimes don't drop their weapons.** Proven merged9 8/8 — in respawn modes
  `eliminate()` returned above `dropLoot`. Ruled: bots drop their held gun in respawn modes, players don't. — *bug review*
- `[~]` **34. Lag-switch SMG duplicated barrel.** SMG fixed (cocking tube banded at the front, sight
  line kept). All-guns floating-tube check written with self-test, **not yet run**. — *guns*
- `[~]` **35. Roof inaccessible on the legendary barricade.** Coded (hatch 3.8→5.8 with truss).
  `defense_roof` gallery shot. Opening/headroom measurement outstanding. — *destruction*
- `[x]` **36. A way to drop weapons and ammo from inventory.** Server half always existed; the DROP
  button (`InventoryPanel.lua:289-296`) was the missing discoverability. Server path proven 8/8. — *HUD*
- `[x]` **37. Stairs leading into walls.** Five maps clean on the 04:42 build: `wallHoles=0`, no
  blocked stair tops, self-test 0-as-built → 1-planted on every map. Log read by claude-43. — *map*
- `[x]` **38. Remove the out-of-stamina sound.** No longer played; the SoundConfig entry kept for a future breath cue. — *movement*
- `[~]` **39. Vehicles stuck in the ground.** Measured with the vehicle loop running: 0 buried, mean
  tyre gap −0.17. 1 of 13 hangs 1.48 studs where MapGenerator asks for that spot — fixed by the routed
  placement patch, ticks when that patch is in a build. — *vehicles*
- `[x]` **40. Nerf the AI aim.** `MatchConfig.lua:103-104` Near 0.66→0.55, Far 0.19→0.15; measured
  43/33/12% at 20/60/150 studs. **Hit rate stays here** — #75/#81 buy aggression through commitment, not lethality. — *bots*

## #41–#60

- `[~]` **41. Improve the arrest egg + rename "The Sweaty Incident".** Rename verified in the 03:23 build. Roof and arms still owed. — *easter eggs*
- `[ ]` **42. Revamp the other low-quality easter eggs.** — *easter eggs*
- `[~]` **43. All benches on sidewalks face the road.** Street benches were already correct — 720 cases,
  worst 0.000001°. **Waiting on you:** which bench did you see? — *map*
- `[ ]` **44. FPS animations should use your avatar.** — *guns*
- `[ ]` **45. Make the storm brainrot-themed.** — *storm*
- `[x]` **46. Bots just move in circles in the other modes.** Proven — hill contest/hold, 0 objectiveless
  bots; TDM rally to friendly centroid then push to last-seen. Root cause was #88 (no team). — *bots*
- `[x]` **47. Bots shoot through walls and barricades.** Proven — barricade shots; bots track structures
  they built and never fire on their own; only RotBarricade (250 hp) counts as shootable cover. — *bots*
- `[~]` **48. Improve the blood splat and add particles.** IN TREE and **photographed** — blast frames,
  scorch views and splats on body/head/shield all captured. Life hold 3.0 + fade 1.0; MAX_SPLATS 40→30. — *destruction*
- `[~]` **49. Improve the sound of the carts running.** Rebuilt — same cue as #83, one fix covers both. Needs your ears. — *audio*
- `[~]` **50. Car designs have random black poles.** Van drumsticks thickened; door seams at 0.02.
  **The Ranger is still reported** — see #61 and #116. — *vehicles*
- `[ ]` **51. Old road cars can't be destroyed.** Cause known (parts literally named "Part", damage looked
  up by name). Roads tab: not started. Pairs with #16 and #94. — *vehicles / map*
- `[x]` **52. Admin HUD for you only.** Probe 0 failures with both planted faults (wrong user gets
  nothing; wrong constant gives you nothing), nine forged payloads refused, every action logged. — *HUD*
- `[~]` **53. Vehicle low-health warning HUD.** There was no vehicle health at all — cars 300 hp, bikes 150, built and in the build. — *vehicles*
- `[~]` **54. KOTH HUD at the top.** In `ModeScoreHud.client.lua`; KOTH's score IS seconds held, so it
  reads as the leading score and the gap. Render outstanding. — *HUD*
- `[x]` **55. Improve the reloading sounds.** The 7 closing beats now carry a low layer; opening beats
  stay light; volumes untouched. **In the build — needs your ears.** — *audio*
- `[ ]` **56. Make the whole map destructible.** Big design job, not started. — *destruction*
- `[~]` **57. Roadkill with the cars.** Built — damage scales with speed, nothing below walking pace,
  never your own passengers. **IN THE BUILD BUT UNPROVEN.** You re-asked as #110, which means it is
  absent or silent for you — prove it fires before touching it. — *vehicles*
- `[~]` **58. Sticky bomb + translucent placement preview.** Coded end to end and probe-proven
  (kind "sticky", fuse 2.5 s, 110 over 12 studs, 45-part model, rides what it sticks to).
  **NEVER PHOTOGRAPHED** — all four sticky views were lost in the half-gallery. One clean re-run takes them. — *destruction*
- `[~]` **59. Splats cover your view on head hits.** Fixed for you only — the splat is drawn on your own
  head and in first person the camera is inside it. Spectators still see the full effect. — *destruction*
- `[~]` **60. Let me zoom out more in vehicles.** Both halves fixed — the combat camera was pinning your zoom back every frame while you drove. — *vehicles*

## #61–#80

- `[ ]` **61. The Ranger still has random poles sticking out.** Has now survived one "fix" — find out
  what that fix actually changed before writing another. See #50 and #116. — *vehicles*
- `[~]` **62. The sliding sound is an explosion.** Rebuilt as a skid, 1.16 s — it was a brick-crash bang
  pitched down through distortion, running 4.0 s against a 1.1 s slide. Needs your ears. — *audio*
- `[ ]` **63. The throwable preview stays around after the throw.** — *destruction*
- `[ ]` **64. Shotgun nerf: all pellets = 2-shot body, 1-shot head.** NOT STARTED. **This reverses #12** — *guns*
- `[~]` **65. Menu tabs don't fit inside the menu HUD.** IN TREE — 9 tabs needed 568 px in 539; the menu
  was also never told your screen size, so it always drew the desktop layout. Both fixed. — *menu*
- `[x]` **66. The X button on the menu is broken.** Fixed by construction, and **I verified this
  directly**: the X and the gear now read their handler at click time, and `Dismiss()` falls back to
  `Close()`, so a dead X can no longer be built whatever a caller forgets to pass. — *menu*
- `[ ]` **67. Move the companion to the character's left side.** — *companions*
- `[~]` **68. Free mouse when not holding anything.** Built; checked that no pickup needs a click, so a
  free cursor can't break looting. Interacts with #100 and #112 — prove which writer wins. — *HUD*
- `[ ]` **69. Sticky bomb remote detonator left in your hand.** — *destruction*
- `[~]` **70. Bombs leave a floating circle on a destructible floor.** Same cause as #29 and reopened with it. — *destruction*
- `[ ]` **71. A breaking animation per material instead of fading to clear.** — *destruction*
- `[ ]` **72. Random floating texts on some gun textures in FPS.** — *guns*
- `[~]` **73. Improve the rivers and their banks/valleys.** **MEASURED, NOT DESIGNED.** 579 cross-sections:
  width 34/30 wetted constant, depth 4.3, and the finding that matters — **the typical riverbank (60–66°)
  is steeper than a player can climb out of** (escapable at ≤50°; swim 12.3 studs/s). Ruled banks first,
  width second. Design note is the next step. — *roads*
- `[~]` **74. Still spawning in the lobby during other modes.** This is what reopened #4/#6. — *bug review*
- `[~]` **75. Make the bots more aggressive.** Ruled: aggression = commitment, not lethality. Baseline
  measured (first shot 0.83 s front / 2.09 s behind; rifle duels 3.1–4.9 s). A/B dial script **BUILT, NOT RUN**. — *bots*
- `[ ]` **76. Compounding playtime awards.** — *progression*
- `[ ]` **77. Daily streak awards.** — *progression*
- `[ ]` **78. Revamp the menu: separate progression, shop and catalogue menus, previews everywhere.**
  The big one. #20 is the polish; this is the restructure. — *menu*
- `[ ]` **79. Leaning in FPS; on mobile only when scoped.** — *movement*
- `[~]` **80. Fix HUD overlap everywhere, diligently.** The play-through sweep landed a long row of fixes.
  **Still live:** on an upright phone the compass, bounty line and speed pill set `Visible = true` every
  frame and reappear at desktop positions over the portrait layout. See also #86. — *HUD*

## #81–#94

- `[~]` **81. Increase bot reaction speed and aggressiveness.** With #75 — reaction speed is the one dial
  you named. A/B built, not run. — *bots*
- `[x]` **82. Sprinting in the lobby keeps cancelling.** The lobby sent match state once a second and the
  client read every repeat as "you left the match", cancelling sprint and aim. Fixed — hold shift in the lobby and say. — *movement*
- `[~]` **83. The car sound is messed up.** Rebuilt — the engine loop was a brick-crash sample through
  distortion, i.e. a car repeatedly hitting something, at every speed. Needs your ears. — *audio*
- `[ ]` **84. Cars get bumpy and glitchy at speed.** Same as #109. — *vehicles*
- `[ ]` **85. Chests and supply drops should drop contents on the ground, not into inventory.** — *loot*
- `[~]` **86. Bug-fixer pass over the HUD and menus for fit and crowding.** **DONE AS A REVIEW, NOT AS
  FIXES:** the player's-eye review produced 142 claims → 89 survived adversarial refutation → 82 unique
  sites (2 blocks-play, 46 confuses, 34 minor), in `coordination/handoffs/bug-review-player-eye.md`.
  **None of it is assigned or landed.** This is the largest single block of ready work in the project. — *unrouted*
- `[ ]` **87. Make the grenade launcher launch grenades further.** — *guns*
- `[x]` **88. Bots never get assigned a team in TDM/KOTH.** Root cause of #46 and #125. `ModeTeams` now
  writes the `Team` attribute for players and bots alike (`:318/:620/:636/:712`). — *bots*
- `[~]` **89. Can't see animations on other players, like sliding.** First cause was wrong and is
  retracted: the slide IS published (`MatchService:858`) and you hearing it proves it arrives — so the
  state arrives and the POSE doesn't draw on someone else's body. **SPRINT is genuinely never published
  at all** — that half is real and separate. — *movement*
- `[ ]` **90. Minimize button on the controls.** Collapsed state to be remembered between rounds; starts collapsed on phones. — *HUD*
- `[ ]` **91. Legendary brainrot "tom pearl".** **Concept comes to you before it is built.** Also checks
  the crate odds and the hard-coded "126 brainrots" in the menu. — *brainrot*
- `[ ]` **92. The hands gripping the guns need improvement.** Rides in the hands/sights render — measuring
  whether the palm meets the grip on every gun, and whether one pose is reused for every weapon shape. — *guns*
- `[ ]` **93. Improve the King of the Hill objective circle.** To be built as a module the render and the
  game share, so the picture you approve is the code that ships. — *match flow*
- `[ ]` **94. Improve the cars that can't be driven and spawn on the road.** Any roadside car that stays
  decoration gets built from the real vehicle model, anchored — and destructible for free. Pairs with #16/#51. — *vehicles*

---

# LIST 2 — #95 to #135

Source: `C:\Users\oliver\Downloads\make it easier to see whos an enemy.txt` (#95–#132) and your 06:1x
message (#133), and your 2026-09-22 13:36 message (#134–#135).

- `[~]` **95. Easier to see who's an enemy, including bots.** IN TREE — `EnemyAura` rewritten: enemies
  filled red, teammates outlined, nameplates tinted to match. **The bug inside the old #27 was that it
  iterated `Players:GetPlayers()` and bots are not Players, so no bot was ever marked.** Now keyed off the
  server's `Team` attribute. **UNPROVEN: whether the friendly outline reads clearly without a fill.** — *HUD*
- `[ ]` **96. More loot boxes on the team gamemodes.** — *map*
- `[~]` **97. The hit registration feels bad.** **The highest-value item on either list.** Measured, not
  guessed: the client quantises fire rate down to the frame rate and the server drops shots inside a 10%
  tolerance with no tracer, no flash and no ammo spent. **Fixing one alone makes it worse** — they land
  together or not at all. Design, the cap, the server-clock rule and the cover trade you must choose are
  in `HITREG_DESIGN.md`. Rewind deliberately unbuilt. — *guns*
- `[x]` **98. Many TDM bots just stand in one spot.** `nextSlot` for replacement bots + S25. — *bots*
- `[~]` **99. Bot and player movement is clippy, like low fps.** — *bots + perf*
- `[~]` **100. Mouse doesn't unlock when vote menus pull up.** Read as **our own cursor regression**, not a
  new bug. Ready-up loop landed: an unready player's vote no longer takes the cursor or the overlay. — *pre-match UI*
- `[~]` **101. Improve the winning screens of each gamemode.** — *pre-match UI*
- `[~]` **102. Spectator mode glitchy, can't swap, no way to leave.** IN TREE, proven 15/15 —
  `InMatch` written true/false for every Player, leave key L, `[E]` next / `[L]` leave labelled. **The
  focus gate is now closed against a modified client** (`MatchService.FocusTarget`), which is the least
  visible and most important part. — *bug review*
- `[ ]` **103. People can jump off the edge in the lobby.** — *map*
- `[~]` **104. The TDM HUD at the top stays after the game.** IN TREE — five elements plus the TDM/KOTH
  scoreline hidden when in-progress and not in the match; a mid-game joiner renders the live score. — *HUD*
- `[ ]` **105. Make the drop menu higher res.** — *pre-match UI*
- `[x]` **106. Can't pick weapons up, especially after a lobby trial gun.** Range-stop guard in `verify.py`;
  found from the contributors' ignored-return-value rule within twenty minutes of merging it. — *guns*
- `[ ]` **107. The game-choosing menu pulls up randomly mid-match.** — *pre-match UI*
- `[x]` **108. The storm kills you in the lobby.** 20/20 probe. — *storm*
- `[ ]` **109. Cars are glitchy and bounce around.** Same as #84. — *vehicles*
- `[~]` **110. Add roadkill for the cars.** Already landed once as #57 and unproven. You asking again means
  it is absent or silent — **prove it fires before touching it.** — *vehicles*
- `[ ]` **111. Increase time-to-kill a bit.** — *guns*
- `[~]` **112. I can still see my cursor in FPS.** Same cursor family as #100 and #68. — *HUD*
- `[~]` **113. The bots are pretty laggy.** Cap now 15 (your figure), bots 30. Worst tick measured
  32.4 ms at cap 15 on one run; **a second run read 42.6 ms and that is deliberately unresolved.** — *bots*
- `[ ]` **114. Popup barricade in the team-mode kit; two objectives on KOTH.** — *destruction (a) / match flow (b)*
- `[x]` **115. Make it easier to vault through windows.** `Parkour.lua` sets `MaxParts` per query instead
  of a flat 1 — with the flat cap, a box straddling a pane and the pier beside it reported CLEAR whenever
  Roblox returned the pane first, and the client CFramed you through the pier. — *destruction*
- `[ ]` **116. Bat parts still sideways on the Sahur RV and the Ranger.** The `Enum.PartType.Cylinder`
  X-axis lesson. Has survived one fix — see #50/#61. — *vehicles*
- `[ ]` **117. Lobby trial guns change every pickup.** — *guns*
- `[x]` **118. Nerf the bots' aim slightly.** Measured 43/33/12% at 20/60/150 studs (was 58/43/19). — *bots*
- `[x]` **119. Glass still doesn't break jumping through windows.** **Struck as already fixed** by the
  MovementService rewrite: no root-height ray left, `panesAhead` sweeps feet+1.6…feet+8.2 onto the wall,
  and `MovementService.LastGlass = {found, broken, at}` plus a warn-once say why on a miss. — *destruction*
- `[ ]` **120. Sound design more accurate to real life.** — *audio*
- `[ ]` **121. Bigger maps on every gamemode.** ⚠ Constrained: Sahur Springs already measures 32,969 parts
  against ~31,600 affordable. Read with #32 and the foliage ceiling. — *map*
- `[ ]` **122. Weapons with explosive ammo must actually explode what you shoot.** **Parked until you say
  what you mean by it.** Note for whoever picks it up: `CombatService.fireAbility`'s explosive branch has
  no production caller, so the first hitscan explosive added would silently get a cruder blast. — *destruction*
- `[ ]` **123. Sort the guns by tier in the admin menu.** — *menu*
- `[x]` **124. No kit drops in kit modes; picked-up items still drop, players and bots.** Landed in the
  match-flow set, proven 11/11 with semantic controls failing. — *bug review*
- `[~]` **125. Team bots walk in unison.** `nextSlot` fixed the shared-slot cause. The held idle-wander
  work re-hit it and was written with **two** constants (slot × 2.399963 + leg × 1.0) so equal slot+leg
  can't align again. — *bots*
- `[ ]` **126. Too many bots in one area = lag.** Cap A/B partially done; see #113 and #131. — *bots*
- `[x]` **127. Reduce the bot count to 30.** `MatchConfig.BotFillTarget` 50 → 30. **Changed 09-22 13:45 on your word:**
  "50 players in the battle royale rounds and keep 30 in the other gamemodes" — the battle royale now fills to
  `BotFillTargetBattleRoyale` = 50, TDM and KOTH stay at `BotFillTarget` = 30. — *bots*
- `[~]` **128. Place barricades anywhere.** **A + B LANDED UNPROVEN and both are in the build you are
  playing.** A: a kit stops on first contact with anything solid (kills the 5.6/11.9-stud roll). B:
  per-footprint slope allowance, proven exactly over five runs. **B governs on terrain only** — expect
  "still refuses on that sloped roof" and don't read it as B failing. C (water / no ground / no room)
  agreed not to relax. **D — aim a ghost and click to place — is yours to call, after you play A and B.** — *destruction*
- `[x]` **129. Codex→brainrots back button visually broken.** Sized to its own label with `AutomaticSize.X`
  instead of a fixed 70 px that "BACK TO MY BRAINROTS" overflowed. Before/after shot not taken. — *menu*
- `[?]` **130. Fix the sorting in the codex.** **HELD FOR YOU — it is not mis-sorted, it is UNSORTED**
  (grouped by rarity, then source-file declaration order). Your choice: **A–Z within rarity** (positions
  stay put as you collect) or **owned-first** (shows progress, every row moves). — *menu*
- `[ ]` **131. Fix as much lag as possible.** Cap + #127 landed against it; everyone's worst tick. — *all*
- `[?]` **132. Vaulting still hard, glass doesn't always break.** **Nothing left to build** — it is #115
  plus the MovementService rewrite, both in your build. **Your verdict decides.** On a miss,
  `MovementService.LastGlass` and the warn-once say why. — *destruction*
- `[~]` **133. Bots need an idle wander when the bot count doesn't let them move.** **HELD, NOT LANDED —
  and it failed the coordinator's bar on the bots tab's own numbers**: stationary share went 4.7% → 6.5%,
  the wrong direction, on a confounded metric. At cap 15 the frozen state is ~0.1% of bot-samples, so your
  own cap choice already removed most of it. Do not re-propose without the built-and-unrun S26 run. — *bots*
- `[ ]` **134. Bots just stand around in clumps in TDM and don't fight.** Reported by Oliver on 09-22 13:36. Not yet
  diagnosed. Related, not the same: #125 (team bots in unison) and #133 (idle
  wander) are about movement; this one is about bots not engaging enemies at all in Team Deathmatch. — *bots*
- `[ ]` **135. Moving into a new area pops up two HUD notifications for it instead of one.** Reported by Oliver
  on 09-22 13:36. Not yet diagnosed; find which client scripts show the area notice and why it fires twice. — *HUD*

---

# A1–A6 — the six items you typed to claude-43

These were numbered 59–64 in the old ledger, which collided with real List 1 items. **Their old
numbers are kept here so COORDINATION.md and the handoffs stay readable. Give them real numbers
whenever you like — #134+ is free.**

- `[x]` **A1 (was "#59"). Dummies ragdoll when they die.** Proven 47/47 in Run mode — corpse moves
  (fastest part 43 studs/s), at rest after 0.9 s, cleared at 4.53 s, fresh body back at 5.05 s tagged and
  full; a CanCollide-off planted corpse fell 233 studs and was caught. — *bug review*
- `[?]` **A2 (was "#60"). Cosmetic crates tab.** Designed and priced (STYLE 8k / DELUXE 25k / PRESTIGE
  60k, all 65 cosmetics per tier, refunds 35/40/45%). **Odds proven 88/88** against the percentages parsed
  off the card's own printed line — and the cards *understate* what you get at the guarantee line.
  **HELD until you update the developer products in the Creator Dashboard.** — *crates*
- `[~]` **A3 (was "#61"). Exhaust pipe end is see-through.** Root cause found and fixed — the exhausts
  did not join up on all four vehicles; every exit now has a dark bore set back inside. Open-end audit
  passes with its planted fault. **Render `048` came back as empty sky** — re-frame from the exhaust pivot
  with a content assertion. — *vehicles*
- `[~]` **A4 (was "#62"). Merge dialog can't be confirmed on a phone.** Card was 436 tall on a 390 screen
  with both buttons ~26 px past the edge. Code landed via `PhoneLayout.PanelScale` — **not** FitPanel,
  and the comment says why that obvious fix was wrong. Phone-reach render outstanding. — *menu*
- `[~]` **A5 (was "#63"). Brainrot abilities: improve designs and effects.** Audit found 126 brainrots
  sharing **six identical effects and one attack sound**, 4 of 6 moves doing nothing with no target, and
  **a 0-HP companion able to fight all match**. Tier A coded (announce-last, per-victim LOS, Shockwave
  range by rarity). **Probe queued and never run; no tab in the current seven owns it.** — *unowned*
- `[~]` **A6 (was "#64"). Blood splats coloured by the rarity of the gun that hit.** Coded and probe-proven
  — rank decided server-side from the weapon id, client maps to `Rarity.Color`, hazards and shield hits stay
  plain. **NEVER PHOTOGRAPHED:** the `splat_rarities` frame is this item's entire subject and was lost in the
  half-gallery. One clean re-run takes it with #58. — *destruction*

---

# Needs a number from Oliver

`coordination/handoffs/hud-menu.md` claims these as "#33" and "#25". Both numbers already belong to
other items (#33 bots dropping weapons, #25 zoom hotkey), so these two are recorded here unnumbered
rather than guessed at.

- `[x]` **The stuck free cursor.** The inventory now takes a real `MenuOpenClaims.Claim("Inventory")`
  instead of reading the attribute to decide whether to write it. Related to #100/#112/#68 — it may
  belong to one of them rather than needing a new number. — *HUD*
- `[x]` **The team results card.** **Two bugs, not one:** the crash on a nil crate, and `Rarity.Color(nil)`
  answering `Common`, which would have left every team card grey forever if only the crash were guarded.
  Possibly belongs to #101. — *HUD*

---

# Open decisions that are yours, collected

Everything below is built as far as it can go and is waiting on you, not on a tab.

1. **#130** — codex sorting: A–Z within rarity, or owned-first?
2. **#128 D** — after playing A and B, do you still want "anywhere" (aim a ghost and click)?
3. **#132** — your verdict on vaulting and glass; there is nothing left to build.
4. **A2** — the developer products in the Creator Dashboard, before the cosmetic crates tab can ship.
5. **#122** — what "explosive ammo" means to you.
6. **#43** — which bench you saw facing the wrong way.
7. **#91** — the "tom pearl" concept comes to you before it is built.
8. **#5** — is the team arena now *too* big?
9. **#49, #55, #62, #83** — four audio rebuilds that need your ears in a playtest.
10. **Does the `guard` toast read as disconnected from a modal?** A merge confirm now says "Couldn't
    merge that." while the specific reason appears at the screen edge. If it reads wrong, the fix is a
    caller-declared form.

# The three biggest blocks of ready work nobody owns

1. **#86 / the player's-eye review** — 82 verified sites including 2 that block play, fully written up,
   entirely unassigned.
2. **A5 / brainrot abilities** — Tier A coded, probe never run, no owner in the current seven tabs.
3. **The nine unrouted logic-review survivors** — in `coordination/handoffs/survivors-triage.md`.
   Two are already dead; **#14 of that set is live and unowned and loses nothing but fairness**: ready up,
   vote, un-ready, and your vote still decides the mode and map for everyone actually playing.
