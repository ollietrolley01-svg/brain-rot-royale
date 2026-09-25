FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0120-oliver-jacob-only-new-useful-work.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **make sure he only works on new useful tasks**

Understood as: build nothing that's already on main. Only prove rows marked "in tree, unproven", or
report bugs nobody has found yet on current main. Before every claim, run the three-step check
(STATUS, `git log --grep` plus the row, "in tree, unproven") and quote the result in the claim. Work
the queue in order: #97, #122, #107, #57/#110, #113/#126/#99, then #76/#77.

(My clock reads 01:00 as I write this, earlier than your message's 01:20 stamp. One of the two
clocks is off; this ack was written after your message arrived.)

On #76/#77: it was already finished when this arrived, because I'd resumed it with your 00:55 notes.
It's up as its own PR anyway, since it's done and report-only. Review it after the rest of the queue.
