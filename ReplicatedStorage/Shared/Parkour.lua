-- Ledge climbing (mantle) and vaulting: finding something to climb or vault, and the path the body
-- follows over it. Shared, so the local player's client (StarterPlayerScripts/MovementClient) and the
-- server's bots (MovementService.TryParkour) obey exactly the same rules. Tuning lives in
-- Shared/MovementConfig (Parkour block).
--
-- Finding a move, in order:
--   1. A slab the width of the body, from MinRise to HandReach above the feet, is swept forward. The
--      first solid thing it meets is the obstacle, and its face turns the move square onto it.
--   2. A ray straight down just inside that face finds the top. A ray that starts inside a taller part
--      passes through it, so a wall too high to grab finds no top at all.
--   3. Short rays walk across the top to measure how deep it is: thin means a vault, deep means a
--      climb.
--   4. The body has to fit everywhere it's about to go: over its head on the way up, over the lip,
--      where it lands, and through the gap of a vault. Checks use RespectCanCollide, so an intact
--      window pane (CanCollide) blocks a vault through its window and a broken one (removed) doesn't.
--
-- Never climbed: anything carrying NoMantle = true on itself or an ancestor (the Cloud Climb, the
-- obby towers), other characters, and loose unanchored parts.
--
-- A move is a plan: { kind, rise, depth, topY, forward, points = { Vector3 ... }, times = { ... },
-- duration, exitVelocity, cost }. `Parkour.PositionAt(plan, t)` gives where the root should be `t`
-- seconds in; the runner sets the root there each Heartbeat with its velocity zeroed, then hands over
-- `exitVelocity` at the end.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MovementConfig"))

local Parkour = {}

local CFG = MovementConfig.Parkour
local STAMINA = MovementConfig.Stamina

local UP = Vector3.new(0, 1, 0)

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- True when `instance` or any ancestor carries NoMantle.
function Parkour.IsExcluded(instance)
	local node = instance
	while node and node ~= workspace and node ~= game do
		if node:GetAttribute("NoMantle") == true then
			return true
		end
		node = node.Parent
	end
	return false
end

-- Part of something with a Humanoid: a player, a bot, a practice dummy, a companion.
local function isCharacterPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	for _ = 1, 3 do
		if not model then
			return false
		end
		if model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- Loose physics debris can't be stood on reliably: it moves under you.
local function isLoose(part)
	return part:IsA("BasePart") and not part.Anchored and not part:IsGrounded()
end

local function unclimbable(part)
	return part == nil or Parkour.IsExcluded(part) or isCharacterPart(part) or isLoose(part)
end

-- How a body sits: `stand` is root centre above the feet, `height` feet to the top of the head.
function Parkour.Metrics(character)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return nil
	end
	local stand = humanoid.HipHeight + root.Size.Y / 2
	local head = character:FindFirstChild("Head")
	local headTop = head and (head.Position.Y + head.Size.Y / 2 - root.Position.Y) or 2.5
	-- A fallen or ragdolled head reads nonsense; clamp to a plausible body.
	headTop = math.clamp(headTop, 1.5, 4)
	return {
		root = root,
		humanoid = humanoid,
		stand = stand,
		feetY = root.Position.Y - stand,
		height = stand + headTop,
		halfWidth = math.max(root.Size.X / 2, 0.8),
		halfDepth = math.max(root.Size.Z / 2, 0.5),
	}
end

local function queryParams(character)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	rayParams.IgnoreWater = true
	rayParams.RespectCanCollide = true
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.RespectCanCollide = true
	overlapParams.MaxParts = 1
	return rayParams, overlapParams
end

-- Is an axis-aligned-to-`forward` box empty? `from` and `to` are the two ends along forward (at any
-- height); the box spans `bottom`..`top` vertically and `width` across.
-- A window pane is not an obstacle to a body moving fast enough to vault: it breaks. This is the shared
-- half of that — Shared/Parkour runs on both sides and can't see the server's DestructibleService, so it
-- matches the name that service gives its panes (DestructibleService.GlassName). The BREAKING is done by
-- MovementService when the vault runs; here it only stops a pane from refusing one.
Parkour.BreakableName = "WindowGlass"

function Parkour.IsBreakable(part)
	return part ~= nil and part.Name == Parkour.BreakableName
end

-- `breakable`: treat panes as if they weren't there, and return the ones found so the caller can break
-- them. Every other clearance check leaves glass solid, so nothing but a vault plans through a window.
local function boxClear(overlapParams, from, to, bottom, top, width, forward, breakable)
	local length = (flat(to) - flat(from)).Magnitude
	local mid = (flat(from) + flat(to)) / 2
	local center = Vector3.new(mid.X, (bottom + top) / 2, mid.Z)
	local cframe = CFrame.lookAt(center, center + forward)
	local parts = workspace:GetPartBoundsInBox(cframe, Vector3.new(width, top - bottom, math.max(length, 0.2)), overlapParams)
	if not breakable then
		return #parts == 0, parts[1]
	end
	local panes, blocker = nil, nil
	for _, part in ipairs(parts) do
		if Parkour.IsBreakable(part) then
			panes = panes or {}
			table.insert(panes, part)
		else
			blocker = blocker or part
		end
	end
	return blocker == nil, blocker, panes
end

-- Where a flat forward walk across the top stops being the top. Returns the depth reached and whether
-- it's still going at `limit`.
local function measureDepth(rayParams, edge, forward, topY, limit, startAt)
	local step = 0.3
	local depth = 0
	-- Terrain's rounded lip sits below the flat top, so the walk starts where the flat was found.
	local d = math.max(0.15, startAt or 0)
	while d <= limit + 0.001 do
		local point = edge + forward * d
		local hit = workspace:Raycast(Vector3.new(point.X, topY + 0.5, point.Z), Vector3.new(0, -1.1, 0), rayParams)
		if not hit or math.abs(hit.Position.Y - topY) > 0.6 or hit.Normal.Y < CFG.TopNormal then
			return depth, false
		end
		depth = d
		d += step
	end
	return depth, true
end

local function easeOut(t)
	return 1 - (1 - t) * (1 - t)
end

local function smooth(t)
	return t * t * (3 - 2 * t)
end

-- Where the root should be `elapsed` seconds into a plan, and whether the plan has finished.
function Parkour.PositionAt(plan, elapsed)
	local points, times = plan.points, plan.times
	local clock = 0
	for index = 2, #points do
		local span = times[index - 1]
		if elapsed < clock + span then
			local t = math.clamp((elapsed - clock) / math.max(span, 1e-3), 0, 1)
			-- The first leg bursts off the mark and eases in; later legs ease both ends.
			local shaped = index == 2 and easeOut(t) or smooth(t)
			return points[index - 1]:Lerp(points[index], shaped), false
		end
		clock += span
	end
	return points[#points], true
end

--[[
	options:
	  groundY     feet height of the last surface stood on (nil: the current feet)
	  speed       horizontal speed toward `direction`, studs/s
	  grounded    on the ground right now
	  allowVault  default true
	  allowMantle default true
	  exhausted   out of stamina: climbs still happen, slower; vaults don't
	Returns a plan, or nil and a short reason.
]]
function Parkour.Find(character, direction, options)
	options = options or {}
	local body = Parkour.Metrics(character)
	if not body then
		return nil, "no body"
	end
	local humanoid, root = body.humanoid, body.root
	if humanoid.Health <= 0 or humanoid.Sit then
		return nil, "can't move"
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Swimming or state == Enum.HumanoidStateType.Seated
		or state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.PlatformStanding
		or state == Enum.HumanoidStateType.Dead or state == Enum.HumanoidStateType.Climbing then
		return nil, "state " .. state.Name
	end

	local look = flat(direction or root.CFrame.LookVector)
	if look.Magnitude < 0.05 then
		return nil, "no direction"
	end
	local forward = look.Unit
	local rayParams, overlapParams = queryParams(character)
	local origin = root.Position
	local feetY = body.feetY
	local groundY = options.groundY or feetY
	local speed = options.speed or 0

	-- 1. The face.
	local lowY = feetY + CFG.MinRise - 0.25
	local highY = feetY + CFG.HandReach
	local centerY = (lowY + highY) / 2
	local slabOrigin = Vector3.new(origin.X, centerY, origin.Z)
	local slab = workspace:Blockcast(CFrame.lookAt(slabOrigin, slabOrigin + forward),
		Vector3.new(body.halfWidth * 1.6, highY - lowY, 0.2), forward * (body.halfDepth + CFG.Reach), rayParams)
	if not slab then
		return nil, "nothing ahead"
	end
	if unclimbable(slab.Instance) then
		return nil, "unclimbable face"
	end
	if math.abs(slab.Normal.Y) > CFG.WallNormal then
		return nil, "a slope, not a wall"
	end
	local wallForward = flat(-slab.Normal)
	if wallForward.Magnitude < 0.2 or wallForward.Unit:Dot(forward) < math.cos(math.rad(55)) then
		return nil, "too oblique"
	end
	forward = wallForward.Unit
	local faceDistance = (flat(slab.Position) - flat(origin)):Dot(forward)

	-- 2. The top. Just inside the face first; smooth terrain rounds its edges over a stud or so, so if
	-- the lip there is sloped, look a little further in for the flat.
	local inside = flat(origin) + forward * (faceDistance + 0.12)
	local top = nil
	local topInset = 0.12
	for _, inset in ipairs({ 0.12, 0.7, 1.3 }) do
		local point = flat(origin) + forward * (faceDistance + inset)
		local hit = workspace:Raycast(Vector3.new(point.X, highY + 0.6, point.Z), Vector3.new(0, -(highY + 0.6 - lowY), 0), rayParams)
		if not hit then
			if inset == 0.12 then
				return nil, "too high"
			end
			break
		end
		if hit.Normal.Y >= CFG.TopNormal then
			top, topInset = hit, inset
			break
		end
	end
	if not top then
		return nil, "no flat top"
	end
	if unclimbable(top.Instance) then
		return nil, "unclimbable top"
	end
	local topY = top.Position.Y
	local rise = topY - feetY
	if rise < CFG.MinRise then
		return nil, "a step"
	end
	if rise > CFG.HandReach then
		return nil, "out of reach"
	end
	if topY - groundY > CFG.MaxRiseFromGround then
		return nil, "too high from the ground"
	end

	local edge = Vector3.new(inside.X, topY, inside.Z) - forward * 0.12
	local width = body.halfWidth * 1.8

	-- 3. Depth.
	local depth, deep = measureDepth(rayParams, edge, forward, topY, CFG.VaultMaxDepth, topInset)

	-- 4a. A vault: thin, low, taken at speed, with somewhere to land.
	if options.allowVault ~= false and not options.exhausted and not deep and rise >= CFG.VaultMinRise
		and rise <= CFG.VaultMaxRise and speed >= CFG.VaultMinSpeed then
		local farEdge = edge + forward * (depth + 0.3)
		local landXZ = farEdge + forward * (body.halfDepth + 1.1)
		local land = workspace:Raycast(Vector3.new(landXZ.X, topY + 0.5, landXZ.Z), Vector3.new(0, -(CFG.VaultMaxDrop + 0.5), 0), rayParams)
		if land and land.Normal.Y >= CFG.TopNormal and not unclimbable(land.Instance) and land.Position.Y < topY - 0.4 then
			local landY = land.Position.Y
			local through, _, panes = boxClear(overlapParams, flat(origin), landXZ + forward * body.halfDepth,
				topY + 0.3, topY + CFG.VaultClearance, width, forward, true)
			local landing = boxClear(overlapParams, landXZ - forward * body.halfDepth, landXZ + forward * body.halfDepth,
				landY + 0.35, landY + body.height - 0.1, width, forward)
			if through and landing then
				local lift = topY + math.max(body.stand * 0.62, 1.7)
				local pathSpeed = math.max(speed, CFG.VaultMinPathSpeed)
				local points = {
					origin,
					Vector3.new(edge.X, lift, edge.Z) - forward * (body.halfDepth + 0.1),
					Vector3.new(farEdge.X, lift, farEdge.Z) + forward * 0.1,
					Vector3.new(landXZ.X, landY + body.stand, landXZ.Z),
				}
				local times = {}
				for index = 2, #points do
					local legLength = (points[index] - points[index - 1]).Magnitude
					table.insert(times, math.clamp(legLength / pathSpeed, 0.06, 0.4))
				end
				local duration = 0
				for _, t in ipairs(times) do
					duration += t
				end
				return {
					kind = "vault", rise = rise, depth = depth, topY = topY, forward = forward, part = top.Instance,
					points = points, times = times, duration = duration, landY = landY,
					exitVelocity = forward * pathSpeed * 0.95 + Vector3.new(0, -4, 0),
					cost = STAMINA.VaultCost,
				}
			end
		end
	end

	-- 4b. A climb onto the top.
	if options.allowMantle == false then
		return nil, "no climb"
	end
	if not deep and depth < 0.9 then
		return nil, "too thin to stand on"
	end
	local landInset = math.clamp(depth / 2 + 0.15, 0.6, body.halfDepth + 1.0)
	local landXZ = edge + forward * landInset
	local hang = Vector3.new(origin.X, 0, origin.Z)
	local pressed = edge - forward * (body.halfDepth + 0.2)
	-- Never pulled backwards toward a wall that's already under the chest.
	if (flat(pressed) - flat(origin)):Dot(forward) > 0 then
		hang = flat(pressed)
	end
	-- The body rises from where it is to the hang point against the face, so that whole corridor, from the
	-- top of the head up to standing height over the ledge, has to be empty. (An overhang in front of the
	-- face is normally caught earlier, since the sweep meets its front edge first and climbs onto it; this
	-- covers the sliver between the head and the lip box, not just the column straight up.)
	local headTopY = origin.Y - body.stand + body.height
	if topY + body.height > headTopY + 0.1 then
		local column = boxClear(overlapParams, flat(origin) - forward * 0.3, hang + forward * (body.halfDepth * 0.6),
			headTopY + 0.05, topY + body.height, width * 0.9, forward)
		if not column then
			return nil, "no headroom to rise"
		end
	end
	local over = boxClear(overlapParams, flat(origin), landXZ + forward * body.halfDepth,
		topY + 0.3, topY + body.height - 0.1, width, forward)
	if not over then
		return nil, "blocked over the lip"
	end
	local pullY = math.max(topY + math.max(body.stand * 0.42, 1.15), origin.Y)
	local points = {
		origin,
		Vector3.new(hang.X, pullY, hang.Z),
		Vector3.new(landXZ.X, topY + body.stand + 0.05, landXZ.Z),
	}
	local climb = math.max(pullY - origin.Y, 0)
	local scale = options.exhausted and CFG.ExhaustedTimeScale or 1
	local times = {
		math.clamp(CFG.MantleBaseTime + CFG.MantlePerStud * climb, CFG.MantleBaseTime, CFG.MantleMaxTime) * scale,
		CFG.MantleOverTime * scale,
	}
	return {
		kind = "mantle", rise = rise, depth = depth, deep = deep, topY = topY, forward = forward, part = top.Instance,
		points = points, times = times, duration = times[1] + times[2],
		exitVelocity = forward * math.max(6, math.min(speed, 18)),
		cost = rise <= STAMINA.FreeMantleRise and 0 or STAMINA.MantleCost,
	}
end

--------------------------------------------------------------------------------
-- Poses
--------------------------------------------------------------------------------

-- How a body looks mid-move, for everyone watching (and you in third person). There's no uploaded
-- animation in this project, so poses are joint Transforms written in Stepped, straight after the
-- Animator (the same technique as GunPoseClient). Lower body and spine only: the arms stay with the
-- gun pose.
--
-- R15 joint frames: a positive X angle swings a hip's leg forward, folds a knee's shin forward too
-- (so a bent knee is negative), and tips the pelvis (Root) or chest (Waist) backwards. Checked by
-- render in tools/parkour_probe.lua's pose views.
local rad = math.rad
Parkour.Poses = {
	-- Leaning back on one hip, lead leg out straight, back leg tucked.
	slide = {
		Root = CFrame.new(0, -1.55, 0.2) * CFrame.Angles(rad(48), 0, rad(-8)),
		Waist = CFrame.Angles(rad(-20), rad(8), 0),
		RightHip = CFrame.Angles(rad(34), 0, rad(4)),
		RightKnee = CFrame.Angles(rad(-4), 0, 0),
		LeftHip = CFrame.Angles(rad(8), 0, rad(-10)),
		LeftKnee = CFrame.Angles(rad(-78), 0, 0),
	},
	-- Stepping up over the lip: chest leaning in, one knee driven high onto the ledge, the other leg
	-- still hanging below.
	mantle = {
		Root = CFrame.Angles(rad(-12), 0, 0),
		Waist = CFrame.Angles(rad(-16), 0, 0),
		RightHip = CFrame.Angles(rad(96), 0, 0),
		RightKnee = CFrame.Angles(rad(-112), 0, 0),
		LeftHip = CFrame.Angles(rad(-8), 0, 0),
		LeftKnee = CFrame.Angles(rad(-24), 0, 0),
	},
	-- A side vault: body tipped over, both legs swung up and tucked to one side.
	vault = {
		Root = CFrame.Angles(rad(-14), rad(-10), rad(34)),
		Waist = CFrame.Angles(rad(-8), 0, rad(-12)),
		RightHip = CFrame.Angles(rad(72), 0, rad(-18)),
		RightKnee = CFrame.Angles(rad(-44), 0, 0),
		LeftHip = CFrame.Angles(rad(58), 0, rad(-22)),
		LeftKnee = CFrame.Angles(rad(-82), 0, 0),
	},
}

local POSE_JOINTS = {
	Root = "LowerTorso",
	Waist = "UpperTorso",
	RightHip = "RightUpperLeg",
	RightKnee = "RightLowerLeg",
	LeftHip = "LeftUpperLeg",
	LeftKnee = "LeftLowerLeg",
	-- The ankles and the neck are here for Shared/CrouchAnimation: the ankles keep the soles flat while
	-- the legs fold, and the neck keeps the head up while the chest leans over it. The slide/climb/vault
	-- poses have no entry for any of the three, so ApplyPose leaves them exactly as the Animator left them.
	RightAnkle = "RightFoot",
	LeftAnkle = "LeftFoot",
	Neck = "Head",
}

-- The joints a pose drives, by name: Motor6Ds on a player's rig, AnimationConstraints on a physics rig
-- (every bot). Nil for anything that isn't R15.
function Parkour.PoseJoints(character)
	local joints = {}
	for jointName, partName in pairs(POSE_JOINTS) do
		local part = character:FindFirstChild(partName)
		local joint = part and part:FindFirstChild(jointName)
		if joint and (joint:IsA("Motor6D") or joint:IsA("AnimationConstraint")) then
			joints[jointName] = joint
		end
	end
	if not joints.Root or not joints.RightHip or not joints.LeftHip then
		return nil
	end
	return joints
end

-- Blends the pose for `kind` over whatever the Animator just wrote, by `weight` (0..1).
function Parkour.ApplyPose(joints, kind, weight)
	local pose = Parkour.Poses[kind]
	if not pose or weight <= 0 then
		return
	end
	for jointName, target in pairs(pose) do
		local joint = joints[jointName]
		if joint then
			joint.Transform = weight >= 1 and target or joint.Transform:Lerp(target, weight)
		end
	end
end

return Parkour
