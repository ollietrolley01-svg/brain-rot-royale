# Player's-eye review (#86): status of every site

Source: `coordination/handoffs/bug-review-player-eye.md` (82 sites: 2 blocks-play, 46 confuses, 34 minor).
Checked against the tree at `59ebfe1` plus this branch's commits (deb7f4a, 81a2e0c, 38d3975, de7ffd1, 369cb8e).
Line numbers are the CURRENT tree's, not the review's.

Status key: **fixed-now** (this branch) · **already-fixed** (in the tree before this branch) · **still-open** · **needs-Studio** (a layout/render call; a number would not settle it).
Sites in files other workers own right now (HudClient, PhoneLayout, MatchConfig, …) carry the exact edit as BEFORE → AFTER instead of a change.

Logic check: `python tools/player_eye_check.py .` (5 checks on the real modules) and `--plant` (5 planted faults, all caught).

Totals: fixed-now 43 · already-fixed 22 · still-open 10 · needs-Studio 7 = 82 (a row with two halves counts under its first status).

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
| C7 | Combatants:44 usernames, not display names | fixed-now | In lockstep: `Combatants.lua:49` returns `token.DisplayName`; `HudClient.client.lua:2846` kill-feed highlight and `:2956` bounty "YOU" toast compare `player.DisplayName`. Nothing looks a player up by that string (companion model name `CompanionService.lua:271` is cosmetic). A namesake would also get the "YOU" toast (noted at `:2951`). |
| C8 | LootService:88 floor-gun prompt shares X with Reload | fixed-now | `LootService.lua:100` ButtonB (also chests); `SupplyDropService.lua:210`, `VendorService.lua:162`; lantern off ButtonY `LobbyService.lua:3316`. VehicleService prompts not touched (owned elsewhere): same one line `prompt.GamepadKeyCode = Enum.KeyCode.ButtonB` wherever it builds a ProximityPrompt. |
| C9 | CombatClient:486 phone spectator has no NEXT | fixed-now | NEXT / LEAVE TextButtons on touch `CombatClient.client.lua:548`; line says "tap NEXT or LEAVE" `:450`. |
| C10 | HudClient:1505 "0 / 0" in white | already-fixed | `HudClient.client.lua:1519` "NO AMMO" in red; empty mag names the reload key. |
| C11 | HudClient:2726 bounty warning misses display names | already-fixed | `HudClient.client.lua:2877` compares `player.Name` (what the server sends). |
| C12 | HudClient:2842 phone never sees reserve | still-open | `HudClient.client.lua:1393` `refs.count.Text = tostring(slot.mag)` → `refs.count.Text = (phone and string.format("%d/%d", slot.mag, slot.reserve)) or tostring(slot.mag)` (needs the phone flag in renderSlots) and `refs.center.Text = "NO AMMO"` when `slot.mag == 0 and slot.reserve == 0`. Width check wants a phone render. |
| C13 | LobbyService:3220 Start-over on the Ready key | fixed-now | `LobbyService.lua:3316` KeyboardKeyCode H, GamepadKeyCode ButtonB. |
| C14 | ItemData:198 item descriptions never shown | still-open | No client reads `ItemData.description`. Needs space on the held-item line (HudClient `:1503`) or the bag card (`InventoryPanel.lua:605`, a 16 px line already full); a layout call. |
| C15 | MovementService:274 Blink Bean dead click | fixed-now | `MovementService.lua:277` returns a reason; threaded `WeaponService.lua:1894` (applyItem) and `:1955` (StartUse) to Bootstrap's existing toast; description `ItemData.lua:112`. |
| C16 | WeaponService:1809 "only heals up to 75" at 113 HP | fixed-now | `WeaponService.lua:1869` quotes `math.floor(healCap(...))`; `ItemData.lua:29` "up to 75% of your max health". |
| C17 | HudClient:983 no boots pill / no countdown | already-fixed (soda) · still-open (boots) | Soda countdown `HudClient.client.lua:3877`. Boots: add a pill driven by the `BounceBootsUntil` attribute (MovementService) beside speedPill, same countdown code. |
| C18 | MovementClient:959 which item X uses | fixed-now (label) · still-open (HUD) | `Settings.lua:26` "Use the first movement item in your bag". Still open in HudClient renderSlots `:1371`: `refs.key.Text = Settings.KeyLabel("Slot" .. index)` → append `.. " · " .. Settings.KeyLabel("MovementItem")` on the first movement-item slot. No client toast channel exists for "No movement item". |
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
| C32 | CombatService:353 vetoed hit silent; protection never broken by attacking | fixed-now | Grey "+" tick on veto `CombatService.lua:409` (kind "structure"); landing a hit ends your own protection `ModeTeams.lua:427`. Still open: a "PROTECTED" pill (HudClient reads `SpawnProtected`). |
| C33 | HudClient:1823 (modes) "Storm moves in 0s" over the scoreline | already-fixed | Same as C23 (`:1867`), the line is empty in team modes. |
| C34 | HudClient:2441 nothing points at the hill | still-open | KOTH is now multi-objective ("Two teams, two objectives", `VoteScreen.lua:70`); `HudClient.client.lua:2586` still draws only the storm "ZONE" marker. Needs a marker per objective from ModeKingOfTheHill.Objectives; design call. |
| C35 | HudClient:3510 "+0 / +0" and "#2" in team modes | already-fixed | `ResultsScreen.client.lua:325` VICTORY / DEFEAT / DRAW; the old "+0" result is gone (header comment `:4`). |
| C36 | HudClient:3587 "50 ALIVE" in respawn modes | already-fixed (players) · still-open (late joiner) | Banner hidden in team matches `HudClient.client.lua:3706`. Late joiner `:3749` `bannerTitle.Text = matchState.aliveCount .. " ALIVE"` → `bannerTitle.Text = (matchState.mode and matchState.mode ~= "BattleRoyale") and string.upper(GameModes.Get(matchState.mode).name) or (matchState.aliveCount .. " ALIVE")`. |
| C37 | ModeScoreHud:187 "level", hill status invisible | fixed-now (TIED) · still-open (status) | `ModeScoreHud.client.lua:271` "TIED". Hill status line not added: KOTH now scores several objectives, one status word no longer describes it. |
| C38 | ModeScoreHud:200 TDM has no clock | fixed-now | `ModeScoreHud.client.lua:278` "FIRST TO 100\n7:42", red in the last 30 s. |
| C39 | ArsenalExpansion:14 gun names carry no type | still-open | Needs `def.style` in the slot payload and a type word on floor label / HUD line; floor label already carries rarity (`LootService.lua:284`). |
| C40 | WeaponData:18 range never shown, out-of-range silent | still-open | Crosshair dimming is CombatClient + WeaponData range; inventory line is full (`InventoryPanel.lua:605`). |
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
| M4 | HudClient:1372 rarity colour-only | already-fixed (floor) · still-open (hotbar) | Floor label/prompt carry the word `LootService.lua:284`. Hotbar `HudClient.client.lua:1383` colour only; proposal: a one-letter tier tag in the cell corner. |
| M5 | HudClient:1493 "click to use" on a pad | still-open | `HudClient.client.lua:1503` `slot.name .. "  •  click to use"` → `slot.name .. (lastInputIsGamepad and "  •  RT to use" or "  •  click to use")`. |
| M6 | HudClient:2224 minimap names 9 px, towns vs landmarks by colour | needs-Studio | `HudClient.client.lua:2273`, `:2438` TextSize 9; diamond markers need a render. |
| M7 | MenuClient:646 filter chips 28 px | needs-Studio | `MenuClient.client.lua:658`; growing to 44 px wraps the row, needs a render. |
| M8 | HudClient:2653 kill feed row runs off screen | fixed-now | `HudClient.client.lua:2843` TextTruncate AtEnd, right-aligned, placement first. |
| M9 | LobbyService:554 welcome arch faces the plaza | fixed-now | `LobbyService.lua:559` greeting on Back (+Z), the face seen from the spawn at z 110 (`SpawnOffset :101`). |
| M10 | LobbyService:2135 [G] with no companion does nothing | fixed-now | `Bootstrap.server.lua:664` throttled "No companion yet" toast when UseAbility fails and no companion is equipped. |
| M11 | LobbyService:3168 sprint key never named | fixed-now | `LobbyService.lua:3265` KeyHint "Hold [{Sprint}] for the long leaps"; the ControlsHint half is moot (removed). |
| M12 | HudClient:890 "Stay inside the storm" | fixed-now | `HudClient.client.lua:921` "Stay inside the zone — the purple storm wall hurts. …". |
| M13 | ItemData:149 three-structure cap unstated | still-open | Text exists as `capRule` `ItemData.lua:253`, but nothing reads it. Proposal: MenuClient/HUD caption appends `item.capRule` wherever the description is shown (none yet, see C14). |
| M14 | ProjectileService:587 driver's throw refused silently | still-open | Client sinks the click; `HudClient.client.lua:1503` → when `Humanoid.SeatPart` is a VehicleSeat: `slot.name .. "  •  hands on the wheel"`. |
| M15 | SupplyDropService:251 supplies never announced | fixed-now | Spilled on the ground since #85; toast names every piece `SupplyDropService.lua:268`. |
| M16 | HudClient:1492 first click after a swap eaten | still-open | `HudClient.client.lua:1500-1503` item branch: reuse `local raising = (loadout.equipReadyIn or 0) > 0.05` (`:1508`) and when raising set `ammoText.Text = "RAISING"`, `weaponName.Text = slot.name`. |
| M17 | MatchEvents:77 "half again as fast"; Shield Up "drops in" | fixed-now | `MatchEvents.lua:81` composed from the speed ("50% faster"); `:53` "Everyone starts with 50 shield." Check "events" (plant = field 1.75, caught). |
| M18 | MatchService:1739 countdown 15 → 7 | fixed-now | `MatchService.lua:1910` an all-ready lobby enters Countdown at AllReadyCountdown. VoteScreen's bar total is still LobbyCountdown (VoteDropClient passes it): bar starts part-empty rather than snapping. |
| M19 | StormService:269 storm damage silent | already-fixed (enter/leave) · still-open (tick) | `StormClient.client.lua:206` StormEnter/StormLeave cues (#45). No per-tick sound. |
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
| M32 | GameMode:382 respawn wait only in a 2.6 s toast | still-open | Needs the recap (HudClient `:3540`) to carry a countdown: add `respawnDelay` to the recap payload and title it `"DOWNED BY " .. name .. " — BACK IN " .. n`. |
| M33 | VoteScreen:70 KOTH pitch drops "alone" | already-fixed (superseded) | KOTH is now objective capture; pitch `VoteScreen.lua:70` "Two teams, two objectives. Capture and hold them, first to %d." |
| M34 | LootService:247 rarity colour-only on the floor | already-fixed (floor) · still-open (HUD) | `LootService.lua:284` "Uncommon Crocodilo Rifle" label and prompt. HUD `HudClient.client.lua:1529` could append `string.upper(slot.rarity)`. |

## What Oliver's machine should run

- A pad: die in a match, press RB (next) and B (leave); open the menu with Back, quests with D-pad left; stand by a floor gun and press X (reload only) then B (pick up).
- A phone: spectate, tap NEXT / LEAVE (buttons sit 80 px above the label).
- Start a match from the lobby: the MATCH EVENT card should appear after the NEXT MATCH reveal, not under it.
- Get shot, then die in the storm: recap sources list "Storm"; the headline no longer names the shooter and the title reads "THE STORM GOT YOU".
- Team match: shoot a team-mate (grey + tick), watch the TDM clock under FIRST TO 100.
