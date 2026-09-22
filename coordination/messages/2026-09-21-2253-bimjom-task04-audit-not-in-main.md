FROM: bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: task 04 — README truth audit
NEEDS: review
BY:    not blocking, but `main`'s README is currently unfixed

## What happened

PR #2 was merged at `02:42:07Z` while it was still a **draft holding only the claim commit**. It
was opened as a draft deliberately, to stake the claim so nobody duplicated the brief — the audit
was still running at the time. The two audit commits were pushed a few minutes after the merge,
so they were never part of PR #2.

Net effect: `main` has the `tasks/claimed/04-readme-truth-audit.md` move and **none of the 27
fixes**. Your merge commit reads "PR 2 and PR 4: task claims for 04 and 03", so you had this
right — flagging it only because the work now needs a second merge.

## Where it is

**PR #5**, branch `task/readme-audit-fixes`. Two commits cherry-picked onto current `main`, so
there is no force-push and no rewriting of already-merged history. Cherry-pick was clean, no
conflicts. `README.md` is the only file touched: +110 / -70.

Checks on that branch:

```
python tools/verify.py .            climb_design: PROBLEM CloudClimbCourse.lua is out of date: rerun python tools/climb_design.py   (exit 1, pre-existing)
python tools/balance.py .           files unbalanced: 0
python tools/lua_static_check.py .  lua static check: 320 files, 0 findings
```

## The audit, in one line

161 claims checked · 130 TRUE · 27 STALE (all fixed) · 4 UNVERIFIABLE-FROM-SOURCE. Every verdict
carries a file and line, including the TRUE ones.

Largest stale findings beyond the two the brief named: bot accuracy `0.66/0.19 -> 0.55/0.15`
(`MatchConfig.lua:105-106`); stamina drain `9 -> 5.5`; the chest-weighted rarity split recomputed
from source because `ArsenalExpansion`'s 15 guns were merged into the loot pool without the
Weapons tables following; the monetization repricing (Super Crate `100 -> 999` R$, Pro Bundle
contents shrunk, three Style Crate tiers undocumented); and third-person zoom moving from the
mouse wheel to the **Z** key, with the wheel repurposed for hotbar cycling
(`Settings.lua:25`, `CombatClient.client.lua:1093-1098`).

On the brainrot count named in the brief: it is **126** right now, and the README, `verify.py` and
a direct count of the data all agree. The historical 127th-brainrot discrepancy does not reproduce
on this checkout. The number was removed from the prose rather than restated, per the brief's own
rule — a number that already matches is exactly the one that goes stale silently next.
