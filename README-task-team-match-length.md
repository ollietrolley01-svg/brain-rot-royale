# task/team-match-length

Task 18 ("team game modes should last longer", brief in PR #68). Cut from `origin/main` at d1e4f73.

## What changed from d1e4f73

| File | Change |
|---|---|
| `ReplicatedStorage/Shared/GameModes.lua` | TDM: target 100 -> 150, clock 480 -> 720 s. Objective Capture: target 250 -> 400, clock 480 -> 720 s. One side holding both objectives now needs 200 s instead of 125 s |
| `ReplicatedStorage/Shared/MatchConfig.lua` | `TeamModeRewards.matchSeconds = 720` (new), plus result pay and every per-match cap scaled by 720/480: win 1300/345 -> 1950/518, draw 600/270 -> 900/405, loss 250/230 -> 375/345, kill cap 30 -> 45, maxPaidKills 40 -> 60, assist cap 20 -> 30, revenge 5 -> 8, streak cap 600 -> 900, capture 8 -> 12, hold capSeconds 240 -> 360, defend 10 -> 15. Comments that said 8 minutes now say 12 |
| `StarterPlayerScripts/ModeScoreHud.client.lua` | Two header comments no longer name 100 and 250 (comments only) |
| `tools/economy_model.py` | The team profiles' per-match counts scale by timeLimit/480. A new check fails if a team clock and `matchSeconds` disagree, with a planted fault |
| `tools/team_rewards_check.py` | Stubs use 720 s, the hold scenario runs past whatever the hold cap is, and the full-match ceiling uses `matchSeconds` |
| `tools/team_match_length_check.py` | New offline check: target, clock and fastest end before and after, plus invariants SIZED, STEAMROLL, REACHABLE, EARLY and STALE. `--plant` runs 8 planted faults, `--log` reads a probe log |
| `tools/team_match_length_probe.lua` | New Studio probe: one bots-only TDM and one Objective Capture played out by the real server scripts, logging the score every 30 s and how each match ended |
| `README.md`, `ECONOMY.md` | The lengths, targets and team-mode pay ratios updated |

Nothing else in the game changes. Respawn delays, restocks, supply drops and vehicle respawns run on fixed timers that don't depend on the match length.
