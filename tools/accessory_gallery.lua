-- Every accessory worn, before and after the design pass, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/accessory_gallery.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- Each accessory gets a pair shot -- the old design on the left, the new one on the right, same
-- camera -- and then a closer three-quarter of the new one on its own. The "before" comes from a copy
-- of the old CosmeticData dropped into the private build tree as Shared/CosmeticDataOld, so the old
-- designs are the actual shipped numbers rather than my transcription of them. Without that module
-- the gallery still runs and renders the new designs only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local AccessoryService = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("AccessoryService"))

local oldModule = Shared:FindFirstChild("CosmeticDataOld")
local Old = nil
if oldModule then
	local ok, loaded = pcall(require, oldModule)
	Old = ok and loaded or nil
end

local V = Vector3.new

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local HIGH = V(0, 1200, -2600)

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
	local torso = Instance.new("Part")
	torso.Name = "UpperTorso"
	torso.Size = V(2, 1.6, 1)
	torso.CFrame = CFrame.new(0, 1.4, 0)
	torso.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = V(1.2, 1.2, 1.2)
	head.CFrame = CFrame.new(0, 2.6, 0)
	head.Parent = model
	Instance.new("Humanoid").Parent = model
	model.PrimaryPart = root
	return model
end

-- Wears `id` on a fresh rig at `at`, facing `yaw`. `which` is "new" or "old"; "old" swaps the entry
-- for the shipped one for the length of the attach and puts it back.
local function wear(id, at, yaw, which, parent)
	local rig = character()
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	rig:PivotTo(CFrame.new(at) * CFrame.Angles(0, yaw or 0, 0))
	rig.Parent = parent

	local restore = CosmeticData.Items[id]
	if which == "old" and Old and Old.Items[id] then
		CosmeticData.Items[id] = Old.Items[id]
	end
	AccessoryService.Attach(rig, id)
	CosmeticData.Items[id] = restore
	return rig
end

local views = {}
local function add(name, setup)
	table.insert(views, { name = name, settle = 1.2, hold = 2, setup = setup })
end

-- Head-anchored pieces sit around y+3.05 on an R15 rig; back-anchored ones around y+2.4, seen from
-- behind. `turn` faces the rig away from the camera for those.
local FRAMING = {
	HeadTop = { height = 3.15, aim = 3.05, distance = 4.6, lift = 0.7, yaw = 0 },
	Face = { height = 2.95, aim = 2.95, distance = 3.6, lift = 0.25, yaw = 0 },
	Back = { height = 2.5, aim = 2.3, distance = 5.2, lift = 0.6, yaw = math.pi },
}

local ids = CosmeticData.OfKind("Accessory")
note(string.format("%d accessories, before %s", #ids, Old and "from Shared/CosmeticDataOld" or "UNAVAILABLE (new designs only)"))

for _, id in ipairs(ids) do
	local item = CosmeticData.Get(id)
	local frame = FRAMING[item.anchor] or FRAMING.HeadTop
	local changed = Old and Old.Items[id] and #Old.Items[id].parts ~= #item.parts

	-- Old on the left, new on the right, one camera on both.
	if Old and Old.Items[id] then
		add(id .. "_pair", function(folder, camera)
			wear(id, HIGH + V(-1.6, 0, 0), frame.yaw, "old", folder)
			wear(id, HIGH + V(1.6, 0, 0), frame.yaw, "new", folder)
			camera.FieldOfView = 34
			local side = frame.yaw == 0 and -1 or 1
			camera.CFrame = CFrame.lookAt(HIGH + V(0, frame.height + frame.lift, side * (frame.distance + 1.8)),
				HIGH + V(0, frame.aim, 0))
			note(string.format("%s: left is the old design, right is the new one%s", id, changed and "" or " (same piece count)"))
		end)
	end

	-- And the new one alone, three-quarters on, close.
	add(id .. "_new", function(folder, camera)
		wear(id, HIGH, frame.yaw, "new", folder)
		camera.FieldOfView = 28
		local side = frame.yaw == 0 and -1 or 1
		camera.CFrame = CFrame.lookAt(HIGH + V(side * frame.distance * 0.55, frame.height + frame.lift, side * frame.distance * 0.8),
			HIGH + V(0, frame.aim, 0))
	end)
end

-- All of them in a row, new designs, for one sheet that shows the set.
for half = 0, 1 do
	add("lineup_" .. (half == 0 and "a" or "b"), function(folder, camera)
		local from = half * 7 + 1
		local shown = 0
		for index = from, math.min(from + 6, #ids) do
			local id = ids[index]
			local item = CosmeticData.Get(id)
			local yaw = (FRAMING[item.anchor] or FRAMING.HeadTop).yaw
			wear(id, HIGH + V((shown - 3) * 3.4, 0, 0), yaw, "new", folder)
			shown += 1
		end
		camera.FieldOfView = 36
		camera.CFrame = CFrame.lookAt(HIGH + V(0, 3.6, -15.5), HIGH + V(0, 2.9, 0))
	end)
end

return views
