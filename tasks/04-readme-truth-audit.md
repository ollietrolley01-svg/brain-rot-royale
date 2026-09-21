# Task 04 — make the README true again

**Files you own for this task:** `README.md` only.

**The job.** The README describes how this game works, and it is the first thing any new worker
— human or Claude — reads. Parts of it are now wrong, because the game moved and the prose did
not. One known example: it said the game had 126 brainrots when a 127th was added, and it
described a lobby vote that has since changed shape entirely.

Go through it section by section against the code and produce a claim-by-claim audit: the
claim, the file and line that decides it, and the verdict — **TRUE**, **STALE**, or
**UNVERIFIABLE-FROM-SOURCE**. Then fix the stale ones.

**This is worth more than it sounds.** Every wrong sentence is a trap for the next person, and
several of the expensive mistakes on this project began with someone trusting a description
instead of reading the code.

**Two rules.** Where a number in the prose duplicates a number in the data, do not merely
correct it — **say so**, because the right fix is for the prose to stop carrying the number at
all. And where the code and the README disagree about **intent** rather than fact, do not pick a
side: report it as a question for the owner.

**Proof without Studio.** The audit table *is* the evidence, with counts: claims checked, true,
stale, unverifiable. A "stale" verdict with no file and line behind it does not count.
