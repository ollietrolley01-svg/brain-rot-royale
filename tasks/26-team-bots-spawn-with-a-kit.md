# Task 26: team-mode bots spawn with a kit instead of looting

**Files you own for this task:** `BotService.SpawnLoadout` as set in `GameMode.lua` (line 748), a new
bot kit in `GameModes.lua` beside `GameModes.Loadout`, and the base-gear phase in `BotService.lua`
(`bot.gearUntil`, about line 5962) only. **Read only:** `BotService.FindBaseLoot`, `ItemData.lua`,
`ModeTeams.lua`, the player kit (`GameModes.Loadout`, `RollLoadout`).

## What was asked for

In team modes, bots should spawn with a random kit instead of looting: 1 gun, 2 explosives, 2
defenses, 2 heals and 1 movement item. Oliver, relayed by Jacob.

## What happens now

Team-mode bots already spawn with the players' kit. `GameMode.lua` sets `BotService.SpawnLoadout` to
`ModeTeams.RollGreenWeapon()` (a random Uncommon gun) and `GameModes.RollLoadout()`: 3 Bandages, 2
Lowkey Lattes, 2 each of two random explosives (from Cooked Coconut, Clingy Crumpet and Rot Mine), 2 of
one random defense (from Rot Barricade, Popup Bunker and Brainrot Fortress), and full shield.

Then they go looting anyway. For `MatchConfig.BotBaseGearSeconds` (30 s) after each spawn, a bot looks
for base chests, guns and heals every 0.6 s (`FindBaseLoot` with `chestsFirst`, BotService about line
5975). Later, `FindBaseLoot` sends it home for heals in a lull (line 5290). `isUnderArmed` (line 3615)
already treats a kit gun as enough.

The ask differs from today's kit in two ways. It has no movement item, and it has fewer explosives and
heals.

## Default

For bots only (players keep their kit): 1 random Uncommon gun, 2 of one random explosive, 2 of one
random defense, 2 Bandages, and 1 random movement item from `ItemData`'s `kind = "movement"` entries.
Bots can already use the Rot Rocket, but not every movement item (Task 25: no bot uses the Launch Pad),
so draw only from items bots can use, and list them. Turn the base-gear phase off for bots. Keep the
lull restock for heals.

## Overlap

- Task 18 (longer team matches): more time between spawns changes how far a kit has to last.
- Task 20 (bot gunners): a bot that doesn't loot at spawn reaches the fight and the guns sooner.

## Conflicts

`pc/lag-bug-sweep` changes `FindBaseLoot` and `GameMode.lua`. `pc/lag-bug-sweep` and `pc/teambase-v2`
both change `GameModes.lua` and `ModeTeams.lua`. `task/bot-gunner-wait` and `task/blast-parachuters` are
stacked on the sweep. Merge main before pushing. Oliver's 03:00 rule applies to game-file edits.

## Proof

Offline, with lupa: roll the bot kit 10,000 times and show every roll has exactly 1 gun, 2 explosives, 2
defenses, 2 heals and 1 movement item, each within its item's stack. Run the base-gear code with a
mocked base and show a fresh bot never targets base loot at spawn. Plant a fault aimed at the kit's
shape and show it goes red.

Real behaviour: bots are server-side, so a runtest probe over a team match can count how many seconds
after spawn each bot reaches the middle, before and after, over 3 reps. The coordinator runs it.

Status: ready to start
