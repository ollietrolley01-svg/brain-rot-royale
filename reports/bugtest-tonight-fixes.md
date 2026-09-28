# Bug test: the build machine's fixes of 2026-09-25

Jacob's branch `task/bugtest-tonight-fixes`, cut from main **`d1e4f73`**, and every run below is on that
commit. Oliver's order (coordination/messages/2026-09-25-0300): "run bug tests", starting with "the
explosive-ammo, drop-picker and roadkill fixes the build machine is doing now". The six fixes are the ones
listed in coordination/messages/2026-09-25-0500-coordinator-your-work-landed.md.

Everything here was either measured outside Studio (Python + lupa, running the game's own Lua) or read from
source, and each claim says which. Nothing was run in Roblox. No game file or existing tool was edited.
Damage numbers use `CombatDamageScale` **0.736** (main since pc/ttk-plus-25).

## Verdict

**All six fixes do what they claim. None broke anything I could find next to it.** Each fix's own check
passes on `d1e4f73` with every planted fault caught (table below), and my new check adds 5 edge checks
that pass with 12 of 12 planted faults caught. I found **no bug that needs fixing before a playtest.**

What I did find is small: four rough edges the new rules leave (a round from a player who has left, a
driverless car against a "ratio'd" victim, a rounding test that reads a tiny hit as a vetoed one, and a
bot's cannon blast placed inside an armoured car), plus one thing Oliver may want to know about his
roadkill decision 4A. They are ranked below. None of them is a crash, and none undoes what a fix set out to
do.

Separately, the full quality gate on this tree turned up two things outside tonight's fixes: a red
`vehicle_models_runtime_check` (wheels leave their arches at full steer on three cars), and a gate wiring
bug that never runs `shed_loot_check`, whose town-keepout plant no longer bites. See "Other checks on
this tree".

| Fix (merge) | Verdict | Its own check on d1e4f73 | What I added |
| --- | --- | --- | --- |
| pc/explosive-followups (69a3187) | holds, with gaps | `explosive_dispatch_check`: 93 checks, 0 failed; plants 18/18 | X1; findings 1 and 4 |
| pc/drop-picker-reset (6b4e5e1) | holds | `vote_menu_proof`: OK, throw sweep of 168 points, 0 broke an invariant; plants 11/11 | read only (below) |
| pc/roadkill-rules (fbc5121) | holds, with gaps | `roadkill_proof_check`: 22 checks, 0 failed; plants 18/18 | K1, K2; findings 2, 3, 5 |
| pc/range-reload-fix (d53694f) | holds | `trial_guns_proof_check`: 52 checks, 0 failed; plants 16/16 | read only (below) |
| pc/clock-deadlines (e1fe0c0) | holds, with a gap | `clock_ratchet`: OK, 5/5 needles | C1 across the whole game; finding 6 |
| pc/bot-movement-smooth (443304b) | holds | `bot_lag_proof_check`: 0 failures; plants 14/14 | M1; note 7 |

## Findings, most important first

1. **A launcher round whose owner leaves the server mid-flight bursts on the team-mate in front.**
   Measured (X2). pc/explosive-followups made rounds fly on through their owner's team-mates
   (`ProjectileService.lua:185-195`, `mateInTheWay`). It decides "team-mate" from `creditable(entry.owner)`
   (`:189`), and a player who has left is no longer creditable (`:130-135`). So the round stops on the
   team-mate again, which is what the fix removed: the enemy behind is shielded. Measured in
   `explosive_dispatch_world` with a team-mate at z -15 and an enemy at z -30: all 4 launchers burst at
   z -14.2 to -14.4 (Tralala Thumper at -4.3) with the owner gone, against z -29.4/-29.5 with the owner
   present. The round already carries the team it was fired from (`entry.ownerTeam`, stamped at launch,
   `:472`), and `explode()` already uses it to spare that team (`:409`). The same stamp would do here.
   Rare (the shooter has to leave while the round flies) and harmless to the team-mate, who takes no
   damage in the game (the world has no ModeTeams, so it can't show that part).
2. **A "ratio'd" victim takes less from a driverless car than from a driven one.** Measured (K3). Oliver's
   decision 4A put the time-to-kill scale on a driverless hit (`VehicleService.lua:1057-1059`). But
   `DealDamage` applies two things only to a hit with an attacker (`CombatService.lua:453-459`): the
   time-to-kill scale and `DamageTakenScale`, the "ratio'd" status that makes its victim "take more from
   everyone". The fix copied the first and not the second. At 60 studs/s into a ratio'd victim (x1.5):
   **95.39 from a driven Rotster, 63.59 from the same car with nobody in it.** Whether a driverless car
   counts as "everyone" is Oliver's call. If it does, it's one more line beside `:1058`.
3. **The veto test reads a rounded number, so a hit under half a point counts as vetoed.** Measured (K4).
   `VehicleService.lua:1064` treats `dealt <= 0` as "the mode refused this hit". `dealt` is
   `math.floor(absorbed + min(amount, health) + 0.5)` (`CombatService.lua:476`), so it is 0 for any hit
   under half a point that did land. Two effects:
   - a graze at 12.3 studs/s takes 0.397 health and the body isn't thrown (harmless);
   - a victim left on **0.3 health**, hit at 60, **dies with `RoadkillThrow` cleared** (on 10 health it
     is kept). `DeathFxService.OnDeath` reads that attribute to throw the body, so this kill gets no
     throw. Health can be fractional because damage is scaled by 0.736. Rare, cosmetic.
   Asking the veto itself (`CombatService.DamageVeto`) instead of the rounded `dealt` would avoid both.
4. **A bot's cannon blast on someone in a vehicle goes off at the body, inside the cabin.** Reasoned, not
   measured. `BotService.lua:2010-2018` rolls where a bot's shot met a vehicle rider (hull, glass or open)
   and splits the bullet. The new blast (`:2025-2031`) ignores that roll and always goes off half a stud
   in front of the rider's root. In an armoured car the roll is "body" every time (sealed cabin: body 1),
   so the bullet reaches the rider at 8% while the blast goes off next to them. A player's cannon round
   in the same spot stops on the hull and blows up outside it. The rider's share is still cut by
   `VehicleCover.BlastShareFor`, so the gap is the distance and line-of-sight part of the blast. The
   Golden Sahur Cannon is the only gun with explosive ammo. Low.
5. **Oliver's decision 4A means a bailed car can hurt its old driver's team.** Measured (K5), and working
   as decided. A car its driver bailed out of at 60 hits the driver's own team-mate for 63.59 and throws
   them, credited to nobody, because there is no attacker to veto. The 02:15 DECISION message said option
   B would have stopped this; Oliver picked A. Listed so it isn't a surprise in a playtest.
6. **`MovementService.lua` still times seven things on `os.clock()`.** Reasoned. pc/clock-deadlines moved
   the bot glide (`:650`, `:688`) and the parkour move (`:972-977`) to `tick()`, as reported. Still on
   `os.clock()` in the same file: the jump pad cooldown (`:240`), the canopy's settle and timeout
   (`:429-440`), `LastGlass` (`:579`) and the 0.3 s ClientParkour gate (`:857`). COORDINATION says
   `os.clock()` is CPU time in Roblox. Under load the canopy would come off later and the gates would last
   longer. They are on the ratchet's baseline, so they are accepted today, not missed. None mixes clocks
   (C1).
7. **Note, not a bug: a bot's route continues to its end without a think.** Measured (M1's scene).
   `continueRoute` (`BotNav.lua:830-851`) moves `nav.moveTarget` on at each step, so the next arrival
   passes its check too. A bot the LOD rarely thinks for walks its whole route between thinks. That is
   the #99 fix working. The comment at `:826` says "only from the waypoint it handed", which reads
   narrower than what happens. Every other guard holds (M1: 14 cases).

Examined and found nothing: the other code that read spawn protection (`ModeTeams.DamageVeto` `:1333-1356`,
`GameMode.lua:437`'s last-resort pad (a comment; the pick is in ModeTeams), HudClient's `PROTECTED` pill `:4228`; all still work with protection
never granted), the three other clients that read `dropSelect`/`teamSelect`, `CancelReload`'s callers (one:
`RangeService.lua:141`), the removed `BlastCue` listener (nothing in the game sets the attribute or makes an
`Explosion`), and the bot animation handlers against vehicles, death and a new body (below).

## Per fix: what I checked

### pc/explosive-followups (69a3187): holds, with gaps

Claims: a bot's cannon explodes, rounds pass team-mates, small per-pellet blasts, both explosive checks
repaired.

- **(a) Does it do what it claims.** Measured: `explosive_dispatch_check` 93 checks, 0 failed, plants 18/18;
  `explosive_ammo_check` 23 checks, 0 failed. Both run on main.
- **(b) Next to it.** `CombatService.BulletBlast` has four callers on main (`CombatService.lua:802`,
  `BotService.lua:1969` and `:2025`, and the check). The pellet split changes the blast only for a gun with
  more than one pellet. No gun on main has both (X1: 1 gun with a bullet blast, the Golden Sahur Cannon, one
  pellet), so today the split changes nothing in play. `mateInTheWay` asks `CombatService.DamageVeto`, which
  also ends the owner's spawn protection (`ModeTeams.lua:1349`). With no protection granted (fbc5121) that
  side effect does nothing. Findings 1 and 4.
- **(c) Edges.** X1 runs the real `BulletBlast` on every gun with a bullet blast, on 1 to 12 pellets: the
  pellets add up to the whole (damage and wall damage), each is smaller than the whole, none is under 2
  studs, and one pellet is the ammo untouched. Holds, 12 pellet counts. Plants: 3/3.
- Bot blasts are not scaled by `BotDamageScale` (0.8), while a bot's bullets are (`BotService.lua:2003`). A
  bot's launcher rounds aren't scaled either, so the new blast matches them. Just so it's known.

### pc/drop-picker-reset (6b4e5e1): holds

Claims: a failed start clears `dropSelect`; the client gates the picker on Loading.

- **(a)** `vote_menu_proof` on main: 5 clients, 702 client moments, 0 violations; a throw at each of **168
  injection points** inside `startMatch` (a battle royale and a team match): 115 became a failed start and
  **0 broke an invariant**; plants 11/11. The fallback (`MatchService.lua:2290-2300`) clears `dropSelect`,
  `teamSelect` and `countdown`, then broadcasts before `VoteService.Close()`.
- **(b)** Read: the other readers of the flags are HudClient (`:4088`, `:4316`, `:4353`), TeamPickerClient
  (`:215`) and `VoteReveal.View` (`:94`). HudClient's `:4353` docks the event card on `dropSelect` without
  checking the state; with the server clearing the flag that's harmless. `ChooseDrop` (`:1093`) refuses a
  pick once the flag is down.
- **(c)** The throw sweep already covers every point I'd have planted. Nothing new added.

### pc/roadkill-rules (fbc5121): holds, with gaps

Claims: no spawn protection, vetoed hits don't throw, an armoured cabin shelters riders, driverless hits
scaled.

- **(a)** `roadkill_proof_check` on main: 22 checks, 0 failed, 0 findings; plants 18/18.
  `roadkill_check` 25/25 and `roadkill_momentum_check` 16/16.
- **(b) Next to it.** Spawn protection: `GameModes` sets 0 in both team modes, and every other mode has no
  value, which the two grant sites read as 0 (`mode.spawnProtection or 0`, `ModeTeams.lua:1623`, `:1728`). Nothing else in the
  game reads `IsProtected` or `SpawnProtected` except the veto and the HUD pill, both fine. The pad picker
  (`GameMode.lua:437`) still falls back to "the least bad pad" when every pad is refused; that spawn now
  has no protection (reasoned; it's what Oliver asked for). The cabin rule and mounted guns: a mounted
  gun's seat sits in a model with no `VehicleModel` attribute, so both `Sheltered` and `ShieldingVehicle`
  answer no (read). Crash damage between vehicles is separate code and unchanged. The driverless scale:
  findings 2, 3, 5.
- **(c) Edges, measured.** K1: for every seat of every model (9 models, 5 with a gunner seat; driver,
  passengers, gunner), parked and wrecked, the driver's client (`RoadkillPass.Sheltered`) and the server
  (`VehicleService.ShieldingVehicle`) agree with each other and with the rule: **58 seat states, all
  agree.** K2: an armoured car's gunner (the hatch is open) is still run over, 63.59 at 60 on both the
  Tartaruga Scout and the Camelo Carrier. Plants: 3/3.

### pc/range-reload-fix (d53694f): holds

Claims: `WeaponService.CancelReload` on a retake; dead BlastCue listener removed.

- **(a)** `trial_guns_proof_check` on main: 52 checks, 0 failed; plants 16/16, including "a retake of the
  gun in hand leaves its reload running". `range_give_check` 9 checks with both plants caught.
  `contracts_check` 0 problems.
- **(b)** Read: `CancelReload` (`WeaponService.lua:1930-1935`) does only what a slot switch already did
  (`cancelReload` at `:1528`, shared with `selectSlot` at `:1535`), and only when a reload is running. Its one caller
  pushes afterwards (`RangeService.lua:142-143`). The ammo pool is infinite, so there is no refund to get
  wrong. `ReloadEmpty` is left set, as a slot switch always left it; its one reader
  (`GunPoseClient.client.lua:167`) reads it only when a new reload starts.
- **(c)** Nothing new to plant beyond the check's own I2.

### pc/clock-deadlines (e1fe0c0): holds, with a gap

Claims: `tick()` for the CombatClient deadlines and the MovementService glide; ratchet baseline.

- **(a)** `clock_ratchet` on main: OK (35 files on the baseline, 5/5 needles).
- **(b) Next to it.** The danger in moving half of a pair of stamps is comparing a `tick()` value with an
  `os.clock()` one. C1 checks for exactly that, across the whole game: **49 files with a clock, 394 clock
  expressions, none mixed.** It follows plain names and table fields within a file, so it sees
  `shot.t` (set at `CombatClient.client.lua:802`) against `now` (`:716`) and `loadoutPushedAt` (`:2301`).
- **(c)** Plants 3/3: each puts one of the fix's own stamps back on `os.clock()`. Finding 6.

### pc/bot-movement-smooth (443304b): holds

Claims: animation tracks follow Running/StateChanged; waypoints chain on MoveToFinished; FindCover budget.

- **(a)** `bot_lag_proof_check` on main: 9 scenarios, 6240 frames, 12345 thinks, 0 failures; plants 14/14.
- **(b) Next to it.** Read: each bot table has one humanoid for its whole life (a respawn makes a new bot,
  `BotService.lua:6160`), so an old body's events can't drive a new body's tracks. In a vehicle seat
  `continueRoute` stands (`SeatPart`); `setMovementTrack` picks from the same state and speed rules the
  per-think code used, so a seated or downed bot gets what it got before. On death `StateChanged(Dead)`
  now picks idle (or fall) where the old code left the last track playing. DeathFxService turns the
  joints off or anchors the body, so that shouldn't show (reasoned). FindCover's new "budget" answer is
  one its callers already handled.
- **(c)** M1: `continueRoute`, cut from the real file, in 14 cases: it goes on only in the plain case,
  and stands when the bot is seated, dead, mid-parkour, has thought since, faces a jump, has a detour, is
  climbing, has a new route, was sent elsewhere, is off its waypoint, is at the route's end, has lost its
  route, or gave up (`MoveToFinished(false)`). Plants 3/3. Note 7.

## The check

`tools/tonight_fixes_bugtest_check.py` loads the fixes' own worlds (`roadkill_proof_world.lua`,
`explosive_dispatch_world.lua`) through their own loaders and runs new scenes against the real modules.
The clock scan reads every game `.lua` file. The route check cuts `continueRoute` and its helpers from the
real `BotNav.lua`.

```
ok   K1 the driver's client (RoadkillPass.Sheltered) and the server (ShieldingVehicle) agree with the rule on every seat, parked and wrecked  (58 seat states examined (9 models, 5 with a gunner seat, 6 sheltered): all agree)
ok   K2 a gunner in an armoured car's hatch is run over like anyone in the open (server Touched at 60)  (CameloCarrier gunner dealt 63.59 (want 63.59); TartarugaScout gunner dealt 63.59 (want 63.59))
ok   X1 every gun with a bullet blast, on 1-12 pellets: ... (1 gun(s) (GoldenSahurCannon (1 pellet)), 12 pellet counts examined: all hold)
ok   C1 no expression in the game puts a tick() reading against an os.clock() reading  (49 files with a clock, 394 clock expressions examined: none mixed)
ok   M1 a bot's MoveToFinished continues its route only when ... (14 cases: all as the fix says)
tonight_fixes_bugtest_check: 5 checks, 0 failed, 6 finding(s)
tonight_fixes_bugtest_check planted faults: 12/12 caught
```

The 12 plants each break an invariant the code must keep for good: the sweep sheltering a wreck, the
server sheltering the gunner, the armour covering the gunner, each pellet carrying the whole damage, wall
damage or radius, three of the fix's clock stamps put back on `os.clock()`, and three of `continueRoute`'s
guards removed.

The world's cars are boxes. Gunner seats are added to the armed models (`VehicleModels.Mounts`, read
from the real file) above the middle of the box, so K2's contact is a stand-in.

## Other checks on this tree

`tools/quality_gate.py --timeout-scale 3` on `d1e4f73`: **178 checks, 6 failed, planted faults 970/972.**
My new check was written after that run started; `quality_gate.py -k tonight` runs it on its own: 2 checks,
0 failed, planted faults 12/12. None of the six is in a file tonight's fixes touched. I ran each one again on
its own:

- `bot_driving_sim.py`: the known red the coordinator named (CrocodiloRanger lap). Not looked at.
- **`vehicle_models_runtime_check.py`: red on main, not reported before as far as I can see.** Measured:
  10 faults, all "comes away from what carries it at steer +/-32-34 deg, suspension extended": all four
  wheels of the Sahur Van and the Tartaruga Scout, and both front wheels of the Tralala GT (the wheel
  loses every rest contact with its arch panels). Its 8 plants are all caught. The files it reads last
  changed in 52a5608, 47200d3, 14eebfd and its revert 9c44f4b; I didn't bisect.
- **`shed_loot_check.py` is never run by the gate.** Measured. `quality_gate.py:91-92` treats a script that
  uses argparse as taking no root, but `shed_loot_check.py:140` requires one, so the gate gets `exit 2`
  (usage) in 0.4 s. Run by hand with `.` it passes ("TOTAL failing checks: 0"), **but `--plant` catches
  only 1 of 2**: "the town keepout dropped ... on TralalaTown: 0 -> 0". That plant no longer bites, so
  nothing checks the town keepout for shed loot.
- `car_bounce_audit_sim.py`: passes on its own ("OK"). The gate reads its line "caught on 4/6 cars" as
  two missed plants (`10/12`). A parsing mismatch, not a failing car.
- `roads_check.py --plant`: timed out at 1800 s on a loaded machine. Not re-run.

## Unmerged branches

Of the four the brief names, only `pc/teambase-v2` touches these files (`git diff --stat
origin/main...origin/pc/teambase-v2`): `GameModes.lua` (a team insignia; no `spawnProtection`), `BotNav.lua`
(the drive route only, not `continueRoute`), `BotService.lua` and `ModeTeams.lua` (neither touches the veto,
protection, animation or the bot blast). It predates 443304b, so it needs a merge, but I found nothing it
would change here. `pc/ttk-plus-25`, `pc/hitreg-fixes` and `pc/mounted-guns-powerful` have nothing left
that isn't on main.

## What I did NOT prove

- Anything in Roblox. The roadkill and blast worlds are one machine with box bodies; Humanoid events,
  physics contact and animation playback are stand-ins or not modelled.
- Finding 4 is reasoning. I didn't build a sealed cabin in the blast world, so the size of the gap
  (distance falloff and line of sight through the hull) is not measured.
- Whether `Humanoid:ChangeState(FallingDown)` does anything to a bot, whose `FallingDown` state is turned
  off at spawn (`BotService.lua:6186`). `VehicleService.lua:989` knocks a bot down before a roadkill throw
  and its comment says that was measured to make the bot fly. Not tonight's change, and platform
  knowledge I couldn't settle from here.
- How the new animation handlers look. The bot_lag harness measures which track plays against the
  motion; whether it looks smooth is for the coordinator's Studio.
- C1 is a text scan. It follows names within a file, not across modules or through function returns.
- The drop-picker and range-reload fixes: I read them and ran their own checks, and added no scenes.
