# task/mythic-crate: a win can pay a Mythic Crate (Task 24)

Cut from `origin/main` at d1e4f73. The brief is `tasks/24-mythic-crate-chance-on-a-win.md` on
`task/playtest-briefs` (PR #68).

## What changes

- **`ReplicatedStorage/Shared/MatchConfig.lua`**: `mythicChance = 0.01` on the rank-1 bracket of
  `PlacementBrackets` and as its own line in `TeamModeRewards`. New `MatchConfig.ChanceText(chance)`
  formats a chance for the player ("1%"), so the number shown is always the field's.
- **`ServerScriptService/Modules/RewardService.lua`**: `RewardService.Roll` (math.random; checks seed it) and
  `RewardService.MythicLine(chance, won)`, the card's line for the roll. `AwardPlacement` rolls on a bracket
  with `mythicChance` and returns the line as `reward.mythic`. `AwardTeamResult` rolls on a win that isn't
  idle, and `TeamBreakdown` lists the line on every win card. Both give the Mythic Crate exactly when the
  line says it dropped, on top of the usual crate.
- **`StarterPlayerScripts/ResultsScreen.client.lua`**: a breakdown line with a `note` shows it where the pay
  goes ("+1 CRATE" / "not this time", in Mythic pink when it dropped); the battle royale card shows
  `reward.mythic.chip`.
- **`StarterPlayerScripts/HudClient.client.lua`**: the new-player tip about winning reads the win's crate and
  Mythic chance from MatchConfig.
- **`tools/economy_model.py`**: counts the Mythic Crate as a crate share on a win (battle royale and team).
- **`tools/mythic_crate_check.py`** (new): runs the real AwardPlacement and AwardTeamResult 100,000 times each
  with a seeded roll, with 8 planted faults.
- **`tools/team_rewards_check.py`**: pins the roll to "no drop", so its exact crate list stays deterministic.
- **`tools/mythic_crate_gallery.lua`** (new): renders the real results card with the real Mythic lines, a battle
  royale win and a team win, each with the crate dropped and not (`tools/gallery.ps1 -Gallery ...`).
