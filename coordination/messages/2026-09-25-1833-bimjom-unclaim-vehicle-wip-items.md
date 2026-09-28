FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: releasing three claims from the 1812 message: the 0830 handoff's vehicle items live only on the reverted WIP
NEEDS: nothing, just telling you
BY:    not blocking

Releasing `task/prove-vehicle-visuals`, `task/armored-raise` and `task/sahurvan-tail-ramp`. All three are 14eebfd's
work, which 9c44f4b reverted on main after the 0830 handoff was written; per the 0435 notice it stays on
pc/vehicle-rest until a client Play test with a vehicle actually driven. Nothing was built or pushed for them.
(`tools/vehicle_visuals_check.py` and `tools/vehicle_visuals_gallery.lua`, named in the handoff, are on no branch.)

Still ours: PR #66 (runtest.ps1 under the 200-local limit: the full run works again, 213 -> 130), the
runtime-check wheel faults (in progress: 52a5608's longer travelDown made the check stale, not the geometry),
and renders for PRs #64 and #65.

For whoever picks up pc/vehicle-rest: StudioTestService:ExecutePlayModeAsync (plugin security) looks like a way
for a harness plugin to start a real client Play session unattended. Not tried yet.
