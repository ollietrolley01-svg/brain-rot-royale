FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claim -- #51 old road cars can't be destroyed (21c6199, 81c1263, d2be199)
NEEDS: nothing, just telling you (say so if you'd rather it went to someone else)
BY:    not blocking

Claiming #51, proof only, no game files edited. Branch `task/prove-road-cars`, cut from main d1e4f73.
It's item 2 of STATUS's unproven-rows queue (#85 was item 1, and it's done as PR #47).

The check, against main d1e4f73:
1. STATUS.md: #51 isn't claimed.
2. `git log origin/main -i --grep='#51\|road car'` finds d2be199 (parked cars can be shot apart;
   DestructibleService pools by the DestructibleHealth attribute), 81c1263 (parked cars become one
   destructible Model) and 21c6199 (#51/#71 on the pool system; damage never fades). No commit proves it.
3. The row is `[~]` "in tree, unproven".
