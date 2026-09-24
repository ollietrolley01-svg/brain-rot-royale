-- The battle royale state machine: Waiting -> Countdown -> InProgress -> Results.
--
-- Placement is assigned at the moment of death: with N combatants still alive, the one who
-- dies takes rank N. The last standing takes rank 1. Bots fill the lobby up to the cap, so
-- placements stay meaningful on a quiet server — they occupy ranks but never earn rewards.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))

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
local VoteService = require(script.Parent:WaitForChild("VoteService"))
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
local chosenDrop = {}
local participants = {}
local alive = {}
local aliveCount = 0
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
		humanoid.MaxHealth = MatchConfig.StartHealth
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
	local now = os.clock()
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
	return participants[player] == true and not alive[player]
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
function MatchService.LeaveSpectate(player)
	if not MatchService.IsSpectating(player) then
		return false
	end

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
	local bonusHealth, bonusSpeed = 0, 0

	if Monetization.Owns(player, "ExtraHealth") then
		bonusHealth += 50
	end
	if Monetization.Owns(player, "ExtraSpeed") then
		bonusSpeed += 4
	end

	-- One-match boosts, the Pro pair first (2x health, 1.5x speed) then the regular ones (1.5x
	-- health, +4 speed); a pass or a stronger boost already covering the stat leaves the weaker
	-- one unspent.
	local speedScale = 1
	if data then
		local consumables = data.Consumables
		if bonusHealth == 0 and (consumables.HealthPro or 0) > 0 then
			consumables.HealthPro -= 1
			bonusHealth += MatchConfig.StartHealth
		elseif bonusHealth == 0 and consumables.Health > 0 then
			consumables.Health -= 1
			bonusHealth += 50
		end
		if bonusSpeed == 0 and (consumables.SpeedPro or 0) > 0 then
			consumables.SpeedPro -= 1
			speedScale = 1.5
		elseif bonusSpeed == 0 and consumables.Speed > 0 then
			consumables.Speed -= 1
			bonusSpeed += 4
		end
		StateSync.Push(player)
	end

	grantedBoosts[player] = { health = bonusHealth, speed = bonusSpeed, scale = speedScale }
	humanoid.MaxHealth = MatchConfig.StartHealth + bonusHealth
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
	local bonusHealth = granted and granted.health or (Monetization.Owns(player, "ExtraHealth") and 50 or 0)
	local bonusSpeed = granted and granted.speed or (Monetization.Owns(player, "ExtraSpeed") and 4 or 0)
	local speedScale = granted and granted.scale or 1
	humanoid.MaxHealth = MatchConfig.StartHealth + bonusHealth
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
	return MatchService.StaminaTestMode or (state == "InProgress" and participants[token] == true)
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
					and groundUnder(character, humanoid, root) ~= nil
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
	effects[key] = { factor = factor, untilTime = untilTime }
	applySpeed(token)
	task.delay(math.min(duration, 60), function()
		local current = statusSpeeds[token]
		if current and current[key] and current[key].untilTime == untilTime then
			applySpeed(token)
		end
	end)
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

	local total = countKeys(participants)

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
				or RewardService.AwardPlacement(token, rank)
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
		-- A minute's break in the lobby before the next countdown can start.
		state = "Intermission"
		countdown = MatchConfig.Intermission
		broadcast()

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

-- Put the victim's gear back on the map so a kill is worth pushing for.
local function dropLoot(token)
	local root = Combatants.GetRoot(token)
	if not root then
		return
	end
	local position = root.Position

	if Combatants.IsBot(token) then
		if token.weapon then
			LootService.DropWeapon(token.weapon.id, position)
		end
		-- Bots loot heals and shields now, so killing one pays out the same as killing a player.
		local heals = token.heals
		if heals and (heals.Bandage or 0) + (heals.MedKit or 0) > 0 then
			LootService.DropHeal(position)
		end
		local shields = token.shields
		if shields and (shields.MiniShield or 0) + (shields.ShieldPotion or 0) > 0 then
			LootService.DropItem((shields.ShieldPotion or 0) > 0 and "ShieldPotion" or "MiniShield", position, 1)
		end
		if (token.defenses or 0) > 0 then
			LootService.DropItem("RotBarricade", position, token.defenses)
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
		LootService.DropSlot(slot, position)
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
-- `issuedWeaponId` (a bot's kit items are never consumed today, so what it holds was picked up). A
-- pickup that displaced an issued slot is untagged and drops; ammo picked up INTO an issued gun stays
-- with it. Bots track a magazine but no reserve, so a dropped bot gun comes down full, the way the
-- battle royale's do. Coins, XP and mastery are untouched: this is loot, not the reward economy.
local function dropPickedUp(token)
	local root = Combatants.GetRoot(token)
	if not root then
		return
	end
	local position = root.Position
	if Combatants.IsBot(token) then
		if token.weapon and token.weapon.id and token.weapon.id ~= token.issuedWeaponId then
			LootService.DropWeapon(token.weapon.id, position)
		end
		local heals = token.heals
		if heals and (heals.Bandage or 0) + (heals.MedKit or 0) > 0 then
			LootService.DropHeal(position)
		end
		local shields = token.shields
		if shields and (shields.MiniShield or 0) + (shields.ShieldPotion or 0) > 0 then
			LootService.DropItem((shields.ShieldPotion or 0) > 0 and "ShieldPotion" or "MiniShield", position, 1)
		end
		if (token.defenses or 0) > 0 then
			LootService.DropItem("RotBarricade", position, token.defenses)
		end
		return
	end
	local loadout = WeaponService.Get(token)
	if not loadout then
		return
	end
	for _, slot in pairs(loadout.slots) do
		if not slot.issued then
			LootService.DropSlot(slot, position)
		end
	end
end

-- `method` (optional) names what did it, for the kill feed. `weaponId` (optional) is the raw id of
-- what landed the last hit, for gun mastery.
local function eliminate(token, killerToken, method, weaponId)
	if not alive[token] then
		return
	end

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
	disconnectDeath(token)
	CombatService.ClearAttacker(token)

	killFeed:FireAllClients({
		victim = Combatants.GetName(token),
		killer = killerToken and Combatants.GetName(killerToken) or nil,
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
			bounty:FireAllClients({ claimed = true, name = Combatants.GetName(token), by = Combatants.GetName(killerToken), reward = reward })
		else
			bounty:FireAllClients(nil)
		end
	end

	if Combatants.IsPlayer(killerToken) and killerToken ~= token and participants[killerToken] then
		RewardService.AwardKill(killerToken, Combatants.IsBot(token))
		-- Set by Bootstrap to ProgressionService.OnKillCredited (gun mastery). It ignores anything
		-- that isn't a WeaponData gun: companions, barrels and mines.
		if MatchService.OnKillCredited then
			MatchService.OnKillCredited(killerToken, token, weaponId)
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
			bounty:FireAllClients({ name = Combatants.GetName(killerToken), kills = streak.total, reward = bountyReward })
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
	if weaponDef and weaponDef.ability == "goldRush" and Combatants.IsPlayer(killer) then
		RewardService.AwardBonusCoins(killer, weaponDef.goldRushBonus or 100, "Gold Rush")
	end

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

	mapInfo = MapGenerator.Build(winningMap)
	-- A Night Ops match lays its own lighting over the map's time of day.
	MapGenerator.ApplyLightingOverride(event.lighting)
	LootService.Populate(mapInfo)
	BotService.Clear()

	participants = {}
	alive = {}
	placements = {}
	aliveCount = 0
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
		end
		dropSelect = false
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
				local deadline = os.clock() + 10
				repeat
					task.wait(0.1)
					character = player.Character
				until character or os.clock() > deadline or not player.Parent
			end

			local humanoid = character and character:WaitForChild("Humanoid", 10)
			if not humanoid then
				failSpawn(player)
				return
			end

			Combatants.Register(character, player)
			applyBoosts(player, humanoid)
			WeaponService.Reset(player)
			if currentEvent and currentEvent.startShield then
				WeaponService.SetShield(player, currentEvent.startShield)
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
				StateSync.Notify(player, "Dropping in — steer with WASD, look for a landmark")
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
			end

			BotService.Start()
			broadcast()
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
			if currentEvent and currentEvent.startShield then
				WeaponService.SetShield(player, currentEvent.startShield)
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
		pcall(RewardService.AwardPlacement, player, placements[player])
	end
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

			if state == "Waiting" then
				if #readyPlayers() >= MatchConfig.MinPlayers then
					state = "Countdown"
					countdown = MatchConfig.LobbyCountdown
					VoteService.Open()
				end
				broadcast()
			elseif state == "Intermission" then
				-- Readying up still works during the break; it just can't start the countdown yet.
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
					state = "Waiting"
					countdown = 0
					VoteService.Close()
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
							participants, alive, placements = {}, {}, {}
							aliveCount = 0
							state = "Waiting"
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
