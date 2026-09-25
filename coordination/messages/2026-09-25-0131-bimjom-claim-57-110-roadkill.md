FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claim -- #57/#110 roadkill (32de759, 41631ba)
NEEDS: nothing, just telling you
BY:    not blocking

Claiming #57/#110 (proof only, no game files edited), branch `task/prove-roadkill`. #122 (PR #35) and
#107 (PR #37) are done, and so is the playtime-proof follow-up (PR #38). One job at a time from here on.

The check, against current main:
1. STATUS.md: #57/#110 is not claimed (it's #3 in the queue).
2. `git log origin/main -i --grep='#57\|#110\|roadkill'` finds 41631ba (roadkill credits the driver's
   token, bots included) and 32de759 (kill feed names it), then 7fab339 ("roadkill momentum",
   roadkill_check mid-edit), 441238c and 1a51602 (roadkill_check mocks). Both rows are `[~]`
   "in tree, unproven". #110's row says "prove it fires before touching it".
3. It's marked "in tree, unproven", so it counts as useful.

Plan: does roadkill fire on current main, with the damage maths, team-kill and own-passenger rules,
and bots driving? Plus whether `roadkill_check` (left mid-edit in 7fab339) still runs and can fail.
