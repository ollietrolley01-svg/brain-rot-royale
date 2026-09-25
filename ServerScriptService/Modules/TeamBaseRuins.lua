-- The ruined outpost each team spawns in (Oliver, 2026-09-24: "design a ruined base with very high
-- quality for both team spawns so that all the item chests and cars aren't just sitting in random
-- fields").
--
--   TeamBaseRuins.Build(baseCFrame, teamColor, mapInfo, seed)
--       -> { model, pads = {CFrame...}, chestSpots = {CFrame...}, vehicleBays = {CFrame...},
--            lootSpots = {CFrame...}, names = { chests = {...}, bays = {...} }, frame, height }
--   TeamBaseRuins.Layout(frame, teamColor, seed) -> model, info    the geometry alone, no terrain
--   TeamBaseRuins.SiteCost(site, mapInfo) -> cost | nil, reason    for choosing where a base goes
--   TeamBaseRuins.ClearSite(site, map)                             scenery out of the footprint
--
-- `baseCFrame` is the base's centre on the ground, LookVector toward the arena centre. Everything
-- is laid out in that frame: -Z is the front (the gate and the main breach face the fight), +X is
-- the vehicle side. Both teams' bases are the same build turned to face the middle, so neither side
-- starts with a better compound; only the team paint differs, and every part that carries it is
-- named Team*. `seed` drives the wear (wall heights, rubble, which panels are scorched): the same
-- seed builds the same ruin to the stud, and ModeTeams hands both bases one seed per match.
--
-- THE LAYOUT (local studs; the compound is 92 x 84, walls at x = +/-45 and z = +/-41):
--
--          front (-Z, toward the arena)
--   +--------[breach]-------+ post ========= gate gantry ========= post
--   | tower      sandbags   |   bay 1      bay 2      bay 3  drums |
--   |   lean-to     flag    |   (camo net, noses to the gate)     |
--   |       MG nest   ruin  | barriers                         post
--  [breach]                 |  fallen lamp     bay 4 ->          E |
--   |  generator   crates   |  work lamp       bay 5 ->   (net)  gate
--   +---- BUNKER (spawn) ---+  workbench       bay 6 ->          |
--   | 8 pads under the roof |---------- SUPPLY ROOM ---------------|
--   | collapsed corner      |  crates   RotVat   4 chest alcoves    |
--   | armoury    terminal   |                                      |
--   +-----------------------+--------------------------------------+
--          back (+Z)
--
-- WHAT BREAKS (DestructibleService). The perimeter, the supply room's walls and the courtyard ruin
-- are parts named "Wall" (by name, HEALTH.Wall, with DestructibleHealth for the thick concrete),
-- and their broken tops, rebar, brick patches, soot and paint are trim (no collision, no query)
-- touching only their own panel, so a panel takes its dressing with it. Sandbag lines, crate
-- stacks, barriers and props are tagged pools ("Sandbags:nest" and so on); the watchtower is one
-- tagged Model, so it comes down whole. NEVER breaks: the bunker (a Model named "Spawn", which
-- DestructibleService.Never refuses outright, and tagged false as well), every floor ("Foundation"
-- and "Paving", both in Never), the pillars and beams that carry the supply room's roof (so no roof
-- is ever left in the air), the gate posts and gantry, and the rubble.
--
-- WHAT IS PROVED OFFLINE (tools/team_base_ruins_check.py runs this module's real source and the
-- real ZFight): no coplanar faces at source or after the pass, nothing floating, every cylinder
-- round with its length on X, doorways at least 4 wide and 7 tall, every chest spot and bay
-- reachable on foot from every pad (R15: 2 wide, 5.2 tall, steps up to 1.5), each bay level with
-- nothing queryable over it and a straight, clear drive out through the gate, the destructible
-- rules through DestructibleService's own KeyOf, both bases identical, the part budget, and Build on a
-- hillside: flush (no plinth), the ground round it graded (1 in 3, the gate ramps 1 in 8), scenery on
-- moved ground cleared, a road's ground untouched, all decided from the voxels while terrain rays are
-- stale. What it cannot prove is how it looks: tools/team_base_ruins_gallery.lua is the render for that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))

local TeamBaseRuins = {}

-- The compound's footprint (X across, Z deep) and the flat ground kept round it. The rubble at the
-- breaches lies inside the margin, so it is on the flattened pad too.
-- The perimeter's centre lines are at x = +/-WX and z = +/-WZ (Oliver, 2026-09-24: "the bases need to be
-- bigger to accommodate all the players of each team": sized for 25 a side, a full 50-player server).
local WX, WZ = 66, 54
TeamBaseRuins.Footprint = Vector3.new(2 * (WX + 1), 0, 2 * (WZ + 1))
TeamBaseRuins.Margin = 4
-- Distinct things built in the footprint that ClearSite removes whole; bigger ones stay, and
-- SiteCost counts them against a site.
TeamBaseRuins.ClearableSpan = 70
-- Named top-level map models ClearSite never touches: taking a road or river part out would leave
-- a hole in something that runs far outside the base.
local KEEP = { Roads = true, River = true, Ziplines = true, TeamBaseVehicles = true }
-- How far past the footprint and margin FlattenPad can move the ground: its graded edge (24 at most)
-- and the two voxel columns it keeps flat past the margin.
local FLATTEN_REACH = 24 + 8
-- The ground under a levelled site, read back from the voxels, must be within LEVEL_SLACK of the pad
-- height everywhere under the footprint; a site that is not is refused (Build returns nil and
-- ModeTeams tries the next site). It used to be read by RAYCAST, and that is why the compounds stood
-- on plinths (Oliver, 2026-09-24: "the team bases are on a platform that's raised up"): a terrain
-- raycast straight after Terrain:WriteVoxels still hits the ground as it was BEFORE the write.
-- Measured in Studio on the galleries' map (RotRidge, seed 101): both pads were written (PadAt
-- 16.54 and 36.06, the voxels flat under the whole footprint) while the rays read 2.75..30.53 and
-- 29.04..43.47, the untouched slopes (whose middles ARE those pad heights), so both compounds went
-- up on plinths 28.8 and 15.4 deep over ground that was really flat. Nothing here reads the terrain
-- by raycast any more: the voxels are the truth (MapTerrain reads them the same way).
local LEVEL_SLACK = 0.35
-- THE GROUND ROUND THE COMPOUND. FlattenPad levels the footprint, the margin and two voxel columns
-- past it (8 studs), then blends back to the natural ground over at most 24 studs whatever the height
-- difference: on RotRidge's slopes that left a bank of 14 studs in 24, a 30-degree lip all round the
-- compound, with the vehicle gate opening onto it. So past the pad's flat edge the ground is held to a
-- grade (GradeSurroundings): never steeper than 1 in GRADE_BANK (33%, an easy walk), and in front of the two
-- vehicle gates, in a corridor as wide as the gate, 1 in GRADE_GATE (12.5%, a gentle
-- drive: VehicleDynamics' weakest climber, the rear-driven Sahur Van with traction 1.3, holds about
-- 33 degrees on grip alone, tools/bot_driving_sim.py drives bots up an 18% hill, and BotNav only
-- slows for a downhill steeper than 20%). Beside a gate corridor the ground climbs to meet the banks
-- at 1 in GRADE_BANK, a cutting (or an embankment) with sloped sides. Ground already inside the cone
-- is not touched. The floor meets the ground at the pad: the paving is 0.3 over it, a step of nothing.
-- (Banks were 1 in 4 at first: on RotRidge that cut hills down 30 studs and more a hundred studs out.)
local GRADE_BANK, GRADE_GATE = 3, 8
-- How far past the pad's flat the ground work reaches (a 17-stud difference is 136 studs of gate ramp at 1
-- in 8, and 51 of bank at 1 in 3). The ring at that distance is held as it stands, like a road or
-- anything else the work may not move, so the ground always meets what lies beyond it
-- (GradeSurroundings); SiteCost charges a site whose gates would need more ramp than this.
local GRADE_REACH = 136
-- The pad's flat, as FlattenPad leaves it: the footprint, the margin and two voxel columns (local
-- half-extents, X and Z).
local FLAT_X, FLAT_Z = WX + 1 + 4 + 8, WZ + 1 + 4 + 8
-- The motor pool's lanes: the front row's four side by side from LANE_X0 to LANE_X1 (out through the
-- gatehouse, -Z), the east row's three from EAST_Z0 to EAST_Z1 (out through the east gate, +X), each
-- LANE_PITCH wide: the biggest vehicle's width and 6 more. DRIVE_OUT is how far past the compound's
-- middle every lane is kept clear (tools/team_base_ruins_check.py sweeps it).
local LANE_PITCH = 15
local LANE_X0, LANE_X1 = 3, 3 + 4 * LANE_PITCH
local EAST_Z0, EAST_Z1 = 6.5, 6.5 + 3 * LANE_PITCH
local DRIVE_OUT = WX + 16
TeamBaseRuins.Lanes = { pitch = LANE_PITCH, front = { LANE_X0, LANE_X1 }, east = { EAST_Z0, EAST_Z1 }, driveOut = DRIVE_OUT }
-- Where the access road to the map's roads starts (TeamBaseRoads): the foot of the gatehouse's ramp,
-- in the middle of its lanes.
TeamBaseRuins.GateOut = Vector3.new((LANE_X0 + LANE_X1) / 2, 0, -(WZ + 0.8 + 3))
TeamBaseRuins.GateOutEast = Vector3.new(WX + 0.8 + 3, 0, (EAST_Z0 + EAST_Z1) / 2)
-- The two vehicle gates' corridors (local), for the ground work: a little wider than the lanes.
local GATE_FRONT = { LANE_X0 - 4, LANE_X1 + 4 }
local GATE_EAST = { EAST_Z0 - 4, EAST_Z1 + 4 }
-- Terrain voxels are 4 studs; MapTerrain draws the surface SurfaceLift over the filled volume.
local CELL = 4

-- Heights, local: the flattened ground is 0; the paving tiles' top; the bunker and supply floors.
local TILE_TOP = 0.3
local ROOM_FLOOR = 0.8
-- The foundation slab's top: under the paving (whose cracks show it), 0.1 clear of the ground so the
-- z-fight pass never takes it for a face lying on the terrain.
local FOUNDATION_TOP = 0.1
-- The underside of the main gate's gantry.
local GANTRY_Y = 12.5

--------------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------------

local rgb = Color3.fromRGB
local CONCRETE = rgb(150, 147, 140)
local CONCRETE_DARK = rgb(118, 116, 110)
local CONCRETE_LIGHT = rgb(170, 166, 156)
local BUNKER = rgb(128, 131, 120)
local BUNKER_DARK = rgb(98, 101, 92)
local PAVING = rgb(138, 134, 124)
local BRICK = rgb(146, 82, 62)
local BRICK_DARK = rgb(116, 64, 48)
local RUST = rgb(118, 70, 42)
local STEEL = rgb(92, 96, 100)
local STEEL_DARK = rgb(58, 61, 64)
local SAND = { rgb(186, 164, 120), rgb(170, 148, 104), rgb(158, 138, 98) }
local SOOT = rgb(34, 32, 30)
local WOOD = rgb(132, 98, 62)
local WOOD_DARK = rgb(96, 72, 48)
local OLIVE = rgb(84, 94, 58)
local NET = rgb(92, 102, 62)
local CANVAS = rgb(126, 118, 90)
local RUBBER = rgb(36, 36, 38)
local WHITE_PAINT = rgb(226, 222, 210)
local YELLOW_PAINT = rgb(222, 186, 64)
local ROT_GREEN = rgb(120, 255, 90)
local WARM = rgb(255, 190, 120)

local MAT = Enum.Material

--------------------------------------------------------------------------------
-- Part helpers
--------------------------------------------------------------------------------

-- The build in progress: its frame, its rng, the team colours and the lists it hands back. One at
-- a time; Layout never yields.
local B = nil

-- Plates on a face stand out by one of these, so two overlapping plates on one face never share a
-- plane (ZFight counts anything nearer than 0.045 as fighting): brick, team paint, soot.
local PROUD_BRICK, PROUD_PAINT, PROUD_SOOT = 0.12, 0.2, 0.28

local function put(parent, name, size, at, color, material, opts)
	local part = Instance.new(opts and opts.class or "Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = B.frame * at
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if opts then
		if opts.shape then
			part.Shape = opts.shape
		end
		if opts.trim then
			-- Dressing: nothing to bump into or shoot, and DestructibleService carries it off with the
			-- structure it touches.
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
		if opts.transparency then
			part.Transparency = opts.transparency
		end
		if opts.tag ~= nil then
			local tag = opts.tag
			-- A "Kind:id" pool is keyed map-wide by its string (DestructibleService), and both bases
			-- are built from one layout: without the site on the end, a shot at one team's sandbags
			-- counted toward the same sandbags at the other team's base.
			if type(tag) == "string" and string.find(tag, ":") then
				tag = tag .. "@" .. B.site
			end
			part:SetAttribute("Destructible", tag)
		end
		if opts.health then
			part:SetAttribute("DestructibleHealth", opts.health)
		end
	end
	part.Parent = parent
	return part
end

local TRIM = { trim = true }
local function trimWith(extra)
	local opts = { trim = true }
	for key, value in pairs(extra) do
		opts[key] = value
	end
	return opts
end

-- An axis-aligned box by its local extents.
local function box(parent, name, x0, x1, y0, y1, z0, z1, color, material, opts)
	return put(parent, name, Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, material, opts)
end

-- A cylinder's frame from end `a` to end `b`. Its length is its X axis (a Cylinder part's round
-- faces are on X), so a standing pole is turned, never sized (d, h, d).
local function rodFrame(a, b)
	local axis = (b - a).Unit
	local helper = math.abs(axis.Y) > 0.9 and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
	local zAxis = axis:Cross(helper).Unit
	local yAxis = zAxis:Cross(axis).Unit
	return CFrame.fromMatrix((a + b) / 2, axis, yAxis, zAxis)
end

local function rod(parent, name, a, b, diameter, color, material, opts)
	local o = { shape = Enum.PartType.Cylinder }
	if opts then
		for key, value in pairs(opts) do
			o[key] = value
		end
	end
	return put(parent, name, Vector3.new((b - a).Magnitude, diameter, diameter), rodFrame(a, b), color, material, o)
end

-- A disc flat against a face: `normal` points out of the face, the disc stands `proud` out of it.
local function disc(parent, name, centre, normal, proud, diameter, color, material, opts)
	return rod(parent, name, centre - normal * proud, centre + normal * proud, diameter, color, material, opts or TRIM)
end

-- A plate from `a` to `b` (its length on its own Z), `width` across and `thick` through, with its
-- width lying along `across` as near as the length allows.
local function plateBetween(parent, name, a, b, width, thick, color, material, opts)
	local along = (b - a).Unit
	local across = Vector3.new(1, 0, 0)
	if math.abs(along:Dot(across)) > 0.9 then
		across = Vector3.new(0, 0, 1)
	end
	local normal = across:Cross(along).Unit
	across = along:Cross(normal).Unit
	local frame = CFrame.fromMatrix((a + b) / 2, across, normal, -along)
	return put(parent, name, Vector3.new(width, thick, (b - a).Magnitude), frame, color, material, opts)
end

-- A plate on the face of an axis-aligned wall. `axis` is the face normal's axis ("x" or "z"), `at`
-- the face's coordinate on it and `side` which way it faces (+1 or -1); u0..u1 runs along the wall.
-- The plate is centred on the face, so it stands `proud` out and is buried as deep behind it.
local function facePlate(parent, name, axis, at, side, proud, u0, u1, y0, y1, color, material, opts)
	local c0, c1 = at - proud, at + proud
	if axis == "z" then
		return box(parent, name, u0, u1, y0, y1, c0, c1, color, material, opts or TRIM)
	end
	return box(parent, name, c0, c1, y0, y1, u0, u1, color, material, opts or TRIM)
end

local function mix(a, b, t)
	return a:Lerp(b, t)
end

local function light(parent, color, range, brightness)
	local lamp = Instance.new("PointLight")
	lamp.Color = color
	lamp.Range = range
	lamp.Brightness = brightness
	lamp.Shadows = false
	lamp.Parent = parent
	return lamp
end

-- A caged wall lamp on a face, with a warm light. `normal` points out of the face.
local function wallLamp(parent, face, normal, range)
	local up = Vector3.new(0, 1, 0)
	local base = put(parent, "LampBracket", Vector3.new(0.9, 0.5, 0.9),
		CFrame.new(face + normal * 0.2), STEEL_DARK, MAT.Metal, TRIM)
	local _ = base
	local bulb = put(parent, "LampBulb", Vector3.new(0.7, 0.7, 0.7), CFrame.new(face + normal * 0.75 - up * 0.1),
		WARM, MAT.Neon, trimWith({ shape = Enum.PartType.Ball }))
	rod(parent, "LampCage", face + normal * 0.35 + up * 0.35, face + normal * 1.12 + up * 0.35, 0.12, STEEL_DARK, MAT.Metal, TRIM)
	light(bulb, WARM, range, 1.3)
	return bulb
end

--------------------------------------------------------------------------------
-- Wear: rubble, rebar, sandbags
--------------------------------------------------------------------------------

local function rnd(a, b)
	return a + (b - a) * B.rng:NextNumber()
end

-- A tilt of 0.15 to 0.35 radians either way: never square, so no face of a chunk can lie in the
-- plane of a wall or a slab beside it.
local TILTS = { 0.16, 0.23, 0.3, 0.35 }
local function tipped()
	B.tilt = (B.tilt or 0) + 1
	return (B.rng:NextNumber() < 0.5 and -1 or 1) * (TILTS[B.tilt % #TILTS + 1] + rnd(-0.02, 0.02))
end

-- Every chunk of rubble is turned the golden fraction of a right angle on from the one before, across
-- the whole build (a box looks the same every 90 degrees, so that is the turn that counts), and its
-- tilts step through TILTS: chunks lying together, built one after another, never face the same way.
local GOLDEN = math.pi / 2 * (math.sqrt(5) - 1) / 2
local function nextTurn()
	B.turn = (B.turn or 0) + GOLDEN
	return B.turn
end

-- A heap of broken concrete round (cx, cz) on ground at `floor`. Every chunk is sunk by a fifth of
-- its height, so whatever it is turned to, its lowest corner is in the ground: a heap, never a hover.
local function rubble(parent, cx, cz, radius, count, floor, colors)
	colors = colors or { CONCRETE, CONCRETE_DARK, CONCRETE_LIGHT }
	-- No two chunks touch: each one's footprint circle keeps clear of every other chunk's in the build.
	-- Chunks lying into one another at random turns are the one thing here that could put two faces in
	-- one plane by chance, and a heap reads as a heap without them touching.
	B.stones = B.stones or {}
	for _ = 1, count do
		for _ = 1, 10 do
			local angle = rnd(0, math.pi * 2)
			local reach = radius * math.sqrt(B.rng:NextNumber())
			local near = 1 - reach / math.max(radius, 0.01)
			local size = Vector3.new(rnd(0.8, 1.4) + near * 0.9, rnd(0.5, 0.9) + near * 0.7, rnd(0.8, 1.4) + near * 0.8)
			local x, z = cx + math.cos(angle) * reach, cz + math.sin(angle) * reach
			local r = math.sqrt(size.X * size.X + size.Z * size.Z) / 2 + 0.2
			local clear = true
			for _, stone in ipairs(B.stones) do
				if (stone[1] - x) ^ 2 + (stone[2] - z) ^ 2 < (stone[3] + r + 0.05) ^ 2 then
					clear = false
					break
				end
			end
			if clear then
				table.insert(B.stones, { x, z, r })
				local at = CFrame.new(x, floor + size.Y * 0.2, z) * CFrame.Angles(0, nextTurn(), 0) * CFrame.Angles(tipped(), 0, tipped())
				put(parent, "Rubble", size, at, colors[B.rng:NextInteger(1, #colors)], MAT.Concrete)
				break
			end
		end
	end
end

-- A bar of rebar out of a broken top at `base` (buried 0.6 into it, below any broken lump on the same top), leaning a little.
local function rebar(parent, base, length, lean, heading)
	local dir = Vector3.new(math.sin(lean) * math.cos(heading), math.cos(lean), math.sin(lean) * math.sin(heading))
	rod(parent, "Rebar", base - dir * 0.6, base + dir * length, 0.16, RUST, MAT.CorrodedMetal, TRIM)
end

-- A line of sandbags from (x0, z0) to (x1, z1) along X or Z, `courses` high on ground at `floor`.
-- Bags in a course stand 0.06 apart and every other course is offset half a bag, so no two bags'
-- faces share a plane where they overlap; one pool per line (`tag`).
local BAG_LONG, BAG_HIGH, BAG_DEEP, BAG_GAP = 2.3, 0.78, 1.15, 0.06
local function sandbags(parent, tag, x0, z0, x1, z1, courses, floor)
	local alongX = math.abs(x1 - x0) >= math.abs(z1 - z0)
	local from, to = alongX and math.min(x0, x1) or math.min(z0, z1), alongX and math.max(x0, x1) or math.max(z0, z1)
	local across = alongX and z0 or x0
	local opts = { tag = "Sandbags:" .. tag }
	for course = 1, courses do
		local inset = (course % 2 == 0) and BAG_LONG / 2 or 0
		local length = to - from - inset * 2
		local count = math.max(1, math.floor((length + BAG_GAP) / (BAG_LONG + BAG_GAP) + 0.5))
		local bag = (length - (count - 1) * BAG_GAP) / count
		local y = floor + (course - 0.5) * BAG_HIGH
		for index = 1, count do
			local u = from + inset + (index - 0.5) * bag + (index - 1) * BAG_GAP
			local wobble = rnd(-0.07, 0.07)
			local yaw = rnd(-0.025, 0.025)
			local size = alongX and Vector3.new(bag, BAG_HIGH, BAG_DEEP) or Vector3.new(BAG_DEEP, BAG_HIGH, bag)
			local at = alongX and CFrame.new(u, y, across + wobble) or CFrame.new(across + wobble, y, u)
			put(parent, "Sandbag", size, at * CFrame.Angles(0, yaw, 0), SAND[B.rng:NextInteger(1, #SAND)], MAT.Fabric, opts)
		end
	end
end

--------------------------------------------------------------------------------
-- The team insignia
--------------------------------------------------------------------------------

-- The team's mark (Oliver, 2026-09-24: the round white-disc-and-dot emblems "read as eyes"): a
-- heater shield, square at the top and pointed at the foot, in a white border, with two chevrons
-- and a bar over them. Built flat against a face: `centre` on the face, `normal` out of it, `width`
-- across (the shield is as tall as it is wide). `field` fills the shield (the team's colour on a
-- neutral wall, dark on a team-coloured banner); the border and the marks are white. Every layer
-- stands INSIGNIA_STEP prouder than the one under it, so no two share a plane; the lowest is sunk
-- into the face, so the whole mark touches what it is painted on.
local INSIGNIA_STEP = 0.07
local function insignia(parent, centre, normal, width, field, opts)
	local up = Vector3.new(0, 1, 0)
	local right = up:Cross(normal).Unit
	local face = CFrame.fromMatrix(centre, right, up, normal)
	local thick = 0.12
	local options = opts and trimWith(opts) or TRIM
	local level = 0
	local function plate(name, sx, sy, u, v, angle, color, at)
		level = at or (level + 1)
		local front = 0.03 + level * INSIGNIA_STEP
		return put(parent, name, Vector3.new(sx, sy, thick), face * CFrame.new(u, v, front - thick / 2) * CFrame.Angles(0, 0, angle),
			color, MAT.SmoothPlastic, options)
	end
	local teamName = "TeamInsignia"
	local w = width
	local diamond = w / math.sqrt(2)
	-- The border (white), then the field inset from it: the foot a square turned on its corner, the
	-- top a plain rectangle over the diamond's upper half.
	plate("InsigniaBorder", diamond, diamond, 0, 0, math.pi / 4, WHITE_PAINT)
	plate("InsigniaBorder", w, w / 2, 0, w / 4, 0, WHITE_PAINT)
	local inner = w - w * 0.16
	plate(teamName, inner / math.sqrt(2), inner / math.sqrt(2), 0, 0.02 * w, math.pi / 4, field)
	plate(teamName, inner, w / 2 - w * 0.08, 0, w / 4 + 0.04 * w, 0, field)
	-- Two chevrons pointing up, and a bar over them.
	local length, bar = w * 0.36, w * 0.1
	local tilt = math.rad(34)
	for _, apex in ipairs({ 0.08 * w, -0.14 * w }) do
		local du, dv = math.cos(tilt) * length / 2, math.sin(tilt) * length / 2
		-- The marks all lie on the field: each chevron's two arms a step apart (they cross at the apex).
		plate("InsigniaChevron", length, bar, -du + bar * 0.3, apex - dv, tilt, WHITE_PAINT, 5)
		plate("InsigniaChevron", length, bar, du - bar * 0.3, apex - dv, -tilt, WHITE_PAINT, 6)
	end
	plate("InsigniaBar", w * 0.42, bar, 0, 0.3 * w, 0, WHITE_PAINT, 5)
end

-- A lit sign: a steel board on a face with the team's colour round a dark panel, the insignia in the
-- middle, a neon strip under it and a light. u0..u1 along the face (axis "x": along X, facing
-- `side` in Z; axis "z": along Z, facing `side` in X), y0..y1 up it.
local function litSign(parent, axis, at, side, u0, u1, y0, y1, range)
	local mid, cy = (u0 + u1) / 2, (y0 + y1) / 2
	-- facePlate names the face's NORMAL axis; `axis` here is the one the sign runs along.
	local normalAxis = axis == "x" and "z" or "x"
	local function onFace(proud, a, b, c, d, color, material, name)
		return facePlate(parent, name, normalAxis, at, side, proud, a, b, c, d, color, material, TRIM)
	end
	onFace(0.1, u0, u1, y0, y1, STEEL_DARK, MAT.Metal, "SignBoard")
	onFace(0.2, u0 + 0.25, u1 - 0.25, y0 + 0.25, y1 - 0.25, B.team, MAT.SmoothPlastic, "TeamSignPanel")
	onFace(0.3, u0 + 0.55, u1 - 0.55, y0 + 0.55, y1 - 0.55, SOOT, MAT.SmoothPlastic, "SignField")
	local glow = onFace(0.4, u0 + 0.8, u1 - 0.8, y0 + 0.62, y0 + 0.8, B.team, MAT.Neon, "TeamSignGlow")
	local normal = axis == "x" and Vector3.new(0, 0, side) or Vector3.new(side, 0, 0)
	local centre = axis == "x" and Vector3.new(mid, cy + 0.15, at + side * 0.38) or Vector3.new(at + side * 0.38, cy + 0.15, mid)
	insignia(parent, centre, normal, math.min(y1 - y0 - 0.9, (u1 - u0) * 0.4), B.team)
	-- Stencilled bars either side of the mark, like lettering seen from a distance.
	for _, s in ipairs({ -1, 1 }) do
		for row = 0, 1 do
			local a = mid + s * (y1 - y0) * 0.55
			local b = a + s * (u1 - u0) * 0.22
			local lo, hi = math.min(a, b), math.max(a, b)
			local y = cy + 0.25 - row * 0.8
			onFace(0.4, lo, hi, y, y + 0.36, WHITE_PAINT, MAT.SmoothPlastic, "SignLettering")
		end
	end
	light(glow, B.team:Lerp(WARM, 0.5), range or 18, 1.1)
end


--------------------------------------------------------------------------------
-- Walls
--------------------------------------------------------------------------------

-- One ruined panel: a "Wall" part from under the ground to `top`, running `axis` ("x" or "z") from
-- u0 to u1 with its centre line at `c` and `thick` through, plus its wear. `style`:
--   out        which side is outside (+1 / -1 on the other axis), for the team stripe
--   health     DestructibleHealth (nil: the Wall default)
--   color, material, stripe (paint the outer face), inStripe (and the inner), low (a broken stub
--   next to a gap), slopeUp (the height the panel beside a gap rises to), slopeToward (+1/-1: the
--   gap's end), brick (brick shows through the render), plain (no wear on top)
local function wallPanel(parent, axis, u0, u1, c, thick, top, style)
	local alongX = axis == "x"
	local half = thick / 2
	local mid = (u0 + u1) / 2
	local length = u1 - u0
	local color = style.color or CONCRETE
	local material = style.material or MAT.Concrete
	local name = style.name or "Wall"
	local wall
	if alongX then
		wall = box(parent, name, u0, u1, -1, top, c - half, c + half, color, material, { health = style.health })
	else
		wall = box(parent, name, c - half, c + half, -1, top, u0, u1, color, material, { health = style.health })
	end
	local faceAxis = alongX and "z" or "x"
	local inset = 0.5
	local function along(u, y, across)
		if alongX then
			return Vector3.new(u, y, c + across)
		end
		return Vector3.new(c + across, y, u)
	end

	-- A broken lump on the top, tipped along the wall; or, where the top held, barbed wire on posts.
	local lump = B.rng:NextNumber() < 0.55
	if not style.plain and not style.low and length > 3.2 and not lump and style.wire ~= false then
		local a, b = u0 + inset + 0.3, u1 - inset - 0.3
		for _, u in ipairs({ a, b }) do
			put(parent, "WirePost", Vector3.new(0.14, 1.4, 0.14), CFrame.new(along(u, top + 0.6, 0)), STEEL_DARK, MAT.Metal, TRIM)
		end
		for _, h in ipairs({ 0.75, 1.15 }) do
			rod(parent, "BarbedWire", along(a, top + h, 0), along(b, top + h, 0), 0.07, STEEL, MAT.Metal, TRIM)
		end
	elseif not style.plain and not style.low and length > 3.2 then
		local lumpLength = math.min(length - 1.6, rnd(1.4, 3.0))
		local tilt = rnd(-0.14, 0.14)
		local spare = (length - 2 * inset - lumpLength * math.cos(tilt) - 1.2 * math.abs(math.sin(tilt))) / 2
		local u = mid + (spare > 0 and rnd(-spare, spare) or 0)
		local size = alongX and Vector3.new(lumpLength, rnd(0.7, 1.2), thick * 0.85) or Vector3.new(thick * 0.85, rnd(0.7, 1.2), lumpLength)
		local rotation = alongX and CFrame.Angles(0, 0, tilt) or CFrame.Angles(tilt, 0, 0)
		put(parent, "BrokenTop", size, CFrame.new(along(u, top + size.Y * 0.3, 0)) * rotation, color, material, TRIM)
	end

	-- A broken slope down to the gap: a wedge on the stub whose tall end is away from the gap.
	if style.slopeUp and style.slopeUp > top + 0.8 and length > 2 then
		local rise = math.min(style.slopeUp - top, 3.6) * 0.85
		local run = length - 2 * inset
		local towardGap = style.slopeToward
		-- A WedgePart's tall face is its +Z; turn that away from the gap.
		local yaw
		if alongX then
			yaw = towardGap > 0 and -math.pi / 2 or math.pi / 2
		else
			yaw = towardGap > 0 and math.pi or 0
		end
		put(parent, "BrokenSlope", Vector3.new(thick * 0.8, rise, run),
			CFrame.new(along(mid, top + rise / 2 - 0.2, 0)) * CFrame.Angles(0, yaw, 0), color, material,
			trimWith({ class = "WedgePart" }))
	end

	-- Rebar out of the break.
	if not style.plain then
		local bars = style.low and 3 or B.rng:NextInteger(0, 2)
		-- Each bar in its own share of the break, so no two stand together.
		local from, share = u0 + inset + 0.3, (length - 2 * inset - 0.6) / math.max(bars, 1)
		for bar = 1, bars do
			local u = from + (bar - 0.5) * share + rnd(-0.2, 0.2) * math.min(1, share)
			rebar(parent, along(u, top, rnd(-half * 0.5, half * 0.5)), rnd(1.0, 2.3), rnd(0.05, 0.4), rnd(0, math.pi * 2))
		end
	end

	-- Along the panel, every plate's ends sit on a half-stud grid from the panel's start: brick at
	-- +0.2, the stripe at +0.35, soot at +0.45. Plates of two kinds overlap on one face, so their ends
	-- must never meet in one plane by chance; on the grid they are always 0.1 or more apart.
	local function span(offset, want)
		local steps = math.max(1, math.floor(math.min(want, length - 2 * inset - 0.5) / 0.5))
		local slots = math.floor((length - 2 * inset - 0.5 - steps * 0.5) / 0.5)
		local first = u0 + offset + 0.5 * (1 + (slots > 0 and B.rng:NextInteger(0, slots) or 0))
		return first, first + steps * 0.5
	end

	-- The render has come off: brick showing through, on one face or the other.
	if style.brick ~= false and (style.brick or B.rng:NextNumber() < 0.55) and top > 3.4 and length > 3 then
		local side = B.rng:NextNumber() < 0.5 and 1 or -1
		if style.bareInside and style.out then
			side = style.out
		end
		local a, b = span(0.2, rnd(2.0, 3.6))
		local w, u = b - a, (a + b) / 2
		-- Edges on a half-stud grid plus 0.2, a tenth clear of every stripe and soot edge (those sit on
		-- .0, .1 and .3/.4 of it), so no two plates' edges ever share a plane by chance.
		local y0 = math.floor(rnd(0.9, math.max(1.0, top - 3.0)) * 2) / 2 + 0.2
		local y1 = math.floor(math.min(top - 0.6, y0 + rnd(1.4, 2.6)) * 2) / 2 + 0.2
		if y1 > y0 + 0.6 then
			facePlate(parent, "BrickCourse", faceAxis, c + side * half, side, PROUD_BRICK, u - w / 2, u + w / 2, y0, y1,
				B.rng:NextNumber() < 0.5 and BRICK or BRICK_DARK, MAT.Brick)
		end
	end

	-- Soot from a blast: always beside a gap, now and then elsewhere (never where style.soot is false).
	if style.soot ~= false and (style.low or style.slopeUp or B.rng:NextNumber() < 0.25) and length > 2.4 then
		local side = B.rng:NextNumber() < 0.5 and 1 or -1
		if style.bareInside and style.out then
			side = style.out
		end
		local a, b = span(-0.05, rnd(2.2, 3.8))
		local w, u = b - a, (a + b) / 2
		local y1 = math.floor(math.min(top - 0.3, rnd(3.6, 5.0)) * 2) / 2
		if y1 > 1.2 then
			facePlate(parent, "Scorch", faceAxis, c + side * half, side, PROUD_SOOT, u - w / 2, u + w / 2, 0.4, y1, SOOT, MAT.Slate)
		end
	end

	-- The team's stripe, as painted: along the outer face (and the inner, where asked), with the odd
	-- panel's worn away.
	if top > 4.0 and length > 1.4 then
		local function stripe(side)
			if B.rng:NextNumber() < 0.15 then
				return
			end
			facePlate(parent, "TeamStripe", faceAxis, c + side * half, side, PROUD_PAINT, u0 + 0.35,
				u0 + 0.35 + math.floor((length - 0.7) / 0.5) * 0.5, 2.3, 3.1,
				B.team, MAT.SmoothPlastic)
		end
		if style.stripe and style.out then
			stripe(style.out)
		end
		if style.inStripe and style.out then
			stripe(-style.out)
		end
	end
	return wall
end

-- A straight run of perimeter wall from u0 to u1, cut into panels of about 6.5 studs of uneven
-- height, the panel at a gapped end knocked down to a stub with a broken slope up from it.
-- `hold` (optional) is a point along the run whose panel is kept standing tall and carries the
-- team's banner on its outer face; `keep` (optional, {from, to}) keeps those panels tall too (the
-- lean-to's roof rests on them).
-- `bare` (optional, {from, to}): panels there keep their inner face plain, because something leans on it.
local function perimeterRun(parent, axis, c, u0, u1, out, lowStart, lowEnd, hold, keep, bare)
	local count = math.max(1, math.floor((u1 - u0) / 6.5 + 0.5))
	local length = (u1 - u0) / count
	local tops = {}
	for index = 1, count do
		tops[index] = rnd(6.6, 9.4)
		local a, b = u0 + (index - 1) * length, u0 + index * length
		if (hold and hold >= a and hold <= b) or (keep and b > keep[1] and a < keep[2]) then
			tops[index] = math.max(tops[index], rnd(8.6, 9.4))
		end
	end
	for index = 1, count do
		local a, b = u0 + (index - 1) * length, u0 + index * length
		local low = (lowStart and index == 1) or (lowEnd and index == count)
		local top = tops[index]
		local style = { out = out, stripe = true, inStripe = index % 2 == 0, health = 200 }
		if bare and b > bare[1] and a < bare[2] then
			style.bareInside = true
			style.inStripe = false
		end
		if low then
			top = rnd(3.3, 4.4)
			style.low = true
			style.slopeUp = count > 1 and tops[lowStart and index + 1 or index - 1] or nil
			style.slopeToward = (lowStart and index == 1) and -1 or 1
		end
		wallPanel(parent, axis, a, b, c, 1.6, top, style)
		if hold and hold >= a and hold <= b then
			-- The banner: a rod along the top of the outer face, the cloth hanging from it, the insignia on it.
			local m = (a + b) / 2
			local face = c + out * 0.8
			local function at(u, y, off)
				if axis == "x" then
					return Vector3.new(u, y, face + out * off)
				end
				return Vector3.new(face + out * off, y, u)
			end
			rod(parent, "BannerRod", at(m - 2.4, top - 0.35, 0.2), at(m + 2.4, top - 0.35, 0.2), 0.5, STEEL_DARK, MAT.Metal, TRIM)
			local w, t = 2.0, 0.06
			if axis == "x" then
				box(parent, "TeamWallBanner", m - w, m + w, top - 6.6, top - 0.35, face + out * 0.51 - t, face + out * 0.51 + t, B.team, MAT.Fabric, TRIM)
			else
				box(parent, "TeamWallBanner", face + out * 0.51 - t, face + out * 0.51 + t, top - 6.6, top - 0.35, m - w, m + w, B.team, MAT.Fabric, TRIM)
			end
			local normal = axis == "x" and Vector3.new(0, 0, out) or Vector3.new(out, 0, 0)
			insignia(parent, at(m, top - 3.2, 0.57), normal, 2.6, mix(B.team, SOOT, 0.55))
		end
	end
end

--------------------------------------------------------------------------------
-- The ground
--------------------------------------------------------------------------------

-- Concrete paving over a rectangle: nx by nz slabs with 0.2 cracks of ground between them, sunk a
-- stud into the ground.
local function paving(parent, x0, x1, z0, z1, nx, nz, colors)
	local w, d = (x1 - x0) / nx, (z1 - z0) / nz
	for i = 1, nx do
		for j = 1, nz do
			local color = colors[B.rng:NextInteger(1, #colors)]
			box(parent, "Paving", x0 + (i - 1) * w + 0.1, x0 + i * w - 0.1, TILE_TOP - 1, TILE_TOP,
				z0 + (j - 1) * d + 0.1, z0 + j * d - 0.1, color, MAT.Concrete)
		end
	end
end

-- A mark lying on the paving (a crack, an oil stain, soot, a painted line). `level` 0, 1 or 2 lifts
-- it by 0.08 a step, so two marks that overlap never share a plane.
local function groundMark(parent, name, x, z, sizeX, sizeZ, yaw, color, material, level, floor)
	local thick = 0.12
	local centre = (floor or TILE_TOP) + 0.08 * (level or 0)
	return put(parent, name, Vector3.new(sizeX, thick, sizeZ), CFrame.new(x, centre, z) * CFrame.Angles(0, yaw, 0), color, material, TRIM)
end

-- A round mark on the floor (soot, oil, goo): a flat disc, at a level like groundMark's.
local function groundDisc(parent, name, x, z, diameter, color, material, level, floor)
	local y = (floor or TILE_TOP) + 0.08 * (level or 0)
	return rod(parent, name, Vector3.new(x, y - 0.06, z), Vector3.new(x, y + 0.06, z), diameter, color, material, TRIM)
end

-- A ramp from the ground up to the paving's top at a vehicle gate, so no wheel meets a lip: a wedge
-- `run` long outside the wall face at `at` (axis "z": the front wall, the ramp running -Z; "x": the
-- east wall, running +X), u0..u1 across.
local function gateRamp(parent, axis, at, u0, u1, run)
	local rise = TILE_TOP + 0.5
	if axis == "z" then
		-- A wedge's tall face is its +Z: turned half round, it is tall at the wall and low outside.
		put(parent, "Paving", Vector3.new(u1 - u0, rise, run), CFrame.new((u0 + u1) / 2, TILE_TOP - rise / 2, at - run / 2) * CFrame.Angles(0, math.pi, 0),
			PAVING, MAT.Concrete, { class = "WedgePart" })
	else
		put(parent, "Paving", Vector3.new(u1 - u0, rise, run), CFrame.new(at + run / 2, TILE_TOP - rise / 2, (u0 + u1) / 2) * CFrame.Angles(0, math.pi / 2, 0),
			PAVING, MAT.Concrete, { class = "WedgePart" })
	end
end

local function buildGround(model)
	local ground = Instance.new("Model")
	ground.Name = "Paving"
	ground.Parent = model
	-- The foundation: one slab under the whole compound, its top 0.1 over the levelled ground, so a ray
	-- down anywhere inside the walls finds concrete of the compound's own.
	box(ground, "Foundation", -WX - 0.7, WX + 0.7, -1.2, FOUNDATION_TOP, -WZ - 0.7, WZ + 0.7, CONCRETE_DARK, MAT.Concrete)
	-- The parade ground (the courtyard) in cracked slabs of three greys, and the strip under its gate.
	paving(ground, -WX + 0.8, 2, -WZ + 0.8, 24, 6, 6, { PAVING, CONCRETE_DARK, CONCRETE })
	paving(ground, -37, -29, -WZ - 1.4, -WZ + 0.8, 1, 1, { PAVING })
	-- The alley between the spawn hall and the armoury.
	paving(ground, -7, 4, 24, WZ - 0.8, 1, 3, { PAVING, CONCRETE })
	-- The motor pool as TWO slabs (no wheel of a parked car and no footing ray of VehicleService's
	-- stands over a crack): the apron and the front row, out under the main gate; the east row, out
	-- under the east gate. Ramps down to the ground outside both.
	box(ground, "Paving", 2, WX - 0.8, TILE_TOP - 1, TILE_TOP, -WZ - 0.8, 8, PAVING, MAT.Concrete)
	box(ground, "Paving", 24, WX + 0.8, TILE_TOP - 1, TILE_TOP, 8, WZ - 0.8, PAVING, MAT.Concrete)
	gateRamp(ground, "z", -WZ - 0.8, LANE_X0, LANE_X1, 3)
	gateRamp(ground, "x", WX + 0.8, EAST_Z0, EAST_Z1, 3)
	-- A kerb line of yellow paint where the parade ground meets the motor pool.
	groundMark(ground, "KerbPaint", 2.1, -14, 0.2, 76, 0, YELLOW_PAINT, MAT.SmoothPlastic, 1)
	-- Cracks and blast marks, at least 6 apart so no two cross.
	for _, at in ipairs({ { -56, -40 }, { -27, -30 }, { -6, -44 }, { -4, -18 }, { -38, 8 }, { -58, -4 }, { -22, 16 },
		{ 14, -4 }, { 44, -2 }, { 30, -48 }, { 52, 30 } }) do
		groundMark(ground, "Crack", at[1], at[2], rnd(2.5, 5.2), 0.22,
			B.rng:NextInteger(0, 1) * math.pi / 2 + rnd(0.15, math.pi / 2 - 0.15), SOOT, MAT.Slate, 1)
	end
	for _, blast in ipairs({ { -17, -8, 4.6 }, { -46, -44, 3.4 }, { 28, -8, 3.8 } }) do
		groundDisc(ground, "BlastMark", blast[1], blast[2], blast[3], mix(SOOT, CONCRETE_DARK, 0.35), MAT.Slate, 0)
		groundDisc(ground, "BlastMark", blast[1] + 0.3, blast[2] - 0.2, blast[3] * 0.55, SOOT, MAT.Slate, 2)
	end
end

--------------------------------------------------------------------------------
-- The perimeter
--------------------------------------------------------------------------------

local function buildPerimeter(model)
	local walls = Instance.new("Model")
	walls.Name = "Perimeter"
	walls.Parent = model

	-- Front (z = -WZ, outside -Z): the corner to the foot gate, the foot gate to the gatehouse.
	perimeterRun(walls, "x", -WZ, -WX - 0.8, -40, -1, false, false, -50)
	perimeterRun(walls, "x", -WZ, -26, LANE_X0 - 8.2, -1, false, false, -15)
	-- West (x = -WX): the corner to the breach at z -14..-6, the breach to the spawn hall.
	perimeterRun(walls, "z", -WX, -WZ + 0.8, -14, -1, false, true, -34)
	perimeterRun(walls, "z", -WX, -6, 24, -1, true, false, 18, { -0.5, 14.5 }, { -0.5, 14.5 })
	-- East (x = +WX): from the gatehouse's east tower to the east gate's south post.
	perimeterRun(walls, "z", WX, -WZ + 6.4, EAST_Z0 - 3.9, 1, false, false, -24)
	-- Back (z = +WZ): the alley's end, and behind the east row of bays.
	perimeterRun(walls, "x", WZ, -7, 4, 1, false, false)
	perimeterRun(walls, "x", WZ, 24, WX - 1.2, 1, false, false, 44)

	-- Rubble spilled out of the breach, clear of the way through.
	rubble(walls, -WX - 2.2, -15.4, 1.6, 4, 0)
	rubble(walls, -WX - 2.4, -4.6, 1.6, 4, 0)
	rubble(walls, -WX + 2.6, -12.8, 1.2, 3, TILE_TOP)
end

--------------------------------------------------------------------------------
-- The gates: the gatehouse over the motor pool, the east gate, the foot gate
--------------------------------------------------------------------------------

-- A truss between two points at the same height along X or Z: bottom and top chords, posts and
-- diagonals between them. Everything in it is a real part (it is what the sign hangs on).
local function truss(parent, alongX, u0, u1, c, y0, y1, bay)
	local function at(u, y)
		return alongX and Vector3.new(u, y, c) or Vector3.new(c, y, u)
	end
	if alongX then
		box(parent, "Gantry", u0, u1, y0, y0 + 1.2, c - 0.6, c + 0.6, STEEL, MAT.Metal)
		box(parent, "Gantry", u0, u1, y1 - 0.8, y1, c - 0.5, c + 0.5, STEEL, MAT.Metal)
	else
		box(parent, "Gantry", c - 0.6, c + 0.6, y0, y0 + 1.2, u0, u1, STEEL, MAT.Metal)
		box(parent, "Gantry", c - 0.5, c + 0.5, y1 - 0.8, y1, u0, u1, STEEL, MAT.Metal)
	end
	local count = math.max(1, math.floor((u1 - u0) / bay + 0.5))
	local step = (u1 - u0) / count
	for index = 1, count - 1 do
		local u = u0 + index * step
		if alongX then
			box(parent, "GantryPost", u - 0.3, u + 0.3, y0 + 1.2, y1 - 0.8, c - 0.3, c + 0.3, STEEL_DARK, MAT.Metal)
		else
			box(parent, "GantryPost", c - 0.3, c + 0.3, y0 + 1.2, y1 - 0.8, u - 0.3, u + 0.3, STEEL_DARK, MAT.Metal)
		end
	end
	for index = 1, count do
		local a, b = u0 + (index - 1) * step, u0 + index * step
		local flip = index % 2 == 0
		plateBetween(parent, "GantryBrace", at(flip and a + 0.3 or b - 0.3, y0 + 1.25), at(flip and b - 0.3 or a + 0.3, y1 - 0.85), 0.35, 0.35,
			STEEL_DARK, MAT.Metal)
	end
end

-- A gatehouse tower: a concrete block on a wider plinth, a band at the gantry, slit windows, a
-- parapet round a flat roof, a banner with the insignia facing out, a ladder on its back.
local TOWER_TOP = 16
local function gateTower(gate, x0, x1, z0, z1, ladderX)
	box(gate, "GateTower", x0 - 0.5, x1 + 0.5, -0.95, 2.2, z0 - 0.5, z1 + 0.5, CONCRETE_DARK, MAT.Concrete)
	box(gate, "GateTower", x0, x1, 2.2, TOWER_TOP, z0, z1, CONCRETE, MAT.Concrete)
	-- A band of darker concrete round it at the gantry, the roof slab over the top.
	box(gate, "TowerBand", x0 - 0.25, x1 + 0.25, GANTRY_Y - 0.4, GANTRY_Y + 0.5, z0 - 0.25, z1 + 0.25, CONCRETE_DARK, MAT.Concrete)
	box(gate, "TowerRoof", x0 - 0.35, x1 + 0.35, TOWER_TOP, TOWER_TOP + 0.4, z0 - 0.35, z1 + 0.35, CONCRETE_DARK, MAT.Concrete)
	-- The parapet, with a gap at the back for the ladder.
	local top = TOWER_TOP + 0.4
	box(gate, "Parapet", x0 - 0.35, x1 + 0.35, top, top + 1.3, z0 - 0.35, z0 + 0.45, CONCRETE, MAT.Concrete)
	box(gate, "Parapet", x0 - 0.35, x0 + 0.45, top, top + 1.1, z0 + 0.45, z1 + 0.35, CONCRETE, MAT.Concrete)
	box(gate, "Parapet", x1 - 0.45, x1 + 0.35, top, top + 1.2, z0 + 0.45, z1 + 0.35, CONCRETE, MAT.Concrete)
	-- Slits on the front, and a scorch where something hit it.
	for _, u in ipairs({ x0 + 1.6, x1 - 2.4 }) do
		facePlate(gate, "WindowSlit", "z", z0, -1, 0.1, u, u + 0.8, 5.5, 8.5, SOOT, MAT.Slate)
	end
	facePlate(gate, "Scorch", "z", z0, -1, PROUD_SOOT, x0 + 0.6, x0 + 3.2, 2.6, 6.2, SOOT, MAT.Slate)
	-- The team's banner down the front, the insignia on it.
	local mid = (x0 + x1) / 2
	rod(gate, "BannerRod", Vector3.new(mid - 2, 14.9, z0 - 0.45), Vector3.new(mid + 2, 14.9, z0 - 0.45), 0.35, STEEL_DARK, MAT.Metal, TRIM)
	box(gate, "TeamTowerBanner", mid - 1.7, mid + 1.7, 9.2, 14.8, z0 - 0.33, z0 - 0.19, B.team, MAT.Fabric, TRIM)
	insignia(gate, Vector3.new(mid, 12.6, z0 - 0.33), Vector3.new(0, 0, -1), 2.4, mix(B.team, SOOT, 0.55))
	-- A floodlight on the inner corner, looking in over the pool.
	local la = ladderX > mid and x0 + 0.3 or x1 - 1.9
	local lampHead = box(gate, "GateLamp", la, la + 1.6, 10.2, 11.1, z1, z1 + 0.9, STEEL_DARK, MAT.Metal, TRIM)
	local _ = lampHead
	local glass = box(gate, "GateLampGlass", la + 0.2, la + 1.4, 10.35, 10.95, z1 + 0.9, z1 + 1.05, WARM, MAT.Neon, TRIM)
	light(glass, WARM, 28, 1.4)
	-- The way up: a ladder on the back face.
	local ladder = Instance.new("TrussPart")
	ladder.Name = "TowerLadder"
	ladder.Anchored = true
	ladder.Size = Vector3.new(2, 16, 2)
	ladder.CFrame = B.frame * CFrame.new(ladderX, 8, z1 + 1)
	ladder.Color = STEEL
	ladder.Material = MAT.Metal
	ladder.Parent = gate
	-- Where pc/mounted-guns stands a gun: invisible, not solid, tagged, its CFrame at the gun's base,
	-- facing out of the compound.
	local mount = put(gate, "GunEmplacement", Vector3.new(1, 0.2, 1), CFrame.new(mid, top, (z0 + z1) / 2), STEEL_DARK, MAT.Metal,
		{ trim = true, transparency = 1 })
	mount.CastShadow = false
	game:GetService("CollectionService"):AddTag(mount, "GunEmplacement")
end

local function buildGates(model)
	local gate = Instance.new("Model")
	gate.Name = "Gate"
	gate.Parent = model

	-- THE GATEHOUSE over the motor pool's way out: two towers either side of the four lanes, a truss
	-- between them over the lanes (its underside GANTRY_Y, over the tallest vehicle there is with a
	-- stud and more to spare), the lit sign in its middle.
	gateTower(gate, LANE_X0 - 8.2, LANE_X0 - 0.8, -WZ - 4.4, -WZ + 4.4, LANE_X0 - 4)
	gateTower(gate, LANE_X1 + 0.8, LANE_X1 + 8.2, -WZ - 4.4, -WZ + 4.4, LANE_X1 + 2.3)
	truss(gate, true, LANE_X0 - 0.8, LANE_X1 + 0.8, -WZ, GANTRY_Y, GANTRY_Y + 4.4, 7.5)
	-- The sign stands on the truss's top chord, over the whole way out.
	litSign(gate, "x", -WZ, -1, (LANE_X0 + LANE_X1) / 2 - 8, (LANE_X0 + LANE_X1) / 2 + 8, GANTRY_Y + 4.4, GANTRY_Y + 8.2, 30)

	-- THE EAST GATE, for the east row: two posts, a truss between them, a sign on the outside.
	box(gate, "GatePost", WX - 1.2, WX + 1.6, -1, GANTRY_Y + 4.4, EAST_Z0 - 3.9, EAST_Z0 - 0.2, CONCRETE_DARK, MAT.Concrete)
	box(gate, "GatePost", WX - 1.2, WX + 1.6, -1, GANTRY_Y + 4.4, EAST_Z1 + 0.2, WZ + 0.8, CONCRETE_DARK, MAT.Concrete)
	box(gate, "PostCap", WX - 1.45, WX + 1.85, GANTRY_Y + 4.4, GANTRY_Y + 4.9, EAST_Z0 - 4.15, EAST_Z0 + 0.05, CONCRETE, MAT.Concrete)
	box(gate, "PostCap", WX - 1.45, WX + 1.85, GANTRY_Y + 4.4, GANTRY_Y + 4.9, EAST_Z1 - 0.05, WZ + 1.05, CONCRETE, MAT.Concrete)
	truss(gate, false, EAST_Z0 - 0.2, EAST_Z1 + 0.2, WX + 0.2, GANTRY_Y, GANTRY_Y + 4.4, 7.5)
	litSign(gate, "z", WX + 0.2, 1, (EAST_Z0 + EAST_Z1) / 2 - 7, (EAST_Z0 + EAST_Z1) / 2 + 7, GANTRY_Y + 4.4, GANTRY_Y + 7.8, 24)
	for _, z in ipairs({ EAST_Z0 - 2, EAST_Z1 + 2 }) do
		facePlate(gate, "TeamGatePaint", "x", WX + 1.6, 1, PROUD_PAINT, z - 1, z + 1, 8.6, 10.6, B.team, MAT.SmoothPlastic)
	end

	-- THE FOOT GATE into the parade ground: two pylons and a lintel, the insignia on each pylon, a
	-- sandbagged step on the lintel.
	for _, x in ipairs({ -40, -29 }) do
		box(gate, "GatePylon", x - 0.3, x + 3.3, -0.9, 12.4, -WZ - 1.6, -WZ + 1.4, CONCRETE, MAT.Concrete)
		box(gate, "PylonCap", x - 0.55, x + 3.55, 12.4, 12.9, -WZ - 1.85, -WZ + 1.65, CONCRETE_DARK, MAT.Concrete)
		box(gate, "PylonPlinth", x - 0.55, x + 3.55, -0.95, 1.6, -WZ - 1.85, -WZ + 1.65, CONCRETE_DARK, MAT.Concrete)
		insignia(gate, Vector3.new(x + 1.5, 6.4, -WZ - 1.6), Vector3.new(0, 0, -1), 2.2, B.team)
	end
	box(gate, "Lintel", -37, -29, 9.6, 11.4, -WZ - 1.2, -WZ + 1.0, CONCRETE_DARK, MAT.Concrete)
	facePlate(gate, "TeamLintelPaint", "z", -WZ - 1.2, -1, PROUD_PAINT, -36.4, -29.6, 10.1, 10.9, B.team, MAT.SmoothPlastic)
	sandbags(gate, "lintel", -36.6, -WZ - 0.1, -29.4, -WZ - 0.1, 1, 11.4)
	table.insert(B.doorways, { name = "FootGate", x0 = -36.4, x1 = -29.6, z0 = -WZ - 1.2, z1 = -WZ + 1.0, floor = TILE_TOP, top = 9.6 })
	local lamp = wallLamp(gate, Vector3.new(-33, 10.5, -WZ + 1.0), Vector3.new(0, 0, 1), 20)
	local _ = lamp
end

--------------------------------------------------------------------------------
-- The spawn hall ("Spawn"): 28 pads under one roof, four ways out
--------------------------------------------------------------------------------

local BUNKER_TOP = 10.8
local ROOF_TOP = 12
-- The pads: seven columns by four rows, 7.5 and 6.5 apart, so a full team of 25 spawns with room
-- to step off (Oliver, 2026-09-24: "the bases need to be bigger to accommodate all the players").
local PAD_X = { -60.5, -53, -45.5, -38, -30.5, -23, -15.5 }
local PAD_Z = { 30, 36.5, 43, 49.5 }
-- The hall's front doors (x spans), each 8 wide.
local HALL_DOORS = { { -57, -49 }, { -42, -34 }, { -27, -19 } }
local HALL_EAST_DOOR = { 36, 44 }

local function buildHall(model)
	local hall = Instance.new("Model")
	-- "Spawn" is in DestructibleService.Never: nothing in here breaks, whatever it is called.
	hall.Name = "Spawn"
	hall:SetAttribute("Destructible", false)
	hall.Parent = model
	local never = { tag = false }
	local x0, x1, z0, z1 = -WX - 0.8, -7, 24, WZ + 0.8

	-- The floor, 0.5 over the paving: one easy step at every door.
	box(hall, "Foundation", x0 + 2, x1 - 2, -0.6, ROOM_FLOOR, z0 + 2, z1 - 2, CONCRETE_DARK, MAT.Concrete, never)
	for _, door in ipairs(HALL_DOORS) do
		box(hall, "Foundation", door[1], door[2], -0.6, ROOM_FLOOR, z0, z0 + 2, CONCRETE_DARK, MAT.Concrete, never)
	end
	box(hall, "Foundation", x1 - 2, x1, -0.6, ROOM_FLOOR, HALL_EAST_DOOR[1], HALL_EAST_DOOR[2], CONCRETE_DARK, MAT.Concrete, never)

	local function wall(a, b, c, d, y1, color)
		return box(hall, "BunkerWall", a, b, -1, y1 or BUNKER_TOP, c, d, color or BUNKER, MAT.Concrete, never)
	end
	-- West and back: the compound's own walls here.
	wall(x0, x0 + 2, z0, z1)
	wall(x0 + 2, x1, z1 - 2, z1)
	-- East: the door to the alley.
	wall(x1 - 2, x1, z0, HALL_EAST_DOOR[1])
	wall(x1 - 2, x1, HALL_EAST_DOOR[2], z1 - 2)
	box(hall, "BunkerWall", x1 - 2, x1, 9, BUNKER_TOP, HALL_EAST_DOOR[1], HALL_EAST_DOOR[2], BUNKER, MAT.Concrete, never)
	table.insert(B.doorways, { name = "HallEast", x0 = x1 - 2, x1 = x1, z0 = HALL_EAST_DOOR[1], z1 = HALL_EAST_DOOR[2], floor = ROOM_FLOOR, top = 9 })
	-- Front: three wide doors onto the parade ground.
	local last = x0 + 2
	for index, door in ipairs(HALL_DOORS) do
		wall(last, door[1], z0, z0 + 2)
		box(hall, "BunkerWall", door[1], door[2], 9, BUNKER_TOP, z0, z0 + 2, BUNKER, MAT.Concrete, never)
		table.insert(B.doorways, { name = "HallDoor" .. index, x0 = door[1], x1 = door[2], z0 = z0, z1 = z0 + 2, floor = ROOM_FLOOR, top = 9 })
		last = door[2]
	end
	wall(last, x1 - 2, z0, z0 + 2)

	-- The roof, and the column line that holds its middle.
	box(hall, "BunkerRoof", x0, x1, BUNKER_TOP, ROOF_TOP, z0, z1, BUNKER, MAT.Concrete, never)
	box(hall, "BunkerBeam", x0 + 2, x1 - 2, 9.8, BUNKER_TOP, 39.1, 40.4, BUNKER_DARK, MAT.Concrete, never)
	for _, x in ipairs({ -49.25, -34.25, -19.25 }) do
		box(hall, "BunkerPillar", x - 0.7, x + 0.7, ROOM_FLOOR, 9.8, 39.05, 40.45, BUNKER_DARK, MAT.Concrete, never)
	end

	-- THE FACADE. Pilasters between the doors, standing proud of the roof; a hood over each door with
	-- the team's colour on its edge and round the opening; a darker plinth; slit windows.
	for _, x in ipairs({ -45.5, -30.5, -15.5 }) do
		box(hall, "BunkerPillar", x - 1.2, x + 1.2, -0.9, 12.8, z0 - 1.2, z0 + 0.4, BUNKER_DARK, MAT.Concrete, never)
		box(hall, "PillarCap", x - 1.45, x + 1.45, 12.8, 13.3, z0 - 1.45, z0 + 0.65, BUNKER, MAT.Concrete, never)
	end
	box(hall, "BunkerPillar", x0 - 0.3, x0 + 2.3, -0.9, 13.1, z0 - 1.2, z0 + 2.3, BUNKER_DARK, MAT.Concrete, never)
	box(hall, "BunkerPillar", x1 - 2.3, x1 + 0.3, -0.9, 13.1, z0 - 1.2, z0 + 2.3, BUNKER_DARK, MAT.Concrete, never)
	for _, door in ipairs(HALL_DOORS) do
		local a, b = door[1], door[2]
		box(hall, "DoorHood", a - 0.9, b + 0.9, 9.4, 9.95, z0 - 2.6, z0, BUNKER_DARK, MAT.Concrete, never)
		facePlate(hall, "TeamHoodEdge", "z", z0 - 2.6, -1, 0.1, a - 0.7, b + 0.7, 9.5, 9.85, B.team, MAT.SmoothPlastic)
		facePlate(hall, "TeamDoorFrame", "z", z0, -1, PROUD_PAINT, a - 0.6, a + 0.08, ROOM_FLOOR, 9.0, B.team, MAT.SmoothPlastic)
		facePlate(hall, "TeamDoorFrame", "z", z0, -1, PROUD_PAINT, b - 0.08, b + 0.6, ROOM_FLOOR, 9.0, B.team, MAT.SmoothPlastic)
		for _, s in ipairs({ a - 0.2, b + 0.2 }) do
			local lamp = wallLamp(hall, Vector3.new(s + (s < a and -1.6 or 1.6), 7.8, z0), Vector3.new(0, 0, -1), 16)
			local _ = lamp
		end
	end
	local pieces = { { x0 + 2.3, HALL_DOORS[1][1] - 0.6 }, { HALL_DOORS[1][2] + 0.6, -46.7 }, { -44.3, HALL_DOORS[2][1] - 0.6 },
		{ HALL_DOORS[2][2] + 0.6, -31.7 }, { -29.3, HALL_DOORS[3][1] - 0.6 }, { HALL_DOORS[3][2] + 0.6, -16.7 }, { -14.3, x1 - 2.3 } }
	for _, piece in ipairs(pieces) do
		facePlate(hall, "Plinth", "z", z0, -1, PROUD_BRICK, piece[1], piece[2], 0.35, 1.6, BUNKER_DARK, MAT.Concrete)
		if piece[2] - piece[1] > 4 then
			local m = (piece[1] + piece[2]) / 2
			facePlate(hall, "WindowSlit", "z", z0, -1, PROUD_PAINT, m - 1.2, m + 1.2, 5.6, 6.5, SOOT, MAT.Slate)
			facePlate(hall, "TeamStripe", "z", z0, -1, PROUD_PAINT, piece[1] + 0.2, piece[2] - 0.2, 2.4, 3.0, B.team, MAT.SmoothPlastic)
		end
	end
	facePlate(hall, "Scorch", "z", z0, -1, PROUD_SOOT, -18.6, -16.9, 1.2, 5.4, SOOT, MAT.Slate)
	facePlate(hall, "Scorch", "z", z0, -1, PROUD_SOOT, -64.2, -61.5, 5.2, 9.9, SOOT, MAT.Slate)

	-- THE LANTERN over the middle door: a raised block on the roof with clerestory slits down its sides,
	-- the team's band round the top and the insignia lit on its face. It is what you see from the gate.
	local lx0, lx1, lz1 = -47.2, -28.8, 36
	box(hall, "Lantern", lx0, lx1, ROOF_TOP, 16.6, z0 + 0.6, lz1, BUNKER, MAT.Concrete, never)
	box(hall, "LanternRoof", lx0 - 0.4, lx1 + 0.4, 16.6, 17.1, z0 + 0.2, lz1 + 0.4, BUNKER_DARK, MAT.Concrete, never)
	facePlate(hall, "TeamBand", "z", z0 + 0.6, -1, PROUD_PAINT, lx0 + 0.3, lx1 - 0.3, 15.5, 16.3, B.team, MAT.SmoothPlastic)
	insignia(hall, Vector3.new(-38, 13.9, z0 + 0.6), Vector3.new(0, 0, -1), 3.0, B.team)
	local glow = facePlate(hall, "TeamSignGlow", "z", z0, -1, PROUD_PAINT, -41.5, -34.5, 11.2, 11.6, B.team, MAT.Neon)
	light(glow, B.team:Lerp(WARM, 0.5), 20, 1.2)
	for _, x in ipairs({ lx0, lx1 }) do
		for z = 27.5, 33.5, 3 do
			facePlate(hall, "ClerestorySlit", "x", x, x < -38 and -1 or 1, PROUD_PAINT, z, z + 1.6, 13.2, 15.2, SOOT, MAT.Slate)
		end
	end

	-- The roof: a parapet round it, a sandbagged lookout on each front corner, a mast and a dish, vents.
	box(hall, "Parapet", x0, x1, ROOF_TOP, ROOF_TOP + 1.0, z1 - 0.8, z1, BUNKER_DARK, MAT.Concrete, never)
	box(hall, "Parapet", x0, x0 + 0.8, ROOF_TOP, ROOF_TOP + 1.05, z0 + 2.3, z1 - 0.8, BUNKER_DARK, MAT.Concrete, never)
	box(hall, "Parapet", x1 - 0.8, x1, ROOF_TOP, ROOF_TOP + 1.05, z0 + 2.3, z1 - 0.8, BUNKER_DARK, MAT.Concrete, never)
	sandbags(hall, "roofWest", x0 + 3, z0 + 1.6, x0 + 11, z0 + 1.6, 2, ROOF_TOP)
	sandbags(hall, "roofEast", x1 - 11, z0 + 1.6, x1 - 3, z0 + 1.6, 2, ROOF_TOP)
	rod(hall, "Aerial", Vector3.new(-58, ROOF_TOP, 46), Vector3.new(-58, ROOF_TOP + 9, 46), 0.35, STEEL, MAT.Metal)
	rod(hall, "Aerial", Vector3.new(-58, ROOF_TOP + 8.8, 46), Vector3.new(-56.6, ROOF_TOP + 10.9, 46.8), 0.28, STEEL, MAT.Metal)
	box(hall, "DishMount", -20.8, -19.2, ROOF_TOP, ROOF_TOP + 1.6, 45.2, 46.8, STEEL_DARK, MAT.Metal)
	put(hall, "Dish", Vector3.new(0.35, 4.2, 4.2),
		CFrame.new(-20, ROOF_TOP + 2.6, 46) * CFrame.Angles(0, 0.7, 0) * CFrame.Angles(0, 0, 0.9), WHITE_PAINT, MAT.Metal,
		{ shape = Enum.PartType.Cylinder })
	for _, v in ipairs({ { -54, 32 }, { -24, 32 }, { -12, 44 } }) do
		box(hall, "Vent", v[1], v[1] + 2.4, ROOF_TOP, ROOF_TOP + 1.4, v[2], v[2] + 2.4, STEEL, MAT.Metal)
		box(hall, "VentCap", v[1] - 0.3, v[1] + 2.7, ROOF_TOP + 1.4, ROOF_TOP + 1.7, v[2] - 0.3, v[2] + 2.7, STEEL_DARK, MAT.Metal)
	end
	rod(hall, "WaterTank", Vector3.new(-44, ROOF_TOP + 2.6, 47), Vector3.new(-36, ROOF_TOP + 2.6, 47), 3.4, mix(STEEL, RUST, 0.3), MAT.CorrodedMetal)
	for _, x in ipairs({ -43, -37 }) do
		box(hall, "TankCradle", x - 0.3, x + 0.3, ROOF_TOP, ROOF_TOP + 0.9, 45.6, 48.4, STEEL_DARK, MAT.Metal)
	end

	-- THE PADS.
	for _, z in ipairs(PAD_Z) do
		for _, x in ipairs(PAD_X) do
			box(hall, "TeamPad", x - 1.6, x + 1.6, ROOM_FLOOR, ROOM_FLOOR + 0.16, z - 1.6, z + 1.6, B.team, MAT.SmoothPlastic, TRIM)
			box(hall, "PadMark", x - 0.5, x + 0.5, ROOM_FLOOR + 0.1, ROOM_FLOOR + 0.24, z - 1.1, z - 0.2, WHITE_PAINT, MAT.SmoothPlastic, TRIM)
			table.insert(B.pads, CFrame.new(x, ROOM_FLOOR, z))
		end
	end

	-- Inside: the banner and insignia on the back wall, lamps along both long walls, lockers by the
	-- east door, a cable run.
	local back = z1 - 2
	rod(hall, "BannerRod", Vector3.new(-42.6, 9.35, back - 0.3), Vector3.new(-33.4, 9.35, back - 0.3), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	box(hall, "TeamBanner", -42, -34, 3.2, 9.2, back - 0.2, back, B.team, MAT.Fabric, TRIM)
	insignia(hall, Vector3.new(-38, 6.6, back - 0.2), Vector3.new(0, 0, -1), 3.4, mix(B.team, SOOT, 0.55))
	for _, x in ipairs({ -57, -26.5, -12 }) do
		wallLamp(hall, Vector3.new(x, 8.2, back), Vector3.new(0, 0, -1), 22)
	end
	for _, x in ipairs({ -60.5, -30.5 }) do
		wallLamp(hall, Vector3.new(x, 8.2, z0 + 2), Vector3.new(0, 0, 1), 20)
	end
	rod(hall, "Conduit", Vector3.new(x0 + 2.1, 9.4, back - 0.08), Vector3.new(x1 - 2, 9.4, back - 0.08), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	for _, span in ipairs({ { 27, 34.6 }, { 45.4, 51.8 } }) do
		for z = span[1], span[2] - 1.2, 1.3 do
			box(hall, "Locker", x1 - 3.3, x1 - 2, ROOM_FLOOR, 7.0, z, z + 1.2, mix(OLIVE, STEEL, 0.4), MAT.Metal)
		end
	end
	return hall
end

--------------------------------------------------------------------------------
-- The armoury: a brick shed on a concrete frame, a pitched roof, the chests
--------------------------------------------------------------------------------

local ARM_X0, ARM_X1, ARM_Z0, ARM_Z1 = 4, 24, 8, WZ + 0.8
local ARM_EAVES, ARM_RIDGE = 12, 15.4

local function buildArmoury(model)
	local room = Instance.new("Model")
	room.Name = "Armoury"
	room.Parent = model
	local x0, x1, z0, z1 = ARM_X0, ARM_X1, ARM_Z0, ARM_Z1
	box(room, "Foundation", x0 + 1, x1 - 1, -0.6, ROOM_FLOOR, z0 + 1, z1 - 1.6, CONCRETE_DARK, MAT.Concrete)
	box(room, "Foundation", 10, 18, -0.6, ROOM_FLOOR, z0, z0 + 1, CONCRETE_DARK, MAT.Concrete)
	box(room, "Foundation", x0, x0 + 1, -0.6, ROOM_FLOOR, 32.55, 42.25, CONCRETE_DARK, MAT.Concrete)

	-- The frame: concrete columns at the corners and down the long walls, brick panels between them.
	local columnsZ = { z0, 19.5, 31, 42.5, z1 - 1.3 }
	for _, x in ipairs({ x0, x1 - 1.3 }) do
		for _, z in ipairs(columnsZ) do
			box(room, "Pillar", x - 0.25, x + 1.55, -0.95, ARM_EAVES + 0.1, z - 0.25, z + 1.55, CONCRETE_LIGHT, MAT.Concrete)
		end
	end
	local function panel(axis, u0, u1, c, style)
		style.color = style.color or BRICK
		style.material = style.material or MAT.Brick
		style.plain = true
		style.wire = false
		style.brick = false
		style.soot = false
		style.health = 160
		return wallPanel(room, axis, u0, u1, c, 1.3, ARM_EAVES, style)
	end
	-- West wall (x = x0 + 0.65), the door to the alley at z 34..42.
	for index = 1, #columnsZ - 1 do
		local a, b = columnsZ[index] + 1.55, columnsZ[index + 1] - 0.25
		if index ~= 3 then
			panel("z", a, b, x0 + 0.65, { out = -1, stripe = true })
		end
		panel("z", a, b, x1 - 0.65, { out = 1, color = BRICK_DARK })
	end
	box(room, "Wall", x0, x0 + 1.3, 9, ARM_EAVES, 32.55, 42.25, BRICK, MAT.Brick, { health = 160 })
	table.insert(B.doorways, { name = "ArmouryWest", x0 = x0, x1 = x0 + 1.3, z0 = 32.55, z1 = 42.25, floor = ROOM_FLOOR, top = 9 })
	-- The front (z0) with its double door; the back is the compound's wall.
	panel("x", x0 + 1.55, 10, z0 + 0.65, { out = -1, stripe = true })
	panel("x", 18, x1 - 1.55, z0 + 0.65, { out = -1, stripe = true })
	box(room, "Wall", 10, 18, 8.4, ARM_EAVES, z0, z0 + 1.3, BRICK, MAT.Brick, { health = 160 })
	table.insert(B.doorways, { name = "ArmouryFront", x0 = 10, x1 = 18, z0 = z0, z1 = z0 + 1.3, floor = ROOM_FLOOR, top = 8.4 })
	panel("x", x0 + 1.55, x1 - 1.55, z1 - 0.65, { out = 1, color = BRICK_DARK, stripe = true })

	-- The pitched roof: two slopes of corrugated steel on a ridge, gables in brick at both ends.
	local mid = (x0 + x1) / 2
	local rise = ARM_RIDGE - ARM_EAVES
	-- The slope's centre line: 0.2 over the wall tops at the wall's middle, rising `rise` to the ridge.
	local wallLine = x0 + 0.65
	local slope = rise / (mid - wallLine)
	for _, s in ipairs({ -1, 1 }) do
		local eaveX = mid + s * ((x1 - x0) / 2 + 0.8)
		local eaveY = ARM_EAVES + 0.2 - (math.abs(eaveX - mid) - (mid - wallLine)) * slope
		local zc = (z0 + z1) / 2
		plateBetween(room, "Roof", Vector3.new(eaveX, eaveY, zc), Vector3.new(mid, ARM_EAVES + 0.2 + rise + (s > 0 and 0.06 or 0), zc), z1 - z0 + (s < 0 and 1.2 or 1.0), 0.4,
			s < 0 and mix(STEEL, RUST, 0.45) or mix(STEEL, RUST, 0.6), MAT.CorrodedMetal)
	end
	rod(room, "RidgeCap", Vector3.new(mid, ARM_EAVES + rise + 0.45, z0 - 0.4), Vector3.new(mid, ARM_EAVES + rise + 0.45, z1 + 0.4), 0.6, STEEL_DARK, MAT.Metal)
	for _, zc in ipairs({ z0 + 0.65, z1 - 0.65 }) do
		for _, s in ipairs({ -1, 1 }) do
			local run = (x1 - x0) / 2 - 0.2
			put(room, "Gable", Vector3.new(1.3, rise, run), CFrame.new(mid + s * run / 2, ARM_EAVES + rise / 2, zc) * CFrame.Angles(0, s < 0 and math.pi / 2 or -math.pi / 2, 0),
				BRICK_DARK, MAT.Brick, { class = "WedgePart", health = 120 })
		end
	end
	-- The sign over the front door, and lamps either side of it.
	litSign(room, "x", z0, -1, 10.4, 17.6, 8.8, 11.8, 16)
	for _, x in ipairs({ 8.6, 19.4 }) do
		wallLamp(room, Vector3.new(x, 8, z0), Vector3.new(0, 0, -1), 14)
	end
	-- Painted windows down the west face.
	for _, z in ipairs({ 14.5, 25, 48 }) do
		facePlate(room, "Window", "x", x0, -1, PROUD_PAINT, z - 1.6, z + 1.6, 5.4, 8.2, mix(SOOT, STEEL, 0.3), MAT.Glass)
		facePlate(room, "WindowFrame", "x", x0, -1, PROUD_BRICK, z - 1.9, z + 1.9, 5.1, 8.5, CONCRETE_LIGHT, MAT.Concrete)
	end

	-- THE AWNING over the east row: corrugated sheet cantilevered off the east wall on struts, over the
	-- tallest vehicle's roof. Dressing (no collision, no queries): nothing stands in the bays or their
	-- ways out, and VehicleService's footing rays pass it.
	local awning = mix(STEEL, OLIVE, 0.35)
	plateBetween(room, "Awning", Vector3.new(x1, 12.6, (EAST_Z0 + EAST_Z1) / 2), Vector3.new(x1 + 17, 12.1, (EAST_Z0 + EAST_Z1) / 2),
		EAST_Z1 - EAST_Z0 + 1, 0.3, awning, MAT.CorrodedMetal, TRIM)
	for _, z in ipairs({ EAST_Z0 + 1, (EAST_Z0 + EAST_Z1) / 2, EAST_Z1 - 1 }) do
		plateBetween(room, "AwningStrut", Vector3.new(x1 + 0.1, 8.2, z), Vector3.new(x1 + 9, 12.2, z), 0.3, 0.3, STEEL_DARK, MAT.Metal, TRIM)
	end

	-- Inside: racks between the chest spots, crates, lamps, the chests.
	local lampZ = { 14, 27, 40, 50 }
	for _, z in ipairs(lampZ) do
		wallLamp(room, Vector3.new(x1 - 1.3, 8.4, z), Vector3.new(-1, 0, 0), 14)
	end
	for _, z in ipairs({ 17, 23.2, 44 }) do
		box(room, "Rack", x0 + 1.3, x0 + 2.4, ROOM_FLOOR, 6.4, z - 0.4, z + 0.4, WOOD_DARK, MAT.WoodPlanks)
	end
	for _, z in ipairs({ 21, 31, 41 }) do
		box(room, "Rack", x1 - 2.4, x1 - 1.3, ROOM_FLOOR, 6.4, z - 0.4, z + 0.4, WOOD_DARK, MAT.WoodPlanks)
	end
	local stack = { tag = "Crate:armoury" }
	box(room, "Crate", 12.6, 15.6, ROOM_FLOOR, ROOM_FLOOR + 3, 49.4, 52.4, WOOD, MAT.WoodPlanks, stack)
	box(room, "Crate", 12.9, 15.3, ROOM_FLOOR + 3, ROOM_FLOOR + 5.4, 49.7, 52.1, WOOD_DARK, MAT.WoodPlanks, stack)
	facePlate(room, "CrateBand", "z", 49.4, -1, 0.08, 12.8, 15.4, ROOM_FLOOR + 1.3, ROOM_FLOOR + 1.7, STEEL_DARK, MAT.Metal, trimWith({ tag = stack.tag }))
	for _, spot in ipairs({ { "ArmouryWest1", x0 + 5.4, 14 }, { "ArmouryWest2", x0 + 5.4, 20.3 }, { "ArmouryWest3", x0 + 5.4, 26.6 },
		{ "ArmouryWest4", x0 + 5.4, 48 }, { "ArmouryEast1", x1 - 5.4, 16 }, { "ArmouryEast2", x1 - 5.4, 26 },
		{ "ArmouryEast3", x1 - 5.4, 36 }, { "ArmouryEast4", x1 - 5.4, 46 } }) do
		table.insert(B.chests, { name = spot[1], at = CFrame.new(spot[2], ROOM_FLOOR, spot[3]) })
	end
	for _, z in ipairs({ 20, 33, 44 }) do
		table.insert(B.loot, CFrame.new(14, ROOM_FLOOR, z))
	end
	return room
end

--------------------------------------------------------------------------------
-- The motor pool
--------------------------------------------------------------------------------

-- Bays are LANE_PITCH apart, so each one's way out is the biggest vehicle's width and 6 more
-- (Oliver, 2026-09-24: "the bots struggle to drive out of the base due to poles in the way"): nothing
-- stands in a lane from a bay's tail out through its gate, and no parked neighbour is in it either.
local FRONT_Z = -30
local FRONT_BAYS = { LANE_X0 + LANE_PITCH / 2, LANE_X0 + LANE_PITCH * 1.5, LANE_X0 + LANE_PITCH * 2.5, LANE_X0 + LANE_PITCH * 3.5 }
local EAST_X = 35.5
local EAST_BAYS = { EAST_Z0 + LANE_PITCH / 2, EAST_Z0 + LANE_PITCH * 1.5, EAST_Z0 + LANE_PITCH * 2.5 }
local BAY_HALF_LENGTH = 9.3

-- The team's number on a bay: a painted square and up to three white pips a row.
local function bayNumber(yard, number, x, z)
	groundMark(yard, "TeamBayNumber", x, z, 2.6, 2.6, 0, B.team, MAT.SmoothPlastic, 0)
	local rows = math.ceil(number / 3)
	for pip = 1, number do
		local row = math.floor((pip - 1) / 3)
		local inRow = math.min(3, number - row * 3)
		local col = (pip - 1) % 3
		local px = x + (col - (inRow - 1) / 2) * 0.7
		local pz = z + (row - (rows - 1) / 2) * 0.7
		put(yard, "BayPip", Vector3.new(0.12, 0.5, 0.5), CFrame.new(px, TILE_TOP + 0.08, pz) * CFrame.Angles(0, 0, math.pi / 2),
			WHITE_PAINT, MAT.SmoothPlastic, trimWith({ shape = Enum.PartType.Cylinder }))
	end
end

local function buildYard(model)
	local yard = Instance.new("Model")
	yard.Name = "VehicleYard"
	yard.Parent = model

	-- The front row: four bays side by side, noses to the gatehouse.
	for index = 0, #FRONT_BAYS do
		local x = LANE_X0 + index * LANE_PITCH + (index == 0 and 0.3 or index == #FRONT_BAYS and -0.3 or 0)
		local line = groundMark(yard, "BayLine", x, FRONT_Z, 0.3, BAY_HALF_LENGTH * 2, 0, YELLOW_PAINT, MAT.SmoothPlastic, 0)
		if not yard.PrimaryPart then
			yard.PrimaryPart = line
		end
	end
	for number, x in ipairs(FRONT_BAYS) do
		table.insert(B.bays, { name = "Bay" .. number, at = CFrame.new(x, TILE_TOP, FRONT_Z) })
		bayNumber(yard, number, x, FRONT_Z + BAY_HALF_LENGTH - 1.2)
		groundDisc(yard, "OilStain", x + rnd(-1.5, 1.5), FRONT_Z + rnd(-3, 3), rnd(1.8, 2.8), SOOT, MAT.Slate, 1)
	end
	-- The east row: three bays against the armoury, noses to the east gate.
	for index = 0, #EAST_BAYS do
		local z = EAST_Z0 + index * LANE_PITCH + (index == 0 and 0.3 or index == #EAST_BAYS and -0.3 or 0)
		groundMark(yard, "BayLine", EAST_X, z, BAY_HALF_LENGTH * 2, 0.3, 0, YELLOW_PAINT, MAT.SmoothPlastic, 0)
	end
	for index, z in ipairs(EAST_BAYS) do
		local number = #FRONT_BAYS + index
		table.insert(B.bays, { name = "Bay" .. number, at = CFrame.new(EAST_X, TILE_TOP, z) * CFrame.Angles(0, -math.pi / 2, 0) })
		bayNumber(yard, number, EAST_X - BAY_HALF_LENGTH + 1.2, z)
		groundDisc(yard, "OilStain", EAST_X + rnd(-3, 3), z + rnd(-1.5, 1.5), rnd(1.8, 2.8), SOOT, MAT.Slate, 1)
	end

	-- THE CANOPY over the front row, cable-stayed: masts well BEHIND the bays' tails (on the lane lines,
	-- out of every way out), beams reaching forward over the bays from them, stays from the mast heads
	-- to the beam tips, camouflage netting between the beams. Only the masts are solid; the beams, the
	-- stays and the net are dressing over the lanes (nothing to hit, nothing for a footing ray).
	local mastZ, tipZ, beamY = FRONT_Z + BAY_HALF_LENGTH + 8, FRONT_Z - BAY_HALF_LENGTH + 1, 12.6
	local masts = {}
	for index = 0, #FRONT_BAYS do
		table.insert(masts, LANE_X0 + index * LANE_PITCH + (index == 0 and 0.6 or index == #FRONT_BAYS and -0.6 or 0))
	end
	for _, x in ipairs(masts) do
		box(yard, "CanopyMast", x - 0.45, x + 0.45, TILE_TOP + 0.2, 17, mastZ - 0.45, mastZ + 0.45, OLIVE, MAT.Metal)
		box(yard, "MastFoot", x - 0.9, x + 0.9, TILE_TOP, TILE_TOP + 0.6, mastZ - 0.9, mastZ + 0.9, CONCRETE_LIGHT, MAT.Concrete)
		plateBetween(yard, "CanopyBeam", Vector3.new(x, beamY, mastZ + 0.6), Vector3.new(x, beamY, tipZ), 0.5, 0.7, STEEL_DARK, MAT.Metal, TRIM)
		rod(yard, "CanopyStay", Vector3.new(x, 16.6, mastZ - 0.2), Vector3.new(x, beamY + 0.3, tipZ + 0.3), 0.14, RUBBER, MAT.Plastic, TRIM)
		rod(yard, "CanopyStay", Vector3.new(x, 16.2, mastZ - 0.2), Vector3.new(x, beamY + 0.3, (mastZ + tipZ) / 2), 0.14, RUBBER, MAT.Plastic, TRIM)
	end
	local netOpts = trimWith({ transparency = 0.12 })
	for index = 1, #masts - 1 do
		local a0, a1 = masts[index] + 0.3, masts[index + 1] - 0.3
		local color = index % 2 == 0 and mix(NET, OLIVE, 0.5) or NET
		local sag = FRONT_Z
		plateBetween(yard, "CamoNet", Vector3.new((a0 + a1) / 2, beamY + 0.4, mastZ - 0.6), Vector3.new((a0 + a1) / 2, beamY - 0.5, sag), a1 - a0, 0.1,
			color, MAT.Fabric, netOpts)
		plateBetween(yard, "CamoNet", Vector3.new((a0 + a1) / 2, beamY - 0.5, sag - 0.5), Vector3.new((a0 + a1) / 2, beamY + 0.4, tipZ + 0.4),
			a1 - a0 - 0.2, 0.1, color, MAT.Fabric, netOpts)
		for _, t in ipairs({ 0.3, 0.7 }) do
			local a = a0 + (a1 - a0) * t
			box(yard, "NetScrim", a - 0.35, a + 0.35, beamY - 1.6, beamY + 0.2, tipZ + 0.2, tipZ + 0.26, OLIVE, MAT.Fabric, TRIM)
		end
	end
	-- Floodlights on the two end masts, looking over the bays.
	for _, x in ipairs({ masts[1], masts[#masts] }) do
		local head = box(yard, "WorkLamp", x - 0.6, x + 0.6, 14.6, 15.6, mastZ - 1.35, mastZ - 0.45, STEEL_DARK, MAT.Metal, TRIM)
		local _ = head
		local glass = box(yard, "WorkLampGlass", x - 0.45, x + 0.45, 14.75, 15.45, mastZ - 1.5, mastZ - 1.35, WARM, MAT.Neon, TRIM)
		light(glass, WARM, 30, 1.3)
	end

	-- Where a thrown defense may not go up: each bay and its way out, the lane's full width, out to
	-- DRIVE_OUT past the compound's middle. Invisible, and nothing else can meet them. DefensePlacement
	-- reads the "NoBuild" tag.
	local CollectionService = game:GetService("CollectionService")
	local laneHalf, low, high = LANE_PITCH / 2 - 0.05, -5.95, 13.95
	local function noBuild(x0, x1, z0, z1)
		local part = box(yard, "NoBuildLane", x0, x1, low, high, z0, z1, CONCRETE_LIGHT, MAT.SmoothPlastic)
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part:SetAttribute("NoBuildReason", "Keep the vehicle bays' way out clear.")
		CollectionService:AddTag(part, "NoBuild")
	end
	for _, x in ipairs(FRONT_BAYS) do
		noBuild(x - laneHalf, x + laneHalf, -DRIVE_OUT, FRONT_Z + BAY_HALF_LENGTH + 0.37)
	end
	for _, z in ipairs(EAST_BAYS) do
		noBuild(EAST_X - BAY_HALF_LENGTH - 0.37, DRIVE_OUT, z - laneHalf, z + laneHalf)
	end

	-- The apron between the rows: the fuel point by the east wall, the workshop against the armoury,
	-- tyres and drums at the edges, all clear of every lane.
	local fuel = { tag = "Prop:fuel" }
	box(yard, "FuelPump", 61.6, 63.4, TILE_TOP, TILE_TOP + 4.2, -9.2, -7.6, mix(YELLOW_PAINT, RUST, 0.2), MAT.Metal, fuel)
	box(yard, "FuelPumpFace", 61.4, 61.6, TILE_TOP + 2.2, TILE_TOP + 3.6, -9, -7.8, SOOT, MAT.Slate, trimWith(fuel))
	rod(yard, "FuelHose", Vector3.new(61.5, TILE_TOP + 2.4, -7.5), Vector3.new(60.8, TILE_TOP + 0.9, -6.2), 0.25, RUBBER, MAT.Plastic, trimWith(fuel))
	box(yard, "FuelTankCradle", 58.4, 64.6, TILE_TOP, TILE_TOP + 0.8, -2.6, -1.8, STEEL_DARK, MAT.Metal, fuel)
	box(yard, "FuelTankCradle", 58.4, 64.6, TILE_TOP, TILE_TOP + 0.8, 1.8, 2.6, STEEL_DARK, MAT.Metal, fuel)
	rod(yard, "FuelTank", Vector3.new(61.5, TILE_TOP + 2.2, -3.4), Vector3.new(61.5, TILE_TOP + 2.2, 3.4), 3.2, mix(OLIVE, STEEL, 0.3), MAT.Metal, fuel)
	facePlate(yard, "TeamTankStripe", "x", 59.9, -1, 0.08, -3, 3, TILE_TOP + 2.0, TILE_TOP + 2.5, B.team, MAT.SmoothPlastic, trimWith(fuel))
	local drum = { tag = "Prop:drums" }
	for index, at in ipairs({ { 64.1, -16.2 }, { 64.1, -18.3 }, { 61.9, -16.6 } }) do
		rod(yard, "Drum", Vector3.new(at[1], TILE_TOP, at[2]), Vector3.new(at[1], TILE_TOP + 2.8, at[2]), 1.8,
			index == 2 and OLIVE or mix(RUST, BRICK, 0.4), MAT.CorrodedMetal, drum)
	end
	local bench = { tag = "Prop:bench" }
	box(yard, "Workbench", 4.8, 9.8, TILE_TOP + 2.9, TILE_TOP + 3.2, 5.4, 7.4, WOOD, MAT.WoodPlanks, bench)
	for _, x in ipairs({ 5.0, 9.3 }) do
		for _, z in ipairs({ 5.6, 6.9 }) do
			box(yard, "BenchLeg", x, x + 0.3, TILE_TOP, TILE_TOP + 2.9, z, z + 0.3, WOOD_DARK, MAT.WoodPlanks, bench)
		end
	end
	box(yard, "Toolbox", 5.4, 7.2, TILE_TOP + 3.2, TILE_TOP + 4.1, 5.8, 6.7, BRICK, MAT.Metal, trimWith(bench))
	box(yard, "Vice", 8.4, 9.2, TILE_TOP + 3.2, TILE_TOP + 3.9, 5.5, 6.1, STEEL, MAT.Metal, trimWith(bench))
	local function tyres(x, z, count, tag)
		for index = 1, count do
			local y = TILE_TOP + (index - 1) * 0.9
			rod(yard, "Tyre", Vector3.new(x, y, z), Vector3.new(x, y + 0.9, z), 2.4, RUBBER, MAT.Plastic, { tag = "Prop:" .. tag })
		end
		disc(yard, "TyreHole", Vector3.new(x, TILE_TOP + count * 0.9, z), Vector3.new(0, 1, 0), 0.06, 1.2, SOOT, MAT.Slate, trimWith({ tag = "Prop:" .. tag }))
	end
	tyres(20.5, 5.6, 3, "tyresA")
	tyres(23.2, 3.4, 2, "tyresB")

	-- Jersey barriers between the parade ground and the pool, with gaps to walk through.
	for index, span in ipairs({ { -46, -40 }, { -34, -28 }, { -18, -12 } }) do
		local opts = { tag = "Barrier:" .. index }
		box(yard, "Barrier", -0.8, 0.8, TILE_TOP, TILE_TOP + 1.0, span[1], span[2], CONCRETE_LIGHT, MAT.Concrete, opts)
		box(yard, "Barrier", -0.45, 0.45, TILE_TOP + 1.0, TILE_TOP + 2.9, span[1] + 0.1, span[2] - 0.1, CONCRETE_LIGHT, MAT.Concrete, opts)
		facePlate(yard, "TeamBarrierPaint", "x", -0.45, -1, 0.08, span[1] + 0.8, span[2] - 0.8, TILE_TOP + 1.9, TILE_TOP + 2.5, B.team,
			MAT.SmoothPlastic, trimWith({ tag = opts.tag }))
	end

	table.insert(B.chests, { name = "YardWorkbench", at = CFrame.new(6.5, TILE_TOP, 1.2) })
	table.insert(B.chests, { name = "FuelPoint", at = CFrame.new(54, TILE_TOP, -8) })
	for _, at in ipairs({ { 12, -10 }, { 30, -4 }, { 44, -12 }, { 52, 2 } }) do
		table.insert(B.loot, CFrame.new(at[1], TILE_TOP, at[2]))
	end
	return yard
end

--------------------------------------------------------------------------------
-- The parade ground: watchtower, ops room, flag, cover
--------------------------------------------------------------------------------

-- The watchtower in the front-west corner: steel legs, a plank deck with sandbags, a searchlight,
-- a tin roof, a ladder. One pool (the Model is tagged), so when it goes it goes whole.
local function buildTower(model)
	local tower = Instance.new("Model")
	tower.Name = "Watchtower"
	tower:SetAttribute("Destructible", "Shelter")
	tower.Parent = model
	local x0, x1, z0, z1 = -63.4, -56.6, -52.2, -45.4
	local deck = 9.6
	for _, leg in ipairs({ { x0, z0, 14.4 }, { x0, z1, 14.4 }, { x1, z0, 14.4 }, { x1, z1, 14.4 } }) do
		box(tower, "TowerLeg", leg[1] - 0.4, leg[1] + 0.4, 0, leg[3], leg[2] - 0.4, leg[2] + 0.4, STEEL, MAT.Metal)
	end
	box(tower, "TowerDeck", x0 - 0.3, x1 + 0.3, deck - 0.6, deck, z0 - 0.3, z1 + 0.3, WOOD_DARK, MAT.WoodPlanks)
	local function brace(a, b)
		plateBetween(tower, "TowerBrace", a, b, 0.25, 0.25, STEEL_DARK, MAT.Metal)
	end
	brace(Vector3.new(x0, 0.9, z1 + 0.1), Vector3.new(x1, deck - 1, z1 + 0.1))
	brace(Vector3.new(x1, 0.9, z1 - 0.12), Vector3.new(x0, deck - 1, z1 - 0.12))
	box(tower, "TowerRail", x0 + 0.4, x1 - 0.4, deck + 0.8, deck + 1.1, z0 - 0.15, z0 + 0.15, STEEL, MAT.Metal)
	box(tower, "TowerRail", x0 - 0.15, x0 + 0.15, deck + 0.8, deck + 1.1, z0 + 0.4, z1 - 0.4, STEEL, MAT.Metal)
	sandbags(tower, "tower", x0 + 0.7, z0 + 0.7, x1 - 0.7, z0 + 0.7, 1, deck)
	box(tower, "SearchlightStand", x1 - 1.6, x1 - 0.8, deck, deck + 1.2, z0 + 2.6, z0 + 3.4, STEEL_DARK, MAT.Metal)
	rod(tower, "Searchlight", Vector3.new(x1 - 1.2, deck + 1.7, z0 + 3.6), Vector3.new(x1 - 1.2, deck + 1.7, z0 + 2.0), 1.2, STEEL_DARK, MAT.Metal)
	local glass = disc(tower, "SearchlightGlass", Vector3.new(x1 - 1.2, deck + 1.7, z0 + 2.0), Vector3.new(0, 0, -1), 0.08, 1.0, WARM, MAT.Neon)
	light(glass, WARM, 22, 1.2)
	-- A pitched tin roof on the four legs.
	local mid = (x0 + x1) / 2
	for _, s in ipairs({ -1, 1 }) do
		plateBetween(tower, "TowerRoof", Vector3.new(mid + s * ((x1 - x0) / 2 + 0.8), 14.25, (z0 + z1) / 2), Vector3.new(mid, 16.0 + (s > 0 and 0.06 or 0), (z0 + z1) / 2),
			z1 - z0 + (s < 0 and 1.6 or 1.4), 0.25, s < 0 and mix(STEEL, RUST, 0.5) or mix(STEEL, RUST, 0.35), MAT.CorrodedMetal)
	end
	rod(tower, "PennantPole", Vector3.new(x0, 14.4, z0), Vector3.new(x0, 18.2, z0), 0.2, STEEL, MAT.Metal)
	box(tower, "TeamPennant", x0 + 0.05, x0 + 2.6, 16.9, 18.1, z0 - 0.04, z0 + 0.04, B.team, MAT.Fabric, TRIM)
	local ladder = Instance.new("TrussPart")
	ladder.Name = "TowerLadder"
	ladder.Anchored = true
	ladder.Size = Vector3.new(2, 10, 2)
	ladder.CFrame = B.frame * CFrame.new(x1 + 1.4, 5, z0 + 1.4)
	ladder.Color = STEEL
	ladder.Material = MAT.Metal
	ladder.Parent = tower
	table.insert(B.chests, { name = "TowerBase", at = CFrame.new(mid, TILE_TOP, (z0 + z1) / 2) })
	return tower
end

-- The ops room: a one-storey brick block with a broken second storey on its north-west corner, a
-- flat roof, a door on the east and on the north, a window on the south.
local function buildOps(model)
	local ops = Instance.new("Model")
	ops.Name = "OpsRoom"
	ops.Parent = model
	local x0, x1, z0, z1 = -60, -44, -26, -10
	local top = 9
	box(ops, "Foundation", x0 + 1.2, x1 - 1.2, -0.6, ROOM_FLOOR, z0 + 1.2, z1 - 1.2, CONCRETE_DARK, MAT.Concrete)
	box(ops, "Foundation", x1 - 1.2, x1, -0.6, ROOM_FLOOR, -21, -15, CONCRETE_DARK, MAT.Concrete)
	box(ops, "Foundation", -54, -48, -0.6, ROOM_FLOOR, z1 - 1.2, z1, CONCRETE_DARK, MAT.Concrete)
	local function w(axis, u0, u1, c, t, style)
		style.color = style.color or BRICK
		style.material = style.material or MAT.Brick
		style.wire = false
		style.soot = false
		style.health = 150
		return wallPanel(ops, axis, u0, u1, c, 1.2, t, style)
	end
	-- South, with a window at x -54..-50 (sill 3.2, head 6.2).
	w("x", x0, -54, z0 + 0.6, top, { out = -1, stripe = true, plain = true })
	w("x", -50, x1, z0 + 0.6, top, { out = -1, stripe = true, plain = true })
	box(ops, "Wall", -54, -50, -1, 3.2, z0, z0 + 1.2, BRICK, MAT.Brick, { health = 150 })
	box(ops, "Wall", -54, -50, 6.2, top, z0, z0 + 1.2, BRICK, MAT.Brick, { health = 150 })
	box(ops, "WindowSill", -54.3, -49.7, 3.2, 3.5, z0 - 0.3, z0 + 1.1, CONCRETE_LIGHT, MAT.Concrete, TRIM)
	-- West.
	w("z", z0 + 1.2, z1 - 1.2, x0 + 0.6, top, { out = -1, plain = true, brick = true })
	-- East, the door at z -21..-15.
	w("z", z0 + 1.2, -21, x1 - 0.6, top, { out = 1, plain = true })
	w("z", -15, z1 - 1.2, x1 - 0.6, top, { out = 1, plain = true })
	box(ops, "Wall", x1 - 1.2, x1, 8, top, -21, -15, BRICK, MAT.Brick, { health = 150 })
	table.insert(B.doorways, { name = "OpsEast", x0 = x1 - 1.2, x1 = x1, z0 = -21, z1 = -15, floor = ROOM_FLOOR, top = 8 })
	-- North, the door at x -54..-48.
	w("x", x0, -54, z1 - 0.6, top, { out = 1, plain = true })
	w("x", -48, x1, z1 - 0.6, top, { out = 1, plain = true })
	box(ops, "Wall", -54, -48, 8, top, z1 - 1.2, z1, BRICK, MAT.Brick, { health = 150 })
	table.insert(B.doorways, { name = "OpsNorth", x0 = -54, x1 = -48, z0 = z1 - 1.2, z1 = z1, floor = ROOM_FLOOR, top = 8 })
	-- The roof, a parapet with a broken run, the stub of the storey above on the north-west corner.
	box(ops, "Roof", x0, x1, top, top + 0.6, z0, z1, CONCRETE_DARK, MAT.Concrete, { health = 200 })
	box(ops, "Parapet", x0, x1, top + 0.6, top + 1.4, z0, z0 + 0.6, BRICK_DARK, MAT.Brick)
	box(ops, "Parapet", x1 - 0.6, x1, top + 0.6, top + 1.2, z0 + 0.6, -16, BRICK_DARK, MAT.Brick)
	box(ops, "Wall", x0, -53, top + 0.6, top + 5.4, z1 - 1.2, z1, BRICK_DARK, MAT.Brick, { health = 150 })
	box(ops, "Wall", x0, x0 + 1.2, top + 0.6, top + 4.2, -17, z1 - 1.2, BRICK_DARK, MAT.Brick, { health = 150 })
	rebar(ops, Vector3.new(-53.5, top + 5.4, z1 - 0.6), 1.6, 0.3, 0.4)
	rebar(ops, Vector3.new(-56.5, top + 5.4, z1 - 0.6), 1.2, 0.5, 2.1)
	rebar(ops, Vector3.new(x0 + 0.6, top + 4.2, -16.4), 1.4, 0.4, 1.2)
	rubble(ops, -46, -6.4, 1.6, 4, TILE_TOP, { BRICK, BRICK_DARK, CONCRETE_DARK })
	-- Inside: a map table, a board with the insignia, a lamp, the chest.
	local table_ = { tag = "Prop:mapTable" }
	box(ops, "MapTable", -58.4, -55.4, ROOM_FLOOR + 2.6, ROOM_FLOOR + 2.9, -24.4, -20.4, WOOD, MAT.WoodPlanks, table_)
	for _, leg in ipairs({ { -58.2, -24.2 }, { -55.9, -24.2 }, { -58.2, -21.1 }, { -55.9, -21.1 } }) do
		box(ops, "TableLeg", leg[1], leg[1] + 0.3, ROOM_FLOOR, ROOM_FLOOR + 2.6, leg[2], leg[2] + 0.3, WOOD_DARK, MAT.WoodPlanks, table_)
	end
	box(ops, "MapSheet", -58.1, -55.7, ROOM_FLOOR + 2.9, ROOM_FLOOR + 3.0, -24.1, -20.7, mix(CANVAS, WHITE_PAINT, 0.4), MAT.Fabric, trimWith(table_))
	box(ops, "Board", x0 + 1.2, x0 + 1.6, 3.35, 7.05, -16, -11.8, WOOD_DARK, MAT.WoodPlanks, TRIM)
	insignia(ops, Vector3.new(x0 + 1.6, 5.2, -13.9), Vector3.new(1, 0, 0), 2.2, B.team)
	wallLamp(ops, Vector3.new(-52, 7.4, z0 + 1.2), Vector3.new(0, 0, 1), 14)
	table.insert(B.chests, { name = "OpsRoom", at = CFrame.new(-50, ROOM_FLOOR, -16.5) })
	table.insert(B.loot, CFrame.new(-54, ROOM_FLOOR, -15))
	return ops
end

local function buildCourtyard(model)
	local yard = Instance.new("Model")
	yard.Name = "Courtyard"
	yard.Parent = model

	-- The flag on its plinth, the team's colours with the insignia on them.
	box(yard, "FlagPlinth", -31.6, -28.4, TILE_TOP - 0.3, TILE_TOP + 1.2, -3.6, -0.4, CONCRETE_LIGHT, MAT.Concrete, { tag = "Prop:flag" })
	box(yard, "FlagPlinthCap", -31.8, -28.2, TILE_TOP + 1.2, TILE_TOP + 1.5, -3.8, -0.2, CONCRETE, MAT.Concrete, { tag = "Prop:flag" })
	rod(yard, "FlagPole", Vector3.new(-30, TILE_TOP + 1.5, -2), Vector3.new(-30, 17.5, -2), 0.35, STEEL, MAT.Metal, { tag = "Prop:flag" })
	box(yard, "TeamFlag", -29.8, -24.6, 13.2, 17.0, -2.07, -1.93, B.team, MAT.Fabric, trimWith({ tag = "Prop:flag" }))
	insignia(yard, Vector3.new(-27.2, 15.1, -2.07), Vector3.new(0, 0, -1), 2.2, mix(B.team, SOOT, 0.55), { tag = "Prop:flag" })

	-- The machine-gun nest behind the front wall, sandbagged on three sides.
	sandbags(yard, "nestFront", -24, -WZ + 3.4, -14, -WZ + 3.4, 3, TILE_TOP)
	sandbags(yard, "nestWest", -24.6, -WZ + 4.6, -24.6, -WZ + 8.8, 2, TILE_TOP)
	sandbags(yard, "nestEast", -13.4, -WZ + 4.6, -13.4, -WZ + 8.8, 2, TILE_TOP)
	table.insert(B.chests, { name = "MachineGunNest", at = CFrame.new(-19, TILE_TOP, -WZ + 7.2) })

	-- A blast wall of concrete T-sections in front of the hall's doors, with gaps between them: cover
	-- for anyone stepping off the pads, and no straight line from the foot gate onto a door.
	for index, x in ipairs({ -53, -38, -23 }) do
		local opts = { tag = "BlastWall:" .. index }
		box(yard, "BlastWall", x - 4, x + 4, TILE_TOP - 0.2, 6.4, 12.4, 13.4, CONCRETE_LIGHT, MAT.Concrete, opts)
		box(yard, "BlastWallFoot", x - 4.3, x + 4.3, TILE_TOP - 0.3, TILE_TOP + 0.6, 11.3, 14.5, CONCRETE, MAT.Concrete, opts)
		facePlate(yard, "TeamBlastPaint", "z", 12.4, -1, 0.08, x - 3.4, x + 3.4, 4.6, 5.3, B.team, MAT.SmoothPlastic, trimWith(opts))
		facePlate(yard, "Scorch", "z", 12.4, -1, 0.16, x - 2.6 + index, x - 0.4 + index, 1.0, 4.2, SOOT, MAT.Slate, trimWith(opts))
	end

	-- Cover across the open ground: jersey barriers and sandbag crescents, crate stacks, tank traps.
	for index, b in ipairs({ { -52, -36, -46, -36 }, { -30, -24, -24, -24 }, { -14, -30, -8, -30 }, { -44, -2, -38, -2 } }) do
		local opts = { tag = "Barrier:c" .. index }
		box(yard, "Barrier", b[1], b[3], TILE_TOP, TILE_TOP + 1.0, b[2] - 0.8, b[2] + 0.8, CONCRETE_LIGHT, MAT.Concrete, opts)
		box(yard, "Barrier", b[1] + 0.1, b[3] - 0.1, TILE_TOP + 1.0, TILE_TOP + 2.9, b[2] - 0.45, b[2] + 0.45, CONCRETE_LIGHT, MAT.Concrete, opts)
	end
	sandbags(yard, "coverA", -40, -32, -34, -32, 3, TILE_TOP)
	sandbags(yard, "coverB", -20, 2, -14, 2, 3, TILE_TOP)
	sandbags(yard, "coverC", -10, -16, -10, -10, 3, TILE_TOP)
	local crates = { tag = "Crate:yardA" }
	box(yard, "Crate", -24, -21, TILE_TOP, TILE_TOP + 3, -40, -37, WOOD, MAT.WoodPlanks, crates)
	box(yard, "Crate", -20.9, -17.9, TILE_TOP, TILE_TOP + 3, -40, -37, WOOD_DARK, MAT.WoodPlanks, crates)
	box(yard, "Crate", -23, -20, TILE_TOP + 3, TILE_TOP + 5.6, -39.8, -37.2, WOOD, MAT.WoodPlanks, crates)
	local crates2 = { tag = "Crate:yardB" }
	box(yard, "Crate", -60, -57, TILE_TOP, TILE_TOP + 3, -34, -31, WOOD_DARK, MAT.WoodPlanks, crates2)
	put(yard, "Crate", Vector3.new(2.4, 2.4, 2.4), CFrame.new(-55.2, TILE_TOP + 1.2, -32.4) * CFrame.Angles(0, 0.35, 0), WOOD, MAT.WoodPlanks, crates2)
	for index, at in ipairs({ { -50, -42 }, { -8, -40 } }) do
		local opts = { tag = "Prop:trap" .. index }
		for k = 0, 2 do
			local yaw = k * math.pi / 3 + 0.2
			put(yard, "TankTrap", Vector3.new(4.2, 0.45, 0.45), CFrame.new(at[1], TILE_TOP + 1.25, at[2]) * CFrame.Angles(0, yaw, 0.62 * (k == 1 and -1 or 1)),
				mix(STEEL, RUST, 0.6), MAT.CorrodedMetal, opts)
		end
	end

	-- The lean-to against the west wall: posts, a canvas roof, crates under it.
	local lean = { tag = "Shelter:leanTo" }
	for _, z in ipairs({ 0.6, 13.4 }) do
		box(yard, "LeanPost", -58.6, -58.0, TILE_TOP, 6.4, z - 0.3, z + 0.3, WOOD_DARK, MAT.WoodPlanks, lean)
	end
	plateBetween(yard, "LeanRoof", Vector3.new(-WX + 0.8, 7.6, 7), Vector3.new(-57.6, 6.35, 7), 14.2, 0.2, CANVAS, MAT.Fabric, lean)
	box(yard, "Crate", -64.4, -62.0, TILE_TOP, TILE_TOP + 2.4, 11, 13.4, WOOD, MAT.WoodPlanks, { tag = "Crate:lean" })
	table.insert(B.chests, { name = "LeanTo", at = CFrame.new(-61.8, TILE_TOP, 6.4) })

	-- The rest of the chest spots in the open, and the loot.
	table.insert(B.chests, { name = "FootGate", at = CFrame.new(-44, TILE_TOP, -WZ + 5) })
	table.insert(B.chests, { name = "FlagCache", at = CFrame.new(-24, TILE_TOP, -2) })
	table.insert(B.chests, { name = "CourtyardEast", at = CFrame.new(-7, TILE_TOP, -24) })
	table.insert(B.chests, { name = "HallPorchWest", at = CFrame.new(-61, TILE_TOP, 18.5) })
	table.insert(B.chests, { name = "HallPorchEast", at = CFrame.new(-12.5, TILE_TOP, 18.5) })
	table.insert(B.chests, { name = "Alley", at = CFrame.new(-1.5, TILE_TOP, 48) })
	for _, at in ipairs({ { -40, -42 }, { -30, -46 }, { -8, -48 }, { -36, -20 }, { -20, -18 }, { -10, -4 }, { -48, 6 },
		{ -30, 7 }, { -8, 12 }, { -46, 19 }, { -30, 19 }, { -1.5, 30 }, { -1.5, 40 } }) do
		table.insert(B.loot, CFrame.new(at[1], TILE_TOP, at[2]))
	end
	return yard
end

--------------------------------------------------------------------------------
-- Layout and Build
--------------------------------------------------------------------------------

-- The whole compound, built in `frame` (its origin on the ground at the centre, LookVector to the
-- arena), parented to nothing. Returns the model and the lists in LOCAL space as well as world.
function TeamBaseRuins.Layout(frame, teamColor, seed)
	B = {
		frame = frame,
		-- Where this build stands, to the stud: the suffix that keeps its pools its own.
		site = string.format("%d,%d", math.floor(frame.Position.X + 0.5), math.floor(frame.Position.Z + 0.5)),
		rng = Random.new(seed or 1),
		team = teamColor,
		pads = {},
		chests = {},
		bays = {},
		loot = {},
		doorways = {},
	}
	local model = Instance.new("Model")
	model.Name = "TeamBase"
	buildGround(model)
	buildPerimeter(model)
	buildGates(model)
	buildHall(model)
	buildArmoury(model)
	buildYard(model)
	buildTower(model)
	buildOps(model)
	buildCourtyard(model)

	-- The ways out on foot, just outside each (local x, z): every one reachable from every pad.
	local exits = {
		{ name = "foot gate", x = -33, z = -WZ - 4 },
		{ name = "gatehouse", x = (LANE_X0 + LANE_X1) / 2, z = -WZ - 4 },
		{ name = "west breach", x = -WX - 4, z = -10 },
		{ name = "east gate", x = WX + 4, z = (EAST_Z0 + EAST_Z1) / 2 },
	}
	local info = { frame = frame, pads = {}, chestSpots = {}, vehicleBays = {}, lootSpots = {}, names = { chests = {}, bays = {} },
		localPads = B.pads, localChests = {}, localBays = {}, localLoot = B.loot, doorways = B.doorways, exits = exits }
	for _, pad in ipairs(B.pads) do
		table.insert(info.pads, frame * pad)
	end
	for _, chest in ipairs(B.chests) do
		table.insert(info.chestSpots, frame * chest.at)
		table.insert(info.localChests, chest.at)
		table.insert(info.names.chests, chest.name)
	end
	for _, bay in ipairs(B.bays) do
		table.insert(info.vehicleBays, frame * bay.at)
		table.insert(info.localBays, bay.at)
		table.insert(info.names.bays, bay.name)
	end
	for _, spot in ipairs(B.loot) do
		table.insert(info.lootSpots, frame * spot)
	end
	B = nil
	return model, info
end

-- The site's frame, flat, from any CFrame: its position and its yaw only.
local function flatFrame(cframe)
	local look = cframe.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local position = cframe.Position
	return CFrame.new(position.X, position.Y, position.Z) * CFrame.Angles(0, yaw, 0), yaw
end

-- The thing in the map that `part` belongs to: its ancestor two levels under the map (a building in
-- a town, a tree in the props), or the part itself when it sits straight in a map folder.
local function itemOf(part, map)
	local node = part
	while node.Parent and node.Parent ~= map and node.Parent.Parent ~= map do
		node = node.Parent
	end
	if node.Parent == map then
		return nil
	end
	if not node.Parent or KEEP[node.Parent.Name] then
		return nil
	end
	return node
end

-- The pieces of `item` that go with it: a part tagged into a group ("Tree:12") takes its whole group
-- (the trunk and the leaves of one tree share a parent with every other tree); anything else is itself.
local function piecesOf(item)
	if item:IsA("BasePart") then
		local tag = item:GetAttribute("Destructible")
		if type(tag) == "string" and string.find(tag, ":") and item.Parent then
			local group = {}
			for _, other in ipairs(item.Parent:GetChildren()) do
				if other:IsA("BasePart") and other:GetAttribute("Destructible") == tag then
					table.insert(group, other)
				end
			end
			return group
		end
	end
	return { item }
end

local function spanOf(item)
	if item:IsA("BasePart") then
		return math.max(item.Size.X, item.Size.Z)
	end
	local ok, size = pcall(function()
		return item:GetExtentsSize()
	end)
	return ok and math.max(size.X, size.Z) or math.huge
end

-- Scenery standing where the compound goes: whatever map item overlaps the footprint and margin and
-- is no bigger than ClearableSpan goes (a tree, a parked car, a shed); loot lying there goes too, or
-- it would be left inside a wall. Returns how many items went and the biggest one that stayed.
function TeamBaseRuins.ClearSite(site, map)
	if not map then
		return 0, 0
	end
	local frame = flatFrame(site)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local include = { map }
	local loot = workspace:FindFirstChild("Loot")
	if loot then
		table.insert(include, loot)
	end
	params.FilterDescendantsInstances = include
	-- Not just the footprint: FlattenPad grades the ground for up to FLATTEN_REACH beyond its flat, and
	-- a tree, a rock or a pickup standing there is left in the air (or buried) once it has.
	local reach = TeamBaseRuins.Margin + FLATTEN_REACH
	local size = Vector3.new(TeamBaseRuins.Footprint.X + reach * 2, 600, TeamBaseRuins.Footprint.Z + reach * 2)
	local cleared, kept = 0, 0
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(frame * CFrame.new(0, 100, 0), size, params)) do
		if loot and part:IsDescendantOf(loot) then
			-- The whole pickup (the loot folder's own child), not the one piece of it the query found.
			local pickup = part
			while pickup.Parent and pickup.Parent ~= loot do
				pickup = pickup.Parent
			end
			if not seen[pickup] then
				seen[pickup] = true
				pickup:Destroy()
			end
		elseif not part:GetAttribute("TeamBaseRuin") then
			local item = itemOf(part, map)
			if item and not seen[item] then
				seen[item] = true
				local span = spanOf(item)
				if span <= TeamBaseRuins.ClearableSpan then
					for _, piece in ipairs(piecesOf(item)) do
						seen[piece] = true
						piece:Destroy()
					end
					cleared += 1
				else
					kept = math.max(kept, span)
				end
			end
		end
	end
	return cleared, kept
end

--------------------------------------------------------------------------------
-- The ground, read from the voxels
--------------------------------------------------------------------------------

-- The terrain over a square of columns round `centre` (half `half` across, world axes), read once
-- between heights yLow and yHigh: each column's ground (its top solid voxel's fill, drawn
-- MapTerrain.SurfaceLift over it, exactly as MapTerrain measures every pad) and the material on top.
-- A column whose ground is above the read is `buried` and one with water over it `wet`: neither is
-- ever written, since nothing here can see its top. Columns are CELL wide, the terrain's own grid.
local function readGround(centre, half, yLow, yHigh)
	local region = Region3.new(Vector3.new(centre.X - half, yLow, centre.Z - half), Vector3.new(centre.X + half, yHigh, centre.Z + half))
		:ExpandToGrid(CELL)
	local materials, occupancies = workspace.Terrain:ReadVoxels(region, CELL)
	local size = region.Size / CELL
	local grid = {
		region = region, materials = materials, occupancies = occupancies, origin = region.CFrame.Position - region.Size / 2,
		nx = math.floor(size.X + 0.5), ny = math.floor(size.Y + 0.5), nz = math.floor(size.Z + 0.5),
		height = {}, top = {}, buried = {}, wet = {},
	}
	local lift = MapTerrain.SurfaceLift or 2
	for ix = 1, grid.nx do
		grid.height[ix], grid.top[ix], grid.buried[ix], grid.wet[ix] = {}, {}, {}, {}
		for iz = 1, grid.nz do
			for iy = grid.ny, 1, -1 do
				local occupancy = occupancies[ix][iy][iz]
				local material = materials[ix][iy][iz]
				if material == Enum.Material.Water and occupancy > 0 then
					grid.wet[ix][iz] = true
				elseif occupancy > 0 and material ~= Enum.Material.Air then
					if iy == grid.ny and occupancy >= 1 then
						grid.buried[ix][iz] = true
					else
						grid.height[ix][iz] = grid.origin.Y + (iy - 1) * CELL + occupancy * CELL + lift
						grid.top[ix][iz] = material
					end
					break
				end
			end
		end
	end
	return grid
end

-- The world position of a column's centre.
local function columnAt(grid, ix, iz)
	return grid.origin.X + (ix - 0.5) * CELL, grid.origin.Z + (iz - 0.5) * CELL
end

-- The column a world (x, z) falls in, or nil outside the read.
local function columnOf(grid, x, z)
	local ix, iz = math.floor((x - grid.origin.X) / CELL) + 1, math.floor((z - grid.origin.Z) / CELL) + 1
	if ix < 1 or iz < 1 or ix > grid.nx or iz > grid.nz then
		return nil
	end
	return ix, iz
end

-- Terrain materials whose surface lies exactly where the voxels put it (RoadNetwork.SmoothMaterials,
-- measured by tools/road_terrain_probe.lua). Rock draws its surface up to 1.1 off its voxels, Slate and
-- Basalt most of a stud: a ramp or a bank left in one of those is a washboard to drive up, so ground the
-- grading moves is repainted with the pad's own smooth ground wherever it was rough.
local SMOOTH = {
	[Enum.Material.Asphalt] = true, [Enum.Material.Glacier] = true, [Enum.Material.Grass] = true, [Enum.Material.Ground] = true,
	[Enum.Material.LeafyGrass] = true, [Enum.Material.Limestone] = true, [Enum.Material.Mud] = true, [Enum.Material.Salt] = true,
	[Enum.Material.Sand] = true, [Enum.Material.Sandstone] = true, [Enum.Material.Snow] = true,
}

-- A column's ground set to `target`, the same fill FlattenPad writes: full voxels under it, the top
-- one part-filled, air over it; new ground takes `fill`, and water is never touched. `repaint` paints
-- the whole column `fill` (its old surface was rough).
local function setColumn(grid, ix, iz, target, fill, repaint)
	local lift = MapTerrain.SurfaceLift or 2
	for iy = 1, grid.ny do
		local bottom = grid.origin.Y + (iy - 1) * CELL
		local occupancy = math.clamp((target - lift - bottom) / CELL, 0, 1)
		local was = grid.materials[ix][iy][iz]
		if was ~= Enum.Material.Water then
			grid.occupancies[ix][iy][iz] = occupancy
			if occupancy <= 0 then
				grid.materials[ix][iy][iz] = Enum.Material.Air
			elseif was == Enum.Material.Air or repaint then
				grid.materials[ix][iy][iz] = fill
			end
		end
	end
	grid.height[ix][iz] = target
end

-- The lowest and highest ground under the foundation (the footprint), read from the voxels, and how
-- far the worst column is from `height`. A column under the footprint with no ground the read can see
-- (buried, under water, or nothing at all) counts as infinitely far.
function TeamBaseRuins.GroundUnder(site, height)
	local frame = flatFrame(site)
	local reach = math.sqrt((TeamBaseRuins.Footprint.X / 2) ^ 2 + (TeamBaseRuins.Footprint.Z / 2) ^ 2) + CELL
	local grid = readGround(frame.Position, reach, height - 48, height + 48)
	local low, high, worst = math.huge, -math.huge, 0
	for ix = 1, grid.nx do
		for iz = 1, grid.nz do
			local x, z = columnAt(grid, ix, iz)
			local here = frame:PointToObjectSpace(Vector3.new(x, frame.Position.Y, z))
			if math.abs(here.X) <= TeamBaseRuins.Footprint.X / 2 and math.abs(here.Z) <= TeamBaseRuins.Footprint.Z / 2 then
				local y = grid.height[ix][iz]
				if y then
					low, high = math.min(low, y), math.max(high, y)
					worst = math.max(worst, math.abs(y - height))
				else
					worst = math.huge
				end
			end
		end
	end
	if low == math.huge then
		return nil
	end
	return low, high, worst
end

-- How far the local point (x, z) is from the pad's flat (0 on it): straight out from a side, round from
-- a corner.
function TeamBaseRuins.FlatDistance(x, z)
	local dx, dz = math.max(0, math.abs(x) - FLAT_X), math.max(0, math.abs(z) - FLAT_Z)
	return math.sqrt(dx * dx + dz * dz)
end
TeamBaseRuins.GradeBank, TeamBaseRuins.GradeGate = GRADE_BANK, GRADE_GATE
TeamBaseRuins.GradeReach = GRADE_REACH
TeamBaseRuins.GateCorridors = { front = GATE_FRONT, east = GATE_EAST, flat = Vector3.new(FLAT_X, 0, FLAT_Z) }

-- Map things the grading must go round rather than move the ground under: the roads (and everything
-- else in a KEEP folder), the towns (their streets are non-collidable slabs lying on the ground), and
-- anything too big to clear. Returns a set of column keys (ix * 65536 + iz), each such thing's plan
-- and a column round it.
local function lockedColumns(grid, map, centre, reach)
	local locked = {}
	local function lock(part)
		local cf, size = part.CFrame, part.Size
		local ex = math.abs(cf.RightVector.X) * size.X / 2 + math.abs(cf.UpVector.X) * size.Y / 2 + math.abs(cf.LookVector.X) * size.Z / 2 + CELL
		local ez = math.abs(cf.RightVector.Z) * size.X / 2 + math.abs(cf.UpVector.Z) * size.Y / 2 + math.abs(cf.LookVector.Z) * size.Z / 2 + CELL
		local p = cf.Position
		for x = p.X - ex, p.X + ex + 0.01, CELL do
			for z = p.Z - ez, p.Z + ez + 0.01, CELL do
				local ix, iz = columnOf(grid, x, z)
				if ix then
					locked[ix * 65536 + iz] = true
				end
			end
		end
	end
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") and not part:GetAttribute("TeamBaseRuin") then
			local p = part.Position
			local flat = Vector3.new(p.X - centre.X, 0, p.Z - centre.Z).Magnitude
			if flat - math.max(part.Size.X, part.Size.Z) <= reach then
				local node, keep, town = part, false, false
				while node and node ~= map do
					if node.Parent == map and KEEP[node.Name] then
						keep = true
					end
					if node:GetAttribute("TownName") ~= nil then
						town = true
					end
					node = node.Parent
				end
				local item = itemOf(part, map)
				if keep or town or (item and spanOf(item) > TeamBaseRuins.ClearableSpan) then
					lock(part)
				end
			end
		end
	end
	return locked
end

-- Whether the local point (x, z) is in a vehicle gate's corridor (in front of the main gate across its
-- span, or out of the east gate along its span), where the ground may climb only 1 in GRADE_GATE.
local function inCorridor(x, z)
	return (z < -FLAT_Z and x >= GATE_FRONT[1] and x <= GATE_FRONT[2]) or (x > FLAT_X and z >= GATE_EAST[1] and z <= GATE_EAST[2])
end

-- Holds the ground round a compound levelled at `height` to a grade: nowhere may it change faster than 1
-- in GRADE_BANK (a walk), and in each vehicle gate's corridor 1 in GRADE_GATE (a gentle drive), between
-- any two FIXED columns -- the pad's flat (at `height`), everything the work may not move (a road's
-- corridor, another pad, the river, anything locked) and the ring GRADE_REACH past the flat (as it
-- stands, so the work always meets the ground beyond it). Each free column is held between the lowest and the
-- highest ground those allow it (a weighted distance to every fixed column, swept across the grid) and
-- left alone where it already lies between them: flush at the pad, a bank or a ramp where it has to be,
-- the natural ground where it can. Where two fixed things are too close for their difference (a road
-- 20 studs from the gate and 12 below it) the ground moves as little as it can between them: the
-- steepest it ever gets, and the site's cost (SiteCost) steers the compounds off such places. `grid` is a readGround taken
-- AFTER FlattenPad; it is written back in one go. Returns stats: columns moved, the most any moved, the
-- largest difference off the pad it left, and the conflicts.
function TeamBaseRuins.GradeSurroundings(site, height, mapInfo, grid, locked)
	local frame = flatFrame(site)
	local roads = mapInfo and mapInfo.roads
	local river = mapInfo and mapInfo.river
	local fillMaterial = MapTerrain._padGround or Enum.Material.Ground
	local nx, nz = grid.nx, grid.nz
	local huge = math.huge
	local upper, lower, grade, free, band = {}, {}, {}, {}, {}
	local function key(ix, iz)
		return (ix - 1) * nz + iz
	end
	for ix = 1, nx do
		for iz = 1, nz do
			local k = key(ix, iz)
			local ground = grid.height[ix][iz]
			local x, z = columnAt(grid, ix, iz)
			local here = frame:PointToObjectSpace(Vector3.new(x, frame.Position.Y, z))
			grade[k] = inCorridor(here.X, here.Z) and 1 / GRADE_GATE or 1 / GRADE_BANK
			-- A gate corridor and 24 studs either side of it: the ground smoothed to its grade below.
			band[k] = (here.Z < -FLAT_Z + 8 and here.X >= GATE_FRONT[1] - 24 and here.X <= GATE_FRONT[2] + 24)
				or (here.X > FLAT_X - 8 and here.Z >= GATE_EAST[1] - 24 and here.Z <= GATE_EAST[2] + 24)
			upper[k], lower[k] = huge, -huge
			if ground and not grid.wet[ix][iz] and not grid.buried[ix][iz] then
				local onPad = math.max(math.abs(here.X) - FLAT_X, math.abs(here.Z) - FLAT_Z) <= 0
				local edge = ix == 1 or iz == 1 or ix == nx or iz == nz or TeamBaseRuins.FlatDistance(here.X, here.Z) >= GRADE_REACH
				if onPad then
					upper[k], lower[k] = height, height
				elseif edge or (locked and locked[ix * 65536 + iz])
					or (roads and roads.WithinCorridor and roads:WithinCorridor(x, z)) or MapTerrain.PadAt(x, z)
					or (river and MapTerrain.InRiver(river, x, z, CELL)) then
					upper[k], lower[k] = ground, ground
				else
					free[k] = true
				end
			end
		end
	end
	-- The sweep: each column's bounds from its neighbours', a step costing the grade between them times
	-- the step's length, forward then back, twice. Straight, diagonal and knight's-move steps (the 5 x 5
	-- chamfer): with straight and diagonal steps alone, ground running between those directions could
	-- come out 8% steeper than its grade; with the knight's moves, under 3%.
	local forward, backward = {}, {}
	for _, step in ipairs({ { -1, -1 }, { -1, 0 }, { -1, 1 }, { 0, -1 }, { -1, -2 }, { -1, 2 }, { -2, -1 }, { -2, 1 } }) do
		local length = CELL * math.sqrt(step[1] * step[1] + step[2] * step[2])
		table.insert(forward, { step[1], step[2], length })
		table.insert(backward, { -step[1], -step[2], length })
	end
	local function sweep(order, steps)
		local a0, a1, da = 1, nx, 1
		if order < 0 then
			a0, a1, da = nx, 1, -1
		end
		for ix = a0, a1, da do
			for iz = (order > 0 and 1 or nz), (order > 0 and nz or 1), order do
				local k = key(ix, iz)
				if free[k] then
					for _, step in ipairs(steps) do
						local jx, jz = ix + step[1], iz + step[2]
						if jx >= 1 and jx <= nx and jz >= 1 and jz <= nz then
							local j = key(jx, jz)
							local cost = (grade[k] + grade[j]) / 2 * step[3]
							if upper[j] + cost < upper[k] then
								upper[k] = upper[j] + cost
							end
							if lower[j] - cost > lower[k] then
								lower[k] = lower[j] - cost
							end
						end
					end
				end
			end
		end
	end
	for _ = 1, 2 do
		sweep(1, forward)
		sweep(-1, backward)
	end
	local stats = { moved = 0, most = 0, bank = 0, conflicts = 0 }
	local T = {}
	for ix = 1, nx do
		for iz = 1, nz do
			local k = key(ix, iz)
			if free[k] then
				local ground = grid.height[ix][iz]
				if lower[k] > upper[k] then
					-- Two fixed things too close for their difference: the ground moves as little as it can.
					T[k] = math.clamp(ground, upper[k], lower[k])
					stats.conflicts += 1
				else
					T[k] = math.clamp(ground, lower[k], upper[k])
				end
			elseif upper[k] == lower[k] then
				T[k] = upper[k]
			end
		end
	end
	-- The gate corridors smoothed to their grade: the bounds above only keep the ground within reach of
	-- the fixed things, and natural ground left inside them keeps its own bumps (a rock step across the
	-- way out, 1 in 1.4, measured in Studio). Round each gate every column of the corridor and its band
	-- is held within its grade of every neighbour (the average of the two columns' grades, as in the
	-- sweep above), sweeping both ways until it settles: the ramp is a ramp, its sides meet the ground
	-- beside them at the bank's grade, and ground further off keeps its own shape.
	for _ = 1, 4 do
		for _, order in ipairs({ 1, -1 }) do
			for ix = (order > 0 and 1 or nx), (order > 0 and nx or 1), order do
				for iz = (order > 0 and 1 or nz), (order > 0 and nz or 1), order do
					local k = key(ix, iz)
					if free[k] and band[k] and T[k] then
						local lo, hi = -huge, huge
						for dx = -1, 1 do
							for dz = -1, 1 do
								local jx, jz = ix + dx, iz + dz
								if (dx ~= 0 or dz ~= 0) and jx >= 1 and jx <= nx and jz >= 1 and jz <= nz then
									local j = key(jx, jz)
									if T[j] then
										local c = (grade[k] + grade[j]) / 2 * CELL * math.sqrt(dx * dx + dz * dz)
										hi = math.min(hi, T[j] + c)
										lo = math.max(lo, T[j] - c)
									end
								end
							end
						end
						if lo <= hi then
							T[k] = math.clamp(T[k], lo, hi)
						else
							T[k] = (lo + hi) / 2
						end
					end
				end
			end
		end
	end
	for ix = 1, nx do
		for iz = 1, nz do
			local k = key(ix, iz)
			if free[k] then
				local ground = grid.height[ix][iz]
				local target = T[k]
				if math.abs(target - ground) > 0.02 then
					local top = grid.top[ix][iz]
					local smooth = top ~= nil and SMOOTH[top] == true
					setColumn(grid, ix, iz, target, smooth and top or fillMaterial, not smooth and math.abs(target - ground) > 0.5)
					stats.moved += 1
					stats.most = math.max(stats.most, math.abs(target - ground))
					stats.bank = math.max(stats.bank, math.abs(target - height))
				end
			end
		end
	end
	if stats.moved > 0 then
		workspace.Terrain:WriteVoxels(grid.region, CELL, grid.materials, grid.occupancies)
	end
	return stats
end

-- After the ground work: map scenery standing where the ground moved (by more than GROUND_MOVED
-- against `before`, the ground as it was before FlattenPad) is taken away, since it now floats or is
-- buried. Solid things go whole (ClearSite's items, tag groups whole); non-collidable dressing --
-- flowers, ferns, grass tufts -- goes a piece at a time, because a foliage patch can be far bigger than
-- the moved ground. These are what the gallery counted "hovering" round the compounds: 14 of 27 near
-- one base, every one a Wilds flower or fern, non-queryable, so ClearSite's box query never saw them.
local GROUND_MOVED = 0.3
function TeamBaseRuins.ClearMoved(before, after, map, centre, reach)
	local cleared = 0
	local seen = {}
	local function moved(x, z)
		local ix, iz = columnOf(before, x, z)
		if not ix then
			return false
		end
		local a, b = before.height[ix][iz], after.height[ix][iz]
		return a ~= nil and b ~= nil and math.abs(a - b) > GROUND_MOVED
	end
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") and part.Parent and not seen[part] and not part:GetAttribute("TeamBaseRuin") then
			local p = part.Position
			if Vector3.new(p.X - centre.X, 0, p.Z - centre.Z).Magnitude <= reach then
				local half = part.Size / 2
				local hit = moved(p.X, p.Z)
				for _, corner in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
					if hit then
						break
					end
					local c = part.CFrame * Vector3.new(half.X * corner[1] * 0.9, 0, half.Z * corner[2] * 0.9)
					hit = moved(c.X, c.Z)
				end
				if hit then
					local item = itemOf(part, map)
					local pieces
					if not part.CanCollide and not (type(part:GetAttribute("Destructible")) == "string") then
						pieces = { part }
					elseif item and spanOf(item) <= TeamBaseRuins.ClearableSpan then
						pieces = piecesOf(item)
					end
					for _, piece in ipairs(pieces or {}) do
						seen[piece] = true
						if piece.Parent then
							piece:Destroy()
							cleared += 1
						end
					end
				end
			end
		end
	end
	return cleared
end

-- How far the ground under world (x, z) was moved by a compound's ground work (its info.graded), or nil
-- where the work never looked.
function TeamBaseRuins.MovedAt(graded, x, z)
	local m = graded and graded.heights
	if not m then
		return nil
	end
	local ix, iz = math.floor((x - m.origin.X) / CELL) + 1, math.floor((z - m.origin.Z) / CELL) + 1
	local a, b = m.before[ix] and m.before[ix][iz], m.after[ix] and m.after[ix][iz]
	return a and b and b - a or nil
end

-- How good a place `site` is for a compound, lower is better, or nil and why it cannot go there:
-- on a road's corridor, in the river, over another made pad (FlattenPad would refuse all three), or
-- nowhere with ground. The cost is the ground's rise across the footprint, plus half the rise across
-- the ground round it out to 32 studs (what the banks and the gate ramps will have to take up), plus
-- a heavy charge for anything built there too big for ClearSite to move.
function TeamBaseRuins.SiteCost(site, mapInfo)
	local frame = flatFrame(site)
	local roads = mapInfo and mapInfo.roads
	local river = mapInfo and mapInfo.river
	local halfX = TeamBaseRuins.Footprint.X / 2 + TeamBaseRuins.Margin
	local halfZ = TeamBaseRuins.Footprint.Z / 2 + TeamBaseRuins.Margin
	for x = -halfX, halfX, 8 do
		for z = -halfZ, halfZ, 8 do
			local p = frame * Vector3.new(x, 0, z)
			if roads and roads.WithinCorridor and roads:WithinCorridor(p.X, p.Z) then
				return nil, "road"
			end
			if river and MapTerrain.InRiver(river, p.X, p.Z, 6) then
				return nil, "river"
			end
			if MapTerrain.PadAt(p.X, p.Z) then
				return nil, "pad"
			end
		end
	end
	local low, high = MapTerrain.PadCost(frame, TeamBaseRuins.Footprint, { margin = TeamBaseRuins.Margin })
	if not low then
		return nil, "nothing"
	end
	local cost = high - low
	local ringLow, ringHigh = MapTerrain.PadCost(frame, TeamBaseRuins.Footprint + Vector3.new(64, 0, 64), { margin = TeamBaseRuins.Margin })
	if ringLow then
		cost += math.max(0, (ringHigh - ringLow) - (high - low)) * 0.5
	end
	-- The ground each vehicle gate's ramp has to reach, 120 out: past what 1 in GRADE_GATE takes up inside
	-- the cone's reach, the rest would drop in its fade. Charged heavily, so a gate opens onto a drive.
	local mid = (low + high) / 2
	local limit = GRADE_REACH / GRADE_GATE - 4
	local gates = {
		{ Vector3.new((GATE_FRONT[1] + GATE_FRONT[2]) / 2, 0, -FLAT_Z), Vector3.new(0, 0, -1) },
		{ Vector3.new(FLAT_X, 0, (GATE_EAST[1] + GATE_EAST[2]) / 2), Vector3.new(1, 0, 0) },
	}
	for _, gate in ipairs(gates) do
		local _, _, there = MapTerrain.PadCost(frame * CFrame.new(gate[1] + gate[2] * 120), Vector3.new(8, 0, 8), { margin = 0 })
		if there then
			cost += math.max(0, math.abs(there - mid) - limit) * 3
		end
		-- A road across the way out, nearer than its height can be met at the gate's grade: the ground
		-- between cannot be graded to it (the road stays as it is), and the ramp would end in a bank.
		if roads and roads.WithinCorridor then
			for along = 8, 120, 8 do
				local p = frame * (gate[1] + gate[2] * along)
				if roads:WithinCorridor(p.X, p.Z) then
					local _, _, road = MapTerrain.PadCost(CFrame.new(p.X, 0, p.Z), Vector3.new(4, 0, 4), { margin = 2 })
					if road and math.abs(road - mid) > along / GRADE_GATE + 1 then
						cost += 20
					end
					break
				end
			end
		end
	end
	-- The apron: a road's corridor or another pad the grading must leave as it is, nearer the flat than
	-- its height can be met at the grade (the ground between would end in a bank against it).
	for x = -FLAT_X - 48, FLAT_X + 48, 8 do
		for z = -FLAT_Z - 48, FLAT_Z + 48, 8 do
			local d = TeamBaseRuins.FlatDistance(x, z)
			if d > 0 then
				local p = frame * Vector3.new(x, 0, z)
				local fixed = (roads and roads.WithinCorridor and roads:WithinCorridor(p.X, p.Z)) or MapTerrain.PadAt(p.X, p.Z)
				if fixed then
					local _, _, there = MapTerrain.PadCost(CFrame.new(p.X, 0, p.Z), Vector3.new(4, 0, 4), { margin = 2 })
					local grade = inCorridor(x, z) and 1 / GRADE_GATE or 1 / GRADE_BANK
					if there and math.abs(there - mid) > d * grade + 1 then
						cost += 4
					end
				end
			end
		end
	end
	local map = mapInfo and mapInfo.map
	if map then
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { map }
		local seen = {}
		local size = Vector3.new(halfX * 2, 600, halfZ * 2)
		for _, part in ipairs(workspace:GetPartBoundsInBox(frame * CFrame.new(0, 100, 0), size, params)) do
			local item = itemOf(part, map)
			if item and not seen[item] then
				seen[item] = true
				cost += spanOf(item) > TeamBaseRuins.ClearableSpan and 60 or 1
			end
		end
		-- Something too big to clear in the ring the ground work reaches (a landmark's platform): the
		-- ground round it is held as it stands, and the banks meet it at a grade.
		for _, part in ipairs(workspace:GetPartBoundsInBox(frame * CFrame.new(0, 100, 0), size + Vector3.new(96, 0, 96), params)) do
			local item = itemOf(part, map)
			if item and not seen[item] then
				seen[item] = true
				cost += spanOf(item) > TeamBaseRuins.ClearableSpan and 12 or 0
			end
		end
	end
	return cost
end

-- Every spot (pads, chests, loot, bays) put on the surface really under it: a ray down from 4 studs up
-- into the compound's own parts. By construction that is where the layout put it; if the z-fight pass
-- nudged a floor, or anything else moved, the spot follows the floor rather than the plan.
function TeamBaseRuins.SnapSpots(model, list)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { model }
	for index, spot in ipairs(list) do
		local hit = workspace:Raycast(spot.Position + Vector3.new(0, 4, 0), Vector3.new(0, -8, 0), params)
		if hit then
			list[index] = spot + Vector3.new(0, hit.Position.Y - spot.Position.Y, 0)
		end
	end
end

-- Builds the compound for one team, FLUSH with the ground (Oliver, 2026-09-24: "the team bases are on
-- a platform that's raised up and needs a ramp for the players and vehicles, or it needs to be made
-- more flush to the ground"):
--   1. clears the site (and the ring round it the ground work reaches) of scenery and loot;
--   2. reads the ground round it from the voxels, levels the footprint with MapTerrain's FlattenPad
--      (the same pad every building stands on) and checks, from the voxels, that it came out level;
--   3. holds the ground round it to a grade (GradeSurroundings): banks at 1 in 3, ramps out of the
--      two vehicle gates at 1 in 8, nothing changed where the ground already lies within that;
--   4. takes away the scenery left standing where the ground moved (ClearMoved);
--   5. lays the compound out at the pad's height, puts it in the map, runs the z-fight pass and snaps
--      every spot to the real floor under it.
-- Returns the compound, or nil and why when the site cannot be levelled (a road or another pad in the
-- way, ground it cannot see): ModeTeams then tries its next site, and never builds a compound standing
-- proud of the ground. (The concrete plinth that used to stand in for a levelled site is gone: every
-- one of them was a raycast reading ground the pad had already levelled; see LEVEL_SLACK.)
function TeamBaseRuins.Build(baseCFrame, teamColor, mapInfo, seed)
	local map = (mapInfo and mapInfo.map) or workspace:FindFirstChild("Map") or workspace
	local site, yaw = flatFrame(baseCFrame)
	TeamBaseRuins.ClearSite(site, map)

	local reach = math.sqrt(FLAT_X * FLAT_X + FLAT_Z * FLAT_Z) + GRADE_REACH + CELL * 2
	local _, _, around = MapTerrain.PadCost(site, TeamBaseRuins.Footprint, { margin = TeamBaseRuins.Margin })
	around = around or site.Position.Y
	local before = readGround(site.Position, reach, around - 72, around + 72)
	local height, why = MapTerrain.FlattenPad(site, TeamBaseRuins.Footprint, { height = "mid", margin = TeamBaseRuins.Margin })
	if not height then
		return nil, "ground not levelled: " .. tostring(why)
	end
	local low, high, worst = TeamBaseRuins.GroundUnder(site, height)
	if not low or worst > LEVEL_SLACK then
		return nil, string.format("ground not level under the footprint (%s)", low and string.format("off by %.2f", worst) or "unseen")
	end
	local after = readGround(site.Position, reach, around - 72, around + 72)
	local locked = lockedColumns(after, map, site.Position, reach)
	local graded = TeamBaseRuins.GradeSurroundings(site, height, mapInfo, after, locked)
	graded.cleared = TeamBaseRuins.ClearMoved(before, after, map, site.Position, reach)
	-- How far the ground moved, column by column, for the gallery's probe (heights only: small).
	graded.heights = { origin = before.origin, before = before.height, after = after.height }

	local position = site.Position
	local frame = CFrame.new(position.X, height, position.Z) * CFrame.Angles(0, yaw, 0)
	local model, info = TeamBaseRuins.Layout(frame, teamColor, seed)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part:SetAttribute("TeamBaseRuin", true)
		end
	end
	model.Parent = map
	ZFight.Fix({ model })
	for _, key in ipairs({ "pads", "chestSpots", "lootSpots", "vehicleBays" }) do
		TeamBaseRuins.SnapSpots(model, info[key])
	end

	info.model = model
	info.height = height
	info.frame = frame
	info.graded = graded
	return info
end

return TeamBaseRuins
