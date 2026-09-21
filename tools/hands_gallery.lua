-- Hands gallery: what the first-person hands look like holding each gun.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/hands_gallery.lua -OutDir <folder> -PlaceFile <place>
--
-- Every gun at the hip, where both hands are on the gun and nothing is hidden by the sights, so a whole
-- set can be looked over at once. Then a closer before/after pass on SHOW: the same gun, pose for pose,
-- built with the place's Viewmodel and with a ViewmodelBefore module beside it (a scratch place carrying
-- the older rig), so a change to the hands can be judged rather than remembered.
--
-- Poses: at the hip, aimed, mid-reload and mid-shot -- a hand that sits right on a still gun can be
-- inside a pump, a bolt, a lever or a cylinder once it moves.

local SHOW = { "SahurPistol", "PawnshopNine", "CrocodiloRifle", "TralalaShotgun", "LarilaSniper", "NonnaDoubleBarrel",
	"CameloLMG", "SigmaRevolver" }
local MOMENTS = {
	{ "hip", { aim = 0 }, 70 },
	{ "ads", { aim = 1 }, 70 * 0.64 },
	{ "reload45", { clip = "reload", progress = 0.45, roundsLeft = 0 }, 70 },
	{ "fire50", { aim = 1, clip = "fire", progress = 0.5, roundsLeft = 5 }, 70 * 0.64 },
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local Viewmodel = require(scripts:WaitForChild("Viewmodel"))
local beforeModule = scripts:FindFirstChild("ViewmodelBefore")
local ViewmodelBefore = beforeModule and require(beforeModule) or nil

local ORIGIN = Vector3.new(0, 600, 0)
Lighting.ClockTime = 14
Lighting.Brightness = 2.4
Lighting.ExposureCompensation = 0.1

local okAvatar, avatar = pcall(function()
	local description = Instance.new("HumanoidDescription")
	description.LeftArmColor = Color3.fromRGB(204, 142, 105)
	description.RightArmColor = Color3.fromRGB(204, 142, 105)
	return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
end)
if not okAvatar then
	print("[BRR_Gallery] note no avatar in edit mode (" .. tostring(avatar) .. "); stand-in arms")
	avatar = nil
end

local function room(folder)
	local function block(size, position, color, material)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.Position = position
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		part.Parent = folder
	end
	block(Vector3.new(80, 1, 120), ORIGIN + Vector3.new(0, -5.5, -40), Color3.fromRGB(116, 112, 104), Enum.Material.Concrete)
	block(Vector3.new(80, 40, 1), ORIGIN + Vector3.new(0, 10, -60), Color3.fromRGB(172, 170, 164), Enum.Material.Plaster)
	block(Vector3.new(4, 4, 0.2), ORIGIN + Vector3.new(0, 0, -59.4), Color3.fromRGB(210, 60, 50))
	block(Vector3.new(2, 2, 0.2), ORIGIN + Vector3.new(0, 0, -59.2), Color3.fromRGB(240, 236, 226))
end

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			room(folder)
			camera.FieldOfView = 70
			camera.CFrame = CFrame.new(ORIGIN)
		end,
	},
}

local function pose(module, id, moment)
	return function(folder, camera)
		room(folder)
		local def = WeaponData.Get(id)
		local vm = module.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatar })
		vm.model.Parent = folder
		local eye = CFrame.new(ORIGIN)
		local state = table.clone(moment[2])
		state.magSize = def.magSize
		vm:Pose(eye, state)
		camera.FieldOfView = moment[3] or 70
		camera.CFrame = eye
	end
end

-- Every gun at the hip, in one pass.
local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)
for _, id in ipairs(ids) do
	table.insert(views, { name = "all_" .. id .. "_hip", setup = pose(Viewmodel, id, MOMENTS[1]) })
end

-- The closer look, before and after where there's an older rig to compare with.
for _, id in ipairs(SHOW) do
	for _, moment in ipairs(MOMENTS) do
		if ViewmodelBefore then
			table.insert(views, { name = id .. "_" .. moment[1] .. "_before", setup = pose(ViewmodelBefore, id, moment) })
		end
		table.insert(views, { name = id .. "_" .. moment[1] .. "_after", setup = pose(Viewmodel, id, moment) })
	end
end

table.insert(views, {
	name = "cleanup",
	setup = function(folder, camera)
		camera.CFrame = CFrame.new(ORIGIN)
	end,
})

return views
