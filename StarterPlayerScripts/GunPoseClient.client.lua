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
						armed[child] = { humanoid = humanoid, root = root, joints = joints }
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

RunService.Stepped:Connect(function()
	local focus = camera.CFrame.Position
	for character, entry in pairs(armed) do
		if not character.Parent or not entry.root.Parent then
			armed[character] = nil
		elseif entry.humanoid.Health > 0 and (entry.root.Position - focus).Magnitude < POSE_DISTANCE then
			local joints = entry.joints
			if entry.item then
				joints.rightShoulder.Transform = ITEM_SHOULDER
				if joints.rightElbow then
					joints.rightElbow.Transform = ITEM_ELBOW
				end
			else
				joints.rightShoulder.Transform = RIGHT_SHOULDER
				joints.leftShoulder.Transform = LEFT_SHOULDER
				if joints.rightElbow then
					joints.rightElbow.Transform = RIGHT_ELBOW
				end
				if joints.leftElbow then
					joints.leftElbow.Transform = LEFT_ELBOW
				end
			end
		end
	end
end)
