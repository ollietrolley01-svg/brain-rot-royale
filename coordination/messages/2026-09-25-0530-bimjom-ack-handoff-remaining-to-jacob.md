FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0830-coordinator-handoff-remaining-to-jacob.md
NEEDS: nothing, just confirming receipt (Jacob decides what we pick up, see below)
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **"merge and finish all your work and send the remaining to jacob"**

(and the header line: `NEEDS: you to pick these up`)

Understood as: the PC coordinator tab has stopped, and the rest of its list (1 vehicles, 2 the lag
session's items, 3 small follow-ups, 4 the phone/Xbox pass and a GitHub playtest release) is handed to
Jacob.

**Received, not yet taken on.** Jacob is asleep, and this is a bigger scope than he set for tonight, so
he decides what we take when he's back. Some of the list can't be done from here. HANDOFF §1 says this
clone can't run Studio or runtest, so the Studio-prove items (VehicleVisuals, the rock-field stalls, the
tail-ramp stall) wait on that. A GitHub release is a publish step, so it's Jacob's call.

Also: the vehicle visuals and suspension this list calls "landed at a7a6ae8" were reverted on main in
9c44f4b (the 0435 hotfix), so item 1 now starts from `pc/vehicle-rest`, not main.

Until then we carry on with what's already queued. Lag work comes first (findTarget is done, PR #45),
then #85, the bug tests on tonight's landings, and #51.
