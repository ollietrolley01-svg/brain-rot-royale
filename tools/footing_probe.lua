-- Footing probe: does everything built on the map stand on the ground, or hang off a ledge?
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/footing_probe.lua -WaitSeconds 400
-- One map per run (edit MAP_ID and SEED below): a map is several thousand parts and Studio dies
-- around 3.6 GB.
--
-- Oliver's rule (2026-09-17): "buildings and structures are built with a flat floor under them so
-- they don't look like they're floating on ledges, and the same for the roads." This measures it,
-- for the map tabs to fix against and to verify with:
--
--   STRUCTURES  every model that stands on the map (town buildings, landmarks, wilds shelters, sheds
--               and props of any size): points round the edge of its footprint at its base height
--               (corners and every EDGE_STEP studs along each side, a hair outside the walls), each
--               traced straight down for the nearest solid thing that isn't the structure itself. The
--               gap is how far the base hangs above it. A structure FLOATS if any edge point hangs
--               more than FLOAT studs (a corner over a slope, a wall on a ledge), and is BURIED if the
--               ground rises more than BURY studs above its base anywhere round the edge (the terrain
--               swallowing a wall). Both are reported by owner (Town, Landmarks, Wilds, ...) with the
--               worst cases and their positions.
--   ROADS       every road, junction and street surface part (not bridge decks: those are meant to
--               span): columns along both long edges, the same trace down from the surface, the same
--               FLOAT/BURY rule against the road's underside. Bridge decks are counted separately.
--   BOULDERS    every loose rock part (Rock, Boulder, SteppingStone, OasisBoulder; MIN_ROCK studs or
--               more) in ANY container, River and Decor included, measured on its own underside with
--               WATER counted as a surface: floating (the whole underside > FLOAT up), perched (a
--               corner > PERCH up while the rest touches), lifted (HAIR..FLOAT, "floating a bit").
--               Structures and roads get the same lifted count, so a slab a hair off the ground is a
--               number rather than a shrug. Rocks are parts, not Models with a floor, so the structure
--               walk never sees them; Oliver saw them first (2026-09-17: "some of the random gen
--               buildings and boulders are floating a bit").
--
-- Attributes a structure's owner can set on its Model (project convention, approved 2026-09-17):
--   FootingSkip = true      not a structure: a scatter group (Woods_N, Clutter_N, Hedgerow_N ...)
--                           whose bounding box spans a whole stand. Skipped, and counted, so a skip
--                           can't hide a real building.
--   FootingBase (number)    the world Y of the floor/base, and
--   FootingSize (Vector3)   the footprint (X and Z; Y unused) measured round the model's pivot, which
--                           sits at the footprint's centre. With both set, these are used instead of
--                           the bounding box: deliberately sunk posts, piers and legs stop reading
--                           as buried, while the floor edge is still checked for floating.
--   FootingGroup = true     a container (a town's Theme model holding its set piece, flags and
--                           props): not measured itself; its child Models are, recursively, under an
--                           owner path such as "Town/Theme". FootingSkip on the container skips the
--                           whole subtree (counted); on a child, just that child. A container with no
--                           child Models is warned about.
-- Without them the bounding box is used; each owner's report says how many of each.
--
-- Lines start "[FOOTING]"; "[FOOTING] PROBLEM" lines are the ones to fix. Numbers, not opinions:
-- a corner 0.4 studs up is rounding, 3 studs up is a building on stilts.

local RS = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))

local MAP_ID, SEED = "SahurSprings", 101
local FLOAT = 1.0
local BURY = 1.5
local EDGE_STEP = 6
local EDGE_OUT = 0.3
local REACH = 40
local ROAD_STEP = 6
-- RoadNetwork names its slabs RoadSurface (BridgeRoad over water) and its pads Junction; Road and
-- Asphalt are the older street names, kept so a town street built by MapDecor is still measured.
local SURFACE = { Road = true, RoadSurface = true, Junction = true, Asphalt = true }
local BRIDGE = { BridgeDeck = true, BridgeRoad = true }
-- Groups whose children are structures (each child Model is one), and groups that aren't structures.
local GROUPS = { Town = true, Landmarks = true, Wilds = true, Props = true, Decor = true, Buildings = true }
local SKIP = { Roads = true, River = true, Vehicles = true, Ziplines = true, Terrain = true, Loot = true }
-- A model smaller than this on the ground is a prop that can sit on a slope without looking wrong.
local MIN_FOOTPRINT = 5
local MIN_HEIGHT = 3

local function out(fmt, ...)
	print("[FOOTING] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z)
end

math.randomseed(SEED)
local started = os.clock()
MapGenerator.Build(MAP_ID)
task.wait(1.5)
local map = workspace:FindFirstChild("Map")
if not map then
	out("PROBLEM no workspace.Map after MapGenerator.Build(%s)", MAP_ID)
	return
end
out("%s seed %d built in %.1fs", MAP_ID, SEED, os.clock() - started)

--------------------------------------------------------------------------------
-- Structures
--------------------------------------------------------------------------------

-- The models that stand on the map, each with the path of the group it sits in ("Town",
-- "Town/Theme/Props"). A Model with `FootingGroup = true` is a container: it isn't measured itself,
-- its child Models are, recursively. A container with FootingSkip is skipped whole (the main loop
-- counts it); one with no child Models is warned about, so a mis-tagged real structure can't vanish.
local structures = {}
local groupCount, emptyGroups = 0, 0
local function collect(container, owner)
	local children = 0
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Model") then
			children += 1
			if child:GetAttribute("FootingGroup") == true and child:GetAttribute("FootingSkip") ~= true then
				groupCount += 1
				local inside = collect(child, owner .. "/" .. child.Name)
				if inside == 0 then
					emptyGroups += 1
					out("WARNING FootingGroup %s/%s at %s has no child Models: a mis-tagged structure? (not measured)", owner, child.Name, v3(child:GetPivot().Position))
				end
			else
				table.insert(structures, { model = child, owner = owner })
			end
		end
	end
	return children
end
for _, child in ipairs(map:GetChildren()) do
	if SKIP[child.Name] then
		continue
	end
	if GROUPS[child.Name] or child:IsA("Folder") or (child:IsA("Model") and child:GetAttribute("FootingGroup") == true) then
		if child:GetAttribute("FootingSkip") == true then
			table.insert(structures, { model = child, owner = "Map" })
		else
			if child:IsA("Model") and child:GetAttribute("FootingGroup") == true then
				groupCount += 1
			end
			collect(child, child.Name)
		end
	elseif child:IsA("Model") then
		table.insert(structures, { model = child, owner = "Map" })
	end
end

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true
-- Never counted as ground: pickups, effects and the other things that hover.
local baseExclude = {}
for _, name in ipairs({ "Loot", "Effects", "Deployables", "Defenses", "Companions" }) do
	local instance = workspace:FindFirstChild(name)
	if instance then
		table.insert(baseExclude, instance)
	end
end
local vehicles = map:FindFirstChild("Vehicles")
if vehicles then
	table.insert(baseExclude, vehicles)
end

-- Terrain height isn't exact everywhere (measured by claude-79, 2026-09-17, 11 materials):
--   SMOOTH  (+-0.006)  Asphalt, Glacier, Grass, Ground, LeafyGrass, Limestone, Mud, Salt, Sand,
--                      Sandstone, Snow
--   ROUGH              Rock -1.08..+1.16, Basalt -0.79..+0.72, Ice -0.58..+0.51, Slate +-0.39,
--                      CrackedLava +-0.37
--   STEPPED            Pavement (whole studs), Concrete (2 studs), Brick and WoodPlanks (drop to the
--                      4-stud voxel boundary, up to -1.75), Cobblestone (finer, -0.29..+0.05)
-- and rough or stepped materials disturb smooth ground 2-4 studs beside them. So every sample
-- records the material it landed on, PROBLEM lines name it, and the summary counts how many
-- problems sit on rough or stepped ground, which may be that noise rather than a real overhang.
local ROUGH = {
	Rock = true, Basalt = true, Ice = true, Slate = true, CrackedLava = true,
	Pavement = true, Concrete = true, Brick = true, WoodPlanks = true, Cobblestone = true,
}

local function materialOf(result)
	if result.Instance:IsA("Terrain") then
		return result.Material.Name
	end
	return "part:" .. result.Instance.Name
end

-- The ground under `point`, ignoring `exclude`: one cast straight down from well above the base
-- (LOOK_ABOVE studs), taking the first solid thing that isn't the structure. The gap is how far the
-- base sits above it (positive = hanging in the air, negative = the ground is above the base, i.e.
-- buried), or REACH when nothing is under it at all; and what it landed on.
--
-- Cast from above on purpose: a ray that starts inside a terrain voxel never reports that terrain
-- (measured by claude-f5, 2026-09-17), so a base sunk half a stud into the pavement read as "40
-- studs over nothing". Starting LOOK_ABOVE up means the first hit is the surface, whichever side of
-- the base it is on; anything more than LOOK_ABOVE above the base (a neighbour's eaves) is ignored.
--
-- A prop standing in the footprint (a yard crate, a barrel: a part no bigger than PROP_MAX on
-- every side, above the base) is not ground either: the ray steps past it and casts again, up to
-- PROP_STEPS times. Without this every town house read "buried 6.5 under part:YardCrate".
--
-- Nothing within reach from there means one of three things, told apart before anything is called
-- "over nothing": a base sunk deep (a landmark's bounding box reaching 8 studs down into its hill)
-- starts the ray inside a terrain voxel, which never reports that terrain, so a second look from
-- HIGH_LOOK up, taking terrain only (parts up there are roofs, not ground), finds the surface and
-- the point reads as buried; a base over the river reads "over Water" (the normal casts ignore water,
-- as they always have); only the void beyond the map is "nothing".
local LOOK_ABOVE = BURY + 6
-- High enough that a landmark whose bounding box reaches 60 studs down a ridge (TurbineRidge) still
-- starts the second look above the terrain.
local HIGH_LOOK = 250
local PROP_MAX = 12
local PROP_STEPS = 4
local function castGap(point, exclude, castParams)
	local filter = table.clone(baseExclude)
	table.insert(filter, exclude)
	local top = point + Vector3.new(0, LOOK_ABOVE, 0)
	local down = Vector3.new(0, -(LOOK_ABOVE + REACH), 0)
	for _ = 1, PROP_STEPS + 1 do
		castParams.FilterDescendantsInstances = filter
		local hit = workspace:Raycast(top, down, castParams)
		if not hit then
			break
		end
		local instance = hit.Instance
		local size = instance:IsA("BasePart") and not instance:IsA("Terrain") and instance.Size or nil
		local prop = size and size.X <= PROP_MAX and size.Y <= PROP_MAX and size.Z <= PROP_MAX and hit.Position.Y > point.Y
		if not prop then
			return point.Y - hit.Position.Y, materialOf(hit)
		end
		table.insert(filter, instance)
	end
	local from = point + Vector3.new(0, HIGH_LOOK, 0)
	local far = Vector3.new(0, -(HIGH_LOOK + REACH), 0)
	for _ = 1, 8 do
		castParams.FilterDescendantsInstances = filter
		local hit = workspace:Raycast(from, far, castParams)
		if not hit then
			break
		end
		if hit.Instance:IsA("Terrain") then
			return point.Y - hit.Position.Y, materialOf(hit)
		end
		table.insert(filter, hit.Instance)
	end
	if castParams.IgnoreWater then
		castParams.IgnoreWater = false
		castParams.FilterDescendantsInstances = filter
		local wet = workspace:Raycast(from, far, castParams)
		castParams.IgnoreWater = true
		if wet and wet.Instance:IsA("Terrain") and wet.Material == Enum.Material.Water then
			return point.Y - wet.Position.Y, "Water"
		end
	end
	return REACH, "nothing"
end
local function groundGap(point, exclude)
	return castGap(point, exclude, params)
end

-- Decor built with CanQuery = false (MapDecor's clutter(): a fountain's bowl, a bench, a crate) is
-- invisible to rays, so a statue standing in the bowl read as 5.6 studs over the pavement. Before a
-- floating structure is counted, its container's non-queryable parts are searched by hand for one
-- whose world bounds sit under the hanging point, between the ground the ray found and the base.
-- Found: it's a NOTE, counted apart, not a PROBLEM.
local function worldBounds(part)
	local cframe, size = part.CFrame, part.Size / 2
	local r = cframe.Rotation
	local half = Vector3.new(
		math.abs(r.XVector.X) * size.X + math.abs(r.YVector.X) * size.Y + math.abs(r.ZVector.X) * size.Z,
		math.abs(r.XVector.Y) * size.X + math.abs(r.YVector.Y) * size.Y + math.abs(r.ZVector.Y) * size.Z,
		math.abs(r.XVector.Z) * size.X + math.abs(r.YVector.Z) * size.Y + math.abs(r.ZVector.Z) * size.Z
	)
	return cframe.Position - half, cframe.Position + half
end

local function unqueryableSupport(structure, point, gap)
	local container = structure.Parent
	if not container then
		return nil
	end
	local floorY = point.Y - gap
	for _, part in ipairs(container:GetDescendants()) do
		if part:IsA("BasePart") and not part.CanQuery and not part:IsDescendantOf(structure) then
			local low, high = worldBounds(part)
			if point.X >= low.X - 0.1 and point.X <= high.X + 0.1 and point.Z >= low.Z - 0.1 and point.Z <= high.Z + 0.1
				and high.Y >= floorY - 0.05 and high.Y <= point.Y + 0.6 then
				return part
			end
		end
	end
	return nil
end
local clutterSupported = 0

local roughProblems, exactProblems = 0, 0
local function countMaterial(material)
	local name = string.match(material, "^part:") and "part" or material
	if ROUGH[name] then
		roughProblems += 1
	else
		exactProblems += 1
	end
end

local byOwner = {}
local worstFloat, worstBury = {}, {}
local checked, floating, buried, skipped = 0, 0, 0, 0
local byAttributes, byBox = 0, 0
-- "Floating a bit": a worst edge point between HAIR and FLOAT up. Not a PROBLEM (terrain noise on
-- rough ground reaches this), but counted and listed, since a slab 0.6 off the grass is visible.
local HAIR = 0.4
local lifted, liftedList = 0, {}

local function record(owner, key)
	local entry = byOwner[owner]
	if not entry then
		entry = { checked = 0, floating = 0, buried = 0, skipped = 0, attributes = 0, box = 0, floatExample = nil, buryExample = nil }
		byOwner[owner] = entry
	end
	if key then
		entry[key] += 1
	end
	return entry
end

for _, item in ipairs(structures) do
	local model = item.model
	if model:GetAttribute("FootingSkip") == true then
		skipped += 1
		record(item.owner, "skipped")
		continue
	end
	-- The footprint and base: the owner's own numbers when it has given them, else the bounding box.
	local cframe, size, baseY, method
	local base, footprint = model:GetAttribute("FootingBase"), model:GetAttribute("FootingSize")
	if type(base) == "number" and typeof(footprint) == "Vector3" then
		local pivot = model:GetPivot()
		cframe = CFrame.new(pivot.Position.X, base, pivot.Position.Z) * pivot.Rotation
		size = Vector3.new(footprint.X, MIN_HEIGHT, footprint.Z)
		baseY = 0
		method = "attributes"
	else
		local ok, boxFrame, boxSize = pcall(function()
			return model:GetBoundingBox()
		end)
		if not ok then
			continue
		end
		cframe, size = boxFrame, boxSize
		baseY = -size.Y / 2
		method = "box"
	end
	if size.X < MIN_FOOTPRINT or size.Z < MIN_FOOTPRINT or size.Y < MIN_HEIGHT then
		continue
	end
	checked += 1
	local entry = record(item.owner, "checked")
	record(item.owner, method)
	if method == "attributes" then
		byAttributes += 1
	else
		byBox += 1
	end
	local halfX, halfZ = size.X / 2 + EDGE_OUT, size.Z / 2 + EDGE_OUT
	local points = {}
	local nx = math.max(1, math.ceil(size.X / EDGE_STEP))
	local nz = math.max(1, math.ceil(size.Z / EDGE_STEP))
	for i = 0, nx do
		local x = -halfX + (2 * halfX) * i / nx
		table.insert(points, cframe:PointToWorldSpace(Vector3.new(x, baseY, -halfZ)))
		table.insert(points, cframe:PointToWorldSpace(Vector3.new(x, baseY, halfZ)))
	end
	for j = 1, nz - 1 do
		local z = -halfZ + (2 * halfZ) * j / nz
		table.insert(points, cframe:PointToWorldSpace(Vector3.new(-halfX, baseY, z)))
		table.insert(points, cframe:PointToWorldSpace(Vector3.new(halfX, baseY, z)))
	end
	local maxGap, maxBury, gapAt, buryAt, gapOn, buryOn = 0, 0, nil, nil, "?", "?"
	local hanging = 0
	for _, point in ipairs(points) do
		local gap, material = groundGap(point, model)
		if gap > maxGap then
			maxGap, gapAt, gapOn = gap, point, material
		end
		if -gap > maxBury then
			maxBury, buryAt, buryOn = -gap, point, material
		end
		if gap > FLOAT then
			hanging += 1
		end
	end
	local label = string.format("%s/%s at %s (%.0f x %.0f footprint, by %s)", item.owner, model.Name, v3(cframe.Position), size.X, size.Z,
		method == "attributes" and "FootingBase/Size" or "bounding box")
	if maxGap > FLOAT then
		local support = unqueryableSupport(model, gapAt, maxGap)
		if support then
			clutterSupported += 1
			out("NOTE %s: hangs %.1f over %s at %s but rests on non-queryable %s (decor rays pass through); not counted", label, maxGap, gapOn, v3(gapAt), support.Name)
		else
			floating += 1
			record(item.owner, "floating")
			countMaterial(gapOn)
			table.insert(worstFloat, { gap = maxGap, text = string.format("%s: %d of %d edge points hang, worst %.1f studs at %s over %s", label, hanging, #points, maxGap, v3(gapAt), gapOn) })
			entry.floatExample = entry.floatExample or worstFloat[#worstFloat].text
		end
	elseif maxGap > HAIR then
		lifted += 1
		table.insert(liftedList, { gap = maxGap, text = string.format("%s: worst edge point %.1f over %s at %s", label, maxGap, gapOn, v3(gapAt)) })
	end
	if maxBury > BURY then
		buried += 1
		record(item.owner, "buried")
		countMaterial(buryOn)
		table.insert(worstBury, { gap = maxBury, text = string.format("%s: ground (%s) %.1f studs above the base at %s", label, buryOn, maxBury, v3(buryAt)) })
		entry.buryExample = entry.buryExample or worstBury[#worstBury].text
	end
end

table.sort(worstFloat, function(a, b)
	return a.gap > b.gap
end)
table.sort(worstBury, function(a, b)
	return a.gap > b.gap
end)

out("STRUCTURES %d checked (footprint >= %d, height >= %d): %d float (an edge point > %.1f studs above solid ground), %d buried (ground > %.1f above the base); %d by FootingBase/Size, %d by bounding box, %d skipped (FootingSkip)",
	checked, MIN_FOOTPRINT, MIN_HEIGHT, floating, FLOAT, buried, BURY, byAttributes, byBox, skipped)
local owners = {}
for owner in pairs(byOwner) do
	table.insert(owners, owner)
end
table.sort(owners)
for _, owner in ipairs(owners) do
	local entry = byOwner[owner]
	out("STRUCTURES %s: %d checked (%d by attributes, %d by bounding box), %d floating, %d buried, %d skipped", owner, entry.checked, entry.attributes, entry.box, entry.floating, entry.buried, entry.skipped)
end
for index = 1, math.min(15, #worstFloat) do
	out("PROBLEM floating: %s", worstFloat[index].text)
end
for index = 1, math.min(8, #worstBury) do
	out("PROBLEM buried: %s", worstBury[index].text)
end
table.sort(liftedList, function(a, b)
	return a.gap > b.gap
end)
out("STRUCTURES lifted a little: %d with a worst edge point between %.1f and %.1f up (visible, not counted as floating)", lifted, HAIR, FLOAT)
for index = 1, math.min(8, #liftedList) do
	out("NOTE lifted: %s", liftedList[index].text)
end

--------------------------------------------------------------------------------
-- Roads
--------------------------------------------------------------------------------

local roads = map:FindFirstChild("Roads")
local surfaces, decks = {}, 0
local restore = {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") then
		if SURFACE[d.Name] then
			table.insert(surfaces, d)
			restore[d] = d.CanQuery
			d.CanQuery = true
		elseif BRIDGE[d.Name] then
			decks += 1
		end
	end
end

local roadChecked, roadFloat, roadBury = 0, 0, 0
local roadLifted, roadLiftedList = 0, {}
local roadWorstFloat, roadWorstBury = {}, {}
local columns, hangingColumns = 0, 0
for _, part in ipairs(surfaces) do
	roadChecked += 1
	-- Along the part's long axis, columns on both edges, just outside the surface.
	local size = part.Size
	local along, across = "Z", "X"
	if size.X > size.Z then
		along, across = "X", "Z"
	end
	local length, width = size[along], size[across]
	local n = math.max(1, math.ceil(length / ROAD_STEP))
	local maxGap, maxBury, gapAt, buryAt, gapOn, buryOn = 0, 0, nil, nil, "?", "?"
	local hanging = 0
	for i = 0, n do
		local a = -length / 2 + length * i / n
		for _, side in ipairs({ -1, 1 }) do
			local c = side * (width / 2 + EDGE_OUT)
			local localPoint = along == "Z" and Vector3.new(c, -size.Y / 2, a) or Vector3.new(a, -size.Y / 2, c)
			local point = part.CFrame:PointToWorldSpace(localPoint)
			-- Only the part itself is left out: a road may rightly rest on a junction pad or a kerb,
			-- and those are ground for it.
			local gap, material = groundGap(point, part)
			columns += 1
			if gap > maxGap then
				maxGap, gapAt, gapOn = gap, point, material
			end
			if -gap > maxBury then
				maxBury, buryAt, buryOn = -gap, point, material
			end
			if gap > FLOAT then
				hanging += 1
			end
		end
	end
	local owner = part.Parent and part.Parent.Name or "?"
	if maxGap > FLOAT then
		local support = unqueryableSupport(part, gapAt, maxGap)
		if support then
			clutterSupported += 1
			out("NOTE %s %s at %s: an edge column hangs %.1f over %s but rests on non-queryable %s; not counted", owner, part.Name, v3(part.Position), maxGap, gapOn, support.Name)
		else
			roadFloat += 1
			hangingColumns += hanging
			countMaterial(gapOn)
			table.insert(roadWorstFloat, { gap = maxGap, text = string.format("%s %s at %s (%.0f long): %d edge columns hang, worst %.1f studs at %s over %s", owner, part.Name, v3(part.Position), length, hanging, maxGap, v3(gapAt), gapOn) })
		end
	end
	if maxGap <= FLOAT and maxGap > HAIR then
		roadLifted += 1
		table.insert(roadLiftedList, { gap = maxGap, text = string.format("%s %s at %s: worst edge column %.1f over %s at %s", owner, part.Name, v3(part.Position), maxGap, gapOn, v3(gapAt)) })
	end
	if maxBury > BURY then
		roadBury += 1
		countMaterial(buryOn)
		table.insert(roadWorstBury, { gap = maxBury, text = string.format("%s %s at %s: ground (%s) %.1f studs above the road's underside at %s", owner, part.Name, v3(part.Position), buryOn, maxBury, v3(buryAt)) })
	end
end
for part, was in pairs(restore) do
	part.CanQuery = was
end
table.sort(roadWorstFloat, function(a, b)
	return a.gap > b.gap
end)
table.sort(roadWorstBury, function(a, b)
	return a.gap > b.gap
end)

out("ROADS %d surface parts checked (%d edge columns), %d bridge decks left out: %d parts float (an edge column > %.1f studs above ground, %d columns in all), %d parts buried (ground > %.1f above the underside)",
	roadChecked, columns, decks, roadFloat, FLOAT, hangingColumns, roadBury, BURY)
for index = 1, math.min(15, #roadWorstFloat) do
	out("PROBLEM road floating: %s", roadWorstFloat[index].text)
end
for index = 1, math.min(8, #roadWorstBury) do
	out("PROBLEM road buried: %s", roadWorstBury[index].text)
end
table.sort(roadLiftedList, function(a, b)
	return a.gap > b.gap
end)
out("ROADS lifted a little: %d parts with a worst edge column between %.1f and %.1f up (visible, not counted as floating)", roadLifted, HAIR, FLOAT)
for index = 1, math.min(8, #roadLiftedList) do
	out("NOTE road lifted: %s", roadLiftedList[index].text)
end

--------------------------------------------------------------------------------
-- Boulders
--------------------------------------------------------------------------------

-- Loose rocks are parts, not Models with a floor, so the structure walk never sees them, and a rock
-- hovering over the grass or the river is the first thing a player notices. Every part named like a
-- rock under the Map, in any container (River and Decor included), is measured on its own underside:
-- a 3 x 3 grid on a block's bottom face however it is tilted, or the sphere's underside for a Ball
-- (which renders at its smallest dimension). WATER counts as a surface here: a stepping stone
-- belongs in the river, not over it.
-- Anything named like a rock (Rock, Boulder, SteppingStone, OasisBoulder, Rock_3, BigStone ...), but
-- not a wall built of stone, which is a structure part.
local function rockName(name)
	-- A vehicle's rocker panel (RockerL/RockerR) is not a rock; measured once as 12 "floating boulders".
	if string.find(name, "Wall") or string.find(name, "Rocker") then
		return false
	end
	return string.find(name, "Rock") ~= nil or string.find(name, "Boulder") ~= nil or string.find(name, "Stone") ~= nil
end
local function underVehicle(part)
	local node = part.Parent
	while node and node ~= map do
		if node.Name == "Vehicles" or node.Name == "Vehicle" then
			return true
		end
		node = node.Parent
	end
	return false
end
local MIN_ROCK = 3
local PERCH = 2
local rockParams = RaycastParams.new()
rockParams.FilterType = Enum.RaycastFilterType.Exclude
rockParams.IgnoreWater = false

local rocks = {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") and rockName(d.Name) and math.max(d.Size.X, d.Size.Y, d.Size.Z) >= MIN_ROCK and not underVehicle(d) then
		table.insert(rocks, d)
	end
end
local rockChecked, rockFloating, rockPerched, rockLifted = 0, 0, 0, 0
local rockWorst, rockByKind = {}, {}
for _, rock in ipairs(rocks) do
	rockChecked += 1
	local size = rock.Size
	local ball = rock:IsA("Part") and rock.Shape == Enum.PartType.Ball
	local points = {}
	if ball then
		-- The sphere's lowest point, and four more out at 60% of the radius.
		local radius = math.min(size.X, size.Y, size.Z) / 2
		local centre = rock.Position
		table.insert(points, centre - Vector3.new(0, radius, 0))
		local r = radius * 0.6
		local drop = math.sqrt(radius * radius - r * r)
		for _, offset in ipairs({ Vector3.new(r, 0, 0), Vector3.new(-r, 0, 0), Vector3.new(0, 0, r), Vector3.new(0, 0, -r) }) do
			table.insert(points, centre + offset - Vector3.new(0, drop, 0))
		end
	else
		for i = -1, 1 do
			for j = -1, 1 do
				table.insert(points, rock.CFrame:PointToWorldSpace(Vector3.new(i * size.X * 0.4, -size.Y / 2, j * size.Z * 0.4)))
			end
		end
	end
	local minGap, maxGap, gapAt, gapOn = math.huge, -math.huge, nil, "?"
	for _, point in ipairs(points) do
		local gap, material = castGap(point, rock, rockParams)
		if gap > maxGap then
			maxGap, gapAt, gapOn = gap, point, material
		end
		minGap = math.min(minGap, gap)
	end
	local kind = rockByKind[rock.Name]
	if not kind then
		kind = { checked = 0, floating = 0, perched = 0, lifted = 0 }
		rockByKind[rock.Name] = kind
	end
	kind.checked += 1
	local verdict, rank = nil, 0
	if minGap > FLOAT then
		verdict, rank = "floating", 2000 + minGap
		rockFloating += 1
		kind.floating += 1
	elseif maxGap > PERCH then
		verdict, rank = "perched", 1000 + maxGap
		rockPerched += 1
		kind.perched += 1
	elseif maxGap > HAIR then
		verdict, rank = "lifted", maxGap
		rockLifted += 1
		kind.lifted += 1
	end
	if verdict then
		local owner = rock.Parent and rock.Parent.Name or "?"
		table.insert(rockWorst, { rank = rank, text = string.format("%s: %s/%s at %s (%.1f across%s): underside from %.1f to %.1f above the surface, highest over %s at %s",
			verdict, owner, rock.Name, v3(rock.Position), math.max(size.X, size.Z), ball and ", ball" or "", minGap, maxGap, gapOn, v3(gapAt)) })
	end
end
table.sort(rockWorst, function(a, b)
	return a.rank > b.rank
end)
out("BOULDERS %d rock parts checked (Rock/Boulder/SteppingStone/OasisBoulder, %d studs or more, water counts as the surface): %d floating (whole underside > %.1f up), %d perched (a corner > %.1f up, the rest touching), %d lifted a little (%.1f..%.1f)",
	rockChecked, MIN_ROCK, rockFloating, FLOAT, rockPerched, PERCH, rockLifted, HAIR, FLOAT)
local rockKinds = {}
for name in pairs(rockByKind) do
	table.insert(rockKinds, name)
end
table.sort(rockKinds)
for _, name in ipairs(rockKinds) do
	local k = rockByKind[name]
	out("BOULDERS %s: %d checked, %d floating, %d perched, %d lifted", name, k.checked, k.floating, k.perched, k.lifted)
end
for index = 1, math.min(12, #rockWorst) do
	out("%s boulder %s", rockWorst[index].rank >= 1000 and "PROBLEM" or "NOTE", rockWorst[index].text)
end

out("MATERIALS %d problems sit on rough or stepped terrain (Rock, Basalt, Ice, Slate, CrackedLava; Pavement, Concrete, Brick, WoodPlanks, Cobblestone; may be terrain noise of up to ~1.2 studs), %d on smooth ground or parts",
	roughProblems, exactProblems)
out("SUMMARY %s: structures %d/%d floating, %d buried, %d lifted a little (%d measured by FootingBase/Size, %d by bounding box, %d skipped, %d FootingGroup containers walked, %d of them empty); roads %d/%d floating, %d buried, %d lifted; boulders %d/%d floating, %d perched, %d lifted; %d of the problems on rough/snapping terrain; %d hanging points found resting on non-queryable decor (notes, not counted)",
	MAP_ID, floating, checked, buried, lifted, byAttributes, byBox, skipped, groupCount, emptyGroups, roadFloat, roadChecked, roadBury, roadLifted, rockFloating, rockChecked, rockPerched, rockLifted, roughProblems, clutterSupported)
