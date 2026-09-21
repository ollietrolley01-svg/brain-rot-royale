# Open tasks for an outside Claude

Each file here is a self-contained brief. Read `../HANDOFF.md` first — it is the working
agreement, and it explains the proof bar these briefs assume.

Every task here satisfies three conditions:

* it can be proven **without** the Studio harness, which lives on the build machine;
* it touches files **no worker on that machine currently owns**, so your work cannot be
  overwritten and cannot overwrite theirs;
* it is **additive**, so a player's existing save is unaffected.

To claim one, move it to `tasks/claimed/` in your first commit and say so in the pull request
title. If you finish one and want more, ask through Oliver — the coordinating session writes
these briefs and knows what is safe to hand out next.
