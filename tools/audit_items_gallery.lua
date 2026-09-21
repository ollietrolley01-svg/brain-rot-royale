-- Item gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/audit_items_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- The drop-in / glider canopy the way players see it: the wing as it was before the 2026-09-17 fix
-- and as it is now, at the in-game scale 3, from below against the sky (where slits show as light),
-- from the side and from above; then hung over a character through MovementService.BotDrop, the
-- same attachCanopy path every drop-in uses. Then every item at 3 angles.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local HIGH = Vector3.new(0, 1400, -3000)

local function legacyCanopy(scale)
	local model = Instance.new("Model")
	model.Name = "LegacyCanopy"
	local color = ItemData.Get("RotGlider").color
	local DARK = Color3.fromRGB(40, 42, 48)
	local V = Vector3.new
	local function piece(name, size, cframe, pieceColor, material)
		local part = Instance.new("Part")
		part.Name = name
		local frame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
		part.Size = size * scale
		part.CFrame = CFrame.new(frame.Position * scale) * frame.Rotation
		part.Color = pieceColor
		part.Material = material or Enum.Material.SmoothPlastic
		part.Anchored = true
		part.CanCollide = false
		part.Parent = model
		return part
	end
	local body = piece("Body", V(1.4, 0.12, 0.12), V(0, 0, 0), DARK, Enum.Material.Metal)
	local mint = Color3.fromRGB(120, 230, 160)
	for index = 0, 8 do
		local t = index / 8 - 0.5
		local angle = t * math.rad(150)
		local at = CFrame.new(math.sin(angle) * 2.3, math.cos(angle) * 2.3 - 2.3 + 2.6, 0) * CFrame.Angles(0, 0, -angle)
		piece("Cell", V(0.62, 0.16, 1.6), at, index % 2 == 0 and color or mint, Enum.Material.Fabric)
		piece("CellRib", V(0.04, 0.2, 1.62), at * CFrame.new(0.31, 0, 0), DARK, Enum.Material.Fabric)
		piece("Glow", V(0.62, 0.06, 0.08), at * CFrame.new(0, 0.02, -0.82), color, Enum.Material.Neon)
		if index % 2 == 0 then
			local anchor = at * CFrame.new(0, -0.1, 0.4)
			local line = CFrame.lookAt(anchor.Position:Lerp(V(t * 0.6, 0, 0), 0.5), anchor.Position)
			piece("Line", V(0.03, 0.03, (anchor.Position - V(t * 0.6, 0, 0)).Magnitude), line, Color3.fromRGB(236, 232, 220), Enum.Material.Fabric)
		end
	end
	for _, x in ipairs({ -0.55, 0.55 }) do
		piece("Strap", V(0.12, 1.1, 0.12), CFrame.new(x, -0.55, 0) * CFrame.Angles(0, 0, x * 0.3), DARK, Enum.Material.Fabric)
	end
	ZFight.Fix({ model }, { all = true })
	model.PrimaryPart = body
	body.PivotOffset = body.CFrame:Inverse()
	return model
end

local views = {}
local function add(name, setup)
	table.insert(views, { name = name, settle = 1.2, hold = 2, setup = setup })
end

local function canopyShots(label, build)
	local centre = HIGH
	add(label .. "_below", function(folder, camera)
		local model = build(3)
		model:PivotTo(CFrame.new(centre))
		model.Parent = folder
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(0.5, -1.5, -3.5), centre + Vector3.new(0, 7.8, 0))
	end)
	add(label .. "_side", function(folder, camera)
		local model = build(3)
		model:PivotTo(CFrame.new(centre))
		model.Parent = folder
		camera.FieldOfView = 55
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(-3, 5, -17), centre + Vector3.new(0, 5, 0))
	end)
	add(label .. "_above", function(folder, camera)
		local model = build(3)
		model:PivotTo(CFrame.new(centre))
		model.Parent = folder
		camera.FieldOfView = 55
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(2, 20, -10), centre + Vector3.new(0, 7, 0))
	end)
end

canopyShots("canopy_before", legacyCanopy)
canopyShots("canopy_after", function(scale)
	return ItemModels.Build("RotGlider", { scale = scale, open = true })
end)

-- On a character, through the real attach path.
local function character()
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and rig then
		return rig, "R15 rig"
	end
	-- Fallback stand-in with what BotDrop needs: a root, a head and a humanoid.
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.CFrame = CFrame.new(0, 2.6, 0)
	head.Parent = model
	Instance.new("Humanoid").Parent = model
	model.PrimaryPart = root
	return model, "stand-in (no rig in edit mode)"
end

local attached = nil
add("canopy_on_character_front", function(folder, camera)
	local MovementService = require(modules:WaitForChild("MovementService"))
	local rig, kind = character()
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	rig:PivotTo(CFrame.new(HIGH + Vector3.new(60, 0, 0)))
	rig.Parent = folder
	local ok = MovementService.BotDrop(rig, HIGH + Vector3.new(60, -200, 0), function() end)
	attached = rig
	note(string.format("canopy on %s via MovementService.BotDrop: %s, canopy present %s", kind, tostring(ok), tostring(rig:FindFirstChild("GliderCanopy") ~= nil)))
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt(HIGH + Vector3.new(63, 5, -20), HIGH + Vector3.new(60, 5, 0))
end)
add("canopy_on_character_below", function(_, camera)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.lookAt(HIGH + Vector3.new(61, -6, -6), HIGH + Vector3.new(60, 10, 0))
	local MovementService = require(modules:WaitForChild("MovementService"))
	task.delay(3, function()
		pcall(MovementService.Clear)
	end)
end)

-- Every item, three angles, at pickup scale.
for _, id in ipairs(ItemData.Order) do
	for side, direction in ipairs({ Vector3.new(0.15, 0.25, -1), Vector3.new(1, 0.45, 0.35), Vector3.new(-0.55, 0.9, 0.7) }) do
		add(string.format("item_%s_%d", id, side), function(folder, camera)
			local model = ItemModels.Build(id, { scale = 1.25 })
			local at = HIGH + Vector3.new(-80, 0, 0)
			model:PivotTo(CFrame.new(at))
			model.Parent = folder
			local box, size = model:GetBoundingBox()
			local radius = size.Magnitude / 2
			camera.FieldOfView = 35
			camera.CFrame = CFrame.lookAt(box.Position + direction.Unit * radius / math.tan(math.rad(17.5)) * 1.05, box.Position)
		end)
	end
end

return views
