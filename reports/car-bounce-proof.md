# #84 / #109 car bounce: an independent check of commit 3f1d7b6

Jacob's branch `task/prove-car-bounce`, cut from origin/main 82968cb. Everything here was measured
outside Studio (Python + lupa) or read from source. Nothing was run in Roblox. No game file and no
existing tool was edited.

## Verdict

- **The cloud session's "13 problems before, 0 after" reproduces exactly**, and current main (82968cb)
  still passes: 0 problems, planted fault caught on 4/4.
- **The fix is real in the sim, but almost all of the "before" failures come from one frame-rate
  assumption that Roblox may not make.** 12 of the 13 problems are in the sim's "144 fps over 60 Hz
  physics" mode, where some frames get no physics step. A Roblox staff post says physics steps on
  every rendered frame. When I run that model instead (144/240 and 240/240), **the pre-fix code has 0
  problems.** At 60 fps (the server, every bot, a 60 fps player) the pre-fix code already passed every
  bar; the fix roughly halves the jolt numbers there, but nothing crosses a line either way.
- So the sim proves that the new damper cannot pogo when frames outpace physics, and that it is
  calmer at every frame rate. It does **not** show that the pre-fix code bounced in the game Oliver
  played. If frames did not outpace physics on his machine, the sim has no explanation for #84, and
  the likeliest remaining cause is in what the sim leaves out, network ownership (section 5).
- I found no bug that needs fixing now. I found one ownership handover worth measuring (5c) and several
  places where the sim differs from the game (section 4). Most of those make the sim's course harder
  than the real road. Two missing cars have now been run and pass.

## 1. Reproducing the claim

Setup: `python3 -m venv /tmp/brr-venv && /tmp/brr-venv/bin/pip install lupa`. The sim's logic has not
changed since 3f1d7b6. The only later edit (13a28cd) is two docstring lines, which I checked by diff.
Sources are extracted with `git show <rev>:ReplicatedStorage/Shared/VehicleDynamics.lua`.

`tools/vehicle_stability_sim.py --source <file>`, final lines, verbatim:

**3f1d7b6^ (before the fix)**, exit 1:
```
PROBLEM Rotster edge10 144/60: all four wheels off the ground for 0.05 s
PROBLEM Rotster edge10 144/60: vertical jolt 18.47 studs/s per 60th > 6.0
PROBLEM Rotster edge10 144/60: vertical speed 21.70 > 7.0
PROBLEM TralalaGT edge10 30/240: vertical speed 10.22 > 7.0
PROBLEM TralalaGT road 144/60: all four wheels off the ground for 0.83 s
PROBLEM TralalaGT road 144/60: vertical jolt 40.91 studs/s per 60th > 6.0
PROBLEM TralalaGT road 144/60: vertical speed 42.48 > 7.0
PROBLEM TralalaGT edge10 144/60: all four wheels off the ground for 1.68 s
PROBLEM TralalaGT edge10 144/60: vertical jolt 43975423.81 studs/s per 60th > 6.0
PROBLEM TralalaGT edge10 144/60: vertical speed 43975578.13 > 7.0
PROBLEM TralalaGT edge30 144/60: all four wheels off the ground for 2.26 s
PROBLEM TralalaGT edge30 144/60: vertical jolt 66.54 studs/s per 60th > 6.0
PROBLEM TralalaGT edge30 144/60: vertical speed 146.16 > 7.0
planted fault (damper pushing the wrong way): caught on 4/4 models
56 runs examined (4 models), 13 problems: FAIL
```

**3f1d7b6 (the fix)**, exit 0:
```
planted fault (damper pushing the wrong way): caught on 4/4 models
56 runs examined (4 models), 0 problems: OK
```

**82968cb (current main)**, exit 0:
```
planted fault (damper pushing the wrong way): caught on 4/4 models
56 runs examined (4 models), 0 problems: OK
```

What the 13 are: 13 threshold breaches in 5 runs out of 56, on 2 of the 4 cars. 12 are in the 144/60
mode and 1 is a marginal 30/240 breach (10.22 against a limit of 7). The TralalaGT 144/60 edge run
blows up numerically (4.4e7 studs/s), which is a real instability in the old code under that mode.

Road runs at 60/240 (a 60 fps client, the server, every bot), largest per-60th jolt, before → after,
from the same outputs: Rotster 2.49 → 1.30, CrocodiloRanger 1.68 → 0.30, TralalaGT 2.41 → 1.66,
SahurVan 2.23 → 1.46. The limit is 6. None were airborne either way.

## 2. Planted faults

**The sim's own plant (damper sign flipped)** fired on 4/4 cars against all three sources. It is
aimed at an invariant, "a car at top speed on a road never leaves the ground". Flipping the damper's
sign breaks that no matter how the damper is computed, so it will not expire the way a test of the old
bug would. Two weaknesses:
- It is only run at 60/240 (`MODES[0]`). The check is never shown to fire in the 144/60 mode that
  carries the headline result.
- The docstring describes a different plant ("a pogo-stick bump stop and load cap") and a different
  jump ("12-degree ramp's end at 60 st/s"; the code uses 20 degrees at 70). The code is what runs. The
  docstring is stale. Reported, not edited.

**My plant (the damper reverted to frame-to-frame ray length, the rest of 3f1d7b6 left in)**, from
`tools/car_bounce_audit_sim.py` against current main:
```
planted fault damper-diff (old bug): caught on 3/6 cars (Rotster, SahurVan, TralalaGT), in modes 144/60, 30/240, 13 problems
```
The sim catches it, and it reproduces the pre-fix failure list almost line for line (same runs, same
13 breaches). **In the sim, the damper line is the whole fix.** The other parts of 3f1d7b6 (the
`heldFor` caps and treating a slab's side face as the strut axis) change nothing the sim measures.
This plant is aimed at the old bug, not at an invariant. It is a regression test and will expire if the
damper is rewritten again. It is **not** caught at 60/240, 144/240 or 240/240.

## 3. The frame-rate question the headline rests on

The sim's 144/60 mode gives a frame no physics step whenever frames outpace a 60 Hz physics step.
The pre-fix damper differenced ray length between frames, so on those frames it read zero and then
a double step.

What Roblox does, from the researcher's sources:
- A Roblox staff member (DevForum, "Introducing the Maximum Framerate Setting", 2024-05-30):
  *"Physics also runs at your framerate, but it will rerun to hit 240Hz."* In that model every
  rendered frame gets a physics step.
- Adaptive timestepping has been the default since July 2023 (the default setting "resolves to the
  same behavior as Adaptive"). It steps each assembly at 240, 120 or **60 Hz**, so an assembly dropped
  to 60 Hz inside a 144 fps client could plausibly miss frames. No source confirms this. One non-staff
  forum post reports zero position change on some Stepped frames at 240 fps.
- No source says whether a VectorForce is re-read per substep. The sim assumes it is held for the whole
  step, the same assumption the fix's `MIN_HOLD` makes.
- The project sets no `PhysicsSteppingMethod` (grep over every .lua and .py: 0 hits), so the game runs
  Adaptive.

My helper adds the "every frame stepped" modes. Pre-fix, 144/240 road jolts are Rotster 1.24,
Ranger 0.84, TralalaGT 1.22, Van 2.03. At 240/240 they are 0.62 / 0.42 / 0.61 / 0.56. There are 0
problems in either mode.

**How to settle it:** log `PreSimulation`'s `deltaTimeSim` and the chassis's position change per frame
on a 144 fps client while driving, or open the MicroProfiler `worldStep` scope. This needs a real
client, so it is a playtest measurement, not a Studio probe.

## 4. How honest is the sim? (17 things checked against the game)

| # | What | Sim | Game (source) | Effect |
|---|---|---|---|---|
| 1 | Module under test | real `VehicleDynamics.lua`, `+=` rewritten | same file | ✓ |
| 2 | Vector3/CFrame/Raycast mocks | hand-written, only the ops the module uses | engine | ✓ ran all three sources without error |
| 3 | Ray against ground | exact 1-D profile incl. slab side faces | engine raycast | ✓, but the ground varies only along travel (see 8) |
| 4 | What a wheel stands on | real `standable()` | `VehicleDynamics.lua:465-483` | ✓ mock parts answer the same fields |
| 5 | Substeps / force hold | 240 Hz, forces held between Steps | staff: 4 × 240 Hz per 60 Hz frame | ✓ at 60 fps. 144/60 unconfirmed (section 3) |
| 6 | Step's dt | previous frame's length | Stepped hands the last frame's dt (docs) | ✓ |
| 7 | RoadLift / MarkRaise | 0.4 / 0.07 | `MapDecor.lua:92`, `:99` | ✓ |
| 8 | Stop lines | 1.0 long, full width | 1.2 long, one lane (`RoadNetwork.lua:1859`, `:1864`) | sim can't put one side's wheels on a line. Real lines add a roll input the sim never sees |
| 9 | Slab joins | tops step 0.01 every other slab, 0.05 gap every third join | tops meet exactly; the stagger is 0.07 in width and 0.15 in depth only (`RoadNetwork.lua:22`, `:51-56`, `:1785-1800`) | **sim harsher** |
| 10 | Slab length / grade | 8-stud flat slabs, no grade | slabs merged while the grade holds (`:1765`); grade ≤ 0.1, crease ≈ 0.5° (`:89-92`) | creases not modelled. At 100 st/s over R = 1000 that is 10 st/s² against g = 196, so small |
| 11 | Bridge deck | collidable top at 0.7, a 0.3 step above the road at each end | asphalt runs straight across; deck top = road ground, under the asphalt (`MapDecor.lua:441-452`) | **sim harsher**: the real bridge is just road to a wheel |
| 12 | Road width (edge course) | 24 | `RoadNetwork.Width = 18` (24 is the claim width) | minor |
| 13 | Cars covered | 4 | **6**: TartarugaScout and CameloCarrier added in 7fab339, after the sim | **gap**. Run by my helper: 0 problems |
| 14 | Wheel mounts | axle Z from the model origin | mount = hub offset from the Chassis centre (`VehicleDynamics.lua:249-255`, `VehicleModels.lua:3505`) | Rotster/Ranger off by 0.05, **SahurVan by 0.4** (chassis centre Z = 0.4). Corrected in my helper, same result |
| 15 | Mass | volume × 1.3 | volume × the hull's density (`VehicleModels.lua:350`): van 1.1, scout 2.2, carrier 2.6. Riders, seats and trim massless (`VehicleService.lua:164`, `:200-216`, `VehicleModels.lua:196`) | Every force in the dynamics scales with mass, so this should cancel. Corrected anyway, same result |
| 16 | Gravity | 196.2 | 196.2, but ×0.5 in a low-gravity event (`MatchEvents.lua:76`, `MatchService.lua:539`) | not modelled. My helper at ×0.5: 0 problems |
| 17 | Body contact | 4 bottom corners, stiff and dead | full box, friction 0.3, elasticity 0 (`VehicleModels.lua:350`). Wheels never collide (`:369`) | only matters in runs that already fail (hull 0 in every passing run) |

With all of 8-17 that can be fixed from outside corrected (`tools/car_bounce_audit_sim.py`: 6 cars, the
real mounts and densities, six modes), current main:
```
120 runs examined (6 cars), 0 problems
planted fault damper-sign (invariant): caught on 6/6 cars at 60/240
```
The same holds with `--ground built` (the road laid the way RoadNetwork lays it: flush tops, 1.2 stop
lines, deck under the asphalt) and with `--gravity 0.5`. Across the 36 road runs, the built road changes peak
|vy| by at most 1.07 studs/s and the worst jolt by at most 0.29, so the sim's seams are not where its
jolts come from.

## 5. Network ownership (static read, what the sim leaves out)

Who runs `VehicleDynamics.Step`:
- **A player driving:** their client, on `RunService.Stepped` at their own frame rate
  (`VehicleClient.client.lua:472`, `:506`). It skips stepping while the model carries `ServerControl`
  (`:483-490`).
- **Everything else:** the server, on `RunService.Stepped` at about 60 Hz (`VehicleService.lua:1709`).
  That covers empty cars, bot drivers (no Player → `driverPlayer` nil at `:558`), and any car during a
  server hold.

Ownership is set in one place, `updateOwnership` (`VehicleService.lua:1448-1477`): the driver's Player,
or the server while `now < serverHoldUntil`. It changes hands **while a car is moving** in these cases:

a. **Driver sits or leaves** (`:558-559` sets `ownerDirty`): expected, once per ride.

b. **Any seat changes, passengers and gunner included** (`onSeatChanged` → `:558-559`). The same
   Player is handed ownership again, and the honesty baselines reset (`:1467-1476`). The file's own
   comment (`:1542-1545`) says the engine returns an assembly to automatic ownership "whenever the
   assembly changes -- a weld made or broken". If that also applies to an owned assembly, then from a
   passenger's SeatWeld until the next server Stepped the car is on the engine's automatic choice. That
   could be the passenger. **This is a candidate jolt when someone climbs into or out of a moving
   car.** Reasoning only.

c. **Honesty correction** (`:1517-1530`: over-speed for 0.7 s, a teleport-sized jump, or 3 s hovering).
   The server takes the car for `SERVER_HOLD` 1.2 s, `PivotTo`s it back and zeroes its velocity. That
   reads as a rubber-band snap, not a bounce, and the thresholds look far from normal driving. Rare by
   reasoning. Not measured.

d. **Blast** (`ApplyBlast`, `:1886`): the server takes the car for `BLAST_HOLD` 0.6 s. Intended.

e. **A player takes over from a bot** ("Take over" prompt, `:567`): ownership goes from the server to
   the player mid-drive. Same path as (a).

On each handover to a player, the server calls `VehicleDynamics.Idle` once (`:1562-1571`), which writes
zero forces on the server's copy. Server property writes replicate to the owning client, so a zero
can land between the client's Step and its physics step and drop the springs for one step (about 3.3
studs/s of free fall). That happens once per handover, so it cannot explain a sustained bounce.
Reasoning only.

The empty-car guard (`:1546-1559`) only acts when no player owns the car, so it cannot flip a driven
car.

**No steady flip-flop was found.** Nothing hands a driven car back and forth every frame or every few
frames. The candidates are all one-off events (b is the one worth measuring). The instrument for that
is already in the tree: `VehicleClient` reports any per-Stepped vertical-speed change over 20 as
`VehicleJolt` with the `ServerControl` flag (`VehicleClient.client.lua:536-551`), and the server
counts and prints them as `[VehicleJolt] #N` (`VehicleService.lua:1693-1708`). After Oliver's next
playtest, the count of those lines is the number for #84.

## 6. The Studio probe

`tools/vehicle_stability_probe.lua` (in tree) is ready to queue for what it covers. It drives every
car **and bike** found in both `Handling` and `Models`, so it picks up the two armoured cars and the
bikes the sim misses. The lane is the sim's course. It uses two modes ("frame", and "split", which
emulates a frame with no physics step) and measures the outcome: airtime, the worst per-frame jolt, peak
|vy| and distance, where a car that never moves fails on distance. It carries a planted fault
(negated damping ratio on a Rotster) aimed at an invariant, and it reports the self-check.

What it lacks:
- **No jump and no flip.** Oliver's "done" includes "still lands cleanly off a real jump and still
  rolls if you flip it hard"; only the sim checks those.
- Its airtime is the dynamics' own `telemetry.grounded`, which is the code under test grading itself.
- Its course copies the sim's harsher lane (the 0.3 deck step, the 0.01 top stagger), not the real road.
  That is fine as a stress test, but it is not "a real road".
- It cannot see network ownership. No Studio probe can.

For the first two gaps I wrote a **new** probe, `tools/vehicle_landing_probe.lua` (in my branch,
**never run**). It runs every car on the sim's jump (20° kicker, 70 st/s) and flip (a 40 rad/s roll kick
plus 40 st/s of lift). Airtime is measured independently of the dynamics, as chassis height over the
ground against the ride height it settled at, and the dynamics' own count is printed alongside. It has
two planted faults, each aimed at an invariant: a negated damper must fail the jump, and a Rotster held
upright by an unlimited AlignOrientation must fail the flip. It compiles under stock Lua (after the
`+=` rewrite), and `lua_static_check` passes on it. Queue it the same way as the stability probe
(command in its header).

## 7. The three checks (my branch, run from the repo root with the lupa venv's python)

```
OK: no problems
files unbalanced: 0
lua static check: 435 files, 0 findings
```
The pattern stage printed `lua pattern check: 435 files, 8 rules, 4828 candidate sites, 139 findings`.
Without my probe file it prints `434 files, 8 rules, 4825 candidate sites, 139 findings`, so all 139
were already in the tree and my file adds none.

## What this does NOT prove

- **Nothing here ran in Roblox.** Every number is from a Python stand-in for the engine or from
  reading source.
- **It does not prove Oliver's cars stopped bouncing.** It proves that the new damper is stable in the
  sim at every frame-rate model tried, and that the old one was unstable only when frames outpace
  physics. Whether that happens in the real engine is unconfirmed (section 3).
- **It does not find the cause of #84 if Oliver played at 60 fps.** At 60 fps the sim's pre-fix numbers
  were already inside every bar. The ownership candidates in section 5 are reasoning, not
  measurements.
- Bikes, steering, lateral road features (one-lane stop lines, centre dashes, kerbs), grade creases and
  real body collision are not in the sim. The in-tree probe covers bikes and the real collision; mine
  covers jump and flip. Neither has been run.
- `tools/vehicle_landing_probe.lua` has never executed. Its planted faults have never fired. Until they
  do, its PASSes mean nothing.
- "Feels planted" is Oliver's to judge in a playtest. The `[VehicleJolt]` count is the number to bring
  back.

## Files (all new, all in my branch)

- `reports/car-bounce-proof.md`: this report
- `tools/car_bounce_audit_sim.py`: re-runs the in-tree sim with all six cars read from
  VehicleModels.lua (real mounts and densities), the two "every frame stepped" modes, an optional
  as-built road and optional low gravity, plus the damper-revert plant. It imports
  `vehicle_stability_sim.py` and does not modify it.
- `tools/vehicle_landing_probe.lua`: Studio probe for jump and flip, with two planted faults. Not run.
- `README-task-prove-car-bounce.md`: what the branch adds
