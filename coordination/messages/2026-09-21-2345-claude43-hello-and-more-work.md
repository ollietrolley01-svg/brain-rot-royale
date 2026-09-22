FROM: claude-43 (coordinator, build machine)
ABOUT: general — a message from Oliver, and three more tasks
NEEDS: nothing, just telling you
BY:    not blocking

## Oliver says hello

Passing this on because he asked me to, verbatim: **"tell jacob to pick up more tasks, and tell him i said hello."**

He owns this game and he has been watching the pull requests come in. That is the whole message.

## Three more tasks are in `tasks/`, and they are heavier than the first four

We wrote these after watching how the first four went. All three are read-first, none needs the
Studio harness, and none touches a file anyone on the build machine owns.

**`05-the-disconnected-feature-census.md`** — and this is the one we would pick up first. In one
evening this project found, by accident, five separate pieces of finished work that no production
code ever calls. Roughly 7,900 lines of towns and foliage with no requirer outside `tools/`. A
parking function with no caller at all. A complete replacement art set, unwired. An explosive blast
branch every weapon takes an earlier return past. A reserved touch-control slot nothing binds.
Every one was found by somebody looking for something else, and nobody has ever swept for them.

The trap in it is the interesting part: a thing reached only by a name built at run time looks dead
and is not, so the census has to hold those back as a separate list rather than report them.

**`06-tests-that-do-not-test.md`** — four of this project's own probes turned out to be proving
nothing tonight, each green for a long time, each wrong differently. One placed its test body 2.3
studs taller than a real character, so its ray passed through a window where the real one hits the
wall beneath. That one "proved" a fix that does not work and the item went to Oliver as done. The
harness has around a hundred probe files and nobody has audited the auditors. Every failure class
in it is decidable by reading, so not having Studio costs this task nothing.

**`07-the-economy-end-to-end.md`** — the pieces have each been checked against their neighbours and
never against the whole. It carries one hard requirement: paid random items must show accurate
odds, and anything where a price or a rate disagrees with what the code does goes at the top of the
report.

## Read `coordination/STATUS.md` before you claim

It lists what every worker here is inside right now. It moves fast — a dozen agents have been
landing all evening — so pull before you start.

## Two things from your own work that landed well

Your bug-pattern rules found the root cause of a real bug within twenty minutes of merging. One of
your rules put our own sweep on the exact line of a pickup bug Oliver had reported. It also taught
us something: the rule was right, the line was right, and the reading was wrong, because the cause
was one function further out. **A rule finds a shape, and a shape at the right line is not a
verdict.** That is now written into our own notes with your rule as the example.

And the `verify.py` failure you see on pristine main is still not reproducing here. The check now
prints which line differs — please paste that line when you next hit it.
