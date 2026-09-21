-- Workshop gallery: the shed-and-kitchen guns, as a rack and as you hold them.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/workshop_gallery.lua -OutDir <folder>
--
-- Each gun gets a three-quarter view and a side view of the model the hand, the floor and the podium all
-- use, then the first-person view at the hip and aimed, posed by the game's own Viewmodel with a default
-- avatar's arms. Two mechanism frames as well: the broom gun broken open and the vacuum mid-reload.

local SHOW = { "RageQuitCarbine", "CleanSweepDouble", "HoseDownSniper", "DustDevilRotary", "YardWorkBlower", "PartyFoulCannon" }
local BREAK_OPEN = { CleanSweepDouble = true, DustDevilRotary = true }

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
local VM_ORIGIN = Vector3.new(0, 600, 0)
Lighting.ClockTime = 14
Lighting.Brightness = 2.4

local okAvatar, avatar = pcall(function()
	local description = Instance.new("HumanoidDescription")
	description.LeftArmColor = Color3.fromRGB(204, 142, 105)
	description.RightArmColor = Color3.fromRGB(204, 142, 105)
	return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
end)
if not okAvatar then
	avatar = nil
end

local function backdrop(folder, position, facing)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(90, 90, 1)
	part.CFrame = CFrame.lookAt(position, position + facing)
	part.Color = Color3.fromRGB(198, 206, 212)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = folder
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
	block(Vector3.new(80, 1, 120), VM_ORIGIN + Vector3.new(0, -5.5, -40), Color3.fromRGB(116, 112, 104), Enum.Material.Concrete)
	block(Vector3.new(80, 40, 1), VM_ORIGIN + Vector3.new(0, 10, -60), Color3.fromRGB(172, 170, 164), Enum.Material.Plaster)
	block(Vector3.new(4, 4, 0.2), VM_ORIGIN + Vector3.new(0, 0, -59.4), Color3.fromRGB(210, 60, 50))
	block(Vector3.new(2, 2, 0.2), VM_ORIGIN + Vector3.new(0, 0, -59.2), Color3.fromRGB(240, 236, 226))
end

local function gunView(id, direction, distance, fov)
	return function(folder, camera)
		local def = WeaponData.Get(id)
		local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
		model:PivotTo(CFrame.new(ORIGIN))
		model.Parent = folder
		local target = ORIGIN + Vector3.new(0, -10, -120) * MM
		local eye = target + direction.Unit * distance * MM
		backdrop(folder, target - direction.Unit * 14, direction.Unit)
		camera.FieldOfView = fov
		camera.CFrame = CFrame.lookAt(eye, target)
	end
end

local function handsView(id, state, fov)
	return function(folder, camera)
		room(folder)
		local def = WeaponData.Get(id)
		local vm = Viewmodel.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatar })
		vm.model.Parent = folder
		local eye = CFrame.new(VM_ORIGIN)
		local pose = table.clone(state)
		pose.magSize = def.magSize
		vm:Pose(eye, pose)
		camera.FieldOfView = fov
		camera.CFrame = eye
	end
end

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			backdrop(folder, ORIGIN + Vector3.new(0, 0, -20), Vector3.new(0, 0, 1))
			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, 6), ORIGIN)
		end,
	},
}

for _, id in ipairs(SHOW) do
	table.insert(views, { name = id .. "_quarter", setup = gunView(id, Vector3.new(0.85, 0.35, -0.5), 1250, 42) })
	table.insert(views, { name = id .. "_side", setup = gunView(id, Vector3.new(1, 0.06, 0), 1250, 42) })
	table.insert(views, { name = id .. "_hip", setup = handsView(id, { aim = 0 }, 70) })
	table.insert(views, { name = id .. "_ads", setup = handsView(id, { aim = 1 }, 70 * 0.64) })
	if BREAK_OPEN[id] then
		table.insert(views, { name = id .. "_reload45", setup = handsView(id, { clip = "reload", progress = 0.45, roundsLeft = 0 }, 70) })
	end
end

table.insert(views, {
	name = "cleanup",
	setup = function(folder, camera)
		camera.CFrame = CFrame.new(ORIGIN)
	end,
})

return views
