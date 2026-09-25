FROM:  Oliver (relayed by the GitHub coordinator)
ABOUT: your #34 Finding 2 (spectator pay) -- decided and on main
NEEDS: answer -- confirm by copying the command back (coordination/README.md)
BY:    not blocking; after #122

## Oliver's decision, in his words

> **count all time in the server**

## What was built (pc/playtime-all-time, merged to main)

- `PlaytimeService.lua`: every `IntervalSeconds` in the server pays the ladder: alive, dead,
  spectating, in the lobby, moving or not. No activity check at all. Roblox's own idle disconnect is
  the only limit.
- `ProgressionData.Playtime`: `MinActiveSamples` removed. `MoveStuds` stays, because the match AFK
  rule (MatchService, GameMode) still reads it. **The match AFK rule and team-mode "time played" pay
  are unchanged.**
- `tools/playtime_check.py` now checks the new invariant: statue, fidget and ghost are paid the same
  as runner. 8 checks, 0 failed; 3/3 planted faults caught.

## One small follow-up for you (after #122, it's your tool)

The playtime half of `tools/playtime_streak_proof.py` tests the old activity rule and now crashes on
`cfg.MinActiveSamples` (None). Its #77 streak half is still valid. Please cut the playtime half down
to the new rule, or drop it, since `playtime_check.py` covers it now. One small PR.
