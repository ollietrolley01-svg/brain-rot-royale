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
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))
local ModeKingOfTheHill = require(script.Parent:WaitForChild("ModeKingOfTheHill"))
local ModeTeams = require(script.Parent:WaitForChild("ModeTeams"))
local LootService = require(script.Parent:WaitForChild("LootService"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local RewardService = require(script.Parent:WaitForChild("RewardService"))
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

-- Whether a combatant is dead and waiting for a respawn pad. MatchService.IsAlive says no for them:
-- a corpse cannot fire, cannot drop its kit at its own feet, and its companion does not fight.
function GameMode.IsDowned(token)
	return ModeTeams.IsDowned(token)
end

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

-- The last state sent: KOTH ticks four times a second, and an unchanged state isn't sent again.
local lastPushed = nil
local function pushState()
	local key = table.concat({ tostring(current.id), tostring(scores[1]), tostring(scores[2]),
		tostring(GameMode.SecondsLeft()), tostring(hillStatus), tostring(hillHolder) }, "|")
	if key == lastPushed then
		return
	end
	lastPushed = key
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
-- Team-mode rewards: what everyone did this match (MatchConfig.TeamModeRewards)
--------------------------------------------------------------------------------

-- One ledger per combatant, players and bots alike (a bot's counts are only there so it can beat a
-- player to MVP; a bot is a new token every life, so its ledger is one life's). Plain strong tables,
-- cleared when the next match starts, NOT when this one stops: the payout reads them after StopWorld.
local ledgers = {}
-- [victim] = { [attacker] = { amount, at } }: recent damage, for assists. Wall-clock milliseconds.
local damageLog = {}
-- [token] = whoever last killed them, for revenge.
local lastKiller = {}
-- [token] = true for each team's MVP, decided in stopWorld while the teams still exist.
local mvps = {}

local TEAM_RULES = MatchConfig.TeamModeRewards or {}
local MOVE_STUDS = ProgressionData.Playtime and ProgressionData.Playtime.MoveStuds or 4
-- The battle royale's multi-kill callouts (MatchService STREAK_LABELS), so a team mode's banners read the
-- same. tools/team_rewards_check.py fails if the two tables drift apart.
local STREAK_LABELS = {
	[2] = "DOUBLE KILL",
	[3] = "TRIPLE KILL",
	[4] = "QUAD KILL",
	[5] = "RAMPAGE",
}
local killStreak = Remotes.Event("KillStreak")

local function ledgerOf(token)
	local ledger = ledgers[token]
	if not ledger then
		ledger = {
			playerKills = 0, botKills = 0, assists = 0, revenges = 0, streakCoins = 0,
			captures = 0, holdSeconds = 0, defends = 0, deaths = 0,
			samples = 0, activeSamples = 0,
			streakCount = 0, streakAt = 0,
			isPlayer = Combatants.IsPlayer(token),
			name = Combatants.GetName(token),
		}
		ledgers[token] = ledger
	end
	local team = ModeTeams.TeamOf(token)
	if team then
		ledger.team = team
	end
	return ledger
end

-- Damage one combatant did to another, for assists and for "active" (`busySince`: something this player
-- did since the last participation check that counts as playing even without moving). Registered once;
-- does nothing outside a running team match (`running` is only ever set by a respawn mode's startWorld).
CombatService.OnDamage(function(attacker, victim, dealt)
	if not running or attacker == nil or victim == nil or attacker == victim or (dealt or 0) <= 0 then
		return
	end
	local log = damageLog[victim]
	if not log then
		log = {}
		damageLog[victim] = log
	end
	local entry = log[attacker]
	if not entry then
		entry = { amount = 0, at = 0 }
		log[attacker] = entry
	end
	entry.amount += dealt
	entry.at = nowMs()
	ledgerOf(attacker).busySince = true
end)

-- A death, credited. Enemy kills only: a team-mate cannot be shot (DamageVeto), and dying to the world
-- pays nobody. Called from onDeath before the death is scored or announced.
local function creditDeath(token, killerToken, victimTeam, killerTeam)
	local victim = ledgerOf(token)
	victim.deaths += 1
	victim.streakCount = 0
	local log = damageLog[token]
	damageLog[token] = nil

	if not killerToken or killerToken == token or not killerTeam or not victimTeam or killerTeam == victimTeam then
		return
	end
	local now = nowMs()
	local killer = ledgerOf(killerToken)
	if Combatants.IsBot(token) then
		killer.botKills += 1
	else
		killer.playerKills += 1
	end

	-- Multi-kills, the battle royale's streak: kills within the window of the one before escalate.
	local streak = TEAM_RULES.streak or {}
	local window = (streak.windowSeconds or 8) * 1000
	killer.streakCount = (now - killer.streakAt <= window) and killer.streakCount + 1 or 1
	killer.streakAt = now
	local step = math.min(killer.streakCount, streak.max or 5)
	local label = STREAK_LABELS[step]
	if label then
		killer.streakCoins += step * (streak.coinsPerStep or 50) - (streak.coinsPerStep or 50)
		if Combatants.IsPlayer(killerToken) then
			announce(function()
				killStreak:FireClient(killerToken, label, killer.streakCount)
			end)
		end
	end

	if lastKiller[killerToken] == token then
		killer.revenges += 1
		lastKiller[killerToken] = nil
	end
	lastKiller[token] = killerToken

	-- Objective Capture: an enemy killed standing on an objective the killer's team owns.
	if current.id == "KingOfTheHill" then
		local root = Combatants.GetRoot(token)
		local _, owner = ModeKingOfTheHill.ObjectiveAt(root and root.Position)
		if owner == killerTeam then
			killer.defends += 1
		end
	end

	-- Assists: everyone else on the killer's side who did enough damage recently.
	local assist = TEAM_RULES.assist or {}
	for attacker, entry in pairs(log or {}) do
		if attacker ~= killerToken and entry.amount >= (assist.minDamage or 25)
			and now - entry.at <= (assist.windowSeconds or 10) * 1000
			and ModeTeams.TeamOf(attacker) == killerTeam then
			local helper = ledgerOf(attacker)
			helper.assists += 1
		end
	end
end

-- A fresh body is never "movement" and carries no damage from the last life.
local function noteRespawn(token)
	local ledger = ledgers[token]
	if ledger then
		ledger.lastPos = nil
	end
	damageLog[token] = nil
end

-- Objective Capture's per-tick presence (ModeKingOfTheHill.Tick's fifth return): captures and time on
-- an objective your team owns. Taking one, or holding one that is contested, is playing even standing
-- still (a defender behind cover), so it counts as active for the participation check; standing alone on
-- an objective nobody is attacking does not.
local function creditObjectives(presence, seconds)
	for _, objective in ipairs(presence or {}) do
		for token, team in pairs(objective.inside or {}) do
			local ledger = ledgerOf(token)
			if objective.capturedBy == team then
				ledger.captures += 1
				ledger.busySince = true
			end
			if objective.status == "Contested" then
				ledger.busySince = true
			end
			if objective.owner == team then
				ledger.holdSeconds += seconds
			end
		end
	end
end

-- One participation check for a player (the PlaytimeService rule, per life).
local function sampleActivity(player)
	local ledger = ledgerOf(player)
	ledger.samples += 1
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local active
	if ModeTeams.IsDowned(player) or not humanoid or humanoid.Health <= 0 or not root then
		active = ledger.lastActive == true
		ledger.lastPos = nil
	else
		local position = root.Position
		active = (ledger.lastPos ~= nil and (position - ledger.lastPos).Magnitude >= MOVE_STUDS) or ledger.busySince == true
		ledger.lastPos = position
		ledger.lastActive = active
	end
	ledger.busySince = false
	if active then
		ledger.activeSamples += 1
	end
end

local function isAfk(ledger)
	local share = (TEAM_RULES.participation and TEAM_RULES.participation.minActiveShare) or 0.5
	return ledger.samples > 0 and ledger.activeSamples < ledger.samples * share
end

-- Each team's MVP: the best performance value (RewardService.TeamPerformanceValue, before caps), at least
-- mvp.minCoins, never an idle player. Ties go to fewer deaths, then the name, so it never depends on
-- table order. A bot can win it, and then no player on that team is paid for it.
local function pickMvps()
	table.clear(mvps)
	local best = {}
	for token, ledger in pairs(ledgers) do
		local team = ledger.team
		if team and not (ledger.isPlayer and isAfk(ledger)) then
			local value = RewardService.TeamPerformanceValue(ledger)
			local holder = best[team]
			if not holder or value > holder.value
				or (value == holder.value and (ledger.deaths < holder.ledger.deaths
					or (ledger.deaths == holder.ledger.deaths and tostring(ledger.name) < tostring(holder.ledger.name)))) then
				best[team] = { token = token, value = value, ledger = ledger }
			end
		end
	end
	local floor = (TEAM_RULES.mvp and TEAM_RULES.mvp.minCoins) or 0
	for _, holder in pairs(best) do
		if holder.value >= floor then
			mvps[holder.token] = true
		end
	end
	return mvps
end

-- What the payout reads for one player.
local function summaryFor(token)
	local ledger = ledgers[token] or {}
	return {
		playerKills = ledger.playerKills, botKills = ledger.botKills, assists = ledger.assists,
		revenges = ledger.revenges, streakCoins = ledger.streakCoins, captures = ledger.captures,
		holdSeconds = ledger.holdSeconds, defends = ledger.defends,
		activeSamples = ledger.activeSamples, samples = ledger.samples,
		mvp = mvps[token] == true,
		afk = ledger.samples ~= nil and isAfk(ledger),
	}
end

local function resetLedgers()
	table.clear(ledgers)
	table.clear(damageLog)
	table.clear(lastKiller)
	table.clear(mvps)
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
	noteRespawn(player)
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
		-- Onto the side that just lost one while the sides are level; onto the smaller side when they
		-- aren't (a player quit), so a short team is made up rather than staying short all match.
		local counts = ModeTeams.Counts()
		if counts[1] ~= counts[2] then
			ModeTeams.Assign(bot)
		else
			ModeTeams.AssignTo(bot, team)
		end
		-- The gun SpawnLoadout just issued: a death drops the held gun only if it is a different one
		-- (MatchService.dropPickedUp, Oliver's #124).
		bot.issuedWeaponId = bot.weapon and bot.weapon.id or nil
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

	-- Rewards bookkeeping (kills, assists, streaks, revenge, defends) while both teams are still known.
	-- Protected: a bookkeeping error must never stop the death being scored and the respawn scheduled.
	local credited, creditError = pcall(creditDeath, token, killerToken, victimTeam, killerTeam)
	if not credited then
		warn("[GameMode] team reward bookkeeping failed: " .. tostring(creditError))
	end

	ModeTeams.MarkDown(token)

	if Combatants.IsPlayer(token) then
		if token.Parent then
			-- State first: the loadout is cleared here so the corpse carries nothing and the
			-- respawn grants a clean kit.
			local delay = current.respawnDelay or 5
			local myGeneration = generation
			-- For the death recap's countdown, "DOWNED BY <name> — BACK IN n" (#86 M32). The recap itself
			-- is CombatService's and has gone out already by now (HandleDeath sends it before the death
			-- reaches a mode), so the time rides beside it on the player. Server time: the client reads it
			-- against workspace:GetServerTimeNow(), the same clock.
			token:SetAttribute("RespawnAt", workspace:GetServerTimeNow() + delay)
			task.delay(delay, function()
				if token.Parent then
					token:SetAttribute("RespawnAt", nil)
				end
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
			killerUserId = killerToken and Combatants.GetUserId(killerToken) or nil,
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

-- Oliver, 2026-09-23 14:32: "make sure that the loot regenerates over the course of the round like
-- every minute or so". Every 60 s each base is refilled to its full stock.
local BASE_RESTOCK = 60

local function startWorld(mapInfo)
	-- No storm. Stop() sets the broadcast status to "Idle", which is what makes the HUD's storm
	-- line and the client's ring disappear on their own with no client change at all.
	StormService.Stop()

	scores[1], scores[2] = 0, 0
	hillStatus, hillHolder = "Open", nil
	resetLedgers()
	generation += 1
	running = true
	deadlineMs = nowMs() + (current.timeLimit or 480) * 1000

	local centre, radius = ModeTeams.Setup(current, mapInfo)

	-- Base loot (Oliver, 2026-09-23: "way more loot around the spawns of the teams"). Each base is
	-- stocked at the start and refilled to full every BASE_RESTOCK seconds while the match runs, so
	-- whoever respawns later still finds something at home. Off the main thread: seeding yields.
	local stockGeneration = generation
	task.spawn(function()
		while running and generation == stockGeneration do
			for team = 1, GameModes.TeamCount do
				local base = ModeTeams.BaseOf(team)
				if base then
					local have = LootService.CountNear(base, LootService.BaseRadius)
					for kind, want in pairs(LootService.BaseStock) do
						local missing = want - (have[kind] or 0)
						if missing > 0 then
							local inner = kind == "chest" and 20 or 10
							local gap = kind == "chest" and 14 or 6
							LootService.SeedAt(ModeTeams.BaseLootSpots(team, missing, inner, LootService.BaseRadius - 5, gap, kind), kind)
						end
					end
				end
			end
			task.wait(BASE_RESTOCK)
		end
	end)

	-- The arena boundary: a circle that never shrinks, drawn through the storm's own broadcast so
	-- the ring, the minimap circle and the bots' rotation logic all work with nothing new.
	if current.bounds and StormService.StartStatic then
		StormService.StartStatic(centre, radius, 4, "Stay in the arena")
	end

	if current.id == "KingOfTheHill" then
		ModeKingOfTheHill.Start(current, mapInfo)
	end

	CombatService.DamageVeto = ModeTeams.DamageVeto
	CombatService.RespawnDelay = current.respawnDelay or 5
	CombatService.OnShot = ModeTeams.BreakProtection

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
				-- Objective Capture: every objective a team owns scores it a point a second.
				local team, status, _, scoring, presence = ModeKingOfTheHill.Tick()
				hillHolder, hillStatus = team, status
				local credited, creditError = pcall(creditObjectives, presence, KOTH_TICK)
				if not credited then
					warn("[GameMode] objective reward bookkeeping failed: " .. tostring(creditError))
				end
				accumulated += KOTH_TICK
				if accumulated >= 1 then
					accumulated -= 1
					for _, owner in ipairs(scoring or {}) do
						addScore(owner, 1)
						-- The first owner's point can finish the match (FinishNow runs synchronously);
						-- nothing may score, or be broadcast, after the results were taken.
						if not running then
							return
						end
					end
				end
			end
			if nowMs() >= deadlineMs then
				GameMode.FinishNow()
				return
			end
			pushState()
		end
	end)

	-- Participation: every player in the match checked every sampleSeconds for being active
	-- (sampleActivity). Wall-clock task.wait, one loop per match generation.
	task.spawn(function()
		local every = (TEAM_RULES.participation and TEAM_RULES.participation.sampleSeconds) or 15
		while running and generation == myGeneration do
			task.wait(every)
			if not running or generation ~= myGeneration then
				return
			end
			for _, player in ipairs(Players:GetPlayers()) do
				if host.IsParticipant(player) then
					local ok, err = pcall(sampleActivity, player)
					if not ok then
						warn("[GameMode] participation check failed: " .. tostring(err))
					end
				end
			end
		end
	end)

	pushState()
	return centre, radius
end

local function stopWorld()
	running = false
	generation += 1
	-- MVPs now, while ModeTeams still knows the sides; the payout runs after Teardown.
	local picked, pickError = pcall(pickMvps)
	if not picked then
		warn("[GameMode] MVP pick failed: " .. tostring(pickError))
	end
	CombatService.DamageVeto = nil
	CombatService.RespawnDelay = nil
	CombatService.OnShot = nil
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
	announce(StateSync.Notify, player, string.format("%s — you're on %s. Teammates are green, enemies red.", current.name,
		string.upper(GameModes.TeamName(ModeTeams.TeamOf(player) or 1))))
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

-- A list of { team, name }, never a sparse array: a remote drops a table indexed [2] with no [1].
local function mvpNames()
	local names = {}
	for token in pairs(mvps) do
		local ledger = ledgers[token]
		if ledger and ledger.team then
			table.insert(names, { team = ledger.team, name = ledger.name })
		end
	end
	table.sort(names, function(a, b)
		return a.team < b.team
	end)
	return names
end

local function results()
	return {
		mode = current.id,
		scores = { scores[1], scores[2] },
		teams = { GameModes.TeamName(1), GameModes.TeamName(2) },
		winner = leader(),
		target = current.scoreTarget,
		-- Each team's MVP by name (pickMvps), for the card. A team nobody earned it on has no entry.
		mvps = mvpNames(),
	}
end

-- The team-mode payout (Oliver, 2026-09-23 16:10: "theres no rewards for the team gamemodes!"): a crate,
-- coins and pass XP for a win, a draw or a loss, and since 2026-09-24 ("improve the rewards for team gamemodes
-- too") everything the player did, itemised: kills, assists, multi-kills, revenge, objectives, MVP and time
-- played (MatchConfig.TeamModeRewards, RewardService.TeamBreakdown). MatchService's live kill path pays 0
-- now (killScale) and only counts the kill; the kill is paid here, on the card.
local function awardResult(player, rank)
	-- From the rank MatchService read before StopWorld: the team table is cleared by then, so TeamOf
	-- here was nil for everyone and every winner was paid as a loss. Rank 1 is the winning team.
	local winner = leader()
	local outcome = winner == nil and "draw" or (rank == 1 and "win" or "loss")
	local ok, reward = pcall(RewardService.AwardTeamResult, player, outcome, rank, summaryFor(player))
	if not ok then
		warn("[GameMode] team reward failed for " .. player.Name .. ": " .. tostring(reward))
		return { rank = rank, coins = 0, xp = 0 }
	end
	return reward
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
	-- The team-mode rewards' bookkeeping (tools/team_rewards_check.py drives these, the shipped ones).
	creditDeath = creditDeath,
	creditObjectives = creditObjectives,
	noteRespawn = noteRespawn,
	sampleActivity = sampleActivity,
	pickMvps = pickMvps,
	summaryFor = summaryFor,
	resetLedgers = resetLedgers,
	awardResult = awardResult,
	ledgers = ledgers,
	streakLabels = STREAK_LABELS,
}

-- Unused but required so the module's dependency on the run loop is explicit for anything that
-- later wants a Heartbeat tick rather than a task.wait loop.
GameMode.Heartbeat = RunService.Heartbeat
GameMode.BaseWalkSpeed = MatchConfig.BaseWalkSpeed

return GameMode
