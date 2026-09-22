# Task 06 — the probes that cannot fail

An audit of this project's own test harness: every file under `tools/` that asserts anything, with
each check classified SOUND, CANNOT FAIL, STANDS IN WRONGLY or DEAD PLANT.

**Nothing in the game changed. Nothing in the harness changed.** This adds one tool
(`tools/probe_audit.py`) and this report.

---

## What was examined

| | files | checks |
| --- | --- | --- |
| Lua probes and galleries under `tools/` | 162 total, **109 assert something**, all 109 read by hand | tool: **943 check sites** + 36 that take no boolean to classify. Hand read: **~1,267 sites** |
| Python checkers under `tools/` | **13** | **274 assertion sites**, and **228 regex sites executed and counted** over the real project |
| **Total read** | **122 asserting files** | **1,217 check sites** by the tool's count, **~1,540** by hand |

The tool counts are from `python tools/probe_audit.py .`, not estimated. The hand counts are per
group, listed in the Lua section below, and are higher because the hand read also counts
`table.insert(problems, ...)`, inline `PASS`/`FAIL` expressions, bare `assert` and self-test verdict
lines. The 36 unclassifiable sites are calls to helpers with no boolean parameter
(`checkWalks(folder)`, `checkTrunk(folder)`); they were read by hand instead of by condition text,
and they are counted separately rather than quietly folded in.

The 109 Lua files were read against the game modules they stand in for. Where a probe copies a
formula or a constant from the game, the copy was compared with the original and the result is
stated either way. The findings are ordered by what each check protects, worst first, with the Lua
harness first because that is where the game is actually tested.

Seven of the thirteen Python checkers were **executed** with an instrumented `re` module, so every
regex in them is reported with how many times it was tried, how often it matched, and how large the
input was. The other six write files into the tree (`menu_hud_audit.py` and `brainrot_asset_audit.py`
are generators; three are builders; one updates a baseline), so they were read rather than run.

**None of this needed Studio.** Every class in the brief is decidable by reading, and the three
findings below that are proved rather than argued were proved by planting a fault in a scratch copy
of the tree (`git archive HEAD | tar -x -C /tmp/...`) and running the real checker over it. The
repo was never written to.

---

## Findings, worst first

## The Lua probes and galleries

109 files, read by hand in five groups (economy and save data; combat and guns; movement, vehicles
and companions; HUD, menu and admin; world, models and audits). Every group read the game module a
probe stands in for before calling it a stand-in. The counts per group:

| group | files | check sites read | flagged |
| --- | --- | --- | --- |
| economy, crates, save data | 16 | 437 | 0 |
| combat and guns | 25 | 220 | 3 |
| movement, vehicles, companions | 21 | 204 | 1 |
| HUD, menu, admin | 21 | 341 | 6 |
| world, models, `audit_*` | 26 | ~65 | 4, plus one retired file |
| **Lua total** | **109** | **~1,267** | **14** |

The hand counts and the tool's 943 differ because they count differently: the tool counts calls to a
check-shaped helper; the hand read also counts `table.insert(problems, ...)`, inline `PASS`/`FAIL`
expressions, `assert(...)` and self-test verdict lines, which is what the brief means by "asserts
anything". 24 of the 26 world files were read end to end; `audit_roads.lua` (self-retired) and
`brainrot_art_compare_gallery.lua` (both self-tests and the security scan read; the trailing render
views not) were read in part, and the table says so rather than rounding up.

**No DEAD PLANT was found in any group.** Every plant in this harness that was read is aimed at an
invariant and fabricated fresh each run. The four classes below are CANNOT FAIL and STANDS IN
WRONGLY only.

### 1. `tools/enemy_aura_gallery.lua:93-101` — CANNOT FAIL, and the check it claims does not exist

**Protects:** the one line that keeps the enemy-aura Highlight from drawing through walls
(`DepthMode = Occluded`). The file's own header calls the alternative "a wallhack, handed to
everyone." This is the fairness bug, not a cosmetic one.

**Evidence:**

```
19  -- It also reads StarterPlayerScripts.EnemyAura's own source and asserts the line is there, so the
20  -- picture and the shipped script cannot drift apart.
93  local occluded = string.find(text, "DepthMode = Enum.HighlightDepthMode.Occluded", 1, true) ~= nil
94  local assignsTop = string.find(text, "DepthMode = Enum.HighlightDepthMode.AlwaysOnTop", 1, true) ~= nil
100 note(string.format("EnemyAura source: assigns Occluded = %s, assigns AlwaysOnTop = %s (want true / false)", ...
```

and the shipped script this reads:

```
StarterPlayerScripts/EnemyAura.client.lua
8   -- only line that matters here is `DepthMode = Occluded`, and it is asserted in
9   -- tools/enemy_aura_probe.lua rather than trusted.
```

**Why it cannot fail:** both booleans are computed correctly and then handed to `note`, which is a
`print`. No value of either can fail the gallery. The shipped script says the assertion lives in
`tools/enemy_aura_probe.lua`; **no such file exists** in `tools/`. Two comments in two files describe
an enforced check that has never existed. Delete the `Occluded` line tomorrow and a picture renders,
a note prints, and nothing fails.

**To make it sound:** turn the two `string.find` results into a `check`/`assert` in this file, or
write the `enemy_aura_probe.lua` the shipped source already promises.

### 2. `tools/hud_overlap_probe.lua:361-414` — CANNOT FAIL on the real overlaps

**Protects:** HUD elements overlapping each other, Oliver's #80/#86. The file's own header says
it replaced `menu_hud_audit.py` because that tool could not see every participant, and the bug
reached Oliver once already.

**Evidence:**

```
373   if ox > 0 and oy > 0 then
375       table.insert(isDemo and demo_pairs or pairs_found, { a.name, b.name, math.floor(ox), math.floor(oy) })
383   totalPairs += #pairs_found
386   table.insert(reportLines, string.format("[HUD_OVERLAP] %s: %d elements, %d overlapping pairs", passKey, liveCount, #pairs_found))
409   assert(#hardFailures == 0, ...)
414   assert(faultSeen[passKey], "[HUD_OVERLAP] planted fault NOT reported at " .. passKey .. " -- the checker is blind")
```

**Why it cannot fail:** `pairs_found` and `totalPairs` are the whole point of the file and nothing
compares either to anything. The only two asserts are that no pass crashed and that the planted
box on the minimap was seen. The plant proves the detector can see an overlap; it does not make the
file fail when a real one exists. A new overlap between two real HUD elements prints
`N overlapping pairs` exactly like a clean run, and a human has to notice N is more than one.

**To make it sound:** after the plant is confirmed, assert per pass that `pairs_found` holds exactly
the planted pair and nothing else, and print the extras in the assert message.

### 3. `tools/audit_lobby.lua:260-386` — CANNOT FAIL: the measurement is defined and never called

**Protects:** buried set-piece parts, off-mirror twins and off-base pieces in the lobby. The header
says the file is "Built on the tools/audit_models.lua measuring code (copied in; keep the two in
step)", so a reader expects the lobby gets the same three checks every model family gets.

**Evidence:** `analyze` is defined at line 260 with `report.mirror` (320), `report.buried` (345)
and `report.base` (381). `grep -n "analyze(" tools/audit_lobby.lua` returns one line: the
definition. The real sweep starting at line 388 does its own `components`, `seeThrough` and
`ZFight.Scan`, none of which looks for a buried, off-mirror or off-base part.

**Why it cannot fail:** not a weak filter. The check has no execution path.

**To make it sound:** call `analyze` per structure in the sweep and print its three lists the way
`audit_models.lua` does, or delete `analyze`, `inside` and `samplePoints` and correct the header so
it stops promising coverage the file does not have.

### 4. `tools/audit_eggs.lua:69-146` — CANNOT FAIL: the instrument is proved, the reading is never judged

**Protects:** every Easter egg and the obby sitting on the terrain: not buried, not sunk, not
floating, not in water. That is the file's whole stated purpose.

**Evidence:** the only `PASS`/`FAIL` in the file is line 73, the water-detector self-test. Lines
131-133 accumulate `totals.buried`, `totals.sunkWorst`, `totals.floatWorst` and `totals.wet`, and line
145 prints them in a SUMMARY. No threshold, no check.

**Why it cannot fail:** the self-test proves the water raycast can see a planted pool. Nothing then
compares any egg's numbers to anything. An egg half-buried after a terrain change prints a number
and the file exits clean. The `no EasterEggs on the map` branch at 76-77 is the same shape one level
up: a renamed container is a printed note.

**To make it sound:** `check(totals.buried == 0, ...)`, a sink/float ceiling, `check(totals.wet ==
0, ...)`, and a RESULT line like every other `audit_*` in the folder.

### 5. `tools/loot_zfight_probe.lua:94-105` — CANNOT FAIL: a self-test with no verdict

**Protects:** the loot z-fight scanner catching flush parts on dropped weapons and consumables.
The file exists because the scanner once "stopped scanning the guns on weapon pickups" (line 2).

**Evidence:**

```
17  local function out(text)
18      print("[PROBE] " .. text)
96  out(string.format("  %s: %d fighting pairs found (want > 0)", entry.label, involving(withPlanted, entry.part)))
103 out(string.format("planted parts removed: flush %d (want %d)", #ZFight.Scan(lootRoots), #baseline))
```

There is no `check`, `assert`, `expect` or inline PASS/FAIL anywhere in the 105 lines.

**Why it cannot fail:** the pass condition is written in English inside the print. `involving` can
return 0 for both plants and the file prints `done`.

**To make it sound:** wrap lines 96 and 103 in a `check` that counts failures, and end with a
RESULT line.

### 6. `tools/display_paths_probe.lua:163-243` — CANNOT FAIL: three real paths, four return values, all discarded

**Protects:** a gun's ground pickup and podium display matching the reference build part for
part, on the three production paths the header names: `WeaponService.BuildGunModel`,
`LootService.DropWeapon` and `LobbyService.Build`'s podium after the lobby z-fight pass.

**Evidence:**

```
154   local missing, moved, _, resized = compare("SELFTEST", id, parts, ref, CFrame.identity)
167   compare("build", id, baseParts(model), refs[id], CFrame.identity)
195   compare("floor", id, baseParts(base), refs[id], ...)
243   compare("podium", matched, placed, refs[matched], ...)
```

**Why it cannot fail:** `compare` returns `missing, moved, turned, resized`. The self-test at 154
reads them and prints ok/FAILED (and gates nothing). The three real loops at 167, 195 and 243, over
every gun in `WeaponData.Weapons`, discard all four. `compare` itself only calls `out`, a print. A
gun drifting on any real path prints a line and the probe finishes clean.

**To make it sound:** total the four counts across the three loops and assert each is zero at the
end, per path.

### 7. `tools/road_audit_all.lua` "network:" line, via `RoadNetwork:Audit` — CANNOT FAIL at a curve. Outside the brief; reported, not fixed

**Protects:** every town's streets and inter-town roads forming one connected, gap-free surface.

**Evidence:**

```
tools/road_audit_all.lua
18    local SURFACE = { RoadSurface = true, BridgeRoad = true, JunctionAsphalt = true, Asphalt = true, RoadCurve = true }

ServerScriptService/Modules/RoadNetwork.lua
1943  curveBand(model, curve, pieces, ..., "RoadCurve")
2149  local SURFACES = { RoadSurface = true, BridgeRoad = true, JunctionAsphalt = true, Asphalt = true }
2264  local function surfaceTop(x, z)
2268      if p:IsA("WedgePart") and math.abs(cf.XVector.Y) > 0.9 then
```

**Why it cannot fail:** the game builds parts named `RoadCurve` (1943). `RoadNetwork:Audit`'s own
`SURFACES` (2149) and `ROAD_PARTS` (2151) do not list it, so no curve part enters the grid the
gap/step/ground pass walks. The `WedgePart` branch at 2268, written for curve wedges, is
unreachable: its input is filtered out one step earlier. `road_audit_all.lua`'s own sampling
includes `RoadCurve` and is unaffected, but it prints `info.roads:Audit(map).summary` as the
"network:" line with no cross-check. A fault whose only symptom is at a curve is invisible there.

**To make it sound:** one line in `RoadNetwork.lua`, not in `tools/`: add `RoadCurve = true` to
`SURFACES` and `ROAD_PARTS`. That file belongs to the roads tab. On the probe side,
`road_audit_all.lua` could diff the name set `RoadNetwork:Audit` walks against its own `SURFACE`
table and warn on a mismatch.

### 8. `tools/vehicle_probe.lua:458-465, 492-493, 513-519, 546-549, 629-630` and `tools/vehicle_gallery.lua:887-938` — STANDS IN WRONGLY: the terrain is read back before it exists

**Protects:** five terrain lanes of the vehicle course: grade climb, side slope, bump field, road
surface and parked-on-a-slope. The spawn height, and for the grade tests the pass threshold
`topPoint.Y`, come from the read-back.

**Evidence:** `terrainSlab` (100) calls `workspace.Terrain:FillBlock`; `terrainTopAt` (106) raycasts
the same terrain. At each of the five sites the two are adjacent with no `task.wait` between them.
Every `task.wait` in the file was listed; the nearest after each site is inside `spawnDriven`, which
runs after the height has been used. `vehicle_gallery.lua` does the same at 888-892 (`buildVerge`
fills) then 938 (`terrainTopAt`).

**What differs:** `COORDINATION.md:975` records the trap in the project's own words: "A fresh
terrain write is not raycastable for a frame or so. A gallery measuring immediately reported 38
studs of spread on a pad the next screenshot showed dead flat." `terrainTopAt` falls back to
`fromY` on a total miss and says so, but the recorded failure was a hit at the wrong height, which
leaves no trace. `mapvehicle_probe.lua` (`task.wait(0.5)` after its one fill) and
`parkour_probe.lua` (`{ wait = 1 }` on its terrain ledge) already do this right.

**To make it sound:** a `task.wait()` between each fill and the `terrainTopAt` that reads it, in
both files.

### 9. `tools/sight_probe.lua:18-22` and `tools/sight_align_probe.lua:22-27` — STANDS IN WRONGLY: two drifted copies of a table that no longer exists

**Protects:** which part of a gun is the rear aim reference, and so whether a front post floating
above or below it would ever be flagged.

**Evidence:** both files say `-- Kept in the same order and with the same offsets as SIGHT_PARTS in
CombatClient`. `grep -rn SIGHT_PARTS` outside `tools/` returns nothing. Aim alignment now lives in
`Viewmodel.lua` and reads the `KP_Sight` attribute. `GunModels.lua:3326-3331` builds a part named
`AimPoint` at the KP_Sight position "for anything still looking for it", which is these two files.
`sight_align_probe.lua` lists `AimPoint` first; `sight_probe.lua` never got it.

**What differs:** `sight_probe.lua` walks its list with `FindFirstChild(name, true)` and takes the
first hit, so it anchors on a cosmetic `RearSight` or `Rib` (real parts, `GunModels.lua:615, 1412,
1732`) with no defined relationship to the aim line. Its `missing`/`frontOnly` sorting is built on
that. `sight_align_probe.lua` resolves the right part but compares raw world Y/X (line 88), and its
own header (13-14) admits the error this adds on turned receivers. `ads_align_probe.lua` already
does the same comparison in the sight line's local frame, with five planted faults.

**To make it sound:** retire both in favour of `ads_align_probe.lua`, or at minimum add `AimPoint`
to `sight_probe.lua` so the two copies agree.

### 10. `tools/hud_overlap_probe.lua:100-123` — STANDS IN WRONGLY: the desktop pass is hand-typed literals with no tie back to the source

**Protects:** the 1920x1080 pass of the same overlap audit: 15 HUD elements plus the mode
scoreline.

**Evidence:** the two phone passes `require` the real `PhoneLayout` and call `Rects()`/`Place()`;
the header says this is deliberate so the maths cannot drift. The desktop pass is a `DESKTOP` table
of positions and sizes typed from `HudClient.client.lua`, each with a `cite` comment. There is no
`string.find` against `HudClient.Source` anywhere in the file.

**What differs:** every citation matches today (banner, health panel and hotbar spot-checked). Edit
one UDim2 literal in `HudClient.client.lua` and the probe keeps computing from the old numbers and
keeps passing. `hud_ux_probe.lua`'s `phone` section already verifies its transcribed literals
against the source with `string.find`.

**To make it sound:** the same source check `hud_ux_probe.lua` uses, so an edited literal fails
this probe instead of leaving a stale comment.

### 11. `tools/range_probe.server.lua:96` — CANNOT FAIL: the value it reads cannot move

**Protects:** the range's safety promise that a shot can only hit a tagged practice dummy, never a
bystander. `RangeService.lua`'s header calls this "structural rather than conditional."

**Evidence:**

```
46   bystander.Name = "NonTargetBystander"
52   local hum = Instance.new("Humanoid"); hum.Parent = bystander
96   check(hum.Health == 100, id .. " cannot damage bystanders")
```

**Why it cannot fail:** `RangeService.Fire` never calls `CombatService.DealDamage`. Its only damage
path is `PracticeDummy.Hit` (`RangeService.lua:158`), which returns `0, false, false, false` for
any body without a registered `DummySite` (`PracticeDummy.lua:333-336`). The bystander has none. So
even if the raycast filter regressed and the ray hit the bystander, `hum.Health` stays 100. The line
two above it, `check(hits - priorHits == (def.pellets or 1), ...)`, with the bystander on the
boresight 20 studs out, is the check that actually proves the ray passes through the untagged body.

**To make it sound:** drop the line, or make it observe what it names: wrap `PracticeDummy.Hit` for
the test and assert it is never called with a part of `bystander`.

### 12. `tools/menu_cursor_probe.client.lua:33, 43` — STANDS IN WRONGLY: the seed is a state no client reaches

**Protects:** `MenuCursor.client.lua` restoring `MouseIconEnabled` to what it was before a menu
opened.

**Evidence:**

```
33   Input.MouseIconEnabled = false
35   player:SetAttribute("MenuOpen", true)
41   player:SetAttribute("MenuOpen", false)
43   if Input.MouseIconEnabled then failures += 1; warn("[CURSOR] previous icon not restored") end
```

**What differs:** `grep -rln MouseIconEnabled` over the shipped Lua returns one file:
`MenuCursor.client.lua` itself. Nothing in the client ever sets it `false`, so `previousIcon` is
always `true` in real play and the restore this exercises, restoring a captured `false`, cannot
occur. This is the brief's cursor calibration example, still in the tree. The mechanism is real and
does run; the input is not one the game produces.

**To make it sound:** drop the seed and assert the restore is an identity on whatever the value
is, or keep the seed and say in a comment that it tests the general case, not a reachable one.

### 13. `tools/orphan3_render_gallery.lua:176-186` — CANNOT FAIL: named `assertInFrame`, returns a note

**Protects:** the companion and owner rig landing inside the camera frame in the #67 before/after
renders.

**Evidence:** `ok` is computed at 182, passed to `note` at 183, returned at 185. All four call
sites (209, 213, 238, 242) discard the return.

**To make it sound:** collect `ok` at each call and `check` it at the end of the view, as
`vote_drop_gallery.lua` and `arena_gallery.lua` do with their own helpers.

### Retired, would mislead if run: `tools/audit_roads.lua`

Line 1 says `SUPERSEDED (2026-09-17), DON'T RUN` and points at `road_audit_all`. Not counted above.
Filed because line 9 still carries a `runtest.ps1 -Probe` invocation and the file would print a
plausible clean result: its `SURFACE` filter at 37 is `{ Road, Junction, Asphalt, BridgeDeck }`, and
only `Asphalt` survives in `RoadNetwork.lua:2149`. The self-test at 405-417 draws its victim from the
same empty set and takes the "nothing to test against" branch. Delete it or move it out of
`tools/`. `tools/crown_gallery.lua` is the same shape (superseded by `accessory_gallery.lua`, no
checks) and was not assigned to a group for that reason.

### Lower-severity notes from the read, not filed as findings

* `audit_models.lua:784-800` and `audit_brainrots.lua:777-794`: the `EXTRAS` list comes from a
  pattern over `BrainrotModels.Source` and falls back to a fixed 38-name `EXTRAS_KNOWN` if that
  yields nothing. The pattern currently finds about 90 names, so the primary path is the more
  complete one. The fallback prints nothing when it fires, so a run in that state would silently
  test around 50 fewer extras. The comment near line 448 still says "all 38 extras".
* `audit_buildings.lua`: two detectors (wall holes, stair tops blocked) are proved by planting;
  the other dozen-plus per-map metrics have no plant and no aggregate RESULT. The header frames it
  as a measure tool with reference numbers for a human to diff, which is why it is not filed.
* `audit_statesync_push.lua`: `coalesced = requestedInFrame > builtInFrame or requestedInFrame <= 1`
  can pass through the `<= 1` arm without exercising coalescing. Whether it does depends on
  QuestData's daily generation for the stand-in profile, which was not resolved. Open question.
* `merge_probe.lua`'s trade section reproduces `TradeService.execute`'s `move()` by hand instead of
  firing the real remotes. Read side by side (`TradeService.lua:267-276`), it is the same two lines
  today. It is the one place in the economy group where a future guard added to `move()` would not
  be exercised.
* `audit_models.lua` and `audit_brainrots.lua` ship with `landmarks` and `eggs` commented out of
  `FAMILIES`. Visible, not hidden, but nobody running either file as documented runs those two.

### Lua files read and found sound

The whole economy and save-data group, 16 files and 437 check sites, with nothing to flag:
`progression_probe`, `progression_runtime_probe`, `progression_width_probe`, `playerdata_probe`,
`monetization_probe`, `receipt_probe`, `style_crate_probe`, `crate_gallery`, `crate_card_gallery`,
`merge_probe`, `merge_gallery`, `trade_double_confirm_probe`, `beginner_probe`,
`parachute_shop_probe`, `cosmetic_preview_probe`, `ratelimit_probe`. Nearly every one carries its own
control: a hand-written pre-fix module that must fail, a planted wrong-luck odds table that must be
rejected, a refund count that must be zero so a shrunk sample cannot pass, an `os.clock` swap that
must break the timing check. `playerdata_probe` runs two copies of the real `PlayerData` source over
one stub DataStore so cross-server locking is real. `trade_double_confirm_probe` swaps exactly two
remote calls in the real `TradeService` source, refuses to run if the count is not two, and drives a
real race.

Combat and guns, 23 of 25 clean, one of them apart from a single line: `arsenal_probe`, `ads_align_probe` (five planted faults, each
caught and then removed from the real list), `ads_hands_probe`, `arms_clear_probe`,
`combat_state_probe` (runs the old rule and requires it to fail the rows the fix was for),
`driver_fire_probe`, `ground_gun_probe` (eight plants), `gun_anim_probe`, `gun_contact_probe`,
`gun_flush_probe` (a report tool, asserts nothing and does not claim to), `gun_gaps_probe`,
`gun_hold_probe` (its `PALM_SINK_MM = 14.5` checked against `Viewmodel.lua`'s `HAND_SINK = 0.055`
over `StudsPerMillimetre = 0.0038`, not drifted), `hand_grip_probe`, `grip_junction_probe`,
`projectile_probe` (five plants; its stand-in rig was checked against `ProjectileService.exposure()`,
which reads only head and root), `range_probe.client`, `range_probe.server` apart from line 96,
`recoil_probe`, `shotgun_range_probe` (its `applySpread` compared line by line with
`CombatService.applySpread`, identical), `sight_kick_probe`, `wallscan_probe`,
`crouch_accuracy_probe`, `audit_guns_zfight`.

Movement, vehicles and companions, 19 of 21 clean: `movement_probe` (its feet formula matches
`Parkour.lua:83-95`; two "samples > 0" guards on the sanity checks), `parkour_probe` (waits a second
after its terrain fill), `crouch_probe` (its formula matches `MatchService.lua:665-669`, and it
walks a real rig through a doorway rather than trusting the arithmetic), `climb_gallery` (a
negative control on a known-good ledge, "THE TEST PROVES NOTHING" if a rig cannot stand there),
`parachute_probe` (three plants, one two-sided), `vehicle_api_probe`, `vehicle_health_probe` (every
damage check paired with a no-damage case; forces a GC inside the debounce window),
`mapvehicle_probe`, `mapvehicle_physics_probe`, `mechanism_probe`, `bot_probe` (measurements for a
human, with two explicit "or this test proves nothing" controls), `companion_probe`,
`companion_offset_probe` and `companion_offset_gallery` (their camera constants checked against
`CombatClient.client.lua:133-138` and `Settings.lua:49`, all match), `companion_compile_probe`,
`accessory_probe` (its own header names and fixes the rod-audit shape from the brief),
`status_effects_probe`, `floating_tube_probe` (two-sided plant), `potion_clip_probe` (every constant
checked against `CombatClient.client.lua:1533, 1648-1650, 1672-1673`).

HUD, menu and admin, 16 of 21 clean: `hud_ux_probe` (127 sites; every comparison loop guards its
sample count, and the `touch` section drives the same `_Press`/`_Release` the real handlers call,
`TouchControls.lua:356-361, 519-532`), `menu_shell_probe`, `drop_cursor_probe`,
`hands_free_cursor_probe`, `vote_drop_gallery`, `arena_gallery`, `mode_probe` (every detector run
on real input and then on broken input), `admin_probe` (gates checked against the real remote
handler, `AdminService.lua:174-195`), `admin_fly_probe`, `admin_powers_probe`, `compile_probe`,
`runtime_script_probe`, and the three pure galleries `hud_overlap_gallery`, `controls_hint_gallery`,
`phone_reach_gallery`, which claim nothing. `anim_probe` is an id-discovery tool with no pass/fail.

World, models and audits, 22 of 26 clean, one of them apart from the dependency above: `brainrot_models_probe` (coverage gated on
`totals.models == #BrainrotData.Types`), `map_fingerprint_probe` (guards the two-failed-builds-hash-
the-same case by name), `road_floaters_probe` (prints its skip list with counts every run),
`mapplan_probe` (a vacuity guard on archetype spread and a planted wrong reference), `eggs_gallery`,
`road_gallery`, `wilds_landmarks_probe` (five plants in one landmark; forces a GC to falsify a
weak-table cooldown), `town_themes_probe` (six plants), `wilds_map_probe`,
`brainrot_art_compare_gallery` (planted builder failure and planted backdoor, both graded),
`road_audit_all` apart from the dependency above (three plants through the same functions the real
map uses), `building_gallery`, `audit_models` and `audit_brainrots` (an eight-case shape self-test),
`audit_defenses` (its `IDS` list checked against `DefenseService.lua:243-245`, complete),
`audit_model_gaps`, `audit_animated_collision`, `audit_statesync_push` (with the open question
above), `audit_supplydrop_staged`, `audit_loot_resettle` (its name filter checked against
`LootService.lua`, complete; prints INCONCLUSIVE on a short sample), `audit_glass_gallery`,
`audit_buildings`.

---

## The Python checkers

### 1. `tools/verify.py:436-439` — CANNOT FAIL, on the only route that matters

**Protects:** Beginner's Luck charges — free boosted crate opens, held in saved player data. The
comment above the check states the rule it enforces: *"Nothing may ever raise the charge count
outside the one-off grant."* A second grant is the paid Crate Luck pass given away for free, written
to the profile.

**Evidence:**

```
433  for _bl_rel, _bl_text in lua_files():
435      if _bl_rel.endswith(("PlayerData.lua", "ProgressionData.lua", "CrateData.lua")) or ...: continue
436      for _bl_write in re.findall(r"beginnerLuck[^\n]*", re.sub(r"--[^\n]*", "", _bl_text)):
438          if re.search(r"beginnerLuck\.left\s*(\+=|=[^=])", _bl_write) and "-= 1" not in _bl_write:
439              problems.append(f"{_bl_rel}: writes Beginner's Luck charges ...")
```

**Why it cannot fail:** line 436 only ever hands line 438 lines containing the literal text
`beginnerLuck`, so a write through a local alias is never examined. That is not a hypothetical
shape. It is how the legitimate grant itself writes the field, in a file this sweep **does** scan:

```
ServerScriptService/Modules/CrateService.lua
65      local beginner = progression.beginnerLuck
72      beginner.left = CrateData.BeginnerCrates
```

Line 65 reaches the guard and shows it the bare word `beginnerLuck` with nothing after it. Line 72
is the actual write and does not contain the string at all, so it is never looked at. **The check
passes on the one file in the project containing the write it exists to police**, and the shape it
is blind to is the shape any copy-paste of that grant would take.

Traced over the whole project, the site makes 3 attempts on strings of 12 to 23 bytes and matches
none of them, every run.

**Proved by planting, both routes, in a scratch copy:**

```
plant A, direct   data.Progression.beginnerLuck.left = 99
  -> RewardService.lua: writes Beginner's Luck charges (beginnerLuck.left = 99); only the
     one-off grant may, and opens may only spend one

plant B, aliased  local beginner = data.Progression.beginnerLuck
                  beginner.left = 99
  -> (nothing. verify.py stays green)
```

**To make it sound:** resolve the alias. Collect the names bound to the field, then look for writes
through those names in the same file:

```python
for _alias in re.findall(r"local (\w+)\s*=\s*[\w.]*\bbeginnerLuck\b", _bl_text):
    ... re.search(rf"\b{_alias}\.left\s*(\+=|=[^=])", _bl_text) ...
```

This will not catch every indirection and the comment should say so. It closes the one route the
real code demonstrates, which is the route a copy-paste would take.

### 2. `tools/balance.py` — the check works; its exit code cannot fail

**Protects:** Lua block balance across all 320 `.lua` files. This is one of the **three checks every
contributor is told to run before every commit and again before the pull request** (`HANDOFF.md` §2).

**Evidence:** the file contains no `sys.exit` anywhere. It ends:

```python
print(f'{delta:+3d}  {p.relative_to(sys.argv[1])}{flag}')
print('\nfiles unbalanced:', bad)
```

**Why it cannot fail:** proved by planting a Lua file with a missing `end` into a scratch copy.

```
files unbalanced: 1      exit code: 0
files unbalanced: 0      exit code: 0     (plant removed)
```

The detection is correct — it found the planted imbalance and named it. Only a human reading the
printed line can act on it. Anything gating on the exit code — a CI step, or an agent chaining the
three checks with `&&` — reads success on a broken tree.

**To make it sound:** `sys.exit(1 if bad else 0)`. `verify.py` ends `sys.exit(1 if problems else 0)`
and `keybind_check.py` returns `1 if findings else 0`. `balance.py` is the odd one out of the three
mandatory checks.

**Two more things in this file, neither a finding:** `opens` is computed, corrected for `elseif`,
then recomputed from scratch on line 47, discarding the correction. The recompute is the correct one
— Luau tokenises `elseif` as a single token, so no correction is needed — and the two comments
either side of it contradict each other. Separately, `balance.py` carries no planted fault of any
kind, so its exit path is not the only part of it that has never been shown able to fail.

### 3. `tools/keybind_check.py:20` — no parse-completeness guard

**Protects:** two actions defaulting to the same key. Its header explains that Studio cannot catch
this, because Settings is a client module and client scripts never run in the harness. This file is
the only thing between a collision and a player finding it.

**Evidence:**

```python
20  ROW = re.compile(r'\{\s*id\s*=\s*"([A-Za-z0-9_]+)"[^}]*?default\s*=\s*"([A-Za-z0-9]+)"[^}]*?\}')
```

**Why it could stop failing:** `[^}]*?` requires `id` before `default` and cannot cross a nested
brace. A row written `{ default = "K", id = "Vault", ... }` parses as nothing, and **nothing anywhere
compares rows parsed against rows present**. The printed count would drop from 22 to 21 and the run
would stay green.

It is **not** proving nothing today. Settings.lua has 38 `id` fields, 22 of them with a string
`default` — the other 16 are the toggles and sliders the code deliberately skips — and the tool
reports 22 bound keys across 22 actions. The parse is currently complete.

**To make it sound:** the guard this project already uses, two files away.
`tools/achievement_check.py:31` counts rows with a cheap independent pattern, and line 132 exits when
the two disagree:

```python
31   raw_count = len(re.findall(r'\{ id = "', block))
132  if len(entries) != raw_count:
133      sys.exit(f"achievement_check: parsed {len(entries)} entries but the file has {raw_count} ...")
```

### 4. `tools/progression_model.py:49,53,55,63,70` — empty parses accepted silently

**Protects:** the model of the rank and prestige curve — tiers, cosmetic slots, the brainrot
catalogue, the weapon count. Its output is numbers other work quotes.

**Evidence:** the file defines a fail-loud reader and uses it 19 times —

```python
25  def need(pattern, text, what, flags=0):
27      if not m:
28          sys.exit(f"progression_model: couldn't read {what}")
```

— then reads five of its inputs with bare `re.findall`, for which an empty result is a valid value:

```python
49  TIERS = [... for n, p, c, x in re.findall(r'name = "(\w+)", points = (\d+), ...', prog)]
53  SLOTS = re.findall(r'\{ id = "(\w+)", kind = "(\w+)", ... \}', prog)
55  CATALOGUE = {r: len(re.findall(rf'rarity = "{r}", coinValue', brainrots)) for r in RARITIES}
```

**Why it could stop failing:** a format change in `ProgressionData.lua` empties `TIERS` or `SLOTS`
and the model reports a curve over nothing. All five match today (traced: 1 attempt, 1 hit each).

**To make it sound:** route them through `need`, or assert the counts non-zero. The file already
knows how; it stops doing it five times.

### The pattern behind the one real find

`verify.py` carries six permanent planted-needle assertions — lines 647, 648, 671, 690, 958 and 1158
— guarding five detectors. **All five fire.** Proved by breaking each detector in a scratch copy and
rerunning the real checker:

```
break _gun_staging          -> staging: the check missed a planted loot weight on a staged gun; it isn't testing anything
break _kill_effects         -> kill effects: the check missed a planted typo ("confettti"); it isn't testing anything
break _duplicate_ids        -> weapon ids: the duplicate check missed a planted clash; it isn't testing anything
break _projectile_contract  -> explosives: the projectile-kind check missed a planted typo ("rockett"); it isn't testing anything
break _gm_description_drift -> game modes: the description-drift check did NOT catch a planted 50-vs-100 disagreement — it is testing nothing
```

All five are aimed at invariants ("an unregistered round kind must be caught"), not at past bugs, so
none can expire. The comment at `verify.py:1131-1135` is the best writing in this harness on why: an
earlier version of that needle was handed a raw string while the real input was stripped source, so
the needle went green while the check saw an empty description and passed forever.

**Every one of those five plants guards a parser** — a check that reads source, builds a model and
judges it. **Not one guards a negative detector**, the `if re.search(BAD_THING): problems.append(...)`
shape. Tracing found 12 regex sites in `verify.py` that match nothing across the whole project.
Eleven are negative detectors, silent because the project is genuinely clean, over inputs of 7 KB to
169 KB — which the tracer records, so an empty haystack cannot hide behind a zero:

| site | looks for | haystack |
| --- | --- | --- |
| 285, 287, 289 | building code pasted back into MapGenerator | 38 KB, 38 KB, 67 KB |
| 342 | CrateService rolling raw `crate.odds` | 11 KB |
| 422 | BattlePassService calling `Monetization.Clear` | 7 KB |
| 511 | a Vector3 guarded by type alone | 48,857 attempts |
| 553 | a local used before its definition | 1,057,917 attempts |
| 753, 754 | Cells sold, or ProgressionService touching coins | 12–22 KB |
| 851 | Neon, glass or transparency on a parachute | 62 KB |
| 1033 | road markings sunk into the asphalt | 169 KB |

None of the twelve carries a needle, so none has ever been shown able to fire. The twelfth is the
Beginner's Luck guard in finding 1 — the one negative detector I did plant into, and it was blind on
the route the real code uses.

**That is the shape worth carrying forward: in this harness the plants are on the parsers, and the
unproven half is the detectors.**

### Python checkers read and found sound

* **`tools/achievement_check.py`** — the model to copy. A permanent plant (an achievement asking for
  more brainrots than exist) fabricated fresh each run, aimed at the invariant and stated to be, and
  it gates the exit code at line 160 *before* the exit for real problems. Plus the
  parse-completeness guard at 31/132. 9 regex sites, all matching.
* **`tools/climb_design.py`** — a two-sided plant at 919-926: a synthetic limb in clear air must be
  reported, and a buried one must not. Both sides, invariant-aimed, every run. 23 assertion sites.
  It is the source of the pre-existing `verify.py` red — float rounding on a two-decimal boundary,
  diagnosed in the 2026-09-21 mailbox message — not a check fault.
* **`tools/lua_static_check.py`** — every pattern rule owns a `_bad` and a `_good` fixture under
  `tools/patterns/`; they run on every invocation, they gate the exit code, and the header explains
  both why they are aimed at invariants and why they are named `.lua.fixture` (so `balance.py`'s
  `**/*.lua` and `verify.py`'s walk do not eat them). It reports 3,170 candidate sites beside its
  105 findings — it states its denominator without being asked.
* **`tools/weapon_stats.py`** — `self_test()` at line 92 plants a two-entry table and asserts three
  separate things about the parse: both entries found, a field written *after* a nested table still
  read, and the first entry's body not running on into the second. Aimed at the parser's invariant,
  not at the regex that once got it wrong.
* **`tools/brainrot_asset_audit.py`** — `--selftest` proves the backdoor detector against a planted
  backdoor. Not traced here because it writes three files per input; read instead.
* **`tools/menu_hud_audit.py`, `build_cursor_test.py`, `build_range_test.py`,
  `update_gun_nudge_baseline.py`** — generators and builders, not checkers. One assertion site
  between the four. Listed so the file count is honest.

---

## What this audit did not prove

* **The harness was never run.** Every finding is from reading, and the three proved ones were
  proved against the Python checkers, which run without Studio. No Lua probe in this report was
  executed. Where a finding says a probe's sample would be empty, that is read from the filter and
  the source it filters, not observed.
* **The Lua read was done in five groups by five readers, then re-read.** Every flagged Lua finding
  was checked a second time against the source before it went in: the line numbers, the grep
  results quoted, and the game-module references. The "found sound" lists were not re-read line by
  line a second time; they are the first readers' word, with the specific cross-checks they name.
* **Two world files were read in part**, `audit_roads.lua` (self-retired) and
  `brainrot_art_compare_gallery.lua` (the trailing render views), and the Lua section says which
  parts.
* **No DEAD PLANT was found.** That is a result, not a gap in the reading: every plant read is
  fabricated fresh each run and aimed at an invariant. It is possible one was missed in a file's
  "found sound" line.
* **`RoadNetwork.lua` is outside the brief.** Finding 7 in the Lua section names a one-line fix
  there. It is reported, not made.
* **`tools/probe_audit.py` decides three shapes, not four.** It cannot tell a stand-in body from a
  real one, and it cannot tell a live plant from an expired one. Both need the probe read beside the
  code it stands in for, which is what the written findings above are.
* **NEVER MATCHED is a site to read, not a verdict.** Eleven of the twelve it found are healthy. The
  tool reports the haystack size precisely so a reader can tell the two apart; it does not claim to.
* **No judgement about whether any of these probes tests the right thing.** This asks only whether
  each check can fail. A probe that soundly measures something nobody needs is out of scope here.
