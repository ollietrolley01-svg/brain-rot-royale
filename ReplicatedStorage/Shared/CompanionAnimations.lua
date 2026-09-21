-- Companion animation: procedural poses for the part-built brainrots that follow players.
--
-- A companion built with `BrainrotModels.Build(def, { rig = true })` has its parts welded to a few
-- invisible pivots: Body, and on it Head (for stacked bodies), ArmL/ArmR, WingL/WingR, Tail and
-- FootL/FootR, each joined to its parent by a Motor6D named after its group. Motor6D.Transform is
-- local to each machine and never replicates, the same as a character's Animator, so every client
-- poses every nearby companion itself (bots' ones, simulated by the server, included) while the
-- server keeps the rest pose for hit detection.
--
-- Everything here is a pure function of time, so the gallery can render a clip mid-swing on an
-- anchored build and the probe can check clip timing without a client.
--
--   CompanionAnimations.Rig(model)                 -> rig, or nil if the model isn't rigged
--   CompanionAnimations.Idle(rig, now)             -> pose parameters
--   CompanionAnimations.Layer(pose, rig, clip, t)  -> adds a clip at time t onto a pose
--   CompanionAnimations.Transforms(pose)           -> { group = CFrame } joint transforms
--   CompanionAnimations.Apply(rig, pose)           -> sets the joints' Transforms
--   CompanionAnimations.Duration(kind, travel)     -> how long a clip runs
--
-- A clip is { kind = "Spit" | "Bonk" | "Zap" | "Chain" | "Lob" | "Shockwave" | "Cheer",
-- start = os.clock(), target = Vector3 (the target in the root's space, from the Body pivot),
-- travel = seconds }. Attacks connect `Windup` seconds in (the server delays the damage by the same
-- amount), so the strike, the beam or the launch always lines up with the hit.

local CompanionAnimations = {}

CompanionAnimations.Windup = 0.15
local WINDUP = CompanionAnimations.Windup

-- Stacked bodies nod their top half on its own; the neck height is where it splits.
CompanionAnimations.Neck = { Pear = 0.3, Stack = 0.2, Totem = -0.16 }

-- How each body moves. hop scales jumps, tilt scales leans; tumble bodies flip rigidly through
-- the air, spinners turn on the spot instead of jumping, floaters swoop and bob more.
local STYLES = {
	Blob = { hop = 1.0, tilt = 1.0 },
	Bean = { hop = 1.1, tilt = 1.1 },
	Cube = { hop = 0.8, tilt = 0.45, tumble = true },
	Pear = { hop = 0.9, tilt = 1.2 },
	Disc = { hop = 0.5, tilt = 0.5, spinner = true },
	Stack = { hop = 1.0, tilt = 1.15 },
	Egg = { hop = 0.9, tilt = 1.35, wobble = true },
	Mushroom = { hop = 1.2, tilt = 0.8 },
	Cloud = { hop = 0.6, tilt = 0.6, spinner = true, floats = true },
	Can = { hop = 0.7, tilt = 0.5, tumble = true },
	Cone = { hop = 0.8, tilt = 1.0, wobble = true },
	Ghost = { hop = 0.6, tilt = 0.8, spinner = true, floats = true },
	Loaf = { hop = 0.6, tilt = 0.4, tumble = true },
	Totem = { hop = 0.7, tilt = 0.9 },
}
CompanionAnimations.Styles = STYLES

local function clamp01(x)
	return math.clamp(x, 0, 1)
end

local function smooth(x)
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

-- 0 before a, 1 after b, linear between.
local function span(t, a, b)
	return clamp01((t - a) / (b - a))
end

-- A sine bump: 0 at a, 1 halfway, 0 at b.
local function bump(t, a, b)
	if t <= a or t >= b then
		return 0
	end
	return math.sin(math.pi * (t - a) / (b - a))
end

function CompanionAnimations.Blank()
	return {
		x = 0, y = 0, z = 0, yaw = 0, spin = 0, pitch = 0, roll = 0,
		swingL = 0, swingR = 0, raiseL = 0, raiseR = 0,
		flap = 0, sweep = 0, wag = 0, lift = 0, nod = 0, turn = 0, stepL = 0, stepR = 0,
	}
end

function CompanionAnimations.Duration(kind, travel)
	travel = travel or 0.35
	if kind == "Spit" then
		return 0.6
	elseif kind == "Zap" then
		return 0.55
	elseif kind == "Chain" then
		return 0.7
	elseif kind == "Lob" then
		return 0.72
	elseif kind == "Shockwave" then
		return 0.8
	elseif kind == "Bonk" then
		return WINDUP + travel + 0.55
	elseif kind == "Cheer" then
		return 0.45
	end
	return 0.5
end

-- Moves the body `amount` along the way it's facing.
local function forward(pose, amount)
	pose.x -= math.sin(pose.yaw) * amount
	pose.z -= math.cos(pose.yaw) * amount
end

local CLIPS = {}

CLIPS.Spit = function(pose, style, t, s)
	local rear = bump(t, 0, WINDUP + 0.03)
	local snap = bump(t, WINDUP - 0.03, WINDUP + 0.24)
	pose.pitch += (0.38 * rear - 0.5 * snap) * style.tilt
	pose.y += 0.14 * rear * style.hop * s
	forward(pose, 0.4 * snap * s)
	pose.swingL += -0.4 * rear + 0.9 * snap
	pose.swingR += -0.4 * rear + 0.9 * snap
	pose.nod += -0.35 * rear + 0.5 * snap
	pose.flap += 0.6 * snap
	pose.lift += 0.4 * snap
end

CLIPS.Zap = function(pose, style, t, s)
	local charge = smooth(span(t, 0, WINDUP)) * (1 - span(t, WINDUP, WINDUP + 0.04))
	local recoil = bump(t, WINDUP, WINDUP + 0.32)
	pose.x += math.sin(t * 90) * 0.05 * charge * s
	pose.y += 0.12 * charge * s
	forward(pose, -0.45 * recoil * s)
	pose.pitch += 0.28 * recoil * style.tilt
	local point = smooth(span(t, 0, WINDUP)) * (1 - smooth(span(t, WINDUP + 0.2, 0.55)))
	pose.swingR += 1.45 * point
	pose.swingL += 0.5 * point
	pose.nod += 0.2 * recoil
	pose.flap += 0.8 * charge
end

CLIPS.Chain = function(pose, style, t, s)
	CLIPS.Zap(pose, style, t, s)
	pose.spin += math.pi * 2 * smooth(span(t, WINDUP, WINDUP + 0.45))
	pose.raiseL += 0.9 * bump(t, WINDUP, WINDUP + 0.45)
	pose.raiseR += 0.9 * bump(t, WINDUP, WINDUP + 0.45)
end

CLIPS.Lob = function(pose, style, t, s)
	local wind = smooth(span(t, 0, WINDUP)) * (1 - smooth(span(t, WINDUP, WINDUP + 0.1)))
	local toss = bump(t, WINDUP, WINDUP + 0.32)
	pose.pitch += (0.42 * wind - 0.38 * toss) * style.tilt
	pose.y += (0.36 * toss * style.hop - 0.08 * wind) * s
	pose.swingL += 2.6 * wind + 1.1 * toss
	pose.swingR += 2.6 * wind + 1.1 * toss
	pose.nod += -0.3 * wind + 0.35 * toss
	pose.flap += 0.7 * toss
end

CLIPS.Shockwave = function(pose, style, t, s)
	local slam = bump(t, WINDUP, WINDUP + 0.18)
	if style.spinner then
		pose.spin += math.pi * 2 * smooth(span(t, 0, WINDUP + 0.22))
		pose.y += (0.4 * bump(t, 0, WINDUP) - 0.12 * slam) * s
	else
		-- Up fast, down faster, landing on the windup.
		local rise = t < WINDUP * 0.65 and math.sin(span(t, 0, WINDUP * 0.65) * math.pi / 2)
			or 1 - span(t, WINDUP * 0.65, WINDUP) ^ 2
		if t >= WINDUP then
			rise = 0
		end
		pose.y += (0.95 * rise * style.hop - 0.2 * slam) * s
		pose.pitch += (style.tumble and 0.25 or -0.1) * slam * style.tilt
	end
	local up = t < WINDUP and smooth(span(t, 0, WINDUP * 0.6)) or 1 - smooth(span(t, WINDUP, WINDUP + 0.1))
	pose.raiseL += 1.6 * up
	pose.raiseR += 1.6 * up
	pose.flap += 1.0 * up
	pose.stepL += 0.25 * slam * s
	pose.stepR += 0.25 * slam * s
	pose.roll += math.sin(t * 40) * 0.06 * slam
end

CLIPS.Bonk = function(pose, style, t, s, clip)
	local target = clip.target or Vector3.new(0, 0, -6)
	local travel = clip.travel or 0.35
	local crouch = bump(t, 0, WINDUP + 0.03)
	pose.y -= 0.2 * crouch * s
	pose.pitch += 0.28 * crouch * style.tilt
	pose.swingL += 2.2 * crouch
	pose.swingR += 2.2 * crouch

	local land = WINDUP + travel
	local horizontal = Vector3.new(target.X, 0, target.Z).Magnitude
	local arc = 1.5 + horizontal * 0.12
	if t >= WINDUP and t < land then
		local a = span(t, WINDUP, land)
		local at = target * a
		pose.x += at.X
		pose.y += at.Y + arc * 4 * a * (1 - a)
		pose.z += at.Z
		if style.tumble then
			pose.pitch -= math.pi * 2 * a
		else
			pose.pitch -= 0.55 * bump(a, 0, 1) * style.tilt
		end
		pose.swingL += 2.4
		pose.swingR += 2.4
		pose.flap += math.sin(a * math.pi * 6) * 0.8
	elseif t >= land and t < land + 0.12 then
		local dip = bump(t, land, land + 0.12)
		pose.x += target.X
		pose.y += target.Y - 0.25 * dip * s
		pose.z += target.Z
		pose.swingL += 2.4 * (1 - dip)
		pose.swingR += 2.4 * (1 - dip)
		pose.roll += math.sin(t * 60) * 0.1 * dip
	elseif t >= land + 0.12 then
		local b = smooth(span(t, land + 0.12, land + 0.52))
		local at = target * (1 - b)
		pose.x += at.X
		pose.y += at.Y + arc * 0.3 * 4 * b * (1 - b)
		pose.z += at.Z
	end
end

CLIPS.Cheer = function(pose, style, t, s)
	local hop = bump(t, 0, 0.45)
	pose.y += 0.32 * hop * style.hop * s
	pose.roll += math.sin(t * 28) * 0.12 * hop
	pose.raiseL += 1.1 * hop
	pose.raiseR += 1.1 * hop
	pose.flap += 0.9 * hop
	pose.wag += math.sin(t * 30) * 0.5 * hop
end

-- Where the clip wants the creature to face: toward its target, blended in at the start and out
-- at the end so it turns rather than snaps.
local function facing(clip, t, duration)
	local target = clip.target
	if not target or Vector3.new(target.X, 0, target.Z).Magnitude < 0.5 then
		return 0
	end
	local yaw = math.atan2(-target.X, -target.Z)
	local weight = smooth(span(t, 0, 0.08)) * (1 - smooth(span(t, duration - 0.18, duration)))
	return yaw * weight
end

-- Adds `clip` at `t` seconds into it onto `pose`. Returns false once the clip has finished.
function CompanionAnimations.Layer(pose, body, clip, t, scale)
	local fn = CLIPS[clip.kind]
	local duration = CompanionAnimations.Duration(clip.kind, clip.travel)
	if not fn or t < 0 or t > duration then
		return false
	end
	local style = STYLES[body] or STYLES.Blob
	-- Facing turns the body about its base; a Bonk's leap is a translation in the root's frame,
	-- which the turn doesn't rotate, so it faces its target and still lands on it.
	pose.yaw += facing(clip, t, duration)
	fn(pose, style, t, scale or 1, clip)
	return true
end

-- Always-on life: a breathing bob and sway, arms swinging a little, wings fluttering, tail
-- wagging. `seed` keeps a crowd of companions out of step with each other.
function CompanionAnimations.IdlePose(body, now, seed, scale, into)
	local style = STYLES[body] or STYLES.Blob
	local s = scale or 1
	local t = now + (seed or 0)
	local pose = into or CompanionAnimations.Blank()
	if into then
		for key in pairs(pose) do
			pose[key] = 0
		end
	end
	pose.y = math.sin(t * 2.1) * (style.floats and 0.1 or 0.05) * s
	pose.roll = math.sin(t * 1.3) * (style.wobble and 0.07 or 0.035)
	pose.pitch = math.sin(t * 1.7) * 0.025
	pose.swingL = math.sin(t * 2.1) * 0.14
	pose.swingR = -math.sin(t * 2.1) * 0.14
	pose.raiseL = 0.06 + math.sin(t * 1.6) * 0.04
	pose.raiseR = 0.06 + math.sin(t * 1.6 + 0.8) * 0.04
	pose.flap = math.sin(t * (style.floats and 9 or 6.5)) * 0.3
	pose.wag = math.sin(t * 3.2) * 0.35
	pose.nod = math.sin(t * 1.9) * 0.06
	return pose
end

local JOINT_NAMES = { "Body", "Head", "ArmR", "ArmL", "WingR", "WingL", "Tail", "FootR", "FootL" }

-- One joint's transform from the pose.
local function transformFor(name, pose)
	if name == "Body" then
		return CFrame.new(pose.x, pose.y, pose.z) * CFrame.Angles(0, pose.yaw + pose.spin, 0) * CFrame.Angles(pose.pitch, 0, pose.roll)
	elseif name == "Head" then
		return CFrame.Angles(pose.nod, pose.turn, 0)
	elseif name == "ArmR" then
		return CFrame.Angles(pose.swingR, 0, pose.raiseR)
	elseif name == "ArmL" then
		return CFrame.Angles(pose.swingL, 0, -pose.raiseL)
	elseif name == "WingR" then
		return CFrame.Angles(0, pose.sweep, pose.flap)
	elseif name == "WingL" then
		return CFrame.Angles(0, -pose.sweep, -pose.flap)
	elseif name == "Tail" then
		return CFrame.Angles(pose.lift, pose.wag, 0)
	elseif name == "FootR" then
		return CFrame.new(0, pose.stepR, 0)
	elseif name == "FootL" then
		return CFrame.new(0, pose.stepL, 0)
	end
	return nil
end

function CompanionAnimations.Transforms(pose)
	local transforms = {}
	for _, name in ipairs(JOINT_NAMES) do
		transforms[name] = transformFor(name, pose)
	end
	return transforms
end

-- A phase offset in [0, 2π) from every character of a name.
local function seedFor(name)
	local hash = 0
	for index = 1, #name do
		hash = (hash * 31 + string.byte(name, index)) % 100003
	end
	return hash / 100003 * math.pi * 2
end

-- The joints of a rigged companion, or nil.
function CompanionAnimations.Rig(model)
	local joints = {}
	local any = false
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") and string.sub(child.Name, 1, 5) == "Pivot" then
			local joint = child:FindFirstChildOfClass("Motor6D")
			if joint then
				joints[joint.Name] = joint
				any = true
			end
		end
	end
	if not any or not joints.Body then
		return nil
	end
	return {
		model = model,
		joints = joints,
		root = model.PrimaryPart or model:FindFirstChild("Root"),
		body = model:GetAttribute("RigBody") or "Blob",
		scale = model:GetAttribute("RigScale") or 1,
		seed = seedFor(model.Name),
	}
end

-- Fills and returns the rig's own pose table, so animating a crowd allocates nothing per frame.
function CompanionAnimations.Idle(rig, now)
	rig.pose = CompanionAnimations.IdlePose(rig.body, now, rig.seed, rig.scale, rig.pose)
	return rig.pose
end

-- Every joint back to its rest pose.
function CompanionAnimations.Rest(rig)
	for _, joint in pairs(rig.joints) do
		joint.Transform = CFrame.new()
	end
end

-- Every frame, for every rig in range: no table of transforms is built to be thrown away.
function CompanionAnimations.Apply(rig, pose)
	for name, joint in pairs(rig.joints) do
		local transform = transformFor(name, pose)
		if transform then
			joint.Transform = transform
		end
	end
end

return CompanionAnimations
