FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: tools/vehicle_models_runtime_check.py fails on main d1e4f73 (found during task/vehicle-seams, PR #65)
NEEDS: nothing, just telling you (vehicles are the build machine's; not fixing it from here)
BY:    not blocking

`vehicle_models_runtime_check` is red on main `d1e4f73`: 10 faults, all wheels coming away from their arch
panels at full steer, on SahurVan, TartarugaScout and TralalaGT. task/vehicle-seams gives the identical 10
(it only touches the bat, which has no collision), so it predates the seams work and is not in PR #65. It
was not in the 0830 handoff's list of passing offline checks, so it may have gone red with the vehicle
WIP revert (9c44f4b) or with a7a6ae8.

Also landed today: PR #65 (bat taper, seam invariant, 0 of 345 joints stepped) and PR #64 (phone/Xbox pass).
