-- Mountable guns, server side (Oliver, 2026-09-24: "add mountable guns around the battleground and map";
-- "put the mountable guns in strategic locations"; "the team bases and battleground must never appear in
-- battle royale"). What they are and their numbers: Shared/MountedGunData. Their metal: Shared/
-- MountedGunModels. Where the map's go: MountedGunPlacement.
--
--   MountedGuns.Start()                          damage hooks, the round loop (once, from Bootstrap)
--   MountedGuns.OnMapBuilt(mapInfo, mode)        MatchService, once the match's map is built
--   MountedGuns.OnMatchEnd()                     MatchService's round end: every gun and gunner gone
--   MountedGuns.FreeNear(position, radius)       -> seat, model   an unmanned, usable gun (bots)
--   MountedGuns.BotSit(humanoid, seat)           -> ok            sit a bot at a gun, the prompt's checks
--   MountedGuns.IsGunSeat(seat)                  -> bool
--   MountedGuns.All()                            -> { model, ... } the guns standing now
--
-- WHICH GUNS, WHEN (the lifecycle is PURE below; tools/mounted_guns_check.py drives it BR -> team -> BR):
--   a TEAM match   a gun at every Part tagged GunEmplacement (TeamBattleground places 8-12 in the arena),
--                  whenever it appears during the match; no map guns
--   any OTHER mode (the battle royale)   MountedGunPlacement's strategic spots; never an arena gun, even
--                  if a tagged part were left lying about
--   round end      every gun destroyed, every gunner put down first; the next match builds its own
-- A kind for an arena spot comes from the part's `Kind` attribute ("hmg"/"cannon") if it has one, else
-- every third spot is a cannon.
--
-- WORKING ONE is the vehicles' turret path end to end (MountedGunData's header): a Seat named GunnerSeat on
-- a model tagged ArmedVehicle with a VehicleModel attribute, so VehicleWeapons fires it (its remotes and
-- RateLimit "Fire", the belt, overheat, arc clamp, lag-compensated trace) and VehicleWeaponClient/
-- GunnerView give the gunner arms, sight and HUD. The only way on is the prompt ("Man the gun"), rate
-- limited per player (MountCooldown) and checked here: a live match, the gun whole and unlocked, the
-- player alive, on foot and near, the seat free (a bot on it yields as it does a vehicle seat). The Player
-- carries InVehicle and VehicleRole "Gunner" while seated, as VehicleService's riders do, so the combat
-- camera stands down. OFF: jump (the seat lets go), death, the gun breaking, the round ending, the gun
-- destroyed -- every one through release(), which clears the rider and sets a live one down behind the gun.
--
-- DAMAGE. Bullets reach a gun through CombatService.VehicleFromPart/DamageVehicle (chained here, the
-- vehicles' own hooks are kept for everything else), blasts through DamageHazardsInRadius (chained too:
-- ProjectileService calls it for every blast). A gun takes MountedGunData.Classes by damage class, a Shield
-- part a quarter of a bullet. The gunner is an ordinary body in the open: nothing here protects them.
-- At 0 the gun breaks: its gunner is thrown off, it goes black and droops, and MountedGunData.RebuildDelay
-- later a new one stands in its place (in the same match only).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MountedGunData = require(Shared:WaitForChild("MountedGunData"))
local MountedGunModels = require(Shared:WaitForChild("MountedGunModels"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
-- Required for its side effect: the emplacements' weapons merged into VehicleWeaponData.
require(Shared:WaitForChild("VehicleWeaponData"))

local Modules = script.Parent
local CombatService = require(Modules:WaitForChild("CombatService"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local MountedGunPlacement = require(Modules:WaitForChild("MountedGunPlacement"))

local MountedGuns = {}

MountedGuns.Now = function()
	return workspace:GetServerTimeNow()
end

-- PURE BEGIN
-- The lifecycle, with everything it touches in `env`:
--   env.build(kind, cframe, source, matchId, opts) -> gun     env.destroy(gun)
--   env.release(gun, reason)                            put its gunner down (and clear them), if any
--   env.choose(mapInfo) -> { { kind, cframe }, ... }    the map's spots
--   env.emplacements() -> { spot, ... }                 the tagged parts standing now
--   env.frameOf(spot) -> cframe, env.kindOf(spot) -> kind or nil
--   env.now() -> seconds
local Life = {}
Life.__index = Life

function Life.new(env, data)
	return setmetatable({ env = env, data = data, guns = {}, bySpot = {}, live = false, teams = false, matchId = 0,
		arenaCount = 0 }, Life)
end

function Life:add(kind, cframe, source, spot, opts)
	local gun = self.env.build(kind, cframe, source, self.matchId, opts)
	if not gun then
		return nil
	end
	local entry = { gun = gun, kind = kind, cframe = cframe, source = source, spot = spot, matchId = self.matchId, opts = opts }
	table.insert(self.guns, entry)
	if spot then
		self.bySpot[spot] = entry
	end
	return entry
end

-- A match starts on its built map. Whatever the last match left is cleared first.
function Life:start(teams, mapInfo)
	self:clear("round end")
	self.matchId += 1
	self.live = true
	self.teams = teams == true
	self.arenaCount = 0
	if self.teams then
		for _, spot in ipairs(self.env.emplacements()) do
			self:atEmplacement(spot)
		end
	else
		for _, s in ipairs(self.env.choose(mapInfo) or {}) do
			local d = s.details
			self:add(s.kind, s.cframe, "map", nil, d and { flankBags = d.sandbag == true, covers = (d.vehicles or 0) > 0 } or nil)
		end
	end
end

-- A tagged emplacement: a gun on it in a live team match, and never otherwise.
function Life:atEmplacement(spot)
	if not self.live or not self.teams or self.bySpot[spot] then
		return nil
	end
	self.arenaCount += 1
	local kind = self.env.kindOf(spot)
	if kind ~= "hmg" and kind ~= "cannon" then
		kind = (self.arenaCount % 3 == 0) and "cannon" or "hmg"
	end
	return self:add(kind, self.env.frameOf(spot), "arena", spot)
end

-- A gun broke: its gunner off, and a new one due where it stood.
function Life:broken(entry)
	if entry.broken then
		return
	end
	entry.broken = true
	self.env.release(entry.gun, "break")
	entry.rebuildAt = self.env.now() + self.data.RebuildDelay
end

-- Once in a while: broken guns whose time is up are replaced (in the same live match only).
function Life:tick()
	if not self.live then
		return
	end
	local now = self.env.now()
	for index, entry in ipairs(self.guns) do
		if entry.broken and entry.rebuildAt and now >= entry.rebuildAt and entry.matchId == self.matchId then
			self.env.destroy(entry.gun)
			local gun = self.env.build(entry.kind, entry.cframe, entry.source, self.matchId, entry.opts)
			local fresh = { gun = gun, kind = entry.kind, cframe = entry.cframe, source = entry.source, spot = entry.spot,
				matchId = self.matchId }
			self.guns[index] = fresh
			if entry.spot then
				self.bySpot[entry.spot] = fresh
			end
		end
	end
end

function Life:finish()
	self.live = false
	self:clear("round end")
end

function Life:clear(reason)
	for _, entry in ipairs(self.guns) do
		self.env.release(entry.gun, reason)
		self.env.destroy(entry.gun)
	end
	self.guns = {}
	self.bySpot = {}
end

function Life:entryOf(gun)
	for _, entry in ipairs(self.guns) do
		if entry.gun == gun then
			return entry
		end
	end
	return nil
end
-- PURE END

MountedGuns.Life = Life

--------------------------------------------------------------------------------
-- The world
--------------------------------------------------------------------------------

local folder = nil
local function gunFolder()
	if not folder or not folder.Parent then
		folder = Instance.new("Folder")
		folder.Name = "MountedGuns"
		folder.Parent = workspace
	end
	return folder
end

local riders = {} -- model -> { humanoid, player, character, died }; STRONG keys, dropped on release/destroy
local lastPart = {} -- model -> the part a bullet asked about last (VehicleFromPart), for the shield rule
local mountedAt = {} -- player -> MountedGuns.Now() of their last mount attempt
local life

local function clearRider(player)
	if player then
		player:SetAttribute("InVehicle", nil)
		player:SetAttribute("VehicleRole", nil)
		player:SetAttribute("MountedGun", nil)
	end
end

local function seatOf(model)
	local seat = model and model:FindFirstChild("GunnerSeat")
	return seat and seat:IsA("Seat") and seat or nil
end

-- Puts the gun's gunner down and clears them. `reason` is "leave", "death", "break", "round end" or
-- "destroyed". A living gunner is set on their feet just behind the gun.
local function release(model, reason)
	local rider = riders[model]
	riders[model] = nil
	if model and model.Parent then
		model:SetAttribute("Gunner", nil)
	end
	if not rider then
		return
	end
	if rider.died then
		rider.died:Disconnect()
	end
	clearRider(rider.player)
	local humanoid = rider.humanoid
	local seat = seatOf(model)
	if seat then
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
	end
	if humanoid and humanoid.Parent then
		humanoid.Sit = false
		local root = humanoid.Parent:FindFirstChild("HumanoidRootPart")
		if root and humanoid.Health > 0 and model and model.Parent then
			local behind = model:GetPivot() * CFrame.new(0, 3.2, 3.6)
			task.defer(function()
				if root.Parent and humanoid.Health > 0 and not humanoid.SeatPart then
					root.CFrame = CFrame.new(behind.Position) * (model:GetPivot() - model:GetPivot().Position)
					root.AssemblyLinearVelocity = Vector3.zero
				end
			end)
		end
	end
	MountedGuns.Released = (MountedGuns.Released or 0) + 1
	MountedGuns.LastRelease = reason
end
MountedGuns.Release = release

local function onSeatChanged(model, seat)
	local occupant = seat.Occupant
	local rider = riders[model]
	if rider and rider.humanoid ~= occupant then
		release(model, rider.humanoid and rider.humanoid.Health <= 0 and "death" or "leave")
	end
	if occupant and not riders[model] then
		local character = occupant.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		local entry = { humanoid = occupant, player = player, character = character }
		entry.died = occupant.Died:Connect(function()
			if riders[model] == entry then
				release(model, "death")
			end
		end)
		riders[model] = entry
		model:SetAttribute("Gunner", character and character.Name or nil)
		if player then
			player:SetAttribute("InVehicle", true)
			player:SetAttribute("VehicleRole", "Gunner")
			player:SetAttribute("MountedGun", true)
		end
	end
end

local function usable(model)
	if not model or not model.Parent or model:GetAttribute("Wrecked") then
		return false
	end
	local lockedUntil = model:GetAttribute("LockedUntil")
	return not (lockedUntil and MountedGuns.Now() < lockedUntil)
end

local function tryMount(player, model)
	local now = MountedGuns.Now()
	if mountedAt[player] and now - mountedAt[player] < MountedGunData.MountCooldown then
		return false, "cooldown"
	end
	mountedAt[player] = now
	if not life or not life.live or not usable(model) then
		return false, "unusable"
	end
	local seat = seatOf(model)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not seat or not humanoid or humanoid.Health <= 0 or not root or humanoid.SeatPart then
		return false, "not on foot"
	end
	if (root.Position - seat.Position).Magnitude > MountedGunData.MountReach then
		return false, "too far"
	end
	if seat.Occupant then
		-- A bot on it gets off for a player it would let into a vehicle seat (BotService's takeover rules).
		local holder = seat.Occupant.Parent
		local bot = holder and not Players:GetPlayerFromCharacter(holder) and Combatants.FromCharacter(holder)
		local okBots, BotService = pcall(require, Modules:FindFirstChild("BotService"))
		if not (bot and okBots and BotService.YieldSeat and BotService.YieldSeat(bot, player, seat)) then
			return false, "taken"
		end
		task.wait()
		if seat.Occupant then
			return false, "taken"
		end
	end
	seat:Sit(humanoid)
	return true
end
MountedGuns.TryMount = tryMount

local function lockFor(model, seconds)
	if seconds and seconds > 0 then
		model:SetAttribute("LockedUntil", MountedGuns.Now() + seconds)
	end
end

local function build(kind, cframe, source, _matchId, opts)
	local spec = MountedGunData.SpecOf(kind)
	local info = MountedGunData.Kinds[kind]
	if not spec or not info then
		return nil
	end
	local model = MountedGunModels.Build(kind, cframe, opts)
	model.Name = "MountedGun_" .. kind
	model:SetAttribute("VehicleModel", info.modelId)
	model:SetAttribute("MountedGun", kind)
	model:SetAttribute("VehicleMaxHealth", info.health)
	model:SetAttribute("VehicleHealth", info.health)
	-- For BotGunner: which way the gun faces, and whether it covers ground worth holding without a
	-- known enemy in view (a team mode's battleground guns; a battle royale's over roads and bridges).
	model:SetAttribute("BotFacing", cframe.LookVector)
	model:SetAttribute("BotCovers", source == "arena" or (opts ~= nil and opts.covers == true) or nil)
	local root = model.PrimaryPart
	local promptAt = root:FindFirstChild("MountPromptAt")
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GunnerPrompt"
	prompt.ActionText = "Man the gun"
	prompt.ObjectText = info.displayName
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = MountedGunData.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonB
	prompt.Parent = promptAt or root
	prompt.Triggered:Connect(function(player)
		tryMount(player, model)
	end)
	local seat = seatOf(model)
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onSeatChanged(model, seat)
	end)
	model.Parent = gunFolder()
	CollectionService:AddTag(model, MountedGunData.Tag)
	CollectionService:AddTag(model, "ArmedVehicle")
	-- A battle royale's map guns wait out the landing (MountedGunData.LandingGrace).
	if source == "map" then
		lockFor(model, MountedGunData.LandingGrace)
		prompt.Enabled = false
		task.delay(MountedGunData.LandingGrace, function()
			if model.Parent and not model:GetAttribute("Wrecked") then
				prompt.Enabled = true
			end
		end)
	end
	return model
end

local function destroy(model)
	if model then
		release(model, "destroyed")
		riders[model] = nil
		lastPart[model] = nil
		model:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Damage and breaking
--------------------------------------------------------------------------------

local function breakGun(model, attacker)
	if model:GetAttribute("Wrecked") then
		return
	end
	model:SetAttribute("Wrecked", true)
	model:SetAttribute("VehicleHealth", 0)
	local prompt = model.PrimaryPart and model.PrimaryPart:FindFirstChild("GunnerPrompt", true)
	if prompt then
		prompt.Enabled = false
	end
	local entry = life and life:entryOf(model)
	if entry then
		life:broken(entry)
	else
		release(model, "break")
	end
	-- Black and drooping, a puff of smoke, a flash with no push (the blast that broke it did the damage).
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 then
			part.Color = part.Color:Lerp(Color3.fromRGB(26, 24, 22), 0.75)
			part.Material = Enum.Material.CorrodedMetal
		end
	end
	local pitch = model:FindFirstChild("TurretPitch")
	local joint = pitch and pitch:FindFirstChild("Joint")
	if joint then
		joint.C0 = joint.C0 * CFrame.Angles(math.rad(-14), math.rad(9), 0)
	end
	local flash = Instance.new("Explosion")
	flash.BlastPressure = 0
	flash.BlastRadius = 0
	flash.DestroyJointRadiusPercent = 0
	flash.ExplosionType = Enum.ExplosionType.NoCraters
	flash.Position = model:GetPivot().Position + Vector3.new(0, 3.5, 0)
	flash.Parent = workspace
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(40, 38, 36)
	smoke.Opacity = 0.35
	smoke.RiseVelocity = 4
	smoke.Size = 3
	smoke.Parent = pitch or model.PrimaryPart
	if attacker ~= nil then
		CombatService.ConfirmHit(attacker, 0, true, flash.Position, "vehicle")
	end
end

-- `amount` of damage class `class` to a gun; `part` the part struck (nil for a blast).
local function damageGun(attacker, model, amount, class, part, position)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or model:GetAttribute("Wrecked") then
		return 0, false
	end
	local rider = riders[model]
	if attacker ~= nil and rider and Combatants.FromCharacter(rider.character) == attacker then
		return 0, false
	end
	local scale = MountedGunData.Classes[class or "bullet"] or 1
	if part and part:GetAttribute("Shield") and class ~= "explosive" then
		scale *= MountedGunData.ShieldScale
	end
	if attacker ~= nil then
		scale *= MatchConfig.CombatDamageScale or 1
	end
	local health = model:GetAttribute("VehicleHealth") or 0
	local after = math.max(0, health - amount * scale)
	model:SetAttribute("VehicleHealth", math.floor(after + 0.5))
	local dealt = math.floor(health - after + 0.5)
	if after <= 0 then
		breakGun(model, attacker)
		return dealt, true
	end
	if attacker ~= nil then
		CombatService.ConfirmHit(attacker, dealt, false, position or model:GetPivot().Position, "vehicle")
	end
	return dealt, false
end
MountedGuns.Damage = damageGun

local function gunOf(part)
	local model = part and part:FindFirstAncestorOfClass("Model")
	while model and not model:GetAttribute("MountedGun") do
		model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
	end
	return model
end

local function hookDamage()
	local innerFrom, innerDamage = CombatService.VehicleFromPart, CombatService.DamageVehicle
	CombatService.VehicleFromPart = function(part)
		local model = gunOf(part)
		if model then
			lastPart[model] = part
			return model
		end
		return innerFrom and innerFrom(part) or nil
	end
	CombatService.DamageVehicle = function(attacker, model, amount, class, weaponId, position)
		if model and model:GetAttribute("MountedGun") then
			local part = lastPart[model]
			lastPart[model] = nil
			return damageGun(attacker, model, amount, class, part, position)
		end
		if innerDamage then
			return innerDamage(attacker, model, amount, class, weaponId, position)
		end
		return 0, false
	end
	local innerBlast = CombatService.DamageHazardsInRadius
	CombatService.DamageHazardsInRadius = function(centre, radius, amount, owner)
		if innerBlast then
			innerBlast(centre, radius, amount, owner)
		end
		if not SafeValue.Vector3(centre) or type(radius) ~= "number" or type(amount) ~= "number" then
			return
		end
		for _, model in ipairs(CollectionService:GetTagged(MountedGunData.Tag)) do
			if model.Parent and not model:GetAttribute("Wrecked") then
				local middle = model:GetPivot().Position + Vector3.new(0, 3, 0)
				local d = (middle - centre).Magnitude - 1.5
				if d < radius then
					local falloff = math.clamp(1 - math.max(0, d) / radius, 0.3, 1)
					damageGun(owner, model, amount / MountedGunData.BlastIn * falloff, "explosive", nil, centre)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Bots
--------------------------------------------------------------------------------

function MountedGuns.IsGunSeat(seat)
	return seat ~= nil and seat.Name == "GunnerSeat" and seat.Parent ~= nil and seat.Parent:GetAttribute("MountedGun") ~= nil
end

function MountedGuns.FreeNear(position, radius)
	local best, bestModel, bestDistance = nil, nil, radius
	for _, model in ipairs(CollectionService:GetTagged(MountedGunData.Tag)) do
		local seat = seatOf(model)
		if seat and not seat.Occupant and usable(model) and model:IsDescendantOf(workspace) then
			local d = (seat.Position - position).Magnitude
			if d < bestDistance then
				best, bestModel, bestDistance = seat, model, d
			end
		end
	end
	return best, bestModel
end

function MountedGuns.BotSit(humanoid, seat)
	local character = humanoid and humanoid.Parent
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or humanoid.Health <= 0 or humanoid.SeatPart or not MountedGuns.IsGunSeat(seat) or seat.Occupant then
		return false
	end
	if not life or not life.live or not usable(seat.Parent) then
		return false
	end
	if (root.Position - seat.Position).Magnitude > MountedGunData.MountReach then
		return false
	end
	-- The prompt's cooldown between mounts, as a player's (tryMount), keyed by the bot's humanoid.
	local now = MountedGuns.Now()
	if mountedAt[humanoid] and now - mountedAt[humanoid] < MountedGunData.MountCooldown then
		return false
	end
	mountedAt[humanoid] = now
	seat:Sit(humanoid)
	return true
end

function MountedGuns.All()
	return CollectionService:GetTagged(MountedGunData.Tag)
end

--------------------------------------------------------------------------------
-- The match
--------------------------------------------------------------------------------

local function newLife()
	return Life.new({
		build = build,
		destroy = destroy,
		release = release,
		now = MountedGuns.Now,
		choose = function(mapInfo)
			if not mapInfo then
				return {}
			end
			local okGround, MapGenerator = pcall(require, Modules:WaitForChild("MapGenerator"))
			local groundAt = okGround and MapGenerator.GroundHeightAt or function()
				return 0
			end
			local ok, spots, rejected, considered = pcall(MountedGunPlacement.Choose, mapInfo, math.random(1, 2147483646), groundAt)
			if not ok then
				warn("[MountedGuns] placement failed: " .. tostring(spots))
				return {}
			end
			local tally = {}
			for why, n in pairs(rejected or {}) do
				table.insert(tally, why .. " " .. n)
			end
			table.sort(tally)
			print(string.format("[MountedGuns] %d map guns from %d candidates (rejected: %s)", #spots, considered or 0, table.concat(tally, ", ")))
			for _, s in ipairs(spots) do
				local c = {}
				for kind, n in pairs(s.details and s.details.covers or {}) do
					table.insert(c, n .. " " .. kind)
				end
				table.sort(c)
				print(string.format("[MountedGuns]   %s at (%.0f, %.0f, %.0f) %s, score %.1f, rise %.1f, covers %s", s.kind,
					s.cframe.X, s.cframe.Y, s.cframe.Z, (s.why or "?") .. (s.details and s.details.sandbag and " sandbagged" or ""), s.score, s.details and s.details.rise or 0, table.concat(c, ", ")))
			end
			return spots
		end,
		emplacements = function()
			return CollectionService:GetTagged(MountedGunData.EmplacementTag)
		end,
		frameOf = function(spot)
			return spot.CFrame
		end,
		kindOf = function(spot)
			return spot:GetAttribute("Kind")
		end,
	}, MountedGunData)
end

function MountedGuns.OnMapBuilt(mapInfo, mode)
	life = life or newLife()
	life:start(mode ~= nil and mode.teams == true, mapInfo)
end

function MountedGuns.OnMatchEnd()
	if life then
		life:finish()
	end
	-- Anything left in the folder (a gun built by hand in a harness) goes too.
	if folder and folder.Parent then
		for _, model in ipairs(folder:GetChildren()) do
			destroy(model)
		end
	end
end

local started = false
function MountedGuns.Start()
	if started then
		return
	end
	started = true
	life = life or newLife()
	hookDamage()
	CollectionService:GetInstanceAddedSignal(MountedGunData.EmplacementTag):Connect(function(spot)
		if life and spot:IsA("BasePart") then
			life:atEmplacement(spot)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		mountedAt[player] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.5 then
			return
		end
		acc = 0
		if life then
			life:tick()
		end
		-- A rider whose seat let go without the Occupant signal (a streamed-out seat, a teleport).
		for model, rider in pairs(riders) do
			local seat = seatOf(model)
			if not model.Parent or not seat or seat.Occupant ~= rider.humanoid then
				release(model, "leave")
			end
		end
	end)
end

return MountedGuns
