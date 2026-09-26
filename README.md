# proof/gunner-aim-world

Proof-only branch for PR #69 (Task 14: gunner aim holds world direction when the car turns).
**Never merge this branch.** The repo commits no images; these are here only so the PR can embed them.

Rendered by `tools/gunner_aim_world_gallery.lua` (Linux Studio harness, edit mode) on task/gunner-aim-world
at bb40cd0: the real Rotster and the real GunnerView, stepped by hand. The gun is laid on a green pole
60 studs ahead, then the car yaws about the turret axis at 90 deg/s with no input.

| File | What to look for |
| --- | --- |
| `montage_car.png` | The four chase views side by side (car turned 0/45/90/135 deg): the magenta beam down the barrel ends on the green pole in every one |
| `montage_fp.png` | The four gunner views side by side: the pole stays centred in the sight; only the bonnet under it moves |
| `001_car_000.png` | Chase view, car at 0 deg: the gun laid on the pole |
| `003_car_045.png` | Chase view, car turned 45 deg: beam still on the pole |
| `005_car_090.png` | Chase view, car turned 90 deg: beam still on the pole |
| `007_car_135.png` | Chase view, car turned 135 deg: beam still on the pole |
| `002_fp_000.png` | Gunner view, car at 0 deg: pole centred in the sight |
| `004_fp_045.png` | Gunner view, car turned 45 deg: pole still centred |
| `006_fp_090.png` | Gunner view, car turned 90 deg: pole still centred |
| `008_fp_135.png` | Gunner view, car turned 135 deg: pole still centred |

The beige arms in the gunner views are the gallery's stand-in (edit mode has no avatar).
