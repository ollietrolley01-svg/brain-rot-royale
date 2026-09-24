-- Vehicles: drivable cars and motorbikes parked along the roads and around the towns.
--
--   VehicleService.Create(parent, position, yaw, kind, options) -> model   kind "car" or "bike";
--       options: model, scheme, rng, inward, exact (stand exactly at `position`, no parkOn)
--     (an optional fifth argument { model = "TralalaGT", scheme = 2 } picks both, for tests;
--      { inward = Vector3 } says which way, and how far, level ground lies if the spot is not level)
--   VehicleService.Start()                                         (once, from Bootstrap)
--   VehicleService.Count()                                         registered vehicles, for tests
--   VehicleService.ApplyBlast(centre, radius, damage)              throw vehicles clear of a blast
--   VehicleService.Get(model)                                      the service's entry for a model
--   VehicleService.FootingAt(parent, centre, yaw, size)            parkOn's level test, asked in advance
--
-- Bodies come from Shared/VehicleModels and handling from Shared/VehicleDynamics; this file owns
-- everything around them: seats and prompts, who simulates the physics, keeping drivers honest,
-- getting people in and out cleanly, and righting vehicles that end up on their roof.
--
-- WHO SIMULATES. A vehicle is simulated where its physics is owned. While a player drives, the
-- chassis is handed to that player and VehicleClient steps the dynamics on their machine, so the
-- controls answer the moment a key goes down. Otherwise (parked, driven by a rig, or for a moment
-- after a blast) the server owns it and steps the same dynamics here. The model attribute
-- ServerControl tells a driver's client to hold off while the server has it.
--
-- STAYING HONEST. A driver's client could report any position it likes, so the server watches every
-- player-driven vehicle: sustained speed well past the model's top speed, or a jump further than it
-- could have travelled, takes the physics back and puts the vehicle where it last was sane.
--
-- RIDERS. Sitting is by prompt (Drive, Ride), never by walking into a seat. A rider's parts go
-- massless while seated so they can't tip the vehicle, and the Player carries InVehicle (and
-- VehicleRole "Driver" or "Passenger") so the combat camera stands down. Jump gets you out, put
-- down at the first clear spot beside the vehicle.
--
-- RNG. Create makes exactly one call to the global math.random, as it always has (it used to pick a
-- paint colour). That roll seeds a local Random which picks the model, paint and everything else,
-- so map features generated after vehicles see the same global rolls however many choices a
-- vehicle makes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
-- #53/#57: roadkill routes through the same damage pathway a gun does (shield absorption, kill
-- feed, quest progress, the damage-direction indicator), so a fully-shielded target survives a hit
-- the way they would survive anything else, and a bot is a valid victim/attacker the same way.
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local Combatants = require(script.Parent:WaitForChild("Combatants"))
local RateLimit = require(script.Parent:WaitForChild("RateLimit"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local VehicleService = {}

local SPAWN_LIFT = 0.25
local PROMPT_DISTANCE = 10
local EXIT_BOX = Vector3.new(2.4, 4.6, 2.4)
local BAIL_SPEED = 28

-- Honesty checks for player-driven vehicles.
local SPEED_SLACK = 1.35
local SPEED_GRACE = 0.7
local SERVER_HOLD = 1.2
local AIR_LIMIT = 45
local AIR_CHECK_EVERY = 0.25
local HOVER_GRACE = 3.0

-- Flipped vehicles.
local RIGHT_OCCUPIED_AFTER = 2.0
local RIGHT_EMPTY_AFTER = 6.0

-- A parked vehicle that has settled is stepped this many times less often.
local REST_AFTER = 2.0
local REST_EVERY = 8

-- Blasts: raw damage to a velocity change at the centre, falling off linearly to the radius. 100
-- damage throws a car about ten studs up and twenty-odd across.
local BLAST_SPEED_PER_DAMAGE = 0.74
local BLAST_MAX_DAMAGE = 160
local BLAST_BIKE_SCALE = 1.2
local BLAST_SPIN = 0.035
local BLAST_HOLD = 0.6

-- Vehicle health (#53 low-health HUD warning, #57 roadkill). Numbers sent to and approved by
-- claude-43 2026-09-21, with two conditions folded in below: the roadkill debounce never fires at
-- all below the floor (so a car resting or parked on someone can never tick, whatever its state),
-- and the roadkill rate was checked against a full-health, full-shield player (MatchConfig
-- StartHealth 100 + MaxShield 100 = 200 effective HP): at BaseWalkSpeed (18 studs/s) a graze deals
-- (18-12)*1.8 = 10.8, nowhere near lethal; at the fastest bike's top speed (114) a single hit deals
-- (114-12)*1.8 = 183.6, short of 200 -- a fully-armoured player can survive even the worst hit.
local MAX_HEALTH_CAR = 300
local MAX_HEALTH_BIKE = 150
local COLLISION_FLOOR = 18        -- studs/s lost in one physics step before it counts as an impact
local COLLISION_DAMAGE_PER = 1.5  -- damage per stud/s of speed lost past the floor
local ROADKILL_FLOOR = 12         -- studs/s; at or under this, no damage is even considered
local ROADKILL_DAMAGE_PER = 1.8   -- damage per stud/s of speed over the floor
local ROADKILL_DEBOUNCE = 0.5     -- seconds, per victim
-- The client HUD warning threshold (share of MaxHealth) lives in VehicleDynamics.LOW_HEALTH_SHARE,
-- not here: nothing on the server thresholds against it, and a bug-hunt finding (2026-09-21) was
-- exactly this shape elsewhere -- two copies of one number drift, one source doesn't.

local active = {}
local byModel = {}
local started = false
local joltCount = 0 -- #84: how many VehicleJolt reports this server has seen; see VehicleService.Start

--------------------------------------------------------------------------------
-- Seats and prompts
--------------------------------------------------------------------------------

local function makeSeat(className, name, model, chassis, frame, isBike)
	local seat = Instance.new(className)
	seat.Name = name
	seat.Size = isBike and Vector3.new(1.0, 0.3, 1.6) or Vector3.new(1.8, 0.3, 1.8)
	seat.CFrame = frame
	seat.Transparency = 1
	seat.CanCollide = false
	-- Touch-sitting is off: walking into a car shouldn't sit you in it. The prompt sits you instead.
	seat.CanTouch = false
	seat.CanQuery = false
	seat.Massless = true
	if seat:IsA("VehicleSeat") then
		seat.HeadsUpDisplay = false
		seat.MaxSpeed = 0
		seat.Torque = 0
		seat.TurnSpeed = 0
	end
	seat.Parent = model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = chassis
	weld.Part1 = seat
	weld.Parent = seat
	return seat
end

local function makePrompt(chassis, name, localPosition, actionText, objectText)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = localPosition
	attachment.Parent = chassis
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	-- B on a controller, like the loot prompts: X is Reload (#86).
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonB
	prompt.Parent = attachment
	return prompt
end

--------------------------------------------------------------------------------
-- Occupants
--------------------------------------------------------------------------------

local function setMassless(entry, character, on)
	if on then
		local saved = {}
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				saved[part] = part.Massless
				part.Massless = true
			end
		end
		entry.savedMass[character] = saved
	else
		local saved = entry.savedMass[character]
		entry.savedMass[character] = nil
		if saved then
			for part, value in pairs(saved) do
				if part.Parent then
					part.Massless = value
				end
			end
		end
	end
end

local function clearRider(player)
	if player then
		player:SetAttribute("InVehicle", nil)
		player:SetAttribute("VehicleRole", nil)
	end
end

-- The first exit point, in order (the side you sat on first), with room to stand and ground under it.
local function findExit(entry, character, preferSide)
	local pivot = entry.model:GetPivot()
	local flat = Vector3.new(pivot.LookVector.X, 0, pivot.LookVector.Z)
	flat = flat.Magnitude > 0.05 and flat.Unit or Vector3.new(0, 0, -1)
	local upright = CFrame.lookAt(pivot.Position, pivot.Position + flat)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { entry.model, character }
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { entry.model, character }

	local order = {}
	for index, exit in ipairs(entry.info.exits) do
		table.insert(order, { exit = exit, rank = index })
	end
	if preferSide then
		table.sort(order, function(a, b)
			local sa = (a.exit.Position.X * preferSide > 0) and 0 or 1
			local sb = (b.exit.Position.X * preferSide > 0) and 0 or 1
			if sa ~= sb then
				return sa < sb
			end
			return a.rank < b.rank
		end)
	end

	for _, item in ipairs(order) do
		local world = upright * item.exit
		local standAt = world.Position + Vector3.new(0, 3, 0)
		if #workspace:GetPartBoundsInBox(CFrame.new(standAt), EXIT_BOX, params) == 0 then
			local ground = workspace:Raycast(standAt, Vector3.new(0, -14, 0), rayParams)
			if ground then
				local at = ground.Position + Vector3.new(0, 3.1, 0)
				return CFrame.lookAt(at, at + flat)
			end
		end
	end
	-- Nowhere clear: stand on top of it.
	local at = pivot.Position + Vector3.new(0, entry.info.kind == "bike" and 6 or 8.5, 0)
	return CFrame.lookAt(at, at + flat)
end

local function onSeatChanged(entry, seat)
	local previous = entry.occupants[seat]
	local current = seat.Occupant

	if previous and previous ~= current then
		-- What was recorded at sitting down, because the character may already be gone (a respawn
		-- or a reset while seated) and a player can't be found from a character that isn't there.
		local rider = entry.riders[seat]
		entry.occupants[seat] = nil
		entry.riders[seat] = nil
		if entry.deaths[seat] then
			entry.deaths[seat]:Disconnect()
			entry.deaths[seat] = nil
		end
		local switching = entry.switching[previous]
		if rider and not switching then
			clearRider(rider.player)
		end
		local character = previous.Parent
		if not character and rider then
			entry.savedMass[rider.character] = nil
		end
		if character then
			setMassless(entry, character, false)
			local root = character:FindFirstChild("HumanoidRootPart")
			if previous.Health > 0 and root and not switching then
				local chassis = entry.rig.chassis
				local velocity = chassis.AssemblyLinearVelocity
				local side = chassis.CFrame:PointToObjectSpace(seat.Position).X < 0 and -1 or 1
				-- Deferred: the seat weld is still coming apart when Occupant changes.
				task.defer(function()
					if not root.Parent or not entry.model.Parent then
						return
					end
					root.CFrame = findExit(entry, character, side)
					if velocity.Magnitude > BAIL_SPEED then
						root.AssemblyLinearVelocity = velocity * 0.5 + Vector3.new(0, 14, 0)
					else
						root.AssemblyLinearVelocity = Vector3.zero
					end
				end)
			end
		end
	end

	if current and current ~= previous then
		entry.occupants[seat] = current
		entry.switching[current] = nil
		-- A humanoid whose character is already being taken away still reports as the occupant for a
		-- moment; without this the whole vehicle loop errors on it every frame.
		local character = current.Parent
		local player = nil
		if character then
			setMassless(entry, character, true)
			player = Players:GetPlayerFromCharacter(character)
		end
		entry.riders[seat] = { character = character, player = player }
		if player then
			player:SetAttribute("InVehicle", true)
			player:SetAttribute("VehicleRole", seat == entry.seat and "Driver" or "Passenger")
		end
		-- A rider who dies would otherwise stay welded in.
		entry.deaths[seat] = current.Died:Connect(function()
			local weld = seat:FindFirstChild("SeatWeld")
			if weld then
				weld:Destroy()
			end
		end)
	end

	local driver = entry.seat.Occupant
	entry.driverPlayer = (driver and driver.Parent) and Players:GetPlayerFromCharacter(driver.Parent) or nil
	entry.ownerDirty = true
	entry.restFor = 0
	-- A taken seat's prompt goes away, so nobody is offered a ride that can't happen. A wrecked
	-- vehicle's prompts stay off regardless (#53/#57): this used to re-enable the drive prompt the
	-- moment damageVehicle's own ejection cleared the seat's Occupant, undoing the wreck lock one
	-- event later -- caught by vehicle_health_probe.lua's check named
	-- "the drive prompt is disabled once wrecked" (verbatim, so a grep for the check name finds
	-- both the proof and the guard it proves).
	if not entry.wrecked then
		for promptSeat, prompt in pairs(entry.prompts) do
			prompt.Enabled = promptSeat.Occupant == nil
		end
	end
end

local function trySit(entry, player, seat)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or seat.Occupant then
		return
	end
	if (root.Position - seat.Position).Magnitude > PROMPT_DISTANCE + 6 then
		return
	end
	if entry.rig.chassis.CFrame.UpVector.Y < 0.4 then
		return
	end
	-- Moving seats within the same vehicle: get up first. Seated anywhere else: no.
	local current = humanoid.SeatPart
	if current then
		if not current:IsDescendantOf(entry.model) then
			return
		end
		-- Moving seats: the old seat letting go must not put you out of the vehicle first.
		entry.switching[humanoid] = true
		task.delay(2, function()
			entry.switching[humanoid] = nil
		end)
		local weld = current:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		humanoid.Sit = false
		task.wait()
		if seat.Occupant or humanoid.Health <= 0 then
			entry.switching[humanoid] = nil
			clearRider(player)
			return
		end
	end
	seat:Sit(humanoid)
end

--------------------------------------------------------------------------------
-- Where a parked vehicle stands
--------------------------------------------------------------------------------
-- A quarter of the vehicles a map parked were left hanging off the ground at a corner, because they
-- are placed 36 studs off a road's centre line while the road's graded flat corridor ends at 20 --
-- so they land on the bank, and being held level over sloping ground is what reads as "spawning on
-- hillsides". This is fixed here rather than in the placement loop, so nothing outside this file has
-- to change: a vehicle checks the ground under its own four corners, steps aside to level ground if
-- there is any within a few studs, and lays a piece of hardstanding under itself if there is not.
-- A car standing on a made surface reads as parked; a car merely not floating still reads as dropped.

local FOOTING_TOLERANCE = 0.5    -- studs between highest and lowest corner before a site is a slope
local FOOTING_REACH = 26         -- how far to look for level ground before making some
local PAD_THICKNESS = 0.7
local PAD_MARGIN = 1.6           -- how far a pad stands out past the vehicle

local footingParams = RaycastParams.new()
footingParams.FilterType = Enum.RaycastFilterType.Exclude
footingParams.IgnoreWater = true

local function groundUnder(x, z, aboveY)
	local hit = workspace:Raycast(Vector3.new(x, aboveY + 24, z), Vector3.new(0, -90, 0), footingParams)
	return hit and hit.Position.Y or nil
end

-- The corners and edge midpoints of a vehicle's footprint, and how far apart the ground under them is.
-- The midpoints catch a kerb or a bank edge running under the middle of a long side, which four
-- corners either side of it read as level.
local FOOTING_POINTS = {
	Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, -1),
	Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
}
local function footingAt(centre, yaw, size)
	local frame = CFrame.new(centre) * CFrame.Angles(0, yaw, 0)
	local half = Vector3.new(size.X / 2, 0, size.Z / 2)
	local lowest, highest = math.huge, -math.huge
	for _, point in ipairs(FOOTING_POINTS) do
		local corner = point * half
		local at = frame:PointToWorldSpace(corner)
		local y = groundUnder(at.X, at.Z, centre.Y)
		if not y then
			return nil
		end
		lowest = math.min(lowest, y)
		highest = math.max(highest, y)
	end
	return highest - lowest, highest
end

-- The same footing test parkOn makes, for a caller choosing between spots BEFORE it creates anything
-- (ModeTeams' base vehicles): a spot that passes here is one parkOn keeps exactly where it was asked,
-- rather than stepping it up to FOOTING_REACH studs aside. Returns the spread and the highest ground,
-- or nil where some point of the footprint has no ground under it at all.
function VehicleService.FootingAt(parent, centre, yaw, size)
	footingParams.FilterDescendantsInstances = { parent }
	return footingAt(centre, yaw, size)
end
VehicleService.FootingTolerance = FOOTING_TOLERANCE

-- `inward` (optional) points from the spot towards somewhere known to be level, as far as the
-- vehicle may go: MapGenerator's verge parking passes the way to its road, whose graded corridor is
-- flat. A verge spot on the corridor's outer edge is then pulled in a stud or two, which keeps it on
-- the verge, before the ring below goes looking eight studs away (onto the carriageway, as often as not).
local function parkOn(parent, position, yaw, size, label, inward)
	footingParams.FilterDescendantsInstances = { parent }
	local spread, top = footingAt(position, yaw, size)
	if spread and spread <= FOOTING_TOLERANCE then
		return Vector3.new(position.X, top, position.Z), yaw
	end

	if typeof(inward) == "Vector3" and inward.Magnitude > 0 then
		local steps = math.ceil(inward.Magnitude / 0.5)
		for step = 1, steps do
			local at = position + inward * (step / steps)
			local otherSpread, otherTop = footingAt(at, yaw, size)
			if otherSpread and otherSpread <= FOOTING_TOLERANCE and math.abs(otherTop - (top or position.Y)) <= 4 then
				return Vector3.new(at.X, otherTop, at.Z), yaw
			end
		end
	end

	-- Step aside: nearby spots, nearest first, taking the first that is level. A candidate also has to
	-- be at about the same height as where it was asked to park: a building roof and the bottom of a
	-- ditch are both perfectly level, and a car parked on either is worse than a car on a slope. A spot
	-- beside a road (one given `inward`) only steps along the road: a ring of spots round it would put
	-- the car out in the lane on one side, or on the bank or in the field on the other.
	local across = typeof(inward) == "Vector3" and inward.Magnitude > 0 and inward.Unit or nil
	for _, reach in ipairs({ 8, 16, FOOTING_REACH }) do
		local candidates = {}
		if across then
			local alongRoad = Vector3.new(-across.Z, 0, across.X)
			candidates = { position + alongRoad * reach, position - alongRoad * reach }
		else
			for turn = 0, 7 do
				local angle = turn * math.pi / 4
				table.insert(candidates, position + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach))
			end
		end
		for _, at in ipairs(candidates) do
			local otherSpread, otherTop = footingAt(at, yaw, size)
			if otherSpread and otherSpread <= FOOTING_TOLERANCE and math.abs(otherTop - (top or position.Y)) <= 4 then
				return Vector3.new(at.X, otherTop, at.Z), yaw
			end
		end
	end

	-- Nowhere level within reach: make somewhere. The pad's top is the highest ground under the
	-- footprint, so no wheel is left underground, and it is thick enough to meet the slope behind it.
	if not spread then
		return position, yaw
	end
	local pads = parent.Parent and parent.Parent:FindFirstChild("VehiclePads")
	if not pads and parent.Parent then
		pads = Instance.new("Folder")
		pads.Name = "VehiclePads"
		pads.Parent = parent.Parent
	end
	local pad = Instance.new("Part")
	pad.Name = "Hardstanding"
	pad.Anchored = true
	pad.Size = Vector3.new(size.X + PAD_MARGIN, PAD_THICKNESS + spread, size.Z + PAD_MARGIN)
	pad.CFrame = CFrame.new(position.X, top - pad.Size.Y / 2 + 0.05, position.Z) * CFrame.Angles(0, yaw, 0)
	pad.Material = Enum.Material.Concrete
	pad.Color = Color3.fromRGB(122, 121, 116)
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.BottomSurface = Enum.SurfaceType.Smooth
	pad.Parent = pads or parent
	if not pads then
		warn(string.format("VehicleService: no map to park %s on; its hardstanding went in with it", tostring(label)))
	end
	return Vector3.new(position.X, top + 0.05, position.Z), yaw
end

--------------------------------------------------------------------------------
-- Other tabs' vehicle types
--------------------------------------------------------------------------------
-- A kind registered here is built by its own builder and then runs in THIS loop, so there is one
-- drive loop and one contract rather than a second Heartbeat beside it.
--
--   VehicleService.RegisterKind("skiff", spec, {
--       build = function(parent, position, yaw, options) return model, info end,
--       step  = function(entry, dt, now) end,   -- optional, instead of the dynamics step
--   })
--
-- `spec` is a VehicleDynamics handling entry (topSpeed, accel, brake, grip, ...) and is registered
-- under the kind's name so the rig finds it. `info` must carry kind, displayName, chassis,
-- seats { driver, passengers } and exits, in the model's own space.
--
-- Two things hold for every registered kind, and the worst bugs come from forgetting them:
--   * while a player drives, THAT PLAYER'S CLIENT steps the vehicle, not the server. A step that
--     lives only in a server hook stops running the moment someone sits down. Behaviour that must
--     always apply belongs in a module both sides run, named by `spec.stepModule`.
--   * the honesty checks apply. Sustained speed past spec.topSpeed, a teleport, or hanging in the
--     air takes the physics back. A kind meant to fly or to be very fast must say so in its spec.

local registered = {}

function VehicleService.RegisterKind(name, spec, hooks)
	if type(name) ~= "string" or name == "car" or name == "bike" then
		warn("VehicleService.RegisterKind: needs a name of its own, not " .. tostring(name))
		return false
	end
	if type(spec) ~= "table" or type(hooks) ~= "table" or type(hooks.build) ~= "function" then
		warn("VehicleService.RegisterKind: " .. name .. " needs a spec table and hooks.build")
		return false
	end
	registered[name] = { spec = spec, hooks = hooks }
	VehicleDynamics.Handling[name] = spec
	return true
end

--------------------------------------------------------------------------------
-- Health, collision damage and roadkill (#53, #57). Defined before Create (which connects
-- onChassisTouched) rather than down in the Loop section with checkHonest/step, which also call
-- these -- both use sites need them declared first.
--------------------------------------------------------------------------------

-- Reduces a vehicle's health and, the moment it reaches zero, wrecks it: every occupant is put
-- back on their feet (reusing the normal exit path -- clearing Sit fires onSeatChanged, which
-- finds a clear spot and throws them clear exactly as leaving at speed already does), every prompt
-- is disabled so nobody can get back in, and the model carries Wrecked for whoever dresses that
-- later. Never damages twice past zero, and never un-wrecks.
local function damageVehicle(entry, amount)
	if amount <= 0 or entry.wrecked or entry.health <= 0 then
		return
	end
	entry.health = math.max(0, entry.health - amount)
	entry.model:SetAttribute("VehicleHealth", entry.health)
	if entry.health <= 0 then
		entry.wrecked = true
		entry.model:SetAttribute("Wrecked", true)
		for _, prompt in pairs(entry.prompts) do
			prompt.Enabled = false
		end
		for _, humanoid in pairs(entry.occupants) do
			if humanoid then
				humanoid.Sit = false
			end
		end
	end
end

-- A one-step speed loss over COLLISION_FLOOR studs/s is a real impact (a wall, another vehicle,
-- slamming down after a jump) -- ordinary braking and coasting never lose that much speed in a
-- single physics step (VehicleDynamics' own braking constants top out well under this per-step at
-- normal frame rates). Called from both branches of step() (client-owned and server-simulated) so
-- collision damage applies whoever is driving. entry.lastFlatSpeed is nil on a vehicle's first step
-- and is set to 0 by checkHonest's own anti-cheat correction so a teleport-back is never misread as
-- a 100-studs/s "impact".
local function checkCollisionDamage(entry, flatSpeed)
	local last = entry.lastFlatSpeed
	entry.lastFlatSpeed = flatSpeed
	if not last then
		return
	end
	local drop = last - flatSpeed
	if drop > COLLISION_FLOOR then
		damageVehicle(entry, (drop - COLLISION_FLOOR) * COLLISION_DAMAGE_PER)
	end
end

-- Roadkill (#57): the vehicle's own flat speed at the moment of contact, above a floor, scaled
-- into damage on whoever it hit, through the same pathway a gun uses (shield first, then health).
-- Never the vehicle's own driver or passengers. The floor check runs BEFORE the debounce and BEFORE
-- setting one, on purpose: a parked or resting vehicle (speed at or under the floor, comfortably
-- above VehicleDynamics' own PARKED_STILL of 4) never enters the cooldown path at all, so a car
-- sitting on top of someone can never tick regardless of how many times Touched re-fires while it
-- rests there.
--
-- #110: who is credited is whoever sits in the DRIVING seat at the moment of contact, as a combatant
-- token. This used to pass entry.driverPlayer, which is only ever a Player (onSeatChanged fills it
-- from Players:GetPlayerFromCharacter), so a BOT at the wheel -- BotService drives armed vehicles --
-- dealt its roadkill as nobody's: no kill-feed name, no credit, no CombatDamageScale, and, because
-- ModeTeams.DamageVeto waves every attacker-less hit through, a bot could run over its own team in a
-- team mode. Combatants.FromCharacter answers for players and bots alike; driverPlayer is the
-- fallback for a character that has already gone from the seat. A car nobody is driving (a bail at
-- speed, a wreck still rolling) still hurts, credited to no one, as before.
local function roadkillDriverToken(entry)
	local driver = entry.seat.Occupant
	local character = driver and driver.Parent
	return (character and Combatants.FromCharacter(character)) or entry.driverPlayer
end

local function onChassisTouched(entry, hit)
	local character = hit.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	for _, occupant in pairs(entry.occupants) do
		if occupant == humanoid then
			return
		end
	end
	local chassis = entry.rig.chassis
	local flat = Vector3.new(chassis.AssemblyLinearVelocity.X, 0, chassis.AssemblyLinearVelocity.Z).Magnitude
	if flat <= ROADKILL_FLOOR then
		return
	end
	local now = tick()
	local last = entry.roadkillCooldown[humanoid]
	if last and now - last < ROADKILL_DEBOUNCE then
		return
	end
	if not last then
		-- First time this humanoid is tracked here: connected once, the strong-key drop that keeps
		-- this table from growing forever (matches DestructibleService's part.Destroying pattern).
		humanoid.Destroying:Connect(function()
			entry.roadkillCooldown[humanoid] = nil
		end)
	end
	entry.roadkillCooldown[humanoid] = now
	local victimToken = Combatants.FromCharacter(character)
	if not victimToken then
		return
	end
	local driverToken = roadkillDriverToken(entry)
	-- Belt and braces beside the occupants loop above: a driver is never their own car's victim.
	if driverToken == victimToken then
		return
	end
	CombatService.DealDamage(driverToken, victimToken, (flat - ROADKILL_FLOOR) * ROADKILL_DAMAGE_PER, "Roadkill", false)
end

--------------------------------------------------------------------------------
-- Create
--------------------------------------------------------------------------------

function VehicleService.Create(parent, position, yaw, kind, options)
	-- The one global roll (see the header), taken even when `options` names the model and paint,
	-- so a test that picks them draws exactly what a map would. A caller that brings its own Random
	-- (a placement module spending a single roll for a whole batch) takes none.
	local ownRng = type(options) == "table" and options.rng or nil
	local rng = ownRng or Random.new(math.random(1, 2147483646))
	local entryKind = registered[kind]
	local model, info
	if entryKind then
		model, info = entryKind.hooks.build(parent, position, yaw, options)
		if not model or not info or not info.chassis then
			warn("VehicleService: the builder for " .. kind .. " returned nothing usable")
			return nil
		end
		model:SetAttribute("RegisteredKind", kind)
		if entryKind.spec.stepModule then
			model:SetAttribute("StepModule", entryKind.spec.stepModule)
		end
	else
		local modelId = VehicleModels.Pick(kind == "bike" and "bike" or "car", rng)
		if type(options) == "table" and VehicleModels.Models[options.model] then
			modelId = options.model
		end
		model, info = VehicleModels.Build(modelId, rng, { scheme = type(options) == "table" and options.scheme or nil })
	end
	local chassis = info.chassis
	local isBike = info.kind == "bike"
	local maxHealth = isBike and MAX_HEALTH_BIKE or MAX_HEALTH_CAR
	model:SetAttribute("VehicleMaxHealth", maxHealth)
	model:SetAttribute("VehicleHealth", maxHealth)

	local seat = makeSeat("VehicleSeat", "DriverSeat", model, chassis, info.seats.driver, isBike)
	local passengers = {}
	for index, frame in ipairs(info.seats.passengers or {}) do
		table.insert(passengers, makeSeat("Seat", "PassengerSeat" .. index, model, chassis, frame, isBike))
	end

	-- Prompts stand beside each seat's door (on a bike, beside the saddle), in chassis space.
	local halfWidth = chassis.Size.X / 2
	local function promptSpot(frame, sideHint)
		local spot = chassis.CFrame:PointToObjectSpace(frame.Position)
		local side = sideHint or (spot.X < 0 and -1 or 1)
		return Vector3.new(side * (halfWidth + (isBike and 1.2 or 0.9)), 0.2, spot.Z)
	end
	local drivePrompt = makePrompt(chassis, "DrivePrompt", promptSpot(info.seats.driver, -1), isBike and "Ride" or "Drive", info.displayName)
	local ridePrompts = {}
	for index, passenger in ipairs(passengers) do
		table.insert(ridePrompts, makePrompt(chassis, "RidePrompt" .. index, promptSpot(passenger.CFrame, isBike and 1 or nil),
			isBike and "Ride pillion" or "Ride", info.displayName))
	end

	-- The footing is judged under everything the vehicle stands over, not the chassis collider alone
	-- (#39). The bumpers, arches and a yaw of a few degrees put a verge car's outer corners past the
	-- chassis box and past the edge of its road's flat corridor, over the bank, where the four chassis
	-- corners still read level: measured, 1 of 13 parked vehicles hung 1.48 studs at a corner.
	local footprint = chassis.Size
	local okExtents, extents = pcall(function()
		return model:GetExtentsSize()
	end)
	if okExtents and typeof(extents) == "Vector3" then
		footprint = Vector3.new(math.max(footprint.X, extents.X), footprint.Y, math.max(footprint.Z, extents.Z))
	end
	-- `options.exact`: the caller has measured the spot (a team base's painted bay, its floor read by
	-- raycast) and it must be used as given. parkOn's step-aside ring would otherwise move a car off
	-- its bay whenever one footing ray fell in a crack or on a wheel stop -- onto the next bay, where
	-- the next car then spawned into it -- and could lay hardstanding inside a building.
	if not (type(options) == "table" and options.exact) then
		position, yaw = parkOn(parent, position, yaw, footprint, info.displayName,
			type(options) == "table" and options.inward or nil)
	end
	model:PivotTo(CFrame.new(position + Vector3.new(0, SPAWN_LIFT, 0)) * CFrame.Angles(0, yaw, 0))
	local rig = VehicleDynamics.Rig(model)
	if not rig then
		-- A registered kind may have no wheels at all (a boat), so there is nothing for the dynamics
		-- to rig. The rest of this file only needs the chassis and a handling table to own the physics
		-- and to judge whether the thing is behaving, so it gets a stand-in with exactly that.
		rig = {
			model = model,
			chassis = chassis,
			handling = (entryKind and entryKind.spec) or VehicleDynamics.Handling[info.modelId or ""] or { topSpeed = 80 },
			wheels = {},
		}
	end
	model.Parent = parent

	local entry = {
		model = model,
		info = info,
		hooks = entryKind and entryKind.hooks or nil,
		rig = rig,
		seat = seat,
		passengers = passengers,
		occupants = {},
		riders = {},
		-- This one IS state, not a cache: while it holds a humanoid, that humanoid is moving between
		-- seats in this vehicle and must not be put out of it. STRONG keys (bug-hunt B3-1, 2026-09-
		-- 21): "reachable through the DataModel" is not "reachable from Lua" -- the exact argument
		-- that produced the geyser-cooldown exploit this project already recorded, and weak keys
		-- here would drop the switching flag mid-window rather than just losing a cache entry. Never
		-- leaks: every entry is cleared within 2s regardless by trySit's own task.delay, whether or
		-- not the humanoid still exists by then (the closure captures it, not a live lookup).
		switching = {},
		prompts = {},
		deaths = {},
		savedMass = {},
		driverPlayer = nil,
		owner = false,
		ownerDirty = true,
		serverHoldUntil = 0,
		overSpeedFor = 0,
		lastGood = model:GetPivot(),
		lastPosition = chassis.Position,
		restFor = 0,
		restSkip = 0,
		-- Health (#53/#57): maxHealth/health mirror the VehicleMaxHealth/VehicleHealth attributes
		-- (the attributes are what replicate to the client HUD; these are the authoritative numbers
		-- the server reads and writes). lastFlatSpeed starts nil on purpose (see checkCollisionDamage).
		-- roadkillCooldown: STRONG keys (bug-hunt B3-1). A weak table here was the same
		-- "reachable through the character" argument that produced the geyser exploit, and its
		-- consequence was one-directional and nasty: chassis.Touched fires many times a second
		-- while a car passes over someone, a dropped entry skips the 0.5s debounce entirely, and
		-- EVERY surviving fire deals full roadkill damage again -- a glancing brush at 40 studs/s
		-- (50 damage/tick) became an instant kill. Dropped explicitly in onChassisTouched via
		-- humanoid.Destroying, the same lifecycle hook DestructibleService uses for its part table.
		maxHealth = maxHealth,
		health = maxHealth,
		wrecked = false,
		lastFlatSpeed = nil,
		roadkillCooldown = {},
	}
	entry.groundParams = RaycastParams.new()
	entry.groundParams.FilterType = Enum.RaycastFilterType.Exclude
	entry.groundParams.FilterDescendantsInstances = { model }
	table.insert(active, entry)
	byModel[model] = entry

	entry.prompts[seat] = drivePrompt
	for index, prompt in ipairs(ridePrompts) do
		entry.prompts[passengers[index]] = prompt
	end
	drivePrompt.Triggered:Connect(function(player)
		trySit(entry, player, seat)
	end)
	for index, prompt in ipairs(ridePrompts) do
		prompt.Triggered:Connect(function(player)
			trySit(entry, player, passengers[index])
		end)
	end
	for _, s in ipairs({ seat, table.unpack(passengers) }) do
		s:GetPropertyChangedSignal("Occupant"):Connect(function()
			onSeatChanged(entry, s)
		end)
	end
	chassis.Touched:Connect(function(hit)
		onChassisTouched(entry, hit)
	end)

	return model
end

--------------------------------------------------------------------------------
-- Loop
--------------------------------------------------------------------------------

local function updateOwnership(entry, now)
	local wantPlayer = entry.driverPlayer
	if now < entry.serverHoldUntil or (wantPlayer and wantPlayer.Parent ~= Players) then
		wantPlayer = nil
	end
	local want = wantPlayer or false
	if want ~= entry.owner or entry.ownerDirty then
		entry.ownerDirty = false
		local ok = pcall(function()
			entry.rig.chassis:SetNetworkOwner(wantPlayer)
		end)
		entry.owner = ok and want or false
		entry.model:SetAttribute("ServerControl", (entry.driverPlayer ~= nil and not entry.owner) or nil)
		-- The honesty checks start fresh from wherever the vehicle is when a driver takes over.
		entry.lastPosition = entry.rig.chassis.Position
		entry.lastMoveAt = now
		entry.lastGood = entry.model:GetPivot()
		entry.overSpeedFor = 0
	end
end

local function checkHonest(entry, dt, now)
	local chassis = entry.rig.chassis
	local h = entry.rig.handling
	local velocity = chassis.AssemblyLinearVelocity
	local flat = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local moved = (chassis.Position - entry.lastPosition).Magnitude

	if flat > h.topSpeed * SPEED_SLACK + 10 and math.abs(velocity.Y) < 60 then
		entry.overSpeedFor += dt
	else
		entry.overSpeedFor = 0
	end
	-- A driver's position arrives in bursts, and after a network stall all at once, so a jump is
	-- judged against the time since the position last changed rather than one frame. The slack
	-- covers falling and a flipped vehicle being set back on its wheels.
	local teleported = false
	if moved > 0.01 then
		local elapsed = math.max(now - (entry.lastMoveAt or now), dt)
		teleported = moved > (math.max(flat, h.topSpeed) * SPEED_SLACK + 80) * elapsed + 16
		entry.lastMoveAt = now
		entry.lastPosition = chassis.Position
	end

	-- Hovering: far above anything and not falling, for longer than any jump lasts.
	entry.airCheckIn = (entry.airCheckIn or 0) - dt
	if entry.airCheckIn <= 0 then
		entry.airCheckIn = AIR_CHECK_EVERY
		-- These params deliberately do NOT ignore water, unlike the wheel rays in VehicleDynamics: a
		-- hull floating on a river is supported and must not be judged to be hovering, while a wheel
		-- must never find grip on one. Neither is a mistake.
		local below = workspace:Raycast(chassis.Position, Vector3.new(0, -AIR_LIMIT, 0), entry.groundParams)
		if not below and velocity.Y > -20 then
			entry.hoverFor = (entry.hoverFor or 0) + AIR_CHECK_EVERY
		else
			entry.hoverFor = 0
		end
		entry.grounded = below ~= nil and (chassis.Position - below.Position).Magnitude < 8
	end
	local hovering = (entry.hoverFor or 0) > HOVER_GRACE

	local corrected = entry.overSpeedFor > SPEED_GRACE or teleported or hovering
	if corrected then
		entry.hoverFor = 0
		entry.overSpeedFor = 0
		entry.serverHoldUntil = now + SERVER_HOLD
		updateOwnership(entry, now)
		entry.model:PivotTo(entry.lastGood)
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
		entry.lastPosition = chassis.Position
		entry.lastMoveAt = now
		-- Not a crash: the anti-cheat correction just zeroed the velocity itself, so the NEXT call
		-- must not read this as a 100-studs/s impact.
		entry.lastFlatSpeed = 0
	elseif flat < h.topSpeed * SPEED_SLACK and entry.grounded then
		-- Only a pose with ground right under it counts as a sane place to put the vehicle back.
		entry.lastGood = entry.model:GetPivot()
	end
	if not corrected then
		checkCollisionDamage(entry, flat)
	end
end

local function step(entry, dt, now)
	local rig = entry.rig
	updateOwnership(entry, now)

	if entry.owner then
		-- The driver's client simulates. Keep the server's copy of the forces quiet so nothing stale
		-- applies the moment ownership comes back.
		if not entry.idled then
			entry.idled = true
			VehicleDynamics.Idle(rig)
		end
		checkHonest(entry, dt, now)
		return
	end
	entry.idled = false

	-- A registered kind with its own step runs here instead of the dynamics, in this same loop. It
	-- is wrapped, because a hook that raises would otherwise take every vehicle behind it in the
	-- list down with it.
	if entry.hooks and entry.hooks.step then
		local ok, err = pcall(entry.hooks.step, entry, dt, now)
		if not ok and not entry.hookWarned then
			entry.hookWarned = true
			warn(string.format("VehicleService: the step for %s errored and is being skipped: %s",
				tostring(entry.model:GetAttribute("RegisteredKind")), tostring(err)))
		end
		return
	end

	local seat = entry.seat
	local occupant = seat.Occupant
	local chassis = rig.chassis

	-- A settled, empty vehicle is stepped now and then; its forces hold it between steps. It is stepped
	-- with THIS frame's dt, not the frames it skipped added up: VehicleDynamics softens the springs for
	-- a long dt (so they can't overshoot), and eight frames' worth let a parked car sag on springs far
	-- weaker than its weight, wake (it moved), bounce back up at full rate, settle, and do it again --
	-- the "parked cars jitter" bob. A car at rest only needs the forces that hold it where it is.
	if not occupant and next(entry.occupants) == nil then
		local resting = chassis.AssemblyLinearVelocity.Magnitude < 0.3 and chassis.AssemblyAngularVelocity.Magnitude < 0.3
		entry.restFor = resting and entry.restFor + dt or 0
		if entry.restFor > REST_AFTER then
			entry.restSkip = (entry.restSkip + 1) % REST_EVERY
			if entry.restSkip ~= 0 then
				return
			end
		end
	else
		entry.restFor = 0
	end

	local ignore = {}
	for _, humanoid in pairs(entry.occupants) do
		if humanoid.Parent then
			table.insert(ignore, humanoid.Parent)
		end
	end
	VehicleDynamics.SetIgnore(rig, ignore)

	local input
	if occupant then
		input = { throttle = seat.ThrottleFloat, steer = seat.SteerFloat, handbrake = seat:GetAttribute("Handbrake") == true }
	else
		input = { throttle = 0, steer = 0, parked = true }
	end
	local telemetry = VehicleDynamics.Step(rig, input, dt)
	checkCollisionDamage(entry, Vector3.new(chassis.AssemblyLinearVelocity.X, 0, chassis.AssemblyLinearVelocity.Z).Magnitude)

	if telemetry.flippedFor > (occupant and RIGHT_OCCUPIED_AFTER or RIGHT_EMPTY_AFTER) then
		if occupant or next(entry.occupants) == nil then
			VehicleDynamics.Right(rig)
		end
	end
end

function VehicleService.Start()
	if started then
		return
	end
	started = true
	-- A new character is never seated, so whatever an old one left on the player is stale.
	local function watchPlayer(player)
		player.CharacterAdded:Connect(function()
			clearRider(player)
		end)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	-- #84: client-detected jolts, reported so a real playtest produces a number instead of an
	-- impression (claude-43's ask, 2026-09-21). Measured baseline this harness CAN see: flat road
	-- 0.00 vertical velocity, worst seam-at-speed case 3.14 studs/s -- VehicleClient's threshold
	-- (20) is well clear of both, so anything that arrives here is either a bug this harness missed
	-- or the one thing it structurally cannot see, a network ownership handoff (ServerControl marks
	-- exactly that). Counted, not just printed, so "how often" is answerable at a glance.
	Remotes.Event("VehicleJolt").OnServerEvent:Connect(function(player, jump, speed, serverControl)
		if not RateLimit.Take(player, "VehicleJolt") then
			return
		end
		if not SafeValue.Number(jump, 500) or not SafeValue.Number(speed, 500) then
			return
		end
		-- Only from someone actually driving: anyone else's report is noise in the count and the log.
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if not (humanoid and humanoid.SeatPart and humanoid.SeatPart:IsA("VehicleSeat")) then
			return
		end
		joltCount += 1
		warn(string.format("[VehicleJolt] #%d %s: %.1f studs/s vertical jump at %.0f studs/s forward speed, ServerControl %s",
			joltCount, player.Name, jump, speed, tostring(serverControl == true)))
	end)
	RunService.Stepped:Connect(function(_, dt)
		-- Wall clock, not os.clock() (which is process CPU time in Roblox -- a measured lesson
		-- elsewhere in this project): serverHoldUntil, airCheckIn and hoverFor are real-time holds
		-- and grace periods, and CPU time under-counts them whenever the server is busy.
		local now = tick()
		for index = #active, 1, -1 do
			local entry = active[index]
			-- Maps are destroyed wholesale between matches; drop the entries that went with them.
			if not entry.model.Parent or not entry.rig or not entry.rig.chassis.Parent then
				for _, rider in pairs(entry.riders) do
					if rider.character and rider.character.Parent then
						setMassless(entry, rider.character, false)
					end
					clearRider(rider.player)
				end
				for _, connection in pairs(entry.deaths) do
					connection:Disconnect()
				end
				byModel[entry.model] = nil
				table.remove(active, index)
			else
				step(entry, dt, now)
			end
		end
	end)
end

-- Parks vehicles on the towns' declared parking bays, and returns how many it managed.
--
-- Oliver, twice: cars should stand in parking lots and spaces that make sense, not on random grass.
-- The towns declare where those are (ParkingLots) and this fills them. It does nothing at all while
-- no town has any. A bay is used only if the ground under its own footprint is level: a declared bay
-- that is not (a town wired up wrongly, or a bay laid on a slope) is refused and said out loud, rather
-- than parking a car somewhere that looks worse than the verge it came from.
--
-- The way a real car park fills (Oliver 09-24, "make all the car placements make sense"): every
-- town's car park gets its turn before any gets a second car, so they don't all go in the first
-- town's; no more than LOT_DRIVABLE_SHARE of a car park is taken, and never its last bay, so what's
-- left of it is MapDecor.ParkBays' to part-fill with parked scenery; the bays are taken at random, not
-- from one end; and each car stands square in its bay, nose the bay's way, the middle of the car on
-- the middle of the bay (a van's body runs further back than forward). Each bay taken is marked
-- `ParkingBayTaken_<i>` on its town.
local LOT_DRIVABLE_SHARE = 0.5
-- The most a car stands off the middle of its bay, along it, so a row doesn't look stamped out.
local BAY_JITTER = 0.3

-- Moves a vehicle, keeping its yaw and height, so the middle of its bounding box is at `centre`
-- (about its own axes: a model's box is turned to its PrimaryPart).
local function centreModel(model, centre)
	local pivot = model:GetPivot()
	local box = model:GetBoundingBox()
	local offset = pivot:PointToObjectSpace(box.Position)
	local wanted = pivot:PointToObjectSpace(Vector3.new(centre.X, pivot.Y, centre.Z))
	model:PivotTo(pivot * CFrame.new(wanted.X - offset.X, 0, wanted.Z - offset.Z))
end

-- `share` (optional, default LOT_DRIVABLE_SHARE) is the most of any one car park, counting what's
-- already in it, that this call may fill.
function VehicleService.ParkInTowns(parent, map, wanted, rng, share)
	if not parent or not map or (wanted or 0) <= 0 then
		return 0
	end
	local roll = rng or Random.new(math.random(1, 2147483646))
	-- Flat attributes, because a Roblox attribute cannot hold a table: `ParkingBays` is the count and
	-- each bay is `ParkingBay_<i>`, a CFrame whose position is the bay's centre on the hardstanding
	-- and whose LookVector is the way a parked car's nose should point.
	local towns = map:FindFirstChild("Towns") or map
	local lots = {}
	for _, town in ipairs(towns:GetChildren()) do
		local count = tonumber(town:GetAttribute("ParkingBays")) or 0
		local size = town:GetAttribute("ParkingBaySize")
		local lot = { town = town, bays = {}, used = 0, taken = {} }
		for index = 1, count do
			local cf = town:GetAttribute("ParkingBay_" .. index)
			if typeof(cf) == "CFrame" and town:GetAttribute("ParkingBayTaken_" .. index) then
				lot.used += 1
				table.insert(lot.taken, cf.Position)
			elseif typeof(cf) == "CFrame" then
				-- Shuffled in as they come, so the bays are taken in no particular order.
				table.insert(lot.bays, roll:NextInteger(1, #lot.bays + 1), {
					cf = cf,
					index = index,
					w = typeof(size) == "Vector3" and size.X or nil,
					d = typeof(size) == "Vector3" and size.Z or nil,
				})
			end
		end
		-- A town that says it has no cars (MapGenerator marks it) leaves its car park empty.
		if count >= 2 and #lot.bays > 0 and not town:GetAttribute("NoParkedCars") then
			lot.cap = math.min(count - 1, math.max(1, math.floor(count * (share or LOT_DRIVABLE_SHARE))))
			table.insert(lots, lot)
		end
	end
	if #lots == 0 then
		return 0
	end

	local parked, refused = 0, 0
	local progress = true
	while parked < wanted and progress do
		progress = false
		for _, lot in ipairs(lots) do
			if parked >= wanted then
				break
			end
			while lot.used < lot.cap and #lot.bays > 0 do
				-- The next bay with nobody either side of it, if there is one: drivers spread out while a
				-- car park is empty, and two big cars side by side are mirror to mirror.
				local pickAt = #lot.bays
				for index = #lot.bays, 1, -1 do
					local free = true
					for _, taken in ipairs(lot.taken) do
						if (taken - lot.bays[index].cf.Position).Magnitude < (lot.bays[index].w or 8.9) + 0.5 then
							free = false
							break
						end
					end
					if free then
						pickAt = index
						break
					end
				end
				local bay = table.remove(lot.bays, pickAt)
				local yaw = math.atan2(-bay.cf.LookVector.X, -bay.cf.LookVector.Z)
				-- The bay's own size if the town gave one, otherwise TownKinds.Bay's.
				local size = Vector3.new(bay.w or 8.9, 1, bay.d or 16.6)
				footingParams.FilterDescendantsInstances = { parent }
				local spread, _ = footingAt(bay.cf.Position, yaw, size)
				if spread and spread <= FOOTING_TOLERANCE then
					local model = VehicleService.Create(parent, bay.cf.Position, yaw, roll:NextNumber() < 0.3 and "bike" or "car",
						{ rng = roll })
					if model then
						centreModel(model, (bay.cf * CFrame.new(0, 0, roll:NextNumber(-BAY_JITTER, BAY_JITTER))).Position)
						lot.town:SetAttribute("ParkingBayTaken_" .. bay.index, true)
						table.insert(lot.taken, bay.cf.Position)
						lot.used += 1
						parked += 1
						progress = true
					end
					break
				end
				refused += 1
			end
		end
	end
	if refused > 0 then
		warn(string.format("VehicleService: %d parking bays were refused because the ground under them is not level", refused))
	end
	return parked
end

function VehicleService.Count()
	return #active
end

-- Throws vehicles clear of a blast. `damage` is the blast's raw damage (the Explosives tab passes
-- what it deals a player at the centre). Whoever owns a vehicle's physics is the only one whose
-- impulse counts, so the server takes it back for a moment, pushes, and hands it back.
function VehicleService.ApplyBlast(centre, radius, damage)
	if not SafeValue.Vector3(centre) or not SafeValue.Number(radius, 1000) or radius <= 0 or not SafeValue.Number(damage, 1e5) then
		return
	end
	local strength = math.clamp(damage, 0, BLAST_MAX_DAMAGE) * BLAST_SPEED_PER_DAMAGE
	local now = tick() -- wall clock: this feeds entry.serverHoldUntil, compared against Start()'s tick()-based now
	for _, entry in ipairs(active) do
		local chassis = entry.rig and entry.rig.chassis
		if chassis and chassis.Parent then
			local offset = chassis.Position - centre
			local distance = offset.Magnitude
			if distance < radius then
				local falloff = 1 - distance / radius
				local away = Vector3.new(offset.X, 0, offset.Z)
				away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 0)
				local speed = strength * falloff * (entry.info.kind == "bike" and BLAST_BIKE_SCALE or 1)
				local mass = chassis.AssemblyMass
				entry.serverHoldUntil = now + BLAST_HOLD
				entry.restFor = 0
				updateOwnership(entry, now)
				chassis:ApplyImpulse((away * 0.55 + Vector3.new(0, 0.85, 0)).Unit * speed * mass)
				if away.Magnitude > 0 then
					local inertia = entry.rig.inertiaShape * mass
					chassis:ApplyAngularImpulse(Vector3.new(0, 1, 0):Cross(away) * speed * BLAST_SPIN * (inertia.X + inertia.Z) / 2)
				end
			end
		end
	end
end

function VehicleService.Get(model)
	return byModel[model]
end

return VehicleService
