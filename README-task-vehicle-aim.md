# task/vehicle-aim (task 08)

Cut from `origin/main` at d1e4f73. Oliver's playtest note, 2026-09-25: "the aiming for the vehicle guns
dont work in 3rd person sometimes and locks your cursor in the middle of screen".

## What changed from d1e4f73

- `StarterPlayerScripts/CombatClient.client.lua`, `updateCameraMode` only: the vehicle branch now sets
  `UserInputService.MouseBehavior` to `Default`, unless the `GunnerView` attribute says a gunner's view
  owns the mouse. Before, it returned without touching the mouse, so a player who boarded in combat kept
  combat's `LockCenter` for the whole ride. `VehicleWeaponClient.aimScreen` reads `LockCenter` as "aim
  through the middle", so the driver's gun ignored the cursor, and MenuCursor hid the icon.
- `tools/vehicle_aim_check.py`: a third half, C. It cuts the real `setThirdPerson`, `updateCameraMode`
  and the `InVehicle` listener out of CombatClient and runs them in the HUD mock world beside the real
  VehicleWeaponClient and GunnerView. It walks combat on foot, board, drive, leave, the gunner's seat,
  gunner to driver and driver to gunner, in third and first person. It also adds three planted faults
  aimed at the invariant. Roblox's camera module is modelled on its real mouse logic (CameraUtils'
  override/restore, BaseCamera:UpdateMouseBehavior), because on main its restore is what re-locks a
  first-person rider. Run against main's CombatClient (d1e4f73) the walk fails 8 cases, third and first
  person; on this branch it fails none.

Nothing else. `VehicleWeaponClient.aimScreen` is unchanged.
