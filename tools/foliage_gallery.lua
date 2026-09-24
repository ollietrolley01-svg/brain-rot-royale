-- Foliage spread gallery and probe (Oliver 09-24, "spread the foliage more across the map"): builds
-- every map in turn and photographs it from straight above -- the whole map, then each quarter
-- closer in -- and prints how evenly the foliage covers it. tools/foliage_map.py measures the same
-- thing under lupa on the harness's height-function ground; this is the picture, on real terrain.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/foliage_gallery.lua -OutDir <folder>\after -TimeoutSeconds 1500
--
-- BEFORE AND AFTER: run it twice with the same SEED, once on this commit and once on the commit before
-- the foliage change (build that tree's place with rojo and pass it as -PlaceFile), into two folders;
-- the shots are named alike (10_SahurSprings_whole.png and so on), so they pair up side by side.
--
-- The notes ("[BRR_Gallery] note ...") are the probe, per map: foliage parts (Map/Wilds less the
-- shelters, and Map/Props), all parts in the map, and over the 64-stud cells of open ground (inside
-- 0.93 of the radius, clear of the towns, ground under the centre that isn't water or paving) the
-- share with foliage rooted in them and the largest bare run of such cells. After the change it
-- should read about 0.9 covered with no bare run over a handful of cells; before, 0.5 to 0.7 with
-- runs of 50 to 160 cells.
--
-- What to look for: green spread across the whole map between the towns, denser in groves and on
-- slopes, thinner on open fields, never on a road, a car park or a building lot; hedge runs along the
-- country roads with gaps; reeds along both river banks; no bare rings round the towns or bare edges.

local SEED = 1
local MAPS = { "SahurSprings", "TralalaTown", "BombardiroBay", "RotRidge", "PatapimPlains" }

local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local CELL = 64
local FOLIAGE = { Woods = true, Trees = true, Clutter = true, GroundCover = true, Meadow = true, Hedgerow = true, StoneWall = true,
	Orchard = true, Grass = true, Fill = true, Reeds = true, Verge = true }
local PAVED = { [Enum.Material.Asphalt] = true, [Enum.Material.Pavement] = true, [Enum.Material.Concrete] = true,
	[Enum.Material.Water] = true }

local state = {}

-- Straight down from `height` over `at`, north up the frame.
local function above(camera, at, height, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.new(at + Vector3.new(0, height, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
end

local function measure(map, radius)
	local towns = {}
	for _, town in ipairs((map:FindFirstChild("Towns") or map):GetChildren()) do
		local centre = town:GetAttribute("TownCenter")
		if centre then
			table.insert(towns, { centre = centre, spread = town:GetAttribute("TownSpread") or 150 })
		end
	end
	local perCell, foliage, all = {}, 0, 0
	local function add(part)
		foliage += 1
		local p = part.Position
		local key = math.floor(p.X / CELL) * 65536 + math.floor(p.Z / CELL)
		perCell[key] = (perCell[key] or 0) + 1
	end
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") then
			all += 1
		end
	end
	local wilds = map:FindFirstChild("Wilds")
	for _, child in ipairs(wilds and wilds:GetChildren() or {}) do
		if FOLIAGE[child.Name:match("^(%a+)")] then
			for _, part in ipairs(child:GetDescendants()) do
				if part:IsA("BasePart") then
					add(part)
				end
			end
		end
	end
	local props = map:FindFirstChild("Props")
	for _, part in ipairs(props and props:GetDescendants() or {}) do
		if part:IsA("BasePart") then
			add(part)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local limit = radius * 0.93
	local eligible, covered, bare = 0, 0, {}
	local n = math.ceil(radius / CELL)
	for ix = -n, n do
		for iz = -n, n do
			local x, z = (ix + 0.5) * CELL, (iz + 0.5) * CELL
			local ok = x * x + z * z < limit * limit
			for _, town in ipairs(towns) do
				if ok and (Vector2.new(town.centre.X - x, town.centre.Z - z)).Magnitude < town.spread + 40 then
					ok = false
				end
			end
			if ok then
				local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), params)
				ok = hit ~= nil and not PAVED[hit.Material]
			end
			if ok then
				eligible += 1
				local key = ix * 65536 + iz
				if (perCell[key] or 0) >= 2 then
					covered += 1
				else
					bare[key] = true
				end
			end
		end
	end
	-- The largest 4-connected bare run.
	local seen, largest = {}, 0
	for start in pairs(bare) do
		if not seen[start] then
			local stack, size = { start }, 0
			seen[start] = true
			while #stack > 0 do
				local key = table.remove(stack)
				size += 1
				for _, step in ipairs({ 1, -1, 65536, -65536 }) do
					local other = key + step
					if bare[other] and not seen[other] then
						seen[other] = true
						table.insert(stack, other)
					end
				end
			end
			largest = math.max(largest, size)
		end
	end
	return foliage, all, eligible, covered, largest
end

local views = {}
for index, mapId in ipairs(MAPS) do
	local base = 10 * index
	table.insert(views, {
		name = string.format("%02d_%s_whole", base, mapId),
		settle = 4,
		setup = function(_, camera)
			Lighting.ClockTime = 13
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(SEED)
			local started = os.clock()
			local info = MapGenerator.Build(mapId)
			local map = workspace:FindFirstChild("Map")
			local radius = info and info.radius or 1000
			state[mapId] = radius
			local foliage, all, eligible, covered, largest = measure(map, radius)
			note("%s seed %d: built in %.1fs, %d parts, %d foliage (%d wilds parts attr)", mapId, SEED, os.clock() - started, all,
				foliage, map:GetAttribute("WildsParts") or -1)
			note("%s: %d of %d open 64-stud cells have foliage (%.3f), largest bare run %d cells", mapId, covered, eligible,
				covered / math.max(1, eligible), largest)
			above(camera, Vector3.zero, radius * 1.95, 60)
		end,
	})
	for quarter, sign in ipairs({ { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }) do
		table.insert(views, {
			name = string.format("%02d_%s_quarter%d", base + quarter, mapId, quarter),
			settle = 2,
			setup = function(_, camera)
				local radius = state[mapId] or 1000
				above(camera, Vector3.new(sign[1] * radius * 0.45, 0, sign[2] * radius * 0.45), radius * 0.95, 60)
			end,
		})
	end
end

return views
