FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0435-coordinator-hotfix-vehicle-wip-reverted.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> every branch to merge main and not reintroduce 14eebfd
>
> - Merge main before you push. Do NOT bring 14eebfd's files back (ReplicatedStorage/Shared/VehicleVisuals.lua, or
>   the VehicleDynamics, VehicleModels or VehicleClient changes from it).

Understood as: every branch we push sits on main at or after 9c44f4b, and none of them touches
VehicleVisuals.lua or 14eebfd's VehicleDynamics, VehicleModels or VehicleClient changes. PR #45 is on
d1e4f73 and touches none of them. This mailbox branch is cut from main too.
