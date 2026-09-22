-- What IS the river today? Oliver's #73 is "better rivers and banks", and the recorded diagnosis is
-- that the river is a canal: constant width, vertical walls, a flat shelf, no valley. Those are four
-- claims, so this measures each one rather than accepting it.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/road_river_probe.lua -WaitSeconds 1200 [-PlaceFile <rbxlx>]
--
-- Per map, along the river's own course:
--   width      where the water surface ends on each side, measured across the flow
--   depth      water surface down to the bed under the middle
--   bank       the rise from the waterline out to where the ground stops climbing, and its angle
--   valley     the ground 40, 80 and 120 studs out, against the water's height: a river in a valley
--              sits below its surroundings, a canal sits level with them
--   variation  min, max, mean and spread of each, because "the same everywhere" is the complaint
-- And the roads' side of it: every bridge's span against the water width it crosses.
--
-- Nothing here writes terrain. Every ray starts at 2000 (terrain never reports the voxel a ray
-- starts inside) and the water rays are separate from the ground rays, because a ray that ignores
-- water measures the bed and one that doesn't measures the surface.

local RUNS = {
	{ "SahurSprings", 101 }, { "SahurSprings", 7 },
	{ "TralalaTown", 101 }, { "BombardiroBay", 101 }, { "RotRidge", 101 }, { "PatapimPlains", 101 },
}
local ALONG_STEP = 24 -- studs between cross-sections
local ACROSS_STEP = 2 -- studs between samples across the flow
local ACROSS_REACH = 130 -- how far out to look for the bank and the valley

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))

local function out(fmt, ...)
	print("[RIVER] " .. string.format(fmt, ...))
end

local ground = RaycastParams.new()
ground.FilterType = Enum.RaycastFilterType.Include
ground.IgnoreWater = true
local wet = RaycastParams.new()
wet.FilterType = Enum.RaycastFilterType.Include
wet.IgnoreWater = false

local function stats(list)
	if #list == 0 then
		return nil
	end
	local low, high, total = math.huge, -math.huge, 0
	for _, value in ipairs(list) do
		low, high, total = math.min(low, value), math.max(high, value), total + value
	end
	return low, high, total / #list
end

for _, run in ipairs(RUNS) do
	local mapId, seed = run[1], run[2]
	math.randomseed(seed)
	local ok, info = pcall(MapGenerator.Build, mapId)
	if not ok then
		out("%s seed %d: BUILD FAILED %s", mapId, seed, tostring(info))
		continue
	end
	task.wait(1.5)
	ground.FilterDescendantsInstances = { workspace.Terrain }
	wet.FilterDescendantsInstances = { workspace.Terrain }

	local river = info.river
	if not river or not river.points or #river.points < 3 then
		out("%s seed %d: no river on this map", mapId, seed)
		MapGenerator.Clear()
		task.wait(1)
		continue
	end

	local function solidAt(x, z)
		local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), ground)
		return hit and hit.Position.Y
	end
	local function waterAt(x, z)
		local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), wet)
		if hit and hit.Material == Enum.Material.Water then
			return hit.Position.Y
		end
		return nil
	end

	local SHELF_OUT = { 2, 6, 10, 14, 20, 30 }
	local VALLEY_OUT = { 40, 80, 120 }
	local widths, depths, bedSpread = {}, {}, {}
	local wallRises, wallAngles, bankRises, bankAngles = {}, {}, {}, {}
	local shelf, valley = {}, {}
	for index = 1, #SHELF_OUT do
		shelf[index] = {}
	end
	for index = 1, #VALLEY_OUT do
		valley[index] = {}
	end
	local sections, dry = 0, 0
	for index = 1, #river.points - 1 do
		local a, b = river.points[index], river.points[index + 1]
		local length = (b - a).Magnitude
		if length > 1 then
			local dir = (b - a).Unit
			local across = Vector3.new(-dir.Z, 0, dir.X)
			for step = 0, length - 1, ALONG_STEP do
				local centre = a + dir * step
				local surface = waterAt(centre.X, centre.Z)
				if not surface then
					dry += 1
				else
					sections += 1
					-- Width: out from the middle on both sides until the water stops.
					local edges = {}
					for _, side in ipairs({ -1, 1 }) do
						local edge = 0
						for distance = 0, ACROSS_REACH, ACROSS_STEP do
							local p = centre + across * (side * distance)
							if waterAt(p.X, p.Z) then
								edge = distance
							else
								break
							end
						end
						table.insert(edges, edge)
					end
					table.insert(widths, edges[1] + edges[2])
					-- The bed under the water: how deep in the middle, and how level across. A
					-- flat-bottomed channel and a river bed are different shapes.
					local deepest, shallowest, middle = -math.huge, math.huge, nil
					for _, fraction in ipairs({ -0.9, -0.5, 0, 0.5, 0.9 }) do
						local side = fraction < 0 and -1 or 1
						local p = centre + across * (side * math.abs(fraction) * (side < 0 and edges[1] or edges[2]))
						local bed = solidAt(p.X, p.Z)
						if bed then
							deepest, shallowest = math.max(deepest, surface - bed), math.min(shallowest, surface - bed)
							if fraction == 0 then
								middle = surface - bed
							end
						end
					end
					if middle then
						table.insert(depths, middle)
					end
					if deepest > -math.huge then
						table.insert(bedSpread, deepest - shallowest)
					end
					-- The wall, on the wider side: the bed two studs inside the waterline against the
					-- ground two studs outside it. A vertical wall puts the whole rise in those four studs.
					local side = edges[1] >= edges[2] and -1 or 1
					local waterEdge = math.max(edges[1], edges[2])
					local inPoint = centre + across * (side * math.max(waterEdge - 2, 0))
					local outPoint = centre + across * (side * (waterEdge + 2))
					local inside, outside = solidAt(inPoint.X, inPoint.Z), solidAt(outPoint.X, outPoint.Z)
					if inside and outside then
						table.insert(wallRises, outside - inside)
						table.insert(wallAngles, math.deg(math.atan2(outside - inside, 4)))
					end
					-- The shelf and then the bank, as height over the water at fixed distances out
					-- from the waterline. This is the cross-section, sampled the same way every time.
					for i, distance in ipairs(SHELF_OUT) do
						local p = centre + across * (side * (waterEdge + distance))
						local here = solidAt(p.X, p.Z)
						if here then
							table.insert(shelf[i], here - surface)
						end
					end
					-- The bank: from the waterline out, until the ground stops rising.
					local last = solidAt(outPoint.X, outPoint.Z) or surface
					local top, run = last, 0
					for distance = waterEdge + ACROSS_STEP, ACROSS_REACH, ACROSS_STEP do
						local p = centre + across * (side * distance)
						local here = solidAt(p.X, p.Z)
						if not here then
							break
						end
						if here > top + 0.05 then
							top, run = here, distance - waterEdge
						elseif distance - waterEdge > run + 16 then
							break -- stopped climbing for 16 studs: that is the bank top
						end
					end
					table.insert(bankRises, top - surface)
					table.insert(bankAngles, run > 0 and math.deg(math.atan2(top - last, run)) or 90)
					-- Valley: the ground well out from the water, as height over the water. A river in
					-- a valley sits below its surroundings; a canal sits level with them.
					for i, distance in ipairs(VALLEY_OUT) do
						local p = centre + across * (side * distance)
						local here = solidAt(p.X, p.Z)
						if here then
							table.insert(valley[i], here - surface)
						end
					end
				end
			end
		end
		if index % 8 == 0 then
			task.wait()
		end
	end

	local function line(name, list, unit)
		local low, high, mean = stats(list)
		if not low then
			return string.format("%s no samples", name)
		end
		return string.format("%s %.1f..%.1f %s (mean %.1f, spread %.1f)", name, low, high, unit, mean, high - low)
	end
	local function profile(outs, lists)
		local parts = {}
		for i, distance in ipairs(outs) do
			local low, high, mean = stats(lists[i])
			table.insert(parts, low and string.format("%d:%.1f (%.1f..%.1f)", distance, mean, low, high)
				or string.format("%d:-", distance))
		end
		return table.concat(parts, "  ")
	end
	out("%s seed %d: %d cross-sections measured, %d points of the course had no water; river.width says %s; pond %s",
		mapId, seed, sections, dry, tostring(river.width), tostring(river.pond))
	out("    %s", line("water width", widths, "studs"))
	out("    %s", line("depth in the middle", depths, "studs"))
	out("    %s", line("bed unevenness across the channel", bedSpread, "studs"))
	out("    %s", line("wall rise over the 4 studs at the waterline", wallRises, "studs"))
	out("    %s", line("wall angle", wallAngles, "deg"))
	out("    %s", line("bank top above the water", bankRises, "studs"))
	out("    %s", line("bank angle", bankAngles, "deg"))
	out("    cross-section, height over the water at studs out from the waterline: %s", profile(SHELF_OUT, shelf))
	out("    further out: %s", profile(VALLEY_OUT, valley))

	-- The town centres, because Oliver has also asked for a roundabout in every one: what stands in
	-- the middle today, by name, with how far out each name reaches. A ring road has to fit between
	-- the fountain and the buildings, so the gap between them is the design, and it is measured here
	-- rather than assumed. One pass over the map's parts, shared by the towns.
	local roads = info.roads
	local towns = {}
	for townIndex, town in ipairs(roads and roads.towns or {}) do
		if townIndex <= 2 then
			table.insert(towns, { town = town, names = {} })
		end
	end
	local pieces = workspace.Map:GetDescendants()
	for _, part in ipairs(pieces) do
		if part:IsA("BasePart") then
			for _, entry in ipairs(towns) do
				local dx = part.Position.X - entry.town.center.X
				local dz = part.Position.Z - entry.town.center.Z
				if dx * dx + dz * dz <= 110 * 110 then
					local distance = math.sqrt(dx * dx + dz * dz)
					local row = entry.names[part.Name]
					if row then
						row.n, row.low, row.high = row.n + 1, math.min(row.low, distance), math.max(row.high, distance)
					else
						entry.names[part.Name] = { n = 1, low = distance, high = distance }
					end
				end
			end
		end
	end
	for townIndex, entry in ipairs(towns) do
		local rows = {}
		for name, row in pairs(entry.names) do
			table.insert(rows, { name = name, n = row.n, low = row.low, high = row.high })
		end
		table.sort(rows, function(p, q)
			return p.low < q.low
		end)
		local listed = {}
		for i, row in ipairs(rows) do
			if i <= 26 then
				table.insert(listed, string.format("%s x%d %.0f..%.0f", row.name, row.n, row.low, row.high))
			end
		end
		out("    town %d at (%.0f, %.0f), footprint half %s cross %s zext %s; %d part names within 110 studs of the centre, nearest first: %s",
			townIndex, entry.town.center.X, entry.town.center.Z, tostring(entry.town.half), tostring(entry.town.cross),
			tostring(entry.town.zext), #rows, table.concat(listed, " | "))
	end

	-- The roads' side: each bridge's span against the water it crosses.
	local decks = {}
	for _, d in ipairs(workspace.Map:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "BridgeDeck" then
			table.insert(decks, d)
		end
	end
	local spans = {}
	for _, deck in ipairs(decks) do
		local look = deck.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		local span = flat.Magnitude > 0.1 and deck.Size.Z or deck.Size.X
		-- The water actually under it, across the deck's own line.
		local dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
		local wetRun = 0
		for step = -span / 2, span / 2, 2 do
			local p = deck.Position + dir * step
			if waterAt(p.X, p.Z) then
				wetRun += 2
			end
		end
		table.insert(spans, string.format("deck %.0f long over %.0f of water", span, wetRun))
	end
	out("    bridges: %d [%s]", #decks, table.concat(spans, "; "))
	MapGenerator.Clear()
	task.wait(1)
end
-- FlattenPad's `space` option, never yet exercised: MapGenerator.Build does not return its MapSpace,
-- so the pads probe passed nil and the claim-aware graded edge went unmeasured. The promise is that
-- the skirt leaves claimed ground alone unless the claim is the caller's own `ignore`. Two pads on
-- the same kind of slope, one claim each side, settle it.
local MapTerrain = require(modules:WaitForChild("MapTerrain"))
local MapSpace = require(modules:WaitForChild("MapSpace"))
math.randomseed(101)
local padOk, padInfo = pcall(MapGenerator.Build, "RotRidge")
if not padOk then
	out("pad space test: BUILD FAILED %s", tostring(padInfo))
else
	task.wait(1.5)
	ground.FilterDescendantsInstances = { workspace.Terrain }
	local function solid(x, z)
		local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), ground)
		return hit and hit.Position.Y
	end
	-- A sloping site clear of the roads, the same search the pads probe uses.
	local site = nil
	for _ = 1, 600 do
		local angle, distance = math.random() * math.pi * 2, (0.3 + math.random() * 0.5) * padInfo.radius
		local x, z = math.cos(angle) * distance, math.sin(angle) * distance
		if not padInfo.roads:GroundAt(x, z, 0) then
			local low, high = math.huge, -math.huge
			for _, offset in ipairs({ { 0, 0 }, { 14, 0 }, { -14, 0 }, { 0, 14 }, { 0, -14 } }) do
				local here = solid(x + offset[1], z + offset[2])
				if here then
					low, high = math.min(low, here), math.max(high, here)
				end
			end
			if low < math.huge and high - low > 2 and (not site or high - low > site.fall) then
				site = { x = x, z = z, fall = high - low }
			end
		end
	end
	if not site then
		out("pad space test: no sloping site off the roads")
	else
		-- Sample OUTSIDE the pad's own flat zone. The first run of this test sampled from 16 studs out
		-- and reported 17.7 studs of movement on claimed ground, which reads as the claim being
		-- ignored -- but FlattenPad's flat zone runs to margin + 2 voxels (3 + 8 = 11) past the
		-- footprint's 12, so everything inside 23 studs is flat BY DESIGN and the claim has no say
		-- there ("keep the margin inside your own claim"). The promise is about the graded edge, so
		-- the measurement has to start past 23: from 26 to 50 studs out.
		local function line(sign)
			local heights = {}
			for distance = 26, 50, 4 do
				table.insert(heights, solid(site.x + sign * distance, site.z))
			end
			return heights
		end
		local leftBefore, rightBefore = line(-1), line(1)
		local space = MapSpace.new()
		space:AddCircle(site.x - 38, site.z, 14) -- claims 24..52 studs out: the ground the left skirt would grade
		local height, why = MapTerrain.FlattenPad(CFrame.new(site.x, 0, site.z), Vector3.new(24, 0, 18),
			{ height = "mid", margin = 3, space = space })
		task.wait(0.5)
		local leftAfter, rightAfter = line(-1), line(1)
		local function moved(before, after)
			local most = 0
			for index, was in ipairs(before) do
				if was and after[index] then
					most = math.max(most, math.abs(after[index] - was))
				end
			end
			return most
		end
		out("pad space test: site (%.0f, %.0f) falls %.1f studs; pad -> %s%s", site.x, site.z, site.fall,
			tostring(height or why), height and "" or " (refused)")
		out("    ground moved at 26..50 studs out (past the flat zone): claimed side %.3f studs (want ~0), free side %.3f studs (want the skirt's own grade)",
			moved(leftBefore, leftAfter), moved(rightBefore, rightAfter))
		-- And again with `ignore`: the caller's own claim must NOT stop its own skirt.
		local site2 = nil
		for _ = 1, 600 do
			local angle, distance = math.random() * math.pi * 2, (0.3 + math.random() * 0.5) * padInfo.radius
			local x, z = math.cos(angle) * distance, math.sin(angle) * distance
			if not padInfo.roads:GroundAt(x, z, 0) and not MapTerrain.PadNear(x, z, 60) then
				local low, high = math.huge, -math.huge
				for _, offset in ipairs({ { 0, 0 }, { 14, 0 }, { -14, 0 } }) do
					local here = solid(x + offset[1], z + offset[2])
					if here then
						low, high = math.min(low, here), math.max(high, here)
					end
				end
				if low < math.huge and high - low > 2 and (not site2 or high - low > site2.fall) then
					site2 = { x = x, z = z, fall = high - low }
				end
			end
		end
		if site2 then
			local before = {}
			for distance = 26, 50, 4 do
				table.insert(before, solid(site2.x - distance, site2.z))
			end
			local mine = MapSpace.new()
			local claim = mine:AddCircle(site2.x - 38, site2.z, 14)
			local height2 = MapTerrain.FlattenPad(CFrame.new(site2.x, 0, site2.z), Vector3.new(24, 0, 18),
				{ height = "mid", margin = 3, space = mine, ignore = claim })
			task.wait(0.5)
			local after = {}
			for distance = 26, 50, 4 do
				table.insert(after, solid(site2.x - distance, site2.z))
			end
			local most = 0
			for index, was in ipairs(before) do
				if was and after[index] then
					most = math.max(most, math.abs(after[index] - was))
				end
			end
			out("    with the claim passed as `ignore`: pad -> %s, ground moved %.3f studs on that same side (want the grade, not 0)",
				tostring(height2), most)
		else
			out("    no second site for the `ignore` half of the test")
		end
	end
end
out("done")
