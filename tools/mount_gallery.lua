-- Mount gallery: close-ups of how a gun's fittings are held on (optic mounts, rails, magazines, lights),
-- from several sides, and the sight picture, for before/after checks of tools/gun_contact_probe.lua
-- findings.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/mount_gallery.lua -OutDir <folder>
-- (add -PlaceFile <snapshot.rbxlx> to shoot an older build for the "before")
--
-- SHOTS lists each gun, the point to look at (millimetres in the gun's own frame: bore y=0, trigger z=0,
-- facing -Z, +X right), how far away and how wide, and which sides. The gun is the one WeaponService
-- builds for the hand, the floor and the podium. "ads" adds the aimed first-person view.

local SHOTS = {
	{ id = "CappuccinaLauncher", focus = Vector3.new(-36, 22, -75), distance = 330, fov = 42,
		sides = { "left", "leftFront", "leftRear", "leftBelow", "top", "right" }, ads = true },
	{ id = "CappuccinaLauncher", name = "CappuccinaLauncher_whole", focus = Vector3.new(0, 0, -120), distance = 1500, fov = 50,
		sides = { "left", "leftFront" } },
}

local SIDES = {
	left = Vector3.new(-1, 0.12, 0),
	right = Vector3.new(1, 0.12, 0),
	top = Vector3.new(-0.15, 1, 0.05),
	leftFront = Vector3.new(-0.8, 0.35, -0.6),
	leftRear = Vector3.new(-0.8, 0.3, 0.7),
	leftBelow = Vector3.new(-0.8, -0.55, 0.15),
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponService = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("WeaponService"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local MM = GunModels.StudsPerMillimetre
local ORIGIN = Vector3.new(0, 700, 3000)
Lighting.ClockTime = 14
Lighting.Brightness = 2.4

local function backdrop(folder, position, facing)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(80, 80, 1)
	part.CFrame = CFrame.lookAt(position, position + facing)
	part.Color = Color3.fromRGB(196, 204, 210)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = folder
end

local function gun(folder, id)
	local def = WeaponData.Get(id)
	local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	model:PivotTo(CFrame.new(ORIGIN))
	model.Parent = folder
	return model
end

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-5, 1, 0), ORIGIN)
		end,
	},
}

for _, shot in ipairs(SHOTS) do
	local label = shot.name or shot.id
	for _, side in ipairs(shot.sides) do
		table.insert(views, {
			name = label .. "_" .. side,
			setup = function(folder, camera)
				gun(folder, shot.id)
				local target = ORIGIN + shot.focus * MM
				local direction = SIDES[side].Unit
				local eye = target + direction * shot.distance * MM
				backdrop(folder, target - direction * 12, direction)
				camera.FieldOfView = shot.fov
				camera.CFrame = CFrame.lookAt(eye, target)
			end,
		})
	end
	if shot.ads then
		table.insert(views, {
			name = label .. "_ads",
			setup = function(folder, camera)
				local def = WeaponData.Get(shot.id)
				local vm = Viewmodel.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
				vm.model.Parent = folder
				local eye = CFrame.new(ORIGIN + Vector3.new(0, 0, 60))
				backdrop(folder, eye.Position + Vector3.new(0, 0, -40), Vector3.new(0, 0, 1))
				vm:Pose(eye, { aim = 1 })
				camera.FieldOfView = 70 * 0.64
				camera.CFrame = eye
			end,
		})
	end
end

table.insert(views, {
	name = "cleanup",
	setup = function(folder, camera)
		camera.CFrame = CFrame.new(ORIGIN)
	end,
})

return views
