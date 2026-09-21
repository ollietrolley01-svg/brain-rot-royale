-- Roof access probe: how high a ledge-climb could reach before it puts players on town roofs.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/roof_access_probe.lua -WaitSeconds 600
--
-- Builds one map (edit MAP_ID / SEED; one map per run). Around every building it samples columns on
-- rings 0.25..6 studs outside the walls, and lists every surface you could stand on down each column
-- (ground, docks, awnings, balconies, crates, props, a neighbour's parts), plus the roof's own surfaces
-- (eaves, parapet tops, coping) where it overhangs the ring.
--
-- Then, for each candidate climb height M, it floods what's reachable without items:
--   * from the ground: anything standable up to JUMP_STEP above it (a plain jump, measured 7.86),
--   * from anything reachable: anything within CLIMB_REACH studs sideways and up to M above it (a climb),
--     or within JUMP_ACROSS sideways and up to JUMP_STEP above it (a plain jump across),
-- and reports how many roofs that opens, with the chain of surfaces for the lowest M that opens one.
-- "Standable" means a part whose smaller horizontal size is at least MIN_STAND (a 0.7-deep sill isn't),
-- or terrain, which is how Shared/Parkour judges a top too.

local MAP_ID, SEED = "SahurSprings", 101

local JUMP_STEP = 7.8
local JUMP_ACROSS = 10
local CLIMB_REACH = 3.2
local MIN_STAND = 0.9
local CANDIDATES = { 7.8, 8.5, 9, 9.5, 10, 10.5, 11, 12, 13, 14 }

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))

local function out(fmt, ...)
	print("[RoofProbe] " .. string.format(fmt, ...))
end

math.randomseed(SEED)
local t0 = os.clock()
local info = MapGenerator.Build(MAP_ID)
local map = workspace:WaitForChild("Map")
out("map %s seed %d built in %.1fs, radius %d", MAP_ID, SEED, os.clock() - t0, info.radius)
task.wait(1)
if flush then
	flush()
end

local ROOF_NAMES = { Roof = true, Parapet = true, Coping = true, RidgeCap = true, Gable = true, GableVent = true }
local ARCHETYPES = { house = true, tower = true, warehouse = true }

-- The smaller horizontal extent of a part's top face, near enough for boxes turned about Y.
local function standWidth(part)
	if part:IsA("Terrain") then
		return math.huge
	end
	local s = part.Size
	local up = part.CFrame:VectorToObjectSpace(Vector3.new(0, 1, 0))
	local ax, ay, az = math.abs(up.X), math.abs(up.Y), math.abs(up.Z)
	if ay >= ax and ay >= az then
		return math.min(s.X, s.Z)
	elseif ax >= az then
		return math.min(s.Y, s.Z)
	end
	return math.min(s.X, s.Y)
end

local buildings = {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("Model") and ARCHETYPES[d.Name] then
		table.insert(buildings, d)
	end
end
out("buildings: %d", #buildings)

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.RespectCanCollide = true
params.IgnoreWater = true
params.FilterDescendantsInstances = {}

-- Every upward-facing surface down one column, top first.
local function column(x, z, fromY, toY)
	local surfaces = {}
	local y = fromY
	for _ = 1, 16 do
		if y <= toY then
			break
		end
		local hit = workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -(y - toY), 0), params)
		if not hit then
			break
		end
		if hit.Normal.Y >= 0.72 then
			table.insert(surfaces, { y = hit.Position.Y, part = hit.Instance })
		end
		if hit.Instance:IsA("Terrain") then
			break
		end
		-- Start again just under this surface: a ray that begins inside a part passes through it.
		y = hit.Position.Y - 0.05
	end
	return surfaces
end

local CELL = 2
local function cellKey(x, z)
	return math.floor(x / CELL) .. "," .. math.floor(z / CELL)
end

local opened = {}
for _, m in ipairs(CANDIDATES) do
	opened[m] = 0
end
local closest = {}

for _, building in ipairs(buildings) do
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	local roofTop = -math.huge
	for _, part in ipairs(building:GetDescendants()) do
		if part:IsA("BasePart") then
			if part.Name == "Wall" then
				local cf, s = part.CFrame, part.Size / 2
				for _, sx in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local p = cf:PointToWorldSpace(Vector3.new(s.X * sx, 0, s.Z * sz))
						minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
						minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
					end
				end
			end
			if ROOF_NAMES[part.Name] then
				roofTop = math.max(roofTop, part.Position.Y + part.Size.Magnitude)
			end
		end
	end
	if minX < math.huge and roofTop > -math.huge then
		local ground = MapGenerator.GroundHeightAt((minX + maxX) / 2, (minZ + maxZ) / 2)
		local surfaces = {}
		local grid = {}
		local function add(x, z, s, groundY)
			local isRoof = ROOF_NAMES[s.part.Name] == true
			local entry = {
				x = x, z = z, y = s.y, part = s.part, roof = isRoof, own = s.part:IsDescendantOf(building),
				stand = isRoof or standWidth(s.part) >= MIN_STAND, fromGround = s.y - groundY,
			}
			table.insert(surfaces, entry)
			local key = cellKey(x, z)
			grid[key] = grid[key] or {}
			table.insert(grid[key], entry)
		end
		for _, outDistance in ipairs({ 0.25, 1, 2, 3, 4.5, 6 }) do
			local x0, x1, z0, z1 = minX - outDistance, maxX + outDistance, minZ - outDistance, maxZ + outDistance
			local points = {}
			for x = x0, x1, 1.5 do
				table.insert(points, { x, z0 })
				table.insert(points, { x, z1 })
			end
			for z = z0, z1, 1.5 do
				table.insert(points, { x0, z })
				table.insert(points, { x1, z })
			end
			for _, p in ipairs(points) do
				local list = column(p[1], p[2], roofTop + 10, ground - 40)
				local groundY = #list > 0 and list[#list].y or ground
				for _, s in ipairs(list) do
					add(p[1], p[2], s, groundY)
				end
			end
		end

		local function flood(m)
			local reached = {}
			local queue = {}
			for _, s in ipairs(surfaces) do
				if s.stand and not (s.roof and s.own) and s.fromGround <= JUMP_STEP then
					reached[s] = "ground"
					table.insert(queue, s)
				end
			end
			local head = 1
			while head <= #queue do
				local r = queue[head]
				head += 1
				local cx, cz = math.floor(r.x / CELL), math.floor(r.z / CELL)
				local span = math.ceil(JUMP_ACROSS / CELL)
				for dx = -span, span do
					for dz = -span, span do
						local bucket = grid[(cx + dx) .. "," .. (cz + dz)]
						if bucket then
							for _, s in ipairs(bucket) do
								if not reached[s] and (s.stand or s.roof) then
									local across = math.sqrt((s.x - r.x) ^ 2 + (s.z - r.z) ^ 2)
									local up = s.y - r.y
									if (up <= JUMP_STEP and across <= JUMP_ACROSS) or (up <= m and across <= CLIMB_REACH) then
										reached[s] = r
										table.insert(queue, s)
									end
								end
							end
						end
					end
				end
			end
			for _, s in ipairs(surfaces) do
				if s.roof and s.own and reached[s] then
					return s, reached
				end
			end
			return nil
		end

		local lowest = nil
		for _, m in ipairs(CANDIDATES) do
			local roof, reached = flood(m)
			if roof then
				opened[m] += 1
				if not lowest then
					lowest = m
					local chain = {}
					local node = roof
					while type(node) == "table" and #chain < 8 do
						table.insert(chain, string.format("%s %.1f", node.part.Name .. (node.own and "" or "*"), node.y - ground))
						node = reached[node]
					end
					table.insert(closest, {
						m = m, text = string.format("%-9s at (%.0f,%.0f): opens at M=%.1f via %s", building.Name,
							(minX + maxX) / 2, (minZ + maxZ) / 2, m, table.concat(chain, " <- ")),
					})
				end
			end
		end
	end
end

table.sort(closest, function(a, b)
	return a.m < b.m
end)
for index, row in ipairs(closest) do
	if index <= 20 then
		out("%s", row.text)
	end
end
for _, m in ipairs(CANDIDATES) do
	out("climb height M %.1f opens %d of %d roofs", m, opened[m], #buildings)
end

MapGenerator.Clear()
out("done")
print("[BRR_Probe] done")
