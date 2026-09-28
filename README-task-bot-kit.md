# task/bot-kit (Task 26)

Cut from `origin/pc/lag-bug-sweep` at `cf35aa3`. The PR targets `pc/lag-bug-sweep`.

## What changes

In the team modes, bots spawn with their own kit and head out, instead of looting their base first.
Players are unchanged: they keep `GameModes.Loadout`.

- `ReplicatedStorage/Shared/GameModes.lua`: a new `GameModes.BotLoadout`: 2 Bandages, 2 of one explosive
  (Cooked Coconut or Clingy Crumpet), 2 of one defense (Rot Barricade or Pop-up Bunker) and 1 Rot Rocket,
  plus the players' full shield. The gun is still the players' Uncommon roll. `RollLoadout(random, loadout)`
  takes an optional loadout, and the players' `Loadout` is the default.
- `ServerScriptService/Modules/GameMode.lua`: `BotService.SpawnLoadout` rolls `BotLoadout` instead of the
  players' kit.
- `ServerScriptService/Modules/BotService.lua`: one per-life field, `bot.kitHeals`. The spawn kit handler
  sets it to the number of heals the kit gave, and a bot with no kit has it nil (the battle royale).
  The kit replaces the battle royale's random starting Bandage (0 or 1), so a kitted bot carries exactly
  the kit's 2.
  A bot with the field set:
  - skips the gear-up phase (`bot.gearUntil` stays nil);
  - gets no chests or guns from `FindBaseLoot`, and heals only once it's below the kit's heal count (the
    lull restock, still gated by `RESTOCK_LULL` in `pickLoot`), and no shields;
  - gets nothing from its own base through `bestConsumable`.
  Loot away from home is unchanged.
- `tools/bot_kit_check.py` (new): an offline check in lupa on the real code, with 16 planted faults.
- `tools/bot_kit_probe.lua` (new): a runtest probe that times each bot life from spawn to leaving the base
  and to reaching the middle, over 3 real Team Deathmatch matches.
- `tools/bot_kit_gallery.lua` (new): the live film of a team base as the bots spawn (`-Record`).
