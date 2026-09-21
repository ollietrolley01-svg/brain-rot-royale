-- Building audit, for tools/runtest.ps1 -Probe (every map in MAPS below, one after another).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_buildings.lua
--
-- Builds the map from a fixed seed and MEASURES, per building: through-holes in wall faces (rays on
-- a 0.25 x 0.5 grid, open cells grouped; 5x5 windows and the 8x9 front door are expected, anything
-- else is reported) and roofs; doorway thresholds with no part under them; stair flights with no
-- floor under the foot landing, a gap beside the first step or at the top, or a wall/prop in their
-- headroom or exit; multi-floor buildings with no stairs and the loot spots on their upper floors;
-- partition end gaps; ceiling lights with nothing above them; chimneys hanging into rooms. Then every
-- loot spot (pad height against the surface under it, solid parts inside the pickup's volume), every
-- chest spot, and death drops by roof parapets and back walls through LootService.DropItem.
--
-- Reference numbers (before any building fix, 2026-09-16): SahurSprings seed 101 -> 59 buildings,
-- windows 789, doors 59, wallHoles 0, flights 41, footNoFloor 21, sideGap 21, topGap 41,
-- blockedFlights 10, multiFloor 27, noStairs 7 (32 loot spots), thresholdOpenBuildings 59,
-- floatingLights 33, chimneyStubs 25, partitionEndGaps 105. TralalaTown seed 202 -> 59 buildings,
-- windows 826, wallHoles 0, flights 50, footNoFloor 29, topGap 48, blockedFlights 12, multiFloor 28,
-- noStairs 7 (21), thresholdOpenBuildings 59, floatingLights 27, chimneyStubs 20, chestBlocked 2.
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local modules = SSS:WaitForChild("Modules")
local Shared = RS:WaitForChild("Shared")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local LootService = require(modules:WaitForChild("LootService"))
local ZFight = require(Shared:WaitForChild("ZFight"))

-- Every map, each from a fixed seed, so a run is repeatable and two runs can be compared. The seeds
-- are arbitrary but pinned: SahurSprings 101 and TralalaTown 202 are the ones the reference numbers
-- above were taken with. Cut this list down to one entry while chasing a single map -- a full pass is
-- about five builds' worth of time.
local MAPS = {
	{ "SahurSprings", 101 }, { "TralalaTown", 202 }, { "BombardiroBay", 303 },
	{ "RotRidge", 404 }, { "PatapimPlains", 505 },
}
local FLOOR_HEIGHT, WH, TW = 15, 0.7, 1.4
local PITCH = math.tan(math.rad(28))

local function out(fmt, ...)
	print("[PROBE] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

local H = {}

-- Connected components of open cells in a 2D grid of booleans keyed "i,j".
function H.components(open, stepA, stepB, originA, originB)
	local seen, comps = {}, {}
	for key in pairs(open) do
		if not seen[key] then
			local i0, j0 = string.match(key, "(-?%d+),(-?%d+)")
			local stack = { { tonumber(i0), tonumber(j0) } }
			seen[key] = true
			local c = { minI = math.huge, maxI = -math.huge, minJ = math.huge, maxJ = -math.huge, n = 0 }
			while #stack > 0 do
				local cell = table.remove(stack)
				local i, j = cell[1], cell[2]
				c.n += 1
				c.minI, c.maxI = math.min(c.minI, i), math.max(c.maxI, i)
				c.minJ, c.maxJ = math.min(c.minJ, j), math.max(c.maxJ, j)
				for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
					local k = (i + d[1]) .. "," .. (j + d[2])
					if open[k] and not seen[k] then
						seen[k] = true
						table.insert(stack, { i + d[1], j + d[2] })
					end
				end
			end
			c.a0, c.a1 = originA + c.minI * stepA, originA + c.maxI * stepA
			c.b0, c.b1 = originB + c.minJ * stepB, originB + c.maxJ * stepB
			table.insert(comps, c)
		end
	end
	return comps
end

function H.boxHits(cframe, size, include, shape)
	local probe = Instance.new("Part")
	if shape then
		probe.Shape = shape
	end
	probe.Size = size
	probe.CFrame = cframe
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.Transparency = 1
	probe.Parent = workspace
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	local hits = workspace:GetPartsInPart(probe, params)
	probe:Destroy()
	return hits
end

-- The building's frame from its ground-floor slab (the only Floor part at y 0 on a floor with no well).
function H.frameOf(model)
	local ground, area = nil, -1
	local levels = {}
	local fh = model.Name == "warehouse" and FLOOR_HEIGHT * 1.6 or FLOOR_HEIGHT
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") and p.Name == "Floor" then
			levels[math.floor(p.Position.Y / fh + 0.5)] = true
			if math.abs(p.Position.Y) < 0.3 and p.Size.X * p.Size.Z > area then
				ground, area = p, p.Size.X * p.Size.Z
			end
		end
	end
	if not ground then
		return nil
	end
	local floors = 0
	for _ in pairs(levels) do
		floors += 1
	end
	local width = math.floor(ground.Size.X + TW + 0.5)
	local depth = math.floor(ground.Size.Z + TW + 0.5)
	local frame = CFrame.new(ground.Position.X, 0, ground.Position.Z) * ground.CFrame.Rotation
	local _, yaw = frame:ToOrientation()
	return {
		model = model, frame = frame, width = width, depth = depth, halfW = width / 2, halfD = depth / 2,
		floors = floors, fh = fh, topY = floors * fh, archetype = model.Name, yaw = math.deg(yaw),
	}
end

local totals = {}
local function bump(key, n)
	totals[key] = (totals[key] or 0) + (n or 1)
end
local examples = {}
local function example(key, text, limit)
	examples[key] = examples[key] or {}
	if #examples[key] < (limit or 4) then
		table.insert(examples[key], text)
	end
end

-- Walls: rays straight through each face on a 0.25 x 0.5 grid, outside to just inside. Open cells
-- are grouped; windows (5 x 5 at sill 4.0..9.0 above the floor) and the front door (8 x 9 on the
-- ground floor) are expected, anything else is reported.
function H.scanWalls(b, mapId, index)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { b.model }
	-- Window panes are solid parts (WindowGlass), so every ray through a window stops on the glass and
	-- the scan counts windows 0, measuring nothing about the openings. They must be taken out of the
	-- rays' way and put back after.
	--
	-- DETACHED, not CanQuery = false: this scan's RaycastParams uses an INCLUDE filter on the model,
	-- and measurement (tools/wallscan_probe.lua) shows a CanQuery = false part inside that filter is
	-- still hit — 400 rays landed on hidden panes. Unparenting takes them out of the filter itself,
	-- which nothing can ignore. The same mistake defeated this scan's own self-test below.
	local panes = {}
	for _, p in ipairs(b.model:GetDescendants()) do
		if p:IsA("BasePart") and p.Name == "WindowGlass" then
			table.insert(panes, { part = p, parent = p.Parent })
			p.Parent = nil
		end
	end
	local faces = {
		-- `span` is how far along the face to sample, and it stops at the wall's OWN extent. The front
		-- and back walls run the full width; the side walls fit BETWEEN them, so their ends are TW/2
		-- short. Sampling past those ends (it used to add WH) puts rays through the corner, where the
		-- face being tested has already finished and the perpendicular wall carries the structure: with
		-- the ray stopping a hair short of the inner face those columns read as 264 full-height "holes"
		-- 0.75 wide, every one of them a corner. A gap where two walls meet is a corner problem, not a
		-- hole in a wall panel.
		{ name = "front", n = Vector3.new(0, 0, -1), a = Vector3.new(1, 0, 0), dist = b.halfD, span = b.halfW - 0.02 },
		{ name = "back", n = Vector3.new(0, 0, 1), a = Vector3.new(1, 0, 0), dist = b.halfD, span = b.halfW - 0.02 },
		{ name = "left", n = Vector3.new(-1, 0, 0), a = Vector3.new(0, 0, 1), dist = b.halfW, span = b.halfD - TW / 2 - 0.02 },
		{ name = "right", n = Vector3.new(1, 0, 0), a = Vector3.new(0, 0, 1), dist = b.halfW, span = b.halfD - TW / 2 - 0.02 },
	}
	local house = b.archetype == "house"
	local stepA, stepH = 0.25, 0.5
	local windows, doors, odd = 0, 0, 0
	for _, f in ipairs(faces) do
		local open = {}
		local na = math.floor(2 * f.span / stepA)
		local topH = house and (f.name == "left" or f.name == "right") and b.topY + PITCH * b.halfD or b.topY
		local nh = math.floor((topH - 0.63) / stepH)
		for i = 0, na do
			local a = -f.span + 0.013 + i * stepA
			for j = 0, nh do
				local h = 0.63 + j * stepH
				local limit
				if house and (f.name == "left" or f.name == "right") and math.abs(a) < b.halfD - WH then
					limit = b.topY + PITCH * (b.halfD - math.abs(a)) - 0.9
				elseif house then
					limit = b.topY - 0.3
				else
					limit = b.topY - 0.6
				end
				if h <= limit then
					-- Through the WALL BAND only: from 0.75 outside its centre line to a hair SHORT of its
					-- inner face (the wall is TW thick, so its faces are at +-TW/2). A missing panel still
					-- reads as open, because then nothing blocks the ray at all.
					--
					-- It used to run 0.95 inside — 0.25 PAST the inner face — so an interior partition
					-- standing against the shell was hit through its own window and reported as a hole in
					-- the wall: 44 of them on SahurSprings, all in the window band, all on towers wide
					-- enough to have a partition. Ending exactly ON the inner face still grazed the
					-- partition's end (36 left), because the partition stops PARTITION_WALL_GAP short of
					-- that same plane. What stands behind a window is not a hole in the wall.
					local o = f.n * (f.dist + 0.75) + f.a * a + Vector3.new(0, h, 0)
					local e = f.n * (f.dist - (TW / 2 - 0.02)) + f.a * a + Vector3.new(0, h, 0)
					local wo, we = b.frame * o, b.frame * e
					if not workspace:Raycast(wo, we - wo, params) then
						open[i .. "," .. j] = true
					end
				end
			end
		end
		for _, c in ipairs(H.components(open, stepA, stepH, -f.span + 0.013, 0.63)) do
			local w = c.a1 - c.a0 + stepA
			local hgt = c.b1 - c.b0 + stepH
			local floor = math.floor((c.b0 + 0.2) / b.fh)
			local rel0, rel1 = c.b0 - floor * b.fh, c.b1 + stepH - floor * b.fh
			local isWindow = w > 4.4 and w < 5.6 and rel0 > 3.9 and rel0 < 4.7 and rel1 > 8.6 and rel1 < 9.6
			local isDoor = f.name == "front" and floor == 0 and w > 7.4 and w < 8.6 and rel0 < 1 and rel1 > 8.6 and rel1 < 9.6
			if isWindow then
				windows += 1
			elseif isDoor then
				doors += 1
			else
				odd += 1
				-- The brackets matter: without them this reads as `(f.name == "left") or (...)`, which is
				-- `true` on a side face, and `b[true]` is nil. It never fired while the scan was blind,
				-- because no odd hole was ever found to report.
				local half = (f.name == "left" or f.name == "right") and b.halfW or b.halfD
				local mid = b.frame * (f.n * half + f.a * ((c.a0 + c.a1) / 2) + Vector3.new(0, (c.b0 + c.b1) / 2, 0))
				example("wallHole", string.format("%s #%d %s yaw %.0f %dx%d %s face, floor %d: open %.2f wide x %.2f tall, along %.2f..%.2f, %.2f..%.2f above floor, %d cells, world %s",
					mapId, index, b.archetype, b.yaw, b.width, b.depth, f.name, floor, w, hgt, c.a0, c.a1 + stepA, rel0, rel1, c.n, v3(mid)), 12)
			end
		end
	end
	for _, p in ipairs(panes) do
		p.part.Parent = p.parent
	end
	bump("panes", #panes)
	bump("windows", windows)
	bump("doors", doors)
	bump("wallHoles", odd)
end

-- Roof: rays from high above to just under the ceiling line.
function H.scanRoof(b, mapId, index)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { b.model }
	local step = 0.5
	local open = {}
	local nx, nz = math.floor((b.width - 1.6) / step), math.floor((b.depth - 1.6) / step)
	for i = 0, nx do
		for j = 0, nz do
			local x, z = -b.halfW + 0.8 + i * step, -b.halfD + 0.8 + j * step
			local from = b.frame * Vector3.new(x, b.topY + 40, z)
			local to = b.frame * Vector3.new(x, b.topY - 1, z)
			if not workspace:Raycast(from, to - from, params) then
				open[i .. "," .. j] = true
			end
		end
	end
	for _, c in ipairs(H.components(open, step, step, -b.halfW + 0.8, -b.halfD + 0.8)) do
		bump("roofHoles")
		example("roofHole", string.format("%s #%d %s %dx%d: open %d cells x %.1f..%.1f z %.1f..%.1f", mapId, index, b.archetype, b.width, b.depth, c.n, c.a0, c.a1, c.b0, c.b1), 8)
	end
end

-- The doorway threshold: is there anything under the door opening, between the step and the floor?
function H.threshold(b, mapId, index)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { b.model }
	local open, total = 0, 0
	for x = -3.75, 3.75, 0.5 do
		for z = -b.halfD - 0.6, -b.halfD + 0.6, 0.3 do
			total += 1
			local from = b.frame * Vector3.new(x, 1.2, z)
			if not workspace:Raycast(from, Vector3.new(0, -1.6, 0), params) then
				open += 1
			end
		end
	end
	if open > 0 then
		bump("thresholdOpenBuildings")
		local door = b.frame * Vector3.new(0, 0, -b.halfD)
		-- GroundHeightAt returns nil where there's no solid ground (claude-79's contract), so the
		-- message says "no ground" rather than erroring on a nil.
		local ground = MapGenerator.GroundHeightAt(door.X, door.Z)
		example("threshold", string.format("%s #%d %s: %d of %d samples under the doorway hit no part; terrain there at y %s vs floor top 0.5 and step top 0.3, world %s",
			mapId, index, b.archetype, open, total, ground and string.format("%.2f", ground) or "nil (no ground)", v3(door)), 3)
	end
end

-- Stairs, partitions, loot on unreachable floors, ceiling lights, chimneys.
function H.interior(b, mapId, index, info)
	local model = b.model
	local stairs, walls, lights, bricks, crates = {}, {}, {}, {}, {}
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") then
			if p.Name == "Crate" then
				table.insert(crates, p)
			end
			if p.Name == "Stair" then
				table.insert(stairs, p)
			elseif p.Name == "Wall" then
				table.insert(walls, p)
			elseif p.Name == "CeilingLight" then
				table.insert(lights, p)
			elseif p.Name == "Chimney" then
				-- Named since the chimney fix; the old unnamed brick column below is the fallback.
				table.insert(bricks, p)
				bump("chimneysByName")
			elseif p.Material == Enum.Material.Brick and math.abs(p.Size.Y - 12) < 0.2 then
				table.insert(bricks, p)
				bump("chimneysBySize")
			end
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { model }

	-- Loot inside this footprint above the ground floor, split into floors and roof.
	local upperLoot, roofLoot = 0, 0
	local function count(pos)
		local l = b.frame:PointToObjectSpace(pos)
		if math.abs(l.X) < b.halfW and math.abs(l.Z) < b.halfD then
			if pos.Y > b.topY - 0.5 then
				roofLoot += 1
			elseif pos.Y > 10 then
				upperLoot += 1
			end
		end
	end
	for _, cf in ipairs(info.chestSpots) do
		count(cf.Position)
	end
	for _, kind in ipairs({ "weapon", "heal", "item" }) do
		for _, pos in ipairs(info.lootSpots[kind]) do
			count(pos)
		end
	end
	if b.floors > 1 then
		bump("multiFloor")
		if #stairs == 0 then
			bump("noStairs")
			bump("noStairsLoot", upperLoot)
			example("noStairs", string.format("%s #%d %s %dx%d, %d floors, no stairs; %d chest/loot spots on upper floors, world %s",
				mapId, index, b.archetype, b.width, b.depth, b.floors, upperLoot, v3(b.frame.Position)), 4)
		end
	end
	if b.archetype ~= "house" then
		bump("flatRoofs")
		bump("flatRoofLoot", roofLoot)
	end

	-- Each flight: stair parts per floor.
	local flights = {}
	for _, s in ipairs(stairs) do
		local f = math.floor((s.Position.Y - 0.5) / b.fh)
		flights[f] = flights[f] or {}
		table.insert(flights[f], s)
	end
	for f, steps in pairs(flights) do
		bump("flights")
		local base = f * b.fh + 0.5
		-- Landing at the foot (between the back wall and the first step).
		local foot = b.frame * Vector3.new(-b.halfW + 5, base + 1.5, -b.halfD + 2.35)
		local hit = workspace:Raycast(foot, Vector3.new(0, -3, 0), params)
		if not hit then
			bump("footNoFloor")
			local deep = workspace:Raycast(foot, Vector3.new(0, -40, 0), params)
			example("footNoFloor", string.format("%s #%d %s floor %d: nothing under the landing at the foot of the flight (drop %.1f), world %s",
				mapId, index, b.archetype, f, deep and (foot.Y - 1.5 - deep.Position.Y) or -1, v3(foot)), 3)
		end
		-- The only floor you could walk on to reach the first step: the side slab, 1 stud across a gap.
		local side = b.frame * Vector3.new(-b.halfW + 9.5, base + 1.5, -b.halfD + 6)
		if not workspace:Raycast(side, Vector3.new(0, -3, 0), params) then
			bump("sideGap")
		end
		-- Gap between the top step and the floor above.
		local topGap = b.frame * Vector3.new(-b.halfW + 5, base + b.fh + 1.5, -b.halfD + 19.5)
		if not workspace:Raycast(topGap, Vector3.new(0, -3, 0), params) then
			bump("topGap")
		end
		-- Headroom over every step and the way off the top.
		local blocked = {}
		for _, s in ipairs(steps) do
			local top = s.CFrame * CFrame.new(0, s.Size.Y / 2 + 2.85, 0)
			for _, hitPart in ipairs(H.boxHits(top, Vector3.new(s.Size.X - 0.4, 5.5, s.Size.Z - 0.1), { model })) do
				if hitPart.CanCollide and hitPart.Name ~= "Stair" then
					blocked[hitPart.Name] = (blocked[hitPart.Name] or 0) + 1
				end
			end
		end
		local exit = b.frame * CFrame.new(-b.halfW + 5, base + b.fh + 2.85, -b.halfD + 21.5)
		for _, hitPart in ipairs(H.boxHits(exit, Vector3.new(7.6, 5.5, 3.6), { model })) do
			if hitPart.CanCollide and hitPart.Name ~= "Stair" then
				blocked["exit:" .. hitPart.Name] = (blocked["exit:" .. hitPart.Name] or 0) + 1
			end
		end

		-- "Stairs that lead up to walls that block their way" (Oliver, 2026-09-18), measured on its own
		-- rather than inferred from the headroom box: stand at the top step, at chest height, and walk
		-- forward a stud. Anything solid there is a wall across the way off the flight.
		bump("stairTops")
		local topStand = b.frame * CFrame.new(-b.halfW + 5, base + b.fh + 3, -b.halfD + 20)
		local ahead = topStand * CFrame.new(0, 0, 1.4)
		for _, hitPart in ipairs(H.boxHits(ahead, Vector3.new(6, 5, 1.2), { model })) do
			if hitPart.CanCollide and hitPart.Name ~= "Stair" then
				bump("stairTopsIntoWall")
				example("stairTopIntoWall", string.format("%s #%d %s %dx%d floor %d: the way off the top of the flight is blocked by %s, world %s",
					mapId, index, b.archetype, b.width, b.depth, f, hitPart.Name, v3(ahead.Position)), 6)
				break
			end
		end
		local names = {}
		for name, n in pairs(blocked) do
			table.insert(names, name .. " x" .. n)
		end
		if #names > 0 then
			bump("blockedFlights")
			example("blockedFlight", string.format("%s #%d %s %dx%d floor %d: flight headroom/exit blocked by %s, world %s",
				mapId, index, b.archetype, b.width, b.depth, f, table.concat(names, ", "), v3(b.frame * Vector3.new(-b.halfW + 5, base, -b.halfD + 12))), 6)
		end
	end

	-- Partitions: interior walls (not on the shell). Gaps to the side walls and to the ceiling.
	for _, w in ipairs(walls) do
		local l = b.frame:PointToObjectSpace(w.Position)
		if math.abs(math.abs(l.Z) - b.halfD) > 1 and math.abs(math.abs(l.X) - b.halfW) > 1 then
			local rel = b.frame.Rotation:Inverse() * w.CFrame.Rotation
			local len = math.abs(rel.RightVector.X) > 0.5 and w.Size.X or w.Size.Z
			if len > 4 then
				local endGap = (b.halfW - WH) - (math.abs(l.X) + len / 2)
				if endGap > 0.05 then
					bump("partitionEndGaps")
					totals.partitionEndGapMax = math.max(totals.partitionEndGapMax or 0, endGap)
				end
			end
		end
	end

	-- Ceiling lights with nothing within half a stud above them.
	for _, light in ipairs(lights) do
		local from = light.Position + Vector3.new(0, light.Size.Y / 2 + 0.02, 0)
		local up = workspace:Raycast(from, Vector3.new(0, 12, 0), params)
		local gap = up and (up.Position.Y - from.Y) or 12
		if gap > 0.5 then
			bump("floatingLights")
			example("floatingLight", string.format("%s #%d %s: ceiling light %.2f below the nearest thing above it, world %s", mapId, index, b.archetype, gap, v3(light.Position)), 3)
		end
	end
	-- Chimneys seen from inside: look straight up from under the roof at the centre and four
	-- corners of each chimney's footprint. Where the chimney is the first thing hit, it shows
	-- below the roof; how far is the gap between its bottom and the roof underside there.
	-- Crate stacks: through the ceiling into the room above, hanging in the air, or sunk into each
	-- other. Each crate used to be placed by its own size alone, rather than on the one below it.
	for _, crate in ipairs(crates) do
		bump("crates")
		local bottom = crate.Position.Y - crate.Size.Y / 2
		local top = crate.Position.Y + crate.Size.Y / 2
		local f = math.floor((bottom - 0.5 + 0.05) / b.fh)
		local ceiling = (f + 1) * b.fh - 0.5
		if not (b.archetype == "house" and f == b.floors - 1) and top > ceiling + 0.01 then
			bump("cratesThroughCeiling")
			example("crateCeiling", string.format("%s #%d %s floor %d: crate top %.2f, ceiling %.2f (%.2f through), world %s",
				mapId, index, b.archetype, f, top, ceiling, top - ceiling, v3(crate.Position)), 4)
		end
		local downParams = RaycastParams.new()
		downParams.FilterType = Enum.RaycastFilterType.Include
		downParams.FilterDescendantsInstances = { model }
		local saved = crate.CanQuery
		crate.CanQuery = false
		local under = workspace:Raycast(Vector3.new(crate.Position.X, bottom + 0.05, crate.Position.Z), Vector3.new(0, -0.3, 0), downParams)
		crate.CanQuery = saved
		if not under then
			bump("cratesFloating")
			example("crateFloating", string.format("%s #%d %s floor %d: crate (size %.0f) with nothing within 0.25 under its centre, world %s",
				mapId, index, b.archetype, f, crate.Size.Y, v3(crate.Position)), 4)
		end
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Include
		overlap.FilterDescendantsInstances = crates
		for _, other in ipairs(workspace:GetPartBoundsInBox(crate.CFrame, crate.Size - Vector3.new(0.2, 0.2, 0.2), overlap)) do
			if other ~= crate then
				bump("crateOverlapPairs")
				break
			end
		end
	end
	for _, chimney in ipairs(bricks) do
		local bottom = chimney.Position.Y - chimney.Size.Y / 2
		local exposed = 0
		local roofOnly = RaycastParams.new()
		roofOnly.FilterType = Enum.RaycastFilterType.Include
		local others = {}
		for _, p in ipairs(model:GetChildren()) do
			if p:IsA("BasePart") and p ~= chimney then
				table.insert(others, p)
			end
		end
		roofOnly.FilterDescendantsInstances = others
		local half = chimney.Size / 2 - Vector3.new(0.1, 0, 0.1)
		for _, corner in ipairs({ Vector3.zero, Vector3.new(half.X, 0, half.Z), Vector3.new(-half.X, 0, half.Z), Vector3.new(half.X, 0, -half.Z), Vector3.new(-half.X, 0, -half.Z) }) do
			local point = chimney.CFrame * Vector3.new(corner.X, 0, corner.Z)
			local from = Vector3.new(point.X, b.topY - 0.8, point.Z)
			local first = workspace:Raycast(from, Vector3.new(0, 40, 0), params)
			if first and first.Instance == chimney then
				local roof = workspace:Raycast(from, Vector3.new(0, 40, 0), roofOnly)
				exposed = math.max(exposed, roof and (roof.Position.Y - first.Position.Y) or 0)
			end
		end
		if exposed > 0.05 or bottom < b.topY + 0.5 then
			bump("chimneyStubs")
			example("chimney", string.format("%s #%d %s: chimney bottom at y %.2f (top-floor wall tops %.2f); shows %.2f below the roof underside from inside, world %s",
				mapId, index, b.archetype, bottom, b.topY + 0.5, exposed, v3(chimney.Position)), 2)
		end
	end
end

-- Every loot spot: pad bottom against the surface under it, and solid parts inside the pickup's volume.
function H.spots(info, mapId)
	local map = workspace:FindFirstChild("Map")
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { map, workspace.Terrain }
	rayParams.IgnoreWater = false
	local function ownerOf(part)
		local node = part
		while node and node.Parent and node.Parent ~= map do
			if node:IsA("Model") and node.Parent and node.Parent.Name == "Town" then
				return node.Name
			end
			node = node.Parent
		end
		return node and node.Name or "?"
	end
	for _, kind in ipairs({ "weapon", "heal", "item" }) do
		for _, spot in ipairs(info.lootSpots[kind]) do
			bump("spots")
			local padBottom = spot.Y + 0.115
			local hit = workspace:Raycast(spot + Vector3.new(0, 2.5, 0), Vector3.new(0, -8, 0), rayParams)
			if not hit then
				bump("spotNoGround")
				example("spotNoGround", string.format("%s %s spot %s: no surface within 5.5 below", mapId, kind, v3(spot)), 4)
			else
				local gap = padBottom - hit.Position.Y
				local what = hit.Instance == workspace.Terrain and ("terrain " .. hit.Material.Name) or (hit.Instance.Name .. " in " .. ownerOf(hit.Instance))
				if gap > 0.3 then
					bump("spotFloating")
					-- Banded, because one count cannot be acted on: a 0.4 gap over terrain is a voxel
					-- surface reading a hair low and nobody will ever see it, while a 3.9 gap is a gun
					-- hanging at chest height over open grass. The bands are what says which this is,
					-- and `spotFloatOnTerrain` says whether the thing underneath was terrain at all.
					bump(gap > 1.5 and "spotFloatOver1_5" or (gap > 0.6 and "spotFloat0_6to1_5" or "spotFloat0_3to0_6"))
					if hit.Instance == workspace.Terrain then
						bump("spotFloatOnTerrain")
					end
					totals.spotFloatMax = math.max(totals.spotFloatMax or 0, gap)
					example("spotFloating", string.format("%s %s spot %s: pad bottom %.2f above %s", mapId, kind, v3(spot), gap, what), 6)
					if gap > 1.5 then
						example("spotFloatBad", string.format("%s %s spot %s: pad bottom %.2f above %s", mapId, kind, v3(spot), gap, what), 12)
					end
				elseif gap < -0.08 then
					bump("spotSunk")
					totals.spotSinkMax = math.max(totals.spotSinkMax or 0, -gap)
					example("spotSunk", string.format("%s %s spot %s: pad bottom %.2f below the top of %s", mapId, kind, v3(spot), -gap, what), 6)
				end
			end
			local blockers = {}
			for _, part in ipairs(H.boxHits(CFrame.new(spot + Vector3.new(0, 1.6, 0)), Vector3.new(2.2, 2.4, 2.2), { map })) do
				if part.CanCollide and part.Transparency < 0.9 then
					blockers[part.Name .. " in " .. ownerOf(part)] = true
				end
			end
			local list = {}
			for name in pairs(blockers) do
				table.insert(list, name)
			end
			if #list > 0 then
				bump("spotBlocked")
				example("spotBlocked", string.format("%s %s spot %s: pickup volume overlaps %s", mapId, kind, v3(spot), table.concat(list, ", ")), 10)
			end
		end
	end
	for _, cf in ipairs(info.chestSpots) do
		bump("chests")
		local hit = workspace:Raycast(cf.Position + Vector3.new(0, 3, 0), Vector3.new(0, -40, 0), rayParams)
		local floor = hit and hit.Position or cf.Position - Vector3.new(0, 2, 0)
		if not hit then
			bump("chestNoGround")
		end
		local blockers = {}
		for _, part in ipairs(H.boxHits(CFrame.new(floor) * cf.Rotation * CFrame.new(0, 1.45, 0), Vector3.new(3.4, 2.4, 2.4), { map })) do
			if part.CanCollide and part.Transparency < 0.9 then
				blockers[part.Name .. " in " .. ownerOf(part)] = true
			end
		end
		local list = {}
		for name in pairs(blockers) do
			table.insert(list, name)
		end
		if #list > 0 then
			bump("chestBlocked")
			example("chestBlocked", string.format("%s chest at %s (snapped floor y %.2f): overlaps %s", mapId, v3(cf.Position), floor.Y, table.concat(list, ", ")), 8)
		end
	end
end

-- Death drops next to walls and on roof edges, through the real LootService.DropWeapon.
function H.drops(buildings, mapId)
	local loot = workspace:FindFirstChild("Loot")
	local function newest(before)
		local folder = workspace:FindFirstChild("Loot")
		for _, child in ipairs(folder and folder:GetChildren() or {}) do
			if not before[child] then
				return child
			end
		end
	end
	local function snapshot()
		local set = {}
		local folder = workspace:FindFirstChild("Loot")
		for _, child in ipairs(folder and folder:GetChildren() or {}) do
			set[child] = true
		end
		return set
	end
	local roofTried, roofAir, roofGround = 0, 0, 0
	local wallTried, wallOutside, wallInWall = 0, 0, 0
	for index, b in ipairs(buildings) do
		if index > 30 then
			break
		end
		if b.archetype ~= "house" then
			-- A death 1.5 studs inside the parapet, halfway along the front, at waist height.
			for _ = 1, 8 do
				local before = snapshot()
				LootService.DropItem("Bandage", b.frame * Vector3.new(0, b.topY + 3.5, -b.halfD + 1.5), 1)
				local pickup = newest(before)
				if pickup then
					roofTried += 1
					local l = b.frame:PointToObjectSpace(pickup.Position)
					if math.abs(l.X) > b.halfW + 0.5 or math.abs(l.Z) > b.halfD + 0.5 then
						if pickup.Position.Y > 3 then
							roofAir += 1
							example("roofDropAir", string.format("%s %s %d floors: a drop by the parapet landed outside the roof at y %.1f with the ground at y ~0, world %s",
								mapId, b.archetype, b.floors, pickup.Position.Y, v3(pickup.Position)), 3)
						else
							roofGround += 1
						end
					end
					pickup:Destroy()
				end
			end
		end
		-- A death 1 stud inside the back wall on the ground floor.
		for _ = 1, 6 do
			local before = snapshot()
			LootService.DropItem("Bandage", b.frame * Vector3.new(0, 3.5, b.halfD - WH - 1), 1)
			local pickup = newest(before)
			if pickup then
				wallTried += 1
				local l = b.frame:PointToObjectSpace(pickup.Position)
				if math.abs(l.Z) > b.halfD + WH or math.abs(l.X) > b.halfW + WH then
					wallOutside += 1
				elseif math.abs(l.Z) > b.halfD - WH - 1.4 then
					wallInWall += 1
				end
				pickup:Destroy()
			end
		end
	end
	out("%s drops: roof-edge drops %d, landed in mid-air outside the building %d, on the ground outside %d; drops 1 stud inside a back wall %d, went through to the outside %d, pad overlapping the wall %d",
		mapId, roofTried, roofAir, roofGround, wallTried, wallOutside, wallInWall)
end

for _, entry in ipairs(MAPS) do
	local mapId, seed = entry[1], entry[2]
	totals, examples = {}, {}
	math.randomseed(seed)
	local started = os.clock()
	local okBuild, info = pcall(MapGenerator.Build, mapId)
	if not okBuild then
		out("%s build failed: %s", mapId, tostring(info))
		continue
	end
	task.wait(1.5)
	out("%s seed %d built in %.1fs: %d chests, %d weapon, %d heal, %d item spots", mapId, seed, os.clock() - started,
		#info.chestSpots, #info.lootSpots.weapon, #info.lootSpots.heal, #info.lootSpots.item)

	local buildings, counts = {}, {}
	for _, town in ipairs(workspace.Map:GetChildren()) do
		if town.Name == "Town" then
			for _, child in ipairs(town:GetChildren()) do
				if child:IsA("Model") and (child.Name == "house" or child.Name == "tower" or child.Name == "warehouse") then
					local b = H.frameOf(child)
					if b then
						table.insert(buildings, b)
						counts[b.archetype] = (counts[b.archetype] or 0) + 1
					end
				end
			end
		end
	end
	out("%s buildings: %d (houses %d, towers %d, warehouses %d)", mapId, #buildings, counts.house or 0, counts.tower or 0, counts.warehouse or 0)

	-- The self-tests below rescan a building two or three extra times, which bumps every counter
	-- those scans touch -- not just the one being tested. Restoring the tested key alone left the
	-- rest inflated: the 2026-09-18 landed run printed `blockedFlights=1` whose only example was the
	-- test's own SelfTestSeal, which reads as a real defect and isn't one. So the whole of `totals`
	-- and `examples` is snapshotted here and put back afterwards: the numbers reported are the map's
	-- as built, and a self-test can never invent one.
	local savedTotals, savedExamples = {}, {}
	for key, value in pairs(totals) do
		savedTotals[key] = value
	end
	for key, list in pairs(examples) do
		savedExamples[key] = { table.unpack(list) }
	end
	local function restoreCounts()
		for key in pairs(totals) do
			totals[key] = savedTotals[key]
		end
		for key in pairs(examples) do
			examples[key] = savedExamples[key]
		end
	end

	-- Self-test: the wall scan must actually see a hole. One solid wall part of the first building is
	-- taken out of the rays' way (as a missing panel would be), that building is rescanned, and the
	-- odd-hole count has to rise. Everything is put back and the test's own counts are taken off the
	-- totals, so the numbers reported below are the map's, not the test's.
	if buildings[1] then
		local b = buildings[1]
		local hidden = nil
		for _, part in ipairs(b.model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == "Wall" and part.CanQuery and part.Size.Y > 3 then
				hidden = part
				break
			end
		end
		if not hidden then
			out("%s wall-scan self-test: no wall part to hide; SKIPPED", mapId)
		else
			local baseline = totals.wallHoles or 0
			H.scanWalls(b, mapId, 0)
			local unchanged = (totals.wallHoles or 0) - baseline
			-- Detached, not CanQuery = false: with this scan's include filter a flagged part is still
			-- hit, so the old version of this test "removed" a panel that was never out of the way and
			-- could not fail whatever the scan did. Measured in tools/wallscan_probe.lua.
			local wasParent = hidden.Parent
			hidden.Parent = nil
			H.scanWalls(b, mapId, 0)
			local withHole = (totals.wallHoles or 0) - baseline - unchanged
			hidden.Parent = wasParent
			out("%s wall-scan self-test: %d odd holes as built, %d with one wall panel taken out -> %s",
				mapId, unchanged, withHole, withHole > unchanged and "PASS" or "FAIL")
		end

		-- Self-test for the stairs check: seal the way off the top of a flight and it must be reported.
		-- A climbable building is needed, so the first one with stairs is used rather than the first one.
		local stairBuilding = nil
		for _, candidate in ipairs(buildings) do
			for _, part in ipairs(candidate.model:GetChildren()) do
				if not stairBuilding and part:IsA("BasePart") and part.Name == "Stair" then
					stairBuilding = candidate
				end
			end
		end
		if not stairBuilding then
			out("%s stairs self-test: no building with stairs; SKIPPED", mapId)
		else
			local sb = stairBuilding
			local baseTops = totals.stairTopsIntoWall or 0
			H.interior(sb, mapId, 0, info)
			local clean = (totals.stairTopsIntoWall or 0) - baseTops
			local seal = Instance.new("Part")
			seal.Name = "SelfTestSeal"
			seal.Size = Vector3.new(7, 6, 1)
			seal.CFrame = sb.frame * CFrame.new(-sb.halfW + 5, sb.fh + 3, -sb.halfD + 21.4)
			seal.Anchored = true
			seal.Transparency = 1
			seal.Parent = sb.model
			H.interior(sb, mapId, 0, info)
			local sealed = (totals.stairTopsIntoWall or 0) - baseTops - clean
			seal:Destroy()
			out("%s stairs self-test: %d blocked tops as built, %d with one flight's way off sealed -> %s",
				mapId, clean, sealed, sealed > clean and "PASS" or "FAIL")
		end
		-- Every counter and example the self-tests touched, back to what the map itself produced.
		restoreCounts()
	end

	local t0 = os.clock()
	for index, b in ipairs(buildings) do
		local okB, errB = pcall(function()
			H.scanWalls(b, mapId, index)
			H.scanRoof(b, mapId, index)
			H.threshold(b, mapId, index)
			H.interior(b, mapId, index, info)
		end)
		if not okB then
			out("%s building #%d failed: %s", mapId, index, tostring(errB))
		end
		task.wait()
	end
	out("%s building scan %.1fs", mapId, os.clock() - t0)
	local okS, errS = pcall(H.spots, info, mapId)
	if not okS then
		out("%s spot scan failed: %s", mapId, tostring(errS))
	end

	task.wait(1)
	local okD, errD = pcall(H.drops, buildings, mapId)
	if not okD then
		out("%s drops failed: %s", mapId, tostring(errD))
	end

	local keys = {}
	for key in pairs(totals) do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, string.format("%s=%s", key, type(totals[key]) == "number" and (totals[key] % 1 == 0 and tostring(totals[key]) or string.format("%.2f", totals[key])) or tostring(totals[key])))
	end
	out("%s totals: %s", mapId, table.concat(parts, " "))
	local exKeys = {}
	for key in pairs(examples) do
		table.insert(exKeys, key)
	end
	table.sort(exKeys)
	for _, key in ipairs(exKeys) do
		for _, text in ipairs(examples[key]) do
			out("  %s: %s", key, text)
		end
	end
	LootService.Clear()
end
MapGenerator.Clear()
pcall(flush)
