-- Easter eggs and the storm, before and after, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/eggs_gallery.lua -OutDir <folder> -PlaceFile <private build>
--
-- Every egg is built twice on a flat strip of real terrain: once from `EasterEggsBefore` (a copy of
-- the module as it was, put in a PRIVATE tree only, never the project) and once from `EasterEggs`
-- as it is now, and each is photographed the two ways a player meets it: from across the field at
-- head height, and standing next to it. The arrest tableau gets two more (its roof, its figures).
--
-- Measured as well as pictured, on the current module: flush face pairs AS WRITTEN (ZFight.Scan
-- before any fix), then how many parts the map's own z-fight pass moves and how far. Parts moved
-- is the number that matters — a flush count taken after a fix pass would be vacuous. Planted
-- every run: two faces 0.02 apart must be seen and must move, or the counts mean nothing.
--
-- The storm: StormClient's ring as the client draws it (StormClientBefore, the copy, and StormClient
-- if its source differs), photographed from outside, inside and above at a radius of 175; then
-- static mock-ups of candidate looks for Oliver's "brainrot themed" storm, built here from parts.
--
-- Nothing here is in the built place until EasterEggs / StormClient land.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local After = require(modules:WaitForChild("EasterEggs"))
local beforeModule = modules:FindFirstChild("EasterEggsBefore")
local Before = beforeModule and require(beforeModule) or nil

-- Far from the map's coordinates and each other. The egg rows run along +X; the storm sits 800 south.
local EGG_ORIGIN = Vector3.new(7000, 0, 7000)
local ROW_GAP = 220
local SPACING = 90
local STORM_CENTRE = Vector3.new(7000, 0, 7800)
local STORM_RADIUS = 175
local SETTLE, HOLD = 1.4, 1.5

local state = { checks = 0, failures = 0 }
local views = {}

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function check(ok, text)
	state.checks += 1
	if not ok then
		state.failures += 1
	end
	note((ok and "PASS  " or "FAIL  ") .. text)
end

local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 50
	camera.CFrame = CFrame.lookAt(eye, target)
end

local function add(name, fn, hold)
	table.insert(views, { name = name, settle = SETTLE, hold = hold or HOLD, setup = fn })
end

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }
terrainParams.IgnoreWater = true

local function groundAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), terrainParams)
	return hit and hit.Position.Y or nil
end

local function countParts(model)
	local count = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- The eggs
--------------------------------------------------------------------------------

-- Both rows built once, on terrain, and kept outside the gallery's per-view folder. Returns the
-- models by name.
local function buildRow(module, rowIndex)
	local row = Instance.new("Folder")
	row.Name = "EggsRow" .. rowIndex
	row.Parent = state.stage
	local origin = EGG_ORIGIN + Vector3.new(0, 0, (rowIndex - 1) * ROW_GAP)
	local surface = groundAt(origin.X, origin.Z)
	origin = Vector3.new(origin.X, surface or origin.Y, origin.Z)
	local models = module.BuildAll(row, origin, SPACING)
	local byName, origins = {}, {}
	for index, model in ipairs(models) do
		byName[model.Name] = model
		-- Where BuildAll stood this egg (its builder's origin), so pair positions can be quoted
		-- relative to it and found in the source.
		origins[model] = origin + Vector3.new((index - 1) * SPACING, 0, 0)
	end
	return byName, models, origins
end

-- The map's z-fight pass, measured on a fresh build: pairs as written, then what Fix moves.
local function measureRow(label, models, origins)
	local totalParts, totalFlush, totalMoved, worst, worstAt = 0, 0, 0, 0, "-"
	local rows = {}
	for _, model in ipairs(models) do
		local before = {}
		local parts = 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				parts += 1
				before[part] = { part.Position, part.Size }
			end
		end
		local pairsFound = ZFight.Scan({ model })
		local flush = #pairsFound
		-- Every part is called "Part", so a pair is named by where it stands relative to the egg's
		-- own origin and how big it is: enough to find both lines in the builder.
		local eggOrigin = origins and origins[model] or model:GetPivot().Position
		local function where(part)
			if part == workspace.Terrain then
				return "Terrain"
			end
			local rel = part.Position - eggOrigin
			return string.format("(%.2f,%.2f,%.2f) %.2fx%.2fx%.2f", rel.X, rel.Y, rel.Z, part.Size.X, part.Size.Y, part.Size.Z)
		end
		local described = {}
		for index = 1, math.min(#pairsFound, 14) do
			local pair = pairsFound[index]
			table.insert(described, string.format("n(%.0f,%.0f,%.0f) gap %.3f: %s | %s", pair.normal.X, pair.normal.Y, pair.normal.Z, pair.gap,
				where(pair.a), where(pair.b)))
		end
		ZFight.Fix({ model })
		local moved, eggWorst, eggWorstAt = 0, 0, "-"
		for part, was in pairs(before) do
			local shift = (part.Position - was[1]).Magnitude + (part.Size - was[2]).Magnitude
			if shift > 0.005 then
				moved += 1
				if shift > eggWorst then
					eggWorst, eggWorstAt = shift, part.Name .. " vs " .. tostring(part:GetAttribute("ZFixedWith"))
				end
			end
		end
		totalParts += parts
		totalFlush += flush
		totalMoved += moved
		if eggWorst > worst then
			worst, worstAt = eggWorst, model.Name .. "/" .. eggWorstAt
		end
		table.insert(rows, string.format("%s %s: %d parts, %d flush as written, %d moved (worst %.3f %s)", label, model.Name, parts, flush,
			moved, eggWorst, eggWorstAt))
		if label == "after" then
			for _, line in ipairs(described) do
				table.insert(rows, "    pair " .. line)
			end
		end
	end
	note(string.format("zfight %s: %d eggs, %d parts, %d flush pairs as written, %d parts moved by the pass (worst %.3f on %s)",
		label, #models, totalParts, totalFlush, totalMoved, worst, worstAt))
	for _, line in ipairs(rows) do
		note("zfight " .. line)
	end
	return totalMoved
end

add("stage", function(_, camera)
	local old = workspace:FindFirstChild("EggsStage")
	if old then
		old:Destroy()
	end
	state.stage = Instance.new("Folder")
	state.stage.Name = "EggsStage"
	state.stage.Parent = workspace

	-- A strip of grass under each row and a field under the storm, then a frame for the fills to
	-- become raycastable (a ray straight after a fill still meets the terrain as it was).
	local terrain = workspace.Terrain
	terrain:FillBlock(CFrame.new(EGG_ORIGIN.X + 405, EGG_ORIGIN.Y - 4, EGG_ORIGIN.Z + ROW_GAP / 2), Vector3.new(1100, 8, 200 + ROW_GAP),
		Enum.Material.Grass)
	terrain:FillBlock(CFrame.new(STORM_CENTRE.X, STORM_CENTRE.Y - 4, STORM_CENTRE.Z), Vector3.new(620, 8, 620), Enum.Material.Grass)
	task.wait(0.5)
	local surface = groundAt(EGG_ORIGIN.X, EGG_ORIGIN.Z)
	check(surface ~= nil, string.format("terrain strip under the eggs reads back (surface %s)", surface and string.format("%.2f", surface) or "nil"))
	state.eggGround = surface or EGG_ORIGIN.Y
	state.stormGround = groundAt(STORM_CENTRE.X, STORM_CENTRE.Z - STORM_RADIUS) or STORM_CENTRE.Y

	state.afterByName, state.afterModels, state.afterOrigins = buildRow(After, 2)
	if Before then
		state.beforeByName, state.beforeModels, state.beforeOrigins = buildRow(Before, 1)
	else
		note("no EasterEggsBefore module in this place: before views skipped")
		state.beforeByName, state.beforeModels = {}, {}
	end
	task.wait(0.5)
	check(#state.afterModels >= 10, string.format("%d eggs built from the current module", #state.afterModels))

	-- Measured before any render, so the pictures show the models as the map's pass leaves them.
	if Before then
		measureRow("before", state.beforeModels, state.beforeOrigins)
	end
	local movedAfter = measureRow("after", state.afterModels, state.afterOrigins)
	note(string.format("zfight target for #42: parts moved by the pass -> 0; current module: %d", movedAfter))

	-- Planted: two faces 0.02 apart must be seen by Scan and moved by Fix.
	local planted = Instance.new("Model")
	planted.Name = "PlantedPair"
	planted.Parent = state.stage
	local function slab(size, at)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.CFrame = CFrame.new(at)
		part.Parent = planted
		return part
	end
	local base = EGG_ORIGIN + Vector3.new(-60, state.eggGround + 3, 0)
	slab(Vector3.new(6, 1, 6), base)
	local lid = slab(Vector3.new(3, 1, 3), base + Vector3.new(0, 0.02, 0))
	local seen = #ZFight.Scan({ planted })
	local lidWas = lid.Position
	ZFight.Fix({ planted })
	local plantedMoved = (lid.Position - lidWas).Magnitude + math.abs(lid.Size.Y - 1)
	check(seen > 0 and plantedMoved > 0.01, string.format("planted 0.02 pair: seen %d, moved %.3f (so the counts above can fail)", seen, plantedMoved))

	look(camera, EGG_ORIGIN + Vector3.new(405, state.eggGround + 140, -260), EGG_ORIGIN + Vector3.new(405, state.eggGround, ROW_GAP / 2), 70)
end, 1)

-- The two shots a player gets: across the field at head height, then standing at it. Both from
-- the -Z side, which is the side the builders treat as the front.
local function frameFar(camera, model, ground)
	local box, size = model:GetBoundingBox()
	local out = math.max(60, size.Y * 1.4 + 20)
	local eye = Vector3.new(box.Position.X + out * 0.35, ground + 5, box.Position.Z - out)
	look(camera, eye, Vector3.new(box.Position.X, ground + math.min(size.Y * 0.5, 14), box.Position.Z), 50)
end

local function frameClose(camera, model, ground)
	local box, size = model:GetBoundingBox()
	local out = math.max(size.X, size.Z) * 0.55 + 8
	local eye = Vector3.new(box.Position.X + out * 0.3, ground + 4.6, box.Position.Z - out)
	look(camera, eye, Vector3.new(box.Position.X, ground + math.min(size.Y * 0.45, 8), box.Position.Z), 58)
end

local ORDER = { "Carrot", "Camp", "Guest", "SixSeven", "LivingRoom", "Fridgehenge", "NormalGuy", "Squeak", "Obby", "Arrest" }

for index, id in ipairs(ORDER) do
	for _, pass in ipairs({ "before", "after" }) do
		for _, shot in ipairs({ { "far", frameFar }, { "close", frameClose } }) do
			add(string.format("egg_%02d_%s_%s_%s", index, id, pass, shot[1]), function(_, camera)
				local byName = pass == "before" and state.beforeByName or state.afterByName
				local model = byName and byName[id]
				if not model then
					note(string.format("%s %s: NOT BUILT", id, pass))
					look(camera, EGG_ORIGIN + Vector3.new(0, 40, -80), EGG_ORIGIN, 50)
					return
				end
				note(string.format("%s %s %s [%d parts]", id, pass, shot[1], countParts(model)))
				shot[2](camera, model, state.eggGround)
			end)
		end
	end
end

-- The arrest's two named faults (Oliver: "the roof is messed up, and his arms are messed up").
for _, pass in ipairs({ "before", "after" }) do
	-- A view that has nothing to show still moves the camera: the first run left it where the
	-- previous view had put it, and the frame was filed under this view's name.
	add("arrest_roof_" .. pass, function(_, camera)
		local model = (pass == "before" and state.beforeByName or state.afterByName)["Arrest"]
		if not model then
			note("arrest roof " .. pass .. ": NOT BUILT")
			look(camera, EGG_ORIGIN + Vector3.new(0, 40, -80), EGG_ORIGIN, 50)
			return
		end
		local pivot = model:GetPivot().Position
		-- The house stands 15 behind the pivot; the ridge is at about 14 up.
		local house = Vector3.new(pivot.X, state.eggGround, pivot.Z + 15)
		look(camera, house + Vector3.new(-26, 16, -30), house + Vector3.new(0, 9, 0), 45)
	end)
	add("arrest_arms_" .. pass, function(_, camera)
		local model = (pass == "before" and state.beforeByName or state.afterByName)["Arrest"]
		if not model then
			note("arrest arms " .. pass .. ": NOT BUILT")
			look(camera, EGG_ORIGIN + Vector3.new(0, 40, -80), EGG_ORIGIN, 50)
			return
		end
		local pivot = model:GetPivot().Position
		local figures = Vector3.new(pivot.X, state.eggGround, pivot.Z)
		look(camera, figures + Vector3.new(-4, 6.5, -13), figures + Vector3.new(0, 4.8, 0), 40)
	end)
end

--------------------------------------------------------------------------------
-- The storm as the client draws it
--------------------------------------------------------------------------------

-- Loads a LocalScript's source in this (edit-mode) context with its server remote swapped for a
-- BindableEvent we can fire (the way tools/effects_gallery.lua does). Returns the event.
local function loadClientScript(name, remoteName)
	local script = Scripts:WaitForChild(name)
	local source = script.Source
	local bindable = Instance.new("BindableEvent")
	local key = "__" .. name .. "Event"
	_G[key] = { OnClientEvent = bindable.Event }
	source = source:gsub('Remotes%.Event%("' .. remoteName .. '"%)', "_G." .. key)
	source = source:gsub('require%(script%.Parent:WaitForChild%("Sfx"%)%)', "{ PlayAt = function() end, Play = function() end }")
	local fn, err = loadstring(source, name)
	assert(fn, tostring(err))
	fn()
	return bindable
end

local function wallParts()
	local wall = workspace:FindFirstChild("StormWall")
	local count = 0
	if wall then
		for _, part in ipairs(wall:GetDescendants()) do
			if part:IsA("BasePart") then
				count += 1
			end
		end
	end
	return wall, count
end

-- Scale for the storm shots: a few plain blocks near the wall, and a stand-in for a player.
local function stormScenery()
	local folder = Instance.new("Folder")
	folder.Name = "StormScenery"
	folder.Parent = state.stage
	local g = state.stormGround
	for index, spec in ipairs({ { -30, -150, 12, 9, 12 }, { 22, -158, 16, 7, 10 }, { 60, -140, 9, 12, 9 } }) do
		local block = Instance.new("Part")
		block.Name = "ScaleBlock" .. index
		block.Anchored = true
		block.Size = Vector3.new(spec[3], spec[4], spec[5])
		block.CFrame = CFrame.new(STORM_CENTRE.X + spec[1], g + spec[4] / 2, STORM_CENTRE.Z + spec[2])
		block.Color = Color3.fromRGB(150, 146, 140)
		block.Material = Enum.Material.Concrete
		block.Parent = folder
	end
	local player = Instance.new("Part")
	player.Name = "PlayerStandIn"
	player.Anchored = true
	player.Size = Vector3.new(2, 5, 1)
	player.CFrame = CFrame.new(STORM_CENTRE.X + 4, g + 2.5, STORM_CENTRE.Z - 162)
	player.Color = Color3.fromRGB(60, 120, 200)
	player.Parent = folder
	return folder
end

local STORM_INFO = { status = "Shrinking", center = STORM_CENTRE, radius = STORM_RADIUS, targetCenter = STORM_CENTRE,
	targetRadius = STORM_RADIUS * 0.62, phase = 2, totalPhases = 5, secondsLeft = 30, damagePerSecond = 2 }

-- Each look's `prepare` takes the previous look down itself, so nothing is left to a timer.
local function stormShots(label, prepare)
	add("storm_" .. label .. "_outside", function(_, camera)
		if not state.scenery then
			state.scenery = stormScenery()
		end
		prepare()
		local g = state.stormGround
		look(camera, STORM_CENTRE + Vector3.new(-10, g + 6, -(STORM_RADIUS + 55)), STORM_CENTRE + Vector3.new(0, g + 16, -STORM_RADIUS), 60)
	end, 2)
	add("storm_" .. label .. "_inside", function(_, camera)
		local g = state.stormGround
		look(camera, STORM_CENTRE + Vector3.new(-12, g + 5, -(STORM_RADIUS - 26)), STORM_CENTRE + Vector3.new(0, g + 10, -STORM_RADIUS), 65)
	end, 2)
	add("storm_" .. label .. "_above", function(_, camera)
		local g = state.stormGround
		look(camera, STORM_CENTRE + Vector3.new(0, g + 1000, -720), STORM_CENTRE + Vector3.new(0, g + 300, 0), 60)
	end, 2)
end

local beforeScript = Scripts:FindFirstChild("StormClientBefore")
local afterScript = Scripts:FindFirstChild("StormClient")

if beforeScript then
	stormShots("before", function()
		state.stormBefore = loadClientScript("StormClientBefore", "StormChanged")
		state.stormBefore:Fire(STORM_INFO)
		task.wait(0.6)
		local wall, laid = wallParts()
		check(wall ~= nil and laid > 0, string.format("StormClientBefore laid out %d wall parts", laid))
	end)
end

if afterScript and (not beforeScript or afterScript.Source ~= beforeScript.Source) then
	stormShots("after", function()
		if state.stormBefore then
			state.stormBefore:Fire({ status = "Idle" })
			task.wait(0.3)
		end
		state.stormAfter = loadClientScript("StormClient", "StormChanged")
		state.stormAfter:Fire(STORM_INFO)
		task.wait(0.8)
		local wall, laid = wallParts()
		check(wall ~= nil and laid > 0, string.format("StormClient laid out %d wall parts", laid))
		-- An Idle broadcast must take the whole ring down (the planted fault for the storm views).
		state.stormAfter:Fire({ status = "Idle" })
		task.wait(0.3)
		local gone = workspace:FindFirstChild("StormWall") == nil
		check(gone, "planted: an Idle storm takes the ring down")
		state.stormAfter:Fire(STORM_INFO)
		task.wait(0.8)
	end)
else
	note("StormClient source is unchanged from StormClientBefore: after views skipped")
end

--------------------------------------------------------------------------------
-- Mock-ups for #45 ("make the storm brainrot themed"): static parts, built here only, so Oliver can
-- pick a direction from a picture before anything is written into StormClient.
--------------------------------------------------------------------------------

local SEGMENTS = 96

local function mockPart(folder, name, size, cframe, color, material, transparency, shape)
	local part = Instance.new("Part")
	part.Name = name
	if shape then
		part.Shape = shape
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.Neon
	part.Transparency = transparency or 0
	part.Parent = folder
	return part
end

local function blob(folder, name, size, cframe, color, material, transparency)
	local part = mockPart(folder, name, size, cframe, color, material, transparency)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

-- Each segment's frame: on the ring at `radius`, X along the ring, facing the centre.
local function ringFrame(index, radius, y)
	local angle = (index - 0.5) / SEGMENTS * math.pi * 2
	local flat = Vector3.new(STORM_CENTRE.X, y, STORM_CENTRE.Z)
	local base = flat + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
	return CFrame.lookAt(base, flat)
end

-- Chord, not arc plus a stud: the old wall's segments overlapped by a stud and every overlap drew
-- double, which showed as 96 bright stripes (claude-4a's finding). A hair closes the outer seam.
local function chord(radius)
	return 2 * radius * math.sin(math.pi / SEGMENTS) + 0.06
end

local function plainWall(folder, color, transparency, bottom, top)
	local length = chord(STORM_RADIUS)
	for index = 1, SEGMENTS do
		mockPart(folder, "Wall", Vector3.new(length, top - bottom, 1.5), ringFrame(index, STORM_RADIUS, (top + bottom) / 2), color, Enum.Material.Neon,
			transparency)
	end
end

local function labelFace(part, text, color, background)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.MaxDistance = 400
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = background or Color3.new()
	label.BackgroundTransparency = background and 0 or 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeTransparency = 0.5
	label.Parent = gui
	gui.Parent = part
end

local MOCKS = {}

-- A: "Rot Tide". The wall is the rot itself: deep purple, a churning acid-green scum at the foot,
-- and the game's cartoon eyes peering out of it at whoever is still outside.
MOCKS.rot_tide = function(folder)
	local g = state.stormGround
	plainWall(folder, Color3.fromRGB(122, 58, 210), 0.82, -60, 900)
	local length = chord(STORM_RADIUS - 0.6)
	for index = 1, SEGMENTS do
		mockPart(folder, "Band", Vector3.new(length, 34, 1), ringFrame(index, STORM_RADIUS - 0.6, g + 8), Color3.fromRGB(176, 118, 255), Enum.Material.Neon, 0.55)
	end
	local rng = Random.new(67)
	for index = 1, SEGMENTS, 2 do
		local frame = ringFrame(index, STORM_RADIUS - 1.6, g)
		local size = rng:NextNumber(3.5, 6.5)
		blob(folder, "Scum", Vector3.new(size * 1.6, size * 0.6, size), frame * CFrame.new(rng:NextNumber(-3, 3), size * 0.12, 0),
			Color3.fromRGB(150, 255, 90), Enum.Material.Neon, 0.15)
	end
	for index = 3, SEGMENTS, 6 do
		local frame = ringFrame(index, STORM_RADIUS - 2.4, g)
		local height = rng:NextNumber(12, 30)
		local size = rng:NextNumber(3.2, 4.6)
		local pair = rng:NextNumber() < 0.75
		for _, x in ipairs(pair and { -size * 0.7, size * 0.7 } or { 0 }) do
			local eyeSize = pair and size or size * 1.5
			local at = frame * CFrame.new(x, height, 0)
			mockPart(folder, "Eye", Vector3.new(eyeSize, eyeSize, eyeSize), at, Color3.fromRGB(246, 246, 250), Enum.Material.SmoothPlastic, 0.1,
				Enum.PartType.Ball)
			mockPart(folder, "Pupil", Vector3.new(eyeSize * 0.42, eyeSize * 0.42, eyeSize * 0.42), at * CFrame.new(0, -eyeSize * 0.05, -eyeSize * 0.34),
				Color3.fromRGB(20, 20, 28), Enum.Material.SmoothPlastic, 0, Enum.PartType.Ball)
		end
	end
	-- Drips of rot running down off the band.
	for index = 2, SEGMENTS, 5 do
		local frame = ringFrame(index, STORM_RADIUS - 1.2, g)
		local fall = rng:NextNumber(4, 12)
		mockPart(folder, "Drip", Vector3.new(0.9, fall, 0.5), frame * CFrame.new(rng:NextNumber(-4, 4), 25 - fall / 2, 0), Color3.fromRGB(150, 255, 90),
			Enum.Material.Neon, 0.25)
	end
end

-- B: "Signal Lost". The storm is the feed breaking up: a wall of static in pixel rows low down,
-- a scanline, and warning panels in the game's own voice.
MOCKS.signal_lost = function(folder)
	local g = state.stormGround
	plainWall(folder, Color3.fromRGB(140, 126, 210), 0.86, g + 60, 900)
	local tones = { Color3.fromRGB(70, 60, 110), Color3.fromRGB(150, 140, 215), Color3.fromRGB(110, 90, 190), Color3.fromRGB(215, 205, 255) }
	local rng = Random.new(6767)
	local length = chord(STORM_RADIUS)
	for row = 0, 5 do
		for index = 1, SEGMENTS do
			local tone = tones[rng:NextInteger(1, #tones)]
			mockPart(folder, "Static", Vector3.new(length, 10, 1.5), ringFrame(index, STORM_RADIUS, g + row * 10 + 5), tone, Enum.Material.Neon,
				rng:NextNumber(0.55, 0.78))
		end
	end
	for index = 1, SEGMENTS do
		mockPart(folder, "Scanline", Vector3.new(chord(STORM_RADIUS - 0.9), 1.4, 0.6), ringFrame(index, STORM_RADIUS - 0.9, g + 23), Color3.fromRGB(240, 240, 255),
			Enum.Material.Neon, 0.35)
	end
	local lines = { "NO SIGNAL", "ROT ZONE", "TOUCH GRASS", "STAY INSIDE", "SKILL ISSUE", "LOADING... 99%" }
	for index = 1, SEGMENTS, 8 do
		local panel = mockPart(folder, "Panel", Vector3.new(11, 3.6, 0.6), ringFrame(index, STORM_RADIUS - 1.3, g + 13), Color3.fromRGB(18, 16, 30),
			Enum.Material.SmoothPlastic, 0)
		labelFace(panel, lines[(index // 8) % #lines + 1], Color3.fromRGB(150, 255, 90))
	end
end

-- C: "Brainwall". The edge of the map is where the brainrot has physically piled up: a ridge of
-- pink lobes at the foot of a magenta wall, with green rot dripping down them.
MOCKS.brainwall = function(folder)
	local g = state.stormGround
	plainWall(folder, Color3.fromRGB(255, 110, 205), 0.84, -60, 900)
	local rng = Random.new(8080)
	local pink = Color3.fromRGB(250, 150, 190)
	local fold = Color3.fromRGB(226, 112, 160)
	for index = 1, SEGMENTS do
		local frame = ringFrame(index, STORM_RADIUS + (index % 2 == 0 and 2.5 or -2.5), g)
		local size = rng:NextNumber(11, 16)
		blob(folder, "Lobe", Vector3.new(size * 1.25, size * 0.8, size), frame * CFrame.new(rng:NextNumber(-2, 2), size * 0.32, 0), pink,
			Enum.Material.SmoothPlastic, 0.05)
		-- A fold line across each lobe, so it reads as brain rather than as bubblegum.
		blob(folder, "Fold", Vector3.new(size * 0.35, size * 0.7, size * 1.05), frame * CFrame.new(rng:NextNumber(-2, 2), size * 0.34, 0), fold,
			Enum.Material.SmoothPlastic, 0.05)
	end
	for index = 1, SEGMENTS, 2 do
		local frame = ringFrame(index, STORM_RADIUS, g)
		local size = rng:NextNumber(6, 9)
		blob(folder, "LobeTop", Vector3.new(size * 1.3, size * 0.8, size * 0.9), frame * CFrame.new(rng:NextNumber(-3, 3), 10 + size * 0.3, 0), pink,
			Enum.Material.SmoothPlastic, 0.05)
	end
	for index = 1, SEGMENTS, 3 do
		local frame = ringFrame(index, STORM_RADIUS - 6, g)
		local fall = rng:NextNumber(5, 14)
		mockPart(folder, "Drip", Vector3.new(1.1, fall, 0.7), frame * CFrame.new(rng:NextNumber(-5, 5), 18 - fall / 2, 0), Color3.fromRGB(150, 255, 90),
			Enum.Material.Neon, 0.2)
	end
	for index = 1, SEGMENTS do
		mockPart(folder, "Glow", Vector3.new(chord(STORM_RADIUS - 0.8), 6, 1), ringFrame(index, STORM_RADIUS - 0.8, g + 24), Color3.fromRGB(255, 170, 230),
			Enum.Material.Neon, 0.5)
	end
end

for _, name in ipairs({ "rot_tide", "signal_lost", "brainwall" }) do
	stormShots("mock_" .. name, function()
		if state.stormBefore then
			state.stormBefore:Fire({ status = "Idle" })
		end
		if state.stormAfter then
			state.stormAfter:Fire({ status = "Idle" })
		end
		if state.mock then
			state.mock:Destroy()
		end
		state.mock = Instance.new("Folder")
		state.mock.Name = "StormMock_" .. name
		state.mock.Parent = state.stage
		MOCKS[name](state.mock)
		local count = 0
		for _, part in ipairs(state.mock:GetChildren()) do
			if part:IsA("BasePart") then
				count += 1
			end
		end
		note(string.format("mock %s: %d parts", name, count))
	end)
end

add("result", function(_, camera)
	if state.mock then
		state.mock:Destroy()
		state.mock = nil
	end
	note(string.format("RESULT %s: %d checks, %d failed", state.failures == 0 and "PASS" or "FAIL", state.checks, state.failures))
	look(camera, EGG_ORIGIN + Vector3.new(405, state.eggGround + 140, -260), EGG_ORIGIN + Vector3.new(405, state.eggGround, ROW_GAP / 2), 70)
end, 1)

return views
