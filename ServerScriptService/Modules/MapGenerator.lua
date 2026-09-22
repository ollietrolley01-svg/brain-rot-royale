-- Builds the chosen map: real Roblox Terrain for the ground, towns of multi-storey
-- buildings with window openings and internal staircases, and scattered props.
--
-- The buildings themselves (walls, floors, stairs, roofs, interiors, facades) live in MapBuildings.
--
-- Towns are laid out along real streets (see buildTown), with every building facing the street
-- it's on. Everything placed claims its footprint in a MapSpace, and everything placed after
-- checks it, so roads, buildings, street furniture, lakes, easter eggs and scenery never overlap. Inside
-- buildings each floor keeps its own, so furniture never blocks the stairs or swallows a chest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local MapData = require(Shared:WaitForChild("MapData"))
local ZFight = require(Shared:WaitForChild("ZFight"))

-- Required for its side effect as much as its API: loading it registers the map's walls and
-- furniture with CombatService, so bullets can knock them down.
local DestructibleService = require(script.Parent:WaitForChild("DestructibleService"))
local EasterEggs = require(script.Parent:WaitForChild("EasterEggs"))
local HazardService = require(script.Parent:WaitForChild("HazardService"))
local Landmarks = require(script.Parent:WaitForChild("Landmarks"))
local MapDecor = require(script.Parent:WaitForChild("MapDecor"))
local MapSpace = require(script.Parent:WaitForChild("MapSpace"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))
local MapWilds = require(script.Parent:WaitForChild("MapWilds"))
local RoadNetwork = require(script.Parent:WaitForChild("RoadNetwork"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local VendorService = require(script.Parent:WaitForChild("VendorService"))
-- Loaded last so adding it changed no module's load order.
local MapBuildings = require(script.Parent:WaitForChild("MapBuildings"))

local MapGenerator = {}

-- What the parts being built right now are called (Wall, Floor, Sill…), so the build check's
-- clipping and z-fight reports name the piece rather than saying "Part". Builders set it.
local currentName = "Part"

local function makePart(parent, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = currentName
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Trim is decoration: it never collides or stops a bullet, so it can't snag movement or get in
-- the way of a shot through a window.
local function trim(parent, size, cframe, color, material)
	local part = makePart(parent, size, cframe, color, material)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

-- Terrain is no longer flat, so anything placed in the world has to find the surface or it
-- ends up buried in a hill or hovering over a dip.
-- The solid ground at (x, z). Water is NOT ground: left in, a raycast stops at the river's surface,
-- which is the flattest thing on the map, so anything looking for level ground to build on was drawn
-- to the water -- landmark sites scored a river as a perfect site and plugged it with a disc of
-- earth. Callers that want to know about water should ask for it separately.
--
-- The ray starts far above anything the map can build: terrain never reports the voxel a ray starts
-- inside, so a start height below the tallest ground reads as no ground at all.
function MapGenerator.GroundHeightAt(x, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = true

	local result = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), params)
	return result and result.Position.Y or 0
end

--------------------------------------------------------------------------------
-- Buildings
--------------------------------------------------------------------------------

-- Everything about a building is in MapBuildings; a town only needs these three.
local rollPlan = MapBuildings.RollPlan
local buildBuilding = MapBuildings.BuildBuilding
local buildCrate = MapBuildings.BuildCrate

--------------------------------------------------------------------------------
-- Towns
--------------------------------------------------------------------------------

-- A town is laid out like a real one. A main street runs east-west through the town square and a
-- cross street north-south, with a back street parallel to the main one on either side, meeting
-- the cross street at a junction. Buildings line both sides of every street, set back behind the
-- pavement with alleys between them and every door facing the street — densest (and tallest) near
-- the square, thinning toward the edge of town. The streets are only drawn as far out as the
-- buildings go, except where a road leaves the town along one: that street runs right out to meet
-- it, so the road carries straight on from the street's end.
local MAIN_STREET = 18
local SIDE_STREET = 14
local SIDEWALK = 5
local SETBACK = 2
local PLAZA_HALF = 25
local ALLEY_MIN, ALLEY_MAX = 5, 10

-- How wide the gap after a building is, by how far along the street it stands. Alleys tighten
-- toward the square: the blocks nearest it read as a terrace standing shoulder to shoulder, and
-- the gaps only open up toward the edge of town, which is how a real town looks from above. One
-- flat 5-10 gap everywhere made every street a row of detached boxes instead of a street.
--
-- A building's claim already carries 1.5 studs each side, so even a zero here leaves a 3-stud
-- gap between walls -- a narrow alley, not two buildings fused together.
local function alleyAt(along, primary)
	if primary and along < 70 then
		return math.random(0, 2)
	elseif along < 140 then
		return math.random(2, 6)
	end
	return math.random(ALLEY_MIN, ALLEY_MAX)
end
-- Main-street buildings are at most 44 deep and their yards run 11 further back; the back streets
-- sit just behind that.
local BACK_STREET_OFFSET = MAIN_STREET / 2 + SIDEWALK + SETBACK + 44 + 11 + SIDE_STREET / 2 + SIDEWALK

-- The ground a town covers, for laying roads and other towns out round it: its main street runs
-- `half` out along X, its cross street `cross` out along Z, and its buildings can reach `zext` along
-- Z (the back streets' outer blocks stand further out than a short cross street runs).
local function townShape(spread)
	local half = spread + 20
	local cross = math.max(half * 0.85, BACK_STREET_OFFSET + 20)
	return {
		half = half,
		cross = cross,
		zext = math.max(cross, BACK_STREET_OFFSET + SIDE_STREET / 2 + SIDEWALK + SETBACK + 44 + 11),
	}
end

-- Town squares round the map: the first in the middle, the rest round a ring at varied distances.
-- Each is re-rolled -- a little off its slot on the ring after the first few tries -- until its
-- footprint clears every other town's by RoadNetwork.TownGap, so no two towns' streets or blocks
-- run into each other and a road has room to pass between them. Left to chance, towns overlapped on
-- between a third and three quarters of maps. A map too cramped to manage the gap takes the roll
-- that came closest.
local function placeTowns(count, radius, shape)
	local centers = {}
	for index = 1, count do
		local best, bestGap = nil, -math.huge
		for attempt = 1, 80 do
			local angle = index / count * math.pi * 2 + (attempt <= 10 and 0 or (math.random() - 0.5) * 0.7)
			local distance = index == 1 and 0 or radius * (0.32 + math.random() * 0.44)
			local candidate = Vector3.new(
				math.cos(angle) * distance + math.random(-40, 40),
				0,
				math.sin(angle) * distance + math.random(-40, 40)
			)
			if index == 1 or candidate.Magnitude + shape.half * 0.9 <= radius then
				local gap = math.huge
				for _, other in ipairs(centers) do
					local gapX = math.abs(candidate.X - other.X) - 2 * shape.half
					local gapZ = math.abs(candidate.Z - other.Z) - 2 * shape.zext
					gap = math.min(gap, math.max(gapX, gapZ))
				end
				if gap > bestGap then
					best, bestGap = candidate, gap
				end
				if gap >= RoadNetwork.TownGap then
					break
				end
			end
		end
		table.insert(centers, best or Vector3.zero)
	end
	return centers
end

local GROUND_PAINT = Enum.Material.Pavement

-- Repaints the terrain under a strip or a footprint as pavement. Grass terrain grows blades of
-- grass up through anything thin laid on it, which made building floors, streets and squares
-- look like there was nothing there. The paint is the top four studs of the solid ground, whose
-- top sits the surface lift under the surface (see MapTerrain.SurfaceLift), so the ground stays
-- at height 0.
local PAINT_CENTRE = -2 - MapTerrain.SurfaceLift

local function paintStrip(a, b, width)
	local delta = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	if delta.Magnitude < 1 then
		return
	end
	local mid = Vector3.new((a.X + b.X) / 2, PAINT_CENTRE, (a.Z + b.Z) / 2)
	workspace.Terrain:FillBlock(CFrame.lookAt(mid, mid + delta), Vector3.new(width, 4, delta.Magnitude), GROUND_PAINT)
end

local function paintFootprint(center, yaw, sizeX, sizeZ)
	workspace.Terrain:FillBlock(CFrame.new(center.X, PAINT_CENTRE, center.Z) * CFrame.Angles(0, yaw, 0), Vector3.new(sizeX, 4, sizeZ), GROUND_PAINT)
end

-- Whether a turned rectangle is clear in `space`, checked as a grid of small circles covering it.
local function rectFree(space, x, z, yaw, halfX, halfZ, ignore)
	local columns = math.max(1, math.ceil(halfX * 2 / 8))
	local rows = math.max(1, math.ceil(halfZ * 2 / 8))
	local cellX, cellZ = halfX * 2 / columns, halfZ * 2 / rows
	local radius = math.sqrt(cellX * cellX + cellZ * cellZ) / 2
	local c, s = math.cos(yaw), math.sin(yaw)
	for column = 1, columns do
		for row = 1, rows do
			local localX = -halfX + (column - 0.5) * cellX
			local localZ = -halfZ + (row - 0.5) * cellZ
			if not space:IsFree(x + localX * c + localZ * s, z - localX * s + localZ * c, radius, ignore) then
				return false
			end
		end
	end
	return true
end

-- `mouths` says which of the town's four street ends (E, W, N, S) a road leaves from.
local function buildTown(parent, center, preset, spread, chestSpots, lootSpots, townName, space, mouths)
	mouths = mouths or {}
	local town = Instance.new("Model")
	town.Name = "Town"
	town:SetAttribute("TownName", townName)
	-- The HUD reads these for its "now entering" banner. A model's pivot isn't a reliable
	-- centre, and attributes replicate even when the town's parts are streamed out.
	town:SetAttribute("TownCenter", center)
	town:SetAttribute("TownRadius", spread + 40)
	-- How far the town's streets and blocks spread from its square, for anything laying itself out
	-- round a town (its main street runs spread + 20 out).
	town:SetAttribute("TownSpread", spread)
	town.Parent = parent

	local c = Vector3.new(center.X, 0, center.Z)
	local shape = townShape(spread)
	local half, crossHalf = shape.half, shape.cross

	-- Streets are laid out (and claimed) first; they're drawn once we know how far out the
	-- buildings actually go. `primary` streets run out of the square, where the town is densest.
	local streets = {}
	local function planStreet(a, b, width, primary)
		local delta = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local street = {
			a = a,
			b = b,
			width = width,
			primary = primary,
			direction = delta.Unit,
			length = delta.Magnitude,
			used = 0,
			entry = space:AddStrip(a, b, width / 2 + SIDEWALK),
		}
		table.insert(streets, street)
		return street
	end
	local main = {}
	for _, name in ipairs({ "E", "W" }) do
		local direction = name == "E" and Vector3.new(1, 0, 0) or Vector3.new(-1, 0, 0)
		main[name] = planStreet(c + direction * PLAZA_HALF, c + direction * half, MAIN_STREET, true)
	end
	-- The cross street runs out of the square to a junction with the back street and on past it to
	-- the edge of town, and the back street runs both ways out of that junction. The cross street is
	-- as wide as the main street, so a road leaving along either meets a street of its own width.
	local junctions = {}
	for _, name in ipairs({ "N", "S" }) do
		local side = name == "N" and 1 or -1
		local jc = Vector3.new(c.X, 0, c.Z + side * BACK_STREET_OFFSET)
		junctions[name] = {
			name = name,
			center = jc,
			inner = planStreet(c + Vector3.new(0, 0, side * PLAZA_HALF), jc - Vector3.new(0, 0, side * SIDE_STREET / 2), MAIN_STREET, true),
			outer = planStreet(jc + Vector3.new(0, 0, side * SIDE_STREET / 2), c + Vector3.new(0, 0, side * crossHalf), MAIN_STREET, false),
			east = planStreet(jc + Vector3.new(MAIN_STREET / 2, 0, 0), Vector3.new(c.X + half * 0.8, 0, jc.Z), SIDE_STREET, false),
			west = planStreet(jc - Vector3.new(MAIN_STREET / 2, 0, 0), Vector3.new(c.X - half * 0.8, 0, jc.Z), SIDE_STREET, false),
		}
		-- The junction and its corners, where lights or signs may stand.
		space:AddRect(jc.X, jc.Z, MAIN_STREET / 2 + SIDEWALK + 1, SIDE_STREET / 2 + SIDEWALK + 1)
	end

	-- The square.
	space:AddRect(c.X, c.Z, PLAZA_HALF - 1, PLAZA_HALF - 1)

	-- Buildings along both sides of every street. Each street side keeps a cursor walking out from
	-- where the street starts; taking turns round the sides spreads the town evenly, so the blocks
	-- nearest the square fill first.
	local frontages = {}
	for _, street in ipairs(streets) do
		for _, side in ipairs({ 1, -1 }) do
			table.insert(frontages, { street = street, side = side, cursor = 4 })
		end
	end

	local placed = {}
	local target = math.random(preset.buildingsPerTown[1], preset.buildingsPerTown[2]) + 3

	local function placeNext(frontage)
		local street = frontage.street
		local sideVector = Vector3.new(-street.direction.Z, 0, street.direction.X) * frontage.side
		local yaw = math.atan2(sideVector.X, sideVector.Z)
		local frontDistance = street.width / 2 + SIDEWALK + SETBACK

		while frontage.cursor < street.length - 10 do
			local along = frontage.cursor
			local plan = rollPlan(street.primary and along < 70)
			local span = plan.width + 3
			if along + span > street.length - 4 then
				frontage.cursor = street.length
				return false
			end

			local lot = street.a + street.direction * (along + span / 2) + sideVector * (frontDistance + plan.depth / 2)
			local pad = plan.dock and 5 or 0
			local claimCenter = lot + CFrame.Angles(0, yaw, 0) * Vector3.new(0, 0, -2.5 + pad / 2)
			local claimX, claimZ = plan.width / 2 + 1.5, plan.depth / 2 + 3.5 + pad / 2

			if rectFree(space, claimCenter.X, claimCenter.Z, yaw, claimX, claimZ, street.entry) then
				space:AddRect(claimCenter.X, claimCenter.Z, claimX, claimZ, yaw)
				paintFootprint(claimCenter, yaw, claimX * 2 + 2, claimZ * 2 + 2)
				buildBuilding(town, Vector3.new(lot.X, 0, lot.Z), preset, chestSpots, lootSpots, plan, yaw)
				table.insert(placed, { lot = lot, plan = plan, yaw = yaw })
				street.used = math.max(street.used, along + span)
				frontage.cursor = along + span + alleyAt(along, street.primary)
				-- A town is a few thousand parts; spread the cost so the server doesn't stall.
				task.wait()
				return true
			end
			frontage.cursor = along + 8
		end
		return false
	end

	local progress = true
	while progress and #placed < target do
		progress = false
		for _, frontage in ipairs(frontages) do
			if #placed >= target then
				break
			end
			if placeNext(frontage) then
				progress = true
			end
		end
	end

	-- Now draw the streets. A street a road leaves along runs all the way out to meet it; the rest
	-- run a little past their last building (the ones out of the square always a decent way).
	local reach = {}
	local function builtReach(street, minimum)
		if street.used <= 0 and not minimum then
			return 0
		end
		return math.min(street.length, math.max(street.used + 14, minimum or 0))
	end
	for name, street in pairs(main) do
		reach[street] = mouths[name] and street.length or builtReach(street, 60)
	end

	local drawn = {}
	-- A street's far end, unless it's given one (a junction, or a road carrying on), is where it
	-- stops past its last building: closed off with a kerb and pavement across it.
	local closedEnd = { closed = true }
	local function draw(street, ends)
		local length = reach[street] or 0
		if length > 0 then
			local b = street.a + street.direction * length
			ends.b = ends.b or closedEnd
			MapDecor.Street(town, street.a, b, street.width, SIDEWALK, ends)
			paintStrip(street.a, b + street.direction * (SIDEWALK + 1), street.width + SIDEWALK * 2 + 2)
			table.insert(drawn, { a = street.a, b = b, width = street.width, entry = street.entry, sidewalk = SIDEWALK })
		end
	end
	-- A zebra crossing where each street leaves the square.
	local squareEnd = { crossing = 2.8, reserve = 6 }
	-- Where a road carries on from a street's end, the pavements taper away beside it.
	local roadEnd = { taper = true }
	for name, street in pairs(main) do
		draw(street, { a = squareEnd, b = mouths[name] and roadEnd or nil })
	end

	-- The back-street junctions. Whichever streets out of a junction got drawn are its arms; the
	-- cross street always reaches it when any do. Four arms get traffic lights, three a stop sign on
	-- every approach, and two (the cross street straight through, or a bend) neither.
	for _, junction in pairs(junctions) do
		local outward = junction.name
		local inward = outward == "N" and "S" or "N"
		reach[junction.outer] = mouths[outward] and junction.outer.length or builtReach(junction.outer)
		reach[junction.east] = builtReach(junction.east)
		reach[junction.west] = builtReach(junction.west)
		local arms = {
			[inward] = true,
			[outward] = reach[junction.outer] > 0,
			E = reach[junction.east] > 0,
			W = reach[junction.west] > 0,
		}
		local armCount = 0
		for _, present in pairs(arms) do
			if present then
				armCount += 1
			end
		end
		if armCount >= 2 then
			reach[junction.inner] = junction.inner.length
			local control = nil
			if armCount == 4 then
				control = { kind = "signals", phase = math.random() * 40 }
			elseif armCount == 3 then
				control = { kind = "stop", stopArms = arms }
			end
			-- The corners take over the last SIDEWALK of each street's kerbs, with a crossing across
			-- each arm between them and a stop line behind it.
			local atJunction = {
				kerbTrim = SIDEWALK,
				crossing = control and 2.5 or nil,
				stopLine = control and SIDEWALK + 0.7 or nil,
				reserve = control and SIDEWALK + 2.5 or 3,
			}
			draw(junction.inner, { a = squareEnd, b = atJunction })
			draw(junction.outer, { a = atJunction, b = mouths[outward] and roadEnd or nil })
			draw(junction.east, { a = atJunction })
			draw(junction.west, { a = atJunction })
			local spec = {
				center = junction.center,
				bx = MAIN_STREET / 2,
				bz = SIDE_STREET / 2,
				arms = arms,
				sidewalkX = SIDEWALK,
				sidewalkZ = SIDEWALK,
			}
			MapDecor.Junction(town, spec)
			if control then
				MapDecor.JunctionControl(town, spec, control)
			end
			paintFootprint(junction.center, 0, (MAIN_STREET / 2 + SIDEWALK) * 2 + 2, (SIDE_STREET / 2 + SIDEWALK) * 2 + 2)
		else
			reach[junction.inner] = builtReach(junction.inner, 60)
			draw(junction.inner, { a = squareEnd })
		end
	end

	-- Most squares honour an Epic or Legendary brainrot with a statue in the fountain.
	paintFootprint(c, 0, PLAZA_HALF * 2 + 2, PLAZA_HALF * 2 + 2)
	local statueDef = nil
	if math.random() < 0.6 then
		local pool = BrainrotData.OfRarity(math.random() < 0.5 and "Legendary" or "Epic")
		statueDef = #pool > 0 and pool[math.random(1, #pool)] or nil
	end
	local plaza = MapDecor.Plaza(town, center, MapGenerator.GroundHeightAt, statueDef)
	for kind, spots in pairs(plaza) do
		for _, spot in ipairs(spots) do
			table.insert(lootSpots[kind], spot)
		end
	end

	-- A Rot Vendor on the square: SahurCoins for a heal, a shield or ammo, mid-match.
	-- Standing on the square's paving, not sunk into it.
	local vendorAt = c + Vector3.new(21.5, MapGenerator.GroundHeightAt(c.X + 21.5, c.Z - 13.5) + MapDecor.PavingTop, -13.5)
	VendorService.Build(town, CFrame.lookAt(vendorAt, Vector3.new(c.X, vendorAt.Y, c.Z)))

	-- Lamps, benches, parked cars, planters and the welcome sign along the streets.
	local decorSpots = MapDecor.Town(town, center, preset, spread, drawn, townName or "Rotville", MapGenerator.GroundHeightAt, space)
	for _, spot in ipairs(decorSpots) do
		table.insert(lootSpots[math.random() < 0.75 and "weapon" or "heal"], spot)
	end

	-- Crates stacked in back yards, behind each building (and its loading dock), where there's room.
	for _, building in ipairs(placed) do
		local plan = building.plan
		local turn = CFrame.Angles(0, building.yaw, 0)
		for _ = 1, math.random(1, 2) do
			for _ = 1, 6 do
				local offset = turn * Vector3.new((math.random() - 0.5) * math.max(0, plan.width - 6), 0,
					plan.depth / 2 + (plan.dock and 5 or 0) + 5.4)
				local spot = building.lot + offset
				if space:IsFree(spot.X, spot.Z, 4.3) then
					space:AddCircle(spot.X, spot.Z, 4.3)
					buildCrate(town, Vector3.new(spot.X, 0, spot.Z))
					break
				end
			end
		end
	end

	-- Farmland towns sit among fenced crop fields, out past the streets.
	if preset.terrainMaterial == Enum.Material.LeafyGrass then
		for _ = 1, 2 do
			for _ = 1, 10 do
				local angle = math.random() * math.pi * 2
				local width, depth = math.random(50, 70), math.random(34, 44)
				local fieldCenter = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (spread + 60 + math.random(0, 40))
				if space:IsFree(fieldCenter.X, fieldCenter.Z, math.sqrt(width * width + depth * depth) / 2 + 2) then
					space:AddRect(fieldCenter.X, fieldCenter.Z, width / 2 + 1, depth / 2 + 1, angle)
					MapDecor.Field(town, fieldCenter, width, depth, angle, MapGenerator.GroundHeightAt)
					break
				end
			end
		end
	end

	return town
end

--------------------------------------------------------------------------------

-- Tears down the current map and its terrain. The lobby is built from parts high above the
-- map, so clearing terrain never touches it.
-- Each map has its own time of day (MapData.Lighting); the lobby gets the default back.
local function applyLighting(settings)
	local Lighting = game:GetService("Lighting")
	local defaults = MapData.DefaultLighting
	Lighting.ClockTime = settings.clockTime or defaults.clockTime
	Lighting.Brightness = settings.brightness or defaults.brightness
	Lighting.Ambient = settings.ambient or defaults.ambient
	Lighting.OutdoorAmbient = settings.outdoorAmbient or defaults.outdoorAmbient
	Lighting.ShadowSoftness = settings.shadowSoftness or defaults.shadowSoftness
end

-- The lighting the current map was built with, so an event can lay its own over it.
local currentLighting = nil

function MapGenerator.ResetLighting()
	currentLighting = nil
	applyLighting(MapData.DefaultLighting)
end

-- Lays `overrides` (any of clockTime, brightness, ambient, outdoorAmbient, shadowSoftness) over
-- the map's own lighting: a Night Ops match turns the lights out.
function MapGenerator.ApplyLightingOverride(overrides)
	if not overrides then
		return
	end
	local merged = table.clone(currentLighting or MapData.DefaultLighting)
	for key, value in pairs(overrides) do
		merged[key] = value
	end
	applyLighting(merged)
end

function MapGenerator.Clear()
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end
	workspace.Terrain:Clear()
	MapTerrain.SetClouds(workspace.Terrain, nil)
	MapGenerator.ResetLighting()
end

function MapGenerator.Build(mapId)
	local preset = MapData.Get(mapId) or MapData.Get(MapData.Order[1])

	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end

	local map = Instance.new("Folder")
	map.Name = "Map"
	map.Parent = workspace

	currentLighting = MapData.Lighting[preset.id] or MapData.DefaultLighting
	applyLighting(currentLighting)

	local radius = preset.radius
	local townSpread = math.floor(math.max(110, radius * 0.17))
	local space = MapSpace.new()
	local shape = townShape(townSpread)

	-- Town squares first, spaced so no two towns run into each other. The terrain pass keeps their
	-- footprints level (hills under a building would leave it half-buried or floating) and the roads
	-- are planned round them.
	local centers = placeTowns(preset.towns, radius, shape)

	-- The road network, planned before any ground is written. Every road runs on the towns' street
	-- axes: out of a town along the street it continues, across country in straight runs and square
	-- bends, meeting other roads at T-junctions and crossroads (see RoadNetwork). Its corridors are
	-- claimed now, so the plateaus, hills, river, towns and scenery all keep off them, and the relief
	-- pass shapes the ground under them.
	local roads = RoadNetwork.Plan(centers, shape, radius)
	roads:Claim(space)

	local terrain = workspace.Terrain
	terrain:Clear()

	-- The ground: a slab whose top is the surface lift under y = 0, so the surface itself is at
	-- 0 — where the towns, their streets and everything else built to "ground level" go.
	local groundSize = math.floor(radius * 2.3)
	-- A deep slab rather than a 16-stud crust: the relief pass carves into the top of it, and a
	-- thin crust would be punched clean through into the void wherever the ground dips.
	terrain:FillBlock(CFrame.new(0, -36 - MapTerrain.SurfaceLift, 0), Vector3.new(groundSize, 72, groundSize), preset.terrainMaterial)
	task.wait(0.3)

	-- Where the plateaus and the river will go, planned (and the plateaus claimed) before any ground
	-- is shaped, so the roads know where their bridges are while their heights are worked out.
	local plateauPlan = MapTerrain.PlanPlateaus(preset, radius, centers, townSpread, space)
	local riverPlan = MapTerrain.PlanRiver(radius, centers, townSpread, plateauPlan, roads)
	local roadCrossings = riverPlan and MapTerrain.RoadCrossings(riverPlan.points, roads) or {}

	-- Rolling ground across the whole map, before anything at all is built on it. This is what
	-- stops the map reading flat between features; hills and ridges then go on top of it. Towns
	-- fade to dead flat so their streets and buildings still meet level ground, and the ground under
	-- every road is shaped flat to the road's own height.
	MapTerrain.Relief(terrain, preset, radius, centers, townSpread, roads, roadCrossings)
	task.wait()

	local chestSpots, dropSpots = {}, {}

	-- Loot goes where you'd expect to find it rather than evenly everywhere: guns at doorsteps,
	-- by benches and cars, along the roads and in forest clearings; heals indoors and in the
	-- square; movement items on rooftops, at the end of a dock, beside the easter eggs and on
	-- top of the obby. LootService fills a share of each list.
	local lootSpots = { weapon = {}, heal = {}, item = {} }

	-- Plateaus first: they claim their ground so the hills keep off them.
	local ziplines = Instance.new("Model")
	ziplines.Name = "Ziplines"
	ziplines.Parent = map
	local plateaus = MapTerrain.Plateaus(terrain, ziplines, preset, radius, centers, townSpread, space, chestSpots, lootSpots,
		MapGenerator.GroundHeightAt, plateauPlan)

	-- Rolling ground between the towns — hills, ridges, craters, dunes on sand — kept clear of
	-- the towns, the roads, the plateaus and the middle where the last circle lands.
	local hillCount = MapTerrain.Hills(terrain, preset, radius, centers, townSpread, space)
	task.wait()
	-- Whatever the hills filled back into the roads' cuttings goes again.
	MapTerrain.RestoreRoadGround(terrain, roads)
	task.wait()

	-- The river cuts through whatever hills are in its way, then bridges go in where the roads
	-- cross it. Patches of other ground and the snow line come last so they paint the banks and
	-- plateaus too.
	local riverModel = Instance.new("Model")
	riverModel.Name = "River"
	riverModel.Parent = map
	local river = MapTerrain.River(terrain, riverModel, preset, radius, centers, townSpread, plateaus, roads, space, lootSpots,
		MapGenerator.GroundHeightAt, riverPlan)
	task.wait()
	MapTerrain.PaintPatches(terrain, preset, radius, centers, townSpread)
	MapTerrain.SetClouds(terrain, preset.id)
	task.wait()

	-- Ground height for anything standing beside a road: nil in the river, where nothing should.
	local function landHeightAt(x, z)
		if MapTerrain.InRiver(river, x, z, 8) then
			return nil
		end
		return MapGenerator.GroundHeightAt(x, z)
	end

	local roadsModel = Instance.new("Model")
	roadsModel.Name = "Roads"
	roadsModel.Parent = map

	local townNames = MapDecor.ShuffledTownNames()
	local function townName(index)
		return townNames[(index - 1) % #townNames + 1]
	end

	-- Road surfaces and markings, junction boxes, traffic lights and stop signs, bridges, lamps and
	-- fingerposts. Guns and items turn up at the foot of the lamps.
	local roadside = roads:Build(roadsModel, { river = river, landHeightAt = landHeightAt, space = space, townName = townName })
	for _, spot in ipairs(roadside) do
		local roll = math.random()
		if roll < 0.5 then
			table.insert(lootSpots.weapon, spot)
		elseif roll < 0.65 then
			table.insert(lootSpots.item, spot)
		end
	end
	task.wait()

	for index, center in ipairs(centers) do
		buildTown(map, center, preset, townSpread, chestSpots, lootSpots, townName(index), space, roads:MouthsOf(index))
		table.insert(dropSpots, center)
		task.wait()
	end

	if preset.terrainMaterial == Enum.Material.Sand then
		MapDecor.Coast(radius)
	end

	-- Landmarks: big named set pieces between the towns with their own chests and loot. They
	-- level their sites and claim them, so the eggs, lakes and scenery below keep clear, and
	-- they're places a supply drop can land.
	local landmarkSpots, landmarks = Landmarks.Place(map, preset, radius, centers, townSpread + 60, MapGenerator.GroundHeightAt, space,
		chestSpots, lootSpots)
	for _, spot in ipairs(landmarkSpots) do
		table.insert(dropSpots, spot)
	end
	task.wait()

	-- Easter eggs go down before the scenery, so trees and rocks can keep clear of them.
	local eggSpots, obbyTop = EasterEggs.Place(map, radius, centers, townSpread + 70, MapGenerator.GroundHeightAt, space)
	for _, spot in ipairs(eggSpots) do
		-- A movement item just outside the egg, wherever there's room.
		for _ = 1, 8 do
			local angle = math.random() * math.pi * 2
			local x, z = spot.X + math.cos(angle) * 28, spot.Z + math.sin(angle) * 28
			if space:IsFree(x, z, 2) then
				space:AddCircle(x, z, 2)
				table.insert(lootSpots.item, Vector3.new(x, MapGenerator.GroundHeightAt(x, z), z))
				break
			end
		end
	end
	if obbyTop then
		table.insert(lootSpots.item, obbyTop + Vector3.new(3, 0, 0))
		table.insert(lootSpots.weapon, obbyTop + Vector3.new(-3, 0, 0))
	end

	-- Scenery between the towns so the open ground isn't a featureless plain.
	local props = Instance.new("Model")
	props.Name = "Props"
	props.Parent = map

	local function awayFromTowns(position, margin)
		for _, center in ipairs(centers) do
			if Vector2.new(center.X - position.X, center.Z - position.Z).Magnitude < margin then
				return false
			end
		end
		return true
	end

	local function awayFromEggs(position)
		for _, spot in ipairs(eggSpots) do
			if Vector2.new(spot.X - position.X, spot.Z - position.Z).Magnitude < 50 then
				return false
			end
		end
		return true
	end

	-- A few lakes on flat ground between the towns, each with a dock.
	for _ = 1, math.random(1, 3) do
		for _ = 1, 20 do
			local angle = math.random() * math.pi * 2
			local distance = (0.25 + math.random() * 0.6) * radius
			local x, z = math.cos(angle) * distance, math.sin(angle) * distance
			local flat = Vector3.new(x, 0, z)
			local lakeRadius = math.random(28, 50)
			if awayFromTowns(flat, townSpread + lakeRadius + 60) and awayFromEggs(flat) and space:IsFree(x, z, lakeRadius + 14) then
				local low, high = math.huge, -math.huge
				for _, corner in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 0, 0 } }) do
					local height = MapGenerator.GroundHeightAt(x + corner[1] * lakeRadius, z + corner[2] * lakeRadius)
					low, high = math.min(low, height), math.max(high, height)
				end
				if high - low < 4 then
					space:AddCircle(x, z, lakeRadius + 9)
					table.insert(lootSpots.item, MapDecor.Lake(props, Vector3.new(x, low, z), lakeRadius))
					break
				end
			end
		end
	end
	task.wait()

	local function canPlaceProp(position)
		return awayFromTowns(position, townSpread + 40) and awayFromEggs(position)
	end

	-- Scenery grows in clusters — groves, rock fields, palm stands — with open ground between,
	-- rather than one tree every so often evenly across the whole map. A clearing in the middle
	-- of a cluster is a natural place to find a gun. MapDecor.Prop checks and claims the ground
	-- for each piece, so they never grow into each other, a road or a lake.
	local propCount = math.floor(radius * 0.34 * (preset.propDensity or 1))
	local clusterCount = math.max(6, math.floor(propCount / 11))
	for clusterIndex = 1, clusterCount do
		local angle = math.random() * math.pi * 2
		local distance = math.sqrt(math.random()) * radius * 0.92
		local clusterCenter = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)

		if canPlaceProp(clusterCenter) then
			if math.random() < 0.45 and space:IsFree(clusterCenter.X, clusterCenter.Z, 4) then
				space:AddCircle(clusterCenter.X, clusterCenter.Z, 4)
				table.insert(lootSpots.weapon,
					Vector3.new(clusterCenter.X, MapGenerator.GroundHeightAt(clusterCenter.X, clusterCenter.Z), clusterCenter.Z))
			end

			local clusterRadius = math.random(25, 55)
			for _ = 1, math.random(6, 14) do
				local offset = Vector3.new((math.random() - 0.5) * 2 * clusterRadius, 0, (math.random() - 0.5) * 2 * clusterRadius)
				local flat = clusterCenter + offset
				if canPlaceProp(flat) then
					MapDecor.Prop(props, Vector3.new(flat.X, MapGenerator.GroundHeightAt(flat.X, flat.Z), flat.Z), preset, space,
						MapGenerator.GroundHeightAt, lootSpots)
				end
			end
		end

		if clusterIndex % 3 == 0 then
			task.wait()
		end
	end

	-- A light scattering of singles between the clusters.
	for index = 1, math.floor(propCount * 0.25) do
		local angle = math.random() * math.pi * 2
		local distance = math.sqrt(math.random()) * radius * 0.95
		local flat = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		if canPlaceProp(flat) then
			MapDecor.Prop(props, Vector3.new(flat.X, MapGenerator.GroundHeightAt(flat.X, flat.Z), flat.Z), preset, space,
				MapGenerator.GroundHeightAt, lootSpots)
		end
		if index % 40 == 0 then
			task.wait()
		end
	end

	-- The ground under the roads once more, now that the landmark sites, eggs and lakes are down:
	-- a levelled square's corners can reach past the circle it keeps clear. The river's gorge under
	-- each bridge is left as it is.
	MapTerrain.RestoreRoadGround(terrain, roads, true)
	task.wait()

	-- Vehicles, parked on the verge along the roads. On the verge rather than on the carriageway:
	-- the road strips are already claimed in MapSpace, so parking on one would mean skipping the
	-- overlap check that keeps everything else from growing into everything else. They are the
	-- one unanchored thing in a map, which is why they go in last, after the ground has settled.
	local vehicles = Instance.new("Model")
	vehicles.Name = "Vehicles"
	vehicles.Parent = map

	-- On the flat verge, not up the bank. The road's graded corridor is flat for 20 studs either side
	-- of the centre line and then climbs or falls away, so parking beyond the claim (36 studs out) put
	-- every car on the cut-and-fill blend, tilted and half in the air on any slope. The reason it was
	-- pushed out there was that a vehicle's own free-space check failed against the ROAD's claim every
	-- time -- but MapSpace.IsFree already takes an entry to ignore, and roads:Claim keeps each edge's
	-- claim on the edge, so the car can be checked against everything except the road it parks beside.
	local VERGE = RoadNetwork.Width / 2 + 7
	local wantedVehicles = math.clamp(math.floor(radius / 95), 6, 16)
	local parked = 0
	for _, edge in ipairs(roads.edges) do
		if parked >= wantedVehicles then
			break
		end
		-- The straight part of the edge: a bend with a curve has no road on its last stretch.
		local from = edge.a.curve and edge.a.box or 0
		local to = edge.length - (edge.b.curve and edge.b.box or 0)
		local span = to - from
		if span > 90 then
			local along = edge.dir
			for _ = 1, 3 do
				if parked >= wantedVehicles then
					break
				end
				local side = Vector3.new(-along.Z, 0, along.X) * (math.random() < 0.5 and 1 or -1)
				local at = edge.from + along * (from + span * (0.2 + math.random() * 0.6)) + side * VERGE
				if space:IsFree(at.X, at.Z, 9, edge.claim) and not MapTerrain.InRiver(river, at.X, at.Z, 14) then
					space:AddCircle(at.X, at.Z, 9)
					-- Parked pointing along the road, give or take. A vehicle's front is its own -Z, so
					-- the yaw that puts -Z along the road is atan2 of the negated direction.
					local yaw = math.atan2(-along.X, -along.Z) + (math.random() - 0.5) * 0.3
					VehicleService.Create(vehicles, Vector3.new(at.X, MapGenerator.GroundHeightAt(at.X, at.Z), at.Z),
						yaw, math.random() < 0.38 and "bike" or "car")
					parked += 1
				end
			end
		end
	end
	task.wait()

	-- Trees, undergrowth and shelters over everything that is already placed. Last of the placers
	-- because every wild piece asks space:IsFree, so anything claiming ground has claimed it by
	-- now; after MapTerrain.RestoreRoadGround so the ground it samples is final; and before the
	-- map-wide z-fight pass below, so any flush pair it creates is still caught.
	--
	-- `seed` and `avoid` are passed EXPLICITLY because MapWilds treats both as optional and
	-- degrades in silence without them: with no seed it falls back to Random.new(1), which would
	-- make every map on every server roll the identical sequence and quietly break the module's
	-- own "no global RNG" contract; with no avoid list the easter eggs get no clearance and
	-- foliage grows through them. One draw from the global RNG here keeps MapWilds' rolls off the
	-- shared stream, which is what the separate seed is for.
	--
	-- NOTE: ctx.groundAt is MapGenerator.GroundHeightAt, which today ends `or 0` and so never
	-- returns nil -- MapWilds' documented "nil vetoes the spot" check cannot fire yet, so its
	-- counts are an OVER-COUNT and will drop when that contract lands. Not a regression.
	-- pcall because this module had never run in the build path before it was hooked: foliage is
	-- decoration and the map is the game, so a fault in here must not cost the match its map (this
	-- call is not inside one anywhere up the stack -- MatchService takes MapGenerator.Build's
	-- return straight). It must not be SILENT either, which is why the failure lands on an
	-- attribute and not only in a warn: a warn does not reach the render harness, and "no trees"
	-- would otherwise look identical to "trees turned off".
	local okWilds, wilds = pcall(MapWilds.Build, map, {
		preset = preset, radius = radius, centers = centers,
		townSpread = townSpread, space = space,
		groundAt = MapGenerator.GroundHeightAt,
		roads = roads, river = river,
		avoid = eggSpots,
		seed = math.random(1, 2147483646),
	})
	if okWilds and type(wilds) == "table" then
		map:SetAttribute("WildsParts", wilds.parts)
		map:SetAttribute("WildsTrees", wilds.counts.trees)
	else
		map:SetAttribute("WildsFailed", tostring(wilds))
		warn("[MapGenerator] MapWilds.Build failed; map built with no foliage: " .. tostring(wilds))
	end
	task.wait()

	-- The river's line for the minimap, as an attribute so it replicates whatever is streamed.
	if river then
		local list = {}
		for _, point in ipairs(river.points) do
			table.insert(list, string.format("%d,%d", point.X, point.Z))
		end
		map:SetAttribute("RiverPath", table.concat(list, ";"))
	end

	-- Last of all, the z-fight pass over the whole map: any two faces still lying flush (a trim
	-- level with its wall, a slab top at the ground's own surface) are nudged a hair apart.
	local zfight = ZFight.Fix({ map }, { yield = true })
	map:SetAttribute("ZFightMoved", zfight.moved)
	map:SetAttribute("ZFightRemaining", #zfight.remaining)
	task.wait()

	return {
		map = map,
		mapId = preset.id,
		mapName = preset.name,
		radius = radius,
		river = river,
		plateaus = plateaus,
		hills = hillCount,
		zfight = zfight,
		chestSpots = chestSpots,
		lootSpots = lootSpots,
		-- Kept for anything that still reads the old flat list.
		groundSpots = lootSpots.weapon,
		dropSpots = dropSpots,
		-- { X, Y, Z, name, id } per landmark, for the map and the minimap.
		landmarks = landmarks,
		-- The RoadNetwork: its nodes (mouths, bends, junctions) and edges, for anything that needs the roads.
		roads = roads,
	}
end

return MapGenerator
