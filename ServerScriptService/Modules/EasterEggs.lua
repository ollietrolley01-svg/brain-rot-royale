-- Easter eggs: silly set pieces hidden out between the towns, plus one parkour obby tower per
-- map.
--
-- Each has an Inspect prompt with a one-liner and a small reward, paid once per player per
-- match. Every piece is an original gag built from primitive parts. Several nod at things that
-- are big on Roblox right now — growing gardens, surviving nights around a campfire, obbies,
-- the "67" meme, the eternal lost guest — without borrowing any other game's characters or
-- branding.
--
-- Motion (flickering flames, a bobbing duck, a spinning snack) is tagged for AmbientClient to
-- animate locally, so the server never replicates a CFrame per frame.

local CollectionService = game:GetService("CollectionService")

local BattlePassService = require(script.Parent:WaitForChild("BattlePassService"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))
local RewardService = require(script.Parent:WaitForChild("RewardService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local EasterEggs = {}

local EGG_COINS = 30
local EGG_XP = 25
local DEFAULT_REACH = 16

-- Minimum distance between two eggs, so they're spread over the map rather than clustered.
local EGG_SPACING = 160

-- UserId -> { [eggKey] = true }. Replaced every map. Keyed by id, not Player: a Player held only
-- by a weak-keyed table can drop out of it while still in the game.
local found = {}

-- How many eggs (obby included) actually made it onto the current map.
local placedCount = 0

--------------------------------------------------------------------------------
-- Building helpers
--------------------------------------------------------------------------------

local function piece(parent, size, cframe, color, material, shape)
	local part = Instance.new("Part")
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

-- A block with a sphere mesh, so it can be squashed — Ball parts are forced round.
local function sphere(parent, size, cframe, color, material)
	local part = piece(parent, size, cframe, color, material)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

local function decor(part)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

local function bob(part, height, speed, phase)
	part:SetAttribute("BobHeight", height)
	part:SetAttribute("BobSpeed", speed)
	part:SetAttribute("BobPhase", phase or 0)
	CollectionService:AddTag(part, "AmbientBob")
	return part
end

local function spin(part, degreesPerSecond)
	part:SetAttribute("SpinSpeed", degreesPerSecond)
	CollectionService:AddTag(part, "AmbientSpin")
	return part
end

-- A group of pieces that sways together.
--
-- AmbientBob is a CLIENT animation: the server's copy never moves. A SOLID part that sways
-- therefore leaves its collision box and its raycast box behind at the rest position — you walk
-- into an invisible wall a quarter of a stud from where the thing looks, and a shot at it passes
-- through the part you can see and hits nothing. So the swaying pieces become decoration, and one
-- invisible box at the rest position does the colliding and takes the shots. It's built from the
-- group's own extents, so it fits whatever the egg is.
local function sway(model, parts, height, speed, phase)
	local low, high = nil, nil
	for _, part in ipairs(parts) do
		local frame, size = part.CFrame, part.Size
		local reach = Vector3.new(
			math.abs(frame.RightVector.X) * size.X + math.abs(frame.UpVector.X) * size.Y + math.abs(frame.LookVector.X) * size.Z,
			math.abs(frame.RightVector.Y) * size.X + math.abs(frame.UpVector.Y) * size.Y + math.abs(frame.LookVector.Y) * size.Z,
			math.abs(frame.RightVector.Z) * size.X + math.abs(frame.UpVector.Z) * size.Y + math.abs(frame.LookVector.Z) * size.Z
		) / 2
		low = low and low:Min(part.Position - reach) or (part.Position - reach)
		high = high and high:Max(part.Position + reach) or (part.Position + reach)
		decor(part)
		bob(part, height, speed, phase)
	end
	if not low then
		return nil
	end
	local hull = Instance.new("Part")
	hull.Name = "SwayHull"
	hull.Size = high - low
	hull.CFrame = CFrame.new((low + high) / 2)
	hull.Anchored = true
	hull.Transparency = 1
	hull.CanCollide = true
	hull.CanQuery = true
	hull.CanTouch = false
	hull.CastShadow = false
	hull.Parent = model
	return hull
end

-- Text on a board. With `background`, the text sits on a lit panel (a screen, a sign face).
local function sign(part, text, textColor, background, faces)
	for _, face in ipairs(faces or { Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = background and 0 or 0.3
		gui.MaxDistance = 200

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = background or Color3.new()
		label.BackgroundTransparency = background and 0 or 1
		label.BorderSizePixel = 0
		label.Font = Enum.Font.FredokaOne
		label.Text = text
		label.TextColor3 = textColor
		label.TextScaled = true
		label.TextStrokeTransparency = 0.6
		label.Parent = gui

		gui.Parent = part
	end
end

local function light(part, color, range, brightness)
	local pointLight = Instance.new("PointLight")
	pointLight.Color = color
	pointLight.Range = range
	pointLight.Brightness = brightness
	pointLight.Parent = part
end

-- A limb segment: a block `thick` square running from `from` to `to`, so an arm is built joint to
-- joint and can never stop in mid-air. Pair it with `joint` balls at each end, a little wider than
-- the block's diagonal, which hide the square ends whatever angle the next segment leaves at.
local function limb(model, from, to, thick, color, material)
	local direction = to - from
	local up = math.abs(direction.Unit.Y) > 0.99 and Vector3.zAxis or Vector3.yAxis
	local frame = CFrame.lookAt((from + to) / 2, to, up) * CFrame.Angles(-math.pi / 2, 0, 0)
	return decor(piece(model, Vector3.new(thick, direction.Magnitude, thick), frame, color, material))
end

local function joint(model, at, diameter, color, material)
	return decor(piece(model, Vector3.new(diameter, diameter, diameter), CFrame.new(at), color, material, Enum.PartType.Ball))
end

-- The game's cartoon eyes on a head whose front is -Z: a white, a pupil looking out of it and a
-- glint, mirrored about the centre line. `at` is the head's frame, the offsets are in it.
local function cartoonEyes(model, at, spacing, y, z, size)
	local white = Color3.fromRGB(246, 246, 250)
	for _, side in ipairs({ -1, 1 }) do
		decor(sphere(model, Vector3.new(size, size * 1.1, size * 0.85), at * CFrame.new(side * spacing, y, z), white))
		decor(sphere(model, Vector3.new(size * 0.5, size * 0.55, size * 0.4), at * CFrame.new(side * spacing, y - size * 0.12, z - size * 0.3),
			Color3.fromRGB(28, 28, 36)))
		decor(piece(model, Vector3.new(size * 0.18, size * 0.18, size * 0.18), at * CFrame.new(side * spacing + side * size * 0.1, y + size * 0.08, z - size * 0.5),
			white, nil, Enum.PartType.Ball))
	end
end

--------------------------------------------------------------------------------
-- The eggs. Each builder fills `model` around `origin` (ground level, random yaw) and returns
-- the part the Inspect prompt hangs on.
--------------------------------------------------------------------------------

local BUTTERFLIES = { Color3.fromRGB(255, 150, 200), Color3.fromRGB(150, 210, 255), Color3.fromRGB(255, 226, 90) }

-- Garden-growing is everywhere on Roblox. This one got out of hand.
local function giantCarrot(model, origin)
	local plank = Color3.fromRGB(128, 92, 58)
	local leaf = Color3.fromRGB(70, 150, 62)
	local orange = Color3.fromRGB(242, 128, 34)

	piece(model, Vector3.new(30, 1, 22), origin * CFrame.new(0, 0.5, 0), Color3.fromRGB(92, 64, 42), Enum.Material.Ground)
	for _, edge in ipairs({
		{ Vector3.new(31, 1.6, 1), CFrame.new(0, 0.8, 11.5) },
		{ Vector3.new(31, 1.6, 1), CFrame.new(0, 0.8, -11.5) },
		{ Vector3.new(1, 1.6, 22), CFrame.new(15.5, 0.8, 0) },
		{ Vector3.new(1, 1.6, 22), CFrame.new(-15.5, 0.8, 0) },
	}) do
		piece(model, edge[1], origin * edge[2], plank, Enum.Material.WoodPlanks)
	end

	-- Rows of ordinary sprouts, with a gap in the middle for the one that didn't stop.
	for row = -1, 1 do
		for col = -3, 3 do
			if row ~= 0 or math.abs(col) > 1 then
				decor(piece(model, Vector3.new(1.4, 1.4, 1.4), origin * CFrame.new(col * 3.8, 1.5, row * 6.5),
					leaf, Enum.Material.Grass, Enum.PartType.Ball))
			end
		end
	end

	column(model, 3, 4.5, origin * CFrame.new(0, 2.5, 0), orange)
	local body = column(model, 4, 6.5, origin * CFrame.new(0, 6, 0), orange)
	column(model, 1.6, 7, origin * CFrame.new(0, 8.8, 0), orange)
	for index = 1, 3 do
		local yaw = index / 3 * math.pi * 2
		-- Each leaf on its own phase, so the top rustles rather than bouncing as one lump.
		bob(decor(piece(model, Vector3.new(1.2, 7, 1.2),
			origin * CFrame.new(0, 9.6, 0) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(22), 0, 0) * CFrame.new(0, 3.5, 0),
			leaf, Enum.Material.Grass)), 0.18, 1.3, index * 1.9)
	end
	-- #42: growth rings round the root, a shade darker and a tenth proud, so it reads as a carrot and
	-- not as three orange drums stacked up.
	local ringTone = orange:Lerp(Color3.new(0, 0, 0), 0.18)
	for _, ring in ipairs({ { 2.6, 4.7 }, { 4.6, 6.7 }, { 5.8, 6.7 }, { 7.0, 6.7 } }) do
		decor(column(model, 0.3, ring[2], origin * CFrame.new(0, ring[1], 0), ringTone))
	end

	-- Somebody watered it anyway. The can lies on its side where it was dropped (a cylinder's length is
	-- its X axis, so an unturned one already lies down), with the puddle it left and a shovel that
	-- was clearly not up to the job. Parts are sized so no two faces share a plane.
	local can = origin * CFrame.new(5.7, 1.9, -3.3) * CFrame.Angles(0, math.rad(25), 0)
	local canTone = Color3.fromRGB(70, 132, 96)
	decor(piece(model, Vector3.new(2.2, 1.8, 1.8), can, canTone, Enum.Material.Metal, Enum.PartType.Cylinder))
	decor(piece(model, Vector3.new(0.3, 0.3, 2.0), can * CFrame.new(0.6, 0, -1.7), canTone, Enum.Material.Metal))
	decor(sphere(model, Vector3.new(0.7, 0.7, 0.4), can * CFrame.new(0.6, 0, -2.75), canTone:Lerp(Color3.new(1, 1, 1), 0.2), Enum.Material.Metal))
	decor(piece(model, Vector3.new(1.4, 0.25, 0.25), can * CFrame.new(0, 1.25, 0), canTone, Enum.Material.Metal))
	for _, x in ipairs({ -0.5, 0.5 }) do
		decor(piece(model, Vector3.new(0.25, 0.5, 0.16), can * CFrame.new(x, 1.0, 0), canTone, Enum.Material.Metal))
	end
	local puddle = decor(column(model, 0.06, 4.5, origin * CFrame.new(5.2, 1.03, -5.4), Color3.fromRGB(110, 170, 220), Enum.Material.Glass))
	puddle.Transparency = 0.35
	local shovel = origin * CFrame.new(-13.2, 0, 3.2) * CFrame.Angles(0, 0, math.rad(12))
	decor(piece(model, Vector3.new(1.4, 1.8, 0.2), shovel * CFrame.new(0, 1.1, 0), Color3.fromRGB(150, 154, 160), Enum.Material.Metal))
	decor(piece(model, Vector3.new(0.3, 4.6, 0.3), shovel * CFrame.new(0, 4.3, 0), plank, Enum.Material.Wood))
	decor(piece(model, Vector3.new(1.2, 0.3, 0.36), shovel * CFrame.new(0, 6.6, 0), plank, Enum.Material.Wood))

	-- Butterflies over the sprouts: the one thing in the bed that isn't a vegetable.
	for index, spot in ipairs({ Vector3.new(-6, 3.4, 5), Vector3.new(5, 4.2, 6.5), Vector3.new(-3, 3.8, -6) }) do
		local wings = decor(piece(model, Vector3.new(0.7, 0.1, 0.5), origin * CFrame.new(spot) * CFrame.Angles(0, index * 1.3, 0),
			BUTTERFLIES[index], Enum.Material.Neon))
		bob(wings, 0.6, 1.8 + index * 0.35, index * 1.1)
	end

	piece(model, Vector3.new(0.5, 6, 0.5), origin * CFrame.new(11, 3, -9), plank, Enum.Material.Wood)
	local board = piece(model, Vector3.new(7, 3, 0.4), origin * CFrame.new(11, 6.2, -9),
		Color3.fromRGB(236, 226, 200), Enum.Material.WoodPlanks)
	sign(board, "DO NOT WATER", Color3.fromRGB(150, 40, 30))

	return body
end

-- Surviving night after night out in the woods is another big one.
local function survivalCamp(model, origin)
	local stone = Color3.fromRGB(120, 118, 112)
	local wood = Color3.fromRGB(104, 72, 46)

	for index = 1, 9 do
		local angle = index / 9 * math.pi * 2
		piece(model, Vector3.new(1.6, 1.6, 1.6), origin * CFrame.new(math.cos(angle) * 3.6, 0.6, math.sin(angle) * 3.6),
			stone, Enum.Material.Slate, Enum.PartType.Ball)
	end

	local logs
	for index = 0, 2 do
		logs = piece(model, Vector3.new(5, 0.9, 0.9), origin * CFrame.new(0, 0.7, 0) * CFrame.Angles(0, index * math.pi / 3, 0),
			wood, Enum.Material.Wood, Enum.PartType.Cylinder)
	end

	local flameColors = { Color3.fromRGB(255, 120, 30), Color3.fromRGB(255, 190, 50), Color3.fromRGB(255, 240, 170) }
	local flameSizes = { 2.2, 1.4, 0.8 }
	for index = 1, 3 do
		local size = flameSizes[index]
		local flame = decor(piece(model, Vector3.new(size, size * 1.3, size),
			origin * CFrame.new(0, 1.4 + index * 0.9, 0) * CFrame.Angles(0, index * 0.7, 0),
			flameColors[index], Enum.Material.Neon))
		bob(flame, 0.18, 9 + index * 2, index)
	end

	local fire = Instance.new("Fire")
	fire.Size = 4
	fire.Heat = 7
	fire.Parent = logs
	light(logs, Color3.fromRGB(255, 150, 60), 28, 2.2)

	-- Log seats, each laid along the ring rather than pointing into the fire.
	for index = 1, 3 do
		local angle = index / 3 * math.pi * 2 + 0.5
		piece(model, Vector3.new(6, 1.8, 1.8),
			origin * CFrame.new(math.cos(angle) * 8, 0.9, math.sin(angle) * 8) * CFrame.Angles(0, -angle - math.pi / 2, 0),
			wood, Enum.Material.Wood, Enum.PartType.Cylinder)
	end

	-- A tripod over the fire with a pot hanging off it, which is what a camp is missing without.
	for index = 0, 2 do
		local angle = index / 3 * math.pi * 2
		piece(model, Vector3.new(0.4, 7.5, 0.4),
			origin * CFrame.new(math.cos(angle) * 2.2, 3.6, math.sin(angle) * 2.2) * CFrame.Angles(0, -angle, math.rad(17)),
			wood, Enum.Material.Wood)
	end
	-- The pot hangs clear of the flames' tops, and its chain runs from the rim up to the tripod's
	-- apex. (Its base used to lie in the plane of the top flame's base: z-fighting.)
	decor(piece(model, Vector3.new(0.12, 1.15, 0.12), origin * CFrame.new(0, 6.725, 0), Color3.fromRGB(60, 58, 56), Enum.Material.Metal))
	local pot = piece(model, Vector3.new(2.6, 2, 2.6), origin * CFrame.new(0, 5.2, 0), Color3.fromRGB(48, 48, 52), Enum.Material.Metal)
	decor(piece(model, Vector3.new(2.9, 0.3, 2.9), origin * CFrame.new(0, 6.1, 0), Color3.fromRGB(70, 70, 76), Enum.Material.Metal))
	bob(decor(pot), 0.1, 1.1, 0)

	-- A-frame tent, with a door flap open on the fire side, a ridge pole and pegged guy ropes. At 12.4
	-- rather than 14, so the back pegs stay inside the 19-stud site (they reached 20.6).
	local canvas = Color3.fromRGB(96, 120, 76)
	local tentZ = 12.4
	for _, side in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(6, 0.3, 8), origin * CFrame.new(side * 1.93, 2.3, tentZ) * CFrame.Angles(0, 0, -side * math.rad(50)),
			canvas, Enum.Material.Fabric)
	end
	piece(model, Vector3.new(0.4, 0.4, 8.4), origin * CFrame.new(0, 4.5, tentZ), wood, Enum.Material.Wood)
	piece(model, Vector3.new(5.6, 0.25, 4.4), origin * CFrame.new(-1.1, 2.6, tentZ - 3.7) * CFrame.Angles(math.rad(-24), math.rad(-14), math.rad(-46)),
		canvas:Lerp(Color3.new(0, 0, 0), 0.12), Enum.Material.Fabric)
	decor(piece(model, Vector3.new(4.6, 0.3, 5.6), origin * CFrame.new(0, 0.22, tentZ), Color3.fromRGB(150, 128, 92), Enum.Material.Fabric))
	decor(sphere(model, Vector3.new(4, 1.6, 5), origin * CFrame.new(0, 0.9, tentZ + 1.4), Color3.fromRGB(180, 76, 68), Enum.Material.Fabric))
	for _, corner in ipairs({ { -1, 1 }, { 1, 1 }, { -1, -1 }, { 1, -1 } }) do
		local pegAt = Vector3.new(corner[1] * 5.6, 0.35, tentZ + corner[2] * 5.4)
		local ridgeAt = Vector3.new(corner[1] * 2.1, 4.3, tentZ + corner[2] * 4.1)
		decor(piece(model, Vector3.new(0.25, 1.3, 0.25),
			origin * CFrame.new(pegAt) * CFrame.Angles(math.rad(corner[2] * -18), 0, math.rad(corner[1] * 18)), wood, Enum.Material.Wood))
		decor(piece(model, Vector3.new(0.1, 0.1, (ridgeAt - pegAt).Magnitude),
			origin * CFrame.lookAt((pegAt + ridgeAt) / 2, ridgeAt), Color3.fromRGB(216, 208, 180), Enum.Material.Fabric))
	end

	-- Firewood, and an axe left in the chopping block.
	for index = 0, 3 do
		decor(piece(model, Vector3.new(4.4, 0.8, 0.8), origin * CFrame.new(7.5, 0.5 + index % 2 * 0.85, -7 + math.floor(index / 2) * 0.9)
			* CFrame.Angles(0, math.rad(8 - index * 5), 0), wood, Enum.Material.Wood, Enum.PartType.Cylinder))
	end
	local block = column(model, 2.2, 3, origin * CFrame.new(11, 1.1, -3), Color3.fromRGB(122, 90, 62), Enum.Material.Wood)
	decor(piece(model, Vector3.new(0.3, 3.4, 0.3), origin * CFrame.new(11, 3.4, -3) * CFrame.Angles(math.rad(24), 0, 0),
		Color3.fromRGB(96, 70, 44), Enum.Material.Wood))
	decor(piece(model, Vector3.new(0.5, 1.4, 1.9), origin * CFrame.new(11, 4.8, -2.3) * CFrame.Angles(math.rad(24), 0, 0),
		Color3.fromRGB(180, 184, 192), Enum.Material.Metal))

	piece(model, Vector3.new(0.5, 5, 0.5), origin * CFrame.new(-9, 2.5, 6), wood, Enum.Material.Wood)
	local board = piece(model, Vector3.new(6, 2.6, 0.3), origin * CFrame.new(-9, 5.2, 6),
		Color3.fromRGB(200, 184, 150), Enum.Material.WoodPlanks)
	sign(board, "NIGHTS SURVIVED: 97", Color3.fromRGB(60, 40, 30))
	-- A lantern hung off an arm that reaches out past the board's end, so the camp has a second light
	-- at its edge. (It used to hang half inside the board, its top in the plane of the arm's.)
	decor(piece(model, Vector3.new(2.2, 0.16, 0.16), origin * CFrame.new(-5.3, 6.6, 6), Color3.fromRGB(60, 58, 56), Enum.Material.Metal))
	local lantern = piece(model, Vector3.new(1.1, 1.5, 1.1), origin * CFrame.new(-4.9, 5.8, 6), Color3.fromRGB(255, 226, 150), Enum.Material.Neon)
	decor(lantern)
	light(lantern, Color3.fromRGB(255, 214, 150), 16, 1.2)
	bob(lantern, 0.12, 1.4, 1.2)
	-- Tally scratches on a plank of their own under the count: five bundles of five, then two, because
	-- 97 is a lot of nights. Marks, strikes and plank are three different depths, so no two faces share
	-- a plane (they used to: every strike z-fought the four marks it crossed).
	local tallyTone = Color3.fromRGB(70, 48, 36)
	piece(model, Vector3.new(5.8, 0.9, 0.24), origin * CFrame.new(-9, 3.35, 6), Color3.fromRGB(186, 168, 132), Enum.Material.WoodPlanks)
	for index = 0, 4 do
		for mark = 0, 3 do
			decor(piece(model, Vector3.new(0.1, 0.6, 0.36), origin * CFrame.new(-11.6 + index * 1.05 + mark * 0.2, 3.35, 6), tallyTone))
		end
		decor(piece(model, Vector3.new(1, 0.1, 0.44), origin * CFrame.new(-11.3 + index * 1.05, 3.35, 6)
			* CFrame.Angles(0, 0, math.rad(22)), tallyTone))
	end
	for mark = 0, 1 do
		decor(piece(model, Vector3.new(0.1, 0.6, 0.36), origin * CFrame.new(-6.5 + mark * 0.2, 3.35, 6), tallyTone))
	end

	return logs
end

-- A statue for everyone who has ever spawned in with no idea what's going on.
local function lostGuest(model, origin)
	local stone = Color3.fromRGB(196, 196, 190)

	piece(model, Vector3.new(9, 3, 9), origin * CFrame.new(0, 1.5, 0), Color3.fromRGB(110, 108, 104), Enum.Material.Concrete)
	piece(model, Vector3.new(7, 1, 7), origin * CFrame.new(0, 3.5, 0), Color3.fromRGB(130, 128, 122), Enum.Material.Concrete)

	-- The plinth gets a moulding and a plaque, so it reads as a monument rather than two slabs.
	decor(piece(model, Vector3.new(9.6, 0.5, 9.6), origin * CFrame.new(0, 3.05, 0), Color3.fromRGB(142, 140, 134), Enum.Material.Concrete))
	local plaque = piece(model, Vector3.new(5, 1.6, 0.5), origin * CFrame.new(0, 2, -4.4), Color3.fromRGB(180, 150, 90), Enum.Material.Metal)
	sign(plaque, "STILL LOOKING", Color3.fromRGB(60, 46, 20), nil, { Enum.NormalId.Front })

	for _, x in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(1.9, 4, 1.9), origin * CFrame.new(x, 6, 0), stone, Enum.Material.Marble)
		piece(model, Vector3.new(1.9, 4, 1.9), origin * CFrame.new(x * 2.95, 10, 0), stone, Enum.Material.Marble)
		-- Shoes, and a hand shading the eyes on one side while the other holds the strap.
		decor(piece(model, Vector3.new(2.1, 0.8, 3), origin * CFrame.new(x, 4.35, -0.5), stone:Lerp(Color3.new(0, 0, 0), 0.18),
			Enum.Material.Marble))
		decor(piece(model, Vector3.new(1.7, 1.7, 1.7), origin * CFrame.new(x * 2.95, 8.1, 0), stone, Enum.Material.Marble))
	end
	local torso = piece(model, Vector3.new(4, 4, 2), origin * CFrame.new(0, 10, 0), stone, Enum.Material.Marble)
	decor(piece(model, Vector3.new(4.2, 1, 2.2), origin * CFrame.new(0, 11.7, 0), stone:Lerp(Color3.new(1, 1, 1), 0.2), Enum.Material.Marble))
	decor(piece(model, Vector3.new(1.4, 1.4, 1.4), origin * CFrame.new(0, 12.1, 0), stone, Enum.Material.Marble))
	local head = piece(model, Vector3.new(2.6, 2.6, 2.6), origin * CFrame.new(0, 13.3, 0), stone, Enum.Material.Marble)
	sign(head, "?", Color3.fromRGB(60, 60, 70), nil, { Enum.NormalId.Front })
	-- A backpack, dropped where the guest gave up, and a pigeon that has made the head its own.
	decor(piece(model, Vector3.new(2.6, 3, 1.6), origin * CFrame.new(-3.6, 5, 2.6) * CFrame.Angles(0, math.rad(22), math.rad(-14)),
		Color3.fromRGB(96, 104, 120), Enum.Material.Fabric))
	decor(piece(model, Vector3.new(2.8, 0.5, 1.8), origin * CFrame.new(-3.6, 6.2, 2.6) * CFrame.Angles(0, math.rad(22), math.rad(-14)),
		Color3.fromRGB(70, 78, 96), Enum.Material.Fabric))
	local pigeon = sphere(model, Vector3.new(1.3, 1.1, 1.9), origin * CFrame.new(0.7, 15.1, 0.3), Color3.fromRGB(120, 126, 140))
	decor(pigeon)
	bob(pigeon, 0.1, 1.6, 0.4)
	decor(sphere(model, Vector3.new(0.8, 0.8, 0.8), origin * CFrame.new(0.7, 15.7, -0.5), Color3.fromRGB(132, 138, 152)))
	decor(piece(model, Vector3.new(0.5, 0.2, 0.2), origin * CFrame.new(0.7, 15.65, -1.05), Color3.fromRGB(230, 160, 60)))

	-- The post stands in the moulding (it used to stop 0.7 above it) and behind the board rather than
	-- through it, so the two no longer share their front and back faces.
	piece(model, Vector3.new(0.4, 9.8, 0.4), origin * CFrame.new(4.6, 8.1, -0.85), Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
	local board = piece(model, Vector3.new(6, 3, 0.4), origin * CFrame.new(4.6, 13.5, -1.2),
		Color3.fromRGB(240, 236, 220), Enum.Material.WoodPlanks)
	sign(board, "where is my spawn??", Color3.fromRGB(40, 40, 50))

	return torso
end

-- 5x7 pixel glyphs for the 67 sign.
local DIGITS = {
	["6"] = { ".###.", "#....", "#....", "####.", "#...#", "#...#", ".###." },
	["7"] = { "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..." },
}

-- #42. This used to be a scoreboard on two poles: the digits and nothing else to look at. Now it is
-- a monument: a stepped plinth with a plaque, the board framed, lit so it carries at night, and in
-- front of it the joke itself, a pair of big cartoon gloves on pedestals weighing the air out of
-- step with each other. The whole thing stays inside the 14-stud footprint it always had.
local function sixSeven(model, origin)
	local pixel = 2.2
	local lime = Color3.fromRGB(150, 255, 90)
	local dark = Color3.fromRGB(26, 28, 34)
	local metal = Color3.fromRGB(60, 60, 66)
	local stone = Color3.fromRGB(150, 148, 142)
	local glove = Color3.fromRGB(246, 246, 250)
	-- Two studs higher than it was, so the gloves in front never cover the digits from head height.
	local boardY = 18

	-- The plinth: two steps, the lower one wide enough to carry the pedestals out front.
	piece(model, Vector3.new(24, 1.2, 11), origin * CFrame.new(0, 0.6, -1.5), stone:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.Concrete)
	piece(model, Vector3.new(22, 0.8, 9), origin * CFrame.new(0, 1.6, -1.5), stone, Enum.Material.Concrete)
	local plaque = decor(piece(model, Vector3.new(8, 0.9, 0.3), origin * CFrame.new(0, 0.6, -7.1), Color3.fromRGB(180, 150, 90), Enum.Material.Metal))
	sign(plaque, "SIX SEVEN", Color3.fromRGB(60, 46, 20), nil, { Enum.NormalId.Front })

	for _, x in ipairs({ -10, 10 }) do
		piece(model, Vector3.new(1.4, boardY - 1.8, 1.4), origin * CFrame.new(x, 1.8 + (boardY - 1.8) / 2, 0.6), metal, Enum.Material.Metal)
	end
	local board = piece(model, Vector3.new(27.6, 19, 1), origin * CFrame.new(0, boardY, 0), dark)
	light(board, lime, 22, 1.3)
	-- The frame stands proud of the board front and back. Top and bottom rails run a fifth past the
	-- board's ends (the board lost that much width to keep the frame inside the footprint); the side
	-- rails stop inside them, a tenth in from the board's edge and a fifth shallower, so no rail
	-- shares a face with another or with the board.
	for _, y in ipairs({ boardY - 9.5, boardY + 9.5 }) do
		piece(model, Vector3.new(28, 1, 1.8), origin * CFrame.new(0, y, -0.2), metal, Enum.Material.Metal)
	end
	for _, x in ipairs({ -13.45, 13.45 }) do
		piece(model, Vector3.new(0.9, 18.8, 1.6), origin * CFrame.new(x, boardY, -0.2), metal, Enum.Material.Metal)
	end

	for digitIndex, digit in ipairs({ "6", "7" }) do
		local offsetX = (digitIndex == 1 and -1 or 1) * 6.6
		for row, line in ipairs(DIGITS[digit]) do
			for col = 1, 5 do
				if line:sub(col, col) == "#" then
					decor(piece(model, Vector3.new(pixel - 0.2, pixel - 0.2, 0.6),
						origin * CFrame.new(offsetX + (col - 3) * pixel, boardY + (4 - row) * pixel, -0.7),
						lime, Enum.Material.Neon))
				end
			end
		end
	end

	-- The gloves, palms up, one over each pedestal. Each sways as a unit (see `sway`) and the two are
	-- half a beat apart, so one rises as the other drops. At rest a glove's cuff hangs 1.35 over its
	-- pedestal's cap and it bobs 0.8, so it never dips into it.
	for _, side in ipairs({ -1, 1 }) do
		local x = side * 6
		column(model, 1.6, 2.6, origin * CFrame.new(x, 2.8, -3.5), stone, Enum.Material.Concrete)
		decor(column(model, 0.35, 2.9, origin * CFrame.new(x, 3.675, -3.5), lime, Enum.Material.Neon))

		local hand = origin * CFrame.new(x, 6.75, -3.5)
		local parts = {
			piece(model, Vector3.new(3.4, 1, 3), hand, glove),
		}
		for index, fx in ipairs({ -1.2, -0.4, 0.4, 1.2 }) do
			-- Fingers curl up a little, the middle two longest, so the palm reads as a cupped hand.
			local reach = (index == 2 or index == 3) and 2.1 or 1.8
			table.insert(parts, piece(model, Vector3.new(0.72, 0.8, reach), hand * CFrame.new(fx, 0.12, -1.5 - reach / 2 + 0.35) * CFrame.Angles(math.rad(16), 0, 0),
				glove))
		end
		table.insert(parts, piece(model, Vector3.new(0.8, 0.8, 1.7), hand * CFrame.new(-side * 1.9, 0.2, -0.6) * CFrame.Angles(math.rad(10), side * math.rad(35), 0), glove))
		-- The cuff, a round collar at the wrist, clearly wider than the palm is thick.
		table.insert(parts, piece(model, Vector3.new(1.1, 3.1, 3.1), hand * CFrame.new(0, 0, 1.95) * CFrame.Angles(0, math.pi / 2, 0),
			glove:Lerp(Color3.new(0, 0, 0), 0.08), nil, Enum.PartType.Cylinder))
		local hull = sway(model, parts, 0.8, 2.4, side == 1 and math.pi or 0)
		if hull then
			hull:SetAttribute("IntentionalFloat", true)
		end
		for _, part in ipairs(parts) do
			part:SetAttribute("IntentionalFloat", true)
		end
	end

	return board
end

-- Touching grass, but comfortably.
local function livingRoom(model, origin)
	local fabric = Color3.fromRGB(64, 150, 150)
	local wood = Color3.fromRGB(120, 84, 54)

	decor(piece(model, Vector3.new(18, 0.2, 14), origin * CFrame.new(0, 0.1, 0), Color3.fromRGB(150, 44, 52), Enum.Material.Fabric))

	piece(model, Vector3.new(10, 2, 4), origin * CFrame.new(0, 1.2, 4), fabric, Enum.Material.Fabric)
	-- The back runs into the arms rather than ending in the plane of the seat's ends.
	piece(model, Vector3.new(10.4, 3.2, 1.2), origin * CFrame.new(0, 3.2, 5.6), fabric, Enum.Material.Fabric)
	for _, x in ipairs({ -5.4, 5.4 }) do
		piece(model, Vector3.new(1.2, 2.8, 4.6), origin * CFrame.new(x, 1.6, 4.3), fabric, Enum.Material.Fabric)
	end
	for _, x in ipairs({ -2.5, 2.5 }) do
		piece(model, Vector3.new(4.6, 0.8, 3.4), origin * CFrame.new(x, 2.6, 3.8), fabric:Lerp(Color3.new(1, 1, 1), 0.15), Enum.Material.Fabric)
	end

	piece(model, Vector3.new(5, 0.5, 2.6), origin * CFrame.new(0, 1.9, -0.5), wood, Enum.Material.Wood)
	for _, x in ipairs({ -2.2, 2.2 }) do
		for _, z in ipairs({ -1.6, 0.6 }) do
			piece(model, Vector3.new(0.4, 1.6, 0.4), origin * CFrame.new(x, 0.9, z), wood, Enum.Material.Wood)
		end
	end
	decor(piece(model, Vector3.new(0.8, 0.3, 0.5), origin * CFrame.new(1, 2.3, -0.4), Color3.fromRGB(30, 30, 34)))

	-- A proper boxy set on its stand: deep case, a screen sunk into the front, and an aerial.
	piece(model, Vector3.new(8, 2.4, 2.4), origin * CFrame.new(0, 1.3, -6), wood, Enum.Material.WoodPlanks)
	decor(piece(model, Vector3.new(8.4, 0.5, 2.8), origin * CFrame.new(0, 2.45, -6), wood:Lerp(Color3.new(0, 0, 0), 0.2), Enum.Material.Wood))
	piece(model, Vector3.new(8, 5.6, 3.2), origin * CFrame.new(0, 5.5, -6.6), Color3.fromRGB(216, 208, 190), Enum.Material.Plastic)
	local tv = piece(model, Vector3.new(6.6, 4.4, 0.4), origin * CFrame.new(0, 5.6, -5.1), Color3.fromRGB(20, 20, 24))
	-- The couch is on the +Z side, so the screen is the Back face.
	sign(tv, "LOADING BRAINROT... 99%", Color3.fromRGB(140, 255, 200), Color3.fromRGB(16, 30, 60), { Enum.NormalId.Back })
	for _, x in ipairs({ -2.4, 2.4 }) do
		decor(piece(model, Vector3.new(0.5, 0.5, 0.5), origin * CFrame.new(x, 2.9, -5.2), Color3.fromRGB(80, 80, 88), Enum.Material.Metal,
			Enum.PartType.Ball))
	end
	decor(piece(model, Vector3.new(0.16, 4.4, 0.16), origin * CFrame.new(-2, 10.4, -6.6) * CFrame.Angles(math.rad(-18), 0, math.rad(-22)),
		Color3.fromRGB(150, 154, 162), Enum.Material.Metal))
	decor(piece(model, Vector3.new(0.16, 4.4, 0.16), origin * CFrame.new(2, 10.4, -6.6) * CFrame.Angles(math.rad(-18), 0, math.rad(22)),
		Color3.fromRGB(150, 154, 162), Enum.Material.Metal))

	-- A shelf of books, a mug on the table and a cat asleep on the cushion: the room reads lived-in.
	piece(model, Vector3.new(4.4, 0.4, 2), origin * CFrame.new(-8.4, 3.3, -1.5), wood, Enum.Material.Wood)
	piece(model, Vector3.new(4.4, 0.4, 2), origin * CFrame.new(-8.4, 1.4, -1.5), wood, Enum.Material.Wood)
	for _, x in ipairs({ -10.5, -6.3 }) do
		piece(model, Vector3.new(0.4, 3.6, 2), origin * CFrame.new(x, 1.8, -1.5), wood, Enum.Material.Wood)
	end
	local spines = { Color3.fromRGB(180, 76, 68), Color3.fromRGB(70, 110, 170), Color3.fromRGB(210, 170, 70),
		Color3.fromRGB(90, 140, 90), Color3.fromRGB(150, 90, 160) }
	for index = 0, 7 do
		local tall = 1.1 + (index % 3) * 0.2
		decor(piece(model, Vector3.new(0.45, tall, 1.5), origin * CFrame.new(-10.1 + index * 0.55, 1.52 + tall / 2 + 0.2 * (index % 2), -1.5)
			* CFrame.Angles(0, 0, math.rad(index % 4 == 3 and 12 or 0)),
			spines[index % #spines + 1], Enum.Material.Fabric))
	end
	local mug = decor(column(model, 0.7, 0.8, origin * CFrame.new(-1.4, 2.42, -0.4), Color3.fromRGB(240, 240, 244)))
	decor(piece(model, Vector3.new(0.12, 0.5, 0.5), origin * CFrame.new(-1.95, 2.42, -0.4), Color3.fromRGB(240, 240, 244)))
	decor(column(model, 0.08, 0.66, origin * CFrame.new(-1.4, 2.73, -0.4), Color3.fromRGB(96, 64, 40)))
	local cat = decor(sphere(model, Vector3.new(2.2, 1.4, 3), origin * CFrame.new(2.5, 3.3, 3.8), Color3.fromRGB(80, 78, 86), Enum.Material.Fabric))
	bob(cat, 0.06, 0.9, 0)
	decor(sphere(model, Vector3.new(1.3, 1.2, 1.3), origin * CFrame.new(2.5, 3.6, 2.5), Color3.fromRGB(80, 78, 86), Enum.Material.Fabric))
	for _, ear in ipairs({ -0.4, 0.4 }) do
		decor(piece(model, Vector3.new(0.5, 0.5, 0.2), origin * CFrame.new(2.5 + ear, 4.2, 2.5), Color3.fromRGB(80, 78, 86), Enum.Material.Fabric))
	end
	decor(mug)

	column(model, 6, 0.4, origin * CFrame.new(7, 3, 5), Color3.fromRGB(60, 60, 64), Enum.Material.Metal)
	local shade = decor(column(model, 1.8, 2.6, origin * CFrame.new(7, 6.6, 5), Color3.fromRGB(250, 236, 200), Enum.Material.Neon))
	light(shade, Color3.fromRGB(255, 226, 170), 18, 1.5)

	return tv
end

local MAGNETS = { Color3.fromRGB(230, 70, 70), Color3.fromRGB(70, 150, 240), Color3.fromRGB(250, 200, 60),
	Color3.fromRGB(90, 200, 110), Color3.fromRGB(200, 110, 220) }

local function fridgehenge(model, origin)
	local white = Color3.fromRGB(236, 238, 240)
	local count, radius = 7, 12
	local positions = {}

	for index = 1, count do
		local angle = index / count * math.pi * 2
		local position = Vector3.new(math.cos(angle) * radius, 4.5, math.sin(angle) * radius)
		positions[index] = position

		-- Doors face the altar.
		local fridge = piece(model, Vector3.new(4, 9, 3.4), origin * CFrame.lookAt(position, Vector3.new(0, 4.5, 0)), white)
		-- Handle, door seam and magnets at different depths off the door, so none shares a face.
		decor(piece(model, Vector3.new(0.3, 3, 0.3), fridge.CFrame * CFrame.new(1.4, 1, -1.8), Color3.fromRGB(170, 176, 184), Enum.Material.Metal))
		decor(piece(model, Vector3.new(3.9, 0.1, 0.1), fridge.CFrame * CFrame.new(0, 2.2, -1.76), Color3.fromRGB(150, 154, 160)))
		-- #42: every fridge has magnets. These ones are offerings.
		for m, spot in ipairs({ { -1.1, 0.3 }, { -0.3, -0.5 }, { 0.5, 0.4 }, { -0.7, -1.5 } }) do
			decor(piece(model, Vector3.new(0.5, 0.5, 0.12), fridge.CFrame * CFrame.new(spot[1], spot[2], -1.76),
				MAGNETS[(index + m) % #MAGNETS + 1]))
		end
	end

	for _, pair in ipairs({ { 1, 2 }, { 3, 4 }, { 5, 6 } }) do
		local a, b = positions[pair[1]], positions[pair[2]]
		local raise = Vector3.new(0, 5, 0)
		piece(model, Vector3.new(3.4, 1.4, (b - a).Magnitude + 3), origin * CFrame.lookAt((a + b) / 2 + raise, b + raise), white)
	end

	local altar = piece(model, Vector3.new(5, 3, 4), origin * CFrame.new(0, 1.5, 0), Color3.fromRGB(100, 98, 94), Enum.Material.Slate)
	light(altar, Color3.fromRGB(200, 230, 255), 20, 1.6)

	-- The sacred sandwich, hovering and slowly turning.
	for _, layer in ipairs({
		{ Vector3.new(3, 0.5, 3), 3.85, Color3.fromRGB(222, 184, 120) },
		{ Vector3.new(3.3, 0.2, 3.3), 4.2, Color3.fromRGB(96, 190, 70) },
		{ Vector3.new(3.1, 0.2, 3.1), 4.4, Color3.fromRGB(255, 200, 60) },
		{ Vector3.new(3, 0.5, 3), 4.75, Color3.fromRGB(222, 184, 120) },
	}) do
		spin(decor(piece(model, layer[1], origin * CFrame.new(0, layer[2], 0), layer[3])), 40)
	end
	-- Four candles on the altar's corners, clear of the turning sandwich (its corners sweep 2.33 from
	-- the middle; these stand 2.5 out), each with a flickering flame.
	for index, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		decor(column(model, 0.9, 0.4, origin * CFrame.new(corner[1] * 2.2, 3.45, corner[2] * 1.6), Color3.fromRGB(246, 240, 222)))
		local flame = decor(piece(model, Vector3.new(0.22, 0.4, 0.22), origin * CFrame.new(corner[1] * 2.2, 4.12, corner[2] * 1.6),
			Color3.fromRGB(255, 190, 80), Enum.Material.Neon))
		bob(flame, 0.05, 8 + index, index)
	end

	return altar
end

local function normalGuy(model, origin)
	local yellow = Color3.fromRGB(250, 222, 80)
	local coat = Color3.fromRGB(176, 140, 96)
	local hat = Color3.fromRGB(60, 44, 34)
	local black = Color3.fromRGB(20, 20, 24)

	local parts = {
		column(model, 4, 3.4, origin * CFrame.new(0, 2, 0), yellow),
		column(model, 4, 3.3, origin * CFrame.new(0.3, 5.6, 0), yellow),
		column(model, 3.6, 3, origin * CFrame.new(0.45, 9.2, 0), yellow),
		column(model, 3, 2.6, origin * CFrame.new(0.3, 12.3, 0), yellow),
		column(model, 1, 1, origin * CFrame.new(0.05, 14.3, 0), Color3.fromRGB(96, 70, 40)),
		piece(model, Vector3.new(5, 1, 4.6), origin * CFrame.new(0.3, 10.2, 0), coat:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.Fabric),
		piece(model, Vector3.new(4.8, 0.6, 4.4), origin * CFrame.new(0.3, 6.5, 0), Color3.fromRGB(70, 50, 34), Enum.Material.Fabric),
		piece(model, Vector3.new(3, 0.6, 0.3), origin * CFrame.new(0.3, 12.6, -1.4), black),
		column(model, 0.3, 4.8, origin * CFrame.new(0.3, 13.9, 0), hat, Enum.Material.Fabric),
		column(model, 1.8, 3, origin * CFrame.new(0.3, 14.9, 0), hat, Enum.Material.Fabric),
		column(model, 0.4, 3.06, origin * CFrame.new(0.3, 14.3, 0), black, Enum.Material.Fabric),
	}
	local body = piece(model, Vector3.new(4.6, 7, 4.2), origin * CFrame.new(0.3, 6.5, 0), coat, Enum.Material.Fabric)
	table.insert(parts, body)

	-- Same phase on every piece, so he sways as one very normal unit, and one invisible box does
	-- the colliding: swaying parts are moved on the client only, so solid ones left their collision
	-- behind (see `sway`).
	sway(model, parts, 0.25, 1.4, 0)

	return body
end

local function bigSqueak(model, origin)
	-- A pond, and a sand shoal under the duck. Water is not ground to a raycast, so over the pond
	-- the duck had nothing solid under it at all; the shoal's top sits a third of a stud under the
	-- surface, so it still reads as a duck sitting in water.
	workspace.Terrain:FillCylinder(origin * CFrame.new(0, -1.5, 0), 3, 20, Enum.Material.Water)
	workspace.Terrain:FillCylinder(origin * CFrame.new(0, -2.35 - MapTerrain.SurfaceLift, 0), 4, 12, Enum.Material.Sand)

	local yellow = Color3.fromRGB(255, 212, 50)
	local shadeYellow = Color3.fromRGB(226, 178, 34)
	local body = sphere(model, Vector3.new(14, 9, 18), origin * CFrame.new(0, 2, 0), yellow)
	local head = piece(model, Vector3.new(9, 9, 9), origin * CFrame.new(0, 8.5, -5.5), yellow, nil, Enum.PartType.Ball)
	local parts = {
		body,
		head,
		-- The bill: an upper and a lower, with a nostril, instead of one flat slab.
		piece(model, Vector3.new(4.2, 1.5, 4.4), origin * CFrame.new(0, 8.1, -10.7), Color3.fromRGB(255, 140, 34)),
		piece(model, Vector3.new(3.4, 0.9, 3.4), origin * CFrame.new(0, 7.2, -10.3), Color3.fromRGB(226, 108, 24)),
		sphere(model, Vector3.new(0.7, 0.5, 0.7), origin * CFrame.new(-0.9, 8.7, -12.2), Color3.fromRGB(196, 92, 20)),
		sphere(model, Vector3.new(0.7, 0.5, 0.7), origin * CFrame.new(0.9, 8.7, -12.2), Color3.fromRGB(196, 92, 20)),
		-- Tail, and a wing tucked along each flank.
		piece(model, Vector3.new(4, 4, 4), origin * CFrame.new(0, 4.5, 8.4) * CFrame.Angles(math.rad(35), 0, 0), yellow),
		sphere(model, Vector3.new(1.6, 5, 8), origin * CFrame.new(-6.1, 2.6, 0.6), shadeYellow),
		sphere(model, Vector3.new(1.6, 5, 8), origin * CFrame.new(6.1, 2.6, 0.6), shadeYellow),
		-- A moulded seam round the hull, the giveaway that it is a bath toy the size of a bus.
		sphere(model, Vector3.new(14.3, 1, 18.3), origin * CFrame.new(0, 1.2, 0), shadeYellow),
	}
	for _, x in ipairs({ -2, 2 }) do
		table.insert(parts, piece(model, Vector3.new(1.3, 1.3, 1.3), origin * CFrame.new(x, 10, -9.4),
			Color3.fromRGB(20, 20, 24), nil, Enum.PartType.Ball))
		-- A glint, so the eyes read as eyes from the path rather than as two dark dots.
		table.insert(parts, sphere(model, Vector3.new(0.5, 0.5, 0.4), origin * CFrame.new(x - 0.25, 10.35, -10.05),
			Color3.fromRGB(245, 245, 250)))
		table.insert(parts, sphere(model, Vector3.new(2.6, 0.5, 2.6), origin * CFrame.new(x * 1.6, 10.9, -8.9),
			Color3.fromRGB(255, 226, 120)))
	end
	sway(model, parts, 0.45, 1.6, 0)

	-- Ripples spreading off the hull, and reeds standing in the shallows.
	-- Inside the 22-stud site: the outer ring used to reach 23.
	for index, ring in ipairs({ { 13, 0.35 }, { 16.5, 0.28 }, { 20, 0.2 } }) do
		local ripple = decor(column(model, 0.2, ring[1] * 2, origin * CFrame.new(0, 0.05 + index * 0.11, 0),
			Color3.fromRGB(180, 226, 240), Enum.Material.Glass))
		ripple.Transparency = 1 - ring[2]
		bob(ripple, 0.12, 1.1 + index * 0.2, index * 0.7)
	end

	for index = 1, 10 do
		local angle = index / 10 * math.pi * 2 + math.random() * 0.3
		local distance = 18.5 + math.random() * 2
		decor(column(model, 4 + math.random() * 2, 0.3, origin * CFrame.new(math.cos(angle) * distance, 2, math.sin(angle) * distance),
			Color3.fromRGB(90, 130, 60), Enum.Material.Grass))
	end

	return body
end

local RAINBOW = {
	Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 150, 40), Color3.fromRGB(255, 226, 60),
	Color3.fromRGB(90, 230, 110), Color3.fromRGB(60, 210, 240), Color3.fromRGB(80, 120, 255),
	Color3.fromRGB(190, 90, 255),
}

-- A classic Roblox obby: neon steps spiralling up a pole to a trophy. Each step rises 4 studs
-- with a 3-stud gap — well inside a default jump — and the rainbow is visible across the map.
local function obbyTower(model, origin)
	-- No ledge-climbing on it: a climb up the pole or step to step would skip the obby.
	model:SetAttribute("NoMantle", true)
	local steps, rise, radius, stepAngle = 14, 4, 11, math.rad(48)
	local topY = 1 + (steps + 1) * rise

	piece(model, Vector3.new(22, 1, 22), origin * CFrame.new(0, 0.5, 0), Color3.fromRGB(46, 48, 58), Enum.Material.DiamondPlate)

	local poleHeight = topY - 1.5
	column(model, poleHeight, 2.4, origin * CFrame.new(0, 1 + poleHeight / 2, 0), Color3.fromRGB(70, 72, 84), Enum.Material.Metal)

	for index = 1, steps do
		local angle = index * stepAngle
		local step = piece(model, Vector3.new(6, 1, 6),
			origin * CFrame.new(math.cos(angle) * radius, 1 + index * rise - 0.5, math.sin(angle) * radius) * CFrame.Angles(0, -angle, 0),
			RAINBOW[(index - 1) % #RAINBOW + 1], Enum.Material.Neon)
		-- The step number on its top face, so a climber can see how far is left, and a bracket back
		-- to the pole so the steps read as a staircase rather than as floating tiles.
		sign(step, tostring(index), Color3.fromRGB(20, 20, 26), nil, { Enum.NormalId.Top })
		decor(piece(model, Vector3.new(0.6, 0.6, radius - 2.4),
			origin * CFrame.new(math.cos(angle) * radius / 2, 1 + index * rise - 0.8, math.sin(angle) * radius / 2)
				* CFrame.Angles(0, -angle + math.pi / 2, 0),
			Color3.fromRGB(70, 72, 84), Enum.Material.Metal))
	end

	local top = piece(model, Vector3.new(14, 1, 14), origin * CFrame.new(0, topY - 0.5, 0), Color3.fromRGB(255, 196, 64), Enum.Material.Foil)
	light(top, Color3.fromRGB(255, 210, 110), 30, 2)
	-- Confetti hanging over the trophy platform, for whoever actually gets up here.
	for index = 0, 11 do
		local angle = index / 12 * math.pi * 2
		local drop = decor(piece(model, Vector3.new(0.5, 0.5, 0.12),
			origin * CFrame.new(math.cos(angle) * 5.4, topY + 2 + (index % 4) * 1.1, math.sin(angle) * 5.4) * CFrame.Angles(0, -angle, 0),
			RAINBOW[index % #RAINBOW + 1], Enum.Material.Neon))
		bob(drop, 0.5, 1.6 + (index % 3) * 0.4, index * 0.5)
	end

	local gold = Color3.fromRGB(255, 200, 60)
	column(model, 1, 4, origin * CFrame.new(0, topY + 0.5, 0), Color3.fromRGB(50, 40, 30), Enum.Material.Wood)
	local stem = column(model, 2, 0.9, origin * CFrame.new(0, topY + 2, 0), gold, Enum.Material.Foil)
	for _, part in ipairs({
		sphere(model, Vector3.new(3.6, 3.2, 3.6), origin * CFrame.new(0, topY + 4.4, 0), gold, Enum.Material.Foil),
		column(model, 0.4, 3.8, origin * CFrame.new(0, topY + 5.9, 0), gold, Enum.Material.Foil),
		piece(model, Vector3.new(0.5, 2, 0.5), origin * CFrame.new(-2.1, topY + 4.6, 0), gold, Enum.Material.Foil),
		piece(model, Vector3.new(0.5, 2, 0.5), origin * CFrame.new(2.1, topY + 4.6, 0), gold, Enum.Material.Foil),
	}) do
		bob(decor(part), 0.3, 2.2, 0)
	end

	-- Posts at the board's ends, thicker than it, so the board is framed rather than sharing their faces.
	for _, x in ipairs({ -5.1, 5.1 }) do
		piece(model, Vector3.new(0.6, 5, 0.6), origin * CFrame.new(x, 3.5, -11.6), Color3.fromRGB(40, 40, 48), Enum.Material.Metal)
	end
	local board = piece(model, Vector3.new(10, 2.6, 0.5), origin * CFrame.new(0, 5, -11.6), Color3.fromRGB(26, 24, 34))
	sign(board, "OBBY OF ROT - CLIMB!", Color3.fromRGB(255, 226, 60), Color3.fromRGB(26, 24, 34))

	return stem
end

-- A house, a patrol car outside it, and a heavy-set figure in a red sweater being walked to the
-- car by two officers. Read from a distance it is a silhouette — house behind, car in front, three
-- figures between them — so the pose carries it: the sweater leans back on his heels, hands cuffed
-- behind, an officer on each arm, and he is sweating buckets. Our own character and our own force;
-- the joke is the sweater, not a person. Built to the 0.07 rule: nothing sits flush with anything,
-- trim stands a clear tenth proud, and every limb runs joint to joint so no arm ends in mid-air.
local function sweaterArrest(model, origin)
	local cream = Color3.fromRGB(226, 216, 196)
	local trim = Color3.fromRGB(96, 72, 56)
	local roofTone = Color3.fromRGB(86, 62, 56)
	local navy = Color3.fromRGB(30, 46, 92)
	local squad = Color3.fromRGB(238, 240, 244)
	local skin = Color3.fromRGB(236, 196, 160)
	local red = Color3.fromRGB(196, 46, 44)
	local black = Color3.fromRGB(20, 20, 24)
	local brass = Color3.fromRGB(226, 194, 90)
	local glass = Color3.fromRGB(110, 150, 190)

	-- The house, set back behind the scene and facing the street: walls 18 by 13, 9 high.
	local W, D, H = 18, 13, 9
	local house = origin * CFrame.new(0, 0, 15)
	piece(model, Vector3.new(W, H, D), house * CFrame.new(0, H / 2, 0), cream, Enum.Material.Concrete)

	-- The roof. The attic is two wedges back to back, so the gable ends are solid and the slopes
	-- meet at a real ridge. (The old roof was two slabs each cut to reach past the centre line: they
	-- crossed there and splayed, the cap sat below their tops, and the ends were open.) Slate slabs
	-- lie on the slopes and overhang the walls, and a cap covers the seam at the top.
	local RISE = 5.4
	local pitch = math.atan(RISE / (W / 2))
	for _, side in ipairs({ -1, 1 }) do
		local wedge = Instance.new("WedgePart")
		wedge.Name = "Attic"
		wedge.Size = Vector3.new(D, RISE, W / 2)
		-- A wedge's high edge is its +Z side: turned so that side stands on the ridge plane and the
		-- slope runs down to the eave.
		wedge.CFrame = house * CFrame.new(side * W / 4, H + RISE / 2, 0) * CFrame.Angles(0, -side * math.pi / 2, 0)
		wedge.Color = cream
		wedge.Material = Enum.Material.Concrete
		wedge.Anchored = true
		wedge.TopSurface = Enum.SurfaceType.Smooth
		wedge.BottomSurface = Enum.SurfaceType.Smooth
		wedge.Parent = model
		-- The slab runs from 0.6 short of the ridge (the cap covers the rest) to 1.3 past the wall,
		-- its underside on the wedge.
		local inner, outer = 0.6, W / 2 + 1.3
		local midX = (inner + outer) / 2
		local normal = Vector3.new(side * math.sin(pitch), math.cos(pitch), 0)
		local centre = Vector3.new(side * midX, H + RISE - midX * math.tan(pitch), 0) + normal * 0.25
		piece(model, Vector3.new((outer - inner) / math.cos(pitch), 0.5, D + 2.4), house * CFrame.new(centre) * CFrame.Angles(0, 0, -side * pitch),
			roofTone, Enum.Material.Slate)
	end
	piece(model, Vector3.new(2.2, 0.8, D + 2.6), house * CFrame.new(0, H + RISE + 0.2, 0), roofTone:Lerp(Color3.new(0, 0, 0), 0.25), Enum.Material.Slate)
	-- A chimney through the right slope, with a cap, a pot and smoke drifting off it.
	piece(model, Vector3.new(2.2, 7.6, 2.2), house * CFrame.new(5.4, 11.8, 2.5), Color3.fromRGB(150, 96, 84), Enum.Material.Brick)
	decor(piece(model, Vector3.new(2.6, 0.5, 2.6), house * CFrame.new(5.4, 15.85, 2.5), Color3.fromRGB(120, 76, 68), Enum.Material.Brick))
	decor(piece(model, Vector3.new(0.9, 0.9, 0.9), house * CFrame.new(5.4, 16.55, 2.5), Color3.fromRGB(96, 60, 54), Enum.Material.Concrete))
	for index, puff in ipairs({ { 1.2, 17.8, 0.1 }, { 1.7, 19.0, 0.5 }, { 2.2, 20.4, 1.1 } }) do
		local smoke = decor(sphere(model, Vector3.new(puff[1], puff[1] * 0.85, puff[1]), house * CFrame.new(5.4 + puff[3], puff[2], 2.5 - puff[3] * 0.4),
			Color3.fromRGB(200, 200, 206), Enum.Material.SmoothPlastic))
		smoke.Transparency = 0.25 + index * 0.12
		bob(smoke, 0.35, 0.9 + index * 0.2, index * 0.8)
	end

	-- The front: a door in a frame with a step, a mat, a lamp and a canopy; two windows with frames,
	-- glass, a cross bar, a sill and shutters; and the house number. Everything on the wall stands a
	-- clear tenth proud of whatever is behind it.
	local F = -D / 2
	piece(model, Vector3.new(3.9, 6.0, 0.8), house * CFrame.new(0, 3.0, F), trim, Enum.Material.Wood)
	piece(model, Vector3.new(3.2, 5.5, 0.5), house * CFrame.new(0, 2.75, F - 0.25), trim:Lerp(Color3.new(1, 1, 1), 0.18), Enum.Material.WoodPlanks)
	decor(piece(model, Vector3.new(0.45, 0.45, 0.45), house * CFrame.new(1.1, 2.9, F - 0.65), brass, Enum.Material.Metal, Enum.PartType.Ball))
	piece(model, Vector3.new(5.2, 0.9, 2.6), house * CFrame.new(0, 0.45, F - 1.8), Color3.fromRGB(176, 172, 164), Enum.Material.Concrete)
	decor(piece(model, Vector3.new(2.2, 0.2, 1.4), house * CFrame.new(0, 0.1, F - 3.85), Color3.fromRGB(118, 72, 50), Enum.Material.Fabric))
	piece(model, Vector3.new(4.8, 0.35, 2.4), house * CFrame.new(0, 6.175, F - 1.1), trim, Enum.Material.Wood)
	local porch = decor(piece(model, Vector3.new(0.6, 0.6, 0.6), house * CFrame.new(0, 6.0, F - 1.6), Color3.fromRGB(255, 232, 170), Enum.Material.Neon))
	light(porch, Color3.fromRGB(255, 226, 170), 14, 1.1)
	local number = decor(piece(model, Vector3.new(1.1, 1.1, 0.3), house * CFrame.new(0, 7.0, F - 0.15), Color3.fromRGB(40, 40, 48), Enum.Material.Metal))
	sign(number, "67", brass, nil, { Enum.NormalId.Front })
	for _, cx in ipairs({ -5.6, 5.6 }) do
		local cy = 4.6
		for _, bar in ipairs({
			{ Vector3.new(3.4, 0.4, 0.5), Vector3.new(cx, cy + 1.6, F - 0.05) },
			{ Vector3.new(3.4, 0.4, 0.5), Vector3.new(cx, cy - 1.6, F - 0.05) },
			{ Vector3.new(0.4, 2.8, 0.5), Vector3.new(cx - 1.5, cy, F - 0.05) },
			{ Vector3.new(0.4, 2.8, 0.5), Vector3.new(cx + 1.5, cy, F - 0.05) },
		}) do
			piece(model, bar[1], house * CFrame.new(bar[2]), trim, Enum.Material.Wood)
		end
		local pane = piece(model, Vector3.new(2.6, 2.8, 0.3), house * CFrame.new(cx, cy, F + 0.05), glass, Enum.Material.Glass)
		pane.Transparency = 0.3
		-- The cross bar stands in front of the glass rather than into it (it used to reach 0.05 into
		-- the pane, sharing the pane's top, bottom and end faces), and the rail sits a clear 0.06
		-- behind the upright's back so the two never share a face where they cross.
		decor(piece(model, Vector3.new(0.24, 2.8, 0.4), house * CFrame.new(cx, cy, F - 0.3), trim, Enum.Material.Wood))
		decor(piece(model, Vector3.new(2.6, 0.24, 0.2), house * CFrame.new(cx, cy, F - 0.26), trim, Enum.Material.Wood))
		piece(model, Vector3.new(3.8, 0.4, 0.9), house * CFrame.new(cx, cy - 2.0, F - 0.2), cream:Lerp(Color3.new(0, 0, 0), 0.25), Enum.Material.Concrete)
		for _, side in ipairs({ -1, 1 }) do
			decor(piece(model, Vector3.new(0.8, 3.2, 0.35), house * CFrame.new(cx + side * 2.15, cy, F - 0.225), Color3.fromRGB(60, 90, 110), Enum.Material.Wood))
		end
	end

	-- A patch of street, so the car makes sense wherever the map drops the scene.
	-- 34 long (it was 38), so its far corners stay on the levelled site.
	piece(model, Vector3.new(34, 0.6, 10), origin * CFrame.new(0, 0.12, -13), Color3.fromRGB(68, 68, 72), Enum.Material.Asphalt)
	decor(piece(model, Vector3.new(30, 0.12, 0.5), origin * CFrame.new(0, 0.44, -13), Color3.fromRGB(226, 220, 190), Enum.Material.SmoothPlastic))

	-- The patrol car, pulled up at an angle on the street with its near door swung open. Its front
	-- is +X, and its frame's origin is the street's surface, so it stands on its wheels.
	local carAt = origin * CFrame.new(3, 0.42, -12) * CFrame.Angles(0, math.rad(-18), 0)
	piece(model, Vector3.new(12, 2, 5), carAt * CFrame.new(0, 1.9, 0), squad)
	piece(model, Vector3.new(11.4, 0.7, 5.2), carAt * CFrame.new(0, 2.35, 0), navy)
	piece(model, Vector3.new(6.4, 2.3, 4.6), carAt * CFrame.new(-0.4, 3.8, 0), squad)
	decor(piece(model, Vector3.new(6.7, 1.5, 4.9), carAt * CFrame.new(-0.4, 4, 0), Color3.fromRGB(120, 160, 190), Enum.Material.Glass))
	-- Light bar: blocks, not cylinders, so there is nothing round to shimmer against the roof.
	decor(piece(model, Vector3.new(4.4, 0.55, 1.6), carAt * CFrame.new(-0.4, 5.1, 0), Color3.fromRGB(40, 40, 46)))
	for _, bar in ipairs({ { -1.2, Color3.fromRGB(255, 60, 60) }, { 1.2, Color3.fromRGB(70, 110, 255) } }) do
		local lamp = decor(piece(model, Vector3.new(1.9, 0.7, 1.4), carAt * CFrame.new(-0.4 + bar[1], 5.725, 0), bar[2], Enum.Material.Neon))
		light(lamp, bar[2], 16, 1.4)
	end
	-- Wheels, axle across the car (the old ones had the cylinder axis upright: pucks lying flat a
	-- third of a stud off the ground). Tyre and hub radii a clear stud apart and the hub ends a tenth
	-- proud, so neither a curved nor a flat pair shares a surface.
	for _, wheel in ipairs({ { -3.8, 2.6 }, { -3.8, -2.6 }, { 3.8, 2.6 }, { 3.8, -2.6 } }) do
		local hubAt = carAt * CFrame.new(wheel[1], 1.4, wheel[2]) * CFrame.Angles(0, math.pi / 2, 0)
		piece(model, Vector3.new(1.1, 2.8, 2.8), hubAt, Color3.fromRGB(32, 32, 36), Enum.Material.Rubber, Enum.PartType.Cylinder)
		decor(piece(model, Vector3.new(1.3, 1, 1), hubAt, Color3.fromRGB(180, 184, 192), Enum.Material.Metal, Enum.PartType.Cylinder))
	end
	local door = piece(model, Vector3.new(4.4, 2.6, 0.4), carAt * CFrame.new(-0.6, 2.4, -3.4) * CFrame.Angles(0, math.rad(-58), 0), squad)
	decor(piece(model, Vector3.new(4.2, 0.6, 0.6), door.CFrame * CFrame.new(0, -0.05, 0), navy))
	-- The window stops a clear 0.055 above the stripe and under the door's top: it used to overlap
	-- the stripe, and the two, both 0.6 deep, shared their front and back faces there.
	decor(piece(model, Vector3.new(2.2, 0.95, 0.6), door.CFrame * CFrame.new(0.3, 0.78, 0), Color3.fromRGB(120, 160, 190), Enum.Material.Glass))
	-- Bumpers, lights, grille, plates, mirrors and an aerial.
	for _, endX in ipairs({ -1, 1 }) do
		piece(model, Vector3.new(0.6, 0.7, 5.4), carAt * CFrame.new(endX * 6.2, 1.5, 0), Color3.fromRGB(60, 60, 66), Enum.Material.Metal)
		for _, z in ipairs({ -1.6, 1.6 }) do
			decor(piece(model, Vector3.new(0.3, 0.6, 1.0), carAt * CFrame.new(endX * 6.1, 2.3, z),
				endX == 1 and Color3.fromRGB(255, 240, 200) or Color3.fromRGB(230, 40, 40), Enum.Material.Neon))
		end
		local plate = decor(piece(model, Vector3.new(0.2, 0.6, 1.6), carAt * CFrame.new(endX * 6.6, 1.5, 0), navy))
		sign(plate, "ROT 1", squad, nil, { endX == 1 and Enum.NormalId.Right or Enum.NormalId.Left })
	end
	decor(piece(model, Vector3.new(0.3, 0.5, 2.0), carAt * CFrame.new(6.1, 2.3, 0), Color3.fromRGB(30, 30, 34)))
	for _, sideZ in ipairs({ -1, 1 }) do
		decor(piece(model, Vector3.new(0.5, 0.5, 0.6), carAt * CFrame.new(2.4, 3.9, sideZ * 2.6), squad))
		local panel = piece(model, Vector3.new(4.0, 1.3, 0.4), carAt * CFrame.new(0, 2.15, sideZ * 2.55), squad)
		sign(panel, "ROT PATROL", navy, nil, { sideZ == 1 and Enum.NormalId.Back or Enum.NormalId.Front })
	end
	decor(piece(model, Vector3.new(0.2, 1.6, 0.2), carAt * CFrame.new(-2.8, 5.75, 1.6), Color3.fromRGB(40, 40, 46), Enum.Material.Metal))

	-- The sweater's frame: leaning back on his heels (top toward the house), feet on the ground.
	local lean = origin * CFrame.new(0, 0, 0.6) * CFrame.Angles(math.rad(9), 0, 0)

	-- An officer: navy uniform, belt, badge, tie, cap. `side` is the way to the sweater. The near
	-- arm is built shoulder, elbow, hand to `gripAt`, so it holds him rather than pointing at him;
	-- the far arm hangs, or holds a radio up if `radio`.
	local function officer(x, z, yaw, side, gripAt, elbowBow, radio)
		local at = origin * CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
		for _, leg in ipairs({ -0.7, 0.7 }) do
			piece(model, Vector3.new(1, 3.2, 1), at * CFrame.new(leg, 1.6, 0), Color3.fromRGB(26, 30, 44), Enum.Material.Fabric)
			decor(piece(model, Vector3.new(1.2, 0.5, 1.7), at * CFrame.new(leg, 0.25, -0.25), black))
		end
		local torso = piece(model, Vector3.new(2.8, 3.4, 1.7), at * CFrame.new(0, 4.9, 0), navy, Enum.Material.Fabric)
		-- The belt hangs 0.07 below the torso's bottom rather than level with it.
		decor(piece(model, Vector3.new(3.0, 0.5, 1.9), at * CFrame.new(0, 3.38, 0), Color3.fromRGB(18, 18, 22), Enum.Material.Fabric))
		decor(piece(model, Vector3.new(0.5, 0.36, 0.2), at * CFrame.new(0, 3.38, -1.05), brass, Enum.Material.Metal))
		decor(piece(model, Vector3.new(0.5, 0.9, 0.7), at * CFrame.new(-side * 1.75, 3.3, 0.2), black))
		decor(piece(model, Vector3.new(0.6, 0.7, 0.2), at * CFrame.new(-0.8, 5.6, -0.95), brass, Enum.Material.Metal))
		decor(piece(model, Vector3.new(0.5, 1.7, 0.2), at * CFrame.new(0.1, 5.5, -0.95), Color3.fromRGB(16, 20, 34), Enum.Material.Fabric))
		for _, s in ipairs({ -1, 1 }) do
			decor(piece(model, Vector3.new(0.8, 0.35, 1.9), at * CFrame.new(s * 1.1, 6.7, 0), navy:Lerp(Color3.new(0, 0, 0), 0.3), Enum.Material.Fabric))
		end
		-- Head and cap: a crown, a band a tenth proud of it and up off its bottom edge, a peak a tenth
		-- narrower than the crown, a badge.
		local head = at * CFrame.new(0, 7.3, 0)
		decor(sphere(model, Vector3.new(1.9, 1.9, 1.9), head, skin))
		decor(piece(model, Vector3.new(2.2, 0.8, 2.2), at * CFrame.new(0, 8.35, 0), navy, Enum.Material.Fabric))
		decor(piece(model, Vector3.new(2.4, 0.28, 2.4), at * CFrame.new(0, 8.19, 0), black, Enum.Material.Fabric))
		decor(piece(model, Vector3.new(2.0, 0.25, 1.1), at * CFrame.new(0, 7.98, -1.35), black, Enum.Material.Fabric))
		decor(piece(model, Vector3.new(0.5, 0.4, 0.2), at * CFrame.new(0, 8.5, -1.3), brass, Enum.Material.Metal))
		if radio then
			-- Sunglasses with a bridge, and a flat mouth.
			for _, s in ipairs({ -1, 1 }) do
				decor(piece(model, Vector3.new(0.72, 0.5, 0.2), head * CFrame.new(s * 0.4, 0.12, -0.95), black, Enum.Material.SmoothPlastic))
			end
			-- The bridge sits 0.08 behind the lenses' fronts (it was 0.02, and shimmered).
			decor(piece(model, Vector3.new(0.3, 0.2, 0.2), head * CFrame.new(0, 0.12, -0.87), black, Enum.Material.SmoothPlastic))
			decor(piece(model, Vector3.new(0.7, 0.2, 0.2), head * CFrame.new(0, -0.4, -0.92), Color3.fromRGB(120, 66, 62)))
		else
			cartoonEyes(model, head, 0.36, 0.1, -0.82, 0.62)
			decor(piece(model, Vector3.new(1.1, 0.28, 0.24), head * CFrame.new(0, -0.45, -0.9), Color3.fromRGB(70, 48, 36)))
		end
		-- Arms, joint to joint.
		local shoulderIn = at * Vector3.new(side * 1.55, 6.35, 0)
		local shoulderOut = at * Vector3.new(-side * 1.55, 6.35, 0)
		joint(model, shoulderIn, 1.3, navy, Enum.Material.Fabric)
		joint(model, shoulderOut, 1.3, navy, Enum.Material.Fabric)
		local elbowIn = shoulderIn:Lerp(gripAt, 0.5) + origin:VectorToWorldSpace(elbowBow)
		limb(model, shoulderIn, elbowIn, 0.9, navy, Enum.Material.Fabric)
		joint(model, elbowIn, 1.3, navy, Enum.Material.Fabric)
		limb(model, elbowIn, gripAt, 0.85, navy, Enum.Material.Fabric)
		joint(model, gripAt, 1.25, skin)
		local elbowOut = at * Vector3.new(-side * 1.8, 4.85, 0.15)
		local handOut = at * Vector3.new(-side * 1.95, 3.35, 0.4)
		if radio then
			elbowOut = at * Vector3.new(-side * 2.0, 4.9, -0.5)
			handOut = at * Vector3.new(-side * 1.15, 6.6, -1.45)
			decor(piece(model, Vector3.new(0.5, 1.0, 0.36), at * CFrame.new(-side * 1.05, 7.2, -1.55), black))
		end
		limb(model, shoulderOut, elbowOut, 0.9, navy, Enum.Material.Fabric)
		joint(model, elbowOut, 1.3, navy, Enum.Material.Fabric)
		limb(model, elbowOut, handOut, 0.85, navy, Enum.Material.Fabric)
		joint(model, handOut, 1.25, skin)
		return torso
	end
	-- Each officer stands clear of the sweater's arms (they used to overlap them) and holds an elbow.
	officer(-5.8, 0.2, math.rad(14), 1, lean * Vector3.new(-4.2, 4.5, 1.5), Vector3.new(-0.6, -0.3, -0.3), false)
	officer(5.8, 0.2, math.rad(-14), -1, lean * Vector3.new(4.2, 4.5, 1.5), Vector3.new(0.6, -0.3, -0.3), true)

	-- The sweater: heavy-set, hands cuffed behind him, chin down, sweating. The game's own cartoon
	-- eyes, so he reads as one of ours rather than as anybody in particular.
	for _, leg in ipairs({ -1.1, 1.1 }) do
		-- The leg starts a tenth up inside the shoe, so the two soles are not one face (the lean lifts
		-- the toes clear of the grass, where that face shows).
		piece(model, Vector3.new(1.5, 2.5, 1.5), lean * CFrame.new(leg, 1.35, 0), Color3.fromRGB(70, 74, 88), Enum.Material.Fabric)
		decor(piece(model, Vector3.new(1.7, 0.6, 2.4), lean * CFrame.new(leg, 0.3, -0.4), Color3.fromRGB(40, 38, 44)))
	end
	local belly = sphere(model, Vector3.new(6, 4.6, 4.4), lean * CFrame.new(0, 4.6, 0), red, Enum.Material.Fabric)
	decor(sphere(model, Vector3.new(5.2, 1.6, 4.2), lean * CFrame.new(0, 2.5, 0), red:Lerp(Color3.new(0, 0, 0), 0.18), Enum.Material.Fabric))
	decor(sphere(model, Vector3.new(4.6, 1.5, 4), lean * CFrame.new(0, 6.5, 0), red:Lerp(Color3.new(1, 1, 1), 0.08), Enum.Material.Fabric))
	decor(sphere(model, Vector3.new(2.7, 0.8, 2.5), lean * CFrame.new(0, 7.05, 0.1), red:Lerp(Color3.new(0, 0, 0), 0.25), Enum.Material.Fabric))
	-- Arms: shoulder, elbow, cuffed wrist, every segment joint to joint. (They used to be single
	-- blocks rolled 38 degrees off the shoulder, flaring out sideways and stopping in mid-air.)
	for _, side in ipairs({ -1, 1 }) do
		local shoulder = lean * Vector3.new(side * 2.7, 6.3, 0.1)
		local elbow = lean * Vector3.new(side * 3.1, 4.3, 1.5)
		local wrist = lean * Vector3.new(side * 0.95, 3.5, 2.3)
		joint(model, shoulder, 1.8, red, Enum.Material.Fabric)
		limb(model, shoulder, elbow, 1.25, red, Enum.Material.Fabric)
		joint(model, elbow, 1.8, red, Enum.Material.Fabric)
		limb(model, elbow, wrist, 1.1, red, Enum.Material.Fabric)
		local along = (wrist - elbow).Unit
		-- The cuff is a ring round the wrist, wider than the forearm's diagonal, and the hand sits past it.
		decor(piece(model, Vector3.new(0.45, 1.6, 1.6), CFrame.lookAt(wrist, wrist + along) * CFrame.Angles(0, math.pi / 2, 0),
			Color3.fromRGB(196, 200, 210), Enum.Material.Metal, Enum.PartType.Cylinder))
		joint(model, wrist + along * 0.7, 1.6, skin)
	end
	decor(piece(model, Vector3.new(1.3, 0.22, 0.22), lean * CFrame.new(0, 3.5, 2.3), Color3.fromRGB(170, 174, 184), Enum.Material.Metal))
	-- Head, chin down, and the sweat that gives the whole thing its name.
	local head = lean * CFrame.new(0, 7.9, 0.15) * CFrame.Angles(math.rad(-14), 0, 0)
	decor(sphere(model, Vector3.new(3.2, 3.1, 3.1), head, skin))
	decor(sphere(model, Vector3.new(3.1, 1.3, 3.1), head * CFrame.new(0, 1.0, -0.05), Color3.fromRGB(96, 74, 56), Enum.Material.Fabric))
	cartoonEyes(model, head, 0.62, -0.15, -1.5, 0.9)
	for _, side in ipairs({ -1, 1 }) do
		decor(sphere(model, Vector3.new(1.1, 0.6, 0.6), head * CFrame.new(side * 1.3, -0.7, -0.8), Color3.fromRGB(226, 150, 140)))
		-- A frown: each half of the mouth tips down toward its own side.
		decor(piece(model, Vector3.new(0.8, 0.24, 0.3), head * CFrame.new(side * 0.42, -0.95, -1.25) * CFrame.Angles(0, 0, -side * math.rad(14)),
			Color3.fromRGB(120, 66, 62)))
	end
	local sweat = Color3.fromRGB(150, 210, 255)
	for _, drop in ipairs({ { 0.45, 0.25, -1.5 }, { -1.15, 0.15, -1.05 }, { 1.25, -0.2, -0.95 } }) do
		local bead = decor(sphere(model, Vector3.new(0.36, 0.5, 0.3), head * CFrame.new(drop[1], drop[2], drop[3]), sweat))
		bead.Transparency = 0.15
	end
	local falling = decor(sphere(model, Vector3.new(0.4, 0.56, 0.34), head * CFrame.new(-1.2, -0.75, -0.75), sweat))
	falling.Transparency = 0.15
	bob(falling, 0.3, 1.8, 0.6)

	-- Scene tape between the figures and the house, on two posts, sagging a little in the middle.
	local yellow = Color3.fromRGB(250, 220, 60)
	for _, x in ipairs({ -11.5, 11.5 }) do
		decor(piece(model, Vector3.new(1.2, 0.2, 1.2), origin * CFrame.new(x, 0.1, 4.5), Color3.fromRGB(50, 50, 56), Enum.Material.Metal))
		piece(model, Vector3.new(0.3, 3.25, 0.3), origin * CFrame.new(x, 1.775, 4.5), Color3.fromRGB(230, 232, 236), Enum.Material.Metal)
	end
	for _, run in ipairs({ { -11.5, 0 }, { 0, 11.5 } }) do
		local from = origin * Vector3.new(run[1], run[1] == 0 and 2.45 or 2.7, 4.5)
		local to = origin * Vector3.new(run[2], run[2] == 0 and 2.45 or 2.7, 4.5)
		local tape = decor(piece(model, Vector3.new((to - from).Magnitude, 0.5, 0.2), CFrame.lookAt((from + to) / 2, to) * CFrame.Angles(0, math.pi / 2, 0),
			yellow, Enum.Material.SmoothPlastic))
		sign(tape, "ROT PATROL - DO NOT CROSS", black, yellow)
	end

	-- What it was all about, dropped in the grass, and a marker beside it.
	decor(piece(model, Vector3.new(1.8, 2.2, 0.9), origin * CFrame.new(-7.4, 1, -4.6) * CFrame.Angles(math.rad(76), math.rad(18), 0),
		Color3.fromRGB(240, 196, 60), Enum.Material.Plastic))
	for index = 0, 5 do
		decor(piece(model, Vector3.new(0.5, 0.12, 0.5), origin * CFrame.new(-8.6 - index % 3 * 0.9, 0.2, -5.4 + math.floor(index / 3) * 0.8)
			* CFrame.Angles(0, math.rad(index * 25), 0), Color3.fromRGB(226, 172, 70), Enum.Material.Plastic))
	end
	local marker = decor(piece(model, Vector3.new(1.1, 1.4, 1.1), origin * CFrame.new(-6, 0.7, -6.4), Color3.fromRGB(230, 120, 40)))
	sign(marker, "1", Color3.fromRGB(255, 255, 255), nil, { Enum.NormalId.Front })

	return belly
end

local EGGS = {
	{ id = "Carrot", title = "The Absolute Unit Carrot", build = giantCarrot, footprint = 20,
		line = "It's been growing since the last update. Nobody remembers planting it." },
	{ id = "Camp", title = "Night Counter Camp", build = survivalCamp, footprint = 19,
		line = "Someone survived 97 nights out here. Night 98 was apparently a bit much." },
	{ id = "Guest", title = "The Lost Guest", build = lostGuest, footprint = 8,
		line = "Dedicated to everyone who spawned in, took one step, and fell off the map." },
	{ id = "SixSeven", title = "The 67 Monument", build = sixSeven, footprint = 14, reach = 20,
		line = "Six. Seven. Scholars still can't explain it. Everyone still does the hands." },
	{ id = "LivingRoom", title = "Outdoor Living Room", build = livingRoom, footprint = 12,
		line = "Touching grass, but make it comfy. The TV has been loading for three years." },
	{ id = "Fridgehenge", title = "Fridgehenge", build = fridgehenge, footprint = 15,
		line = "Ancient builders aligned these fridges with the midnight snack solstice." },
	{ id = "NormalGuy", title = "Definitely A Normal Guy", build = normalGuy, footprint = 6,
		line = "Just a regular guy. Standing in a field. In a coat. Please stop inspecting him." },
	{ id = "Squeak", title = "Big Squeak", build = bigSqueak, footprint = 22, reach = 26, floor = 14,
		line = "Squeak. (It is eighteen studs long and it knows what you did.)" },
}

local OBBY = {
	id = "Obby", title = "Obby of Rot", build = obbyTower, footprint = 16, reach = 12, coins = 100, xp = 60,
	line = "You beat the Obby of Rot. No checkpoints. No mercy. No reason.",
}

-- Placed on every map, not drawn from the pool: the obby is the landmark players look for, and the
-- arrest is the one Oliver wants everywhere.
local ALWAYS = {
	-- "The Sweaty Incident" is Oliver's name for it (list item 41), not a typo for the sweater.
	-- footprint 25: the scene (house behind, street in front) measures 25.0 from its centre, and the
	-- site levelled for it is footprint + SITE_MARGIN. At 20 its roof and street stood out on the
	-- levelled pad's rounded lip (tools/eggs_storm_check.py asserts every egg inside its footprint).
	{ id = "Arrest", title = "The Sweaty Incident", build = sweaterArrest, footprint = 25, reach = 24,
		line = "Nobody will say what he did. The sweater is saying plenty." },
}

--------------------------------------------------------------------------------
-- Placement and rewards
--------------------------------------------------------------------------------

local function hookPrompt(hotspot, key, egg)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Inspect"
	prompt.ObjectText = egg.title
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = egg.reach or DEFAULT_REACH
	prompt.RequiresLineOfSight = false
	prompt.Parent = hotspot

	prompt.Triggered:Connect(function(player)
		StateSync.Notify(player, egg.line)

		local seen = found[player.UserId]
		if not seen then
			seen = {}
			found[player.UserId] = seen
		end
		if seen[key] then
			return
		end
		seen[key] = true

		-- XP first: the coin award pushes the profile, and that push should include both.
		BattlePassService.AddXp(player, egg.xp or EGG_XP)
		RewardService.AwardBonusCoins(player, egg.coins or EGG_COINS, "found " .. egg.title)
	end)
end

-- How far past an egg's footprint its site is claimed and levelled. Terrain rounds off a levelled
-- site's edge over about a voxel (4 studs), so the margin keeps that slope clear of the egg itself.
local SITE_MARGIN = 8
-- How much the ground may rise and fall across a site before the spot is rejected.
local SITE_FLAT = 5

-- Water reads as no ground at all.
--
-- The height function the caller hands in reads whatever surface is under a point, and water is a
-- surface: over the river it gives back the top of the water. That is the flattest thing on the
-- whole map, so a search that picks a site by how level it is doesn't merely allow the river, it is
-- drawn to it — and levelling a site there fills the river with a disc of dirt up to the waterline.
-- The river isn't claimed in `space` either (MapGenerator checks it by hand, and only for roads and
-- vehicles), so nothing else was stopping this.
--
-- Two rays tell water from ground: one that stops at the surface and one that carries on to the bed.
local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Include
surfaceParams.FilterDescendantsInstances = { workspace.Terrain }
surfaceParams.IgnoreWater = false
local bedParams = RaycastParams.new()
bedParams.FilterType = Enum.RaycastFilterType.Include
bedParams.FilterDescendantsInstances = { workspace.Terrain }
bedParams.IgnoreWater = true

local function overWater(x, z)
	local from, down = Vector3.new(x, 400, z), Vector3.new(0, -800, 0)
	local surface = workspace:Raycast(from, down, surfaceParams)
	if not surface then
		return false
	end
	local bed = workspace:Raycast(from, down, bedParams)
	return bed == nil or surface.Position.Y - bed.Position.Y > 0.5
end

-- A spot away from the towns and other eggs, clear of anything already claimed in `space`
-- (roads, fields, lakes), on ground gentle enough to level. Its height is halfway between the
-- highest and lowest ground across the site, which levelSite then cuts and fills to.
local function findSpot(radius, centers, keepOut, taken, footprint, groundHeightAt, space)
	-- The caller's height function, with water vetoed: nil, which the sampling below already drops
	-- the whole spot for.
	local function solidHeightAt(x, z)
		local height = groundHeightAt(x, z)
		if not height or overWater(x, z) then
			return nil
		end
		return height
	end
	for _ = 1, 40 do
		local angle = math.random() * math.pi * 2
		local distance = (0.18 + math.random() * 0.62) * radius
		local x, z = math.cos(angle) * distance, math.sin(angle) * distance

		local clear = true
		for _, center in ipairs(centers) do
			if Vector2.new(center.X - x, center.Z - z).Magnitude < keepOut then
				clear = false
				break
			end
		end
		for _, spot in ipairs(taken) do
			if clear and Vector2.new(spot.X - x, spot.Z - z).Magnitude < EGG_SPACING then
				clear = false
			end
		end
		if clear and space and not space:IsFree(x, z, footprint + SITE_MARGIN) then
			clear = false
		end

		if clear then
			-- The centre, and eight directions at half the site and at its edge. A nil height is a veto
			-- (no solid ground there: water, or off the map), so the whole spot is dropped.
			local low = solidHeightAt(x, z)
			local high = low
			local edge = footprint + SITE_MARGIN
			for step = 0, 7 do
				local angle = step / 8 * math.pi * 2
				for _, reach in ipairs({ edge / 2, edge }) do
					local height = solidHeightAt(x + math.cos(angle) * reach, z + math.sin(angle) * reach)
					if not height or not low then
						low, high = nil, nil
						break
					end
					low, high = math.min(low, height), math.max(high, height)
				end
				if not low then
					break
				end
			end
			if low and high and high - low < SITE_FLAT then
				-- Halfway between: the site is levelled to it, cut on the high side and filled on the low.
				-- (It used to go at the lowest corner with the ground left as it was, which buried the
				-- uphill side by up to five studs: the obby's pad, first steps and sign.)
				return Vector3.new(x, (low + high) / 2, z)
			end
		end
	end
	return nil
end

-- Levels a round site of `radius` at `spot.Y`, the way Landmarks levels its sites: the terrain above
-- is cleared and the ground under it filled up, in the material the site was already. The fill's
-- top is the surface lift under `spot.Y`, which puts the ground's surface exactly at `spot.Y`
-- (MapTerrain.SurfaceLift). The radius is the site's claim in `space`, so it can't cut into a road.
-- Terrain materials whose surface sits exactly where it's filled to. Rough ones (Rock, Basalt, Slate)
-- stand up to a stud off it and ruffle the ground around them, Pavement snaps to whole studs and
-- Concrete to even ones (measured by claude-79), so a site on those is laid in Ground.
local SMOOTH_GROUND = {
	[Enum.Material.Ground] = true, [Enum.Material.Grass] = true, [Enum.Material.Asphalt] = true,
	[Enum.Material.Sand] = true, [Enum.Material.Snow] = true,
}

local function levelSite(spot, radius)
	local terrain = workspace.Terrain
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }
	params.IgnoreWater = true
	local hit = workspace:Raycast(Vector3.new(spot.X, spot.Y + 60, spot.Z), Vector3.new(0, -120, 0), params)
	local material = hit and SMOOTH_GROUND[hit.Material] and hit.Material or Enum.Material.Ground
	local top = spot.Y - MapTerrain.SurfaceLift
	terrain:FillCylinder(CFrame.new(spot.X, top + 25, spot.Z), 50, radius, Enum.Material.Air)
	terrain:FillCylinder(CFrame.new(spot.X, top - 4, spot.Z), 8, radius, material)
end

-- Builds this map's eggs under `parent` and returns where they went, so scenery can avoid them.
function EasterEggs.Place(parent, radius, centers, keepOut, groundHeightAt, space)
	found = {}
	placedCount = 0

	local pool = table.clone(EGGS)
	for index = #pool, 2, -1 do
		local swap = math.random(1, index)
		pool[index], pool[swap] = pool[swap], pool[index]
	end

	local chosen = { OBBY }
	for _, egg in ipairs(ALWAYS) do
		table.insert(chosen, egg)
	end
	for index = 1, math.min(#pool, math.clamp(math.floor(radius / 260), 3, 6)) do
		table.insert(chosen, pool[index])
	end

	local folder = Instance.new("Model")
	folder.Name = "EasterEggs"
	-- A container, not a structure: tools/footing_probe.lua measures each egg model in it.
	folder:SetAttribute("FootingGroup", true)

	local spots = {}
	local obbyTop = nil
	for index, egg in ipairs(chosen) do
		local spot = findSpot(radius, centers, keepOut, spots, egg.footprint, groundHeightAt, space)
		if spot then
			if space then
				space:AddCircle(spot.X, spot.Z, egg.footprint + SITE_MARGIN)
			end
			levelSite(spot, egg.footprint + SITE_MARGIN)
			-- Terrain snaps the levelled surface to its voxel grid, so it can come out a stud or two off
			-- the height asked for: the egg stands on the surface as it actually is. Read a frame later:
			-- straight after a fill, a ray still meets the terrain as it was (measured: eggs stood 2 studs
			-- under the new surface, and one 1.45 over it).
			task.wait()
			-- nil means no solid ground there under the new contract; keep the height the site was
			-- levelled to rather than dropping the egg to zero.
			local levelled = groundHeightAt(spot.X, spot.Z)
			spot = Vector3.new(spot.X, levelled or spot.Y, spot.Z)
			local model = Instance.new("Model")
			model.Name = egg.id

			local origin = CFrame.new(spot) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
			local ok, hotspot = pcall(egg.build, model, origin)
			if ok and hotspot then
				-- For tools/footing_probe.lua: the base is the levelled ground, the footprint the site's
				-- square round the pivot, which sits at the site's centre.
				model.WorldPivot = origin
				-- The floor an egg stands on is the disc levelSite flattened, so the declared square is
				-- the one inscribed in that disc, less a stud and a half for the probe's own edge step.
				-- A square of footprint * 2 has its corners out past the pad on the original slope,
				-- which is what read as eggs floating a couple of studs. An egg that brings its own
				-- floor (the duck's shoal) declares that instead.
				local half = egg.floor and egg.floor / 2 or (egg.footprint + SITE_MARGIN) / math.sqrt(2) - 1.5
				for _ = 1, 8 do
					local worst = 0
					-- Sampled a little OUTSIDE the square, because that is where the footing probe looks
					-- (its EDGE_OUT): a square that agrees exactly at its edge can still sit over the
					-- rounded lip of the pad.
					local out = half + 0.45
					for _, corner in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local height = groundHeightAt(spot.X + corner[1] * out, spot.Z + corner[2] * out)
						worst = math.max(worst, height and math.abs(height - spot.Y) or 99)
					end
					if worst <= 0.6 or half <= 5 then
						break
					end
					half *= 0.84
				end
				model:SetAttribute("FootingBase", spot.Y)
				model:SetAttribute("FootingSize", Vector3.new(half * 2, 0, half * 2))
				hookPrompt(hotspot, egg.id .. index, egg)
				model.Parent = folder
				table.insert(spots, spot)
				placedCount += 1
				if egg == OBBY then
					-- The trophy platform's surface: 15 four-stud rises above the 1-stud base pad.
					obbyTop = spot + Vector3.new(0, 61, 0)
				end
			else
				model:Destroy()
				warn(string.format("[EasterEggs] %s failed: %s", egg.id, tostring(hotspot)))
			end
			task.wait()
		end
	end

	-- Parented once every egg is built, so they replicate together.
	folder.Parent = parent
	return spots, obbyTop
end

-- For the build check only: every egg and the obby in a row under `parent` from `origin`,
-- stepping `spacing` along X, prompts and all. The game never calls this; tools/runtest.ps1
-- does, to audit all of them in one run. Returns the models.
function EasterEggs.BuildAll(parent, origin, spacing)
	spacing = spacing or 90
	local all = table.clone(EGGS)
	table.insert(all, OBBY)
	for _, egg in ipairs(ALWAYS) do
		table.insert(all, egg)
	end
	local models = {}
	for index, egg in ipairs(all) do
		local spot = Vector3.new(origin.X + (index - 1) * spacing, origin.Y, origin.Z)
		local model = Instance.new("Model")
		model.Name = egg.id
		local ok, hotspot = pcall(egg.build, model, CFrame.new(spot))
		if ok and hotspot then
			hookPrompt(hotspot, "sample" .. egg.id, egg)
			model.Parent = parent
			table.insert(models, model)
		else
			model:Destroy()
			warn(string.format("[EasterEggs] %s failed: %s", egg.id, tostring(hotspot)))
		end
	end
	return models
end

-- For the results card: how many of this map's eggs `player` found, out of how many.
function EasterEggs.FoundCount(player)
	local seen = found[player.UserId]
	local count = 0
	if seen then
		for _ in pairs(seen) do
			count += 1
		end
	end
	return count, placedCount
end

return EasterEggs
