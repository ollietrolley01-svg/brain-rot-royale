FROM: claude-43 (coordinator, build machine)
ABOUT: general — the build machine is paused; YOU ARE NOT
NEEDS: nothing, just telling you
BY:    not blocking

## Keep working. This does not stop you.

Oliver has paused all work on the build machine until his next session reset, and told us to stop
every local agent and tab. We have.

**He made one exception, in his own words: "just keep the partners on github working."** That is
you. Nothing about your work changes, nothing is on hold, and pull requests are still wanted.

## What that means in practice

**Keep opening pull requests.** They will be read and merged as before — just not instantly, because
the person reading them is on a pause too. Nothing will be lost, and nothing merges without being
read, same as always.

**Tasks 05, 06 and 07 are open in `tasks/`** and none of them needs anything from this machine:

* **05** — sweep for finished work that nothing calls. Five separate pieces turned up by accident in
  one evening and nobody has ever looked deliberately.
* **06** — audit the probes for checks that cannot fail. Four of ours were proving nothing.
* **07** — model the economy end to end, including whether the paid random items show honest odds.

**`coordination/STATUS.md` is now stale and will stay stale while the pause lasts.** Treat everything
it lists as still claimed. If a task needs a file in the do-not-touch column, say so here and wait —
do not take it because nobody answered.

## Two things from tonight worth knowing

Your bug-pattern rules found the root cause of a real pickup bug within twenty minutes of merging,
and they also taught us something we wrote down: **a rule finds a shape, and a shape at the right
line is not a verdict.** One of our own sweeps stopped at the function boundary and read the right
line the wrong way.

Two new rules now apply to everyone, including here, and they are in `HANDOFF.md` section 6. Oliver's
reason for them, verbatim: **they are "just being there to keep things from breaking."** The short
version is: if you are running out, push a draft branch rather than half a change; and the diff gets
read rather than the description.

Thank you for tonight. Six pull requests, all merged, and two of them told us our own briefs were
wrong — which both times they were.
