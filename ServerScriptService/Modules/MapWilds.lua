-- The wild ground between the towns: woods, undergrowth and shelters.
--
-- MapDecor's props put a tree, a rock or a shed down every so often. That leaves the ground
-- between towns reading as a lawn with ornaments, and a player rotating from one town to the next
-- crosses hundreds of studs with nothing to duck behind. This fills that ground in, suited to each
-- map's terrain:
--
--   woods      stands of one dominant species with others mixed in, undergrowth under them, logs
--              and stumps on the floor, and sometimes a clearing with a camp or a lean-to in it;
--   trees      oaks, birches, spruces (snow-dusted above the snow line), dead snags, acacias,
--              yuccas, fan palms and apple trees, each built to read as its species from a distance;
--   ground     ferns, grass tufts, flower clumps, mushrooms, shrubs, meadows, hedgerows, dry-stone
--              field walls and orchards, and patches of long grass where they read as deliberate --
--              the skirts of the woods, the river banks and the ground beside a shelter;
--   shelters   lean-tos, campsites, log cabins, stone bothies, beach huts, metal shacks, pole barns,
--              palapas, ruins, rock overhangs, deer stands, concrete pipes and roadside bus shelters.
--              Some are spaced along the routes between towns, so cover is never far off the road.
--
-- Rules the whole module keeps:
--
--   * COVER AND CONCEALMENT. Trunks, logs, rocks, walls and roofs are solid: they block movement
--     and bullets. Low foliage (undergrowth, spruce skirts, shrubs) is not: it hides you but won't
--     stop a shot, and players, bots and vehicles push straight through it. Leaves above head
--     height are solid, the same as MapDecor's trees.
--   * WHAT BREAKS. Wooden shelter parts use DestructibleService's names (Wall, Roof, Gable, Crate,
--     Table), so they can be shot apart like a shed. Stone (StoneWall, Ruin, Rock), posts, decks and
--     pipes are permanent cover. Every roof rests on posts or on stone, never only on a breakable
--     wall, so nothing is left floating when the planks go. Each shelter is its own Model with its
--     parts as direct children, which is what DestructibleService's trim cascade walks.
--   * NOTHING CLIPS. Everything checks the map's MapSpace before it goes down and claims its
--     footprint after. Each woods, shelter or hedgerow is its own Model under Map/Wilds, so the
--     harness's clipping check can see one wild thing running into another.
--   * NOTHING FIGHTS. The builders keep faces out of each other's planes at source: walls butt
--     between corner posts rather than overlapping at the corners, and paired roof slabs and
--     rows of logs differ in length, so their end faces never share a plane. The map's z-fight
--     pass is a safety net, not the plan.
--   * NO GLOBAL RNG. Everything rolls on a Random seeded from ctx.seed, so adding or tuning a
--     feature here never shifts a roll anywhere else on the map. Nothing here adds loot.
--   * A PART BUDGET. Each map gets about BUDGET_PER_RADIUS parts per stud of radius, shared out
--     by phase so shelters and woods always get built before the ground clutter. It is a CEILING,
--     not a target: measured, the build stops growing at about 12 per stud because the attempt
--     counts below (stands, single trees, undergrowth) run out first, so raising the budget alone
--     changes nothing. Raise the counts to get more foliage; raise the budget to let them spend.
--
-- API:
--   MapWilds.Build(map, ctx) -> { model, parts, seconds, counts = { trees, undergrowth, shelters, byKind } }
--     ctx.preset, ctx.radius, ctx.centers, ctx.townSpread, ctx.space   required
--     ctx.groundAt(x, z) -> y or nil   optional veto (nil skips the spot)
--     ctx.roads     optional: the RoadNetwork. Its `edges` (each with from, to, length, and bridges
--                   as { s0, s1 } spans along it) put bus shelters on the verges, and its `nodes`
--                   (position, control) keep them clear of a junction's sight lines. Every edge is a
--                   straight run on a world axis, so the line from `from` to `to` is the road itself.
--                   A list of { from, to } or { legs } works too; with none, routes are the planned
--                   ring between towns.
--     ctx.avoid     optional list of Vector3 kept 50 studs clear (easter eggs)
--     ctx.river     optional { points = { Vector3, ... }, width }: long grass grows along its banks
--     ctx.seed      optional number
--   MapWilds.Specimens(parent, origin, groundAt) builds one of everything in a row, for galleries
--     and audits.

local MapWilds = {}

-- Agreed with claude-79 (00:55) against the measured curve: 7.5 is the density we can defend on
-- part count, and it is raised later with numbers rather than taste.
MapWilds.BUDGET_PER_RADIUS = 12

-- Trunks, posts and walls start this far underground, like MapDecor's, so a slope never leaves
-- one standing on air on its low side.
local SINK = 1.5

-- While this is true, everything built casts no shadow. The low foliage turns it on round itself:
-- map-wide, 92.6% of all parts cast shadows and 2,817 of them are under a stud (performance tab's
-- baseline), and a shadow a player cannot resolve is a shadow-map draw spent on a smudge. It is a
-- switch rather than a per-part flag so a builder cannot half-apply it.
local noShadow = false

-- Off builds the same wilds with every part casting, so a before and an after can be photographed
-- from one camera and counted in one run. It is not a quality setting to ship either way -- it is
-- how the trim gets shown to be worth having.
MapWilds.SHADOW_TRIM = true

-- Under a stud in every direction, or inside a stretch of low foliage: no shadow. Called from both
-- part constructors, so there is one rule rather than two.
local function shadowFor(p, size)
	if not MapWilds.SHADOW_TRIM then
		return
	end
	if noShadow or (size.X < 1 and size.Y < 1 and size.Z < 1) then
		p.CastShadow = false
	end
end

-- Solid leaves never come lower than this over the ground a tree stands on: a player is about
-- 5.3 studs tall, and a crown at head height snags everyone walking under it.
local HEAD_CLEAR = 6.5

-- The tall corner of a CornerWedgePart, as signs of its own X and Z. Four of them turned about a
-- common centre make a square pyramid (spruce tiers, palapa roofs). Measured in
-- tools/wilds_probe.lua.
MapWilds.CornerApex = { x = 1, z = -1 }

--------------------------------------------------------------------------------
-- Per-build state
--------------------------------------------------------------------------------

local rng = Random.new(1)
local partCount = 0
local sampler -- fn(x, z) -> y, material or nil

-- The thing being built right now, when it can be shot apart (#56): every part it makes is tagged
-- `Destructible = "Kind:W<n>"`, one pool for DestructibleService (so a tree's leaves go with its
-- trunk, and a cabin comes down whole rather than leaving its roof in the air). Trees, shelters and
-- the solid clutter are grouped; undergrowth and grass are not, since nothing can hit them anyway.
local currentGroup = nil
local groupSerial = 0

local function grouped(kind, build)
	return function(...)
		if currentGroup then
			return build(...)
		end
		groupSerial += 1
		currentGroup = kind .. ":W" .. groupSerial
		local results = table.pack(pcall(build, ...))
		currentGroup = nil
		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end
end
-- How far the ground falls away under the piece being built, below the point it stands on. Trunks,
-- stumps and rocks go that much deeper, so a tree on a slope never shows air under its low side.
local footDrop = 0
-- Per map: the share of broadleaf trees already turning (the farmland's late afternoon), and whether
-- the piece being built stands in snow (roofs and rocks above Rot Ridge's snow line carry some).
local autumnShare = 0
local snowCover = false

local function rand(a, b)
	return rng:NextNumber(a, b)
end

local function chance(p)
	return rng:NextNumber() < p
end

local function pick(list)
	return list[rng:NextInteger(1, #list)]
end

-- `weights` is { name = weight }. Names are sorted first so the pick depends only on the roll,
-- never on table iteration order.
local function weighted(weights)
	local names, total = {}, 0
	for name, weight in pairs(weights) do
		if weight > 0 then
			table.insert(names, name)
			total += weight
		end
	end
	if #names == 0 then
		return nil
	end
	table.sort(names)
	local roll = rng:NextNumber() * total
	for _, name in ipairs(names) do
		roll -= weights[name]
		if roll <= 0 then
			return name
		end
	end
	return names[#names]
end

--------------------------------------------------------------------------------
-- Parts
--------------------------------------------------------------------------------

local function part(parent, name, size, cframe, color, material, shape)
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		-- Before Size: a ball forces its size uniform when the shape is set.
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	shadowFor(p, size)
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if currentGroup then
		p:SetAttribute("Destructible", currentGroup)
	end
	p.Parent = parent
	partCount += 1
	return p
end

local function classPart(className, parent, name, size, cframe, color, material)
	local p = Instance.new(className)
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	shadowFor(p, size)
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if currentGroup then
		p:SetAttribute("Destructible", currentGroup)
	end
	p.Parent = parent
	partCount += 1
	return p
end

-- Foliage and dressing: seen, never collided with or shot. Small pieces skip shadows too.
local function soft(p, shadow)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	if not shadow then
		p.CastShadow = false
	end
	return p
end

local function block(parent, name, size, cframe, color, material)
	return part(parent, name, size, cframe, color, material)
end

local function ball(parent, name, centre, size, color, material)
	return part(parent, name, Vector3.new(size, size, size), CFrame.new(centre), color, material, Enum.PartType.Ball)
end

-- A cylinder from `a` to `b`. Cylinder parts run along their own X.
local function rod(parent, name, a, b, diameter, color, material)
	local offset = b - a
	local length = offset.Magnitude
	local mid = (a + b) / 2
	local cf
	if length < 1e-3 or math.abs(offset.Unit.Y) > 0.999 then
		cf = CFrame.new(mid) * CFrame.Angles(0, 0, math.pi / 2)
	else
		cf = CFrame.lookAt(mid, b) * CFrame.Angles(0, math.pi / 2, 0)
	end
	return part(parent, name, Vector3.new(math.max(length, 0.05), diameter, diameter), cf, color, material, Enum.PartType.Cylinder)
end

local function column(parent, name, base, height, diameter, color, material)
	return rod(parent, name, base, base + Vector3.new(0, height, 0), diameter, color, material)
end

-- A WedgePart: tall at its own +Z, sloping down to -Z (as MapBuildings' gables use it).
local function wedge(parent, name, size, cframe, color, material)
	return classPart("WedgePart", parent, name, size, cframe, color, material)
end

-- A square pyramid standing on `base` (a CFrame at the centre of its bottom face): four corner
-- wedges, each turned so its tall corner meets the others over the centre.
local function pyramid(parent, name, base, width, height, color, material)
	local half = width / 2
	local apexAngle = math.atan2(MapWilds.CornerApex.z, MapWilds.CornerApex.x)
	local pieces = {}
	for _, quadrant in ipairs({ { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }) do
		local sx, sz = quadrant[1], quadrant[2]
		-- CFrame.Angles(0, t, 0) takes a direction at angle a (atan2(z, x)) to a - t.
		local turn = apexAngle - math.atan2(-sz, -sx)
		local cf = base * CFrame.new(sx * half / 2, height / 2, sz * half / 2) * CFrame.Angles(0, turn, 0)
		table.insert(pieces, classPart("CornerWedgePart", parent, name, Vector3.new(half, height, half), cf, color, material))
	end
	return pieces
end

local function truss(parent, name, cframe, height, color)
	local t = Instance.new("TrussPart")
	t.Name = name
	t.Size = Vector3.new(2, math.max(2, math.ceil(height / 2) * 2), 2)
	t.CFrame = cframe
	t.Anchored = true
	t.Color = color
	t.Material = Enum.Material.Wood
	if currentGroup then
		t:SetAttribute("Destructible", currentGroup)
	end
	t.Parent = parent
	partCount += 1
	return t
end

-- Glass exactly as MapBuildings makes it, so DestructibleService treats a cabin pane like any other.
local function pane(parent, size, cframe)
	local p = block(parent, "WindowGlass", size, cframe, Color3.fromRGB(150, 196, 222), Enum.Material.Glass)
	p.Transparency = 0.45
	p.Reflectance = 0.15
	return p
end

local function model(parent, name)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- Ground under a point, or the default when no sampler is set (specimen rows on a flat pad).
local function groundY(x, z, fallback)
	if sampler then
		local y = sampler(x, z)
		if y then
			return y
		end
	end
	return fallback
end

--------------------------------------------------------------------------------
-- Palettes
--------------------------------------------------------------------------------

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local BARKS = { rgb(92, 68, 48), rgb(78, 60, 44), rgb(104, 80, 56) }
local OAK_LEAVES = { rgb(66, 112, 52), rgb(82, 128, 58), rgb(58, 98, 50), rgb(98, 140, 62) }
local BIRCH_BARK = rgb(222, 218, 206)
local BIRCH_LEAVES = { rgb(132, 168, 74), rgb(150, 180, 86), rgb(118, 156, 70) }
local SPRUCE_NEEDLES = { rgb(40, 82, 58), rgb(46, 92, 62), rgb(36, 74, 54) }
local SNOW = rgb(228, 234, 238)
local DEAD_WOOD = rgb(118, 104, 92)
local ACACIA_LEAVES = { rgb(112, 138, 64), rgb(128, 146, 70), rgb(104, 128, 62) }
local ACACIA_BARK = rgb(96, 76, 58)
local YUCCA_LEAVES = rgb(96, 128, 82)
local YUCCA_BARK = rgb(128, 108, 86)
local PALM_TRUNK = rgb(150, 116, 78)
local FROND = rgb(70, 140, 66)
local DEAD_FROND = rgb(150, 124, 78)
local APPLE_LEAVES = { rgb(74, 122, 56), rgb(88, 134, 60) }
local AUTUMN_LEAVES = { rgb(204, 120, 48), rgb(186, 84, 44), rgb(214, 162, 60), rgb(160, 70, 42) }

-- A broadleaf crown's colour: usually from its own greens, on an autumn map sometimes already turned.
-- Rolls nothing extra on a map without autumn, so those maps come out the same as before.
local function leafColor(greens)
	if autumnShare > 0 and chance(autumnShare) then
		return pick(AUTUMN_LEAVES)
	end
	return pick(greens)
end

-- A roof or rock top in snow carries a covering of it.
local function snowTint(color)
	return snowCover and color:Lerp(rgb(232, 238, 242), 0.62) or color
end
local FRUIT = { rgb(196, 48, 40), rgb(214, 170, 52), rgb(176, 36, 44) }
local PLANKS = { rgb(138, 104, 70), rgb(116, 88, 62), rgb(150, 122, 88) }
local LOGS = { rgb(104, 76, 52), rgb(90, 66, 46) }
local ROOF_SHINGLE = { rgb(96, 62, 48), rgb(74, 78, 86), rgb(110, 86, 58) }
local STONES = { rgb(140, 134, 122), rgb(124, 120, 112), rgb(152, 146, 132) }
local FABRIC = { rgb(196, 92, 52), rgb(66, 118, 152), rgb(96, 134, 70), rgb(214, 170, 60) }
local FLOWER_SETS = {
	meadow = { rgb(240, 214, 70), rgb(236, 236, 240), rgb(214, 96, 150), rgb(156, 120, 220), rgb(236, 120, 60) },
	heather = { rgb(170, 110, 176), rgb(196, 140, 200), rgb(150, 96, 150) },
	weeds = { rgb(236, 214, 80), rgb(240, 240, 236) },
}

--------------------------------------------------------------------------------
-- Trees. Each takes (parent, ground point, scale, snowy) and stands on the point. `reach` in
-- TREES is the canopy's radius at scale 1: what the tree claims, and what keeps it off everything.
--------------------------------------------------------------------------------

local function oak(parent, p, s)
	local bark = pick(BARKS)
	local height = rand(10, 13) * s
	local width = rand(2.3, 2.9) * s
	column(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), height + SINK + footDrop, width, bark, Enum.Material.Wood)

	-- Two roots flaring out into the ground, each finding its own ground.
	local turn = rand(0, math.pi * 2)
	for index = 1, 2 do
		local angle = turn + index * math.pi + rand(-0.5, 0.5)
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local outer = p + direction * width * 1.3
		local y = groundY(outer.X, outer.Z, p.Y)
		soft(rod(parent, "Root", p + direction * width * 0.15 + Vector3.new(0, 1.4 * s, 0),
			Vector3.new(outer.X, y - 0.4, outer.Z), 0.95 * s, bark, Enum.Material.Wood))
	end

	local green = leafColor(OAK_LEAVES)
	local top = p + Vector3.new(0, height, 0)
	ball(parent, "Leaves", top + Vector3.new(0, 4.5 * s, 0), 13 * s, green, Enum.Material.Grass)
	-- Three lobes round the crown on branches from the upper trunk. Their undersides stay above
	-- head height: height - 2.75s at the least, which a small oak (s 0.68 on the downtown map) would
	-- bring down to 4.9 studs, so a lobe is lifted to keep HEAD_CLEAR under it.
	for index = 1, 3 do
		local angle = turn + (index + rand(-0.18, 0.18)) * math.pi * 2 / 3
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle)) * rand(5, 6.5) * s
		local centre = top + out + Vector3.new(0, rand(2.5, 4) * s, 0)
		local size = rand(8.5, 10.5) * s
		centre += Vector3.new(0, math.max(0, p.Y + HEAD_CLEAR + size / 2 - centre.Y), 0)
		soft(rod(parent, "Branch", p + Vector3.new(0, height * 0.72, 0), centre, 0.9 * s, bark, Enum.Material.Wood))
		-- Solid (it is cover above head height) but it casts no shadow: a lobe sits inside or above the
		-- main crown, whose shadow already covers the same ground.
		local lobe = ball(parent, "Leaves", centre, size, green:Lerp(rgb(255, 255, 210), rand(0, 0.08)), Enum.Material.Grass)
		lobe.CastShadow = false
	end
end

local function birch(parent, p, s)
	local height = rand(15, 19) * s
	local width = 1.25 * s
	local lean = Vector3.new(rand(-0.06, 0.06), 1, rand(-0.06, 0.06)).Unit
	rod(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), p + lean * height, width, BIRCH_BARK, Enum.Material.Wood)

	-- Dark bark marks, proud of the trunk by a hair.
	for _ = 1, 2 do
		local along = rand(2, height * 0.6)
		local point = p + lean * along
		local angle = rand(0, math.pi * 2)
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		soft(block(parent, "Bark", Vector3.new(0.75 * s, 0.24, 0.3),
			CFrame.lookAt(point, point + outward) * CFrame.new(0, 0, -(width / 2 - 0.08)), rgb(44, 40, 38), Enum.Material.SmoothPlastic))
	end

	-- A tall narrow crown of stacked balls, the lowest clear of head height.
	local base = math.max(height * 0.5, 7 + 3.4 * s)
	local sizes = { 6.8, 7.4, 6.2, 4.4 }
	local gold = autumnShare > 0 and chance(autumnShare)
	for index, size in ipairs(sizes) do
		local along = base + (height + 1.5 * s - base) * (index - 1) / (#sizes - 1)
		local centre = p + lean * along + Vector3.new(rand(-1.2, 1.2) * s, 0, rand(-1.2, 1.2) * s)
		ball(parent, "Leaves", centre, size * s, gold and rgb(224, 184, 64):Lerp(rgb(255, 230, 120), rand(0, 0.3)) or pick(BIRCH_LEAVES),
			Enum.Material.Grass)
	end
end

local function spruce(parent, p, s, snowy)
	local green = pick(SPRUCE_NEEDLES)
	column(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), SINK + footDrop + 14 * s, 1.6 * s, BARKS[2], Enum.Material.Wood)

	-- Three pyramid tiers, each turned 45 degrees on the one below. The bottom skirt reaches the
	-- ground, so it's concealment you walk through; the upper tiers are above head height and solid.
	local yaw = rand(0, math.pi / 2)
	-- Two dice per tree, so no two spruces' flat tier bottoms can lie in one plane. MEASURED: the
	-- last six flush pairs left in the wilds were all one stand spruce against one single spruce,
	-- 0.021 studs apart with parallel downward normals -- and both halves of that were built in.
	-- The head-height clamp below handed many trees the SAME tier height, and terrain renders on
	-- 4-stud voxel boundaries, so neighbours' ground heights matched exactly too. ZFight calls a
	-- pair flush within 0.045 studs and 1.8 degrees, so: the lean now points anywhere on the
	-- circle rather than into one of four diagonals, and the clamp varies by over a stud per tree.
	local leanAt, leanBy = rand(0, math.pi * 2), rand(0.05, 0.11)
	local clear = HEAD_CLEAR + 0.4 + rand(0, 1.3)
	local y = 2.2 * s
	for index, tier in ipairs({ { 12, 11 }, { 8.6, 9.5 }, { 5, 8 } }) do
		local width, height = tier[1] * s, tier[2] * s
		local color = green:Lerp(rgb(0, 0, 0), (3 - index) * 0.04)
		if snowy then
			color = color:Lerp(SNOW, 0.35 + index * 0.1)
		end
		-- Each tier still leans its own way (a radian round from the one below), so the tree reads as
		-- a tree rather than a stack; the DIRECTION of the whole lean is the per-tree die.
		local tilt = CFrame.Angles(math.cos(leanAt + index) * leanBy, 0, math.sin(leanAt + index) * leanBy)
		local pieces = pyramid(parent, "Needles", CFrame.new(p + Vector3.new(0, y, 0)) * tilt * CFrame.Angles(0, yaw + index * math.pi / 4, 0),
			width, height, color, Enum.Material.Grass)
		if index == 1 then
			for _, piece in ipairs(pieces) do
				soft(piece, true)
			end
		elseif index > 2 then
			-- The top tier sits inside the one below it: solid, but its shadow is already drawn.
			for _, piece in ipairs(pieces) do
				piece.CastShadow = false
			end
		end
		y += height * 0.55
		-- The solid tiers start above head height, tilt included, even on a small spruce.
		y = math.max(y, clear)
	end
end

local function deadTree(parent, p, s)
	local height = rand(9, 13) * s
	local lean = Vector3.new(rand(-0.1, 0.1), 1, rand(-0.1, 0.1)).Unit
	local tip = p + lean * height
	rod(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), tip, 1.9 * s, DEAD_WOOD, Enum.Material.Wood)
	local turn = rand(0, math.pi * 2)
	for index = 1, 3 do
		local from = p + lean * (height * (0.45 + index * 0.13))
		local angle = turn + index * 2.1
		local to = from + Vector3.new(math.cos(angle) * rand(3.5, 5.5) * s, rand(2, 4) * s, math.sin(angle) * rand(3.5, 5.5) * s)
		soft(rod(parent, "Branch", from, to, (0.85 - index * 0.12) * s, DEAD_WOOD, Enum.Material.Wood), true)
	end
	-- The snapped-off top.
	soft(rod(parent, "Branch", tip - lean * 0.3, tip + Vector3.new(rand(-1, 1), 2.2 * s, rand(-1, 1)), 1.2 * s, DEAD_WOOD,
		Enum.Material.Wood), true)
end

local function acacia(parent, p, s)
	local lean = Vector3.new(rand(-0.25, 0.25), 1, rand(-0.25, 0.25)).Unit
	local fork = p + lean * 6 * s
	rod(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), fork, 1.7 * s, ACACIA_BARK, Enum.Material.Wood)
	local angle = rand(0, math.pi * 2)
	local side = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local green = pick(ACACIA_LEAVES)
	local canopyY = fork.Y + 4.6 * s
	for _, sign in ipairs({ 1, -1 }) do
		local tip = Vector3.new(fork.X, canopyY, fork.Z) + side * sign * 3.6 * s
		rod(parent, "Trunk", fork - lean * 0.4, tip, 1.1 * s, ACACIA_BARK, Enum.Material.Wood)
	end
	-- Flat umbrella crown: two discs, the smaller riding high and off-centre. Each tips a few degrees
	-- its own way, so two acacias growing into each other can't put their crown tops in one plane.
	for index, disc in ipairs({ { -0.6, 16, 1.8, 0 }, { 0.5, 9.5, 1.6, 2.4 } }) do
		local centre = Vector3.new(fork.X, canopyY + disc[1] * s, fork.Z) + side * disc[4] * s
		local tilt = CFrame.Angles((chance(0.5) and 1 or -1) * rand(0.035, 0.06), 0, (chance(0.5) and 1 or -1) * rand(0.035, 0.06))
		part(parent, "Leaves", Vector3.new(disc[3] * s, disc[2] * s, disc[2] * s), CFrame.new(centre + Vector3.new(0, disc[3] * s / 2, 0)) * tilt
			* CFrame.Angles(0, 0, math.pi / 2), index == 1 and green or green:Lerp(rgb(255, 255, 200), 0.08), Enum.Material.Grass, Enum.PartType.Cylinder)
	end
end

local function yucca(parent, p, s)
	local height = rand(8, 11) * s
	local lean = Vector3.new(rand(-0.15, 0.15), 1, rand(-0.15, 0.15)).Unit
	local tip = p + lean * height
	rod(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), tip, 1.7 * s, YUCCA_BARK, Enum.Material.Wood)

	local heads = { tip }
	local turn = rand(0, math.pi * 2)
	for index = 1, rng:NextInteger(2, 3) do
		local from = p + lean * height * (0.45 + index * 0.12)
		local angle = turn + index * 2.4
		local to = from + Vector3.new(math.cos(angle) * 4 * s, rand(3, 4.5) * s, math.sin(angle) * 4 * s)
		rod(parent, "Trunk", from, to, 1.05 * s, YUCCA_BARK, Enum.Material.Wood)
		table.insert(heads, to)
	end
	-- Each head a spiky ball: the ball and a V of blades bursting up out of it, too high and thin to matter.
	for _, head in ipairs(heads) do
		soft(ball(parent, "Leaves", head + Vector3.new(0, 0.5 * s, 0), 3 * s, YUCCA_LEAVES, Enum.Material.Grass), true)
		local turn = rand(0, math.pi)
		for blade = 1, 2 do
			soft(block(parent, "Leaves", Vector3.new(0.35, 0.3, 5 * s),
				CFrame.new(head + Vector3.new(0, 0.8 * s, 0)) * CFrame.Angles(0, turn + blade * math.pi / 2, 0) * CFrame.Angles(math.rad(blade == 1 and 55 or -40), 0, 0),
				YUCCA_LEAVES:Lerp(rgb(0, 0, 0), 0.1 * blade), Enum.Material.Grass))
		end
	end
end

local function fanPalm(parent, p, s)
	local lean = Vector3.new(rand(-0.3, 0.3), 1, rand(-0.3, 0.3)).Unit
	local mid = p + lean * 3.4 * s
	local top = mid + (lean + Vector3.new(0, 0.3, 0)).Unit * 3.2 * s
	rod(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), mid, 1.5 * s, PALM_TRUNK, Enum.Material.Wood)
	rod(parent, "Trunk", mid - lean * 0.3, top, 1.25 * s, PALM_TRUNK:Lerp(rgb(0, 0, 0), 0.08), Enum.Material.Wood)
	-- Seven fronds, an odd number so no two point exactly opposite: a frond's sides don't turn with its
	-- droop, so opposite fronds reaching past the crown would put their side faces in one plane.
	-- Their inner ends also stop just short of the centre, inside the trunk top.
	local turn = rand(0, math.pi * 2)
	for index = 1, 7 do
		local yaw = turn + index / 7 * math.pi * 2
		-- Arching down from the crown, each at its own droop and a slight twist, rather than held out flat.
		soft(block(parent, "Frond", Vector3.new(1.7 * s, 0.22, 7 * s),
			CFrame.new(top) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(rand(-34, -16)), 0, math.rad(rand(-12, 12)))
				* CFrame.new(0, 0, -3.6 * s),
			FROND:Lerp(rgb(200, 220, 120), rand(0, 0.12)), Enum.Material.Grass), true)
	end
	-- A dead frond hanging down the trunk.
	soft(block(parent, "Frond", Vector3.new(1.6 * s, 0.2, 4.6 * s),
		CFrame.new(top) * CFrame.Angles(0, turn + 0.45, 0) * CFrame.Angles(math.rad(-62), 0, 0) * CFrame.new(0, 0, -2.4 * s),
		DEAD_FROND, Enum.Material.Grass))
end

local function appleTree(parent, p, s)
	local height = rand(5.5, 6.5) * s
	column(parent, "Trunk", p - Vector3.new(0, SINK + footDrop, 0), height + SINK + footDrop, 1.8 * s, BARKS[1], Enum.Material.Wood)
	local green = leafColor(APPLE_LEAVES)
	local fruit = pick(FRUIT)
	local top = p + Vector3.new(0, height, 0)
	local crowns = { { top + Vector3.new(0, 3.4 * s, 0), 10 * s } }
	local turn = rand(0, math.pi * 2)
	for index = 1, 3 do
		local angle = turn + index * math.pi * 2 / 3
		table.insert(crowns, { top + Vector3.new(math.cos(angle) * 3.6 * s, rand(1.2, 2.2) * s, math.sin(angle) * 3.6 * s), rand(7, 8) * s })
	end
	-- An apple tree is short: its crowns hang from 2.4 to 5 studs up, so they're concealment you
	-- push through (like a shrub), not a solid ball at head height. The trunk is the cover.
	for _, crown in ipairs(crowns) do
		local leaves = ball(parent, "Leaves", crown[1], crown[2], green, Enum.Material.Grass)
		if crown[1].Y - crown[2] / 2 < p.Y + HEAD_CLEAR then
			soft(leaves, true)
		end
	end
	-- Fruit sitting in the leaves' surface.
	for index = 1, 5 do
		local crown = crowns[(index % #crowns) + 1]
		local angle = rand(0, math.pi * 2)
		local direction = Vector3.new(math.cos(angle), rand(-0.3, 0.6), math.sin(angle)).Unit
		soft(ball(parent, "Fruit", crown[1] + direction * (crown[2] / 2 - 0.2), 0.9, fruit, Enum.Material.SmoothPlastic))
	end
end

local TREES = {
	oak = { reach = 11.5, build = oak },
	birch = { reach = 5.5, build = birch },
	spruce = { reach = 8, build = spruce },
	dead = { reach = 6, build = deadTree },
	acacia = { reach = 9, build = acacia },
	yucca = { reach = 5, build = yucca },
	fanPalm = { reach = 7.5, build = fanPalm },
	apple = { reach = 8.5, build = appleTree },
}
for _, spec in pairs(TREES) do
	spec.build = grouped("Tree", spec.build)
end
appleTree = TREES.apple.build

--------------------------------------------------------------------------------
-- Ground cover: soft clumps that hide nothing solid, and a few solid pieces (logs, stumps, boulders)
--------------------------------------------------------------------------------

-- Five fronds rising out of the ground from a common root. Five, not four, so none points straight
-- back along another (their side faces would share a plane where they cross at the root).
local function fern(parent, p, s, color)
	local turn = rand(0, math.pi * 2)
	for index = 1, 5 do
		soft(block(parent, "Fern", Vector3.new(1.1 * s, 0.12 + (index % 3) * 0.02, 3.8 * s),
			CFrame.new(p - Vector3.new(0, 0.12 - index * 0.015, 0)) * CFrame.Angles(0, turn + index * math.pi * 2 / 5 + rand(-0.25, 0.25), 0)
				* CFrame.Angles(math.rad(rand(22, 40)), 0, 0) * CFrame.new(0, 0, -1.75 * s),
			(color or rgb(72, 120, 58)):Lerp(rgb(160, 190, 90), rand(0, 0.15)), Enum.Material.Grass))
	end
end

local function tuft(parent, p, s, color)
	local turn = rand(0, math.pi * 2)
	for index = 1, 3 do
		local height = rand(2.2, 3.2) * s
		soft(block(parent, "Grass", Vector3.new(0.5 * s, height, 0.12),
			CFrame.new(p) * CFrame.Angles(0, turn + index * 2.1, 0) * CFrame.Angles(math.rad(rand(10, 26)), 0, 0)
				* CFrame.new(0, height / 2 - 0.3, 0),
			color:Lerp(rgb(0, 0, 0), rand(0, 0.12)), Enum.Material.Grass))
	end
end

local function flowers(parent, p, s, palette, leaf)
	soft(ball(parent, "Flowers", p + Vector3.new(0, 0.35 * s, 0), 2 * s, leaf or rgb(78, 128, 60), Enum.Material.Grass))
	local color = pick(palette)
	for _ = 1, 3 do
		local angle = rand(0, math.pi * 2)
		soft(ball(parent, "Flowers", p + Vector3.new(math.cos(angle) * 0.75 * s, rand(1.05, 1.35) * s, math.sin(angle) * 0.75 * s),
			rand(0.6, 0.85) * s, color, Enum.Material.SmoothPlastic))
	end
end

local function mushrooms(parent, p, s)
	local cap = chance(0.5) and rgb(196, 62, 48) or rgb(176, 140, 104)
	for index = 1, 2 do
		local at = p + Vector3.new(index * 0.9 - 1.3, 0, rand(-0.6, 0.6))
		local y = groundY(at.X, at.Z, p.Y)
		-- The taller of the two stands a clear step above the other -- a WHOLE step, not one scaled
		-- down with the mushroom, which on a small pair came out under ZFight's 0.045 and put the two
		-- flat brims in one plane. And each mushroom leans its own way, so two brims in DIFFERENT
		-- clumps can't be level with each other either: measured, that was 5 of the 7 flush pairs left
		-- on Sahur Springs, all of them Mushroom against Mushroom with a dead-flat downward normal.
		local height = rand(0.7, 1.1) * s + (index - 1) * 0.35
		local width = rand(1.1, 1.5) * s
		local brim = 0.22 * s + (index - 1) * 0.05
		local leanAt, leanBy = rand(0, math.pi * 2), rand(0.06, 0.14)
		local up = Vector3.new(math.cos(leanAt) * leanBy, 1, math.sin(leanAt) * leanBy).Unit
		local foot = Vector3.new(at.X, y - 0.2, at.Z)
		soft(rod(parent, "Mushroom", foot, foot + up * (height + 0.2), 0.34 * s, rgb(232, 226, 210), Enum.Material.SmoothPlastic))
		-- The cap: a flat round brim with a low dome sunk into it, both square to the stalk.
		local top = foot + up * (height + 0.15)
		soft(rod(parent, "Mushroom", top, top + up * brim, width, cap:Lerp(rgb(0, 0, 0), 0.1), Enum.Material.SmoothPlastic))
		soft(ball(parent, "Mushroom", top + up * (brim - width * 0.3), width * 0.92, cap, Enum.Material.SmoothPlastic))
	end
end

-- A clump of long grass: taller and denser than a tuft, the sort you can crouch in. Soft, like all
-- the low foliage here -- it hides you without stopping a shot.
local function grassClump(parent, p, s, color)
	local turn = rand(0, math.pi * 2)
	-- FIVE blades, an odd number: six put opposite pairs in one plane through the middle of the clump,
	-- which measured 288 z-fighting pairs on a map's worth of grass. At 72 degrees apart no two blades
	-- in a clump come within 0.6 radians of parallel, jitter included, so the clump is safe by
	-- construction. Each blade also rolls a few degrees on its own long axis, which is what stops two
	-- blades in DIFFERENT clumps having parallel side faces by luck: measured, that was the last
	-- Grass-against-Grass pair on Sahur Springs, two vertical faces 0.029 apart.
	-- A per-clump sink as well, because every blade in a clump has its FOOT at the same depth by
	-- construction (the offset below is height/2, so the bottom sits at -0.35 whatever the blade's
	-- height), and neighbouring clumps stand on terrain that renders on 4-stud voxel boundaries --
	-- so two clumps' feet were landing in one plane. Buried either way: nothing of this shows.
	local sink = rand(0, 0.55)
	for index = 1, 5 do
		local height = rand(3.2, 4.8) * s
		soft(block(parent, "Grass", Vector3.new(0.55 * s, height, 0.12 + (index % 2) * 0.03),
			CFrame.new(p) * CFrame.Angles(0, turn + index * 1.2566 + rand(-0.22, 0.22), 0)
				* CFrame.Angles(math.rad(rand(8, 26)), 0, rand(-0.16, 0.16))
				-- 0.13 a blade, not 0.012: ZFight calls a pair flush within 0.045, so the step I put
				-- between the blades' feet was six times too small to be a step at all. Measured, those
				-- feet were the flush pairs left in the grass -- three of them 0.000 apart.
				* CFrame.new(rand(-0.3, 0.3) * s, height / 2 - 0.35 - sink + index * 0.13, rand(0.1, 0.45) * s),
			color:Lerp(rgb(0, 0, 0), rand(0, 0.14)), Enum.Material.Grass))
	end
end

local function shrub(parent, p, s, color)
	local green = color or pick(OAK_LEAVES)
	for index = 1, 2 do
		local size = rand(3.2, 4.6) * s
		local at = p + Vector3.new(rand(-1.4, 1.4) * s, 0, rand(-1.4, 1.4) * s)
		soft(ball(parent, "Shrub", Vector3.new(at.X, groundY(at.X, at.Z, p.Y) + size * 0.25, at.Z), size,
			green:Lerp(rgb(0, 0, 0), index * 0.05), Enum.Material.Grass), true)
	end
end

-- How far a part's own tilt lifts its underside: the world bounding box's half height less its own,
-- which is the rise of the far corner. A rock laid on the ground at an angle has to be sunk by this
-- much, or it stands on one edge with daylight under the other -- the "boulders floating a bit"
-- Oliver could see while playing (22:58).
local function tiltLift(size, cframe)
	return (math.abs(cframe.XVector.Y) * size.X + math.abs(cframe.YVector.Y) * size.Y
		+ math.abs(cframe.ZVector.Y) * size.Z) / 2 - size.Y / 2
end

-- Lays `size` on the ground at `at` with the given tilt, sunk by `into` of its own height plus
-- whatever its tilt lifts, so no corner of its underside shows daylight.
local function laidOnGround(parent, name, size, at, tilt, into, color, material)
	local turned = CFrame.Angles(tilt.X, tilt.Y, tilt.Z)
	local ground = groundY(at.X, at.Z, at.Y)
	return block(parent, name, size,
		CFrame.new(at.X, ground - size.Y * into - tiltLift(size, turned), at.Z) * turned, color, material)
end

-- A fallen log along `direction`, lying on the ground under both its ends.
local function fallenLog(parent, p, s, direction, color)
	local length = rand(8, 13) * s
	local diameter = rand(1.8, 2.4) * s
	local a = p - direction * length / 2
	local b = p + direction * length / 2
	local ya = groundY(a.X, a.Z, p.Y)
	local yb = groundY(b.X, b.Z, p.Y)
	local lift = diameter * 0.32
	local from = Vector3.new(a.X, ya + lift, a.Z)
	local to = Vector3.new(b.X, yb + lift, b.Z)
	rod(parent, "Log", from, to, diameter, color or pick(LOGS), Enum.Material.Wood)
	-- A broken-off branch stub and a patch of moss along the top.
	local along = from:Lerp(to, rand(0.3, 0.7))
	soft(rod(parent, "Branch", along, along + Vector3.new(direction.Z, 0.9, -direction.X) * 2.2 * s, 0.6 * s, pick(LOGS),
		Enum.Material.Wood), true)
	return from, to, diameter / 2
end
fallenLog = grouped("Log", fallenLog)

local function stump(parent, p, s)
	local diameter = rand(2.2, 3) * s
	local height = rand(1.2, 2) * s
	column(parent, "Stump", p - Vector3.new(0, 1 + footDrop, 0), height + 1 + footDrop, diameter, pick(BARKS), Enum.Material.Wood)
	-- The cut face, a shade lighter and just proud of the bark.
	soft(column(parent, "Stump", p + Vector3.new(0, height, 0), 0.12, diameter - 0.35, rgb(176, 142, 100), Enum.Material.Wood))
end
stump = grouped("Stump", stump)

local function boulder(parent, p, s, color, material, mossy)
	local size = rand(4.5, 7.5) * s
	-- Settled most of the way into the fall of the ground; all of it would bury a small rock on a slope.
	local settle = footDrop * 0.85
	local rockSize = Vector3.new(size, size * 0.7, size * rand(0.8, 1.1))
	local rockTilt = CFrame.Angles(rand(-0.35, 0.35), rand(0, math.pi), rand(-0.35, 0.35))
	-- A quarter of its height into the ground, less whatever the tilt lifts, less the fall of the
	-- ground under it.
	block(parent, "Rock", rockSize,
		CFrame.new(p + Vector3.new(0, size * 0.1 - settle - tiltLift(rockSize, rockTilt), 0)) * rockTilt, color, material)
	local small = size * 0.45
	local offset = Vector3.new(rand(-1, 1), 0, rand(-1, 1))
	offset = offset.Magnitude > 0.1 and offset.Unit or Vector3.new(1, 0, 0)
	local at = p + offset * size * 0.62
	laidOnGround(parent, "Rock", Vector3.new(small, small * 0.75, small), at,
		Vector3.new(rand(-0.5, 0.5), rand(0, math.pi), rand(-0.5, 0.5)), -0.16, color:Lerp(rgb(255, 255, 255), 0.06), material)
	if snowCover then
		soft(ball(parent, "Snow", p + Vector3.new(0, size * 0.38 - settle, 0), size * 0.5, rgb(234, 240, 244), Enum.Material.Snow))
	elseif mossy then
		soft(ball(parent, "Moss", p + Vector3.new(0, size * 0.36 - settle, 0), size * 0.55, rgb(84, 118, 60), Enum.Material.Grass))
	end
	return size * 0.75
end
boulder = grouped("Rock", boulder)

--------------------------------------------------------------------------------
-- Shelters. Each builds into its own Model, standing on `cf`: a CFrame at the site's centre, at the
-- HIGHEST ground under its footprint, turned to face its opening down its own -Z. `rise` is how far
-- the ground falls away under it, so walls and posts reach that much further down.
--------------------------------------------------------------------------------

local function firePit(parent, cf, lit)
	local stones = STONES[1]
	local centre = cf.Position
	local y = groundY(centre.X, centre.Z, centre.Y)
	for index = 1, 6 do
		local angle = index / 6 * math.pi * 2
		local at = (cf * CFrame.new(math.cos(angle) * 1.7, 0, math.sin(angle) * 1.7)).Position
		soft(ball(parent, "FireStone", Vector3.new(at.X, groundY(at.X, at.Z, y) + 0.15, at.Z), rand(0.9, 1.15),
			stones:Lerp(rgb(60, 58, 56), rand(0, 0.3)), Enum.Material.Slate), true)
	end
	local ash = soft(column(parent, "Ash", Vector3.new(centre.X, y - 0.3, centre.Z), 0.45, 2.6, rgb(52, 48, 46), Enum.Material.Slate))
	for index = 1, 2 do
		local angle = index * math.pi / 2 + rand(-0.2, 0.2)
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		soft(rod(parent, "Firewood", Vector3.new(centre.X, y + 0.35, centre.Z) - direction * 1.2,
			Vector3.new(centre.X, y + 0.55 + index * 0.02, centre.Z) + direction * 1.2, 0.45, LOGS[2], Enum.Material.Wood))
	end
	if lit then
		local fire = Instance.new("Fire")
		fire.Size = 3
		fire.Heat = 6
		fire.Color = rgb(255, 150, 60)
		fire.SecondaryColor = rgb(255, 60, 20)
		fire.Parent = ash
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 170, 90)
		light.Range = 14
		light.Brightness = 1.4
		light.Parent = ash
	end
end

local function logSeat(parent, cf, length)
	local a = (cf * CFrame.new(-length / 2, 0, 0)).Position
	local b = (cf * CFrame.new(length / 2, 0, 0)).Position
	local ya, yb = groundY(a.X, a.Z, a.Y), groundY(b.X, b.Z, b.Y)
	-- Both ends on their own ground, and the middle sunk to the lower of them: a log lying across a
	-- dip was reading as a log hanging over one.
	local sink = math.min(ya, yb) - math.min(ya, yb, groundY((a.X + b.X) / 2, (a.Z + b.Z) / 2, ya))
	rod(parent, "Log", Vector3.new(a.X, ya + 0.55 - sink, a.Z), Vector3.new(b.X, yb + 0.55 - sink, b.Z), 1.5, pick(LOGS), Enum.Material.Wood)
end

-- A lean-to: a sloping plank roof on four posts, open at the front (-Z), a plank back wall and one
-- closed side, with a log to sit on and a fire pit out front.
local function leanTo(parent, cf, rise, style)
	local planks = style == "driftwood" and rgb(176, 160, 136) or pick(PLANKS)
	local roofColor = snowTint(style == "driftwood" and rgb(196, 170, 110) or pick(ROOF_SHINGLE))
	local roofMaterial = style == "driftwood" and Enum.Material.Grass or Enum.Material.WoodPlanks
	local depth = SINK + rise
	local frontH, backH, halfW, halfD = 7.2, 3.6, 5.2, 3.6
	local pitch = math.atan((frontH - backH) / (halfD * 2))
	local midH = (frontH + backH) / 2 + 0.35

	-- Posts reach up past the roof slab's middle, so the roof visibly rests on them, and down a little
	-- deeper than the walls, so no two buried bottoms share a plane either.
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local z = corner[2] * halfD
		local top = midH - z * math.tan(pitch) + 0.12
		column(parent, "Post", (cf * CFrame.new(corner[1] * halfW, -depth - 0.3, z)).Position, top + depth + 0.3, 0.9, LOGS[1], Enum.Material.Wood)
	end
	local length = halfD * 2 / math.cos(pitch) + 1.8
	block(parent, "Roof", Vector3.new(halfW * 2 + 1.4, 0.5, length), cf * CFrame.new(0, midH, 0) * CFrame.Angles(pitch, 0, 0),
		roofColor, roofMaterial)

	-- The roof's underside above a point along Z.
	local function roofUnder(z)
		return midH - z * math.tan(pitch) - 0.25 / math.cos(pitch)
	end

	-- Back wall, just inside the back posts and up under the roof.
	local wallTop = backH - 0.05
	block(parent, "Wall", Vector3.new(halfW * 2 - 0.2, wallTop + depth, 0.6), cf * CFrame.new(0, (wallTop - depth) / 2, halfD + 0.35),
		planks, Enum.Material.WoodPlanks)
	-- One closed side: planks up to the roof at the back end, then a wedge whose slope runs a tenth
	-- of a stud inside the roof slab all the way to the front, so no daylight shows along the join.
	local side = chance(0.5) and 1 or -1
	local zBack, zFront = halfD - 0.3, -halfD
	local sideLength = zBack - zFront
	local sideTop = roofUnder(zBack) + 0.1
	local sideZ = (zBack + zFront) / 2
	block(parent, "Wall", Vector3.new(0.6, sideTop + depth, sideLength), cf * CFrame.new(side * (halfW + 0.35), (sideTop - depth) / 2, sideZ),
		planks, Enum.Material.WoodPlanks)
	-- Tall end toward the open front: the wedge's own +Z turned to the shelter's -Z.
	local gableHeight = roofUnder(zFront) + 0.1 - sideTop
	wedge(parent, "Gable", Vector3.new(0.6, gableHeight, sideLength),
		cf * CFrame.new(side * (halfW + 0.35), sideTop + gableHeight / 2, sideZ) * CFrame.Angles(0, math.pi, 0),
		planks, Enum.Material.WoodPlanks)

	-- A log to sit on facing the fire, a bedroll across the back well clear of the wall (so it isn't
	-- taken for the wall's trim when the planks break), and the fire.
	logSeat(parent, cf * CFrame.new(0, 0, -3), 6.5)
	-- On the ground under it, not on the shelter's floor level: the ground falls away under a lean-to.
	local bedAt = cf * CFrame.new(-side * 1.8, 0, 1.9)
	soft(block(parent, "Bedroll", Vector3.new(5, 0.35, 2.2),
		CFrame.new(bedAt.X, groundY(bedAt.X, bedAt.Z, cf.Y) + 0.12, bedAt.Z) * cf.Rotation, pick(FABRIC), Enum.Material.Fabric))
	firePit(parent, cf * CFrame.new(0, 0, -7.2), chance(0.55))
end

-- A ridge tent opening down its own -Z: two fabric panels, a closed back and a ridge pole.
local function tent(parent, cf, color)
	local length, halfW, height = 6.4, 2.6, 3.8
	local pitch = math.atan((height + 0.3) / halfW)
	local slope = math.sqrt(halfW * halfW + (height + 0.3) ^ 2)
	for _, side in ipairs({ 1, -1 }) do
		block(parent, "Wall", Vector3.new(slope + 0.2, 0.18, length + (side == 1 and 0 or 0.24)),
			cf * CFrame.new(side * halfW / 2, (height - 0.3) / 2, 0) * CFrame.Angles(0, 0, -side * pitch), color, Enum.Material.Fabric)
	end
	-- The back: two wedges meeting under the ridge, tall edges toward the middle.
	for _, side in ipairs({ 1, -1 }) do
		wedge(parent, "Gable", Vector3.new(0.14, height, halfW), cf * CFrame.new(side * halfW / 2, height / 2 - 0.15, length / 2 - 0.2)
			* CFrame.Angles(0, side * -math.pi / 2, 0), color:Lerp(rgb(0, 0, 0), 0.12), Enum.Material.Fabric)
	end
	soft(rod(parent, "Pole", (cf * CFrame.new(0, height + 0.05, -length / 2 - 0.4)).Position,
		(cf * CFrame.new(0, height + 0.05, length / 2 + 0.3)).Position, 0.25, rgb(70, 70, 76), Enum.Material.Metal), true)
end

local function campsite(parent, cf, rise)
	firePit(parent, cf, chance(0.7))
	local colors = table.clone(FABRIC)
	for index, spot in ipairs({ { -6, 4.5, 0.5 }, { 6.2, 3.6, -0.6 } }) do
		local at = cf * CFrame.new(spot[1], 0, spot[2])
		local y = groundY(at.X, at.Z, cf.Y)
		-- Door toward the fire.
		local toward = (cf.Position - at.Position) * Vector3.new(1, 0, 1)
		local facing = CFrame.lookAt(Vector3.new(at.X, y, at.Z), Vector3.new(at.X, y, at.Z) + toward.Unit) * CFrame.Angles(0, spot[3] * 0.3, 0)
		tent(parent, facing, table.remove(colors, rng:NextInteger(1, #colors)))
		if index == 1 then
			soft(block(parent, "Bedroll", Vector3.new(1.8, 0.3, 3.8), facing * CFrame.new(0, 0.12, 0.3), pick(FABRIC), Enum.Material.Fabric))
		end
	end
	logSeat(parent, cf * CFrame.new(0, 0, -4.2) * CFrame.Angles(0, rand(-0.2, 0.2), 0), 5.5)
	logSeat(parent, cf * CFrame.new(-4.4, 0, -1.6) * CFrame.Angles(0, math.pi / 2 + rand(-0.3, 0.3), 0), 4.5)
	-- A small woodpile and a supply crate you can shoot apart.
	local pile = cf * CFrame.new(5.5, 0, -5.5) * CFrame.Angles(0, rand(0, math.pi), 0)
	local py = groundY(pile.X, pile.Z, cf.Y)
	for index, offset in ipairs({ { -0.62, 0.62, 3.6 }, { 0.62, 0.62, 3.9 }, { 0, 1.66, 3.3 } }) do
		local c = pile * CFrame.new(offset[1], 0, 0)
		local a = Vector3.new(c.X, py + offset[2], c.Z) + pile.LookVector * offset[3] / 2
		local b = Vector3.new(c.X, py + offset[2], c.Z) - pile.LookVector * offset[3] / 2
		rod(parent, "Log", a, b, 1.24 - index * 0.01, LOGS[index % 2 + 1], Enum.Material.Wood)
	end
	local crateAt = cf * CFrame.new(-6.6, 0, -6)
	block(parent, "Crate", Vector3.new(3, 3, 3), CFrame.new(crateAt.X, groundY(crateAt.X, crateAt.Z, cf.Y) + 1.45, crateAt.Z)
		* CFrame.Angles(0, rand(0, 1.4), 0), rgb(150, 116, 74), Enum.Material.WoodPlanks)
end

-- A wall along local X from x0 to x1 at z, bottom at -depth, top at `top`, with optional openings
-- { centre, width, bottom, top } cut through it as bands and piers. Returns the parts.
local function wallRun(parent, cf, name, x0, x1, z, depth, top, thickness, color, material, openings)
	local parts = {}
	local function piece(a, b, y0, y1)
		if b - a > 0.05 and y1 - y0 > 0.05 then
			table.insert(parts, block(parent, name, Vector3.new(b - a, y1 - y0, thickness), cf * CFrame.new((a + b) / 2, (y0 + y1) / 2, z),
				color, material))
		end
	end
	local cursor = x0
	for _, opening in ipairs(openings or {}) do
		local left, right = opening.centre - opening.width / 2, opening.centre + opening.width / 2
		-- Pier up to the full height beside the opening; sill and lintel across it.
		piece(cursor, left, -depth, top)
		piece(left, right, -depth, opening.bottom)
		piece(left, right, opening.top, top)
		if opening.glass then
			table.insert(parts, pane(parent, Vector3.new(opening.width + 0.2, opening.top - opening.bottom + 0.2, 0.2),
				cf * CFrame.new(opening.centre, (opening.bottom + opening.top) / 2, z)))
		end
		cursor = right
	end
	piece(cursor, x1, -depth, top)
	return parts
end

local CABIN_STYLES = {
	cabin = {
		walls = { rgb(120, 86, 58), rgb(104, 76, 52), rgb(132, 98, 66) }, wallMaterial = Enum.Material.WoodPlanks, wallName = "Wall",
		posts = LOGS[2], postMaterial = Enum.Material.Wood, postName = "Post",
		roof = ROOF_SHINGLE, roofMaterial = Enum.Material.Slate, pitched = true, porch = true, chimney = true,
	},
	bothy = {
		walls = STONES, wallMaterial = Enum.Material.Cobblestone, wallName = "StoneWall", gableName = "StoneWall",
		posts = rgb(118, 112, 104), postMaterial = Enum.Material.Cobblestone, postName = "StoneWall",
		roof = { rgb(70, 74, 78), rgb(88, 82, 78) }, roofMaterial = Enum.Material.Slate, pitched = true, porch = false, chimney = true,
	},
	beach = {
		walls = { rgb(120, 178, 196), rgb(236, 196, 120), rgb(214, 128, 116), rgb(150, 196, 150) }, wallMaterial = Enum.Material.WoodPlanks,
		wallName = "Wall", posts = rgb(238, 236, 228), postMaterial = Enum.Material.Wood, postName = "Post",
		roof = { rgb(160, 120, 84), rgb(214, 204, 186) }, roofMaterial = Enum.Material.WoodPlanks, pitched = false, porch = true, chimney = false,
	},
	shack = {
		walls = { rgb(122, 96, 82), rgb(96, 104, 108), rgb(132, 120, 98) }, wallMaterial = Enum.Material.CorrodedMetal, wallName = "Wall",
		posts = rgb(64, 66, 70), postMaterial = Enum.Material.Metal, postName = "Post",
		roof = { rgb(110, 90, 76), rgb(90, 96, 100) }, roofMaterial = Enum.Material.CorrodedMetal, pitched = false, porch = false, chimney = false,
	},
}

-- A one-room hut, 16 by 13: corner posts carrying the roof, walls with window openings between
-- them, a doorway at the front (-Z), a floor, and a few things inside to hide behind.
local function cabin(parent, cf, rise, styleName)
	local style = CABIN_STYLES[styleName] or CABIN_STYLES.cabin
	local W, D, H, T, P = 16, 13, 8.5, 0.8, 1.3
	local halfW, halfD = W / 2, D / 2
	local depth = SINK + rise
	local wallColor = pick(style.walls)
	local roofColor = snowTint(pick(style.roof))

	-- Walls go `depth` underground, posts 0.3 deeper and the floor slab 0.4 shallower, so none of their
	-- buried bottom faces share a plane.
	-- The floor: a slab from underground to just above the highest ground.
	local floorDepth = depth - 0.4
	block(parent, "Deck", Vector3.new(W - 0.2, 0.35 + floorDepth, D - 0.2), cf * CFrame.new(0, (0.35 - floorDepth) / 2, 0),
		rgb(128, 98, 70), Enum.Material.WoodPlanks)

	-- Corner posts, square, standing proud of the wall faces so they never share a plane.
	local postDepth = depth + 0.3
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		block(parent, style.postName, Vector3.new(P, H + postDepth, P), cf * CFrame.new(corner[1] * halfW, (H - postDepth) / 2, corner[2] * halfD),
			style.posts, style.postMaterial)
	end

	local inX0, inX1 = -halfW + P / 2, halfW - P / 2
	local inZ0, inZ1 = -halfD + P / 2, halfD - P / 2
	local doorX = rand(-2.5, 2.5)
	-- Front: a doorway.
	wallRun(parent, cf, style.wallName, inX0, inX1, -halfD, depth, H, T, wallColor, style.wallMaterial,
		{ { centre = doorX, width = 4.4, bottom = -depth, top = 7 } })
	-- Back: a window.
	wallRun(parent, cf, style.wallName, inX0, inX1, halfD, depth, H, T, wallColor, style.wallMaterial,
		{ { centre = rand(-3, 3), width = 4, bottom = 3.4, top = 6.6, glass = styleName ~= "shack" } })
	-- Sides run along Z: build them in a frame turned a quarter so wallRun's X is the side's length.
	for _, sideSign in ipairs({ -1, 1 }) do
		local sideFrame = cf * CFrame.new(sideSign * halfW, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
		local openings = (sideSign == 1 or chance(0.5)) and { { centre = rand(-1.5, 1.5), width = 3.4, bottom = 3.4, top = 6.4,
			glass = styleName ~= "shack" } } or nil
		wallRun(parent, sideFrame, style.wallName, inZ0, inZ1, 0, depth, H, T, wallColor, style.wallMaterial, openings)
	end

	if style.pitched then
		-- Ridge along X; gables stand on the side walls.
		local pitch = math.rad(32)
		local rise2 = math.tan(pitch) * halfD
		for _, sideSign in ipairs({ -1, 1 }) do
			for _, halfSide in ipairs({ 1, -1 }) do
				wedge(parent, style.gableName or "Gable", Vector3.new(T, rise2, halfD),
					cf * CFrame.new(sideSign * halfW, H + rise2 / 2, halfSide * halfD / 2) * CFrame.Angles(0, halfSide == 1 and math.pi or 0, 0),
					wallColor, style.wallMaterial)
			end
		end
		local overhang = 1.3
		local slabWidth = halfD / math.cos(pitch) + overhang
		for index, zSign in ipairs({ -1, 1 }) do
			-- Down-slope direction and outward normal of this half.
			local down = Vector3.new(0, -math.sin(pitch), zSign * math.cos(pitch))
			local normal = Vector3.new(0, math.cos(pitch), zSign * math.sin(pitch))
			local centre = Vector3.new(0, H + rise2 / 2, zSign * halfD / 2) + down * (overhang / 2) + normal * 0.3
			-- CFrame.Angles(a, 0, 0) with a > 0 lifts a slab's -Z end, so each half lifts the end
			-- toward the ridge. Lengths differ by a fifth, so the two gable-end faces never share a plane.
			block(parent, "Roof", Vector3.new(W + 1.6 + index * 0.2, 0.6, slabWidth),
				cf * CFrame.new(centre) * CFrame.Angles(zSign * pitch, 0, 0), roofColor, style.roofMaterial)
		end
		-- Kept inside the slabs' length, clear of the chimney, so it only ever hangs on the roof.
		soft(block(parent, "RidgeCap", Vector3.new(W + 1, 0.45, 1.1), cf * CFrame.new(0, H + rise2 + 0.5, 0),
			roofColor:Lerp(rgb(0, 0, 0), 0.2), style.roofMaterial), true)
	else
		block(parent, "Roof", Vector3.new(W + 2.4, 0.6, D + 2.4), cf * CFrame.new(0, H + 0.45, 0.3) * CFrame.Angles(math.rad(3), 0, 0),
			roofColor, style.roofMaterial)
	end

	if style.chimney then
		local top = style.pitched and H + math.tan(math.rad(32)) * halfD + 2.6 or H + 3
		-- Off the ridge line, so no chimney face can land in the plane of a ridge cap face (z = +-0.55).
		local chimneyZ = (chance(0.5) and 1 or -1) * rand(2, 2.6)
		block(parent, "StoneWall", Vector3.new(2.4, top + depth + 0.15, 2.4), cf * CFrame.new(halfW + P / 2 + 1.2, (top - depth - 0.15) / 2, chimneyZ),
			rgb(128, 120, 112), Enum.Material.Cobblestone)
	end

	if style.porch then
		local porchD = 4.2
		local porchDepth = depth - 0.25
		block(parent, "Deck", Vector3.new(W - 2.4, 0.2 + porchDepth, porchD), cf * CFrame.new(0, (0.2 - porchDepth) / 2, -halfD - P / 2 - porchD / 2),
			rgb(120, 92, 66), Enum.Material.WoodPlanks)
		local frontZ = -halfD - P / 2 - porchD + 0.5
		for _, x in ipairs({ -(halfW - 2), halfW - 2 }) do
			column(parent, "Post", (cf * CFrame.new(x, -depth, frontZ)).Position, 7.4 + depth, 0.7, style.posts, style.postMaterial)
		end
		local awningLength = frontZ * -1 - halfD + 0.9
		-- Sloping down and away from the wall (its -Z end lower).
		block(parent, "Roof", Vector3.new(W - 1.2, 0.35, awningLength),
			cf * CFrame.new(0, 7.55, -halfD - awningLength / 2 + 0.1) * CFrame.Angles(math.rad(-6), 0, 0), roofColor, style.roofMaterial)
	end

	-- Inside (x -7.6..7.6, z -6.1..6.1 between the wall faces): a cot along the right, a crate in the
	-- back-left corner, a table in front of both, and a clear run in from the doorway.
	local tableAt = CFrame.new(rand(-1.5, 0.5), 0, rand(-2.5, -1))
	block(parent, "Table", Vector3.new(4.2, 0.35, 2.6), cf * tableAt * CFrame.new(0, 3.0, 0), rgb(120, 88, 60), Enum.Material.Wood)
	block(parent, "Table", Vector3.new(0.8, 2.66, 0.8), cf * tableAt * CFrame.new(0, 1.66, 0), rgb(104, 76, 52), Enum.Material.Wood)
	block(parent, "Bed", Vector3.new(3.2, 1.3, 6.2), cf * CFrame.new(4.4, 1.0, 2.6), rgb(96, 72, 52), Enum.Material.Wood)
	soft(block(parent, "Blanket", Vector3.new(3, 0.3, 4.6), cf * CFrame.new(4.4, 1.78, 1.9), pick(FABRIC), Enum.Material.Fabric), true)
	block(parent, "Crate", Vector3.new(3, 3, 3), cf * CFrame.new(-5.2, 1.85, 3.7) * CFrame.Angles(0, rand(-0.25, 0.25), 0),
		rgb(150, 116, 74), Enum.Material.WoodPlanks)
	if styleName == "shack" then
		local drumAt = cf * CFrame.new(halfW + 2.2, 0, -halfD + 1.5)
		column(parent, "Drum", Vector3.new(drumAt.X, groundY(drumAt.X, drumAt.Z, cf.Y) - 0.4, drumAt.Z), 4.4, 2.6, rgb(52, 92, 120), Enum.Material.Metal)
	end
end

local RUIN_STYLES = {
	stone = { colors = STONES, material = Enum.Material.Cobblestone, columns = true, vines = true },
	sandstone = { colors = { rgb(206, 178, 132), rgb(190, 162, 120), rgb(220, 194, 150) }, material = Enum.Material.Sandstone, columns = true },
	concrete = { colors = { rgb(150, 148, 142), rgb(128, 126, 122), rgb(164, 160, 152) }, material = Enum.Material.Concrete, rebar = true },
}

-- The shell of an old building: walls broken to different heights, a doorway, one window arch, and
-- fallen blocks round about. Stone doesn't break, so a ruin is permanent cover.
local function ruin(parent, cf, rise, styleName)
	local style = RUIN_STYLES[styleName] or RUIN_STYLES.stone
	local W, D, T = rand(18, 22), rand(12, 15), 1.6
	local halfW, halfD = W / 2, D / 2
	local depth = SINK + rise
	local color = pick(style.colors)

	-- Heights down a wall, in segments; zero leaves a breach. Neighbours always differ by a clear step.
	-- Returns each standing segment's top, centre and width, in the wall's own frame.
	local function run(frame, length, profile, window)
		local count = #profile
		local segment = length / count
		local last = -1
		local tops = {}
		for index, height in ipairs(profile) do
			if height > 0 then
				if math.abs(height - last) < 0.4 then
					height += 0.6
				end
				last = height
				local x0 = -length / 2 + (index - 1) * segment
				if window == index and height >= 7 then
					wallRun(parent, frame, "Ruin", x0, x0 + segment, 0, depth, height, T, color, style.material,
						{ { centre = x0 + segment / 2, width = segment * 0.5, bottom = 3.2, top = 6 } })
				else
					block(parent, "Ruin", Vector3.new(segment, height + depth, T), frame * CFrame.new(x0 + segment / 2, (height - depth) / 2, 0),
						color:Lerp(rgb(0, 0, 0), rand(0, 0.08)), style.material)
				end
				table.insert(tops, { x = x0 + segment / 2, width = segment, top = height, window = window == index and height >= 7 })
			else
				last = -1
			end
		end
		return tops
	end

	local function heights(count, low, high, breach)
		local list = {}
		for index = 1, count do
			list[index] = rand(low, high)
		end
		if breach then
			list[breach] = 0
		end
		return list
	end

	-- Front wall (with the doorway as a breach) and back wall (tallest, with a window) run the full
	-- outside width, T past each side wall's centreline; the sides butt between them, so every
	-- corner is square and no two walls overlap.
	run(cf * CFrame.new(0, 0, -halfD), W + T, heights(5, 2.4, 6.5, 3))
	local backTops = run(cf * CFrame.new(0, 0, halfD), W + T, heights(4, 4.5, 8.5), 2)
	for _, sideSign in ipairs({ -1, 1 }) do
		local frame = cf * CFrame.new(sideSign * halfW, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
		run(frame, D - T, heights(3, 1.8, 5.5, chance(0.4) and rng:NextInteger(1, 3) or nil))
	end

	-- Fallen blocks outside the walls, each on its own ground.
	for _ = 1, rng:NextInteger(3, 5) do
		local angle = rand(0, math.pi * 2)
		local distance = rand(1.02, 1.22)
		local at = cf * CFrame.new(math.cos(angle) * (halfW + 2.5) * distance, 0, math.sin(angle) * (halfD + 2.5) * distance)
		local size = Vector3.new(rand(2.2, 3.6), rand(1.4, 2.2), rand(1.6, 2.6))
		laidOnGround(parent, "Ruin", size, Vector3.new(at.X, cf.Y, at.Z), Vector3.new(rand(-0.4, 0.4), rand(0, math.pi), rand(-0.4, 0.4)),
			0.05, color:Lerp(rgb(255, 255, 255), 0.05), style.material)
	end

	if style.columns then
		-- A pair of broken columns out front, where a portico stood.
		for _, x in ipairs({ -halfW * 0.45, halfW * 0.45 }) do
			local at = cf * CFrame.new(x, 0, -halfD - 5.5)
			column(parent, "Ruin", Vector3.new(at.X, groundY(at.X, at.Z, cf.Y) - SINK, at.Z), SINK + rand(2.5, 6.5), 2.2, color, style.material)
		end
	end
	if style.vines then
		-- Ivy climbing the back wall's outside face from the ground: narrow strands leaning a little
		-- each way, kept below the lowest top and apart along the wall, their feet at different depths.
		-- Turning a strand about the wall's normal keeps it flat against the stone.
		local lowest = math.huge
		for _, segment in ipairs(backTops) do
			lowest = math.min(lowest, segment.top)
		end
		for index, x in ipairs({ -halfW * 0.55, -halfW * 0.2, halfW * 0.35 }) do
			local height = math.min(rand(3.2, 5.2), lowest - 0.6)
			local bottom = -0.1 - index * 0.12
			soft(block(parent, "Vine", Vector3.new(rand(0.8, 1.3), height, 0.14),
				cf * CFrame.new(x + rand(-1, 1), bottom + height / 2, halfD + T / 2 + 0.09) * CFrame.Angles(0, 0, rand(-0.25, 0.25)),
				rgb(70, 112, 56):Lerp(rgb(110, 150, 70), rand(0, 0.4)), Enum.Material.Grass))
		end
	end
	if style.rebar and #backTops > 0 then
		-- Bent reinforcing bar sticking out of the broken tops of the back wall.
		for _ = 1, 3 do
			local segment = pick(backTops)
			if segment and not segment.window then
				local at = cf * CFrame.new(segment.x + rand(-segment.width * 0.35, segment.width * 0.35), segment.top - 0.3, halfD)
				soft(rod(parent, "Rebar", at.Position, (at * CFrame.new(rand(-0.6, 0.6), 2.4, rand(-0.4, 0.4))).Position, 0.2,
					rgb(110, 70, 50), Enum.Material.CorrodedMetal), true)
			end
		end
	end
	-- Rubble inside.
	for _ = 1, 3 do
		local at = cf * CFrame.new(rand(-halfW + 3, halfW - 3), 0, rand(-halfD + 3, halfD - 3))
		soft(ball(parent, "Debris", Vector3.new(at.X, groundY(at.X, at.Z, cf.Y) + 0.2, at.Z), rand(1, 1.8), color, style.material), true)
	end
end

local ROCK_STYLES = {
	rock = { color = rgb(122, 118, 110), material = Enum.Material.Rock, moss = true },
	slate = { color = rgb(104, 102, 100), material = Enum.Material.Slate, moss = false },
	sandstone = { color = rgb(196, 164, 120), material = Enum.Material.Sandstone, moss = false },
}

-- An overhang: three standing boulders round a hollow with a slab laid over them, open at the front.
local function rockShelter(parent, cf, rise, styleName)
	local style = ROCK_STYLES[styleName] or ROCK_STYLES.rock
	local color = style.color
	local function slab(size, offset, angles, name)
		return block(parent, name or "Rock", size + Vector3.new(0, rise, 0), cf * CFrame.new(offset - Vector3.new(0, rise / 2, 0))
			* CFrame.Angles(angles.X, angles.Y, angles.Z), color:Lerp(rgb(0, 0, 0), rand(0, 0.1)), style.material)
	end
	-- Each boulder's top reaches at least half a stud into the roof slab, so it visibly bears it.
	slab(Vector3.new(14, 9, 4.5), Vector3.new(0, 3.2, 5.4), Vector3.new(rand(-0.08, 0), rand(-0.1, 0.1), rand(-0.05, 0.05)))
	slab(Vector3.new(4.6, 8.4, 10.5), Vector3.new(-6, 2.9, 0.8), Vector3.new(rand(-0.05, 0.05), 0.14, rand(0.03, 0.08)))
	slab(Vector3.new(4.2, 8.4, 9.5), Vector3.new(5.8, 2.8, 0.4), Vector3.new(rand(-0.05, 0.05), -0.12, rand(-0.08, -0.03)))
	-- The roof slab, tipped back a little so it reads as fallen rather than placed.
	block(parent, "Rock", Vector3.new(16.5, 2.6, 13.5), cf * CFrame.new(0, 8, 1.6) * CFrame.Angles(rand(0.08, 0.14), rand(-0.06, 0.06), rand(-0.05, 0.05)),
		snowTint(color:Lerp(rgb(255, 255, 255), 0.04)), style.material)
	-- A broken-off second slab lying skewed across the first, so the top reads as rock, not a lid.
	block(parent, "Rock", Vector3.new(9, 2.2, 8), cf * CFrame.new(rand(-3, 3), 9.6, rand(1, 3))
		* CFrame.Angles(rand(-0.25, -0.12), rand(0.3, 0.9), rand(0.12, 0.25)), snowTint(color:Lerp(rgb(0, 0, 0), 0.06)), style.material)
	-- Loose rocks at the mouth: low cover in front.
	for _, x in ipairs({ -5.5, 5.8 }) do
		local at = cf * CFrame.new(x + rand(-1, 1), 0, -6.5 + rand(-1, 1))
		local size = rand(2.8, 4)
		laidOnGround(parent, "Rock", Vector3.new(size, size * 0.75, size), Vector3.new(at.X, cf.Y, at.Z),
			Vector3.new(rand(-0.4, 0.4), rand(0, math.pi), rand(-0.4, 0.4)), -0.2 / 0.75, color, style.material)
	end
	if style.moss and not snowCover then
		for _, x in ipairs({ -3.5, 4 }) do
			soft(ball(parent, "Moss", (cf * CFrame.new(x, 9.2, rand(0, 3))).Position, rand(3.5, 5), rgb(84, 118, 60), Enum.Material.Grass), true)
		end
	end
end

-- A hunting stand: a railed platform twelve studs up on splayed legs, roofed, with a ladder.
local function deerStand(parent, cf, rise)
	local H, half = 12, 4.2
	local wood = pick(PLANKS)
	local legs = LOGS[1]
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local foot = cf * CFrame.new(corner[1] * (half + 0.9), 0, corner[2] * (half + 0.9))
		local y = groundY(foot.X, foot.Z, cf.Y - rise)
		rod(parent, "Post", Vector3.new(foot.X, y - SINK, foot.Z), (cf * CFrame.new(corner[1] * (half - 0.8), H + 0.3, corner[2] * (half - 0.8))).Position,
			0.8, legs, Enum.Material.Wood)
	end
	-- Cross bracing on the two sides.
	for _, sideSign in ipairs({ -1, 1 }) do
		soft(rod(parent, "Brace", (cf * CFrame.new(sideSign * (half + 0.3), 1.5, -half - 0.3)).Position,
			(cf * CFrame.new(sideSign * (half - 0.4), H - 0.6, half - 0.4)).Position, 0.4, legs, Enum.Material.Wood), true)
	end
	block(parent, "Deck", Vector3.new(half * 2, 0.6, half * 2), cf * CFrame.new(0, H + 0.3, 0), wood, Enum.Material.WoodPlanks)

	-- Railings: back wall full width, sides butted to it, and a front rail each side of the ladder gap.
	local railY, railH, t = H + 0.6, 3.2, 0.5
	block(parent, "Wall", Vector3.new(half * 2, railH, t), cf * CFrame.new(0, railY + railH / 2, half - t / 2), wood, Enum.Material.WoodPlanks)
	for _, sideSign in ipairs({ -1, 1 }) do
		block(parent, "Wall", Vector3.new(t, railH, half * 2 - t), cf * CFrame.new(sideSign * (half - t / 2), railY + railH / 2, -t / 2), wood,
			Enum.Material.WoodPlanks)
		local inner, outer = 1.15, half - t
		block(parent, "Wall", Vector3.new(outer - inner, railH, t), cf * CFrame.new(sideSign * (inner + outer) / 2, railY + railH / 2, -half + t / 2),
			wood, Enum.Material.WoodPlanks)
	end
	-- Roof on four corner posts.
	local roofY = railY + 6.6
	-- Set into the deck, so their feet aren't in the plane the railings stand on.
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		column(parent, "Post", (cf * CFrame.new(corner[1] * (half - t / 2), railY - 0.3, corner[2] * (half - t / 2))).Position, roofY - railY + 0.3, 0.4,
			legs, Enum.Material.Wood)
	end
	block(parent, "Roof", Vector3.new(half * 2 + 1.6, 0.4, half * 2 + 1.6), cf * CFrame.new(0, roofY + 0.2, 0) * CFrame.Angles(math.rad(-7), 0, 0),
		snowTint(pick(ROOF_SHINGLE)), Enum.Material.WoodPlanks)

	-- Ladder up the front, through the gap in the rail. Trusses are climbed natively.
	-- Its top is level with the deck; its foot goes a stud or more into the ground.
	local ladderBase = cf * CFrame.new(0, 0, -half - 1)
	local groundAtLadder = groundY(ladderBase.X, ladderBase.Z, cf.Y)
	local deckTop = cf.Y + railY
	local even = math.max(2, math.ceil((deckTop - (groundAtLadder - 1)) / 2) * 2)
	truss(parent, "Ladder", cf.Rotation + Vector3.new(ladderBase.X, deckTop - even / 2, ladderBase.Z), even, legs)
end

-- An open-sided farm shelter: six posts, a pitched tin roof, a plank half wall along the back and
-- hay stacked inside.
local function poleBarn(parent, cf, rise)
	local W, D, eave = 20, 13, 9
	local halfW, halfD = W / 2, D / 2
	local depth = SINK + rise
	local pitch = math.rad(20)
	local ridge = math.tan(pitch) * halfD
	local posts = LOGS[1]
	for _, x in ipairs({ -halfW, 0, halfW }) do
		for _, z in ipairs({ -halfD, halfD }) do
			block(parent, "Post", Vector3.new(1, eave + depth, 1), cf * CFrame.new(x, (eave - depth) / 2, z), posts, Enum.Material.Wood)
		end
	end
	-- A beam down each long side for the roof to sit on.
	for index, z in ipairs({ -halfD, halfD }) do
		block(parent, "Post", Vector3.new(W + 1 + index * 0.2, 0.8, 1.1), cf * CFrame.new(0, eave + 0.4, z), posts, Enum.Material.Wood)
	end
	local roofColor = snowTint(pick({ rgb(150, 64, 52), rgb(120, 126, 132), rgb(92, 110, 84) }))
	local overhang = 1.4
	for index, zSign in ipairs({ -1, 1 }) do
		local down = Vector3.new(0, -math.sin(pitch), zSign * math.cos(pitch))
		local normal = Vector3.new(0, math.cos(pitch), zSign * math.sin(pitch))
		local centre = Vector3.new(0, eave + 0.8 + ridge / 2, zSign * halfD / 2) + down * (overhang / 2) + normal * 0.25
		block(parent, "Roof", Vector3.new(W + 2 + index * 0.24, 0.5, halfD / math.cos(pitch) + overhang),
			cf * CFrame.new(centre) * CFrame.Angles(zSign * pitch, 0, 0), roofColor, Enum.Material.CorrodedMetal)
	end
	-- Back half wall between the posts.
	for _, span in ipairs({ { -halfW + 0.5, -0.5 }, { 0.5, halfW - 0.5 } }) do
		block(parent, "Wall", Vector3.new(span[2] - span[1], 4 + depth, 0.6), cf * CFrame.new((span[1] + span[2]) / 2, (4 - depth) / 2, halfD),
			pick(PLANKS), Enum.Material.WoodPlanks)
	end
	-- Hay: a row of bales with a second tier half across it, every bale a hair apart. Each bottom bale
	-- sits on its own ground (the barn floor is the field, and it isn't level), and each top bale on
	-- the higher of the two below it.
	local hay = rgb(214, 180, 96)
	local count = rng:NextInteger(3, 4)
	local bottoms = {}
	for index = 1, count do
		local x = -halfW + 3 + (index - 1) * 4.15
		local at = cf * CFrame.new(x, 0, halfD - 2.2)
		local lift = groundY(at.X, at.Z, cf.Y) - cf.Y
		bottoms[index] = lift
		block(parent, "Hay", Vector3.new(4, 2.6, 2.6), cf * CFrame.new(x, lift + 1.25, halfD - 2.2), hay:Lerp(rgb(0, 0, 0), rand(0, 0.08)), Enum.Material.Grass)
	end
	for index = 1, count - 1 do
		local x = -halfW + 3 + (index - 1) * 4.15
		local lift = math.max(bottoms[index], bottoms[index + 1])
		block(parent, "Hay", Vector3.new(3.9, 2.5, 2.5), cf * CFrame.new(x + 2.08, lift + 3.82, halfD - 2.35), hay:Lerp(rgb(255, 255, 255), rand(0, 0.06)),
			Enum.Material.Grass)
	end
	-- A loose round bale out front.
	local roundAt = cf * CFrame.new(rand(-5, 5), 0, -halfD - 4)
	part(parent, "Hay", Vector3.new(4.4, 5.4, 5.4), CFrame.new(roundAt.X, groundY(roundAt.X, roundAt.Z, cf.Y) + 2.4, roundAt.Z)
		* CFrame.Angles(0, rand(0, math.pi), 0), hay, Enum.Material.Grass, Enum.PartType.Cylinder)
end

-- A thatched sunshade on four poles, with a table and a driftwood windbreak.
local function palapa(parent, cf, rise)
	local half, H = 4.6, 7.4
	local poles = rgb(170, 140, 104)
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		column(parent, "Post", (cf * CFrame.new(corner[1] * half, -SINK - rise, corner[2] * half)).Position, H + SINK + rise + 0.3, 0.7, poles, Enum.Material.Wood)
	end
	pyramid(parent, "Roof", cf * CFrame.new(0, H, 0), 12.5, 4.4, rgb(196, 170, 110), Enum.Material.Grass)
	block(parent, "Table", Vector3.new(3.2, 0.3, 3.2), cf * CFrame.new(0, 2.9, 0) * CFrame.Angles(0, rand(0, 1), 0), rgb(160, 126, 90), Enum.Material.WoodPlanks)
	column(parent, "Table", (cf * CFrame.new(0, -0.8 - rise, 0)).Position, 3.56 + rise, 0.8, rgb(140, 110, 80), Enum.Material.Wood)
	-- Windbreak: three bleached logs stacked along one side, lengths staggered.
	local side = chance(0.5) and 1 or -1
	local frame = cf * CFrame.new(side * (half + 2.2), 0, 0)
	for index, row in ipairs({ { -0.66, 0.62, 8.4 }, { 0.66, 0.62, 8.8 }, { 0, 1.72, 8.1 } }) do
		local c = frame * CFrame.new(row[1], 0, 0)
		local y = groundY(c.X, c.Z, cf.Y)
		rod(parent, "Log", Vector3.new(c.X, y + row[2], c.Z) + frame.LookVector * row[3] / 2,
			Vector3.new(c.X, y + row[2], c.Z) - frame.LookVector * row[3] / 2, 1.3, rgb(186, 172, 150):Lerp(rgb(0, 0, 0), index * 0.04), Enum.Material.Wood)
	end
end

-- Big concrete drainage pipes left out on the verge: crouch inside one for cover on three sides.
local function pipes(parent, cf, rise)
	local radius, wall = 3.8, 0.8
	local count = rng:NextInteger(2, 3)
	local color = rgb(150, 148, 142)
	for index = 1, count do
		local length = 10 + index * 0.3
		local axis = cf * CFrame.new((index - (count + 1) / 2) * (radius * 2 + wall + 1.8), radius + wall / 2 - 0.4 - rise, rand(-1.5, 1.5))
		local segments = 8
		local width = 2 * (radius + wall / 2) * math.tan(math.pi / segments) + 0.12
		for k = 0, segments - 1 do
			local angle = k / segments * math.pi * 2
			-- Alternate lengths, so the end faces of neighbouring segments never share a plane.
			block(parent, "Pipe", Vector3.new(width, wall, length + (k % 2) * 0.24),
				axis * CFrame.Angles(0, 0, angle) * CFrame.new(0, -(radius + wall / 2), 0), color:Lerp(rgb(0, 0, 0), rand(0, 0.06)), Enum.Material.Concrete)
		end
	end
	-- Broken bits of concrete round about.
	for _ = 1, 2 do
		local at = cf * CFrame.new(rand(-8, 8), 0, rand(6, 8) * (chance(0.5) and 1 or -1))
		local size = rand(1.4, 2.6)
		laidOnGround(parent, "Pipe", Vector3.new(size * 1.6, size * 0.6, size), Vector3.new(at.X, cf.Y, at.Z),
			Vector3.new(rand(-0.3, 0.3), rand(0, math.pi), rand(-0.3, 0.3)), -0.25, color, Enum.Material.Concrete)
	end
end

-- A roadside bus shelter, open toward the road (-Z): glass back and ends in a metal frame, a roof,
-- a bench and a sign.
local function busShelter(parent, cf, rise)
	local W, D, H = 10, 4, 7.6
	local halfW, halfD = W / 2, D / 2
	local metal = rgb(58, 62, 70)
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		block(parent, "Post", Vector3.new(0.4, H + SINK + rise, 0.4), cf * CFrame.new(corner[1] * halfW, (H - SINK - rise) / 2, corner[2] * halfD),
			metal, Enum.Material.Metal)
	end
	block(parent, "Roof", Vector3.new(W + 1, 0.4, D + 1), cf * CFrame.new(0, H + 0.2, 0.1) * CFrame.Angles(math.rad(-3), 0, 0), metal, Enum.Material.Metal)
	-- Glass between the posts, with a solid kick panel under the back pane.
	block(parent, "Wall", Vector3.new(W - 0.4, 1.4 + rise + 0.6, 0.3), cf * CFrame.new(0, (1.4 - rise - 0.6) / 2, halfD), metal, Enum.Material.Metal)
	pane(parent, Vector3.new(W - 0.3, H - 1.5, 0.2), cf * CFrame.new(0, 1.4 + (H - 1.4) / 2 - 0.05, halfD))
	for _, sideSign in ipairs({ -1, 1 }) do
		pane(parent, Vector3.new(0.2, H - 1.5, D - 0.3), cf * CFrame.new(sideSign * halfW, 1.4 + (H - 1.4) / 2 - 0.05, 0))
	end
	block(parent, "Bench", Vector3.new(W - 2, 0.35, 1.3), cf * CFrame.new(0, 1.7, halfD - 1.1), rgb(120, 88, 60), Enum.Material.WoodPlanks)
	for _, x in ipairs({ -(halfW - 1.6), halfW - 1.6 }) do
		local legDepth = rise + 0.3
		block(parent, "Bench", Vector3.new(0.3, 1.52 + legDepth, 1), cf * CFrame.new(x, (1.52 - legDepth) / 2, halfD - 1.1), metal, Enum.Material.Metal)
	end
	-- The stop sign on its own pole beside the shelter.
	local signBase = cf * CFrame.new(halfW + 1.6, 0, -halfD - 0.4)
	local y = groundY(signBase.X, signBase.Z, cf.Y)
	column(parent, "Post", Vector3.new(signBase.X, y - SINK, signBase.Z), SINK + 8.2, 0.3, metal, Enum.Material.Metal)
	local plate = soft(block(parent, "Sign", Vector3.new(2.2, 1.6, 0.15),
		CFrame.new(signBase.X, y + 7.6, signBase.Z) * cf.Rotation * CFrame.new(0, 0, -0.25), rgb(40, 120, 196), Enum.Material.SmoothPlastic), true)
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(220, 160)
		gui.LightInfluence = 0.6
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBlack
		label.Text = "BUS"
		label.TextScaled = true
		label.TextColor3 = rgb(255, 255, 255)
		label.Parent = gui
		gui.Parent = plate
	end
end

local WRECK_PAINT = { rgb(128, 72, 52), rgb(92, 98, 106), rgb(146, 124, 92), rgb(70, 92, 76) }

-- A burnt-out car left to rust: flat on its belly, wheels gone but for two on one side, the bonnet
-- crumpled and a door lying beside it. Waist-high body, head-high cabin: real cover.
local function wreck(parent, cf, rise)
	local paint = pick(WRECK_PAINT)
	local rust = paint:Lerp(rgb(110, 62, 36), 0.45)
	-- The whole car settles a few degrees toward the side that lost its wheels (its -X).
	local frame = cf * CFrame.Angles(rand(-0.03, 0.03), 0, 0.05)
	block(parent, "Wreck", Vector3.new(6.2, 1.9 + rise, 13), frame * CFrame.new(0, 0.65 - rise / 2, 0), rust, Enum.Material.CorrodedMetal)
	block(parent, "Wreck", Vector3.new(5.6, 1.85, 6), frame * CFrame.new(0, 2.5, 0.8), paint:Lerp(rgb(40, 36, 34), 0.35), Enum.Material.CorrodedMetal)
	-- The bonnet: a wedge sloping down from the windscreen, a fraction narrower than the body.
	wedge(parent, "Wreck", Vector3.new(5.8, 0.9, 3.4), frame * CFrame.new(0, 2.05, -3.9), rust:Lerp(rgb(0, 0, 0), 0.1), Enum.Material.CorrodedMetal)
	for _, z in ipairs({ -4.2, 4.3 }) do
		local at = frame * CFrame.new(3.35, 0, z)
		local y = groundY(at.X, at.Z, cf.Y)
		part(parent, "Tyre", Vector3.new(0.9, 2, 2), frame.Rotation + Vector3.new(at.X, y + 0.95, at.Z), rgb(34, 34, 36), Enum.Material.Rubber,
			Enum.PartType.Cylinder)
	end
	-- Black window band round the cabin, headlights and a bumper, so it reads as a car at a glance.
	soft(block(parent, "Glass", Vector3.new(5.72, 0.9, 6.12), frame * CFrame.new(0, 2.75, 0.8), rgb(24, 26, 30), Enum.Material.SmoothPlastic), true)
	for _, x in ipairs({ -2.1, 2.1 }) do
		soft(part(parent, "Light", Vector3.new(0.3, 0.9, 0.9), frame * CFrame.new(x, 1.15, -6.55) * CFrame.Angles(0, math.pi / 2, 0),
			rgb(210, 200, 170), Enum.Material.Glass, Enum.PartType.Cylinder), true)
	end
	soft(block(parent, "Bumper", Vector3.new(6.4, 0.45, 0.5), frame * CFrame.new(0, 0.55, -6.62), rgb(70, 70, 74), Enum.Material.Metal), true)
	local doorAt = cf * CFrame.new(-5.4, 0, rand(-2, 2))
	soft(block(parent, "Door", Vector3.new(3, 0.22, 3.4), CFrame.new(doorAt.X, groundY(doorAt.X, doorAt.Z, cf.Y) + 0.05, doorAt.Z)
		* CFrame.Angles(rand(-0.08, 0.08), rand(0, math.pi), rand(-0.08, 0.08)), paint, Enum.Material.CorrodedMetal), true)
end

-- A rowing boat left upturned above the tideline: two planked halves meeting at the keel (their
-- lengths a fifth apart, so the stern faces don't share a plane), and its oars dropped beside it.
local function upturnedBoat(parent, cf, rise)
	local hull = pick({ rgb(236, 236, 228), rgb(70, 110, 160), rgb(186, 70, 58), rgb(228, 196, 90) })
	local length, height, half = 12, 2.7 + rise, 2.5
	for index, sideSign in ipairs({ 1, -1 }) do
		-- Tall edge along the keel: the wedge's +Z turned toward the centre line, its X along the boat.
		wedge(parent, "Boat", Vector3.new(length + (index - 1) * 0.2, height, half),
			cf * CFrame.new(sideSign * half / 2, height / 2 - rise - 0.2, 0) * CFrame.Angles(0, -sideSign * math.pi / 2, 0),
			hull:Lerp(rgb(0, 0, 0), (index - 1) * 0.06), Enum.Material.WoodPlanks)
	end
	soft(block(parent, "Keel", Vector3.new(0.4, 0.3, length + 0.5), cf * CFrame.new(0, height - rise - 0.1, 0), rgb(110, 82, 58), Enum.Material.Wood), true)
	for index, x in ipairs({ -3.6, -4.3 }) do
		local at = cf * CFrame.new(x, 0, rand(-2, 2))
		local y = groundY(at.X, at.Z, cf.Y)
		local turn = rand(-0.2, 0.2)
		-- The second oar lies across the first, a hair higher, so their blades never share a plane.
		soft(block(parent, "Oar", Vector3.new(0.3, 0.2, 7), CFrame.new(at.X, y + 0.12 + index * 0.12, at.Z) * cf.Rotation * CFrame.Angles(0, turn, 0),
			rgb(176, 140, 96), Enum.Material.Wood), true)
	end
end

-- A waymarker cairn: flat stones stacked smaller toward the top, each turned its own way.
local function cairn(parent, p, s, color, material)
	local y = -0.3 - footDrop
	for index, size in ipairs({ 2.8, 2.2, 1.7, 1.1 }) do
		local thick = (index == 1 and 0.9 + footDrop or 0.7) * s
		block(parent, "Rock", Vector3.new(size * s, thick, size * s * rand(0.8, 1)),
			CFrame.new(p + Vector3.new(rand(-0.15, 0.15), y + thick / 2, rand(-0.15, 0.15)))
				* CFrame.Angles(rand(-0.06, 0.06), rand(0, math.pi), rand(-0.06, 0.06)),
			snowTint(color:Lerp(rgb(255, 255, 255), index * 0.03)), material)
		y += thick * 0.92
	end
end
cairn = grouped("Cairn", cairn)

-- A picnic table: top, two benches, and end frames that reach down to the lowest ground under it.
local function picnicTable(parent, p, yaw)
	local frame = CFrame.new(p) * CFrame.Angles(0, yaw, 0)
	local wood = pick(PLANKS)
	block(parent, "Table", Vector3.new(6, 0.3, 2.6), frame * CFrame.new(0, 2.7, 0), wood, Enum.Material.WoodPlanks)
	for _, z in ipairs({ -1.9, 1.9 }) do
		block(parent, "Bench", Vector3.new(6, 0.25, 1), frame * CFrame.new(0, 1.5, z), wood:Lerp(rgb(0, 0, 0), 0.08), Enum.Material.WoodPlanks)
	end
	-- Each end an A of two splayed legs, reaching down to the lowest ground under the table.
	for _, x in ipairs({ -2.4, 2.4 }) do
		for _, lean in ipairs({ -1, 1 }) do
			local length = 3.1 + footDrop
			block(parent, "Table", Vector3.new(0.3, length, 0.5),
				-- A tenth of a stud apart along X, so the two legs' side faces never share a plane where they cross.
				frame * CFrame.new(x + lean * 0.09, 2.55, 0) * CFrame.Angles(lean * 0.42, 0, 0) * CFrame.new(0, -length / 2, 0),
				wood:Lerp(rgb(0, 0, 0), 0.15), Enum.Material.Wood)
		end
	end
end
picnicTable = grouped("Picnic", picnicTable)

-- Each shelter: its footprint's half extents (before any turn), how uneven its ground may be, and
-- its builder. `reach` pads the claim for pieces set outside the walls (fire pits, fallen blocks).
local SHELTERS = {
	leanTo = { halfX = 6.5, halfZ = 9.5, offsetZ = -2.5, flat = 1.6, build = function(p, cf, rise) leanTo(p, cf, rise) end },
	driftwoodLeanTo = { halfX = 6.5, halfZ = 9.5, offsetZ = -2.5, flat = 1.6, build = function(p, cf, rise) leanTo(p, cf, rise, "driftwood") end },
	campsite = { halfX = 10, halfZ = 9, flat = 1.8, rigid = true, build = campsite },
	cabin = { halfX = 11.5, halfZ = 12, offsetZ = -2, flat = 2.4, build = function(p, cf, rise) cabin(p, cf, rise, "cabin") end },
	bothy = { halfX = 11.5, halfZ = 8.5, flat = 2.2, build = function(p, cf, rise) cabin(p, cf, rise, "bothy") end },
	beachHut = { halfX = 10, halfZ = 12, offsetZ = -2, flat = 1.8, build = function(p, cf, rise) cabin(p, cf, rise, "beach") end },
	shack = { halfX = 12, halfZ = 8.5, flat = 2, build = function(p, cf, rise) cabin(p, cf, rise, "shack") end },
	ruin = { halfX = 16.5, halfZ = 14, flat = 2.6, build = function(p, cf, rise) ruin(p, cf, rise, "stone") end },
	sandstoneRuin = { halfX = 16.5, halfZ = 14, flat = 2.6, build = function(p, cf, rise) ruin(p, cf, rise, "sandstone") end },
	concreteRuin = { halfX = 16.5, halfZ = 13, flat = 2.6, build = function(p, cf, rise) ruin(p, cf, rise, "concrete") end },
	rockShelter = { halfX = 10, halfZ = 9.5, flat = 2.4, build = function(p, cf, rise) rockShelter(p, cf, rise, "rock") end },
	slateShelter = { halfX = 10, halfZ = 9.5, flat = 2.4, build = function(p, cf, rise) rockShelter(p, cf, rise, "slate") end },
	sandstoneShelter = { halfX = 10, halfZ = 9.5, flat = 2.4, build = function(p, cf, rise) rockShelter(p, cf, rise, "sandstone") end },
	deerStand = { halfX = 7, halfZ = 8, flat = 3, build = deerStand },
	poleBarn = { halfX = 12, halfZ = 12, offsetZ = -1.5, flat = 1.8, build = poleBarn },
	palapa = { halfX = 9.5, halfZ = 7.5, flat = 1.6, build = palapa },
	pipes = { halfX = 15.5, halfZ = 9.5, flat = 0.9, rigid = true, build = pipes },
	busShelter = { halfX = 8, halfZ = 3.5, flat = 1.2, rigid = true, build = busShelter },
	wreck = { halfX = 7.5, halfZ = 7.5, flat = 1.4, rigid = true, build = wreck },
	upturnedBoat = { halfX = 5, halfZ = 7, flat = 1.2, rigid = true, build = upturnedBoat },
}
for kind, spec in pairs(SHELTERS) do
	spec.build = grouped(kind == "wreck" and "Wreck" or "Shelter", spec.build)
end
MapWilds.ShelterKinds = SHELTERS

--------------------------------------------------------------------------------
-- What grows where
--------------------------------------------------------------------------------

local GRASS_TUFT = rgb(104, 138, 64)

local PROFILES = {
	[Enum.Material.Grass] = {
		trees = { oak = 5, birch = 3, spruce = 2, dead = 0.5 },
		woods = 1.0, scattered = 1.0,
		shelters = { leanTo = 3, cabin = 2, ruin = 2, rockShelter = 1.5, deerStand = 1, campsite = 2 },
		clearing = { campsite = 2, leanTo = 2, deerStand = 1, ruin = 0.7 },
		undergrowth = { fern = 3, flowers = 3, tuft = 2, mushrooms = 1, shrub = 1.2 },
		clutter = { log = 1.5, stump = 1, boulder = 1, picnic = 0.35 },
		flowers = "meadow", tuft = GRASS_TUFT, meadows = 1.0, stoneWalls = 0.3, hedgerows = 0.2,
		rock = { color = rgb(122, 118, 110), material = Enum.Material.Rock, moss = true },
	},
	[Enum.Material.Ground] = {
		trees = { birch = 3, dead = 3, oak = 2, spruce = 0.5 },
		-- The downtown map has the least open ground between its towns, so what there is gets more.
		woods = 0.9, scattered = 1.0, treeScale = 0.85, shelterScale = 1.5, coverScale = 1.5,
		shelters = { shack = 3, pipes = 2.5, concreteRuin = 2, wreck = 2.5, leanTo = 1, campsite = 0.7, rockShelter = 0.5 },
		clearing = { campsite = 1, leanTo = 2, shack = 1 },
		undergrowth = { tuft = 4, shrub = 2, flowers = 0.7, fern = 0.5 },
		clutter = { log = 1, stump = 1.2, boulder = 1 },
		flowers = "weeds", tuft = rgb(128, 132, 78), meadows = 0.3, stoneWalls = 0, hedgerows = 0,
		rock = { color = rgb(128, 122, 114), material = Enum.Material.Rock, moss = false },
	},
	[Enum.Material.Sand] = {
		trees = { acacia = 3, yucca = 3, fanPalm = 3 },
		woods = 0.5, scattered = 0.45,
		shelters = { palapa = 2.5, beachHut = 2, sandstoneRuin = 2, sandstoneShelter = 2.5, driftwoodLeanTo = 1, campsite = 1, upturnedBoat = 2, wreck = 1 },
		clearing = { palapa = 2, campsite = 1.5, driftwoodLeanTo = 1 },
		undergrowth = { tuft = 4, shrub = 2 },
		clutter = { log = 0.6, boulder = 2 },
		flowers = "meadow", tuft = rgb(184, 170, 112), shrubColor = rgb(124, 132, 76), logColor = rgb(186, 172, 150),
		meadows = 0, stoneWalls = 0, hedgerows = 0,
		rock = { color = rgb(196, 164, 120), material = Enum.Material.Sandstone, moss = false },
	},
	[Enum.Material.Rock] = {
		trees = { spruce = 6, dead = 1.5, birch = 1 },
		woods = 1.0, scattered = 1.0, flatScale = 1.8, shelterScale = 1.3,
		shelters = { bothy = 3, slateShelter = 3, ruin = 2, leanTo = 1.5, campsite = 1.5, deerStand = 0.7 },
		clearing = { campsite = 2, leanTo = 2, bothy = 1 },
		undergrowth = { tuft = 2, flowers = 2, fern = 1, shrub = 1 },
		clutter = { log = 2, stump = 1.5, boulder = 3, cairn = 1 },
		flowers = "heather", tuft = rgb(138, 128, 84), meadows = 0.4, stoneWalls = 0.8, hedgerows = 0,
		rock = { color = rgb(104, 102, 100), material = Enum.Material.Slate, moss = false },
	},
	[Enum.Material.LeafyGrass] = {
		trees = { oak = 4, apple = 2, birch = 1.5 },
		woods = 0.7, scattered = 1.0,
		shelters = { poleBarn = 3, leanTo = 1.5, cabin = 1.5, ruin = 1, deerStand = 1.5, campsite = 1, wreck = 0.5 },
		clearing = { campsite = 1.5, leanTo = 1.5, deerStand = 1.5 },
		undergrowth = { flowers = 3, tuft = 3, fern = 1, shrub = 1, mushrooms = 0.5 },
		clutter = { log = 1, stump = 1, boulder = 1, picnic = 0.5 },
		flowers = "meadow", tuft = rgb(112, 146, 66), meadows = 1.3, stoneWalls = 0.5, hedgerows = 1.0, orchards = 1.0, autumn = 0.3,
		rock = { color = rgb(122, 118, 110), material = Enum.Material.Rock, moss = true },
	},
}
MapWilds.Profiles = PROFILES

-- The material a map's grass is painted in, over its own base material and nothing else. Both of
-- these are measured smooth (+-0.006), so the surface lands exactly where the voxels put it. A Rock
-- map is missing on purpose: rock is drawn rough, and a smooth patch over the same voxels reads as a
-- change of shape underfoot even though no voxel moved.
local GRASS_PAINT = {
	[Enum.Material.Grass] = Enum.Material.LeafyGrass,
	[Enum.Material.LeafyGrass] = Enum.Material.Grass,
	[Enum.Material.Ground] = Enum.Material.Grass,
	[Enum.Material.Sand] = Enum.Material.Grass,
}

-- Terrain the map paints over its base that shouldn't grow a tree: town paving, roads, ice.
local BARE = {
	[Enum.Material.Pavement] = true, [Enum.Material.Asphalt] = true, [Enum.Material.Concrete] = true,
	[Enum.Material.Salt] = true, [Enum.Material.Glacier] = true, [Enum.Material.Water] = true,
}

--------------------------------------------------------------------------------
-- Specimens: one of everything, in a row, for galleries and audits
--------------------------------------------------------------------------------

function MapWilds.Specimens(parent, origin, groundAt, seed)
	rng = Random.new(seed or 7)
	partCount = 0
	sampler = groundAt
	autumnShare, snowCover, footDrop = 0, false, 0
	local row = model(parent, "WildsSpecimens")
	local x = 0
	local entries = {}
	local function place(name, width, build)
		x += width / 2
		local m = model(row, name)
		local before = partCount
		build(m, origin + Vector3.new(x, 0, 0))
		table.insert(entries, { name = name, model = m, parts = partCount - before, at = origin + Vector3.new(x, 0, 0) })
		x += width / 2 + 6
	end
	local treeOrder = { "oak", "birch", "spruce", "dead", "acacia", "yucca", "fanPalm", "apple" }
	for _, kind in ipairs(treeOrder) do
		place("Tree_" .. kind, TREES[kind].reach * 2, function(m, at)
			TREES[kind].build(m, at, 1)
		end)
	end
	place("Tree_spruceSnowy", 16, function(m, at)
		spruce(m, at, 1, true)
	end)
	place("Ground_fern", 5, function(m, at) fern(m, at, 1) end)
	place("Ground_tuft", 4, function(m, at) tuft(m, at, 1, GRASS_TUFT) end)
	place("Ground_flowers", 4, function(m, at) flowers(m, at, 1, FLOWER_SETS.meadow) end)
	place("Ground_mushrooms", 4, function(m, at) mushrooms(m, at, 1) end)
	place("Ground_shrub", 7, function(m, at) shrub(m, at, 1) end)
	place("Ground_log", 13, function(m, at) fallenLog(m, at, 1, Vector3.new(0, 0, 1)) end)
	place("Ground_stump", 4, function(m, at) stump(m, at, 1) end)
	place("Ground_boulder", 10, function(m, at) boulder(m, at, 1, rgb(122, 118, 110), Enum.Material.Rock, true) end)
	place("Ground_cairn", 5, function(m, at) cairn(m, at, 1, rgb(104, 102, 100), Enum.Material.Slate) end)
	place("Ground_picnic", 8, function(m, at) picnicTable(m, at, 0.3) end)
	-- Every kind, variants included: two shelters that differ only in material still differ in the
	-- parts they build (a driftwood roof is thatch, a sandstone overhang is a different stone), and an
	-- audit that never builds one can't say anything about it.
	local shelterOrder = { "leanTo", "driftwoodLeanTo", "campsite", "cabin", "bothy", "beachHut", "shack", "ruin", "sandstoneRuin", "concreteRuin",
		"rockShelter", "sandstoneShelter", "deerStand", "poleBarn", "palapa", "pipes", "busShelter", "wreck", "upturnedBoat" }
	for _, kind in ipairs(shelterOrder) do
		local spec = SHELTERS[kind]
		place("Shelter_" .. kind, spec.halfX * 2, function(m, at)
			spec.build(m, CFrame.new(at + Vector3.new(0, 0, -(spec.offsetZ or 0))), 0)
		end)
	end
	-- The seasonal variants: a turned oak and birch (Patapim), and snow on a rock, a slate overhang
	-- and a bothy (above Rot Ridge's snow line).
	place("Season_oakAutumn", TREES.oak.reach * 2, function(m, at)
		autumnShare = 1
		oak(m, at, 1)
		autumnShare = 0
	end)
	place("Season_birchAutumn", TREES.birch.reach * 2, function(m, at)
		autumnShare = 1
		birch(m, at, 1)
		autumnShare = 0
	end)
	for _, kind in ipairs({ "slateShelter", "bothy" }) do
		local spec = SHELTERS[kind]
		place("Season_" .. kind .. "Snow", spec.halfX * 2, function(m, at)
			snowCover = true
			spec.build(m, CFrame.new(at + Vector3.new(0, 0, -(spec.offsetZ or 0))), 0)
			snowCover = false
		end)
	end
	place("Season_boulderSnow", 10, function(m, at)
		snowCover = true
		boulder(m, at, 1, rgb(104, 102, 100), Enum.Material.Slate, false)
		snowCover = false
	end)
	sampler = nil
	return row, entries
end

--------------------------------------------------------------------------------
-- The build
--------------------------------------------------------------------------------

function MapWilds.Build(map, ctx)
	-- Wall clock, not os.clock: a build that yields spends most of its life not on the CPU, and
	-- os.clock() reported 0.35s for a build the harness timed at 0.50s. Callers reading `seconds`
	-- want the time the map generator actually spent here.
	local started = DateTime.now().UnixTimestampMillis
	rng = Random.new(ctx.seed or 1)
	partCount = 0

	local preset, radius, centers, townSpread, space = ctx.preset, ctx.radius, ctx.centers, ctx.townSpread, ctx.space
	-- The five arguments this cannot be built without, checked here and named in the error. A map
	-- generator is about to call this for the first time, and a missing field would otherwise show
	-- up as an arithmetic error 200 lines in, or as a half-built Wilds -- neither of which says
	-- which argument the CALLER left out. Everything else is optional and defaults quietly:
	-- roads (no verges or corridor veto), river (no bank planting), avoid (nothing kept clear),
	-- groundAt (the second ground veto; this module casts its own ray regardless), seed (1).
	for _, need in ipairs({
		{ "preset", preset }, { "radius", radius }, { "centers", centers }, { "townSpread", townSpread }, { "space", space },
	}) do
		if need[2] == nil then
			error(string.format("MapWilds.Build: ctx.%s is required (see the argument list at the top of this file)", need[1]), 2)
		end
	end
	if type(space.IsFree) ~= "function" then
		error("MapWilds.Build: ctx.space must be a MapSpace (it needs IsFree)", 2)
	end
	local profile = PROFILES[preset.terrainMaterial] or PROFILES[Enum.Material.Grass]
	autumnShare = profile.autumn or 0
	snowCover = false
	local area = (radius / 1150) ^ 2
	local budget = math.floor(radius * MapWilds.BUDGET_PER_RADIUS)
	local counts = { trees = 0, undergrowth = 0, shelters = 0, byKind = {} }
	local serial = 0

	local root = Instance.new("Model")
	root.Name = "Wilds"
	root.Parent = map

	local function count(kind)
		counts.byKind[kind] = (counts.byKind[kind] or 0) + 1
	end

	-- Groups of scattered things (a stand of trees, a meadow, a hedgerow) aren't structures with a
	-- floor: the footing audit skips them. Shelters carry their footprint instead (placeShelter).
	local SCATTER = { Woods = true, Trees = true, Clutter = true, GroundCover = true, Meadow = true, Hedgerow = true, StoneWall = true,
		Orchard = true, Grass = true }
	local function named(prefix)
		serial += 1
		local m = model(root, prefix .. "_" .. serial)
		if SCATTER[prefix] then
			m:SetAttribute("FootingSkip", true)
		end
		return m
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { workspace.Terrain }
	rayParams.IgnoreWater = false

	-- Ground and what it's made of, or nil over water, off the map's own veto, or on paving.
	-- Cast from far above anything the map builds: a ray that starts inside terrain (a mountain top
	-- over the old 500) never reports that terrain.
	-- Counted, because "the veto never fires" and "the veto fires and nothing is out there" look
	-- identical in a part count. THIS is the ground veto: it does not wait on GroundHeightAt's nil
	-- contract, which is a breaking change across 47 sites in 10 modules and is not this module's
	-- to make. The ray here answers the same question -- no hit is no ground, and water is not
	-- ground -- so the counts are honest today and will not move when that contract lands.
	local vetoed = { nothing = 0, water = 0, mapSaysNone = 0, corridor = 0 }
	local function sample(x, z)
		local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), rayParams)
		if not hit then
			vetoed.nothing += 1
			return nil
		end
		if hit.Material == Enum.Material.Water then
			vetoed.water += 1
			return nil
		end
		if ctx.groundAt and ctx.groundAt(x, z) == nil then
			vetoed.mapSaysNone += 1
			return nil
		end
		return hit.Position.Y, hit.Material
	end
	sampler = sample

	-- Paints a patch of grass: MATERIAL ONLY, never shape (claude-79's rules, 22:58). ReplaceMaterial
	-- from the map's own base material, so a road's asphalt and gravel, a river's sand banks and
	-- anything else painted on purpose are left as they are; never Fill*, which writes occupancy too
	-- and is how ground quietly rises under a building. Roads keep their whole shaping reach.
	local paintTo = GRASS_PAINT[preset.terrainMaterial]
	local paintedPatches = 0
	-- Asked for softly, once: this module requires nothing, so it can be built and audited alone.
	local terrainModule = script.Parent:FindFirstChild("MapTerrain")
	local MapTerrain = terrainModule and require(terrainModule)
	local function paintGrass(x, z, spread)
		if not paintTo then
			return
		end
		if ctx.roads and ctx.roads.GroundAt and ctx.roads:GroundAt(x, z, 0) then
			return
		end
		-- And never a town's ground: its square, streets and pavements are somebody else's to paint,
		-- and roundabouts and sidewalks are being added to every town centre as I write this. The
		-- clumps already keep out (townFactor), but a patch centred at the edge of one would have
		-- painted over the line.
		for _, centre in ipairs(centers) do
			if (Vector2.new(centre.X - x, centre.Z - z)).Magnitude < townSpread + 40 + spread then
				return
			end
		end
		-- Once the pads land, a structure's whole pad is off limits: PadNear covers a terraced site ring
		-- by ring, the slopes between its steps and the graded skirt at the bottom; PadAt (the flat only)
		-- is the fallback if that call doesn't exist yet.
		if MapTerrain then
			if MapTerrain.PadNear then
				if MapTerrain.PadNear(x, z, 4) then
					return
				end
			elseif MapTerrain.PadAt and MapTerrain.PadAt(x, z) then
				return
			end
		end
		local y = sample(x, z)
		if not y then
			return
		end
		-- Three overlapping squares rather than one: a region is a box, and a single box reads as a
		-- mown rectangle from the air. Jittered, they read as a patch with a ragged edge.
		for index = 1, 3 do
			local size = spread * (index == 1 and 1 or rand(0.5, 0.75))
			local ox = index == 1 and 0 or rand(-spread * 0.6, spread * 0.6)
			local oz = index == 1 and 0 or rand(-spread * 0.6, spread * 0.6)
			local min = Vector3.new(x + ox - size, y - 10, z + oz - size)
			local max = Vector3.new(x + ox + size, y + 10, z + oz + size)
			workspace.Terrain:ReplaceMaterial(Region3.new(min, max):ExpandToGrid(4), 4, preset.terrainMaterial, paintTo)
		end
		paintedPatches += 1
	end

	local limit = radius * 0.93
	local avoid = ctx.avoid or {}

	-- How welcome growth is here: nothing inside a town's edge, fading in over the next 130 studs,
	-- so woods thin out toward a town rather than stopping at a line.
	local function townFactor(x, z)
		local nearest = math.huge
		for _, centre in ipairs(centers) do
			local dx, dz = centre.X - x, centre.Z - z
			nearest = math.min(nearest, dx * dx + dz * dz)
		end
		return math.clamp((math.sqrt(nearest) - townSpread - 40) / 130, 0, 1)
	end

	-- `ignore` skips one claim, the way MapSpace means it: a bus shelter stands on the verge of the very
	-- road it serves, inside that road's corridor claim but clear of everything else.
	local function open(x, z, reach, ignore)
		if x * x + z * z > limit * limit then
			return false
		end
		-- Never inside a road's corridor: the carriageway, its 3-stud shoulders and the 8-stud flat
		-- apron the road grades round itself. That whole band is the road's own ground -- a trunk in
		-- it is standing in the road, and on a rocky map the apron's outer studs are not even flat
		-- (the roads tab measures 9-11% of samples 13-19 studs out off by more than 0.25, worst
		-- 1.17). The claims in `space` cover the road's PARTS, not that graded band, so this is a
		-- different question from IsFree; and the roads' own query answers it correctly on a curve,
		-- where a distance from the centre line reads a trunk in the apron as clear (claude-79).
		-- NOT a burial fix: the hook goes in after the second RestoreRoadGround, so the ground read
		-- here is already the road's final ground. It would become one if the hook ever moved up.
		-- `ignore` means the caller is on that road on purpose: a bus shelter stands on its verge.
		if not ignore and ctx.roads and ctx.roads.WithinCorridor then
			if ctx.roads:WithinCorridor(x, z) then
				vetoed.corridor += 1
				return false
			end
			-- And nothing whose footprint reaches into it either, checked at the four compass points:
			-- a shelter clear at its middle can still have a corner post in the apron.
			local edge = math.min(reach or 0, 26)
			if edge > 2 then
				for _, at in ipairs({ { edge, 0 }, { -edge, 0 }, { 0, edge }, { 0, -edge } }) do
					if ctx.roads:WithinCorridor(x + at[1], z + at[2]) then
						vetoed.corridor += 1
						return false
					end
				end
			end
		end
		for _, spot in ipairs(avoid) do
			local dx, dz = spot.X - x, spot.Z - z
			if dx * dx + dz * dz < (50 + reach) ^ 2 then
				return false
			end
		end
		return space:IsFree(x, z, reach, ignore)
	end

	local function welcome(x, z, exponent)
		local factor = townFactor(x, z)
		return factor > 0 and rng:NextNumber() < factor ^ (exponent or 1)
	end

	-- Which phase ran out of budget, and how often it asked after that. Without this a density
	-- number can only be raised by guesswork: parts stop growing whether the attempts ran out or
	-- the share did, and the fix for those two is not the same one.
	local capped = {}
	local function overBudget(share)
		if partCount >= budget * share then
			capped[share] = (capped[share] or 0) + 1
			return true
		end
		return false
	end

	local function treeKindFor(material, preferred)
		if BARE[material] then
			return nil
		end
		if material == Enum.Material.Snow then
			return "spruce", true
		end
		if (material == Enum.Material.Sand or material == Enum.Material.Sandstone) and preset.terrainMaterial ~= Enum.Material.Sand then
			return chance(0.5) and "dead" or nil
		end
		return preferred or weighted(profile.trees), false
	end

	----------------------------------------------------------------------------
	-- Shelters
	----------------------------------------------------------------------------

	local SAMPLES = { { 0, 0 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
	-- What the opening looks out on: across it and out to DOOR_REACH, the ground may climb no more than
	-- DOOR_RISE over the floor, nor fall more than DOOR_DROP within four studs of it. A lean-to opening
	-- onto a bank, a cabin door onto a two-stud rise, a slate shelter over a three-stud drop: a door
	-- into a hill or off a ledge (Oliver, 2026-09-24; tools/foundation_check.py).
	local DOOR_RISE, DOOR_DROP, DOOR_REACH = 1.5, 2.5, 5
	-- Where the shelters and the stands of trees went: the grass goes round them.
	local shelterSpots, woodsSpots = {}, {}

	-- Tries to put shelter `kind` at (x, z) facing `yaw` (its opening down local -Z). Returns true
	-- when built. With no `yaw` given, a random one, turned a quarter at a time until the opening
	-- looks out on open ground; a caller's yaw (a bus stop facing its road) is kept or the spot goes.
	local tryShelter
	local function placeShelter(kind, x, z, yaw, ignore)
		if yaw then
			return tryShelter(kind, x, z, yaw, ignore)
		end
		local first = rand(0, math.pi * 2)
		for turn = 0, 3 do
			if tryShelter(kind, x, z, first + turn * math.pi / 2, ignore) then
				return true
			end
		end
		return false
	end

	tryShelter = function(kind, x, z, yaw, ignore)
		local spec = SHELTERS[kind]
		if not spec then
			return false
		end
		-- The footprint's own centre can sit off the build origin (a fire pit out front).
		local frame = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
		local centre = frame * CFrame.new(0, 0, spec.offsetZ or 0)
		-- MapSpace answers circles, so the footprint is checked as a row of them down its long axis,
		-- each big enough to reach the corners either side. One circle round the whole diagonal would
		-- refuse a long narrow shelter (a bus stop) anywhere near a road it's meant to stand beside.
		local long, short = math.max(spec.halfX, spec.halfZ), math.min(spec.halfX, spec.halfZ)
		local axis = spec.halfX >= spec.halfZ and centre.RightVector or centre.LookVector
		local circle = short * math.sqrt(2) + 2
		local stretch = long - short
		local steps = math.max(0, math.ceil(stretch * 2 / short))
		for k = 0, steps do
			local t = steps == 0 and 0 or (-stretch + 2 * stretch * k / steps)
			local at = centre.Position + axis * t
			if not open(at.X, at.Z, circle, ignore) then
				return false
			end
		end
		local low, high = math.huge, -math.huge
		local centreMaterial
		for _, s in ipairs(SAMPLES) do
			local w = centre * CFrame.new(s[1] * spec.halfX, 0, s[2] * spec.halfZ)
			local y, material = sample(w.X, w.Z)
			if not y or BARE[material] then
				return false
			end
			centreMaterial = centreMaterial or material
			low, high = math.min(low, y), math.max(high, y)
		end
		-- Highland ground is rarely level, so huts there may stand on more of a slope (their walls and
		-- posts reach down by however far it falls). Things that can't follow a slope never stretch.
		if high - low > spec.flat * (spec.rigid and 1 or (profile.flatScale or 1)) then
			return false
		end
		-- The way out: across the opening, out to DOOR_REACH, never into a bank, over a drop or water.
		for _, across in ipairs({ -0.4, 0, 0.4 }) do
			for out = 1, DOOR_REACH do
				local w = centre * CFrame.new(across * spec.halfX, 0, -spec.halfZ - out)
				local y = sample(w.X, w.Z)
				if not y or y > high + DOOR_RISE or (out <= 4 and y < high - DOOR_DROP) then
					return false
				end
			end
		end
		space:AddRect(centre.X, centre.Z, spec.halfX + 2, spec.halfZ + 2, yaw)
		local m = named(kind)
		local base = CFrame.new(x, high, z) * CFrame.Angles(0, yaw, 0)
		snowCover = centreMaterial == Enum.Material.Snow
		spec.build(m, base, high - low)
		snowCover = false
		-- The footing convention: the pivot at the footprint's centre at floor height, turned the way
		-- the opening faces (its LookVector points out of the opening), with the footprint's size and
		-- the floor height as attributes for the footing audit.
		m.WorldPivot = CFrame.new(centre.X, high, centre.Z) * CFrame.Angles(0, yaw, 0)
		m:SetAttribute("FootingSize", Vector3.new(spec.halfX * 2, 0, spec.halfZ * 2))
		m:SetAttribute("FootingBase", high)
		table.insert(shelterSpots, centre.Position)
		counts.shelters += 1
		count(kind)
		return true
	end

	-- Yaw that turns local -Z toward `direction`.
	local function yawToward(direction)
		return math.atan2(-direction.X, -direction.Z)
	end

	-- Routes between towns: the road network's edges when there is one, else the ring of towns
	-- and the spokes to the middle, the way the roads are planned.
	local corridors = {}
	local roads = ctx.roads
	-- A road end may be a position or a node carrying one.
	local function positionOf(value)
		if typeof(value) == "Vector3" then
			return value
		elseif type(value) == "table" and typeof(value.position) == "Vector3" then
			return value.position
		end
		return nil
	end
	if roads and roads.edges then
		for _, edge in ipairs(roads.edges) do
			local from, to = positionOf(edge.from) or positionOf(edge.a), positionOf(edge.to) or positionOf(edge.b)
			if from and to then
				table.insert(corridors, { a = from, b = to, edge = edge })
			end
		end
	elseif type(roads) == "table" and #roads > 0 then
		for _, road in ipairs(roads) do
			if road.legs then
				for _, leg in ipairs(road.legs) do
					table.insert(corridors, { a = leg[1], b = leg[2] })
				end
			elseif road.from and road.to then
				table.insert(corridors, { a = road.from, b = road.to })
			end
		end
	end
	local plannedRoutes = #corridors == 0
	if plannedRoutes and #centers > 1 then
		for index = 1, #centers do
			local nextIndex = index % #centers + 1
			if nextIndex ~= index then
				table.insert(corridors, { a = centers[index], b = centers[nextIndex] })
			end
		end
		for index = 2, #centers do
			table.insert(corridors, { a = centers[index], b = centers[1] })
		end
	end

	-- Places a road network's controlled junctions: roadside things keep clear of their sight lines.
	local controlled = {}
	if roads and roads.nodes then
		for _, node in ipairs(roads.nodes) do
			if node.control and node.position then
				table.insert(controlled, node.position)
			end
		end
	end

	-- A random point on open ground between the towns.
	local function randomPoint(edge)
		local angle = rand(0, math.pi * 2)
		local distance = math.sqrt(rng:NextNumber()) * limit * (edge or 1)
		return math.cos(angle) * distance, math.sin(angle) * distance
	end

	-- Whether the ground within `r` of (x, z) is steady enough to stand something on, and if so how
	-- far it falls below `y` there (which the builders sink trunks and rocks by). Four samples on the
	-- diagonals; a crater rim or a hill's rock cap can drop studs within a trunk's width.
	local function steady(x, z, y, r, maxRise)
		local low, high = y, y
		for k = 0, 3 do
			local angle = k * math.pi / 2 + math.pi / 4
			local gy = sample(x + math.cos(angle) * r, z + math.sin(angle) * r)
			if not gy then
				return false
			end
			low, high = math.min(low, gy), math.max(high, gy)
		end
		if high - low > maxRise then
			return false
		end
		footDrop = y - low
		return true
	end

	-- Budget shares, cumulative: each phase may spend up to this fraction of the whole budget
	-- including what the phases before it spent. Shelters go first because they are the cover.
	local SHARE = { routes = 0.10, roadside = 0.13, shelters = 0.24, woods = 0.58, singles = 0.76, lines = 0.82, orchards = 0.86,
		grass = 0.93, meadows = 0.97 }

	-- 1. Shelters spaced along the routes between towns, alternating sides, so cover is never far
	-- off the road.
	local SPACING = 210
	for _, corridor in ipairs(corridors) do
		if overBudget(SHARE.routes) then
			break
		end
		local a = Vector3.new(corridor.a.X, 0, corridor.a.Z)
		local b = Vector3.new(corridor.b.X, 0, corridor.b.Z)
		local length = (b - a).Magnitude
		if length > 120 then
			local along = (b - a).Unit
			local side = Vector3.new(-along.Z, 0, along.X)
			local sign = chance(0.5) and 1 or -1
			local t = rand(40, SPACING * 0.6)
			while t < length - 40 do
				local base = a + along * t
				if townFactor(base.X, base.Z) > 0.25 then
					for _ = 1, 6 do
						local offset = rand(48, 105)
						local at = base + along * rand(-45, 45) + side * sign * offset
						local kind = weighted(profile.shelters)
						local facing = chance(0.5) and -side * sign or side * sign
						if welcome(at.X, at.Z, 0.5) and placeShelter(kind, at.X, at.Z, yawToward(facing) + rand(-0.35, 0.35)) then
							break
						end
					end
					sign = -sign
				end
				t += SPACING * rand(0.85, 1.2)
			end
		end
	end

	-- 2. Bus shelters on the verges of a real road network, clear of junction controls and bridges.
	if roads and roads.edges then
		-- The road's ground is graded flat from its centre line out past its shoulders; its corridor claim
		-- reaches further still. A shelter belongs on that flat verge, which means inside the claim of the
		-- road it serves (passed to placeShelter as the claim to ignore).
		local verge = (roads.Width or 18) / 2 + 7
		for _, corridor in ipairs(corridors) do
			if overBudget(SHARE.roadside) then
				break
			end
			local edge = corridor.edge or {}
			local from, to = corridor.a, corridor.b
			local length = edge.length or (to - from).Magnitude
			if length > 200 and chance(0.45) then
				local along = Vector3.new(to.X - from.X, 0, to.Z - from.Z).Unit
				for _ = 1, 4 do
					local s = rand(70, length - 70)
					local onBridge = false
					for _, span in ipairs(edge.bridges or {}) do
						-- RoadNetwork spans a bridge as { s0, s1 } studs along the edge (it names them s0/s1).
						local from0, to0 = span.s0 or span[1], span.s1 or span[2]
						if from0 and to0 and s > from0 - 40 and s < to0 + 40 then
							onBridge = true
						end
					end
					local base = from + along * s
					local nearControl = false
					for _, position in ipairs(controlled) do
						if (Vector3.new(position.X, 0, position.Z) - Vector3.new(base.X, 0, base.Z)).Magnitude < 90 then
							nearControl = true
						end
					end
					if not onBridge and not nearControl then
						local sideSign = chance(0.5) and 1 or -1
						local side = Vector3.new(-along.Z, 0, along.X) * sideSign
						-- The shelter's back to the bank, its open side to the road, on the flat verge.
						local at = base + side * verge
						-- Open side toward the road.
						if placeShelter("busShelter", at.X, at.Z, yawToward(-side), edge.claim) then
							break
						end
					end
				end
			end
		end
	end
	task.wait()

	-- 3. More shelters out in the open, before the woods take the ground.
	local wantedShelters = math.floor(20 * area * (profile.shelterScale or 1) + 0.5)
	local placedShelters = 0
	for _ = 1, wantedShelters * 12 do
		if placedShelters >= wantedShelters or overBudget(SHARE.shelters) then
			break
		end
		local x, z = randomPoint()
		if welcome(x, z, 0.5) and placeShelter(weighted(profile.shelters), x, z) then
			placedShelters += 1
		end
	end
	task.wait()

	----------------------------------------------------------------------------
	-- Trees and ground cover
	----------------------------------------------------------------------------

	local groundColor = { tuft = profile.tuft or GRASS_TUFT }

	local function undergrowthAt(parent, x, z, kind)
		local y, material = sample(x, z)
		if not y or BARE[material] then
			return false
		end
		local at = Vector3.new(x, y, z)
		local s = rand(0.8, 1.25)
		-- Ankle-to-knee foliage casts no shadow: at this size a cast shadow is a grey smear on the
		-- ground rather than the shape of a fern, and there are more of these parts in a build than
		-- of anything else. Shrubs are the exception -- they are chest-high cover, and a player reads
		-- cover by its shadow.
		noShadow = kind ~= "shrub"
		if kind == "fern" then
			fern(parent, at, s)
		elseif kind == "flowers" then
			flowers(parent, at, s, FLOWER_SETS[profile.flowers] or FLOWER_SETS.meadow)
		elseif kind == "mushrooms" then
			mushrooms(parent, at, s)
		elseif kind == "shrub" then
			shrub(parent, at, s, profile.shrubColor)
		else
			local color = material == Enum.Material.Snow and rgb(170, 170, 150) or groundColor.tuft
			tuft(parent, at, s, color)
		end
		noShadow = false
		counts.undergrowth += 1
		return true
	end

	-- Solid pieces on the ground between things: how far each reaches, how steady its ground must be
	-- (the radius sampled and the most it may fall across it), and the builder.
	local CLUTTER = {
		log = { reach = 7.5, footing = 4, rise = 3.5 },
		stump = { reach = 4.5, footing = 3, rise = 2.5 },
		boulder = { reach = 5, footing = 4.2, rise = 1.6 },
		cairn = { reach = 3, footing = 2, rise = 1.5 },
		picnic = { reach = 5.5, footing = 3.5, rise = 1.4 },
	}
	local function clutterAt(parent, kind, at, material)
		snowCover = material == Enum.Material.Snow
		local rock = profile.rock
		if kind == "log" then
			local angle = rand(0, math.pi * 2)
			fallenLog(parent, at, rand(0.8, 1.1), Vector3.new(math.cos(angle), 0, math.sin(angle)), profile.logColor)
		elseif kind == "stump" then
			stump(parent, at, rand(0.9, 1.2))
		elseif kind == "cairn" then
			cairn(parent, at, rand(0.9, 1.25), rock.color, rock.material)
		elseif kind == "picnic" then
			picnicTable(parent, at, rand(0, math.pi * 2))
		else
			boulder(parent, at, rand(0.75, 1.15), rock.color, rock.material, rock.moss)
		end
		snowCover = false
		footDrop = 0
		count(kind)
	end

	-- A stand of trees round (cx, cz) of radius R. Trees are spaced against each other here and only
	-- claimed once the stand is finished, so they can grow closer than separate props would.
	local function woods(cx, cz, R)
		local m = named("Woods")
		local dominant = weighted(profile.trees)
		local scaleBase = profile.treeScale or 1

		-- A clearing in the middle, sometimes, with somebody's camp in it.
		local clearing = nil
		if chance(0.45) then
			local kind = weighted(profile.clearing)
			if placeShelter(kind, cx, cz) then
				local spec = SHELTERS[kind]
				clearing = math.sqrt(spec.halfX ^ 2 + spec.halfZ ^ 2) + 4
			end
		end
		-- Or a glade: where no camp went, the canopy is broken anyway and long grass grows in the light.
		if not clearing and chance(0.5) then
			clearing = rand(11, 17)
			local gladeColor = (profile.tuft or GRASS_TUFT):Lerp(rgb(126, 176, 84), 0.3)
			paintGrass(cx, cz, clearing)
			for _ = 1, rng:NextInteger(4, 6) do
				local r = clearing * 0.8 * math.sqrt(rng:NextNumber())
				local angle = rand(0, math.pi * 2)
				local gx, gz = cx + math.cos(angle) * r, cz + math.sin(angle) * r
				local gy, gmaterial = sample(gx, gz)
				if gy and not BARE[gmaterial] then
					grassClump(m, Vector3.new(gx, gy, gz), rand(0.9, 1.3), gladeColor)
				end
			end
		end

		local planted = {}
		local attempts = math.floor(R * R / 26)
		for _ = 1, attempts do
			if overBudget(SHARE.woods - 0.04) then
				break
			end
			local r = R * math.sqrt(rng:NextNumber())
			local angle = rand(0, math.pi * 2)
			local x, z = cx + math.cos(angle) * r, cz + math.sin(angle) * r
			-- Thinner toward the edge.
			if (not clearing or r > clearing + 6) and rng:NextNumber() > (r / R) ^ 3 * 0.55 then
				local y, material = sample(x, z)
				local kind, snowy = nil, false
				if y then
					kind, snowy = treeKindFor(material, chance(0.62) and dominant or nil)
				end
				if kind then
					local s = rand(0.85, 1.25) * scaleBase
					local reach = TREES[kind].reach * s
					local fits = true
					for _, other in ipairs(planted) do
						local dx, dz = other.x - x, other.z - z
						if dx * dx + dz * dz < ((other.reach + reach) * 0.46) ^ 2 then
							fits = false
							break
						end
					end
					if fits and open(x, z, reach + 4) and welcome(x, z, 0.7) and steady(x, z, y, 2.6, 3) then
						TREES[kind].build(m, Vector3.new(x, y, z), s, snowy)
						footDrop = 0
						table.insert(planted, { x = x, z = z, reach = reach })
						counts.trees += 1
						count(kind)
					end
				end
			end
		end

		-- The floor: undergrowth between the trunks, and a few logs, stumps and rocks.
		local trunkClear = 2.6
		local function clearOfTrunks(x, z, radiusNeeded)
			for _, tree in ipairs(planted) do
				local dx, dz = tree.x - x, tree.z - z
				if dx * dx + dz * dz < (radiusNeeded + trunkClear) ^ 2 then
					return false
				end
			end
			return true
		end
		local solids = {}
		for _ = 1, math.floor(#planted * 0.35) + 1 do
			if overBudget(SHARE.woods - 0.02) then
				break
			end
			local r = R * math.sqrt(rng:NextNumber())
			local angle = rand(0, math.pi * 2)
			local x, z = cx + math.cos(angle) * r, cz + math.sin(angle) * r
			local kind = weighted(profile.clutter)
			local spec = CLUTTER[kind]
			local halfLength = spec.reach
			local fits = clearOfTrunks(x, z, halfLength) and open(x, z, halfLength + 1)
			for _, other in ipairs(solids) do
				if (Vector2.new(other.x - x, other.z - z)).Magnitude < other.r + halfLength + 1 then
					fits = false
				end
			end
			local y, material = sample(x, z)
			if fits and y and not BARE[material] and steady(x, z, y, spec.footing, spec.rise) then
				clutterAt(m, kind, Vector3.new(x, y, z), material)
				table.insert(solids, { x = x, z = z, r = halfLength })
			end
		end
		for _ = 1, math.floor(#planted * 1.2) do
			if overBudget(SHARE.woods) then
				break
			end
			local r = R * 1.05 * math.sqrt(rng:NextNumber())
			local angle = rand(0, math.pi * 2)
			local x, z = cx + math.cos(angle) * r, cz + math.sin(angle) * r
			if clearOfTrunks(x, z, 0.5) and (not clearing or r > clearing) and open(x, z, 1.5) then
				local fits = true
				for _, other in ipairs(solids) do
					if (Vector2.new(other.x - x, other.z - z)).Magnitude < other.r + 1 then
						fits = false
						break
					end
				end
				if fits then
					undergrowthAt(m, x, z, weighted(profile.undergrowth))
				end
			end
		end

		for _, tree in ipairs(planted) do
			space:AddCircle(tree.x, tree.z, tree.reach)
		end
		for _, solid in ipairs(solids) do
			space:AddCircle(solid.x, solid.z, solid.r)
		end
		if #m:GetChildren() == 0 then
			m:Destroy()
		else
			table.insert(woodsSpots, { x = cx, z = cz, r = R })
		end
		return #planted
	end

	-- 4. Woods, placed where there's room for a real stand rather than squeezed in round the props.
	local wantedWoods = math.max(4, math.floor(40 * area * profile.woods + 0.5))
	local builtWoods = 0
	for _ = 1, wantedWoods * 12 do
		if builtWoods >= wantedWoods or overBudget(SHARE.woods - 0.06) then
			break
		end
		local x, z = randomPoint()
		local R = rand(40, 78)
		if open(x, z, 22) and townFactor(x, z) > 0.4 then
			-- Enough of the ground around free?
			local free = 0
			for k = 1, 8 do
				local angle = k / 8 * math.pi * 2
				if open(x + math.cos(angle) * R * 0.7, z + math.sin(angle) * R * 0.7, 8) then
					free += 1
				end
			end
			if free >= 6 then
				woods(x, z, R)
				builtWoods += 1
				task.wait()
			end
		end
	end

	-- 5. Single trees, small groups and ground clutter between everything else.
	local singles = math.floor(460 * area * profile.scattered)
	local singlesModel = named("Trees")
	local clutterModel = named("Clutter")
	for index = 1, singles do
		if overBudget(SHARE.singles) then
			break
		end
		local x, z = randomPoint()
		local y, material = sample(x, z)
		if y and welcome(x, z) then
			local kind, snowy = treeKindFor(material)
			if kind then
				local s = rand(0.8, 1.3) * (profile.treeScale or 1)
				local reach = TREES[kind].reach * s
				if open(x, z, reach + 4) and steady(x, z, y, 2.6, 3) then
					space:AddCircle(x, z, reach)
					TREES[kind].build(singlesModel, Vector3.new(x, y, z), s, snowy)
					footDrop = 0
					counts.trees += 1
					count(kind)
					-- A little undergrowth at its foot.
					-- Inside the tree's own claim (reach), which was free of everything before it went down.
					for _ = 1, rng:NextInteger(1, 3) do
						local angle = rand(0, math.pi * 2)
						local d = rand(math.min(3, reach * 0.5), reach * 0.8)
						local ux, uz = x + math.cos(angle) * d, z + math.sin(angle) * d
						undergrowthAt(singlesModel, ux, uz, weighted(profile.undergrowth))
					end
				end
			end
		end
		if index % 3 == 0 then
			local cx, cz = randomPoint()
			local kind = weighted(profile.clutter)
			local spec = CLUTTER[kind]
			local cy, cmaterial = sample(cx, cz)
			if cy and not BARE[cmaterial] and welcome(cx, cz) and open(cx, cz, spec.reach + 1) and steady(cx, cz, cy, spec.footing, spec.rise) then
				space:AddCircle(cx, cz, spec.reach)
				clutterAt(clutterModel, kind, Vector3.new(cx, cy, cz), cmaterial)
			end
		end
		if index % 40 == 0 then
			task.wait()
		end
	end

	-- Hedgerows and dry-stone walls: long, low lines of cover across the fields.
	local function linear(kind, wanted)
		for _ = 1, wanted * 8 do
			if wanted <= 0 or overBudget(SHARE.lines) then
				break
			end
			local x, z = randomPoint(0.95)
			local length = rand(26, 52)
			local angle = rand(0, math.pi)
			local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local a = Vector3.new(x, 0, z) - direction * length / 2
			local b = Vector3.new(x, 0, z) + direction * length / 2
			local ok = welcome(x, z)
			local step = kind == "hedge" and 3.2 or 3.8
			local points = {}
			if ok then
				for k = 0, math.floor(length / step) do
					local p = a + direction * (k * step)
					local y, material = sample(p.X, p.Z)
					if not y or BARE[material] or not open(p.X, p.Z, 4.5) then
						ok = false
						break
					end
					table.insert(points, Vector3.new(p.X, y, p.Z))
				end
			end
			if ok and #points >= 6 then
				space:AddStrip(a, b, 4)
				local m = named(kind == "hedge" and "Hedgerow" or "StoneWall")
				local gap = kind == "hedge" and chance(0.5) and rng:NextInteger(3, #points - 3) or nil
				local lastHeight = 0
				for k, p in ipairs(points) do
					if kind == "hedge" then
						if not gap or (k ~= gap and k ~= gap + 1) then
							local size = rand(5, 6.6)
							ball(m, "Hedge", p + Vector3.new(0, size * 0.32, 0), size, pick(OAK_LEAVES):Lerp(rgb(0, 0, 0), 0.08), Enum.Material.Grass)
						end
					else
						-- Blocks alternate in thickness and step in height, and each settles a few degrees
						-- the opposite way to the last. Height alone can't keep two tops out of one plane
						-- once the ground under them differs, but opposite tilts can.
						local height = rand(2.4, 3.4)
						if math.abs(height - lastHeight) < 0.25 then
							height += 0.4
						end
						lastHeight = height
						local thickness = k % 2 == 0 and 2.4 or 2.8
						local lean = (k % 2 == 0 and 1 or -1) * rand(0.04, 0.07)
						local stone = pick(STONES)
						-- Footed well down: the ground under a block's ends can sit lower than under its middle.
						-- Reaching down to the lower of its neighbours, so a block spanning a dip has no daylight under it.
					local drop = math.max(points[k - 1] and (p.Y - points[k - 1].Y) or 0, points[k + 1] and (p.Y - points[k + 1].Y) or 0, 0)
					block(m, "StoneWall", Vector3.new(step + 0.3, height + 1.8 + drop, thickness),
							CFrame.lookAt(p, p + direction) * CFrame.Angles(0, math.pi / 2, 0) * CFrame.new(0, height / 2 - 0.9 - drop / 2, 0)
								* CFrame.Angles(lean, rand(-0.04, 0.04), rand(-0.03, 0.03)),
							stone, Enum.Material.Cobblestone)
					end
				end
				count(kind)
				wanted -= 1
			end
		end
	end
	linear("hedge", math.floor(8 * area * (profile.hedgerows or 0) + 0.5))
	linear("wall", math.floor(6 * area * (profile.stoneWalls or 0) + 0.5))

	-- Orchards on farmland: apple trees in rows.
	local wantedOrchards = profile.orchards and math.max(1, math.floor(2 * area * profile.orchards + 0.5)) or 0
	for _ = 1, wantedOrchards * 20 do
		if wantedOrchards <= 0 or overBudget(SHARE.orchards) then
			break
		end
		local x, z = randomPoint()
		local rows, perRow, gap = rng:NextInteger(3, 4), rng:NextInteger(4, 5), 17
		local halfX, halfZ = (perRow - 1) * gap / 2 + 9, (rows - 1) * gap / 2 + 9
		local yaw = rand(0, math.pi)
		if welcome(x, z) and open(x, z, math.sqrt(halfX ^ 2 + halfZ ^ 2)) then
			local frame = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
			local low, high = math.huge, -math.huge
			local ok = true
			for _, s in ipairs(SAMPLES) do
				local w = frame * CFrame.new(s[1] * halfX, 0, s[2] * halfZ)
				local y, material = sample(w.X, w.Z)
				if not y or BARE[material] then
					ok = false
					break
				end
				low, high = math.min(low, y), math.max(high, y)
			end
			if ok and high - low < 8 then
				space:AddRect(x, z, halfX, halfZ, yaw)
				local m = named("Orchard")
				for row = 1, rows do
					for col = 1, perRow do
						local at = frame * CFrame.new((col - (perRow + 1) / 2) * gap + rand(-1, 1), 0, (row - (rows + 1) / 2) * gap + rand(-1, 1))
						local y = sample(at.X, at.Z)
						if y and steady(at.X, at.Z, y, 2.6, 4) then
							appleTree(m, Vector3.new(at.X, y, at.Z), rand(0.9, 1.1))
							footDrop = 0
							counts.trees += 1
							count("apple")
						end
					end
				end
				-- Windfalls and a few flowers between the rows.
				for _ = 1, rows * 2 do
					local at = frame * CFrame.new(rand(-halfX + 4, halfX - 4), 0, (rng:NextInteger(1, rows - 1) - rows / 2) * gap)
					undergrowthAt(m, at.X, at.Z, chance(0.5) and "flowers" or "tuft")
				end
				count("orchard")
				wantedOrchards -= 1
			end
		end
	end
	task.wait()

	-- 6. Long grass, in the places it reads as deliberate rather than as a lawn over the whole map:
	-- round the skirts of the woods, along the river banks, and beside the shelters. It claims
	-- nothing and stops nothing -- it's cover for the eye only.
	do
		local grassColor = (profile.tuft or GRASS_TUFT):Lerp(rgb(126, 176, 84), 0.3)
		local grassModel = named("Grass")
		local function patch(x, z, spread)
			if overBudget(SHARE.grass) then
				return false
			end
			local put = 0
			for _ = 1, rng:NextInteger(4, 7) do
				local r = spread * math.sqrt(rng:NextNumber())
				local angle = rand(0, math.pi * 2)
				local px, pz = x + math.cos(angle) * r, z + math.sin(angle) * r
				local y, material = sample(px, pz)
				if y and not BARE[material] and townFactor(px, pz) > 0 then
					grassClump(grassModel, Vector3.new(px, y, pz), rand(0.85, 1.25), grassColor)
					put += 1
				end
			end
			if put > 0 then
				count("grass")
				paintGrass(x, z, spread + 4)
			end
			return true
		end
		-- The skirt of each stand, where the canopy thins and the light gets in.
		for _, stand in ipairs(woodsSpots) do
			for _ = 1, rng:NextInteger(2, 4) do
				local angle = rand(0, math.pi * 2)
				local r = stand.r * rand(0.92, 1.18)
				if not patch(stand.x + math.cos(angle) * r, stand.z + math.sin(angle) * r, rand(7, 12)) then
					break
				end
			end
		end
		-- Both banks of the river, just past its sand beach (MapTerrain's RIVER_BEACH_OUT is width / 2 + 14).
		local river = ctx.river
		for index = 1, river and #river.points - 1 or 0 do
			local a, b = river.points[index], river.points[index + 1]
			local along = (b - a)
			local length = along.Magnitude
			if length > 1 then
				along = along.Unit
				local side = Vector3.new(-along.Z, 0, along.X)
				local step = 44
				for travelled = step / 2, length, step do
					local at = a + along * travelled
					local offset = (river.width or 34) / 2 + rand(16, 26)
					local sign = chance(0.5) and 1 or -1
					if not patch(at.X + side.X * offset * sign, at.Z + side.Z * offset * sign, rand(6, 11)) then
						break
					end
				end
			end
		end
		-- And where somebody camps: long grass right up to the walls.
		for _, at in ipairs(shelterSpots) do
			local angle = rand(0, math.pi * 2)
			local r = rand(13, 19)
			patch(at.X + math.cos(angle) * r, at.Z + math.sin(angle) * r, rand(5, 9))
		end
		if #grassModel:GetChildren() == 0 then
			grassModel:Destroy()
		end
	end
	task.wait()

	-- 7. Meadows and scattered ground cover last: they claim nothing, so nothing waits on them.
	local wantedMeadows = math.floor(20 * area * (profile.meadows or 0) + 0.5)
	for _ = 1, wantedMeadows * 6 do
		if wantedMeadows <= 0 or overBudget(SHARE.meadows) then
			break
		end
		local x, z = randomPoint()
		local R = rand(22, 42)
		if welcome(x, z) and open(x, z, R * 0.5) then
			local m = named("Meadow")
			for _ = 1, rng:NextInteger(9, 16) do
				local r = R * math.sqrt(rng:NextNumber())
				local angle = rand(0, math.pi * 2)
				local ux, uz = x + math.cos(angle) * r, z + math.sin(angle) * r
				if open(ux, uz, 1.5) then
					undergrowthAt(m, ux, uz, chance(0.7) and "flowers" or "tuft")
				end
			end
			if #m:GetChildren() == 0 then
				m:Destroy()
			else
				count("meadow")
			end
			wantedMeadows -= 1
		end
	end

	local groundModel = named("GroundCover")
	for index = 1, math.floor(380 * area * (profile.coverScale or 1)) do
		if overBudget(1) then
			break
		end
		local x, z = randomPoint()
		if welcome(x, z) and open(x, z, 1.5) then
			undergrowthAt(groundModel, x, z, weighted(profile.undergrowth))
		end
		if index % 90 == 0 then
			task.wait()
		end
	end

	for _, child in ipairs(root:GetChildren()) do
		if #child:GetChildren() == 0 then
			child:Destroy()
		end
	end

	-- Named against the share table, so the report reads "woods(0.52) x431" rather than a number.
	local cappedAt = {}
	for share, hits in pairs(capped) do
		local name, nearest = "?", math.huge
		for phase, value in pairs(SHARE) do
			if math.abs(value - share) < nearest then
				name, nearest = phase, math.abs(value - share)
			end
		end
		table.insert(cappedAt, { phase = name, share = share, hits = hits })
	end
	table.sort(cappedAt, function(a, b)
		return a.share < b.share
	end)

	sampler = nil
	autumnShare, snowCover, footDrop = 0, false, 0
	return {
		model = root,
		parts = partCount,
		budget = budget,
		seconds = (DateTime.now().UnixTimestampMillis - started) / 1000,
		counts = counts,
		paintedPatches = paintedPatches,
		cappedAt = cappedAt,
		vetoed = vetoed,
		plannedRoutes = plannedRoutes,
		corridors = #corridors,
	}
end

return MapWilds
