# task/playtest-briefs

Cut from `origin/main` at d1e4f73 ("Mailbox: hotfix notice, vehicle WIP 14eebfd reverted (9c44f4b);
don't reintroduce"). No game file or tool changes. Markdown only.

Adds six open task briefs (08-13) from Oliver's 2026-09-25 playtest feedback:

- `tasks/08-vehicle-gun-aim-third-person.md`: the vehicle gun ignores the mouse in third person and
  the cursor stays locked in the middle.
- `tasks/09-cant-un-ready-in-the-lobby.md`: un-ready doesn't stick.
- `tasks/10-arms-on-long-guns.md`: the elbow looks wrong on longer guns.
- `tasks/11-car-health-700-800.md`: cars at 700-800 health (Jacob's revised target), and the questions
  for Oliver first.
- `tasks/12-minimap-towns.md`: draw the towns better on the minimap.
- `tasks/13-bots-drive-into-props.md`: bot drivers hit props and get stuck.

Changes `tasks/README.md` so its conditions stay true for these briefs. Tasks 08-13 may name a Studio
Play test they need, and they may share files with named `pc/*` branches. The README also restates
the 03:00 game-file rule for outside claimants.

Adds three briefs straight into `tasks/claimed/`, because Jacob started each fix before its brief
was written:

- `tasks/claimed/14-gunner-aim-holds-in-world.md` (`task/gunner-aim-world`): the gunner's aim should
  stay put in the world when the car turns.
- `tasks/claimed/15-gunner-range-of-motion.md` (`task/gunner-range`): the gunner's guns need more
  pitch range.
- `tasks/claimed/16-gunner-gun-blocks-view.md` (`task/gunner-view-clear`): the gun blocks the hip
  view.

Adds five more open briefs (17-21) from feedback Jacob relayed:

- `tasks/17-sniper-rounds-with-travel-time.md`: sniper shots become real rounds with travel time and
  drop, using the existing non-explosive round path.
- `tasks/18-longer-team-matches.md`: team modes last longer; current targets and clocks listed.
- `tasks/19-lobby-clutter-and-gates.md`: the lobby v2 road and gates are cluttered and block a booth.
- `tasks/20-bot-gunners-engage-better.md`: bots in gunner seats fight better.
- `tasks/21-bots-dont-target-cars.md`: bots never target a car, and rarely see its riders.

Adds nine more open briefs (22-30) from Oliver, relayed by Jacob:

- `tasks/22-no-shooting-on-bikes.md`: no firing from any seat on a bike.
- `tasks/23-bots-drive-across-bridges.md`: bot drivers get across bridges.
- `tasks/24-mythic-crate-chance-on-a-win.md`: a win has a chance of a Mythic Crate, with the odds shown.
- `tasks/25-improve-the-launch-pad.md`: the Launch Pad launches you at once.
- `tasks/26-team-bots-spawn-with-a-kit.md`: team-mode bots spawn with a fixed-shape kit and skip base
  looting.
- `tasks/27-declutter-team-bases-and-battleground.md`: fewer parts in the battleground, then the bases.
- `tasks/28-loading-screen-for-new-maps.md`: a loading screen while a map builds and streams in.
- `tasks/29-fewer-armed-cars-in-battle-royale.md`: armed cars from 81% to 25% of battle royale cars.
- `tasks/30-roadkill-never-one-shots.md`: one pass never kills a full-health, full-shield player.

Every brief from 08 on now ends with a `Status:` line. Briefs that used to wait on a question now give
a default to work to, and say what to ask in the PR.
