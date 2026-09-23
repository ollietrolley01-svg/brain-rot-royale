-- Wires every service together and owns the remote surface. Services stay unaware of each
-- other's remotes; everything routes through here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))

local Modules = ServerScriptService:WaitForChild("Modules")
-- Requiring it is what arms it: AdminService wires its own remotes and greets the admin on join.
local AdminService = require(Modules:WaitForChild("AdminService"))
local BattlePassService = require(Modules:WaitForChild("BattlePassService"))
local BrainrotShopService = require(Modules:WaitForChild("BrainrotShopService"))
local CombatService = require(Modules:WaitForChild("CombatService"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local CrateService = require(Modules:WaitForChild("CrateService"))
local MatchService = require(Modules:WaitForChild("MatchService"))
local Monetization = require(Modules:WaitForChild("Monetization"))
local NameplateService = require(Modules:WaitForChild("NameplateService"))
local AuraService = require(Modules:WaitForChild("AuraService"))
local AccessoryService = require(Modules:WaitForChild("AccessoryService"))
local CompanionService = require(Modules:WaitForChild("CompanionService"))
local DeathFxService = require(Modules:WaitForChild("DeathFxService"))
local DefenseService = require(Modules:WaitForChild("DefenseService"))
-- The picture of the match's terrain the drop picker draws: sampled once a match and cached
-- on the server, because streaming means a client has almost none of the map.
local DropMapService = require(Modules:WaitForChild("DropMapService"))
-- Launcher rounds, grenades, smoke, and the splat where a bullet lands. Both hook themselves in.
local HitSplatService = require(Modules:WaitForChild("HitSplatService"))
local HazardService = require(Modules:WaitForChild("HazardService"))
local ProjectileService = require(Modules:WaitForChild("ProjectileService"))
-- The creative guns' knockback, bleed, ignite and chill; hooks itself in the same way.
local StatusEffects = require(Modules:WaitForChild("StatusEffects"))
local MovementService = require(Modules:WaitForChild("MovementService"))
local MovementSanity = require(Modules:WaitForChild("MovementSanity"))
local LobbyService = require(Modules:WaitForChild("LobbyService"))
local LootService = require(Modules:WaitForChild("LootService"))
local AchievementService = require(Modules:WaitForChild("AchievementService"))
local PlayerData = require(Modules:WaitForChild("PlayerData"))
local PlaytimeService = require(Modules:WaitForChild("PlaytimeService"))
local ProgressionService = require(Modules:WaitForChild("ProgressionService"))
local QuestService = require(Modules:WaitForChild("QuestService"))
local RateLimit = require(Modules:WaitForChild("RateLimit"))
local RewardService = require(Modules:WaitForChild("RewardService"))
local ShowcaseService = require(Modules:WaitForChild("ShowcaseService"))
local StateSync = require(Modules:WaitForChild("StateSync"))
local TradeService = require(Modules:WaitForChild("TradeService"))
local VehicleService = require(Modules:WaitForChild("VehicleService"))
local VoteService = require(Modules:WaitForChild("VoteService"))
local WeaponService = require(Modules:WaitForChild("WeaponService"))

-- Every autosave also refreshes the profile's session lock (PlayerData), so this has to stay well
-- inside its stale timeout: 60 s against 150 s. At a full 50-player server that's ~50 DataStore writes
-- a minute, against a budget of 60 + 10 per player.
local AUTOSAVE_INTERVAL = 60
-- The last profile snapshot built for each player, and how long one may be reused (see the
-- RequestProfile remote). Cleared when they leave.
local profileSnapshots = {}
local PROFILE_SNAPSHOT_CACHE = 1
-- "senderId>targetId" -> os.clock() of the last trade invite, for the per-target cooldown.
local tradeInviteAt = {}
local TRADE_INVITE_COOLDOWN = 10

-- Spawning is managed explicitly: eliminated players spectate until the match resets
-- instead of auto-respawning into an empty lobby mid-round.
Players.CharacterAutoLoads = false

-- Bodies ragdoll, float, burn or shatter by the gun that got them.
CombatService.OnDeathFx = DeathFxService.OnDeath

-- A crouched, still shooter gets a steadier gun. MatchService requires CombatService, so the
-- crouch state is handed over rather than required back.
CombatService.IsCrouching = MatchService.IsCrouching

--------------------------------------------------------------------------------
-- Monetization grants
--------------------------------------------------------------------------------

-- Each handler only changes the profile, checking first, and hands back an `announce` function for the
-- toasts and pushes. Monetization.HandleReceipt runs that after the purchase is recorded and saved, so
-- a failing toast can never make a paid receipt look ungranted and get it granted twice.
Monetization.RegisterGrantHandler("Coins", function(player, data, grant)
	data.SahurCoins += grant.amount
	return function()
		StateSync.Notify(player, string.format("+%d SahurCoins", grant.amount))
		StateSync.Push(player)
	end
end)

Monetization.RegisterGrantHandler("Crate", function(player, _data, grant)
	-- A Robux crate: counted as paid, so what it pulls is recorded in the Rot Index without Cells.
	if not CrateService.GivePaid(player, grant.crate, 1) then
		error("crate product for unknown crate " .. tostring(grant.crate))
	end
	return function()
		-- The crate's own name, not its key with "Crate" glued on: the cosmetic tiers are keyed
		-- DeluxeStyle and PrestigeStyle, which read as "+1 DeluxeStyle Crate" the old way.
		local crate = require(Shared:WaitForChild("CrateData")).Get(grant.crate)
		StateSync.Notify(player, "+1 " .. ((crate and crate.name) or (grant.crate .. " Crate")))
		StateSync.Push(player)
	end
end)

Monetization.RegisterGrantHandler("Consumable", function(player, data, grant)
	data.Consumables[grant.consumable] = (data.Consumables[grant.consumable] or 0) + grant.amount
	return function()
		StateSync.Notify(player, string.format("+%d one-match %s boost", grant.amount, grant.consumable))
		StateSync.Push(player)
	end
end)

-- Everything in a bundle lands at once. It's all checked before anything is handed over, so a bad
-- entry fails the whole receipt (and it's retried) rather than half-granting it. Exclusives the
-- player already owns turn into coins, so buying a bundle twice is never wasted.
local bundleGranted = Remotes.Event("BundleGranted")

Monetization.RegisterGrantHandler("Bundle", function(player, data, grant, product)
	for _, entry in ipairs(grant.contents) do
		local valid = (entry.kind == "Coins" and type(entry.amount) == "number")
			or (entry.kind == "Crate" and data.Crates[entry.crate] ~= nil)
			or (entry.kind == "Consumable" and data.Consumables[entry.consumable] ~= nil)
			or (entry.kind == "Cosmetic" and CosmeticData.Get(entry.id) ~= nil)
		if not valid then
			error(string.format("%s has a bad %s entry", product.key, tostring(entry.kind)))
		end
	end

	local refunded = 0
	for _, entry in ipairs(grant.contents) do
		if entry.kind == "Coins" then
			data.SahurCoins += entry.amount
		elseif entry.kind == "Crate" then
			-- Bundle crates are bought with Robux too (see the Crate handler above).
			data.Crates[entry.crate] += entry.amount or 1
			data.PaidCrates[entry.crate] = (data.PaidCrates[entry.crate] or 0) + (entry.amount or 1)
		elseif entry.kind == "Consumable" then
			data.Consumables[entry.consumable] += entry.amount or 1
		elseif entry.kind == "Cosmetic" then
			if data.Cosmetics.owned[entry.id] then
				refunded += grant.duplicateCoins or 0
			else
				data.Cosmetics.owned[entry.id] = true
			end
		end
	end
	data.SahurCoins += refunded
	data.Bundles[product.key] = (data.Bundles[product.key] or 0) + 1

	return function()
		bundleGranted:FireClient(player, product.key, refunded)
		StateSync.Push(player)
	end
end)

-- A brainrot bought with Robux: the one the player picked (BrainrotShopService explains how the pick
-- is tied to the purchase). It opens with the crate reveal, in the rarity's colours.
local brainrotPurchaseReveal = Remotes.Event("CrateOpened")
Monetization.RegisterGrantHandler("Brainrot", function(player, data, grant)
	local def, chosen = BrainrotShopService.Grant(player, data, grant)
	-- Straight after the grant, with nothing in between that could yield: a brainrot bought with
	-- Robux goes into the Rot Index as discovered but never pays Brain Cells (ProgressionService).
	-- In its own pcall: the brainrot is already in the profile, so an error here must not fail the
	-- receipt.
	if ProgressionService.RecordPurchased then
		local recorded, err = pcall(ProgressionService.RecordPurchased, player, def.name)
		if not recorded then
			warn("[Bootstrap] RecordPurchased failed for a bought " .. def.name .. ": " .. tostring(err))
		end
	end
	return function()
		local colour = require(Shared:WaitForChild("Rarity")).Color(def.rarity)
		brainrotPurchaseReveal:FireClient(player, {
			crate = def.rarity .. " Brainrot",
			crateId = def.rarity,
			crateColor = colour,
			rarity = def.rarity,
			kind = "Brainrot",
			name = def.name,
			coinValue = def.coinValue,
		})
		StateSync.Notify(player, chosen and string.format("Bought %s!", def.name)
			or string.format("Bought a %s brainrot: %s (your pick didn't reach the server, so it's one you didn't have yet).", def.rarity, def.name))
		RewardService.CheckCollections(player)
		StateSync.Push(player)
	end
end)

Monetization.Init(function(player)
	StateSync.Push(player)
end)

--------------------------------------------------------------------------------
-- Player lifecycle
--------------------------------------------------------------------------------

local function setupLeaderstats(player, data)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Value = data.Stats.wins
	wins.Parent = leaderstats

	local kills = Instance.new("IntValue")
	kills.Name = "Kills"
	kills.Value = data.Stats.kills
	kills.Parent = leaderstats

	leaderstats.Parent = player
end

local function refreshLeaderstats(player)
	local data = PlayerData.Get(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not data or not leaderstats then
		return
	end
	local wins = leaderstats:FindFirstChild("Wins")
	local kills = leaderstats:FindFirstChild("Kills")
	if wins then
		wins.Value = data.Stats.wins
	end
	if kills then
		kills.Value = data.Stats.kills
	end
end

local function onPlayerAdded(player)
	-- #102: not in any match until startMatch says so. The client's spectator cycle reads this off the
	-- Player and treats an ABSENT attribute as "in" (so the read is inert wherever the write is not),
	-- which is why a mid-match joiner is told `false` here rather than left unset.
	player:SetAttribute("InMatch", false)
	player.CharacterAdded:Connect(function(character)
		MatchService.OnCharacterAdded(player, character)
		WeaponService.RefreshHeldGun(player)
	end)

	player.CharacterRemoving:Connect(function(character)
		Combatants.Unregister(character)
	end)

	-- Spawn BEFORE loading the profile. PlayerData.Load can sit there for many seconds
	-- retrying an unavailable DataStore, and with CharacterAutoLoads off that would leave
	-- the player with no character — and no world to look at — for the whole wait.
	if player.Character then
		MatchService.OnCharacterAdded(player, player.Character)
	else
		pcall(function()
			player:LoadCharacter()
		end)
	end

	local data = PlayerData.Load(player)
	if not player.Parent then
		PlayerData.Release(player)
		return
	end

	Monetization.Refresh(player)
	setupLeaderstats(player, data)
	BattlePassService.SyncTier(player)
	-- Profiles from before an achievement existed catch up here.
	AchievementService.SyncTitle(player)
	AchievementService.Check(player)
	-- Rot Rank and the Rot Index: a profile from before progression is backfilled once, and rank
	-- and prestige go on the player for nameplates.
	ProgressionService.OnProfileLoaded(player)
	-- Beginner's Luck: the one-off grant of its charges, once per profile, before the first push (see
	-- CrateService). Nothing in the menu says it exists.
	CrateService.GrantBeginnerLuck(player)
	StateSync.Push(player)

	-- The character spawns before the profile loads, so its first spawn had no cosmetics to
	-- draw. Apply them now that the data is here.
	AuraService.Apply(player, player.Character)
	AccessoryService.Apply(player, player.Character)
	CompanionService.Refresh(player)
	-- Collections completed before sets existed still pay out, once.
	RewardService.CheckCollections(player)

	-- Re-broadcast so someone joining mid-countdown sees the vote already in progress.
	--
	-- GATED ON open, and the gate is the whole point (#107, "game choosing menu pulls up randomly
	-- mid match"). VoteService.Resolve caches its pick until the next Open(), so from the moment a
	-- match starts until the next lobby countdown the snapshot still reads `open = false` with a
	-- `winner` set -- and that pair is exactly the cue VoteDropClient treats as "reveal the
	-- result". Broadcast is FireAllClients, so an ungated call here popped the mode/map reveal onto
	-- EVERY player's screen for three seconds every time anybody joined the server mid-match.
	-- Random from the player's side, because he cannot see who is joining.
	--
	-- A snapshot is not an event: the winner field stays true for a whole match, so anything that
	-- resends it re-fires the reveal. VoteService.Forget already gates its own rebroadcast on
	-- `if open`; this was the one path of the two that did not.
	if VoteService.IsOpen() then
		VoteService.Broadcast()
	end
	ShowcaseService.Refresh()

	-- The new arrival changes everyone else's trade list.
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			StateSync.Push(other)
		end
	end
end

local function onPlayerRemoving(player)
	MatchService.OnPlayerRemoving(player)
	WeaponService.Clear(player)
	CombatService.ForgetToken(player)
	Monetization.Clear(player)
	RateLimit.Clear(player)
	-- Snapshots are coalesced to one a frame (StateSync.Push), so send anything still waiting for
	-- this player before their profile is released below.
	StateSync.Flush(player)
	profileSnapshots[player] = nil
	for pair in pairs(tradeInviteAt) do
		if string.find(pair, tostring(player.UserId), 1, true) then
			tradeInviteAt[pair] = nil
		end
	end
	PlayerData.Release(player)

	task.defer(function()
		ShowcaseService.Refresh()
		for _, other in ipairs(Players:GetPlayers()) do
			StateSync.Push(other)
		end
	end)
end

-- The lobby MUST exist before anyone is spawned into it. PlaceInLobby teleports to
-- LobbyPosition, and if the platform isn't built yet the player drops through empty space,
-- dies, respawns and falls again — which reads as "the game doesn't load".
-- No ground fog. The place ships without an Atmosphere, but Studio or a plugin can add one
-- back, and even a light one lays a grey film along the ground on maps this big.
do
	local Lighting = game:GetService("Lighting")
	Lighting.FogStart = 0
	Lighting.FogEnd = 100000
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Atmosphere") then
			child.Density = 0
			child.Haze = 0
			child.Glare = 0
		end
	end
end

ShowcaseService.Start()
BrainrotShopService.Start()
NameplateService.Start()
AuraService.Start()
AccessoryService.Start()
CompanionService.IsFighting = function(player)
	return MatchService.IsAlive(player)
end
CompanionService.OnLevelUp = function(player, name, level, bonusPercent)
	StateSync.Notify(player, string.format("%s reached level %d!  +%d%% damage and health", name, level, bonusPercent))
	StateSync.Push(player)
end
MovementService.SetSpeedBoost = MatchService.ApplySpeedBoost
-- The stamina ledger lives in MatchService; MovementService charges climbs and vaults against it.
MovementService.SpendStamina = MatchService.SpendStamina
MovementService.GetStamina = MatchService.GetStamina
-- A climb or a vault stands the body up first, the way it does for a player.
MovementService.SetCrouching = MatchService.SetCrouching
-- Vaulting through a window breaks the panes the body passes, with the same shatter a shot through them
-- gives: one DamageDestructible per pane (DestructibleService's hook on CombatService, set when it loads).
MovementService.BreakPane = function(token, pane, from)
	if not CombatService.DamageDestructible then
		return false
	end
	return CombatService.DamageDestructible(token, pane, 1, from) > 0
end
-- The movement sanity monitor watches players in a running match only, and only ever counts (see its
-- header). Vehicles fall back to its own seat allowance, which clears the fastest vehicle (92).
MovementSanity.IsActive = function(player)
	return MatchService.GetState() == "InProgress" and MatchService.IsParticipant(player)
end
-- Parachutes: which canopy MovementService opens over a character on the drop-in and with the Rot
-- Glider, as an id for Shared/ParachuteModels (nil is the default Rot Glider canopy). A player gets
-- the one they have equipped, if they still own it. A bot sometimes gets a shop parachute, mostly
-- the common ones, so the designs turn up in the sky; its own Random leaves math.random alone.
do
	local BOT_CHANCE = 0.45
	local BOT_WEIGHT = { Common = 6, Uncommon = 3, Rare = 1.5, Epic = 0.6 }
	local botPool, botTotal = {}, 0
	for _, id in ipairs(CosmeticData.OfKind("Parachute", true)) do
		local weight = BOT_WEIGHT[CosmeticData.Get(id).rarity]
		if weight then
			table.insert(botPool, { id = id, weight = weight })
			botTotal += weight
		end
	end
	local botRandom = Random.new()

	MovementService.ParachuteFor = function(character)
		local player = Players:GetPlayerFromCharacter(character)
		if player then
			local data = PlayerData.Get(player)
			local id = data and data.Cosmetics.parachute
			if id and data.Cosmetics.owned[id] then
				return id
			end
			return nil
		end
		if #botPool == 0 or botRandom:NextNumber() > BOT_CHANCE then
			return nil
		end
		local roll = botRandom:NextNumber() * botTotal
		for _, entry in ipairs(botPool) do
			roll -= entry.weight
			if roll <= 0 then
				return entry.id
			end
		end
		return botPool[#botPool].id
	end
end
LobbyService.OnReadyPad = function(player)
	MatchService.SetReady(player, true)
end
-- Cloud Climb obby: the time every clear, and 250 SahurCoins the first clear per server.
LobbyService.OnObbyComplete = function(player, seconds, firstClear, isRecord)
	-- The clear is announced whatever happens, and the coins are their own line. It used to hand the
	-- whole sentence to AwardBonusCoins as the bracketed "reason", which read as
	-- "+250 SahurCoins (Cloud Climb cleared in 12.3s — server record!)" -- the record, the thing the
	-- player actually did, arriving as a footnote to the payment. It also meant the announcement only
	-- went out if coins landed, so a first clear on a profile that had not loaded said nothing at all.
	StateSync.Notify(player, string.format("Cloud Climb cleared in %.1fs%s", seconds,
		isRecord and " — server record!" or ""))
	if firstClear then
		RewardService.AwardBonusCoins(player, 250, "first clear")
	end
	QuestService.Progress(player, "obby", 1)
end
-- The lobby pitch: a goal pays a few coins (LobbyService rate-limits it) and counts for quests.
LobbyService.OnGoal = function(player)
	RewardService.AwardBonusCoins(player, 35, "GOAL!")
	QuestService.Progress(player, "goals", 1)
end
-- The daily wheel is the daily reward from the Pass tab, claimed by spinning it in person. The
-- third value is the segment it landed on, for the wheel.
LobbyService.OnDailySpin = function(player)
	local success, message, segment = BattlePassService.ClaimDaily(player)
	if success then
		refreshLeaderstats(player)
		-- The wheel can hand out a brainrot.
		ProgressionService.RecordIndex(player)
	end
	return success, message, segment
end
-- Progression: every point of pass XP also feeds Rot Rank, and credited gun kills feed mastery.
ProgressionService.Start()
-- Compounding coins for every ten active minutes in one visit (#76).
PlaytimeService.Start()
BattlePassService.OnXp = ProgressionService.OnPassXp
MatchService.OnKillCredited = ProgressionService.OnKillCredited
MatchService.ProgressionSummary = ProgressionService.MatchSummary
TradeService.OnTradeMoved = ProgressionService.OnTradeMoved
LobbyService.Start()
CompanionService.Start()
-- The drive loop for map vehicles. Safe to start before any map exists: it only ever walks the
-- vehicles that have registered themselves, and prunes them when their map is destroyed.
VehicleService.Start()
MatchService.Start()

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

--------------------------------------------------------------------------------
-- Combat remotes
--------------------------------------------------------------------------------

-- Every remote below is rate-limited (RateLimit.Budgets says what each budget is sized against).
-- Dropped calls are silent: the budgets sit well above anything this game's own client sends.
Remotes.Event("Fire").OnServerEvent:Connect(function(player, direction)
	if not RateLimit.Take(player, "Fire") then
		return
	end
	CombatService.Fire(player, direction)
end)

-- Latest, not dropped: each switch rebuilds and replicates the held gun, but dropping the LAST
-- switch of a fast weapon-wheel spin would leave the server holding a different gun from the one the
-- client is already drawing.
Remotes.Event("EquipSlot").OnServerEvent:Connect(function(player, slotIndex)
	RateLimit.Latest(player, "EquipSlot", slotIndex, function(index)
		WeaponService.Equip(player, index)
	end)
end)

Remotes.Event("ReloadWeapon").OnServerEvent:Connect(function(player)
	if not RateLimit.Take(player, "Reload") then
		return
	end
	WeaponService.Reload(player)
end)

-- Right-clicking a hotbar cell drops what's in it at your feet, for making room.
Remotes.Event("DropSlot").OnServerEvent:Connect(function(player, slotIndex)
	if not RateLimit.Take(player, "DropSlot") or not MatchService.IsAlive(player) then
		return
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local slot = root and WeaponService.TakeSlot(player, slotIndex)
	if slot then
		LootService.DropSlot(slot, root.Position + root.CFrame.LookVector * 3, root.Position)
	end
end)

-- HUD & UX: rearranging the hotbar from the Inventory panel (StarterPlayerScripts/InventoryPanel). Two
-- slot numbers; WeaponService.SwapSlots checks them again and keeps what's in hand in hand. Both must be
-- real whole numbers 1-8 (SafeValue first: NaN and infinity fail every other test). At most SWAP_BURST
-- swaps in a row, refilling SWAP_RATE a second, so a modified client can't spam loadout pushes.
do
	local SWAP_BURST, SWAP_RATE = 8, 6
	local swapBudget = {}
	Remotes.Event("SwapSlots").OnServerEvent:Connect(function(player, a, b)
		if not SafeValue.Number(a, WeaponService.SlotCount) or not SafeValue.Number(b, WeaponService.SlotCount)
			or a % 1 ~= 0 or b % 1 ~= 0 or a < 1 or b < 1 then
			return
		end
		local now = os.clock()
		local budget = swapBudget[player]
		if not budget then
			budget = { tokens = SWAP_BURST, at = now }
			swapBudget[player] = budget
		end
		budget.tokens = math.min(SWAP_BURST, budget.tokens + (now - budget.at) * SWAP_RATE)
		budget.at = now
		if budget.tokens < 1 then
			return
		end
		budget.tokens -= 1
		WeaponService.SwapSlots(player, a, b)
	end)
	Players.PlayerRemoving:Connect(function(player)
		swapBudget[player] = nil
	end)
end

Remotes.Event("SetAiming").OnServerEvent:Connect(function(player, value)
	RateLimit.Latest(player, "SetAiming", value, function(latest)
		CombatService.SetAiming(player, latest)
	end)
end)

Remotes.Event("SetSprinting").OnServerEvent:Connect(function(player, value)
	RateLimit.Latest(player, "SetSprinting", value == true, function(latest)
		MatchService.SetSprinting(player, latest)
	end)
end)

-- Crouching, the same shape: a state setter, so the newest value is what lands. MatchService holds the
-- speed factor and the height; SetCrouching is idempotent and refuses while seated. (It shared the
-- sprint bucket until RateLimit grew one of its own.)
Remotes.Event("SetCrouching").OnServerEvent:Connect(function(player, value)
	RateLimit.Latest(player, "SetCrouching", value == true, function(latest)
		MatchService.SetCrouching(player, latest)
	end)
end)

-- The client's slide ended early (slowed, jumped, blocked, airborne): drop the speed ceiling now.
-- Only acts on a slide that's actually on, so spamming it does nothing.
Remotes.Event("SlideEnd").OnServerEvent:Connect(function(player)
	if not RateLimit.Take(player, "Slide") then
		return
	end
	MatchService.EndSlide(player)
end)

-- The client climbed a ledge or vaulted something (it simulates its own body, so it runs the move):
-- MovementService charges the stamina, rate-limits, and poses the body for everyone else.
Remotes.Event("Parkour").OnServerEvent:Connect(function(player, kind, rise, duration)
	if not RateLimit.Take(player, "Parkour") then
		return
	end
	MovementService.ClientParkour(player, kind, rise, duration)
end)

-- A slide. The server decides whether it counts: you must be sprinting, not exhausted, alive, on the
-- ground, off cooldown and not on NoMantle ground; it costs stamina.
Remotes.Event("Slide").OnServerEvent:Connect(function(player)
	if not RateLimit.Take(player, "Slide") then
		return
	end
	MatchService.StartSlide(player)
end)

-- Picking a landing spot during the drop window. The server validates the point and the timing.
Remotes.Event("ChooseDrop").OnServerEvent:Connect(function(player, x, z)
	RateLimit.Latest(player, "ChooseDrop", { x = x, z = z }, function(latest)
		MatchService.ChooseDrop(player, latest.x, latest.z)
	end)
end)

-- The drop map itself: the raster the picker draws, asked for once as the window opens. Sampled and
-- cached on the server (DropMapService), so fifty clients asking at once cost one sample. Limited
-- rather than exempt because it is the largest answer any remote here gives.
Remotes.Function("GetDropMap").OnServerInvoke = function(player)
	if not RateLimit.Take(player, "DropMap") then
		return nil
	end
	return DropMapService.Current()
end

-- A click with an item in hand: start using it. Only while alive in a match. Refusals that are
-- worth explaining ("already at full health") come back as a toast.
Remotes.Event("UseSelected").OnServerEvent:Connect(function(player, aimPoint, slotIndex)
	if not RateLimit.Take(player, "UseSelected") or not MatchService.IsAlive(player) then
		return
	end
	-- Any component NaN or infinite is refused, not just a wrong type (see SafeValue).
	if aimPoint ~= nil and not SafeValue.Vector3(aimPoint) then
		return
	end
	-- `slotIndex` is the Quick Movement key's slot; StartUse validates it (a real whole number naming a
	-- slot that holds a movement item).
	local ok, reason = WeaponService.StartUse(player, aimPoint, slotIndex)
	if not ok and reason then
		StateSync.Notify(player, reason, true)
	end
end)

-- The companion hotkey. The client sends where it's aiming; the server picks the target and
-- owns the cooldown.
Remotes.Event("CompanionAbility").OnServerEvent:Connect(function(player, aimPoint)
	if not RateLimit.Take(player, "CompanionAbility") then
		return
	end
	if aimPoint ~= nil and not SafeValue.Vector3(aimPoint) then
		return
	end
	CompanionService.UseAbility(player, aimPoint)
end)

-- Ready up / stay in the lobby. Only readied players are pulled into the next match.
Remotes.Event("SetReady").OnServerEvent:Connect(function(player, value)
	if type(value) ~= "boolean" then
		return
	end
	RateLimit.Latest(player, "SetReady", value, function(latest)
		MatchService.SetReady(player, latest)
	end)
end)

-- With StreamingEnabled the server replicates around the player's own character, so a
-- spectator watching someone across the map would see nothing. Point replication at
-- whoever they're following instead.
-- The checks, run on whichever focus the rate limit settles on (see the remote below).
local function setReplicationFocus(player, part)
	if part == nil then
		player.ReplicationFocus = nil
		return
	end
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") or not part.Parent then
		return
	end

	-- Only while spectating, and only onto a combatant's body. Accepting any part at any time
	-- let a modified client point streaming at, say, a spot beside an enemy it can't see yet
	-- and have the server replicate that region to it. Spectating means a dead PARTICIPANT of the
	-- running match: without that, anyone sitting in the lobby could stream the match and pass on
	-- what they saw.
	--
	-- Through MatchService.IsSpectating, which is that same rule written once. It used to be spelled
	-- out here as `IsAlive or not IsParticipant`; now that there is an EXIT from spectating (#102)
	-- there are two places that must agree on who is spectating, and two spellings of one rule is
	-- how they drift -- a player who had left would keep streaming the arena from the lobby.
	-- Both halves of the rule -- who may spectate, and which body they may stream around -- live in
	-- MatchService.FocusTarget beside IsSpectating and LeaveSpectate, so the three cannot drift. The
	-- target test that used to sit here accepted any Player's character (Combatants.FromCharacter falls
	-- back to Players:GetPlayerFromCharacter), which let a modified client stream the arena from a
	-- lobby idler's body; the target must now be alive in the match's own table (#102).
	local focus = MatchService.FocusTarget(player, part)
	if not focus then
		return
	end

	player.ReplicationFocus = focus
end

-- #102: the way OUT of spectating. Until this existed the only exit was the end of the match, so an
-- early elimination meant watching until the reset with no control that did anything.
--
-- RateLimit.Take, not Latest: this is a door, not a state. Over budget the press is dropped and
-- costs one more press, whereas a QUEUED press would fire a respawn seconds later, after the player
-- had given up on the button and the match had moved on underneath them.
--
-- No arguments, so there is nothing to validate: the server decides entirely from its own state
-- whether this player is spectating, and MatchService.LeaveSpectate refuses anyone who is not.
Remotes.Event("LeaveSpectate").OnServerEvent:Connect(function(player)
	if not RateLimit.Take(player, "LeaveSpectate") then
		return
	end
	MatchService.LeaveSpectate(player)
end)

Remotes.Event("SetReplicationFocus").OnServerEvent:Connect(function(player, part)
	if part ~= nil and typeof(part) ~= "Instance" then
		return
	end
	RateLimit.Latest(player, "SetReplicationFocus", part, function(latest)
		setReplicationFocus(player, latest)
	end)
end)

--------------------------------------------------------------------------------
-- Menu remotes
--------------------------------------------------------------------------------

local function guard(handler)
	return function(player, ...)
		local data = PlayerData.Get(player)
		if not data then
			pcall(StateSync.Notify, player, "Profile still loading.", true)
			return false, "Profile still loading."
		end
		-- One shared budget for the menu: each of these ends in a profile push and a leaderstats
		-- refresh, which is the cost worth capping. Over budget the call is dropped silently: no
		-- toast, no kick, and the budget is far above human clicking (RateLimit.Budgets.Menu).
		if not RateLimit.Take(player, "Menu") then
			return false, nil
		end
		local ok, success, message = pcall(handler, player, ...)
		if not ok then
			warn("[Bootstrap] Remote handler error: " .. tostring(success))
			pcall(StateSync.Notify, player, "Something went wrong.", true)
			return false, "Something went wrong."
		end
		-- THE ONE PLACE A MENU REMOTE'S ANSWER REACHES THE PLAYER. The client fires and forgets on
		-- purpose (MenuClient's invoke discards the reply: the profile push re-renders the tab), so a
		-- message a handler returns is heard only if it is toasted here. Before this, every refusal
		-- and every receipt written on the server -- "you can't sell your last copy", "that request
		-- expired", "Sold 4 Uncommon brainrots" -- was generated and thrown away, and a button that
		-- silently refused looked exactly like one that silently worked. A nil message stays silent
		-- (a rate-limited call, a settings save); a failure is red. The rule that goes with it: no
		-- guarded handler, and no service it calls, toasts the CALLER the message it also returns --
		-- tools/menu_reply_probe.lua counts those sites to zero. pcall'd, because a toast at a player
		-- on their way out must not take the reply with it.
		if message ~= nil then
			pcall(StateSync.Notify, player, message, not success)
		end
		refreshLeaderstats(player)
		return success, message
	end
end

-- Never refused, so a menu that asks always gets an answer. But a full snapshot is expensive to
-- build, so one asked for again within CACHE seconds gets the last one (RateLimit.Exempt says so).
Remotes.Function("RequestProfile").OnServerInvoke = function(player)
	local cached = profileSnapshots[player]
	local now = os.clock()
	if cached and now - cached.at < PROFILE_SNAPSHOT_CACHE then
		return cached.snapshot
	end
	local snapshot = StateSync.Build(player)
	profileSnapshots[player] = { snapshot = snapshot, at = now }
	return snapshot
end

-- Settings menu. The profile may still be loading when the client asks, so wait for it.
-- One waiting call per player: this one polls for up to 20 seconds, so a client calling it in a loop
-- would otherwise pile up threads. A second call while one waits answers with whatever has loaded.
local settingsWaiting = {}

Remotes.Function("GetSettings").OnServerInvoke = function(player)
	local data = PlayerData.Get(player)
	if not data and not settingsWaiting[player] then
		settingsWaiting[player] = true
		local waited = 0
		while not data and waited < 20 and player.Parent do
			task.wait(0.5)
			waited += 0.5
			data = PlayerData.Get(player)
		end
		settingsWaiting[player] = nil
	end
	return data and data.Settings or nil
end

-- Latest, not dropped: the settings menu debounces already, and the last values sent are the ones
-- the player means to keep.
Remotes.Function("SaveSettings").OnServerInvoke = guard(function(player, settings)
	RateLimit.Latest(player, "SaveSettings", settings, function(latest)
		local data = PlayerData.Get(player)
		if data then
			data.Settings = PlayerData.SanitizeSettings(latest)
		end
	end)
	return true
end)

Remotes.Function("CastVote").OnServerInvoke = function(player, mapId)
	if type(mapId) ~= "string" then
		return false, "Invalid map."
	end
	-- Not through guard(): it answers before a profile exists. It takes from the same menu budget,
	-- since a vote broadcasts to everyone in the lobby.
	if not RateLimit.Take(player, "Menu") then
		return false, nil
	end
	return VoteService.CastVote(player, mapId)
end

Remotes.Function("BuyCrate").OnServerInvoke = guard(function(player, tier)
	return CrateService.Buy(player, tier)
end)

-- Opening a crate, from the menu or the Crate Altar in the lobby: the pull, its set bonus and
-- quest progress, and the show on the altar.
local function openCrateFor(player, tier, shownLuck)
	local success, message, result = CrateService.Open(player, tier, shownLuck)
	if success then
		-- The brainrot that just came out may complete a set, and may be new to the Rot Index. A pull
		-- from a crate bought with Robux (`result.purchased`) is logged as Purchased and pays no Brain
		-- Cells; any other pull counts as found in play. Purchased must be written before the scan.
		RewardService.CheckCollections(player)
		local pulled = result and result.kind == "Brainrot" and result.name or nil
		if pulled and result.purchased then
			ProgressionService.RecordPurchased(player, pulled)
		end
		ProgressionService.RecordIndex(player, false, not (result and result.purchased) and pulled or nil)
		QuestService.Progress(player, "crates", 1)
		-- Everyone in the lobby sees the pull on the altar.
		if result then
			LobbyService.PresentCrate(player, result)
		end
	end
	return success, message
end

-- `shownLuck`: the crate luck the menu's odds were drawn for (CrateService.Open refuses a mismatch).
-- From the client, so only a sane number counts; anything else is ignored like the altar's nil (the
-- check only protects the player from rolling at odds they weren't shown).
Remotes.Function("OpenCrate").OnServerInvoke = guard(function(player, tier, shownLuck)
	return openCrateFor(player, tier, SafeValue.Number(shownLuck, 100) and shownLuck or nil)
end)

LobbyService.OnAltarOpen = function(player, tier)
	if not PlayerData.Get(player) then
		return false, "Profile still loading."
	end
	local success, message = openCrateFor(player, tier)
	refreshLeaderstats(player)
	return success, message
end

-- Selling can take away the brainrot you have equipped as a companion.
Remotes.Function("SellBrainrot").OnServerInvoke = guard(function(player, name)
	local success, message, showcaseChanged = RewardService.SellBrainrot(player, name)
	if success then
		CompanionService.Refresh(player)
		-- Only when the sale actually took the showcased brainrot: Refresh rebuilds every
		-- podium on the server, so it is not run for a sale that changed nothing on them.
		if showcaseChanged then
			ShowcaseService.Refresh()
		end
	end
	return success, message
end)

Remotes.Function("SellAllOfRarity").OnServerInvoke = guard(function(player, rarity)
	local success, message, showcaseChanged = RewardService.SellAllOfRarity(player, rarity)
	if success then
		CompanionService.Refresh(player)
		-- Only when the sale actually took the showcased brainrot: Refresh rebuilds every
		-- podium on the server, so it is not run for a sale that changed nothing on them.
		if showcaseChanged then
			ShowcaseService.Refresh()
		end
	end
	return success, message
end)

Remotes.Function("SellDuplicates").OnServerInvoke = guard(function(player)
	return RewardService.SellDuplicates(player)
end)

-- Merging spare copies into a brainrot for a star. The companion already out picks up the new
-- numbers in place, and a podium showing it redraws its damage line.
-- Buying a specific brainrot with Robux: stores the pick, then opens the rarity's purchase prompt
-- from the server. The receipt is handled by the "Brainrot" grant handler above.
Remotes.Function("BuyBrainrot").OnServerInvoke = guard(function(player, name)
	if type(name) ~= "string" then
		return false, "Invalid brainrot."
	end
	-- Toasted by guard(), like every other reply.
	local success, message = BrainrotShopService.Choose(player, name)
	return success, message
end)

-- `fromStars` is the star count the confirm dialog showed; a stale one (double-click, second
-- menu) is refused instead of spending another batch of copies.
Remotes.Function("MergeBrainrot").OnServerInvoke = guard(function(player, name, fromStars)
	if type(name) ~= "string" or type(fromStars) ~= "number" then
		return false, "Invalid merge."
	end
	local success, message = RewardService.MergeBrainrot(player, name, fromStars)
	if success then
		local data = PlayerData.Get(player)
		if data and data.Companion == name then
			CompanionService.UpdateStats(player)
		end
		if data and data.Showcase == name then
			ShowcaseService.Refresh()
		end
	end
	-- guard() toasts the reply (the receipt once the dialog has closed itself; a refusal as well,
	-- beside the line the confirm dialog shows).
	return success, message
end)

Remotes.Function("SetCompanion").OnServerInvoke = guard(function(player, name)
	if name ~= nil and type(name) ~= "string" then
		return false, "Invalid brainrot."
	end
	local success, message = RewardService.SetCompanion(player, name)
	if success then
		CompanionService.Refresh(player)
	end
	-- The menu doesn't show this result itself, so a message goes back either way: guard() toasts
	-- the reply, and the fallback wording survives as the message itself.
	return success, message or (success and "Done." or "Couldn't do that.")
end)

Remotes.Function("BuyCosmetic").OnServerInvoke = guard(function(player, cosmeticId)
	return RewardService.BuyCosmetic(player, cosmeticId)
end)

Remotes.Function("EquipCosmetic").OnServerInvoke = guard(function(player, cosmeticId)
	local success, message = RewardService.EquipCosmetic(player, cosmeticId)
	if success then
		-- Show the change straight away. Auras are otherwise only drawn at spawn, and the
		-- held gun keeps its old skin colour until it's rebuilt.
		AuraService.Apply(player, player.Character)
		AccessoryService.Apply(player, player.Character)
		WeaponService.RefreshHeldGun(player)
	end
	return success, message
end)

Remotes.Function("ClaimPassTier").OnServerInvoke = guard(function(player, tier, track)
	return BattlePassService.ClaimTier(player, tier, track)
end)

Remotes.Function("ClaimPassAll").OnServerInvoke = guard(function(player)
	return BattlePassService.ClaimAll(player)
end)

Remotes.Function("ClaimDaily").OnServerInvoke = guard(function(player)
	return BattlePassService.ClaimDaily(player)
end)

-- The title worn on the nameplate: an unlocked achievement's id, or nil for none.
Remotes.Function("SetTitle").OnServerInvoke = guard(function(player, id)
	if id ~= nil and type(id) ~= "string" then
		return false, "Invalid title."
	end
	return AchievementService.SetTitle(player, id)
end)

--------------------------------------------------------------------------------
-- Progression: Rot Rank, the Rot Index and the Cell Shop (ProgressionService)
--------------------------------------------------------------------------------

-- Each of these is rate-limited per player, and each spends or claims idempotently: the client
-- says what it saw (prestige, shop day), and a stale view is refused rather than acted on twice.

-- `expected` is the prestige the confirm button showed.
Remotes.Function("Prestige").OnServerInvoke = guard(function(player, expected)
	if ProgressionService.RateLimited(player, "Prestige") then
		return false, "Slow down a moment."
	end
	if not SafeValue.Number(expected, 1000) then
		return false, "Invalid prestige."
	end
	return ProgressionService.Prestige(player, expected)
end)

-- One discovery by name, or nil for CLAIM ALL.
Remotes.Function("ClaimIndex").OnServerInvoke = guard(function(player, name)
	if ProgressionService.RateLimited(player, "ClaimIndex") then
		return false, "Slow down a moment."
	end
	if name ~= nil and (type(name) ~= "string" or #name > 64) then
		return false, "Invalid brainrot."
	end
	return ProgressionService.ClaimIndex(player, name)
end)

-- `day` is the shop day the client was shown, only to refuse a stale shop; the server picks the
-- rotation. `companion` names who a Companion Snack feeds (nil: the equipped one).
Remotes.Function("BuyCellOffer").OnServerInvoke = guard(function(player, offerId, day, companion)
	if ProgressionService.RateLimited(player, "BuyCellOffer") then
		return false, "Slow down a moment."
	end
	if type(offerId) ~= "string" or #offerId > 16 or not SafeValue.Number(day)
		or (companion ~= nil and (type(companion) ~= "string" or #companion > 64)) then
		return false, "Invalid offer."
	end
	local success, message, fedCompanion = ProgressionService.BuyOffer(player, offerId, day, companion)
	local data = success and fedCompanion and PlayerData.Get(player)
	-- A snack for the companion that's out changes its numbers in place.
	if data and data.Companion == (companion or data.Companion) then
		CompanionService.UpdateStats(player)
	end
	return success, message
end)

--------------------------------------------------------------------------------
-- Showcase + trading
--------------------------------------------------------------------------------

Remotes.Function("SetShowcase").OnServerInvoke = guard(function(player, name)
	if name ~= nil and type(name) ~= "string" then
		return false, "Invalid brainrot."
	end
	local success, message = RewardService.SetShowcase(player, name)
	if success then
		ShowcaseService.Refresh()
	end
	return success, message
end)

local function playerFromUserId(userId)
	if type(userId) ~= "number" then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

Remotes.Function("RequestTrade").OnServerInvoke = guard(function(player, targetUserId)
	local target = playerFromUserId(targetUserId)
	if not target then
		return false, "That player has left."
	end
	-- Invites get a budget of their own on top of the menu one, and a cooldown per TARGET, so an
	-- invite popup can't be used to pester someone. Both refusals say so rather than going silent.
	if not RateLimit.Take(player, "TradeInvite") then
		return false, "Wait a moment before sending another invite."
	end
	local pair = player.UserId .. ">" .. target.UserId
	local now = os.clock()
	if tradeInviteAt[pair] and now - tradeInviteAt[pair] < TRADE_INVITE_COOLDOWN then
		return false, "Wait a moment before inviting them again."
	end
	tradeInviteAt[pair] = now
	return TradeService.Request(player, target)
end)

Remotes.Function("RespondTrade").OnServerInvoke = guard(function(player, accept)
	return TradeService.Respond(player, accept == true)
end)

Remotes.Function("TradeOffer").OnServerInvoke = guard(function(player, name, add)
	if type(name) ~= "string" then
		return false, "Invalid brainrot."
	end
	return TradeService.Offer(player, name, add == true)
end)

Remotes.Function("TradeConfirm").OnServerInvoke = guard(function(player, value)
	return TradeService.Confirm(player, value == true)
end)

Remotes.Function("TradeCancel").OnServerInvoke = guard(function(player)
	return TradeService.Cancel(player)
end)

TradeService.IsBusy = function(player)
	return MatchService.IsAlive(player)
end

RewardService.IsTrading = TradeService.InSession

TradeService.OnTradeComplete = function()
	ShowcaseService.Refresh()
	-- A traded-away companion has to go home with its new owner's collection.
	CompanionService.RefreshAll()
	-- A trade can complete a set for either side.
	for _, player in ipairs(Players:GetPlayers()) do
		RewardService.CheckCollections(player)
		ProgressionService.RecordIndex(player)
	end
end

-- A mine is a weapon: it only triggers while a match is actually being played, so one left armed
-- cannot kill anyone on the results screen.
HazardService.MatchIsLive = function()
	return MatchService.GetState() == "InProgress"
end

MatchService.OnMatchStart = function()
	TradeService.CancelAll("Match starting — trade cancelled.")
	MovementService.Clear()
	DefenseService.Clear()
	ProjectileService.Clear()
	-- Only the mines players armed; the map's own barrels belong to the map.
	HazardService.Clear("mine")
	QuestService.ResetTallies()
	-- Where everyone's Rot Rank stands, for the results card's progression line.
	ProgressionService.BeginMatch()
end

MatchService.OnMatchEnd = function()
	ShowcaseService.Refresh()
	MovementService.Clear()
	DefenseService.Clear()
	ProjectileService.Clear()
	HazardService.Clear("mine")
	-- Companions downed this match come back for the next one.
	CompanionService.ReviveAll()
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(PlayerData.Save, player)
		end
	end
end)

game:BindToClose(function()
	if RunService:IsStudio() then
		return
	end
	-- Release rather than save: the final write also clears each session lock, so the server people are
	-- sent to can load them at once instead of waiting for the locks to go stale. All in parallel,
	-- bounded well inside the ~30 s Roblox allows.
	local released = PlayerData.ReleaseAll(Players:GetPlayers(), 20)
	print(string.format("[Bootstrap] shutdown: released %d of %d profiles", released, #Players:GetPlayers()))
end)
