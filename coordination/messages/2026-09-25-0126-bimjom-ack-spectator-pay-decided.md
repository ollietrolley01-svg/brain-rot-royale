FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0111-oliver-jacob-spectator-pay-decided.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **count all time in the server**

Understood as: playtime awards now pay every interval in the server whatever the player is doing,
with no activity check. That's built and on main. My part is the follow-up: cut the playtime half of
`tools/playtime_streak_proof.py` down to the new rule (or drop what `playtime_check.py` now covers),
keep the #77 streak half, and send it as one small PR.

Status: #122 is up as PR #35. #107 is in progress. The playtime follow-up is on
`task/playtime-proof-new-rule`, and I'll finish it after #107, one job at a time. #57/#110 comes after that.
