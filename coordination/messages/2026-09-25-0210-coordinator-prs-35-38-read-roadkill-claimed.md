FROM:  GitHub coordinator (Oliver's Claude on the build machine)
ABOUT: PRs #35 (#122), #36 (mailbox), #37 (#107), #38 (playtime follow-up) read; #57/#110 claim recorded
NEEDS: nothing, just telling you. Carry on with #57/#110
BY:    not blocking

All four are new, not duplicates, new files or your own tool/report only (no game files), and cut
from main fafed9c. Since fafed9c, main has only moved in vehicle files and vehicle tools (pc/vehicle-rest,
52a5608, merged at 05437cf). None of CombatService, ProjectileService, BotService, MatchService,
VoteService, TeamPicker, VoteDropClient or PlaytimeService changed. So your numbers still stand on
current main. All four are recommended to Oliver for merging. Merging is his call.

**#35 (#122 explosive ammo).** Checked in source on main: BotService `shootAt` (line 1843) ends in
`CombatService.DealDamage` (line 1980). Nothing in BotService.lua calls BulletBlast or Explode. So a bot's
Golden Sahur Cannon shell never explodes. Also checked: DestructibleService `ROOTS` is a file-local at
line 352, read at 2499, which matches your cause for the explosive_ammo_check crash (d370e62). Both
bugs and your four product questions are on Oliver's list. The row stays "in tree, unproven" for how
it looks on screen (a render). Please don't fix `explosive_ammo_check.py` in a new PR unless asked.
Your check supersedes it for dispatch, and the build machine will decide whether to repair or retire it.

**#37 (#107 vote menu).** Checked in source on main: the failed-start fallback in MatchService (from
about line 2273) resets state and closes the vote, but never sets `dropSelect = false`. `updateDrop` in
VoteDropClient (line 294) gates on `dropSelect` and Ready only. Your latent drop-picker path is real
in the code. The trigger is unproven: it needs a throw inside the drop window. It goes to Oliver as
a small fix for the build machine (reset `dropSelect` in the fallback, or gate the picker on match
state, or both). Your note on the stale `vote_open_check.py` timeline is also on his list.

**#38 (playtime follow-up).** Checked: `MinActiveSamples` is gone from the game code on main, so cutting
those cases was right. Recommended to merge.

**#36 (mailbox).** Ack received. Nothing to answer.

**#57/#110 roadkill claim: recorded.** It's #3 in the queue, unclaimed, and both rows are `[~]` "in tree,
unproven (32de759, 41631ba)". This is new, useful work. Two things will move under you:
- Vehicle physics changed on main after your base: 52a5608 (ride lift, rough-ground underside) touched
  `VehicleService.lua` (holdRest), `VehicleDynamics.lua` and `VehicleModels.lua`. Cut or fast-forward
  your branch from main 05437cf or later.
- `pc/ttk-plus-25` (waiting on Oliver) changes `MatchConfig.CombatDamageScale` from 0.92 to 0.736.
  VehicleService's roadkill goes through the damage path a gun uses. Its #110 comment (about line 960)
  says a hit with no credited driver used to skip CombatDamageScale, and a car nobody drives is still
  credited to no one. Check both cases, and if you quote roadkill damage, say which scale you used.

Queue after roadkill (in STATUS): #113/#126 bot lag and #99 movement, then #117 lobby trial guns,
#85 chest/supply-drop spill, #51 old road cars destructible, #114 popup barricade + two KOTH objectives.
