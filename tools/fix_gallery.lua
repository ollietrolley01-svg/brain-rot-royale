-- Fix gallery: close-ups of gun model fixes, before and after, in one run; then the first-person view.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/fix_gallery.lua -OutDir <folder> -PlaceFile <place>
--
-- "After" is the place's own GunModels. "Before" needs an older GunModels in the same place, as a
-- ModuleScript named GunModelsBefore in ReplicatedStorage.Shared (build a scratch copy of the source tree
-- with the old file added under that name); without one, only the "after" shots are taken. Guns are built
-- the way the hand, the floor and the podium build them, anchored in a lit empty spot, and SHOTS frames
-- each fix: the point to look at (millimetres in the gun's frame: bore y=0, trigger z=0, facing -Z, +X
-- right), the camera's direction from it, its distance and field of view.
--
-- VM lists guns shown in first person with the game's own Viewmodel at the hip and aimed, and
-- VM_RELOAD the ones caught halfway through the reload (a revolver's crane swung out).
--
-- If _G.BRR_MEASURE is a list of functions, a first "measure" view runs them before any shot (a merged
-- run: probes that print "[BRR_Gallery] note ..." lines).

local SHOTS = {
	{ "PawnshopNine", "quarter", Vector3.new(0, -35, -10), Vector3.new(0.8, 0.3, -0.5), 520, 40 },
	{ "PawnshopNine", "side", Vector3.new(0, -35, -10), Vector3.new(1, 0.05, 0), 520, 40 },
	{ "PawnshopNine", "gripjoint", Vector3.new(0, -32, 30), Vector3.new(-0.75, -0.05, -0.65), 230, 40 },
	{ "PawnshopNine", "extension", Vector3.new(0, -115, 66), Vector3.new(0.65, -0.55, 0.5), 230, 40 },
	{ "RustbeltMarshal", "quarter", Vector3.new(0, -25, -60), Vector3.new(0.8, 0.3, -0.5), 620, 40 },
	{ "RustbeltMarshal", "side", Vector3.new(0, -25, -60), Vector3.new(1, 0.05, 0), 620, 40 },
	{ "RustbeltMarshal", "cylinder", Vector3.new(0, -10, -25), Vector3.new(0.9, 0.25, -0.35), 240, 40 },
	{ "RustbeltMarshal", "backstrap", Vector3.new(0, -40, 40), Vector3.new(0.65, 0.2, 0.75), 260, 40 },
	{ "SigmaRevolver", "quarter", Vector3.new(0, -25, -80), Vector3.new(0.8, 0.3, -0.5), 700, 40 },
	{ "SahurPistol", "quarter", Vector3.new(0, -40, -20), Vector3.new(0.8, 0.3, -0.5), 560, 40 },
	{ "AdminOverride", "quarter", Vector3.new(0, -40, -20), Vector3.new(0.8, 0.3, -0.5), 560, 40 },
	{ "PocketPopper", "quarter", Vector3.new(0, -40, -10), Vector3.new(-0.8, 0.3, -0.5), 520, 40 },
	{ "CappuccinaLauncher", "mount", Vector3.new(-36, 22, -75), Vector3.new(-1, 0.12, 0), 330, 42 },
	{ "CappuccinaLauncher", "mountFront", Vector3.new(-36, 22, -75), Vector3.new(-0.8, 0.35, -0.6), 330, 42 },
	{ "LarilaSniper", "ocular", Vector3.new(0, 88, 110), Vector3.new(0.6, 0.35, 0.75), 260, 40 },
	{ "AuraAuditRifle", "holo", Vector3.new(0, 68, -20), Vector3.new(0.4, 0.3, 0.9), 230, 40 },
	{ "NonnaDoubleBarrel", "rib", Vector3.new(0, 10, -300), Vector3.new(0.7, 0.3, -0.6), 320, 40 },
	{ "CrocodiloRifle", "sling", Vector3.new(0, -85, 312), Vector3.new(0.7, -0.5, 0.25), 220, 40 },
	{ "DeluluRailgun", "foregrip", Vector3.new(0, -40, -357), Vector3.new(-0.7, -0.4, 0.3), 330, 40 },
	{ "TralalaThumper", "crane", Vector3.new(-20, -120, -90), Vector3.new(-0.8, -0.3, -0.2), 480, 40 },
	{ "GrassToucherDMR", "frontsight", Vector3.new(0, 20, -574), Vector3.new(0.7, 0.3, -0.6), 200, 40 },
}
local VM = { "PawnshopNine", "RustbeltMarshal", "SahurPistol", "NonnaDoubleBarrel", "CrocodiloRifle", "AuraAuditRifle", "CameloLMG" }
local VM_RELOAD = { "RustbeltMarshal", "TralalaThumper" }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))
local beforeModule = Shared:FindFirstChild("GunModelsBefore")
local GunModelsBefore = beforeModule and require(beforeModule) or nil

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
	part.Size = Vector3.new(80, 80, 1)
	part.CFrame = CFrame.lookAt(position, position + facing)
	part.Color = Color3.fromRGB(196, 204, 210)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = folder
end

local function build(module, folder, id)
	local def = WeaponData.Get(id)
	local model = module.Build(def, Rarity.Color(def.rarity), Enum.Material.Metal)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	model:PivotTo(CFrame.new(ORIGIN))
	model.Parent = folder
end

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			backdrop(folder, ORIGIN + Vector3.new(0, 0, -20), Vector3.new(0, 0, 1))
			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, 5), ORIGIN)
		end,
	},
}

if type(_G.BRR_MEASURE) == "table" then
	table.insert(views, {
		name = "measure",
		setup = function(folder, camera)
			for index, fn in ipairs(_G.BRR_MEASURE) do
				local ok, err = pcall(fn)
				if not ok then
					print("[BRR_Gallery] note measure " .. index .. " failed: " .. tostring(err))
				end
			end
			backdrop(folder, ORIGIN + Vector3.new(0, 0, -20), Vector3.new(0, 0, 1))
			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, 5), ORIGIN)
		end,
	})
end

for _, shot in ipairs(SHOTS) do
	local id, label, focus, direction, distance, fov = shot[1], shot[2], shot[3], shot[4].Unit, shot[5], shot[6]
	local passes = GunModelsBefore and { { "before", GunModelsBefore }, { "after", GunModels } } or { { "after", GunModels } }
	for _, pass in ipairs(passes) do
		table.insert(views, {
			name = id .. "_" .. label .. "_" .. pass[1],
			setup = function(folder, camera)
				build(pass[2], folder, id)
				local target = ORIGIN + focus * MM
				backdrop(folder, target - direction * 12, direction)
				camera.FieldOfView = fov
				camera.CFrame = CFrame.lookAt(target + direction * distance * MM, target)
			end,
		})
	end
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

local function vmView(id, label, state, fov)
	table.insert(views, {
		name = "vm_" .. id .. "_" .. label,
		setup = function(folder, camera)
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
		end,
	})
end
for _, id in ipairs(VM) do
	vmView(id, "hip", { aim = 0 }, 70)
	vmView(id, "ads", { aim = 1 }, 70 * 0.64)
end
for _, id in ipairs(VM_RELOAD) do
	vmView(id, "reload45", { clip = "reload", progress = 0.45, roundsLeft = 0 }, 70)
end

table.insert(views, {
	name = "cleanup",
	setup = function(folder, camera)
		camera.CFrame = CFrame.new(ORIGIN)
	end,
})

return views
