# task/gunner-aim-world

Task 14 (brief in PR #68): "make the gunner aim not turn with the car". Cut from `origin/main` at
d1e4f73.

## What changed from d1e4f73

- `StarterPlayerScripts/GunnerView.lua`: the gunner's aim is held as a world direction.
  - `Pure.worldOf(rest, yaw, pitch)` and `Pure.anglesIn(rest, world)`: a look's world direction from the
    turret's rest frame, and back.
  - `GunnerView:Update`, before `look`: the turret's angles are carried across the chassis's turn since
    the last frame (held to the arc). The wanted look is re-read each frame from `aimWorld`, the world
    direction last asked for, and held to the arc. `aimWorld` changes only when the mouse, stick or drag
    moves the want, or something sets `wantYaw`/`wantPitch` by hand (the galleries do). So at an arc's
    edge, or under a pitch floor on a bump, the gun waits at the limit and comes back to the aim
    afterwards. The aim is not dragged along.
  - The header's WHAT YOU SEE paragraph says so.
- `tools/gunner_aim_world_check.py` and `tools/gunner_aim_world_mocks.lua`: a new offline check. It runs
  the real GunnerView (`Start`, `Update`, `AimPoint`) and VehicleWeaponData under lupa, yaws the chassis
  90 deg/s under a still mouse, and measures the barrel's world direction. It has 7 planted faults
  (`--plant`) and `--before REF` for the old numbers. It borrows `tools/destruct_mocks.lua`'s
  Vector3/CFrame section.
- `tools/gunner_aim_world_gallery.lua`: the picture, in Studio edit mode. The real Rotster and the real
  GunnerView, with the car turned 0/45/90/135 deg. It shows a chase view with a beam down the barrel to a
  pole, and the gunner's own view.

## Not changed

`VehicleWeaponClient`, `VehicleWeapons`, `VehicleWeaponData` and `MountRig` are untouched. The server
still turns the aim point the client sends into hull-relative `AimYaw`/`AimPitch`, as before.
