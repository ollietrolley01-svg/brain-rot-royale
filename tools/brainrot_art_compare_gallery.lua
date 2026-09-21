-- Brainrot ART COMPARISON gallery: what ships today (BrainrotModels) beside the original remake set
-- (BrainrotModelsRemake) and, for the established meme names, the Creator Store candidate
-- (BrainrotAssetCandidates) -- same pad, same camera, same lighting, plus the sizes they are really
-- seen at: companion beside a character (x0.55), menu card portraits (106 / 48 px ViewportFrames),
-- lobby statue (x1.6), plaza statue (x2.6), and the mixed line-ups a swap would produce.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 `
--     -Gallery tools/brainrot_art_compare_gallery.lua -OutDir <folder> -Hold 1
--
-- It changes nothing: production still requires BrainrotModels only. NOT IN THE BUILT PLACE as art:
-- the remake module is in the place but nothing requires it; Store assets are fetched here only.
--
-- It doubles as the measurement run (rule 8b: numbers AND a render):
--   audit_numbers     every BrainrotData entry through both builders: built / nil, PrimaryPart, parts
--                     (all, visible, nested), base offset against each builder's Metrics AND the
--                     remake stood by the CURRENT metrics (what a Build-only switch would do), rig
--                     readable by CompanionAnimations, portrait crop + fill in a square ViewportFrame.
--                     PERMANENT PLANTED FAULT: a builder that returns nil / errors / builds no parts
--                     for three entries must be reported as three failures.
--   asset_check       InsertService:LoadAsset for every candidate FROM THIS HARNESS (the open
--                     question), then the security audit on the UNPARENTED package: every
--                     LuaSourceContainer (Disabled ones too), Remotes, Bindables, Actors, suspicious
--                     strings in Source / Name / StringValue / attributes, non-geometry classes, then
--                     strip, RE-SCAN the kept model, and print the bake data (mesh + texture ids).
--                     PERMANENT PLANTED BACKDOOR: a Disabled Script holding require(123456) four
--                     containers deep, a RemoteEvent beside it and a base64-looking StringValue blob
--                     are planted in a copy; the scan must flag all three and the strip must remove
--                     them. Instances EXAMINED are printed beside instances FLAGGED.
-- Every render view asserts each stood model is IN FRAME (camera-space distance and angle off
-- centre, against the vertical and horizontal half-FOV) and prints it.

local ONLY = nil -- e.g. { "canon_", "portraits" } to shoot a subset

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local InsertService = game:GetService("InsertService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local Current = require(Shared:WaitForChild("BrainrotModels"))
local Remake = require(Shared:WaitForChild("BrainrotModelsRemake"))
local CompanionAnimations = require(Shared:WaitForChild("CompanionAnimations"))
local Candidates = require(Shared:WaitForChild("BrainrotAssetCandidates"))

local ORIGIN = Vector3.new(6000, 400, 6000)
local GUI_NAME = "BRR_ArtCompareGui"
local COMPANION_SCALE = 0.55 -- CompanionService SCALE
local FOLLOW_OFFSET = Vector3.new(2.8, 2.6, 2.4) -- CompanionService FOLLOW_OFFSET
local OVERRIDE_HEIGHT = 2.6 -- BrainrotModels OVERRIDE_HEIGHT: how an override model is sized
local GOLD = Color3.fromRGB(255, 200, 60)

local CANONICAL = {
	"Tung Tung Tung Sahur", "Bombardiro Crocodilo", "Tralalero Tralala", "Chimpanzini Bananini",
	"Boneca Ambalabu", "Lirili Larila", "Ballerina Cappuccina", "Brr Brr Patapim",
	"Frigo Camelo", "Bombombini Gusini", "La Vacca Saturno Saturnita", "Golden Sahur",
}
local ORIGINALS = { "Trippi Troppi", "Fenice Pixelata", "Kraken Caramello", "Oracolo Lavatrice",
	"Faro Guardiano", "Cavaliere Lattina" }

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local BUILDERS = {
	{ tag = "cur", label = "CURRENT", module = Current },
	{ tag = "rem", label = "REMAKE", module = Remake },
}

--------------------------------------------------------------------------------
-- Scene helpers
--------------------------------------------------------------------------------

local function clearGui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
end

local function pad(folder, centre, width, depth)
	local floor = Instance.new("Part")
	floor.Name = "Pad"
	floor.Anchored = true
	floor.Size = Vector3.new(width, 1, depth)
	floor.CFrame = CFrame.new(centre - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(150, 152, 158)
	floor.Material = Enum.Material.SmoothPlastic
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = folder
	local wall = floor:Clone()
	wall.Name = "Backdrop"
	wall.Size = Vector3.new(width, 40, 1)
	wall.CFrame = CFrame.new(centre + Vector3.new(0, 20, depth / 2))
	wall.Color = Color3.fromRGB(196, 200, 208)
	wall.Parent = folder
end

-- A readable caption standing on the pad in front of a model (Front face = -Z = towards the camera).
local function plate(folder, text, position, width)
	local part = Instance.new("Part")
	part.Name = "Plate"
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(width or 4.6, 0.9, 0.12)
	part.CFrame = CFrame.new(position)
	part.Color = Color3.fromRGB(34, 36, 42)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = folder
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(460, 90)
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(245, 245, 240)
	label.Text = text
	label.Parent = gui
	return part
end

-- How far a part reaches along a world direction from its centre, from its real shape (from
-- tools/brainrot_models_probe.lua).
local function support(part, direction)
	local cf = part.CFrame
	local size = part.Size
	local dx, dy, dz = cf.RightVector:Dot(direction), cf.UpVector:Dot(direction), cf.LookVector:Dot(direction)
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	if mesh and mesh.MeshType == Enum.MeshType.Sphere then
		local a, b, c = size.X / 2 * mesh.Scale.X, size.Y / 2 * mesh.Scale.Y, size.Z / 2 * mesh.Scale.Z
		return math.sqrt((a * dx) ^ 2 + (b * dy) ^ 2 + (c * dz) ^ 2)
	end
	if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return math.min(size.X, size.Y, size.Z) / 2
	end
	if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		local radius = math.min(size.Y, size.Z) / 2
		return math.abs(dx) * size.X / 2 + radius * math.sqrt(math.max(0, 1 - dx * dx))
	end
	return math.abs(dx) * size.X / 2 + math.abs(dy) * size.Y / 2 + math.abs(dz) * size.Z / 2
end

local function partsOf(model)
	local all, visible, nested = 0, 0, 0
	local lowest = math.huge
	local down = Vector3.new(0, -1, 0)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			all += 1
			if d.Parent ~= model then
				nested += 1
			end
			if d.Transparency < 0.98 then
				visible += 1
				local low = d.Position.Y - support(d, down)
				if low < lowest then
					lowest = low
				end
			end
		end
	end
	return all, visible, nested, lowest
end

-- Stands a creature from `builder` with its base on `ground` (by that builder's own Metrics, the
-- way every caller does it) and returns the model, its part count and the measured base offset:
-- + means the lowest visible point is that far below the ground (sinking), - floating.
local function stand(builder, folder, def, ground, yaw, options)
	local size = (def.look and def.look.size) or 1
	local scale = (options and options.scale) or 1
	local metrics = builder.module.Metrics(def)
	local centre = ground - Vector3.new(0, metrics.bottom * size * scale, 0)
	local opts = { flair = false, cframe = CFrame.new(centre) * CFrame.Angles(0, yaw or 0, 0) }
	if options then
		for k, v in pairs(options) do
			opts[k] = v
		end
	end
	local model = builder.module.Build(def, opts)
	model.Parent = folder
	local all, _, _, lowest = partsOf(model)
	return model, all, ground.Y - lowest
end

-- Every render view says whether its targets are IN FRAME: the target in camera space, the distance
-- and the angle off centre against the vertical and horizontal half-FOV (COORDINATION, claude-0d).
local function frameCheck(viewName, camera, targets)
	local vfov = camera.FieldOfView
	local viewport = camera.ViewportSize
	local aspect = (viewport.Y > 0) and (viewport.X / viewport.Y) or (16 / 9)
	local hfov = math.deg(2 * math.atan(math.tan(math.rad(vfov) / 2) * aspect))
	local inside, outside = 0, {}
	for _, target in ipairs(targets) do
		local local_ = camera.CFrame:PointToObjectSpace(target.position)
		local forward = -local_.Z
		local offV = math.deg(math.atan2(math.abs(local_.Y), math.max(forward, 1e-6)))
		local offH = math.deg(math.atan2(math.abs(local_.X), math.max(forward, 1e-6)))
		local ok = forward > 0 and offV < vfov / 2 and offH < hfov / 2
		if ok then
			inside += 1
		else
			table.insert(outside, string.format("%s (%.1f ahead, v %.1f/%.1f h %.1f/%.1f)", target.name, forward, offV, vfov / 2, offH, hfov / 2))
		end
	end
	note("view %s: %d target(s), %d IN FRAME, %d NOT IN FRAME%s (vfov %.0f hfov %.0f, viewport %dx%d)", viewName, #targets, inside,
		#outside, #outside > 0 and (": " .. table.concat(outside, "; ")) or "", vfov, hfov, viewport.X, viewport.Y)
	return #outside == 0
end

local function lookAt(camera, from, to, fov)
	camera.FieldOfView = fov or 30
	camera.CFrame = CFrame.lookAt(from, to)
end

-- Frames a set of models: bounding box of everything, camera in front and a little above.
local function frameAll(camera, models, fov, yawBias)
	local minV, maxV = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, model in ipairs(models) do
		local cf, size = model:GetBoundingBox()
		local lo, hi = cf.Position - size / 2, cf.Position + size / 2
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
	end
	local centre = (minV + maxV) / 2
	local extent = maxV - minV
	fov = fov or 30
	local viewport = camera.ViewportSize
	local aspect = (viewport.Y > 0) and (viewport.X / viewport.Y) or (16 / 9)
	local halfV = extent.Y / 2 + 0.8
	local halfH = extent.X / 2 + 1.0
	local back = math.max(halfV / math.tan(math.rad(fov) / 2), halfH / (math.tan(math.rad(fov) / 2) * aspect)) * 1.12 + extent.Z / 2 + 1
	lookAt(camera, centre + Vector3.new(back * (yawBias or 0.12), extent.Y * 0.16 + back * 0.08, -back), centre, fov)
	return centre
end

--------------------------------------------------------------------------------
-- Creator Store candidates: load once, audit, strip, keep the inert art for later views
--------------------------------------------------------------------------------

local SUSPICIOUS = {
	{ "require by id", "require%s*%(%s*%d" },
	{ "getfenv", "getfenv" },
	{ "setfenv", "setfenv" },
	{ "loadstring", "loadstring" },
	{ "HttpService", "HttpService" },
	{ "GetAsync", "GetAsync" },
	{ "PostAsync", "PostAsync" },
	{ "MarketplaceService", "MarketplaceService" },
	{ "TeleportService", "TeleportService" },
	{ "InsertService", "InsertService" },
	{ "\\x escape", "\\x%x%x" },
	{ "string.char chain", "string%.char%s*%(" },
	{ "base64-looking blob", "[A-Za-z0-9+/=]%s*" },
}

local function smells(text)
	local hits = {}
	if type(text) ~= "string" or #text == 0 then
		return hits
	end
	for _, rule in ipairs(SUSPICIOUS) do
		if rule[1] == "base64-looking blob" then
			-- 60+ base64 characters in a row with no spaces.
			local run = string.match(text, "[A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=]+")
			local longest = 0
			for chunk in string.gmatch(text, "[A-Za-z0-9+/=]+") do
				if #chunk > longest then
					longest = #chunk
				end
			end
			if run and longest >= 60 then
				table.insert(hits, string.format("%s (%d chars)", rule[1], longest))
			end
		elseif string.find(text, rule[2]) then
			table.insert(hits, rule[1])
		end
	end
	return hits
end

local function depthOf(inst, root)
	local depth, cursor = 0, inst
	while cursor and cursor ~= root do
		depth += 1
		cursor = cursor.Parent
	end
	return depth
end

local function pathOf(inst, root)
	local names = {}
	local cursor = inst
	while cursor and cursor ~= root do
		table.insert(names, 1, cursor.Name)
		cursor = cursor.Parent
	end
	return table.concat(names, "/")
end

-- Classes the kept review model may contain. Anything else is stripped and listed.
local KEEP = {
	Model = true, Folder = true, Accessory = true,
	SpecialMesh = true, SurfaceAppearance = true, Decal = true, Texture = true,
	Attachment = true, Weld = true, WeldConstraint = true, Motor6D = true, Snap = true, ManualWeld = true,
	Vector3Value = true, Color3Value = true, CFrameValue = true, NumberValue = true, IntValue = true, BoolValue = true,
}

-- Walks EVERYTHING under `root` (root included) and reports what is there. Never mutates.
local function scan(root)
	local report = { examined = 0, flagged = 0, classes = {}, scripts = {}, remotes = {}, other = {}, strings = {}, values = {} }
	local list = root:GetDescendants()
	table.insert(list, 1, root)
	for _, inst in ipairs(list) do
		report.examined += 1
		local class = inst.ClassName
		report.classes[class] = (report.classes[class] or 0) + 1
		local path = pathOf(inst, root)
		local depth = depthOf(inst, root)
		local hitsHere = {}
		for _, hit in ipairs(smells(inst.Name)) do
			table.insert(hitsHere, "Name:" .. hit)
		end
		local okAttrs, attrs = pcall(function() return inst:GetAttributes() end)
		if okAttrs and attrs then
			for key, value in pairs(attrs) do
				for _, hit in ipairs(smells(value)) do
					table.insert(hitsHere, "attr " .. key .. ":" .. hit)
				end
			end
		end
		if inst:IsA("LuaSourceContainer") then
			local okSource, source = pcall(function() return inst.Source end)
			local disabled = false
			if inst:IsA("BaseScript") then
				disabled = inst.Disabled
			end
			local hits = okSource and smells(source) or { "SOURCE UNREADABLE" }
			for _, hit in ipairs(hits) do
				table.insert(hitsHere, "Source:" .. hit)
			end
			table.insert(report.scripts, { class = class, path = path, depth = depth, disabled = disabled,
				length = okSource and #source or -1, hits = hits })
		elseif inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") or inst:IsA("BindableEvent") or inst:IsA("BindableFunction")
			or inst:IsA("Actor") then
			table.insert(report.remotes, { class = class, path = path, depth = depth })
		elseif inst:IsA("StringValue") then
			local hits = smells(inst.Value)
			for _, hit in ipairs(hitsHere) do
				table.insert(hits, hit)
			end
			for _, hit in ipairs(smells(inst.Value)) do
				table.insert(hitsHere, "Value:" .. hit)
			end
			table.insert(report.values, { class = class, path = path, depth = depth, length = #inst.Value, hits = hits })
		elseif inst:IsA("ObjectValue") then
			table.insert(report.values, { class = class, path = path, depth = depth,
				length = 0, hits = { "ObjectValue -> " .. (inst.Value and inst.Value:GetFullName() or "nil") } })
		elseif not (inst:IsA("BasePart") or KEEP[class]) and inst ~= root then
			table.insert(report.other, { class = class, path = path, depth = depth })
		end
		if #hitsHere > 0 then
			table.insert(report.strings, { path = path, class = class, depth = depth, hits = hitsHere })
		end
	end
	report.flagged = #report.scripts + #report.remotes + #report.other + #report.strings
	for _, value in ipairs(report.values) do
		if #value.hits > 0 or value.length > 64 then
			report.flagged += 1
		end
	end
	return report
end

-- Removes everything that is not inert geometry. Returns per-class counts of what went.
local function strip(root)
	local removed = {}
	local function drop(inst)
		removed[inst.ClassName] = (removed[inst.ClassName] or 0) + 1
		inst:Destroy()
	end
	for _, inst in ipairs(root:GetDescendants()) do
		if inst.Parent == nil then
			-- already gone with an ancestor
		elseif inst:IsA("LuaSourceContainer") or inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")
			or inst:IsA("BindableEvent") or inst:IsA("BindableFunction") or inst:IsA("Actor") then
			drop(inst)
		elseif inst:IsA("StringValue") then
			-- A StringValue is kept only when it is short and clean; otherwise it is a payload.
			if #inst.Value > 64 or #smells(inst.Value) > 0 then
				drop(inst)
			end
		elseif inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanTouch = false
			inst.CanQuery = false
		elseif not KEEP[inst.ClassName] then
			drop(inst)
		end
	end
	-- Containers left holding nothing are debris.
	for _, inst in ipairs(root:GetDescendants()) do
		if inst.Parent ~= nil and (inst:IsA("Folder") or inst:IsA("Model")) and #inst:GetChildren() == 0 then
			drop(inst)
		end
	end
	return removed
end

local function classCensus(counts)
	local names = {}
	for class in pairs(counts) do
		table.insert(names, class)
	end
	table.sort(names)
	local out = {}
	for _, class in ipairs(names) do
		table.insert(out, class .. " " .. counts[class])
	end
	return #out > 0 and table.concat(out, ", ") or "(none)"
end

local function printScan(tag, report)
	note("%s: EXAMINED %d instances, FLAGGED %d; classes: %s", tag, report.examined, report.flagged, classCensus(report.classes))
	for _, s in ipairs(report.scripts) do
		note("%s:   SCRIPT %s %s depth %d %s len %d hits [%s]", tag, s.class, s.path, s.depth, s.disabled and "DISABLED" or "enabled", s.length,
			table.concat(s.hits, ", "))
	end
	for _, r in ipairs(report.remotes) do
		note("%s:   REMOTE/BINDABLE/ACTOR %s %s depth %d", tag, r.class, r.path, r.depth)
	end
	for _, v in ipairs(report.values) do
		note("%s:   VALUE %s %s depth %d len %d hits [%s]", tag, v.class, v.path, v.depth, v.length, table.concat(v.hits, ", "))
	end
	for _, s in ipairs(report.strings) do
		note("%s:   STRING HIT %s %s depth %d [%s]", tag, s.class, s.path, s.depth, table.concat(s.hits, ", "))
	end
	local others = {}
	for _, o in ipairs(report.other) do
		others[o.class] = (others[o.class] or 0) + 1
	end
	note("%s:   non-geometry classes: %s", tag, classCensus(others))
end

-- Bake readout: the data a shipped module would carry (no code, no LoadAsset).
local function bakeReadout(tag, model)
	local meshIds, textureIds, parts, meshParts, unions, appearances = {}, {}, 0, 0, 0, 0
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			parts += 1
			if inst:IsA("MeshPart") then
				meshParts += 1
				meshIds[inst.MeshId] = (meshIds[inst.MeshId] or 0) + 1
				if inst.TextureID ~= "" then
					textureIds[inst.TextureID] = (textureIds[inst.TextureID] or 0) + 1
				end
			elseif inst:IsA("UnionOperation") then
				unions += 1
			end
		elseif inst:IsA("SpecialMesh") then
			if inst.MeshId ~= "" then
				meshIds[inst.MeshId] = (meshIds[inst.MeshId] or 0) + 1
			end
			if inst.TextureId ~= "" then
				textureIds[inst.TextureId] = (textureIds[inst.TextureId] or 0) + 1
			end
		elseif inst:IsA("SurfaceAppearance") then
			appearances += 1
			if inst.ColorMap ~= "" then
				textureIds[inst.ColorMap] = (textureIds[inst.ColorMap] or 0) + 1
			end
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			if inst.Texture ~= "" then
				textureIds[inst.Texture] = (textureIds[inst.Texture] or 0) + 1
			end
		end
	end
	local meshList, texList = {}, {}
	for id in pairs(meshIds) do
		table.insert(meshList, id)
	end
	for id in pairs(textureIds) do
		table.insert(texList, id)
	end
	local _, size = model:GetBoundingBox()
	note("%s: BAKE parts %d (MeshParts %d, unions %d, SurfaceAppearances %d), unique meshes %d, unique textures %d, bbox %.2fx%.2fx%.2f, single-mesh %s",
		tag, parts, meshParts, unions, appearances, #meshList, #texList, size.X, size.Y, size.Z, tostring(meshParts == 1 and parts <= 2))
	note("%s: BAKE mesh ids: %s", tag, table.concat(meshList, " "))
	note("%s: BAKE texture ids: %s", tag, table.concat(texList, " "))
	return meshParts, unions
end

local imports = {} -- name -> stripped, unparented Model (loaded once in asset_check)
local importInfo = {} -- name -> summary string

local function loadCandidate(name, entry)
	local okLoad, package = pcall(InsertService.LoadAsset, InsertService, entry.assetId)
	local how = "InsertService:LoadAsset"
	if not okLoad or not package then
		local err1 = tostring(package)
		local okObjects, objects = pcall(function()
			return game:GetObjects("rbxassetid://" .. tostring(entry.assetId))
		end)
		if okObjects and type(objects) == "table" and #objects > 0 then
			package = Instance.new("Model")
			for _, object in ipairs(objects) do
				object.Parent = package
			end
			how = "game:GetObjects (LoadAsset said: " .. err1 .. ")"
		else
			return nil, string.format("LOAD FAILED: LoadAsset -> %s; GetObjects -> %s", err1, tostring(objects))
		end
	end
	-- Audit while still UNPARENTED (package.Parent == nil): nothing in it has run.
	local before = scan(package)
	printScan(string.format("asset %s [%s] PRE-STRIP", name, tostring(entry.assetId)), before)
	local removed = strip(package)
	local after = scan(package)
	printScan(string.format("asset %s [%s] POST-STRIP (the kept model)", name, tostring(entry.assetId)), after)
	local clean = #after.scripts == 0 and #after.remotes == 0 and #after.other == 0
	note("asset %s [%s]: loaded via %s; parent at audit = %s; stripped: %s; kept model CLEAN = %s", name, tostring(entry.assetId), how,
		tostring(package.Parent), classCensus(removed), tostring(clean))
	local art = Instance.new("Model")
	art.Name = name
	for _, child in ipairs(package:GetChildren()) do
		child.Parent = art
	end
	package:Destroy()
	local parts = 0
	for _, inst in ipairs(art:GetDescendants()) do
		if inst:IsA("BasePart") then
			parts += 1
		end
	end
	if parts == 0 then
		art:Destroy()
		return nil, "asset held no geometry after the strip"
	end
	local meshParts, unions = bakeReadout(string.format("asset %s", name), art)
	local verdict = clean and "AUDIT CLEAN" or "AUDIT DIRTY"
	if unions > 0 then
		verdict ..= " (has UnionOperations: not bakeable as mesh ids)"
	end
	return art, string.format("%s; %d parts, %d MeshParts, scripts removed %d, pre-strip flagged %d, examined %d/%d", verdict, parts, meshParts,
		#before.scripts, before.flagged, before.examined, after.examined)
end

-- A copy of an imported model, sized the way BrainrotModels.buildOverride would size an override
-- (OVERRIDE_HEIGHT tall x scale x look.size, bounding-box centre at the caller's cframe).
local function standImport(folder, def, ground, yaw, scale, glowColor)
	local source = imports[def.name] or (def.name == "Golden Sahur" and imports["Tung Tung Tung Sahur"]) or nil
	if not source then
		return nil
	end
	local size = (def.look and def.look.size) or 1
	scale = (scale or 1) * size
	local model = source:Clone()
	local _, boxSize = model:GetBoundingBox()
	model:ScaleTo(math.max(0.01, OVERRIDE_HEIGHT / math.max(boxSize.Y, 0.1)) * scale)
	if def.name == "Golden Sahur" then
		for _, inst in ipairs(model:GetDescendants()) do
			if inst:IsA("BasePart") then
				inst.Color = GOLD
				inst.Material = Enum.Material.Metal
			end
		end
	end
	local metrics = Current.Metrics(def)
	local centre = ground - Vector3.new(0, metrics.bottom * scale, 0)
	local box = model:GetBoundingBox()
	model:PivotTo(CFrame.new(centre) * CFrame.Angles(0, yaw or 0, 0) * box:ToObjectSpace(model:GetPivot()))
	if glowColor then
		local light = Instance.new("PointLight")
		light.Color = glowColor
		light.Range = 10 * scale
		light.Brightness = 1.4
		light.Parent = model:FindFirstChildWhichIsA("BasePart", true)
	end
	model.Parent = folder
	local all, _, _, lowest = partsOf(model)
	return model, all, ground.Y - lowest
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local views = {}

-- 1. Numbers for every entry through both builders, with the planted fault first.
table.insert(views, {
	name = "audit_numbers",
	settle = 1.2,
	setup = function(folder, camera)
		clearGui()
		pad(folder, ORIGIN, 24, 16)
		local targets = {}

		local function audit(builder, defs)
			local r = { built = 0, nilModel = 0, errored = 0, noParts = 0, noPrimary = 0, parts = 0, visible = 0, nested = 0, maxParts = 0,
				maxName = "", rigs = 0, cropped = 0, fillSum = 0, fillMin = math.huge, fillMax = 0, worstSink = 0, worstSinkName = "",
				worstFloat = 0, worstFloatName = "", crossSink = 0, crossFloat = 0, failures = {} }
			local viewport = Instance.new("ViewportFrame")
			for index, def in ipairs(defs) do
				local size = (def.look and def.look.size) or 1
				local ok, model = pcall(builder.module.Build, def, { flair = false })
				if not ok then
					r.errored += 1
					table.insert(r.failures, def.name .. ": build ERROR " .. tostring(model))
				elseif typeof(model) ~= "Instance" then
					r.nilModel += 1
					table.insert(r.failures, def.name .. ": build returned " .. tostring(model))
				else
					local all, visible, nested, lowest = partsOf(model)
					if all == 0 then
						r.noParts += 1
						table.insert(r.failures, def.name .. ": model has NO PARTS")
					else
						r.built += 1
						r.parts += all
						r.visible += visible
						r.nested += nested
						if all > r.maxParts then
							r.maxParts, r.maxName = all, def.name
						end
						if not model.PrimaryPart then
							r.noPrimary += 1
							table.insert(r.failures, def.name .. ": no PrimaryPart")
						end
						-- Base offset against the builder's own metrics (statues stand by `bottom`).
						local metrics = builder.module.Metrics(def)
						local offset = metrics.bottom * size - lowest -- + sinks below the plinth, - floats
						local hover = def.look and (def.look.body == "Ghost" or def.look.body == "Cloud")
						if offset > r.worstSink then
							r.worstSink, r.worstSinkName = offset, def.name
						end
						if -offset > r.worstFloat and not hover then
							r.worstFloat, r.worstFloatName = -offset, def.name
						end
						-- The remake stood by the CURRENT metrics: what a Build-only switch would do.
						if builder.tag == "rem" then
							local cross = Current.Metrics(def).bottom * size - lowest
							if cross > 0.15 then
								r.crossSink += 1
							elseif cross < -0.15 then
								r.crossFloat += 1
							end
						end
						-- Portrait: the model at the origin in a square ViewportFrame, framed by this
						-- builder's FrameViewport; bounding-box corners projected through that camera.
						local cam = builder.module.FrameViewport(viewport, def)
						local cf, box = model:GetBoundingBox()
						local t = math.tan(math.rad(cam.FieldOfView) / 2)
						local nyMin, nyMax, cropped = math.huge, -math.huge, false
						for sx = -1, 1, 2 do
							for sy = -1, 1, 2 do
								for sz = -1, 1, 2 do
									local corner = cf * Vector3.new(sx * box.X / 2, sy * box.Y / 2, sz * box.Z / 2)
									local l = cam.CFrame:PointToObjectSpace(corner)
									local z = -l.Z
									if z <= 0.01 then
										cropped = true
									else
										local nx, ny = l.X / (z * t), l.Y / (z * t)
										if math.abs(nx) > 1 or math.abs(ny) > 1 then
											cropped = true
										end
										nyMin, nyMax = math.min(nyMin, ny), math.max(nyMax, ny)
									end
								end
							end
						end
						local fill = (nyMax - nyMin) / 2
						if cropped then
							r.cropped += 1
						end
						r.fillSum += fill
						r.fillMin, r.fillMax = math.min(r.fillMin, fill), math.max(r.fillMax, fill)
					end
					model:Destroy()
				end
				-- Companion rig: does CompanionAnimations read it?
				local okRig, rigged = pcall(builder.module.Build, def, { flair = false, rig = true, anchored = false, scale = COMPANION_SCALE })
				if okRig and typeof(rigged) == "Instance" then
					if CompanionAnimations.Rig(rigged) then
						r.rigs += 1
					end
					rigged:Destroy()
				end
				if index % 8 == 0 then
					task.wait()
				end
			end
			viewport:Destroy()
			return r
		end

		-- PERMANENT PLANTED FAULT: a builder that returns nil for #1, errors on #2 and builds no parts
		-- for #3 must produce exactly three failures on those three names.
		do
			local planted = { tag = "planted", label = "PLANTED", module = {
				Metrics = function(def) return Current.Metrics(def) end,
				FrameViewport = function(viewport, def) return Current.FrameViewport(viewport, def) end,
				Build = function(def, options)
					if def.name == BrainrotData.Types[1].name then
						return nil
					elseif def.name == BrainrotData.Types[2].name then
						error("planted build error")
					elseif def.name == BrainrotData.Types[3].name then
						local empty = Instance.new("Model")
						empty.Name = def.name
						return empty
					end
					return Current.Build(def, options)
				end,
			} }
			local r = audit(planted, { BrainrotData.Types[1], BrainrotData.Types[2], BrainrotData.Types[3], BrainrotData.Types[4] })
			local caught = r.nilModel == 1 and r.errored == 1 and r.noParts == 1 and r.built == 1 and #r.failures == 3
			note("== PLANTED FAULT (nil / error / no parts on entries 1-3 of 4): nil %d, errored %d, noParts %d, built %d, failures %d -> %s",
				r.nilModel, r.errored, r.noParts, r.built, #r.failures, caught and "CAUGHT" or "MISSED (the audit below cannot see a broken builder)")
		end

		for _, builder in ipairs(BUILDERS) do
			local r = audit(builder, BrainrotData.Types)
			local n = math.max(r.built, 1)
			note("== %s: built %d/%d (nil %d, errored %d, noParts %d, noPrimaryPart %d); parts total %d, mean %.1f, max %d (%s); visible mean %.1f; nested %d",
				builder.label, r.built, #BrainrotData.Types, r.nilModel, r.errored, r.noParts, r.noPrimary, r.parts, r.parts / n, r.maxParts, r.maxName,
				r.visible / n, r.nested)
			note("== %s: companion rigs readable by CompanionAnimations %d/%d; portraits CROPPED %d/%d, fill mean %.2f min %.2f max %.2f",
				builder.label, r.rigs, #BrainrotData.Types, r.cropped, r.built, r.fillSum / n, r.fillMin, r.fillMax)
			note("== %s: base vs own Metrics.bottom: worst sink %.3f (%s), worst float %.3f (%s)%s", builder.label, r.worstSink, r.worstSinkName,
				r.worstFloat, r.worstFloatName, builder.tag == "rem"
					and string.format("; stood by the CURRENT metrics instead: %d sink >0.15, %d float >0.15", r.crossSink, r.crossFloat) or "")
			for i, failure in ipairs(r.failures) do
				if i > 20 then
					note("== %s:   ... %d more failures", builder.label, #r.failures - 20)
					break
				end
				note("== %s:   FAIL %s", builder.label, failure)
			end
		end

		local marker = plate(folder, "audit_numbers: see notes", ORIGIN + Vector3.new(0, 1.5, 0), 10)
		table.insert(targets, { name = "marker", position = marker.Position })
		lookAt(camera, ORIGIN + Vector3.new(0, 3, -14), ORIGIN + Vector3.new(0, 1.5, 0), 30)
		frameCheck("audit_numbers", camera, targets)
	end,
})

-- 2. Can this harness load Store assets at all? Then the audit, then all of them in a line.
table.insert(views, {
	name = "asset_check_lineup",
	settle = 1.5,
	hold = 2,
	setup = function(folder, camera)
		clearGui()
		local names = {}
		for name in pairs(Candidates) do
			if name ~= "Golden Sahur" then
				table.insert(names, name)
			end
		end
		table.sort(names, function(a, b)
			return (table.find(CANONICAL, a) or 99) < (table.find(CANONICAL, b) or 99)
		end)

		-- PERMANENT PLANTED BACKDOOR, scanned before any real asset so the scan is proven first.
		do
			local copy = Instance.new("Model")
			copy.Name = "PlantedCopy"
			local body = Instance.new("Part")
			body.Name = "Body"
			body.Parent = copy
			local nested = Instance.new("Model")
			nested.Name = "Head"
			nested.Parent = copy
			local f1 = Instance.new("Folder")
			f1.Name = "Animate"
			f1.Parent = nested
			local f2 = Instance.new("Folder")
			f2.Name = "Health"
			f2.Parent = f1
			local f3 = Instance.new("Folder")
			f3.Name = "Sound"
			f3.Parent = f2
			local script = Instance.new("Script")
			script.Name = "Humanoid"
			script.Disabled = true
			script.Source = "require(123456)"
			script.Parent = f3
			local remote = Instance.new("RemoteEvent")
			remote.Name = "Weld"
			remote.Parent = f3
			local blob = Instance.new("StringValue")
			blob.Name = "Color"
			blob.Value = string.rep("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=", 3)
			blob.Parent = f2
			local before = scan(copy)
			local scriptSeen, disabledSeen, deepEnough, requireSeen, remoteSeen, blobSeen = false, false, false, false, false, false
			for _, s in ipairs(before.scripts) do
				scriptSeen = true
				disabledSeen = disabledSeen or s.disabled
				deepEnough = deepEnough or s.depth >= 4
				for _, hit in ipairs(s.hits) do
					requireSeen = requireSeen or hit == "require by id"
				end
			end
			remoteSeen = #before.remotes >= 1
			for _, v in ipairs(before.values) do
				for _, hit in ipairs(v.hits) do
					blobSeen = blobSeen or string.find(hit, "base64") ~= nil
				end
			end
			local removed = strip(copy)
			local after = scan(copy)
			local cleanAfter = #after.scripts == 0 and #after.remotes == 0 and #after.values == 0
			local caught = scriptSeen and disabledSeen and deepEnough and requireSeen and remoteSeen and blobSeen and cleanAfter
			note("== PLANTED BACKDOOR: examined %d, flagged %d; disabled Script seen %s at depth>=4 %s with require-by-id %s; RemoteEvent seen %s; blob seen %s; after strip (%s) examined %d, scripts %d remotes %d values %d -> %s",
				before.examined, before.flagged, tostring(scriptSeen), tostring(deepEnough), tostring(requireSeen), tostring(remoteSeen),
				tostring(blobSeen), classCensus(removed), after.examined, #after.scripts, #after.remotes, #after.values,
				caught and "CAUGHT" or "MISSED (the asset scan below proves nothing)")
			copy:Destroy()
		end

		local loaded = 0
		for _, name in ipairs(names) do
			local entry = Candidates[name]
			local okAll, art, summary = pcall(loadCandidate, name, entry)
			if not okAll then
				importInfo[name] = "LOAD/AUDIT ERRORED: " .. tostring(art)
				note("asset %s [%s]: %s", name, tostring(entry.assetId), importInfo[name])
			elseif not art then
				importInfo[name] = summary
				note("asset %s [%s]: %s", name, tostring(entry.assetId), summary)
			else
				imports[name] = art
				importInfo[name] = summary
				loaded += 1
				note("asset %s [%s] by %s: %s", name, tostring(entry.assetId), tostring(entry.creator), summary)
			end
			task.wait()
		end
		note("== ASSET LOAD FROM THIS HARNESS: %d of %d candidates loaded (0 means importing is a manual Studio step)", loaded, #names)

		pad(folder, ORIGIN, #names * 5.2 + 24, 30)
		local models, targets = {}, {}
		for index, name in ipairs(names) do
			local def = BrainrotData.Get(name)
			local x = (index - (#names + 1) / 2) * 5.2
			local ground = ORIGIN + Vector3.new(x, 0, 0)
			local model, count, base = standImport(folder, def, ground, 0, 1)
			if model then
				table.insert(models, model)
				table.insert(targets, { name = name, position = model:GetBoundingBox().Position })
				plate(folder, string.format("%s\nIMPORT %dp base %+.2f", name, count, base), ground + Vector3.new(0, 0.5, -2.2), 4.8)
			else
				plate(folder, name .. "\nNO IMPORT", ground + Vector3.new(0, 0.5, -2.2), 4.8)
			end
		end
		if #models > 0 then
			frameAll(camera, models, 30, 0.05)
		else
			lookAt(camera, ORIGIN + Vector3.new(0, 4, -30), ORIGIN + Vector3.new(0, 1.5, 0), 30)
			table.insert(targets, { name = "empty pad", position = ORIGIN })
		end
		frameCheck("asset_check_lineup", camera, targets)
	end,
})

-- 3. The twelve meme names: CURRENT | REMAKE | IMPORT, close up.
for index, name in ipairs(CANONICAL) do
	local def = BrainrotData.Get(name)
	if def then
		table.insert(views, {
			name = string.format("canon_%02d_%s", index, (string.gsub(name, "[^%w]", ""))),
			settle = 1.3,
			hold = 1.5,
			setup = function(folder, camera)
				clearGui()
				pad(folder, ORIGIN, 30, 18)
				local models, targets = {}, {}
				local slots = { -5.2, 0, 5.2 }
				for b, builder in ipairs(BUILDERS) do
					local ground = ORIGIN + Vector3.new(slots[b], 0, 0)
					local model, count, base = stand(builder, folder, def, ground, -0.2)
					table.insert(models, model)
					table.insert(targets, { name = builder.label, position = model:GetBoundingBox().Position })
					plate(folder, string.format("%s %dp base %+.2f", builder.label, count, base), ground + Vector3.new(0, 0.5, -2.4), 4.8)
				end
				local ground = ORIGIN + Vector3.new(slots[3], 0, 0)
				local model, count, base = standImport(folder, def, ground, -0.2, 1)
				if model then
					table.insert(models, model)
					table.insert(targets, { name = "IMPORT", position = model:GetBoundingBox().Position })
					plate(folder, string.format("IMPORT %dp base %+.2f", count, base), ground + Vector3.new(0, 0.5, -2.4), 4.8)
				else
					plate(folder, "IMPORT: none loaded", ground + Vector3.new(0, 0.5, -2.4), 4.8)
				end
				plate(folder, name, ORIGIN + Vector3.new(0, 6.2, 8.4), 12)
				frameAll(camera, models, 30, 0.08)
				note("canon %s: %s", name, importInfo[name] or importInfo["Tung Tung Tung Sahur"] and (name == "Golden Sahur" and "gold recolour of the Tung import") or "no candidate")
				frameCheck("canon_" .. name, camera, targets)
			end,
		})
	end
end

-- 4. Every brainrot as a CURRENT | REMAKE pair, four pairs per sheet, grouped by rarity.
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }
local PAIRS_PER_SHEET = 4
local PAIR_GAP = 4.4
local GROUP_GAP = 10.2
for rarityIndex, rarity in ipairs(RARITIES) do
	local pool = BrainrotData.OfRarity(rarity)
	for sheet = 1, math.ceil(#pool / PAIRS_PER_SHEET) do
		local first = (sheet - 1) * PAIRS_PER_SHEET + 1
		local last = math.min(#pool, sheet * PAIRS_PER_SHEET)
		table.insert(views, {
			name = string.format("pair_%d_%s_%d", rarityIndex, rarity, sheet),
			settle = 1.2,
			setup = function(folder, camera)
				clearGui()
				pad(folder, ORIGIN, PAIRS_PER_SHEET * GROUP_GAP + 16, 24)
				local models, targets, labels = {}, {}, {}
				local shown = last - first
				for itemIndex = first, last do
					local def = pool[itemIndex]
					local gx = (itemIndex - first - shown / 2) * GROUP_GAP
					local counts = {}
					for b, builder in ipairs(BUILDERS) do
						local ground = ORIGIN + Vector3.new(gx + (b - 1.5) * PAIR_GAP, 0, 0)
						local model, count, base = stand(builder, folder, def, ground, 0)
						table.insert(models, model)
						table.insert(targets, { name = def.name .. " " .. builder.tag, position = model:GetBoundingBox().Position })
						table.insert(counts, string.format("%s %d (base %+.2f)", builder.tag, count, base))
					end
					plate(folder, string.format("%s\ncur | rem", def.name), ORIGIN + Vector3.new(gx, 0.5, -2.4), 8.4)
					table.insert(labels, string.format("%s[%s]", def.name, table.concat(counts, ", ")))
				end
				note("pair sheet %s %d: %s", rarity, sheet, table.concat(labels, "; "))
				frameAll(camera, models, 30, 0.04)
				frameCheck(string.format("pair_%s_%d", rarity, sheet), camera, targets)
			end,
		})
	end
end

-- 5. Companion beside a character, at the size and offset CompanionService uses.
local function dummyAt(folder, position)
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if not ok or not rig then
		-- A block figure of R15 proportions (about 5 studs tall), so the scale reference still stands.
		rig = Instance.new("Model")
		rig.Name = "BlockFigure"
		local function piece(name, size, offset)
			local part = Instance.new("Part")
			part.Name = name
			part.Size = size
			part.Color = Color3.fromRGB(120, 130, 150)
			part.CFrame = CFrame.new(position + offset)
			part.Anchored = true
			part.Parent = rig
			return part
		end
		local root = piece("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0))
		root.Transparency = 1
		piece("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0))
		piece("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 4.6, 0))
		piece("LegL", Vector3.new(0.9, 2, 1), Vector3.new(-0.5, 1, 0))
		piece("LegR", Vector3.new(0.9, 2, 1), Vector3.new(0.5, 1, 0))
		piece("ArmL", Vector3.new(0.9, 2, 1), Vector3.new(-1.5, 3, 0))
		piece("ArmR", Vector3.new(0.9, 2, 1), Vector3.new(1.5, 3, 0))
		rig.PrimaryPart = root
		rig.Parent = folder
		return rig, root, "block figure (CreateHumanoidModelFromDescription failed: " .. tostring(rig) .. ")"
	end
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	rig.Parent = folder
	local root = rig:FindFirstChild("HumanoidRootPart")
	local hipHeight = 0
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		hipHeight = humanoid.HipHeight
	end
	rig:PivotTo(CFrame.new(position + Vector3.new(0, (root and root.Size.Y / 2 or 1) + hipHeight, 0)))
	return rig, root or rig.PrimaryPart, "R15 from HumanoidDescription"
end

local function companionView(viewName, def, withImport)
	return {
		name = viewName,
		settle = 1.3,
		hold = 1.5,
		setup = function(folder, camera)
			clearGui()
			local slots = withImport and { -9, 0, 9 } or { -5, 5 }
			pad(folder, ORIGIN, 40, 22)
			local models, targets = {}, {}
			local kind
			for b, builder in ipairs(BUILDERS) do
				local spot = ORIGIN + Vector3.new(slots[b], 0, 0)
				local rig, root, how = dummyAt(folder, spot)
				kind = how
				table.insert(models, rig)
				-- Where CompanionService puts it: root.CFrame * FOLLOW_OFFSET, body centre there.
				local at = root.CFrame * CFrame.new(FOLLOW_OFFSET)
				-- Built exactly as CompanionService does (rig = true, unanchored), then anchored so edit
				-- mode holds the rest pose; the plate says whether CompanionAnimations can read the rig.
				local model = builder.module.Build(def, { flair = false, scale = COMPANION_SCALE, cframe = at, rig = true, anchored = false })
				for _, d in ipairs(model:GetDescendants()) do
					if d:IsA("BasePart") then
						d.Anchored = true
					end
				end
				model.Parent = folder
				local rigOk = CompanionAnimations.Rig(model) ~= nil
				local count = partsOf(model)
				table.insert(models, model)
				table.insert(targets, { name = builder.label .. " companion", position = model:GetBoundingBox().Position })
				plate(folder, string.format("%s x%.2f %dp\n%s", builder.label, COMPANION_SCALE, count,
					rigOk and "RIG OK: animates" or "NO RIG: never animates"), spot + Vector3.new(0, 0.5, -3), 5.2)
				note("%s: %s companion rig readable by CompanionAnimations = %s", viewName, builder.label, tostring(rigOk))
			end
			if withImport then
				local spot = ORIGIN + Vector3.new(slots[3], 0, 0)
				local rig, root = dummyAt(folder, spot)
				table.insert(models, rig)
				local source = imports[def.name]
				if source then
					local model = source:Clone()
					local _, boxSize = model:GetBoundingBox()
					local size = (def.look and def.look.size) or 1
					model:ScaleTo(math.max(0.01, OVERRIDE_HEIGHT / math.max(boxSize.Y, 0.1)) * COMPANION_SCALE * size)
					local box = model:GetBoundingBox()
					model:PivotTo(root.CFrame * CFrame.new(FOLLOW_OFFSET) * box:ToObjectSpace(model:GetPivot()))
					model.Parent = folder
					local count = partsOf(model)
					table.insert(models, model)
					table.insert(targets, { name = "IMPORT companion", position = model:GetBoundingBox().Position })
					plate(folder, string.format("IMPORT x%.2f %dp", COMPANION_SCALE, count), spot + Vector3.new(0, 0.5, -3), 5.2)
				else
					plate(folder, "IMPORT: none loaded", spot + Vector3.new(0, 0.5, -3), 5.2)
				end
			end
			plate(folder, def.name .. " as a companion", ORIGIN + Vector3.new(0, 8.5, 10.4), 14)
			note("%s: character = %s", viewName, tostring(kind))
			frameAll(camera, models, 32, 0.1)
			frameCheck(viewName, camera, targets)
		end,
	}
end
table.insert(views, companionView("companion_TralaleroTralala", BrainrotData.Get("Tralalero Tralala"), true))
table.insert(views, companionView("companion_FenicePixelata", BrainrotData.Get("Fenice Pixelata"), false))

-- 6. Menu card portraits at the sizes MenuClient really draws them (106 px cards, 48 px rows).
table.insert(views, {
	name = "portraits_cards",
	settle = 1.6,
	hold = 2,
	setup = function(folder, camera)
		clearGui()
		pad(folder, ORIGIN, 20, 12)
		local gui = Instance.new("ScreenGui")
		gui.Name = GUI_NAME
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 10
		gui.Parent = StarterGui
		local backdrop = Instance.new("Frame")
		backdrop.Size = UDim2.new(1, 0, 1, -40) -- leaves the bottom strip for the harness tag
		backdrop.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
		backdrop.BorderSizePixel = 0
		backdrop.Parent = gui

		local sample = { "Tung Tung Tung Sahur", "Tralalero Tralala", "Lirili Larila", "Frigo Camelo",
			"Trippi Troppi", "Fenice Pixelata", "Oracolo Lavatrice", "Cavaliere Lattina" }
		local rows = {
			{ label = "CURRENT 106", size = 106, builder = BUILDERS[1] },
			{ label = "REMAKE 106", size = 106, builder = BUILDERS[2] },
			{ label = "IMPORT 106 (override path)", size = 106, import = true },
			{ label = "CURRENT 48", size = 48, builder = BUILDERS[1] },
			{ label = "REMAKE 48", size = 48, builder = BUILDERS[2] },
		}
		local y = 14
		local crops = {}
		for _, row in ipairs(rows) do
			local title = Instance.new("TextLabel")
			title.Position = UDim2.fromOffset(16, y)
			title.Size = UDim2.fromOffset(200, 16)
			title.BackgroundTransparency = 1
			title.Font = Enum.Font.GothamBold
			title.TextSize = 13
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.TextColor3 = Color3.fromRGB(230, 230, 236)
			title.Text = row.label
			title.Parent = backdrop
			y += 18
			for i, name in ipairs(sample) do
				local def = BrainrotData.Get(name)
				local viewport = Instance.new("ViewportFrame")
				viewport.Position = UDim2.fromOffset(16 + (i - 1) * (row.size + 10), y)
				viewport.Size = UDim2.fromOffset(row.size, row.size)
				viewport.BackgroundColor3 = Color3.fromRGB(44, 47, 58)
				viewport.BorderSizePixel = 0
				viewport.Ambient = Color3.fromRGB(170, 170, 182)
				viewport.LightColor = Color3.fromRGB(255, 250, 240)
				viewport.LightDirection = Vector3.new(-0.4, -1, 0.6)
				viewport.Parent = backdrop
				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(0, 10)
				corner.Parent = viewport
				local model
				if row.import then
					local source = imports[name]
					if source then
						model = source:Clone()
						local _, boxSize = model:GetBoundingBox()
						model:ScaleTo(math.max(0.01, OVERRIDE_HEIGHT / math.max(boxSize.Y, 0.1)) * ((def.look and def.look.size) or 1))
						local box = model:GetBoundingBox()
						model:PivotTo(CFrame.new() * box:ToObjectSpace(model:GetPivot()))
						model.Parent = viewport
						Current.FrameViewport(viewport, def)
					end
				else
					model = row.builder.module.Build(def, { flair = false })
					model.Parent = viewport
					row.builder.module.FrameViewport(viewport, def)
				end
				if model then
					local cam = viewport.CurrentCamera
					local cf, box = model:GetBoundingBox()
					local t = math.tan(math.rad(cam.FieldOfView) / 2)
					local cropped = false
					for sx = -1, 1, 2 do
						for sy = -1, 1, 2 do
							for sz = -1, 1, 2 do
								local l = cam.CFrame:PointToObjectSpace(cf * Vector3.new(sx * box.X / 2, sy * box.Y / 2, sz * box.Z / 2))
								local z = -l.Z
								if z <= 0.01 or math.abs(l.X / (z * t)) > 1 or math.abs(l.Y / (z * t)) > 1 then
									cropped = true
								end
							end
						end
					end
					if cropped then
						table.insert(crops, row.label .. " " .. name)
					end
				end
			end
			y += row.size + 10
		end
		note("portraits: %d cards drawn; bounding box cropped in %d: %s", #rows * #sample, #crops, #crops > 0 and table.concat(crops, "; ") or "none")
		-- IN FRAME for a GUI view: the ScreenGui covers the viewport by construction; the 3D marker
		-- behind it is checked so the note still carries a camera-space number.
		local marker = plate(folder, "portraits_cards", ORIGIN + Vector3.new(0, 1.5, 0), 8)
		lookAt(camera, ORIGIN + Vector3.new(0, 3, -14), ORIGIN + Vector3.new(0, 1.5, 0), 30)
		frameCheck("portraits_cards", camera, { { name = "marker", position = marker.Position } })
	end,
})

-- 7. World statues at the scales the lobby and the plaza use, with the glow they give.
local function statueView(viewName, def, scale, glowColor, caption)
	return {
		name = viewName,
		settle = 1.3,
		hold = 1.5,
		setup = function(folder, camera)
			clearGui()
			pad(folder, ORIGIN, 30 * scale, 14 * scale)
			local models, targets = {}, {}
			local slots = { -5.6 * scale, 0, 5.6 * scale }
			for b, builder in ipairs(BUILDERS) do
				local ground = ORIGIN + Vector3.new(slots[b], 0, 0)
				local model, count, base = stand(builder, folder, def, ground, 0, { scale = scale, glow = glowColor })
				table.insert(models, model)
				table.insert(targets, { name = builder.label, position = model:GetBoundingBox().Position })
				plate(folder, string.format("%s x%.1f %dp base %+.2f", builder.label, scale, count, base), ground + Vector3.new(0, 0.5, -2.6 * scale), 5.4 * scale)
			end
			local ground = ORIGIN + Vector3.new(slots[3], 0, 0)
			local model, count, base = standImport(folder, def, ground, 0, scale, glowColor)
			if model then
				table.insert(models, model)
				table.insert(targets, { name = "IMPORT", position = model:GetBoundingBox().Position })
				plate(folder, string.format("IMPORT x%.1f %dp base %+.2f", scale, count, base), ground + Vector3.new(0, 0.5, -2.6 * scale), 5.4 * scale)
			else
				plate(folder, "IMPORT: none loaded", ground + Vector3.new(0, 0.5, -2.6 * scale), 5.4 * scale)
			end
			plate(folder, caption, ORIGIN + Vector3.new(0, 6.5 * scale, 6.4 * scale), 14 * scale)
			frameAll(camera, models, 30, 0.1)
			frameCheck(viewName, camera, targets)
		end,
	}
end
table.insert(views, statueView("statue_lobby_x1_6_GoldenSahur", BrainrotData.Get("Golden Sahur"), 1.6, GOLD, "Golden Sahur: lobby statue x1.6, gold glow"))
table.insert(views, statueView("statue_plaza_x2_6_LiriliLarila", BrainrotData.Get("Lirili Larila"), 2.6, nil, "Lirili Larila: plaza statue x2.6"))
table.insert(views, statueView("statue_plaza_x2_6_KrakenCaramello", BrainrotData.Get("Kraken Caramello"), 2.6, nil, "Kraken Caramello (original): plaza statue x2.6"))

-- 7b. What a Build-only switch does: the remake stood by the CURRENT per-body metrics (as every
-- statue caller would, if only Build were delegated) beside the same model stood by its own, on
-- plinths so a sunk base disappears the way it would in the lobby.
table.insert(views, {
	name = "metrics_gap_build_only_switch",
	settle = 1.3,
	hold = 1.5,
	setup = function(folder, camera)
		clearGui()
		local picks = {}
		for _, body in ipairs({ "Disc", "Loaf", "Blob", "Cube", "Totem" }) do
			for _, def in ipairs(BrainrotData.Types) do
				if def.look and def.look.body == body then
					table.insert(picks, def)
					break
				end
			end
		end
		pad(folder, ORIGIN, #picks * 10.4 + 16, 20)
		local models, targets = {}, {}
		for index, def in ipairs(picks) do
			local gx = (index - (#picks + 1) / 2) * 10.4
			for slot, useCurrentMetrics in ipairs({ true, false }) do
				local ground = ORIGIN + Vector3.new(gx + (slot - 1.5) * 4.6, 1, 0)
				local plinth = Instance.new("Part")
				plinth.Name = "Plinth"
				plinth.Anchored = true
				plinth.Size = Vector3.new(4, 1, 4)
				plinth.CFrame = CFrame.new(ground - Vector3.new(0, 0.5, 0))
				plinth.Color = Color3.fromRGB(214, 206, 190)
				plinth.Material = Enum.Material.Marble
				plinth.Parent = folder
				local size = (def.look and def.look.size) or 1
				local bottom = (useCurrentMetrics and Current.Metrics(def) or Remake.Metrics(def)).bottom
				local model = Remake.Build(def, { flair = false, cframe = CFrame.new(ground - Vector3.new(0, bottom * size, 0)) })
				model.Parent = folder
				local _, _, _, lowest = partsOf(model)
				table.insert(models, model)
				table.insert(targets, { name = def.name .. (useCurrentMetrics and " by-current" or " by-own"), position = model:GetBoundingBox().Position })
				plate(folder, string.format("%s\n%s metrics: base %+.2f", def.look.body, useCurrentMetrics and "CURRENT" or "own", ground.Y - lowest),
					ground + Vector3.new(0, -0.1, -2.3), 4.4)
			end
			plate(folder, def.name, ORIGIN + Vector3.new(gx, 5.4, 9.4), 9)
		end
		plate(folder, "REMAKE stood by CURRENT metrics (a Build-only switch) vs by its own", ORIGIN + Vector3.new(0, 7.6, 9.4), 30)
		frameAll(camera, models, 30, 0.04)
		frameCheck("metrics_gap_build_only_switch", camera, targets)
	end,
})

-- 8. The mixed sets a swap would produce, standing together.
local function mixedView(viewName, caption, originalsBuilder)
	return {
		name = viewName,
		settle = 1.3,
		hold = 1.5,
		setup = function(folder, camera)
			clearGui()
			local lineup = {}
			for i = 1, 6 do
				table.insert(lineup, { name = CANONICAL[i], import = true })
				table.insert(lineup, { name = ORIGINALS[i], import = false })
			end
			pad(folder, ORIGIN, #lineup * 5 + 20, 24)
			local models, targets = {}, {}
			for index, item in ipairs(lineup) do
				local def = BrainrotData.Get(item.name)
				local ground = ORIGIN + Vector3.new((index - (#lineup + 1) / 2) * 5, 0, 0)
				local model, count, base, tag
				if item.import then
					model, count, base = standImport(folder, def, ground, 0, 1)
					tag = "IMPORT"
					if not model then
						model, count, base = stand(BUILDERS[2], folder, def, ground, 0)
						tag = "REMAKE (no import)"
					end
				else
					model, count, base = stand(originalsBuilder, folder, def, ground, 0)
					tag = originalsBuilder.label
				end
				table.insert(models, model)
				table.insert(targets, { name = item.name, position = model:GetBoundingBox().Position })
				plate(folder, string.format("%s\n%s %dp", item.name, tag, count), ground + Vector3.new(0, 0.5, -2.4), 4.8)
			end
			plate(folder, caption, ORIGIN + Vector3.new(0, 7, 10.4), 30)
			frameAll(camera, models, 30, 0.04)
			frameCheck(viewName, camera, targets)
		end,
	}
end
table.insert(views, mixedView("mixed_imports_plus_remake", "Mixed set A: imports for the meme names + REMAKE for the originals", BUILDERS[2]))
table.insert(views, mixedView("mixed_imports_plus_current", "Mixed set B: imports for the meme names + CURRENT for the originals", BUILDERS[1]))

-- 9. Tom Pearl (new Legendary), only when the place the run uses carries him: a close-up (front
-- three-quarter and back, so the drips, the puddle and the face all show) and a line-up beside the
-- two Legendaries he sits next to on value, so he reads as their equal or as an outsider.
local tomPearl = BrainrotData.Get("Tom Pearl")
if tomPearl then
	table.insert(views, {
		name = "tom_pearl_closeup",
		settle = 1.4,
		hold = 2,
		setup = function(folder, camera)
			clearGui()
			pad(folder, ORIGIN, 26, 16)
			local models, targets = {}, {}
			local front, count, base = stand(BUILDERS[1], folder, tomPearl, ORIGIN + Vector3.new(-3.0, 0, 0), -0.35)
			local back = stand(BUILDERS[1], folder, tomPearl, ORIGIN + Vector3.new(3.0, 0, 0), math.pi - 0.3)
			table.insert(models, front)
			table.insert(models, back)
			table.insert(targets, { name = "front", position = front:GetBoundingBox().Position })
			table.insert(targets, { name = "back", position = back:GetBoundingBox().Position })
			local puddle = front:FindFirstChild("Puddle")
			local drips = 0
			for _, d in ipairs(front:GetChildren()) do
				if d.Name == "Drip" then
					drips += 1
				end
			end
			plate(folder, string.format("Tom Pearl  CURRENT builder  %dp  base %+.2f\npuddle %s, drips %d", count, base,
				puddle and string.format("%.2f wide, underside %+.2f above base", puddle.Size.Y, (puddle.Position.Y - puddle.Size.X / 2) - (ORIGIN.Y)) or "MISSING", drips),
				ORIGIN + Vector3.new(0, 0.5, -3.2), 10)
			note("tom_pearl_closeup: parts %d, base offset %+.3f, puddle %s, drips %d", count, base, tostring(puddle ~= nil), drips)
			frameAll(camera, models, 28, 0.06)
			frameCheck("tom_pearl_closeup", camera, targets)
		end,
	})
	table.insert(views, {
		name = "tom_pearl_neighbours",
		settle = 1.3,
		hold = 1.5,
		setup = function(folder, camera)
			clearGui()
			local names = { "Imperatore Gelato", "Tom Pearl", "Titano Tuttifrutti", "Titano Tostapane", "Balena Cantante" }
			pad(folder, ORIGIN, #names * 5.4 + 16, 18)
			local models, targets = {}, {}
			for index, name in ipairs(names) do
				local def = BrainrotData.Get(name)
				if def then
					local ground = ORIGIN + Vector3.new((index - (#names + 1) / 2) * 5.4, 0, 0)
					local model, count = stand(BUILDERS[1], folder, def, ground, 0)
					table.insert(models, model)
					table.insert(targets, { name = name, position = model:GetBoundingBox().Position })
					plate(folder, string.format("%s\n%s %d coins  %dp", name, def.attack, def.coinValue, count), ground + Vector3.new(0, 0.5, -2.6), 5.2)
				end
			end
			plate(folder, "Legendaries beside Tom Pearl on value (17,000) and on attack (Lob)", ORIGIN + Vector3.new(0, 6.4, 8.4), 28)
			frameAll(camera, models, 30, 0.04)
			frameCheck("tom_pearl_neighbours", camera, targets)
		end,
	})
end

if ONLY then
	local kept = {}
	for _, view in ipairs(views) do
		for _, prefix in ipairs(ONLY) do
			if string.sub(view.name, 1, #prefix) == prefix then
				table.insert(kept, view)
				break
			end
		end
	end
	views = kept
end

return views
