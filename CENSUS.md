# The disconnected feature census

Task 05. Finished work that nothing in the game can run, swept deliberately rather than found by
accident. **Nothing in this repository was changed to produce it.** The sweep is
`tools/census.py`; run it with `python tools/census.py .` and it reprints every number below.

## Coverage, before the findings

A count of findings says nothing without a count of candidates.

| Swept | Examined | Flagged | Could not settle |
|---|---|---|---|
| Modules (shape 1) | 134 | 6 | 0 |
| Exported functions (shape 2) | 807 | 50 | 0 |
| Sound cues (shape 4) | 104 | 2 | 0 |
| Remote channels (shape 4) | 84 | **0** | 0 |
| Instance attributes (shape 4) | 115 | 4 | 6 |
| Branches (shape 3) | see below | 2 | — |

**The remote sweep is a clean sweep, and that is a result.** All 84 channels are wired on both
sides. It is reported because a filter that matched nothing is worth knowing about — and because
the first version of that filter reported three dangling remotes, all three of which were wrong.

Shape 3 is the one shape that is not decidable by reading in general, and I did not pretend
otherwise. There is no whole-project branch sweep here. What there is instead: a sweep for branches
gated on an **instance attribute nothing ever writes**, which is decidable and which produced both
shape 3 findings below. I tried a second approach — branches gated on a data field no data sets —
and **threw it away**: it flagged 10 candidates and all 10 were false, because `def` means a
parachute, a vehicle or a brainrot in different files and the heuristic conflated them. That is
stated here rather than quietly dropped.

---

## Confident findings

Each verified by reading the code, not by trusting the sweep.

### 1. The town and wilds cluster — ~7,900 lines, and it is worse than reported

| File | Lines | Shape | Referrers |
|---|---|---|---|
| `ServerScriptService/Modules/TownThemes.lua` | 4,857 | 1 | `tools/` only (5 files) |
| `ServerScriptService/Modules/MapWilds.lua` | 2,554 | 1 | `tools/` only (4 files) |
| `ServerScriptService/Modules/TownKinds.lua` | 485 | 1 | **nothing anywhere, including `tools/`** |

**What it was for:** yards, lots, verges, foliage and town character. `MapGenerator` builds towns
itself, through its own `placeTowns` and `buildTown`, and requires none of these three.

**Correction to the brief:** it says `TownKinds` has "no requirer outside `tools/`". It has no
requirer *at all*. `TownThemes` requires exactly four modules — `SafeValue`, `MapSpace`,
`MapTerrain`, `MovementService` (`TownThemes.lua:37-40`) — and `TownKinds` is not among them. So
`TownKinds` is dead even relative to the dead cluster. Only a comment at `TownKinds.lua:215` links
them, and a comment is not a call.

**Verdict: UNFINISHED, and the most expensive thing on this list.** Oliver has asked for more
foliage three times. Route to whoever owns `MapGenerator`.

### 2. Vehicle parking — a feature dead at both ends, one root cause

| Site | Shape | What |
|---|---|---|
| `ServerScriptService/Modules/VehicleService.lua:932` | 2 | `ParkInTowns`, 54 lines, no caller |
| `ServerScriptService/Modules/VehicleService.lua:942` | 3 | its loop body is unreachable on every map and seed |
| `ParkingBays`, `ParkingBaySize` | 4 | attributes read, never written |

`ParkInTowns` reads `town:GetAttribute("ParkingBays")` and returns `0` before its loop whenever the
attribute is absent. **Nothing in production ever writes it.** The intended writer is named at
`TownKinds.lua:215` — "read by `TownThemes`' builders, which write the `ParkingBays`" — and
`TownThemes` is finding 1. So the parking feature is not merely uncalled; it could not work if it
were called.

**This is the connection the earlier accidental discovery missed.** `ParkInTowns` returning zero and
the town cluster being dead are the same fault, and fixing either alone changes nothing.

**Verdict: UNFINISHED.** Its comment records Oliver asking twice for cars to stand in parking lots.

### 3. Comments that name a caller which does not exist

The most dangerous class here, because each one reads as wired.

| Site | Lines | What the comment claims | Reality |
|---|---|---|---|
| `DefenseService.lua:398` `OwnerOf` | 4 | "BotService asks so a bot never shoots through its own side's barricade" | `BotService` never calls it. The name appears nowhere but its own definition. |
| `LootService.lua:890` `FindNearestHeal` | 16 | bots want heals "when they're hurt and carrying nothing" | Only a comment in `BotService.lua:1814` mentions it. Bots never seek heals. |
| `MovementService.lua:550` `DroppingCount` | 3 | "for the build check" | No build check calls it. |
| `Sfx.lua:388` `LoopCount` | 9 | "for the probe that proves the cap and the clean-up" | No probe calls it. The loop cap is unproven. |

**Verdict: UNFINISHED, all four** — each describes a behaviour someone intended and nobody wired.
The last two are also task 06 material: a seam built for a check, and the check never written.

### 4. Touch controls — a slide button bound to nothing, and no crouch at all

| Site | Shape | What |
|---|---|---|
| `StarterPlayerScripts/TouchControls.lua:64` | 4 | slot `BRR_Slide`, an action nothing binds |
| `StarterPlayerScripts/MovementState.lua:66` | 2 | `RequestSlide`, the entry point that would serve it |

Every other touch slot is bound with `Settings.Bind("BRR_X", ...)` in `CombatClient`. `BRR_Slide`
is not, anywhere — it appears in exactly three places, one being the slot table and two being
`tools/` files that draw it as though it works.

**A correction I had to make mid-sweep, because the obvious reading is wrong:** sliding is not
reached through a slide action at all. It is reached through **crouch** —
`CombatClient` binds `BRR_Crouch`, which calls `crouchPressed` (`MovementClient.client.lua:888`),
which calls `tryStartSlide`. And `BRR_Crouch` **has no touch slot**. So on touch: the slide button
does nothing, and the control that actually slides is not on screen.

`MovementState.RequestSlide` fires a BindableEvent whose listener is live
(`MovementClient.client.lua:603`) and which nothing ever fires. It is the natural wiring for that
button.

**Verdict: UNFINISHED.** One of the few findings here a player would feel.

### 5. `Viewmodel.Preload` — the hitch it prevents still happens

`StarterPlayerScripts/Viewmodel.lua:648`, shape 2, 3 lines. "Builds a gun's template ahead of time
(when it's picked up) so drawing it never hitches." Nothing calls it, so no template is ever built
ahead of time and every first draw builds one. **Verdict: UNFINISHED.**

### 6. `CosmeticPreview.lua` — 347 lines, a documented API, no requirer

`ReplicatedStorage/Shared/CosmeticPreview.lua`, shape 1. Required only from `tools/` (2 files). A
finished live preview for accessories, parachutes, gun skins and auras, with a worked usage example
in its own header.

**Not previously known.** `STATUS.md` puts `CosmeticData/Preview` in the menu worker's column, so
this may be mid-wiring right now — which is exactly why it is reported rather than touched.
**Verdict: UNFINISHED. Route to the menu worker, do not delete.**

### 7. Two unreachable branches from attributes nothing writes

| Site | What | Effect |
|---|---|---|
| `BotService.lua:1796` | `item:GetAttribute("BotIgnore") == true` | Never true. Nothing writes `BotIgnore`, in production or in `tools/`. Bots cannot be told to ignore a pickup. |
| `VehicleDynamics.lua:226` | `hub:GetAttribute("Ratio") or 7` | Never set, so the steering ratio is always the default 7. Not a dead branch — a per-hub override that no hub can use. |

**Verdict: `BotIgnore` UNFINISHED** (a flag with no way to set it). **`Ratio` is a judgement call**
for whoever owns vehicles: either something should write it, or the read and the fallback should
collapse to a constant.

### 8. Abandoned — safe to delete

Trivial accessors and wrappers with no caller anywhere, no `tools/` caller, and no comment claiming
one. These are the actual delete list.

| Site | Lines | What it was for |
|---|---|---|
| `WeaponService.lua:1637` `GiveHeal` | 3 | "Kept for callers that only care whether anything was taken." There are none. |
| `WeaponService.lua:1641` `GiveItem` | 3 | the same wrapper, same absence |
| `BotService.lua:2484` `GetAll` | 3 | `return bots` |
| `CombatService.lua:285` `IsAiming` | 3 | the server tracks aim state and nothing reads it |
| `GameMode.lua:114` `Scores` | 3 | `return scores[1], scores[2]` |
| `GameModes.lua:114` `AssertGreen` | 3 | an assertion nothing runs |
| `ModeKingOfTheHill.lua:226` `SiteCount` | 3 | `return #candidates` |
| `ModeTeams.lua:48` `PoolSize` | 3 | `return #greenPool` |
| `ModeTeams.lua:704` `GreenColor` | 3 | "Here so ModeTeams is the one place a mode asks about the green kit." Nothing asks. |
| `MapData.lua:150` `RandomCandidates` | 13 | a shuffled map pool nothing draws from |
| `MenuOpenClaims.lua:146` `Holders` | 8 | a claim list nothing inspects |
| `QuestData.lua:100` `Week` | 3 | a week number nothing reads |
| `TouchControls.lua:510` `SlotRect` | 7 | a slot rectangle nothing queries |

`MenuShell.lua:544 UnbindBack` and `MenuShell.lua:552 ClearContent` are the same shape, **but
`MenuShell` is mid-rewrite on the build machine** and a five-destination navigation may well call
both. Listed, not recommended for deletion.

### 9. `StaminaEmpty` — a cue with no play site

`SoundConfig.lua:1331`, shape 4. A complete sound recipe that nothing plays. Stamina exhaustion is
shown but never heard. **Verdict: UNFINISHED**, and cheap.

---

## Found, and deliberately NOT findings

Both of these are documented as intentional in the source. The sweep flags them; a reader should
not act on them. They are listed so nobody re-reports them next time.

* **`SoundConfig.lua:61-64` `Gunshot`** — "UNUSED: nothing plays `Gunshot` any more. Every gun plays
  a family report below. Kept as the original recipe for reference." Deliberate.
* **`ReplicatedStorage/Shared/BrainrotAssetCandidates.lua`**, 91 lines — "REVIEW DATA ONLY.
  Production does not require this module and it never calls LoadAsset." Deliberate.
* **`ReplicatedStorage/Shared/BrainrotModelsRemake.lua`**, 568 lines — already known, approval
  given, and `STATUS.md` shows a worker swapping the live art to it now. Not stale; in flight.

---

## Could not settle — run-time names, reported as questions

**The census will not call these dead and neither should anyone reading it.** Each is a name built
by concatenation, which no literal search can match against its writer.

| Name | Read at | Why it cannot be settled |
|---|---|---|
| `KP_Muzzle`, `KP_Sight`, `KP_Load` | `GunModels.lua`, `ArsenalFinish.lua` | written by `SetAttribute("KP_" .. name)` at `GunModels.lua:338` — **live** |
| `Parent_` | `Viewmodel.lua:778` | read as `GetAttribute("Parent_" .. group)` |
| `ParkingBay_`, `ParkingBayLot_` | `VehicleService.lua` | read by concatenation; their writer is finding 1 |

The `KP_` group is the brief's own example of the trap, and the first version of this sweep did
report them as dead. They are live.

Three remote channels — `Prestige`, `ClaimIndex`, `BuyCellOffer` — were also flagged by a first
version and are **all live**. The client reaches them through a dispatcher,
`call(ctx, "Prestige", ...)` (`ProgressionPanel.lua:1307`, `:1557`), never through
`Remotes.Function("Prestige")`. That is why the final sweep counts bare string literals and why the
remote result is 0 rather than 3.

---

## How the sweep is kept honest

`tools/census.py` carries two fixtures in `tools/census_fixtures/`, analysed through the same
functions as the real tree.

**must flag** — a module nothing names, and an exported function nothing references. If either
stops being flagged, the sweep has stopped working and the run exits 1.

**must NOT flag** — the two shapes that produced wrong answers while this census was being written:
a module loaded from a name held in a table, and a function referenced only as a value. This is the
more important fixture, because the census is a delete list and a false positive deletes live code.

Both were confirmed to fire, not assumed:

```
clean run exit code: 0
broken-fixture exit code: 1     (a reference added to the must-flag module)
restored exit code: 0
```

Breaking the value-reference guard on purpose reproduces the original false positive exactly:

```
must-NOT-flag flagged: ['LiveModule.CalledAsValue']
census: FAIL — a must-not-flag fixture was flagged; the sweep would delete live code
```

---

## What this census does NOT prove

* **It is a reading of the source, not a run of the game.** Nothing here was observed failing; it
  was observed to have no path that could run it.
* **Shape 3 is barely covered.** Two unreachable branches found, both through the attribute route.
  A general branch-reachability sweep is not in here and I do not think a regex can do it.
* **Anything reached from the place file rather than from Lua would look dead to this.**
  `BrainrotRoyale.rbxlx` is generated and git-ignored, so the sweep cannot read it. I checked
  `build_place.py`, which only classifies files by suffix and adds no references, but a hand-placed
  instance in Studio is outside what I can see.
* **Abandoned versus unfinished is a judgement**, made explicitly per finding above and open to
  disagreement. Where a comment states intent I followed the comment; where there was none I called
  a three-line accessor with no caller abandoned.
* **Nothing here was deleted or changed**, and the section-8 delete list should be read by whoever
  owns each file before anything goes.
