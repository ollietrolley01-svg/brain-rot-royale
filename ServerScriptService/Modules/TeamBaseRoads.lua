-- The access road from each team base's gatehouse to the map's road network (Oliver, 2026-09-24:
-- "make sure the team bases connect to the roads too"). Team matches only: ModeTeams builds it with
-- the compounds and it goes with them (it is parented into the compound's model), so a battle royale
-- map never has one.
--
--   TeamBaseRoads.Plan(start, heading, roads, options)  -> plan | nil, why     pure: no instances
--   TeamBaseRoads.Profile(plan, groundAt, startY)        -> heights            pure
--   TeamBaseRoads.Build(plan, heights, parent, terrain)  -> model              the road and its ground
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
-- THE HEIGHTS. The ground along the route, smoothed, held to MAX_GRADE, pinned to the gate's ramp at
-- one end and to the road's own surface at the other. The ground under the carriageway and its
-- shoulders is then written flat to those heights (a cutting or an embankment), so the slabs lie on it.
--
-- THE SURFACE. A run of asphalt slabs whose TOP edges meet at every sample (a change of grade is a
-- crease, as RoadNetwork builds its roads), a joint disc under each crease a hair lower filling the
-- outside of a bend, white edge lines, the dashed centre line, and a stop line at the junction.
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
local MAX_GRADE = 1 / 8
TeamBaseRoads.MinRadius, TeamBaseRoads.MaxGrade, TeamBaseRoads.Step = MIN_RADIUS, MAX_GRADE, STEP
-- The junction keeps this far from either end of the edge it joins (the boxes and bends there).
local END_CLEAR = 36
-- Straight on out of the gate before any turn.
local LEAD = 24
-- Straight in, square to the road, for the last stretch before the junction.
local APPROACH = 14
-- The ground work each side of the carriageway, and how far up a cutting is cleared.
local SHOULDER = 4
local CUT_HEIGHT = 40
local FILL_DEPTH = 30
local GROUND_DROP = 1.2

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

-- One candidate route to `edge` from `start` heading `heading` (flat unit vectors), or nil and why.
local function routeTo(start, heading, edge, roads, options, shift, tension)
	local a, b = flat(edge.from or edge.a.position), flat(edge.to or edge.b.position)
	local along = b - a
	local length = along.Magnitude
	if length < 2 * END_CLEAR + TeamBaseRoads.Width then
		return nil, "edge too short"
	end
	local dir = along / length
	local lead = start + heading * LEAD
	local t = math.clamp((lead - a):Dot(dir) + (shift or 0), END_CLEAR + HALF, length - END_CLEAR - HALF)
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
	-- The rules.
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
	return { points = path, edge = edge, along = t, join = join, centre = centre, normal = normal, length = total }
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

-- Where along an edge the junction may go (from the lead's own square-on point) and how hard the
-- curve pulls: more than one of each is tried, so a road the plain curve cannot reach is still found.
local SHIFTS = { 0, -45, 45, -100, 100 }
local TENSIONS = { 0.42, 0.28, 0.6 }

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
		for _, edge in ipairs(roads.edges) do
			if not edge.blocked and not (edge.bridges and #edge.bridges > 0) then
				local a, b = flat(edge.from or edge.a.position), flat(edge.to or edge.b.position)
				table.insert(ranked, { edge = edge, d = distanceToSegment(from, a, b) })
			end
		end
		table.sort(ranked, function(p, q)
			return p.d < q.d
		end)
		for index = 1, math.min(#ranked, 24) do
			for _, shift in ipairs(SHIFTS) do
				for _, tension in ipairs(TENSIONS) do
					local route, reason = routeTo(from, dir, ranked[index].edge, roads, options, shift, tension)
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
		return p.length < q.length
	end)
	for _, route in ipairs(found) do
		local why = blockedRoute(route, options)
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

-- The road's height at each point: the ground, smoothed, held to MAX_GRADE, from `startY` at the gate
-- to the target road's own surface height at the junction.
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
	local heights = {}
	for i, p in ipairs(points) do
		heights[i] = (groundAt and groundAt(p.X, p.Z)) or startY
	end
	-- Smooth: a few passes of a 5-point average, ends pinned.
	for _ = 1, 4 do
		local copy = table.clone(heights)
		for i = 3, n - 2 do
			heights[i] = (copy[i - 2] + copy[i - 1] + copy[i] + copy[i + 1] + copy[i + 2]) / 5
		end
		heights[1], heights[n] = startY, endY
		heights[2] = (startY + heights[3]) / 2
		heights[n - 1] = (endY + heights[n - 2]) / 2
	end
	-- Held to the grade from both ends.
	for _ = 1, 8 do
		heights[1], heights[n] = startY, endY
		for i = 2, n do
			local d = (points[i] - points[i - 1]).Magnitude * MAX_GRADE
			heights[i] = math.clamp(heights[i], heights[i - 1] - d, heights[i - 1] + d)
		end
		heights[1], heights[n] = startY, endY
		for i = n - 1, 1, -1 do
			local d = (points[i + 1] - points[i]).Magnitude * MAX_GRADE
			heights[i] = math.clamp(heights[i], heights[i + 1] - d, heights[i + 1] + d)
		end
	end
	heights[1], heights[n] = startY, endY
	return heights
end

-- A frame on the carriageway's centre line from `p` to `q` (3D, on the road's top), its look along it.
local function along(p, q)
	local forward = (q - p).Unit
	local right = forward:Cross(Vector3.new(0, 1, 0)).Unit
	local up = right:Cross(forward).Unit
	return CFrame.fromMatrix((p + q) / 2, right, up, -forward), up, right
end

-- The road: slabs, joints, lines, the stop line; and the ground under it written flat.
function TeamBaseRoads.Build(plan, heights, parent, terrain)
	local model = Instance.new("Model")
	model.Name = "AccessRoad"
	local lift = TeamBaseRoads.Lift
	-- Thick enough to reach down past the ground written under it (voxels round the surface a little).
	local thick = 2.2
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
		local frame, up = along(p, q)
		local length = (q - p).Magnitude
		part("RoadSurface", Vector3.new(TeamBaseRoads.Width, thick, length), frame * CFrame.new(0, -thick / 2, 0), ASPHALT, Enum.Material.Asphalt, true)
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
		local _ = up
		-- The ground under it: dead flat to the road's ground across the carriageway and shoulders.
		if terrain then
			local mid = (points[i - 1] + points[i]) / 2
			local h = (heights[i - 1] + heights[i]) / 2
			local flatFrame = CFrame.lookAt(Vector3.new(mid.X, h, mid.Z), Vector3.new(points[i].X, h, points[i].Z))
			local width = TeamBaseRoads.Width + 2 * SHOULDER
			local long = length + 2
			pcall(function()
				-- The ground left 1.2 under the road's own ground, the slabs reaching down to it: whatever
				-- the voxels round the surface to, it never comes up through the asphalt.
				terrain:FillBlock(flatFrame * CFrame.new(0, CUT_HEIGHT / 2 - GROUND_DROP, 0), Vector3.new(width, CUT_HEIGHT, long), Enum.Material.Air)
				terrain:FillBlock(flatFrame * CFrame.new(0, -FILL_DEPTH / 2 - GROUND_DROP, 0), Vector3.new(width, FILL_DEPTH, long), Enum.Material.Ground)
			end)
		end
	end
	-- A joint under each crease, a hair under the slabs' tops, filling the outside of the bend.
	for i = 2, #tops - 1 do
		local p = tops[i]
		part("RoadJoint", Vector3.new(thick, TeamBaseRoads.Width, TeamBaseRoads.Width), CFrame.new(p.X, p.Y - 0.08 - thick / 2, p.Z) * CFrame.Angles(0, 0, math.pi / 2),
			ASPHALT, Enum.Material.Asphalt, true).Shape = Enum.PartType.Cylinder
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
