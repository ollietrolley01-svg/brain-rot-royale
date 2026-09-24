-- The ground breaks, and nobody falls through the map (Oliver 2026-09-24), measured on a real built
-- map. For tools/runtest.ps1 -Probe (edit mode is enough: craters are terrain writes, not physics).
-- Build the place first (python build_place.py .), then:
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/ground_probe.lua -WaitSeconds 600 [-PlaceFile <rbxlx>]
--
-- Lines start "[GROUND]"; "PROBLEM" lines are findings, "FAULT" lines planted faults that must fire.
--
--   THICKNESS  how deep the terrain really goes: a grid over the whole played area, the surface by a
--              ray down and the underside by a ray up from under the world; the thinnest spots, and
--              how many cells have less than DigDepth + Bedrock under the surface (a crater there is
--              refused, so this only says where the bedrock layer is thin).
--   BOTTOM     REPEAT blasts (a rocket's crater each: reach 7, wall damage 150) on one spot of open
--              ground, at whatever the ground is by then, then the same round a ring about it, at
--              several spots with different ground. After every blast: the lowest ground within 10
--              studs, against the dig floor (the ground as built minus DigDepth). Want: it goes down,
--              stops AT the floor, and never passes it; terrain still solid a stud under the floor.
--   REFUSED    a blast at the river's edge (water in reach), on a road, and at the map's edge dig nothing.
--   RESCUE     a stand-in body dropped 300 studs under the world, one past the map's edge, and one
--              in the middle of the map: DestructibleService.Rescue puts the first two back on the
--              ground above (standing on it, speed zero) and leaves the third alone.
--   FAULT      the dig floor ignored (DestructibleService.CraterAt with DigDepth pushed to 200 by a
--              planted copy of the rule): the ground must then go under where the floor was.

local MAP_ID = "RotRidge"
local SEED = 7
local BLASTS = 30
local RING = 12
local GRID = 24

local ServerScriptService = game:GetService("ServerScriptService")
local modules = ServerScriptService:WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local DS = require(modules:WaitForChild("DestructibleService"))

local function out(fmt, ...)
	print("[GROUND] " .. string.format(fmt, ...))
end

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }
terrainParams.IgnoreWater = true

local function surfaceAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), terrainParams)
	return hit and hit.Position.Y or nil, hit and hit.Material or nil
end

local function lowestNear(x, z, reach)
	local low = math.huge
	for dx = -reach, reach, 2 do
		for dz = -reach, reach, 2 do
			local y = surfaceAt(x + dx, z + dz)
			if y then
				low = math.min(low, y)
			end
		end
	end
	return low
end

-- The ground on a 2-stud grid round (x, z), and how far under that it is now at worst.
local function gridAt(x, z, reach)
	local grid = {}
	for dx = -reach, reach, 2 do
		for dz = -reach, reach, 2 do
			grid[dx .. ":" .. dz] = surfaceAt(x + dx, z + dz)
		end
	end
	return grid
end
-- Measured against the height the service wrote down for that 4-stud cell (its dig floor is that
-- less DigDepth), or this probe's own reading before the first blast where no crater has come yet.
local function deepestUnder(x, z, reach, before)
	local worst = 0
	for dx = -reach, reach, 2 do
		for dz = -reach, reach, 2 do
			local px, pz = x + dx, z + dz
			local recorded = DS.GroundState.original[math.floor(px / 4) .. ":" .. math.floor(pz / 4)]
			local was = recorded or before[dx .. ":" .. dz]
			local now = surfaceAt(px, pz)
			if was and now then
				worst = math.max(worst, was - now)
			end
		end
	end
	return worst
end

local function solidAt(point)
	local ok, materials, occupancies = pcall(function()
		return workspace.Terrain:ReadVoxels(Region3.new(point - Vector3.new(0.1, 0.1, 0.1), point + Vector3.new(0.1, 0.1, 0.1)):ExpandToGrid(4), 4)
	end)
	if not ok then
		return false
	end
	local m, o = materials[1][1][1], occupancies[1][1][1]
	return m ~= Enum.Material.Air and m ~= Enum.Material.Water and o > 0.5, m
end

local ok, err = pcall(function()
	math.randomseed(SEED)
	local started = os.clock()
	local info = MapGenerator.Build(MAP_ID)
	local map = info.map
	out("built %s in %.1f s, radius %d; DigDepth %d, Bedrock %d, crater cap %d, crater max %.1f", MAP_ID, os.clock() - started,
		info.radius, DS.DigDepth, DS.Bedrock, DS.CraterCap, DS.CraterMax)

	-- THICKNESS
	local cells, thin, thinnest, where = 0, 0, math.huge, nil
	local step = 48
	local thicknesses = {}
	for x = -info.radius, info.radius, step do
		for z = -info.radius, info.radius, step do
			if x * x + z * z <= info.radius * info.radius then
				local top = surfaceAt(x, z)
				local under = DS.TerrainUnderside(x, z)
				if top and under then
					cells += 1
					local t = top - under
					table.insert(thicknesses, t)
					if t < thinnest then
						thinnest, where = t, Vector3.new(x, top, z)
					end
					if t < DS.DigDepth + DS.Bedrock then
						thin += 1
					end
				end
			end
		end
	end
	table.sort(thicknesses)
	out("THICKNESS %d cells (every %d studs over the played circle): thinnest %.1f at (%.0f, %.0f, %.0f), median %.1f; %d thinner than DigDepth + Bedrock (%d)",
		cells, step, thinnest, where and where.X or 0, where and where.Y or 0, where and where.Z or 0,
		thicknesses[math.max(1, math.floor(#thicknesses / 2))] or 0, thin, DS.DigDepth + DS.Bedrock)
	if thin > 0 then
		out("PROBLEM %d cells have too little ground under them for a full dig: craters there are refused as thin ground", thin)
	end

	-- Open ground to blast: well away from the towns, roads, water and anything built.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map, workspace.Terrain }
	params.IgnoreWater = false
	local spots, tried = {}, 0
	local wantMaterials = {}
	while #spots < 3 and tried < 4000 do
		tried += 1
		local angle, dist = math.random() * math.pi * 2, math.sqrt(math.random()) * info.radius * 0.8
		local x, z = math.cos(angle) * dist, math.sin(angle) * dist
		local hit = workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -1000, 0), params)
		if hit and hit.Instance == workspace.Terrain and hit.Material ~= Enum.Material.Water and not wantMaterials[hit.Material] then
			local clear = true
			for _, d in ipairs({ Vector3.new(14, 0, 0), Vector3.new(-14, 0, 0), Vector3.new(0, 0, 14), Vector3.new(0, 0, -14) }) do
				local h2 = workspace:Raycast(Vector3.new(x + d.X, 500, z + d.Z), Vector3.new(0, -1000, 0), params)
				if not h2 or h2.Instance ~= workspace.Terrain or h2.Material == Enum.Material.Water then
					clear = false
				end
			end
			local paved = ({ Asphalt = true, Pavement = true, Concrete = true, Cobblestone = true, Brick = true, Glacier = true,
				Ice = true, Salt = true })[hit.Material.Name]
			if clear and not paved then
				wantMaterials[hit.Material] = true
				table.insert(spots, { x = x, z = z, material = hit.Material.Name })
			end
		end
	end

	-- BOTTOM
	for index, spot in ipairs(spots) do
		local original = surfaceAt(spot.x, spot.z)
		local floorY = original - DS.DigDepth
		local before = gridAt(spot.x, spot.z, GRID)
		local trail, dug, passed, worst = {}, 0, false, 0
		for blast = 1, BLASTS + RING do
			local x, z = spot.x, spot.z
			if blast > BLASTS then
				local a = (blast - BLASTS) / RING * math.pi * 2
				x, z = x + math.cos(a) * 4, z + math.sin(a) * 4
			end
			local y = surfaceAt(x, z) or original
			local okDig, why = DS.CraterAt(Vector3.new(x, y + 0.5, z), 7, 150, map)
			if okDig then
				dug += 1
			end
			-- The deepest the ground now is under where it was, anywhere on the grid (each point
			-- against its own original height, so a slope can't hide a dig past the floor).
			worst = deepestUnder(spot.x, spot.z, GRID, before)
			if worst > DS.DigDepth + 0.1 then
				passed = true
			end
			if blast <= 6 or blast % 6 == 0 then
				table.insert(trail, string.format("%.1f%s", worst, okDig and "" or ("(" .. tostring(why) .. ")")))
			end
			-- Under the crater burst cap (16 a second).
			task.wait(0.08)
		end
		local under = solidAt(Vector3.new(spot.x, floorY - 1.5, spot.z))
		out("BOTTOM spot %d (%s) at (%.0f, %.0f): %d of %d blasts dug; deepest dig on a 25x25 grid round it, after blasts 1-6 then every 6th: %s",
			index, spot.material, spot.x, spot.z, dug, BLASTS + RING, table.concat(trail, " "))
		out("BOTTOM spot %d: deepest %.2f studs under the ground as built (dig floor %d); terrain solid 1.5 under the floor: %s",
			index, worst, DS.DigDepth, tostring(under))
		-- CLIMB OUT: from the lowest point of the bowl, eight ways out, the steepest 4-stud stretch and
		-- the steepest 8-stud stretch of the ground on each.
		local lowX, lowZ, lowY = spot.x, spot.z, math.huge
		for dx = -6, 6, 2 do
			for dz = -6, 6, 2 do
				local y = surfaceAt(spot.x + dx, spot.z + dz)
				if y and y < lowY then
					lowX, lowZ, lowY = spot.x + dx, spot.z + dz, y
				end
			end
		end
		local ways, worst4, worst8 = {}, 0, 0
		for k = 0, 7 do
			local a = k / 8 * math.pi * 2
			local steep4, steep8 = 0, 0
			local prev, prev8 = lowY, lowY
			for r = 4, 64, 4 do
				local y = surfaceAt(lowX + math.cos(a) * r, lowZ + math.sin(a) * r)
				if y then
					steep4 = math.max(steep4, math.deg(math.atan((y - prev) / 4)))
					if r % 8 == 0 then
						steep8 = math.max(steep8, math.deg(math.atan((y - prev8) / 8)))
						prev8 = y
					end
					prev = y
				end
			end
			worst4, worst8 = math.max(worst4, steep4), math.max(worst8, steep8)
			table.insert(ways, string.format("%.0f/%.0f", steep4, steep8))
		end
		out("CLIMB spot %d: out of the bowl (floor %.1f under the ground) eight ways, steepest 4-stud / 8-stud stretch in degrees: %s; worst %.0f / %.0f",
			index, (original or 0) - lowY, table.concat(ways, " "), worst4, worst8)
		if worst8 > 40 then
			out("PROBLEM spot %d: a crater wall steeper than 40 degrees over 8 studs", index)
		end
		if passed then
			out("PROBLEM spot %d went %.2f studs under the dig floor", index, worst - DS.DigDepth)
		end
		if not under then
			out("PROBLEM spot %d has no solid terrain under its dig floor", index)
		end
	end
	if #spots == 0 then
		out("PROBLEM found no open ground to blast")
	end

	-- REFUSED
	local river = map:FindFirstChild("River")
	local waterSpot = nil
	for _ = 1, 3000 do
		local angle, dist = math.random() * math.pi * 2, math.sqrt(math.random()) * info.radius * 0.9
		local x, z = math.cos(angle) * dist, math.sin(angle) * dist
		local wparams = RaycastParams.new()
		wparams.FilterType = Enum.RaycastFilterType.Include
		wparams.FilterDescendantsInstances = { workspace.Terrain }
		wparams.IgnoreWater = false
		local hit = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), wparams)
		if hit and hit.Material == Enum.Material.Water then
			-- Step out to the bank.
			for d = 2, 40, 2 do
				local bank = workspace:Raycast(Vector3.new(x + d, 400, z), Vector3.new(0, -800, 0), wparams)
				if bank and bank.Material ~= Enum.Material.Water then
					waterSpot = bank.Position
					break
				end
			end
			if waterSpot then
				break
			end
		end
	end
	if waterSpot then
		local okDig, why = DS.CraterAt(waterSpot + Vector3.new(0, 0.5, 0), 7, 150, map)
		out("REFUSED river bank at (%.0f, %.0f): dug %s (%s)", waterSpot.X, waterSpot.Z, tostring(okDig), tostring(why))
		if okDig then
			out("PROBLEM a crater was dug with water in reach")
		end
	else
		out("REFUSED no water found on %s (river model: %s)", MAP_ID, tostring(river ~= nil))
	end
	local road = nil
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "RoadSurface" then
			road = d
			break
		end
	end
	if road then
		local okDig, why = DS.CraterAt(road.Position + Vector3.new(0, road.Size.Y / 2 + 0.5, 0), 7, 150, map)
		out("REFUSED on a road: dug %s (%s)", tostring(okDig), tostring(why))
	end
	local edgeX = math.floor(info.radius * 2.3) / 2 - 3
	local ey = surfaceAt(edgeX, 0) or 0
	local okEdge, whyEdge = DS.CraterAt(Vector3.new(edgeX, ey + 0.5, 0), 7, 150, map)
	out("REFUSED at the ground's edge (x = %.0f): dug %s (%s)", edgeX, tostring(okEdge), tostring(whyEdge))
	if okEdge then
		out("PROBLEM a crater was dug at the map's edge")
	end

	-- RESCUE
	local function dummy(at)
		local model = Instance.new("Model")
		model.Name = "RescueDummy"
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.Anchored = true
		root.CFrame = CFrame.new(at)
		root.Parent = model
		local humanoid = Instance.new("Humanoid")
		humanoid.Parent = model
		model.PrimaryPart = root
		model.Parent = workspace
		return model, root
	end
	for _, case in ipairs({
		{ "under the world", Vector3.new(spots[1] and spots[1].x or 0, -300, spots[1] and spots[1].z or 0), true },
		{ "past the map's edge", Vector3.new(info.radius * 1.6, -200, 0), true },
		{ "on the map", Vector3.new(0, (surfaceAt(0, 0) or 0) + 3, 0), false },
	}) do
		local model, root = dummy(case[2])
		local moved = DS.Rescue(model)
		local p = root.Position
		local ground = surfaceAt(p.X, p.Z)
		out("RESCUE %s: from (%.0f, %.0f, %.0f) %s to (%.0f, %.1f, %.0f), ground there %.1f, speed %.1f",
			case[1], case[2].X, case[2].Y, case[2].Z, moved and "moved" or "left", p.X, p.Y, p.Z, ground or -999,
			root.AssemblyLinearVelocity.Magnitude)
		if moved ~= case[3] then
			out("PROBLEM rescue %s: moved %s, expected %s", case[1], tostring(moved), tostring(case[3]))
		elseif moved and (not ground or p.Y < ground or p.Y > ground + 8) then
			out("PROBLEM rescue %s did not land on the ground (%.1f vs ground %s)", case[1], p.Y, tostring(ground))
		end
		model:Destroy()
	end

	-- FAULT: the floor ignored. Blast one fresh spot 20 times with a copy of the rule that allows 200.
	if spots[1] then
		local x, z = spots[1].x + 40, spots[1].z + 40
		local original = surfaceAt(x, z)
		if original then
			for _ = 1, 20 do
				local y = surfaceAt(x, z) or original
				-- The planted rule: dig a rocket's bowl wherever the ground is, no floor.
				workspace.Terrain:FillBall(Vector3.new(x, y + 2.2, z), 6.4, Enum.Material.Air)
				task.wait()
			end
			local low = lowestNear(x, z, 6)
			local fired = low < original - DS.DigDepth - 0.6
			out("FAULT no dig floor: 20 bowls on one spot went %.1f below the ground (floor %d): %s", original - low, DS.DigDepth,
				fired and "fired" or "DID NOT FIRE")
		end
	end
	out("craters dug this run: %d (cap %d)", DS.GroundState.count, DS.CraterCap)
end)
if not ok then
	out("PROBLEM probe error: %s", tostring(err))
end
out("done")
