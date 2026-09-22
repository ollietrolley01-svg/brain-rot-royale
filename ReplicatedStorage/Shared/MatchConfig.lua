-- Battle royale rules: lobby pacing, the storm schedule, and placement payouts.

local MatchConfig = {}

-- Fifty a match, bots filling whatever real players don't. The place itself has to allow it too:
-- Game Settings -> Places -> Max Players (or the Creator Dashboard), which isn't in this file.
MatchConfig.MaxPlayers = 50
-- One is enough to start: bots backfill the rest, so nobody ever waits on a quiet server.
MatchConfig.MinPlayers = 1
MatchConfig.LobbyCountdown = 15
-- Once every player in the server has readied up there's nobody left to wait for, so the
-- countdown drops to this. 8 rather than 5 since the vote became a MODE and map decision
-- (Oliver's #2): three cards, three different games, and five seconds is not long enough to read
-- them. Revert this one number if it ever feels slow.
MatchConfig.AllReadyCountdown = 8

-- How far away text in the lobby can be seen, so the plaza isn't a wall of labels from wherever
-- you stand. Floating labels (Ready Pad, Trading Post, practice targets, podium names, the
-- mannequin's plaque) disappear beyond the first; the big boards and the Cloud Climb sign beyond the
-- second; player nameplates beyond the third while their owner is in the lobby.
MatchConfig.LobbyLabelDistance = 55
MatchConfig.LobbySignDistance = 120
MatchConfig.LobbyNameplateDistance = 80
MatchConfig.ResultsDuration = 15
-- A break in the lobby after every match, before the next countdown can begin: time to open
-- crates, trade, kick the balls around or have a go at the Cloud Climb.
MatchConfig.Intermission = 35

-- Shields sit on top of health and take damage first. Everyone drops in with none; shield
-- potions fill them (ItemData). The storm ignores shields.
MatchConfig.MaxShield = 100

MatchConfig.LobbyPosition = Vector3.new(0, 500, 0)

-- Everyone starts on the ground, spread across the whole map on a sunflower spiral rather
-- than clustered on town centres. On a 900-radius map that's roughly 250 studs between
-- neighbours, so nobody opens the match already in a fight.
MatchConfig.SpawnHeight = 6
-- Players open a canopy this far above their spawn and steer down; bots start on the ground.
MatchConfig.DropHeight = 170
-- How long you get to pick a landing spot on the drop map once the map is built, before anyone
-- is placed. Not choosing leaves you on the spawn the spiral gave you, which is the old random
-- behaviour unchanged.
MatchConfig.DropSelectSeconds = 15
MatchConfig.SpawnSpread = 0.96

-- Spacing is driven by area per combatant, so pushing points outward only helps if the
-- disc is big enough. `SpawnInnerBias` also keeps anyone from landing dead centre, which
-- is where the tightest clustering used to happen.
MatchConfig.SpawnInnerBias = 0.22

MatchConfig.StartHealth = 100
MatchConfig.BaseWalkSpeed = 18

-- Sprint multiplies whatever the player's current base speed is, so the Rot Runner
-- gamepass bonus still counts while sprinting instead of being flattened by it.
MatchConfig.SprintMultiplier = 1.45

-- Time to raise a weapon after changing what's in your hands. Shared so the server's
-- enforcement and the client's prediction can never disagree.
MatchConfig.EquipTime = 0.35

-- The storm walks through these in order. `holdTime` is the calm before it moves,
-- `shrinkTime` is how long the move takes, and `radiusScale` is a fraction of the chosen
-- map's radius — so the same schedule works on every map regardless of size.
MatchConfig.StormPhases = {
	{ holdTime = 45, shrinkTime = 50, radiusScale = 0.62, damagePerSecond = 1 },
	{ holdTime = 35, shrinkTime = 40, radiusScale = 0.40, damagePerSecond = 2 },
	{ holdTime = 28, shrinkTime = 34, radiusScale = 0.24, damagePerSecond = 4 },
	{ holdTime = 22, shrinkTime = 28, radiusScale = 0.12, damagePerSecond = 7 },
	{ holdTime = 18, shrinkTime = 22, radiusScale = 0.03, damagePerSecond = 12 },
}

MatchConfig.VoteCandidates = 3

-- Placement payouts. Rewards do NOT stack: a player gets exactly the crate for the bracket
-- they landed in, nothing from the brackets below. Paying out a crate rather than a fixed
-- brainrot means every placement ends on a roll — a Legendary Crate is only 42% to actually
-- cough up a Legendary or better, and 8% to reach Mythic.
MatchConfig.PlacementBrackets = {
	{ maxRank = 1,  crate = "Legendary", coins = 2500, xp = 900 },
	{ maxRank = 5,  crate = "Epic",      coins = 1200, xp = 550 },
	{ maxRank = 10, crate = "Rare",      coins = 600,  xp = 340 },
	{ maxRank = 20, crate = "Uncommon",  coins = 260,  xp = 190 },
	{ maxRank = 30, crate = "Common",    coins = 100,  xp = 90 },
	{ maxRank = 50, crate = "Common",    coins = 60,   xp = 60 },
}

MatchConfig.CoinsPerKill = 75
MatchConfig.XpPerKill = 60

-- Bots backfill the lobby and play for real: they carry actual weapons from WeaponData,
-- push and strafe instead of standing still, fight each other as well as players, and
-- retreat when hurt. Accuracy falls off with range so close fights are genuinely dangerous
-- and long ones are survivable.
-- #127 (Oliver, 2026-09-22): "reduce the bot count down to 30". Was 50 (49 bots with one player).
-- Oliver, 2026-09-22 13:45: "we need 50 players in the battle royale rounds and keep 30 in the other
-- gamemodes". So the fill target is per mode: MatchService fills to min(target, MaxPlayers) minus the
-- real players, reading BotFillTargetBattleRoyale for the battle royale and BotFillTarget for every
-- other mode (TDM, KOTH). 50 in the battle royale means 49 bots with one player, as it was before #127;
-- the team modes keep 30, where bunched bots were the lag complaint (#126).
MatchConfig.BotFillTarget = 30
MatchConfig.BotFillTargetBattleRoyale = 50
MatchConfig.BotHealth = 100
MatchConfig.BotWalkSpeed = 17
MatchConfig.BotThinkInterval = 0.25

-- Nerfed 2026-09-18 on Oliver's "nerf the ai aim a bit": near 0.66 -> 0.55, far 0.19 -> 0.15, which
-- is about a sixth off a bot's hit rate at every range (measured at 20, 60 and 150 studs by
-- tools/bot_probe.lua's S23). Accuracy falls off with distance, so these two numbers and the falloff
-- below are the whole difficulty dial, alongside BotDamageScale.
-- Oliver, 2026-09-22 14:39: "un nerf the bots aim". Back to the pre-#118 values.
MatchConfig.BotAccuracyNear = 0.66
MatchConfig.BotAccuracyFar = 0.19
MatchConfig.BotAccuracyFalloff = 120
MatchConfig.BotReactionTime = 0.28
MatchConfig.BotBurstRest = 0.48

MatchConfig.BotVisionRange = 260
MatchConfig.BotEngagePreferred = 70
MatchConfig.BotRetreatHealth = 26

-- Regen only starts after a bot has been out of a fight for a while, which keeps chip damage
-- meaningful without making a wounded bot a permanent free kill. It's the slow fallback;
-- a bot carrying heal items uses those first.
MatchConfig.BotRegenDelay = 9
MatchConfig.BotRegenPerSecond = 3.5

-- Heal items. Bots use Bandages and Med Kits below this share of max health, only once
-- they've been out of sight for BotHealLull seconds (so a heal is a reward for breaking
-- contact, never a mid-duel refill), and no faster than the player heal cooldown.
MatchConfig.BotHealBelow = 0.6
MatchConfig.BotHealLull = 1.5
MatchConfig.BotHealCooldown = 1.5
MatchConfig.BotStartBandages = 1
MatchConfig.BotPlayerBias = 1.6
MatchConfig.BotDamageScale = 0.8

-- Awareness. A target in front of a bot (a 150-degree cone) is noticed at once; one behind it takes
-- BotRearNoticeTime, unless it's the one shooting, so sneaking up on a bot works. When a target
-- breaks line of sight the bot goes to where it last saw them, for BotMemorySeconds plus the time
-- it takes to walk there, instead of tracking them through walls.
MatchConfig.BotRearNoticeTime = 1.2
MatchConfig.BotMemorySeconds = 6

-- Below this share of max health, a bot that's being hit looks for cover (or builds some).
MatchConfig.BotCoverHealth = 0.6

-- Storm pressure: the distance to the safe circle over how far a bot can walk before the storm
-- gets there. Past Rotate it stops looting outside that circle and sprints its wander legs; past
-- Urgent it drops everything and heads in, shooting on the move.
MatchConfig.BotStormRotate = 0.6
MatchConfig.BotStormUrgent = 0.9

-- Bots empty magazines and reload with the gun's own magSize and reloadTime, like players.
MatchConfig.BotReload = true

MatchConfig.CoinsPerBotKill = 40
MatchConfig.XpPerBotKill = 32

function MatchConfig.GetBracket(rank)
	for _, bracket in ipairs(MatchConfig.PlacementBrackets) do
		if rank <= bracket.maxRank then
			return bracket
		end
	end
	return nil
end

return MatchConfig
