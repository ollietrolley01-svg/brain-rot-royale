-- Roadkill at speed keeps the vehicle's momentum (Oliver 09-24: "make vehicles keep their momentum
-- when they do a roadkill").
--
-- Before this, a body in a vehicle's way was a solid part like any other. The machine that simulates
-- the vehicle (the driver's client for a player's car, the server for a bot's or an empty one) sees
-- someone else's character as a body it cannot shove (its owner keeps putting it back), so the car
-- stopped dead on it or ploughed on with the body dragged in front; a corpse on the road did the same;
-- and the sudden loss of speed was also scored as a crash on the car (VehicleService's
-- checkCollisionDamage).
--
-- Now, on whichever machine simulates the vehicle, every physics step BEFORE the simulation runs
-- (VehicleClient's drive loop, VehicleService's step):
--   * over FLOOR (VehicleService's roadkill floor), every body the vehicle's colliders are about to
--     reach this step -- or already touch -- is let through: NoCollisionConstraints between the body's
--     parts and this vehicle's colliders AND its riders' solid parts (a body let through the hull would
--     otherwise meet the driver inside it: measured, that alone cost a car 20-28% of its speed), for
--     PASS_SECONDS and after that until the body is clear.
--   * a live body costs the vehicle Toll of its flat speed (a few percent; less for the heavy ones),
--     its heading, vertical speed and spin untouched, and is reported as a hit (the server's roadkill:
--     damage, credit, the throw along the direction of travel).
--   * a dead one (a ragdoll) is let through for nothing: bodies are not speed bumps.
--   * at or under FLOOR nothing changes: the body collides as it always did, so you can nudge someone
--     with a car without hurting them.
-- The server lets the body through as well when it accepts a hit (its constraints reach every
-- machine, the victim's own included).

local RoadkillPass = {}
RoadkillPass.__index = RoadkillPass

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VehicleArmor = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VehicleArmor"))

-- studs/s of flat speed; VehicleService's ROADKILL_FLOOR is this number (roadkill_check holds them equal).
RoadkillPass.FLOOR = 12
-- How long a body stays let through, at least; after it, until it is clear of the vehicle.
RoadkillPass.PASS_SECONDS = 1.5
-- A body is let through at the most this long however long it stays alongside.
RoadkillPass.PASS_MAX = 6
-- How far ahead the look reaches, in steps of the vehicle's travel, and the margin all round (studs):
-- enough that a body this step's travel reaches is let through before the contact, not after it.
RoadkillPass.LEAD_STEPS = 2.5
RoadkillPass.MARGIN = 0.6
-- The share of its flat speed a vehicle gives up to a body: a person is a few percent of a car's
-- weight, next to nothing to an armoured car's, and a real share of a bike's.
RoadkillPass.Tolls = { bike = 0.04, car = 0.025, armored = 0.01 }

function RoadkillPass.Toll(modelId, kind)
	local armor = VehicleArmor.Models[modelId]
	if armor and armor.cabin == "armored" then
		return RoadkillPass.Tolls.armored
	end
	return kind == "bike" and RoadkillPass.Tolls.bike or RoadkillPass.Tolls.car
end

-- The vehicle's velocity once it has gone through a body: the flat part short by `toll`, the vertical
-- as it was (the heading is the flat part's direction, which a scale leaves alone).
function RoadkillPass.After(velocity, toll)
	local keep = 1 - toll
	return Vector3.new(velocity.X * keep, velocity.Y, velocity.Z * keep)
end

-- Where a body goes when a vehicle doing `velocity` hits it: on along the direction of travel, off
-- to the side it was standing on (`offset`, from the vehicle's middle to the body), and up -- over the
-- bonnet and off the side, out of the vehicle's path, rather than on ahead of it to be run down again.
-- MovementClient caps a "blast" at 60 studs/s flat.
function RoadkillPass.Throw(velocity, offset)
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	if speed < 1e-3 then
		return Vector3.new(0, 14, 0)
	end
	local along = flat / speed
	local side = Vector3.new(-along.Z, 0, along.X)
	local sign = (offset and offset.X * side.X + offset.Z * side.Z < 0) and -1 or 1
	local forward = math.min(speed * 0.6, 40)
	local lateral = math.min(speed * 0.45, 26)
	local up = math.clamp(14 + speed * 0.35, 16, 40)
	return along * forward + side * (sign * lateral) + Vector3.new(0, up, 0)
end

-- The body a part belongs to (a model with a Humanoid), or nil.
function RoadkillPass.BodyOf(part)
	local model = part and part:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return model, humanoid
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- One vehicle's state. `onHit(character, speed, velocity)` is told of each live body it goes through:
-- the flat speed and the velocity it had before the toll.
function RoadkillPass.new(model, chassis, onHit)
	local self = setmetatable({}, RoadkillPass)
	self.model = model
	self.chassis = chassis
	self.onHit = onHit
	self.passed = {}
	self.colliders = {}
	self.seats = {}
	local reach = 0
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("Seat") or part:IsA("VehicleSeat") then
			table.insert(self.seats, part)
		elseif part:IsA("BasePart") and part.CanCollide then
			table.insert(self.colliders, part)
			reach = math.max(reach, (part.Position - chassis.Position).Magnitude + part.Size.Magnitude / 2)
		end
	end
	self.reach = reach + 3
	self.toll = RoadkillPass.Toll(model:GetAttribute("VehicleModel"), model:GetAttribute("VehicleKind"))
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = false
	self.params = params
	self.lastVelocity = nil
	self.lastSpin = nil
	return self
end

function RoadkillPass:isRider(humanoid)
	for _, seat in ipairs(self.seats) do
		if seat.Occupant == humanoid then
			return true
		end
	end
	return false
end

-- Whether `humanoid` sits inside an armoured cabin (VehicleArmor.Protects; a wreck covers nobody, as
-- VehicleCover.SeatOf says): Oliver 09-25, a car that rams one meets the hull, never its riders, so the
-- sweep neither lets them through nor reports them. VehicleService's roadkill refuses them by the same rule.
function RoadkillPass.Sheltered(humanoid)
	local seat = humanoid and humanoid.SeatPart
	local model = seat and seat.Parent
	if not model or model:GetAttribute("Wrecked") then
		return false
	end
	return VehicleArmor.Protects(model:GetAttribute("VehicleModel"), seat.Name)
end

-- Lets `character` through this vehicle (both ways: every limb against every collider and every
-- rider's solid part). Returns true the first time; again while it is through, only the time is extended.
function RoadkillPass:Pass(character, now)
	local pass = self.passed[character]
	if pass then
		pass.untilTime = math.max(pass.untilTime, now + RoadkillPass.PASS_SECONDS)
		return false
	end
	local mine = {}
	for _, collider in ipairs(self.colliders) do
		table.insert(mine, collider)
	end
	for _, seat in ipairs(self.seats) do
		local occupant = seat.Occupant
		local rider = occupant and occupant.Parent
		if rider and rider ~= character then
			for _, part in ipairs(rider:GetChildren()) do
				if part:IsA("BasePart") and part.CanCollide then
					table.insert(mine, part)
				end
			end
		end
	end
	local constraints = {}
	for _, part in ipairs(character:GetChildren()) do
		if part:IsA("BasePart") then
			for _, collider in ipairs(mine) do
				local constraint = Instance.new("NoCollisionConstraint")
				constraint.Name = "RoadkillPass"
				constraint.Part0 = collider
				constraint.Part1 = part
				constraint.Parent = self.chassis
				table.insert(constraints, constraint)
			end
		end
	end
	self.passed[character] = { since = now, untilTime = now + RoadkillPass.PASS_SECONDS, constraints = constraints }
	return true
end

local function release(pass)
	for _, constraint in ipairs(pass.constraints) do
		constraint:Destroy()
	end
end

-- Collisions back on for every body whose time is up and that is clear of the vehicle.
function RoadkillPass:expire(now)
	for character, pass in pairs(self.passed) do
		local done = character.Parent == nil or now - pass.since > RoadkillPass.PASS_MAX
		if not done and now >= pass.untilTime then
			local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			done = root == nil or (root.Position - self.chassis.Position).Magnitude > self.reach
		end
		if done then
			release(pass)
			self.passed[character] = nil
		end
	end
end

-- The bodies within the look-ahead of the colliders this step: { [character] = humanoid }.
function RoadkillPass:bodiesAhead(velocity, dt)
	local filter = { self.model }
	for _, seat in ipairs(self.seats) do
		local occupant = seat.Occupant
		if occupant and occupant.Parent then
			table.insert(filter, occupant.Parent)
		end
	end
	self.params.FilterDescendantsInstances = filter
	local lead = velocity * (dt * RoadkillPass.LEAD_STEPS)
	local margin = RoadkillPass.MARGIN * 2
	local found = {}
	for _, collider in ipairs(self.colliders) do
		if collider.Parent then
			local frame = collider.CFrame
			local localLead = frame:VectorToObjectSpace(lead)
			local size = collider.Size + Vector3.new(math.abs(localLead.X) + margin, math.abs(localLead.Y) + margin,
				math.abs(localLead.Z) + margin)
			for _, part in ipairs(workspace:GetPartBoundsInBox(frame + lead / 2, size, self.params)) do
				local character, humanoid = RoadkillPass.BodyOf(part)
				if character and not found[character] and not self:isRider(humanoid)
					and not RoadkillPass.Sheltered(humanoid) then
					found[character] = humanoid
				end
			end
		end
	end
	return found
end

-- The step: call before the physics simulates it. Returns how many live bodies it went through.
function RoadkillPass:Sweep(dt, now)
	local chassis = self.chassis
	self:expire(now)
	local velocity = chassis.AssemblyLinearVelocity
	local spin = chassis.AssemblyAngularVelocity
	local lastVelocity, lastSpin = self.lastVelocity, self.lastSpin
	self.lastVelocity, self.lastSpin = velocity, spin
	local flat = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if flat <= RoadkillPass.FLOOR then
		return 0
	end
	local hits = 0
	for character, humanoid in pairs(self:bodiesAhead(velocity, dt)) do
		if self:Pass(character, now) and humanoid.Health > 0 then
			hits += 1
			-- A body that came in from the side already touched last step: what that cost is given back.
			local lastFlat = lastVelocity and Vector3.new(lastVelocity.X, 0, lastVelocity.Z).Magnitude or 0
			if lastFlat > flat + 1 then
				velocity, spin = lastVelocity, lastSpin
				flat = lastFlat
			end
			if self.onHit then
				self.onHit(character, flat, velocity)
			end
			velocity = RoadkillPass.After(velocity, self.toll)
			flat = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		end
	end
	if hits > 0 then
		chassis.AssemblyLinearVelocity = velocity
		chassis.AssemblyAngularVelocity = spin
		self.lastVelocity, self.lastSpin = velocity, spin
	end
	return hits
end

function RoadkillPass:Destroy()
	for character, pass in pairs(self.passed) do
		release(pass)
		self.passed[character] = nil
	end
end

return RoadkillPass
