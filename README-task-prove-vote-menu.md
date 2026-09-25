# Branch `task/prove-vote-menu`

Jacob's proof of OLIVER_LIST #107 ("the game-choosing menu pulls up randomly mid-match"). It was cut
from origin/main ac22e5e and fast-forwarded to fafed9c before the final run. No game file and no
existing tool is changed.

What it adds:

- `reports/vote-menu-proof.md`: every path that can open the vote screen, its reveal, the drop picker
  or the team picker, which state guards each one, the race analysis, the results, and what it does
  not prove.
- `tools/vote_menu_proof.py`: runs the real VoteService, TeamPicker, MatchService pieces (startMatch,
  the 1 s loop, broadcast, SetReady, LeaveSpectate), the Bootstrap join re-broadcast, VoteDropClient
  and TeamPickerClient under lupa. It checks the in-match invariants in order, with cross-channel
  swaps, late joins, a hostile replay and a throw sweep, and carries 9 planted faults.
  Run `python3 tools/vote_menu_proof.py .` (it needs lupa).

Result: no remaining path puts the vote or the team picker over a match on main. There is one latent
drop-picker path (`dropSelect` isn't reset after a failed start in the drop window), and I found no way
to trigger it in normal play.
