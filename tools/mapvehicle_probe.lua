-- Map vehicle probe: the numbers the new map-vehicle work is set against, measured on real
-- generated maps instead of assumed. Run it in the background; it waits on the Studio lock:
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/mapvehicle_probe.lua -WaitSeconds 1800
--
-- Edit mode, no physics. Every physics question (what a car does in the river, ramming, the drive
-- loop itself) needs Run mode and is deliberately NOT here -- an edit-mode "measurement" of a
-- physics behaviour would measure nothing, which is exactly the failure mode the project keeps
-- finding. Those go in a separate Run-mode probe.
--
-- Each section runs in its own `do ... end` and is pcall'd, so one section failing still leaves
-- the rest of the numbers. Every aggregate line prints its SAMPLE COUNT, and every check family
-- carries a PLANTED FAULT that makes it visibly fail, because several "0 findings" results on this
-- project turned out to be measuring nothing.
--
-- What it answers, in order:
--   CENSUS   how many vehicles a map really gets, what they cost in parts, and where they are
--   FOOTING  do parked vehicles sit flat, or does the AlignOrientation hold them level over a bank
--            (MapGenerator parks them 36 studs off the centre line, and the road's flat corridor
--            ends at 20, so every one of them lands in the cut/fill blend)
--   SPREAD   nearest-neighbour spacing, distance from each town, map coverage, and whether the
--            placement loop's road-order bias is real
--   WATER    where the water actually is, what its surface height is, and whether GroundHeightAt
--            returns the water surface or the bed (this decides how a boat gets its float height)
--   SLOPE    what fraction of a map is locked out at claude-0d's measured 20 / 30 / 40 degree
--            climb limits -- i.e. how much ground an off-roader would actually open up
--   ROUTES   road distance vs straight-line distance between every town pair, which is the whole
--            justification for an off-roader, stated as a number instead of an argument
--   STORM    how much of the river is still inside the late circles, which decides whether a
--            river boat is a headline vehicle or a nice-to-have
--
-- Lines start "[MAPVEH]". "PROBLEM" lines are findings; "FAULT" lines are the planted faults
-- proving the check above them can fail.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Stats = game:GetService("Stats")

local modules = ServerScriptService:WaitForChild("Modules")
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")

local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local MapTerrain = require(modules:WaitForChild("MapTerrain"))
local RoadNetwork = require(modules:WaitForChild("RoadNetwork"))
local MatchConfig = require(sharedFolder:WaitForChild("MatchConfig"))

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- The run stops early and says so if memory climbs or the clock runs out, rather than taking
-- Studio down with it (it has died around 3.6 GB building several whole maps).
--
-- Run 1 (18:16 build) measured RotRidge/101 and then stopped: Studio was ALREADY at 2578 MB before
-- the first map, so an absolute 2600 MB ceiling was spent before any work happened. One map cost
-- 189 MB. So the guard is now measured from where this run actually starts, with an absolute cap
-- underneath it as a backstop. Change JOBS per run and work through the maps a few at a time.
-- Run 2 did all five in 45 s and memory plateaued (the build cost 189 MB on the first map, then
-- 79, 68, 65 and -4, with Clear giving back nothing), so the cost is Studio's own caching warming
-- up rather than a leak, and five maps in a run is comfortable.
local JOBS = {
	{ map = "RotRidge", seed = 303 },
	{ map = "TralalaTown", seed = 303 },
	{ map = "PatapimPlains", seed = 303 },
	{ map = "SahurSprings", seed = 303 },
	{ map = "BombardiroBay", seed = 303 },
}

-- How much this run may ADD to whatever Studio was already using, and the hard line underneath.
local MEMORY_HEADROOM_MB = 620
local MEMORY_HARD_CAP_MB = 3300
-- Wall-clock seconds. os.clock() is process CPU time in Roblox, and a map build is nearly all
-- yielding, so run 1's "8 s elapsed" for a whole map was CPU time and the old budget of 1500
-- could never have fired. Measured with os.time() instead.
local TIME_BUDGET = 1500

-- Daylight under a parked vehicle's footprint corner before it reads as floating. Oliver's flat
-- footing rule; footing_probe uses 1.0 for structures and SKIPs vehicles entirely.
local FLOAT = 1.0
-- How far a vehicle may be from a road centre line and still count as "on" that road's verge.
local VERGE_REACH = RoadNetwork.ClaimWidth + 26
-- Coverage question: from a random point on the map, is there a vehicle within a short walk?
local COVER_RADIUS = 250
local COVER_STEP = 60
-- Water census grid, and the slope census grid with its gradient baseline.
local WATER_STEP = 30
local SLOPE_STEP = 60
local SLOPE_BASE = 3
-- claude-0d measured these on its seven vehicles: everything climbs 20 degrees, the Scrambler,
-- Ranger and GT climb 30, nothing climbs 40.
local CLIMB_BANDS = { 20, 30, 40 }
local STORM_TRIALS = 400
local RIVER_STEP = 5
-- Yield this often inside the sampling loops so Studio stays responsive and the run isn't killed.
local YIELD_EVERY = 400

local TAG = "[MAPVEH]"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function out(format, ...)
	if select("#", ...) > 0 then
		print(TAG .. " " .. string.format(format, ...))
	else
		print(TAG .. " " .. format)
	end
end

local solidParams = RaycastParams.new()
solidParams.FilterType = Enum.RaycastFilterType.Include
solidParams.FilterDescendantsInstances = { workspace.Terrain }
solidParams.IgnoreWater = true

local wetParams = RaycastParams.new()
wetParams.FilterType = Enum.RaycastFilterType.Include
wetParams.FilterDescendantsInstances = { workspace.Terrain }
wetParams.IgnoreWater = false

-- Straight down from well above anything a map builds. claude-79's new contract rays from 2000;
-- the old MapGenerator.GroundHeightAt rays from 400, so this is the taller of the two and can't
-- start inside a hill (a ray started inside terrain was one of the fresh-eyes review's findings).
local function terrainAt(x, z, params)
	local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), params)
	if not hit then
		return nil, nil
	end
	return hit.Position.Y, hit.Material
end

local function flatDistance(ax, az, bx, bz)
	local dx, dz = ax - bx, az - bz
	return math.sqrt(dx * dx + dz * dz)
end

-- min / median / mean / max over a list of numbers, and the count, so no aggregate is ever printed
-- without saying how many samples are behind it.
local function stats(list)
	local count = #list
	if count == 0 then
		return { count = 0, min = 0, median = 0, mean = 0, max = 0 }
	end
	local sorted = table.clone(list)
	table.sort(sorted)
	local total = 0
	for _, value in ipairs(sorted) do
		total += value
	end
	return {
		count = count,
		min = sorted[1],
		median = sorted[math.max(1, math.floor((count + 1) / 2))],
		mean = total / count,
		max = sorted[count],
	}
end

-- The footprint corners of a model, in world X/Z, plus the world Y of its underside. The model is
-- held yaw-only by the AlignOrientation, so its bounding box is yaw-aligned and its underside is a
-- horizontal plane -- which is the whole reason a bank shows daylight under it.
local function footprint(model)
	local ok, cframe, size = pcall(function()
		local c, s = model:GetBoundingBox()
		return c, s
	end)
	if not ok or not cframe then
		return nil
	end
	local halfX, halfZ = size.X / 2, size.Z / 2
	local corners = {}
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local point = cframe * CFrame.new(sx * halfX, 0, sz * halfZ)
			table.insert(corners, point.Position)
		end
	end
	return { bottom = cframe.Position.Y - size.Y / 2, corners = corners, size = size, centre = cframe.Position }
end

local function partCount(model)
	local count = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

local startClock = os.time()
local function elapsedSeconds()
	return os.time() - startClock
end
local function outOfTime()
	return elapsedSeconds() > TIME_BUDGET
end

--------------------------------------------------------------------------------
-- One map
--------------------------------------------------------------------------------

-- Collected across every job so the run can end with one line per question.
local roll = {
	census = {},
	daylight = {},
	neighbour = {},
	townGap = {},
	coverage = {},
	waterSurfaces = {},
	groundReturnsWater = { water = 0, bed = 0, other = 0 },
	climbLocked = {},
	routeRatio = {},
	riverInside = {},
	mapParts = {},
	townSites = {},
}

local function measureMap(job, info)
	local map = workspace:FindFirstChild("Map")
	if not map then
		out("PROBLEM %s/%d: no workspace.Map after Build", job.map, job.seed)
		return
	end
	local radius = info.radius
	local label = string.format("%s/%d", job.map, job.seed)

	----------------------------------------------------------------------------
	-- CENSUS and FOOTING
	----------------------------------------------------------------------------
	local positions = {}
	do
		local folder = map:FindFirstChild("Vehicles")
		local models = folder and folder:GetChildren() or {}
		local parts, floating, worst, checked = 0, 0, nil, 0
		local gaps = {}

		for _, model in ipairs(models) do
			parts += partCount(model)
			local chassis = model:FindFirstChild("Chassis")
			if chassis then
				table.insert(positions, chassis.Position)
			end
			local shape = footprint(model)
			if shape then
				checked += 1
				local worstGap = -math.huge
				for _, corner in ipairs(shape.corners) do
					local ground = terrainAt(corner.X, corner.Z, solidParams)
					if ground then
						local gap = shape.bottom - ground
						if gap > worstGap then
							worstGap = gap
						end
					end
				end
				if worstGap > -math.huge then
					table.insert(gaps, worstGap)
					table.insert(roll.daylight, worstGap)
					if worstGap > FLOAT then
						floating += 1
						if not worst or worstGap > worst.gap then
							worst = { gap = worstGap, at = shape.centre }
						end
					end
				end
			end
		end

		local wanted = math.clamp(math.floor(radius / 95), 6, 16)
		table.insert(roll.census, { label = label, built = #models, wanted = wanted, parts = parts })
		local gapStats = stats(gaps)
		out("CENSUS %s: %d vehicles built (formula wants %d), %d parts in all, %.1f parts each on average",
			label, #models, wanted, parts, #models > 0 and parts / #models or 0)
		out("FOOTING %s: %d of %d parked vehicles hang more than %.1f studs clear at a footprint corner; gap min %.2f median %.2f max %.2f over %d measured",
			label, floating, checked, FLOAT, gapStats.min, gapStats.median, gapStats.max, gapStats.count)
		if worst then
			out("PROBLEM %s worst parked vehicle hangs %.2f studs clear at (%.0f, %.0f, %.0f)",
				label, worst.gap, worst.at.X, worst.at.Y, worst.at.Z)
		end

		-- PLANTED FAULT. Run 1's version lifted models[1] and compared the FLEET count, which came
		-- back 4 -> 4 and proved nothing, because the vehicle it happened to lift was already
		-- floating. So this measures the lifted vehicle ITSELF, before and after, where the answer
		-- cannot be swallowed by the rest of the fleet.
		if #models > 0 then
			local victim, victimWas = nil, nil
			-- Prefer one that is NOT already floating, so the verdict flips as well as the number.
			for _, model in ipairs(models) do
				local shape = footprint(model)
				if shape then
					local worstGap = -math.huge
					for _, corner in ipairs(shape.corners) do
						local ground = terrainAt(corner.X, corner.Z, solidParams)
						if ground and shape.bottom - ground > worstGap then
							worstGap = shape.bottom - ground
						end
					end
					if worstGap > -math.huge and (not victim or (victimWas > FLOAT and worstGap <= FLOAT)) then
						victim, victimWas = model, worstGap
					end
				end
			end
			if victim then
				local before = victim:GetPivot()
				victim:PivotTo(before + Vector3.new(0, 4, 0))
				local shape = footprint(victim)
				local after = -math.huge
				for _, corner in ipairs(shape.corners) do
					local ground = terrainAt(corner.X, corner.Z, solidParams)
					if ground and shape.bottom - ground > after then
						after = shape.bottom - ground
					end
				end
				victim:PivotTo(before)
				out("FAULT %s footing: the SAME vehicle measured %.2f studs clear, then %.2f after being lifted 4 studs (want a rise of 4.00; verdict %s -> %s)",
					label, victimWas, after, victimWas > FLOAT and "floating" or "seated", after > FLOAT and "floating" or "seated")
			end
		end
	end

	----------------------------------------------------------------------------
	-- MAPPARTS: what a map costs today, so a vehicle budget is a share of something
	----------------------------------------------------------------------------
	do
		local total, vehicleParts = 0, 0
		local byGroup = {}
		for _, child in ipairs(map:GetChildren()) do
			local count = 0
			for _, descendant in ipairs(child:GetDescendants()) do
				if descendant:IsA("BasePart") then
					count += 1
				end
			end
			if child:IsA("BasePart") then
				count += 1
			end
			total += count
			byGroup[child.Name] = count
			if child.Name == "Vehicles" then
				vehicleParts = count
			end
		end
		table.insert(roll.mapParts, { label = label, total = total, vehicles = vehicleParts })
		-- claude-0d measured its seven at a mean of 307 parts each (313/372/550/341/270/179/126),
		-- so this is what the same fleet costs once the redesign is wired in.
		local projected = #positions * 307
		out("MAPPARTS %s: %d parts in the map, %d of them vehicles (%.1f%%). At claude-0d's measured 307 per vehicle the same fleet becomes %d parts, %.1f%% of a map this size",
			label, total, vehicleParts, total > 0 and vehicleParts / total * 100 or 0,
			projected, total > 0 and projected / (total - vehicleParts + projected) * 100 or 0)
		local biggest, biggestName = 0, "none"
		for name, count in pairs(byGroup) do
			if count > biggest then
				biggest, biggestName = count, name
			end
		end
		out("MAPPARTS %s: largest group is %s at %d parts (%d groups in all)", label, biggestName, biggest, #map:GetChildren())
	end

	----------------------------------------------------------------------------
	-- TOWNSITES: is there actually room to park in a town?
	----------------------------------------------------------------------------
	--
	-- The town tier is the biggest single change I want to make, and it is worth nothing if a town
	-- has no level, clear, car-sized ground left once the buildings, streets and furniture are in.
	-- Rather than replicate MapDecor's street layout (which it owns and may change), this asks the
	-- built world directly: a car-sized box, free of parts, over ground level within LEVEL studs.
	do
		local towns = info.roads and info.roads.towns or {}
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { map:FindFirstChild("Vehicles") or map }
		local CAR = Vector3.new(6.5, 4, 11.5)
		local LEVEL = 0.5
		local STEP = 10
		local REACH = 150

		local free, level, sampled = 0, 0, 0
		local perTown = {}
		local witness = nil
		for _, town in ipairs(towns) do
			local here = 0
			for dx = -REACH, REACH, STEP do
				for dz = -REACH, REACH, STEP do
					local x, z = town.center.X + dx, town.center.Z + dz
					sampled += 1
					local ground = terrainAt(x, z, solidParams)
					if ground then
						local at = CFrame.new(x, ground + CAR.Y / 2 + 0.2, z)
						if #workspace:GetPartBoundsInBox(at, CAR, params) == 0 then
							free += 1
							local low, high = math.huge, -math.huge
							for _, ox in ipairs({ -CAR.X / 2, CAR.X / 2 }) do
								for _, oz in ipairs({ -CAR.Z / 2, CAR.Z / 2 }) do
									local corner = terrainAt(x + ox, z + oz, solidParams)
									if corner then
										low, high = math.min(low, corner), math.max(high, corner)
									end
								end
							end
							if high - low <= LEVEL then
								level += 1
								here += 1
								witness = witness or at
							end
						end
					end
				end
			end
			table.insert(perTown, here)
		end
		local townStats = stats(perTown)
		table.insert(roll.townSites, townStats.min)
		out("TOWNSITES %s: %d of %d sampled spots inside %d studs of a town square are clear of parts, and %d of those are level within %.1f studs -- per town min %d median %d max %d over %d towns",
			label, free, sampled, REACH, level, LEVEL, townStats.min, townStats.median, townStats.max, #towns)
		-- PLANTED FAULT: drop a real part into one of the spots this just called clear and the same
		-- box must come back occupied. Without this, "N clear spots" could be an overlap test that
		-- never finds anything.
		if witness then
			local blocker = Instance.new("Part")
			blocker.Size = Vector3.new(4, 4, 4)
			blocker.CFrame = witness
			blocker.Anchored = true
			blocker.Parent = map
			local nowFound = #workspace:GetPartBoundsInBox(witness, CAR, params)
			blocker:Destroy()
			local afterFound = #workspace:GetPartBoundsInBox(witness, CAR, params)
			out("FAULT %s townsites: a spot measured clear found %d parts once a blocker was dropped in it and %d again after it was removed (want more than 0, then 0)",
				label, nowFound, afterFound)
		else
			out("FAULT %s townsites: no clear spot was found at all, so there was nothing to plant a blocker in -- treat the count above as unproven", label)
		end
	end

	----------------------------------------------------------------------------
	-- SPREAD: spacing, towns, coverage, road-order bias
	----------------------------------------------------------------------------
	do
		local neighbours = {}
		for i = 1, #positions do
			local best = math.huge
			for j = 1, #positions do
				if i ~= j then
					local d = flatDistance(positions[i].X, positions[i].Z, positions[j].X, positions[j].Z)
					if d < best then
						best = d
					end
				end
			end
			if best < math.huge then
				table.insert(neighbours, best)
				table.insert(roll.neighbour, best)
			end
		end
		local nearStats = stats(neighbours)
		out("SPREAD %s: nearest-neighbour min %.0f median %.0f mean %.0f max %.0f studs over %d vehicles",
			label, nearStats.min, nearStats.median, nearStats.mean, nearStats.max, nearStats.count)

		-- PLANTED FAULT: two vehicles 5 studs apart must drag the minimum down to 5.
		do
			local fake = table.clone(positions)
			if #fake > 0 then
				table.insert(fake, fake[1] + Vector3.new(5, 0, 0))
				local best = math.huge
				for i = 1, #fake do
					for j = i + 1, #fake do
						local d = flatDistance(fake[i].X, fake[i].Z, fake[j].X, fake[j].Z)
						if d < best then
							best = d
						end
					end
				end
				out("FAULT %s spread: a planted pair 5 studs apart gives minimum %.1f (want 5.0), %d positions",
					label, best, #fake)
			end
		end

		-- How far a town square is from the nearest drivable vehicle. Towns are where players land
		-- and fight, and today nothing is parked in one.
		local towns = info.roads and info.roads.towns or {}
		local townGaps = {}
		for _, town in ipairs(towns) do
			local best = math.huge
			for _, position in ipairs(positions) do
				local d = flatDistance(town.center.X, town.center.Z, position.X, position.Z)
				if d < best then
					best = d
				end
			end
			if best < math.huge then
				table.insert(townGaps, best)
				table.insert(roll.townGap, best)
			end
		end
		local townStats = stats(townGaps)
		out("TOWNS %s: %d towns, distance from a town square to the nearest vehicle min %.0f median %.0f max %.0f studs",
			label, #towns, townStats.min, townStats.median, townStats.max)

		-- Coverage: from a point on the map, is a vehicle within a short walk?
		local covered, sampled = 0, 0
		for x = -radius, radius, COVER_STEP do
			for z = -radius, radius, COVER_STEP do
				if flatDistance(0, 0, x, z) <= radius then
					sampled += 1
					for _, position in ipairs(positions) do
						if flatDistance(x, z, position.X, position.Z) <= COVER_RADIUS then
							covered += 1
							break
						end
					end
				end
			end
		end
		local fraction = sampled > 0 and covered / sampled or 0
		table.insert(roll.coverage, fraction)
		out("COVERAGE %s: %.1f%% of the map is within %d studs of a vehicle (%d of %d grid points, %d-stud grid)",
			label, fraction * 100, COVER_RADIUS, covered, sampled, COVER_STEP)
		out("FAULT %s coverage: with no vehicles the same grid gives 0.0%% by construction (%d points)", label, sampled)

		-- Road-order bias: the placement loop walks roads.edges in plan order and breaks at its
		-- quota, and RoadNetwork adds roads nearest-town-pair-first.
		local edges = info.roads and info.roads.edges or {}
		local eligible, used, lastUsed = 0, 0, 0
		for index, edge in ipairs(edges) do
			if edge.length > 90 then
				eligible += 1
				local hit = false
				for _, position in ipairs(positions) do
					local along = edge.dir
					local delta = position - edge.from
					local t = math.clamp(delta.X * along.X + delta.Z * along.Z, 0, edge.length)
					local on = edge.from + along * t
					if flatDistance(on.X, on.Z, position.X, position.Z) <= VERGE_REACH then
						hit = true
						break
					end
				end
				if hit then
					used += 1
					lastUsed = index
				end
			end
		end
		out("BIAS %s: %d of %d eligible road edges got a vehicle; the last one used is edge %d of %d in plan order",
			label, used, eligible, lastUsed, #edges)
	end

	----------------------------------------------------------------------------
	-- WATER: where it is, what height its surface is, and what GroundHeightAt says there
	----------------------------------------------------------------------------
	do
		local waterPoints, surfaces = {}, {}
		local sampled, steps = 0, 0
		for x = -radius, radius, WATER_STEP do
			for z = -radius, radius, WATER_STEP do
				if flatDistance(0, 0, x, z) <= radius * 1.2 then
					sampled += 1
					local wet, material = terrainAt(x, z, wetParams)
					if wet and material == Enum.Material.Water then
						table.insert(waterPoints, Vector3.new(x, wet, z))
						table.insert(surfaces, wet)
					end
					steps += 1
					if steps % YIELD_EVERY == 0 then
						task.wait()
					end
				end
			end
		end
		local surfaceStats = stats(surfaces)
		out("WATER %s: %d of %d sampled points are water (%.2f%%), surface height min %.2f median %.2f max %.2f",
			label, #waterPoints, sampled, sampled > 0 and #waterPoints / sampled * 100 or 0,
			surfaceStats.min, surfaceStats.median, surfaceStats.max)
		for _, height in ipairs(surfaces) do
			table.insert(roll.waterSurfaces, height)
		end

		-- The question that decides how a boat gets its float height: over water, does the
		-- GroundHeightAt every map feature already uses hand back the SURFACE or the BED?
		local usesTerrainModule = type(MapTerrain.GroundHeightAt) == "function"
		local matchedSurface, matchedBed, neither = 0, 0, 0
		local checkedWater = 0
		for index = 1, #waterPoints, math.max(1, math.floor(#waterPoints / 60)) do
			local point = waterPoints[index]
			local bed = terrainAt(point.X, point.Z, solidParams)
			local reported
			if usesTerrainModule then
				reported = MapTerrain.GroundHeightAt(point.X, point.Z)
			else
				reported = MapGenerator.GroundHeightAt(point.X, point.Z)
			end
			if reported then
				checkedWater += 1
				if math.abs(reported - point.Y) < 0.2 then
					matchedSurface += 1
				elseif bed and math.abs(reported - bed) < 0.2 then
					matchedBed += 1
				else
					neither += 1
				end
			end
		end
		roll.groundReturnsWater.water += matchedSurface
		roll.groundReturnsWater.bed += matchedBed
		roll.groundReturnsWater.other += neither
		out("GROUNDAT %s: over water, %s returned the SURFACE %d times, the BED %d times, neither %d, over %d samples (source: %s)",
			label, usesTerrainModule and "MapTerrain.GroundHeightAt" or "MapGenerator.GroundHeightAt",
			matchedSurface, matchedBed, neither, checkedWater,
			usesTerrainModule and "MapTerrain (new contract)" or "MapGenerator (old contract, MapTerrain.GroundHeightAt absent)")

		-- PLANTED FAULT: on LAND the two rays must agree. Offsetting half the samples by 3 studs
		-- has to show up as exactly that many mismatches, or the comparison above proves nothing.
		do
			local agree, disagree, planted, checked = 0, 0, 0, 0
			local index = 0
			for x = -radius * 0.5, radius * 0.5, WATER_STEP * 8 do
				for z = -radius * 0.5, radius * 0.5, WATER_STEP * 8 do
					local wet, material = terrainAt(x, z, wetParams)
					local dry = terrainAt(x, z, solidParams)
					if wet and dry and material ~= Enum.Material.Water and checked < 24 then
						checked += 1
						index += 1
						local compare = wet
						if index % 2 == 0 then
							compare += 3
							planted += 1
						end
						if math.abs(compare - dry) < 0.2 then
							agree += 1
						else
							disagree += 1
						end
					end
				end
			end
			out("FAULT %s water: on land, %d of %d samples were offset by 3 studs on purpose and %d came back as mismatches (want them equal), %d agreed",
				label, planted, checked, disagree, agree)
		end
	end

	----------------------------------------------------------------------------
	-- SLOPE: how much of the map a 20 / 30 / 40 degree climb limit locks out
	----------------------------------------------------------------------------
	do
		local slopes = {}
		local steps = 0
		for x = -radius, radius, SLOPE_STEP do
			for z = -radius, radius, SLOPE_STEP do
				if flatDistance(0, 0, x, z) <= radius then
					local east = terrainAt(x + SLOPE_BASE, z, solidParams)
					local west = terrainAt(x - SLOPE_BASE, z, solidParams)
					local north = terrainAt(x, z + SLOPE_BASE, solidParams)
					local south = terrainAt(x, z - SLOPE_BASE, solidParams)
					if east and west and north and south then
						local gx = (east - west) / (2 * SLOPE_BASE)
						local gz = (north - south) / (2 * SLOPE_BASE)
						table.insert(slopes, math.deg(math.atan(math.sqrt(gx * gx + gz * gz))))
					end
					steps += 1
					if steps % YIELD_EVERY == 0 then
						task.wait()
					end
				end
			end
		end
		local locked = {}
		for _, band in ipairs(CLIMB_BANDS) do
			local over = 0
			for _, slope in ipairs(slopes) do
				if slope > band then
					over += 1
				end
			end
			locked[band] = #slopes > 0 and over / #slopes or 0
		end
		table.insert(roll.climbLocked, locked)
		local slopeStats = stats(slopes)
		out("SLOPE %s: median %.1f deg, mean %.1f, max %.1f over %d grid points (%d-stud grid, %d-stud baseline)",
			label, slopeStats.median, slopeStats.mean, slopeStats.max, slopeStats.count, SLOPE_STEP, SLOPE_BASE)
		out("CLIMB %s: %.1f%% of the map is steeper than 20 deg, %.1f%% steeper than 30, %.1f%% steeper than 40 (%d samples)",
			label, locked[20] * 100, locked[30] * 100, locked[40] * 100, #slopes)

		-- PLANTED FAULT: a synthetic 45 degree sample set must land wholly in the steepest band.
		do
			local fake = { 45, 45, 45, 1, 1 }
			local over = 0
			for _, slope in ipairs(fake) do
				if slope > 40 then
					over += 1
				end
			end
			out("FAULT %s slope: a planted set of 5 (three at 45 deg) reports %d over 40 deg (want 3)", label, over)
		end
	end

	----------------------------------------------------------------------------
	-- ROUTES: road distance vs straight line between town pairs -- the off-roader's case
	----------------------------------------------------------------------------
	do
		local roads = info.roads
		local towns = roads and roads.towns or {}
		local ratios, pairsChecked, unreachable = {}, 0, 0
		for i = 1, #towns do
			for j = i + 1, #towns do
				local straight = flatDistance(towns[i].center.X, towns[i].center.Z, towns[j].center.X, towns[j].center.Z)
				local ok, byRoad = pcall(function()
					return roads:_networkDistance(i, j)
				end)
				if ok and byRoad and byRoad < math.huge and straight > 1 then
					pairsChecked += 1
					table.insert(ratios, byRoad / straight)
					table.insert(roll.routeRatio, byRoad / straight)
				else
					unreachable += 1
				end
			end
		end
		local ratioStats = stats(ratios)
		out("ROUTES %s: road distance / straight line between town pairs min %.2f median %.2f mean %.2f max %.2f over %d pairs (%d unreachable)",
			label, ratioStats.min, ratioStats.median, ratioStats.mean, ratioStats.max, ratioStats.count, unreachable)
	end

	----------------------------------------------------------------------------
	-- STORM: is the river still inside the late circles?
	----------------------------------------------------------------------------
	do
		local river = info.river
		if not river or not river.points or #river.points < 2 then
			out("STORM %s: no river on this map, so a river boat would spawn none here", label)
			table.insert(roll.riverInside, { phase2 = 0, phase3 = 0, noRiver = true })
		else
			-- The river as evenly spaced samples, so "how much is inside" is a length, not a guess.
			local samples = {}
			for index = 1, #river.points - 1 do
				local a, b = river.points[index], river.points[index + 1]
				local span = flatDistance(a.X, a.Z, b.X, b.Z)
				local count = math.max(1, math.floor(span / RIVER_STEP))
				for step = 0, count - 1 do
					table.insert(samples, a:Lerp(b, step / count))
				end
			end

			-- StormService.pickNextCenter, replayed with our own Random so the probe takes no
			-- global roll and can't shift the map's own stream.
			local rng = Random.new(job.seed * 7919 + 13)
			local function walk(stopAfter)
				local centre, currentRadius = Vector3.zero, radius
				for phaseIndex, phase in ipairs(MatchConfig.StormPhases) do
					local nextRadius = radius * phase.radiusScale
					local drift = math.max(0, currentRadius - nextRadius) * 0.55
					local angle = rng:NextNumber() * math.pi * 2
					local distance = math.sqrt(rng:NextNumber()) * drift
					centre = centre + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
					currentRadius = nextRadius
					if phaseIndex == stopAfter then
						break
					end
				end
				return centre, currentRadius
			end

			local function fractionInside(stopAfter)
				local total, anyTrials = 0, 0
				local withAny = 0
				for _ = 1, STORM_TRIALS do
					local centre, currentRadius = walk(stopAfter)
					local inside = 0
					for _, point in ipairs(samples) do
						if flatDistance(point.X, point.Z, centre.X, centre.Z) <= currentRadius then
							inside += 1
						end
					end
					total += inside / #samples
					anyTrials += 1
					if inside > 0 then
						withAny += 1
					end
				end
				return total / anyTrials, withAny / anyTrials
			end

			local mean2, any2 = fractionInside(2)
			local mean3, any3 = fractionInside(3)
			table.insert(roll.riverInside, { phase2 = mean2, phase3 = mean3 })
			out("STORM %s: river %d samples (%d studs of water). Phase 2 circle (%.0f%% radius): %.1f%% of the river inside on average, some river in %.0f%% of %d trials",
				label, #samples, #samples * RIVER_STEP, MatchConfig.StormPhases[2].radiusScale * 100,
				mean2 * 100, any2 * 100, STORM_TRIALS)
			out("STORM %s: phase 3 circle (%.0f%% radius): %.1f%% of the river inside on average, some river in %.0f%% of %d trials",
				label, MatchConfig.StormPhases[3].radiusScale * 100, mean3 * 100, any3 * 100, STORM_TRIALS)

			-- PLANTED FAULT: a river forced to the origin must be inside every circle; one forced
			-- far outside the map must be inside none.
			do
				local centre, currentRadius = walk(3)
				local atOrigin = flatDistance(0, 0, centre.X, centre.Z) <= currentRadius and 1 or 0
				local farAway = flatDistance(radius * 9, 0, centre.X, centre.Z) <= currentRadius and 1 or 0
				out("FAULT %s storm: a point at the origin reads inside=%d (want 1), a point at 9x the radius reads inside=%d (want 0)",
					label, atOrigin, farAway)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

local startMemory = Stats:GetTotalMemoryUsageMb()
out("START %d jobs. Studio is already using %.0f MB, so this run stops at %.0f MB (start + %d headroom) or %d MB hard, and after %d s. Edit mode: no physics measured here.",
	#JOBS, startMemory, math.min(startMemory + MEMORY_HEADROOM_MB, MEMORY_HARD_CAP_MB),
	MEMORY_HEADROOM_MB, MEMORY_HARD_CAP_MB, TIME_BUDGET)
out("CONTRACT MapTerrain.GroundHeightAt is %s in this tree; MapGenerator.GroundHeightAt is %s",
	type(MapTerrain.GroundHeightAt) == "function" and "PRESENT" or "ABSENT",
	type(MapGenerator.GroundHeightAt) == "function" and "present" or "ABSENT")

-- Half of the car-in-the-river question needs no physics at all, so it is answered here rather
-- than waiting for a Run-mode probe: VehicleService decides it is "grounded" with
-- workspace:Raycast and a plain RaycastParams, whose IgnoreWater DEFAULTS TO FALSE -- i.e. water
-- is hit. If that is so, a car over the river thinks it has something to push against and drives.
-- Measured on an isolated rig cut to the real river's profile (bed surface -7, water surface -1),
-- far from where any map is built, and cleared up afterwards. Buoyancy is the other half and does
-- need Run mode.
do
	local ok, err = pcall(function()
		local cx, cz = 14000, 14000
		local terrain = workspace.Terrain
		terrain:FillBlock(CFrame.new(cx, -30, cz), Vector3.new(160, 42, 160), Enum.Material.Ground)
		terrain:FillBlock(CFrame.new(cx, -4, cz), Vector3.new(120, 6, 120), Enum.Material.Water)
		task.wait(0.5)

		-- Exactly the params VehicleService builds for its grounded check: an Exclude filter and
		-- everything else left at its default.
		local driveParams = RaycastParams.new()
		driveParams.FilterType = Enum.RaycastFilterType.Exclude
		driveParams.FilterDescendantsInstances = {}

		local origin = Vector3.new(cx, 50, cz)
		local down = Vector3.new(0, -120, 0)
		local asDrive = workspace:Raycast(origin, down, driveParams)
		local asWet = workspace:Raycast(origin, down, wetParams)
		local asDry = workspace:Raycast(origin, down, solidParams)

		out("WATERRAY grounded check over open water: %s%s",
			asDrive and string.format("HIT at y=%.2f, material %s", asDrive.Position.Y, asDrive.Material.Name) or "no hit",
			asDrive and asDrive.Material == Enum.Material.Water
				and "  -> a vehicle over the river reads as GROUNDED and its drive stays on" or "")
		out("WATERRAY same column: IgnoreWater=false gives %s, IgnoreWater=true gives %s (the bed)",
			asWet and string.format("y=%.2f %s", asWet.Position.Y, asWet.Material.Name) or "no hit",
			asDry and string.format("y=%.2f %s", asDry.Position.Y, asDry.Material.Name) or "no hit")
		out("WATERRAY built to the river's own profile: water surface wanted -1.00, measured %s; bed wanted -7.00, measured %s",
			asWet and string.format("%.2f", asWet.Position.Y) or "none",
			asDry and string.format("%.2f", asDry.Position.Y) or "none")

		-- PLANTED FAULT: the same three rays over empty space must all miss, or a "hit" above
		-- proves nothing about water.
		local emptyOrigin = Vector3.new(cx + 600, 50, cz + 600)
		local missDrive = workspace:Raycast(emptyOrigin, down, driveParams)
		local missWet = workspace:Raycast(emptyOrigin, down, wetParams)
		out("FAULT waterray: over empty ground 600 studs away the same rays give %s / %s (want no hit / no hit)",
			missDrive and "HIT" or "no hit", missWet and "HIT" or "no hit")

		terrain:FillBlock(CFrame.new(cx, -20, cz), Vector3.new(200, 90, 200), Enum.Material.Air)
	end)
	if not ok then
		out("PROBLEM waterray section failed: %s", tostring(err))
	end
end

local budget = math.min(startMemory + MEMORY_HEADROOM_MB, MEMORY_HARD_CAP_MB)
local completed = 0
for index, job in ipairs(JOBS) do
	local memory = Stats:GetTotalMemoryUsageMb()
	if memory > budget then
		out("STOP after %d of %d jobs: memory %.0f MB is over this run's %.0f MB budget. Remaining maps need another run.",
			completed, #JOBS, memory, budget)
		break
	end
	if outOfTime() then
		out("STOP after %d of %d jobs: %d s used, over the %d s budget", completed, #JOBS, elapsedSeconds(), TIME_BUDGET)
		break
	end

	out("---- job %d/%d %s seed %d, memory %.0f MB of %.0f, %d s elapsed ----",
		index, #JOBS, job.map, job.seed, memory, budget, elapsedSeconds())
	math.randomseed(job.seed)
	local built, info = pcall(MapGenerator.Build, job.map)
	local afterBuild = Stats:GetTotalMemoryUsageMb()
	if not built then
		out("PROBLEM %s/%d: Build failed: %s", job.map, job.seed, tostring(info))
	else
		task.wait(1.5)
		local measured, err = pcall(measureMap, job, info)
		if not measured then
			out("PROBLEM %s/%d: measurement failed: %s", job.map, job.seed, tostring(err))
		end
		completed += 1
	end
	MapGenerator.Clear()
	-- Breathing room for the collector: run 1 kept 189 MB per map after Clear, and whether that is
	-- garbage waiting to be swept or genuinely held decides how many maps fit in one run, so the
	-- number is printed rather than assumed.
	for _ = 1, 8 do
		task.wait()
	end
	local afterClear = Stats:GetTotalMemoryUsageMb()
	out("MEMORY %s/%d: %.0f MB before, %.0f after the build, %.0f after Clear -- the build cost %.0f and Clear gave back %.0f",
		job.map, job.seed, memory, afterBuild, afterClear, afterBuild - memory, afterBuild - afterClear)
end

--------------------------------------------------------------------------------
-- One line per question, across every map measured
--------------------------------------------------------------------------------

do
	local built, wanted, parts = 0, 0, 0
	for _, entry in ipairs(roll.census) do
		built += entry.built
		wanted += entry.wanted
		parts += entry.parts
	end
	out("SUMMARY census: %d maps measured, %d vehicles built against %d wanted, %d vehicle parts in all (%.0f per vehicle, %.0f per map)",
		#roll.census, built, wanted, parts, built > 0 and parts / built or 0, #roll.census > 0 and parts / #roll.census or 0)

	local dayStats = stats(roll.daylight)
	local floatingCount = 0
	for _, gap in ipairs(roll.daylight) do
		if gap > FLOAT then
			floatingCount += 1
		end
	end
	out("SUMMARY footing: %d of %d parked vehicles across every map hang more than %.1f studs clear at a corner (median gap %.2f, worst %.2f)",
		floatingCount, dayStats.count, FLOAT, dayStats.median, dayStats.max)

	local nearStats = stats(roll.neighbour)
	local townStats = stats(roll.townGap)
	out("SUMMARY spread: nearest-neighbour median %.0f studs (%d samples); town square to nearest vehicle median %.0f, worst %.0f (%d towns)",
		nearStats.median, nearStats.count, townStats.median, townStats.max, townStats.count)

	local coverStats = stats(roll.coverage)
	out("SUMMARY coverage: %.1f%% of map area within %d studs of a vehicle on average (%d maps, worst %.1f%%)",
		coverStats.mean * 100, COVER_RADIUS, coverStats.count, coverStats.min * 100)

	local waterStats = stats(roll.waterSurfaces)
	local reported = roll.groundReturnsWater
	out("SUMMARY water: %d water samples, surface heights min %.2f median %.2f max %.2f; over water GroundHeightAt gave the surface %d times, the bed %d, neither %d",
		waterStats.count, waterStats.min, waterStats.median, waterStats.max, reported.water, reported.bed, reported.other)

	local at20, at30, at40, bands = 0, 0, 0, 0
	for _, locked in ipairs(roll.climbLocked) do
		at20 += locked[20]
		at30 += locked[30]
		at40 += locked[40]
		bands += 1
	end
	if bands > 0 then
		out("SUMMARY slope: on average %.1f%% of a map is steeper than 20 deg, %.1f%% steeper than 30, %.1f%% steeper than 40 (%d maps)",
			at20 / bands * 100, at30 / bands * 100, at40 / bands * 100, bands)
	end

	local routeStats = stats(roll.routeRatio)
	out("SUMMARY routes: road distance is %.2fx the straight line between towns on average (median %.2f, worst %.2f, %d town pairs)",
		routeStats.mean, routeStats.median, routeStats.max, routeStats.count)

	local phase2, phase3, rivers, dry = 0, 0, 0, 0
	for _, entry in ipairs(roll.riverInside) do
		if entry.noRiver then
			dry += 1
		else
			phase2 += entry.phase2
			phase3 += entry.phase3
			rivers += 1
		end
	end
	if rivers > 0 then
		out("SUMMARY storm: %d of %d maps have a river; of those, %.1f%% of the river is inside the phase 2 circle and %.1f%% inside phase 3 on average",
			rivers, rivers + dry, phase2 / rivers * 100, phase3 / rivers * 100)
	else
		out("SUMMARY storm: no river on any map measured (%d maps)", dry)
	end
	do
		local totalParts, vehParts, maps = 0, 0, 0
		for _, entry in ipairs(roll.mapParts) do
			totalParts += entry.total
			vehParts += entry.vehicles
			maps += 1
		end
		if maps > 0 then
			local built = 0
			for _, entry in ipairs(roll.census) do
				built += entry.built
			end
			local projected = built * 307
			out("SUMMARY mapparts: %d parts per map on average, %d of them vehicles (%.1f%%). With claude-0d's 307-part vehicles the fleet becomes %d per map, taking vehicles from %.1f%% to %.1f%% of a map",
				totalParts / maps, vehParts / maps, vehParts / math.max(1, totalParts) * 100,
				projected / maps, vehParts / math.max(1, totalParts) * 100,
				projected / math.max(1, totalParts - vehParts + projected) * 100)
		end
		local siteStats = stats(roll.townSites)
		if siteStats.count > 0 then
			out("SUMMARY townsites: the emptiest town on each map had min %d, median %d, max %d level car-sized spots free (%d maps) -- the town tier is feasible if the minimum is comfortably above what it wants to place",
				siteStats.min, siteStats.median, siteStats.max, siteStats.count)
		end
	end

	out("SUMMARY done: %d of %d jobs completed in %.0f s, memory %.0f MB at the end",
		completed, #JOBS, elapsedSeconds(), Stats:GetTotalMemoryUsageMb())
end
