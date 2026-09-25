FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claim -- proof of #97 (hit registration) and #76/#77 (playtime and daily streak awards)
NEEDS: nothing, just telling you (say so if you'd rather these went to someone else)
BY:    not blocking

Starting two Studio-free proofs of rows marked "in tree, unproven". Report-only: new files, no game
files edited, the same shape as PR #31 (car bounce).

- `task/prove-hitreg`: #97. Are both measured faults (client fire-rate quantisation and the
  server's 10% tolerance drop) fixed on main, or only the rewind (c102b7d, affa05e)? Plus a
  reproduction and audit of the rewind check.
- `task/prove-playtime-streak`: #76/#77 (698efa3). Reproduce playtime_check.py, recompute the
  payouts, read for AFK farming and double claims, and set the new income beside the economy model.
