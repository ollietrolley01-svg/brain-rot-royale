-- SUPERSEDED by tools/accessory_gallery.lua, which does before-and-after for every accessory from a
-- real copy of the old CosmeticData rather than rebuilding one design from numbers written down here.
--
-- Do not trust this file's "before": it reconstructs the old crown by matching piece sizes (0.36 teeth,
-- band at 0.54), and the crown is no longer two rings of blocks at all, so those matches now find
-- nothing and the two halves of the comparison are the same crown. Kept only for the note it prints
-- about how many pieces the build pass moves, which was the measurement that caught the fault.
--
-- Crown of Rot, worn, before and after the 2026-09-18 fix, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/crown_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- The crown's ten teeth used to be 0.36 wide on a 0.54 radius, where each tooth's slice of the ring
-- is only 0.339, so neighbours overlapped in plane with their tops and bottoms in one plane (pieces
-- turn about Y, which never turns those faces). AccessoryService runs ZFight over a worn accessory,
-- and it resolved those coplanar tops by stepping each tooth up in turn — a spiral staircase rather
-- than a crown, on every player who wore it.
--
-- This renders it on a head both ways and prints, as notes, how many pieces the pass moves and by how
-- much: build with ZFight off, build again with it on, and compare piece by piece. The "before" is
-- rebuilt here from the old numbers, so both sit in one run.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local AccessoryService = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("AccessoryService"))

local V = Vector3.new

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local HIGH = V(0, 1200, -2600)
local ITEM = "CrownOfRot"

-- The crown as it shipped: teeth 0.36 wide, and the band on the teeth's own radius.
local fixed = CosmeticData.Items[ITEM].parts
local before = {}
for _, piece in ipairs(fixed) do
	local copy = {}
	for key, value in pairs(piece) do
		copy[key] = value
	end
	if copy.size and math.abs(copy.size.X - 0.32) < 1e-3 and math.abs(copy.size.Y - 0.32) < 1e-3 then
		copy.size = V(0.36, copy.size.Y, copy.size.Z)
	elseif copy.size and math.abs(copy.size.X - 0.12) < 1e-3 then
		-- Back from radius 0.62 to 0.54, along the piece's own outward axis.
		copy.offset = copy.offset * CFrame.new(0, 0, -0.08)
	end
	table.insert(before, copy)
end

local function character()
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and rig then
		return rig
	end
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = V(2, 2, 1)
	root.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = V(1.2, 1.2, 1.2)
	head.CFrame = CFrame.new(0, 2.6, 0)
	head.Parent = model
	Instance.new("Humanoid").Parent = model
	model.PrimaryPart = root
	return model
end

-- Wears the crown on a fresh rig at `at` and returns the rig and its crown pieces.
local function wear(parts, at, parent)
	CosmeticData.Items[ITEM].parts = parts
	local rig = character()
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	rig:PivotTo(CFrame.new(at))
	rig.Parent = parent
	AccessoryService.Attach(rig, ITEM)
	local worn = rig:FindFirstChild("CosmeticAccessory")
	local pieces = {}
	if worn then
		for _, part in ipairs(worn:GetDescendants()) do
			if part:IsA("BasePart") then
				table.insert(pieces, part)
			end
		end
	end
	return rig, pieces
end

-- How many pieces the build's z-fight pass moves or resizes, and the worst move.
local function measure(label, parts, folder)
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local rawRig, rawPieces = wear(parts, HIGH + V(0, 0, 60), folder)
	ZFight.Enabled = wasEnabled
	local fixedRig, fixedPieces = wear(parts, HIGH + V(0, 0, 90), folder)
	-- Compared in each rig's own head frame: the two rigs stand apart, so world positions would differ
	-- by the distance between them and every piece would read as moved.
	local rawHead = rawRig:FindFirstChild("Head")
	local fixedHead = fixedRig:FindFirstChild("Head")
	local changed, worst = 0, 0
	local tallest, shortest = 0, math.huge
	for index = 1, math.min(#rawPieces, #fixedPieces) do
		local a, b = rawPieces[index], fixedPieces[index]
		local moved = (rawHead.CFrame:PointToObjectSpace(a.Position) - fixedHead.CFrame:PointToObjectSpace(b.Position)).Magnitude
		local grew = (a.Size - b.Size).Magnitude
		if moved > 0.001 or grew > 0.001 then
			changed += 1
			worst = math.max(worst, moved, grew)
		end
		tallest = math.max(tallest, b.Size.Y)
		shortest = math.min(shortest, b.Size.Y)
	end
	note(string.format("%s: %d pieces, the build pass changed %d of them, worst %.3f; worn piece heights %.2f to %.2f", label, #fixedPieces,
		changed, worst, shortest, tallest))
	rawRig:Destroy()
	fixedRig:Destroy()
end

local views = {}
local function add(name, setup)
	table.insert(views, { name = name, settle = 1.2, hold = 2, setup = setup })
end

-- Each view wears one version on a fresh rig and frames the head.
local function crownViews(label, parts, offset)
	add(label .. "_front", function(folder, camera)
		local at = HIGH + offset
		wear(parts, at, folder)
		camera.FieldOfView = 26
		camera.CFrame = CFrame.lookAt(at + V(0, 3.4, -4.2), at + V(0, 3.1, 0))
	end)
	add(label .. "_side", function(folder, camera)
		local at = HIGH + offset
		wear(parts, at, folder)
		camera.FieldOfView = 26
		camera.CFrame = CFrame.lookAt(at + V(-4.0, 3.6, -1.4), at + V(0, 3.05, 0))
	end)
	add(label .. "_above", function(folder, camera)
		local at = HIGH + offset
		wear(parts, at, folder)
		camera.FieldOfView = 30
		camera.CFrame = CFrame.lookAt(at + V(1.6, 5.2, -2.6), at + V(0, 3.05, 0))
	end)
end

crownViews("crown_before", before, V(0, 0, 0))
crownViews("crown_after", fixed, V(30, 0, 0))

-- The numbers, once, in the first view's folder.
add("crown_measurements", function(folder, camera)
	measure("before (as shipped)", before, folder)
	measure("after (0.32 teeth, band at 0.62)", fixed, folder)
	CosmeticData.Items[ITEM].parts = fixed
	camera.FieldOfView = 30
	camera.CFrame = CFrame.lookAt(HIGH + V(0, 3.4, -5), HIGH + V(0, 3.1, 0))
end)

return views
