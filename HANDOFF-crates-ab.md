# Handoff — crates, crate open, building audit, map plans (tab "ab")

Stopped 2026-09-21 on Oliver's instruction ("stop all agents and all tabs", "pause all work here until
next session reset"), relayed by claude-43. Nothing is queued in Studio; no job of mine was running
when I stopped. `verify.py` OK, `lua_static_check.py` 0 findings, `balance.py` 0 unbalanced at the
moment of stopping.

Read this before touching crates, the crate reveal, `tools/audit_buildings.lua`, or `MapBuildings`.

---

## 1. What is DONE and PROVEN

**Beginner's Luck, hidden (Oliver's "Secret 4x luck").** A profile's first 4 FREE brainrot crates roll
at 4x; those cards list rarity names with no percentages; nothing explains it. Paid and coin-bought
crates are never boosted and never spend a charge. Proven by `tools/beginner_probe.lua` (37/37,
including grant-once, spent-stays-spent, never-boosted-when-bought, and a planted wrong-luck mismatch
that fires at 6.4–29.9 sd).

Rendered and **sent to Oliver** (`scratchpad/ab/cards3/`, 13 PNGs):
- `003_crate_cards_side_by_side.png` — the same Common Crate normal then boosted. This is the picture
  that answers his question.
- `002_crate_cards_boosted.png`, `001_crate_cards_normal.png`, `004_crate_cards_pass_owner.png`.
- `013_crate_open_before_after.png` — the old fly-off above the new hinge swing.

One open question I put to him and he has not answered: the boosted card still shows `+ 6% accessory`.
That number is unaffected by luck so it is still true; removing it would hide something accurate.
Leave it until he says otherwise.

**#37 (stairs into walls / wall holes) — ticked by claude-43.** Five maps, all clean:

| map | seed | wallHoles | stairTopsIntoWall | blockedFlights | windows = panes | build |
|---|---|---|---|---|---|---|
| SahurSprings | 101 | 0 | 0 | 0 | 730 = 730 | 10.0 s |
| TralalaTown | 202 | 0 | 0 | 0 | 719 = 719 | 8.4 s |
| BombardiroBay | 303 | 0 | 0 | 0 | 771 = 771 | 11.4 s |
| RotRidge | 404 | 0 | 0 | 0 | 644 = 644 | 8.1 s |
| PatapimPlains | 505 | 0 | 0 | 0 | 700 = 700 | 10.0 s |

Log `scratchpad/ab/audit5.log`. Zeros are absences: `bump` only creates a counter when it finds a
fault. `flights`/`stairTops` ARE present on every line, so the check ran. Both self-tests read 0 as
built and 1 with a fault planted, on every map. The build times are the measured baseline for the
15 s whole-map budget.

**`tools/audit_buildings.lua` fix worth knowing:** the self-tests rescan a building two or three extra
times, and restoring only the counter under test left every other counter carrying the test's own
contribution — that is how a planted `SelfTestSeal` was reported as `blockedFlights = 1`. `totals` and
`examples` are now snapshotted before the self-tests and restored after (`restoreCounts`).

**#32 batch 1 (MapBuildings town profiles) — proven.** `MapBuildings.RollPlan(downtown, townPlan)`
honours `weights`, `sizes`, and carries `palette`, `sign`, `variant` out on the rolled plan;
`buildBuilding` reads palette and sign. `tools/mapplan_probe.lua`, **21 passed** (log
`scratchpad/ab/mapplan2.log`), including:
- no profile → identical plans AND an identical random stream over 4,000 rolls, compared after every
  single roll against a verbatim copy of the old `rollPlan`;
- a planted wrong reference is caught (1,890 rolls differ);
- a profile restating the defaults changes nothing and takes the same draws;
- fixed sizes draw no randoms at all; `sign = false` survives as `false`.

---

## 2. What is BUILT but NOT PROVEN — pick these up first

**a. Style Crate distribution proof (#60).** `tools/style_crate_probe.lua` is written and has never
run. It measures 9,000 opens per tier against `CrateData.EffectiveOdds`, with a planted mismatch
(Style's rolls judged against Prestige's odds) that must fail. **This is the one that matters most**:
the three Style tiers are sold for coins AND Robux, and nothing has yet measured that what the card
prints is what the crate rolls. Run it first.

    powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/style_crate_probe.lua

**b. The Style-row clipping fix.** The render caught a real bug: the Style Crate rows cut their odds
line off mid-list — `…Lege 2.5%  Myth` and nothing after it — so `Myth 0.40%` and `Secr 0.10%` never
appeared on a crate costing 8,000 coins / 69 R$. `UiParts` `row.Line` is a fixed one or two lines tall
and clips. Fixed in `renderStyleCrates` (MenuClient) by drawing that label directly with
`AutomaticSize.Y`, wrap on, truncate off, plus narrower action buttons. **The fix has not been
rendered.** `tools/crate_card_gallery.lua` has the matching change; re-run it and look at
`005_crate_cards_style_tiers.png`.

**c. The narrow (phone) brainrot card.** Same bug class, same fix: the odds line used a fixed two-line
box. It now measures the text with `TextService:GetTextSize` and shifts the description, the drop
photos and the card height by the difference. **Never rendered at a narrow width.** Render at 320–375
px before trusting it.

**d. #32 batch 2, terrace + barn.** `plan.variant == "terrace"` blanks both side walls (no windows,
party-wall colour) and `"barn"` puts a pitched roof on a warehouse. Per the Cities tab's decision, NO
geometry is shared between models. The probe's terrace section has **two badly written checks that
fail and must be fixed before the result means anything**:
- "the plain house it is compared against HAS side windows" returned 0 — my test for a side-wall pane
  (`part.Size.X < part.Size.Z`) does not identify them, so the primary check ("terrace: no windows in
  the side walls", which passed) is currently **vacuous**. Fix the pane test first.
- "it still builds its own full set of walls" compared wall-part counts and got 26 vs 38. That
  criterion is wrong: a windowless wall needs fewer parts, not more. Compare the four wall RUNS (front,
  back, two sides) per floor instead, or check the model's bounding box is unchanged.
Also unresolved and deliberate: **a barn loses the roof chest** a warehouse gets (a pitched roof has no
flat top). Someone tuning loot should decide whether to place that chest elsewhere.

**e. Loot-spot floating (handed to me by claude-43, not started).** `spotFloating` counts a loot pad
with more than 0.3 studs of air under it, measured against whatever is directly below (terrain or a
part), and the examples name what was hit. 136 on SahurSprings sounds alarming but is not yet
actionable: in the examples five of six gaps are 0.46–0.52 (a terrain voxel reading low, invisible)
and one is 3.91 (a gun at chest height over grass). I banded the counts in `audit_buildings.lua`
(`spotFloat0_3to0_6`, `spotFloat0_6to1_5`, `spotFloatOver1_5`, `spotFloatOnTerrain`, plus a twelve-item
`spotFloatBad` list) — **that banded run has not happened.** Do it, then chase the SahurSprings cluster
at y≈38.9 near (-580, 367) and (-519, 370), the same high ground as the 3.91 and as the three
`spotNoGround` spots (nothing at all within 5.5 studs below). claude-43's lead: `GroundHeightAt`
changed at 03:41 to start at y=2000 with `IgnoreWater` and still returns `or 0` on a miss — check
whether those pads were placed off a stale or failed height. **Do not edit LootService directly**:
read its owner in COORDINATION's ownership table and send that tab an anchored patch;
`spawnGroundWeapon`'s gun lines are claude-f0's.

---

## 3. New shared file

`ReplicatedStorage/Shared/CrateOpen.lua` — the lid swing, in one place, played by MenuClient's reveal
and rendered frame by frame by `tools/crate_card_gallery.lua`. Per-tier feel: Common 0.34 s with a
light settle, Prestige Style 0.62 s with a heavy one. Measured in the gallery: the hinge must not
travel while the lid swings (worst drift 0.000 studs), the lid must end up open and behind its hinge,
and no tier may open faster or lighter than a cheaper one — with the old fly-off kept as a planted
failure that must be caught (8.42 studs of hinge travel).

**Correction for claude-4a, in their file:** `CrateModels.lua`'s lid comment says to animate with
`CFrame.Angles(-angle, 0, 0)`. That sign swings the lid's front DOWN into the crate. A crate faces -Z,
the hinge is the back edge at +Z, so the front sits at -Z from the hinge and only a POSITIVE X rotation
lifts it; `LootFxClient`'s shipped world-crate swing already uses the positive angle. `CrateOpen` uses
positive and the gallery fails the wrong sign. One word to fix in that comment.

---

## 4. Two process lessons this tab paid for

1. **`runtest.ps1` and `gallery.ps1` read `BrainRotRoyale.rbxlx` from disk and never build it.** I
   queued a probe without rebuilding and it silently tested the previous build's code — and worse, the
   checks that PASSED in that run were old-versus-verbatim-old, which passes by definition. Rebuild
   (`python build_place.py .`) immediately before queueing, and say so in the coordination channel
   first because another tab may have a baseline-sensitive run queued.
2. **Merge galleries.** Studio is one machine-wide lock with ~10 sessions queued; a picture that could
   have shared a slot and didn't costs everyone half an hour. `tools/crate_card_gallery.lua`
   deliberately holds both the card views and the open film strips.

---

## 5. Exact next step

Rebuild the place, then run `tools/style_crate_probe.lua` (2a). It is the only unproven thing standing
between the three Style tiers and being sold for real money.
