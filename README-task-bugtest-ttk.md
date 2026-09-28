# task/bugtest-ttk

This branch is cut from main `d1e4f73` and every run is on that tree. It is a bug test of the +25%
time-to-kill (b668a9e, merge 25839e2: `MatchConfig.CombatDamageScale` 0.92 -> 0.736), which Oliver asked for in
coordination/messages/2026-09-25-0300 and -0315. It adds new files only. No game file or existing tool
changed.

- `reports/bugtest-ttk.md`: the report. The verdict comes first, then 8 findings ranked, the 17 `DealDamage`
  call sites and the other damage paths counted, the existing checks' results, and what was not proven.
- `tools/ttk_bugtest_check.py`: runs the real CombatService, ProjectileService, StatusEffects and the damage
  functions of VehicleService, MountedGuns, CompanionService, CompanionBoons and WeaponService in lupa (the
  world is `tools/explosive_dispatch_world.lua`). It holds 8 invariants, including "every attacker hit is
  scaled exactly once" and "a hit with no attacker is never scaled", and catches 12/12 planted faults
  (`--plant`). It also prints the findings (F1-F6), and tables of every gun's shots and seconds to kill at 0.92
  and at 0.736, against players, vehicles and mounted guns.

    python3 tools/ttk_bugtest_check.py .
    python3 tools/ttk_bugtest_check.py . --plant
