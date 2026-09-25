# Task 08: vehicle-gun aim fails in third person and locks the cursor to the middle

**Files you own for this task:** `StarterPlayerScripts/CombatClient.client.lua`, the `updateCameraMode`
function only; `StarterPlayerScripts/VehicleWeaponClient.client.lua`, `aimScreen` only, if the fix needs it.
**Read only:** `MenuCursor.client.lua` (the one writer of `MouseIconEnabled`, #112), `GunnerView.lua`,
`VehicleClient.client.lua` (pc/vehicle-rest's WIP, 14eebfd, must not come back).

## What Oliver saw

"the aiming for the vehicle guns dont work in 3rd person sometimes and locks your cursor in the middle
of screen". Playtest, 2026-09-25.

## Where to look

The driver's gun follows the mouse only while the mouse is free. `VehicleWeaponClient.aimScreen` (line
105) reads `UserInputService.MouseBehavior`, and when it is `LockCenter`, `aimMode` returns `"centre"`
and the gun aims through the middle of the screen.

The likely cause is in `CombatClient.updateCameraMode` (about line 308). In combat it sets `LockCenter`
(line 325). When `InVehicle` turns on, the vehicle branch turns third person off and sets the camera
mode, then returns without writing `MouseBehavior`. A player who boards while in combat keeps
`LockCenter` for the whole ride. That would explain "sometimes": it depends on whether combat was on
when they got in. Confirm this before fixing it. `GunnerView:look` (line 499) and `GunnerView:Stop`
(line 700) also write `MouseBehavior`, so a gunner who moves to the driver's seat is a second path to
test.

## Conflicts

`pc/lag-bug-sweep` changes both files: `VehicleWeaponClient.aimPoint` (it now filters the riders, so
a roof gunner behind the driver no longer takes the driver's aim) and `swingMount`, and in
`CombatClient` the `setThirdPerson` and `InputChanged` code beside `updateCameraMode`.
`task/blast-parachuters` and `task/bot-gunner-wait` are stacked on it. PR #64 (`task/device-compat`)
also changes `CombatClient`. Cut from `pc/lag-bug-sweep` or wait for it to merge, and say which in
the PR. Part of what Oliver saw may already be fixed there.

## Proof

Offline, with lupa: run the real `updateCameraMode` against a mocked `UserInputService`, the
`InVehicle` attribute and the combat state. Walk it through: combat in third person, board, drive,
leave, and board from a gunner seat. The invariant is that while `InVehicle` is set and no
`GunnerView` is running, `MouseBehavior` is never `LockCenter`. Plant the fault by removing your
write; the check must go red. `tools/vehicle_aim_check.py` already runs `aimScreen`'s PURE block, so
extend it rather than start a new file if that is simpler.

**This task cannot be closed offline.** Whether the cursor is free and the gun follows it needs a
Studio **Play** test with a client, because runtest's Run mode runs no LocalScripts. The coordinator
runs it. The Play test needs a car driven in third-person combat with the mouse moved to each corner,
the same in first person, and a gunner seat, so the fix does not undo the gunner's locked aim. Write
the steps into the PR.
