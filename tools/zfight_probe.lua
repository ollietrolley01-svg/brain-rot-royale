-- Probe for tools/runtest.ps1 -Probe: exercises ZFight on a few builders and prints what it
-- did, plus a terrain experiment. Runs inside Studio in edit mode (no Run mode).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local CrateModels = require(Shared:WaitForChild("CrateModels"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local WeaponService = require(modules:WaitForChild("WeaponService"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))

local function dump(label, model)
	print("[PROBE] " .. label)
	for _, p in ipairs(ZFight.Parts({ model }, true)) do
		print(string.format("[PROBE]   %-14s size %s pos %s", p.Name, tostring(p.Size), tostring(p.Position)))
	end
end

local function trial(label, build, trace, showParts)
	ZFight.Enabled = false
	local model = build()
	ZFight.Enabled = true
	if showParts then
		dump(label .. " before", model)
	end
	ZFight.Trace = trace or false
	local before = ZFight.Scan({ model })
	local report = ZFight.Fix({ model }, { all = true })
	ZFight.Trace = false
	local after = ZFight.Scan({ model })
	print(string.format("[PROBE] %s: fighting before %d; moved %d resized %d passes %d; remaining %d / rescan %d",
		label, #before, report.moved, report.resized, report.passes, #report.remaining, #after))
	for _, line in ipairs(ZFight.Describe(after, function() return label end, 30)) do
		print("[PROBE]   still " .. line)
	end
	if showParts then
		dump(label .. " after", model)
	end
	model:Destroy()
end

trial("crate", function() return (CrateModels.Crate("Common")) end, true, false)
trial("chest", function() return (CrateModels.Chest(CFrame.new(0, 100, 0))) end, true, false)
trial("PocketPopper", function() return (WeaponService.BuildGunModel(WeaponData.Get("PocketPopper"), Rarity.Color("Common"), Enum.Material.Metal)) end, true, false)
trial("TralalaShotgun", function() return (WeaponService.BuildGunModel(WeaponData.Get("TralalaShotgun"), Rarity.Color("Uncommon"), Enum.Material.Metal)) end, false, false)
for _, name in ipairs({ "Patatina Fritta", "Tralalero Tralala" }) do
	local def = BrainrotData.Get(name)
	if def then
		trial(name, function() return BrainrotModels.Build(def, { flair = false }) end, name == "Tralalero Tralala", false)
	end
end

-- Terrain: does a rotated paint FillBlock (-4..0) leave the surface at 0, or raise it? (Fills
-- take a moment to become raycastable, so wait before asking.)
local terrain = workspace.Terrain
terrain:Clear()
task.wait(0.5)
terrain:FillBlock(CFrame.new(0, -8, 0), Vector3.new(400, 16, 400), Enum.Material.Grass)
task.wait(1)
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { terrain }
local function probeAt(label, points)
	for _, point in ipairs(points) do
		local hit = workspace:Raycast(point + Vector3.new(0, 300, 0), Vector3.new(0, -600, 0), params)
		print(string.format("[PROBE] terrain %s at (%d, %d): %s %s", label, point.X, point.Z, hit and string.format("%.3f", hit.Position.Y) or "miss",
			hit and tostring(hit.Material) or ""))
	end
end
probeAt("base", { Vector3.new(0, 0, 0), Vector3.new(150, 0, 150) })
terrain:FillBlock(CFrame.new(60, -2, 60) * CFrame.Angles(0, 0.37, 0), Vector3.new(60, 4, 40), Enum.Material.Pavement)
terrain:FillBlock(CFrame.new(-60, -2, -60), Vector3.new(60, 4, 40), Enum.Material.Pavement)
task.wait(1)
probeAt("painted", { Vector3.new(60, 0, 60), Vector3.new(70, 0, 55), Vector3.new(-60, 0, -60), Vector3.new(-50, 0, -70), Vector3.new(0, 0, 0) })
-- ReplaceMaterial as the alternative: material only, occupancy untouched.
local region = Region3.new(Vector3.new(100, -4, -100), Vector3.new(160, 0, -60)):ExpandToGrid(4)
terrain:ReplaceMaterial(region, 4, Enum.Material.Grass, Enum.Material.Pavement)
task.wait(1)
probeAt("replaced", { Vector3.new(130, 0, -80), Vector3.new(110, 0, -70) })
terrain:Clear()
