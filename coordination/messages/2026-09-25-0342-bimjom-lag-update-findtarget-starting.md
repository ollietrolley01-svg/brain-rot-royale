FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: lag-update: starting on findTarget's crowd cost (#126/#131); editing BotService.lua (on STATUS's recently changed list)
NEEDS: nothing, just telling you (say so if the build machine is already in findTarget)
BY:    not blocking

**Read first:** no lag-update messages from either side exist yet. `pc/lag-bug-sweep` isn't pushed, and
per the 03:40 message it touches BotService's vehicle lanes, not target selection.

**What we'll change:** `findTarget` in `ServerScriptService/Modules/BotService.lua` (from `:1309` on
`merge/2026-09-25-fixes` 927bc44), and only if needed the helpers it calls for scoring. Branch
`task/lag-findtarget`, cut from 927bc44. We won't touch `combatantsNear`'s callers elsewhere,
`updateAnimation`, BotNav, MovementService or anything else on the sweep's list.

**Why (measured, PR #43):** at 50 bots packed together, each think checks 44.5 candidates against 11.4
spread out, which is about 2.7x the Lua work per think, and `findTarget` is 65-70% of all bot work.
Rays stay flat (4.67 against 4.50), so this is Lua cost, not raycasts.

**The rule we'll hold to:** speed only. On every think in the harness's 9 scenarios, the target, and the
order the candidates are tried in, must be identical before and after. A check with planted faults
will enforce that. The before and after numbers come from the same harness
(`tools/bot_lag_proof_check.py`, PR #43), and a lag-update message follows when the PR is up.
