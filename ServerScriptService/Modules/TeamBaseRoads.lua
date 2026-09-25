-- The access road from each team base's gatehouse to the map's road network (Oliver, 2026-09-24:
-- "make sure the team bases connect to the roads too"). Team matches only: ModeTeams builds it with
-- the compounds and it goes with them (it is parented into the compound's model), so a battle royale
-- map never has one.
--
--   TeamBaseRoads.Plan(start, heading, roads, options)  -> plan | nil, why     pure: no instances
--   TeamBaseRoads.GatewayTargets(roads, gateways, centre) -> targets           the arena gateways' roads
--   TeamBaseRoads.CutAtArena(roads, centre, radius)       -> undo              no bot route through the arena
--   TeamBaseRoads.Profile(plan, groundAt, startY)        -> heights            pure
--   TeamBaseRoads.ShapeGround(terrain, plan, heights)    -> columns changed    cut and fill to the road
--   TeamBaseRoads.Build(plan, heights, parent)           -> model              the road
--   TeamBaseRoads.Register(roads, plan, heights)         -> undo               a road bots can route on
--
-- THE ROUTE. From the end of the gate's ramp, straight on out of the gate, then a smooth curve (a
-- cubic Bezier) that meets the chosen map road SQUARE, butting onto its edge: a T-junction. Every
-- road in the network runs on the world's axes, so "square" is always along an axis. The target is
-- the nearest point on any road edge that is not a bridge and keeps clear of the edge's ends (its
-- junction boxes and bends); a route is refused if it bends tighter than MIN_RADIUS, runs longer than
-- MAX_LENGTH, comes within `avoid` discs (the battleground), crosses another road, or (options.blocked)
-- runs into something that cannot be cleared. The best of what is left is the shortest.
--
-- THE HEIGHTS (Oliver: "make the roads to the bases smoother on the hills"). A graded vertical curve,
-- not the terrain's bumps: the centre-line ground smoothed hard, pinned to the gate and to the joined
-- road's surface, held to MAX_GRADE (12%) and to MAX_PITCH of pitch change between stretches (gentle
-- crests and sags). A route the hill is too steep for, or that would need more than MAX_EARTH of cut
-- or fill, is passed over for one round the hill. ShapeGround then cuts and fills the terrain to the
-- road on the voxels, with banks at 35 degrees back to the natural ground (no cliffs beside it).
--
-- THE SURFACE. Asphalt slabs whose top centre lines meet at every sample, each run past its ends by the
-- bend's overhang so the outside of a bend is covered (the step where two tops cross stays under 0.05
-- with the pitch held); edge lines, the dashed centre line, and a stop line at the junction.
--
-- FOR BOTS. Register splits the target edge at the junction and chains nodes up the access road to the
-- gate, in the shape BotNav reads (edges with a, b, from, to, length; nodes with position, arms), and
-- hands back an undo.
--
-- tools/team_base_road_check.py runs Plan, Profile, Build and Register offline.

local TeamBaseRoads = {}

TeamBaseRoads.Width = 18
TeamBaseRoads.Lift = 0.4
local HALF = TeamBaseRoads.Width / 2
-- Chord between samples, the tightest bend allowed, the longest access road, the steepest grade.
local STEP = 6
local MIN_RADIUS = 45
local MAX_LENGTH = 900
local MAX_GRADE = 0.12
-- The most the pitch may change from one stretch to the next (degrees), the deepest cut or fill a
-- route may need (more, and the planner goes round the hill), the running-average passes.
local MAX_PITCH = 2.8
local MAX_EARTH = 12
local SMOOTH_PASSES = 30
TeamBaseRoads.MinRadius, TeamBaseRoads.MaxGrade, TeamBaseRoads.Step = MIN_RADIUS, MAX_GRADE, STEP
TeamBaseRoads.MaxPitch, TeamBaseRoads.MaxEarth = MAX_PITCH, MAX_EARTH
-- The junction keeps this far from either end of the edge it joins (the boxes and bends there).
local END_CLEAR = 36
-- Straight on out of the gate before any turn.
local LEAD = 24
-- Straight in, square to the road, for the last stretch before the junction.
local APPROACH = 14
-- The ground work: flat shoulders each side, the ground this far under the road's own ground, banks
-- back to the natural ground at 35 degrees reaching out at most BANK_REACH, on MapTerrain's 4-stud voxels.
local SHOULDER = 3
local GROUND_UNDER = 0.25
local BANK_SLOPE = math.tan(math.rad(35))
local BANK_REACH = 18
local CELL = 4
-- Smooth terrain draws its surface this far over the filled volume (MapTerrain.SurfaceLift): a read
-- adds it, a write takes it off. Left out, the road's own ground came up 2 over the asphalt (Studio).
TeamBaseRoads.SurfaceLift = 2

local ASPHALT = Color3.fromRGB(62, 62, 66)
local LINE = Color3.fromRGB(236, 232, 220)

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function bezier(p0, p1, p2, p3, t)
	local u = 1 - t
	return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
end

local function segmentsCross(a, b, c, d)
	local function orient(p, q, r)
		return (q.X - p.X) * (r.Z - p.Z) - (q.Z - p.Z) * (r.X - p.X)
	end
	local d1, d2 = orient(c, d, a), orient(c, d, b)
	local d3, d4 = orient(a, b, c), orient(a, b, d)
	return ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
end

local function distanceToSegment(p, a, b)
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-9), 0, 1)
	return (p - (a + ab * t)).Magnitude
end

-- Is flat point `p` inside any of `boxes` ({ frame, halfX, halfZ }, the compounds)?
local function inBox(p, boxes)
	for _, b in ipairs(boxes or {}) do
		local d = Vector3.new(p.X - b.frame.Position.X, 0, p.Z - b.frame.Position.Z)
		if math.abs(d:Dot(b.frame.RightVector)) < b.halfX + HALF and math.abs(d:Dot(b.frame.LookVector)) < b.halfZ + HALF then
			return true
		end
	end
	return false
end

-- The rules every route is held to, whichever planner drew it: no longer than MAX_LENGTH, no bend
-- tighter than MIN_RADIUS, clear of the `avoid` discs, across no other road, out of the compounds once
-- past the gate's lead. Returns the route, or nil and why.
local function checkRoute(path, start, edge, t, join, centre, normal, roads, options, target)
	local total = 0
	for i = 2, #path do
		total += (path[i] - path[i - 1]).Magnitude
	end
	if total > MAX_LENGTH then
		return nil, "too long"
	end
	for i = 2, #path - 1 do
		local u, v = path[i] - path[i - 1], path[i + 1] - path[i]
		local chord = (u.Magnitude + v.Magnitude) / 2
		local cosine = math.clamp(u.Unit:Dot(v.Unit), -1, 1)
		local turn = math.acos(cosine)
		if turn > 1e-6 and chord / turn < MIN_RADIUS then
			return nil, "bends too tight"
		end
	end
	for _, disc in ipairs(options.avoid or {}) do
		for i = 2, #path do
			if distanceToSegment(flat(disc.centre), path[i - 1], path[i]) < disc.radius + HALF then
				return nil, "through the " .. (disc.name or "arena")
			end
		end
	end
	for _, other in ipairs(roads.edges) do
		if other ~= edge then
			local c, d = flat(other.from or other.a.position), flat(other.to or other.b.position)
			for i = 2, #path - 1 do
				if segmentsCross(path[i - 1], path[i], c, d) then
					return nil, "crosses another road"
				end
			end
		end
	end
	-- Out of the compounds (its own included), once clear of the gate's straight lead.
	for i = 1, #path do
		if (path[i] - start).Magnitude > LEAD + 1 and inBox(path[i], options.boxes) then
			return nil, "through a compound"
		end
	end
	-- The whole way to the arena: this road, then along the map road to the gateway (when there is one).
	local to = target and math.abs(t - target.at) or 0
	return { points = path, edge = edge, along = t, join = join, centre = centre, normal = normal, length = total,
		total = total + to, gateway = target and target.gateway, alongRoad = to }
end

-- One candidate route to `edge` from `start` heading `heading` (flat unit vectors), or nil and why.
local function routeTo(start, heading, edge, roads, options, shift, tension, target)
	local a, b = flat(edge.from or edge.a.position), flat(edge.to or edge.b.position)
	local along = b - a
	local length = along.Magnitude
	if not target and length < 2 * END_CLEAR + TeamBaseRoads.Width then
		return nil, "edge too short"
	end
	local dir = along / length
	local lead = start + heading * LEAD
	-- A target (an arena gateway's road) limits where on the edge the junction may go.
	local lo, hi = END_CLEAR + HALF, length - END_CLEAR - HALF
	if target then
		-- The gateway's end of its road is a cut, not a junction box: only the outer end keeps clear.
		lo, hi = math.max(HALF + 4, target.lo), math.min(length - HALF - 4, target.hi)
		if hi < lo then
			return nil, "no room on the gateway's road"
		end
	end
	local t = math.clamp((lead - a):Dot(dir) + (shift or 0), lo, hi)
	local centre = a + dir * t
	local normal = Vector3.new(-dir.Z, 0, dir.X)
	if (lead - centre):Dot(normal) < 0 then
		normal = -normal
	end
	local join = centre + normal * HALF
	local span = (join - lead).Magnitude
	if span < 20 then
		return nil, "too close"
	end
	local k = math.clamp(span * (tension or 0.42), 18, 160)
	local points = { start }
	local samples = math.max(8, math.ceil(span / 2))
	local raw = {}
	-- The curve ends APPROACH short of the road, square to it; the last stretch is straight in.
	local approach = join + normal * APPROACH
	for i = 0, samples do
		table.insert(raw, bezier(lead, lead + heading * k, approach + normal * k, approach, i / samples))
	end
	table.insert(raw, join)
	-- Resample the straight lead and the curve at STEP.
	local path = { start }
	local carry, last = 0, start
	local chain = { start }
	for _, p in ipairs(raw) do
		table.insert(chain, p)
	end
	for i = 2, #chain do
		local p, q = chain[i - 1], chain[i]
		local seg = (q - p).Magnitude
		local walked = 0
		while seg - walked + carry >= STEP do
			walked += STEP - carry
			carry = 0
			last = p + (q - p) * (walked / seg)
			table.insert(path, last)
		end
		carry += seg - walked
	end
	if (path[#path] - join).Magnitude > STEP / 2 then
		table.insert(path, join)
	else
		path[#path] = join
	end
	local _ = points
	return checkRoute(path, start, edge, t, join, centre, normal, roads, options, target)
end

-- What options.blocked says about a whole route: nil when every stretch is clear.
local function blockedRoute(route, options)
	if options.blocked then
		for i = 2, #route.points do
			local why = options.blocked(route.points[i - 1], route.points[i])
			if why then
				return "blocked by " .. tostring(why)
			end
		end
	end
	return nil
end

-- THE GRID PLANNER, for where no single smooth curve gets through (a town, a hill, the arena, a road in
-- the way): A* over an 8-stud grid round the start and the targets -- the battleground's disc, the
-- compounds and every other road's corridor out of bounds, climbs costed -- to a point square off the
-- target road, then smoothed (ends held: the gate's straight lead, the straight run in) until it bends
-- no tighter than MIN_RADIUS, and put through the same rules as a curve. Something that cannot be
-- cleared in the smoothed way (options.blocked) is cut out of the grid and the search run again.
local GRID = 8
local GRID_MARGIN = 160
local GRID_TRIES = 4

local function heapPush(heap, item)
	table.insert(heap, item)
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if heap[parent].f <= heap[i].f then
			break
		end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end

local function heapPop(heap)
	local top = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r, small = 2 * i, 2 * i + 1, i
			if heap[l] and heap[l].f < heap[small].f then
				small = l
			end
			if heap[r] and heap[r].f < heap[small].f then
				small = r
			end
			if small == i then
				break
			end
			heap[i], heap[small] = heap[small], heap[i]
			i = small
		end
	end
	return top
end

-- Ends held, the middle relaxed toward its neighbours until no bend is tighter than MIN_RADIUS.
local function smoothPath(path, holdStart, holdEnd)
	local n = #path
	for pass = 1, 400 do
		local worst = math.huge
		for i = 2, n - 1 do
			local u, v = path[i] - path[i - 1], path[i + 1] - path[i]
			if u.Magnitude > 0.01 and v.Magnitude > 0.01 then
				local turn = math.acos(math.clamp(u.Unit:Dot(v.Unit), -1, 1))
				if turn > 1e-6 then
					worst = math.min(worst, ((u.Magnitude + v.Magnitude) / 2) / turn)
				end
			end
		end
		if worst >= MIN_RADIUS * 1.05 and pass > 20 then
			break
		end
		local copy = table.clone(path)
		for i = holdStart + 1, n - holdEnd do
			path[i] = copy[i] * 0.5 + (copy[i - 1] + copy[i + 1]) * 0.25
		end
	end
	return path
end

local function resample(chain)
	local path = { chain[1] }
	local carry = 0
	for i = 2, #chain do
		local p, q = chain[i - 1], chain[i]
		local seg = (q - p).Magnitude
		local walked = 0
		while seg - walked + carry >= STEP do
			walked += STEP - carry
			carry = 0
			table.insert(path, p + (q - p) * (walked / seg))
		end
		carry += seg - walked
	end
	if (path[#path] - chain[#chain]).Magnitude > STEP / 2 then
		table.insert(path, chain[#chain])
	else
		path[#path] = chain[#chain]
	end
	return path
end

-- Routes from `start` (heading `dir`) onto `targets` (Plan's ranked { edge, target }), by the grid.
local function gridRoutes(start, dir, targets, roads, options)
	local lead = start + dir * LEAD
	-- The goals: points square off each target edge, along its allowed stretch every 16.
	local goals = {}
	for _, item in ipairs(targets) do
		local edge, target = item.edge, item.target
		local a, b = flat(edge.from or edge.a.position), flat(edge.to or edge.b.position)
		local length = (b - a).Magnitude
		if length > 1 then
			local along = (b - a) / length
			local lo, hi = END_CLEAR + HALF, length - END_CLEAR - HALF
			if target then
				lo, hi = math.max(HALF + 4, target.lo), math.min(length - HALF - 4, target.hi)
			end
			local t = lo
			while t <= hi + 0.01 do
				local centre = a + along * t
				local normal = Vector3.new(-along.Z, 0, along.X)
				if (lead - centre):Dot(normal) < 0 then
					normal = -normal
				end
				local join = centre + normal * HALF
				table.insert(goals, { edge = edge, target = target, t = t, centre = centre, normal = normal, join = join,
					approach = join + normal * (APPROACH + GRID), extra = target and math.abs(t - target.at) or 0 })
				t += 16
			end
		end
	end
	if #goals == 0 then
		return {}
	end
	local x0, z0, x1, z1 = lead.X, lead.Z, lead.X, lead.Z
	for _, goal in ipairs(goals) do
		x0, x1 = math.min(x0, goal.approach.X), math.max(x1, goal.approach.X)
		z0, z1 = math.min(z0, goal.approach.Z), math.max(z1, goal.approach.Z)
	end
	x0, z0, x1, z1 = x0 - GRID_MARGIN, z0 - GRID_MARGIN, x1 + GRID_MARGIN, z1 + GRID_MARGIN
	local nx, nz = math.ceil((x1 - x0) / GRID), math.ceil((z1 - z0) / GRID)
	if nx * nz > 90000 then
		return {}
	end
	local function centreOf(ix, iz)
		return Vector3.new(x0 + (ix - 0.5) * GRID, 0, z0 + (iz - 0.5) * GRID)
	end
	-- Other roads' corridors, bucketed.
	local tile = 64
	local buckets = {}
	local targetEdges = {}
	for _, item in ipairs(targets) do
		targetEdges[item.edge] = true
	end
	for _, e in ipairs(roads.edges) do
		if not targetEdges[e] then
			local a, b = flat(e.from or e.a.position), flat(e.to or e.b.position)
			local reach = HALF + 8
			for tx = math.floor((math.min(a.X, b.X) - reach) / tile), math.floor((math.max(a.X, b.X) + reach) / tile) do
				for tz = math.floor((math.min(a.Z, b.Z) - reach) / tile), math.floor((math.max(a.Z, b.Z) + reach) / tile) do
					local key = tx * 100003 + tz
					buckets[key] = buckets[key] or {}
					table.insert(buckets[key], { a, b })
				end
			end
		end
	end
	local banned = {}
	local function free(ix, iz)
		local key = ix * 65536 + iz
		if banned[key] ~= nil then
			return not banned[key]
		end
		local p = centreOf(ix, iz)
		local bad = false
		for _, disc in ipairs(options.avoid or {}) do
			if (p - flat(disc.centre)).Magnitude < disc.radius + HALF + 4 then
				bad = true
			end
		end
		if not bad and (p - start).Magnitude > LEAD + 16 and inBox(p, options.boxes) then
			bad = true
		end
		if not bad then
			for _, seg in ipairs(buckets[math.floor(p.X / tile) * 100003 + math.floor(p.Z / tile)] or {}) do
				if distanceToSegment(p, seg[1], seg[2]) < HALF + 8 then
					bad = true
					break
				end
			end
		end
		banned[key] = bad
		return not bad
	end
	local ground = options.fastGround or options.groundAt
	local heights = {}
	local function heightAt(ix, iz)
		local key = ix * 65536 + iz
		local h = heights[key]
		if h == nil then
			local p = centreOf(ix, iz)
			h = ground and ground(p.X, p.Z) or 0
			heights[key] = h
		end
		return h
	end
	local routes = {}
	for _ = 1, GRID_TRIES do
		local sx, sz = math.floor((lead.X - x0) / GRID) + 1, math.floor((lead.Z - z0) / GRID) + 1
		local goalAt = {}
		for _, goal in ipairs(goals) do
			local gx, gz = math.floor((goal.approach.X - x0) / GRID) + 1, math.floor((goal.approach.Z - z0) / GRID) + 1
			local key = gx * 65536 + gz
			if not goalAt[key] or goal.extra < goalAt[key].extra then
				goalAt[key] = goal
			end
		end
		local function h(ix, iz)
			local p = centreOf(ix, iz)
			local best = math.huge
			for _, goal in ipairs(goals) do
				best = math.min(best, (p - goal.approach).Magnitude + goal.extra)
			end
			return best
		end
		local open, g, came = {}, {}, {}
		local startKey = sx * 65536 + sz
		g[startKey] = 0
		heapPush(open, { f = h(sx, sz), ix = sx, iz = sz, key = startKey })
		local found, foundKey = nil, nil
		local expanded = 0
		while #open > 0 and expanded < 60000 do
			local node = heapPop(open)
			expanded += 1
			if g[node.key] and node.f - h(node.ix, node.iz) <= g[node.key] + 1e-6 then
				local goal = goalAt[node.key]
				if goal then
					found, foundKey = goal, node.key
					break
				end
				for dx = -1, 1 do
					for dz = -1, 1 do
						if dx ~= 0 or dz ~= 0 then
							local ix, iz = node.ix + dx, node.iz + dz
							if ix >= 1 and iz >= 1 and ix <= nx and iz <= nz and free(ix, iz) then
								local step = (dx ~= 0 and dz ~= 0) and GRID * 1.4142 or GRID
								local climb = math.abs(heightAt(ix, iz) - heightAt(node.ix, node.iz)) / step
								local cost = step * (1 + 12 * math.max(0, climb - MAX_GRADE * 0.8))
								local key = ix * 65536 + iz
								local ng = g[node.key] + cost
								if ng < (g[key] or math.huge) then
									g[key] = ng
									came[key] = node.key
									heapPush(open, { f = ng + h(ix, iz), ix = ix, iz = iz, key = key })
								end
							end
						end
					end
				end
			end
		end
		if not found then
			break
		end
		-- The cells back to the start, then the path: start, lead, cells, the run in.
		local cells = {}
		local key = foundKey
		while key do
			table.insert(cells, 1, centreOf(key // 65536, key % 65536))
			key = came[key]
		end
		local chain = { start, lead }
		for i = 2, #cells do
			table.insert(chain, cells[i])
		end
		table.insert(chain, found.approach)
		table.insert(chain, found.join)
		local path = resample(chain)
		-- Held: the straight lead (LEAD / STEP samples) and the straight run in (APPROACH + GRID).
		local holdStart = math.floor(LEAD / STEP) + 1
		local holdEnd = math.floor((APPROACH + GRID) / STEP) + 1
		smoothPath(path, holdStart, holdEnd)
		path = resample(path)
		local route, why = checkRoute(path, start, found.edge, found.t, found.join, found.centre, found.normal, roads, options, found.target)
		if route then
			local blockedAt = nil
			if options.blocked then
				for i = 2, #path do
					if options.blocked(path[i - 1], path[i]) then
						blockedAt = (path[i - 1] + path[i]) / 2
						break
					end
				end
			end
			if not blockedAt then
				route.grid = true
				table.insert(routes, route)
				break
			end
			-- Cut what stood there out of the grid and search again.
			for ix = 1, nx do
				for iz = 1, nz do
					if (centreOf(ix, iz) - blockedAt).Magnitude < 32 then
						banned[ix * 65536 + iz] = true
					end
				end
			end
		else
			routes.why = why
			break
		end
	end
	return routes
end

-- Where along an edge the junction may go (from the lead's own square-on point) and how hard the
-- curve pulls: more than one of each is tried, so a road the plain curve cannot reach is still found.
local SHIFTS = { 0, -45, 45, -100, 100, -170, 170, -250, 250 }
local TENSIONS = { 0.42, 0.28, 0.6, 0.8 }

-- The arena's gateways as targets for Plan: for each gateway point (a finished road end at the
-- battleground's apron), every road edge it lies on, with the stretch of that edge OUTSIDE the gateway
-- (away from `centre`, GATEWAY_CLEAR on) where a junction may go, and where along the edge the gateway
-- is (so a route's total runs on to it).
local GATEWAY_CLEAR = 30
function TeamBaseRoads.GatewayTargets(roads, gateways, centre)
	local out = {}
	local c = flat(centre)
	for gi, gateway in ipairs(gateways) do
		local g = flat(gateway)
		for _, edge in ipairs(roads.edges) do
			if not edge.access and not edge.blocked then
				local a, b = flat(edge.from or edge.a.position), flat(edge.to or edge.b.position)
				local length = (b - a).Magnitude
				if length > 1 and distanceToSegment(g, a, b) < HALF + 3 then
					local at = (g - a):Dot((b - a) / length)
					-- The end further from the middle is outward.
					if (b - c).Magnitude >= (a - c).Magnitude then
						table.insert(out, { edge = edge, gateway = gi, at = at, lo = at + GATEWAY_CLEAR, hi = length })
					else
						table.insert(out, { edge = edge, gateway = gi, at = at, lo = 0, hi = at - GATEWAY_CLEAR })
					end
				end
			end
		end
	end
	return out
end

-- The roads the battleground cut (TeamBattleground ends every road at its apron, RoadEnd from the
-- middle, but the road DATA runs on through the arena): each edge crossing the circle is split where it
-- crosses (a node there -- the gateway), the inside part closed (edge.blocked, as a broken road is), so
-- no bot route runs through the apron and walls. Returns the undo.
function TeamBaseRoads.CutAtArena(roads, centre, radius)
	local c = flat(centre)
	local added, removed, closed = {}, {}, {}
	local original = table.clone(roads.edges)
	for _, edge in ipairs(original) do
		if not edge.blocked then
			local a, b = flat(edge.a.position), flat(edge.b.position)
			local ia, ib = (a - c).Magnitude < radius, (b - c).Magnitude < radius
			if ia and ib then
				edge.blocked = true
				table.insert(closed, edge)
			elseif ia ~= ib or distanceToSegment(c, a, b) < radius then
				-- Where the segment crosses the circle (the crossings nearest each outside end).
				local d = b - a
				local A = d:Dot(d)
				local B = 2 * (a - c):Dot(d)
				local C = (a - c):Dot(a - c) - radius * radius
				local disc = B * B - 4 * A * C
				if disc > 0 then
					local r = math.sqrt(disc)
					local t0, t1 = (-B - r) / (2 * A), (-B + r) / (2 * A)
					local cuts = {}
					if t0 > 0.001 and t0 < 0.999 then
						table.insert(cuts, t0)
					end
					if t1 > 0.001 and t1 < 0.999 then
						table.insert(cuts, t1)
					end
					if #cuts > 0 then
						local armA, armB
						for name, e in pairs(edge.a.arms) do
							if e == edge then
								armA = name
							end
						end
						for name, e in pairs(edge.b.arms) do
							if e == edge then
								armB = name
							end
						end
						local chain = { edge.a }
						local ts = { 0 }
						for _, t in ipairs(cuts) do
							table.insert(chain, { position = Vector3.new(a.X + d.X * t, 0, a.Z + d.Z * t), arms = {}, gateway = true })
							table.insert(ts, t)
						end
						table.insert(chain, edge.b)
						table.insert(ts, 1)
						local pieces = {}
						for k = 1, #chain - 1 do
							local p, q = chain[k], chain[k + 1]
							local piece = { a = p, b = q, from = p.position, to = q.position, road = edge.road, dir = edge.dir,
								length = (flat(q.position) - flat(p.position)).Magnitude, arena = true }
							local mid = a + d * ((ts[k] + ts[k + 1]) / 2)
							piece.blocked = (mid - c).Magnitude < radius or nil
							p.arms[k == 1 and (armA or "arenaA") or ("arena" .. k)] = piece
							q.arms[k + 1 == #chain and (armB or "arenaB") or ("arenaBack" .. k)] = piece
							table.insert(pieces, piece)
						end
						local index = table.find(roads.edges, edge)
						if index then
							table.remove(roads.edges, index)
						end
						table.insert(removed, { edge = edge, armA = armA, armB = armB })
						for _, piece in ipairs(pieces) do
							table.insert(roads.edges, piece)
							table.insert(added, piece)
						end
					end
				end
			end
		end
	end
	return function()
		for _, piece in ipairs(added) do
			local index = table.find(roads.edges, piece)
			if index then
				table.remove(roads.edges, index)
			end
		end
		for _, r in ipairs(removed) do
			table.insert(roads.edges, r.edge)
			if r.armA then
				r.edge.a.arms[r.armA] = r.edge
			end
			if r.armB then
				r.edge.b.arms[r.armB] = r.edge
			end
		end
		for _, edge in ipairs(closed) do
			edge.blocked = nil
		end
	end
end

-- How far a route that joins the network ANYWHERE drives on along the map's roads to its nearest arena
-- gateway: Dijkstra over roads.edges from the junction (both ways along the joined edge), to the point
-- on an edge where a gateway lies. Returns the distance and the gateway's index, or nil.
function TeamBaseRoads.DistanceToGateway(roads, plan, gateways)
	local edge = plan.edge
	local dist, done = {}, {}
	local adjacency = {}
	for _, e in ipairs(roads.edges) do
		if not e.blocked then
			adjacency[e.a] = adjacency[e.a] or {}
			adjacency[e.b] = adjacency[e.b] or {}
			table.insert(adjacency[e.a], e)
			table.insert(adjacency[e.b], e)
		end
	end
	local function gatewayOn(e)
		local a, b = flat(e.from or e.a.position), flat(e.to or e.b.position)
		local out = {}
		for gi, g in ipairs(gateways) do
			if distanceToSegment(flat(g), a, b) < HALF + 3 then
				table.insert(out, { gi = gi, along = (flat(g) - a):Dot((b - a).Unit) })
			end
		end
		return out
	end
	local best, bestGate = math.huge, nil
	-- On the joined edge itself.
	for _, hit in ipairs(gatewayOn(edge)) do
		local d = math.abs(hit.along - plan.along)
		if d < best then
			best, bestGate = d, hit.gi
		end
	end
	dist[edge.a] = plan.along
	dist[edge.b] = (edge.length or (flat(edge.b.position) - flat(edge.a.position)).Magnitude) - plan.along
	while true do
		local node, nd = nil, math.huge
		for n, d in pairs(dist) do
			if not done[n] and d < nd then
				node, nd = n, d
			end
		end
		if not node or nd >= best then
			break
		end
		done[node] = true
		for _, e in ipairs(adjacency[node] or {}) do
			local length = e.length or (flat(e.b.position) - flat(e.a.position)).Magnitude
			for _, hit in ipairs(gatewayOn(e)) do
				local d = nd + (e.a == node and hit.along or (length - hit.along))
				if d < best then
					best, bestGate = d, hit.gi
				end
			end
			local other = e.a == node and e.b or e.a
			if not done[other] and nd + length < (dist[other] or math.huge) then
				dist[other] = nd + length
			end
		end
	end
	if not bestGate then
		return nil
	end
	return best, bestGate
end

-- Where a base vehicle leaving its bay goes, after its straight lane out, to reach the access road:
-- nothing when its lane already leaves by the gate the road starts at; else round the compound's
-- nearest front corner (outside it, `corner` local) to the road's start. `frame` is the compound's,
-- `look` the vehicle's nose (flat), `gateLook` the heading the road left its gate with. Flat points.
function TeamBaseRoads.DriveVia(frame, plan, look, corner)
	local gateLook = flat(plan.heading or frame.LookVector).Unit
	if flat(look).Unit:Dot(gateLook) > 0.7 then
		return {}
	end
	local start = plan.points[1]
	return { flat(frame * corner), flat(start + gateLook * 12) }
end

-- The fairest pair of routes, one from each team's list of options (each with .total): the shortest
-- longer way of the pairs within `share` of each other, else the pair that differs least. Returns
-- { route1, route2 } and the pair's difference as a share of the longer.
function TeamBaseRoads.ChooseFair(first, second, share)
	local chosen, bestLong, bestGap = {}, math.huge, math.huge
	for _, p1 in ipairs(first) do
		for _, p2 in ipairs(second) do
			local long = math.max(p1.total, p2.total)
			local gap = math.abs(p1.total - p2.total) / math.max(long, 1)
			local fair, wasFair = gap <= share, bestGap <= share
			if (fair and (not wasFair or long < bestLong)) or (not fair and not wasFair and gap < bestGap) then
				chosen, bestLong, bestGap = { p1, p2 }, long, gap
			end
		end
	end
	if not chosen[1] then
		return { first[1], second[1] }, nil
	end
	return chosen, bestGap
end

-- The shortest acceptable route from `start` (the end of the gate's ramp) out along `heading` to any
-- road edge. options: avoid = { { centre, radius, name } }, blocked(a, b) -> why | nil.
-- `start` may be a list of { position, heading } (a compound's gates): the best route out of any.
function TeamBaseRoads.Plan(start, heading, roads, options)
	options = options or {}
	if not roads or not roads.edges or #roads.edges == 0 then
		return nil, "no roads"
	end
	local starts = heading and { { position = start, heading = heading } } or start
	local found, reasons = {}, {}
	for gateIndex, gate in ipairs(starts) do
		local from, dir = flat(gate.position), flat(gate.heading).Unit
		local ranked = {}
		if options.targets then
			-- Only the arena gateways' roads, outside their gateways (TeamBaseRoads.GatewayTargets).
			for _, target in ipairs(options.targets) do
				local a, b = flat(target.edge.from or target.edge.a.position), flat(target.edge.to or target.edge.b.position)
				table.insert(ranked, { edge = target.edge, target = target, d = distanceToSegment(from, a, b) })
			end
		else
			for _, edge in ipairs(roads.edges) do
				if not edge.blocked and not (edge.bridges and #edge.bridges > 0) then
					local a, b = flat(edge.from or edge.a.position), flat(edge.to or edge.b.position)
					table.insert(ranked, { edge = edge, d = distanceToSegment(from, a, b) })
				end
			end
		end
		table.sort(ranked, function(p, q)
			return p.d < q.d
		end)
		-- The grid planner too, over the nearest few (it finds a way where no single curve does).
		local near = {}
		for index = 1, math.min(#ranked, 12) do
			table.insert(near, ranked[index])
		end
		local gridFound = gridRoutes(from, dir, near, roads, options)
		for _, route in ipairs(gridFound) do
			route.gate, route.heading = gateIndex, dir
			table.insert(found, route)
		end
		if gridFound.why then
			reasons["grid: " .. gridFound.why] = (reasons["grid: " .. gridFound.why] or 0) + 1
		end
		for index = 1, math.min(#ranked, 24) do
			for _, shift in ipairs(SHIFTS) do
				for _, tension in ipairs(TENSIONS) do
					local route, reason = routeTo(from, dir, ranked[index].edge, roads, options, shift, tension, ranked[index].target)
					if route then
						route.gate, route.heading = gateIndex, dir
						table.insert(found, route)
					else
						reasons[reason] = (reasons[reason] or 0) + 1
					end
				end
			end
		end
	end
	-- The shortest first; only those are asked about what stands in the way (a query per stretch).
	table.sort(found, function(p, q)
		return p.total < q.total
	end)
	for _, route in ipairs(found) do
		local why = blockedRoute(route, options)
		-- With the ground to hand (options.groundAt, options.startY per gate), a route whose profile
		-- cannot keep to the grade over it (the ground climbs too hard at an end) is passed over too.
		if not why and options.groundAt then
			local startY = type(options.startY) == "table" and options.startY[route.gate] or options.startY
			local heights, stats = TeamBaseRoads.Profile(route, options.groundAt, startY or 0)
			route.heights, route.stats = heights, stats
			if stats.grade > MAX_GRADE + 0.005 or stats.pitch > MAX_PITCH + 0.3 then
				why = "too steep for the ground"
			elseif stats.earthwork > MAX_EARTH then
				why = "too much cutting (round the hill)"
			end
		end
		if not why then
			return route
		end
		reasons[why] = (reasons[why] or 0) + 1
	end
	local summary = {}
	for reason, count in pairs(reasons) do
		table.insert(summary, reason .. " x" .. count)
	end
	table.sort(summary)
	return nil, #summary > 0 and table.concat(summary, ", ") or "no edge"
end

-- THE VERTICAL CURVE (Oliver, 2026-09-24: "make the roads to the bases smoother on the hills"). The
-- road's own profile, graded, not the terrain's bumps: the ground along the centre line smoothed hard,
-- pinned to the gate's height and the joined road's surface, then held to MAX_GRADE and to at most
-- MAX_PITCH of change in pitch between one stretch and the next (gentle crests and sags); the ground
-- is then cut and filled to it (ShapeGround). Returns the heights (the road's ground; its top is Lift
-- over) and { grade, pitch, earthwork } -- the steepest grade, the biggest pitch change in degrees,
-- the deepest cut or fill -- for the planner to refuse a route the hill is too steep for.
function TeamBaseRoads.Profile(plan, groundAt, startY)
	local points = plan.points
	local n = #points
	local edge = plan.edge
	local endY = startY
	if edge.heights and edge.step then
		local k = math.clamp(plan.along / edge.step, 0, #edge.heights - 1)
		local i = math.floor(k)
		local f = k - i
		local h0 = edge.heights[i + 1]
		local h1 = edge.heights[math.min(i + 2, #edge.heights)]
		endY = h0 + (h1 - h0) * f
	elseif groundAt then
		endY = groundAt(plan.join.X, plan.join.Z) or startY
	end
	local ground, heights = {}, {}
	for i, p in ipairs(points) do
		ground[i] = (groundAt and groundAt(p.X, p.Z)) or startY
		heights[i] = ground[i]
	end
	local function pin()
		heights[1], heights[n] = startY, endY
	end
	-- A running average over the samples, many passes: the long shape of the hill, not its bumps.
	for _ = 1, SMOOTH_PASSES do
		local copy = table.clone(heights)
		for i = 2, n - 1 do
			heights[i] = (copy[i - 1] + copy[i] + copy[i + 1]) / 3
		end
		pin()
	end
	-- The grade and the pitch change, relaxed in turn until both hold.
	local bend = math.tan(math.rad(MAX_PITCH))
	for _ = 1, 300 do
		for i = 2, n do
			local d = (points[i] - points[i - 1]).Magnitude * MAX_GRADE
			heights[i] = math.clamp(heights[i], heights[i - 1] - d, heights[i - 1] + d)
		end
		pin()
		for i = n - 1, 1, -1 do
			local d = (points[i + 1] - points[i]).Magnitude * MAX_GRADE
			heights[i] = math.clamp(heights[i], heights[i + 1] - d, heights[i + 1] + d)
		end
		pin()
		for i = 2, n - 1 do
			local d0 = (points[i] - points[i - 1]).Magnitude
			local d1 = (points[i + 1] - points[i]).Magnitude
			local g0 = (heights[i] - heights[i - 1]) / d0
			local g1 = (heights[i + 1] - heights[i]) / d1
			local excess = math.abs(g1 - g0) - bend
			if excess > 0 then
				-- Move this sample toward the line through its neighbours by as much as the excess asks.
				local shift = math.sign(g1 - g0) * excess * (d0 * d1) / (d0 + d1)
				heights[i] += shift
			end
		end
		pin()
	end
	local stats = { grade = 0, pitch = 0, earthwork = 0 }
	for i = 2, n do
		local d = (points[i] - points[i - 1]).Magnitude
		stats.grade = math.max(stats.grade, math.abs(heights[i] - heights[i - 1]) / d)
		if i < n then
			local g0 = (heights[i] - heights[i - 1]) / d
			local g1 = (heights[i + 1] - heights[i]) / (points[i + 1] - points[i]).Magnitude
			stats.pitch = math.max(stats.pitch, math.deg(math.abs(math.atan(g1) - math.atan(g0))))
		end
	end
	for i = 1, n do
		stats.earthwork = math.max(stats.earthwork, math.abs(heights[i] - ground[i]))
	end
	return heights, stats
end

-- THE GROUND TO THE ROAD. Where the ground should stand at flat point (x, z), given the ground there
-- now (`natural`): under the carriageway and its shoulders, just under the road's own ground (the
-- slabs lie on it); beyond, a bank at BANK_SLOPE (35 degrees) back to the natural ground, cut or fill;
-- nil when the road does not reach (x, z).
local function nearestOnRoad(points, heights, x, z)
	local best, bestH = math.huge, nil
	local p = Vector3.new(x, 0, z)
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		local ab = b - a
		local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-9), 0, 1)
		local d = (p - (a + ab * t)).Magnitude
		if d < best then
			best, bestH = d, heights[i - 1] + (heights[i] - heights[i - 1]) * t
		end
	end
	return best, bestH
end

function TeamBaseRoads.GroundTarget(points, heights, x, z, natural)
	local d, h = nearestOnRoad(points, heights, x, z)
	if not h then
		return nil
	end
	local bed = h - GROUND_UNDER
	local flatHalf = HALF + SHOULDER
	if d <= flatHalf then
		return bed
	end
	local e = d - flatHalf
	if e > BANK_REACH then
		return nil
	end
	return math.clamp(natural, bed - e * BANK_SLOPE, bed + e * BANK_SLOPE)
end
TeamBaseRoads.BankSlope, TeamBaseRoads.BankReach, TeamBaseRoads.Shoulder = BANK_SLOPE, BANK_REACH, SHOULDER

-- Cuts and fills the terrain to the road (GroundTarget), column by column on the 4-stud voxel grid,
-- with the top cell's occupancy set to the fraction under the target (so the surface stands where it
-- is meant to, not rounded up to a whole cell -- what FillBlock did, burying the asphalt).
function TeamBaseRoads.ShapeGround(terrain, plan, heights)
	local points = plan.points
	local reach = HALF + SHOULDER + BANK_REACH + CELL
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	local y0, y1 = math.huge, -math.huge
	for i, p in ipairs(points) do
		x0, x1 = math.min(x0, p.X - reach), math.max(x1, p.X + reach)
		z0, z1 = math.min(z0, p.Z - reach), math.max(z1, p.Z + reach)
		y0, y1 = math.min(y0, heights[i]), math.max(y1, heights[i])
	end
	local function snap(v, up)
		return (up and math.ceil(v / CELL) or math.floor(v / CELL)) * CELL
	end
	x0, z0, x1, z1 = snap(x0), snap(z0), snap(x1, true), snap(z1, true)
	y0, y1 = snap(y0 - BANK_REACH * BANK_SLOPE - 2 * CELL), snap(y1 + BANK_REACH * BANK_SLOPE + 2 * CELL, true)
	local region = Region3.new(Vector3.new(x0, y0, z0), Vector3.new(x1, y1, z1))
	local materials, occupancy = terrain:ReadVoxels(region, CELL)
	local size = materials.Size
	local changed = 0
	for ix = 1, size.X do
		local x = x0 + (ix - 0.5) * CELL
		for iz = 1, size.Z do
			local z = z0 + (iz - 0.5) * CELL
			-- The natural surface: the top of the highest solid cell, by its occupancy.
			local natural = nil
			local solid = Enum.Material.Ground
			for iy = size.Y, 1, -1 do
				local m = materials[ix][iy][iz]
				if m ~= Enum.Material.Air and m ~= Enum.Material.Water and occupancy[ix][iy][iz] > 0 then
					natural = y0 + (iy - 1) * CELL + occupancy[ix][iy][iz] * CELL + TeamBaseRoads.SurfaceLift
					solid = m
					break
				end
			end
			local target = natural and TeamBaseRoads.GroundTarget(points, heights, x, z, natural)
			if target and math.abs(target - natural) > 0.05 then
				changed += 1
				for iy = 1, size.Y do
					local bottom = y0 + (iy - 1) * CELL
					local fill = math.clamp((target - TeamBaseRoads.SurfaceLift - bottom) / CELL, 0, 1)
					if materials[ix][iy][iz] ~= Enum.Material.Water then
						occupancy[ix][iy][iz] = fill
						if fill > 0 and materials[ix][iy][iz] == Enum.Material.Air then
							materials[ix][iy][iz] = solid
						elseif fill == 0 then
							materials[ix][iy][iz] = Enum.Material.Air
						end
					end
				end
			end
		end
	end
	terrain:WriteVoxels(region, CELL, materials, occupancy)
	return changed
end

-- A frame on the carriageway's centre line from `p` to `q` (3D, on the road's top), its look along it.
local function along(p, q)
	local forward = (q - p).Unit
	local right = forward:Cross(Vector3.new(0, 1, 0)).Unit
	local up = right:Cross(forward).Unit
	return CFrame.fromMatrix((p + q) / 2, right, up, -forward), up, right
end

-- How far each slab runs past its samples at each end, so the outside of a bend is covered and the
-- next slab's top meets it with a step of no more than JOIN_STEP (the overlap times the pitch change).
local function overhang(points, i)
	if i <= 1 or i >= #points then
		return 0
	end
	local u, v = (points[i] - points[i - 1]).Unit, (points[i + 1] - points[i]).Unit
	local turn = math.acos(math.clamp(u:Dot(v), -1, 1))
	return HALF * math.tan(turn / 2) + 0.05
end
TeamBaseRoads.Overhang = overhang

-- The road: slabs, lines, the stop line.
function TeamBaseRoads.Build(plan, heights, parent)
	local model = Instance.new("Model")
	model.Name = "AccessRoad"
	local lift = TeamBaseRoads.Lift
	-- Thick enough that the ground written under it (GROUND_UNDER down) is hidden however the voxels round.
	local thick = 2.4
	local points = plan.points
	local tops = {}
	for i, p in ipairs(points) do
		tops[i] = Vector3.new(p.X, heights[i] + lift, p.Z)
	end
	local function part(name, size, cf, color, material, collide)
		local piece = Instance.new("Part")
		piece.Name = name
		piece.Anchored = true
		piece.Size = size
		piece.CFrame = cf
		piece.Color = color
		piece.Material = material
		piece.TopSurface = Enum.SurfaceType.Smooth
		piece.BottomSurface = Enum.SurfaceType.Smooth
		if not collide then
			piece.CanCollide = false
			piece.CanQuery = false
			piece.CanTouch = false
		end
		piece.Parent = model
		return piece
	end
	local dashRun = 0
	for i = 2, #tops do
		local p, q = tops[i - 1], tops[i]
		local frame = along(p, q)
		local length = (q - p).Magnitude
		-- Past each end by the bend's overhang: the tops cross at the sample, the step between them
		-- the overhang times the pitch change (under JOIN_STEP with MAX_PITCH).
		local back, ahead = overhang(points, i - 1), overhang(points, i)
		local slab = frame * CFrame.new(0, -thick / 2, (back - ahead) / 2)
		part("RoadSurface", Vector3.new(TeamBaseRoads.Width, thick, length + back + ahead), slab, ASPHALT, Enum.Material.Asphalt, true)
		for _, side in ipairs({ -1, 1 }) do
			part("RoadEdge", Vector3.new(0.4, 0.07, length), frame * CFrame.new(side * (HALF - 0.9), 0.035, 0), LINE, Enum.Material.SmoothPlastic)
		end
		-- The dashed centre line, 6 on and 10 off, carried across the samples.
		local s = 0
		while s < length - 0.01 do
			local phase = (dashRun + s) % 16
			local run = phase < 6 and math.min(6 - phase, length - s) or math.min(16 - phase, length - s)
			if phase < 6 and run > 0.3 then
				part("RoadDash", Vector3.new(0.5, 0.07, run), frame * CFrame.new(0, 0.035, length / 2 - s - run / 2), LINE, Enum.Material.SmoothPlastic)
			end
			s += run
		end
		dashRun += length
	end
	-- The stop line across the access road, just short of the junction.
	local n = #tops
	local frame = along(tops[n - 1], tops[n])
	part("StopLine", Vector3.new(TeamBaseRoads.Width - 2, 0.07, 0.6), frame * CFrame.new(0, 0.035, -((tops[n] - tops[n - 1]).Magnitude / 2) + 1.2),
		LINE, Enum.Material.SmoothPlastic)
	model.Parent = parent
	return model
end

-- Joins the access road into `roads` for BotNav: the target edge split at the junction, a chain of
-- nodes from there to the gate. Returns the undo (puts the network back as it was).
function TeamBaseRoads.Register(roads, plan, heights)
	local edge = plan.edge
	local a, b = edge.a, edge.b
	local from = flat(edge.from or a.position)
	local to = flat(edge.to or b.position)
	local junction = { position = flat(plan.centre), arms = {}, index = #roads.edges + 1000, access = true }
	local function newEdge(p, q, name, back)
		local e = { a = p, b = q, from = p.position, to = q.position, length = (q.position - p.position).Magnitude, access = true }
		p.arms[name] = e
		q.arms[back] = e
		return e
	end
	local armA, armB
	for name, e in pairs(a.arms) do
		if e == edge then
			armA = name
		end
	end
	for name, e in pairs(b.arms) do
		if e == edge then
			armB = name
		end
	end
	local first = newEdge(a, junction, armA or "access", armB or "back")
	local second = newEdge(junction, b, armA or "access2", armB or "back2")
	local added = { first, second }
	local chain = junction
	for i = #plan.points - 1, 1, -1 do
		local p = plan.points[i]
		local node = { position = Vector3.new(p.X, 0, p.Z), arms = {}, access = true }
		table.insert(added, newEdge(chain, node, "up" .. i, "down" .. i))
		chain = node
	end
	local _ = heights
	-- Swap the target edge for its two halves; the chain's edges go on the end.
	local index = table.find(roads.edges, edge)
	if index then
		table.remove(roads.edges, index)
	end
	for _, e in ipairs(added) do
		table.insert(roads.edges, e)
	end
	local gate = chain
	return function()
		for _, e in ipairs(added) do
			local at = table.find(roads.edges, e)
			if at then
				table.remove(roads.edges, at)
			end
		end
		if index then
			table.insert(roads.edges, index, edge)
		end
		if armA then
			a.arms[armA] = edge
		end
		if armB then
			b.arms[armB] = edge
		end
	end, gate, junction
end

return TeamBaseRoads
