-- Vehicle dynamics: how every vehicle moves, in one place that the server and the driver's client
-- both run, so they can never disagree about how a car handles.
--
--   VehicleDynamics.Handling[modelId]              -> tuning table (see TUNING below)
--   VehicleDynamics.Rig(model, findOnly)           -> rig, or nil
--   VehicleDynamics.Step(rig, input, dt)           -> telemetry   (before physics, every frame)
--   VehicleDynamics.Idle(rig)                                      (zero every force)
--   VehicleDynamics.SetIgnore(rig, instances)                      (riders, so rays skip them)
--   VehicleDynamics.Right(rig)                                     (back on its wheels, in place)
--   VehicleDynamics.AnimateWheels(rig, dt, steerAngle)             (any client: bob, steer, spin)
--
-- Whoever owns the chassis's physics steps it: the driver's client while a player drives, the
-- server otherwise. input = { throttle = -1..1, steer = -1..1, handbrake = bool, parked = bool }.
-- The force instances are made once, by the server (Rig without findOnly); a client only finds
-- them, so nothing it makes can double up when streaming delivers a model twice.
--
-- The model is arcade-but-physical. Each wheel samples the ground under the front, middle and
-- back of its tyre, so a round tyre rolls up a step instead of a stick hitting it. Where it
-- touches, a spring-damper holds the body up along the strut; lateral grip stops the tyre sliding
-- sideways and holds the car against a side slope; drive, brakes and a hill hold push along the
-- ground under that wheel. Lateral and longitudinal grip share one friction circle limited by the
-- wheel's own load and the surface, so a car slides at the limit instead of snapping. Every force
-- goes in at the wheel, so the body squats, dives and leans on its own and sits properly on a
-- grade instead of being held level. Assists, each doing one job:
--   gravity      drive pushes back against most of a hill's pull, so grades are driven, not
--                crawled, until the tyres run out of grip
--   governor     a vehicle can't run away past its top speed downhill
--   anti-roll    moves load across an axle so a car corners flat
--   yaw damping  takes the edge off spins without taking the steering away
--   rollover     cars: roll or pitch far past the ground's own angle is pushed back
--   air          damps tumbling and turns the wheels back toward the ground before landing
--   balance      bikes: an AlignOrientation holds the lean a turn needs (and the ground's pitch),
--                solved inside the physics step, so a bike can't topple, loop or wheelie over
--
-- Spring stiffness is a natural frequency and damping a ratio, so feel doesn't change with a
-- model's mass. Roblox gravity (196.2) makes real sag figures huge, so each spring carries its
-- share of the weight as a constant and the frequency only describes how it answers bumps.

local VehicleDynamics = {}

-- #53: the single source of truth for "how low is low". VehicleService.lua does not threshold
-- against this itself (nothing server-side needs to); VehicleClient.client.lua's HUD warning reads
-- it so the two never drift into disagreeing about the same number.
VehicleDynamics.LOW_HEALTH_SHARE = 0.25

local V = Vector3.new
local UP = V(0, 1, 0)
local rad = math.rad
local clamp = math.clamp

--------------------------------------------------------------------------------
-- TUNING
--------------------------------------------------------------------------------
-- topSpeed / reverseSpeed   studs/s (a sprinting player does 26)
-- accel                     studs/s^2 up to 60% of top; tapers to nothing at top
-- brake, coast              studs/s^2
-- grip, traction            friction coefficients: sideways, and along the heading
-- offroad                   0..1, how little loose ground (grass, sand, mud) costs this tyre
-- driven                    "front", "rear" or "all"
-- steerLow, steerHigh       front wheel angle in degrees at a crawl and at top speed
-- steerRate                 degrees/s toward the input (back toward centre is quicker)
-- travelUp, travelDown      suspension room above and below where the model was built
-- springHz, dampingRatio
-- bumpDamping, reboundDamping  optional: shares of that damping while a wheel is pushed up / extends
--                           again (defaults BUMP_DAMPING, REBOUND_DAMPING)
-- rideLift                  optional: studs the springs hold the body above where the model was built
--                           (ground clearance on rough ground; wheels are drawn down to meet the ground)
-- antiRoll                  0..~1.5, share of an axle's compression difference pushed back
-- yawDamping                0..1
-- downforce                 per stud/s squared, as a share of weight
-- lean, leanRate            bikes: most lean in degrees, how quickly it follows (1/s)

VehicleDynamics.Handling = {
	Rotster = {
		topSpeed = 84, reverseSpeed = 26, accel = 40, brake = 100, coast = 13,
		grip = 1.6, traction = 1.45, offroad = 0.35, driven = "all",
		steerLow = 36, steerHigh = 11, steerRate = 180,
		travelUp = 0.7, travelDown = 0.95, springHz = 2.0, dampingRatio = 0.6, antiRoll = 0.8, rideLift = 0.5,
		yawDamping = 0.4, downforce = 0,
	},
	CrocodiloRanger = {
		topSpeed = 78, reverseSpeed = 30, accel = 36, brake = 92, coast = 14,
		grip = 1.5, traction = 1.55, offroad = 0.85, driven = "all",
		steerLow = 34, steerHigh = 9, steerRate = 160,
		travelUp = 1.1, travelDown = 0.8, springHz = 1.5, dampingRatio = 0.55, antiRoll = 0.9,
		yawDamping = 0.4, downforce = 0,
	},
	TralalaGT = {
		topSpeed = 106, reverseSpeed = 28, accel = 46, brake = 118, coast = 11,
		grip = 1.9, traction = 1.45, offroad = 0, driven = "all",
		steerLow = 32, steerHigh = 8, steerRate = 200,
		-- Rough ground (09-25): the lowest car, so the most lift and the most droop.
		travelUp = 0.6, travelDown = 1.0, springHz = 2.2, dampingRatio = 0.65, antiRoll = 1.1, rideLift = 0.7,
		yawDamping = 0.45, downforce = 0.00004,
	},
	SahurVan = {
		topSpeed = 72, reverseSpeed = 24, accel = 30, brake = 86, coast = 14,
		grip = 1.4, traction = 1.3, offroad = 0.3, driven = "all",
		steerLow = 34, steerHigh = 10, steerRate = 150,
		travelUp = 0.8, travelDown = 1.15, springHz = 1.6, dampingRatio = 0.6, antiRoll = 1.3, rideLift = 0.7,
		yawDamping = 0.5, downforce = 0,
	},
	-- The armoured cars (Oliver 09-24: "we need armored vehicles too"): heavy, so everything about
	-- them is slower -- top speed, pick-up, braking, how fast the wheel turns -- and they sit on softer,
	-- longer springs that let the weight lean. The scout car is a brisk 70 (the van does 72); the carrier
	-- is the slowest thing on four wheels, and the slowest to get going (24 against the van's 30). Both
	-- drive all four wheels and shrug off rough ground almost as well as the Ranger.
	TartarugaScout = {
		topSpeed = 70, reverseSpeed = 22, accel = 30, brake = 84, coast = 15,
		grip = 1.5, traction = 1.5, offroad = 0.75, driven = "all",
		steerLow = 32, steerHigh = 8, steerRate = 140,
		travelUp = 1.0, travelDown = 1.35, springHz = 1.5, dampingRatio = 0.6, antiRoll = 1.1, rideLift = 0.7,
		yawDamping = 0.5, downforce = 0,
	},
	CameloCarrier = {
		topSpeed = 62, reverseSpeed = 20, accel = 24, brake = 78, coast = 16,
		grip = 1.45, traction = 1.5, offroad = 0.7, driven = "all",
		steerLow = 30, steerHigh = 7, steerRate = 120,
		travelUp = 1.0, travelDown = 0.7, springHz = 1.4, dampingRatio = 0.62, antiRoll = 1.2,
		yawDamping = 0.55, downforce = 0,
	},
	BananiniScoot = {
		topSpeed = 66, reverseSpeed = 12, accel = 44, brake = 104, coast = 12,
		grip = 1.7, traction = 1.4, offroad = 0.1, driven = "rear",
		steerLow = 40, steerHigh = 12, steerRate = 240,
		travelUp = 0.45, travelDown = 0.35, springHz = 2.4, dampingRatio = 0.6,
		yawDamping = 0.3, lean = 32, leanRate = 8,
	},
	PatapimScrambler = {
		topSpeed = 90, reverseSpeed = 12, accel = 48, brake = 100, coast = 12,
		grip = 1.65, traction = 1.6, offroad = 0.8, driven = "rear",
		steerLow = 38, steerHigh = 10, steerRate = 220,
		travelUp = 1.2, travelDown = 0.8, springHz = 1.6, dampingRatio = 0.55,
		yawDamping = 0.3, lean = 40, leanRate = 7,
	},
	BrrStreetfighter = {
		topSpeed = 114, reverseSpeed = 12, accel = 54, brake = 120, coast = 11,
		grip = 1.9, traction = 1.5, offroad = 0.15, driven = "rear",
		steerLow = 34, steerHigh = 8, steerRate = 220,
		travelUp = 0.55, travelDown = 0.35, springHz = 2.4, dampingRatio = 0.6,
		yawDamping = 0.35, lean = 46, leanRate = 8, downforce = 0.00002,
	},
}

-- Assists shared by every model.
local SWEEP = 0.62               -- tyre samples ahead of and behind the axle, as a share of radius
local SAMPLES = { 0, SWEEP, -SWEEP }
local BUMP_EXTRA = 0.45          -- how far past full travel a step can push before the body takes it
local PRELOAD_RAMP = 0.12        -- the weight share fades in over this much compression
local FRONT_SPLIT = 0.4           -- share of the drive to the front axle, both axles down (AWD)
local MAX_WHEEL_SHARE = 0.5       -- most of the drive any one wheel of a car takes
local MAX_LOAD_G = 2.5           -- one wheel never pushes harder than this many of its weight share
local MIN_HOLD = 1 / 60          -- s: a force set in Step is held at least one 60 Hz physics step
local WALL_DOT = 0.5             -- a hit whose face leans more than 60 degrees off the strut is a side, not ground
local LATERAL_RESPONSE = 20      -- 1/s, how quickly sideways slip is taken out within the grip
local HOLD_SPEED = 2.5           -- below this with no input, brakes hold the vehicle on a slope
local HOLD_RESPONSE = 8          -- 1/s
local PARKED_STILL = 4           -- studs/s: an empty vehicle moving slower than this is parked, not sliding
local PARKED_HOLD = 9            -- 1/s, how fast a parked vehicle's drift is taken out
local GRAVITY_ASSIST = 0.85      -- share of a hill's pull the drive pushes back against
local BUMP_DAMPING = 0.7         -- share of the damping while a wheel is being pushed up (rough ground)
local REBOUND_DAMPING = 1.4      -- share of it while the wheel extends again (no pogo)
local BUMP_STOP_DAMPING = 1.0    -- extra damping, on the way in, once a wheel is at its bump stop
local GOVERNOR = 1.06            -- past this share of top speed, drag grows until it holds
local OVERSPEED_RESPONSE = 6     -- 1/s
local HANDBRAKE_GRIP = 0.42      -- rear lateral grip while the handbrake is on
local AIR_DAMPING = 3.0          -- 1/s, tumbling bled off while airborne
local AIR_RIGHTING = 5.5         -- how firmly an airborne car turns wheels-down
local ROLLOVER_START = rad(19)   -- cars: roll or pitch past the ground's own angle by more than this
local ROLLOVER_GAIN = 85         -- 1/s^2 per radian past it
local ROLL_RATE_FREE = 0.6       -- cars: roll rate (rad/s) the body is free to reach on its springs
local ROLL_RATE_DAMPING = 15     -- 1/s, how hard a faster roll (a kerb strike, a lopsided landing) is damped
local FLIP_UP_DOT = 0.25         -- a body whose up points less than this upward counts as flipped
local KICKSTAND = rad(-9)        -- a parked bike leans on its stand (to the left)
local BALANCE_RESPONSIVENESS = 20
local BALANCE_TORQUE = 2500      -- per unit of mass

-- How much grip loose or slick ground leaves a road tyre (off-road tyres lose less; see offroad).
local SURFACE_GRIP = {
	[Enum.Material.Grass] = 0.82, [Enum.Material.LeafyGrass] = 0.8, [Enum.Material.Ground] = 0.8,
	[Enum.Material.Mud] = 0.62, [Enum.Material.Sand] = 0.66, [Enum.Material.Snow] = 0.6,
	[Enum.Material.Ice] = 0.32, [Enum.Material.Glacier] = 0.38, [Enum.Material.Salt] = 0.78,
	[Enum.Material.Pebble] = 0.8, [Enum.Material.Rock] = 0.9, [Enum.Material.Slate] = 0.9,
	[Enum.Material.Basalt] = 0.9, [Enum.Material.Limestone] = 0.9, [Enum.Material.Sandstone] = 0.88,
	[Enum.Material.CrackedLava] = 0.85, [Enum.Material.Marble] = 0.78, [Enum.Material.Glass] = 0.7,
	[Enum.Material.SmoothPlastic] = 0.86, [Enum.Material.Plastic] = 0.9, [Enum.Material.Metal] = 0.85,
	[Enum.Material.Foil] = 0.8, [Enum.Material.Wood] = 0.9, [Enum.Material.WoodPlanks] = 0.9,
	[Enum.Material.Water] = 0.5,
}

local function surfaceGrip(material, offroad)
	local base = SURFACE_GRIP[material] or 1
	return 1 - (1 - base) * (1 - (offroad or 0))
end

local function project(vector, normal)
	return vector - normal * vector:Dot(normal)
end

--------------------------------------------------------------------------------
-- Rigging
--------------------------------------------------------------------------------

local function findOrMake(parent, className, name, findOnly, init)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	if findOnly then
		return nil
	end
	local instance = Instance.new(className)
	instance.Name = name
	init(instance)
	instance.Parent = parent
	return instance
end

-- Where `part` sits in the chassis's space with every joint at rest, following its Joint chain.
local function restFrame(part, chassis)
	local frame = CFrame.identity
	local current = part
	for _ = 1, 8 do
		if current == chassis then
			return frame
		end
		local joint = current:FindFirstChild("Joint")
		if not joint or not joint.Part0 then
			return nil
		end
		frame = joint.C0 * joint.C1:Inverse() * frame
		current = joint.Part0
	end
	return nil
end

-- Finds a model's wheels and the forces it's driven with. Without findOnly (the server) the force
-- instances are made the first time and found afterwards; with it (a client) a model whose
-- forces haven't streamed in yet returns nil.
function VehicleDynamics.Rig(model, findOnly)
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	local modelId = model:GetAttribute("VehicleModel")
	local handling = VehicleDynamics.Handling[modelId]
	if not chassis or not handling then
		return nil
	end
	local bike = handling.lean ~= nil

	local wheels = {}
	local steerWheels = {}
	for _, hub in ipairs(model:GetChildren()) do
		if hub:IsA("BasePart") and hub:GetAttribute("Pivot") == "SteerWheel" then
			local joint = hub:FindFirstChild("Joint")
			if not joint then
				return nil
			end
			table.insert(steerWheels, { joint = joint, ratio = hub:GetAttribute("Ratio") or 7 })
		end
		if hub:IsA("BasePart") and hub:GetAttribute("Radius") then
			local joint = hub:FindFirstChild("Joint")
			local rest = joint and restFrame(hub, chassis)
			if not rest then
				return nil
			end
			local mount = rest.Position
			-- Pivots above the hub do some of its moving: a fork steers and slides, a swingarm swings.
			local steerJoint, sliderJoint, sliderUp, swingJoint, swingArm = nil, nil, 1, nil, 1
			local above = joint.Part0
			while above and above ~= chassis do
				local kind = above:GetAttribute("Pivot")
				local aboveJoint = above:FindFirstChild("Joint")
				local aboveRest = aboveJoint and restFrame(above, chassis)
				if not aboveRest then
					return nil
				end
				if kind == "Steer" then
					steerJoint = aboveJoint
				elseif kind == "Slider" then
					sliderJoint = aboveJoint
					sliderUp = math.max(0.3, aboveRest.UpVector.Y)
				elseif kind == "Swing" then
					swingJoint = aboveJoint
					local arm = aboveRest:PointToObjectSpace(mount).Z
					swingArm = math.abs(arm) > 0.2 and arm or 1
				end
				above = aboveJoint.Part0
			end
			local attachment = findOrMake(chassis, "Attachment", "Contact_" .. hub.Name, findOnly, function(instance)
				instance.Position = mount
			end)
			local force = attachment and findOrMake(chassis, "VectorForce", "Force_" .. hub.Name, findOnly, function(instance)
				instance.Attachment0 = attachment
				instance.RelativeTo = Enum.ActuatorRelativeTo.World
				instance.ApplyAtCenterOfMass = false
				instance.Force = Vector3.zero
			end)
			if not force then
				return nil
			end
			local front = hub:GetAttribute("Front") == true
			local driven = handling.driven or "all"
			table.insert(wheels, {
				name = hub.Name,
				hub = hub,
				joint = joint,
				mount = mount,
				force = force,
				radius = hub:GetAttribute("Radius") or 1,
				steer = hub:GetAttribute("Steer") == true,
				front = front,
				side = mount.X < -0.05 and -1 or (mount.X > 0.05 and 1 or 0),
				drive = driven == "all" or (driven == "front" and front) or (driven == "rear" and not front),
				compression = handling.travelDown - (handling.rideLift or 0),
				grounded = false,
				load = 0,
				visualOffset = 0,
				spin = 0,
				steerJoint = steerJoint,
				sliderJoint = sliderJoint,
				sliderUp = sliderUp,
				swingJoint = swingJoint,
				swingArm = swingArm,
			})
		end
	end
	if #wheels == 0 then
		return nil
	end
	table.sort(wheels, function(a, b)
		return a.name < b.name
	end)

	local assistAttachment = findOrMake(chassis, "Attachment", "AssistAttachment", findOnly, function() end)
	local torque = assistAttachment and findOrMake(chassis, "Torque", "Assist", findOnly, function(instance)
		instance.Attachment0 = assistAttachment
		instance.RelativeTo = Enum.ActuatorRelativeTo.World
		instance.Torque = Vector3.zero
	end)
	local downforce = assistAttachment and findOrMake(chassis, "VectorForce", "Downforce", findOnly, function(instance)
		instance.Attachment0 = assistAttachment
		instance.RelativeTo = Enum.ActuatorRelativeTo.World
		instance.ApplyAtCenterOfMass = true
		instance.Force = Vector3.zero
	end)
	if not torque or not downforce then
		return nil
	end

	local balance = nil
	if bike then
		-- The attachment's primary axis (its X) is the bike's up; PrimaryAxisOnly leaves yaw free.
		local balanceAttachment = findOrMake(chassis, "Attachment", "BalanceAttachment", findOnly, function(instance)
			instance.CFrame = CFrame.fromMatrix(Vector3.zero, UP, V(0, 0, -1))
		end)
		balance = balanceAttachment and findOrMake(chassis, "AlignOrientation", "Balance", findOnly, function(instance)
			instance.Attachment0 = balanceAttachment
			instance.Mode = Enum.OrientationAlignmentMode.OneAttachment
			instance.PrimaryAxisOnly = true
			instance.Responsiveness = BALANCE_RESPONSIVENESS
			instance.MaxTorque = chassis.AssemblyMass * BALANCE_TORQUE
			instance.MaxAngularVelocity = 8
			instance.CFrame = CFrame.fromMatrix(Vector3.zero, UP, V(0, 0, -1))
		end)
		if not balance then
			return nil
		end
	end

	-- Anti-roll pairs: the left and right wheel of each axle.
	local axles = {}
	for _, a in ipairs(wheels) do
		if a.side < 0 then
			for _, b in ipairs(wheels) do
				if b.side > 0 and b.front == a.front then
					table.insert(axles, { a, b })
				end
			end
		end
	end

	local frontZ, rearZ, frontN, rearN = 0, 0, 0, 0
	for _, wheel in ipairs(wheels) do
		if wheel.front then
			frontZ += wheel.mount.Z
			frontN += 1
		else
			rearZ += wheel.mount.Z
			rearN += 1
		end
	end
	local wheelbase = (frontN > 0 and rearN > 0) and math.abs(rearZ / rearN - frontZ / frontN) or 6

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { model }
	-- Deliberately opposite to the hover check in VehicleService, which does NOT ignore water: a
	-- wheel must never find grip on a river (you would drive across it), while a hull floating on one
	-- is properly supported and must not be judged to be hovering. Neither is a mistake.
	rayParams.IgnoreWater = true

	local size = chassis.Size
	return {
		model = model,
		chassis = chassis,
		handling = handling,
		bike = bike,
		wheels = wheels,
		steerWheels = steerWheels,
		axles = axles,
		wheelbase = wheelbase,
		torque = torque,
		downforce = downforce,
		balance = balance,
		rayParams = rayParams,
		ignoreBase = { model },
		ignoreExtra = {},
		-- Weak keys on purpose, and safe: this is only a cache of "can a tyre stand on this part",
		-- so an entry the collector takes is simply worked out again the next time that part is hit.
		-- It is weak so a part that leaves the world does not keep its entry (or itself) alive.
		verdicts = setmetatable({}, { __mode = "k" }),
		steerAngle = 0,
		lean = 0,
		groundUp = UP,
		flippedFor = 0,
		-- Rough principal inertia of the collider box; multiplied by the assembly's mass each step.
		inertiaShape = V((size.Y ^ 2 + size.Z ^ 2) / 12, (size.X ^ 2 + size.Z ^ 2) / 12, (size.X ^ 2 + size.Y ^ 2) / 12),
	}
end

function VehicleDynamics.Idle(rig)
	for _, wheel in ipairs(rig.wheels) do
		wheel.force.Force = Vector3.zero
	end
	rig.torque.Torque = Vector3.zero
	rig.downforce.Force = Vector3.zero
end

local function refreshFilter(rig)
	local list = table.clone(rig.ignoreBase)
	for _, item in ipairs(rig.ignoreExtra) do
		table.insert(list, item)
	end
	rig.rayParams.FilterDescendantsInstances = list
end

-- Whoever is sitting in a vehicle is welded into it, and a ray that hit its own rider would
-- think the ground was up at the seat.
function VehicleDynamics.SetIgnore(rig, extra)
	local base = { rig.model }
	for _, item in ipairs(extra or {}) do
		table.insert(base, item)
	end
	local same = #base == #rig.ignoreBase
	if same then
		for index, item in ipairs(base) do
			if rig.ignoreBase[index] ~= item then
				same = false
				break
			end
		end
	end
	if not same then
		rig.ignoreBase = base
		refreshFilter(rig)
	end
end

--------------------------------------------------------------------------------
-- Ground
--------------------------------------------------------------------------------

-- What a wheel can stand on: terrain, anything solid, and thin visible slabs laid over the ground
-- (road asphalt, kerbs and pavements don't collide, but a tyre should still ride on top of
-- them). Not characters, invisible volumes, or foliage and other clutter.
local function standable(rig, part)
	local verdict = rig.verdicts[part]
	if verdict == nil then
		if part:IsA("Terrain") then
			verdict = true
		else
			local model = part:FindFirstAncestorOfClass("Model")
			if model and model:FindFirstChildOfClass("Humanoid") then
				verdict = model
			elseif part.CanCollide then
				verdict = true
			else
				verdict = part.Anchored and part.Transparency < 0.5 and part.Size.Y <= 1.2
			end
		end
		rig.verdicts[part] = verdict
	end
	return verdict
end

local function cast(rig, origin, direction)
	for _ = 1, 4 do
		local hit = workspace:Raycast(origin, direction, rig.rayParams)
		if not hit then
			return nil
		end
		local verdict = standable(rig, hit.Instance)
		if verdict == true then
			return hit
		end
		if #rig.ignoreExtra >= 48 then
			table.clear(rig.ignoreExtra)
		end
		table.insert(rig.ignoreExtra, typeof(verdict) == "Instance" and verdict or hit.Instance)
		refreshFilter(rig)
	end
	return nil
end

-- The least extension any sample of the tyre allows (the tyre sits on whatever it reaches first),
-- and the hit that set it.
local function contact(rig, wheel, frame, castUp, castForward, travel)
	local radius = wheel.radius
	local base = frame:PointToWorldSpace(wheel.mount) + castUp * rig.handling.travelUp
	local bestExtension, bestHit = nil, nil
	-- `rig.samples` stands in for SAMPLES on one rig only (a test plants a single ray per wheel with it).
	for _, share in ipairs(rig.samples or SAMPLES) do
		local offset = share * radius
		local depth = math.sqrt(radius * radius - offset * offset)
		local hit = cast(rig, base + castForward * offset, -castUp * (travel + depth))
		if hit then
			local extension = hit.Distance - depth
			if not bestExtension or extension < bestExtension then
				bestExtension, bestHit = extension, hit
			end
		end
	end
	return bestExtension, bestHit
end

--------------------------------------------------------------------------------
-- Step
--------------------------------------------------------------------------------

-- Engine push per unit mass at `speed` toward a top of `top`: full up to 60%, then tapering.
local function engine(accel, speed, top)
	if speed <= top * 0.6 then
		return accel
	end
	return accel * math.max(0, top - speed) / (top * 0.4)
end

-- All-wheel drive (Oliver 09-25): the front axle's share of the drive, from the load on each axle's
-- grounded driven wheels. Weight even on both (or the front up to half light): FRONT_SPLIT, the rest
-- to the rear. The front lighter than that (up a climb, over a crest): its share falls with its load,
-- the way a torque-sensing centre differential sends drive to the axle that can use it -- a fixed
-- 40/60 lost the Ranger 5 degrees of climb, its front tyres spinning. The rear lighter (hung on a lip,
-- cresting a bump): the front's share rises as the rear's load falls. One axle down: all of it there.
-- Within an axle Step splits by the load on each wheel (limited slip), and no wheel of a car takes
-- more than MAX_WHEEL_SHARE of the whole however few are down -- the full drive is never put through
-- one tyre (the fling guard). A bike's one driven wheel takes it all.
function VehicleDynamics.DriveSplit(frontLoad, rearLoad)
	if rearLoad <= 0 then
		return frontLoad > 0 and 1 or 0
	elseif frontLoad <= 0 then
		return 0
	end
	local front = frontLoad / (frontLoad + rearLoad)
	if front <= FRONT_SPLIT then
		return front
	elseif front <= 0.5 then
		return FRONT_SPLIT
	end
	return front - (0.5 - FRONT_SPLIT)
end

function VehicleDynamics.Step(rig, input, dt)
	-- The real frame time, however long: the forces set now act until the next step, so a slow
	-- frame must be answered with forces sized for it. Every term below stays stable at any dt.
	dt = clamp(dt, 1 / 240, 0.25)
	local gravity = workspace.Gravity
	local chassis = rig.chassis
	local h = rig.handling
	local frame = chassis.CFrame
	local mass = chassis.AssemblyMass
	local wheels = rig.wheels
	local wheelCount = #wheels
	local wheelMass = mass / wheelCount
	local velocity = chassis.AssemblyLinearVelocity
	local angular = chassis.AssemblyAngularVelocity
	local bodyUp = frame.UpVector
	local bodyForward = frame.LookVector
	local bodyRight = frame.RightVector
	local forwardSpeed = velocity:Dot(bodyForward)
	local speed = velocity.Magnitude

	local throttle = clamp(input.throttle or 0, -1, 1)
	local steerInput = clamp(input.steer or 0, -1, 1)
	local handbrake = input.handbrake == true

	-- Steering: speed-sensitive, eased toward the input, quicker back to centre.
	local speedFraction = clamp(math.abs(forwardSpeed) / h.topSpeed, 0, 1)
	local maxSteer = h.steerLow + (h.steerHigh - h.steerLow) * speedFraction ^ 0.75
	local targetSteer = steerInput * maxSteer
	local returning = math.abs(targetSteer) < math.abs(rig.steerAngle) or targetSteer * rig.steerAngle < 0
	local steerStep = h.steerRate * (returning and 1.6 or 1) * dt
	rig.steerAngle += clamp(targetSteer - rig.steerAngle, -steerStep, steerStep)

	-- Rays go along the struts; a bike's struts are taken upright, whatever its lean.
	local leanNow = 0
	local castUp = bodyUp
	if rig.bike then
		leanNow = math.asin(clamp(-bodyRight.Y, -1, 1))
		castUp = CFrame.fromAxisAngle(bodyForward, -leanNow):VectorToWorldSpace(bodyUp)
	end

	-- #84/#109: how long a force set now is actually held. A frame can be shorter than the physics
	-- step that follows it (a 120 or 144 Hz screen, with the engine stepping this assembly at 60 Hz),
	-- and every "held for too long" limit below must be sized for the step, not the frame.
	local heldFor = math.max(dt, MIN_HOLD)

	-- Pass 1: contact, compression and spring loads.
	local travel = h.travelUp + h.travelDown
	local omega = 2 * math.pi * h.springHz
	-- A spring or damper held for a long frame overshoots; past these limits they're softened.
	local k = wheelMass * math.min(omega * omega, 2.5 / (heldFor * heldFor))
	local damper = wheelMass * math.min(2 * h.dampingRatio * omega, 1.5 / heldFor)
	-- Rough ground (Oliver 09-24): softer on the way in, firmer on the way out, the way a real damper is
	-- valved. A rock or a rubble block is soaked up instead of kicked back through the body, and the
	-- spring can't fling the body up off the far side of it (the pogo). The way-out figure stays under
	-- the limit that keeps a held damper force from overshooting within one step.
	local damperBump = damper * (h.bumpDamping or BUMP_DAMPING)
	local damperRebound = math.min(damper * (h.reboundDamping or REBOUND_DAMPING), wheelMass * 1.5 / heldFor)
	-- Where the springs hold each wheel at rest: its built place, less any ride lift.
	local neutral = h.travelDown - (h.rideLift or 0)
	local maxLoad = wheelMass * gravity * MAX_LOAD_G
	local groundedCount = 0
	local normalSum = Vector3.zero
	for _, wheel in ipairs(wheels) do
		local extension, hit = contact(rig, wheel, frame, castUp, bodyForward, travel)
		if hit then
			-- A ray tilted by pitch or roll can meet the SIDE of a road slab, kerb or deck edge. That
			-- face is not what the tyre rolls on: taken as the ground, it turned drive and grip
			-- toward the vertical and tipped groundUp over. The strut's own axis stands in for it.
			local normal = hit.Normal
			if normal:Dot(castUp) < WALL_DOT then
				normal = castUp
			end
			wheel.compression = clamp(travel - extension, 0, travel + BUMP_EXTRA)
			wheel.grounded = true
			wheel.normal = normal
			wheel.contactPoint = hit.Position
			wheel.surface = surfaceGrip(hit.Material, h.offroad)
			wheel.material = hit.Material
			groundedCount += 1
			normalSum += normal
			-- #84/#109: the damper reads how fast the body is closing on the ground from VELOCITY,
			-- not from the change in ray length since the last frame. The difference was the bounce:
			--   * on a frame with no physics step under it (a fast screen, the engine stepping this
			--     assembly at 60 Hz) the rays saw nothing move, so the damper read zero, and the next
			--     frame saw a whole step's movement divided by a short frame. The damper stopped
			--     damping and the car pogoed: tools/vehicle_stability_sim.py puts a TralalaGT
			--     airborne on a flat road at 120 fps over 60 Hz physics.
			--   * a slab edge, a stop line or a seam arrives in one frame, and differencing turned
			--     every such step into a damper kick; a wheel that had just missed (compression 0)
			--     read its first hit back as a slam.
			-- Velocity along the contact normal is the same number wherever the ground is smooth
			-- and has none of those faults. The ground's own velocity counts when it moves.
			local closing = chassis:GetVelocityAtPosition(frame:PointToWorldSpace(wheel.mount))
			local ground = hit.Instance
			if ground:IsA("BasePart") and not ground.Anchored then
				closing -= ground:GetVelocityAtPosition(hit.Position)
			end
			local compressionSpeed = clamp(-closing:Dot(normal) / math.max(normal:Dot(castUp), WALL_DOT), -16, 16)
			local preload = wheelMass * gravity * clamp(wheel.compression / PRELOAD_RAMP, 0, 1)
			local load = preload + k * (wheel.compression - neutral)
				+ (compressionSpeed > 0 and damperBump or damperRebound) * compressionSpeed
			if wheel.compression > travel - 0.05 then
				-- Bump stop: bottoming out is hard, and a step past full travel lifts the body. It is
				-- rubber, not a second spring, so most of it is there on the way in and little of it
				-- on the way out: a bike cornering hard used to squash onto the stop and be thrown
				-- off the ground by it, and a bike that leaves the ground in a steady turn is a pogo
				-- stick, not a motorbike.
				local over = wheel.compression - (travel - 0.05)
				load += k * 4 * over * (compressionSpeed > 0 and 1 or 0.2)
				-- And it takes the speed out of a wheel that arrives at it fast, rather than stopping it dead
				-- on the stop's spring alone (the jolt through the body on a kerb or crater lip).
				load += damper * BUMP_STOP_DAMPING * math.max(compressionSpeed, 0)
			end
			wheel.load = clamp(load, 0, maxLoad)
		else
			wheel.compression = 0
			wheel.grounded = false
			wheel.load = 0
		end
	end

	for _, pair in ipairs(rig.axles) do
		local a, b = pair[1], pair[2]
		if a.grounded and b.grounded and (h.antiRoll or 0) > 0 then
			local transfer = (a.compression - b.compression) * k * h.antiRoll
			a.load = clamp(a.load + transfer, 0, maxLoad)
			b.load = clamp(b.load - transfer, 0, maxLoad)
		end
	end

	-- (Normals that cancel out, a wheel either side of a knife edge, have no direction to give.)
	local groundUp = normalSum.Magnitude > 0.1 and normalSum.Unit or UP
	local forwardGround = project(bodyForward, groundUp)
	forwardGround = forwardGround.Magnitude > 0.05 and forwardGround.Unit or bodyForward

	-- What the driver is asking of the tyres, per unit mass.
	local driveAccel, brakeAccel, coastAccel, hold = 0, 0, 0, false
	if throttle > 0.02 then
		if forwardSpeed < -1.5 then
			brakeAccel = h.brake * throttle
		else
			driveAccel = engine(h.accel, math.max(forwardSpeed, 0), h.topSpeed) * throttle
			-- Against the hill, only when climbing it.
			driveAccel += math.max(0, gravity * forwardGround.Y) * GRAVITY_ASSIST * throttle
		end
	elseif throttle < -0.02 then
		if forwardSpeed > 1.5 then
			brakeAccel = h.brake * -throttle
		else
			driveAccel = -engine(h.accel * 0.75, math.max(-forwardSpeed, 0), h.reverseSpeed) * -throttle
			driveAccel -= math.max(0, -gravity * forwardGround.Y) * GRAVITY_ASSIST * -throttle
		end
	elseif math.abs(forwardSpeed) < HOLD_SPEED or input.parked then
		hold = true
	else
		coastAccel = h.coast
	end
	local overspeed = math.max(0, math.abs(forwardSpeed) - (forwardSpeed >= 0 and h.topSpeed or h.reverseSpeed) * GOVERNOR)
	local governorAccel = overspeed * OVERSPEED_RESPONSE * 3

	local drivenGrounded, drivenCount, frontLoad, rearLoad = 0, 0, 0, 0
	for _, wheel in ipairs(wheels) do
		drivenCount += wheel.drive and 1 or 0
		if wheel.drive and wheel.grounded then
			drivenGrounded += 1
			if wheel.front then
				frontLoad += wheel.load
			else
				rearLoad += wheel.load
			end
		end
	end
	local frontShare = VehicleDynamics.DriveSplit(frontLoad, rearLoad)
	local wheelCap = drivenCount > 1 and MAX_WHEEL_SHARE or 1

	-- Pass 2: grip, drive and brakes at each wheel.
	local steerFrame = frame * CFrame.Angles(0, -rad(rig.steerAngle), 0)
	local anySlip = false
	for _, wheel in ipairs(wheels) do
		if not wheel.grounded or wheel.load <= 0 then
			wheel.force.Force = castUp * wheel.load
			wheel.slip = false
		else
			local normal = wheel.normal
			local heading = wheel.steer and steerFrame.LookVector or bodyForward
			local forward = project(heading, normal)
			if forward.Magnitude < 0.05 then
				forward = forwardGround
			end
			forward = forward.Unit
			local right = forward:Cross(normal)
			if right.Magnitude < 0.05 then
				-- Heading straight into the surface (a wall caught by a ray): no sideways to grip.
				right = bodyRight
			end
			right = right.Unit

			local wheelVelocity = chassis:GetVelocityAtPosition(frame:PointToWorldSpace(wheel.mount))
			local lateralSpeed = wheelVelocity:Dot(right)
			local longSpeed = wheelVelocity:Dot(forward)
			local rolling = longSpeed >= 0 and 1 or -1

			local surface = wheel.surface
			local rear = not wheel.front
			local lateralLimit = h.grip * surface * wheel.load * ((handbrake and rear) and HANDBRAKE_GRIP or 1)
			local longLimit = h.traction * surface * wheel.load

			-- Sideways: take out the slip, and hold against the slope.
			local slipForce = -lateralSpeed * wheelMass * LATERAL_RESPONSE
			local slipCap = math.abs(lateralSpeed) * wheelMass / (2 * heldFor)
			local lateral = clamp(slipForce, -slipCap, slipCap) + wheelMass * gravity * right.Y

			-- Along the heading.
			local long = 0
			if wheel.drive and driveAccel ~= 0 and drivenGrounded > 0 then
				local axleLoad = wheel.front and frontLoad or rearLoad
				local share = axleLoad > 0 and (wheel.front and frontShare or 1 - frontShare) * wheel.load / axleLoad or 0
				long += mass * driveAccel * math.min(share, wheelCap)
			end
			local stopCap = math.abs(longSpeed) * wheelMass / (2 * heldFor)
			local resist = brakeAccel + coastAccel + governorAccel
			if handbrake and rear then
				resist = math.max(resist, h.brake * 0.8)
			end
			if resist > 0 then
				long -= rolling * math.min(resist * wheelMass, stopCap)
			end
			if hold then
				long += wheelMass * gravity * forward.Y - clamp(longSpeed * wheelMass * HOLD_RESPONSE, -stopCap, stopCap)
			end

			-- One friction circle: sideways grip keeps priority so braking in a bend doesn't spin,
			-- but drive and brakes always keep a share.
			local ly = lateralLimit > 0 and lateral / lateralLimit or 0
			local lx = longLimit > 0 and long / longLimit or 0
			if ly * ly + lx * lx > 1 then
				ly = clamp(ly, -1, 1)
				local room = math.max(0.35, math.sqrt(math.max(0, 1 - ly * ly)))
				lx = clamp(lx, -room, room)
				local total = math.sqrt(ly * ly + lx * lx)
				if total > 1 then
					ly /= total
					lx /= total
				end
				wheel.slip = math.abs(lateralSpeed) > 3 or math.abs(lx) >= room * 0.99
				anySlip = anySlip or wheel.slip
			else
				wheel.slip = false
			end
			lateral = ly * lateralLimit
			long = lx * longLimit

			wheel.force.Force = castUp * wheel.load + right * lateral + forward * long
			wheel.lateral, wheel.long, wheel.lateralSpeed = lateral, long, lateralSpeed
		end
	end

	-- Assists, as one torque.
	local inertia = rig.inertiaShape * mass
	local torque = Vector3.zero
	local grounded = groundedCount > 0

	if grounded then
		-- Yaw damping: only the part of the yaw rate the steering doesn't account for.
		local yawRate = angular:Dot(bodyUp)
		local expected = -forwardSpeed * math.tan(rad(rig.steerAngle)) / rig.wheelbase
		local excess = yawRate - expected
		local threshold = 0.35 + (handbrake and 1.2 or 0)
		if math.abs(excess) > threshold then
			local over = math.abs(excess) - threshold
			torque -= bodyUp * (excess > 0 and 1 or -1) * over * inertia.Y * (h.yawDamping or 0) * 10
		end
		if (h.downforce or 0) > 0 then
			rig.downforce.Force = -groundUp * mass * gravity * math.min(h.downforce * forwardSpeed * forwardSpeed, 1.2)
		else
			rig.downforce.Force = Vector3.zero
		end
	else
		rig.downforce.Force = Vector3.zero
	end

	if not rig.bike then
		if grounded then
			-- Rollover: roll or pitch well past the ground's own angle is pushed back.
			local roll = math.asin(clamp(-bodyRight:Dot(groundUp), -1, 1))
			local rollRate = angular:Dot(bodyForward)
			if math.abs(roll) > ROLLOVER_START then
				local over = (math.abs(roll) - ROLLOVER_START) * (roll > 0 and 1 or -1)
				torque += bodyForward * (-over * ROLLOVER_GAIN - rollRate * 8) * inertia.Z
			elseif math.abs(rollRate) > ROLL_RATE_FREE then
				local fast = rollRate - ROLL_RATE_FREE * (rollRate > 0 and 1 or -1)
				torque -= bodyForward * fast * ROLL_RATE_DAMPING * inertia.Z
			end
			local pitch = math.asin(clamp(bodyForward:Dot(groundUp), -1, 1))
			if math.abs(pitch) > ROLLOVER_START then
				local over = (math.abs(pitch) - ROLLOVER_START) * (pitch > 0 and 1 or -1)
				local pitchRate = angular:Dot(bodyRight)
				torque += bodyRight * (-over * ROLLOVER_GAIN - pitchRate * 8) * inertia.X
			end
		else
			-- In the air: bleed off tumbling and turn wheels-down toward whatever is below, so a
			-- jump onto a slope lands square on it.
			local tumble = angular - bodyUp * angular:Dot(bodyUp) * 0.5
			torque -= tumble * AIR_DAMPING * (inertia.X + inertia.Z) / 2
			local below = cast(rig, chassis.Position, V(0, -40, 0))
			local target = (below and below.Normal.Y > 0.6) and below.Normal or UP
			local axis = bodyUp:Cross(target)
			if axis.Magnitude > 1e-3 then
				local angle = math.acos(clamp(bodyUp:Dot(target), -1, 1))
				torque += axis.Unit * angle * AIR_RIGHTING * (inertia.X + inertia.Z) / 2
			end
		end
	else
		-- Balance: the lean the turn is actually asking for, led a little by the steering input.
		local blend = clamp(dt * (grounded and 10 or 2), 0, 1)
		local wantUp = groundUp
		if not grounded then
			local below = cast(rig, chassis.Position, V(0, -40, 0))
			wantUp = (below and below.Normal.Y > 0.6) and below.Normal or UP
		end
		if groundedCount >= 2 then
			-- Pitch from the line between the tyres, which a bump shows before the normals do.
			local front, back
			for _, wheel in ipairs(wheels) do
				if wheel.front then
					front = wheel.contactPoint
				else
					back = wheel.contactPoint
				end
			end
			if front and back and (front - back).Magnitude > 0.5 then
				local along = (front - back).Unit
				local side = along:Cross(groundUp)
				if side.Magnitude > 0.1 then
					wantUp = side.Unit:Cross(along).Unit
				end
			end
		end
		rig.groundUp = rig.groundUp:Lerp(wantUp, blend).Unit

		local yawRate = angular:Dot(rig.groundUp)
		local turnLean = -math.atan2(forwardSpeed * yawRate, gravity)
		local lead = steerInput * rad(h.lean) * 0.25 * clamp(math.abs(forwardSpeed) / 25, 0, 1)
		local target = clamp(turnLean + lead, -rad(h.lean), rad(h.lean))
		if math.abs(forwardSpeed) < 3 then
			-- A stand only holds a bike up on the level; on a slope it leans it over instead.
			target = (input.parked and rig.groundUp.Y > 0.995) and KICKSTAND or 0
		end
		rig.lean += (target - rig.lean) * clamp(h.leanRate * dt, 0, 1)

		local flatForward = project(bodyForward, rig.groundUp)
		if flatForward.Magnitude > 0.05 then
			flatForward = flatForward.Unit
			local targetUp = CFrame.fromAxisAngle(flatForward, rig.lean):VectorToWorldSpace(rig.groundUp)
			rig.balance.CFrame = CFrame.fromMatrix(Vector3.zero, targetUp, flatForward)
		end
		rig.balance.MaxTorque = mass * BALANCE_TORQUE

		-- Oliver: "the bikes fall over when you drive them". The tyre forces go in at the hubs, about
		-- a stud below the chassis's centre of mass, and a bike's body is a stud wide, so it has next
		-- to no roll inertia to resist them. The first frame of a turn, before the lean has caught up,
		-- the sideways grip at the hubs is a roll torque many times what the Balance constraint holds
		-- at a sensible angle, and it rolled the bike OUT of the turn and onto its side in about a
		-- tenth of a second (tools/bike_balance_sim.py: every bike, every turn). On a real bike the
		-- rider's countersteer puts the lean in first; here the lean is the constraint's job alone,
		-- so the part of the tyre forces that would roll the body is taken back out and the Balance
		-- is left to set the lean on its own. Pitch (squat, dive, bumps) is left as it is. The
		-- chassis is the only part of a vehicle with mass (VehicleModels' Builder:hull, and riders
		-- are made Massless), so its position is the centre of mass.
		local roll = 0
		for _, wheel in ipairs(wheels) do
			local arm = frame:PointToWorldSpace(wheel.mount) - chassis.Position
			roll += arm:Cross(wheel.force.Force):Dot(bodyForward)
		end
		torque -= bodyForward * roll
	end

	rig.torque.Torque = torque

	-- Stopped means stopped. Tyre grip alone let a bike left across a 20-degree slope walk 20 studs
	-- downhill in six seconds, and a scooter coasting to a halt crawl at a stud a second for as long
	-- as anyone watched. Both read as bugs however well the friction circle is argued, so when a
	-- vehicle is parked, or its driver is off the throttle and it is already almost stopped, the last
	-- of the drift is taken out of the velocity itself. The thresholds are low enough that a blast
	-- (which arrives as tens of studs a second) still throws it properly.
	if grounded and (input.parked or hold) and speed < (input.parked and PARKED_STILL or HOLD_SPEED) then
		local v = chassis.AssemblyLinearVelocity
		if input.parked then
			-- Parked is parked: the drift goes entirely, not by degrees. Damping it only reaches a
			-- terminal speed -- on a 20-degree slope that was still 13 studs in six seconds, because
			-- gravity puts back each frame what the damper takes out.
			-- Sideways and along only: the vertical axis is left to the springs, which are still
			-- holding it up.
			chassis.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
			chassis.AssemblyAngularVelocity = Vector3.zero
		else
			local shed = clamp(PARKED_HOLD * dt, 0, 1)
			chassis.AssemblyLinearVelocity = Vector3.new(v.X * (1 - shed), v.Y, v.Z * (1 - shed))
			chassis.AssemblyAngularVelocity = chassis.AssemblyAngularVelocity * (1 - shed)
		end
	end

	-- Flip detection, for the owner to act on.
	if bodyUp.Y < FLIP_UP_DOT and speed < 8 then
		rig.flippedFor += dt
	else
		rig.flippedFor = 0
	end
	-- Wall clock: os.clock() is process CPU time in Roblox and barely advances while a frame is
	-- mostly waiting on the engine, which would make a stale step read as "fresh" for longer than
	-- the 0.05s AnimateWheels below actually intends.
	rig.steppedAt = tick()

	local telemetry = {
		speed = speed,
		forwardSpeed = forwardSpeed,
		grounded = groundedCount,
		steer = rig.steerAngle,
		lean = leanNow,
		slip = anySlip,
		flippedFor = rig.flippedFor,
	}
	if VehicleDynamics.Debug then
		local net = Vector3.zero
		for _, wheel in ipairs(wheels) do
			net += wheel.force.Force
		end
		telemetry.netForward = net:Dot(bodyForward) / mass
		local lines = {}
		for _, wheel in ipairs(wheels) do
			table.insert(lines, string.format("%s c%.2f L%.0f lat%.0f lon%.0f vs%.1f", wheel.name, wheel.compression, wheel.load / wheelMass,
				(wheel.lateral or 0) / wheelMass, (wheel.long or 0) / wheelMass, wheel.lateralSpeed or 0))
		end
		-- Speed along the heading against speed over the ground: if only the second is climbing, the
		-- vehicle is sliding wider, not gaining energy.
		telemetry.debug = string.format("m%.1f up%.2f h%.2f net%.0f fwd%.1f grd%.1f slip%.0f | %s", mass, bodyUp.Y,
			chassis.Position.Y, telemetry.netForward, forwardSpeed, Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
			math.deg(math.atan2(velocity:Dot(bodyRight), math.max(math.abs(forwardSpeed), 0.01))),
			table.concat(lines, " | "))
	end
	return telemetry
end

-- Puts a flipped vehicle back on its wheels where it is, keeping its heading.
function VehicleDynamics.Right(rig)
	local chassis = rig.chassis
	local look = chassis.CFrame.LookVector
	local flat = V(look.X, 0, look.Z)
	flat = flat.Magnitude > 0.05 and flat.Unit or V(0, 0, -1)
	local pivot = rig.model:GetPivot()
	local hit = cast(rig, pivot.Position + V(0, 8, 0), V(0, -20, 0))
	local at = (hit and hit.Position or pivot.Position) + V(0, 0.6, 0)
	rig.model:PivotTo(CFrame.lookAt(at, at + flat))
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	rig.flippedFor = 0
	rig.lean = 0
	rig.groundUp = UP
end

-- Wheel visuals for any client: bob, steer and spin through each hub's Motor6D.Transform, which
-- stays on the machine that sets it. Where this machine stepped the rig this frame the step's own
-- compression is used; otherwise a ray finds the ground, so a watcher sees wheels on the road
-- without the driver sending anything.
function VehicleDynamics.AnimateWheels(rig, dt, steerAngle)
	local chassis = rig.chassis
	local h = rig.handling
	local frame = chassis.CFrame
	local travel = h.travelUp + h.travelDown
	local fresh = rig.steppedAt and tick() - rig.steppedAt < 0.05
	local castUp = frame.UpVector
	if rig.bike then
		local leanNow = math.asin(clamp(-frame.RightVector.Y, -1, 1))
		castUp = CFrame.fromAxisAngle(frame.LookVector, -leanNow):VectorToWorldSpace(frame.UpVector)
	end
	for _, wheel in ipairs(rig.wheels) do
		local compression
		if fresh then
			compression = wheel.grounded and wheel.compression or 0
		else
			local top = frame:PointToWorldSpace(wheel.mount) + castUp * h.travelUp
			local hit = cast(rig, top, -castUp * (travel + wheel.radius))
			compression = hit and clamp(travel - (hit.Distance - wheel.radius), 0, travel) or 0
		end
		local offset = clamp(compression - h.travelDown, -h.travelDown, h.travelUp)
		wheel.visualOffset += (offset - wheel.visualOffset) * clamp(dt * 20, 0, 1)

		local steer = wheel.steer and -rad(steerAngle or rig.steerAngle or 0) or 0
		-- A wheel rolls along the way it points, so a steered one on full lock spins at its own rate,
		-- not the body's.
		local heading = steer ~= 0 and (frame * CFrame.Angles(0, steer, 0)).LookVector or frame.LookVector
		local rolling = chassis:GetVelocityAtPosition(frame:PointToWorldSpace(wheel.mount)):Dot(heading)
		wheel.spin = (wheel.spin - rolling / wheel.radius * dt) % (2 * math.pi)

		local hubTransform = CFrame.Angles(wheel.spin, 0, 0)
		if wheel.steerJoint then
			wheel.steerJoint.Transform = CFrame.Angles(0, steer, 0)
		else
			hubTransform = CFrame.Angles(0, steer, 0) * hubTransform
		end
		if wheel.sliderJoint then
			wheel.sliderJoint.Transform = CFrame.new(0, wheel.visualOffset / wheel.sliderUp, 0)
		elseif wheel.swingJoint then
			wheel.swingJoint.Transform = CFrame.Angles(-math.asin(clamp(wheel.visualOffset / wheel.swingArm, -0.9, 0.9)), 0, 0)
		else
			hubTransform = CFrame.new(0, wheel.visualOffset, 0) * hubTransform
		end
		wheel.joint.Transform = hubTransform
	end
	for _, entry in ipairs(rig.steerWheels) do
		entry.joint.Transform = CFrame.Angles(0, 0, -rad(steerAngle or rig.steerAngle or 0) * entry.ratio)
	end
end

return VehicleDynamics
