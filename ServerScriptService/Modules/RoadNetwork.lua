-- The roads between towns: planned as a network, laid on ground shaped for them, joined flush.
--
-- Planning. Every town's streets leave its square on the four world axes, so every road here runs
-- on those axes too: out of a town's street mouth, straight on past the edge of town, then across
-- country in straight runs joined by square bends, and into the next town along the axis of the
-- street it meets. A road never needs a joint at an angle, which is what makes every join below
-- exactly flush instead of nearly.
--
-- Towns are joined cheapest-first until the network reaches every town, then a few extra roads
-- go in where the network made two towns a long way round. Each road takes the best route it can
-- find through the rules: it keeps off every town, never runs alongside another road, and keeps
-- its bends, crossings and junctions well apart so each one has room for its markings and
-- furniture. A town has four mouths; when a road can't get a free one it joins an existing road at
-- a T-junction instead. Two roads crossing make a four-way junction.
--
-- Heights. Each road gets a height profile before any terrain is written: the ground along it,
-- smoothed, held under a maximum grade, and dead level for a stretch either side of every
-- junction and bend so the box there meets level arms. The relief pass then shapes the terrain to
-- the road: dead flat to the road's ground height across the carriageway and shoulders, blending
-- back into the natural ground as a cutting or an embankment. Nothing floats and nothing is buried.
--
-- Building. A road surface is a run of slabs whose TOP faces meet edge to edge at every sample,
-- so a change of grade is a crease, never a step or an overlap. Junction boxes, bends, stop lines,
-- edge lines and centre markings are laid so no two of them share a face (MapDecor.Junction draws
-- the boxes); a four-way crossing gets traffic lights, the stem of a T gets a stop sign.
--
--   RoadNetwork.Plan(centers, shape, radius)  -> network
--   network:Claim(space)                       claims every road's corridor
--   network:ComputeHeights(naturalAt, preset)  profiles (MapTerrain.Relief calls this)
--   network:GroundAt(x, z, natural)            -> shaped ground height, material (or nil)
--   network:Build(parent, context)             surfaces, junctions, bridges, lamps, signs
--   network:MouthsOf(townIndex)                -> { E = true, ... } mouths with a road

local MapDecor = require(script.Parent:WaitForChild("MapDecor"))

local RoadNetwork = {}
RoadNetwork.__index = RoadNetwork

RoadNetwork.Width = 18
-- Road top above the ground under it, as in the towns (asphalt from the ground to +0.4).
RoadNetwork.Lift = MapDecor.RoadLift
-- Kept clear of everything else, measured from the centre line.
RoadNetwork.ClaimWidth = 24
-- Clear ground between two towns' footprints, for a road and its corridor to pass between them.
RoadNetwork.TownGap = 140

local HALF = RoadNetwork.Width / 2
local LIFT = RoadNetwork.Lift
-- Slabs reach well under the ground so the terrain's own smoothing never shows a gap beneath an edge.
local THICKNESS = 0.8
-- Every other slab is this much narrower each side, and this much shallower, so neighbours' faces
-- never share a plane: more than the z-fight pass's tolerance, far less than anything you'd see.
-- The depth needs more room than the width, because where the grade changes the two slabs' bottoms
-- tilt apart by up to half a slab's length times the change of grade.
local SLAB_STAGGER = 0.07
local SLAB_STAGGER_DEPTH = 0.15
local SHOULDER = 3

-- Planning.
local APPROACH = 40 -- straight run past a town's footprint before a road may turn
local KEEP_MARGIN = 20 -- how far roads stay off a town's footprint
local NODE_GAP = 80 -- spacing between any two bends, junctions and crossings
local PARALLEL_GAP = 110 -- how close two parallel roads may run where they overlap
local BEND_COST = 70
-- Curves. Between towns a bend is a real curve rather than a square corner wherever there is room:
-- an arc tangent to both arms, cutting the corner, reaching CURVE radius back along each arm. The
-- arc is level, like a junction piece, because a graded curve can't be built from flat pieces
-- without a step at its edges; the climb is taken on the straights either side. Junctions, town
-- street ends and bridges keep their straight approaches exactly as they are.
local CURVE_MAX_RADIUS = 90
-- The tightest arc worth building, and the floor is geometry rather than taste: the inner edge of the
-- carriageway runs at radius - HALF, so anything under about 14 has no inner edge left. A tight arc
-- still reads as a turn; a right angle never does. An earlier floor of 46 quietly turned most bends
-- back into square corners, because bends are spaced NODE_GAP apart and neither end could claim that
-- much -- 22 curves out of 79 bends across ten builds, which is not what "curve the bends" means.
local CURVE_MIN_RADIUS = HALF + 5
local CURVE_PIECE = 8 -- longest piece of arc, in studs
-- ...and the tightest, in ANGLE: a fixed 8-stud piece turns 30 degrees at a joint on a 15-stud
-- radius, which is a corner of its own. Every joint between two pieces of a curve turns by at most
-- this, however tight the arc.
local CURVE_MAX_TURN = math.rad(10)
local CURVE_STRAIGHT = 12 -- straight road kept between a curve and whatever comes next
local CURVE_CLEAR = 45 -- how far a curve stays off other roads and their junctions
local T_COST = 60
local CROSS_BONUS = 40

-- Heights.
local PROFILE_STEP = 8
local MAX_GRADE = 0.1
-- The grade changes no faster than a vertical curve of this radius: over one 8-stud sample, about
-- half a degree, which keeps every crease between slabs invisible.
local CURVE_RADIUS = 1000
local FLAT_RUN = 26 -- level road beyond a junction box before the grade may start
local BRIDGE_RUN = 20 -- straight road beyond each end of a bridge
local BRIDGE_MIN_HEIGHT = 0.6 -- road ground over a bridge never lower than this (the water is at -1)
local BRIDGE_EASE = 5 -- free samples kept between a junction's level stretch and a bridge's straight one
-- The lowest a bridge's road ground may go when nothing higher fits: the deck reaches 1.2 under the
-- road ground and the water's surface is at -1.
local BRIDGE_FLOOR = 0.25
local BLEND_MAX = 60
-- Flat ground past the shoulders before any bank starts. Smooth terrain draws its surface through
-- the neighbouring voxels (4 studs apart) as well as the one underneath, so a bank that starts right
-- at the shoulder bends the shoulder up or down with it; two voxels of flat keep the carriageway and
-- the shoulders true however steep the bank beyond.
local BANK_SETBACK = 8
local REACH = HALF + SHOULDER + BANK_SETBACK + BLEND_MAX

-- Terrain materials whose surface lies exactly where the voxels put it. Measured for every terrain
-- material (a flat voxel write raycast on a 1-stud grid at three heights, tools/road_terrain_probe.lua):
-- these are true to ±0.006. The rest are not: Rock (±1.1), Basalt (±0.7), Ice (±0.6), Slate and
-- CrackedLava (±0.4) draw a rough surface over the same voxels; Pavement snaps it to the nearest
-- whole stud, Concrete to the nearest two, Brick and WoodPlanks down to the voxel below, and
-- Cobblestone to a finer grid; and a rough or stepped material disturbs a smooth one beside it up to
-- about 4 studs in. Only these go under a road, on its shoulders or on the flat ground beside it.
RoadNetwork.SmoothMaterials = {
	[Enum.Material.Asphalt] = true,
	[Enum.Material.Glacier] = true,
	[Enum.Material.Grass] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.LeafyGrass] = true,
	[Enum.Material.Limestone] = true,
	[Enum.Material.Mud] = true,
	[Enum.Material.Salt] = true,
	[Enum.Material.Sand] = true,
	[Enum.Material.Sandstone] = true,
	[Enum.Material.Snow] = true,
}
local GRID_CELL = 64

local AXIS = {
	E = Vector3.new(1, 0, 0),
	W = Vector3.new(-1, 0, 0),
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
}
local MOUTH_ORDER = { "E", "W", "N", "S" }
local OPPOSITE = { E = "W", W = "E", N = "S", S = "N" }

local EPS = 1e-6

--------------------------------------------------------------------------------
-- Geometry on the ground plane (Y ignored)
--------------------------------------------------------------------------------

local function dirName(v)
	if math.abs(v.X) > math.abs(v.Z) then
		return v.X > 0 and "E" or "W"
	end
	return v.Z > 0 and "N" or "S"
end

local function flatDistance(a, b)
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function aligned(a, b)
	return math.abs(a.X - b.X) < EPS or math.abs(a.Z - b.Z) < EPS
end

-- Which axis an axis-aligned segment runs along, the fixed coordinate, and its range.
local function axisOf(a, b)
	if math.abs(a.Z - b.Z) < EPS then
		return "x", a.Z, math.min(a.X, b.X), math.max(a.X, b.X)
	end
	return "z", a.X, math.min(a.Z, b.Z), math.max(a.Z, b.Z)
end

local function pointSegmentDistance(p, a, b)
	local axis, coord, lo, hi = axisOf(a, b)
	if axis == "x" then
		local x = math.clamp(p.X, lo, hi)
		return math.sqrt((p.X - x) ^ 2 + (p.Z - coord) ^ 2)
	end
	local z = math.clamp(p.Z, lo, hi)
	return math.sqrt((p.X - coord) ^ 2 + (p.Z - z) ^ 2)
end

-- Where two perpendicular axis-aligned segments cross (ends included), or nil.
local function crossing(a, b, c, d)
	local axis1, c1, lo1, hi1 = axisOf(a, b)
	local axis2, c2, lo2, hi2 = axisOf(c, d)
	if axis1 == axis2 then
		return nil
	end
	if axis1 == "x" then
		if c2 >= lo1 and c2 <= hi1 and c1 >= lo2 and c1 <= hi2 then
			return Vector3.new(c2, 0, c1)
		end
	elseif c1 >= lo2 and c1 <= hi2 and c2 >= lo1 and c2 <= hi1 then
		return Vector3.new(c1, 0, c2)
	end
	return nil
end

local function isEndpoint(p, a, b)
	return flatDistance(p, a) < 1e-4 or flatDistance(p, b) < 1e-4
end

local function samePoint(a, b)
	return flatDistance(a, b) < 1e-4
end

local function boxHitsSegment(center, hx, hz, a, b)
	local axis, coord, lo, hi = axisOf(a, b)
	if axis == "x" then
		return math.abs(coord - center.Z) < hz and hi > center.X - hx and lo < center.X + hx
	end
	return math.abs(coord - center.X) < hx and hi > center.Z - hz and lo < center.Z + hz
end

-- Drops repeated points and the middle of any three in a line.
local function tidy(points)
	local out = { points[1] }
	for index = 2, #points do
		if not samePoint(points[index], out[#out]) then
			table.insert(out, points[index])
		end
	end
	local index = 2
	while index < #out do
		local a, b, c = out[index - 1], out[index], out[index + 1]
		local sameX = math.abs(a.X - b.X) < EPS and math.abs(b.X - c.X) < EPS
		local sameZ = math.abs(a.Z - b.Z) < EPS and math.abs(b.Z - c.Z) < EPS
		if sameX or sameZ then
			table.remove(out, index)
		else
			index += 1
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Planning
--------------------------------------------------------------------------------

local function mouthPoint(town, name)
	local direction = AXIS[name]
	return town.center + direction * (direction.Z == 0 and town.half or town.cross)
end

-- Where a road out of this mouth is clear of the town's footprint and may turn.
local function exitPoint(town, name)
	local direction = AXIS[name]
	return town.center + direction * ((direction.Z == 0 and town.half or town.zext) + KEEP_MARGIN + APPROACH)
end

function RoadNetwork.new(radius, towns)
	local self = setmetatable({ radius = radius, towns = towns, roads = {}, parent = {} }, RoadNetwork)
	for index = 1, #towns do
		self.parent[index] = index
	end
	return self
end

function RoadNetwork:_find(index)
	while self.parent[index] ~= index do
		self.parent[index] = self.parent[self.parent[index]]
		index = self.parent[index]
	end
	return index
end

function RoadNetwork:_union(a, b)
	self.parent[self:_find(a)] = self:_find(b)
end

function RoadNetwork:_segments()
	local list = {}
	for roadIndex, road in ipairs(self.roads) do
		for k = 1, #road.points - 1 do
			table.insert(list, { road = roadIndex, index = k, a = road.points[k], b = road.points[k + 1] })
		end
	end
	return list
end

function RoadNetwork:_crossings()
	local segments = self:_segments()
	local found = {}
	for i = 1, #segments do
		for j = i + 1, #segments do
			local s, t = segments[i], segments[j]
			if s.road ~= t.road then
				local point = crossing(s.a, s.b, t.a, t.b)
				if point and not isEndpoint(point, s.a, s.b) and not isEndpoint(point, t.a, t.b) then
					table.insert(found, point)
				end
			end
		end
	end
	return found
end

-- Bends, T-junctions and crossings already in the network.
function RoadNetwork:_junctionPoints()
	local list = {}
	for _, road in ipairs(self.roads) do
		for k = 2, #road.points - 1 do
			table.insert(list, road.points[k])
		end
		if road.target then
			table.insert(list, road.points[#road.points])
		end
	end
	for _, point in ipairs(self:_crossings()) do
		table.insert(list, point)
	end
	return list
end

-- Whether a route obeys every rule. `startMouth` is the mouth of `startTown` it leaves by;
-- `endMouth` the mouth of `endTown` it arrives at, or nil when it ends on `target` (a segment of an
-- existing road, as { road, index }). Returns its length and how many roads it crosses, or nil.
function RoadNetwork:_valid(points, startTown, startMouth, endTown, endMouth, target)
	local count = #points - 1
	if count < 1 then
		return nil
	end
	for _, point in ipairs(points) do
		if math.sqrt(point.X * point.X + point.Z * point.Z) > self.radius * 0.97 then
			return nil
		end
	end
	for k = 1, count do
		if samePoint(points[k], points[k + 1]) or not aligned(points[k], points[k + 1]) then
			return nil
		end
	end
	-- Runs between two bends need room for both.
	for k = 1, count do
		local interiorStart = k > 1
		local interiorEnd = k < count or target ~= nil
		if interiorStart and interiorEnd and flatDistance(points[k], points[k + 1]) < NODE_GAP then
			return nil
		end
	end

	-- Clear of every town, once past the stub that leaves its own town. The stub has to point out
	-- of the town and reach its exit before anything turns.
	local clipped = table.clone(points)
	clipped[1] = exitPoint(self.towns[startTown], startMouth)
	if endMouth then
		clipped[#clipped] = exitPoint(self.towns[endTown], endMouth)
	end
	for k = 1, count do
		local a, b = clipped[k], clipped[k + 1]
		if k == 1 and (b - a):Dot(AXIS[startMouth]) < -EPS then
			return nil
		end
		if k == count and endMouth and (a - b):Dot(AXIS[endMouth]) < -EPS then
			return nil
		end
		if not samePoint(a, b) then
			if not aligned(a, b) then
				return nil
			end
			for _, town in ipairs(self.towns) do
				if boxHitsSegment(town.center, town.half + KEEP_MARGIN, town.zext + KEEP_MARGIN, a, b) then
					return nil
				end
			end
		end
	end
	-- The stubs themselves, from each street end out to where the road may turn, must stay off every
	-- OTHER town: on a small map where two towns couldn't be spaced apart, a stub could otherwise run
	-- straight through the neighbouring town's blocks.
	local stubs = { { points[1], clipped[1], startTown } }
	if endMouth then
		table.insert(stubs, { points[#points], clipped[#clipped], endTown })
	end
	for _, stub in ipairs(stubs) do
		if not samePoint(stub[1], stub[2]) then
			for index, town in ipairs(self.towns) do
				if index ~= stub[3] and boxHitsSegment(town.center, town.half + KEEP_MARGIN, town.zext + KEEP_MARGIN, stub[1], stub[2]) then
					return nil
				end
			end
		end
	end

	-- Against the network so far.
	local existing = self:_junctionPoints()
	local newPoints = {}
	for k = 2, count do
		table.insert(newPoints, points[k])
	end
	if target then
		table.insert(newPoints, points[#points])
	end
	local crossings = 0
	for _, segment in ipairs(self:_segments()) do
		local ea, eb = segment.a, segment.b
		local axis2, c2, lo2, hi2 = axisOf(ea, eb)
		for k = 1, count do
			local a, b = points[k], points[k + 1]
			local axis1, c1, lo1, hi1 = axisOf(a, b)
			local isTarget = target ~= nil and target.road == segment.road and target.index == segment.index and k == count
			if axis1 == axis2 then
				if math.abs(c1 - c2) < PARALLEL_GAP and hi1 + NODE_GAP > lo2 and hi2 + NODE_GAP > lo1 then
					return nil
				end
			else
				local point = crossing(a, b, ea, eb)
				if point then
					if not (isTarget and samePoint(point, points[#points])) then
						if isEndpoint(point, a, b) or isEndpoint(point, ea, eb) then
							return nil
						end
						crossings += 1
						table.insert(newPoints, point)
					end
				else
					for _, p in ipairs({ a, b }) do
						local exempt = samePoint(p, points[1]) or (endMouth ~= nil and samePoint(p, points[#points]))
						if not exempt and pointSegmentDistance(p, ea, eb) < NODE_GAP then
							return nil
						end
					end
					for _, p in ipairs({ ea, eb }) do
						if pointSegmentDistance(p, a, b) < NODE_GAP then
							return nil
						end
					end
				end
			end
		end
	end
	for i, p in ipairs(newPoints) do
		for _, q in ipairs(existing) do
			if flatDistance(p, q) < NODE_GAP then
				return nil
			end
		end
		for j = i + 1, #newPoints do
			if flatDistance(p, newPoints[j]) < NODE_GAP then
				return nil
			end
		end
		for _, town in ipairs(self.towns) do
			if math.abs(p.X - town.center.X) < town.half + KEEP_MARGIN + NODE_GAP / 2
				and math.abs(p.Z - town.center.Z) < town.zext + KEEP_MARGIN + NODE_GAP / 2 then
				return nil
			end
		end
	end

	local length = 0
	for k = 1, count do
		length += flatDistance(points[k], points[k + 1])
	end
	return length, crossings
end

-- Routes from a free mouth of town i to a free mouth of town j: an L with one bend when the
-- mouths are at right angles, a straight run or a Z with two bends when they face each other, a
-- U round the back when they face the same way.
function RoadNetwork:_mouthRoutes(i, j)
	local ti, tj = self.towns[i], self.towns[j]
	local out = {}
	for _, mi in ipairs(MOUTH_ORDER) do
		if not ti.used[mi] then
			local di = AXIS[mi]
			local pi, ei = mouthPoint(ti, mi), exitPoint(ti, mi)
			for _, mj in ipairs(MOUTH_ORDER) do
				if not tj.used[mj] then
					local dj = AXIS[mj]
					local pj, ej = mouthPoint(tj, mj), exitPoint(tj, mj)
					local routes = {}
					local facing = di:Dot(dj)
					if math.abs(facing) < 0.5 then
						local corner = di.Z == 0 and Vector3.new(pj.X, 0, pi.Z) or Vector3.new(pi.X, 0, pj.Z)
						if (corner - ei):Dot(di) >= 0 and (corner - ej):Dot(dj) >= 0 then
							table.insert(routes, { pi, corner, pj })
						end
					elseif facing < 0 then
						local span = (ej - ei):Dot(di)
						if span >= 0 then
							local offset = di.Z == 0 and (pj.Z - pi.Z) or (pj.X - pi.X)
							if math.abs(offset) < EPS then
								table.insert(routes, { pi, pj })
							elseif math.abs(offset) >= NODE_GAP then
								for _, fraction in ipairs({ 0.5, 0.3, 0.7, 0.15, 0.85, 0, 1 }) do
									local m = ei:Dot(di) + fraction * span
									if di.Z == 0 then
										table.insert(routes, { pi, Vector3.new(m * di.X, 0, pi.Z), Vector3.new(m * di.X, 0, pj.Z), pj })
									else
										table.insert(routes, { pi, Vector3.new(pi.X, 0, m * di.Z), Vector3.new(pj.X, 0, m * di.Z), pj })
									end
								end
							end
						end
					else
						local base = math.max(ei:Dot(di), ej:Dot(di))
						for _, extra in ipairs({ 0, 60, 140 }) do
							local m = base + extra
							if di.Z == 0 then
								table.insert(routes, { pi, Vector3.new(m * di.X, 0, pi.Z), Vector3.new(m * di.X, 0, pj.Z), pj })
							else
								table.insert(routes, { pi, Vector3.new(pi.X, 0, m * di.Z), Vector3.new(pj.X, 0, m * di.Z), pj })
							end
						end
					end
					for _, route in ipairs(routes) do
						local points = tidy(route)
						local length, crossings = self:_valid(points, i, mi, j, mj, nil)
						if length then
							table.insert(out, {
								score = length + BEND_COST * (#points - 2) - CROSS_BONUS * crossings,
								points = points, startTown = i, startMouth = mi, endTown = j, endMouth = mj,
							})
						end
					end
				end
			end
		end
	end
	return out
end

-- Routes from a free mouth of town i onto any road already connected to town j, ending in a
-- T-junction: straight in when the mouth faces across that road, or with one bend when it runs
-- alongside it.
function RoadNetwork:_teeRoutes(i, j)
	local ti, tj = self.towns[i], self.towns[j]
	local component = self:_find(j)
	local out = {}
	for _, segment in ipairs(self:_segments()) do
		local road = self.roads[segment.road]
		if self:_find(road.startTown) == component then
			local axis, coord, lo, hi = axisOf(segment.a, segment.b)
			for _, mi in ipairs(MOUTH_ORDER) do
				if not ti.used[mi] then
					local di = AXIS[mi]
					local pi, ei = mouthPoint(ti, mi), exitPoint(ti, mi)
					local candidates = {}
					local mouthAlongX = di.Z == 0
					if (axis == "x") ~= mouthAlongX then
						if axis == "z" then
							if pi.Z >= lo + NODE_GAP and pi.Z <= hi - NODE_GAP then
								table.insert(candidates, { pi, Vector3.new(coord, 0, pi.Z) })
							end
						elseif pi.X >= lo + NODE_GAP and pi.X <= hi - NODE_GAP then
							table.insert(candidates, { pi, Vector3.new(pi.X, 0, coord) })
						end
					else
						local low, high = lo + NODE_GAP, hi - NODE_GAP
						if high >= low then
							local targets = axis == "x" and { ei.X, tj.center.X, (low + high) / 2 } or { ei.Z, tj.center.Z, (low + high) / 2 }
							for _, m in ipairs(targets) do
								m = math.clamp(m, low, high)
								if axis == "x" then
									table.insert(candidates, { pi, Vector3.new(m, 0, pi.Z), Vector3.new(m, 0, coord) })
								else
									table.insert(candidates, { pi, Vector3.new(pi.X, 0, m), Vector3.new(coord, 0, m) })
								end
							end
						end
					end
					for _, route in ipairs(candidates) do
						local points = tidy(route)
						if #points >= 2 then
							local target = { road = segment.road, index = segment.index }
							local length, crossings = self:_valid(points, i, mi, nil, nil, target)
							if length then
								local joint = points[#points]
								local detour = math.abs(joint.X - tj.center.X) + math.abs(joint.Z - tj.center.Z)
								table.insert(out, {
									score = length + BEND_COST * (#points - 2) - CROSS_BONUS * crossings + T_COST + 0.6 * detour,
									points = points, startTown = i, startMouth = mi, endTown = j, target = target,
								})
							end
						end
					end
				end
			end
		end
	end
	return out
end

function RoadNetwork:_add(choice)
	self.towns[choice.startTown].used[choice.startMouth] = true
	if choice.endMouth then
		self.towns[choice.endTown].used[choice.endMouth] = true
	end
	table.insert(self.roads, {
		points = choice.points,
		startTown = choice.startTown,
		startMouth = choice.startMouth,
		endTown = choice.endTown,
		endMouth = choice.endMouth,
		target = choice.target,
	})
	self:_union(choice.startTown, choice.endTown)
end

-- Shortest distance between two towns' squares along the roads, or math.huge.
function RoadNetwork:_networkDistance(i, j)
	local keys, positions, links = {}, {}, {}
	local function key(p)
		return string.format("%d:%d", math.floor(p.X * 100 + 0.5), math.floor(p.Z * 100 + 0.5))
	end
	local function node(p)
		local k = key(p)
		if not keys[k] then
			keys[k] = true
			positions[k] = p
			links[k] = {}
		end
		return k
	end
	local function link(p, q, weight)
		local a, b = node(p), node(q)
		table.insert(links[a], { b, weight })
		table.insert(links[b], { a, weight })
	end
	local points = self:_crossings()
	for _, road in ipairs(self.roads) do
		for _, p in ipairs(road.points) do
			table.insert(points, p)
		end
	end
	for _, segment in ipairs(self:_segments()) do
		local on = {}
		for _, p in ipairs(points) do
			if pointSegmentDistance(p, segment.a, segment.b) < 1e-3 then
				table.insert(on, p)
			end
		end
		table.sort(on, function(p, q)
			return flatDistance(p, segment.a) < flatDistance(q, segment.a)
		end)
		for k = 1, #on - 1 do
			link(on[k], on[k + 1], flatDistance(on[k], on[k + 1]))
		end
	end
	for _, road in ipairs(self.roads) do
		local startTown = self.towns[road.startTown]
		link(startTown.center, mouthPoint(startTown, road.startMouth), 0)
		if road.endMouth then
			local endTown = self.towns[road.endTown]
			link(endTown.center, mouthPoint(endTown, road.endMouth), 0)
		end
	end
	local source, goal = node(self.towns[i].center), node(self.towns[j].center)
	local dist, done = { [source] = 0 }, {}
	while true do
		local best, bestDistance = nil, math.huge
		for k, d in pairs(dist) do
			if not done[k] and d < bestDistance then
				best, bestDistance = k, d
			end
		end
		if not best then
			return math.huge
		end
		if best == goal then
			return bestDistance
		end
		done[best] = true
		for _, entry in ipairs(links[best]) do
			local nd = bestDistance + entry[2]
			if nd < (dist[entry[1]] or math.huge) then
				dist[entry[1]] = nd
			end
		end
	end
end

-- `centers` are the town squares; `shape` the town footprint { half, cross, zext } (half: how far
-- the main street runs out along X, cross: along Z, zext: how far buildings can reach along Z).
function RoadNetwork.Plan(centers, shape, radius)
	local towns = {}
	for index, center in ipairs(centers) do
		towns[index] = {
			index = index,
			center = Vector3.new(center.X, 0, center.Z),
			half = shape.half,
			cross = shape.cross,
			zext = shape.zext,
			used = {},
		}
	end
	local self = RoadNetwork.new(radius, towns)

	local pairsList = {}
	for i = 1, #towns do
		for j = i + 1, #towns do
			local a, b = towns[i].center, towns[j].center
			table.insert(pairsList, { distance = math.abs(a.X - b.X) + math.abs(a.Z - b.Z), i = i, j = j })
		end
	end
	table.sort(pairsList, function(p, q)
		return p.distance < q.distance
	end)

	local function best(list)
		local chosen = nil
		for _, candidate in ipairs(list) do
			if not chosen or candidate.score < chosen.score then
				chosen = candidate
			end
		end
		return chosen
	end

	-- Every town on the network, nearest pairs first.
	for _, pair in ipairs(pairsList) do
		if self:_find(pair.i) ~= self:_find(pair.j) then
			local candidates = self:_mouthRoutes(pair.i, pair.j)
			for _, list in ipairs({ self:_teeRoutes(pair.i, pair.j), self:_teeRoutes(pair.j, pair.i) }) do
				for _, candidate in ipairs(list) do
					table.insert(candidates, candidate)
				end
			end
			local chosen = best(candidates)
			if chosen then
				self:_add(chosen)
			end
		end
	end

	-- Then a few more where the network sends two towns a long way round.
	local extras = 0
	for _, pair in ipairs(pairsList) do
		if extras >= math.max(1, math.floor(#towns / 2)) then
			break
		end
		local current = self:_networkDistance(pair.i, pair.j)
		if current >= pair.distance * 1.6 then
			local chosen = best(self:_mouthRoutes(pair.i, pair.j))
			if chosen and chosen.score < current * 0.7 then
				self:_add(chosen)
				extras += 1
			end
		end
	end

	self:_finish()
	self:_chooseCurves()
	return self
end

--------------------------------------------------------------------------------
-- Curves
--------------------------------------------------------------------------------

-- A point on a curve: `t` from 0 at the first tangent point to 1 at the second.
local function curvePoint(curve, t)
	local angle = curve.a1 + curve.sweep * t
	return Vector3.new(curve.centre.X + math.cos(angle) * curve.radius, 0, curve.centre.Z + math.sin(angle) * curve.radius)
end

-- The arc as straight chords about `step` studs long, for claims and clearance checks.
local function curveChords(curve, step)
	local length = math.abs(curve.sweep) * curve.radius
	local count = math.max(2, math.ceil(length / step))
	local chords = {}
	local previous = curvePoint(curve, 0)
	for index = 1, count do
		local point = curvePoint(curve, index / count)
		table.insert(chords, { from = previous, to = point })
		previous = point
	end
	return chords
end

-- How far (x, z) is from the arc's own line, or nil when it isn't beside the arc at all: the arc
-- spans a quarter turn, and the straights either side cover everything past its ends.
local function curveOffset(curve, x, z)
	local dx, dz = x - curve.centre.X, z - curve.centre.Z
	local delta = math.atan2(dz, dx) - curve.a1
	while delta > math.pi do
		delta -= 2 * math.pi
	end
	while delta < -math.pi do
		delta += 2 * math.pi
	end
	local along = curve.sweep >= 0 and delta or -delta
	if along < 0 or along > math.abs(curve.sweep) then
		return nil
	end
	return math.abs(math.sqrt(dx * dx + dz * dz) - curve.radius)
end

--------------------------------------------------------------------------------
-- The built graph: nodes (mouths, bends, junctions) and the edges between them
--------------------------------------------------------------------------------

function RoadNetwork:_finish()
	local nodes, byKey = {}, {}
	local function nodeAt(p)
		local key = string.format("%d:%d", math.floor(p.X * 100 + 0.5), math.floor(p.Z * 100 + 0.5))
		local node = byKey[key]
		if not node then
			node = { position = Vector3.new(p.X, 0, p.Z), arms = {}, index = #nodes + 1 }
			byKey[key] = node
			table.insert(nodes, node)
		end
		return node
	end
	for _, road in ipairs(self.roads) do
		local first = nodeAt(road.points[1])
		first.town, first.mouth = road.startTown, road.startMouth
		for k = 2, #road.points - 1 do
			nodeAt(road.points[k])
		end
		local last = nodeAt(road.points[#road.points])
		if road.endMouth then
			last.town, last.mouth = road.endTown, road.endMouth
		end
	end
	for _, point in ipairs(self:_crossings()) do
		nodeAt(point)
	end

	local edges = {}
	for _, segment in ipairs(self:_segments()) do
		local on = {}
		for _, node in ipairs(nodes) do
			if pointSegmentDistance(node.position, segment.a, segment.b) < 1e-3 then
				table.insert(on, node)
			end
		end
		table.sort(on, function(p, q)
			return flatDistance(p.position, segment.a) < flatDistance(q.position, segment.a)
		end)
		for k = 1, #on - 1 do
			local a, b = on[k], on[k + 1]
			local delta = b.position - a.position
			local length = delta.Magnitude
			if length > 0.01 then
				local name = dirName(delta)
				local edge = {
					a = a, b = b, from = a.position, to = b.position, dir = AXIS[name], length = length,
					road = segment.road, index = #edges + 1,
				}
				a.arms[name] = edge
				b.arms[OPPOSITE[name]] = edge
				table.insert(edges, edge)
			end
		end
	end

	for _, node in ipairs(nodes) do
		local count = 0
		for _ in pairs(node.arms) do
			count += 1
		end
		node.armCount = count
		if node.mouth then
			node.kind = "mouth"
		elseif count == 4 then
			node.kind = "cross"
			node.control = "signals"
		elseif count == 3 then
			node.kind = "tee"
			node.control = "stop"
			for name in pairs(node.arms) do
				if not node.arms[OPPOSITE[name]] then
					node.stem = name
				end
			end
		elseif count == 2 then
			node.kind = (node.arms.E and node.arms.W or node.arms.N and node.arms.S) and "straight" or "bend"
		else
			node.kind = "end"
		end
		-- How far the junction box reaches along each arm from the node's centre.
		node.box = (node.kind == "mouth" or node.kind == "straight" or node.kind == "end") and 0 or HALF
	end

	self.nodes = nodes
	self.edges = edges
end

-- The arc that replaces a bend's square corner: tangent to both arms `radius` studs back from the
-- corner, curving through the inside of it.
local function curveFor(node, radius)
	local names = {}
	for name in pairs(node.arms) do
		table.insert(names, name)
	end
	if #names ~= 2 then
		return nil
	end
	local d1, d2 = AXIS[names[1]], AXIS[names[2]]
	local centre = node.position + d1 * radius + d2 * radius
	local first = node.position + d1 * radius
	local second = node.position + d2 * radius
	local a1 = math.atan2(first.Z - centre.Z, first.X - centre.X)
	local a2 = math.atan2(second.Z - centre.Z, second.X - centre.X)
	local sweep = a2 - a1
	while sweep > math.pi do
		sweep -= 2 * math.pi
	end
	while sweep < -math.pi do
		sweep += 2 * math.pi
	end
	return { radius = radius, centre = centre, a1 = a1, sweep = sweep, arms = names, tangents = { first, second } }
end

-- Whether an arc keeps the clearances the corner it replaces had: off every town's footprint, and
-- well away from any other road, junction or bend. An arc only ever cuts INSIDE its corner, so
-- nothing outside it can come closer than it already was.
-- Whether an arc keeps the clearances the corner it replaces had: off every town's footprint, and
-- well away from any OTHER road, junction or bend. Returns false and which of those it hit.
--
-- Its own route doesn't count -- not the two arms, not the nodes at their far ends, and not what
-- carries on beyond those. A Z-shaped route bends twice about NODE_GAP apart, so the leg past the
-- next bend is always within a radius of this arc; measured as a stranger it refused the curve on
-- every Z route, which is most of them, and left 50 of 79 bends square.
function RoadNetwork:_curveClear(node, curve)
	local own, ownEdges = { [node] = true }, {}
	for _, name in ipairs(curve.arms) do
		local arm = node.arms[name]
		ownEdges[arm] = true
		for _, tip in ipairs({ arm.a, arm.b }) do
			own[tip] = true
			for _, beyond in pairs(tip.arms) do
				ownEdges[beyond] = true
			end
		end
	end
	for _, chord in ipairs(curveChords(curve, 14)) do
		for _, town in ipairs(self.towns) do
			-- The margin the planner held the straights to, so a curve is allowed where its corner was.
			if boxHitsSegment(town.center, town.half + KEEP_MARGIN, town.zext + KEEP_MARGIN, chord.from, chord.to) then
				return false, "town"
			end
		end
		for _, edge in ipairs(self.edges) do
			if not ownEdges[edge] then
				for _, point in ipairs({ chord.from, chord.to }) do
					if pointSegmentDistance(point, edge.from, edge.to) < CURVE_CLEAR then
						return false, "road"
					end
				end
			end
		end
		for _, other in ipairs(self.nodes) do
			if not own[other] and flatDistance(other.position, chord.from) < CURVE_CLEAR then
				return false, "node"
			end
		end
	end
	return true
end

-- Every bend that has room becomes a curve, as big a one as fits. Two curves on one road each need
-- their radius of it, with a straight run between them, and every junction, town street end and
-- bridge keeps the straight approach it always had.
function RoadNetwork:_chooseCurves()
	local bends = {}
	for _, node in ipairs(self.nodes) do
		if node.kind == "bend" then
			node.curveRadius = CURVE_MAX_RADIUS
			table.insert(bends, node)
		end
	end
	-- Shrink until every edge has room for the curves at its ends and a straight between them.
	for _ = 1, 60 do
		local changed = false
		for _, edge in ipairs(self.edges) do
			local ra = edge.a.curveRadius or edge.a.box
			local rb = edge.b.curveRadius or edge.b.box
			local slack = edge.length - ra - rb - CURVE_STRAIGHT
			if slack < -1e-6 then
				local share = {}
				for _, node in ipairs({ edge.a, edge.b }) do
					if node.curveRadius then
						table.insert(share, node)
					end
				end
				for _, node in ipairs(share) do
					node.curveRadius = math.max(0, node.curveRadius + slack / #share)
				end
				changed = true
			end
		end
		if not changed then
			break
		end
	end
	-- A bend that can't hold the radius the edges allow gets a smaller one rather than a square
	-- corner: most refusals are the town keep-out, because an arc cuts INSIDE its corner and a corner
	-- near a town leans toward it. Shrinking is always available -- the arc's reach into the corner is
	-- 0.29 of its radius -- so the answer to "too close" is a tighter curve, not a right angle.
	self.curveRefused = { tight = 0, town = 0, road = 0, node = 0 }
	for _, node in ipairs(bends) do
		local curve, fits, why = nil, false, nil
		local radius = node.curveRadius
		while radius and radius >= CURVE_MIN_RADIUS and not fits do
			curve = curveFor(node, radius)
			fits, why = self:_curveClear(node, curve)
			if not fits then
				radius = radius >= CURVE_MIN_RADIUS * 1.3 and radius * 0.75 or 0
			end
		end
		if not fits then
			curve = nil
			if (node.curveRadius or 0) < CURVE_MIN_RADIUS then
				self.curveRefused.tight += 1
			else
				self.curveRefused[why or "node"] += 1
			end
		else
			node.curveRadius = radius
		end
		if fits then
			node.curve = curve
			node.box = radius
			-- A curve is level itself, so the climb may start where it ends -- but the profile's level
			-- stretch runs to whole samples, and one that stopped just short of the tangent point left
			-- the road already climbing where the curve's own height took over, a tenth of a stud of
			-- lip. One sample past is enough to land the tangent point inside the level stretch.
			node.flatRun = PROFILE_STEP
		else
			node.curveRadius = nil
		end
	end
end

function RoadNetwork:MouthsOf(townIndex)
	return self.towns[townIndex] and table.clone(self.towns[townIndex].used) or {}
end

function RoadNetwork:Claim(space)
	for _, edge in ipairs(self.edges) do
		edge.claim = space:AddStrip(edge.from, edge.to, RoadNetwork.ClaimWidth)
	end
	-- A curve cuts inside its corner, so its own strip is claimed too; the corner it left behind
	-- stays claimed as well, which keeps anything from being built in the crook of a bend.
	for _, node in ipairs(self.nodes) do
		if node.curve then
			for _, chord in ipairs(curveChords(node.curve, 24)) do
				space:AddStrip(chord.from, chord.to, RoadNetwork.ClaimWidth)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Heights and the ground under the roads
--------------------------------------------------------------------------------

-- Road ground height (the top is LIFT above it) at `along` studs from the edge's start.
local function edgeHeight(edge, along)
	local heights = edge.heights
	local t = math.clamp(along, 0, edge.length) / edge.step
	local k = math.floor(t)
	if k >= #heights - 1 then
		return heights[#heights]
	end
	local f = t - k
	return heights[k + 1] + (heights[k + 2] - heights[k + 1]) * f
end
RoadNetwork.EdgeHeight = edgeHeight

local DISC = { Vector3.zero }
for index = 0, 7 do
	local angle = index / 8 * math.pi * 2
	table.insert(DISC, Vector3.new(math.cos(angle) * 20, 0, math.sin(angle) * 20))
end

-- How far a road can climb (and fall) over `x` studs, starting at a grade of `m`: easing into the
-- steepest grade along a vertical curve of radius CURVE_RADIUS, then holding MAX_GRADE.
local function climb(m, x)
	local reach = math.max(0, MAX_GRADE - m) * CURVE_RADIUS
	if x <= reach then
		return m * x + x * x / (2 * CURVE_RADIUS)
	end
	return m * reach + reach * reach / (2 * CURVE_RADIUS) + MAX_GRADE * (x - reach)
end
local function fall(m, x)
	return -climb(-m, x)
end

-- The most a road can climb over `x` studs, leaving at a grade of `m0` and arriving at a grade of
-- `m1`, within the grade and the curve limits: easing up toward the steepest grade and back down to
-- the grade it arrives at. nil when `x` isn't long enough even to turn from one grade to the other.
-- The most it can fall is reach(-m0, -m1, x).
local function reach(m0, m1, x)
	if x < math.abs(m1 - m0) * CURVE_RADIUS then
		return nil
	end
	local peak = (x / CURVE_RADIUS + m0 + m1) / 2
	if peak <= MAX_GRADE then
		return CURVE_RADIUS * (2 * peak * peak - m0 * m0 - m1 * m1) / 2
	end
	return CURVE_RADIUS * (2 * MAX_GRADE * MAX_GRADE - m0 * m0 - m1 * m1) / 2 + MAX_GRADE * (x - (2 * MAX_GRADE - m0 - m1) * CURVE_RADIUS)
end

-- A reach kept a little inside the exact limit, so the profile's projection always has room to meet it.
local function inside(value)
	return math.max(0, value * 0.98 - 0.005)
end

-- The most two level points `distance` apart can differ in height.
local function levelToLevel(distance)
	return inside(reach(0, 0, math.max(0, distance)))
end

-- The bridge spans on each edge, from where the planned river crosses it: one { s0, s1 } per
-- bridge, in studs along the edge, with crossings of a winding river close together merged into
-- one longer bridge, and every span kept clear of the junction boxes at the edge's ends.
local function bridgeSpans(edges, crossings)
	local byEdge = {}
	for _, cross in ipairs(crossings or {}) do
		local edge = cross.edge
		local along = (cross.point - edge.from):Dot(edge.dir)
		local s0 = math.max(edge.a.box + 2, along - cross.span / 2)
		local s1 = math.min(edge.length - edge.b.box - 2, along + cross.span / 2)
		if s1 > s0 then
			byEdge[edge] = byEdge[edge] or {}
			table.insert(byEdge[edge], { s0 = s0, s1 = s1 })
		end
	end
	for _, edge in ipairs(edges) do
		local spans = byEdge[edge] or {}
		table.sort(spans, function(p, q)
			return p.s0 < q.s0
		end)
		local merged = {}
		for _, span in ipairs(spans) do
			local last = merged[#merged]
			if last and span.s0 <= last.s1 + 20 then
				last.s1 = math.max(last.s1, span.s1)
			else
				table.insert(merged, { s0 = span.s0, s1 = span.s1 })
			end
		end
		edge.bridges = merged
	end
end

-- An edge's samples every PROFILE_STEP studs: how many and how far apart, the last level sample
-- past the start's junction box and the first before the end's, and each bridge's span in samples,
-- kept off the level stretches.
local function layoutOf(edge)
	local length = edge.length
	local count = math.max(2, math.ceil(length / PROFILE_STEP))
	local step = length / count
	local n = count + 1
	-- Each level stretch reaches a sample PAST its junction box (or its curve's tangent point), so
	-- the piece of road that meets the box is level with it. Stopping level exactly at the box leaves
	-- the last slab before it sloping up to meet it, which is a lip you can see and measure.
	local flatA = edge.a.box + (edge.a.flatRun or FLAT_RUN)
	local flatB = length - edge.b.box - (edge.b.flatRun or FLAT_RUN)
	if flatA >= flatB then
		-- Too short to hold both: level from end to end, meeting in the middle. ComputeHeights relaxes
		-- the two junction heights against this same layout, so they are already close enough to meet.
		flatA = (edge.a.box + length - edge.b.box) / 2
		flatB = flatA
	end
	local lastLevelA, firstLevelB = 1, n
	for k = 1, n do
		if (k - 1) * step <= flatA + 1e-6 then
			lastLevelA = k
		end
	end
	for k = n, lastLevelA + 1, -1 do
		if (k - 1) * step >= flatB - 1e-6 then
			firstLevelB = k
		end
	end
	local spans = {}
	for _, span in ipairs(edge.bridges or {}) do
		local k0 = math.max(lastLevelA + 1, math.floor(span.s0 / step) + 1)
		local k1 = math.min(firstLevelB - 1, math.ceil(span.s1 / step) + 1)
		if k1 >= k0 then
			table.insert(spans, { s0 = span.s0, s1 = span.s1, k0 = k0, k1 = k1 })
		end
	end
	return { n = n, step = step, lastLevelA = lastLevelA, firstLevelB = firstLevelB, spans = spans }
end

-- The distances between the level stretches and the straight lines in `lines` ({ k0, k1 } each, in
-- order along the edge): from the start's level stretch to the first line, between each pair, and
-- from the last line to the end's level stretch.
local function gapsBetween(layout, lines)
	local gaps, previous = {}, layout.lastLevelA
	for _, line in ipairs(lines) do
		table.insert(gaps, math.max(0, line.k0 - previous) * layout.step)
		previous = line.k1
	end
	table.insert(gaps, math.max(0, layout.firstLevelB - previous) * layout.step)
	return gaps
end

-- `crossings` are where the planned river crosses the roads (MapTerrain.RoadCrossings), so the
-- profiles can run straight across the bridges.
function RoadNetwork:ComputeHeights(naturalAt, preset, crossings)
	local base = preset and preset.terrainMaterial or Enum.Material.Ground
	-- Gravel-coloured shoulders; on a map whose ground is already Ground, limestone, so they still read.
	self.shoulderMaterial = base == Enum.Material.Ground and Enum.Material.Limestone or Enum.Material.Ground
	self.groundMaterial = base
	-- The flat ground past the shoulders keeps the map's own material where that is smooth, and is
	-- Ground where it isn't (a Rock map's verges are earth).
	self.apronMaterial = RoadNetwork.SmoothMaterials[base] and base or Enum.Material.Ground

	-- Junctions sit at the average ground round them; mouths at the town's own level.
	for _, node in ipairs(self.nodes) do
		if node.kind == "mouth" then
			node.height = 0
			node.fixed = true
		else
			-- Round the middle of the arc where there is one: a curve's corner has no road on it.
			local at = node.curve and curvePoint(node.curve, 0.5) or node.position
			local sum = 0
			for _, offset in ipairs(DISC) do
				sum += naturalAt(at.X + offset.X, at.Z + offset.Z)
			end
			node.height = math.max(0, sum / #DISC)
		end
	end
	bridgeSpans(self.edges, crossings)
	for _, edge in ipairs(self.edges) do
		edge.layout = layoutOf(edge)
	end
	-- Pull neighbouring junctions toward each other until every edge between them can hold both the
	-- grade and the curve limits, so a profile is never asked for the impossible. An edge with bridges
	-- is measured as if each bridge were level and only as long as its span, the arrangement that asks
	-- least of the junctions (_profile tries better ones first); and a junction beside a bridge is
	-- raised if it's too low for the road to climb clear of the water by the bridge.
	for _ = 1, 200 do
		local changed = false
		for _, edge in ipairs(self.edges) do
			local layout = edge.layout
			local gaps = gapsBetween(layout, layout.spans)
			local allowed = 0
			for _, distance in ipairs(gaps) do
				allowed += levelToLevel(distance)
			end
			local gap = edge.b.height - edge.a.height
			if math.abs(gap) > allowed + 1e-3 then
				local excess = math.abs(gap) - allowed + 1e-3
				local sign = gap > 0 and 1 or -1
				if edge.a.fixed and not edge.b.fixed then
					edge.b.height -= sign * excess
				elseif edge.b.fixed and not edge.a.fixed then
					edge.a.height += sign * excess
				elseif not edge.a.fixed then
					edge.a.height += sign * excess / 2
					edge.b.height -= sign * excess / 2
				end
				changed = true
			end
			if #layout.spans > 0 then
				local needA = BRIDGE_MIN_HEIGHT - levelToLevel(gaps[1])
				if not edge.a.fixed and edge.a.height < needA - 1e-3 then
					edge.a.height = needA
					changed = true
				end
				local needB = BRIDGE_MIN_HEIGHT - levelToLevel(gaps[#gaps])
				if not edge.b.fixed and edge.b.height < needB - 1e-3 then
					edge.b.height = needB
					changed = true
				end
			end
		end
		if not changed then
			break
		end
	end

	for _, edge in ipairs(self.edges) do
		self:_profile(edge, naturalAt)
	end

	-- A coarse grid of which edges and curves reach each cell, for GroundAt.
	local grid = {}
	local function addToGrid(minX, maxX, minZ, maxZ, entry)
		for cx = math.floor(minX / GRID_CELL), math.floor(maxX / GRID_CELL) do
			for cz = math.floor(minZ / GRID_CELL), math.floor(maxZ / GRID_CELL) do
				local key = cx * 65536 + cz
				grid[key] = grid[key] or {}
				table.insert(grid[key], entry)
			end
		end
	end
	for _, node in ipairs(self.nodes) do
		if node.curve then
			local c = node.curve
			local reach = c.radius + REACH
			addToGrid(c.centre.X - reach, c.centre.X + reach, c.centre.Z - reach, c.centre.Z + reach, { bend = node })
		end
	end
	for _, edge in ipairs(self.edges) do
		local minX = math.min(edge.from.X, edge.to.X) - REACH
		local maxX = math.max(edge.from.X, edge.to.X) + REACH
		local minZ = math.min(edge.from.Z, edge.to.Z) - REACH
		local maxZ = math.max(edge.from.Z, edge.to.Z) + REACH
		addToGrid(minX, maxX, minZ, maxZ, { edge = edge })
	end
	self.grid = grid
end

-- An edge's height profile: the road's ground height every PROFILE_STEP studs.
--
-- Some heights are fixed: the level stretch past each end's junction box, at that junction's
-- height, and a straight line across every bridge and BRIDGE_RUN either side of it, so a bridge deck
-- meets the road with no change of grade at either end. The rest follows the ground, averaged over
-- a few dozen studs so every small bump doesn't become a bump in the road, within two limits: the
-- grade never passes MAX_GRADE, and the grade never changes faster than a vertical curve of radius
-- CURVE_RADIUS allows. The second limit is what keeps every crease between two slabs too gentle to
-- see or to measure: where it isn't met, the slabs either side meet at an angle that shows, and
-- their lower corners cross in a dip.
--
-- In order: the ground is cut down to the grade and built up to it and the two averaged; the result
-- is clamped into the band the fixed heights allow (no higher than climbing away from every fixed
-- height as fast as the limits let, no lower than falling away from it); a few rounds of smoothing
-- round it off; and then the limits are enforced exactly by repeated projection -- nudging every
-- three neighbours whose change of grade is too sharp, and every two whose grade is too steep, back
-- inside, as little as possible, putting the fixed heights back each round.
function RoadNetwork:_profile(edge, naturalAt)
	local length = edge.length
	local count = math.max(2, math.ceil(length / PROFILE_STEP))
	local step = length / count
	local rise = MAX_GRADE * step
	local bend = step * step / CURVE_RADIUS
	local n = count + 1

	local target = {}
	for k = 1, n do
		local along = (k - 1) * step
		local sum = 0
		for w = -3, 3 do
			local p = edge.from + edge.dir * math.clamp(along + w * 8, 0, length)
			sum += naturalAt(p.X, p.Z)
		end
		target[k] = math.max(0, sum / 7)
	end
	local under, over = table.clone(target), table.clone(target)
	for k = 2, n do
		under[k] = math.min(under[k], under[k - 1] + rise)
		over[k] = math.max(over[k], over[k - 1] - rise)
	end
	for k = n - 1, 1, -1 do
		under[k] = math.min(under[k], under[k + 1] + rise)
		over[k] = math.max(over[k], over[k + 1] - rise)
	end
	local base = {}
	for k = 1, n do
		base[k] = (under[k] + over[k]) / 2
	end

	-- Fixed heights, each with the grade the road has there, and the band they allow.
	local layout = edge.layout or layoutOf(edge)
	local lastLevelA, firstLevelB = layout.lastLevelA, layout.firstLevelB
	local fixed, fixedSlope = {}, {}
	for k = 1, n do
		if k <= lastLevelA then
			fixed[k], fixedSlope[k] = edge.a.height, 0
		elseif k >= firstLevelB then
			fixed[k], fixedSlope[k] = edge.b.height, 0
		end
	end
	local low, high = {}, {}
	local function band()
		for k = 1, n do
			low[k], high[k] = -math.huge, math.huge
		end
		for f = 1, n do
			local v = fixed[f]
			if v then
				local m = fixedSlope[f]
				for k = 1, n do
					if k == f then
						low[k], high[k] = math.max(low[k], v), math.min(high[k], v)
					else
						local x = math.abs(k - f) * step
						-- Travelling backward the grade reads the other way round.
						local slope = k > f and m or -m
						low[k] = math.max(low[k], v + fall(slope, x))
						high[k] = math.min(high[k], v + climb(slope, x))
					end
				end
			end
		end
	end
	band()

	-- Each bridge: a straight line of fixed heights across it, so the deck meets the road with no
	-- change of grade at either end. Tried in order, keeping the first that fits: a single bridge on
	-- the ground's average grade across it with BRIDGE_RUN of straight road either side; the same,
	-- level; every bridge level across its own span; and that again with the least clearance over the
	-- water. "Fits" is exact: from each level stretch (or the bridge before) the road has to be able
	-- to reach the line's height, arriving at the line's grade, within the grade and the curve limits
	-- (reach), and the deck has to clear the water. ComputeHeights relaxed the junction heights so
	-- that the level-across-the-span arrangement always fits unless both ends are town street ends.
	local spans = layout.spans
	local function preferredHeight(k0, k1)
		local mid = (k0 + k1) / 2
		return (base[math.floor(mid)] + base[math.ceil(mid)]) / 2, mid
	end
	-- A single line { k0, k1, slope }: the height at its middle that fits, nearest the ground's.
	local function fitOne(line, minHeight)
		local centre, mid = preferredHeight(line.k0, line.k1)
		local m = line.slope
		local x0, x1 = (line.k0 - lastLevelA) * step, (firstLevelB - line.k1) * step
		local upA, downA = reach(0, m, x0), reach(0, -m, x0)
		local upB, downB = reach(m, 0, x1), reach(-m, 0, x1)
		if not (upA and downA and upB and downB) then
			return nil
		end
		local startOffset, endOffset = m * (line.k0 - mid) * step, m * (line.k1 - mid) * step
		local low = math.max(edge.a.height - inside(downA) - startOffset, edge.b.height - inside(upB) - endOffset,
			minHeight - math.min(startOffset, endOffset))
		local high = math.min(edge.a.height + inside(upA) - startOffset, edge.b.height + inside(downB) - endOffset)
		if low > high then
			return nil
		end
		return { math.clamp(centre, low, high) }
	end
	-- Every line level: heights for them all that fit, each nearest the ground's that the one before
	-- allows, or nil.
	local function fitLevel(lines, minHeight)
		local gaps = gapsBetween(layout, lines)
		local count = #lines
		-- Backward first: the heights each line may take and still reach the end's level stretch.
		local lows, highs = {}, {}
		local low, high = edge.b.height - levelToLevel(gaps[count + 1]), edge.b.height + levelToLevel(gaps[count + 1])
		for i = count, 1, -1 do
			low = math.max(low, minHeight)
			if low > high then
				return nil
			end
			lows[i], highs[i] = low, high
			low, high = low - levelToLevel(gaps[i]), high + levelToLevel(gaps[i])
		end
		local heights, previous = {}, edge.a.height
		for i = 1, count do
			local lowest = math.max(lows[i], previous - levelToLevel(gaps[i]))
			local highest = math.min(highs[i], previous + levelToLevel(gaps[i]))
			if lowest > highest then
				return nil
			end
			heights[i] = math.clamp((preferredHeight(lines[i].k0, lines[i].k1)), lowest, highest)
			previous = heights[i]
		end
		return heights
	end

	local lines, heights = nil, nil
	edge.bridgeFit = nil
	if #spans == 1 then
		local span = spans[1]
		local k0 = math.max(lastLevelA + 1, math.floor((span.s0 - BRIDGE_RUN) / step) + 1, math.min(span.k0, lastLevelA + BRIDGE_EASE))
		local k1 = math.min(firstLevelB - 1, math.ceil((span.s1 + BRIDGE_RUN) / step) + 1, math.max(span.k1, firstLevelB - BRIDGE_EASE))
		local runs = { k0 = k0, k1 = math.max(k0, k1), slope = 0 }
		-- Close to a junction's level stretch there's no room to ease onto a grade and off it again.
		local easeLength = MAX_GRADE * 0.5 * CURVE_RADIUS + 3 * step
		if (runs.k0 - lastLevelA) * step >= easeLength and (firstLevelB - runs.k1) * step >= easeLength then
			local slope = math.clamp((base[runs.k1] - base[runs.k0]) / math.max(step, (runs.k1 - runs.k0) * step), -MAX_GRADE * 0.5, MAX_GRADE * 0.5)
			local graded = { k0 = runs.k0, k1 = runs.k1, slope = slope }
			local fit = fitOne(graded, BRIDGE_MIN_HEIGHT)
			if fit then
				lines, heights, edge.bridgeFit = { graded }, fit, "graded"
			end
		end
		if not lines then
			local fit = fitOne(runs, BRIDGE_MIN_HEIGHT)
			if fit then
				lines, heights, edge.bridgeFit = { runs }, fit, "level"
			end
		end
	end
	if not lines and #spans > 0 then
		local exact = {}
		for _, span in ipairs(spans) do
			table.insert(exact, { k0 = span.k0, k1 = span.k1, slope = 0 })
		end
		lines = exact
		heights = fitLevel(exact, BRIDGE_MIN_HEIGHT)
		edge.bridgeFit = "level over the span"
		if not heights then
			heights = fitLevel(exact, BRIDGE_FLOOR)
			edge.bridgeFit = "lowered"
		end
		if not heights then
			-- Nothing fits: each bridge as near the height the one before lets it reach as it gets,
			-- and the projection does what it can.
			heights = {}
			local previous, gaps = edge.a.height, gapsBetween(layout, exact)
			for i, line in ipairs(exact) do
				local allowed = levelToLevel(gaps[i])
				heights[i] = math.clamp((preferredHeight(line.k0, line.k1)), math.max(BRIDGE_FLOOR, previous - allowed), math.max(BRIDGE_FLOOR, previous + allowed))
				previous = heights[i]
			end
			edge.bridgeFit = "forced"
		end
	end
	for i, line in ipairs(lines or {}) do
		local mid = (line.k0 + line.k1) / 2
		for k = line.k0, line.k1 do
			if not fixed[k] then
				fixed[k], fixedSlope[k] = heights[i] + line.slope * (k - mid) * step, line.slope
			end
		end
	end
	band()

	local heights = {}
	for k = 1, n do
		heights[k] = fixed[k] or math.clamp(math.max(0, base[k]), low[k], math.max(low[k], high[k]))
	end
	local function clampFree(k, value)
		return math.clamp(value, low[k], math.max(low[k], high[k]))
	end
	for _ = 1, 12 do
		local copy = table.clone(heights)
		for k = 2, n - 1 do
			if not fixed[k] then
				heights[k] = clampFree(k, copy[k - 1] * 0.25 + copy[k] * 0.5 + copy[k + 1] * 0.25)
			end
		end
	end
	-- Exact limits by projection.
	for _ = 1, 3000 do
		local worst = 0
		for k = 2, n - 1 do
			local d2 = heights[k + 1] - 2 * heights[k] + heights[k - 1]
			local excess = math.abs(d2) - bend
			if excess > 1e-6 then
				worst = math.max(worst, excess)
				-- Only the free heights move; the fixed ones' share goes to the free ones.
				local weights = { fixed[k - 1] and 0 or 1, fixed[k] and 0 or 4, fixed[k + 1] and 0 or 1 }
				local total = weights[1] + weights[2] + weights[3]
				if total > 0 then
					local scale = excess / total * (d2 > 0 and 1 or -1)
					heights[k - 1] -= scale * weights[1]
					heights[k] += scale * weights[2] / 2
					heights[k + 1] -= scale * weights[3]
				end
			end
		end
		for k = 1, n - 1 do
			local d1 = heights[k + 1] - heights[k]
			local excess = math.abs(d1) - rise
			if excess > 1e-6 then
				worst = math.max(worst, excess)
				local sign = d1 > 0 and 1 or -1
				local freeA, freeB = not fixed[k], not fixed[k + 1]
				if freeA and freeB then
					heights[k] += sign * excess / 2
					heights[k + 1] -= sign * excess / 2
				elseif freeA then
					heights[k] += sign * excess
				elseif freeB then
					heights[k + 1] -= sign * excess
				end
			end
		end
		if worst < 1e-5 then
			break
		end
	end

	edge.step = step
	edge.heights = heights
	edge.topAt = function(point)
		local along = (point - edge.from):Dot(edge.dir)
		return edgeHeight(edge, along) + LIFT
	end
end

-- The ground the relief pass should write at (x, z), given the natural ground there: flat to the
-- road's ground height across the carriageway and shoulders, blending back to natural beyond.
-- Returns the height and the terrain material for that column (asphalt under the road, a gravel
-- shoulder beside it), or nil where no road reaches.
-- Half the width of the flat corridor under a road (carriageway, shoulders and the flat beyond
-- them), and whether a column is inside it -- for MapTerrain.RestoreRoadGround, which writes that
-- corridor again once the hills are down.
-- Every curve in the network as { node, centre, radius, sweep, chords }: for anything that has to
-- follow the roads on the ground rather than just ask about a point (MapTerrain.RestoreRoadGround).
function RoadNetwork:Curves()
	local list = {}
	for _, node in ipairs(self.nodes) do
		if node.curve then
			table.insert(list, { node = node, curve = node.curve, chords = curveChords(node.curve, 24) })
		end
	end
	return list
end

function RoadNetwork:CorridorHalfWidth()
	return HALF + SHOULDER + BANK_SETBACK
end

-- How far (x, z) is from the road in one grid entry -- an edge or a curve -- and how high the road
-- is there, or nil where that entry doesn't reach it. An edge's corridor squares off past its ends
-- so a junction box's corners sit on flat ground too, except at an end where a curve takes over:
-- there the corridor stops on the tangent line and the curve's own band carries on from it.
local function entryReach(entry, x, z)
	if entry.bend then
		local offset = curveOffset(entry.bend.curve, x, z)
		if not offset then
			return nil
		end
		return offset, entry.bend.height or 0
	end
	local edge = entry.edge
	local dx, dz = x - edge.from.X, z - edge.from.Z
	local along = dx * edge.dir.X + dz * edge.dir.Z
	local lateral = math.abs(dx * edge.dir.Z - dz * edge.dir.X)
	local startAt = edge.a.curve and edge.a.box or 0
	local endAt = edge.length - (edge.b.curve and edge.b.box or 0)
	if (edge.a.curve and along < startAt) or (edge.b.curve and along > endAt) then
		return nil
	end
	local over = along < startAt and startAt - along or (along > endAt and along - endAt or 0)
	return math.max(lateral, over), edgeHeight(edge, math.clamp(along, startAt, endAt))
end

-- Whether (x, z) is within `margin` of a bridge span, along the road it carries.
function RoadNetwork:NearBridge(x, z, margin)
	local bucket = self.grid and self.grid[math.floor(x / GRID_CELL) * 65536 + math.floor(z / GRID_CELL)]
	for _, entry in ipairs(bucket or {}) do
		local edge = entry.edge
		if edge and edge.bridges and #edge.bridges > 0 then
			local dx, dz = x - edge.from.X, z - edge.from.Z
			local along = dx * edge.dir.X + dz * edge.dir.Z
			local lateral = math.abs(dx * edge.dir.Z - dz * edge.dir.X)
			if lateral <= HALF + SHOULDER + BANK_SETBACK + margin then
				for _, span in ipairs(edge.bridges) do
					if along >= span.s0 - margin and along <= span.s1 + margin then
						return true
					end
				end
			end
		end
	end
	return false
end

function RoadNetwork:WithinCorridor(x, z)
	local bucket = self.grid and self.grid[math.floor(x / GRID_CELL) * 65536 + math.floor(z / GRID_CELL)]
	local width = HALF + SHOULDER + BANK_SETBACK
	for _, entry in ipairs(bucket or {}) do
		local distance = entryReach(entry, x, z)
		-- Never past a town's street end, where the town lays its own ground.
		if distance and distance <= width then
			local edge = entry.edge
			if not edge then
				return true
			end
			local dx, dz = x - edge.from.X, z - edge.from.Z
			local along = dx * edge.dir.X + dz * edge.dir.Z
			local before = edge.a.kind == "mouth" and 0 or width
			local after = edge.b.kind == "mouth" and 0 or width
			if along >= -before and along <= edge.length + after then
				return true
			end
		end
	end
	return false
end

function RoadNetwork:GroundAt(x, z, natural)
	local grid = self.grid
	if not grid then
		return nil
	end
	local bucket = grid[math.floor(x / GRID_CELL) * 65536 + math.floor(z / GRID_CELL)]
	if not bucket then
		return nil
	end
	local bestDistance, road = math.huge, nil
	for _, entry in ipairs(bucket) do
		local distance, height = entryReach(entry, x, z)
		if distance and distance < bestDistance then
			bestDistance, road = distance, height
		end
	end
	if not road or bestDistance >= REACH then
		return nil
	end
	local difference = math.abs(natural - road)
	local inner = HALF + SHOULDER + BANK_SETBACK
	if bestDistance <= inner then
		return road, bestDistance <= HALF + 1.5 and Enum.Material.Asphalt
			or (bestDistance <= HALF + SHOULDER and self.shoulderMaterial or self.apronMaterial)
	end
	-- Wide enough to keep the bank under about 34 degrees, and its smoothstep's bend at the top
	-- and the foot gentle (a bend of 6 * difference / blend^2 per stud, held to 1/32): a narrow blend
	-- over a small difference was a kerb at the roadside for anything driving off the road.
	local blend = math.clamp(math.max(difference * 2.2, math.sqrt(192 * difference)), 8, BLEND_MAX)
	local t = (bestDistance - inner) / blend
	if t >= 1 then
		return nil
	end
	return road + (natural - road) * (t * t * (3 - 2 * t)), nil
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local ASPHALT = MapDecor.AsphaltColor
local EDGE_LINE = MapDecor.EdgeLineColor
local CENTRE_LINE = MapDecor.CentreLineColor
local STOP_LINE = MapDecor.StopLineColor

local currentName = "Road"

-- Road parts don't collide (you walk and drive on the terrain shaped flat under them) but, like the
-- roads always have, they can be hit by raycasts: a supply crate lands on the road's top, not in it.
local function part(parent, size, cframe, color, material)
	local p = Instance.new("Part")
	p.Name = currentName
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- How an edge meets the node at one of its ends: the box it stops at, and whether traffic arriving
-- there has to stop (a stop line, and a solid centre line on the approach).
local function endInfo(edge, atStart)
	local node = atStart and edge.a or edge.b
	local arm = atStart and dirName(edge.dir) or dirName(-edge.dir)
	local controlled = node.control == "signals" or (node.control == "stop" and node.stem == arm)
	return node.box, controlled, node
end

-- The surface of one edge as a list of slabs { s0, s1, frame, length, bridge } in order. `spans`
-- are the bridge decks on this edge as { s0, s1 }.
local function buildSurface(parent, edge, spans)
	local startAt, endAt = edge.a.box, edge.length - edge.b.box
	local marks = { startAt, endAt }
	for k = 0, #edge.heights - 1 do
		local along = k * edge.step
		if along > startAt + 0.05 and along < endAt - 0.05 then
			table.insert(marks, along)
		end
	end
	for _, span in ipairs(spans) do
		table.insert(marks, span.s0)
		table.insert(marks, span.s1)
	end
	table.sort(marks)

	local function inBridge(s0, s1)
		local mid = (s0 + s1) / 2
		for _, span in ipairs(spans) do
			if mid > span.s0 and mid < span.s1 then
				return true
			end
		end
		return false
	end
	local function topPoint(along)
		local p = edge.from + edge.dir * along
		return Vector3.new(p.X, edgeHeight(edge, along) + LIFT, p.Z)
	end

	-- Pieces between consecutive marks, merged while the grade stays the same.
	local pieces = {}
	for k = 1, #marks - 1 do
		local s0, s1 = marks[k], marks[k + 1]
		if s1 - s0 > 0.02 then
			local bridge = inBridge(s0, s1)
			local slope = (edgeHeight(edge, s1) - edgeHeight(edge, s0)) / (s1 - s0)
			local last = pieces[#pieces]
			local contiguous = last ~= nil and math.abs(last.s1 - s0) < 1e-6
			if contiguous and bridge and last.bridge then
				-- A bridge is one straight deck from bank to bank.
				last.s1 = s1
			elseif contiguous and not bridge and not last.bridge and math.abs(last.slope - slope) < 1e-4 then
				last.s1 = s1
			else
				table.insert(pieces, { s0 = s0, s1 = s1, slope = slope, bridge = bridge })
			end
		end
	end

	-- Where the grade changes, two slabs meet along their top edges and, in a dip, their lower
	-- corners cross by a sliver. Their sides and bottoms would then be the same planes overlapping,
	-- which the z-fight pass reads as a fight and "fixes" by growing faces -- fattening the road
	-- edge and its lines at every crease. Every other slab is a little narrower and shallower
	-- (SLAB_STAGGER on each side and underneath), so neighbours never share a side or bottom plane;
	-- the tops, which are what you see, still meet exactly.
	local slabs = {}
	for index, piece in ipairs(pieces) do
		local t0, t1 = topPoint(piece.s0), topPoint(piece.s1)
		local length = (t1 - t0).Magnitude
		local frame = CFrame.lookAt(t0:Lerp(t1, 0.5), t1)
		local staggered = index % 2 == 0
		local width = RoadNetwork.Width - (staggered and SLAB_STAGGER * 2 or 0)
		local thickness = piece.bridge and LIFT or (THICKNESS - (staggered and SLAB_STAGGER_DEPTH or 0))
		currentName = piece.bridge and "BridgeRoad" or "RoadSurface"
		part(parent, Vector3.new(width, thickness, length), frame * CFrame.new(0, -thickness / 2, 0), ASPHALT, Enum.Material.Asphalt)
		table.insert(slabs, { s0 = piece.s0, s1 = piece.s1, frame = frame, length = length, bridge = piece.bridge, thickness = thickness })
	end
	return slabs
end

-- A marking along an edge between `s0` and `s1`, `lateral` studs right of the centre line (right
-- when travelling from the edge's start to its end), laid onto whichever slabs it crosses so it
-- lies exactly on the surface: a thin slab on top of the asphalt, MapDecor.MarkRaise proud (see
-- MapDecor on why markings sit on the surface rather than sinking into it).
local MARK_HEIGHT = MapDecor.MarkRaise
local MARK_RAISE = MapDecor.MarkRaise
local MARK_SLIVER = 0.3
local function mark(parent, slabs, s0, s1, lateral, width, color, name)
	if s1 - s0 < 0.05 then
		return
	end
	currentName = name
	for _, slab in ipairs(slabs) do
		local a, b = math.max(s0, slab.s0), math.min(s1, slab.s1)
		-- A marking that only just reaches onto the next slab would leave a sliver there a few
		-- hundredths of a stud long, facing its neighbour's end almost in the same plane; a dash is
		-- no shorter to the eye for leaving it off. Anything that runs the length of a slab (an edge
		-- line) is never a sliver.
		if b - a >= MARK_SLIVER or (b - a > 0.02 and b - a >= slab.s1 - slab.s0 - 0.02) then
			local scale = slab.length / (slab.s1 - slab.s0)
			local mid = ((a + b) / 2 - (slab.s0 + slab.s1) / 2) * scale
			part(parent, Vector3.new(width, MARK_HEIGHT, (b - a) * scale),
				slab.frame * CFrame.new(lateral, MARK_RAISE - MARK_HEIGHT / 2, -mid), color, Enum.Material.SmoothPlastic)
		end
	end
end

local EDGE_INSET = MapDecor.EdgeLineInset
local EDGE_WIDTH = MapDecor.EdgeLineWidth
local DASH_LENGTH, DASH_PERIOD, DASH_WIDTH = 6, 16, 0.5
local SOLID_RUN = 30

local function buildMarkings(parent, edge, slabs)
	local startBox, startControlled = endInfo(edge, true)
	local endBox, endControlled = endInfo(edge, false)
	local s0, s1 = startBox, edge.length - endBox

	-- Edge lines, unbroken along the whole edge.
	for _, side in ipairs({ -1, 1 }) do
		mark(parent, slabs, s0, s1, side * (HALF - EDGE_INSET), EDGE_WIDTH, EDGE_LINE, "RoadEdge")
	end

	-- Stop lines across the lane arriving at a controlled end, and a solid double centre line on
	-- the approach to it; dashes everywhere else.
	local dashFrom, dashTo = s0 + 4, s1 - 4
	local laneInner, laneOuter = 0.65, HALF - EDGE_INSET - EDGE_WIDTH / 2 - 0.05
	local function solidRun(from, to)
		for _, side in ipairs({ -1, 1 }) do
			mark(parent, slabs, from, to, side * 0.4, 0.3, CENTRE_LINE, "RoadCentreLine")
		end
	end
	if startControlled then
		-- Arriving at the start means travelling toward it, whose right is this edge's left.
		mark(parent, slabs, s0 + 1, s0 + 2.2, -(laneInner + laneOuter) / 2, laneOuter - laneInner, STOP_LINE, "StopLine")
		solidRun(s0 + 0.5, math.min(s0 + SOLID_RUN, (s0 + s1) / 2))
		dashFrom = s0 + SOLID_RUN + 6
	end
	if endControlled then
		mark(parent, slabs, s1 - 2.2, s1 - 1, (laneInner + laneOuter) / 2, laneOuter - laneInner, STOP_LINE, "StopLine")
		solidRun(math.max(s1 - SOLID_RUN, (s0 + s1) / 2), s1 - 0.5)
		dashTo = s1 - SOLID_RUN - 6
	end
	local span = dashTo - dashFrom
	if span > DASH_LENGTH then
		local count = math.max(1, math.floor((span + DASH_PERIOD - DASH_LENGTH) / DASH_PERIOD))
		local used = count * DASH_LENGTH + (count - 1) * (DASH_PERIOD - DASH_LENGTH)
		local start = dashFrom + (span - used) / 2
		for index = 0, count - 1 do
			local from = start + index * DASH_PERIOD
			mark(parent, slabs, from, from + DASH_LENGTH, 0, DASH_WIDTH, CENTRE_LINE, "RoadDash")
		end
	end
end

-- A curve, built as a fan of flat pieces between the radii that divide it: each piece is a
-- rectangle with a wedge either side of it, so its outer corners reach the outer chord while its
-- radial edges lie exactly along the radii its neighbours share. Nothing here has to be nudged
-- apart afterwards: neighbours meet edge to edge, never plane to plane. The whole curve is level
-- (its node's height), which is what lets each piece be a flat plate at all -- two horizontal edges
-- at different heights on non-parallel radii have no plane through them.
--
-- `r0` and `r1` are the radii the band runs between, `top` the height of its top face.
local function curveBand(model, curve, count, r0, r1, top, thickness, color, material, name)
	local step = curve.sweep / count
	local delta = math.abs(step) / 2
	local cosD, sinD = math.cos(delta), math.sin(delta)
	for index = 1, count do
		local mid = curve.a1 + step * (index - 0.5)
		local out = Vector3.new(math.cos(mid), 0, math.sin(mid))
		local side = Vector3.new(-math.sin(mid), 0, math.cos(mid))
		local base = Vector3.new(curve.centre.X, top - thickness / 2, curve.centre.Z)
		currentName = name
		local centre = base + out * ((r0 + r1) / 2 * cosD)
		part(model, Vector3.new(2 * r0 * sinD, thickness, (r1 - r0) * cosD), CFrame.lookAt(centre, centre + out), color, material)
		if (r1 - r0) * sinD > 0.05 then
			local corner = base + out * (r1 * cosD)
			for _, hand in ipairs({ 1, -1 }) do
				local wedge = MapDecor.Triangle(model, corner + side * (hand * r0 * sinD), out, side, -1, hand,
					(r1 - r0) * cosD, (r1 - r0) * sinD, thickness, color, material)
				wedge.Name = name
				wedge.CanCollide = false
				wedge.CanQuery = true
				wedge.CanTouch = false
			end
		end
	end
end

-- A marking round a curve: a chord of the band's middle for each piece, trimmed at both ends just
-- enough that the inside corners of two neighbours meet where the radii turn between them rather
-- than overlap (half the width times the tangent of half the turn), and a hair more so the two
-- never share a sliver of face. The hair was 0.02 a side, which left a 0.09 break in the line's
-- middle at every joint of a tight curve; 0.005 keeps them apart and leaves 0.06.
local function curveMarks(model, curve, count, radius, width, top, color, name)
	local step = curve.sweep / count
	local trim = width / 2 * math.abs(math.tan(step / 2)) + 0.005
	for index = 1, count do
		local from = curvePoint({ centre = curve.centre, radius = radius, a1 = curve.a1 + step * (index - 1), sweep = 0 }, 0)
		local to = curvePoint({ centre = curve.centre, radius = radius, a1 = curve.a1 + step * index, sweep = 0 }, 0)
		local length = (to - from).Magnitude - 2 * trim
		if length > 0.05 then
			local centre = from:Lerp(to, 0.5)
			currentName = name
			part(model, Vector3.new(width, MARK_HEIGHT, length),
				CFrame.lookAt(Vector3.new(centre.X, top + MARK_RAISE - MARK_HEIGHT / 2, centre.Z), Vector3.new(to.X, top + MARK_RAISE - MARK_HEIGHT / 2, to.Z)),
				color, Enum.Material.SmoothPlastic)
		end
	end
end

-- The whole curve at a bend: its surface, its edge lines and its dashed centre line.
local function buildCurve(parent, node)
	local curve = node.curve
	local top = node.height + LIFT
	local model = Instance.new("Model")
	model.Name = "Curve"
	model.Parent = parent
	-- Enough pieces that no joint turns more than CURVE_MAX_TURN, and none is longer than CURVE_PIECE.
	local pieces = math.max(4, math.ceil(math.abs(curve.sweep) / CURVE_MAX_TURN), math.ceil(math.abs(curve.sweep) * curve.radius / CURVE_PIECE))
	curve.pieces = pieces
	curveBand(model, curve, pieces, curve.radius - HALF, curve.radius + HALF, top, THICKNESS, ASPHALT, Enum.Material.Asphalt, "RoadCurve")
	-- The edge lines' middles are EDGE_INSET in from the carriageway's edge, exactly where a straight
	-- lays them (buildMarkings) and a junction box does (MapDecor.Junction). Measured from the line's
	-- inner side, as they once were, they stepped sideways by half a line's width where every curve met
	-- its straights (tools/roads_check.py, edgeline_gap).
	for _, side in ipairs({ -1, 1 }) do
		curveMarks(model, curve, pieces, curve.radius + side * (HALF - EDGE_INSET), EDGE_WIDTH, top, EDGE_LINE, "RoadEdge")
	end
	-- Dashes on the centre line, spaced along the arc as they are along a straight.
	local length = math.abs(curve.sweep) * curve.radius
	local dashes = math.max(1, math.floor(length / DASH_PERIOD))
	local sweepPerDash = curve.sweep / dashes
	for index = 1, dashes do
		local at = curve.a1 + sweepPerDash * (index - 0.5)
		local half = DASH_LENGTH / 2 / curve.radius
		local from = curvePoint({ centre = curve.centre, radius = curve.radius, a1 = at - half * (curve.sweep >= 0 and 1 or -1), sweep = 0 }, 0)
		local to = curvePoint({ centre = curve.centre, radius = curve.radius, a1 = at + half * (curve.sweep >= 0 and 1 or -1), sweep = 0 }, 0)
		local centre = from:Lerp(to, 0.5)
		currentName = "RoadDash"
		part(model, Vector3.new(DASH_WIDTH, MARK_HEIGHT, (to - from).Magnitude),
			CFrame.lookAt(Vector3.new(centre.X, top + MARK_RAISE - MARK_HEIGHT / 2, centre.Z), Vector3.new(to.X, top + MARK_RAISE - MARK_HEIGHT / 2, to.Z)),
			CENTRE_LINE, Enum.Material.SmoothPlastic)
	end
	currentName = "Road"
	return model
end

-- Towns reachable along each arm of a node, nearest first, for fingerposts: walks the network
-- from the node out along one arm without coming back through the node.
local function nearestTownAlong(network, node, armName)
	local dist, done = {}, { [node] = true }
	local first = node.arms[armName]
	dist[first.a == node and first.b or first.a] = first.length
	while true do
		local current, currentDistance = nil, math.huge
		for candidate, d in pairs(dist) do
			if not done[candidate] and d < currentDistance then
				current, currentDistance = candidate, d
			end
		end
		if not current then
			return nil
		end
		if current.kind == "mouth" then
			return current.town, currentDistance
		end
		done[current] = true
		for _, edge in pairs(current.arms) do
			local other = edge.a == current and edge.b or edge.a
			if not done[other] then
				local nd = currentDistance + edge.length
				if nd < (dist[other] or math.huge) then
					dist[other] = nd
				end
			end
		end
	end
end

-- context: river (from MapTerrain.River), landHeightAt(x, z) (nil over water), space, lootSpots,
-- townName(index). Returns roadside loot spots.
function RoadNetwork:Build(parent, context)
	local lootSpots = {}
	local space = context.space

	-- Surfaces, markings and bridges, edge by edge. The bridge spans were worked out with the heights
	-- (ComputeHeights), from the same planned river the terrain pass carves.
	for index, edge in ipairs(self.edges) do
		local merged = edge.bridges or {}
		local slabs = buildSurface(parent, edge, merged)
		edge.slabs = slabs
		buildMarkings(parent, edge, slabs)
		for _, slab in ipairs(slabs) do
			if slab.bridge then
				MapDecor.Bridge(parent, slab.frame, slab.length, HALF)
			end
		end
		if index % 6 == 0 then
			task.wait()
		end
	end

	-- Junction boxes, bends, lights and signs. A bend with room for a curve got one instead of a box.
	for _, node in ipairs(self.nodes) do
		if node.curve then
			buildCurve(parent, node)
			if space then
				for _, chord in ipairs(curveChords(node.curve, 24)) do
					space:AddStrip(chord.from, chord.to, HALF + 6)
				end
			end
		elseif node.box > 0 then
			local ground = Vector3.new(node.position.X, node.height, node.position.Z)
			local arms = {}
			for name in pairs(node.arms) do
				arms[name] = true
			end
			local spec = {
				center = ground,
				bx = HALF,
				bz = HALF,
				arms = arms,
				thickness = THICKNESS,
				edgeInset = EDGE_INSET,
				joinInner = node.kind == "bend",
				queryable = true,
			}
			currentName = "Junction"
			MapDecor.Junction(parent, spec)
			if node.control == "signals" then
				-- One phase offset per junction, so neighbouring junctions don't all change together.
				MapDecor.JunctionControl(parent, spec, { kind = "signals", phase = math.random() * 40 })
			elseif node.control == "stop" then
				MapDecor.JunctionControl(parent, spec, { kind = "stop", stopArms = { [node.stem] = true } })
			end
			if space then
				space:AddCircle(node.position.X, node.position.Z, HALF + 6)
			end
		end
	end
	task.wait()

	-- Lamps down both verges of the longer edges, clear of junctions and bridges.
	for _, edge in ipairs(self.edges) do
		local startAt, endAt = edge.a.box + 45, edge.length - edge.b.box - 45
		if edge.a.kind == "mouth" then
			startAt = 30
		end
		if edge.b.kind == "mouth" then
			endAt = edge.length - 30
		end
		local usable = endAt - startAt
		if usable > 60 then
			local count = math.max(1, math.floor(usable / 110))
			local right = Vector3.new(-edge.dir.Z, 0, edge.dir.X)
			for k = 0, count do
				local along = startAt + usable * k / count
				local clear = true
				for _, span in ipairs(edge.bridges or {}) do
					if along > span.s0 - 12 and along < span.s1 + 12 then
						clear = false
					end
				end
				local side = k % 2 == 0 and 1 or -1
				local flat = edge.from + edge.dir * along + right * side * (HALF + SHOULDER + 0.8)
				local height = clear and context.landHeightAt(flat.X, flat.Z)
				if height then
					local position = Vector3.new(flat.X, height, flat.Z)
					MapDecor.StreetLamp(parent, position, -right * side)
					table.insert(lootSpots, position - right * side * 3)
				end
			end
		end
	end
	task.wait()

	-- Fingerposts: just outside each town on the road leaving it, naming where the road goes, and
	-- on a corner of every junction, one board per arm.
	local townName = context.townName or function(index)
		return "Town " .. index
	end
	for _, node in ipairs(self.nodes) do
		local boards = {}
		local position = nil
		if node.kind == "mouth" then
			local armName, edge = next(node.arms)
			if edge then
				local out = AXIS[armName]
				local right = Vector3.new(-out.Z, 0, out.X)
				local town = nearestTownAlong(self, node, armName)
				if town and town ~= node.town then
					position = node.position + out * 24 + right * (HALF + SHOULDER + 1.5)
					table.insert(boards, { direction = out, text = townName(town) })
				end
			end
		elseif node.kind == "tee" or node.kind == "cross" then
			for _, armName in ipairs(MOUTH_ORDER) do
				if node.arms[armName] then
					local town = nearestTownAlong(self, node, armName)
					if town then
						table.insert(boards, { direction = AXIS[armName], text = townName(town) })
					end
				end
			end
			-- The corner on the far side of the stem at a T, or any corner of a crossing that the
			-- lights leave free.
			local corner = node.stem and (-AXIS[node.stem] + AXIS[(node.stem == "E" or node.stem == "W") and "N" or "E"])
				or Vector3.new(1, 0, -1)
			position = node.position + corner * (HALF + 7)
		end
		if position and #boards > 0 then
			-- Inside the road's own claim, where nothing else is built, so no free-space check.
			local height = context.landHeightAt(position.X, position.Z)
			if height then
				if space then
					space:AddCircle(position.X, position.Z, 1.5)
				end
				MapDecor.Fingerpost(parent, Vector3.new(position.X, height, position.Z), boards)
			end
		end
	end

	return lootSpots
end

--------------------------------------------------------------------------------
-- Audit
--------------------------------------------------------------------------------

-- Every surface a road or street is made of, by part name. The curves' pieces are RoadCurve: left off
-- this list, every stud round every curve read as a hole (2040 on one TralalaTown build under
-- tools/roads_check.py's harness), which the gallery then printed as the roads' own number.
-- RingAsphalt is a town roundabout's carriageway (MapDecor.Roundabout), which its streets run on from.
local SURFACES = { RoadSurface = true, BridgeRoad = true, JunctionAsphalt = true, Asphalt = true, RoadCurve = true, RingAsphalt = true }
-- Everything that makes up a road, a street or a square: surfaces, markings, kerbs and paving.
local ROAD_PARTS = {
	RoadSurface = true, BridgeRoad = true, JunctionAsphalt = true, Asphalt = true, RoadEdge = true, RoadDash = true,
	RoadCentreLine = true, StopLine = true, Dash = true, Crossing = true, Kerb = true, Pavement = true, Paving = true,
	Cobbles = true, RoadCurve = true, DroppedKerb = true,
}

-- A part's solid corners: eight for a box, six for a wedge, whose top face is cut away from its
-- (+Y, -Z) edge. A curve's wedges fill only half of the box they sit in, and the other half reaches
-- into the neighbouring piece's sector, so measuring them as boxes reports overlaps that aren't there.
local function cornersOf(part)
	local cf, half = part.CFrame, part.Size / 2
	local wedge = part:IsA("WedgePart")
	local list = {}
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				if not (wedge and sy > 0 and sz < 0) then
					table.insert(list, (cf * CFrame.new(sx * half.X, sy * half.Y, sz * half.Z)).Position)
				end
			end
		end
	end
	return list
end

-- The faces a part can be separated along: its own three, and for a wedge the slope as well.
local function axesOf(part)
	local cf = part.CFrame
	local list = { cf.XVector, cf.YVector, cf.ZVector }
	if part:IsA("WedgePart") then
		table.insert(list, (cf.YVector * part.Size.Z - cf.ZVector * part.Size.Y).Unit)
	end
	return list
end

-- How far two blocks interpenetrate: the least distance either would have to move to clear the
-- other, by separating axes. 0 when they don't overlap (touching counts as not).
local function penetration(a, b)
	local cornersA, cornersB = cornersOf(a), cornersOf(b)
	local axesA, axesB = axesOf(a), axesOf(b)
	local best = math.huge
	local function spread(corners, axis)
		local low, high = math.huge, -math.huge
		for _, corner in ipairs(corners) do
			local value = corner:Dot(axis)
			low, high = math.min(low, value), math.max(high, value)
		end
		return low, high
	end
	local function separated(axis)
		local magnitude = axis.Magnitude
		if magnitude < 1e-3 then
			return false
		end
		axis /= magnitude
		local lowA, highA = spread(cornersA, axis)
		local lowB, highB = spread(cornersB, axis)
		local overlap = math.min(highA, highB) - math.max(lowA, lowB)
		if overlap <= 0 then
			return true
		end
		best = math.min(best, overlap)
		return false
	end
	for _, axis in ipairs(axesA) do
		if separated(axis) then
			return 0
		end
	end
	for _, axis in ipairs(axesB) do
		if separated(axis) then
			return 0
		end
	end
	for _, one in ipairs(axesA) do
		for _, other in ipairs(axesB) do
			if separated(one:Cross(other)) then
				return 0
			end
		end
	end
	return best
end

-- Measures the built roads under `map`, for the build check and the road gallery:
--   gaps      points a stud apart along every edge, across both lanes and both edges, from node
--             centre to node centre and on into the town street at a mouth, that no surface covers
--   steps     neighbouring points whose surface tops differ by more than the grade allows -- a step
--             or an overlap where two pieces meet
--   ground    road top minus the terrain under the carriageway (it should read Lift everywhere off
--             the bridges), how many points have terrain poking through or the road floating, and
--             how far the shoulders sit from the road's ground
-- Returns the numbers and a one-line summary.
function RoadNetwork:Audit(map)
	local CELL = 32
	local grid = {}
	for _, p in ipairs(map:GetDescendants()) do
		if p:IsA("BasePart") and SURFACES[p.Name] then
			local cf, size = p.CFrame, p.Size
			local ex = math.abs(cf.XVector.X) * size.X / 2 + math.abs(cf.YVector.X) * size.Y / 2 + math.abs(cf.ZVector.X) * size.Z / 2
			local ez = math.abs(cf.XVector.Z) * size.X / 2 + math.abs(cf.YVector.Z) * size.Y / 2 + math.abs(cf.ZVector.Z) * size.Z / 2
			for cx = math.floor((p.Position.X - ex) / CELL), math.floor((p.Position.X + ex) / CELL) do
				for cz = math.floor((p.Position.Z - ez) / CELL), math.floor((p.Position.Z + ez) / CELL) do
					local key = cx * 65536 + cz
					grid[key] = grid[key] or {}
					table.insert(grid[key], p)
				end
			end
		end
	end
	-- The highest surface top over (x, z), or nil. A curve's pieces include wedges, which are flat
	-- plates lying in their own X/Z plane rather than boxes: their prism axis is the vertical one, and
	-- the shape underfoot is a right triangle rather than the whole rectangle.
	local function surfaceTop(x, z)
		local best = nil
		for _, p in ipairs(grid[math.floor(x / CELL) * 65536 + math.floor(z / CELL)] or {}) do
			local cf, size = p.CFrame, p.Size
			if p:IsA("WedgePart") and math.abs(cf.XVector.Y) > 0.9 then
				local y = p.Position.Y + (cf.XVector.Y > 0 and size.X / 2 or -size.X / 2) * (cf.XVector.Y > 0 and 1 or -1)
				local localHit = cf:PointToObjectSpace(Vector3.new(x, p.Position.Y, z))
				-- The right angle is at local (-Y, +Z), so the solid side of the hypotenuse is this.
				local inside = math.abs(localHit.Y) <= size.Y / 2 + 0.01 and math.abs(localHit.Z) <= size.Z / 2 + 0.01
					and localHit.Y <= -size.Y / 2 + size.Y * (localHit.Z + size.Z / 2) / size.Z + 0.01
				if inside then
					best = best and math.max(best, y) or y
				end
			else
				local up = cf.YVector
				if math.abs(up.Y) > 0.5 then
					local topCentre = cf.Position + up * (size.Y / 2)
					local y = topCentre.Y - ((x - topCentre.X) * up.X + (z - topCentre.Z) * up.Z) / up.Y
					local localHit = cf:PointToObjectSpace(Vector3.new(x, y, z))
					if math.abs(localHit.X) <= size.X / 2 + 0.01 and math.abs(localHit.Z) <= size.Z / 2 + 0.01 then
						best = best and math.max(best, y) or y
					end
				end
			end
		end
		return best
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = true
	local function ground(x, z)
		local hit = workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -1000, 0), params)
		return hit and hit.Position.Y
	end

	local result = {
		samples = 0, gaps = 0, steps = 0, groundSamples = 0, groundLow = math.huge, groundHigh = -math.huge, groundTotal = 0,
		poking = 0, floating = 0, shoulderLow = math.huge, shoulderHigh = -math.huge, steepest = 0,
	}
	for index, edge in ipairs(self.edges) do
		local right = Vector3.new(-edge.dir.Z, 0, edge.dir.X)
		local startAt = edge.a.curve and edge.a.box or (edge.a.kind == "mouth" and -8 or 0)
		local endAt = edge.length - (edge.b.curve and edge.b.box or 0) + (edge.b.kind == "mouth" and 8 or 0)
		local previous = {}
		for along = startAt, endAt do
			local centre = edge.from + edge.dir * along
			local onBridge = false
			for _, span in ipairs(edge.bridges or {}) do
				if along >= span.s0 - 4 and along <= span.s1 + 4 then
					onBridge = true
				end
			end
			local onEdge = along >= math.max(0, startAt) and along <= math.min(edge.length, endAt)
			for lane, lateral in ipairs({ -HALF + 0.5, -HALF / 2, 0, HALF / 2, HALF - 0.5 }) do
				local p = centre + right * lateral
				local top = surfaceTop(p.X, p.Z)
				result.samples += 1
				if not top then
					result.gaps += 1
					result.gapAt = result.gapAt or string.format("(%.1f, %.1f), %d studs along a %s-to-%s road", p.X, p.Z, along, edge.a.kind, edge.b.kind)
				elseif previous[lane] and math.abs(top - previous[lane]) > MAX_GRADE + 0.03 then
					result.steps += 1
					result.stepAt = result.stepAt or string.format("(%.1f, %.1f) %.2f against %.2f, %d studs along a %s-to-%s road", p.X, p.Z, top,
						previous[lane], along, edge.a.kind, edge.b.kind)
				end
				previous[lane] = top
				if top and onEdge and not onBridge and along % 4 == 0 then
					local g = ground(p.X, p.Z)
					if g then
						local offset = top - g
						result.groundSamples += 1
						result.groundTotal += offset
						result.groundLow = math.min(result.groundLow, offset)
						result.groundHigh = math.max(result.groundHigh, offset)
						if offset < 0.05 then
							result.poking += 1
							if result.poking <= 4 then
								result.pokeAt = (result.pokeAt or "") .. string.format(" (%.1f, %.1f, %.1f) %.2f over, %d along a %s-to-%s road at lateral %.1f;",
									p.X, top, p.Z, -offset, along, edge.a.kind, edge.b.kind, lateral)
							end
						elseif offset > LIFT + 0.6 then
							result.floating += 1
							if result.floating <= 3 then
								result.floatAt = (result.floatAt or "") .. string.format(" (%.1f, %.1f, %.1f) %.2f under, %d along a %s-to-%s road;",
									p.X, top, p.Z, offset, along, edge.a.kind, edge.b.kind)
							end
						end
					end
				end
			end
			if onEdge and not onBridge and along % 4 == 0 then
				local roadGround = edgeHeight(edge, along)
				for _, side in ipairs({ -1, 1 }) do
					local p = centre + right * side * (HALF + SHOULDER - 1)
					local g = ground(p.X, p.Z)
					if g then
						result.shoulderLow = math.min(result.shoulderLow, g - roadGround)
						result.shoulderHigh = math.max(result.shoulderHigh, g - roadGround)
					end
				end
				if along >= 4 and along <= edge.length - 4 then
					result.steepest = math.max(result.steepest, math.abs(edgeHeight(edge, along + 4) - edgeHeight(edge, along - 4)) / 8)
				end
			end
		end
		if index % 4 == 0 then
			task.wait()
		end
	end

	-- The curves, walked the same way: a stud at a time round the arc, across both lanes and both
	-- edges. A curve is level, so its tops must all read the same height and its ground the same
	-- offset under them.
	-- Oliver's rule: a run may only turn a right angle where roads MEET. So every bend is a curve,
	-- and every joint within a curve turns gently. Junctions are excluded: a square crossing is the
	-- point of a crossing.
	result.squareBends, result.sharpestTurn, result.squareBendAt = 0, 0, nil
	for _, node in ipairs(self.nodes) do
		if node.kind == "bend" then
			if node.curve then
				result.sharpestTurn = math.max(result.sharpestTurn, math.deg(math.abs(node.curve.sweep) / math.max(1, node.curve.pieces or 1)))
			else
				result.squareBends += 1
				result.sharpestTurn = math.max(result.sharpestTurn, 90)
				result.squareBendAt = result.squareBendAt or string.format("(%.0f, %.0f)", node.position.X, node.position.Z)
			end
		end
	end
	result.curves, result.curveTightest = 0, math.huge
	for _, node in ipairs(self.nodes) do
		if node.curve then
			local curve = node.curve
			result.curves += 1
			result.curveTightest = math.min(result.curveTightest, curve.radius)
			local steps = math.max(8, math.ceil(math.abs(curve.sweep) * curve.radius))
			local previous = {}
			for step = 0, steps do
				local t = step / steps
				local angle = curve.a1 + curve.sweep * t
				local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
				local centre = curvePoint(curve, t)
				for lane, lateral in ipairs({ -HALF + 0.5, -HALF / 2, 0, HALF / 2, HALF - 0.5 }) do
					local p = centre + out * lateral
					local top = surfaceTop(p.X, p.Z)
					result.samples += 1
					if not top then
						result.gaps += 1
						result.gapAt = result.gapAt or string.format("(%.1f, %.1f), %.0f%% round a curve of radius %.0f", p.X, p.Z, t * 100, curve.radius)
					elseif previous[lane] and math.abs(top - previous[lane]) > 0.03 then
						result.steps += 1
						result.stepAt = result.stepAt or string.format("(%.1f, %.1f) %.2f against %.2f, %.0f%% round a curve of radius %.0f", p.X, p.Z, top,
							previous[lane], t * 100, curve.radius)
					end
					previous[lane] = top
					if top and step % 4 == 0 then
						local g = ground(p.X, p.Z)
						if g then
							local offset = top - g
							result.groundSamples += 1
							result.groundTotal += offset
							result.groundLow = math.min(result.groundLow, offset)
							result.groundHigh = math.max(result.groundHigh, offset)
							if offset < 0.05 then
								result.poking += 1
								if result.poking <= 4 then
									result.pokeAt = (result.pokeAt or "") .. string.format(" (%.1f, %.1f, %.1f) %.2f over, on a curve;", p.X, top, p.Z, -offset)
								end
							elseif offset > LIFT + 0.6 then
								result.floating += 1
								if result.floating <= 3 then
									result.floatAt = (result.floatAt or "") .. string.format(" (%.1f, %.1f, %.1f) %.2f under, on a curve;", p.X, top, p.Z, offset)
								end
							end
						end
					end
				end
				if step % 4 == 0 then
					for _, side in ipairs({ -1, 1 }) do
						local p = centre + out * side * (HALF + SHOULDER - 1)
						local g = ground(p.X, p.Z)
						if g then
							result.shoulderLow = math.min(result.shoulderLow, g - node.height)
							result.shoulderHigh = math.max(result.shoulderHigh, g - node.height)
						end
					end
				end
			end
			task.wait()
		end
	end
	if result.curveTightest == math.huge then
		result.curveTightest = 0
	end

	-- Joints along every road: the change of grade where two slabs meet, and how far their lower
	-- corners cross in a dip.
	result.joints, result.jointAngle, result.jointSliver = 0, 0, 0
	for _, edge in ipairs(self.edges) do
		local slabs = edge.slabs or {}
		for i = 1, #slabs - 1 do
			local lookA, lookB = slabs[i].frame.LookVector, slabs[i + 1].frame.LookVector
			local angle = math.acos(math.clamp(lookA:Dot(lookB), -1, 1))
			result.joints += 1
			if math.deg(angle) > result.jointAngle then
				local at = edge.from + edge.dir * slabs[i].s1
				local nearest = math.huge
				for _, span in ipairs(edge.bridges or {}) do
					nearest = math.min(nearest, math.abs(slabs[i].s1 - span.s0), math.abs(slabs[i].s1 - span.s1))
				end
				result.sharpestAt = string.format("(%.0f, %.0f) %.0f of %.0f along a %s-to-%s road, nearest bridge end %.0f", at.X, at.Z, slabs[i].s1,
					edge.length, edge.a.kind, edge.b.kind, nearest)
			end
			result.jointAngle = math.max(result.jointAngle, math.deg(angle))
			if lookB.Y > lookA.Y then
				result.jointSliver = math.max(result.jointSliver, math.max(slabs[i].thickness, slabs[i + 1].thickness) * math.tan(angle))
			end
		end
	end

	-- Anything that makes up a road, street or square sharing volume with another such part.
	local parts = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("Part") and ROAD_PARTS[d.Name] then
			table.insert(parts, d)
		end
	end
	local OVERLAP_CELL = 24
	local cells = {}
	for index, p in ipairs(parts) do
		local cf, size = p.CFrame, p.Size
		local ex = math.abs(cf.XVector.X) * size.X / 2 + math.abs(cf.YVector.X) * size.Y / 2 + math.abs(cf.ZVector.X) * size.Z / 2
		local ez = math.abs(cf.XVector.Z) * size.X / 2 + math.abs(cf.YVector.Z) * size.Y / 2 + math.abs(cf.ZVector.Z) * size.Z / 2
		for cx = math.floor((p.Position.X - ex) / OVERLAP_CELL), math.floor((p.Position.X + ex) / OVERLAP_CELL) do
			for cz = math.floor((p.Position.Z - ez) / OVERLAP_CELL), math.floor((p.Position.Z + ez) / OVERLAP_CELL) do
				local key = cx * 65536 + cz
				cells[key] = cells[key] or {}
				table.insert(cells[key], index)
			end
		end
	end
	result.overlaps, result.deepestOverlap = 0, 0
	local checked = {}
	local tested = 0
	for _, list in pairs(cells) do
		for i = 1, #list do
			for j = i + 1, #list do
				local a, b = math.min(list[i], list[j]), math.max(list[i], list[j])
				local key = a * 1000000 + b
				if not checked[key] then
					checked[key] = true
					local depth = penetration(parts[a], parts[b])
					tested += 1
					if depth > 0.01 then
						result.overlaps += 1
						if depth > result.deepestOverlap then
							result.deepestOverlap = depth
							result.overlapAt = string.format("%s/%s %.3f deep at %s", parts[a].Name, parts[b].Name, depth,
								tostring(Vector3.new(math.floor(parts[a].Position.X), math.floor(parts[a].Position.Y * 10) / 10, math.floor(parts[a].Position.Z))))
						end
					end
					if tested % 4000 == 0 then
						task.wait()
					end
				end
			end
		end
	end

	local kinds = {}
	for _, node in ipairs(self.nodes) do
		kinds[node.kind] = (kinds[node.kind] or 0) + 1
	end
	result.kinds = kinds

	-- Connectivity: every town reachable from every other along the roads, and no road ending
	-- anywhere but a town's street or a junction.
	local reached, frontier = {}, {}
	for _, node in ipairs(self.nodes) do
		if node.kind == "mouth" then
			reached[node] = true
			table.insert(frontier, node)
			break
		end
	end
	-- A town joins every road that leaves it: reaching one of its street ends reaches them all.
	local mouthsOf = {}
	for _, node in ipairs(self.nodes) do
		if node.town then
			mouthsOf[node.town] = mouthsOf[node.town] or {}
			table.insert(mouthsOf[node.town], node)
		end
	end
	while #frontier > 0 do
		local node = table.remove(frontier)
		for _, sibling in ipairs(node.town and mouthsOf[node.town] or {}) do
			if not reached[sibling] then
				reached[sibling] = true
				table.insert(frontier, sibling)
			end
		end
		for _, edge in pairs(node.arms) do
			local other = edge.a == node and edge.b or edge.a
			if not reached[other] then
				reached[other] = true
				table.insert(frontier, other)
			end
		end
	end
	local townsReached = {}
	for node in pairs(reached) do
		if node.town then
			townsReached[node.town] = true
		end
	end
	local reachedCount = 0
	for _ in pairs(townsReached) do
		reachedCount += 1
	end
	result.townsConnected = reachedCount
	result.towns = #self.towns
	-- The tightest gap between two towns' footprints (negative is overlap).
	result.townGap = math.huge
	for i = 1, #self.towns do
		for j = i + 1, #self.towns do
			local a, b = self.towns[i], self.towns[j]
			local gap = math.max(math.abs(a.center.X - b.center.X) - a.half - b.half, math.abs(a.center.Z - b.center.Z) - a.zext - b.zext)
			result.townGap = math.min(result.townGap, gap)
		end
	end
	result.deadEnds = kinds["end"] or 0
	local counts = {}
	for _, d in ipairs(map:GetDescendants()) do
		counts[d.Name] = (counts[d.Name] or 0) + 1
	end
	result.signalLamps = counts.SignalLamp or 0
	result.stopSigns = counts.StopSignPost or 0
	result.fingerposts = counts.FingerpostPost or 0
	result.bridges = counts.BridgeDeck or 0
	-- How each edge's bridges were fitted into its profile (see _profile).
	local fits = {}
	for _, edge in ipairs(self.edges) do
		if edge.bridgeFit then
			fits[edge.bridgeFit] = (fits[edge.bridgeFit] or 0) + 1
		end
	end
	local fitList = {}
	for name, count in pairs(fits) do
		table.insert(fitList, count .. " " .. name)
	end
	table.sort(fitList)
	result.bridgeFits = table.concat(fitList, ", ")

	result.summary = string.format(
		"%d of %d towns connected, %d roads ending in open ground, tightest gap between towns %.0f; %d roads, %d pieces; nodes: %d mouths, %d bends, %d T-junctions, %d crossroads; %d signal lamps, %d stop signs, %d fingerposts, %d bridges%s; %d curves (tightest radius %.0f); %d bends left square%s (%d with no room, %d off a town, %d off another road, %d off a junction), sharpest turn away from a junction %.0f deg; "
			.. "coverage %d points, gaps %d%s, steps %d%s; road top over ground %.2f..%.2f mean %.2f (want %.2f), terrain poking through %d, floating %d; "
			.. "shoulders %.2f..%.2f from road ground; steepest grade %.1f%%; %d joints, sharpest %.2f deg, deepest dip crossing %.3f; "
			.. "%d road/street parts overlapping by more than 0.01%s",
		result.townsConnected, result.towns, result.deadEnds, result.townGap, #self.roads, #self.edges, kinds.mouth or 0, kinds.bend or 0, kinds.tee or 0, kinds.cross or 0,
		result.signalLamps, result.stopSigns, result.fingerposts, result.bridges, result.bridgeFits ~= "" and (" (" .. result.bridgeFits .. ")") or "",
		result.curves, result.curveTightest, result.squareBends, result.squareBendAt and (" at " .. result.squareBendAt) or "",
		(self.curveRefused and self.curveRefused.tight) or 0, (self.curveRefused and self.curveRefused.town) or 0,
		(self.curveRefused and self.curveRefused.road) or 0, (self.curveRefused and self.curveRefused.node) or 0, result.sharpestTurn,
		result.samples, result.gaps, result.gapAt and (" at " .. result.gapAt) or "", result.steps, result.stepAt and (" at " .. result.stepAt) or "",
		result.groundLow, result.groundHigh, result.groundTotal / math.max(1, result.groundSamples), LIFT, result.poking, result.floating,
		result.shoulderLow, result.shoulderHigh, result.steepest * 100, result.joints, result.jointAngle, result.jointSliver,
		result.overlaps, result.overlapAt and (" (deepest " .. result.overlapAt .. ")") or "")
		.. (result.pokeAt and ("; poking at" .. result.pokeAt) or "") .. (result.floatAt and ("; floating at" .. result.floatAt) or "")
		.. (result.sharpestAt and ("; sharpest joint at " .. result.sharpestAt) or "")
	return result
end

return RoadNetwork
