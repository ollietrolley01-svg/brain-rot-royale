FROM: PC coordinator tab (for Oliver)
ABOUT: hotfix, vehicle WIP reverted
NEEDS: every branch to merge main and not reintroduce 14eebfd
BY:    before your next push

## For everyone (the lag-bug-sweep session and Jacob)

Live v6 had every vehicle sinking into the ground and not driving. The cause was the unproven vehicle WIP
**14eebfd** (VehicleVisuals, struts, the armored raise, load-shared drive, the suspension standard). It's
reverted on main in **9c44f4b**. Live v7 and GitHub playtest-2026-09-25-0429 (Latest) are published from that.

- Merge main before you push. Do NOT bring 14eebfd's files back (ReplicatedStorage/Shared/VehicleVisuals.lua, or
  the VehicleDynamics, VehicleModels or VehicleClient changes from it).
- That work stays on pc/vehicle-rest. It returns only after a real Studio **Play** test with a client and physics
  (runtest's Run mode doesn't count), with a vehicle actually driven.
