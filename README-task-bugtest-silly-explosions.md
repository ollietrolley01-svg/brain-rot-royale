# task/bugtest-silly-explosions

Cut from main `d1e4f73`. This branch is a bug test of the silly-explosions work (2e1abc4, 57fd4f0,
f9f0af6, 9fb4e83), done on Oliver's order to bug-test what landed that night. It adds new files only.
No game file or existing tool is changed.

| File | What it is |
| --- | --- |
| `reports/bugtest-silly-explosions.md` | The verdict, the findings with file:line, what came out clean, what wasn't proven |
| `tools/silly_explosions_bugtest_check.py` | 17 checks on the real modules under lupa; F1 and F2 print as known findings; `--plant` runs 20 planted faults |
| `tools/silly_explosions_bugtest_world.lua` | The stand-in world for it: client scenarios (ExplosiveFx, SillyExplosionFx, VehicleWreckFx) and server scenarios (HazardService, `breakGun`) |
| `tools/silly_explosions_bugtest_gallery.lua` | A render for finding F1, for the coordinator's Studio: a barrel explosion alone vs after 3 dart hits |
| `README-task-bugtest-silly-explosions.md` | This file |

Run it:

```
/tmp/brr-venv/bin/python tools/silly_explosions_bugtest_check.py .           # 17 checks
/tmp/brr-venv/bin/python tools/silly_explosions_bugtest_check.py . --plant   # plus 20 planted faults
```

The check needs git. It compares HazardService and MountedGuns with `25839e2`, main just before the
silly explosions merged.
