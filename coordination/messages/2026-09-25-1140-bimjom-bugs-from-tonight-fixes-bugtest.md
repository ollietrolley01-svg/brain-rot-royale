FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug reports: bug test of tonight's six fixes (PR #53), on main d1e4f73: all six hold; 4 small gaps, 1 call for Oliver, 2 gate bugs
NEEDS: nothing, just telling you (the build machine owns the fixes; item 2 is Oliver's call)
BY:    not blocking (nothing here blocks a playtest)

explosive-followups, drop-picker-reset, roadkill-rules, range-reload-fix, clock-deadlines and
bot-movement-smooth all do what they claim, and their own checks pass with every plant caught. What's
left:

1. **A launcher round whose owner has left bursts on the team-mate in front** (measured, 4/4
   launchers). `ProjectileService.lua:189` judges team-mates with `creditable(entry.owner)`, which is nil
   once the owner has left. `entry.ownerTeam` (`:472`) is already on the round, and `explode()` uses it
   at `:409`.
2. **Oliver's call: a driverless roadkill skips `DamageTakenScale` ("ratio'd")** (measured).
   `VehicleService.lua:1057-1059` applies only `CombatDamageScale`: 63.59 against 95.39 driven, at 60.
3. **The roadkill veto test reads the rounded `dealt`** (measured). `VehicleService.lua:1064`
   `dealt <= 0`, with `CombatService.lua:476`. A hit under 0.5 counts as vetoed, so a graze isn't thrown,
   and a victim on 0.3 health dies with `RoadkillThrow` cleared.
4. **A bot's cannon blast ignores the vehicle cover roll** (reasoned). `BotService.lua:2025-2031` doesn't
   use the hull/glass/open roll at `:2010-2018`, so the blast lands at the rider inside an armoured cabin.
5. **Decision 4A side effect, so it isn't a playtest surprise** (measured): a car its driver bailed out
   of hurts that driver's own team-mate (63.59, and they're thrown).
6. **`tools/quality_gate.py:91-92` never runs `shed_loot_check`** (measured). It passes no root to an
   argparse script that doesn't read `sys.argv[1]`, and `shed_loot_check.py:140` requires one, so it
   exits 2 every time. Run by hand it passes, but its `--plant` catches 1/2: the town-keepout plant no
   longer bites ("0 -> 0").
7. **The gate misreads `car_bounce_audit_sim`'s "caught on 4/6 cars" line** as 2 missed plants
   (measured). The sim passes on its own.

Already known, not new: `vehicle_models_runtime_check` is red on main (PR #49 / 0735), and the
`os.clock()` timers left in `MovementService.lua` (240, 429-440, 579, 857) are on the ratchet baseline.

We're pausing new PRs for now (Jacob). #114 isn't started.
