-- Landmarks: big named set pieces out between the towns, each with its own loot — somewhere to
-- drop that isn't a town, something to steer by from across the map, and a place worth a fight.
--
--   Signal Hill   a radio mast on a bunker, with a chest up on the platform for whoever climbs
--   Rot Docks     a container yard: lanes of cover, chests in the open containers, loot on top
--   The Rot Bowl  a stadium — tiered stands round a pitch under floodlights, chests in the tunnels
--   Flight 67     a crashed cargo plane, its torn-open cabin full of loot, still smoking
--   Sahur Ruins   a stone circle round an altar, a sunken chamber and torches that never go out
--   The Beacon    a lighthouse on the edge of coastal maps, its lamp sweeping the sand
--
-- and each map's own monuments, recognisable from across the map so a position can be called out:
--
--   Sahur Springs   The Great Sundial (a fifty-stud gnomon over a marble dial),
--                   Aura Windmill (turning sails, glowing purple windows), Sahur Aqueduct
--   Tralala Town    Crane Yard (a tower crane over a half-built frame), The Tralala Arch (neon gateway)
--   Bombardiro Bay  The Beached Galleon (a keeled-over warship), Sandcastle Citadel
--   Rot Ridge       The Stone Noggin (a carved head in a beanie), Turbine Ridge (three wind turbines)
--   Patapim Plains  The Giant Scarecrow, Patapim Water Tower, Crop Circle (a crashed saucer's beam)
--
-- Every map has its own set (MAP_SETS): its signature pieces always, then a pool of pieces that
-- suit it, so nothing from one map's list turns up on another (coastal maps also always get the
-- lighthouse). Each levels its own site out of the terrain (or, for long pieces, stands its feet on
-- the ground as it is), claims it in MapSpace so nothing else is built through it, and is a landing
-- spot for supply drops. Everything is primitive parts and materials, and every build-time roll is
-- on this module's own Random, seeded from one global roll.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))

local HazardService = require(script.Parent:WaitForChild("HazardService"))
local MapSpace = require(script.Parent:WaitForChild("MapSpace"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))
local ZiplineService = require(script.Parent:WaitForChild("ZiplineService"))

local Landmarks = {}

-- Every build-time roll in this module comes from here, never from math.random: Place seeds it from
-- one global roll, so however many rolls the landmarks take, nothing placed after them on the map
-- (eggs, lakes, props) sees its own rolls shift.
local rng = Random.new(1)

local function rrand(a, b)
	return rng:NextNumber(a, b)
end

-- Minimum distance between two landmarks (less on small maps; see Place).
local SPACING = 320
-- Tries per landmark before giving up on it for this map.
local TRIES = 120
-- How uneven a levelled site's ground may be. The rolling relief under every map almost never
-- stays within five studs across a hundred, which is what the old per-landmark `flat` values asked
-- for, so most landmarks quietly found no site at all. A levelled site is cut and filled to the
-- middle anyway, with a terrace round it (levelSite), so it can take a real slope.
local LEVEL_TOLERANCE = 14

local CONCRETE = Color3.fromRGB(148, 146, 140)
local DARK_CONCRETE = Color3.fromRGB(96, 96, 96)
local IRON = Color3.fromRGB(58, 60, 68)
local STEEL = Color3.fromRGB(160, 164, 172)
local RUST = Color3.fromRGB(128, 78, 48)
local STONE = Color3.fromRGB(176, 168, 150)
local OLD_STONE = Color3.fromRGB(132, 126, 112)
local WHITE = Color3.fromRGB(236, 236, 230)
local GOLD = Color3.fromRGB(255, 196, 64)
local RED = Color3.fromRGB(220, 60, 60)
local PINK = Color3.fromRGB(255, 110, 200)
local FLAME = Color3.fromRGB(255, 150, 50)

--------------------------------------------------------------------------------
-- Building helpers
--------------------------------------------------------------------------------

-- The thing being built right now, when it can be shot apart (#56): every part made is tagged
-- `Destructible = "Kind:L<n>"`, one pool for DestructibleService. Only free-standing pieces are
-- grouped (the docks' lone closed containers): a landmark's towers, platforms, ladders and
-- ziplines are what people climb and stand on, so they never break.
local currentGroup = nil
local groupSerial = 0

local function piece(parent, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	if currentGroup then
		part:SetAttribute("Destructible", currentGroup)
	end
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
	part.Parent = parent
	return part
end

-- Upright cylinder centred at `cframe`. Cylinder parts run along X, hence the quarter turn.
local function column(parent, height, diameter, cframe, color, material)
	return piece(parent, Vector3.new(height, diameter, diameter), cframe * CFrame.Angles(0, 0, math.pi / 2),
		color, material, Enum.PartType.Cylinder)
end

-- A bar from one point to another.
local function beam(parent, from, to, thickness, color, material)
	local length = (to - from).Magnitude
	return piece(parent, Vector3.new(thickness, thickness, length), CFrame.lookAt(from:Lerp(to, 0.5), to), color, material)
end

local function named(part, name)
	part.Name = name
	return part
end

-- A round bar from one point to another (beam's are square). Cylinder parts run along X.
local function rod(parent, from, to, diameter, color, material)
	local offset = to - from
	local cframe
	if math.abs(offset.Unit.Y) > 0.999 then
		cframe = CFrame.new((from + to) / 2) * CFrame.Angles(0, 0, math.pi / 2)
	else
		cframe = CFrame.lookAt((from + to) / 2, to) * CFrame.Angles(0, math.pi / 2, 0)
	end
	return piece(parent, Vector3.new(offset.Magnitude, diameter, diameter), cframe, color, material, Enum.PartType.Cylinder)
end

local function wedgePiece(parent, size, cframe, color, material)
	local wedge = Instance.new("WedgePart")
	wedge.Size = size
	wedge.CFrame = cframe
	wedge.Color = color
	wedge.Material = material or Enum.Material.SmoothPlastic
	wedge.Anchored = true
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.Parent = parent
	return wedge
end

-- A square pyramid on `base` (the centre of its bottom face): four corner wedges turned so their
-- tall corners meet over the middle. A CornerWedgePart's tall corner is at its own (+X, -Z)
-- (measured in tools/wilds_probe.lua).
local function pyramid(parent, base, width, height, color, material)
	local half = width / 2
	local apexAngle = math.atan2(-1, 1)
	for _, quadrant in ipairs({ { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }) do
		local sx, sz = quadrant[1], quadrant[2]
		local wedge = Instance.new("CornerWedgePart")
		wedge.Size = Vector3.new(half, height, half)
		wedge.CFrame = base * CFrame.new(sx * half / 2, height / 2, sz * half / 2) * CFrame.Angles(0, apexAngle - math.atan2(-sz, -sx), 0)
		wedge.Color = color
		wedge.Material = material or Enum.Material.SmoothPlastic
		wedge.Anchored = true
		wedge.Parent = parent
	end
end

-- One foot of a piece that stands on several: its own Model, its own floor height and footprint,
-- so the footing audit measures each foot rather than a box round the whole thing.
local function footing(parent, name, x, y, z, sizeX, sizeZ)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	m.WorldPivot = CFrame.new(x, y, z)
	m:SetAttribute("FootingBase", y)
	m:SetAttribute("FootingSize", Vector3.new(sizeX, 0, sizeZ))
	return m
end

local function decor(part)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

local function light(part, color, range, brightness)
	local pointLight = Instance.new("PointLight")
	pointLight.Color = color
	pointLight.Range = range
	pointLight.Brightness = brightness
	pointLight.Parent = part
	return pointLight
end

local function spin(part, degreesPerSecond)
	part:SetAttribute("SpinSpeed", degreesPerSecond)
	CollectionService:AddTag(part, "AmbientSpin")
	return part
end

local function bob(part, height, speed, phase)
	part:SetAttribute("BobHeight", height)
	part:SetAttribute("BobSpeed", speed)
	part:SetAttribute("BobPhase", phase or 0)
	CollectionService:AddTag(part, "AmbientBob")
	return part
end

-- Climbable: humanoids climb trusses natively. Sizes are multiples of two.
local function ladder(parent, cframe, height)
	local truss = Instance.new("TrussPart")
	truss.Size = Vector3.new(2, math.max(2, math.ceil(height / 2) * 2), 2)
	truss.CFrame = cframe
	truss.Anchored = true
	truss.Color = IRON
	truss.Material = Enum.Material.Metal
	truss.Parent = parent
	return truss
end

local function sign(part, text, textColor, background, faces)
	for _, face in ipairs(faces or { Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 30
		gui.LightInfluence = background and 0 or 0.3
		gui.MaxDistance = 300

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = background or Color3.new()
		label.BackgroundTransparency = background and 0 or 1
		label.BorderSizePixel = 0
		label.Font = Enum.Font.FredokaOne
		label.Text = text
		label.TextColor3 = textColor
		label.TextScaled = true
		label.TextStrokeTransparency = 0.5
		label.Parent = gui

		gui.Parent = part
	end
end

-- A plaque with the monument's name, standing on two posts facing the way it came in from.
local function nameBoard(model, cframe, text, color)
	for _, x in ipairs({ -4.5, 4.5 }) do
		column(model, 4, 0.5, cframe * CFrame.new(x, 2, 0), IRON, Enum.Material.Metal)
	end
	local board = piece(model, Vector3.new(11, 2.6, 0.4), cframe * CFrame.new(0, 4.6, 0), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(board, text, color or GOLD, Color3.fromRGB(30, 30, 36))
	return board
end


-- A flame: a bobbing neon blob with a light, for torches and beacons.
local function flame(parent, cframe, size, color)
	local core = decor(piece(parent, Vector3.new(size, size * 1.4, size), cframe, color or FLAME, Enum.Material.Neon, Enum.PartType.Ball))
	light(core, color or FLAME, 18, 1.6)
	bob(core, 0.15, 6, rng:NextNumber() * 6)
	return core
end

-- The geyser's launch, as a function rather than a closure inside the builder, so a probe can drive
-- it: the cooldown bug below can only be caught by calling it twice with a collection in between.
--
-- STRONG keys on purpose. Roblox drops an Instance's Lua handle as soon as nothing but a weak table
-- holds it, so a collection between two touches empties a weak cooldown table and the same player is
-- thrown again immediately. (Written weak here this morning to stop it holding dead characters, and
-- the same mistake was already fixed in TownThemes' springs; the leak is handled by pruning instead.)
local GEYSER_COOLDOWN = 3
local geyserLast = {}

function Landmarks.GeyserLaunch(vent, character, now)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not vent or not vent.Parent or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	now = now or os.clock()
	local times = geyserLast[vent]
	if not times then
		times = {}
		geyserLast[vent] = times
		vent.Destroying:Connect(function()
			geyserLast[vent] = nil
		end)
	end
	local last = times[character]
	if last and now - last < GEYSER_COOLDOWN then
		return nil
	end
	-- Prune what can never matter again, so a long match can't grow this without bound.
	for who, when in pairs(times) do
		if now - when > GEYSER_COOLDOWN * 4 or not who.Parent then
			times[who] = nil
		end
	end
	times[character] = now
	-- "pad": the launch whoosh and the momentum carry, and the throw follows the way you are running,
	-- like TownThemes' springs. With no kind it played the item pickup sound and a bare jump.
	local velocity = Vector3.new((math.random() - 0.5) * 16, 120, (math.random() - 0.5) * 16)
	MovementService.Launch(character, velocity, "pad")
	return velocity
end

-- What the vent's Touched does with whatever touched it: the character that part belongs to.
function Landmarks.GeyserTouched(vent, hit, now)
	return Landmarks.GeyserLaunch(vent, hit and hit:FindFirstAncestorOfClass("Model"), now)
end

-- Loot helpers: the builders register chests and pickups in world space.
local function chestAt(ctx, cframe)
	table.insert(ctx.chestSpots, cframe)
end

local function lootAt(ctx, kind, position)
	table.insert(ctx.lootSpots[kind], position)
end

-- A zipline from a high point on the landmark down to the ground `distance` studs away along
-- `direction` (a flat unit vector), where there's room for the landing. Tries a few distances.
local function ziplineFrom(model, ctx, top, direction, distance)
	for _, reach in ipairs({ distance, distance - 20, distance + 20 }) do
		local x, z = top.X + direction.X * reach, top.Z + direction.Z * reach
		if ctx.space:IsFree(x, z, 5) then
			local ground = ctx.groundHeightAt(x, z)
			if ground and ground < top.Y - 14 then
				local landing = Vector3.new(x, ground, z)
				local line = ZiplineService.Create(model, landing, landing, top)
				if line then
					ctx.space:AddCircle(x, z, 5)
					return line
				end
			end
		end
	end
	return nil
end

-- The landmark's own flat directions, from its origin.
local function flatForward(origin)
	local look = origin.LookVector
	return Vector3.new(look.X, 0, look.Z).Unit
end

local function flatRight(origin)
	local right = origin.RightVector
	return Vector3.new(right.X, 0, right.Z).Unit
end

--------------------------------------------------------------------------------
-- Signal Hill
--------------------------------------------------------------------------------

local function signalHill(model, origin, ctx)
	piece(model, Vector3.new(44, 1, 44), origin * CFrame.new(0, 0.5, 0), CONCRETE, Enum.Material.Concrete)

	-- The bunker: a concrete box with a doorway on the front, a chest and heals inside.
	local wall = Enum.Material.Concrete
	piece(model, Vector3.new(16, 1, 14), origin * CFrame.new(-12, 1.5, 8), DARK_CONCRETE, wall)
	piece(model, Vector3.new(16, 9, 1), origin * CFrame.new(-12, 5.5, 15), DARK_CONCRETE, wall)
	piece(model, Vector3.new(1, 9, 14), origin * CFrame.new(-20, 5.5, 8), DARK_CONCRETE, wall)
	piece(model, Vector3.new(1, 9, 14), origin * CFrame.new(-4, 5.5, 8), DARK_CONCRETE, wall)
	-- Front wall with a doorway in the middle.
	piece(model, Vector3.new(4.5, 9, 1), origin * CFrame.new(-18, 5.5, 1), DARK_CONCRETE, wall)
	piece(model, Vector3.new(4.5, 9, 1), origin * CFrame.new(-6, 5.5, 1), DARK_CONCRETE, wall)
	piece(model, Vector3.new(8, 2, 1), origin * CFrame.new(-12, 9, 1), DARK_CONCRETE, wall)
	piece(model, Vector3.new(17, 1, 15), origin * CFrame.new(-12, 10.5, 8), DARK_CONCRETE, wall)
	local plaque = piece(model, Vector3.new(10, 2.4, 0.4), origin * CFrame.new(-12, 8.2, 0.4), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(plaque, "SIGNAL HILL", GOLD, Color3.fromRGB(30, 30, 36), { Enum.NormalId.Front })
	chestAt(ctx, origin * CFrame.new(-12, 2, 11))
	lootAt(ctx, "heal", (origin * CFrame.new(-17, 2, 5)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-7, 2, 12)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-12, 1, -4)).Position)

	-- The mast: four legs leaning in, braced every ten studs, a platform halfway and a beacon on top.
	local height = 72
	local function legHalf(y)
		return 6 - 4.5 * (y / height)
	end
	for _, corner in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
		local from = (origin * CFrame.new(corner[1] * legHalf(0) + 8, 1, corner[2] * legHalf(0))).Position
		local to = (origin * CFrame.new(corner[1] * legHalf(height) + 8, height, corner[2] * legHalf(height))).Position
		beam(model, from, to, 0.9, IRON, Enum.Material.Metal)
	end
	for y = 8, height - 4, 8 do
		local half = legHalf(y)
		for _, side in ipairs({ -1, 1 }) do
			decor(piece(model, Vector3.new(half * 2, 0.4, 0.4), origin * CFrame.new(8, y, side * half), STEEL, Enum.Material.Metal))
			decor(piece(model, Vector3.new(0.4, 0.4, half * 2), origin * CFrame.new(8 + side * half, y, 0), STEEL, Enum.Material.Metal))
		end
	end

	local platformY = 40
	piece(model, Vector3.new(14, 0.8, 14), origin * CFrame.new(8, platformY, 0), IRON, Enum.Material.DiamondPlate)
	for _, side in ipairs({ -1, 1 }) do
		if side == 1 then
			piece(model, Vector3.new(14, 0.3, 0.3), origin * CFrame.new(8, platformY + 2.6, 6.85), STEEL, Enum.Material.Metal)
		else
			-- A gap in the rail where the ladder comes up.
			for _, x in ipairs({ -4.5, 4.5 }) do
				piece(model, Vector3.new(5, 0.3, 0.3), origin * CFrame.new(8 + x, platformY + 2.6, -6.85), STEEL, Enum.Material.Metal)
			end
		end
		piece(model, Vector3.new(0.3, 0.3, 14), origin * CFrame.new(8 + side * 6.85, platformY + 2.6, 0), STEEL, Enum.Material.Metal)
		for _, other in ipairs({ -1, 1 }) do
			piece(model, Vector3.new(0.3, 2.6, 0.3), origin * CFrame.new(8 + side * 6.85, platformY + 1.5, other * 6.85), STEEL, Enum.Material.Metal)
		end
	end
	ladder(model, origin * CFrame.new(8, (platformY + 1) / 2, -8), platformY + 1)
	chestAt(ctx, origin * CFrame.new(8, platformY + 1, 3))
	-- Loot between the legs, which come up through the platform at its corners.
	lootAt(ctx, "item", (origin * CFrame.new(2.5, platformY + 0.4, 0)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(8, platformY + 0.4, -3.5)).Position)
	-- A zipline off the platform's far rail.
	ziplineFrom(model, ctx, (origin * CFrame.new(15, platformY + 2.6, 0)).Position, flatRight(origin), 110)

	-- Dishes and the beacon.
	for index, y in ipairs({ 52, 60 }) do
		local dish = piece(model, Vector3.new(1, 5, 5), origin * CFrame.new(8 + (index == 1 and 4 or -4), y, 0)
			* CFrame.Angles(0, 0, math.rad(index == 1 and -70 or 70)), WHITE, Enum.Material.Metal, Enum.PartType.Cylinder)
		decor(dish)
	end
	-- A cap plate where the legs meet, so the crossbars and the beacon's post have something to stand on.
	piece(model, Vector3.new(4, 1, 4), origin * CFrame.new(8, height - 0.5, 0), IRON, Enum.Material.Metal)
	column(model, 6, 0.6, origin * CFrame.new(8, height + 3, 0), STEEL, Enum.Material.Metal)
	local beacon = decor(piece(model, Vector3.new(1.6, 1.6, 1.6), origin * CFrame.new(8, height + 6.5, 0), RED, Enum.Material.Neon, Enum.PartType.Ball))
	light(beacon, RED, 40, 2)
	bob(beacon, 0.2, 3, 0)
	decor(piece(model, Vector3.new(12, 0.8, 0.8), origin * CFrame.new(8, height - 1, 0), STEEL, Enum.Material.Metal))
	decor(piece(model, Vector3.new(0.8, 0.8, 12), origin * CFrame.new(8, height - 1, 0), STEEL, Enum.Material.Metal))

	-- A generator shed and fuel drums by the pad edge, for cover.
	piece(model, Vector3.new(6, 4, 4), origin * CFrame.new(14, 3, 16), Color3.fromRGB(80, 96, 70), Enum.Material.Metal)
	for index = 0, 2 do
		column(model, 3.6, 2.4, origin * CFrame.new(-2 + index * 3, 2.8, -17), index == 1 and RED or RUST, Enum.Material.CorrodedMetal)
	end
	lootAt(ctx, "weapon", (origin * CFrame.new(8, 1, -13)).Position)
end

--------------------------------------------------------------------------------
-- Rot Docks
--------------------------------------------------------------------------------

local CONTAINER_COLORS = {
	Color3.fromRGB(180, 52, 48), Color3.fromRGB(46, 96, 170), Color3.fromRGB(64, 132, 76),
	Color3.fromRGB(220, 130, 40), Color3.fromRGB(40, 140, 150), Color3.fromRGB(120, 120, 128),
}

-- A container is 8 wide, 8.5 tall, 20 long. Closed ones are solid blocks; open ones are hollow
-- with one end missing, so there's somewhere to duck into.
local function container(model, cframe, color, open)
	local ridged = Enum.Material.CorrodedMetal
	if not open then
		local box = piece(model, Vector3.new(8, 8.5, 20), cframe * CFrame.new(0, 4.25, 0), color, ridged)
		for _, z in ipairs({ -6, 0, 6 }) do
			decor(piece(model, Vector3.new(8.2, 8.3, 0.3), cframe * CFrame.new(0, 4.25, z), color:Lerp(Color3.new(0, 0, 0), 0.25), ridged))
		end
		return box
	end
	piece(model, Vector3.new(8, 0.4, 20), cframe * CFrame.new(0, 0.2, 0), color:Lerp(Color3.new(0, 0, 0), 0.3), ridged)
	piece(model, Vector3.new(8, 0.4, 20), cframe * CFrame.new(0, 8.3, 0), color, ridged)
	for _, x in ipairs({ -3.8, 3.8 }) do
		piece(model, Vector3.new(0.4, 8.5, 20), cframe * CFrame.new(x, 4.25, 0), color, ridged)
	end
	piece(model, Vector3.new(8, 8.5, 0.4), cframe * CFrame.new(0, 4.25, 9.8), color, ridged)
	-- One door hanging open.
	piece(model, Vector3.new(0.3, 8, 3.8), cframe * CFrame.new(-3.9, 4.25, -11.6) * CFrame.Angles(0, math.rad(20), 0), color, ridged)
	return nil
end

local function rotDocks(model, origin, ctx)
	-- 86 square: its corners sit just inside the ground the site claims (96 reached six studs past).
	piece(model, Vector3.new(86, 1, 86), origin * CFrame.new(0, 0.5, 0), DARK_CONCRETE, Enum.Material.Concrete)
	-- Lane markings down the two lanes between the rows.
	for _, x in ipairs({ -16, 16 }) do
		decor(piece(model, Vector3.new(0.6, 0.1, 90), origin * CFrame.new(x, 1.06, 0), Color3.fromRGB(230, 200, 60), Enum.Material.SmoothPlastic))
	end

	-- Three rows of stacks with lanes between. Some are open, some two high.
	local colorIndex = 0
	local function nextColor()
		colorIndex += 1
		return CONTAINER_COLORS[(colorIndex - 1) % #CONTAINER_COLORS + 1]
	end
	local stackTops = {}
	for row, x in ipairs({ -22, 10, 42 }) do
		for slot, z in ipairs({ -30, -10, 10, 30 }) do
			local open = (row + slot) % 5 == 0
			local base = origin * CFrame.new(x - 10, 1, z) * CFrame.Angles(0, 0, 0)
			local color = nextColor()
			-- A closed container with nothing stacked on it, other than the first (a truss climbs that
			-- one), can be shot apart; the loot some carry on top settles when it goes.
			local stacked = not open and (row * 3 + slot) % 4 == 1
			if not open and not stacked and #stackTops > 0 then
				groupSerial += 1
				currentGroup = "Container:L" .. groupSerial
			end
			container(model, base, color, open)
			currentGroup = nil
			if open then
				chestAt(ctx, base * CFrame.new(0, 1, 4))
				lootAt(ctx, "heal", (base * CFrame.new(0, 1, -4)).Position)
			elseif (row * 3 + slot) % 4 == 1 then
				container(model, base * CFrame.new(0, 8.5, 0), nextColor(), false)
				table.insert(stackTops, base * CFrame.new(0, 17.4, 0))
			else
				table.insert(stackTops, base * CFrame.new(0, 8.9, 0))
			end
		end
	end
	-- Loot on top of a few stacks, and a truss up one of them.
	for index, top in ipairs(stackTops) do
		if index % 3 == 0 then
			lootAt(ctx, index % 2 == 0 and "item" or "weapon", top.Position)
		end
	end
	-- Explosive barrels along the lanes, between the rows — cover that bites back.
	for _, offset in ipairs({ Vector3.new(-6, 0, -20), Vector3.new(-6, 0, 22), Vector3.new(26, 0, 0), Vector3.new(26, 0, -24), Vector3.new(-6, 0, 2) }) do
		HazardService.Barrel(model, origin * CFrame.new(offset + Vector3.new(0, 1, 0)) * CFrame.Angles(0, offset.Z * 0.1, 0))
	end
	if #stackTops > 0 then
		local first = stackTops[1]
		ladder(model, first * CFrame.new(-5, -(first.Position.Y - origin.Position.Y) / 2 - 0.5, 0), first.Position.Y - origin.Position.Y + 1)
	end
	-- Weapons along the lanes.
	for _, z in ipairs({ -20, 0, 20 }) do
		lootAt(ctx, "weapon", (origin * CFrame.new(-16, 1, z)).Position)
		lootAt(ctx, "weapon", (origin * CFrame.new(16, 1, z)).Position)
	end

	-- A gantry crane straddling the middle lane.
	local craneY = 30
	for _, z in ipairs({ -40, 40 }) do
		for _, x in ipairs({ -8, 28 }) do
			piece(model, Vector3.new(2, craneY, 2), origin * CFrame.new(x, craneY / 2 + 1, z), Color3.fromRGB(220, 170, 40), Enum.Material.Metal)
		end
		piece(model, Vector3.new(38, 2, 2), origin * CFrame.new(10, craneY + 1, z), Color3.fromRGB(220, 170, 40), Enum.Material.Metal)
	end
	for _, x in ipairs({ -8, 28 }) do
		piece(model, Vector3.new(2, 2, 82), origin * CFrame.new(x, craneY + 1, 0), Color3.fromRGB(220, 170, 40), Enum.Material.Metal)
	end
	-- The cross beam the trolley hangs from, between the two long rails.
	piece(model, Vector3.new(34, 2, 2), origin * CFrame.new(10, craneY + 1.1, -12), Color3.fromRGB(220, 170, 40), Enum.Material.Metal)
	local trolley = piece(model, Vector3.new(6, 3, 6), origin * CFrame.new(10, craneY - 0.5, -12), IRON, Enum.Material.Metal)
	decor(piece(model, Vector3.new(0.3, 12, 0.3), origin * CFrame.new(10, craneY - 8, -12), IRON, Enum.Material.Metal))
	local hook = decor(piece(model, Vector3.new(1.4, 2, 1.4), origin * CFrame.new(10, craneY - 14.5, -12), STEEL, Enum.Material.Metal))
	bob(hook, 0.4, 1.2, 0)
	local board = piece(model, Vector3.new(24, 4, 0.5), origin * CFrame.new(10, craneY + 4, 40), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(board, "ROT DOCKS", GOLD, Color3.fromRGB(30, 30, 36))
	light(trolley, Color3.fromRGB(255, 220, 150), 40, 1.5)
end

--------------------------------------------------------------------------------
-- The Rot Bowl
--------------------------------------------------------------------------------

local function rotBowl(model, origin, ctx)
	local pitchColor = Color3.fromRGB(72, 150, 66)
	-- Round and inside the levelled pad (footprint + 4), so no corner of it hangs over natural ground.
	column(model, 1, 112, origin * CFrame.new(0, 0.5, 0), CONCRETE, Enum.Material.Concrete)
	piece(model, Vector3.new(64, 0.4, 40), origin * CFrame.new(0, 1.2, 0), pitchColor, Enum.Material.Grass)
	-- Lines.
	for _, spec in ipairs({
		{ Vector3.new(64, 0.1, 0.5), CFrame.new(0, 1.45, -20) }, { Vector3.new(64, 0.1, 0.5), CFrame.new(0, 1.45, 20) },
		{ Vector3.new(0.5, 0.1, 40), CFrame.new(-32, 1.45, 0) }, { Vector3.new(0.5, 0.1, 40), CFrame.new(32, 1.45, 0) },
		{ Vector3.new(0.5, 0.1, 40), CFrame.new(0, 1.45, 0) },
	}) do
		decor(piece(model, spec[1], origin * spec[2], WHITE, Enum.Material.SmoothPlastic))
	end
	decor(piece(model, Vector3.new(0.12, 12, 12), origin * CFrame.new(0, 1.45, 0) * CFrame.Angles(0, 0, math.pi / 2), WHITE,
		Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))
	decor(piece(model, Vector3.new(0.14, 11, 11), origin * CFrame.new(0, 1.46, 0) * CFrame.Angles(0, 0, math.pi / 2), pitchColor,
		Enum.Material.Grass, Enum.PartType.Cylinder))

	-- Goals at both ends.
	for _, side in ipairs({ -1, 1 }) do
		local mouth = origin * CFrame.new(side * 31, 0, 0) * CFrame.Angles(0, side > 0 and math.pi / 2 or -math.pi / 2, 0)
		for _, x in ipairs({ -6, 6 }) do
			piece(model, Vector3.new(0.7, 7, 0.7), mouth * CFrame.new(x, 4.5, 0), WHITE, Enum.Material.SmoothPlastic)
		end
		piece(model, Vector3.new(12.7, 0.7, 0.7), mouth * CFrame.new(0, 8, 0), WHITE, Enum.Material.SmoothPlastic)
		local net = piece(model, Vector3.new(12.7, 7.5, 0.3), mouth * CFrame.new(0, 4.75, 3), WHITE, Enum.Material.Fabric)
		net.Transparency = 0.5
		lootAt(ctx, "weapon", (mouth * CFrame.new(0, 1.5, -8)).Position)
	end

	-- Stands: three tiers on every side, with the corners left open as entrances.
	local seatColors = { Color3.fromRGB(200, 60, 70), Color3.fromRGB(240, 200, 60), Color3.fromRGB(60, 110, 200) }
	for tier = 1, 3 do
		local inset = 24 + tier * 4.5
		local y = 1 + tier * 3
		local depth = 4.5
		for _, side in ipairs({ -1, 1 }) do
			piece(model, Vector3.new(60, 3, depth), origin * CFrame.new(0, y - 1.5, side * inset), CONCRETE, Enum.Material.Concrete)
			piece(model, Vector3.new(36, 3, depth), origin * CFrame.new(side * inset, y - 1.5, 0) * CFrame.Angles(0, math.pi / 2, 0), CONCRETE, Enum.Material.Concrete)
			-- Seats: a striped strip along the back of each step.
			for step = 0, 14 do
				local x = -28 + step * 4
				decor(piece(model, Vector3.new(3.2, 0.9, 1.4), origin * CFrame.new(x, y + 0.45, side * (inset + 1.2)), seatColors[(step + tier) % 3 + 1], Enum.Material.SmoothPlastic))
			end
			for step = 0, 8 do
				local z = -16 + step * 4
				decor(piece(model, Vector3.new(1.4, 0.9, 3.2), origin * CFrame.new(side * (inset + 1.2), y + 0.45, z), seatColors[(step + tier) % 3 + 1], Enum.Material.SmoothPlastic))
			end
		end
	end
	-- Back walls behind the top tier, and the tunnels under the stands at the corners.
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(62, 6, 1), origin * CFrame.new(0, 13, side * 40), DARK_CONCRETE, Enum.Material.Concrete)
		piece(model, Vector3.new(38, 6, 1), origin * CFrame.new(side * 40, 13, 0) * CFrame.Angles(0, math.pi / 2, 0), DARK_CONCRETE, Enum.Material.Concrete)
		for _, other in ipairs({ -1, 1 }) do
			local corner = origin * CFrame.new(side * 36, 0, other * 36)
			chestAt(ctx, corner * CFrame.new(0, 1.5, 0))
			lootAt(ctx, "heal", (corner * CFrame.new(side * 4, 1.5, 0)).Position)
			-- Floodlight mast in each corner.
			local mast = corner * CFrame.new(side * 12, 0, other * 12)
			piece(model, Vector3.new(1.6, 34, 1.6), mast * CFrame.new(0, 18, 0), IRON, Enum.Material.Metal)
			local head = piece(model, Vector3.new(7, 4, 1.2), mast * CFrame.new(0, 36, 0) * CFrame.lookAt(Vector3.zero, Vector3.new(-side, 0, -other)), IRON, Enum.Material.Metal)
			for lamp = -1, 1 do
				decor(piece(model, Vector3.new(1.8, 1.8, 0.4), head.CFrame * CFrame.new(lamp * 2.2, 0, -0.7), Color3.fromRGB(255, 244, 210), Enum.Material.Neon))
			end
			local spot = Instance.new("SpotLight")
			spot.Face = Enum.NormalId.Front
			spot.Angle = 70
			spot.Range = 90
			spot.Brightness = 1.6
			spot.Color = Color3.fromRGB(255, 244, 210)
			spot.Parent = head
		end
	end
	-- Items up on the top tier, and a zipline out over the back wall from it.
	for _, side in ipairs({ -1, 1 }) do
		-- In the gangway between the blocks of seats, not among them.
		lootAt(ctx, "item", (origin * CFrame.new(side * 18, 11, side * 35.5)).Position)
		lootAt(ctx, "weapon", (origin * CFrame.new(side * 35.5, 11, -side * 8)).Position)
	end
	ziplineFrom(model, ctx, (origin * CFrame.new(0, 16.5, 41)).Position, flatForward(origin) * -1, 120)

	-- The scoreboard over one end.
	local board = piece(model, Vector3.new(30, 8, 1), origin * CFrame.new(0, 22, -41), Color3.fromRGB(22, 22, 30), Enum.Material.Metal)
	for _, x in ipairs({ -13, 13 }) do
		piece(model, Vector3.new(1.2, 10, 1.2), origin * CFrame.new(x, 15, -41), IRON, Enum.Material.Metal)
	end
	sign(board, "THE ROT BOWL   •   67 - 67", GOLD, Color3.fromRGB(22, 22, 30))
	light(board, GOLD, 40, 1.5)
end

--------------------------------------------------------------------------------
-- Flight 67
--------------------------------------------------------------------------------

local function flight67(model, origin, ctx)
	local hull = Color3.fromRGB(214, 216, 220)
	local scorched = Color3.fromRGB(44, 42, 40)
	decor(piece(model, Vector3.new(70, 0.3, 40), origin * CFrame.new(-4, 0.15, 0), scorched, Enum.Material.Basalt))
	-- A furrow where it came down.
	decor(piece(model, Vector3.new(40, 0.35, 8), origin * CFrame.new(-26, 0.16, 4) * CFrame.Angles(0, math.rad(-8), 0), Color3.fromRGB(70, 60, 50), Enum.Material.Ground))

	-- Nose section, half buried and tipped nose-down, so the cone digs into the ground. (Tipped the
	-- other way it lifted the cone a stud clear of the grass: tools/foundation_check.py.)
	local nose = origin * CFrame.new(20, 4.5, 0) * CFrame.Angles(0, 0, math.rad(-6)) * CFrame.Angles(0, math.rad(-8), 0)
	piece(model, Vector3.new(22, 11, 11), nose * CFrame.Angles(0, 0, 0), hull, Enum.Material.Metal, Enum.PartType.Cylinder)
	piece(model, Vector3.new(10, 10, 10), nose * CFrame.new(14, 0, 0), hull, Enum.Material.Metal, Enum.PartType.Ball)
	decor(piece(model, Vector3.new(4, 3, 8), nose * CFrame.new(11, 3.2, 0), Color3.fromRGB(60, 90, 120), Enum.Material.Glass))
	decor(piece(model, Vector3.new(22, 1.2, 11.3), nose * CFrame.new(0, 0, 0), RED, Enum.Material.Metal))

	-- The torn-open cabin: floor, one wall, roof, rows of seats, and the loot.
	local cabin = origin * CFrame.new(-6, 0, 0)
	piece(model, Vector3.new(26, 0.8, 11), cabin * CFrame.new(0, 1.4, 0), Color3.fromRGB(90, 92, 98), Enum.Material.Metal)
	piece(model, Vector3.new(26, 9, 0.8), cabin * CFrame.new(0, 5.9, 5.4), hull, Enum.Material.Metal)
	piece(model, Vector3.new(26, 0.8, 8), cabin * CFrame.new(0, 10.4, 1.4), hull, Enum.Material.Metal)
	for index = 0, 3 do
		decor(piece(model, Vector3.new(2, 1.8, 1.6), cabin * CFrame.new(-8 + index * 5, 2.7, 0.6 + index * 0.4), Color3.fromRGB(80, 80, 140), Enum.Material.SmoothPlastic))
	end
	for index = 0, 2 do
		decor(piece(model, Vector3.new(1.6, 1.4, 1.2), cabin * CFrame.new(-10 + index * 7, 6.5, 4.6), Color3.fromRGB(180, 180, 190), Enum.Material.SmoothPlastic))
	end
	chestAt(ctx, cabin * CFrame.new(-9, 2.6, -2))
	-- Clear of the last row of seats, toward the torn-open end of the cabin.
	chestAt(ctx, cabin * CFrame.new(10.5, 2.6, -2.5))
	lootAt(ctx, "heal", (cabin * CFrame.new(0, 2.2, 3)).Position)
	lootAt(ctx, "weapon", (cabin * CFrame.new(4, 2.2, -3)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(13, 1, -9)).Position)

	-- Tail section on its side, further back.
	local tail = origin * CFrame.new(-30, 4, 8) * CFrame.Angles(0, math.rad(25), math.rad(35))
	piece(model, Vector3.new(18, 9, 9), tail, hull, Enum.Material.Metal, Enum.PartType.Cylinder)
	piece(model, Vector3.new(9, 12, 1.2), tail * CFrame.new(-7, 8, 0), RED, Enum.Material.Metal)
	piece(model, Vector3.new(6, 1, 14), tail * CFrame.new(-6, 3, 0), hull, Enum.Material.Metal)
	lootAt(ctx, "item", (origin * CFrame.new(-34, 1, -4)).Position)

	-- Wings: one still on, one torn off, with an engine each.
	local wing = origin * CFrame.new(4, 5, -10) * CFrame.Angles(0, math.rad(15), math.rad(4))
	piece(model, Vector3.new(30, 1, 10), wing, hull, Enum.Material.Metal)
	column(model, 8, 4.4, wing * CFrame.new(-4, -2.5, -2) * CFrame.Angles(0, 0, math.pi / 2), STEEL, Enum.Material.Metal)
	local lost = origin * CFrame.new(-14, 2, 22) * CFrame.Angles(0, math.rad(-40), math.rad(30))
	piece(model, Vector3.new(24, 1, 9), lost, hull, Enum.Material.Metal)
	column(model, 7, 4, origin * CFrame.new(10, 2, 18) * CFrame.Angles(0, math.rad(60), math.rad(80)), STEEL, Enum.Material.CorrodedMetal)
	lootAt(ctx, "item", (wing * CFrame.new(8, 1, 0)).Position)

	-- Cargo thrown clear.
	for index = 0, 3 do
		local angle = index * 1.7
		local crate = origin * CFrame.new(16 + math.cos(angle) * 14, 1.5, 14 + math.sin(angle) * 10) * CFrame.Angles(0, angle, 0)
		piece(model, Vector3.new(3, 3, 3), crate, Color3.fromRGB(150, 108, 62), Enum.Material.WoodPlanks)
	end
	lootAt(ctx, "weapon", (origin * CFrame.new(24, 1, 22)).Position)

	-- Still smoking. Smoke comes off the engine and the cabin.
	for _, spot in ipairs({ wing * CFrame.new(-4, 1, -2), cabin * CFrame.new(8, 11.4, 1.4) }) do
		local source = decor(piece(model, Vector3.new(1, 1, 1), spot, scorched, Enum.Material.SmoothPlastic))
		source.Transparency = 1
		local smoke = Instance.new("ParticleEmitter")
		smoke.Color = ColorSequence.new(Color3.fromRGB(60, 60, 64), Color3.fromRGB(110, 110, 114))
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 8) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
		smoke.Lifetime = NumberRange.new(3, 5)
		smoke.Rate = 5
		smoke.Speed = NumberRange.new(3, 5)
		smoke.SpreadAngle = Vector2.new(15, 15)
		smoke.Parent = source
		flame(model, spot * CFrame.new(0, -0.5, 0), 1.6)
	end

	local board = piece(model, Vector3.new(8, 2.2, 0.4), origin * CFrame.new(30, 3, 12), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	for _, x in ipairs({ -3.5, 3.5 }) do
		piece(model, Vector3.new(0.4, 3, 0.4), origin * CFrame.new(30 + x, 1.5, 12), IRON, Enum.Material.Metal)
	end
	sign(board, "FLIGHT 67  •  DO NOT ENTER", GOLD, Color3.fromRGB(30, 30, 36))
end

--------------------------------------------------------------------------------
-- Sahur Ruins
--------------------------------------------------------------------------------

local function sahurRuins(model, origin, ctx)
	local stone = Enum.Material.Cobblestone
	-- Round and inside the levelled pad (footprint + 4), so no corner of it hangs over natural ground.
	decor(column(model, 0.3, 72, origin * CFrame.new(0, 0.15, 0), Color3.fromRGB(150, 146, 130), Enum.Material.Cobblestone))

	-- The circle: broken columns of different heights, three still carrying a lintel.
	local heights = { 14, 6, 11, 4, 14, 9, 3, 12 }
	local tops = {}
	for index = 0, 7 do
		local angle = index / 8 * math.pi * 2
		local at = origin * CFrame.new(math.cos(angle) * 22, 0, math.sin(angle) * 22)
		local height = heights[index + 1]
		column(model, 1, 5, at * CFrame.new(0, 0.8, 0), OLD_STONE, stone)
		column(model, height, 3.6, at * CFrame.new(0, 1.3 + height / 2, 0), STONE, stone)
		if height >= 11 then
			column(model, 0.8, 4.4, at * CFrame.new(0, 1.7 + height, 0), OLD_STONE, stone)
		end
		tops[index + 1] = at * CFrame.new(0, 1.3 + height + 0.9, 0)
	end
	for _, pair in ipairs({ { 1, 8 }, { 5, 6 } }) do
		local a, b = tops[pair[1]].Position, tops[pair[2]].Position
		beam(model, a, b, 2.4, OLD_STONE, stone)
	end
	-- A fallen column leans on the tallest as a ramp up to its top.
	local tallest = tops[1]
	local foot = (origin * CFrame.new(math.cos(math.rad(30)) * 38, 0.8, math.sin(math.rad(30)) * 38)).Position
	local head = tallest.Position + Vector3.new(0, -0.6, 0)
	local rampLength = (head - foot).Magnitude
	piece(model, Vector3.new(3.6, 3.6, rampLength), CFrame.lookAt(foot:Lerp(head, 0.5), head), STONE, stone)
	-- A capstone on it: the lintel and the ramp both end at its middle, so the item sits on the side
	-- facing into the circle, clear of both.
	piece(model, Vector3.new(8, 1, 8), tallest * CFrame.new(0, 0.5, 0), OLD_STONE, stone)
	lootAt(ctx, "item", (tallest * CFrame.new(-2.3, 1.4, 1.2)).Position)

	-- The altar in the middle, with a chest on it and torches round it.
	piece(model, Vector3.new(12, 1.2, 12), origin * CFrame.new(0, 0.9, 0), OLD_STONE, stone)
	piece(model, Vector3.new(8, 1.2, 8), origin * CFrame.new(0, 2.1, 0), STONE, stone)
	piece(model, Vector3.new(4, 2, 4), origin * CFrame.new(0, 3.7, 0), OLD_STONE, stone)
	chestAt(ctx, origin * CFrame.new(0, 4.8, 0))
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + math.pi / 4
		local at = origin * CFrame.new(math.cos(angle) * 9, 0, math.sin(angle) * 9)
		column(model, 5, 0.8, at * CFrame.new(0, 2.8, 0), Color3.fromRGB(70, 56, 40), Enum.Material.Wood)
		flame(model, at * CFrame.new(0, 5.9, 0), 1.2)
	end
	lootAt(ctx, "weapon", (origin * CFrame.new(-8, 1.5, 0)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(0, 1.5, 12)).Position)

	-- A sunken chamber under one edge: steps down into a stone room with a chest and heals. The
	-- site was levelled to ground, so the room and the stairwell are carved out of the terrain.
	local chamber = origin * CFrame.new(0, 0, -30)
	local depth = 7
	-- Cut the surface lift deeper than the floor slab, so the ground's surface inside ends up
	-- under the slab rather than over it.
	local cut = depth + 3 + MapTerrain.SurfaceLift
	workspace.Terrain:FillBlock(chamber * CFrame.new(0, -cut / 2 + 2, 0), Vector3.new(19, cut, 19), Enum.Material.Air)
	workspace.Terrain:FillBlock(chamber * CFrame.new(0, -cut / 2 + 2, 12), Vector3.new(9, cut, 10), Enum.Material.Air)
	piece(model, Vector3.new(16, 1, 16), chamber * CFrame.new(0, -depth - 0.5, 0), OLD_STONE, stone)
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(1, depth + 1, 16), chamber * CFrame.new(side * 8, -depth / 2, 0), OLD_STONE, stone)
	end
	piece(model, Vector3.new(16, depth + 1, 1), chamber * CFrame.new(0, -depth / 2, -8), OLD_STONE, stone)
	-- The open side toward the circle has the stairs.
	for step = 1, 7 do
		piece(model, Vector3.new(6, 1, 2), chamber * CFrame.new(0, -step + 0.5, 8 + step * 0.9), STONE, stone)
	end
	piece(model, Vector3.new(5, depth + 1, 1), chamber * CFrame.new(-5.5, -depth / 2, 8), OLD_STONE, stone)
	piece(model, Vector3.new(5, depth + 1, 1), chamber * CFrame.new(5.5, -depth / 2, 8), OLD_STONE, stone)
	-- A slab roof with a hole where the light gets in.
	piece(model, Vector3.new(16, 1, 6), chamber * CFrame.new(0, 0.5, -5), OLD_STONE, stone)
	piece(model, Vector3.new(16, 1, 5), chamber * CFrame.new(0, 0.5, 5.5), OLD_STONE, stone)
	piece(model, Vector3.new(5, 1, 5), chamber * CFrame.new(-5.5, 0.5, 0), OLD_STONE, stone)
	piece(model, Vector3.new(5, 1, 5), chamber * CFrame.new(5.5, 0.5, 0), OLD_STONE, stone)
	chestAt(ctx, chamber * CFrame.new(0, -depth + 1, -4))
	lootAt(ctx, "heal", (chamber * CFrame.new(-5, -depth + 0.5, 3)).Position)
	lootAt(ctx, "heal", (chamber * CFrame.new(5, -depth + 0.5, -2)).Position)
	for _, x in ipairs({ -6.5, 6.5 }) do
		column(model, 3.6, 0.6, chamber * CFrame.new(x, -depth + 1.8, -6.5), Color3.fromRGB(70, 56, 40), Enum.Material.Wood)
		flame(model, chamber * CFrame.new(x, -depth + 4, -6.5), 1)
	end

	local tablet = piece(model, Vector3.new(6, 4, 0.8), origin * CFrame.new(28, 2.2, 10) * CFrame.Angles(0, math.rad(-60), 0), OLD_STONE, Enum.Material.Slate)
	sign(tablet, "SAHUR RUINS", Color3.fromRGB(240, 226, 180))
	-- Rubble.
	for index = 0, 5 do
		local angle = index * 1.1
		piece(model, Vector3.new(2 + index % 3, 1.5, 2.5), origin * CFrame.new(math.cos(angle) * 30, 0.9, math.sin(angle) * 30) * CFrame.Angles(0, angle, 0.2), OLD_STONE, stone)
	end
end

--------------------------------------------------------------------------------
-- The Beacon
--------------------------------------------------------------------------------

local function beacon(model, origin, ctx)
	piece(model, Vector3.new(30, 1, 30), origin * CFrame.new(0, 0.5, 0), CONCRETE, Enum.Material.Concrete)

	-- The tower: stacked cylinders tapering up, banded red and white.
	local y = 1
	for index = 0, 7 do
		local diameter = 12 - index * 0.9
		column(model, 6, diameter, origin * CFrame.new(0, y + 3, 0), index % 2 == 0 and WHITE or RED, Enum.Material.Concrete)
		y += 6
	end
	-- Gallery and light room.
	local galleryY = y
	-- Wide enough to walk round the lamp room (radius 3.5) with a chest against the rail.
	column(model, 1, 16, origin * CFrame.new(0, galleryY + 0.5, 0), IRON, Enum.Material.DiamondPlate)
	for index = 0, 11 do
		-- No post where the ladder tops out.
		if index ~= 9 then
			local angle = index / 12 * math.pi * 2
			piece(model, Vector3.new(0.3, 3, 0.3), origin * CFrame.new(math.cos(angle) * 7.8, galleryY + 2.5, math.sin(angle) * 7.8), IRON, Enum.Material.Metal)
		end
	end
	decor(piece(model, Vector3.new(0.4, 12.2, 12.2), origin * CFrame.new(0, galleryY + 4, 0) * CFrame.Angles(0, 0, math.pi / 2), IRON, Enum.Material.Metal, Enum.PartType.Cylinder))
	local glass = column(model, 8, 7, origin * CFrame.new(0, galleryY + 5, 0), Color3.fromRGB(200, 230, 255), Enum.Material.Glass)
	glass.Transparency = 0.55
	-- Walked through, so shot through as well.
	decor(glass)
	column(model, 1.5, 8.5, origin * CFrame.new(0, galleryY + 9.5, 0), IRON, Enum.Material.Metal)
	-- The lamp: a bright core and a sweeping beam, turned locally by AmbientClient.
	local core = decor(piece(model, Vector3.new(2.4, 2.4, 2.4), origin * CFrame.new(0, galleryY + 5, 0), Color3.fromRGB(255, 244, 200), Enum.Material.Neon, Enum.PartType.Ball))
	light(core, Color3.fromRGB(255, 240, 190), 120, 3)
	local sweep = decor(piece(model, Vector3.new(60, 1.4, 1.4), origin * CFrame.new(0, galleryY + 5, 0), Color3.fromRGB(255, 244, 200), Enum.Material.Neon))
	sweep.Transparency = 0.6
	spin(sweep, 30)

	-- Up the outside of the tower, which narrows away from the truss as it climbs.
	ladder(model, origin * CFrame.new(0, galleryY / 2 + 0.5, -9.2), galleryY)
	-- Against the rail, its long side along it, clear of the lamp room.
	chestAt(ctx, origin * CFrame.new(5.6, galleryY + 1.5, 0) * CFrame.Angles(0, math.pi / 2, 0))
	lootAt(ctx, "item", (origin * CFrame.new(-5.6, galleryY + 1.4, 0)).Position)
	-- A zipline from the gallery rail down the beach, away from the cottage.
	ziplineFrom(model, ctx, (origin * CFrame.new(-7.8, galleryY + 4, 0)).Position, flatRight(origin) * -1, 100)

	-- The keeper's cottage beside it.
	local cottage = origin * CFrame.new(14, 0, 8)
	piece(model, Vector3.new(12, 1, 10), cottage * CFrame.new(0, 1.5, 0), Color3.fromRGB(120, 92, 60), Enum.Material.WoodPlanks)
	piece(model, Vector3.new(12, 7, 1), cottage * CFrame.new(0, 4.5, 5), WHITE, Enum.Material.Concrete)
	piece(model, Vector3.new(1, 7, 10), cottage * CFrame.new(6, 4.5, 0), WHITE, Enum.Material.Concrete)
	piece(model, Vector3.new(1, 7, 10), cottage * CFrame.new(-6, 4.5, 0), WHITE, Enum.Material.Concrete)
	piece(model, Vector3.new(3, 7, 1), cottage * CFrame.new(-4.5, 4.5, -5), WHITE, Enum.Material.Concrete)
	piece(model, Vector3.new(3, 7, 1), cottage * CFrame.new(4.5, 4.5, -5), WHITE, Enum.Material.Concrete)
	piece(model, Vector3.new(6, 1.5, 1), cottage * CFrame.new(0, 7.25, -5), WHITE, Enum.Material.Concrete)
	piece(model, Vector3.new(13, 1, 11), cottage * CFrame.new(0, 8.5, 0), RED, Enum.Material.Slate)
	chestAt(ctx, cottage * CFrame.new(-3, 2.5, 2))
	lootAt(ctx, "heal", (cottage * CFrame.new(3, 2.4, -2)).Position)
	lootAt(ctx, "weapon", (cottage * CFrame.new(0, 1.5, -9)).Position)

	local board = piece(model, Vector3.new(8, 2.2, 0.4), origin * CFrame.new(-10, 3, 10), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(board, "THE BEACON", GOLD, Color3.fromRGB(30, 30, 36))
	-- Rocks round the base.
	for index = 0, 5 do
		local angle = index * 1.05
		piece(model, Vector3.new(4 + index % 2 * 2, 2.5, 3.5), origin * CFrame.new(math.cos(angle) * 18, 1.2, math.sin(angle) * 18) * CFrame.Angles(0, angle, 0.15), Color3.fromRGB(110, 104, 96), Enum.Material.Rock)
	end
end

--------------------------------------------------------------------------------
-- Brainrot Carnival
--------------------------------------------------------------------------------

local CARNIVAL_COLORS = {
	Color3.fromRGB(255, 90, 120), Color3.fromRGB(255, 200, 60), Color3.fromRGB(90, 220, 140),
	Color3.fromRGB(80, 170, 255), Color3.fromRGB(200, 110, 255),
}

local function carnival(model, origin, ctx)
	-- Round and inside the levelled pad (footprint + 4), so no corner of it hangs over natural ground.
	column(model, 1, 100, origin * CFrame.new(0, 0.5, 0), Color3.fromRGB(120, 100, 82), Enum.Material.Ground)

	-- The ferris wheel: an A-frame either side, the axle between, and the wheel — rim, spokes
	-- and eight cabins — as one spinning group hung on the axle hub.
	local wheelCenter = origin * CFrame.new(-22, 26, 0)
	for _, side in ipairs({ -1, 1 }) do
		for _, lean in ipairs({ -1, 1 }) do
			local foot = (origin * CFrame.new(-22 + lean * 9, 1, side * 5)).Position
			beam(model, foot, wheelCenter.Position + Vector3.new(0, 0, side * 5 * 0.9) - origin.LookVector * 0, 1.2, IRON, Enum.Material.Metal)
		end
	end
	piece(model, Vector3.new(1.4, 1.4, 12), wheelCenter, STEEL, Enum.Material.Metal)
	-- The hub is a part whose Y axis runs along the axle, so AmbientSpin turns the wheel.
	local hub = decor(piece(model, Vector3.new(3, 2, 3), wheelCenter * CFrame.Angles(math.pi / 2, 0, 0), GOLD, Enum.Material.Foil, Enum.PartType.Cylinder))
	hub.Name = "FerrisHub"
	local radius = 20
	for index = 0, 7 do
		local angle = index / 8 * math.pi * 2
		local at = wheelCenter * CFrame.new(math.cos(angle) * radius, math.sin(angle) * radius, 0)
		-- Spoke, rim segment and a cabin hanging under the rim point (kept upright by being a
		-- box on the rim; it turns with the wheel).
		local spoke = decor(piece(hub, Vector3.new(0.5, radius, 0.5), wheelCenter * CFrame.Angles(0, 0, angle) * CFrame.new(0, radius / 2, 0),
			STEEL, Enum.Material.Metal))
		local nextAngle = (index + 1) / 8 * math.pi * 2
		local nextAt = wheelCenter * CFrame.new(math.cos(nextAngle) * radius, math.sin(nextAngle) * radius, 0)
		decor(piece(hub, Vector3.new(0.6, 0.6, (nextAt.Position - at.Position).Magnitude), CFrame.lookAt(at.Position:Lerp(nextAt.Position, 0.5), nextAt.Position),
			CARNIVAL_COLORS[(index % 5) + 1], Enum.Material.Neon))
		local cabin = decor(piece(hub, Vector3.new(3.2, 3, 3.2), at * CFrame.new(0, -2.2, 0), CARNIVAL_COLORS[(index % 5) + 1], Enum.Material.SmoothPlastic))
		decor(piece(hub, Vector3.new(3.4, 0.4, 3.4), at * CFrame.new(0, -0.6, 0), DARK_CONCRETE, Enum.Material.Metal))
		spoke.Name = "Spoke"
		cabin.Name = "Cabin"
	end
	spin(hub, 9)
	light(hub, GOLD, 40, 1.5)

	-- The carousel: a round deck, a striped roof on a pole, and horses on poles that go round.
	local carouselCenter = origin * CFrame.new(20, 1, 12)
	piece(model, Vector3.new(1, 22, 22), carouselCenter * CFrame.new(0, 0.5, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(150, 110, 70),
		Enum.Material.WoodPlanks, Enum.PartType.Cylinder)
	column(model, 12, 1.2, carouselCenter * CFrame.new(0, 7, 0), STEEL, Enum.Material.Metal)
	local roof = piece(model, Vector3.new(1.5, 24, 24), carouselCenter * CFrame.new(0, 13.5, 0) * CFrame.Angles(0, 0, math.pi / 2), RED, Enum.Material.Fabric,
		Enum.PartType.Cylinder)
	for index = 0, 7 do
		local angle = index / 8 * math.pi * 2
		decor(piece(model, Vector3.new(3, 0.3, 11), carouselCenter * CFrame.new(0, 14.4, 0) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -6),
			index % 2 == 0 and WHITE or RED, Enum.Material.Fabric))
	end
	local platter = decor(piece(model, Vector3.new(0.6, 1.5, 0.6), carouselCenter * CFrame.new(0, 8, 0), GOLD, Enum.Material.Foil))
	platter.Name = "CarouselHub"
	for index = 0, 5 do
		local angle = index / 6 * math.pi * 2
		local at = carouselCenter * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -8)
		decor(piece(platter, Vector3.new(0.3, 10, 0.3), at * CFrame.new(0, 6, 0), GOLD, Enum.Material.Foil))
		-- A horse: body, neck, head, four legs, in a bright colour.
		local horse = CARNIVAL_COLORS[(index % 5) + 1]
		local body = at * CFrame.new(0, 4.5 + (index % 2) * 0.8, 0) * CFrame.Angles(0, math.pi / 2, 0)
		decor(piece(platter, Vector3.new(1.6, 1.6, 3.4), body, horse, Enum.Material.SmoothPlastic))
		decor(piece(platter, Vector3.new(0.9, 1.8, 0.9), body * CFrame.new(0, 1.3, -1.5) * CFrame.Angles(0.5, 0, 0), horse, Enum.Material.SmoothPlastic))
		decor(piece(platter, Vector3.new(0.9, 0.9, 1.6), body * CFrame.new(0, 2.2, -2.3), horse, Enum.Material.SmoothPlastic))
		for _, dx in ipairs({ -0.5, 0.5 }) do
			for _, dz in ipairs({ -1.2, 1.2 }) do
				decor(piece(platter, Vector3.new(0.4, 1.8, 0.4), body * CFrame.new(dx, -1.6, dz) * CFrame.Angles(dz > 0 and -0.4 or 0.4, 0, 0), horse,
					Enum.Material.SmoothPlastic))
			end
		end
	end
	spin(platter, 18)
	light(roof, PINK, 30, 1.2)

	-- Booths along the front: a ticket booth with the chest, a popcorn stand, a ring toss.
	local function booth(at, name, color)
		piece(model, Vector3.new(10, 0.6, 8), at * CFrame.new(0, 1.3, 0), Color3.fromRGB(150, 110, 70), Enum.Material.WoodPlanks)
		for _, x in ipairs({ -4.5, 4.5 }) do
			for _, z in ipairs({ -3.5, 3.5 }) do
				piece(model, Vector3.new(0.6, 8, 0.6), at * CFrame.new(x, 5, z), Color3.fromRGB(90, 66, 44), Enum.Material.Wood)
			end
		end
		piece(model, Vector3.new(10, 6, 0.4), at * CFrame.new(0, 4.6, 3.8), color, Enum.Material.SmoothPlastic)
		piece(model, Vector3.new(8, 2.6, 1.2), at * CFrame.new(0, 2.9, -3.2), Color3.fromRGB(90, 66, 44), Enum.Material.WoodPlanks)
		for index = 0, 4 do
			decor(piece(model, Vector3.new(2, 0.3, 8.6), at * CFrame.new(-4 + index * 2, 9.2, 0) * CFrame.Angles(-0.12, 0, 0),
				index % 2 == 0 and color or WHITE, Enum.Material.Fabric))
		end
		local board = decor(piece(model, Vector3.new(8, 1.8, 0.3), at * CFrame.new(0, 7.2, -3.9), Color3.fromRGB(30, 30, 36), Enum.Material.Metal))
		sign(board, name, color, Color3.fromRGB(30, 30, 36), { Enum.NormalId.Front })
	end
	booth(origin * CFrame.new(-14, 0, -32), "TICKETS", CARNIVAL_COLORS[1])
	booth(origin * CFrame.new(2, 0, -32), "POPCORN", CARNIVAL_COLORS[2])
	booth(origin * CFrame.new(18, 0, -32), "RING TOSS", CARNIVAL_COLORS[4])
	chestAt(ctx, origin * CFrame.new(-14, 2, -30))
	chestAt(ctx, origin * CFrame.new(18, 2, -30))
	lootAt(ctx, "heal", (origin * CFrame.new(2, 2, -30)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-6, 1.5, -22)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(10, 1.5, -22)).Position)
	lootAt(ctx, "item", (origin * CFrame.new(16, 2, 12)).Position)
	lootAt(ctx, "item", (origin * CFrame.new(-22, 1.5, -10)).Position)

	-- Bunting between poles round the ground, and the entrance arch.
	for index = 0, 5 do
		local angle = index / 6 * math.pi * 2
		local foot = origin * CFrame.new(math.cos(angle) * 44, 0, math.sin(angle) * 44)
		column(model, 9, 0.5, foot * CFrame.new(0, 5.5, 0), IRON, Enum.Material.Metal)
		local nextAngle = (index + 1) / 6 * math.pi * 2
		local nextFoot = origin * CFrame.new(math.cos(nextAngle) * 44, 0, math.sin(nextAngle) * 44)
		-- The rope sags to a low point halfway, in two straight runs; each pennant hangs from it.
		local top = Vector3.new(0, 10, 0)
		local low = foot.Position:Lerp(nextFoot.Position, 0.5) + Vector3.new(0, 8, 0)
		decor(rod(model, foot.Position + top, low, 0.15, WHITE, Enum.Material.Fabric))
		decor(rod(model, low, nextFoot.Position + top, 0.15, WHITE, Enum.Material.Fabric))
		for step = 1, 7 do
			local t = step / 8
			local ropeAt = t <= 0.5 and (foot.Position + top):Lerp(low, t * 2) or low:Lerp(nextFoot.Position + top, t * 2 - 1)
			local at = ropeAt - Vector3.new(0, 0.5, 0)
			decor(piece(model, Vector3.new(0.9, 1.1, 0.1), CFrame.lookAt(at, nextFoot.Position + Vector3.new(0, at.Y - nextFoot.Position.Y, 0)),
				CARNIVAL_COLORS[(step % 5) + 1], Enum.Material.Fabric))
		end
	end
	local archAt = origin * CFrame.new(0, 0, -46)
	for _, x in ipairs({ -8, 8 }) do
		column(model, 14, 1.2, archAt * CFrame.new(x, 8, 0), RED, Enum.Material.SmoothPlastic)
	end
	local arch = piece(model, Vector3.new(19, 3.4, 1), archAt * CFrame.new(0, 14.7, 0), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(arch, "BRAINROT CARNIVAL", GOLD, Color3.fromRGB(30, 30, 36))
	light(arch, GOLD, 40, 1.5)
	for index = 0, 9 do
		decor(piece(model, Vector3.new(0.6, 0.6, 0.6), archAt * CFrame.new(-8.5 + index * 1.9, 16.6, 0), index % 2 == 0 and GOLD or PINK, Enum.Material.Neon,
			Enum.PartType.Ball))
	end
end

--------------------------------------------------------------------------------
-- Sahur Farmstead
--------------------------------------------------------------------------------

local function farmstead(model, origin, ctx)
	local barnRed = Color3.fromRGB(150, 46, 44)
	local barnTrim = Color3.fromRGB(236, 230, 214)
	-- Round and inside the levelled pad (footprint + 4), so no corner of it hangs over natural ground.
	column(model, 1, 92, origin * CFrame.new(0, 0.5, 0), Color3.fromRGB(110, 92, 64), Enum.Material.Ground)

	-- The barn: a big open box with double doors at the front, a hayloft at the back and a
	-- gambrel roof of two wedges a side.
	local barn = origin * CFrame.new(-14, 0, 6)
	piece(model, Vector3.new(30, 1, 40), barn * CFrame.new(0, 1.5, 0), Color3.fromRGB(120, 92, 60), Enum.Material.WoodPlanks)
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(1, 16, 40), barn * CFrame.new(side * 15, 10, 0), barnRed, Enum.Material.WoodPlanks)
		-- Windows cut as white frames on the side walls.
		for _, z in ipairs({ -12, 0, 12 }) do
			decor(piece(model, Vector3.new(0.3, 4, 4), barn * CFrame.new(side * 15.6, 9, z), barnTrim, Enum.Material.SmoothPlastic))
			decor(piece(model, Vector3.new(0.4, 3.2, 3.2), barn * CFrame.new(side * 15.7, 9, z), Color3.fromRGB(150, 200, 230), Enum.Material.Glass))
		end
	end
	piece(model, Vector3.new(30, 16, 1), barn * CFrame.new(0, 10, 20), barnRed, Enum.Material.WoodPlanks)
	-- Front wall with the doorway, and the doors open either side.
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(9, 16, 1), barn * CFrame.new(side * 10.5, 10, -20), barnRed, Enum.Material.WoodPlanks)
		piece(model, Vector3.new(0.6, 12, 6), barn * CFrame.new(side * 6, 7, -23) * CFrame.Angles(0, side * 0.3, 0), barnRed:Lerp(Color3.new(0, 0, 0), 0.2),
			Enum.Material.WoodPlanks)
	end
	piece(model, Vector3.new(12, 4, 1), barn * CFrame.new(0, 16, -20), barnRed, Enum.Material.WoodPlanks)
	decor(piece(model, Vector3.new(13, 0.6, 1.2), barn * CFrame.new(0, 13.8, -20), barnTrim, Enum.Material.SmoothPlastic))
	-- The hayloft at the back, with a ladder up and bales on it.
	piece(model, Vector3.new(28, 0.8, 14), barn * CFrame.new(0, 10, 12), Color3.fromRGB(120, 92, 60), Enum.Material.WoodPlanks)
	ladder(model, barn * CFrame.new(-12, 5.5, 4), 10)
	for index = 0, 3 do
		piece(model, Vector3.new(4, 2.4, 2.6), barn * CFrame.new(-8 + index * 5, 11.6, 14) * CFrame.Angles(0, index * 0.2, 0), Color3.fromRGB(214, 186, 96),
			Enum.Material.Fabric)
	end
	chestAt(ctx, barn * CFrame.new(8, 11.4, 9))
	lootAt(ctx, "heal", (barn * CFrame.new(-6, 2.5, -8)).Position)
	lootAt(ctx, "weapon", (barn * CFrame.new(8, 2, -12)).Position)
	lootAt(ctx, "item", (barn * CFrame.new(-4, 11.3, 8)).Position)
	-- Gambrel roof: a steep lower wedge and a shallow upper wedge each side, and a ridge cap.
	for _, side in ipairs({ -1, 1 }) do
		local lower = Instance.new("WedgePart")
		lower.Size = Vector3.new(42, 6, 9)
		lower.CFrame = barn * CFrame.new(side * 11.5, 21, 0) * CFrame.Angles(0, side > 0 and -math.pi / 2 or math.pi / 2, 0)
		lower.Color = Color3.fromRGB(70, 60, 56)
		lower.Material = Enum.Material.Slate
		lower.Anchored = true
		lower.Parent = model
		-- The two upper wedges meet exactly at the ridge (7.6 long from 3.8 out) rather than
		-- crossing, so their gable faces don't overlap under the cap.
		local upper = Instance.new("WedgePart")
		upper.Size = Vector3.new(42, 3, 7.6)
		upper.CFrame = barn * CFrame.new(side * 3.8, 25.5, 0) * CFrame.Angles(0, side > 0 and -math.pi / 2 or math.pi / 2, 0)
		upper.Color = Color3.fromRGB(70, 60, 56)
		upper.Material = Enum.Material.Slate
		upper.Anchored = true
		upper.Parent = model
	end
	piece(model, Vector3.new(1.6, 1.2, 42), barn * CFrame.new(0, 27.3, 0), Color3.fromRGB(70, 60, 56), Enum.Material.Slate)
	local boardSign = piece(model, Vector3.new(14, 2.4, 0.4), barn * CFrame.new(0, 19.5, -20.6), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(boardSign, "SAHUR FARMSTEAD", GOLD, Color3.fromRGB(30, 30, 36), { Enum.NormalId.Front })

	-- Two silos with a catwalk between them and a ladder up; an item at the top.
	for index, offset in ipairs({ Vector3.new(20, 0, -14), Vector3.new(20, 0, 2) }) do
		local foot = origin * CFrame.new(offset)
		column(model, 30, 10, foot * CFrame.new(0, 16, 0), STEEL, Enum.Material.Metal)
		column(model, 1, 10.6, foot * CFrame.new(0, 1.5, 0), IRON, Enum.Material.DiamondPlate)
		for band = 1, 4 do
			decor(piece(model, Vector3.new(0.4, 10.8, 10.8), foot * CFrame.new(0, 1 + band * 6, 0) * CFrame.Angles(0, 0, math.pi / 2), IRON,
				Enum.Material.Metal, Enum.PartType.Cylinder))
		end
		-- A dome: a ball half sunk into the top.
		piece(model, Vector3.new(10, 10, 10), foot * CFrame.new(0, 31, 0), STEEL:Lerp(Color3.new(0, 0, 0), 0.1), Enum.Material.Metal, Enum.PartType.Ball)
		if index == 1 then
			ladder(model, foot * CFrame.new(-6, 15.5, 0), 30)
		end
	end
	piece(model, Vector3.new(4, 0.6, 16), origin * CFrame.new(20, 31.3, -6), IRON, Enum.Material.DiamondPlate)
	-- Both on the stretch of catwalk between the domes.
	lootAt(ctx, "item", (origin * CFrame.new(20, 32, -7.8)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(20, 32, -4.4)).Position)
	ziplineFrom(model, ctx, (origin * CFrame.new(22, 32, -6)).Position, flatRight(origin), 100)

	-- The windmill: a stone tower, a cap, and four sails turning on a hub.
	local mill = origin * CFrame.new(28, 0, 30)
	for index = 0, 3 do
		column(model, 7, 12 - index * 1.5, mill * CFrame.new(0, 1 + index * 7 + 3.5, 0), OLD_STONE, Enum.Material.Cobblestone)
	end
	piece(model, Vector3.new(8, 4, 8), mill * CFrame.new(0, 31, 0), Color3.fromRGB(120, 92, 60), Enum.Material.WoodPlanks)
	local hub = decor(piece(model, Vector3.new(2, 2, 2), mill * CFrame.new(0, 30, -5) * CFrame.Angles(math.pi / 2, 0, 0), IRON, Enum.Material.Metal,
		Enum.PartType.Cylinder))
	hub.Name = "MillHub"
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2
		decor(piece(hub, Vector3.new(0.5, 16, 0.5), mill * CFrame.new(0, 30, -5) * CFrame.Angles(0, 0, angle) * CFrame.new(0, 8, 0), Color3.fromRGB(90, 66, 44),
			Enum.Material.Wood))
		decor(piece(hub, Vector3.new(3.2, 12, 0.2), mill * CFrame.new(0, 30, -5) * CFrame.Angles(0, 0, angle) * CFrame.new(1.8, 9.5, 0), WHITE,
			Enum.Material.Fabric))
	end
	spin(hub, -14)
	lootAt(ctx, "weapon", (mill * CFrame.new(0, 1.5, -10)).Position)

	-- Fenced yard with a trough, a tractor and hay bales; a scarecrow in the field.
	for _, spec in ipairs({ { Vector3.new(0, 0, -40), 84, 0 }, { Vector3.new(0, 0, 40), 84, 0 }, { Vector3.new(-42, 0, 0), 80, math.pi / 2 }, { Vector3.new(42, 0, 0), 80, math.pi / 2 } }) do
		local rail = origin * CFrame.new(spec[1]) * CFrame.Angles(0, spec[3], 0)
		for _, y in ipairs({ 1.4, 2.6 }) do
			decor(piece(model, Vector3.new(spec[2], 0.25, 0.25), rail * CFrame.new(0, y, 0), Color3.fromRGB(128, 94, 60), Enum.Material.Wood))
		end
		for index = 0, 8 do
			piece(model, Vector3.new(0.5, 3.2, 0.5), rail * CFrame.new(-spec[2] / 2 + index * spec[2] / 8, 1.6, 0), Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
		end
	end
	piece(model, Vector3.new(8, 2, 3), origin * CFrame.new(-2, 2, -28), STEEL, Enum.Material.Metal)
	decor(piece(model, Vector3.new(7.4, 0.3, 2.4), origin * CFrame.new(-2, 2.9, -28), Color3.fromRGB(96, 190, 240), Enum.Material.Glass))
	-- The tractor: engine block, cab, big back wheels, small front wheels.
	local tractor = origin * CFrame.new(8, 0, 30) * CFrame.Angles(0, 0.6, 0)
	piece(model, Vector3.new(4, 3, 6), tractor * CFrame.new(0, 3.5, -2), Color3.fromRGB(60, 140, 70), Enum.Material.Metal)
	piece(model, Vector3.new(4.4, 4, 4), tractor * CFrame.new(0, 5.5, 3), Color3.fromRGB(60, 140, 70), Enum.Material.Metal)
	decor(piece(model, Vector3.new(4.6, 2, 0.3), tractor * CFrame.new(0, 6, 0.9), Color3.fromRGB(150, 200, 230), Enum.Material.Glass))
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(1.4, 5, 5), tractor * CFrame.new(side * 2.6, 2.5, 3) * CFrame.Angles(0, 0, math.pi / 2), DARK_CONCRETE, Enum.Material.Rubber,
			Enum.PartType.Cylinder)
		piece(model, Vector3.new(1, 2.6, 2.6), tractor * CFrame.new(side * 2.2, 1.3, -3.5) * CFrame.Angles(0, 0, math.pi / 2), DARK_CONCRETE, Enum.Material.Rubber,
			Enum.PartType.Cylinder)
	end
	column(model, 3, 0.6, tractor * CFrame.new(1.2, 6.5, -3), IRON, Enum.Material.Metal)
	chestAt(ctx, tractor * CFrame.new(-6, 1.5, -0.5))
	for index = 0, 4 do
		piece(model, Vector3.new(4, 2.4, 2.6), origin * CFrame.new(-30 + (index % 3) * 5, 1 + 1.2 + math.floor(index / 3) * 2.4, -28 + math.floor(index / 3) * 0.2),
			Color3.fromRGB(214, 186, 96), Enum.Material.Fabric)
	end
	local scarecrow = origin * CFrame.new(-28, 0, 28)
	column(model, 8, 0.5, scarecrow * CFrame.new(0, 5, 0), Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
	piece(model, Vector3.new(6, 0.5, 0.5), scarecrow * CFrame.new(0, 7.5, 0), Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
	piece(model, Vector3.new(2.4, 3, 1.4), scarecrow * CFrame.new(0, 6.5, 0), Color3.fromRGB(90, 110, 160), Enum.Material.Fabric)
	piece(model, Vector3.new(1.4, 1.4, 1.4), scarecrow * CFrame.new(0, 8.8, 0), Color3.fromRGB(214, 186, 96), Enum.Material.Fabric, Enum.PartType.Ball)
	decor(piece(model, Vector3.new(3, 0.3, 3), scarecrow * CFrame.new(0, 9.5, 0), Color3.fromRGB(150, 110, 60), Enum.Material.Fabric, Enum.PartType.Cylinder))
	lootAt(ctx, "heal", (scarecrow * CFrame.new(3, 1.5, 0)).Position)
end

--------------------------------------------------------------------------------
-- The Sigma Spire
--------------------------------------------------------------------------------

local function sigmaSpire(model, origin, ctx)
	local glass = Color3.fromRGB(120, 170, 210)
	local frame = Color3.fromRGB(60, 64, 76)
	local floorHeight = 12
	local floors = 8
	local half = 14
	-- Round and inside the levelled pad (footprint + 4), so no corner of it hangs over natural ground.
	column(model, 1, 70, origin * CFrame.new(0, 0.5, 0), CONCRETE, Enum.Material.Concrete)

	-- Each floor: a slab, glass walls with window frames, a doorway on the ground floor, and
	-- a stairwell in one corner up to the next.
	for floor = 0, floors - 1 do
		local y = 1 + floor * floorHeight
		piece(model, Vector3.new(half * 2, 1, half * 2), origin * CFrame.new(0, y + 0.5, 0), DARK_CONCRETE, Enum.Material.Concrete)
		for _, side in ipairs({ -1, 1 }) do
			for _, axis in ipairs({ "x", "z" }) do
				local wallFrame = axis == "x" and origin * CFrame.new(side * half, y + floorHeight / 2 + 0.5, 0)
					or origin * CFrame.new(0, y + floorHeight / 2 + 0.5, side * half)
				local size = axis == "x" and Vector3.new(0.6, floorHeight - 1, half * 2) or Vector3.new(half * 2, floorHeight - 1, 0.6)
				if floor == 0 and axis == "z" and side == -1 then
					-- Ground floor front: a doorway in the middle.
					piece(model, Vector3.new(10, floorHeight - 1, 0.6), wallFrame * CFrame.new(-9, 0, 0), glass, Enum.Material.Glass).Transparency = 0.35
					piece(model, Vector3.new(10, floorHeight - 1, 0.6), wallFrame * CFrame.new(9, 0, 0), glass, Enum.Material.Glass).Transparency = 0.35
					piece(model, Vector3.new(8, 3, 0.6), wallFrame * CFrame.new(0, floorHeight / 2 - 2, 0), frame, Enum.Material.Metal)
				else
					local pane = piece(model, size, wallFrame, glass, Enum.Material.Glass)
					pane.Transparency = 0.35
				end
				-- Mullions.
				for index = -1, 1 do
					local mullion = axis == "x" and Vector3.new(0.8, floorHeight - 1, 0.5) or Vector3.new(0.5, floorHeight - 1, 0.8)
					local offset = axis == "x" and CFrame.new(0, 0, index * half * 0.66) or CFrame.new(index * half * 0.66, 0, 0)
					decor(piece(model, mullion, wallFrame * offset, frame, Enum.Material.Metal))
				end
			end
		end
		-- Floor band outside.
		decor(piece(model, Vector3.new(half * 2 + 1, 1.2, half * 2 + 1), origin * CFrame.new(0, y + 0.5, 0), frame, Enum.Material.Metal))
		-- Stairs in the +X +Z corner, with a hole in the slab above.
		if floor < floors - 1 then
			for step = 0, 9 do
				piece(model, Vector3.new(4, 1, 1.4), origin * CFrame.new(half - 3, y + 1 + step * 1.2, half - 10 + step * 1.2), CONCRETE, Enum.Material.Concrete)
			end
			-- A stringer down each side of the flight, lapping the ends of the treads.
			local from = origin * CFrame.new(0, y + 0.6, half - 10.4)
			local to = origin * CFrame.new(0, y + 11.6, half - 10.4 + 11)
			for _, side in ipairs({ -1, 1 }) do
				local a = (from * CFrame.new(half - 3 + side * 2.05, 0, 0)).Position
				local b = (to * CFrame.new(half - 3 + side * 2.05, 0, 0)).Position
				decor(piece(model, Vector3.new(0.3, 1.2, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), DARK_CONCRETE, Enum.Material.Concrete))
			end
		end
		if floor > 0 then
			-- The slab above the stairs is left open: cut by placing the hole part as air (a
			-- non-colliding marker) — the slab is built full, so leave a gap by shrinking it.
		end
		-- Loot and cover on every floor: a desk, a couple of crates.
		piece(model, Vector3.new(6, 2.4, 3), origin * CFrame.new(-6, y + 2.2, -4) * CFrame.Angles(0, floor * 0.4, 0), Color3.fromRGB(70, 74, 92), Enum.Material.Metal)
		piece(model, Vector3.new(3, 3, 3), origin * CFrame.new(6, y + 2.5, 6), Color3.fromRGB(150, 108, 62), Enum.Material.WoodPlanks)
		if floor % 2 == 1 then
			chestAt(ctx, origin * CFrame.new(-8, y + 1.5, 6))
		else
			lootAt(ctx, "heal", (origin * CFrame.new(-8, y + 1.5, 6)).Position)
		end
		lootAt(ctx, floor % 3 == 0 and "weapon" or "item", (origin * CFrame.new(4, y + 1.5, -8)).Position)
	end
	-- Floors are built full; the stairs climb through a hole cut by rebuilding each upper slab
	-- as two pieces around the stairwell.
	for floor = 1, floors - 1 do
		local y = 1 + floor * floorHeight
		local slab = nil
		for _, child in ipairs(model:GetChildren()) do
			if child:IsA("BasePart") and child.Size == Vector3.new(half * 2, 1, half * 2) and math.abs(child.Position.Y - (origin.Position.Y + y + 0.5)) < 0.01 then
				slab = child
			end
		end
		if slab then
			slab:Destroy()
			piece(model, Vector3.new(half * 2, 1, half * 2 - 6), origin * CFrame.new(0, y + 0.5, -3), DARK_CONCRETE, Enum.Material.Concrete)
			piece(model, Vector3.new(half * 2 - 6, 1, 6), origin * CFrame.new(-3, y + 0.5, half - 3), DARK_CONCRETE, Enum.Material.Concrete)
		end
	end

	-- The roof: a helipad, a parapet, an antenna with a beacon, and two ziplines off it.
	local roofY = 1 + floors * floorHeight
	piece(model, Vector3.new(half * 2, 1, half * 2), origin * CFrame.new(0, roofY + 0.5, 0), DARK_CONCRETE, Enum.Material.Concrete)
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(0.6, 2.4, half * 2), origin * CFrame.new(side * (half - 0.3), roofY + 2.2, 0), frame, Enum.Material.Metal)
		piece(model, Vector3.new(half * 2, 2.4, 0.6), origin * CFrame.new(0, roofY + 2.2, side * (half - 0.3)), frame, Enum.Material.Metal)
	end
	decor(piece(model, Vector3.new(0.3, 18, 18), origin * CFrame.new(0, roofY + 1.1, 0) * CFrame.Angles(0, 0, math.pi / 2), GOLD, Enum.Material.Neon,
		Enum.PartType.Cylinder))
	decor(piece(model, Vector3.new(0.35, 15, 15), origin * CFrame.new(0, roofY + 1.12, 0) * CFrame.Angles(0, 0, math.pi / 2), DARK_CONCRETE,
		Enum.Material.Concrete, Enum.PartType.Cylinder))
	decor(piece(model, Vector3.new(8, 0.4, 1.2), origin * CFrame.new(0, roofY + 1.15, 0), GOLD, Enum.Material.Neon))
	decor(piece(model, Vector3.new(1.2, 0.4, 8), origin * CFrame.new(0, roofY + 1.15, 0), GOLD, Enum.Material.Neon))
	column(model, 14, 0.8, origin * CFrame.new(-10, roofY + 8, -10), STEEL, Enum.Material.Metal)
	local beacon = decor(piece(model, Vector3.new(1.4, 1.4, 1.4), origin * CFrame.new(-10, roofY + 15.6, -10), RED, Enum.Material.Neon, Enum.PartType.Ball))
	light(beacon, RED, 40, 2)
	bob(beacon, 0.2, 3, 0)
	chestAt(ctx, origin * CFrame.new(8, roofY + 1.5, -8))
	lootAt(ctx, "item", (origin * CFrame.new(-8, roofY + 1.5, 8)).Position)
	local plaque = piece(model, Vector3.new(14, 2.4, 0.4), origin * CFrame.new(0, 11, -half - 0.5), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(plaque, "THE SIGMA SPIRE", GOLD, Color3.fromRGB(30, 30, 36), { Enum.NormalId.Front })
	-- A neon spine up the corners, and the name in lights near the top.
	for _, corner in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
		decor(piece(model, Vector3.new(0.5, roofY, 0.5), origin * CFrame.new(corner[1] * (half + 0.4), roofY / 2, corner[2] * (half + 0.4)),
			Rarity.Color("Epic"), Enum.Material.Neon))
	end
	ziplineFrom(model, ctx, (origin * CFrame.new(half, roofY + 2.5, 0)).Position, flatRight(origin), 130)
	ziplineFrom(model, ctx, (origin * CFrame.new(-half, roofY + 2.5, 0)).Position, flatRight(origin) * -1, 130)
end

--------------------------------------------------------------------------------
-- Sahur Hot Springs
--------------------------------------------------------------------------------

local function hotSprings(model, origin, ctx)
	local terrain = workspace.Terrain
	local rock = Color3.fromRGB(150, 140, 126)
	-- Round and inside the levelled pad (footprint + 4), so no corner of it hangs over natural ground.
	column(model, 1, 84, origin * CFrame.new(0, 0.5, 0), rock, Enum.Material.Rock)

	-- Three steaming pools at different levels, each ringed with stones, and a geyser.
	for index, spec in ipairs({ { Vector3.new(-14, 0, -8), 11, 1 }, { Vector3.new(12, 0, 4), 9, 3 }, { Vector3.new(-2, 0, 18), 7, 5 } }) do
		local at = origin * CFrame.new(spec[1] + Vector3.new(0, spec[3], 0))
		column(model, spec[3] + 1, spec[2] * 2 + 6, origin * CFrame.new(spec[1]) * CFrame.new(0, (spec[3] + 1) / 2 + 0.5, 0), rock, Enum.Material.Rock)
		local water = piece(model, Vector3.new(0.8, spec[2] * 2, spec[2] * 2), at * CFrame.new(0, 1.2, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Color3.fromRGB(120, 220, 230), Enum.Material.Glass, Enum.PartType.Cylinder)
		water.Transparency = 0.35
		-- Seen, never collided with or shot: a pool you wade through can't stop a bullet.
		decor(water)
		light(water, Color3.fromRGB(120, 220, 230), 20, 1.2)
		for stone = 0, 11 do
			local angle = stone / 12 * math.pi * 2
			piece(model, Vector3.new(2.4, 1.6, 2), at * CFrame.new(math.cos(angle) * (spec[2] + 1.2), 1.4, math.sin(angle) * (spec[2] + 1.2)) * CFrame.Angles(0, angle, 0.2),
				OLD_STONE, Enum.Material.Rock, Enum.PartType.Ball)
		end
		local steam = Instance.new("ParticleEmitter")
		steam.Color = ColorSequence.new(Color3.fromRGB(240, 250, 255))
		steam.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 6) })
		steam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
		steam.Lifetime = NumberRange.new(2.5, 4)
		steam.Speed = NumberRange.new(1.5, 3)
		steam.Rate = 5
		steam.Parent = water
		-- Beside the pool on the ground, clear of its raised rim (radius + 3) and the stones round it.
		lootAt(ctx, index == 2 and "item" or "heal", (origin * CFrame.new(spec[1]) * CFrame.new(spec[2] + 6, 1.5, 0)).Position)
	end
	-- The geyser: a cone of rock with a column of water that rises and falls. Stand on the vent
	-- and it throws you into the air — the fastest way onto the bath house roof, or out of a fight.
	local geyser = origin * CFrame.new(22, 0, -20)
	column(model, 4, 12, geyser * CFrame.new(0, 2.5, 0), rock, Enum.Material.Rock)
	column(model, 3, 7, geyser * CFrame.new(0, 6, 0), rock, Enum.Material.Rock)
	local jet = decor(column(model, 22, 2.4, geyser * CFrame.new(0, 17, 0), Color3.fromRGB(200, 240, 255), Enum.Material.Neon))
	jet.Transparency = 0.35
	bob(jet, 9, 0.6, 0)
	light(jet, Color3.fromRGB(200, 240, 255), 30, 1.5)
	local vent = column(model, 0.4, 6.4, geyser * CFrame.new(0, 7.7, 0), Color3.fromRGB(150, 220, 240), Enum.Material.Neon)
	vent.Name = "GeyserVent"
	vent.Transparency = 0.2
	vent.CanCollide = false
	vent.CanQuery = false
	vent.Touched:Connect(function(hit)
		Landmarks.GeyserTouched(vent, hit)
	end)
	-- A bath house: a wooden pavilion with a chest inside and towels on rails.
	local house = origin * CFrame.new(-24, 0, 20)
	piece(model, Vector3.new(18, 1, 14), house * CFrame.new(0, 1.5, 0), Color3.fromRGB(120, 92, 60), Enum.Material.WoodPlanks)
	for _, x in ipairs({ -8, 8 }) do
		for _, z in ipairs({ -6, 6 }) do
			column(model, 9, 1, house * CFrame.new(x, 6.5, z), Color3.fromRGB(90, 66, 44), Enum.Material.Wood)
		end
	end
	piece(model, Vector3.new(18, 8, 1), house * CFrame.new(0, 6, 6.5), Color3.fromRGB(236, 230, 214), Enum.Material.WoodPlanks)
	piece(model, Vector3.new(1, 8, 14), house * CFrame.new(-8.5, 6, 0), Color3.fromRGB(236, 230, 214), Enum.Material.WoodPlanks)
	local roof = Instance.new("WedgePart")
	roof.Size = Vector3.new(20, 5, 16)
	roof.CFrame = house * CFrame.new(0, 13, 0) * CFrame.Angles(0, math.pi, 0)
	roof.Color = Color3.fromRGB(150, 46, 44)
	roof.Material = Enum.Material.Slate
	roof.Anchored = true
	roof.Parent = model
	chestAt(ctx, house * CFrame.new(-4, 2.5, 3))
	lootAt(ctx, "weapon", (house * CFrame.new(4, 2.5, -3)).Position)
	decor(rod(model, (house * CFrame.new(7.6, 6.1, -6)).Position, (house * CFrame.new(7.6, 6.1, 6)).Position, 0.3, Color3.fromRGB(90, 66, 44), Enum.Material.Wood))
	for index = 0, 2 do
		decor(piece(model, Vector3.new(0.3, 3, 2.4), house * CFrame.new(7.6, 4.5, -4 + index * 3.2), Color3.fromHSV(index / 3, 0.5, 1), Enum.Material.Fabric))
	end
	local board = piece(model, Vector3.new(12, 2.2, 0.4), house * CFrame.new(0, 9.8, -7.4), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	sign(board, "SAHUR HOT SPRINGS", GOLD, Color3.fromRGB(30, 30, 36), { Enum.NormalId.Front })
	-- Stone lanterns on the paths.
	for _, offset in ipairs({ Vector3.new(0, 0, -30), Vector3.new(30, 0, 20), Vector3.new(-30, 0, -20), Vector3.new(4, 0, 32) }) do
		local at = origin * CFrame.new(offset)
		piece(model, Vector3.new(2, 4, 2), at * CFrame.new(0, 3, 0), OLD_STONE, Enum.Material.Cobblestone)
		local lamp = decor(piece(model, Vector3.new(1.4, 1.4, 1.4), at * CFrame.new(0, 5.4, 0), FLAME, Enum.Material.Neon))
		light(lamp, FLAME, 16, 1.2)
		piece(model, Vector3.new(2.6, 0.6, 2.6), at * CFrame.new(0, 6.4, 0), OLD_STONE, Enum.Material.Cobblestone)
	end
	-- A statue of a brainrot bathing: the Sahur Springs' own mascot on a rock.
	-- A Rare, so the statue is somebody people want.
	local def = BrainrotData.RandomOfRarity("Rare") or BrainrotData.Types[1]
	if def then
		local scale = 1.2
		local size = def.look and def.look.size or 1
		local metrics = BrainrotModels.Metrics(def)
		local foot = (origin * CFrame.new(12, 3.2 - metrics.bottom * scale * size, 4)).Position
		local statue = BrainrotModels.Build(def, { scale = scale, glow = Color3.fromRGB(120, 220, 230), cframe = CFrame.new(foot) * origin.Rotation })
		statue.Name = "SpringsStatue"
		statue.Parent = model
	end
	terrain = nil
end

--------------------------------------------------------------------------------
-- Monuments: each map's own skyline pieces
--
-- Every map carries a couple of these on top of its signature landmark, so the maps can be told
-- apart at a glance and a position can be called out by name ("under the Drum", "at the Galleon").
-- Each reads from across the map: 40 to 150 studs tall, a silhouette nothing else on that map has.
-- Like the landmarks above they level their own site (unless marked `level = false`, when their
-- piers and legs find the ground themselves), carry one chest and a few pickups, and are a supply
-- drop spot. Rolls come from `rng`, which Place seeds from a single global roll.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- The Great Sundial (Sahur Springs)
--------------------------------------------------------------------------------

-- The springs' timekeeper: a round marble dial on a stepped plinth ringed with hour stones, noon's in
-- gold, and rising from it a fifty-stud bronze gnomon whose shadow sweeps the dial under the midday
-- sun. The gnomon's sloping back can be walked all the way up to a perch at its tip; obelisks
-- mark the four quarters round the plinth.
local function greatSundial(model, origin, ctx)
	local marble = Color3.fromRGB(222, 216, 200)
	local warmStone = Color3.fromRGB(184, 170, 146)
	local bronze = Color3.fromRGB(150, 108, 58)
	-- Three steps up to the dial, each a little narrower.
	local y = 0
	for step, diameter in ipairs({ 52, 46, 40 }) do
		column(model, 1.2, diameter, origin * CFrame.new(0, y + 0.6, 0), warmStone:Lerp(Color3.new(1, 1, 1), step * 0.05), Enum.Material.Cobblestone)
		y += 1.2
	end
	column(model, 0.6, 37, origin * CFrame.new(0, y + 0.3, 0), marble, Enum.Material.Marble)
	local dialTop = y + 0.6
	-- Hour stones round the rim, set half a step off the gnomon's line so none stands in its foot;
	-- the one facing it across the dial is noon, taller and gilded.
	for hour = 0, 11 do
		local angle = (hour + 0.5) / 12 * math.pi * 2
		local noon = hour == 5
		local height = noon and 3.2 or 1.4
		piece(model, Vector3.new(1.8, height, 3), origin * CFrame.Angles(0, angle, 0) * CFrame.new(0, dialTop + height / 2, 16.4),
			noon and GOLD or warmStone, noon and Enum.Material.Foil or Enum.Material.Marble)
	end
	-- The gnomon: a wedge standing on the dial's north-south line, its tall back face at the rim and
	-- its slope running down to the centre, so the slope is the walk up.
	local length, height = 34, 50
	wedgePiece(model, Vector3.new(3, height, length), origin * CFrame.new(0, dialTop + height / 2, 17 - length / 2), bronze, Enum.Material.Metal)
	for _, side in ipairs({ -1, 1 }) do
		-- A buttress each side of the gnomon's foot.
		wedgePiece(model, Vector3.new(1.6, 9, 5), origin * CFrame.new(side * 2.3, dialTop + 4.5, 11.5), bronze:Lerp(Color3.new(), 0.15), Enum.Material.Metal)
	end
	local perchY = dialTop + height
	-- The perch sits on the blade's top edge and out behind it, a short hop up from the top of the slope.
	piece(model, Vector3.new(6, 0.8, 6), origin * CFrame.new(0, perchY + 0.4, 19), bronze:Lerp(Color3.new(), 0.2), Enum.Material.Metal)
	local finial = decor(piece(model, Vector3.new(2.2, 2.2, 2.2), origin * CFrame.new(0, perchY + 1.9, 21), GOLD, Enum.Material.Foil, Enum.PartType.Ball))
	light(finial, GOLD, 30, 1)
	-- Obelisks at the four quarters, just off the bottom step.
	for quarter = 0, 3 do
		local at = origin * CFrame.Angles(0, quarter * math.pi / 2 + math.pi / 4, 0) * CFrame.new(0, 0, 31)
		piece(model, Vector3.new(3, 12, 3), at * CFrame.new(0, 6, 0), warmStone, Enum.Material.Marble)
		pyramid(model, at * CFrame.new(0, 12, 0), 3, 2.6, GOLD, Enum.Material.Foil)
	end

	chestAt(ctx, origin * CFrame.new(-5, dialTop + 0.5, -4))
	chestAt(ctx, origin * CFrame.Angles(0, math.pi * 1.25, 0) * CFrame.new(0, 0.5, 34))
	lootAt(ctx, "item", (origin * CFrame.new(1.5, perchY + 1.2, 18.5)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(24, 0.5, -20)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(6, dialTop + 0.5, -10)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-21, 2.8, 6)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(26, 0.5, 20)).Position)
	ziplineFrom(model, ctx, (origin * CFrame.new(0, perchY + 3, 21.5)).Position, flatForward(origin) * -1, 110)
	nameBoard(model, origin * CFrame.new(-14, 0, -32), "THE GREAT SUNDIAL")
end

--------------------------------------------------------------------------------
-- Aura Windmill (Sahur Springs)
--------------------------------------------------------------------------------

-- A tall tapered windmill of stone and whitewashed timber, its four sails always turning, its
-- windows glowing aura-purple. A ladder climbs the back to a balcony ringing the tower.
local function auraWindmill(model, origin, ctx)
	local aura = Color3.fromRGB(176, 96, 255)
	local limewash = Color3.fromRGB(232, 226, 212)
	column(model, 2, 28, origin * CFrame.new(0, 1, 0), OLD_STONE, Enum.Material.Cobblestone)
	-- Four tapering drums, stone at the bottom and timber above; each sits a hair onto the one below.
	local y = 2
	local sections = { { 20, 11, OLD_STONE, Enum.Material.Cobblestone }, { 18, 11, STONE, Enum.Material.Cobblestone },
		{ 16, 11, limewash, Enum.Material.WoodPlanks }, { 14, 10, limewash, Enum.Material.WoodPlanks } }
	for _, section in ipairs(sections) do
		column(model, section[2], section[1], origin * CFrame.new(0, y + section[2] / 2, 0), section[3], section[4])
		y += section[2]
	end
	local top = y
	pyramid(model, origin * CFrame.new(0, top, 0) * CFrame.Angles(0, math.pi / 4, 0), 17, 9, Color3.fromRGB(70, 60, 80), Enum.Material.Slate)
	local finial = decor(piece(model, Vector3.new(2.4, 2.4, 2.4), origin * CFrame.new(0, top + 9.6, 0), aura, Enum.Material.Neon, Enum.PartType.Ball))
	light(finial, aura, 40, 1.4)

	-- Glowing windows in a spiral up the tower, and the door.
	for index = 0, 8 do
		local angle = index * 2.2
		local height = 7 + index * 3.6
		local sectionRadius = height < 13 and 10 or height < 24 and 9 or height < 35 and 8 or 7
		-- Set out a little, so the one behind the door shares neither of the door's faces (its 0.5 sits
		-- inside the door's 0.6).
		decor(piece(model, Vector3.new(2, 3, 0.5), origin * CFrame.Angles(0, angle, 0) * CFrame.new(0, height, -(sectionRadius + 0.1)), aura, Enum.Material.Neon))
	end
	decor(piece(model, Vector3.new(4.5, 7, 0.6), origin * CFrame.new(0, 5.5, -10.1), Color3.fromRGB(70, 48, 34), Enum.Material.WoodPlanks))

	-- The balcony: a deck round the third drum with a railing, reached by a ladder up the back.
	local deckY = 2 + 11 + 11 + 0.4
	column(model, 0.8, 26, origin * CFrame.new(0, deckY - 0.4, 0), Color3.fromRGB(120, 92, 66), Enum.Material.WoodPlanks)
	-- Twelve rail sections round the deck; the one facing straight back is left out for the ladder.
	-- CFrame.Angles(0, a, 0) sends -Z to (-sin a, 0, -cos a), so the back (+Z) is a = pi.
	for index = 0, 11 do
		local angle = index / 12 * math.pi * 2
		if index ~= 6 then
			piece(model, Vector3.new(6.6, 2.8, 0.4), origin * CFrame.Angles(0, angle, 0) * CFrame.new(0, deckY + 1.4, -12.6),
				Color3.fromRGB(96, 72, 52), Enum.Material.Wood)
		end
	end
	ladder(model, origin * CFrame.new(0, (deckY + 2) / 2, 14), deckY - 1)

	-- The sails: a hub on the front whose own Y axis runs out along the tower's forward axis, so
	-- AmbientSpin turns everything hung from it. Spinning parts never collide.
	local hubAt = origin * CFrame.new(0, top - 5, -15.5)
	-- The axle out from the tower, clear of the balcony, so the sails never sweep through it.
	rod(model, (origin * CFrame.new(0, top - 5, -6)).Position, hubAt.Position, 1.6, Color3.fromRGB(80, 60, 44), Enum.Material.Wood)
	local hub = decor(piece(model, Vector3.new(2.5, 3, 2.5), hubAt * CFrame.Angles(math.pi / 2, 0, 0), Color3.fromRGB(80, 60, 44), Enum.Material.Wood,
		Enum.PartType.Cylinder))
	hub.Name = "SailHub"
	for index = 0, 3 do
		local arm = hubAt * CFrame.Angles(0, 0, index * math.pi / 2 + math.pi / 4)
		-- Each spar a few hundredths further out than the last, so where they cross at the hub no two
		-- front faces share a plane.
		decor(piece(hub, Vector3.new(0.9, 30, 0.9), arm * CFrame.new(0, 15, -0.6 - index * 0.04), Color3.fromRGB(90, 70, 50), Enum.Material.Wood))
		-- The inner edge of the sail laps under the spar, so it hangs from it rather than beside it.
		decor(piece(hub, Vector3.new(5, 22, 0.25), arm * CFrame.new(2.9, 18, -0.9), limewash, Enum.Material.Fabric))
	end
	spin(hub, 24)

	chestAt(ctx, origin * CFrame.new(-10.2, deckY + 0.5, 1))
	-- On the plinth's ring beside the bottom drum.
	chestAt(ctx, origin * CFrame.new(12, 2.5, 0))
	lootAt(ctx, "item", (origin * CFrame.new(10.5, deckY + 0.4, 0)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-4, 1.5, -16)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-16, 0.5, 18)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(12, 1.5, 10)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(3, deckY + 0.4, -11)).Position)
	ziplineFrom(model, ctx, (origin * CFrame.new(-12.4, deckY + 3, -4)).Position, flatRight(origin) * -1, 100)
	nameBoard(model, origin * CFrame.new(16, 0, -20), "AURA WINDMILL", aura)
end

--------------------------------------------------------------------------------
-- Sahur Aqueduct (Sahur Springs)
--------------------------------------------------------------------------------

-- A line of stone arches striding across the fields with water running along the top: a wall of
-- cover to fight along and a high walkway to fight over. Built on the ground as it lies: every pier
-- finds its own ground, and the channel runs level on top.
local function sahurAqueduct(model, origin, ctx)
	local stone = Color3.fromRGB(170, 158, 136)
	local spacing, piers, width = 24, 6, 8
	local deckY = origin.Y + 24
	local half = (piers - 1) * spacing / 2
	local frames = {}
	for index = 0, piers - 1 do
		local at = origin * CFrame.new(-half + index * spacing, 0, 0)
		local ground = ctx.groundHeightAt(at.X, at.Z) or origin.Y
		local bottom = ground - 2
		local height = deckY - bottom
		-- Each pier stands on its own ground, so each is measured on its own rather than as one box
		-- stretched down the whole line of arches.
		local pier = footing(model, "Pier" .. (index + 1), at.X, ground, at.Z, 5.4, width + 0.4)
		piece(pier, Vector3.new(5, height, width), CFrame.new(at.X, bottom + height / 2, at.Z) * origin.Rotation, stone:Lerp(Color3.new(), rrand(0, 0.06)),
			Enum.Material.Cobblestone)
		table.insert(frames, at)
	end
	-- Arches between the piers: a lintel, with wedge haunches under its ends to round the opening.
	for index = 1, piers - 1 do
		local mid = frames[index]:Lerp(frames[index + 1], 0.5)
		local lintel = CFrame.new(mid.X, deckY - 3, mid.Z) * origin.Rotation
		piece(model, Vector3.new(spacing - 5, 6, width - 0.2), lintel, stone, Enum.Material.Cobblestone)
		for _, side in ipairs({ -1, 1 }) do
			-- Tall edge against the pier, sloping down toward the middle of the span.
			wedgePiece(model, Vector3.new(width - 0.4, 5, 5), lintel * CFrame.new(side * (spacing - 5) / 2 - side * 2.5, -5.5, 0)
				* CFrame.Angles(0, side * math.pi / 2, 0) * CFrame.Angles(0, 0, math.pi), stone:Lerp(Color3.new(), 0.08), Enum.Material.Cobblestone)
		end
	end
	-- The channel on top: a walkway slab, two low parapets and the water between them.
	local length = (piers - 1) * spacing + 8
	local deck = CFrame.new(origin.X, deckY + 0.5, origin.Z) * origin.Rotation
	piece(model, Vector3.new(length, 1, width + 1), deck, stone:Lerp(Color3.new(1, 1, 1), 0.05), Enum.Material.Cobblestone)
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(length + 0.2, 2.2, 1), deck * CFrame.new(0, 1.6, side * (width / 2)), stone, Enum.Material.Cobblestone)
	end
	local water = piece(model, Vector3.new(length - 1, 0.5, width - 1.4), deck * CFrame.new(0, 0.9, 0), Color3.fromRGB(90, 170, 210), Enum.Material.Glass)
	water.Transparency = 0.35
	-- The channel's water is walked through, so rays pass it too (a chest set on the walkway was
	-- landing on the water's surface instead of the flagstones).
	decor(water)
	-- Ladders up both end piers.
	for _, sign_ in ipairs({ -1, 1 }) do
		local at = frames[sign_ == -1 and 1 or piers] * CFrame.new(sign_ * 3.5, 0, 0)
		local ground = ctx.groundHeightAt(at.X, at.Z) or origin.Y
		local height = deckY + 1 - ground
		ladder(model, CFrame.new(at.X, ground + height / 2, at.Z) * origin.Rotation, height)
	end
	chestAt(ctx, deck * CFrame.new(0, 1, 0))
	local arch = frames[2]:Lerp(frames[3], 0.5)
	chestAt(ctx, CFrame.new(arch.X, (ctx.groundHeightAt(arch.X, arch.Z) or origin.Y) + 0.5, arch.Z) * origin.Rotation)
	lootAt(ctx, "item", (deck * CFrame.new(-spacing * 1.5, 1, 0)).Position)
	lootAt(ctx, "weapon", (deck * CFrame.new(spacing * 1.5, 1, 0)).Position)
	lootAt(ctx, "weapon", (deck * CFrame.new(-spacing * 2.5, 1, 0)).Position)
	lootAt(ctx, "heal", (deck * CFrame.new(spacing * 0.5, 1, 0)).Position)
	local under = frames[3]:Lerp(frames[4], 0.5)
	lootAt(ctx, "heal", Vector3.new(under.X, (ctx.groundHeightAt(under.X, under.Z) or origin.Y) + 1, under.Z))
	nameBoard(model, frames[1] * CFrame.new(-8, 0, -8) * CFrame.new(0, (ctx.groundHeightAt(frames[1].X, frames[1].Z) or origin.Y) - origin.Y, 0),
		"SAHUR AQUEDUCT")
end

--------------------------------------------------------------------------------
-- Crane Yard (Tralala Town)
--------------------------------------------------------------------------------

-- The next tower going up downtown: a five-storey steel frame half-floored, and beside it a tower
-- crane taller than anything on the map, its jib swung out over the frame with a shipping container
-- hanging from the hook. The mast is four trusses, so it can be climbed; the crane's deck has a
-- zipline all the way back to the street.
local function craneYard(model, origin, ctx)
	local primer = Color3.fromRGB(176, 76, 52)
	local craneYellow = Color3.fromRGB(240, 186, 40)
	-- Round and inside the levelled pad (footprint + 4), so no corner of it hangs over natural ground.
	column(model, 1, 92, origin * CFrame.new(0, 0.5, 0), Color3.fromRGB(120, 116, 108), Enum.Material.Concrete)

	-- The frame: perimeter columns, three floors with a stairwell hole in one corner, then bare beams.
	local building = origin * CFrame.new(-16, 1, 10)
	for _, x in ipairs({ -15, -5, 5, 15 }) do
		for _, z in ipairs({ -15, -5, 5, 15 }) do
			if math.abs(x) == 15 or math.abs(z) == 15 then
				-- A third of a stud taller than the top beams, so the two tops never share a plane.
				piece(model, Vector3.new(1.4, 61.3, 1.4), building * CFrame.new(x, 30.65, z), primer, Enum.Material.Metal)
			end
		end
	end
	for _, level in ipairs({ 12, 24, 36 }) do
		piece(model, Vector3.new(31.6, 0.8, 27.6), building * CFrame.new(0, level + 0.4, -2), DARK_CONCRETE, Enum.Material.Concrete)
		piece(model, Vector3.new(27.6, 0.8, 4), building * CFrame.new(-2, level + 0.4, 13.8), DARK_CONCRETE, Enum.Material.Concrete)
	end
	for _, level in ipairs({ 48, 60 }) do
		for _, side in ipairs({ -1, 1 }) do
			piece(model, Vector3.new(31.6, 1, 1), building * CFrame.new(0, level + 0.5, side * 15), primer, Enum.Material.Metal)
			piece(model, Vector3.new(1, 1, 29), building * CFrame.new(side * 15, level + 0.5, 0), primer, Enum.Material.Metal)
		end
	end
	ladder(model, building * CFrame.new(13.5, 31, 13.5), 62)
	local billboard = piece(model, Vector3.new(22, 7, 0.5), building * CFrame.new(0, 17, -15.95), Color3.fromRGB(28, 30, 40), Enum.Material.Metal)
	sign(billboard, "TRALALA TOWER - COMING SOON", Color3.fromRGB(255, 120, 200), Color3.fromRGB(28, 30, 40), { Enum.NormalId.Front })

	-- The crane: a base, a four-truss mast, a deck, the cab, and the jib pointing out over the frame.
	local base = origin * CFrame.new(24, 1, -20)
	piece(model, Vector3.new(12, 2, 12), base * CFrame.new(0, 1, 0), CONCRETE, Enum.Material.Concrete)
	local mastHeight = 92
	for _, x in ipairs({ -2, 2 }) do
		for _, z in ipairs({ -2, 2 }) do
			ladder(model, base * CFrame.new(x, 2 + mastHeight / 2, z), mastHeight)
		end
	end
	local toward = building.Position - base.Position
	local slew = CFrame.lookAt(base.Position, base.Position + Vector3.new(toward.X, 0, toward.Z))
	local deckY = 2 + mastHeight
	piece(model, Vector3.new(9, 2, 9), slew * CFrame.new(0, deckY + 1, 0), craneYellow, Enum.Material.DiamondPlate)
	piece(model, Vector3.new(4.4, 4, 4.4), slew * CFrame.new(5.6, deckY + 1.4, -1), craneYellow, Enum.Material.Metal)
	decor(piece(model, Vector3.new(0.3, 2, 3.4), slew * CFrame.new(7.85, deckY + 2, -1), Color3.fromRGB(140, 190, 220), Enum.Material.Glass))
	local jibY = deckY + 3.5
	piece(model, Vector3.new(3, 3, 62), slew * CFrame.new(0, jibY, -31), craneYellow, Enum.Material.Metal)
	piece(model, Vector3.new(2.8, 2.8, 22), slew * CFrame.new(0, jibY, 11), craneYellow, Enum.Material.Metal)
	for index = 0, 2 do
		piece(model, Vector3.new(3.6, 5, 3.6), slew * CFrame.new(0, jibY - 3.85, 13.2 + index * 3.8), CONCRETE, Enum.Material.Concrete)
	end
	ladder(model, slew * CFrame.new(0, jibY + 7.5, 0), 12)
	local apex = (slew * CFrame.new(0, jibY + 13, 0)).Position
	decor(rod(model, apex, (slew * CFrame.new(0, jibY + 1.5, -42)).Position, 0.4, IRON, Enum.Material.Metal))
	decor(rod(model, apex, (slew * CFrame.new(0, jibY + 1.4, 21)).Position, 0.4, IRON, Enum.Material.Metal))
	-- Trolley, cable, hook, and a container on slings, hanging over the frame's top floor.
	local hookZ = -(toward * Vector3.new(1, 0, 1)).Magnitude
	piece(model, Vector3.new(3.6, 1.2, 3), slew * CFrame.new(0, jibY - 2.1, hookZ), IRON, Enum.Material.Metal)
	local containerY = 70
	decor(rod(model, (slew * CFrame.new(0, jibY - 2.7, hookZ)).Position, (slew * CFrame.new(0, containerY + 12, hookZ)).Position, 0.3, IRON, Enum.Material.Metal))
	piece(model, Vector3.new(1.6, 2.2, 1.6), slew * CFrame.new(0, containerY + 11, hookZ), craneYellow, Enum.Material.Metal)
	local load = CFrame.new((slew * CFrame.new(0, containerY, hookZ)).Position) * CFrame.Angles(0, rrand(0.3, 0.8), 0)
	container(model, load, CONTAINER_COLORS[2], false)
	for _, z in ipairs({ -9, 9 }) do
		decor(rod(model, (slew * CFrame.new(0, containerY + 10, hookZ)).Position, (load * CFrame.new(0, 8.5, z)).Position, 0.25, IRON, Enum.Material.Metal))
	end

	-- The site: a beam stack, a cement mixer, two portable loos and concrete barriers, for cover.
	for index, offset in ipairs({ { -0.8, 1.7 }, { 0.8, 1.7 }, { 0, 3.1 } }) do
		piece(model, Vector3.new(1.4, 1.4, 22 + index * 0.4), origin * CFrame.new(18 + offset[1] * 0.95, offset[2], 22), primer, Enum.Material.Metal)
	end
	local mixer = origin * CFrame.new(-34, 1, -26)
	piece(model, Vector3.new(4, 2.4, 5), mixer * CFrame.new(0, 1.2, 0), Color3.fromRGB(60, 110, 70), Enum.Material.Metal)
	piece(model, Vector3.new(6, 5, 5), mixer * CFrame.new(0, 4.6, 0) * CFrame.Angles(0, 0, 0.5), Color3.fromRGB(236, 150, 40), Enum.Material.Metal,
		Enum.PartType.Cylinder)
	for index = 0, 1 do
		local loo = origin * CFrame.new(-38 + index * 4.6, 1, 16)
		piece(model, Vector3.new(4, 7.5, 4), loo * CFrame.new(0, 3.75, 0), Color3.fromRGB(50, 110, 200), Enum.Material.SmoothPlastic)
		piece(model, Vector3.new(4.4, 0.5, 4.4), loo * CFrame.new(0, 7.75, 0), WHITE, Enum.Material.SmoothPlastic)
	end
	for index = 0, 3 do
		piece(model, Vector3.new(1.6, 2.8, 7.8), origin * CFrame.new(-4 + index * 8.2, 2.4, -34) * CFrame.Angles(0, math.pi / 2, 0), CONCRETE,
			Enum.Material.Concrete)
	end

	chestAt(ctx, building * CFrame.new(-8, 24.8 + 0.5, -8))
	lootAt(ctx, "item", (slew * CFrame.new(-3, deckY + 2.4, 2.5)).Position)
	lootAt(ctx, "weapon", (mixer * CFrame.new(5, 0.5, 4)).Position)
	lootAt(ctx, "heal", (building * CFrame.new(6, 12.8 + 0.4, -6)).Position)
	lootAt(ctx, "weapon", (building * CFrame.new(-6, 36.8 + 0.4, 4)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-36, 1.5, 20)).Position)
	ziplineFrom(model, ctx, (slew * CFrame.new(0, deckY + 3, 4.5)).Position, (slew.LookVector * Vector3.new(-1, 0, -1)).Unit, 130)
	nameBoard(model, origin * CFrame.new(26, 1, -40), "CRANE YARD", craneYellow)
end

--------------------------------------------------------------------------------
-- The Tralala Arch (Tralala Town)
--------------------------------------------------------------------------------

-- A seventy-stud steel gateway over a plaza, a huge pink neon TRALALA across its face on both
-- sides, lit from below. A ladder up the outside of one leg reaches the walkway across the top.
local function tralalaArch(model, origin, ctx)
	local steel = Color3.fromRGB(74, 78, 92)
	local neon = Color3.fromRGB(255, 90, 200)
	piece(model, Vector3.new(84, 1, 40), origin * CFrame.new(0, 0.5, 0), Color3.fromRGB(150, 146, 140), Enum.Material.Concrete)
	local legTop, beamH = 61, 9
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(13, 4, 13), origin * CFrame.new(side * 26, 3, 0), DARK_CONCRETE, Enum.Material.Concrete)
		piece(model, Vector3.new(10, legTop - 1.5, 10), origin * CFrame.new(side * 26, 1.5 + (legTop - 1.5) / 2, 0), steel, Enum.Material.DiamondPlate)
		-- A haunch under each end of the beam: tall face against the leg, sloping in toward the middle.
		wedgePiece(model, Vector3.new(9.6, 12, 10), origin * CFrame.new(side * 16, legTop - 6, 0) * CFrame.Angles(0, side * math.pi / 2, 0)
			* CFrame.Angles(0, 0, math.pi), steel:Lerp(Color3.new(), 0.1), Enum.Material.DiamondPlate)
		-- Light strips down the leg's inner face.
		decor(piece(model, Vector3.new(0.3, 42, 1.2), origin * CFrame.new(side * 20.9, 26, 0), neon, Enum.Material.Neon))
		local spot = decor(piece(model, Vector3.new(0.6, 3, 3), origin * CFrame.new(side * 14, 1.3, -8) * CFrame.Angles(0, 0, math.pi / 2), WHITE, Enum.Material.Neon,
			Enum.PartType.Cylinder))
		local beamLight = Instance.new("SpotLight")
		beamLight.Face = Enum.NormalId.Right
		beamLight.Angle = 50
		beamLight.Range = 60
		beamLight.Brightness = 3
		beamLight.Color = neon
		beamLight.Parent = spot
	end
	local beamY = legTop + beamH / 2
	piece(model, Vector3.new(62, beamH, 10), origin * CFrame.new(0, beamY, 0), steel, Enum.Material.DiamondPlate)
	decor(piece(model, Vector3.new(22, 0.3, 1.2), origin * CFrame.new(0, legTop - 0.1, 0), neon, Enum.Material.Neon))
	-- The sign on both faces of the beam.
	for _, z in ipairs({ -5.2, 5.2 }) do
		local board = decor(piece(model, Vector3.new(48, 7, 0.5), origin * CFrame.new(0, beamY, z), Color3.fromRGB(24, 20, 34), Enum.Material.SmoothPlastic))
		sign(board, "TRALALA", neon, nil, { z < 0 and Enum.NormalId.Front or Enum.NormalId.Back })
		light(board, neon, 30, 1.5)
	end
	-- Walkway railings across the top.
	for _, z in ipairs({ -4.7, 4.7 }) do
		piece(model, Vector3.new(62, 2.6, 0.4), origin * CFrame.new(0, legTop + beamH + 1.3, z), IRON, Enum.Material.Metal)
	end
	local topY = legTop + beamH
	ladder(model, origin * CFrame.new(32, 1 + topY / 2, 0), topY)

	chestAt(ctx, origin * CFrame.new(0, topY + 0.5, 0))
	lootAt(ctx, "item", (origin * CFrame.new(-27, topY + 0.4, 0)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-26, 1.5, -9.5)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(0, 1.5, 12)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(8, 1.5, -10)).Position)
	lootAt(ctx, "item", (origin * CFrame.new(20, topY + 0.4, 0)).Position)
	ziplineFrom(model, ctx, (origin * CFrame.new(-30, topY + 3, 0)).Position, flatRight(origin) * -1, 120)
end

--------------------------------------------------------------------------------
-- The Beached Galleon (Bombardiro Bay)
--------------------------------------------------------------------------------

-- An old wooden warship run aground and keeled over on the sand: flared hull sides, a raised stern
-- with lit windows, three masts leaning with the hull, torn sails, a crow's nest up the main mast.
-- The hull's low side is stove in at ground level, so you can walk into the hold; a hatch in the
-- deck drops into it from above. Its cannons lie half-buried in the sand around it.
local function beachedGalleon(model, origin, ctx)
	local hullWood = Color3.fromRGB(104, 72, 46)
	local darkWood = Color3.fromRGB(70, 48, 32)
	local sailcloth = Color3.fromRGB(230, 220, 194)
	local ship = origin * CFrame.new(0, 4, 0) * CFrame.Angles(math.rad(2), 0, math.rad(13))

	piece(model, Vector3.new(3, 3, 58), ship * CFrame.new(0, -3.5, 0), darkWood, Enum.Material.Wood)
	piece(model, Vector3.new(9, 1.5, 54), ship * CFrame.new(0, -2.25, -1), darkWood, Enum.Material.WoodPlanks)
	for _, side in ipairs({ -1, 1 }) do
		local wall = ship * CFrame.new(side * 6.8, 3, 0) * CFrame.Angles(0, 0, -side * 0.28)
		if side == -1 then
			-- The low side, stove in: a hole eight studs tall at ground level under a strip of planking.
			piece(model, Vector3.new(1.4, 12, 21), wall * CFrame.new(0, 0, -16.5), hullWood, Enum.Material.WoodPlanks)
			piece(model, Vector3.new(1.4, 12, 21), wall * CFrame.new(0, 0, 14.5), hullWood, Enum.Material.WoodPlanks)
			piece(model, Vector3.new(1.4, 4, 10), wall * CFrame.new(0, 4, -1), hullWood:Lerp(Color3.new(), 0.1), Enum.Material.WoodPlanks)
		else
			piece(model, Vector3.new(1.4, 12, 52), wall * CFrame.new(0, 0, -1), hullWood, Enum.Material.WoodPlanks)
		end
		-- A gold stripe along the gunwale.
		decor(piece(model, Vector3.new(0.3, 0.8, 50), wall * CFrame.new(side * 0.75, 4.5, -1), GOLD, Enum.Material.SmoothPlastic))
		-- The bow closing in to a point.
		local from = Vector3.new(side * 6.4, 3, -27)
		local to = Vector3.new(side * 0.6, 3, -39)
		-- One bow plank stands a quarter higher than the other, so their tops don't meet in one plane at the prow.
		local bowHeight = side == 1 and 12.5 or 12
		piece(model, Vector3.new(1.4, bowHeight, (to - from).Magnitude + 1), ship * CFrame.lookAt((from + to) / 2 + Vector3.new(0, (bowHeight - 12) / 2, 0), to + Vector3.new(0, (bowHeight - 12) / 2, 0)),
			hullWood, Enum.Material.WoodPlanks)
	end
	-- The stern: a tall transom with lit windows, and the raised aft deck behind it.
	piece(model, Vector3.new(16, 14.6, 1.4), ship * CFrame.new(0, 4.3, 26.4), hullWood, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -4.5, 0, 4.5 }) do
		decor(piece(model, Vector3.new(2.4, 2.6, 0.3), ship * CFrame.new(x, 7.5, 27.2), Color3.fromRGB(255, 200, 110), Enum.Material.Neon))
	end
	piece(model, Vector3.new(14, 1, 11), ship * CFrame.new(0, 11.5, 20.4), darkWood, Enum.Material.WoodPlanks)
	-- The main deck, with a hatch left open down into the hold.
	piece(model, Vector3.new(15, 1, 22), ship * CFrame.new(0, 8.3, -15), darkWood, Enum.Material.WoodPlanks)
	piece(model, Vector3.new(15, 1, 12.6), ship * CFrame.new(0, 8.3, 8.7), darkWood, Enum.Material.WoodPlanks)

	-- Masts leaning with the hull, yards across them and torn sails hanging from the yards.
	local masts = { { z = -18, height = 44, yards = { 34 } }, { z = -1, height = 58, yards = { 44, 30 } }, { z = 15, height = 40, yards = { 30 } } }
	for _, mast in ipairs(masts) do
		rod(model, (ship * CFrame.new(0, -2, mast.z)).Position, (ship * CFrame.new(0, mast.height, mast.z)).Position, 2.4, darkWood, Enum.Material.Wood)
		for _, y in ipairs(mast.yards) do
			decor(rod(model, (ship * CFrame.new(-10, y, mast.z - 1.4)).Position, (ship * CFrame.new(10, y, mast.z - 1.4)).Position, 1, darkWood,
				Enum.Material.Wood))
			local tear = rrand(-3, 3)
			-- Both halves hang from the yard, their tops lapping a little up into it.
			decor(piece(model, Vector3.new(8 + tear, 10, 0.3), ship * CFrame.new(-8 + (8 + tear) / 2, y - 5.3, mast.z - 1.4), sailcloth, Enum.Material.Fabric))
			local drop = rrand(5, 8)
			decor(piece(model, Vector3.new(6 - tear, drop, 0.3), ship * CFrame.new(8 - (6 - tear) / 2, y + 0.3 - drop / 2, mast.z - 1.4), sailcloth:Lerp(Color3.new(), 0.08),
				Enum.Material.Fabric))
		end
	end
	-- The crow's nest on the main mast, reached by a ladder from the deck.
	local nestY = 48
	column(model, 1, 10, ship * CFrame.new(0, nestY, -1), darkWood, Enum.Material.WoodPlanks)
	for index = 0, 3 do
		if index ~= 2 then
			piece(model, Vector3.new(9, 2.4, 0.4), ship * CFrame.new(0, nestY, -1) * CFrame.Angles(0, index * math.pi / 2, 0) * CFrame.new(0, 1.7, -4.7), darkWood,
				Enum.Material.Wood)
		end
	end
	ladder(model, ship * CFrame.new(0, (9 + nestY) / 2 + 0.5, 1.6), nestY - 8)
	-- A gilded fish for a figurehead.
	decor(piece(model, Vector3.new(3.4, 3.4, 3.4), ship * CFrame.new(0, 6.5, -40.5), GOLD, Enum.Material.Foil, Enum.PartType.Ball))
	decor(wedgePiece(model, Vector3.new(0.6, 3, 3), ship * CFrame.new(0, 6.5, -42.8) * CFrame.Angles(0, math.pi, 0), GOLD, Enum.Material.Foil))

	-- On the sand: cannons, barrels, spilled coins.
	for index, spot in ipairs({ { -18, -14, 0.4 }, { 16, 22, -0.8 } }) do
		local gun = origin * CFrame.new(spot[1], 0, spot[2]) * CFrame.Angles(0, spot[3], 0)
		piece(model, Vector3.new(3, 1.6, 4), gun * CFrame.new(0, 0.6, 0), darkWood, Enum.Material.Wood)
		piece(model, Vector3.new(7, 2, 2), gun * CFrame.new(0, 1.7, -1.5) * CFrame.Angles(0, math.pi / 2, 0.12), IRON, Enum.Material.Metal, Enum.PartType.Cylinder)
		if index == 1 then
			lootAt(ctx, "weapon", (gun * CFrame.new(3, 0.5, 2)).Position)
		end
	end
	for index = 0, 2 do
		column(model, 3.4, 2.6, origin * CFrame.new(-20 + index * 2.8, 1.5, 14 + index % 2) * CFrame.Angles(0, 0, index == 2 and 1.2 or 0),
			Color3.fromRGB(120, 86, 56), Enum.Material.Wood)
	end
	for _ = 1, 6 do
		decor(piece(model, Vector3.new(0.8, 0.8, 0.8), origin * CFrame.new(rrand(-24, -16), 0.3, rrand(8, 16)), GOLD, Enum.Material.Neon, Enum.PartType.Ball))
	end

	lootAt(ctx, "item", (ship * CFrame.new(2.9, nestY + 0.9, -1)).Position)
	chestAt(ctx, ship * CFrame.new(-3.5, 12.5, 21))
	chestAt(ctx, ship * CFrame.new(-1, -1, 20.5))
	lootAt(ctx, "weapon", (ship * CFrame.new(0, -1, -12)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(20, 0.5, -24)).Position)
	lootAt(ctx, "heal", (ship * CFrame.new(1, -1, 10)).Position)
	ziplineFrom(model, ctx, (ship * CFrame.new(0, nestY + 2, -4)).Position, flatRight(origin), 110)
	nameBoard(model, origin * CFrame.new(-26, 0, -30) * CFrame.Angles(0, 0.4, 0), "THE BEACHED GALLEON")
end

--------------------------------------------------------------------------------
-- Sandcastle Citadel (Bombardiro Bay)
--------------------------------------------------------------------------------

-- A sandcastle built by something enormous: a moat round a mound, a crenellated curtain wall with a
-- gate, four round towers with stepped cone tops and flags, a tall keep in the middle, and the
-- bucket and spade it was made with lying beside it. The walls can be walked; the keep's top holds
-- the chest.
local function sandcastleCitadel(model, origin, ctx)
	local sand = Color3.fromRGB(226, 200, 150)
	local wet = Color3.fromRGB(200, 170, 120)
	local moat = piece(model, Vector3.new(0.5, 76, 76), origin * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(80, 170, 200),
		Enum.Material.Glass, Enum.PartType.Cylinder)
	moat.Transparency = 0.3
	decor(moat)
	column(model, 3, 60, origin * CFrame.new(0, 1.5, 0), wet, Enum.Material.Sand)

	local base, wallH, half = 3, 15, 20
	-- Curtain walls between the towers; the front one around a gate.
	local function wall(size, at)
		piece(model, size, origin * CFrame.new(at), sand, Enum.Material.Sand)
	end
	wall(Vector3.new(28, wallH, 3), Vector3.new(0, base + wallH / 2, half))
	for _, side in ipairs({ -1, 1 }) do
		wall(Vector3.new(3, wallH, 28), Vector3.new(side * half, base + wallH / 2, 0))
		wall(Vector3.new(10.5, wallH, 3), Vector3.new(side * 8.75, base + wallH / 2, -half))
	end
	wall(Vector3.new(7, 4, 3), Vector3.new(0, base + wallH - 2, -half))
	-- Merlons along the wall tops, a little deeper than the wall so no faces line up.
	local top = base + wallH
	for _, x in ipairs({ -11.2, -5.6, 0, 5.6, 11.2 }) do
		piece(model, Vector3.new(2.6, 2.5, 3.3), origin * CFrame.new(x, top + 1.25, half), sand, Enum.Material.Sand)
		piece(model, Vector3.new(3.3, 2.5, 2.6), origin * CFrame.new(-half, top + 1.25, x), sand, Enum.Material.Sand)
		piece(model, Vector3.new(3.3, 2.5, 2.6), origin * CFrame.new(half, top + 1.25, x), sand, Enum.Material.Sand)
		if x ~= 0 then
			piece(model, Vector3.new(2.6, 2.5, 3.3), origin * CFrame.new(x, top + 1.25, -half), sand, Enum.Material.Sand)
		end
	end
	-- Corner towers with stepped cone tops and pennants.
	local flagColors = { Color3.fromRGB(255, 80, 80), Color3.fromRGB(80, 170, 255), Color3.fromRGB(255, 210, 60), Color3.fromRGB(120, 230, 120) }
	for index, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local towerH = 34
		local at = origin * CFrame.new(corner[1] * half, 0, corner[2] * half)
		column(model, towerH, 13, at * CFrame.new(0, base + towerH / 2, 0), sand, Enum.Material.Sand)
		for step, diameter in ipairs({ 14, 10, 5.5 }) do
			column(model, 3, diameter, at * CFrame.new(0, base + towerH + (step - 0.5) * 3, 0), wet, Enum.Material.Sand)
		end
		local poleTop = base + towerH + 9 + 7
		decor(rod(model, (at * CFrame.new(0, base + towerH + 8.5, 0)).Position, (at * CFrame.new(0, poleTop, 0)).Position, 0.4, IRON,
			Enum.Material.Wood))
		decor(piece(model, Vector3.new(4.5, 2.6, 0.2), at * CFrame.new(2.4, poleTop - 1.5, 0), flagColors[index], Enum.Material.Neon))
	end
	-- The keep, with corner merlons, a flag and a ladder up its back.
	local keepH = 30
	piece(model, Vector3.new(16, keepH, 16), origin * CFrame.new(0, base + keepH / 2, 2), sand, Enum.Material.Sand)
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		piece(model, Vector3.new(3.4, 3, 3.4), origin * CFrame.new(corner[1] * 6.3, base + keepH + 1.5, 2 + corner[2] * 6.3), sand, Enum.Material.Sand)
	end
	decor(rod(model, (origin * CFrame.new(0, base + keepH, 2)).Position, (origin * CFrame.new(0, base + keepH + 14, 2)).Position, 0.5, IRON, Enum.Material.Metal))
	decor(piece(model, Vector3.new(7, 4, 0.2), origin * CFrame.new(3.6, base + keepH + 11.8, 2), Color3.fromRGB(255, 120, 200), Enum.Material.Neon))
	ladder(model, origin * CFrame.new(0, base + keepH / 2, 11), keepH)
	ladder(model, origin * CFrame.new(-10, base + wallH / 2, half - 2.5), wallH)

	-- The bucket on its side and the spade stuck in the sand against the wall.
	local bucket = origin * CFrame.new(31, 6, 22) * CFrame.Angles(0, 0.6, 0)
	piece(model, Vector3.new(11, 12, 12), bucket, Color3.fromRGB(220, 60, 60), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	piece(model, Vector3.new(0.8, 13.2, 13.2), bucket * CFrame.new(5.6, 0, 0), Color3.fromRGB(240, 90, 90), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	local handleFrom = (bucket * CFrame.new(-2, 0, 6.2)).Position
	decor(rod(model, handleFrom, (bucket * CFrame.new(-2, 7, 2)).Position, 0.5, Color3.fromRGB(240, 240, 240), Enum.Material.SmoothPlastic))
	local spadeFoot = (origin * CFrame.new(-34, 1, 6)).Position
	local spadeTop = (origin * CFrame.new(-21.6, 21, 6)).Position
	rod(model, spadeFoot + (spadeTop - spadeFoot).Unit * 3, spadeTop, 1.4, Color3.fromRGB(70, 140, 230), Enum.Material.SmoothPlastic)
	piece(model, Vector3.new(6, 7, 0.5), CFrame.lookAt(spadeFoot, spadeTop) * CFrame.new(0, 0, -1) * CFrame.Angles(math.pi / 2, 0, 0),
		Color3.fromRGB(255, 210, 60), Enum.Material.SmoothPlastic)
	for _ = 1, 4 do
		decor(piece(model, Vector3.new(1.2, 1.2, 1.2), origin * CFrame.new(rrand(-12, 12), 3.2, rrand(-25.5, -23)), Color3.fromRGB(255, 150, 170), Enum.Material.SmoothPlastic,
			Enum.PartType.Ball))
	end

	chestAt(ctx, origin * CFrame.new(0, base + keepH + 0.5, 0))
	lootAt(ctx, "weapon", (origin * CFrame.new(-10, base + 0.5, -10)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(12, base + 0.5, 12)).Position)
	-- In the gap between two merlons (they stand at x -11.2, -5.6, 0, 5.6, 11.2), on the wall walk.
	lootAt(ctx, "item", (origin * CFrame.new(8.4, top + 0.4, half)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-14, 3.5, -26)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-12, base + 0.5, 12)).Position)
	ziplineFrom(model, ctx, (origin * CFrame.new(-6.5, base + keepH + 3, 2)).Position, flatRight(origin) * -1, 110)
	nameBoard(model, origin * CFrame.new(10, 0, -41), "SANDCASTLE CITADEL")
end

--------------------------------------------------------------------------------
-- The Stone Noggin (Rot Ridge)
--------------------------------------------------------------------------------

-- A colossal carved stone head on the heights, leaning back a little as if looking at the sky,
-- with glowing eyes, a heavy brow, and a knitted red beanie with a pompom, snow on its top. Its
-- open mouth is a cave with the chest inside; a ladder up the back of its head reaches the beanie.
local function stoneNoggin(model, origin, ctx)
	local stone = Color3.fromRGB(122, 120, 116)
	local knit = Color3.fromRGB(196, 48, 58)
	local snow = Color3.fromRGB(236, 242, 246)
	local glow = Color3.fromRGB(110, 230, 255)
	local head = origin * CFrame.new(0, 0, 4) * CFrame.Angles(0.07, 0, 0)

	-- Built round the mouth cave (x -5..5, y 4..11, z -11..5): chin, cheeks, the back of the mouth
	-- and the upper head, each butted against the next.
	piece(model, Vector3.new(26, 5, 22), head * CFrame.new(0, 1.5, 0), stone, Enum.Material.Slate)
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(8, 7, 22), head * CFrame.new(side * 9, 7.5, 0), stone:Lerp(Color3.new(), 0.04), Enum.Material.Slate)
		piece(model, Vector3.new(2, 7, 5), head * CFrame.new(side * 14, 17, 1), stone:Lerp(Color3.new(), 0.08), Enum.Material.Slate)
		decor(piece(model, Vector3.new(7, 5.5, 0.6), head * CFrame.new(side * 6.5, 18.5, -11.2), Color3.fromRGB(40, 40, 46), Enum.Material.Slate))
		local eye = decor(piece(model, Vector3.new(4, 4, 4), head * CFrame.new(side * 6.5, 18.5, -11.4), glow, Enum.Material.Neon, Enum.PartType.Ball))
		light(eye, glow, 24, 1.6)
	end
	piece(model, Vector3.new(10, 7, 6), head * CFrame.new(0, 7.5, 8), stone:Lerp(Color3.new(), 0.1), Enum.Material.Slate)
	piece(model, Vector3.new(26, 19, 22), head * CFrame.new(0, 20.5, 0), stone, Enum.Material.Slate)
	piece(model, Vector3.new(28, 4, 5), head * CFrame.new(0, 24, -12.5), stone:Lerp(Color3.new(1, 1, 1), 0.05), Enum.Material.Slate)
	-- The nose: a wedge, back against the face, sloping out and down over the mouth.
	wedgePiece(model, Vector3.new(5, 6, 5), head * CFrame.new(0, 14, -13.5),
		stone:Lerp(Color3.new(), 0.06), Enum.Material.Slate)
	for _, x in ipairs({ -3, 0, 3 }) do
		decor(piece(model, Vector3.new(2, 1.6, 0.8), head * CFrame.new(x, 10.2, -10.5), Color3.fromRGB(230, 226, 214), Enum.Material.Marble))
	end
	-- The beanie: body, a folded band a hair wider and set lower, snow on top, and the pompom.
	piece(model, Vector3.new(27, 8, 23), head * CFrame.new(0, 34, 0), knit, Enum.Material.Fabric)
	piece(model, Vector3.new(27.8, 3, 23.8), head * CFrame.new(0, 31.3, 0), knit:Lerp(Color3.new(), 0.18), Enum.Material.Fabric)
	decor(piece(model, Vector3.new(24, 0.6, 20), head * CFrame.new(0, 38.2, 0), snow, Enum.Material.Snow))
	piece(model, Vector3.new(9, 9, 9), head * CFrame.new(0, 42.5, 0), snow, Enum.Material.Fabric, Enum.PartType.Ball)
	decor(piece(model, Vector3.new(25.4, 0.5, 4), head * CFrame.new(0, 26.2, -12.6), snow, Enum.Material.Snow))
	for _, offset in ipairs({ Vector3.new(-14, 1, -12), Vector3.new(15, 1, -8), Vector3.new(-12, 1, 13) }) do
		decor(piece(model, Vector3.new(6, 6, 6), origin * CFrame.new(offset), snow, Enum.Material.Snow, Enum.PartType.Ball))
	end
	ladder(model, head * CFrame.new(0, 20, 12.5), 40)

	chestAt(ctx, head * CFrame.new(0, 4.5, -2))
	chestAt(ctx, origin * CFrame.new(-19, 0.5, 15))
	lootAt(ctx, "heal", (head * CFrame.new(3, 4.5, 2)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(18, 0.5, 10)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-18, 0.5, -10)).Position)
	lootAt(ctx, "item", (head * CFrame.new(-7, 38.9, -6.5)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(10, 1, -18)).Position)
	ziplineFrom(model, ctx, (head * CFrame.new(8, 40, 0)).Position, flatRight(origin), 110)
	nameBoard(model, origin * CFrame.new(-12, 0, -22), "THE STONE NOGGIN", glow)
end

--------------------------------------------------------------------------------
-- Turbine Ridge (Rot Ridge)
--------------------------------------------------------------------------------

-- Three wind turbines standing in a staggered line along the high ground, blades always turning,
-- red lights on their nacelles, a cable slung between them. A service ladder climbs the middle one
-- to a sniper's perch on its nacelle; the chest is in the maintenance hut at its foot.
local function turbineRidge(model, origin, ctx)
	local white = Color3.fromRGB(236, 238, 240)
	local spots = { Vector3.new(-40, 0, -22), Vector3.new(0, 0, 0), Vector3.new(40, 0, 22) }
	local speeds = { 38, 32, 44 }
	local anchors = {}
	for index, offset in ipairs(spots) do
		local at = origin * CFrame.new(offset)
		local g = ctx.groundHeightAt(at.X, at.Z) or origin.Y
		local base = CFrame.new(at.X, g, at.Z) * origin.Rotation
		-- The tower stands on its own pad on its own ground: 7.8 square is the biggest square inside
		-- the 11-stud pad, so the audit's edge ring stays on concrete.
		local tower = footing(model, "Turbine" .. index, at.X, g + 1.5, at.Z, 7.8, 7.8)
		column(tower, 2, 11, base * CFrame.new(0, 0.5, 0), CONCRETE, Enum.Material.Concrete)
		column(tower, 38, 4.6, base * CFrame.new(0, 1.5 + 19, 0), white, Enum.Material.SmoothPlastic)
		column(tower, 36, 3.4, base * CFrame.new(0, 39.5 + 18, 0), white, Enum.Material.SmoothPlastic)
		decor(piece(tower, Vector3.new(1.8, 3.4, 0.4), base * CFrame.new(0, 3.2, -2.2), Color3.fromRGB(80, 84, 92), Enum.Material.Metal))
		local hubY = 77.7
		piece(tower, Vector3.new(4.4, 4.4, 10), base * CFrame.new(0, hubY, 1.5), white, Enum.Material.SmoothPlastic)
		local lamp = decor(piece(tower, Vector3.new(1, 1, 1), base * CFrame.new(0, hubY + 2.7, 4), RED, Enum.Material.Neon, Enum.PartType.Ball))
		light(lamp, RED, 20, 1.2)
		-- The rotor: a hub whose own Y axis points out of the nacelle, so AmbientSpin turns the blades.
		local hubAt = base * CFrame.new(0, hubY, -4.4)
		local hub = decor(piece(tower, Vector3.new(3.6, 3.6, 3.6), hubAt * CFrame.Angles(math.pi / 2, 0, 0), white, Enum.Material.SmoothPlastic, Enum.PartType.Ball))
		hub.Name = "RotorHub"
		for blade = 0, 2 do
			decor(piece(hub, Vector3.new(1.4, 26, 0.35), hubAt * CFrame.Angles(0, 0, blade * math.pi * 2 / 3) * CFrame.new(0, 14, -0.6) * CFrame.Angles(0, 0.12, 0),
				white, Enum.Material.SmoothPlastic))
		end
		spin(hub, speeds[index])
		table.insert(anchors, base)
		if index == 2 then
			-- The service ladder, standing clear behind the nacelle so its top steps onto the roof.
			ladder(model, base * CFrame.new(0, 1.5 + 39.5, 7.6), 79)
			lootAt(ctx, "item", (base * CFrame.new(0, hubY + 2.6, 2)).Position)
			ziplineFrom(model, ctx, (base * CFrame.new(0, hubY + 4, 5)).Position, flatForward(origin) * -1, 140)
		end
	end
	-- The cable between the towers.
	for index = 1, 2 do
		decor(rod(model, (anchors[index] * CFrame.new(0, 30, 0)).Position, (anchors[index + 1] * CFrame.new(0, 30, 0)).Position, 0.25, IRON, Enum.Material.Metal))
	end
	-- The maintenance hut beside the middle tower, its door toward the front.
	local hutAt = origin * CFrame.new(0, 0, -14)
	local hg = ctx.groundHeightAt(hutAt.X, hutAt.Z) or origin.Y
	local hut = CFrame.new(hutAt.X, hg, hutAt.Z) * origin.Rotation
	local hutModel = footing(model, "Hut", hutAt.X, hg, hutAt.Z, 9.2, 6.6)
	local wallColor = Color3.fromRGB(150, 150, 146)
	piece(hutModel, Vector3.new(10, 9, 0.8), hut * CFrame.new(0, 2.5, 3.6), wallColor, Enum.Material.Concrete)
	for _, side in ipairs({ -1, 1 }) do
		piece(hutModel, Vector3.new(0.8, 9, 6.4), hut * CFrame.new(side * 4.6, 2.5, 0), wallColor, Enum.Material.Concrete)
		piece(hutModel, Vector3.new(3.2, 9, 0.8), hut * CFrame.new(side * 3.4, 2.5, -3.6), wallColor, Enum.Material.Concrete)
	end
	piece(hutModel, Vector3.new(3.6, 2, 0.8), hut * CFrame.new(0, 6, -3.6), wallColor, Enum.Material.Concrete)
	piece(hutModel, Vector3.new(11, 0.8, 9), hut * CFrame.new(0, 7.4, 0), DARK_CONCRETE, Enum.Material.Concrete)
	chestAt(ctx, hut * CFrame.new(0, 0.5, 1.5))
	lootAt(ctx, "heal", (hut * CFrame.new(-2.5, 0.5, -1)).Position)
	local firstBase = anchors[1]
	lootAt(ctx, "weapon", (firstBase * CFrame.new(8.5, 0.5, 0)).Position)
	chestAt(ctx, anchors[3] * CFrame.new(-8, 0.5, 0))
	lootAt(ctx, "weapon", (anchors[3] * CFrame.new(0, 0.5, 8.5)).Position)
	lootAt(ctx, "heal", (hut * CFrame.new(6, 0.5, -6)).Position)
	nameBoard(model, hut * CFrame.new(9, 0, -6), "TURBINE RIDGE")
end

--------------------------------------------------------------------------------
-- The Giant Scarecrow (Patapim Plains)
--------------------------------------------------------------------------------

-- A scarecrow as tall as a tower block standing in a corn patch: sack head with stitched eyes and a
-- stitched grin under a wide straw hat, a patched plaid shirt with straw poking out of the cuffs,
-- crows perched on its arms. The corn is concealment you can walk through; a ladder up the post
-- reaches the arms.
local function giantScarecrow(model, origin, ctx)
	local straw = Color3.fromRGB(222, 190, 100)
	local sack = Color3.fromRGB(196, 170, 120)
	local plaid = Color3.fromRGB(172, 52, 46)
	local wood = Color3.fromRGB(120, 88, 58)
	local black = Color3.fromRGB(26, 24, 28)
	-- Corn rows either side of the scarecrow.
	for _, x in ipairs({ -17, -12, -7, 7, 12, 17 }) do
		decor(piece(model, Vector3.new(1.6, 4.2, 36), origin * CFrame.new(x, 2.1, 0), Color3.fromRGB(86, 140, 56), Enum.Material.Grass))
		for _, z in ipairs({ -12, 2, 14 }) do
			decor(piece(model, Vector3.new(0.7, 1.4, 0.7), origin * CFrame.new(x + 0.9, 3.4, z + rrand(-2, 2)), Color3.fromRGB(240, 206, 80), Enum.Material.SmoothPlastic))
		end
	end

	rod(model, (origin * CFrame.new(0, -1, 0)).Position, (origin * CFrame.new(0, 50, 0)).Position, 3, wood, Enum.Material.Wood)
	-- The crossbar ends inside the sleeves, so its end caps never meet the sleeves' ends.
	rod(model, (origin * CFrame.new(-18.4, 36, 0)).Position, (origin * CFrame.new(18.4, 36, 0)).Position, 2, wood, Enum.Material.Wood)
	piece(model, Vector3.new(13, 15, 5), origin * CFrame.new(0, 29, 0), plaid, Enum.Material.Fabric)
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(13, 5, 4.6), origin * CFrame.new(side * 12.5, 36, 0), plaid:Lerp(Color3.new(), 0.08), Enum.Material.Fabric)
		for index, angle in ipairs({ -0.45, 0.4 }) do
			decor(piece(model, Vector3.new(3, 1, 3.8 - index * 0.3), origin * CFrame.new(side * (19.6 + index * 0.4), 35.6 + index * 0.5, 0) * CFrame.Angles(0, 0, side * angle), straw,
				Enum.Material.Grass))
		end
	end
	-- Patches, buttons and straw hanging from under the shirt.
	decor(piece(model, Vector3.new(3.4, 3.2, 0.3), origin * CFrame.new(-3, 25, -2.65), Color3.fromRGB(70, 110, 170), Enum.Material.Fabric))
	decor(piece(model, Vector3.new(2.6, 2.8, 0.3), origin * CFrame.new(3.6, 32, -2.65), Color3.fromRGB(220, 190, 80), Enum.Material.Fabric))
	for _, y in ipairs({ 34, 30, 26 }) do
		decor(piece(model, Vector3.new(0.9, 0.9, 0.9), origin * CFrame.new(0.4, y, -2.6), Color3.fromRGB(236, 230, 210), Enum.Material.SmoothPlastic, Enum.PartType.Ball))
	end
	for _, x in ipairs({ -4, 0, 4 }) do
		decor(piece(model, Vector3.new(1.4, 4, 1.4), origin * CFrame.new(x, 20.4, 0) * CFrame.Angles(0, 0, x * 0.05), straw, Enum.Material.Grass))
	end

	-- The head: a sack with stitched X eyes and a stitched grin, under a wide straw hat.
	local headY = 44
	piece(model, Vector3.new(12, 12, 12), origin * CFrame.new(0, headY, 0), sack, Enum.Material.Fabric, Enum.PartType.Ball)
	for _, side in ipairs({ -1, 1 }) do
		-- The two strokes of each X differ in depth, so their front faces never share a plane.
		for stroke, angle in ipairs({ 0.785, -0.785 }) do
			decor(piece(model, Vector3.new(2.6, 0.45, 0.3 + stroke * 0.15), origin * CFrame.new(side * 2.4, headY + 1.5, -5.4) * CFrame.Angles(0, 0, angle), black,
				Enum.Material.SmoothPlastic))
		end
	end
	decor(piece(model, Vector3.new(4.4, 0.4, 0.4), origin * CFrame.new(0, headY - 2.4, -5.3), black, Enum.Material.SmoothPlastic))
	for _, x in ipairs({ -1.6, -0.5, 0.6, 1.7 }) do
		decor(piece(model, Vector3.new(0.3, 1.2, 0.6), origin * CFrame.new(x, headY - 2.4, -5.3), black, Enum.Material.SmoothPlastic))
	end
	column(model, 0.8, 20, origin * CFrame.new(0, headY + 5.2, 0), straw, Enum.Material.Grass)
	column(model, 6, 10, origin * CFrame.new(0, headY + 8.5, 0), straw, Enum.Material.Grass)
	column(model, 1.3, 10.6, origin * CFrame.new(0, headY + 6.3, 0), Color3.fromRGB(110, 60, 40), Enum.Material.Fabric)

	-- Crows on the arms and the hat brim.
	for index, spot in ipairs({ Vector3.new(-15, 39.6, 0), Vector3.new(16.5, 39.6, 1), Vector3.new(6.5, headY + 6.7, -5) }) do
		local crow = origin * CFrame.new(spot) * CFrame.Angles(0, index * 1.9, 0)
		decor(piece(model, Vector3.new(2.2, 2.2, 2.2), crow, black, Enum.Material.SmoothPlastic, Enum.PartType.Ball))
		decor(piece(model, Vector3.new(1.4, 1.4, 1.4), crow * CFrame.new(0, 1.2, -1), black, Enum.Material.SmoothPlastic, Enum.PartType.Ball))
		decor(wedgePiece(model, Vector3.new(0.4, 0.5, 0.9), crow * CFrame.new(0, 1.1, -2.1) * CFrame.Angles(0, math.pi, 0), Color3.fromRGB(240, 160, 40),
			Enum.Material.SmoothPlastic))
	end

	-- A hay pile at the foot with the chest in it, and the ladder up the back of the post.
	for index, spot in ipairs({ { 6, 7 }, { 11, 9 }, { 8.5, 13 } }) do
		piece(model, Vector3.new(4.4, 5.4, 5.4), origin * CFrame.new(spot[1], 2.6, spot[2]) * CFrame.Angles(0, index * 0.7, 0), straw, Enum.Material.Grass,
			Enum.PartType.Cylinder)
	end
	ladder(model, origin * CFrame.new(0, 19, 3.5), 38)

	-- Chests turned to run along the rows, so they fit the gaps: one beside the hay, one in the corn.
	chestAt(ctx, origin * CFrame.new(3.6, 0.5, 14) * CFrame.Angles(0, math.pi / 2, 0))
	chestAt(ctx, origin * CFrame.new(-14.5, 0.5, 7.5) * CFrame.Angles(0, math.pi / 2, 0))
	lootAt(ctx, "item", (origin * CFrame.new(-12.5, 38.9, 0)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(14.5, 0.5, -12)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-2, 0.5, -16)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-9.5, 1, -8)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(14.5, 1, 4)).Position)
	ziplineFrom(model, ctx, (origin * CFrame.new(17, 41, 0)).Position, flatRight(origin), 100)
	nameBoard(model, origin * CFrame.new(-8, 0, -22), "THE GIANT SCARECROW")
end

--------------------------------------------------------------------------------
-- Patapim Water Tower (Patapim Plains)
--------------------------------------------------------------------------------

-- The farmland's tallest thing: a painted water tank on four splayed legs with a railed catwalk
-- round its base, a stepped cone roof, and PATAPIM lettered round the tank. A ladder climbs to the
-- catwalk and a zipline runs off it.
local function patapimWaterTower(model, origin, ctx)
	local legColor = Color3.fromRGB(140, 62, 50)
	local tankColor = Color3.fromRGB(236, 232, 220)
	local red = Color3.fromRGB(196, 52, 46)
	local deckY = 47.7
	local legTops = {}
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local foot = (origin * CFrame.new(corner[1] * 9, -1, corner[2] * 9)).Position
		local top = (origin * CFrame.new(corner[1] * 6.2, 47, corner[2] * 6.2)).Position
		rod(model, foot, top, 1.8, legColor, Enum.Material.Metal)
		table.insert(legTops, { foot = foot, top = top })
	end
	-- Ring beams between the legs at two heights.
	for _, t in ipairs({ 0.36, 0.7 }) do
		for index = 1, 4 do
			local order = { 1, 2, 4, 3 }
			local a, b = legTops[order[index]], legTops[order[index % 4 + 1]]
			decor(rod(model, a.foot:Lerp(a.top, t), b.foot:Lerp(b.top, t), 0.5, legColor, Enum.Material.Metal))
		end
	end
	column(model, 0.7, 30, origin * CFrame.new(0, deckY - 0.35, 0), IRON, Enum.Material.DiamondPlate)
	for index = 1, 11 do
		local angle = index / 12 * math.pi * 2
		piece(model, Vector3.new(7.8, 2.6, 0.35), origin * CFrame.Angles(0, angle, 0) * CFrame.new(0, deckY + 1.3, -14.6), IRON, Enum.Material.Metal)
	end
	ladder(model, origin * CFrame.new(0, deckY / 2 + 0.5, -16), deckY + 1)

	-- The tank, its red bands and the stepped cone roof.
	column(model, 18, 22, origin * CFrame.new(0, deckY + 9, 0), tankColor, Enum.Material.SmoothPlastic)
	for _, y in ipairs({ deckY + 3, deckY + 15 }) do
		decor(column(model, 1.2, 22.4, origin * CFrame.new(0, y, 0), red, Enum.Material.SmoothPlastic))
	end
	for step, spec in ipairs({ { 23, 2.5 }, { 16, 2.5 }, { 9, 2.5 } }) do
		column(model, spec[2], spec[1], origin * CFrame.new(0, deckY + 18 - 0.05 + (step - 0.5) * 2.5, 0), red, Enum.Material.SmoothPlastic)
	end
	local finial = decor(piece(model, Vector3.new(2.5, 2.5, 2.5), origin * CFrame.new(0, deckY + 26.7, 0), GOLD, Enum.Material.Foil, Enum.PartType.Ball))
	light(finial, GOLD, 30, 1)
	-- PATAPIM lettered round the front of the tank, one board per letter, each facing out.
	local word = "PATAPIM"
	for index = 1, #word do
		local angle = (index - (#word + 1) / 2) * 0.24
		local board = decor(piece(model, Vector3.new(2.6, 3.8, 0.3), origin * CFrame.Angles(0, angle, 0) * CFrame.new(0, deckY + 9, -11.1), tankColor,
			Enum.Material.SmoothPlastic))
		sign(board, string.sub(word, index, index), red, nil, { Enum.NormalId.Front })
	end
	decor(rod(model, (origin * CFrame.new(0, deckY - 0.2, 0)).Position, (origin * CFrame.new(0, 18, 0)).Position, 1.2, IRON, Enum.Material.Metal))

	chestAt(ctx, origin * CFrame.new(-12.7, deckY + 0.5, 0) * CFrame.Angles(0, math.pi / 2, 0))
	chestAt(ctx, origin * CFrame.new(-4, 0.5, -4))
	lootAt(ctx, "item", (origin * CFrame.new(12.7, deckY + 0.4, 2.5)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(16, 0.5, 12)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-15, 0.5, 14)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(4, 1, -4)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-5, 1, 6)).Position)
	ziplineFrom(model, ctx, (origin * CFrame.new(13, deckY + 3, -3)).Position, flatRight(origin), 110)
	nameBoard(model, origin * CFrame.new(-6, 0, -20), "PATAPIM WATER TOWER")
end

--------------------------------------------------------------------------------
-- Crop Circle Saucer (Patapim Plains)
--------------------------------------------------------------------------------

-- A flying saucer ploughed into a wheat field, glowing, a pale beam still climbing out of it into the
-- sky, the crop around it flattened into rings. The beam is what you steer by from across the map.
local function cropCircleSaucer(model, origin, ctx)
	local flattened = Color3.fromRGB(214, 192, 128)
	local standing = Color3.fromRGB(226, 186, 76)
	local metal = Color3.fromRGB(186, 194, 204)
	local glow = Color3.fromRGB(130, 255, 160)
	-- Rings of flattened crop with rings of standing wheat between them, drawn as arc segments.
	local function ring(radius, width, height, color, segments, lift)
		for index = 0, segments - 1 do
			local angle = (index + 0.5) / segments * math.pi * 2
			local length = 2 * radius * math.tan(math.pi / segments) + 0.3
			-- Neighbouring segments overlap at their joints, so alternate ones stand a little taller:
			-- two tops in one plane would flicker where they cross.
			local h = height + (index % 2) * 0.08
			local bottom = lift + (index % 2) * 0.06
			decor(piece(model, Vector3.new(length, h, width), origin * CFrame.Angles(0, angle, 0) * CFrame.new(0, bottom + h / 2, -radius), color,
				Enum.Material.Grass))
		end
	end
	decor(column(model, 0.2, 14, origin * CFrame.new(0, 0.12, 0), flattened, Enum.Material.Grass))
	ring(13, 3, 0.2, flattened, 14, 0.02)
	ring(19, 4, 2.6, standing, 16, 0)
	ring(26, 3, 0.2, flattened, 18, 0.04)
	ring(33, 5, 3, standing, 20, 0)

	-- The saucer, nosed into the ground at the circle's heart.
	local saucer = origin * CFrame.new(3, 3.2, 2) * CFrame.Angles(math.rad(14), rrand(0, math.pi * 2), math.rad(8))
	piece(model, Vector3.new(3, 26, 26), saucer * CFrame.Angles(0, 0, math.pi / 2), metal, Enum.Material.Metal, Enum.PartType.Cylinder)
	piece(model, Vector3.new(2, 17, 17), saucer * CFrame.new(0, -2.3, 0) * CFrame.Angles(0, 0, math.pi / 2), metal:Lerp(Color3.new(), 0.3), Enum.Material.Metal,
		Enum.PartType.Cylinder)
	local dome = piece(model, Vector3.new(11, 11, 11), saucer * CFrame.new(0, 2.2, 0), Color3.fromRGB(120, 230, 240), Enum.Material.Glass, Enum.PartType.Ball)
	dome.Transparency = 0.35
	for index = 0, 9 do
		local angle = index / 10 * math.pi * 2
		decor(piece(model, Vector3.new(1.2, 1.2, 1.2), saucer * CFrame.new(math.cos(angle) * 12.8, 0, math.sin(angle) * 12.8), glow, Enum.Material.Neon,
			Enum.PartType.Ball))
	end
	-- The beam: a pale column of light rising far above the fields.
	local beamPart = decor(piece(model, Vector3.new(170, 5, 5), CFrame.new((saucer * CFrame.new(0, 3, 0)).Position + Vector3.new(0, 85, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		glow, Enum.Material.Neon, Enum.PartType.Cylinder))
	beamPart.Transparency = 0.72
	beamPart.CastShadow = false
	light(dome, glow, 40, 2)
	local smoke = Instance.new("ParticleEmitter")
	smoke.Color = ColorSequence.new(Color3.fromRGB(90, 90, 96))
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	smoke.Lifetime = NumberRange.new(3, 5)
	smoke.Speed = NumberRange.new(3, 6)
	smoke.Rate = 4
	smoke.Parent = dome
	decor(column(model, 0.2, 20, origin * CFrame.new(-4, 0.2, -3), Color3.fromRGB(50, 44, 40), Enum.Material.Slate))

	chestAt(ctx, origin * CFrame.new(-18, 0.5, 18))
	lootAt(ctx, "item", (origin * CFrame.new(-6, 0.5, -6)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(22, 0.5, 5)).Position)
	lootAt(ctx, "heal", (origin * CFrame.new(-2, 0.5, 24)).Position)
	lootAt(ctx, "weapon", (origin * CFrame.new(-26, 0.5, -12)).Position)
	lootAt(ctx, "item", (origin * CFrame.new(14, 0.5, -22)).Position)
	nameBoard(model, origin * CFrame.new(0, 0, -40), "CROP CIRCLE", glow)
end

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

-- `footprint` is the radius the site levels and claims; `flat` how much the ground may vary
-- across it before the spot is rejected; `edge` pins it toward the map's rim.
-- `natural` sites are levelled in the map's own ground rather than paved; `level = false` pieces
-- aren't levelled at all (a line of arches, a row of turbines) and find the ground under each of
-- their own feet, so `flat` can be much looser for them.
local LANDMARKS = {
	{ id = "SignalHill", name = "Signal Hill", build = signalHill, footprint = 30, flat = 6 },
	{ id = "RotDocks", name = "Rot Docks", build = rotDocks, footprint = 52, flat = 5 },
	{ id = "RotBowl", name = "The Rot Bowl", build = rotBowl, footprint = 56, flat = 5 },
	{ id = "Flight67", name = "Flight 67", build = flight67, footprint = 40, flat = 7 },
	-- `footing`: the square the footing audit measures, where the computed one would cross a hole the
	-- piece digs on purpose (the ruins' sunken chamber at z -30 and its stairwell at -18).
	{ id = "SahurRuins", name = "Sahur Ruins", build = sahurRuins, footprint = 40, flat = 6, natural = true, footing = 19 },
	{ id = "Carnival", name = "Brainrot Carnival", build = carnival, footprint = 50, flat = 5 },
	{ id = "Farmstead", name = "Sahur Farmstead", build = farmstead, footprint = 46, flat = 5, natural = true },
	{ id = "SigmaSpire", name = "The Sigma Spire", build = sigmaSpire, footprint = 34, flat = 5 },
	{ id = "HotSprings", name = "Sahur Hot Springs", build = hotSprings, footprint = 42, flat = 6, natural = true },
	-- The monuments.
	{ id = "GreatSundial", name = "The Great Sundial", build = greatSundial, footprint = 36, flat = 6, natural = true },
	{ id = "AuraWindmill", name = "Aura Windmill", build = auraWindmill, footprint = 32, flat = 6, natural = true },
	{ id = "SahurAqueduct", name = "Sahur Aqueduct", build = sahurAqueduct, footprint = 66, flat = 22, level = false },
	{ id = "CraneYard", name = "Crane Yard", build = craneYard, footprint = 48, flat = 5 },
	{ id = "TralalaArch", name = "The Tralala Arch", build = tralalaArch, footprint = 44, flat = 5 },
	{ id = "BeachedGalleon", name = "The Beached Galleon", build = beachedGalleon, footprint = 48, flat = 6, natural = true },
	{ id = "SandcastleCitadel", name = "Sandcastle Citadel", build = sandcastleCitadel, footprint = 44, flat = 5, natural = true },
	{ id = "StoneNoggin", name = "The Stone Noggin", build = stoneNoggin, footprint = 32, flat = 8, natural = true },
	{ id = "TurbineRidge", name = "Turbine Ridge", build = turbineRidge, footprint = 58, flat = 18, level = false },
	{ id = "GiantScarecrow", name = "The Giant Scarecrow", build = giantScarecrow, footprint = 30, flat = 6, natural = true },
	{ id = "WaterTower", name = "Patapim Water Tower", build = patapimWaterTower, footprint = 26, flat = 6, natural = true },
	{ id = "CropCircle", name = "Crop Circle", build = cropCircleSaucer, footprint = 46, flat = 5, natural = true },
}
Landmarks.Registry = LANDMARKS

-- What each map is made of. `always` go down first, in order (each map's original signature
-- landmark, then its monuments); `pool` tops the map up from pieces that suit it. Nothing from
-- one map's list turns up on another's, which is what makes the maps tell apart.
local MAP_SETS = {
	SahurSprings = { always = { "HotSprings", "GreatSundial", "AuraWindmill" }, pool = { "SahurAqueduct", "SahurRuins", "Flight67" } },
	TralalaTown = { always = { "SigmaSpire", "CraneYard", "TralalaArch" }, pool = { "RotBowl", "Flight67" } },
	BombardiroBay = { always = { "Carnival", "BeachedGalleon", "SandcastleCitadel" }, pool = { "RotDocks", "Flight67" } },
	RotRidge = { always = { "SignalHill", "StoneNoggin", "TurbineRidge" }, pool = { "SahurRuins", "HotSprings" } },
	PatapimPlains = { always = { "Farmstead", "GiantScarecrow", "WaterTower" }, pool = { "CropCircle", "RotBowl", "Flight67" } },
}
Landmarks.MapSets = MAP_SETS

local BY_ID = {}
for _, landmark in ipairs(LANDMARKS) do
	BY_ID[landmark.id] = landmark
end

local BEACON = { id = "Beacon", name = "The Beacon", build = beacon, footprint = 22, flat = 6, edge = true }
Landmarks.Beacon = BEACON

-- A levelled site is a flat round pad with terraced steps down to the ground round it (Oliver, 18:40:
-- terraced steps, not a flat disc). Every step is STEP_RISE high and STEP_RUN deep, which a player
-- walks up without a vault, and a whole number of studs so Pavement's surface (which snaps to whole
-- studs) lands exactly where the step says.
-- MEASURED (five points, two of them written by the probe itself on empty ground): terrain renders
-- its surface at the 4-STUD VOXEL BOUNDARY at or above the fill's top, plus SurfaceLift. So a pad
-- filled to an arbitrary height comes out up to 3 studs higher than asked, which is why three
-- landmarks declared a floor 3 studs under the ground that actually rendered, and why terrain rings
-- 2 studs apart came out as one smooth mound: both steps landed on the same voxel boundary.
-- A site height is therefore chosen so that (height - SurfaceLift) sits exactly ON a boundary, and
-- the terrain's own terraces step by a whole voxel. The walkable 2-stud steps are built out of stone
-- on top of them, which is a part and lands where it is put.
local VOXEL = 4
local TERRAIN_STEP_RISE = VOXEL
local TERRAIN_STEP_RUN = 6
-- The stone steps: two per terrain ring, so each is a 2-stud rise on a 3-stud tread.
local STEP_RISE = 2
local STEP_RUN = 3

-- The nearest height whose pad fill lands exactly on a voxel boundary, so the ground renders where
-- the landmark says its floor is.
local function padHeight(y)
	local lift = MapTerrain.SurfaceLift
	return math.floor((y - lift) / VOXEL + 0.5) * VOXEL + lift
end
-- Enough steps for the worst site a search will accept, and no more: past this the landmark would
-- claim half the map.
local MAX_STEPS = 7

-- How many steps a site needs, and how far out they reach: a flat site gets one, a site on a slope
-- gets one per STEP_RISE of fall. `drop` is how far the ground falls away at the pad's edge.
local function terraceSteps(drop)
	-- Counted in terrain rings, each a voxel deep.
	return math.clamp(math.ceil(drop / TERRAIN_STEP_RISE), 1, MAX_STEPS)
end

local function siteRadius(footprint, steps)
	-- Terrain rings are what reach furthest: two stone steps sit on each one.
	return footprint + 4 + steps * TERRAIN_STEP_RUN
end

-- The ground at a point, or nil where there is none: no solid surface, or water lying over it.
-- Two rays from far above (a ray that starts inside terrain never reports that terrain): one that
-- stops at the water's surface and one that ignores water. A gap between them is water, however it
-- got there, which is the defence that matters -- a lake dug after the landmarks would otherwise
-- read as the flattest, most inviting site on the map.
local WATER_DEPTH = 0.5
local wetParams = RaycastParams.new()
wetParams.FilterType = Enum.RaycastFilterType.Include
wetParams.IgnoreWater = false
local dryParams = RaycastParams.new()
dryParams.FilterType = Enum.RaycastFilterType.Include
dryParams.IgnoreWater = true
local function solidGroundAt(x, z, groundHeightAt)
	wetParams.FilterDescendantsInstances = { workspace.Terrain }
	dryParams.FilterDescendantsInstances = { workspace.Terrain }
	local from, down = Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0)
	local dry = workspace:Raycast(from, down, dryParams)
	if not dry then
		return nil
	end
	local wet = workspace:Raycast(from, down, wetParams)
	if wet and wet.Material == Enum.Material.Water and wet.Position.Y - dry.Position.Y > WATER_DEPTH then
		return nil
	end
	-- The map's own answer where it has one, so a caller that shapes the ground (roads) still wins.
	local height = groundHeightAt and groundHeightAt(x, z)
	return height or dry.Position.Y
end

local function findSpot(landmark, radius, centers, keepOut, taken, groundHeightAt, space, spacing, chestSpots, lootSpots)
	local footprint = landmark.footprint
	-- Every chest and pickup already on the map (a building's, a plateau's): a landmark never lands on one.
	local occupied = {}
	for _, spot in ipairs(chestSpots or {}) do
		table.insert(occupied, typeof(spot) == "CFrame" and spot.Position or spot)
	end
	for _, list in pairs(lootSpots or {}) do
		for _, spot in ipairs(list) do
			table.insert(occupied, typeof(spot) == "CFrame" and spot.Position or spot)
		end
	end
	-- Pieces that stand their own feet on the ground keep their own tolerance; levelled ones may
	-- take up to LEVEL_TOLERANCE. Of every spot that's clear, the flattest wins.
	local tolerance = landmark.level == false and landmark.flat or math.max(landmark.flat, LEVEL_TOLERANCE)
	local best, bestSpread, bestSteps = nil, math.huge, 1
	for _ = 1, TRIES do
		local angle = rng:NextNumber() * math.pi * 2
		local fraction = landmark.edge and (0.78 + rng:NextNumber() * 0.1) or (0.22 + rng:NextNumber() * 0.56)
		local x, z = math.cos(angle) * radius * fraction, math.sin(angle) * radius * fraction

		local clear = true
		for _, center in ipairs(centers) do
			if Vector2.new(center.X - x, center.Z - z).Magnitude < keepOut + footprint then
				clear = false
				break
			end
		end
		for _, spot in ipairs(taken) do
			if clear and Vector2.new(spot.X - x, spot.Z - z).Magnitude < (spacing or SPACING) then
				clear = false
			end
		end
		if clear then
			local low, high = math.huge, -math.huge
			-- A nil height is the map's own veto (no solid ground there, or water over it): the spot goes.
			for _, sample in ipairs({ { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } }) do
				local height = solidGroundAt(x + sample[1] * footprint, z + sample[2] * footprint, groundHeightAt)
				if not height then
					low, high = math.huge, -math.huge
					break
				end
				low, high = math.min(low, height), math.max(high, height)
			end
			local spread = high - low
			-- The site is levelled to the middle of its own spread, so the ground falls about half of it
			-- away at the pad's edge; the steps that meet it reach further out, and all of that has to be
			-- clear. A flat site claims very little more than it used to.
			local steps = (landmark.level == false) and 1 or terraceSteps(spread / 2 + 1)
			local claim = (landmark.level == false) and (footprint + 10) or (siteRadius(footprint, steps) + 4)
			-- Nobody else's chest or pickup under the site, terrace steps included.
			for _, held in ipairs(occupied) do
				local dx, dz = held.X - x, held.Z - z
				if dx * dx + dz * dz < claim * claim then
					clear = false
					break
				end
			end
			if clear and low < math.huge and spread <= tolerance and spread < bestSpread and space:IsFree(x, z, claim) then
				-- Halfway between the extremes (the site is levelled to it, so a slope is cut into on one
				-- side and filled on the other), then moved to the nearest height whose fill lands on a
				-- voxel boundary -- otherwise the ground renders up to 3 studs above what the landmark
				-- declares as its floor.
				best, bestSpread, bestSteps = Vector3.new(x, padHeight((low + high) / 2), z), spread, steps
				if spread <= landmark.flat then
					break
				end
			end
		end
	end
	return best, bestSpread, bestSteps
end

-- Cuts the site flat: anything above the pad within the footprint is removed, and the pad is
-- filled up to it. `material` is what the pad is made of. The pad's top is the surface lift
-- under `spot.Y`, which puts the ground's surface exactly at `spot.Y` (MapTerrain.SurfaceLift).
local ROUGH_TERRAIN = {
	[Enum.Material.Rock] = true, [Enum.Material.Basalt] = true, [Enum.Material.Ice] = true, [Enum.Material.Slate] = true,
	[Enum.Material.CrackedLava] = true, [Enum.Material.Concrete] = true, [Enum.Material.Brick] = true,
	[Enum.Material.WoodPlanks] = true, [Enum.Material.Cobblestone] = true,
}

local function levelSite(spot, footprint, material, steps)
	local terrain = workspace.Terrain
	local top = spot.Y - MapTerrain.SurfaceLift
	local pad = footprint + 4

	-- The terraces round the pad (Oliver, 2026-09-22 16:00: "there's this ditch around them that looks
	-- bad"). They used to be cylinders stepping DOWN a voxel per ring on every side, each one cutting
	-- away everything above it: on flat ground that dug a 4-stud trench round the whole pad, and on the
	-- uphill side of a slope a trench under a cliff. Now each ring only ever moves the ground TOWARD the
	-- pad: where the natural ground is lower it is filled up in steps (terraces down to it), where it is
	-- higher it is cut down in steps (terraces up to it), and where it is already level with the pad it
	-- is left exactly as it is. Ring heights stay on whole-voxel boundaries, so the steps still render.
	local reach = pad + steps * TERRAIN_STEP_RUN
	local region = Region3.new(
		Vector3.new(spot.X - reach - VOXEL, top - (steps + 2) * VOXEL - 16, spot.Z - reach - VOXEL),
		Vector3.new(spot.X + reach + VOXEL, top + (steps + 2) * VOXEL + 140, spot.Z + reach + VOXEL)):ExpandToGrid(VOXEL)
	local materials, occupancies = terrain:ReadVoxels(region, VOXEL)
	local origin = region.CFrame.Position - region.Size / 2
	local count = region.Size / VOXEL
	local changed = false
	for ix = 1, count.X do
		local x = origin.X + (ix - 0.5) * VOXEL
		for iz = 1, count.Z do
			local z = origin.Z + (iz - 0.5) * VOXEL
			local r = math.sqrt((x - spot.X) ^ 2 + (z - spot.Z) ^ 2)
			if r > pad and r <= reach then
				-- The natural ground's top in this column (fill height, before the surface lift). Water is
				-- left alone: a lake shore beside a landmark keeps its water.
				local ground, water = nil, false
				for iy = count.Y, 1, -1 do
					local was = materials[ix][iy][iz]
					if was == Enum.Material.Water and occupancies[ix][iy][iz] > 0 then
						water = true
					elseif occupancies[ix][iy][iz] > 0 and was ~= Enum.Material.Air then
						ground = origin.Y + (iy - 1) * VOXEL + occupancies[ix][iy][iz] * VOXEL
						break
					end
				end
				if ground and not water then
					local ring = math.ceil((r - pad) / TERRAIN_STEP_RUN)
					local target = math.clamp(ground, top - ring * TERRAIN_STEP_RISE, top + ring * TERRAIN_STEP_RISE)
					if math.abs(target - ground) > 0.05 then
						changed = true
						for iy = 1, count.Y do
							local bottom = origin.Y + (iy - 1) * VOXEL
							local occupancy = math.clamp((target - bottom) / VOXEL, 0, 1)
							occupancies[ix][iy][iz] = occupancy
							if occupancy <= 0 then
								materials[ix][iy][iz] = Enum.Material.Air
							elseif materials[ix][iy][iz] == Enum.Material.Air or bottom + VOXEL > target - VOXEL then
								-- New fill, and the new top face of a cut, are the site's material.
								materials[ix][iy][iz] = material
							end
						end
					end
				end
			end
		end
	end
	if changed then
		terrain:WriteVoxels(region, VOXEL, materials, occupancies)
	end

	terrain:FillCylinder(CFrame.new(spot.X, top + 25, spot.Z), 50, pad, Enum.Material.Air)
	terrain:FillCylinder(CFrame.new(spot.X, top - 8, spot.Z), 16, pad, material)
end

-- Builds this map's landmarks under `parent`, adds their chests and loot to `chestSpots` and
-- `lootSpots`, and returns their centres (for supply drops) and names.
function Landmarks.Place(parent, preset, radius, centers, keepOut, groundHeightAt, space, chestSpots, lootSpots)
	-- The one global roll; everything else here, and in every builder, rolls on `rng`.
	rng = Random.new(math.random(1, 2 ^ 31 - 2))

	local function shuffled(list)
		local copy = table.clone(list)
		for index = #copy, 2, -1 do
			local swap = rng:NextInteger(1, index)
			copy[index], copy[swap] = copy[swap], copy[index]
		end
		return copy
	end

	-- This map's own set in order (its signature pieces, the lighthouse on coasts, then its pool in
	-- a random order), or for a map with no set of its own, anything at all.
	local candidates = {}
	local set = MAP_SETS[preset.id]
	if set then
		for _, id in ipairs(set.always) do
			table.insert(candidates, BY_ID[id])
		end
	end
	if preset.terrainMaterial == Enum.Material.Sand then
		table.insert(candidates, BEACON)
	end
	local poolIds = {}
	if set then
		poolIds = set.pool
	else
		for _, landmark in ipairs(LANDMARKS) do
			table.insert(poolIds, landmark.id)
		end
	end
	for _, id in ipairs(shuffled(poolIds)) do
		table.insert(candidates, BY_ID[id])
	end
	-- Four on every map, the lighthouse on top; a candidate that finds no room is passed over and
	-- the next one in the list gets its turn. Small maps pack them a little closer.
	local want = math.clamp(math.floor(radius / 300), 4, 5) + (preset.terrainMaterial == Enum.Material.Sand and 1 or 0)
	local spacing = math.min(SPACING, radius * 0.33)

	local folder = Instance.new("Model")
	folder.Name = "Landmarks"

	local ctx = { chestSpots = chestSpots, lootSpots = lootSpots, space = space, groundHeightAt = groundHeightAt }
	local placed = {}
	for _, landmark in ipairs(candidates) do
		if #placed >= want then
			break
		end
		local spot, spread, steps = findSpot(landmark, radius, centers, keepOut, placed, groundHeightAt, space, spacing, chestSpots, lootSpots)
		if not spot then
			warn(string.format("[Landmarks] no room for %s on %s this match", landmark.id, preset.id))
		end
		if spot then
			-- The pad, its steps, and a stud or two past them.
			space:AddCircle(spot.X, spot.Z, landmark.level == false and (landmark.footprint + 10) or (siteRadius(landmark.footprint, steps) + 4))
			if landmark.level ~= false then
				-- Rough terrain materials (Rock ±1.1 studs, Basalt ±0.8, Ice ±0.55, Slate, CrackedLava) never lie
				-- flat, and stepped ones (Concrete, Brick, WoodPlanks, Cobblestone) snap their surface, so a natural
				-- pad on such a map is laid in smooth Ground instead.
				local natural = preset.terrainMaterial
				if ROUGH_TERRAIN[natural] then
					natural = Enum.Material.Ground
				end
				levelSite(spot, landmark.footprint, landmark.natural and natural or Enum.Material.Pavement, steps)
			end

			local model = Instance.new("Model")
			model.Name = landmark.id
			-- How far the site's ground varied before levelling: worth knowing when tuning.
			model:SetAttribute("SiteSpread", math.floor(spread * 10 + 0.5) / 10)
			model:SetAttribute("SiteSteps", steps)
			local origin = CFrame.new(spot) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
			local ok, err = pcall(landmark.build, model, origin, ctx)
			if ok then
				-- Whatever of it reaches past the flat pad (a fence post on the first terrace, a pole, a deck
				-- corner, the ruins' stair down its own stairwell) is carried down to the ground under it
				-- rather than left hanging over it (MapTerrain.Underpin; tools/foundation_check.py). A piece
				-- that stands on its own feet is underpinned foot by foot, from each foot's own floor.
				if landmark.level == false then
					for _, foot in ipairs(model:GetChildren()) do
						local footBase = foot:IsA("Model") and foot:GetAttribute("FootingBase")
						if type(footBase) == "number" then
							MapTerrain.Underpin(foot, footBase)
						end
					end
				else
					MapTerrain.Underpin(model, spot.Y)
				end
				-- For the minimap: attributes replicate even while the landmark is streamed out.
				model:SetAttribute("LandmarkCenter", spot)
				model:SetAttribute("LandmarkName", landmark.name)
				-- The footing convention: the pad's height, and a footprint inside the levelled pad, round a
				-- pivot at its centre. A long zipline or a deep chamber would otherwise stretch the bounding
				-- box far past the pad.
				if landmark.level == false then
					-- Stands on its own feet: the audit walks its child pieces, each with its own base.
					model:SetAttribute("FootingGroup", true)
				elseif landmark.level ~= false then
					model.WorldPivot = CFrame.new(spot)
					model:SetAttribute("FootingBase", spot.Y)
					-- A square inside the round pad (radius footprint + 4), four studs clear of its edge: a footing
					-- edge point that fell past the pad would land on the first terrace step, two studs lower, and
					-- read as a floating corner. A piece that digs a hole inside its own site declares its own.
					local side = landmark.footing and (landmark.footing * 2) or ((landmark.footprint + 4) * math.sqrt(2) - 8)
					model:SetAttribute("FootingSize", Vector3.new(side, 0, side))
				end
				model.Parent = folder
				table.insert(placed, { X = spot.X, Y = spot.Y, Z = spot.Z, name = landmark.name, id = landmark.id })
			else
				model:Destroy()
				warn(string.format("[Landmarks] %s failed: %s", landmark.id, tostring(err)))
			end
			task.wait()
		end
	end

	folder.Parent = parent

	local spots = {}
	for _, entry in ipairs(placed) do
		table.insert(spots, Vector3.new(entry.X, entry.Y, entry.Z))
	end
	return spots, placed
end

-- For the build check only: every landmark, the lighthouse included, in a row under `parent`
-- from `origin` stepping `spacing` along X, each on its own levelled pad. The game never calls
-- this; tools/runtest.ps1 does, to audit all of them in one run. Returns the models.
function Landmarks.BuildAll(parent, origin, spacing, groundHeightAt)
	spacing = spacing or 260
	local ctx = {
		chestSpots = {},
		lootSpots = { weapon = {}, heal = {}, item = {} },
		space = MapSpace.new(),
		groundHeightAt = groundHeightAt or function()
			return origin.Y
		end,
	}
	local all = table.clone(LANDMARKS)
	table.insert(all, BEACON)
	local models = {}
	for index, landmark in ipairs(all) do
		local spot = Vector3.new(origin.X + (index - 1) * spacing, origin.Y, origin.Z)
		levelSite(spot, landmark.footprint, Enum.Material.Pavement, 1)
		local model = Instance.new("Model")
		model.Name = landmark.id
		local ok, err = pcall(landmark.build, model, CFrame.new(spot), ctx)
		if ok then
			model.Parent = parent
			table.insert(models, model)
		else
			model:Destroy()
			warn(string.format("[Landmarks] %s failed: %s", landmark.id, tostring(err)))
		end
	end
	return models
end

return Landmarks
