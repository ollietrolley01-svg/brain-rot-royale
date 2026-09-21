-- The drop map: a picture of the match's terrain, sampled on the SERVER once per match and drawn by
-- the client (StarterPlayerScripts/DropPicker.lua).
--
-- WHY THE SERVER SAMPLES IT. Streaming means a client holds only the parts near its own body, and
-- during the drop window it has no body at all — so a client-drawn map of "what I can see" would be
-- a picture of almost nothing. The server has the whole map. It samples the ground into a small
-- raster and sends that, together with the vector geometry a map needs to be readable: the roads,
-- the river, the towns and the landmarks. The same argument covers the LABELS: the town and
-- landmark names used to be read off `workspace.Map`'s attributes on the client, which is the same
-- bet on streaming that the raster exists to avoid.
--
-- WHY THE ROADS ARE VECTORS AND THE GROUND IS A RASTER. A road is about 18 studs wide and a raster
-- cell on the biggest map is 20. Sampled, a road comes out dotted; stamped, it comes out as a
-- 20-stud smear that wanders off the real line. Both lie about the thing a player navigates by. So
-- roads travel as the line segments they really are and are drawn at the pixel resolution of
-- whatever size the map is being drawn at, while ground cover — which genuinely is a field — stays
-- a raster. Buildings stay a raster too: there are hundreds of them, they read as blocks of town at
-- this scale, and a block is what a raster is good at.
--
-- WHAT IT COSTS is printed by tools/vote_drop_gallery.lua's `build` view every run: the sample time,
-- the cell counts, the wire size and the round-trip error. Nothing here is asserted from memory.
--
-- THE RADIUS IS NEVER TAKEN FROM A CLIENT. It comes from VoteService's cached resolution — the very
-- mapId MatchService passed to MapGenerator.Build — looked up in MapData. A wrong radius would draw
-- the map at the wrong scale, so the sampler also counts cells inside the disc where there is no
-- ground at all and puts the count in the payload: `groundless` should be near zero on a real map,
-- and a scale that has slipped shows up there instead of only in someone's eyes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapData = require(Shared:WaitForChild("MapData"))
local VoteService = require(script.Parent:WaitForChild("VoteService"))

local DropMapService = {}

-- 128 x 128 over the map's square: 20 studs a cell on the 1280-radius maps, 15 on the smallest.
-- Both strings are one byte a cell, so the wire is 2 * N * N bytes plus the vectors.
DropMapService.N = 128

-- The height alphabet travels WITH the payload. A wire format written down in two files drifts;
-- this one is written down once and the decoder is handed the table it was encoded with.
DropMapService.Alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"

-- A road network with more segments than this is not a map, it is a bug; the count is reported so a
-- truncation can never be silent.
local MAX_ROAD_SEGMENTS = 1400

local MATERIAL_CLASS = {
	[Enum.Material.Water] = "w",
	[Enum.Material.Grass] = "g",
	[Enum.Material.LeafyGrass] = "g",
	[Enum.Material.Sand] = "s",
	[Enum.Material.Sandstone] = "s",
	[Enum.Material.Ground] = "d",
	[Enum.Material.Mud] = "d",
	[Enum.Material.Rock] = "k",
	[Enum.Material.Slate] = "k",
	[Enum.Material.Basalt] = "k",
	[Enum.Material.Limestone] = "k",
	[Enum.Material.Snow] = "n",
	[Enum.Material.Glacier] = "n",
	[Enum.Material.Salt] = "n",
	[Enum.Material.Ice] = "n",
	[Enum.Material.Asphalt] = "p",
	[Enum.Material.Concrete] = "p",
	[Enum.Material.Cobblestone] = "p",
	[Enum.Material.Pavement] = "p",
}

-- What a part standing on a cell makes of that cell. Walks up to the Map folder: a road reads as
-- paving (the road LINE is drawn from the real footprint over the top, so a road's cells must not
-- also be stamped dark or the line comes out three times its width); a town part reads as a
-- building if it stands over 4 studs, as paving if it is a kerb or a yard; a landmark reads as a
-- landmark only if it stands proud. Props, vehicles and ziplines are ignored, so a tree is not a
-- house.
local function classify(hit, groundY)
	local inst = hit.Instance
	local lift = hit.Position.Y - groundY
	while inst and inst ~= workspace do
		local name = inst.Name
		if name == "Roads" then
			return "p"
		elseif name == "Props" or name == "Vehicles" or name == "Ziplines" then
			return nil
		elseif name == "Landmarks" then
			return lift > 3 and "l" or nil
		elseif name == "Town" then
			return lift > 4 and "b" or "p"
		elseif name == "Map" then
			return nil
		end
		inst = inst.Parent
	end
	return nil
end

-- Marks every cell whose centre lies inside a turned rectangle (a building's box), grown by
-- `dilate`. Cells outside the disc keep the "." they started with.
local function stamp(raster, cf, sx, sz, dilate, class)
	local n, cell, radius = raster.n, raster.cell, raster.radius
	local hx, hz = sx / 2 + dilate, sz / 2 + dilate
	local right, look = cf.RightVector, cf.LookVector
	local ex = hx * math.abs(right.X) + hz * math.abs(look.X)
	local ez = hx * math.abs(right.Z) + hz * math.abs(look.Z)
	local px, pz = cf.Position.X, cf.Position.Z
	local c0 = math.max(1, math.floor((px - ex + radius) / cell) + 1)
	local c1 = math.min(n, math.floor((px + ex + radius) / cell) + 1)
	local r0 = math.max(1, math.floor((pz - ez + radius) / cell) + 1)
	local r1 = math.min(n, math.floor((pz + ez + radius) / cell) + 1)
	local count = 0
	for row = r0, r1 do
		local cz = -radius + (row - 0.5) * cell
		for col = c0, c1 do
			local cx = -radius + (col - 0.5) * cell
			local i = (row - 1) * n + col
			if raster.classes[i] ~= "." then
				local local_ = cf:PointToObjectSpace(Vector3.new(cx, cf.Position.Y, cz))
				if math.abs(local_.X) <= hx and math.abs(local_.Z) <= hz then
					raster.classes[i] = class
					count += 1
				end
			end
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------

function DropMapService.Sample(map, radius)
	local n = DropMapService.N
	local cell = 2 * radius / n
	local raster = {
		n = n,
		radius = radius,
		cell = cell,
		classes = table.create(n * n, "."),
		heights = table.create(n * n, 0),
		min = math.huge,
		max = -math.huge,
		counts = {
			samples = 0, groundless = 0, water = 0, built = 0, stampedBuilt = 0,
			landmark = 0, paved = 0, roadSegments = 0, roadSkipped = 0,
		},
	}

	local terrainParams = RaycastParams.new()
	terrainParams.FilterType = Enum.RaycastFilterType.Include
	terrainParams.FilterDescendantsInstances = { workspace.Terrain }
	terrainParams.IgnoreWater = false
	local mapParams = RaycastParams.new()
	mapParams.FilterType = Enum.RaycastFilterType.Include
	mapParams.FilterDescendantsInstances = { map }

	-- A raycast never reports terrain the ray STARTS inside, and a ray that starts too low reads as
	-- "no ground at all" rather than failing loudly. Start well above anything the map builds.
	local START_Y = 2000
	local down = Vector3.new(0, -4000, 0)
	for row = 1, n do
		local cz = -radius + (row - 0.5) * cell
		for col = 1, n do
			local cx = -radius + (col - 0.5) * cell
			if cx * cx + cz * cz <= radius * radius then
				local i = (row - 1) * n + col
				local origin = Vector3.new(cx, START_Y, cz)
				local ground = workspace:Raycast(origin, down, terrainParams)
				local class, h = "g", 0
				if ground then
					h = ground.Position.Y
					class = MATERIAL_CLASS[ground.Material] or "g"
				else
					raster.counts.groundless += 1
				end
				local over = workspace:Raycast(origin, down, mapParams)
				if over and over.Instance then
					local kind = classify(over, h)
					if kind then
						class = kind
					end
				end
				raster.classes[i] = class
				raster.heights[i] = h
				raster.min = math.min(raster.min, h)
				raster.max = math.max(raster.max, h)
				raster.counts.samples += 1
			end
		end
		if row % 12 == 0 then
			task.wait()
		end
	end

	-- Buildings from their real boxes. A model under a Town that stands 6 studs and covers 60 square
	-- studs is a building; anything smaller is furniture and belongs to the ground it sits on.
	for _, town in ipairs(map:GetChildren()) do
		if town.Name == "Town" then
			for _, child in ipairs(town:GetChildren()) do
				if child:IsA("Model") then
					local ok, cf, size = pcall(function()
						return child:GetBoundingBox()
					end)
					if ok and size and size.Y >= 6 and size.X * size.Z >= 60 then
						raster.counts.stampedBuilt += stamp(raster, cf, size.X, size.Z, cell * 0.2, "b")
					end
				end
			end
		end
	end

	for i = 1, n * n do
		local class = raster.classes[i]
		if class == "w" then
			raster.counts.water += 1
		elseif class == "b" then
			raster.counts.built += 1
		elseif class == "l" then
			raster.counts.landmark += 1
		elseif class == "p" then
			raster.counts.paved += 1
		end
	end
	if raster.max <= raster.min then
		raster.max = raster.min + 1
	end
	return raster
end

-- Every road slab as the line it is: centre, direction and width, quantised to whole studs. A slab
-- is longer than it is wide along one of its own axes; which one is decided per part rather than
-- assumed, because a curve piece is built the other way round from a straight.
function DropMapService.RoadSegments(map, counts)
	local roads = map:FindFirstChild("Roads")
	local parts = {}
	if not roads then
		return ""
	end
	for _, part in ipairs(roads:GetDescendants()) do
		if part:IsA("BasePart") and part.Size.Y < 3 and (part.Name == "Road" or part.Name == "RoadCurve") then
			table.insert(parts, part)
		end
	end
	local out = {}
	for index, part in ipairs(parts) do
		if index > MAX_ROAD_SEGMENTS then
			counts.roadSkipped = #parts - MAX_ROAD_SEGMENTS
			break
		end
		local cf, size = part.CFrame, part.Size
		local along, width
		if size.X >= size.Z then
			along, width = cf.RightVector * (size.X / 2), size.Z
		else
			along, width = cf.LookVector * (size.Z / 2), size.X
		end
		local a = cf.Position - along
		local b = cf.Position + along
		table.insert(out, string.format("%d,%d,%d,%d,%d",
			math.round(a.X), math.round(a.Z), math.round(b.X), math.round(b.Z), math.round(width)))
		counts.roadSegments += 1
	end
	return table.concat(out, ";")
end

-- Towns and landmarks, with the names the labels show. `TownRadius` is the town's own claimed
-- radius; the ring drawn from it is how a player tells a hamlet from a downtown at a glance.
local function placesOf(map)
	local towns, landmarks = {}, {}
	for _, child in ipairs(map:GetChildren()) do
		local centre = child:GetAttribute("TownCenter")
		if centre then
			table.insert(towns, {
				name = child:GetAttribute("TownName") or "Town",
				x = math.round(centre.X),
				z = math.round(centre.Z),
				r = math.round(child:GetAttribute("TownRadius") or 120),
			})
		end
	end
	local folder = map:FindFirstChild("Landmarks")
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			local centre = child:GetAttribute("LandmarkCenter")
			if centre then
				table.insert(landmarks, {
					name = child:GetAttribute("LandmarkName") or "Landmark",
					x = math.round(centre.X),
					z = math.round(centre.Z),
				})
			end
		end
	end
	return towns, landmarks
end

--------------------------------------------------------------------------------
-- The wire
--------------------------------------------------------------------------------

-- One class letter and one height letter per cell (64 levels between the map's own lowest and
-- highest ground), plus the vectors. The alphabet goes with it so the decoder cannot drift.
function DropMapService.Encode(raster, map, mapName)
	local alphabet = DropMapService.Alphabet
	local heights = table.create(raster.n * raster.n)
	local span = raster.max - raster.min
	for i = 1, raster.n * raster.n do
		local q = math.clamp(math.floor((raster.heights[i] - raster.min) / span * 63 + 0.5), 0, 63)
		heights[i] = string.sub(alphabet, q + 1, q + 1)
	end
	local towns, landmarks = placesOf(map)
	local counts = raster.counts
	return {
		n = raster.n,
		radius = raster.radius,
		min = raster.min,
		max = raster.max,
		alphabet = alphabet,
		classes = table.concat(raster.classes),
		heights = table.concat(heights),
		roads = DropMapService.RoadSegments(map, counts),
		river = map:GetAttribute("RiverPath") or "",
		towns = towns,
		landmarks = landmarks,
		mapName = mapName,
		-- Carried so a probe, a gallery and a support question can all read what the sample found
		-- without re-running it. `groundless` is the scale check described at the top of this file.
		counts = counts,
	}
end

--------------------------------------------------------------------------------
-- The cache
--------------------------------------------------------------------------------

-- Fifty clients ask for this within a second of each other and the answer is the same for all of
-- them, so it is sampled once. `building` is the single-flight latch: a caller that arrives while
-- the sample is running waits for it instead of starting a second one.
local cache = nil
local building = false

local function payloadFor(map, radius, mapName)
	if cache and cache.map == map and cache.radius == radius then
		return cache.payload
	end
	if building then
		-- tick() and not os.clock(): os.clock() is process CPU time in Roblox, and a sampler that
		-- spends most of its time yielding would make this deadline unreachable.
		local deadline = tick() + 30
		while building and tick() < deadline do
			task.wait(0.1)
		end
		if cache and cache.map == map and cache.radius == radius then
			return cache.payload
		end
	end

	building = true
	local ok, result = pcall(function()
		local raster = DropMapService.Sample(map, radius)
		return DropMapService.Encode(raster, map, mapName)
	end)
	building = false
	if not ok then
		warn("[DropMapService] sampling failed: " .. tostring(result))
		return nil
	end
	cache = { map = map, radius = radius, payload = result }
	return result
end

-- The payload for the match now on, or nil if there is no map to draw. The map instance is the
-- cache key, so a new match's map misses the cache by construction rather than by remembering to
-- clear it.
function DropMapService.Current()
	local map = workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	-- VoteService's resolution is cached until the next Open, and it is the very mapId MatchService
	-- passed to MapGenerator.Build, so this is the built map's own preset — not a guess and not
	-- anything a client sent.
	local mapId = VoteService.Resolve()
	local preset = MapData.Get(mapId)
	if not preset then
		return nil
	end
	return payloadFor(map, preset.radius, preset.name)
end

-- Public for the probe and the gallery, which build a map themselves and hand it over directly.
function DropMapService.For(map, radius, mapName)
	return payloadFor(map, radius, mapName)
end

-- Drops the cache. Nothing needs to call this — the map instance is the key — but a tool that
-- rebuilds a map in place would otherwise read a stale picture.
function DropMapService.Clear()
	cache = nil
end

-- Nothing here is per-player: one map, one picture, the same for everyone. So there is no
-- PlayerRemoving handler and nothing to forget when someone leaves.

return DropMapService
