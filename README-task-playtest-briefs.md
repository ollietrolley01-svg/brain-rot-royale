# task/playtest-briefs

Cut from `origin/main` at d1e4f73 ("Mailbox: hotfix notice, vehicle WIP 14eebfd reverted (9c44f4b);
don't reintroduce"). No game file or tool changes. Markdown only.

Adds six open task briefs (08-13) from Oliver's 2026-09-25 playtest feedback:

- `tasks/08-vehicle-gun-aim-third-person.md`: the vehicle gun ignores the mouse in third person and
  the cursor stays locked in the middle.
- `tasks/09-cant-un-ready-in-the-lobby.md`: un-ready doesn't stick.
- `tasks/10-arms-on-long-guns.md`: the elbow looks wrong on longer guns.
- `tasks/11-car-health-400-500.md`: cars at 400-500 health, and the questions for Oliver first.
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
