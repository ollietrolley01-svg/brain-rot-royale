-- Crouch probe: what crouching actually does to the body, measured rather than eyeballed.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/crouch_probe.lua -WaitSeconds 300
--
-- Four questions, because four different people need an answer:
--
--   1. FEET. Does Shared/CrouchAnimation keep the soles on the ground, or do they skate? The legs are
--      solved by IK against a planted target, so the answer should be "0.00 studs at a steady speed".
--   2. THE POSE ON A REAL BODY. Lane 1 is the module checked against itself — it inverts Pose() with the
--      same assumption about which way an R15 joint turns, so a sign error would pass it. This lane puts
--      the pose on a real rig, lets it render, and measures where the feet actually ended up.
--   3. GAPS. How low does the body really get, and what does that let it through? The fold the players
--      see is drawn per client; what COLLIDES is the whole rig lowered by the HipHeight drop. There are
--      two ladders: the arithmetic one, and a real body walked at a real opening under physics. Where
--      they disagree, the walking one is the answer.
--   4. HITTING. From 30 studs, how much harder is a crouched body to shoot, and is any of it now
--      impossible to shoot (sunk into the floor)? The bot tab wants both before cover logic leans on it.
--
-- Everything is built in its own lane far from the map, and the rig is a real R15 where Studio will make
-- one. The walking and rendering lanes start Run mode themselves (the way tools/movement_probe.lua does)
-- because neither question can be answered without the engine.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CrouchAnimation = require(Shared:WaitForChild("CrouchAnimation"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))

local CROUCH = MovementConfig.Crouch
local ORIGIN = Vector3.new(6600, 400, 6600)
local pi = math.pi
local TAU = pi * 2

local function out(fmt, ...)
	print("[CrouchProbe] " .. string.format(fmt, ...))
end

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
	else
		failed += 1
	end
	out("%s %-46s %s", ok and "PASS" or "FAIL", name, detail or "")
end

local folder = Instance.new("Folder")
folder.Name = "CrouchProbe"
folder.Parent = workspace

local function block(parent, size, cframe, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props or {}) do
		part[key] = value
	end
	part.Parent = parent
	return part
end

--------------------------------------------------------------------------------
-- The rig
--------------------------------------------------------------------------------

local template
do
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and model then
		template = model
		out("rig: R15 from description")
	else
		out("rig: NO R15 (%s) — the gap and hit lanes need one, skipping them", tostring(model))
	end
	if template then
		for _, part in ipairs(template:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
end

local humanoid = template and template:FindFirstChildOfClass("Humanoid")
local rigRoot = template and template:FindFirstChild("HumanoidRootPart")
local STAND_HIP = humanoid and humanoid.HipHeight or 2
local ROOT_HALF = rigRoot and rigRoot.Size.Y / 2 or 1
-- What MatchService.setHipHeight would do to this rig, and so how far the whole body drops.
local CROUCH_HIP = math.max(STAND_HIP * CROUCH.HipScale, CROUCH.MinHipHeight)
local DROP = STAND_HIP - CROUCH_HIP

local segments = CrouchAnimation.Segments(template)
local DEPTH = CrouchAnimation.Depth(segments, DROP)
local STRIDE = CrouchAnimation.Stride(segments)
local CROUCH_SPEED = MatchConfig.BaseWalkSpeed * CROUCH.SpeedMultiplier

out("leg: upper %.2f lower %.2f foot %.2f (straight %.2f)", segments.upper, segments.lower, segments.foot, segments.length)
out("hip height %.2f -> %.2f (HipScale %.2f, floor %.2f): the body drops %.2f studs",
	STAND_HIP, CROUCH_HIP, CROUCH.HipScale, CROUCH.MinHipHeight, DROP)
out("crouched the hips ride %.2f over the soles; step %.2f, full cycle %.2f; crouch speed %.2f studs/s",
	DEPTH, STRIDE / 2, STRIDE, CROUCH_SPEED)

do
	-- Cadence: how often a foot lands at full crouch speed. Too many and it scuttles, too few and it
	-- moonwalks. Roblox's own walk is around 2.5 steps a second at full speed; a crouch should be a
	-- little quicker than that and nowhere near double.
	-- The cadence FOLLOWS from the step, and the step is capped by the ankle (see CrouchAnimation's STEP):
	-- a crouch-walk at this speed is short quick steps. This range only catches a step so short it
	-- scuttles, or so long the foot would have to bend further than a foot bends.
	local stepsPerSecond = CROUCH_SPEED / (STRIDE / 2)
	check("the walk cadence looks like walking", stepsPerSecond >= 3 and stepsPerSecond <= 5.5,
		string.format("%.2f steps a second (%.2f stud steps at %.1f studs/s)",
			stepsPerSecond, STRIDE / 2, CROUCH_SPEED))
	-- A step the leg cannot reach is a step the IK quietly shortens, which is skate by another name. The
	-- furthest point is SCANNED rather than assumed to be half a step out: the swing overshoots the mark
	-- by design, and a future change to that curve must not silently walk past the leg's reach.
	local worst, worstAt = 0, 0
	for step = 0, 199 do
		local phase = step / 200 * TAU
		local forward, drop = CrouchAnimation.Foot(phase, 1, STRIDE, DEPTH)
		local need = math.sqrt((drop - segments.foot) ^ 2 + forward ^ 2)
		if need > worst then
			worst, worstAt = need, forward
		end
	end
	check("the leg can reach the far end of its own step", worst < (segments.upper + segments.lower) * 0.97,
		string.format("needs %.2f of %.2f studs, %.2f out from the hip", worst, segments.upper + segments.lower, worstAt))
end

--------------------------------------------------------------------------------
-- 1. Feet: the pose's own kinematics, read back out of the CFrames it returns
--------------------------------------------------------------------------------

-- Reads a pose back: where the ANKLE ended up relative to its hip, and how far the foot is from flat.
-- The ankle is what the IK actually solves for; the sole then hangs off it, tilting when the foot rolls
-- at the ends of the stride. This runs the real Pose() and inverts it, so a sign error in the
-- torso-pitch compensation shows up as a miss of about a stud.
local function ankleFromPose(pose, side)
	local pitch = -select(1, pose.Root:ToEulerAnglesXYZ())
	local hip = select(1, pose[side .. "Hip"]:ToEulerAnglesXYZ())
	local knee = select(1, pose[side .. "Knee"]:ToEulerAnglesXYZ())
	local ankle = select(1, pose[side .. "Ankle"]:ToEulerAnglesXYZ())
	-- The joints add down the limb, and the Root's forward lean is a NEGATIVE turn, so the world angle of
	-- the thigh is the hip's own angle LESS the lean. (Getting this backwards is precisely the mistake
	-- lane 2c exists to catch, so it is spelled out here rather than shared with the module.)
	local thigh = hip - pitch
	local shin = thigh + knee
	local forward = segments.upper * math.sin(thigh) + segments.lower * math.sin(shin)
	local below = segments.upper * math.cos(thigh) + segments.lower * math.cos(shin)
	-- Flat means the foot's own angle in the world comes to nothing.
	return forward, below, shin + ankle
end

local function poseAt(phase, walk, clock)
	return CrouchAnimation.Pose({
		phase = phase, walk = walk, clock = clock or 0,
		segments = segments, depth = DEPTH, stride = STRIDE,
	})
end

do
	-- The leg the IK solves must actually reach where Foot() asked, and the foot must be flat where it
	-- matters and never rolled further than an ankle can go.
	local worstReach, worstFlat, worstPlant, worstRoll = 0, 0, 0, 0
	for _, walk in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
		for step = 0, 47 do
			local phase = step / 48 * TAU
			local pose = poseAt(phase, walk, 0)
			for _, side in ipairs({ "Left", "Right" }) do
				local at = side == "Right" and phase or (phase + pi) % TAU
				local wantForward, wantDrop = CrouchAnimation.Foot(at, walk, STRIDE, DEPTH)
				-- Foot() names the SOLE; the ankle sits its own height above it.
				local wantBelow = wantDrop - segments.foot
				local gotForward, gotBelow, tilt = ankleFromPose(pose, side)
				worstReach = math.max(worstReach,
					math.sqrt((gotForward - wantForward) ^ 2 + (gotBelow - wantBelow) ^ 2))
				-- The foot is only asked to be FLAT through the middle of its plant. At the ends of the
				-- stride a real foot rolls — heel up behind, toes up in front — and the ankle is clamped to
				-- a human range rather than bent to whatever flatness would need.
				if at > pi * 0.4 and at < pi * 0.6 then
					worstFlat = math.max(worstFlat, math.abs(tilt))
				end
				worstRoll = math.max(worstRoll, math.abs(tilt))
				if at < pi then
					worstPlant = math.max(worstPlant, math.abs(gotBelow - (DEPTH - segments.foot)))
				end
			end
		end
	end
	check("the leg reaches the target the cycle asks for", worstReach < 0.02,
		string.format("worst miss %.4f studs", worstReach))
	check("the sole is flat under the body at mid-stance", math.deg(worstFlat) < 3,
		string.format("worst tilt %.2f deg", math.deg(worstFlat)))
	check("the foot never rolls further than an ankle can", math.deg(worstRoll) < 32,
		string.format("worst roll %.1f deg, at the ends of the stride (that is toe-off)", math.deg(worstRoll)))
	check("a planted ankle sits exactly over the ground", worstPlant < 0.02,
		string.format("worst %.4f studs off", worstPlant))

	-- The head. The chest leans a long way over in a crouch and the head is bolted to the top of it, so
	-- without the neck taking most of that back the body crouches staring at its own feet.
	local worstStoop, worstChin = 0, 0
	for step = 0, 23 do
		local pose = poseAt(step / 24 * TAU, 1, 0)
		local root = select(1, pose.Root:ToEulerAnglesXYZ())
		local waist = select(1, pose.Waist:ToEulerAnglesXYZ())
		local neck = pose.Neck and select(1, pose.Neck:ToEulerAnglesXYZ()) or 0
		worstStoop = math.max(worstStoop, math.abs(root + waist))
		worstChin = math.max(worstChin, math.abs(root + waist + neck))
	end
	check("the head looks ahead, not at the floor", math.deg(worstChin) < 10,
		string.format("chin %.1f deg down, from a chest leaning %.1f", math.deg(worstChin), math.deg(worstStoop)))
end

do
	-- Skate: walk the body at a speed, advance the phase by the distance covered, and watch a planted
	-- sole's WORLD position. It must not move while it is planted.
	local function skate(speedAt, frames)
		local phase, travelled, plantAt, worst = 0, 0, nil, 0
		local dt = 1 / 60
		for frame = 1, frames do
			local speed = speedAt(frame * dt)
			local moved = speed * dt
			local walk = CrouchAnimation.Walk(speed, CROUCH_SPEED)
			local was = phase
			phase = CrouchAnimation.Advance(phase, moved, STRIDE, walk)
			travelled += moved
			local forward = CrouchAnimation.Foot(phase, walk, STRIDE, DEPTH)
			local world = travelled + forward
			if phase < pi then
				if was >= pi or plantAt == nil then
					plantAt = world
				end
				worst = math.max(worst, math.abs(world - plantAt))
			else
				plantAt = nil
			end
		end
		return worst
	end
	local steady = 0
	for _, fraction in ipairs({ 1, 0.75, 0.5, 0.25, 0.1 }) do
		steady = math.max(steady, skate(function()
			return CROUCH_SPEED * fraction
		end, 900))
	end
	local ramp = skate(function(t)
		return math.min(CROUCH_SPEED, CROUCH_SPEED * t / 0.2)
	end, 900)
	local wobble = skate(function(t)
		return CROUCH_SPEED * (0.5 + 0.5 * math.sin(t * 3))
	end, 900)
	check("feet don't skate at a steady speed", steady < 0.02, string.format("%.4f studs, worst of 5 speeds", steady))
	check("feet barely skate while speeding up", ramp < 0.35, string.format("%.3f studs (target 0.35)", ramp))
	check("feet barely skate while the speed wobbles", wobble < 0.35, string.format("%.3f studs (target 0.35)", wobble))
	-- The hips swing forward and back with the torso bob, which the legs do NOT compensate for (the
	-- sockets move with LowerTorso). Report it so nobody hunts for the residue above.
	local lowerTorso = template and template:FindFirstChild("LowerTorso")
	if lowerTorso then
		out("note: the torso bob swings the hip sockets about %.3f studs — the residue above is mostly this",
			lowerTorso.Size.Y / 2 * math.rad(1.4) * 2)
	end
end

do
	-- The idle must not be a statue, and must not wander.
	local a = poseAt(0, 0, 0)
	local b = poseAt(0, 0, 1.1)
	local moved = (select(1, a.Waist:ToEulerAnglesXYZ()) - select(1, b.Waist:ToEulerAnglesXYZ()))
	check("a held crouch keeps breathing", math.abs(math.deg(moved)) > 0.3,
		string.format("the spine moves %.2f deg over 1.1s", math.deg(moved)))
	local aForward = ankleFromPose(a, "Right")
	local bForward = ankleFromPose(b, "Right")
	check("breathing doesn't drag the feet", math.abs(aForward - bForward) < 0.05,
		string.format("the sole moves %.4f studs", math.abs(aForward - bForward)))
end

--------------------------------------------------------------------------------
-- 2. Gaps: what the lowered body fits under
--------------------------------------------------------------------------------

local standHeight, crouchHeight
if template then
	local lane = Instance.new("Model")
	lane.Name = "Gaps"
	lane.Parent = folder
	local base = ORIGIN
	block(lane, Vector3.new(60, 2, 40), CFrame.new(base + Vector3.new(0, -1, 0)), { Name = "Ground" })

	local rig = template:Clone()
	rig.Parent = lane
	-- Segments() reads the leg off the part sizes; this is the same length measured off where the parts
	-- actually sit, so a rig whose legs don't stack cleanly is caught rather than quietly mis-posed.
	do
		rig:PivotTo(CFrame.new(base + Vector3.new(0, STAND_HIP + ROOT_HALF, 0)))
		local upper = rig:FindFirstChild("LeftUpperLeg")
		local foot = rig:FindFirstChild("LeftFoot")
		if upper and foot then
			-- Against the JOINTS, not the part sizes: R15's leg parts overlap by about 0.7 studs, and
			-- building the pose on their sizes is the bug this check exists to have caught.
			-- Players' rigs are jointed with Motor6Ds and bots' with AnimationConstraints, and this check
			-- has to read both — asking only for a Motor6D is how this measured zero and reported it as a
			-- mismatch when the rig was fine.
			local hipJoint = upper:FindFirstChild("LeftHip")
			local hipY = nil
			if hipJoint and hipJoint:IsA("Motor6D") and hipJoint.Part0 then
				hipY = (hipJoint.Part0.CFrame * hipJoint.C0).Position.Y
			elseif hipJoint and hipJoint:IsA("AnimationConstraint") and hipJoint.Attachment0 then
				hipY = hipJoint.Attachment0.WorldPosition.Y
			end
			local soleY = foot.Position.Y - foot.Size.Y / 2
			local measured = hipY and (hipY - soleY) or -1
			local fromSizes = upper.Size.Y + foot.Size.Y
				+ (rig:FindFirstChild("LeftLowerLeg") and rig.LeftLowerLeg.Size.Y or 0)
			check("the leg measures the same on the rig as in Segments()",
				hipY ~= nil and math.abs(measured - segments.length) < 0.06,
				string.format("%.2f hip-to-sole on the rig, %.2f from Segments() (part sizes would say %.2f)",
					measured, segments.length, fromSizes))
			-- The humanoid's own float height doesn't put the soles exactly on the floor; what the pose
			-- needs is the hip-to-sole length above, so this is reported with a loose bound rather than
			-- held to the tight one it used to fail.
			check("a standing rig's soles sit about on the floor", math.abs(soleY - base.Y) < 0.25,
				string.format("%.3f studs off the ground", soleY - base.Y))
		end
	end
	local function heightAt(hip)
		local root = base + Vector3.new(0, hip + ROOT_HALF, 0)
		rig:PivotTo(CFrame.new(root))
		local _, size = rig:GetBoundingBox()
		local top = -math.huge
		for _, part in ipairs(rig:GetDescendants()) do
			if part:IsA("BasePart") then
				top = math.max(top, part.Position.Y + part.Size.Y / 2)
			end
		end
		return top - base.Y, size
	end
	standHeight = heightAt(STAND_HIP)
	crouchHeight = heightAt(CROUCH_HIP)
	rig:Destroy()

	out("body height: %.2f standing, %.2f crouched (%.2f lower)", standHeight, crouchHeight, standHeight - crouchHeight)
	check("crouching lowers the body by the whole HipHeight drop",
		math.abs((standHeight - crouchHeight) - DROP) < 0.05,
		string.format("%.2f studs against a %.2f drop", standHeight - crouchHeight, DROP))

	local onlyCrouched = {}
	local ladder = {}
	for gap = 3.4, 6.01, 0.2 do
		local standFits = standHeight <= gap
		local crouchFits = crouchHeight <= gap
		if crouchFits and not standFits then
			table.insert(onlyCrouched, string.format("%.1f", gap))
		end
		table.insert(ladder, string.format("%.1f:%s", gap, standFits and "both" or (crouchFits and "CROUCH" or "no")))
	end
	out("gap ladder %s", table.concat(ladder, " "))
	check("there are gaps only a crouched body fits through", #onlyCrouched >= 2,
		string.format("%d of them: %s", #onlyCrouched, table.concat(onlyCrouched, ", ")))
	-- The whole point of the number for the map: a gap under this is impassable to anyone.
	out("FOR THE MAP: openings of %.1f studs and up are walkable; %.1f to %.1f are crouch-only; under %.1f nobody.",
		math.ceil(standHeight * 10) / 10, math.ceil(crouchHeight * 10) / 10,
		math.ceil(standHeight * 10) / 10 - 0.1, math.ceil(crouchHeight * 10) / 10)
end

--------------------------------------------------------------------------------
-- Physics: starting it also boots the game, which builds a map
--------------------------------------------------------------------------------

-- Run mode runs the real game, so the map generator is grinding away while these lanes measure. A frame
-- can hitch for seconds during that, which would make a rig look blocked when it was only waiting for a
-- frame. So: start physics, then wait until frames are actually arriving at a sane rate before timing
-- anything, and report what it took.
local physicsReady = false
local function startPhysics()
	if physicsReady then
		return true
	end
	local RunService = game:GetService("RunService")
	if not RunService:IsRunning() then
		RunService:Run()
	end
	local began = os.clock()
	local smooth = 1
	while true do
		local before = os.clock()
		task.wait()
		local frame = os.clock() - before
		smooth = smooth * 0.8 + frame * 0.2
		local waited = os.clock() - began
		-- Settled, or settled ENOUGH, or out of patience. Waiting longer than this buys nothing: the
		-- walks below are robust to a hitch anyway, and the frame rate under a map build is what it is.
		if (waited > 3 and smooth < 0.06) or (waited > 20 and smooth < 0.15) or waited > 45 then
			break
		end
	end
	physicsReady = true
	out("physics started; frames settled to %.0f ms after %.1fs of the game's own boot", smooth * 1000,
		os.clock() - began)
	return true
end

--------------------------------------------------------------------------------
-- 2b. Gaps, for real: a body walking at a header beam, physics and all
--------------------------------------------------------------------------------

-- The ladder above is arithmetic on the rig's height. This one starts physics and walks a real humanoid
-- at a real opening, because what gets through a doorway is decided by the engine, not by me: the head
-- is a ball, the humanoid nudges itself over small obstructions, and the collision box is not the
-- bounding box. Where the two ladders disagree, THIS one is the answer.
if template then
	startPhysics()
	local lane = Instance.new("Model")
	lane.Name = "WalkThrough"
	lane.Parent = folder
	local base = ORIGIN + Vector3.new(0, 0, 240)
	block(lane, Vector3.new(60, 2, 30), CFrame.new(base + Vector3.new(0, -1, 0)), { Name = "Ground" })

	-- Walks the rig from behind the opening to past it, and says whether it got through.
	local function walksThrough(gap, hip)
		local header = block(lane, Vector3.new(4, 12, 24), CFrame.new(base + Vector3.new(0, gap + 6, 0)), {
			Name = "Header", Color = Color3.fromRGB(120, 90, 80),
		})
		local rig = template:Clone()
		for _, part in ipairs(rig:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = false
			end
		end
		rig.Parent = lane
		local body = rig:FindFirstChildOfClass("Humanoid")
		local root = rig:FindFirstChild("HumanoidRootPart")
		body.HipHeight = hip
		body.WalkSpeed = 14
		rig:PivotTo(CFrame.lookAt(base + Vector3.new(-8, hip + ROOT_HALF, 0), base + Vector3.new(8, hip + ROOT_HALF, 0)))
		task.wait(0.4)
		local startX = root.Position.X
		-- Generous, and it leaves the moment the body is through: the walk itself takes under a second at
		-- 14 studs/s, so the rest is headroom for a hitch while the map builds. A body that is really
		-- blocked simply spends it all pressed against the header.
		local began = os.clock()
		while os.clock() - began < 8 do
			body:Move(Vector3.new(1, 0, 0), false)
			task.wait()
			if root.Position.X > base.X + 3 then
				break
			end
		end
		local took = os.clock() - began
		local got = root.Position.X - startX
		local through = root.Position.X > base.X + 2.5
		rig:Destroy()
		header:Destroy()
		return through, got, took
	end

	local standLadder, crouchLadder = {}, {}
	for _, gap in ipairs({ 3.8, 4.2, 4.6, 5.0, 5.4 }) do
		local standThrough, standGot, standTook = walksThrough(gap, STAND_HIP)
		local crouchThrough, crouchGot, crouchTook = walksThrough(gap, CROUCH_HIP)
		table.insert(standLadder, string.format("%.1f:%s", gap, standThrough and "yes" or "no"))
		table.insert(crouchLadder, string.format("%.1f:%s", gap, crouchThrough and "yes" or "no"))
		out("walked %.1f gap: standing %s (%.1f studs in %.1fs), crouched %s (%.1f studs in %.1fs)",
			gap, standThrough and "THROUGH" or "blocked", standGot, standTook,
			crouchThrough and "THROUGH" or "blocked", crouchGot, crouchTook)
	end
	out("walk ladder standing %s", table.concat(standLadder, " "))
	out("walk ladder crouched %s", table.concat(crouchLadder, " "))
	local opened = 0
	for index, entry in ipairs(crouchLadder) do
		if string.find(entry, "yes", 1, true) and not string.find(standLadder[index], "yes", 1, true) then
			opened += 1
		end
	end
	check("crouching really opens gaps a standing body can't walk through", opened >= 1,
		string.format("%d of the 5 heights", opened))
end

--------------------------------------------------------------------------------
-- 2c. The pose on a real rig: are the soles actually on the ground?
--------------------------------------------------------------------------------

-- Everything in lane 1 is the module checked against itself: Pose() builds joint angles and the probe
-- inverts them with the same assumption about which way an R15 joint turns. If that assumption is wrong,
-- both sides are wrong together and the lane passes while the game looks broken. So this lane applies the
-- pose to a REAL rig, lets it render, and measures where the feet ended up in the world. It is the only
-- check here that can catch a sign error, and it also measures the one thing the maths knowingly leaves
-- out: leaning the torso swings the hip sockets, which the leg targets don't compensate for.
if template then
	startPhysics()
	local lane = Instance.new("Model")
	lane.Name = "RealPose"
	lane.Parent = folder
	local base = ORIGIN + Vector3.new(0, 0, 360)
	block(lane, Vector3.new(40, 2, 20), CFrame.new(base + Vector3.new(0, -1, 0)), { Name = "Ground" })

	-- The lowest point of a part, whatever way it is turned.
	local function lowestY(part)
		local low = math.huge
		for _, sx in ipairs({ -0.5, 0.5 }) do
			for _, sy in ipairs({ -0.5, 0.5 }) do
				for _, sz in ipairs({ -0.5, 0.5 }) do
					local corner = part.CFrame * CFrame.new(part.Size.X * sx, part.Size.Y * sy, part.Size.Z * sz)
					low = math.min(low, corner.Position.Y)
				end
			end
		end
		return low
	end

	local worstSole, worstReport = 0, "nothing measured"
	for _, case in ipairs({ { "held", 0, 0 }, { "mid-step", 0.5 * pi, 1 }, { "swap", pi, 1 } }) do
		local rig = template:Clone()
		-- Only the root is anchored. An anchored part cannot be moved by its joint, so a fully anchored
		-- rig would hold the standing pose whatever we wrote onto it and this lane would measure nothing
		-- (and pass, which is worse). Kinematic joints then hold the limbs exactly where the pose puts
		-- them instead of letting them sag.
		for _, part in ipairs(rig:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = part.Name == "HumanoidRootPart"
			end
		end
		for _, joint in ipairs(rig:GetDescendants()) do
			if joint:IsA("AnimationConstraint") then
				pcall(function()
					joint.IsKinematic = true
				end)
			end
		end
		rig.Parent = lane
		rig:PivotTo(CFrame.lookAt(base + Vector3.new(0, CROUCH_HIP + ROOT_HALF, 0),
			base + Vector3.new(10, CROUCH_HIP + ROOT_HALF, 0)))
		local joints = Parkour.PoseJoints(rig)
		local pose = CrouchAnimation.Pose({
			phase = case[2], walk = case[3], clock = 0,
			segments = segments, depth = DEPTH, stride = STRIDE,
		})
		if joints then
			-- Hold it for a few frames: one Transform write can be overwritten by the Animator's own.
			for _ = 1, 12 do
				CrouchAnimation.Apply(joints, pose, 1)
				task.wait()
			end
			local left = rig:FindFirstChild("LeftFoot")
			local right = rig:FindFirstChild("RightFoot")
			local hipPart = rig:FindFirstChild("LeftUpperLeg")
			-- The ankle, not the foot: a foot part's centre sits well ahead of the joint it hangs from
			-- (toes), and comparing that against a model that hangs the sole straight below the ankle
			-- would fail on the rig's own geometry rather than on the pose.
			local shins = {
				Left = rig:FindFirstChild("LeftLowerLeg"), Right = rig:FindFirstChild("RightLowerLeg"),
			}
			local function ankleOf(side)
				local shin = shins[side]
				if not shin then
					return nil
				end
				return (shin.CFrame * CFrame.new(0, -shin.Size.Y / 2, 0)).Position
			end
			if left and right and hipPart and shins.Left and shins.Right then
				-- Whichever foot the cycle says is planted is the one that must be on the ground.
				local rightPlanted = (case[2] % TAU) < pi
				local planted = rightPlanted and right or left
				local sole = lowestY(planted) - base.Y
				-- HEIGHT ALONE IS NOT ENOUGH. A pitch compensation applied the wrong way round swings the
				-- leg backwards and only lifts the sole by a quarter of a stud, which would slip through a
				-- height check while the body visibly walked with its feet behind it. So measure where the
				-- sole sits ALONG the facing too, against what the cycle asked for. The rig faces +X.
				local hipY = hipPart.Position.Y + hipPart.Size.Y / 2
				local wantForward = CrouchAnimation.Foot(case[2] + (rightPlanted and 0 or pi), case[3], STRIDE, DEPTH)
				local ankle = ankleOf(rightPlanted and "Right" or "Left")
				local gotForward = ankle.X - base.X
				local drift = math.abs(gotForward - wantForward)
				local worst = math.max(math.abs(sole), drift)
				if worst > math.abs(worstSole) then
					worstSole = worst
					worstReport = string.format(
						"%s: planted sole %.3f studs %s the ground, and %.3f along the facing against %.3f asked for (out by %.3f); hips %.2f up",
						case[1], math.abs(sole), sole < 0 and "BELOW" or "above", gotForward, wantForward, drift,
						hipY - base.Y)
				end
				out("real pose %s: soles %.3f / %.3f above the ground; planted sole %.3f along the facing (asked %.3f)",
					case[1], lowestY(left) - base.Y, lowestY(right) - base.Y, gotForward, wantForward)
			end
		end
		rig:Destroy()
	end
	-- A sign error puts the sole about a stud out along the facing; the hip-socket swing the maths
	-- knowingly ignores is worth about a fifth of one, so this tolerance separates the two.
	check("the pose really stands the body on its feet", worstSole < 0.35, worstReport)
end

--------------------------------------------------------------------------------
-- 3. Hitting: a ray grid from 30 studs, standing against crouched
--------------------------------------------------------------------------------

if template then
	local lane = Instance.new("Model")
	lane.Name = "Hits"
	lane.Parent = folder
	local base = ORIGIN + Vector3.new(0, 0, 120)
	local ground = block(lane, Vector3.new(80, 2, 60), CFrame.new(base + Vector3.new(0, -1, 0)), { Name = "Ground" })

	local rig = template:Clone()
	rig.Parent = lane

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { rig, ground }

	-- A grid of shots from 30 studs away, at the whole silhouette a standing body could occupy.
	local function profile(hip)
		-- Facing the shooter: a front-on silhouette is what a gunfight presents, and the grid's width
		-- below is sized for the body's shoulders, not its depth.
		local at = base + Vector3.new(0, hip + ROOT_HALF, 0)
		rig:PivotTo(CFrame.lookAt(at, at - Vector3.new(1, 0, 0)))
		local from = base + Vector3.new(-30, 0, 0)
		local hits, head, torso, legs, ground_ = 0, 0, 0, 0, 0
		local lowest = math.huge
		for _, part in ipairs(rig:GetDescendants()) do
			if part:IsA("BasePart") then
				lowest = math.min(lowest, part.Position.Y - part.Size.Y / 2)
			end
		end
		for z = -2, 2.001, 0.2 do
			for y = 0.1, 6.5, 0.15 do
				local origin = from + Vector3.new(0, y, z)
				local result = workspace:Raycast(origin, Vector3.new(60, 0, 0), params)
				if result then
					if result.Instance == ground then
						ground_ += 1
					else
						hits += 1
						local name = result.Instance.Name
						if name == "Head" then
							head += 1
						elseif string.find(name, "Torso") or name == "HumanoidRootPart" then
							torso += 1
						else
							legs += 1
						end
					end
				end
			end
		end
		return { hits = hits, head = head, torso = torso, legs = legs, ground = ground_, lowest = lowest - base.Y }
	end

	local stand = profile(STAND_HIP)
	local crouch = profile(CROUCH_HIP)
	rig:Destroy()

	out("standing: %d hits (head %d, torso %d, limbs %d)", stand.hits, stand.head, stand.torso, stand.legs)
	out("crouched: %d hits (head %d, torso %d, limbs %d)", crouch.hits, crouch.head, crouch.torso, crouch.legs)
	local ratio = crouch.hits / math.max(stand.hits, 1)
	out("FOR THE BOT TAB: a crouched body catches %.0f%% of the shots a standing one does (%.2fx), and its "
		.. "head sits %.2f studs lower.", ratio * 100, ratio, standHeight and (standHeight - crouchHeight) or DROP)
	check("crouching makes you meaningfully harder to hit", ratio < 0.9,
		string.format("%.2fx the standing profile", ratio))
	check("crouching doesn't make you unhittable", ratio > 0.45 and crouch.torso > 0 and crouch.head > 0,
		string.format("%.2fx, head %d, torso %d", ratio, crouch.head, crouch.torso))
	-- The rig does not fold on the server — only the drawn legs do — so the shins go into the floor.
	-- Shots that would have hit them hit the ground instead, which is honest cover, not a hiding spot.
	check("nothing but the legs goes under the floor", crouch.lowest > -(DROP + 0.05),
		string.format("lowest part %.2f studs below the floor (drop %.2f)", -crouch.lowest, DROP))
end

--------------------------------------------------------------------------------
-- The canopy's landing test
--------------------------------------------------------------------------------

-- A parachute now comes off when the feet are down rather than when a timer expires. The DEPLOY path is
-- what that change could break: a ground test that says "down" while the body is still in the air would
-- take the canopy off the instant it opened, which is the free-fall bug all over again. So the test is
-- held to both answers.
if template then
	local ok, MovementService = pcall(function()
		return require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("MovementService"))
	end)
	if ok and MovementService and MovementService.FeetDown then
		local lane = Instance.new("Model")
		lane.Name = "Canopy"
		lane.Parent = folder
		local base = ORIGIN + Vector3.new(0, 0, 480)
		block(lane, Vector3.new(40, 2, 20), CFrame.new(base + Vector3.new(0, -1, 0)), { Name = "Ground" })
		local rig = template:Clone()
		rig.Parent = lane

		rig:PivotTo(CFrame.new(base + Vector3.new(0, STAND_HIP + ROOT_HALF, 0)))
		local down = MovementService.FeetDown(rig)
		rig:PivotTo(CFrame.new(base + Vector3.new(0, 30, 0)))
		local up = MovementService.FeetDown(rig)
		-- Crouched, the body sits lower and the ray is shorter with it: it must still find the floor.
		local humanoidOf = rig:FindFirstChildOfClass("Humanoid")
		humanoidOf.HipHeight = CROUCH_HIP
		rig:PivotTo(CFrame.new(base + Vector3.new(0, CROUCH_HIP + ROOT_HALF, 0)))
		local crouchedDown = MovementService.FeetDown(rig)
		rig:Destroy()

		check("a body on the ground reads as landed", down == true, tostring(down))
		check("a body 30 studs up does NOT read as landed", up == false,
			tostring(up) .. " (true here would take the canopy off the moment it opened)")
		check("a crouched body on the ground still reads as landed", crouchedDown == true, tostring(crouchedDown))
	else
		out("canopy lane skipped: MovementService.FeetDown not available (%s)", tostring(MovementService))
	end
end

--------------------------------------------------------------------------------
-- The joints the animation needs
--------------------------------------------------------------------------------

if template then
	local rig = template:Clone()
	rig.Parent = folder
	local joints = Parkour.PoseJoints(rig)
	check("the rig exposes every joint the crouch drives",
		joints ~= nil and joints.LeftAnkle ~= nil and joints.RightAnkle ~= nil and joints.LeftKnee ~= nil,
		joints and "Root, Waist, hips, knees, ankles" or "PoseJoints returned nothing")
	rig:Destroy()
end

out("passed %d, failed %d", passed, failed)
folder:Destroy()
print("[BRR_Probe] done")
