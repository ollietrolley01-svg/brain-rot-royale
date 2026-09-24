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
	{ maxRank = 30, crate = "Common",    coins = 120,  xp = 90 },
	{ maxRank = 50, crate = "Common",    coins = 90,   xp = 70 },
}
-- The bottom two were 100 and 60 coins (xp 60 at the bottom). Raised a little (Oliver, 2026-09-22,
-- from ECONOMY.md s.2): at 50 players a player who keeps losing spends two thirds of their matches in
-- ranks 31-50 and earned 4.5x less a minute than a middle player.

-- Every hit between combatants is multiplied by this (CombatService.DealDamage). 1 = the weapons' raw damage.
-- 0.85 (Oliver, 2026-09-22 21:38: "increase the ttk a bit") turned out too slow (2026-09-23 15:07: "make it
-- a good middleground"), so 0.92: a kill takes about 9% longer than raw damage instead of 18%.
MatchConfig.CombatDamageScale = 0.92

MatchConfig.CoinsPerKill = 75
-- Team Deathmatch / Objective Capture payouts. Oliver, 2026-09-23 16:10: "theres no rewards for the team
-- gamemodes!", then 2026-09-24: "improve the rewards for team gamemodes too".
--
-- THE YARDSTICK is the battle royale's pay per minute of play, lobby included (tools/economy_model.py,
-- ECONOMY.md s.2): a player who picks a team mode should earn about what the same player earns in the
-- battle royale over the same hour -- within 15%, never clearly more. The model checks every profile
-- ("loses only", "wins sometimes", "strong") for coins an hour AND Pass XP an hour, Team Deathmatch and
-- Objective Capture separately, and fails if any of the twelve numbers drifts outside that band.
--
-- WHAT A MATCH PAYS, all of it at the end, on one itemised results card (RewardService.TeamBreakdown):
--   the result      a crate, coins and XP for a win, a draw or a loss. A loss still pays a crate.
--   performance     kills at the battle royale's own rate, assists, multi-kills, revenge, and in Objective
--                   Capture captures, time on the objective and kills made defending it. Each is capped per
--                   match, so a bot lobby cannot be farmed past a sensible match's worth.
--   MVP             the best performer on each team (performance value, before caps) gets a bonus.
--   time played     coins and XP per minute ACTIVELY played (the PlaytimeService movement rule).
-- Everything goes through the 2x SahurCoins pass once, on the total. XP is Brainrot Pass XP, which feeds
-- Rot Rank exactly as battle royale XP does (BattlePassService.OnXp). Wins here do NOT count as battle
-- royale wins (Stats.wins, the global board).
--
-- AFK: a player active in fewer than `participation.minActiveShare` of the checks gets the `afk` line
-- and nothing else -- no crate, no win pay, no MVP. Riding a winning team while idle pays nothing.
--
-- Why the result spread is narrower than the battle royale's (2,500 for 1st, 90 for 31st+): the result is
-- shared by fifteen team-mates, so a big win bonus pays whoever was carried. The difference between a weak
-- and a strong player is made in the performance lines instead, which only that player earns.
MatchConfig.TeamModeRewards = {
	-- THE RESULT. A team match is ~9.3 minutes with the lobby (8 of play), so ~6.5 an hour against the
	-- battle royale's 10-19. A loss still pays a crate and more than a bottom-half battle royale finish
	-- (90-260), because it took three times as long. The win is not the battle royale's 2,500: it is
	-- shared by the whole side, so most of the gap between players is made in the lines below instead.
	win = { crate = "Rare", coins = 900, xp = 230 },
	draw = { crate = "Uncommon", coins = 350, xp = 170 },
	loss = { crate = "Uncommon", coins = 175, xp = 130 },
	-- Idle for most of the match: this and nothing else.
	afk = { coins = 25, xp = 20 },

	-- MatchService's live kill path. Kills are paid on the results card now, so the live payment is 0; the
	-- live call still counts the kill for Stats.kills, the kills quest and gun mastery, up to maxPaidKills.
	killScale = 0,
	maxPaidKills = 30,

	-- Kills pay the battle royale's own rate (CoinsPerKill / XpPerKill, the bot rates for a bot) for the
	-- first `cap` of a match. A strong player makes ~20 against bots in 8 minutes of respawns, where a strong
	-- battle royale player makes 5 in 6; paid in full, the kill XP alone would put a strong team-mode hour
	-- 20% over the battle royale's. The kills past the cap still count for MVP, streaks and quests.
	kill = { cap = 18 },
	-- Damage on someone a team-mate then finished: at least `minDamage` in the last `windowSeconds`.
	assist = { coins = 30, xp = 12, cap = 15, minDamage = 25, windowSeconds = 10 },
	-- Killing whoever last killed you.
	revenge = { coins = 40, xp = 10, cap = 5 },
	-- Multi-kills, the battle royale's streak (MatchService STREAK_WINDOW, 50 a step: 50 for a double up to
	-- 200 for a rampage). tools/team_rewards_check.py fails if these drift from MatchService's. Coins only,
	-- as in the battle royale.
	streak = { windowSeconds = 8, coinsPerStep = 50, max = 5, cap = 400 },
	-- Objective Capture only, standing in for the kills that mode does not score. A capture pays everyone of
	-- the capturing team standing on it; time pays per second on an objective your team owns (contested
	-- counts: that is defending it); a defend is a kill of an enemy standing on an objective your team owns,
	-- paid on top of the kill. Sized so Objective Capture lands within a few % of Team Deathmatch.
	capture = { coins = 60, xp = 25, cap = 8 },
	hold = { coinsPerSecond = 1, xpPerSecond = 0.3, capSeconds = 240 },
	defend = { coins = 30, xp = 12, cap = 10 },
	-- The best on each team by performance value (uncapped), if it is at least `minCoins`. A bot can be
	-- MVP; then nobody on that team gets the bonus. Never an AFK player. It is big on purpose: it is the
	-- team modes' answer to the battle royale's win (2,500 and a Legendary Crate, whose 3,750 jackpot is
	-- most of a strong player's hour), paid for carrying rather than for being carried. Coins, not XP:
	-- the XP side was already level.
	mvp = { coins = 1000, xp = 60, minCoins = 150 },
	-- Paid per minute of ACTIVE play. Checked every `sampleSeconds`: active if the body moved
	-- ProgressionData.Playtime.MoveStuds since the last check in the same life, or dealt damage, or took an
	-- objective or stood on a contested one (a defender behind cover need not move); while dead
	-- a check carries the last live one forward (a player who died mid-fight is still playing, an idle one
	-- is still idle). A respawn is never movement.
	participation = { coinsPerMinute = 10, xpPerMinute = 8, sampleSeconds = 15, minActiveShare = 0.5 },
}
-- What that comes to (tools/economy_model.py s.2b, 2026-09-24), coins an hour / XP an hour against the
-- same player's battle royale hour:
--                    Team Deathmatch   Objective Capture
--   loses only         1.02 / 0.97       1.08 / 0.94
--   wins sometimes     0.91 / 0.93       0.96 / 0.89
--   strong             0.87 / 1.08       0.91 / 1.05
-- Crates are fewer an hour than in the battle royale (6.5 against 10-19), so selling every pull, a team
-- hour is worth less than a battle royale one: never more, which is the rule.
MatchConfig.XpPerKill = 60

-- Vehicles parked at each team's base in the team modes (Oliver, 2026-09-24: "make vehicles spawn near
-- the spawns of the teams on team gamemodes"). ModeTeams parks them; they are EXTRA to the map's own
-- town and verge parking, which every mode keeps. One per slot, and both bases get the same models.
--   Slots          "armed" is a car with a mounted weapon (Rotster, Crocodilo Ranger, Sahur Van);
--                  "car" is any car, weighted as the map rolls them; "bike" is any bike. At most one
--                  bike: a base of bikes is a base nobody can fight from.
--   Inner/Outer    studs from the base point the spots are looked for between. The pads spread 60
--                  from it, so the ring overlaps them and PadClearance does the keeping apart.
--   PadClearance   studs from a vehicle's centre to any spawn pad: half a Ranger's length (7.3) plus
--                  the 8-stud box a pad keeps clear, plus a few to walk round the bumper.
--   Gap            studs between two base vehicles' centres, so none is parked into another.
--   LootClearance  studs from any loot already lying there (the base caches).
--   RespawnDelay   seconds after a base vehicle is wrecked (or lost off the map) before a replacement
--                  is parked; never more live base vehicles than slots.
MatchConfig.TeamBaseVehicles = {
	Enabled = true,
	-- Oliver, 2026-09-24: "add more cars to spawn bases". Six, one for each bay of the compound's yard.
	Slots = { "armed", "armed", "car", "car", "car", "bike" },
	Inner = 22,
	Outer = 75,
	PadClearance = 18,
	Gap = 18,
	LootClearance = 10,
	RespawnDelay = 45,
}

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
-- Oliver, 2026-09-22 21:34: "make the bots aim a little better". Up a notch (0.66/0.19 -> 0.71/0.22);
-- BotService also lets aim settle on a target and makes fast-moving targets harder to hit.
MatchConfig.BotAccuracyNear = 0.71
MatchConfig.BotAccuracyFar = 0.22
MatchConfig.BotAccuracyFalloff = 120
-- #75/#81 (Oliver: "increase bots reaction speed and their aggressiveness"). Was 0.28, which a
-- bot could only honour in whole thinks (one every ~0.267 s), so it was really two thinks. 0.12 is a
-- real time now: BotService fires the first shot on a short timer when the reaction ends between
-- thinks. Aim does NOT move with it: BotService's aim settle is pinned to the old 0.28 (#40).
MatchConfig.BotReactionTime = 0.12
MatchConfig.BotBurstRest = 0.48

MatchConfig.BotVisionRange = 260
-- Aggression is commitment, not lethality (#75/#81 ruling). Closer fights (was 70) and a later
-- retreat (was 26 hp). 55 not 45: closing in raises the hit rate through the distance falloff
-- (base chance 0.42 at 70 studs, 0.49 at 55, 0.53 at 45), and 45 buys more of that than the ruling
-- allows. Guns with a short reach fight at 0.6 of it either way. tools/bot_aggression_ab.lua
-- measures 55 and 45 against the old values.
MatchConfig.BotEngagePreferred = 55
MatchConfig.BotRetreatHealth = 15

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
-- #75/#81: rear notice 1.2 -> 0.7 (sneaking up still works, for less long); hunting a lost target
-- 6 -> 10 s plus the walk, so a bot chases instead of going back to looting.
MatchConfig.BotRearNoticeTime = 0.7
MatchConfig.BotMemorySeconds = 10

-- Below this share of max health, a bot that's being hit looks for cover (or builds some).
-- Oliver, 2026-09-22 21:35: "make them take cover". Was 0.6.
MatchConfig.BotCoverHealth = 0.8
-- #75/#81: a bot being shot by someone it can't see used to run whenever it was under BotCoverHealth
-- (0.8 since 21:35, so at 79 hp). That's cover in a fight, which stays; running from an unseen
-- shooter now waits until half health, and above that the bot goes looking for them.
MatchConfig.BotFleeHealth = 0.5
-- Pushing a nearly dead target, which overrides taking cover: the target under this share of its
-- health, the bot over that share of its own. Were 0.35 and 0.5 (#75/#81: push earlier).
MatchConfig.BotPushTargetBelow = 0.5
MatchConfig.BotPushHealthAbove = 0.4
-- Team modes: how long a freshly spawned bot spends gearing up at its base (chests first) before it
-- heads for the fight. Ends early once the base has nothing it wants.
MatchConfig.BotBaseGearSeconds = 30

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
