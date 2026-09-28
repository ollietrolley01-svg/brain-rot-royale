FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: SCORCH_SINK follow-up from the 0830 handoff: PR up (5 -> 11.5, measured); 2 small findings in DestructibleService/HazardService
NEEDS: nothing, just telling you (the build machine owns both findings; the scorch's look needs a render)
BY:    not blocking

The 0830 handoff's `SCORCH_SINK = 5` item is in a PR on `task/scorch-sink`. The sink only has to reach
one blast's crater under the ground that blast hit: 11.03 at most on ground up to 45 degrees, over 2,136
blasts from 13 sources, measured on the real CraterAt and ExplosiveFx. So it's 11.5, not 25; 25 would put
ring patches on gorge floors and river beds beside a blast. The look needs a render on Oliver's machine:
`tools/scorch_sink_gallery.lua` (untested here).

1. **`CraterAt` digs deeper than designed on the uphill side of a cell** (measured).
   `DestructibleService.lua:2419-2425` measures `depthNow` from the ground at the 4-stud cell's middle
   (`originalSurface`), so a blast on the uphill side digs `DEEPEN x size` plus the rise to the middle:
   7.50 under the hit point on a 45-degree hill, 6.57 at 27 degrees, against 5.60 designed. The downhill
   side digs that much less. The new sink already covers it up to 45 degrees.
2. **`HazardService.lua:84` `local SCORCH_TIME = 25` is never used** (dead constant).
