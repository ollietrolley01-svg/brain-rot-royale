# #57 / #110 roadkill: does it fire?

Jacob's branch `task/prove-roadkill`, cut from main `fafed9c`, first run on main `30e4e77`, then merged with
main **`f1bb3b4`** and run again. Since `30e4e77`, main changed the vehicle physics (52a5608: ride lift and a
rough-ground underside, in `VehicleService.lua`, `VehicleDynamics.lua` and `VehicleModels.lua`). No roadkill
code changed. Every check, plant and number below came out the same on `f1bb3b4`, and every line reference
is to `f1bb3b4`. `VehicleService.lua` gained one line at 349, so its references past that are one higher
than in the first version of this report.
I either measured things outside Studio (Python + lupa, running the game's own Lua) or read them from
source. Nothing was run in Roblox, and no game file or existing tool was edited.

OLIVER_LIST #57 says: "Roadkill with the cars. Built: damage scales with speed, nothing below walking
pace, never your own passengers." #110 is Oliver asking again, and its row says to prove it fires before
anyone touches it. Both rows are marked "in tree, unproven (commit 32de759, 41631ba)".

## Verdict

**It fires on main, in the code.** A player driving any of the nine vehicles into an enemy player or bot
hurts them. So does a bot at the wheel, and so does a driverless car still rolling. Riders of the car,
team-mates, spawn-protected enemies and anything at or under 12 studs/s are never hurt. A kill reaches
the kill feed as `driver ➜ victim [Roadkill]`. I ran the real modules whole, through their real entry
points (details below): **16 checks pass and 11 of 11 planted faults are caught.** Nothing on main
switches roadkill off: no flag, no mode check, no ownership state, and not the parked-car rest hold.

**Problems found, most important first:**

1. **Nobody has ever run a player-driven roadkill in Roblox, and one Roblox fact decides whether it works.**
   (On main.) Since 7fab339, a player's car is swept by the driver's own client, and the hit is reported
   to the server (`VehicleRoadkill`). The server then caps the speed it believes at
   `seen * 1.15 + 4` (`VehicleService.lua:1091`). `seen` is the server's own copy of the car's
   velocity. The other route, the server's `chassis.Touched` (`:1061-1065`), reads the same copy. If
   the server read 0 for a car a client owns, the cap would be 4 studs/s, under the 12 floor, and
   **every player's roadkill would be silent: no damage, no marker, no feed line.** I planted exactly that fault in a
   copy of the game (see "My own planted fault"): 8 of my 16 checks fail. Roblox does replicate a
   client-owned assembly's velocity to the server, and `checkHonest`'s speed limit relies on the same
   read, so I expect it to work. That is platform knowledge, though, not a measurement. The Studio probes that exist
   (`vehicle_health_probe.lua`, `roadkill_momentum_probe.lua`) drive **server-simulated** cars, and
   HANDOFF says a probe cannot run a LocalScript, so the client path has never run in Studio. It needs
   a two-person playtest (see "For the coordinator").
2. **A vetoed hit still throws the body.** (On main, `VehicleService.lua:1031-1052`.) `roadkill()` sets
   up the throw and launches a survivor whatever `CombatService.DealDamage` returned. A team-mate in a
   team mode, and an enemy under spawn protection, take **0 damage but are launched** at
   `(26, 40, -40)` studs/s from an 84 studs/s car (MovementService "blast"). A bot team-mate is also
   knocked `FallingDown` first. Measured: the `FINDING` lines of `tools/roadkill_proof_check.py`. The
   crash grace opens too. A throw of 40 up and 40 forward can put someone off a ledge or into the storm,
   so a team-mate can still die of it (credited to nobody). Whether a team-mate should be shoved at all
   is Oliver's call. Throwing a spawn-protected player looks unintended.
3. **Someone sitting in another vehicle can be run over, armour or not.** (On main.) `RoadkillPass`
   filters only its own car's riders (`RoadkillPass.lua:196-202`). `roadkill()` checks neither
   `VehicleService.CabinShield` nor the cover rules c8736d2 added for bullets and blasts. In the harness, a
   bot's car T-boning a parked armoured **Tartaruga Scout** at 60 dealt **79.49** to its near-side
   driver, landing while the rammer's nose was still **1.03 studs** short of the hull. The far-side
   passenger took 0. This uses box bodies, not the real models, so the distances are approximate
   (reasoning, not a measurement of the real car). Whether ramming a car should roadkill its riders,
   through an armoured cabin, is Oliver's call.
4. **A driverless car hits 8.7% harder than a driven one.** (On main.) A car its driver bailed out of
   credits nobody. That is intended: the comment at `VehicleService.lua:963-964` says a car nobody is
   driving "still hurts, credited to no one, as before". The side effect is that the 0.92 time-to-kill
   scale is skipped, because `DealDamage` scales only a hit that has an attacker
   (`CombatService.lua:447-448`). The team veto is skipped for the same reason. Measured: a Tralala GT
   bailed out of at 60 hit a player for **86.40** (60 − 12) × 1.8, against **79.49** for the same car
   driven. It gave no kill-feed name and no quest progress. Minor. Whether the bailer should get the
   kill is Oliver's call.
5. **A Sahur Van at full speed leaves an unshielded player on 0.64 health.** (Balance, on main.) The van
   tops out at 72 (`VehicleDynamics.lua:97`) and deals **99.36**. A one-hit kill on 100 health needs
   **72.39** studs/s. The Tartaruga Scout (96.05), Bananini Scoot (89.42) and Camelo Carrier (82.80) are
   also short. For Oliver, if "a van at full speed kills" matters to him.
6. **Stale numbers in a comment.** (On main, `VehicleService.lua:119-125`.) The comment gives 10.8 at
   walking pace and 183.6 at 114. Both are from before `CombatDamageScale` 0.92 (#111). The real numbers
   are **9.94** and **168.91**. The claim they support (a full-health, full-shield player survives the
   worst hit) still holds: measured, the victim was left on 31.09 health.

**Why Oliver asked again (#110).** His re-ask came on 09-21, about three hours after the repo's first
commit (741042c, 09-21 18:45). In that code a roadkill kill **was silent in the kill feed**: `method`
was nil for "Roadkill", so the row read `A ➜ B` with no tag (fixed by 32de759, 09-24). A **bot**
driver's roadkill credited nobody (fixed by 41631ba, 09-24). A player's car relied on the server's
`Touched` alone, and the body was a solid obstacle the car stopped dead on (the header of
`RoadkillPass.lua` describes this). All three fixes, plus the client report path (7fab339), first
shipped together in `playtest-2026-09-24-2000` (main 8f16a5f). That build is the first one where
Oliver could see the current behaviour.

## 1. The path, end to end (on main f1bb3b4)

**Detection. There are three ways in, and all three reach one function, `roadkill()`
(`VehicleService.lua:995-1059`):**

| Who simulates the car | What detects the contact | Where |
|---|---|---|
| The driver's client (a player at the wheel; the server hands the chassis over in `updateOwnership`, `VehicleService.lua:1449-1476`, `SetNetworkOwner` at `:1458`) | `RoadkillPass:Sweep` in VehicleClient's `RunService.Stepped` loop (`VehicleClient.client.lua:472`, sweep at `:493`, skipped while `ServerControl` is set, `:483`). The sweep uses a `GetPartBoundsInBox` look-ahead of 2.5 frames of travel plus 0.6 studs round each collider (`RoadkillPass.lua:195-222`). A live body is reported once: `FireServer(model, character, speed)` (`VehicleClient.client.lua:386-388`) | Server: `Remotes.Event("VehicleRoadkill")` handler (`VehicleService.lua:1688-1693`), rate limit 8 burst, 4/s (`RateLimit.lua:85`), then `onRoadkillReport` (`:1070-1092`) |
| The server (a bot at the wheel, an empty car, a car the honesty check took back) | `entry.roadkillPass:Sweep(dt, now)` in `step()` (`VehicleService.lua:1575-1577`). It runs before the registered-kind hook and before the parked rest hold, so a1eb7a8 does not skip it | `roadkill()` directly, through the callback made in `Create` (`:1398-1400`) |
| Either | `chassis.Touched` on the server (connected in `Create`, `:1438-1440`) | `onChassisTouched` (`:1061-1065`) |

A player-driven car is never swept by the server: the owner branch of `step()` returns at `:1563-1573`
before the sweep. The harness confirms it: the server's `roadkillPass.lastVelocity` stayed nil on all 9
player-driven cars.

**What the server believes from a client report** (`onRoadkillReport`): the car must exist and not be
wrecked. The reporter must be `entry.owner` (the player the server handed the chassis to) and sit in the
driving seat. The body must have a root within `10 + 0.3 * seen` studs of the hull (`hullDistance`): 19
studs at 30, 28 at 60, 44.2 at 114. The speed used is `min(reported, 1.15 * seen + 4)`, where `seen =
max(server's flat speed, entry.lastFlatSpeed)`. So the server does not trust the client's speed; it
trusts its own copy of the car's velocity (problem 1).

**The vetoes, in the order they run** (`roadkill()`):
1. No humanoid, or already dead: nothing (`:996-999`).
2. **Any rider of this car** (`entry.occupants`, driver included): nothing (`:1000-1004`).
   `RoadkillPass` also leaves its own riders out of the look-ahead (`:196-202`, `isRider` `:124-131`).
3. **Walking pace**: `flat <= ROADKILL_FLOOR` (12, `:131`), checked before the debounce is armed
   (`:1006-1008`). The client sweep has the same floor (`RoadkillPass.FLOOR = 12`, `:34`), and
   `roadkill_check` holds the two equal. Walking speed is 18 (`MatchConfig.BaseWalkSpeed`), so a car at
   walking pace does hurt (9.94). "Nothing below walking pace" is true of anything under 12.
4. **Debounce**: 0.5 s per victim per car (`:133`, `:1010-1021`). The keys are strong, so a Touched and
   a report for one body inside 0.5 s make one hit (measured).
5. The body must be a combatant (`Combatants.FromCharacter`, `:1022-1025`).
6. **The driver themself**: `driverToken == victimToken` returns (`:1027-1030`).
7. Then `CombatService.DealDamage(driverToken, victimToken, (flat - 12) * 1.8, "Roadkill", false)` (`:1044`).
   `DealDamage` (`CombatService.lua:424`) applies the **mode's veto** (`:432`,
   `ModeTeams.DamageVeto`, `ModeTeams.lua:1333-1356`: team-mates and spawn protection, hung on only in a
   team mode, `GameMode.lua:733`). Then the **0.92 time-to-kill scale** when there is an attacker
   (`:447-448`), then the shield, then `TakeDamage`.

**Credit.** `roadkillDriverToken` (`VehicleService.lua:965-969`): `Combatants.FromCharacter` of whoever
sits in the driving seat. That covers players and bots alike (41631ba), and bots drive every vehicle
since 0f0f28e, through `VehicleService.BotSit`, `BotService.lua:4563`. The credit is stored as
`lastAttacker[victim] = { driver, "Roadkill" }` (`CombatService.lua:474`), read back by `HandleDeath`
(`:1237`).

**What each side gets:**
- **The driver** (player): `DamageDealt` (`CombatService.lua:487`). HudClient draws the red "X" and the
  damage number and plays `HitConfirm`. On a kill it shows "ELIM" and plays `Elimination`
  (`HudClient.client.lua:433-474`), and KillFeedback plays `KillConfirm` with the ELIMINATED badge
  (`KillFeedback.client.lua:117`). A vetoed hit gets the grey "+" instead (`CombatService.lua:432-440`,
  measured).
- **The victim** (player): `DamageTaken` with the driver's position (`:501`): the red direction arc. A
  survivor is thrown along the car's travel (`RoadkillPass.Throw`, `MovementService.Launch` "blast");
  a bot is knocked down first (`VehicleService.lua:984-987`). On death, the recap names the driver and
  "Roadkill" (`:1225`, measured), and the ragdoll carries the throw (`RoadkillThrow`,
  `DeathFxService.lua:715`).
- **Everyone**: the kill feed row `driver ➜ victim [Roadkill]`. `CombatService.OnElimination`
  (`MatchService.lua:1658-1675`, 32de759 at `:1670`) sends it (`:1573`). A respawn mode sends the same
  `method` from `GameMode.lua:662`.

**Momentum (7fab339, `RoadkillPass.lua`).** Over the floor, a body is let through the car
(NoCollisionConstraints, every collider × every limb, plus the riders' solid parts). The car gives up
its **toll** of flat speed per live body: bike 4%, car 2.5%, armoured 1% (`:45`). It keeps its heading,
vertical speed and spin. A dead body goes through for free. The crash check ignores the speed change
for 0.4 s (`ROADKILL_GRACE`, `VehicleService.lua:138`, used at `:940`). The throw at speed `v` is
`forward min(0.6v, 40)`, `sideways min(0.45v, 26)`, `up clamp(14 + 0.35v, 16, 40)` (`:66-79`). Measured:
an enemy behind a team-mate took the hit at 84 × 0.975 (115.75 dealt), because the car paid the toll
going through the team-mate.

## 2. Damage table (on main)

Damage = `(v - 12) × 1.8 × 0.92` for a driven car. Sources: `ROADKILL_FLOOR` and `ROADKILL_DAMAGE_PER`
(`VehicleService.lua:131-132`), `MatchConfig.CombatDamageScale` (`MatchConfig.lua:107`), top speeds
from `VehicleDynamics.Handling` (`VehicleDynamics.lua:73-140`). There are **nine** models, not six: six cars
(two of them armoured) and three bikes. The "dealt" column is **measured** through the real modules,
not computed. The "marker" column is the whole number the driver's HUD shows.

| Model | Kind | Top speed | Dealt at top speed | Marker | Kills 100 HP, no shield? | Kills 100 + 100 shield? |
|---|---|---|---|---|---|---|
| Brr Streetfighter | bike | 114 | 168.91 | 169 | yes | no (31.09 left) |
| Tralala GT | car | 106 | 155.66 | 156 | yes | no |
| Patapim Scrambler | bike | 90 | 129.17 | 129 | yes | no |
| Rotster | car | 84 | 119.23 | 119 | yes | no |
| Crocodilo Ranger | car | 78 | 109.30 | 109 | yes | no |
| Sahur Van | car | 72 | 99.36 | 99 | **no, 0.64 left** | no |
| Tartaruga Scout | armoured car | 70 | 96.05 | 96 | no | no |
| Bananini Scoot | bike | 66 | 89.42 | 89 | no | no |
| Camelo Carrier | armoured car | 62 | 82.80 | 83 | no | no |

Boundaries (worked out from the same three numbers):

| Speed (studs/s) | Dealt | What it is |
|---|---|---|
| 0 to 12 | 0, and no throw | the floor (measured at 0, 4, 8, 11.9, 12 by every path) |
| 12.5 | 0.83 | just over the floor (measured) |
| 18 | 9.94 | walking pace, `BaseWalkSpeed` (measured) |
| 26.1 | 23.35 | sprinting, 18 × 1.45 (measured) |
| 72.39 | 100 | one-hit kill on 100 health, no shield |
| 132.77 | 200 | one-hit kill on full health + full shield: faster than any vehicle |
| 67.56 | 100 | one-hit kill by a **driverless** car, which is not scaled (problem 4) |

## 3. The check: `tools/roadkill_proof_check.py` (new, in my branch)

It loads **VehicleService, CombatService, RoadkillPass, Combatants, RateLimit, Remotes, SafeValue,
VehicleArmor, VehicleCover, MatchConfig and MovementConfig whole** in lupa
(`tools/roadkill_proof_world.lua` is the world). It cuts four pieces from real files and runs them
as they are:
- VehicleClient's `RoadkillPass.new(...)` with its `FireServer`, and the head of its `Stepped` loop down
  to the sweep. These run as the driver's machine.
- MatchService's `CombatService.OnElimination`, which builds the feed's method.
- ModeTeams' `DamageVeto`, `IsProtected`, `BreakProtection` and `protectionNowMs`.

The stand-ins are:
- `VehicleDynamics`: the real Handling table cut from the file, a rig with four grounded wheels, and a
  `Step` that only records.
- `VehicleModels`: the real id, kind and display name, with a box body.
- `WeaponService`: a shield per token.
- `MovementService`: records launches.
- A small Roblox instance model: parts, seats, signals, network owner, ground plane, box query.

There is no physics. A scene sets the chassis velocity, and each frame moves the car and its riders.
Every vehicle is made by the real `VehicleService.Create`. Players sit through the real drive prompt
(`trySit`), bots through `VehicleService.BotSit`. The service is stepped by the `Stepped` handler that
`VehicleService.Start` connects.

**Examined:** 9 of 9 models with a player at the wheel, 9 of 9 with a bot at the wheel, 18 more vehicles
in the other scenes, and 5 under-floor speeds × 4 paths.

Verbatim, on main f1bb3b4:

```
ok    I1 every model, player driver at top speed into an enemy player: the driver's client reports it, the server deals (top-12)*1.8*0.92, credits the driver, marks the driver's HUD and the victim's  (9 models: BananiniScoot 66.00->89.42, BrrStreetfighter 114.00->168.91, CameloCarrier 62.00->82.80, CrocodiloRanger 78.00->109.30, PatapimScrambler 90.00->129.17, Rotster 84.00->119.23, SahurVan 72.00->99.36, TartarugaScout 70.00->96.05, TralalaGT 106.00->155.66)
ok    I1 a player driver into a bot: dealt and credited  (dealt 79.49 want 79.49, credited driver_botvictim)
ok    I2 every model, bot driver at top speed into a player: the server's own sweep deals it and credits the bot  (9 models)
ok    I6 a player's roadkill kill: the feed row names the driver and "Roadkill"; the driver gets an ELIM marker, the victim a recap naming Roadkill  (feed: feed_driver -> feed_victim [Roadkill]; marker kill=true; recap weapon Roadkill)
ok    I6 a bot's roadkill kill: the feed row names the bot and "Roadkill"  (feed_bot [Roadkill])
ok    I3 riders are never hurt by their own car (player-driven and bot-driven, client sweep, server sweep, Touched, a report naming them)  (driver 1000.00 passenger 1000.00 bot driver 1000.00 bot's passenger 1000.00)
ok    I4 at or under 12 studs/s nothing happens: no damage, no throw (0, 4, 8, 11.9, 12; client report, Touched, forged report, server sweep)  (most dealt 0.00, thrown 0)
ok    I4 just over the floor the formula holds: 12.5, walking pace 18, sprinting 26.1 studs/s  (12.50 -> 0.83, 18.00 -> 9.94, 26.10 -> 23.35)
ok    I5 team mode: a team-mate is never hurt (player driver, bot driver), an enemy behind them is  (mate 1000.00, bot's mate 1000.00, enemy dealt 115.75 (want 115.75: the car paid the 2.5% toll going through the mate))
ok    I5 team mode: an enemy under spawn protection is never hurt  (health 1000.00)
ok    the vetoed hit gives the driver the grey "+" (#86), not silence  (kind structure)
ok    the server's chassis.Touched (Create connects it) deals the hit on its own, and a report of the same body inside 0.5 s adds nothing  (Touched 62.93, then report 62.93)
ok    reports refused: from a passenger, and of a body 200 studs off  (side 1000.00, far 1000.00)
ok    a report's speed is held to what the server saw (50 -> at most 50*1.15+4)  (dealt 81.97 want 81.97)
ok    a1eb7a8: a parked car is held at rest, and one shoved into someone at 40 still hits (the sweep runs before the hold), unscaled and credited to nobody  (held true, dealt 50.40)
ok    a full-health, full-shield player survives the fastest bike at its top speed (114)  (health left 31.09, shield left 0.00)
FINDING a team-mate the car goes through takes no damage but is still thrown  (launch (26.00, 40.00, -40.00) (MovementService.Launch "blast"); a bot team-mate knocked down: true)
FINDING an enemy under spawn protection takes no damage but is still thrown  (launch (26.00, 40.00, -40.00))
FINDING a car its driver bailed out of still hurts, credited to nobody as intended, but skipping the 0.92 scale and the team veto  (dealt 86.40 (want (60-12)*1.8 = 86.40), credited nil, owner false; the driver kept 100.00 health)
FINDING riders of another vehicle are roadkill too: a car T-boning a parked armoured Tartaruga Scout at 60  (near-side driver dealt 79.49 (the rammer's nose 1.03 studs short of the hull when it landed), far-side passenger dealt 0.00)
roadkill proof: 16 checks, 0 failed, 4 findings
```

**Planted faults** (`--plant`: each is applied to the game's text in memory, and each is aimed at an
invariant, not at a bug). **11 of 11 caught:**

```
CAUGHT I1: the server drops every driver's report
CAUGHT I1: the driver's client never reports (VehicleClient's FireServer gone)
CAUGHT I1: the server never hands the car to its driver (it sweeps it itself)
CAUGHT I1/I2: the driver's credit lost
CAUGHT I2: the server's step skips the sweep
CAUGHT I3: riders not excluded (server and sweep)
CAUGHT I4: no server-side floor
CAUGHT I5: DealDamage skips the mode's veto
CAUGHT I6: the kill feed drops the Roadkill name
CAUGHT Touched no longer connected
CAUGHT damage retuned (the report's table would be stale)
roadkill proof plants: 11/11 caught
```

(The full lines also name which checks failed.) The last plant is deliberate. The damage numbers are
pinned in the check (`PIN_FLOOR`, `PIN_PER`, `PIN_SCALE`), not read from the game, so a retune fails the
check until this report's table is redone. The first version of the I4 plant was **missed**, and I kept
that result: with the server's floor removed, `DealDamage` still refuses a negative amount, so the
damage stayed 0. What the floor also stops is the throw. I4 now asserts "no throw" as well, and the
plant is caught.

`python tools/quality_gate.py -k roadkill` runs it with the other two roadkill checks: `6 checks, 0
failed, 1 skipped; planted faults 34/34 caught`.

### My own planted fault, in a copy of the game

I made a temp copy of the tree (`git archive HEAD`), then edited its `VehicleService.lua`, line 1087,
so the server reads a client-owned car's speed as 0. This is the Roblox failure in problem 1:

```
-	local seen = math.max(Vector3.new(velocity.X, 0, velocity.Z).Magnitude, entry.lastFlatSpeed or 0)
+	local seen = Vector3.new(velocity.X, 0, velocity.Z).Magnitude * 0
```

`roadkill_proof_check.py` on the copy: **`16 checks, 8 failed`**. The player-driven cars dealt 0 on all
9 models (`I1 a player driver into a bot ... dealt 0.00 want 79.49`). The bot-driven cars and the server
paths (I2, the parked car, Touched) still passed, which is what that fault predicts. The existing
`roadkill_check.py` also catches it (`25 checks, 2 failed`).

## 4. The existing checks, honestly

`tools/roadkill_check.py` (41631ba, finished in 7fab339, mocks fixed in 441238c and 1a51602). **It runs
on main**, and the "mid-edit" in 7fab339's title no longer applies: `25 checks, 0 failed`, `--plant`
11/11. It runs **the real text** of the roadkill section of VehicleService, `DealDamage`,
`GetLastAttacker` and `DamageVeto`, each cut from the file, not copied by hand. Around them it puts its
own stand-ins:
- `MatchConfig.CombatDamageScale = 1`. Its numbers are **not the game's**: it expects 49.6 at 40 where
  the game deals 46.37 (28 × 1.8 × 0.92).
- `ModeTeams.IsProtected` always false, so **spawn protection is never tested**.
- `hullDistance` is a point distance.
- `RoadkillPass` is a stub.
- Its own `Combatants`.

It never runs `step()`, `Create`'s wiring, `Start`'s remote hook-up, VehicleClient, `HandleDeath` or the
kill feed.

`tools/roadkill_momentum_check.py` (7fab339): **runs on main**, `16 checks, 0 failed`, `--plant` 12/12.
It runs the real `RoadkillPass` whole on the real `VehicleArmor`, with its own mocks for the world.

**What they miss.** I applied each of my 11 plants to a copy of the tree and ran both existing checks on
it:

| Plant | `roadkill_check` | `roadkill_momentum_check` |
|---|---|---|
| the server drops every driver's report | missed | missed |
| the driver's client never reports | missed | missed |
| the server never hands the car to its driver | missed | missed |
| the driver's credit lost | CAUGHT | missed |
| the server's step skips the sweep | missed | missed |
| riders not excluded | CAUGHT | missed |
| no server-side floor | CAUGHT | missed |
| DealDamage skips the veto | CAUGHT | missed |
| the kill feed drops the Roadkill name | missed | missed |
| Touched no longer connected | missed | missed |
| damage retuned | missed (by design: it reads the constants) | missed |

Every fault that would make roadkill **silent**, meaning wired to nothing, gets past both existing
checks. That is the gap `roadkill_proof_check.py` fills.

## What this does NOT prove

- **Roblox's physics and networking.** The world is one machine with no physics. It does not show
  that the server's copy of a client-owned car's velocity is right (problem 1), that Roblox fires
  `chassis.Touched` on the server for a client-owned car, or what the NoCollisionConstraints and the
  new velocity do in a real simulation. Lag between the driver, the server and the victim is not
  modelled either. The reach allowance (`10 + 0.3 × seen` studs) is worked out from source, not tested
  under lag.
- **Anything drawn or heard.** "The driver gets the marker" means the server sent `DamageDealt` with
  the right numbers. The HUD code that draws it was read, not run. Whether the throw looks and feels
  right is Oliver's to judge.
- **The real vehicle shapes.** Bodies here are boxes (car 6 × 2.5 × 12, bike 2 × 2.5 × 6) with seats
  near the real offsets. The damage per speed does not depend on shape. Problem 3's distances do.
- **The kill feed's final text.** The check reads the `method` MatchService builds. The feed's text
  (`HudClient.client.lua:2957`) was read, not run.
- Bots' **choice** to drive at people (`BotDriveTactics`) was not examined, only that a bot at the wheel
  deals and is credited.

## For Oliver (product calls, not bugs)

1. Should a team-mate, or a spawn-protected enemy, be thrown by a car that can't hurt them (problem 2)?
2. Should ramming a car roadkill the people inside it, including through an armoured cabin (problem 3)?
3. Should the player who bails out of a moving car get the roadkill it makes (problem 4)? Today nobody
   does, on purpose, and the hit skips the 0.92 scale and the team veto.
4. The Sahur Van at full speed leaves an unshielded player on 0.64 health. Should a van kill in one hit
   (problem 5)?

## For the coordinator

- The one measurement that closes problem 1: a **two-person** playtest (or Studio's local server with
  two players), where one person drives a player-driven Rotster at full speed into the other and reads
  the kill feed for `[Roadkill]`. A server-side count like `[VehicleJolt]`'s, of `onRoadkillReport`
  accepts and refusals with the `seen` speed, would turn "it didn't happen" into a number. That is a
  change to a game file, so it is yours to make if you want it.
- Problems 2 and 6 are in `VehicleService.lua`; 3 is in `VehicleService.lua` and `RoadkillPass.lua`;
  4 is `CombatService.lua:447-448` meeting a nil attacker.
  I have not touched them.

## Files

- `reports/roadkill-proof.md`: this report.
- `tools/roadkill_proof_check.py`: the check (`--plant` for the planted faults).
- `tools/roadkill_proof_world.lua`: its world (read as Luau by the static checks, run as Lua by lupa).
- `README-task-prove-roadkill.md`: what the branch adds.
