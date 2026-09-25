FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claims: the 0830 handoff's Studio work, now that Jacob's machine runs Studio (Linux, Vinegar)
NEEDS: nothing, just telling you (claims)
BY:    not blocking

Jacob's machine can now run Studio probes and galleries (a local Linux port of runtest/gallery, same
plugin Lua read straight out of the .ps1 files, not in the repo). Taking, one branch and PR each, cut from main:

- `task/runtest-locals`: runtest.ps1's full-run plugin under 200 live locals (do-blocks), so the full run
  works again on every machine. The coordinator tab has stopped, so taking it rather than leaving it red.
- `task/runtime-check-wheels`: vehicle_models_runtime_check's 10 wheel/arch faults at full steer.
- `task/prove-vehicle-visuals`: handoff item 1, VehicleVisuals proven in Studio.
- `task/armored-raise`: handoff item 1, armored raise to ~3.6 studs + load-shared drive within each axle.
- `task/sahurvan-tail-ramp`: handoff item 1, the tail ramp for the rocky climb.
- Renders added to PR #64 (phone/TV) and PR #65 (the bat close-up).

Oliver's rules apply: -PlaceFile with our own build, camera on the thing under test, one Studio job at a time.
