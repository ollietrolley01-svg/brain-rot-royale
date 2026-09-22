-- Every accessory worn, before and after the design pass, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/accessory_gallery.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- Each accessory gets a pair shot -- the old design beside the new one, same camera, each rig labelled
-- OLD or NEW over its head -- and then a closer three-quarter of the new one on its own. The labels are
-- in the picture because which side is which depends on where the camera stands: the first run of this
-- gallery photographed the rigs face-on, so the rig at -X appeared on the right of the image and a
-- caption saying "old on the left" was wrong about its own screenshot. The "before" comes from a copy
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
local function wear(id, at, yaw, which, parent, label)
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

	if label then
		local post = Instance.new("Part")
		post.Name = "Label"
		post.Size = V(0.2, 0.2, 0.2)
		post.Transparency = 1
		post.Anchored = true
		post.CanCollide = false
		post.CFrame = CFrame.new(at + V(0, 4.6, 0))
		post.Parent = parent

		local billboard = Instance.new("BillboardGui")
		billboard.Size = UDim2.fromOffset(150, 44)
		billboard.AlwaysOnTop = true
		billboard.Parent = post

		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.GothamBold
		text.TextSize = 26
		text.TextColor3 = label == "NEW" and Color3.fromRGB(120, 240, 150) or Color3.fromRGB(245, 180, 120)
		text.TextStrokeTransparency = 0.1
		text.Text = label
		text.Parent = billboard
	end

	return rig
end

local views = {}
local function add(name, setup)
	-- No `hold` here on purpose: the plugin uses `view.hold or HOLD`, so a view that names its
	-- own hold ignores gallery.ps1's -Hold. Leaving it out lets the caller slow the run down
	-- when the machine is busy, which is when the capture loop falls behind the plugin.
	table.insert(views, { name = name, settle = 1.2, setup = setup })
end

-- `from` is which side of the rig the camera stands on: -1 in front, +1 behind. It is a field rather
-- than something derived from the anchor, because deriving it is how the first run went wrong -- a
-- back-anchored rig was turned to face away AND the camera moved round to the far side, which cancelled
-- out and photographed the pizza slice from the front, where there is no pizza.
local FRAMING = {
	HeadTop = { height = 3.15, aim = 3.05, distance = 4.6, lift = 0.7, yaw = 0, from = -1 },
	Face = { height = 2.95, aim = 2.95, distance = 3.6, lift = 0.25, yaw = 0, from = -1 },
	Back = { height = 2.9, aim = 2.2, distance = 5.6, lift = 0.5, yaw = 0, from = 1 },
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
			wear(id, HIGH + V(-1.6, 0, 0), frame.yaw, "old", folder, "OLD")
			wear(id, HIGH + V(1.6, 0, 0), frame.yaw, "new", folder, "NEW")
			camera.FieldOfView = 34
			camera.CFrame = CFrame.lookAt(HIGH + V(0, frame.height + frame.lift, frame.from * (frame.distance + 1.8)),
				HIGH + V(0, frame.aim, 0))
			note(string.format("%s: both rigs labelled in shot%s", id, changed and "" or " (same piece count)"))
		end)
	end

	-- And the new one alone, three-quarters on, close.
	add(id .. "_new", function(folder, camera)
		wear(id, HIGH, frame.yaw, "new", folder)
		camera.FieldOfView = 28
		camera.CFrame = CFrame.lookAt(
			HIGH + V(frame.from * frame.distance * 0.55, frame.height + frame.lift, frame.from * frame.distance * 0.8),
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
			-- The lineup camera stands in front of the row, so a back-anchored rig turns round in this
			-- shot only -- otherwise its backpack faces away and the cell shows an empty back.
			local yaw = item.anchor == "Back" and math.pi or 0
			wear(id, HIGH + V((shown - 3) * 3.4, 0, 0), yaw, "new", folder)
			shown += 1
		end
		camera.FieldOfView = 36
		camera.CFrame = CFrame.lookAt(HIGH + V(0, 3.6, -15.5), HIGH + V(0, 2.9, 0))
	end)
end

return views
