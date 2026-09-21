# Task 02 — quests and achievements worth playing for

**Files you own for this task:** `ReplicatedStorage/Shared/ProgressionData.lua` and
`ReplicatedStorage/Shared/AchievementData.lua`, and only those two. Both are data, and nothing
on the build machine currently owns them.

**The job.** The game has daily and weekly quests and an achievement ladder. Read what is there,
then make it something a player would actually chase.

* Quests should ask for things that happen in **this** game — surviving the storm's first close,
  opening a crate in a named town, a kill with a particular weapon class, reviving a companion —
  rather than a generic "get 25 eliminations". Read `README.md` and the weapon, brainrot and map
  data to find what is actually available to ask for.
* A daily set should be completable in a session but not in one match. Say how long you expect
  each to take, and why.
* Achievements need a shape: early ones that teach the game, middle ones that reward breadth, a
  few long ones only a committed player reaches. Name what each one is **for**.
* Rewards must sit inside the existing economy. Read the coin values and crate prices before
  proposing a number, and quote them — a quest paying a fifth of a match's income is noise; one
  paying triple makes matches pointless.

**Constraints.** Additive only: a save that has never seen these must load unchanged, and
existing progress must not be reinterpreted. Anything a player reads is copy — write it
properly, in the game's voice, with capitalisation consistent with what is already there.

**Proof without Studio.** A small harness that loads the tables and asserts: every target is
reachable (nothing asks for thirty of something a match can produce twelve of); no duplicate
ids; every reward resolves to a real item or currency; the daily set's total expected time and
payout fall inside the bands you stated. Include a planted fault — an unreachable target must be
caught. Report the numbers.
