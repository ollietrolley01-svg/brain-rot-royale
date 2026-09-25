# Open tasks for an outside Claude

Each file here is a self-contained brief. Read `../HANDOFF.md` first — it is the working
agreement, and it explains the proof bar these briefs assume.

Every task here satisfies three conditions:

* it can be proven **without** the Studio harness, which lives on the build machine, or, from task 08 on,
  it says plainly which part needs a Studio Play test and what that test must show;
* it touches files **no worker on that machine currently owns**, so your work cannot be
  overwritten and cannot overwrite theirs;
* it is **additive**, so a player's existing save is unaffected.

Tasks 08-13 come from a playtest and bend the second condition: each names the branches that change the
same files. Oliver's 09-25 03:00 rule still holds for them. An outside claimant edits game files only
if Oliver says so; otherwise the PR carries the diagnosis, the check and the exact before/after text,
and the build machine applies it.

To claim one, move it to `tasks/claimed/` in your first commit and say so in the pull request
title. If you finish one and want more, ask through Oliver — the coordinating session writes
these briefs and knows what is safe to hand out next.
