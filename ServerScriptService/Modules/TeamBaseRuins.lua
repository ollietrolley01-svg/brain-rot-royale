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
-- rules through DestructibleService's own KeyOf, both bases identical, and the part budget. What
-- it cannot prove is how it looks: tools/team_base_ruins_gallery.lua is the render for that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))

local TeamBaseRuins = {}

-- The compound's footprint (X across, Z deep) and the flat ground kept round it. The rubble at the
-- breaches lies inside the margin, so it is on the flattened pad too.
TeamBaseRuins.Footprint = Vector3.new(92, 0, 84)
TeamBaseRuins.Margin = 4
-- Distinct things built in the footprint that ClearSite removes whole; bigger ones stay, and
-- SiteCost counts them against a site.
TeamBaseRuins.ClearableSpan = 70
-- Named top-level map models ClearSite never touches: taking a road or river part out would leave
-- a hole in something that runs far outside the base.
local KEEP = { Roads = true, River = true, Ziplines = true, TeamBaseVehicles = true }

-- Heights, local: the flattened ground is 0; the paving tiles' top; the bunker and supply floors.
local TILE_TOP = 0.3
local ROOM_FLOOR = 0.8

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
			part:SetAttribute("Destructible", opts.tag)
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

	-- Soot from a blast: always beside a gap, now and then elsewhere.
	if (style.low or style.slopeUp or B.rng:NextNumber() < 0.25) and length > 2.4 then
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
			-- The banner: a rod along the top of the outer face, the cloth hanging from it, the eye on it.
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
			disc(parent, "BannerEye", at(m, top - 2.6, 0.51), normal, 0.14, 2.4, WHITE_PAINT, MAT.SmoothPlastic)
			disc(parent, "BannerPupil", at(m + 0.2, top - 2.7, 0.51), normal, 0.22, 1.0, SOOT, MAT.SmoothPlastic)
		end
	end
end

--------------------------------------------------------------------------------
-- The ground
--------------------------------------------------------------------------------

-- Concrete paving over a rectangle: nx by nz slabs with 0.2 cracks of ground between them. The
-- slabs are "Paving" (DestructibleService.Never) and sunk a stud into the ground.
local function paving(parent, x0, x1, z0, z1, nx, nz, colors)
	local w, d = (x1 - x0) / nx, (z1 - z0) / nz
	for i = 1, nx do
		for j = 1, nz do
			local color = colors[B.rng:NextInteger(1, #colors)]
			box(parent, "Paving", x0 + (i - 1) * w + 0.1, x0 + i * w - 0.1, TILE_TOP - 1, TILE_TOP,
				z0 + (j - 1) * d + 0.1, z0 + j * d - 0.1, color, MAT.Concrete, { tag = false })
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

local function buildGround(model)
	local ground = Instance.new("Model")
	ground.Name = "Paving"
	ground:SetAttribute("Destructible", false)
	ground.Parent = model
	-- The courtyard and the yard + lane; the bunker and the supply room have their own floors.
	paving(ground, -44.2, 4, -40.2, 8, 4, 4, { PAVING, CONCRETE_DARK, CONCRETE })
	paving(ground, 4, 44.2, -40.2, 22, 3, 5, { PAVING, CONCRETE })

	-- Cracks across the courtyard, at least 6 apart so no two cross, and two blast marks.
	for _, at in ipairs({ { -37, -2 }, { -27, -26 }, { -14, -38 }, { -8, -12 }, { -21, 1 }, { -36, -33 }, { -13, -1 } }) do
		groundMark(ground, "Crack", at[1], at[2], rnd(2.5, 5.2), 0.22,
			B.rng:NextInteger(0, 1) * math.pi / 2 + rnd(0.15, math.pi / 2 - 0.15), SOOT, MAT.Slate, 0)
	end
	for _, blast in ipairs({ { -17, -7, 4.6 }, { -34.5, -12.5, 3.4 }, { 26, -30, 3.8 } }) do
		groundDisc(ground, "BlastMark", blast[1], blast[2], blast[3], mix(SOOT, CONCRETE_DARK, 0.35), MAT.Slate, 1)
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

	-- Front (z = -41, outside is -Z): the corner run, the breach at x -24..-17, the run to the gate.
	perimeterRun(walls, "x", -41, -45.8, -24, -1, false, true, -35)
	perimeterRun(walls, "x", -41, -17, 2.2, -1, true, false)
	-- Left (x = -45): up to the side breach at z -10..-3, then on to the bunker's own wall.
	perimeterRun(walls, "z", -45, -40.2, -10, -1, false, true, -36, { -27, -17 })
	perimeterRun(walls, "z", -45, -3, 8, -1, true, false)
	-- Right (x = +45), along the yard to the east gate at z -14.6..22 (the back row of bays drives out
	-- through it); the gate leaf leans on its inner face at z -37..-29, so that stays plain.
	perimeterRun(walls, "z", 45, -39.8, -14.6, 1, false, true, -27, nil, { -37.5, -29 })

	-- Rubble spilled out of each breach, clear of the way through.
	rubble(walls, -25.4, -43.6, 1.8, 5, 0)
	rubble(walls, -15.6, -43.2, 1.6, 4, 0)
	rubble(walls, -47.4, -11.4, 1.6, 4, 0)
	rubble(walls, -47.6, -1.4, 1.6, 4, 0)
	rubble(walls, 48.2, -17.2, 1.4, 4, 0)

	-- The gate: two posts and a gantry over the vehicle way, the team's banner hanging from it.
	local gate = Instance.new("Model")
	gate.Name = "Gate"
	gate:SetAttribute("Destructible", false)
	gate.Parent = model
	box(gate, "GatePost", 2.2, 4.6, -1, 11.5, -42.2, -39.8, CONCRETE_DARK, MAT.Concrete)
	box(gate, "GatePost", 43.4, 45.8, -1, 11.5, -42.2, -39.8, CONCRETE_DARK, MAT.Concrete)
	box(gate, "Gantry", 2.2, 45.8, 11.5, 12.7, -41.6, -40.4, STEEL, MAT.Metal)
	-- The east gate, for the back row of bays: one post, and a gantry from it to the supply room's
	-- roof beam, the team's banner over the way out.
	box(gate, "GatePost", 43.4, 45.8, -1, 11.5, -14.6, -12.6, CONCRETE_DARK, MAT.Concrete)
	box(gate, "Gantry", 43.9, 45.3, 11.5, 12.7, -14.6, 22.4, STEEL, MAT.Metal)
	box(gate, "TeamGateBanner", 44.52, 44.68, 8.6, 12.0, 0.5, 7.5, B.team, MAT.Fabric, TRIM)
	disc(gate, "GateEmblem", Vector3.new(44.6, 10.2, 4), Vector3.new(1, 0, 0), 0.14, 2.2, WHITE_PAINT, MAT.SmoothPlastic)
	disc(gate, "GateEmblemEye", Vector3.new(44.6, 10.2, 4), Vector3.new(1, 0, 0), 0.22, 1.0, SOOT, MAT.SmoothPlastic)
	for x = 6, 42, 9 do
		rod(gate, "GantryRivet", Vector3.new(x, 12.1, -41.7), Vector3.new(x, 12.1, -41.5), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	end
	facePlate(gate, "TeamGatePaint", "z", -42.2, -1, PROUD_PAINT, 2.6, 4.2, 8.6, 10.6, B.team, MAT.SmoothPlastic)
	facePlate(gate, "TeamGatePaint", "z", -42.2, -1, PROUD_PAINT, 43.8, 45.4, 8.6, 10.6, B.team, MAT.SmoothPlastic)
	-- The banner hangs through the gantry's middle; it stops 8.6 up, over the tallest car.
	box(gate, "TeamGateBanner", 20.5, 27.5, 8.6, 12.0, -41.08, -40.92, B.team, MAT.Fabric, TRIM)
	disc(gate, "GateEmblem", Vector3.new(24, 10.2, -41.0), Vector3.new(0, 0, -1), 0.14, 2.2, WHITE_PAINT, MAT.SmoothPlastic)
	disc(gate, "GateEmblemEye", Vector3.new(24, 10.2, -41.0), Vector3.new(0, 0, -1), 0.22, 1.0, SOOT, MAT.SmoothPlastic)
	box(gate, "TeamBannerTatter", 25.2, 27.0, 8.0, 8.9, -41.17, -41.03, mix(B.team, SOOT, 0.3), MAT.Fabric, TRIM)
	-- A floodlight on the left post, looking in over the yard.
	local head = box(gate, "GateLamp", 2.6, 4.2, 9.4, 10.4, -39.8, -38.9, STEEL_DARK, MAT.Metal, TRIM)
	local _ = head
	local bulb = box(gate, "GateLampGlass", 2.8, 4.0, 9.55, 10.25, -38.9, -38.75, WARM, MAT.Neon, TRIM)
	light(bulb, WARM, 26, 1.4)
end

--------------------------------------------------------------------------------
-- The bunker: the spawn shelter
--------------------------------------------------------------------------------

local BUNKER_TOP = 10.8
local ROOF_TOP = 12

local function buildBunker(model)
	local bunker = Instance.new("Model")
	-- "Spawn" is in DestructibleService.Never: nothing in here breaks, whatever it is called.
	bunker.Name = "Spawn"
	bunker:SetAttribute("Destructible", false)
	bunker.Parent = model
	local never = { tag = false }

	-- Floor and thresholds. The floor is 0.5 above the paving, one easy step.
	box(bunker, "Foundation", -43.8, 2, -0.7, ROOM_FLOOR, 10, 39.8, CONCRETE_DARK, MAT.Concrete, never)
	box(bunker, "Foundation", -33, -26, -0.7, ROOM_FLOOR, 8, 10, CONCRETE_DARK, MAT.Concrete, never)
	box(bunker, "Foundation", -16, -9, -0.7, ROOM_FLOOR, 8, 10, CONCRETE_DARK, MAT.Concrete, never)
	box(bunker, "Foundation", 2, 4, -0.7, ROOM_FLOOR, 28, 35, CONCRETE_DARK, MAT.Concrete, never)

	-- Walls, 2 thick. The west and back walls are the compound's own there.
	local function wall(x0, x1, y1, z0, z1, color)
		return box(bunker, "BunkerWall", x0, x1, -1, y1, z0, z1, color or BUNKER, MAT.Concrete, never)
	end
	wall(-45.8, -43.8, BUNKER_TOP, 8, 41.8)
	wall(-43.8, 4, BUNKER_TOP, 39.8, 41.8)
	-- East: a stub where the corner came down, the doorway to the supply room at z 28..35.
	wall(2, 4, 4.3, 10, 17, BUNKER_DARK)
	wall(2, 4, BUNKER_TOP, 17, 28)
	box(bunker, "BunkerWall", 2, 4, 8.8, BUNKER_TOP, 28, 35, BUNKER, MAT.Concrete, never)
	wall(2, 4, BUNKER_TOP, 35, 39.8)
	-- Front: a firing slit, two doorways (x -33..-26 and -16..-9), and the stub at the fallen corner.
	wall(-43.8, -41, BUNKER_TOP, 8, 10)
	box(bunker, "BunkerWall", -41, -37, -1, 5, 8, 10, BUNKER, MAT.Concrete, never)
	box(bunker, "BunkerWall", -41, -37, 6.4, BUNKER_TOP, 8, 10, BUNKER, MAT.Concrete, never)
	wall(-37, -33, BUNKER_TOP, 8, 10)
	box(bunker, "BunkerWall", -33, -26, 8.8, BUNKER_TOP, 8, 10, BUNKER, MAT.Concrete, never)
	wall(-26, -16, BUNKER_TOP, 8, 10)
	box(bunker, "BunkerWall", -16, -9, 8.8, BUNKER_TOP, 8, 10, BUNKER, MAT.Concrete, never)
	wall(-9, -4, BUNKER_TOP, 8, 10)
	wall(-4, 4, 3.5, 8, 10, BUNKER_DARK)
	table.insert(B.doorways, { name = "BunkerDoorWest", x0 = -33, x1 = -26, z0 = 8, z1 = 10, floor = ROOM_FLOOR, top = 8.8 })
	table.insert(B.doorways, { name = "BunkerDoorEast", x0 = -16, x1 = -9, z0 = 8, z1 = 10, floor = ROOM_FLOOR, top = 8.8 })
	table.insert(B.doorways, { name = "BunkerToSupply", x0 = 2, x1 = 4, z0 = 28, z1 = 35, floor = ROOM_FLOOR, top = 8.8 })

	-- The roof, and the column line holding its middle.
	box(bunker, "BunkerRoof", -45.8, -4, BUNKER_TOP, ROOF_TOP, 8, 41.8, BUNKER, MAT.Concrete, never)
	box(bunker, "BunkerRoof", -4, 4, BUNKER_TOP, ROOF_TOP, 17, 41.8, BUNKER, MAT.Concrete, never)
	box(bunker, "BunkerBeam", -43.8, 2, 9.8, BUNKER_TOP, 22.4, 23.6, BUNKER_DARK, MAT.Concrete, never)
	box(bunker, "BunkerPillar", -32.3, -30.7, ROOM_FLOOR, 9.8, 22.2, 23.8, BUNKER_DARK, MAT.Concrete, never)
	box(bunker, "BunkerPillar", -14.3, -12.7, ROOM_FLOOR, 9.8, 22.2, 23.8, BUNKER_DARK, MAT.Concrete, never)
	-- A broken lip round the roof's front and west edges.
	box(bunker, "RoofLip", -45.6, -38.5, ROOF_TOP, ROOF_TOP + 0.9, 8.2, 9.0, BUNKER_DARK, MAT.Concrete, never)
	box(bunker, "RoofLip", -35.8, -27.2, ROOF_TOP, ROOF_TOP + 0.6, 8.2, 9.0, BUNKER_DARK, MAT.Concrete, never)
	box(bunker, "RoofLip", -22.6, -12.4, ROOF_TOP, ROOF_TOP + 0.9, 8.2, 9.0, BUNKER_DARK, MAT.Concrete, never)
	box(bunker, "RoofLip", -45.6, -44.8, ROOF_TOP, ROOF_TOP + 0.9, 9.0, 24.5, BUNKER_DARK, MAT.Concrete, never)
	box(bunker, "RoofLip", -45.6, -44.8, ROOF_TOP, ROOF_TOP + 0.7, 29.2, 41.6, BUNKER_DARK, MAT.Concrete, never)

	-- THE COLLAPSED CORNER. The roof over x -4..4, z 8..17 came in: one slab lies from the front
	-- stub's top down onto the floor, on its own rubble, with rebar hanging out of both broken edges.
	local stubTop, highZ, lowZ = 3.5, 9.2, 19.0
	local rise = stubTop - ROOM_FLOOR
	local run = lowZ - highZ
	local slope = math.atan2(rise, run)
	local slabLength = math.sqrt(rise * rise + run * run) + 0.3
	local bottomMid = Vector3.new(-1.35, (stubTop + ROOM_FLOOR) / 2 - 0.1, (highZ + lowZ) / 2)
	local up = Vector3.new(0, math.cos(slope), math.sin(slope))
	put(bunker, "FallenRoof", Vector3.new(6.3, 1.2, slabLength),
		CFrame.new(bottomMid + up * 0.6) * CFrame.Angles(slope, 0, 0), BUNKER, MAT.Concrete, never)
	rubble(bunker, -2.2, 12.6, 1.8, 5, ROOM_FLOOR, { BUNKER, BUNKER_DARK, CONCRETE_DARK })
	rubble(bunker, 0.6, 15.6, 1.4, 4, ROOM_FLOOR, { BUNKER, BUNKER_DARK, CONCRETE_DARK })
	rubble(bunker, -3.0, 18.4, 1.2, 3, ROOM_FLOOR, { BUNKER, BUNKER_DARK })
	for index = 0, 3 do
		local z = 9.4 + index * 2.3
		rebar(bunker, Vector3.new(-4.3, 11.2, z), rnd(1.0, 1.8), rnd(1.6, 2.1), rnd(-0.3, 0.3))
	end
	for index = 0, 2 do
		local x = -3.1 + index * 2.6
		rebar(bunker, Vector3.new(x, 11.1, 17.3), rnd(1.0, 1.7), rnd(1.7, 2.2), -math.pi / 2 + rnd(-0.3, 0.3))
	end
	put(bunker, "BrokenEdge", Vector3.new(1.4, 0.9, 3.2), CFrame.new(-3.6, 10.7, 12.6) * CFrame.Angles(0, 0, -0.35),
		BUNKER, MAT.Concrete, TRIM)
	put(bunker, "BrokenEdge", Vector3.new(2.6, 0.9, 1.3), CFrame.new(1.2, 10.7, 17.4) * CFrame.Angles(0.4, 0, 0),
		BUNKER, MAT.Concrete, TRIM)
	-- The stubs' own broken tops.
	for _, x in ipairs({ -3, -0.8, 1.6 }) do
		rebar(bunker, Vector3.new(x, stubTop, 9.0), rnd(0.9, 1.8), rnd(0.1, 0.5), rnd(0, math.pi * 2))
	end
	for _, z in ipairs({ 11.5, 14.5 }) do
		rebar(bunker, Vector3.new(3.0, 4.3, z), rnd(0.9, 1.6), rnd(0.1, 0.5), rnd(0, math.pi * 2))
	end

	-- The spawn pads: two rows of four under the whole roof, clear of the fallen corner.
	for _, z in ipairs({ 16, 30 }) do
		for _, x in ipairs({ -36, -27, -18, -9 }) do
			box(bunker, "TeamPad", x - 2, x + 2, ROOM_FLOOR, ROOM_FLOOR + 0.16, z - 2, z + 2, B.team, MAT.SmoothPlastic, TRIM)
			box(bunker, "PadMark", x - 0.6, x + 0.6, ROOM_FLOOR + 0.1, ROOM_FLOOR + 0.24, z - 1.2, z - 0.2, WHITE_PAINT, MAT.SmoothPlastic, TRIM)
			table.insert(B.pads, CFrame.new(x, ROOM_FLOOR, z))
		end
	end

	-- Inside: the team's banner and emblem on the back wall, lamps, a cable run, a bunk, the rack.
	box(bunker, "TeamBanner", -25, -17, 3.2, 8.8, 39.62, 39.82, B.team, MAT.Fabric, TRIM)
	rod(bunker, "BannerRod", Vector3.new(-25.6, 8.95, 39.55), Vector3.new(-16.4, 8.95, 39.55), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	disc(bunker, "BannerEye", Vector3.new(-21, 6.2, 39.72), Vector3.new(0, 0, -1), 0.18, 3.0, WHITE_PAINT, MAT.SmoothPlastic)
	disc(bunker, "BannerPupil", Vector3.new(-21, 6.0, 39.72), Vector3.new(0, 0, -1), 0.26, 1.3, SOOT, MAT.SmoothPlastic)
	wallLamp(bunker, Vector3.new(-31, 8.2, 39.8), Vector3.new(0, 0, -1), 22)
	wallLamp(bunker, Vector3.new(-6, 8.2, 39.8), Vector3.new(0, 0, -1), 22)
	rod(bunker, "Conduit", Vector3.new(-43.72, 9.4, 39.72), Vector3.new(2, 9.4, 39.72), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	rod(bunker, "Conduit", Vector3.new(-43.72, 9.4, 10), Vector3.new(-43.72, 9.4, 39.8), 0.3, STEEL_DARK, MAT.Metal, TRIM)

	-- A double bunk against the west wall.
	for _, x in ipairs({ -43.5, -40.9 }) do
		for _, z in ipairs({ 20.8, 26.2 }) do
			box(bunker, "BunkPost", x - 0.15, x + 0.15, ROOM_FLOOR, 6.3, z - 0.15, z + 0.15, STEEL, MAT.Metal)
		end
	end
	box(bunker, "Bunk", -43.4, -41.0, 1.9, 2.4, 20.9, 26.1, CANVAS, MAT.Fabric)
	box(bunker, "Bunk", -43.4, -41.0, 4.6, 5.1, 20.9, 26.1, OLIVE, MAT.Fabric)
	box(bunker, "BunkFrame", -43.5, -40.9, 1.7, 1.9, 20.75, 26.25, STEEL, MAT.Metal)
	box(bunker, "BunkFrame", -43.5, -40.9, 4.4, 4.6, 20.75, 26.25, STEEL, MAT.Metal)

	-- An empty rack by the west wall, ammo tins left under it.
	box(bunker, "Rack", -43.8, -43.3, 1.2, 6.4, 11.2, 14.8, WOOD_DARK, MAT.WoodPlanks)
	for _, y in ipairs({ 2.8, 4.6 }) do
		box(bunker, "RackBar", -43.3, -42.5, y, y + 0.25, 11.4, 14.6, STEEL, MAT.Metal)
	end
	box(bunker, "AmmoTin", -42.9, -41.3, ROOM_FLOOR, 1.9, 11.6, 12.8, OLIVE, MAT.Metal)
	box(bunker, "AmmoTin", -42.8, -41.4, ROOM_FLOOR, 1.7, 13.2, 14.3, OLIVE, MAT.Metal)

	-- The Rot-O-Matic: a humming console against the back wall, its screen still glowing green.
	box(bunker, "RotOMatic", -15, -11, ROOM_FLOOR, 5.8, 37.6, 39.8, STEEL, MAT.Metal)
	box(bunker, "RotOMaticScreen", -14.4, -11.6, 3.4, 5.3, 37.46, 37.74, ROT_GREEN, MAT.Neon, TRIM)
	box(bunker, "ScreenCrack", -13.6, -12.9, 3.6, 5.1, 37.38, 37.66, SOOT, MAT.Slate, TRIM)
	put(bunker, "RotOMaticKeys", Vector3.new(3.4, 0.8, 1.2), CFrame.new(-13, 2.9, 37.2) * CFrame.Angles(0.5, 0, 0),
		STEEL_DARK, MAT.Metal, TRIM)
	rod(bunker, "RotOMaticAerial", Vector3.new(-12, 5.45, 38.7), Vector3.new(-11.4, 8.4, 38.9), 0.14, STEEL_DARK, MAT.Metal, TRIM)
	light(put(bunker, "RotOMaticGlow", Vector3.new(0.5, 0.5, 0.5), CFrame.new(-13, 4.3, 37.3), ROT_GREEN, MAT.Neon,
		trimWith({ shape = Enum.PartType.Ball })), ROT_GREEN, 9, 0.8)
	-- A filing cabinet knocked flat beside it.
	put(bunker, "Cabinet", Vector3.new(4.2, 1.8, 2), CFrame.new(-6.9, ROOM_FLOOR + 0.9, 37.6) * CFrame.Angles(0, 0.06, 0),
		STEEL, MAT.Metal)

	-- On the roof: a sandbagged lookout, a bent aerial and a dish knocked askew.
	sandbags(bunker, "roofFront", -30, 10.4, -21, 10.4, 2, ROOF_TOP)
	sandbags(bunker, "roofSide", -31.4, 11.8, -31.4, 17.2, 2, ROOF_TOP)
	-- The observation cupola over the armoury: a concrete box with a firing slit, its aerial snapped.
	box(bunker, "Cupola", -43.8, -36.8, ROOF_TOP, ROOF_TOP + 3.4, 30, 38, BUNKER_DARK, MAT.Concrete, never)
	box(bunker, "CupolaRoof", -44.1, -36.5, ROOF_TOP + 3.4, ROOF_TOP + 4.0, 29.7, 38.3, BUNKER, MAT.Concrete, never)
	facePlate(bunker, "CupolaSlit", "z", 30, -1, 0.1, -42.6, -38, ROOF_TOP + 1.8, ROOF_TOP + 2.4, SOOT, MAT.Slate)
	facePlate(bunker, "TeamStripe", "z", 30, -1, PROUD_PAINT, -43.4, -37.2, ROOF_TOP + 0.6, ROOF_TOP + 1.2, B.team, MAT.SmoothPlastic)
	rod(bunker, "Aerial", Vector3.new(-39, ROOF_TOP + 3.7, 36), Vector3.new(-39, ROOF_TOP + 10.5, 36), 0.35, STEEL, MAT.Metal)
	rod(bunker, "Aerial", Vector3.new(-39, ROOF_TOP + 10.3, 36), Vector3.new(-37.6, ROOF_TOP + 12.4, 36.8), 0.28, STEEL, MAT.Metal)
	box(bunker, "DishMount", -26.8, -25.2, ROOF_TOP, ROOF_TOP + 1.6, 34.2, 35.8, STEEL_DARK, MAT.Metal)
	put(bunker, "Dish", Vector3.new(0.35, 4.2, 4.2),
		CFrame.new(-26, ROOF_TOP + 2.6, 35) * CFrame.Angles(0, 0.7, 0) * CFrame.Angles(0, 0, 0.9), WHITE_PAINT, MAT.Metal,
		{ shape = Enum.PartType.Cylinder })
	box(bunker, "Vent", -12, -9.6, ROOF_TOP, ROOF_TOP + 1.4, 30, 32.4, STEEL, MAT.Metal)
	box(bunker, "VentCap", -12.3, -9.3, ROOF_TOP + 1.4, ROOF_TOP + 1.7, 29.7, 32.7, STEEL_DARK, MAT.Metal)

	-- The team's Rot Eye painted on the front, between the doors, with the paint run down from it.
	local eye = Vector3.new(-21, 6.4, 8)
	local out = Vector3.new(0, 0, -1)
	disc(bunker, "TeamEmblem", eye, out, 0.14, 5.2, B.team, MAT.SmoothPlastic)
	disc(bunker, "EmblemWhite", eye + Vector3.new(0, 0.1, 0), out, 0.22, 3.4, WHITE_PAINT, MAT.SmoothPlastic)
	disc(bunker, "EmblemPupil", eye + Vector3.new(0.3, -0.1, 0), out, 0.30, 1.6, SOOT, MAT.SmoothPlastic)
	disc(bunker, "EmblemGlint", eye + Vector3.new(0.75, 0.45, 0), out, 0.38, 0.45, WHITE_PAINT, MAT.SmoothPlastic)
	for _, drip in ipairs({ { -22.3, 3.6 }, { -20.4, 3.4 }, { -19.3, 4.4 } }) do
		facePlate(bunker, "TeamEmblemDrip", "z", 8, -1, 0.06, drip[1] - 0.18, drip[1] + 0.18, drip[2], 4.6, B.team, MAT.SmoothPlastic)
	end
	-- Soot round the doors, stencilled team stripe along the front.
	facePlate(bunker, "Scorch", "z", 8, -1, PROUD_SOOT, -8.7, -4.6, 0.4, 7.6, SOOT, MAT.Slate)
	facePlate(bunker, "Scorch", "z", 8, -1, PROUD_SOOT, -36.8, -33.2, 5.0, 9.8, SOOT, MAT.Slate)
	facePlate(bunker, "TeamStripe", "z", 8, -1, PROUD_PAINT, -43.4, -41.2, 2.3, 3.1, B.team, MAT.SmoothPlastic)
	facePlate(bunker, "TeamStripe", "z", 8, -1, PROUD_PAINT, -36.8, -33.2, 2.3, 3.1, B.team, MAT.SmoothPlastic)
	facePlate(bunker, "TeamStripe", "z", 8, -1, PROUD_PAINT, -25.6, -16.4, 2.3, 3.1, B.team, MAT.SmoothPlastic)

	-- Chest spots: the armoury corner and beside the console.
	table.insert(B.chests, { name = "BunkerArmoury", at = CFrame.new(-40.5, ROOM_FLOOR, 36.9) })
	table.insert(B.chests, { name = "BunkerConsole", at = CFrame.new(-1.5, ROOM_FLOOR, 36.9) })
	table.insert(B.loot, CFrame.new(-22.5, ROOM_FLOOR, 36.6))
	table.insert(B.loot, CFrame.new(-22.5, ROOM_FLOOR, 23))
	table.insert(B.loot, CFrame.new(-4.5, ROOM_FLOOR, 23))
	return bunker
end

--------------------------------------------------------------------------------
-- The supply room
--------------------------------------------------------------------------------

local function buildSupply(model)
	local room = Instance.new("Model")
	room.Name = "SupplyRoom"
	room.Parent = model
	local never = { tag = false }

	box(room, "Foundation", 4, 43.8, -0.7, ROOM_FLOOR, 24, 39.8, CONCRETE_DARK, MAT.Concrete, never)
	box(room, "Foundation", 20, 27, -0.7, ROOM_FLOOR, 22, 24, CONCRETE_DARK, MAT.Concrete, never)
	table.insert(B.doorways, { name = "SupplyDoor", x0 = 20, x1 = 27, z0 = 22, z1 = 24, floor = ROOM_FLOOR, top = 9 })

	-- The frame that carries the roof never breaks, so nothing is ever left hanging when the brick
	-- infill between it is shot out.
	for _, x in ipairs({ 5, 17, 30, 44.8 }) do
		for _, z in ipairs({ 23, 40.8 }) do
			box(room, "Pillar", x - 1, x + 1, -1, 11, z - 1, z + 1, CONCRETE_DARK, MAT.Concrete, never)
		end
	end
	box(room, "RoofBeam", 4, 45.8, 11, 12, 22.4, 23.6, RUST, MAT.CorrodedMetal, never)
	box(room, "RoofBeam", 4, 45.8, 11, 12, 40.2, 41.4, RUST, MAT.CorrodedMetal, never)
	for _, x in ipairs({ 5, 17, 30, 44.8 }) do
		box(room, "RoofBeam", x - 0.5, x + 0.5, 12, 12.8, 22.4, 41.4, RUST, MAT.CorrodedMetal, never)
	end
	-- What is left of the tin roof, over the back of the room.
	local sheets = {
		{ 4.6, 16.9, 30.0, 41.2 },
		{ 17.1, 29.9, 33.2, 41.2 },
	}
	for _, s in ipairs(sheets) do
		box(room, "RoofSheet", s[1], s[2], 12.8, 13.05, s[3], s[4], mix(STEEL, RUST, 0.45), MAT.CorrodedMetal, never)
		for rib = 1, 4 do
			local x = s[1] + (s[2] - s[1]) * rib / 5
			rod(room, "SheetRib", Vector3.new(x, 13.05, s[3] + 0.3), Vector3.new(x, 13.05, s[4] - 0.3), 0.16,
				mix(STEEL, RUST, 0.3), MAT.CorrodedMetal, TRIM)
		end
	end

	-- Brick infill, 2 thick, in the frame's bays. The front has the doorway (x 20..27) and a blown hole
	-- down to a stub at x 36..40; the east side is the compound's own wall.
	local function infill(axis, u0, u1, c, top, style)
		style.color = style.color or BRICK
		style.material = MAT.Brick
		style.health = 150
		style.brick = false
		return wallPanel(room, axis, u0, u1, c, 2, top, style)
	end
	infill("x", 6, 16, 23, rnd(8.6, 9.6), { out = -1, stripe = true })
	infill("x", 18, 20, 23, rnd(8.4, 9.6), { out = -1, plain = true })
	infill("x", 27, 29, 23, rnd(6.2, 7.4), { out = -1, plain = true })
	infill("x", 31, 36, 23, rnd(8.4, 9.6), { out = -1, stripe = true })
	infill("x", 36, 40, 23, 2.5, { out = -1, low = true, color = BRICK_DARK })
	infill("x", 40, 43.8, 23, rnd(7.4, 8.8), { out = -1 })
	infill("x", 6, 16, 40.8, rnd(8.6, 9.6), { out = 1, stripe = true })
	infill("x", 18, 29, 40.8, rnd(8.6, 9.6), { out = 1, stripe = true })
	infill("x", 31, 43.8, 40.8, rnd(8.6, 9.6), { out = 1, stripe = true })
	infill("z", 24, 31, 44.8, rnd(8.6, 9.6), { out = 1, stripe = true })
	infill("z", 31, 39.8, 44.8, rnd(7.8, 9.0), { out = 1, stripe = true })
	rubble(room, 38.2, 25.4, 1.0, 3, ROOM_FLOOR, { BRICK, BRICK_DARK })

	-- Four chest alcoves along the back wall, between shelving partitions, each with its number
	-- painted over it in the team's colour.
	for _, x in ipairs({ 14, 24, 34 }) do
		box(room, "Shelf", x - 0.5, x + 0.5, ROOM_FLOOR, 6.3, 34, 39.8, WOOD, MAT.WoodPlanks)
		box(room, "ShelfTin", x - 0.4, x + 0.4, 6.3, 7.0, 35.2, 36.4, OLIVE, MAT.Metal, TRIM)
	end
	local alcoves = { { 9, 9 }, { 19, 19.5 }, { 29, 27.3 }, { 39, 39 } }
	for number, alcove in ipairs(alcoves) do
		local x, sign = alcove[1], alcove[2]
		table.insert(B.chests, { name = "SupplyAlcove" .. number, at = CFrame.new(x, ROOM_FLOOR, 36.9) })
		facePlate(room, "TeamAlcoveNumber", "z", 39.8, -1, PROUD_BRICK, sign - 0.9, sign + 0.9, 6.6, 8.4, B.team, MAT.SmoothPlastic)
		for pip = 1, number do
			local px = sign + (pip - (number + 1) / 2) * 0.42
			disc(room, "AlcovePip", Vector3.new(px, 7.5, 39.8), Vector3.new(0, 0, -1), PROUD_PAINT, 0.32, WHITE_PAINT, MAT.SmoothPlastic)
		end
	end

	-- Crates by the west wall, one knocked over with its lid off.
	local stackA = { tag = "Crate:supplyA" }
	box(room, "Crate", 6.5, 9.5, ROOM_FLOOR, ROOM_FLOOR + 3, 25, 28, WOOD, MAT.WoodPlanks, stackA)
	box(room, "Crate", 9.6, 12.6, ROOM_FLOOR, ROOM_FLOOR + 3, 25, 28, WOOD_DARK, MAT.WoodPlanks, stackA)
	box(room, "Crate", 7.5, 10.5, ROOM_FLOOR + 3, ROOM_FLOOR + 6, 25.2, 28.2, WOOD, MAT.WoodPlanks, stackA)
	for _, band in ipairs({ { 6.5, 9.5, 25 }, { 9.6, 12.6, 25 } }) do
		facePlate(room, "CrateBand", "z", band[3], -1, 0.08, band[1] + 0.2, band[2] - 0.2, ROOM_FLOOR + 1.3, ROOM_FLOOR + 1.7,
			STEEL_DARK, MAT.Metal)
	end
	put(room, "Crate", Vector3.new(2.4, 2.4, 2.4), CFrame.new(14.6, ROOM_FLOOR + 1.2, 26.3) * CFrame.Angles(0, 0.3, 0) * CFrame.Angles(math.pi / 2, 0, 0),
		WOOD, MAT.WoodPlanks, { tag = "Crate:tipped" })
	put(room, "CrateLid", Vector3.new(2.4, 0.2, 2.4), CFrame.new(17.2, ROOM_FLOOR + 0.1, 28.9) * CFrame.Angles(0, 0.35, 0),
		WOOD_DARK, MAT.WoodPlanks, TRIM)

	-- A crate by the doorway, with a ripped sheet of the roof hanging from the beam onto it.
	box(room, "Crate", 27, 30.2, ROOM_FLOOR, ROOM_FLOOR + 3.2, 26.8, 30, WOOD_DARK, MAT.WoodPlanks, { tag = "Crate:door" })
	plateBetween(room, "TornSheet", Vector3.new(28.6, 11.1, 23.4), Vector3.new(28.6, ROOM_FLOOR + 3.15, 28.9), 2.8, 0.15,
		mix(STEEL, RUST, 0.45), MAT.CorrodedMetal, TRIM)

	-- The RotVat: a big brainrot brewing tank, dented, still lit, leaking green onto the floor.
	local vat = Vector3.new(39.5, 0, 28.5)
	rod(room, "VatBase", Vector3.new(vat.X, ROOM_FLOOR, vat.Z), Vector3.new(vat.X, ROOM_FLOOR + 0.4, vat.Z), 5.0, STEEL_DARK, MAT.Metal,
		{ tag = "Prop:vat" })
	rod(room, "RotVat", Vector3.new(vat.X, ROOM_FLOOR + 0.4, vat.Z), Vector3.new(vat.X, ROOM_FLOOR + 6.2, vat.Z), 4.6, STEEL, MAT.Metal,
		{ tag = "Prop:vat" })
	put(room, "VatDome", Vector3.new(4.6, 4.6, 4.6), CFrame.new(vat.X, ROOM_FLOOR + 6.2, vat.Z), STEEL, MAT.Metal,
		{ shape = Enum.PartType.Ball, tag = "Prop:vat" })
	local glow = rod(room, "VatWindow", Vector3.new(vat.X, ROOM_FLOOR + 2.6, vat.Z), Vector3.new(vat.X, ROOM_FLOOR + 3.8, vat.Z), 4.72,
		ROT_GREEN, MAT.Neon, trimWith({ transparency = 0.15 }))
	light(glow, ROT_GREEN, 12, 0.9)
	rod(room, "VatPipe", Vector3.new(41.5, ROOM_FLOOR + 5.2, vat.Z), Vector3.new(44.1, ROOM_FLOOR + 5.2, vat.Z), 0.55, RUST, MAT.CorrodedMetal, TRIM)
	rod(room, "VatPipe", Vector3.new(vat.X, ROOM_FLOOR + 8.1, vat.Z), Vector3.new(vat.X, ROOM_FLOOR + 10.4, vat.Z), 0.55, RUST, MAT.CorrodedMetal, TRIM)
	rod(room, "VatPipe", Vector3.new(vat.X - 0.3, ROOM_FLOOR + 10.1, vat.Z), Vector3.new(vat.X - 0.3, 11.2, 23.6), 0.45, RUST, MAT.CorrodedMetal, TRIM)
	groundDisc(room, "RotGoo", 37.0, 32.2, 2.6, ROT_GREEN, MAT.Neon, 0, ROOM_FLOOR)
	groundDisc(room, "RotGoo", 38.6, 33.2, 1.4, ROT_GREEN, MAT.Neon, 1, ROOM_FLOOR)

	-- A bare bulb hanging from the frame.
	rod(room, "BulbCord", Vector3.new(17, 12.05, 31.5), Vector3.new(17, 9.1, 31.5), 0.08, RUBBER, MAT.Plastic, TRIM)
	local bulb = put(room, "Bulb", Vector3.new(0.7, 0.7, 0.7), CFrame.new(17, 8.9, 31.5), WARM, MAT.Neon,
		trimWith({ shape = Enum.PartType.Ball }))
	light(bulb, WARM, 24, 1.2)

	table.insert(B.loot, CFrame.new(16.5, ROOM_FLOOR, 32.0))
	table.insert(B.loot, CFrame.new(24.5, ROOM_FLOOR, 31.0))
	table.insert(B.loot, CFrame.new(33.0, ROOM_FLOOR, 27.0))
	table.insert(B.loot, CFrame.new(8.0, ROOM_FLOOR, 31.5))
	return room
end

--------------------------------------------------------------------------------
-- The vehicle yard
--------------------------------------------------------------------------------

-- Six bays (Oliver, 2026-09-24: "add more cars to spawn bases"). The front row of three faces the
-- gate and drives straight out through it; the back row of three stands across the yard's east end
-- and drives straight out through the east gate. Neither row's way out crosses the other.
local FRONT_BAYS, FRONT_Z = { 12.5, 25, 37.5 }, -26
local BACK_BAYS, BACK_X = { -7, 4, 15 }, 32
local BAY_HALF_WIDTH, BAY_HALF_LENGTH = 6.25, 11

-- A camo net over a row of bays: poles on the bay lines at both ends of the bays, cables along
-- the pole tops, the net sagging between. `across` is the list of bay-line positions across the row,
-- `backAt`/`frontAt` where the pole rows stand along it, `alongX` whether the bays run along X (the
-- back row) rather than Z. NOTHING over a bay may be queryable: VehicleService's footing ray starts
-- 24 studs over the spot, and would park the car on the net.
local function camoNet(yard, across, backAt, frontAt, alongX, torn)
	local top, sag = 11.8, 10.1
	local mid = (backAt + frontAt) / 2
	local function at(a, y, u)
		if alongX then
			return Vector3.new(u, y, a)
		end
		return Vector3.new(a, y, u)
	end
	for _, a in ipairs(across) do
		for _, u in ipairs({ backAt, frontAt }) do
			rod(yard, "NetPole", at(a, 0, u), at(a, top, u), 0.8, OLIVE, MAT.Metal)
		end
		rod(yard, "NetCable", at(a, top - 0.25, backAt), at(a, top - 0.25, frontAt), 0.12, RUBBER, MAT.Plastic, TRIM)
	end
	for _, u in ipairs({ backAt, frontAt }) do
		rod(yard, "NetCable", at(across[1], top - 0.25, u), at(across[#across], top - 0.25, u), 0.12, RUBBER, MAT.Plastic, TRIM)
	end
	local netOpts = trimWith({ transparency = 0.12 })
	local step = frontAt > backAt and 1 or -1
	for index = 1, #across - 1 do
		local a0, a1 = across[index] + 0.05, across[index + 1] - 0.05
		local w = a1 - a0
		local ca = (a0 + a1) / 2
		local color = index == 2 and mix(NET, OLIVE, 0.5) or NET
		-- The two halves of a panel cross at the sag; the second is a little narrower so their edges
		-- never share a plane.
		plateBetween(yard, "CamoNet", at(ca, top - 0.4, backAt), at(ca, sag, mid + 0.3 * step), w, 0.1, color, MAT.Fabric, netOpts)
		w = w - 0.2
		if torn == index then
			-- Torn: the outer half of this panel is gone, a flap hanging from what is left.
			local edge = mid + 6 * step
			plateBetween(yard, "CamoNet", at(ca, sag, mid - 0.3 * step), at(ca, 10.6, edge), w, 0.1, color, MAT.Fabric, netOpts)
			plateBetween(yard, "NetFlap", at(ca + 2, 10.62, edge - 0.2 * step), at(ca + 2.6, 8.4, edge + 0.7 * step), 4.2, 0.1, color,
				MAT.Fabric, netOpts)
		else
			plateBetween(yard, "CamoNet", at(ca, sag, mid - 0.3 * step), at(ca, top - 0.4, frontAt), w, 0.1, color, MAT.Fabric, netOpts)
		end
	end
	-- Scrim strips hanging off the outer cable, between the poles.
	for index = 1, #across - 1 do
		for _, t in ipairs({ 0.3, 0.7 }) do
			local a = across[index] + (across[index + 1] - across[index]) * t
			if alongX then
				box(yard, "NetScrim", frontAt - 0.03, frontAt + 0.03, top - 2.2, top - 0.3, a - 0.35, a + 0.35, OLIVE, MAT.Fabric, TRIM)
			else
				box(yard, "NetScrim", a - 0.35, a + 0.35, top - 2.2, top - 0.3, frontAt - 0.03, frontAt + 0.03, OLIVE, MAT.Fabric, TRIM)
			end
		end
	end
end

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

	-- The front row: three bays side by side, noses to the gate. Lines between, the number at the
	-- back of each, a wheel stop behind.
	for _, x in ipairs({ 6.25, 18.75, 31.25, 43.75 }) do
		groundMark(yard, "BayLine", x, FRONT_Z, 0.3, BAY_HALF_LENGTH * 2, 0, YELLOW_PAINT, MAT.SmoothPlastic, 0)
	end
	for number, x in ipairs(FRONT_BAYS) do
		table.insert(B.bays, { name = "Bay" .. number, at = CFrame.new(x, TILE_TOP, FRONT_Z) })
		bayNumber(yard, number, x, FRONT_Z + 9.7)
		box(yard, "WheelStop", x - 2.2, x + 2.2, TILE_TOP, TILE_TOP + 0.5, FRONT_Z + 11.0, FRONT_Z + 11.6, CONCRETE_LIGHT, MAT.Concrete, { tag = false })
		groundDisc(yard, "OilStain", x + rnd(-1.5, 1.5), FRONT_Z + rnd(-3, 3), rnd(1.8, 2.8), SOOT, MAT.Slate, 0)
	end
	camoNet(yard, { 6.2, 18.75, 31.25, 43.4 }, FRONT_Z + 11.6, FRONT_Z - 11.8, false, 3)

	-- The back row: three bays across the east end, noses to the east gate.
	for _, z in ipairs({ -12.5, -1.5, 9.5, 20.5 }) do
		groundMark(yard, "BayLine", BACK_X, z, BAY_HALF_LENGTH * 2, 0.3, 0, YELLOW_PAINT, MAT.SmoothPlastic, 0)
	end
	for index, z in ipairs(BACK_BAYS) do
		local number = #FRONT_BAYS + index
		table.insert(B.bays, { name = "Bay" .. number, at = CFrame.new(BACK_X, TILE_TOP, z) * CFrame.Angles(0, -math.pi / 2, 0) })
		bayNumber(yard, number, BACK_X - 8.8, z)
		box(yard, "WheelStop", BACK_X - 10.9, BACK_X - 10.3, TILE_TOP, TILE_TOP + 0.5, z - 2.2, z + 2.2, CONCRETE_LIGHT, MAT.Concrete, { tag = false })
		groundDisc(yard, "OilStain", BACK_X + rnd(-3, 3), z + rnd(-1.5, 1.5), rnd(1.8, 2.8), SOOT, MAT.Slate, 0)
	end
	camoNet(yard, { -12.5, -1.5, 9.5, 20.5 }, BACK_X - 11.4, BACK_X + 11, true, nil)

	-- A work lamp on the back row's inner pole, looking out over the bays.
	box(yard, "WorkLampArm", 20.6, 21.8, 9.2, 9.6, 9.1, 9.9, STEEL_DARK, MAT.Metal, TRIM)
	box(yard, "WorkLamp", 21.8, 22.6, 8.6, 9.6, 8.9, 10.1, STEEL_DARK, MAT.Metal, TRIM)
	local lamp = box(yard, "WorkLampGlass", 22.6, 22.7, 8.75, 9.45, 9.05, 9.95, WARM, MAT.Neon, TRIM)
	light(lamp, WARM, 26, 1.3)

	-- The apron: tyre stacks and drums between the ways out, the gate's torn-off leaf against the wall.
	local function tyres(x, z, count, tag)
		for index = 1, count do
			local y = TILE_TOP + (index - 1) * 0.9
			rod(yard, "Tyre", Vector3.new(x, y, z), Vector3.new(x, y + 0.9, z), 2.4, RUBBER, MAT.Plastic, { tag = "Prop:" .. tag })
		end
		disc(yard, "TyreHole", Vector3.new(x, TILE_TOP + count * 0.9, z), Vector3.new(0, 1, 0), 0.06, 1.2, SOOT, MAT.Slate)
	end
	tyres(18.75, -24, 3, "tyresA")
	tyres(31.25, -30, 2, "tyresB")
	local drum = { tag = "Prop:drums" }
	rod(yard, "Drum", Vector3.new(43.25, TILE_TOP, -26), Vector3.new(43.25, TILE_TOP + 2.8, -26), 1.8, mix(RUST, BRICK, 0.4), MAT.CorrodedMetal, drum)
	rod(yard, "Drum", Vector3.new(43.25, TILE_TOP, -23.9), Vector3.new(43.25, TILE_TOP + 2.8, -23.9), 1.8, OLIVE, MAT.Metal, drum)
	rod(yard, "Drum", Vector3.new(43.25, TILE_TOP + 0.9, -21.4), Vector3.new(43.25, TILE_TOP + 0.9, -18.6), 1.8, mix(RUST, OLIVE, 0.5), MAT.CorrodedMetal, drum)
	-- The gate leaf, leaning on the wall: steel frame round a sagging mesh.
	local lean = math.asin(1.5 / 6.5)
	local leaf = CFrame.new(42.6, TILE_TOP, -33.3) * CFrame.Angles(0, 0, -lean)
	local leafOpts = { tag = "Prop:gateLeaf" }
	put(yard, "GateLeaf", Vector3.new(0.3, 0.3, 6.8), leaf * CFrame.new(0, 0.15, 0), STEEL, MAT.Metal, leafOpts)
	put(yard, "GateLeaf", Vector3.new(0.3, 0.3, 6.8), leaf * CFrame.new(0, 6.35, 0), STEEL, MAT.Metal, leafOpts)
	put(yard, "GateLeaf", Vector3.new(0.46, 6.2, 0.3), leaf * CFrame.new(0, 3.25, -3.35), STEEL, MAT.Metal, leafOpts)
	put(yard, "GateLeaf", Vector3.new(0.46, 6.2, 0.3), leaf * CFrame.new(0, 3.25, 3.35), STEEL, MAT.Metal, leafOpts)
	put(yard, "GateMesh", Vector3.new(0.08, 5.9, 6.4), leaf * CFrame.new(0, 3.25, 0), STEEL_DARK, MAT.Metal,
		trimWith({ transparency = 0.45 }))

	-- The jersey barriers between the yard and the courtyard, with gaps to walk through.
	for index, span in ipairs({ { -38, -32 }, { -24, -18 }, { -15, -10 } }) do
		local opts = { tag = "Barrier:" .. index }
		box(yard, "Barrier", 4.2, 5.8, TILE_TOP, TILE_TOP + 1.0, span[1], span[2], CONCRETE_LIGHT, MAT.Concrete, opts)
		box(yard, "Barrier", 4.55, 5.45, TILE_TOP + 1.0, TILE_TOP + 2.9, span[1] + 0.1, span[2] - 0.1, CONCRETE_LIGHT, MAT.Concrete, opts)
		facePlate(yard, "TeamBarrierPaint", "x", 4.55, -1, 0.08, span[1] + 0.8, span[2] - 0.8, TILE_TOP + 1.9, TILE_TOP + 2.5, B.team, MAT.SmoothPlastic)
	end

	-- The lane behind the bays: a workbench against the supply wall, a lamp post come down.
	local bench = { tag = "Prop:bench" }
	box(yard, "Workbench", 8, 13, TILE_TOP + 2.9, TILE_TOP + 3.2, 19.6, 21.6, WOOD, MAT.WoodPlanks, bench)
	for _, x in ipairs({ 8.2, 12.5 }) do
		for _, z in ipairs({ 19.8, 21.1 }) do
			box(yard, "BenchLeg", x, x + 0.3, TILE_TOP, TILE_TOP + 2.9, z, z + 0.3, WOOD_DARK, MAT.WoodPlanks, bench)
		end
	end
	box(yard, "Toolbox", 8.6, 10.4, TILE_TOP + 3.2, TILE_TOP + 4.1, 20.0, 20.9, BRICK, MAT.Metal, TRIM)
	box(yard, "Vice", 11.6, 12.4, TILE_TOP + 3.2, TILE_TOP + 3.9, 19.7, 20.3, STEEL, MAT.Metal, TRIM)
	rod(yard, "FallenLampPost", Vector3.new(8, TILE_TOP + 0.25, -3.6), Vector3.new(18, TILE_TOP + 0.25, -3.6), 0.5, STEEL_DARK, MAT.Metal,
		{ tag = "Prop:fallenLamp" })
	box(yard, "FallenLampHead", 17.9, 19.4, TILE_TOP, TILE_TOP + 0.7, -4.2, -3.0, STEEL_DARK, MAT.Metal, { tag = "Prop:fallenLamp" })

	table.insert(B.loot, CFrame.new(15.5, TILE_TOP, 17.5))
	table.insert(B.loot, CFrame.new(12.0, TILE_TOP, 8.0))
	table.insert(B.loot, CFrame.new(14.0, TILE_TOP, -11.5))
	return yard
end

--------------------------------------------------------------------------------
-- The courtyard
--------------------------------------------------------------------------------

local function buildTower(model)
	-- One pool (the Model is tagged), so when it goes it goes whole.
	local tower = Instance.new("Model")
	tower.Name = "Watchtower"
	tower:SetAttribute("Destructible", "Shelter")
	tower.Parent = model
	local x0, x1, z0, z1 = -42.4, -35.6, -38.2, -31.4
	local deck = 7.6
	-- Legs: the two at the back run on up as the roof posts; the front two snapped off at the rail.
	for _, leg in ipairs({ { x0, z0, 11.6 }, { x0, z1, 11.6 }, { x1, z0, 9.0 }, { x1, z1, 9.0 } }) do
		box(tower, "TowerLeg", leg[1] - 0.4, leg[1] + 0.4, 0, leg[3], leg[2] - 0.4, leg[2] + 0.4, STEEL, MAT.Metal)
	end
	box(tower, "TowerDeck", -42.7, -35.3, deck - 0.6, deck, -38.5, -31.1, WOOD_DARK, MAT.WoodPlanks)
	-- Cross bracing on the front face and the east face (one of its braces is gone).
	local function brace(a, b)
		plateBetween(tower, "TowerBrace", a, b, 0.25, 0.25, STEEL_DARK, MAT.Metal)
	end
	brace(Vector3.new(x0, 0.9, z0 - 0.1), Vector3.new(x1, 6.6, z0 - 0.1))
	brace(Vector3.new(x1, 0.9, z0 + 0.12), Vector3.new(x0, 6.6, z0 + 0.12))
	brace(Vector3.new(x0 - 0.1, 0.9, z1), Vector3.new(x0 - 0.1, 6.6, z0))
	brace(Vector3.new(x1 + 0.1, 0.9, z0), Vector3.new(x1 + 0.1, 6.6, z1))
	-- Rails on three sides; the ladder side is open.
	box(tower, "TowerRail", x0 + 0.4, x1 - 0.4, 8.4, 8.7, z0 - 0.15, z0 + 0.15, STEEL, MAT.Metal)
	box(tower, "TowerRail", x0 - 0.15, x0 + 0.15, 8.4, 8.7, z0 + 0.4, z1 - 0.4, STEEL, MAT.Metal)
	box(tower, "TowerRail", x0 + 0.4, -38.4, 8.4, 8.7, z1 - 0.15, z1 + 0.15, STEEL, MAT.Metal)
	put(tower, "TowerRail", Vector3.new(3.4, 0.3, 0.3), CFrame.new(-37.3, 7.9, z1) * CFrame.Angles(0, 0, 0.5), STEEL, MAT.Metal)
	-- Sandbags along the front of the deck, and a searchlight.
	sandbags(tower, "tower", -41.7, -37.6, -36.3, -37.6, 1, deck)
	box(tower, "SearchlightStand", -41.6, -40.8, deck, deck + 1.2, -33.0, -32.2, STEEL_DARK, MAT.Metal)
	local lamp = rod(tower, "Searchlight", Vector3.new(-41.2, deck + 1.7, -32.0), Vector3.new(-41.2, deck + 1.7, -33.6), 1.2, STEEL_DARK, MAT.Metal)
	local _ = lamp
	local glass = disc(tower, "SearchlightGlass", Vector3.new(-41.2, deck + 1.7, -33.6), Vector3.new(0, 0, -1), 0.08, 1.0, WARM, MAT.Neon)
	light(glass, WARM, 20, 1.2)
	-- The roof came down onto the snapped legs.
	local high, low = Vector3.new(x0, 11.6, 0), Vector3.new(x1, 9.0, 0)
	local tilt = math.atan2(high.Y - low.Y, low.X - high.X)
	local mid = (high + low) / 2
	put(tower, "TowerRoof", Vector3.new((low - high).Magnitude + 1.4, 0.25, 8.2),
		CFrame.new(mid.X, mid.Y, (z0 + z1) / 2) * CFrame.Angles(0, 0, -tilt) * CFrame.new(0, 0.05, 0),
		mix(STEEL, RUST, 0.5), MAT.CorrodedMetal)
	-- A pennant on the tall back leg.
	rod(tower, "PennantPole", Vector3.new(x0, 11.4, z0), Vector3.new(x0, 14.2, z0), 0.2, STEEL, MAT.Metal)
	box(tower, "TeamPennant", x0 + 0.05, x0 + 2.6, 12.9, 14.1, z0 - 0.04, z0 + 0.04, B.team, MAT.Fabric, TRIM)
	-- The way up.
	local ladder = Instance.new("TrussPart")
	ladder.Name = "TowerLadder"
	ladder.Anchored = true
	ladder.Size = Vector3.new(2, 8, 2)
	ladder.CFrame = B.frame * CFrame.new(-34.3, 4, -34.8)
	ladder.Color = STEEL
	ladder.Material = MAT.Metal
	ladder.Parent = tower
	return tower
end

local function buildCourtyard(model)
	local yard = Instance.new("Model")
	yard.Name = "Courtyard"
	yard.Parent = model

	buildTower(model)

	-- The MG nest: sandbags three high on the front, two on the sides, open to the bunker. A tripod
	-- still stands on the front line, its gun long gone.
	sandbags(yard, "nestFront", -31.2, -20.3, -20.8, -20.3, 3, TILE_TOP)
	sandbags(yard, "nestWest", -30.6, -19.6, -30.6, -13.2, 2, TILE_TOP)
	sandbags(yard, "nestEast", -21.4, -19.6, -21.4, -13.2, 2, TILE_TOP)
	local apex = Vector3.new(-26, TILE_TOP + 3 * BAG_HIGH + 0.9, -20.3)
	for index = 0, 2 do
		local angle = index * math.pi * 2 / 3 + 0.4
		rod(yard, "TripodLeg", apex, Vector3.new(-26 + math.cos(angle) * 0.6, TILE_TOP + 3 * BAG_HIGH - 0.1, -20.3 + math.sin(angle) * 0.35),
			0.12, STEEL_DARK, MAT.Metal, TRIM)
	end
	box(yard, "AmmoTin", -29.6, -28.6, TILE_TOP - 0.1, TILE_TOP + 1.0, -14.5, -13.4, OLIVE, MAT.Metal, { tag = "Prop:nestTin" })
	table.insert(B.chests, { name = "MachineGunNest", at = CFrame.new(-26, TILE_TOP, -15.8) })

	-- Sandbags either side of the front breach.
	sandbags(yard, "breachWest", -32.5, -35, -25.5, -35, 2, TILE_TOP)
	sandbags(yard, "breachEast", -15.5, -35, -8.5, -35, 2, TILE_TOP)

	-- The lean-to against the west wall: a tin roof on two posts, a chest under it, the radio crate.
	local leanTo = { tag = "Shelter:leanTo" }
	box(yard, "LeanToPost", -37.55, -37.05, TILE_TOP, 7.2, -25.85, -25.35, WOOD_DARK, MAT.WoodPlanks, leanTo)
	box(yard, "LeanToPost", -37.55, -37.05, TILE_TOP, 7.2, -18.65, -18.15, WOOD_DARK, MAT.WoodPlanks, leanTo)
	plateBetween(yard, "LeanToRoof", Vector3.new(-44.5, 7.95, -22), Vector3.new(-36.6, 7.12, -22), 8.8, 0.25,
		mix(STEEL, RUST, 0.55), MAT.CorrodedMetal, leanTo)
	table.insert(B.chests, { name = "LeanTo", at = CFrame.new(-40.8, TILE_TOP, -22) })
	local radio = { tag = "Crate:radio" }
	box(yard, "Crate", -43.9, -41.1, TILE_TOP, TILE_TOP + 2.4, -29.4, -26.6, WOOD, MAT.WoodPlanks, radio)
	box(yard, "MemeRadio", -43.4, -41.6, TILE_TOP + 2.4, TILE_TOP + 3.5, -28.6, -27.4, OLIVE, MAT.Metal, TRIM)
	box(yard, "MemeRadioDial", -42.9, -42.1, TILE_TOP + 2.7, TILE_TOP + 3.2, -28.72, -28.52, ROT_GREEN, MAT.Neon, TRIM)
	rod(yard, "MemeRadioAerial", Vector3.new(-41.9, TILE_TOP + 3.3, -27.8), Vector3.new(-41.3, TILE_TOP + 6.2, -27.5), 0.1, STEEL_DARK, MAT.Metal, TRIM)

	-- The flag: a concrete block, the pole, the team's colours with the Rot Eye on them.
	box(yard, "Plinth", -4.7, -2.3, TILE_TOP, TILE_TOP + 1.0, -30.2, -27.8, CONCRETE_LIGHT, MAT.Concrete, { tag = false })
	rod(yard, "FlagPole", Vector3.new(-3.5, TILE_TOP + 0.7, -29), Vector3.new(-3.5, 15.5, -29), 0.36, STEEL, MAT.Metal, { tag = "Prop:flag" })
	put(yard, "FlagFinial", Vector3.new(0.6, 0.6, 0.6), CFrame.new(-3.5, 15.6, -29), YELLOW_PAINT, MAT.Metal,
		trimWith({ shape = Enum.PartType.Ball }))
	box(yard, "TeamFlag", -3.5, 1.1, 12.4, 15.2, -29.05, -28.95, B.team, MAT.Fabric, TRIM)
	box(yard, "TeamFlagTatter", 0.2, 1.9, 12.0, 12.9, -28.97, -28.87, mix(B.team, SOOT, 0.35), MAT.Fabric, TRIM)
	-- Through the cloth, so it reads from both sides.
	disc(yard, "FlagEye", Vector3.new(-1.5, 13.9, -29), Vector3.new(0, 0, -1), 0.11, 1.8, WHITE_PAINT, MAT.SmoothPlastic)

	-- The Rot Generator by the west door: a skid-mounted brainrot dynamo, blown, one window still lit,
	-- its cable run across the paving to the bunker.
	local gen = { tag = "Prop:generator" }
	box(yard, "GeneratorSkid", -40, -39.4, TILE_TOP, TILE_TOP + 0.3, 0.1, 3.5, STEEL_DARK, MAT.Metal, gen)
	box(yard, "GeneratorSkid", -36.6, -36, TILE_TOP, TILE_TOP + 0.3, 0.1, 3.5, STEEL_DARK, MAT.Metal, gen)
	box(yard, "RotGenerator", -40, -36, TILE_TOP + 0.3, TILE_TOP + 3.1, 0.3, 3.3, OLIVE, MAT.Metal, gen)
	rod(yard, "GeneratorFlywheel", Vector3.new(-40.3, TILE_TOP + 1.8, 1.8), Vector3.new(-39.7, TILE_TOP + 1.8, 1.8), 2.2, STEEL, MAT.Metal, TRIM)
	rod(yard, "GeneratorExhaust", Vector3.new(-39, TILE_TOP + 3.0, 2.6), Vector3.new(-39, TILE_TOP + 5.4, 2.6), 0.6, RUST, MAT.CorrodedMetal, TRIM)
	local window = box(yard, "GeneratorWindow", -38.8, -37.2, TILE_TOP + 1.3, TILE_TOP + 2.3, 0.22, 0.38, ROT_GREEN, MAT.Neon, TRIM)
	light(window, ROT_GREEN, 8, 0.6)
	facePlate(yard, "Scorch", "z", 0.3, -1, 0.1, -39.8, -38.9, TILE_TOP + 2.4, TILE_TOP + 2.9, SOOT, MAT.Slate)
	local cable = { Vector3.new(-36.2, TILE_TOP + 0.1, 1.6), Vector3.new(-34.2, TILE_TOP + 0.1, 3.4), Vector3.new(-34.6, TILE_TOP + 0.1, 7.9) }
	for index = 1, #cable - 1 do
		rod(yard, "PowerCable", cable[index], cable[index + 1], 0.22, RUBBER, MAT.Plastic, TRIM)
	end
	rod(yard, "PowerCable", Vector3.new(-34.6, TILE_TOP, 7.9), Vector3.new(-34.6, 3.2, 7.9), 0.22, RUBBER, MAT.Plastic, TRIM)

	-- Crates dumped by the front of the bunker.
	box(yard, "Crate", -24.5, -21.5, TILE_TOP, TILE_TOP + 3, 4.4, 7.4, WOOD, MAT.WoodPlanks, { tag = "Crate:front" })
	put(yard, "Crate", Vector3.new(2, 2, 2), CFrame.new(-19.4, TILE_TOP + 1, 5.6) * CFrame.Angles(0, 0.6, 0), WOOD_DARK,
		MAT.WoodPlanks, { tag = "Crate:frontSmall" })

	-- The Rot Cannon: an abandoned brainrot field piece, barrel still cocked at the sky, its coils
	-- glowing, a puddle of goo under the breech.
	local cannon = { tag = "Prop:cannon" }
	for _, x in ipairs({ -13.8, -10.7 }) do
		rod(yard, "CannonWheel", Vector3.new(x, TILE_TOP + 1.1, -8), Vector3.new(x + 0.5, TILE_TOP + 1.1, -8), 2.2, WOOD_DARK, MAT.WoodPlanks, cannon)
	end
	rod(yard, "CannonAxle", Vector3.new(-13.6, TILE_TOP + 1.1, -8), Vector3.new(-10.4, TILE_TOP + 1.1, -8), 0.35, STEEL_DARK, MAT.Metal, cannon)
	box(yard, "CannonCarriage", -13.0, -11.0, TILE_TOP + 1.0, TILE_TOP + 2.0, -10.4, -6.6, OLIVE, MAT.Metal, cannon)
	plateBetween(yard, "CannonTrail", Vector3.new(-12, TILE_TOP + 1.3, -6.8), Vector3.new(-12, TILE_TOP + 0.15, -3.4), 0.8, 0.4, OLIVE, MAT.Metal, cannon)
	local breech, muzzle = Vector3.new(-12, TILE_TOP + 2.2, -8.2), Vector3.new(-12, TILE_TOP + 5.0, -14.4)
	rod(yard, "CannonBarrel", breech, muzzle, 0.9, STEEL_DARK, MAT.Metal, cannon)
	local dir = (muzzle - breech).Unit
	rod(yard, "CannonMuzzle", muzzle - dir * 0.5, muzzle + dir * 0.1, 1.3, STEEL, MAT.Metal, cannon)
	for _, t in ipairs({ 0.35, 0.55 }) do
		local at = breech + (muzzle - breech) * t
		rod(yard, "CannonCoil", at - dir * 0.2, at + dir * 0.2, 1.1, ROT_GREEN, MAT.Neon, TRIM)
	end
	groundDisc(yard, "RotGoo", -12.4, -9.2, 1.6, ROT_GREEN, MAT.Neon, 0)

	-- Sandbags blown in off the west breach, lying where they fell.
	for index, bag in ipairs({ { -42.6, -11.6, 0.4 }, { -40.9, -12.4, 1.2 }, { -42.1, -1.6, 2.1 } }) do
		put(yard, "Sandbag", Vector3.new(BAG_LONG, BAG_HIGH, BAG_DEEP), CFrame.new(bag[1], TILE_TOP + BAG_HIGH / 2 - 0.05, bag[2])
			* CFrame.Angles(0, bag[3], 0.08 * index), SAND[index], MAT.Fabric, { tag = "Sandbags:spill" .. index })
	end

	-- A cable reel on its side.
	local reel = { tag = "Prop:reel" }
	rod(yard, "Reel", Vector3.new(-13.1, TILE_TOP + 1.5, -22), Vector3.new(-12.8, TILE_TOP + 1.5, -22), 3.0, WOOD, MAT.WoodPlanks, reel)
	rod(yard, "Reel", Vector3.new(-11.2, TILE_TOP + 1.5, -22), Vector3.new(-10.9, TILE_TOP + 1.5, -22), 3.0, WOOD, MAT.WoodPlanks, reel)
	rod(yard, "ReelCore", Vector3.new(-12.8, TILE_TOP + 1.5, -22), Vector3.new(-11.2, TILE_TOP + 1.5, -22), 1.8, RUBBER, MAT.Plastic, reel)

	-- The ruin of an older building: a brick corner standing in the courtyard.
	local ruin = Instance.new("Model")
	ruin.Name = "Ruin"
	ruin.Parent = model
	wallPanel(ruin, "x", -6.6, -1, -16, 1.2, 5.6, { color = BRICK, material = MAT.Brick, brick = false })
	wallPanel(ruin, "z", -15.4, -11, -6, 1.2, 4.2, { color = BRICK_DARK, material = MAT.Brick, brick = false })
	rubble(ruin, -3.6, -17.8, 1.4, 5, TILE_TOP, { BRICK, BRICK_DARK, CONCRETE_DARK })

	-- A lamp post at the corner of the bunker.
	box(yard, "LampBase", 0.2, 1.4, TILE_TOP, TILE_TOP + 0.6, 4.6, 5.8, CONCRETE_DARK, MAT.Concrete, { tag = "Prop:lampPost" })
	rod(yard, "LampPost", Vector3.new(0.8, TILE_TOP + 0.5, 5.2), Vector3.new(0.8, 9.8, 5.2), 0.4, STEEL_DARK, MAT.Metal, { tag = "Prop:lampPost" })
	box(yard, "LampArm", -1.2, 0.8, 9.25, 9.55, 5.05, 5.35, STEEL_DARK, MAT.Metal, TRIM)
	box(yard, "LampHead", -1.9, -0.9, 8.75, 9.25, 4.8, 5.6, STEEL_DARK, MAT.Metal, TRIM)
	local glassPart = box(yard, "LampGlass", -1.8, -1.0, 8.65, 8.75, 4.9, 5.5, WARM, MAT.Neon, TRIM)
	light(glassPart, WARM, 26, 1.3)

	table.insert(B.loot, CFrame.new(-13, TILE_TOP, -30))
	table.insert(B.loot, CFrame.new(-36.5, TILE_TOP, -8))
	table.insert(B.loot, CFrame.new(-10, TILE_TOP, -5))
	table.insert(B.loot, CFrame.new(-30, TILE_TOP, 3.5))
	table.insert(B.loot, CFrame.new(-17, TILE_TOP, -15))
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
	buildBunker(model)
	buildSupply(model)
	buildYard(model)
	buildCourtyard(model)

	local info = { frame = frame, pads = {}, chestSpots = {}, vehicleBays = {}, lootSpots = {}, names = { chests = {}, bays = {} },
		localPads = B.pads, localChests = {}, localBays = {}, localLoot = B.loot, doorways = B.doorways }
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
	local size = Vector3.new(TeamBaseRuins.Footprint.X + TeamBaseRuins.Margin * 2, 600, TeamBaseRuins.Footprint.Z + TeamBaseRuins.Margin * 2)
	local cleared, kept = 0, 0
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(frame * CFrame.new(0, 100, 0), size, params)) do
		if loot and part:IsDescendantOf(loot) then
			if not seen[part] then
				seen[part] = true
				part:Destroy()
			end
		elseif not part:GetAttribute("TeamBaseRuin") then
			local item = itemOf(part, map)
			if item and not seen[item] then
				seen[item] = true
				local span = spanOf(item)
				if span <= TeamBaseRuins.ClearableSpan then
					item:Destroy()
					cleared += 1
				else
					kept = math.max(kept, span)
				end
			end
		end
	end
	return cleared, kept
end

-- How good a place `site` is for a compound, lower is better, or nil and why it cannot go there:
-- on a road's corridor, in the river, over another made pad (FlattenPad would refuse all three), or
-- nowhere with ground. The cost is the ground's rise across the footprint plus a heavy charge for
-- anything built there too big for ClearSite to move.
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
	end
	return cost
end

-- Builds the compound for one team: clears the site, levels the ground under it (MapTerrain's
-- FlattenPad, the same pad every building stands on), lays it out at the height the pad actually
-- came out at, puts it in the map and runs the z-fight pass. Where the ground cannot be levelled
-- (a road or another pad in the way), it stands on a concrete plinth down to the lowest ground
-- under it instead, so it is never left floating.
function TeamBaseRuins.Build(baseCFrame, teamColor, mapInfo, seed)
	local map = (mapInfo and mapInfo.map) or workspace:FindFirstChild("Map") or workspace
	local site, yaw = flatFrame(baseCFrame)
	TeamBaseRuins.ClearSite(site, map)

	local height, why = MapTerrain.FlattenPad(site, TeamBaseRuins.Footprint, { height = "mid", margin = TeamBaseRuins.Margin })
	local plinthBottom = nil
	if not height then
		local low, high = MapTerrain.PadCost(site, TeamBaseRuins.Footprint, { margin = TeamBaseRuins.Margin })
		height = high or site.Position.Y
		plinthBottom = low
		warn(string.format("TeamBaseRuins: ground not levelled (%s); on a plinth from %.1f to %.1f", tostring(why),
			low or height, height))
	end
	local position = site.Position
	local frame = CFrame.new(position.X, height, position.Z) * CFrame.Angles(0, yaw, 0)
	local model, info = TeamBaseRuins.Layout(frame, teamColor, seed)
	if plinthBottom and height - plinthBottom > 0.2 then
		local halfX = TeamBaseRuins.Footprint.X / 2 + TeamBaseRuins.Margin
		local halfZ = TeamBaseRuins.Footprint.Z / 2 + TeamBaseRuins.Margin
		local depth = height - plinthBottom + 1
		local plinth = Instance.new("Part")
		plinth.Name = "Foundation"
		plinth.Anchored = true
		plinth.Size = Vector3.new(halfX * 2, depth, halfZ * 2)
		plinth.CFrame = frame * CFrame.new(0, -0.2 - depth / 2, 0)
		plinth.Color = CONCRETE_DARK
		plinth.Material = MAT.Concrete
		plinth:SetAttribute("Destructible", false)
		plinth.Parent = model
	end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part:SetAttribute("TeamBaseRuin", true)
		end
	end
	model.Parent = map
	ZFight.Fix({ model })

	info.model = model
	info.height = height
	return info
end

return TeamBaseRuins
