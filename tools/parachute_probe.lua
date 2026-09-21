-- Parachute probe, for tools/runtest.ps1 (run it in the background: it waits on the Studio lock):
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/parachute_probe.lua [-PlaceFile <rbxlx>]
--
-- Builds every canopy in Shared/ParachuteModels and measures what matters about it. Anything that
-- fails is printed as "[Parachute] FAIL ..."; the last line is a summary.
--
--   see-through   At the worn scale (3), rays on a 0.05-stud grid from below, above, the front, the
--                 back and both sides, and a fan from the pilot's eye. Only the canopy blocks them
--                 (the lines, straps and harness bar don't count). A miss with hits all round it is a
--                 HOLE. A narrow gap open to the edge is a SLIT: the misses a 0.4-stud morphological
--                 closing fills in, grouped, where a group is long and thin. Holes fail; slits are
--                 listed with where they are, to judge against the renders.
--   z-fighting    What ZFight.Fix had to move inside Build, and ZFight.Scan afterwards, at scales 3
--                 and 1. Both should be zero: the designs keep their faces apart at the source.
--   attached      Every part reaches the harness bar through parts that overlap (GetPartsInPart).
--   materials     No Neon and no transparency on any part.
--   budget        At most 110 parts.
--   envelope      The canopy's size next to the default Rot Glider's at scale 3, and the lowest
--                 canopy part near the head, which must stay above it.
--   fallback      Build(nil) and Build of an unknown id both give the default Rot Glider.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ParachuteModels = require(Shared:WaitForChild("ParachuteModels"))
local ZFight = require(Shared:WaitForChild("ZFight"))

-- Set to a design id to probe just that one.
local ONLY = nil

local WORN = ParachuteModels.WornScale
local SPACING = 0.05
local CLOSE_STUDS = 0.4
local SLIT_LENGTH = 0.45
local SLIT_WIDTH = 0.3
local BUDGET = 110
-- The bar hangs 1.4 studs over the head's centre and the head is 1.2 tall, so its top is 0.8
-- under the bar. Canopy parts within this far of the middle must stay above HEAD_CLEAR.
local HEAD_HALF_WIDTH = 1.5
local HEAD_CLEAR = -0.6
local HARNESS = { Body = true, Strap = true, Line = true, Riser = true }

local failures = 0
local function out(format, ...)
	print("[Parachute] " .. string.format(format, ...))
end
local function fail(format, ...)
	failures += 1
	out("FAIL " .. format, ...)
end

local stage = Instance.new("Folder")
stage.Name = "ParachuteProbe"
stage.Parent = workspace
local SPOT = CFrame.new(0, 3000, -4000)

local function partsOf(model)
	local list = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(list, part)
		end
	end
	return list
end

local function skinOf(model)
	local list = {}
	for _, part in ipairs(partsOf(model)) do
		if not HARNESS[part.Name] then
			table.insert(list, part)
		end
	end
	return list
end

-- The eight corners of a part's box.
local function corners(part)
	local list = {}
	local half = part.Size / 2
	for _, x in ipairs({ -1, 1 }) do
		for _, y in ipairs({ -1, 1 }) do
			for _, z in ipairs({ -1, 1 }) do
				table.insert(list, part.CFrame * Vector3.new(half.X * x, half.Y * y, half.Z * z))
			end
		end
	end
	return list
end

-- Extent of `parts` along `axis`, from `origin`.
local function extent(parts, origin, axis)
	local low, high = math.huge, -math.huge
	for _, part in ipairs(parts) do
		for _, corner in ipairs(corners(part)) do
			local along = (corner - origin):Dot(axis)
			low = math.min(low, along)
			high = math.max(high, along)
		end
	end
	return low, high
end

--------------------------------------------------------------------------------
-- Rasters
--------------------------------------------------------------------------------

local function index(nu, u, v)
	return (v - 1) * nu + u
end

-- Connected groups (4-way) of the cells where `inside(i)` holds.
local function components(nu, nv, inside)
	local seen = table.create(nu * nv, false)
	local groups = {}
	for start = 1, nu * nv do
		if not seen[start] and inside(start) then
			local group = { count = 0, uMin = math.huge, uMax = -math.huge, vMin = math.huge, vMax = -math.huge }
			local stack = { start }
			seen[start] = true
			while #stack > 0 do
				local i = table.remove(stack)
				local u, v = (i - 1) % nu + 1, (i - 1) // nu + 1
				group.count += 1
				group.uMin, group.uMax = math.min(group.uMin, u), math.max(group.uMax, u)
				group.vMin, group.vMax = math.min(group.vMin, v), math.max(group.vMax, v)
				for _, step in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
					local nu2, nv2 = u + step[1], v + step[2]
					if nu2 >= 1 and nu2 <= nu and nv2 >= 1 and nv2 <= nv then
						local j = index(nu, nu2, nv2)
						if not seen[j] and inside(j) then
							seen[j] = true
							table.insert(stack, j)
						end
					end
				end
			end
			table.insert(groups, group)
		end
	end
	return groups
end

-- Sum of `mask` over any rectangle, from a summed-area table.
local function summed(mask, nu, nv)
	local width = nu + 1
	local table_ = table.create((nu + 1) * (nv + 1), 0)
	for v = 1, nv do
		local row = 0
		for u = 1, nu do
			row += mask[index(nu, u, v)]
			table_[v * width + u + 1] = row + table_[(v - 1) * width + u + 1]
		end
	end
	return function(u0, v0, u1, v1)
		u0, v0 = math.max(u0, 1), math.max(v0, 1)
		u1, v1 = math.min(u1, nu), math.min(v1, nv)
		if u0 > u1 or v0 > v1 then
			return 0, 0
		end
		local area = (u1 - u0 + 1) * (v1 - v0 + 1)
		local sum = table_[v1 * width + u1 + 1] - table_[v1 * width + u0] - table_[(v0 - 1) * width + u1 + 1] + table_[(v0 - 1) * width + u0]
		return sum, area
	end
end

-- Holes and slits in a grid of hits (1) and misses (0). `place(u, v)` names a cell for the report.
local function inspect(label, grid, nu, nv, cellStuds, place)
	local hits = 0
	for i = 1, nu * nv do
		hits += grid[i]
	end

	-- Misses reachable from the border are outside; any others are holes.
	local outside = table.create(nu * nv, false)
	local stack = {}
	local function push(u, v)
		local i = index(nu, u, v)
		if grid[i] == 0 and not outside[i] then
			outside[i] = true
			table.insert(stack, i)
		end
	end
	for u = 1, nu do
		push(u, 1)
		push(u, nv)
	end
	for v = 1, nv do
		push(1, v)
		push(nu, v)
	end
	while #stack > 0 do
		local i = table.remove(stack)
		local u, v = (i - 1) % nu + 1, (i - 1) // nu + 1
		if u > 1 then
			push(u - 1, v)
		end
		if u < nu then
			push(u + 1, v)
		end
		if v > 1 then
			push(u, v - 1)
		end
		if v < nv then
			push(u, v + 1)
		end
	end
	local holes = components(nu, nv, function(i)
		return grid[i] == 0 and not outside[i]
	end)

	-- Closing: dilate the hits, then erode the result, both by a square of CLOSE radius.
	local radius = math.max(1, math.floor(CLOSE_STUDS / cellStuds + 0.5))
	local hitSum = summed(grid, nu, nv)
	local dilated = table.create(nu * nv, 0)
	for v = 1, nv do
		for u = 1, nu do
			if hitSum(u - radius, v - radius, u + radius, v + radius) > 0 then
				dilated[index(nu, u, v)] = 1
			end
		end
	end
	local dilatedSum = summed(dilated, nu, nv)
	local filled = table.create(nu * nv, false)
	for v = 1, nv do
		for u = 1, nu do
			local i = index(nu, u, v)
			if grid[i] == 0 then
				local sum, area = dilatedSum(u - radius, v - radius, u + radius, v + radius)
				filled[i] = sum == area and area > 0
			end
		end
	end
	local slits = {}
	for _, group in ipairs(components(nu, nv, function(i)
		return filled[i]
	end)) do
		local long = math.max(group.uMax - group.uMin, group.vMax - group.vMin) + 1
		local width = group.count / long
		if long * cellStuds >= SLIT_LENGTH and width * cellStuds <= SLIT_WIDTH then
			table.insert(slits, group)
		end
	end

	local line = string.format("%s: %d rays, %d hit, %d holes, %d slits", label, nu * nv, hits, #holes, #slits)
	if hits == 0 then
		fail("%s — nothing was hit (is the canopy there?)", line)
	elseif #holes > 0 then
		table.sort(holes, function(a, b)
			return a.count > b.count
		end)
		local where = {}
		for n = 1, math.min(4, #holes) do
			local hole = holes[n]
			table.insert(where, string.format("%d cells at %s", hole.count, place((hole.uMin + hole.uMax) / 2, (hole.vMin + hole.vMax) / 2)))
		end
		fail("%s — holes: %s", line, table.concat(where, "; "))
	else
		out("  %s", line)
	end
	table.sort(slits, function(a, b)
		return a.count > b.count
	end)
	for n = 1, math.min(6, #slits) do
		local slit = slits[n]
		local long = math.max(slit.uMax - slit.uMin, slit.vMax - slit.vMin) + 1
		out("    slit? %s: %.2f long, %.2f wide at %s", label, long * cellStuds, slit.count / long * cellStuds,
			place((slit.uMin + slit.uMax) / 2, (slit.vMin + slit.vMax) / 2))
	end
	return #holes, #slits
end

local function includeParams(parts)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = parts
	return params
end

local rayCount = 0

-- Parallel rays along `direction` (a unit vector in the pivot's frame) over the canopy's shadow.
local function orthographic(label, pivot, skin, direction, uAxis, vAxis)
	local params = includeParams(skin)
	local worldDir = pivot:VectorToWorldSpace(direction)
	local worldU = pivot:VectorToWorldSpace(uAxis)
	local worldV = pivot:VectorToWorldSpace(vAxis)
	local origin = pivot.Position
	local uLow, uHigh = extent(skin, origin, worldU)
	local vLow, vHigh = extent(skin, origin, worldV)
	local dLow, dHigh = extent(skin, origin, worldDir)
	local margin = math.floor(CLOSE_STUDS / SPACING) + 3
	local nu = math.ceil((uHigh - uLow) / SPACING) + 2 * margin
	local nv = math.ceil((vHigh - vLow) / SPACING) + 2 * margin
	local u0 = uLow - margin * SPACING
	local v0 = vLow - margin * SPACING
	local length = dHigh - dLow + 4
	local grid = table.create(nu * nv, 0)
	for v = 1, nv do
		local along = worldV * (v0 + (v - 0.5) * SPACING) + worldDir * (dLow - 2)
		for u = 1, nu do
			local from = origin + along + worldU * (u0 + (u - 0.5) * SPACING)
			if workspace:Raycast(from, worldDir * length, params) then
				grid[index(nu, u, v)] = 1
			end
		end
		rayCount += nu
		if v % 25 == 0 then
			task.wait()
		end
	end
	return inspect(label, grid, nu, nv, SPACING, function(u, v)
		return string.format("(%.2f, %.2f) along %s/%s", u0 + u * SPACING, v0 + v * SPACING, tostring(uAxis), tostring(vAxis))
	end)
end

-- A fan of rays from the pilot's eye, on a grid of slopes (x/y, z/y) in the pivot's frame.
local function fromEye(label, pivot, skin)
	local params = includeParams(skin)
	local eye = pivot * Vector3.new(0, -1.3, 0)
	local step = 0.012
	local limitX, limitZ = 2.6, 1.6
	local nu = math.ceil(2 * limitX / step)
	local nv = math.ceil(2 * limitZ / step)
	local grid = table.create(nu * nv, 0)
	for v = 1, nv do
		local slopeZ = -limitZ + (v - 0.5) * step
		for u = 1, nu do
			local slopeX = -limitX + (u - 0.5) * step
			local direction = pivot:VectorToWorldSpace(Vector3.new(slopeX, 1, slopeZ).Unit)
			if workspace:Raycast(eye, direction * 80, params) then
				grid[index(nu, u, v)] = 1
			end
		end
		rayCount += nu
		if v % 25 == 0 then
			task.wait()
		end
	end
	-- A cell at the canopy's height (about 7 studs over the eye) is about this wide.
	return inspect(label, grid, nu, nv, step * 7, function(u, v)
		return string.format("slope (%.2f, %.2f)", -limitX + u * step, -limitZ + v * step)
	end)
end

--------------------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------------------

local function attachedCheck(id, scale, model, body)
	local parts = partsOf(model)
	for _, part in ipairs(parts) do
		part.CanQuery = true
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { model }
	local reached = { [body] = true }
	local queue = { body }
	while #queue > 0 do
		local part = table.remove(queue)
		for _, other in ipairs(workspace:GetPartsInPart(part, params)) do
			if not reached[other] then
				reached[other] = true
				table.insert(queue, other)
			end
		end
	end
	local loose = {}
	for _, part in ipairs(parts) do
		if not reached[part] then
			table.insert(loose, part.Name)
		end
	end
	if #loose > 0 then
		fail("%s x%.2f: %d of %d parts don't reach the harness: %s", id, scale, #loose, #parts, table.concat(loose, ", ", 1, math.min(#loose, 12)))
	end
	return #loose
end

local function materialCheck(id, model)
	local bad = {}
	for _, part in ipairs(partsOf(model)) do
		if part.Material == Enum.Material.Neon then
			table.insert(bad, part.Name .. " is Neon")
		end
		if part.Transparency > 0 then
			table.insert(bad, string.format("%s is %.2f transparent", part.Name, part.Transparency))
		end
		if part.Material == Enum.Material.Glass or part.Material == Enum.Material.ForceField then
			table.insert(bad, part.Name .. " is " .. part.Material.Name)
		end
	end
	if #bad > 0 then
		fail("%s: %s", id, table.concat(bad, "; ", 1, math.min(#bad, 8)))
	end
end

local function envelope(model, pivot)
	local skin = skinOf(model)
	local origin = pivot.Position
	local xLow, xHigh = extent(skin, origin, pivot.RightVector)
	local yLow, yHigh = extent(skin, origin, pivot.UpVector)
	local zLow, zHigh = extent(skin, origin, -pivot.LookVector)
	-- Which parts set the width, and the lowest canopy part over the head: any part whose box, in
	-- the pivot's frame, overlaps the column over the head.
	local widest, widestReach = "?", -math.huge
	local nearHead, nearHeadName = math.huge, "none"
	for _, part in ipairs(skin) do
		local low, xMin, xMax, zMin, zMax = math.huge, math.huge, -math.huge, math.huge, -math.huge
		for _, corner in ipairs(corners(part)) do
			local offset = pivot:PointToObjectSpace(corner)
			low = math.min(low, offset.Y)
			xMin, xMax = math.min(xMin, offset.X), math.max(xMax, offset.X)
			zMin, zMax = math.min(zMin, offset.Z), math.max(zMax, offset.Z)
		end
		local reach = math.max(-xMin, xMax)
		if reach > widestReach then
			widest, widestReach = part.Name, reach
		end
		if xMin < HEAD_HALF_WIDTH and xMax > -HEAD_HALF_WIDTH and zMin < HEAD_HALF_WIDTH and zMax > -HEAD_HALF_WIDTH and low < nearHead then
			nearHead, nearHeadName = low, part.Name
		end
	end
	return {
		x = xHigh - xLow, y = yHigh - yLow, z = zHigh - zLow, top = yHigh, bottom = yLow,
		nearHead = nearHead, nearHeadName = nearHeadName, widest = widest,
	}
end

-- The seam test: a ray straight through every seam, from under the skin out past it, at points
-- along the seam. Seams are where tiles meet, so where a wrong width or angle opens a gap. Unlike
-- the rasters it needs no judgement about which misses matter: any miss fails. `layout` is
-- ParachuteModels.LastLayout from the model's own build. Rays start a cell's thickness clear of the
-- skin, since a ray that starts inside a part never hits it.
local function seamTest(model, pivot, layout)
	local skin = skinOf(model)
	for _, part in ipairs(skin) do
		part.CanQuery = true
	end
	local params = includeParams(skin)
	local scale = layout.scale
	local tested, missed, where = 0, 0, {}
	-- Tiles overlap underneath a seam, so a ray exactly on the seam line runs through a neighbour's
	-- overlap even when one tile is short and a slit has opened just beside the line. So each point
	-- casts a fan across the seam: straight out, at offsets up to 0.08 design units either side.
	local OFFSETS = { -0.08, -0.06, -0.04, -0.02, 0, 0.02, 0.04, 0.06, 0.08 }
	local function cast(frame, depth, label, across)
		for _, offset in ipairs(OFFSETS) do
			local at = frame * CFrame.new(across * offset)
			local from = pivot:PointToWorldSpace((at * CFrame.new(0, -depth, 0)).Position * scale)
			local direction = pivot:VectorToWorldSpace(frame.UpVector) * (2 * depth * scale)
			tested += 1
			if not workspace:Raycast(from, direction, params) then
				missed += 1
				if #where < 4 then
					table.insert(where, string.format("%s, %+.2f across", label, offset))
				end
			end
		end
	end
	local X, Z = Vector3.xAxis, Vector3.zAxis
	for _, w in ipairs(layout.wings) do
		for s = 1, w.cells - 1 do
			local front, back = w.seamChord(s)
			for step = 0, 8 do
				local z = front + 0.1 + (back - front - 0.2) * step / 8
				cast(w.onSeam(s, 0, z), w.thick * 1.5, string.format("seam %d at z %.2f", s, z), X)
			end
		end
	end
	for _, d in ipairs(layout.domes) do
		for gore = 0, d.gores - 1 do
			local azimuth = gore / d.gores * 2 * math.pi
			for step = 0, 8 do
				local polar = d.crown + 0.04 + (d.hem - d.crown - 0.08) * step / 8
				cast(d.frame(polar, azimuth), d.thick * 1.5, string.format("gore seam %d at %.0f deg", gore, math.deg(polar)), X)
			end
		end
		for row = 1, d.rows - 1 do
			local polar = d.crown + row * d.rowAngle
			for step = 0, 31 do
				cast(d.frame(polar, (step + 0.25) / 32 * 2 * math.pi), d.thick * 1.5, string.format("row seam %d, step %d", row, step), Z)
			end
		end
		-- And straight up through the vent cap over the crown's opening.
		for _, polar in ipairs({ 0.01, d.crown * 0.5, d.crown * 0.95 }) do
			cast(d.frame(polar, 0.3), d.thick * 3, string.format("crown at %.1f deg", math.deg(polar)), X)
		end
	end
	return tested, missed, where
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

local started = os.clock()

-- Every build here is fresh: a cached clone has no LastFix or LastLayout of its own.
ParachuteModels.CacheBuilds = false

-- Self-tests. A detector that reports 0 has only proved something if a planted fault makes it
-- report more, so plant one of each and check it's caught.
do
	local function cellsOf(model)
		local cells = {}
		for _, part in ipairs(model:GetChildren()) do
			if part.Name == "Cell" then
				table.insert(cells, part)
			end
		end
		return cells
	end

	-- 1. A seam gap: the Dragonwing's fourth cell (no rib or panel over its seams) made narrower. Its
	-- neighbours overlap under the seams by up to about 0.05 studs, so narrowing it 0.2 in all leaves
	-- no straight path through (reported, not required); 0.4 opens a real slit, which must be caught.
	local model = ParachuteModels.Build("DragonChute", { scale = WORN })
	local layout = ParachuteModels.LastLayout
	local at = SPOT * CFrame.new(-140, 0, 0)
	model:PivotTo(at)
	model.Parent = stage
	local cell = cellsOf(model)[4]
	local width = cell.Size.X
	local clean, cleanMissed = seamTest(model, at, layout)
	cell.Size = Vector3.new(width - 0.2, cell.Size.Y, cell.Size.Z)
	local _, missedSmall = seamTest(model, at, layout)
	cell.Size = Vector3.new(width - 0.4, cell.Size.Y, cell.Size.Z)
	local tested, missed = seamTest(model, at, layout)
	if cleanMissed > 0 or missed == 0 then
		fail("self-test: the seam test missed %d rays on the clean Dragonwing (%d rays) and %d with a cell 0.4 studs short", cleanMissed, clean, missed)
	else
		out("self-test: the seam test catches a cell 0.4 studs short (%d of %d rays missed; %d at 0.2 short; 0 clean)", missed, tested, missedSmall)
	end
	model:Destroy()

	-- 2. A hole: the Dragonwing's middle cell cut in two with a third of its chord missing between.
	model = ParachuteModels.Build("DragonChute", { scale = WORN })
	model:PivotTo(at)
	model.Parent = stage
	local middle = cellsOf(model)[7]
	local depth = middle.Size.Z
	local backHalf = middle:Clone()
	backHalf.Size = Vector3.new(middle.Size.X, middle.Size.Y, depth * 0.35)
	backHalf.CFrame = middle.CFrame * CFrame.new(0, 0, depth / 2 - depth * 0.175)
	backHalf.Parent = model
	middle.Size = Vector3.new(middle.Size.X, middle.Size.Y, depth * 0.35)
	middle.CFrame = middle.CFrame * CFrame.new(0, 0, -depth / 2 + depth * 0.175)
	local skin = skinOf(model)
	for _, part in ipairs(skin) do
		part.CanQuery = true
	end
	-- The raster reports the planted hole as a failure; that one is expected, so it's taken back.
	local failuresBefore = failures
	local holes = orthographic("self-test (planted hole, expected)", at, skin, Vector3.yAxis, Vector3.xAxis, Vector3.zAxis)
	failures = failuresBefore
	if holes == 0 then
		fail("self-test: the below raster didn't catch a planted hole across the Dragonwing's middle cell")
	else
		out("self-test: the below raster catches a planted hole (%d found)", holes)
	end
	model:Destroy()

	-- 3. A canopy part hanging into the head. Every design clears the head by about 7 studs, so the
	-- check never has to say no; plant a part where a head would be and make sure it does.
	model = ParachuteModels.Build("PatchworkChute", { scale = WORN })
	model:PivotTo(at)
	model.Parent = stage
	local intruder = Instance.new("Part")
	intruder.Name = "Cell"
	intruder.Size = Vector3.new(1, 1, 1)
	intruder.CFrame = at * CFrame.new(0, -1.2, 0)
	intruder.Anchored = true
	intruder.Parent = model
	local planted = envelope(model, at)
	if planted.nearHead >= HEAD_CLEAR then
		fail("self-test: the head-clearance check didn't see a part planted at -1.2 over the head (lowest %.2f)", planted.nearHead)
	else
		out("self-test: the head-clearance check sees a part planted in the head's column (lowest %.2f, limit %.2f)", planted.nearHead, HEAD_CLEAR)
	end
	model:Destroy()
end

-- The default canopy, to measure the others against, and the fallback for ids with no design.
local default, defaultBody = ParachuteModels.Build(nil, { scale = WORN })
local defaultAt = SPOT * CFrame.new(-60, 0, 0)
default:PivotTo(defaultAt)
default.Parent = stage
local base = envelope(default, defaultAt)
out("default Rot Glider x%d: %d parts, %.2f wide, %.2f tall, %.2f deep, top %.2f", WORN, #partsOf(default), base.x, base.y, base.z, base.top)
if not defaultBody or default:GetAttribute("ItemId") ~= "RotGlider" then
	fail("Build(nil) didn't give the default Rot Glider")
end
-- For the record (not a failure here: ItemModels is claude-4a's): what ZFight moved on the default.
do
	local nudged, most, mostName = 0, 0, "none"
	for _, part in ipairs(partsOf(default)) do
		local moved = part:GetAttribute("ZFixed")
		if moved then
			nudged += 1
			if moved > most then
				most, mostName = moved, string.format("%s (with %s)", part.Name, tostring(part:GetAttribute("ZFixedWith")))
			end
		end
	end
	out("default Rot Glider: ZFight nudged %d parts, most %.3f studs: %s", nudged, most, mostName)
end
default:Destroy()
local unknown = ParachuteModels.Build("NoSuchChute", { scale = 1 })
if not unknown or unknown:GetAttribute("ItemId") ~= "RotGlider" then
	fail("Build of an unknown id didn't fall back to the default Rot Glider")
end
if unknown then
	unknown:Destroy()
end

local totals = { designs = 0, holes = 0, slits = 0 }
for number, id in ipairs(ParachuteModels.Order) do
	if not ONLY or id == ONLY then
		totals.designs += 1
		local designStarted = os.clock()
		-- The crate reveal's size: rebuilt so the canopy's longest side is 5.5 studs.
		local measured = ParachuteModels.Build(id, { scale = 1 })
		local _, measuredSize = measured:GetBoundingBox()
		measured:Destroy()
		local reveal = 5.5 / math.max(measuredSize.X, measuredSize.Y, measuredSize.Z)
		for _, scale in ipairs({ WORN, 1, reveal }) do
			-- As tools/audit_glider_zfight.lua measures it: the geometry as written (ZFight off), its
			-- flush pairs at the fix tolerance, and every part the build pass then changes.
			local written = nil
			if scale == WORN then
				ZFight.Enabled = false
				local okRaw, raw = pcall(ParachuteModels.Build, id, { scale = scale })
				ZFight.Enabled = true
				if okRaw and raw then
					written = { model = raw, pairs = ZFight.Scan({ raw }, ZFight.FixTolerance) }
				end
			end
			local ok, model, body = pcall(ParachuteModels.Build, id, { scale = scale })
			if not ok or not model then
				fail("%s x%.2f didn't build: %s", id, scale, tostring(model))
				continue
			end
			local fix = ParachuteModels.LastFix or { moved = 0, resized = 0, remaining = {} }
			local at = SPOT * CFrame.new(number * 40, 0, scale * 40)
			model:PivotTo(at)
			model.Parent = stage

			local parts = partsOf(model)
			-- Below the worn scale Build shrinks the worn canopy whole, so its face gaps shrink with it:
			-- scan with the tolerance shrunk the same way.
			local scan = ZFight.Scan({ model }, ZFight.Tolerance * math.min(1, scale / WORN))
			local summary = string.format("%s x%.2f: %d parts; ZFight moved %d, resized %d, left %d; scan %d", id, scale, #parts, fix.moved,
				fix.resized, #fix.remaining, #scan)
			if fix.moved + fix.resized > 0 or #scan > 0 then
				fail("%s", summary)
				for n = 1, math.min(6, #scan) do
					local pair = scan[n]
					out("    flush: %s / %s, gap %.3f", pair.a.Name, pair.b.Name, pair.gap or -1)
				end
				for _, part in ipairs(parts) do
					if part:GetAttribute("ZFixed") then
						out("    nudged: %s (with %s) by %.3f", part.Name, tostring(part:GetAttribute("ZFixedWith")), part:GetAttribute("ZFixed"))
					end
				end
			else
				out("%s", summary)
			end
			if written then
				local rawParts = partsOf(written.model)
				local rawOrigin = written.model.PrimaryPart.CFrame
				local builtOrigin = model.PrimaryPart.CFrame
				local changed = 0
				for index = 1, math.min(#rawParts, #parts) do
					local before = rawOrigin:ToObjectSpace(rawParts[index].CFrame)
					local after = builtOrigin:ToObjectSpace(parts[index].CFrame)
					if (before.Position - after.Position).Magnitude > 0.001 or (rawParts[index].Size - parts[index].Size).Magnitude > 0.001 then
						changed += 1
					end
				end
				local line = string.format("%s x%d: %d flush pairs as written, %d parts changed by the build pass", id, WORN, #written.pairs, changed)
				if #written.pairs > 0 or changed > 0 or #rawParts ~= #parts then
					fail("%s", line)
					for n = 1, math.min(6, #written.pairs) do
						local pair = written.pairs[n]
						out("    written flush: %s %s at %s / %s %s at %s; face normal %s, gap %.3f, overlap %.3f", pair.a.Name,
							tostring(pair.a.Size), tostring(rawOrigin:PointToObjectSpace(pair.a.Position)), pair.b.Name, tostring(pair.b.Size),
							tostring(rawOrigin:PointToObjectSpace(pair.b.Position)), tostring(pair.normal), pair.gap or -1, pair.overlap or -1)
					end
				else
					out("  %s", line)
				end
				written.model:Destroy()
			end
			if #parts > BUDGET then
				fail("%s: %d parts is over the budget of %d", id, #parts, BUDGET)
			end
			materialCheck(id, model)
			attachedCheck(id, scale, model, body)

			if scale == WORN then
				local size = envelope(model, at)
				local line = string.format("  envelope %.2f wide (%.0f%%, widest part %s), %.2f tall, %.2f deep, top %.2f, lowest over the head %.2f (%s)",
					size.x, size.x / base.x * 100, size.widest, size.y, size.z, size.top, size.nearHead, size.nearHeadName)
				if size.x > base.x * 1.12 or size.x < base.x * 0.85 then
					fail("%s %s — span is more than 12%% off the default's", id, line)
				elseif size.nearHead < HEAD_CLEAR then
					fail("%s %s — canopy comes down into the head", id, line)
				else
					out("%s", line)
				end

				local skin = skinOf(model)
				for _, part in ipairs(skin) do
					part.CanQuery = true
				end
				local X, Y, Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
				local views = {
					{ "below", Y, X, Z },
					{ "above", -Y, X, Z },
					{ "front", Z, X, Y },
					{ "back", -Z, X, Y },
					{ "left", X, Z, Y },
					{ "right", -X, Z, Y },
				}
				for _, view in ipairs(views) do
					local holes, slits = orthographic(id .. " " .. view[1], at, skin, view[2], view[3], view[4])
					totals.holes += holes
					totals.slits += slits
				end
				local holes, slits = fromEye(id .. " eye", at, skin)
				totals.holes += holes
				totals.slits += slits

				local layout = ParachuteModels.LastLayout
				local rays, missed, where = seamTest(model, at, layout)
				local seamLine = string.format("%s seams: %d rays through %d wing(s) and %d dome(s), %d missed", id, rays, #layout.wings,
					#layout.domes, missed)
				if rays == 0 or missed > 0 then
					fail("%s%s", seamLine, #where > 0 and (" at " .. table.concat(where, "; ")) or " (no seams tested)")
				else
					out("  %s", seamLine)
				end
				totals.seamRays = (totals.seamRays or 0) + rays
			end
			model:Destroy()
			task.wait()
		end
		out("  (%s took %.1fs)", id, os.clock() - designStarted)
	end
end

-- How long a worn canopy takes the way attachCanopy asks for it (unanchored, welded), since a
-- drop-in makes one per player: fresh, and from the cache (a clone), which is what every build after
-- the first gets. A cached clone must also match a fresh build part for part.
ParachuteModels.CacheBuilds = true
local timings = {}
local slowestFresh, slowestCached = 0, 0
for _, id in ipairs({ "default", table.unpack(ParachuteModels.Order) }) do
	if not ONLY or id == ONLY or id == "default" then
		local designId = id ~= "default" and id or nil
		local options = { scale = WORN, anchored = false, name = "GliderCanopy" }
		local clock = os.clock()
		local first = ParachuteModels.Build(designId, options)
		local fresh = (os.clock() - clock) * 1000
		clock = os.clock()
		local copies = {}
		for index = 1, 5 do
			copies[index] = ParachuteModels.Build(designId, options)
		end
		local cached = (os.clock() - clock) / 5 * 1000
		if designId then
			local a, b = partsOf(first), partsOf(copies[1])
			local same = #a == #b
			for index = 1, math.min(#a, #b) do
				if a[index].Name ~= b[index].Name or (a[index].Position - b[index].Position).Magnitude > 1e-3 or (a[index].Size - b[index].Size).Magnitude > 1e-3 then
					same = false
				end
			end
			local welds = #copies[1]:GetDescendants() - #b
			if not same or welds ~= #b - 1 then
				fail("%s: a cached build differs from a fresh one (%d vs %d parts, %d welds for %d parts)", id, #a, #b, welds, #b)
			end
		end
		first:Destroy()
		for _, copy in ipairs(copies) do
			copy:Destroy()
		end
		slowestFresh = math.max(slowestFresh, fresh)
		slowestCached = math.max(slowestCached, cached)
		table.insert(timings, string.format("%s %.1f/%.2f", id, fresh, cached))
	end
end
out("build ms, fresh/cached (worn, welded): %s; slowest %.1f fresh, %.2f cached", table.concat(timings, ", "), slowestFresh, slowestCached)

stage:Destroy()
out("SUMMARY: %d designs, %d failures, %d holes, %d possible slits, %d seam rays, %d rays, %.0fs", totals.designs, failures, totals.holes,
	totals.slits, totals.seamRays or 0, rayCount, os.clock() - started)
