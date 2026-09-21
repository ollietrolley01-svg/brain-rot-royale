-- Wilds map probe: builds one whole map, then MapWilds on it, and measures what the wilds did.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/wilds_map_probe.lua -WaitSeconds 900
--
-- Edit MAP_ID below (one map per run: Studio has died at ~3.6 GB building several).
--
-- Until MapGenerator calls MapWilds itself, this stands in for the hook: it rebuilds a MapSpace
-- from the finished map (every part's footprint, the river's strip and the plateaus' claims),
-- which is stricter than the real one, and calls MapWilds.Build with it. Reports:
--   wilds      parts against the budget, build seconds, counts by kind
--   zfight     ZFight.Scan pairs inside Wilds before any pass (want 0), then what a map-wide pass
--              moved and what's left flush afterwards
--   clipping   the harness's own cross-thing overlap check, for solid Wilds parts (want none)
--   buried     solid Wilds parts whose top is under the ground (want 0)
--   hovering   solid parts meant to stand on the ground with a bottom corner in the air (want 0)
--   paths      bot paths across the wilds, the same agent as BotService, before and after
--   water      Wilds parts standing in water (want 0)

local MAP_ID = "SahurSprings"
local SEED = 424242
-- Pathfinding across a whole map is the heaviest thing here; Studio died on Bombardiro Bay (the
-- largest map) with it on. Turn it off to measure the wilds alone.
local PATHS = true

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local MapSpace = require(modules:WaitForChild("MapSpace"))
local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))
local MapWilds = require(modules:WaitForChild("MapWilds"))

local function out(fmt, ...)
	print("[WildsMap] " .. string.format(fmt, ...))
end

math.randomseed(SEED)
local t0 = os.clock()
local info = MapGenerator.Build(MAP_ID)
local map = workspace:WaitForChild("Map")
local preset = MapData.Get(MAP_ID)
out("map %s built in %.1fs, radius %d", MAP_ID, os.clock() - t0, info.radius)
do
	local names = {}
	for _, entry in ipairs(info.landmarks or {}) do
		table.insert(names, entry.name)
	end
	out("landmarks: %s; chests %d, weapon %d, heal %d, item %d", table.concat(names, ", "), #info.chestSpots, #info.lootSpots.weapon,
		#info.lootSpots.heal, #info.lootSpots.item)
	-- How far each site's ground varied before it was levelled (Landmarks sets SiteSpread).
	local spreads = {}
	local folder = workspace.Map:FindFirstChild("Landmarks")
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		table.insert(spreads, string.format("%s %s", child.Name, tostring(child:GetAttribute("SiteSpread"))))
	end
	out("landmark site spreads: %s", table.concat(spreads, ", "))

	-- A landmark never sits on a building, a road or another thing's chest or pickup. For each landmark:
	-- town buildings whose bounds reach into its footprint, road parts inside it, and chest or loot
	-- spots inside it that lie within a town building's bounds (a landmark's own chests are its own).
	local registry = {}
	local okRegistry, Landmarks = pcall(require, modules:WaitForChild("Landmarks"))
	for _, entry in ipairs(okRegistry and Landmarks.Registry or {}) do
		registry[entry.id] = entry.footprint
	end
	local buildings = {}
	for _, town in ipairs(map:GetChildren()) do
		if town.Name == "Town" then
			for _, building in ipairs(town:GetChildren()) do
				if building:IsA("Model") then
					local cf, size = building:GetBoundingBox()
					table.insert(buildings, { name = building.Name, cf = cf, size = size })
				end
			end
		end
	end
	local roadsFolder = map:FindFirstChild("Roads")
	local problems = {}
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		local centre = child:GetAttribute("LandmarkCenter")
		local footprint = registry[child.Name] or 22
		if centre then
			for _, building in ipairs(buildings) do
				local localCentre = building.cf:PointToObjectSpace(Vector3.new(centre.X, building.cf.Y, centre.Z))
				local outX = math.max(math.abs(localCentre.X) - building.size.X / 2, 0)
				local outZ = math.max(math.abs(localCentre.Z) - building.size.Z / 2, 0)
				if outX * outX + outZ * outZ < footprint * footprint then
					table.insert(problems, string.format("%s overlaps building %s", child.Name, building.name))
				end
			end
			for _, part in ipairs(roadsFolder and roadsFolder:GetDescendants() or {}) do
				if part:IsA("BasePart") and (Vector2.new(part.Position.X - centre.X, part.Position.Z - centre.Z)).Magnitude < footprint then
					table.insert(problems, string.format("%s has road part %s inside", child.Name, part.Name))
					break
				end
			end
			local spots = {}
			for _, spot in ipairs(info.chestSpots) do
				table.insert(spots, typeof(spot) == "CFrame" and spot.Position or spot)
			end
			for _, list in pairs(info.lootSpots) do
				for _, spot in ipairs(list) do
					table.insert(spots, spot)
				end
			end
			for _, spot in ipairs(spots) do
				if (Vector2.new(spot.X - centre.X, spot.Z - centre.Z)).Magnitude < footprint then
					for _, building in ipairs(buildings) do
						local localSpot = building.cf:PointToObjectSpace(spot)
						if math.abs(localSpot.X) <= building.size.X / 2 and math.abs(localSpot.Z) <= building.size.Z / 2 then
							table.insert(problems, string.format("%s holds a spot of building %s at %s", child.Name, building.name, tostring(spot)))
						end
					end
				end
			end
		end
	end
	out("landmark overlaps (want none): %s", #problems > 0 and table.concat(problems, " | ") or "none")
end
task.wait(1)
if flush then
	flush()
end

local function countParts(root)
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end
local mapPartsBefore = countParts(map)

-- Town centres and spread, as Build worked them out.
local centers = {}
for _, child in ipairs(map:GetChildren()) do
	if child.Name == "Town" and child:GetAttribute("TownCenter") then
		table.insert(centers, child:GetAttribute("TownCenter"))
	end
end
local townSpread = math.floor(math.max(110, info.radius * 0.17))
out("towns %d, spread %d, map parts %d", #centers, townSpread, mapPartsBefore)

-- The stand-in MapSpace: every part's world bounding box, the river strip and the plateaus.
local space = MapSpace.new()
local claimed = 0
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") then
		local cf, size = d.CFrame, d.Size
		local ex = math.abs(cf.XVector.X) * size.X + math.abs(cf.YVector.X) * size.Y + math.abs(cf.ZVector.X) * size.Z
		local ez = math.abs(cf.XVector.Z) * size.X + math.abs(cf.YVector.Z) * size.Y + math.abs(cf.ZVector.Z) * size.Z
		space:AddRect(d.Position.X, d.Position.Z, ex / 2, ez / 2, 0)
		claimed += 1
	end
end
if info.river then
	for index = 1, #info.river.points - 1 do
		space:AddStrip(info.river.points[index], info.river.points[index + 1], (info.river.width or 34) / 2 + 8)
	end
end
for _, plateau in ipairs(info.plateaus or {}) do
	space:AddCircle(plateau.X, plateau.Z, plateau.radius + 10)
	if plateau.out then
		local c = Vector3.new(plateau.X, 0, plateau.Z)
		space:AddStrip(c + plateau.out * (plateau.radius - 4), c + plateau.out * (plateau.radius + 70), 12)
	end
end
out("stand-in space: %d part footprints, river %s, %d plateaus", claimed, info.river and "yes" or "no", #(info.plateaus or {}))

-- Paths: fixed pairs across open ground, measured before the wilds exist and again after.
local rng = Random.new(SEED)
local pairsList = {}
local function farFromTowns(x, z)
	for _, c in ipairs(centers) do
		if (Vector2.new(c.X - x, c.Z - z)).Magnitude < townSpread + 80 then
			return false
		end
	end
	return true
end
for _ = 1, 400 do
	if #pairsList >= 24 then
		break
	end
	local angle = rng:NextNumber(0, math.pi * 2)
	local distance = math.sqrt(rng:NextNumber()) * info.radius * 0.85
	local a = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
	local heading = rng:NextNumber(0, math.pi * 2)
	local b = a + Vector3.new(math.cos(heading), 0, math.sin(heading)) * 160
	if farFromTowns(a.X, a.Z) and farFromTowns(b.X, b.Z) and b.Magnitude < info.radius * 0.9 then
		table.insert(pairsList, { a, b })
	end
end
local function ground(p)
	-- GroundHeightAt answers nil where there's no solid ground (claude-79's contract); 0 keeps the
	-- path test running rather than erroring, and such a pair simply fails to path.
	return Vector3.new(p.X, (MapGenerator.GroundHeightAt(p.X, p.Z) or 0) + 3, p.Z)
end
local function runPaths(label)
	local ok, lengths = 0, {}
	local failed = {}
	for index, pair in ipairs(pairsList) do
		local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = true, AgentMaxSlope = 55 })
		local success = pcall(function()
			path:ComputeAsync(ground(pair[1]), ground(pair[2]))
		end)
		if success and path.Status == Enum.PathStatus.Success then
			ok += 1
			local total, prev = 0, nil
			for _, w in ipairs(path:GetWaypoints()) do
				if prev then
					total += (w.Position - prev).Magnitude
				end
				prev = w.Position
			end
			lengths[index] = total
		else
			table.insert(failed, index)
		end
	end
	out("paths %s: %d of %d found; failed #%s", label, ok, #pairsList, table.concat(failed, ","))
	return lengths
end
local Stats = game:GetService("Stats")
out("memory before paths: %.0f MB", Stats:GetTotalMemoryUsageMb())
local before = PATHS and runPaths("before") or {}
out("memory after paths: %.0f MB", Stats:GetTotalMemoryUsageMb())
if flush then
	flush()
end

-- The wilds. Timed on the wall clock as well: os.clock is process CPU time, and a map build spends
-- most of its life yielding, so CPU time badly understates what a player waits for.
local t1 = os.clock()
local wall1 = DateTime.now().UnixTimestampMillis
local result = MapWilds.Build(map, {
	preset = preset,
	radius = info.radius,
	centers = centers,
	townSpread = townSpread,
	space = space,
	groundAt = MapGenerator.GroundHeightAt,
	-- The real road network, so the bus shelters on the verges are exercised too, and the river, so
	-- the long grass grows along its banks.
	roads = info.roads,
	river = info.river,
	seed = SEED,
})
local kinds = {}
for kind, n in pairs(result.counts.byKind) do
	table.insert(kinds, kind .. " " .. n)
end
table.sort(kinds)
local wallSeconds = (DateTime.now().UnixTimestampMillis - wall1) / 1000
out("wilds: %d parts (budget %d, %.2f x radius), %.1fs cpu, %.1fs wall; trees %d, undergrowth %d, shelters %d; %d models; corridors %d (%s)",
	result.parts, result.budget, result.parts / info.radius, os.clock() - t1, wallSeconds, result.counts.trees, result.counts.undergrowth,
	result.counts.shelters, #result.model:GetChildren(), result.corridors, result.plannedRoutes and "planned from towns" or "roads")
-- Density, so "more trees" is a number that moved. The playable circle less the towns' own ground is
-- what the wilds may fill; near a road means within 60 studs of one of its edges.
do
	local playable = math.pi * (info.radius * 0.93) ^ 2
	local townArea = #centers * math.pi * townSpread ^ 2
	local open = math.max(1, playable - townArea)
	local nearRoad, nearTown, far = 0, 0, 0
	for _, child in ipairs(result.model:GetChildren()) do
		for _, d in ipairs(child:GetDescendants()) do
			if d.Name == "Trunk" and d:IsA("BasePart") then
				local p = d.Position
				local closestTown = math.huge
				for _, c in ipairs(centers) do
					closestTown = math.min(closestTown, (Vector2.new(c.X - p.X, c.Z - p.Z)).Magnitude)
				end
				local closestRoad = math.huge
				for _, corridor in ipairs(info.roads and info.roads.edges or {}) do
					local a, b = corridor.from, corridor.to
					local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
					local t = ab.Magnitude > 0 and math.clamp((Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab)) / ab:Dot(ab), 0, 1) or 0
					local at = Vector3.new(a.X, 0, a.Z) + ab * t
					closestRoad = math.min(closestRoad, (Vector2.new(at.X - p.X, at.Z - p.Z)).Magnitude)
				end
				if closestTown < townSpread + 130 then
					nearTown += 1
				elseif closestRoad < 60 then
					nearRoad += 1
				else
					far += 1
				end
			end
		end
	end
	local trunks = nearTown + nearRoad + far
	out("density: %d trunks, %.2f per 1000 studs squared of open ground (%d near a town, %d near a road, %d out in the open); undergrowth %.2f per 1000",
		trunks, trunks / open * 1000, nearTown, nearRoad, far, result.counts.undergrowth / open * 1000)
end
out("wilds kinds: %s; grass patches painted: %s", table.concat(kinds, ", "), tostring(result.paintedPatches))
local fires, lights = 0, 0
for _, d in ipairs(result.model:GetDescendants()) do
	if d:IsA("Fire") then
		fires += 1
	elseif d:IsA("PointLight") then
		lights += 1
	end
end
out("wilds effects: %d fires, %d lights; map parts %d -> %d", fires, lights, mapPartsBefore, countParts(map))
if flush then
	flush()
end

-- Z-fighting inside the wilds, before any pass.
local flush0 = ZFight.Scan({ result.model })
local function groupOf(part)
	local node = part
	while node.Parent and node.Parent ~= result.model do
		node = node.Parent
	end
	return string.gsub(node.Name, "_%d+$", "")
end
out("zfight wilds before pass: %d flush%s", #flush0,
	#flush0 > 0 and (" [" .. table.concat(ZFight.Describe(flush0, groupOf, 20), " | ") .. "]") or "")
local t2 = os.clock()
local fix = ZFight.Fix({ map }, { yield = true })
do
	-- Every wild part the pass moved or resized, with what it fought: 0 before the pass can't show a
	-- pair between a wild part and the rest of the map, and those are exactly what the pass fixes.
	local moved = {}
	for _, d in ipairs(result.model:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("ZFixed") then
			table.insert(moved, string.format("%s in %s by %.3f vs %s", d.Name, groupOf(d), d:GetAttribute("ZFixed"), tostring(d:GetAttribute("ZFixedWith"))))
		end
	end
	out("zfight map pass after wilds: moved %d, remaining %d, %.1fs; wilds parts moved: %d%s", fix.moved, #fix.remaining, os.clock() - t2, #moved,
		#moved > 0 and (" [" .. table.concat(moved, " ; ") .. "]") or "")
end

-- Flush pairs BETWEEN a wild part and anything else on the map, by owner. The wilds are to be left
-- out of the map's z-fight pass (they are built to keep faces out of each other's planes at source,
-- and a pass that nudges them hides the bug instead of fixing it), so a cross-owner pair has to be
-- measured somewhere or it goes unseen: this is that somewhere.
do
	local ownerOf = {}
	for _, child in ipairs(map:GetChildren()) do
		for _, d in ipairs(child:GetDescendants()) do
			if d:IsA("BasePart") then
				ownerOf[d] = child.Name
			end
		end
	end
	local crossed = {}
	for _, pair in ipairs(ZFight.Scan({ map })) do
		local a, b = ownerOf[pair.a], ownerOf[pair.b]
		if (a == "Wilds") ~= (b == "Wilds") and a and b then
			local key = a == "Wilds" and ("Wilds/" .. b) or ("Wilds/" .. a)
			crossed[key] = (crossed[key] or 0) + 1
		end
	end
	local rows = {}
	for key, n in pairs(crossed) do
		table.insert(rows, string.format("%s x%d", key, n))
	end
	table.sort(rows)
	out("flush pairs between the wilds and anything else (want 0): %s", #rows > 0 and table.concat(rows, ", ") or "none")
end

-- Clipping and buried, exactly as the harness judges them, for the wilds' solid parts.
local function thingOf(part)
	local node = part
	while node and node.Parent ~= map do
		if node.Parent and node.Parent.Parent == map and node:IsA("Model") then
			return node
		end
		node = node.Parent
	end
	return node
end
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include
overlapParams.FilterDescendantsInstances = { map }
local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }
terrainParams.IgnoreWater = true
local waterParams = RaycastParams.new()
waterParams.FilterType = Enum.RaycastFilterType.Include
waterParams.FilterDescendantsInstances = { workspace.Terrain }
waterParams.IgnoreWater = false

local pairsFound, examples, checked, buried, buriedExamples
local hovering, hoverExamples, inWater
local laid, laidExamples
local SKY = 2000
local function groundAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, SKY, z), Vector3.new(0, -2 * SKY, 0), terrainParams)
	return hit and hit.Position.Y
end
-- Something standing on another wild part (a table on a cabin floor) isn't hovering.
local supportParams = RaycastParams.new()
supportParams.FilterType = Enum.RaycastFilterType.Include
supportParams.FilterDescendantsInstances = { result.model }
supportParams.RespectCanCollide = true
local function supported(part, point)
	supportParams.FilterDescendantsInstances = { result.model }
	local hit = workspace:Raycast(point + Vector3.new(0, 0.05, 0), Vector3.new(0, -0.6, 0), supportParams)
	return hit ~= nil and hit.Instance ~= part
end
local function audit(parts)
	pairsFound, examples, checked, buried, buriedExamples = {}, {}, 0, 0, {}
	hovering, hoverExamples, inWater = 0, {}, 0
	laid, laidExamples = 0, {}
	for _, d in ipairs(parts) do
		if d:IsA("BasePart") and d.CanCollide and d.Size.Magnitude > 2 then
			checked += 1
			local mine = thingOf(d)
			local probe = Instance.new((d.ClassName == "WedgePart" or d.ClassName == "CornerWedgePart") and d.ClassName or "Part")
			if d:IsA("Part") and probe:IsA("Part") then
				probe.Shape = d.Shape
			end
			probe.Size = Vector3.new(math.max(0.05, d.Size.X - 0.7), math.max(0.05, d.Size.Y - 0.7), math.max(0.05, d.Size.Z - 0.7))
			probe.CFrame = d.CFrame
			probe.Transparency = 1
			probe.Anchored = true
			probe.CanCollide = false
			probe.CanTouch = false
			probe.Parent = workspace
			for _, other in ipairs(workspace:GetPartsInPart(probe, overlapParams)) do
				local theirs = thingOf(other)
				if other.CanCollide and theirs and theirs ~= mine then
					local a, b = string.gsub(mine.Name, "_%d+$", ""), string.gsub(theirs.Name, "_%d+$", "")
					local key = a < b and (a .. "/" .. b) or (b .. "/" .. a)
					pairsFound[key] = (pairsFound[key] or 0) + 1
					examples[key] = examples[key] or string.format("%s(%s) vs %s(%s) near %s", d.Name, mine.Name, other.Name, theirs.Name,
						tostring(Vector3.new(math.floor(d.Position.X), math.floor(d.Position.Y), math.floor(d.Position.Z))))
				end
			end
			probe:Destroy()
			local hit = workspace:Raycast(Vector3.new(d.Position.X, SKY, d.Position.Z), Vector3.new(0, -2 * SKY, 0), terrainParams)
			local partTop = d.Position.Y + (math.abs(d.CFrame.XVector.Y) * d.Size.X + math.abs(d.CFrame.YVector.Y) * d.Size.Y + math.abs(d.CFrame.ZVector.Y) * d.Size.Z) / 2
			if hit and hit.Position.Y > partTop + 1.5 then
				buried += 1
				if #buriedExamples < 6 then
					table.insert(buriedExamples, string.format("%s in %s top %.1f under %.1f", d.Name, mine.Name, partTop, hit.Position.Y))
				end
			end
			local wet = workspace:Raycast(Vector3.new(d.Position.X, SKY, d.Position.Z), Vector3.new(0, -2 * SKY, 0), waterParams)
			if wet and wet.Material == Enum.Material.Water and wet.Position.Y > d.Position.Y - d.Size.Y / 2 then
				inWater += 1
			end
			-- Laid on the ground and floating over it, for the pieces that are MEANT to lie on it: the
		-- scatter groups (rocks, logs, stumps, walls, hedges), which the footing probe skips and which
		-- the upright test below can't see once they are tilted. A shelter is left out of this one --
		-- its roof is supposed to be five studs up, and asking whether something is directly under a
		-- roof's middle answers "no" for every shelter ever built. Those are the floating-group check's.
		if mine and mine:GetAttribute("FootingSkip") == true then
			local cf, size = d.CFrame, d.Size
			local halfY = (math.abs(cf.XVector.Y) * size.X + math.abs(cf.YVector.Y) * size.Y + math.abs(cf.ZVector.Y) * size.Z) / 2
			local bottom = d.Position.Y - halfY
			local g = groundAt(d.Position.X, d.Position.Z)
			if g and bottom > g + 0.35 and bottom < g + 14 and not supported(d, Vector3.new(d.Position.X, bottom, d.Position.Z)) then
				laid += 1
				if #laidExamples < 10 then
					table.insert(laidExamples, string.format("%s in %s (%.1f x %.1f x %.1f) %.2f clear of the ground", d.Name, mine.Name,
						size.X, size.Y, size.Z, bottom - g))
				end
			end
		end
		-- Hovering: parts standing on the ground (upright, bottom near it) with a bottom corner in the air.
			local up = d.CFrame.UpVector
			local isColumn = d:IsA("Part") and d.Shape == Enum.PartType.Cylinder and math.abs(d.CFrame.XVector.Y) > 0.97
			if isColumn or (d.ClassName == "Part" and d.Shape == Enum.PartType.Block and math.abs(up.Y) > 0.97) then
				local bottomY, corners
				if isColumn then
					bottomY = d.Position.Y - d.Size.X / 2
					local r = d.Size.Y / 2 * 0.7
					corners = { Vector3.new(r, 0, 0), Vector3.new(-r, 0, 0), Vector3.new(0, 0, r), Vector3.new(0, 0, -r) }
				else
					bottomY = d.Position.Y - d.Size.Y / 2
					local hx, hz = d.Size.X / 2 * 0.95, d.Size.Z / 2 * 0.95
					corners = {}
					for _, s in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
						table.insert(corners, d.CFrame:VectorToWorldSpace(Vector3.new(s[1] * hx, 0, s[2] * hz)))
					end
				end
				local centreGround = groundAt(d.Position.X, d.Position.Z)
				if centreGround and bottomY < centreGround + 1 and bottomY > centreGround - 12 then
					for _, c in ipairs(corners) do
						local g = groundAt(d.Position.X + c.X, d.Position.Z + c.Z)
						if g and bottomY > g + 0.2 and not supported(d, Vector3.new(d.Position.X + c.X, bottomY, d.Position.Z + c.Z)) then
							hovering += 1
							if #hoverExamples < 8 then
								table.insert(hoverExamples, string.format("%s in %s (%.1f x %.1f x %.1f) %.2f above ground", d.Name, mine.Name,
							d.Size.X, d.Size.Y, d.Size.Z, bottomY - g))
							end
							break
						end
					end
				end
			end
			if checked % 150 == 0 then
				task.wait()
			end
		end
	end
	local report = {}
	for key, n in pairs(pairsFound) do
		table.insert(report, string.format("%s x%d (%s)", key, n, examples[key]))
	end
	table.sort(report)
	return report
end

-- Groups of visible wild parts joined (grown 0.05 each way) to nothing that reaches the ground, per
-- wild piece. The hovering test above only sees a part whose bottom is within a stud of the ground
-- under it; a rock or a table standing clear of the ground altogether is this one's.
local function floatingGroups(pieces)
	local groups = {}
	for _, piece in ipairs(pieces) do
		local parts, wasQueryable = {}, {}
		for _, d in ipairs(piece:GetDescendants()) do
			if d:IsA("BasePart") and d.Transparency < 0.98 and not d:GetAttribute("IntentionalFloat") then
				wasQueryable[d] = d.CanQuery
				d.CanQuery = true
				table.insert(parts, d)
			end
		end
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Include
		overlap.FilterDescendantsInstances = parts
		local parent = {}
		local function find(x)
			while parent[x] ~= x do
				parent[x] = parent[parent[x]]
				x = parent[x]
			end
			return x
		end
		local GROUND = {}
		parent[GROUND] = GROUND
		for _, part in ipairs(parts) do
			parent[part] = part
		end
		for index, part in ipairs(parts) do
			local cf, size = part.CFrame, part.Size
			local bottom = part.Position.Y - (math.abs(cf.XVector.Y) * size.X + math.abs(cf.YVector.Y) * size.Y + math.abs(cf.ZVector.Y) * size.Z) / 2
			local g = groundAt(part.Position.X, part.Position.Z)
			if g and bottom <= g + 0.3 then
				parent[find(part)] = find(GROUND)
			end
			local grown = part:Clone()
			grown:ClearAllChildren()
			grown.Size = part.Size + Vector3.new(0.1, 0.1, 0.1)
			grown.Transparency = 1
			grown.CanCollide = false
			grown.Parent = workspace
			for _, other in ipairs(workspace:GetPartsInPart(grown, overlap)) do
				if parent[other] then
					parent[find(other)] = find(part)
				end
			end
			grown:Destroy()
			if index % 400 == 0 then
				task.wait()
			end
		end
		local grounded = find(GROUND)
		local loose = {}
		for _, part in ipairs(parts) do
			local root = find(part)
			if root ~= grounded then
				loose[root] = loose[root] or {}
				table.insert(loose[root], part)
			end
		end
		for _, members in pairs(loose) do
			local first = members[1]
			local g = groundAt(first.Position.X, first.Position.Z)
			table.insert(groups, string.format("%s: %d parts (%s at %.1f over the ground)", piece.Name, #members, first.Name, first.Position.Y - (g or 0)))
		end
		for part, value in pairs(wasQueryable) do
			part.CanQuery = value
		end
	end
	return groups
end

local wildParts = result.model:GetDescendants()
local report = audit(wildParts)
local loose = floatingGroups(result.model:GetChildren())
out("clipping: %d solid wilds parts checked; cross-thing overlaps: %s", checked, #report > 0 and table.concat(report, " | ") or "none")
out("buried: %d%s; hovering: %d%s; in water: %d", buried, buried > 0 and (" [" .. table.concat(buriedExamples, " ; ") .. "]") or "",
	hovering, hovering > 0 and (" [" .. table.concat(hoverExamples, " ; ") .. "]") or "", inWater)
out("floating over the ground (want 0): %d%s", laid, laid > 0 and (" [" .. table.concat(laidExamples, " ; ") .. "]") or "")
out("floating groups (want 0): %d%s", #loose, #loose > 0 and (" [" .. table.concat(loose, " ; "):sub(1, 1500) .. "]") or "")

-- Planted faults through the same checks: a block inside a town building's wall (clipping), one six
-- studs under the ground (buried), one standing half a stud up on open ground (hovering) and one
-- hanging eight studs up (floating). Each must be caught, or the zeros above mean nothing.
do
	local wall
	for _, town in ipairs(map:GetChildren()) do
		if town.Name == "Town" and not wall then
			for _, d in ipairs(town:GetDescendants()) do
				if d:IsA("BasePart") and d.CanCollide and d.Size.Magnitude > 6 then
					wall = d
					break
				end
			end
		end
	end
	local open = pairsList[1] and pairsList[1][1] or Vector3.new(0, 0, 0)
	local function plant(name, size, position)
		local m = Instance.new("Model")
		m.Name = "SelfTest" .. name
		m.Parent = result.model
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.CFrame = CFrame.new(position)
		part.Parent = m
		return m, part
	end
	local function groundNear(dx)
		return groundAt(open.X + dx, open.Z) or 0
	end
	local results = {}
	local clipModel, clipPart = nil, nil
	if wall then
		clipModel, clipPart = plant("Clip", Vector3.new(4, 4, 4), wall.Position)
		results.clip = #audit({ clipPart })
	end
	local buriedModel, buriedPart = plant("Buried", Vector3.new(4, 2, 4), Vector3.new(open.X, groundNear(0) - 6, open.Z))
	audit({ buriedPart })
	results.buried = buried
	local hoverModel, hoverPart = plant("Hover", Vector3.new(4, 2, 4), Vector3.new(open.X + 30, groundNear(30) + 1.5, open.Z))
	audit({ hoverPart })
	results.hover = hovering
	local floatModel = plant("Float", Vector3.new(3, 1, 3), Vector3.new(open.X + 60, groundNear(60) + 8.5, open.Z))
	results.float = #floatingGroups({ floatModel })
	-- And the other way: the buried block is on the ground, so it must not read as floating.
	results.groundedFloat = #floatingGroups({ buriedModel })
	local works = (not wall or results.clip > 0) and results.buried == 1 and results.hover == 1 and results.float == 1 and results.groundedFloat == 0
	out("SELFTEST clipping %s, buried %d of 1, hovering %d of 1, floating %d of 1, grounded block floating %d of 0: %s",
		wall and (results.clip > 0 and "caught" or "MISSED") or "not planted (no town part)", results.buried, results.hover, results.float, results.groundedFloat,
		works and "CHECKS WORK" or "CHECKS BROKEN")
	for _, m in ipairs({ clipModel, buriedModel, hoverModel, floatModel }) do
		if m then
			m:Destroy()
		end
	end
end
if flush then
	flush()
end

local after = PATHS and runPaths("after") or {}
-- A path that worked before the wilds and not after: which wild pieces stand near its line?
for index, pair in ipairs(pairsList) do
	if before[index] and not after[index] then
		local a, b = pair[1], pair[2]
		local near = {}
		for _, child in ipairs(result.model:GetChildren()) do
			local cf, size = child:GetBoundingBox()
			local p = Vector3.new(cf.Position.X, 0, cf.Position.Z)
			local ab = b - a
			local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
			local distance = (a + ab * t - p).Magnitude - math.max(size.X, size.Z) / 2
			if distance < 12 then
				table.insert(near, string.format("%s (%.0f)", child.Name, distance))
			end
		end
		out("path #%d blocked after the wilds: %s -> %s; wild pieces within 12 studs of the line: %s", index, tostring(a), tostring(b),
			#near > 0 and table.concat(near, ", ") or "none (terrain or claims)")
	end
end
local longer, worst = 0, 0
for index, length in pairs(before) do
	if after[index] then
		local ratio = after[index] / math.max(length, 1)
		worst = math.max(worst, ratio)
		if ratio > 1.15 then
			longer += 1
		end
	end
end
out("paths: %d got over 15%% longer; worst ratio %.2f", longer, worst)

-- Up onto a landmark: a levelled site is a ring of 2-stud terrace steps, and a bot has to be able to
-- walk up them (its limit is 55 degrees; a 2-in-5 step is 22, but a stack of them can still read as a
-- wall to the navmesh). From 70 studs out on natural ground to the middle of the pad.
do
	local folder = map:FindFirstChild("Landmarks")
	local lines = {}
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		local centre = child:GetAttribute("LandmarkCenter")
		local steps = child:GetAttribute("SiteSteps")
		if centre and PATHS then
			local angle = rng:NextNumber() * math.pi * 2
			local from = ground(Vector3.new(centre.X + math.cos(angle) * 70, 0, centre.Z + math.sin(angle) * 70))
			local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = true, AgentMaxSlope = 55 })
			local success = pcall(function()
				path:ComputeAsync(from, Vector3.new(centre.X, centre.Y + 3, centre.Z))
			end)
			local ok = success and path.Status == Enum.PathStatus.Success
			local climbed = 0
			if ok then
				local prev
				for _, w in ipairs(path:GetWaypoints()) do
					if prev and w.Position.Y > prev.Y then
						climbed += w.Position.Y - prev.Y
					end
					prev = w.Position
				end
			end
			table.insert(lines, string.format("%s (%s steps) %s%s", child.Name, tostring(steps), ok and "reached" or ("FAILED " .. tostring(path.Status)),
				ok and string.format(", climbing %.0f", climbed) or ""))
		end
	end
	out("paths onto landmarks: %s", #lines > 0 and table.concat(lines, "; ") or "none checked")
end

-- Straight through the woods: a bot should be able to walk into a stand and out the far side.
local through, throughOk, ratios = 0, 0, {}
for _, child in ipairs(PATHS and result.model:GetChildren() or {}) do
	if string.match(child.Name, "^Woods_") and through < 8 then
		local cf, size = child:GetBoundingBox()
		local centre = cf.Position
		local half = math.max(size.X, size.Z) / 2 + 12
		local a = ground(Vector3.new(centre.X - half, 0, centre.Z))
		local b = ground(Vector3.new(centre.X + half, 0, centre.Z))
		through += 1
		local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = true, AgentMaxSlope = 55 })
		local success = pcall(function()
			path:ComputeAsync(a, b)
		end)
		if success and path.Status == Enum.PathStatus.Success then
			throughOk += 1
			local total, prev = 0, nil
			for _, w in ipairs(path:GetWaypoints()) do
				if prev then
					total += (w.Position - prev).Magnitude
				end
				prev = w.Position
			end
			table.insert(ratios, string.format("%s %.2f", child.Name, total / (b - a).Magnitude))
		else
			table.insert(ratios, child.Name .. " FAILED " .. tostring(path.Status))
		end
	end
end
out("paths through woods: %d of %d found; length over straight line: %s", throughOk, through, table.concat(ratios, ", "))

MapGenerator.Clear()
out("done")
