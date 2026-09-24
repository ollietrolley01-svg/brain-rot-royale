# STOP — Oliver, 2026-09-22 14:44: every tab wraps up now. Write your handoff and stop.
# Start nothing new, no rebuilds, no Studio jobs. Details: the 14:45 entry at the end of COORDINATION.md.

> ## Hello from Oliver
>
> Oliver owns this game. He asked us to pass this on, in his words: **"tell jacob to pick up more
> tasks, and tell him i said hello."** He has been reading the pull requests as they come in.
>
> Three heavier tasks are open in `tasks/`: 05, 06 and 07. Take whichever you like.

# What is claimed, and what is free

Maintained by claude-43 on the build machine. **Read this before you pick anything up.** A task in
`tasks/` that this file says is claimed IS claimed, and the task file will not have been updated.

Last updated: 2026-09-21 23:2x.

## Why this file exists

Fourteen agents work on the build machine and cannot see your clone; you cannot see them. The only
thing both sides can read is this repository. Everything below is a live claim, not a plan.

## DO NOT TOUCH — a worker on the build machine is inside these right now

These have someone in them this hour. An edit from outside will collide.

| Area | Files | What is happening |
|---|---|---|
| Guns | `GunModels*`, `Arsenal*`, `Viewmodel`, `GunFx`, `CombatClient.client.lua`, `WeaponService` | Hit registration and the weapon-pickup bug. Three streams converging on `CombatClient`. |
| Menu | `MenuClient.client.lua`, `MenuShell.lua`, `UiParts.lua`, `ProgressionPanel.lua`, `CrateData/Open/Models`, `CosmeticData/Preview` | A five-destination navigation rewrite. **`MenuClient` is one local variable below Luau's compiler warning, so any change there must remove more locals than it adds.** |
| Match flow | `MatchService.lua`, `GameMode*.lua`, `ModeTeams.lua`, `ModeKingOfTheHill.lua`, `LobbyService.lua`, `Bootstrap.server.lua` | Spectator exit, a second King of the Hill objective, and a respawn bug. |
| Pre-match UI | `VoteService.lua`, `VoteScreen.lua`, `DropPicker.lua`, `VoteDropClient.client.lua`, `MenuOpenClaims.lua`, `DropMapService` | A cursor-ownership fix. |
| HUD | `HudClient.client.lua`, `ControlsHint`, `ModeScoreHud`, `HitSplatClient`, `MenuCursor.client.lua`, `InventoryPanel`, `UiKit`, `PhoneLayout`, `EnemyAura.client.lua`, `NameplateService.lua` | Telling friend from enemy at a glance, and the mouse cursor. |
| Vehicles | `VehicleModels.lua`, `VehicleService.lua`, `TrafficClient`, `VehicleDynamics` | Bouncing cars and roadkill. |
| Destruction | `ExplosiveFx`, `ProjectileClient/Service`, `ThrowableModels`, `DefensePlacement`, `MovementService.lua`, `Parkour.lua` | Glass breaking and window vaulting. |
| Bots | `BotService.lua`, `MatchConfig.lua` bot fields | Bots standing still, and their aim. |
| Map and terrain | `MapGenerator`, `MapBuildings`, `MapDecor`, `MapTerrain`, `MapWilds`, `RoadNetwork`, `TownKinds`, `TownThemes`, `Landmarks`, `LootService` | Map size, foliage, rivers, town hookup. Split across three workers. |
| Storm and audio | `StormService.lua`, `StormClient.client.lua`, `EasterEggs.lua` | The storm damaging players in the lobby. |
| Brainrot art | `BrainrotModels.lua`, `BrainrotModelsRemake.lua` | Swapping the live art for the remake set. |
| Tooling | `tools/verify.py`, `tools/lua_static_check.py`, `tools/clock_ratchet.py`, `tools/climb_design.py` | Coordinate through the mailbox before touching any of these. |

## FREE — nothing on the build machine owns these

- `ReplicatedStorage/Shared/QuestData.lua` — see the answer in the mailbox. Probably needs nothing.
- `ReplicatedStorage/Shared/ProgressionData.lua`
- `ReplicatedStorage/Shared/AchievementData.lua`
- `README.md`
- `HANDOFF.md`, `tasks/`, `coordination/`
- Any NEW file you create, as long as nothing here already covers its job.

## The rule that matters most

**A file not listed as free is not free.** The DO NOT TOUCH table is long because this project is
busy, not because the work is closed. If something there needs changing for your task, say so in
the mailbox and it gets routed to whoever is inside it. That is faster than a conflict.

## Something we learned tonight, which applies to you too

A brief can be wrong about the tree. Two of the four briefs named a file or a field that does not
exist in the shape described. **Check the brief against the code before you build to it, and if
they disagree, say so rather than building to the brief.** Both times that happened tonight the
contributor was right and the brief was wrong.
