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
-- called from inside another keeps the outer one's group. Roads, bridges, signs, signals and the
-- square are never wrapped: they are the ground people stand on or steer by.
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
local PLAIN_FOOTPRINT = { length = 12.9, width = 7.3 }
local footprints = {}

local function footprintOf(modelId)
	if not footprints[modelId] then
		local probe = VehicleModels.BuildStatic(modelId, Random.new(1), CFrame.new())
		local box, size = probe:GetBoundingBox()
		probe:Destroy()
		footprints[modelId] = {
			length = 2 * (math.abs(box.Position.Z) + size.Z / 2),
			width = 2 * (math.abs(box.Position.X) + size.X / 2),
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
	makePart(parent, Vector3.new(6, 0.5, 2), look * CFrame.new(0, 2.1, 0), wood, Enum.Material.WoodPlanks)
	makePart(parent, Vector3.new(6, 1.8, 0.4), look * CFrame.new(0, 3.3, 0.9), wood, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -2.5, 2.5 }) do
		makePart(parent, Vector3.new(0.4, 2, 1.8), look * CFrame.new(x, 1, 0), METAL_DARK, Enum.Material.Metal)
	end
end

-- The town square: paving, a two-tier fountain with animated spray, benches around it and
-- planters at the corners. Returns loot spots — heals by the fountain, guns at the edges and
-- a movement item on the far side.
-- `statueDef`, when given, puts a giant statue of that brainrot in the fountain's upper bowl in
-- place of the spray.
function MapDecor.Plaza(parent, center, groundHeightAt, statueDef)
	local y = groundHeightAt(center.X, center.Z)
	local c = Vector3.new(center.X, y, center.Z)
	local marble = Color3.fromRGB(226, 222, 214)
	local water = Color3.fromRGB(70, 170, 220)

	-- Paving to the square's edge, where the streets butt against it at the same height, round a
	-- raised square of cobbles in the middle: four strips framing the cobbles rather than one slab
	-- under them, so the two never share any volume.
	currentName = "Paving"
	local paving = Color3.fromRGB(196, 190, 176)
	-- From a little under the ground, so nothing standing at ground level shares the paving's
	-- underside.
	for _, side in ipairs({ -1, 1 }) do
		clutter(makePart(parent, Vector3.new(50, 0.46, 10), CFrame.new(c + Vector3.new(0, 0.17, side * 20)), paving, Enum.Material.Pavement))
		clutter(makePart(parent, Vector3.new(10, 0.46, 30), CFrame.new(c + Vector3.new(side * 20, 0.17, 0)), paving, Enum.Material.Pavement))
	end
	currentName = "Cobbles"
	clutter(makePart(parent, Vector3.new(30, 0.52, 30), CFrame.new(c + Vector3.new(0, 0.2, 0)), Color3.fromRGB(150, 146, 138),
		Enum.Material.Cobblestone))

	currentName = "FountainWall"
	for index = 0, 7 do
		local angle = index / 8 * math.pi * 2
		makePart(parent, Vector3.new(7.4, 2.2, 1.4),
			CFrame.new(c + Vector3.new(0, 1.1, 0)) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, 8.6), marble, Enum.Material.Marble)
	end
	currentName = "FountainPool"
	local pool = clutter(makePart(parent, Vector3.new(1.2, 17, 17),
		CFrame.new(c + Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, 0, math.pi / 2), water, Enum.Material.Glass, Enum.PartType.Cylinder))
	pool.Transparency = 0.25

	currentName = "FountainColumn"
	column(parent, 5, 2, c, marble, Enum.Material.Marble)
	currentName = "FountainBowl"
	makePart(parent, Vector3.new(0.8, 7, 7), CFrame.new(c + Vector3.new(0, 5.2, 0)) * CFrame.Angles(0, 0, math.pi / 2), marble,
		Enum.Material.Marble, Enum.PartType.Cylinder)
	local bowl = clutter(makePart(parent, Vector3.new(0.3, 6, 6),
		CFrame.new(c + Vector3.new(0, 5.55, 0)) * CFrame.Angles(0, 0, math.pi / 2), water, Enum.Material.Glass, Enum.PartType.Cylinder))
	bowl.Transparency = 0.2
	currentName = "Part"

	if statueDef then
		-- The town's patron brainrot, well over life size, standing in the upper bowl.
		local scale = 2.6
		local size = statueDef.look and statueDef.look.size or 1
		local metrics = BrainrotModels.Metrics(statueDef)
		local statue = BrainrotModels.Build(statueDef, {
			scale = scale,
			cframe = CFrame.new(c + Vector3.new(0, 5.6 - metrics.bottom * scale * size, 0))
				* CFrame.Angles(0, math.random() * math.pi * 2, 0),
		})
		statue.Name = "Statue"
		statue.Parent = parent
	else
		for index, size in ipairs({ 1.4, 1.0, 0.6 }) do
			local spray = clutter(makePart(parent, Vector3.new(size, size, size), CFrame.new(c + Vector3.new(0, 5.5 + index * 1.05, 0)),
				Color3.fromRGB(180, 235, 255), Enum.Material.Neon, Enum.PartType.Ball))
			spray.Transparency = 0.2
			spray:SetAttribute("BobHeight", 0.35)
			spray:SetAttribute("BobSpeed", 3 + index)
			spray:SetAttribute("BobPhase", index)
			CollectionService:AddTag(spray, "AmbientBob")
		end
	end

	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + math.pi / 4
		benchFacing(parent, c + Vector3.new(math.cos(angle) * 15, MapDecor.CobblesTop, math.sin(angle) * 15), c)
	end
	for _, corner in ipairs({ Vector3.new(19, 0, 19), Vector3.new(-19, 0, 19), Vector3.new(19, 0, -19), Vector3.new(-19, 0, -19) }) do
		planter(parent, c + corner + Vector3.new(0, MapDecor.PavingTop, 0), 0)
	end

	return {
		-- Just outside the fountain's wall, whose ring of segments reaches 10 studs out at its corners.
		heal = { c + Vector3.new(12, MapDecor.CobblesTop, 0), c + Vector3.new(-12, MapDecor.CobblesTop, 0) },
		weapon = { c + Vector3.new(0, 0.4, 20), c + Vector3.new(20, 0.4, 0) },
		item = { c + Vector3.new(0, 0.4, -20) },
	}
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

	-- Cars parked along the edge of the street, facing the way traffic would go. The first few are
	-- real designs (DETAILED_CARS_PER_TOWN). Each is chosen before its spot is looked for, so the
	-- claim fits it, and it stands as far in from the asphalt's edge as its own width needs: the
	-- outer side 0.25 past the edge, where the plain car's wheels always were.
	local detailedLeft = DETAILED_CARS_PER_TOWN
	for _ = 1, #streets > 0 and count("cars", 4) or 0 do
		local design = parkedCarDesign(detailedLeft > 0)
		local radius, reach = design.radius, design.reach
		for _ = 1, 16 do
			local flat, direction, side, entry, surface = besideStreet(-(design.halfWidth + 2.25))
			if flat then
				local front, back = flat + direction * reach, flat - direction * reach
				if space:IsFree(front.X, front.Z, radius, entry) and space:IsFree(back.X, back.Z, radius, entry) then
					space:AddCircle(front.X, front.Z, radius)
					space:AddCircle(back.X, back.Z, radius)
					local position = Vector3.new(flat.X, groundHeightAt(flat.X, flat.Z) + surface, flat.Z)
					parkedCar(town, position, yawFacing(direction), design)
					if design.id then
						detailedLeft -= 1
					end
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
	-- Sunk like the trees are, so a slope never leaves a shed standing on one corner.
	local base = CFrame.new(position - Vector3.new(0, SINK, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
	local wallHeight = height + SINK

	currentName = "Wall"
	makePart(parent, Vector3.new(width, wallHeight, 0.8), base * CFrame.new(0, wallHeight / 2, halfD), wood, Enum.Material.WoodPlanks)
	for _, side in ipairs({ -1, 1 }) do
		makePart(parent, Vector3.new(0.8, wallHeight, depth), base * CFrame.new(side * halfW, wallHeight / 2, 0), wood, Enum.Material.WoodPlanks)
	end

	-- The front, split round a doorway you can actually walk through.
	local doorway, doorTop = 5, SINK + 7
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
