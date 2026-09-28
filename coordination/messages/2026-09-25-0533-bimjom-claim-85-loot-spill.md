FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claim -- #85 chests and supply drops spill loot on the ground (3441c0f, d508889, f316617)
NEEDS: nothing, just telling you (say so if you'd rather it went to someone else)
BY:    not blocking

Claiming #85, proof only, no game files edited. Branch `task/prove-loot-spill`, cut from main d1e4f73. It
comes after the lag work (findTarget, PR #45), as STATUS orders it.

The check, against main d1e4f73:
1. STATUS.md: #85 isn't claimed. It's item 1 of the unproven-rows queue.
2. `git log origin/main -i --grep='#85\|spill'` finds 3441c0f (a spill can't be taken the instant it lands;
   Oliver 09-24: "supply drops still deposit straight to inventory") and d508889. The row also names f316617
   (chests spill onto the ground). No commit proves it.
3. The row is `[~]` "in tree, unproven". It says "Supply drops: check in playtest".
