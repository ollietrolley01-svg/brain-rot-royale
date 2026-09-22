-- MapTerrain.FlattenPad, measured on real ground. An API with no callers yet is an API nobody has
-- proved, so this builds a map, makes pads on the worst ground it can find, and measures what they
-- did: flat where they promise flat, solid underneath where they filled, graded at the edges, and
-- refused where they promise to refuse.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/road_pads_probe.lua -WaitSeconds 900 [-PlaceFile <rbxlx>]

local MAP_ID, SEED = "RotRidge", 101 -- the roughest ground of the five
local SITES = 20 -- enough to time the call honestly as well as measure it
local FLAT = 0.25 -- a pad's top must be this flat across its whole footprint and margin

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local MapTerrain = require(modules:WaitForChild("MapTerrain"))

local function out(fmt, ...)
	print("[PADS] " .. string.format(fmt, ...))
end

math.randomseed(SEED)
local ok, info = pcall(MapGenerator.Build, MAP_ID)
if not ok then
	out("BUILD FAILED %s", tostring(info))
	return
end
task.wait(1.5)
local roads = info.roads

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { workspace.Terrain }
params.IgnoreWater = true
local function surface(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), params)
	return hit and hit.Position.Y
end

-- The sites: sloping ground away from the roads, found by sampling.
local sites = {}
for _ = 1, 400 do
	if #sites >= SITES then
		break
	end
	local angle, distance = math.random() * math.pi * 2, (0.3 + math.random() * 0.5) * info.radius
	local x, z = math.cos(angle) * distance, math.sin(angle) * distance
	if not roads:GroundAt(x, z, 0) then
		local low, high = math.huge, -math.huge
		for _, offset in ipairs({ { 0, 0 }, { 14, 0 }, { -14, 0 }, { 0, 14 }, { 0, -14 } }) do
			local h = surface(x + offset[1], z + offset[2])
			if h then
				low, high = math.min(low, h), math.max(high, h)
			end
		end
		if low < math.huge and high - low > 1.5 then
			table.insert(sites, { x = x, z = z, low = low, high = high })
		end
	end
end
out("%d sloping sites off the roads on %s seed %d (fall across 28 studs: %.1f..%.1f)", #sites, MAP_ID, SEED,
	(function()
		local least = math.huge
		for _, site in ipairs(sites) do
			least = math.min(least, site.high - site.low)
		end
		return least == math.huge and 0 or least
	end)(), (function()
		local most = 0
		for _, site in ipairs(sites) do
			most = math.max(most, site.high - site.low)
		end
		return most
	end)())

local worstFlat, worstHollow, madeCount, refusedCount = 0, 0, 0, 0
local worstFootprint, steepest, steepestSite, steepestHeight = 0, 0, nil, nil
local totalMillis = 0
local reasons = {}
-- Wall clock, not os.clock: os.clock is CPU time, and a build that yields understates itself.
local function millis()
	return DateTime.now().UnixTimestampMillis
end
for index, site in ipairs(sites) do
	out("  pad %d: starting at (%.0f, %.0f)", index, site.x, site.z)
	task.wait()
	local size = Vector3.new(24, 0, 18)
	local yaw = math.random() * math.pi * 2
	local frame = CFrame.new(site.x, 0, site.z) * CFrame.Angles(0, yaw, 0)
	local costStarted = os.clock()
	local low, high, mean = MapTerrain.PadCost(frame, size, { margin = 3 })
	out("  pad %d: cost read in %.2fs", index, os.clock() - costStarted)
	local madeStarted = millis()
	local height, why = MapTerrain.FlattenPad(frame, size, { height = "mid", margin = 3, space = info.space })
	local took = millis() - madeStarted
	totalMillis += took
	if index <= 3 then
		out("  pad %d: flatten returned %s in %d ms", index, tostring(height or why), took)
	end
	if not height then
		refusedCount += 1
		reasons[why or "?"] = (reasons[why or "?"] or 0) + 1
	else
		madeCount += 1
		task.wait(0.2)
		-- Flat across the footprint and its margin?
		local flattest, roughest = math.huge, -math.huge
		for dx = -15, 15, 3 do
			for dz = -12, 12, 3 do
				local p = frame * CFrame.new(dx, 0, dz)
				local got = surface(p.X, p.Z)
				if got then
					flattest, roughest = math.min(flattest, got), math.max(roughest, got)
				end
			end
		end
		worstFlat = math.max(worstFlat, math.max(math.abs(roughest - height), math.abs(flattest - height)))
		-- Solid underneath where it filled: read the voxels under the pad's lowest corner.
		local check = frame * CFrame.new(10, 0, 7)
		local region = Region3.new(Vector3.new(check.X - 2, height - 20, check.Z - 2), Vector3.new(check.X + 2, height + 4, check.Z + 2)):ExpandToGrid(4)
		local mats, occs = workspace.Terrain:ReadVoxels(region, 4)
		local hollow, origin = 0, region.CFrame.Position - region.Size / 2
		for iy = 1, mats.Size.Y do
			local bottom = origin.Y + (iy - 1) * 4
			if bottom + 4 <= height - MapTerrain.SurfaceLift and occs[1][iy][1] < 1 then
				hollow += 1
			end
		end
		worstHollow = math.max(worstHollow, hollow)
		if index <= 3 then
			out("  pad %d at (%.0f, %.0f): ground %.2f..%.2f (mean %.2f) -> flat at %.2f; measured %.2f..%.2f; %d hollow voxels under it",
				index, site.x, site.z, low, high, mean, height, flattest, roughest, hollow)
		end
	end
end
local reasonList = {}
for why, n in pairs(reasons) do
	table.insert(reasonList, why .. " x" .. n)
end
out("pads made %d, refused %d [%s]; worst departure from flat: footprint %.3f, footprint+margin %.3f (want <= %.2f); worst hollow voxels under a fill %d (want 0)",
	madeCount, refusedCount, table.concat(reasonList, ", "), worstFootprint, worstFlat, FLAT, worstHollow)
out("cost: %d pads in %d ms wall clock, %.1f ms each. A map with 150 padded structures would add %.2f s to its build.",
	madeCount, totalMillis, madeCount > 0 and totalMillis / madeCount or 0, (madeCount > 0 and totalMillis / madeCount or 0) * 150 / 1000)

-- A cross-section through the steepest pad: where the flat ends and how the edge grades away. This is
-- the measurement that settles "the render shows a flat pad but the numbers say 38 studs of spread".
if steepestSite then
	local row = {}
	for dx = -40, 40, 4 do
		local p = steepestSite.frame * CFrame.new(dx, 0, 0)
		local got = surface(p.X, p.Z)
		table.insert(row, string.format("%d:%s", dx, got and string.format("%.1f", got - steepestHeight) or "-"))
	end
	out("cross-section of the steepest pad (%.1f studs of natural fall), height over the pad, footprint is |x|<=12: %s", steepest, table.concat(row, " "))
end

-- The promises that are refusals, each planted on purpose.
local edge = roads.edges[1]
local onRoad = edge.from + edge.dir * (edge.length / 2)
local _, roadWhy = MapTerrain.FlattenPad(CFrame.new(onRoad.X, 0, onRoad.Z), Vector3.new(24, 0, 18), {})
local firstSite = sites[1]
local overlapHeight, overlapWhy = nil, nil
if firstSite then
	overlapHeight, overlapWhy = MapTerrain.FlattenPad(CFrame.new(firstSite.x + 4, 0, firstSite.z + 4), Vector3.new(24, 0, 18), { height = 500 })
end
local _, roughWhy = MapTerrain.FlattenPad(CFrame.new(0, 0, 0), Vector3.new(10, 0, 10), { material = Enum.Material.Rock })
out("refusals: on a road -> %s (want road); over an earlier pad at another height -> %s (want pad); rough material -> %s (want material)",
	tostring(roadWhy), tostring(overlapWhy), tostring(roughWhy))

-- PadAt and PadNear, at a made pad's centre, its skirt, and well away.
if sites[1] then
	local here = MapTerrain.PadAt(sites[1].x, sites[1].z)
	local skirt = MapTerrain.PadNear(sites[1].x + 22, sites[1].z, 0)
	local away = MapTerrain.PadNear(sites[1].x + 200, sites[1].z, 0)
	out("PadAt on a pad -> %s (want a height); PadNear on its skirt -> %s (want true); PadNear 200 studs away -> %s (want false)",
		tostring(here), tostring(skirt), tostring(away))
end

-- And the re-assert, after something else writes over a pad.
if sites[1] and MapTerrain.PadAt(sites[1].x, sites[1].z) then
	local padHeight = MapTerrain.PadAt(sites[1].x, sites[1].z)
	workspace.Terrain:FillBlock(CFrame.new(sites[1].x, padHeight + 3, sites[1].z), Vector3.new(12, 12, 12), Enum.Material.Rock)
	task.wait(0.5)
	local buried = surface(sites[1].x, sites[1].z)
	MapTerrain.RewritePads(workspace.Terrain)
	task.wait(0.5)
	local restored = surface(sites[1].x, sites[1].z)
	out("re-assert: pad at %.2f, buried to %.2f by a block dropped on it, back to %.2f after RewritePads (want %.2f)",
		padHeight, buried or -999, restored or -999, padHeight)
end
out("done")
