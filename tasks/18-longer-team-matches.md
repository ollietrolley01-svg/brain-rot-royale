# Task 18: team game modes should last longer

**Files you own for this task:** `ReplicatedStorage/Shared/GameModes.lua`, the `scoreTarget` and
`timeLimit` fields of `TeamDeathmatch` and `KingOfTheHill` only. **Read only:** `GameMode.lua`,
`ModeKingOfTheHill.lua`, `ModeTeams.lua`, `TeamBattleground.lua`, `MatchConfig.lua`, the reward code.

## What was reported

Team matches end too soon. Jacob relayed this from a 2026-09-25 playtest.

## What the limits are now

Both team modes are in `GameModes.lua`. A match ends at the score target or the time limit, whichever
comes first (`GameMode.lua` line 167 for the score, line 696 for the deadline):

| Mode | Shown as | scoreTarget | timeLimit | Fastest possible end |
|---|---|---|---|---|
| `TeamDeathmatch` (line 205) | TDM | 100 team kills (line 222) | 480 s (8 min) | when one side reaches 100 kills |
| `KingOfTheHill` (line 229) | Objective Capture | 250 "seconds held" (line 247) | 480 s | 125 s: each held objective scores a point a second, and there are two |

Objective Capture can end in about two minutes if one team holds both objectives. TDM's real length
depends on the kill rate. Measure it before proposing a number. The +25% time-to-kill change
(`CombatDamageScale` 0.736, 09-25) already slowed kills.

`tools/verify.py` refuses a mode description with a hard-coded number that disagrees with its
`scoreTarget` (GameModes line 273), so the text updates itself.

## Ask Oliver

"Longer" could mean a higher target, a longer clock, or both. Send him the table above with a
measured TDM length and two or three options. Longer matches also change coins per hour, streak and
playtime pay (Task 07's economy model, `tools/economy_model.py`, and `tools/team_rewards_check.py`),
so say what each option does to those.

## Default

Both team modes' clocks from 480 to 720 s; TDM's target from 100 to 150 kills; Objective Capture's target from 250 to 400, so one team holding both objectives needs 200 s instead of 125. Adjust from the measured TDM kill rate and the economy model, and say what moved.

## Conflicts

`pc/lag-bug-sweep` and `pc/teambase-v2` both change `GameModes.lua` (a new block near
`GameModes.TeamName`, line 67, and the events list near line 173), plus `GameMode.lua` and
`ModeTeams.lua`. Neither changes `scoreTarget` or `timeLimit`. Merge main and check again before
pushing.

## Proof

Offline: a script that reads the real `GameModes.lua` and reports each team mode's target, clock and
fastest possible end, before and after. For TDM, add a kill-rate estimate from the bot-lag or
team-battleground harness logs if one exists, and say where the number came from. Plant a fault (a
target the clock can never reach at the measured rate) and show it goes red. Run `verify.py` for the
description check. Whether the new length feels right is Oliver's call after a playtest.

Status: ready to start
