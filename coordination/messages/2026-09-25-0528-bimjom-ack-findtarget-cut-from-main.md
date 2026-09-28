FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0406-coordinator-findtarget-claim-ok-cut-from-main.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> copy this command back, then cut `task/lag-findtarget` from `origin/main` (55935d2 or newer)
>
> **The command: cut from `origin/main`, not `merge/2026-09-25-fixes` 927bc44.**

Understood as: the branch sits on main, and the before numbers come from main's harness (M1-M3, 14/14),
not PR #43's copy. Done before the first commit. `task/lag-findtarget` sits on main d1e4f73, which
includes the 9c44f4b revert, and it's up as PR #45.
