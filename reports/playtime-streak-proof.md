# #76 playtime awards and #77 daily streak prize: an independent check

> **2026-09-25 update.** Oliver decided "count all time in the server" (`pc/playtime-all-time`, merged
> in 091812e): PlaytimeService pays every 10 minutes in the server whatever the player does, and
> `MinActiveSamples` is gone. The activity-rule findings below (finding 2, finding 3, the threshold and
> movement cases in sections 2 and 3, the spectating rows in section 5) are **superseded** and kept as
> history. `tools/playtime_check.py` now checks the ladder amounts and that statue, fidget and ghost
> are paid the same as a runner. `tools/playtime_streak_proof.py` was cut to what that check does not
> cover: a player who leaves is dropped (playtime_check still misses that plant), a rejoin restarts the
> ladder, the profile-not-loaded fact, and the whole #77 half. It now prints `8 checks, 0 failed` and
> `7/7 caught`.

Proved against **main at ac22e5e** (fetched 2026-09-25). The feature landed in 698efa3. Since then,
two commits changed these files: **a2ba3b4** made dead / spectating checks count as idle, and a
Premium-pass guard went into the Daily Spin's TempPass branch. **9db0d20** and **e05b995** touch
related code (the match AFK rule and PlayerData's load lock) and are covered below. Nothing in
`PlaytimeService.lua`, `BattlePassService.lua`, `ProgressionData.Playtime`,
`BattlePassData.DailyRewards`, `DailySpinData.lua`, `RewardService.lua`, `Monetization.lua`,
`StateSync.lua` or `tools/playtime_check.py` changed between 82968cb and ac22e5e.

No game file or existing tool was edited. What this branch adds is at the end.

## Verdict, claim by claim

| Claim in 698efa3 | On main at ac22e5e |
|---|---|
| #77: the Daily Spin also pays day N of the seven-day table, wrapping after day 7 | **Holds.** The real `ClaimDaily` pays entry `(N-1)%7+1` on 15 straight days; day 8 pays entry 1 (+250) |
| #77: the spin's message names the bonus | **Holds.** `Daily Spin: +1200 SahurCoins   (day 1 streak)   •   Day 1 bonus: +250 SahurCoins` (real output) |
| #76: 50, 75, … up to 200 every 10 active minutes; 675 the first hour, 1,200 each hour after | **Holds** (recomputed below) |
| #76: server memory only, no save touched | **Holds.** PlaytimeService writes no profile field. The coins go through `Monetization.EarnCoins`, like every other coin |
| #76: a stretch counts if the character moved in half its 30 s checks | **Holds**, exactly: 10 of 20 pays and 9 of 20 does not (measured) |
| #76: **being dead or spectating counts as playing** | **No longer true, on purpose.** a2ba3b4 changed `PlaytimeService.lua:40` to `return false`. The comment at `PlaytimeService.lua:5-9` and `playtime_check.py` were updated to match. The claim in the 698efa3 message and OLIVER_LIST is stale |
| `tools/playtime_check.py`: 8 checks, 4 planted faults caught | **Reproduces:** `8 checks, 0 failed` and `4/4 caught`. One of the 8 checks cannot fail (finding 1) |

No bug was found in the payout code. There are four findings, most important first.

### Finding 1: `playtime_check.py`'s #77 check cannot fail

`tools/playtime_check.py:180-182` ("the daily streak prize walks the whole table and wraps") recomputes
`(streak - 1) % cycle + 1` **in Python**. The only thing it reads from the game is the number of
entries in `DailyRewards`, and it never runs `ClaimDaily`. I planted a fault in a temp copy: I shifted
`BattlePassService.lua:236` to `data.Daily.streak % BattlePassData.DailyCycle + 1`, so day 1 would pay
entry 2. The result was `playtime check: 8 checks, 0 failed`: **missed**. None of its four plants is
aimed at #77. The new `tools/playtime_streak_proof.py` runs the real `ClaimDaily` and catches the same
fault.

### Finding 2: since a2ba3b4, a player who spectates is barely paid, and that is the losing player

> **Superseded 2026-09-25:** all time in the server now pays; see the note at the top.

After dying in the battle royale, a real player has no character until the match ends or they press
LEAVE. `CharacterAutoLoads` is off (`MatchService.lua:2127`), and `LeaveSpectate` is at
`MatchService.lua:475`. Since a2ba3b4, every one of those checks is idle. The model below puts numbers
on what that does. A player who loses early and watches each match out in a server with other people
goes from about 938 coins an hour of playtime to about 54, because 14% of their stretches pay. A player
who wins sometimes goes from 938 to 356. In a solo server of bots, the match ends when the only person
dies (`concludeIfOver`, `MatchService.lua:1461`), so there is no spectating and every profile gets the
full ladder.

This conflicts with the design note still at `ProgressionData.lua:613-614`: "it matters most to the
player losing most". Before a2ba3b4 that held; in a multi-player server it now holds the other way
round. Whether that is acceptable is Oliver's call. The trade-off:
- **Counting spectating as idle** closes the AFK farm a2ba3b4 was fixing (an idle player dying at the
  drop and sitting on the spectator camera).
- **Counting it as playing** pays that farm again.
- **A third option**: skip dead checks entirely rather than counting them as idle, so a stretch is
  judged only on the time the player had a body.

These numbers come from a model, not a measurement (see "What this does NOT prove").

### Finding 3: the two AFK rules differ

> **Superseded 2026-09-25:** all time in the server now pays; see the note at the top.

9db0d20 made the battle royale / team-mode AFK rule count being hurt, firing, reloading and item use
(`WeaponService.NoteActivity`, `MatchService` `afk.busy`). PlaytimeService was not changed and still
counts **movement only** (`PlaytimeService.lua:45`). A player who holds one spot for a stretch while
fighting is "active" for match pay and "idle" for playtime pay. It rarely matters, because a stretch is
10 minutes and needs only 5 minutes of movement. I'm reporting it because the two rules now disagree,
not because it is a bug.

### Finding 4: stale numbers in a comment

`ProgressionData.lua:613-614` quotes ECONOMY.md section 2 cash an hour as 5,431 (loses only) and 12,024
(wins sometimes). `tools/economy_model.py` on main now prints **5,213** and **11,740**. The team quests
moved them, as ECONOMY.md itself says. It is a comment only; nothing reads it.

## 1. The existing check, reproduced, and planted faults

```
$ python tools/playtime_check.py .
playtime check: 8 checks, 0 failed; hour 1 pays 675, each later hour 1200
$ python tools/playtime_check.py . --plant
playtime planted faults: 4/4 caught
```

Are its four plants aimed at invariants (HANDOFF section 3)?

| Plant | Aimed at | Caught by |
|---|---|---|
| `MoveStuds = 0` | invariant: a body that never moves is never paid | "standing still pays nothing" (behaviour) |
| a missing character counts as playing | invariant since a2ba3b4: dead / spectating is not playing | "dead / spectating pays nothing" (behaviour) |
| the ladder never caps | invariant: no award above CapCoins | "the second hour pays at the cap" (behaviour) |
| `MinActiveSamples = 1` | invariant: at least half a stretch | "an award needs at least half its stretch active", which reads the **config**, not behaviour. None of the behaviour checks would catch it, because its statue and fidget players never move 4 studs at all |

All four are invariants, not "the bug is still there" plants. The fourth is caught only by a config
assertion. The #77 check has no plant at all (finding 1).

My own plants, each in a fresh copy of the tree (`/tmp/brr-plant-{a,b,c}`), run against the
**existing** `playtime_check.py`:

| My plant | Result |
|---|---|
| a. `BattlePassService.lua:236` shifted by one day | `8 checks, 0 failed`: **missed** (finding 1) |
| b. `PlaytimeService.lua:74` `sessions[player] = nil` deleted (a player who leaves is kept forever) | `8 checks, 0 failed`: **missed**. Its harness never removes a player |
| c. `SAMPLES_PER_AWARD` halved (an award every 5 minutes) | `8 checks, 2 failed; hour 1 pays 1675, each later hour 2400`: **caught** |

## 2. The numbers

Each award's coins are `min(CapCoins, FirstCoins + StepCoins × (award − 1))` (`ProgressionData.lua:626`).
The values come from `ProgressionData.Playtime` (`ProgressionData.lua:615`): `IntervalSeconds = 600`,
`FirstCoins = 50`, `StepCoins = 25`, `CapCoins = 200`, `SampleSeconds = 30`, `MinActiveSamples = 10`,
`MoveStuds = 4`.

- The awards run 50, 75, 100, 125, 150, 175, then 200, 200, … From award 7 on the value is 50 + 25×6
  = 200 = cap.
- Hour 1 has 3600/600 = 6 awards: 50+75+100+125+150+175 = **675**.
- Hour 2 has awards 7-12, all at the cap: 6 × 200 = **1,200**. Every hour after that pays the same.
- A 2-hour visit pays 1,875. The real Lua, driven for 2 hours, paid
  `[50, 75, 100, 125, 150, 175, 200, 200, 200, 200, 200, 200], total 1875`.
- **Rounding:** every value is a whole number, so none is needed. `EarnCoins` floors `amount ×
  multiplier` (`Monetization.lua:126`), so with **2x SahurCoins** the numbers are exactly 1,350 and
  2,400.

When the ladder resets and when it doesn't (measured with the real Lua):
- **Per visit.** A player who left one check before their 8th award and rejoined was next paid
  `[50]`. Both the ladder and the 19 checks of the part-done stretch were lost.
- **Not per death or per idle stretch.** A player dead for the whole 4th stretch was paid
  `[50, 75, 100, 125, 150, 175, 200, …]`: the dead stretch paid nothing, and the next award carried on
  at 125. An idle stretch pauses the climb; it does not restart it.
- **Nothing is saved**, so there is no daily cap either. Every visit starts at 50, and a player who
  plays 5 hours in one visit gets 675 + 4 × 1,200 = 5,475.

## 3. Abuse and edge cases, read from source and run in the real Lua

> **Superseded 2026-09-25** for everything about movement (the table, macros, riders, idle input): all
> time now pays. The leaver, rejoin, profile, clock and bootstrap bullets still hold.

**What "moved" compares** (`PlaytimeService.lua:36-46`): the `HumanoidRootPart` position against the
same player's position at the previous 30 s check. It measures the straight-line distance, vertical
included, with a threshold of `>= 4` studs. The first check of a visit, and the first after a respawn,
have nothing to compare with and never count. No living character counts as idle.

| Case | Result (real Lua, 2 h) | Why |
|---|---|---|
| standing still / walking into a wall | 0 | the position doesn't change |
| moving 1 check in 3 (for example, a Ready-but-AFK player teleported into and out of matches) | 0 | 7 of 20 at most |
| moving 1 check in 2 | 1,675 | 10 of 20 from the second stretch on |
| a macro that walks 4 studs back and forth | **1,875** | the check sees 4 studs every time |
| the same macro at 3.9 studs | 0 | under `MoveStuds` |
| seated and carried 60 studs a check (vehicle driver or passenger, moving platform) | **1,875** | the root moves with the seat; the server cannot tell riding from walking |

- **Macros and exploits (reasoning, not measured).** The character's position is replicated from the
  client that owns it, so the server check trusts whatever the client reports. A macro, or an exploit
  that moves the root 4 studs every 30 s, earns the full ladder, at most 1,200 an hour after the first.
  Any movement-based rule has this limit. For scale, ECONOMY.md section 2 already reports lobby football
  at a 6,300 coins/h ceiling for a player who never readies. That player also earns playtime, since
  kicking a ball is movement.
- **An idle player with no input at all (platform behaviour, not checked in this repo).** Roblox
  disconnects a client after 20 minutes without input, and nothing in the repo handles `Player.Idled`
  (grep: no hits in ServerScriptService or StarterPlayerScripts). So a hands-off rider, for example a
  passenger in a moving vehicle, gets at most the first two stretches (50 + 75) before being dropped,
  then starts at 50 again on rejoining. Vehicles exist only in matches, which last minutes, so a riding
  farm is short anyway.
- **Moving lobby parts:** `AmbientSpin`/`AmbientBob` are driven on the client (`AmbientClient`). I did
  not check which of those parts a player can stand on.
- **A rejoin, or a server hop mid-stretch,** loses the part-done stretch and restarts the ladder at 50
  (measured above). It cannot pay twice, because nothing carries over.
- **A player who leaves is dropped** (`PlaytimeService.lua:74`). 300 join/leave visits, each leaving at
  a different point in a stretch, left the service holding **10 before, 10 after** (read from the
  `sessions` table itself via `debug.getupvalue`). The loop also skips anyone whose `Parent` is nil
  (`:81`).
- **Profile not loaded yet.** The ladder climbs even when no coins can land (`AwardBonusCoins` →
  `EarnCoins` returns 0 with no profile). Measured: with no profile for the first 20 minutes, the first
  coins that landed were 100, not 50. Since **e05b995**, though, a live player is without a profile only
  while `PlayerData.Load` waits on a lock (at most `LOCK_WAIT_SECONDS = 16`, then a kick) or retries an
  outage (a few seconds, then a temporary profile). The first award comes at 600 s, so **this cannot
  happen in normal play**. I'm noting it as a property of the code, not as a bug.
- **The clock** is neither `os.clock` nor the wall clock. It is one `task.wait(30)` loop
  (`PlaytimeService.lua:79`), so a stretch is 20 scheduler waits. `task.wait` can overrun under load but
  never returns early, so a "10-minute" stretch is at least 10 minutes of real time, and a slow server
  pays a little less an hour, never more. The COORDINATION lesson about `os.clock` doesn't apply here.
- **Cost:** one loop for the whole server, not one per player. Every 30 s it makes two
  `FindFirstChild*` calls and one vector subtraction per real player, each in a `pcall`. Bots are not
  `Players` and never get a session. With `MatchConfig.MaxPlayers = 50`, that is at most 50 of these
  every 30 s, which is negligible. (This is reasoning; I did not profile it.)
- **Bootstrap order:** `PlaytimeService.Start()` (`Bootstrap.server.lua:474`) also adopts players who
  are already present (`Players:GetPlayers()`), so a player who joined before `Start` is not skipped.

## 4. #77: the Daily Spin path

`LobbyService` wheel / `ClaimDaily` remote → `Bootstrap.server.lua` `LobbyService.OnDailySpin` →
`BattlePassService.ClaimDaily` (`BattlePassService.lua:210-242`):

- **The day** is `math.floor(os.time() / 86400)` (`StateSync.lua:42-44`), a **UTC** day. A new day
  starts at 00:00 UTC for everyone, which is 8 pm EDT or 5 pm PDT the evening before.
- **Streak:** if the last claim was on day `today − 1`, the streak goes up by one. Any other gap resets
  it to 1 (`:222-226`). Measured: a two-day gap gave streak 1, the menu promised day 1, and the claim
  paid entry 1 (+250).
- **Day 8** pays entry 1 (+250), day 14 pays entry 7 (Rare Crate), day 15 pays entry 1 again. Measured
  over 15 days: `d1:+250 d2:+400 d3:Common d4:+800 d5:Uncommon d6:+1500 d7:Rare d8:+250 … d15:+250`.
- **The menu is honest.** Before each claim, StateSync's `nextIndex` (`StateSync.lua:100-102`, run
  verbatim) named the same day `ClaimDaily` then paid, on all 15 claims and after the gap.
- **Two claims in one day:**
  - A second claim the same UTC day was refused (`'Already spun today. Come back tomorrow.'`, 0 coins,
    0 crates, measured). A claim from a clock reading one day earlier was also refused.
  - `lastClaimDay` is written at `:227`, **before** any prize is paid, and nothing between the check at
    `:217` and that write yields. So two invocations cannot both pass the check.
  - A rejoin reads the same saved `lastClaimDay`.
  - A **second server** would need a second live copy of the profile, which PlayerData's session lock
    prevents (proved separately by `tools/playerdata_lock_check.py` on main, not by me).
  - **Clock skew** (reasoning): a server whose clock runs a day ahead would let a player claim
    "tomorrow" early, then every correct server refuses until that day has passed. That shifts the
    claim and never doubles it.
- **Saved data:** 698efa3 adds no save field and does not touch `PlayerData.lua`. Measured on a default
  profile (`Daily = { lastClaimDay = 0, streak = 0 }`): across the claims, the only paths that appeared
  were `Crates.Common`, `Crates.Rare` and `Crates.Uncommon`, the crate counts it won, which are existing
  fields. A player who owns nothing new is unaffected beyond getting the prize.
- **The table** (`BattlePassData.lua:37-45`) has **7 entries, all examined**: four `Coins` (250, 400,
  800, 1500, all positive integers) and three `Crate` (Common, Uncommon, Rare, each a key in
  `CrateData.Crates`). Both kinds are handled by `applyReward` (`BattlePassService.lua:66-77`). Each
  entry paid on its own day in the run. None falls through to `"Reward granted."`.
- **Two design facts, reported rather than judged:**
  - The streak prize is **not** multiplied by the spin's streak multiplier; only the wheel's coins are.
  - The streak prize's coins **are** doubled by 2x SahurCoins, since they go through `EarnCoins`.

## 5. Economy: before and after

> **Superseded 2026-09-25** for the spectating rows: every profile now gets the full 938 an hour.

These come from `tools/playtime_economy_compare.py`. It uses `tools/economy_model.py` on main for
everything it can: the profiles, placements, match lengths, cash an hour, and crate sale values. It adds
two assumptions of its own, which nobody has measured:
- A player moves whenever alive in a match and stands still through the 73 s lobby gap.
- "Spectates" means a dead player watches the match to the end (about the storm's length) instead of
  the match ending at their death.

This is a reimplementation of the payment rule over simulated timelines, 400 two-hour visits per row.
It is not the Lua.

```
  profile         cash/h before spectate paid stretches playtime/h    + %
  loses only              5,213       no          100%        938  18.0%
  loses only              5,213      yes           14%         54   1.0%
  wins sometimes         11,740       no          100%        938   8.0%
  wins sometimes         11,740      yes           51%        356   3.0%
  strong                 22,124       no          100%        938   4.2%
  strong                 22,124      yes           98%        909   4.1%
```

The ceiling for a 2-hour visit is 1,875, or 938 an hour. That is +13% / +23% / +18% of the losing
player's 5,213 cash an hour (hour 1 / hour 2 / the 2-hour average), +6% / +10% / +8% of 11,740, and
+3% / +5% / +4% of 22,124. With 2x SahurCoins it doubles, and so do most of the "before" coins.

The seven-day streak table, for a player who claims every day:

```
Streak table (BattlePassData.DailyRewards, 7 days): 2,950 coins + Common, Uncommon, Rare crates a cycle
  crates at shop price 7,000 coins; sold on opening (1x luck) 2,401
  a day: 421 coins cash, 764 with the crates' pulls sold
  an hour of a 2 h day: 211 cash, 382 if sold
    loses only      cash/h    5,213 -> + 4.0%;  if sold/h   12,409 -> + 3.1%
    wins sometimes  cash/h   11,740 -> + 1.8%;  if sold/h   35,000 -> + 1.1%
    strong          cash/h   22,124 -> + 1.0%;  if sold/h   70,282 -> + 0.5%
```

`tools/economy_model.py` does not count either new income yet: it has no playtime line, and its daily
layer is the quests, spin and weeklies without `DailyRewards`. So its section 2 and section 3 hours (and
the 2x SahurCoins payback) are from before #76/#77. I didn't edit it (existing tool). Whether the
numbers are the right size is Oliver's call.

## 6. What this does NOT prove

- **Nothing here ran in Roblox.** Everything was run in lupa with `Players`, characters, `task.wait`,
  `PlayerData`, `CrateService` and `StateSync.Push/Notify` mocked. The payout code, `EarnCoins`,
  `AwardBonusCoins` and the `nextIndex` lines are the real source. Whether a real
  `HumanoidRootPart.Position` moves 4 studs between checks for a given real activity (a seat, a
  vehicle, a platform, a jump in place) was **not measured**. The table rows in section 3 are about the
  rule, with positions I chose.
- **The economy table is a model.** The two assumptions above (still in the lobby, how long a spectator
  watches) decide the spectating rows. How long real players spectate, and whether they press LEAVE,
  would come from a playtest.
- **Nobody has seen it.** Whether the "+N SahurCoins (playtime bonus, next one M)" toast and the longer
  Daily Spin message read well on screen, and fit on a phone, needs a render. That is the
  coordinator's to run.
- **Assumed, not tested here:** that two servers cannot hold one profile (the session lock), and that
  Roblox disconnects idle clients after 20 minutes.
- **I did not check** which client-animated lobby parts a player can stand on.
- **How much server load stretches a `task.wait(30)`** was not measured.

## 7. What this branch adds

> **Superseded 2026-09-25:** the script's plant list and counts below are from PR #34. It now has 8
> checks and 7 plants; see the note at the top.

All new files, relative to 82968cb (the branch was fast-forwarded to ac22e5e before committing):

- `reports/playtime-streak-proof.md`: this report.
- `tools/playtime_streak_proof.py`: runs the real PlaytimeService and ClaimDaily in lupa. It has 11
  checks, and 8 permanent planted faults that must all be caught:

  ```
  $ python tools/playtime_streak_proof.py .
  playtime/streak proof: 11 checks, 0 failed
  $ python tools/playtime_streak_proof.py . --plant
    caught: #77 the streak day shifted by one -> day N of an unbroken streak pays table entry (N-1)%7+1 on top of the wheel
    caught: #77 the streak prize never paid -> day N of an unbroken streak pays table entry (N-1)%7+1 on top of the wheel
    caught: #77 the claim day never recorded -> day N of an unbroken streak pays table entry (N-1)%7+1 on top of the wheel
    caught: #77 a missed day keeps the streak -> a missed day restarts the streak at day 1 and pays entry 1
    caught: #77 a streak crate names no crate -> day N of an unbroken streak pays table entry (N-1)%7+1 on top of the wheel
    caught: #76 an award one check short of the threshold -> a stretch one check short of MinActiveSamples pays nothing
    caught: #76 awards twice as often -> a stretch with exactly MinActiveSamples pays
    caught: #76 a player who leaves is kept -> a player who leaves is dropped
  playtime/streak planted faults: 8/8 caught
  ```

  Each plant breaks something the code must refuse forever: the day paid, the prize existing, one
  claim a day, the gap reset, a real crate, the threshold, the interval, and dropping leavers.
- `tools/playtime_economy_compare.py`: section 5's numbers.
- `README-task-prove-playtime-streak.md`.

The three checks, from the repo root at ac22e5e with this branch's files in place:

```
OK: no problems
files unbalanced: 0
lua static check: 437 files, 0 findings
```
