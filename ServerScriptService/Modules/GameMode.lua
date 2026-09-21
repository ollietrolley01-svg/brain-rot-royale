-- The mode dispatcher. MatchService consults this; it never consults MatchService.
--
-- The battle royale is a FLAGS-ONLY entry here: its code stays in MatchService untouched, and the
-- seams there are `if` wrappers, not moved logic. So the battle royale path is byte-identical in
-- behaviour whatever happens in this file.
--
-- MatchService hands over four closures once, through Bind, rather than exposing its internals:
-- finishing a match, rebroadcasting, and adding/retiring a combatant. Nothing else can reach them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local Remotes = require(Shared:WaitForChild("Remotes"))

-- Both of these are already required by MatchService before it requires this module, so there is
-- no load-order hazard and no cycle: neither requires MatchService at its top level.
local BotService = require(script.Parent:WaitForChild("BotService"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local Combatants = require(script.Parent:WaitForChild("Combatants"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local ModeKingOfTheHill = require(script.Parent:WaitForChild("ModeKingOfTheHill"))
local ModeTeams = require(script.Parent:WaitForChild("ModeTeams"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local StormService = require(script.Parent:WaitForChild("StormService"))

local GameMode = {}

local killFeed = Remotes.Event("KillFeed")
local modeChanged = Remotes.Event("ModeChanged")

--------------------------------------------------------------------------------
-- Host binding
--------------------------------------------------------------------------------

local host = {
	Finish = function() end,
	Broadcast = function() end,
	AddCombatant = function() return false end,
	RemoveCombatant = function() return false end,
	IsParticipant = function() return false end,
}

function GameMode.Bind(handlers)
	for key, fn in pairs(handlers) do
		if type(fn) == "function" then
			host[key] = fn
		end
	end
end

-- One place every outbound remote goes. A toast is news about something that already happened and
-- must never undo it: a FireClient at a player on their way out can throw, and an unprotected one
-- would abort the rest of a scoring handler.
local function announce(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[GameMode] announce failed: " .. tostring(err))
	end
end

--------------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------------

local function noop() end

-- The battle royale. Flags only: MatchService keeps every line of its own behaviour.
GameMode.BattleRoyale = setmetatable({
	StartWorld = function(mapInfo)
		StormService.Start(mapInfo.radius)
	end,
	StopWorld = noop,
	OnDeath = noop,
	OnRespawn = noop,
	PlaceAtStart = nil,
	Broadcast = function()
		return nil
	end,
	RankOf = function()
		return nil
	end,
	Results = function()
		return nil
	end,
}, { __index = GameModes.Modes.BattleRoyale })

local current = GameMode.BattleRoyale

function GameMode.Current()
	return current
end

--------------------------------------------------------------------------------
-- Respawn modes: the shared scoreline and clock
--------------------------------------------------------------------------------

local scores = { 0, 0 }
local deadlineMs = 0
local running = false
local generation = 0
local hillStatus = "Open"
local hillHolder = nil

-- Wall clock, never os.clock(): os.clock() is process CPU time in Roblox, and a match that spends
-- most of itself yielding would never reach a deadline measured that way.
local function nowMs()
	return DateTime.now().UnixTimestampMillis
end

function GameMode.Scores()
	return scores[1], scores[2]
end

function GameMode.SecondsLeft()
	return math.max(0, math.floor((deadlineMs - nowMs()) / 1000))
end

-- Who is winning, or nil for a draw.
local function leader()
	if scores[1] > scores[2] then
		return 1
	elseif scores[2] > scores[1] then
		return 2
	end
	return nil
end

local function pushState()
	announce(function()
		modeChanged:FireAllClients({
			mode = current.id,
			scores = { scores[1], scores[2] },
			target = current.scoreTarget,
			secondsLeft = GameMode.SecondsLeft(),
			hillStatus = current.id == "KingOfTheHill" and hillStatus or nil,
			hillHolder = current.id == "KingOfTheHill" and hillHolder or nil,
		})
	end)
end

local function addScore(team, amount)
	if not team or amount <= 0 then
		return
	end
	scores[team] = scores[team] + amount
	if scores[team] >= (current.scoreTarget or math.huge) then
		GameMode.FinishNow()
	end
end

function GameMode.FinishNow()
	if not running then
		return false
	end
	running = false
	generation += 1
	host.Finish()
	return true
end

--------------------------------------------------------------------------------
-- Respawning
--------------------------------------------------------------------------------

local function padBonus()
	if current.id == "KingOfTheHill" then
		return ModeKingOfTheHill.PadBonus()
	end
	return nil
end

-- Puts a body on a pad, NOW. No waiting and no retry loop: LoadCharacter has already stood this
-- body on the LOBBY's spawn pad -- the lobby holds the only SpawnLocation in the game and
-- player.RespawnLocation is never set -- so every frame this function does not place it is a frame
-- the player spends looking at the lobby. That wait WAS the bug, and it measured 3075 ms.
--
-- Three answers, in order:
--   1. the best pad -- or, when every pad is refused, the least bad one, under spawn protection;
--   2. no pads at all: the nearest real ground to the arena centre (ModeTeams.PlaceWithoutPad);
--   3. nothing anywhere: say so loudly and leave the body alone rather than drop it into the void.
local place

-- CONFIRM THE PLACEMENT TOOK, by reading the body back instead of trusting the write.
--
-- Three things are true at once and together they are why this has been reported three times:
--   * LoadCharacter stands EVERY fresh body on the lobby's spawn pad, so the lobby is always the
--     starting point and being left there is the default failure, not an exotic one;
--   * the only thing that moves it is the PivotTo above, run from an UNPROTECTED CharacterAdded
--     handler, so an error anywhere in that handler leaves the body there for the whole round;
--   * a character's physics are owned by its own CLIENT, so a server CFrame written in the same
--     instant the body replicates is not guaranteed to be the one that sticks.
-- A probe running on a server can only ever see the first two: it measures the server's final
-- CFrame and reports a perfect respawn. So this reads the position back.
--
-- It cannot fight legitimate movement. The tolerance is 150 studs and the sample is 0.35 s later,
-- and nothing in this game moves a player that far that fast: sprint is 26 studs/s, a Rot Rocket
-- and a launch pad are both well under 150 studs in a third of a second, and a body still in the
-- air from one is measured from where it was PUT, which is where the launch started. The lobby is
-- 500 studs away, so the only thing that trips this is a placement that did not take.
--
-- EVERY re-placement warns with the player's name. If that line shows up in a real session, its
-- COUNT is the measurement we could not otherwise make.
local CONFIRM_DELAY = 0.35
local CONFIRM_ATTEMPTS = 3
GameMode.RePlacements = 0

local function confirmPlaced(token, character, target, attempt)
	if not target then
		return
	end
	task.delay(CONFIRM_DELAY, function()
		if not running or not character or not character.Parent then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end
		local drift = (root.Position - target).Magnitude
		if drift <= ModeTeams.PlacedTolerance then
			return
		end
		GameMode.RePlacements += 1
		local tries = attempt or 1
		if tries < CONFIRM_ATTEMPTS then
			warn(string.format("[GameMode] RESPAWN DID NOT TAKE: %s was %.0f studs from where it was placed %.2f s ago (tolerance %d). Placing again, try %d of %d. Total this session: %d.",
				Combatants.GetName(token), drift, CONFIRM_DELAY, ModeTeams.PlacedTolerance,
				tries + 1, CONFIRM_ATTEMPTS, GameMode.RePlacements))
			place(token, character, tries + 1)
		else
			warn(string.format("[GameMode] RESPAWN STILL NOT TAKING for %s after %d tries -- %.0f studs off. Giving up so this cannot loop. Total this session: %d.",
				Combatants.GetName(token), CONFIRM_ATTEMPTS, drift, GameMode.RePlacements))
		end
	end)
end

function place(token, character, attempt)
	local ok, _, where = ModeTeams.PlaceAt(token, character, padBonus(), true)
	if ok then
		confirmPlaced(token, character, where, attempt)
		return true
	end
	local placed, position = ModeTeams.PlaceWithoutPad(token, character)
	if placed then
		warn(string.format("[GameMode] %s: team has no spawn pad at all; placed on the nearest real ground at (%.0f, %.1f, %.0f).",
			Combatants.GetName(token), position.X, position.Y, position.Z))
		confirmPlaced(token, character, position, attempt)
		return true
	end
	warn("[GameMode] no ground anywhere in the arena for " .. Combatants.GetName(token) .. " -- body not moved.")
	return false
end

-- A player's respawn. Reached from MatchService.OnCharacterAdded's existing early return, which is
-- the ONLY path a respawned participant takes.
--
-- PLACE FIRST, KIT SECOND, AND THE KIT PROTECTED. The body's position is state; the kit is news.
-- OnCharacterAdded does not pcall this, so anything that throws while handing out the loadout used
-- to eat the placement and leave the body on the lobby pier, alive and in the match, for the rest
-- of the round. Same shape as the announce-last lesson: write the state, then send the news.
local function respawnPlayer(player, character)
	if not running or not host.IsParticipant(player) then
		return
	end
	place(player, character)
	local ok, err = pcall(ModeTeams.GrantLoadout, player)
	if not ok then
		warn("[GameMode] spawn loadout failed for " .. Combatants.GetName(player) .. ": " .. tostring(err))
	end
end

local function retireBot(bot)
	local character = bot and bot.character
	host.RemoveCombatant(bot)
	ModeTeams.Forget(bot)
	-- Long enough for the death effect to play out, matching the battle royale's own timing.
	task.delay(7, function()
		if character and character.Parent then
			Combatants.Unregister(character)
			character:Destroy()
		end
	end)
end

local function spawnReplacementBot(team)
	local myGeneration = generation
	BotService.Spawn(1, function()
		-- Where the rig is BUILT. It is placed properly a moment later by `place`; this only has to be
		-- real ground, because the arena centre's stored Y is 0 and building a rig four studs above sea
		-- level buries it on any map whose centre stands higher.
		local pad = ModeTeams.PickPad(team, padBonus())
			or ModeTeams.GroundNear(select(1, ModeTeams.Arena()))
			or select(1, ModeTeams.Arena())
		return CFrame.new(pad + Vector3.new(0, 4, 0))
	end, function(bot, humanoid)
		if not running or generation ~= myGeneration then
			return
		end
		-- Forced onto the side that just lost one, so the sides stay level. Assign deals onto the
		-- smaller side and cannot be asked for a particular one, so this says which.
		ModeTeams.AssignTo(bot, team)
		host.AddCombatant(bot, humanoid)
		-- Through the same placer players use, so a replacement can never come back on the enemy's
		-- pad, underground, or on top of somebody. Three in a row used to land on the same point.
		if bot.character then
			place(bot, bot.character)
		end
	end, { dropIn = false })
end

--------------------------------------------------------------------------------
-- Deaths
--------------------------------------------------------------------------------

-- Called from MatchService.eliminate's respawn branch, INSTEAD of the placement path. Scoring
-- happens first and the announcement last.
local function onDeath(token, killerToken, method)
	if not running then
		return
	end

	local victimTeam = ModeTeams.TeamOf(token)
	local killerTeam = killerToken and ModeTeams.TeamOf(killerToken) or nil

	-- Team Deathmatch scores eliminations. King of the Hill scores the hill, so a kill there is
	-- worth nothing on the scoreboard and everything in practice.
	if current.id == "TeamDeathmatch" then
		if killerTeam and killerTeam ~= victimTeam then
			addScore(killerTeam, 1)
		elseif victimTeam then
			-- Falling, drowning or running yourself out of the arena pays the other side, so
			-- there is no way to stall by dying to the world.
			addScore(GameModes.OtherTeam(victimTeam), 1)
		end
	end

	ModeTeams.MarkDown(token)

	if Combatants.IsPlayer(token) then
		if token.Parent then
			-- State first: the loadout is cleared here so the corpse carries nothing and the
			-- respawn grants a clean kit.
			local delay = current.respawnDelay or 5
			local myGeneration = generation
			task.delay(delay, function()
				if running and generation == myGeneration and token.Parent and host.IsParticipant(token) then
					pcall(function()
						token:LoadCharacter()
					end)
				end
			end)
		end
	elseif Combatants.IsBot(token) then
		-- A bot with NO TEAM used to fall out of this branch entirely (it read `elseif victimTeam`):
		-- never retired, never replaced, its corpse left standing in the arena and its slot never
		-- refilled. Two ways in: match-start bots were never dealt a side at all, and `retireBot` calls
		-- ModeTeams.Forget, which clears the team the branch was testing -- so a bot that had already
		-- been retired once could never die again. Measured: 4 bots, 3 deaths, 1 retire, 0 replacements.
		local team = victimTeam or ModeTeams.Assign(token)
		retireBot(token)
		local myGeneration = generation
		task.delay(current.respawnDelay or 5, function()
			if running and generation == myGeneration then
				spawnReplacementBot(team)
			end
		end)
	end

	-- News, last, and protected. Everything above has already happened.
	announce(function()
		killFeed:FireAllClients({
			victim = Combatants.GetName(token),
			killer = killerToken and Combatants.GetName(killerToken) or nil,
			method = killerToken and method or nil,
		})
	end)
	if Combatants.IsPlayer(token) and token.Parent then
		announce(StateSync.Notify, token, string.format("Down — back in %d seconds", current.respawnDelay or 5))
	end
	pushState()
end

--------------------------------------------------------------------------------
-- The respawn-mode driver
--------------------------------------------------------------------------------

local KOTH_TICK = 0.25

local function startWorld(mapInfo)
	-- No storm. Stop() sets the broadcast status to "Idle", which is what makes the HUD's storm
	-- line and the client's ring disappear on their own with no client change at all.
	StormService.Stop()

	scores[1], scores[2] = 0, 0
	hillStatus, hillHolder = "Open", nil
	generation += 1
	running = true
	deadlineMs = nowMs() + (current.timeLimit or 480) * 1000

	local centre, radius = ModeTeams.Setup(current, mapInfo)

	-- The arena boundary: a circle that never shrinks, drawn through the storm's own broadcast so
	-- the ring, the minimap circle and the bots' rotation logic all work with nothing new.
	if current.bounds and StormService.StartStatic then
		StormService.StartStatic(centre, radius, 4, "Stay in the arena")
	end

	if current.id == "KingOfTheHill" then
		ModeKingOfTheHill.Start(current, mapInfo)
	end

	CombatService.DamageVeto = ModeTeams.DamageVeto

	-- BotService pcalls this and fails OPEN: anything but a literal `false` counts as hostile, so
	-- an error here leaves today's behaviour rather than producing pacifist bots. Return the
	-- boolean directly and never raise.
	BotService.IsHostile = ModeTeams.IsHostile

	-- BotService's contract: return a WeaponData def, a weapon id string, or nil. The second
	-- return is the kit (heals, shields, throwables) and is ignored until BotService consumes it;
	-- extra returns are discarded in Lua, so this is correct against the call site as it stands.
	BotService.SpawnLoadout = function()
		return ModeTeams.RollGreenWeapon(), GameModes.Loadout.items
	end

	local myGeneration = generation
	task.spawn(function()
		local accumulated = 0
		while running and generation == myGeneration do
			task.wait(KOTH_TICK)
			if not running or generation ~= myGeneration then
				return
			end
			if current.id == "KingOfTheHill" then
				local team, status = ModeKingOfTheHill.Tick()
				hillHolder, hillStatus = team, status
				accumulated += KOTH_TICK
				if accumulated >= 1 then
					accumulated -= 1
					addScore(team, 1)
				end
			end
			if nowMs() >= deadlineMs then
				GameMode.FinishNow()
				return
			end
			pushState()
		end
	end)

	pushState()
	return centre, radius
end

local function stopWorld()
	running = false
	generation += 1
	CombatService.DamageVeto = nil
	BotService.IsHostile = nil
	BotService.SpawnLoadout = nil
	ModeKingOfTheHill.Stop()
	ModeTeams.Teardown()
	StormService.Stop()
end

-- The first spawn of a match, standing in for MatchService's spiral-and-parachute path. No drop
-- and no canopy: a respawn mode opens on the ground in your own base.
--
-- Placed before the kit, and the kit protected, for the reason respawnPlayer gives.
local function placeAtStart(player, character, index)
	ModeTeams.Assign(player)
	place(player, character)
	local ok, err = pcall(ModeTeams.GrantLoadout, player)
	if not ok then
		warn("[GameMode] opening loadout failed for " .. Combatants.GetName(player) .. ": " .. tostring(err))
	end
	announce(StateSync.Notify, player, string.format("%s — %s", current.name,
		GameModes.TeamName(ModeTeams.TeamOf(player) or 1)))
	return index
end

-- Where a bot's rig is BUILT at match start. A respawn mode opens on the ground in its own base, so
-- the battle royale's sunflower spiral and 170-stud canopy drop do not apply. Real ground, because
-- the arena centre's stored Y is 0.
local function botSpawnCFrame()
	local centre = select(1, ModeTeams.Arena())
	local spot = ModeTeams.GroundNear(centre) or centre
	return CFrame.new(spot + Vector3.new(0, 4, 0))
end

-- A bot joining a respawn mode at match start. WITHOUT THIS every match-start bot played Team
-- Deathmatch and King of the Hill with `teamOf = nil`. Measured, 8 of 8: a bot kill scored +0 (which
-- is why the TDM score HUD reads zero), a dead bot was never retired or replaced, the hill counted
-- 0/0 with every bot standing on it, and the spawn-pad enemy scan refused nothing with enemies stood
-- on the pad. It is also why "the bots just move in circles": a bot with no team has no team
-- objective to pursue. Do not remove while tidying.
local function enrolBot(bot)
	ModeTeams.Assign(bot)
	if bot.character then
		place(bot, bot.character)
	end
	return ModeTeams.TeamOf(bot)
end

-- What the results card shows. There are no placements, so a win is rank 1 and a loss rank 2;
-- a draw is rank 2 for both sides. AwardResult is deliberately NOT RewardService.AwardPlacement:
-- a Team Deathmatch win must not inflate Stats.wins or the global battle-royale board.
local function rankOf(token)
	local team = ModeTeams.TeamOf(token)
	local winner = leader()
	if not team or not winner then
		return 2
	end
	return team == winner and 1 or 2
end

local function results()
	return {
		mode = current.id,
		scores = { scores[1], scores[2] },
		teams = { GameModes.TeamName(1), GameModes.TeamName(2) },
		winner = leader(),
		target = current.scoreTarget,
	}
end

-- Placeholder until the reward-rate work lands: credits the kill quest and nothing else, so no
-- economy is changed by these modes before the per-minute baseline has been measured.
local function awardResult(player, rank)
	QuestService.Progress(player, "matches", 1)
	return { rank = rank, crate = nil, coins = 0, xp = 0, pending = true }
end

local respawnBehaviour = {
	StartWorld = startWorld,
	StopWorld = stopWorld,
	OnDeath = onDeath,
	OnRespawn = respawnPlayer,
	PlaceAtStart = placeAtStart,
	EnrolBot = enrolBot,
	BotSpawnCFrame = botSpawnCFrame,
	RankOf = rankOf,
	Results = results,
	AwardResult = awardResult,
	Broadcast = function()
		return {
			scores = { scores[1], scores[2] },
			target = current.scoreTarget,
			secondsLeft = GameMode.SecondsLeft(),
			hillStatus = current.id == "KingOfTheHill" and hillStatus or nil,
			hillHolder = current.id == "KingOfTheHill" and hillHolder or nil,
		}
	end,
}

local function wrap(definition)
	local mode = setmetatable(table.clone(respawnBehaviour), { __index = definition })
	return mode
end

GameMode.TeamDeathmatch = wrap(GameModes.Modes.TeamDeathmatch)
GameMode.KingOfTheHill = wrap(GameModes.Modes.KingOfTheHill)

local byId = {
	BattleRoyale = GameMode.BattleRoyale,
	TeamDeathmatch = GameMode.TeamDeathmatch,
	KingOfTheHill = GameMode.KingOfTheHill,
}

-- Which mode this match runs. The lobby vote decides it: `modeId` is what the vote resolved to.
-- nil -- no countdown, a probe, a server that started mid-match -- falls back to the rotation this
-- function has always used, and so does an id that is not a mode, because a bad id must not throw
-- inside startMatch.
function GameMode.Resolve(matchNumber, modeId)
	local definition = modeId and GameModes.Get(modeId) or nil
	if not definition then
		definition = GameModes.FromRotation(matchNumber or 1)
	end
	current = byId[definition.id] or GameMode.BattleRoyale
	return current
end

function GameMode.Get(id)
	return byId[id]
end

-- Passthrough so MatchService needs one require, not two.
function GameMode.AllowsEvent(mode, event)
	return GameModes.AllowsEvent(mode, event)
end

-- A player who leaves mid-match takes their team slot with them.
Players.PlayerRemoving:Connect(function(player)
	ModeTeams.Forget(player)
end)

-- Kept so a probe can drive the driver without a match: the same functions, named.
GameMode.Internal = {
	onDeath = onDeath,
	-- Test-only seams (tools/respawn_probe.lua). THE SHIPPED FUNCTIONS, never copies of them: a
	-- Studio Run-mode window has no Player, so the respawn path could not be reached at all, and
	-- that is how this shipped unproven twice. Nothing in the game reads these.
	place = place,
	respawnPlayer = respawnPlayer,
	retireBot = retireBot,
	spawnReplacementBot = spawnReplacementBot,
	confirmPlaced = confirmPlaced,
	confirmDelay = CONFIRM_DELAY,
	startWorld = startWorld,
	stopWorld = stopWorld,
	rankOf = rankOf,
	leader = leader,
	nowMs = nowMs,
}

-- Unused but required so the module's dependency on the run loop is explicit for anything that
-- later wants a Heartbeat tick rather than a task.wait loop.
GameMode.Heartbeat = RunService.Heartbeat
GameMode.BaseWalkSpeed = MatchConfig.BaseWalkSpeed

return GameMode
