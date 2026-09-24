-- Car placement gallery and probe (Oliver 09-24, "make all the car placements make sense"): builds a
-- whole map, reports where every car on it ended up and whether any of them is inside something, and
-- photographs the results from above -- whole towns, their car parks, a kerb, a driveway, a verge.
-- tools/car_placement_check.py scores the same placements by rule on maps built under lupa; this is
-- the picture of it, on the real terrain, with the real physics settling the drivable ones.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/car_placement_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Pick the map by editing MAP_ID and SEED below (the gallery runner takes no arguments). The notes it
-- prints ("[BRR_Gallery] note ...") are the probe: per town, how many cars stand at the kerb, in the
-- car park (and of how many bays) and on driveways; per map, the drivable count; and every car whose
-- box reaches into a solid part that isn't a car, a road or the ground (a wall, a tree, a lamp post),
-- which should be none.
--
-- What to look for in the shots: kerb cars on one side of a street only, a couple of studs apart,
-- facing the way the traffic on their side goes, never at a junction or crossing; car parks part
-- filled, every car square in its bay and all of a row nosing the same way; driveway cars on their
-- concrete strip beside the house, nose to the house, the pavement in front of them clear; verge
-- vehicles pulled in beside a straight bit of country road, off the lane, alone.

local MAP_ID, SEED = "SahurSprings", 101
local TOWN_SHOTS = 3

local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local state = { towns = {}, kerb = {}, driveway = {}, verge = {} }

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- Straight down from `height` over `at`, north up the frame.
local function above(camera, at, height, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.new(at + Vector3.new(0, height, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
end

-- Which parts count as something a car must not be inside: solid, above the kerb, not a car, not
-- the road or a street surface, not the ground.
local SURFACES = { Asphalt = true, JunctionAsphalt = true, Kerb = true, Pavement = true, PavementTaper = true, Crossing = true,
	StopLine = true, Dash = true, RoadSurface = true, RoadEdge = true, RoadCentreLine = true, RoadDash = true, BridgeRoad = true,
	Driveway = true, Hardstanding = true, Paving = true, Cobbles = true }
local function isCar(part)
	local node = part
	while node and node ~= workspace do
		if node.Name == "ParkedCar" or node.Name == "Vehicles" then
			return true
		end
		node = node.Parent
	end
	return false
end

local function probe(map)
	local cars = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("Model") and (d.Name == "ParkedCar" or (d.Parent and d.Parent.Name == "Vehicles")) then
			table.insert(cars, d)
		end
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	local inside = 0
	for _, car in ipairs(cars) do
		local box, size = car:GetBoundingBox()
		-- Above the kerb and a little in from the mirrors, so touching the ground or a bay line isn't a hit.
		local probeBox = box * CFrame.new(0, 0.6, 0)
		local probeSize = Vector3.new(math.max(0.5, size.X - 0.8), math.max(0.5, size.Y - 1.2), math.max(0.5, size.Z - 0.8))
		for _, part in ipairs(workspace:GetPartBoundsInBox(probeBox, probeSize, params)) do
			if part.CanCollide and not isCar(part) and not SURFACES[part.Name] and part.Transparency < 1 then
				inside += 1
				note("INSIDE: %s at %s reaches into %s (%s)", car.Name, tostring(flat(box.Position)), part.Name,
					part.Parent and part.Parent.Name or "?")
				break
			end
		end
	end
	note("probe: %d cars examined, %d reach into something solid", #cars, inside)
end

local function collect(map)
	local vehicles = map:FindFirstChild("Vehicles")
	local drivable = vehicles and #vehicles:GetChildren() or 0
	for _, town in ipairs(map:GetChildren()) do
		if town.Name == "Town" then
			local center = town:GetAttribute("TownCenter")
			local entry = { town = town, name = town:GetAttribute("TownName"), kind = town:GetAttribute("TownKind"),
				center = center, spread = town:GetAttribute("TownSpread") or 110, bays = town:GetAttribute("ParkingBays") or 0,
				taken = 0, statics = 0, driveways = 0 }
			local lot = Vector3.zero
			for index = 1, entry.bays do
				local cf = town:GetAttribute("ParkingBay_" .. index)
				if typeof(cf) == "CFrame" then
					lot += cf.Position / entry.bays
				end
				if town:GetAttribute("ParkingBayTaken_" .. index) then
					entry.taken += 1
				end
			end
			entry.lot = entry.bays > 0 and lot or nil
			for _, child in ipairs(town:GetChildren()) do
				if child.Name == "Driveway" then
					entry.driveways += 1
					table.insert(state.driveway, child.Position)
				elseif child.Name == "ParkedCar" then
					entry.statics += 1
				end
			end
			note("town %s [%s]: %d cars in town models, car park %d of %d bays taken, %d driveways", tostring(entry.name),
				tostring(entry.kind), entry.statics, entry.taken, entry.bays, entry.driveways)
			table.insert(state.towns, entry)
		end
	end
	-- A kerb car: a ParkedCar standing on a street (not in a bay or on a driveway).
	for _, entry in ipairs(state.towns) do
		for _, child in ipairs(entry.town:GetChildren()) do
			if child.Name == "ParkedCar" then
				local at = child:GetBoundingBox().Position
				local inLot = entry.lot and (flat(at) - flat(entry.lot)).Magnitude < 60
				local onDrive = false
				for _, spot in ipairs(state.driveway) do
					if (flat(spot) - flat(at)).Magnitude < 14 then
						onDrive = true
					end
				end
				if not inLot and not onDrive then
					table.insert(state.kerb, at)
				end
			end
		end
	end
	if vehicles then
		for _, vehicle in ipairs(vehicles:GetChildren()) do
			local at = vehicle:GetPivot().Position
			local inTown = false
			for _, entry in ipairs(state.towns) do
				if entry.center and (flat(at) - flat(entry.center)).Magnitude < entry.spread + 60 then
					inTown = true
				end
			end
			if not inTown then
				table.insert(state.verge, at)
			end
		end
	end
	note("map: %d drivable vehicles (%d on country verges), %d kerb cars, %d driveways", drivable, #state.verge, #state.kerb,
		#state.driveway)
end

local views = {
	{
		name = "00_build",
		settle = 3,
		setup = function(_, camera)
			Lighting.ClockTime = 13
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(SEED)
			local started = os.clock()
			local info = MapGenerator.Build(MAP_ID)
			local map = workspace:FindFirstChild("Map")
			note("built %s seed %d in %.1fs, radius %d", MAP_ID, SEED, os.clock() - started, info and info.radius or -1)
			collect(map)
			-- Let the drivable ones settle on their wheels before looking inside anything.
			task.wait(3)
			probe(map)
			above(camera, Vector3.zero, 1400, 70)
		end,
	},
}

for index = 1, TOWN_SHOTS do
	table.insert(views, {
		name = string.format("%02d_town_above", index),
		settle = 2,
		setup = function(_, camera)
			local entry = state.towns[index]
			if not entry then
				note("no town %d", index)
				return
			end
			note("town %d: %s from above", index, tostring(entry.name))
			above(camera, entry.center, entry.spread * 2.4, 60)
		end,
	})
	table.insert(views, {
		name = string.format("%02d_carpark_above", index),
		settle = 2,
		setup = function(_, camera)
			local entry = state.towns[index]
			if not entry or not entry.lot then
				note("town %d has no car park", index)
				return
			end
			note("town %d: %s car park, %d of %d bays", index, tostring(entry.name), entry.taken, entry.bays)
			above(camera, entry.lot, 95, 55)
		end,
	})
	table.insert(views, {
		name = string.format("%02d_carpark_low", index),
		settle = 2,
		setup = function(_, camera)
			local entry = state.towns[index]
			if not entry or not entry.lot then
				return
			end
			camera.FieldOfView = 60
			camera.CFrame = CFrame.lookAt(entry.lot + Vector3.new(34, 16, 34), entry.lot)
		end,
	})
end

for index, list in ipairs({ { "kerb", 3, 60 }, { "driveway", 3, 55 }, { "verge", 3, 70 } }) do
	local kind, count, height = list[1], list[2], list[3]
	for shot = 1, count do
		table.insert(views, {
			name = string.format("%02d_%s_%d", 10 + index, kind, shot),
			settle = 2,
			setup = function(_, camera)
				local at = state[kind][shot]
				if not at then
					note("no %s car %d", kind, shot)
					return
				end
				note("%s %d at %s", kind, shot, tostring(flat(at)))
				above(camera, at, height, 55)
			end,
		})
	end
end

return views
