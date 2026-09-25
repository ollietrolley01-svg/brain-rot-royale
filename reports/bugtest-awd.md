# Bug test: all-wheel drive (47200d3)

Jacob's branch `task/bugtest-awd`, cut from main **`d1e4f73`**; every run and line reference below is on
`d1e4f73`. Oliver's order (mailbox 2026-09-25-0300 and -0315): hunt for new bugs in what landed tonight and
report them with file and line. The target is 47200d3, "All-wheel drive for every car; load-following centre
split". It moved Rotster (front-drive before), TralalaGT and SahurVan (rear-drive before) to all four wheels and
added `VehicleDynamics.DriveSplit`: 40% of the drive to the front with the weight even, following the load when
an axle goes light, and no car wheel taking more than half of it (the fling guard).

Everything here ran outside Studio: Python and lupa, running the game's own `VehicleDynamics.lua`, with the mock
world and 240 Hz integrator of `tools/vehicle_stability_sim.py`. "Before" is the file at `47200d3^`. No game
file and no existing tool was edited. `CombatDamageScale` plays no part here (no damage is dealt); main has
0.736.

## Verdict

**The drive split itself is sound, and AWD changed almost nothing a player will notice. But it is what turned
`bot_driving_sim` red on main.** Over 115,248 wheel-load patterns the split never makes drive from nothing,
never pushes a wheel the wrong way, never hands one wheel more than half, and never goes NaN on loads Step can
produce. Bikes are bit-for-bit what they were. Top speed, reverse and braking are unchanged, and so is parked
rest. Cornering is within about 1%, and nothing flings on landing. What it does change: the three cars that
changed wheels climb much steeper grass (Rotster 29° → 51°), and the Ranger's bot lap. With AWD's centre split
the Ranger takes a corner a little differently, stops at an obstacle, reverses into it at 5.4 studs/s, and
finishes 9 s slower. Put back only the old load-share split and the lap passes again. The revert of the vehicle
WIP (9c44f4b) left 47200d3's code whole.

**Problems found, most important first:**

1. **The known red `bot_driving_sim` (Ranger lap, "1 impacts") comes from 47200d3's centre split, not from
   the bots.** Measured. `VehicleDynamics.lua:556-569` (`DriveSplit`), used at `:743` and `:787`.
   I ran `bot_driving_sim.py --only lap` four ways, on main's `BotNav.lua`:

   | VehicleDynamics.lua | Ranger lap | result |
   |---|---|---|
   | main as it is | 70.3 s, 1 impact (5.4 studs/s), 2 recoveries | RED |
   | from before AWD (47200d3^) | 61.3 s, 0 impacts, 0 recoveries | OK |
   | main, only `DriveSplit` put back to the load share (fling guard kept) | 61.3 s, 0, 0 | OK |
   | main, only the fling guard off (split kept) | 70.3 s, 1, 2 | RED |

   The runs are deterministic: main gave the same 70.3 s twice. How it happened: the BotNav fix d400668
   ("bot_driving_sim OK", 03:03) was cut from a tree without AWD. AWD (02:33) was on another branch, and the
   two met at the merge. Each was green alone; together they are red. In the trace
   (`--trace lap:CrocodiloRanger`), the AWD Ranger comes out of the corner at about (250, -3) roughly 1 stud
   wider and 0.3 s later. It then sees an obstacle at (263, 10), does a three-point turn, and backs into
   block 7 at t = 26.05 s. The lap is on a knife edge. In my flat-ground runs the Ranger's handling hardly
   changed: its full-lock crawl is 0.9% slower. So a small change tipped it, and a small change to either
   file could tip it back. That is reasoning from the trace, not a measurement of the edge. `pc/lag-bug-sweep`'s
   `BotNav.lua` gives exactly the same four results (measured). The impact is small: 5.4 studs/s, in
   reverse. The lap time and the two stuck recoveries are what a player would see.

2. **SahurVan rolls backwards on flat ground at part throttle, and never reaches its top speed.** Measured in
   lupa. **This is not from AWD:** it was the same before AWD, within 0.3%. I found it while measuring AWD.
   The van sits 2.2° nose-up at rest and about 3.7° nose-up under acceleration. Each spring pushes along the
   body's up (`VehicleDynamics.lua:823`, `castUp * wheel.load`), so on a nose-up body part of that push points
   backward. Measured steady state: the drive that holds the van at 63.8 studs/s is 8.5 studs/s², and
   196.2 × sin(2.43°) = 8.3. The tilt comes from every spring carrying the same share of the weight,
   `wheelMass * gravity` (`:669`, with `wheelMass = mass / wheelCount` at `:582`). The van's chassis centre sits
   0.4 studs behind the middle (`VehicleModels.lua:1633`), so its rear springs carry 54% of the weight on
   preloads made for 50%, and they sink. That cause is reasoning; the tilt and the numbers are measured.
   What it does, in lupa:
   - The van tops out at **63.8 of its 72** (88.7%). The CameloCarrier tops out at 57.9 of 62 (93.4%, tilt 1.05°).
   - At throttle 0.15, the bots' corner throttle, from 12 studs/s in a straight line on flat tarmac, the van is
     **rolling backwards at 1.5 studs/s after 6 s**. The Carrier drops to 10.7, the Ranger climbs to 28 and the
     Rotster to 46. At full lock and 0.15 the van creeps at 1.2 studs/s.
   - Studio agrees on the size of it: `tools/vehicle_awd_check.py`'s own BEFORE table, measured in Studio, has
     the van at 11.22 s and the Carrier at 12.03 s to 95% of top. Rotster, Ranger, GT and Scout take 3.2-4.4 s.
     With no drag the van's engine curve would take about 3.4 s (reasoning).
   - Roadkill: the damage uses the speed at impact, so a van hits for at most (63.8 - 12) × 1.8 × 0.736 = 68.6,
     not the 79.5 its topSpeed of 72 suggests. That is arithmetic on a lupa speed.

3. **The fling guard throws drive away rather than passing it on.** Measured (the pure sweep). Reported as a
   design point for Oliver; it may be intended. `VehicleDynamics.lua:744` sets the cap and `:788` applies it
   with `math.min(share, wheelCap)`. The part of a wheel's share above half goes to nobody. Shares of the drive
   actually handed out, by the real lines cut from the source:

   | wheels down (load shares FL FR RL RR) | handed out | before AWD (Ranger/Scout/Carrier) |
   |---|---|---|
   | fronts only, even (0.5 0.5 0 0) | 100% | 100% |
   | fronts only, 70/30 in a turn (0.7 0.3 0 0) | **80%** | 100% |
   | one front wheel only (1 0 0 0) | **50%** | 100% |
   | crossed up, one wheel per axle (0.5 0 0 0.5) | **90%** | 100% |
   | hard cornering, outside wheels 90% | 96% | 100% |

   On a grid of 115,248 patterns (7 load levels per wheel × 16 grounded patterns × 3 drive requests), 97,956
   lose some drive, all at the guard. The grid is lopsided on purpose and says nothing about how often this
   happens in play. In the whole-step runs it never happened: 0 frames under 99% handed out, for all 6 cars,
   on flat ground, in all four corners, across road edges at 10° and 30°, up a 40° climb, and landing two jumps.
   Rocks, where one or two wheels carry a car, are where it would bite. The commit's "all of it to the one axle
   down" holds only when that axle's two wheels share the load evenly. Only a Studio run on the rock field
   (`tools/vehicle_rough_terrain_probe.lua` already logs wheel loads when a run stalls) can say whether it matters.

4. **With the front carrying more than half the load, the rear gets its load share plus 10%.** Measured
   (pure). `VehicleDynamics.lua:568`: `return front - (0.5 - FRONT_SPLIT)`. A rear axle carrying 5% of the
   load gets 15% of the drive (7.5% on each wheel, three times its share). At 1% of the load it still gets 11%.
   As the last rear wheel lifts, the front's share jumps from 0.9 to 1.0 (a rear with 1e-9 of load gives 0.9).
   The comment 47200d3 removed from Step warned about exactly this: "a wheel barely touching was handed half
   the drive, spun it away against its own tiny grip". Each wheel's friction circle caps its push at its own
   grip, so the extra is wasted, not thrown (reasoning, from the friction circle at `:802-821`). No run of mine showed an effect.
   Low severity; I name it because the old comment named it.

5. **`vehicle_models_runtime_check.py` is red on main, and not from AWD.** Measured. Three models fail:
   SahurVan with 4 faults, TartarugaScout with 4 and TralalaGT with 2, each a wheel that "comes away from
   what carries it at steer ±32-34 deg, suspension extended". Bisected with main's version of the tool:
   OK at `52a5608^`, FAIL at `52a5608` ("Rough ground: ... ride lift"). Identical at `47200d3^`, `47200d3`
   and main. At `47200d3^` and `47200d3` the tool of that day crashes on a missing `table.find` in its mock;
   main's copy fixed that. The three models that fail are exactly the three with `rideLift = 0.7`
   (`VehicleDynamics.lua:93`, `:100`, `:112`). The Rotster, with 0.5, passes. That link is reasoning. STATUS
   lists only `bot_driving_sim` as known red. Whether a wheel visibly leaves its arch is a picture, so it
   needs a render (`tools/vehicle_gallery.lua`).

6. **SahurVan's pick-up changed by more than the commit's "within 1%".** Measured, and minor. 0-60% went
   from 2.400 to 2.317 s (-3.5%). The time to 95% of the top it reached before went from 4.667 to 4.467 s
   (-4.3%), and 0-90% in reverse -1.6%. That is inside `vehicle_awd_check.py`'s own 5% tolerance. The cause is
   finding 2: with some of the drive at the front the body squats less (3.77° → 3.56° over 0.5-2.3 s), so
   less of the springs' push points backward. Every other car is within 1% on every flat number.

Not a code bug, but it matters for what to work on next:
the handoff message `2026-09-25-0830-coordinator-handoff-remaining-to-jacob.md` was committed at 04:15, before
the revert (04:28). Its item 1 says the vehicle visuals and suspension "landed at a7a6ae8" and asks for
`vehicle_visuals_check.py`, `tools/vehicle_visuals_gallery.lua` and the suspension_standard check. None of those
exists on main after 9c44f4b. The 0435 hotfix message says that work stays on `pc/vehicle-rest` until a Play
test with a client proves it. Item 1 needs the coordinator to confirm before anyone acts on it.

## The revert (9c44f4b) left AWD whole

Measured with `git diff`:

- `VehicleDynamics.lua`, `VehicleModels.lua` and `VehicleClient.client.lua` on main are **byte-identical to
  47200d3**, and to `14eebfd^`. The revert put all of 14eebfd's game files back exactly; nothing of 47200d3
  was undone.
- Nothing on main names `VehicleVisuals`. `DriveSplit`, `FRONT_SPLIT` and `MAX_WHEEL_SHARE` are used only
  inside `VehicleDynamics.lua` and by `tools/vehicle_awd_check.py`, which cuts the function out of the file.
- `VehicleWreckFx.lua` is as it was at `14eebfd^`. Its `OnWreck` hook (`:66`) came from a99c94f (sound
  polish), and `ProjectileClient.client.lua:584` still sets it.
- One tool is not back to `14eebfd^`: `tools/vehicle_models_axis_check.py` has 11 more lines, its mock gaining
  `table.find`, `table.clone`, `V3.Min/Max/Abs/Lerp` and quiet signals. They arrived with a main merge, not
  from 14eebfd, and the check passes.

## What was run, end to end

`tools/awd_bugtest_check.py` has three parts.

**split.** It cuts `DriveSplit`, the two constants and the drive lines of `Step` out of the source text as
they are. That is lines 731-744 (the axle loads and the cap) and 785-789 (each wheel's drive), plus Step's
skip for a wheel that is up or unloaded. It runs them as pure functions.
- `DriveSplit`: 8,004 load splits (4 totals from 1e-9 to 1e12 × 2,001 front fractions), plus the four ends
  and five inputs off the domain.
- Per wheel: a four-wheel car with every wheel driven, and a bike with only the rear driven. Loads
  {0, 1e-9, 0.5, 30, 400, 2500, 12000} are what Step can produce, since it clamps each load to 0..maxLoad
  (the Ranger's maxLoad is about 22,000). Add {-50, 1e300, inf, NaN} for off the domain. Every grounded
  pattern, and drive requests of +40, -30 and 1e-6.
- 115,248 car cases and 588 bike cases in the domain; 702,768 and 1,452 off it.

Invariants, each of which fails the check: the split in 0..1, finite, never falling as the front takes more
load, 0 with the front up, 1 with only the front down (S1). Every wheel finite (S2). No wheel against the
request (S3). Never more handed out than asked (S4). No car wheel over half (S5). A bike's front never driven
and its rear taking all of it (S6). Some drive reaching the ground whenever a driven wheel is down with load (S7).

**step.** Whole-step runs of every car model (the six `kind = "car"` entries of `VehicleModels.lua`, with
geometry and density read by `car_bounce_audit_sim.read_cars`), before and after, under the same integrator.
Bikes go through `bike_balance_sim.measure` whole (15 runs), and every number is compared exactly. Invariants:
flat 0-60%, 0-95% and top speed, and reverse, within 5% (`vehicle_awd_check.py`'s tolerance). Past 1% prints
a `FINDING`, since 1% is the commit's claim. Braking and parked rest must be identical, because no drive is
asked for there. Bikes must be identical.

**bot** (`--bot`). The four `bot_driving_sim --only lap` runs of finding 1, each in a temporary copy holding
only the sim, its two imports, main's `BotNav.lua` and the VehicleDynamics variant.

Before → after on main, per car (lupa, flat tarmac unless said):

| | Rotster | Ranger | TralalaGT | SahurVan | Scout | Carrier |
|---|---|---|---|---|---|---|
| driven | front → all | all → all | rear → all | rear → all | all → all | all → all |
| 0-60% s | 1.350 → 1.350 | 1.633 → 1.633 | 1.417 → 1.417 | 2.400 → 2.317 | 1.567 → 1.567 | 2.167 → 2.183 |
| 0-95% of top reached before, s | 3.217 → 3.233 | 3.750 → 3.767 | 5.817 → 5.817 | 4.667 → 4.467 | 5.550 → 5.550 | 4.650 → 4.667 |
| top speed reached | 84.00 → 84.00 | 76.03 → 76.02 | 112.43 → 112.43 | 63.67 → 63.83 | 74.28 → 74.28 | 57.92 → 57.91 |
| reverse top | 26.00 → 26.00 | 31.93 → 31.93 | 27.82 → 27.82 | 25.91 → 25.91 | 21.46 → 21.46 | 21.42 → 21.42 |
| brake 90% → 0, studs | 28.61 (same) | 28.53 (same) | 37.96 (same) | 24.62 (same) | 25.27 (same) | 20.71 (same) |
| parked drift on 10° grass, 7 s | 0.1153 (same) | 0.3257 (same) | 0.0162 (same) | 0.6757 (same) | 0.1053 (same) | 0.3586 (same) |
| power corner (60% top, full lock, throttle 1): max slip ° / radius | 2.0/34.7 → 1.9/35.0 | 1.9/46.2 → 1.9/46.2 | 1.1/50.9 → 1.1/50.6 | 1.8/32.4 → 1.8/32.2 | 2.3/53.3 → 2.3/53.4 | 2.6/56.5 → 2.6/56.5 |
| step steer at 90% top: max slip ° | 1.8 → 1.7 | 1.5 → 1.5 | 1.4 → 1.4 | 1.6 → 1.6 | 1.7 → 1.7 | 1.6 → 1.6 |
| full-lock crawl (12 studs/s, throttle 0.15): speed | 26.56 → 25.32 | 18.76 → 18.58 | 31.28 → 32.10 | 1.17 → 1.23 | 27.00 → 26.90 | 10.14 → 10.04 |
| steepest grass grade from standing, ° | **29 → 51** | 49 → 49 | **34 → 50** | **36 → 44** | 51 → 50 | 18 → 18 |
| jump on the throttle: pitch rate after / min up | 7.94/0.831 → 8.98/0.876 | 6.79/0.930 → 6.82/0.929 | 7.88/0.919 → 7.81/0.913 | 7.27/0.915 → 7.18/0.913 | 7.26/0.943 → 7.23/0.943 | 6.33/0.917 → 6.33/0.916 |
| nose-down landing: peak wheel push / wheel weight | 0.29 → 0.12 | 0.06 → 0.06 | 0.16 → 0.26 | 0.06 → 0.05 | 0.51 → 0.52 | 0.46 → 0.45 |

What those say about the brief's questions:
- **Understeer or spin at speed, especially TralalaGT and Rotster:** no change past 1% in slip angle or
  radius, with the power on or in a step steer. Measured.
- **Landing with one axle light (a torque spike, a fling):** no relaunch, before or after. On a nose-down
  landing the peak push through any one wheel is at most half that wheel's weight (TralalaGT 0.16 → 0.26 of
  it). The body ends more upright than before on both the Rotster and the GT. Measured.
- **Parked rest (holdRest):** unaffected. `holdRest` (`VehicleService.lua:337`) reads compression, grounded
  and normal, never drive. A parked Step asks for no drive (`hold`, `VehicleDynamics.lua:723-724`). The runs are
  identical to the last digit. Measured.
- **Roadkill:** its damage takes the impact speed, and no car's reachable top speed moved more than 0.3%. The
  one exception is the van, whose top speed already falls short (finding 2). `roadkill_proof_check.py`
  passes on main. Measured.
- **Stability and car bounce:** `vehicle_stability_sim.py` and `car_bounce_audit_sim.py` pass before and
  after, and no number moves more than 0.3 studs/s (diff of the two outputs). Measured.
- **The lift-off corner** (60% of top, full lock, throttle off) spins the Ranger (76° of slip), the van (55°)
  and the Carrier (88°). The same before AWD. Whether that is right is a feel question for Oliver.

## The existing vehicle checks on main `d1e4f73`, verbatim

| check | exit | last line | new with 47200d3? |
|---|---|---|---|
| vehicle_stability_sim | 0 | `56 runs examined (4 models), 0 problems: OK` | no (OK before and after) |
| car_bounce_audit_sim | 0 | `OK` | no |
| bike_balance_sim | 0 | `30 runs examined (3 bikes), 0 problems: OK` | no |
| bot_driving_sim | 1 | `PROBLEM lap CrocodiloRanger: 1 impacts (worst 5.4 studs/s)` / `bot driving sim: FAILED` | **yes, with d400668** (finding 1). At 47200d3^ and at 47200d3 it was red for another reason: `PROBLEM lap TralalaGT: off the tarmac 12.2% / 8.0% of the time on road legs`, which d400668 fixed |
| vehicle_models_runtime_check | 1 | `vehicle_models_runtime_check: FAIL` | no: since 52a5608 (finding 5) |
| vehicle_models_axis_check | 0 | `vehicle_models_axis_check: OK` | |
| vehicle_collision_check | 0 | `vehicle_collision_check: 7 checks, 0 failed` | |
| roadkill_check | 0 | `roadkill check: 25 checks, 0 failed` | |
| roadkill_momentum_check | 0 | `roadkill momentum check: 16 checks, 0 failed` | |
| roadkill_proof_check | 0 | `roadkill proof: 22 checks, 0 failed, 0 findings` | |
| parked_car_check | 0 | `parked_car_check: OK` | |
| team_vehicles_check | 0 | `team_vehicles_check: 40 matches, 480 parked base vehicles examined, 0 failures` | |
| vehicle_place_check | 0 | `self-test: chassis-only caught, no inward caught` | |
| vehicle_aim_check | 0 | `problems: 0` | |
| vehicle_cover_check | 0 | `vehicle_cover_check: 0 problems` | |
| destruct_car_check | 0 | `destruct_car_check: OK` | |
| throw_carry_check | 0 | `throw_carry_check: 8 checks, 0 failed` | |
| car_placement_check | 0 | `car_placement_check: OK` | |
| base_vehicle_respawn_check | 0 | `base_vehicle_respawn_check: 12 matches, 216 base vehicles examined, 0 failures` | |
| vehicle_awd_check, vehicle_rough_terrain_check, parked_vehicle_rest_check | 1 | (their usage text) | these read a Studio probe log. Without one they print usage and exit 1, so they could not run here |

22 checks run; 2 are red on their own merits, and 3 need a Studio log.

## Other branches

`git diff --stat origin/main...origin/<branch>` on `VehicleDynamics.lua`, `VehicleModels.lua` and `BotNav.lua`:
- `pc/lag-bug-sweep` touches `BotNav.lua` (drive routing: arena gateways, a heap) and `VehicleModels.lua`
  (part names). With its `BotNav.lua` the four lap runs come out exactly as in finding 1. With its
  `VehicleModels.lua`, `vehicle_models_runtime_check` fails with the same 10 faults. Measured.
- `pc/teambase-v2` touches `BotNav.lua` (29 lines, routing inside a team arena, only when `BotNav.Arena` is
  set). Not run. The lap has no arena, so I expect no change (reasoning).
- `pc/vehicle-rest`: nothing beyond main (its tip a7a6ae8 is an ancestor of main). `pc/hitreg-fixes`,
  `pc/mounted-guns-powerful` and `pc/ttk-plus-25` are merged.

## For the coordinator (needs Studio)

`tools/awd_bugtest_probe.lua` runs, with Roblox's physics, the three runs that decide findings 1-3: the
full-lock crawl, the jump landed on the throttle, and the flat drag with the body's tilt. It runs each car twice
in one session, as shipped and with the centre split back to the load share. It swaps
`VehicleDynamics.DriveSplit` for the length of each Step call, and puts Rotster, GT and van back on their old
wheels before `Rig`. The per-wheel cap is a local inside Step and stays on, so "pre" there is not the whole of
47200d3^. It prints `[AWDBUG] <model> <variant> <run> k=v`. **It needs a real Play test with a client**, as
the 0435 hotfix message requires for anything vehicle, not runtest's Run mode. I have not run it: there is no
Studio here. Past the Lua parse (lupa, with compound assignments spelled out) and `lua_static_check`, it is
untested.

## Planted faults

`python3 tools/awd_bugtest_check.py --plant` breaks one invariant at a time in a copy of main's source. Each
is aimed at something the drive code must refuse for good, not at a finding above:

| plant | caught by |
|---|---|
| the rear up hands the front 1.25 of the drive | S1 (out of 0..1) |
| the fling guard off | S5 (97,956 cases over half) |
| a bike's drive split to its undriven front | S1 (falls) and S6 |
| reverse throttle drives forward | S3 (65,856 cases) |
| the zero-load guards loosened (0/0) | S1 (rear up gives 0.9; both up gives NaN) |
| the split hands out 10% more than asked | S4 and W1 |
| the brakes go through the split | W3 (braking no longer identical) |

**7/7 caught.**

## What I did NOT prove

- **Nothing here ran in Roblox.** Every number is the lupa integrator's: a box of mass with wheel forces,
  no tyre or body friction from Roblox's solver, and no network ownership. Where Studio figures exist they
  agree: the lupa 0-95% times for Rotster, Ranger, GT and Scout are within 1% of `vehicle_awd_check.py`'s
  Studio BEFORE table, and the van's slow pick-up shows there too. That is agreement, not proof.
- **Finding 1's cause inside the lap** (why the AWD Ranger comes out of that corner 1 stud wider) is read
  off a trace, not measured. Which file should change, `DriveSplit` or BotNav's corner logic, is the build
  machine's call and Oliver's.
- **Finding 2's root cause** (equal spring preloads on a car whose weight is not centred) is reasoning. The
  tilt, the drag and the speeds are measured. The lupa van's mass is its chassis hull only, as in
  `car_bounce_audit_sim.py`; if other parts of the real van carry mass, its tilt differs.
- **Whether the fling guard's lost drive (finding 3) stalls anyone on rocks.** My runs had no rocks. The
  rough-terrain Studio probe is where that shows.
- **How the cars feel.** Whether AWD cars corner or climb as Oliver wants, and whether the lift-off spins are
  wanted, is his to judge in a playtest.
- **Finding 5 by eye:** the check says wheels come away from their arches at full steer. Whether that shows on
  screen needs a render.
- `vehicle_awd_check.py`, `vehicle_rough_terrain_check.py` and `parked_vehicle_rest_check.py` were not run.
  Each needs a Studio probe log.
