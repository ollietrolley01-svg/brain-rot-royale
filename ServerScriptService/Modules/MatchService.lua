-- The battle royale state machine: Waiting -> Countdown -> InProgress -> Results.
--
-- Placement is assigned at the moment of death: with N combatants still alive, the one who
-- dies takes rank N. The last standing takes rank 1. Bots fill the lobby up to the cap, so
-- placements stay meaningful on a quiet server — they occupy ranks but never earn rewards.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local BotService = require(script.Parent:WaitForChild("BotService"))
local DeathFxService = require(script.Parent:WaitForChild("DeathFxService"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local Combatants = require(script.Parent:WaitForChild("Combatants"))
local CompanionService = require(script.Parent:WaitForChild("CompanionService"))
local EasterEggs = require(script.Parent:WaitForChild("EasterEggs"))
local LobbyService = require(script.Parent:WaitForChild("LobbyService"))
local LootService = require(script.Parent:WaitForChild("LootService"))
local MapGenerator = require(script.Parent:WaitForChild("MapGenerator"))
local Monetization = require(script.Parent:WaitForChild("Monetization"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local MatchEvents = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MatchEvents"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local RewardService = require(script.Parent:WaitForChild("RewardService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local StormService = require(script.Parent:WaitForChild("StormService"))
local SupplyDropService = require(script.Parent:WaitForChild("SupplyDropService"))
local VendorService = require(script.Parent:WaitForChild("VendorService"))
local VoteService = require(script.Parent:WaitForChild("VoteService"))
local TeamPicker = require(script.Parent:WaitForChild("TeamPicker"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))
-- S1. The mode table this file consults; it never consults this file back. Required after
-- BotService and CombatService above, which GameMode also requires — neither of those requires
-- MatchService at its top level, so there is no cycle.
local GameMode = require(script.Parent:WaitForChild("GameMode"))

local MatchService = {}

local matchChanged = Remotes.Event("MatchChanged")
local killFeed = Remotes.Event("KillFeed")
local matchResults = Remotes.Event("MatchResults")
local spectate = Remotes.Event("Spectate")
local killStreak = Remotes.Event("KillStreak")
local bounty = Remotes.Event("Bounty")

local state = "Waiting"
local countdown = 0
-- True only during the window after the map is built and before anyone is placed, while players
-- pick where to land. Player -> Vector2 of the spot they picked, in world X/Z.
local dropSelect = false
-- True while the team picker is up (a team mode's Loading, the way dropSelect is the battle royale's).
local teamSelect = false
local chosenDrop = {}
local participants = {}
local alive = {}
-- #102: participants who pressed LEAVE on the spectator HUD this match. Still participants (see
-- LeaveSpectate), no longer spectators: IsSpectating and FocusTarget refuse them, and a second LEAVE is
-- refused rather than loading another body at the pier. Cleared when the match's tables are.
local leftSpectate = {}

-- The battle royale's AFK rule, the team modes' participation check (GameMode.sampleActivity) applied to
-- a placement: every `every` seconds of a running match each living player is checked for having moved
-- MoveStuds, hurt someone, been hurt, fired, reloaded or used an item since the last check (findings C2:
-- moving and hurting alone called a camper holding an angle, a looter and a healer idle). One active in fewer than minActiveShare of their checks
-- is paid the team modes' `afk` line instead of their placement -- a Ready player who never touches the
-- keyboard used to drop in, stand still and collect a placement crate and coins every match. A dead or
-- spectating player is not checked (their placement is already fixed), nor is anyone before their first
-- check (killed in the opening seconds is not idling). All of it in one table: this file is near the
-- local limit.
local afk = {
	players = {}, -- [player] = { samples, active, last = Vector3?, busy = bool }
	tick = 0,
	every = MatchConfig.TeamModeRewards.participation.sampleSeconds or 15,
	share = MatchConfig.TeamModeRewards.participation.minActiveShare or 0.5,
	moveStuds = require(Shared:WaitForChild("ProgressionData")).Playtime.MoveStuds,
}

function afk.record(player)
	local record = afk.players[player]
	if not record then
		record = { samples = 0, active = 0 }
		afk.players[player] = record
	end
	return record
end

function afk.sample(player)
	local record = afk.record(player)
	local root = Combatants.GetRoot(player)
	local position = root and root.Position
	-- With no earlier position there is nothing to have moved from: the first check only sets the
	-- baseline, unless they were already busy. Counting it idle made anyone killed between their first
	-- and second checks (a hot drop's fight) AFK.
	if record.last == nil and not record.busy then
		record.last = position
		return
	end
	local moved = position ~= nil and record.last ~= nil and (position - record.last).Magnitude >= afk.moveStuds
	record.samples += 1
	if moved or record.busy then
		record.active += 1
	end
	record.last = position
	record.busy = false
end

-- Nobody dead is checked again, so a fight since their last check (it set `busy`) counts as one more
-- active check at their elimination.
function afk.settle(player)
	local record = afk.players[player]
	if record and record.busy then
		record.samples += 1
		record.active += 1
		record.busy = false
	end
end

function afk.isIdle(player)
	local record = afk.players[player]
	return record ~= nil and record.samples > 0 and record.active < record.samples * afk.share
end

-- A placement's pay: the real one, or for an idle player only the `afk` line (no crate, no placement
-- coins, no match, win or quest progress). Same shape as a team mode's card, so the results screen lists it.
function afk.award(player, rank)
	if not afk.isIdle(player) then
		return RewardService.AwardPlacement(player, rank)
	end
	local rules = MatchConfig.TeamModeRewards.afk or {}
	local coins = RewardService.AddCoins(player, rules.coins or 0)
	local xp = rules.xp or 0
	require(script.Parent:WaitForChild("BattlePassService")).AddXp(player, xp)
	StateSync.Push(player)
	return {
		rank = rank,
		coins = coins,
		xp = xp,
		afk = true,
		lines = { { id = "result", label = "Away from keyboard", coins = coins, xp = xp } },
	}
end

-- Hurting someone is playing, even standing still (a camper holding an angle is not AFK); so is being
-- hurt by someone, and firing, reloading or using an item (WeaponService.NoteActivity).
function afk.busy(token)
	if state == "InProgress" and token ~= nil and participants[token] and Combatants.IsPlayer(token) then
		afk.record(token).busy = true
	end
end
CombatService.OnDamage(function(attacker, victim, dealt)
	-- Someone else's hit: not the storm (no attacker) and not your own splash.
	if (dealt or 0) > 0 and attacker ~= nil and attacker ~= victim then
		afk.busy(attacker)
		afk.busy(victim)
	end
end)
WeaponService.OnActivity = afk.busy

-- Players' out-of-combat regen, the bots' own rule (BotService: MatchConfig.BotRegenDelay seconds with no
-- damage taken or dealt, then BotRegenPerSecond, up to MaxHealth). Roblox's default character "Health"
-- script used to regenerate players 1% a second all match, storm and all; StarterCharacterScripts/Health
-- replaces it with nothing, and this is the whole of player regen now. Only for someone playing a running
-- match (MatchService.IsPlaying: not the lobby, not Loading, not downed), from the 1 s loop in Start.
local regen = {
	lastCombat = {}, -- [player] = tick() of the last damage taken or dealt
	lastHealth = {}, -- [player] = Health after the last step: any loss (storm, a fall) is combat too
	at = nil, -- tick() of the last step, so a late loop heals for the time that really passed
}

function regen.step(player, now, seconds)
	local humanoid = Combatants.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		regen.lastHealth[player] = nil
		return
	end
	local health = humanoid.Health
	local before = regen.lastHealth[player]
	if before and health < before then
		regen.lastCombat[player] = now
	end
	-- Never above MaxHealth, and never DOWN to it: a heal cap only ever raises health.
	if health < humanoid.MaxHealth and now - (regen.lastCombat[player] or 0) > MatchConfig.BotRegenDelay then
		health = math.min(humanoid.MaxHealth, health + MatchConfig.BotRegenPerSecond * seconds)
		humanoid.Health = health
	end
	regen.lastHealth[player] = health
end

function regen.forget(player)
	regen.lastCombat[player], regen.lastHealth[player] = nil, nil
end

-- Dealing damage, or a hit the shield soaked (health never moved), is combat as well.
CombatService.OnDamage(function(attacker, victim, dealt)
	if (dealt or 0) <= 0 or attacker == victim then
		return
	end
	local now = tick()
	for _, token in ipairs({ attacker, victim }) do
		if token ~= nil and Combatants.IsPlayer(token) then
			regen.lastCombat[token] = now
		end
	end
end)
local aliveCount = 0
-- How many combatants this match started with (startMatch, less any bot that failed to build): the
-- results card's "of N", which a leaver must not shrink.
local matchField = 0
local placements = {}
local deathConnections = {}
local baseSpeeds = {}
local mapInfo = nil
local matchId = 0
-- S2. Which mode this match runs. Battle royale until startMatch resolves otherwise, and every
-- battle-royale branch below is the original code wrapped in a condition, never moved out.
local currentMode = GameMode.BattleRoyale

-- Multi-kill callouts. Keyed explicitly rather than as an array with a nil first slot,
-- which would make the length operator undefined. A single kill announces nothing.
local STREAK_WINDOW = 8
-- Roblox's default gravity; a Low Gravity match halves it for the match and this puts it back.
local NORMAL_GRAVITY = 196.2
local STREAK_MAX = 5
local STREAK_LABELS = {
	[2] = "DOUBLE KILL",
	[3] = "TRIPLE KILL",
	[4] = "QUAD KILL",
	[5] = "RAMPAGE",
}
local streaks = {}

-- A bounty goes on the match's kill leader once they have a few kills: everyone is told who
-- they are, and whoever eliminates them collects. The reward grows with the leader's tally,
-- so the more dominant someone is, the more they're worth. Players only; bots never carry one.
local BOUNTY_MIN_KILLS = 3
local BOUNTY_BASE = 200
local BOUNTY_PER_KILL = 75
local bountyToken, bountyReward = nil, 0
-- This match's event (MatchEvents), rolled at start; nil for a plain match. Bounty Rush changes
-- the two bounty numbers below for the match.
local currentEvent = nil
local bountyMinKills, bountyMultiplier = BOUNTY_MIN_KILLS, 1

-- Set by Bootstrap: fires just before players are pulled out of the lobby, so social
-- systems (trades in progress) can shut themselves down.
MatchService.OnMatchStart = nil
MatchService.OnMatchEnd = nil
MatchService.OnMapBuilt = nil

local function countKeys(map)
	local total = 0
	for _ in pairs(map) do
		total += 1
	end
	return total
end

local function realPlayersAlive()
	local total = 0
	for token in pairs(alive) do
		if Combatants.IsPlayer(token) then
			total += 1
		end
	end
	return total
end

--------------------------------------------------------------------------------
-- Lobby
--------------------------------------------------------------------------------

local function buildLobby()
	local existing = workspace:FindFirstChild("Lobby")
	if existing then
		existing:Destroy()
	end

	local lobby = Instance.new("Model")
	lobby.Name = "Lobby"
	lobby.Parent = workspace

	local base = MatchConfig.LobbyPosition

	-- Rot Island: everything from the ground up is LobbyService's (see its header for the layout).
	LobbyService.Build(lobby, base)

	-- The spawn pad on the pier, where the island's spawn offset says.
	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Name = "LobbySpawn"
	spawnPad.Size = Vector3.new(LobbyService.SpawnHalfWidth * 2, 1, 22)
	spawnPad.CFrame = CFrame.new(base + LobbyService.SpawnOffset)
	spawnPad.Anchored = true
	spawnPad.Neutral = true
	spawnPad.Duration = 0
	spawnPad.Color = Color3.fromRGB(120, 200, 255)
	spawnPad.Material = Enum.Material.Neon
	spawnPad.Transparency = 0.35
	spawnPad.TopSurface = Enum.SurfaceType.Smooth
	spawnPad.Parent = lobby

	return lobby
end

-- Spawn on the pier, facing the island. Spawning anywhere in the middle used to drop people
-- onto the plinth or straight onto the ready pad, which readied them up without asking.
local function lobbyCFrame()
	local base = MatchConfig.LobbyPosition
	local spawn = base + LobbyService.SpawnOffset
	local position = spawn + Vector3.new(math.random(-LobbyService.SpawnHalfWidth + 2, LobbyService.SpawnHalfWidth - 2), 2.2, math.random(-8, 8))
	return CFrame.lookAt(position, Vector3.new(base.X, position.Y, base.Z))
end

function MatchService.PlaceInLobby(player)
	local character = player.Character
	if not character then
		return
	end

	-- Never teleport someone to where the lobby is supposed to be without checking it's
	-- actually there; the alternative is dropping them through empty space.
	if not workspace:FindFirstChild("Lobby") then
		warn("[MatchService] Lobby missing at spawn time — rebuilding.")
		buildLobby()
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		baseSpeeds[player] = MatchConfig.BaseWalkSpeed
		humanoid.WalkSpeed = MatchConfig.BaseWalkSpeed
		-- Plus a companion health boon already on this body (it can land on CharacterAdded first, as
		-- applyBoosts notes): a plain write wiped it, and unequipping later took it off base max HP.
		humanoid.MaxHealth = MatchConfig.StartHealth + CompanionService.BoonHealth(player, humanoid)
		humanoid.Health = MatchConfig.StartHealth
	end
	character:PivotTo(lobbyCFrame())
	WeaponService.Clear(player)
	WeaponService.Push(player)
end

--------------------------------------------------------------------------------
-- Broadcasting
--------------------------------------------------------------------------------

-- Only players who've readied up are pulled into a match; everyone else stays in the lobby as
-- long as they like. The flag is a player attribute, so the HUD reads it without a remote.
local function isReady(player)
	return player:GetAttribute("Ready") == true
end

local function readyPlayers()
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if isReady(player) then
			table.insert(list, player)
		end
	end
	return list
end

-- How many MatchChanged broadcasts have gone out. Read by tools/respawn_probe.lua: CombatClient's
-- handler treats each ARRIVAL as a state change and drops the sprint on every one that is not
-- InProgress, so this rate is the rate at which a held sprint dies in the lobby (Oliver's #82).
-- Never read by game code.
MatchService.BroadcastCount = 0

local function broadcast()
	MatchService.BroadcastCount += 1
	matchChanged:FireAllClients({
		state = state,
		countdown = math.max(0, math.floor(countdown)),
		dropSelect = dropSelect,
		teamSelect = teamSelect,
		readyCount = #readyPlayers(),
		aliveCount = aliveCount,
		participantCount = countKeys(participants),
		botCount = BotService.Count(),
		minPlayers = MatchConfig.MinPlayers,
		maxPlayers = MatchConfig.MaxPlayers,
		playerCount = #Players:GetPlayers(),
		mapName = mapInfo and mapInfo.mapName or nil,
		mapRadius = mapInfo and mapInfo.radius or nil,
		event = MatchEvents.Describe(currentEvent),
		-- S3. The mode rides as a FIELD, never as a new state string: the HUD banner, CombatClient,
		-- MovementClient, ProjectileClient and TouchControls all gate on `state`, and an
		-- unrecognised value there would break them quietly.
		mode = currentMode.id,
		modeState = currentMode.Broadcast and currentMode.Broadcast() or nil,
	})
end

-- UserId -> when they last toggled (a Player key in a weak table can drop out while they're
-- still here).
local lastReadyToggle = {}

-- Can be toggled at any time; it decides who joins the *next* match, never the one in progress.
-- Throttled, because every change is broadcast to the whole server.
function MatchService.SetReady(player, value)
	-- Wall time: only this throttle reads it, and os.clock is CPU time in Roblox.
	local now = tick()
	if lastReadyToggle[player.UserId] and now - lastReadyToggle[player.UserId] < 0.3 then
		return
	end
	lastReadyToggle[player.UserId] = now

	-- Not while a match is loading: the HUD already refuses, but the lobby's ready pad did not, and a
	-- lobby player stepping on it during the drop window got the full drop picker and its cursor claim
	-- for a match they are not in (logic review #24).
	if value and state == "Loading" then
		return
	end
	if isReady(player) == value then
		return
	end
	player:SetAttribute("Ready", value)
	broadcast()
end

function MatchService.IsParticipant(player)
	return participants[player] == true
end

-- #102: the client's spectator cycle (CombatClient.livingCharacters) reads `InMatch` off each Player to
-- skip lobby idlers, mid-match joiners and anyone who has left. Written for EVERYONE present, true or
-- FALSE -- never left unset -- because the client treats an absent attribute as "in", so the read stays
-- inert wherever the write has not happened and a player who was never tagged would otherwise show up
-- in every spectator's cycle. Takes the list rather than asking Players itself so the probe can hand it
-- stand-ins. Bots have no Player and are always candidates on the client.
local function tagInMatch(everyone)
	for _, player in ipairs(everyone) do
		player:SetAttribute("InMatch", participants[player] == true)
	end
end

function MatchService.IsAlive(player)
	-- A respawn mode keeps alive[] set through the 5 s wait (that is what routes the next body back
	-- to a pad), but a dead player is not alive to anything that asks here: DropSlot dumped the whole
	-- kit at the corpse on every death (Bootstrap's handler asks IsAlive), and the companion kept
	-- fighting for a corpse (logic review #12).
	if alive[player] ~= true then
		return false
	end
	return not (currentMode.respawn and GameMode.IsDowned(player))
end

-- Alive in a match that is actually being played: InProgress, not Loading. startMatch marks everyone
-- alive before it places them, so IsAlive alone let the drop-in window use items and dump the kit
-- (Bootstrap's DropSlot and UseSelected ask this).
function MatchService.IsPlaying(player)
	return state == "InProgress" and MatchService.IsAlive(player)
end

-- Is this player WATCHING the match rather than playing it?
--
-- One predicate, in one place, because two copies of it is exactly how the exit below and
-- Bootstrap's replication-focus guard would drift apart -- and they must agree, or a player can
-- leave spectating while the server still streams the match to them, or be refused an exit from a
-- state the focus guard thinks they are in.
--
-- A spectator is a PARTICIPANT of the running match who is no longer alive. Respawn modes never
-- spectate at all -- eliminate() returns at its `currentMode.respawn` branch, which sits ABOVE the
-- spectate fire -- so they are excluded by name here rather than by trusting that alive[] is never
-- cleared over there. If that branch ever moves, this stays correct.
function MatchService.IsSpectating(player)
	if currentMode and currentMode.respawn then
		return false
	end
	return participants[player] == true and not alive[player] and not leftSpectate[player]
end

-- #102: "theres no way to leave spectator mode." There was not. The Spectate remote had exactly two
-- fire sites -- true on elimination, false inside the match-reset loop -- so the ONLY exit was the
-- end of the match. No key, no button, no remote: the spectator HUD was a text label and a rounded
-- corner. This is the exit.
--
-- Leaving drops them to the lobby and does NOT let them back in (Oliver's call, taken knowing it):
-- re-entry needs a spectate-list UI that does not exist, and inventing one to support a button is
-- how scope doubles. The button says so.
--
-- They stay a PARTICIPANT on purpose. Their placement already stands, they are eliminated either
-- way, and leaving forfeits nothing they still had -- while staying in `participants` means the
-- match-end reset still respawns them with everybody else instead of leaving them the one player
-- the reset skips.
--
-- Returns whether they were actually spectating, so a stray remote is distinguishable from a real
-- exit rather than silently doing nothing.
--
-- And it ENDS spectating: `leftSpectate` takes them out of IsSpectating, which FocusTarget and this
-- function both ask. Before it, a player who had left was still "spectating" to the server -- they could
-- keep streaming the arena through SetReplicationFocus, and every LEAVE (the remote allows one a second)
-- loaded yet another body at the pier.
function MatchService.LeaveSpectate(player)
	if not MatchService.IsSpectating(player) then
		return false
	end
	leftSpectate[player] = true

	-- The client is told FIRST, and the order is load-bearing. setSpectating(false) is what tears
	-- the spectator camera down and hands the view back; doing it after LoadCharacter would race a
	-- brand-new body's camera against a spectator camera still pointed at somebody else, which is
	-- the same two-writers-one-property fault this item is already about.
	spectate:FireClient(player, false)
	-- Out of the match for good: not a spectator target for anyone else either (#102).
	player:SetAttribute("InMatch", false)

	-- Cleared here as well as by the client's own focus call, because that call is rate-limited
	-- (RateLimit "SetReplicationFocus") and may be applied a moment late. A player standing in the
	-- lobby must not still be streaming the arena.
	player.ReplicationFocus = nil

	-- LoadCharacter lands in OnCharacterAdded, where `alive[player]` is false, so it takes the
	-- lobby branch and PlaceInLobby puts them on Rot Island. Deliberately NOT calling PlaceInLobby
	-- here as well: two placements for one body is how a spawn ends up fighting itself.
	local ok = pcall(function()
		player:LoadCharacter()
	end)
	return ok
end

-- #102, the streaming half: which body a spectator may point replication at. Bootstrap's
-- SetReplicationFocus handler asks here -- one rule, next to IsSpectating and LeaveSpectate, which it
-- must agree with. The spectator test was always right; the TARGET test used to be "any combatant or
-- any Player's character", and Combatants.FromCharacter falls back to Players:GetPlayerFromCharacter,
-- so a lobby idler's body passed and a modified client could stream the arena from the lobby by naming
-- one. The target must be a combatant of THIS match who is alive in the server's own table -- a bot
-- token or a Player that alive[] says is standing. Returns the part to focus on, or nil.
function MatchService.FocusTarget(player, part)
	if not MatchService.IsSpectating(player) then
		return nil
	end
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") or part.Name ~= "HumanoidRootPart" or not part.Parent then
		return nil
	end
	local target = Combatants.FromCharacter(part.Parent)
	if not target or alive[target] ~= true then
		return nil
	end
	return part
end

function MatchService.GetState()
	return state
end

-- Every knob a match event turns, set from `event` (an empty table for a plain match). Called at
-- match start, and again by SetEvent when an admin puts an event on a running match.
local function applyEventKnobs(event)
	bountyMinKills = event.bountyMinKills or BOUNTY_MIN_KILLS
	bountyMultiplier = event.bountyMultiplier or 1
	LootService.ChestGuns = event.chestGuns or 2
	LootService.ChestRarityFloor = event.chestRarityFloor
	SupplyDropService.SetInterval(event.dropInterval, event.firstDrop)
	RewardService.PlacementMultiplier = event.placementMultiplier or 1
	CombatService.HeadshotScale = event.headshotMultiplier or 1
	StormService.SetSpeed(event.stormSpeed or 1)
	workspace.Gravity = NORMAL_GRAVITY * (event.gravity or 1)
end

-- Admin (#52): puts a match event on the RUNNING match by id, or clears it with nil. Validated
-- against MatchEvents and the mode's veto; refused outside a live match. Server-side only —
-- AdminService calls it after its own UserId gate; nothing here trusts a client. Everything an
-- event turns is re-applied at once (bounty, chests, supply drops, placement, headshots, storm
-- speed, gravity, lighting) and the HUD is told; the two things an event sets on a body at spawn —
-- the start shield and the speed multiplier baked into base speed — reach a player on their next
-- body. Returns true, or false and why not.
function MatchService.SetEvent(eventId)
	if state ~= "InProgress" then
		return false, "No match running."
	end
	local event = nil
	if eventId ~= nil then
		event = type(eventId) == "string" and MatchEvents.Get(eventId) or nil
		if not event then
			return false, "No such event."
		end
		if not GameMode.AllowsEvent(currentMode, event) then
			return false, "That event can't run in this mode."
		end
	end
	currentEvent = event
	applyEventKnobs(event or {})
	MapGenerator.ApplyLightingOverride(event and event.lighting or nil)
	broadcast()
	return true
end

--------------------------------------------------------------------------------
-- Boosts
--------------------------------------------------------------------------------

-- Permanent gamepasses always apply. Single-use consumables are spent here, at the moment
-- the match actually starts, so buying one and then leaving doesn't burn it.
-- What applyBoosts granted each player at the opening spawn, so a respawn body (a respawn mode's
-- second, third... body) gets the same max health and speed WITHOUT spending another consumable
-- (logic review #23). Overwritten every match start; cleared when the player leaves.
local grantedBoosts = {}

local function applyBoosts(player, humanoid)
	local data = PlayerData.Get(player)

	-- The passes, and at most one one-match boost per stat: the bigger of the pass and the boost
	-- applies, and a boost is spent only when it beats what the player already has, so a pass owner
	-- still gets the Pro boosts and keeps a regular one that would add nothing (GamepassConfig.PlanBoosts).
	local plan = GamepassConfig.PlanBoosts({
		ExtraHealth = Monetization.Owns(player, "ExtraHealth"),
		ExtraSpeed = Monetization.Owns(player, "ExtraSpeed"),
	}, data and data.Consumables, MatchConfig.StartHealth, MatchConfig.BaseWalkSpeed)
	local bonusHealth, bonusSpeed, speedScale = plan.health, plan.speed, plan.scale
	if data then
		for _, name in ipairs(plan.spend) do
			data.Consumables[name] -= 1
		end
		StateSync.Push(player)
	end

	grantedBoosts[player] = { health = bonusHealth, speed = bonusSpeed, scale = speedScale }
	-- Plus whatever a companion's health boon has already put on this body: the companion lands on
	-- CharacterAdded too, sometimes first, and a plain write here wiped its bonus for the whole life.
	humanoid.MaxHealth = MatchConfig.StartHealth + bonusHealth + CompanionService.BoonHealth(player, humanoid)
	humanoid.Health = humanoid.MaxHealth

	-- Remembered so sprinting can scale it without losing the gamepass bonus. A Rot Rush match
	-- scales the lot.
	baseSpeeds[player] = (MatchConfig.BaseWalkSpeed + bonusSpeed) * speedScale * (currentEvent and currentEvent.speedMultiplier or 1)
	humanoid.WalkSpeed = baseSpeeds[player]
end

-- The same numbers on a respawn body, from the record: nothing is spent, nothing is re-rolled. A
-- player with no record (joined a running respawn mode) gets the gamepass bonuses only.
local function reapplyBoosts(player, humanoid)
	local granted = grantedBoosts[player]
	local bonusHealth = granted and granted.health or (Monetization.Owns(player, "ExtraHealth") and GamepassConfig.PassHealth or 0)
	local bonusSpeed = granted and granted.speed or (Monetization.Owns(player, "ExtraSpeed") and GamepassConfig.PassSpeed or 0)
	local speedScale = granted and granted.scale or 1
	humanoid.MaxHealth = MatchConfig.StartHealth + bonusHealth + CompanionService.BoonHealth(player, humanoid)
	humanoid.Health = humanoid.MaxHealth
	baseSpeeds[player] = (MatchConfig.BaseWalkSpeed + bonusSpeed) * speedScale * (currentEvent and currentEvent.speedMultiplier or 1)
	humanoid.WalkSpeed = baseSpeeds[player]
end

-- Walk speed is base (gamepass bonus and match event included) × any active speed boost × sprint ×
-- slide. All of them are tracked here so none can overwrite another — a Speed Soda used mid-sprint
-- keeps the sprint, and letting go of sprint keeps the Soda. Everything is keyed by combatant token,
-- so bots go through exactly the same composition as players.
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))
local STAMINA = MovementConfig.Stamina
local SLIDE = MovementConfig.Slide
local CROUCH = MovementConfig.Crouch

local speedBoosts = {}
local sprinting = {}
-- token -> the CHARACTER that is crouching, not just true: a token whose body has been replaced (a
-- respawn) is standing again whatever was set for the old one.
local crouching = {}

-- Sliding. The server holds the CEILING: while a slide is on, applySpeed multiplies walk speed by
-- Slide.PeakMultiplier. A player's client shapes the real speed underneath it frame by frame (a
-- burst that bleeds off, faster downhill) and says when the slide ends, which drops the ceiling
-- early; the window only runs out on its own if the client never says. A bot has no client to shape
-- it, so it gets a short flat burst (Slide.BotWindow) instead. It stays a factor in here rather than a
-- WalkSpeed write because applySpeed recomputes the whole speed on every sprint toggle and boost.
local slides = {}

-- Stamina: a ledger per combatant token. Sprinting drains it while you're really moving, slides,
-- vaults and climbs cost chunks of it, and it refills after a short pause. Hitting zero exhausts you:
-- the sprint factor comes off here (whatever the client says) and slides and vaults are refused until
-- it's back to Stamina.ExhaustedUntil. It only counts for a participant in a running match; in the
-- lobby it stays full. A player's client predicts all of this for the HUD and is corrected over
-- StaminaSync, sent only to that player.
--
-- The character itself is simulated on its owner's client, so nothing here can stop a modified client
-- writing its own WalkSpeed. What the ledger guarantees is that the speed the server composes, and the
-- slide ceiling, obey stamina.
local stamina = {}
local staminaSync = Remotes.Event("StaminaSync")

-- For probes only (tools/movement_probe.lua): treat every token as in a running match, so the ledger
-- can be measured without starting one. The game never sets it.
MatchService.StaminaTestMode = false

local function staminaApplies(token)
	-- Not for a participant who pressed LEAVE while spectating: they are on a lobby body now.
	return MatchService.StaminaTestMode or (state == "InProgress" and participants[token] == true and not leftSpectate[token])
end

local function isRushing(token)
	local boost = speedBoosts[token]
	return boost ~= nil and boost.rush == true and os.clock() < boost.untilTime
end

local function ledger(token)
	local entry = stamina[token]
	if not entry then
		entry = { value = STAMINA.Max, exhausted = false, lastSpend = 0, syncedAt = 0, synced = STAMINA.Max, syncedFlags = "" }
		stamina[token] = entry
	end
	return entry
end

-- Tells a player's client its real stamina: at most four times a second while it changes, and at
-- once (`force`) on exhaustion, recovery, a refusal or a cost.
local function syncStamina(token, force)
	local entry = stamina[token]
	if not entry or not Combatants.IsPlayer(token) or not token.Parent then
		return
	end
	local now = os.clock()
	local rushing = isRushing(token)
	local flags = tostring(entry.exhausted) .. tostring(rushing)
	if force or (now - entry.syncedAt >= 0.25 and (math.abs(entry.value - entry.synced) >= 1 or flags ~= entry.syncedFlags)) then
		entry.syncedAt, entry.synced, entry.syncedFlags = now, entry.value, flags
		staminaSync:FireClient(token, math.floor(entry.value * 10 + 0.5) / 10, entry.exhausted, rushing)
	end
end

-- A bot's base speed when nobody has set one: MatchConfig.BotWalkSpeed, scaled by the match event the
-- same way a player's is (a Rot Rush used to reach players only).
local function defaultBaseSpeed(token)
	if Combatants.IsBot(token) then
		return (MatchConfig.BotWalkSpeed or MatchConfig.BaseWalkSpeed) * (currentEvent and currentEvent.speedMultiplier or 1)
	end
	return MatchConfig.BaseWalkSpeed
end

-- Status effects on speed (a CHILL slow, a haste), keyed per token by effect name so one effect
-- refreshing never touches another. Of everything active, the strongest slow and the strongest
-- speed-up apply (they don't stack with their own kind), so three chills are no worse than one.
local statusSpeeds = {}

local function statusFactor(token, now)
	local effects = statusSpeeds[token]
	if not effects then
		return 1
	end
	local slowest, fastest = 1, 1
	for key, effect in pairs(effects) do
		if now >= effect.untilTime then
			effects[key] = nil
		elseif effect.factor < slowest then
			slowest = effect.factor
		elseif effect.factor > fastest then
			fastest = effect.factor
		end
	end
	if next(effects) == nil then
		statusSpeeds[token] = nil
	end
	return slowest * fastest
end

local function applySpeed(player)
	local humanoid = Combatants.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local now = os.clock()
	local speed = baseSpeeds[player] or defaultBaseSpeed(player)
	local boost = speedBoosts[player]
	if boost and now < boost.untilTime then
		speed *= boost.multiplier
	end
	speed *= statusFactor(player, now)
	local entry = stamina[player]
	local slide = slides[player]
	local sliding = slide ~= nil and now < slide.untilTime
	-- A slide outranks a crouch: a body that crouched mid-slide would otherwise have its ceiling
	-- multiplied by both and end up slower than walking. (The client won't ask for it; a bot or a
	-- replayed remote could.)
	local down = not sliding and crouching[player] ~= nil and crouching[player] == humanoid.Parent
	if down then
		speed *= CROUCH.SpeedMultiplier
	elseif sprinting[player] and not (entry and entry.exhausted) then
		speed *= MatchConfig.SprintMultiplier
	end
	if sliding then
		speed *= SLIDE.PeakMultiplier
	end
	humanoid.WalkSpeed = speed
	-- Other players see the run (#89): GunPoseClient reads the Sprinting attribute.
	MovementService.SetSprintPose(humanoid, not down and not sliding and sprinting[player] ~= nil and not (entry and entry.exhausted))
end

-- A bounded number of calls per second per token and kind, for the movement remotes.
local rateBuckets = {}
local function withinRate(token, kind, perSecond)
	local key = kind
	local buckets = rateBuckets[token]
	if not buckets then
		buckets = {}
		rateBuckets[token] = buckets
	end
	local now = os.clock()
	local bucket = buckets[key]
	if not bucket or now - bucket.startedAt >= 1 then
		buckets[key] = { startedAt = now, count = 1 }
		return true
	end
	bucket.count += 1
	return bucket.count <= perSecond
end

-- The ground under a body, from the server's copy of its position: a ray down past the feet. Used
-- instead of Humanoid.FloorMaterial because a player's humanoid is simulated on their own client, and
-- the server's view of its FloorMaterial isn't something to build a rule on. `extra` studs of slack
-- below the feet (default 1.5) cover the server's position lagging a step behind.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true
groundParams.IgnoreWater = true
local function groundUnder(character, humanoid, root, extra)
	groundParams.FilterDescendantsInstances = { character }
	return workspace:Raycast(root.Position, Vector3.new(0, -(humanoid.HipHeight + root.Size.Y / 2 + (extra or 1.5)), 0), groundParams)
end

-- Standing on something. A bot's humanoid is simulated here, so its FloorMaterial is exact and costs
-- no ray (fifty sprinting bots were 500 rays a second); a player's body is simulated on their client,
-- so it is measured.
local function onGround(token, character, humanoid, root)
	if Combatants.IsPlayer(token) then
		return groundUnder(character, humanoid, root) ~= nil
	end
	return humanoid.FloorMaterial ~= Enum.Material.Air
end

local function tokenGone(token)
	if Combatants.IsPlayer(token) then
		return token.Parent == nil
	end
	local character = type(token) == "table" and token.character
	return not character or character.Parent == nil
end

-- Ten times a second: drain for anyone sprinting and moving, refill after the pause, flip exhaustion
-- both ways, and forget tokens that are gone. Only tokens that have a ledger entry are visited, and an
-- entry that's full, idle and synced is dropped again.
local STAMINA_TICK = 0.1
local pruneClock = 0
local function tickStamina(dt)
	local now = os.clock()
	for token, entry in pairs(stamina) do
		if tokenGone(token) then
			stamina[token] = nil
		elseif not staminaApplies(token) or isRushing(token) then
			-- Outside a match, or on a Soda's rush: full, and never exhausted.
			if entry.value < STAMINA.Max or entry.exhausted then
				entry.value, entry.exhausted = STAMINA.Max, false
				applySpeed(token)
				syncStamina(token, true)
			else
				syncStamina(token, false)
				-- Nothing left to track once the client has been told it's full and not rushing.
				local settled = entry.synced >= STAMINA.Max and entry.syncedFlags == "falsefalse"
				if not sprinting[token] and not isRushing(token) and (settled or not Combatants.IsPlayer(token)) then
					stamina[token] = nil
				end
			end
		else
			local draining = false
			if sprinting[token] and not entry.exhausted then
				local character = Combatants.GetCharacter(token)
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local velocity = root and root.AssemblyLinearVelocity
				-- Riding in a vehicle moves the root too, but isn't running; nor is flying through the air
				-- off a rocket, a pad or a glider with sprint still held or toggled on.
				draining = velocity ~= nil and humanoid ~= nil and not humanoid.Sit
					and Vector3.new(velocity.X, 0, velocity.Z).Magnitude > STAMINA.MovingSpeed
					and onGround(token, character, humanoid, root)
			end
			if draining then
				entry.value = math.max(entry.value - STAMINA.SprintDrainPerSecond * dt, 0)
				entry.lastSpend = now
				if entry.value <= 0 then
					entry.exhausted = true
					applySpeed(token)
					syncStamina(token, true)
				end
			elseif now - entry.lastSpend >= (entry.exhausted and STAMINA.ExhaustedRegenDelay or STAMINA.RegenDelay) then
				entry.value = math.min(entry.value + STAMINA.RegenPerSecond * dt, STAMINA.Max)
				if entry.exhausted and entry.value >= STAMINA.ExhaustedUntil then
					entry.exhausted = false
					applySpeed(token)
					syncStamina(token, true)
				end
			end
			syncStamina(token, false)
		end
	end

	-- Every few seconds, drop speed state left behind by bots that no longer exist (players are
	-- cleared in OnPlayerRemoving).
	pruneClock += dt
	if pruneClock >= 5 then
		pruneClock = 0
		for _, map in ipairs({ baseSpeeds, speedBoosts, sprinting, slides, rateBuckets, statusSpeeds, crouching }) do
			for token in pairs(map) do
				if not Combatants.IsPlayer(token) and tokenGone(token) then
					map[token] = nil
				end
			end
		end
	end
end

do
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated >= STAMINA_TICK then
			tickStamina(math.min(accumulated, 0.5))
			accumulated = 0
		end
	end)
end

-- Sprinting on or off. Returns whether the sprint is actually on: false while exhausted (the request
-- is remembered, and the sprint comes back by itself once stamina recovers, if it's still held).
function MatchService.SetSprinting(player, value)
	local wanted = value == true
	sprinting[player] = wanted or nil
	if wanted then
		ledger(player)
		-- Sprinting and crouching are exclusive, the way sprinting and aiming are.
		if crouching[player] then
			MatchService.SetCrouching(player, false)
		end
	end
	-- The latest request is always recorded; a client toggling absurdly fast just has the speed
	-- recomposed a moment later instead of on every toggle.
	if Combatants.IsPlayer(player) and not withinRate(player, "sprint", 20) then
		local buckets = rateBuckets[player]
		if not buckets.sprintDeferred then
			buckets.sprintDeferred = true
			task.delay(0.3, function()
				buckets.sprintDeferred = nil
				applySpeed(player)
			end)
		end
	else
		applySpeed(player)
	end
	local entry = stamina[player]
	return wanted and not (entry and entry.exhausted)
end

-- Crouching: a speed factor inside applySpeed and a real drop in height, so a crouched body is a
-- smaller target and fits under things a standing one doesn't. HipHeight is scaled here (which lowers
-- the whole rig, bots included, since they have no client of their own); the fold you see in the legs is
-- drawn per client by Shared/CrouchAnimation from the character's `Crouching` attribute.
--
-- Idempotent: setting the state it's already in returns immediately, so a bot can call it as often as it
-- likes. Nothing here touches the humanoid's state machine, and nothing runs per frame.
local function setHipHeight(humanoid, down)
	-- Reading the standing height off the humanoid at the first crouch is safe even though the client
	-- predicts the same drop locally: Humanoid properties are server-authoritative, and a client setting
	-- HipHeight on its own character changes only its own simulation. If that ever stopped being true,
	-- this would record the CROUCHED height as the base and the body would never stand back up.
	if humanoid:GetAttribute("BaseHipHeight") == nil then
		humanoid:SetAttribute("BaseHipHeight", humanoid.HipHeight)
	end
	local base = humanoid:GetAttribute("BaseHipHeight") or humanoid.HipHeight
	humanoid.HipHeight = down and math.max(base * CROUCH.HipScale, CROUCH.MinHipHeight) or base
end

-- The body is LOW while crouching and also while sliding. A slide that doesn't lower you is only a
-- burst of speed: getting under things is half of why you slide, and now that the slide is entered from
-- the crouch key the two want to read as one move. Both states go through here so neither can leave the
-- body standing while the other still wants it down.
local function updateHeight(token)
	local humanoid = Combatants.GetHumanoid(token)
	if not humanoid then
		return
	end
	local slide = slides[token]
	local low = (crouching[token] ~= nil and crouching[token] == humanoid.Parent)
		or (slide ~= nil and os.clock() < slide.untilTime)
	setHipHeight(humanoid, low)
end

function MatchService.SetCrouching(token, value)
	local wanted = value == true
	local humanoid = Combatants.GetHumanoid(token)
	local character = humanoid and humanoid.Parent
	if (crouching[token] ~= nil and crouching[token] == character) == wanted then
		return wanted
	end
	if not humanoid or not character or humanoid.Health <= 0 then
		crouching[token] = nil
		return false
	end
	if wanted and humanoid.Sit then
		return false
	end
	crouching[token] = wanted and character or nil
	if wanted then
		sprinting[token] = nil
	end
	updateHeight(token)
	character:SetAttribute("Crouching", wanted or nil)
	applySpeed(token)
	return wanted
end

function MatchService.IsCrouching(token)
	local crouchedCharacter = crouching[token]
	return crouchedCharacter ~= nil and crouchedCharacter == Combatants.GetCharacter(token)
end

-- The base walk speed for a token, before boosts, sprint and slide. The match event's speed
-- multiplier is applied here, so a Rot Rush reaches bots too. Bots call this at spawn.
function MatchService.SetBaseSpeed(token, speed)
	if not SafeValue.Number(speed, 500) or speed <= 0 then
		return false
	end
	baseSpeeds[token] = speed * (currentEvent and currentEvent.speedMultiplier or 1)
	applySpeed(token)
	return true
end

-- Stamina as a fraction of full, and whether the token is exhausted. Full outside a match.
function MatchService.GetStamina(token)
	local entry = stamina[token]
	if not entry or not staminaApplies(token) then
		return 1, false
	end
	return entry.value / STAMINA.Max, entry.exhausted
end

-- A temporary speed factor from a status effect: `key` names the effect (a later call with the same key
-- replaces it), `factor` multiplies walk speed (0 stops you, 0.5 halves it, 1.3 hastes), `duration` is
-- in seconds and it expires by itself. A factor of 1 or a duration of 0 clears that key now. Of all
-- active effects the strongest slow and the strongest speed-up apply. Returns whether it was accepted.
function MatchService.SetStatusSpeed(token, key, factor, duration)
	if type(key) ~= "string" or #key == 0 or #key > 32 then
		return false
	end
	if not SafeValue.Number(factor, 10) or factor < 0 or factor > 2 or not SafeValue.Number(duration, 600) or duration < 0 then
		return false
	end
	local effects = statusSpeeds[token]
	if factor == 1 or duration == 0 then
		if effects then
			effects[key] = nil
		end
		applySpeed(token)
		return true
	end
	if not effects then
		effects = {}
		statusSpeeds[token] = effects
	end
	local untilTime = os.clock() + math.min(duration, 60)
	-- The same effect refreshed (a companion's speed boon re-applies it every 0.2 s): only the end moves.
	-- A new table, a speed write and a fresh 5 s timer per refresh left ~25 timers live per owner.
	local existing = effects[key]
	if existing and existing.factor == factor then
		existing.untilTime = math.max(existing.untilTime, untilTime)
		return true
	end
	local entry = { factor = factor, untilTime = untilTime }
	effects[key] = entry
	applySpeed(token)
	-- One timer per effect: it re-arms for whatever a refresh added, and stands down once replaced.
	local function expire()
		local current = statusSpeeds[token]
		if not current or current[key] ~= entry then
			return
		end
		local left = entry.untilTime - os.clock()
		if left > 0.05 then
			task.delay(left, expire)
			return
		end
		applySpeed(token)
	end
	task.delay(math.min(duration, 60), expire)
	return true
end

-- Takes `amount` stamina. Refused (false) when there isn't enough or the token is exhausted, unless
-- `allowDebt`, which takes what's there and may exhaust (a climb is never refused). Free outside a
-- match and while a Speed Soda's rush lasts.
function MatchService.SpendStamina(token, amount, allowDebt)
	if not SafeValue.Number(amount, 1000) or amount < 0 then
		return false
	end
	if not staminaApplies(token) or isRushing(token) or amount == 0 then
		return true
	end
	local entry = ledger(token)
	if not allowDebt and (entry.exhausted or entry.value < amount) then
		syncStamina(token, true)
		return false
	end
	entry.value = math.max(entry.value - amount, 0)
	entry.lastSpend = os.clock()
	if entry.value <= 0 and not entry.exhausted then
		entry.exhausted = true
		applySpeed(token)
	end
	syncStamina(token, true)
	return true
end

-- Where you want to land, picked off the drop map. Checked here rather than trusted: the window
-- has to be open, you have to be someone this match is about to place, and the point has to be a
-- real number inside the playable disc. An out-of-bounds pick is pulled back to the edge rather
-- than refused, so a click near the rim still does what it looked like it would.
function MatchService.ChooseDrop(player, x, z)
	if not dropSelect or not participants[player] or not mapInfo then
		return false
	end
	-- Infinity passed the old NaN-only test and then became NaN below (limit / inf is 0, and inf * 0 is
	-- NaN), storing a NaN landing point. SafeValue refuses NaN, infinity and absurd sizes alike.
	if not SafeValue.Number(x) or not SafeValue.Number(z) then
		return false
	end
	local limit = mapInfo.radius * MatchConfig.SpawnSpread
	local distance = math.sqrt(x * x + z * z)
	if distance > limit then
		local scale = limit / math.max(distance, 1)
		x, z = x * scale, z * scale
	end
	chosenDrop[player] = Vector2.new(x, z)
	return true
end

-- A slide out of a sprint: you have to actually be sprinting (not exhausted) and on the ground, so it
-- can't be used as a standing dash; it costs Stamina.SlideCost; and a new one can't start until the
-- last has ended and Slide.Cooldown has passed. Not on NoMantle ground (the Cloud Climb, obby
-- towers), where a slide-jump would skip measured jumps.
function MatchService.StartSlide(player)
	local humanoid = Combatants.GetHumanoid(player)
	if not humanoid or humanoid.Health <= 0 or not sprinting[player] then
		return false
	end
	if humanoid.Sit then
		return false
	end
	if Combatants.IsPlayer(player) and not withinRate(player, "slide", 6) then
		return false
	end
	local now = os.clock()
	local previous = slides[player]
	if previous and (now < previous.untilTime or now < previous.readyAt) then
		return false
	end
	local entry = stamina[player]
	if entry and entry.exhausted then
		syncStamina(player, true)
		return false
	end

	-- On the ground (see groundUnder: not FloorMaterial, which isn't the server's to read for a player),
	-- and not on NoMantle ground.
	local character = humanoid.Parent
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local floor = groundUnder(character, humanoid, root)
	if not floor or Parkour.IsExcluded(floor.Instance) then
		return false
	end
	if not MatchService.SpendStamina(player, STAMINA.SlideCost, false) then
		return false
	end

	local window = Combatants.IsPlayer(player) and SLIDE.ServerWindow or SLIDE.BotWindow
	local untilTime = now + window
	slides[player] = { untilTime = untilTime, readyAt = untilTime + SLIDE.Cooldown }
	applySpeed(player)
	updateHeight(player)
	MovementService.SetParkourPose(character, "slide", window)
	task.delay(window, function()
		local current = slides[player]
		if current and current.untilTime == untilTime then
			applySpeed(player)
			-- The window ran out rather than the client ending it: stand back up, unless a crouch is
			-- holding the body down of its own accord.
			updateHeight(player)
		end
	end)
	return true
end

-- The client's word that its slide is over (it slowed down, jumped, hit something, left the ground):
-- the ceiling comes off now rather than when the window runs out, and the cooldown starts from here.
function MatchService.EndSlide(player)
	local slide = slides[player]
	local now = os.clock()
	if not slide or now >= slide.untilTime then
		return false
	end
	slide.untilTime = now
	slide.readyAt = now + SLIDE.Cooldown
	applySpeed(player)
	updateHeight(player)
	local character = Combatants.GetCharacter(player)
	if character and character:GetAttribute("Parkour") == "slide" then
		MovementService.SetParkourPose(character, nil)
	end
	return true
end

-- `options.rush` (a Speed Soda): while it lasts stamina is full and nothing costs any.
function MatchService.ApplySpeedBoost(player, multiplier, duration, options)
	local untilTime = os.clock() + duration
	local rush = type(options) == "table" and options.rush == true
	speedBoosts[player] = { multiplier = multiplier, untilTime = untilTime, rush = rush }
	if rush then
		local entry = ledger(player)
		entry.value, entry.exhausted = STAMINA.Max, false
		syncStamina(player, true)
	end
	applySpeed(player)
	-- The HUD shows a SPEED BOOST pill while this is set, and counts down to the stamp: SERVER time,
	-- the clock the client reads back with workspace:GetServerTimeNow(), the way MovementService stamps
	-- BounceBootsUntil. A second soda re-stamps; the first soda's delayed clear below sees a newer
	-- untilTime and leaves both alone.
	if Combatants.IsPlayer(player) then
		player:SetAttribute("SpeedBoosted", true)
		player:SetAttribute("SpeedBoostUntil", workspace:GetServerTimeNow() + duration)
	end
	task.delay(duration, function()
		local boost = speedBoosts[player]
		if boost and boost.untilTime == untilTime then
			speedBoosts[player] = nil
			applySpeed(player)
			if rush then
				syncStamina(player, true)
			end
			if Combatants.IsPlayer(player) and player.Parent then
				player:SetAttribute("SpeedBoosted", false)
				player:SetAttribute("SpeedBoostUntil", nil)
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Elimination
--------------------------------------------------------------------------------

local function disconnectDeath(token)
	local connection = deathConnections[token]
	if connection then
		connection:Disconnect()
		deathConnections[token] = nil
	end
end

local function finishMatch()
	state = "Results"
	CombatService.SetEnabled(false)
	StormService.Stop()
	SupplyDropService.Stop()
	LootService.Clear()
	-- S5a. Ranks BEFORE the world comes down: a respawn mode's RankOf reads the team table that
	-- StopWorld clears, so read after it every team was nil and every player ranked #2 - no winner,
	-- no "Won by", both sides paid rank 2 (logic review #17).
	local ranks = {}
	for token in pairs(participants) do
		ranks[token] = placements[token] or (currentMode.RankOf and currentMode.RankOf(token) or nil)
	end

	-- S4. Tears down whatever the mode built: the hill, the arena boundary, team state and the
	-- respawn timers. A no-op in the battle royale.
	currentMode.StopWorld()
	workspace.Gravity = NORMAL_GRAVITY

	-- S4a. A respawn mode has no spectating, and StopWorld has just cancelled every respawn timer.
	-- Anyone who died in the last few seconds of it was waiting on a LoadCharacter that will now
	-- never happen, and with CharacterAutoLoads off nothing else gives them a body until the
	-- intermission reset fifteen seconds later: a whole results screen with no body and no camera
	-- subject. Give them one back.
	if currentMode.respawn then
		for token in pairs(participants) do
			if Combatants.IsPlayer(token) and token.Parent and not Combatants.IsAlive(token) then
				pcall(function()
					token:LoadCharacter()
				end)
			end
		end
	end

	-- The field the match started with: `participants` has lost everyone who left, so a player who
	-- stayed could read "#50 of 49". Never below a rank that was handed out.
	local total = math.max(matchField, countKeys(participants))
	for _, rank in pairs(ranks) do
		total = math.max(total, rank)
	end

	-- Who actually won, so everyone gets closure rather than just their own placement.
	local winnerName, winnerIsBot = nil, false
	for token, rank in pairs(placements) do
		if rank == 1 then
			winnerName = Combatants.GetName(token)
			winnerIsBot = Combatants.IsBot(token)
			break
		end
	end

	for token in pairs(participants) do
		disconnectDeath(token)

		-- S5. A respawn mode has no placements, so its rank and its payout come from the mode.
		-- AwardResult is deliberately NOT AwardPlacement: that counts Stats.wins and submits to the
		-- global battle-royale board, and a Team Deathmatch win must not inflate either.
		local rank = ranks[token]
		if rank and Combatants.IsPlayer(token) and token.Parent then
			local reward = currentMode.AwardResult and currentMode.AwardResult(token, rank)
				or afk.award(token, rank)
			local eggsFound, eggsTotal = EasterEggs.FoundCount(token)
			matchResults:FireClient(token, {
				companionDamage = CompanionService.DamageDealt(token),
				eggsFound = eggsFound,
				eggsTotal = eggsTotal,
				rank = rank,
				total = total,
				reward = reward,
				winnerName = winnerName,
				winnerIsBot = winnerIsBot,
				kills = streaks[token] and streaks[token].total or nil,
				-- Damage, chests, items, supply drops and bounties this match.
				tally = QuestService.MatchTally(token),
				-- Shots, hits, headshots, damage taken and the longest elimination.
				combat = CombatService.MatchStats(token),
				-- Rot Rank before and after, XP and Brain Cells this match (set by Bootstrap to
				-- ProgressionService.MatchSummary; after AwardPlacement, so placement XP is in it).
				progression = MatchService.ProgressionSummary and MatchService.ProgressionSummary(token) or nil,
				-- S6. Which mode this was, and the team scoreline, for the results card.
				mode = currentMode.id,
				modeResults = currentMode.Results and currentMode.Results() or nil,
			})
		end
	end

	BotService.Clear()
	broadcast()

	local thisMatch = matchId
	task.delay(MatchConfig.ResultsDuration, function()
		if matchId ~= thisMatch then
			return
		end

		-- Free the finished map now rather than when the next match builds over it. It's
		-- several thousand parts plus a terrain slab thousands of studs wide, and nothing
		-- needs it through results, the lobby and the countdown.
		MapGenerator.Clear()
		-- The drop-map cache holds the old Map model; let it go with the map.
		require(script.Parent:WaitForChild("DropMapService")).Clear()
		mapInfo = nil

		-- Only bring back the people who were in the match. Anyone who stayed in the lobby is
		-- left exactly where they are, rather than respawned at every match end.
		local wereIn = participants

		participants = {}
		alive = {}
		placements = {}
		aliveCount = 0
		table.clear(leftSpectate)
		-- A minute's break in the lobby before the next countdown can start.
		state = "Intermission"
		countdown = MatchConfig.Intermission
		broadcast()
		-- The next match's vote goes up now, not at the countdown: the whole break to read three cards
		-- and argue about them, where the countdown alone left 8 seconds once everyone was ready.
		VoteService.Open()

		for _, player in ipairs(Players:GetPlayers()) do
			-- Only the match's own loadouts. Clearing everyone nilled a lobby player's rack gun taken
			-- during the results screen with no push and no held-gun refresh: a dead welded gun and a
			-- hotbar entry until they took another (logic review #8).
			if wereIn[player] then
				player:SetAttribute("InMatch", false)
				WeaponService.Clear(player)
				spectate:FireClient(player, false)
				pcall(function()
					player:LoadCharacter()
				end)
			end
		end

		if MatchService.OnMatchEnd then
			MatchService.OnMatchEnd()
		end

		broadcast()
	end)
end

-- Where a body's drop goes: its HumanoidRootPart, or failing that wherever the body is. Only the root
-- was asked before, and a death without one (a body that fell out of the world, a rig whose root came
-- away) quietly dropped nothing at all.
local function deathSpot(token)
	local root = Combatants.GetRoot(token)
	if root then
		return root.Position
	end
	local character = Combatants.GetCharacter(token)
	if character and character.Parent then
		local ok, pivot = pcall(character.GetPivot, character)
		if ok then
			return pivot.Position
		end
	end
	return nil
end

-- One piece of a death drop. Each goes down on its own, so a fault building one pickup costs that
-- pickup only, not the rest of the body's gear, and never the elimination that called it (dropLoot
-- runs first in eliminate(): a throw here used to lose the kill feed, the placement and the alive
-- count along with the drop).
local function dropSafely(drop, ...)
	local ok, err = pcall(drop, ...)
	if not ok then
		warn("[MatchService] death drop failed: " .. tostring(err))
	end
end

-- Put the victim's gear back on the map so a kill is worth pushing for.
local function dropLoot(token)
	local position = deathSpot(token)
	if not position then
		return
	end

	if Combatants.IsBot(token) then
		if token.weapon then
			dropSafely(LootService.DropWeapon, token.weapon.id, position)
		end
		-- The second gun a bot carries (BotService's BOT LOOTING & ROTATION, bot.backup) drops as well.
		if token.backup and token.backup.id then
			dropSafely(LootService.DropWeapon, token.backup.id, position)
		end
		-- Bots loot heals and shields now, so killing one pays out the same as killing a player.
		local heals = token.heals
		if heals and (heals.Bandage or 0) + (heals.MedKit or 0) > 0 then
			dropSafely(LootService.DropHeal, position)
		end
		local shields = token.shields
		if shields and (shields.MiniShield or 0) + (shields.ShieldPotion or 0) > 0 then
			dropSafely(LootService.DropItem, (shields.ShieldPotion or 0) > 0 and "ShieldPotion" or "MiniShield", position, 1)
		end
		if (token.defenses or 0) > 0 then
			dropSafely(LootService.DropItem, "RotBarricade", position, token.defenses)
		end
		return
	end

	local loadout = WeaponService.Get(token)
	if not loadout then
		return
	end

	-- Everything they carried hits the floor: each gun with the ammo its owner had left (so a
	-- death isn't an ammo refill), each item stack as one pickup.
	for _, slot in pairs(loadout.slots) do
		dropSafely(LootService.DropSlot, slot, position)
	end
end

-- The battle royale is over when one combatant (or no real player) is left: rank the survivors and
-- finish. Called from eliminate() once the match is running, and from the end of startMatch for a
-- match that lost everyone WHILE loading - finishing one that was still starting resumed startMatch
-- over the results screen with a fresh storm and combat (logic review #21).
local function concludeIfOver()
	if state ~= "InProgress" then
		return false
	end
	if currentMode.respawn then
		-- A respawn mode never ends by elimination; with no real player left it ran on with bots to the
		-- deadline while late joiners sat on "Not in this match" (logic review #20).
		if realPlayersAlive() == 0 then
			finishMatch()
			return true
		end
		return false
	end
	if aliveCount <= 1 or realPlayersAlive() == 0 then
		local rank = aliveCount
		for survivor in pairs(alive) do
			placements[survivor] = rank
			rank = math.max(1, rank - 1)
			alive[survivor] = nil
			disconnectDeath(survivor)
		end
		aliveCount = 0
		finishMatch()
		return true
	end
	return false
end

-- S7a, Oliver's #124: in a kit mode a death drops nothing of the ISSUED kit - nobody needs a floor
-- of kit guns in a mode that hands one out every five seconds - but everything picked up during the
-- match still drops, players and bots through this one rule. The kit is tagged where it is issued:
-- ModeTeams.GrantLoadout marks a player's slots `issued`, and the spawn callbacks record a bot's
-- `issuedWeaponId` and, through noteIssuedKit, its issued heal and defense counts. A
-- pickup that displaced an issued slot is untagged and drops; ammo picked up INTO an issued gun stays
-- with it. Bots track a magazine but no reserve, so a dropped bot gun comes down full, the way the
-- battle royale's do. Coins, XP and mastery are untouched: this is loot, not the reward economy.
--
-- BotService puts the kit's Bandages and structures into the same counters chest pickups fill, so
-- every kit-mode bot death used to drop a heal and a barricade stack. What the counters held at spawn
-- is recorded here and only what is over it drops (a bot that used kit items and then picked some up
-- is under-counted, never over).
local function noteIssuedKit(bot)
	local heals = bot.heals
	bot.issuedHeals = heals and (heals.Bandage or 0) + (heals.MedKit or 0) or 0
	bot.issuedDefenses = bot.defenses or 0
end

local function dropPickedUp(token)
	local position = deathSpot(token)
	if not position then
		return
	end
	if Combatants.IsBot(token) then
		if token.weapon and token.weapon.id and token.weapon.id ~= token.issuedWeaponId then
			dropSafely(LootService.DropWeapon, token.weapon.id, position)
		end
		if token.backup and token.backup.id and token.backup.id ~= token.issuedWeaponId then
			dropSafely(LootService.DropWeapon, token.backup.id, position)
		end
		local heals = token.heals
		if heals and (heals.Bandage or 0) + (heals.MedKit or 0) > (token.issuedHeals or 0) then
			dropSafely(LootService.DropHeal, position)
		end
		local shields = token.shields
		if shields and (shields.MiniShield or 0) + (shields.ShieldPotion or 0) > 0 then
			dropSafely(LootService.DropItem, (shields.ShieldPotion or 0) > 0 and "ShieldPotion" or "MiniShield", position, 1)
		end
		local pickedDefenses = (token.defenses or 0) - (token.issuedDefenses or 0)
		if pickedDefenses > 0 then
			dropSafely(LootService.DropItem, "RotBarricade", position, pickedDefenses)
		end
		return
	end
	local loadout = WeaponService.Get(token)
	if not loadout then
		return
	end
	for _, slot in pairs(loadout.slots) do
		if not slot.issued then
			dropSafely(LootService.DropSlot, slot, position)
		end
	end
end

-- `method` (optional) names what did it, for the kill feed. `weaponId` (optional) is the raw id of
-- what landed the last hit, for gun mastery.
local function eliminate(token, killerToken, method, weaponId)
	if not alive[token] then
		return
	end
	-- A Gold Rush gun's kill bonus, paid below with the kill credit and under its guards (in a respawn
	-- mode its cap and scale). OnElimination used to pay it with none, so replaced bots could be farmed.
	local gun = type(weaponId) == "string" and WeaponData.Get(weaponId) or nil
	local goldRush = gun and gun.ability == "goldRush" and (gun.goldRushBonus or 100) or nil

	-- S7. Team Deathmatch and King of the Hill: a death is not an elimination. The mode scores it
	-- and brings the player back, and none of the placement path below applies — there is no rank,
	-- no spectating and no last one standing.
	--
	-- This sits ABOVE dropLoot and above the kill-reward block on purpose, so a respawn mode drops
	-- nothing of the ISSUED kit (what was picked up still drops - dropPickedUp, Oliver's #124). Kills
	-- DO pay here now (Oliver, 2026-09-23 16:10: "theres no rewards for the team gamemodes!"), at
	-- MatchConfig.TeamModeRewards.killScale of the battle royale rate and only for the first
	-- maxPaidKills of the match; the result payout is the mode's AwardResult.
	if currentMode.respawn then
		dropPickedUp(token)
		-- Counted for the results card only (no coins, XP or streak banners, per the note above):
		-- the respawn path returned before the tally below, so a Team Deathmatch results screen showed
		-- 0 eliminations however many players and bots you took down (Oliver, 2026-09-22: "the win
		-- screen isnt showing my bot kills").
		if killerToken and killerToken ~= token and Combatants.IsPlayer(killerToken) and participants[killerToken] then
			local streak = streaks[killerToken]
			if not streak then
				streak = { count = 0, at = 0, total = 0 }
				streaks[killerToken] = streak
			end
			streak.total += 1
			local rules = MatchConfig.TeamModeRewards or {}
			if streak.total <= (rules.maxPaidKills or 30) then
				local ok, err = pcall(RewardService.AwardKill, killerToken, Combatants.IsBot(token), rules.killScale or 0.5)
				if not ok then
					warn("[MatchService] team kill reward failed: " .. tostring(err))
				end
				if MatchService.OnKillCredited then
					pcall(MatchService.OnKillCredited, killerToken, token, weaponId)
				end
				-- Gold Rush under the same cap and scale as the kill itself.
				local bonus = goldRush and math.floor(goldRush * (rules.killScale or 0.5) + 0.5) or 0
				if bonus > 0 then
					pcall(RewardService.AwardBonusCoins, killerToken, bonus, "Gold Rush")
				end
			end
		end
		currentMode.OnDeath(token, killerToken, method, weaponId)
		return
	end

	-- Must happen before the loadout is cleared further down.
	dropLoot(token)

	alive[token] = nil
	placements[token] = aliveCount
	aliveCount -= 1
	afk.settle(token)
	disconnectDeath(token)
	CombatService.ClearAttacker(token)

	killFeed:FireAllClients({
		victim = Combatants.GetName(token),
		killer = killerToken and Combatants.GetName(killerToken) or nil,
		killerUserId = killerToken and Combatants.GetUserId(killerToken) or nil,
		method = killerToken and method or nil,
		placement = placements[token],
	})

	-- The bounty holder went down: whoever did it collects, and the bounty is off.
	if token == bountyToken then
		local reward = bountyReward
		bountyToken, bountyReward = nil, 0
		if Combatants.IsPlayer(killerToken) and killerToken ~= token and participants[killerToken] then
			RewardService.AwardBonusCoins(killerToken, reward, "bounty on " .. Combatants.GetName(token))
			QuestService.Progress(killerToken, "bounties", 1)
			bounty:FireAllClients({ claimed = true, name = Combatants.GetName(token), userId = Combatants.GetUserId(token),
				by = Combatants.GetName(killerToken), reward = reward })
		else
			bounty:FireAllClients(nil)
		end
	end

	if Combatants.IsPlayer(killerToken) and killerToken ~= token and participants[killerToken] then
		-- Wrapped, as the respawn path above wraps them: alive[token] is already cleared, so a throw here
		-- would skip the victim's spectate, broadcast() and concludeIfOver() and could leave the match
		-- with nobody to end it.
		local ok, err = pcall(RewardService.AwardKill, killerToken, Combatants.IsBot(token))
		if not ok then
			warn("[MatchService] kill reward failed: " .. tostring(err))
		end
		if goldRush then
			pcall(RewardService.AwardBonusCoins, killerToken, goldRush, "Gold Rush")
		end
		-- Set by Bootstrap to ProgressionService.OnKillCredited (gun mastery). It ignores anything
		-- that isn't a WeaponData gun: companions, barrels and mines.
		if MatchService.OnKillCredited then
			local credited, creditErr = pcall(function()
				MatchService.OnKillCredited(killerToken, token, weaponId)
			end)
			if not credited then
				warn("[MatchService] kill credit failed: " .. tostring(creditErr))
			end
		end

		-- Rapid consecutive kills escalate. `count` resets outside the window so a slow
		-- grind doesn't read as a rampage, while `total` keeps the match tally for the
		-- results card.
		local streak = streaks[killerToken]
		if not streak then
			streak = { count = 0, at = 0, total = 0 }
			streaks[killerToken] = streak
		end

		local now = os.clock()
		streak.total += 1
		streak.count = (now - streak.at <= STREAK_WINDOW) and streak.count + 1 or 1
		streak.at = now

		local label = STREAK_LABELS[math.min(streak.count, STREAK_MAX)]
		if label then
			killStreak:FireClient(killerToken, label, streak.count)
			-- Streaks pay: 50 coins for a double, up to 200 for a rampage.
			RewardService.AwardBonusCoins(killerToken, math.min(streak.count, STREAK_MAX) * 50 - 50, label)
		end

		-- Taking the lead (or extending it) puts, or raises, the bounty on the leader's head.
		local leaderKills = bountyToken and streaks[bountyToken] and streaks[bountyToken].total or 0
		if streak.total >= bountyMinKills and (killerToken == bountyToken or streak.total > leaderKills) and alive[killerToken] then
			bountyToken = killerToken
			bountyReward = math.floor((BOUNTY_BASE + BOUNTY_PER_KILL * streak.total) * bountyMultiplier)
			bounty:FireAllClients({ name = Combatants.GetName(killerToken), userId = Combatants.GetUserId(killerToken),
				kills = streak.total, reward = bountyReward })
		end
	end

	if Combatants.IsPlayer(token) and token.Parent then
		StateSync.Notify(token, string.format("Eliminated — placed #%d", placements[token]))
		-- Stay in the match as a spectator rather than being dumped back in an empty
		-- lobby. Respawning happens for everyone when the match resets.
		WeaponService.Clear(token)
		WeaponService.Push(token)
		spectate:FireClient(token, true)
	elseif Combatants.IsBot(token) then
		-- Long enough for the death effect (DeathFxService) to play out and hide the body.
		local character = token.character
		task.delay(7, function()
			if character and character.Parent then
				Combatants.Unregister(character)
				character:Destroy()
			end
		end)
	end

	broadcast()

	-- A server of bots fighting each other with nobody watching is not worth running out.
	concludeIfOver()
end

CombatService.OnElimination = function(victim, killer, weaponDef, weaponId)
	-- For the kill feed: the gun's name, the companion brainrot that landed the last hit, the barrel
	-- or mine that went up, or the thrown item (ItemData throwables). The hazardKills quest stays
	-- barrels and mines only.
	local method = weaponDef and weaponDef.name or nil
	local hazard = weaponId == "ExplosiveBarrel" or weaponId == "RotMine"
	if not method and type(weaponId) == "string" then
		method = string.match(weaponId, "^Companion:(.+)$")
			or ((hazard or weaponId == "Roadkill" or ItemData.Get(weaponId)) and CombatService.DescribeWeapon(weaponId)) or nil
	end
	if hazard and Combatants.IsPlayer(killer) and killer ~= victim then
		QuestService.Progress(killer, "hazardKills", 1)
	end
	-- A Gold Rush gun's bonus is paid inside eliminate, with the kill credit and under its guards.
	eliminate(victim, killer, method, weaponId)
end

local function watchDeath(token, humanoid)
	disconnectDeath(token)
	deathConnections[token] = humanoid.Died:Connect(function()
		CombatService.HandleDeath(token)
	end)
end

-- S8. The only way a mode reaches this file's internals: four closures, handed over once. They are
-- not a public API — nothing outside GameMode can call them. Placed here rather than beside
-- finishMatch because watchDeath above is one of them.
GameMode.Bind({
	Finish = finishMatch,
	Broadcast = broadcast,
	IsParticipant = function(token)
		return participants[token] == true
	end,
	-- A respawn mode brings bots back rather than running down to one survivor, so it enrols the
	-- replacement. Refused outside a respawn mode: the battle royale's roster never grows mid-match.
	AddCombatant = function(token, humanoid)
		if not currentMode.respawn or state ~= "InProgress" or participants[token] then
			return false
		end
		participants[token] = true
		alive[token] = true
		aliveCount += 1
		-- A replacement bot has just been issued its kit (GameMode's spawn callback calls this).
		if Combatants.IsBot(token) then
			noteIssuedKit(token)
		end
		watchDeath(token, humanoid)
		broadcast()
		return true
	end,
	RemoveCombatant = function(token)
		if not currentMode.respawn or not participants[token] then
			return false
		end
		disconnectDeath(token)
		CombatService.ClearAttacker(token)
		if alive[token] then
			aliveCount -= 1
		end
		participants[token], alive[token] = nil, nil
		broadcast()
		return true
	end,
})

-- #108. The storm asks before it hurts anyone: only a LIVE PARTICIPANT of the running match is
-- eligible, players and bots alike. A lobby body is registered like every other (OnCharacterAdded)
-- but never enters `alive`, so it can never take storm damage. Installed here, beside GameMode.Bind,
-- because it is the same kind of seam: a closure over this file's internals, handed over once.
StormService.SetEligibility(function(token)
	return alive[token] == true
end)

--------------------------------------------------------------------------------
-- Match start
--------------------------------------------------------------------------------

-- Sunflower (Vogel) spiral: the golden angle spreads points evenly over a disc instead of
-- bunching them on rings, so every combatant starts roughly the same distance from their
-- nearest neighbour no matter how many are in the match.
local GOLDEN_ANGLE = math.pi * (3 - math.sqrt(5))

local function spawnCFrameFor(index, total)
	local radius = mapInfo and mapInfo.radius or 600
	local raw = (index - 0.5) / math.max(1, total)

	-- Remap into [innerBias, 1] so nobody spawns at the centre of the disc.
	local inner = MatchConfig.SpawnInnerBias
	local t = inner + (1 - inner) * raw

	local distance = math.sqrt(t) * radius * MatchConfig.SpawnSpread
	local angle = index * GOLDEN_ANGLE

	local x = math.cos(angle) * distance
	local z = math.sin(angle) * distance

	-- Terrain has hills now, so sit on the surface rather than at a fixed height.
	local position = Vector3.new(x, MapGenerator.GroundHeightAt(x, z) + MatchConfig.SpawnHeight, z)

	-- Face the middle, so everyone opens looking at the play area.
	return CFrame.lookAt(position, Vector3.new(0, position.Y, 0))
end

local function startMatch()
	bountyToken, bountyReward = nil, 0
	bounty:FireAllClients(nil)
	matchId += 1

	-- Roll this match's event and set every knob it touches; a plain match gets the defaults.
	currentEvent = MatchEvents.Roll()
	-- S9. Which mode this match runs, and a veto on events it cannot host: a storm event with no
	-- storm, or a chest event in a mode where the kit is handed to you. The mode comes from the
	-- lobby vote; VoteService.Resolve caches its pick until the next Open, so this call and the one
	-- that takes the map below answer the same match -- a tie is drawn once, not twice.
	currentMode = GameMode.Resolve(matchId, select(2, VoteService.Resolve()))
	if not GameMode.AllowsEvent(currentMode, currentEvent) then
		currentEvent = nil
	end
	local event = currentEvent or {}
	applyEventKnobs(event)
	CombatService.ResetStats()
	-- The vendors' per-player caps (2 heals, 1 shield) are per match.
	VendorService.ResetMatch()

	-- Who's in is fixed the moment loading begins. Readying up or down during the few seconds
	-- of map generation applies to the match after this one.
	local readyAtStart = readyPlayers()

	-- Generating terrain and a few thousand parts takes a few seconds. Sit in a distinct
	-- state for that window so the HUD says what's happening instead of showing an
	-- in-progress match with nobody in it.
	state = "Loading"
	broadcast()

	if MatchService.OnMatchStart then
		MatchService.OnMatchStart()
	end

	local winningMap = VoteService.Resolve()
	VoteService.Close()
	-- The team picker waits out the vote's winner reveal, which starts now on every client.
	local revealUntil = TeamPicker.Clock() + TeamPicker.RevealGuard

	mapInfo = MapGenerator.Build(winningMap)
	-- A Night Ops match lays its own lighting over the map's time of day.
	MapGenerator.ApplyLightingOverride(event.lighting)
	LootService.Populate(mapInfo)
	-- The map is built: MountedGuns puts its guns up (Bootstrap sets this; the mode says which guns).
	if MatchService.OnMapBuilt then
		local okGuns, gunsErr = pcall(MatchService.OnMapBuilt, mapInfo, currentMode)
		if not okGuns then
			warn("[MatchService] OnMapBuilt failed: " .. tostring(gunsErr))
		end
	end
	BotService.Clear()
	-- The map's RoadNetwork, so bot drivers route along the roads (BotService.SetRoads).
	if BotService.SetRoads then
		BotService.SetRoads(mapInfo and mapInfo.roads)
	end

	participants = {}
	alive = {}
	placements = {}
	aliveCount = 0
	table.clear(leftSpectate)
	table.clear(afk.players)
	afk.tick = 0
	table.clear(regen.lastCombat)
	table.clear(regen.lastHealth)
	table.clear(streaks)
	CompanionService.ResetStats()

	local joining = {}
	for _, player in ipairs(readyAtStart) do
		if #joining >= MatchConfig.MaxPlayers then
			break
		end
		-- Someone who left during map generation isn't joining anything.
		if player.Parent then
			table.insert(joining, player)
			participants[player] = true
			alive[player] = true
			aliveCount += 1
		end
	end
	tagInMatch(Players:GetPlayers())

	-- The battle royale fills to 50, every other mode to 30 (MatchConfig, Oliver 09-22 13:45).
	local fillTarget = MatchConfig.BotFillTarget
	if currentMode.id == "BattleRoyale" then
		fillTarget = MatchConfig.BotFillTargetBattleRoyale or fillTarget
	end
	local botCount = math.clamp(
		math.min(fillTarget, MatchConfig.MaxPlayers) - #joining,
		0,
		MatchConfig.MaxPlayers
	)
	local total = #joining + botCount
	matchField = total

	-- Count bots into the alive tally up front so early deaths can't hand out rank #1 while
	-- the backfill is still spawning.
	aliveCount += botCount
	broadcast()

	-- The drop window: time to pick a landing spot before anybody is placed. It sits here because
	-- this is the one moment when a real map exists and nobody has a body yet. It can't go in the
	-- lobby countdown instead, because the map hasn't been generated then and there'd be nothing
	-- to choose from.
	--
	-- Owning `countdown` here is safe: the ticker in MatchService.Start has no branch for the
	-- Loading state, and startMatch runs synchronously on that very thread, so nothing else
	-- touches the countdown or the state while this runs.
	-- S10. Only a mode that drops you in from the sky needs a landing spot picked first.
	if currentMode.dropSelect then
		table.clear(chosenDrop)
		dropSelect = true
		countdown = MatchConfig.DropSelectSeconds
		broadcast()
		for _ = 1, MatchConfig.DropSelectSeconds do
			task.wait(1)
			countdown -= 1
			broadcast()
			-- Every player being placed has picked (a leaver has nothing to pick): nobody left to wait for.
			local waiting = false
			for _, player in ipairs(joining) do
				if player.Parent and participants[player] and not chosenDrop[player] then
					waiting = true
					break
				end
			end
			if not waiting then
				break
			end
		end
		dropSelect = false
		countdown = 0
		broadcast()
	end

	-- The team picker (TeamPicker): a team mode's side choice, in the same slot as the drop window and
	-- for the same reason. It ends in ModeTeams.SetPicks, so the placement below deals each player onto
	-- the side they chose (or were balanced onto) and the bots fill round them. Protected: a failure
	-- costs the match its picker, never its start -- everyone is then auto-assigned as before.
	if currentMode.teams then
		teamSelect = true
		local ok, err = pcall(TeamPicker.Run, joining, total, currentMode, revealUntil, function(left)
			countdown = left
			broadcast()
		end)
		if not ok then
			warn("[MatchService] team picker failed, everyone is auto-assigned: " .. tostring(err))
			pcall(TeamPicker.Close)
		end
		teamSelect = false
		countdown = 0
		broadcast()
	end

	local thisMatch = matchId

	-- Everyone in `joining` is already counted alive. If their character never materialises
	-- they have no body, no death hook and no loadout — and they'd keep the match from ever
	-- ending once everyone else was dead. Eliminate them instead of silently giving up.
	--
	-- Deferred until the match has left Loading: a failure can surface before this task first
	-- yields, and eliminating then could run finishMatch mid-setup, after which startMatch
	-- would carry on and flip the state back to InProgress on top of the results screen.
	local function failSpawn(player)
		while state == "Loading" and matchId == thisMatch do
			task.wait(0.25)
		end
		if matchId == thisMatch and alive[player] then
			warn("[MatchService] " .. player.Name .. " failed to spawn — eliminating so the match can end.")
			eliminate(player, nil)
		end
	end

	-- S12a. A respawn mode's arena and spawn pads have to exist before anyone is placed on them.
	-- StartWorld used to run after this loop for every mode, so the first placement found no
	-- pads, and each player stood on the LOBBY's spawn pad for the second it took the retry to
	-- come round. The battle royale keeps its order below: its StartWorld is the storm.
	if currentMode.respawn then
		currentMode.StartWorld(mapInfo)
	end

	for index, player in ipairs(joining) do
		LobbyService.ClearClimb(player)
		task.spawn(function()
			-- The opening body: state is already InProgress by the time it arrives, and without this mark
			-- OnCharacterAdded would run the respawn path (place + kit) and PlaceAtStart below would do
			-- it all again. OnCharacterAdded consumes it (under deferred signals it runs after this
			-- thread moves on, so clearing it here would be too early); a timer clears it if it never does.
			local openingStamp = os.clock()
			player:SetAttribute("OpeningSpawn", openingStamp)
			-- Longer than the waits below (10 s for the body, 10 s for its Humanoid), so a slow load
			-- can't outlast the mark and be treated as a respawn.
			task.delay(25, function()
				if player:GetAttribute("OpeningSpawn") == openingStamp then
					player:SetAttribute("OpeningSpawn", nil)
				end
			end)
			local ok = pcall(function()
				player:LoadCharacter()
			end)
			if not ok then
				player:SetAttribute("OpeningSpawn", nil)
				failSpawn(player)
				return
			end

			-- Bounded, unlike CharacterAdded:Wait(), which blocks forever if the character
			-- never arrives. A player who leaves in the meantime is already eliminated by
			-- OnPlayerRemoving, so failSpawn no-ops for them.
			local character = player.Character
			if not character then
				local deadline = tick() + 10 -- wall time, not os.clock (CPU time in Roblox)
				repeat
					task.wait(0.1)
					character = player.Character
				until character or tick() > deadline or not player.Parent
			end

			local humanoid = character and character:WaitForChild("Humanoid", 10)
			if not humanoid then
				failSpawn(player)
				return
			end

			Combatants.Register(character, player)
			applyBoosts(player, humanoid)
			WeaponService.Reset(player)
			-- Never LOWER a shield the spawn kit already filled (the team kit spawns everyone full).
			if currentEvent and currentEvent.startShield then
				local now = (WeaponService.Get(player) or {}).shield or 0
				WeaponService.SetShield(player, math.max(now, currentEvent.startShield))
			end
			-- Drop in from high above the spawn under a canopy, steering on the way down. Over
			-- wherever you picked on the drop map, or over the spiral's spot if you picked nothing.
			-- S11. A respawn mode opens on the ground in its own base, with no canopy.
			if currentMode.PlaceAtStart then
				currentMode.PlaceAtStart(player, character, index, total)
			else
				local picked = chosenDrop[player]
				local spawnAt = spawnCFrameFor(index, total)
				if picked then
					spawnAt = CFrame.new(picked.X, MapGenerator.GroundHeightAt(picked.X, picked.Y) + MatchConfig.SpawnHeight, picked.Y)
				end
				character:PivotTo(spawnAt + Vector3.new(0, MatchConfig.DropHeight, 0))
				MovementService.DropIn(player, character)
				-- The drop glides in "steer" mode: straight down with nothing held, so doing what the old
				-- toast said (hold W) carried the player off the spot they had just picked (#86).
				StateSync.Notify(player, picked and "Dropping in over your spot — hold nothing to land there, or steer with WASD"
					or "Dropping in — steer with WASD, look for a landmark")
			end
			watchDeath(player, humanoid)
		end)
	end

	if botCount > 0 then
		task.spawn(function()
			-- The match can end while this is still spawning. Nothing that completes after
			-- that may touch the finished match: registering bots there let their falls into
			-- the cleared void re-trigger finishMatch and pay out results a second time, and
			-- the reconcile below could drive aliveCount negative.
			local function stillThisMatch()
				return matchId == thisMatch and (state == "Loading" or state == "InProgress")
			end

			-- Bots drop in under canopies like everyone else, steering for the nearest town or
			-- landmark, so the opening sky is full and nobody starts on a doorstep.
			-- S12b. A respawn mode opens on the ground in its own base, so its bots are built there
			-- and dealt a side, not dropped on the battle royale's spiral under a canopy. Both hooks
			-- are nil on the battle royale, so its path is byte-identical.
			local spawned = BotService.Spawn(botCount, function(botIndex)
				if currentMode.BotSpawnCFrame then
					return currentMode.BotSpawnCFrame(botIndex)
				end
				return spawnCFrameFor(#joining + botIndex, total) + Vector3.new(0, MatchConfig.DropHeight, 0)
			end, function(bot, humanoid)
				if not stillThisMatch() then
					return
				end
				participants[bot] = true
				alive[bot] = true
				-- The gun SpawnLoadout issued (it runs before this callback): a death in a kit mode drops
				-- the held gun only if it is a different one (dropPickedUp, Oliver's #124).
				bot.issuedWeaponId = bot.weapon and bot.weapon.id or nil
				noteIssuedKit(bot)
				-- Shield Up: "Everyone starts with 50 shield", bots too (a bot's shield is this attribute,
				-- which BotService zeroes at spawn). Never lowered, as for players.
				if currentEvent and currentEvent.startShield and humanoid then
					humanoid:SetAttribute("Shield", math.max(humanoid:GetAttribute("Shield") or 0, currentEvent.startShield))
				end
				-- S12c. WITHOUT THIS LINE a bot enters Team Deathmatch and King of the Hill with no
				-- team at all: killing it scores nothing, it is never retired or replaced, the hill
				-- never counts it, the spawn-pad enemy scan cannot see it, and it has no team
				-- objective to chase. Every rule in those modes keys off ModeTeams.TeamOf. Measured
				-- 8 of 8 teamless before this line existed.
				if currentMode.EnrolBot then
					currentMode.EnrolBot(bot, humanoid)
				end
				watchDeath(bot, humanoid)
			end, { dropIn = not currentMode.respawn, dropTargets = mapInfo.dropSpots })

			if not stillThisMatch() then
				return
			end

			-- Reconcile if any rig failed to build, so the alive count never overstates.
			local missing = botCount - #spawned
			if missing > 0 then
				aliveCount -= missing
				matchField -= missing
			end

			BotService.Start()
			broadcast()
			-- The reconcile can leave one combatant (a solo player whose bots all failed to build), and
			-- nothing else would end the match until they died; refused unless InProgress.
			concludeIfOver()
		end)
	end

	-- S12. The battle royale's StartWorld is exactly StormService.Start(mapInfo.radius); a respawn
	-- mode stops the storm and raises its arena boundary and hill instead (already up, above).
	if not currentMode.respawn then
		currentMode.StartWorld(mapInfo)
	end
	SupplyDropService.Start()
	state = "InProgress"
	CombatService.SetEnabled(true)
	broadcast()
	-- Anyone who left while the match was loading was taken out of the counts without ending it (see
	-- concludeIfOver); now that it has started, the same test runs once.
	concludeIfOver()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function MatchService.OnCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end

	Combatants.Register(character, player)
	DeathFxService.Prepare(character)

	-- "Loading" counts too: startMatch marks everyone alive before it spawns them, and
	-- falling through to the lobby path here would attach the out-of-match respawn handler
	-- to a live participant — which would yank them out of spectating the moment they die.
	if (state == "InProgress" or state == "Loading") and alive[player] then
		-- The new body's death has to reach eliminate the way the first body's did. startMatch arms
		-- this for the opening spawn; nothing armed it for a respawn, so a respawned player's NEXT
		-- death was seen by nobody — CombatService.HandleDeath is only ever called from this
		-- connection — no scoring, no "back in 5 seconds", no LoadCharacter, and with
		-- CharacterAutoLoads off they stayed dead for the rest of the match (Oliver's "died in a
		-- match and never respawned"). Armed here for every match body, so it can't be forgotten.
		watchDeath(player, humanoid)
		-- S13. A respawn mode puts them back on their team's pad with a fresh kit. WITHOUT THIS
		-- LINE a respawned player falls through to the lobby path below and is teleported to Rot
		-- Island mid-match. Do not remove it while tidying: it is the entire respawn path.
		-- Only once the match is running: the opening spawn is placed by startMatch's PlaceAtStart.
		local opening = player:GetAttribute("OpeningSpawn") ~= nil
		player:SetAttribute("OpeningSpawn", nil)
		if state == "InProgress" and not opening then
			currentMode.OnRespawn(player, character)
			-- Everything startMatch gave the opening body, the respawn body gets too - passes and the
			-- consumable's max-health boost, the movement speed, and the event's start shield, which
			-- GrantLoadout's Reset has just zeroed - re-applied from the record, not re-spent
			-- (logic review #23).
			reapplyBoosts(player, humanoid)
			-- Never LOWER a shield the spawn kit already filled (the team kit spawns everyone full).
			if currentEvent and currentEvent.startShield then
				local now = (WeaponService.Get(player) or {}).shield or 0
				WeaponService.SetShield(player, math.max(now, currentEvent.startShield))
			end
		end
		-- Handled by startMatch, which pivots to the spawn point itself.
		return
	end

	-- CharacterAutoLoads is off so eliminated players can spectate. That means a death
	-- outside a match — falling out of the lobby, say — would leave someone dead forever
	-- unless we respawn them ourselves.
	humanoid.Died:Connect(function()
		DeathFxService.Apply(character, "ragdoll")
		task.wait(2.5)
		if player.Parent and not alive[player] then
			pcall(function()
				player:LoadCharacter()
			end)
		end
	end)

	MatchService.PlaceInLobby(player)
	-- The lobby speed through the composition, not PlaceInLobby's plain write, which dropped a
	-- companion speed boon applied first until the next sprint toggle (applySpeed is defined below
	-- PlaceInLobby, so it is called here).
	applySpeed(player)
end

function MatchService.OnPlayerRemoving(player)
	disconnectDeath(player)
	baseSpeeds[player] = nil
	speedBoosts[player] = nil
	sprinting[player] = nil
	slides[player], stamina[player], rateBuckets[player], statusSpeeds[player] = nil, nil, nil, nil
	crouching[player] = nil
	if alive[player] and currentMode.respawn then
		-- S7b. Leaving a respawn mode is not a death. eliminate() handed it to the mode's onDeath, which
		-- scored a "died to the world" point for the other side (a second one if they quit during the
		-- respawn wait) and never took them out of the alive count, so "N ALIVE" overstated by one per
		-- quitter for the rest of the match (logic review #19, #18). Out the way a retired bot goes.
		disconnectDeath(player)
		CombatService.ClearAttacker(player)
		aliveCount -= 1
		participants[player], alive[player] = nil, nil
		concludeIfOver()
	elseif alive[player] then
		eliminate(player, nil)
	elseif placements[player] and state == "InProgress" and Combatants.IsPlayer(player) then
		-- Eliminated, told "placed #N", then left while spectating: finishMatch pays placements only to
		-- players still here, so theirs was never paid. Rank is final at death, so pay it now - this
		-- runs before PlayerData.Release in Bootstrap's leave handler, so it saves (logic review #1).
		-- Through the same AFK rule as everyone else's placement.
		pcall(afk.award, player, placements[player])
	end
	leftSpectate[player] = nil
	afk.players[player] = nil
	regen.forget(player)
	-- Keyed by UserId, so a weak table can't drop it mid-visit; nothing else let it go on leave.
	lastReadyToggle[player.UserId] = nil
	participants[player] = nil
	alive[player] = nil
	placements[player] = nil
	chosenDrop[player] = nil
	grantedBoosts[player] = nil
end

function MatchService.Start()
	buildLobby()
	broadcast()

	task.spawn(function()
		while true do
			task.wait(1)

			if state == "InProgress" then
				local now = tick()
				local seconds = regen.at and math.clamp(now - regen.at, 0, 3) or 1
				regen.at = now
				for token in pairs(participants) do
					if Combatants.IsPlayer(token) and MatchService.IsPlaying(token) then
						local ok, err = pcall(regen.step, token, now, seconds)
						if not ok then
							warn("[MatchService] regen failed: " .. tostring(err))
						end
					end
				end
			else
				regen.at = nil
			end

			if state == "InProgress" and not currentMode.respawn then
				-- The battle royale's participation checks (a respawn mode runs its own, in GameMode).
				afk.tick += 1
				if afk.tick >= afk.every then
					afk.tick = 0
					for token in pairs(participants) do
						if Combatants.IsPlayer(token) and alive[token] then
							local ok, err = pcall(afk.sample, token)
							if not ok then
								warn("[MatchService] participation check failed: " .. tostring(err))
							end
						end
					end
				end
			end

			if state == "Waiting" then
				local readyNow = #readyPlayers()
				if readyNow >= MatchConfig.MinPlayers then
					state = "Countdown"
					-- Everyone already ready (a solo player, always): start at the short count. Starting at
					-- the full one and cutting it on the next tick showed "STARTING IN 15" then "7", a
					-- clock that skipped eight seconds with no word why (#86).
					countdown = readyNow >= #Players:GetPlayers()
						and math.min(MatchConfig.LobbyCountdown, MatchConfig.AllReadyCountdown)
						or MatchConfig.LobbyCountdown
					-- Normally already open since the break began; a fresh server, or a failed start that
					-- closed it, opens it here. Never re-rolled while open: that would wipe the votes cast.
					if not VoteService.IsOpen() then
						VoteService.Open()
					end
				end
				broadcast()
			elseif state == "Intermission" then
				-- Readying up still works during the break; it just can't start the countdown yet. Once
				-- everyone here is ready there is nobody left to wait for, so the rest of the break goes,
				-- all but IntermissionAllReady seconds of it.
				local present = #Players:GetPlayers()
				if present > 0 and #readyPlayers() >= present and countdown > MatchConfig.IntermissionAllReady then
					countdown = MatchConfig.IntermissionAllReady
				end
				countdown -= 1
				if countdown <= 0 then
					countdown = 0
					state = "Waiting"
				end
				broadcast()
			elseif state == "Countdown" then
				-- Everyone unreadying cancels the countdown, back to waiting.
				local readyCount = #readyPlayers()
				if readyCount < MatchConfig.MinPlayers then
					-- The vote stays up: it belongs to the lobby now (it opened when the break began), and
					-- closing it here only to re-roll new cards at the next countdown threw away every vote.
					-- A close with no winner revealed nothing anyway (VoteReveal.ShouldReveal).
					state = "Waiting"
					countdown = 0
				else
					-- Everyone here is ready: nobody left to wait for.
					if readyCount >= #Players:GetPlayers() and countdown > MatchConfig.AllReadyCountdown then
						countdown = MatchConfig.AllReadyCountdown
					end
					countdown -= 1
					if countdown <= 0 then
						-- Map generation touches terrain, pathfinding and a few thousand
						-- parts. An unhandled error here used to kill this whole loop
						-- thread, which meant no match would ever start again for the
						-- life of the server. Fall back to the lobby instead.
						local ok, err = pcall(startMatch)
						if not ok then
							warn("[MatchService] startMatch failed: " .. tostring(err))
							CombatService.SetEnabled(false)
							StormService.Stop()
							SupplyDropService.Stop()
							LootService.Clear()
							BotService.Clear()
							-- A generation failure can leave a half-built map behind.
							MapGenerator.Clear()
							mapInfo = nil
							-- startMatch set the event's gravity before the map build that can throw; only
							-- finishMatch put it back, so a failed Low Gravity start left the lobby at half.
							-- And a respawn mode that got as far as StartWorld keeps running until stopped, as
							-- do the mounted guns OnMapBuilt put up (OnMatchEnd is OnMatchStart's pair).
							workspace.Gravity = NORMAL_GRAVITY
							pcall(currentMode.StopWorld)
							if MatchService.OnMatchEnd then
								pcall(MatchService.OnMatchEnd)
							end
							participants, alive, placements = {}, {}, {}
							aliveCount = 0
							table.clear(leftSpectate)
							-- Nobody is in a match now (startMatch may already have tagged the joiners).
							tagInMatch(Players:GetPlayers())
							state = "Waiting"
							-- A throw inside the drop window unwinds past its `dropSelect = false`, and left set it
							-- rode every later broadcast: the picker opened over the lobby and over every team match
							-- until the next battle royale cleared it (reports/vote-menu-proof.md, section 4). The
							-- team picker's flag and the window's countdown are the same kind of leftover.
							dropSelect = false
							teamSelect = false
							countdown = 0
							-- The state goes out before the close, so no client draws the close's winner reveal
							-- (or keeps a picker up) against a Countdown/Loading it still believes in.
							broadcast()
							-- A throw before VoteService.Close() leaves the vote open with no countdown; close it here. #107
							VoteService.Close()
							for _, player in ipairs(Players:GetPlayers()) do
								WeaponService.Clear(player)
								pcall(function()
									player:LoadCharacter()
								end)
							end
						end
					end
				end
				broadcast()
			end
		end
	end)
end

return MatchService
