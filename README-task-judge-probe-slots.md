# task/judge-probe-slots

Cut from main `d1e4f73`. A report on the 1000 handoff's two `base_vehicle_respawn_check` items: the
`judge_probe` slot count (section 3) and the seed-9 failure (section 1).

New files only. No game file or existing tool is changed.

- `reports/base-vehicle-respawn-seed9.md`: `judge_probe` is already fixed on the sweep (2e6d846). The
  seed-9 failure is a real parking fault on both trees: a replacement can be parked in terrain water
  and is lost as "drowned" a tick later. Main fails 15 of 300 seeds and the sweep 10 of 300. The report
  has file:line on both trees.
- `tools/base_vehicle_respawn_seed_sweep.py`: runs the unchanged check over seeds 1..N and flags any
  replacement lost within 2 s of parking. It has a permanent plant (every replacement lands in water).

```
/tmp/brr-venv/bin/python tools/base_vehicle_respawn_seed_sweep.py .          # main: 15 of 300 seeds fail (the fault)
/tmp/brr-venv/bin/python tools/base_vehicle_respawn_seed_sweep.py . --plant  # 1 of 1 caught
```
