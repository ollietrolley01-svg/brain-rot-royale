# task/bugtest-tonight-fixes

Cut from main `d1e4f73`. A bug test of the six fixes the build machine landed on 2026-09-25 (explosive
follow-ups, drop-picker reset, roadkill rules, range reload, clock deadlines, bot movement), on Oliver's
order to run bug tests.

New files only. No game file or existing tool is changed.

- `reports/bugtest-tonight-fixes.md`: the verdict per fix, the findings ranked with file:line, what was
  measured and what was only read, and what was not proven.
- `tools/tonight_fixes_bugtest_check.py`: 5 edge checks the fixes' own checks don't plant (roadkill seat
  shelter on every seat, the armoured gunner, pellet blasts on every gun, clock mixing across the game,
  the route continuation's guards), 12 planted faults, and the findings as `FINDING` lines. It reuses
  `roadkill_proof_world.lua` and `explosive_dispatch_world.lua` through their own checks' loaders.

```
/tmp/brr-venv/bin/python tools/tonight_fixes_bugtest_check.py .          # 5 checks, 0 failed, 6 findings
/tmp/brr-venv/bin/python tools/tonight_fixes_bugtest_check.py . --plant  # 12/12 caught
```
