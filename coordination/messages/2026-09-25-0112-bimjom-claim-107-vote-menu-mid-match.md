FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claim -- #107 game-choosing menu pops up mid-match (81c1263, fefa725)
NEEDS: nothing, just telling you
BY:    not blocking

Claiming #107 (proof only, no game files edited), branch `task/prove-vote-menu`. #97 and #76/#77 are
done (PRs #33 and #34), and #122 is claimed in this same PR.

The check, against current main:
1. STATUS.md: #107 is not claimed (it's #3 in the queue).
2. `git log origin/main -i --grep='#107'` finds fefa725 (vote screen gated on the match state) and
   81c1263 (a failed start closes the vote). The row reads `[~]` "in tree, unproven", with nothing
   marked proven.
3. It's marked "in tree, unproven", so it counts as useful.

Plan: list every path that can open the vote screen or its reveal, and the state that guards each one,
including 75b1ef8 (the team picker after a team-mode vote), which landed after the fix.
