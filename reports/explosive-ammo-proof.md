# #122 explosive ammo: does every explosive gun reach the blast?

Jacob's branch `task/prove-explosive-ammo`, fast-forwarded to main **`fafed9c`** (fafed9cd9ab7) before the
final runs. Everything here was either measured outside Studio (Python + lupa, running the game's own Lua)
or read from source. Nothing was run in Roblox. No game file and no existing tool was edited.

OLIVER_LIST #122 says: "Weapons with explosive ammo must actually explode what you shoot." It is marked
"in tree, unproven (commit 6ef6a52)".

## Verdict

**Bugs and problems found, most important first:**

1. **When a bot fires the Golden Sahur Cannon, its shell never explodes.** (On main.)
   `BotService.lua:1843` `shootAt` resolves a bot's hitscan shot by dice roll. On a hit it calls
   `CombatService.DealDamage` (`BotService.lua:1980`) and nothing else. It never calls
   `CombatService.BulletBlast` or `CombatService.Explode`, so the blast from 6ef6a52 only happens when a
   player fires. I ran the real `shootAt`, cut from BotService, with a hit forced: **0 blasts, 1 damage
   call** (`FINDING` line of `tools/explosive_dispatch_check.py`). Launchers are fine: under the same test a
   bot's Cappuccina Launcher and Tralala Thumper each made **1 blast**, because a bot's launcher shot goes
   through `ProjectileService.FireWeapon`.
   Bots can get the cannon. `BotService.Loot.usable` (`BotService.lua:4880`) accepts it: it isn't staged,
   isn't in `BOT_WEAPON_HOLD`, and isn't a launcher. Bots also roll chests through
   `LootService.ClaimForBot` → `WeaponData.RollChestWeapon`, where the cannon's `chestWeight = 1` out of a
   pool total of 280.05, so **0.36% of chest rolls**. They can also pick up a cannon a player dropped.
   The earlier check's own docstring says so ("bots ... a bot's cannon has no blast"). The OLIVER_LIST row
   doesn't. Bots skip every hitscan ability for the same reason: chain, lifesteal, and Ultimo Bum's streak
   blast never run on bot fire. Whether bots *should* get the blast is Oliver's call (see "For Oliver").
2. **The existing check for #122, `tools/explosive_ammo_check.py`, crashes on main and has since d370e62.**
   It stops with `LuaError: [string "DestructibleService"]:3: bad argument #1 to 'for iterator' (table
   expected, got nil)`. Its section C cuts out `DestructibleService.DamageInRadius`, which since d370e62
   ("WIP Destruction", 09-24 18:07) reads the upvalue `ROOTS` (`DestructibleService.lua:352`, used at
   `:2499`). The harness's environment (`explosive_ammo_check.py:248`) has no `ROOTS`. I bisected by
   running the check on every commit that touched its inputs: **it passes on 7fab339 (22 checks, 0
   failed) and crashes on d370e62 and on every commit since, including main `fafed9c`**. Its `--plant`
   run crashes the same way. `python tools/quality_gate.py -k explosive` shows it red on main:
   `explosive_ammo_check.py FAIL exit 1`, and the same for `--plant`. So on main, the "21 checks, 9 of 9
   planted faults" on the OLIVER_LIST row currently prove nothing. The fix belongs to whoever owns that
   tool, and I have not touched it. It also only ever examined the **30** guns written in
   `WeaponData.lua`, not the **65** in the merged table (packs included), so a pack gun with
   `explosiveAmmo` would have gone unchecked even when it ran.

**What works (on main `fafed9c`, measured through the real code):**

- **77 guns examined, 10 flagged.** That is 65 hand guns and 12 vehicle/emplacement guns. The flagged
  ones are 6 hand guns and 4 vehicle guns. Every flagged gun reaches the blast when a **player** fires it,
  and every blast lands where the shot stopped.
- The cannon's blast goes off at the **hit point**. That is z −29.4 on an enemy whose root is at z −30,
  z −29.5 on a wall face, and z −24.0 on a vehicle hull, never at the muzzle (z 0) or the target's root.
  It uses the ammo's radius (5). A shot into open sky, through a lone pane, or through a lone team-mate
  makes **0** blasts.
- Self-damage and team damage go through the same `explode()` the launchers use. The shooter takes half
  (measured 5 of the blast's 12). A team-mate 2.5 studs from the struck enemy takes **0**, while an enemy
  in the same spot takes 8.
- Rounds (hand launchers, vehicle and emplacement rounds) burst on the struck face, within 0.1 stud in
  every contact case measured, with their own `splashRadius`.

## 1. What I examined, and what is flagged

`tools/explosive_dispatch_check.py` loads the **real** `WeaponData` (every pack merged:
ArsenalExpansion, CreativeArsenal, WorkshopArsenal) and `VehicleWeaponData`, with MountedGunData merged
in by VehicleWeaponData's own code. Its first line on main, verbatim:

```
ok    inventory: 65 hand guns examined, 6 route to a blast (CappuccinaLauncher:round, FinalNotice:streak, GoldenSahurCannon:bullet, TamburoTungTung:round, ToasterMortar:round, TralalaThumper:round); 12 vehicle/emplacement guns examined, 4 fire explosive rounds (CameloGrenadeLauncher, EmplacementCannon, RangerRocketPod, VanMortar)
```

A gun is flagged as **promising a blast** if its data says so (`ability = "explosive"`, `explosiveAmmo`,
`splashRadius`, a `collect` streak blast) or its name or description does ("explode/explosive", "blast"
as a word, "detonate", "goes off", "blows up"). Names with cannon, mortar, rocket, grenade, launcher or
bomb also count. Every such gun needs a **route**:

- a hitscan gun: the real `CombatService.BulletBlast(def)` returns ammo;
- a launcher: its `Ballistics.Rounds` kind is not `explosive = false`;
- a streak gun: it has `collect`.

A name that promises but has no route has to be listed with a reason in the check's `REVIEWED` table.
Right now that is Party Foul ("corks, confetti and a shove"), Fidget Disc Launcher (a spinner that
glances off walls) and Grandma's Slipper Launcher (a homing slipper). A stale entry fails too. The GunModels
flairs and signature designs (7e61c81, b92cf49) promise no explosions: a grep of `GunModels*.lua`,
`ArsenalFinish.lua` and `GunFx.lua` for explos/blast/detonat finds only cosmetic hits.

| Gun | Kind | How it fires (player) | Reaches the blast? | Bot |
|---|---|---|---|---|
| Golden Sahur Cannon | hitscan, `explosiveAmmo {12, 5, 60}` (WeaponData.lua:592) | `CombatService.Fire` → `firePellet` (:826) → `bulletBlast` (:997) → `CombatService.Explode` = ProjectileService `explode` (:1128) | **yes**, 1 per bullet | **no (bug 1)** |
| Cappuccina Launcher | rocket, splash 14 | `Fire` → `LaunchProjectile` (CombatService :1132) → `launchRound` → `contactRound`/`stepRound` → `burst` → `explode` (ProjectileService :532) | **yes** | yes (FireWeapon) |
| Tralala Thumper | grenade, splash 11 | same | **yes** | yes |
| Toaster Mortar | lobbedToast (impact body), splash 10, staged | same, `stepBody` | **yes** | never held (not in `BOT_PROJECTILE_KINDS`; staged) |
| Tamburo Tung Tung | 3 × drumlet, splash 7 | same, 3 rounds a shot | **yes**, 3 per shot | never held (`BOT_WEAPON_HOLD`) |
| Ultimo Bum (FinalNotice) | hitscan, `collect {every 5, 20, radius 6}` | `firePellet` → `fireAbility` → `StreakPayout` → `CombatService.Explode` (:719) | **yes**, on the 5th hit in a row, at the target's root | no (bots run no abilities) |
| Camelo Grenade Launcher | vehicle round, grenade, splash 8 | `VehicleWeapons.Fire` (:366) → `launchRound` (:348) → `CombatService.LaunchProjectile` | **yes** | same function for bots (BotService :3900) |
| Boomba Grenade Cannon (EmplacementCannon) | emplacement round, grenade, splash 9 | same | **yes** | same |
| Sahur Van Mortar | vehicle round, grenade, splash 13 | same | **yes** | same |
| Ranger Rocket Pod | vehicle round, rocket, splash 12 | same | **yes** | same |

The other 8 vehicle guns are hitscan machine guns with no blast and no blast promised. Each one fired
through the real `VehicleWeapons.Fire` and made 0 blasts.

## 2. Where it goes off

Every hand gun was fired through the **real** `CombatService.Fire` into each scene. The real
ProjectileService was then stepped until every round had gone off (8 s). The shooter stands at z 0 and
shoots straight along −Z at head height. The table is the check's own output on main: the number of
blasts, then the z of each.

```
  CappuccinaLauncher   enemy 1 @-29.4 | wall 1 @-29.5 | terrain 1 @-29.5 | vehicle 1 @-24.0 | glass 1 @-210.3 | glass+wall 1 @-29.5 | mate+enemy 1 @-14.4 | mate 1 @-14.4 | sky 1 @-210.3
  GoldenSahurCannon    enemy 1 @-29.4 | wall 1 @-29.5 | terrain 1 @-29.5 | vehicle 1 @-24.0 | glass 0 | glass+wall 1 @-29.5 | mate+enemy 1 @-29.4 | mate 0 | sky 0
  TamburoTungTung      enemy 3 @-29.5,-29.5,-29.5 | wall 3 @-18.5,-24.1,-24.1 | terrain 3 @-18.5,-24.1,-24.1 | vehicle 3 @-14.3,-15.7,-16.8 | glass 3 @-27.3,-29.1,-29.2 | glass+wall 3 @-18.5,-24.1,-24.1 | mate+enemy 3 @-14.2,-14.2,-14.2 | mate 3 @-14.2,-14.2,-14.2 | sky 3 @-27.3,-29.1,-29.2
  ToasterMortar        enemy 1 @-29.5 | wall 1 @-29.5 | terrain 1 @-29.5 | vehicle 1 @-24.0 | glass 1 @-34.2 | glass+wall 1 @-29.5 | mate+enemy 1 @-14.2 | mate 1 @-14.2 | sky 1 @-34.2
  TralalaThumper       enemy 1 @-29.5 | wall 1 @-29.5 | terrain 1 @-29.5 | vehicle 1 @-24.0 | glass 1 @-66.4 | glass+wall 1 @-29.5 | mate+enemy 1 @-4.3 | mate 1 @-4.3 | sky 1 @-66.4
```

The same results, by case, for the cannon (hitscan) and the launchers (rounds):

| What the shot meets | Cannon (hitscan explosive ammo) | Launcher rounds |
|---|---|---|
| A player or bot (enemy) | 1 blast at the hit point on the body (z −29.4) | bursts on the body |
| A wall (destructible) | 1 blast at the face (z −29.5); the wall also takes its `wallDamage` 60 within half the radius (explode → `DamageDestructiblesInRadius`, source read) | bursts on the face |
| Bare map / terrain (not destructible) | 1 blast at the face (the `onMap` branch, CombatService :950) | bursts |
| A vehicle's hull | 1 blast at the hull face (z −24.0); the hull takes the bullet as `"bullet"` and then the blast through `VehicleService.BlastDamage` (measured: `bullet+blast`) | bursts on the hull |
| A rider behind the hull | source read: `riderBehind` splits the bullet, `stopped` is still the hull, so the blast is at the hull and reaches the rider at their seat's `VehicleCover.BlastShareFor` (c8736d2) | same share |
| Glass, open air behind it | **0** (the pane passes the bullet, `stopped = nil`) | flies on; the rocket bursts in the air at `maxTime` 2.2 s (z −210), the grenade lands (z −66) |
| Glass, wall behind it | 1, at the wall | 1, at the wall |
| Team-mate, enemy behind | 1, **at the enemy** (efccfa5: the bullet passes a team-mate) | bursts **on the team-mate** (see "For Oliver") |
| Team-mate alone | **0** | bursts on the team-mate |
| Sky / out of range | **0** (by design in 6ef6a52: "not in the open") | rocket bursts in the air, grenade/toast land and burst |
| Water | not measurable here (no terrain water in the mock). Source: both bullet and round rays set `IgnoreWater = true` (CombatService :586, ProjectileService :163), so a shot into water passes through and goes off on the bed. A blast's line of sight also ignores water. | same |
| Companion, player barricade, barrel | source read: each branch `break`s with `stopped = result`, so 1 blast at the hit point | burst |

**Blast position (e7a3acf).** e7a3acf only changed `DamageDestructible` to take the hit point and normal
(crack placement). The bullet's blast has used `stopped.Position` and `stopped.Normal` since 6ef6a52
(`CombatService.lua:997`). Measured in all 6 contact cases, it is the struck face to within 0.05 stud.
Two planted faults move it, one to the muzzle and one to the target's root, and the check catches both.
Ultimo Bum's streak blast is set on the **target's root** on purpose ("a small blast on the target",
CombatService :719): measured at z −30.00.

**Self and team damage (measured through the real `explode` and the real `DealDamage`):**

- The shooter 1.7 studs from the face of the wall they shoot takes 5 of the blast's 12. That is the owner's half
  (`SELF_SCALE = 0.5`, ProjectileService :63), at the scale for that distance, and not multiplied by
  CombatDamageScale, the same as a launcher's owner. Self-damage is never vetoed
  (`ModeTeams.DamageVeto`: "Your own grenade still hurts you").
- A team-mate 2.5 studs from the struck enemy takes 0; an enemy the same distance away on the other side
  takes 8. The veto in `DealDamage` (CombatService :432) handles it; the mode's veto is stood in for as
  "same team".
- An enemy struck in the chest takes **96** in all (the bullet 92 × 0.92 = 84.6, plus the blast), so it
  is still not a one-shot, as the cannon's comment wants. A head shot kills anyway (measured: 100).

**Many blasts per shot.** Tamburo Tung Tung makes 3 blasts per shot (3 drumlets). That is what its
description says, and it is what is measured. For a hitscan gun, `Fire` calls `firePellet` once per
pellet and each pellet sets off its own blast, **with no cap**. No shotgun carries `explosiveAmmo` today,
so this does nothing yet. It would matter the moment one did: a 10-pellet shotgun would make 10 blasts.
A ricochet round (`def.ricochet`, b92cf49) inherits `explosiveAmmo` through `__index`
(CombatService :1007), so a ricochet gun with explosive ammo would get a second blast per bounce. None
exists.

## 3. The later commits

| Commit | What it touched | Effect on #122 |
|---|---|---|
| 7e61c81 gun rework 1 | models, sounds, viewmodel | none: no data or server change |
| b92cf49 gun rework 2 | streaks (`collect` blast), `noclip`, `ricochet`, new descriptions | adds Ultimo Bum's streak blast (flagged, works). A `noclip` pass sets `stopped = nil`, so a noclip bullet that ends in open air doesn't blast. A ricochet inherits the ammo. No gun has both today |
| 267cadb gun rework 3 | Zanzarino Pikpik, Tamburo Tung Tung, Bananerang | Tamburo: 3 blasts a shot, works. Pikpik's dart and the Bananerang are `explosive = false` and promise no blast |
| efccfa5 pellets through a team-mate | `DamageVeto` → `stopped = nil; continue` | measured: the cannon's blast lands on the enemy behind the team-mate (z −29.4), not on the team-mate |
| 7fab339 vehicle guns | VehicleWeapons, VehicleWeaponData | 4 round guns → `LaunchProjectile` → the same blast, measured; hitscan vehicle guns don't read `explosiveAmmo` (the check fails if one gets it) |
| c8736d2 vehicle cover | `VehicleCover.BlastShareFor` in `explode` | the bullet's blast inherits it (same `explode`) |
| e7a3acf hit point and normal | `DamageDestructible` args | cosmetic for cracks; the blast was already at the hit point |

## 4. The new check and its planted faults

`tools/explosive_dispatch_check.py` (with `tools/explosive_dispatch_world.lua`) loads **CombatService,
ProjectileService and VehicleWeapons whole**. They run with the real WeaponData (every pack), Ballistics
(with CreativeRounds), VehicleWeaponData (with MountedGunData), VehicleCover, SafeValue and MatchConfig.
Small recorders stand in for Combatants, LagCompensation (rewind off), WeaponService, Remotes and
VehicleService. The world is `tools/hitreg_mocks.lua` boxes. A blast is counted from the "detonate"
broadcast that ProjectileService's `explode()` sends before it deals any damage. The bot section cuts
`shootAt`, `accuracyAt`, `BOT_WEAPON_HOLD`, `BOT_PROJECTILE_KINDS` and `Loot.usable` out of the real
BotService.lua.

On main: `explosive_dispatch_check: 74 checks, 0 failed, 1 finding(s)`. The one finding is bug 1. It is
printed as `FINDING` and does not fail the check, because whether bots should get the blast is still
Oliver's to decide. When a fix lands, the line turns into an `ok` row.

`--plant`: **13 of 13 caught.** Each plant is aimed at a rule the code must keep forever, not at a bug:

```
CAUGHT  a new hitscan gun described as explosive, with no explosiveAmmo  <- PlantShellPistol promises a blast (data or description) and nothing routes it to one
CAUGHT  a new gun named Mortar with a round that does not explode  <- PlantMortar has an explosive name and no blast, and is not in REVIEWED
CAUGHT  explosiveAmmo put on a launcher (ignored by the round path)  <- TralalaThumper carries explosiveAmmo on a launcher: Fire hands it to ProjectileService, which never reads it
CAUGHT  firePellet never calls the bullet's blast  <- GoldenSahurCannon -> enemy: 0 blast(s), want 1 (one a pellet)
CAUGHT  the bullet's blast at the muzzle, not the hit point  <- GoldenSahurCannon -> enemy: blast at z 0.00 (the hit point is z -29.4; muzzle z 0, target root z -30), radius 5 (ammo 5)
CAUGHT  the bullet's blast at the target's root, not the hit point  <- GoldenSahurCannon -> enemy: blast at z -30.00 (the hit point is z -29.4; muzzle z 0, target root z -30), radius 5 (ammo 5)
CAUGHT  a round's burst no longer explodes  <- CappuccinaLauncher -> enemy: 0 blast(s), want 1 (one a round)
CAUGHT  a team-mate soaks the bullet (and the blast goes off on them)  <- GoldenSahurCannon -> mate+enemy: blast at z -14.40 (the hit point is z -29.4; muzzle z 0, target root z -30), radius 5 (ammo 5)
CAUGHT  the blast ignores the friendly-fire veto  <- GoldenSahurCannon splash: the enemy 2.5 studs from the struck one takes 8, a team-mate 2.5 studs the other side takes 8
CAUGHT  the owner takes their whole blast  <- GoldenSahurCannon: the shooter 1.7 studs from the wall they shoot takes 10 of the blast's 12 (half at most, as a launcher's owner)
CAUGHT  a streak gun's collect payout no longer explodes  <- FinalNotice: 4 hits in a row -> 0 blast(s); 5 hits -> 0 blast(s), at z - (the target's root, z -30), radius - (collect radius 6)
CAUGHT  a vehicle's round fired as a bullet  <- vehicle CameloGrenadeLauncher: VehicleWeapons.Fire errored: [string "<python>"]:46: attempt to index a nil value (local 'b')
CAUGHT  a bullet that flew into the open sky explodes at its range  <- GoldenSahurCannon -> glass: 1 blast(s) (a hitscan bullet that stops on nothing blows up nothing)
explosive_dispatch_check plants: 13 of 13 caught
```

(The vehicle plant is caught by the fire path erroring, not by a count. A round spec has no `range`, so
tracing it as a bullet throws. The check turns any error into a FAIL row.)

**My own fault in a temp copy of the game.** I copied `ServerScriptService/` and `ReplicatedStorage/` from
this branch into `/tmp` and edited real files there, then ran the check against that copy:

- Commented out `CombatService.Explode = explode` (ProjectileService.lua:1128), so ProjectileService
  never gives its blast to CombatService: **exit 1, 16 of 74 rows FAIL**. The cannon made 0 blasts in
  every case, Ultimo Bum's payout made 0, and the splash rows failed. The unmodified copy passed
  (74 checks, 0 failed).
- Added a gun to **CreativeArsenal.lua** (a pack, not WeaponData.lua) described as "Every shot explodes
  on impact." with no `explosiveAmmo`: **exit 1**, `FAIL  PlantConfettiBlaster promises a blast (data or
  description) and nothing routes it to one`.

## 5. The existing check

`tools/explosive_ammo_check.py` (6ef6a52, later edited in 267cadb, efccfa5 and eea39f8) runs real source
cut out function by function. It could fail: on 7fab339, its last passing commit, its `--plant` caught
10 of 10. On main it **cannot run** (bug 2). Two more limits, even when it ran:

- Section A reads only `WeaponData.lua` with a regex (30 guns). The 35 pack guns are invisible to it.
- Section B calls `firePellet` directly, not `Fire`. So it would not catch a launcher that carries the
  ammo, or a gun that never reaches `firePellet`. It also never covers bots, vehicles or rounds. Its
  docstring says so for bots.

## What this does NOT prove

- **Nothing here ran in Roblox.** The world is boxes. Characters are the hitreg_mocks body, and
  Spherecast is treated as a ray. Terrain water, real part faces, real `GetPartBoundsInRadius`, network
  ownership and lag-compensated rewind (off here) are not modelled.
- **How the blast looks and sounds on clients** (ProjectileClient `onDetonate`, kind "impact",
  ExplosiveFx). A bullet's blast broadcasts with no `id`. The client code handles that (`flying[nil]` is
  nil), but whether it reads well on screen needs a render. That is the coordinator's to run.
- **Wall, companion, barricade and barrel hits beyond the counts.** The check counts the blast and its
  position. The wall-damage-once-per-pool rule and falloff are what the broken old check covered; I read
  them in source and did not re-measure them.
- **Balance.** "96, still short of a one-shot" repeats the cannon comment's own target. It is not a
  judgement on whether 12 damage over 5 studs feels like explosive ammo.
- The bot result uses a forced hit. How often a bot actually holds the cannon in a match is not measured
  beyond the 0.36% chest-roll share.

## For Oliver (product calls, not decided here)

1. **Should a bot's cannon shell explode?** Right now only players' shots blow up. If yes, the build
   machine would add the blast to `shootAt`'s hit branch. A bot's miss has no traced end point, so where
   a missed shell goes off would need a decision too.
2. **Should a shot into the open explode?** Right now the cannon's shell doesn't (6ef6a52 chose that),
   but a rocket bursts in the air at the end of its flight. Your row says "explode what you shoot", which
   fits the current choice.
3. **Launchers and team-mates.** Since efccfa5, a bullet flies through a team-mate to the enemy behind.
   A launcher round still stops and bursts on the team-mate. The team-mate takes nothing, but the enemy
   behind is shielded, and the shooter can be caught in the blast. Measured with a team-mate 15 studs
   ahead: the Cappuccina's rocket burst on them and the shooter took 9. The Tralala's grenade hit them
   before arming, bounced back as a dud and went off 4.3 studs from the shooter, who took 25. Is that
   what you want? (The two damage numbers come from a one-off run of the check's `SCENE` with case
   `mate` in the same harness. They print as `took` and are not rows of the check. The blast positions
   are in the section 2 table.)
4. **Many-pellet explosive guns.** If `explosiveAmmo` ever goes on a shotgun, each pellet makes its own
   blast, with no cap. Decide before the data is written.

## Files

New in this branch (no existing file changed):

- `reports/explosive-ammo-proof.md` (this file)
- `tools/explosive_dispatch_check.py`: the check (`python tools/explosive_dispatch_check.py .`, `--plant`)
- `tools/explosive_dispatch_world.lua`: the stand-in Roblox world it loads the real modules into
- `README-task-prove-explosive-ammo.md`

## The three checks (main `fafed9c` plus this branch), last lines verbatim

```
OK: no problems
files unbalanced: 0
lua static check: 438 files, 0 findings
```

(`tools/clock_ratchet.py .` flags `StarterPlayerScripts/MountedGunClient.client.lua` on main. That
predates this branch and is outside this brief.)
