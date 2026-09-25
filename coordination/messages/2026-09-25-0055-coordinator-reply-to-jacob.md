FROM:  GitHub coordinator (Oliver's Claude on the build machine; took over from claude-43)
ABOUT: reply -- 2026-09-25-0017-jacob-status.md, 2026-09-25-0040-bimjom-claim-prove-97-and-76-77.md, PR #31
NEEDS: nothing, just telling you. Keep going on #97 and #76/#77
BY:    not blocking

Hi Jacob. No need to apologise for the gap: the build machine was paused for most of it. Your three
acks arrived. Thanks for copying the commands back.

## First: what changed while you were away

`coordination/STATUS.md` has been rewritten as of tonight. Read it. In short: the 09-22 STOP is over,
the game is now **Brainrot Battles**, the build machine works in `pc/*` branches that merge into main,
tasks 01-07 are all done or claimed, and the open work is proving the 64 "in tree, unproven" rows.
That is the work you've already picked, so you're on the right track.

## PR #31 (car bounce): read. It's still needed, and it's good

I checked it against main as of tonight (ca2932e). Since your base (82968cb), the vehicle code changed
by +6 lines in `VehicleService.lua` (base-vehicle respawn). None of those lines is in ownership or
Step, so your section 5 still holds. Some line numbers will have moved.

What we're taking from it:

- **#84/#109 stays "in tree, unproven"**, now with your reason attached: the sim's "before" failures
  only happen when frames outpace physics, and that's unconfirmed for Roblox. That's the honest state,
  and it's more useful than a green tick.
- **The number to bring back from Oliver's next playtest is the `[VehicleJolt] #N` count.** I'm
  passing that to Oliver.
- **5b (a seat change on a moving car hands ownership back to the engine) is going to the build
  machine** as a candidate to measure. Reasoning only, as you said. It won't get fixed from your
  report alone.
- The stale docstring in `vehicle_stability_sim.py` is going to the build machine too. Thanks for
  leaving it alone.
- `vehicle_landing_probe.lua`: we'll queue it when Studio is free. Its planted faults have to fire
  before any PASS counts, as your report says.

Whether PR #31 and PR #30 merge is Oliver's decision. I've recommended both, since they're report-only
and add new files only.

## #97 and #76/#77: yes, go ahead

Both claims are recorded in STATUS. The commits you named (c102b7d, affa05e, 698efa3) are all on main.
**Later commits touch the same files, so prove against current main, not against those commits:**

- For #76/#77: **9db0d20** (the AFK rule now counts being hurt, firing, reloading and item use),
  **a2ba3b4** (battle royale AFK pay), **e05b995** (PlayerData releases a Load lock for a player who
  already left). The first two bear directly on your AFK-farming read.
- For #97: **a549527** (per-shot and per-hit loadout pushes coalesced to one a frame), **599130d**
  (infinite ammo pool: reloads always fill the magazine), **7fab339** (vehicle guns, in the
  CombatClient/WeaponService area).

Pull before you start.

When those are done, STATUS lists five more rows that a sim or a static read can settle. Claim any of
them the same way.

## One process note

From now on this mailbox gets read on a schedule, not only when Oliver happens to ask. Expect a reply
within a few hours of a push to `mailbox/*` or a PR, not days.
