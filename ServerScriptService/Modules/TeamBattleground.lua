-- The battleground in the middle of a team match (Oliver, 2026-09-24: "make a way better quality and
-- more fun to play around battleground in the centre of the maps for the team gamemodes").
--
--   TeamBattleground.Build(centreCFrame, mapInfo, seed) -> info | nil, reason
--       info = { model, frame, height, objectives = { A, B } (Vector3, on the floor), cover = {Vector3...},
--                lootSpots = { { position, kind, floor, name }... }, ziplines = { model... } }
--   TeamBattleground.Layout(frame, seed) -> model, info      the geometry alone, no terrain, no services
--   TeamBattleground.ClearSite(frame, map) -> cleared, trimmed, kept
--   TeamBattleground.CoverNear(info, origin, radius) -> { Vector3... }   floor points, nearest first
--   TeamBattleground.SeedLoot(info) / TeamBattleground.Destroy(info)
--
-- `centreCFrame` is the arena centre on the ground with its LookVector toward TEAM 1's base. Every
-- position below is in that frame: -Z runs to team 1, +Z to team 2, and X across the fight. The whole
-- thing is built as HALF a battleground (z <= 0) and then the same half again reflected in the plane
-- z = 0, from the same seed, so each team walks into exactly the same ground: the same cover, the same
-- climbs, the same distance to both objectives. Only parts that sit ON that plane and are their own
-- reflection (the fountain, the mast, the objective mosaic) are built once.
--
-- THE LAYOUT (local studs, the half toward team 1; the disc is 126 across the middle, flattened):
--
--                                   z = 0  (the mirror: team 2's half is this, reflected)
--     -110        -84        -48  -30 -22     0      22 30        61   74 84  98   110
--      +--rim------PIT--------+berm+ [L]+----KEEP-----+[B]==== bridge ====+ VEH +-GANTRY-+
--      | colonnade (B)  fountain|tiers| scaf  gallery 11 |ramp  market piers | LANE| mast   |
--      +---rim---[cut]--------+----+  fold  twin stairs +----   stalls     C3|   C2|stairs  |
--        south stair    zip->        colossus  kiosk        shop ruin   C1   bend    crane
--                     (approach)     gatehouse (arch + two towers)            (vehicle route)
--                               perimeter ruin walls, the entry road            z = -126
--
-- THREE LANES. The centre is the KEEP: a two-storey ruin, an open hall on the ground floor and a
-- gallery all round at 11 studs over a central void, reached by twin stairs in the void, a ramp up the
-- east face to a balcony, a scaffold stair up the west face to a landing, and the bridge from the
-- gantry: four ways up, so whoever holds it can be taken off it. Objective A is the middle of its floor.
-- The left lane is THE PIT: a plaza walled in by a raised rim 6 studs up (above eye height, so it
-- cannot be seen into from the flat), entered at ground level through a cut in each side's rim and the
-- gap in the stepped berm on the keep side, and overlooked from the rim and the berm's ridge.
-- Objective B is the fountain in the middle of it. The right lane is THE SCRAPYARD CUT: the vehicle
-- route, 16 wide and doglegged round three containers and the gantry so neither team's cars have a
-- straight run and no rifle does either, under the bridge and past the GANTRY (a platform at 11 with a
-- stair from each side). Between the keep and the cut is the MARKET, the infantry flank.
--
-- Both objectives sit on the mirror plane, so they are exactly as far from one base as the other.
-- Ziplines run from the balcony and the landing down into each team's half of the flanks, the fast
-- way off the high ground. Vehicles go round the keep, never through it: the cut on the right, and
-- the apron all round the outside (ClearSite clears it of buildings, cars and props).
--
-- WHAT BREAKS (DestructibleService). The perimeter ruin and the market's shop ruin are parts named
-- "Wall"; sandbags, crates, containers, the wreck, barriers, tyres and the stalls are tagged pools
-- ("Sandbags:bg12s" and so on: every pool string is numbered and carries its half, so no two pools on
-- the map ever share a key). NEVER breaks: the keep, the gatehouse, the pit, the gantry and the bridge
-- (each a Model tagged false), every floor, stair, ramp, pier and the paving.
--
-- WHAT IS PROVED OFFLINE (tools/team_battleground_check.py runs this module's real source and the real
-- ZFight, DestructibleService and BotNav): the mirror, no coplanar faces, nothing floating, cylinders
-- round, doorways wide and tall enough, the walk from both teams' ends to everything, every high place
-- reached by two ways or more, no trap a bot can fall into and not leave, the longest eye-level line
-- down each lane, cover along every route, the vehicle routes clear, the objectives equidistant, the
-- part budget. What it cannot prove is how it looks: tools/team_battleground_gallery.lua renders it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))

local TeamBattleground = {}

-- The flattened disc (its radius), the flat kept round it, and the ring beyond that ClearSite empties
-- of buildings and scenery so vehicles can drive all the way round.
TeamBattleground.Radius = 126
TeamBattleground.Margin = 4
TeamBattleground.Apron = 24
-- Distinct things standing in the footprint that ClearSite removes whole. A town building is 20-50
-- across and a TownThemes set piece up to about 80; the town model itself and the landmarks are more.
TeamBattleground.ClearableSpan = 90
-- Top-level map models ClearSite never touches.
local KEEP = { Roads = true, River = true, Ziplines = true, TeamBaseVehicles = true, TeamBase1 = true, TeamBase2 = true }

-- Heights, local: the flattened ground is 0.
local TILE = 0.3 -- paving tops
local KF = 0.8 -- the keep's floor
local GAL = 11 -- the keep's gallery, the balcony, the landing, the bridge and the gantry deck
local SILL = 12.8 -- the crenel sill round the gallery (1.8 over its floor: shoot over it standing)
local MERLON = 14.6 -- merlon tops (3.6 over the gallery: cover crouched and standing)
local RISE = 0.84 -- the pit's tiers and the berm's steps
local RIM = TILE + 7 * RISE -- 6.18: the pit's rim, above a standing player's eyes on the flat
local PX = -84 -- the pit's centre on X
local GATE_TOP = 8.5 -- the gatehouse's towers and wall-walk
local ZIP_TOP = GAL + 9.6 -- where the ziplines leave the balcony's and the landing's masts

-- The two objectives: the middle of the keep's floor and the middle of the pit, both on the mirror.
TeamBattleground.ObjectivesLocal = { Vector3.new(0, KF, 0), Vector3.new(PX, TILE, 0) }

--------------------------------------------------------------------------------
-- Palette: team-neutral. Nothing here is orange or teal (the team colours); the arena's own accents
-- are rot green and a faded purple.
--------------------------------------------------------------------------------

local rgb = Color3.fromRGB
local STONE = rgb(198, 184, 150)
local STONE_DARK = rgb(162, 146, 112)
local STONE_LIGHT = rgb(216, 204, 172)
local LIME = rgb(208, 204, 190)
local LIME_DARK = rgb(176, 170, 154)
local BASALT = rgb(76, 74, 80)
local BASALT_LIGHT = rgb(100, 98, 104)
local CONCRETE = rgb(150, 147, 140)
local CONCRETE_DARK = rgb(118, 116, 110)
local PAVING = rgb(138, 134, 124)
local BRICK = rgb(146, 82, 62)
local BRICK_DARK = rgb(116, 64, 48)
local RUST = rgb(118, 70, 42)
local STEEL = rgb(92, 96, 100)
local STEEL_DARK = rgb(58, 61, 64)
local SACK = { rgb(186, 164, 120), rgb(170, 148, 104), rgb(158, 138, 98) }
local SOOT = rgb(34, 32, 30)
local WOOD = rgb(132, 98, 62)
local WOOD_DARK = rgb(96, 72, 48)
local CANVAS = rgb(126, 118, 90)
local RUBBER = rgb(36, 36, 38)
local WHITE_PAINT = rgb(226, 222, 210)
local HAZARD = rgb(222, 196, 64)
local BRONZE = rgb(150, 112, 58)
local ROT_GREEN = rgb(120, 255, 90)
local MELON = rgb(96, 170, 70)
local PURPLE = rgb(122, 84, 184)
local PURPLE_DARK = rgb(84, 58, 128)
local MAROON = rgb(122, 40, 52)
local OLIVE_DRAB = rgb(92, 98, 66)
local NAVY = rgb(52, 70, 118)
local WARM = rgb(255, 190, 120)

local MAT = Enum.Material

--------------------------------------------------------------------------------
-- Part helpers (the same family as TeamBaseRuins', plus the mirror)
--------------------------------------------------------------------------------

-- The build in progress. One at a time; Layout never yields.
local B = nil

local PROUD_BRICK, PROUD_PAINT, PROUD_SOOT = 0.12, 0.2, 0.28

-- The reflection in z = 0 of a part's frame. The position's Z changes sign; the rotation becomes
-- M R F (M the reflection, F a flip of the part's own X), which is a proper rotation again, and
-- every shape built here (block, wedge, cylinder, ball, truss) is symmetric across its own X, so
-- the part it describes is exactly the reflected part.
local function mirrored(cframe)
	local p = cframe.Position
	local r, u, b = cframe.XVector, cframe.YVector, cframe.ZVector
	return CFrame.fromMatrix(Vector3.new(p.X, p.Y, -p.Z), Vector3.new(-r.X, -r.Y, r.Z), Vector3.new(u.X, u.Y, -u.Z),
		Vector3.new(b.X, b.Y, -b.Z))
end

-- A point recorded for the lists (cover, loot, routes) in the half being built.
local function here(x, y, z)
	return Vector3.new(x, y, B.mirror and -z or z)
end

local function put(parent, name, size, at, color, material, opts)
	local part = Instance.new(opts and opts.class or "Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = B.frame * (B.mirror and mirrored(at) or at)
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if opts then
		if opts.shape then
			part.Shape = opts.shape
		end
		if opts.trim then
			-- Dressing: nothing to bump into or shoot, and it goes with the structure it touches.
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
local NEVER = { tag = false }
local function trimWith(extra)
	local opts = { trim = true }
	for key, value in pairs(extra) do
		opts[key] = value
	end
	return opts
end

-- A pool of one breakable thing: its tag string, numbered through the build and marked with the half,
-- so the two reflections (and nothing else on the map) never share one. DestructibleService keys a
-- pool by the string itself.
local function pool(kind)
	B.pools += 1
	return { tag = kind .. ":bg" .. B.pools .. (B.mirror and "n" or "s") }
end

local function folder(parent, name, never)
	local model = Instance.new("Model")
	model.Name = name
	if never then
		model:SetAttribute("Destructible", false)
	end
	model.Parent = parent
	return model
end

local function box(parent, name, x0, x1, y0, y1, z0, z1, color, material, opts)
	return put(parent, name, Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, material, opts)
end

-- A box of size (sx, y1 - y0, sz) standing at (cx, cz), turned `yaw` about the vertical.
local function yawBox(parent, name, cx, cz, yaw, sx, y0, y1, sz, color, material, opts)
	return put(parent, name, Vector3.new(sx, y1 - y0, sz), CFrame.new(cx, (y0 + y1) / 2, cz) * CFrame.Angles(0, yaw, 0),
		color, material, opts)
end

-- A cylinder's frame from end `a` to end `b`. Its length is its X axis (a Cylinder part's round faces
-- are on X), so a standing pole is turned, never sized (d, h, d).
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

local function disc(parent, name, centre, normal, proud, diameter, color, material, opts)
	return rod(parent, name, centre - normal * proud, centre + normal * proud, diameter, color, material, opts or TRIM)
end

local function ball(parent, name, centre, diameter, color, material, opts)
	local o = { shape = Enum.PartType.Ball }
	if opts then
		for key, value in pairs(opts) do
			o[key] = value
		end
	end
	return put(parent, name, Vector3.new(diameter, diameter, diameter), CFrame.new(centre), color, material, o)
end

-- A plate from `a` to `b` (its length on its own Z), `width` across and `thick` through.
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

-- A plate on the face of an axis-aligned wall: `axis` is the face normal's axis, `at` the face's
-- coordinate on it; u runs along the wall. Centred on the face, `proud` out and as deep behind.
local function facePlate(parent, name, axis, at, proud, u0, u1, y0, y1, color, material, opts)
	if axis == "z" then
		return box(parent, name, u0, u1, y0, y1, at - proud, at + proud, color, material, opts or TRIM)
	end
	return box(parent, name, at - proud, at + proud, y0, y1, u0, u1, color, material, opts or TRIM)
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

-- A caged wall lamp on an axis-aligned face; `normal` points out of it.
local function wallLamp(parent, face, normal, range, color)
	local up = Vector3.new(0, 1, 0)
	put(parent, "LampBracket", Vector3.new(0.9, 0.5, 0.9), CFrame.new(face + normal * 0.2), STEEL_DARK, MAT.Metal, TRIM)
	local bulb = ball(parent, "LampBulb", face + normal * 0.75 - up * 0.1, 0.7, color or WARM, MAT.Neon, TRIM)
	rod(parent, "LampCage", face + normal * 0.35 + up * 0.35, face + normal * 1.12 + up * 0.35, 0.12, STEEL_DARK, MAT.Metal, TRIM)
	light(bulb, color or WARM, range, 1.3)
	return bulb
end

local function rnd(a, b)
	return a + (b - a) * B.rng:NextNumber()
end

--------------------------------------------------------------------------------
-- Records: cover spots for the bots, loot, doorways, routes, high ground
--------------------------------------------------------------------------------

-- Where to stand behind something: the floor points `reach` out from each side of the line a..b (a
-- wall, a sandbag line, a container's long side), at its middle and toward each end when it is long.
local function coverLine(ax, az, bx, bz, floor, reach)
	reach = reach or 1.8
	local dx, dz = bx - ax, bz - az
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 0.1 then
		return
	end
	local nx, nz = -dz / length, dx / length
	local count = math.max(1, math.floor(length / 7 + 0.5))
	for index = 1, count do
		local t = (index - 0.5) / count
		local x, z = ax + dx * t, az + dz * t
		for _, side in ipairs({ -1, 1 }) do
			table.insert(B.cover, here(x + nx * reach * side, floor, z + nz * reach * side))
		end
	end
end

-- One spot, where only some sides of a thing have room to stand.
local function coverAt(x, z, floor)
	table.insert(B.cover, here(x, floor, z))
end

-- The same round a block: a spot off the middle of each of its four sides.
local function coverBox(x0, x1, z0, z1, floor, reach)
	reach = reach or 1.8
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	table.insert(B.cover, here(x0 - reach, floor, cz))
	table.insert(B.cover, here(x1 + reach, floor, cz))
	table.insert(B.cover, here(cx, floor, z0 - reach))
	table.insert(B.cover, here(cx, floor, z1 + reach))
end

-- A pickup spot. `kind` is what LootService seeds there ("weapon", "heal", "item", "chest"); `floor`
-- the least rarity a weapon there rolls (nil: any), higher the more exposed the spot.
local function lootSpot(name, x, y, z, kind, floor)
	table.insert(B.loot, { name = name .. (B.mirror and "N" or "S"), at = here(x, y, z), kind = kind, floor = floor })
end

local function doorway(name, x0, x1, z0, z1, floor, top)
	local a, b = z0, z1
	if B.mirror then
		a, b = -z1, -z0
	end
	table.insert(B.doorways, { name = name .. (B.mirror and "N" or "S"), x0 = x0, x1 = x1, z0 = a, z1 = b, floor = floor, top = top })
end

--------------------------------------------------------------------------------
-- Wear: rubble, rebar, sandbags, crates (from TeamBaseRuins' rules)
--------------------------------------------------------------------------------

-- A tilt of 0.15 to 0.35 radians either way: never square, so no face of a chunk lies in a wall's plane.
local TILTS = { 0.16, 0.23, 0.3, 0.35 }
local function tipped()
	B.tilt += 1
	return (B.rng:NextNumber() < 0.5 and -1 or 1) * (TILTS[B.tilt % #TILTS + 1] + rnd(-0.02, 0.02))
end

-- Each chunk turned the golden fraction of a right angle on from the one before.
local GOLDEN = math.pi / 2 * (math.sqrt(5) - 1) / 2
local function nextTurn()
	B.turn += GOLDEN
	return B.turn
end

-- A heap of broken stone round (cx, cz) on ground at `floor`; every chunk sunk a fifth of its height,
-- and no two chunks touching (each one's footprint circle keeps clear of every other's in the build).
local function rubble(parent, cx, cz, radius, count, floor, colors)
	colors = colors or { CONCRETE, CONCRETE_DARK, STONE_DARK }
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

local function rebar(parent, base, length, lean, heading)
	local dir = Vector3.new(math.sin(lean) * math.cos(heading), math.cos(lean), math.sin(lean) * math.sin(heading))
	rod(parent, "Rebar", base - dir * 0.6, base + dir * length, 0.16, RUST, MAT.CorrodedMetal, TRIM)
end

-- A line of sandbags from (x0, z0) to (x1, z1) along X or Z, `courses` high on ground at `floor`. Bags
-- in a course stand 0.06 apart and every other course is offset half a bag, so no two bags' faces
-- share a plane where they overlap; one pool per line. Three courses (2.34) hide a crouching body.
local BAG_LONG, BAG_HIGH, BAG_DEEP, BAG_GAP = 2.3, 0.78, 1.15, 0.06
local function sandbags(parent, x0, z0, x1, z1, courses, floor, noCover)
	local alongX = math.abs(x1 - x0) >= math.abs(z1 - z0)
	local from, to = alongX and math.min(x0, x1) or math.min(z0, z1), alongX and math.max(x0, x1) or math.max(z0, z1)
	local across = alongX and z0 or x0
	local opts = pool("Sandbags")
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
			put(parent, "Sandbag", size, at * CFrame.Angles(0, yaw, 0), SACK[B.rng:NextInteger(1, #SACK)], MAT.Fabric, opts)
		end
	end
	if not noCover and courses >= 3 then
		coverLine(x0, z0, x1, z1, floor, 1.6)
	end
end

-- A stack of crates: `base` crates side by side along X at (x, z) and `top` more on them; one pool.
local function crates(parent, x, z, base, top, floor, size)
	size = size or 3
	local opts = pool("Crate")
	for index = 1, base do
		local cx = x + (index - (base + 1) / 2) * (size + 0.1)
		local color = index % 2 == 0 and WOOD_DARK or WOOD
		box(parent, "Crate", cx - size / 2, cx + size / 2, floor, floor + size, z - size / 2, z + size / 2, color, MAT.WoodPlanks, opts)
		facePlate(parent, "CrateBand", "z", z - size / 2, 0.08, cx - size / 2 + 0.2, cx + size / 2 - 0.2, floor + size * 0.4,
			floor + size * 0.52, STEEL_DARK, MAT.Metal, trimWith({ tag = opts.tag }))
	end
	for index = 1, top do
		local cx = x + (index - (top + 1) / 2) * (size + 0.1) + 0.35
		local s = size * 0.8
		put(parent, "Crate", Vector3.new(s, s, s), CFrame.new(cx, floor + size + s / 2, z + 0.2) * CFrame.Angles(0, 0.21 + index * 0.13, 0),
			WOOD, MAT.WoodPlanks, opts)
	end
	local width = base * (size + 0.1)
	coverBox(x - width / 2, x + width / 2, z - size / 2, z + size / 2, floor)
end

-- Concrete tank teeth: blocks 2.7 high, crouching cover a stride apart. One pool per row.
local function teeth(parent, x, z, count, dx, dz)
	local opts = pool("Prop")
	for index = 0, count - 1 do
		local cx, cz = x + (dx or 3.2) * index, z + (dz or 0) * index
		box(parent, "TankTooth", cx - 1.1, cx + 1.1, -0.3, 2.7, cz - 1.1, cz + 1.1, CONCRETE_DARK, MAT.Concrete, opts)
		local alongZ = (dz or 0) ~= 0
		coverAt(cx + (alongZ and 2.9 or 0), cz + (alongZ and 0 or 2.9), 0)
		coverAt(cx - (alongZ and 2.9 or 0), cz - (alongZ and 0 or 2.9), 0)
	end
end

-- A burning brazier: a stand, a bowl, green fire and its light.
local function brazier(parent, x, z, floor)
	local opts = pool("Prop")
	rod(parent, "BrazierStand", Vector3.new(x, floor + 0.1, z), Vector3.new(x, floor + 2.4, z), 0.5, STEEL_DARK, MAT.Metal, opts)
	rod(parent, "BrazierFoot", Vector3.new(x, floor, z), Vector3.new(x, floor + 0.3, z), 1.6, STEEL_DARK, MAT.Metal, opts)
	rod(parent, "BrazierBowl", Vector3.new(x, floor + 2.4, z), Vector3.new(x, floor + 3.2, z), 2.2, BRONZE, MAT.Metal, opts)
	local fire = ball(parent, "BrazierFire", Vector3.new(x, floor + 3.3, z), 1.5, ROT_GREEN, MAT.Neon, trimWith({ transparency = 0.1 }))
	light(fire, ROT_GREEN, 18, 1.1)
end

--------------------------------------------------------------------------------
-- Walls in any direction
--------------------------------------------------------------------------------

-- One ruined panel from `a` to `b` (ground points, Vector3 with Y ignored), `thick` through, from
-- under the ground to `top`, and its wear. Laid out in the panel's own frame (x along it, z across),
-- so it serves the axis-aligned walls and the perimeter's chords alike.
--   style: name ("Wall" breaks), health, color, material, plain (no wear), brick (render off), low
--          (a stub beside a gap), soot, base (the floor it stands on; default 0)
local function panel(parent, ax, az, bx, bz, thick, top, style)
	style = style or {}
	local dx, dz = bx - ax, bz - az
	local length = math.sqrt(dx * dx + dz * dz)
	local yaw = math.atan2(-dz, dx)
	local mid = Vector3.new((ax + bx) / 2, 0, (az + bz) / 2)
	local frame = CFrame.new(mid) * CFrame.Angles(0, yaw, 0)
	local base = style.base or 0
	local color = style.color or CONCRETE
	local material = style.material or MAT.Concrete
	local half = thick / 2
	-- Buried a stud; `style.bottom` deeper where two runs meet at an angle and their feet overlap, so the
	-- two bottom faces are never in one plane.
	local bottom = style.bottom or (base - 1)
	local wall = put(parent, style.name or "Wall", Vector3.new(length, top - bottom, thick), frame * CFrame.new(0, (top + bottom) / 2, 0),
		color, material, { health = style.health, tag = style.tag })
	local function at(u, y, w)
		return frame * CFrame.new(u, y, w)
	end
	local inset = 0.5
	if not style.plain and length > 3.2 then
		if B.rng:NextNumber() < 0.6 then
			-- A broken lump on the top, tipped along the wall.
			local lump = math.min(length - 1.6, rnd(1.4, 3.0))
			local tilt = rnd(-0.14, 0.14)
			local spare = (length - 2 * inset - lump * math.cos(tilt) - 1.2 * math.abs(math.sin(tilt))) / 2
			local u = spare > 0 and rnd(-spare, spare) or 0
			local h = rnd(0.7, 1.2)
			put(parent, "BrokenTop", Vector3.new(lump, h, thick * 0.85), at(u, top + h * 0.3, 0) * CFrame.Angles(0, 0, tilt), color, material, TRIM)
		end
		local bars = style.low and 3 or B.rng:NextInteger(0, style.light and 1 or 2)
		local from, share = -length / 2 + inset + 0.3, (length - 2 * inset - 0.6) / math.max(bars, 1)
		for bar = 1, bars do
			local u = from + (bar - 0.5) * share + rnd(-0.2, 0.2) * math.min(1, share)
			rebar(parent, at(u, top, rnd(-half * 0.5, half * 0.5)).Position, rnd(1.0, 2.3), rnd(0.05, 0.4), rnd(0, math.pi * 2))
		end
	end
	-- Plates on a face stand proud of it by a fixed step per kind, their ends on a half-stud grid
	-- from the panel's start at an offset per kind, so no two plates' faces or edges share a plane.
	local function span(offset, want)
		local steps = math.max(1, math.floor(math.min(want, length - 2 * inset - 0.5) / 0.5))
		local slots = math.floor((length - 2 * inset - 0.5 - steps * 0.5) / 0.5)
		local first = -length / 2 + offset + 0.5 * (1 + (slots > 0 and B.rng:NextInteger(0, slots) or 0))
		return first, first + steps * 0.5
	end
	if not style.plain and not style.light and style.brick ~= false and B.rng:NextNumber() < 0.55 and top - base > 3.4 and length > 3 then
		local side = B.rng:NextNumber() < 0.5 and 1 or -1
		local a, b = span(0.2, rnd(2.0, 3.6))
		local y0 = base + math.floor(rnd(0.9, math.max(1.0, top - base - 3.0)) * 2) / 2 + 0.2
		local y1 = base + math.floor(math.min(top - base - 0.6, y0 - base + rnd(1.4, 2.6)) * 2) / 2 + 0.2
		if y1 > y0 + 0.6 then
			put(parent, "BrickCourse", Vector3.new(b - a, y1 - y0, PROUD_BRICK * 2), at((a + b) / 2, (y0 + y1) / 2, side * half),
				B.rng:NextNumber() < 0.5 and BRICK or BRICK_DARK, MAT.Brick, TRIM)
		end
	end
	if not style.plain and (style.low or style.soot or B.rng:NextNumber() < 0.3) and length > 2.4 then
		local side = B.rng:NextNumber() < 0.5 and 1 or -1
		local a, b = span(-0.05, rnd(2.2, 3.8))
		local y1 = base + math.floor(math.min(top - base - 0.3, rnd(3.6, 5.0)) * 2) / 2
		if y1 > base + 1.2 then
			put(parent, "Scorch", Vector3.new(b - a, y1 - base - 0.4, PROUD_SOOT * 2), at((a + b) / 2, (base + 0.4 + y1) / 2, side * half),
				SOOT, MAT.Slate, TRIM)
		end
	end
	return wall, frame
end

-- A run of ruined wall from `a` to `b` in panels about 6.5 long of uneven height between lo and hi.
local function wallRun(parent, ax, az, bx, bz, thick, lo, hi, style)
	local dx, dz = bx - ax, bz - az
	local length = math.sqrt(dx * dx + dz * dz)
	local count = math.max(1, math.floor(length / 6.5 + 0.5))
	for index = 1, count do
		local t0, t1 = (index - 1) / count, index / count
		local low = style and style.lowEnds and (index == 1 or index == count)
		local top = low and rnd(3.0, 3.8) or rnd(lo, hi)
		local s = {}
		for key, value in pairs(style or {}) do
			s[key] = value
		end
		s.low = low
		panel(parent, ax + dx * t0, az + dz * t0, ax + dx * t1, az + dz * t1, thick, top, s)
	end
	coverLine(ax, az, bx, bz, 0, thick / 2 + 1.6)
end

-- Merlons along an axis-aligned wall top: `axis` is the direction the wall runs ("x" or "z"), `c` its
-- centre line across, u0..u1 its run, from `y` up to MERLON-y high. 2.2 long, about 1.6 apart, set
-- 0.1 in from both faces of a wall `thick` through.
local function merlons(parent, axis, c, u0, u1, thick, y, height, color)
	local long, gap = 2.2, 1.6
	local count = math.floor((u1 - u0 + gap) / (long + gap))
	if count < 1 then
		return
	end
	local step = count > 1 and (u1 - u0 - long) / (count - 1) or 0
	local half = thick / 2 - 0.1
	for index = 1, count do
		local u = u0 + (index - 1) * step
		if axis == "x" then
			box(parent, "Merlon", u, u + long, y, y + height, c - half, c + half, color or STONE, MAT.Limestone, NEVER)
		else
			box(parent, "Merlon", c - half, c + half, y, y + height, u, u + long, color or STONE, MAT.Limestone, NEVER)
		end
	end
end

-- A straight flight of solid steps along Z: its foot at zFoot (on the floor at yFoot), its head at
-- zHead where the upper floor (at yHead) begins; `rises` equal rises, the last one up onto that
-- floor, so rises - 1 steps share the run. Each step is a solid block down to `bottom`.
local function flightZ(parent, name, x0, x1, zFoot, zHead, yFoot, yHead, rises, color, material, bottom)
	local tread = (zHead - zFoot) / (rises - 1)
	local rise = (yHead - yFoot) / rises
	for k = 1, rises - 1 do
		local za, zb = zFoot + tread * (k - 1), zFoot + tread * k
		box(parent, name, x0, x1, bottom or (yFoot - 0.5), yFoot + rise * k, math.min(za, zb), math.max(za, zb), color, material, NEVER)
	end
end

local function flightX(parent, name, z0, z1, xFoot, xHead, yFoot, yHead, rises, color, material, bottom)
	local tread = (xHead - xFoot) / (rises - 1)
	local rise = (yHead - yFoot) / rises
	for k = 1, rises - 1 do
		local xa, xb = xFoot + tread * (k - 1), xFoot + tread * k
		box(parent, name, math.min(xa, xb), math.max(xa, xb), bottom or (yFoot - 0.5), yFoot + rise * k, z0, z1, color, material, NEVER)
	end
end

-- The top of the step of such a flight at `u` along it (for posts and rails standing on it).
local function flightTop(foot, head, yFoot, yHead, rises, u)
	local tread = (head - foot) / (rises - 1)
	local k = math.clamp(math.ceil((u - foot) / tread), 1, rises - 1)
	return yFoot + (yHead - yFoot) / rises * k
end

-- Concrete paving over a rectangle: nx by nz slabs with 0.2 cracks between, "Paving" (never breaks),
-- sunk a stud; `skip` is a set of "i,j" slabs that are gone.
local function paving(parent, x0, x1, z0, z1, nx, nz, colors, material, skip, top)
	top = top or TILE
	local w, d = (x1 - x0) / nx, (z1 - z0) / nz
	for i = 1, nx do
		for j = 1, nz do
			if not (skip and skip[i .. "," .. j]) then
				box(parent, "Paving", x0 + (i - 1) * w + 0.1, x0 + i * w - 0.1, top - 1, top, z0 + (j - 1) * d + 0.1, z0 + j * d - 0.1,
					colors[B.rng:NextInteger(1, #colors)], material or MAT.Concrete, NEVER)
			end
		end
	end
end

-- A mark on the floor (a crack, soot, goo): a flat disc, lifted 0.08 a level so overlaps never share a plane.
local function groundDisc(parent, name, x, z, diameter, color, material, level, floor)
	local y = (floor or TILE) + 0.08 * (level or 0)
	return rod(parent, name, Vector3.new(x, y - 0.06, z), Vector3.new(x, y + 0.06, z), diameter, color, material, TRIM)
end

local function groundMark(parent, name, x, z, sizeX, sizeZ, yaw, color, material, level, floor)
	local centre = (floor or TILE) + 0.08 * (level or 0)
	return put(parent, name, Vector3.new(sizeX, 0.12, sizeZ), CFrame.new(x, centre, z) * CFrame.Angles(0, yaw, 0), color, material, TRIM)
end

--------------------------------------------------------------------------------
-- The keep (objective A): 44 x 44, walls at x, z = +/-22; the half toward team 1
--------------------------------------------------------------------------------

-- The keep's gallery runs round a void 20 across (|x|, |z| < 10). The void is that size, and the twin
-- stairs stand inside it, because of how bots hold an objective: BotService sends each one to a point
-- HILL_SPREAD (0.55) of the objective's radius out from its middle, 15.4 studs, at the floor's height.
-- Every one of those points is on open floor under the gallery; nothing on the ground floor stands
-- between 12.9 and 17.9 from the middle (a bot's 2.5 either side of that ring).
local VOID = 10

local function keepWall(keep, x0, x1, y0, y1, z0, z1, color)
	return box(keep, "KeepWall", x0, x1, y0, y1, z0, z1, color or STONE, MAT.Limestone, NEVER)
end

local function buildKeep(root)
	local keep = folder(root, "Keep", true)

	-- The floor: a slab under dark flagstones, 0.2 cracks between them.
	box(keep, "Foundation", -20, 20, -0.7, 0.6, -20, 0, BASALT, MAT.Slate, NEVER)
	for i = 0, 4 do
		local x0 = -20 + i * 8
		local shade = i % 2 == 0 and BASALT_LIGHT or mix(BASALT_LIGHT, STONE_DARK, 0.25)
		box(keep, "Paving", x0 + 0.1, x0 + 7.9, 0.5, KF, -19.9, -0.1, shade, MAT.Slate, NEVER)
	end
	-- Thresholds in the doorways, level with the flagstones.
	box(keep, "Foundation", -15, -9, -0.7, KF, -22, -20, BASALT, MAT.Slate, NEVER)
	box(keep, "Foundation", 6, 13, -0.7, KF, -22, -20, BASALT, MAT.Slate, NEVER)
	box(keep, "Foundation", -22, -20, -0.7, KF, -4, 0, BASALT, MAT.Slate, NEVER)
	box(keep, "Foundation", 20, 22, -0.7, KF, -4, 0, BASALT, MAT.Slate, NEVER)
	doorway("KeepDoor", -15, -9, -22, -20, KF, 9.8)
	doorway("KeepBreach", 6, 13, -22, -20, KF, 40)
	doorway("KeepWestDoor", -22, -20, -4, 0, KF, 9.8)
	doorway("KeepEastDoor", 20, 22, -4, 0, KF, 9.8)
	doorway("KeepWestUpper", -22, -20, -4, 0, GAL, 40)
	doorway("KeepEastUpper", 20, 22, -4, 0, GAL, 40)

	-- South wall (z -22..-20): the door, a panel, the breach, and the corner that still stands to 19.
	keepWall(keep, -22, -15, -1, SILL, -22, -20)
	keepWall(keep, -15, -9, 9.8, SILL, -22, -20)
	keepWall(keep, -9, 6, -1, SILL, -22, -20)
	keepWall(keep, 13, 16, -1, SILL, -22, -20)
	keepWall(keep, 16, 22, -1, 19, -22, -20, STONE_DARK)
	-- West wall (x -22..-20), to the door; over the door a lintel to the gallery floor and nothing above
	-- it: the way out onto the landing.
	keepWall(keep, -22, -20, -1, SILL, -20, -4)
	keepWall(keep, -22, -20, 9.8, GAL, -4, 0)
	-- East wall: the tall ruin of the upper storey over the south end, a window in it at the gallery's
	-- eye height; then the door, under the way out onto the balcony.
	keepWall(keep, 20, 22, -1, 13.5, -20, -12, STONE_DARK)
	keepWall(keep, 20, 22, 13.5, 16.5, -20, -17.5, STONE_DARK)
	keepWall(keep, 20, 22, 13.5, 16.5, -14.5, -12, STONE_DARK)
	keepWall(keep, 20, 22, 16.5, 19, -20, -12, STONE_DARK)
	keepWall(keep, 20, 22, -1, SILL, -12, -4)
	keepWall(keep, 20, 22, 9.8, GAL, -4, 0)

	-- Crenellation round the gallery.
	merlons(keep, "x", -21, -22, 6, 2, SILL, MERLON - SILL)
	merlons(keep, "x", -21, 13, 16, 2, SILL, MERLON - SILL)
	merlons(keep, "z", -21, -20, -4.6, 2, SILL, MERLON - SILL)
	merlons(keep, "z", 21, -12, -4.6, 2, SILL, MERLON - SILL)
	-- The corner's broken top, and a dark string course round the outside at the gallery's floor.
	put(keep, "BrokenTop", Vector3.new(4.2, 1.1, 1.7), CFrame.new(18.6, 19.3, -21) * CFrame.Angles(0, 0, 0.12), STONE_DARK, MAT.Limestone, TRIM)
	put(keep, "BrokenTop", Vector3.new(1.7, 0.9, 5.2), CFrame.new(21, 19.25, -15.8) * CFrame.Angles(0.1, 0, 0), STONE_DARK, MAT.Limestone, TRIM)
	facePlate(keep, "StringCourse", "z", -22, 0.14, -21.8, -15.2, 10.2, 10.8, BASALT, MAT.Basalt)
	facePlate(keep, "StringCourse", "z", -22, 0.14, -8.8, 5.8, 10.2, 10.8, BASALT, MAT.Basalt)
	facePlate(keep, "StringCourse", "z", -22, 0.14, 13.2, 21.8, 10.2, 10.8, BASALT, MAT.Basalt)
	facePlate(keep, "StringCourse", "x", -22, 0.14, -19.8, -4.2, 10.2, 10.8, BASALT, MAT.Basalt)
	-- The breach: rebar out of both broken ends, soot up the panels beside it, the fall outside.
	for index = 0, 1 do
		local y = 3.2 + index * 4.4
		rod(keep, "Rebar", Vector3.new(5.4, y, -21 + (index % 2) * 0.5 - 0.25), Vector3.new(6.9, y + 0.3, -21.2 + (index % 2) * 0.4),
			0.16, RUST, MAT.CorrodedMetal, TRIM)
		rod(keep, "Rebar", Vector3.new(13.6, y + 1.1, -20.8 - (index % 2) * 0.4), Vector3.new(12.1, y + 1.5, -21 + (index % 2) * 0.3),
			0.16, RUST, MAT.CorrodedMetal, TRIM)
	end
	facePlate(keep, "Scorch", "z", -22, PROUD_SOOT, 2.5, 5.5, 0.4, 7.5, SOOT, MAT.Slate)
	facePlate(keep, "Scorch", "z", -22, PROUD_SOOT, 13.5, 15.5, 0.4, 6.0, SOOT, MAT.Slate)
	rubble(keep, 4.2, -24.4, 1.6, 5, 0, { STONE, STONE_DARK, CONCRETE_DARK })
	rubble(keep, 15.2, -24.2, 1.4, 4, 0, { STONE, STONE_DARK, CONCRETE_DARK })
	-- Rot goo weeping down the front from the gallery's drains.
	for _, drip in ipairs({ { -18.5, 3.4 }, { 17.9, 2.6 } }) do
		facePlate(keep, "GooDrip", "z", -22, 0.06, drip[1] - 0.22, drip[1] + 0.22, drip[2], 10.1, ROT_GREEN, MAT.Neon)
	end

	-- The gallery floor, round the void, and a low broken balustrade along the void's edge.
	box(keep, "GalleryFloor", -20, 20, GAL - 1, GAL, -20, -VOID, STONE_DARK, MAT.Cobblestone, NEVER)
	box(keep, "GalleryFloor", -20, -VOID, GAL - 1, GAL, -VOID, 0, STONE_DARK, MAT.Cobblestone, NEVER)
	box(keep, "GalleryFloor", VOID, 20, GAL - 1, GAL, -VOID, 0, STONE_DARK, MAT.Cobblestone, NEVER)
	for _, run in ipairs({ { -9.6, -7.2 }, { 0.4, 3.6 }, { 5.2, 9.6 } }) do
		box(keep, "Balustrade", run[1], run[2], GAL, GAL + 1.2, -10.9, -10.1, STONE_LIGHT, MAT.Limestone, NEVER)
	end
	box(keep, "Balustrade", 10.1, 10.9, GAL, GAL + 1.2, -8.8, -2.5, STONE_LIGHT, MAT.Limestone, NEVER)
	box(keep, "Balustrade", -10.9, -10.1, GAL, GAL + 1.2, -8.8, -4.2, STONE_LIGHT, MAT.Limestone, NEVER)
	facePlate(keep, "GalleryFascia", "z", -VOID, 0.12, -0.6, 9.8, GAL - 0.9, GAL - 0.3, BASALT, MAT.Basalt)
	facePlate(keep, "GalleryFascia", "z", -VOID, 0.12, -9.8, -6.9, GAL - 0.9, GAL - 0.3, BASALT, MAT.Basalt)

	-- The twin stair: from the middle of the floor up to each side's gallery, 12 rises of 0.85.
	local stairFoot, stairRises = -0.2, 12
	flightZ(keep, "KeepStair", -6.5, -1, stairFoot, -VOID, KF, GAL, stairRises, STONE_LIGHT, MAT.Limestone, KF - 0.2)
	local postTops = {}
	for index = 0, 1 do
		local z = -1.6 - index * 6.2
		local top = flightTop(stairFoot, -VOID, KF, GAL, stairRises, z)
		rod(keep, "StairPost", Vector3.new(-1.35, top - 0.4, z), Vector3.new(-1.35, top + 2.8, z), 0.22, STEEL_DARK, MAT.Metal, TRIM)
		table.insert(postTops, Vector3.new(-1.35, top + 2.8, z))
	end
	rod(keep, "StairRail", postTops[1], postTops[#postTops], 0.16, STEEL, MAT.Metal, TRIM)

	-- On the floor: a fallen bell in the void (cover in the middle of the fight), braziers in the
	-- corners, lamps on the walls.
	local bellA, bellB = Vector3.new(3.2, KF + 2.3, -5.4), Vector3.new(7.4, KF + 2.3, -5.4)
	rod(keep, "FallenBell", bellA, bellB, 4.6, BRONZE, MAT.Metal)
	rod(keep, "BellLip", bellB - Vector3.new(0.3, 0, 0), bellB + Vector3.new(0.3, 0, 0), 5.1, mix(BRONZE, SOOT, 0.2), MAT.Metal)
	disc(keep, "BellMouth", bellB + Vector3.new(0.3, 0, 0), Vector3.new(1, 0, 0), 0.06, 4.2, SOOT, MAT.Slate)
	box(keep, "BellCrown", 2.2, 3.4, KF + 1.4, KF + 3.2, -6.0, -4.8, mix(BRONZE, SOOT, 0.3), MAT.Metal)
	coverBox(3.2, 7.4, -7.7, -3.1, KF)
	brazier(keep, -17, -17, KF)
	brazier(keep, 17, -17, KF)
	wallLamp(keep, Vector3.new(-3, 7.6, -20), Vector3.new(0, 0, 1), 24)
	wallLamp(keep, Vector3.new(-8, GAL + 1.2, -20), Vector3.new(0, 0, 1), 20, ROT_GREEN)
	-- Banners in the arena's purple, hanging from under the gallery against the south wall.
	for _, x in ipairs({ -18 }) do
		rod(keep, "BannerRod", Vector3.new(x - 2.2, GAL - 1.15, -19.6), Vector3.new(x + 2.2, GAL - 1.15, -19.6), 0.3, STEEL_DARK, MAT.Metal, TRIM)
		box(keep, "Banner", x - 1.8, x + 1.8, 3.4, GAL - 1.15, -19.72, -19.6, PURPLE, MAT.Fabric, TRIM)
		disc(keep, "BannerEye", Vector3.new(x, 7.6, -19.54), Vector3.new(0, 0, 1), 0.06, 2.2, WHITE_PAINT, MAT.SmoothPlastic)
		disc(keep, "BannerPupil", Vector3.new(x + 0.2, 7.5, -19.46), Vector3.new(0, 0, 1), 0.06, 0.9, ROT_GREEN, MAT.Neon)
	end

	-- Cover spots on the gallery: behind the merlons and the balustrade.
	for _, x in ipairs({ -16, -8, 0, 8 }) do
		table.insert(B.cover, here(x + 1.1, GAL, -18.4))
	end
	table.insert(B.cover, here(-18.4, GAL, -12))
	table.insert(B.cover, here(18.4, GAL, -8))
	table.insert(B.cover, here(2, GAL, -12))
	lootSpot("KeepVoid", 5.2, KF, -0.6, "weapon", "Rare")
	lootSpot("Balcony", 25, GAL, -2.5, "weapon", "Epic")
	lootSpot("KeepGallery", 15, GAL, -15, "chest")
	lootSpot("KeepHall", -15.5, KF, -6.5, "heal")

	-- OUTSIDE, EAST: the balcony over the door, its pillar, and the ramp up the face to it.
	box(keep, "KeepBalcony", 22, 30, GAL - 1, GAL, -5, 0, STONE_DARK, MAT.Cobblestone, NEVER)
	box(keep, "KeepPillar", 28.2, 29.8, -1, GAL - 1, -4.8, -3.2, STONE, MAT.Limestone, NEVER)
	put(keep, "KeepRamp", Vector3.new(6, GAL, 29), CFrame.new(25, GAL / 2, -19.5), STONE, MAT.Cobblestone, { class = "WedgePart", tag = false })
	plateBetween(keep, "RampKerb", Vector3.new(27.6, 0.15, -34), Vector3.new(27.6, GAL + 0.15, -5), 0.6, 0.6, BASALT, MAT.Basalt, TRIM)
	box(keep, "KeepRail", 28, 30, GAL, GAL + 1.1, -5, -4.6, STEEL_DARK, MAT.Metal, NEVER)
	doorway("KeepPorchEast", 22, 28, -5, 0, 0, GAL - 1)
	-- The zipline's mast at the balcony's corner, its arm out past the edge: the line runs from under
	-- the arm, so a rider hangs clear of the balcony from the start.
	box(keep, "ZipMast", 29, 29.6, GAL - 0.4, ZIP_TOP + 0.6, -4.9, -4.3, STEEL_DARK, MAT.Metal, NEVER)
	box(keep, "ZipArm", 29, 29.6, ZIP_TOP, ZIP_TOP + 0.6, -6.6, -4.9, STEEL_DARK, MAT.Metal, NEVER)

	-- OUTSIDE, WEST: the landing over the door on a timber post, and the stone stair to it with its
	-- scaffold of poles.
	box(keep, "ScaffoldDeck", -30, -22, GAL - 1, GAL, -5, 0, WOOD, MAT.WoodPlanks, NEVER)
	box(keep, "ScaffoldPost", -30, -29, -0.5, GAL - 1, -5, -4, WOOD_DARK, MAT.Wood, NEVER)
	flightZ(keep, "ScaffoldStair", -30, -22, -27, -5, 0, GAL, 13, STONE, MAT.Cobblestone, -0.5)
	local poleTops = {}
	for _, z in ipairs({ -24, -10 }) do
		local top = flightTop(-27, -5, 0, GAL, 13, z)
		rod(keep, "ScaffoldPole", Vector3.new(-29.7, top - 0.4, z), Vector3.new(-29.7, top + 4.2, z), 0.35, WOOD_DARK, MAT.Wood, TRIM)
		table.insert(poleTops, Vector3.new(-29.7, top + 3.2, z))
	end
	plateBetween(keep, "ScaffoldRail", poleTops[1], poleTops[#poleTops], 0.25, 0.25, WOOD, MAT.Wood, TRIM)
	doorway("KeepPorchWest", -29, -22, -5, 0, 0, GAL - 1)
	-- The landing's zipline mast, straight up from its post, the arm out over the edge.
	box(keep, "ZipMast", -29.6, -29, GAL - 0.4, ZIP_TOP + 0.6, -4.9, -4.3, WOOD_DARK, MAT.Wood, NEVER)
	box(keep, "ZipArm", -31.6, -29.6, ZIP_TOP, ZIP_TOP + 0.6, -4.9, -4.3, WOOD_DARK, MAT.Wood, NEVER)
	return keep
end

--------------------------------------------------------------------------------
-- A sign with words on it (both faces), for the brainrot touches
--------------------------------------------------------------------------------

local function signText(part, text, color)
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 0.4
		gui.Parent = part
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextColor3 = color
		label.Text = text
		label.Parent = gui
	end
end

--------------------------------------------------------------------------------
-- The forecourt: in front of the keep's south face
--------------------------------------------------------------------------------

local function buildForecourt(root)
	local court = folder(root, "Forecourt")
	-- Cracked paving; two slabs gone, one under the fallen colossus and one blown out by the breach.
	local ground = folder(court, "Paving", true)
	paving(ground, -21.9, 21, -40, -22.2, 4, 2, { PAVING, CONCRETE_DARK, CONCRETE }, MAT.Concrete, { ["2,1"] = true, ["4,2"] = true })
	groundDisc(ground, "BlastMark", 15.1, -26.7, 6.4, mix(SOOT, CONCRETE_DARK, 0.35), MAT.Slate, 0, 0)
	groundDisc(ground, "BlastMark", 15.4, -26.9, 3.4, SOOT, MAT.Slate, 1, 0)
	for _, at in ipairs({ { -18, -27 }, { 6, -32 } }) do
		groundMark(ground, "Crack", at[1], at[2], rnd(2.5, 4.8), 0.22, rnd(0.2, 1.3), SOOT, MAT.Slate, 0)
	end

	-- THE SAHUR COLOSSUS: the carved log head of a giant brainrot drummer, toppled on its side in front
	-- of the keep's door, its eyes still lit. It stands between the door and the lane, so nobody sees
	-- (or shoots) straight in at the door from the gatehouse.
	local colossus = folder(court, "SahurColossus", true)
	local cx, cy, cz, radius = -12, 4.2, -34, 4.2
	rod(colossus, "ColossusHead", Vector3.new(cx - 4.5, cy, cz), Vector3.new(cx + 4.5, cy, cz), radius * 2, WOOD, MAT.Wood)
	rod(colossus, "ColossusCap", Vector3.new(cx - 4.9, cy, cz), Vector3.new(cx - 4.5, cy, cz), radius * 2 - 0.9, WOOD_DARK, MAT.Wood)
	disc(colossus, "ColossusRings", Vector3.new(cx + 4.5, cy, cz), Vector3.new(1, 0, 0), 0.08, radius * 2 - 1.6, mix(WOOD, WOOD_DARK, 0.5), MAT.Wood)
	local function onFace(x, lift, proud, diameter, color, material, name)
		local normal = Vector3.new(0, lift, -math.sqrt(1 - lift * lift))
		disc(colossus, name, Vector3.new(x, cy, cz) + normal * radius, normal, proud, diameter, color, material)
	end
	onFace(cx - 2, 0.34, 0.1, 2.3, WHITE_PAINT, MAT.SmoothPlastic, "ColossusEye")
	onFace(cx + 2, 0.34, 0.1, 2.3, WHITE_PAINT, MAT.SmoothPlastic, "ColossusEye")
	onFace(cx - 1.8, 0.34, 0.2, 1.0, ROT_GREEN, MAT.Neon, "ColossusPupil")
	onFace(cx + 2.2, 0.34, 0.2, 1.0, ROT_GREEN, MAT.Neon, "ColossusPupil")
	onFace(cx, -0.3, 0.1, 2.4, SOOT, MAT.Slate, "ColossusMouth")
	-- His drumstick, dropped where he fell.
	local batA, batB = Vector3.new(-26, 0.75, -45), Vector3.new(-18.5, 0.75, -40.5)
	rod(colossus, "ColossusBat", batA, batB, 1.5, WOOD_DARK, MAT.Wood)
	ball(colossus, "ColossusBatKnob", batA - (batB - batA).Unit * 0.4, 1.9, WOOD_DARK, MAT.Wood)
	coverBox(cx - 4.9, cx + 4.5, cz - radius, cz + radius, TILE)

	-- The pedestal he stood on, in the middle of the approach, his bronze sandals still on it: the lines
	-- up the middle of the lane stop against it.
	local pedestal = folder(court, "ColossusPedestal", true)
	box(pedestal, "Plinth", -7.6, 6.4, -0.3, 1.2, -54, -47, STONE_DARK, MAT.Limestone, NEVER)
	box(pedestal, "Plinth", -7, 5.8, 1.2, 6, -53.4, -47.6, STONE, MAT.Limestone, NEVER)
	box(pedestal, "PlinthCap", -7.3, 6.1, 6, 6.5, -53.7, -47.3, STONE_LIGHT, MAT.Limestone, NEVER)
	for _, x in ipairs({ -3.6, 1.2 }) do
		box(pedestal, "BronzeSandal", x - 1.3, x + 1.3, 6.5, 7.3, -52.6, -48.2, BRONZE, MAT.Metal, NEVER)
		box(pedestal, "BronzeAnkle", x - 0.9, x + 0.9, 7.3, 8.6, -51.1, -49.5, BRONZE, MAT.Metal, NEVER)
		rebar(pedestal, Vector3.new(x, 8.6, -50.3), 1.1, 0.2, x)
	end
	local plaque = facePlate(pedestal, "Plaque", "z", -53.4, 0.1, -3.2, 0.8, 2.6, 4.2, BRONZE, MAT.Metal)
	signText(plaque, "IL GRANDE SAHUR · FELL OVER", SOOT)
	coverAt(-1.2, -56, 0)
	coverAt(-9.6, -50.5, 0)
	coverAt(8.4, -50.5, 0)
	coverAt(-1.2, -45, TILE)

	-- The Rot-Cola kiosk in front of the breach, near enough that the breach has no long line in either.
	local kiosk = folder(court, "RotKiosk", true)
	local paint = mix(PURPLE, CONCRETE, 0.45)
	box(kiosk, "KioskBody", 5.5, 13.5, -0.5, 6.4, -41, -35, paint, MAT.Concrete, NEVER)
	box(kiosk, "KioskRoof", 4.9, 14.1, 6.4, 7.0, -41.6, -34.4, PURPLE_DARK, MAT.Concrete, NEVER)
	facePlate(kiosk, "KioskHatch", "z", -35, 0.1, 6.7, 12.3, 2.8, 4.9, SOOT, MAT.Slate)
	box(kiosk, "KioskCounter", 6.5, 12.5, 2.6, 2.9, -35, -34.3, WOOD, MAT.WoodPlanks, TRIM)
	facePlate(kiosk, "KioskStripe", "z", -41, PROUD_PAINT, 5.8, 13.2, 5.2, 5.8, ROT_GREEN, MAT.Neon)
	local sign = box(kiosk, "KioskSign", 6.8, 12.2, 7.0, 8.6, -38.1, -37.9, WHITE_PAINT, MAT.SmoothPlastic, TRIM)
	signText(sign, "ROT-COLA", PURPLE_DARK)
	light(box(kiosk, "KioskLamp", 9.1, 9.9, 6.1, 6.4, -34.9, -34.4, WARM, MAT.Neon, TRIM), WARM, 16, 1)
	coverAt(9.5, -33, TILE)
	coverAt(9.5, -43, TILE)
	coverAt(3.6, -38, TILE)

	-- Sandbags, crates and braziers: cover every few strides across the forecourt.
	teeth(court, -22.4, -46.5, 3)
	sandbags(court, 14, -29.5, 20.5, -29.5, 3, 0)
	sandbags(court, 2.5, -63, 8.5, -63, 3, 0)
	crates(court, 2.5, -31, 2, 1, TILE)
	brazier(court, -17, -24.8, TILE)
	brazier(court, -7, -24.8, TILE)
	-- A stretch of old market wall across the west of the court.
	wallRun(court, -30, -51, -18, -51, 1.2, 4.8, 6.2, { name = "Wall", health = 150, color = BRICK, material = MAT.Brick, brick = false })
	rubble(court, -15.8, -52.4, 1.4, 4, 0, { BRICK, BRICK_DARK, CONCRETE_DARK })
	lootSpot("Forecourt", 1.5, TILE, -38.5, "weapon")
	return court
end

--------------------------------------------------------------------------------
-- The gatehouse: two towers and a wall-walk across the centre lane, each team's own perch
--------------------------------------------------------------------------------

local function buildGatehouse(root)
	local gate = folder(root, "Gatehouse", true)
	box(gate, "GateTower", -20, -13, -1, GATE_TOP, -72, -65, STONE, MAT.Limestone, NEVER)
	box(gate, "GateTower", 13, 20, -1, GATE_TOP, -72, -65, STONE, MAT.Limestone, NEVER)
	box(gate, "GateWalk", -13, 13, GATE_TOP - 1, GATE_TOP, -71.5, -65.5, STONE_DARK, MAT.Cobblestone, NEVER)
	-- A pier under the walk against the east tower: the arch is one opening 21 wide, off the lane's
	-- middle, and the line down its east side stops here.
	box(gate, "GatePier", 8, 13, -1, GATE_TOP - 1, -71, -66, STONE, MAT.Limestone, NEVER)
	doorway("GateArch", -13, 8, -71.5, -65.5, 0, GATE_TOP - 1)
	-- The arch's dark band and keystone (dressing: nothing under the walk to walk into).
	facePlate(gate, "ArchBand", "z", -71.5, 0.12, -12.6, 12.6, GATE_TOP - 0.9, GATE_TOP - 0.5, BASALT, MAT.Basalt)
	facePlate(gate, "ArchBand", "z", -65.5, 0.12, -12.6, 12.6, GATE_TOP - 0.9, GATE_TOP - 0.5, BASALT, MAT.Basalt)
	box(gate, "Keystone", -1, 1, GATE_TOP - 1.9, GATE_TOP - 0.3, -71.75, -65.25, BASALT_LIGHT, MAT.Basalt, TRIM)
	-- Merlons on the side that faces the fight.
	merlons(gate, "x", -65.9, -12.4, 12.4, 0.8, GATE_TOP, 1.8)
	merlons(gate, "x", -65.5, -19.8, -13.2, 1, GATE_TOP, 1.8)
	merlons(gate, "x", -65.5, 13.2, 19.8, 1, GATE_TOP, 1.8)
	-- A stair up the outside of each tower, from the team's own side.
	flightZ(gate, "GateStair", -26, -20, -80.6, -68, 0, GATE_TOP, 10, STONE_DARK, MAT.Cobblestone, -0.5)
	flightZ(gate, "GateStair", 20, 26, -80.6, -68, 0, GATE_TOP, 10, STONE_DARK, MAT.Cobblestone, -0.5)
	-- The arena's purple on the towers' faces, and a lamp on each.
	for _, x in ipairs({ -16.5, 16.5 }) do
		box(gate, "Banner", x - 1.6, x + 1.6, 2.4, GATE_TOP - 0.7, -64.98, -64.86, PURPLE, MAT.Fabric, TRIM)
		disc(gate, "BannerEye", Vector3.new(x, 5.6, -64.8), Vector3.new(0, 0, 1), 0.06, 1.8, WHITE_PAINT, MAT.SmoothPlastic)
		disc(gate, "BannerPupil", Vector3.new(x, 5.5, -64.72), Vector3.new(0, 0, 1), 0.06, 0.8, ROT_GREEN, MAT.Neon)
		wallLamp(gate, Vector3.new(x + (x < 0 and 2.6 or -2.6), 6.6, -65), Vector3.new(0, 0, 1), 18)
	end
	rubble(gate, -10.5, -76.5, 1.4, 4, 0, { STONE, STONE_DARK })
	-- Seven studs clear of the pier: at two studs further north the gap between them was five, exactly
	-- a bot's width, and a bot that dropped into it off the walk could not path back out.
	crates(gate, 6.5, -79.5, 1, 1, 0)
	for _, x in ipairs({ -16.5, 16.5 }) do
		coverAt(x, -63.2, 0)
		coverAt(x, -73.8, 0)
	end
	for _, x in ipairs({ -9, 0, 9, -16.5, 16.5 }) do
		table.insert(B.cover, here(x, GATE_TOP, -67.2))
	end
	lootSpot("GateBack", -16.5, 0, -76, "weapon")
	return gate
end

--------------------------------------------------------------------------------
-- The entry: where the centre lane comes in off the town
--------------------------------------------------------------------------------

-- A burnt-out car: body, cabin, three wheels (the fourth is gone), soot for windows. One pool.
local function wreck(parent, x, z, yaw)
	local frame = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
	local opts = pool("Wreck")
	local function part(name, size, at, color, material, o)
		local p = put(parent, name, size, frame * at, color, material, o or opts)
		return p
	end
	part("WreckBody", Vector3.new(6.2, 1.9, 14.4), CFrame.new(0, 1.9, 0), mix(RUST, SOOT, 0.35), MAT.CorrodedMetal)
	part("WreckCabin", Vector3.new(5.6, 1.7, 6.6), CFrame.new(0, 3.7, 0.9) * CFrame.Angles(0.04, 0, 0.03), mix(RUST, SOOT, 0.55), MAT.CorrodedMetal)
	for _, wheel in ipairs({ { -1, -4.6 }, { 1, -4.6 }, { 1, 4.6 } }) do
		local wx = wheel[1] * 3.2
		rod(parent, "WreckWheel", frame * Vector3.new(wx - wheel[1] * 0.45, 1.05, wheel[2]),
			frame * Vector3.new(wx + wheel[1] * 0.45, 1.05, wheel[2]), 2.1, RUBBER, MAT.Plastic, opts)
	end
	-- The corner with no wheel has settled onto its sill.
	part("WreckSill", Vector3.new(0.8, 1.0, 1.8), CFrame.new(-2.9, 0.45, 4.6), mix(RUST, SOOT, 0.5), MAT.CorrodedMetal)
	part("WreckSoot", Vector3.new(5.0, 1.2, 0.12), CFrame.new(0, 3.8, -2.47), SOOT, MAT.Slate, trimWith({ tag = opts.tag }))
	-- Behind it on either long side.
	local nose, tail = frame * Vector3.new(0, 0, -6), frame * Vector3.new(0, 0, 6)
	coverLine(nose.X, nose.Z, tail.X, tail.Z, 0, 4.9)
end

-- Three steel beams through one point: an anti-tank hedgehog. One pool.
local function hedgehog(parent, x, z)
	local opts = pool("Prop")
	local c = Vector3.new(x, 1.35, z)
	for index = 0, 2 do
		local yaw = index * math.pi * 2 / 3 + 0.3
		local d = Vector3.new(math.cos(yaw) * 0.8, 0.6, math.sin(yaw) * 0.8).Unit * 2.4
		plateBetween(parent, "Hedgehog", c - d, c + d, 0.55, 0.55, STEEL_DARK, MAT.CorrodedMetal, opts)
	end
	coverBox(x - 1.8, x + 1.8, z - 1.8, z + 1.8, 0, 1.2)
end

local function buildEntry(root)
	local entry = folder(root, "Entry")
	local ground = folder(entry, "Paving", true)
	paving(ground, -7, 7, -120, -86, 2, 2, { PAVING, CONCRETE, CONCRETE_DARK }, MAT.Concrete, { ["1,2"] = true })
	wreck(entry, -21, -97, 0.45)
	hedgehog(entry, 12, -112)
	teeth(entry, 3.2, -116, 2)
	teeth(entry, -6.4, -104, 2)
	teeth(entry, 3.2, -94, 2)
	crates(entry, 12.5, -84, 2, 0, 0)
	sandbags(entry, -9, -86, -2.6, -86, 3, 0)
	-- The arena's sign, knocked askew: "ROT ARENA - KEEP OFF THE GOO".
	-- One Model, tagged, so it comes down whole.
	local signs = folder(entry, "ArenaSign")
	signs:SetAttribute("Destructible", "Sign")
	local tilt = CFrame.Angles(0, 0, 0.05)
	for _, x in ipairs({ -17.4, -8.4 }) do
		put(signs, "SignPost", Vector3.new(7.8, 0.45, 0.45), CFrame.new(x, 3.4, -113.6) * tilt * CFrame.Angles(0, 0, math.pi / 2),
			STEEL_DARK, MAT.Metal, { shape = Enum.PartType.Cylinder })
	end
	local board = put(signs, "SignBoard", Vector3.new(10.4, 2.6, 0.25), CFrame.new(-12.9, 5.4, -113.85) * tilt, PURPLE_DARK, MAT.Metal)
	signText(board, "ROT ARENA · KEEP OFF THE GOO", WHITE_PAINT)
	lootSpot("Entry", -3.5, TILE, -94, "weapon")
	return entry
end

--------------------------------------------------------------------------------
-- The pit (objective B): a plaza walled in by a rim above eye height, centred on (PX, 0)
--------------------------------------------------------------------------------

-- A frame at (x, y, z) facing (tx, tz) (LookVector along it), for the busts.
local function facing(x, y, z, tx, tz)
	local dx, dz = tx - x, tz - z
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.atan2(-dx, -dz), 0)
end

-- A stone bust on a plinth in a corner of the pit, looking at the fountain. Kind 1 is the Brr bust
-- (a round head in a tall hat), kind 2 the Croc bust (a flat head and a long snout), both with the
-- rot glowing in their eyes.
local function bust(pit, x, z, kind)
	box(pit, "Plinth", x - 1.5, x + 1.5, -0.2, 2.9, z - 1.5, z + 1.5, LIME_DARK, MAT.Marble, NEVER)
	local frame = facing(x, 2.9, z, PX, 0)
	if kind == 1 then
		local head = frame * Vector3.new(0, 1.25, 0)
		ball(pit, "BustHead", head, 2.6, STONE_LIGHT, MAT.Marble, NEVER)
		rod(pit, "BustHat", head + Vector3.new(0, 0.9, 0), head + Vector3.new(0, 2.9, 0), 1.7, BASALT, MAT.Slate, NEVER)
		rod(pit, "BustBrim", head + Vector3.new(0, 1.0, 0), head + Vector3.new(0, 1.25, 0), 2.8, BASALT, MAT.Slate, NEVER)
		for _, s in ipairs({ -1, 1 }) do
			local eye = frame * Vector3.new(0.48 * s, 1.5, -1.15)
			disc(pit, "BustEye", eye, (eye - head).Unit, 0.08, 0.55, ROT_GREEN, MAT.Neon)
		end
	else
		put(pit, "BustHead", Vector3.new(2, 1.7, 2), frame * CFrame.new(0, 0.85, 0), STONE_LIGHT, MAT.Marble, NEVER)
		put(pit, "BustSnout", Vector3.new(1.1, 0.8, 2.4), frame * CFrame.new(0, 0.5, -1.9), STONE_LIGHT, MAT.Marble, NEVER)
		for _, s in ipairs({ -1, 1 }) do
			ball(pit, "BustEye", (frame * CFrame.new(0.55 * s, 1.75, -0.5)).Position, 0.55, ROT_GREEN, MAT.Neon, TRIM)
			put(pit, "BustTooth", Vector3.new(0.18, 0.3, 0.18), frame * CFrame.new(0.4 * s, 0.05, -2.6), WHITE_PAINT, MAT.SmoothPlastic, TRIM)
		end
	end
	-- The busts stand in the corners: the room to crouch is on the two sides toward the pit.
	local inX = x < PX and 1 or -1
	coverAt(x + inX * 3.3, z, TILE)
	coverAt(x, z + 3.3, TILE)
end

local function buildPit(root)
	local pit = folder(root, "Pit", true)
	-- The floor, pale flags round the fountain, and the cut's floor.
	paving(pit, -102, -66, -18, 0, 4, 1, { LIME, LIME_DARK, mix(LIME, STONE, 0.4) }, MAT.Marble)
	paving(pit, -76, -66, -26, -18, 1, 1, { LIME_DARK }, MAT.Marble)
	-- The rim: along the south (the cut ends it at -76) and down the west side.
	box(pit, "PitRim", -110, -76, -1, RIM, -26, -18, LIME_DARK, MAT.Limestone, NEVER)
	box(pit, "PitRim", -110, -102, -1, RIM, -18, 0, LIME_DARK, MAT.Limestone, NEVER)
	facePlate(pit, "RimCoping", "z", -18, 0.12, -101.8, -76.2, RIM - 0.55, RIM - 0.15, LIME, MAT.Marble)
	facePlate(pit, "RimCoping", "x", -102, 0.12, -17.8, -0.2, RIM - 0.55, RIM - 0.15, LIME, MAT.Marble)
	doorway("PitCut", -76, -66, -26, -18, TILE, 40)
	-- The berm on the keep's side: seven steps up each face to a ridge 2.4 wide, in slabs that each start
	-- where the one below stops (so no two share a face), cut at the mirror to walk straight through.
	local bottom = -0.5
	for k = 1, 7 do
		local top = TILE + RISE * k
		box(pit, "BermStep", -66 + 1.3 * (k - 1), -48 - 1.3 * (k - 1), bottom, top, -26, -4, k % 2 == 0 and LIME or LIME_DARK,
			MAT.Limestone, NEVER)
		bottom = top
	end
	doorway("BermCut", -66, -48, -4, 0, 0, 40)
	-- The rim's parapets: chest-high on the pit's edge (the rim's cover), knee-high on the outer edge.
	for _, run in ipairs({ { -108.6, -103.4 }, { -99.2, -92 }, { -88.6, -80.4 } }) do
		box(pit, "RimParapet", run[1], run[2], RIM, RIM + 2.4, -18.8, -18, LIME, MAT.Limestone, NEVER)
		table.insert(B.cover, here((run[1] + run[2]) / 2, RIM, -20.4))
	end
	for _, run in ipairs({ { -16.2, -10.9 }, { -6.4, -1.2 } }) do
		box(pit, "RimParapet", -102.8, -102, RIM, RIM + 2.4, run[1], run[2], LIME, MAT.Limestone, NEVER)
		table.insert(B.cover, here(-104.4, RIM, (run[1] + run[2]) / 2))
	end
	for _, run in ipairs({ { -108.6, -94 }, { -84, -77.6 } }) do
		box(pit, "RimParapet", run[1], run[2], RIM, RIM + 1.2, -26, -25.2, LIME, MAT.Limestone, NEVER)
	end
	-- Two ways up from outside: a stair up the south face, one up the west.
	flightZ(pit, "RimStair", -92, -86, -35.1, -26, 0, RIM, 8, LIME_DARK, MAT.Limestone, -0.5)
	flightX(pit, "RimStair", -10.2, -5, -119.1, -110, 0, RIM, 8, LIME_DARK, MAT.Limestone, -0.5)
	-- A colonnade on the west rim: two whole columns under a length of architrave, one snapped.
	local colTop = RIM + 0.4 + 8
	for index, z in ipairs({ -16, -12.4, -2.8 }) do
		local x = -108.8
		box(pit, "ColumnBase", x - 1.2, x + 1.2, RIM, RIM + 0.4, z - 1.2, z + 1.2, LIME, MAT.Marble, NEVER)
		local top = index < 3 and colTop or RIM + 0.4 + rnd(3.2, 4.6)
		rod(pit, "Column", Vector3.new(x, RIM + 0.4, z), Vector3.new(x, top, z), 1.8, LIME, MAT.Marble, NEVER)
		if index < 3 then
			box(pit, "Capital", x - 1.1, x + 1.1, top, top + 0.5, z - 1.1, z + 1.1, LIME_DARK, MAT.Marble, NEVER)
		else
			rebar(pit, Vector3.new(x + 0.3, top, z), 1.2, 0.3, 1.1)
			rod(pit, "ColumnDrum", Vector3.new(-106.2, RIM + 0.9, 1.4 - 8.4), Vector3.new(-106.2, RIM + 0.9, 1.4 - 6.2), 1.8, LIME, MAT.Marble, NEVER)
		end
	end
	box(pit, "Architrave", -109.9, -107.7, colTop + 0.5, colTop + 1.5, -17.2, -11.2, LIME, MAT.Marble, NEVER)

	-- The cut's gate: posts on the rim and the berm, a lintel, the pit's name hanging from it.
	box(pit, "GatePost", -77.6, -76.2, RIM, RIM + 6.4, -22.7, -21.3, LIME, MAT.Limestone, NEVER)
	box(pit, "GatePost", -65.8, -64.4, -0.6, RIM + 6.4, -22.7, -21.3, LIME, MAT.Limestone, NEVER)
	box(pit, "GateLintel", -77.6, -64.4, RIM + 6.4, RIM + 7.6, -22.8, -21.2, BASALT, MAT.Basalt, NEVER)
	for _, x in ipairs({ -73.8, -68.2 }) do
		rod(pit, "SignChain", Vector3.new(x, RIM + 6.45, -22), Vector3.new(x, 12.05, -22), 0.12, STEEL_DARK, MAT.Metal, TRIM)
	end
	local sign = box(pit, "PitSign", -74.5, -67.5, 10.4, 12.1, -22.1, -21.9, PURPLE_DARK, MAT.Wood, TRIM)
	signText(sign, "THE GOO PIT", ROT_GREEN)
	wallLamp(pit, Vector3.new(-76.2, RIM + 4.4, -22), Vector3.new(1, 0, 0), 26)

	-- On the floor: the busts in the corners, a column's fallen drums, crates, goo.
	bust(pit, PX - 15, -15, 1)
	bust(pit, PX + 15, -15, 2)
	rod(pit, "ColumnDrum", Vector3.new(-94.5, TILE + 1.1, -6), Vector3.new(-91, TILE + 1.1, -6), 2.2, LIME, MAT.Marble, NEVER)
	rod(pit, "ColumnDrum", Vector3.new(-91, TILE - 0.1, -9.4), Vector3.new(-91, TILE + 1.6, -9.4), 2.2, LIME_DARK, MAT.Marble, NEVER)
	coverBox(-94.5, -91, -7.1, -4.9, TILE)
	crates(pit, -74.5, -2.4, 2, 1, TILE, 2.4)
	groundDisc(pit, "RotGoo", -88.5, -12.5, 2.6, ROT_GREEN, MAT.Neon, 1)
	-- The fountain's goo spouts on this half's side (the fountain itself is on the mirror).
	for _, angle in ipairs({ -math.pi / 4, -3 * math.pi / 4 }) do
		local c, s = math.cos(angle), math.sin(angle)
		rod(pit, "GooSpout", Vector3.new(PX + 1.9 * c, 4.1, 1.9 * s), Vector3.new(PX + 3.9 * c, 1.3, 3.9 * s), 0.34, ROT_GREEN, MAT.Neon,
			trimWith({ transparency = 0.15 }))
	end

	lootSpot("PitFloor", -86.5, TILE, -9.8, "weapon", "Epic")
	lootSpot("PitRim", -105, RIM, -10, "weapon", "Rare")
	lootSpot("BermRidge", -57, RIM, -15, "weapon", "Epic")
	return pit
end

--------------------------------------------------------------------------------
-- The market: the infantry flank between the keep and the vehicle cut
--------------------------------------------------------------------------------

-- A market stall 7 x 4 at (cx, cz): corner posts, a counter along its front (-Z), a solid board across
-- its back (the stalls are what break the lines down the market), a striped canopy and a few rot
-- melons. One tagged Model, so it comes down whole.
local function stall(parent, cx, cz, backedOnto)
	local model = folder(parent, "MarketStall")
	model:SetAttribute("Destructible", "Shelter")
	local x0, x1, z0, z1 = cx - 3.5, cx + 3.5, cz - 2, cz + 2
	for _, px in ipairs({ x0 + 0.2, x1 - 0.2 }) do
		for _, pz in ipairs({ z0 + 0.2, z1 - 0.2 }) do
			box(model, "StallPost", px - 0.2, px + 0.2, TILE, 6.6, pz - 0.2, pz + 0.2, WOOD_DARK, MAT.Wood)
		end
	end
	box(model, "StallCounter", x0 + 0.4, x1 - 0.4, TILE, 3.2, z0 + 0.4, z0 + 1.5, WOOD, MAT.WoodPlanks)
	box(model, "StallBack", x0 + 0.4, x1 - 0.4, TILE, 6.6, z1 - 0.35, z1 - 0.05, WOOD_DARK, MAT.WoodPlanks)
	-- The canopy overhangs the posts, so no strip's edge lies in a post's face.
	local strips = 3
	local w = (x1 - x0 + 0.6) / strips
	for index = 1, strips do
		local x = x0 - 0.3 + (index - 0.5) * w
		plateBetween(model, "StallCanopy", Vector3.new(x, 6.66, z1 - 0.2), Vector3.new(x, 5.9, z0 - 0.5), w, 0.12,
			index % 2 == 0 and WHITE_PAINT or PURPLE, MAT.Fabric, TRIM)
	end
	for index = 1, 2 do
		ball(model, "RotMelon", Vector3.new(x0 + 1.4 + index * 1.9, 3.75, z0 + 0.95), 1.1, MELON, MAT.SmoothPlastic, TRIM)
	end
	coverAt(cx, z0 - 1.2, TILE)
	if not backedOnto then
		coverAt(cx - 1.8, z1 + 1.4, TILE)
		coverAt(cx + 1.8, z1 + 1.4, TILE)
	end
	return model
end

local function buildMarket(root)
	local market = folder(root, "Market")
	local ground = folder(market, "Paving", true)
	paving(ground, 37, 62, -50, -10, 3, 3, { PAVING, CONCRETE, mix(PAVING, BRICK, 0.2) }, MAT.Cobblestone)
	groundDisc(ground, "BlastMark", 49.5, -30, 5.2, mix(SOOT, CONCRETE_DARK, 0.4), MAT.Slate, 1)

	stall(market, 52, -22)
	stall(market, 43.5, -44)
	stall(market, 57, -40.5, true)

	-- A corner shop, gutted: a brick front with its window blown out and one side wall.
	local shop = folder(market, "ShopRuin")
	local brick = { name = "Wall", health = 160, color = BRICK, material = MAT.Brick, brick = false }
	panel(shop, 38, -56, 43, -56, 1.2, 8.4, brick)
	box(shop, "Wall", 43, 46, -1, 3.0, -56.6, -55.4, BRICK_DARK, MAT.Brick, { health = 160 })
	box(shop, "Wall", 43, 46, 6.0, 8.4, -56.6, -55.4, BRICK, MAT.Brick, { health = 160 })
	panel(shop, 46, -56, 50.5, -56, 1.2, 7.0, brick)
	panel(shop, 38, -56, 38, -49.5, 1.2, 6.4, { name = "Wall", health = 160, color = BRICK, material = MAT.Brick, brick = false, bottom = -1.1 })
	box(shop, "WindowSill", 42.9, 46.1, 3.0, 3.25, -56.75, -55.25, STONE_LIGHT, MAT.Limestone, TRIM)
	local shopSign = box(shop, "ShopSign", 39.2, 49.6, 6.6, 7.9, -55.28, -55.14, mix(HAZARD, WOOD, 0.4), MAT.Wood, TRIM)
	signText(shopSign, "BRAINROT BARGAINS", SOOT)
	rubble(shop, 44.6, -52.4, 1.4, 3, TILE, { BRICK, BRICK_DARK, CONCRETE_DARK })
	coverLine(38, -56, 50.5, -56, 0, 2.2)

	-- A tower of crates by the way in from the keep, cover on the way up from the south, and the
	-- Rot-Cola machine.
	crates(market, 39.5, -14.5, 1, 1, TILE)
	crates(market, 51, -100, 1, 1, 0)
	sandbags(market, 53.5, -84, 59, -84, 3, 0)
	-- The market's gate: two brick piers and a lintel with the market's name, the way in between them
	-- 6 wide; the piers close the lines down the market's east side.
	local gate = folder(market, "MarketGate", true)
	box(gate, "GatePier", 40, 44, -0.5, 8.2, -90, -86, BRICK, MAT.Brick, NEVER)
	box(gate, "GatePier", 50, 56, -0.5, 8.2, -90, -86, BRICK, MAT.Brick, NEVER)
	box(gate, "GateLintel", 39.6, 56.4, 8.2, 9.3, -89.4, -86.6, BRICK_DARK, MAT.Brick, NEVER)
	local banner = facePlate(gate, "MarketSign", "z", -86.6, 0.1, 44.4, 49.6, 8.35, 9.15, PURPLE, MAT.SmoothPlastic)
	signText(banner, "ROT MARKET", WHITE_PAINT)
	doorway("MarketGate", 44, 50, -90, -86, 0, 8.2)
	coverAt(47, -92, 0)
	coverAt(58, -88, 0)
	teeth(market, 53.5, -73, 2, 0, 3.2)
	local machine = pool("Prop")
	box(market, "RotColaMachine", 54.8, 57.2, TILE, 7.2, -15.4, -12.6, MAROON, MAT.Metal, machine)
	local front = box(market, "RotColaFront", 55.2, 56.8, 2.4, 6.6, -15.52, -15.28, ROT_GREEN, MAT.Neon, trimWith({ tag = machine.tag }))
	signText(front, "ROT-COLA", SOOT)
	light(front, ROT_GREEN, 12, 0.8)
	coverBox(54.8, 57.2, -15.4, -12.6, TILE)

	-- THE SAHUR DRUM: the colossus's drum, rolled here when he fell, standing on its end between the
	-- keep's ramp and the market; a wall of wood and hide across the lines down this side.
	local drum = folder(market, "SahurDrum", true)
	local dc = Vector3.new(32, 0, -40)
	rod(drum, "DrumShell", dc + Vector3.new(0, -0.3, 0), dc + Vector3.new(0, 6.2, 0), 10, mix(WOOD, BRICK, 0.35), MAT.Wood, NEVER)
	rod(drum, "DrumHide", dc + Vector3.new(0, 6.2, 0), dc + Vector3.new(0, 6.45, 0), 9.4, CANVAS, MAT.Fabric, NEVER)
	for _, y in ipairs({ 0.8, 5.4 }) do
		rod(drum, "DrumHoop", dc + Vector3.new(0, y - 0.3, 0), dc + Vector3.new(0, y + 0.3, 0), 10.5, BRONZE, MAT.Metal, TRIM)
	end
	for index = 0, 5 do
		local angle = index * math.pi / 3 + 0.26
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 5.05
		plateBetween(drum, "DrumCord", dc + out + Vector3.new(0, 1.1, 0), dc + out * 0.99 + Vector3.new(math.sin(angle) * 1.2, 5.1, -math.cos(angle) * 1.2),
			0.18, 0.12, CANVAS, MAT.Fabric, TRIM)
	end
	coverAt(dc.X + 6.9, dc.Z, 0)
	coverAt(dc.X, dc.Z + 6.9, 0)
	coverAt(dc.X, dc.Z - 6.9, 0)

	lootSpot("Market", 49.5, TILE, -30, "weapon", "Rare")
	lootSpot("MarketBack", 47.5, TILE, -50.5, "heal")
	return market
end

--------------------------------------------------------------------------------
-- The approach to the pit: the derailed Rot-Tram, its stop, the old chapel, the obelisk
--------------------------------------------------------------------------------

-- A tram car from x0 to x1 across z0..z1, off its rails: bogies, a maroon body under a cream band of
-- dark windows, a roof. It never breaks (it is what the lines down this side stop against).
local function tramCar(parent, x0, x1, z0, z1, name, withPole)
	local car = folder(parent, name, true)
	box(car, "TramBogie", x0 + 2, x0 + 5, -0.3, 1.2, z0 + 0.6, z1 - 0.6, STEEL_DARK, MAT.Metal, NEVER)
	box(car, "TramBogie", x1 - 5, x1 - 2, -0.3, 1.2, z0 + 0.6, z1 - 0.6, STEEL_DARK, MAT.Metal, NEVER)
	box(car, "TramBody", x0, x1, 1.2, 3.9, z0, z1, MAROON, MAT.Metal, NEVER)
	box(car, "TramBody", x0, x1, 3.9, 6.2, z0, z1, mix(WHITE_PAINT, STONE, 0.4), MAT.Metal, NEVER)
	box(car, "TramRoof", x0 + 0.2, x1 - 0.2, 6.2, 6.7, z0 + 0.3, z1 - 0.3, STEEL_DARK, MAT.Metal, NEVER)
	for _, face in ipairs({ z0, z1 }) do
		facePlate(car, "TramWindows", "z", face, 0.1, x0 + 1.2, x1 - 1.2, 4.3, 5.8, mix(SOOT, NAVY, 0.3), MAT.Glass)
	end
	local sign = box(car, "TramSign", x1 - 0.1, x1 + 0.1, 5.0, 5.9, z0 + 1, z1 - 1, SOOT, MAT.SmoothPlastic, TRIM)
	signText(sign, "ROT LINE · NOT IN SERVICE", ROT_GREEN)
	if withPole then
		local mid = (x0 + x1) / 2
		local zc = (z0 + z1) / 2
		rod(car, "TramPole", Vector3.new(mid - 1, 6.6, zc), Vector3.new(mid + 2.6, 9.4, zc), 0.2, STEEL_DARK, MAT.Metal, TRIM)
		rod(car, "TramPole", Vector3.new(mid + 1, 6.6, zc), Vector3.new(mid + 2.6, 9.4, zc), 0.2, STEEL_DARK, MAT.Metal, TRIM)
		rod(car, "TramShoe", Vector3.new(mid + 2.6, 9.4, zc - 1.2), Vector3.new(mid + 2.6, 9.4, zc + 1.2), 0.3, STEEL, MAT.Metal, TRIM)
	end
	return car
end

local function buildApproach(root)
	local approach = folder(root, "PitApproach")
	-- The Rot-Tram, jackknifed across the way to the pit's cut: the lines down this side stop at it.
	tramCar(approach, -84, -62, -41, -36, "RotTramA", true)
	tramCar(approach, -62.5, -50.6, -36, -31, "RotTramB", false)
	coverAt(-73, -43, 0)
	coverAt(-73, -34, 0)
	coverAt(-56, -29, 0)
	coverAt(-56, -38, 0)

	teeth(approach, -60.5, -96, 2)
	teeth(approach, -53, -82, 2)

	-- Its stop: a shelter with a solid back, a bench, and the timetable.
	local stop = folder(approach, "TramStop")
	stop:SetAttribute("Destructible", "Shelter")
	box(stop, "StopBack", -52, -42, 0, 6.4, -62.2, -61.6, mix(STEEL, NAVY, 0.3), MAT.Metal)
	box(stop, "StopRoof", -52.4, -41.6, 6.4, 6.8, -62.2, -58.8, STEEL_DARK, MAT.Metal)
	for _, x in ipairs({ -51.7, -42.3 }) do
		box(stop, "StopPost", x - 0.2, x + 0.2, 0, 6.4, -59.5, -59.1, STEEL_DARK, MAT.Metal)
	end
	box(stop, "StopBench", -49, -45, 1.4, 1.7, -61.6, -60.4, WOOD, MAT.WoodPlanks)
	local board = box(stop, "StopTimetable", -44.6, -42.6, 2.4, 5.4, -61.6, -61.45, WHITE_PAINT, MAT.SmoothPlastic, TRIM)
	signText(board, "NEXT TRAM: NEVER", SOOT)
	coverAt(-47, -58, 0)
	coverAt(-47, -63.8, 0)

	-- The old chapel: brick walls standing to 7-9, the roof long gone, pews and a shrine to the rot eye.
	-- The way between it and the tram is 5 wide (a bot's width).
	local chapel = folder(approach, "Chapel")
	local function brick(top, bottom)
		return { name = "Wall", health = 180, color = BRICK, material = MAT.Brick, brick = false, bottom = bottom }
	end
	panel(chapel, -45, -36, -38, -36, 1.2, rnd(7.2, 8.2), brick(nil, -1))
	panel(chapel, -38, -36, -31, -36, 1.2, rnd(7.2, 8.2), brick(nil, -1))
	-- The walls either side of a door stand above its lintel, which rests on them.
	panel(chapel, -45, -48, -41, -48, 1.2, rnd(8.5, 8.8), brick(nil, -1))
	panel(chapel, -35, -48, -31, -48, 1.2, rnd(8.5, 8.8), brick(nil, -1))
	box(chapel, "Wall", -41, -35, 7.4, 8.4, -48.6, -47.4, BRICK_DARK, MAT.Brick, { health = 180 })
	panel(chapel, -45, -48, -45, -36, 1.2, rnd(6.8, 7.8), brick(nil, -1.1))
	panel(chapel, -31, -48, -31, -45, 1.2, rnd(8.95, 9.3), brick(nil, -1.1))
	panel(chapel, -31, -39, -31, -36, 1.2, rnd(8.95, 9.3), brick(nil, -1.1))
	box(chapel, "Wall", -31.6, -30.4, 7.4, 8.4, -45, -39, BRICK_DARK, MAT.Brick, { health = 180 })
	doorway("ChapelSouth", -41, -35, -48.6, -47.4, TILE, 7.4)
	doorway("ChapelEast", -31.6, -30.4, -45, -39, TILE, 7.4)
	local floor = folder(chapel, "Paving", true)
	paving(floor, -44.4, -31.6, -47.4, -36.6, 2, 2, { LIME_DARK, STONE_DARK }, MAT.Slate)
	-- The shrine at the north wall, the rot eye in its face.
	box(chapel, "Shrine", -39.8, -36.2, TILE, 3.4, -38.9, -36.6, LIME, MAT.Marble, NEVER)
	disc(chapel, "ShrineEye", Vector3.new(-38, 2.2, -38.96), Vector3.new(0, 0, -1), 0.06, 1.9, WHITE_PAINT, MAT.SmoothPlastic)
	disc(chapel, "ShrinePupil", Vector3.new(-38, 2.2, -39.04), Vector3.new(0, 0, -1), 0.06, 0.8, ROT_GREEN, MAT.Neon)
	-- Two pews, knee-high cover.
	local pews = pool("Prop")
	for _, z in ipairs({ -42.2, -45 }) do
		box(chapel, "Pew", -43.6, -39.2, TILE, TILE + 1.6, z - 0.5, z + 0.5, WOOD_DARK, MAT.WoodPlanks, pews)
	end
	coverAt(-42, -39.2, TILE)
	coverAt(-33, -46, TILE)
	coverAt(-47.6, -42, 0)
	coverAt(-38, -34.2, 0)

	-- The rot monolith at the foot of the berm, between it and the chapel: the lines past the chapel's
	-- west end stop at it.
	local monolith = folder(approach, "Monolith", true)
	box(monolith, "MonolithBase", -51, -45.2, -0.3, 1.6, -16.9, -11.1, STONE_DARK, MAT.Limestone, NEVER)
	box(monolith, "Monolith", -50.4, -45.8, 1.6, 9.8, -16.3, -11.7, STONE, MAT.Limestone, NEVER)
	put(monolith, "MonolithCap", Vector3.new(3.2, 3.2, 3.2), CFrame.new(-48.1, 10.3, -14) * CFrame.Angles(0.62, 0.785, 0), STONE_LIGHT,
		MAT.Limestone, NEVER)
	disc(monolith, "MonolithEye", Vector3.new(-48.1, 7.6, -11.7), Vector3.new(0, 0, 1), 0.08, 2.0, WHITE_PAINT, MAT.SmoothPlastic)
	disc(monolith, "MonolithPupil", Vector3.new(-48.1, 7.6, -11.54), Vector3.new(0, 0, 1), 0.08, 0.9, ROT_GREEN, MAT.Neon)
	coverAt(-48.1, -18.9, 0)
	coverAt(-43.2, -14, 0)
	lootSpot("Chapel", -36.5, TILE, -43.4, "weapon")
	return approach
end

--------------------------------------------------------------------------------
-- The scrapyard cut: the vehicle route on the right, doglegged round the containers
--------------------------------------------------------------------------------

-- The route's centre line through this half, from outside the disc to the mirror. A car is 8.9 wide
-- and 16.6 long; the way is kept 16 wide (8 either side of this line) with room to swing through the
-- bends. Each straight is under 40 long and every bend has a container on its outside, so neither a
-- car nor a rifle gets a long straight run down it.
local LANE = {
	Vector3.new(70, 0, -114), Vector3.new(70, 0, -80), Vector3.new(88, 0, -56),
	Vector3.new(88, 0, -28), Vector3.new(67, 0, -10), Vector3.new(67, 0, 0),
}
TeamBattleground.LaneHalfWidth = 8
TeamBattleground.LaneClearance = 8

-- A shipping container, 7 high: ribbed sides, doors at one end, one tough pool (every piece carries
-- its tag, so the ribs and doors go with the box).
local function container(parent, x0, x1, z0, z1, color, doorsAtLow, sealedEnd)
	local opts = pool("Container")
	opts.health = 900
	box(parent, "Container", x0, x1, 0, 7, z0, z1, color, MAT.Metal, opts)
	local dressing = trimWith({ tag = opts.tag })
	local alongX = (x1 - x0) >= (z1 - z0)
	local u0, u1 = alongX and x0 or z0, alongX and x1 or z1
	local c0, c1 = alongX and z0 or x0, alongX and z1 or x1
	local ribs = math.floor((u1 - u0) / 4.5)
	for index = 1, ribs - 1 do
		local u = u0 + (u1 - u0) * index / ribs
		for _, face in ipairs({ c0, c1 }) do
			facePlate(parent, "ContainerRib", alongX and "z" or "x", face, 0.12, u - 0.22, u + 0.22, 0.25, 6.75, mix(color, SOOT, 0.25),
				MAT.Metal, dressing)
		end
	end
	local door = doorsAtLow and u0 or u1
	local mid = (c0 + c1) / 2
	for _, side in ipairs({ -1, 1 }) do
		local a, b = mid + side * 0.05, mid + side * ((c1 - c0) / 2 - 0.15)
		facePlate(parent, "ContainerDoor", alongX and "x" or "z", door, 0.1, math.min(a, b), math.max(a, b), 0.3, 6.7,
			mix(color, WHITE_PAINT, 0.08), MAT.Metal, dressing)
		local bar = mid + side * (c1 - c0) / 4
		local out = (doorsAtLow and -1 or 1) * 0.18
		local p0 = alongX and Vector3.new(door + out, 0.6, bar) or Vector3.new(bar, 0.6, door + out)
		rod(parent, "ContainerBar", p0, p0 + Vector3.new(0, 5.8, 0), 0.16, STEEL_DARK, MAT.Metal, dressing)
	end
	-- Along both long sides, and at each end that is not up against something.
	if alongX then
		coverLine(x0 + 3, (z0 + z1) / 2, x1 - 3, (z0 + z1) / 2, 0, (z1 - z0) / 2 + 1.8)
		if sealedEnd ~= "low" then coverAt(x0 - 1.8, (z0 + z1) / 2, 0) end
		if sealedEnd ~= "high" then coverAt(x1 + 1.8, (z0 + z1) / 2, 0) end
	else
		coverLine((x0 + x1) / 2, z0 + 3, (x0 + x1) / 2, z1 - 3, 0, (x1 - x0) / 2 + 1.8)
	end
end

-- A jersey barrier `length` long along Z at x, from z0. One pool each.
local function barrier(parent, x, z0, length)
	local opts = pool("Prop")
	box(parent, "Barrier", x - 0.8, x + 0.8, -0.2, 1.0, z0, z0 + length, CONCRETE, MAT.Concrete, opts)
	box(parent, "Barrier", x - 0.45, x + 0.45, 1.0, 2.9, z0 + 0.1, z0 + length - 0.1, CONCRETE, MAT.Concrete, opts)
	facePlate(parent, "BarrierPaint", "x", x - 0.45, 0.08, z0 + 0.8, z0 + length - 0.8, 2.0, 2.5, HAZARD, MAT.SmoothPlastic,
		trimWith({ tag = opts.tag }))
	coverLine(x, z0, x, z0 + length, 0, 1.6)
end

local function tyres(parent, x, z, count)
	local opts = pool("Prop")
	for index = 1, count do
		local y = (index - 1) * 0.9
		rod(parent, "Tyre", Vector3.new(x, y, z), Vector3.new(x, y + 0.9, z), 2.4, RUBBER, MAT.Plastic, opts)
	end
	disc(parent, "TyreHole", Vector3.new(x, count * 0.9, z), Vector3.new(0, 1, 0), 0.06, 1.2, SOOT, MAT.Slate, trimWith({ tag = opts.tag }))
end

local function drums(parent, spots)
	local opts = pool("Prop")
	for index, at in ipairs(spots) do
		local color = index % 2 == 0 and mix(RUST, NAVY, 0.4) or mix(RUST, MAROON, 0.5)
		rod(parent, "Drum", Vector3.new(at[1], 0, at[2]), Vector3.new(at[1], 2.8, at[2]), 1.8, color, MAT.CorrodedMetal, opts)
	end
end

-- A derelict crane beside the cut, its jib out over the road (well above anything that drives).
local function crane(parent)
	local model = folder(parent, "Crane", true)
	box(model, "CraneBase", 88, 96, -0.5, 2.6, -86, -78, CONCRETE_DARK, MAT.Concrete, NEVER)
	local legs = { { 89.2, -84.8 }, { 94.8, -84.8 }, { 94.8, -79.2 }, { 89.2, -79.2 } }
	for _, c in ipairs(legs) do
		rod(model, "CraneLeg", Vector3.new(c[1], 2.4, c[2]), Vector3.new(c[1], 18.3, c[2]), 0.7, HAZARD, MAT.Metal, NEVER)
	end
	for index = 1, 4 do
		local a, b = legs[index], legs[index % 4 + 1]
		for level = 0, 0 do
			local y0, y1 = 3.2 + level * 5, 3.2 + (level + 1) * 5
			-- Round bars: two flat ones meeting end to end in one face would share a plane at the joint.
			local flip = (index + level) % 2 == 0
			rod(model, "CraneBrace", Vector3.new(a[1], flip and y0 or y1, a[2]), Vector3.new(b[1], flip and y1 or y0, b[2]), 0.26,
				mix(HAZARD, RUST, 0.3), MAT.Metal, TRIM)
		end
	end
	box(model, "CraneCab", 88.4, 95.6, 18.2, 21.4, -85.6, -78.4, HAZARD, MAT.Metal, NEVER)
	facePlate(model, "CraneWindow", "z", -78.4, 0.1, 89.4, 94.6, 19.2, 20.8, SOOT, MAT.Glass)
	box(model, "CraneWeight", 93.5, 97.5, 21.4, 23.4, -84.5, -79.5, CONCRETE_DARK, MAT.Concrete, NEVER)
	local root, tip = Vector3.new(91, 22, -81.5), Vector3.new(72, 25.5, -63)
	plateBetween(model, "CraneJib", root, tip, 1.3, 1.3, HAZARD, MAT.Metal, NEVER)
	rod(model, "CraneCable", tip - Vector3.new(0, 0.6, 0), tip - Vector3.new(0, 11.4, 0), 0.14, STEEL_DARK, MAT.Metal, TRIM)
	box(model, "CraneHook", tip.X - 0.6, tip.X + 0.6, tip.Y - 12.6, tip.Y - 11.3, tip.Z - 0.4, tip.Z + 0.4, STEEL_DARK, MAT.Metal, TRIM)
	light(box(model, "CraneLamp", 91.4, 92.6, 17.6, 18.2, -78.3, -77.9, WARM, MAT.Neon, TRIM), WARM, 28, 1.2)
	coverAt(97.8, -82, 0)
	coverAt(92, -76.2, 0)
	coverAt(92, -87.8, 0)
	return model
end

local function buildLane(root)
	local lane = folder(root, "ScrapyardCut")
	-- The containers on the bends: every straight ends against one, and between them they close every
	-- line down this side (the cut's two straights never overlap across it).
	container(lane, 56, 80, -52, -45.5, MAROON, true)
	container(lane, 58, 77, -36, -29.5, mix(CONCRETE_DARK, NAVY, 0.35), false)
	container(lane, 77, 97.4, -8, -1.5, NAVY, true, "high")
	crane(lane)
	-- Along the edges: jersey barriers, a wreck, tyres, drums, a heap of scrap.
	barrier(lane, 59.4, -108, 5)
	barrier(lane, 59.4, -101.5, 5)
	barrier(lane, 59.4, -95, 5)
	wreck(lane, 84.5, -97, 0.15)
	-- The scrapyard's stack of crushed cars on the outside of the first bend, under the crane.
	local cubes = pool("Wreck")
	box(lane, "CarCube", 80.2, 84, -0.3, 3.6, -86.8, -81.8, mix(RUST, MAROON, 0.4), MAT.CorrodedMetal, cubes)
	box(lane, "CarCube", 84.2, 88, -0.3, 3.4, -86.6, -81.6, mix(RUST, NAVY, 0.4), MAT.CorrodedMetal, cubes)
	box(lane, "CarCube", 80.4, 84.1, 3.6, 7.1, -86.5, -82, mix(RUST, HAZARD, 0.25), MAT.CorrodedMetal, cubes)
	box(lane, "CarCube", 84.1, 88.3, 3.4, 6.9, -86.3, -81.9, mix(RUST, STEEL_DARK, 0.3), MAT.CorrodedMetal, cubes)
	coverAt(84, -79.6, 0)
	tyres(lane, 95, -66, 3)
	tyres(lane, 58, -76, 2)
	drums(lane, { { 62.6, -40.8 }, { 64.6, -41.4 }, { 63.3, -43.2 } })
	rubble(lane, 96.5, -58, 2.2, 5, 0, { RUST, STEEL_DARK, mix(RUST, SOOT, 0.4) })
	lootSpot("LaneWest", 56, 0, -100, "weapon")
	lootSpot("LaneEast", 99, 0, -44, "heal")
	return lane
end

--------------------------------------------------------------------------------
-- The gantry and the bridge: the right lane's high ground, joined to the keep's balcony
--------------------------------------------------------------------------------

local function buildGantry(root)
	local gantry = folder(root, "Gantry", true)
	box(gantry, "GantryDeck", 98, 110, GAL - 1, GAL, -8, 0, STEEL, MAT.DiamondPlate, NEVER)
	for _, leg in ipairs({ { 98, -8 }, { 108.8, -8 }, { 98, -1.2 }, { 108.8, -1.2 } }) do
		box(gantry, "GantryLeg", leg[1], leg[1] + 1.2, -0.5, GAL - 1, leg[2], math.min(leg[2] + 1.2, 0), STEEL_DARK, MAT.Metal, NEVER)
	end
	rod(gantry, "GantryBrace", Vector3.new(99.2, 0.6, -7.4), Vector3.new(108.8, GAL - 1.3, -7.4), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	rod(gantry, "GantryBrace", Vector3.new(108.8, 0.6, -7.4), Vector3.new(99.2, GAL - 1.3, -7.4), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	rod(gantry, "GantryBrace", Vector3.new(109.4, 0.6, -6.8), Vector3.new(109.4, GAL - 1.3, -1.2), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	-- The stair up from this side, and a hazard stripe where it arrives.
	flightZ(gantry, "GantryStair", 104, 110, -28.3, -8, 0, GAL, 13, CONCRETE_DARK, MAT.Concrete, -0.5)
	groundMark(gantry, "HazardStripe", 107, -7.55, 5.8, 0.7, 0, HAZARD, MAT.SmoothPlastic, 0, GAL)
	-- Rails round the edges, open where the stair and the bridge come in.
	box(gantry, "GantryRail", 98, 104, GAL, GAL + 1.1, -8, -7.7, STEEL_DARK, MAT.Metal, NEVER)
	box(gantry, "GantryRail", 109.7, 110, GAL, GAL + 1.1, -7.7, 0, STEEL_DARK, MAT.Metal, NEVER)
	box(gantry, "GantryRail", 98, 98.3, GAL, GAL + 1.1, -7.7, -4, STEEL_DARK, MAT.Metal, NEVER)
	sandbags(gantry, 99.4, -6.4, 103.6, -6.4, 2, GAL, true)
	-- Under the deck: the signal rig's generator, humming green, a block of cover between the legs.
	box(gantry, "Generator", 99.6, 103.8, -0.5, 5.8, -6.6, -1.2, OLIVE_DRAB, MAT.Metal, NEVER)
	facePlate(gantry, "GeneratorGrille", "x", 99.6, 0.1, -5.8, -2, 1.6, 4.6, STEEL_DARK, MAT.DiamondPlate)
	light(facePlate(gantry, "GeneratorWindow", "z", -6.6, 0.1, 100.4, 103, 3.4, 4.4, ROT_GREEN, MAT.Neon), ROT_GREEN, 10, 0.7)
	rod(gantry, "GeneratorExhaust", Vector3.new(102.8, 5.6, -2.2), Vector3.new(102.8, 8.2, -2.2), 0.6, RUST, MAT.CorrodedMetal, TRIM)
	coverAt(101.7, -8.6, 0)
	-- A searchlight on its stand, looking down the cut.
	box(gantry, "SearchlightStand", 107.6, 108.4, GAL, GAL + 1.2, -6.4, -5.6, STEEL_DARK, MAT.Metal, NEVER)
	rod(gantry, "Searchlight", Vector3.new(108, GAL + 1.8, -5.4), Vector3.new(108, GAL + 1.8, -7.0), 1.2, STEEL_DARK, MAT.Metal, NEVER)
	light(disc(gantry, "SearchlightGlass", Vector3.new(108, GAL + 1.8, -7.0), Vector3.new(0, 0, -1), 0.08, 1.0, WARM, MAT.Neon), WARM, 26, 1.2)
	-- A guy wire from the mast to each of this half's corners.
	for _, corner in ipairs({ { 99, -7.3 }, { 109.2, -7.3 } }) do
		rod(gantry, "GuyWire", Vector3.new(106, GAL + 14, 0), Vector3.new(corner[1], GAL + 0.1, corner[2]), 0.1, STEEL, MAT.Metal, TRIM)
	end
	table.insert(B.cover, here(101.5, GAL, -4.6))
	table.insert(B.cover, here(104, GAL, -5.2))
	lootSpot("GantryDeck", 103.2, GAL, -3.4, "weapon", "Rare")
	return gantry
end

local function buildBridge(root)
	local bridge = folder(root, "Bridge", true)
	box(bridge, "BridgeDeck", 30, 98, GAL - 1, GAL, -4, 0, STEEL, MAT.DiamondPlate, NEVER)
	for _, x in ipairs({ 46, 57 }) do
		box(bridge, "BridgePier", x - 1.2, x + 1.2, -1, GAL - 1.6, -1.5, 0, CONCRETE, MAT.Concrete, NEVER)
		box(bridge, "PierCap", x - 1.6, x + 1.6, GAL - 1.6, GAL - 1, -2.4, 0, CONCRETE_DARK, MAT.Concrete, NEVER)
	end
	box(bridge, "Girder", 30.2, 97.8, GAL - 2.1, GAL - 1, -3.9, -3.2, RUST, MAT.CorrodedMetal, TRIM)
	box(bridge, "BridgeRail", 30, 98, GAL, GAL + 1.1, -4, -3.7, STEEL_DARK, MAT.Metal, NEVER)
	-- Steel shields along the rail: cover on the crossing, with the way still 7 wide.
	for _, x in ipairs({ 39, 74, 84.5 }) do
		box(bridge, "BridgeShield", x, x + 3, GAL + 1.1, GAL + 2.8, -3.95, -3.75, mix(STEEL, RUST, 0.3), MAT.CorrodedMetal, NEVER)
		table.insert(B.cover, here(x + 1.5, GAL, -2.4))
	end
	-- The truss over the long span above the cut.
	local truss = { 62, 71, 80, 89, 98 }
	local y0, y1 = GAL + 1.1, GAL + 4.4
	rod(bridge, "TrussChord", Vector3.new(62, y1, -3.85), Vector3.new(98, y1, -3.85), 0.35, STEEL, MAT.Metal, TRIM)
	for index, x in ipairs(truss) do
		rod(bridge, "TrussPost", Vector3.new(x, y0, -3.85), Vector3.new(x, y1, -3.85), 0.3, STEEL, MAT.Metal, TRIM)
		local nextX = truss[index + 1]
		if nextX then
			local up = index % 2 == 1
			rod(bridge, "TrussBar", Vector3.new(x, up and y0 or y1, -3.85), Vector3.new(nextX, up and y1 or y0, -3.85), 0.26, STEEL, MAT.Metal, TRIM)
		end
	end
	return bridge
end

--------------------------------------------------------------------------------
-- The perimeter: broken walls round the edge of the disc between the lanes' ways in
--------------------------------------------------------------------------------

local PERIMETER = 121
-- Arcs of wall, in degrees round the centre (0 is +X; this half is the negative angles).
local PERIMETER_RUNS = { { -80, -64 }, { -117, -101 } }

local function buildPerimeter(root)
	local ring = folder(root, "Perimeter")
	for index, run in ipairs(PERIMETER_RUNS) do
		local a, b = math.rad(run[1]), math.rad(run[2])
		local chords = math.max(1, math.floor((run[2] - run[1]) / 8.5 + 0.5))
		for chord = 1, chords do
			local style = { name = "Wall", health = 200, color = index % 2 == 0 and BRICK or CONCRETE,
				material = index % 2 == 0 and MAT.Brick or MAT.Concrete, brick = index % 2 == 1, bottom = -1 - 0.1 * (chord % 2), light = true }
			-- Each chord stops a quarter of a stud short at both ends: a crack between them, and no two
			-- chords' panels overlapping at the joint (where two random tops could meet in one plane).
			local t0, t1 = a + (b - a) * (chord - 1) / chords, a + (b - a) * chord / chords
			local ax, az, bx, bz = PERIMETER * math.cos(t0), PERIMETER * math.sin(t0), PERIMETER * math.cos(t1), PERIMETER * math.sin(t1)
			local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
			local ux, uz = (bx - ax) / len * 0.25, (bz - az) / len * 0.25
			wallRun(ring, ax + ux, az + uz, bx - ux, bz - uz, 1.6, 5.8, 8.8, style)
		end
		local t = index % 2 == 0 and a - 0.03 or b + 0.03
		rubble(ring, (PERIMETER - 2.5) * math.cos(t), (PERIMETER - 2.5) * math.sin(t), 1.6, 4, 0,
			index % 2 == 0 and { BRICK, BRICK_DARK, CONCRETE_DARK } or nil)
	end
	return ring
end

--------------------------------------------------------------------------------
-- Routes, high ground and ziplines (for the bots' cover, the check and the gallery)
--------------------------------------------------------------------------------

local ROUTES = {
	-- The centre lane: in off the town, under the gatehouse, round the colossus, in at the door.
	Centre = { { 0, 0, -124 }, { 0, 0, -86 }, { 0, 0, -68.5 }, { 0, 0, -58 }, { -11, 0, -57 }, { -11, 0, -44 }, { -4.5, TILE, -40 },
		{ -4.5, TILE, -27 }, { -12, TILE, -27 }, { -12, KF, -21 }, { -12, KF, -14 }, { -3, KF, -3 }, { 0.5, KF, -0.4 } },
	-- The left lane: past the tram stop, between the tram and the chapel, along the berm's foot and in
	-- through the cut to the fountain.
	Pit = { { -62, 0, -108 }, { -56, 0, -70 }, { -54.5, 0, -56 }, { -48, 0, -50 }, { -48, 0, -29 }, { -64, 0, -28.5 },
		{ -71, 0, -24 }, { -71, TILE, -21 }, { -76, TILE, -12 }, { -84, TILE, -6.4 } },
	-- The market flank: up the east side, between the stalls, to the keep's east door.
	Market = { { 40, 0, -116 }, { 47, 0, -96 }, { 47, 0, -80 }, { 53, 0, -60 }, { 50.7, TILE, -46 }, { 50.7, TILE, -33 }, { 47, TILE, -26 },
		{ 47, TILE, -10 }, { 36, 0, -4 }, { 30, 0, -1 }, { 21, KF, -1 }, { 8, KF, -1 }, { 1, KF, -0.4 } },
}

local function recordRoutes()
	local suffix = B.mirror and "N" or "S"
	for name, points in pairs(ROUTES) do
		local list = {}
		for _, p in ipairs(points) do
			table.insert(list, here(p[1], p[2], p[3]))
		end
		B.routes[name .. suffix] = list
	end
	local lane = {}
	for _, p in ipairs(LANE) do
		table.insert(lane, here(p.X, p.Y, p.Z))
	end
	B.lanes[suffix] = lane
	-- The high ground in this half (the pieces that cross the mirror are the middle's).
	table.insert(B.power, { name = "Gatehouse" .. suffix, point = here(0, GATE_TOP, -68.5),
		box = B.mirror and { -20, 20, 65, 72 } or { -20, 20, -72, -65 }, minY = 7 })
	table.insert(B.power, { name = "BermRidge" .. suffix, point = here(-57, RIM, -15),
		box = B.mirror and { -66, -48, 4, 26 } or { -66, -48, -26, -4 }, minY = 5 })
	-- The ziplines: off the balcony's mast down over the market to this half's end of the cut, and off
	-- the landing's mast straight down into the pit, objective A to objective B: the fast ways off the
	-- keep, back to a flank or on to the other fight.
	table.insert(B.zips, { name = "BalconyZip" .. suffix, fromTop = here(29.3, ZIP_TOP, -6.1), to = here(62, 0, -66) })
	table.insert(B.zips, { name = "LandingZip" .. suffix, fromTop = here(-31.1, ZIP_TOP, -4.6), to = here(-80, TILE, -9) })
end

--------------------------------------------------------------------------------
-- The pieces on the mirror itself, built once: each is its own reflection
--------------------------------------------------------------------------------

local function buildMiddle(root)
	local middle = folder(root, "Middle", true)
	-- Objective A's mosaic in the keep's floor: the rot eye.
	groundDisc(middle, "Mosaic", 0, 0, 12, PURPLE_DARK, MAT.Slate, 0, KF)
	groundDisc(middle, "MosaicEye", 0, 0, 6.4, WHITE_PAINT, MAT.Marble, 1, KF)
	groundDisc(middle, "MosaicPupil", 0, 0, 2.6, ROT_GREEN, MAT.Neon, 2, KF)

	-- Objective B: the fountain, brimming with rot, its globe still lit.
	rod(middle, "FountainBasin", Vector3.new(PX, -0.2, 0), Vector3.new(PX, 1.2, 0), 11, LIME, MAT.Marble, NEVER)
	rod(middle, "FountainGoo", Vector3.new(PX, 1.2, 0), Vector3.new(PX, 1.32, 0), 9.6, ROT_GREEN, MAT.Neon, TRIM)
	rod(middle, "FountainPedestal", Vector3.new(PX, 1.1, 0), Vector3.new(PX, 3.6, 0), 2.0, LIME_DARK, MAT.Marble, NEVER)
	rod(middle, "FountainBowl", Vector3.new(PX, 3.6, 0), Vector3.new(PX, 4.2, 0), 4.2, LIME, MAT.Marble, NEVER)
	local globe = ball(middle, "RotGlobe", Vector3.new(PX, 5.3, 0), 2.4, ROT_GREEN, MAT.Neon, TRIM)
	light(globe, ROT_GREEN, 26, 1.4)
	coverBox(PX - 5.5, PX + 5.5, -5.5, 5.5, TILE)

	-- The gantry's mast, its beacon the arena's green, a dish on it.
	rod(middle, "RadioMast", Vector3.new(106, GAL, 0), Vector3.new(106, GAL + 22, 0), 1.0, STEEL, MAT.Metal, NEVER)
	rod(middle, "MastArm", Vector3.new(106, GAL + 16, -2.6), Vector3.new(106, GAL + 16, 2.6), 0.3, STEEL_DARK, MAT.Metal, TRIM)
	light(ball(middle, "MastBeacon", Vector3.new(106, GAL + 22.6, 0), 1.6, ROT_GREEN, MAT.Neon, TRIM), ROT_GREEN, 34, 1.6)
	rod(middle, "MastDish", Vector3.new(106.45, GAL + 12, 0), Vector3.new(107.05, GAL + 12, 0), 3.4, WHITE_PAINT, MAT.Metal, TRIM)

	-- The high ground that crosses the mirror.
	table.insert(B.power, { name = "KeepGallery", point = Vector3.new(0, GAL, -15), box = { -20, 20, -20, 20 }, minY = 9.5 })
	table.insert(B.power, { name = "PitRim", point = Vector3.new(-106, RIM, -8), box = { -110, -76, -26, 26 }, minY = 5.5 })
	table.insert(B.power, { name = "Gantry", point = Vector3.new(104, GAL, 0), box = { 98, 110, -8, 8 }, minY = 9 })
	table.insert(B.power, { name = "WestLanding", point = Vector3.new(-26, GAL, 0), box = { -30, -22, -5, 5 }, minY = 9 })
	return middle
end

--------------------------------------------------------------------------------
-- Layout and Build
--------------------------------------------------------------------------------

local function toWorld(frame, list)
	local out = {}
	for index, p in ipairs(list) do
		out[index] = frame * p
	end
	return out
end

-- The whole battleground in `frame` (its origin on the ground at the centre, LookVector to team 1),
-- parented to nothing. Returns the model and its lists in local space as well as world.
function TeamBattleground.Layout(frame, seed)
	B = { frame = frame, cover = {}, loot = {}, doorways = {}, routes = {}, power = {}, zips = {}, lanes = {} }
	local model = Instance.new("Model")
	model.Name = "TeamBattleground"
	for _, mirror in ipairs({ false, true }) do
		-- Each half from the same seed, so the wear (and every pool's number) repeats exactly.
		B.mirror = mirror
		B.rng = Random.new(seed or 1)
		B.turn, B.tilt, B.pools, B.stones = 0, 0, 0, {}
		local half = folder(model, mirror and "Team2Half" or "Team1Half")
		buildKeep(half)
		buildForecourt(half)
		buildGatehouse(half)
		buildEntry(half)
		buildPit(half)
		buildApproach(half)
		buildMarket(half)
		buildLane(half)
		buildGantry(half)
		buildBridge(half)
		buildPerimeter(half)
		recordRoutes()
	end
	B.mirror = false
	buildMiddle(model)

	local info = {
		frame = frame,
		objectivesLocal = table.clone(TeamBattleground.ObjectivesLocal),
		objectives = toWorld(frame, TeamBattleground.ObjectivesLocal),
		coverLocal = B.cover,
		cover = toWorld(frame, B.cover),
		lootSpots = {},
		doorways = B.doorways,
		routes = B.routes,
		power = B.power,
		lanes = B.lanes,
		zips = {},
	}
	for _, spot in ipairs(B.loot) do
		table.insert(info.lootSpots, { name = spot.name, localPosition = spot.at, position = frame * spot.at, kind = spot.kind, floor = spot.floor })
	end
	for _, zip in ipairs(B.zips) do
		table.insert(info.zips, { name = zip.name, fromTopLocal = zip.fromTop, toLocal = zip.to, fromTop = frame * zip.fromTop, to = frame * zip.to })
	end
	B = nil
	return model, info
end

-- The site's frame, flat, from any CFrame: its position and its yaw only.
local function flatYaw(cframe)
	local look = cframe.LookVector
	return math.atan2(-look.X, -look.Z)
end

local function flatFrame(cframe)
	local position = cframe.Position
	return CFrame.new(position.X, position.Y, position.Z) * CFrame.Angles(0, flatYaw(cframe), 0)
end

-- Whether `node` only holds things (the map, a top-level map folder, a town, a scatter group or a
-- themes group), so that what is inside it is what gets cleared, one thing at a time.
local function holds(node, map)
	if node == map or node.Parent == map or node:IsA("Folder") then
		return true
	end
	return node:GetAttribute("TownName") ~= nil or node:GetAttribute("FootingGroup") == true or node:GetAttribute("FootingSkip") == true
end

-- The thing in the map `part` belongs to, or nil for something ClearSite must leave alone.
local function itemOf(part, map)
	if part:GetAttribute("TeamBaseRuin") or part:GetAttribute("TeamBattleground") then
		return nil
	end
	local node = part
	while node.Parent and not holds(node.Parent, map) do
		node = node.Parent
	end
	if not node.Parent or node == map then
		return nil
	end
	local walk = node
	while walk and walk ~= map do
		if KEEP[walk.Name] then
			return nil
		end
		walk = walk.Parent
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

-- A long flat part (a street's asphalt, a kerb, a pavement) that runs into the disc is cut back to
-- where it meets the edge (plus half its own width), and what runs on outside it is kept, one piece
-- each side. Returns how many pieces are left (0: it was all inside), or nil for a part it cannot
-- cut (not a level block).
local function trimPart(part, centre, radius)
	local cf = part.CFrame
	if math.abs(cf.UpVector.Y) < 0.99 or part.Shape ~= Enum.PartType.Block then
		return nil
	end
	local size = part.Size
	local alongX = size.X >= size.Z
	local axis = alongX and cf.RightVector or cf.LookVector
	local u = Vector3.new(axis.X, 0, axis.Z).Unit
	local half = (alongX and size.X or size.Z) / 2
	local width = (alongX and size.Z or size.X) / 2
	local rel = Vector3.new(cf.Position.X - centre.X, 0, cf.Position.Z - centre.Z)
	local reach = radius + width
	local b = rel:Dot(u)
	local disc = b * b - (rel:Dot(rel) - reach * reach)
	if disc <= 0 then
		return 1
	end
	local t0, t1 = -b - math.sqrt(disc), -b + math.sqrt(disc)
	if t1 <= -half or t0 >= half then
		return 1
	end
	local pieces = {}
	if t0 > -half + 0.3 then
		table.insert(pieces, { -half, t0 })
	end
	if t1 < half - 0.3 then
		table.insert(pieces, { t1, half })
	end
	if #pieces == 0 then
		part:Destroy()
		return 0
	end
	local rotation = cf - cf.Position
	local parent = part.Parent
	for index, piece in ipairs(pieces) do
		local target = index == 1 and part or part:Clone()
		local length = piece[2] - piece[1]
		target.Size = alongX and Vector3.new(length, size.Y, size.Z) or Vector3.new(size.X, size.Y, length)
		target.CFrame = CFrame.new(cf.Position + u * ((piece[1] + piece[2]) / 2)) * rotation
		if index > 1 then
			target.Parent = parent
		end
	end
	return #pieces
end

-- Clears the site: every map item overlapping the disc and its apron that is no bigger than
-- ClearableSpan goes (buildings, parked cars, trees, props, street furniture); long flat pieces that
-- reach into the disc itself (the town's streets) are cut back to its edge; the loot lying there goes
-- too. Bigger things stay (the landmarks), and so does anything in KEEP or either team's base.
-- Returns cleared, trimmed, kept (the widest thing it had to leave).
function TeamBattleground.ClearSite(site, map)
	if not map then
		return 0, 0, 0
	end
	local frame = flatFrame(site)
	local centre = frame.Position
	local outer = TeamBattleground.Radius + TeamBattleground.Margin + TeamBattleground.Apron
	local cut = TeamBattleground.Radius + TeamBattleground.Margin + 2
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local include = { map }
	local loot = workspace:FindFirstChild("Loot")
	if loot then
		table.insert(include, loot)
	end
	params.FilterDescendantsInstances = include
	local cleared, trimmed, kept = 0, 0, 0
	local seen = {}
	local found = workspace:GetPartBoundsInBox(CFrame.new(centre + Vector3.new(0, 100, 0)), Vector3.new(outer * 2, 600, outer * 2), params)
	for _, part in ipairs(found) do
		local offset = part.Position - centre
		local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
		local reach = math.max(part.Size.X, part.Size.Z) / 2
		if part.Parent and flat - reach <= outer then
			if loot and part:IsDescendantOf(loot) then
				if not seen[part] then
					seen[part] = true
					part:Destroy()
				end
			else
				local item = itemOf(part, map)
				if item and not seen[item] then
					seen[item] = true
					local span = spanOf(item)
					if span <= TeamBattleground.ClearableSpan then
						item:Destroy()
						cleared += 1
					elseif item:IsA("BasePart") and flat - reach <= cut and trimPart(item, centre, cut) ~= 1 then
						trimmed += 1
					else
						kept = math.max(kept, span)
					end
				end
			end
		end
	end
	return cleared, trimmed, kept
end

-- Why the battleground cannot go here, or nil: the river through the disc (a pad never writes over
-- water, and a lane with a river down it is not a lane).
function TeamBattleground.SiteRefusal(site, mapInfo)
	local river = mapInfo and mapInfo.river
	if not river then
		return nil
	end
	local frame = flatFrame(site)
	local reach = TeamBattleground.Radius + TeamBattleground.Margin
	for x = -reach, reach, 12 do
		for z = -reach, reach, 12 do
			if x * x + z * z <= reach * reach then
				local p = frame * Vector3.new(x, 0, z)
				if MapTerrain.InRiver(river, p.X, p.Z, 6) then
					return "river"
				end
			end
		end
	end
	return nil
end

-- The level the town's own pads stand at under the disc (all at the town's height), or nil.
local function padLevel(frame)
	local counts, best, bestCount = {}, nil, 0
	local reach = TeamBattleground.Radius + TeamBattleground.Margin
	for x = -reach, reach, 8 do
		for z = -reach, reach, 8 do
			if x * x + z * z <= reach * reach then
				local p = frame * Vector3.new(x, 0, z)
				local height = MapTerrain.PadAt(p.X, p.Z)
				if height then
					local key = math.floor(height * 100 + 0.5)
					counts[key] = (counts[key] or 0) + 1
					if counts[key] > bestCount then
						best, bestCount = height, counts[key]
					end
				end
			end
		end
	end
	return best
end

-- Builds the battleground: refuses a river site, clears the site, levels the disc (MapTerrain's
-- FlattenPad, painted bare earth), lays the battleground out at the height the pad actually came out
-- at, puts it in the map, runs the z-fight pass and hangs the ziplines. The arena's middle is a town
-- square, flat already, whose buildings each stood on a pad of their own at the town's level: when
-- FlattenPad refuses the disc for those, it is asked again at exactly that level; failing that, ground
-- flat within a stud and a half is built on as it stands (every floor reaches below it).
function TeamBattleground.Build(centre, mapInfo, seed)
	local map = (mapInfo and mapInfo.map) or workspace:FindFirstChild("Map")
	if not map then
		return nil, "no map"
	end
	local site, yaw = flatFrame(centre), flatYaw(centre)
	local refusal = TeamBattleground.SiteRefusal(site, mapInfo)
	if refusal then
		return nil, refusal
	end
	TeamBattleground.ClearSite(site, map)
	local size = Vector3.new(TeamBattleground.Radius * 2, 0, TeamBattleground.Radius * 2)
	local options = { shape = "round", height = "mid", margin = TeamBattleground.Margin, material = Enum.Material.Ground }
	local height, why = MapTerrain.FlattenPad(site, size, options)
	if not height and why == "pad" then
		local level = padLevel(site)
		if level then
			options.height = level
			height, why = MapTerrain.FlattenPad(site, size, options)
		end
	end
	if not height then
		local low, high = MapTerrain.PadCost(site, size, { shape = "round", margin = TeamBattleground.Margin })
		if not low or high - low > 1.5 then
			return nil, "ground not levelled: " .. tostring(why)
		end
		height = (low + high) / 2
		warn(string.format("TeamBattleground: ground not levelled (%s); built on it as it stands, %.2f to %.2f", tostring(why), low, high))
	end
	local position = site.Position
	local frame = CFrame.new(position.X, height, position.Z) * CFrame.Angles(0, yaw, 0)
	local model, info = TeamBattleground.Layout(frame, seed)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part:SetAttribute("TeamBattleground", true)
		end
	end
	model.Parent = map
	ZFight.Fix({ model })

	-- The ziplines, after the z-fight pass (they are ZiplineService's own geometry). A failure costs the
	-- battleground a zipline, never the match its battleground.
	local lines = Instance.new("Model")
	lines.Name = "Ziplines"
	lines:SetAttribute("IntentionalFloat", true)
	lines:SetAttribute("FootingSkip", true)
	lines.Parent = model
	info.ziplines = {}
	local okService, ZiplineService = pcall(require, script.Parent:WaitForChild("ZiplineService"))
	for _, zip in ipairs(info.zips) do
		local ok, line = false, ZiplineService
		if okService then
			ok, line = pcall(ZiplineService.Create, lines, zip.fromTop, zip.to, zip.fromTop)
		end
		if ok and line then
			table.insert(info.ziplines, line)
		else
			warn("TeamBattleground: zipline " .. zip.name .. " not hung: " .. tostring(line))
		end
	end

	info.model = model
	info.height = height
	info.alive = true
	return info
end

-- Built cover near `origin`: the floor points behind this battleground's walls, sandbags, crates and
-- containers within `radius` (flat) and a storey of `origin`, nearest first. For BotNav.FindCover.
function TeamBattleground.CoverNear(info, origin, radius)
	local found = {}
	if not (info and info.alive) then
		return found
	end
	for _, point in ipairs(info.cover) do
		local dx, dz = point.X - origin.X, point.Z - origin.Z
		local d = dx * dx + dz * dz
		if d <= radius * radius and math.abs(point.Y - origin.Y) < 12 then
			table.insert(found, { point, d })
		end
	end
	table.sort(found, function(a, b)
		return a[2] < b[2]
	end)
	local out = {}
	for index = 1, math.min(#found, 16) do
		out[index] = found[index][1]
	end
	return out
end

-- Loot on the battleground's spots: chests in the chest spots, weapons that roll at least the spot's
-- rarity (the most exposed spots hold the best), heals and items; then every RESTOCK seconds while it
-- stands, any spot whose pickup has been taken is filled again.
local RESTOCK = 75
local SPOT_TAKEN = 3

local function spotFree(position)
	local loot = workspace:FindFirstChild("Loot")
	if not loot then
		return true
	end
	for _, item in ipairs(loot:GetChildren()) do
		if item:IsA("BasePart") and not item:GetAttribute("Claimed") then
			local d = item.Position - position
			if Vector3.new(d.X, 0, d.Z).Magnitude < SPOT_TAKEN and math.abs(d.Y) < 5 then
				return false
			end
		end
	end
	return true
end

-- The best of up to 16 ground rolls, stopping at the first that reaches `floor`: a spot that asks for
-- Epic gets an Epic or better nearly every time, never a gun the pool doesn't hold.
function TeamBattleground.RollWeapon(WeaponData, Rarity, floor)
	local best = WeaponData.RollGroundWeapon()
	for _ = 1, 16 do
		if not floor or Rarity.IsAtLeast(best.rarity, floor) then
			break
		end
		local def = WeaponData.RollGroundWeapon()
		if (Rarity.Index[def.rarity] or 0) > (Rarity.Index[best.rarity] or 0) then
			best = def
		end
	end
	return best
end

local function seedSpot(LootService, WeaponData, Rarity, spot)
	if spot.kind == "weapon" and spot.floor then
		LootService.DropWeapon(TeamBattleground.RollWeapon(WeaponData, Rarity, spot.floor).id, spot.position, nil, spot.position)
	else
		LootService.SeedAt({ spot.position }, spot.kind)
	end
end

function TeamBattleground.SeedLoot(info)
	local shared = ReplicatedStorage:WaitForChild("Shared")
	local okLoot, LootService = pcall(require, script.Parent:WaitForChild("LootService"))
	local okWeapons, WeaponData = pcall(require, shared:WaitForChild("WeaponData"))
	local okRarity, Rarity = pcall(require, shared:WaitForChild("Rarity"))
	if not (okLoot and okWeapons and okRarity) then
		warn("TeamBattleground: no loot: " .. tostring(not okLoot and LootService or not okWeapons and WeaponData or Rarity))
		return 0
	end
	local function fill()
		local placed = 0
		for _, spot in ipairs(info.lootSpots) do
			if not info.alive then
				break
			end
			if spotFree(spot.position) then
				local ok, problem = pcall(seedSpot, LootService, WeaponData, Rarity, spot)
				if ok then
					placed += 1
				else
					warn("TeamBattleground: loot at " .. spot.name .. " failed: " .. tostring(problem))
				end
			end
		end
		return placed
	end
	local placed = fill()
	task.spawn(function()
		while info.alive do
			task.wait(RESTOCK)
			if info.alive then
				fill()
			end
		end
	end)
	return placed
end

-- Takes it down (the match ending).
function TeamBattleground.Destroy(info)
	if not info then
		return
	end
	info.alive = false
	if info.model then
		info.model:Destroy()
	end
end

return TeamBattleground
