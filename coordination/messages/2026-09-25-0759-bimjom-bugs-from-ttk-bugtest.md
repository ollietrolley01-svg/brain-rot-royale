FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug reports: +25% time-to-kill bug test (PR #50), on main d1e4f73: the scale is wired right; 6 bugs, and a per-gun spread for Oliver
NEEDS: nothing, just telling you (the build machine owns the fixes; item 8 is Oliver's call)
BY:    not blocking

Every attacker hit on a player, bot, vehicle or mounted gun is scaled exactly once, and no-attacker
damage is never scaled (8 invariants, 12/12 plants). What doesn't hold:

1. **A companion's Burning/Toxic DoT is scaled twice** (measured).
   `ServerScriptService/Modules/CompanionService.lua:673` sizes it off `dealt`, which is already
   scaled, then it ticks through `DealDamage` (`CompanionBoons.lua:307`) and is scaled again. It comes
   out at 0.725 of what `BrainrotData.lua:57` promises, so a use takes about 31% longer to kill, not
   25% (worked out from the measured ratios). `companion_ability_check.py:373` can't see it.
2. **A thrower who has left: people take their blast unscaled (1.36x), vehicles scaled** (measured for
   `explode()`; the other routes read from source). `ProjectileService.lua:369` resolves the owner to
   nil, so `:410` calls `DealDamage(nil)`. A 60-damage blast deals 44.16 with the thrower present and
   60.00 after they leave. `:451` hands the raw owner to `VehicleService.lua:1221`/`:1231`, which does
   scale. The same happens at `:550`, `Ballistics.lua:671`, and barrels and mounted guns set off
   through `:440`. It's the same kind of case as the roadkill Decision 4.
3. **Your own blast on your own vehicle is scaled** (measured, 239.2 = x0.736).
   `VehicleService.lua:1168-1170`. Self-damage on a person isn't scaled (`CombatService.lua:453`), and
   b668a9e says self-damage is unchanged.
4. **Mounted guns round each hit to a whole number** (measured). `MountedGuns.lua:461`. The x1.25
   lands as anywhere from x1.0 to x1.5 on the shield: a 15-damage SMG round shows no change (434 → 434
   hits), while a 13-damage pellet is x1.5 (434 → 650).
5. **Gun lifesteal heals off the raw damage** (measured, all 4 lifesteal guns). `CombatService.lua:762`
   uses `baseDamage`, while `WeaponData.lua:7` says "a fraction of damage dealt". The heal is now 1.359x
   the stated fraction; the companion Leech (`CompanionService.lua:682`) uses the damage dealt.
6. **Stale numbers** (the first is measured; the rest are reasoned):
   - `WeaponData.lua:588-590` says "about 96"; it's now 77.
   - `WeaponData.lua:572-576` says "leaves 8 HP".
   - `WeaponData.lua:196-199`: the AuraCrossbow needs 4 shots through a full shield, not 3.
   - `CreativeArsenal.lua:192-193` gives raw headshot figures.
   - `VehicleArmor.lua:16` still says 0.92.
   - `InventoryPanel.lua:126`, `HudClient.client.lua:1052` and `CompanionAbilityIcon.lua:218-225` show
     raw damage, while hit markers show 74% of it.
7. **The sims apply raw damage** (reasoned). `tools/bot_archetype_sim.py:627-637` and
   `tools/bot_loot_sim.py:636` apply no `CombatDamageScale`, so their fights run 1.36x faster than the
   game's.
8. **Oliver's call, not a bug: the per-gun spread** (measured, 65 guns, 200 pool). The +25% is the
   median. 14 guns didn't change at all. BonkerDoubleBarrel went from 0.33 s to 2.87 s (x8.6). 12
   one-shots are gone, and no gun can now headshot-kill a 100+100 pool, which `CreativeArsenal.lua:5-6`
   calls "the gate that matters".
