-- Car parks for the towns (Oliver's #31, "real parking lots for cars to spawn on"; 09-24: "the parking
-- lot locations still are terrible and the parking lots don't all need to be full", and then "way
-- better": believable, detailed lots that are good to fight in).
--
-- WHERE. A town's car park is one of its street lots, the way a real one is: it takes a plot on a
-- street, right beside the building it serves, fronting the street and square to it, instead of
-- whatever ground was left over once the town was built (which put it past the end of a street, or out
-- in the field beyond the last house). MapGenerator's building walk hands it the plot:
--
--   ParkingLots.Reserve(town, ctx) -> plan | nil     during the walk, once every street side has had
--                                                    its first building: the plot right after one of
--                                                    them, levelled and claimed
--   ParkingLots.Build(town, plan, space) -> bays     once the streets are drawn: the car park itself
--   ParkingLots.DealFills(towns)                     once the map's towns are built: how full each is
--
-- so the buildings after it go round it and it stands in the row like any other lot: right beside the
-- first building on its street side (by the square), the street in front, its axes the street's. The
-- main street first, then the cross street's inner arms, then any other street; a street side with a
-- building before one without. A plot that doesn't fit (another claim, the back street's lots, the
-- street's end) moves along a few studs at a time; a car park of GOOD_BAYS on a better street is taken
-- before a bigger one on a worse, and then any size down to MIN_BAYS. A town with no room for even that
-- has no car park (its cars go to the kerb and its driveways); a town that says it has no cars
-- (TownKinds' blurb) doesn't get one.
--
-- WHAT. Three kinds, by what the town is (KindFor) and the map it's on:
--   paved    the town car park: asphalt the streets' own (sun-bleached on sand), raised concrete curbs
--            with a real face, planted islands at the row ends (the map's own trees and shrubs: palms
--            and cacti on sand), a raised walkway down the side by the building it serves with
--            bollards along it and a painted crossing to it, hairpin stall lines, an accessible stall
--            and its hatched access bay, concrete wheel stops at the stall heads, aisle arrows and a
--            stop bar at the way out, light poles lit after dark, a pay machine and a bin, a cart
--            corral at a shop, a hedge where it meets the yards; worn paint, patched asphalt, oil
--            stains, a drain
--   gravel   the country or desert lot (rural and market towns, and the small-town lots on sand): a
--            gravel yard in timber edging, no lines, timber wheel stops, tyre tracks, a post-and-rail
--            fence and a hand-painted board
--   yard     the works car park (industrial towns): a concrete apron with its joints showing, faded
--            yellow lines, a chain-link fence, a barrier arm at the gate, a floodlight, crates
-- and two layouts, by what fits the plot (paved lots take either, seeded):
--   double   two rows either side of a two-way aisle square to the street, the aisle opening straight
--            onto it: in on its right-hand half, out on the other with the stop bar across it
--   angled   one row of 60-degree stalls behind a one-way aisle along the street, in at one end and
--            out at the other (with the traffic on the near side of the street), a planted strip
--            between the aisle and the pavement, big planted islands at the row's ends
-- Every way in is the street's own kerb dropped (MapDecor.DropKerb) and its pavement cut
-- (MapDecor.CutPavement), with an apron of the car park's surface across the gap flush with the
-- street: street, dropped kerb, apron and car park one surface at RoadLift. Its mouth is claimed out
-- into the near lane, so no bench, lamp or kerbside car ever stands in it.
--
-- EVERYTHING BREAKS (Oliver 09-24): the surface too, and the ground is always right under it (the pad
-- this levels, painted), so a broken car park shows ground, never a hole. What's built of several
-- parts is one breakable thing (its parts share a `Destructible` group): a lamp, a tree, an island
-- and what grows on it, a fence side, the pay machine; the surface and its paint break together.
-- Islands and curbs stand on the ground through the surface, not on it.
--
-- Nothing a vehicle drives over collides: curbs, islands' edges, the walkway and wheel stops are
-- visual, like the streets' own kerbs, so nothing snags a wheel; what stands up (lamps, trees,
-- shrubs, bollards, hedges, fences, the pay machine, the barrier post, crates) is solid cover, and
-- none of it stands in an aisle or a stall.
--
-- The bays are published on the town as the attributes VehicleService.ParkInTowns and MapDecor.ParkBays
-- read (a Roblox attribute can't hold a table):
--   ParkingBays      how many (the accessible stalls aren't among them: nothing is parked there)
--   ParkingBay_<i>   CFrame at the bay's centre on the surface's top, LookVector = the parked car's
--                    nose: into the stall, away from the aisle (nose-in). Numbered from the building's
--                    end back, so a lower number is a bay nearer where people walk to.
--   ParkingBayNext_<i>  the bay beside it in the same row, if any (for MapDecor.ParkBays' straddler)
--   ParkingBaySize   Vector3 (width, 1, length), TownKinds.Bay
--   ParkingAccessible, ParkingAccessible_<i>   the accessible stalls, the same way
--   ParkingFill      how full this car park is, 0..1 (DealFills): ParkBays parks scenery up to it
-- and the car park's model carries Kind, Layout, Parts and the aisle (AisleA, AisleB, AisleWidth), for
-- the tools.

local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Modules")
local MapTerrain = require(Modules:WaitForChild("MapTerrain"))
local TownKinds = require(Modules:WaitForChild("TownKinds"))
local MapDecor = require(Modules:WaitForChild("MapDecor"))

local ParkingLots = {}

local BAY = TownKinds.Bay or { width = 10.2, length = 18.6 }
-- The two-way aisle: 14 studs, three quarters of a bay's length. A real car park's aisle is 6 m for
-- 4.8 m bays, 1.25 : 1; narrower here because the longest car (17.4) is a stud and a half shorter than
-- its bay and the arcade handling turns tighter than a real car, and every stud of aisle is a stud of
-- frontage. A one-way aisle beside 60-degree stalls needs less: 12.
local AISLE = 14
local AISLE_ONE_WAY = 12
local ANGLE = math.rad(60)

-- Heights over the ground the car park is levelled to. The surface is the street's (its top at
-- RoadLift), paint lies on it (MarkRaise proud), and a curb stands CURB_RISE above the surface: a real
-- face you can see (a street kerb only stands 0.1 proud of its asphalt). Island soil sits a tenth under
-- the curb's top, so the two tops never share a plane (ZFight counts 0.045).
local LIFT = MapDecor.RoadLift or 0.4
local MARK = MapDecor.MarkRaise or 0.07
local CURB_RISE = 0.35
local CURB_TOP = LIFT + CURB_RISE
local SOIL_TOP = CURB_TOP - 0.1
local SINK = 0.06
local CURB = MapDecor.KerbWidth or 0.8

-- Layout dimensions: an end island's depth along its row, the walkway's width, a hedge or fence band's
-- width, an angled lot's way in and way out, and its planted strip along the street.
local ISLAND = 5
local WALK = 4.8
local BAND = 1.8
local THROAT = 12
local STRIP = 5
-- Two lots side by side keep 2.5 studs of ground between them (a building's own claim carries 1.5).
local CLAIM_MARGIN = 1

local MIN_BAYS, MAX_BAYS = 4, 12
-- Any car park on a better street before a bigger one on a worse (see Reserve): with its accessible
-- stall, hatched bay and corral a paved lot of eight stalls has five bays, and eight stalls in two rows
-- is as deep as the main street's lots go (54 studs of the 57 between it and the back street).
local GOOD_BAYS = 4
-- How full a car park is (ParkingFill): FILL_MIN + (FILL_MAX - FILL_MIN) * u ^ FILL_SKEW, u in 0..1,
-- dealt across a map's car parks by DealFills. Half come out under 0.15 + 0.55 * 0.5 ^ 1.5 = 0.34
-- full, the mean is 0.15 + 0.55 / 2.5 = 0.37, the top sixth of u gives 0.57 to 0.7, and none is ever
-- over 0.7.
local FILL_MIN, FILL_MAX, FILL_SKEW = 0.15, 0.7, 1.5
ParkingLots.FillMin, ParkingLots.FillMax = FILL_MIN, FILL_MAX

-- How far along a street a plot may slide from where the walk left off, and in what steps.
local SLIDE, SLIDE_STEP = 24, 2

-- Parts a car park may take, its parked cars apart (each of those is a real design, 200 to 290 parts):
-- tools/parking_lot_check.py holds every car park to it. A paved double lot of eight stalls comes to
-- about 150: surface and paint 60, curbs and walkway 12, four islands with a tree or shrub 30, two
-- lights 10, hedges 8, bollards, pay machine, bin and sign 25.
ParkingLots.PartBudget = { paved = 190, gravel = 80, yard = 110 }

--------------------------------------------------------------------------------
-- Colours
--------------------------------------------------------------------------------

local WHITE = Color3.fromRGB(238, 238, 230)
local YELLOW = Color3.fromRGB(222, 184, 60)
local BLUE = Color3.fromRGB(38, 98, 196)
local CONCRETE = Color3.fromRGB(178, 176, 168)
local CONCRETE_LIGHT = Color3.fromRGB(196, 194, 186)
local METAL_DARK = Color3.fromRGB(52, 54, 60)
local LAMP_GLOW = Color3.fromRGB(255, 226, 170)
local TIMBER = Color3.fromRGB(116, 84, 56)
local TIMBER_DARK = Color3.fromRGB(88, 62, 42)
local HEDGE = Color3.fromRGB(52, 96, 54)
local TRUNK = Color3.fromRGB(94, 70, 48)
local LEAVES = { Color3.fromRGB(70, 118, 58), Color3.fromRGB(84, 132, 62), Color3.fromRGB(62, 108, 70) }

-- The surface per kind, and on sand: sun-bleached asphalt, sandy gravel.
local function surfaceOf(kind, sand)
	if kind == "gravel" then
		return sand and Color3.fromRGB(204, 182, 138) or Color3.fromRGB(138, 132, 120), Enum.Material.Pebble
	elseif kind == "yard" then
		return Color3.fromRGB(164, 162, 154), Enum.Material.Concrete
	end
	return sand and Color3.fromRGB(88, 86, 84) or (MapDecor.AsphaltColor or Color3.fromRGB(62, 62, 66)), Enum.Material.Asphalt
end

--------------------------------------------------------------------------------
-- Building blocks, in the car park's own frame (x along the street, z away from it, y up from the
-- ground it's levelled to). `lot` carries the frame (`base`) and the model, and counts the parts.
--------------------------------------------------------------------------------

local groupSerial = 0
local function newGroup(kind)
	groupSerial += 1
	return kind .. ":P" .. groupSerial
end

local function part(lot, name, size, cframe, color, material, opts)
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = opts.collide == true
	p.CanQuery = opts.collide == true or opts.query == true
	p.CanTouch = false
	p.CastShadow = opts.shadow == true
	if opts.shape then
		p.Shape = opts.shape
	end
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if opts.transparency then
		p.Transparency = opts.transparency
	end
	if opts.group then
		p:SetAttribute("Destructible", opts.group)
	end
	p.Parent = lot.model
	lot.parts += 1
	return p
end

-- An axis-aligned box in the car park's frame, x0..x1, y0..y1, z0..z1.
local function box(lot, name, x0, x1, y0, y1, z0, z1, color, material, opts)
	if x1 - x0 < 0.02 or z1 - z0 < 0.02 or y1 - y0 < 0.01 then
		return nil
	end
	return part(lot, name, Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		lot.base * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, material, opts)
end

-- A flat bar from (ax, az) to (bx, bz), `width` wide, y0..y1: paint and rails at any angle.
local function strip(lot, name, ax, az, bx, bz, width, y0, y1, color, material, opts)
	local dx, dz = bx - ax, bz - az
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 0.02 then
		return nil
	end
	local mid = lot.base * CFrame.new((ax + bx) / 2, (y0 + y1) / 2, (az + bz) / 2)
	local look = lot.base:VectorToWorldSpace(Vector3.new(dx, 0, dz) / length)
	return part(lot, name, Vector3.new(width, y1 - y0, length), CFrame.lookAt(mid.Position, mid.Position + look), color,
		material, opts)
end

-- An upright cylinder standing on `y` at (x, z).
local function post(lot, name, x, z, y, height, diameter, color, material, opts)
	opts = opts or {}
	opts.shape = opts.shape or Enum.PartType.Cylinder
	local p = lot.base * CFrame.new(x, y + height / 2, z)
	return part(lot, name, Vector3.new(height, diameter, diameter), CFrame.new(p.Position) * CFrame.Angles(0, 0, math.pi / 2),
		color, material, opts)
end

-- A disc lying flat at (x, z), y0..y1.
local function disc(lot, name, x, z, y0, y1, diameter, color, material, opts)
	opts = opts or {}
	opts.shape = Enum.PartType.Cylinder
	local p = lot.base * CFrame.new(x, (y0 + y1) / 2, z)
	return part(lot, name, Vector3.new(y1 - y0, diameter, diameter), CFrame.new(p.Position) * CFrame.Angles(0, 0, math.pi / 2),
		color, material, opts)
end

-- Paint: a strip lying on the surface, MARK proud, worn to the car park's own degree (a little
-- transparency and a little of the surface's colour through it, varying line to line). Breaks with
-- the surface.
local function paint(lot, name, ax, az, bx, bz, width, color)
	local wear = math.clamp(lot.wear + (math.random() - 0.5) * 0.12, 0, 0.45)
	local c = (color or WHITE):Lerp(lot.surfaceColor, wear * 0.45)
	return strip(lot, name, ax, az, bx, bz, width, LIFT, LIFT + MARK, c, Enum.Material.SmoothPlastic,
		{ transparency = wear * 0.5, group = lot.surfaceGroup })
end

--------------------------------------------------------------------------------
-- Layouts. Each lays out the car park in its own frame with the street along -z (its front edge at
-- -depth / 2, flush with the back of the pavement). `bs` is the side (-1 or +1 along x) of the
-- building it serves, where the walkway goes.
--------------------------------------------------------------------------------

local function doubleSize(n, o)
	local width = (o.walk and WALK or CURB) + 2 * BAY.length + AISLE + CURB + (o.band and BAND or 0)
	local depth = CURB + (o.front and ISLAND or 0) + n * BAY.width + (o.back and ISLAND or 0) + CURB + (o.band and BAND or 0)
	return width, depth
end

-- An angled stall's spacing along the aisle, and how far its rectangle reaches along the aisle and
-- across it either side of its middle.
local function angledStep()
	return BAY.width / math.sin(ANGLE)
end
local function angledReach()
	return BAY.length / 2 * math.cos(ANGLE) + BAY.width / 2 * math.sin(ANGLE),
		BAY.length / 2 * math.sin(ANGLE) + BAY.width / 2 * math.cos(ANGLE)
end

local function angledSize(n, o)
	local hx, hz = angledReach()
	local row = (n - 1) * angledStep() + 2 * hx
	local width = (o.walk and WALK or CURB) + THROAT + 1 + row + 1 + THROAT + CURB + (o.band and BAND or 0)
	local depth = STRIP + AISLE_ONE_WAY + 2 * hz + CURB + (o.band and BAND or 0)
	return width, depth
end

-- The double layout. Rows run back from the street (+z) either side of the aisle; the building's row
-- is A. Slots are laid from the front: the accessible stall and its hatched access bay first in row A
-- (nearest the walkway and the street), a cart corral or the crates at the back of row B.
local function doubleLayout(shape, bs, o)
	local W, D = shape.width, shape.depth
	-- u runs across from the building's side: u = 0 is its edge.
	local function X(u)
		return bs < 0 and (-W / 2 + u) or (W / 2 - u)
	end
	local function xr(u0, u1)
		local a, b = X(u0), X(u1)
		return math.min(a, b), math.max(a, b)
	end
	local e = o.walk and WALK or CURB
	local L, A, n = BAY.length, AISLE, shape.perRow
	local zf = -D / 2
	local zs = zf + CURB + (o.front and ISLAND or 0)
	local ze = zs + n * BAY.width
	local zb = ze + (o.back and ISLAND or 0)
	local g = { islands = {}, slots = {}, openings = {}, bollards = {}, curbs = {} }
	local ax0, ax1 = xr(e + L, e + L + A)
	local mid = (ax0 + ax1) / 2
	g.aisle = { ax = mid, az = zf, bx = mid, bz = zb, width = A, x0 = ax0, x1 = ax1 }
	local sx0, sx1 = xr(e, e + 2 * L + A)
	g.slab = { sx0, sx1, zf + CURB, zb }
	-- The front curb stops at the aisle; the aisle's mouth is the way in and out.
	table.insert(g.openings, { x0 = ax0, x1 = ax1, role = "both" })
	local r0, r1 = xr(e, e + L)
	local s0, s1 = xr(e + L + A, e + 2 * L + A)
	local f0, f1 = xr(e + 2 * L + A, e + 2 * L + A + CURB)
	table.insert(g.curbs, { f0, f1, zf, zb + CURB })
	local b0, b1 = xr(o.walk and 0 or CURB, e + 2 * L + A)
	table.insert(g.curbs, { b0, b1, zb, zb + CURB })
	table.insert(g.curbs, { r0, r1, zf, zf + CURB })
	table.insert(g.curbs, { s0, s1, zf, zf + CURB })
	if o.walk then
		local w0, w1 = xr(0, WALK)
		g.walkway = { w0, w1, zf, zb }
		-- Bollards along the walkway's edge at the heads of row A's stalls (none on the ramp at its front).
		for index = 0, n do
			local z = zs + index * BAY.width
			if z >= zf + 3 then
				table.insert(g.bollards, { X(WALK - 0.6), z })
			end
		end
		g.payAt = { X(WALK / 2), zf + 3.4 }
		g.binAt = { X(WALK / 2), zb - 2.4 }
	else
		local w0, w1 = xr(0, CURB)
		table.insert(g.curbs, { w0, w1, zf, zb + CURB })
	end
	if o.band then
		local h0, h1 = xr(e + 2 * L + A + CURB, e + 2 * L + A + CURB + BAND)
		local k0, k1 = xr(0, e + 2 * L + A + CURB)
		g.bands = {
			{ h0, h1, zf, zb + CURB + BAND, along = "z" },
			{ k0, k1, zb + CURB, zb + CURB + BAND, along = "x" },
		}
	end
	-- Islands: at the front of each row (either side of the way in, with the crossing between them)
	-- and at the back, where the lights stand and the trees grow.
	-- The crossing runs between the two islands at the front, or failing those the two at the back:
	-- either way from the far row to the building's row and its walkway.
	if o.front then
		table.insert(g.islands, { r0, r1, zf + CURB, zs, plant = "shrub" })
		table.insert(g.islands, { s0, s1, zf + CURB, zs, plant = "shrub" })
		g.crossing = { ax0, ax1, zf + CURB + 0.9, zs - 0.9 }
	end
	if o.back then
		table.insert(g.islands, { r0, r1, ze, zb, plant = "tree", lamp = true, aisleX = ax0 })
		table.insert(g.islands, { s0, s1, ze, zb, plant = "tree", lamp = true, aisleX = ax1 })
		if not g.crossing then
			g.crossing = { ax0, ax1, ze + 0.9, zb - 0.9 }
		end
	end
	-- Slots, row A (the building's) then row B, each from the front. The nose points away from the aisle.
	for row, u in ipairs({ e + L / 2, e + L + A + L / 2 }) do
		local x = X(u)
		local nx = x < mid and -1 or 1
		for index = 1, n do
			local kind = "bay"
			if o.accessible and row == 1 and index == 1 then
				kind = "accessible"
			elseif o.accessible and row == 1 and index == 2 and n >= 3 then
				kind = "hatch"
			elseif o.corral and row == 2 and index == n and n >= 4 then
				kind = "corral"
			elseif o.crates and row == 2 and index == n and n >= 4 then
				kind = "crates"
			end
			table.insert(g.slots, { kind = kind, x = x, z = zs + (index - 0.5) * BAY.width, nx = nx, nz = 0, row = row, index = index })
		end
	end
	-- Lanes keep to the right: driving in (+z) the right-hand side is -x, so the way in is the aisle's
	-- -x half and the way out (toward the street, -z) its +x half, whichever side the building is on.
	g.stopBars = { { mid + 0.5, zs + 0.7, ax1 - 0.6, zs + 0.7 } }
	g.arrows = {
		{ x = (ax0 + mid) / 2, z = zs + math.min(9, n * BAY.width * 0.3), dx = 0, dz = 1 },
		{ x = (mid + ax1) / 2, z = ze - math.min(8, n * BAY.width * 0.28), dx = 0, dz = -1 },
	}
	-- Patches of newer asphalt: in the way-out half near the front, the way-in half near the back,
	-- clear of the arrows and the drain.
	g.patches = { { mid + 3.4, zs + (ze - zs) * 0.22 }, { mid - 3.4, zs + (ze - zs) * 0.8 } }
	-- The sign on row B's front curb beside the way in.
	g.signAt = { bs < 0 and (ax1 + 1.6) or (ax0 - 1.6), zf + CURB / 2 }
	g.drain = { mid, (zs + ze) / 2 }
	g.lampAt = {}
	g.zf, g.zs, g.ze, g.zb = zf, zs, ze, zb
	g.walkX = X(0)
	return g
end

-- The angled layout: the flow runs along +x (the traffic on the near side of the street runs that way,
-- so it's in at -x and out at +x, both turns to the right), one row of 60-degree stalls behind the
-- aisle, a planted strip between the aisle and the pavement, planted islands in the row's band behind
-- each throat, the walkway down the building's end.
local function angledLayout(shape, bs, o)
	local W, D = shape.width, shape.depth
	local n = shape.perRow
	local hx, hz = angledReach()
	local step = angledStep()
	local zf = -D / 2
	local za0 = zf + STRIP
	local za1 = za0 + AISLE_ONE_WAY
	local zr = za1 + 2 * hz
	local bandL = (o.band and bs > 0) and BAND or 0
	local bandR = (o.band and bs < 0) and BAND or 0
	local left = (o.walk and bs < 0) and WALK or CURB
	local right = (o.walk and bs > 0) and WALK or CURB
	local x0 = -W / 2 + bandL + left
	local x1 = W / 2 - bandR - right
	local inX0, inX1 = x0, x0 + THROAT
	local outX0, outX1 = x1 - THROAT, x1
	local g = { islands = {}, slots = {}, openings = {}, bollards = {}, curbs = {} }
	g.aisle = { ax = x0, az = (za0 + za1) / 2, bx = x1, bz = (za0 + za1) / 2, width = AISLE_ONE_WAY, oneWay = true, z0 = za0, z1 = za1 }
	g.slab = { x0, x1, zf + CURB, zr }
	table.insert(g.openings, { x0 = inX0, x1 = inX1, role = "in" })
	table.insert(g.openings, { x0 = outX0, x1 = outX1, role = "out" })
	-- The ends, full depth, where there's no walkway; the back, under the walkway's end too.
	if not (o.walk and bs < 0) then
		table.insert(g.curbs, { x0 - CURB, x0, zf, zr + CURB })
	end
	if not (o.walk and bs > 0) then
		table.insert(g.curbs, { x1, x1 + CURB, zf, zr + CURB })
	end
	table.insert(g.curbs, { x0 - left, x1 + right, zr, zr + CURB })
	-- The planted strip between the throats, its own curbs all round it: shrubs and two lights.
	table.insert(g.islands, { inX1, outX0, zf, za0, plant = "shrubs", lamp = true, strip = true })
	-- The row, centred between the throats.
	local rowLen = (n - 1) * step + 2 * hx
	local rowX0 = inX1 + 1 + math.max(0, ((outX0 - 1) - (inX1 + 1) - rowLen) / 2)
	local nx, nz = math.cos(ANGLE), math.sin(ANGLE)
	-- Islands in the row's band behind each throat, clear of the stalls' corners.
	table.insert(g.islands, { inX0 + 0.6, rowX0 - 0.6, za1 + 1.2, zr, plant = "tree" })
	table.insert(g.islands, { rowX0 + rowLen + 0.6, outX1 - 0.6, za1 + 1.2, zr, plant = "tree", lamp = true, aisleX = outX1 - 2 })
	for index = 1, n do
		local kind = "bay"
		local fromBuilding = bs < 0 and index or (n + 1 - index)
		if o.accessible and fromBuilding == 1 then
			kind = "accessible"
		elseif o.accessible and fromBuilding == 2 then
			kind = "hatch"
		end
		table.insert(g.slots, { kind = kind, x = rowX0 + hx + (index - 1) * step, z = za1 + hz, nx = nx, nz = nz, row = 1, index = index })
	end
	if o.walk then
		local w0, w1 = bs < 0 and x0 - WALK or x1, bs < 0 and x0 or x1 + WALK
		g.walkway = { w0, w1, zf, zr }
		local bx = bs < 0 and (x0 - 0.6) or (x1 + 0.6)
		for index = 0, 3 do
			table.insert(g.bollards, { bx, za0 + 1 + index * (zr - za0 - 2) / 3 })
		end
		g.payAt = { (w0 + w1) / 2, zf + 3.4 }
		g.binAt = { (w0 + w1) / 2, zr - 2.4 }
		-- The crossing over the throat by the walkway, to the planted strip.
		local t0, t1 = bs < 0 and inX0 or outX0, bs < 0 and inX1 or outX1
		g.crossing = { t0, t1, zf + CURB + 0.9, za0 - 0.9 }
	end
	if o.band then
		if bs < 0 then
			g.bands = { { W / 2 - BAND, W / 2, zf, zr + CURB + BAND, along = "z" }, { -W / 2, W / 2 - BAND, zr + CURB, zr + CURB + BAND, along = "x" } }
		else
			g.bands = { { -W / 2, -W / 2 + BAND, zf, zr + CURB + BAND, along = "z" }, { -W / 2 + BAND, W / 2, zr + CURB, zr + CURB + BAND, along = "x" } }
		end
	end
	-- The stop bar across the way out, behind the pavement; arrows in, along and out.
	g.stopBars = { { outX0 + 0.8, za0 + 0.8, outX1 - 0.8, za0 + 0.8 } }
	g.arrows = {
		{ x = (inX0 + inX1) / 2, z = za0 + AISLE_ONE_WAY * 0.5, dx = 0, dz = 1, size = 5 },
		{ x = inX1 + (outX0 - inX1) * 0.3, z = (za0 + za1) / 2, dx = 1, dz = 0 },
		{ x = inX1 + (outX0 - inX1) * 0.75, z = (za0 + za1) / 2, dx = 1, dz = 0 },
	}
	g.patches = { { inX1 + (outX0 - inX1) * 0.52, (za0 + za1) / 2 + 2.5 } }
	g.signAt = { inX1 + 1.6, zf + CURB / 2 }
	g.drain = { inX1 + (outX0 - inX1) * 0.52, (za0 + za1) / 2 - 3 }
	g.zf, g.zs, g.ze, g.zb = zf, za1, zr, zr
	g.walkX = bs < 0 and -W / 2 or W / 2
	return g
end

--------------------------------------------------------------------------------
-- Props. Each is one breakable thing.
--------------------------------------------------------------------------------

-- A light pole standing on y at (x, z): a post, an arm reaching toward `toward`, a fixture with a lens
-- and a light that shows after dark (the maps have a dawn and a dusk, and Night Ops turns the day off).
local function lightPole(lot, x, z, y, toward, height)
	local group = newGroup("LampPost")
	height = height or 15
	post(lot, "LampPost", x, z, y - 0.3, height + 0.3, 0.7, METAL_DARK, Enum.Material.Metal, { collide = true, group = group, shadow = true })
	post(lot, "LampPostFoot", x, z, y - 0.3, 1.4, 1.2, METAL_DARK, Enum.Material.Metal, { group = group })
	local dx, dz = toward[1] - x, toward[2] - z
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 0.01 then
		dx, dz, len = 0, -1, 1
	end
	dx, dz = dx / len, dz / len
	local reach = 3.6
	local top = y + height
	strip(lot, "LampArm", x, z, x + dx * reach, z + dz * reach, 0.35, top - 0.35, top, METAL_DARK, Enum.Material.Metal, { group = group })
	local hx, hz = x + dx * (reach + 0.8), z + dz * (reach + 0.8)
	strip(lot, "LampHead", hx - dx * 1, hz - dz * 1, hx + dx * 1, hz + dz * 1, 1.2, top - 0.6, top + 0.05, METAL_DARK, Enum.Material.Metal,
		{ group = group, shadow = true })
	local lens = strip(lot, "LampLens", hx - dx * 0.8, hz - dz * 0.8, hx + dx * 0.8, hz + dz * 0.8, 0.9, top - 0.7, top - 0.6, LAMP_GLOW,
		Enum.Material.Neon, { group = group })
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 110
	light.Range = 34
	light.Brightness = 1.6
	light.Color = LAMP_GLOW
	light.Shadows = false
	light.Parent = lens
end

-- A car park tree, from the map's own palette: a palm on sand, a slim pine on bare ground or rock, a
-- broadleaf on grass. Standing on its island's soil at y, its trunk a little way into it. Its crown is
-- held high (over TREE_CLEAR) or kept within the island, so a car in the stall beside it, the tallest
-- being an armed van at 10.3, never has a branch through its roof.
local TREE_CLEAR = 11
local function islandTree(lot, x, z, y, group)
	local opts = { collide = true, group = group, shadow = true }
	if lot.terrain == Enum.Material.Sand then
		local trunk = Color3.fromRGB(150, 116, 78)
		post(lot, "PalmTrunk", x, z, y - 0.4, 7.4, 1.3, trunk, Enum.Material.Wood, opts)
		post(lot, "PalmTrunk", x + 0.3, z, y + 6.8, 6.4, 1.1, trunk, Enum.Material.Wood, opts)
		local crown = (lot.base * CFrame.new(x + 0.3, y + 13.2, z)).Position
		for index = 1, 5 do
			local a = index / 5 * math.pi * 2
			part(lot, "PalmFrond", Vector3.new(2, 0.3, 6.2), CFrame.new(crown) * CFrame.Angles(0, a, 0) * CFrame.Angles(math.rad(-16), 0, 0)
				* CFrame.new(0, 0, -2.8), Color3.fromRGB(68, 140, 66), Enum.Material.Grass, { group = group, shadow = true })
		end
	elseif lot.terrain == Enum.Material.Ground or lot.terrain == Enum.Material.Rock or lot.terrain == Enum.Material.Limestone then
		post(lot, "TreeTrunk", x, z, y - 0.4, 3.2, 0.9, TRUNK, Enum.Material.Wood, opts)
		local ty = y + 2.4
		for _, tier in ipairs({ { 3.6, 3.4 }, { 2.9, 3.2 }, { 2, 3 }, { 1.1, 2.6 } }) do
			post(lot, "TreeCrown", x, z, ty, tier[2], tier[1], Color3.fromRGB(44, 86, 60), Enum.Material.Grass, opts)
			ty += tier[2] * 0.85
		end
	else
		local height = TREE_CLEAR - 1 + math.random() * 1.5
		post(lot, "TreeTrunk", x, z, y - 0.4, height + 0.4, 1, TRUNK, Enum.Material.Wood, opts)
		local green = LEAVES[math.random(1, #LEAVES)]
		local size = 8.5 + math.random() * 1.5
		local top = (lot.base * CFrame.new(x, y + height + size * 0.3 + 0.2, z)).Position
		part(lot, "TreeCrown", Vector3.new(size, size * 0.62, size), CFrame.new(top), green, Enum.Material.Grass,
			{ shape = Enum.PartType.Ball, collide = true, group = group, shadow = true })
		part(lot, "TreeCrown", Vector3.new(5.5, 4.2, 5.5), CFrame.new(top + lot.base:VectorToWorldSpace(Vector3.new(1.6, 1.6, -1.1))),
			green:Lerp(Color3.new(1, 1, 1), 0.06), Enum.Material.Grass, { shape = Enum.PartType.Ball, group = group, shadow = true })
	end
end

-- A shrub on an island (a squat cactus on sand).
local function islandShrub(lot, x, z, y, group)
	if lot.terrain == Enum.Material.Sand then
		local green = Color3.fromRGB(88, 140, 76)
		post(lot, "Cactus", x, z, y - 0.3, 3.6, 1.4, green, Enum.Material.Grass, { collide = true, group = group })
		disc(lot, "CactusTop", x, z, y + 3.3, y + 3.9, 1.3, green, Enum.Material.Grass, { group = group })
		return
	end
	local green = LEAVES[math.random(1, #LEAVES)]
	for _, s in ipairs({ { -0.8, 0.2, 3.2 }, { 0.9, -0.3, 2.6 } }) do
		local p = (lot.base * CFrame.new(x + s[1], y + s[3] * 0.32, z + s[2])).Position
		part(lot, "Shrub", Vector3.new(s[3], s[3] * 0.8, s[3]), CFrame.new(p), green, Enum.Material.Grass,
			{ shape = Enum.PartType.Ball, collide = true, group = group })
	end
end

-- A raised island: a curb all round it and soil inside (grass, or sand on sand), from the ground up
-- through the surface, so it stands on the ground whatever breaks round it. One breakable thing with
-- what grows on it (the group is returned for that).
local function island(lot, r)
	local x0, x1, z0, z1 = r[1], r[2], r[3], r[4]
	if x1 - x0 < 2.4 or z1 - z0 < 2.4 then
		return nil
	end
	local group = newGroup("Island")
	local o = { group = group }
	box(lot, "IslandCurb", x0, x1, -SINK, CURB_TOP, z0, z0 + CURB, CONCRETE, Enum.Material.Concrete, o)
	box(lot, "IslandCurb", x0, x1, -SINK, CURB_TOP, z1 - CURB, z1, CONCRETE, Enum.Material.Concrete, o)
	box(lot, "IslandCurb", x0, x0 + CURB, -SINK, CURB_TOP, z0 + CURB, z1 - CURB, CONCRETE, Enum.Material.Concrete, o)
	box(lot, "IslandCurb", x1 - CURB, x1, -SINK, CURB_TOP, z0 + CURB, z1 - CURB, CONCRETE, Enum.Material.Concrete, o)
	local sand = lot.terrain == Enum.Material.Sand
	box(lot, "IslandSoil", x0 + CURB, x1 - CURB, -0.02, SOIL_TOP, z0 + CURB, z1 - CURB,
		sand and Color3.fromRGB(214, 190, 142) or Color3.fromRGB(86, 128, 62), sand and Enum.Material.Sand or Enum.Material.Grass, o)
	return group
end

-- A wheel stop across a stall `back` studs in from its head end: concrete, or a timber log in a gravel
-- lot. Low, a tenth into the surface, and it doesn't collide, so no wheel catches on it.
local function wheelStop(lot, slot, back)
	local hx, hz = slot.x + slot.nx * (BAY.length / 2 - back), slot.z + slot.nz * (BAY.length / 2 - back)
	local ax, az = -slot.nz, slot.nx
	local half = 2.8
	if lot.kind == "gravel" then
		local p = (lot.base * CFrame.new(hx, LIFT + 0.18, hz)).Position
		local look = lot.base:VectorToWorldSpace(Vector3.new(ax, 0, az))
		part(lot, "TimberWheelStop", Vector3.new(half * 2, 0.5, 0.5), CFrame.lookAt(p, p + look) * CFrame.Angles(0, math.pi / 2, 0),
			TIMBER, Enum.Material.Wood, { shape = Enum.PartType.Cylinder })
	else
		strip(lot, "WheelStop", hx - ax * half, hz - az * half, hx + ax * half, hz + az * half, 0.8, LIFT - 0.1, LIFT + 0.42,
			lot.kind == "yard" and YELLOW or CONCRETE_LIGHT, Enum.Material.Concrete)
	end
end

-- A stall's side line at (sx, sz), along the nose (nx, nz), `length` long: a hairpin (two lines a hand
-- apart, joined at the aisle end) in a paved lot, a single yellow line in a yard.
local function sideLine(lot, sx, sz, nx, nz, length, style)
	if style == "single" then
		paint(lot, "StallLine", sx - nx * length / 2, sz - nz * length / 2, sx + nx * length / 2, sz + nz * length / 2, 0.35, YELLOW)
		return
	end
	local ax, az = -nz, nx
	local gap, w = 0.28, 0.22
	for _, s in ipairs({ -1, 1 }) do
		local ox, oz = ax * s * gap, az * s * gap
		paint(lot, "StallLine", sx - nx * (length / 2 - w / 2) + ox, sz - nz * (length / 2 - w / 2) + oz, sx + nx * length / 2 + ox,
			sz + nz * length / 2 + oz, w)
	end
	-- The cap across the aisle end, butting the two lines' ends.
	local cx, cz = sx - nx * (length / 2 - w / 2) + 0, sz - nz * (length / 2 - w / 2)
	paint(lot, "StallLine", cx - nx * w / 2 - ax * (gap + w / 2), cz - nz * w / 2 - az * (gap + w / 2), cx - nx * w / 2 + ax * (gap + w / 2),
		cz - nz * w / 2 + az * (gap + w / 2), w)
end

-- A painted arrow: a shaft and a head of two triangles, `size` long, pointing (dx, dz).
local function arrow(lot, x, z, dx, dz, size)
	size = size or 7
	local ax, az = -dz, dx
	local shaft = size * 0.55
	local sx, sz = x - dx * size / 2, z - dz * size / 2
	paint(lot, "AisleArrow", sx, sz, sx + dx * shaft, sz + dz * shaft, 0.9)
	local corner = (lot.base * CFrame.new(sx + dx * shaft, LIFT + MARK / 2, sz + dz * shaft)).Position
	local u = lot.base:VectorToWorldSpace(Vector3.new(dx, 0, dz))
	local v = lot.base:VectorToWorldSpace(Vector3.new(ax, 0, az))
	local wear = math.clamp(lot.wear, 0, 0.45)
	for _, s in ipairs({ -1, 1 }) do
		local wedge = MapDecor.Triangle(lot.model, corner, u, v, 1, s, size - shaft, 1.6, MARK, WHITE:Lerp(lot.surfaceColor, wear * 0.45),
			Enum.Material.SmoothPlastic)
		wedge.Name = "AisleArrow"
		wedge.CanCollide, wedge.CanQuery, wedge.CanTouch = false, false, false
		wedge.Transparency = wear * 0.5
		wedge:SetAttribute("Destructible", lot.surfaceGroup)
		lot.parts += 1
	end
end

-- The accessible stall: blue paint inside its lines and the wheelchair sign on it in white.
local function accessibleStall(lot, slot)
	local nx, nz, ax, az = slot.nx, slot.nz, -slot.nz, slot.nx
	local halfW, halfL = BAY.width / 2 - 0.8, BAY.length / 2 - 0.5
	local sg = { group = lot.surfaceGroup }
	strip(lot, "AccessibleFill", slot.x - nx * halfL, slot.z - nz * halfL, slot.x + nx * (halfL - 2.2), slot.z + nz * (halfL - 2.2), halfW * 2,
		LIFT, LIFT + MARK, BLUE:Lerp(lot.surfaceColor, lot.wear * 0.4), Enum.Material.SmoothPlastic,
		{ transparency = lot.wear * 0.4, group = lot.surfaceGroup })
	local y = LIFT + MARK
	local cx, cz = slot.x - nx * 1.5, slot.z - nz * 1.5
	-- A wheel (a white disc with the blue showing through its middle), the seat's back and the head.
	disc(lot, "AccessibleSign", cx - ax * 0.5, cz - az * 0.5, y, y + MARK, 3.4, WHITE, Enum.Material.SmoothPlastic, sg)
	disc(lot, "AccessibleSign", cx - ax * 0.5, cz - az * 0.5, y + MARK, y + 2 * MARK, 2.3, BLUE, Enum.Material.SmoothPlastic, sg)
	strip(lot, "AccessibleSign", cx + ax * 0.9 - nx * 1.2, cz + az * 0.9 - nz * 1.2, cx + ax * 0.9 + nx * 1.4, cz + az * 0.9 + nz * 1.4, 0.55, y,
		y + MARK, WHITE, Enum.Material.SmoothPlastic, sg)
	disc(lot, "AccessibleSign", cx + ax * 0.9 + nx * 2.3, cz + az * 0.9 + nz * 2.3, y, y + MARK, 1.1, WHITE, Enum.Material.SmoothPlastic, sg)
end

-- A hatched no-parking bay: a yellow outline and bars across it at 45 degrees, none touching another.
local function hatchedBay(lot, slot)
	local nx, nz, ax, az = slot.nx, slot.nz, -slot.nz, slot.nx
	local halfW, halfL = BAY.width / 2 - 0.9, BAY.length / 2 - 0.6
	local w = 0.3
	local function at(a, n)
		return slot.x + ax * a + nx * n, slot.z + az * a + nz * n
	end
	for _, s in ipairs({ -1, 1 }) do
		local x0, z0 = at(s * (halfW - w / 2), -halfL)
		local x1, z1 = at(s * (halfW - w / 2), halfL)
		paint(lot, "HatchLine", x0, z0, x1, z1, w, YELLOW)
		local e0, f0 = at(-halfW + w, s * (halfL - w / 2))
		local e1, f1 = at(halfW - w, s * (halfL - w / 2))
		paint(lot, "HatchLine", e0, f0, e1, f1, w, YELLOW)
	end
	-- Bars at 45 degrees, each from one side to the other, a finger clear of the outline.
	local inner = halfW - w - 0.35
	local span = 2 * inner
	local n0 = -halfL + w + 0.35
	while n0 + span <= halfL - w - 0.35 do
		local x0, z0 = at(-inner, n0)
		local x1, z1 = at(inner, n0 + span)
		paint(lot, "HatchLine", x0, z0, x1, z1, 0.45, YELLOW)
		n0 += 3.2
	end
end

-- A cart corral in a stall: a red rail round three sides on posts, open at the aisle.
local function cartCorral(lot, slot)
	local group = newGroup("CartCorral")
	local nx, nz, ax, az = slot.nx, slot.nz, -slot.nz, slot.nx
	local hw, hl = 2.6, 6.5
	local function at(a, n)
		return slot.x + ax * a + nx * n, slot.z + az * a + nz * n
	end
	local red = Color3.fromRGB(196, 44, 40)
	local corners = { { -hw, -hl }, { -hw, hl }, { hw, hl }, { hw, -hl } }
	for index = 1, 3 do
		local x0, z0 = at(corners[index][1], corners[index][2])
		local x1, z1 = at(corners[index + 1][1], corners[index + 1][2])
		strip(lot, "CartCorralRail", x0, z0, x1, z1, 0.3, LIFT + 2.4, LIFT + 2.75, red, Enum.Material.Metal, { collide = true, group = group })
	end
	for _, c in ipairs(corners) do
		local x, z = at(c[1], c[2])
		post(lot, "CartCorralPost", x, z, LIFT - 0.1, 2.85, 0.35, red, Enum.Material.Metal, { collide = true, group = group })
	end
	-- Two carts nested inside it.
	for index = 0, 1 do
		local x, z = at(0, 2.2 - index * 1.4)
		local c = (lot.base * CFrame.new(x, LIFT + 1.6, z)).Position
		part(lot, "Cart", Vector3.new(2.4, 1.6, 3.2), CFrame.lookAt(c, c + lot.base:VectorToWorldSpace(Vector3.new(nx, 0, nz))),
			Color3.fromRGB(170, 176, 184), Enum.Material.DiamondPlate, { collide = true, group = group })
	end
end

-- The pay machine: a cabinet on the walkway facing the car park, its screen lit.
local function payMachine(lot, x, z, y, fx, fz)
	local group = newGroup("PayMachine")
	local p = (lot.base * CFrame.new(x, y + 2, z)).Position
	local cf = CFrame.lookAt(p, p + lot.base:VectorToWorldSpace(Vector3.new(fx, 0, fz)))
	part(lot, "PayMachine", Vector3.new(1.6, 4, 1.1), cf, Color3.fromRGB(40, 80, 150), Enum.Material.Metal, { collide = true, group = group, shadow = true })
	part(lot, "PayMachineScreen", Vector3.new(1, 0.7, 0.1), cf * CFrame.new(0, 0.8, -0.6), Color3.fromRGB(150, 220, 255), Enum.Material.Neon,
		{ group = group })
	part(lot, "PayMachineCap", Vector3.new(1.9, 0.3, 1.4), cf * CFrame.new(0, 2.15, 0), METAL_DARK, Enum.Material.Metal, { group = group })
end

-- The sign: a post and a "P" board, or a hand-painted PARKING board on two timber posts.
local function parkingSign(lot, x, z, y, wooden)
	local group = newGroup("Sign")
	local post_ = { collide = true, group = group }
	if wooden then
		for _, s in ipairs({ -1, 1 }) do
			post(lot, "SignPost", x + s * 1.7, z, y - 0.3, 5, 0.4, TIMBER_DARK, Enum.Material.Wood, post_)
		end
	else
		post(lot, "ParkingSignPost", x, z, y - 0.3, 6.3, 0.4, Color3.fromRGB(90, 94, 100), Enum.Material.Metal, post_)
	end
	local top = (lot.base * CFrame.new(x, y + (wooden and 4 or 6.4), z)).Position
	local board = part(lot, "ParkingSign", wooden and Vector3.new(4.6, 1.6, 0.25) or Vector3.new(2.6, 2.6, 0.25),
		CFrame.lookAt(top, top + lot.base:VectorToWorldSpace(Vector3.new(0, 0, -1))), wooden and TIMBER or Color3.fromRGB(40, 90, 200),
		wooden and Enum.Material.WoodPlanks or Enum.Material.SmoothPlastic, { query = true, group = group, shadow = true })
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = wooden and Vector2.new(230, 80) or Vector2.new(100, 100)
		gui.LightInfluence = 0.3
		gui.MaxDistance = 260
		gui.Parent = board
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = wooden and Enum.Font.FredokaOne or Enum.Font.GothamBlack
		label.Text = wooden and "PARKING" or "P"
		label.TextScaled = true
		label.TextColor3 = wooden and Color3.fromRGB(250, 240, 220) or Color3.new(1, 1, 1)
		label.Parent = gui
	end
end

--------------------------------------------------------------------------------
-- Kinds and shapes
--------------------------------------------------------------------------------

-- What kind of car park a town has, from its TownKinds profile and the map's ground.
function ParkingLots.KindFor(profile, terrainMaterial)
	profile = profile or {}
	local bays = profile.bays or {}
	local kind = profile.kind
	if kind == "industrial" or profile.name == "Bonkington" then
		return "yard"
	end
	if bays.kind == "gravel" or kind == "rural" or kind == "market" then
		return "gravel"
	end
	-- On sand a small town's lot is sandy gravel; downtown and campus ones stay paved.
	if terrainMaterial == Enum.Material.Sand and kind ~= "downtown" and kind ~= "campus" then
		return "gravel"
	end
	return "paved"
end

-- What goes in a car park of `kind` (the layouts' options).
local function optionsFor(kind, shop)
	if kind == "paved" then
		return { walk = true, front = true, back = true, band = true, accessible = true, corral = shop }
	elseif kind == "yard" then
		return { band = true, crates = true }
	end
	return { band = true }
end

-- How many bays a town's car park is for: its kind's count (TownKinds `bays.count`), a neighbourhood's
-- (whose cars are on its driveways) no more than MIN_BAYS, within MIN_BAYS..MAX_BAYS.
function ParkingLots.BaysFor(bays)
	bays = bays or {}
	local count = math.floor(tonumber(bays.count) or 6)
	if bays.kind == "driveway" then
		count = math.min(count, MIN_BAYS)
	end
	return math.clamp(count, MIN_BAYS, MAX_BAYS)
end

-- The shapes to try: every layout the kind takes and every row length, the most bays first and, for
-- the same, the preferred layout, then with the front islands, then the shallower. A slot given over
-- to an accessible stall, its hatched bay, a corral or the crates isn't a bay, so `count` is what's
-- left.
local MAX_PER_ROW = 6
local function shapesFor(kind, count, prefer, o)
	local list = {}
	local layouts = { "double" }
	if kind == "paved" then
		layouts = prefer == "angled" and { "angled", "double" } or { "double", "angled" }
	end
	local function add(layout, perRow, oo, order, rank)
		local width, depth
		local spare = 0
		if layout == "double" then
			width, depth = doubleSize(perRow, oo)
			spare = (oo.accessible and 2 or 0) + ((oo.corral or oo.crates) and perRow >= 4 and 1 or 0)
			perRow = perRow
		else
			width, depth = angledSize(perRow, oo)
			spare = oo.accessible and 2 or 0
		end
		local bays = (layout == "double" and 2 * perRow or perRow) - spare
		if bays >= MIN_BAYS and bays <= count + 1 then
			table.insert(list, { layout = layout, perRow = perRow, count = bays, width = width, depth = depth, options = oo, order = order,
				rank = rank })
		end
	end
	for order, layout in ipairs(layouts) do
		if layout == "double" then
			for perRow = 2, MAX_PER_ROW do
				add("double", perRow, o, order, 0)
				if o.front then
					local oo = table.clone(o)
					oo.front = false
					add("double", perRow, oo, order, 1)
				end
			end
		else
			for slots = 5, 8 do
				add("angled", slots, o, order, 0)
			end
		end
	end
	table.sort(list, function(p, q)
		if p.count ~= q.count then
			return p.count > q.count
		end
		if p.order ~= q.order then
			return p.order < q.order
		end
		if p.rank ~= q.rank then
			return p.rank < q.rank
		end
		return p.depth < q.depth
	end)
	return list
end

--------------------------------------------------------------------------------
-- Reserving the plot
--------------------------------------------------------------------------------

-- The frame a car park stands in on `frontage` (a street side of MapGenerator's walk), `along` studs
-- from where its street starts: its middle at the street's own height, local +Z away from the street
-- (as a building's is), local +X along it.
local function frameOn(frontage, along, shape, sidewalk)
	local street = frontage.street
	local direction = street.direction
	local out = Vector3.new(-direction.Z, 0, direction.X) * frontage.side
	local yaw = math.atan2(out.X, out.Z)
	local middle = street.a + direction * (along + shape.width / 2) + out * (street.width / 2 + sidewalk + shape.depth / 2)
	return CFrame.new(middle.X, street.a.Y, middle.Z) * CFrame.Angles(0, yaw, 0), yaw, out
end

-- The first plot along `frontage` where `shape` fits, from the end of its last building (or where the
-- walk left off) to SLIDE further: clear of every claim but its street's own (it stands flush against
-- the back of the pavement), and levelled at the street's own height the way the town's buildings
-- are. Claims it, paints the ground under it, and moves the frontage's cursor and its street's `used`
-- on. Returns the plan, or nil.
local function tryPlot(ctx, frontage, shape, sidewalk)
	local street = frontage.street
	-- Right up against the last building on this side (no alley needed beside a car park), or where the
	-- walk would put the next lot if there is none yet.
	local start = type(frontage.built) == "number" and frontage.built + CLAIM_MARGIN + 0.5 or frontage.cursor
	local along = start
	while along <= start + SLIDE and along + shape.width <= street.length - 4 do
		local frame, yaw, out = frameOn(frontage, along, shape, sidewalk)
		local halfX, halfZ = shape.width / 2 + CLAIM_MARGIN, shape.depth / 2 + CLAIM_MARGIN
		if ctx.rectFree(ctx.space, frame.X, frame.Z, yaw, halfX, halfZ, street.entry) then
			local ok, height = pcall(MapTerrain.FlattenPad, frame, Vector3.new(shape.width, 0, shape.depth),
				{ height = street.a.Y, margin = 1, space = ctx.space })
			if ok and type(height) == "number" then
				ctx.space:AddRect(frame.X, frame.Z, halfX, halfZ, yaw)
				if ctx.paint then
					-- Under the surface, curbs, walkway and islands, not the hedge or fence band: terrain
					-- paint fills whole 4-stud voxels, so anything wider shows as a pale band at the edge.
					local band = shape.options.band and BAND or 0
					local bs = -frontage.side
					local centre = frame * CFrame.new(bs * band / 2, 0, -band / 2)
					ctx.paint(centre.Position, yaw, shape.width - band, shape.depth - band)
				end
				frontage.cursor = along + shape.width + 2 * CLAIM_MARGIN
				street.used = math.max(street.used or 0, along + shape.width)
				return { frame = frame, yaw = yaw, out = out, shape = shape, street = street, along = along,
					sidewalk = sidewalk, height = street.a.Y, side = frontage.side }
			end
		end
		along += SLIDE_STEP
	end
	return nil
end

-- ctx:
--   frontages  MapGenerator's street sides, { street = { a, direction, length, width, primary, entry,
--              used }, side, cursor, built }: `cursor` is where the next lot on that side would start,
--              `built` where its last building's lot ends
--   space, rectFree   the map's MapSpace and MapGenerator's turned-rectangle test
--   sidewalk   the pavement's width (kerb included)
--   profile    the town's TownKinds profile (its kind, bays, name)
--   terrain    the map's ground material (palms, cacti and sandy gravel on sand)
--   paint      function(centre, yaw, sizeX, sizeZ): paints the ground under a footprint the way a
--              building's is (no grass growing up through the surface)
-- Returns the plan Build lays, having levelled and claimed its plot; or nil.
function ParkingLots.Reserve(town, ctx)
	if not town or not ctx or not ctx.space or not ctx.rectFree then
		return nil
	end
	local profile = ctx.profile or {}
	local count = ParkingLots.BaysFor(profile.bays or ctx.bays)
	local sidewalk = ctx.sidewalk or 5
	local kind = ParkingLots.KindFor(profile, ctx.terrain)
	local shop = profile.kind == "downtown" or profile.kind == "market" or profile.kind == "campus"
	-- The main street first (it runs along X out of the square), then the cross street's inner arms,
	-- then any other street of the town (a back street, the cross street past its junction), where a
	-- car park still stands among buildings with a street in front of it; within each, in an order drawn
	-- from the map's seed, so which side of which street varies from town to town, but a street side that
	-- already has its first building before one that has none (a small town doesn't build every side),
	-- so the car park comes after a building rather than alone on a bare corner of the square.
	local groups = { {}, {}, {} }
	for _, frontage in ipairs(ctx.frontages or {}) do
		local street = frontage.street
		local list = not street.primary and groups[3] or (math.abs(street.direction.X) > 0.5 and groups[1] or groups[2])
		table.insert(list, math.random(1, #list + 1), frontage)
	end
	for index, list in ipairs(groups) do
		local ordered = {}
		for _, frontage in ipairs(list) do
			if frontage.built then
				table.insert(ordered, frontage)
			end
		end
		for _, frontage in ipairs(list) do
			if not frontage.built then
				table.insert(ordered, frontage)
			end
		end
		groups[index] = ordered
	end
	local prefer = math.random() < 0.5 and "angled" or "double"
	local wear = 0.06 + math.random() * 0.3

	-- Where it goes matters more than how big it is: a car park of GOOD_BAYS or more (or the town's
	-- whole count, if smaller) on the main street before a bigger one on the cross street, and so on;
	-- then, if none of those fit, any size down to MIN_BAYS on any street.
	local good = math.min(count, GOOD_BAYS)
	local all = {}
	local tiers = {}
	for _, list in ipairs(groups) do
		table.insert(tiers, { frontages = list, least = good })
		for _, frontage in ipairs(list) do
			table.insert(all, frontage)
		end
	end
	table.insert(tiers, { frontages = all, least = MIN_BAYS })
	local shapes = shapesFor(kind, count, prefer, optionsFor(kind, shop))

	for _, tier in ipairs(tiers) do
		for _, shape in ipairs(shapes) do
			if shape.count >= tier.least then
				for _, frontage in ipairs(tier.frontages) do
					local plan = tryPlot(ctx, frontage, shape, sidewalk)
					if plan then
						plan.kind, plan.wear, plan.terrain = kind, wear, ctx.terrain
						return plan
					end
				end
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Laying it
--------------------------------------------------------------------------------

-- A way in: the street's kerb dropped and its pavement cut across the opening, and an apron of the
-- car park's own surface from the dropped kerb through the gap, flush with both.
local function wayIn(town, lot, plan, opening, space)
	local sidewalk = plan.sidewalk
	local pavement = sidewalk - CURB
	local width = opening.x1 - opening.x0
	local D = plan.shape.depth
	local mouth = lot.base * CFrame.new((opening.x0 + opening.x1) / 2, 0, -D / 2)
	MapDecor.DropKerb(town, mouth.Position - plan.out * (sidewalk - CURB / 2), plan.out, width / 2, 1)
	MapDecor.CutPavement(town, mouth.Position - plan.out * (pavement / 2), plan.out, width / 2, 1)
	box(lot, "LotApron", opening.x0, opening.x1, 0, LIFT, -D / 2 - pavement, -D / 2 + CURB, lot.surfaceColor, lot.surfaceMaterial,
		{ group = lot.surfaceGroup })
	-- Kept clear from the car park's edge out into the near lane (9 studs), a stud wider than the way
	-- in each side, as a driveway's mouth is (MapDecor.Driveways).
	if space then
		local reach = sidewalk + 9
		local centre = mouth.Position - plan.out * (reach / 2)
		space:AddRect(centre.X, centre.Z, width / 2 + 1, reach / 2, plan.yaw)
	end
end

local function isStall(slot)
	return slot and (slot.kind == "bay" or slot.kind == "accessible")
end

-- The car park on its plot. Returns how many bays it has.
function ParkingLots.Build(town, plan, space)
	if not town or not plan then
		return 0
	end
	local shape = plan.shape
	local o = shape.options
	local bs = -(plan.side or 1)
	local kind = plan.kind or "paved"
	local sand = plan.terrain == Enum.Material.Sand
	local surfaceColor, surfaceMaterial = surfaceOf(kind, sand)
	-- Each car park's own tone, a touch lighter or darker.
	surfaceColor = surfaceColor:Lerp(math.random() < 0.5 and Color3.new(1, 1, 1) or Color3.new(0, 0, 0), math.random() * 0.05)

	local model = Instance.new("Model")
	model.Name = "ParkingLot"
	model:SetAttribute("Kind", kind)
	model:SetAttribute("Layout", shape.layout)
	model.Parent = town
	local lot = {
		model = model, base = plan.frame, parts = 0, kind = kind, terrain = plan.terrain, wear = plan.wear or 0.15,
		surfaceColor = surfaceColor, surfaceMaterial = surfaceMaterial, surfaceGroup = newGroup("LotSurface"),
	}
	local g = shape.layout == "angled" and angledLayout(shape, bs, o) or doubleLayout(shape, bs, o)

	-- The surface, on the ground.
	box(lot, "LotSurface", g.slab[1], g.slab[2], 0, LIFT, g.slab[3], g.slab[4], surfaceColor, surfaceMaterial, { group = lot.surfaceGroup })

	-- The edge: raised concrete curbs, or timber edging round a gravel yard.
	for _, r in ipairs(g.curbs) do
		if kind == "gravel" then
			box(lot, "TimberEdging", r[1], r[2], -SINK, LIFT + 0.25, r[3], r[4], TIMBER, Enum.Material.WoodPlanks)
		else
			box(lot, "LotCurb", r[1], r[2], -SINK, CURB_TOP, r[3], r[4], CONCRETE, Enum.Material.Concrete)
		end
	end
	if g.walkway then
		-- The walkway, at the curb's height, coming down to the pavement's over its first two studs so it
		-- meets the street's pavement without a step: a riser and a ramp on it.
		local w = g.walkway
		local pavementTop = MapDecor.PavementTop or 0.35
		box(lot, "Walkway", w[1], w[2], -SINK, CURB_TOP, w[3] + 2, w[4], CONCRETE_LIGHT, Enum.Material.Concrete)
		box(lot, "Walkway", w[1], w[2], -SINK, pavementTop, w[3], w[3] + 2, CONCRETE_LIGHT, Enum.Material.Concrete)
		local ramp = Instance.new("WedgePart")
		ramp.Name = "WalkwayRamp"
		ramp.Anchored, ramp.CanCollide, ramp.CanQuery, ramp.CanTouch = true, false, false, false
		ramp.CastShadow = false
		-- A wedge is tall at its +Z end: that end into the car park (+z), low at the street.
		ramp.Size = Vector3.new(w[2] - w[1], CURB_TOP - pavementTop, 2)
		ramp.CFrame = lot.base * CFrame.new((w[1] + w[2]) / 2, (pavementTop + CURB_TOP) / 2, w[3] + 1)
		ramp.Color = CONCRETE_LIGHT
		ramp.Material = Enum.Material.Concrete
		ramp.TopSurface, ramp.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		ramp.Parent = model
		lot.parts += 1
	end

	for _, opening in ipairs(g.openings) do
		wayIn(town, lot, plan, opening, space)
	end

	-- Islands, what grows on them, and the lights that stand on them (paved lots).
	if kind == "paved" then
		for _, r in ipairs(g.islands) do
			local group = island(lot, r)
			if group then
				local cx, cz = (r[1] + r[2]) / 2, (r[3] + r[4]) / 2
				if r.strip then
					local span = r[2] - r[1]
					local count = math.max(2, math.floor(span / 14))
					for index = 1, count do
						islandShrub(lot, r[1] + (index - 0.5) * span / count, cz, SOIL_TOP, group)
					end
				elseif r.plant == "tree" then
					-- The tree at the island's far end from the aisle; the light at the aisle's end.
					local toward = r.aisleX and (r.aisleX < cx and -1 or 1) or 0
					islandTree(lot, cx - toward * math.max(0, (r[2] - r[1]) / 2 - 4), cz, SOIL_TOP, group)
				else
					islandShrub(lot, cx, cz, SOIL_TOP, group)
				end
			end
			if r.lamp then
				local cz = (r[3] + r[4]) / 2
				if r.strip then
					for _, f in ipairs({ 0.25, 0.75 }) do
						local x = r[1] + (r[2] - r[1]) * f + 3
						lightPole(lot, x, cz, SOIL_TOP, { x, cz + 10 })
					end
				else
					local x = r.aisleX < (r[1] + r[2]) / 2 and r[1] + 2.2 or r[2] - 2.2
					lightPole(lot, x, cz, SOIL_TOP, { r.aisleX, cz - 7 })
				end
			end
		end
	elseif kind == "yard" then
		-- A floodlight on the curb's back corner away from the building, over the apron.
		local x = bs < 0 and g.slab[2] + CURB / 2 or g.slab[1] - CURB / 2
		lightPole(lot, x, g.slab[4] + CURB / 2, CURB_TOP, { (g.slab[1] + g.slab[2]) / 2, (g.slab[3] + g.slab[4]) / 2 }, 22)
	end

	-- Stalls: side lines (once per boundary, so neighbours never paint the same line twice), wheel
	-- stops, oil stains; the accessible stall, the hatched bay, a corral, crates.
	local style = kind == "paved" and "hairpin" or (kind == "yard" and "single" or nil)
	local rows = {}
	for _, slot in ipairs(g.slots) do
		rows[slot.row] = rows[slot.row] or {}
		rows[slot.row][slot.index] = slot
	end
	-- A boundary is half way between two neighbours' middles (on their shared side, an angled row's
	-- stalls being staggered along it), or half a step past the row's end: every line then ends on the
	-- same two lines parallel to the aisle, so an angled row's stalls are painted as parallelograms.
	for _, row in pairs(rows) do
		local n = #row
		local stepX, stepZ = row[2].x - row[1].x, row[2].z - row[1].z
		for k = 0, n do
			local before, after = row[k], row[k + 1]
			if style and (isStall(before) or isStall(after)) then
				local s = after or before
				local px, pz
				if before and after then
					px, pz = (before.x + after.x) / 2, (before.z + after.z) / 2
				elseif after then
					px, pz = after.x - stepX / 2, after.z - stepZ / 2
				else
					px, pz = before.x + stepX / 2, before.z + stepZ / 2
				end
				sideLine(lot, px, pz, s.nx, s.nz, BAY.length, style)
			end
		end
	end
	local bays, accessible = {}, {}
	for _, slot in ipairs(g.slots) do
		if isStall(slot) then
			wheelStop(lot, slot, 1.5)
		end
		if slot.kind == "accessible" then
			accessibleStall(lot, slot)
			table.insert(accessible, slot)
		elseif slot.kind == "hatch" then
			hatchedBay(lot, slot)
		elseif slot.kind == "corral" then
			cartCorral(lot, slot)
		elseif slot.kind == "crates" then
			local group = newGroup("Crates")
			local cx, cz = slot.x + slot.nx * 2, slot.z
			local crate = Color3.fromRGB(150, 112, 70)
			local c = { collide = true, group = group, shadow = true }
			box(lot, "Crate", cx - 2.2, cx + 2.2, LIFT - 0.1, LIFT + 4.4, cz - 4.4, cz, crate, Enum.Material.WoodPlanks, c)
			box(lot, "Crate", cx - 2, cx + 2.4, LIFT - 0.1, LIFT + 4.2, cz + 0.3, cz + 4.7, crate:Lerp(Color3.new(0, 0, 0), 0.1), Enum.Material.WoodPlanks, c)
			box(lot, "Crate", cx - 1.8, cx + 1.8, LIFT + 4.4, LIFT + 8, cz - 4, cz - 0.4, crate:Lerp(Color3.new(1, 1, 1), 0.08), Enum.Material.WoodPlanks, c)
		elseif slot.kind == "bay" then
			table.insert(bays, slot)
			-- An oil stain under where the engine sits, in about half the stalls.
			if kind ~= "gravel" and math.random() < 0.5 then
				disc(lot, "OilStain", slot.x + slot.nx * 3.4, slot.z + slot.nz * 3.4, LIFT, LIFT + MARK, 2.6 + math.random() * 1.4,
					Color3.fromRGB(30, 30, 32), Enum.Material.SmoothPlastic, { transparency = 0.45, group = lot.surfaceGroup })
			end
		end
	end

	-- The aisle's paint: arrows, the stop bar and the crossing on paved lots, with a drain and patches;
	-- tyre tracks in gravel; the concrete's joints in a yard.
	if kind == "paved" then
		for _, a in ipairs(g.arrows) do
			arrow(lot, a.x, a.z, a.dx, a.dz, a.size)
		end
		for _, bar in ipairs(g.stopBars) do
			paint(lot, "StopBar", bar[1], bar[2], bar[3], bar[4], 0.9)
		end
		if g.crossing then
			local c = g.crossing
			local stripes = math.max(3, math.floor((c[2] - c[1] - 1) / 2.3))
			for index = 0, stripes - 1 do
				local x = c[1] + 1.2 + index * ((c[2] - c[1]) - 2.4) / math.max(1, stripes - 1)
				paint(lot, "CrossingStripe", x, c[3], x, c[4], 1.1)
			end
		end
		box(lot, "DrainGrate", g.drain[1] - 1, g.drain[1] + 1, LIFT, LIFT + MARK, g.drain[2] - 1, g.drain[2] + 1, Color3.fromRGB(46, 46, 48),
			Enum.Material.DiamondPlate, { group = lot.surfaceGroup })
		for _, p in ipairs(g.patches) do
			if math.random() < 0.75 then
				local w, d = 3 + math.random() * 2, 2.5 + math.random() * 1.5
				box(lot, "AsphaltPatch", p[1] - w / 2, p[1] + w / 2, LIFT, LIFT + MARK, p[2] - d / 2, p[2] + d / 2,
					surfaceColor:Lerp(Color3.new(0, 0, 0), 0.2), surfaceMaterial, { group = lot.surfaceGroup })
			end
		end
	elseif kind == "gravel" then
		-- Tyre tracks worn in from the way in down the aisle: a pair for each lane.
		local a = g.aisle
		for _, lane in ipairs({ -3.4, 3.4 }) do
			for _, wheel in ipairs({ -1.9, 1.9 }) do
				local x = a.ax + lane + wheel
				strip(lot, "TyreTrack", x, g.slab[3] + 0.5, x, g.slab[4] - 2, 0.9, LIFT, LIFT + MARK, surfaceColor:Lerp(Color3.new(0, 0, 0), 0.25),
					Enum.Material.Ground, { transparency = 0.35, group = lot.surfaceGroup })
			end
		end
	elseif kind == "yard" then
		for z = g.slab[3] + 12, g.slab[4] - 2, 12 do
			strip(lot, "ExpansionJoint", g.aisle.x0 + 0.4, z, g.aisle.x1 - 0.4, z, 0.18, LIFT, LIFT + MARK, Color3.fromRGB(110, 108, 102),
				Enum.Material.Concrete, { group = lot.surfaceGroup })
		end
	end

	-- A hedge (paved) or a fence (post-and-rail in gravel, chain-link at a yard) where it meets yards.
	for _, band in ipairs(g.bands or {}) do
		local x0, x1, z0, z1 = band[1], band[2], band[3], band[4]
		if kind == "paved" then
			local length = band.along == "x" and (x1 - x0) or (z1 - z0)
			local pieces = math.max(1, math.ceil(length / 16))
			for index = 1, pieces do
				local a0 = (index - 1) * length / pieces + 0.2
				local a1 = index * length / pieces - 0.2
				local group = newGroup("Hedge")
				local h = { collide = true, group = group, shadow = true }
				if band.along == "x" then
					box(lot, "Hedge", x0 + a0, x0 + a1, -0.2, 3.2, z0 + 0.15, z1 - 0.15, HEDGE, Enum.Material.LeafyGrass, h)
				else
					box(lot, "Hedge", x0 + 0.15, x1 - 0.15, -0.2, 3.2, z0 + a0, z0 + a1, HEDGE, Enum.Material.LeafyGrass, h)
				end
			end
		else
			local group = newGroup("Fence")
			local chain = kind == "yard"
			local height = chain and 7 or 3.4
			local mx, mz = (x0 + x1) / 2, (z0 + z1) / 2
			local ax0, az0, ax1, az1
			if band.along == "x" then
				ax0, az0, ax1, az1 = x0 + 0.3, mz, x1 - 0.3, mz
			else
				ax0, az0, ax1, az1 = mx, z0 + 0.3, mx, z1 - 0.3
			end
			local length = math.sqrt((ax1 - ax0) ^ 2 + (az1 - az0) ^ 2)
			local posts = math.max(2, math.floor(length / (chain and 10 or 8)) + 1)
			local f = { collide = true, group = group }
			for index = 0, posts - 1 do
				local t = index / (posts - 1)
				post(lot, "FencePost", ax0 + (ax1 - ax0) * t, az0 + (az1 - az0) * t, -0.4, height + 0.4, chain and 0.35 or 0.55,
					chain and METAL_DARK or TIMBER_DARK, chain and Enum.Material.Metal or Enum.Material.Wood, f)
			end
			if chain then
				strip(lot, "FenceMesh", ax0, az0, ax1, az1, 0.12, 0.2, height - 0.3, Color3.fromRGB(120, 124, 128), Enum.Material.DiamondPlate,
					{ collide = true, transparency = 0.72, group = group })
				strip(lot, "FenceRail", ax0, az0, ax1, az1, 0.25, height - 0.3, height, METAL_DARK, Enum.Material.Metal, { group = group })
			else
				for _, h in ipairs({ 1.3, 2.6 }) do
					strip(lot, "FenceRail", ax0, az0, ax1, az1, 0.3, h - 0.2, h + 0.2, TIMBER, Enum.Material.Wood, f)
				end
			end
		end
	end

	-- The walkway's bollards, pay machine and bin.
	for _, b in ipairs(g.bollards) do
		local group = newGroup("Bollard")
		post(lot, "Bollard", b[1], b[2], CURB_TOP - 0.2, 3.2, 0.7, Color3.fromRGB(60, 62, 66), Enum.Material.Metal, { collide = true, group = group })
		post(lot, "BollardBand", b[1], b[2], CURB_TOP + 2.2, 0.4, 0.76, YELLOW, Enum.Material.SmoothPlastic, { group = group })
	end
	if g.payAt and shape.count >= 6 then
		payMachine(lot, g.payAt[1], g.payAt[2], CURB_TOP, bs < 0 and 1 or -1, 0)
	end
	if g.binAt then
		local group = newGroup("Bin")
		post(lot, "Bin", g.binAt[1], g.binAt[2], CURB_TOP - 0.1, 3.3, 2.2, Color3.fromRGB(54, 92, 64), Enum.Material.Metal, { collide = true, group = group })
		post(lot, "BinLid", g.binAt[1], g.binAt[2], CURB_TOP + 3.2, 0.3, 2.5, Color3.fromRGB(40, 70, 48), Enum.Material.Metal, { group = group })
	end

	-- A yard's gate: a barrier arm, raised, on its post beside the way in.
	if kind == "yard" then
		local o1 = g.openings[1]
		local gx = bs < 0 and o1.x1 + 1.3 or o1.x0 - 1.3
		local group = newGroup("Barrier")
		local zf = -shape.depth / 2
		-- On the front curb, clear of the first stall behind it.
		box(lot, "BarrierPost", gx - 0.6, gx + 0.6, -0.2, 3.8, zf + 0.05, zf + CURB - 0.05, YELLOW, Enum.Material.Metal, { collide = true, group = group })
		local pivot = (lot.base * CFrame.new(gx, 3.4, zf + CURB / 2)).Position
		local toward = lot.base:VectorToWorldSpace(Vector3.new(bs < 0 and -1 or 1, 3.2, 0).Unit)
		part(lot, "BarrierArm", Vector3.new(0.35, 0.35, 11), CFrame.lookAt(pivot + toward * 5.5, pivot + toward * 11), Color3.fromRGB(220, 50, 44),
			Enum.Material.SmoothPlastic, { group = group })
	end

	-- The board's two posts stand either side of its middle: two studs further from the way in.
	local signX = g.signAt[1]
	if kind == "gravel" then
		local nearest = g.openings[1]
		for _, opening in ipairs(g.openings) do
			if math.abs((opening.x0 + opening.x1) / 2 - signX) < math.abs((nearest.x0 + nearest.x1) / 2 - signX) then
				nearest = opening
			end
		end
		signX += (signX > (nearest.x0 + nearest.x1) / 2) and 2 or -2
	end
	parkingSign(lot, signX, g.signAt[2], kind == "gravel" and LIFT + 0.25 or CURB_TOP, kind == "gravel")

	-- The bays, numbered from the building's end (where people walk to) back.
	local function key(slot)
		return math.abs(slot.x - g.walkX) * 0.3 + (slot.z - g.zf)
	end
	table.sort(bays, function(p, q)
		return key(p) < key(q)
	end)
	local function frameOf(slot)
		local centre = (lot.base * CFrame.new(slot.x, LIFT, slot.z)).Position
		return CFrame.lookAt(centre, centre + lot.base:VectorToWorldSpace(Vector3.new(slot.nx, 0, slot.nz)))
	end
	local number = {}
	for index, slot in ipairs(bays) do
		number[slot] = index
		town:SetAttribute("ParkingBay_" .. index, frameOf(slot))
	end
	for index, slot in ipairs(bays) do
		local neighbour = rows[slot.row][slot.index + 1]
		if neighbour and number[neighbour] then
			town:SetAttribute("ParkingBayNext_" .. index, number[neighbour])
		end
	end
	town:SetAttribute("ParkingBays", #bays)
	town:SetAttribute("ParkingKind", kind)
	town:SetAttribute("ParkingBaySize", Vector3.new(BAY.width, 1, BAY.length))
	town:SetAttribute("ParkingAccessible", #accessible)
	for index, slot in ipairs(accessible) do
		town:SetAttribute("ParkingAccessible_" .. index, frameOf(slot))
	end
	local a = g.aisle
	model:SetAttribute("AisleA", (lot.base * CFrame.new(a.ax, LIFT, a.az)).Position)
	model:SetAttribute("AisleB", (lot.base * CFrame.new(a.bx, LIFT, a.bz)).Position)
	model:SetAttribute("AisleWidth", a.width)
	model:SetAttribute("Parts", lot.parts)
	return #bays
end

-- How full each of a map's car parks is (Oliver 09-24: "the parking lots don't all need to be full"),
-- dealt once every town is built, from the map's seed. Drawn independently, six car parks can all come
-- out a fifth full (one map in fifty) or all half full, and a map reads the same everywhere; so the
-- draws are stratified: with n car parks, one draw from each n-th of 0..1, dealt to the towns in a
-- shuffled order. Every map with a few car parks then has a nearly empty one, a busy one and the rest
-- between, and which town gets which changes from map to map. Sets ParkingFill on each town with bays.
function ParkingLots.DealFills(towns)
	local lots = {}
	for _, town in ipairs(towns or {}) do
		if (tonumber(town:GetAttribute("ParkingBays")) or 0) > 0 then
			table.insert(lots, town)
		end
	end
	local order = {}
	for index = 1, #lots do
		table.insert(order, math.random(1, #order + 1), index)
	end
	for index, town in ipairs(lots) do
		local u = (order[index] - 1 + math.random()) / #lots
		town:SetAttribute("ParkingFill", FILL_MIN + (FILL_MAX - FILL_MIN) * u ^ FILL_SKEW)
	end
	return #lots
end

return ParkingLots
