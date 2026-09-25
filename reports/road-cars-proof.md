# #51 old road cars can't be destroyed: do they break now?

Jacob's branch `task/prove-road-cars`, cut from main **`d1e4f73`** and run on it. Every line reference is
to `d1e4f73`. The measurements were taken outside Studio, with Python and lupa running the game's own
Lua. The rest was read from source, and each claim says which. Nothing was run in Roblox, and no game
file or existing tool was edited.

OLIVER_LIST #51 says: "Old road cars can't be destroyed. Cause known (parts literally named "Part",
damage looked up by name)." It is marked "in tree, unproven (commit 21c6199, 81c1263, d2be199; merged to
main)". #16 and #94 (the parked cars rebuilt from the real drivable designs, 951ec86 and 69cd028) change
which cars those are, so this proof covers every road car on main, not only the old ones.

## Verdict

**Every parked road car on main breaks, in the code.** There are 79 of them on five generated maps:
34 at the kerb, 32 on driveways and 13 in car parks. Every one is a real design. None of the old 11-part
box cars is left. Each car is one pool of 240 health. All **1,728** parts that a ray can hit, on those
cars and on 8 wilds wrecks, reach their car's pool. None fails to. Bullets, rockets, frags, stickies and
barrels all break them. Damage never fades, nothing is left standing, no pool entry leaks, and a
broken car takes no more damage. I ran the real DestructibleService, CombatService and ProjectileService
on maps built by the real MapGenerator: **0 failures, and 9 of 9 planted faults caught.** The old cause
is gone. The pool is found through the Model's `DestructibleHealth` attribute, so a part's name no
longer matters (`DestructibleService.lua:549-566`, `:588-594`).

**Problems found, most important first:**

1. **The same car has two health systems.** (Measured and computed, on main.) Since #16/#94, a
   parked car is the same model as the drivable one. The parked Tralala GT breaks after **9** hits of
   the Crocodilo Rifle: its pool is 240, and map damage is raw `def.damage`, with no
   `CombatDamageScale`. The drivable Tralala GT takes **71**: 1,400 health, at 27 × 0.736 = 19.87 a
   hit, by `VehicleService.DamageVehicle`'s formula (`VehicleService.lua:1167-1170`). Across the four
   parked designs the drivable takes **7.9x to 9.3x** as many hits: Rotster 76, Crocodilo Ranger 81,
   Sahur Van 84. Rockets: a parked car needs 2 (measured, wallDamage 150). A drivable needs 3 to 4
   (VehicleArmor's own comment, `VehicleArmor.lua:32-34`, not measured here). A player can't tell the
   two apart by looking, so the same-looking car melts in one place and soaks a magazine in another.
   Whether that matters is Oliver's call.
2. **A wrecked drivable can't be destroyed, and it still blocks, for the rest of a battle royale
   match.** (Measured: section G of the check, through the real VehicleService.) When a Tralala GT is
   wrecked, it stays in the map. It keeps `Wrecked`, its chassis still collides, and
   `CombatService.VehicleFromPart` still claims it, so a bullet stops on it
   (`CombatService.lua:955-956`). Every later hit deals **0**: `DamageVehicle` returns early on a wreck
   (`VehicleService.lua:1159-1162`). DestructibleService refuses it too, because of `VehicleMaxHealth`
   (`DestructibleService.lua:416`). Only a team base's own vehicles are cleared, when they respawn
   (`ModeTeams.lua:1151-1156`). This answers the question "can a road car be both indestructible and
   blocking": **no static car can. A wrecked drivable is exactly that.** It is also inconsistent to
   look at: a parked car that breaks leaves nothing behind, while a drivable of the same design leaves
   a wreck.
3. **The noclip AdminOverride hits a car twice per bullet, at full damage both times.** (Measured on 5
   cars: 8 hits from 4 shots, 34 each.) `CombatService.lua:930-939`: after a destructible hit, a round
   with `walls > 0` leaves out only the part it struck and flies on. The next part of the **same car**
   counts as the second wall. The map is also dealt `def.damage` each time (`:920`), never
   `def.damage * through`, which is what a vehicle gets (`:956`). So a car takes 68 a bullet instead of
   34 + 0, or 34 + 23.8. The second half of this (reasoning, not measured) applies to any two walls in a
   row. The gun is Secret-tier (`ArsenalExpansion.lua:126`), so this is minor.
4. **A bot's bullets never hurt a parked car.** (Reasoning, from source.) A bot's hitscan shot isn't
   traced. Its cover check damages only RotBarricades (`BotService.lua:1268-1297`), and its
   line-of-sight test treats a car like a wall (`hasLineOfSight`, `:1023-1062`). Only a bot's launcher
   rounds (ProjectileService) break cars. A player crouched behind a parked car is safe from a bot's
   rifle until someone else breaks the car. Walls work the same way, so this is not new, but it is
   Oliver's to know.
5. **Ramming and melee: there is no path at all.** (Measured by search.) The game has no melee
   weapon: "melee" appears in no weapon or item data file. Nothing in vehicle code calls into
   DestructibleService (every caller is listed under "The path"). A car driven into a parked car takes
   crash damage itself. The parked car takes 0 (reasoning). Whether ramming should break a parked car
   is Oliver's call.
6. **`CombatDamageScale` (0.736) does not touch map damage.** (Measured: 27 a hit, equal to the rifle's
   `damage`.) The +25% time-to-kill did not change how long a parked car, a wreck or a wall lasts. That
   matches its own words ("every kill of a player, bot, vehicle or mounted gun"). Every number here
   holds at any scale.

Notes, not bugs:
- Only 18 to 24 of a parked car's 210 to 289 parts take a ray. These are the invisible hull boxes, the
  chassis, the cabin pillars and the roof panels. Wheels, mirrors and bumpers are
  `CanQuery = false`, so they are dressing that goes with the car. A shot aimed at a wheel lands on
  whatever hull box is behind it, or passes. The drivables are built the same way. Whether the hull
  boxes cover the body well enough to feel right is a picture question (see the gallery below).
- A blast can break the car next door. This happened once in the run, on BombardiroBay: blasts aimed
  at kerb cars (a rocket, a frag and a barrel there) broke a neighbour before its turn. The harness
  doesn't record which blast did it. This is how DamageInRadius works, not a fault.
- Wilds wrecks (the burnt-out cars in the country) are not road cars, but they are the other "car" on
  a map. Each is one group pool of 268 to 284 health, from its size and CorrodedMetal. They take 10 to
  11 rifle hits.

## 1. Which road cars exist on main, and how many (Q1)

Measured on five maps, built with the real `MapGenerator.Build` (seed 1 each):

| map | kerb | driveway | car park | drivable, car park | drivable, verge | wilds wreck | parts in map |
|---|---|---|---|---|---|---|---|
| SahurSprings | 8 | 6 | 4 | 6 | 7 | 0 | 48,691 |
| TralalaTown | 5 | 7 | 3 | 7 | 3 | 6 | 34,529 |
| BombardiroBay | 10 | 6 | 2 | 9 | 6 | 2 | 52,233 |
| RotRidge | 5 | 8 | 4 | 5 | 4 | 0 | 34,828 |
| PatapimPlains | 6 | 5 | 0 | 8 | 4 | 0 | 42,012 |
| **all** | **34** | **32** | **13** | **35** | **24** | **8** | |

- **Static, the #51 cars:** kerb (`MapDecor.Town`, `MapDecor.lua:2339`), driveway (`MapDecor.Driveways`,
  `:2438`) and car park (`MapDecor.ParkBays`, `:2548`). All three go through `parkedCar`
  (`:369-384`), which builds a real design with `VehicleModels.BuildStatic` (`VehicleModels.lua:3632`),
  names it `ParkedCar` and sets `DestructibleHealth = 240` (`MapDecor.lua:380`). The designs used
  were Crocodilo Ranger 21, Rotster 24, Sahur Van 17 and Tralala GT 17. Each car has 210 to 289 parts
  (18,980 in all). `DETAILED_CARS_PER_TOWN = math.huge` (`:307`), so the plain 11-part box car (the
  "old road car") is only a fallback when no design can be built. **0 of the 79** were plain.
- **Drivable:** `VehicleService.Create`, in car-park bays (`VehicleService.ParkInTowns`,
  `MapGenerator.lua:1189`, `:1244`) or on the country verge (`:1225`). These have their own health
  (VehicleArmor) and are never DestructibleService's (check F: 21,378 parts over 59 vehicles).
- **Wilds wreck:** `MapWilds` `wreck` (`MapWilds.lua:1507`), grouped as `Wreck:W<n>` (`:1616`). It
  sits in the wilds, not on a road.
- **Not built by this harness:** the battleground's 4 wrecks in team modes (`TeamBattleground.lua:1148`,
  pooled as `Wreck:bg<n>`), and the team bases' vehicles (ModeTeams, drivable). There are **no
  traffic cars** on main: the only "traffic" in the code is BotNav's list of vehicles around a
  driving bot.

## 2. The path, end to end (on main d1e4f73)

**The pool.** `keyOf` (`DestructibleService.lua:568-613`) asks `taggedModel` (`:549-566`) for the
nearest Model above the part that carries a string `Destructible` or a positive `DestructibleHealth`.
A ParkedCar is found that way from any part in it, whatever the part is called. The pool's health is
the attribute (`:594`). `resolvePool` (`:692-720`) takes every BasePart under the Model as a member,
and `entryFor` (`:726-756`) makes the entry on the first hit. The entry is dropped when the Model is
destroyed (`:749-753`). Two things are refused: anything outside `workspace.Map` (`mapRootOf`,
`:363-378`), and anything under a Model with `VehicleMaxHealth` (`ownerElsewhere`, `:416`).

**Every way damage can reach it** (every caller of the damage entry points, by search):

| route | where | what the car takes |
|---|---|---|
| a player's hitscan bullet | `CombatService.Fire` → `firePellet` → `DestructibleFromPart` → `DamageDestructible` (`CombatService.lua:918-920`) | the gun's `damage`, per pellet |
| a vehicle's or emplacement's gun | `VehicleWeapons.lua:290-292` | the spec's `damage` (reasoning, not run here) |
| every launcher round, throwable and explosive bullet | ProjectileService `explode` → `DamageDestructiblesInRadius(centre, radius × 0.5, wallDamage)` (`ProjectileService.lua:442-443`, `WALL_REACH` `:85`) | its `wallDamage`, once per pool per blast (`DestructibleService.lua:2607`) |
| an explosive barrel or mine | `HazardService.lua:401` | 78 × 1.2 = 93.6 within 15 studs (barrel) |
| rubble from a collapse | CollapseService `damagePart` (`DestructibleService.lua:2754-2756`) | its own amount |
| glass only (1 damage, a pane) | `CombatService.lua:420`, `ProjectileService.lua:220`, `:316`, `Bootstrap.server.lua:391` | nothing on a car (no car part is named `WindowGlass`) |

There is no caller in VehicleService, RoadkillPass, VehicleDynamics, MovementService or a bot's
hitscan path.

**Damage** (`DestructibleService.lua:1545-1590`): `dealt = min(health, amount)`. At 0 or below, the
entry is marked `broken` and `shatterPool` runs (`:1323-1355`). Otherwise the crack stage rises at
75/50/25% and the hit site is recorded (colour only, never see-through).

**The break** (`shatterPool`): the box round the car is handed to `tellBroken` (`:1138-1150`). That
tells the `OnPartBroken` listeners, so loot resting on it resettles (`LootService.lua:1007`). It also
runs the support pass for anything standing on the car, and clears loose cover. The 10 biggest
visible parts are sent to clients as debris (`FX_PER_POOL`, `:307`). Every member is destroyed, then
the Model. Nothing is made on the server.

## 3. The evidence (`tools/road_cars_proof_check.py`)

The harness builds each map with the world of `tools/car_placement_map.py`. The real modules are
MapGenerator, MapDecor, MapWilds, ParkingLots, VehicleModels and the rest. The ground is a height
function. Then, in the same Lua runtime, it loads the real DestructibleService, CombatService,
ProjectileService, CollapseService and RateLimit, with the real WeaponData (every pack), Ballistics,
CreativeRounds, ItemData, VehicleCover, VehicleArmor and MatchConfig. Stand-ins: one shooter
(Combatants), a loadout that always has a round (WeaponService), the present-time ray with no rewind
(LagCompensation), and QuestService. Rays are cast against the map's own turned boxes and the ground.

| check | what it holds | result on 5 maps |
|---|---|---|
| A routing | every part a ray can hit reaches the car's one pool (KeyOf and FromPart); the pool is 240; a level shot from the side lands on it | 1,728 of 1,728; 51 of 51 side shots |
| B bullets | real `CombatService.Fire` until the car is gone: every hit is the gun's own damage, the pool breaks exactly when spent, and no part or Model is left | 43 cars by rifle: 9 hits each; wrecks 10-11; shotgun 3 shots (19 of 24 pellets on target, from 18 studs above); sniper 3; noclip gun 4 |
| C fading | health 60 s of server time after the first hit | unchanged on every car |
| D after | no pool entry outlives its car (DestructibleService's `damaged` table, read through `debug.getupvalue`); a stale part deals 0; a shot through where the car stood hits nothing of it | 0 stale entries, 0 dealt, 0 hits |
| E blasts | real `ProjectileService.FireWeapon`/`Throw` and `Step` until each bursts: no blast takes more than its wallDamage, and the car goes | rocket 2, frag 2, sticky 2, barrel 3 on each map |
| F drivables | with `VehicleMaxHealth` set as `Create` sets it (`VehicleService.lua:1297`), no part is DestructibleService's, anchored or not, and a blast breaks none | 0 of 21,378 parts |
| G wreck | a drivable wrecked by the real VehicleService (`roadkill_proof_world.lua`) | stays, collides, stops bullets, takes 0 (finding 2) |

The check's last lines, verbatim:

```
F drivables: 21378 parts over 59 vehicles, none DestructibleService's (anchored or not) unless an F failure is listed
  FINDING same design, parked vs drivable: CrocodiloRanger parked 240 = 9 rifle hits; drivable 1600 at 19.87 a hit = 81 hits (9.0x)
  FINDING same design, parked vs drivable: Rotster parked 240 = 9 rifle hits; drivable 1500 at 19.87 a hit = 76 hits (8.4x)
  FINDING same design, parked vs drivable: SahurVan parked 240 = 9 rifle hits; drivable 1650 at 19.87 a hit = 84 hits (9.3x)
  FINDING same design, parked vs drivable: TralalaGT parked 240 = 9 rifle hits; drivable 1400 at 19.87 a hit = 71 hits (7.9x)
  FINDING AdminOverride (noclip one wall): 2.00 hits on the same car per bullet (measured on 5 cars)
G a drivable TralalaGT (1400 health) wrecked by the real VehicleService: dealt 1400, wrecked True; 10 s later still in the map True, Wrecked True, bullets still stop on it (VehicleFromPart) True, chassis collides True, a later hit deals 0
  FINDING a wrecked drivable stays for the rest of a battle royale match: solid, takes bullets, can't be hurt
road_cars_proof_check: OK (0 failures)
```

**Planted faults** (`--plant`), each applied to the game's source text in memory and aimed at a rule
the code must keep forever:

```
planted A (the pool looked up by part name again (#51's old cause): the chassis and hull stop reaching the car): caught
planted A (a real design parked without its DestructibleHealth (the #51 fix undone for the #16/#94 cars)): caught
planted B (a bullet that stops on a car never reaches its pool): caught
planted B (a car breaks before its pool is spent): caught
planted B (a broken car leaves pieces behind): caught
planted C (damage fades (2 health a second back)): caught
planted D (a broken car's pool entry is never dropped): caught
planted E (a blast hurts a car once per part it reaches): caught
planted F (a drivable's parts become map scenery): caught
road_cars_proof_check --plant: 9/9 caught
```

(Each line also prints the failure that caught it; those are trimmed here.) The "pieces behind" fault
is caught only on a wilds wreck. On a parked car, destroying the Model takes the leftover pieces with
it, so the fault can't show there.

## 4. Which tree, and the unmerged branches

Run on main `d1e4f73`. `pc/ttk-plus-25`, `pc/hitreg-fixes` and `pc/mounted-guns-powerful` are merged,
with no diff left. `CombatDamageScale` is 0.736 on main, and none of the parked-car numbers depend on
it. `pc/teambase-v2` (776713a, not merged) touches none of DestructibleService, MapDecor,
VehicleModels, CombatService or ProjectileService. It does change MapGenerator (hills planned before
the relief), MapTerrain, ParkingLots (gravel car parks on Limestone), MatchConfig (one more team-base
car) and BotService/BotNav (base vehicles take the roads). If it merges, the car counts per map will
shift and the damage path will not. The lupa terrain stand-in in `car_placement_map.py` may then need
a no-op `PlanHills` (reasoning, not tried).

## 5. For the coordinator: `tools/road_cars_break_gallery.lua` (needs Studio)

A number is not a picture. This gallery builds TralalaTown (seed 7) and shoots a kerb car, a driveway
car, a car-park car and a wilds wreck four times each: whole, at 90 of 240 (cracks), 0.3 s after
the break (the debris, if the runner draws client effects), and 3 s after (what is left). It also
shoots one drivable before and after it is wrecked, for finding 2. Its notes are a live probe with
Roblox's own rays: 24 rays at each car, how many meet it, and how many of those count for its pool.
lupa treats a wheel as a box. Expected: every ray that meets the car counts, and 0 parts are left
after the break.

```
powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/road_cars_break_gallery.lua -OutDir <folder> -TimeoutSeconds 600
```

## 6. What this does NOT prove

- **How it looks and feels.** The debris, the cracks, whether the invisible hull boxes match the
  body closely enough that a shot at the car always counts, and whether 9 rifle hits feels right for a
  car. All of that is Oliver's to judge, and the gallery is the first picture.
- **Roblox itself.** Wheels are boxes to lupa's rays. There is no lag compensation (no rewind), no
  network, and no live server. Whether Roblox's navmesh re-plans when a car goes is platform
  behaviour, not measured. (On foot, bots use PathfindingService, `BotNav.lua:347`. A path computed
  before the break keeps its detour until the next compute. Driving bots use live rays with a 0.5 s
  memory, `BotNav.lua:1979`.)
- **The vehicle and emplacement guns, the grenade-launcher round, mines and the battleground's
  wrecks** were not fired here. Their route is the same hook, read from source (the table in
  section 2).
- **The barrel** used HazardService's own numbers (read from its source), but the call was made
  directly. HazardService was not loaded.
- **Drivables' rocket count** (3-4) is VehicleArmor's comment, not a run.
- One seed per map. The counts differ by seed. The rules held on every car built.
