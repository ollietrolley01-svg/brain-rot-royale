# task/gunner-range

Cut from main at d1e4f73. Task 15: "make the gunner guns have more range of motion" (Jacob's playtest).

Every turret already turned all the way round (yawLimit 180), and every clamp in the code (server
`Solve`/`InArc`, client `GunnerView.clampLook`, `VehicleWeaponClient`'s held aim) reads the limits from
`VehicleWeaponData`, so the pitch limits and the two guards were the whole of it. The drivers' guns are
unchanged.

| Turret | Before | After |
|---|---|---|
| Rotster Roof Gun | -12..25 | -18..36 |
| Ranger Rocket Pod | -8..30, front guard 4 within 54 | -15..60, front guard 4 within 60 |
| Sahur Van Mortar | 10..60 | 10..80 |
| Tartaruga HMG | -8..25 | -12..34 |
| Camelo Grenade Launcher | -8..30, rear guard -6 within 15 | -18..55, rear guard -5 within 45 |

- `ReplicatedStorage/Shared/VehicleWeaponData.lua`: the new limits, each 3-4 degrees inside where the
  arc sweep finds the first contact, with the measured stops in the comments.
- `tools/vehicle_models_axis_check.py`: invariant 6 now reads the rear guard (it ignored it before) and
  steps pitch 2 degrees at most (it took 11 even steps, up to 3.8 apart), with poses on both sides of each
  guard's edge. New invariant 7: the shot's first stretch (pivot, muzzle, 4 studs on, the line the Studio
  gallery sweep casts) meets no visible part of the vehicle. Four new plants: limits that put the HMG's
  grips through its roof or the roof gun's barrel through its roof, and the Ranger's and Camelo's guards
  dropped. Nearby parts' boxes are cached, so the whole check runs in about 5.5 min (it took 12).
- `tools/vehicle_models_runtime_check.py`: reads the rear guard from the same arcs.
- `tools/vehicle_weapons_gallery.lua`: `_low` and `_high` views, side-on to each turret at its floor and
  its top pitch.
