# task/bugtest-awd

Cut from main `d1e4f73`. A bug test of all-wheel drive (47200d3), on Oliver's order to run bug tests on
what landed on 09-25 (mailbox 2026-09-25-0300 and -0315). New files only; no game file or existing tool
is changed.

What the branch adds:

- `reports/bugtest-awd.md`: the verdict, the findings with file:line, what was run, the existing vehicle
  checks on main verbatim, and what was not proven.
- `tools/awd_bugtest_check.py`: runs the real `VehicleDynamics.lua` in lupa. `DriveSplit` and the per-wheel
  drive lines are swept as pure functions (S1-S7). The six cars go through whole-step runs before and after
  AWD, and the bikes are compared number for number (W1-W4). `--bot` runs `bot_driving_sim`'s lap on four
  VehicleDynamics variants. `--plant` runs 7 planted faults aimed at invariants, and all 7 are caught.
  It imports `vehicle_stability_sim.py`, `car_bounce_audit_sim.py` and `bike_balance_sim.py` and leaves them
  unchanged.
- `tools/awd_bugtest_probe.lua`: the Studio side of the crawl, jump and drag runs, shipped split against the
  load-share split in one session. It has not been run, and needs a real Play test with a client.

Run: `/tmp/brr-venv/bin/python tools/awd_bugtest_check.py --plant --bot` (about 2.5 minutes).
