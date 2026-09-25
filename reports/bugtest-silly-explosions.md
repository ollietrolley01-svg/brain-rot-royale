# Bug test: silly explosions (2e1abc4, 57fd4f0, f9f0af6, 9fb4e83)

Tree: main `d1e4f73`. Branch `task/bugtest-silly-explosions`, cut from it; it adds files only.
Damage numbers use `CombatDamageScale` 0.736, main's value since ttk-plus-25 (`MatchConfig.lua:110`,
applied in `CombatService.lua:454`).
"Before" means `25839e2`, main just before the silly explosions merged (the second parent of `8ee9c9f`).
There HazardService and MountedGuns still made their bare, tagged `Explosion`s. Against main, those two
files differ only by the silly change.

## Verdict

The server side is clean. Replacing the bare `Explosion`s changed no damage, radius, kill credit,
kill-feed weapon, splash or quest call. That was measured by running the real HazardService and
`breakGun` before and after. The old Explosions had no physics at all (radius, pressure and joint-break
all 0), so nothing was lost. The cue contract is clean too.

I found two new client bugs, both visual:
1. Hits that don't explode count toward the new crowd budget. A dart pistol's hits make the next real
   explosion lose its rock chunks and smoke column.
2. The new vehicle-wreck blast can go off minutes late, at a wreck you drive back up to.

I also found one check problem. `silly_explosion_check`'s gameplay gate (E) compares main with itself
now that the work is merged, and on any other branch it raises false alarms.

## Findings, most important first

### F1: hits with no explosion push real explosions into the "crowded" look. Measured. New in 57fd4f0.

- The crowd budget counts every `ExplosiveFx.Explosion` call:
  `local crowded = liveBlasts >= LIVE_BLASTS` then `liveBlasts += 1` (`ExplosiveFx.lua:623`, `:627`).
- A hit with no explosion goes through the same function: `ExplosiveFx.Impact` calls
  `ExplosiveFx.Explosion(position, normal, "impact", 4, weaponId)` (`ExplosiveFx.lua:845`).
  ProjectileClient calls `Impact` for every hit from a round with `explosive = false`
  (`ProjectileClient.client.lua:599`). Those rounds are the Zanzarino Pikpik's darts, the Bananerang,
  the Fidget Disc Launcher and Grandma's Slipper Launcher.
- Each call stays counted for 1.3 s (`ExplosiveFx.lua:760`). Once 3 are counted, the next explosion
  gets no rock chunks and no smoke column, and half its particles (`:714`, `:749`).
- Measured, real ExplosiveFx: a barrel explosion on its own has 6 chunks, 1 smoke column and 74
  particles. After 3 Zanzarino, Fidget or Slipper hits 0.24 s apart, the same barrel has 0 chunks, 0
  columns and 38 particles. The results are identical for all three guns (check C4b).
- In a match: the Zanzarino Pikpik is a Rare pistol at 4.2 shots a second (`WeaponData.lua:243`), found
  in chests (`chestWeight = 5`). One player firing it keeps about 5.5 hits counted (4.2 × 1.3) on every
  client within 650 studs of where the darts land (`ProjectileClient.client.lua:49`). While they fire,
  and for 1.3 s after, every real explosion those clients see is drawn light: rockets, grenades,
  barrels, mines and silly launchers. That last part is reasoning from the numbers, not a live
  measurement.
- The code says hits should not count, but only for the other counter. `SillyExplosionFx.lua:759-761`
  keeps hits out of `Silly.Active`, with the comment "a stream of slipper or disc hits must not push the
  next real explosion down". Nothing does the same for `liveBlasts`. The existing plant "hit rounds
  counted in the crowd cap" guards `Silly.Active` only.
- Possible fix (not made): count only real explosions, e.g. `if kind ~= "impact" then liveBlasts += 1`,
  with the matching decrement. Whether hits should count toward a lag budget is Oliver's call. The
  comment at `ExplosiveFx.lua:621` names "a barrel chain, a rocket volley".
- Look only. No damage is involved.

### F2: a vehicle wreck's blast goes off late when you come back to it. Measured on the real module; the gating is read from the code. The visual is new in the merge 8ee9c9f / f9f0af6.

**Already known:** Oliver's handoff (`coordination/messages/2026-09-25-0830-coordinator-handoff-remaining-to-jacob.md`,
item 1, "Wreck blast") lists this cause: the blast fires from SetSmoke, which runs only within 320 studs. This section
measures it. It isn't a new find.

- `VehicleWreckFx.SetSmoke` fires `OnWreck` when it sees a vehicle whole on one call and wrecked on the
  next (`VehicleWreckFx.lua:78-81`). It has no idea how much time passed between the two calls.
- VehicleClient only calls it for vehicles within `ANIMATE_DISTANCE` = 320 studs
  (`VehicleClient.client.lua:44`, `:748`, `:762`, `:655`).
- Wrecks are never removed or repaired (`VehicleService.lua:891`: "never un-wrecks"). The place streams
  with a target radius of 1024 (`build_place.py:80-82`) and never sets a stream-out behaviour, so a wreck
  320 to 1024 studs away stays on the client. That is reasoning, not a measurement.
- Measured (C9b): a car seen whole at 0 s is wrecked out of range at 10 s. When it comes back into range
  at 130 s, `OnWreck` fires then, 120 s after the wreck. `ProjectileClient.client.lua:588-589` then
  draws the full grenade-standard blast (flash, fireballs, chunks, scorch) and plays `ExplosionVehicle`
  at a car that has been burning for two minutes.
- The late sound has existed since a99c94f (sound polish). The late fireball is new with this work.
- A wreck seen as it happens is correct: one blast, on that frame, never a second (C9a).
- Possible fix (not made): have the server stamp the wreck time (e.g. a `WreckedAt` attribute) and skip
  the blast when it is more than a second or two old. Or only fire when the previous `SetSmoke` call for
  that model was a frame or two ago.

### F3: silly_explosion_check's gameplay gate (E) proves nothing on main and false-alarms on branches. Measured.

- E compares the gameplay files with the merge base of `HEAD` and `origin/main`
  (`tools/silly_explosion_check.py:321`). On main that merge base is `HEAD` itself (`d1e4f73`), so E
  compares each file with itself and can't fail once a change is committed.
- On any branch, E flags every gameplay change since the branch point, related or not. I ran the check's
  own `check()` on `origin/pc/lag-bug-sweep`'s files against its merge base (`d1e4f73`). It reports 7
  E problems, all from that branch's unrelated fixes: WeaponData, CombatService, DestructibleService,
  ProjectileService, the mine team rule in the HazardService damage block, and MountedGuns.
- With `--base 57fd4f0^` it reports 5 E problems from work merged since then. The hazard and mounted-gun
  look-only part still passes against that base.
- The guarantee E was written for ("gameplay unchanged by the silly work") is now held on main by S1/S2
  of the new check, which run the real code before and after.

### F4: dead code and stale text left by the change. Measured by grep. New in 57fd4f0.

- `HazardService.lua:84` `SCORCH_TIME = 25` is never read. `entry.base` (`:104`, `:182`, `:243`) is
  written and never read. The server scorch mark was their only reader.
- `HazardService.lua:331-333` still describes the explosion as "an Explosion with no physics of its
  own ... a scorch mark with smoke".
- `tools/silly_explosion_check.py:50` says the barrel sends "the rocket blast look". It sends `"grenade"`
  (`HazardService.lua:357`).

### Known, not new: the smoke column is destroyed at 1.3 s. Measured.

- `ExplosiveFx.lua:735` puts the column part into the explosion's own part list, so the 1.3 s entry
  destroys it. Its own `columnTime + 5` entry never gets to fade it out. Measured: destroyed at 1.30 s
  for grenade, rocket, coffee and gold.
- This predates the silly work (it is unchanged context in 57fd4f0's diff). The unmerged
  `pc/lag-bug-sweep` already fixes it. Listed so nobody reports it twice.

## What was examined and came out clean

- **Server, before against after (S1, measured).** The scene: P1 shoots a barrel with five people at 0,
  5, 10, 14.9 and 15.1 studs; a second barrel 12 studs away goes up in the chain; P3 shoots P2's mine
  while P2 stands on it; B1 steps on P2's mine. That makes 27 calls (InRadius, DealDamage, splash on
  companions, structures and walls, quests), identical and in the same order before and after.
  Examples at 0.736: the barrel does 78 → 57.41 at 0 studs and 27.64 → 20.34 at the 14.9-stud edge,
  and nothing at 15.1. The chain barrel is still credited to P1. The shot mine is P3's kill and spares
  its owner P2. The stepped-on mine is P2's kill, 77.53 → 57.07. The kill-feed weapon is still
  `ExplosiveBarrel` or `RotMine`.
- **What the old Explosions did.** The 4 Explosions before the change all had `BlastRadius` 0,
  `BlastPressure` 0 and `DestroyJointRadiusPercent` 0, and nothing connected `.Hit`. So they dealt no
  damage, no knockback and no joint breaks. Main makes none. Each detonate cue carries the radius the
  damage used: 15, 15, 10, 10.
- **MountedGuns (S2, measured).** `breakGun` makes the same calls before and after (release, then
  `ConfirmHit(P1, 0, true, pivot + 3.5 up, "vehicle")`, Wrecked, prompt off, smoke). Calling it a
  second time does nothing. The cue is sent from exactly where the old Explosion was.
- **Cue contract (K1 to K4).** There are 3 detonate senders (`HazardService.lua:354`,
  `MountedGuns.lua:425`, `ProjectileService.lua:377`), and each sends position, normal, kind, radius and
  weaponId. ProjectileClient routes `"detonate"` to `onDetonate`, which reads all five. The kind
  `grenade` is in `BLAST_LOOK`. `ExplosiveBarrel`, `RotMine` and `MountedGunWreck` are in `WEAPON_CUE`,
  and their cues (`ExplosionBarrel`, `ExplosionMine`) exist in SoundConfig. None of the 204 game files
  makes an `Explosion`, touches `BlastCue` or listens for `IsA("Explosion")`. ProjectileService sends
  the same `radius` its damage loop uses. All 6 theme sound keys exist.
- **Counters and cleanup (C1 to C3, measured).** I ran 14 kinds of explosion: the realistic grenade,
  rocket and frag, the barrel, the mine, the mounted-gun and vehicle wrecks, 4 silly explosions, 2 silly
  hits and a dart hit. After each, 0 of its instances were left after 40 s, and `liveBlasts` and
  `Silly.Active` were back to 0. Then 42 explosions over 4.2 s (peak `liveBlasts` 12): 40 s later both
  counters were 0 and the next barrel explosion was drawn in full. Then `ExplosiveFx.Clear()` 0.3 s
  into 14 explosions (the `"clear"` action): 0 instances left and both counters at 0.
- **Dying (reasoned).** A character dying doesn't interrupt any of this. The effects live in
  `workspace.BRR_ExplosiveFx`, and ExplosiveFx runs from a StarterPlayerScripts module that isn't reset
  on respawn.
- **Crowd budget for real explosions (C4a, measured).** With 3 explosions live, the 4th has 0 chunks,
  0 columns and 38 particles, against 6, 1 and 74 on its own.
- **Silly cap (C5, measured).** 10 slipper and fidget hits leave `Silly.Active` at 0, and the next
  coffee explosion is drawn at full detail. With 6 coffee explosions live, the next is drawn FAR.
- **Themes (C6, C7, measured).** All 6 silly weapons name a complete theme. 10 other ids (the hazards,
  both wrecks, the Tralala Thumper, the Zanzarino, junk, nil) get none. Themed pieces actually made:
  coffee 20, fidget 21, gold 15, party 24, slipper 6 and toast 8, all within the budget of 26. Coffee
  also makes 18 SpecialMeshes for its droplets and sheets, which the budget doesn't count; they are
  cheap. Instances per explosion: a realistic grenade makes 29; the silly ones make 24 to 54.
- **Danger ring (C8, measured).** At 0.3 s each non-hit theme's ring is exactly the radius the server
  sent. Hits draw none. It sits on the root-distance radius; the server hurts roots up to 1.2 studs
  further (`Ballistics.BodyAllowance`), which works out to the body's edge touching the ring. That is
  reasoning, not a measurement.
- **Where the mounted-gun wreck's scorch lands (measured once by hand, not in the check).** The
  downward ray skips the gun's base, because the cannon's `BaseSkid` is 2.7 studs wide, just under the
  2.72-stud minimum for a scorch surface, and lands on the ground. Widen that skid by 0.03 studs and the
  scorch would sit on the skid instead.

## Existing checks on this tree, verbatim

```
silly explosion check: 6 silly, 6 realistic + mounted/vehicle, 0 problems
silly explosion plants: 10/10 caught
explosive_dispatch_check: 93 checks, 0 failed, 0 finding(s)
explosive_dispatch_check plants: 18 of 18 caught
explosive_ammo_check: 23 checks, 0 failed
explosive_ammo_check plants: 12 of 12 caught
mounted_guns_check: 0 problem(s)
contracts_check: 0 problem(s), 0 note(s)
sound polish: 11/11 checks pass
sound polish planted faults: 14/14 caught
scorch_check: OK
```

What they cover here:
- `silly_explosion_check` reads the source with regexes and never runs the modules. Its budget and
  crowd checks confirm a guard line exists, not that the counters come back down. It doesn't look at
  hits against `liveBlasts` (F1). Its E gate is empty on main (F3).
- `scorch_check` runs the real ExplosiveFx, but with SillyExplosionFx stubbed to "no theme".
- `explosive_dispatch_check` and `explosive_ammo_check` cover the server damage of the silly launchers
  and of explosive bullets, which this work didn't touch.
- `sound_polish_check` confirms the cue keys exist.
- None of them covers the vehicle wreck timing (F2).

## The new check

`tools/silly_explosions_bugtest_check.py` (+ `tools/silly_explosions_bugtest_world.lua`) runs the real
HazardService (before and after), `breakGun` (before and after), ExplosiveFx, SillyExplosionFx and
VehicleWreckFx under lupa on `tools/destruct_mocks.lua`. It has 17 checks. F1 and F2 are listed as
known findings: they print FINDING and don't fail the run, and if either stops reproducing the run
fails so the list gets updated. It has 20 planted faults, each aimed at an invariant that holds today;
20/20 are caught.

On `origin/pc/lag-bug-sweep`'s versions of HazardService, MountedGuns, ExplosiveFx, ProjectileClient and
ProjectileService, the other 15 checks pass and F1 and F2 still reproduce. That branch fixes neither.

## Unmerged pc/* branches

Only `pc/lag-bug-sweep` (30 commits ahead) touches these files. It changes HazardService (a mine team
rule), MountedGuns, ProjectileService, ExplosiveFx (the column fix above), ProjectileClient (grenade
cooking) and VehicleClient (jolt report). None of that touches the cue, the counters or the wreck timing.
`pc/teambase-v2` (19 ahead) touches none of them. All the other `pc/*` branches are merged.

## Renders

- **F1:** `tools/silly_explosions_bugtest_gallery.lua` (new; needs the coordinator's Studio) shows
  the same barrel explosion alone and after 3 darts, at 0.35 s and 0.9 s. It shows whether a player
  would notice the missing chunks and column.
- **F2:** the late blast looks exactly like row `r13_vehicle_wreck` of `tools/silly_explosion_gallery.lua`.
  What's wrong is when it happens, which a still frame can't show.

## What I did NOT prove

- Nothing ran in Studio or a live server. The Roblox world is a stand-in (`destruct_mocks.lua`):
  raycasts hit a flat plane, particles are counted rather than drawn, and time only moves when stepped.
- F1's in-match effect (how often three hits line up next to a real explosion) is arithmetic from fire
  rates, not a measurement. Whether it is noticeable is for the render and Oliver's eye.
- F2 relies on VehicleClient's 320-stud gate and on streaming keeping far wrecks loaded. I read both in
  the code; I didn't run them (VehicleClient is a LocalScript).
- I assumed the client gets the detonate event while the barrel or mine model still exists (the server
  sends it before `model:Destroy()`). Roblox orders these on one channel, as far as I know; that is not
  measured. Either way the ground scorch is found, because the barrel body isn't a scorch surface.
- The vehicle-wreck blast is cast from the chassis with no normal. If a car's collidable body parts are
  4.1 studs or more across in two directions, its scorch and shock ring could land on the car. I didn't
  check the vehicle models.
- The look of any explosion. That is judged by eye, in the existing gallery.
