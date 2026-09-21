-- SUPERSEDED (2026-09-17), DON'T RUN. This measures the OLD road design (MapDecor.RoadLamps and
-- Signpost, the Plateaus split, the old River/Relief signatures, Shore parts). claude-79's road
-- rework replaced those with RoadNetwork, so the numbers below would be wrong rather than merely
-- stale. Use claude-79's road_audit_all, which has a planted-fault self-test, and tools/footing_probe
-- for how roads meet the ground. Kept only as a record of the pre-rework baseline.
--
-- Roads audit, for tools/runtest.ps1 -Probe (one map per run: edit MAP_ID and SEED below).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_roads.lua
--
-- Builds the map from a fixed seed and measures whether the drivable surface is ONE continuous,
-- flush, connected skin: inter-town roads, junction pads, town street asphalt and bridge decks.
--
--   joints     every end of every surface part, on columns across its width: does the surface carry
--              on past the end (contiguous), resume within RESUME studs (a GAP, with its length), or
--              not resume at all (an OPEN END)? Where it carries on, the top height just past the end
--              against the plane of the part just before it (a STEP). Mixed ends (some columns carry
--              on, some are open) are RAGGED. Samples sit half a stud off part ends, and only hits on
--              upward faces (normal Y > 0.9) are compared, so an end face is never read as a step.
--   doubles    a second, different surface part within DOUBLE under the top one, at points at least
--              0.05 inside BOTH footprints (two slabs lying through each other)
--   overlap    surface parts intersecting other surface parts (exact geometry, shrunk 0.05)
--   markings   marking parts intersecting other markings
--   z-fight    ZFight.Scan over roads, towns and river, pairs involving surfaces or markings
--   ground     road/junction tops against the terrain under them
--   network    surface parts that touch are joined; every town's streets should be one network,
--              every inter-town road part should belong to it; open ends are listed with whether
--              anything finishes them (a kerb, edge line or barrier across the end)
--   self-test  one road segment is lifted 0.5 and slid 1 stud along; the joint check must report a
--              gap and a step there (then it is put back)
--
-- Town street parts are CanQuery=false (they're clutter), which hides them from every query, so
-- CanQuery is switched on for surfaces, markings and finishing parts while measuring.
-- If the road rework renames parts, update SURFACE, MARKING and FINISH.

local MAP_ID, SEED = "SahurSprings", 101
local SURFACE = { Road = true, Junction = true, Asphalt = true, BridgeDeck = true }
local MARKING = { RoadEdge = true, RoadStripe = true, Dash = true, Crossing = true }
local FINISH = { RoadEdge = true, Kerb = true, Barrier = true, Crossing = true }
local STEP = 0.06
local DOUBLE = 0.12
local RESUME = 4
local ACROSS_STEP = 2

local RS = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local ZFight = require(RS:WaitForChild("Shared"):WaitForChild("ZFight"))

local function out(fmt, ...)
	print("[AUDIT roads] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

math.randomseed(SEED)
local started = os.clock()
MapGenerator.Build(MAP_ID)
task.wait(1.5)
local map = workspace.Map
out("%s seed %d built in %.1fs", MAP_ID, SEED, os.clock() - started)

local surfaces, markings, finishes, restore = {}, {}, {}, {}
local byName = {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") and (SURFACE[d.Name] or MARKING[d.Name] or FINISH[d.Name]) then
		restore[d] = d.CanQuery
		d.CanQuery = true
		byName[d.Name] = (byName[d.Name] or 0) + 1
		if SURFACE[d.Name] then
			table.insert(surfaces, d)
		end
		if MARKING[d.Name] then
			table.insert(markings, d)
		end
		if FINISH[d.Name] then
			table.insert(finishes, d)
		end
	end
end
local counts = {}
for name, n in pairs(byName) do
	table.insert(counts, name .. " " .. n)
end
table.sort(counts)
out("parts: %s", table.concat(counts, ", "))

local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Include
surfaceParams.FilterDescendantsInstances = surfaces

local examples = {}
local function example(key, text, limit)
	examples[key] = examples[key] or {}
	if #examples[key] < (limit or 10) then
		table.insert(examples[key], text)
	end
end
local function ownerOf(part)
	local node = part
	while node.Parent and node.Parent ~= map do
		node = node.Parent
	end
	return node.Name
end

local function topHit(point)
	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), surfaceParams)
	if hit and hit.Normal.Y > 0.9 then
		return hit
	end
	return nil
end

local function insideFootprint(part, point, margin)
	local l = part.CFrame:PointToObjectSpace(point)
	return math.abs(l.X) <= part.Size.X / 2 - margin and math.abs(l.Z) <= part.Size.Z / 2 - margin
end

-- One end of one part: columns across it, walking out past the end.
local function checkEnd(part, sign, record)
	local length, width = part.Size.Z, part.Size.X
	local columns = math.max(1, math.floor((width - 1) / ACROSS_STEP))
	local contiguous, open, gapMax, stepMax = 0, 0, 0, 0
	local gapAt, stepAt = nil, nil
	for column = 0, columns do
		local x = -width / 2 + 0.5 + column * (width - 1) / math.max(1, columns)
		local inner = topHit(part.CFrame * Vector3.new(x, 0, sign * (length / 2 - 0.5)))
		if inner and inner.Instance == part then
			local resumed = nil
			for distance = 0.5, RESUME, 0.5 do
				local hit = topHit(part.CFrame * Vector3.new(x, 0, sign * (length / 2 + distance)))
				if hit then
					resumed = { distance = distance, hit = hit }
					break
				end
			end
			if not resumed then
				open += 1
			elseif resumed.distance <= 0.5 then
				contiguous += 1
				local hit = resumed.hit
				if hit.Instance ~= part then
					local n, p0 = inner.Normal, inner.Position
					local predicted = p0.Y - (n.X * (hit.Position.X - p0.X) + n.Z * (hit.Position.Z - p0.Z)) / n.Y
					local excess = math.abs(hit.Position.Y - predicted)
					if excess > stepMax then
						stepMax, stepAt = excess, hit.Position
					end
				end
			else
				local gap = resumed.distance - 0.5
				if gap > gapMax then
					gapMax, gapAt = gap, part.CFrame * Vector3.new(x, 0, sign * (length / 2 + gap / 2))
				end
			end
		end
	end
	record.ends += 1
	local label = string.format("%s (%s) %s end", part.Name, ownerOf(part), sign > 0 and "+" or "-")
	if gapMax > 0 then
		record.gaps += 1
		record.gapMax = math.max(record.gapMax, gapMax)
		example("gap", string.format("%s: surface stops and resumes %.1f further on at %s", label, gapMax, v3(gapAt)))
	end
	if stepMax > STEP then
		record.steps += 1
		record.stepMax = math.max(record.stepMax, stepMax)
		example("step", string.format("%s: %.2f step onto the next surface at %s", label, stepMax, v3(stepAt)))
	end
	if open > 0 and contiguous > 0 then
		record.ragged += 1
		example("ragged", string.format("%s: %d columns carry on, %d stop dead at %s", label, contiguous, open,
			v3(part.CFrame * Vector3.new(0, 0, sign * length / 2))))
	elseif open > 0 and contiguous == 0 and gapMax == 0 then
		table.insert(record.openEnds, { part = part, sign = sign })
	end
	return gapMax, stepMax
end

local record = { ends = 0, gaps = 0, gapMax = 0, steps = 0, stepMax = 0, ragged = 0, openEnds = {} }
for index, part in ipairs(surfaces) do
	checkEnd(part, 1, record)
	checkEnd(part, -1, record)
	if index % 40 == 0 then
		task.wait()
	end
end
out("joints: %d part ends; gaps %d (longest %.1f); steps > %.2f %d (largest %.2f); ragged ends %d; open ends %d",
	record.ends, record.gaps, record.gapMax, STEP, record.steps, record.stepMax, record.ragged, #record.openEnds)

-- Doubles, on a grid inside each part.
local doubles, doubleSamples = 0, 0
for index, part in ipairs(surfaces) do
	for x = -part.Size.X / 2 + 1, part.Size.X / 2 - 1, 3 do
		for z = -part.Size.Z / 2 + 1, part.Size.Z / 2 - 1, 3 do
			doubleSamples += 1
			local point = part.CFrame * Vector3.new(x, 0, z)
			local hit = topHit(point)
			if hit then
				local rest = RaycastParams.new()
				rest.FilterType = Enum.RaycastFilterType.Include
				local list = table.clone(surfaces)
				table.remove(list, table.find(list, hit.Instance))
				rest.FilterDescendantsInstances = list
				local under = workspace:Raycast(hit.Position + Vector3.new(0, 0.01, 0), Vector3.new(0, -DOUBLE, 0), rest)
				if under and insideFootprint(hit.Instance, hit.Position, 0.05) and insideFootprint(under.Instance, hit.Position, 0.05) then
					doubles += 1
					example("double", string.format("%s (%s) lies %.3f over %s (%s) at %s", hit.Instance.Name, ownerOf(hit.Instance),
						hit.Position.Y - under.Position.Y, under.Instance.Name, ownerOf(under.Instance), v3(hit.Position)))
				end
			end
		end
	end
	if index % 40 == 0 then
		task.wait()
	end
end
out("doubles: %d of %d interior samples have a second surface within %.2f under the top one", doubles, doubleSamples, DOUBLE)

-- Exact overlaps.
local function overlaps(list, label)
	local pairsByName, seen, total = {}, {}, 0
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = list
	for index, part in ipairs(list) do
		local probe = part:Clone()
		probe:ClearAllChildren()
		probe.Size = Vector3.new(math.max(0.02, part.Size.X - 0.1), math.max(0.02, part.Size.Y - 0.1), math.max(0.02, part.Size.Z - 0.1))
		probe.Transparency = 1
		probe.CanQuery = false
		probe.Parent = workspace
		for _, other in ipairs(workspace:GetPartsInPart(probe, params)) do
			if other ~= part and not seen[other] then
				total += 1
				local key = part.Name < other.Name and (part.Name .. "/" .. other.Name) or (other.Name .. "/" .. part.Name)
				pairsByName[key] = (pairsByName[key] or 0) + 1
				example(label, string.format("%s (%s) x %s (%s) near %s", part.Name, ownerOf(part), other.Name, ownerOf(other), v3(part.Position)))
			end
		end
		seen[part] = true
		probe:Destroy()
		if index % 60 == 0 then
			task.wait()
		end
	end
	local rows = {}
	for key, n in pairs(pairsByName) do
		table.insert(rows, key .. " " .. n)
	end
	table.sort(rows)
	return total, table.concat(rows, ", ")
end
local surfaceTotal, surfacePairs = overlaps(surfaces, "overlap")
out("overlapping surface pairs: %d [%s]", surfaceTotal, surfacePairs)
local markingTotal, markingPairs = overlaps(markings, "markingOverlap")
out("overlapping marking pairs: %d [%s]", markingTotal, markingPairs)

-- Z-fight.
local roots = {}
for _, child in ipairs(map:GetChildren()) do
	if child.Name == "Roads" or child.Name == "Town" or child.Name == "River" then
		table.insert(roots, child)
	end
end
local flushPairs = ZFight.Scan(roots)
local roadFlush = {}
for _, pair in ipairs(flushPairs) do
	if SURFACE[pair.a.Name] or SURFACE[pair.b.Name] or MARKING[pair.a.Name] or MARKING[pair.b.Name] then
		table.insert(roadFlush, pair)
	end
end
out("z-fight: %d flush pairs involving road surfaces or markings (of %d in roads/towns/river)%s", #roadFlush, #flushPairs,
	#roadFlush > 0 and (" [" .. table.concat(ZFight.Describe(roadFlush, ownerOf, 8), " | ") .. "]") or "")

-- Ground.
local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }
terrainParams.IgnoreWater = true
local floating, buried, checked, floatMax, buryMax = 0, 0, 0, 0, 0
for _, part in ipairs(surfaces) do
	if part.Name == "Road" or part.Name == "Junction" then
		checked += 1
		local top = part.CFrame * Vector3.new(0, part.Size.Y / 2, 0)
		local ground = workspace:Raycast(top + Vector3.new(0, 60, 0), Vector3.new(0, -120, 0), terrainParams)
		if ground then
			local lift = top.Y - ground.Position.Y
			if lift > 0.9 then
				floating += 1
				floatMax = math.max(floatMax, lift)
				example("floating", string.format("%s top %.2f above the ground at %s", part.Name, lift, v3(top)))
			elseif lift < 0.05 then
				buried += 1
				buryMax = math.max(buryMax, -lift)
				example("buried", string.format("%s top %.2f under the ground at %s", part.Name, -lift, v3(top)))
			end
		end
	end
end
out("ground: %d road/junction parts; top more than 0.9 over the ground %d (max %.2f); top at or under the ground %d (max %.2f)",
	checked, floating, floatMax, buried, buryMax)

-- Network.
do
	local parent = {}
	local function find(x)
		while parent[x] ~= x do
			parent[x] = parent[parent[x]]
			x = parent[x]
		end
		return x
	end
	for _, part in ipairs(surfaces) do
		parent[part] = part
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = surfaces
	for index, part in ipairs(surfaces) do
		local probe = part:Clone()
		probe:ClearAllChildren()
		probe.Size = part.Size + Vector3.new(0.6, 0.6, 0.6)
		probe.Transparency = 1
		probe.CanQuery = false
		probe.Parent = workspace
		for _, other in ipairs(workspace:GetPartsInPart(probe, params)) do
			if parent[other] then
				local a, b = find(part), find(other)
				if a ~= b then
					parent[a] = b
				end
			end
		end
		probe:Destroy()
		if index % 60 == 0 then
			task.wait()
		end
	end
	local componentTowns, componentParts = {}, {}
	for _, part in ipairs(surfaces) do
		local root = find(part)
		componentParts[root] = (componentParts[root] or 0) + 1
		local node = part
		while node.Parent and node.Parent ~= map do
			node = node.Parent
		end
		if node.Name == "Town" then
			componentTowns[root] = componentTowns[root] or {}
			componentTowns[root][node:GetAttribute("TownName") or tostring(node)] = true
		end
	end
	local components, lines = 0, {}
	for root, n in pairs(componentParts) do
		components += 1
		local towns = {}
		for name in pairs(componentTowns[root] or {}) do
			table.insert(towns, name)
		end
		table.sort(towns)
		table.insert(lines, string.format("%d parts, towns [%s] near %s", n, table.concat(towns, ", "), v3(root.Position)))
	end
	table.sort(lines)
	out("network: %d separate surface networks (want 1)", components)
	for _, line in ipairs(lines) do
		out("  network: %s", line)
	end

	local finishParams = OverlapParams.new()
	finishParams.FilterType = Enum.RaycastFilterType.Include
	finishParams.FilterDescendantsInstances = finishes
	local unfinished = 0
	for _, entry in ipairs(record.openEnds) do
		local part, sign = entry.part, entry.sign
		local endFrame = part.CFrame * CFrame.new(0, 0, sign * part.Size.Z / 2)
		local across = workspace:GetPartBoundsInBox(endFrame, Vector3.new(part.Size.X * 0.8, 2, 3), finishParams)
		local finished = #across > 0
		if not finished then
			unfinished += 1
		end
		example(finished and "openEndFinished" or "openEndUnfinished", string.format("%s (%s) %s end at %s%s", part.Name, ownerOf(part),
			sign > 0 and "+" or "-", v3(endFrame.Position), finished and (" finished by " .. across[1].Name) or ""), 40)
	end
	out("open ends: %d, of which nothing finishes %d (listed below)", #record.openEnds, unfinished)
end

-- Self-test: break one joint on purpose and see it caught.
do
	local victim = nil
	for _, part in ipairs(surfaces) do
		if part.Name == "Road" then
			local probe = { ends = 0, gaps = 0, gapMax = 0, steps = 0, stepMax = 0, ragged = 0, openEnds = {} }
			local gapA, stepA = checkEnd(part, 1, probe)
			local gapB, stepB = checkEnd(part, -1, probe)
			if gapA == 0 and gapB == 0 and #probe.openEnds == 0 and probe.ragged == 0 then
				victim = part
				break
			end
		end
	end
	if victim then
		local saved = victim.CFrame
		victim.CFrame = saved * CFrame.new(0, 0.5, 1)
		local test = { ends = 0, gaps = 0, gapMax = 0, steps = 0, stepMax = 0, ragged = 0, openEnds = {} }
		local examplesBefore = examples
		examples = {}
		checkEnd(victim, 1, test)
		checkEnd(victim, -1, test)
		examples = examplesBefore
		victim.CFrame = saved
		out("self-test: a Road lifted 0.5 and slid 1 along -> gaps %d (longest %.1f), steps %d (largest %.2f), open ends %d; %s",
			test.gaps, test.gapMax, test.steps, test.stepMax, #test.openEnds,
			(test.gaps > 0 or #test.openEnds > 0) and test.steps > 0 and "CAUGHT" or "MISSED")
	else
		out("self-test: no fully joined Road segment to break (nothing to test against)")
	end
end

local keys = {}
for key in pairs(examples) do
	table.insert(keys, key)
end
table.sort(keys)
for _, key in ipairs(keys) do
	for _, text in ipairs(examples[key]) do
		out("  %s: %s", key, text)
	end
end
for part, value in pairs(restore) do
	if part.Parent then
		part.CanQuery = value
	end
end
MapGenerator.Clear()
pcall(flush)
