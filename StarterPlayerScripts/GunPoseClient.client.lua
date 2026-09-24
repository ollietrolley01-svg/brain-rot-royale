-- Third-person arm pose for anyone holding a gun.
--
-- WeaponService mounts every gun with its grip where a raised right hand is. This raises the arms
-- to match: the right hand on the grip and the left reaching forward to support the gun, so
-- everyone — other players and bots alike — reads as aiming rather than walking around with a
-- gun floating in front of their chest.
--
-- It runs locally on every client, for every nearby character. A joint's Transform is written by
-- the Animator each frame; setting it in Stepped, which runs straight after animations, overrides
-- the arms for that frame while the walk and idle animations keep driving the rest of the body.
-- R15 rigs only: R6 shoulders use different joint axes. Both rig formats work: classic Motor6D
-- joints and the AnimationConstraint joints of current physics rigs (every bot).

local RunService = game:GetService("RunService")

-- Both arms swing forward (pitch) and turn in toward the gun (yaw). Yaw is applied after pitch so
-- it turns the raised arm rather than twisting the hanging one.
local RIGHT_SHOULDER = CFrame.Angles(0, math.rad(10), 0) * CFrame.Angles(math.rad(82), 0, 0)
local LEFT_SHOULDER = CFrame.Angles(0, math.rad(-38), 0) * CFrame.Angles(math.rad(78), 0, 0)
local RIGHT_ELBOW = CFrame.Angles(math.rad(6), 0, 0)
local LEFT_ELBOW = CFrame.Angles(math.rad(14), 0, 0)

-- Holding an item (a potion, a med kit) is one-handed: the right arm is held out lower with the
-- elbow bent, and the left arm is left to the walk animation.
local ITEM_SHOULDER = CFrame.Angles(0, math.rad(-12), 0) * CFrame.Angles(math.rad(58), 0, 0)
local ITEM_ELBOW = CFrame.Angles(math.rad(34), 0, 0)

-- Sprinting (the character's `Sprinting` attribute, published by the server's MovementService): the gun
-- comes down to a low ready across the body and the chest leans into the run, the third-person twin of
-- the first-person dip in Viewmodel (#13, #89). Shoulders pitched forward less and turned further in,
-- elbows bent so the muzzle points at the ground ahead. An item hand just swings with the run.
local SPRINT_RIGHT_SHOULDER = CFrame.Angles(0, math.rad(28), 0) * CFrame.Angles(math.rad(34), 0, 0)
local SPRINT_LEFT_SHOULDER = CFrame.Angles(0, math.rad(-46), 0) * CFrame.Angles(math.rad(46), 0, 0)
local SPRINT_RIGHT_ELBOW = CFrame.Angles(math.rad(62), 0, 0)
local SPRINT_LEFT_ELBOW = CFrame.Angles(math.rad(70), 0, 0)
-- A positive X tips the chest back on an R15 Waist (Shared/Parkour), so the lean is negative.
local SPRINT_WAIST = CFrame.Angles(math.rad(-10), 0, 0)
-- As Viewmodel: standing still with sprint held is not a sprint. Studs per second, flat.
local SPRINT_MIN_SPEED = 4
-- How fast the pose eases in and out, per second: Viewmodel's 9.
local SPRINT_EASE = 9

local SCAN_INTERVAL = 0.5
local POSE_DISTANCE = 300

local camera = workspace.CurrentCamera

-- character -> { humanoid, root, joints }
local armed = {}

local function jointsFor(character)
	local function joint(partName, jointName)
		local part = character:FindFirstChild(partName)
		local motor = part and part:FindFirstChild(jointName)
		if not motor then
			-- Physics rigs keep the joint under the part too, but look everywhere to be safe.
			for _, descendant in ipairs(character:GetDescendants()) do
				if descendant.Name == jointName and (descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint")) then
					motor = descendant
					break
				end
			end
		end
		return motor and (motor:IsA("Motor6D") or motor:IsA("AnimationConstraint")) and motor or nil
	end
	local joints = {
		rightShoulder = joint("RightUpperArm", "RightShoulder"),
		leftShoulder = joint("LeftUpperArm", "LeftShoulder"),
		rightElbow = joint("RightLowerArm", "RightElbow"),
		leftElbow = joint("LeftLowerArm", "LeftElbow"),
		waist = joint("UpperTorso", "Waist"),
	}
	if not joints.rightShoulder or not joints.leftShoulder then
		return nil
	end
	return joints
end

-- Characters are direct children of the workspace, so a light scan finds everyone holding a gun
-- without listening to every descendant the map adds.
local function scan()
	local seen = {}
	for _, child in ipairs(workspace:GetChildren()) do
		local holdingGun = child:IsA("Model") and child:FindFirstChild("HeldGun") ~= nil
		local holdingItem = child:IsA("Model") and child:FindFirstChild("HeldItem") ~= nil
		if holdingGun or holdingItem then
			local humanoid = child:FindFirstChildOfClass("Humanoid")
			local root = child:FindFirstChild("HumanoidRootPart")
			if humanoid and root then
				seen[child] = true
				if not armed[child] then
					local joints = jointsFor(child)
					if joints then
						armed[child] = { humanoid = humanoid, root = root, joints = joints, sprint = 0 }
					end
				end
				if armed[child] then
					armed[child].item = not holdingGun
				end
			end
		end
	end
	for character in pairs(armed) do
		if not seen[character] then
			armed[character] = nil
		end
	end
end

task.spawn(function()
	while true do
		scan()
		task.wait(SCAN_INTERVAL)
	end
end)

-- Whether this body reads as sprinting right now: the server says so, it is actually moving, and no
-- slide, climb or vault owns the lower body (MovementClient poses those, from the `Parkour` attribute).
local function sprintingNow(character, root)
	if character:GetAttribute("Sprinting") ~= true or character:GetAttribute("Parkour") ~= nil then
		return false
	end
	local velocity = root.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude > SPRINT_MIN_SPEED
end

local function blend(from, to, weight)
	return weight <= 0 and from or from:Lerp(to, weight)
end

RunService.Stepped:Connect(function(_, delta)
	local focus = camera.CFrame.Position
	local ease = math.clamp(math.min(delta, 0.1) * SPRINT_EASE, 0, 1)
	for character, entry in pairs(armed) do
		if not character.Parent or not entry.root.Parent then
			armed[character] = nil
		elseif entry.humanoid.Health > 0 and (entry.root.Position - focus).Magnitude < POSE_DISTANCE then
			local joints = entry.joints
			entry.sprint += ((sprintingNow(character, entry.root) and 1 or 0) - entry.sprint) * ease
			local sprint = entry.sprint > 0.01 and entry.sprint or 0
			if entry.item then
				-- Blended from what the run animation just wrote, so a sprinting hand swings with it.
				local hand = joints.rightShoulder.Transform
				joints.rightShoulder.Transform = blend(ITEM_SHOULDER, hand, sprint)
				if joints.rightElbow then
					joints.rightElbow.Transform = blend(ITEM_ELBOW, joints.rightElbow.Transform, sprint)
				end
			else
				joints.rightShoulder.Transform = blend(RIGHT_SHOULDER, SPRINT_RIGHT_SHOULDER, sprint)
				joints.leftShoulder.Transform = blend(LEFT_SHOULDER, SPRINT_LEFT_SHOULDER, sprint)
				if joints.rightElbow then
					joints.rightElbow.Transform = blend(RIGHT_ELBOW, SPRINT_RIGHT_ELBOW, sprint)
				end
				if joints.leftElbow then
					joints.leftElbow.Transform = blend(LEFT_ELBOW, SPRINT_LEFT_ELBOW, sprint)
				end
			end
			-- The lean goes on top of the run's own spine, eased with the rest.
			if sprint > 0 and joints.waist then
				joints.waist.Transform = joints.waist.Transform:Lerp(joints.waist.Transform * SPRINT_WAIST, sprint)
			end
		end
	end
end)
