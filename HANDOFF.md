# Working on Brain Rot Royale from another machine

This file is for a Claude working on a **clone** of this repo, on someone else's computer,
on behalf of a friend of the owner (Oliver). Read it before you touch anything.

There is a coordinating Claude session on Oliver's machine. It owns the build, arbitrates
who edits what, and is the only thing that puts work in front of Oliver. **You do not make
product decisions and you do not get to decide when something is finished** — you do the work,
you prove it, and you send it back as a pull request with the evidence attached.

---

## 1. What you cannot do from there, and why it shapes everything

**You cannot run the test harness.** `tools/runtest.ps1` and `tools/gallery.ps1` drive Roblox
Studio on Oliver's machine, one job at a time, behind a machine-wide lock. That lock is the
bottleneck for the whole project. You have no access to it.

So: **take work that can be proven without Studio.** The most effective work done on this
project has been exactly that — a fault list computed from the source, a layout overflow
predicted to the pixel and confirmed later, a whole-project sweep for a bug pattern. None of
it needed the lock.

If your task genuinely needs a render or a live probe, write the probe or the gallery view,
say so in the PR, and the coordinator will queue it on Oliver's machine and send the result back.

**You also cannot:** publish the game (never run `tools/publish.ps1`), change anyone's Roblox
or system settings, or build the place into the repo (`BrainRotRoyale.rbxlx` is generated and
git-ignored — `python build_place.py .` makes it locally).

## 2. The three checks. Always.

From the repo root, before any commit and again before the PR:

```
python tools/verify.py .            ->  OK: no problems
python tools/balance.py .           ->  files unbalanced: 0
python tools/lua_static_check.py .  ->  lua static check: N files, 0 findings
```

Paste the lines into the PR **verbatim, as they printed**. Never paraphrase them, never
summarise them as "checks pass". If one is red, the work is not ready.

## 3. The proof bar — this is the part that matters

This project has repeatedly shipped fixes that passed their own tests and did nothing. The
rules below were each paid for. They are not ceremony.

- **Measure the outcome, not the branch.** "The function ran" is not evidence. "The thing
  that was wrong is now right, and here is the number" is.
- **Every check carries a permanent planted fault** — break the thing deliberately and confirm
  the check fails. A check that has never failed has never been shown to work.
- **Aim the planted fault at an invariant, not at the bug.** A fault that says "the broken
  thing is still broken" expires the moment you fix it, and then the check quietly proves
  nothing. Aim it at something the code must refuse forever.
- **Say how many candidates you examined**, not just how many you flagged. A filter that
  matched nothing reports a clean sweep.
- **A number is not a picture.** Several fixes here passed every number they had and were
  visibly wrong — chimneys lying on the grass, a gun invisible under its own glowing pad.
  If a human would judge it by looking, it needs a render, and the render is the coordinator's
  to run.
- **State which tree a thing is in.** "Fixed via `Settings.WasSet`" cost this project real time
  when that function existed only in one worker's private copy. Say "landed" or "in my branch".

`COORDINATION.md` holds the full list of lessons, including the Roblox-specific ones
(`os.clock` is not wall time; weak-keyed tables drop live instances; a cylinder's length is
its X axis; a probe cannot synthesise input or run a LocalScript). Read it — most of it was
learned the expensive way.

## 4. How to take a task

1. Look in `tasks/`. Each file is a self-contained brief. Take one that is unclaimed.
2. Say so in the PR title and rename the file to `tasks/claimed/…` in your first commit, so
   two people cannot take the same one.
3. Work on a branch: `git checkout -b task/<short-name>`.
4. **Stay inside the files your brief names.** Thirteen workers are editing this repo on
   Oliver's machine right now. Editing a file outside your brief is how work gets lost — if you
   need a change elsewhere, write the exact before/after text in the PR and the coordinator
   routes it.
5. Additive only on anything that touches saved player data. A player who owns nothing new must
   be unaffected.
6. Original designs only. No lifting a known meme character's likeness or name.

## 5. What the pull request must contain

- What you changed and **why**, in plain English.
- The three check lines, verbatim.
- Your evidence: the measurement, the counts, the planted fault firing.
- **What you did NOT prove**, stated plainly. This is the most valued thing in this project.
  "The wiring is proven; whether it feels right is Oliver's to judge" is a good sentence.
- Anything you found that is outside your brief — a bug, a stale number, a dead code path.
  Report it; do not fix it.

Questions and decisions go back through Oliver to the coordinating session. Do not guess at a
product decision to avoid asking — a wrong guess costs more than a question.

## 6. Two rules from Oliver, for everyone working on this game

Oliver owns Brain Rot Royale. He set these for the workers on the build machine and then said they
apply to contributors here too. His own words on why: **the rules are "just being there to keep
things from breaking."** They are not there to slow you down or to doubt your work.

### Rule 10 — if you are running out, land nothing

**If you are low on context, near a usage limit, or otherwise might stop part way, do not push a
half-finished change.** Not a one-line fix, not a comment, not a tidy-up.

The reason is the same here as on the build machine. A change is not one write: it is the edit, the
three checks, a re-read to confirm it took, and the write-up. Work that stops in the middle of that
leaves something nobody has read, and on this project the recovery has twice cost more than the
work did.

What to do instead:

* Stop **before** you start writing, not part way through.
* Push what you have to **a branch, as a draft pull request**, clearly marked unfinished.
* Say in the description what is done, what is proven, what is not, and the exact next step.
* Say plainly that you stopped because you ran out. Going quiet reads as failing.

If you are already mid-change when you notice: finish the file you are in, run the three checks,
and write it up. A half-applied edit is worse than either a complete one or none at all.

### Rule 11 — the work gets read, not just the description

Every pull request is read as a diff before it is merged. The description is an account of the
work; it is not the work.

This is not a comment on anyone's care. On one recent night here, two internal reports both read as
accurate and both carried a claim that turned out to be arithmetically false — one of them would
have changed a weapon class Oliver had explicitly asked us to protect. Both were caught by checking
the numbers rather than by reading the summary.

So, practically:

* **Name every file you touched, and make that list match the diff.** A file in the diff that is
  not in the description is the thing reviewers miss.
* **Keep one pull request to one idea.** A branch carrying two unrelated changes gets one of them
  read properly.
* **State what you could not prove.** "This is reasoning, not a measurement" costs you nothing and
  is the single most useful sentence a reviewer can be given. Several contributions here have been
  accepted faster because they said it.
* **A yes to a plan in the mailbox is not a yes to a merge.** Send the change.

Neither rule slows honest work down, and neither one touches your own branch. Work at whatever pace
suits you there. The gate is on `main`, and it always was.
