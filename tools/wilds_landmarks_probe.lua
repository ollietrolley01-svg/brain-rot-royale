-- Landmark and monument probe: builds every entry in Landmarks.Registry (and the lighthouse) on its
-- own flat patch of terrain far off the map, and audits each.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/wilds_landmarks_probe.lua -WaitSeconds 400
--
-- Per piece: parts, how tall it stands (what reads on the skyline), chests and pickups it adds,
-- ladders, spinning groups, z-fight pairs (no z-fight pass runs here, so these are the builder's
-- own), parts floating free of anything that reaches the ground, chest and pickup spots inside a
-- part (SPOT CLASH) or with no floor just under them (SPOT FLOOR). Each piece is built turned, as
-- Place turns them. A last SelfTest piece plants one fault of each kind and must read CHECKS WORK.
-- Then per map: what its set adds in chests and pickups, counting its always pieces and the average
-- of its pool (each map places four, the coast five with the lighthouse).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local MapSpace = require(modules:WaitForChild("MapSpace"))
local Landmarks = require(modules:WaitForChild("Landmarks"))

local function out(fmt, ...)
	print("[Landmarks] " .. string.format(fmt, ...))
end

local stage = Instance.new("Folder")
stage.Name = "LandmarkProbe"
stage.Parent = workspace
local terrain = workspace.Terrain
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { terrain }
local function groundAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 600, z), Vector3.new(0, -1200, 0), params)
	return hit and hit.Position.Y
end

-- Whether a part, or anything it hangs from inside the model, is marked as floating on purpose.
local function intentional(part, model)
	local node = part
	while node and node ~= model do
		if node:GetAttribute("IntentionalFloat") then
			return true
		end
		node = node.Parent
	end
	return false
end

-- How far a part reaches below its centre: its world bounding box's half height, so a long beam
-- lying flat reaches its thickness down, not half its length.
local function halfHeight(part)
	local cf, size = part.CFrame, part.Size
	return (math.abs(cf.XVector.Y) * size.X + math.abs(cf.YVector.Y) * size.Y + math.abs(cf.ZVector.Y) * size.Z) / 2
end

-- Parts not connected (grown 0.05 each way) to anything whose bottom is at or under the ground.
-- Returns one line per loose group: how many parts, and the first few with their position relative
-- to `origin`, size, class and what they hang from. Every part's CanQuery is put back afterwards:
-- DestructibleService and LootService's rays both read it.
local function floating(model, origin)
	local parts = {}
	local wasQueryable = {}
	for _, d in ipairs(model:GetDescendants()) do
		-- The zipline lands a hundred studs away, past the edge of this stage's patch of ground, so on
		-- the stage it always reads as floating. Its own parts are checked by ZiplineService's owner.
		local onZipline = d:FindFirstAncestor("Zipline") ~= nil
		if d:IsA("BasePart") and d.Transparency < 0.98 and not onZipline and not intentional(d, model) then
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
	for _, part in ipairs(parts) do
		-- Was Size.Magnitude / 2 (the bounding sphere): any part as long as it was high counted as
		-- touching the ground, and everything joined to it with it.
		local bottom = part.Position.Y - halfHeight(part)
		local g = groundAt(part.Position.X, part.Position.Z)
		if g and bottom <= g + 0.3 then
			parent[find(part)] = find(GROUND)
		end
		local probe = part:Clone()
		probe:ClearAllChildren()
		probe.Size = part.Size + Vector3.new(0.1, 0.1, 0.1)
		probe.Transparency = 1
		probe.CanCollide = false
		probe.Parent = workspace
		for _, other in ipairs(workspace:GetPartsInPart(probe, overlap)) do
			if parent[other] then
				parent[find(other)] = find(part)
			end
		end
		probe:Destroy()
	end
	local groups = {}
	local grounded = find(GROUND)
	for _, part in ipairs(parts) do
		local root = find(part)
		if root ~= grounded then
			groups[root] = groups[root] or {}
			table.insert(groups[root], part)
		end
	end
	local list = {}
	for _, members in pairs(groups) do
		local shown = {}
		for index = 1, math.min(3, #members) do
			local part = members[index]
			local at = origin and origin:PointToObjectSpace(part.Position) or part.Position
			table.insert(shown, string.format("%s %s(%.1f,%.1f,%.1f) size(%.1f,%.1f,%.1f)%s under %s", part.Name,
				part:IsA("Part") and part.Shape.Name or part.ClassName, at.X, at.Y, at.Z, part.Size.X, part.Size.Y, part.Size.Z,
				part.CanCollide and "" or " soft", part.Parent and part.Parent.Name or "?"))
		end
		table.insert(list, string.format("%d parts: %s", #members, table.concat(shown, " | ")))
	end
	for part, value in pairs(wasQueryable) do
		part.CanQuery = value
	end
	return list
end

-- Every landmark is built turned by YAW, as Place turns them by a random one: anything square to the
-- world (a pickup's box, a terrain pad) only lines up with a landmark at yaw 0. Offsets in the report
-- are in the landmark's own frame, so they read straight against its builder.
local YAW = 0.6

local all = table.clone(Landmarks.Registry)
if Landmarks.Beacon then
	table.insert(all, Landmarks.Beacon)
else
	out("no Landmarks.Beacon: the lighthouse isn't audited")
end
-- Planted faults, built last. Each check must report exactly these, or it isn't checking anything:
--   floating  a small block hanging 10 studs over the ground, and a 30-stud beam lying flat 6 studs up
--             (the old bounding-sphere rule called the beam grounded);
--   spots     a chest spot beside a post standing on a plinth, and a pickup spot beside a wall.
local SELFTEST = { floating = 2, clashes = 2 }
table.insert(all, { id = "SelfTest", footprint = 24, build = function(model, origin, ctx)
	local function block(size, cframe)
		local p = Instance.new("Part")
		p.Anchored = true
		p.Size = size
		p.CFrame = cframe
		p.Parent = model
		return p
	end
	block(Vector3.new(8, 4, 8), origin * CFrame.new(0, 2, 0))
	block(Vector3.new(1, 6, 1), origin * CFrame.new(1.5, 7, 0))
	block(Vector3.new(1, 6, 8), origin * CFrame.new(-5.2, 3, 0))
	block(Vector3.new(4, 1, 4), origin * CFrame.new(12, 10, 0))
	block(Vector3.new(30, 1, 1), origin * CFrame.new(0, 6.5, 14))
	table.insert(ctx.chestSpots, origin * CFrame.new(0, 4.5, 0))
	table.insert(ctx.lootSpots.item, (origin * CFrame.new(-4.3, 1, 0)).Position)
end })
local stats = {}
local ORIGIN = Vector3.new(-5200, 0, 5200)
for index, landmark in ipairs(all) do
	local spot = ORIGIN + Vector3.new((index - 1) * 260, 0, 0)
	local size = landmark.footprint * 2 + 60
	terrain:FillBlock(CFrame.new(spot.X, -6, spot.Z), Vector3.new(size, 8, size), Enum.Material.Grass)
	task.wait()
	local model = Instance.new("Model")
	model.Name = landmark.id
	model.Parent = stage
	local ctx = { chestSpots = {}, lootSpots = { weapon = {}, heal = {}, item = {} }, space = MapSpace.new(), groundHeightAt = function(x, z)
		return groundAt(x, z) or 0
	end }
	local origin = CFrame.new(spot) * CFrame.Angles(0, YAW, 0)
	local started = os.clock()
	local ok, err = pcall(landmark.build, model, origin, ctx)
	local seconds = os.clock() - started
	if not ok then
		out("%-18s BUILD FAILED: %s", landmark.id, tostring(err))
	else
		local parts, trusses, top = 0, 0, -math.huge
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				parts += 1
				if d:IsA("TrussPart") then
					trusses += 1
				end
				top = math.max(top, d.Position.Y + d.Size.Magnitude / 2)
			end
		end
		-- How far the piece reaches from its middle, against the round pad the site is levelled to
		-- (footprint + 4) and the claim round it (footprint + 10). What matters for the claim is what
		-- stands on the ground: a crane's jib or a sail's tip can hang over a neighbour's ground
		-- harmlessly, so anything whose underside clears LOW is measured apart. The zipline is left
		-- out either way: it lands a hundred studs off on purpose.
		local LOW = 14
		local reachLow, reachAll = 0, 0
		local reachPart
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and not (d.Parent and d.Parent.Name == "Zipline") then
				local cf, half = d.CFrame, d.Size / 2
				local ex = math.abs(cf.XVector.X) * half.X + math.abs(cf.YVector.X) * half.Y + math.abs(cf.ZVector.X) * half.Z
				local ey = math.abs(cf.XVector.Y) * half.X + math.abs(cf.YVector.Y) * half.Y + math.abs(cf.ZVector.Y) * half.Z
				local ez = math.abs(cf.XVector.Z) * half.X + math.abs(cf.YVector.Z) * half.Y + math.abs(cf.ZVector.Z) * half.Z
				local at = origin:PointToObjectSpace(d.Position)
				local out_ = Vector2.new(math.abs(at.X) + ex, math.abs(at.Z) + ez).Magnitude
				reachAll = math.max(reachAll, out_)
				if d.Position.Y - ey < spot.Y + LOW and out_ > reachLow then
					reachLow, reachPart = out_, d
				end
			end
		end
		if landmark.footprint and reachLow > landmark.footprint + 4 then
			local at = reachPart and origin:PointToObjectSpace(reachPart.Position) or Vector3.new()
			out("%-18s REACH %.0f studs on the ground (%.0f in the air), past its %s (pad %d, claim %d): footprint %d; furthest %s(%.1f,%.1f,%.1f) at (%.0f,%.0f,%.0f)",
				landmark.id, reachLow, reachAll, reachLow > landmark.footprint + 10 and "CLAIM" or "pad", landmark.footprint + 4, landmark.footprint + 10,
				landmark.footprint, reachPart and reachPart.Name or "?", reachPart and reachPart.Size.X or 0, reachPart and reachPart.Size.Y or 0,
				reachPart and reachPart.Size.Z or 0, at.X, at.Y, at.Z)
		end
		local spinners = 0
		for _, tagged in ipairs(CollectionService:GetTagged("AmbientSpin")) do
			if tagged:IsDescendantOf(model) then
				spinners += 1
			end
		end
		local zipline = model:FindFirstChild("Zipline", true) ~= nil
		local flushPairs = ZFight.Scan({ model })
		local loose = floating(model, origin)
		local loot = #ctx.lootSpots.weapon + #ctx.lootSpots.heal + #ctx.lootSpots.item
		stats[landmark.id] = { chests = #ctx.chestSpots, loot = loot }
		out("%-18s parts %4d  top %5.0f  chests %d  loot %d (w%d h%d i%d)  ladders %d  spin %d  zip %s  flush %d%s  floating %d%s  %.2fs", landmark.id, parts, top,
			#ctx.chestSpots, loot, #ctx.lootSpots.weapon, #ctx.lootSpots.heal, #ctx.lootSpots.item, trusses, spinners, tostring(zipline), #flushPairs,
			#flushPairs > 0 and (" [" .. table.concat(ZFight.Describe(flushPairs, function(p)
				-- Parts named by size and parent, since most landmark parts are just "Part".
				return string.format("%s%s(%.1f,%.1f,%.1f)", p.Parent and p.Parent.Name == "Zipline" and "zip:" or "", p.ClassName == "Part" and p.Shape.Name or p.ClassName,
					p.Size.X, p.Size.Y, p.Size.Z)
			end, 8), " | ") .. "]") or "", #loose,
			#loose > 0 and (" [" .. table.concat(loose, " ; "):sub(1, 1500) .. "]") or "", seconds)
		-- Chests and pickups standing clear: a chest is CrateModels.Chest's whole extent on the floor
		-- under its spot, a pickup a 2-stud cube; neither may be inside any of the landmark's parts,
		-- soft ones included (a chest through a seat reads as broken).
		local clashes, floorProblems = {}, {}
		do
			-- 1. Every spot's floor, the way LootService finds it (a ray from 3 above the spot, 40 straight
			-- down, Map and Terrain), while every part's CanQuery is still what the builder set: a decor
			-- rug is invisible to that ray in the game, so it must be here.
			local floorParams = RaycastParams.new()
			floorParams.FilterType = Enum.RaycastFilterType.Include
			floorParams.FilterDescendantsInstances = { model, terrain }
			local spots = {}
			for _, chest in ipairs(ctx.chestSpots) do
				table.insert(spots, { kind = "chest", cframe = chest, size = Vector3.new(3.72, 2.3, 2.84) })
			end
			for _, kind in ipairs({ "weapon", "heal", "item" }) do
				for _, point in ipairs(ctx.lootSpots[kind]) do
					table.insert(spots, { kind = kind, cframe = CFrame.new(point), size = Vector3.new(2, 2, 2) })
				end
			end
			for _, entry in ipairs(spots) do
				entry.floor = workspace:Raycast(entry.cframe.Position + Vector3.new(0, 3, 0), Vector3.new(0, -40, 0), floorParams)
				entry.floorY = entry.floor and entry.floor.Position.Y or entry.cframe.Position.Y - 2
				-- The floor should be just under the spot: above it means the ray landed on something over
				-- the spot (the chest ends up on that), far below means there's nothing to stand on.
				local at = origin:PointToObjectSpace(entry.cframe.Position)
				local drop = entry.cframe.Position.Y - entry.floorY
				if not entry.floor or drop < -0.3 or drop > 3 then
					table.insert(floorProblems, string.format("%s at (%.1f,%.1f,%.1f): floor %s", entry.kind, at.X, at.Y, at.Z,
						entry.floor and string.format("%.1f %s the spot on %s", math.abs(drop), drop < 0 and "above" or "below", entry.floor.Instance.Name) or "none within 40"))
				end
			end

			-- 2. Overlaps against every part, soft ones included (GetPartsInPart skips CanQuery = false, so
			-- it's set for the test and put back after).
			local partsOf, wasQueryable = {}, {}
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and not (d.Parent and d.Parent.Name == "Zipline") then
					wasQueryable[d] = d.CanQuery
					d.CanQuery = true
					table.insert(partsOf, d)
				end
			end
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Include
			overlapParams.FilterDescendantsInstances = partsOf
			for _, entry in ipairs(spots) do
				local size, floor, floorY = entry.size, entry.floor, entry.floorY
				local box = Instance.new("Part")
				box.Anchored = true
				box.CanCollide = false
				box.Transparency = 1
				-- Shrunk a hair so a chest resting on a floor or against a wall doesn't count.
				box.Size = size - Vector3.new(0.2, 0.2, 0.2)
				-- A pickup's box is square to the world: on a tilted deck its corners would dip into the boards,
				-- so it's lifted by how far a corner drops over the slope.
				local lift = 0
				if entry.kind ~= "chest" and floor and floor.Normal.Y > 0.2 then
					lift = size.X / 2 * math.sqrt(2) * math.sqrt(1 - floor.Normal.Y ^ 2) / floor.Normal.Y
				end
				box.CFrame = CFrame.new(entry.cframe.X, floorY + lift, entry.cframe.Z) * entry.cframe.Rotation * CFrame.new(0, size.Y / 2, 0)
				box.Parent = workspace
				local found = workspace:GetPartsInPart(box, overlapParams)
				box:Destroy()
				-- Ankle-deep non-colliding ground cover under a spot isn't a clash: a dusting of snow, the
				-- film of water in an aqueduct's channel, flattened crop, a scorch mark. Anything soft and
				-- taller than that (a row of corn, a seat back) still counts.
				local hits = {}
				for _, h in ipairs(found) do
					if h.CanCollide or h.Position.Y + halfHeight(h) > floorY + 0.9 then
						table.insert(hits, h)
					end
				end
				if #hits > 0 then
					local at = origin:PointToObjectSpace(entry.cframe.Position)
					local names = {}
					for index = 1, math.min(3, #hits) do
						local h = hits[index]
						local hAt = origin:PointToObjectSpace(h.Position)
						table.insert(names, string.format("%s(%.1f,%.1f,%.1f) at (%.1f,%.1f,%.1f)%s", h.ClassName == "Part" and h.Shape.Name or h.ClassName,
							h.Size.X, h.Size.Y, h.Size.Z, hAt.X, hAt.Y, hAt.Z, wasQueryable[h] == false and " soft" or ""))
					end
					table.insert(clashes, string.format("%s at (%.1f,%.1f,%.1f) hits %s", entry.kind, at.X, at.Y, at.Z, table.concat(names, ", ")))
				end
			end
			for part, value in pairs(wasQueryable) do
				part.CanQuery = value
			end
		end
		if #clashes > 0 then
			out("%-18s SPOT CLASH %d: %s", landmark.id, #clashes, table.concat(clashes, " | "))
		end
		if #floorProblems > 0 then
			out("%-18s SPOT FLOOR %d: %s", landmark.id, #floorProblems, table.concat(floorProblems, " | "))
		end
		if landmark.id == "SelfTest" then
			out("SELFTEST floating groups %d (planted %d), spot clashes %d (planted %d), floor problems %d (planted 0): %s", #loose, SELFTEST.floating,
				#clashes, SELFTEST.clashes, #floorProblems,
				(#loose == SELFTEST.floating and #clashes == SELFTEST.clashes and #floorProblems == 0) and "CHECKS WORK" or "CHECKS BROKEN")
		end
		-- The zipline's own flush pairs, spelled out for ZiplineService's owner.
		local line = model:FindFirstChild("Zipline", true)
		if line then
			local pairsFound = ZFight.Scan({ line })
			if #pairsFound > 0 then
				out("%-18s zipline flush %d: %s", landmark.id, #pairsFound, table.concat(ZFight.Describe(pairsFound, function(p)
					return string.format("%s size(%.1f,%.1f,%.1f)", p.Name, p.Size.X, p.Size.Y, p.Size.Z)
				end, 6), " | "))
			end
		end
	end
	-- The harness plugin's own log flush, so a Studio that dies part-way keeps what came before.
	if index % 4 == 0 and flush then
		flush()
	end
	task.wait()
end

-- The geyser's cooldown, driven directly. This bug has been written twice in this project (TownThemes'
-- springs, and this geyser -- by me, this morning): a cooldown kept in a WEAK table is emptied by a
-- collection, and the same player is thrown again immediately. The collection between the two calls
-- is the whole test; without it a weak table passes.
if Landmarks.GeyserLaunch then
	local vent = Instance.new("Part")
	vent.Anchored = true
	vent.Size = Vector3.new(4, 1, 4)
	vent.Parent = workspace
	local character = Instance.new("Model")
	character.Name = "CooldownDummy"
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Size = Vector3.new(2, 2, 1)
	root.Parent = character
	character.Parent = workspace

	local first = Landmarks.GeyserLaunch(vent, character, 100)
	collectgarbage("collect")
	local second = Landmarks.GeyserLaunch(vent, character, 101)
	local later = Landmarks.GeyserLaunch(vent, character, 120)
	local dead = Landmarks.GeyserLaunch(vent, nil, 200)
	out("GEYSER first %s, second one second later after a collection %s, again twenty seconds later %s, no character %s: %s",
		first and "launched" or "refused", second and "LAUNCHED" or "refused", later and "launched" or "REFUSED",
		dead and "LAUNCHED" or "refused",
		(first and not second and later and not dead) and "COOLDOWN HOLDS" or "COOLDOWN BROKEN")
	character:Destroy()
	vent:Destroy()
else
	out("GEYSER no Landmarks.GeyserLaunch to drive: the cooldown is untested")
end

-- What each map's set adds.
for mapId, set in pairs(Landmarks.MapSets) do
	local chests, loot = 0, 0
	for _, id in ipairs(set.always) do
		chests += stats[id] and stats[id].chests or 0
		loot += stats[id] and stats[id].loot or 0
	end
	local poolChests, poolLoot = 0, 0
	for _, id in ipairs(set.pool) do
		poolChests += stats[id] and stats[id].chests or 0
		poolLoot += stats[id] and stats[id].loot or 0
	end
	local fill = 4 - #set.always
	-- Before: the map's signature plus a random pick from the nine originals, three to five in all
	-- (radius / 320), the lighthouse counted among them on the coast.
	local ORIGINAL = { "SignalHill", "RotDocks", "RotBowl", "Flight67", "SahurRuins", "Carnival", "Farmstead", "SigmaSpire", "HotSprings" }
	local radii = { SahurSprings = 1280, TralalaTown = 950, BombardiroBay = 1480, RotRidge = 880, PatapimPlains = 1150 }
	local signature = set.always[1]
	local oldWant = math.clamp(math.floor((radii[mapId] or 1000) / 320), 3, 5) - (mapId == "BombardiroBay" and 1 or 0)
	local otherChests, otherLoot = 0, 0
	for _, id in ipairs(ORIGINAL) do
		if id ~= signature and stats[id] then
			otherChests += stats[id].chests
			otherLoot += stats[id].loot
		end
	end
	-- A build that failed has no stats; it's already reported above, so it counts as nothing here.
	local signatureStats = stats[signature] or { chests = 0, loot = 0 }
	local before = signatureStats.chests + otherChests / 8 * (oldWant - 1)
	local beforeLoot = signatureStats.loot + otherLoot / 8 * (oldWant - 1)
	out("set %-14s always %s; pool %s -> about %.1f chests, %.1f pickups (before: about %.1f chests, %.1f pickups; lighthouse not counted)", mapId,
		table.concat(set.always, ","), table.concat(set.pool, ","), chests + poolChests / #set.pool * fill, loot + poolLoot / #set.pool * fill, before, beforeLoot)
end

stage:Destroy()
terrain:Clear()
out("done")
