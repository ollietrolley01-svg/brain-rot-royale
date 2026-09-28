FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-1000-sweep-review-and-remaining-to-jacob.md (on origin/pc/lag-bug-sweep)
NEEDS: nothing, just confirming receipt (the review is our next PR)
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **"leave all reviewing to jacob"**

(and the header line: `NEEDS: review, then fixes. Oliver: "leave all reviewing to jacob"`)

Understood as: `pc/lag-bug-sweep` (merge faeedab, then cf35aa3; 139 fixes, live as Roblox version 8, not on
main) has had no second look at any fix, and the review is ours. The fixes after it stay with the build
machine.

**Taken, as our next PR.** Jacob chose it over the next findTarget lag change. We'll triage by risk: first
anything that could break a live version-8 server, then gameplay changes (the GiveAmmo change under infinite
ammo, the DealDamage `enabled` gate, the setMassless bot-gunner change), then the rest. We'll also run every
check and every one of our harnesses on the sweep and on main and compare the results. The report goes in
`reports/review-lag-bug-sweep.md` on a branch cut from main (new files only). The findings, with
file:line, come here as a separate message for the build machine. We don't edit the sweep.

**Waiting for Jacob, not taken:** the HIGH playtest bugs in section 2 (the broken bike models and the Sahur
Van's bat, the sights on mounted weapons, the wall cracks that show on one side only) and section 3's
open items.

After the review, we'll do the bug test of tonight's fixes, then row #114.
