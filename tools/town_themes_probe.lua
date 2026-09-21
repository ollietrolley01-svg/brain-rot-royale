-- Town themes probe, for tools/runtest.ps1 -Probe (one map per run: edit MAP_ID and SEED below).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/town_themes_probe.lua -WaitSeconds 900
--
-- 1. Compiles and requires TownThemes.
-- 2. Builds every theme on flat plates (TownThemes.BuildAll), with no z-fight pass anywhere, and checks
--    each one on its own: flush faces (the real z-fight number: nothing has been nudged yet); parts
--    reaching past the ground the piece claims (a set piece's width x depth, a prop's radius); and
--    parts that move on clients (AmbientSpin / Sway / Bob) but still collide or stop bullets on the
--    server, where they never moved.
-- 3. The springs: the launch rules against a stand-in character, the touch wiring (a foot, an
--    accessory handle, a part of something that isn't a character), and where the last spring's
--    throw lands.
-- 4. Builds the whole map twice from the same seed: without a terrain pad API (placement counts only)
--    and with one (MapTerrain.FlattenPad, or a stand-in when it doesn't exist yet), and for the second
--    reports per town and audits: solid theme parts inside solid parts of anything else; parts buried
--    under the terrain; pieces standing clear of the ground; what the map's z-fight pass had to move in
--    themes (0 is the target: a flush pair counted AFTER that pass could never fail, so it isn't one);
--    bot paths round each set piece; spring triggers.
--
-- Every audit that can report "0" first catches a fault planted on purpose (the SELFTEST line), so
-- a 0 means nothing was found, not that nothing was looked at. Each prints how many things it checked.
local MAP_ID, SEED = "SahurSprings", 101

local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(RS:WaitForChild("Shared"):WaitForChild("ZFight"))

local function out(fmt, ...)
	print("[THEMES] " .. string.format(fmt, ...))
end

local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

local selfTests = {}
local function selfTest(name, caught, detail)
	table.insert(selfTests, string.format("%s=%s%s", name, caught and "caught" or "MISSED", detail and (" [" .. detail .. "]") or ""))
end

local moduleScript = modules:FindFirstChild("TownThemes")
if not moduleScript then
	out("no TownThemes module in this place")
	return
end
local fn, compileError = loadstring(moduleScript.Source, "TownThemes")
out("compile: %s", fn and "ok" or tostring(compileError))
local okRequire, TownThemes = pcall(require, moduleScript)
out("require: %s", okRequire and "ok" or tostring(TownThemes))
if not okRequire then
	return
end
out("themes defined: %d", #TownThemes.Order)

local function partsOf(root)
	local list = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

--------------------------------------------------------------------------------
-- Shared measurements
--------------------------------------------------------------------------------

-- The points a part reaches to, for footprint checks: an oriented box's eight corners; a ball's
-- centre pushed out by its radius; a cylinder's axis ends pushed out by its radius.
local function reachPoints(part)
	local cf, size = part.CFrame, part.Size
	local points = {}
	if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		local r = size.X / 2
		for _, d in ipairs({ Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis }) do
			table.insert(points, cf.Position + d * r)
		end
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		local r = math.min(size.Y, size.Z) / 2
		for _, sx in ipairs({ -1, 1 }) do
			local tip = cf.Position + cf.RightVector * (sx * size.X / 2)
			for _, d in ipairs({ Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis }) do
				table.insert(points, tip + d * r)
			end
		end
	else
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					table.insert(points, cf:PointToWorldSpace(Vector3.new(sx * size.X / 2, sy * size.Y / 2, sz * size.Z / 2)))
				end
			end
		end
	end
	return points
end

-- How far past its claim a piece reaches: a rectangle (width x depth round `frame`) or a circle.
-- Two numbers, because they mean different things. Anything within HEAD_ROOM of the ground is IN the
-- way -- it has to stay inside the claim, or it ends up in a pavement or through a neighbour. Higher
-- up, a palm frond, a roof eave or a spotlight beam may reach out over the boundary: that's an
-- overhang, reported but allowed.
local HEAD_ROOM = 5

local function overrun(model, frame, width, depth, radius)
	local worst, worstPart, overhang, overhangPart = 0, nil, 0, nil
	for _, part in ipairs(partsOf(model)) do
		local low = math.huge
		local points = reachPoints(part)
		for _, point in ipairs(points) do
			low = math.min(low, frame:PointToObjectSpace(point).Y)
		end
		-- A part counts as on the ground if any of it is below head height.
		local onGround = low < HEAD_ROOM
		for _, point in ipairs(points) do
			local p = frame:PointToObjectSpace(point)
			local past
			if radius then
				past = math.sqrt(p.X * p.X + p.Z * p.Z) - radius
			else
				past = math.max(math.abs(p.X) - width / 2, math.abs(p.Z) - depth / 2)
			end
			if onGround then
				if past > worst then
					worst, worstPart = past, part
				end
			elseif past > overhang then
				overhang, overhangPart = past, part
			end
		end
	end
	return worst, worstPart, overhang, overhangPart
end

-- Parts that move on clients but not on the server, and still collide or stop bullets there.
local MOVERS = { "AmbientSpin", "AmbientSway", "AmbientBob" }
local function movingSolids(root)
	local found, moving = {}, 0
	local seen = {}
	for _, tag in ipairs(MOVERS) do
		for _, tagged in ipairs(CollectionService:GetTagged(tag)) do
			if tagged:IsDescendantOf(root) and not seen[tagged] then
				seen[tagged] = true
				local group = { tagged }
				if tag ~= "AmbientBob" then
					for _, d in ipairs(tagged:GetDescendants()) do
						table.insert(group, d)
					end
				end
				for _, part in ipairs(group) do
					if part:IsA("BasePart") then
						moving += 1
						if part.CanCollide or part.CanQuery then
							table.insert(found, part)
						end
					end
				end
			end
		end
	end
	return found, moving
end

--------------------------------------------------------------------------------
-- 2. Every theme on its own plate, no z-fight pass
--------------------------------------------------------------------------------

local samples = Instance.new("Folder")
samples.Name = "ThemeSamples"
samples.Parent = workspace
local okAll, entries = pcall(TownThemes.BuildAll, samples, Vector3.new(6000, 800, 6000), 100)
if not okAll then
	out("BuildAll FAILED: %s", tostring(entries))
	entries = {}
end

-- Planted faults first, so the counts below mean something.
do
	local plant = Instance.new("Model")
	plant.Name = "PlantedFlush"
	plant.Parent = samples
	for index, size in ipairs({ Vector3.new(4, 1, 4), Vector3.new(3, 1, 3) }) do
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.CFrame = CFrame.new(5000 + index * 0.5, 800, 5000)
		part.Parent = plant
	end
	selfTest("flush", #ZFight.Scan({ plant }) > 0)
	plant:Destroy()
	if entries[1] then
		local pieceModel = entries[1].model:FindFirstChild(TownThemes.Themes[entries[1].name].setPiece.id)
		local stray = Instance.new("Part")
		stray.Anchored = true
		stray.Size = Vector3.new(1, 1, 1)
		stray.CFrame = CFrame.new(entries[1].base + Vector3.new(entries[1].width / 2 + 40, 1, 0))
		stray.Parent = pieceModel
		local past, worst = overrun(pieceModel, CFrame.new(entries[1].base), entries[1].width, entries[1].depth)
		selfTest("footprint", worst == stray, string.format("%.1f past", past))
		stray:Destroy()
		local bobber = Instance.new("Part")
		bobber.Anchored = true
		bobber.Parent = pieceModel
		CollectionService:AddTag(bobber, "AmbientBob")
		local found = movingSolids(samples)
		selfTest("movingSolid", table.find(found, bobber) ~= nil)
		bobber:Destroy()
	end
end

local flushTotal, overrunCount, overhangCount, movingChecked, movingBad, piecesChecked = 0, 0, 0, 0, {}, 0
for _, entry in ipairs(entries) do
	local theme = TownThemes.Themes[entry.name]
	local parts = partsOf(entry.model)
	local pairsFound = ZFight.Scan({ entry.model })
	flushTotal += #pairsFound
	local lines = ZFight.Describe(pairsFound, function(part)
		local node = part
		while node.Parent and node.Parent ~= entry.model do
			node = node.Parent
		end
		return node.Name
	end, 8)
	-- Footprints: the set piece, then each prop.
	local reach = {}
	local pieceModel = entry.model:FindFirstChild(theme.setPiece.id)
	if pieceModel then
		piecesChecked += 1
		local past, part, over, overPart = overrun(pieceModel, CFrame.new(entry.base), entry.width, entry.depth)
		if past > 0.3 then
			overrunCount += 1
			table.insert(reach, string.format("%s ON THE GROUND %.1f past (%s)", theme.setPiece.id, past, part and part.Name or "?"))
		end
		if over > 0.3 then
			overhangCount += 1
			table.insert(reach, string.format("%s overhang %.1f (%s)", theme.setPiece.id, over, overPart and overPart.Name or "?"))
		end
	end
	for _, prop in ipairs(entry.props) do
		local propModel
		for _, child in ipairs(entry.model:GetChildren()) do
			if child.Name == prop.id and child:IsA("Model") then
				propModel = child
			end
		end
		if propModel then
			piecesChecked += 1
			local past, part, over, overPart = overrun(propModel, CFrame.new(prop.at), nil, nil, prop.radius)
			if past > 0.3 then
				overrunCount += 1
				table.insert(reach, string.format("%s ON THE GROUND %.1f past r%.1f (%s)", prop.id, past, prop.radius, part and part.Name or "?"))
			end
			if over > 0.3 then
				overhangCount += 1
				table.insert(reach, string.format("%s overhang %.1f r%.1f (%s)", prop.id, over, prop.radius, overPart and overPart.Name or "?"))
			end
		end
	end
	out("sample %s: parts=%d flush=%d%s%s", entry.name, #parts, #pairsFound, #lines > 0 and (" :: " .. table.concat(lines, " ; ")) or "",
		#reach > 0 and (" || OVERRUN " .. table.concat(reach, " ; ")) or "")
	task.wait()
end
local moving, movingCount = movingSolids(samples)
movingChecked = movingCount
for _, part in ipairs(moving) do
	table.insert(movingBad, (part:GetFullName():gsub("^Workspace%.ThemeSamples%.", "")))
end
out("samples: %d themes, flush pairs %d (no fix pass ran); footprints checked %d, over the edge on the ground %d, overhanging above %d studs %d; animated parts %d, still solid or hittable %d%s",
	#entries, flushTotal, piecesChecked, overrunCount, HEAD_ROOM, overhangCount, movingChecked, #movingBad,
	#movingBad > 0 and (" :: " .. table.concat(movingBad, " ; ", 1, math.min(10, #movingBad))) or "")
samples:Destroy()

--------------------------------------------------------------------------------
-- 3. Speedrun Springs' springs: the rules, the touch wiring, and where the last throw lands
--------------------------------------------------------------------------------

do
	local MovementService = require(modules:WaitForChild("MovementService"))
	local folder = Instance.new("Folder")
	folder.Name = "SpringTest"
	folder.Parent = workspace
	local realLaunch, realCan = MovementService.Launch, TownThemes.CanLaunch
	local okSpring, springErr = pcall(function()
		local springEntries = TownThemes.BuildAll(folder, Vector3.new(9000, 800, 9000), 100, { "Speedrun Springs" })
		local model = springEntries[1].model
		local triggers, steps, pads, deck = {}, 0, 0, nil
		for _, d in ipairs(model:GetDescendants()) do
			if d.Name == "SpringTrigger" then
				table.insert(triggers, d)
			elseif d.Name == "SpringStep" and d.CanCollide and d.Transparency >= 0.98 then
				steps += 1
			elseif d.Name == "SpringPad" and not d.CanCollide then
				pads += 1
			elseif d.Name == "LedgeDeck" then
				deck = d
			end
		end
		table.sort(triggers, function(a, b)
			return a.Position.Z < b.Position.Z
		end)
		out("springs: %d triggers, %d solid still steps, %d bobbing pads that don't collide, deck %s, launch enabled %s",
			#triggers, steps, pads, deck and "found" or "MISSING", tostring(TownThemes.EnableSpringLaunch))

		-- A stand-in character: a Humanoid, a foot and a hat, and a recorder in place of the real Launch.
		local fake = Instance.new("Model")
		fake.Name = "SpringDummy"
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Parent = fake
		local foot = Instance.new("Part")
		foot.Name = "LeftFoot"
		foot.Anchored = true
		foot.Parent = fake
		local hat = Instance.new("Accessory")
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Anchored = true
		handle.Parent = hat
		hat.Parent = fake
		Instance.new("Humanoid").Parent = fake
		fake.Parent = folder
		local notCharacter = Instance.new("Model")
		local crate = Instance.new("Part")
		crate.Anchored = true
		crate.Parent = notCharacter
		notCharacter.Parent = folder

		local launched = {}
		MovementService.Launch = function(character, velocity, kind)
			table.insert(launched, { character = character, velocity = velocity, kind = kind })
		end
		local trigger = triggers[#triggers]
		local botResult = TownThemes.SpringLaunch(trigger, fake, 100)
		TownThemes.CanLaunch = function()
			return true
		end
		local first = TownThemes.SpringLaunch(trigger, fake, 200)
		local tooSoon = TownThemes.SpringLaunch(trigger, fake, 200 + TownThemes.SpringCooldown * 0.5)
		local later = TownThemes.SpringLaunch(trigger, fake, 200 + TownThemes.SpringCooldown + 0.1)
		TownThemes.EnableSpringLaunch = false
		local switchedOff = TownThemes.SpringLaunch(trigger, fake, 300)
		TownThemes.EnableSpringLaunch = true
		local byFoot = TownThemes.SpringTouched(trigger, foot, 400)
		local byHat = TownThemes.SpringTouched(trigger, handle, 410)
		local byCrate = TownThemes.SpringTouched(trigger, crate, 420)
		local otherSpring = TownThemes.SpringLaunch(triggers[1], fake, 410.5)
		fake.Humanoid.Health = 0
		local dead = TownThemes.SpringLaunch(trigger, fake, 500)
		local kinds = {}
		for _, call in ipairs(launched) do
			kinds[tostring(call.kind)] = true
		end
		local kindList = {}
		for kind in pairs(kinds) do
			table.insert(kindList, kind)
		end
		out("spring rules: bot=%s first=%s cooldown=%s after=%s off=%s foot=%s hat=%s crate=%s otherSpringDuringCooldown=%s dead=%s calls=%d kinds=%s (want nil, vec, nil, vec, nil, vec, vec, nil, vec, nil, 5, pad)",
			tostring(botResult), tostring(first), tostring(tooSoon), tostring(later), tostring(switchedOff), tostring(byFoot), tostring(byHat), tostring(byCrate),
			tostring(otherSpring), tostring(dead), #launched, table.concat(kindList, ","))

		-- The throw from the last spring, stepped under gravity from a root standing on the step.
		if first and deck then
			local g = workspace.Gravity
			local start = trigger.Position + Vector3.new(0, -trigger.Size.Y / 2 + 3, 0)
			local deckTop = deck.Position.Y + deck.Size.Y / 2
			local landed, hitUnderside, apex = nil, false, start.Y
			local t = 0
			while t < 3 do
				t += 0.005
				local p = start + first * t + Vector3.new(0, -0.5 * g * t * t, 0)
				apex = math.max(apex, p.Y)
				local localP = deck.CFrame:PointToObjectSpace(Vector3.new(p.X, deck.Position.Y, p.Z))
				local over = math.abs(localP.X) < deck.Size.X / 2 + 1 and math.abs(localP.Z) < deck.Size.Z / 2 + 1
				local velocityY = first.Y - g * t
				if over and velocityY > 0 and p.Y - 3 < deckTop and p.Y + 2 > deck.Position.Y - deck.Size.Y / 2 then
					hitUnderside = true
				end
				if velocityY < 0 and p.Y - 3 <= deckTop then
					local inside = math.abs(localP.X) < deck.Size.X / 2 - 0.5 and math.abs(localP.Z) < deck.Size.Z / 2 - 0.5
					landed = { t = t, inside = inside, localP = localP }
					break
				end
			end
			out("spring throw (standing still, so along the spring): apex +%.1f, deck top %.1f above the trigger's foot; lands on deck=%s at t=%.2f local (%.1f, %.1f); clips underside=%s",
				apex - start.Y, deckTop - (trigger.Position.Y - trigger.Size.Y / 2), tostring(landed and landed.inside), landed and landed.t or -1,
				landed and landed.localP.X or 0, landed and landed.localP.Z or 0, tostring(hitUnderside))
		end
	end)
	MovementService.Launch, TownThemes.CanLaunch = realLaunch, realCan
	TownThemes.EnableSpringLaunch = true
	if not okSpring then
		out("spring test FAILED: %s", tostring(springErr))
	end
	folder:Destroy()
end

--------------------------------------------------------------------------------
-- 4. The whole map
--------------------------------------------------------------------------------

local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local MapTerrain = require(modules:WaitForChild("MapTerrain"))
local realPad = MapTerrain.FlattenPad

-- A stand-in for claude-79's pad API until it lands: cut and fill the rectangle flat at the given
-- height, painted. Same contract: the floor height, or nil and a reason.
local function standInPad(cframe, size, options)
	local margin = options and options.margin or 0
	local material = options and options.material or Enum.Material.Ground
	local top = cframe.Position.Y - MapTerrain.SurfaceLift
	local extent = Vector3.new(size.X + margin * 2, 40, size.Z + margin * 2)
	workspace.Terrain:FillBlock(CFrame.new(cframe.Position.X, top + 20, cframe.Position.Z) * cframe.Rotation, extent, Enum.Material.Air)
	workspace.Terrain:FillBlock(CFrame.new(cframe.Position.X, top - 5, cframe.Position.Z) * cframe.Rotation, Vector3.new(extent.X, 10, extent.Z), material)
	return cframe.Position.Y
end

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }
terrainParams.IgnoreWater = true

local function groundUnder(position)
	local hit = workspace:Raycast(Vector3.new(position.X, position.Y + 300, position.Z), Vector3.new(0, -700, 0), terrainParams)
	return hit and hit.Position.Y
end

local function buildMap(mode)
	MapGenerator.Clear()
	task.wait(1)
	if mode == "pads" then
		MapTerrain.FlattenPad = realPad or standInPad
	else
		MapTerrain.FlattenPad = nil
	end
	math.randomseed(SEED)
	-- Wall clock (os.clock() is CPU time in Roblox; a map build is mostly yielding and would under-read).
	local t0 = DateTime.now().UnixTimestampMillis
	local okBuild, info = pcall(MapGenerator.Build, MAP_ID)
	local wall = (DateTime.now().UnixTimestampMillis - t0) / 1000
	MapTerrain.FlattenPad = realPad
	local map = workspace:FindFirstChild("Map")
	out("[%s] map %s seed %d: ok=%s in %.2fs WALL; pad API %s; ThemeParts=%s ThemeSeconds=%s (wall, from the hook)", mode, MAP_ID, SEED, tostring(okBuild), wall,
		mode == "pads" and (realPad and "real" or "stand-in") or "none", tostring(map and map:GetAttribute("ThemeParts")), tostring(map and map:GetAttribute("ThemeSeconds")))
	if not okBuild then
		out("[%s] BUILD FAILED: %s", mode, tostring(info))
		return nil
	end
	return map
end

local function townLines(mode, map)
	local themeRoots, placed, towns = {}, 0, 0
	-- Per-town cost against the 15 s per-map budget: theme parts and wall-clock ms (ThemeMillis is
	-- written by TownThemes.themeTown from DateTime, never os.clock), plus the whole town's parts so
	-- the theme's share is visible.
	local themeParts, themeMillis, townParts, slowest, slowestMillis = 0, 0, 0, "-", -1
	for _, town in ipairs(map:GetChildren()) do
		local name = town:GetAttribute("TownName")
		if name then
			towns += 1
			local theme = town:FindFirstChild("Theme")
			local streets = 0
			for _, child in ipairs(town:GetChildren()) do
				if child:IsA("BasePart") and child.Name == "Asphalt" and child.Size.Z >= 30 then
					streets += 1
				end
			end
			local wholeTown = #partsOf(town)
			townParts += wholeTown
			if not theme then
				out("[%s] town %s: NO THEME (streets=%d, town parts=%d)", mode, name, streets, wholeTown)
			else
				table.insert(themeRoots, theme)
				local millis = theme:GetAttribute("ThemeMillis") or -1
				local tp = theme:GetAttribute("ThemeParts") or 0
				themeParts += tp
				themeMillis += math.max(0, millis)
				if millis > slowestMillis then
					slowest, slowestMillis = name, millis
				end
				out("[%s] cost %s: theme parts=%d ms=%d (town parts=%d, theme share %.0f%%)", mode, name, tp, millis, wholeTown,
					wholeTown > 0 and tp / wholeTown * 100 or 0)
				local setPiece, flags, props = nil, 0, 0
				for _, child in ipairs(theme:GetChildren()) do
					if child.Name == "Flags" then
						flags = #child:GetChildren()
					elseif child.Name == "Props" then
						props = #child:GetChildren()
					elseif child:GetAttribute("SetPiece") then
						setPiece = child
					end
				end
				if setPiece then
					placed += 1
				end
				local pivot = setPiece and setPiece:GetPivot().Position
				local center = town:GetAttribute("TownCenter")
				out("[%s] town %s: setPiece=%s onStreet=%s padded=%s dist=%.0f flags=%d props=%d parts=%s streets=%d | sites tried=%s blocked=%s sloped=%s flattest=%s pads asked=%s refused=%s last=%s",
					mode, name, setPiece and setPiece.Name or "NONE", tostring(setPiece and setPiece:GetAttribute("OnStreet")), tostring(setPiece and setPiece:GetAttribute("Padded")),
					(pivot and center) and (Vector3.new(pivot.X, 0, pivot.Z) - Vector3.new(center.X, 0, center.Z)).Magnitude or -1,
					flags, props, tostring(theme:GetAttribute("ThemeParts")), streets, tostring(theme:GetAttribute("SiteCandidates")),
					tostring(theme:GetAttribute("SiteBlocked")), tostring(theme:GetAttribute("SiteSloped")), tostring(theme:GetAttribute("SiteFlattest")),
					tostring(theme:GetAttribute("SitePadsAsked")), tostring(theme:GetAttribute("SitePadsRefused")), tostring(theme:GetAttribute("SiteLastRefusal")))
			end
		end
	end
	out("[%s] towns=%d themed=%d set pieces placed=%d", mode, towns, #themeRoots, placed)
	out("[%s] COST %s: themes %d parts, %d ms wall over %d towns (slowest %s %d ms); all towns %d parts; themes are %.1f%% of town parts",
		mode, MAP_ID, themeParts, themeMillis, #themeRoots, slowest, slowestMillis, townParts, townParts > 0 and themeParts / townParts * 100 or 0)
	return themeRoots
end

do
	local noPadMap = buildMap("nopads")
	if noPadMap then
		townLines("nopads", noPadMap)
	end
end

local map = buildMap("pads")
if not map then
	return
end
local themeRoots = townLines("pads", map)
out("map parts total=%d", #partsOf(map))

-- Which piece a part belongs to: for theme parts, Theme/<Piece> (a set piece, Flags, or a prop inside
-- Props); for anything else, the Model directly under a town or the map, or the town itself.
local function ownerOf(part)
	local node = part
	local chain = {}
	while node and node ~= map do
		table.insert(chain, 1, node)
		node = node.Parent
	end
	local top = chain[1]
	if top and top.Name == "Town" and chain[2] and chain[2].Name == "Theme" then
		local piece = chain[3]
		if piece and (piece.Name == "Props" or piece.Name == "Flags") and chain[4] then
			return "Theme/" .. piece.Name .. "/" .. chain[4].Name .. "#" .. tostring(chain[4]:GetDebugId()), chain[4], true
		end
		return "Theme/" .. (piece and piece.Name or "?"), piece, true
	end
	if top and top.Name == "Town" and chain[2] and chain[2]:IsA("Model") then
		return "Town/" .. chain[2].Name, chain[2], false
	end
	return top and top.Name or "?", top, false
end

local function shortOwner(key)
	return (key:gsub("#%d+$", ""))
end

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include
overlapParams.FilterDescendantsInstances = { map }

-- Solid parts of `part` overlapping solid parts of a different piece, by exact shape shrunk a little.
local function clipsOf(part)
	local class = part.ClassName
	local probe = Instance.new((class == "WedgePart" or class == "CornerWedgePart") and class or "Part")
	if part:IsA("Part") and probe:IsA("Part") then
		probe.Shape = part.Shape
	end
	probe.Size = Vector3.new(math.max(0.05, part.Size.X - 0.7), math.max(0.05, part.Size.Y - 0.7), math.max(0.05, part.Size.Z - 0.7))
	probe.CFrame = part.CFrame
	probe.Transparency = 1
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.Parent = workspace
	local mine = ownerOf(part)
	local hits = {}
	for _, other in ipairs(workspace:GetPartsInPart(probe, overlapParams)) do
		if other.CanCollide and other ~= part and ownerOf(other) ~= mine then
			table.insert(hits, other)
		end
	end
	probe:Destroy()
	return hits, mine
end

local function isBuried(part)
	local ground = groundUnder(part.Position)
	return ground ~= nil and ground > part.Position.Y + part.Size.Y / 2 + 1.5, ground
end

-- How far a piece's lowest visible, non-floating part stands above the ground under it.
local function hoverOf(piece)
	local best = math.huge
	for _, d in ipairs(partsOf(piece)) do
		if not d:GetAttribute("IntentionalFloat") and d.Transparency < 0.98 then
			local cf, size = d.CFrame, d.Size
			local halfY = math.abs(cf.RightVector.Y) * size.X / 2 + math.abs(cf.UpVector.Y) * size.Y / 2 + math.abs(cf.LookVector.Y) * size.Z / 2
			local ground = groundUnder(d.Position)
			if ground then
				best = math.min(best, (d.Position.Y - halfY) - ground)
			end
		end
	end
	return best
end

-- Planted faults, in the first themed town: a solid block inside a building (or anything solid that
-- isn't theme), a block six studs under the ground, and a piece hanging three studs up.
if themeRoots[1] then
	local root = themeRoots[1]
	local plant = Instance.new("Model")
	plant.Name = "PlantedPiece"
	plant.Parent = root
	local target
	for _, d in ipairs(root.Parent:GetDescendants()) do
		if d:IsA("BasePart") and d.CanCollide and d.Size.X > 3 and d.Size.Y > 3 and d.Size.Z > 3 and not d:IsDescendantOf(root) then
			target = d
			break
		end
	end
	if target then
		local block = Instance.new("Part")
		block.Anchored = true
		block.Size = Vector3.new(2, 2, 2)
		block.CFrame = target.CFrame
		block.Parent = plant
		selfTest("clipping", #clipsOf(block) > 0, target.Name)
		block:Destroy()
	else
		selfTest("clipping", false, "no solid target found")
	end
	local center = root.Parent:GetAttribute("TownCenter")
	local ground = center and groundUnder(Vector3.new(center.X, 50, center.Z))
	if ground then
		local sunk = Instance.new("Part")
		sunk.Anchored = true
		sunk.Size = Vector3.new(2, 2, 2)
		sunk.CFrame = CFrame.new(center.X + 3, ground - 6, center.Z + 3)
		sunk.Parent = plant
		selfTest("buried", (isBuried(sunk)))
		sunk:Destroy()
		local high = Instance.new("Part")
		high.Anchored = true
		high.Size = Vector3.new(2, 2, 2)
		high.CFrame = CFrame.new(center.X + 3, ground + 4, center.Z + 3)
		high.Parent = plant
		local hover = hoverOf(plant)
		selfTest("hovering", hover > 0.25 and hover < math.huge, string.format("+%.1f", hover))
	end
	plant:Destroy()
end

-- Clipping and burial, theme parts only.
local clips, clipExamples, buried, buriedExamples, checked = {}, {}, 0, {}, 0
for _, theme in ipairs(themeRoots) do
	for _, d in ipairs(partsOf(theme)) do
		if d.CanCollide and d.Size.Magnitude > 1 then
			checked += 1
			local hits, mine = clipsOf(d)
			for _, other in ipairs(hits) do
				local key = shortOwner(mine) .. " x " .. shortOwner((ownerOf(other)))
				clips[key] = (clips[key] or 0) + 1
				clipExamples[key] = clipExamples[key] or string.format("%s vs %s at %s", d.Name, other.Name, v3(d.Position))
			end
			local isUnder, ground = isBuried(d)
			if isUnder then
				buried += 1
				table.insert(buriedExamples, string.format("%s %s top %.1f ground %.1f", shortOwner(mine), d.Name, d.Position.Y + d.Size.Y / 2, ground))
			end
			if checked % 150 == 0 then
				task.wait()
			end
		end
	end
end
local clipLines = {}
for key, n in pairs(clips) do
	table.insert(clipLines, string.format("%s x%d (%s)", key, n, clipExamples[key]))
end
table.sort(clipLines)
out("clipping: %d solid theme parts checked; overlaps: %s", checked, #clipLines > 0 and table.concat(clipLines, " | ") or "none")
out("buried: %d of %d%s", buried, checked, buried > 0 and (" :: " .. table.concat(buriedExamples, " ; ", 1, math.min(8, #buriedExamples))) or "")

-- Pieces standing clear of the ground.
local hovering, piecesSeen = {}, 0
for _, theme in ipairs(themeRoots) do
	local pieces = {}
	for _, child in ipairs(theme:GetChildren()) do
		if child.Name == "Props" or child.Name == "Flags" then
			for _, sub in ipairs(child:GetChildren()) do
				table.insert(pieces, sub)
			end
		else
			table.insert(pieces, child)
		end
	end
	for _, piece in ipairs(pieces) do
		piecesSeen += 1
		local best = hoverOf(piece)
		if best > 0.25 and best < math.huge then
			table.insert(hovering, string.format("%s/%s +%.2f", theme.Parent:GetAttribute("TownName"), piece.Name, best))
		end
	end
end
out("hovering pieces: %d of %d%s", #hovering, piecesSeen, #hovering > 0 and (" :: " .. table.concat(hovering, " ; ")) or "")

-- What the map's z-fight pass had to move or resize in themes (its ZFixed marks). The target is 0:
-- anything it moved was flush as built. (A scan for flush pairs after the pass can't fail, so none.)
local themePartCount = 0
for _, theme in ipairs(themeRoots) do
	themePartCount += #partsOf(theme)
end
local touched, movedLines = ZFight.Report(themeRoots, function(part)
	return shortOwner((ownerOf(part)))
end, 20)
out("zfight pass moved in themes: %s of %d parts%s", tostring(touched), themePartCount,
	(type(movedLines) == "table" and #movedLines > 0) and (" :: " .. table.concat(movedLines, " ; ")) or "")

-- Animated parts on the real map, the same check as the samples.
local mapMoving, mapMovingCount = movingSolids(map)
out("animated theme parts on the map: %d, still solid or hittable %d", mapMovingCount, #mapMoving)

-- Paths, with BotService's own agent: from the street in front of each set piece to both its sides
-- (round it), and on Rizz Ridge up the stairs onto the terrace.
local PathfindingService = game:GetService("PathfindingService")
local function pathStatus(from, to)
	local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = true })
	local ok = pcall(function()
		path:ComputeAsync(from, to)
	end)
	return ok and path.Status.Name or "Error", ok and #path:GetWaypoints() or 0
end
local pathLines = {}
for _, theme in ipairs(themeRoots) do
	for _, piece in ipairs(theme:GetChildren()) do
		local site, size = piece:GetAttribute("Site"), piece:GetAttribute("SiteSize")
		if site and size then
			local town = theme.Parent:GetAttribute("TownName")
			local front = (site * CFrame.new(0, 3, -size.Z / 2 - 5)).Position
			local left = (site * CFrame.new(-size.X / 2 - 5, 3, 0)).Position
			local right = (site * CFrame.new(size.X / 2 + 5, 3, 0)).Position
			local line = string.format("%s front->left %s front->right %s", town, pathStatus(front, left), pathStatus(front, right))
			if piece.Name == "TheRidge" then
				local top = (site * CFrame.new(0, 9, 9.5)).Position
				local status, waypoints = pathStatus(front, top)
				line ..= string.format(" front->terrace top %s (%d waypoints)", status, waypoints)
			end
			table.insert(pathLines, line)
			task.wait()
		end
	end
end
out("paths (%d set pieces): %s", #pathLines, #pathLines > 0 and table.concat(pathLines, " | ") or "none to test")

local springs = 0
for _, theme in ipairs(themeRoots) do
	for _, d in ipairs(theme:GetDescendants()) do
		if d.Name == "SpringTrigger" then
			springs += 1
		end
	end
end
out("spring triggers on the map: %d (launch enabled: %s)", springs, tostring(TownThemes.EnableSpringLaunch))
out("SELFTEST %s", table.concat(selfTests, " "))
MapGenerator.Clear()
out("probe finished")
