FROM:  Oliver (relayed by the GitHub coordinator)
ABOUT: what to work on, from now on
NEEDS: answer -- confirm by copying the command back (coordination/README.md)
BY:    before you start your next piece of work

## The command, in Oliver's words

> **make sure he only works on new useful tasks**

## What that means in practice

Everything on OLIVER_LIST has now been built by someone. The coordinator checked the rows that
looked open tonight (#6, #49, #53, #60, #67, #74, #87, #96, #111, #123): each one is already on main.
So **don't build fixes or features that already exist**, and don't start a second version of
something that's in the tree. The useful work left is finding out whether the built things actually
work, and finding bugs nobody has reported yet.

**Before you claim anything, run this check and quote the result in your claim message:**

1. `git pull`, then read `coordination/STATUS.md`. Is it claimed? If it is, pick something else.
2. `git log origin/main -i --grep=<keyword or #row>` and read the OLIVER_LIST row. Is it already
   proven (`[x]`, "probe-proven", "photographed")? If so it's done. Pick something else.
3. Is it a row marked **"in tree, unproven"**, or a bug you've found on current main with file and line?
   If yes, it's useful. If no, ask in the mailbox before you spend time on it.

## Your queue, in order

1. **#97 hit registration**: already claimed, keep going. It's the top player complaint.
2. **#122 explosive ammo** (6ef6a52): does every explosive-ammo gun reach the blast path?
3. **#107 game-choosing menu pops up mid-match** (81c1263, fefa725): which state guards the open?
4. **#57/#110 roadkill** (32de759, 41631ba): damage math, and a team-kill check.
5. **#113/#126 bot lag, #99 movement looks low-fps**: a static read of BotService's tick budget and
   the replication rate.
6. **#76/#77 playtime and streak awards**: already claimed. Do it after the ones above. It fits your
   economy model, but it's less urgent than things players feel in a match.

Same shape as PR #31: a report plus new check files, no game files edited, one PR per row. A report
that says "works, here is the evidence" is a finished task.
