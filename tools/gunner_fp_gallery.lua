-- The gunner's first-person view (GunnerView), per armed vehicle, and the gunner as everyone else
-- sees them. Oliver 09-24: the gunner sits at the gun and sees down it, their own arms on its
-- handles, with a sight that shows where the shot really lands.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/gunner_fp_gallery.lua -OutDir <folder>
--
-- Views per armed model (VehicleModels.Mounts):
--   <Model>_fp_rest     the gunner's own view at rest: the eye riding the turret, the arms on the grips,
--                       the sight's cross in the middle and its ring where the shot lands
--   <Model>_fp_fire     three frames after a shot: the kick (the barrel and the view thrown up and back)
--   <Model>_fp_reload   the mount not ready (reloading, or overheated): the right hand off to load
--   <Model>_fp_ads      aiming down the sight (the right mouse, L2, the AIM button): the view on the
--                       sight, zoomed; the launcher's scope glass when its sight is a scope
--   <Model>_fp_swung    turned 50 degrees left and 8 up: the turret, the view and the hands go together
--   <Model>_3p_back     the gunner from behind, posed as VehicleClient poses them (VehicleModels.Poses
--   <Model>_3p_front    GunnerStand / GunnerKneel), turned with the turret; and from the front
-- A small magenta ball is put where GunnerView says the shot lands, so the picture shows whether the
-- ring is on it; a wall 70 studs ahead gives the flat shots something to land on.
--
-- Printed per model ("[BRR_Gallery] note ..."):
--   sight: the predicted landing point, whether it is a hit, and how far the server's own line for the
--          same aim (VehicleWeaponData.Solve, off the mount at rest -- what VehicleWeapons fires) is from
--          the barrel GunnerView draws the sight from: the angle between them and the gap at the muzzle.
--          Both near 0 means the sight shows the true impact.
--   rider: where a posed rider's head stands against the mount's GunnerEye (the first-person camera),
--          in the turret's frame -- what VehicleModels' RIDER_ROOT / EYE_ABOVE_ROOT are set from.
--
-- Edit mode: nothing simulates, so the mount's parts are turned by hand (the Motor6Ds' rotation laid
-- on their subtrees, as tools/vehicle_weapons_gallery.lua does), GunnerView is stepped by hand
-- (noInput), its sight goes in StarterGui (edit mode has no player), and the rider is posed joint by
-- joint from the rig's attachments.
-- static-check: globals GUNNER_FP_ONLY

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))
local GunnerView = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("GunnerView"))

local ORIGIN = Vector3.new(0, 420, 0)
local DT = 1 / 60
-- A seated R15's root in the seat part's space, as the handling probe measured it (tools/vehicle_gallery.lua
-- SEAT_ROOT): half the seat's 0.3 height and 1.486 above that.
local SEAT_ROOT = CFrame.new(0, 0.15 + 1.486, 0)

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4
Lighting.ExposureCompensation = 0.15

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function block(folder, size, frame, color, material)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = frame
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Parent = folder
	return part
end

local function stage(folder)
	block(folder, Vector3.new(700, 1, 700), CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0)), Color3.fromRGB(128, 130, 136), Enum.Material.Concrete)
	-- The wall ahead, with a darker band every 5 studs so the ring's height on it reads.
	block(folder, Vector3.new(160, 44, 2), CFrame.new(ORIGIN + Vector3.new(0, 22, -70)), Color3.fromRGB(196, 190, 176), Enum.Material.Concrete)
	for y = 5, 40, 5 do
		block(folder, Vector3.new(160, 0.25, 0.2), CFrame.new(ORIGIN + Vector3.new(0, y, -68.95)), Color3.fromRGB(120, 116, 108))
	end
	-- A few crates to the left, so the swung view has something to look at.
	for i = 0, 3 do
		block(folder, Vector3.new(4, 4, 4), CFrame.new(ORIGIN + Vector3.new(-40 - i * 7, 2, -30 - i * 9)), Color3.fromRGB(150, 110, 70), Enum.Material.WoodPlanks)
	end
end

local function place(folder, modelId)
	local model = VehicleModels.Build(modelId, Random.new(7), { scheme = 1 })
	model.Parent = folder
	model:PivotTo(CFrame.new(ORIGIN))
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	return model
end

-- Parts that move with `pivot`: welded to it, or hung from it by a joint, all the way down.
local function subtree(model, pivot)
	local set = { [pivot] = true }
	local grew = true
	while grew do
		grew = false
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and not set[part] then
				for _, link in ipairs(part:GetChildren()) do
					local parent = (link:IsA("WeldConstraint") or link:IsA("Motor6D")) and link.Part0 or nil
					if parent and set[parent] and link.Part1 == part then
						set[part] = true
						grew = true
						break
					end
				end
			end
		end
	end
	return set
end

-- The mount turned as its joints would turn it: pitch (with the kick's slide back) then yaw.
local function poseMount(model, yawDeg, pitchDeg, back)
	local names = VehicleWeaponData.Parts.turret
	local yawPart, pitchPart = model:FindFirstChild(names.yaw), model:FindFirstChild(names.pitch)
	local function about(set, frame, rotation)
		local move = frame * rotation * frame:Inverse()
		for part in pairs(set) do
			part.CFrame = move * part.CFrame
		end
	end
	about(subtree(model, pitchPart), pitchPart.CFrame, CFrame.Angles(math.rad(pitchDeg), 0, 0) * CFrame.new(0, 0, back or 0))
	about(subtree(model, yawPart), yawPart.CFrame, CFrame.Angles(0, math.rad(yawDeg), 0))
end

local R15_JOINTS = {
	{ "HumanoidRootPart", "LowerTorso", "Root" },
	{ "LowerTorso", "UpperTorso", "Waist" },
	{ "UpperTorso", "Head", "Neck" },
	{ "UpperTorso", "LeftUpperArm", "LeftShoulder" },
	{ "LeftUpperArm", "LeftLowerArm", "LeftElbow" },
	{ "LeftLowerArm", "LeftHand", "LeftWrist" },
	{ "UpperTorso", "RightUpperArm", "RightShoulder" },
	{ "RightUpperArm", "RightLowerArm", "RightElbow" },
	{ "RightLowerArm", "RightHand", "RightWrist" },
	{ "LowerTorso", "LeftUpperLeg", "LeftHip" },
	{ "LeftUpperLeg", "LeftLowerLeg", "LeftKnee" },
	{ "LeftLowerLeg", "LeftFoot", "LeftAnkle" },
	{ "LowerTorso", "RightUpperLeg", "RightHip" },
	{ "RightUpperLeg", "RightLowerLeg", "RightKnee" },
	{ "RightLowerLeg", "RightFoot", "RightAnkle" },
}

local function newRig()
	local ok, rig = pcall(function()
		local description = Instance.new("HumanoidDescription")
		description.LeftArmColor = Color3.fromRGB(204, 142, 105)
		description.RightArmColor = Color3.fromRGB(204, 142, 105)
		description.HeadColor = Color3.fromRGB(204, 142, 105)
		description.TorsoColor = Color3.fromRGB(60, 90, 160)
		description.LeftLegColor = Color3.fromRGB(40, 44, 56)
		description.RightLegColor = Color3.fromRGB(40, 44, 56)
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	return ok and rig or nil
end

-- A rider posed without physics: the root where the seat puts it, every joint solved down from it
-- (the pose's transform on the rig attachments' C0/C1, as Humanoid:BuildRigFromAttachments joins them).
local function poseRider(rig, rootFrame, pose)
	local motors = {}
	for _, joint in ipairs(R15_JOINTS) do
		local part0, part1 = rig:FindFirstChild(joint[1]), rig:FindFirstChild(joint[2])
		local a0 = part0 and part0:FindFirstChild(joint[3] .. "RigAttachment")
		local a1 = part1 and part1:FindFirstChild(joint[3] .. "RigAttachment")
		if a0 and a1 then
			table.insert(motors, { name = joint[3], part0 = part0, part1 = part1, c0 = a0.CFrame, c1 = a1.CFrame })
		end
	end
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("AnimationConstraint") then
			d:Destroy()
		end
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	local root = rig:FindFirstChild("HumanoidRootPart")
	local before = root.CFrame
	root.CFrame = rootFrame
	local placed = { [root] = true }
	for _ = 1, 4 do
		for _, m in ipairs(motors) do
			if placed[m.part0] and not placed[m.part1] then
				m.part1.CFrame = m.part0.CFrame * m.c0 * (pose[m.name] or CFrame.identity) * m.c1:Inverse()
				placed[m.part1] = true
			end
		end
	end
	local carry = root.CFrame * before:Inverse()
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") and not placed[d] then
			d.CFrame = carry * d.CFrame
		end
	end
	return #motors
end

-- The mount as the server sees it (at rest), for the agreement test: VehicleWeapons.solve's inputs.
local function restMount(model)
	local names = VehicleWeaponData.Parts.turret
	local yawPart, pitchPart, muzzle = model:FindFirstChild(names.yaw), model:FindFirstChild(names.pitch), model:FindFirstChild(names.muzzle)
	local frame = yawPart.CFrame
	return frame, frame:PointToObjectSpace(pitchPart.Position), frame:VectorToObjectSpace(muzzle.Position - pitchPart.Position)
end

local current = nil
local function stopCurrent()
	if current then
		pcall(function()
			current:Stop()
		end)
		current = nil
	end
	local old = StarterGui:FindFirstChild("GunnerSight")
	if old then
		old:Destroy()
	end
end

local function marker(folder, at)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.Size = Vector3.new(0.9, 0.9, 0.9)
	ball.Position = at
	ball.Material = Enum.Material.Neon
	ball.Color = Color3.fromRGB(255, 40, 220)
	ball.Parent = folder
end

local MOMENTS = {
	{ "rest", 0, 0 },
	{ "fire", 0, 0 },
	{ "reload", 0, 0 },
	{ "ads", 0, 0 },
	{ "swung", 50, 8 },
}

local views = {}
local ids = {}
for modelId in pairs(VehicleModels.Mounts) do
	-- GUNNER_FP_ONLY = { "ModelId", ... } in a chunk glued in front renders just those.
	if not GUNNER_FP_ONLY or table.find(GUNNER_FP_ONLY, modelId) then
		table.insert(ids, modelId)
	end
end
table.sort(ids)

for _, modelId in ipairs(ids) do
	local spec = VehicleWeaponData.ForModel(modelId, "turret")
	for _, moment in ipairs(MOMENTS) do
		table.insert(views, {
			name = modelId .. "_fp_" .. moment[1],
			settle = 1,
			setup = function(folder, camera)
				stopCurrent()
				stage(folder)
				local model = place(folder, modelId)
				local frame, pivot, mouth = restMount(model)
				-- The arms' look comes from this rig; it sits out of sight (GunnerView hides it anyway), inside
				-- the vehicle's model so the sight's trace passes it as it passes a seated rider.
				local rig = newRig()
				if rig then
					rig.Parent = model
					rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, -40, 0)))
				end
				local view = GunnerView.Start(model, spec, { noInput = true, character = rig, guiParent = StarterGui })
				if not view then
					note(modelId .. ": GunnerView did not start -- no first-person markers on this mount")
					return
				end
				current = view
				local yaw = moment[2]
				local pitch = math.max(moment[3] + (spec.restPitch or 0), VehicleWeaponData.PitchFloor(spec, math.rad(yaw)) * 180 / math.pi)
				view.yaw, view.wantYaw, view.pitch, view.wantPitch = yaw, yaw, pitch, pitch
				local state = { ready = true }
				if moment[1] == "ads" then
					view:SetAiming(true)
				end
				for _ = 1, 45 do
					view:Update(DT, state)
				end
				if moment[1] == "fire" then
					view:Fired()
					for _ = 1, 3 do
						view:Update(DT, state)
					end
				elseif moment[1] == "reload" then
					state.ready = false
					for _ = 1, 22 do
						view:Update(DT, state)
					end
				end
				poseMount(model, view.yaw, view.pitch + view.kickPitch, view.kickBack)
				marker(folder, view.impact)
				-- The server's line for this aim, off the mount at rest, against the barrel the sight is drawn from.
				local aimPoint, origin, direction = view:AimPoint()
				local sYaw, _, sOrigin, sDirection = VehicleWeaponData.Solve(spec, frame, pivot, mouth, aimPoint)
				if sYaw then
					local angle = math.deg(math.acos(math.clamp(sDirection:Dot(direction), -1, 1)))
					note(string.format("%s_fp_%s sight: lands at %.1f studs (%s), server line %.3f deg / %.3f studs off the barrel's -- %s",
						modelId, moment[1], (view.impact - origin).Magnitude, view.impactHit and "a hit" or "its reach, in the air",
						angle, (sOrigin - origin).Magnitude, (angle < 0.25 and (sOrigin - origin).Magnitude < 0.25) and "AGREE" or "DISAGREE"))
				end
				local screen, onScreen = camera:WorldToViewportPoint(view.impact)
				note(string.format("%s_fp_%s ring: impact on screen %s at (%.0f, %.0f) of (%.0f, %.0f)", modelId, moment[1],
					tostring(onScreen), screen.X, screen.Y, camera.ViewportSize.X, camera.ViewportSize.Y))
			end,
		})
	end
	for _, side in ipairs({ "back", "front" }) do
		table.insert(views, {
			name = modelId .. "_3p_" .. side,
			settle = 1,
			setup = function(folder, camera)
				stopCurrent()
				stage(folder)
				local model = place(folder, modelId)
				local names = VehicleWeaponData.Parts.turret
				local yawPart = model:FindFirstChild(names.yaw)
				local restYaw = yawPart.CFrame
				local eyeMark = yawPart:FindFirstChild("GunnerEye")
				local yaw, pitch = 30, (spec.restPitch or 0) + 4
				pitch = math.max(pitch, VehicleWeaponData.PitchFloor(spec, math.rad(yaw)) * 180 / math.pi)
				poseMount(model, yaw, pitch, 0)
				local turn = restYaw * CFrame.Angles(0, math.rad(yaw), 0) * restYaw:Inverse()
				local seat = VehicleModels.GunnerSeats[modelId]
				local rig = newRig()
				if not seat or not rig then
					note(modelId .. ": no gunner seat or no rig -- nothing to pose")
					return
				end
				rig.Parent = folder
				local stance = yawPart:GetAttribute("Stance") == "kneel" and "GunnerKneel" or "GunnerStand"
				local rootFrame = turn * (model:GetPivot() * seat * SEAT_ROOT)
				local joints = poseRider(rig, rootFrame, VehicleModels.Poses[stance])
				local head = rig:FindFirstChild("Head")
				if eyeMark and head then
					local eye = restYaw * CFrame.Angles(0, math.rad(yaw), 0) * eyeMark.CFrame
					-- The eyes are a little in front of and above the head's middle.
					local eyes = head.CFrame * CFrame.new(0, 0.1, -0.45)
					local off = eye:PointToObjectSpace(eyes.Position)
					note(string.format("%s rider (%s, %d joints): its eyes stand (%.2f, %.2f, %.2f) from GunnerEye in the turret's frame (x right, y up, z back)",
						modelId, stance, joints, off.X, off.Y, off.Z))
				end
				local target = (head and head.Position or yawPart.Position) - Vector3.new(0, 1, 0)
				local away = side == "back" and Vector3.new(-9, 5, 12) or Vector3.new(-8, 3, -13)
				camera.FieldOfView = 45
				camera.CFrame = CFrame.lookAt(target + away, target)
			end,
		})
	end
end

-- The last view puts everything back (the arms under the camera and the sight in StarterGui).
table.insert(views, {
	name = "zz_cleanup",
	settle = 0.3,
	setup = function(folder, camera)
		stopCurrent()
		camera.CameraType = Enum.CameraType.Fixed
		camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(20, 12, 20), ORIGIN)
	end,
})

return views
