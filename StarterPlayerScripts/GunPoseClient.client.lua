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
-- the pouch, back, the charging handle -- on the same timing. While `Aiming` is set the gun comes up to
-- the eye line and the arms go with it (below), and the head cants down onto the stock. Both attributes
-- are the server's to publish (WeaponService.Reload and CombatService.SetAiming).
--
-- The gun is mounted on the torso by a Motor6D, `GunMount` (WeaponService.MountGun). Raising it is that
-- joint's Transform, which like every joint Transform here is local to this client: the server's gun and
-- its shot origins never move, and your own HeldGun stays hidden in first person as before.

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
-- Aimed, the sight comes to the eye line: level with the eyes, in front of the right eye, and no nearer
-- the face than AIM_RELIEF. The eye is read off the rig (the Neck), a little forward of the head's middle.
local AIM_EYE = Vector3.new(0, 0.1, -0.45)
local AIM_RIGHT_EYE = 0.18
local AIM_RELIEF = 0.55

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
		rightWrist = joint("RightHand", "RightWrist"),
		leftWrist = joint("LeftHand", "LeftWrist"),
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

-- A joint's fixed frames either side of its Transform: C0 and C1 for a Motor6D, the two attachments'
-- frames for an AnimationConstraint. Part1 sits at Part0 * c0 * Transform * c1:Inverse().
local function frames(joint)
	if joint:IsA("Motor6D") then
		return joint.C0, joint.C1
	end
	return joint.Attachment0 and joint.Attachment0.CFrame or CFrame.identity,
		joint.Attachment1 and joint.Attachment1.CFrame or CFrame.identity
end

-- Where the hand's grip is, in the upper torso's space, for a shoulder and elbow Transform.
local function handAt(arm, shoulder, elbow)
	local s0, s1 = frames(arm.shoulder)
	local e0, e1 = frames(arm.elbow)
	local w0, w1 = frames(arm.wrist)
	return (s0 * shoulder * s1:Inverse() * e0 * elbow * e1:Inverse() * w0 * w1:Inverse()) * arm.grip
end

-- The shoulder and elbow Transforms that carry this arm's hand from where the held pose puts it to
-- `target` (upper-torso space): the elbow opens or closes until the hand is as far from the shoulder as
-- the target (bisection: the reach grows with the elbow opening), then the shoulder turns the hand onto
-- it, twice over so the turn and the bend settle on each other.
local function reachTo(arm, shoulder, elbow, target)
	local s0, _ = frames(arm.shoulder)
	local pivot = s0.Position
	local want = (target - pivot).Magnitude
	local low, high = 0, math.rad(150)
	local function reach(bend)
		return (handAt(arm, shoulder, CFrame.Angles(bend, 0, 0)) - pivot).Magnitude
	end
	local open, shut = reach(low), reach(high)
	local bend
	if want >= open then
		bend = low
	elseif want <= shut then
		bend = high
	else
		for _ = 1, 24 do
			bend = (low + high) / 2
			if reach(bend) > want then
				low = bend
			else
				high = bend
			end
		end
	end
	elbow = CFrame.Angles(bend, 0, 0)
	local rotation = s0.Rotation
	for _ = 1, 2 do
		local have = (handAt(arm, shoulder, elbow) - pivot).Unit
		local goal = (target - pivot).Unit
		local axis = have:Cross(goal)
		if axis.Magnitude > 1e-6 then
			local turn = CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(have:Dot(goal), -1, 1)))
			shoulder = rotation:Inverse() * turn * rotation * shoulder
		end
	end
	return shoulder, elbow
end

-- The aimed pose for a body and the gun in its hands, worked out once per gun: the GunMount Transform
-- that brings the sight to the eye line, and each arm's shoulder and elbow Transforms that keep its hand
-- where it was on the gun. Nil when the body or the gun lacks what it needs (no GunMount, no sight), and
-- the body then aims as before, head only.
local function aimPoseFor(character, joints)
	local gun = character:FindFirstChild("HeldGun")
	local receiver = gun and gun.PrimaryPart
	local mount = receiver and receiver:FindFirstChild("GunMount")
	local sight = gun and gun:GetAttribute("KP_Sight")
	if not (mount and mount:IsA("Motor6D") and sight and joints.neck) then
		return nil
	end
	-- The design origin, where the keypoints are measured from, in the upper torso's space.
	local origin = mount.C0 * mount.C1:Inverse() * (receiver.PivotOffset or CFrame.identity)
	local n0, n1 = frames(joints.neck)
	local eye = (n0 * n1:Inverse()) * AIM_EYE
	local from = (origin * sight).Position
	local to = Vector3.new(eye.X + AIM_RIGHT_EYE, eye.Y, math.min(from.Z, eye.Z - AIM_RELIEF))
	local raise = to - from
	local pose = {
		gun = gun,
		mount = mount,
		raise = CFrame.new(mount.C0:VectorToObjectSpace(raise)),
	}
	for _, side in ipairs({ { "right", "GripHand", RIGHT_SHOULDER, RIGHT_ELBOW }, { "left", "SupportHand", LEFT_SHOULDER, LEFT_ELBOW } }) do
		local name = side[1]
		local arm = {
			shoulder = joints[name .. "Shoulder"],
			elbow = joints[name .. "Elbow"],
			wrist = joints[name .. "Wrist"],
		}
		if arm.shoulder and arm.elbow and arm.wrist then
			-- The middle of the palm, a little below the wrist joint.
			local _, w1 = frames(arm.wrist)
			arm.grip = w1.Position + Vector3.new(0, -0.15, 0)
			-- The hand goes up with the gun, keeping whatever relation the held pose gives it.
			local target = handAt(arm, side[3], side[4]) + raise
			pose[name .. "Shoulder"], pose[name .. "Elbow"] = reachTo(arm, side[3], side[4], target)
		end
	end
	return pose
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
				-- A reload owns the left arm, sprinting or not: first person keeps reloading through a run.
				local shoulder, elbow = reloadArm(character, entry, now)
				entry.aim += ((character:GetAttribute("Aiming") == true and not entry.reload and 1 or 0) - entry.aim) * aimEase
				-- The aimed pose: worked out only for a body that is aiming (or easing out of it), and again when
				-- the gun in hand changes. A body that never aims -- every bot -- never has it built, and its
				-- GunMount and neck are never written.
				local pose = entry.aimPose
				if entry.aim > 0.001 and (pose == nil or (pose and pose.gun.Parent ~= character)) then
					pose = aimPoseFor(character, joints) or false
					entry.aimPose = pose
				end
				-- Aimed and sprinting do not go together; whichever is further in wins the arms.
				local aim = (pose and entry.aim > 0.01) and entry.aim * (1 - sprint) or 0
				local rightShoulder = blend(RIGHT_SHOULDER, SPRINT_RIGHT_SHOULDER, sprint)
				local rightElbow = blend(RIGHT_ELBOW, SPRINT_RIGHT_ELBOW, sprint)
				local leftShoulder = blend(LEFT_SHOULDER, SPRINT_LEFT_SHOULDER, sprint)
				local leftElbow = blend(LEFT_ELBOW, SPRINT_LEFT_ELBOW, sprint)
				if aim > 0 then
					rightShoulder = rightShoulder:Lerp(pose.rightShoulder or rightShoulder, aim)
					rightElbow = rightElbow:Lerp(pose.rightElbow or rightElbow, aim)
					leftShoulder = leftShoulder:Lerp(pose.leftShoulder or leftShoulder, aim)
					leftElbow = leftElbow:Lerp(pose.leftElbow or leftElbow, aim)
				end
				-- The gun is raised only while there is some aim to raise it by, and set back to rest exactly
				-- once when that ends; a body that is not aiming has its GunMount left alone.
				if pose and aim > 0 then
					pose.mount.Transform = CFrame.identity:Lerp(pose.raise, aim)
					entry.raised = true
				elseif pose and entry.raised then
					pose.mount.Transform = CFrame.identity
					entry.raised = false
				end
				joints.rightShoulder.Transform = rightShoulder
				if joints.rightElbow then
					joints.rightElbow.Transform = rightElbow
				end
				joints.leftShoulder.Transform = shoulder or leftShoulder
				if joints.leftElbow then
					joints.leftElbow.Transform = elbow or leftElbow
				end
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
