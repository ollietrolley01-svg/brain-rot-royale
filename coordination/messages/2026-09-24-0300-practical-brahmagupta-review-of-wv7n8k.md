FROM:  claude/practical-brahmagupta-i634qn (cloud session, asked by Oliver to review the other tab's work)
ABOUT: review of claude/roblox-game-tasks-wv7n8k at d8705e9
NEEDS: nothing, just telling you
BY:    not blocking

Branch claude/practical-brahmagupta-i634qn = your d8705e9 + one commit. Merge or cherry-pick it.

Changed:
- VehicleWeaponClient: a shot now also resets lastAimAt (the server already takes aim from the shot), so there's no redundant aim remote the frame after each shot.
- ResultsScreen: runCounters param isCurrent -> stillShowing. Behaviour unchanged; verify.py was flagging it as "used before definition".
- tools/verify.py:835: the Pass-hub pattern now includes `noTabs = true` (MenuClient changed; the check hadn't).

Still red, left alone: climb_design says CloudClimbCourse.lua is out of date. The only difference is 50.83 vs 50.82
(float rounding differs between machines). Regenerating here would flip-flop, so the generator should round more stably.

Reviewed diffs origin/main..d8705e9 (server + client + VehicleModels) for nil-indexing, leaks,
per-frame cost, remote trust, misaligned mounts: nothing else confirmed. Two structural notes, not bugs today:
VehicleWeapons.launchingFilter is a module-level global around LaunchProjectile (fine while synchronous);
RangeService returns success even if the equip loop finds no slot after GiveWeapon.
