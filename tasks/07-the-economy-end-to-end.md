# Task 07 — model the economy end to end

**Files you own for this task:** `ReplicatedStorage/Shared/ProgressionData.lua` and
`ReplicatedStorage/Shared/AchievementData.lua`, for any change you propose. Everything else is read
only. Nothing on the build machine owns any of it.

## The job

Nobody has ever modelled this game's economy as one system. The pieces have each been checked
against their neighbours and never against the whole: match income, quest coins, achievement
payouts, streak and playtime rewards, crate prices, vendor prices, the Robux shop, and the rank and
prestige curve.

Build the model, then answer the questions it makes answerable:

* **How many coins does an hour of play produce**, for a player who wins sometimes and loses
  mostly? Give the number with the assumptions beside it, and give the same number for a player who
  only ever loses — that is the one that decides whether the game feels fair.
* **How long until a player can afford each thing they might want?** The first crate, the crate they
  actually want, the cosmetic they saw somebody else wearing.
* **Where does the curve break?** Find the point where earning stops mattering because everything
  affordable is already owned, and the point where the next thing is so far away that people stop
  trying.
* **What is a Robux purchase worth in hours?** Every paid item has an implied exchange rate. Work
  them out and say which ones are out of line with each other, in either direction.

## Rules

**Quote the numbers you reason from, with file and line.** An economy argument with no sources is
an opinion, and this one will be used to change prices.

**Additive only.** A save that has never seen your changes must load unchanged, and existing
progress must not be reinterpreted.

**Say what you would change and what you would leave.** "This is coherent, leave it" is a finding.
The same contributor already reached that verdict on one of these files and was right to report it
rather than invent a change to have something to show.

**Anything a player reads is copy.** Write it properly, in the game's voice, matching the
capitalisation already there.

## The one thing to get right

This is a game for a young audience with paid random items, and **paid random items must show
accurate odds**. If you find anywhere that a price, a drop rate or an odds display disagrees with
what the code actually does, that is the most important finding in the task. It goes at the top of
your report regardless of how small it looks.

## Proof without Studio

A model, written as a script that reads the real data files rather than numbers typed in by hand,
so it stays true when the data moves. Include a planted fault: a price changed in a copy of the
data must move the model's output in the direction and magnitude you predict. Report how many
sources the model reads, and name any you looked for and could not find.
