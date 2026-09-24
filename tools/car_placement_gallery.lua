-- Car placement gallery and probe (Oliver 09-24, "make all the car placements make sense"; "the parking
-- lot locations still are terrible and the parking lots don't all need to be full"): builds whole maps,
-- reports where every car on them ended up and whether any of them is inside something, and
-- photographs the results -- the map with every car park marked, every town and its car park from
-- above, each car park from above, from across its street at eye level and from its back corner, and
-- a kerb, a driveway and a verge. tools/car_placement_check.py and tools/parking_lot_check.py score
-- the same placements by rule on maps built under lupa; this is the picture of it, on the real
-- terrain, with the real physics settling the drivable ones.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/car_placement_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Pick the maps by editing RUNS below (the gallery runner takes no arguments). The notes it prints
-- ("[BRR_Gallery] note ...") are the probe: per town, how many cars stand at the kerb, in the car park
-- (and of how many bays, and the fill it was dealt) and on driveways; per map, the drivable count; and
-- every car whose box reaches into a solid part that isn't a car, a road or the ground (a wall, a tree,
-- a lamp post), which should be none.
--
-- What to look for in the shots: every car park in a row of buildings on a street, square to it,
-- its aisle opening straight onto the street through a dropped kerb and an asphalt apron across the
-- pavement; the asphalt the streets' own, a kerb all round, every row of bays painted; car parks
-- filled to different amounts, the front fuller than the back, every car square in its bay and nosed
-- in (away from the aisle); kerb cars on one side of a street only, facing the way the traffic on
-- their side goes; driveway cars on their concrete strip beside the house, nose to the house; verge
-- vehicles pulled in beside a straight bit of country road, off the lane, alone.

local RUNS = {
	{ map = "SahurSprings", seed = 101, towns = 6 },
	{ map = "TralalaTown", seed = 7, towns = 4 },
	{ map = "BombardiroBay", seed = 5, towns = 5 },
}
local SPOT_SHOTS = 2

local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local state = {}

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- Straight down from `height` over `at`, north up the frame.
local function above(camera, at, height, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.new(flat(at) + Vector3.new(0, (at.Y or 0) + height, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
end

local function look(camera, from, at, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, at)
end

-- Which parts count as something a car must not be inside: solid, above the kerb, not a car, not
-- the road or a street surface, not the ground.
local SURFACES = { Asphalt = true, JunctionAsphalt = true, Kerb = true, Pavement = true, PavementTaper = true, Crossing = true,
	StopLine = true, Dash = true, RoadSurface = true, RoadEdge = true, RoadCentreLine = true, RoadDash = true, BridgeRoad = true,
	Driveway = true, Hardstanding = true, Paving = true, Cobbles = true, LotSurface = true, LotApron = true, BayLine = true,
	DroppedKerb = true }
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

-- The car park's surface: its CFrame's LookVector points out of the car park toward its street, and
-- its size is the asphalt inside the kerbs.
local function lotSurface(town)
	local lot = town:FindFirstChild("ParkingLot")
	return lot and lot:FindFirstChild("LotSurface")
end

local function collect(map)
	state.towns, state.kerb, state.driveway, state.verge = {}, {}, {}, {}
	local vehicles = map:FindFirstChild("Vehicles")
	local drivable = vehicles and #vehicles:GetChildren() or 0
	for _, town in ipairs(map:GetChildren()) do
		if town.Name == "Town" then
			local center = town:GetAttribute("TownCenter")
			local entry = { town = town, name = town:GetAttribute("TownName"), kind = town:GetAttribute("TownKind"),
				center = center, spread = town:GetAttribute("TownSpread") or 110, bays = town:GetAttribute("ParkingBays") or 0,
				fill = town:GetAttribute("ParkingFill"), taken = 0, statics = 0, driveways = 0, surface = lotSurface(town) }
			for index = 1, entry.bays do
				if town:GetAttribute("ParkingBayTaken_" .. index) then
					entry.taken += 1
				end
			end
			for _, child in ipairs(town:GetChildren()) do
				if child.Name == "Driveway" then
					entry.driveways += 1
					table.insert(state.driveway, child.Position)
				elseif child.Name == "ParkedCar" then
					entry.statics += 1
				end
			end
			note("town %s [%s]: %d cars in town models, car park %d of %d bays taken (fill dealt %s), %d driveways",
				tostring(entry.name), tostring(entry.kind), entry.statics, entry.taken, entry.bays,
				entry.fill and string.format("%.2f", entry.fill) or "-", entry.driveways)
			table.insert(state.towns, entry)
		end
	end
	-- A kerb car: a ParkedCar standing on a street (not in a car park or on a driveway).
	for _, entry in ipairs(state.towns) do
		for _, child in ipairs(entry.town:GetChildren()) do
			if child.Name == "ParkedCar" then
				local at = child:GetBoundingBox().Position
				local inLot = false
				if entry.surface then
					local l = entry.surface.CFrame:PointToObjectSpace(at)
					inLot = math.abs(l.X) <= entry.surface.Size.X / 2 + 1 and math.abs(l.Z) <= entry.surface.Size.Z / 2 + 1
				end
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

-- A tall beacon over every car park for the overview shot, where a car park is a few pixels: taken
-- down again by the next view. In the gallery's own folder, never the map.
local function beacons(folder)
	for _, entry in ipairs(state.towns) do
		if entry.surface then
			local p = Instance.new("Part")
			p.Anchored = true
			p.CanCollide = false
			p.Material = Enum.Material.Neon
			p.Color = Color3.fromRGB(255, 40, 200)
			p.Size = Vector3.new(26, 60, 26)
			p.CFrame = CFrame.new(entry.surface.Position + Vector3.new(0, 30, 0))
			p.Parent = folder
		end
	end
end

local views = {}

for runIndex, run in ipairs(RUNS) do
	local tag = string.format("%d%s", runIndex, run.map)
	table.insert(views, {
		name = tag .. "_00_map",
		settle = 3,
		setup = function(folder, camera)
			Lighting.ClockTime = 13
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(run.seed)
			local started = os.clock()
			local info = MapGenerator.Build(run.map)
			local map = workspace:FindFirstChild("Map")
			note("built %s seed %d in %.1fs, radius %d", run.map, run.seed, os.clock() - started, info and info.radius or -1)
			collect(map)
			-- Let the drivable ones settle on their wheels before looking inside anything.
			task.wait(3)
			probe(map)
			beacons(folder)
			above(camera, Vector3.zero, (info and info.radius or 1000) * 1.3, 70)
		end,
	})
	for index = 1, run.towns do
		local function entryOf()
			return state.towns[index]
		end
		table.insert(views, {
			name = string.format("%s_%02d_town", tag, index),
			settle = 2,
			setup = function(_, camera)
				local entry = entryOf()
				if not entry then
					note("no town %d", index)
					return
				end
				Lighting.ClockTime = 13
				note("town %d: %s [%s] from above, car park %d of %d", index, tostring(entry.name), tostring(entry.kind), entry.taken,
					entry.bays)
				above(camera, entry.center, entry.spread * 2.3, 60)
			end,
		})
		-- The car park from above, its street along one edge of the frame.
		table.insert(views, {
			name = string.format("%s_%02d_lot_above", tag, index),
			settle = 2,
			setup = function(_, camera)
				local entry = entryOf()
				if not entry or not entry.surface then
					note("town %d has no car park", index)
					return
				end
				local s = entry.surface
				local centre = s.Position + s.CFrame.LookVector * 8
				above(camera, Vector3.new(centre.X, s.Position.Y, centre.Z), math.max(s.Size.X, s.Size.Z) * 1.45 + 12, 55)
			end,
		})
		-- From the far pavement across its street, at eye level: what a player walking the street sees.
		table.insert(views, {
			name = string.format("%s_%02d_lot_street", tag, index),
			settle = 2,
			setup = function(_, camera)
				local entry = entryOf()
				if not entry or not entry.surface then
					return
				end
				local s = entry.surface
				local toward = s.CFrame.LookVector
				local from = s.Position + toward * (s.Size.Z / 2 + 5 + 18 + 4) + Vector3.new(0, 5.5, 0) + s.CFrame.RightVector * 6
				look(camera, from, s.Position + Vector3.new(0, 1.5, 0), 70)
			end,
		})
		-- From above a back corner, looking down the rows toward the street: whichever back corner has
		-- nothing (a building, a hill) between the camera and the car park.
		table.insert(views, {
			name = string.format("%s_%02d_lot_corner", tag, index),
			settle = 2,
			setup = function(_, camera)
				local entry = entryOf()
				if not entry or not entry.surface then
					return
				end
				local s = entry.surface
				local target = s.Position + s.CFrame.LookVector * 6
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { workspace.Map:FindFirstChild("Vehicles"), entry.town:FindFirstChild("ParkingLot") }
				local chosen = nil
				for _, spot in ipairs({ { 1, 1, 24 }, { -1, 1, 24 }, { 1, 0.3, 32 }, { -1, 0.3, 32 }, { 0, 0.2, 60 } }) do
					local from = s.Position - s.CFrame.LookVector * (s.Size.Z / 2 + 14) * spot[2]
						+ s.CFrame.RightVector * (s.Size.X / 2 + 12) * spot[1] + Vector3.new(0, spot[3], 0)
					if not workspace:Raycast(target, from - target, params) then
						chosen = from
						break
					end
				end
				look(camera, chosen or (s.Position + Vector3.new(0, 70, 0.1)), target, 60)
			end,
		})
	end
	-- After dark: the first paved car park from its corner at dusk, its lights on (the maps have a dawn
	-- and a dusk, and Night Ops turns the day off).
	table.insert(views, {
		name = string.format("%s_%02d_dusk", tag, 80),
		settle = 3,
		setup = function(_, camera)
			local entry = nil
			for _, e in ipairs(state.towns) do
				local lot = e.town:FindFirstChild("ParkingLot")
				if lot and lot:GetAttribute("Kind") == "paved" and e.surface then
					entry = entry or e
				end
			end
			if not entry then
				note("no paved car park for the dusk shot")
				return
			end
			Lighting.ClockTime = 18.9
			local s = entry.surface
			local from = s.Position - s.CFrame.LookVector * (s.Size.Z / 2 + 10) + s.CFrame.RightVector * (s.Size.X / 2 + 10) + Vector3.new(0, 20, 0)
			look(camera, from, s.Position + s.CFrame.LookVector * 4, 65)
		end,
	})
	if runIndex == 1 then
		for kindIndex, list in ipairs({ { "kerb", 60 }, { "driveway", 55 }, { "verge", 70 } }) do
			local kind, height = list[1], list[2]
			for shot = 1, SPOT_SHOTS do
				table.insert(views, {
					name = string.format("%s_%02d_%s_%d", tag, 90 + kindIndex, kind, shot),
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
	end
end

return views
