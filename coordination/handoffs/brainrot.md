# Handoff — brainrot shop, companions, crates (tab "ab")

## Landed, with the checks that prove it

**1. Robux brainrot mis-grant (Oliver's top-queue bug, bug-review Finding 4).** A pick could be
overwritten while its receipt was in flight: the prompt-finished event clears the open-prompt hold the
moment a purchase completes, so picking again replaced the paid pick. Receipt 1 (bought for A) handed
over B; receipt 2 found nothing pending and rolled a **random** unowned brainrot. Two purchases,
neither pick.
- Picks now **queue**, oldest first; each receipt takes the oldest pick marked paid (else the oldest
  of any). Nothing is overwritten and nobody is refused a second purchase. A receipt carries only
  `ProductId` (the rarity) and nothing naming the pick, so "oldest paid first" is the best any receipt
  can do.
- Storage is rollback-safe: oldest pick in the slot's own `name`/`at`, the rest on `more`. An older
  build reads `name` — exactly the pick the next receipt is owed.
- Files: `Modules/BrainrotShopService.lua`, `Modules/PlayerData.lua` (reconcile keeps the queue,
  bounded 5, and promotes the first valid pick if the head is corrupt).
- Proof: `tools/brainrot_shop_probe.lua` **18/18** (`scratchpad/ab/shopprobe2.log`), plus
  `tools/monetization_probe.lua` **0 failures** as a regression (`ab/money_regress.log`).

**2. Companion heal/cooldown exploit.** Toggling the equipped companion respawned it at full health
with `lastAttackAt = -math.huge` — a heal and a ready ability for two Menu tokens, against cooldowns
of 1.35–2.6 s.
- `CompanionService.Refresh` carries the health FRACTION and `lastAttackAt` across the respawn, the
  way `UpdateStats` does across a merge. `RefreshAll` (a completing trade — the fourth door) routes
  through `Refresh` too.
- The condition is recorded in `despawn` into `lastCondition`, so it **survives an unequip**; cleared
  by `ResetStats`, `ReviveAll` and `PlayerRemoving`. The coordinator caught that an earlier version
  read the live entry only, which left the hole exactly where the bug was: off-then-on.
- Proof: `tools/companion_refresh_probe.lua` **19/19** (`ab/refreshprobe2.log`), including off/on and
  ten off/on cycles, and two cases holding the match boundaries to still healing.

**3. Brainrot z-fight (41 dirty builds → 0).** `tools/audit_brainrots_zfight.lua` (moved out of the
bug-review tab's scratchpad): **378/378 builds clean, 0 models affected, RESULT PASS**, self-test PASS
with both plants live (`ab/zfight2.log`). Four hunks in `BrainrotModels.lua`: `DomeCollar` 0.18 → 0.32
tall (grows downward inside the body), `Label` 0.7@-0.62 → 0.6@-0.57 (shortened from the bottom only),
`HatCrown` 1.0@+0.55 → 1.2@+0.45 (top unchanged at crownY+1.05), `HatBand` `width * 0.97` →
`width * 0.95 + 0.14`. Part counts unchanged, measured against the baseline log (44|44, 59|59, 56|56,
60|60, 56|56, 61|61, 55|55).
**The rule that matters more than the fix:** `ZFight.FixTolerance` is ABSOLUTE (0.055) and models are
built at three scales, the smallest being the companion at 0.55 — so a step written in model units
must clear `0.055 / 0.55 = 0.1`, not 0.055. The handed-down prescription (0.05 → 0.07) could not have
fixed the companion scale. Before choosing any step: ask what the tolerance is measured in, what the
geometry is measured in, and do the division.

**4. Codex data checked, not wired.** `verify.py` now reports `codex: 126 entries, longest 119/160`
and fails on an entry for a brainrot that doesn't exist, one over `MaxLength`, an exclamation mark, or
one that says its own name — all three planted and caught. The wiring hook is documented at the codex
list loop in `MenuClient` (three candidate sorts, the cost of each, sort a COPY, where the flavour
line goes). **No sort chosen — that waits on Oliver.**

**5. Sold-showcase bug — PROVEN, `tools/merge_probe.lua` 89/89** (`ab/mergeprobe.log`): SELL 1 of the
last copy clears it and says so, SELL 1 of a spare leaves it alone and reports no change, SELL ALL
clears it, selling duplicates can't orphan it, a saved orphan is dropped on load while a legitimate
one survives, a planted orphan is caught, and the block puts the profile back as it found it.** Selling the last copy of the
brainrot you showcase left it on your lobby podium, in other players' trade lists and in the saved
profile. `RewardService.dropOrphanedDisplays` now clears `Companion` and `Showcase` together on both
sell paths and returns whether the showcase changed; the Bootstrap sell remotes call
`ShowcaseService.Refresh()` only when it did. `SellDuplicates` needed nothing (it keeps one of every
name), checked not assumed. **And `PlayerData`'s reconcile now drops a showcase the player does not
own** — without that, everyone who already hit the bug keeps a ghost podium forever, since the sell
fix only stops new ones. Probe cases are in `tools/merge_probe.lua`, invariant: *nothing showcased is
absent from the collection*.

**6. Style Crate odds — PROVEN, 88/88** (`ab/styleprobe2.log`). The three tiers sell for coins and
Robux, so this was the one that mattered. Measured shares versus the percentages **parsed back off
the card's own printed line** (not `CrateData.EffectiveOdds` — the roll calls that too, so comparing
them compares a function with itself): Style worst 1.0 sd, Deluxe 0.9 sd, Prestige 1.8 sd against a
4 sd limit, 9,000 opens each. The plant bends `Rarity.Roll` (one Common in eight comes out Rare)
while touching nothing on the card: caught at 8.0 sd. Pity is measured and only ever helps — Deluxe
Epic+ realised 27.25% vs printed 25.00%, Prestige Legendary+ 27.12% vs 24.00%, i.e. the cards
UNDERSTATE what a player gets at the guarantee line. Refunds exact (2,800 / 10,000 / 27,000), buying
exact, Robux crates counted paid, never Beginner's Luck boosted. The probe reports its own
resolution: at 9,000 opens only Style's Secret row (0.10%) sits inside the printed rounding and is
therefore not tested by it.
**Two lessons in it:** a probe that reads both the shown and the rolled number from the same function
is a tautology; and `CrateService.Open` throws on a stand-in player (it fires a remote at the end,
after the roll), so a probe must pcall it and read the profile.

**7. Defense cap stated, and item/reward wording.** The 3-structure cap was a literal in
`DefenseService` that nothing told the player about — a fourth wall silently collapsed their oldest.
Now `ItemData.MaxStructuresPerPlayer = 3`, the three structures' descriptions are COMPOSED from it
(never typed, so prose can't drift), `DefenseService` reads it, and the owner is told which of theirs
came down. Mines are excluded on purpose: four items are `kind = "defense"`, only three are
structures. Three verify.py checks, each planted and caught.
`RewardService`: four text-vs-arithmetic claims checked, none wrong — and the distinction worth
keeping is that three of them CURRENTLY AGREE while one CANNOT DISAGREE BY CONSTRUCTION (the menu and
`CheckCollections` read the same `BrainrotData.CollectionBonus` table). Only the first kind is worth
re-checking later (streak 50/100/150/200; bot kills
40/32 vs 75/60; obby 250 on first clear; set bonuses drawn from the same table the payout uses). The
real fault was an undocumented contract — `AwardBonusCoins` brackets `reason` after the amount, so a
whole sentence read as *"+250 SahurCoins (Cloud Climb cleared in 12.3s — server record!)"*, and since
it only speaks when coins land, a first clear on an unloaded profile said nothing. Clear announced on
its own line now; contract written on the function.
`ItemData.Items[id].capRule` is its own field, not a sentence glued onto `description` — the HUD
tab's reason and it is the better one: joining two fields is a line of code, splitting one requires
parsing English, so a fused field imposes its choice on every consumer that will ever exist. Still
composed from the constant. `tools/plant_check.py` proves all four cap checks (literal returning,
number typed into the sentence, notify removed, `capRule` deleted) — 4 caught, 0 missed.
**Still open:** all 17 item descriptions have no surface — nothing draws them. Patch and the
measurement that shows it does not fit as-is (footer ~65 chars, descriptions up to 209) are with the
HUD & UX worker via claude-43; `InventoryPanel.lua` is theirs, not mine.

## Proven / unproven, with numbers
- Proven: all four above; #37 building audit clean on all five maps; #32 batch 1 town plans (21/21,
  4000 rolls with the random stream compared after every roll); hidden Beginner's Luck (37/37).
- **Unproven, highest value first:** the Style-row odds-clipping fix and the narrow phone card (both
  written, never rendered — renders come back blank while Oliver's display is asleep). Then #32 batch
  2 terrace: its check passes but **its own vacuity guard fails**, so it proves nothing until the pane
  test is fixed. The Style Crate odds probe is no longer on this list — see 6 above.
- Detail in `HANDOFF-crates-ab.md` (root), which stays accurate.

## Open items
- **Robux mis-grant residual, must not be lost:** two prompt-finished events lost in a row (A unpaid
  in the queue, B paid but unmarked) means B's receipt takes A. Also, a pick whose event is lost goes
  stale after 180 s and is dropped at the next `Choose`; if it had been paid, its receipt falls back
  to random-unowned. Both are better than the old behaviour; neither is "every receipt is correct".
- `BrainrotCodex.lua` (126 entries) is still drawn nowhere. The data is checked and the hook is
  documented (see 4 above); wiring it is one edit once Oliver answers the sort question.
- **Legendary rarity, measured (`tools/brainrot_rarity_audit.py`, no Studio needed). The whole
  finding in one sentence: the size ladder is LIVE IN WORLD SPACE AND CANCELLED IN FRAMED SPACE.**
  Sixteen creatures carry a `look.size` that does nothing anywhere a player looks at a menu, which
  has presumably read as "the rarity system works" to everyone who looked at it. In detail: 15 of 16
  Legendaries share a body shape with a Common or Uncommon (reproduced independently), but all 126
  creatures already have a unique body+extras silhouette — so the gap is that the BODY carries no
  rarity signal, not that two creatures look alike. `look.size` exists only on Mythic (1.10-1.15) and
  Secret (1.20-1.25); Common through Legendary are all exactly 1.00. And `FrameViewport` computes
  `d = distance * size * ...`, pulling the camera back by exactly `size`, so the ladder is cancelled
  in every framed viewport (menu photo, podium, companion icon, crate reveal) and exists only in
  world space. Bumping size cannot make a Legendary read as rarer in the menu as the code stands.
  What the signal should be instead is Oliver's call; nothing changed.
- **The pity gap is OLIVER'S DECISION, with history he needs attached.** Measured: Deluxe Style
  realises Epic+ at 27.25% against a printed 25.00%, Prestige Legendary+ 27.12% against 24.00% — the
  cards UNDERSTATE what a player gets. His standing rule is accurate odds on anything paid and random,
  and "better than advertised" is still a gap. Three options: (1) leave it — defensible, cards stay
  clean; (2) put the guarantee line back on these three rows — **but he cut that line himself on
  2026-09-17, "get rid of the (rank) in 20 opens thing"**, so this is that line returning, not a new
  proposal; (3) print the realised rate instead of the per-roll rate — most honest, most work, and the
  printed number stops being `EffectiveOdds` and has to be derived from the pity cycle (the probe
  would need re-pointing too). My read: 1 is defensible, 3 is correct, 3 is not worth the work unless
  the gap bothers him. Do not pre-build 3.
- Merging: not started. Detail floor holds — part count per creature must not
  drop, print the live count beside the new one, a creature that lost a part is a fail.
- Loot-spot floating (banding is in `audit_buildings.lua`, run never happened); SahurSprings cluster
  at y≈38.9 near (-580, 367) / (-519, 370). Don't edit LootService directly — send its owner a patch.

## Hazards
- `BrainrotModels.Metrics(def)` returns the shared BODIES table **by reference**; three map and lobby
  callers read `metrics.bottom` for footing. Any per-entry proportion work must return a copy or it
  floats statues across the map.

## Next step
Rebuild the place, then run `tools/style_crate_probe.lua`. It is the only unproven thing between the
three Style tiers and being sold for real money.

## Three lessons this tab paid for
1. **`runtest.ps1`/`gallery.ps1` read `BrainRotRoyale.rbxlx` from disk and never build it.** Rebuild
   before queueing or the probe measures the previous build. Worse: the checks that *passed* in such a
   run compared old code against an old reference and passed by definition.
2. **A `-Probe` run never executes Bootstrap.** Register the grant handlers the probe needs, or every
   receipt logs "No handler for grant kind …" and grants nothing.
3. **Never plant a fault in the shared tree — use `tools/plant_check.py`.** A plant deliberately
   breaks a file, and `verify.py` is the gate every tab runs, so an in-place plant makes the shared
   tree red for everyone until it is restored, and the tab that runs verify in that window cannot tell
   whose red it is. It cost two other tabs an hour. The tool copies the tree, plants there, and
   reports CAUGHT/MISSED without the real tree ever being written to.
4. **Land a feature and its check in ONE operation**, never the check first: a check that arrives
   early asserts something the tree does not do yet, which is the same red from the other direction. I
   was told this and then did it anyway ninety seconds later — the `capRule` split wrote ItemData,
   the verify patch failed on a bad anchor, and the gate was red until I fixed it.
5. **A planted case can pass vacuously.** Mine passed while the whole harness was broken ("first
   receipt gave nil"), reading green in a sea of red. Read the planted case's detail string, not its
   verdict.
