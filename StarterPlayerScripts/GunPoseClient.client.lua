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
--
-- Reloading and aiming (#13) are drawn from the first-person viewmodel's own tables, so what others see
-- is the reload you see: while a body's `Reloading` attribute holds the reload's length in seconds, the
-- left arm follows the gun's first-person reload clip (Viewmodel.ClipFor / BodyArm) -- to the magazine,
-- the pouch, back, the charging handle -- on the same timing. While `Aiming` is set the head cants down
-- onto the stock. Both attributes are the server's to publish (WeaponService.Reload and
-- CombatService.SetAiming); without them the body keeps its held pose, as before.

local RunService = game:GetService("RunService")
local Viewmodel = require(script.Parent:WaitForChild("Viewmodel"))

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
-- Aimed, the cheek goes down onto the stock: the head pitched down, turned and tilted toward the gun
-- side. On an R15 Neck a positive X tips the head back and positive Y and Z turn and tilt it to the
-- left, so all three are negative. Eased at Viewmodel's aiming rate (13).
local AIM_NECK = CFrame.Angles(math.rad(-6), math.rad(-10), math.rad(-8))
local AIM_EASE = 13

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
		neck = joint("Head", "Neck"),
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
						armed[child] = { humanoid = humanoid, root = root, joints = joints, sprint = 0, aim = 0 }
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

-- The left arm's turns for a body mid-reload, or nil when it is not reloading. The clip is built once
-- per reload, when the attribute appears, from the gun in the body's hands; the progress is time since
-- then over the reload's length (game time: os.clock is CPU time in Roblox).
local function reloadArm(character, entry, now)
	local seconds = character:GetAttribute("Reloading")
	if type(seconds) ~= "number" or seconds <= 0 then
		entry.reload = nil
		return nil
	end
	if not entry.reload then
		local gun = character:FindFirstChild("HeldGun")
		local clip = gun and Viewmodel.ClipFor(gun, "reload", character:GetAttribute("ReloadEmpty") == true, 1)
		entry.reload = { start = now, clip = clip }
	end
	local progress = math.clamp((now - entry.reload.start) / seconds, 0, 1)
	return Viewmodel.BodyArm(entry.reload.clip, progress)
end

RunService.Stepped:Connect(function(_, delta)
	local focus = camera.CFrame.Position
	local ease = math.clamp(math.min(delta, 0.1) * SPRINT_EASE, 0, 1)
	local aimEase = math.clamp(math.min(delta, 0.1) * AIM_EASE, 0, 1)
	local now = time()
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
				if joints.rightElbow then
					joints.rightElbow.Transform = blend(RIGHT_ELBOW, SPRINT_RIGHT_ELBOW, sprint)
				end
				-- A reload owns the left arm, sprinting or not: first person keeps reloading through a run.
				local shoulder, elbow = reloadArm(character, entry, now)
				joints.leftShoulder.Transform = shoulder or blend(LEFT_SHOULDER, SPRINT_LEFT_SHOULDER, sprint)
				if joints.leftElbow then
					joints.leftElbow.Transform = elbow or blend(LEFT_ELBOW, SPRINT_LEFT_ELBOW, sprint)
				end
				entry.aim += ((character:GetAttribute("Aiming") == true and not entry.reload and 1 or 0) - entry.aim) * aimEase
				if entry.aim > 0.01 and joints.neck then
					joints.neck.Transform = joints.neck.Transform:Lerp(joints.neck.Transform * AIM_NECK, entry.aim)
				end
			end
			-- The lean goes on top of the run's own spine, eased with the rest.
			if sprint > 0 and joints.waist then
				joints.waist.Transform = joints.waist.Transform:Lerp(joints.waist.Transform * SPRINT_WAIST, sprint)
			end
		end
	end
end)
