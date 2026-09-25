# Review: `pc/lag-bug-sweep` (live as Roblox version 8)

Reviewed tree: `pc/lag-bug-sweep` at `cf35aa3` (it merges main `d1e4f73` at `faeedab`), compared with main
`d1e4f73`. All line references are to `cf35aa3` unless marked main. Asked for by the build machine's
`2026-09-25-1000-sweep-review-and-remaining-to-jacob.md` ("leave all reviewing to jacob"). New files
only; nothing in the sweep was changed.

## Verdict

We found nothing that should crash or stall a live version-8 server. Every server-side change we read
refers only to locals and functions that exist, and are defined before they are used. `verify.py`,
`balance.py` and `lua_static_check.py` pass. Roadkill, loot spill, the +25% time-to-kill bug test, the
silly-explosions bug test and the bot-lag proof give the same results as on main. Bot tick cost did not
go up.

Five things need a look before the sweep goes to main:

1. **Rot Ridge changed its look without anyone saying so.** Its ground went from Rock to Limestone. Two
   lookups keyed on Rock now miss, so its woods, shelters and props are the Grass map's.
2. **Two map-building checks now fail on seeds that are clean on main.** On one, a car park sits in the
   river. On the other, a static car stands in open country.
3. **`base_vehicle_respawn_check` now fails at seed 9.** It passes on main, although the sweep's
   message says it was failing before.
4. **Four rows marked "fixed" don't change what players get.** In three the fix is never called or
   never takes effect, and one row says in its own text that its main trigger is still open.
5. **The quality gate goes from 9 red checks to 26.** Most of the new red is harness drift, not the
   game: the checks can no longer load the changed code. It needs fixing first, or the gate stops
   meaning anything.

Version 8 also contains all of `pc/teambase-v2` (merge `1000f1c`). That is 1,223 new lines of
TeamBaseRoads and about 1,500 changed lines of TeamBaseRuins, and the 137-row table doesn't cover them.
The 0830 handoff called that branch "held for the bug sweep", with 14 Studio road-probe checks still
failing. We didn't review it (see "What we did not review").

## What the branch is

| part | commit(s) | files | in the review table? |
|---|---|---|---|
| the deep hunt: "139 confirmed fixes, plus Oliver's playtest reports" | `2e6d846` | 64 | yes: 137 rows (7 high, 40 medium, 90 low; 135 "fixed", 2 "not-fixed") |
| an earlier "20 reviewed fixes" sweep | `1797844` | 15 | no |
| `pc/teambase-v2` (bases v2, access roads, terrain smoothing), fully merged | `1000f1c` and others | ~20 | no |
| the base-road follow-ups | `8c927e6`, `3fb98ef` | 2 | no |

Main to sweep: 85 files, +7,298 / −1,253. The message says 139 fixes. The table has 137 rows, and some
of its "change" cells stop mid-sentence (F48, F140 and F22, for example).

## Findings, ranked

### 1. Rot Ridge is re-skinned: its wilds and props fall back to other maps' sets (reasoned from source; not rendered)

`MapData.lua:72` switches Rot Ridge's `terrainMaterial` from `Rock` to `Limestone`. The commit is `f099fde`,
from teambase-v2 ("Terrain: smooth the ground vehicles drive on"), and the goal is a smoother surface for
vehicles. Two places pick a map's content by that material and have a Rock entry but no Limestone one:

- `MapWilds.lua:1818`: `PROFILES[preset.terrainMaterial] or PROFILES[Enum.Material.Grass]`. `PROFILES`
  has no Limestone key, so Rot Ridge now gets the **Grass** profile: oak, birch and spruce woods, cabins
  and lean-tos, ferns and meadow flowers. Before, it had the Rock profile (`MapWilds.lua:1668`): spruce
  woods, bothies, slate shelters, cairns and heather. Density changes too (Rock has `fillTo 0.93`,
  `flatScale 1.8` and `shelterScale 1.3`; Grass has `fillTo 1.0` and neither scale).
- `MapDecor.lua:2901`: `elseif ground == Enum.Material.Rock then` (pines and rocks) is never reached, so
  Rot Ridge's props come from the default mix of round trees, pines and bushes.

`ParkingLots.lua:534` was updated to accept Limestone; these two weren't. The map's own description
(`MapData.lua:66`) is "Rocky highland basin". The fix is either to add Limestone to both tables or to look
up the old profile for this map. That's the build machine's or Oliver's call.

Measured next to it: `car_placement_check` now finds a static car standing in open country on this map,
`RotRidge/2 stray static CrocodiloRanger at (110, -42): not on a street, bay, driveway or road verge`.
The same seed is clean on main. We didn't find the cause. The new wilds and props change everything built
after them, so they are the likeliest suspect.

### 2. Map building: a car park in a river and a static car in open country, on seeds clean on main (measured)

- `parking_lot_check` on the sweep: `SahurSprings/3 Brainrot Borough paved angled car park at (501, -23)`
  is `in the river`, `runs past the end of its street`, and its way in `has a kerb, pavement or curb
  across it`. On main, all 20 maps are clean.
- `car_placement_check` on the sweep: the Rot Ridge car above (violations `surface 1`). On main, 0.

Candidate causes in the diff, none isolated: hills are now planned before the relief (`MapGenerator.lua:808`,
`MapTerrain.PlanHills`), `MapTerrain.River` no longer re-plans a river it was given no plan for, pads
aren't flattened over another pad's ground, the Limestone switch, and the wider road banks in
`RoadNetwork.lua:1690`. Whatever the cause, these are the kind of fault players see.

### 3. `base_vehicle_respawn_check` fails at seed 9 on the sweep and passes on main (measured)

```
FAIL seed 9: the abandoned vehicle was replaced early
FAIL seed 9: abandoned: 8 replacements, want 7 in all
```

The 1000 message says this "was already failing before the sweep". Against main `d1e4f73` it wasn't:
main passes all 12 matches, and so does `--plant` (13/13). On main, a base has 6 vehicle slots. The sweep
has 7 (`MatchConfig.lua:241`, one more `"car"`). The check's scripted losses (`tools/base_vehicle_respawn_check.py:170-222`)
put two of team 2's vehicles away from home on purpose. Before the abandoned one is due, the tick replaces
one of team 2's vehicles early (8 replacements, want 7). Either the seventh bay at seed 9 counts as lost
at once, or the check's expectations need the extra slot. We didn't isolate which. The fix belongs to
whoever owns the seventh slot.

### 4. Four rows marked "fixed" don't change the game (reasoned from source)

| row | what the table says | what the code does |
|---|---|---|
| F112 (`GamepassConfig.lua:409`) | fixed | `Outclassed` gained a fourth argument, `permanent`. Its only caller (`MenuClient.client.lua:2487`) still passes three, and no server code sends `permanentPasses`, so the new branch never runs. The other two halves are unacted cross-file notes 1-3 under "GamepassConfig.lua". |
| F76 (`ProgressionPanel.lua`) | fixed | `ProgressionPanel.SnapshotArrived` (`ProgressionPanel.lua:93`) is never called. The note says MenuClient's `applyProfile` must call it, and it doesn't. The old first-render stamp still sets the countdown. |
| F48 (`ProjectileService.lua:853`) | fixed | Its own change text says "Only this file's part is done; the main trigger is still open": a release that `WeaponService.StartUse` refuses still leaves the cook armed. |
| the TradeService row (re-asks `IsBusy`) | fixed | `eitherBusy` asks the same `TradeService.IsBusy`, which is still `MatchService.IsAlive` (`Bootstrap.server.lua:1161`). That is false for everyone while a match is Loading, and for a downed player in a respawn mode, which are the windows the row names. A session opened then now closes at the first offer or confirm once they're alive, so it's a partial fix. |

Of the 107 cross-file notes, several were acted on after all: F32's `Life:atRemoved`, the self-hit
marker guard, the PlaceInLobby boon health, and the verify.py `eliminate` anchor (verify passes now).
Others weren't (above, and the rows in finding 7). The heading "not acted on" is no longer accurate
either way.

### 5. Gameplay changes in version 8 that Oliver may not know about (read from source; none measured in play)

None of these is a bug. Each one changes play.

- **Bots restart their reaction delay on every change of target** (`BotService.lua:3236`,
  `bot.acquiredAt = 0` when `bot.target ~= target`). Before, it restarted only after a think with no
  candidate. In a crowd, a bot switching from one enemy to the next now waits its reaction time again.
- **Terrain stops noclip rounds** (`CombatService.lua:1000`). Before, a noclip round passed through
  terrain along with every other map part.
- **Battle-royale bots never man a vehicle's gun, and leave one they are on** (`BotService.lua:3773`,
  `gunnerThink`). Oliver asked for this. The open item he already has goes with it: a bot driver of an
  armed car still waits up to 25 s for a gunner.
- **Anyone up to 30 studs below an objective counts for the capture**, where before it was 6
  (`ObjectiveZone.lua:49`, `Below + DigDepth`). It's meant for craters. Anything else inside the ring and
  under objective A's keep floor counts too.
- **The vendor's AMMO REFILL is a dead button** (`VendorService.lua:36`). `GiveAmmo` always returns false
  now (`WeaponService.lua:1822`), so it always refuses with "Your ammo is already full (or you have no gun
  to refill)". Nothing is charged. The fixer's note says to remove the row.
- **Shield Up and Bounty Rush are gone from the team modes** (`GameModes.lua:207`).
- **Seven base vehicles, not six** (`MatchConfig.lua:241`). **Base chests go from 14 to 20**
  (`LootService.lua:803`; the comment above it still says 14).
- **Team compounds search 144 site pairs, where main searched 48** (`ModeTeams.lua:207`, `:397-398`). It's
  sliced at 1/30 s a slice (`:469-476`), so the server doesn't freeze, but team modes take longer to load.
  Not measured.
- **Bullet marks last 4 s**, then a 1 s fade (`CombatClient.client.lua:2033`). Oliver asked for this.

### 6. `clock_ratchet.py` fails on the sweep (measured)

`ModeTeams.lua is NOT on the baseline and now has 1 os.clock() deadline(s)`. It's `RankBaseAxes`' slice
budget (`ModeTeams.lua:469-476`). It measures CPU work in one frame, where `os.clock` is defensible, so
the baseline needs this site added, or the budget moves to `tick()`. This check isn't in the quality gate.

### 7. The quality gate: 9 red on main, 26 red on the sweep. What the new red is (measured)

Both trees ran the same gate: `quality_gate.py -j 8 -v --timeout-scale 2`, with our unmerged proof
harnesses copied into `tools/` on both (findtarget_equivalence, perf_bot_cost, loot_spill_proof,
awd_bugtest, ttk_bugtest, silly_explosions_bugtest, road_cars_proof).

- main `d1e4f73`: `190 checks, 9 failed, 1 skipped; planted faults 1039/1050 caught`
- sweep `cf35aa3`: `196 checks, 26 failed, 1 skipped; planted faults 1022/1044 caught`

Every check whose result differs:

| check | main | sweep | why |
|---|---|---|---|
| objective_zone_check | FAIL | pass | **fixed** by F175 |
| base_vehicle_respawn_check | pass | FAIL | **real or data**: finding 3 |
| car_placement_check | pass | FAIL | **real**: finding 2 (Rot Ridge stray car) |
| car_placement_check --plant | 11/11 | 9/11 | two plants no longer bite on the new maps |
| parking_lot_check | pass | FAIL | **real**: finding 2 (car park in the river) |
| parking_lot_check --plant | 27/27 | 26/27 | "no car ever backed in" MISSED on the new maps |
| foundation_check --plant | 11/11 | 9/11 | two door-rule plants MISSED (`door ... 0 -> 0`) on the new maps |
| roadkill_proof_check | pass | FAIL | **harness**: it never turns combat on, and DealDamage is now gated on `enabled` (`CombatService.lua:440`). With `CS.SetEnabled(true)` added in a scratch copy: 22/22 checks, 18/18 plants, and the damage table matches main to the digit |
| roadkill_check (+plant) | pass | FAIL | **harness**: its fake vehicle has no `rig.handling` (`onRoadkillReport` now reads `handling.topSpeed`, `VehicleService.lua:1209`), and its cut DealDamage has no `enabled` |
| explosive_ammo_check (+plant) | pass | FAIL | **harness**: it cuts `explode` out of ProjectileService without the new `forgottenMate` (`:371`), and DamageInRadius without the new `slotOf` |
| trial_guns_proof_check | pass | FAIL | **harness**: its cut `PlaceInLobby` now calls `CompanionService.BoonHealth` |
| road_cars_proof_check --plant | 9/9 | crash | **harness**: one plant's text (`damaged[key]`) is now `damaged[slot]`. With the KeyError guarded, the other six plants print CAUGHT. The check itself passes on the sweep |
| defense_anywhere_check | 12/12 | FAIL | **harness**: `planted fault did not apply (a bay's lane box missing): text not found` |
| silly_explosion_check (+plant) | pass | FAIL | **by design**: rule E is scoped to the silly-explosions branch, and every gameplay fix in the sweep trips it. The fixers' own notes say so |
| team_base_ruins_check --plant | 35/35 | 35/37 | "crate band out of its pool" MISSED (the tail shows only that one) |
| team_base_road_check --plant (new) | — | 9/11 | **matters**: see below |

The rest of main's 9 red checks are red on the sweep too, with the same results: bot_driving_sim (the AWD
split, PR #49), car_bounce_audit_sim, findtarget_equivalence (expected off its branch),
vehicle_models_runtime_check, shed_loot_check (the gate calls it with no `root`; run by hand it passes on
both trees), and the roads_check `--plant` timeout.

**`team_base_road_check` reports "0 problems", and that result doesn't cover fairness.** Its plants "an
unfair pair" and "the arena's cut roads left open" are both MISSED, so it can't see the unfairness the
0830 handoff measured in Studio (27-47% on 4 of 10 map-seeds).

In short: 3 of the new red checks are real map faults (findings 2 and 3). 8 are harness drift that the
fixers' own notes mostly predicted. 5 are plants that no longer bite on changed maps. So the gate's
planted-fault guarantee has holes in `car_placement`, `parking_lot`, `foundation`, `team_base_ruins` and
`team_base_road`.

## What holds (measured, same harness on both trees)

- **Roadkill**, player and bot drivers, through the real VehicleRoadkill report, which now carries F118's
  `reportPlausible` (`VehicleService.lua:1140`, `:1213`): 22/22 checks and 18/18 plants, with combat
  enabled as a live match has it. Every model's top-speed damage matches main exactly (for example,
  BrrStreetfighter 135.13, CameloCarrier 66.24).
- **Loot spill** (#85): 14/14 plants. Only the counts of the random rolls differ.
- **+25% TTK bug test** (PR #50): the output is the same line for line, so the bugs it measures are
  still there. The companion DoT is still scaled twice, and a thrower who has left still deals unscaled
  damage to people.
- **Silly-explosions bug test** (PR #48): 20/20 plants; only line numbers moved.
- **Bot tick cost** (`bot_lag_proof_check`, PR #43): no regression. The worst per-frame BotService
  instructions (kinstr) go from 193 to 185 at packed-50 and from 217 to 211 at stress-50. The small moves
  come from bots deciding differently (finding 5), not from new cost. The only lag work in the sweep we
  saw is the Dijkstra heap in `BotNav.DriveRoute`, which the harness doesn't cover.
- `verify.py` 3/3, `lua_static_check.py` 8/8, `balance.py` pass, on the sweep.

## How we triaged (what we read, by risk)

1. **Anything that could break a live server:** every changed server module was read in full diff:
   Bootstrap, PlayerData, TradeService, RewardService, BrainrotShopService, CrateService, CombatService,
   WeaponService, VehicleService, BotService, BotDriveTactics, BotNav, MatchService, GameMode,
   ProjectileService, HazardService, LootService, DestructibleService, CompanionService, CompanionBoons,
   MountedGuns, MovementService, LobbyService, AuraService, DropMapService, MapBuildings, MapGenerator,
   ParkingLots, RoadNetwork, MapWilds, ModeTeams, and the 2e6d846 parts of MapTerrain and TeamBaseRuins.
   For each new call we checked that the name exists and is in scope before its use, and for each
   yield where it runs. Checked in particular: `CompanionService.BoonHealth`, `applySpeed`, `NORMAL_GRAVITY`,
   `tagInMatch`, `concludeIfOver` and `noteIssuedKit` in MatchService; `BotService.Loot.wouldKeep`, `.dial`
   and `.rotateAt`, `StormService` and `stopFacing` in BotService; `RoadkillPass.BodyOf`, `SPEED_SLACK`,
   `hullDistance` and `rig.handling` in VehicleService; `forgottenMate` before `explode`/`burst`;
   `CombatService.IsEnabled`; `DefensePlacement.BodyOf`; `Rarity.IsAtLeast`; `cacheUntil` and `slotOf`;
   `Life:entryOf` and `DestructibleService.OnPartBroken`; the companion anchor, which is an Attachment,
   so `.WorldPosition` is valid; `MapTerrain.PadAt`. `RankBaseAxes` now yields. It runs inside
   `startMatch`, which is pcall'd, and a yield is allowed there.
2. **Player data and money:** the `releasing` flag and the BindToClose wait (PlayerData, Bootstrap), the
   CanSave gates (shop and global board), the crate pity fallback, the trade re-checks, and Settings'
   wait-for-load. A new player gets `data.Settings` from the defaults (`PlayerData.lua:72`), so the
   client's new "don't save until loaded" can't lock a new player out of saving.
3. **Gameplay changes** (finding 5): the DealDamage `enabled` gate (every caller runs in a live match;
   the practice dummies don't use DealDamage), GiveAmmo (the infinite pool is unconditional,
   `WeaponService.lua:1880`), setMassless (pcall'd, so it can't throw; not proven in Studio), and the
   claimPhysics seat rule (a bot-driven car stays server-owned, `VehicleService.lua:1574-1583`).
4. **Client:** UiParts.dialog (its one caller is MenuClient's SELL ALL), ProjectileClient's cook/cancel
   (the server's `pressed == false` path exists), MenuClient, MenuShell, VoteScreen, DropPicker,
   Settings, TeamPickerScreen, CombatClient, VehicleWeaponClient, MountedGunClient (the ShotFired argument
   order matches `CombatService.lua:393`), GunfireCue, MovementClient, VehicleClient, CrackFx, HudClient,
   ResultsScreen, StormClient, InventoryPanel, KillFeedback, CompanionAbilityIcon, EnemyAura, ExplosiveFx,
   BreakFx, GlassFx, DefensePreview, ProgressionPanel, CompanionFxClient and CosmeticPreview.

All 7 high and 40 medium rows were read against their diffs. The 90 low rows' files were read in the
same diffs for crash risk, but not checked row by row against each row's stated change.

## What we did NOT review or prove

- **`pc/teambase-v2` as a feature.** `TeamBaseRoads.lua` (1,223 new lines; only its header and
  whether it yields: it doesn't, and its planning runs unsliced inside Setup, not measured),
  `TeamBaseRuins.lua` beyond `2e6d846`'s 49 lines, and `MapTerrain.lua` beyond `2e6d846`'s 21 lines.
  The new tools weren't read: `ground_driveability_check`, `team_base_road_check`, `team_base_spawn_check`
  and `team_base_roads_probe.lua`. They were only run.
- **Nothing ran in Studio**, so none of these are proven: setMassless's kinematic joints with a bot
  gunner (Oliver's "falls to the ground and won't drive"), the phone COOK button on `KeyCode.World95`,
  the dialog closing, the EditableImage freeing, the wall-crack and bike-model reports, and anything drawn.
- **Rot Ridge's new look (finding 1) wasn't rendered.** The profile fallback is certain from the source.
  How much the map changes on screen is not measured.
- **The causes of findings 2 and 3 weren't isolated.**
- **The 88 "fixed" low rows weren't checked one by one** against their stated defect.
- **Performance at match start** (the 144-pair compound search, the access-road planner) wasn't measured.
- **The 107 cross-file notes weren't all checked**, only the ones named in finding 4.

## Evidence

- Gate outputs (not committed; they are 500 lines each): main `d1e4f73` and sweep `cf35aa3`, the
  command above, run one after the other (never two gates at once), 2,015 s and 2,190 s.
- Scratch harness changes that were run and then deleted, never committed: `roadkill_proof_check.py` with
  `CS.SetEnabled(true)` after `local CS = w.module("CombatService")`, and `road_cars_proof_check.py`
  with `o["max"]` guarded as `o.get("max", -1)`.
- `clock_ratchet.py` run by hand on both trees; `shed_loot_check.py .` run by hand on the sweep (`TOTAL
  failing checks: 0`).
