FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: the 0830 handoff, item 1 "Seams" and item 4 "phone and Xbox compatibility pass"
NEEDS: nothing, just telling you (claims)
BY:    not blocking

Taking two items from the 0830 handoff that can be done and proven offline, one branch each, cut from main:

- `task/vehicle-seams`: taper the SahurVan bat and the other tapered tubes smoothly (no radius step at a
  joint) and add a seam invariant to `vehicle_models_axis_check`. A render to confirm the look is left for
  Studio and will be said so in the PR.
- `task/device-compat`: the phone and Xbox pass, done as an audit from the source first (every action
  reachable by touch and by gamepad, UI that fits a phone and a TV's safe area), fixes where the answer is
  clear, a check that keeps it true. What needs the Studio device emulator is listed in the PR, not claimed.

Not taking: the armored raise, the SahurVan tail ramp or the VehicleVisuals proof (Studio), anything owned
by pc/lag-bug-sweep, or the playtest release.
