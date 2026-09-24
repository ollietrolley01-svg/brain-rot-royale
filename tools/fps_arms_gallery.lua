-- First-person arms gallery (#11, #26, #92, #44, #13): what tools/fps_arms_check.py measured, to be looked at.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/fps_arms_gallery.lua -OutDir <folder>
--
-- First person: the long guns whose support arm used to stretch to half as long again (the shoulder now
-- comes forward), the straight-stocked double whose trigger wrist met its forearm at 105 degrees, the two
-- whose hands were a bare palm (Boombox support hand; the pistol and a rifle trigger hand, fingers now
-- closed or lying along the guard), each at the hip at the WIDEST field of view (95, where the shoulder
-- is nearest the screen's edge), fully aimed, and mid-reload. Look for: no gap or open wedge at an
-- elbow, no shoulder end on screen, a wrist that bends like a wrist, fingers round the grip, nothing on
-- the crosshair (a small red dot is drawn on the wall behind it).
--
-- Third person: a default R15 body holding each of three guns, its left arm posed from that gun's
-- first-person reload clip (Viewmodel.ClipFor / BodyArm, as GunPoseClient poses other players) at four
-- moments. Look for: the hand going to the magazine, the pouch, back, and (empty) the charging handle.

local SHOW = { "RubberChickenRailgun", "SixSevenMarksman", "LarilaSniper", "NonnaDoubleBarrel", "BoomboxBassline", "SahurPistol", "CrocodiloRifle" }
local MOMENTS = {
	{ "hip95", { aim = 0 }, 95 },
	{ "ads", { aim = 1 }, 95 * 0.64 },
	{ "reload45", { clip = "reload", progress = 0.45, roundsLeft = 0 }, 70 },
}
local BODY_GUNS = { "CrocodiloRifle", "SahurPistol", "TralalaShotgun" }
local BODY_MOMENTS = { 0.15, 0.35, 0.6, 0.85 }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local ORIGIN = Vector3.new(0, 600, 0)

local function newAvatar()
	local ok, avatar = pcall(function()
		local description = Instance.new("HumanoidDescription")
		description.LeftArmColor = Color3.fromRGB(204, 142, 105)
		description.RightArmColor = Color3.fromRGB(204, 142, 105)
		description.TorsoColor = Color3.fromRGB(60, 90, 160)
		return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if not ok then
		print("[BRR_Gallery] no avatar in edit mode (" .. tostring(avatar) .. ")")
		return nil
	end
	-- CreateHumanoidModelFromDescription hands back a physics rig whose joints are AnimationConstraints,
	-- and their C0 is read-only, so every body view failed on `motor.C0 = ...`. Convert to Motor6Ds, the
	-- joint a player's character has (the same conversion as tools/crouch_gallery.lua).
	for _, joint in ipairs(avatar:GetDescendants()) do
		if joint:IsA("AnimationConstraint") then
			local a0, a1 = joint.Attachment0, joint.Attachment1
			if a0 and a1 and a0.Parent and a1.Parent then
				local motor = Instance.new("Motor6D")
				motor.Name = joint.Name
				motor.Part0 = a0.Parent
				motor.Part1 = a1.Parent
				motor.C0 = a0.CFrame
				motor.C1 = a1.CFrame
				motor.Parent = joint.Parent
				joint:Destroy()
			end
		end
	end
	return avatar
end
local avatar = newAvatar()

Lighting.ClockTime = 14
Lighting.Brightness = 2.4

local function scene(folder)
	local function block(size, position, color)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.Position = position
		part.Color = color
		part.Parent = folder
	end
	block(Vector3.new(80, 1, 120), ORIGIN + Vector3.new(0, -5.5, -40), Color3.fromRGB(116, 112, 104))
	block(Vector3.new(80, 40, 1), ORIGIN + Vector3.new(0, 10, -60), Color3.fromRGB(172, 170, 164))
	-- The crosshair's own spot on the wall, so anything over it shows.
	block(Vector3.new(0.3, 0.3, 0.2), ORIGIN + Vector3.new(0, 0, -59.4), Color3.fromRGB(230, 30, 30))
end

local views = {
	{ name = "warmup", setup = function(folder, camera)
		scene(folder)
		camera.FieldOfView = 70
		camera.CFrame = CFrame.new(ORIGIN)
	end },
}
for _, id in ipairs(SHOW) do
	for _, moment in ipairs(MOMENTS) do
		table.insert(views, {
			name = id .. "_" .. moment[1],
			setup = function(folder, camera)
				scene(folder)
				local def = WeaponData.Get(id)
				local vm = Viewmodel.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatar })
				vm.model.Parent = folder
				local eye = CFrame.new(ORIGIN)
				local state = table.clone(moment[2])
				state.magSize = def.magSize
				vm:Pose(eye, state)
				camera.FieldOfView = moment[3]
				camera.CFrame = eye
			end,
		})
	end
end

-- A body's left arm posed through C0 (edit mode runs no Animator, so a Transform would not show; C0 *
-- turns is where Transform = turns would put the arm).
for _, id in ipairs(BODY_GUNS) do
	for _, progress in ipairs(BODY_MOMENTS) do
		table.insert(views, {
			name = "body_" .. id .. "_" .. math.floor(progress * 100),
			setup = function(folder, camera)
				scene(folder)
				local body = newAvatar()
				if not body then
					return
				end
				body.Parent = folder
				body:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, -2, -8)) * CFrame.Angles(0, math.rad(150), 0))
				local def = WeaponData.Get(id)
				local gun = GunModels.Build(def, Rarity.Color(def.rarity), Enum.Material.Metal)
				gun.Name = "HeldGun"
				local clip = Viewmodel.ClipFor(gun, "reload", progress > 0.5, 1)
				local shoulder, elbow = Viewmodel.BodyArm(clip, progress)
				local function turn(partName, jointName, by)
					local motor = body:FindFirstChild(partName) and body[partName]:FindFirstChild(jointName)
					if motor then
						motor.C0 = motor.C0 * by
					end
				end
				-- The held pose on the right (GunPoseClient's RIGHT_SHOULDER / RIGHT_ELBOW), the clip on the left.
				turn("RightUpperArm", "RightShoulder", CFrame.Angles(0, math.rad(10), 0) * CFrame.Angles(math.rad(82), 0, 0))
				turn("RightLowerArm", "RightElbow", CFrame.Angles(math.rad(6), 0, 0))
				turn("LeftUpperArm", "LeftShoulder", shoulder)
				turn("LeftLowerArm", "LeftElbow", elbow)
				local hand = body:FindFirstChild("RightHand")
				if hand then
					gun:PivotTo(hand.CFrame * CFrame.new(0, -0.2, -0.4))
				end
				gun.Parent = folder
				camera.FieldOfView = 50
				camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-3, 0.5, -3), ORIGIN + Vector3.new(0, -1, -8))
			end,
		})
	end
end

return views
