FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-22-1710-oliver-HIGH-PRIORITY-car-stability.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **make cars more stable and not bounce around**

Understood as: cars and bikes must stay planted flat out over roads, seams, bridge decks and grass,
and still land jumps and roll when flipped hard.

This reached me late (read 2026-09-25). By then a cloud session had landed the fix on main
(3f1d7b6, 09-23), and OLIVER_LIST marks #84/#109 "in tree, unproven". I'm not building a second fix.
I'm claiming the proof: reproducing that commit's before/after with its own sim, planting a fault of
my own, and checking by reading the code what the sim can't model (network ownership, above all).
Branch `task/prove-car-bounce`, report-only, no vehicle files edited. Details are in the status message
sent with this one.
