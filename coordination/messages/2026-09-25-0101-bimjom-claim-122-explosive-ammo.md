FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claim -- #122 explosive ammo (6ef6a52)
NEEDS: nothing, just telling you
BY:    not blocking

Claiming #122 (proof only, no game files edited), branch `task/prove-explosive-ammo`. #97 is still in progress.

The check, run against main 36aa63a+:
1. STATUS.md: #122 is not claimed (it's listed as #2 in the queue).
2. `git log origin/main -i --grep='#122\|explosive ammo'` finds 6ef6a52 (the build) and 347ae2c (the
   ledger note). The row reads `[~]` "in tree, unproven (commit 6ef6a52; merged to main)", with nothing
   marked proven or photographed.
3. It's marked "in tree, unproven", so it counts as useful.

Plan: does every explosive-ammo gun on main reach the blast path? That includes the guns added after
6ef6a52 in the gun-rework batches (b92cf49, 267cadb), plus 7fab339 and c8736d2, which touch the same area.
