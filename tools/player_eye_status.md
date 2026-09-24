# Player's-eye review (#86): status of every site

Source: `coordination/handoffs/bug-review-player-eye.md` (82 sites: 2 blocks-play, 46 confuses, 34 minor).
Checked against the tree at `59ebfe1` plus this branch's commits (deb7f4a, 81a2e0c, 38d3975, de7ffd1, 369cb8e).
Line numbers are the CURRENT tree's, not the review's.

Status key: **fixed-now** (this branch) · **already-fixed** (in the tree before this branch) · **still-open** · **needs-Studio** (a layout/render call; a number would not settle it).
Sites in files other workers own right now (HudClient, PhoneLayout, MatchConfig, …) carry the exact edit as BEFORE → AFTER instead of a change.

Logic check: `python tools/player_eye_check.py .` (8 checks on the real modules and sources) and `--plant` (8 planted faults, all caught). Layout: `python tools/hud_layout_check.py .` check 7 and `--plant` (16 plants, all caught).

Totals: fixed-now 53 · already-fixed 22 · still-open 0 · needs-Studio 7 = 82 (a row with two halves counts under its first status).

## Blocks play (2)

| # | Site | Status | Evidence |
|---|---|---|---|
| B1 | MenuClient:3408 controller cannot open menu / quests / cycle / spectate | already-fixed + fixed-now | Menu on ButtonSelect `MenuClient.client.lua:3701`; Quests on DPadLeft `:3897`; NextSlot on ButtonR1 `CombatClient.client.lua:1153`; the "MENU [M]" pill is now "SHOP" `MenuClient.client.lua:3704`; ControlsHint.client.lua is gone (#90, 4918382). **Fixed now:** SpectateNext on ButtonR1 `CombatClient.client.lua:573`, SpectateLeave on ButtonB `:592`, line worded per input `:450`. |
| B2 | VoteScreen:549 unready player's two ways to ready up both dead | already-fixed | `VoteCursor.lua:52` `wantsCursor = open == true and ready ~= false`: an unready player's vote draws but takes neither the cursor (no MenuOpen claim, so HudClient `:238` keeps the Ready key) nor the Modal overlay; hint names the ways `VoteScreen.lua:578`. Now held by `player_eye_check.py` "vote" (12 combinations; plant = ignore readiness, caught). |

## Confuses (46)

| # | Site | Status | Evidence / proposed edit |
|---|---|---|---|
| C1 | HudClient:83 onboarding sub-line overflows banner | already-fixed | `HudClient.client.lua:90` TextScaled + UITextSizeConstraint(Max 14). |
| C2 | HudClient:1304 hotbar cell text 6-8 px on phones | needs-Studio | Font sizes under the phone UIScale need a render. Proposal `HudClient.client.lua:1315`: `TextSize = 10,` → `TextScaled = true,` plus child `UITextSizeConstraint { MinTextSize = 12, MaxTextSize = 14 }`; hide `refs.key` when `phone` in setHotbarShape (`:2993`). |
| C3 | HudClient:2671 toast overflows / 2.6 s | fixed-now | `HudClient.client.lua:2896` TextWrapped + AutomaticSize Y; `:2921` shown for `math.max(2.6, 1.5 + 0.05 * #message)` s. (HUD follow-up commit.) |
| C4 | ModeScoreHud:178 which score is mine | already-fixed | `ModeScoreHud.client.lua:249` "YOUR TEAM · EMBER" / "ENEMY · TEAL" tags, friend/enemy colours. |
| C5 | PhoneLayout:241 storm line 8 px on phones | needs-Studio | `PhoneLayout.lua:240-241` (owned elsewhere). Proposal: HudClient phone PIECES entry for the storm line with a shorter string ("Zone 2/5 · 45s · 8/s") at natural width 250; needs a phone render. |
| C6 | CombatService:25 storm finish credited to last shooter | fixed-now | `StormService.lua:25` OnDamage hook (stormHit replaces both TakeDamage sites); `Bootstrap.server.lua:77` wires it to `CombatService.RecordEnvironmentDamage` `CombatService.lua:858`; a storm finish drops the "ELIMINATED BY" headline `:904` and sends `finishedBy`. Self-kill half was already fixed (`killerToken ~= victimToken`). Kill credit unchanged. **HudClient** `:3644` now titles a storm finish "THE STORM GOT YOU" (`info.finishedBy == "Storm"`), fixed in the HUD follow-up. |
| C7 | Combatants:44 usernames, not display names | fixed-now | `Combatants.lua` GetName returns `token.DisplayName` (shown); "is it me?" goes by UserId, sent beside it (`Combatants.GetUserId`): kill feed `killerUserId` (MatchService, GameMode), bounty `userId` (MatchService). HudClient compares `player.UserId` for the kill-feed highlight and the bounty "YOU" toast, so a namesake never gets yours. Held by `hud_layout_check.py` check 5 (plant = compare by name, caught). |
| C8 | LootService:88 floor-gun prompt shares X with Reload | fixed-now | `LootService.lua:100` ButtonB (also chests); `SupplyDropService.lua:210`, `VendorService.lua:162`; lantern off ButtonY `LobbyService.lua:3316`. VehicleService prompts not touched (owned elsewhere): same one line `prompt.GamepadKeyCode = Enum.KeyCode.ButtonB` wherever it builds a ProximityPrompt. |
| C9 | CombatClient:486 phone spectator has no NEXT | fixed-now | NEXT / LEAVE TextButtons on touch `CombatClient.client.lua:548`; line says "tap NEXT or LEAVE" `:450`. |
| C10 | HudClient:1505 "0 / 0" in white | already-fixed | `HudClient.client.lua:1519` "NO AMMO" in red; empty mag names the reload key. |
| C11 | HudClient:2726 bounty warning misses display names | already-fixed | `HudClient.client.lua:2877` compares `player.Name` (what the server sends). |
| C12 | HudClient:2842 phone never sees reserve | fixed-now | `HudClient.client.lua:1437` phone cells read "mag/reserve" (`PhoneShape` attribute set by setHotbarShape, which redraws); "NO AMMO" in red at `:1436` when both are 0. Cell width at phone scale wants a render. |
| C13 | LobbyService:3220 Start-over on the Ready key | fixed-now | `LobbyService.lua:3316` KeyboardKeyCode H, GamepadKeyCode ButtonB. |
| C14 | ItemData:198 item descriptions never shown | fixed-now | Desktop hotbar: `HudClient.client.lua:1223` ItemDetail, two lines of 12 pt in the left of the ammo row (empty while an item is held; the slots start 6 px under the item line, so there is no row below it), text from `InventoryPanel.Describe` `InventoryPanel.lua:97`, set in renderWeapon `HudClient.client.lua:1610`, hidden on the phone plate (setHotbarShape). Bag: card detail over the icon and ammo chip on hover, tap-select or pad selection `InventoryPanel.lua:629`, `:880`. Held by `hud_layout_check.py` check 7 (text, desktop-only, clear of the ammo, every item fits two lines, card detail inside the card above its name; plants caught). Readability of the scaled card text wants a render. |
| C15 | MovementService:274 Blink Bean dead click | fixed-now | `MovementService.lua:277` returns a reason; threaded `WeaponService.lua:1894` (applyItem) and `:1955` (StartUse) to Bootstrap's existing toast; description `ItemData.lua:112`. |
| C16 | WeaponService:1809 "only heals up to 75" at 113 HP | fixed-now | `WeaponService.lua:1869` quotes `math.floor(healCap(...))`; `ItemData.lua:29` "up to 75% of your max health". |
| C17 | HudClient:983 no boots pill / no countdown | already-fixed (soda) · fixed-now (boots) | Soda countdown as before; the same pill now also counts Bounce Boots down off `BounceBootsUntil` (`HudClient.client.lua:4005` effects list), text scaled into the pill. Held by `hud_layout_check.py` check 6 (plant = boots dropped, caught). |
| C18 | MovementClient:959 which item X uses | fixed-now | `Settings.lua:26` label; `HudClient.client.lua:1403` the first movement item's cell key reads "3 · X" on a keyboard (same test as MovementClient.firstMovementSlot). |
| C19 | ProjectileClient:679 phone cannot cook | needs-Studio | `ProjectileClient.client.lua:657` startCook exists; routing BRR_Fire's Begin/End on touch into startCook/throw is an input-flow change that needs a device. |
| C20 | MatchService:1571 drop toast says hold W | fixed-now | `MatchService.lua:1734` "Dropping in over your spot — hold nothing to land there, or steer with WASD" when a spot was picked. |
| C21 | EventBanner:367 event card hidden under the vote reveal | fixed-now | `EventBanner.lua:46` HoldFor, `:847` Announce defers inside the hold; `VoteDropClient.client.lua:206` holds for REVEAL_SECONDS. Untested on screen (render). |
| C22 | HudClient:1823 "Zone" jargon, "Storm moves in 0s" when Final | fixed-now | `HudClient.client.lua:1910` "Final circle • outside: N dmg/s"; otherwise "Circle %d of %d • outside: %d dmg/s". |
| C23 | HudClient:1824 static arena shows BR storm line | already-fixed | `HudClient.client.lua:1867` `if storm.label then stormLabel.Text = "" return end`. |
| C24 | CrateData:272 "Unco / Lege", "+ 6% accessory" | fixed-now (names) · already-fixed (suffix) | Full names `CrateData.lua:274`; suffix "up to N% an accessory instead" `:281`. Check "odds" (152 parts; plant = sub(1,4), caught). |
| C25 | GamepassConfig:127 Pro Bundle worth overstated | already-fixed | `GamepassConfig.lua:133` "Worth 3,200+ R$ • 4x value", counted at shop prices. |
| C26 | GamepassConfig:222 Legendary "best odds you can buy with coins" | fixed-now | `GamepassConfig.lua:231`. The duplicate `order = 14` with CrateMythic is left (cosmetic). |
| C27 | MenuClient:307 menu replies thrown away | already-fixed | `Bootstrap.server.lua:776` guard toasts every returned message. |
| C28 | MenuClient:816 SELL ALL sells the whole rarity | already-fixed | Confirm dialog `MenuClient.client.lua:866`. Label kept "SELL ALL" on purpose until a render (comment above it). |
| C29 | MenuClient:1340 Style crates on Crates tab "You own 0 / 0" | fixed-now | `MenuClient.client.lua:1337` skips `category == "Cosmetic"` (they have the Style tab). |
| C30 | MenuClient:1616 pass reward "Cosmetic" | fixed-now | `MenuClient.client.lua:1732` names the next unowned pool item (same walk as grantCosmetic) or the 1,000-coin fallback. Every unclaimed cosmetic tier names the same next item. |
| C31 | MenuClient:1705 Daily Spin from menu silent | already-fixed (toast) · fixed-now (index) | Toast via guard `Bootstrap.server.lua:776`; menu spin now goes through `LobbyService.OnDailySpin` (RecordIndex) `:990`. |
| C32 | CombatService:353 vetoed hit silent; protection never broken by attacking | fixed-now | Grey "+" tick on veto `CombatService.lua:409` (kind "structure"); landing a hit ends your own protection `ModeTeams.lua:427`. Fixed now too: the effects pill says "PROTECTED" while `SpawnProtected` is on (`HudClient.client.lua:4005`). |
| C33 | HudClient:1823 (modes) "Storm moves in 0s" over the scoreline | already-fixed | Same as C23 (`:1867`), the line is empty in team modes. |
| C34 | HudClient:2441 nothing points at the hill | fixed-now | `HudClient.client.lua:2677` compass markers "A" / "B" from `workspace.Hill.Objective<letter>` HillX/HillZ (ModeKingOfTheHill.buildObjective); hidden when the hill is gone. Owner colours not shown (one accent colour). |
| C35 | HudClient:3510 "+0 / +0" and "#2" in team modes | already-fixed | `ResultsScreen.client.lua:325` VICTORY / DEFEAT / DRAW; the old "+0" result is gone (header comment `:4`). |
| C36 | HudClient:3587 "50 ALIVE" in respawn modes | already-fixed (players) · fixed-now (late joiner) | `HudClient.client.lua:3893` a respawn mode's banner names the mode (GameModes.Get(mode).name) instead of a living count. |
| C37 | ModeScoreHud:187 "level", hill status invisible | fixed-now | "TIED" as before; per-objective line "A YOU  B OPEN" in each side's colour, centred in the tags row `ModeScoreHud.client.lua:137`, parsed from the server's `hillStatus` ("A Ember Squad · B open", ModeKingOfTheHill.Tick) `:328`; tags narrowed and use the short team name. Contested is not shown: the status string does not carry it (proposed edit in the report). Check 7 (from both sides, clear of the tags, on screen at 7 sizes; plant = ignores my side, caught). |
| C38 | ModeScoreHud:200 TDM has no clock | fixed-now | `ModeScoreHud.client.lua:278` "FIRST TO 100\n7:42", red in the last 30 s. |
| C39 | ArsenalExpansion:14 gun names carry no type | fixed-now | `style` in the slot payload `WeaponService.lua:181`; type word from style (`InventoryPanel.lua:72` GunTypeWord, copy in `LootService.lua:122`), left off when the name says it ("Rot SMG"). Floor label + prompt `LootService.lua:310`; HUD line `HudClient.client.lua:1667` ("UNCOMMON  Scrolla Scrolla Brrrap · SMG"); bag detail. `player_eye_check.py` "gunword" (62 guns, both files' functions agree; plant = a word missing, caught). The longer floor label shrinks its TextScaled text: floor_label_gallery render. |
| C40 | WeaponData:18 range never shown, out-of-range silent | fixed-now | `CombatClient.client.lua:687` beyondRange, 10 Hz, head to aim point vs `range` (not the sky, not launchers) raises AimBeyondRange; crosshair ticks grey and fade `HudClient.client.lua:367`. Range in the bag detail "reach 180 studs" `InventoryPanel.lua:124`. `player_eye_check.py` "range" (plant = sky marks, caught); check 7 crosshair + reach (plants caught). In-game feel needs a play. |
| C41 | LobbyService:2134 dummies read as pet-only | fixed-now | `LobbyService.lua:2138` "TARGET PRACTICE"; podium `:2214` "take it and shoot the targets". |
| C42 | LobbyService:2204 "chest loot only" points at chests | fixed-now (partly) | `LobbyService.lua:2214` no longer says chests; it says take-and-try (C41's ask) rather than "supply drops": one 0.9-stud line cannot carry both. |
| C43 | LootService:273 ammo restock invisible | fixed-now | Floor gun `LootService.lua:312`, chest `:531` "+ammo for your guns". Duplicate-gun "Take Ammo" prompt not done (changes pickup rules). |
| C44 | VendorService:104 refill charged for nothing | already-fixed · fixed-now (wording) | Charge only after GiveAmmo succeeds (`VendorService.lua:113`); GiveAmmo is false when nothing was added (`WeaponService.lua:1753`). Now says "already full" `:107`; prompt "(+60% every gun)" `:160`. |
| C45 | HudClient:1508 ability shown as raw id | fixed-now | `HudClient.client.lua:1564` words for all five ids in the arsenal (pierce, chain, lifesteal, explosive, goldRush); unknown ids fall back to the id. |
| C46 | InventoryPanel:605 no gun stats | needs-Studio | `InventoryPanel.lua:605` sub line is one 16 px row already full ("LEGENDARY • 240 reserve"); a stats strip needs a card re-layout and a render. |

## Minor (34)

| # | Site | Status | Evidence / proposed edit |
|---|---|---|---|
| M1 | ControlsHint:98 12 px grey legend | already-fixed | ControlsHint.client.lua removed (#90, commit 4918382). |
| M2 | HudClient:207 "[F] join next match" on phones | fixed-now | `HudClient.client.lua:229` touch or pad: "tap to join next match" / "tap to stay in lobby", no key. |
| M3 | HudClient:885 tips hard-code F, M, T, 1-8, Q | fixed-now | `HudClient.client.lua:916-922` {Ready}, {Slot1}/{Slot8}/{NextSlot}, {ToggleCamera}, filled from this player's bindings by the existing filler. |
| M4 | HudClient:1372 rarity colour-only | already-fixed (floor) · fixed-now (hotbar) | Floor label/prompt carry the word. Hotbar: tier letter (C U R E L M S) in each filled cell's bottom-right corner, in the tier colour `HudClient.client.lua:1375`, `:1471`; item name stops 14 px short of it. Check 7 (letters, clear of the name; plant caught). 10 pt at phone scale wants a render (as C2). |
| M5 | HudClient:1493 "click to use" on a pad | fixed-now | `HudClient.client.lua:1556-1562` "RT to use" on a pad, "tap FIRE to use" on touch, "click to use" otherwise. |
| M6 | HudClient:2224 minimap names 9 px, towns vs landmarks by colour | needs-Studio | `HudClient.client.lua:2273`, `:2438` TextSize 9; diamond markers need a render. |
| M7 | MenuClient:646 filter chips 28 px | needs-Studio | `MenuClient.client.lua:658`; growing to 44 px wraps the row, needs a render. |
| M8 | HudClient:2653 kill feed row runs off screen | fixed-now | `HudClient.client.lua:2843` TextTruncate AtEnd, right-aligned, placement first. |
| M9 | LobbyService:554 welcome arch faces the plaza | fixed-now | `LobbyService.lua:559` greeting on Back (+Z), the face seen from the spawn at z 110 (`SpawnOffset :101`). |
| M10 | LobbyService:2135 [G] with no companion does nothing | fixed-now | `Bootstrap.server.lua:664` throttled "No companion yet" toast when UseAbility fails and no companion is equipped. |
| M11 | LobbyService:3168 sprint key never named | fixed-now | `LobbyService.lua:3265` KeyHint "Hold [{Sprint}] for the long leaps"; the ControlsHint half is moot (removed). |
| M12 | HudClient:890 "Stay inside the storm" | fixed-now | `HudClient.client.lua:921` "Stay inside the zone — the purple storm wall hurts. …". |
| M13 | ItemData:149 three-structure cap unstated | fixed-now | `capRule` appended wherever the description is shown (`InventoryPanel.Describe` `InventoryPanel.lua:107`: HUD item line and bag card). Check 7 (plant = rule dropped, caught). The menu shows no item descriptions, so nothing to add there. |
| M14 | ProjectileService:587 driver's throw refused silently | fixed-now | `HudClient.client.lua:1558` a held item in a VehicleSeat reads "hands on the wheel". |
| M15 | SupplyDropService:251 supplies never announced | fixed-now | Spilled on the ground since #85; toast names every piece `SupplyDropService.lua:268`. |
| M16 | HudClient:1492 first click after a swap eaten | fixed-now | `HudClient.client.lua:1549` a held item shows "RAISING" while `equipReadyIn` runs, as guns do. |
| M17 | MatchEvents:77 "half again as fast"; Shield Up "drops in" | fixed-now | `MatchEvents.lua:81` composed from the speed ("50% faster"); `:53` "Everyone starts with 50 shield." Check "events" (plant = field 1.75, caught). |
| M18 | MatchService:1739 countdown 15 → 7 | fixed-now | `MatchService.lua:1910` an all-ready lobby enters Countdown at AllReadyCountdown. VoteScreen's bar total is still LobbyCountdown (VoteDropClient passes it): bar starts part-empty rather than snapping. |
| M19 | StormService:269 storm damage silent | already-fixed (enter/leave) · fixed-now (tick) | `StormClient.client.lua:173` stormTickDue: on the 0.4 s poll, health lost while outside plays StormEnter at 0.3 gain, pitch 1.25, at most every 0.8 s `:226`. `player_eye_check.py` "stormtick" (plant = inside counts, caught). Loudness wants a listen. |
| M20 | VoteScreen:62 "Fifty in" vs 30 alive | already-fixed | BR fills to 50: `MatchConfig.lua:124` BotFillTargetBattleRoyale = 50. |
| M21 | VoteScreen:347 no pitch on phone shapes | needs-Studio | `VoteScreen.lua:372/382` pitch only on the card shape; row/compact need a render (tools/vote_drop_gallery.lua). |
| M22 | AchievementData:67 rank-score formula in copy | fixed-now | Formula dropped `AchievementData.lua:68-72`; ProgressText `:113`; menu shows it `MenuClient.client.lua:2047`. Check "achieve" (12 rows; plant = raw score, caught). |
| M23 | GamepassConfig:337 "5x 2x Health Boost" | fixed-now | `GamepassConfig.lua:349` "%d × one-match %s"; purchase toast names it `Bootstrap.server.lua:117`. Check "bundle" (plant caught). |
| M24 | MenuClient:999 trade header ignores your confirm | fixed-now | `MenuClient.client.lua:1060` four states. |
| M25 | MenuClient:1364 dead Super Crate price | fixed-now | `MenuClient.client.lua:1336` hidden outside Studio until the product id is set. |
| M26 | MenuClient:1553 "GunSkin", inert CRATES | fixed-now | `MenuClient.client.lua:1650` "Gun Skin"; `:1681` live FROM CRATES → Crates tab. |
| M27 | MenuClient:1708 Daily Spin text | fixed-now | `MenuClient.client.lua:1831` "no streak yet"; prize list matches DailySpinData. |
| M28 | MenuClient:2339 settings labels run under the key button | fixed-now | `MenuClient.client.lua:2549` TextTruncate AtEnd. |
| M29 | MenuClient:2551 restock timer on the Style tab | fixed-now | `MenuClient.client.lua:2760` stockHeader(…, true): no timer; ticker left alone. |
| M30 | MenuClient:3340 invite vanishes without warning | fixed-now | `MenuClient.client.lua:3585` "Expires in Ns" (wall clock). Refusal messages reach the screen via guard. |
| M31 | ProgressionPanel:1429 "pull it in play" | fixed-now | `ProgressionPanel.lua:1557` "BOUGHT — get one\nfrom a coin crate" (old line lengths). |
| M32 | GameMode:382 respawn wait only in a 2.6 s toast | fixed-now | The recap is CombatService's and is sent before the death reaches the mode, so GameMode puts `RespawnAt` (server time) on the player `GameMode.lua:364`; HudClient titles the recap "DOWNED BY RIVAL — BACK IN 5", counting down per frame `HudClient.client.lua:3767`, then the plain title; also reads a payload `respawnDelay` if CombatService adds it (proposed edit in the report). Title scales to fit. Check 7 (5 → 4 → plain, payload path; plant = attribute ignored, caught). |
| M33 | VoteScreen:70 KOTH pitch drops "alone" | already-fixed (superseded) | KOTH is now objective capture; pitch `VoteScreen.lua:70` "Two teams, two objectives. Capture and hold them, first to %d." |
| M34 | LootService:247 rarity colour-only on the floor | already-fixed (floor) · fixed-now (HUD) | `HudClient.client.lua:1599` the held gun's line leads with its tier word ("LEGENDARY  Crocodilo Rifle"). |

## What Oliver's machine should run

- A pad: die in a match, press RB (next) and B (leave); open the menu with Back, quests with D-pad left; stand by a floor gun and press X (reload only) then B (pick up).
- A phone: spectate, tap NEXT / LEAVE (buttons sit 80 px above the label).
- Start a match from the lobby: the MATCH EVENT card should appear after the NEXT MATCH reveal, not under it.
- Get shot, then die in the storm: recap sources list "Storm"; the headline no longer names the shooter and the title reads "THE STORM GOT YOU".
- Team match: shoot a team-mate (grey + tick), watch the TDM clock under FIRST TO 100.
- Hold a Rot Barricade on a desktop: its description and the "Up to 3 ..." rule sit left of the ammo count; open the bag (B) and hover a card: the detail replaces the picture. A floor "Scrolla Scrolla Brrrap" label ends "· SMG" (render: tools/floor_label_gallery.lua).
- Aim a Rot SMG (reach 180) at a wall 250 studs off: the crosshair ticks go grey; step closer and they come back.
- Objective Capture: the line under the scoreline reads "A YOU  B OPEN" and changes as objectives change hands. Die there: the recap counts "BACK IN 5 ... 1".
- Stand outside the storm: a quiet, higher groan with each tick of damage.
