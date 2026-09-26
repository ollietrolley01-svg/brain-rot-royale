# Task 15: the gunner's guns need more range of motion

**Claimed by Jacob (bimjom), branch `task/gunner-range`.** He started the fix before this brief was
written, so it goes straight into `claimed/`.

**Files the claimant owns:** `ReplicatedStorage/Shared/VehicleWeaponData.lua` (the turret specs'
`yawLimit`, `pitchMin`, `pitchMax`, `frontGuard`, `rearGuard`). **Read only:** `VehicleModels.lua` (the
turret geometry the limits protect; pc/vehicle-rest's reverted 14eebfd changes to it must not come
back), `GunnerView.lua`, `VehicleWeapons.lua`.

## What was reported

The gunner's guns can't turn or tip far enough. Jacob relayed this from a 2026-09-25 playtest.

## Where to look

Every turret already turns all the way round (`yawLimit = 180`). The limit is pitch:

| Turret spec (line) | pitchMin | pitchMax | Guard |
|---|---|---|---|
| RotsterRoofGun (line 50) | -12 | 25 | none |
| RangerRocketPod (line 73) | -8 | 30 | `frontGuard` 54 degrees, floor 4 |
| VanMortar, lobs (line 99) | 10 | 60 | none |
| TartarugaHMG (line 120) | -8 | 25 | none |
| CameloGrenadeLauncher (line 143) | -8 | 30 | `rearGuard` 15 degrees, floor -6 |

The driver's guns (RotsterNoseGun and the other four, lines 171-262) are `yawLimit` 20 and pitch -5 to 10. They are not the gunner's,
but confirm with Jacob which guns were meant.

One function set clamps all of these on both sides, so a spec change moves them together:

- `VehicleWeaponData.PitchFloor` and `ClampAim`, lines 327-349.
- `Solve`, line 374, used by the server's `VehicleWeapons` (line 207).
- `GunnerView.Pure.clampLook`, line 103.
- The bots' reach check at `VehicleWeapons` line 566.

The limits are there for a reason. Each one keeps the gun out of its own vehicle, and the comments
say how each was found. The 25-degree `pitchMax` stops the spade grips coming down through the hatch
ring. The front guard stops the launcher firing into the Ranger's cab roof. The rear guard clears the
Camelo's hump. `tools/vehicle_models_axis_check.py` sweeps the arcs. So more range probably means
moving or reshaping the turret in `VehicleModels`, or adding a guard, not only changing a number.
Changing `VehicleModels` is outside this brief's files, so write the exact before/after in the PR and
the build machine applies it.

## Conflicts

No unmerged branch touches `VehicleWeaponData.lua`. `VehicleModels.lua` is changed by `pc/lag-bug-sweep`
(with `task/blast-parachuters` and `task/bot-gunner-wait` stacked on it) and by PR #65
(`task/vehicle-seams`), and `vehicle_models_axis_check.py` by PR #65 and `pc/teambase-v2`. None of
them change a turret's grips or GunnerEye.

## Proof

Offline: `vehicle_models_axis_check.py` sweeps each turret through its arc and holds that the gun
never enters the hull. Widen the limits, run the sweep on every armed model, and report each turret's
old and new pitch range, with the number of arc samples checked. The sweep's planted fault (a limit
past the hull) must still turn it red. Run `vehicle_weapons_check.py` and `mounted_guns_check.py` too
and paste their lines.

**The look needs a render.** A gun that clears the hull by the numbers can still look wrong. The
coordinator runs `tools/gunner_fp_gallery.lua` (its `_fp_swung` view) and `tools/mount_gallery.lua` at
the new extremes.
