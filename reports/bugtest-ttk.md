# Bug test: the +25% time-to-kill (b668a9e, merge 25839e2)

Jacob's branch `task/bugtest-ttk`, cut from main **`d1e4f73`** (`git rev-parse --short origin/main`), and every
run is on that tree. This is a bug test, the kind Oliver asked for (coordination/messages/2026-09-25-0300 and
-0315), not a row proof. New files only. No game file and no existing tool was edited.

The change under test: `MatchConfig.CombatDamageScale` 0.92 -> 0.736 (0.92 / 1.25), `BrainrotData.MaxUseDamage`
x0.8, a comment in `VehicleArmor.lua`, and the bands in three checks x1.25. The commit message says "every such
kill takes exactly 25% longer" and that storm, fall, crash and self-damage have no attacker and are unchanged.
Numbers below use **0.736** (main) and, for "before", the same tree with only that one line set back to 0.92.

## Verdict

**The scale itself is wired right.** Every hit one combatant lands on a player, bot, vehicle or mounted gun is
scaled exactly once, and hits with no attacker are never scaled. I measured this in lupa through the real
`DealDamage`, `DamageVehicle`, `damageGun`, StatusEffects and the companion venom: 8 invariants pass, and 12 of
12 planted faults are caught. **Four of the commit's claims don't hold, though:**
- A companion's Burning/Toxic DoT is scaled twice.
- A blast from a thrower who has left skips the scale on people but not on vehicles.
- A player's own blast on their own car is now scaled.
- The kill time does not rise by "exactly 25%" gun by gun. Rounding to whole shots gives anything from no change
  at all to 8.6x, and it removes every headshot one-shot through a full shield.

None of this breaks the game. Whether the per-gun spread is acceptable is Oliver's call.

## Findings, most important first

1. **A companion's style DoT (Burning, Toxic) is scaled twice.** `CompanionService.lua:673` sizes the DoT off
   `dealt`, the damage the hit took AFTER `CombatDamageScale`. The DoT then ticks through
   `CompanionBoons.lua:307` -> `DealDamage`, which scales it again. `BrainrotData.lua:57` says the DoT is the
   "fraction of the hit dealt again". **Measured:** a 40 hit takes 29.44. Burning's DoT then takes 6.40, which is
   0.218 of the hit where BrainrotData says 0.3. Toxic's takes 7.47, which is 0.254 of the hit where it says 0.35.
   Both are 0.725 of the stated fraction, i.e. the scale again. The bug predates this commit, but the commit
   made it bigger. At 0.92 the DoT lost 8% to the second scale; at 0.736 it loses 26%. Worked out from those
   measured ratios (not measured end to end): an uncapped Burning or Toxic use now takes 31% longer to kill,
   not 25%. The venom boon is not affected. It is sized off the raw number and scaled once (invariant I7).
   `companion_ability_check.py:373` can't see any of this. Its side-grade model is `damage x (1 + dot)` with no
   scale, so it reports Toxic at 1.080x the plain move when the real path gives 1.006x (Burn 1.105 vs 1.038).
   Both are still inside its 0.85-1.2 band, so it passes, but for the wrong reason.

2. **A blast from a thrower who has left hits people unscaled (1.36x) but vehicles scaled.**
   `ProjectileService.lua:369` turns the owner into `creditable(blast.owner)`. That is nil once the thrower has
   left, so `ProjectileService.lua:410` calls `DealDamage(nil, ...)` and the hit is not scaled.
   `ProjectileService.lua:451` hands `VehicleService.BlastDamage` the raw `blast.owner`, and
   `VehicleService.lua:1221/1231` passes it to `DamageVehicle`. That owner is not nil, so the vehicle is scaled.
   **Measured:** a 60 blast 1 stud from a player takes 44.16 with the thrower present and 60.00 once they have
   left, 1.359x. Before this commit the gap was 1.087x.
   Other paths go the same way (reasoning, from source): a round that doesn't explode
   (`ProjectileService.lua:550`), the Bananerang's cut (`Ballistics.lua:671`), and anything set off through
   `DamageHazardsInRadius(..., owner)` (`ProjectileService.lua:440`). That covers barrels, which then deal
   `DealDamage(nil)`, and mounted guns, whose nil-attacker hit is unscaled (I6 measures that half).
   This is the same class of case as the driverless car in the roadkill work. There Oliver answered "the damage
   scale applies even with no attacker" (message 0300, Decision 4), and `VehicleService.lua:1057` now does that
   for roadkill. Blasts were not given the same rule.

3. **"Exactly 25% longer" is true of the median, not of the guns.** This is Oliver's to judge by feel. It is
   not a code bug. I counted shots through the real `DealDamage` (launchers: the real `explode()` on a direct
   hit), for all 65 hand guns, against a 100-health player and a 100 + 100-shield player. Counts are whole
   shots, so the kill time jumps in steps and magazine boundaries add reloads. The time to kill the 200 pool
   with reloads changed by:
   - **median x1.250**
   - 37 guns inside 1.15-1.35
   - **16 guns under 1.15**, 14 of them **x1.000, no change at all**: AuraCrossbow, CappuccinaLauncher,
     DeadAirPrecision, GoldenSahurCannon, LarilaSniper, NightShiftPump, NonnaDoubleBarrel, QuietHours,
     TralalaShotgun, TralalaThumper, and 4 staged guns
   - **12 guns over 1.35**: BonkerDoubleBarrel **0.33 s -> 2.87 s (x8.6)**, because two shells no longer clear
     200 and the third needs a reload. Also DeluluRailgun x2.7, PizzaCutterCrossbow x2.6 (staged),
     RustbeltMarshal x2.33, AuraScattergun and BackroomsBreacher x2.0, ZanzarinoPikpik x1.99 and
     TamburoTungTung x1.51.

   **12 one-shots are gone:**
   - The body one-shot of a 100-health player: AuraScattergun, BackroomsBreacher, BonkerDoubleBarrel.
   - The headshot one-shot of a 100-health player: NightShiftPump, plus the staged CleanSweepDouble and
     SpaghettiSlinger.
   - **Every headshot one-shot through a full shield**: DeadAirPrecision, LarilaSniper, QuietHours,
     NonnaDoubleBarrel, plus the staged GrandmasSlipperLauncher and RubberChickenRailgun. No gun in the game can
     now kill a 200 pool with one headshot. `CreativeArsenal.lua:5-6` calls that threshold "the gate that
     matters".

   Vehicles (the same loader and `ttk()` as `vehicle_ttk_check`):
   - Seconds of fire, 513 gun and vehicle pairs: 21 went up by less than x1.15 and 78 by more than x1.35. The
     reference rifle takes a bike 2.8 -> 5.6 s (x2.0, a reload).
   - Rounds to kill, 45 launcher and vehicle pairs: 8 unchanged, 19 need one more, 18 need two or more. The
     Cappuccina needs 6 -> 8 rockets on the CameloCarrier (x1.33).
   The `MatchConfig.lua:107-109` comment ("every kill ... takes 25% longer") is only true on average.

4. **Mounted guns keep their health in whole numbers, so the change lands unevenly on small hits.**
   `MountedGuns.lua:461` stores `math.floor(after + 0.5)`, which rounds every hit to a whole number. A shield
   hit is damage x 0.25 x scale:
   - A 15-damage SMG round was 3.45 -> 3 and is now 2.76 -> 3. **No change**: 434 -> 434 hits on the HMG's
     shield. The same goes for Doomscroll, DustDevil, Glitch and Spaghetti, on both guns.
   - A 13-damage pellet was 2.99 -> 3 and is now 2.39 -> 2: **x1.5**, 434 -> 650 hits. That covers 5 shotguns,
     RotSMG, JuiceBox, CameloLMG and RageQuit.

   **Measured over 260 cases (gun x emplacement x face):** 28 fall outside 1.10-1.45 against the expected 1.25.
   None became immune: the smallest hit, 2.2, still rounds to 2. The rounding predates this commit; the
   commit's scale is what shifts it. Body hits come out near 1.25.

5. **Gun lifesteal heals off the raw damage, not what the hit took.** `CombatService.lua:762` heals
   `baseDamage x ratio`, where `baseDamage` is `def.damage`, before the scale. `WeaponData.lua:7` says lifesteal
   "heals the shooter for a fraction of damage dealt". **Measured** through the real `CombatService.Fire` on all
   4 lifesteal guns (AuraScattergun, CameloLMG, LavaLampLancer, QuietHours): the heal is **1.359x** the stated
   fraction of the damage dealt. Before this commit it was 1.087x.
   A companion's Leech heals off `dealt` (`CompanionService.lua:682`), so the two lifesteals now disagree by 36%.
   Separately, every heal (potions, regen, lifesteal) is unchanged while damage fell 20%. So heals are
   relatively stronger, and a fight with healing in it stretches by more than 25%. That is Oliver's to judge.

6. **A player's own blast on their own car is now scaled.** `VehicleService.lua:1168-1170` scales any
   non-nil attacker, including a rider who owns the blast. `CombatService.lua:453` doesn't scale
   `attacker == victim`. **Measured:** the owner's own 50 on the Rotster they ride takes 239.2, which is x0.736.
   The same 50 on themselves takes 50.00. The commit says self-damage is unchanged, but on the owner's own
   vehicle it fell 20%. Minor.

7. **Stale numbers (reasoning, except where marked measured):**
   - `WeaponData.lua:588-590` says the Golden Sahur Cannon's body shot plus shell "comes to about 96". It is
     now **77**, measured by `explosive_dispatch_check` and `explosive_ammo_check` (76.5).
   - `WeaponData.lua:572-576`: the cannon's body shot "leaves a full-health player on 8 HP". That was raw
     damage. It now leaves 32 (23.5 with the shell).
   - `WeaponData.lua:196-199`: the AuraCrossbow comment says "THREE body shots are needed to kill through a
     full shield", and sizes magSize 3 to that. It takes **4** (measured in the table, 4 -> 4), so every
     full-shield kill has a 1.4 s reload in it. This has been true since 0.92, not only since this commit.
   - `CreativeArsenal.lua:192-193`: "QuietHours (225.6) and the RubberChickenRailgun (231)" are raw headshot
     numbers. They are now 166 and 170, under the 200 pool.
   - `VehicleArmor.lua:16-27` still says "after MatchConfig.CombatDamageScale (0.92)". The commit's own note at
     `:32-34` flags these as the old figures.
   - The UI shows raw damage. `InventoryPanel.lua:126` prints `def.damage` as "N dmg", and the companion move
     text in `HudClient.client.lua:1052` and `CompanionAbilityIcon.lua:218-225` does the same. The hit marker
     shows 74% of that now; the gap was 8% before. Oliver decides whether that matters.

8. **Checks that ignore the scale:**
   - `tools/bot_archetype_sim.py:627-637` takes the raw `amount` off health, with no `CombatDamageScale`. Its
     duels therefore run 1.36x faster than the game's (1.087x before). The commit lists it as "clean", but it
     cannot see this change.
   - `tools/bot_loot_sim.py:636` has its own damage model, also without the scale.
   - `companion_ability_check.py:373`: see finding 1.
   No check asserts the old 0.92 scale. The three the commit moved read 0.736 (`vehicle_ttk_check` reads it
   from MatchConfig; `companion_ability_check:182/512` pins it). `roadkill_proof_check` pins 0.736 on purpose.

## The damage paths, counted

**17 `DealDamage` call sites (on d1e4f73).** For each: who is the attacker, and is the hit scaled?

| Site | What | Attacker | Scaled | Consistent |
| --- | --- | --- | --- | --- |
| CombatService.lua:1041 | bullet on a body (headshot multiplier inside `amount`) | shooter | once | yes |
| CombatService.lua:965 | rider seen through glass (the car's share goes to DamageVehicle, scaled once) | shooter | once | yes |
| CombatService.lua:724 / 735 / 753 | receipt bonus, audit arcs, chain | shooter | once | yes |
| BotService.lua:2019 | a bot's rolled shot (x BotDamageScale 0.8 first, the difficulty dial) | bot | once | yes |
| ProjectileService.lua:410 | blast | `creditable(owner)` | once; **unscaled if the owner left** | **no (F2)** |
| ProjectileService.lua:550 | a round that doesn't explode | `creditable(owner)` | same as above | **no (F2)** |
| Ballistics.lua:673 | Bananerang cut | `Creditable(owner)` | same as above | **no (F2)** |
| VehicleWeapons.lua:320 | vehicle / emplacement gun | gunner | once | yes |
| VehicleService.lua:1060 | roadkill | driver, or nil (pre-scaled at :1057) | once either way | yes (roadkill_proof_check I9: 63.59 = want) |
| HazardService.lua:390 | barrel / mine | whoever set it off; nil after a leaver's blast | once / unscaled | as F2 |
| StatusEffects.lua:142 | echo | shooter | once | yes (I4) |
| StatusEffects.lua:281 | bleed / ignite ticks | shooter | once | yes (I4) |
| CompanionService.lua:696 | companion hit | owner | once | yes |
| CompanionBoons.lua:307 | venom boon / style DoT ticks | owner | once a tick; **the style DoT is sized off the scaled hit** | **no (F1)** |
| DestructibleService.lua:2768 | falling rubble | nil | never | yes (environment) |

Damage that doesn't go through `DealDamage`:
- `StormService.lua:29`: the storm calls `TakeDamage` directly. Nil attacker, never scaled.
- `VehicleService.lua:946`: a crash. Never scaled.
- `DamageVehicle` (`VehicleService.lua:1159`), 6 callers: CombatService 964 / 967 / 1036, BotService 2015,
  VehicleWeapons 309, VehicleService 1231. Scaled once when there is an attacker (I5). The exception is F6.
- `damageGun` (`MountedGuns.lua:444`), 3 routes: the hook at :496, blasts at :517, `MountedGuns.Damage`.
  Scaled once when there is an attacker (I6).

Hits on companions and on player structures are not scaled. The commit says "players and vehicles", so that fits.

Things that could cancel the scale, looked for and not found:
- `DealDamage` has no floor, cap or one-shot threshold after the scale.
- `dealt` is rounded for reporting only; health takes the exact float.
- The shield soaks the scaled amount (I1).
- `DamageTakenScale` (ratio'd) applies once, only to an attacker's hit (I3).
- The companion cap is booked at `amount x scale` (`CompanionService.lua:653-656`), so it counts after the
  scale, and MaxUseDamage x0.8 keeps capped uses at x1.25.
- Bots make no decisions from damage numbers. BotService only multiplies `def.damage` by `BotDamageScale`, at
  :1967 and :2003.

I also checked 13 places that set Health directly (heals, respawns, admin). Only lifesteal (F5) and Leech are
worked out from damage.

Damage quests and the Menace achievement count `dealt`, and that is capped at what the victim had. A kill is
still worth about 100-200 of progress. Only damage that doesn't end in a kill counts 20% slower per second of
firing. That is reasoning, not a bug.

## The check: `tools/ttk_bugtest_check.py` (new, in my branch)

It runs the game's Lua in lupa inside `tools/explosive_dispatch_world.lua`:
- **Loaded whole:** CombatService, ProjectileService, VehicleWeapons, StatusEffects, WeaponData (all packs),
  Ballistics, VehicleArmor, MountedGunData and MatchConfig.
- **Cut from their files:** WeaponService's `AbsorbDamage`; VehicleService's `DamageVehicle`, `damageVehicle`,
  `vetoed` and `ridersOf`; MountedGuns' `damageGun`; CompanionService's `withinUse`, `applyStyle` and `hit`; and
  CompanionBoons' `StartVenom` and `TickVenom`.
- **Harness-only rewrites:** Luau's `+=` and `continue` become plain Lua (the world's converter). StatusEffects'
  `ServerScriptService:WaitForChild("Modules")` points at `script.Parent`, the same folder, because the world
  resolves requires that way.
- **Stubs:** `underCanopy` is stubbed to false, so the same tool also runs on `pc/lag-bug-sweep`.

```
ok    I1 DealDamage: a hit from another combatant takes amount x 0.736 from the pool (player with and without a shield, bot with one; 3 amounts)
ok    I2 DealDamage: no attacker, and a victim's own hit, take the whole amount
ok    I3 ratio'd victim (1 gun(s)): an attacker's hit x scale x mark, no attacker's plain
ok    I4 4 DoT/echo effect(s) through the real StatusEffects: each scaled exactly once
ok    I5 DamageVehicle, 9 vehicles x 3 classes: attacker's hit x armour x scale, no attacker's x armour
ok    I6 damageGun, 2 guns x 3 classes: attacker's hit x class x scale, no attacker's x class
ok    I7 venom boon: the bite took 29.440 (40 x 0.736), the venom 17.664 (24 x 0.736 = 17.664): scaled once
ok    I8 65 hand guns, 195 cases: the real path's shots to kill equal ceil(pool / (hit x scale))
examined: I1/I2 DealDamage cases 27, ratio guns 1, bleed/ignite/echo effects 4, vehicle x class x attacker cases 54, mounted gun cases 12, hand guns 65, shots-to-kill cases 195
...
ttk_bugtest_check: 8 invariants, 0 failed, 10 finding line(s)
```

The findings lines (F1-F6) and the three tables print below the invariants. The findings don't fail the check:
they are this report's bug list, and fixing them is the build machine's job. The planted faults each break
something the code must keep forever:

```
  caught  DealDamage drops the scale
  caught  DealDamage scales every hit, no attacker too
  caught  DealDamage scales twice
  caught  the ratio mark counts on a hit with no attacker
  caught  the shield soaks the unscaled hit
  caught  health rounded down on every hit
  caught  a bleed or ignite pre-scaled before its ticks
  caught  DamageVehicle drops the scale
  caught  DamageVehicle scales a hit with no attacker
  caught  damageGun drops the scale
  caught  a launcher's direct hit loses its impact bonus
  caught  the venom boon pre-scaled before its ticks
planted faults: 12/12 caught
```

## The existing checks, on d1e4f73 (last line of each, verbatim; exit 0 for all)

```
vehicle_ttk_check: 0 problems                        (--plant: vehicle_ttk_check planted faults: 7/7 caught)
mounted_guns_check: 0 problem(s)                     (--plant: 25 "PLANT caught" lines, 0 missed)
companion_ability_check: PASS (0 failures)           (--plant: companion_ability_check --plant: 14/14 caught)
roadkill proof: 22 checks, 0 failed, 0 findings
roadkill check: 25 checks, 0 failed
explosive_dispatch_check: 93 checks, 0 failed, 0 finding(s)
explosive_ammo_check: 23 checks, 0 failed
gunfun mechanics: 29 checks, 0 failed
vehicle_cover_check: 0 problems
vehicle weapons check: OK
bot_aggression_check: 0 failures
regen_check: 21 checks, 0 failed
```

The commit said `explosive_ammo_check` crashed on main. It passes now.

## Unmerged branches

`git diff --stat origin/main...origin/<branch>` over the 15 damage files above, for every `pc/*` branch that
has commits main doesn't:
- `pc/teambase-v2` (19 commits ahead) touches `MatchConfig.lua` (a base vehicle slot) and `BotService.lua` (bot
  driving). It doesn't touch any damage code, so nothing here changes if it merges.
- `pc/lag-bug-sweep` (30 ahead) touches 11 of the 15 files. I ran `ttk_bugtest_check` on a `git archive` of it:
  the same 8/8 invariants pass, 12/12 plants are caught, and F1-F6 and every table come out identical. So the
  findings stand if it merges. Its `ProjectileService` still passes `creditable(owner)`, and its
  `CompanionService` still sizes the DoT off `dealt`.

All other `pc/*` branches are already in main.

## What this does NOT prove

- **Nothing ran in Roblox.** Every number comes from lupa with stand-ins for the engine. Health here is a
  plain float. I assume Roblox's `Humanoid:TakeDamage` behaves the same, which isn't measured.
- **Feel.** Whether a 1.0x-8.6x spread per gun, lost one-shots, or relatively stronger heals are acceptable is
  Oliver's call. A playtest settles it; numbers can't.
- **Gun mechanics are left out of the shot-count table.** It counts the gun's own hits only: no bleed, echo,
  ratio mark, streak payout or explosive ammo, with every shot landing and no range falloff. The mechanics
  themselves are checked to scale once (I3, I4) but aren't in the counts.
- **The vehicle table uses `vehicle_ttk_check`'s model** (a direct hit, rifle seconds with reloads), not a
  traced shot at a hull.
- **F2 is measured for `explode()` only.** The other leaver routes (a dud round, the Bananerang, barrels,
  mounted guns) are read from source.
- **F1 is measured on an uncapped use.** On a capped Epic+ use the cap binds first, so the second scale matters
  less. The "+31%" for a whole use is worked out from the measured ratios, not measured end to end.

## Files

- `reports/bugtest-ttk.md`: this report.
- `tools/ttk_bugtest_check.py`: the check (8 invariants, 12 planted faults), the findings and the tables.
- `README-task-bugtest-ttk.md`: what the branch adds.
