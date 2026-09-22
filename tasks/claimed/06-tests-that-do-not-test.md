# Task 06 — audit the probes for checks that cannot fail

**Files you own for this task:** none. You change nothing. The deliverable is a table.

## Why

This project runs on its own test harness, and in one evening four of its probes turned out to be
proving nothing. Each was green, each had been green for a long time, and each was wrong in a
different way:

* A vault test placed its test body **2.3 studs taller than a real character**, so its ray passed
  through the window where the real one meets the wall beneath it. It proved a fix that does not
  work, and the item it "proved" was reported to the owner as done.
* A cursor test seeded a state by hand that **nothing in the real game ever produces**, then
  asserted the code restored that seed. A valid test of a mechanism, fed an input no player can
  create.
* A colour check's pattern **could not parse the one site carrying the bug**, so it passed by
  comparing the two that already agreed, and printed a healthy-looking sample count.
* A rod audit filtered for one part shape and reported a model clean **while never looking at the
  parts that carried the fault**. The "clean" result was a measurement of nothing.

A fifth was caught in a simulation rather than a probe: it modelled a rate limiter with a rule the
real code cannot follow, and confidently reported a leak that does not exist.

**A test that cannot fail is worse than no test**, because it stops anyone looking. The harness has
roughly a hundred probe and gallery files and nobody has ever audited the auditors.

## The job

Read every file under `tools/` that asserts anything, and classify each check:

* **SOUND** — it can fail, and it fails for the right reason.
* **CANNOT FAIL** — its condition is always true, its filter matches nothing, its pattern cannot
  parse the input that carries the fault, or its sample excludes the case it exists to catch.
* **STANDS IN WRONGLY** — it builds a substitute for part of the real path, and the substitute
  differs from the real thing in a way that matters. Name the difference.
* **DEAD PLANT** — it plants a fault that no longer fires, usually because the plant was aimed at a
  bug that has since been fixed rather than at an invariant that must always hold.

For each finding: file and line, which class, **and what it would take to make it sound**.

## The two rules this project learned the hard way

**A planted fault must travel the same input pipeline as the real input.** A needle handed to the
checker by a different route proves a detector that works on a route nothing uses.

**A plant aimed at a bug has a shelf life; aim it at an invariant.** "The broken thing is still
broken" goes quiet the moment the fix lands, and the check then prints green-adjacent output
forever. Three plants in this project expired exactly that way.

## Proof without Studio

You cannot run the harness — it needs a Studio install on one machine. That costs this task
nothing: **every class above is decidable by reading**, and reading is the point. Report how many
files and how many individual checks you examined beside how many you flagged.

Rank your findings by what each check was supposed to be protecting. A dead plant on a cosmetic
detail and a dead plant on the save-data path are not the same finding.
