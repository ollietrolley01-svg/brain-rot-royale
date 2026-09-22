-- The codex silhouette grid: every brainrot as the Brainrots tab draws an UNOWNED one.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/brainrot_silhouette_gallery.lua -OutDir <folder> -Hold 1
--
-- Why silhouettes and not the colour cards. `MenuClient.codexRow` draws a brainrot you have not
-- found yet through `brainrotPhoto(cell, def, 70, true)`, which blacks every part to one colour and
-- one material. Colour, face, eyes, accent and material -- everything the look table spends its
-- variety on -- are stripped, and only the SHAPE survives. So the codex is the one screen in the
-- game that photographs proportion on its own, and two creatures built from the same body branch at
-- the same size come out as the same black lump there no matter how different their colours are.
--
-- The photo function below is a VERBATIM copy of MenuClient.client.lua:315-336 (brainrotPhoto),
-- because MenuClient is a LocalScript and cannot be required. The only departures are marked
-- HARNESS: they add measurement and stop one bad build costing the whole sheet. Nothing about the
-- viewport, the lighting, the camera or the blacking-out is changed -- if this picture is wrong,
-- the codex is wrong the same way.
--
-- Views:
--   sil_codex_all_126        every brainrot, ordered by body then rarity, so identical bodies sit
--                            next to each other and repetition shows as a block.
--   sil_body_vocabulary_14   the fourteen body branches with no face and no extras: the entire
--                            shape vocabulary 126 characters are drawn from.
--   sil_toprarity_vs_common  each Legendary/Mythic/Secret beside a Common or Uncommon built from
--                            the same body, at the same size.
--
-- Every note line is a measurement, not a claim. `note` lines reach the run log through gallery.ps1.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local UiKit = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }
local RARITY_INDEX = {}
for index, name in ipairs(RARITIES) do
	RARITY_INDEX[name] = index
end

--------------------------------------------------------------------------------
-- MenuClient's photo, copied
--------------------------------------------------------------------------------

-- VERBATIM from MenuClient.client.lua:315 apart from the two HARNESS lines.
local function brainrotPhoto(parent, def, size, silhouette)
	local viewport = create("ViewportFrame", {
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(170, 170, 182),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Parent = parent,
	}, { rounded(10) })

	-- HARNESS: the codex calls `BrainrotModels.Build(def)` bare. One creature that throws would cost
	-- the whole sheet here, and a build failure is a finding in its own right, so it is caught and
	-- named rather than allowed to abort the view. The call itself is unchanged.
	local ok, model = pcall(BrainrotModels.Build, def)
	if not ok or not model then
		note("BUILD FAILED %s: %s", tostring(def and def.name), tostring(model))
		return viewport, nil
	end
	if silhouette then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Transparency < 1 then
				part.Color = Color3.fromRGB(16, 16, 22)
				part.Material = Enum.Material.SmoothPlastic
			end
		end
	end
	model.Parent = viewport
	BrainrotModels.FrameViewport(viewport, def)
	return viewport, model
end

--------------------------------------------------------------------------------
-- Measurement
--------------------------------------------------------------------------------

-- What the codex camera does to a creature's apparent size. FrameViewport's own arithmetic,
-- recomputed here rather than trusted: distance scales with `look.size`, so a creature that is
-- bigger in the world is photographed from further away and fills the SAME 70 px cell. Reported so
-- the claim "the codex normalises size out" is a number in the log and not an assertion.
local function codexDistance(def)
	local size = (def and def.look and def.look.size) or 1
	local metrics = BrainrotModels.Metrics(def)
	local extent = math.max(metrics.top + 0.9 - metrics.bottom, metrics.halfW * 2 + 0.6)
	return 6.8 * size * math.max(1, extent / 3.2)
end

local function measure(model)
	local parts = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			parts += 1
		end
	end
	local _, boxSize = model:GetBoundingBox()
	return parts, boxSize
end

-- A silhouette signature: the creature's bounding box divided by the distance the codex camera
-- stands at, to three decimals. Two creatures with the same signature occupy the same rectangle of
-- the same 70 px cell -- they are interchangeable AS CODEX PHOTOS. It is a lower bound on sameness
-- (two different shapes can share a box), never an upper one, so a small distinct count is
-- evidence and a large one proves nothing.
local function signature(boxSize, distance)
	return string.format("%.3f/%.3f/%.3f", boxSize.X / distance, boxSize.Y / distance, boxSize.Z / distance)
end

--------------------------------------------------------------------------------
-- The collection, ordered
--------------------------------------------------------------------------------

local all = {}
for index, def in ipairs(BrainrotData.Types) do
	table.insert(all, { def = def, order = index })
end

local byBody = table.clone(all)
table.sort(byBody, function(a, b)
	local ba = (a.def.look and a.def.look.body) or "Blob"
	local bb = (b.def.look and b.def.look.body) or "Blob"
	if ba ~= bb then
		return ba < bb
	end
	local ra = RARITY_INDEX[a.def.rarity] or 0
	local rb = RARITY_INDEX[b.def.rarity] or 0
	if ra ~= rb then
		return ra < rb
	end
	return a.order < b.order
end)

--------------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------------

local GUI_NAME = "BRR_BrainrotSilhouettes"

-- A ScreenGui under StarterGui: that is what Studio draws over the 3D view, which is what the
-- gallery captures. The gallery's own frame tag lives in CoreGui, which draws over this, so a
-- full-width panel cannot hide it.
local function shell(caption, sub, width, height)
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = create("ScreenGui", { Name = GUI_NAME, IgnoreGuiInset = true, Parent = StarterGui })
	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		-- C.Background, not C.Bg: `UiKit.Colors` has no `Bg` key, and because UiKit.create iterates
		-- pairs(props), a nil value is a key that was never in the table -- the property is silently
		-- left at Roblox's default light grey instead of erroring. tools/crate_card_gallery.lua:197
		-- and :250 have exactly that, so its panels have been drawing on default grey.
		BackgroundColor3 = C.Background,
		BorderSizePixel = 0,
		Parent = gui,
	}, { rounded(14) })
	create("TextLabel", {
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.new(1, -40, 0, 24),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = caption,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 19,
		Parent = panel,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(20, 38),
		Size = UDim2.new(1, -40, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = sub,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 13,
		Parent = panel,
	})
	return panel
end

-- One codex cell: the 70 px silhouette with its name under it, on a plate tinted per body group so
-- a run of one body reads as a block.
local function cell(parent, def, x, y, photoSize, tint, label)
	local plate = create("Frame", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(photoSize, photoSize + 14),
		BackgroundColor3 = tint,
		BorderSizePixel = 0,
		Parent = parent,
	}, { rounded(10) })
	local _, model = brainrotPhoto(plate, def, photoSize, true)
	create("TextLabel", {
		Position = UDim2.fromOffset(0, photoSize),
		Size = UDim2.fromOffset(photoSize, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = label or def.name,
		TextColor3 = Rarity.Color(def.rarity),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 9,
		Parent = plate,
	})
	return model
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local views = {}
local function view(name, settle, fn)
	table.insert(views, { name = name, settle = settle, hold = 2, setup = function(folder, camera)
		-- Nothing 3D in these views: the camera is parked somewhere empty so the sky behind the
		-- panel is flat and the picture is the UI.
		camera.CFrame = CFrame.new(0, 900, 0) * CFrame.Angles(math.rad(12), 0, 0)
		fn(folder)
	end })
end

-- 1. The whole codex, 18 across and 7 down, ordered by body then rarity.
view("sil_codex_all_126", 4, function()
	local panel = shell(
		"THE CODEX, AS AN UNOWNED PLAYER SEES IT -- all " .. #byBody .. " brainrots at brainrotPhoto(cell, def, 70, true)",
		"Ordered by body shape, then rarity. Colour and face are stripped by the codex itself; every difference you can see here is proportion.",
		1400, 716)

	local COLUMNS, PHOTO, GAP = 18, 70, 6
	local grid = create("Frame", {
		Position = UDim2.fromOffset(16, 62),
		Size = UDim2.new(1, -32, 1, -74),
		BackgroundTransparency = 1,
		Parent = panel,
	})

	local tints = { C.PanelAlt, Color3.fromRGB(54, 58, 74) }
	local bodyIndex, lastBody = 0, nil
	local counts, signatures, shapeTally = {}, {}, {}
	local distances = {}

	for index, entry in ipairs(byBody) do
		local def = entry.def
		local body = (def.look and def.look.body) or "Blob"
		if body ~= lastBody then
			bodyIndex += 1
			lastBody = body
		end
		local column = (index - 1) % COLUMNS
		local row = math.floor((index - 1) / COLUMNS)
		local model = cell(grid, def, column * (PHOTO + GAP), row * (PHOTO + 14 + 4),
			PHOTO, tints[(bodyIndex - 1) % 2 + 1])
		if model then
			local parts, boxSize = measure(model)
			local distance = codexDistance(def)
			local sig = signature(boxSize, distance)
			counts[def.name] = parts
			signatures[def.name] = sig
			shapeTally[sig] = (shapeTally[sig] or 0) + 1
			table.insert(distances, boxSize.Y / distance)
			note("cell %03d %-28s %-9s %-10s size=%.2f parts=%d box=%.2fx%.2fx%.2f d=%.2f sig=%s",
				index, def.name, def.rarity, body, (def.look and def.look.size) or 1, parts,
				boxSize.X, boxSize.Y, boxSize.Z, distance, sig)
		end
	end

	local distinct = 0
	for _ in pairs(shapeTally) do
		distinct += 1
	end
	note("CODEX SIGNATURE ARITHMETIC: %d creatures examined, %d distinct silhouette signatures.", #byBody, distinct)

	-- How flat the codex camera makes apparent size: min and max of boxY/distance over the set.
	local low, high = math.huge, -math.huge
	for _, value in ipairs(distances) do
		low, high = math.min(low, value), math.max(high, value)
	end
	note("APPARENT HEIGHT boxY/distance over %d creatures: min %.3f, max %.3f, spread x%.2f -- the codex camera distance scales with look.size, so `size` is close to invisible on this screen.",
		#distances, low, high, high / math.max(low, 1e-6))

	-- The biggest interchangeable clusters, largest first.
	local clusters = {}
	for sig, count in pairs(shapeTally) do
		table.insert(clusters, { sig = sig, count = count })
	end
	table.sort(clusters, function(a, b)
		return a.count > b.count
	end)
	for rank = 1, math.min(8, #clusters) do
		local names = {}
		for name, sig in pairs(signatures) do
			if sig == clusters[rank].sig then
				table.insert(names, name)
			end
		end
		table.sort(names)
		note("cluster %d: %d creatures share signature %s -- %s", rank, clusters[rank].count, clusters[rank].sig,
			table.concat(names, ", "))
	end
end)

-- 2. The shape vocabulary on its own: each body branch with no face and no extras.
view("sil_body_vocabulary_14", 3, function()
	-- Which bodies exist, and how many characters are drawn from each.
	local population, order = {}, {}
	for _, entry in ipairs(byBody) do
		local body = (entry.def.look and entry.def.look.body) or "Blob"
		if not population[body] then
			population[body] = 0
			table.insert(order, body)
		end
		population[body] += 1
	end

	local panel = shell(
		"THE ENTIRE SHAPE VOCABULARY: " .. #order .. " body branches for " .. #byBody .. " characters",
		"Each is built with no face and no extras, at size 1.00 -- the mass every character in that column starts from. The number under each is how many characters use it.",
		1400, 460)

	local PHOTO, GAP = 120, 18
	local grid = create("Frame", {
		Position = UDim2.fromOffset(20, 66),
		Size = UDim2.new(1, -40, 1, -78),
		BackgroundTransparency = 1,
		Parent = panel,
	})

	for index, body in ipairs(order) do
		local bare = { name = body, rarity = "Common",
			look = { body = body, color = Color3.fromRGB(200, 200, 200), eyes = "Round", mouth = "None", extras = {} } }
		local column = (index - 1) % 7
		local row = math.floor((index - 1) / 7)
		local plate = create("Frame", {
			Position = UDim2.fromOffset(column * (PHOTO + GAP), row * (PHOTO + 42)),
			Size = UDim2.fromOffset(PHOTO, PHOTO + 34),
			BackgroundColor3 = C.PanelAlt,
			BorderSizePixel = 0,
			Parent = grid,
		}, { rounded(10) })
		local _, model = brainrotPhoto(plate, bare, PHOTO, true)
		create("TextLabel", {
			Position = UDim2.fromOffset(0, PHOTO + 2),
			Size = UDim2.fromOffset(PHOTO, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = body,
			TextColor3 = C.Text,
			TextSize = 13,
			Parent = plate,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(0, PHOTO + 17),
			Size = UDim2.fromOffset(PHOTO, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = population[body] .. " characters",
			TextColor3 = C.Muted,
			TextSize = 11,
			Parent = plate,
		})
		if model then
			local parts, boxSize = measure(model)
			note("body %-9s used by %3d characters, bare mass %d parts, box %.2fx%.2fx%.2f",
				body, population[body], parts, boxSize.X, boxSize.Y, boxSize.Z)
		end
	end
end)

-- 3. Every Legendary, Mythic and Secret beside a Common or Uncommon built from the same body.
view("sil_toprarity_vs_common", 4, function()
	local commonFor = {}
	for _, entry in ipairs(byBody) do
		local def = entry.def
		if def.rarity == "Common" or def.rarity == "Uncommon" then
			local body = (def.look and def.look.body) or "Blob"
			if not commonFor[body] then
				commonFor[body] = def
			end
		end
	end

	local pairsList = {}
	for _, entry in ipairs(byBody) do
		local def = entry.def
		if def.rarity == "Legendary" or def.rarity == "Mythic" or def.rarity == "Secret" then
			local body = (def.look and def.look.body) or "Blob"
			table.insert(pairsList, { top = def, base = commonFor[body], body = body })
		end
	end

	local shared = 0
	for _, pair in ipairs(pairsList) do
		if pair.base then
			shared += 1
		end
	end

	local panel = shell(
		string.format("TOP RARITY AGAINST THE CHEAPEST THING WITH THE SAME BODY -- %d of %d share one",
			shared, #pairsList),
		"Left of each pair is the Legendary / Mythic / Secret. Right is the first Common or Uncommon built from the same body branch. Same mass, same posture, same lump.",
		1400, 560)

	local PHOTO, PAIR_GAP, COL_GAP = 70, 6, 22
	local grid = create("Frame", {
		Position = UDim2.fromOffset(18, 64),
		Size = UDim2.new(1, -36, 1, -76),
		BackgroundTransparency = 1,
		Parent = panel,
	})
	local PAIR_WIDTH = PHOTO * 2 + PAIR_GAP
	local PER_ROW = 8

	for index, pair in ipairs(pairsList) do
		local column = (index - 1) % PER_ROW
		local row = math.floor((index - 1) / PER_ROW)
		local x = column * (PAIR_WIDTH + COL_GAP)
		local y = row * (PHOTO + 14 + 12)
		local topModel = cell(grid, pair.top, x, y, PHOTO, C.PanelAlt)
		local baseModel = pair.base and cell(grid, pair.base, x + PHOTO + PAIR_GAP, y, PHOTO,
			Color3.fromRGB(54, 58, 74))
		if topModel and baseModel then
			local topParts, topBox = measure(topModel)
			local baseParts, baseBox = measure(baseModel)
			local topSize = (pair.top.look and pair.top.look.size) or 1
			local baseSize = (pair.base.look and pair.base.look.size) or 1
			note("pair %02d %-9s %-26s size=%.2f parts=%d box=%.2fx%.2fx%.2f  vs  %-26s size=%.2f parts=%d box=%.2fx%.2fx%.2f  (size ratio %.2f)",
				index, pair.body, pair.top.name, topSize, topParts, topBox.X, topBox.Y, topBox.Z,
				pair.base.name, baseSize, baseParts, baseBox.X, baseBox.Y, baseBox.Z, topSize / baseSize)
		end
	end
	note("TOP-RARITY SHARING: %d of %d Legendary/Mythic/Secret entries are built from a body branch a Common or Uncommon also uses.",
		shared, #pairsList)
end)

return views
