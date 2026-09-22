# Logic-review survivors — triage for routing (read-only; no edits, no Studio)
Source: logic_review_survivors.md (34 findings, mtime 2026-09-21 23:29). Tab: Bot tabs work [77c37e], 2026-09-22 ~04:5x.
Ownership from COORDINATION.md's 09-21 17:3x fleet table + the 09-22 04:2x one-Tier-1-each table.
"Moved tonight" = the cited file's mtime is newer than the review, so its LINE NUMBERS are stale.

## The count "27 unrouted" is stale — it is 9
27 was true when only the seven list-2 symptoms counted as routed. The 04:2x six-tab routing and the
matchflow change set landing now cover far more. Derivation, all 34 accounted for:
- OWNED (22): 1, 8, 9, 12, 13, 17, 18, 19, 20, 21, 23, 24 = the matchflow change set (bug review, landing
  now) · 5, 7 = PlayerData (landed) · 4 = brainrot · 6 = bots · 15, 16, 31 = destruction · 25, 33 = menu+HUD ·
  27 = guns.
- HELD, no tab (3): 22 + 30 = #102's client half (my item (c), patch below) · 32 = #104 HUD not gated on
  participation — one of your seven, never assigned to a tab.
- UNROUTED (9): 2, 3, 10, 11, 14, 26, 28, 29, 34 — the table below. **Two of the nine are already dead.**

## TOP BLOCK — your two sorting rules
| # | sev | file(s) | owner | what a player experiences | flag |
|---|---|---|---|---|---|
| 11 | exploit | CompanionService.lua :1014 Refresh, :143 despawn; Bootstrap SetCompanion/Sell | — | **ALREADY FIXED tonight.** Was: toggle your companion off/on mid-match for a full heal + ability reset ~2.5x/s from a modified client. | **CLOSE IT.** Moved 04:41. `despawn` now records `{fraction, lastAttackAt}` in `lastCondition`; `Refresh` re-applies both after `spawnFor`. The comment block at :1001-1013 states the exploit and the burst budget. Exactly the fix the review asked for. |
| 34 | exploit | DefenseService.lua :519-526; Shared/DefensePlacement.ThrowOrigin :91; DefensePreview.lua :139 | — | **ALREADY FIXED tonight.** Was: stand against a 1.4-stud wall, throw a kit, and a 95-damage Rot Mine arms INSIDE the building where nobody can reach it. | **CLOSE IT.** DefenseService moved 04:46, DefensePreview 04:14. `ThrowOrigin` casts past the spawn point with `RespectCanCollide`, pulls back by the kit's width, and goes behind the head when there is no room. The client ghost calls the same function, which is the mirror the review asked for. |
| 2 | visible | RewardService.lua :308-312 SellBrainrot, :344-347 SellAllOfRarity; Bootstrap :804-818 sell remotes; ShowcaseService.Refresh | **UNOWNED** — nearest is Menu (profile/economy) | **LOSES SAVED DATA.** Sell the last copy of your showcased brainrot and it stays on your lobby podium, in other players' trade lists, and in your saved profile forever — a ghost item you own but do not own. TradeService:293-298 already clears `data.Showcase`; the sell paths do not. | Clean: RewardService Sep 17, ShowcaseService Sep 16, Bootstrap 23:26 (3 min before the review). Lines good. |
| 3 | visible | VendorService.lua :105-115 Buy; WeaponService.lua :1686-1701 GiveAmmo | Guns owns WeaponService gun fns; **VendorService UNOWNED** | **LOSES SAVED CURRENCY.** Pay 150 SahurCoins at the vendor holding no gun, or with every reserve already at the 2x cap, and you get the vendor quest tick and a green "AMMO REFILL" toast for nothing. `GiveAmmo` returns true for any live loadout instead of saying whether rounds were added, so the "Nothing to reload." refusal is unreachable. | Clean: VendorService Sep 17, WeaponService Sep 21 18:39. Lines good. |

## REST, in the order I would route them
| # | sev | file(s) | owner | what a player experiences | flag |
|---|---|---|---|---|---|
| 14 | latent | VoteService.lua :216 CastVote, :275 Forget; MatchService.SetReady | Pre-match UI | A lobby bystander readies up, votes, un-readies, and their vote still decides or tie-breaks the mode and map for everyone actually entering the match. | **STILL LIVE, verified:** MatchService references VoteService only at :1498-1523 and :1840-1857 — `Forget` (VoteService:275) exists and MatchService never calls it, and `tally()` does not filter on `isReady`. MatchService moved tonight; VoteService did not. |
| 10 | visible | HazardService mine poll; CombatService.DealDamage; MatchService.finishMatch | Destruction (hazards) + bug review (finishMatch) | You win the match and an enemy Rot Mine armed seconds earlier kills you during the 15-second Results screen — no recap, no FX, no kill feed, no respawn until the intermission. | **STILL LIVE, verified:** HazardService contains no `MatchService`/state reference at all. Flag: the finishMatch half is in MatchService, which moved 04:48 tonight — re-read those lines before quoting them. |
| 29 | visible | VoteDropClient.client.lua :162; VoteCursor.lua :52-56; VoteScreen.lua :119-132/:193-207; HudClient :237 | Pre-match UI + HUD — **cross-tab, needs your call** | During the lobby countdown the vote screen takes a full-screen Modal overlay and MenuOpen from EVERY player regardless of readiness: it covers the READY pill and HudClient refuses the ready key, so an unready player can only ready via the pad and a readied player cannot un-ready at all until the vote closes. | Vote files clean (23:01); HudClient moved 04:24. |
| 28 | visible | HudClient.client.lua :2447 updateCompass, :2743 bounty, :3684 speed pill vs apply() :3036-3040 | HUD | On an upright phone the compass, bounty line and speed pill set `Visible = true` every frame and reappear at their DESKTOP positions on top of the portrait minimap and icons, after the phone layout deliberately hid them. | **Moved 04:24 — line numbers stale.** I did not re-derive the cause; the HUD tab should re-read before acting. |
| 26 | cosmetic | CombatService.lua :551, :576-582 firePellet | Guns (or Destruction) | A pellet shatters a window pane and then hits nothing: every client sees the tracer stop dead at the broken window instead of carrying on to the gun's range. Lowest of the nine. | Clean (Sep 21 23:03, before the review). |

## Also needing a home (HELD, not in the nine)
- **32 / #104** — storm + team HUD not gated on participation (HudClient :504-538, :1803-1814; StormClient :77-92;
  ModeScoreHud :159-171). A lobby player watches the storm readout, the wall ring drawn through Rot Island, the
  purple OUTSIDE THE ZONE vignette and the TDM/KOTH scoreline for a whole match they are not in. One of your
  seven, but no tab was ever assigned. HudClient 04:24, StormClient 04:24, ModeScoreHud 04:26 — all moved tonight.
- **22 + 30 / #102** — client half. REASSIGNED 2026-09-22 ~05:0x: the bug-review tab owns `CombatClient` for this item and is adding a server-side `InMatch` attribute. No patch from this tab. One measured fact for whoever writes it, below.

## One measured fact for #102's owner (bug review), from a --check + static run on a COPY
I got as far as anchoring the client half before the item was reassigned; nothing was applied to the
shared tree and the patch is withdrawn. Two things I proved on the way are worth keeping:

1. **The client read and the server write must land together, or the read lands second.**
   `tools/lua_static_check.py` on a patched copy reported a NEW finding that the unpatched copy does
   not have: `ATTRIBUTE InMatch (attribute read at 1 site(s) and never written by any Lua here —
   either dead or it comes from the place file)`. Baseline 11 pattern findings → 12. So a client
   filter landing alone takes the guns/HUD three checks off zero.
2. **`~= false`, not `== true`.** A filter written `owner:GetAttribute("InMatch") == true` returns
   BOTS ONLY before the server attribute exists (nil ≠ true), hiding every real player from every
   spectator — that failure is real and is the one the guns tab flagged. Written
   `owner == nil or owner:GetAttribute("InMatch") ~= false` it degrades the other way: nil keeps
   today's behaviour exactly, so the client half is inert-but-harmless until the server line lands,
   and bots (no Player, and they only exist inside a match) are kept by falling through either way.

Also worth knowing before that patch is written: **the SERVER-side hole in #102 is not closed.**
`Bootstrap.server.lua`'s focus gate tests that the SPECTATOR is spectating (`MatchService.IsSpectating`,
which is correct and well-commented) but tests the TARGET only with `Combatants.FromCharacter`, whose
fallback is `Players:GetPlayerFromCharacter` — so **any** player's character passes, including a lobby
idler's. A client-side filter cannot close that; a modified client just ignores it. The target test
needs to be an alive-participant test. That belongs with the `InMatch` work, same owner, same landing.

## Provenance
Read-only. Nothing landed, no Studio job, no file in the shared tree but this one. Findings 11 and 34
were confirmed fixed by reading the current source, not by inference: CompanionService's `despawn`
now records `{fraction, lastAttackAt}` into `lastCondition` and `Refresh` re-applies both, and
DefenseService throws from `DefensePlacement.ThrowOrigin`, which the client ghost calls too.
Findings 14 and 10 were confirmed STILL LIVE the same way (MatchService never calls `VoteService.Forget`;
HazardService contains no match-state reference at all). 28 and 29 I flagged but did NOT re-derive —
their files moved tonight and a shape at a line is not a cause.
