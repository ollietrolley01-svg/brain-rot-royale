-- Set dressing: the details that make a map read as a place instead of a level.
--
-- Street lamps along the roads; benches, bins, hydrants, planters, parked cars and a welcome
-- sign in every town; and vegetation that suits each map's ground (palms and cacti on sand,
-- pines on rock, hay bales on farmland). A building's own door frames, awnings, chimneys and
-- rooftop clutter are in MapBuildings.
--
-- Everything is primitive parts, with materials doing the texture work — no uploaded art. Decor
-- that could matter in a fight (cars, AC units, water tanks, benches) is solid cover. Small
-- clutter (lamp arms, leaves, flowers) neither collides nor stops bullets, so it never snags
-- movement or eats a shot.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrainrotModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotModels"))
local VehicleModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VehicleModels"))

local MapDecor = {}

-- What the parts being built right now are called (Asphalt, Kerb, Paving…), so the build
-- check's reports name the piece rather than saying "Part". Builders set it.
local currentName = "Part"

-- The thing being built right now, when it can be shot apart (#56): every part it makes is tagged
-- `Destructible = "Kind:D<n>"`, which makes them one pool for DestructibleService, sized off the
-- parts themselves. `grouped` wraps a builder so everything it makes is one such thing; a builder
-- called from inside another keeps the outer one's group. Roads, bridges, traffic signals and the
-- square are never wrapped: they are the ground people stand on, or (the signals) TrafficClient
-- drives their lamps. Town signs, fingerposts and stop signs are, since the whole map breaks (#56).
local currentGroup = nil
local groupSerial = 0

local function grouped(kind, build)
	return function(...)
		if currentGroup then
			return build(...)
		end
		groupSerial += 1
		currentGroup = kind .. ":D" .. groupSerial
		local results = table.pack(pcall(build, ...))
		currentGroup = nil
		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end
end

local function makePart(parent, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	part.Name = currentName
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if currentGroup then
		part:SetAttribute("Destructible", currentGroup)
	end
	part.Parent = parent
	return part
end

local function clutter(part)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

local function pick(list)
	return list[math.random(1, #list)]
end

-- Road and street surfaces, shared with RoadNetwork so a road running out of a town is the same
-- asphalt at the same height as the street it continues. The asphalt's top stands RoadLift above
-- the ground under it.
--
-- Every marking -- lines, dashes, crossings, stop lines, on streets and roads alike -- is a thin
-- slab lying ON the asphalt: its underside is the asphalt's top, facing the other way, and its
-- top stands MarkRaise proud. Nothing is sunk into anything, so no marking shares any volume with
-- the surface it's painted on, and the only faces in one plane are a marking's underside and the
-- asphalt top under it, which face opposite ways and never fight. Markings used to reach half a
-- stud down through the asphalt; where a road's grade changes, two such deep pieces meeting at an
-- angle overlapped their neighbours' sides by enough to read as a fight.
MapDecor.RoadLift = 0.4
MapDecor.AsphaltColor = Color3.fromRGB(62, 62, 66)
MapDecor.CentreLineColor = Color3.fromRGB(230, 214, 140)
MapDecor.EdgeLineColor = Color3.fromRGB(232, 230, 222)
MapDecor.StopLineColor = Color3.fromRGB(242, 242, 238)
MapDecor.EdgeLineInset = 1
MapDecor.EdgeLineWidth = 0.6
MapDecor.MarkRaise = 0.07
local MARK_RAISE = MapDecor.MarkRaise
-- The tops of a town square's paving and cobbles, and of a street's pavements, for anything
-- standing on them.
MapDecor.PavingTop = 0.4
MapDecor.CobblesTop = 0.46
MapDecor.PavementTop = 0.35
local KERB = 0.8
-- The kerb's width, for anything edged with the streets' own kerb (ParkingLots).
MapDecor.KerbWidth = KERB
-- How far every kerb and pavement reaches under the ground it stands on (from -0.06), so nothing
-- standing at ground level shares its underside.
local KERB_SINK = 0.06

-- A flat right triangle, `thickness` thick: the right angle at `corner`, one leg `lengthU` long
-- along `u * signU`, the other `lengthV` long along `v * signV`, with `u` and `v` unit vectors at
-- right angles spanning its plane. Wedges are the only primitive with a triangular face, and it is
-- their X faces, so X is set across the plane. Returns the WedgePart.
local function triangle(parent, corner, u, v, signU, signV, lengthU, lengthV, thickness, color, material)
	local wedge = Instance.new("WedgePart")
	wedge.Name = currentName
	wedge.Size = Vector3.new(thickness, lengthV, lengthU)
	-- A wedge's right angle is at its local (-Y, +Z) edge, with the legs along +Y and -Z.
	local axisY = v * signV
	local axisZ = -u * signU
	local centre = corner + u * (signU * lengthU / 2) + v * (signV * lengthV / 2)
	wedge.CFrame = CFrame.fromMatrix(centre, axisY:Cross(axisZ), axisY)
	wedge.Color = color
	wedge.Material = material or Enum.Material.SmoothPlastic
	wedge.Anchored = true
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.Parent = parent
	return wedge
end
MapDecor.Triangle = triangle

-- Upright cylinder standing on `position`. Cylinder parts run along X, hence the quarter turn.
local function column(parent, height, diameter, position, color, material)
	return makePart(parent, Vector3.new(height, diameter, diameter),
		CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		color, material, Enum.PartType.Cylinder)
end

-- Text on both faces of a board (or just the faces given).
function MapDecor.SignText(part, text, color, faces)
	for _, face in ipairs(faces or { Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 30
		gui.LightInfluence = 0.2
		gui.MaxDistance = 260

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.Text = text
		label.TextColor3 = color
		label.TextScaled = true
		label.TextStrokeTransparency = 0.5
		label.Parent = gui

		gui.Parent = part
	end
end

--------------------------------------------------------------------------------
-- Town names
--------------------------------------------------------------------------------

-- Meme slang that's everywhere on Roblox right now, alongside the game's own running jokes.
local TOWN_NAMES = {
	"Rotville", "Sahur Junction", "Bonkington", "Aura Farms", "Sigma Station", "NPC Nook",
	"Delulu Downs", "Lag Lagoon", "Oof Oasis", "Mewing Meadows", "Brainrot Borough",
	"Six Seven Square", "Grass Toucher's Rest", "Lil Tralala", "Crumbly Creek", "Rizz Ridge",
	"Noob Hollow", "Speedrun Springs",
}

function MapDecor.ShuffledTownNames()
	local names = table.clone(TOWN_NAMES)
	for index = #names, 2, -1 do
		local swap = math.random(1, index)
		names[index], names[swap] = names[swap], names[index]
	end
	return names
end

--------------------------------------------------------------------------------
-- Street furniture
--------------------------------------------------------------------------------

local METAL_DARK = Color3.fromRGB(46, 48, 54)
local LAMP_GLOW = Color3.fromRGB(255, 226, 160)

-- `facing` is the flat direction the lamp arm reaches out over.
local function streetLamp(parent, position, facing)
	currentName = "LampPost"
	column(parent, 14, 0.7, position, METAL_DARK, Enum.Material.Metal)
	local top = position + Vector3.new(0, 13.6, 0)
	local look = CFrame.lookAt(top, top + facing)
	currentName = "LampArm"
	clutter(makePart(parent, Vector3.new(0.35, 0.35, 3.4), look * CFrame.new(0, 0, -1.7), METAL_DARK, Enum.Material.Metal))
	currentName = "Lamp"
	clutter(makePart(parent, Vector3.new(1.8, 0.5, 1.4), look * CFrame.new(0, -0.35, -3.3), LAMP_GLOW, Enum.Material.Neon))
	currentName = "Part"
end
streetLamp = grouped("Lamp", streetLamp)
MapDecor.StreetLamp = streetLamp

local function bench(parent, position, yaw)
	local cf = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	local wood = Color3.fromRGB(140, 98, 60)
	makePart(parent, Vector3.new(6, 0.5, 2), cf * CFrame.new(0, 2.1, 0), wood, Enum.Material.WoodPlanks)
	makePart(parent, Vector3.new(6, 1.8, 0.4), cf * CFrame.new(0, 3.3, 0.9), wood, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -2.5, 2.5 }) do
		makePart(parent, Vector3.new(0.4, 2, 1.8), cf * CFrame.new(x, 1, 0), METAL_DARK, Enum.Material.Metal)
	end
end
bench = grouped("Bench", bench)

local function bin(parent, position)
	column(parent, 3.4, 2.4, position, Color3.fromRGB(54, 92, 64), Enum.Material.Metal)
	column(parent, 0.3, 2.7, position + Vector3.new(0, 3.4, 0), Color3.fromRGB(40, 70, 48), Enum.Material.Metal)
end
bin = grouped("Bin", bin)

local function hydrant(parent, position)
	local red = Color3.fromRGB(206, 44, 40)
	column(parent, 2.4, 1.2, position, red, Enum.Material.Metal)
	makePart(parent, Vector3.new(1.3, 1.3, 1.3), CFrame.new(position + Vector3.new(0, 2.5, 0)), red,
		Enum.Material.Metal, Enum.PartType.Ball)
	clutter(makePart(parent, Vector3.new(2, 0.5, 0.5), CFrame.new(position + Vector3.new(0, 1.6, 0)),
		Color3.fromRGB(230, 220, 90), Enum.Material.Metal, Enum.PartType.Cylinder))
end
hydrant = grouped("Hydrant", hydrant)

local FLOWER_COLORS = {
	Color3.fromRGB(255, 96, 140), Color3.fromRGB(255, 214, 70), Color3.fromRGB(170, 120, 255),
	Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 140, 60),
}

local function planter(parent, position, yaw)
	local cf = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	makePart(parent, Vector3.new(6, 1.8, 3), cf * CFrame.new(0, 0.9, 0), Color3.fromRGB(150, 96, 74), Enum.Material.Brick)
	clutter(makePart(parent, Vector3.new(5.4, 0.3, 2.4), cf * CFrame.new(0, 1.85, 0), Color3.fromRGB(80, 56, 40), Enum.Material.Ground))
	for index = -1, 1 do
		clutter(makePart(parent, Vector3.new(1.6, 1.6, 1.6), cf * CFrame.new(index * 1.8, 2.5, 0),
			Color3.fromRGB(70, 132, 60), Enum.Material.Grass, Enum.PartType.Ball))
		clutter(makePart(parent, Vector3.new(0.8, 0.8, 0.8), cf * CFrame.new(index * 1.8 + 0.3, 3.2, -0.3),
			pick(FLOWER_COLORS), Enum.Material.SmoothPlastic, Enum.PartType.Ball))
	end
end
planter = grouped("Planter", planter)

local UMBRELLA_COLORS = {
	Color3.fromRGB(240, 80, 80), Color3.fromRGB(70, 170, 240), Color3.fromRGB(255, 210, 70),
	Color3.fromRGB(120, 220, 140), Color3.fromRGB(250, 130, 200),
}

local function beachUmbrella(parent, position)
	column(parent, 9, 0.4, position, Color3.fromRGB(230, 230, 230), Enum.Material.Metal)
	clutter(makePart(parent, Vector3.new(0.6, 10, 10),
		CFrame.new(position + Vector3.new(0, 9, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		pick(UMBRELLA_COLORS), Enum.Material.Fabric, Enum.PartType.Cylinder))
	clutter(makePart(parent, Vector3.new(3, 0.2, 6), CFrame.new(position + Vector3.new(2.5, 0.1, 0)),
		pick(UMBRELLA_COLORS), Enum.Material.Fabric))
end
beachUmbrella = grouped("Umbrella", beachUmbrella)

local CAR_COLORS = {
	Color3.fromRGB(196, 50, 50), Color3.fromRGB(50, 96, 196), Color3.fromRGB(230, 230, 226),
	Color3.fromRGB(240, 196, 50), Color3.fromRGB(60, 150, 90), Color3.fromRGB(40, 40, 46),
	Color3.fromRGB(240, 130, 190),
}

-- The plain car: a body, a glass cabin, four wheels and four lamps, eleven parts. Solid, waist-high
-- and about the length of a sprint stride: proper cover in the street. Kept for the kerbside cars
-- past a town's DETAILED_CARS_PER_TOWN, where the part budget can't pay for another real design.
local function boxCar(parent, cf, paint)
	makePart(parent, Vector3.new(6.4, 2.6, 12.6), cf * CFrame.new(0, 2.1, 0), paint, Enum.Material.SmoothPlastic)
	local cabin = makePart(parent, Vector3.new(5.8, 2.3, 6.6), cf * CFrame.new(0, 4.55, 0.8),
		Color3.fromRGB(40, 56, 72), Enum.Material.Glass)
	cabin.Transparency = 0.25
	makePart(parent, Vector3.new(5.9, 0.3, 6.7), cf * CFrame.new(0, 5.85, 0.8), paint, Enum.Material.SmoothPlastic)

	for _, x in ipairs({ -3.2, 3.2 }) do
		for _, z in ipairs({ -4.1, 4.1 }) do
			makePart(parent, Vector3.new(0.9, 2.5, 2.5), cf * CFrame.new(x, 1.25, z),
				Color3.fromRGB(28, 28, 30), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		end
	end

	for _, x in ipairs({ -2.2, 2.2 }) do
		clutter(makePart(parent, Vector3.new(1.2, 0.6, 0.2), cf * CFrame.new(x, 2.6, -6.35),
			Color3.fromRGB(255, 250, 220), Enum.Material.Neon))
		clutter(makePart(parent, Vector3.new(1.2, 0.5, 0.2), cf * CFrame.new(x, 2.6, 6.35),
			Color3.fromRGB(220, 40, 40), Enum.Material.Neon))
	end
end

-- How many of a town's kerbside cars are real designs; the rest are the plain car. A design built
-- static is 200 to 290 parts against the plain car's 11 (tools/parked_car_check.py prints them),
-- and the biggest map is already past its part budget (#121), so this is the knob: each step up
-- costs roughly 225 parts a town, 900 to 1,600 a map. Oliver 09-24: every kerbside car is a real
-- design (up to count("cars", 4) a town, so about 900 parts a town); the plain car is only the
-- fallback if a design can't be built.
local DETAILED_CARS_PER_TOWN = math.huge

-- Length (along the nose) and width over everything, mirrors included, about the point the car is
-- placed by (the middle of the wheelbase, which is not the middle of a van: its body runs a stud
-- further back than forward, so it counts as twice its longer end). The plain car's is fixed; a
-- real design's is measured once per server off a static build.
-- Kerbside parking (MapDecor.Town): only on streets at least this wide, so a lane stays clear beside a
-- parked car (18 less the widest car with its mirrors leaves 9); no nearer a street's end than this,
-- where its junction, crossing or stop line is (a real street keeps ten metres or so of kerb clear
-- there); and this gap between two cars in a row.
local KERB_PARKING_WIDTH = 18
local KERB_END_CLEAR = 22
local KERB_GAP = 2
-- A driveway's top, above the ground it's laid on (clear of the grass, like the pavement).
local DRIVEWAY_TOP = 0.12

local PLAIN_FOOTPRINT = { length = 12.9, width = 7.3, centre = Vector3.zero, span = 12.9 }
local footprints = {}

local function footprintOf(modelId)
	if not footprints[modelId] then
		local probe = VehicleModels.BuildStatic(modelId, Random.new(1), CFrame.new())
		local box, size = probe:GetBoundingBox()
		probe:Destroy()
		footprints[modelId] = {
			length = 2 * (math.abs(box.Position.Z) + size.Z / 2),
			width = 2 * (math.abs(box.Position.X) + size.X / 2),
			-- Where the middle of the car is from the point it's placed by (its own axes), so a car
			-- can be centred in a bay or on a driveway rather than its wheelbase.
			centre = Vector3.new(box.Position.X, 0, box.Position.Z),
			-- Its real end-to-end length, for spacing cars in a row.
			span = size.Z,
		}
	end
	return footprints[modelId]
end

-- What the next kerbside car will be, before a spot is looked for, so the spot fits it: `id` and
-- `rng` for a real design (nil for the plain car), and the claim it needs. The claim is two circles
-- `reach` either side of the centre, `radius` wide, which fits a car's long shape far better than
-- one big circle; the plain car's is the 3.6 / 3.2 it always had, a longer or wider design's grows.
-- A real design takes exactly one global roll here (its seed); the plain car takes its one (the
-- paint) in parkedCar. Either way the decor built after it lands where it always did.
local function parkedCarDesign(detailed)
	local design = { footprint = PLAIN_FOOTPRINT }
	if detailed then
		design.rng = Random.new(math.random(1, 2 ^ 30))
		design.id = VehicleModels.Pick("car", design.rng)
		design.footprint = footprintOf(design.id)
	end
	design.halfWidth = design.footprint.width / 2
	design.radius, design.reach = 3.6, 3.2
	if design.id then
		design.radius = math.max(3.6, design.halfWidth)
		design.reach = math.max(3.2, design.footprint.length / 2 - design.radius)
	end
	return design
end

-- A parked car at the kerb (#16 / #94). A real design is built through VehicleModels.BuildStatic:
-- anchored, no seat, no joints, no scripts, nothing that makes it a vehicle, and cut to what reads
-- from the street. Otherwise the plain car above.
local function parkedCar(parent, position, yaw, design)
	local cf = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	local car
	if design and design.id then
		car = VehicleModels.BuildStatic(design.id, design.rng, cf)
	else
		car = Instance.new("Model")
		boxCar(car, cf, pick(CAR_COLORS))
	end
	-- One Model, one health pool (DestructibleService reads the attribute): shot apart as a car, #51.
	car.Name = "ParkedCar"
	car:SetAttribute("DestructibleHealth", 240)
	car.Parent = parent
	return car
end
-- The harnesses (tools/parked_car_check.py) build one on its own.
MapDecor.ParkedCarDesign = parkedCarDesign
MapDecor.ParkedCar = parkedCar

local function townSign(parent, position, facing, name)
	local look = CFrame.lookAt(position, position + facing)
	for _, x in ipairs({ -8.5, 8.5 }) do
		makePart(parent, Vector3.new(0.9, 9, 0.9), look * CFrame.new(x, 4.5, 0), Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
	end
	local board = makePart(parent, Vector3.new(20, 5, 0.7), look * CFrame.new(0, 7, 0),
		Color3.fromRGB(46, 96, 64), Enum.Material.WoodPlanks)
	MapDecor.SignText(board, "WELCOME TO\n" .. string.upper(name), Color3.fromRGB(255, 244, 214))
end
townSign = grouped("Sign", townSign)

-- A fingerpost with one board per direction, stacked up the post: `boards` is a list of
-- { direction = flat unit vector, text = name }. Each board sticks out from the post along its
-- direction and ends in an arrow nose, with the name on both faces.
function MapDecor.Fingerpost(parent, position, boards)
	local wood = Color3.fromRGB(110, 80, 52)
	local paint = Color3.fromRGB(236, 226, 196)
	local height = 9.4
	currentName = "FingerpostPost"
	makePart(parent, Vector3.new(0.8, height, 0.8), CFrame.new(position + Vector3.new(0, height / 2, 0)), wood, Enum.Material.Wood)
	currentName = "FingerpostCap"
	clutter(makePart(parent, Vector3.new(1.1, 0.3, 1.1), CFrame.new(position + Vector3.new(0, height + 0.15, 0)), wood:Lerp(Color3.new(0, 0, 0), 0.3), Enum.Material.Wood))
	local length, boardHeight, thickness = 7.2, 1.1, 0.3
	for index, board in ipairs(boards) do
		local y = height - 0.9 - (index - 1) * 1.35
		local direction = board.direction
		local centre = position + Vector3.new(0, y, 0) + direction * (0.4 + length / 2)
		currentName = "FingerpostBoard"
		local plank = clutter(makePart(parent, Vector3.new(thickness, boardHeight, length), CFrame.lookAt(centre, centre + direction), paint, Enum.Material.WoodPlanks))
		MapDecor.SignText(plank, string.upper(board.text), Color3.fromRGB(46, 36, 26), { Enum.NormalId.Left, Enum.NormalId.Right })
		-- The arrow nose: two wedges meeting at a point beyond the board's end.
		local tip = position + Vector3.new(0, y, 0) + direction * (0.4 + length)
		currentName = "FingerpostNose"
		for _, sign in ipairs({ 1, -1 }) do
			clutter(triangle(parent, tip, direction, Vector3.yAxis, 1, sign, 0.9, boardHeight / 2, thickness, paint, Enum.Material.WoodPlanks))
		end
	end
	currentName = "Part"
end
MapDecor.Fingerpost = grouped("Sign", MapDecor.Fingerpost)

--------------------------------------------------------------------------------
-- River crossings
--------------------------------------------------------------------------------

-- Where the bottoms of bridge piers go: into the river bed, which is carved to -7.
local RIVER_BED = -9

-- A stone road bridge under a stretch of road. The road lays its own asphalt and markings straight
-- across (so the carriageway runs onto and off the bridge without a seam); this builds what carries
-- it: the deck slab under the asphalt, a parapet with coping and lamps down each side, and piers
-- from the deck down into the river bed. `deckFrame` sits on the road's top surface at the middle
-- of the span, looking along the road and tilted with it; `halfWidth` is half the carriageway.
function MapDecor.Bridge(parent, deckFrame, span, halfWidth)
	local stone = Color3.fromRGB(150, 146, 138)
	local dark = Color3.fromRGB(112, 108, 102)
	local lift = MapDecor.RoadLift
	-- Under the 0.4 of asphalt, and a little wider, so the parapets stand on it.
	currentName = "BridgeDeck"
	makePart(parent, Vector3.new(halfWidth * 2 + 3, 1.2, span), deckFrame * CFrame.new(0, -lift - 0.6, 0), Color3.fromRGB(96, 94, 90), Enum.Material.Concrete)
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (halfWidth + 1)
		currentName = "BridgeParapet"
		makePart(parent, Vector3.new(1, 3, span), deckFrame * CFrame.new(x, -lift + 1.5, 0), stone, Enum.Material.Cobblestone)
		currentName = "BridgeCoping"
		clutter(makePart(parent, Vector3.new(1.4, 0.35, span), deckFrame * CFrame.new(x, -lift + 3.175, 0), dark, Enum.Material.Slate))
		-- Lamps at both ends of each parapet.
		for _, z in ipairs({ -span / 2 + 2, span / 2 - 2 }) do
			currentName = "BridgeLampPost"
			makePart(parent, Vector3.new(0.5, 4.5, 0.5), deckFrame * CFrame.new(x, -lift + 3.35 + 2.25, z), Color3.fromRGB(46, 46, 52), Enum.Material.Metal)
			currentName = "BridgeLamp"
			local lamp = clutter(makePart(parent, Vector3.new(1.3, 1.3, 1.3), deckFrame * CFrame.new(x, -lift + 3.35 + 4.5 + 0.65, z),
				Color3.fromRGB(255, 232, 170), Enum.Material.Neon))
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 220, 160)
			light.Range = 22
			light.Brightness = 1.2
			light.Parent = lamp
		end
	end
	-- Piers stand upright whatever the deck's grade, from inside its underside (so a tilted deck
	-- never shows a gap over a flat pier top) down into the river bed, with an arch beam between
	-- each pair butting their inner faces.
	local flatLook = Vector3.new(deckFrame.LookVector.X, 0, deckFrame.LookVector.Z).Unit
	local pierX, pierHalf = halfWidth - 2.5, 2.25
	for _, z in ipairs({ -span * 0.22, span * 0.22 }) do
		for _, side in ipairs({ -1, 1 }) do
			local top = (deckFrame * CFrame.new(side * pierX, -lift - 1.2 + 0.3, z)).Position
			local height = top.Y - RIVER_BED
			if height > 1 then
				local centre = Vector3.new(top.X, (top.Y + RIVER_BED) / 2, top.Z)
				currentName = "BridgePier"
				makePart(parent, Vector3.new(pierHalf * 2, height, pierHalf * 2), CFrame.lookAt(centre, centre + flatLook), dark, Enum.Material.Cobblestone)
			end
		end
		currentName = "BridgeArch"
		clutter(makePart(parent, Vector3.new((pierX - pierHalf) * 2, 2.4, 3.2), deckFrame * CFrame.new(0, -lift - 1.2 - 1.2, z), stone, Enum.Material.Cobblestone))
	end
	currentName = "Part"
end

-- A plank footbridge with rope rails, six studs wide.
function MapDecor.Footbridge(parent, center, direction, span)
	local look = CFrame.lookAt(center, center + direction)
	local wood = Color3.fromRGB(140, 100, 62)
	local post = Color3.fromRGB(96, 70, 46)
	local planks = math.floor(span / 1.6)
	currentName = "FootbridgePlank"
	for index = 1, planks do
		local z = -span / 2 + (index - 0.5) * span / planks
		-- A slight camber: highest in the middle.
		local rise = 1.2 * (1 - (2 * z / span) ^ 2)
		makePart(parent, Vector3.new(6, 0.35, 1.4), look * CFrame.new(0, 0.6 + rise, z), wood, Enum.Material.WoodPlanks)
	end
	for _, x in ipairs({ -2.9, 2.9 }) do
		for _, z in ipairs({ -span / 2 + 1, -span / 6, span / 6, span / 2 - 1 }) do
			local rise = 1.2 * (1 - (2 * z / span) ^ 2)
			currentName = "FootbridgePost"
			makePart(parent, Vector3.new(0.5, 3.4, 0.5), look * CFrame.new(x, 2.2 + rise, z), post, Enum.Material.Wood)
			-- Legs down into the water at the inner posts.
			if math.abs(z) < span / 4 then
				currentName = "FootbridgeLeg"
				makePart(parent, Vector3.new(0.6, 8, 0.6), look * CFrame.new(x, -3.4, z), post, Enum.Material.Wood)
			end
		end
		currentName = "FootbridgeRope"
		clutter(makePart(parent, Vector3.new(0.25, 0.25, span), look * CFrame.new(x, 4, 0), Color3.fromRGB(190, 160, 110), Enum.Material.Fabric))
	end
	currentName = "Part"
end

-- A line of boulders across the water, tops just clear of it.
function MapDecor.SteppingStones(parent, center, direction, span)
	local count = math.floor(span / 5.5)
	currentName = "SteppingStone"
	for index = 0, count do
		local along = -span / 2 + index * span / count
		local position = center + direction * along + Vector3.new((math.random() - 0.5) * 2, 0, (math.random() - 0.5) * 2)
		local size = 4 + math.random() * 1.5
		makePart(parent, Vector3.new(size, size * 0.8, size * 1.1), CFrame.new(position + Vector3.new(0, -1.6, 0)) * CFrame.Angles(0, math.random() * 3, 0),
			Color3.fromRGB(122, 118, 110), Enum.Material.Rock, Enum.PartType.Ball)
	end
	currentName = "Part"
end

--------------------------------------------------------------------------------
-- Roads and towns
--------------------------------------------------------------------------------

local KERB_COLOR = Color3.fromRGB(176, 174, 166)
local TAPER = 6
local PAVEMENT_COLOR = Color3.fromRGB(198, 194, 184)
local ARM_DIRECTION = {
	E = Vector3.new(1, 0, 0),
	W = Vector3.new(-1, 0, 0),
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
}

-- A town street: asphalt with kerbs, a pavement either side `sidewalk` studs wide and centre-line
-- dashes. Laid flat and non-colliding like the roads, and invisible to raycasts, so loot and
-- supply drops still find the ground beneath.
--
-- `ends` says how each end meets whatever is there, as { a = spec, b = spec } (either optional):
--   kerbTrim  how far short of that end the kerbs and pavements stop, where a junction's corner
--             pieces take over
--   crossing  distance from that end to the middle of a zebra crossing
--   stopLine  distance from that end to the middle of a stop line across the lane arriving there
--   reserve   how far from that end the centre dashes keep off (default 3)
--   taper     a road carries on from that end: the pavements narrow away to nothing beside the
--             road's shoulders instead of stopping square
--   closed    the street stops there (past its last building): the kerb and pavement wrap across
--             the end, so it finishes like a street rather than as a raw edge of asphalt
function MapDecor.Street(parent, a, b, width, sidewalk, ends)
	sidewalk = sidewalk or 0
	ends = ends or {}
	local startSpec, endSpec = ends.a or {}, ends.b or {}
	local delta = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local length = delta.Magnitude
	if length < 1 then
		return
	end
	local mid = Vector3.new((a.X + b.X) / 2, a.Y, (a.Z + b.Z) / 2)
	-- Local -Z runs toward `b`, so `a` is at local +Z, and local +X is on the right travelling
	-- toward `b`.
	local look = CFrame.lookAt(mid, mid + delta)
	local lift = MapDecor.RoadLift
	local function at(distance)
		return length / 2 - distance
	end

	-- The asphalt sits on the ground (0 to 0.4). Kerbs and pavements beside it start a little under
	-- the ground and stand clear of it (kerbs to 0.5, pavements to 0.35), and markings lie on top
	-- (0.4 to 0.47), so no two of these share a face facing the same way or any volume.
	currentName = "Asphalt"
	clutter(makePart(parent, Vector3.new(width, lift, length), look * CFrame.new(0, lift / 2, 0), MapDecor.AsphaltColor, Enum.Material.Asphalt))

	local trimA, trimB = startSpec.kerbTrim or 0, endSpec.kerbTrim or 0
	local kerbLength = length - trimA - trimB
	if kerbLength > 0.05 then
		local kerbZ = (trimB - trimA) / 2
		for _, side in ipairs({ -1, 1 }) do
			currentName = "Kerb"
			clutter(makePart(parent, Vector3.new(KERB, 0.56, kerbLength), look * CFrame.new(side * (width / 2 + KERB / 2), 0.22, kerbZ),
				KERB_COLOR, Enum.Material.Concrete))
			if sidewalk > KERB then
				local pavement = sidewalk - KERB
				currentName = "Pavement"
				clutter(makePart(parent, Vector3.new(pavement, 0.41, kerbLength),
					look * CFrame.new(side * (width / 2 + KERB + pavement / 2), 0.145, kerbZ), PAVEMENT_COLOR, Enum.Material.Pavement))
			end
		end
	end

	local markY = lift + MARK_RAISE / 2
	local markHeight = MARK_RAISE
	local function crossing(distance)
		currentName = "Crossing"
		local stripes = math.floor(width / 2.4)
		for index = 0, stripes - 1 do
			local x = -width / 2 + 1.2 + index * (width - 2.4) / math.max(1, stripes - 1)
			clutter(makePart(parent, Vector3.new(1.2, markHeight, 3.6), look * CFrame.new(x, markY, at(distance)),
				MapDecor.StopLineColor, Enum.Material.SmoothPlastic))
		end
	end
	-- Across the lane arriving at that end: traffic drives on the right, so the lane arriving at
	-- `b` is on local +X and the lane arriving at `a` on local -X.
	local function stopLine(distance, side)
		currentName = "StopLine"
		local inner, outer = 0.55, width / 2 - 0.35
		clutter(makePart(parent, Vector3.new(outer - inner, markHeight, 1), look * CFrame.new(side * (inner + outer) / 2, markY, at(distance)),
			MapDecor.StopLineColor, Enum.Material.SmoothPlastic))
	end
	-- A triangle of pavement off each side of the end, `TAPER` long, its long edge against where the
	-- road's asphalt continues and its end against the kerb and pavement it continues.
	local function taper(atStart)
		-- Local -Z (the look direction) runs toward `b`, so past `b` is along it and past `a` against it.
		local sign = atStart and -1 or 1
		local endZ = atStart and length / 2 or -length / 2
		for _, side in ipairs({ -1, 1 }) do
			local corner = (look * CFrame.new(side * width / 2, 0, endZ)).Position
			currentName = "PavementTaper"
			-- The same height as the pavement: from just under the ground to 0.35.
			local wedge = triangle(parent, corner + Vector3.new(0, 0.145, 0), look.RightVector, look.LookVector,
				side, sign, sidewalk, TAPER, 0.41, PAVEMENT_COLOR, Enum.Material.Pavement)
			clutter(wedge)
		end
	end
	-- A closed end: a kerb straight across the end of the asphalt, joining the two side kerbs, and a
	-- strip of pavement behind it joining the two pavements.
	local function close(atStart)
		local sign = atStart and 1 or -1
		local endZ = atStart and length / 2 or -length / 2
		local across = width + 2 * math.max(sidewalk, KERB)
		currentName = "Kerb"
		clutter(makePart(parent, Vector3.new(across, 0.56, KERB), look * CFrame.new(0, 0.22, endZ + sign * KERB / 2), KERB_COLOR, Enum.Material.Concrete))
		if sidewalk > KERB then
			currentName = "Pavement"
			clutter(makePart(parent, Vector3.new(across, 0.41, sidewalk - KERB), look * CFrame.new(0, 0.145, endZ + sign * (KERB + (sidewalk - KERB) / 2)),
				PAVEMENT_COLOR, Enum.Material.Pavement))
		end
	end
	if startSpec.closed then
		close(true)
	end
	if endSpec.closed then
		close(false)
	end
	if startSpec.taper then
		taper(true)
	end
	if endSpec.taper then
		taper(false)
	end
	if startSpec.crossing then
		crossing(startSpec.crossing)
	end
	if endSpec.crossing then
		crossing(length - endSpec.crossing)
	end
	if startSpec.stopLine then
		stopLine(startSpec.stopLine, -1)
	end
	if endSpec.stopLine then
		stopLine(length - endSpec.stopLine, 1)
	end

	local from = startSpec.reserve or 3
	local span = length - (endSpec.reserve or 3) - from
	local dashes = math.floor((span + 12) / 18)
	currentName = "Dash"
	for index = 1, dashes do
		local distance = from + (index - 0.5) * span / dashes
		clutter(makePart(parent, Vector3.new(0.6, markHeight, 6), look * CFrame.new(0, markY, at(distance)),
			MapDecor.CentreLineColor, Enum.Material.SmoothPlastic))
	end
	currentName = "Part"
end

-- A dropped kerb: where a driveway or a car park's aisle meets a street, the kerb between them comes
-- down to the carriageway's own height, so the way in reads as a way in and not as a car park behind
-- a kerb. `parent` holds the street's kerbs (its town); `centre` is any point on the line vehicles
-- cross the kerb along, `across` that line's level direction, and `halfWidth` half the opening.
--
-- Every kerb the line crosses square-on, within `reach` studs of `centre`, is cut into the kerb either
-- side of the opening and a lower piece across it: the same length, line and underside, its top at
-- RoadLift instead of standing 0.1 proud. Cut rather than laid over, so no two pieces share any
-- volume or face. The pavement behind stays as it is -- it's where people walk. Returns how many
-- kerbs it dropped.
function MapDecor.DropKerb(parent, centre, across, halfWidth, reach)
	reach = reach or 12
	local dropped = 0
	for _, kerb in ipairs(parent:GetChildren()) do
		if kerb.Name == "Kerb" and kerb:IsA("BasePart") then
			local cf, size = kerb.CFrame, kerb.Size
			-- The kerb's length is its longer level axis; the crossing has to run square across it.
			local lengthAxis = size.Z >= size.X and cf.LookVector or cf.RightVector
			local length = math.max(size.X, size.Z)
			local offset = kerb.Position - centre
			local along = offset.X * lengthAxis.X + offset.Z * lengthAxis.Z
			local out = offset.X * across.X + offset.Z * across.Z
			if math.abs(lengthAxis.X * across.X + lengthAxis.Z * across.Z) < 0.01 and math.abs(out) <= reach then
				-- The opening along the kerb, from the kerb's own middle, clipped to its ends.
				local o0 = math.max(-length / 2, -along - halfWidth)
				local o1 = math.min(length / 2, -along + halfWidth)
				if o1 - o0 > 0.05 then
					local frame = CFrame.lookAt(kerb.Position, kerb.Position + Vector3.new(lengthAxis.X, 0, lengthAxis.Z))
					local width, height = math.min(size.X, size.Z), size.Y
					local bottom = kerb.Position.Y - height / 2
					local function strip(name, from, to, top, color)
						if to - from > 0.05 then
							currentName = name
							-- Local -Z runs along lengthAxis, so a distance `d` along it is local z = -d.
							clutter(makePart(parent, Vector3.new(width, top - bottom, to - from),
								frame * CFrame.new(0, (bottom + top) / 2 - kerb.Position.Y, -(from + to) / 2), color, kerb.Material))
						end
					end
					strip("Kerb", -length / 2, o0, bottom + height, kerb.Color)
					strip("Kerb", o1, length / 2, bottom + height, kerb.Color)
					-- Down to the carriageway's top: every kerb starts KERB_SINK under the ground it
					-- stands on, as the asphalt beside it starts at that ground.
					strip("DroppedKerb", o0, o1, bottom + KERB_SINK + MapDecor.RoadLift, kerb.Color)
					kerb:Destroy()
					dropped += 1
				end
			end
		end
	end
	currentName = "Part"
	return dropped
end

-- A pavement cut for a way in wider than a driveway: a car park's aisle meets its street through a gap
-- in the pavement, where the car park lays an asphalt apron flush with the street and the dropped kerb
-- (ParkingLots), the way a real car park's entrance is road surface right across rather than a
-- driveway's crossing over the footway. Every Pavement piece the line crosses square-on, within `reach`
-- studs of `centre` (a point on the line, half way across the pavement), is replaced by the pieces
-- either side of the opening: the same section, line and height, so the pavement still runs up to the
-- way in from both sides and nothing is laid over anything. Returns how many pieces it cut.
function MapDecor.CutPavement(parent, centre, across, halfWidth, reach)
	reach = reach or 3
	local cut = 0
	for _, piece in ipairs(parent:GetChildren()) do
		if piece.Name == "Pavement" and piece:IsA("BasePart") then
			local cf, size = piece.CFrame, piece.Size
			local lengthAxis = size.Z >= size.X and cf.LookVector or cf.RightVector
			local length = math.max(size.X, size.Z)
			local offset = piece.Position - centre
			local along = offset.X * lengthAxis.X + offset.Z * lengthAxis.Z
			local out = offset.X * across.X + offset.Z * across.Z
			if math.abs(lengthAxis.X * across.X + lengthAxis.Z * across.Z) < 0.01 and math.abs(out) <= reach then
				local o0 = math.max(-length / 2, -along - halfWidth)
				local o1 = math.min(length / 2, -along + halfWidth)
				if o1 - o0 > 0.05 then
					local frame = CFrame.lookAt(piece.Position, piece.Position + Vector3.new(lengthAxis.X, 0, lengthAxis.Z))
					local width = math.min(size.X, size.Z)
					for _, span in ipairs({ { -length / 2, o0 }, { o1, length / 2 } }) do
						local from, to = span[1], span[2]
						if to - from > 0.05 then
							currentName = "Pavement"
							-- Local -Z runs along lengthAxis, as in DropKerb.
							clutter(makePart(parent, Vector3.new(width, size.Y, to - from), frame * CFrame.new(0, 0, -(from + to) / 2),
								piece.Color, piece.Material))
						end
					end
					piece:Destroy()
					cut += 1
				end
			end
		end
	end
	currentName = "Part"
	return cut
end

-- The box where streets or roads meet, and its corners, laid so every piece butts the arms
-- instead of lying over them. The arms stop at the box's edges (and their kerbs, pavements and
-- edge lines stop where the corners take over), so no two surfaces or markings ever share a face.
--
-- spec:
--   center     ground point in the middle of the box
--   bx, bz     half-extents of the box along X and Z: half the carriageway width of the arms
--              running along Z, and of the arms running along X
--   arms       { E = true, W = true, N = true, S = true } the arms that meet here (E is +X, N is +Z)
--   thickness  asphalt slab thickness; its top is RoadLift above the ground
--   sidewalkX  (towns) the width of kerb and pavement beyond bx, along the N/S streets
--   sidewalkZ  (towns) the same beyond bz, along the E/W streets
--   edgeInset  (country roads) edge lines this far in from the road's edge
--   joinInner  (bends) carry the inside edge lines on round the corner until they meet
--   queryable  (country roads) let raycasts hit the box and its lines, as they hit the roads
--
-- A side with no arm gets a kerb and pavement, or an edge line, straight across it, so a T or a
-- bend reads as one road turning rather than a box with a hole in its side.
function MapDecor.Junction(parent, spec)
	local base = CFrame.new(spec.center)
	local bx, bz = spec.bx, spec.bz
	local lift = MapDecor.RoadLift
	local thickness = spec.thickness or lift
	local arms = spec.arms

	-- An axis-aligned piece by its extents in the junction's own coordinates.
	local function piece(name, x0, x1, z0, z1, y0, y1, color, material)
		local sizeX, sizeZ = math.abs(x1 - x0), math.abs(z1 - z0)
		if sizeX < 0.02 or sizeZ < 0.02 then
			return
		end
		currentName = name
		local p = clutter(makePart(parent, Vector3.new(sizeX, y1 - y0, sizeZ), base * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, material))
		p.CanQuery = spec.queryable == true
	end

	piece("JunctionAsphalt", -bx, bx, -bz, bz, lift - thickness, lift, MapDecor.AsphaltColor, Enum.Material.Asphalt)

	local swx, swz = spec.sidewalkX or 0, spec.sidewalkZ or 0
	local inset = spec.edgeInset
	local lw = MapDecor.EdgeLineWidth / 2
	local markLow, markHigh = lift, lift + MARK_RAISE
	for _, quadrant in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
		local sx, sz = quadrant[1], quadrant[2]
		-- The arm along X on this side of the box, and the arm along Z on this side.
		local armX = arms[sx > 0 and "E" or "W"]
		local armZ = arms[sz > 0 and "N" or "S"]

		if swx > 0 or swz > 0 then
			local function kerb(x0, x1, z0, z1)
				piece("Kerb", sx * x0, sx * x1, sz * z0, sz * z1, -0.06, 0.5, KERB_COLOR, Enum.Material.Concrete)
			end
			local function pave(x0, x1, z0, z1)
				piece("Pavement", sx * x0, sx * x1, sz * z0, sz * z1, -0.06, 0.35, PAVEMENT_COLOR, Enum.Material.Pavement)
			end
			if armX and armZ then
				-- A corner: kerb round both sides and a square of pavement.
				kerb(bx, bx + swx, bz, bz + KERB)
				kerb(bx, bx + KERB, bz + KERB, bz + swz)
				pave(bx + KERB, bx + swx, bz + KERB, bz + swz)
			elseif armX then
				-- No arm along Z here: the X street's kerb and pavement run straight across.
				kerb(0, bx + swx, bz, bz + KERB)
				pave(0, bx + swx, bz + KERB, bz + swz)
			elseif armZ then
				kerb(bx, bx + KERB, 0, bz + swz)
				pave(bx + KERB, bx + swx, 0, bz + swz)
			else
				-- The outside of a bend: kerb and pavement round the box's corner.
				kerb(0, bx + KERB, bz, bz + KERB)
				kerb(bx, bx + KERB, 0, bz)
				pave(0, bx + swx, bz + KERB, bz + swz)
				pave(bx + KERB, bx + swx, 0, bz + KERB)
			end
		end

		if inset then
			local lineZ, lineX = bz - inset, bx - inset
			local function alongX(x0, x1)
				piece("RoadEdge", sx * x0, sx * x1, sz * (lineZ - lw), sz * (lineZ + lw), markLow, markHigh, MapDecor.EdgeLineColor, Enum.Material.SmoothPlastic)
			end
			local function alongZ(z0, z1)
				piece("RoadEdge", sx * (lineX - lw), sx * (lineX + lw), sz * z0, sz * z1, markLow, markHigh, MapDecor.EdgeLineColor, Enum.Material.SmoothPlastic)
			end
			if armX and armZ then
				if spec.joinInner then
					-- The inside of a bend: both edge lines carry on to meet, the X one taking the
					-- corner square.
					alongX(lineX - lw, bx)
					alongZ(lineZ + lw, bz)
				end
			elseif armX then
				alongX(0, bx)
			elseif armZ then
				alongZ(0, bz)
			else
				alongX(0, lineX + lw)
				alongZ(0, lineZ - lw)
			end
		end
	end
	currentName = "Part"
end

--------------------------------------------------------------------------------
-- Traffic control
--------------------------------------------------------------------------------

local SIGNAL_POLE = Color3.fromRGB(66, 68, 74)
local SIGNAL_BODY = Color3.fromRGB(32, 32, 36)
local SIGNAL_PLATE = Color3.fromRGB(16, 16, 18)
local SIGN_POST = Color3.fromRGB(150, 152, 156)

-- How a traffic light cycles, in seconds. Approaches along X show green for `green`, then amber,
-- then red while the Z approaches take their turn; `allRed` is the pause with every approach on red
-- between the two. Written onto every lamp as attributes, which TrafficClient reads, so this is
-- the only place the timing lives.
MapDecor.SignalTiming = { green = 9, amber = 2.5, allRed = 1.5 }
MapDecor.SignalLampColors = {
	red = { on = Color3.fromRGB(255, 56, 44), off = Color3.fromRGB(64, 22, 20) },
	amber = { on = Color3.fromRGB(255, 178, 36), off = Color3.fromRGB(70, 50, 18) },
	green = { on = Color3.fromRGB(60, 255, 120), off = Color3.fromRGB(18, 58, 32) },
}

-- Which lamp of a signal on `axis` ("x" or "z") is lit `t` seconds into its junction's cycle.
function MapDecor.SignalState(axis, t)
	local timing = MapDecor.SignalTiming
	local half = timing.green + timing.amber + timing.allRed
	t %= half * 2
	if axis == "z" then
		t = (t + half) % (half * 2)
	end
	if t < timing.green then
		return "green"
	elseif t < timing.green + timing.amber then
		return "amber"
	end
	return "red"
end

-- A signal head: housing, backplate, and red, amber and green lamps under visors, facing
-- `facing` (toward the traffic it controls).
local function signalHead(parent, centre, facing, axis, phase)
	local frame = CFrame.lookAt(centre, centre + facing)
	currentName = "SignalHousing"
	clutter(makePart(parent, Vector3.new(1.5, 4.3, 1.2), frame, SIGNAL_BODY, Enum.Material.SmoothPlastic))
	currentName = "SignalBackplate"
	clutter(makePart(parent, Vector3.new(2.5, 5.2, 0.15), frame * CFrame.new(0, 0, 0.68), SIGNAL_PLATE, Enum.Material.SmoothPlastic))
	local lit = MapDecor.SignalState(axis, phase)
	local timing = MapDecor.SignalTiming
	for index, kind in ipairs({ "red", "amber", "green" }) do
		local y = (2 - index) * 1.35
		local colors = MapDecor.SignalLampColors[kind]
		currentName = "SignalLamp"
		-- A cylinder runs along its X; the quarter turn points it at the traffic. It sits 0.02 into
		-- the housing's face.
		local lamp = clutter(makePart(parent, Vector3.new(0.3, 1.05, 1.05), frame * CFrame.new(0, y, -0.73) * CFrame.Angles(0, math.pi / 2, 0),
			lit == kind and colors.on or colors.off, lit == kind and Enum.Material.Neon or Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))
		lamp:SetAttribute("Lamp", kind)
		lamp:SetAttribute("Axis", axis)
		lamp:SetAttribute("Phase", phase)
		lamp:SetAttribute("GreenTime", timing.green)
		lamp:SetAttribute("AmberTime", timing.amber)
		lamp:SetAttribute("AllRedTime", timing.allRed)
		lamp:SetAttribute("OnColor", colors.on)
		lamp:SetAttribute("OffColor", colors.off)
		CollectionService:AddTag(lamp, "TrafficLamp")
		currentName = "SignalVisor"
		clutter(makePart(parent, Vector3.new(1.25, 0.1, 0.6), frame * CFrame.new(0, y + 0.6, -0.9), SIGNAL_BODY, Enum.Material.SmoothPlastic))
	end
end

-- A traffic light on the far corner of a junction: a pole, a mast arm reaching `armLength` out
-- along `armDirection` with a head hung over the approaching lane, and a second head on the pole.
-- `axis` and `phase` are the junction's (see SignalTiming).
function MapDecor.TrafficSignal(parent, base, facing, armDirection, armLength, axis, phase)
	currentName = "SignalPole"
	column(parent, 15.5, 0.9, base, SIGNAL_POLE, Enum.Material.Metal)
	local armCentre = base + Vector3.new(0, 15, 0) + armDirection * (armLength / 2)
	currentName = "SignalMastArm"
	clutter(makePart(parent, Vector3.new(0.5, 0.5, armLength), CFrame.lookAt(armCentre, armCentre + armDirection), SIGNAL_POLE, Enum.Material.Metal))
	local hangAt = base + armDirection * (armLength - 0.5)
	currentName = "SignalHanger"
	clutter(makePart(parent, Vector3.new(0.25, 0.7, 0.25), CFrame.new(hangAt + Vector3.new(0, 14.4, 0)), SIGNAL_POLE, Enum.Material.Metal))
	signalHead(parent, hangAt + Vector3.new(0, 11.9, 0), facing, axis, phase)

	-- The pole head, out in front of the pole on a short bracket.
	local poleHead = base + facing * 1.85 + Vector3.new(0, 8.2, 0)
	local bracket = base + facing * 0.77 + Vector3.new(0, 8.2, 0)
	currentName = "SignalBracket"
	clutter(makePart(parent, Vector3.new(0.3, 0.3, 0.64), CFrame.lookAt(bracket, bracket + facing), SIGNAL_POLE, Enum.Material.Metal))
	signalHead(parent, poleHead, facing, axis, phase)
	currentName = "Part"
end

local function faceText(part, text, color, face, font)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.3
	gui.MaxDistance = 200
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = font
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.Parent = gui
	gui.Parent = part
end

-- A flat regular octagon `across` wide between opposite flats, in the plane of `frame` (facing
-- its -Z): a band across the middle, a block above and below, and a triangle in each corner.
-- Returns the band.
local function octagon(parent, frame, across, thickness, color, name)
	local side = across / (1 + math.sqrt(2))
	local cut = (across - side) / 2
	currentName = name
	local band = clutter(makePart(parent, Vector3.new(across, side, thickness), frame, color, Enum.Material.SmoothPlastic))
	for _, sign in ipairs({ 1, -1 }) do
		clutter(makePart(parent, Vector3.new(side, cut, thickness), frame * CFrame.new(0, sign * (side + cut) / 2, 0), color, Enum.Material.SmoothPlastic))
	end
	for _, sx in ipairs({ 1, -1 }) do
		for _, sy in ipairs({ 1, -1 }) do
			local corner = (frame * CFrame.new(sx * side / 2, sy * side / 2, 0)).Position
			clutter(triangle(parent, corner, frame.RightVector, frame.UpVector, sx, sy, cut, cut, thickness, color, Enum.Material.SmoothPlastic))
		end
	end
	currentName = "Part"
	return band
end

local STOP_FONT = Enum.Font.FredokaOne
do
	local ok, font = pcall(function()
		return Enum.Font.GothamBlack
	end)
	if ok and font then
		STOP_FONT = font
	end
end

-- A stop sign on a post at `base`, facing `facing` (toward the traffic that has to stop): a red
-- octagon with a white border and STOP across it.
function MapDecor.StopSign(parent, base, facing)
	local postCentre = base + Vector3.new(0, 4.1, 0)
	currentName = "StopSignPost"
	makePart(parent, Vector3.new(0.3, 8.2, 0.3), CFrame.lookAt(postCentre, postCentre + facing), SIGN_POST, Enum.Material.Metal)
	local signCentre = base + Vector3.new(0, 7.4, 0)
	local frame = CFrame.lookAt(signCentre, signCentre + facing)
	octagon(parent, frame * CFrame.new(0, 0, -0.22), 3.3, 0.12, Color3.fromRGB(245, 245, 245), "StopSignBorder")
	local band = octagon(parent, frame * CFrame.new(0, 0, -0.35), 3, 0.12, Color3.fromRGB(196, 28, 32), "StopSign")
	faceText(band, "STOP", Color3.fromRGB(255, 255, 255), Enum.NormalId.Front, STOP_FONT)
end
MapDecor.StopSign = grouped("Sign", MapDecor.StopSign)

-- Lights or stop signs for a junction built by MapDecor.Junction with the same `spec`.
-- control.kind "signals": a light for every arm, on the far right-hand corner as the traffic
-- arriving along that arm sees it, its head hung over that traffic's lane; control.phase offsets
-- this junction's cycle. control.kind "stop": a stop sign on the near right of every arm in
-- control.stopArms. Traffic drives on the right.
function MapDecor.JunctionControl(parent, spec, control)
	local c = spec.center
	local swx, swz = spec.sidewalkX or 0, spec.sidewalkZ or 0
	local town = swx > 0 or swz > 0
	for name, present in pairs(spec.arms) do
		if present then
			local out = ARM_DIRECTION[name]
			local heading = -out
			local right = Vector3.new(-heading.Z, 0, heading.X)
			local alongX = out.Z == 0
			-- How far the box reaches along this arm, the arm's half-width, and the kerb-and-pavement
			-- widths of this arm and of the street it crosses.
			local reach = alongX and spec.bx or spec.bz
			local halfWidth = alongX and spec.bz or spec.bx
			local ownWalk = alongX and swz or swx
			local crossWalk = alongX and swx or swz
			if control.kind == "signals" then
				local along = town and reach + crossWalk / 2 or reach + 3.2
				local lateral = town and halfWidth + ownWalk / 2 or halfWidth + 3.2
				local base = c + heading * along + right * lateral
				local armLength = lateral - halfWidth / 2 + 0.5
				MapDecor.TrafficSignal(parent, base, out, -right, armLength, alongX and "x" or "z", control.phase or 0)
			elseif control.kind == "stop" and control.stopArms and control.stopArms[name] then
				local along = town and reach + crossWalk + 1.8 or reach + 4
				local lateral = town and halfWidth + KERB + (ownWalk - KERB) / 2 or halfWidth + 2.8
				MapDecor.StopSign(parent, c + out * along + right * lateral, out)
			end
		end
	end
end

-- A bench facing `target`.
local function benchFacing(parent, position, target)
	local look = CFrame.lookAt(position, Vector3.new(target.X, position.Y, target.Z))
	local wood = Color3.fromRGB(140, 98, 60)
	currentName = "Bench"
	makePart(parent, Vector3.new(6, 0.5, 2), look * CFrame.new(0, 2.1, 0), wood, Enum.Material.WoodPlanks)
	-- The back rests on the seat (it stood 0.05 clear of it).
	makePart(parent, Vector3.new(6, 1.8, 0.4), look * CFrame.new(0, 3.2, 0.9), wood, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -2.5, 2.5 }) do
		makePart(parent, Vector3.new(0.4, 2, 1.8), look * CFrame.new(x, 1, 0), METAL_DARK, Enum.Material.Metal)
	end
	currentName = "Part"
end

--------------------------------------------------------------------------------
-- The roundabout at the middle of every town (Oliver 09-24: "make high quality roundabouts around the
-- fountain at the center of the towns ... make it look good and natural like it's always been there").
--
-- Laid out in plan round the town centre O:
--   island     a raised round island, radius `island`: a low mountable kerb, a ring of granite setts
--              (the truck apron), a taller inner kerb, a planted bed, and the town's fountain on a
--              paved plinth in the middle
--   ring       the circulating carriageway from `island` to `outer`, wide enough for the longest
--              vehicle to go round
--   approaches the four streets (E, N, W, S) start `approach` out, and between them and the ring the
--              kerb curves away on a fillet of radius `fillet` tangent to both the street's kerb line
--              and the ring's outer kerb, so the kerb line runs street, curve, ring with no corner
--   splitters  a raised island on each approach's centre line from the ring to the street, with a
--              keep-right bollard at its nose and a give-way sign
-- Traffic drives on the right, so it goes round anticlockwise seen from above (decreasing angle
-- atan2(z, x)) and enters on the approach's right-hand side (v < 0 in an arm's own frame, where
-- u runs out along the arm and v is its left).
--
-- Everything drivable is one fan of flat triangles from O out to the outline (ring, fillets and street
-- ends): the outline is star-shaped from O for every size here, so the fan tiles it exactly, each
-- triangle's edges shared with its neighbours and never a face in the same plane as another. The
-- kerbs and pavements round the outline are bands of pieces whose road-side edges are exactly the
-- fan's outline edges. The island stands on the fan (hidden under it) rather than cut out of it.
-- Surfaces don't collide and don't take raycasts, like the streets; the island, fountain, posts and
-- lamps do.
--------------------------------------------------------------------------------

-- Sizes by class, modelled on a real single-lane town roundabout: the raised island's radius, the
-- overrun apron of setts round it (long vehicles' rear wheels run up on it), the asphalt ring's width,
-- the approach fillet's radius and the splitter's half-width at the ring. The ring is sized for the
-- biggest vehicle, not the average car: the Sahur Van is 9 wide with its mirrors, and the ring is that
-- plus 4 (tools/roundabout_check.py, geometry); the Camelo Carrier (17.6 long) goes all the way round
-- with its body off the island kerb and inside the outer kerb.
local ROUNDABOUT_SIZES = {
	small = { island = 12.5, apron = 4, lane = 13, fillet = 20, splitter = 1.2 },
	medium = { island = 14.5, apron = 4, lane = 13, fillet = 22, splitter = 1.2 },
	large = { island = 17, apron = 4.5, lane = 13, fillet = 26, splitter = 1.3 },
}
-- A village's roundabout is small, a city's large; every other kind of town is medium.
local ROUNDABOUT_CLASS = { rural = "small", neighbourhood = "small", downtown = "large", industrial = "large" }
MapDecor.RoundaboutSizes = ROUNDABOUT_SIZES
MapDecor.RoundaboutClass = ROUNDABOUT_CLASS
-- Parts one roundabout may use, fountain and furniture included (tools/roundabout_check.py).
MapDecor.RoundaboutBudget = 1250
-- The fountain's basin plinth, which the island has to hold with a planted ring round it.
local PLINTH_RADIUS = 10.8
-- Arms by the angle they leave O at (atan2(z, x)), in the order the outline walks them.
local ARM_ANGLE = { E = 0, N = math.pi / 2, W = math.pi, S = 3 * math.pi / 2 }
local ARM_ORDER = { "E", "N", "W", "S" }
MapDecor.RoundaboutArms = ARM_ORDER

-- The layout for a town of `kind` whose streets are `streetHalf` either side of their centre line
-- with `sidewalk` of kerb and pavement beyond. `approach` is where the streets start (MapGenerator
-- lays them from there), `reach` how far from O anything of the roundabout goes.
function MapDecor.RoundaboutSpec(kind, streetHalf, sidewalk)
	local class = ROUNDABOUT_CLASS[kind] or "medium"
	local size = ROUNDABOUT_SIZES[class]
	local island, fillet = size.island, size.fillet
	local outer = island + size.apron + size.lane
	local h = streetHalf
	-- The fillet's centre is (approach, h + fillet) in an arm's frame: `fillet` off the kerb line and
	-- `outer + fillet` from O, so it touches both.
	local approach = math.sqrt((outer + fillet) ^ 2 - (h + fillet) ^ 2)
	return {
		class = class,
		island = island,
		outer = outer,
		lane = size.lane,
		fillet = fillet,
		half = h,
		sidewalk = sidewalk,
		approach = approach,
		-- Half the angle an approach's mouth spans at O, between the two fillets' tangent points.
		mouth = math.atan2(h + fillet, approach),
		splitter = size.splitter,
		apron = size.apron,
		reach = math.sqrt(approach * approach + (h + sidewalk) ^ 2),
		-- The circulating path's radius, down the middle of the ring.
		circulate = island + size.apron + size.lane / 2,
		-- The apron's outer edge, where the asphalt starts.
		apronOuter = island + size.apron,
	}
end

-- An arm's frame: `u` out along it from O, `v` to its left (anticlockwise).
local function armPoint(centre, angle, u, v)
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(centre.X + c * u - s * v, centre.Y, centre.Z + s * u + c * v)
end

local function polar(centre, angle, radius, y)
	return Vector3.new(centre.X + math.cos(angle) * radius, y or centre.Y, centre.Z + math.sin(angle) * radius)
end

-- Evenly split angles from a0 to a1, no step over `maxStep`.
local function angleSteps(a0, a1, maxStep)
	local count = math.max(1, math.ceil(math.abs(a1 - a0) / maxStep - 1e-9))
	local list = {}
	for index = 0, count do
		table.insert(list, a0 + (a1 - a0) * index / count)
	end
	return list
end

-- The drivable outline, walked round O by increasing angle, and the kerb runs along it. Each run is
-- { centre, angles, radius, outward }: the kerb's road-side edge is the chord polygon at `radius` round
-- `centre` through `angles`; `outward` says the kerb and pavement lie outside that circle (the ring)
-- rather than inside it (a fillet, whose centre is off the road).
function MapDecor.RoundaboutOutline(spec, centre)
	local L, h, rf, ro, phi = spec.approach, spec.half, spec.fillet, spec.outer, spec.mouth
	local vertices, runs = {}, {}
	local function add(p)
		local last = vertices[#vertices]
		if not last or (Vector3.new(p.X - last.X, 0, p.Z - last.Z)).Magnitude > 1e-4 then
			table.insert(vertices, p)
		end
	end
	for index, name in ipairs(ARM_ORDER) do
		local theta = ARM_ANGLE[name]
		-- The right-hand fillet (as the traffic arriving sees it), from the ring to the street's kerb.
		local fMinus = armPoint(centre, theta, L, -(h + rf))
		local minus = {}
		for _, beta in ipairs(angleSteps(math.pi - phi, math.pi / 2, math.rad(10))) do
			table.insert(minus, theta + beta)
			add(polar(fMinus, theta + beta, rf))
		end
		table.insert(runs, { centre = fMinus, angles = minus, radius = rf, outward = false, arm = name, side = -1 })
		-- The street's end, across its asphalt, is the one edge from here to the other fillet: a vertex on
		-- the centre line would put two pieces' shared edge right down it.
		-- The left-hand fillet, from the street's kerb back to the ring.
		local fPlus = armPoint(centre, theta, L, h + rf)
		local plus = {}
		for _, beta in ipairs(angleSteps(-math.pi / 2, -(math.pi - phi), math.rad(10))) do
			table.insert(plus, theta + beta)
			add(polar(fPlus, theta + beta, rf))
		end
		table.insert(runs, { centre = fPlus, angles = plus, radius = rf, outward = false, arm = name, side = 1 })
		-- The ring's outer kerb on to the next arm.
		local ring = {}
		for _, angle in ipairs(angleSteps(theta + phi, theta + math.pi / 2 - phi, math.rad(8))) do
			table.insert(ring, angle)
			add(polar(centre, angle, ro))
		end
		table.insert(runs, { centre = centre, angles = ring, radius = ro, outward = true, gap = index })
	end
	-- The walk ends where it began (the first fillet's first point is the last ring's last).
	local first, last = vertices[1], vertices[#vertices]
	if (Vector3.new(first.X - last.X, 0, first.Z - last.Z)).Magnitude < 1e-4 then
		table.remove(vertices)
	end
	return vertices, runs
end

-- Claims the roundabout's ground in `space` before the town's buildings go up: the ring and its pavement,
-- each approach, and each fillet's pavement (which curves out behind the street's building line).
function MapDecor.RoundaboutClaim(space, spec, centre)
	local c = Vector3.new(centre.X, 0, centre.Z)
	space:AddCircle(c.X, c.Z, spec.outer + spec.sidewalk + 0.5)
	local _, runs = MapDecor.RoundaboutOutline(spec, c)
	for _, run in ipairs(runs) do
		if not run.outward then
			for _, angle in ipairs(angleSteps(run.angles[1], run.angles[#run.angles], 3 / run.radius)) do
				local at = polar(run.centre, angle, run.radius - spec.sidewalk / 2)
				space:AddCircle(at.X, at.Z, spec.sidewalk / 2 + 0.6)
			end
		end
	end
	for _, name in ipairs(ARM_ORDER) do
		local theta = ARM_ANGLE[name]
		local mid = armPoint(c, theta, (spec.outer + spec.approach) / 2, 0)
		space:AddRect(mid.X, mid.Z, (spec.approach - spec.outer) / 2 + 1, spec.half + spec.sidewalk, -theta)
		-- The corner's bench (or vendor) and flower bed; the flag's spot between them stays free for
		-- TownThemes, which asks.
		local alpha = theta + math.pi / 4
		local corner0 = spec.outer + spec.sidewalk
		local bench = polar(c, alpha, corner0 + 2.4)
		-- The same `across` as MapDecor.Roundabout's corners.
		local across = Vector3.new(-math.sin(alpha), 0, math.cos(alpha))
		for _, hand in ipairs({ -1, 1 }) do
			local at = bench + across * (hand * 1.9)
			space:AddCircle(at.X, at.Z, 1.3)
		end
		if name == "S" then
			local vendor = polar(c, alpha, corner0 + 3.2) + across * 4.6
			space:AddCircle(vendor.X, vendor.Z, 3.2)
		else
			local bin = bench + across * 4.2
			space:AddCircle(bin.X, bin.Z, 1.4)
		end
		local bed = polar(c, alpha, corner0 + 8.8)
		space:AddCircle(bed.X, bed.Z, 3)
	end
end

-- Any flat triangle `a`, `b`, `c` (their Y ignored) from `y0` to `y1`: the two right-angled wedges
-- either side of the altitude onto its longest side, which always lands inside that side.
local function flatTriangle(parent, a, b, c, y0, y1, color, material)
	local points = { Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z), Vector3.new(c.X, 0, c.Z) }
	local longest, at = -1, 1
	for index = 1, 3 do
		local d = (points[index % 3 + 1] - points[index]).Magnitude
		if d > longest then
			longest, at = d, index
		end
	end
	local p, q, r = points[at], points[at % 3 + 1], points[(at + 1) % 3 + 1]
	if longest < 0.02 then
		return {}
	end
	local u = (q - p) / longest
	local along = (r - p):Dot(u)
	local foot = p + u * along
	local altitude = (r - foot).Magnitude
	if altitude < 0.005 then
		return {}
	end
	local v = (r - foot) / altitude
	local lift = Vector3.new(0, (y0 + y1) / 2, 0)
	local made = {}
	if along > 0.005 then
		table.insert(made, triangle(parent, foot + lift, u, v, -1, 1, along, altitude, y1 - y0, color, material))
	end
	if longest - along > 0.005 then
		table.insert(made, triangle(parent, foot + lift, u, v, 1, 1, longest - along, altitude, y1 - y0, color, material))
	end
	return made
end

-- One piece of an annular band round `centre` between angles a0 and a1 and radii r0 < r1, from y0 to
-- y1: a rectangle on the inner chord and a wedge either side out to the outer chord, so its radial
-- edges lie exactly on the radii at a0 and a1 (RoadNetwork's curveBand, round any centre).
local function bandPiece(parent, centre, a0, a1, r0, r1, y0, y1, color, material)
	local mid = (a0 + a1) / 2
	local delta = math.abs(a1 - a0) / 2
	local cosD, sinD = math.cos(delta), math.sin(delta)
	local out = Vector3.new(math.cos(mid), 0, math.sin(mid))
	local side = Vector3.new(-math.sin(mid), 0, math.cos(mid))
	local base = Vector3.new(centre.X, (y0 + y1) / 2, centre.Z)
	local middle = base + out * ((r0 + r1) / 2 * cosD)
	local made = { makePart(parent, Vector3.new(2 * r0 * sinD, y1 - y0, (r1 - r0) * cosD), CFrame.lookAt(middle, middle + out), color, material) }
	if (r1 - r0) * sinD > 0.005 then
		local corner = base + out * (r1 * cosD)
		for _, hand in ipairs({ 1, -1 }) do
			table.insert(made, triangle(parent, corner + side * (hand * r0 * sinD), out, side, -1, hand, (r1 - r0) * cosD, (r1 - r0) * sinD,
				y1 - y0, color, material))
		end
	end
	return made
end

-- An upright disc (a Cylinder part turned on end) of `radius` from y0 to y1.
local function disc(parent, centre, radius, y0, y1, color, material)
	return makePart(parent, Vector3.new(y1 - y0, radius * 2, radius * 2),
		CFrame.new(centre.X, (y0 + y1) / 2, centre.Z) * CFrame.Angles(0, 0, math.pi / 2), color, material, Enum.PartType.Cylinder)
end

local function jitter(rng, color, amount)
	local d = rng:NextNumber(-amount, amount) / 255
	return Color3.new(math.clamp(color.R + d, 0, 1), math.clamp(color.G + d, 0, 1), math.clamp(color.B + d, 0, 1))
end

-- A bar from `a` to `b` (world points), `width` wide and `depth` deep, its depth along `normal`.
local function bar(parent, a, b, width, depth, normal, color, material)
	local length = (b - a).Magnitude
	local look = CFrame.lookAt((a + b) / 2, b, normal)
	return makePart(parent, Vector3.new(width, depth, length), look, color, material)
end

-- The fountain, standing on `base`: a twelve-sided marble basin with a coping, a tiled floor under
-- the water, the column and the upper bowl with its spray (or the town's statue in the bowl).
local MARBLE = Color3.fromRGB(226, 222, 214)
local WATER = Color3.fromRGB(70, 170, 220)
local function fountain(parent, base, statueDef, rng)
	local y = base.Y
	local centre = Vector3.new(base.X, 0, base.Z)
	currentName = "FountainWall"
	for index = 0, 11 do
		local a0, a1 = index / 12 * math.pi * 2, (index + 1) / 12 * math.pi * 2
		bandPiece(parent, centre, a0, a1, 8.0, 9.4, y - 0.1, y + 1.9, jitter(rng, MARBLE, 5), Enum.Material.Marble)
		currentName = "FountainCoping"
		bandPiece(parent, centre, a0, a1, 7.75, 9.65, y + 1.8, y + 2.15, MARBLE, Enum.Material.Marble)
		currentName = "FountainWall"
	end
	currentName = "FountainFloor"
	disc(parent, centre, 8.05, y - 0.1, y + 0.12, Color3.fromRGB(64, 128, 138), Enum.Material.Slate)
	currentName = "FountainPool"
	local pool = clutter(disc(parent, centre, 8.1, y + 0.3, y + 1.55, WATER, Enum.Material.Glass))
	pool.Transparency = 0.3
	currentName = "FountainColumn"
	column(parent, 5, 2, Vector3.new(base.X, y, base.Z), MARBLE, Enum.Material.Marble)
	currentName = "FountainBowl"
	makePart(parent, Vector3.new(0.8, 7, 7), CFrame.new(base + Vector3.new(0, 5.2, 0)) * CFrame.Angles(0, 0, math.pi / 2), MARBLE,
		Enum.Material.Marble, Enum.PartType.Cylinder)
	local bowl = clutter(makePart(parent, Vector3.new(0.3, 6, 6), CFrame.new(base + Vector3.new(0, 5.55, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		WATER, Enum.Material.Glass, Enum.PartType.Cylinder))
	bowl.Transparency = 0.2
	-- Four low jets round the column, rising and falling out of the pool.
	currentName = "FountainJet"
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + math.pi / 4
		local jet = clutter(makePart(parent, Vector3.new(0.7, 0.7, 0.7), CFrame.new(polar(centre, angle, 4.6, y + 1.9)),
			Color3.fromRGB(180, 235, 255), Enum.Material.Neon, Enum.PartType.Ball))
		jet.Transparency = 0.25
		jet:SetAttribute("BobHeight", 0.3)
		jet:SetAttribute("BobSpeed", 2.5 + index * 0.4)
		jet:SetAttribute("BobPhase", index * 1.3)
		CollectionService:AddTag(jet, "AmbientBob")
	end
	currentName = "Part"
	if statueDef then
		-- The town's patron brainrot, well over life size, standing in the upper bowl.
		local scale = 2.6
		local size = statueDef.look and statueDef.look.size or 1
		local metrics = BrainrotModels.Metrics(statueDef)
		local statue = BrainrotModels.Build(statueDef, {
			scale = scale,
			cframe = CFrame.new(base + Vector3.new(0, 5.6 - metrics.bottom * scale * size, 0)) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
		})
		statue.Name = "Statue"
		statue.Parent = parent
	else
		for index, size in ipairs({ 1.4, 1.0, 0.6 }) do
			currentName = "FountainSpray"
			local spray = clutter(makePart(parent, Vector3.new(size, size, size), CFrame.new(base + Vector3.new(0, 5.5 + index * 1.05, 0)),
				Color3.fromRGB(180, 235, 255), Enum.Material.Neon, Enum.PartType.Ball))
			spray.Transparency = 0.2
			spray:SetAttribute("BobHeight", 0.35)
			spray:SetAttribute("BobSpeed", 3 + index)
			spray:SetAttribute("BobPhase", index)
			CollectionService:AddTag(spray, "AmbientBob")
		end
		currentName = "Part"
	end
end

-- A sign board shaped as an inverted triangle (give way), its top edge `width` across at `top`, facing
-- `facing`: a red triangle with a white one inset in front of it.
local function giveWaySign(parent, foot, facing, height)
	local right = Vector3.new(-facing.Z, 0, facing.X)
	currentName = "SignPost"
	column(parent, height, 0.25, foot - Vector3.new(0, 0.2, 0), Color3.fromRGB(150, 152, 156), Enum.Material.Metal)
	local topCentre = foot + Vector3.new(0, height + 0.1, 0) + facing * 0.16
	currentName = "GiveWaySign"
	for _, layer in ipairs({ { 1.2, 1.9, 0, Color3.fromRGB(200, 30, 36) }, { 0.8, 1.26, 0.09, Color3.fromRGB(244, 244, 240) } }) do
		local half, drop, ahead, color = layer[1], layer[2], layer[3], layer[4]
		local corner = topCentre + facing * ahead - Vector3.new(0, (1.9 - drop) * 0.45, 0)
		for _, hand in ipairs({ 1, -1 }) do
			clutter(triangle(parent, corner, right, Vector3.new(0, -1, 0), hand, 1, half, drop, 0.12, color, Enum.Material.SmoothPlastic))
		end
	end
	currentName = "Part"
end
giveWaySign = grouped("Sign", giveWaySign)

-- A keep-right bollard: a white post with a lit blue disc on top, an arrow down to the right as the
-- oncoming driver sees it.
local function keepRightBollard(parent, foot, facing)
	local right = Vector3.new(-facing.Z, 0, facing.X)
	-- The driver faces -facing, so their right is -right.
	currentName = "Bollard"
	column(parent, 2.0, 0.6, foot - Vector3.new(0, 0.1, 0), Color3.fromRGB(236, 236, 230), Enum.Material.SmoothPlastic)
	local centre = foot + Vector3.new(0, 2.6, 0)
	currentName = "BollardSign"
	-- The disc and its arrow don't collide: only the post stands in a car's way, over the splitter.
	local sign = clutter(makePart(parent, Vector3.new(0.14, 1.2, 1.2), CFrame.lookAt(centre, centre + facing) * CFrame.Angles(0, math.pi / 2, 0),
		Color3.fromRGB(30, 80, 190), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(150, 190, 255)
	glow.Range = 6
	glow.Brightness = 0.6
	glow.Parent = sign
	currentName = "BollardArrow"
	local front = centre + facing * 0.09
	local tip = front - right * 0.32 - Vector3.new(0, 0.32, 0)
	local tail = front + right * 0.32 + Vector3.new(0, 0.32, 0)
	clutter(bar(parent, tail, tip, 0.16, 0.06, facing, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic))
	clutter(bar(parent, tip, tip + Vector3.new(0, 0.36, 0), 0.16, 0.06, facing, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic))
	clutter(bar(parent, tip, tip + right * 0.36, 0.16, 0.06, facing, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic))
	currentName = "Part"
end
keepRightBollard = grouped("Sign", keepRightBollard)

-- The blue roundabout sign: a disc with three white arrows chasing round it (anticlockwise, the way the
-- traffic goes), `centre` its middle, facing `facing`. Doesn't collide; takes shots.
local function roundaboutDisc(parent, centre, facing)
	currentName = "RoundaboutSign"
	local disc = makePart(parent, Vector3.new(0.1, 1.5, 1.5), CFrame.lookAt(centre, centre + facing) * CFrame.Angles(0, math.pi / 2, 0),
		Color3.fromRGB(28, 84, 196), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	disc.CanCollide = false
	local right = Vector3.new(-facing.Z, 0, facing.X)
	local front = centre + facing * 0.07
	currentName = "RoundaboutArrow"
	for index = 0, 2 do
		local a = index / 3 * math.pi * 2
		local p0 = front + (right * math.cos(a) + Vector3.yAxis * math.sin(a)) * 0.45
		local a1 = a + 1.4
		local p1 = front + (right * math.cos(a1) + Vector3.yAxis * math.sin(a1)) * 0.45
		clutter(bar(parent, p0, p1, 0.14, 0.05, facing, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic))
		local tangent = (right * -math.sin(a1) + Vector3.yAxis * math.cos(a1))
		local outward = (right * math.cos(a1) + Vector3.yAxis * math.sin(a1))
		clutter(bar(parent, p1, p1 - tangent * 0.2 + outward * 0.18, 0.12, 0.05, facing, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic))
		clutter(bar(parent, p1, p1 - tangent * 0.2 - outward * 0.18, 0.12, 0.05, facing, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic))
	end
	currentName = "Part"
	return disc
end

-- A warning triangle (point up, red rim, white face) with the roundabout symbol, on its own post on the
-- pavement before an entry, facing the traffic arriving.
local function warningSign(parent, foot, facing)
	local right = Vector3.new(-facing.Z, 0, facing.X)
	currentName = "SignPost"
	column(parent, 5.1, 0.25, foot - Vector3.new(0, 0.2, 0), Color3.fromRGB(150, 152, 156), Enum.Material.Metal)
	local apex = foot + Vector3.new(0, 6.2, 0) + facing * 0.16
	currentName = "WarningSign"
	for _, layer in ipairs({ { 1.2, 2.0, 0, Color3.fromRGB(200, 30, 36) }, { 0.78, 1.3, 0.09, Color3.fromRGB(244, 244, 240) } }) do
		local half, drop, ahead, color = layer[1], layer[2], layer[3], layer[4]
		-- A right triangle each side of the altitude, the right angle at the middle of the base.
		local baseMid = apex + facing * ahead - Vector3.new(0, 2.0 - (2.0 - drop) * 0.45, 0)
		for _, hand in ipairs({ 1, -1 }) do
			clutter(triangle(parent, baseMid, right, Vector3.yAxis, hand, 1, half, drop, 0.12, color, Enum.Material.SmoothPlastic))
		end
	end
	currentName = "WarningSymbol"
	local centre = apex - Vector3.new(0, 1.25, 0) + facing * 0.155
	for index = 0, 2 do
		local a = index / 3 * math.pi * 2
		local p0 = centre + (right * math.cos(a) + Vector3.yAxis * math.sin(a)) * 0.3
		local p1 = centre + (right * math.cos(a + 1.5) + Vector3.yAxis * math.sin(a + 1.5)) * 0.3
		clutter(bar(parent, p0, p1, 0.1, 0.04, facing, Color3.fromRGB(24, 24, 28), Enum.Material.SmoothPlastic))
	end
	currentName = "Part"
end
warningSign = grouped("Sign", warningSign)

-- A chevron board on the island facing an entry: white, three black chevrons pointing the way the
-- traffic goes round (to the entering driver's right).
local function chevronBoard(parent, foot, facing)
	local right = Vector3.new(-facing.Z, 0, facing.X)
	local driverRight = -right
	currentName = "SignPost"
	for _, x in ipairs({ -2.1, 2.1 }) do
		column(parent, 3.3, 0.25, foot + right * x - Vector3.new(0, 0.3, 0), Color3.fromRGB(150, 152, 156), Enum.Material.Metal)
	end
	local centre = foot + Vector3.new(0, 2.3, 0) + facing * 0.18
	currentName = "ChevronBoard"
	makePart(parent, Vector3.new(5.6, 1.4, 0.16), CFrame.lookAt(centre, centre + facing), Color3.fromRGB(244, 244, 240), Enum.Material.SmoothPlastic)
	currentName = "Chevron"
	local front = centre + facing * 0.09
	for index = -1, 1 do
		local nose = front + driverRight * (index * 1.6 + 0.45)
		for _, up in ipairs({ 1, -1 }) do
			local back = nose - driverRight * 0.55 + Vector3.new(0, up * 0.52, 0)
			bar(parent, back, nose, 0.32, 0.05, facing, Color3.fromRGB(24, 24, 28), Enum.Material.SmoothPlastic)
		end
	end
	currentName = "Part"
end
chevronBoard = grouped("Sign", chevronBoard)

-- A street lamp for the ring in the town's colours: a plinth, the post with a collar in the town's
-- accent, an arm out over the road, a lit lantern, and a hanging basket of flowers.
local function ringLamp(parent, foot, facing, accent, flowers)
	currentName = "LampBase"
	column(parent, 1.1, 1.1, foot - Vector3.new(0, 0.1, 0), METAL_DARK, Enum.Material.Metal)
	currentName = "LampPost"
	column(parent, 13.4, 0.55, foot + Vector3.new(0, 0.9, 0), METAL_DARK, Enum.Material.Metal)
	currentName = "LampCollar"
	column(parent, 0.5, 0.75, foot + Vector3.new(0, 3.2, 0), accent, Enum.Material.Metal)
	local top = foot + Vector3.new(0, 13.9, 0)
	local look = CFrame.lookAt(top, top + facing)
	currentName = "LampArm"
	makePart(parent, Vector3.new(0.3, 0.3, 3.6), look * CFrame.new(0, 0, -1.6), METAL_DARK, Enum.Material.Metal)
	currentName = "LampHood"
	makePart(parent, Vector3.new(1.9, 0.35, 1.5), look * CFrame.new(0, -0.1, -3.4), accent, Enum.Material.Metal)
	currentName = "Lamp"
	local lamp = clutter(makePart(parent, Vector3.new(1.5, 0.35, 1.1), look * CFrame.new(0, -0.44, -3.4), LAMP_GLOW, Enum.Material.Neon))
	local light = Instance.new("PointLight")
	light.Color = LAMP_GLOW
	light.Range = 26
	light.Brightness = 1.4
	light.Parent = lamp
	currentName = "BasketBracket"
	makePart(parent, Vector3.new(0.18, 0.18, 1.2), look * CFrame.new(0, -6.2, 0.75), METAL_DARK, Enum.Material.Metal)
	currentName = "FlowerBasket"
	clutter(makePart(parent, Vector3.new(1.5, 1.2, 1.5), look * CFrame.new(0, -6.8, 1.5), flowers, Enum.Material.Grass, Enum.PartType.Ball))
	currentName = "Part"
end
ringLamp = grouped("Lamp", ringLamp)

-- A zebra crossing's beacon: a black-and-white pole with an amber globe, lit.
local function beacon(parent, foot)
	currentName = "BeaconPole"
	column(parent, 7.2, 0.36, foot - Vector3.new(0, 0.1, 0), Color3.fromRGB(240, 240, 236), Enum.Material.SmoothPlastic)
	currentName = "BeaconBand"
	for index = 0, 2 do
		column(parent, 0.7, 0.4, foot + Vector3.new(0, 1.2 + index * 1.9, 0), Color3.fromRGB(26, 26, 28), Enum.Material.SmoothPlastic)
	end
	currentName = "BeaconGlobe"
	local globe = makePart(parent, Vector3.new(1.1, 1.1, 1.1), CFrame.new(foot + Vector3.new(0, 7.55, 0)), Color3.fromRGB(255, 170, 40),
		Enum.Material.Neon, Enum.PartType.Ball)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 170, 60)
	light.Range = 9
	light.Brightness = 0.8
	light.Parent = globe
	currentName = "Part"
end
beacon = grouped("Beacon", beacon)

-- A round bed of flowers on a corner of the roundabout: a low stone edge, soil, and flowers.
local function flowerBed(parent, centre, rng, colors)
	currentName = "BedEdge"
	disc(parent, centre, 2.6, centre.Y - 0.1, centre.Y + 0.55, Color3.fromRGB(168, 160, 146), Enum.Material.Slate)
	currentName = "BedSoil"
	disc(parent, centre, 2.2, centre.Y + 0.2, centre.Y + 0.62, Color3.fromRGB(86, 62, 44), Enum.Material.Ground)
	currentName = "Shrub"
	clutter(makePart(parent, Vector3.new(2.2, 1.9, 2.2), CFrame.new(centre + Vector3.new(0, 1.2, 0)), Color3.fromRGB(62, 116, 56),
		Enum.Material.Grass, Enum.PartType.Ball))
	currentName = "Flowers"
	for index = 0, 4 do
		local angle = index / 5 * math.pi * 2 + rng:NextNumber(0, 0.6)
		clutter(makePart(parent, Vector3.new(0.9, 0.7, 0.9), CFrame.new(polar(centre, angle, 1.55, centre.Y + 0.8)), colors[index % #colors + 1],
			Enum.Material.SmoothPlastic, Enum.PartType.Ball))
	end
	currentName = "Part"
end
flowerBed = grouped("Planter", flowerBed)

-- A small tree for a big island: a trunk and two rounds of leaves.
local function islandTree(parent, foot, rng)
	currentName = "TreeTrunk"
	column(parent, 5.2, 0.7, foot - Vector3.new(0, 0.3, 0), Color3.fromRGB(104, 78, 56), Enum.Material.Wood)
	currentName = "TreeLeaves"
	local green = Color3.fromRGB(70 + rng:NextInteger(-8, 8), 128 + rng:NextInteger(-10, 10), 58)
	makePart(parent, Vector3.new(4.4, 3.6, 4.4), CFrame.new(foot + Vector3.new(0, 5.6, 0)), green, Enum.Material.Grass, Enum.PartType.Ball)
	makePart(parent, Vector3.new(3.0, 2.6, 3.0), CFrame.new(foot + Vector3.new(0.5, 7.2, -0.3)), green, Enum.Material.Grass, Enum.PartType.Ball)
	currentName = "Part"
end
islandTree = grouped("Tree", islandTree)

MapDecor.RoundaboutPieces = {
	surface = { RingAsphalt = true },
	marks = { GiveWay = true, GiveWayTriangle = true, EdgeLine = true, RingArrow = true, Drain = true, DrainChannel = true, Manhole = true,
		Tactile = true },
}

local KERB_TOP, PAVEMENT_TOP = 0.5, 0.35
local ROUNDABOUT_MARK = Color3.fromRGB(238, 236, 228)

-- The whole roundabout round `center` (its Y ignored: surfaces stand on the town's ground at 0, like the
-- streets), laid out by `spec` (MapDecor.RoundaboutSpec). `options`: statueDef, accent and trim
-- (the town's colours), groundHeightAt, space (corner furniture claims its spots). Returns the model and
-- loot spots { heal, weapon, item }.
function MapDecor.Roundabout(parent, center, spec, options)
	options = options or {}
	local model = Instance.new("Model")
	model.Name = "Roundabout"
	model.Parent = parent
	local c = Vector3.new(center.X, 0, center.Z)
	local rng = Random.new((math.floor(center.X * 31 + center.Z * 17) % 2147483000) + 7)
	local lift = MapDecor.RoadLift
	local ri, ro, rf, L, h = spec.island, spec.outer, spec.fillet, spec.approach, spec.half
	local sidewalk = spec.sidewalk
	local accent = options.accent or Color3.fromRGB(40, 90, 60)
	local trim = options.trim or Color3.fromRGB(220, 190, 90)
	local blooms = { accent, trim, Color3.fromRGB(255, 96, 140), Color3.fromRGB(255, 214, 70), Color3.fromRGB(245, 245, 245) }
	for key, value in pairs({ Class = spec.class, Island = ri, Outer = ro, Fillet = rf, Approach = L, StreetHalf = h, Sidewalk = sidewalk,
		Circulate = spec.circulate, Splitter = spec.splitter, ApronOuter = spec.apronOuter }) do
		model:SetAttribute(key, value)
	end
	model:SetAttribute("Center", c)

	-- The carriageway: one fan from O to the outline.
	local vertices, runs = MapDecor.RoundaboutOutline(spec, c)
	currentName = "RingAsphalt"
	for index = 1, #vertices do
		local a, b = vertices[index], vertices[index % #vertices + 1]
		for _, wedge in ipairs(flatTriangle(model, c, a, b, 0, lift, MapDecor.AsphaltColor, Enum.Material.Asphalt)) do
			clutter(wedge)
		end
	end

	-- Kerbs and pavements round the outline, their road-side edges on the fan's.
	for _, run in ipairs(runs) do
		for index = 1, #run.angles - 1 do
			local a0, a1 = run.angles[index], run.angles[index + 1]
			local kerb0, kerb1, walk0, walk1
			if run.outward then
				kerb0, kerb1, walk0, walk1 = run.radius, run.radius + KERB, run.radius + KERB, run.radius + sidewalk
			else
				kerb0, kerb1, walk0, walk1 = run.radius - KERB, run.radius, run.radius - sidewalk, run.radius - KERB
			end
			currentName = "Kerb"
			for _, piece in ipairs(bandPiece(model, run.centre, a0, a1, kerb0, kerb1, -0.06, KERB_TOP, jitter(rng, KERB_COLOR, 6), Enum.Material.Concrete)) do
				clutter(piece)
			end
			currentName = "Pavement"
			for _, piece in ipairs(bandPiece(model, run.centre, a0, a1, walk0, walk1, -0.06, PAVEMENT_TOP, PAVEMENT_COLOR, Enum.Material.Pavement)) do
				clutter(piece)
			end
		end
	end

	-- The solid white edge line 1.3 in from the outer kerb (the gully grates sit in the channel outside it), round the ring and on round each fillet to
	-- the street, broken only across the mouths: chords of its own circle, each trimmed so neighbours
	-- meet at their inside corners rather than overlap.
	for _, run in ipairs(runs) do
		local radius = run.outward and run.radius - 1.3 or run.radius + 1.3
		for index = 1, #run.angles - 1 do
			local a0, a1 = run.angles[index], run.angles[index + 1]
			local p0, p1 = polar(run.centre, a0, radius, lift + MapDecor.MarkRaise / 2), polar(run.centre, a1, radius, lift + MapDecor.MarkRaise / 2)
			local trim = 0.25 * math.abs(math.tan((a1 - a0) / 2)) + 0.005
			local length = (p1 - p0).Magnitude - 2 * trim
			if length > 0.05 then
				currentName = "EdgeLine"
				clutter(makePart(model, Vector3.new(0.5, MapDecor.MarkRaise, length), CFrame.lookAt((p0 + p1) / 2, p1), ROUNDABOUT_MARK, Enum.Material.SmoothPlastic))
			end
		end
	end

	-- The island, stood on the fan: the overrun apron of dark setts (a hair proud of the road, mountable,
	-- not colliding, like every kerb here), the island's raised kerb, the grass bed and the fountain's
	-- plinth, each a disc standing prouder than the one round it.
	local bedRadius = ri - 0.7
	currentName = "IslandApron"
	clutter(disc(model, c, spec.apronOuter, 0.2, lift + 0.06, Color3.fromRGB(96, 90, 86), Enum.Material.Cobblestone))
	currentName = "IslandKerb"
	disc(model, c, ri, -0.06, 0.62, KERB_COLOR, Enum.Material.Concrete)
	currentName = "IslandBed"
	disc(model, c, bedRadius, 0.3, 0.95, Color3.fromRGB(84, 128, 60), Enum.Material.Grass)
	currentName = "FountainPlinth"
	disc(model, c, PLINTH_RADIUS, 0.5, 1.2, Color3.fromRGB(206, 200, 188), Enum.Material.Pavement)
	fountain(model, c + Vector3.new(0, 1.2, 0), options.statueDef, rng)
	-- Low stone bollards round the island's edge, between the chevron boards: nothing tall.
	currentName = "IslandBollard"
	for index = 0, 7 do
		column(model, 1.3, 0.6, polar(c, index / 8 * math.pi * 2 + math.pi / 8, ri - 0.45, 0.4), Color3.fromRGB(196, 192, 182), Enum.Material.Granite)
	end

	-- Planting round the plinth: shrubs and clumps of flowers in the bed, and on a big island four
	-- small trees on the diagonals.
	local plantRadius = (PLINTH_RADIUS + bedRadius) / 2
	local clumps = math.floor(plantRadius * 1.1)
	for index = 0, clumps - 1 do
		local angle = (index + rng:NextNumber(-0.25, 0.25)) / clumps * math.pi * 2
		local shrub = index % 3 == 0
		currentName = shrub and "Shrub" or "Flowers"
		local size = shrub and rng:NextNumber(1.3, 1.8) or rng:NextNumber(0.9, 1.3)
		clutter(makePart(model, Vector3.new(size, size * 0.8, size), CFrame.new(polar(c, angle, plantRadius + rng:NextNumber(-0.2, 0.2), 1.0 + size * 0.2)),
			shrub and Color3.fromRGB(58, 108 + rng:NextInteger(-8, 8), 52) or blooms[rng:NextInteger(1, #blooms)],
			shrub and Enum.Material.Grass or Enum.Material.SmoothPlastic, Enum.PartType.Ball))
	end
	if spec.class == "large" then
		for index = 0, 3 do
			islandTree(model, polar(c, index / 4 * math.pi * 2 + math.pi / 4, plantRadius, 0.95), rng)
		end
	end
	-- Weeds come up between the setts, and moss on the kerb.
	currentName = "Weed"
	for _ = 1, 5 do
		clutter(makePart(model, Vector3.new(0.5, 0.3, 0.5), CFrame.new(polar(c, rng:NextNumber(0, math.pi * 2), ri + 0.4, lift + 0.06)),
			Color3.fromRGB(96, 136, 62), Enum.Material.Grass, Enum.PartType.Ball))
	end
	currentName = "Moss"
	for _ = 1, 3 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local at = polar(c, angle, ri - 0.35, 0.635)
		clutter(makePart(model, Vector3.new(0.4, 0.03, rng:NextNumber(0.8, 1.6)), CFrame.lookAt(at, at + Vector3.new(-math.sin(angle), 0, math.cos(angle))),
			Color3.fromRGB(88, 118, 60), Enum.Material.Grass))
	end

	local markTop = lift + MapDecor.MarkRaise
	local function mark(size, cframe, color, name)
		currentName = name
		local part = clutter(makePart(model, size, cframe, color or ROUNDABOUT_MARK, Enum.Material.SmoothPlastic))
		return part
	end
	-- A flat marking bar at radius `radius` round O, centred on `angle`, `length` along the ring.
	local function arcMark(angle, radius, length, width, name, transparency)
		local at = polar(c, angle, radius, lift + MapDecor.MarkRaise / 2)
		local along = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		local part = mark(Vector3.new(width, MapDecor.MarkRaise, length), CFrame.lookAt(at, at + along), nil, name)
		part.Transparency = transparency or 0
		return part
	end

	for _, name in ipairs(ARM_ORDER) do
		local theta = ARM_ANGLE[name]
		local out = Vector3.new(math.cos(theta), 0, math.sin(theta))
		local fMinus = armPoint(c, theta, L, -(h + rf))
		-- The arm-relative angle (negative, on the entry side) at `radius` where the ring's edge gets
		-- within `clear` of the entry's kerb.
		local function entryLimit(radius, clear)
			local alpha = -math.asin(math.min(1, (spec.splitter + 0.45) / radius))
			while alpha > -spec.mouth * 1.5 do
				local p = polar(c, theta + alpha, radius)
				if (Vector3.new(p.X - fMinus.X, 0, p.Z - fMinus.Z)).Magnitude < rf + clear then
					return alpha
				end
				alpha -= 0.005
			end
			return alpha
		end

		-- The splitter island: a raised kerb from the ring to the street, tapering to a nose, topped
		-- with setts (grass on the bigger ones), and a keep-right bollard at the nose.
		local s = spec.splitter
		-- A teardrop: it stops 6 short of the street, where a long vehicle leaving needs the middle of the road.
		local u0, u1 = ro + 1.2, L - 6
		local p1, p2, p3, p4 = armPoint(c, theta, u0, -s), armPoint(c, theta, u0, s), armPoint(c, theta, u1, 0.45), armPoint(c, theta, u1, -0.45)
		currentName = "SplitterKerb"
		for _, tri in ipairs({ { p1, p2, p3 }, { p1, p3, p4 } }) do
			for _, wedge in ipairs(flatTriangle(model, tri[1], tri[2], tri[3], -0.06, 0.62, KERB_COLOR, Enum.Material.Concrete)) do
				clutter(wedge)
			end
		end
		currentName = "SplitterTop"
		local grassy = spec.class ~= "small"
		for _, wedge in ipairs(flatTriangle(model, armPoint(c, theta, u0 + 0.55, -(s - 0.6)), armPoint(c, theta, u0 + 0.55, s - 0.6),
			armPoint(c, theta, u1 - 1.6, 0), 0.3, 0.66, grassy and Color3.fromRGB(92, 132, 64) or Color3.fromRGB(150, 128, 112),
			grassy and Enum.Material.Grass or Enum.Material.Cobblestone)) do
			clutter(wedge)
		end
		-- What stands on the splitter doesn't collide (like the splitter's own kerb, and every kerb): a
		-- 9-wide van fills its lane beside it. It still takes shots.
		local before = #model:GetChildren()
		keepRightBollard(model, armPoint(c, theta, u1 - 0.9, 0) + Vector3.new(0, 0.62, 0), out)
		giveWaySign(model, armPoint(c, theta, u0 + 1.0, 0) + Vector3.new(0, 0.62, 0), out, 3.6)
		local children = model:GetChildren()
		for index = before + 1, #children do
			if children[index]:IsA("BasePart") then
				children[index].CanCollide = false
				children[index].CanTouch = false
			end
		end
		-- And one on the pavement on the entry's right, where the street meets the fillet: the kerb runs
		-- almost straight there, so the board stands square to the traffic and clear of the kerb.
		do
			local u = L - 1
			local mid = (rf - sidewalk + rf - KERB) / 2
			local v = -(h + rf) + math.sqrt(mid * mid - 1)
			local foot = armPoint(c, theta, u, v) + Vector3.new(0, PAVEMENT_TOP, 0)
			giveWaySign(model, foot, out, 3.8)
			roundaboutDisc(model, foot + Vector3.new(0, 1.1, 0) + out * 0.2, out)
			-- The warning triangle a little way back up the street, on the same side.
			warningSign(model, armPoint(c, theta, L + 7, -(h + sidewalk - 1.4)) + Vector3.new(0, PAVEMENT_TOP, 0), out)
		end
		-- The zebra's kerbs come down to the road either side (MapDecor.Street laid it 2.8 into the street).
		for _, side in ipairs({ -1, 1 }) do
			MapDecor.DropKerb(parent, armPoint(c, theta, L + 2.8, side * (h + KERB / 2)), Vector3.new(-math.sin(theta), 0, math.cos(theta)), 1.8, 3)
		end

		-- Give way: a double broken line across the entry along the ring's edge, then a row of shark's
		-- teeth pointing back at the arriving traffic. Worn: a dash or tooth now and then paler.
		for _, row in ipairs({ 0.75, 1.45 }) do
			local radius = ro + row
			-- Up to the edge line (1.3 in from the kerb, half a stud wide), not over it.
			local a0, a1 = -math.asin((s + 0.45) / radius), entryLimit(radius, 1.7)
			local span = (a0 - a1) * radius
			local dashes = math.max(1, math.floor((span + 0.6) / 1.6))
			local step = (a0 - a1) / dashes
			for index = 0, dashes - 1 do
				arcMark(theta + a0 - step * (index + 0.5), radius, math.min(1.0, math.abs(step) * radius - 0.3), 0.35, "GiveWay",
					rng:NextNumber() < 0.2 and rng:NextNumber(0.25, 0.45) or 0)
			end
		end
		-- The "give way" triangle painted on the entry lane a car's length back: an outline, its point
		-- toward the arriving driver.
		do
			local uBase = ro + 5.5
			local fillEdge = -(h + rf) + math.sqrt(math.max(0, rf * rf - (uBase - L) ^ 2))
			local vMid = (fillEdge + (-(s + 0.3))) / 2
			local b1, b2 = armPoint(c, theta, uBase, vMid - 1.3), armPoint(c, theta, uBase, vMid + 1.3)
			local tip = armPoint(c, theta, uBase + 6, vMid)
			local y = lift + MapDecor.MarkRaise / 2
			local worn = rng:NextNumber() < 0.3 and 0.3 or 0.05
			for _, edge in ipairs({ { b1, b2 }, { b2, tip }, { tip, b1 } }) do
				local a, b = Vector3.new(edge[1].X, y, edge[1].Z), Vector3.new(edge[2].X, y, edge[2].Z)
				local along = (b - a).Unit
				-- Trimmed at the corners so no two bars share any of their faces: the long sides stop well
				-- short of the narrow point, where they would cross.
				local atTip = edge[1] == tip and 1.2 or 0.2
				local toTip = edge[2] == tip and 1.2 or 0.2
				a, b = a + along * atTip, b - along * toTip
				mark(Vector3.new(0.3, MapDecor.MarkRaise, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), nil, "GiveWayTriangle").Transparency = worn
			end
		end
		-- A chevron board on the island facing the entry.
		chevronBoard(model, polar(c, theta, (PLINTH_RADIUS + bedRadius) / 2 + 0.1, 0.95), out)
		-- An arrow on the ring just past the entry, pointing the way round.
		do
			local alpha = theta - spec.mouth * 0.75
			local radius = spec.circulate
			local ahead = Vector3.new(math.sin(alpha), 0, -math.cos(alpha))
			local at = polar(c, alpha, radius, lift + MapDecor.MarkRaise / 2)
			mark(Vector3.new(0.55, MapDecor.MarkRaise, 3.4), CFrame.lookAt(at, at + ahead), nil, "RingArrow")
			local headBase = at + ahead * 1.7
			local sideways = Vector3.new(-ahead.Z, 0, ahead.X)
			currentName = "RingArrow"
			for _, wedge in ipairs(flatTriangle(model, headBase + sideways * 0.9, headBase - sideways * 0.9, headBase + ahead * 1.7, lift, markTop,
				ROUNDABOUT_MARK, Enum.Material.SmoothPlastic)) do
				clutter(wedge)
			end
		end
		-- The zebra's beacons and tactile paving on the pavements either side of the street.
		for _, side in ipairs({ -1, 1 }) do
			beacon(model, armPoint(c, theta, L + 0.9, side * (h + sidewalk - 1.2)) + Vector3.new(0, PAVEMENT_TOP, 0))
			currentName = "Tactile"
			local at = armPoint(c, theta, L + 2.8, side * (h + KERB + 1.0)) + Vector3.new(0, PAVEMENT_TOP + 0.015, 0)
			clutter(makePart(model, Vector3.new(1.8, 0.03, 3.4), CFrame.lookAt(at, at + out), Color3.fromRGB(196, 150, 104), Enum.Material.Pebble))
		end
	end

	-- Drainage: gully grates in the channel against the kerb and a manhole cover, drawn flush on the road
	-- (a SurfaceGui on an invisible plate whose top is 0.01 over the asphalt) rather than built as thin
	-- parts: ZFight.Fix pushes any visible face within 0.055 of the road's top up to 0.06 clear of it,
	-- which stood every thin detail proud of the road as a step. Hidden plates are left alone.
	local function roadDecal(name, cframe, sizeX, sizeZ)
		currentName = name
		local carrier = clutter(makePart(model, Vector3.new(sizeX, 0.02, sizeZ), cframe, Color3.new(0, 0, 0), Enum.Material.SmoothPlastic))
		carrier.Transparency = 1
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Top
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 60
		gui.LightInfluence = 1
		gui.MaxDistance = 300
		gui.Parent = carrier
		return gui
	end
	local function box(parent, color, x, y, w, hgt, round)
		local frame = Instance.new("Frame")
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = color
		frame.Position = UDim2.fromScale(x, y)
		frame.Size = UDim2.fromScale(w, hgt)
		if round then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = frame
		end
		frame.Parent = parent
		return frame
	end
	-- A kerbside gully: a dished concrete channel along the kerb either side, and the grate -- a cast-iron
	-- frame round a dark void with iron bars across it. `kerb` is a point on the kerb's road-side face,
	-- `inward` the level direction into the road from it, `along` the kerb's direction there.
	local function gully(kerb, inward, along)
		-- Right-handed, with local -Z into the road (a mirrored frame turns the plate's top face down).
		local x = along
		if x:Cross(Vector3.yAxis):Dot(inward) > 0 then
			x = -x
		end
		local base = CFrame.fromMatrix(Vector3.new(kerb.X, lift, kerb.Z), x, Vector3.yAxis)
		local depth, length = 0.9, 1.6
		for _, hand in ipairs({ -1, 1 }) do
			local channel = roadDecal("DrainChannel", base * CFrame.new(hand * (length / 2 + 1.3), 0, -0.25), 2.6, 0.45)
			local fill = box(channel, Color3.fromRGB(120, 118, 112), 0, 0, 1, 1)
			fill.BackgroundTransparency = 0.35
		end
		local grate = roadDecal("Drain", base * CFrame.new(0, 0, -depth / 2 - 0.05), length, depth)
		box(grate, Color3.fromRGB(46, 44, 42), 0, 0, 1, 1)
		box(grate, Color3.fromRGB(8, 8, 8), 0.08, 0.14, 0.84, 0.72)
		for k = 0, 6 do
			box(grate, Color3.fromRGB(62, 60, 57), 0.1 + k * 0.12, 0.14, 0.055, 0.72)
		end
	end
	for index, name in ipairs(ARM_ORDER) do
		local theta = ARM_ANGLE[name]
		local mid = theta + math.pi / 4
		-- Round the ring's outer edge, at the middle of each gap between the arms.
		do
			local alpha = mid + rng:NextNumber(-0.06, 0.06)
			gully(polar(c, alpha, ro, 0), Vector3.new(-math.cos(alpha), 0, -math.sin(alpha)), Vector3.new(-math.sin(alpha), 0, math.cos(alpha)))
		end
		-- On each approach, against the entry's kerb a car's length back from the give-way line.
		do
			local fMinus = armPoint(c, theta, L, -(h + rf))
			local u = ro + 7
			local beta = math.atan2(-(h + rf) + math.sqrt(math.max(0, rf * rf - (u - L) ^ 2)) - (-(h + rf)), u - L)
			local kerb = polar(fMinus, theta + beta, rf, 0)
			local out = Vector3.new(math.cos(theta + beta), 0, math.sin(theta + beta))
			gully(kerb, out, Vector3.new(-out.Z, 0, out.X))
		end
		if index == 3 then
			-- A cast-iron manhole cover in its frame: a rim, the lid with a raised ring and a cross of ribs,
			-- and a pair of lifting holes.
			local at = polar(c, mid - 0.4, spec.circulate + 1.5, lift)
			local cover = roadDecal("Manhole", CFrame.new(at), 2.4, 2.4)
			box(cover, Color3.fromRGB(58, 56, 54), 0, 0, 1, 1, true)
			local lid = box(cover, Color3.fromRGB(78, 76, 72), 0.075, 0.075, 0.85, 0.85, true)
			local ring = box(lid, Color3.fromRGB(78, 76, 72), 0.18, 0.18, 0.64, 0.64, true)
			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(52, 50, 48)
			stroke.Thickness = 5
			stroke.Parent = ring
			for _, rib in ipairs({ { 0.47, 0.1, 0.06, 0.8 }, { 0.1, 0.47, 0.8, 0.06 } }) do
				box(lid, Color3.fromRGB(60, 58, 55), rib[1], rib[2], rib[3], rib[4])
			end
			for _, x in ipairs({ 0.22, 0.72 }) do
				box(lid, Color3.fromRGB(14, 14, 14), x, 0.45, 0.06, 0.1, true)
			end
		end
		currentName = "Tuft"
		for _ = 1, 4 do
			local alpha = mid + rng:NextNumber(-0.5, 0.5) * (math.pi / 2 - 2 * spec.mouth)
			local size = rng:NextNumber(0.6, 1.1)
			clutter(makePart(model, Vector3.new(size, size * 0.7, size), CFrame.new(polar(c, alpha, ro + sidewalk + size * 0.55, 0)),
				Color3.fromRGB(90 + rng:NextInteger(-10, 10), 132, 60), Enum.Material.Grass, Enum.PartType.Ball))
		end
	end

	-- The corners between the arms: a lamp on the ring's pavement, and on the ground behind it a bench
	-- facing the fountain with a bin, and a flower bed. The south-east corner has the Rot Vendor instead
	-- of the bench (MapGenerator builds it at the spot returned).
	local groundAt = options.groundHeightAt or function()
		return 0
	end
	local space = options.space
	local spots = { heal = {}, weapon = {}, item = {} }
	local vendorAt = nil
	local corner0 = ro + sidewalk
	for index, name in ipairs(ARM_ORDER) do
		local alpha = ARM_ANGLE[name] + math.pi / 4
		local inward = Vector3.new(-math.cos(alpha), 0, -math.sin(alpha))
		local lampAngles = { alpha }
		if spec.class == "large" then
			lampAngles = { alpha - 0.14, alpha + 0.14 }
		end
		for _, angle in ipairs(lampAngles) do
			ringLamp(model, polar(c, angle, ro + KERB + 1.6, PAVEMENT_TOP), Vector3.new(-math.cos(angle), 0, -math.sin(angle)), accent, blooms[rng:NextInteger(1, 3)])
		end
		local benchAt = polar(c, alpha, corner0 + 2.4, 0)
		benchAt = Vector3.new(benchAt.X, groundAt(benchAt.X, benchAt.Z), benchAt.Z)
		local across = Vector3.new(inward.Z, 0, -inward.X)
		if name == "S" then
			-- S's corner is at 315 degrees (+x, -z), where the old square had its vendor: beside the
			-- flag rather than in front of it.
			vendorAt = polar(c, alpha, corner0 + 3.2, 0) + across * 4.6
			vendorAt = Vector3.new(vendorAt.X, groundAt(vendorAt.X, vendorAt.Z), vendorAt.Z)
			if space then
				space:AddCircle(vendorAt.X, vendorAt.Z, 3.2)
			end
		else
			benchFacing(model, benchAt, c)
			local binAt = benchAt + across * 4.2
			bin(model, binAt)
			if space then
				for _, hand in ipairs({ -1, 1 }) do
					space:AddCircle(benchAt.X + across.X * hand * 1.9, benchAt.Z + across.Z * hand * 1.9, 1.3)
				end
				space:AddCircle(binAt.X, binAt.Z, 1.4)
			end
		end
		local bedAt = polar(c, alpha, corner0 + 8.8, 0)
		bedAt = Vector3.new(bedAt.X, groundAt(bedAt.X, bedAt.Z), bedAt.Z)
		flowerBed(model, bedAt, rng, blooms)
		if space then
			space:AddCircle(bedAt.X, bedAt.Z, 2.8)
		end
		-- Loot on the ring's pavement, clear of the lamp.
		table.insert(index % 2 == 1 and spots.weapon or spots.item, polar(c, alpha + 3.6 / (ro + 3), ro + 3, PAVEMENT_TOP + 0.05))
	end
	for _, angle in ipairs({ 0.4, math.pi + 0.4 }) do
		table.insert(spots.heal, polar(c, angle, (PLINTH_RADIUS + bedRadius) / 2, 0.95))
	end
	currentName = "Part"
	-- Where TownThemes stands the town's flags: on the corners, behind the benches.
	model:SetAttribute("FlagRadius", corner0 + 5.0)
	return model, spots, vendorAt
end

-- A fenced crop field: tilled soil, rows of crops and a post-and-rail fence. The rails don't
-- collide, so a fence never traps anyone.
function MapDecor.Field(parent, center, width, depth, yaw, groundHeightAt)
	local y = groundHeightAt(center.X, center.Z)
	local frame = CFrame.new(center.X, y, center.Z) * CFrame.Angles(0, yaw, 0)
	local wood = Color3.fromRGB(128, 94, 60)

	clutter(makePart(parent, Vector3.new(width, 0.3, depth), frame * CFrame.new(0, 0.1, 0), Color3.fromRGB(110, 80, 56),
		Enum.Material.Ground))

	local crop = pick({ Color3.fromRGB(90, 160, 60), Color3.fromRGB(212, 186, 84), Color3.fromRGB(70, 140, 70) })
	local rows = math.floor(depth / 5)
	for row = 1, rows do
		local z = -depth / 2 + (row - 0.5) * depth / rows
		clutter(makePart(parent, Vector3.new(width - 4, 1.4, 1.8), frame * CFrame.new(0, 0.8, z), crop, Enum.Material.Grass))
	end

	for _, edge in ipairs({
		{ CFrame.new(0, 0, -depth / 2), width },
		{ CFrame.new(0, 0, depth / 2), width },
		{ CFrame.new(-width / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), depth },
		{ CFrame.new(width / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), depth },
	}) do
		local edgeFrame = frame * edge[1]
		for _, height in ipairs({ 1.3, 2.5 }) do
			clutter(makePart(parent, Vector3.new(edge[2], 0.25, 0.25), edgeFrame * CFrame.new(0, height, 0), wood, Enum.Material.Wood))
		end
		local posts = math.floor(edge[2] / 10)
		for index = 0, posts do
			makePart(parent, Vector3.new(0.5, 3, 0.5), edgeFrame * CFrame.new(-edge[2] / 2 + index * edge[2] / posts, 1.5, 0), wood,
				Enum.Material.Wood)
		end
	end
end

-- A lake: a sandy shore, water, reeds and a little dock. Returns a spot at the end of the dock — a
-- good place to leave something worth the walk.
--
-- `center.Y` is the lowest ground the site was measured at, and a site is only chosen where the
-- ground varies by under four studs, so the ground round the lake has to be brought down to that
-- level first. It used to be left as it was, and water filled to half a stud under the lowest
-- point was simply buried under the higher ground: most lakes were grass with a dock sunk into it.
-- Now the ground is written flat at the lake's level out past the shore, blending back into the
-- ground round it, with the shore painted as sand in the same write (terrain, not slabs, so it
-- follows the ground and never overlaps itself), and only then is the water filled in.
local LAKE_SHORE = 7
local LAKE_BLEND = 12
function MapDecor.Lake(parent, center, radius)
	local terrain = workspace.Terrain
	local y = center.Y
	local lift = 2 -- MapTerrain.SurfaceLift: a solid top this far under the ground it should render as
	local flatRadius = radius + LAKE_SHORE + 1
	local reach = flatRadius + LAKE_BLEND
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }
	params.IgnoreWater = true
	local region = Region3.new(Vector3.new(center.X - reach, y - 16, center.Z - reach), Vector3.new(center.X + reach, y + 24, center.Z + reach)):ExpandToGrid(4)
	local size = region.Size / 4
	local origin = region.CFrame.Position - region.Size / 2
	local materials, occupancies = terrain:ReadVoxels(region, 4)
	for ix = 1, size.X do
		local x = origin.X + (ix - 0.5) * 4
		for iz = 1, size.Z do
			local z = origin.Z + (iz - 0.5) * 4
			local distance = math.sqrt((x - center.X) ^ 2 + (z - center.Z) ^ 2)
			if distance < reach then
				local hit = workspace:Raycast(Vector3.new(x, y + 60, z), Vector3.new(0, -120, 0), params)
				local natural = hit and hit.Position.Y or y
				local t = math.clamp((distance - flatRadius) / LAKE_BLEND, 0, 1)
				local height = y + (natural - y) * (t * t * (3 - 2 * t))
				-- The column's own ground material, from its topmost solid voxel.
				local ground = nil
				for iy = size.Y, 1, -1 do
					if occupancies[ix][iy][iz] > 0 and materials[ix][iy][iz] ~= Enum.Material.Water then
						ground = materials[ix][iy][iz]
						break
					end
				end
				ground = ground or Enum.Material.Ground
				local surface = distance <= radius + LAKE_SHORE and Enum.Material.Sand or ground
				for iy = 1, size.Y do
					local bottom = origin.Y + (iy - 1) * 4
					local occupancy = math.clamp((height - lift - bottom) / 4, 0, 1)
					occupancies[ix][iy][iz] = occupancy
					materials[ix][iy][iz] = occupancy > 0 and surface or Enum.Material.Air
				end
			end
		end
	end
	terrain:WriteVoxels(region, 4, materials, occupancies)
	-- The water cut into that flat ground, its surface half a stud under the shore. The basin is
	-- carved to air first, as the river and the pond are: filled with water alone, over solid ground,
	-- every lake came out dry (the roads audit looks for open water off each dock).
	terrain:FillCylinder(CFrame.new(center.X, y + 1.75, center.Z), 12.5, radius, Enum.Material.Air)
	terrain:FillCylinder(CFrame.new(center.X, y - 2.5, center.Z), 4, radius, Enum.Material.Water)

	currentName = "Reed"
	for index = 1, 16 do
		local angle = index / 16 * math.pi * 2 + math.random() * 0.3
		local distance = radius + 1 + math.random() * 4
		clutter(column(parent, 3 + math.random() * 2, 0.3,
			Vector3.new(center.X + math.cos(angle) * distance, y - 0.5, center.Z + math.sin(angle) * distance),
			Color3.fromRGB(96, 140, 64), Enum.Material.Grass))
	end

	local angle = math.random() * math.pi * 2
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local shore = Vector3.new(center.X, y, center.Z) + direction * (radius + 3)
	local length = math.min(radius * 0.6, 22)
	local mid = shore - direction * (length / 2)
	local dock = CFrame.lookAt(mid + Vector3.new(0, 0.6, 0), mid + Vector3.new(0, 0.6, 0) - direction)
	currentName = "LakeDock"
	makePart(parent, Vector3.new(5, 0.5, length), dock, Color3.fromRGB(140, 100, 62), Enum.Material.WoodPlanks)
	currentName = "LakeDockPost"
	for _, x in ipairs({ -2.2, 2.2 }) do
		for _, z in ipairs({ -length / 2 + 0.5, length / 2 - 0.5 }) do
			makePart(parent, Vector3.new(0.5, 4, 0.5), dock * CFrame.new(x, -1.6, z), Color3.fromRGB(96, 70, 46), Enum.Material.Wood)
		end
	end
	currentName = "Part"

	return shore - direction * (length - 2) + Vector3.new(0, 0.85, 0)
end

-- Sand maps: a coastline of shallow water running round just outside the playable circle.
function MapDecor.Coast(radius)
	local terrain = workspace.Terrain
	local segments = 48
	local inner, outer = radius * 1.03, radius * 1.18
	local mid = (inner + outer) / 2
	for index = 0, segments - 1 do
		local angle = index / segments * math.pi * 2
		local position = Vector3.new(math.cos(angle) * mid, -3, math.sin(angle) * mid)
		terrain:FillBlock(CFrame.lookAt(position, Vector3.new(0, -3, 0)),
			Vector3.new(2 * math.pi * mid / segments + 6, 5, outer - inner), Enum.Material.Water)
		if index % 8 == 7 then
			task.wait()
		end
	end
end

-- The yaw that turns a model's -Z (its front) to face along `vector`.
local function yawFacing(vector)
	return math.atan2(-vector.X, -vector.Z)
end

-- Street furniture for a town, set along its streets rather than scattered: lamps and hydrants
-- at the kerb, benches facing the road, bins and planters on the pavement, cars parked along the
-- street edge, and beach umbrellas on sand maps. Each piece checks `space` before it's built and
-- claims its footprint after, so nothing ends up inside a building, a car or another prop.
-- `streets` are { a, b, width, entry } from MapGenerator. Returns loot spots beside some of it.
function MapDecor.Town(town, center, preset, spread, streets, townName, groundHeightAt, space, furniture)
	local spots = {}
	-- How many of each piece (TownKinds' `furniture`); nil is the default town's counts.
	furniture = furniture or {}
	local function count(key, default)
		local value = furniture[key]
		return type(value) == "number" and math.clamp(math.floor(value), 0, 12) or default
	end

	-- A point `beyondKerb` studs outside one side of a random street's kerb (negative is out in
	-- the road), away from the street's ends.
	local function besideStreet(beyondKerb)
		local street = pick(streets)
		local delta = Vector3.new(street.b.X - street.a.X, 0, street.b.Z - street.a.Z)
		local length = delta.Magnitude
		if length < 60 then
			return nil
		end
		local direction = delta.Unit
		local side = Vector3.new(-direction.Z, 0, direction.X) * (math.random() < 0.5 and 1 or -1)
		local lateral = street.width / 2 + 2.5 + beyondKerb
		local flat = Vector3.new(street.a.X, 0, street.a.Z) + direction * (20 + math.random() * (length - 40)) + side * lateral
		-- What it stands on: the asphalt, the pavement, or the ground past it.
		local surface = 0
		if lateral < street.width / 2 then
			surface = MapDecor.RoadLift
		elseif lateral >= street.width / 2 + KERB and lateral <= street.width / 2 + (street.sidewalk or 0) then
			surface = MapDecor.PavementTop
		end
		return flat, direction, side, street.entry, surface
	end

	local function alongStreets(count, beyondKerb, radius, build)
		if #streets == 0 then
			return
		end
		for _ = 1, count do
			for _ = 1, 16 do
				local flat, direction, side, entry, surface = besideStreet(beyondKerb)
				if flat and space:IsFree(flat.X, flat.Z, radius, entry) then
					space:AddCircle(flat.X, flat.Z, radius)
					local spot = build(Vector3.new(flat.X, groundHeightAt(flat.X, flat.Z) + surface, flat.Z), direction, side)
					if spot then
						table.insert(spots, spot)
					end
					break
				end
			end
		end
	end

	-- Lamps just off the kerb, arms reaching out over the road.
	alongStreets(count("lamps", 6), 1.3, 1.2, function(position, _, side)
		streetLamp(town, position, -side)
		return position - side * 2.6
	end)

	-- Benches on the pavement, facing the road: wholly on it, so none stands half on the pavement
	-- and half on the ground behind.
	alongStreets(count("benches", 4), 0.4, 3.4, function(position, _, side)
		bench(town, position, yawFacing(-side))
		-- In front of the bench, still on the pavement.
		return position - side * 1.6
	end)

	alongStreets(count("bins", 3), 1.8, 1.6, function(position)
		bin(town, position)
	end)

	-- Cars parked at the kerb (#16 / #94), the way a real street has them: on one side of the street
	-- only, and only on a street wide enough to leave a lane clear beside them (KERB_PARKING_WIDTH);
	-- parallel to the kerb and nose along the traffic on their side (traffic drives on the right, see
	-- MapDecor.Street); never near the street's ends, where the junctions and crossings are; a couple
	-- of studs apart when in a row; and often in twos and threes rather than evenly spaced, with bare
	-- kerb between. Each car's design is chosen before its spot is looked for, so the claim fits it,
	-- and it stands with its outer side just over the asphalt's edge (a mirror over the kerb face).
	local parkingStreets = {}
	for _, street in ipairs(streets) do
		local delta = Vector3.new(street.b.X - street.a.X, 0, street.b.Z - street.a.Z)
		if street.width >= KERB_PARKING_WIDTH and delta.Magnitude >= 2 * KERB_END_CLEAR + 24 then
			table.insert(parkingStreets, {
				street = street,
				length = delta.Magnitude,
				direction = delta.Unit,
				-- One side of each street is its parking side, and the lane beside it is kept clear.
				side = math.random() < 0.5 and 1 or -1,
			})
		end
	end
	local detailedLeft = DETAILED_CARS_PER_TOWN
	local last = nil
	for _ = 1, #parkingStreets > 0 and count("cars", 4) or 0 do
		local design = parkedCarDesign(detailedLeft > 0)
		local radius, reach = design.radius, design.reach
		local half = design.footprint.span / 2
		for attempt = 1, 16 do
			-- Behind or ahead of the last car, a short gap away, about half the time; otherwise anywhere
			-- on a parking street.
			local lane, along
			if last and attempt <= 4 and math.random() < 0.55 then
				lane = last.lane
				local sign = math.random() < 0.5 and 1 or -1
				along = last.along + sign * (last.half + KERB_GAP + math.random() * 2 + half)
			else
				lane = pick(parkingStreets)
				along = KERB_END_CLEAR + half + math.random() * (lane.length - 2 * (KERB_END_CLEAR + half))
			end
			local street, direction = lane.street, lane.direction
			if along >= KERB_END_CLEAR + half and along <= lane.length - KERB_END_CLEAR - half then
				-- `side` is the kerb the car stands at: +1 is the right of `direction`, so a car there faces
				-- along it, and one at the other kerb faces back the other way.
				local side = Vector3.new(-direction.Z, 0, direction.X) * lane.side
				local facing = direction * lane.side
				local lateral = street.width / 2 + 0.1 - design.halfWidth
				local flat = Vector3.new(street.a.X, 0, street.a.Z) + direction * along + side * lateral
				local front, back = flat + facing * reach, flat - facing * reach
				-- KERB_GAP more than its own claim, so the next car in a row keeps that gap.
				if space:IsFree(front.X, front.Z, radius + KERB_GAP, street.entry)
					and space:IsFree(back.X, back.Z, radius + KERB_GAP, street.entry) then
					space:AddCircle(front.X, front.Z, radius)
					space:AddCircle(back.X, back.Z, radius)
					local position = Vector3.new(flat.X, groundHeightAt(flat.X, flat.Z) + MapDecor.RoadLift, flat.Z)
					parkedCar(town, position, yawFacing(facing), design)
					if design.id then
						detailedLeft -= 1
					end
					last = { lane = lane, along = along, half = half }
					table.insert(spots, position + side * (design.halfWidth + 1.15))
					break
				end
			end
		end
	end

	if preset.terrainMaterial == Enum.Material.Sand then
		-- Beach umbrellas anywhere there's open sand in town.
		for _ = 1, 4 do
			for _ = 1, 14 do
				local x = center.X + math.random(-spread - 24, spread + 24)
				local z = center.Z + math.random(-spread - 24, spread + 24)
				if space:IsFree(x, z, 5.5) then
					space:AddCircle(x, z, 5.5)
					local position = Vector3.new(x, groundHeightAt(x, z), z)
					beachUmbrella(town, position)
					table.insert(spots, position + Vector3.new(-2.5, 0, 0))
					break
				end
			end
		end
	else
		alongStreets(count("hydrants", 2), 1.2, 1, function(position)
			hydrant(town, position)
		end)
		-- Planters run along the pavement, wholly on it.
		alongStreets(count("planters", 3), 0.9, 3.4, function(position, direction)
			planter(town, position, math.atan2(-direction.Z, direction.X))
		end)
	end

	-- Welcome sign on the side facing the middle of the map, where most people arrive from.
	-- The central town has no such side, so it just picks one.
	local flat = Vector3.new(center.X, 0, center.Z)
	local toward = flat.Magnitude > 1 and -flat.Unit or Vector3.new(1, 0, 0)
	for attempt = 0, 5 do
		local direction = CFrame.Angles(0, attempt * math.pi / 3, 0) * toward
		local spot = flat + direction * (spread + 26)
		if space:IsFree(spot.X, spot.Z, 11) then
			space:AddCircle(spot.X, spot.Z, 11)
			townSign(town, Vector3.new(spot.X, groundHeightAt(spot.X, spot.Z), spot.Z), direction, townName)
			break
		end
	end

	return spots
end

-- A parked car stood so the middle of its footprint (not the point it's built about) is at `frame`'s
-- position, nose along `frame`'s look: centred in a bay or on a driveway, whichever end is longer.
local function parkCentred(parent, frame, design)
	local centre = design.footprint.centre or Vector3.zero
	local at = frame * CFrame.new(-centre.X, 0, -centre.Z)
	return parkedCar(parent, at.Position, yawFacing(frame.LookVector), design)
end

-- Whether a turned rectangle is clear in `space`, as a grid of small circles over it: a stud or less
-- apart, each just big enough to cover its cell, and the grid set in by a quarter stud so no circle
-- pokes past the rectangle's edge -- a driveway laid flush against the back of the pavement (the
-- street's claim) still reads clear.
local function rectClear(space, frame, halfX, halfZ)
	halfX, halfZ = math.max(0.5, halfX - 0.25), math.max(0.5, halfZ - 0.25)
	local columns = math.max(1, math.ceil(halfX * 2))
	local rows = math.max(1, math.ceil(halfZ * 2))
	local cellX, cellZ = halfX * 2 / columns, halfZ * 2 / rows
	local radius = math.sqrt(cellX * cellX + cellZ * cellZ) / 2
	for column = 1, columns do
		for row = 1, rows do
			local p = frame * Vector3.new(-halfX + (column - 0.5) * cellX, 0, -halfZ + (row - 0.5) * cellZ)
			if not space:IsFree(p.X, p.Z, radius) then
				return false
			end
		end
	end
	return true
end

local DRIVEWAY_COLOR = Color3.fromRGB(150, 148, 142)
-- How far the car stands in from the back of the pavement, and the clearance kept to the house.
local DRIVEWAY_BACK = 0.8
local DRIVEWAY_WALL = 0.6

-- Driveways (Oliver 09-24: "cars in driveways by houses"). A house may get one down the side gap next
-- to it: a concrete strip from the back of the pavement, a car on it nose-in, parallel to the house.
-- Only where the whole strip and the car are clear ground in `space` -- the gap to the next building
-- has to be wide enough, and nothing (a crate, a fence, a set piece) may be in it -- and it is then
-- claimed, together with its mouth: the pavement in front of it and the kerb lane beyond, so no bench,
-- lamp or kerbside car blocks the way out. Built after the buildings and before the street furniture.
--
-- `houses` are MapGenerator's placed buildings ({ lot, plan, yaw }, local -Z facing the street);
-- `setback` is the gap from the back of the pavement to a building's front, `sidewalk` the pavement's
-- width, `lane` how far the mouth claim reaches out into the street past the kerb. `chance` is per
-- house, `cap` the most in the town. Returns how many it built.
function MapDecor.Driveways(town, houses, setback, sidewalk, lane, groundHeightAt, space, chance, cap)
	local built = 0
	if chance <= 0 or cap <= 0 then
		return 0
	end
	for _, house in ipairs(houses) do
		if built >= cap then
			break
		end
		local plan = house.plan
		if plan.archetype == "house" and math.random() < chance then
			local design = parkedCarDesign(true)
			local halfW, span = design.halfWidth, design.footprint.span
			local turn = CFrame.new(house.lot.X, 0, house.lot.Z) * CFrame.Angles(0, house.yaw, 0)
			-- Local -Z is the street: the back of the pavement is `setback` in front of the house.
			local pavementBack = -plan.depth / 2 - setback
			local centreZ = pavementBack + DRIVEWAY_BACK + span / 2
			local slabFrom, slabTo = pavementBack, centreZ + span / 2 + 1
			for _, sideSign in ipairs(math.random() < 0.5 and { 1, -1 } or { -1, 1 }) do
				-- Beside the building's own claim (its walls plus 1.5), DRIVEWAY_WALL clear of it.
				local x = sideSign * (plan.width / 2 + 1.5 + DRIVEWAY_WALL + halfW)
				local slab = turn * CFrame.new(x, 0, (slabFrom + slabTo) / 2)
				local halfSlabX, halfSlabZ = halfW + DRIVEWAY_WALL / 2, (slabTo - slabFrom) / 2
				-- The mouth: across the pavement and out into the street's kerb lane.
				local mouthFrom, mouthTo = pavementBack - sidewalk - lane, pavementBack
				local mouth = turn * CFrame.new(x, 0, (mouthFrom + mouthTo) / 2)
				if rectClear(space, slab, halfSlabX, halfSlabZ) then
					space:AddRect(slab.X, slab.Z, halfSlabX, halfSlabZ, house.yaw)
					space:AddRect(mouth.X, mouth.Z, halfSlabX, (mouthTo - mouthFrom) / 2, house.yaw)
					local ground = groundHeightAt(slab.X, slab.Z)
					currentName = "Driveway"
					local strip = makePart(town, Vector3.new(halfSlabX * 2, 0.3, halfSlabZ * 2),
						CFrame.new(slab.X, ground + DRIVEWAY_TOP - 0.15, slab.Z) * slab.Rotation, DRIVEWAY_COLOR, Enum.Material.Concrete)
					strip.CanCollide = false
					currentName = "Part"
					-- The kerb at the foot of the driveway comes down, so it runs out to the street
					-- rather than stopping behind a kerb (roads_check.py, driveway access).
					local kerbLine = turn * CFrame.new(x, 0, pavementBack - sidewalk)
					MapDecor.DropKerb(town, kerbLine.Position, turn.LookVector, halfSlabX, 2)
					-- Nose-in: facing the way the house faces away from the street (local +Z).
					local carAt = turn * CFrame.new(x, 0, centreZ)
					local frame = CFrame.lookAt(Vector3.new(carAt.X, ground + DRIVEWAY_TOP, carAt.Z),
						Vector3.new(carAt.X, ground + DRIVEWAY_TOP, carAt.Z) + (turn.LookVector * -1))
					parkCentred(town, frame, design)
					built += 1
					break
				end
			end
		end
	end
	return built
end

-- Static cars in a town's car park, round whatever drivable ones VehicleService.ParkInTowns already
-- stood there (it marks each bay it takes, `ParkingBayTaken_<i>`), so the car park reads as in use --
-- and as a real one does, not all alike (Oliver 09-24: "the parking lots don't all need to be full"):
-- each is filled to its own ParkingFill, dealt across the map's car parks by ParkingLots.DealFills (a
-- nearly empty one, a busy one, the rest between), never past LOT_FILL_MAX of its bays and never to
-- the last bay. Where the drivable cars already take more than that, none are added.
-- A car park fills from the way in back: the free bays are taken in ParkingLots' order (nearest the
-- street first) with the pick leaning to the front of what's left (FRONT_LEAN), so the back rows are
-- the emptier ones, as in any car park, without the front being stamped full. Every one is a real
-- design (#121: 200 to 290 parts a car), square to its bay, nose the bay's way (nose-in), centred in
-- it. `fill` (optional) fixes the share, for tests. Returns how many it parked.
local LOT_FILL_MAX = 0.7
local LOT_FILL_DEFAULT = 0.35
local FRONT_LEAN = 2.5
local BOX_CORNERS = {}
for _, x in ipairs({ -1, 1 }) do
	for _, y in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -1, 1 }) do
			table.insert(BOX_CORNERS, Vector3.new(x, y, z))
		end
	end
end
-- How far a model's visible parts reach along two level directions: { a0, a1, b0, b1 }. What two
-- parked cars are tested with: a real design's mirrors, bull bar or roof load vary with its roll, so
-- the only sure footprint is the one it was built with.
local function reach(model, a, b)
	local a0, a1, b0, b1 = math.huge, -math.huge, math.huge, -math.huge
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 then
			local half, cf = part.Size / 2, part.CFrame
			for _, corner in ipairs(BOX_CORNERS) do
				local p = cf * (corner * half)
				local u, v = p:Dot(a), p:Dot(b)
				a0, a1, b0, b1 = math.min(a0, u), math.max(a1, u), math.min(b0, v), math.max(b1, v)
			end
		end
	end
	return { a0, a1, b0, b1 }
end
local function touching(one, other)
	return one[1] < other[2] + 0.2 and other[1] < one[2] + 0.2 and one[3] < other[4] + 0.2 and other[3] < one[4] + 0.2
end

-- How the parked scenery stands in its stall, the way real drivers leave cars (Oliver 09-24: "slightly
-- off-centre, a few reverse-parked, one stall straddler"): a little off the middle and a degree or two
-- askew, more so in a gravel lot with no lines to go by; REVERSE_SHARE of them backed in (nose to the
-- aisle); and where MapGenerator asks for it, one car straddling a line across two stalls, or one in an
-- accessible stall. Each car says how it was left in its `ParkStyle` attribute (centred, offset,
-- reverse, straddle, accessible), which the tools read.
local REVERSE_SHARE = 0.2
local OFF_ACROSS, OFF_ALONG, OFF_YAW = 0.28, 0.35, math.rad(1.4)
local LOOSE_ACROSS, LOOSE_ALONG, LOOSE_YAW = 0.4, 0.8, math.rad(3)
local STRADDLE_YAW = math.rad(3)

-- `others` (optional) are models already standing in the car parks (VehicleService's), which the
-- parked cars keep off. `options` (optional): `straddle` = park one car across two stalls, `accessible`
-- = park one in an accessible stall.
function MapDecor.ParkBays(town, others, fill, options)
	options = options or {}
	local count = tonumber(town:GetAttribute("ParkingBays")) or 0
	if count < 2 then
		return 0
	end
	local taken, free = 0, {}
	for index = 1, count do
		if town:GetAttribute("ParkingBayTaken_" .. index) then
			taken += 1
		elseif typeof(town:GetAttribute("ParkingBay_" .. index)) == "CFrame" then
			table.insert(free, index)
		end
	end
	local share = fill or tonumber(town:GetAttribute("ParkingFill")) or LOT_FILL_DEFAULT
	-- At least one car, at most LOT_FILL_MAX of the bays: 2 of 4, 4 of 6, 5 of 8, 8 of 12.
	local target = math.clamp(math.floor(count * share + 0.5), 1, math.max(1, math.floor(count * LOT_FILL_MAX)))
	-- Every car park's bays share their axes (a row faces one way or the other), so any bay's frame
	-- measures them all. What's already standing near the car park, measured once.
	local first = town:GetAttribute("ParkingBay_" .. (free[1] or 1))
	if typeof(first) ~= "CFrame" then
		return 0
	end
	local loose = town:GetAttribute("ParkingKind") == "gravel"
	local across, along = first.RightVector, first.LookVector
	local standing = {}
	for _, other in ipairs(others or {}) do
		if other:IsA("Model") and (other:GetPivot().Position - first.Position).Magnitude < 12 * count + 40 then
			table.insert(standing, reach(other, across, along))
		end
	end
	-- Parks one car at `frame` unless it would stand mirror to mirror with one already there.
	local function try(frame, style)
		local car = parkCentred(town, frame, parkedCarDesign(true))
		local box = reach(car, across, along)
		for _, other in ipairs(standing) do
			if touching(box, other) then
				car:Destroy()
				return nil
			end
		end
		car:SetAttribute("ParkStyle", style)
		table.insert(standing, box)
		return car
	end
	local parked = 0
	local function isFree(index)
		return table.find(free, index) ~= nil
	end
	-- The straddler first, if asked for: across the line between a free stall and the free one beside it.
	if options.straddle and taken + 2 <= target then
		for _, index in ipairs(table.clone(free)) do
			local nextIndex = town:GetAttribute("ParkingBayNext_" .. index)
			if nextIndex and isFree(nextIndex) then
				local a, b = town:GetAttribute("ParkingBay_" .. index), town:GetAttribute("ParkingBay_" .. nextIndex)
				local turn = (math.random() < 0.5 and -1 or 1) * STRADDLE_YAW
				local frame = CFrame.new((a.Position + b.Position) / 2) * a.Rotation * CFrame.Angles(0, turn, 0)
				if try(frame, "straddle") then
					for _, used in ipairs({ index, nextIndex }) do
						table.remove(free, table.find(free, used))
						town:SetAttribute("ParkingBayTaken_" .. used, true)
					end
					taken += 2
					parked += 1
				end
				break
			end
		end
	end
	-- One in an accessible stall, if asked for (never more).
	if options.accessible and (tonumber(town:GetAttribute("ParkingAccessible")) or 0) > 0 then
		local stall = town:GetAttribute("ParkingAccessible_1")
		if typeof(stall) == "CFrame" and try(stall, "accessible") then
			town:SetAttribute("ParkingAccessibleTaken_1", true)
			parked += 1
		end
	end
	while taken < target and #free > 0 do
		local index = table.remove(free, math.floor(#free * math.random() ^ FRONT_LEAN) + 1)
		local bay = town:GetAttribute("ParkingBay_" .. index)
		local style = "offset"
		local frame = bay
		if math.random() < REVERSE_SHARE then
			-- Backed in: the nose to the aisle.
			style = "reverse"
			frame = frame * CFrame.Angles(0, math.pi, 0)
		end
		local oa, ol, oy = OFF_ACROSS, OFF_ALONG, OFF_YAW
		if loose then
			oa, ol, oy = LOOSE_ACROSS, LOOSE_ALONG, LOOSE_YAW
		end
		frame = frame * CFrame.new((math.random() * 2 - 1) * oa, 0, (math.random() * 2 - 1) * ol) * CFrame.Angles(0, (math.random() * 2 - 1) * oy, 0)
		if try(frame, style) then
			town:SetAttribute("ParkingBayTaken_" .. index, true)
			taken += 1
			parked += 1
		end
	end
	return parked
end

--------------------------------------------------------------------------------
-- Vegetation and scenery
--------------------------------------------------------------------------------

local TRUNK = Color3.fromRGB(94, 70, 48)
local LEAF_GREENS = {
	Color3.fromRGB(62, 104, 54), Color3.fromRGB(78, 126, 60), Color3.fromRGB(56, 96, 64),
	Color3.fromRGB(96, 136, 58),
}

-- Trunks and stems start this far underground, so a tree on a slope never floats on its low side.
local SINK = 1.5

local function roundTree(parent, position)
	local height = math.random(12, 20)
	column(parent, height + SINK, 2.6, position - Vector3.new(0, SINK, 0), TRUNK, Enum.Material.Wood)

	local green = pick(LEAF_GREENS)
	local top = position + Vector3.new(0, height + 3, 0)
	local size = math.random(15, 19)
	makePart(parent, Vector3.new(size, size, size), CFrame.new(top), green, Enum.Material.Grass, Enum.PartType.Ball)
	for _ = 1, 2 do
		local offset = Vector3.new(math.random(-5, 5), math.random(-3, 2), math.random(-5, 5))
		makePart(parent, Vector3.new(10, 10, 10), CFrame.new(top + offset), green:Lerp(Color3.new(1, 1, 1), 0.06),
			Enum.Material.Grass, Enum.PartType.Ball)
	end
end
roundTree = grouped("Tree", roundTree)

local function pineTree(parent, position, scale)
	column(parent, 6 * scale + SINK, 1.8 * scale, position - Vector3.new(0, SINK, 0), TRUNK, Enum.Material.Wood)

	local green = Color3.fromRGB(44, 86, 60)
	local y = 4 * scale
	for _, tier in ipairs({ { 14, 5 }, { 10.5, 5 }, { 7, 4.5 }, { 3.5, 4 } }) do
		column(parent, tier[2] * scale, tier[1] * scale, position + Vector3.new(0, y, 0), green, Enum.Material.Grass)
		y += tier[2] * scale * 0.8
	end
end
pineTree = grouped("Tree", pineTree)

local function palmTree(parent, position)
	local trunk = Color3.fromRGB(150, 116, 78)
	local lean = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
	lean = lean.Magnitude > 0.05 and lean.Unit or Vector3.new(1, 0, 0)

	local point = position - Vector3.new(0, SINK, 0)
	for segment = 1, 5 do
		local rise = segment == 1 and 3.6 + SINK or 3.6
		local nextPoint = point + Vector3.new(0, rise, 0) + lean * (0.35 * segment)
		makePart(parent, Vector3.new((nextPoint - point).Magnitude + 0.3, 1.5, 1.5),
			CFrame.lookAt((point + nextPoint) / 2, nextPoint) * CFrame.Angles(0, math.pi / 2, 0),
			trunk, Enum.Material.Wood, Enum.PartType.Cylinder)
		point = nextPoint
	end

	for index = 1, 6 do
		local yaw = index / 6 * math.pi * 2
		clutter(makePart(parent, Vector3.new(2.4, 0.3, 9),
			CFrame.new(point) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-22), 0, 0) * CFrame.new(0, 0, -4.2),
			Color3.fromRGB(64, 138, 64), Enum.Material.Grass))
	end
	for _, offset in ipairs({ Vector3.new(0.7, -0.8, 0.4), Vector3.new(-0.6, -0.9, -0.3) }) do
		clutter(makePart(parent, Vector3.new(1.1, 1.1, 1.1), CFrame.new(point + offset),
			Color3.fromRGB(96, 66, 40), Enum.Material.Wood, Enum.PartType.Ball))
	end
end
palmTree = grouped("Palm", palmTree)

local function cactus(parent, position)
	local green = Color3.fromRGB(78, 138, 72)
	local height = math.random(8, 13)
	column(parent, height + SINK, 2.6, position - Vector3.new(0, SINK, 0), green, Enum.Material.Grass)
	makePart(parent, Vector3.new(2.6, 2.6, 2.6), CFrame.new(position + Vector3.new(0, height, 0)), green,
		Enum.Material.Grass, Enum.PartType.Ball)

	for _, side in ipairs({ -1, 1 }) do
		if math.random() < 0.8 then
			local armY = height * (0.4 + math.random() * 0.25)
			makePart(parent, Vector3.new(2.6, 1.6, 1.6), CFrame.new(position + Vector3.new(side * 2, armY, 0)), green,
				Enum.Material.Grass, Enum.PartType.Cylinder)
			column(parent, 3.5, 1.6, position + Vector3.new(side * 3.1, armY, 0), green, Enum.Material.Grass)
			makePart(parent, Vector3.new(1.6, 1.6, 1.6), CFrame.new(position + Vector3.new(side * 3.1, armY + 3.5, 0)), green,
				Enum.Material.Grass, Enum.PartType.Ball)
		end
	end
end
cactus = grouped("Cactus", cactus)

-- Pieces set off to the side of a prop's spot find their own ground (a slope can be studs
-- higher three studs over), when the caller gave us a way to ask.
local function groundUnder(position, offset, groundAt)
	local x, z = position.X + offset.X, position.Z + offset.Z
	local y = groundAt and groundAt(x, z) or position.Y
	return Vector3.new(x, y + offset.Y, z)
end

local function bush(parent, position, groundAt)
	local green = pick(LEAF_GREENS)
	for _ = 1, 3 do
		local size = math.random(4, 7)
		makePart(parent, Vector3.new(size, size, size),
			CFrame.new(groundUnder(position, Vector3.new(math.random(-3, 3), size * 0.3, math.random(-3, 3)), groundAt)),
			green, Enum.Material.Grass, Enum.PartType.Ball)
	end
end
bush = grouped("Bush", bush)

local function hayBales(parent, position)
	local hay = Color3.fromRGB(214, 180, 96)
	local cf = CFrame.new(position) * CFrame.Angles(0, math.random() * math.pi, 0)
	-- Set a little into the ground so a slope doesn't leave them hovering.
	for _, z in ipairs({ -2.6, 2.6 }) do
		makePart(parent, Vector3.new(4, 5, 5), cf * CFrame.new(0, 2.1, z), hay, Enum.Material.Grass, Enum.PartType.Cylinder)
	end
	if math.random() < 0.5 then
		makePart(parent, Vector3.new(4, 5, 5), cf * CFrame.new(0, 6.37, 0), hay, Enum.Material.Grass, Enum.PartType.Cylinder)
	end
end
hayBales = grouped("HayBales", hayBales)

local function rock(parent, position, size, groundAt)
	makePart(parent, Vector3.new(size, size * 0.8, size * 1.1),
		CFrame.new(position + Vector3.new(0, size / 4, 0)) * CFrame.Angles(math.random() * 2, math.random() * 2, math.random() * 2),
		Color3.fromRGB(118, 114, 108), Enum.Material.Rock, Enum.PartType.Ball)
	if math.random() < 0.5 then
		local pebble = size * 0.35
		makePart(parent, Vector3.new(pebble, pebble * 0.7, pebble),
			CFrame.new(groundUnder(position, Vector3.new(size * 0.55, pebble * 0.2, size * 0.3), groundAt)),
			Color3.fromRGB(132, 126, 118), Enum.Material.Rock, Enum.PartType.Ball)
	end
end
rock = grouped("Rock", rock)

-- One piece of open-ground scenery, chosen to suit the map's terrain, if `space` has room for
-- it. Claims its footprint and returns true when placed. `groundAt(x, z)`, if given, lets
-- pieces set off to the side (a pebble, a bush's balls) sit on their own bit of ground.
local SHED_WALLS = {
	Color3.fromRGB(138, 104, 70), Color3.fromRGB(116, 88, 62), Color3.fromRGB(150, 122, 88),
}
local SHED_ROOFS = {
	Color3.fromRGB(96, 62, 48), Color3.fromRGB(74, 78, 86), Color3.fromRGB(110, 86, 58),
}

-- A small shed out in the open: four plank walls round a doorway, a flat overhanging roof and a
-- crate inside. Walls, roof and crate are named from DestructibleService's table, so a shed is
-- real cover that can be shot apart rather than scenery that shrugs bullets off -- which is the
-- whole point of putting them in the empty fields between towns. Nothing here goes through
-- `clutter`: only CanCollide parts are destructible, and only solid ones stop a bullet.
local function shed(parent, position, groundAt, lootSpots)
	local width, depth, height = 14, 12, 9
	local halfW, halfD = width / 2, depth / 2
	local wood, roofColor = pick(SHED_WALLS), pick(SHED_ROOFS)
	-- Sunk like the trees are, and further by however far the ground falls away under its walls from
	-- the point it was placed on: a rigid box on one sampled height stood a corner up to 17 studs over
	-- a hillside (tools/foundation_check.py).
	-- The door faces downhill (critic C9): a random yaw put it uphill as often as not, and the doorway
	-- is cut to a fixed height, so on a slope the ground outside rose into it and the loot inside was
	-- behind a buried door. Of eight directions the one whose ground is lowest out front, turned by up
	-- to 15 degrees either way with the same one roll the random yaw took.
	local jitter = (math.random() - 0.5) * math.rad(30)
	local facing, lowest = 0, math.huge
	if groundAt then
		for step = 0, 7 do
			local angle = step * math.pi / 4
			local y = groundAt(position.X + math.sin(angle) * (halfD + 2), position.Z + math.cos(angle) * (halfD + 2))
			if y and y < lowest then
				facing, lowest = angle, y
			end
		end
	end
	-- Local -Z (the front) toward `facing`.
	local turn = CFrame.Angles(0, facing + math.pi + jitter, 0)
	local drop = 0
	if groundAt then
		for _, corner in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local at = (CFrame.new(position) * turn * CFrame.new(corner[1] * (halfW + 0.4), 0, corner[2] * (halfD + 0.4))).Position
			local y = groundAt(at.X, at.Z)
			if y then
				drop = math.max(drop, position.Y - y)
			end
		end
	end
	local base = CFrame.new(position - Vector3.new(0, SINK + drop, 0)) * turn
	local wallHeight = height + SINK + drop

	currentName = "Wall"
	makePart(parent, Vector3.new(width, wallHeight, 0.8), base * CFrame.new(0, wallHeight / 2, halfD), wood, Enum.Material.WoodPlanks)
	for _, side in ipairs({ -1, 1 }) do
		makePart(parent, Vector3.new(0.8, wallHeight, depth), base * CFrame.new(side * halfW, wallHeight / 2, 0), wood, Enum.Material.WoodPlanks)
	end

	-- The front, split round a doorway you can actually walk through.
	-- The opening is 7 studs clear over the ground at the door itself, not over the ground at the
	-- shed's middle, and never taller than the wall.
	local doorway = 5
	local doorGround = -math.huge
	if groundAt then
		-- Across the doorway, just outside it and just inside: a shed sunk into a slope has its own
		-- ground rising inside the threshold too.
		for _, x in ipairs({ -doorway / 2, 0, doorway / 2 }) do
			for _, z in ipairs({ -halfD - 0.9, -halfD + 0.9 }) do
				local at = (base * CFrame.new(x, 0, z)).Position
				doorGround = math.max(doorGround, groundAt(at.X, at.Z) or position.Y)
			end
		end
	else
		doorGround = position.Y
	end
	local doorTop = math.min(wallHeight - 1, (doorGround - base.Position.Y) + 7)
	local pier = (width - doorway) / 2
	for _, side in ipairs({ -1, 1 }) do
		makePart(parent, Vector3.new(pier, wallHeight, 0.8), base * CFrame.new(side * (width - pier) / 2, wallHeight / 2, -halfD),
			wood, Enum.Material.WoodPlanks)
	end
	local lintel = wallHeight - doorTop
	makePart(parent, Vector3.new(doorway, lintel, 0.8), base * CFrame.new(0, doorTop + lintel / 2, -halfD), wood, Enum.Material.WoodPlanks)

	-- Flat and overhanging. Its underside sits in the same plane as the wall tops, but the two
	-- face opposite ways, which is the one arrangement the z-fight pass never has to resolve.
	currentName = "Roof"
	makePart(parent, Vector3.new(width + 1.8, 0.7, depth + 1.8), base * CFrame.new(0, wallHeight + 0.35, 0), roofColor, Enum.Material.Slate)

	-- The crate and the loot inside find their own ground rather than the shed's. A shed is one
	-- rigid box sitting on a single sampled height, so on any slope its far corner is below the
	-- surface -- and furniture placed at the shed's height ends up buried there.
	currentName = "Crate"
	local crateAt = (base * CFrame.new(halfW - 3, 0, halfD - 3)).Position
	local crateY = groundAt and groundAt(crateAt.X, crateAt.Z) or position.Y
	makePart(parent, Vector3.new(3.2, 3.2, 3.2),
		CFrame.new(crateAt.X, crateY + 1.6, crateAt.Z) * CFrame.Angles(0, math.random() * 1.2, 0),
		Color3.fromRGB(150, 116, 74), Enum.Material.WoodPlanks)
	currentName = "Part"

	if lootSpots then
		local inside = (base * CFrame.new(-2, 0, 0)).Position
		local insideY = groundAt and groundAt(inside.X, inside.Z) or position.Y
		table.insert(math.random() < 0.6 and lootSpots.weapon or lootSpots.heal,
			Vector3.new(inside.X, insideY, inside.Z))
	end
end

function MapDecor.Prop(parent, position, preset, space, groundAt, lootSpots)
	local ground = preset.terrainMaterial
	local roll = math.random()

	local kind
	if roll < 0.08 then
		-- Sheds stand on any ground: cover, and somewhere to find loot, out in the open fields.
		kind = "shed"
	elseif ground == Enum.Material.Sand then
		kind = (roll < 0.48 and "palm") or (roll < 0.66 and "cactus") or "rock"
	elseif ground == Enum.Material.Rock then
		kind = roll < 0.48 and "pine" or "rock"
	elseif ground == Enum.Material.LeafyGrass then
		kind = (roll < 0.48 and "round") or (roll < 0.67 and "hay") or (roll < 0.86 and "bush") or "rock"
	else
		kind = (roll < 0.57 and "round") or (roll < 0.76 and "pine") or (roll < 0.9 and "bush") or "rock"
	end

	local scale = 0.8 + math.random() * 0.6
	local rockSize = math.random(6, 16)
	-- A shed is 14 by 12, so its claim has to cover the half-diagonal with room for the overhang.
	local radius = (kind == "shed" and 12) or (kind == "round" and 9) or (kind == "pine" and 7 * scale) or (kind == "palm" and 4)
		or (kind == "cactus" and 4) or (kind == "bush" and 6.5) or (kind == "hay" and 6) or rockSize * 0.85

	if space then
		if not space:IsFree(position.X, position.Z, radius) then
			return false
		end
		space:AddCircle(position.X, position.Z, radius)
	end

	if kind == "shed" then
		shed(parent, position, groundAt, lootSpots)
	elseif kind == "round" then
		roundTree(parent, position)
	elseif kind == "pine" then
		pineTree(parent, position, scale)
	elseif kind == "palm" then
		palmTree(parent, position)
	elseif kind == "cactus" then
		cactus(parent, position)
	elseif kind == "bush" then
		bush(parent, position, groundAt)
	elseif kind == "hay" then
		hayBales(parent, position)
	else
		rock(parent, position, rockSize, groundAt)
	end
	return true
end

return MapDecor
