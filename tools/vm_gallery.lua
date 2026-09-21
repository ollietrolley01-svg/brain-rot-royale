-- Viewmodel gallery: the first-person view of each gun, posed by the game's own Viewmodel module and
-- photographed from exactly where your eye is.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vm_gallery.lua -OutDir <folder>
--
-- Each view builds a viewmodel, freezes it at a moment (hip, aiming, a point in the reload or the rack,
-- sprinting, inspecting) with Viewmodel:Pose, and holds the edit camera where the player's camera
-- would be. SHOW picks the guns and MOMENTS the poses.

-- nil shows every gun. The ADS field of view is the game's: 70 * ADS_ZOOM (0.64).
local SHOW = { "SahurPistol", "SigmaRevolver", "NonnaDoubleBarrel", "BonkerDoubleBarrel", "GoldenSahurCannon", "TralalaShotgun",
	"LarilaSniper", "CrocodiloRifle" }
local MOMENTS = {
	{ "hip", { aim = 0 } },
	{ "ads", { aim = 1 }, 44.8 },
	-- Aimed, halfway through working the action between shots (the lever, the pump, the bolt).
	{ "adsFire", { aim = 1, clip = "fire", progress = 0.5, roundsLeft = 5 }, 44.8 },
	{ "reload45", { clip = "reload", progress = 0.45, roundsLeft = 0 } },
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local ORIGIN = Vector3.new(0, 600, 0)

-- A default R15 avatar to take the arms from, the way the game takes the player's; if Studio can't
-- build one in edit mode, the viewmodel's stand-in arms are used and the log says so.
local okAvatar, avatar = pcall(function()
	local description = Instance.new("HumanoidDescription")
	description.LeftArmColor = Color3.fromRGB(204, 142, 105)
	description.RightArmColor = Color3.fromRGB(204, 142, 105)
	return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
end)
if not okAvatar then
	print("[BRR_Gallery] no avatar in edit mode (" .. tostring(avatar) .. "); stand-in arms")
	avatar = nil
end

Lighting.ClockTime = 14
Lighting.Brightness = 2.4
Lighting.ExposureCompensation = 0.1

-- A plain room: floor, a wall far ahead with a target on it, so the gun is judged against something.
local function scene(folder)
	local function block(size, position, color, material)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.Position = position
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		part.Parent = folder
		return part
	end
	block(Vector3.new(80, 1, 120), ORIGIN + Vector3.new(0, -5.5, -40), Color3.fromRGB(116, 112, 104), Enum.Material.Concrete)
	block(Vector3.new(80, 40, 1), ORIGIN + Vector3.new(0, 10, -60), Color3.fromRGB(172, 170, 164), Enum.Material.Plaster)
	block(Vector3.new(4, 4, 0.2), ORIGIN + Vector3.new(0, 0, -59.4), Color3.fromRGB(210, 60, 50))
	block(Vector3.new(2, 2, 0.2), ORIGIN + Vector3.new(0, 0, -59.2), Color3.fromRGB(240, 236, 226))
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	if not SHOW or table.find(SHOW, id) then
		table.insert(ids, id)
	end
end
table.sort(ids, function(a, b)
	local da, db = WeaponData.Get(a), WeaponData.Get(b)
	if da.style ~= db.style then
		return da.style < db.style
	end
	return a < b
end)

-- The first capture of a run can come out as the second view, so it goes to a throwaway scene.
local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			scene(folder)
			camera.FieldOfView = 70
			camera.CFrame = CFrame.new(ORIGIN)
		end,
	},
}
for _, id in ipairs(ids) do
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
				camera.FieldOfView = moment[3] or 70
				camera.CFrame = eye
			end,
		})
	end
end

return views
