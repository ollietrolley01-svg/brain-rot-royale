-- Where the battle royale map's mountable guns stand (Oliver, 2026-09-24: "put the mountable guns in
-- strategic locations"). MountedGuns calls Choose once the map is built; nothing here builds anything.
--
--   MountedGunPlacement.Choose(mapInfo, seed)   -> { { cframe, kind, score, covers }, ... }   (Roblox)
--   MountedGunPlacement.Pure                    the scorer and chooser, plain Lua (tools/mounted_guns_check.py
--                                               runs it under lupa on synthetic worlds with planted bad spots)
--
-- CANDIDATES come from the map generator's own data: rings round every landmark, spots beside every road
-- junction, at both ends of every bridge and along the long open roads between towns, and a ring round each
-- town's approaches. Each is then SCORED as a gun position, facing whichever of eight bearings suits it best:
--
--   REJECTED outright (Pure.Score's `why`):
--     no floor        nothing walkable under it (water, a slope steeper than FloorNormal, the void)
--     uneven          the floor across the gun's footprint differs by more than Flatness
--     no room         something solid in the box the gun and its gunner need
--     road            on a road's corridor (a gun in the road is a roadblock, not an emplacement)
--     spawn / lobby / edge / drop point    too near a spawn, the lobby or the map's edge, or ON a drop point
--     overlooks a drop point               a drop point inside its range and arc with a clear line to it
--                                          (nobody lands under a gun; MountedGunData.LandingGrace as well)
--     pit             lower than the ground round it by more than PitDepth
--     blocked field of fire                the median clear sightline across its arc is under FireMinClear
--                                          (a wall-facing spot)
--     no cover        nothing solid beside or behind it within CoverReach at a crouching gunner's chest
--     no flank route  no walkable way in from outside its arc: every approach from the sides and the back
--                     is a drop or a climb steeper than FlankStep (a spot that would be an unassailable lane lock)
--   SCORED on what is left:
--     high ground     its height over the ground round it (HighGroundRing), capped
--     field of fire   the mean clear sightline across the arc
--     coverage        the points of interest (bridges, junctions, roads, towns, landmarks, loot) inside its
--                     range and arc with a clear line from the gunner's eye, by their weights
--     cover           how many of the side and back rays are blocked
--   CHOSEN greedily by score, each at least Spacing from every other, up to Count.max; a third of them
--   (those covering the most road and bridge) are cannons, the rest HMGs. Ties break on a seeded jitter,
--   so the same seed on the same map picks the same spots.

local MountedGunPlacement = {}

-- PURE BEGIN
local Pure = {}

Pure.Params = {
	Count = { min = 12, max = 18 },
	Spacing = 150,
	FloorNormal = 0.85,
	Flatness = 0.8,
	Footprint = 2.4,
	Room = { 5.4, 6.2, 5.4 },
	SpawnClear = 60,
	LobbyClear = 220,
	EdgeMargin = 70,
	DropClear = 70,
	DropOverlook = 130,
	PitDepth = 3,
	HighGroundRing = 28,
	HighGroundCap = 18,
	EyeHeight = 4.7,
	-- A crouching gunner's middle: cover is anything that hides a crouched body beside or behind the gun.
	ChestHeight = 2.2,
	Range = 300,
	ArcHalf = 60,
	FireRays = 9,
	FireMinClear = 60,
	CoverReach = 15,
	CoverMin = 1,
	FlankDistance = 40,
	FlankStepLength = 4,
	FlankStep = 3.2,
	Facings = 8,
	MaxCandidates = 520,
}

local function flatDist(a, b)
	local dx, dz = a[1] - b[1], a[3] - b[3]
	return math.sqrt(dx * dx + dz * dz)
end
local function dist(a, b)
	local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- Bearing 0 is -Z (a gun's front), clockwise seen from above toward +X.
local function dirOf(bearing)
	local r = math.rad(bearing)
	return math.sin(r), -math.cos(r)
end
local function bearingTo(from, to)
	return math.deg(math.atan2(to[1] - from[1], -(to[3] - from[3])))
end
local function angleDiff(a, b)
	local d = (a - b) % 360
	if d > 180 then
		d -= 360
	end
	return math.abs(d)
end
Pure.dirOf, Pure.bearingTo, Pure.angleDiff = dirOf, bearingTo, angleDiff

-- A small deterministic generator (the same numbers in Luau and in lupa's Lua 5.x).
function Pure.rng(seed)
	local state = math.floor(math.abs(seed or 1)) % 2147483647
	if state == 0 then
		state = 1
	end
	return function()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

-- The facing-independent part of a spot: floor, footprint, room, exclusions, high ground, the sightline and
-- cover ray fans and the lines to the points of interest. nil, why when rejected.
function Pure.Survey(world, ctx, x, z, P)
	P = P or Pure.Params
	local y, normalY, walkable = world.floor(x, z)
	if not y or not walkable or normalY < P.FloorNormal then
		return nil, "no floor"
	end
	-- Somewhere a player can walk to: the ground itself, or a floor within a step of it (a bridge deck, a
	-- platform) -- never a rooftop nobody can climb to.
	if world.reachable and not world.reachable(x, z, y) then
		return nil, "unreachable floor"
	end
	local lowest, highest = y, y
	for i = 0, 3 do
		local dx, dz = dirOf(i * 90 + 45)
		local fy = world.floor(x + dx * P.Footprint, z + dz * P.Footprint)
		if not fy then
			return nil, "uneven"
		end
		lowest, highest = math.min(lowest, fy), math.max(highest, fy)
	end
	if highest - lowest > P.Flatness then
		return nil, "uneven"
	end
	local at = { x, y, z }
	if world.onRoad and world.onRoad(x, z) then
		return nil, "road"
	end
	for _, s in ipairs(ctx.spawns or {}) do
		if flatDist(at, s) < P.SpawnClear then
			return nil, "spawn"
		end
	end
	if ctx.lobby and dist(at, ctx.lobby) < P.LobbyClear then
		return nil, "lobby"
	end
	if ctx.radius and math.sqrt(x * x + z * z) > ctx.radius - P.EdgeMargin then
		return nil, "edge"
	end
	for _, d in ipairs(ctx.drops or {}) do
		if flatDist(at, d) < P.DropClear then
			return nil, "drop point"
		end
	end
	if not world.boxFree(x, y + P.Room[2] / 2 + 0.3, z, P.Room[1], P.Room[2], P.Room[3]) then
		return nil, "no room"
	end
	-- High ground: over the ring round it. A pit is rejected.
	local sum, n = 0, 0
	-- Three rings (1x, 2x and 3x HighGroundRing out), so a broad hilltop still reads as high ground.
	for ring = 1, 3 do
		for i = 0, 7 do
			local dx, dz = dirOf(i * 45 + ring * 15)
			local gy = world.floor(x + dx * P.HighGroundRing * ring, z + dz * P.HighGroundRing * ring)
			if gy then
				sum += gy
				n += 1
			end
		end
	end
	local rise = n > 0 and (y - sum / n) or 0
	if rise < -P.PitDepth then
		return nil, "pit"
	end
	local eye = { x, y + P.EyeHeight, z }
	-- Sightlines every 15 degrees all the way round, level from the eye.
	local sight = {}
	for i = 0, 23 do
		local dx, dz = dirOf(i * 15)
		local d = world.cast(eye, { x + dx * P.Range, eye[2], z + dz * P.Range })
		sight[i] = math.min(d or P.Range, P.Range)
	end
	-- Cover: a crouching gunner's chest, rays every 45 degrees out to CoverReach.
	local cover = {}
	for i = 0, 7 do
		local dx, dz = dirOf(i * 45)
		local chest = { x, y + P.ChestHeight, z }
		cover[i] = world.cast(chest, { x + dx * P.CoverReach, chest[2], z + dz * P.CoverReach }) ~= nil
	end
	-- The points of interest in range, each with its bearing and whether the eye sees it.
	local seen = {}
	for _, poi in ipairs(ctx.pois or {}) do
		local d = flatDist(at, poi)
		if d > 8 and d <= P.Range then
			local target = { poi[1], poi[2] + 3, poi[3] }
			if not world.cast(eye, target) then
				table.insert(seen, { poi = poi, bearing = bearingTo(at, poi), distance = d })
			end
		end
	end
	local drops = {}
	for _, d in ipairs(ctx.drops or {}) do
		local fd = flatDist(at, d)
		if fd <= P.DropOverlook and not world.cast(eye, { d[1], d[2] + 3, d[3] }) then
			table.insert(drops, bearingTo(at, d))
		end
	end
	return { at = at, eye = eye, rise = rise, sight = sight, cover = cover, seen = seen, drops = drops }
end

-- A walkable way in along `bearing` (the way the flanker comes FROM), FlankDistance out: every step of it
-- on a floor, none a climb or drop steeper than FlankStep.
function Pure.FlankRoute(world, survey, bearing, P)
	P = P or Pure.Params
	local dx, dz = dirOf(bearing)
	local at = survey.at
	local previous = at[2]
	local steps = math.floor(P.FlankDistance / P.FlankStepLength)
	for s = 1, steps do
		local fx, fz = at[1] + dx * s * P.FlankStepLength, at[3] + dz * s * P.FlankStepLength
		local fy, normalY, walkable = world.floor(fx, fz)
		if not fy or not walkable or math.abs(fy - previous) > P.FlankStep then
			return false
		end
		previous = fy
	end
	return true
end

-- The spot facing `facing`: ok, score, why, details.
function Pure.Score(world, survey, facing, P)
	P = P or Pure.Params
	for _, b in ipairs(survey.drops) do
		if angleDiff(b, facing) <= P.ArcHalf + 5 then
			return false, 0, "overlooks a drop point"
		end
	end
	-- Field of fire across the arc.
	local clear = {}
	for i = 0, 23 do
		if angleDiff(i * 15, facing) <= P.ArcHalf then
			table.insert(clear, survey.sight[i])
		end
	end
	table.sort(clear)
	local median = clear[math.floor((#clear + 1) / 2)] or 0
	if median < P.FireMinClear then
		return false, 0, "blocked field of fire"
	end
	local mean = 0
	for _, c in ipairs(clear) do
		mean += c
	end
	mean /= math.max(1, #clear)
	-- Cover beside and behind (not in front: the shield and sandbags are there).
	local covered = 0
	for i = 0, 7 do
		if survey.cover[i] and angleDiff(i * 45, facing) >= 60 then
			covered += 1
		end
	end
	if covered < P.CoverMin then
		return false, 0, "no cover"
	end
	-- A way round: from either side outside the arc, or from behind.
	local routes = 0
	for _, off in ipairs({ P.ArcHalf + 45, -(P.ArcHalf + 45), 180 }) do
		if Pure.FlankRoute(world, survey, facing + off, P) then
			routes += 1
		end
	end
	if routes == 0 then
		return false, 0, "no flank route"
	end
	local coverage, vehicles = 0, 0
	local covers = {}
	for _, s in ipairs(survey.seen) do
		if angleDiff(s.bearing, facing) <= P.ArcHalf then
			local w = s.poi.weight or 1
			coverage += w
			if s.poi.kind == "bridge" or s.poi.kind == "junction" or s.poi.kind == "road" then
				vehicles += w
			end
			covers[s.poi.kind or "poi"] = (covers[s.poi.kind or "poi"] or 0) + 1
		end
	end
	local score = math.clamp and math.clamp(survey.rise, 0, P.HighGroundCap) * 2 or math.max(0, math.min(survey.rise, P.HighGroundCap)) * 2
	score += mean / P.Range * 30 + coverage * 4 + covered * 2 + routes
	return true, score, nil, { coverage = coverage, vehicles = vehicles, covers = covers, median = median, rise = survey.rise,
		covered = covered, routes = routes }
end

-- The best facing for a surveyed spot: ok, score, facing, details or why (the commonest rejection).
function Pure.Best(world, survey, P)
	P = P or Pure.Params
	local best, bestScore, bestDetails = nil, -math.huge, nil
	local whys = {}
	for i = 0, P.Facings - 1 do
		local facing = i * 360 / P.Facings
		local ok, score, why, details = Pure.Score(world, survey, facing, P)
		if ok and score > bestScore then
			best, bestScore, bestDetails = facing, score, details
		elseif not ok then
			whys[why] = (whys[why] or 0) + 1
		end
	end
	if best then
		return true, bestScore, best, bestDetails
	end
	local why, most = "rejected", -1
	for k, v in pairs(whys) do
		if v > most or (v == most and k < why) then
			why, most = k, v
		end
	end
	return false, 0, nil, why
end

-- Candidate spots from the map's own data: ctx.landmarks, ctx.junctions, ctx.bridgeEnds, ctx.roadRuns
-- ({ a, b } pairs), ctx.towns. Deterministic order.
function Pure.Candidates(ctx, P)
	P = P or Pure.Params
	local out = {}
	local function add(x, z, why)
		table.insert(out, { x, z, why })
	end
	for _, l in ipairs(ctx.landmarks or {}) do
		for _, r in ipairs({ 22, 38 }) do
			for i = 0, 7 do
				local dx, dz = dirOf(i * 45 + (r == 38 and 22.5 or 0))
				add(l[1] + dx * r, l[3] + dz * r, "landmark")
			end
		end
	end
	for _, j in ipairs(ctx.junctions or {}) do
		for i = 0, 3 do
			local dx, dz = dirOf(i * 90 + 45)
			add(j[1] + dx * 26, j[3] + dz * 26, "junction")
		end
	end
	for _, b in ipairs(ctx.bridgeEnds or {}) do
		for _, side in ipairs({ -1, 1 }) do
			add(b[1] + b.sideX * 22 * side, b[3] + b.sideZ * 22 * side, "bridge")
		end
	end
	for _, run in ipairs(ctx.roadRuns or {}) do
		local a, b = run[1], run[2]
		local len = flatDist(a, b)
		if len > 120 then
			local ux, uz = (b[1] - a[1]) / len, (b[3] - a[3]) / len
			for _, t in ipairs({ 0.25, 0.5, 0.75 }) do
				for _, side in ipairs({ -1, 1 }) do
					add(a[1] + (b[1] - a[1]) * t - uz * 28 * side, a[3] + (b[3] - a[3]) * t + ux * 28 * side, "road")
				end
			end
		end
	end
	for _, t in ipairs(ctx.towns or {}) do
		for ring, r in ipairs({ 120, 160, 210 }) do
			for i = 0, 7 do
				local dx, dz = dirOf(i * 45 + ring * 15)
				add(t[1] + dx * r, t[3] + dz * r, "town")
			end
		end
	end
	return out
end

-- Scores every candidate and picks the guns. Returns the chosen list and a tally of the rejections.
--   chosen[i] = { x, y, z, facing, kind, score, details, why = candidate reason }
function Pure.Choose(world, ctx, seed, P, yieldFn)
	P = P or Pure.Params
	local random = Pure.rng(seed)
	local candidates = Pure.Candidates(ctx, P)
	-- Thin to MaxCandidates, deterministically.
	while #candidates > P.MaxCandidates do
		table.remove(candidates, 1 + math.floor(random() * #candidates))
	end
	local passed, rejected = {}, {}
	for index, c in ipairs(candidates) do
		local survey, why = Pure.Survey(world, ctx, c[1], c[2], P)
		local ok, score, facing, details
		if survey then
			ok, score, facing, details = Pure.Best(world, survey, P)
			if not ok then
				why = details
			end
		end
		if survey and ok then
			table.insert(passed, { survey.at[1], survey.at[2], survey.at[3], facing = facing, score = score + random() * 0.5,
				details = details, why = c[3], index = index })
		else
			rejected[why] = (rejected[why] or 0) + 1
		end
		if yieldFn and index % 6 == 0 then
			yieldFn()
		end
	end
	table.sort(passed, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.index < b.index
	end)
	local chosen = {}
	for _, p in ipairs(passed) do
		if #chosen >= P.Count.max then
			break
		end
		local apart = true
		for _, c in ipairs(chosen) do
			if flatDist(p, c) < P.Spacing then
				apart = false
				break
			end
		end
		if apart then
			table.insert(chosen, p)
		end
	end
	-- A third are cannons: the ones covering the most road and bridge.
	local order = {}
	for i, c in ipairs(chosen) do
		order[i] = c
	end
	table.sort(order, function(a, b)
		if a.details.vehicles ~= b.details.vehicles then
			return a.details.vehicles > b.details.vehicles
		end
		return a.index < b.index
	end)
	local cannons = math.floor(#chosen / 3)
	for i, c in ipairs(order) do
		c.kind = i <= cannons and "cannon" or "hmg"
	end
	return chosen, rejected, #candidates
end
-- PURE END

MountedGunPlacement.Pure = Pure

--------------------------------------------------------------------------------
-- The real world (Roblox)
--------------------------------------------------------------------------------

local function worldFor(roads, groundAt)
	local down = RaycastParams.new()
	down.FilterType = Enum.RaycastFilterType.Exclude
	down.IgnoreWater = false
	local excluded = {}
	for _, name in ipairs({ "Loot", "Effects", "DeathFx", "MountedGuns" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(excluded, f)
		end
	end
	down.FilterDescendantsInstances = excluded
	local cache = {}
	local world = {}
	function world.floor(x, z)
		local key = math.floor(x * 4 + 0.5) * 1000003 + math.floor(z * 4 + 0.5)
		local hit = cache[key]
		if hit == nil then
			local result = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -520, 0), down)
			hit = result and { result.Position.Y, result.Normal.Y, result.Material ~= Enum.Material.Water
				and (result.Instance == workspace.Terrain or result.Instance.CanCollide), result.Instance == workspace.Terrain } or false
			cache[key] = hit
		end
		if not hit then
			return nil
		end
		return hit[1], hit[2], hit[3]
	end
	local los = RaycastParams.new()
	los.FilterType = Enum.RaycastFilterType.Exclude
	los.IgnoreWater = true
	los.FilterDescendantsInstances = excluded
	function world.cast(from, to)
		local a = Vector3.new(from[1], from[2], from[3])
		local b = Vector3.new(to[1], to[2], to[3])
		local result = workspace:Raycast(a, b - a, los)
		return result and (result.Position - a).Magnitude or nil
	end
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = excluded
	overlap.RespectCanCollide = true
	function world.boxFree(x, y, z, sx, sy, sz)
		local parts = workspace:GetPartBoundsInBox(CFrame.new(x, y, z), Vector3.new(sx, sy, sz), overlap)
		return #parts == 0
	end
	function world.reachable(x, z, y)
		world.floor(x, z)
		local hit = cache[math.floor(x * 4 + 0.5) * 1000003 + math.floor(z * 4 + 0.5)]
		return (hit and hit[4]) or y <= groundAt(x, z) + 4
	end
	function world.onRoad(x, z)
		return roads ~= nil and roads.WithinCorridor ~= nil and roads:WithinCorridor(x, z) == true
	end
	return world
end

local function v(p)
	return { p.X, p.Y, p.Z }
end

-- The candidates' and points of interest's sources, from MapGenerator.Build's result.
local function contextFor(mapInfo, groundAt)
	local ctx = { landmarks = {}, junctions = {}, bridgeEnds = {}, roadRuns = {}, towns = {}, pois = {}, drops = {}, spawns = {} }
	ctx.radius = mapInfo.radius
	local okConfig, MatchConfig = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MatchConfig"))
	end)
	if okConfig and MatchConfig.LobbyPosition then
		ctx.lobby = v(MatchConfig.LobbyPosition)
	end
	for _, spot in ipairs(mapInfo.dropSpots or {}) do
		local p = typeof(spot) == "Vector3" and spot or (typeof(spot) == "CFrame" and spot.Position) or nil
		if p then
			local at = { p.X, groundAt(p.X, p.Z), p.Z }
			table.insert(ctx.drops, at)
			table.insert(ctx.spawns, at)
			table.insert(ctx.towns, at)
			table.insert(ctx.pois, { at[1], at[2], at[3], kind = "town", weight = 2 })
		end
	end
	for _, l in ipairs(mapInfo.landmarks or {}) do
		local at = { l.X or l[1], l.Y or groundAt(l.X or l[1], l.Z or l[3]), l.Z or l[3] }
		table.insert(ctx.landmarks, at)
		table.insert(ctx.pois, { at[1], at[2], at[3], kind = "landmark", weight = 2 })
	end
	local roads = mapInfo.roads
	if roads and roads.nodes then
		for _, node in pairs(roads.nodes) do
			local p = node.position
			if p and (node.kind == "junction" or node.kind == "tee" or node.kind == "cross" or node.kind == "bend") then
				table.insert(ctx.junctions, v(p))
				table.insert(ctx.pois, { p.X, p.Y, p.Z, kind = "junction", weight = 1.5 })
			end
		end
	end
	if roads and roads.edges then
		for _, edge in pairs(roads.edges) do
			if edge.from and edge.to then
				table.insert(ctx.roadRuns, { v(edge.from), v(edge.to) })
				local mid = (edge.from + edge.to) / 2
				table.insert(ctx.pois, { mid.X, groundAt(mid.X, mid.Z), mid.Z, kind = "road", weight = 1 })
				for _, span in ipairs(edge.bridges or {}) do
					for _, s in ipairs({ span.s0 - 14, span.s1 + 14 }) do
						local p = edge.from + edge.dir * s
						local e = { p.X, groundAt(p.X, p.Z), p.Z, sideX = edge.dir.Z, sideZ = -edge.dir.X }
						table.insert(ctx.bridgeEnds, e)
						table.insert(ctx.pois, { e[1], e[2], e[3], kind = "bridge", weight = 3 })
					end
				end
			end
		end
	end
	return ctx, roads
end

-- The chosen spots for a built map: { { cframe, kind, score, covers, why }, ... } and the rejection tally.
function MountedGunPlacement.Choose(mapInfo, seed, groundAt)
	local ctx, roads = contextFor(mapInfo, groundAt)
	local world = worldFor(roads, groundAt)
	local chosen, rejected, considered = Pure.Choose(world, ctx, seed, Pure.Params, function()
		task.wait()
	end)
	local out = {}
	for _, c in ipairs(chosen) do
		local r = math.rad(c.facing)
		table.insert(out, {
			cframe = CFrame.new(c[1], c[2], c[3]) * CFrame.Angles(0, -r, 0),
			kind = c.kind, score = c.score, details = c.details, why = c.why,
		})
	end
	return out, rejected, considered
end

return MountedGunPlacement
