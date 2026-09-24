-- Mounted vehicle weapons, server side (Oliver: "vehicles with different guns and explosive
-- weapons on them"). The specs are in Shared/VehicleWeaponData, the metal in VehicleModels (Mounts),
-- the HUD and the turret's swing in VehicleWeaponClient.
--
--   VehicleWeapons.Start()                         remotes and the round guard (once, from Bootstrap)
--   VehicleWeapons.Fire(token, aimPoint)  -> ok, reason   a player's remote or a bot calls this
--   VehicleWeapons.Aim(token, aimPoint)   -> ok           swing the turret without firing
--   VehicleWeapons.DrivenBy(token)        -> vehicle, spec, character, humanoid   or nil
--   VehicleWeapons.ClampAim(spec, direction) -> yaw, pitch (radians, mount space, within limits)
--   VehicleWeapons.FreeArmedNear(position, radius) -> vehicle, seat   an empty armed vehicle (bots)
--   VehicleWeapons.BotBoard(humanoid, seat)   -> ok        sit a bot in a driving seat
--
-- `token` is a combatant (a Player or a bot record, see Combatants): players and bots go through
-- exactly the same checks.
--
-- WHAT THE SERVER HOLDS A SHOT TO. The firer must be alive and sitting in the driving seat of an
-- armed, unwrecked vehicle, in a match (CombatService enabled, so never in the lobby). The mount's
-- fire rate is CombatService's own shot budget (ShotCredit/SpendShot), its magazine runs down one a
-- shot and comes back at `recharge` a second once it has been left alone for `rechargeDelay`. The
-- client only ever sends where it is aiming; the direction is worked out here and clamped to the
-- mount's arc, and the shot leaves from the mount's muzzle, not from the client.
--
-- DAMAGE IS NOT DECIDED HERE. A bullet is traced and each thing it meets is handed to the same
-- CombatService functions a hand gun's bullet is (companions, defenses, walls and glass, barrels,
-- then DealDamage for a body, which applies the match's damage scale, shields, the team veto and
-- the credit). A round goes through CombatService.LaunchProjectile, which is ProjectileService's
-- launcher path: the same flight, blast falloff, wall damage, exposure and effects as the hand
-- launchers. Nothing about damage is duplicated in this file.
--
-- NOT HITTING YOURSELF. A bullet's trace excludes the vehicle and everyone sitting in it. A round
-- excludes them from its flight too: ProjectileService's round filter only knows the owner's
-- character, so each round this module launches carries the riders on its def, and each round
-- kind's onLaunch (the Ballistics registry's own hook) adds them to the new round's filter. A blast you set off against a
-- wall at your bumper still reaches you at the launchers' half strength; that is the launchers' rule.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))

local Modules = script.Parent
local CombatService = require(Modules:WaitForChild("CombatService"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local RateLimit = require(Modules:WaitForChild("RateLimit"))

local VehicleWeapons = {}

-- Wall time shared with every client, so the HUD's recharge runs off the same clock (os.clock is
-- CPU time on a server and would drift from it). Swappable for the harness.
VehicleWeapons.Now = function()
	return workspace:GetServerTimeNow()
end

-- VehicleModels tags every armed model it builds with this.
VehicleWeapons.Tag = "ArmedVehicle"

-- How close a bot has to stand to a driving seat to get in (VehicleService lets a player in from
-- the prompt's reach plus a little).
local BOARD_DISTANCE = 12

-- Mount state per vehicle model: STRONG keys, dropped when the model leaves the game (a weak key
-- would drop a live vehicle's magazine; see COORDINATION's weak-table lesson).
local states = {}

--------------------------------------------------------------------------------
-- Who is driving what
--------------------------------------------------------------------------------

local function mountOf(vehicle)
	local yaw = vehicle:FindFirstChild("TurretYaw")
	local pitch = vehicle:FindFirstChild("TurretPitch")
	local muzzle = vehicle:FindFirstChild("TurretMuzzle")
	if yaw and pitch and muzzle then
		return yaw, pitch, muzzle
	end
	return nil
end

-- The armed vehicle `token` is driving, or nil. The driving seat is the VehicleSeat, and its
-- Occupant must be this very humanoid: a passenger, someone standing on the roof, or a stale
-- SeatPart all get nothing.
function VehicleWeapons.DrivenBy(token)
	local character = token ~= nil and Combatants.GetCharacter(token) or nil
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat or not seat:IsA("VehicleSeat") or seat.Occupant ~= humanoid then
		return nil
	end
	local vehicle = seat.Parent
	local spec = vehicle and VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"))
	if not spec or not mountOf(vehicle) then
		return nil
	end
	return vehicle, spec, character, humanoid
end

-- Everything a shot from `vehicle` must pass through: the vehicle and whoever rides in it.
local function riders(vehicle)
	local list = { vehicle }
	for _, child in ipairs(vehicle:GetChildren()) do
		if child:IsA("Seat") or child:IsA("VehicleSeat") then
			local occupant = child.Occupant
			if occupant and occupant.Parent then
				table.insert(list, occupant.Parent)
			end
		end
	end
	return list
end

local function stateFor(vehicle, spec)
	local state = states[vehicle]
	if not state then
		state = { ammo = spec.magazine, firedAt = nil }
		states[vehicle] = state
		vehicle.AncestryChanged:Connect(function()
			if not vehicle:IsDescendantOf(game) then
				states[vehicle] = nil
			end
		end)
	end
	return state
end

-- What the HUD and the other clients read. WeaponAmmo is the count as of WeaponFiredAt; the
-- client climbs it back with VehicleWeaponData.AmmoAt on the same clock.
local function publish(vehicle, state, yaw, pitch)
	vehicle:SetAttribute("WeaponAmmo", state.ammo)
	vehicle:SetAttribute("WeaponFiredAt", state.firedAt or 0)
	if yaw then
		vehicle:SetAttribute("AimYaw", math.floor(math.deg(yaw) * 2 + 0.5) / 2)
		vehicle:SetAttribute("AimPitch", math.floor(math.deg(pitch) * 2 + 0.5) / 2)
	end
end

--------------------------------------------------------------------------------
-- Aiming
--------------------------------------------------------------------------------

-- Shared with the client, which swings the driver's own turret by the same limits.
VehicleWeapons.ClampAim = VehicleWeaponData.ClampAim

-- A mount-space vector turned by the pitch pivot, then the yaw pivot.
local function turn(v, yaw, pitch)
	local cp, sp, cy, sy = math.cos(pitch), math.sin(pitch), math.cos(yaw), math.sin(yaw)
	local y1 = v.Y * cp - v.Z * sp
	local z1 = v.Y * sp + v.Z * cp
	return Vector3.new(v.X * cy + z1 * sy, y1, -v.X * sy + z1 * cy)
end

local function directionOf(yaw, pitch)
	return turn(Vector3.new(0, 0, -1), yaw, pitch)
end

-- Where the shot leaves and which way, in world space, clamped to the mount's arc. The server
-- never swings the pivots itself (clients do, from AimYaw/AimPitch), so the parts stand at rest
-- and the muzzle's offset from the pitch pivot is the rest offset, turned here by the aim.
local function solve(vehicle, spec, aimPoint)
	local yawPart, pitchPart, muzzle = mountOf(vehicle)
	local frame = yawPart.CFrame
	local toAim = frame:VectorToObjectSpace(aimPoint - pitchPart.Position)
	if toAim.Magnitude < 1 then
		return nil
	end
	local yaw, pitch = VehicleWeapons.ClampAim(spec, toAim)
	local rest = frame:VectorToObjectSpace(muzzle.Position - pitchPart.Position)
	local originLocal = turn(rest, yaw, pitch)
	-- Second pass from the muzzle itself, so a close target is hit where the crosshair is rather
	-- than a muzzle's length beside it. Still clamped: a crosshair can't pull the barrel out of its arc.
	local fromMuzzle = toAim - originLocal
	if fromMuzzle.Magnitude > 1 then
		yaw, pitch = VehicleWeapons.ClampAim(spec, fromMuzzle)
	end
	local origin = pitchPart.Position + frame:VectorToWorldSpace(originLocal)
	local direction = frame:VectorToWorldSpace(directionOf(yaw, pitch))
	return origin, direction, yaw, pitch
end

-- A random direction within `degrees` of `direction`.
local function spread(direction, degrees)
	if not degrees or degrees <= 0 then
		return direction
	end
	local up = math.abs(direction.Y) > 0.98 and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
	local right = direction:Cross(up).Unit
	local across = right:Cross(direction).Unit
	local spin = math.random() * math.pi * 2
	local tilt = math.tan(math.rad(degrees) * math.random())
	return (direction + right * (math.cos(spin) * tilt) + across * (math.sin(spin) * tilt)).Unit
end

--------------------------------------------------------------------------------
-- Shots
--------------------------------------------------------------------------------

-- One bullet: traced here, and everything it meets handed to CombatService's own functions in the
-- order a hand gun's bullet meets them (CombatService's firePellet). Returns where it ended.
local function traceBullet(token, vehicle, origin, direction, spec)
	local filter = riders(vehicle)
	local companion = CombatService.CompanionOf and CombatService.CompanionOf(token)
	if companion then
		table.insert(filter, companion)
	end
	for _, name in ipairs({ "Loot", "Effects", "DeathFx" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Water doesn't stop a bullet here either (CombatService.buildRaycastParams).
	params.IgnoreWater = true
	params.FilterDescendantsInstances = filter

	local from = origin
	local travelled = 0
	local endPoint = origin + direction * spec.range
	for _ = 1, 6 do
		local result = CombatService.Raycast(token, from, direction * (spec.range - travelled), params) -- lag-compensated like hand guns, #97
		if not result then
			break
		end
		endPoint = result.Position
		travelled += (result.Position - from).Magnitude
		local part = result.Instance

		local companionModel = CombatService.CompanionFromPart and CombatService.CompanionFromPart(part)
		if companionModel then
			CombatService.DamageCompanion(token, companionModel, spec.damage)
			break
		end
		local structure = CombatService.StructureFromPart and CombatService.StructureFromPart(part)
		if structure then
			CombatService.DamageStructure(token, structure, spec.damage)
			break
		end
		local destructible = CombatService.DestructibleFromPart and CombatService.DestructibleFromPart(part)
		if destructible then
			CombatService.DamageDestructible(token, destructible, spec.damage, origin)
			-- A pane breaks and the bullet carries on.
			if not (CombatService.DestructiblePassesThrough and CombatService.DestructiblePassesThrough(part)) then
				break
			end
			table.insert(filter, part)
			params.FilterDescendantsInstances = filter
			from = result.Position + direction * 0.05
		else
			local hazard = CombatService.HazardFromPart and CombatService.HazardFromPart(part)
			if hazard then
				CombatService.DamageHazard(token, hazard, spec.damage)
				break
			end
			local victimCharacter = part:FindFirstAncestorOfClass("Model")
			local victim = victimCharacter and Combatants.FromCharacter(victimCharacter) or nil
			if victim and victim ~= token and Combatants.IsAlive(victim) then
				local headshot = part.Name == "Head"
				local amount = spec.damage
				if headshot then
					amount *= (spec.headshotMultiplier or 1) * (CombatService.HeadshotScale or 1)
				end
				CombatService.DealDamage(token, victim, amount, spec.id, headshot)
			end
			break
		end
	end
	return endPoint
end

-- The WeaponData-shaped table ProjectileService's launcher path reads (id, projectile, damage,
-- splashRadius, headshotMultiplier, rarity), one per spec.
local roundDefs = {}
local function roundDef(spec)
	local def = roundDefs[spec.id]
	if not def then
		def = {
			id = spec.id,
			name = spec.id,
			projectile = spec.projectile,
			damage = spec.damage,
			splashRadius = spec.splashRadius,
			headshotMultiplier = spec.headshotMultiplier or 1,
			rarity = spec.rarity,
		}
		roundDefs[spec.id] = def
	end
	return def
end

local function launchRound(token, vehicle, origin, direction, spec)
	if not CombatService.LaunchProjectile then
		return false
	end
	-- A per-launch copy of the cached def carries this vehicle's riders to the round guard below
	-- (ProjectileService keeps it as entry.def), so no module-level state spans the call.
	local def = {}
	for key, value in pairs(roundDef(spec)) do
		def[key] = value
	end
	def.vehicleFilter = riders(vehicle)
	local ok, err = pcall(CombatService.LaunchProjectile, token, def, origin, direction)
	if not ok then
		warn("[VehicleWeapons] launch failed: " .. tostring(err))
	end
	return ok
end

function VehicleWeapons.Fire(token, aimPoint)
	-- Matches only: the lobby runs with combat off.
	if not CombatService.IsEnabled() then
		return false, "disabled"
	end
	if not SafeValue.Vector3(aimPoint) then
		return false, "aim"
	end
	if token == nil or not Combatants.IsAlive(token) then
		return false, "dead"
	end
	local vehicle, spec = VehicleWeapons.DrivenBy(token)
	if not vehicle then
		return false, "not driving"
	end
	if vehicle:GetAttribute("Wrecked") then
		return false, "wrecked"
	end

	local now = VehicleWeapons.Now()
	local state = stateFor(vehicle, spec)
	local credit = CombatService.ShotCredit(state, spec, now)
	if credit < 1 then
		return false, "rate"
	end
	local ammo = VehicleWeaponData.AmmoAt(spec, state.ammo, state.firedAt, now)
	if ammo < 1 then
		return false, "ammo"
	end
	local origin, direction, yaw, pitch = solve(vehicle, spec, aimPoint)
	if not origin then
		return false, "aim"
	end

	CombatService.SpendShot(state, credit, now)
	state.ammo = ammo - 1
	state.firedAt = now
	publish(vehicle, state, yaw, pitch)

	-- The shot is broadcast with no shooter: CombatClient would otherwise take the flash and the
	-- tracer from the driver's own hand gun (or their view, for their own shots). With none, every
	-- client, the driver's included, draws it from the mount's muzzle and hears it from there.
	if spec.kind == "round" then
		launchRound(token, vehicle, origin, spread(direction, spec.spread), spec)
		CombatService.BroadcastShot(nil, origin, {}, spec.rarity)
	else
		local endPoints = {}
		for _ = 1, spec.pellets or 1 do
			table.insert(endPoints, traceBullet(token, vehicle, origin, spread(direction, spec.spread), spec))
		end
		CombatService.BroadcastShot(nil, origin, endPoints, spec.rarity)
	end
	return true
end

-- Swings the turret toward `aimPoint` without firing, so everyone sees where it's pointing.
function VehicleWeapons.Aim(token, aimPoint)
	if not SafeValue.Vector3(aimPoint) then
		return false
	end
	local vehicle, spec = VehicleWeapons.DrivenBy(token)
	if not vehicle then
		return false
	end
	local _, _, yaw, pitch = solve(vehicle, spec, aimPoint)
	if not yaw then
		return false
	end
	vehicle:SetAttribute("AimYaw", math.floor(math.deg(yaw) * 2 + 0.5) / 2)
	vehicle:SetAttribute("AimPitch", math.floor(math.deg(pitch) * 2 + 0.5) / 2)
	return true
end

--------------------------------------------------------------------------------
-- Bots (BotService's BOT VEHICLES section drives the decisions)
--------------------------------------------------------------------------------

-- The nearest armed, unwrecked, upright vehicle within `radius` whose driving seat is empty.
function VehicleWeapons.FreeArmedNear(position, radius)
	local best, bestSeat, bestDistance = nil, nil, radius
	for _, vehicle in ipairs(CollectionService:GetTagged(VehicleWeapons.Tag)) do
		local seat = vehicle:FindFirstChild("DriverSeat")
		if seat and seat:IsA("VehicleSeat") and not seat.Occupant and not vehicle:GetAttribute("Wrecked")
			and vehicle:IsDescendantOf(workspace) and seat.CFrame.UpVector.Y > 0.4 then
			local distance = (seat.Position - position).Magnitude
			if distance < bestDistance then
				best, bestSeat, bestDistance = vehicle, seat, distance
			end
		end
	end
	return best, bestSeat
end

-- Sits a bot's humanoid in `seat` with the checks VehicleService's prompt makes for a player.
function VehicleWeapons.BotBoard(humanoid, seat)
	local character = humanoid and humanoid.Parent
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or humanoid.Health <= 0 or humanoid.SeatPart or seat.Occupant then
		return false
	end
	if (root.Position - seat.Position).Magnitude > BOARD_DISTANCE then
		return false
	end
	if seat.Parent and seat.Parent:GetAttribute("Wrecked") then
		return false
	end
	seat:Sit(humanoid)
	return true
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

-- Each launcher round kind learns to leave the launching vehicle and its riders out of its flight.
-- Wraps whatever onLaunch the kind already has, and does nothing for anyone else's launch.
local function guardRound(kind)
	local spec = Ballistics.Rounds[kind]
	if not spec or spec.vehicleGuard then
		return
	end
	local inner = spec.onLaunch
	spec.onLaunch = function(entry, api)
		local vehicleFilter = entry.def and entry.def.vehicleFilter
		if vehicleFilter and entry.filter and entry.params then
			for _, instance in ipairs(vehicleFilter) do
				table.insert(entry.filter, instance)
			end
			entry.params.FilterDescendantsInstances = entry.filter
		end
		if inner then
			return inner(entry, api)
		end
		return nil
	end
	spec.vehicleGuard = true
end

-- The aim remote's own token bucket (RateLimit.Budgets belongs to another file): a client sends
-- its aim about ten times a second while it drives an armed vehicle.
local aimBudget = { burst = 6, rate = 15 }
local aimBuckets = {}

function VehicleWeapons.Start()
	for _, spec in pairs(VehicleWeaponData.Weapons) do
		if spec.kind == "round" then
			guardRound(spec.projectile)
		end
	end

	Remotes.Event("VehicleWeaponFire").OnServerEvent:Connect(function(player, aimPoint)
		-- The hand gun's budget: a driver can't use their hand gun, so it's theirs to spend here.
		if not RateLimit.Take(player, "Fire") then
			return
		end
		VehicleWeapons.Fire(player, aimPoint)
	end)

	Remotes.Event("VehicleWeaponAim").OnServerEvent:Connect(function(player, aimPoint)
		local now = VehicleWeapons.Now()
		local bucket = aimBuckets[player]
		if not bucket then
			bucket = { tokens = aimBudget.burst, at = now }
			aimBuckets[player] = bucket
		end
		bucket.tokens = math.min(aimBudget.burst, bucket.tokens + (now - bucket.at) * aimBudget.rate)
		bucket.at = now
		if bucket.tokens < 1 then
			return
		end
		bucket.tokens -= 1
		VehicleWeapons.Aim(player, aimPoint)
	end)

	Players.PlayerRemoving:Connect(function(player)
		aimBuckets[player] = nil
	end)
end

return VehicleWeapons
