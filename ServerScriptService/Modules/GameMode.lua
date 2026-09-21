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

local PAD_RETRY_DELAY = 1
local PAD_RETRIES = 4

local function padBonus()
	if current.id == "KingOfTheHill" then
		return ModeKingOfTheHill.PadBonus()
	end
	return nil
end

-- Puts a body on a pad, now. When every pad is refused (an enemy within 90 studs of each, or in
-- sight of it) the least bad one — furthest from the nearest enemy — is taken at once, under spawn
-- protection. It used to wait a second and ask again, up to four times: but LoadCharacter stands
-- a fresh body on the LOBBY's spawn pad, so a player who had just died watched the lobby for up
-- to four seconds and then got yanked to the arena (Oliver's "it respawned me in the lobby").
-- The retry loop only remains for the case of no pads at all (the arena not built).
local function place(token, character, attempt)
	if ModeTeams.PlaceAt(token, character, padBonus(), true) then
		return true
	end
	if (attempt or 1) >= PAD_RETRIES then
		local team = ModeTeams.TeamOf(token) or ModeTeams.Assign(token)
		local pad = ModeTeams.PickPad(team) or select(1, ModeTeams.Arena())
		character:PivotTo(CFrame.new(pad + Vector3.new(0, 4, 0)))
		return true
	end
	task.delay(PAD_RETRY_DELAY, function()
		if running and character.Parent then
			place(token, character, (attempt or 1) + 1)
		end
	end)
	return false
end

-- A player's respawn. Reached from MatchService.OnCharacterAdded's existing early return, which
-- is the ONLY path a respawned participant takes.
local function respawnPlayer(player, character)
	if not running or not host.IsParticipant(player) then
		return
	end
	ModeTeams.GrantLoadout(player)
	place(player, character, 1)
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
	local centre = select(1, ModeTeams.Arena())
	BotService.Spawn(1, function()
		local pad = ModeTeams.PickPad(team, padBonus())
		return CFrame.new((pad or centre) + Vector3.new(0, 4, 0))
	end, function(bot, humanoid)
		if not running or generation ~= myGeneration then
			return
		end
		ModeTeams.Assign(bot)
		-- Forced onto the side that just lost one, so the sides stay level.
		local assigned = ModeTeams.TeamOf(bot)
		if assigned ~= team then
			ModeTeams.Forget(bot)
			ModeTeams.Assign(bot)
		end
		host.AddCombatant(bot, humanoid)
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
	elseif victimTeam then
		retireBot(token)
		local myGeneration = generation
		task.delay(current.respawnDelay or 5, function()
			if running and generation == myGeneration then
				spawnReplacementBot(victimTeam)
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
local function placeAtStart(player, character, index)
	ModeTeams.Assign(player)
	ModeTeams.GrantLoadout(player)
	place(player, character, 1)
	announce(StateSync.Notify, player, string.format("%s — %s", current.name,
		GameModes.TeamName(ModeTeams.TeamOf(player) or 1)))
	return index
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

-- Which mode this match runs. Rotation for now; a lobby vote is designed separately and will feed
-- the same function.
function GameMode.Resolve(matchNumber)
	local definition = GameModes.FromRotation(matchNumber or 1)
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
