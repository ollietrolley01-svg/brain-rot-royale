# Task 24: a win has a chance of paying a Mythic Crate

**Files you own for this task:** `MatchConfig.PlacementBrackets` and `MatchConfig.TeamModeRewards`
(new fields only), `RewardService.AwardPlacement` (line 78) and the team results card
(`RewardService.TeamBreakdown`), and `tools/economy_model.py`. **Read only:** `CrateData.lua`,
`CrateService.lua`, `MenuClient.client.lua`.

## What was asked for

Winning should have a chance of giving a Mythic Crate. Oliver, relayed by Jacob.

## What a win pays today

- **Battle royale, rank 1** (`MatchConfig.PlacementBrackets`, MatchConfig line 92): a Legendary Crate,
  2,500 coins and 900 XP. Brackets don't stack.
- **Team win** (`MatchConfig.TeamModeRewards.win`): a Rare Crate, 1,300 coins and 345 XP, plus the
  performance lines. The first team win of the day also pays an Epic Crate.

The **Mythic Crate** (`CrateData.lua` line 94) costs 250,000 coins and is coins-only. It rolls Legendary
80%, Mythic 17%, Secret 3%, has a 40% chance of a 20,000-100,000 coin jackpot, and a pity every 50 on
Secret. One crate is worth 100 battle royale wins in coins.

## Default

On a battle royale win and on a team win, a 1% chance of a Mythic Crate on top of the usual crate. That
adds 2,500 coins of value to a battle royale win on average and roughly doubles it. Run
`tools/economy_model.py` with it and report what it does to an hour for each profile (Task 07's
yardsticks). If the model shows the team modes leaving their 1.25-1.6x band, lower the team chance and
say so.

## Odds must be shown

This is a random reward, and the Mythic Crate's own odds already show on its card. The chance of
getting the crate is a second roll, and it must show wherever the reward is described:

- the results card for the battle royale and the team modes (`TeamBreakdown`),
- any menu text or tooltip that lists what a win pays,
- the crate's line on the card when it drops ("1% chance").

The number shown must be read from the same config field the roll uses, never typed twice. Add that to
`tools/verify.py`'s description checks if it fits there.

## Conflicts

`pc/lag-bug-sweep` changes `RewardService.AwardPlacement` (the global-board save guard) and
`TeamPerformanceValue`, and `MatchConfig`. `pc/teambase-v2` changes `MatchConfig`. Merge main before
pushing. Oliver's 03:00 rule applies to game-file edits.

## Proof

Offline, with lupa: run the real `AwardPlacement` and team payout with a seeded roll over 100,000 wins.
The Mythic Crate rate must land within a stated tolerance of the configured chance, and a loss or a
rank 2 must never pay one. Show the string shown to the player carries the configured number. Plant a
fault (the shown chance differs from the rolled one) and show it goes red. Paste the economy model's
hour figures before and after.

Status: ready to start
