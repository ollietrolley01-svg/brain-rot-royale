-- Mounted vehicle weapons, server side (Oliver: "vehicles with different guns and explosive
-- weapons on them"). The specs are in Shared/VehicleWeaponData, the metal in VehicleModels (Mounts,
-- DriverMounts), the HUD, the aim and the gunner's first-person view in VehicleWeaponClient.
--
--   VehicleWeapons.Start()                         remotes and the round guard (once, from Bootstrap)
--   VehicleWeapons.Fire(token, aimPoint)  -> ok, reason   a player's remote or a bot calls this
--   VehicleWeapons.Aim(token, aimPoint)   -> ok           swing the mount without firing
--   VehicleWeapons.DrivenBy(token)        -> vehicle, spec, character, humanoid, mount   or nil
--                                           (the vehicle and mount `token` works; see WHO WORKS WHAT)
--   VehicleWeapons.GunnerSeatOf(vehicle)  -> seat or nil   the turret's own seat
--   VehicleWeapons.ClampAim(spec, direction) -> yaw, pitch (radians, mount space, within limits)
--   VehicleWeapons.FreeArmedNear(position, radius) -> vehicle, seat   an empty armed vehicle (bots)
--   VehicleWeapons.BotBoard(humanoid, seat)   -> ok        sit a bot in a driving seat
--   VehicleWeapons.AmmoOf(vehicle, mount)     -> rounds, spec  what a mount holds right now
--   VehicleWeapons.InArc(vehicle, point, mount) -> bool    `point` is inside the mount's arc
--   VehicleWeapons.BotAimPoint(vehicle, targetPosition, targetVelocity, hit, mount) -> aimPoint (bots)
-- `mount` is "turret" (the default) or "driver".
--
-- `token` is a combatant (a Player or a bot record, see Combatants): players and bots go through
-- exactly the same checks.
--
-- WHO WORKS WHAT (Oliver 09-24: "make the car guns controllable by a gunner seat" and "make the drivers
-- have their own gun that they can control"). An armed vehicle has two weapons:
--   the TURRET, worked only from its own seat (VehicleModels' `gunner` frame: a Seat named GunnerSeat
--     with a true Gunner attribute, as VehicleWeaponClient reads it). A driver alone in the vehicle can
--     no longer work it: the gun waits for a gunner. (It used to fall to the driver while the gun's seat
--     was empty; now the driver has a gun of their own and the turret belongs to the gunner.)
--   the DRIVER'S GUN, worked only from the driving seat: a short-arc gun at the front.
-- A passenger, someone on the roof, or a stale SeatPart gets nothing.
--
-- WHAT THE SERVER HOLDS A SHOT TO. The firer must be alive and in the seat of an armed, unwrecked
-- vehicle's mount, in a match (CombatService enabled, so never in the lobby). The mount's fire rate is
-- CombatService's own shot budget (ShotCredit/SpendShot), its magazine runs down one a shot and comes
-- back at `recharge` a second once it has been left alone for `rechargeDelay`, and a gun with
-- `overheat` that has run dry stays hot until it has cooled back up to that share (VehicleWeaponData
-- .Ready). The client only ever sends where it is aiming; the direction is worked out here
-- (VehicleWeaponData.Solve) and clamped to the mount's arc, and the shot leaves from the mount's
-- muzzle, not from the client -- and only if the muzzle is in the open: a barrel pushed through a wall
-- (the car parked nose-in against a building) fires into that wall, not through it.
--
-- DAMAGE IS NOT DECIDED HERE. A bullet is traced and each thing it meets is handed to the same
-- CombatService functions a hand gun's bullet is (companions, defenses, walls and glass, barrels,
-- another vehicle, then DealDamage for a body, which applies the match's damage scale, shields, the
-- team veto and the credit). A round goes through CombatService.LaunchProjectile, which is
-- ProjectileService's launcher path: the same flight, blast falloff, wall damage, exposure and effects
-- as the hand launchers. Nothing about damage is duplicated in this file.
--
-- NOT HITTING YOURSELF. A bullet's trace excludes the vehicle and everyone sitting in it. A round
-- excludes them from its flight too: ProjectileService's round filter only knows the owner's
-- character, so each round this module launches carries the riders on its def, and each round
-- kind's onLaunch (the Ballistics registry's own hook) adds them to the new round's filter. A blast you
-- set off against a wall at your bumper still reaches you at the launchers' half strength; that is the
-- launchers' rule.

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

-- Mount state per vehicle model and mount: STRONG keys, dropped when the model leaves the game (a
-- weak key would drop a live vehicle's magazine; see COORDINATION's weak-table lesson).
local states = {}

--------------------------------------------------------------------------------
-- Who works what
--------------------------------------------------------------------------------

local function mountOf(vehicle, mount)
	local names = VehicleWeaponData.Parts[mount or "turret"]
	local yaw = names and vehicle:FindFirstChild(names.yaw)
	local pitch = names and vehicle:FindFirstChild(names.pitch)
	local muzzle = names and vehicle:FindFirstChild(names.muzzle)
	if yaw and pitch and muzzle then
		return yaw, pitch, muzzle
	end
	return nil
end

-- The turret's own seat on `vehicle`, or nil: a Seat named GunnerSeat, or any Seat with a true Gunner
-- attribute (VehicleWeaponClient's gunnerSeatOf reads the same two things).
function VehicleWeapons.GunnerSeatOf(vehicle)
	for _, child in ipairs(vehicle:GetChildren()) do
		if child:IsA("Seat") and (child.Name == "GunnerSeat" or child:GetAttribute("Gunner") == true) then
			return child
		end
	end
	return nil
end

-- The armed vehicle and mount `token` works, or nil (see WHO WORKS WHAT). The seat's Occupant must be
-- this very humanoid, so a stale SeatPart gets nothing. The name is kept from when only the driver
-- could fire.
function VehicleWeapons.DrivenBy(token)
	local character = token ~= nil and Combatants.GetCharacter(token) or nil
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat or seat.Occupant ~= humanoid then
		return nil
	end
	local vehicle = seat.Parent
	local modelId = vehicle and vehicle:GetAttribute("VehicleModel")
	local mount
	if seat == VehicleWeapons.GunnerSeatOf(vehicle) then
		mount = "turret"
	elseif seat:IsA("VehicleSeat") then
		-- The driving seat works the driver's gun, and only that.
		mount = "driver"
	else
		return nil
	end
	local spec = VehicleWeaponData.ForModel(modelId, mount)
	if not spec or not mountOf(vehicle, mount) then
		return nil
	end
	return vehicle, spec, character, humanoid, mount
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

local function stateFor(vehicle, spec, mount)
	local perVehicle = states[vehicle]
	if not perVehicle then
		perVehicle = {}
		states[vehicle] = perVehicle
		vehicle.AncestryChanged:Connect(function()
			if not vehicle:IsDescendantOf(game) then
				states[vehicle] = nil
			end
		end)
	end
	local key = mount or "turret"
	local state = perVehicle[key]
	if not state then
		state = { ammo = spec.magazine, firedAt = nil, hot = false }
		perVehicle[key] = state
	end
	return state
end

-- What the HUD and the other clients read (VehicleWeaponData.Attributes names them per mount). The
-- ammo is the count as of the last shot; the client climbs it back with VehicleWeaponData.AmmoAt on
-- the same clock. Hot is the overheat flag.
local function publish(vehicle, mount, state, yaw, pitch)
	local attributes = VehicleWeaponData.Attributes[mount or "turret"]
	vehicle:SetAttribute(attributes.ammo, state.ammo)
	vehicle:SetAttribute(attributes.firedAt, state.firedAt or 0)
	vehicle:SetAttribute(attributes.hot, state.hot or nil)
	if yaw then
		vehicle:SetAttribute(attributes.yaw, math.floor(math.deg(yaw) * 2 + 0.5) / 2)
		vehicle:SetAttribute(attributes.pitch, math.floor(math.deg(pitch) * 2 + 0.5) / 2)
	end
end

--------------------------------------------------------------------------------
-- Aiming
--------------------------------------------------------------------------------

-- Shared with the client, which swings the mounts by the same limits.
VehicleWeapons.ClampAim = VehicleWeaponData.ClampAim

-- Where the shot leaves and which way, in world space, clamped to the mount's arc
-- (VehicleWeaponData.Solve). The server never swings the pivots itself (clients do, from the aim
-- attributes), so the parts stand at rest: the yaw pivot's frame, the pitch pivot and the muzzle as
-- built are all it needs.
local function solve(vehicle, mount, spec, aimPoint)
	local yawPart, pitchPart, muzzle = mountOf(vehicle, mount)
	local frame = yawPart.CFrame
	local pivot = frame:PointToObjectSpace(pitchPart.Position)
	local mouth = frame:VectorToObjectSpace(muzzle.Position - pitchPart.Position)
	local yaw, pitch, origin, direction = VehicleWeaponData.Solve(spec, frame, pivot, mouth, aimPoint)
	if not yaw then
		return nil
	end
	-- The pivot as turned, for the line-of-sight test (the barrel's own length, pivot to muzzle).
	local pivotWorld = frame:PointToWorldSpace(VehicleWeaponData.Turn(pivot, yaw, 0))
	return origin, direction, yaw, pitch, pivotWorld
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

local function shotParams(token, vehicle)
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
	return params, filter
end

-- Whether the barrel is in the open: nothing solid between its pivot and its mouth. Returns the point
-- a shot really leaves from -- the muzzle, or where the barrel meets whatever it has been pushed into.
local function clearMuzzle(token, vehicle, pivotWorld, origin)
	local params = shotParams(token, vehicle)
	local blocked = workspace:Raycast(pivotWorld, origin - pivotWorld, params)
	if blocked and blocked.Instance.CanCollide then
		return blocked.Position - (origin - pivotWorld).Unit * 0.05, false
	end
	return origin, true
end

-- One bullet: traced here, and everything it meets handed to CombatService's own functions in the
-- order a hand gun's bullet meets them (CombatService's firePellet). Returns where it ended.
local function traceBullet(token, vehicle, origin, direction, spec)
	local params, filter = shotParams(token, vehicle)
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
			CombatService.DamageDestructible(token, destructible, spec.damage, origin, result.Position, result.Normal)
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
			-- Another vehicle's body or armour takes it (VehicleService, VehicleArmor).
			local struck = CombatService.VehicleFromPart and CombatService.VehicleFromPart(part)
			if struck then
				CombatService.DamageVehicle(token, struck, spec.damage, spec.damageClass or "bullet", spec.id, result.Position)
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
	local vehicle, spec, _, _, mount = VehicleWeapons.DrivenBy(token)
	if not vehicle then
		return false, "not driving"
	end
	if vehicle:GetAttribute("Wrecked") then
		return false, "wrecked"
	end

	local now = VehicleWeapons.Now()
	local state = stateFor(vehicle, spec, mount)
	local credit = CombatService.ShotCredit(state, spec, now)
	if credit < 1 then
		return false, "rate"
	end
	local ammo = VehicleWeaponData.AmmoAt(spec, state.ammo, state.firedAt, now)
	-- Run dry, or still hot after running dry: nothing until the belt has cooled (the bots read both as
	-- "ammo" and let it cool).
	local ready, hot = VehicleWeaponData.Ready(spec, ammo, state.hot)
	if hot ~= state.hot then
		state.hot = hot
		publish(vehicle, mount, state)
	end
	if not ready then
		return false, "ammo"
	end
	local origin, direction, yaw, pitch, pivotWorld = solve(vehicle, mount, spec, aimPoint)
	if not origin then
		return false, "aim"
	end

	CombatService.SpendShot(state, credit, now)
	state.ammo = ammo - 1
	state.firedAt = now
	state.hot = spec.overheat ~= nil and state.ammo < 1 or false
	publish(vehicle, mount, state, yaw, pitch)
	origin = clearMuzzle(token, vehicle, pivotWorld, origin)

	-- The shot is broadcast with no shooter: CombatClient would otherwise take the flash and the
	-- tracer from the driver's own hand gun (or their view, for their own shots). With none, every
	-- client, the firer's included, draws it from the mount's muzzle and hears it from there.
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

-- A belt change: the part-used belt is dropped and the mount reloads from its infinite pool (AmmoAt's
-- recharge, after its delay), as it would from dry. Not while overheated or already full. -> ok
function VehicleWeapons.Reload(token)
	if not CombatService.IsEnabled() or token == nil or not Combatants.IsAlive(token) then
		return false
	end
	local vehicle, spec, _, _, mount = VehicleWeapons.DrivenBy(token)
	if not vehicle or vehicle:GetAttribute("Wrecked") then
		return false
	end
	local now = VehicleWeapons.Now()
	local state = stateFor(vehicle, spec, mount)
	local ammo = VehicleWeaponData.AmmoAt(spec, state.ammo, state.firedAt, now)
	if state.hot or ammo >= spec.magazine then
		return false
	end
	state.ammo = 0
	state.firedAt = now
	publish(vehicle, mount, state)
	return true
end

-- Swings the mount toward `aimPoint` without firing, so everyone sees where it's pointing.
function VehicleWeapons.Aim(token, aimPoint)
	if not SafeValue.Vector3(aimPoint) then
		return false
	end
	local vehicle, spec, _, _, mount = VehicleWeapons.DrivenBy(token)
	if not vehicle then
		return false
	end
	local _, _, yaw, pitch = solve(vehicle, mount, spec, aimPoint)
	if not yaw then
		return false
	end
	local attributes = VehicleWeaponData.Attributes[mount]
	vehicle:SetAttribute(attributes.yaw, math.floor(math.deg(yaw) * 2 + 0.5) / 2)
	vehicle:SetAttribute(attributes.pitch, math.floor(math.deg(pitch) * 2 + 0.5) / 2)
	return true
end

--------------------------------------------------------------------------------
-- Bots (BotService's BOT VEHICLES section drives the decisions)
--------------------------------------------------------------------------------

-- The nearest armed, unwrecked, upright vehicle within `radius` whose driving seat is empty. (Kept for
-- anything that still asks; BotService's BOT VEHICLES picks seats through VehicleService now.)
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

-- The rounds a mount holds right now (recharge counted), and its spec; nil for an unarmed one.
function VehicleWeapons.AmmoOf(vehicle, mount)
	local spec = vehicle and VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"), mount)
	if not spec then
		return nil
	end
	local state = stateFor(vehicle, spec, mount)
	return VehicleWeaponData.AmmoAt(spec, state.ammo, state.firedAt, VehicleWeapons.Now()), spec
end

-- The launch angle (radians up) that brings a lobbed round from `origin` down on `point`: the lower
-- of the two that the mount's pitch can reach, or nil when neither can (too near for the mortar's
-- lowest barrel, or past its reach).
local function lobAngle(spec, round, origin, point)
	local g = workspace.Gravity * (round.gravityScale or 1)
	local v = round.speed
	local x = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z).Magnitude
	local y = point.Y - origin.Y
	local root = v ^ 4 - g * (g * x * x + 2 * y * v * v)
	if x < 1 or root < 0 then
		return nil
	end
	local low = math.atan2(v * v - math.sqrt(root), g * x)
	local high = math.atan2(v * v + math.sqrt(root), g * x)
	if low >= math.rad(spec.pitchMin) and low <= math.rad(spec.pitchMax) then
		return low
	end
	if high >= math.rad(spec.pitchMin) and high <= math.rad(spec.pitchMax) then
		return high
	end
	return nil
end

-- Whether a shot at `point` can be made inside the mount's arc (its yaw limit, and its pitch limits
-- for the line or, for a lobbed round, the arc): a bot holds fire rather than send rounds off at the
-- clamped edge.
function VehicleWeapons.InArc(vehicle, point, mount)
	local spec = vehicle and VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"), mount)
	local yawPart, pitchPart = mountOf(vehicle, mount)
	if not spec or not yawPart then
		return false
	end
	local toAim = yawPart.CFrame:VectorToObjectSpace(point - pitchPart.Position)
	if toAim.Magnitude < 1 then
		return false
	end
	-- The bearing about the yaw axis itself (a pintle's pitch pivot stands out in front of it).
	local fromAxis = yawPart.CFrame:PointToObjectSpace(point)
	local yaw = math.atan2(-fromAxis.X, -fromAxis.Z)
	if math.abs(yaw) > math.rad(spec.yawLimit) + 1e-3 then
		return false
	end
	if spec.kind == "round" and spec.projectile == "grenade" and spec.pitchMin >= 0 then
		local round = Ballistics.Rounds[spec.projectile]
		return round ~= nil and round.speed ~= nil and lobAngle(spec, round, pitchPart.Position, point) ~= nil
	end
	local pitch = math.atan2(toAim.Y, math.sqrt(toAim.X * toAim.X + toAim.Z * toAim.Z))
	return pitch >= VehicleWeaponData.PitchFloor(spec, yaw) - 0.02 and pitch <= math.rad(spec.pitchMax) + 0.02
end

-- How much of a moving target's run a bot leads a round by: most of the way, not all of it. A bot
-- that led perfectly would put every rocket on a running player; a real gunner doesn't.
local BOT_LEAD = 0.7
-- A body's root stands about this far above its feet: where a lobbed round is brought down.
local LOB_DROP = 2.5

-- Where a bot aims a shot from `vehicle` at a target standing at `targetPosition`, moving at
-- `targetVelocity`. `hit` is the bot's roll (BotService decides it, from the same aim dials as a bot
-- on foot): true aims at the target, false aims clear of it, a bullet to one side, a round a blast's
-- width and more away so its splash does not turn every miss into a hit. A round is led by BOT_LEAD
-- of the target's run over its flight, and a lobbed one (the mortar) aimed so its arc comes down
-- where it should, not where the barrel points. The mount's own spread and clamp still apply in Fire.
function VehicleWeapons.BotAimPoint(vehicle, targetPosition, targetVelocity, hit, mount)
	local spec = VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"), mount)
	local _, pitchPart = mountOf(vehicle, mount)
	if not spec or not pitchPart then
		return targetPosition
	end
	local origin = pitchPart.Position
	local round = spec.kind == "round" and Ballistics.Rounds[spec.projectile] or nil
	local point = targetPosition
	if round and Ballistics.RoundTimeFor then
		local flight = Ballistics.RoundTimeFor(round, (targetPosition - origin).Magnitude)
		point += (targetVelocity or Vector3.zero) * flight * BOT_LEAD
	end
	local lobbed = round ~= nil and spec.projectile == "grenade" and spec.pitchMin >= 0
	if not hit then
		local off = round and (spec.splashRadius or 12) + 6 + math.random() * 6 or 5 + math.random() * 7
		if lobbed then
			-- A lob comes down somewhere else: anywhere round the target.
			local angle = math.random() * math.pi * 2
			point += Vector3.new(math.cos(angle) * off, 0, math.sin(angle) * off)
		else
			-- A straight shot goes past to one side (or over): off along the line it would still pass
			-- through the target on its way.
			local line = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z)
			local side = line.Magnitude > 0.1 and Vector3.new(-line.Z, 0, line.X).Unit or Vector3.new(1, 0, 0)
			point += side * (math.random() < 0.5 and -off or off) + Vector3.new(0, math.random(-1, 3), 0)
		end
	end
	if lobbed then
		-- A lob: along the launch angle that brings the round down at `point`'s feet (a round coming down
		-- at a shallow angle onto a body's middle would carry on past it to the ground behind).
		point -= Vector3.new(0, LOB_DROP, 0)
		local angle = round.speed and lobAngle(spec, round, origin, point)
		if angle then
			local across = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z).Unit
			return origin + (across * math.cos(angle) + Vector3.new(0, math.sin(angle), 0)) * 100
		end
	elseif round and Ballistics.LeadAim then
		-- A round's drop (a rocket's, a flat-fired grenade's), taken out the way the hand launcher's aim
		-- takes it out (its lead is above).
		return Ballistics.LeadAim(round, origin, point, Vector3.zero, workspace.Gravity)
	end
	return point
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
-- its aim about ten times a second while it works a vehicle's gun.
local aimBudget = { burst = 6, rate = 15 }
local aimBuckets = {}

function VehicleWeapons.Start()
	for _, spec in pairs(VehicleWeaponData.Weapons) do
		if spec.kind == "round" then
			guardRound(spec.projectile)
		end
	end

	Remotes.Event("VehicleWeaponFire").OnServerEvent:Connect(function(player, aimPoint)
		-- The hand gun's budget: whoever works a mount isn't using their hand gun, so it's theirs to
		-- spend here.
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

	-- A belt change on demand (X on a pad, RELOAD on a phone, R): Reload below. The hand gun's Reload budget.
	Remotes.Event("VehicleWeaponReload").OnServerEvent:Connect(function(player)
		if not RateLimit.Take(player, "Reload") then
			return
		end
		VehicleWeapons.Reload(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		aimBuckets[player] = nil
	end)
end

return VehicleWeapons
