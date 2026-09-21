-- Town kinds (#32): what kind of place each of the eighteen town names is, as DATA. A town used to be
-- the same square, the same four streets and the same three building shapes whatever its name, with
-- only the theme's set piece and props to tell them apart. Now every name has a KIND — neighbourhood,
-- industrial, downtown, market, rural, campus, harbour — and a profile that says how its streets, its
-- lots, its buildings, its district block and its parking differ from the default town.
--
-- Two things read this and nothing else does:
--   MapGenerator.buildTown  (claude-79's reader)  street lengths, back streets, setback, alleys,
--                                                 building count, the yard block, crates, furniture,
--                                                 the plan handed to MapBuildings.RollPlan
--   TownThemes              (this tab)            the yard, lot and verge builders and where the
--                                                 parking bays go
--
-- The names are dealt to towns at random per match (MapDecor.ShuffledTownNames), on whichever map
-- is being built, so nothing here may depend on a map: a kind must build on grass, sand, rock, earth
-- and farmland alike. The material palette is the one thing that follows the map, through
-- `plan.palette`, which MapBuildings falls back from to the map preset's own.
--
-- CONSTRAINTS (agreed with the roads tab; the reader asserts and clamps them, and logs the clamp):
--   * mainReach / crossReach are never above 1.0: the footprint handed to the road planner
--     (townShape: half, cross, zext) is what keeps roads off a town, and a town that grows past it
--     gets a road through its yard.
--   * the yard sits inside zext: its depth is at most YARD_MAX_DEPTH, beyond the back street's
--     outer pavement, beside the outer cross street (which runs on past the back-street junction).
--   * nothing goes inside CENTRE_RESERVE of TownCenter (the square today; the roundabout to come).
--   * every field is optional; a name that leaves one unset gets the default town's value, so a
--     profile of {} is exactly today's town.
--
-- TownKinds.For(name) returns a COMPLETE profile (defaults filled in) and never nil: an unknown name
-- is the default town with kind "town".

local TownKinds = {}

-- Radius round the town centre that nothing themed may enter: 25 is today's square (PLAZA_HALF);
-- the roundabout, when it lands, reserves 45. Set to 45 now so nothing has to move later.
TownKinds.CENTRE_RESERVE = 45
-- The deepest yard block that still sits inside a town's footprint (zext - the back street's outer
-- pavement - 2): see MapGenerator.townShape.
TownKinds.YARD_MAX_DEPTH = 54
-- The widest yard: the back street runs 0.8 * half from the centre and the smallest map's half is
-- 169, so a 96-wide block beside the cross street (16 + 96 = 112) fits every map with room to spare.
TownKinds.YARD_MAX_WIDTH = 96

-- A parking bay, sized for the largest vehicle (the CrocodiloRanger, 14.6 long x 6.9 wide; the
-- vehicles tab's number) plus a stud of clearance each side. `length` runs along the bay's
-- LookVector (the parked car's nose), `width` across. One size for every bay in the game, so
-- VehicleService.ParkInTowns has one number (it refuses a bay not level within half a stud).
TownKinds.Bay = { width = 8.9, length = 16.6 }

--------------------------------------------------------------------------------
-- Palettes: wall materials and colours per kind, standing in for the map preset's where set.
--------------------------------------------------------------------------------

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local PALETTES = {
	-- Greys, moss and rust: sheds and works.
	industrial = {
		wallMaterials = { Enum.Material.Concrete, Enum.Material.CorrodedMetal, Enum.Material.Metal },
		wallColors = { rgb(128, 130, 126), rgb(96, 102, 98), rgb(112, 96, 82), rgb(84, 92, 84) },
		roofMaterial = Enum.Material.CorrodedMetal,
		roofColors = { rgb(90, 84, 78), rgb(70, 74, 72) },
	},
	-- Warm brick and red oxide: goods yards and engine sheds.
	rail = {
		wallMaterials = { Enum.Material.Brick, Enum.Material.Concrete, Enum.Material.CorrodedMetal },
		wallColors = { rgb(140, 84, 66), rgb(122, 74, 60), rgb(150, 140, 128), rgb(104, 68, 56) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(70, 66, 64), rgb(96, 60, 52) },
	},
	-- Site grey with safety orange.
	construction = {
		wallMaterials = { Enum.Material.Concrete, Enum.Material.Metal, Enum.Material.Brick },
		wallColors = { rgb(150, 150, 146), rgb(120, 120, 118), rgb(232, 120, 40), rgb(160, 130, 110) },
		roofMaterial = Enum.Material.Concrete,
		roofColors = { rgb(90, 90, 92), rgb(232, 120, 40) },
	},
	-- One pale wall, one roof: the copy-paste suburb picks ONE of each per town (see NPC Nook).
	uniform = {
		wallMaterials = { Enum.Material.SmoothPlastic },
		wallColors = { rgb(214, 208, 190) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(84, 88, 100) },
	},
	-- Pastels for the manicured and the dreamy.
	pastel = {
		wallMaterials = { Enum.Material.SmoothPlastic, Enum.Material.Brick, Enum.Material.WoodPlanks },
		wallColors = { rgb(236, 214, 226), rgb(212, 226, 240), rgb(226, 236, 214), rgb(244, 232, 206) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(120, 96, 112), rgb(96, 110, 130) },
	},
	-- Sweet-shop stripes: pink, lilac and mint walls under candy roofs.
	candy = {
		wallMaterials = { Enum.Material.SmoothPlastic, Enum.Material.SmoothPlastic, Enum.Material.WoodPlanks },
		wallColors = { rgb(255, 196, 220), rgb(214, 190, 255), rgb(190, 240, 214), rgb(255, 236, 200) },
		roofMaterial = Enum.Material.SmoothPlastic,
		roofColors = { rgb(226, 80, 120), rgb(255, 255, 255) },
	},
	-- Limestone, white and gold trim: money.
	upscale = {
		wallMaterials = { Enum.Material.Limestone, Enum.Material.Marble, Enum.Material.Concrete },
		wallColors = { rgb(232, 226, 210), rgb(244, 240, 232), rgb(212, 204, 186), rgb(226, 214, 190) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(62, 66, 74), rgb(84, 74, 60) },
	},
	-- Plain beige and brown: nothing to look at, on purpose.
	plain = {
		wallMaterials = { Enum.Material.WoodPlanks, Enum.Material.Concrete },
		wallColors = { rgb(196, 176, 140), rgb(176, 160, 132), rgb(160, 130, 100) },
		roofMaterial = Enum.Material.WoodPlanks,
		roofColors = { rgb(110, 84, 60), rgb(96, 76, 58) },
	},
	-- Cool greys and glass blue: the business district.
	corporate = {
		wallMaterials = { Enum.Material.Concrete, Enum.Material.Glass, Enum.Material.Metal },
		wallColors = { rgb(150, 156, 172), rgb(118, 126, 146), rgb(96, 120, 150), rgb(176, 180, 190) },
		roofMaterial = Enum.Material.Concrete,
		roofColors = { rgb(70, 74, 86), rgb(56, 60, 72) },
	},
	-- Civic stone.
	civic = {
		wallMaterials = { Enum.Material.Limestone, Enum.Material.Concrete, Enum.Material.Marble },
		wallColors = { rgb(176, 168, 150), rgb(150, 146, 136), rgb(196, 188, 170), rgb(132, 128, 120) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(66, 70, 78), rgb(84, 82, 78) },
	},
	-- Brick and cream: the old town.
	oldTown = {
		wallMaterials = { Enum.Material.Brick, Enum.Material.Cobblestone, Enum.Material.WoodPlanks },
		wallColors = { rgb(150, 88, 66), rgb(226, 214, 186), rgb(172, 124, 104), rgb(196, 176, 150) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(96, 60, 52), rgb(70, 74, 78) },
	},
	-- Bright primaries for the small musical village.
	village = {
		wallMaterials = { Enum.Material.WoodPlanks, Enum.Material.SmoothPlastic, Enum.Material.Brick },
		wallColors = { rgb(226, 96, 80), rgb(96, 150, 210), rgb(240, 200, 70), rgb(110, 176, 96) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(60, 56, 64), rgb(120, 60, 50) },
	},
	-- Ochre and sandstone.
	oasis = {
		wallMaterials = { Enum.Material.Sandstone, Enum.Material.Sandstone, Enum.Material.Concrete },
		wallColors = { rgb(224, 190, 140), rgb(206, 170, 120), rgb(236, 210, 170), rgb(190, 150, 100) },
		roofMaterial = Enum.Material.WoodPlanks,
		roofColors = { rgb(150, 104, 76), rgb(196, 160, 110) },
	},
	-- Barn red and whitewash.
	farm = {
		wallMaterials = { Enum.Material.WoodPlanks, Enum.Material.Wood, Enum.Material.Brick },
		wallColors = { rgb(150, 56, 48), rgb(236, 230, 214), rgb(172, 126, 92), rgb(120, 48, 40) },
		roofMaterial = Enum.Material.CorrodedMetal,
		roofColors = { rgb(96, 70, 60), rgb(118, 62, 54) },
	},
	-- Old stone and cobbles: the mill town.
	ruin = {
		wallMaterials = { Enum.Material.Cobblestone, Enum.Material.Slate, Enum.Material.Limestone },
		wallColors = { rgb(140, 132, 124), rgb(128, 118, 110), rgb(160, 150, 136), rgb(112, 106, 102) },
		roofMaterial = Enum.Material.Slate,
		roofColors = { rgb(70, 74, 78), rgb(88, 82, 78) },
	},
	-- White and racing red.
	sport = {
		wallMaterials = { Enum.Material.Concrete, Enum.Material.SmoothPlastic, Enum.Material.Metal },
		wallColors = { rgb(240, 238, 232), rgb(216, 216, 214), rgb(178, 62, 50), rgb(200, 200, 204) },
		roofMaterial = Enum.Material.Concrete,
		roofColors = { rgb(178, 62, 50), rgb(84, 88, 100) },
	},
	-- Blue-grey and white: the quay.
	harbour = {
		wallMaterials = { Enum.Material.WoodPlanks, Enum.Material.Concrete, Enum.Material.Brick },
		wallColors = { rgb(120, 140, 160), rgb(236, 236, 230), rgb(90, 110, 130), rgb(176, 186, 196) },
		roofMaterial = Enum.Material.CorrodedMetal,
		roofColors = { rgb(60, 70, 84), rgb(150, 56, 48) },
	},
}
TownKinds.Palettes = PALETTES

--------------------------------------------------------------------------------
-- The default town: MapGenerator.buildTown's constants, so a {} profile changes nothing.
--------------------------------------------------------------------------------

local DEFAULTS = {
	kind = "town",
	-- Multipliers on the planned length of the main street (out of the square along X) and the
	-- cross street (along Z). 1.0 = as far as townShape allows; never above 1.0.
	mainReach = 1.0,
	crossReach = 1.0,
	-- The two back streets parallel to the main street, with their junctions on the cross street.
	backStreets = true,
	-- The back streets' width (the main and cross streets stay 18: roads butt them).
	sideStreetWidth = 14,
	-- Pavement's outer edge to a building's front wall.
	setback = 2,
	-- The gap after each building, by how far along its street it stands: near the square (under 70
	-- on a street out of the square), mid (under 140), far.
	alley = { near = { 0, 2 }, mid = { 2, 6 }, far = { 5, 10 } },
	-- Multiplier on the preset's buildingsPerTown roll (the +3 stays).
	buildings = 1.0,
	-- Handed straight to MapBuildings.RollPlan(downtown, plan): archetype weights, size ranges, the
	-- palette, signs. Empty = today's rolls.
	plan = {},
	-- The district block: nil = none. { width, depth, side = "N" | "S" | nil (the reader picks) }.
	yard = nil,
	-- Multiplier on the back-yard crates and barrels.
	crates = 1.0,
	-- MapDecor.Town's furniture counts.
	furniture = { lamps = 6, benches = 4, bins = 3, cars = 4, hydrants = 2, planters = 3 },
	-- Closed back-street ends get a turning circle.
	culDeSac = false,
	-- The square's statue: nil = today's 60% roll, true = always, false = never.
	statue = nil,
	-- Where this kind's cars belong (read by TownThemes' builders, which write the ParkingBays
	-- attributes): "yard" (bays marked out in the district block), "driveway" (one per house, off
	-- the setback, needing setback >= 14 and houses <= 30 deep), "carpark" (a painted lot in the
	-- yard), "gravel" (a gravel park at the yard's edge), "quay" (the quay's landward edge).
	bays = { kind = "yard", count = 6 },
	-- A short line for the HUD, the reader's log and the probe.
	blurb = "a town",
}
TownKinds.Defaults = DEFAULTS

-- Shorthands for the building plans. Weights are {tower, house, warehouse} for lots near the square
-- and for the rest; sizes are {min, max} per dimension.
local function weights(nearTower, nearHouse, nearWarehouse, farTower, farHouse, farWarehouse)
	return {
		downtown = { tower = nearTower, house = nearHouse, warehouse = nearWarehouse },
		edge = { tower = farTower, house = farHouse, warehouse = farWarehouse },
	}
end

--------------------------------------------------------------------------------
-- The seven kinds. A name's profile starts from its kind and overrides what it likes.
--------------------------------------------------------------------------------

local KINDS = {
	-- Gardens, fences, driveways, wide gaps, low roofs. Cars in driveways.
	neighbourhood = {
		kind = "neighbourhood",
		sideStreetWidth = 10,
		setback = 14,
		alley = { near = { 8, 12 }, mid = { 8, 14 }, far = { 10, 14 } },
		buildings = 1.2,
		plan = { weights = weights(0.05, 0.95, 0.0, 0.0, 1.0, 0.0), sizes = { house = { width = { 24, 30 }, depth = { 24, 30 }, floors = { 1, 2 } } } },
		yard = { width = 70, depth = 46 },
		crates = 0,
		furniture = { lamps = 4, benches = 2, bins = 2, cars = 0, hydrants = 1, planters = 0 },
		culDeSac = true,
		statue = false,
		bays = { kind = "driveway", count = 8 },
	},
	-- Sheds, tanks, chimneys, chain-link, wide estate roads, a loading yard. Cars in the yard.
	industrial = {
		kind = "industrial",
		sideStreetWidth = 18,
		setback = 6,
		alley = { near = { 6, 10 }, mid = { 10, 16 }, far = { 12, 20 } },
		buildings = 0.8,
		plan = { weights = weights(0.1, 0.1, 0.8, 0.05, 0.15, 0.8), palette = PALETTES.industrial, sign = { text = "UNIT" } },
		yard = { width = 84, depth = 52 },
		crates = 2.0,
		furniture = { lamps = 4, benches = 0, bins = 6, cars = 0, hydrants = 2, planters = 0 },
		statue = false,
		bays = { kind = "yard", count = 6 },
	},
	-- Terraces shoulder to shoulder, towers, shopfronts, a car park block.
	downtown = {
		kind = "downtown",
		setback = 3,
		alley = { near = { 0, 2 }, mid = { 0, 3 }, far = { 2, 5 } },
		buildings = 1.2,
		plan = { weights = weights(0.7, 0.1, 0.2, 0.4, 0.3, 0.3), sizes = { tower = { floors = { 3, 5 } } } },
		yard = { width = 84, depth = 50 },
		crates = 0.5,
		furniture = { lamps = 8, benches = 4, bins = 4, cars = 0, hydrants = 2, planters = 6 },
		bays = { kind = "carpark", count = 10 },
	},
	-- Cobbles, stalls, bunting, a market block, a gravel park at its edge.
	market = {
		kind = "market",
		sideStreetWidth = 12,
		setback = 2,
		alley = { near = { 0, 2 }, mid = { 2, 6 }, far = { 4, 8 } },
		plan = { weights = weights(0.3, 0.6, 0.1, 0.1, 0.7, 0.2), palette = PALETTES.oldTown },
		yard = { width = 70, depth = 46 },
		crates = 1.0,
		furniture = { lamps = 6, benches = 6, bins = 3, cars = 0, hydrants = 1, planters = 4 },
		statue = true,
		bays = { kind = "gravel", count = 6 },
	},
	-- Few buildings, wide gaps, fences, a farmyard block; the barn yard for the cars.
	rural = {
		kind = "rural",
		crossReach = 0.85,
		backStreets = false,
		setback = 8,
		alley = { near = { 10, 16 }, mid = { 10, 18 }, far = { 12, 18 } },
		buildings = 0.7,
		plan = { weights = weights(0.0, 0.6, 0.4, 0.0, 0.6, 0.4), palette = PALETTES.farm, sign = false },
		yard = { width = 90, depth = 54 },
		crates = 1.0,
		furniture = { lamps = 3, benches = 2, bins = 1, cars = 0, hydrants = 0, planters = 0 },
		statue = false,
		bays = { kind = "yard", count = 4 },
	},
	-- A campus block (track, fair, stand) with its own entrance lot.
	campus = {
		kind = "campus",
		setback = 4,
		alley = { near = { 4, 8 }, mid = { 4, 8 }, far = { 6, 10 } },
		buildings = 0.9,
		plan = { weights = weights(0.3, 0.5, 0.2, 0.2, 0.6, 0.2) },
		yard = { width = 96, depth = 54 },
		crates = 0.5,
		furniture = { lamps = 6, benches = 6, bins = 4, cars = 0, hydrants = 1, planters = 0 },
		bays = { kind = "carpark", count = 8 },
	},
	-- A water basin with a quay; sheds and cottages; cars along the quay's landward edge.
	harbour = {
		kind = "harbour",
		sideStreetWidth = 16,
		setback = 4,
		alley = { near = { 4, 8 }, mid = { 6, 10 }, far = { 8, 12 } },
		buildings = 0.9,
		plan = { weights = weights(0.1, 0.4, 0.5, 0.1, 0.5, 0.4), palette = PALETTES.harbour },
		yard = { width = 96, depth = 54 },
		crates = 1.5,
		furniture = { lamps = 5, benches = 4, bins = 4, cars = 0, hydrants = 1, planters = 0 },
		statue = false,
		bays = { kind = "quay", count = 6 },
	},
}
TownKinds.Kinds = KINDS

--------------------------------------------------------------------------------
-- The eighteen names.
--------------------------------------------------------------------------------

local NAMES = {
	["Rotville"] = { base = "industrial", blurb = "compost and recycling works: stacks, tanks, skips",
		plan = { sign = { text = "ROTVILLE COMPOST" } } },
	["NPC Nook"] = { base = "neighbourhood", blurb = "the copy-paste suburb: every house the same",
		plan = { palette = PALETTES.uniform, sizes = { house = { width = { 26, 26 }, depth = { 26, 26 }, floors = { 1, 1 } } } },
		uniform = true },
	["Mewing Meadows"] = { base = "neighbourhood", blurb = "manicured lawns and square hedges",
		plan = { palette = PALETTES.pastel, weights = weights(0.15, 0.85, 0.0, 0.05, 0.95, 0.0),
			sizes = { house = { width = { 28, 30 }, depth = { 26, 30 }, floors = { 2, 2 } } } },
		yard = { width = 80, depth = 50 } },
	["Grass Toucher's Rest"] = { base = "neighbourhood", blurb = "a park with houses round it, no cars",
		backStreets = false, setback = 8, buildings = 0.8,
		plan = { weights = weights(0.0, 0.9, 0.1, 0.0, 0.9, 0.1) },
		yard = { width = 90, depth = 54 },
		furniture = { lamps = 3, benches = 8, bins = 3, cars = 0, hydrants = 0, planters = 0 },
		bays = { kind = "gravel", count = 3 } },
	["Rizz Ridge"] = { base = "neighbourhood", blurb = "terraced hillside, spotlights, a red carpet",
		setback = 6, alley = { near = { 0, 3 }, mid = { 0, 3 }, far = { 2, 5 } }, buildings = 1.1,
		plan = { palette = PALETTES.upscale, weights = weights(0.4, 0.6, 0.0, 0.3, 0.7, 0.0),
			sizes = { house = { floors = { 2, 2 } }, tower = { floors = { 2, 3 } } } },
		yard = { width = 70, depth = 44 }, culDeSac = false,
		bays = { kind = "carpark", count = 6 } },
	["Noob Hollow"] = { base = "neighbourhood", blurb = "the starter village: tiny houses, huge arrows",
		backStreets = false, setback = 6, buildings = 0.7, alley = { near = { 10, 16 }, mid = { 10, 16 }, far = { 12, 16 } },
		plan = { palette = PALETTES.plain, sizes = { house = { width = { 22, 26 }, depth = { 22, 26 }, floors = { 1, 1 } } } },
		yard = { width = 70, depth = 50 }, crates = 0.5, culDeSac = false,
		bays = { kind = "gravel", count = 2 } },
	["Delulu Downs"] = { base = "campus", blurb = "candy roofs, balloons, a fairground",
		setback = 8, alley = { near = { 6, 10 }, mid = { 6, 10 }, far = { 8, 12 } },
		plan = { palette = PALETTES.candy, weights = weights(0.3, 0.7, 0.0, 0.1, 0.9, 0.0) },
		yard = { width = 90, depth = 54 }, bays = { kind = "carpark", count = 6 } },
	["Sahur Junction"] = { base = "industrial", blurb = "the railway town: a siding, a goods shed, a level crossing",
		sideStreetWidth = 16, setback = 4, alley = { near = { 6, 12 }, mid = { 6, 12 }, far = { 8, 14 } }, buildings = 0.9,
		plan = { weights = weights(0.1, 0.3, 0.6, 0.1, 0.3, 0.6), palette = PALETTES.rail, sign = { text = "GOODS IN" } },
		yard = { width = 90, depth = 54 }, crates = 1.5, bays = { kind = "yard", count = 4 } },
	["Bonkington"] = { base = "downtown", blurb = "the town under construction: crane, scaffolding, cones",
		setback = 4, alley = { near = { 2, 6 }, mid = { 2, 6 }, far = { 4, 8 } }, buildings = 1.0,
		plan = { weights = weights(0.5, 0.3, 0.2, 0.3, 0.4, 0.3), palette = PALETTES.construction },
		yard = { width = 80, depth = 50 }, crates = 1.5, bays = { kind = "yard", count = 4 } },
	["Sigma Station"] = { base = "downtown", blurb = "the transit hub: tallest skyline, a station, a car park",
		plan = { weights = weights(0.7, 0.1, 0.2, 0.4, 0.2, 0.4), palette = PALETTES.corporate, sizes = { tower = { floors = { 3, 5 } } } },
		bays = { kind = "carpark", count = 12 } },
	["Brainrot Borough"] = { base = "downtown", blurb = "the civic centre: a hall with a dome, banners, stone",
		buildings = 1.1, plan = { weights = weights(0.55, 0.25, 0.2, 0.3, 0.4, 0.3), palette = PALETTES.civic, sign = { text = "DEPT OF BRAINROT" } },
		yard = { width = 80, depth = 50 }, bays = { kind = "carpark", count = 8 } },
	["Six Seven Square"] = { base = "market", blurb = "the old town: cobbles, a clock tower, market stalls" },
	["Lil Tralala"] = { base = "market", blurb = "a very small, very musical village with a green",
		backStreets = false, setback = 5, alley = { near = { 4, 8 }, mid = { 4, 8 }, far = { 6, 10 } }, buildings = 0.9,
		plan = { weights = weights(0.0, 0.9, 0.1, 0.0, 0.9, 0.1), palette = PALETTES.village,
			sizes = { house = { width = { 20, 26 }, depth = { 20, 24 }, floors = { 1, 2 } } } },
		yard = { width = 80, depth = 50 }, crates = 0.5, statue = false, bays = { kind = "gravel", count = 3 } },
	["Oof Oasis"] = { base = "market", blurb = "the caravanserai: a palm-ringed pool, tents, low ochre houses",
		setback = 4, alley = { near = { 4, 8 }, mid = { 4, 8 }, far = { 6, 10 } }, buildings = 0.9,
		plan = { weights = weights(0.1, 0.7, 0.2, 0.05, 0.75, 0.2), palette = PALETTES.oasis, sizes = { house = { floors = { 1, 2 } } } },
		yard = { width = 90, depth = 54 }, statue = false, furniture = { lamps = 4, benches = 4, bins = 2, cars = 0, hydrants = 0, planters = 0 },
		bays = { kind = "gravel", count = 4 } },
	["Aura Farms"] = { base = "rural", blurb = "the farm: barns, silos, a windmill, paddocks" },
	["Crumbly Creek"] = { base = "rural", blurb = "the old mill town: a millpond, a wheel, crumbling walls",
		backStreets = true, crossReach = 1.0, setback = 4, alley = { near = { 6, 12 }, mid = { 6, 12 }, far = { 8, 14 } }, buildings = 0.8,
		plan = { weights = weights(0.1, 0.6, 0.3, 0.1, 0.6, 0.3), palette = PALETTES.ruin, sign = nil },
		bays = { kind = "gravel", count = 3 } },
	["Speedrun Springs"] = { base = "campus", blurb = "the sports campus: a track, a grandstand, springs",
		plan = { weights = weights(0.3, 0.5, 0.2, 0.2, 0.6, 0.2), palette = PALETTES.sport },
		yard = { width = 96, depth = 54 }, bays = { kind = "carpark", count = 8 } },
	["Lag Lagoon"] = { base = "harbour", blurb = "the harbour: a basin, a quay, a crane, moored boats" },
}
TownKinds.Names = NAMES

--------------------------------------------------------------------------------
-- Lookup
--------------------------------------------------------------------------------

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in pairs(value) do
		out[key] = copy(item)
	end
	return out
end

-- `over` written onto a copy of `base`, one level of tables deep (plan.sizes.house merges; lists
-- such as alley bands and colour lists replace whole).
local function merge(base, over)
	local out = copy(base)
	for key, value in pairs(over or {}) do
		if type(value) == "table" and type(out[key]) == "table" and #value == 0 and #out[key] == 0 then
			out[key] = merge(out[key], value)
		else
			out[key] = copy(value)
		end
	end
	return out
end

local function clamp(profile)
	profile.mainReach = math.clamp(profile.mainReach or 1, 0.5, 1.0)
	profile.crossReach = math.clamp(profile.crossReach or 1, 0.5, 1.0)
	if profile.yard then
		profile.yard.width = math.clamp(profile.yard.width or 70, 30, TownKinds.YARD_MAX_WIDTH)
		profile.yard.depth = math.clamp(profile.yard.depth or 46, 24, TownKinds.YARD_MAX_DEPTH)
	end
	return profile
end

local cache = {}

-- The complete profile for a town name: its kind's profile over the defaults, the name's own
-- overrides over that, reach and yard clamped. Never nil.
function TownKinds.For(name)
	local cached = cache[name]
	if cached then
		return copy(cached)
	end
	local entry = NAMES[name]
	local profile
	if entry then
		local base = KINDS[entry.base] or DEFAULTS
		local overrides = copy(entry)
		overrides.base = nil
		profile = merge(merge(DEFAULTS, base), overrides)
		profile.name = name
	else
		profile = copy(DEFAULTS)
		profile.name = name
	end
	profile = clamp(profile)
	cache[name] = profile
	return copy(profile)
end

-- Every name that has a kind, in a stable order (for the probe and verify).
function TownKinds.Known()
	local list = {}
	for name in pairs(NAMES) do
		table.insert(list, name)
	end
	table.sort(list)
	return list
end

return TownKinds
