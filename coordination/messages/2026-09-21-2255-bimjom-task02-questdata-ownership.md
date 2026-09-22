FROM: bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: task 02 — quests and achievements
NEEDS: answer
BY:    not blocking — the in-bounds slice is merged as PR #3

## The brief's file list does not match where the quests live

`tasks/claimed/02-quests-and-achievements.md` is mostly about daily and weekly quest design: what a
daily set should ask for, how long it should take, that it should be completable in a session but
not in one match. But it grants `ProgressionData.lua` and `AchievementData.lua`, "and only those
two."

The daily/weekly quest pool is `ReplicatedStorage/Shared/QuestData.lua` — 212 lines, not granted.
`ProgressionData.lua` is the Rot Rank / Prestige / Mastery / Cell Shop economy, not a quest pool.

So either the file list is a slip for `QuestData.lua`, or the intended work was the achievement
ladder alone. **We have not decided which.** `QuestData.lua` is untouched — not one line.

## Worth knowing before you answer

`QuestData.lua` already does what the brief asks for. Its pool is game-specific rather than
generic: Cloud Climb clears, landmark chests, Rot Vendor purchases, explosive-barrel kills,
lobby-pitch goals. It has day- and week-seeded rolling, a bonus crate for clearing all three
dailies, and reset-timer formatting. Our read is that it may not need work at all — which is why
we are asking rather than assuming there was something to fix.

## What we did instead, in bounds (PR #3, merged)

- Audited all 36 achievement rewards against the live economy — placement, kill and bot coins,
  streaks, bounties, crate prices, vendor prices, quest coins. **0 read as noise, 0 as
  match-devaluing.** 36 examined, so that is a real denominator rather than a clean-looking filter.
- Two flagged for your attention rather than changed: `goal25`'s ratio against its own minigame,
  and `obby10` turning out to be the **only** coin incentive for repeat Cloud Climb clears.
- Added two achievements for `items` and `supply` — already-tracked lifetime stats with no
  achievement pointing at them. Both verified live end to end:
  `SupplyDropService.lua:255` and `WeaponService.lua:1850` call `QuestService.Progress`, and both
  stats are declared in the tracked list at `AchievementData.lua:87`, which matters because
  `AchievementService.lua:76` only counts a stat `if data.Lifetime[stat] ~= nil` and silently
  counts nothing otherwise.
- Left `ProgressionData.lua` unchanged. Audited it with your own `tools/progression_model.py` and
  found it coherent — no gap and no bad number to fix. Reporting that as a result rather than
  inventing a change to have something to show.

**Not proven:** reward balance here is an argument from the numbers, not a measurement of play.
Whether any of it is worth chasing is Oliver's call.
