-- Town themes: set dressing that makes each town look like its name.
--
-- The eighteen town names (MapDecor's TOWN_NAMES) used to be labels on identical towns: the same
-- square, lamps, benches and parked cars, with only the welcome sign different. Every name now has
-- a theme here, and a themed town gets three things:
--
--   a set piece   one big signature build on a free lot facing a street (or round the edge of
--                 town, facing the square, when no lot is big enough): Six Seven Square's clock
--                 tower stopped at 6:07, Sahur Junction's signal box and steam engine
--   flags         its banner on a pole at each corner of the square
--   street props  a handful of small themed pieces on the verges behind the pavements
--
--   TownThemes.Build(map, space, groundHeightAt, preset)   themes every town under `map`
--   TownThemes.BuildAll(parent, origin, spacing, names)   every set piece and prop in rows (or just
--                                                         `names`), for the galleries and the probe
--   TownThemes.Themes                                     town name -> theme
--
-- MapGenerator calls Build once, after everything else on the map has claimed its ground and before
-- the map's z-fight pass. It takes ONE roll from the global generator to seed its own Random, so
-- adding or changing a theme never moves a single roll anywhere else on the map. Towns are found
-- by their TownName attribute; streets by their Asphalt parts. Everything placed claims its
-- footprint in the map's MapSpace, and keeps off the pavements, so nothing is built through a
-- building, a lamp, a road or another prop.
--
-- Everything is primitive parts. Pieces that could matter in a fight (tanks, hedges, the engine,
-- stages) are solid cover. Thin detail (rails, ropes, hands, leaves, text boards) neither collides
-- nor stops a bullet. None of it is loot: themes add no chest or pickup spots.
--
-- Part names never reuse DestructibleService's table (Wall, Floor, Roof, Crate...), so nothing here
-- can be shot apart by accident; the street props are made breakable on purpose, each one whole,
-- by the Destructible tag on their Model (placeProps). Set pieces never break. Anything meant to
-- hang in the air carries IntentionalFloat = true, so the floating-parts audit can skip it.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SafeValue = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafeValue"))
local MapSpace = require(script.Parent:WaitForChild("MapSpace"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))

local TownThemes = {}

-- Speedrun Springs' coil springs throw players into the air (Oliver's call, 2026-09-17). Off turns
-- them back into scenery without touching anything else.
TownThemes.EnableSpringLaunch = true
-- How hard a spring throws: straight up, plus a nudge the way the spring faces.
TownThemes.SpringUp = 92
TownThemes.SpringForward = 12

-- The town layout this works round (MapGenerator's constants): the pavement beyond each street's
-- asphalt, and the square's half-width.
local SIDEWALK = 5
local PLAZA_HALF = 25
-- The gap kept between a pavement's outer edge and anything themed.
local VERGE = 1.5
-- The flag poles stand just outside the square's corners: clear of its claim, the streets'
-- pavements and the first building on each side.
local FLAG_CORNER = PLAZA_HALF + 0.8

--------------------------------------------------------------------------------
-- Colours
--------------------------------------------------------------------------------

local C = {
	white = Color3.fromRGB(240, 238, 232),
	cream = Color3.fromRGB(236, 226, 200),
	black = Color3.fromRGB(28, 28, 32),
	charcoal = Color3.fromRGB(48, 48, 54),
	iron = Color3.fromRGB(58, 60, 68),
	steel = Color3.fromRGB(160, 164, 172),
	silver = Color3.fromRGB(196, 200, 206),
	brass = Color3.fromRGB(196, 150, 66),
	gold = Color3.fromRGB(255, 196, 64),
	red = Color3.fromRGB(206, 48, 44),
	crimson = Color3.fromRGB(150, 30, 36),
	orange = Color3.fromRGB(240, 140, 40),
	yellow = Color3.fromRGB(250, 210, 50),
	green = Color3.fromRGB(70, 150, 70),
	hedge = Color3.fromRGB(58, 112, 52),
	leaf = Color3.fromRGB(84, 140, 62),
	blue = Color3.fromRGB(60, 120, 210),
	sky = Color3.fromRGB(120, 200, 240),
	purple = Color3.fromRGB(150, 90, 220),
	pink = Color3.fromRGB(255, 130, 190),
	wood = Color3.fromRGB(140, 100, 62),
	darkWood = Color3.fromRGB(96, 70, 46),
	stone = Color3.fromRGB(176, 168, 150),
	oldStone = Color3.fromRGB(132, 126, 112),
	brick = Color3.fromRGB(156, 92, 70),
	concrete = Color3.fromRGB(150, 148, 142),
	rust = Color3.fromRGB(128, 78, 48),
	signBack = Color3.fromRGB(30, 30, 36),
}
TownThemes.Colors = C

--------------------------------------------------------------------------------
-- Building kit
--------------------------------------------------------------------------------

-- A kit builds into one parent in one local frame: every CFrame a builder passes is relative to
-- `frame`, so a set piece is written once in its own coordinates (-Z toward the street) and lands
-- wherever it's placed.
local Kit = {}
Kit.__index = Kit

function Kit.new(parent, frame, rng)
	return setmetatable({ parent = parent, frame = frame, rng = rng }, Kit)
end

-- The same kit, moved: `localFrame` becomes the new origin.
function Kit:at(localFrame)
	return Kit.new(self.parent, self.frame * localFrame, self.rng)
end

-- The same kit, building under another parent (a spinning hub, a sub-model).
function Kit:into(parent)
	return Kit.new(parent, self.frame, self.rng)
end

function Kit:model(name)
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = self.parent
	return self:into(model), model
end

local function newPart(className, parent, name, size, cframe, color, material, shape)
	local part = Instance.new(className)
	part.Name = name
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

-- Decoration: never collides, never stops a bullet, never fires Touched.
local function decor(part)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end
TownThemes.Decor = decor

-- Meant to hang in the air, so the floating-parts audit leaves it alone.
local function floating(part)
	part:SetAttribute("IntentionalFloat", true)
	return part
end

-- Two facts about text that renders taught (2026-09-17): seen from its front (-Z), a model's +X is
-- the viewer's LEFT, so glyphs and ordered things laid along +X come out mirrored; and a label on a
-- part's Top face has its "up" along the part's own -X. A flat tile turned by READ_FROM_FRONT reads
-- the right way up to someone standing on its -Z side. (Round 3 renders, zoomed: with the opposite
-- turn every top-face label -- lane numbers, hopscotch, WASD -- read upside down from the street.)
local READ_FROM_FRONT = CFrame.Angles(0, math.pi / 2, 0)
TownThemes.ReadFromFront = READ_FROM_FRONT

function Kit:box(name, size, cf, color, material)
	return newPart("Part", self.parent, name, size, self.frame * cf, color, material)
end

function Kit:trim(name, size, cf, color, material)
	return decor(self:box(name, size, cf, color, material))
end

function Kit:ball(name, diameter, cf, color, material)
	return newPart("Part", self.parent, name, Vector3.new(diameter, diameter, diameter), self.frame * cf, color, material, Enum.PartType.Ball)
end

-- A cylinder whose axis is `cf`'s X axis.
function Kit:cyl(name, length, diameter, cf, color, material)
	return newPart("Part", self.parent, name, Vector3.new(length, diameter, diameter), self.frame * cf, color, material, Enum.PartType.Cylinder)
end

-- An upright cylinder standing on `base` (a local Vector3).
function Kit:post(name, height, diameter, base, color, material)
	return self:cyl(name, height, diameter, CFrame.new(base + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), color, material)
end

-- A flat round disc centred on `center`, facing up.
function Kit:disc(name, thickness, diameter, center, color, material)
	return self:cyl(name, thickness, diameter, CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2), color, material)
end

-- A cylinder from one local point to another.
function Kit:rod(name, from, to, diameter, color, material)
	local length = (to - from).Magnitude
	return self:cyl(name, length, diameter, CFrame.lookAt(from:Lerp(to, 0.5), to) * CFrame.Angles(0, math.pi / 2, 0), color, material)
end

-- A square-section bar from one local point to another.
function Kit:bar(name, from, to, thickness, color, material)
	local length = (to - from).Magnitude
	return self:box(name, Vector3.new(thickness, thickness, length), CFrame.lookAt(from:Lerp(to, 0.5), to), color, material)
end

-- WedgePart: full height along its +Z end, sloping down to nothing at its -Z end.
function Kit:wedge(name, size, cf, color, material)
	return newPart("WedgePart", self.parent, name, size, self.frame * cf, color, material)
end

-- A climbable truss standing on `base`, `height` tall (rounded to a multiple of two).
function Kit:truss(name, height, base, color)
	local truss = Instance.new("TrussPart")
	truss.Name = name
	local snapped = math.max(2, math.ceil(height / 2) * 2)
	truss.Size = Vector3.new(2, snapped, 2)
	truss.CFrame = self.frame * CFrame.new(base + Vector3.new(0, snapped / 2, 0))
	truss.Color = color or C.iron
	truss.Material = Enum.Material.Metal
	truss.Anchored = true
	truss.Parent = self.parent
	return truss
end

-- Text on a part's faces (Front by default, which is the part's -Z face).
function Kit.label(part, text, textColor, background, faces, font)
	for _, face in ipairs(faces or { Enum.NormalId.Front }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 30
		gui.LightInfluence = background and 0 or 0.3
		gui.MaxDistance = 260

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = background or Color3.new()
		label.BackgroundTransparency = background and 0 or 1
		label.BorderSizePixel = 0
		label.Font = font or Enum.Font.FredokaOne
		label.Text = text
		label.TextColor3 = textColor
		label.TextScaled = true
		label.TextStrokeTransparency = 0.6
		label.Parent = gui

		gui.Parent = part
	end
	return part
end

function Kit.light(part, color, range, brightness)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Parent = part
	return light
end

-- Client-side motion (AmbientClient): turning about the part's own Y axis (parts under it turn
-- with it), bobbing up and down, cycling colour, or swinging about its X or Y axis.
function Kit.spin(part, degreesPerSecond)
	part:SetAttribute("SpinSpeed", degreesPerSecond)
	CollectionService:AddTag(part, "AmbientSpin")
	return part
end

function Kit.bob(part, height, speed, phase)
	part:SetAttribute("BobHeight", height)
	part:SetAttribute("BobSpeed", speed)
	part:SetAttribute("BobPhase", phase or 0)
	CollectionService:AddTag(part, "AmbientBob")
	return part
end

function Kit.pulse(part, speed, phase)
	part:SetAttribute("PulseSpeed", speed)
	part:SetAttribute("PulsePhase", phase or 0)
	CollectionService:AddTag(part, "AmbientPulse")
	return part
end

function Kit.sway(part, axis, angle, speed, phase)
	part:SetAttribute("SwayAxis", axis)
	part:SetAttribute("SwayAngle", angle)
	part:SetAttribute("SwaySpeed", speed)
	part:SetAttribute("SwayPhase", phase or 0)
	CollectionService:AddTag(part, "AmbientSway")
	return part
end

-- An invisible anchor for a group that moves together (a wheel, a spinner, a rocking horse). It
-- carries no collision and is hidden, so it never shows or fights anything.
function Kit:hub(name, cf)
	local hub = decor(self:box(name, Vector3.new(0.2, 0.2, 0.2), cf, C.black))
	hub.Transparency = 1
	return hub
end

function Kit.emitter(part, spec)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(spec.color or Color3.new(1, 1, 1), spec.color2 or spec.color or Color3.new(1, 1, 1))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, spec.size or 1), NumberSequenceKeypoint.new(1, spec.size2 or spec.size or 1) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, spec.transparency or 0.4), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(spec.lifetime or 2, (spec.lifetime or 2) * 1.5)
	emitter.Rate = spec.rate or 4
	emitter.Speed = NumberRange.new(spec.speed or 1, (spec.speed or 1) * 1.6)
	emitter.SpreadAngle = Vector2.new(spec.spread or 20, spec.spread or 20)
	emitter.LightEmission = spec.lightEmission or 0
	emitter.Acceleration = spec.acceleration or Vector3.zero
	emitter.Parent = part
	return emitter
end

TownThemes.Kit = Kit
TownThemes.Floating = floating

--------------------------------------------------------------------------------
-- Shared pieces
--------------------------------------------------------------------------------

local Pieces = {}
TownThemes.Pieces = Pieces

-- A sign board on one or two posts: `width` x `height` board with its bottom edge `lift` above the
-- ground, reading toward -Z. Returns the board.
function Pieces.board(k, text, width, height, lift, textColor, background, posts, frameColor)
	local postColor = frameColor or C.darkWood
	local board = k:box("SignBoard", Vector3.new(width, height, 0.4), CFrame.new(0, lift + height / 2, 0), background or C.signBack, Enum.Material.SmoothPlastic)
	Kit.label(board, text, textColor or C.gold, background or C.signBack, { Enum.NormalId.Front, Enum.NormalId.Back })
	if posts ~= 0 then
		local spread = (posts == 1) and { 0 } or { -width / 2 + 0.5, width / 2 - 0.5 }
		for _, x in ipairs(spread) do
			-- Behind the board rather than through it, so the text is never crossed by a post.
			k:box("SignPost", Vector3.new(0.5, lift + height, 0.5), CFrame.new(x, (lift + height) / 2, 0.45), postColor, Enum.Material.Wood)
		end
	end
	return board
end

-- A little brass plaque on a short stand, leaning back toward whoever reads it.
function Pieces.plaque(k, text, width)
	width = width or 4
	k:box("PlaqueStand", Vector3.new(0.5, 2.6, 0.5), CFrame.new(0, 1.3, 0.2), C.iron, Enum.Material.Metal)
	local plate = k:box("Plaque", Vector3.new(width, 1.6, 0.25), CFrame.new(0, 2.9, 0) * CFrame.Angles(math.rad(-25), 0, 0), C.brass, Enum.Material.Metal)
	Kit.label(plate, text, C.black, nil, { Enum.NormalId.Front })
	return plate
end

-- A lamp post with a lantern head, `height` tall, lit warm.
function Pieces.lantern(k, height, color)
	k:post("LanternPost", height, 0.5, Vector3.zero, C.iron, Enum.Material.Metal)
	k:trim("LanternArm", Vector3.new(0.3, 0.3, 1.6), CFrame.new(0, height - 0.4, -0.7), C.iron, Enum.Material.Metal)
	local lamp = k:trim("LanternGlass", Vector3.new(0.9, 1.2, 0.9), CFrame.new(0, height - 1.3, -1.4), color or Color3.fromRGB(255, 214, 140), Enum.Material.Neon)
	k:trim("LanternCap", Vector3.new(1.2, 0.3, 1.2), CFrame.new(0, height - 0.55, -1.4), C.iron, Enum.Material.Metal)
	Kit.light(lamp, color or Color3.fromRGB(255, 214, 140), 16, 1.2)
	return lamp
end

-- A simple bench facing -Z.
function Pieces.bench(k, color)
	local wood = color or C.wood
	k:box("BenchSeat", Vector3.new(5, 0.4, 1.8), CFrame.new(0, 1.9, 0), wood, Enum.Material.WoodPlanks)
	k:box("BenchBack", Vector3.new(5, 1.6, 0.35), CFrame.new(0, 3.0, 0.8), wood, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -2.1, 2.1 }) do
		k:box("BenchLeg", Vector3.new(0.35, 1.7, 1.6), CFrame.new(x, 0.85, 0.05), C.iron, Enum.Material.Metal)
	end
end

-- A clock face on the -Z side of `k`'s frame, whose origin sits on the surface it hangs on. The
-- hands read `hours`:`minutes` to someone standing in front of it.
--
-- The layers step out from the wall by fixed amounts, whatever the clock's size: rim to -0.15, dial
-- to -0.25, ticks to -0.33, hour hand to -0.42, minute hand to -0.5, cap to -0.6. Scaling the depths
-- with the diameter put a small clock's ticks within a few hundredths of the dial's face, close
-- enough for the z-fight pass to call every one of them flush.
function Pieces.clockFace(k, hours, minutes, diameter)
	local s = diameter / 6
	local function toward(theta)
		-- Seen from the front, clockwise from twelve runs toward local -X.
		return Vector3.new(-math.sin(theta), math.cos(theta), 0)
	end
	local function layer(from, to)
		return to - from, (from + to) / 2
	end
	local rimDepth, rimZ = layer(0.15, -0.15)
	k:cyl("ClockRim", math.abs(rimDepth), diameter + 0.8 * s, CFrame.new(0, 0, rimZ) * CFrame.Angles(0, math.pi / 2, 0), C.iron, Enum.Material.Metal)
	decor(k:cyl("ClockDial", 0.2, diameter, CFrame.new(0, 0, -0.15) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(246, 242, 228), Enum.Material.SmoothPlastic))
	for index = 0, 11 do
		local theta = math.rad(index * 30)
		local length = (index % 3 == 0 and 0.8 or 0.45) * s
		local radius = diameter / 2 - 0.35 * s - length / 2
		k:trim("ClockTick", Vector3.new(math.max(0.12, 0.22 * s), length, 0.13), CFrame.new(toward(theta) * radius + Vector3.new(0, 0, -0.265)) * CFrame.Angles(0, 0, theta),
			C.black, Enum.Material.SmoothPlastic)
	end
	local hourTheta = math.rad(((hours % 12) + minutes / 60) * 30)
	local minuteTheta = math.rad(minutes * 6)
	local hourLength, minuteLength = diameter * 0.26, diameter * 0.38
	-- The hands' tails and the cap are sized so that at a right angle (3:00, 6:00...) no end of one
	-- lines up with a side of another.
	local hourTail, minuteTail = 0.3 * s + 0.05, 0.4 * s
	local capSize = math.max(0.45, 0.7 * s)
	k:trim("ClockHourHand", Vector3.new(math.max(0.16, 0.38 * s), hourLength, 0.14),
		CFrame.new(toward(hourTheta) * (hourLength / 2 - hourTail) + Vector3.new(0, 0, -0.35)) * CFrame.Angles(0, 0, hourTheta), C.black, Enum.Material.Metal)
	k:trim("ClockMinuteHand", Vector3.new(math.max(0.12, 0.24 * s), minuteLength, 0.14),
		CFrame.new(toward(minuteTheta) * (minuteLength / 2 - minuteTail) + Vector3.new(0, 0, -0.43)) * CFrame.Angles(0, 0, minuteTheta), C.black, Enum.Material.Metal)
	k:trim("ClockCap", Vector3.new(capSize, capSize, 0.15), CFrame.new(0, 0, -0.525), C.brass, Enum.Material.Metal)
end

-- What a spring does to whoever lands on it: nothing for bots (a bot thrown onto a ledge it can't
-- path down from is a stuck bot), and at most one throw every 1.5 seconds per player per spring.
-- Returns the velocity it applied, so a probe can call it without any physics running.
local SPRING_COOLDOWN = 1.5
TownThemes.SpringCooldown = SPRING_COOLDOWN

-- Who a spring will throw. A probe swaps this out to test the throw without a real player.
function TownThemes.CanLaunch(character)
	return Players:GetPlayerFromCharacter(character) ~= nil
end

-- When each character last left each spring, server-side only. STRONG keys on both levels: a weak
-- table with Instance keys loses live entries whenever the collector runs, and this one guards the
-- launch cooldown, so losing an entry would let a player be thrown again immediately (claude-4a's
-- audit, 2026-09-17; the same mistake DestructibleService's `damaged` table documents). The trigger's
-- entry goes when the trigger does, and entries older than the cooldown are dropped as we go, so the
-- table never holds more than the players standing on springs right now.
-- (It used to be a LastLaunch_<Name> attribute per player on the trigger, which replicated every
-- throw to every client and never went away either.)
local lastLaunch = {}

local function launchTimes(trigger)
	local times = lastLaunch[trigger]
	if not times then
		times = {}
		lastLaunch[trigger] = times
		trigger.Destroying:Connect(function()
			lastLaunch[trigger] = nil
		end)
	end
	return times
end

-- The launch kind MovementClient applies: "pad" plays the launch whoosh and sends a running player
-- the way they're running (a standing one along the spring). With no kind it played the item
-- pickup sound, which is wrong for a spring.
TownThemes.SpringLaunchKind = "pad"

function TownThemes.SpringLaunch(trigger, character, now)
	if not TownThemes.EnableSpringLaunch or not trigger.Parent then
		return nil
	end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or not TownThemes.CanLaunch(character) then
		return nil
	end
	local times = launchTimes(trigger)
	now = now or os.clock()
	local last = times[character]
	if last and now - last < SPRING_COOLDOWN then
		return nil
	end
	times[character] = now
	-- Anyone whose cooldown has run out is forgotten: the entry can't matter again.
	for other, when in pairs(times) do
		if other ~= character and now - when > SPRING_COOLDOWN then
			times[other] = nil
		end
	end
	local forward = trigger:GetAttribute("LaunchForward") or Vector3.zero
	local velocity = Vector3.new(0, TownThemes.SpringUp, 0) + forward * TownThemes.SpringForward
	MovementService.Launch(character, velocity, TownThemes.SpringLaunchKind)
	return velocity
end

-- What the trigger's Touched does with whatever touched it: the character that part belongs to (a
-- foot, or an accessory's handle under an Accessory, whose nearest Model ancestor is the character).
function TownThemes.SpringTouched(trigger, hit, now)
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	return TownThemes.SpringLaunch(trigger, character, now)
end

-- A launch trigger: an invisible touch plate over a spring's top. Whoever steps on it is thrown
-- up, and a little along `forward` (a local flat direction). See TownThemes.SpringLaunch.
function Pieces.springTrigger(k, cf, size, forward)
	local trigger = decor(k:box("SpringTrigger", size, cf, C.white))
	trigger.Transparency = 1
	trigger.CanTouch = true
	local world = k.frame:VectorToWorldSpace(forward or Vector3.zero)
	world = Vector3.new(world.X, 0, world.Z)
	trigger:SetAttribute("LaunchForward", world.Magnitude > 0.01 and world.Unit or Vector3.zero)
	trigger.Touched:Connect(function(hit)
		TownThemes.SpringTouched(trigger, hit)
	end)
	return trigger
end

--------------------------------------------------------------------------------
-- Themes
--------------------------------------------------------------------------------

-- Town name -> theme. Each theme is
--   { name, id, flag = { emblem, caption, color, text, trim },
--     setPiece = { id, name, width, depth, ground (terrain material or nil), build(kit, ctx) },
--     props = { { id, radius, build(kit, ctx) }, ... }, propCount = { min, max } (optional) }
-- A set piece builds inside width x depth round its kit's origin, front toward -Z; a prop inside
-- its radius. Neither may reach past that: it's exactly the ground they claim.
TownThemes.Themes = {}
TownThemes.Order = {}

local function defineTheme(theme)
	TownThemes.Themes[theme.name] = theme
	table.insert(TownThemes.Order, theme.name)
	return theme
end

--------------------------------------------------------------------------------
-- Six Seven Square: the town clock stopped at 6:07 and never started again
--------------------------------------------------------------------------------

do
	local BRICK = Color3.fromRGB(150, 88, 66)
	local STONE = Color3.fromRGB(214, 204, 184)
	local COPPER = Color3.fromRGB(88, 152, 130)
	local HEDGE = Color3.fromRGB(60, 118, 58)

	-- Digits drawn three pixels wide and five tall, top row first.
	local DIGITS = {
		["6"] = { "###", "#..", "###", "#.#", "###" },
		["7"] = { "###", "..#", "..#", "..#", "..#" },
	}

	-- A hedge cut into a digit, standing on a brick planter. Each row is laid as runs of hedge, and
	-- a run repeated down consecutive rows becomes one tall block, so a 7 is two parts.
	local function hedgeDigit(k, digit, pixel)
		local rows = DIGITS[digit]
		k:box("DigitPlanter", Vector3.new(pixel * 3 + 1.2, 1.6, pixel + 1.2), CFrame.new(0, 0.4, 0), BRICK, Enum.Material.Brick)
		local runs = {}
		for row, pattern in ipairs(rows) do
			local column = 1
			while column <= 3 do
				if string.sub(pattern, column, column) == "#" then
					local finish = column
					while finish < 3 and string.sub(pattern, finish + 1, finish + 1) == "#" do
						finish += 1
					end
					table.insert(runs, { top = row, bottom = row, from = column, to = finish })
					column = finish + 1
				else
					column += 1
				end
			end
		end
		-- Merge a run into the one above it when they cover the same columns.
		local merged = {}
		for _, run in ipairs(runs) do
			local joined = false
			for _, other in ipairs(merged) do
				if other.from == run.from and other.to == run.to and other.bottom == run.top - 1 then
					other.bottom = run.bottom
					joined = true
					break
				end
			end
			if not joined then
				table.insert(merged, run)
			end
		end
		for _, run in ipairs(merged) do
			local width = (run.to - run.from + 1) * pixel
			local height = (run.bottom - run.top + 1) * pixel
			-- Seen from the front a kit's +X is the viewer's LEFT, so column 1 goes on +X.
			local x = (2 - (run.from + run.to) / 2) * pixel
			local y = 1.2 + (5 - (run.top + run.bottom) / 2 + 0.5) * pixel
			k:box("HedgeDigit", Vector3.new(width, height, pixel), CFrame.new(x, y, 0), HEDGE, Enum.Material.LeafyGrass)
		end
	end

	local function clockTower(k)
		local tower = k:at(CFrame.new(0, 0, 5.5))
		-- Sunk a stud into the ground, so it meets the ground wherever it stands.
		tower:box("TowerPlinth", Vector3.new(10.4, 2.2, 10.4), CFrame.new(0, 0.1, 0), STONE, Enum.Material.Limestone)
		tower:box("TowerShaft", Vector3.new(8, 24, 8), CFrame.new(0, 13.2, 0), BRICK, Enum.Material.Brick)
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				tower:box("TowerQuoin", Vector3.new(1.1, 23.8, 1.1), CFrame.new(sx * 4, 13.2, sz * 4), STONE, Enum.Material.Limestone)
			end
		end
		for _, y in ipairs({ 9, 17 }) do
			tower:trim("TowerBand", Vector3.new(8.8, 0.7, 8.8), CFrame.new(0, y, 0), STONE, Enum.Material.Limestone)
		end
		-- Slit windows up every side, and the door and its plaque on the front.
		for side = 0, 3 do
			local face = tower:at(CFrame.Angles(0, side * math.pi / 2, 0))
			for _, y in ipairs({ 13, 21 }) do
				face:trim("TowerWindow", Vector3.new(1.2, 2.6, 0.2), CFrame.new(0, y, -4.1), Color3.fromRGB(40, 44, 56), Enum.Material.Glass)
			end
		end
		tower:box("TowerDoor", Vector3.new(3.2, 5.6, 0.3), CFrame.new(0, 4.0, -4.15), C.darkWood, Enum.Material.WoodPlanks)
		tower:trim("TowerDoorHead", Vector3.new(4.2, 0.8, 0.4), CFrame.new(0, 7.2, -4.2), STONE, Enum.Material.Limestone)
		local plaque = tower:trim("TowerPlaque", Vector3.new(5.4, 1.4, 0.25), CFrame.new(0, 10.9, -4.125), C.brass, Enum.Material.Metal)
		Kit.label(plaque, "SIX SEVEN SQUARE  •  EST. 6:07", C.black)

		-- The clock stage, a clock on every side, all stopped at the same minute.
		tower:trim("TowerCornice", Vector3.new(10.2, 0.6, 10.2), CFrame.new(0, 25.2, 0), STONE, Enum.Material.Limestone)
		tower:box("ClockStage", Vector3.new(9.6, 7.2, 9.6), CFrame.new(0, 28.8, 0), STONE, Enum.Material.Limestone)
		tower:trim("TowerCornice", Vector3.new(10.2, 0.6, 10.2), CFrame.new(0, 32.4, 0), STONE, Enum.Material.Limestone)
		for side = 0, 3 do
			Pieces.clockFace(tower:at(CFrame.new(0, 28.8, 0) * CFrame.Angles(0, side * math.pi / 2, 0) * CFrame.new(0, 0, -4.8)), 6, 7, 5.6)
		end

		-- The belfry: four piers, a beam, and a bell that still swings.
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				tower:box("BelfryPier", Vector3.new(1.4, 7, 1.4), CFrame.new(sx * 3.9, 36.2, sz * 3.9), STONE, Enum.Material.Limestone)
			end
		end
		tower:trim("BellBeam", Vector3.new(8.4, 0.6, 0.6), CFrame.new(0, 39.1, 0), C.darkWood, Enum.Material.Wood)
		local hub = tower:hub("BellHub", CFrame.new(0, 38.6, 0))
		local bell = tower:into(hub)
		bell:trim("BellYoke", Vector3.new(1.4, 0.5, 0.5), CFrame.new(0, 38.35, 0), C.darkWood, Enum.Material.Wood)
		decor(bell:ball("BellCrown", 2.6, CFrame.new(0, 36.9, 0), C.brass, Enum.Material.Metal))
		decor(bell:cyl("BellSkirt", 1.2, 3.2, CFrame.new(0, 35.7, 0) * CFrame.Angles(0, 0, math.pi / 2), C.brass, Enum.Material.Metal))
		decor(bell:cyl("BellLip", 0.3, 3.5, CFrame.new(0, 35.05, 0) * CFrame.Angles(0, 0, math.pi / 2), C.brass, Enum.Material.Metal))
		decor(bell:ball("BellClapper", 0.7, CFrame.new(0, 34.6, 0), C.iron, Enum.Material.Metal))
		Kit.sway(hub, "X", 14, 1.1, 0)

		-- A stepped copper cap, a spire, and a weathervane that reads 67 whichever way it turns.
		tower:box("BelfryTop", Vector3.new(10.2, 0.8, 10.2), CFrame.new(0, 40.1, 0), STONE, Enum.Material.Limestone)
		local y = 40.5
		for _, size in ipairs({ 9, 6.6, 4.2, 1.8 }) do
			tower:box("TowerCap", Vector3.new(size, 1.6, size), CFrame.new(0, y + 0.8, 0), COPPER, Enum.Material.CorrodedMetal)
			y += 1.6
		end
		tower:post("TowerSpire", 5, 0.4, Vector3.new(0, y, 0), C.iron, Enum.Material.Metal)
		tower:ball("TowerFinial", 0.9, CFrame.new(0, y + 5.3, 0), C.gold, Enum.Material.Metal)
		local vaneHub = tower:hub("VaneHub", CFrame.new(0, y + 3.6, 0))
		local vane = tower:into(vaneHub)
		local plate = vane:trim("VanePlate", Vector3.new(2.6, 1.1, 0.12), CFrame.new(0.9, y + 3.6, 0), C.gold, Enum.Material.Metal)
		Kit.label(plate, "67", C.black, nil, { Enum.NormalId.Front, Enum.NormalId.Back })
		vane:trim("VaneArrow", Vector3.new(1.4, 0.2, 0.2), CFrame.new(-1.1, y + 3.6, 0), C.gold, Enum.Material.Metal)
		Kit.sway(vaneHub, "Y", 35, 0.35, 1.2)
	end

	-- Hopscotch chalked on the cobbles: 6, 7, 6-7, then 67 to finish.
	local function hopscotch(k)
		-- Left to right as you walk in from the street, which is +X to -X in the kit.
		local tiles = {
			{ x = 0, z = -12.5, text = "6" },
			{ x = 0, z = -9.3, text = "7" },
			{ x = 1.6, z = -6.1, text = "6" },
			{ x = -1.6, z = -6.1, text = "7" },
			{ x = 0, z = -2.9, text = "67" },
		}
		for _, tile in ipairs(tiles) do
			-- Turned so its Top-face label reads the right way up walking in from the street.
			local square = k:trim("HopscotchTile", Vector3.new(3, 0.14, 3), CFrame.new(tile.x, 0.09, tile.z) * READ_FROM_FRONT,
				Color3.fromRGB(232, 228, 214), Enum.Material.Concrete)
			Kit.label(square, tile.text, Color3.fromRGB(60, 90, 170), nil, { Enum.NormalId.Top })
		end
	end

	defineTheme({
		name = "Six Seven Square",
		id = "SixSevenSquare",
		flag = { emblem = "6:07", caption = "SIX SEVEN SQUARE", color = Color3.fromRGB(36, 64, 120), text = C.white, trim = C.gold },
		setPiece = {
			id = "ClockTower",
			name = "The 6:07 Clock",
			width = 32,
			depth = 30,
			ground = Enum.Material.Cobblestone,
			build = function(k)
				clockTower(k)
				hedgeDigit(k:at(CFrame.new(10, 0, -4)), "6", 2)
				hedgeDigit(k:at(CFrame.new(-10, 0, -4)), "7", 2)
				hopscotch(k)
				for _, x in ipairs({ -6.5, 6.5 }) do
					Pieces.lantern(k:at(CFrame.new(x, 0, 1.5)), 8)
				end
			end,
		},
		props = {
			{
				id = "SpeedLimit67",
				radius = 1.4,
				build = function(k)
					k:post("SignPole", 7.6, 0.3, Vector3.zero, C.steel, Enum.Material.Metal)
					local disc = decor(k:cyl("SpeedSign", 0.2, 2.8, CFrame.new(0, 6.4, -0.25) * CFrame.Angles(0, math.pi / 2, 0), C.white, Enum.Material.SmoothPlastic))
					decor(k:cyl("SpeedSignRing", 0.14, 3.2, CFrame.new(0, 6.4, -0.12) * CFrame.Angles(0, math.pi / 2, 0), C.red, Enum.Material.SmoothPlastic))
					Kit.label(disc, "67", C.black, nil, { Enum.NormalId.Right })
					local plate = k:trim("SpeedSignPlate", Vector3.new(2.2, 0.8, 0.12), CFrame.new(0, 4.4, -0.22), C.white, Enum.Material.SmoothPlastic)
					Kit.label(plate, "SPEED LIMIT", C.black)
				end,
			},
			{
				id = "NumberBollards",
				radius = 2.6,
				build = function(k)
					for index, x in ipairs({ 1.6, -1.6 }) do
						k:post("Bollard", 2.8, 1.1, Vector3.new(x, 0, 0), C.charcoal, Enum.Material.Metal)
						local cap = k:box("BollardCap", Vector3.new(1.3, 1.3, 1.3), CFrame.new(x, 3.45, 0), index == 1 and C.yellow or C.orange, Enum.Material.SmoothPlastic)
						Kit.label(cap, index == 1 and "6" or "7", C.black, nil, { Enum.NormalId.Front, Enum.NormalId.Back })
					end
				end,
			},
			{
				id = "Hopscotch67",
				radius = 3.2,
				build = function(k)
					for index, tile in ipairs({ { 0, -1.5, "6" }, { 0, 1.5, "7" } }) do
						local square = k:trim("HopscotchTile", Vector3.new(2.8, 0.14, 2.8), CFrame.new(tile[1], 0.09, tile[2]) * READ_FROM_FRONT,
							Color3.fromRGB(232, 228, 214), Enum.Material.Concrete)
						Kit.label(square, tile[3], index == 1 and Color3.fromRGB(200, 60, 90) or Color3.fromRGB(60, 90, 170), nil, { Enum.NormalId.Top })
					end
				end,
			},
			{
				id = "StoppedClock",
				radius = 1.6,
				build = function(k)
					k:post("ClockPost", 8, 0.5, Vector3.zero, Color3.fromRGB(34, 60, 48), Enum.Material.Metal)
					k:box("ClockCase", Vector3.new(2.8, 2.8, 0.9), CFrame.new(0, 9.2, 0), Color3.fromRGB(34, 60, 48), Enum.Material.Metal)
					Pieces.clockFace(k:at(CFrame.new(0, 9.2, -0.45)), 6, 7, 2.2)
					Pieces.clockFace(k:at(CFrame.new(0, 9.2, 0.45) * CFrame.Angles(0, math.pi, 0)), 6, 7, 2.2)
					k:ball("ClockFinial", 0.6, CFrame.new(0, 10.9, 0), C.gold, Enum.Material.Metal)
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Speedrun Springs: a start gantry, split times and a sequence break
--------------------------------------------------------------------------------

do
	local TRACK = Color3.fromRGB(178, 62, 50)
	local TIMER_GREEN = Color3.fromRGB(80, 255, 120)

	-- A coil spring about five studs across: a base plate, a dark core, a real helix of steel wound
	-- two and a half turns round it, and a lime pad on top that bounces. The trigger above the pad
	-- does the throwing (see Pieces.springTrigger).
	local function spring(k, forward)
		k:post("SpringBase", 0.8, 5, Vector3.new(0, -0.2, 0), C.charcoal, Enum.Material.DiamondPlate)
		k:post("SpringCore", 3.0, 1.6, Vector3.new(0, 0.6, 0), C.black, Enum.Material.Metal)
		local turns, segments, radius = 2.5, 20, 1.75
		local function helix(index)
			local angle = index / segments * turns * math.pi * 2
			return Vector3.new(math.cos(angle) * radius, 0.85 + index / segments * 2.55, math.sin(angle) * radius)
		end
		for index = 0, segments - 1 do
			decor(k:rod("SpringCoil", helix(index), helix(index + 1), 0.38, C.silver, Enum.Material.Metal))
		end
		-- Turned a quarter about the vertical first, so the label on its top face reads from the street
		-- (a disc's end-face label has its "up" along the cylinder's own +Y, which the tip-up sends to -X).
		-- The lime pad bobs on each client, so it's decoration: what a player actually stands on is a
		-- still, invisible step just inside it (a collidable part that moved on clients only would
		-- jostle whoever stood on it and put the floor somewhere else on the server).
		local pad = decor(k:cyl("SpringPad", 0.5, 4.4, CFrame.new(0, 3.85, 0) * CFrame.Angles(0, math.pi / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Color3.fromRGB(150, 240, 60), Enum.Material.SmoothPlastic))
		Kit.label(pad, "BOING", C.black, nil, { Enum.NormalId.Right })
		local step = k:cyl("SpringStep", 0.34, 4.2, CFrame.new(0, 3.83, 0) * CFrame.Angles(0, 0, math.pi / 2), C.white, Enum.Material.SmoothPlastic)
		step.Transparency = 1
		step.CanQuery = false
		Pieces.springTrigger(k, CFrame.new(0, 4.6, 0), Vector3.new(3.6, 1, 3.6), forward)
		return pad
	end

	local function gantry(k)
		for _, x in ipairs({ -6.2, 6.2 }) do
			k:box("GantryPost", Vector3.new(1, 13.5, 1), CFrame.new(x, 6.25, 0), C.white, Enum.Material.Metal)
		end
		k:box("GantryBeam", Vector3.new(13.8, 1.2, 1.2), CFrame.new(0, 13.4, 0), C.white, Enum.Material.Metal)
		for index = 0, 9 do
			k:trim("Checker", Vector3.new(1.2, 1.2, 0.1), CFrame.new(-5.4 + index * 1.2, 13.4, -0.66), index % 2 == 0 and C.black or C.white, Enum.Material.SmoothPlastic)
		end
		for _, x in ipairs({ -3.5, 3.5 }) do
			k:trim("TimerHanger", Vector3.new(0.2, 0.7, 0.2), CFrame.new(x, 12.45, -0.25), C.steel, Enum.Material.Metal)
		end
		local timer = k:trim("TimerBoard", Vector3.new(9, 2.8, 0.4), CFrame.new(0, 10.7, -0.25), C.black, Enum.Material.SmoothPlastic)
		Kit.label(timer, "WR  0:06.7", TIMER_GREEN, C.black, { Enum.NormalId.Front }, Enum.Font.RobotoMono)
		Kit.label(timer, "PB  --:--.-", TIMER_GREEN, C.black, { Enum.NormalId.Back }, Enum.Font.RobotoMono)
		Kit.light(timer, TIMER_GREEN, 14, 0.8)
	end

	local function track(k)
		-- Surface 0 to 0.3; lane lines to 0.40, the start line to 0.48 and the lane numbers 0.1 to 0.45,
		-- every top and bottom at least a tenth apart.
		k:trim("Track", Vector3.new(10, 0.3, 27), CFrame.new(0, 0.15, 0), TRACK, Enum.Material.Rubber)
		for _, x in ipairs({ -4.7, -1.6, 1.6, 4.7 }) do
			k:trim("LaneLine", Vector3.new(0.25, 0.32, 26.8), CFrame.new(x, 0.24, 0), C.white, Enum.Material.SmoothPlastic)
		end
		k:trim("StartLine", Vector3.new(9.8, 0.33, 0.6), CFrame.new(0, 0.315, -8.6), C.white, Enum.Material.SmoothPlastic)
		for lane = 1, 3 do
			local tile = k:trim("LaneNumber", Vector3.new(2.2, 0.35, 1.6), CFrame.new(3.15 - (lane - 1) * 3.15, 0.275, -10.6) * READ_FROM_FRONT,
				TRACK, Enum.Material.Rubber)
			Kit.label(tile, tostring(lane), C.white, nil, { Enum.NormalId.Top })
		end
	end

	local function checkpoint(k, text, good)
		for _, x in ipairs({ -5.6, 5.6 }) do
			k:box("CheckpointPost", Vector3.new(0.8, 8.4, 0.8), CFrame.new(x, 3.8, 0), C.charcoal, Enum.Material.Metal)
		end
		k:box("CheckpointBar", Vector3.new(12.4, 0.7, 0.6), CFrame.new(0, 8.3, 0), C.charcoal, Enum.Material.Metal)
		local strip = k:trim("CheckpointGlow", Vector3.new(10.4, 0.25, 0.25), CFrame.new(0, 7.8, 0), Color3.fromRGB(90, 220, 255), Enum.Material.Neon)
		Kit.light(strip, Color3.fromRGB(90, 220, 255), 12, 0.8)
		local board = k:trim("SplitBoard", Vector3.new(4.4, 1.4, 0.3), CFrame.new(0, 6.6, 0), C.black, Enum.Material.SmoothPlastic)
		Kit.label(board, text, good and TIMER_GREEN or Color3.fromRGB(255, 90, 80), C.black, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.RobotoMono)
	end

	-- The ledge only the spring reaches (or the ladder, for the honest): a trophy for the skip.
	local function ledge(k)
		local top = 16
		for _, x in ipairs({ -4.4, 4.4 }) do
			for _, z in ipairs({ -3, 3 }) do
				k:box("LedgeLeg", Vector3.new(0.8, top - 0.4, 0.8), CFrame.new(x, (top - 0.8) / 2, z), C.steel, Enum.Material.Metal)
			end
		end
		k:box("LedgeDeck", Vector3.new(10, 0.8, 7.4), CFrame.new(0, top - 0.4, 0), C.charcoal, Enum.Material.DiamondPlate)
		-- Rails on the back and sides; the front is open to land on.
		for _, x in ipairs({ -4.8, 4.8 }) do
			k:trim("LedgeRail", Vector3.new(0.2, 0.2, 7.2), CFrame.new(x, top + 2.4, 0), C.yellow, Enum.Material.Metal)
			for _, z in ipairs({ -3.5, 0, 3.5 }) do
				-- Posts thicker than the rail, so their faces never line up with it.
				k:trim("LedgeRailPost", Vector3.new(0.36, 2.4, 0.36), CFrame.new(x, top + 1.2, z), C.yellow, Enum.Material.Metal)
			end
		end
		-- The back rails sit a tenth lower and stop inside the side rails.
		for _, x in ipairs({ -3.35, 3.35 }) do
			k:trim("LedgeRail", Vector3.new(2.9, 0.2, 0.2), CFrame.new(x, top + 2.15, 3.5), C.yellow, Enum.Material.Metal)
		end
		-- The trophy.
		k:box("TrophyBase", Vector3.new(1.6, 0.8, 1.6), CFrame.new(1.5, top + 0.4, 1.4), C.black, Enum.Material.Marble)
		decor(k:post("TrophyStem", 0.9, 0.35, Vector3.new(1.5, top + 0.8, 1.4), C.gold, Enum.Material.Foil))
		decor(k:ball("TrophyCup", 1.5, CFrame.new(1.5, top + 2.2, 1.4), C.gold, Enum.Material.Foil))
		for _, side in ipairs({ -1, 1 }) do
			k:trim("TrophyHandle", Vector3.new(0.5, 0.9, 0.2), CFrame.new(1.5 + side * 0.95, top + 2.3, 1.4), C.gold, Enum.Material.Foil)
		end
		local sign = k:trim("SkipSign", Vector3.new(7.4, 1.5, 0.25), CFrame.new(0, top - 1.6, -3.83), C.black, Enum.Material.SmoothPlastic)
		Kit.label(sign, "SEQUENCE BREAK!", C.gold, C.black, { Enum.NormalId.Front })
	end

	defineTheme({
		name = "Speedrun Springs",
		id = "SpeedrunSprings",
		flag = { emblem = "0:06.7", caption = "SPEEDRUN SPRINGS", color = Color3.fromRGB(24, 24, 28), text = Color3.fromRGB(110, 255, 140), trim = Color3.fromRGB(110, 255, 140) },
		setPiece = {
			id = "SpeedrunCourse",
			name = "The Speedrun Course",
			width = 40,
			depth = 28,
			ground = Enum.Material.Pavement,
			build = function(k)
				local lane = k:at(CFrame.new(-9, 0, 0))
				track(lane)
				gantry(lane:at(CFrame.new(0, 0, -8)))
				checkpoint(lane:at(CFrame.new(0, 0, 4)), "SPLIT 1  -0.4", true)
				-- Three springs in a line toward the ledge; the last one is lined up to land you on it.
				local springs = { Vector3.new(2, 0, -9), Vector3.new(8, 0, -4), Vector3.new(14, 0, 1) }
				for index, at in ipairs(springs) do
					local nextAt = springs[index + 1] or Vector3.new(14, 0, 9)
					local forward = Vector3.new(nextAt.X - at.X, 0, nextAt.Z - at.Z).Unit
					local pad = spring(k:at(CFrame.new(at)), forward)
					Kit.bob(pad, 0.35, 5, index)
				end
				ledge(k:at(CFrame.new(14, 0, 8.2)))
				k:truss("LedgeLadder", 16, Vector3.new(14, 0, 12.9), C.steel)
				local rules = Pieces.board(k:at(CFrame.new(11, 0, -12.2)), "NO WALKING  •  SPRINT ONLY", 7, 1.6, 2.6, C.white, Color3.fromRGB(180, 40, 40), 2, C.iron)
				rules.Name = "RulesSign"
			end,
		},
		props = {
			{
				id = "CheckpointFlag",
				radius = 3.0,
				build = function(k)
					k:post("FlagPost", 7.3, 0.3, Vector3.new(0, -0.3, 0), C.steel, Enum.Material.Metal)
					for row = 0, 2 do
						for column = 0, 3 do
							k:trim("CheckerFlag", Vector3.new(0.7, 0.7, 0.08), CFrame.new(0.5 + column * 0.7, 6.3 - row * 0.7, 0), (row + column) % 2 == 0 and C.black or C.white, Enum.Material.Fabric)
						end
					end
					local pad = k:trim("CheckpointPad", Vector3.new(2.6, 0.12, 2.6), CFrame.new(0, 0.08, -0.2), Color3.fromRGB(90, 220, 255), Enum.Material.Neon)
					pad.Transparency = 0.3
				end,
			},
			{
				id = "SplitTimer",
				radius = 1.6,
				build = function(k)
					local times = { "-0.4", "+0.2", "-1.1", "+0.0" }
					local text = times[k.rng:NextInteger(1, #times)]
					k:post("TimerPost", 5.4, 0.35, Vector3.zero, C.charcoal, Enum.Material.Metal)
					local board = k:box("TimerBox", Vector3.new(3.2, 1.6, 0.6), CFrame.new(0, 6.1, 0), C.black, Enum.Material.SmoothPlastic)
					Kit.label(board, text, string.sub(text, 1, 1) == "-" and TIMER_GREEN or Color3.fromRGB(255, 90, 80), C.black,
						{ Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.RobotoMono)
				end,
			},
			{
				id = "SprintSign",
				radius = 2.4,
				build = function(k)
					local sign = Pieces.board(k, "NO WALKING", 4.2, 1.3, 2.4, C.white, Color3.fromRGB(180, 40, 40), 2, C.iron)
					sign.Name = "SprintSign"
				end,
			},
			{
				id = "StartBlocks",
				radius = 2.2,
				build = function(k)
					k:trim("BlockRail", Vector3.new(0.5, 0.3, 3.6), CFrame.new(0, 0.15, 0), C.steel, Enum.Material.Metal)
					for _, side in ipairs({ -1, 1 }) do
						k:wedge("StartBlock", Vector3.new(1.2, 0.9, 1.1), CFrame.new(side * 0.9, 0.45, side * 0.6), Color3.fromRGB(40, 110, 200), Enum.Material.SmoothPlastic)
					end
					local marker = k:trim("LaneMarker", Vector3.new(1.4, 0.8, 0.2), CFrame.new(0, 0.7, -1.9), C.white, Enum.Material.SmoothPlastic)
					Kit.label(marker, "GO", C.black)
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Sahur Junction: the old steam railway where the 3:30 AM never leaves
--------------------------------------------------------------------------------

do
	local ENGINE_GREEN = Color3.fromRGB(34, 88, 58)
	local WHEEL_RED = Color3.fromRGB(170, 40, 36)
	local BALLAST = Color3.fromRGB(118, 110, 100)
	local SLEEPER = Color3.fromRGB(86, 64, 46)
	local RAIL = Color3.fromRGB(140, 140, 146)
	local BRICK = Color3.fromRGB(148, 84, 62)
	local LAMP = Color3.fromRGB(255, 206, 130)

	-- The engine in its own coordinates: +X is its front, Z = 0 the middle of the track, y the
	-- world height above the site (rail tops are at 1.2).
	local function engine(k)
		k:box("EngineFootplate", Vector3.new(21, 0.7, 3.2), CFrame.new(0, 2.55, 0), C.black, Enum.Material.Metal)
		for _, x in ipairs({ -1.5, 2.3, 6.1 }) do
			for _, z in ipairs({ -2.05, 2.05 }) do
				decor(k:cyl("DrivingWheel", 0.5, 3.6, CFrame.new(x, 3.0, z) * CFrame.Angles(0, math.pi / 2, 0), WHEEL_RED, Enum.Material.Metal))
				decor(k:cyl("WheelHub", 0.8, 0.9, CFrame.new(x, 3.0, z) * CFrame.Angles(0, math.pi / 2, 0), C.brass, Enum.Material.Metal))
			end
		end
		for _, x in ipairs({ 9.6, -9.5, -7.2 }) do
			for _, z in ipairs({ -1.95, 1.95 }) do
				decor(k:cyl("SmallWheel", 0.4, 2.2, CFrame.new(x, 2.3, z) * CFrame.Angles(0, math.pi / 2, 0), WHEEL_RED, Enum.Material.Metal))
			end
		end
		k:trim("CouplingRod", Vector3.new(8, 0.3, 0.2), CFrame.new(2.3, 3.0, -2.45), C.steel, Enum.Material.Metal)
		k:trim("RunningBoard", Vector3.new(10.3, 0.25, 4.8), CFrame.new(2.55, 4.9, 0), C.black, Enum.Material.Metal)

		k:cyl("Boiler", 10.5, 4.2, CFrame.new(2.55, 5.0, 0), ENGINE_GREEN, Enum.Material.SmoothPlastic)
		for _, x in ipairs({ 0.5, 5.0 }) do
			decor(k:cyl("BoilerBand", 0.3, 4.35, CFrame.new(x, 5.0, 0), C.brass, Enum.Material.Metal))
		end
		k:cyl("Smokebox", 2.5, 4.4, CFrame.new(9.05, 5.0, 0), C.charcoal, Enum.Material.Metal)
		decor(k:cyl("SmokeboxDoor", 0.2, 3.4, CFrame.new(10.4, 5.0, 0), C.black, Enum.Material.Metal))
		k:trim("SmokeboxHandle", Vector3.new(0.3, 0.4, 0.4), CFrame.new(10.62, 5.0, 0), C.brass, Enum.Material.Metal)
		k:post("Chimney", 2.6, 1.4, Vector3.new(9.05, 6.8, 0), C.charcoal, Enum.Material.Metal)
		local lip = decor(k:cyl("ChimneyLip", 0.45, 1.9, CFrame.new(9.05, 9.3, 0) * CFrame.Angles(0, 0, math.pi / 2), C.charcoal, Enum.Material.Metal))
		Kit.emitter(lip, { color = Color3.fromRGB(200, 200, 204), color2 = Color3.fromRGB(150, 150, 156), size = 1.2, size2 = 5, transparency = 0.45,
			lifetime = 3, rate = 3, speed = 3, spread = 12, acceleration = Vector3.new(0.6, 0.4, 0) })
		decor(k:ball("SteamDome", 2.2, CFrame.new(2.5, 7.0, 0), C.brass, Enum.Material.Metal))
		decor(k:ball("SandDome", 1.7, CFrame.new(-0.8, 6.8, 0), ENGINE_GREEN, Enum.Material.SmoothPlastic))
		local headlamp = k:trim("Headlamp", Vector3.new(0.8, 0.8, 0.8), CFrame.new(10.2, 7.5, 0), LAMP, Enum.Material.Neon)
		Kit.light(headlamp, LAMP, 18, 1.2)

		-- Buffer beam, buffers and the cowcatcher.
		k:trim("BufferBeam", Vector3.new(0.4, 0.8, 3.6), CFrame.new(10.7, 2.9, 0), C.red, Enum.Material.Metal)
		for _, z in ipairs({ -1.1, 1.1 }) do
			decor(k:cyl("Buffer", 0.8, 0.7, CFrame.new(11.1, 3.3, z), C.black, Enum.Material.Metal))
		end
		k:wedge("Cowcatcher", Vector3.new(3.2, 1.3, 1.2), CFrame.new(11.5, 1.95, 0) * CFrame.Angles(0, -math.pi / 2, 0), C.charcoal, Enum.Material.Metal)

		-- The cab.
		k:box("CabLower", Vector3.new(4, 2.6, 3.6), CFrame.new(-4.7, 4.2, 0), ENGINE_GREEN, Enum.Material.SmoothPlastic)
		k:box("CabFront", Vector3.new(0.3, 3.4, 3.6), CFrame.new(-2.85, 7.2, 0), ENGINE_GREEN, Enum.Material.SmoothPlastic)
		for _, z in ipairs({ -1.65, 1.65 }) do
			k:box("CabPillar", Vector3.new(0.3, 3.4, 0.3), CFrame.new(-6.5, 7.2, z), ENGINE_GREEN, Enum.Material.SmoothPlastic)
		end
		for _, z in ipairs({ -0.9, 0.9 }) do
			decor(k:cyl("CabWindow", 0.1, 0.9, CFrame.new(-2.66, 7.9, z), Color3.fromRGB(200, 220, 230), Enum.Material.Glass))
		end
		k:box("CabRoof", Vector3.new(5, 0.35, 4.4), CFrame.new(-4.6, 9.075, 0), C.black, Enum.Material.Metal)
		local plate = k:trim("NamePlate", Vector3.new(2.8, 0.8, 0.1), CFrame.new(-4.7, 4.4, -1.85), C.brass, Enum.Material.Metal)
		Kit.label(plate, "SAHUR EXPRESS", C.black)

		-- The tender and its coal.
		k:box("Tender", Vector3.new(3.6, 3.2, 3.4), CFrame.new(-8.7, 4.5, 0), ENGINE_GREEN, Enum.Material.SmoothPlastic)
		for _, lump in ipairs({ { -8.7, 6.2, -0.6, 2 }, { -9.3, 6.3, 0.7, 1.8 }, { -8.1, 6.1, 0.5, 1.6 } }) do
			decor(k:ball("Coal", lump[4], CFrame.new(lump[1], lump[2], lump[3]), Color3.fromRGB(26, 26, 28), Enum.Material.Slate))
		end
	end

	local function railway(k)
		k:box("Ballast", Vector3.new(40, 0.6, 6), CFrame.new(0, 0.1, 6), BALLAST, Enum.Material.Pebble)
		for index = 0, 14 do
			k:trim("Sleeper", Vector3.new(1.2, 0.3, 5), CFrame.new(-18.2 + index * 2.6, 0.55, 6), SLEEPER, Enum.Material.Wood)
		end
		for _, z in ipairs({ 4.2, 7.8 }) do
			k:trim("Rail", Vector3.new(40, 0.5, 0.35), CFrame.new(0, 0.95, z), RAIL, Enum.Material.Metal)
		end
		-- Buffer stop at the end of the siding.
		for _, z in ipairs({ 4.5, 7.5 }) do
			k:box("BufferStopPost", Vector3.new(0.6, 3, 0.6), CFrame.new(19.2, 1.9, z), C.charcoal, Enum.Material.Metal)
		end
		k:box("BufferStopBeam", Vector3.new(0.8, 1, 4.4), CFrame.new(18.7, 2.6, 6), C.red, Enum.Material.Metal)
		for _, z in ipairs({ 4.9, 7.1 }) do
			k:trim("BufferStopHead", Vector3.new(0.5, 0.8, 0.8), CFrame.new(18.05, 2.6, z), C.white, Enum.Material.SmoothPlastic)
		end
	end

	local function platform(k)
		k:box("Platform", Vector3.new(24, 1.8, 4), CFrame.new(-6, 0.5, 0.5), Color3.fromRGB(170, 162, 148), Enum.Material.Concrete)
		-- Set into the platform (top 1.4) rather than level with it: at 1.43 the coping's top stood at
		-- 1.50 and the pass pulled it 0.22 clear on every build.
		k:trim("PlatformEdge", Vector3.new(23.9, 0.14, 0.7), CFrame.new(-6, 1.39, 2.05), C.yellow, Enum.Material.SmoothPlastic)
		for _, x in ipairs({ -9, 1 }) do
			k:box("PlatformStep", Vector3.new(5, 0.7, 1.2), CFrame.new(x, 0.35, -2.1), Color3.fromRGB(170, 162, 148), Enum.Material.Concrete)
		end

		-- The wake-up drum: at three in the morning it's the loudest thing for miles.
		local drum = k:at(CFrame.new(-15, 0, 0.5))
		for _, x in ipairs({ -2.7, 2.7 }) do
			drum:box("DrumStandPost", Vector3.new(0.4, 2.6, 0.4), CFrame.new(x, 2.7, 0), C.darkWood, Enum.Material.Wood)
			decor(drum:ball("DrumStandKnob", 0.6, CFrame.new(x, 4.1, 0), C.brass, Enum.Material.Metal))
		end
		drum:box("DrumCradle", Vector3.new(5.5, 0.5, 1.2), CFrame.new(0, 1.95, 0), C.darkWood, Enum.Material.Wood)
		local turned = CFrame.Angles(0, math.pi / 2, 0)
		drum:cyl("DrumBody", 3, 4.6, CFrame.new(0, 4.3, 0) * turned, Color3.fromRGB(190, 40, 40), Enum.Material.SmoothPlastic)
		for _, z in ipairs({ -1.25, 1.25 }) do
			decor(drum:cyl("DrumHoop", 0.35, 4.9, CFrame.new(0, 4.3, z) * turned, C.gold, Enum.Material.Metal))
		end
		local head = decor(drum:cyl("DrumHead", 0.1, 4.3, CFrame.new(0, 4.3, -1.57) * turned, C.cream, Enum.Material.Fabric))
		Kit.label(head, "WAKE UP!", Color3.fromRGB(160, 30, 30), nil, { Enum.NormalId.Right })
		for _, spec in ipairs({ { 3.2, -0.8, 2.1, 0.2 }, { 3.6, -0.4, 2.5, 0.6 } }) do
			local foot = Vector3.new(spec[1], 1.4, spec[2])
			local top = Vector3.new(spec[3], 5.2, spec[4])
			decor(drum:rod("Drumstick", foot, top, 0.3, C.wood, Enum.Material.Wood))
			decor(drum:ball("DrumstickTip", 0.6, CFrame.new(top), C.cream, Enum.Material.Fabric))
		end
		local plaque = drum:trim("DrumPlaque", Vector3.new(4, 0.9, 0.12), CFrame.new(0, 0.75, -2.06), C.brass, Enum.Material.Metal)
		Kit.label(plaque, "WAKE-UP DRUM  •  3:00 AM", C.black)

		-- Stood a tenth into the platform, so its foot isn't level with the edge coping's, and BEHIND the
		-- coping strip (z 1.7-2.4) rather than through it: at z 2.0 the post rose through the strip and its
		-- foot (1.30) sat 0.02 under the strip's underside (1.32), a flush pair on every build.
		Pieces.lantern(k:at(CFrame.new(-11, 1.3, 1.1)), 7.1, LAMP)

		-- The station's name board, and under it the train that never comes. Up high on tall posts, so
		-- from the street the engine is seen under them rather than hidden behind them.
		local boardKit = k:at(CFrame.new(-5, 1.4, 1.95))
		local nameBoard = boardKit:box("StationBoard", Vector3.new(9, 1.8, 0.3), CFrame.new(0, 8.0, 0), C.white, Enum.Material.SmoothPlastic)
		Kit.label(nameBoard, "SAHUR JUNCTION", C.black, C.white, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBlack)
		local times = boardKit:box("TimetableBoard", Vector3.new(8.4, 0.9, 0.25), CFrame.new(0, 6.45, 0), C.signBack, Enum.Material.SmoothPlastic)
		Kit.label(times, "NEXT TRAIN: 3:30 AM", LAMP, C.signBack, { Enum.NormalId.Front })
		for _, x in ipairs({ -4, 4 }) do
			-- The posts stand inside the coping strip's depth (world z 1.7-2.4), so every face has to clear
			-- four planes by 0.07: the strip's two faces, and the backs of the two boards (0.125 and 0.15).
			-- At z 0.32 the posts' backs were 0.02 inside the strip's back face. At z 0.20 (faces 0.05 and
			-- 0.35): 0.075 and 0.10 behind the boards' backs, 0.15 and 0.10 inside the strip's faces.
			boardKit:box("StationBoardPost", Vector3.new(0.3, 8.8, 0.3), CFrame.new(x, 4.2, 0.20), C.charcoal, Enum.Material.Metal)
		end
		Pieces.bench(k:at(CFrame.new(-5, 1.4, -0.1)), C.darkWood)

		-- A luggage trolley piled with somebody's cases.
		local trolley = k:at(CFrame.new(1.5, 1.4, 0.3))
		trolley:box("TrolleyBed", Vector3.new(3, 0.25, 1.8), CFrame.new(0, 0.8, 0), C.darkWood, Enum.Material.WoodPlanks)
		for _, x in ipairs({ -1.1, 1.1 }) do
			decor(trolley:cyl("TrolleyWheel", 0.3, 0.9, CFrame.new(x, 0.45, 0) * turned, C.black, Enum.Material.Rubber))
		end
		trolley:trim("TrolleyHandle", Vector3.new(0.2, 1.8, 1.8), CFrame.new(-1.6, 1.8, 0), C.charcoal, Enum.Material.Metal)
		-- Stacked: each case's bottom on the one below's top (the bed's top is 0.925 up).
		for index, case in ipairs({ { 0.2, 1.25, 2.2, 0.65, Color3.fromRGB(120, 60, 40) }, { 0.1, 1.875, 1.8, 0.6, Color3.fromRGB(60, 90, 130) },
			{ 0.3, 2.45, 1.5, 0.55, Color3.fromRGB(170, 140, 70) } }) do
			trolley:box("Suitcase", Vector3.new(case[3], case[4], 1.2), CFrame.new(case[1], case[2], 0) * CFrame.Angles(0, index * 0.12, 0), case[5], Enum.Material.Leather)
		end

		-- The station clock at the platform's end, stopped at sahur.
		local clock = k:at(CFrame.new(4.6, 1.4, 0.5))
		clock:post("StationClockPost", 6.2, 0.35, Vector3.zero, C.charcoal, Enum.Material.Metal)
		clock:box("StationClockCase", Vector3.new(2.6, 2.6, 0.8), CFrame.new(0, 7.5, 0), C.charcoal, Enum.Material.Metal)
		Pieces.clockFace(clock:at(CFrame.new(0, 7.5, -0.4)), 3, 0, 2.1)
		Pieces.clockFace(clock:at(CFrame.new(0, 7.5, 0.4) * CFrame.Angles(0, math.pi, 0)), 3, 0, 2.1)
	end

	local function signalBox(k)
		k:box("SignalBoxBase", Vector3.new(8, 7.4, 5.2), CFrame.new(0, 3.3, 0), BRICK, Enum.Material.Brick)
		k:trim("SignalBoxDoor", Vector3.new(1.8, 3.4, 0.2), CFrame.new(-2, 1.7, -2.7), C.darkWood, Enum.Material.WoodPlanks)
		k:trim("SignalBoxWindow", Vector3.new(2, 1.6, 0.2), CFrame.new(1.8, 3.6, -2.7), Color3.fromRGB(40, 44, 56), Enum.Material.Glass)
		k:box("SignalBoxFloor", Vector3.new(8.6, 0.5, 5.8), CFrame.new(0, 7.25, 0), C.darkWood, Enum.Material.WoodPlanks)
		for _, x in ipairs({ -3.95, 3.95 }) do
			for _, z in ipairs({ -2.55, 2.55 }) do
				k:box("SignalBoxPost", Vector3.new(0.5, 5.4, 0.5), CFrame.new(x, 10.2, z), C.cream, Enum.Material.Wood)
			end
		end
		-- Panels under the windows all round, then glass, then the roof.
		for side = 0, 3 do
			local along = side % 2 == 0
			local span = along and 7.4 or 4.6
			local offset = along and 2.55 or 3.95
			local face = k:at(CFrame.Angles(0, side * math.pi / 2, 0) * CFrame.new(0, 0, -offset))
			face:box("SignalBoxPanel", Vector3.new(span, 1.3, 0.25), CFrame.new(0, 8.15, 0), C.cream, Enum.Material.WoodPlanks)
			local glass = face:trim("SignalBoxGlass", Vector3.new(span, 3.6, 0.12), CFrame.new(0, 10.6, 0), Color3.fromRGB(170, 200, 220), Enum.Material.Glass)
			glass.Transparency = 0.55
		end
		k:box("SignalBoxEave", Vector3.new(9.4, 0.4, 6.6), CFrame.new(0, 13.1, 0), C.charcoal, Enum.Material.Slate)
		k:wedge("SignalBoxRoof", Vector3.new(9.4, 1.8, 3.3), CFrame.new(0, 14.2, -1.65), C.charcoal, Enum.Material.Slate)
		k:wedge("SignalBoxRoof", Vector3.new(9.4, 1.8, 3.3), CFrame.new(0, 14.2, 1.65) * CFrame.Angles(0, math.pi, 0), C.charcoal, Enum.Material.Slate)
		k:trim("SignalBoxRidge", Vector3.new(9.6, 0.3, 0.6), CFrame.new(0, 15.2, 0), C.black, Enum.Material.Metal)
		local name = k:trim("SignalBoxName", Vector3.new(5, 0.9, 0.12), CFrame.new(0, 8.2, -2.74), C.white, Enum.Material.SmoothPlastic)
		Kit.label(name, "SAHUR JCT", C.black, C.white)
		-- The lever frame, through the glass.
		local colors = { C.red, C.red, C.yellow, C.blue, C.black, C.red }
		for index, color in ipairs(colors) do
			k:trim("SignalLever", Vector3.new(0.25, 2, 0.25), CFrame.new(-2.5 + (index - 1), 8.5, 1.2) * CFrame.Angles(index % 2 == 0 and 0.35 or -0.2, 0, 0), color, Enum.Material.Metal)
		end
		k:truss("SignalBoxLadder", 8, Vector3.new(-5, 0, 0), C.charcoal)
	end

	-- A semaphore signal: a tall post, its arm dropped to "clear", the lamp and a ladder up the side.
	-- `side` is which way the arm reaches (1 is +X), so it can always point in over the site.
	local function semaphore(k, side)
		k:post("SemaphorePost", 17, 0.6, Vector3.zero, C.white, Enum.Material.Metal)
		k:ball("SemaphoreFinial", 0.9, CFrame.new(0, 17.3, 0), C.charcoal, Enum.Material.Metal)
		local arm = k:at(CFrame.new(side * 0.3, 15, -0.5) * CFrame.Angles(0, 0, math.rad(-40 * side)))
		arm:trim("SemaphoreArm", Vector3.new(3.8, 0.6, 0.15), CFrame.new(side * 1.9, 0, 0), C.red, Enum.Material.SmoothPlastic)
		arm:trim("SemaphoreStripe", Vector3.new(0.35, 0.72, 0.3), CFrame.new(side * 3.1, 0, 0), C.white, Enum.Material.SmoothPlastic)
		local lens = k:trim("SemaphoreLamp", Vector3.new(0.6, 0.6, 0.3), CFrame.new(0, 14.2, -0.55), Color3.fromRGB(80, 255, 120), Enum.Material.Neon)
		Kit.light(lens, Color3.fromRGB(80, 255, 120), 10, 0.8)
		for _, y in ipairs({ 3, 6, 9, 12 }) do
			k:trim("SemaphoreRung", Vector3.new(0.9, 0.12, 0.12), CFrame.new(0, y, 0.45), C.charcoal, Enum.Material.Metal)
		end
	end

	defineTheme({
		name = "Sahur Junction",
		id = "SahurJunction",
		flag = { emblem = "3:00", caption = "SAHUR JUNCTION", color = Color3.fromRGB(34, 88, 58), text = C.cream, trim = C.brass },
		setPiece = {
			id = "SignalBoxYard",
			name = "Sahur Junction Station",
			width = 40,
			depth = 30,
			ground = Enum.Material.Ground,
			build = function(k)
				railway(k)
				engine(k:at(CFrame.new(-6, 0, 6)))
				platform(k)
				signalBox(k:at(CFrame.new(13, 0, 12.2)))
				semaphore(k:at(CFrame.new(-19, 0, 11)), 1)
				semaphore(k:at(CFrame.new(19, 0, 0.8)), -1)
			end,
		},
		props = {
			{
				id = "RailwayLantern",
				radius = 1.8,
				build = function(k)
					Pieces.lantern(k, 7.5, LAMP)
				end,
			},
			{
				id = "LuggageCart",
				radius = 2.4,
				build = function(k)
					k:box("CartBed", Vector3.new(3.2, 0.3, 2), CFrame.new(0, 1.1, 0), C.darkWood, Enum.Material.WoodPlanks)
					for _, x in ipairs({ -1.2, 1.2 }) do
						decor(k:cyl("CartWheel", 0.3, 1.2, CFrame.new(x, 0.6, 0) * CFrame.Angles(0, math.pi / 2, 0), C.black, Enum.Material.Rubber))
					end
					k:box("CartCase", Vector3.new(2.2, 1, 1.4), CFrame.new(0.1, 1.75, 0), Color3.fromRGB(120, 60, 40), Enum.Material.Leather)
					k:box("CartCase", Vector3.new(1.4, 0.8, 1.1), CFrame.new(-0.2, 2.65, 0) * CFrame.Angles(0, 0.3, 0), Color3.fromRGB(60, 90, 130), Enum.Material.Leather)
					k:trim("CartHandle", Vector3.new(0.2, 1.6, 1.8), CFrame.new(-1.7, 2, 0), C.charcoal, Enum.Material.Metal)
				end,
			},
			{
				id = "WakeUpDrum",
				radius = 1.8,
				build = function(k)
					k:box("MiniDrumStand", Vector3.new(0.5, 1.4, 0.5), CFrame.new(0, 0.7, 0), C.darkWood, Enum.Material.Wood)
					local turned = CFrame.Angles(0, 0, math.pi / 2)
					k:cyl("MiniDrum", 1.8, 2.6, CFrame.new(0, 2.3, 0) * turned, Color3.fromRGB(190, 40, 40), Enum.Material.SmoothPlastic)
					decor(k:cyl("MiniDrumHead", 0.1, 2.4, CFrame.new(0, 3.24, 0) * turned, C.cream, Enum.Material.Fabric))
					for _, y in ipairs({ 1.5, 3.1 }) do
						decor(k:cyl("MiniDrumHoop", 0.25, 2.8, CFrame.new(0, y - 0.12, 0) * turned, C.gold, Enum.Material.Metal))
					end
					for _, x in ipairs({ -0.5, 0.5 }) do
						decor(k:rod("MiniDrumstick", Vector3.new(x, 3.3, -0.2), Vector3.new(x * 2.2, 4.4, -0.8), 0.18, C.wood, Enum.Material.Wood))
					end
				end,
			},
			{
				id = "CrossingSign",
				radius = 2.0,
				build = function(k)
					k:post("CrossingPost", 7, 0.35, Vector3.zero, C.white, Enum.Material.Metal)
					-- The crossed blades are left plain (words on both would cross each other out); the
					-- name goes on a plate under the lamps.
					for _, angle in ipairs({ 32, -32 }) do
						local blade = k:trim("CrossingBlade", Vector3.new(4.2, 0.7, 0.12), CFrame.new(0, 6, -0.3 - (angle > 0 and 0 or 0.2)) * CFrame.Angles(0, 0, math.rad(angle)),
							C.white, Enum.Material.SmoothPlastic)
						k:trim("CrossingStripe", Vector3.new(3.8, 0.3, 0.1), CFrame.new(0, 6, -0.3 - (angle > 0 and 0 or 0.2) - 0.1) * CFrame.Angles(0, 0, math.rad(angle)),
							C.red, Enum.Material.SmoothPlastic)
					end
					local plate = k:trim("CrossingPlate", Vector3.new(2.8, 0.8, 0.12), CFrame.new(0, 3.3, -0.3), C.white, Enum.Material.SmoothPlastic)
					Kit.label(plate, "SAHUR JCT", C.red, nil, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
					k:trim("CrossingLampBar", Vector3.new(2.6, 0.3, 0.2), CFrame.new(0, 4.3, -0.3), C.black, Enum.Material.Metal)
					for _, x in ipairs({ -1.1, 1.1 }) do
						local lamp = decor(k:ball("CrossingLamp", 0.7, CFrame.new(x, 4.3, -0.55), C.red, Enum.Material.Neon))
						Kit.light(lamp, C.red, 6, 0.6)
					end
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Rotville: the compost works, where everything goes to become worse
--------------------------------------------------------------------------------

do
	local RUST = Color3.fromRGB(128, 78, 48)
	local SLUDGE = Color3.fromRGB(130, 230, 60)
	local COMPOST = { Color3.fromRGB(120, 88, 56), Color3.fromRGB(138, 104, 64), Color3.fromRGB(104, 90, 54) }
	local MOULD = Color3.fromRGB(150, 170, 120)
	local OLD_WOOD = Color3.fromRGB(122, 98, 70)

	-- Flies: specks bobbing round `center`, each at its own pace.
	local function flies(k, center, count, spread)
		for index = 1, count do
			local offset = Vector3.new(k.rng:NextNumber(-spread, spread), k.rng:NextNumber(0, spread * 0.6), k.rng:NextNumber(-spread, spread))
			local fly = floating(decor(k:ball("Fly", 0.28, CFrame.new(center + offset), C.black, Enum.Material.SmoothPlastic)))
			Kit.bob(fly, 0.6, 3 + index * 0.37, index)
		end
	end

	local function stink(part, rate)
		Kit.emitter(part, { color = Color3.fromRGB(170, 190, 110), size = 1.2, size2 = 4, transparency = 0.7, lifetime = 3.5, rate = rate or 2,
			speed = 0.8, spread = 30, acceleration = Vector3.new(0, 0.4, 0) })
	end

	-- A sludge vat: a rusty tank banded twice, brimming with glowing green, bubbles breaking on top.
	local function vat(k, diameter, height)
		k:post("VatTank", height + 0.3, diameter, Vector3.new(0, -0.3, 0), RUST, Enum.Material.CorrodedMetal)
		for _, t in ipairs({ 0.3, 0.72 }) do
			decor(k:post("VatBand", 0.45, diameter + 0.3, Vector3.new(0, height * t, 0), C.iron, Enum.Material.Metal))
		end
		local sludge = decor(k:disc("Sludge", 0.3, diameter - 0.4, Vector3.new(0, height + 0.05, 0), SLUDGE, Enum.Material.Neon))
		Kit.light(sludge, SLUDGE, 14, 1.2)
		stink(sludge, 2)
		-- A lip of eight segments round the rim, alternate ones a touch taller, so no two tops or
		-- bottoms line up where the segments overlap at the joins.
		local radius = diameter / 2 - 0.12
		-- Short segments run 0 to 0.5 over the rim, tall ones 0.08 to 0.66; the sludge is -0.1 to 0.2.
		for index = 0, 7 do
			local tall = index % 2 == 1
			local size = Vector3.new(diameter * math.pi / 8 + 0.1, tall and 0.58 or 0.5, 0.45)
			k:trim("VatLip", size, CFrame.Angles(0, index * math.pi / 4, 0) * CFrame.new(0, height + (tall and 0.37 or 0.25), -radius), RUST, Enum.Material.CorrodedMetal)
		end
		for index = 1, 3 do
			local angle = k.rng:NextNumber(0, math.pi * 2)
			local reach = k.rng:NextNumber(0, diameter / 2 - 1.4)
			local bubble = floating(decor(k:ball("SludgeBubble", k.rng:NextNumber(0.5, 1.0),
				CFrame.new(math.cos(angle) * reach, height + 0.35, math.sin(angle) * reach), SLUDGE:Lerp(Color3.new(1, 1, 1), 0.25), Enum.Material.Neon)))
			bubble.Transparency = 0.2
			Kit.bob(bubble, 0.35, 1.4 + index * 0.5, index * 2)
		end
	end

	local function waterTower(k)
		local tower = k:at(CFrame.Angles(math.rad(3), 0, math.rad(-4)))
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				tower:box("TowerLeg", Vector3.new(0.8, 14.6, 0.8), CFrame.new(sx * 2.8, 7.0, sz * 2.8), RUST, Enum.Material.CorrodedMetal)
			end
		end
		-- Crossed braces on two faces, one of each pair set back a hair so they don't share a plane.
		for face = 0, 1 do
			local side = tower:at(CFrame.Angles(0, face * math.pi / 2, 0))
			decor(side:bar("TowerBrace", Vector3.new(-2.8, 1.2, -2.8), Vector3.new(2.8, 9.5, -2.8), 0.3, C.iron, Enum.Material.Metal))
			decor(side:bar("TowerBrace", Vector3.new(2.8, 1.2, -2.95), Vector3.new(-2.8, 9.5, -2.95), 0.3, C.iron, Enum.Material.Metal))
		end
		tower:post("TowerTank", 6, 8, Vector3.new(0, 14, 0), Color3.fromRGB(96, 128, 110), Enum.Material.CorrodedMetal)
		tower:disc("TowerRoof", 0.6, 8.6, Vector3.new(0, 20.3, 0), RUST, Enum.Material.CorrodedMetal)
		tower:disc("TowerRoofTop", 1.0, 5.4, Vector3.new(0, 21.1, 0), RUST, Enum.Material.CorrodedMetal)
		tower:ball("TowerFinial", 0.8, CFrame.new(0, 21.9, 0), C.iron, Enum.Material.Metal)
		local name = tower:trim("TowerName", Vector3.new(4.4, 1.6, 0.25), CFrame.new(0, 17.5, -4.0), Color3.fromRGB(226, 220, 196), Enum.Material.SmoothPlastic)
		Kit.label(name, "ROTVILLE", Color3.fromRGB(70, 120, 40))
		for index, length in ipairs({ 1.2, 2.2, 1.6 }) do
			tower:trim("SlimeDrip", Vector3.new(0.25, length, 0.12), CFrame.new(-1.4 + (index - 1) * 1.4, 16.7 - length / 2, -4.1), SLUDGE, Enum.Material.Neon)
		end
	end

	-- The compost bay: three sides of rough planks with gaps between (the back away from the street),
	-- heaped over the top with dark crumbly compost that spills out of the open front, the day's
	-- scraps on the surface, a pitchfork left in it and a thermometer reading far too hot.
	-- (Round 3: a heap of plain balls on open ground read as bread loaves; the slatted bay is what
	-- says "compost" at a glance.)
	local COMPOST_DARK = { Color3.fromRGB(84, 60, 40), Color3.fromRGB(98, 70, 46), Color3.fromRGB(70, 52, 36) }
	local BAY_HALF_X, BAY_HALF_Z = 4, 3

	local function compostHeap(k)
		for _, x in ipairs({ -BAY_HALF_X, BAY_HALF_X }) do
			for _, z in ipairs({ -BAY_HALF_Z, BAY_HALF_Z }) do
				k:box("BayPost", Vector3.new(0.5, 3.9, 0.5), CFrame.new(x, 1.75, z), OLD_WOOD:Lerp(C.black, 0.2), Enum.Material.Wood)
			end
		end
		-- Back planks are a touch taller than side planks, so their tops never share a plane at the corners.
		for row, y in ipairs({ 0.55, 1.45, 2.35 }) do
			local shade = OLD_WOOD:Lerp(C.black, (row % 2) * 0.12)
			k:box("BayPlank", Vector3.new(BAY_HALF_X * 2 + 0.1, 0.7, 0.25), CFrame.new(0, y, BAY_HALF_Z), shade, Enum.Material.WoodPlanks)
			for _, side in ipairs({ -1, 1 }) do
				k:box("BayPlank", Vector3.new(0.25, 0.56, BAY_HALF_Z * 2), CFrame.new(side * BAY_HALF_X, y, 0), shade, Enum.Material.WoodPlanks)
			end
		end

		-- The heap: highest at the back, slumping forward and out of the open front. Every lump inside
		-- the bay stays clear of the planks.
		local lumps = {
			{ -2.2, 1.5, 1.3, 3.0 }, { 0.2, 1.9, 1.3, 3.2 }, { 2.3, 1.4, 1.2, 2.8 },
			{ -2.4, 0.9, -0.4, 2.8 }, { -0.4, 1.4, -0.1, 3.4 }, { 1.9, 1.0, -0.3, 3.0 },
			{ -1.4, 0.4, -2.0, 2.6 }, { 1.0, 0.3, -2.2, 2.4 },
			{ -0.2, 0.05, -3.5, 2.0 }, { 2.3, 0.0, -3.4, 1.8 }, { -2.5, 0.0, -3.3, 1.6 },
		}
		local top
		for index, lump in ipairs(lumps) do
			-- Sand's texture keeps the browns warm; Ground's rendered them as grey boulders.
			local part = k:ball("CompostHeap", lump[4], CFrame.new(lump[1], lump[2], lump[3]), COMPOST_DARK[(index - 1) % #COMPOST_DARK + 1], Enum.Material.Sand)
			if index == 2 then
				top = part
			end
		end
		stink(top, 3)
		-- The surface of the heap straight above (x, z), so scraps sit on it rather than in or over it.
		local function surface(x, z)
			local height = 0
			for _, lump in ipairs(lumps) do
				local radius = lump[4] / 2
				local d2 = (x - lump[1]) ^ 2 + (z - lump[3]) ^ 2
				if d2 < radius * radius then
					height = math.max(height, lump[2] + math.sqrt(radius * radius - d2))
				end
			end
			return height
		end
		local function scrap(name, size, x, z, color, material)
			local at = CFrame.new(x, surface(x, z) - size.Y * 0.2, z) * CFrame.Angles(0.25, k.rng:NextNumber(0, math.pi * 2), 0.15)
			decor(k:box(name, size, at, color, material or Enum.Material.SmoothPlastic))
			return at
		end
		-- Clods turned every which way over the smooth lumps: a heap of plain spheres still read as
		-- loaves in the round-3 renders, and broken-up edges are what make it look dug over.
		for index, clod in ipairs({
			{ -1.9, 1.0, 1.9 }, { 0.4, 1.4, 1.6 }, { 2.0, 0.9, 1.5 }, { -2.2, -0.6, 1.5 }, { -0.7, 0.4, 2.1 },
			{ 1.5, 0.2, 1.7 }, { -1.5, -2.4, 1.4 }, { 0.8, -2.6, 1.3 }, { 2.4, -1.5, 1.2 }, { -2.7, -1.6, 1.2 },
		}) do
			local size = clod[3]
			decor(k:box("CompostClod", Vector3.new(size, size * 0.6, size * 0.85), CFrame.new(clod[1], surface(clod[1], clod[2]) - size * 0.22, clod[2])
				* CFrame.Angles(k.rng:NextNumber(-0.5, 0.5), k.rng:NextNumber(0, math.pi * 2), k.rng:NextNumber(-0.4, 0.4)),
				COMPOST_DARK[(index - 1) % #COMPOST_DARK + 1]:Lerp(C.black, 0.12), Enum.Material.Sand))
		end
		for _, spot in ipairs({ { -1.8, 0.6 }, { 0.9, 1.0 }, { 1.6, -1.2 }, { -0.8, -1.8 } }) do
			scrap("CabbageLeaf", Vector3.new(1.0, 0.1, 0.8), spot[1], spot[2], Color3.fromRGB(110, 160, 70), Enum.Material.Fabric)
		end
		for _, spot in ipairs({ { -0.2, 0.2 }, { 2.4, 0.4 } }) do
			scrap("OrangePeel", Vector3.new(0.9, 0.14, 0.5), spot[1], spot[2], Color3.fromRGB(232, 132, 42))
		end
		-- A banana peel with its two flaps splayed off the end (just clear of it, so no faces meet flush).
		local banana = scrap("BananaPeel", Vector3.new(1.3, 0.14, 0.4), -2.4, -1.2, Color3.fromRGB(214, 190, 70))
		for _, side in ipairs({ -1, 1 }) do
			-- One flap a little higher than the other, where their inner ends cross.
			decor(k:box("BananaFlap", Vector3.new(0.7, 0.1, 0.26), banana * CFrame.new(-1.05, side * 0.03, side * 0.2) * CFrame.Angles(0, side * 0.6, 0),
				Color3.fromRGB(190, 160, 60), Enum.Material.SmoothPlastic))
		end
		for _, spot in ipairs({ { 0.6, -0.6 }, { -1.1, 1.6 }, { 1.2, 1.9 } }) do
			decor(k:ball("EggShell", 0.42, CFrame.new(spot[1], surface(spot[1], spot[2]) + 0.05, spot[2]), Color3.fromRGB(240, 232, 214), Enum.Material.SmoothPlastic))
		end
		decor(k:ball("AppleCore", 0.7, CFrame.new(-0.6, surface(-0.6, 1.4) + 0.2, 1.4), Color3.fromRGB(200, 160, 100), Enum.Material.SmoothPlastic))
		for _, straw in ipairs({ { 1.2, -1.6, 0.8 }, { -2.0, -0.2, -0.6 }, { 0.3, 1.8, 2.2 } }) do
			decor(k:box("Straw", Vector3.new(0.2, 0.2, 2.0), CFrame.new(straw[1], surface(straw[1], straw[2]) + 0.05, straw[2]) * CFrame.Angles(0.25, straw[3], 0),
				Color3.fromRGB(220, 190, 100), Enum.Material.SmoothPlastic))
		end
		decor(k:box("FishBone", Vector3.new(1.6, 0.15, 0.15), CFrame.new(2.6, surface(2.6, -2.6) + 0.05, -2.6) * CFrame.Angles(0, 0.3, 0.2),
			Color3.fromRGB(230, 226, 214), Enum.Material.SmoothPlastic))

		-- A pitchfork left standing in it.
		local forkBase = Vector3.new(1.2, surface(1.2, 0.4) - 0.6, 0.4)
		decor(k:rod("PitchforkHandle", forkBase, forkBase + Vector3.new(1.6, 5.0, 1.1), 0.25, C.wood, Enum.Material.Wood))
		decor(k:trim("PitchforkHead", Vector3.new(1.4, 0.15, 0.15), CFrame.new(forkBase), C.iron, Enum.Material.Metal))
		-- A compost thermometer pushed into the top, dial to the street, needle past the red.
		local probeBase = Vector3.new(-1.2, surface(-1.2, -0.6) - 0.8, -0.6)
		decor(k:rod("ThermometerStem", probeBase, probeBase + Vector3.new(0, 3.2, 0), 0.14, C.iron, Enum.Material.Metal))
		local dial = decor(k:cyl("ThermometerDial", 0.2, 1.3, CFrame.new(probeBase + Vector3.new(0, 3.5, -0.05)) * CFrame.Angles(0, math.pi / 2, 0), C.cream, Enum.Material.SmoothPlastic))
		Kit.label(dial, "TOO RIPE", Color3.fromRGB(200, 40, 30), nil, { Enum.NormalId.Right }, Enum.Font.GothamBlack)
		-- 0.30 thick at z 0.06: at 0.24/0.02 its face sat 0.01 from the dial's, inside the pass's tolerance.
		decor(k:cyl("ThermometerRim", 0.30, 1.42, CFrame.new(probeBase + Vector3.new(0, 3.5, 0.06)) * CFrame.Angles(0, math.pi / 2, 0), C.iron, Enum.Material.Metal))
		flies(k, Vector3.new(0, surface(0, 0) + 1.2, 0), 8, 2.6)
	end

	local function fruitStall(k)
		k:box("StallCounter", Vector3.new(8, 3, 2.4), CFrame.new(0, 1.3, -1), OLD_WOOD, Enum.Material.WoodPlanks)
		for _, x in ipairs({ -3.8, 3.8 }) do
			decor(k:post("StallPost", 6.3, 0.35, Vector3.new(x, 0, -2.0), OLD_WOOD, Enum.Material.Wood))
			decor(k:post("StallPost", 7.1, 0.35, Vector3.new(x, 0, 1.8), OLD_WOOD, Enum.Material.Wood))
		end
		for index = 0, 4 do
			k:trim("StallAwning", Vector3.new(1.64, 0.25, 4.7), CFrame.new(-3.28 + index * 1.64, 6.6, -0.2) * CFrame.Angles(math.rad(-11.8), 0, 0),
				index % 2 == 0 and Color3.fromRGB(120, 82, 52) or Color3.fromRGB(118, 140, 78), Enum.Material.Fabric)
		end
		local fruitColors = { Color3.fromRGB(110, 90, 50), Color3.fromRGB(170, 130, 60), Color3.fromRGB(90, 60, 90) }
		for crate = 0, 2 do
			local x = -2.6 + crate * 2.6
			k:box("FruitCrate", Vector3.new(2.2, 0.9, 1.8), CFrame.new(x, 3.25, -1), OLD_WOOD:Lerp(C.black, 0.15), Enum.Material.WoodPlanks)
			for fruit = 0, 2 do
				local size = k.rng:NextNumber(0.75, 0.95)
				decor(k:ball("RottenFruit", size, CFrame.new(x - 0.6 + fruit * 0.6, 3.7 + size * 0.3, -1 + (fruit % 2) * 0.3), fruitColors[crate + 1], Enum.Material.SmoothPlastic))
			end
			decor(k:ball("Mould", 0.45, CFrame.new(x + 0.2, 4.2, -0.8), MOULD, Enum.Material.Sand))
		end
		k:ball("MouldyMelon", 2.6, CFrame.new(5.4, 1.1, -1), Color3.fromRGB(78, 120, 60), Enum.Material.SmoothPlastic)
		for index, spot in ipairs({ Vector3.new(4.6, 2.0, -1.6), Vector3.new(6.2, 1.8, -1.8), Vector3.new(5.6, 2.3, -0.2) }) do
			decor(k:ball("Mould", 0.6 + index * 0.1, CFrame.new(spot), MOULD, Enum.Material.Sand))
		end
		for _, x in ipairs({ -1.6, 1.6 }) do
			k:trim("PriceString", Vector3.new(0.08, 0.7, 0.08), CFrame.new(x, 5.75, -2.6), C.black, Enum.Material.Fabric)
		end
		local price = k:trim("PriceBoard", Vector3.new(4, 1, 0.2), CFrame.new(0, 4.9, -2.6), C.cream, Enum.Material.WoodPlanks)
		Kit.label(price, "FRESH-ISH", Color3.fromRGB(90, 120, 40), nil, { Enum.NormalId.Front, Enum.NormalId.Back })
		-- A chalk board standing out front.
		for _, side in ipairs({ -1, 1 }) do
			-- The two boards of an A-frame differ in width, so their edges never share a plane.
			local board = k:box("ChalkBoard", Vector3.new(side < 0 and 2.4 or 2.2, 3, 0.2), CFrame.new(-6, 1.45, -3.6 + side * 0.4) * CFrame.Angles(math.rad(side * 14), 0, 0),
				Color3.fromRGB(40, 48, 44), Enum.Material.Slate)
			if side < 0 then
				Kit.label(board, "50% MOULD FREE", C.white, nil, { Enum.NormalId.Front }, Enum.Font.PermanentMarker)
			end
		end
	end

	defineTheme({
		name = "Rotville",
		id = "Rotville",
		flag = { emblem = "ROT", caption = "ROTVILLE", color = Color3.fromRGB(78, 96, 42), text = SLUDGE, trim = RUST },
		setPiece = {
			id = "CompostWorks",
			name = "Rotville Compost Works",
			width = 36,
			depth = 30,
			ground = Enum.Material.Mud,
			build = function(k)
				vat(k:at(CFrame.new(-11, 0, 6)), 8, 7)
				vat(k:at(CFrame.new(-1.5, 0, 8)), 9, 8.5)
				k:truss("VatLadder", 8, Vector3.new(-1.5, 0, 2.5), RUST)
				decor(k:rod("SludgePipe", Vector3.new(-7.4, 3.2, 6.8), Vector3.new(-5.8, 3.2, 7.4), 0.8, C.iron, Enum.Material.Metal))
				decor(k:rod("SludgePipe", Vector3.new(3.0, 5, 9.4), Vector3.new(7.9, 5, 10.7), 0.8, C.iron, Enum.Material.Metal))
				waterTower(k:at(CFrame.new(11, 0, 8)))
				compostHeap(k:at(CFrame.new(-10, 0, -7)))
				fruitStall(k:at(CFrame.new(8, 0, -7.6)))
				for _, spot in ipairs({ { -5.2, -0.8, 2.6 }, { 4.6, 2.4, 3.2 }, { -16, 12.4, 2.4 } }) do
					local puddle = decor(k:disc("SlimePuddle", 0.22, spot[3], Vector3.new(spot[1], 0.1, spot[2]), SLUDGE, Enum.Material.Neon))
					puddle.Transparency = 0.15
				end
				-- The works' sign, one post sunk further than the other.
				local sign = k:at(CFrame.new(0, 0, -12.8) * CFrame.Angles(0, 0, math.rad(4)))
				local board = Pieces.board(sign, "ROTVILLE COMPOST WORKS", 12, 2.2, 3.6, SLUDGE, Color3.fromRGB(46, 40, 30), 2, OLD_WOOD)
				board.Name = "WorksSign"
				-- A fence along the back with a warning on it.
				for index = 0, 6 do
					k:box("FencePost", Vector3.new(0.4, 5.3, 0.4), CFrame.new(-16 + index * 16 / 3, 2.35, 14.2), RUST, Enum.Material.CorrodedMetal)
				end
				for _, y in ipairs({ 1.5, 4.5 }) do
					k:trim("FenceRail", Vector3.new(32.2, 0.2, 0.2), CFrame.new(0, y, 14.2), RUST, Enum.Material.CorrodedMetal)
				end
				local keepOut = k:trim("FenceSign", Vector3.new(4, 1.4, 0.12), CFrame.new(6, 3, 13.9), C.yellow, Enum.Material.SmoothPlastic)
				Kit.label(keepOut, "DO NOT SNIFF", C.black)
			end,
		},
		props = {
			{
				id = "OverflowingBin",
				radius = 2.3,
				build = function(k)
					k:post("BinBody", 3.2, 2.4, Vector3.zero, Color3.fromRGB(54, 80, 58), Enum.Material.Metal)
					k:disc("BinLid", 0.25, 2.7, Vector3.new(0.9, 3.9, 0.6), Color3.fromRGB(40, 64, 46), Enum.Material.Metal).CFrame *= CFrame.Angles(0, 0, 0.9)
					local colors = { Color3.fromRGB(110, 104, 96), COMPOST[2], Color3.fromRGB(96, 120, 70), COMPOST[1] }
					for index, spot in ipairs({ { -0.4, 3.4, -0.2, 1.2 }, { 0.5, 3.5, 0.3, 1.0 }, { 0.0, 3.9, 0.1, 0.9 }, { -0.7, 3.25, 0.7, 0.8 } }) do
						decor(k:ball("Trash", spot[4], CFrame.new(spot[1], spot[2], spot[3]), colors[index], Enum.Material.Fabric))
					end
					flies(k, Vector3.new(0, 4.6, 0), 2, 0.9)
				end,
			},
			{
				id = "SlimeBarrel",
				radius = 2.6,
				build = function(k)
					k:post("SlimeBarrel", 3.4, 2.4, Vector3.zero, RUST, Enum.Material.CorrodedMetal)
					for _, y in ipairs({ 0.7, 2.4 }) do
						decor(k:post("BarrelBand", 0.3, 2.55, Vector3.new(0, y, 0), C.iron, Enum.Material.Metal))
					end
					local ooze = decor(k:disc("BarrelOoze", 0.2, 2.1, Vector3.new(0, 3.45, 0), SLUDGE, Enum.Material.Neon))
					Kit.light(ooze, SLUDGE, 8, 0.8)
					for index, length in ipairs({ 1.6, 2.4 }) do
						local angle = -0.4 + index * 0.6
						k:trim("OozeDrip", Vector3.new(0.3, length, 0.14), CFrame.Angles(0, angle, 0) * CFrame.new(0, 3.3 - length / 2, -1.25), SLUDGE, Enum.Material.Neon)
					end
					local puddle = decor(k:disc("SlimePuddle", 0.2, 2.8, Vector3.new(-0.6, 0.17, -1.1), SLUDGE, Enum.Material.Neon))
					puddle.Transparency = 0.15
				end,
			},
			{
				id = "MouldyCrates",
				radius = 2.6,
				build = function(k)
					k:box("MouldyCrate", Vector3.new(2.4, 2.4, 2.4), CFrame.new(-0.9, 1.2, 0), OLD_WOOD, Enum.Material.WoodPlanks)
					k:box("MouldyCrate", Vector3.new(2.2, 2.2, 2.2), CFrame.new(-0.8, 3.5, 0.1) * CFrame.Angles(0, 0.3, 0), OLD_WOOD:Lerp(C.black, 0.1), Enum.Material.WoodPlanks)
					local stamped = k:box("MouldyCrate", Vector3.new(2, 2, 2), CFrame.new(1.4, 0.93, -0.2) * CFrame.Angles(0, -0.2, 0), OLD_WOOD:Lerp(C.black, 0.2), Enum.Material.WoodPlanks)
					Kit.label(stamped, "EXPIRED", C.red, nil, { Enum.NormalId.Front })
					for _, spot in ipairs({ { -2.05, 2.3, -0.8, 0.9 }, { 0.3, 2.5, -0.9, 0.7 }, { -1.6, 4.6, 0.8, 0.8 }, { 2.4, 1.9, 0.6, 0.6 } }) do
						decor(k:ball("Mould", spot[4], CFrame.new(spot[1], spot[2], spot[3]), MOULD, Enum.Material.Sand))
					end
				end,
			},
			{
				id = "RotSign",
				radius = 1.6,
				build = function(k)
					local lines = { "SMELL YOU LATER", "FRESH ROT DAILY", "ALL ROADS LEAD TO ROT", "BEST BEFORE: NEVER" }
					local sign = k:at(CFrame.Angles(0, 0, math.rad(k.rng:NextNumber(-8, 8))))
					local board = Pieces.board(sign, lines[k.rng:NextInteger(1, #lines)], 3, 1.4, 3, Color3.fromRGB(70, 120, 40), C.cream, 1, OLD_WOOD)
					board.Name = "RotSign"
				end,
			},
			{
				id = "SlimePuddle",
				radius = 2.2,
				build = function(k)
					local puddle = decor(k:disc("SlimePuddle", 0.22, 3.8, Vector3.new(0, 0.1, 0), SLUDGE, Enum.Material.Neon))
					puddle.Transparency = 0.1
					Kit.light(puddle, SLUDGE, 8, 0.6)
					for index = 1, 3 do
						local bubble = floating(decor(k:ball("SludgeBubble", 0.45 + index * 0.12, CFrame.new(-0.9 + index * 0.6, 0.35, (index % 2) * 0.8 - 0.4), SLUDGE, Enum.Material.Neon)))
						Kit.bob(bubble, 0.25, 1.8 + index * 0.4, index)
					end
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Bonkington: the town that settles everything with a very large mallet
--------------------------------------------------------------------------------

do
	local FAIR_RED = Color3.fromRGB(200, 50, 46)
	local FAIR_YELLOW = Color3.fromRGB(250, 204, 60)
	local FOAM = { Color3.fromRGB(255, 90, 120), Color3.fromRGB(80, 170, 255), Color3.fromRGB(120, 220, 110), Color3.fromRGB(255, 170, 50) }

	-- A mallet whose handle runs from `grip` to `headAt`, with the head's barrel lying along `across`.
	-- Decoration unless `solid`.
	local function mallet(k, grip, headAt, across, headLength, headDiameter, color, solid)
		local handle = k:rod("MalletHandle", grip, headAt, headDiameter * 0.28, C.wood, Enum.Material.Wood)
		local head = k:cyl("MalletHead", headLength, headDiameter, CFrame.lookAt(headAt, headAt + across) * CFrame.Angles(0, math.pi / 2, 0), color, Enum.Material.SmoothPlastic)
		for _, side in ipairs({ -1, 1 }) do
			local capAt = headAt + across.Unit * side * (headLength / 2 + 0.15)
			decor(k:cyl("MalletCap", 0.3, headDiameter * 0.92, CFrame.lookAt(capAt, capAt + across) * CFrame.Angles(0, math.pi / 2, 0), C.black, Enum.Material.Rubber))
		end
		if not solid then
			decor(handle)
			decor(head)
		end
		return head
	end

	local function highStriker(k)
		k:box("StrikerStage", Vector3.new(10, 1.2, 6), CFrame.new(0, 0.3, 0), FAIR_RED, Enum.Material.WoodPlanks)
		k:trim("StrikerTrim", Vector3.new(10.2, 0.25, 6.2), CFrame.new(0, 0.675, 0), FAIR_YELLOW, Enum.Material.SmoothPlastic)
		k:box("StrikePad", Vector3.new(3, 0.4, 3), CFrame.new(-1.2, 1.1, -1.2), C.charcoal, Enum.Material.Rubber)
		decor(k:disc("StrikeTarget", 0.1, 2, Vector3.new(-1.2, 1.35, -1.2), FAIR_RED, Enum.Material.SmoothPlastic))

		k:box("StrikerTower", Vector3.new(4.4, 26, 0.8), CFrame.new(0, 13.9, 2.4), C.white, Enum.Material.WoodPlanks)
		k:trim("StrikerRail", Vector3.new(0.7, 24, 0.2), CFrame.new(-1.2, 13.4, 1.9), FAIR_RED, Enum.Material.Metal)
		local marks = { { 6, "WEAK", Color3.fromRGB(110, 200, 90) }, { 11.5, "MEH", Color3.fromRGB(250, 220, 70) }, { 17, "STRONG", Color3.fromRGB(250, 150, 50) }, { 22.5, "BONK!", FAIR_RED } }
		for _, mark in ipairs(marks) do
			local board = k:trim("StrikerMark", Vector3.new(2.4, 1.8, 0.12), CFrame.new(0.8, mark[1], 1.94), mark[3], Enum.Material.SmoothPlastic)
			Kit.label(board, mark[2], C.white)
		end
		-- The puck rides the rail up and down forever, never quite ringing the bell.
		local puck = floating(decor(k:ball("StrikerPuck", 1.1, CFrame.new(-1.2, 12, 1.3), C.charcoal, Enum.Material.Metal)))
		Kit.bob(puck, 8.5, 1.3, 0)
		k:trim("BellBracket", Vector3.new(1.4, 0.4, 1), CFrame.new(-1.2, 26.9, 1.6), C.iron, Enum.Material.Metal)
		decor(k:ball("StrikerBell", 2.2, CFrame.new(-1.2, 25.9, 1.1), C.gold, Enum.Material.Foil))
		local crown = k:trim("StrikerCrown", Vector3.new(7, 2.2, 0.4), CFrame.new(0, 28.2, 2.4), FAIR_RED, Enum.Material.SmoothPlastic)
		Kit.label(crown, "TEST YOUR BONK", FAIR_YELLOW, FAIR_RED, { Enum.NormalId.Front, Enum.NormalId.Back })
		for index = 0, 6 do
			local bulb = decor(k:ball("CrownBulb", 0.45, CFrame.new(-3 + index, 29.55, 2.4), index % 2 == 0 and FAIR_YELLOW or C.white, Enum.Material.Neon))
			if index == 3 then
				Kit.light(bulb, FAIR_YELLOW, 16, 1)
			end
		end
		-- The mallet, propped against the tower for the next contestant.
		mallet(k, Vector3.new(4.9, 1.0, -0.6), Vector3.new(3.4, 10.4, 1.3), Vector3.new(1, 0.15, 0), 4.6, 2.8, FAIR_RED, false)
	end

	-- A mallet driven head-first into the ground, the paving cracked in a ring round it.
	local function plantedMallet(k)
		decor(k:disc("CraterFloor", 0.2, 5.4, Vector3.new(0, 0.08, 0), Color3.fromRGB(62, 58, 56), Enum.Material.Basalt))
		for index = 0, 7 do
			local angle = index * math.pi / 4 + 0.2
			k:box("CraterShard", Vector3.new(2.8, 0.6, 1.5), CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.25, -3.3) * CFrame.Angles(math.rad(-16), 0, 0),
				Color3.fromRGB(98, 94, 90), Enum.Material.Slate)
		end
		local head = k:cyl("MalletHead", 6, 3.6, CFrame.new(0, 0.9, 0) * CFrame.Angles(0, 0.4, math.rad(8)), FOAM[1], Enum.Material.SmoothPlastic)
		head.Name = "PlantedMalletHead"
		decor(k:rod("MalletHandle", Vector3.new(0, 2.2, 0), Vector3.new(-1.4, 13, 1.1), 1.1, C.wood, Enum.Material.Wood))
		k:ball("MalletGrip", 1.5, CFrame.new(-1.45, 13.1, 1.14), C.black, Enum.Material.Rubber)
		-- The sound effect, frozen.
		-- Off to the side of the striker: in front of it, the star covered the strength marks.
		local burst = k:at(CFrame.new(8.2, 0, -3.2))
		burst:post("BurstPost", 5, 0.3, Vector3.zero, C.iron, Enum.Material.Metal)
		burst:trim("BurstStar", Vector3.new(3.4, 3.4, 0.2), CFrame.new(0, 6.4, 0) * CFrame.Angles(0, 0, math.pi / 4), FAIR_YELLOW, Enum.Material.SmoothPlastic)
		local word = burst:trim("BurstWord", Vector3.new(3.4, 3.4, 0.2), CFrame.new(0, 6.4, -0.22), Color3.fromRGB(255, 140, 50), Enum.Material.SmoothPlastic)
		Kit.label(word, "BONK!", C.white, nil, { Enum.NormalId.Front, Enum.NormalId.Back })
	end

	-- Whack-a-rot: six critters popping up and down out of a cabinet.
	local function whackCabinet(k)
		k:box("WhackCabinet", Vector3.new(8, 3, 4.4), CFrame.new(0, 1.3, 0), FAIR_RED, Enum.Material.SmoothPlastic)
		k:trim("WhackTop", Vector3.new(8.2, 0.2, 4.6), CFrame.new(0, 2.9, 0), FAIR_YELLOW, Enum.Material.SmoothPlastic)
		local index = 0
		for row = 0, 1 do
			for column = 0, 2 do
				index += 1
				local at = Vector3.new(-2.6 + column * 2.6, 3.02, -1 + row * 2)
				decor(k:disc("WhackHole", 0.06, 1.5, at + Vector3.new(0, 0.04, 0), C.black, Enum.Material.SmoothPlastic))
				local color = FOAM[(index - 1) % #FOAM + 1]
				local critter = floating(decor(k:ball("WhackCritter", 1.2, CFrame.new(at + Vector3.new(0, 0.35, 0)), color, Enum.Material.SmoothPlastic)))
				Kit.bob(critter, 0.45, 2.6 + index * 0.3, index * 1.3)
				for _, dx in ipairs({ -0.22, 0.22 }) do
					local eye = floating(decor(k:ball("WhackEye", 0.22, CFrame.new(at + Vector3.new(dx, 0.55, -0.52)), C.black, Enum.Material.SmoothPlastic)))
					Kit.bob(eye, 0.45, 2.6 + index * 0.3, index * 1.3)
				end
			end
		end
		-- Posts behind the board, so they don't cover its first and last letters.
		for _, x in ipairs({ -3.6, 3.6 }) do
			k:box("MarqueePost", Vector3.new(0.4, 4.4, 0.4), CFrame.new(x, 5.1, 2.3), C.iron, Enum.Material.Metal)
		end
		local marquee = k:trim("WhackMarquee", Vector3.new(8, 1.8, 0.2), CFrame.new(0, 6.6, 2.0), C.signBack, Enum.Material.SmoothPlastic)
		Kit.label(marquee, "WHACK-A-ROT", FAIR_YELLOW, C.signBack, { Enum.NormalId.Front, Enum.NormalId.Back })
		mallet(k, Vector3.new(2.6, 3.2, 1.4), Vector3.new(3.4, 3.35, -0.2), Vector3.new(1, 0, 0.1), 1.6, 1.0, FOAM[2], false)
	end

	local function helmetRack(k)
		for _, x in ipairs({ -2.6, 2.6 }) do
			k:box("RackPost", Vector3.new(0.4, 4.4, 0.4), CFrame.new(x, 2.0, 0), C.iron, Enum.Material.Metal)
		end
		-- Proud of the posts (tops at 4.2) rather than level with them.
		k:trim("RackBar", Vector3.new(5.4, 0.3, 0.3), CFrame.new(0, 4.45, 0), C.iron, Enum.Material.Metal)
		for index = 0, 2 do
			local color = FOAM[index + 1]
			decor(k:ball("Helmet", 1.6, CFrame.new(-1.7 + index * 1.7, 3.55, 0), color, Enum.Material.SmoothPlastic))
			k:trim("HelmetBrim", Vector3.new(1.7, 0.15, 0.7), CFrame.new(-1.7 + index * 1.7, 3.2, -0.75), color, Enum.Material.SmoothPlastic)
		end
		local sign = k:trim("HelmetSign", Vector3.new(5.2, 1.4, 0.15), CFrame.new(0, 5.3, 0), FAIR_YELLOW, Enum.Material.SmoothPlastic)
		Kit.label(sign, "BONK ZONE: HELMETS REQUIRED", C.black, nil, { Enum.NormalId.Front, Enum.NormalId.Back })
	end

	local function paddedBollard(k)
		k:post("PaddedBollard", 3, 1.4, Vector3.zero, FAIR_RED, Enum.Material.Fabric)
		for _, y in ipairs({ 0.8, 2.0 }) do
			decor(k:post("BollardFoam", 0.5, 1.6, Vector3.new(0, y, 0), FAIR_YELLOW, Enum.Material.Fabric))
		end
		k:ball("BollardCushion", 1.5, CFrame.new(0, 3.1, 0), FAIR_YELLOW, Enum.Material.Fabric)
	end

	defineTheme({
		name = "Bonkington",
		id = "Bonkington",
		flag = { emblem = "BONK", caption = "BONKINGTON", color = FAIR_RED, text = FAIR_YELLOW, trim = FAIR_YELLOW },
		setPiece = {
			id = "BonkGrounds",
			name = "The Bonk Grounds",
			width = 32,
			depth = 28,
			ground = Enum.Material.WoodPlanks,
			build = function(k)
				highStriker(k:at(CFrame.new(0, 0, 8)))
				plantedMallet(k:at(CFrame.new(-8, 0, -5)))
				whackCabinet(k:at(CFrame.new(9, 0, -5)))
				helmetRack(k:at(CFrame.new(-11, 0, 10)))
				for _, x in ipairs({ -4, 0, 4 }) do
					paddedBollard(k:at(CFrame.new(x, 0, -12.4)))
				end
			end,
		},
		props = {
			{ id = "PaddedBollard", radius = 1.0, build = paddedBollard },
			{
				id = "BonkZoneSign",
				radius = 2.4,
				build = function(k)
					local board = Pieces.board(k, "BONK ZONE", 4.2, 1.8, 2.4, C.black, FAIR_YELLOW, 2, C.iron)
					board.Name = "BonkZoneSign"
				end,
			},
			{
				id = "FoamMalletStand",
				radius = 1.9,
				build = function(k)
					k:post("MalletBucket", 1.8, 1.8, Vector3.zero, C.charcoal, Enum.Material.Metal)
					for index = 0, 2 do
						local angle = index * math.pi * 2 / 3
						local lean = Vector3.new(math.cos(angle) * 0.9, 0, math.sin(angle) * 0.9)
						local headAt = Vector3.new(0, 4.6, 0) + lean
						mallet(k, Vector3.new(0, 1.2, 0) + lean * 0.2, headAt, Vector3.new(-lean.Z, 0, lean.X), 1.6, 1.0, FOAM[index + 1], false)
					end
				end,
			},
			{
				id = "CushionPile",
				radius = 2.4,
				build = function(k)
					for index = 0, 3 do
						k:box("Cushion", Vector3.new(3.6 - index * 0.4, 0.9, 2.8 - index * 0.3), CFrame.new(0, 0.45 + index * 0.9, 0) * CFrame.Angles(0, index * 0.35, 0),
							FOAM[index + 1], Enum.Material.Fabric)
					end
					local tag = k:trim("CushionTag", Vector3.new(2.2, 0.8, 0.1), CFrame.new(0, 0.5, -1.46), C.white, Enum.Material.SmoothPlastic)
					Kit.label(tag, "SOFT LANDING", C.black)
				end,
			},
			{
				id = "BonkBell",
				radius = 1.9,
				build = function(k)
					k:post("BellPost", 5.4, 0.4, Vector3.zero, C.iron, Enum.Material.Metal)
					k:trim("BellArm", Vector3.new(0.3, 0.3, 1.4), CFrame.new(0, 5.1, -0.6), C.iron, Enum.Material.Metal)
					decor(k:ball("HandBell", 1.3, CFrame.new(0, 4.5, -1.2), C.gold, Enum.Material.Foil))
					local sign = k:trim("BellSign", Vector3.new(2.4, 0.9, 0.12), CFrame.new(0, 2.6, -0.27), C.white, Enum.Material.SmoothPlastic)
					Kit.label(sign, "RING FOR BONK", FAIR_RED)
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Aura Farms: where aura is grown, harvested and counted
--------------------------------------------------------------------------------

do
	local AURA = { Color3.fromRGB(190, 120, 255), Color3.fromRGB(110, 230, 255), Color3.fromRGB(255, 214, 90), Color3.fromRGB(255, 140, 220) }
	local SOIL = Color3.fromRGB(80, 58, 40)
	local BED_WOOD = Color3.fromRGB(150, 110, 70)
	local LILAC = Color3.fromRGB(228, 220, 244)

	local function sparkle(part, color)
		Kit.emitter(part, { color = color, size = 0.35, size2 = 0.05, transparency = 0.1, lifetime = 1.8, rate = 6, speed = 1.2, spread = 60,
			lightEmission = 1, acceleration = Vector3.new(0, 1.2, 0) })
	end

	local function cropBed(k, length, plants, offset)
		k:box("CropBed", Vector3.new(length, 1.0, 3.2), CFrame.new(0, 0.3, 0), BED_WOOD, Enum.Material.WoodPlanks)
		local soil = k:trim("CropSoil", Vector3.new(length - 0.6, 0.2, 2.6), CFrame.new(0, 0.85, 0), SOIL, Enum.Material.Ground)
		sparkle(soil, AURA[offset % #AURA + 1])
		for index = 0, plants - 1 do
			local x = -length / 2 + (index + 0.5) * length / plants
			local height = 1.6 + ((index + offset) % 3) * 0.4
			local color = AURA[(index + offset) % #AURA + 1]
			decor(k:post("AuraStem", height, 0.22, Vector3.new(x, 0.9, 0), Color3.fromRGB(80, 150, 70), Enum.Material.SmoothPlastic))
			k:trim("AuraLeaf", Vector3.new(1.4, 0.1, 0.45), CFrame.new(x, 1.35 + height * 0.3, 0) * CFrame.Angles(0, index * 0.9, 0.25), Color3.fromRGB(90, 170, 80), Enum.Material.SmoothPlastic)
			local bulb = decor(k:ball("AuraBulb", 1.0, CFrame.new(x, 0.9 + height + 0.35, 0), color, Enum.Material.Neon))
			if index % 3 == 1 then
				Kit.light(bulb, color, 8, 0.7)
			end
		end
	end

	local function auraSilo(k)
		k:post("AuraSilo", 18.3, 8, Vector3.new(0, -0.3, 0), LILAC, Enum.Material.Marble)
		k:ball("AuraSiloDome", 8, CFrame.new(0, 18, 0), Color3.fromRGB(205, 190, 235), Enum.Material.Marble)
		for index = 0, 2 do
			k:trim("AuraSiloWindow", Vector3.new(0.9, 2.6, 0.3), CFrame.new(0, 5 + index * 4.4, -3.95), AURA[index + 1], Enum.Material.Neon)
		end
		k:trim("AuraSiloDoor", Vector3.new(2.6, 3.8, 0.3), CFrame.Angles(0, math.rad(-35), 0) * CFrame.new(0, 1.9, -3.95), C.darkWood, Enum.Material.WoodPlanks)
		-- The halo: twelve glowing segments on a tilted hub that turns.
		local hub = floating(k:hub("HaloHub", CFrame.new(0, 25.5, 0) * CFrame.Angles(math.rad(8), 0, math.rad(-5))))
		local halo = k:into(hub):at(CFrame.new(0, 25.5, 0) * CFrame.Angles(math.rad(8), 0, math.rad(-5)))
		for index = 0, 11 do
			local segment = floating(halo:trim("HaloSegment", Vector3.new(2.5, 0.4, 0.4), CFrame.Angles(0, index * math.pi / 6, 0) * CFrame.new(0, (index % 2) * 0.08, -4.6),
				Color3.fromRGB(255, 226, 120), Enum.Material.Neon))
			if index == 0 then
				Kit.light(segment, Color3.fromRGB(255, 226, 120), 22, 1.4)
			end
		end
		Kit.spin(hub, 30)
	end

	local function scoreboard(k)
		for _, x in ipairs({ -4.4, 4.4 }) do
			k:box("ScoreboardLeg", Vector3.new(0.6, 9.6, 0.6), CFrame.new(x, 4.5, 0.5), C.iron, Enum.Material.Metal)
		end
		local board = k:box("AuraScoreboard", Vector3.new(10, 4, 0.5), CFrame.new(0, 7.5, 0), Color3.fromRGB(46, 28, 70), Enum.Material.SmoothPlastic)
		Kit.label(board, "AURA HARVESTED TODAY\n+999,999", Color3.fromRGB(255, 214, 90), Color3.fromRGB(46, 28, 70), { Enum.NormalId.Front, Enum.NormalId.Back })
		Kit.light(board, Color3.fromRGB(190, 120, 255), 14, 1)
		for index = 0, 8 do
			decor(k:ball("ScoreBulb", 0.45, CFrame.new(-4.4 + index * 1.1, 9.75, 0), AURA[index % #AURA + 1], Enum.Material.Neon))
		end
	end

	local function auraScarecrow(k)
		k:post("ScarecrowPole", 8.4, 0.5, Vector3.new(0, -0.4, 0), C.darkWood, Enum.Material.Wood)
		k:trim("ScarecrowArms", Vector3.new(6, 0.4, 0.4), CFrame.new(0, 5.6, 0), C.darkWood, Enum.Material.Wood)
		k:box("ScarecrowCoat", Vector3.new(2.6, 3, 1.4), CFrame.new(0, 5, 0), Color3.fromRGB(120, 80, 170), Enum.Material.Fabric)
		decor(k:ball("ScarecrowHead", 1.6, CFrame.new(0, 7.3, 0), Color3.fromRGB(214, 186, 96), Enum.Material.Fabric))
		decor(k:disc("ScarecrowHatBrim", 0.2, 2.6, Vector3.new(0, 8.0, 0), Color3.fromRGB(70, 50, 30), Enum.Material.Fabric))
		decor(k:post("ScarecrowHat", 1, 1.4, Vector3.new(0, 8.1, 0), Color3.fromRGB(70, 50, 30), Enum.Material.Fabric))
		local glow = decor(k:ball("AuraGlow", 6, CFrame.new(0, 5.8, 0), Color3.fromRGB(255, 220, 110), Enum.Material.Neon))
		glow.Transparency = 0.85
		glow.CastShadow = false
		sparkle(glow, Color3.fromRGB(255, 220, 110))
	end

	local function orbCrate(k)
		k:box("OrbCrate", Vector3.new(2.4, 1.8, 2.4), CFrame.new(0, 0.9, 0), BED_WOOD, Enum.Material.WoodPlanks)
		for index = 0, 2 do
			local orb = decor(k:ball("AuraOrb", 0.95, CFrame.new(-0.6 + index * 0.6, 1.9, (index % 2) * 0.5 - 0.25), AURA[index + 1], Enum.Material.Neon))
			if index == 1 then
				Kit.light(orb, AURA[2], 7, 0.6)
			end
		end
	end

	local function auraMeter(k)
		k:box("MeterBase", Vector3.new(2.6, 1, 2.6), CFrame.new(0, 0.3, 0), C.charcoal, Enum.Material.Metal)
		local tube = decor(k:post("MeterTube", 9, 1.3, Vector3.new(0, 0.8, 0), C.white, Enum.Material.Glass))
		tube.Transparency = 0.6
		local fills = { Color3.fromRGB(110, 230, 255), Color3.fromRGB(190, 120, 255), Color3.fromRGB(255, 214, 90) }
		for index, color in ipairs(fills) do
			decor(k:post("MeterFill", 2.7, 0.8, Vector3.new(0, 1.05 + (index - 1) * 2.7, 0), color, Enum.Material.Neon))
		end
		decor(k:ball("MeterBulb", 2.1, CFrame.new(0, 1.3, 0), fills[1], Enum.Material.Neon))
		local label = k:trim("MeterLabel", Vector3.new(3.4, 1.2, 0.15), CFrame.new(0, 10.6, 0), Color3.fromRGB(46, 28, 70), Enum.Material.SmoothPlastic)
		Kit.label(label, "AURA: MAXED", Color3.fromRGB(255, 214, 90), Color3.fromRGB(46, 28, 70), { Enum.NormalId.Front, Enum.NormalId.Back })
	end

	defineTheme({
		name = "Aura Farms",
		id = "AuraFarms",
		flag = { emblem = "+1000", caption = "AURA FARMS", color = Color3.fromRGB(70, 40, 110), text = Color3.fromRGB(255, 214, 90), trim = Color3.fromRGB(190, 120, 255) },
		setPiece = {
			id = "AuraFields",
			name = "The Aura Fields",
			width = 38,
			depth = 30,
			ground = Enum.Material.Ground,
			build = function(k)
				for index, z in ipairs({ -6.5, -0.5, 5.5 }) do
					cropBed(k:at(CFrame.new(-5, 0, z)), 22, 7, index)
				end
				auraSilo(k:at(CFrame.new(13, 0, 8)))
				scoreboard(k:at(CFrame.new(-12, 0, 12)))
				auraScarecrow(k:at(CFrame.new(12, 0, -7)))
				orbCrate(k:at(CFrame.new(-15, 0, -12)))
				orbCrate(k:at(CFrame.new(-12.2, 0, -12.4)))
				local stacked = orbCrate
				stacked(k:at(CFrame.new(-13.6, 1.8, -12.2) * CFrame.Angles(0, 0.25, 0)))
				auraMeter(k:at(CFrame.new(3, 0, -12.2)))
			end,
		},
		props = {
			{ id = "OrbCrate", radius = 1.8, build = orbCrate },
			{
				id = "AuraSunflower",
				radius = 2.1,
				build = function(k)
					decor(k:post("SunflowerStem", 6.2, 0.35, Vector3.zero, Color3.fromRGB(80, 150, 70), Enum.Material.SmoothPlastic))
					k:trim("SunflowerLeaf", Vector3.new(1.8, 0.1, 0.6), CFrame.new(0.6, 2.6, 0) * CFrame.Angles(0, 0, 0.3), Color3.fromRGB(90, 170, 80), Enum.Material.SmoothPlastic)
					local face = k:at(CFrame.new(0, 6.6, -0.2) * CFrame.Angles(math.rad(-15), 0, 0))
					local disc = decor(face:cyl("SunflowerFace", 0.4, 1.8, CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(90, 60, 40), Enum.Material.Sand))
					for index = 0, 7 do
						-- Behind the face, alternate petals a step apart, so neighbours that overlap never
						-- share a face and none cuts into the face's back.
						face:trim("SunflowerPetal", Vector3.new(0.7, 1.3, 0.15), CFrame.Angles(0, 0, index * math.pi / 4) * CFrame.new(0, 1.3, 0.3 + (index % 2) * 0.12), AURA[3], Enum.Material.Neon)
					end
					Kit.light(disc, AURA[3], 10, 0.8)
				end,
			},
			{
				id = "AuraSign",
				radius = 1.4,
				build = function(k)
					local board = Pieces.board(k, "AURA +1000", 2.8, 1.2, 3.2, Color3.fromRGB(255, 214, 90), Color3.fromRGB(46, 28, 70), 1, C.iron)
					board.Name = "AuraSign"
					sparkle(board, AURA[1])
				end,
			},
			{
				id = "GlowingHay",
				radius = 3.1,
				build = function(k)
					for _, z in ipairs({ -1.25, 1.25 }) do
						k:cyl("HayBale", 3.6, 2.5, CFrame.new(0, 1.15, z), Color3.fromRGB(214, 180, 96), Enum.Material.Grass)
					end
					local top = k:cyl("HayBale", 3.6, 2.5, CFrame.new(0, 3.3, 0), Color3.fromRGB(224, 190, 106), Enum.Material.Grass)
					sparkle(top, AURA[3])
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Sigma Station: the maglev to Grindset Central, always on time
--------------------------------------------------------------------------------

do
	local PLATFORM = Color3.fromRGB(206, 206, 210)
	local GUIDEWAY = Color3.fromRGB(70, 72, 80)
	local PURPLE = Color3.fromRGB(120, 70, 230)
	local CYAN = Color3.fromRGB(90, 230, 255)
	local TRAIN_WHITE = Color3.fromRGB(236, 238, 242)
	local AMBER = Color3.fromRGB(255, 176, 60)
	local GLASS = Color3.fromRGB(150, 190, 210)

	-- The shuttle, hovering half a stud over its guideway. Every part of it is meant to float.
	local function shuttle(k)
		local parts = {}
		local function keep(part)
			table.insert(parts, part)
			return part
		end
		-- Body 1.9 to 7.1 high, its platform side at z = 6.9; livery layered off that face.
		keep(k:box("ShuttleBody", Vector3.new(24, 5.2, 4.2), CFrame.new(-2, 4.5, 9), TRAIN_WHITE, Enum.Material.SmoothPlastic))
		keep(k:wedge("ShuttleNose", Vector3.new(4.2, 5.2, 5.5), CFrame.new(12.75, 4.5, 9) * CFrame.Angles(0, -math.pi / 2, 0), TRAIN_WHITE, Enum.Material.SmoothPlastic))
		keep(k:wedge("ShuttleNose", Vector3.new(4.2, 5.2, 5.5), CFrame.new(-16.75, 4.5, 9) * CFrame.Angles(0, math.pi / 2, 0), TRAIN_WHITE, Enum.Material.SmoothPlastic))
		-- Windscreens laid along each nose's slope, a hair proud of it.
		local slope = Vector3.new(5.5, -5.2, 0).Unit
		for _, side in ipairs({ 1, -1 }) do
			local along = Vector3.new(slope.X * side, slope.Y, 0)
			local normal = Vector3.new(-slope.Y * side, slope.X, 0)
			local tip = Vector3.new(side > 0 and 10 or -14, 7.1, 9)
			local at = tip + along * 2.2 + normal * 0.06
			keep(decor(k:box("ShuttleWindscreen", Vector3.new(3.0, 0.1, 3.6), CFrame.fromMatrix(at, along, normal), Color3.fromRGB(30, 40, 60), Enum.Material.Glass)))
		end
		keep(k:trim("ShuttleStripe", Vector3.new(24, 0.8, 0.1), CFrame.new(-2, 3.2, 6.85), PURPLE, Enum.Material.SmoothPlastic))
		keep(k:trim("ShuttleWindows", Vector3.new(21, 1.6, 0.1), CFrame.new(-2, 5.5, 6.85), Color3.fromRGB(30, 40, 60), Enum.Material.Glass))
		for _, x in ipairs({ -9.2, -7.6, 0.4, 2.0 }) do
			keep(k:trim("ShuttleDoorLine", Vector3.new(0.15, 4.2, 0.1), CFrame.new(x, 4.3, 6.74), Color3.fromRGB(150, 154, 164), Enum.Material.SmoothPlastic))
		end
		local logo = keep(k:trim("ShuttleLogo", Vector3.new(2.6, 2.6, 0.1), CFrame.new(6.8, 4.4, 6.78), PURPLE, Enum.Material.SmoothPlastic))
		Kit.label(logo, "Σ", C.white, PURPLE, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
		local glow = keep(k:trim("ShuttleUnderglow", Vector3.new(22, 0.2, 2.8), CFrame.new(-2, 1.7, 9), CYAN, Enum.Material.Neon))
		Kit.light(glow, CYAN, 16, 1.2)
		for _, part in ipairs(parts) do
			floating(part)
		end
	end

	local function sleekBench(k)
		k:box("SleekSeat", Vector3.new(5, 0.35, 1.5), CFrame.new(0, 1.75, 0), Color3.fromRGB(46, 48, 58), Enum.Material.SmoothPlastic)
		k:trim("SleekBack", Vector3.new(5, 1.3, 0.25), CFrame.new(0, 2.7, 0.7) * CFrame.Angles(math.rad(-10), 0, 0), Color3.fromRGB(46, 48, 58), Enum.Material.SmoothPlastic)
		for _, x in ipairs({ -2, 2 }) do
			k:box("SleekLeg", Vector3.new(0.3, 1.575, 1.2), CFrame.new(x, 0.7875, 0), C.silver, Enum.Material.Metal)
		end
	end

	local function gates(k)
		for _, x in ipairs({ -2.9, 0, 2.9 }) do
			k:box("TicketGate", Vector3.new(0.6, 2.6, 2.2), CFrame.new(x, 1.3, 0), Color3.fromRGB(46, 48, 58), Enum.Material.SmoothPlastic)
			local arrow = k:trim("GateLight", Vector3.new(0.5, 0.12, 1.6), CFrame.new(x, 2.66, 0), Color3.fromRGB(80, 255, 140), Enum.Material.Neon)
			arrow.Transparency = 0.1
		end
		for _, x in ipairs({ -2.05, -0.85, 0.85, 2.05 }) do
			local flap = k:trim("GateFlap", Vector3.new(1.1, 1.0, 0.1), CFrame.new(x, 1.8, 0), GLASS, Enum.Material.Glass)
			flap.Transparency = 0.5
		end
	end

	local function canopy(k)
		for _, x in ipairs({ -15, -5, 5, 15 }) do
			k:post("CanopyColumn", 9.0, 0.6, Vector3.new(x, 1.4, 4.4), C.silver, Enum.Material.Metal)
			decor(k:rod("CanopyStrut", Vector3.new(x, 7.2, 4.4), Vector3.new(x, 10.0, -3.3), 0.3, C.silver, Enum.Material.Metal))
		end
		local roof = k:trim("CanopyGlass", Vector3.new(36, 0.3, 9), CFrame.new(0, 10.35, 0.8), GLASS, Enum.Material.Glass)
		roof.Transparency = 0.55
		-- The beams hang wholly under the glass (10.2..10.5) and inside its edges (-3.7..5.3), clear of
		-- every face of it by more than the z-fight pass's tolerance: tops at 10.13, sides at -3.55/-3.05
		-- and 4.45/4.95. The strip light hangs clear under the beam in turn. Designed apart rather than
		-- nudged apart, because a pass that nudges them does it again on every build.
		for _, z in ipairs({ -3.3, 4.7 }) do
			k:trim("CanopyBeam", Vector3.new(36.4, 0.5, 0.5), CFrame.new(0, 9.88, z), C.silver, Enum.Material.Metal)
			k:trim("CanopyLight", Vector3.new(34, 0.12, 0.3), CFrame.new(0, 9.50, z), Color3.fromRGB(230, 240, 255), Enum.Material.Neon)
		end
		for _, x in ipairs({ -5, 5 }) do
			k:trim("BoardHanger", Vector3.new(0.15, 1.3, 0.15), CFrame.new(x, 9.55, 0.8), C.silver, Enum.Material.Metal)
		end
		local board = k:trim("DepartureBoard", Vector3.new(12, 1.8, 0.4), CFrame.new(0, 8.0, 0.8), C.black, Enum.Material.SmoothPlastic)
		Kit.label(board, "SIGMA EXPRESS  →  GRINDSET CENTRAL\nON TIME (ALWAYS)", AMBER, C.black, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.RobotoMono)
		Kit.light(board, AMBER, 10, 0.6)
	end

	local function totem(k)
		k:box("StationTotem", Vector3.new(2.4, 12, 1.2), CFrame.new(0, 5.8, 0), Color3.fromRGB(40, 42, 52), Enum.Material.SmoothPlastic)
		for _, x in ipairs({ -1.3, 1.3 }) do
			k:trim("TotemEdge", Vector3.new(0.2, 11.6, 0.2), CFrame.new(x, 5.8, -0.5), PURPLE, Enum.Material.Neon)
		end
		local logo = k:box("TotemLogo", Vector3.new(4.6, 4.6, 0.5), CFrame.new(0, 13.6, 0), PURPLE, Enum.Material.SmoothPlastic)
		Kit.label(logo, "Σ", C.white, PURPLE, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBlack)
		Kit.light(logo, PURPLE, 16, 1)
		local name = k:trim("TotemName", Vector3.new(2.0, 3.4, 0.1), CFrame.new(0, 8.4, -0.65), Color3.fromRGB(40, 42, 52), Enum.Material.SmoothPlastic)
		Kit.label(name, "SIGMA\nSTATION", C.white, Color3.fromRGB(40, 42, 52), { Enum.NormalId.Front }, Enum.Font.GothamBold)
	end

	defineTheme({
		name = "Sigma Station",
		id = "SigmaStation",
		flag = { emblem = "Σ", caption = "SIGMA STATION", color = Color3.fromRGB(40, 42, 52), text = C.white, trim = PURPLE, font = Enum.Font.GothamBlack },
		setPiece = {
			id = "MaglevPlatform",
			name = "Sigma Station",
			width = 40,
			depth = 26,
			ground = Enum.Material.Concrete,
			build = function(k)
				k:box("StationPlatform", Vector3.new(38, 2.0, 8), CFrame.new(0, 0.6, 1), PLATFORM, Enum.Material.Concrete)
				k:trim("PlatformEdge", Vector3.new(37.8, 0.14, 0.7), CFrame.new(0, 1.63, 4.5), Color3.fromRGB(250, 210, 50), Enum.Material.SmoothPlastic)
				for _, x in ipairs({ -12, 12 }) do
					k:box("PlatformStep", Vector3.new(6, 1.0, 1.2), CFrame.new(x, 0.3, -3.6), PLATFORM, Enum.Material.Concrete)
					gates(k:at(CFrame.new(x, 1.6, -1.6)))
				end
				k:box("Guideway", Vector3.new(40, 1.6, 3.4), CFrame.new(0, 0.6, 9), GUIDEWAY, Enum.Material.Concrete)
				for _, z in ipairs({ 8.0, 10.0 }) do
					k:trim("GuidewayRail", Vector3.new(40, 0.12, 0.25), CFrame.new(0, 1.46, z), CYAN, Enum.Material.Neon)
				end
				shuttle(k)
				canopy(k)
				for _, x in ipairs({ -5, 5 }) do
					sleekBench(k:at(CFrame.new(x, 1.6, 2.4)))
				end
				totem(k:at(CFrame.new(-17.2, 0, -10.2)))
			end,
		},
		props = {
			{
				id = "WayfindingPylon",
				radius = 1.4,
				build = function(k)
					k:box("Pylon", Vector3.new(1.6, 7, 0.8), CFrame.new(0, 3.3, 0), Color3.fromRGB(40, 42, 52), Enum.Material.SmoothPlastic)
					-- A tenth proud of the post on each side: at 0.05 the two faces were inside the z-fight pass's
					-- tolerance and it pulled them apart on every build.
					k:trim("PylonCap", Vector3.new(1.8, 0.5, 1.0), CFrame.new(0, 6.9, 0), PURPLE, Enum.Material.Neon)
					local panel = k:trim("PylonPanel", Vector3.new(1.4, 3.2, 0.1), CFrame.new(0, 4.4, -0.45), Color3.fromRGB(40, 42, 52), Enum.Material.SmoothPlastic)
					Kit.label(panel, "PLATFORM\nΣ\n→", C.white, Color3.fromRGB(40, 42, 52), { Enum.NormalId.Front }, Enum.Font.GothamBold)
				end,
			},
			{ id = "SleekBench", radius = 2.7, build = sleekBench },
			{
				id = "TicketKiosk",
				radius = 1.6,
				build = function(k)
					k:box("Kiosk", Vector3.new(1.8, 5, 1.4), CFrame.new(0, 2.3, 0), Color3.fromRGB(46, 48, 58), Enum.Material.SmoothPlastic)
					local screen = k:trim("KioskScreen", Vector3.new(1.5, 1.3, 0.12), CFrame.new(0, 3.6, -0.75) * CFrame.Angles(math.rad(-12), 0, 0), CYAN, Enum.Material.Neon)
					Kit.label(screen, "BUY\nGRIND PASS", C.black, nil, { Enum.NormalId.Front }, Enum.Font.GothamBold)
					k:trim("KioskSlot", Vector3.new(0.8, 0.12, 0.12), CFrame.new(0, 2.4, -0.76), C.black, Enum.Material.SmoothPlastic)
					k:trim("KioskTop", Vector3.new(1.9, 0.3, 1.5), CFrame.new(0, 4.95, 0), PURPLE, Enum.Material.Neon)
				end,
			},
			{
				id = "MindTheGrind",
				radius = 1.6,
				build = function(k)
					for _, side in ipairs({ -1, 1 }) do
						local board = k:box("GrindSign", Vector3.new(side < 0 and 2 or 1.8, 2.8, 0.15), CFrame.new(0, 1.35, side * 0.45) * CFrame.Angles(math.rad(side * 16), 0, 0),
							Color3.fromRGB(250, 210, 50), Enum.Material.SmoothPlastic)
						Kit.label(board, "MIND THE GRIND", C.black, nil, { side < 0 and Enum.NormalId.Front or Enum.NormalId.Back }, Enum.Font.GothamBlack)
					end
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- NPC Nook: where the background characters wait for someone to talk to them
--------------------------------------------------------------------------------

do
	local NPC_GREY = Color3.fromRGB(150, 160, 176)
	local NPC_DARK = Color3.fromRGB(118, 126, 140)
	local PEDESTAL = Color3.fromRGB(70, 74, 84)
	local QUEST_YELLOW = Color3.fromRGB(255, 214, 40)

	-- A mannequin: a blank grey figure, stiff as a board, NPC printed on its chest, standing on a
	-- plinth. It is not a character in any sense the game knows: no Humanoid, no collision, invisible
	-- to raycasts, so it can't stop a bullet or draw a bot's aim, and from any distance it reads as a
	-- statue on a stand rather than a player. `pose`: stride (legs swing, radians), reach (arms
	-- forward), spread (arms out), sit (legs straight forward), bare (no plinth), lift (height of its
	-- feet).
	local function mannequin(k, pose)
		pose = pose or {}
		local y0 = pose.lift or 0.5
		if not pose.bare then
			k:post("NpcPlinth", 0.6, 2.0, Vector3.new(0, -0.1, 0), PEDESTAL, Enum.Material.Metal)
		end
		local hip = y0 + 2.3
		for _, side in ipairs({ -1, 1 }) do
			local swing = pose.sit and (math.pi / 2) or side * (pose.stride or 0)
			k:trim("NpcLeg", Vector3.new(0.8, 2.3, 0.8), CFrame.new(side * 0.5, hip, 0) * CFrame.Angles(swing, 0, 0) * CFrame.new(0, -1.15, 0), NPC_DARK, Enum.Material.SmoothPlastic)
		end
		k:trim("NpcTorso", Vector3.new(2.0, 2.3, 1.0), CFrame.new(0, hip + 1.15, 0), NPC_GREY, Enum.Material.SmoothPlastic)
		local tag = k:trim("NpcTag", Vector3.new(1.2, 0.5, 0.1), CFrame.new(0, hip + 1.6, -0.55), C.white, Enum.Material.SmoothPlastic)
		Kit.label(tag, "NPC", C.black, C.white, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
		for _, side in ipairs({ -1, 1 }) do
			local reach = -(pose.reach or 0) - side * (pose.stride or 0) * 0.6
			k:trim("NpcArm", Vector3.new(0.7, 2.2, 0.7), CFrame.new(side * 1.35, hip + 2.2, 0) * CFrame.Angles(reach, 0, side * (pose.spread or 0)) * CFrame.new(0, -1.1, 0),
				NPC_DARK, Enum.Material.SmoothPlastic)
		end
		k:trim("NpcHead", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, hip + 2.95, 0), NPC_GREY, Enum.Material.SmoothPlastic)
		return hip + 3.55
	end

	-- A speech bubble hanging in the air: a white board and a tail pointing down at the speaker.
	local function bubble(k, text, width)
		local board = floating(k:trim("SpeechBubble", Vector3.new(width, 1.5, 0.2), CFrame.identity, C.white, Enum.Material.SmoothPlastic))
		Kit.label(board, text, C.black, C.white, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBold)
		floating(decor(k:wedge("SpeechTail", Vector3.new(0.2, 0.7, 0.7), CFrame.new(-width * 0.2, -1.1, 0) * CFrame.Angles(0, math.pi / 2, math.pi), C.white, Enum.Material.SmoothPlastic)))
	end

	-- The floating quest marker: a bar and a dot, bobbing together.
	local function questMark(k, size, phase)
		local bar = floating(k:trim("QuestMark", Vector3.new(size, size * 3.2, size), CFrame.new(0, size * 2.2, 0), QUEST_YELLOW, Enum.Material.Neon))
		local dot = floating(k:trim("QuestMark", Vector3.new(size, size, size), CFrame.new(0, 0, 0), QUEST_YELLOW, Enum.Material.Neon))
		for _, part in ipairs({ bar, dot }) do
			Kit.bob(part, size * 0.45, 1.6, phase or 0)
		end
		Kit.light(bar, QUEST_YELLOW, 14, 1)
	end

	local function kiosk(k)
		k:box("KioskCounter", Vector3.new(8, 3.2, 2.2), CFrame.new(0, 1.4, -1), Color3.fromRGB(150, 110, 70), Enum.Material.WoodPlanks)
		k:box("KioskBack", Vector3.new(8, 7.8, 0.5), CFrame.new(0, 3.7, 2.2), Color3.fromRGB(236, 226, 200), Enum.Material.WoodPlanks)
		for _, x in ipairs({ -3.65, 3.65 }) do
			k:box("KioskSide", Vector3.new(0.5, 7.3, 4.0), CFrame.new(x, 3.55, 0.2), Color3.fromRGB(236, 226, 200), Enum.Material.WoodPlanks)
		end
		k:box("KioskRoof", Vector3.new(9, 0.4, 5.4), CFrame.new(0, 7.8, 0.2), Color3.fromRGB(120, 80, 50), Enum.Material.WoodPlanks)
		for index = 0, 4 do
			k:trim("KioskAwning", Vector3.new(1.7, 0.2, 2.4), CFrame.new(-3.6 + index * 1.8, 7.25, -3.5) * CFrame.Angles(math.rad(-18), 0, 0),
				index % 2 == 0 and QUEST_YELLOW or C.white, Enum.Material.Fabric)
		end
		k:box("QuestBoard", Vector3.new(6, 3.4, 0.2), CFrame.new(0, 5.2, 1.85), Color3.fromRGB(160, 120, 80), Enum.Material.Wood)
		for index, text in ipairs({ "SLAY 10 RATS", "FETCH 1 STICK", "TALK TO BOB" }) do
			local note = k:trim("QuestNote", Vector3.new(1.7, 1.3, 0.06), CFrame.new(-2 + (index - 1) * 2, 5.1 + (index % 2) * 0.4, 1.72) * CFrame.Angles(0, 0, math.rad(-4 + index * 3)),
				Color3.fromRGB(244, 234, 200), Enum.Material.SmoothPlastic)
			Kit.label(note, text, C.black, nil, { Enum.NormalId.Front }, Enum.Font.PermanentMarker)
		end
		local sign = k:trim("KioskSign", Vector3.new(6, 1.2, 0.2), CFrame.new(0, 8.6, -2.35), C.signBack, Enum.Material.SmoothPlastic)
		Kit.label(sign, "QUESTS", QUEST_YELLOW, C.signBack, { Enum.NormalId.Front, Enum.NormalId.Back })
		mannequin(k:at(CFrame.new(0, 0, 0.9)), { bare = true, lift = 0, spread = 0.5 })
		questMark(k:at(CFrame.new(0, 10.6, 0)), 1.3, 0)
	end

	defineTheme({
		name = "NPC Nook",
		id = "NpcNook",
		flag = { emblem = "!", caption = "NPC NOOK", color = Color3.fromRGB(60, 66, 80), text = QUEST_YELLOW, trim = QUEST_YELLOW, font = Enum.Font.GothamBlack },
		setPiece = {
			id = "QuestQueue",
			name = "The Quest Queue",
			width = 34,
			depth = 28,
			ground = Enum.Material.Pavement,
			build = function(k)
				kiosk(k:at(CFrame.new(0, 0, 8.5)))
				-- The queue: six of them, all facing the counter, all waiting.
				local queue = { { -1, 4.4 }, { -1.5, 1.6 }, { -2.2, -1.2 }, { -3, -4.0 }, { -3.8, -6.8 }, { -4.6, -9.6 } }
				for index, spot in ipairs(queue) do
					mannequin(k:at(CFrame.new(spot[1], 0, spot[2]) * CFrame.Angles(0, math.pi, 0)), { stride = index == 6 and 0.25 or 0 })
				end
				local posts = { 1, 3, 5, 6 }
				for _, side in ipairs({ -1, 1 }) do
					local previous = nil
					for _, index in ipairs(posts) do
						local spot = queue[index]
						local at = Vector3.new(spot[1] + side * 2.3, 0, spot[2])
						k:post("QueuePost", 3, 0.3, at, C.brass, Enum.Material.Metal)
						decor(k:ball("QueuePostTop", 0.5, CFrame.new(at + Vector3.new(0, 3.1, 0)), C.brass, Enum.Material.Metal))
						if previous then
							decor(k:rod("QueueRope", previous + Vector3.new(0, 2.6, 0), at + Vector3.new(0, 2.6, 0), 0.22, Color3.fromRGB(170, 30, 50), Enum.Material.Fabric))
						end
						previous = at
					end
				end
				-- One stuck walking into a wall, and the wall is winning.
				k:box("StuckWall", Vector3.new(6, 5, 1), CFrame.new(11, 2.3, -3.5), Color3.fromRGB(160, 96, 74), Enum.Material.Brick)
				mannequin(k:at(CFrame.new(11, 0, -5.6) * CFrame.Angles(0, math.pi, 0)), { stride = 0.4, reach = 0.2 })
				local stuck = Pieces.board(k:at(CFrame.new(15.2, 0, -8.4)), "PATHFINDING...", 3.4, 1.2, 3, C.white, Color3.fromRGB(60, 66, 80), 1, C.iron)
				stuck.Name = "PathfindingSign"
				-- Two of them making small talk, forever.
				local top = mannequin(k:at(CFrame.new(11, 0, 6) * CFrame.Angles(0, math.pi, 0)), {})
				mannequin(k:at(CFrame.new(11, 0, 9.4)), { spread = 0.15 })
				bubble(k:at(CFrame.new(11, top + 1.6, 5.4)), "Nice weather today.", 4.2)
				bubble(k:at(CFrame.new(11, top + 3.6, 9.8)), "It sure is.", 3.2)
				-- And one on a bench, taking a break from standing still.
				local bench = k:at(CFrame.new(-12, 0, 3.5))
				Pieces.bench(bench, Color3.fromRGB(150, 110, 70))
				mannequin(bench:at(CFrame.new(0, 0, 0.05)), { bare = true, lift = -0.05, sit = true })
				bubble(bench:at(CFrame.new(0, 8.4, 0)), "...", 1.8)
				local welcome = Pieces.board(k:at(CFrame.new(-10.5, 0, -11.8)), "NPC NOOK\nPOPULATION: BACKGROUND", 8, 2.4, 2.2, QUEST_YELLOW, Color3.fromRGB(60, 66, 80), 2, C.iron)
				welcome.Name = "WelcomeBoard"
			end,
		},
		props = {
			{
				id = "IdleNpc",
				radius = 2.1,
				build = function(k)
					local top = mannequin(k, { spread = k.rng:NextNumber(0, 0.2) })
					bubble(k:at(CFrame.new(0.3, top + 1.4, 0)), "...", 1.6)
				end,
			},
			{
				id = "WallStareNpc",
				radius = 3.1,
				build = function(k)
					k:box("StareWall", Vector3.new(4, 4.4, 0.8), CFrame.new(0, 2.0, 1.4), Color3.fromRGB(160, 96, 74), Enum.Material.Brick)
					mannequin(k:at(CFrame.new(0, 0, -0.4) * CFrame.Angles(0, math.pi, 0)), { stride = 0.3 })
				end,
			},
			{
				id = "QuestBoard",
				radius = 2.2,
				build = function(k)
					for _, x in ipairs({ -1.7, 1.7 }) do
						k:box("NoticePost", Vector3.new(0.35, 4.6, 0.35), CFrame.new(x, 2.1, 0.3), C.darkWood, Enum.Material.Wood)
					end
					k:box("NoticeBoard", Vector3.new(3.8, 2.4, 0.25), CFrame.new(0, 3.0, 0), Color3.fromRGB(160, 120, 80), Enum.Material.Wood)
					for index, text in ipairs({ "LOST: 1 SOCK", "HELP WANTED: ANYONE" }) do
						local note = k:trim("QuestNote", Vector3.new(1.5, 1.2, 0.06), CFrame.new(-0.85 + (index - 1) * 1.7, 3.0, -0.155) * CFrame.Angles(0, 0, math.rad(index * 5 - 7)),
							Color3.fromRGB(244, 234, 200), Enum.Material.SmoothPlastic)
						Kit.label(note, text, C.black, nil, { Enum.NormalId.Front }, Enum.Font.PermanentMarker)
					end
					questMark(k:at(CFrame.new(0, 6.0, 0)), 0.6, k.rng:NextNumber(0, 6))
				end,
			},
			{
				id = "DialogueSign",
				radius = 2.2,
				build = function(k)
					local lines = { "I'm just standing here.", "Have you heard? Nothing happened.", "Press E to talk. (Don't.)", "Lovely day for a loop.", "Welcome, traveller!" }
					k:post("DialoguePost", 4.2, 0.3, Vector3.zero, C.iron, Enum.Material.Metal)
					local board = k:box("DialogueBubble", Vector3.new(4, 1.8, 0.25), CFrame.new(0, 5.1, 0), C.white, Enum.Material.SmoothPlastic)
					Kit.label(board, lines[k.rng:NextInteger(1, #lines)], C.black, C.white, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBold)
					decor(k:wedge("DialogueTail", Vector3.new(0.25, 0.7, 0.8), CFrame.new(0.6, 3.85, 0) * CFrame.Angles(0, math.pi / 2, math.pi), C.white, Enum.Material.SmoothPlastic))
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Delulu Downs: the racecourse where you've already won
--------------------------------------------------------------------------------

do
	local PINK = Color3.fromRGB(255, 182, 214)
	local LILAC = Color3.fromRGB(200, 170, 255)
	local MINT = Color3.fromRGB(170, 240, 210)
	local BABY_BLUE = Color3.fromRGB(170, 210, 255)
	local PASTELS = { PINK, LILAC, MINT, BABY_BLUE }
	local RAIL_WHITE = Color3.fromRGB(250, 248, 244)

	-- A rocking horse that rocks, facing its kit's -Z. The hub sits on the ground under the rockers,
	-- so the whole horse tips about the point the rockers roll on.
	local function rockingHorse(k, color, mane, number, phase)
		local hub = k:hub("HorseHub", CFrame.new(0, 0.2, 0))
		local h = k:into(hub)
		for _, x in ipairs({ -0.75, 0.75 }) do
			h:trim("HorseRocker", Vector3.new(0.3, 0.35, 5.4), CFrame.new(x, 0.35, 0), C.brass, Enum.Material.Metal)
			h:trim("RockerCurl", Vector3.new(0.16, 0.35, 1.0), CFrame.new(x, 0.62, -3.05) * CFrame.Angles(0.6, 0, 0), C.brass, Enum.Material.Metal)
			h:trim("RockerCurl", Vector3.new(0.16, 0.35, 1.0), CFrame.new(x, 0.62, 3.05) * CFrame.Angles(-0.6, 0, 0), C.brass, Enum.Material.Metal)
			for _, z in ipairs({ -1.5, 1.5 }) do
				decor(h:rod("HorseLeg", Vector3.new(x * 0.73, 0.5, z), Vector3.new(x * 0.66, 2.5, z * 0.87), 0.35, color, Enum.Material.SmoothPlastic))
			end
		end
		h:trim("HorseBody", Vector3.new(1.5, 1.4, 3.2), CFrame.new(0, 3.0, 0), color, Enum.Material.SmoothPlastic)
		h:trim("HorseNeck", Vector3.new(0.8, 1.8, 0.9), CFrame.new(0, 4.0, -1.5) * CFrame.Angles(-0.35, 0, 0), color, Enum.Material.SmoothPlastic)
		h:trim("HorseHead", Vector3.new(1.0, 0.95, 1.9), CFrame.new(0, 5.0, -2.35) * CFrame.Angles(0.15, 0, 0), color, Enum.Material.SmoothPlastic)
		h:trim("HorseMane", Vector3.new(0.3, 1.4, 0.35), CFrame.new(0, 4.3, -1.02) * CFrame.Angles(-0.35, 0, 0), mane, Enum.Material.Fabric)
		h:trim("HorseTail", Vector3.new(0.35, 1.5, 0.35), CFrame.new(0, 3.0, 1.95) * CFrame.Angles(0.6, 0, 0), mane, Enum.Material.Fabric)
		h:trim("HorseSaddle", Vector3.new(1.56, 0.2, 1.3), CFrame.new(0, 3.8, 0.1), C.gold, Enum.Material.Foil)
		local cloth = h:trim("HorseCloth", Vector3.new(1.64, 0.9, 1.4), CFrame.new(0, 3.15, 0.1), C.white, Enum.Material.Fabric)
		Kit.label(cloth, tostring(number), C.black, nil, { Enum.NormalId.Left, Enum.NormalId.Right }, Enum.Font.GothamBlack)
		for _, x in ipairs({ -0.46, 0.46 }) do
			h:ball("HorseEye", 0.2, CFrame.new(x, 5.15, -2.75), C.black, Enum.Material.SmoothPlastic)
		end
		for _, child in ipairs(hub:GetChildren()) do
			if child:IsA("BasePart") then
				decor(child)
			end
		end
		Kit.sway(hub, "X", 9, 2.4, phase)
	end

	local function heartBalloon(k, at, color, phase)
		local parts = {
			k:ball("BalloonLobe", 1.3, CFrame.new(at + Vector3.new(-0.42, 0.25, 0)), color, Enum.Material.SmoothPlastic),
			k:ball("BalloonLobe", 1.3, CFrame.new(at + Vector3.new(0.42, 0.25, 0)), color, Enum.Material.SmoothPlastic),
			k:box("BalloonPoint", Vector3.new(1.15, 1.15, 0.9), CFrame.new(at + Vector3.new(0, -0.3, 0)) * CFrame.Angles(0, 0, math.pi / 4), color, Enum.Material.SmoothPlastic),
		}
		for _, part in ipairs(parts) do
			floating(decor(part))
			Kit.bob(part, 0.4, 1.1, phase)
		end
	end

	-- A few balloons on strings from one weight on the ground.
	local function balloonBunch(k, count, height)
		k:box("BalloonWeight", Vector3.new(0.8, 0.6, 0.8), CFrame.new(0, 0.3, 0), C.gold, Enum.Material.Metal)
		for index = 1, count do
			local angle = index * math.pi * 2 / count
			local at = Vector3.new(math.cos(angle) * 1.1, height + (index % 2) * 1.2, math.sin(angle) * 1.1)
			decor(k:rod("BalloonString", Vector3.new(0, 0.6, 0), at - Vector3.new(0, 1.4, 0), 0.06, C.white, Enum.Material.Fabric))
			heartBalloon(k, at, index % 2 == 0 and PINK or Color3.fromRGB(255, 120, 170), index)
		end
	end

	local function cloud(k, height, scale)
		k:post("CloudPole", height, 0.35 * scale, Vector3.zero, RAIL_WHITE, Enum.Material.SmoothPlastic)
		local puffs = { { 0, 0, 0, 3.4 }, { 1.7, 0.3, 0.4, 2.6 }, { -1.6, 0.2, -0.3, 2.8 }, { 0.6, 1.1, -0.5, 2.4 }, { -0.7, 0.9, 0.8, 2.2 }, { 2.6, -0.2, -0.2, 1.8 } }
		for index, puff in ipairs(puffs) do
			decor(k:ball("CloudPuff", puff[4] * scale, CFrame.new(Vector3.new(puff[1], height + 1 + puff[2], puff[3]) * Vector3.new(scale, 1, scale)),
				PASTELS[(index - 1) % 2 + 1], Enum.Material.SmoothPlastic))
		end
	end

	defineTheme({
		name = "Delulu Downs",
		id = "DeluluDowns",
		flag = { emblem = "#1", caption = "DELULU DOWNS", color = Color3.fromRGB(150, 80, 190), text = PINK, trim = C.white },
		setPiece = {
			id = "DreamRacecourse",
			name = "The Dream Racecourse",
			width = 40,
			depth = 30,
			ground = Enum.Material.LeafyGrass,
			build = function(k)
				-- The home straight, railed both sides.
				for _, z in ipairs({ -3, 7 }) do
					for index = 0, 6 do
						k:post("RailPost", 3.3, 0.35, Vector3.new(-18 + index * 6, -0.3, z), RAIL_WHITE, Enum.Material.SmoothPlastic)
					end
					k:trim("RailTop", Vector3.new(36.4, 0.3, 0.3), CFrame.new(0, 3.0, z), RAIL_WHITE, Enum.Material.SmoothPlastic)
				end
				-- Three rocking horses neck and neck, all of them winning.
				local runners = { { -8, PINK, LILAC }, { 0, MINT, BABY_BLUE }, { 8, BABY_BLUE, PINK } }
				for index, runner in ipairs(runners) do
					rockingHorse(k:at(CFrame.new(runner[1], 0, 2) * CFrame.Angles(0, -math.pi / 2, 0)), runner[2], runner[3], index, index * 0.8)
				end
				-- The finish post.
				local finish = k:at(CFrame.new(15.5, 0, -4))
				finish:post("FinishPole", 9, 0.4, Vector3.zero, RAIL_WHITE, Enum.Material.SmoothPlastic)
				decor(finish:cyl("FinishRing", 0.2, 3.3, CFrame.new(0, 9.6, -0.2) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(230, 60, 90), Enum.Material.SmoothPlastic))
				local disc = decor(finish:cyl("FinishDisc", 0.2, 2.9, CFrame.new(0, 9.6, -0.36) * CFrame.Angles(0, math.pi / 2, 0), C.white, Enum.Material.SmoothPlastic))
				Kit.label(disc, "FINISH", Color3.fromRGB(230, 60, 90), nil, { Enum.NormalId.Right }, Enum.Font.GothamBlack)
				-- The Dream Stand.
				local stand = k:at(CFrame.new(-12, 0, 11.2))
				for tier, spec in ipairs({ { -2.2, PINK }, { 0, C.white }, { 2.2, LILAC } }) do
					local height = tier + 0.2
					stand:box("StandTier", Vector3.new(11, height, 2.2), CFrame.new(0, -0.2 + height / 2, spec[1]), spec[2], Enum.Material.WoodPlanks)
				end
				for _, x in ipairs({ -5.6, 5.6 }) do
					for _, z in ipairs({ -3.2, 3.2 }) do
						stand:post("StandPost", 8, 0.35, Vector3.new(x, 0, z), RAIL_WHITE, Enum.Material.SmoothPlastic)
					end
				end
				for index = 0, 4 do
					stand:trim("StandCanopy", Vector3.new(2.3, 0.2, 7.2), CFrame.new(-4.6 + index * 2.3, 8.1, 0) * CFrame.Angles(math.rad(-6), 0, 0),
						index % 2 == 0 and PINK or C.white, Enum.Material.Fabric)
				end
				local standSign = stand:trim("StandSign", Vector3.new(6, 1.1, 0.2), CFrame.new(0, 7.1, -3.45), C.white, Enum.Material.SmoothPlastic)
				Kit.label(standSign, "DREAM STAND", Color3.fromRGB(200, 80, 150), nil, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
				-- The winners' podium, with nobody on it and everybody on it.
				local podium = k:at(CFrame.new(12, 0, -10.4))
				-- Second on the viewer's left (+X), third on the right.
				for _, block in ipairs({ { 0, 3.0, "1", C.gold }, { 3.1, 2.1, "2", C.silver }, { -3.1, 1.5, "3", Color3.fromRGB(205, 130, 70) } }) do
					local part = podium:box("PodiumBlock", Vector3.new(3, block[2] + 0.2, 3), CFrame.new(block[1], (block[2] - 0.2) / 2, 0), block[4], Enum.Material.SmoothPlastic)
					Kit.label(part, block[3], C.white, nil, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
				end
				podium:box("TrophyBase", Vector3.new(1.4, 0.6, 1.4), CFrame.new(0, 3.3, 0), C.black, Enum.Material.Marble)
				decor(podium:post("TrophyStem", 0.8, 0.35, Vector3.new(0, 3.6, 0), C.gold, Enum.Material.Foil))
				decor(podium:ball("TrophyCup", 1.4, CFrame.new(0, 4.9, 0), C.gold, Enum.Material.Foil))
				local claim = Pieces.board(podium:at(CFrame.new(0, 0, 2.8)), "WINNER (IN MY HEAD)", 8.6, 1.6, 5.6, Color3.fromRGB(120, 60, 160), PINK, 2, RAIL_WHITE)
				claim.Name = "WinnerBoard"
				-- Clouds, balloons and the odds.
				cloud(k:at(CFrame.new(-16.5, 0, -8.5)), 10, 1)
				cloud(k:at(CFrame.new(1, 0, 12.5)), 11.5, 1.1)
				cloud(k:at(CFrame.new(16.4, 0, 9.4)), 9.5, 0.9)
				balloonBunch(k:at(CFrame.new(17.4, 0, -6.2)), 3, 9)
				balloonBunch(k:at(CFrame.new(-5.2, 0, 8.6)), 2, 10)
				local odds = Pieces.board(k:at(CFrame.new(-11.5, 0, -12.2)), "DELULU DOWNS\nODDS: ALWAYS IN YOUR FAVOUR", 9, 2.6, 2.4, Color3.fromRGB(120, 60, 160), C.white, 2, PINK)
				odds.Name = "OddsBoard"
			end,
		},
		props = {
			{
				id = "HeartBalloons",
				radius = 2.3,
				build = function(k)
					balloonBunch(k, 3, 7)
				end,
			},
			{
				id = "ManifestingBoard",
				radius = 2.6,
				build = function(k)
					local board = Pieces.board(k, "MANIFESTING...", 4.6, 2, 2.6, Color3.fromRGB(120, 60, 160), PINK, 2, RAIL_WHITE)
					board.Name = "ManifestingBoard"
					Kit.emitter(board, { color = Color3.fromRGB(255, 220, 250), size = 0.3, size2 = 0.05, transparency = 0.1, lifetime = 1.6, rate = 5, speed = 1,
						spread = 70, lightEmission = 1, acceleration = Vector3.new(0, 1, 0) })
				end,
			},
			{
				id = "CloudPole",
				radius = 2.7,
				build = function(k)
					cloud(k, 7.5, 0.75)
				end,
			},
			{
				id = "RockingHorse",
				radius = 3.7,
				build = function(k)
					-- Its underside just clear of the ground (the map's z-fight pass had to lift it off the terrain).
					k:trim("HorseMat", Vector3.new(3.4, 0.14, 6.6), CFrame.new(0, 0.13, 0), MINT, Enum.Material.Fabric)
					rockingHorse(k, PASTELS[k.rng:NextInteger(1, #PASTELS)], PINK, k.rng:NextInteger(1, 9), k.rng:NextNumber(0, 6))
				end,
			},
		},
	})
end

-- A palm: a leaning trunk of segments, a crown of fronds and a couple of coconuts. `lean` is a
-- flat local direction. Shared by the two waterside towns.
function Pieces.palm(k, height, lean)
	local trunk = Color3.fromRGB(150, 116, 78)
	lean = (lean and lean.Magnitude > 0.05) and lean.Unit or Vector3.new(1, 0, 0)
	local segments = math.max(3, math.floor(height / 3.2))
	local point = Vector3.new(0, -1.2, 0)
	for segment = 1, segments do
		local rise = (segment == 1) and (height / segments + 1.2) or height / segments
		local nextPoint = point + Vector3.new(0, rise, 0) + lean * (0.3 * segment)
		k:rod("PalmTrunk", point, nextPoint + (nextPoint - point).Unit * 0.25, 1.4 - segment * 0.06, trunk, Enum.Material.Wood)
		point = nextPoint
	end
	-- Fronds scale with the tree, so a crown stays about half its height across.
	local frond = math.clamp(height * 0.55, 4, 7)
	for index = 1, 7 do
		local yaw = index / 7 * math.pi * 2
		k:trim("PalmFrond", Vector3.new(2.0, 0.25, frond), CFrame.new(point) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-24), 0, 0) * CFrame.new(0, 0, -frond / 2 + 0.3),
			Color3.fromRGB(62, 136, 62), Enum.Material.Grass)
	end
	for _, offset in ipairs({ Vector3.new(0.7, -0.8, 0.4), Vector3.new(-0.6, -0.9, -0.3) }) do
		decor(k:ball("Coconut", 1.1, CFrame.new(point + offset), Color3.fromRGB(96, 66, 40), Enum.Material.Wood))
	end
	return point
end

-- A pool built from parts: a floor you stand on, a sheet of glass water you wade through at
-- ankle height, and whatever rim the caller puts round it.
function Pieces.pool(k, diameter, waterColor)
	k:disc("PoolFloor", 0.3, diameter, Vector3.new(0, 0.15, 0), waterColor:Lerp(Color3.new(0, 0, 0), 0.45), Enum.Material.Sand)
	local water = decor(k:disc("PoolWater", 0.45, diameter - 0.4, Vector3.new(0, 0.88, 0), waterColor, Enum.Material.Glass))
	water.Transparency = 0.3
	return water
end

--------------------------------------------------------------------------------
-- Lag Lagoon: a lagoon where the frames stopped arriving
--------------------------------------------------------------------------------

do
	local WATER = Color3.fromRGB(70, 200, 220)
	local MAGENTA = Color3.fromRGB(255, 0, 220)
	local ROCK = Color3.fromRGB(176, 164, 140)
	local HULL = Color3.fromRGB(236, 120, 60)

	-- A cube textured like a missing texture: eight smaller cubes in a checkerboard, on a hub that
	-- spins it in the air.
	local function glitchCube(k, at, size, spin)
		local tilt = CFrame.Angles(k.rng:NextNumber(-0.6, 0.6), k.rng:NextNumber(0, math.pi), k.rng:NextNumber(-0.6, 0.6))
		local hub = floating(k:hub("GlitchHub", CFrame.new(at) * tilt))
		local cube = k:into(hub):at(CFrame.new(at) * tilt)
		local half = size / 4
		for _, x in ipairs({ -1, 1 }) do
			for _, y in ipairs({ -1, 1 }) do
				for _, z in ipairs({ -1, 1 }) do
					local dark = (x * y * z) > 0
					floating(cube:trim("GlitchCube", Vector3.new(size / 2, size / 2, size / 2), CFrame.new(x * half, y * half, z * half), dark and C.black or MAGENTA,
						dark and Enum.Material.SmoothPlastic or Enum.Material.Neon))
				end
			end
		end
		Kit.spin(hub, spin)
		return hub
	end

	-- A little motorboat, in its kit's own frame (bow toward -Z). Returns its parts.
	local function boat(k, transparency, scale)
		local s = scale or 1
		local parts = {
			k:trim("BoatHull", Vector3.new(3, 1.2, 5) * s, CFrame.new(0, 0, 0.5 * s), HULL, Enum.Material.SmoothPlastic),
			k:wedge("BoatBow", Vector3.new(3, 1.2, 2) * s, CFrame.new(0, 0, -3 * s), HULL, Enum.Material.SmoothPlastic),
			k:trim("BoatStripe", Vector3.new(3.1, 0.3, 4.9) * s, CFrame.new(0, 0.2 * s, 0.5 * s), C.white, Enum.Material.SmoothPlastic),
			-- Sunk a little into the hull, so its underside isn't the hull's top.
			k:trim("BoatSeat", Vector3.new(2.6, 0.3, 1) * s, CFrame.new(0, 0.7 * s, 0.8 * s), C.white, Enum.Material.SmoothPlastic),
			k:trim("BoatMotor", Vector3.new(0.9, 1.6, 0.9) * s, CFrame.new(0, 0.6 * s, 3.4 * s), C.charcoal, Enum.Material.Metal),
			k:trim("BoatWindscreen", Vector3.new(2.6, 1.0, 0.12) * s, CFrame.new(0, 1.05 * s, -1.2 * s) * CFrame.Angles(math.rad(-25), 0, 0), Color3.fromRGB(150, 210, 240), Enum.Material.Glass),
			k:trim("BoatWheel", Vector3.new(0.7, 0.7, 0.12) * s, CFrame.new(0.5 * s, 1.0 * s, -0.4 * s) * CFrame.Angles(math.rad(-30), 0, 0), C.charcoal, Enum.Material.Metal),
		}
		for _, part in ipairs(parts) do
			floating(decor(part))
			part.Transparency = transparency
			if transparency > 0 then
				part.CastShadow = false
			end
		end
		return parts
	end

	local function spinnerRing(k, radius, dots, dotSize)
		-- The hub's Y axis points out of the board toward -Z, so the ring turns in the board's plane.
		local hub = k:hub("SpinnerHub", CFrame.Angles(-math.pi / 2, 0, 0))
		local ring = k:into(hub)
		for index = 0, dots - 1 do
			local angle = index / dots * math.pi * 2
			local dot = ring:ball("SpinnerDot", dotSize, CFrame.new(math.cos(angle) * radius, math.sin(angle) * radius, 0), C.white, Enum.Material.Neon)
			decor(dot).Transparency = index / dots * 0.85
		end
		Kit.spin(hub, -220)
		return hub
	end

	defineTheme({
		name = "Lag Lagoon",
		id = "LagLagoon",
		flag = { emblem = "999ms", caption = "LAG LAGOON", color = Color3.fromRGB(30, 110, 130), text = MAGENTA, trim = C.white, font = Enum.Font.RobotoMono },
		setPiece = {
			id = "FrozenLagoon",
			name = "The Frozen Lagoon",
			-- 40 x 32 so the leaping boat's last skipped frame stays on the ground it claims.
			width = 40,
			depth = 32,
			ground = Enum.Material.Sand,
			build = function(k)
				local lagoon = k:at(CFrame.new(-5, 0, 3))
				Pieces.pool(lagoon, 18, WATER)
				-- A rim of rocks, open at the front for the jetty.
				for index = 0, 15 do
					if index ~= 12 then
						local tall = index % 2 == 1
						lagoon:box("LagoonRim", Vector3.new(3.8, tall and 1.5 or 1.4, 1.0), CFrame.Angles(0, index * math.pi / 8 + math.pi / 2, 0) * CFrame.new(0, 0.5, -9.3),
							ROCK, Enum.Material.Sandstone)
					end
				end
				for _, x in ipairs({ -1.2, 1.2 }) do
					for _, z in ipairs({ -11.4, -7.8 }) do
						lagoon:post("JettyPost", 1.5, 0.35, Vector3.new(x, -0.2, z), C.darkWood, Enum.Material.Wood)
					end
				end
				lagoon:box("Jetty", Vector3.new(3, 0.3, 6.6), CFrame.new(0, 1.45, -9.3), C.wood, Enum.Material.WoodPlanks)
				-- A crate that can't decide where it is.
				lagoon:box("LagCrate", Vector3.new(1.6, 1.6, 1.6), CFrame.new(0, 2.4, -10.8), C.wood, Enum.Material.WoodPlanks)
				for step, fade in ipairs({ 0.6, 0.82 }) do
					local ghost = lagoon:trim("LagCrateGhost", Vector3.new(1.6, 1.6, 1.6), CFrame.new(step * 0.7, 2.4 + step * 0.1, -10.8 + step * 0.45), C.wood, Enum.Material.WoodPlanks)
					ghost.Transparency = fade
					ghost.CastShadow = false
				end

				-- The boat, frozen mid-jump, with the frames it skipped trailing behind it.
				-- Broadside to the street, nose up, so from the street you see a boat's whole profile
				-- leaping across the lagoon with its skipped frames strung out behind.
				local path = CFrame.new(0, 7.5, 2) * CFrame.Angles(0, math.rad(-75), 0) * CFrame.Angles(math.rad(20), 0, math.rad(6))
				boat(lagoon:at(path), 0, 1.7)
				for step, fade in ipairs({ 0.45, 0.66, 0.84 }) do
					-- Each skipped frame drifts a little sideways too, so no two copies share a side.
					-- 0.6 down a frame: at 0.55, two frames apart one ghost's stripe underside sat 0.005 off
					-- another's hull underside.
					boat(lagoon:at(path * CFrame.new(0.25 * step, -0.6 * step, 3.2 * step)), fade, 1.7)
				end
				-- The splash it left, which also stopped.
				for index = 0, 7 do
					local angle = index / 8 * math.pi * 2
					local drop = floating(decor(lagoon:ball("FrozenSplash", 0.5 + (index % 3) * 0.2,
						CFrame.new(math.cos(angle) * 1.9, 1.5 + (index % 2) * 0.9, 5 + math.sin(angle) * 1.9), Color3.fromRGB(220, 250, 255), Enum.Material.Neon)))
					drop.Transparency = 0.2
				end
				floating(decor(lagoon:ball("FrozenSplash", 1.3, CFrame.new(0, 2.3, 5), Color3.fromRGB(220, 250, 255), Enum.Material.Neon))).Transparency = 0.3

				glitchCube(k, Vector3.new(9, 7.5, -3), 1.8, 60)
				glitchCube(k, Vector3.new(14.5, 11, 5), 2.2, -45)
				glitchCube(k, Vector3.new(-16, 9, -9), 1.6, 80)
				glitchCube(k, Vector3.new(3, 13, 12), 2.0, 35)

				-- The buffering board.
				local board = k:at(CFrame.new(13.5, 0, 11))
				for _, x in ipairs({ -3.2, 3.2 }) do
					board:box("BufferPost", Vector3.new(0.5, 9.6, 0.5), CFrame.new(x, 4.6, 0.5), C.charcoal, Enum.Material.Metal)
				end
				local panel = board:box("BufferBoard", Vector3.new(7.4, 5.4, 0.4), CFrame.new(0, 6.9, 0), C.black, Enum.Material.SmoothPlastic)
				local caption = board:trim("BufferCaption", Vector3.new(6.6, 1.2, 0.1), CFrame.new(0, 4.9, -0.25), C.black, Enum.Material.SmoothPlastic)
				Kit.label(caption, "BUFFERING...", C.white, C.black, { Enum.NormalId.Front }, Enum.Font.RobotoMono)
				spinnerRing(board:at(CFrame.new(0, 7.6, -0.45)), 1.4, 8, 0.6)
				Kit.light(panel, C.white, 10, 0.4)

				local ping = Pieces.board(k:at(CFrame.new(-13.5, 0, -12.4)), "PING: 999ms", 6, 1.8, 2.4, Color3.fromRGB(255, 70, 70), C.black, 2, C.iron)
				ping.Name = "PingBoard"
				-- A banner strung between two poles.
				for _, x in ipairs({ -18.4, -8.6 }) do
					k:post("BannerPole", 8.6, 0.4, Vector3.new(x, 0, 13.8), C.white, Enum.Material.Metal)
				end
				local banner = k:trim("ReconnectBanner", Vector3.new(9.4, 1.5, 0.1), CFrame.new(-13.5, 7.4, 13.8), C.white, Enum.Material.Fabric)
				Kit.label(banner, "RECONNECTING...", Color3.fromRGB(30, 110, 130), nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.RobotoMono)
				Pieces.palm(k:at(CFrame.new(15.5, 0, 2)), 12, Vector3.new(-0.6, 0, 1))
				Pieces.palm(k:at(CFrame.new(-15.5, 0, 9.5)), 10, Vector3.new(0.4, 0, -1))
			end,
		},
		props = {
			{
				id = "GlitchPost",
				radius = 1.6,
				build = function(k)
					k:post("GlitchPost", 3.6, 0.35, Vector3.zero, C.charcoal, Enum.Material.Metal)
					glitchCube(k, Vector3.new(0, 5.4, 0), 1.8, 70)
				end,
			},
			{
				id = "LoadingSign",
				radius = 1.8,
				build = function(k)
					k:post("LoadingPost", 5, 0.35, Vector3.new(0, 0, 0.35), C.charcoal, Enum.Material.Metal)
					k:box("LoadingBoard", Vector3.new(3.2, 3.4, 0.3), CFrame.new(0, 5.6, 0), C.black, Enum.Material.SmoothPlastic)
					local text = k:trim("LoadingText", Vector3.new(3.0, 0.8, 0.1), CFrame.new(0, 4.4, -0.2), C.black, Enum.Material.SmoothPlastic)
					Kit.label(text, "LOADING...", C.white, C.black, { Enum.NormalId.Front }, Enum.Font.RobotoMono)
					spinnerRing(k:at(CFrame.new(0, 6.3, -0.33)), 0.8, 8, 0.36)
				end,
			},
			{
				id = "PingSign",
				radius = 1.6,
				build = function(k)
					local values = { "PING 999", "PING 420", "PING 67", "FPS: 3" }
					local board = Pieces.board(k, values[k.rng:NextInteger(1, #values)], 2.8, 1.2, 3.4, Color3.fromRGB(255, 70, 70), C.black, 1, C.iron)
					board.Name = "PingSign"
				end,
			},
			{
				id = "LaggyBench",
				radius = 4.0,
				build = function(k)
					Pieces.bench(k, C.wood)
					for step, fade in ipairs({ 0.62, 0.84 }) do
						local ghost = k:at(CFrame.new(step * 0.55, step * 0.1, step * 0.35))
						for _, part in ipairs({
							ghost:trim("BenchGhost", Vector3.new(5, 0.4, 1.8), CFrame.new(0, 1.9, 0), C.wood, Enum.Material.WoodPlanks),
							ghost:trim("BenchGhost", Vector3.new(5, 1.6, 0.35), CFrame.new(0, 3.0, 0.8), C.wood, Enum.Material.WoodPlanks),
						}) do
							part.Transparency = fade
							part.CastShadow = false
						end
					end
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Oof Oasis: the prettiest place in the desert to fall over
--------------------------------------------------------------------------------

do
	local WATER = Color3.fromRGB(60, 170, 230)
	local SANDSTONE = Color3.fromRGB(206, 154, 96)
	local CANVAS = Color3.fromRGB(240, 210, 156)
	local AID_GREEN = Color3.fromRGB(60, 200, 90)
	local BANANA = Color3.fromRGB(250, 220, 70)
	local CLAY = Color3.fromRGB(190, 110, 70)

	-- Block letters seven units tall, as bars: { x, y, width, height } of each bar's centre and size,
	-- scaled by `scale`. Seen from the front a kit's +X is the viewer's left, so an F's upright is on
	-- +X and its arms reach toward -X. Bars butt against each other rather than overlapping, and the
	-- whole letter is sunk 0.3.
	local LETTERS = {
		O = { { -2.2, 3.5, 1.6, 7 }, { 2.2, 3.5, 1.6, 7 }, { 0, 6.2, 2.8, 1.6 }, { 0, 0.8, 2.8, 1.6 } },
		F = { { 2.2, 3.5, 1.6, 7 }, { -0.8, 6.2, 4.4, 1.6 }, { -0.3, 3.6, 3.4, 1.4 } },
	}
	local function blockLetter(k, letter, depth, scale)
		for _, bar in ipairs(LETTERS[letter]) do
			k:box("OofLetter", Vector3.new(bar[3] * scale, bar[4] * scale, depth), CFrame.new(bar[1] * scale, bar[2] * scale - 0.3, 0), SANDSTONE, Enum.Material.Sandstone)
		end
	end

	local function bananaPeel(k)
		-- Three flaps splayed out, each a step higher than the last where they cross in the middle.
		for index = 0, 2 do
			k:trim("BananaPeel", Vector3.new(0.35, 0.12, 1.1), CFrame.new(0, 0.08 + index * 0.05, 0) * CFrame.Angles(0, index * 2.1 + 0.4, 0) * CFrame.new(0, 0, -0.45), BANANA, Enum.Material.SmoothPlastic)
		end
		decor(k:ball("BananaStem", 0.35, CFrame.new(0, 0.14, 0), Color3.fromRGB(120, 96, 40), Enum.Material.SmoothPlastic))
	end

	local function wetFloorSign(k, text)
		for _, side in ipairs({ -1, 1 }) do
			local board = k:box("WetFloorSign", Vector3.new(side < 0 and 1.6 or 1.4, 2.4, 0.12), CFrame.new(0, 1.15, side * 0.38) * CFrame.Angles(math.rad(side * 16), 0, 0), BANANA, Enum.Material.SmoothPlastic)
			Kit.label(board, text, C.black, nil, { side < 0 and Enum.NormalId.Front or Enum.NormalId.Back }, Enum.Font.GothamBlack)
		end
	end

	local function clayPots(k)
		for index, pot in ipairs({ { 0, 0, 1.8 }, { 1.6, 0.5, 1.4 }, { -1.3, 0.8, 1.2 } }) do
			local size = pot[3]
			k:ball("ClayPot", size, CFrame.new(pot[1], size * 0.45, pot[2]), CLAY:Lerp(C.black, index * 0.06), Enum.Material.Sandstone)
			decor(k:post("ClayPotNeck", size * 0.35, size * 0.45, Vector3.new(pot[1], size * 0.85, pot[2]), CLAY, Enum.Material.Sandstone))
		end
	end

	local function aidTent(k)
		-- An A-frame of canvas with its ridge running back from the front.
		for _, side in ipairs({ -1, 1 }) do
			local panel = k:trim("TentCanvas", Vector3.new(0.2, 6.4, side < 0 and 8 or 7.9), CFrame.new(side * 1.84, 2.58, 0) * CFrame.Angles(0, 0, math.rad(35 * side)), CANVAS, Enum.Material.Fabric)
			panel.CastShadow = true
		end
		for _, z in ipairs({ -4.0, 3.8 }) do
			k:post("TentPole", 5.3, 0.3, Vector3.new(0, 0, z), C.darkWood, Enum.Material.Wood)
		end
		k:trim("TentRidge", Vector3.new(0.3, 0.3, 8.4), CFrame.new(0, 5.25, 0), C.darkWood, Enum.Material.Wood)
		k:box("TentCot", Vector3.new(1.8, 0.4, 4), CFrame.new(-0.5, 1.2, 0.6), Color3.fromRGB(90, 120, 90), Enum.Material.Fabric)
		for _, z in ipairs({ -1.6, 2.8 }) do
			k:box("CotLeg", Vector3.new(1.6, 1.0, 0.25), CFrame.new(-0.5, 0.5, z), C.darkWood, Enum.Material.Wood)
		end
		decor(k:box("CotPillow", Vector3.new(1.4, 0.35, 0.9), CFrame.new(-0.5, 1.55, 2.2), C.white, Enum.Material.Fabric))
		local sign = k:at(CFrame.new(3.6, 0, -4.4))
		local board = Pieces.board(sign, "FIRST AID\n(for oofs)", 2.8, 1.8, 2.2, C.black, C.white, 1, C.darkWood)
		board.Name = "AidSign"
		local cross = k:at(CFrame.new(0, 3.1, -4.2))
		cross:box("AidPlate", Vector3.new(2.4, 2.4, 0.15), CFrame.identity, C.white, Enum.Material.SmoothPlastic)
		cross:trim("AidCross", Vector3.new(1.8, 0.55, 0.1), CFrame.new(0, 0, -0.12), AID_GREEN, Enum.Material.Neon)
		cross:trim("AidCross", Vector3.new(0.55, 1.8, 0.14), CFrame.new(0, 0, -0.19), AID_GREEN, Enum.Material.Neon)
	end

	defineTheme({
		name = "Oof Oasis",
		id = "OofOasis",
		flag = { emblem = "OOF", caption = "OOF OASIS", color = Color3.fromRGB(40, 150, 190), text = C.white, trim = SANDSTONE },
		setPiece = {
			id = "Oasis",
			name = "The Oof Oasis",
			width = 38,
			depth = 32,
			ground = Enum.Material.Sand,
			build = function(k)
				local pool = k:at(CFrame.new(-3, 0, 2))
				Pieces.pool(pool, 16, WATER)
				for index = 0, 11 do
					local angle = index / 12 * math.pi * 2 + 0.15
					local size = 2.2 + (index % 3) * 0.5
					pool:ball("OasisBoulder", size, CFrame.new(math.cos(angle) * 8.6, size * 0.2, math.sin(angle) * 8.6), SANDSTONE:Lerp(C.black, (index % 4) * 0.05), Enum.Material.Sandstone)
				end
				-- Two palms out to the sides and two at the front corners: the back of the pool is left
				-- clear, because palms there stood right in front of the letters from the street.
				for index, angle in ipairs({ 0, math.pi, -0.9, 4.0 }) do
					local at = Vector3.new(math.cos(angle) * 11, 0, math.sin(angle) * 11)
					Pieces.palm(pool:at(CFrame.new(at)), 10 + index, Vector3.new(at.X, 0, at.Z))
				end
				local plaque = Pieces.plaque(pool:at(CFrame.new(-4.2, 0, -10.6)), "NO RUNNING\n(YOU WILL OOF)", 3.6)
				plaque.Name = "PoolPlaque"
				-- The letters at the back, the F having clearly tripped.
				local letters = k:at(CFrame.new(-1.5, 0, 13.6))
				-- O, O, F from the viewer's left (+X) to right, the F having clearly tripped.
				-- Half again as big as they were, and spaced to match: from the street they were reading as
				-- sandstone ruins rather than letters.
				blockLetter(letters:at(CFrame.new(10.5, 0, 0) * CFrame.Angles(0, math.rad(4), 0)), "O", 2.2, 1.6)
				blockLetter(letters:at(CFrame.new(0.4, 0, 0) * CFrame.Angles(0, math.rad(-3), 0)), "O", 2.2, 1.6)
				blockLetter(letters:at(CFrame.new(-9.7, 0, 0) * CFrame.Angles(0, math.rad(-6), math.rad(9))), "F", 2.2, 1.6)
				aidTent(k:at(CFrame.new(13, 0, -3)))
				for index, spot in ipairs({ { -9.5, -9.8 }, { -7.6, -11.2 }, { -11, -12.4 } }) do
					bananaPeel(k:at(CFrame.new(spot[1], 0, spot[2]) * CFrame.Angles(0, index, 0)))
				end
				wetFloorSign(k:at(CFrame.new(-14.8, 0, -10.8)), "CAUTION\nSLIPPERY")
				clayPots(k:at(CFrame.new(14.5, 0, 9)))
			end,
		},
		props = {
			{
				id = "BananaHazard",
				radius = 2.0,
				build = function(k)
					bananaPeel(k:at(CFrame.new(-0.6, 0, -0.9)))
					wetFloorSign(k:at(CFrame.new(0.7, 0, 0.6)), "OOF\nZONE")
				end,
			},
			{ id = "ClayPots", radius = 2.4, build = clayPots },
			{
				id = "OofWarning",
				radius = 1.8,
				build = function(k)
					k:post("WarningPost", 3.8, 0.3, Vector3.new(0, 0, 0.2), C.steel, Enum.Material.Metal)
					local sign = k:at(CFrame.new(0, 5.2, 0))
					sign:box("WarningDiamond", Vector3.new(2.4, 2.4, 0.15), CFrame.Angles(0, 0, math.pi / 4), BANANA, Enum.Material.SmoothPlastic)
					local text = sign:trim("WarningText", Vector3.new(2.6, 1.0, 0.1), CFrame.new(0, 0, -0.13), BANANA, Enum.Material.SmoothPlastic)
					Kit.label(text, "OOF AHEAD", C.black, nil, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
				end,
			},
			{
				id = "OasisPalm",
				radius = 4.4,
				build = function(k)
					k:ball("PalmMound", 2.6, CFrame.new(0, 0.2, 0), SANDSTONE, Enum.Material.Sand)
					Pieces.palm(k, 9 + k.rng:NextNumber(0, 3), Vector3.new(k.rng:NextNumber(-1, 1), 0, k.rng:NextNumber(-1, 1)))
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Mewing Meadows: a wildflower meadow round a monument to one perfect jawline
--------------------------------------------------------------------------------

do
	local MARBLE = Color3.fromRGB(232, 228, 220)
	local HEDGE = Color3.fromRGB(62, 120, 58)
	local FLOWERS = { Color3.fromRGB(255, 150, 190), Color3.fromRGB(255, 230, 90), Color3.fromRGB(190, 150, 255), Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 160, 80) }

	local function flower(k, at, color, height)
		decor(k:post("FlowerStem", height, 0.14, at, Color3.fromRGB(80, 150, 70), Enum.Material.SmoothPlastic))
		decor(k:ball("FlowerHead", 0.75 + height * 0.12, CFrame.new(at + Vector3.new(0, height + 0.15, 0)), color, Enum.Material.SmoothPlastic))
	end

	-- The Great Jawline, in profile, facing +X: the street sees the side of the face, and the jaw
	-- is the part that was carved with the most care.
	local function jawline(k)
		local s = 1.35
		local function box(name, size, x, y, z, rz)
			return k:box(name, size * s, CFrame.new(x * s, y * s, z * s) * CFrame.Angles(0, 0, math.rad(rz or 0)), MARBLE, Enum.Material.Marble)
		end
		box("JawNeck", Vector3.new(2.6, 3, 2.6), -0.4, 1.5, 0)
		box("JawCranium", Vector3.new(4.6, 4.2, 4.2), -0.6, 6.4, 0)
		k:ball("JawSkull", 4.6 * s, CFrame.new(-1.6 * s, 6.8 * s, 0), MARBLE, Enum.Material.Marble)
		box("JawFace", Vector3.new(1.2, 4, 3.6), 1.9, 5.9, 0)
		box("JawBrow", Vector3.new(1.2, 0.8, 3.8), 2.3, 7.4, 0)
		k:wedge("JawNose", Vector3.new(1.1 * s, 1.8 * s, 1.5 * s), CFrame.new(3.1 * s, 6.3 * s, 0) * CFrame.Angles(0, -math.pi / 2, 0), MARBLE, Enum.Material.Marble)
		box("JawLips", Vector3.new(0.6, 0.35, 1.6), 2.55, 4.9, 0)
		-- The jaw: a long block angled down to a chin like a chisel.
		box("TheJaw", Vector3.new(4.6, 1.6, 4.0), 0.9, 4.2, 0, -25)
		local chin = box("TheChin", Vector3.new(1.6, 1.8, 2.6), 2.7, 3.4, 0, -10)
		-- The jaw's lower edges picked out in gold, both sides, so the line reads from across the street.
		for _, z in ipairs({ -2.05, 2.05 }) do
			local edge = k:trim("JawlineGold", Vector3.new(4.7 * s, 0.2 * s, 0.2 * s), CFrame.new(0.9 * s, 4.2 * s, 0) * CFrame.Angles(0, 0, math.rad(-25)) * CFrame.new(0, -0.8 * s, z * s),
				C.gold, Enum.Material.Neon)
			edge.Transparency = 0.1
		end
		for _, z in ipairs({ -1, 1 }) do
			k:trim("JawEye", Vector3.new(0.3, 0.5, 0.8) * s, CFrame.new(2.55 * s, 6.7 * s, z * 1.1 * s), Color3.fromRGB(150, 146, 140), Enum.Material.Marble)
			k:trim("JawEar", Vector3.new(0.5, 1.6, 1.0) * s, CFrame.new(-1.2 * s, 6.0 * s, z * 2.35 * s), MARBLE, Enum.Material.Marble)
		end
		Kit.emitter(chin, { color = Color3.fromRGB(255, 250, 220), size = 0.5, size2 = 0.05, transparency = 0, lifetime = 1.2, rate = 4, speed = 0.6, spread = 90, lightEmission = 1 })
	end

	local function catTopiary(k, scale)
		local s = scale or 1
		k:box("CatPlanter", Vector3.new(4.4, 1.2, 4.4) * s, CFrame.new(0, 0.4 * s, 0), Color3.fromRGB(170, 110, 84), Enum.Material.Brick)
		k:ball("CatBody", 4 * s, CFrame.new(0, 2.8 * s, 0.4 * s), HEDGE, Enum.Material.LeafyGrass)
		k:ball("CatChest", 3 * s, CFrame.new(0, 3.9 * s, -0.9 * s), HEDGE, Enum.Material.LeafyGrass)
		k:ball("CatHead", 2.8 * s, CFrame.new(0, 6.0 * s, -1.2 * s), HEDGE, Enum.Material.LeafyGrass)
		-- Pointed ears, each two wedges back to back leaning out a little (round ones made bears).
		for _, side in ipairs({ -1, 1 }) do
			local ear = CFrame.new(side * 0.8 * s, 7.55 * s, -1.2 * s) * CFrame.Angles(0, 0, -side * 0.28)
			k:wedge("CatEar", Vector3.new(0.5, 1.8, 0.6) * s, ear * CFrame.new(-0.3 * s, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), HEDGE, Enum.Material.LeafyGrass)
			k:wedge("CatEar", Vector3.new(0.5, 1.8, 0.6) * s, ear * CFrame.new(0.3 * s, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), HEDGE, Enum.Material.LeafyGrass)
		end
		-- A jaw you could cut glass with.
		k:trim("CatJaw", Vector3.new(1.6, 1.0, 1.0) * s, CFrame.new(0, 5.0 * s, -2.1 * s) * CFrame.Angles(math.pi / 4, 0, 0), HEDGE:Lerp(C.black, 0.1), Enum.Material.LeafyGrass)
		for index, spot in ipairs({ { 1.6, 2.0, 2.2 }, { 2.1, 3.2, 2.6 }, { 2.0, 4.4, 2.3 } }) do
			decor(k:ball("CatTail", (1.1 - index * 0.12) * s, CFrame.new(spot[1] * s, spot[2] * s, spot[3] * s), HEDGE, Enum.Material.LeafyGrass))
		end
	end

	local function beehive(k)
		k:box("HiveStand", Vector3.new(2.4, 1.2, 2.4), CFrame.new(0, 0.4, 0), C.darkWood, Enum.Material.Wood)
		for layer = 0, 2 do
			k:box("HiveBox", Vector3.new(2.2, 1.0, 2.2), CFrame.new(0, 1.5 + layer * 1.0, 0), layer % 2 == 0 and C.white or Color3.fromRGB(250, 236, 180), Enum.Material.WoodPlanks)
		end
		k:box("HiveRoof", Vector3.new(2.6, 0.35, 2.6), CFrame.new(0, 4.175, 0), Color3.fromRGB(120, 100, 80), Enum.Material.WoodPlanks)
		for index = 1, 3 do
			local bee = floating(decor(k:ball("Bee", 0.35, CFrame.new(k.rng:NextNumber(-1.4, 1.4), 3 + k.rng:NextNumber(0, 2), k.rng:NextNumber(-1.8, -1)), Color3.fromRGB(250, 200, 40), Enum.Material.SmoothPlastic)))
			Kit.bob(bee, 0.5, 3 + index, index)
		end
	end

	local function butterfly(k, at, color, phase)
		for _, side in ipairs({ -1, 1 }) do
			local wing = floating(k:trim("ButterflyWing", Vector3.new(0.8, 0.06, 0.65), CFrame.new(at + Vector3.new(side * 0.36, 0, 0)) * CFrame.Angles(0, 0, math.rad(side * 30)), color, Enum.Material.SmoothPlastic))
			Kit.bob(wing, 0.6, 1.7, phase)
		end
	end

	defineTheme({
		name = "Mewing Meadows",
		id = "MewingMeadows",
		flag = { emblem = "SHH...", caption = "MEWING MEADOWS", color = Color3.fromRGB(88, 150, 90), text = C.white, trim = Color3.fromRGB(255, 190, 220) },
		setPiece = {
			id = "JawlineMeadow",
			name = "The Great Jawline",
			width = 36,
			depth = 30,
			ground = Enum.Material.LeafyGrass,
			build = function(k)
				local monument = k:at(CFrame.new(0, 0, 7))
				monument:box("JawPlinth", Vector3.new(10, 1.2, 8), CFrame.new(0, 0.4, 0), MARBLE:Lerp(C.black, 0.12), Enum.Material.Marble)
				monument:box("JawPlinth", Vector3.new(8, 1.2, 6), CFrame.new(0, 1.6, 0), MARBLE:Lerp(C.black, 0.06), Enum.Material.Marble)
				jawline(monument:at(CFrame.new(-0.4, 2.2, 0)))
				local plaque = monument:trim("JawPlaque", Vector3.new(6, 0.9, 0.15), CFrame.new(0, 0.5, -4.08), C.brass, Enum.Material.Metal)
				Kit.label(plaque, "THE GREAT JAWLINE  •  HOLD THE POSE", C.black)
				catTopiary(k:at(CFrame.new(-11.5, 0, 6)), 1)
				catTopiary(k:at(CFrame.new(11.5, 0, 6)), 1)

				-- The mirror, for checking progress.
				local mirror = k:at(CFrame.new(11, 0, -9) * CFrame.Angles(0, math.rad(-20), 0))
				for _, x in ipairs({ -0.9, 0.9 }) do
					mirror:box("MirrorLeg", Vector3.new(0.25, 2.2, 0.25), CFrame.new(x, 1.1, 0.3), C.gold, Enum.Material.Foil)
				end
				mirror:box("MirrorFrame", Vector3.new(2.6, 4.2, 0.3), CFrame.new(0, 4.3, 0), C.gold, Enum.Material.Foil)
				local glass = mirror:trim("MirrorGlass", Vector3.new(2.2, 3.8, 0.1), CFrame.new(0, 4.3, -0.2), Color3.fromRGB(210, 225, 235), Enum.Material.Glass)
				glass.Reflectance = 0.55
				local mirrorSign = mirror:trim("MirrorSign", Vector3.new(2.6, 0.7, 0.1), CFrame.new(0, 6.8, -0.1), C.white, Enum.Material.SmoothPlastic)
				Kit.label(mirrorSign, "LOOKSMAX MIRROR", C.black, nil, { Enum.NormalId.Front }, Enum.Font.GothamBold)

				beehive(k:at(CFrame.new(-13, 0, -8.5)))
				beehive(k:at(CFrame.new(-16, 0, -5.4)))
				local hush = Pieces.board(k:at(CFrame.new(-5, 0, -12.6)), "SHH... MEWING IN PROGRESS", 7, 1.6, 2.4, C.white, Color3.fromRGB(88, 150, 90), 2, C.darkWood)
				hush.Name = "HushSign"
				for _, x in ipairs({ -12.5, 12.5 }) do
					k:box("MeadowHedge", Vector3.new(10, 1.6, 1.2), CFrame.new(x, 0.6, -14.2), HEDGE, Enum.Material.LeafyGrass)
				end

				-- Wildflowers everywhere the monument, the cats and the rest aren't.
				local clear = {
					{ 0, 7, 6.5 }, { -11.5, 6, 3.4 }, { 11.5, 6, 3.4 }, { 11, -9, 2.2 }, { -13, -8.5, 2 }, { -16, -5.4, 2 }, { -5, -12.6, 4.2 },
				}
				local placed = 0
				for _ = 1, 120 do
					if placed >= 44 then
						break
					end
					local x, z = k.rng:NextNumber(-17, 17), k.rng:NextNumber(-13, 14)
					local free = math.abs(x) > 6.5 or z < -3
					for _, spot in ipairs(clear) do
						if (Vector2.new(x - spot[1], z - spot[2])).Magnitude < spot[3] then
							free = false
							break
						end
					end
					if free and z > -13.4 then
						placed += 1
						flower(k, Vector3.new(x, 0, z), FLOWERS[k.rng:NextInteger(1, #FLOWERS)], k.rng:NextNumber(0.8, 1.8))
					end
				end
				for index, spot in ipairs({ Vector3.new(-6, 4, -6), Vector3.new(6.5, 5.5, -2), Vector3.new(-8, 6, 12), Vector3.new(16, 4.5, -2) }) do
					butterfly(k, spot, FLOWERS[index], index * 1.3)
				end
			end,
		},
		props = {
			{
				id = "FlowerBed",
				radius = 2.6,
				build = function(k)
					k:box("FlowerBedBox", Vector3.new(4.4, 0.9, 2.4), CFrame.new(0, 0.35, 0), C.darkWood, Enum.Material.WoodPlanks)
					k:trim("FlowerBedSoil", Vector3.new(4.0, 0.12, 2.0), CFrame.new(0, 0.84, 0), Color3.fromRGB(80, 58, 40), Enum.Material.Ground)
					for index = 0, 7 do
						flower(k, Vector3.new(-1.6 + (index % 4) * 1.05, 0.9, -0.5 + (index > 3 and 1 or 0)), FLOWERS[index % #FLOWERS + 1], 0.9 + (index % 3) * 0.3)
					end
				end,
			},
			{
				id = "HushSign",
				radius = 1.8,
				build = function(k)
					local board = Pieces.board(k, "SHH...\nMEWING", 2.8, 1.8, 2.6, C.white, Color3.fromRGB(88, 150, 90), 1, C.darkWood)
					board.Name = "HushSign"
				end,
			},
			{
				id = "CatTopiary",
				radius = 2.3,
				build = function(k)
					catTopiary(k, 0.7)
				end,
			},
			{ id = "Beehive", radius = 1.9, build = beehive },
		},
	})
end

--------------------------------------------------------------------------------
-- Brainrot Borough: the civic heart of brainrot, and its greatest resource
--------------------------------------------------------------------------------

do
	local MARBLE = Color3.fromRGB(230, 226, 216)
	local BRAIN = Color3.fromRGB(240, 150, 172)
	local BRAIN_DARK = Color3.fromRGB(196, 100, 128)
	local CRT_BEIGE = Color3.fromRGB(196, 186, 164)
	local CRT_DARK = Color3.fromRGB(62, 60, 58)
	local STATIC = Color3.fromRGB(170, 190, 210)
	local SPARK = Color3.fromRGB(255, 236, 90)
	local SCREENS = { "BRAINROT", "67", "AURA\n+1000", "NPC", "LOADING...", "RIZZ", "SIGMA", "", "", "" }

	-- A brain: two hemispheres of lobes with a fissure between, about 6 wide.
	local function brain(k, scale)
		local s = scale or 1
		local lobes = { { 0, 0, 0, 3.4 }, { 0, 1.2, 1.4, 2.2 }, { 0, 1.2, -1.4, 2.2 }, { 0.6, -0.8, 1.6, 2.1 }, { 0.6, -0.8, -1.6, 2.1 }, { 0.7, 1.4, 0, 2.3 }, { 0.2, -1.2, 0, 2.2 } }
		for _, side in ipairs({ -1, 1 }) do
			for index, lobe in ipairs(lobes) do
				local at = Vector3.new(side * (1.35 + lobe[1]), lobe[2], lobe[3]) * s
				k:ball("BrainLobe", lobe[4] * s, CFrame.new(at), index % 2 == 0 and BRAIN or BRAIN:Lerp(BRAIN_DARK, 0.25), Enum.Material.SmoothPlastic)
			end
		end
		return k:trim("BrainFissure", Vector3.new(0.3, 3.4, 5.6) * s, CFrame.new(0, 0.5 * s, 0), BRAIN_DARK, Enum.Material.SmoothPlastic)
	end

	-- A crackle of lightning: three short neon bars in a zigzag, bobbing together.
	local function spark(k, at, phase)
		for index = 0, 2 do
			local bar = floating(k:trim("BrainSpark", Vector3.new(0.3, 1.3, 0.3), CFrame.new(at + Vector3.new((index % 2) * 0.5, -index * 1.05, 0)) * CFrame.Angles(0, 0, math.rad(index % 2 == 0 and 35 or -35)),
				SPARK, Enum.Material.Neon))
			Kit.bob(bar, 0.3, 4.5, phase)
		end
	end

	local function crt(k, text, color)
		k:box("CrtTelly", Vector3.new(3.2, 2.8, 2.8), CFrame.new(0, 1.4, 0), color, Enum.Material.SmoothPlastic)
		local screen = k:trim("CrtScreen", Vector3.new(2.5, 2.0, 0.12), CFrame.new(-0.15, 1.45, -1.46), STATIC, Enum.Material.Neon)
		screen.Transparency = 0.05
		if text ~= "" then
			Kit.label(screen, text, Color3.fromRGB(30, 30, 40), nil, { Enum.NormalId.Front }, Enum.Font.Arcade)
		end
		k:trim("CrtKnob", Vector3.new(0.3, 0.3, 0.15), CFrame.new(1.3, 1.9, -1.47), C.black, Enum.Material.SmoothPlastic)
		k:trim("CrtKnob", Vector3.new(0.3, 0.3, 0.15), CFrame.new(1.3, 1.1, -1.47), C.black, Enum.Material.SmoothPlastic)
	end

	local function tvPyramid(k)
		local rows = { 4, 3, 2, 1 }
		for row, count in ipairs(rows) do
			-- Spaced so a set's slight twist never brings two corners together: sets in a row share
			-- their top and bottom heights, so any overlap there would be two faces in one plane.
			for index = 1, count do
				local x = (index - (count + 1) / 2) * 3.55
				local text = SCREENS[k.rng:NextInteger(1, #SCREENS)]
				local color = (index + row) % 2 == 0 and CRT_BEIGE or CRT_DARK
				crt(k:at(CFrame.new(x, (row - 1) * 2.8, 0) * CFrame.Angles(0, math.rad(k.rng:NextNumber(-4, 4)), 0)), text, color)
			end
		end
		for _, lean in ipairs({ -0.5, 0.5 }) do
			decor(k:rod("CrtAntenna", Vector3.new(0, 11.2, 0.4), Vector3.new(lean * 3.2, 14, 0.4), 0.12, C.silver, Enum.Material.Metal))
		end
	end

	local function portico(k)
		k:box("HallStep", Vector3.new(22, 0.8, 7), CFrame.new(0, 0.2, 0), MARBLE:Lerp(C.black, 0.1), Enum.Material.Marble)
		k:box("HallStep", Vector3.new(20, 0.6, 6), CFrame.new(0, 0.9, 0.3), MARBLE:Lerp(C.black, 0.05), Enum.Material.Marble)
		k:box("HallStylobate", Vector3.new(18, 0.6, 5), CFrame.new(0, 1.5, 0.5), MARBLE, Enum.Material.Marble)
		for _, x in ipairs({ -6.6, -2.2, 2.2, 6.6 }) do
			k:post("HallColumnBase", 0.4, 2.1, Vector3.new(x, 1.8, -1.1), MARBLE, Enum.Material.Marble)
			k:post("HallColumn", 8.6, 1.6, Vector3.new(x, 2.2, -1.1), MARBLE, Enum.Material.Marble)
			k:box("HallCapital", Vector3.new(2.2, 0.6, 2.2), CFrame.new(x, 11.1, -1.1), MARBLE, Enum.Material.Marble)
		end
		k:box("HallEntablature", Vector3.new(18, 1.6, 4.2), CFrame.new(0, 12.2, 0.4), MARBLE, Enum.Material.Marble)
		local frieze = k:trim("HallFrieze", Vector3.new(15, 1.0, 0.1), CFrame.new(0, 12.2, -1.75), MARBLE, Enum.Material.Marble)
		Kit.label(frieze, "BRAINROT BOROUGH COUNCIL", Color3.fromRGB(90, 70, 80), nil, { Enum.NormalId.Front }, Enum.Font.Garamond)
		k:wedge("HallPediment", Vector3.new(4.2, 3.4, 9), CFrame.new(-4.5, 14.7, 0.4) * CFrame.Angles(0, math.pi / 2, 0), MARBLE, Enum.Material.Marble)
		k:wedge("HallPediment", Vector3.new(4.2, 3.4, 9), CFrame.new(4.5, 14.7, 0.4) * CFrame.Angles(0, -math.pi / 2, 0), MARBLE, Enum.Material.Marble)
		-- On a mount in front of the pediment, not inside it: the brain's fissure is a thin slab on the
		-- centreline, and the two pediment wedges meet on that same plane, so wherever it overlapped them
		-- its sides sat 0.048 from theirs and the map's z-fight pass pulled it about.
		-- 0.9 tall, not 0.7: at 0.7 its underside landed 0.034 from the fissure's, inside the z-fight
		-- pass's tolerance. At 0.9 it clears by 0.066 and its top is still a quarter under the fissure.
		k:box("BrainMount", Vector3.new(0.7, 0.9, 1.1), CFrame.new(0, 14.05, -1.95), MARBLE, Enum.Material.Marble)
		brain(k:at(CFrame.new(0, 14.05, -3.0)), 0.32)
		k:box("HallWall", Vector3.new(18, 9.6, 0.6), CFrame.new(0, 6.6, 2.7), Color3.fromRGB(214, 196, 190), Enum.Material.Plaster)
		k:trim("HallDoor", Vector3.new(3.2, 5.4, 0.15), CFrame.new(0, 4.5, 2.33), Color3.fromRGB(90, 54, 44), Enum.Material.WoodPlanks)
		for _, x in ipairs({ -5.5, 5.5 }) do
			k:trim("HallWindow", Vector3.new(2.2, 3.2, 0.15), CFrame.new(x, 6.2, 2.33), Color3.fromRGB(50, 60, 80), Enum.Material.Glass)
		end
	end

	local function newsKiosk(k)
		k:box("NewsKiosk", Vector3.new(6, 3, 3), CFrame.new(0, 1.3, 0), Color3.fromRGB(40, 110, 80), Enum.Material.Metal)
		for _, x in ipairs({ -2.8, 2.8 }) do
			k:box("NewsPost", Vector3.new(0.3, 3.6, 0.3), CFrame.new(x, 4.6, 1.3), Color3.fromRGB(40, 110, 80), Enum.Material.Metal)
		end
		k:box("NewsCanopy", Vector3.new(7, 0.3, 4.2), CFrame.new(0, 6.55, 0.2), Color3.fromRGB(40, 110, 80), Enum.Material.Metal)
		local sign = k:trim("NewsSign", Vector3.new(6, 1.2, 0.2), CFrame.new(0, 7.3, -1.8), C.white, Enum.Material.SmoothPlastic)
		Kit.label(sign, "BRAINROT DAILY", Color3.fromRGB(160, 40, 60), C.white, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.Garamond)
		for index = 0, 2 do
			k:box("NewspaperStack", Vector3.new(1.4, 0.4 + index * 0.15, 1.0), CFrame.new(-1.8 + index * 1.8, 3.0 + (0.4 + index * 0.15) / 2, -0.8), C.white, Enum.Material.Fabric)
		end
		local headline = k:at(CFrame.new(-4.4, 0, -2.2))
		for _, side in ipairs({ -1, 1 }) do
			local board = headline:box("HeadlineBoard", Vector3.new(side < 0 and 2.4 or 2.2, 3, 0.15), CFrame.new(0, 1.45, side * 0.4) * CFrame.Angles(math.rad(side * 15), 0, 0), C.white, Enum.Material.SmoothPlastic)
			Kit.label(board, "LOCAL MAN SCROLLS FOR 9 HOURS", C.black, nil, { side < 0 and Enum.NormalId.Front or Enum.NormalId.Back }, Enum.Font.Garamond)
		end
	end

	local function brainLamp(k)
		k:post("BrainLampPost", 6.4, 0.4, Vector3.zero, C.charcoal, Enum.Material.Metal)
		local bulb = decor(k:ball("BrainLampBulb", 1.5, CFrame.new(0, 7.1, 0), BRAIN, Enum.Material.Neon))
		for _, x in ipairs({ -0.35, 0.35 }) do
			decor(k:ball("BrainLampLobe", 0.9, CFrame.new(x, 7.65, 0), BRAIN_DARK, Enum.Material.Neon))
		end
		Kit.light(bulb, BRAIN, 14, 1)
	end

	defineTheme({
		name = "Brainrot Borough",
		id = "BrainrotBorough",
		flag = { emblem = "BRAIN", caption = "BRAINROT BOROUGH", color = BRAIN_DARK, text = C.white, trim = MARBLE },
		setPiece = {
			id = "BoroughHall",
			name = "Brainrot Borough Hall",
			width = 36,
			depth = 30,
			ground = Enum.Material.Pavement,
			build = function(k)
				portico(k:at(CFrame.new(0, 0, 11)))
				-- The monument to the borough's greatest resource.
				local monument = k:at(CFrame.new(0, 0, -3))
				monument:box("BrainPlinth", Vector3.new(7, 1.2, 7), CFrame.new(0, 0.4, 0), MARBLE, Enum.Material.Marble)
				monument:post("BrainColumn", 7, 3, Vector3.new(0, 1.0, 0), MARBLE, Enum.Material.Marble)
				monument:box("BrainCapital", Vector3.new(4, 0.6, 4), CFrame.new(0, 8.3, 0), MARBLE, Enum.Material.Marble)
				monument:post("BrainStem", 1.8, 1.2, Vector3.new(0, 8.6, 0), BRAIN_DARK, Enum.Material.SmoothPlastic)
				Kit.light(brain(monument:at(CFrame.new(0, 11.4, 0)), 1), BRAIN, 20, 1.2)
				for index, at in ipairs({ Vector3.new(-4.4, 13.6, -0.5), Vector3.new(4.2, 14.2, 0.8), Vector3.new(-3.2, 12.8, 3.2), Vector3.new(3.4, 13, -3) }) do
					spark(monument, at, index * 1.7)
				end
				local plaque = monument:trim("BrainPlaque", Vector3.new(5, 0.8, 0.12), CFrame.new(0, 0.5, -3.56), C.brass, Enum.Material.Metal)
				Kit.label(plaque, "OUR GREATEST RESOURCE", C.black, nil, { Enum.NormalId.Front }, Enum.Font.Garamond)
				tvPyramid(k:at(CFrame.new(-10.8, 0, -4.5) * CFrame.Angles(0, math.rad(12), 0)))
				newsKiosk(k:at(CFrame.new(11.5, 0, -6)))
				brainLamp(k:at(CFrame.new(-5, 0, -10)))
				brainLamp(k:at(CFrame.new(5, 0, -10)))
				local street = k:at(CFrame.new(-16.5, 0, -12.6))
				street:post("StreetSignPost", 7.3, 0.3, Vector3.zero, C.charcoal, Enum.Material.Metal)
				local blade = street:trim("StreetBlade", Vector3.new(4.4, 0.8, 0.1), CFrame.new(1.9, 6.6, 0), Color3.fromRGB(30, 110, 60), Enum.Material.SmoothPlastic)
				Kit.label(blade, "DOOMSCROLL AVE", C.white, nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBold)
				local cross = street:trim("StreetBlade", Vector3.new(0.1, 0.8, 4.4), CFrame.new(0, 5.8, 1.9), Color3.fromRGB(30, 110, 60), Enum.Material.SmoothPlastic)
				Kit.label(cross, "BRAINROT BLVD", C.white, nil, { Enum.NormalId.Left, Enum.NormalId.Right }, Enum.Font.GothamBold)
			end,
		},
		props = {
			{
				id = "CrtStack",
				radius = 2.4,
				build = function(k)
					crt(k, SCREENS[k.rng:NextInteger(1, #SCREENS)], CRT_BEIGE)
					crt(k:at(CFrame.new(0.2, 2.8, 0.1) * CFrame.Angles(0, 0.15, 0)), SCREENS[k.rng:NextInteger(1, #SCREENS)], CRT_DARK)
				end,
			},
			{
				id = "NewsBox",
				radius = 1.4,
				build = function(k)
					k:box("NewsBox", Vector3.new(1.8, 3.4, 1.6), CFrame.new(0, 1.7, 0), Color3.fromRGB(50, 90, 170), Enum.Material.Metal)
					local window = k:trim("NewsBoxWindow", Vector3.new(1.4, 1.1, 0.1), CFrame.new(0, 2.5, -0.85), Color3.fromRGB(230, 230, 220), Enum.Material.SmoothPlastic)
					Kit.label(window, "BRAINROT\nDAILY", Color3.fromRGB(160, 40, 60), nil, { Enum.NormalId.Front }, Enum.Font.Garamond)
				end,
			},
			{ id = "BrainLamp", radius = 1.2, build = brainLamp },
			{
				id = "DoomscrollSign",
				radius = 2.4,
				build = function(k)
					k:post("StreetSignPost", 7.3, 0.3, Vector3.zero, C.charcoal, Enum.Material.Metal)
					local blade = k:trim("StreetBlade", Vector3.new(4.4, 0.8, 0.1), CFrame.new(0, 6.6, -0.1), Color3.fromRGB(30, 110, 60), Enum.Material.SmoothPlastic)
					Kit.label(blade, "DOOMSCROLL AVE", C.white, nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBold)
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Grass Toucher's Rest: a walled lawn for finally going outside
--------------------------------------------------------------------------------

do
	local HEDGE = Color3.fromRGB(56, 112, 54)
	local LAWN = Color3.fromRGB(96, 170, 70)
	local MARBLE = Color3.fromRGB(236, 232, 224)
	local LOCKER = Color3.fromRGB(58, 96, 80)

	local function tree(k, height)
		k:post("RestTrunk", height + 1, 1.6, Vector3.new(0, -1, 0), Color3.fromRGB(96, 72, 50), Enum.Material.Wood)
		for _, puff in ipairs({ { 0, height + 2, 0, 7 }, { 2.4, height + 0.6, 0.8, 5 }, { -2.2, height + 0.8, -0.6, 5.2 } }) do
			decor(k:ball("RestCanopy", puff[4], CFrame.new(puff[1], puff[2], puff[3]), Color3.fromRGB(72, 130, 60), Enum.Material.Grass))
		end
	end

	local function pedestal(k)
		k:box("GrassPedestalFoot", Vector3.new(4.2, 0.7, 4.2), CFrame.new(0, 0.05, 0), MARBLE:Lerp(C.black, 0.1), Enum.Material.Marble)
		k:box("GrassPedestal", Vector3.new(3, 2.8, 3), CFrame.new(0, 1.8, 0), MARBLE, Enum.Material.Marble)
		k:box("GrassPedestalCap", Vector3.new(3.6, 0.4, 3.6), CFrame.new(0, 3.4, 0), MARBLE:Lerp(C.black, 0.05), Enum.Material.Marble)
		decor(k:disc("GrassSoil", 0.15, 1.3, Vector3.new(0, 3.675, 0), Color3.fromRGB(80, 58, 40), Enum.Material.Ground))
		-- The tuft itself: seven perfect blades.
		for index = 0, 6 do
			local angle = index / 7 * math.pi * 2
			local lean = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 0.35
			decor(k:rod("OriginalBlade", Vector3.new(lean.X * 0.4, 3.7, lean.Z * 0.4), Vector3.new(lean.X, 4.9 + (index % 3) * 0.25, lean.Z), 0.12, Color3.fromRGB(110, 220, 80), Enum.Material.Neon))
		end
		local dome = decor(k:ball("GrassDome", 3.0, CFrame.new(0, 3.6, 0), Color3.fromRGB(220, 240, 250), Enum.Material.Glass))
		dome.Transparency = 0.72
		Kit.light(dome, Color3.fromRGB(230, 255, 210), 10, 0.8)
		Kit.emitter(dome, { color = Color3.fromRGB(230, 255, 200), size = 0.25, size2 = 0.05, transparency = 0.1, lifetime = 1.5, rate = 3, speed = 0.5, spread = 90, lightEmission = 1 })
		-- Velvet ropes round it on four brass posts.
		local corners = { Vector3.new(2.9, 0, 2.9), Vector3.new(-2.9, 0, 2.9), Vector3.new(-2.9, 0, -2.9), Vector3.new(2.9, 0, -2.9) }
		for index, at in ipairs(corners) do
			local nextAt = corners[index % #corners + 1]
			k:post("RopePost", 2.8, 0.3, at, C.brass, Enum.Material.Metal)
			decor(k:ball("RopePostTop", 0.5, CFrame.new(at + Vector3.new(0, 2.9, 0)), C.brass, Enum.Material.Metal))
			decor(k:rod("VelvetRope", at + Vector3.new(0, 2.5, 0), nextAt + Vector3.new(0, 2.5, 0), 0.2, Color3.fromRGB(160, 20, 40), Enum.Material.Fabric))
		end
		local plaque = Pieces.plaque(k:at(CFrame.new(0, 0, -4.6)), "THE ORIGINAL GRASS\nPLEASE TOUCH (GENTLY)", 4.2)
		plaque.Name = "GrassPlaque"
		-- A museum banner behind it, big enough to read from the street.
		local banner = Pieces.board(k:at(CFrame.new(0, 0, 4.4)), "THE ORIGINAL GRASS", 8, 1.8, 5.2, C.gold, Color3.fromRGB(40, 70, 44), 2, C.brass)
		banner.Name = "GrassBanner"
	end

	local function hammock(k)
		tree(k:at(CFrame.new(-4.6, 0, 0)), 10)
		tree(k:at(CFrame.new(4.6, 0, 0.8)), 11)
		local left, right = Vector3.new(-3.6, 4.4, 0.08), Vector3.new(3.6, 4.4, 0.72)
		local middle = Vector3.new(0, 2.7, 0.4)
		for index, pair in ipairs({ { left, middle }, { middle, right } }) do
			local from, to = pair[1], pair[2]
			local mid = from:Lerp(to, 0.5)
			-- The two halves differ in width AND hang a tenth apart in height: same width or same top and
			-- their faces share a plane where they cross.
			k:trim("Hammock", Vector3.new(index == 1 and 2.4 or 2.3, 0.15, (to - from).Magnitude + 0.2),
				CFrame.lookAt(mid + Vector3.new(0, index == 1 and 0 or -0.09, 0), to), Color3.fromRGB(230, 120, 80), Enum.Material.Fabric)
		end
		decor(k:rod("HammockRope", Vector3.new(-3.85, 5.2, 0.05), left, 0.12, C.cream, Enum.Material.Fabric))
		decor(k:rod("HammockRope", Vector3.new(3.85, 5.2, 0.75), right, 0.12, C.cream, Enum.Material.Fabric))
		k:trim("HammockPillow", Vector3.new(1.6, 0.4, 1.0), CFrame.new(-2.4, 3.9, 0.2) * CFrame.Angles(0, 0, 0.35), C.white, Enum.Material.Fabric)
	end

	local function picnic(k)
		local blanket = k:at(CFrame.Angles(0, 0.25, 0))
		for x = 0, 1 do
			for z = 0, 1 do
				blanket:trim("PicnicBlanket", Vector3.new(2.2, 0.12, 2.2), CFrame.new(-1.1 + x * 2.2, 0.1 + (x + z) % 2 * 0.02, -1.1 + z * 2.2), (x + z) % 2 == 0 and Color3.fromRGB(210, 50, 50) or C.white, Enum.Material.Fabric)
			end
		end
		blanket:box("PicnicBasket", Vector3.new(1.6, 1.0, 1.1), CFrame.new(1.2, 0.66, 1.0), Color3.fromRGB(170, 130, 80), Enum.Material.WoodPlanks)
		decor(blanket:rod("BasketHandle", Vector3.new(0.6, 1.16, 1.0), Vector3.new(1.2, 1.9, 1.0), 0.12, Color3.fromRGB(150, 110, 60), Enum.Material.Wood))
		decor(blanket:rod("BasketHandle", Vector3.new(1.2, 1.9, 1.0), Vector3.new(1.8, 1.16, 1.0), 0.12, Color3.fromRGB(150, 110, 60), Enum.Material.Wood))
		blanket:trim("Sandwich", Vector3.new(1.0, 0.35, 1.0), CFrame.new(-0.9, 0.35, -0.6) * CFrame.Angles(0, 0.6, 0), Color3.fromRGB(230, 200, 140), Enum.Material.SmoothPlastic)
		decor(blanket:ball("PicnicApple", 0.6, CFrame.new(-0.2, 0.46, 0.3), C.red, Enum.Material.SmoothPlastic))
		decor(blanket:post("Thermos", 1.0, 0.45, Vector3.new(-1.5, 0.16, 0.6), C.blue, Enum.Material.Metal))
	end

	local function lounger(k, color)
		k:box("LoungerSeat", Vector3.new(1.9, 0.25, 3.0), CFrame.new(0, 1.1, 0.6), color, Enum.Material.Fabric)
		-- Narrower than the seat (1.7 against 1.9) and lifted so their faces never meet in one plane
		-- where the back leans onto it.
		k:trim("LoungerBack", Vector3.new(1.7, 0.25, 2.2), CFrame.new(0, 1.97, -1.62) * CFrame.Angles(math.rad(40), 0, 0), color, Enum.Material.Fabric)
		for _, x in ipairs({ -0.8, 0.8 }) do
			k:box("LoungerLeg", Vector3.new(0.2, 0.975, 2.6), CFrame.new(x, 0.4875, 0.6), C.silver, Enum.Material.Metal)
		end
	end

	local function phoneLocker(k, columns, rows)
		local width, height = columns * 1.7 + 0.4, rows * 1.6 + 0.6
		k:box("PhoneLocker", Vector3.new(width, height, 2), CFrame.new(0, height / 2 - 0.2, 0), LOCKER, Enum.Material.Metal)
		for column = 1, columns do
			for row = 1, rows do
				local x = -width / 2 + 0.2 + (column - 0.5) * 1.7
				local y = 0.1 + (row - 0.5) * 1.6
				k:trim("LockerDoor", Vector3.new(1.5, 1.4, 0.1), CFrame.new(x, y, -1.05), LOCKER:Lerp(C.white, 0.12), Enum.Material.Metal)
			end
		end
		local sign = k:trim("LockerSign", Vector3.new(width, 1.1, 0.15), CFrame.new(0, height - 0.2 + 0.55, -0.6), C.white, Enum.Material.SmoothPlastic)
		Kit.label(sign, "PHONES HERE. GO OUTSIDE.", LOCKER, nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBlack)
	end

	local function gnome(k)
		k:post("GnomeBody", 1.3, 1.0, Vector3.zero, Color3.fromRGB(60, 110, 180), Enum.Material.SmoothPlastic)
		decor(k:ball("GnomeBeard", 0.9, CFrame.new(0, 1.35, -0.3), C.white, Enum.Material.SmoothPlastic))
		decor(k:ball("GnomeFace", 0.7, CFrame.new(0, 1.6, -0.15), Color3.fromRGB(240, 200, 170), Enum.Material.SmoothPlastic))
		decor(k:post("GnomeHat", 0.5, 0.8, Vector3.new(0, 1.85, 0), C.red, Enum.Material.SmoothPlastic))
		decor(k:post("GnomeHatTip", 0.5, 0.4, Vector3.new(0, 2.35, 0), C.red, Enum.Material.SmoothPlastic))
		local tag = k:trim("GnomeSign", Vector3.new(1.3, 0.6, 0.08), CFrame.new(0.7, 1.0, -0.55) * CFrame.Angles(0, -0.3, 0), Color3.fromRGB(240, 230, 200), Enum.Material.WoodPlanks)
		Kit.label(tag, "touch it.", C.black, nil, { Enum.NormalId.Front }, Enum.Font.PermanentMarker)
	end

	defineTheme({
		name = "Grass Toucher's Rest",
		id = "GrassTouchersRest",
		flag = { emblem = "GO\nOUTSIDE", caption = "GRASS TOUCHER'S REST", color = LAWN, text = C.white, trim = HEDGE },
		setPiece = {
			id = "TouchingLawn",
			name = "The Touching Lawn",
			width = 38,
			depth = 30,
			ground = Enum.Material.LeafyGrass,
			build = function(k)
				k:box("BorderHedge", Vector3.new(36, 2.2, 1.2), CFrame.new(0, 0.9, 14.2), HEDGE, Enum.Material.LeafyGrass)
				for _, x in ipairs({ -18.4, 18.4 }) do
					k:box("BorderHedge", Vector3.new(1.2, 2.2, 27), CFrame.new(x, 0.9, 0), HEDGE, Enum.Material.LeafyGrass)
				end
				for _, x in ipairs({ -12.4, 12.4 }) do
					k:box("BorderHedge", Vector3.new(13, 2.2, 1.2), CFrame.new(x, 0.9, -14.2), HEDGE, Enum.Material.LeafyGrass)
				end
				pedestal(k:at(CFrame.new(0, 0, 2)))
				gnome(k:at(CFrame.new(3.8, 0, -3.4) * CFrame.Angles(0, 0.4, 0)))
				hammock(k:at(CFrame.new(-10, 0, 10)))
				picnic(k:at(CFrame.new(-10, 0, -6.5)))
				lounger(k:at(CFrame.new(8.2, 0, -7.5)), Color3.fromRGB(80, 170, 230))
				lounger(k:at(CFrame.new(12.4, 0, -7.5)), Color3.fromRGB(250, 200, 70))
				local parasol = k:at(CFrame.new(10.3, 0, -4.8))
				parasol:post("ParasolPole", 6.2, 0.25, Vector3.zero, C.white, Enum.Material.Metal)
				decor(parasol:disc("ParasolCanopy", 0.35, 5.2, Vector3.new(0, 6.1, 0), Color3.fromRGB(250, 120, 110), Enum.Material.Fabric))
				decor(parasol:disc("ParasolCanopyTop", 0.3, 2.6, Vector3.new(0, 6.4, 0), C.white, Enum.Material.Fabric))
				phoneLocker(k:at(CFrame.new(12, 0, 11.2)), 4, 3)
				-- A fingerpost at the gap in the hedge.
				local post = k:at(CFrame.new(-5.2, 0, -12.2))
				post:post("RestFingerpost", 6.6, 0.4, Vector3.zero, Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
				-- A board points the way its arrow does: the viewer's right is the kit's -X.
				for index, text in ipairs({ "TOUCH GRASS  →", "SUNLIGHT  ↑", "WIFI: NONE" }) do
					local board = post:trim("RestBoard", Vector3.new(4.2, 0.8, 0.2), CFrame.new(1.9 * (index == 2 and 1 or -1), 6.0 - index * 1.0, -0.3 - index * 0.08),
						Color3.fromRGB(196, 168, 118), Enum.Material.WoodPlanks)
					Kit.label(board, text, Color3.fromRGB(40, 30, 20), nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBold)
				end
			end,
		},
		props = {
			{
				id = "TouchGrassSign",
				radius = 3.3,
				build = function(k)
					k:post("TouchPost", 4.4, 0.35, Vector3.zero, Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
					local board = k:trim("TouchBoard", Vector3.new(4, 0.9, 0.2), CFrame.new(-1.2, 3.8, -0.3), Color3.fromRGB(196, 168, 118), Enum.Material.WoodPlanks)
					Kit.label(board, "TOUCH GRASS  →", Color3.fromRGB(40, 30, 20), nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBold)
				end,
			},
			{
				id = "LawnPatch",
				radius = 2.7,
				build = function(k)
					k:box("LawnPatch", Vector3.new(4.2, 0.6, 3.2), CFrame.new(0, 0.2, 0), Color3.fromRGB(96, 180, 70), Enum.Material.LeafyGrass)
					local sign = k:at(CFrame.new(1.4, 0.5, -0.8))
					sign:post("LawnSignStick", 1.4, 0.12, Vector3.zero, C.white, Enum.Material.Wood)
					local card = sign:trim("LawnSign", Vector3.new(1.6, 0.8, 0.08), CFrame.new(0, 1.6, 0), C.white, Enum.Material.SmoothPlastic)
					Kit.label(card, "YOU MAY TOUCH THIS", Color3.fromRGB(40, 110, 50), nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBold)
				end,
			},
			{
				id = "PicnicTable",
				radius = 3.5,
				build = function(k)
					k:box("PicnicTop", Vector3.new(5, 0.35, 2.4), CFrame.new(0, 2.6, 0), C.wood, Enum.Material.WoodPlanks)
					for _, x in ipairs({ -1.9, 1.9 }) do
						k:box("PicnicLeg", Vector3.new(0.3, 2.425, 2.0), CFrame.new(x, 1.2125, 0), C.darkWood, Enum.Material.Wood)
					end
					for _, z in ipairs({ -1.9, 1.9 }) do
						k:box("PicnicBench", Vector3.new(5, 0.3, 0.9), CFrame.new(0, 1.5, z), C.wood, Enum.Material.WoodPlanks)
						for _, x in ipairs({ -1.9, 1.9 }) do
							k:box("PicnicBenchLeg", Vector3.new(0.3, 1.35, 0.3), CFrame.new(x, 0.675, z), C.darkWood, Enum.Material.Wood)
						end
					end
				end,
			},
			{
				id = "PhoneLocker",
				radius = 2.2,
				build = function(k)
					phoneLocker(k, 2, 2)
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Lil Tralala: a very small town that sings
--------------------------------------------------------------------------------

do
	local WHITE_WOOD = Color3.fromRGB(244, 240, 230)
	local ROOF_RED = Color3.fromRGB(190, 64, 60)
	local NOTE_GOLD = Color3.fromRGB(255, 206, 80)
	local TINY_WALLS = { Color3.fromRGB(240, 220, 180), Color3.fromRGB(200, 220, 240), Color3.fromRGB(240, 200, 210), Color3.fromRGB(210, 240, 200) }

	-- A music note, all of its parts bobbing as one. Seen from the front the stem rises on the head's
	-- right, which is the kit's -X, and the flag trails off to the right of that.
	local function note(k, at, size, phase, color)
		local parts = {
			k:ball("NoteHead", size, CFrame.new(at), color, Enum.Material.Neon),
			k:box("NoteStem", Vector3.new(size * 0.2, size * 2.2, size * 0.2), CFrame.new(at + Vector3.new(-size * 0.42, size * 1.1, 0)), color, Enum.Material.Neon),
			k:box("NoteFlag", Vector3.new(size * 0.75, size * 0.2, size * 0.2 + 0.12), CFrame.new(at + Vector3.new(-size * 0.75, size * 1.95, 0)) * CFrame.Angles(0, 0, math.rad(30)), color, Enum.Material.Neon),
		}
		for _, part in ipairs(parts) do
			floating(decor(part))
			Kit.bob(part, size * 0.5, 1.4, phase)
		end
	end

	-- A little house: walls, a pitched roof of two wedges meeting at the ridge, a door.
	local function tinyHouse(k, s, wall)
		k:box("TinyHouse", Vector3.new(1.4, 1.2, 1.2) * s, CFrame.new(0, 0.6 * s, 0), wall, Enum.Material.SmoothPlastic)
		k:wedge("TinyRoof", Vector3.new(1.5, 0.6, 0.65) * s, CFrame.new(0, 1.5 * s, -0.325 * s), ROOF_RED, Enum.Material.SmoothPlastic)
		k:wedge("TinyRoof", Vector3.new(1.5, 0.6, 0.65) * s, CFrame.new(0, 1.5 * s, 0.325 * s) * CFrame.Angles(0, math.pi, 0), ROOF_RED, Enum.Material.SmoothPlastic)
		-- A step up off the ground, so the door's foot isn't the house's.
		k:trim("TinyDoor", Vector3.new(0.3, 0.5, 0.1) * s, CFrame.new(0, 0.25 * s + 0.06, -0.625 * s), Color3.fromRGB(120, 80, 50), Enum.Material.SmoothPlastic)
	end

	local function bird(k, at, color, phase)
		local parts = {
			k:ball("BirdBody", 0.7, CFrame.new(at), color, Enum.Material.SmoothPlastic),
			k:ball("BirdHead", 0.45, CFrame.new(at + Vector3.new(0, 0.35, -0.3)), color, Enum.Material.SmoothPlastic),
			k:box("BirdBeak", Vector3.new(0.12, 0.12, 0.3), CFrame.new(at + Vector3.new(0, 0.33, -0.6)), NOTE_GOLD, Enum.Material.SmoothPlastic),
			k:box("BirdTail", Vector3.new(0.3, 0.1, 0.5), CFrame.new(at + Vector3.new(0, 0.1, 0.45)) * CFrame.Angles(math.rad(25), 0, 0), color:Lerp(C.black, 0.2), Enum.Material.SmoothPlastic),
		}
		for _, part in ipairs(parts) do
			floating(decor(part))
			Kit.bob(part, 0.12, 4.5, phase)
		end
	end

	local function bandstand(k)
		k:post("BandstandDeck", 1.6, 13, Vector3.new(0, -0.2, 0), WHITE_WOOD, Enum.Material.WoodPlanks)
		for index = 0, 7 do
			local angle = (index + 0.5) / 8 * math.pi * 2
			k:post("BandstandPost", 7, 0.45, Vector3.new(math.cos(angle) * 5.9, 1.4, math.sin(angle) * 5.9), WHITE_WOOD, Enum.Material.Wood)
			-- Railing between posts, except across the front where the steps come up.
			local nextAngle = (index + 1.5) / 8 * math.pi * 2
			local mid = (angle + nextAngle) / 2
			local facingStreet = math.abs(math.sin(mid) + 1) < 0.2
			if not facingStreet then
				decor(k:rod("BandstandRail", Vector3.new(math.cos(angle) * 5.9, 2.6, math.sin(angle) * 5.9), Vector3.new(math.cos(nextAngle) * 5.9, 2.6, math.sin(nextAngle) * 5.9), 0.2, WHITE_WOOD, Enum.Material.Wood))
			end
		end
		k:disc("BandstandRoof", 0.5, 14, Vector3.new(0, 8.65, 0), ROOF_RED, Enum.Material.SmoothPlastic)
		k:disc("BandstandRoof", 1.0, 10, Vector3.new(0, 9.4, 0), ROOF_RED:Lerp(C.white, 0.1), Enum.Material.SmoothPlastic)
		k:disc("BandstandRoof", 1.0, 6, Vector3.new(0, 10.4, 0), ROOF_RED, Enum.Material.SmoothPlastic)
		k:disc("BandstandRoof", 1.0, 2.6, Vector3.new(0, 11.4, 0), ROOF_RED:Lerp(C.white, 0.1), Enum.Material.SmoothPlastic)
		k:ball("BandstandFinial", 1.0, CFrame.new(0, 12.3, 0), C.gold, Enum.Material.Foil)
		for index, step in ipairs({ { 0.5, -7.1 }, { 0.95, -6.5 } }) do
			k:box("BandstandStep", Vector3.new(index == 1 and 3.4 or 3.2, step[1] + 0.2 + (index - 1) * 0.06, 1.0), CFrame.new(0, (step[1] - 0.2 - (index - 1) * 0.06) / 2, step[2] + (index - 1) * 0.05), WHITE_WOOD, Enum.Material.WoodPlanks)
		end
		for index, x in ipairs({ -2.4, 0, 2.4 }) do
			decor(k:post("MusicStand", 2.4, 0.15, Vector3.new(x, 1.4, 2 - math.abs(x) * 0.3), C.black, Enum.Material.Metal))
			k:trim("MusicSheet", Vector3.new(1.2, 0.9, 0.08), CFrame.new(x, 4.0, 2 - math.abs(x) * 0.3 - 0.1) * CFrame.Angles(math.rad(-20), 0, 0), C.white, Enum.Material.SmoothPlastic)
		end
		for index, spot in ipairs({ Vector3.new(-2.5, 14.5, 0), Vector3.new(1.5, 16, 1), Vector3.new(4.2, 13.8, -1.5), Vector3.new(-5.5, 11.5, -2), Vector3.new(6.8, 11, 1.5) }) do
			note(k, spot, 1.0, index * 1.1, NOTE_GOLD)
		end
	end

	local function modelVillage(k)
		k:box("VillageTable", Vector3.new(14, 1.2, 10), CFrame.new(0, 0.4, 0), Color3.fromRGB(110, 170, 80), Enum.Material.Grass)
		k:box("VillageEdge", Vector3.new(14.6, 1.0, 10.6), CFrame.new(0, 0.2, 0), Color3.fromRGB(150, 140, 120), Enum.Material.Cobblestone)
		k:trim("VillageRoad", Vector3.new(12, 0.08, 1), CFrame.new(0, 1.04, 0), Color3.fromRGB(70, 70, 74), Enum.Material.Asphalt)
		local houses = { { -4.8, -2.4, 0 }, { -2.2, -2.6, 0.2 }, { 2.4, -2.3, -0.1 }, { 5, -2.5, 0.1 }, { -3.6, 2.6, math.pi }, { 1.2, 2.5, math.pi } }
		for index, house in ipairs(houses) do
			tinyHouse(k:at(CFrame.new(house[1], 1.0, house[2]) * CFrame.Angles(0, house[3], 0)), 1, TINY_WALLS[(index - 1) % #TINY_WALLS + 1])
		end
		-- The church, with its spire.
		local church = k:at(CFrame.new(4.6, 1.0, 2.6))
		church:box("TinyChurch", Vector3.new(1.6, 1.6, 2.4), CFrame.new(0, 0.8, 0), C.white, Enum.Material.SmoothPlastic)
		church:box("TinyTower", Vector3.new(0.8, 2.6, 0.8), CFrame.new(0, 1.3, -1.6), C.white, Enum.Material.SmoothPlastic)
		church:post("TinySpire", 1.0, 0.3, Vector3.new(0, 2.6, -1.6), ROOF_RED, Enum.Material.SmoothPlastic)
		for _, spot in ipairs({ { -6.2, 3.8 }, { -1.2, 3.6 }, { 6.2, -3.8 }, { -0.2, -4.0 }, { 3.2, 4.0 } }) do
			decor(k:post("TinyTrunk", 0.5, 0.15, Vector3.new(spot[1], 1.0, spot[2]), Color3.fromRGB(96, 70, 48), Enum.Material.Wood))
			decor(k:ball("TinyTree", 0.8, CFrame.new(spot[1], 1.8, spot[2]), Color3.fromRGB(60, 120, 60), Enum.Material.Grass))
		end
		-- And on the model village, a model of the model village.
		k:box("TinierTable", Vector3.new(1.4, 0.2, 1.0), CFrame.new(-6, 1.16, -0.1), Color3.fromRGB(110, 170, 80), Enum.Material.Grass)
		for _, x in ipairs({ -6.35, -5.75 }) do
			k:trim("TiniestHouse", Vector3.new(0.3, 0.3, 0.3), CFrame.new(x, 1.35, -0.1), C.white, Enum.Material.SmoothPlastic)
		end
		local sign = Pieces.board(k:at(CFrame.new(0, 0, -6.4)), "LIL TRALALA MODEL VILLAGE\nSCALE 1:1 (APPROX.)", 8, 1.6, 1.4, C.black, C.cream, 2, C.darkWood)
		sign.Name = "VillageSign"
	end

	local function tinyLamp(k)
		k:post("TinyLampPost", 2.4, 0.25, Vector3.zero, C.charcoal, Enum.Material.Metal)
		local head = decor(k:ball("TinyLamp", 0.7, CFrame.new(0, 2.6, 0), Color3.fromRGB(255, 220, 150), Enum.Material.Neon))
		k:trim("TinyLampCap", Vector3.new(0.8, 0.2, 0.8), CFrame.new(0, 3.0, 0), C.charcoal, Enum.Material.Metal)
		Kit.light(head, Color3.fromRGB(255, 220, 150), 10, 0.8)
	end

	defineTheme({
		name = "Lil Tralala",
		id = "LilTralala",
		flag = { emblem = "♪", caption = "LIL TRALALA", color = Color3.fromRGB(80, 120, 200), text = NOTE_GOLD, trim = WHITE_WOOD },
		setPiece = {
			id = "VillageGreen",
			name = "The Village Green",
			width = 34,
			depth = 30,
			ground = Enum.Material.Grass,
			build = function(k)
				bandstand(k:at(CFrame.new(-8, 0, 6)))
				modelVillage(k:at(CFrame.new(8.5, 0, -5.5)))
				-- The songbirds' wire.
				for _, x in ipairs({ 4.5, 14.5 }) do
					k:post("WirePole", 7.4, 0.45, Vector3.new(x, -0.2, 11.5), Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
				end
				decor(k:rod("SongWire", Vector3.new(4.5, 6.6, 11.5), Vector3.new(14.5, 6.6, 11.5), 0.08, C.black, Enum.Material.Metal))
				local colors = { Color3.fromRGB(240, 90, 90), Color3.fromRGB(90, 160, 240), NOTE_GOLD, Color3.fromRGB(120, 210, 120), Color3.fromRGB(240, 150, 220) }
				for index = 1, 5 do
					bird(k, Vector3.new(4.5 + index * 1.7, 7.0, 11.5), colors[index], index * 0.9)
				end
				note(k, Vector3.new(8, 9.4, 11.3), 0.6, 0.4, colors[2])
				note(k, Vector3.new(12.5, 10, 11.7), 0.5, 2.2, colors[1])
				for _, spot in ipairs({ { -3.5, -12.5 }, { 3.5, -12.5 }, { -15, -3 }, { 0.5, 2 } }) do
					tinyLamp(k:at(CFrame.new(spot[1], 0, spot[2])))
				end
				-- A stump with a door in it, for someone even smaller.
				local stump = k:at(CFrame.new(-13.5, 0, -10))
				stump:post("DoorStump", 2.7, 3, Vector3.new(0, -0.2, 0), Color3.fromRGB(110, 80, 56), Enum.Material.Wood)
				stump:trim("StumpDoor", Vector3.new(0.6, 1.0, 0.1), CFrame.new(0, 0.5, -1.52), Color3.fromRGB(200, 60, 50), Enum.Material.SmoothPlastic)
				stump:trim("StumpWindow", Vector3.new(0.4, 0.4, 0.1), CFrame.new(0.7, 1.6, -1.4) * CFrame.Angles(0, -0.45, 0), Color3.fromRGB(255, 220, 150), Enum.Material.Neon)
				decor(stump:ball("StumpDoorknob", 0.12, CFrame.new(0.18, 0.5, -1.6), C.gold, Enum.Material.Metal))
			end,
		},
		props = {
			{ id = "TinyLamp", radius = 0.8, build = tinyLamp },
			{
				id = "SongbirdPost",
				radius = 1.4,
				build = function(k)
					k:post("BirdPost", 4.2, 0.35, Vector3.zero, Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
					k:trim("BirdPerch", Vector3.new(1.6, 0.15, 0.15), CFrame.new(0, 4.3, 0), Color3.fromRGB(110, 80, 52), Enum.Material.Wood)
					bird(k, Vector3.new(0.4, 4.75, 0), Color3.fromRGB(240, 90, 90), k.rng:NextNumber(0, 6))
					note(k, Vector3.new(-0.6, 6.2, 0), 0.5, k.rng:NextNumber(0, 6), NOTE_GOLD)
				end,
			},
			{
				id = "Dollhouse",
				radius = 1.9,
				build = function(k)
					k:post("DollhouseStump", 1.4, 2.6, Vector3.new(0, -0.2, 0), Color3.fromRGB(110, 80, 56), Enum.Material.Wood)
					tinyHouse(k:at(CFrame.new(0, 1.2, 0)), 1.4, TINY_WALLS[k.rng:NextInteger(1, #TINY_WALLS)])
				end,
			},
			{
				id = "NoteSculpture",
				radius = 1.4,
				build = function(k)
					k:box("NotePlinth", Vector3.new(2.2, 1.0, 2.2), CFrame.new(0, 0.3, 0), WHITE_WOOD, Enum.Material.Marble)
					k:ball("NoteSculptureHead", 1.6, CFrame.new(0.3, 1.5, 0), C.black, Enum.Material.SmoothPlastic)
					k:box("NoteSculptureStem", Vector3.new(0.3, 3.6, 0.3), CFrame.new(-0.35, 3.1, 0), C.black, Enum.Material.SmoothPlastic)
					k:box("NoteSculptureFlag", Vector3.new(1.3, 0.35, 0.42), CFrame.new(-0.9, 4.6, 0) * CFrame.Angles(0, 0, math.rad(30)), C.black, Enum.Material.SmoothPlastic)
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Crumbly Creek: the old mill, falling apart one crumb at a time
--------------------------------------------------------------------------------

do
	local OLD_STONE = Color3.fromRGB(140, 132, 118)
	local DARK_STONE = Color3.fromRGB(104, 98, 90)
	local WATER = Color3.fromRGB(70, 150, 200)
	local COOKIE = Color3.fromRGB(206, 150, 88)
	local CHOC = Color3.fromRGB(70, 44, 30)
	local TIMBER = Color3.fromRGB(110, 80, 52)

	local function rubble(k, count, spread)
		for index = 1, count do
			local size = k.rng:NextNumber(0.9, 1.9)
			-- Every chunk lies at its own angle: the tilts step by index rather than being rolled, so no
			-- two chunks can come to rest with parallel faces, whatever their sizes. (Varying only the
			-- heights wasn't enough; the map's z-fight pass still found a pair 0.078 apart.)
			local tip = 0.14 + index * 0.07
			k:box("Rubble", Vector3.new(size * 1.3, size * (0.72 + (index % 3) * 0.07), size),
				CFrame.new(k.rng:NextNumber(-spread, spread), size * 0.25 + index * 0.05, k.rng:NextNumber(-spread, spread))
					* CFrame.Angles(tip * (index % 2 == 0 and 1 or -1), k.rng:NextNumber(0, 3), tip * 0.6 * (index % 3 == 0 and -1 or 1)),
				index % 2 == 0 and OLD_STONE or DARK_STONE, Enum.Material.Cobblestone)
		end
	end

	-- The mill race: a stone channel along X with water in it, its walls crumbled to uneven heights
	-- and broken through in one place.
	local function millRace(k, length)
		k:box("RaceBed", Vector3.new(length, 0.3, 5), CFrame.new(0, 0.15, 0), DARK_STONE, Enum.Material.Slate)
		local water = decor(k:box("RaceWater", Vector3.new(length, 0.4, 4.6), CFrame.new(0, 0.75, 0), WATER, Enum.Material.Glass))
		water.Transparency = 0.35
		for _, side in ipairs({ -1, 1 }) do
			local segments = 9
			local span = length / segments
			for index = 0, segments - 1 do
				if not (side < 0 and index == 5) then
					local height = 1.0 + ((index * 7 + (side > 0 and 3 or 0)) % 5) * 0.2
					k:box("RaceWall", Vector3.new(span, height + 0.2, 1), CFrame.new(-length / 2 + (index + 0.5) * span, (height - 0.2) / 2, side * 3), OLD_STONE, Enum.Material.Cobblestone)
				end
			end
		end
		rubble(k:at(CFrame.new(-length / 2 + 5.5 * length / 9, 0, -3.8)), 4, 1.4)
	end

	-- The wheel turns in the race on an axle into the mill wall: a hub whose Y axis runs along the
	-- axle, spokes and paddles round it.
	local function waterWheel(k, diameter)
		local hub = k:hub("WheelHub", CFrame.Angles(math.pi / 2, 0, 0))
		local wheel = k:into(hub)
		for index = 0, 3 do
			wheel:trim("WheelSpoke", Vector3.new(0.45, diameter - 0.6, 0.45), CFrame.new(0, 0, -0.18 + index * 0.12) * CFrame.Angles(0, 0, index * math.pi / 4), TIMBER, Enum.Material.Wood)
		end
		for index = 0, 11 do
			wheel:trim("WheelPaddle", Vector3.new(0.3, 1.8, 1.9), CFrame.Angles(0, 0, index * math.pi / 6) * CFrame.new(0, diameter / 2 - 0.9, 0), TIMBER:Lerp(C.black, 0.15), Enum.Material.WoodPlanks)
		end
		for _, z in ipairs({ -0.95, 0.95 }) do
			decor(wheel:cyl("WheelBoss", 0.3, 1.8, CFrame.new(0, 0, z) * CFrame.Angles(0, math.pi / 2, 0), C.iron, Enum.Material.Metal))
		end
		Kit.spin(hub, -28)
		local splash = decor(k:box("WheelSplash", Vector3.new(1, 0.2, 1), CFrame.new(0, -diameter / 2 + 0.7, 0), C.white, Enum.Material.SmoothPlastic))
		splash.Transparency = 1
		Kit.emitter(splash, { color = Color3.fromRGB(220, 240, 255), size = 0.5, size2 = 0.1, transparency = 0.3, lifetime = 0.8, rate = 12, speed = 4, spread = 45,
			acceleration = Vector3.new(0, -20, 0) })
	end

	local function mill(k)
		k:box("MillBackWall", Vector3.new(12, 10, 1), CFrame.new(0, 4.8, 3.5), OLD_STONE, Enum.Material.Cobblestone)
		k:box("MillSideWall", Vector3.new(1, 10, 6), CFrame.new(-5.5, 4.8, 0), OLD_STONE, Enum.Material.Cobblestone)
		k:box("MillSideWall", Vector3.new(1, 4, 6), CFrame.new(5.5, 1.8, 0), OLD_STONE, Enum.Material.Cobblestone)
		k:box("MillWallRemains", Vector3.new(1, 3, 2.6), CFrame.new(5.5, 5.3, 1.7), DARK_STONE, Enum.Material.Cobblestone)
		k:box("MillFrontWall", Vector3.new(5, 7, 1), CFrame.new(-3.5, 3.3, -3.5), OLD_STONE, Enum.Material.Cobblestone)
		k:box("MillFrontWall", Vector3.new(3, 5, 1), CFrame.new(3.5, 2.3, -3.5), DARK_STONE, Enum.Material.Cobblestone)
		-- What's left of the roof: one slope and the gable under it, the ridge, two rafters hanging.
		k:box("MillRoofSlope", Vector3.new(6.9, 0.5, 8.4), CFrame.new(-3, 11.4, 0) * CFrame.Angles(0, 0, math.rad(28)), Color3.fromRGB(90, 70, 60), Enum.Material.Slate)
		k:wedge("MillGable", Vector3.new(1, 3.2, 6), CFrame.new(-3, 11.4, 3.5) * CFrame.Angles(0, math.pi / 2, 0), OLD_STONE, Enum.Material.Cobblestone)
		decor(k:rod("MillRidge", Vector3.new(0, 13, -3.8), Vector3.new(0, 13, 4), 0.5, TIMBER, Enum.Material.Wood))
		for _, z in ipairs({ -1.8, 1.6 }) do
			decor(k:rod("BrokenRafter", Vector3.new(0, 12.9, z), Vector3.new(4.6, 7.4, z + 0.4), 0.4, TIMBER, Enum.Material.Wood))
		end
		rubble(k:at(CFrame.new(3, 0, -1)), 5, 1.6)
		for index, height in ipairs({ 1.1, 0.95, 1.25 }) do
			k:box("FlourSack", Vector3.new(1.6, height, 1.2), CFrame.new(-3.6 + (index - 1) * 1.7, height / 2 - 0.09 * index, 1.7) * CFrame.Angles(0, index * 0.3, 0),
				Color3.fromRGB(230, 220, 196), Enum.Material.Fabric)
		end
		decor(k:disc("SpiltFlour", 0.1, 3, Vector3.new(0.2, 0.05, -1.6), C.white, Enum.Material.Sand))
		local sign = k:trim("MillSign", Vector3.new(4.4, 1.2, 0.2), CFrame.new(-3.5, 5.6, -4.1) * CFrame.Angles(0, 0, math.rad(-6)), Color3.fromRGB(196, 168, 118), Enum.Material.WoodPlanks)
		Kit.label(sign, "CRUMBLY CREEK MILL", Color3.fromRGB(60, 40, 20), nil, { Enum.NormalId.Front }, Enum.Font.Fantasy)
	end

	-- The millstone that was actually a cookie, broken, and the bit that came off.
	local function cookie(k, diameter)
		local face = k:at(CFrame.new(0, diameter / 2 - 0.4, 0) * CFrame.Angles(math.rad(-14), 0, 0))
		face:cyl("CookieStone", 1.4, diameter, CFrame.Angles(0, math.pi / 2, 0), COOKIE, Enum.Material.Sand)
		for index = 0, 7 do
			local angle = index * 2.4
			local reach = (0.25 + (index % 4) * 0.18) * diameter / 2
			decor(face:ball("ChocolateChip", 0.55 + (index % 3) * 0.12, CFrame.new(math.cos(angle) * reach, math.sin(angle) * reach, -0.62), CHOC, Enum.Material.SmoothPlastic))
		end
		k:box("CookieChunk", Vector3.new(diameter * 0.35, 1.2, diameter * 0.3), CFrame.new(diameter * 0.55, 0.45, -diameter * 0.2) * CFrame.Angles(0.2, 0.7, 0.1), COOKIE, Enum.Material.Sand)
		for index = 1, 10 do
			decor(k:ball("Crumb", k.rng:NextNumber(0.25, 0.5), CFrame.new(k.rng:NextNumber(-diameter * 0.6, diameter * 0.7), 0.12, k.rng:NextNumber(-diameter * 0.5, -0.8)), COOKIE, Enum.Material.Sand))
		end
	end

	local function brokenBridge(k)
		for _, z in ipairs({ -3, 3 }) do
			k:box("BridgePier", Vector3.new(4, 2.7, 1.2), CFrame.new(0, 1.05, z), OLD_STONE, Enum.Material.Cobblestone)
		end
		k:box("BridgeDeckStone", Vector3.new(4, 0.6, 3.7), CFrame.new(0, 2.7, -3.15), OLD_STONE, Enum.Material.Cobblestone)
		k:box("BridgeDeckStone", Vector3.new(4, 0.6, 3.5), CFrame.new(0, 2.7, 3.25), OLD_STONE, Enum.Material.Cobblestone)
		-- The middle fell in.
		k:box("FallenDeck", Vector3.new(3.6, 0.6, 1.8), CFrame.new(0.3, 1.1, 0) * CFrame.Angles(0.5, 0.2, 0.3), DARK_STONE, Enum.Material.Cobblestone)
		for _, z in ipairs({ -1, 1 }) do
			k:wedge("BridgeRamp", Vector3.new(4, 3.0, 3.2), CFrame.new(0, 1.3, z * 6.6) * CFrame.Angles(0, z > 0 and math.pi or 0, 0), OLD_STONE, Enum.Material.Cobblestone)
		end
		k:box("BridgeParapet", Vector3.new(0.6, 1.2, 2.2), CFrame.new(-1.7, 3.6, -4.2), DARK_STONE, Enum.Material.Cobblestone)
		k:box("BridgeParapet", Vector3.new(0.6, 0.8, 1.6), CFrame.new(1.7, 3.4, 4.3) * CFrame.Angles(0, 0, 0.1), DARK_STONE, Enum.Material.Cobblestone)
	end

	local function cautionTape(k, width)
		for _, x in ipairs({ -width / 2, width / 2 }) do
			k:box("TapePost", Vector3.new(0.5, 3.4, 0.5), CFrame.new(x, 1.5, 0), C.orange, Enum.Material.SmoothPlastic)
		end
		for index, y in ipairs({ 1.4, 2.7 }) do
			local tape = k:trim("CautionTape", Vector3.new(width - 0.5, 0.6, 0.08), CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(index == 1 and 2 or -3)), Color3.fromRGB(255, 226, 40), Enum.Material.SmoothPlastic)
			Kit.label(tape, "CAUTION: CRUMBLING", C.black, Color3.fromRGB(255, 226, 40), { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBlack)
		end
	end

	local function crumblingPillar(k)
		k:post("PillarBase", 1.0, 2.4, Vector3.new(0, -0.2, 0), DARK_STONE, Enum.Material.Cobblestone)
		k:post("CrackedPillar", 5, 1.8, Vector3.new(0, 0.8, 0), OLD_STONE, Enum.Material.Cobblestone)
		k:post("PillarTop", 1.6, 1.8, Vector3.new(0, 0, 0), OLD_STONE, Enum.Material.Cobblestone).CFrame = k.frame * CFrame.new(0.25, 6.55, 0) * CFrame.Angles(0.15, 0, math.pi / 2 + 0.18)
		k:box("PillarChunk", Vector3.new(1.2, 0.9, 1.4), CFrame.new(1.4, 0.4, -0.8) * CFrame.Angles(0.3, 0.8, 0.2), OLD_STONE, Enum.Material.Cobblestone)
	end

	defineTheme({
		name = "Crumbly Creek",
		id = "CrumblyCreek",
		flag = { emblem = "CRUMB", caption = "CRUMBLY CREEK", color = Color3.fromRGB(150, 104, 60), text = C.cream, trim = COOKIE },
		setPiece = {
			id = "CrumblingMill",
			name = "The Crumbling Mill",
			width = 40,
			depth = 32,
			ground = Enum.Material.Ground,
			build = function(k)
				millRace(k:at(CFrame.new(0, 0, 4)), 40)
				mill(k:at(CFrame.new(-8, 0, 11.5)))
				waterWheel(k:at(CFrame.new(-5, 6.2, 4)), 11)
				decor(k:rod("WheelAxle", Vector3.new(-5, 6.2, 1.0), Vector3.new(-5, 6.2, 8.2), 0.6, C.iron, Enum.Material.Metal))
				k:box("AxleBearing", Vector3.new(1, 5.2, 1), CFrame.new(-5, 3.8, 1.0), TIMBER, Enum.Material.Wood)
				brokenBridge(k:at(CFrame.new(10, 0, 4)))
				cookie(k:at(CFrame.new(-11, 0, -8.5)), 7)
				local crumbs = Pieces.board(k:at(CFrame.new(-4, 0, -12.8)), "MIND THE CRUMBS", 5.4, 1.4, 2.4, Color3.fromRGB(60, 40, 20), Color3.fromRGB(236, 206, 150), 2, TIMBER)
				crumbs.Name = "CrumbsSign"
				cautionTape(k:at(CFrame.new(14, 0, -9.5)), 6)
				crumblingPillar(k:at(CFrame.new(17.5, 0, -3)))
				rubble(k:at(CFrame.new(3.5, 0, -6)), 3, 1.6)
			end,
		},
		props = {
			{
				id = "RubblePile",
				radius = 2.6,
				build = function(k)
					rubble(k, 5, 1.2)
				end,
			},
			{
				id = "CautionTape",
				radius = 2.9,
				build = function(k)
					cautionTape(k, 5)
				end,
			},
			{ id = "CrumblingPillar", radius = 2.5, build = crumblingPillar },
			{
				id = "CookieChunk",
				radius = 3.0,
				build = function(k)
					cookie(k, 3.6)
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Rizz Ridge: the high ground, a red carpet and a meter that only reads one way
--------------------------------------------------------------------------------

do
	local STONE = Color3.fromRGB(196, 170, 140)
	local STONE_DARK = Color3.fromRGB(158, 132, 108)
	local CARPET = Color3.fromRGB(180, 24, 40)
	local ROSE = Color3.fromRGB(220, 30, 60)
	local LEAF = Color3.fromRGB(60, 120, 60)
	local SPOT = Color3.fromRGB(255, 240, 210)

	local function rosePlanter(k, width)
		k:box("RosePlanter", Vector3.new(width, 1.4, 2), CFrame.new(0, 0.5, 0), STONE_DARK, Enum.Material.Limestone)
		for index = 0, math.floor(width / 0.9) - 1 do
			local x = -width / 2 + 0.55 + index * 0.9
			decor(k:ball("RoseLeaves", 0.9, CFrame.new(x, 1.45, (index % 2) * 0.4 - 0.2), LEAF, Enum.Material.Grass))
			decor(k:ball("Rose", 0.55, CFrame.new(x + 0.1, 1.95, (index % 2) * 0.4 - 0.3), ROSE, Enum.Material.SmoothPlastic))
		end
	end

	local function brassRope(k, from, to)
		for _, at in ipairs({ from, to }) do
			-- Posts don't collide: ropes are for show, not for walling bots out of a path.
			decor(k:post("CarpetPost", 2.8, 0.3, at, C.gold, Enum.Material.Foil))
			decor(k:ball("CarpetPostTop", 0.5, CFrame.new(at + Vector3.new(0, 2.9, 0)), C.gold, Enum.Material.Foil))
		end
		decor(k:rod("CarpetRope", from + Vector3.new(0, 2.4, 0), to + Vector3.new(0, 2.4, 0), 0.22, CARPET, Enum.Material.Fabric))
	end

	-- A spotlight on a pole, aimed at `target` (local), with a faint beam drawn to it.
	local function spotlight(k, height, target)
		k:post("SpotPole", height, 0.5, Vector3.zero, C.charcoal, Enum.Material.Metal)
		local head = Vector3.new(0, height + 0.6, 0)
		local lamp = k:box("SpotLamp", Vector3.new(1.4, 1.4, 2.2), CFrame.lookAt(head, target), C.black, Enum.Material.Metal)
		local light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Front
		light.Angle = 40
		light.Range = 40
		light.Brightness = 3
		light.Color = SPOT
		light.Parent = lamp
		k:trim("SpotLens", Vector3.new(1.1, 1.1, 0.1), CFrame.lookAt(head, target) * CFrame.new(0, 0, -1.15), SPOT, Enum.Material.Neon)
		local beam = decor(k:rod("SpotBeam", head + (target - head).Unit * 1.3, target, 2.2, SPOT, Enum.Material.Neon))
		beam.Transparency = 0.92
		beam.CastShadow = false
	end

	local function rizzMeter(k)
		k:box("MeterBoard", Vector3.new(7, 4.4, 0.3), CFrame.identity, Color3.fromRGB(30, 26, 34), Enum.Material.SmoothPlastic)
		local colors = { Color3.fromRGB(90, 200, 90), Color3.fromRGB(180, 220, 70), Color3.fromRGB(250, 210, 60), Color3.fromRGB(250, 140, 50), Color3.fromRGB(240, 50, 60) }
		-- Layers off the board: labels to -0.25, bands alternately to -0.35 and -0.43, the needle to
		-- -0.57, so neighbouring bands that overlap never share a face.
		for index, color in ipairs(colors) do
			-- Five bands round a half circle, left (none) to right (max).
			local angle = math.rad(180 - (index - 0.5) * 36)
			k:trim("MeterBand", Vector3.new(1.6, 0.5, 0.1), CFrame.new(-math.cos(angle) * 2.2, -1.2 + math.sin(angle) * 2.2, index % 2 == 0 and -0.3 or -0.38)
				* CFrame.Angles(0, 0, -(angle - math.pi / 2)), color, Enum.Material.Neon)
		end
		-- Pinned at the red end, which is the viewer's right: the kit's -X, so a positive turn.
		k:trim("MeterNeedle", Vector3.new(0.2, 2.3, 0.1), CFrame.new(0, -1.2, -0.52) * CFrame.Angles(0, 0, math.rad(72)) * CFrame.new(0, 1.05, 0), C.white, Enum.Material.Neon)
		decor(k:ball("MeterPivot", 0.5, CFrame.new(0, -1.2, -0.52), C.white, Enum.Material.Metal))
		local title = k:trim("MeterTitle", Vector3.new(6.4, 0.9, 0.1), CFrame.new(0, 1.6, -0.2), Color3.fromRGB(30, 26, 34), Enum.Material.SmoothPlastic)
		Kit.label(title, "RIZZ-O-METER", C.white, nil, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
		local reading = k:trim("MeterReading", Vector3.new(2.2, 0.6, 0.1), CFrame.new(-2.2, -1.75, -0.2), Color3.fromRGB(30, 26, 34), Enum.Material.SmoothPlastic)
		Kit.label(reading, "UNSPOKEN", Color3.fromRGB(240, 50, 60), nil, { Enum.NormalId.Front }, Enum.Font.GothamBlack)
	end

	defineTheme({
		name = "Rizz Ridge",
		id = "RizzRidge",
		flag = { emblem = "W", caption = "RIZZ RIDGE", color = CARPET, text = C.white, trim = C.gold, font = Enum.Font.GothamBlack },
		setPiece = {
			id = "TheRidge",
			name = "The Ridge",
			width = 36,
			depth = 30,
			ground = Enum.Material.Limestone,
			build = function(k)
				-- The terrace: one solid block of stone six studs high, stairs up the front of it.
				k:box("RidgeTerrace", Vector3.new(26, 6.4, 9), CFrame.new(0, 2.8, 9.5), STONE, Enum.Material.Limestone)
				-- Nine studs wide, a stud up every 1.2: a bot's path agent is six across, and at six wide
				-- the stairs only worked when nothing else crowded the foot of them.
				for step = 1, 6 do
					local front = -2.2 + (step - 1) * 1.2
					k:box("RidgeStep", Vector3.new(9, step + 0.4, 1.2), CFrame.new(0, (step - 0.4) / 2, front + 0.6), STONE_DARK, Enum.Material.Limestone)
				end
				-- A rim round the top, open where the stairs arrive.
				for _, spec in ipairs({ { -8.75, 5.4, 8.1, 0.6 }, { 8.75, 5.4, 8.1, 0.6 } }) do
					k:trim("RidgeRim", Vector3.new(spec[3], 0.4, spec[4]), CFrame.new(spec[1], 6.1, spec[2]), STONE_DARK, Enum.Material.Limestone)
				end
				-- Parapets down the sides and along the back: cover, up on the high ground.
				for _, x in ipairs({ -12.7, 12.7 }) do
					k:box("RidgeParapet", Vector3.new(0.6, 1.3, 9), CFrame.new(x, 6.65, 9.5), STONE_DARK, Enum.Material.Limestone)
				end
				k:box("RidgeParapet", Vector3.new(24.8, 1.3, 0.6), CFrame.new(0, 6.65, 13.7), STONE_DARK, Enum.Material.Limestone)
				-- The rose arch at the top.
				local arch = k:at(CFrame.new(0, 6, 11.4))
				for _, x in ipairs({ -2.2, 2.2 }) do
					arch:box("ArchPost", Vector3.new(0.4, 5, 0.4), CFrame.new(x, 2.5, 0), C.white, Enum.Material.Metal)
				end
				for index = 0, 4 do
					local angle = math.rad(index * 45)
					arch:trim("ArchCurve", Vector3.new(1.8, 0.28, 0.28), CFrame.new(math.cos(angle) * 2.2, 5 + math.sin(angle) * 2.2, (index % 2) * 0.08) * CFrame.Angles(0, 0, angle + math.pi / 2), C.white, Enum.Material.Metal)
				end
				for index = 0, 13 do
					local t = index / 13
					local at
					if t < 0.3 then
						at = Vector3.new(-2.2, 1.2 + t / 0.3 * 3.8, 0)
					elseif t > 0.7 then
						at = Vector3.new(2.2, 5 - (t - 0.7) / 0.3 * 3.8, 0)
					else
						local angle = math.pi - (t - 0.3) / 0.4 * math.pi
						at = Vector3.new(math.cos(angle) * 2.2, 5 + math.sin(angle) * 2.2, 0)
					end
					decor(arch:ball(index % 3 == 0 and "RoseLeaves" or "Rose", index % 3 == 0 and 0.8 or 0.6, CFrame.new(at + Vector3.new(0, 0, -0.35)), index % 3 == 0 and LEAF or ROSE, Enum.Material.SmoothPlastic))
				end
				-- The microphone.
				local mic = k:at(CFrame.new(0, 6, 8.2))
				decor(mic:disc("MicBase", 0.2, 1.4, Vector3.new(0, 0.1, 0), C.black, Enum.Material.Metal))
				decor(mic:post("MicStand", 4.1, 0.15, Vector3.new(0, 0.1, 0), C.silver, Enum.Material.Metal))
				-- String lights along the terrace's front edge, drooping between posts.
				for index = 0, 11 do
					local x = -12 + index * (24 / 11)
					if math.abs(x) > 5.2 then
						local bulb = decor(k:ball("StringLight", 0.45, CFrame.new(x, 7.9 - math.abs(math.sin(index * 1.3)) * 0.35, 5.4), index % 2 == 0 and C.gold or ROSE, Enum.Material.Neon))
						bulb.CastShadow = false
					end
				end
				for _, x in ipairs({ -12.0, -4.9, 4.9, 12.0 }) do
					k:post("LightPost", 2.6, 0.2, Vector3.new(x, 5.8, 5.4), C.charcoal, Enum.Material.Metal)
				end
				for _, span in ipairs({ { -12.0, -4.9 }, { 4.9, 12.0 } }) do
					decor(k:rod("LightWire", Vector3.new(span[1], 8.2, 5.4), Vector3.new(span[2], 8.2, 5.4), 0.06, C.black, Enum.Material.SmoothPlastic))
				end
				decor(mic:ball("Microphone", 0.6, CFrame.new(0, 4.4, -0.2), C.charcoal, Enum.Material.Metal))
				-- Spotlights at the front corners, both on the arch.
				spotlight(k:at(CFrame.new(-16, 0, -12)), 11, Vector3.new(16, 8, 23.4))
				spotlight(k:at(CFrame.new(16, 0, -12)), 11, Vector3.new(-16, 8, 23.4))
				-- The meter and the sign on the terrace face.
				rizzMeter(k:at(CFrame.new(-8.9, 3, 4.8)))
				local wSign = k:box("RizzSign", Vector3.new(6, 2.6, 0.3), CFrame.new(9, 3.4, 4.85), Color3.fromRGB(30, 26, 34), Enum.Material.SmoothPlastic)
				Kit.label(wSign, "W RIZZ ONLY", ROSE, Color3.fromRGB(30, 26, 34), { Enum.NormalId.Front }, Enum.Font.GothamBlack)
				Kit.light(wSign, ROSE, 12, 1)
				-- The red carpet up to the stairs, roped both sides, and roses at the foot of it.
				k:trim("RedCarpet", Vector3.new(4.4, 0.12, 12.2), CFrame.new(0, 0.08, -8.3), CARPET, Enum.Material.Fabric)
				for _, x in ipairs({ -3.8, 3.8 }) do
					brassRope(k, Vector3.new(x, 0, -13.4), Vector3.new(x, 0, -9))
					brassRope(k, Vector3.new(x, 0, -7), Vector3.new(x, 0, -2.8))
				end
				rosePlanter(k:at(CFrame.new(-6.5, 0, -12.6)), 5)
				rosePlanter(k:at(CFrame.new(6.5, 0, -12.6)), 5)
			end,
		},
		props = {
			{
				id = "RosePlanter",
				radius = 2.4,
				build = function(k)
					rosePlanter(k, 4)
				end,
			},
			{
				id = "CarpetRunner",
				radius = 3.2,
				build = function(k)
					k:trim("RedCarpet", Vector3.new(2.4, 0.12, 5.6), CFrame.new(0, 0.08, 0), CARPET, Enum.Material.Fabric)
					brassRope(k, Vector3.new(-1.8, 0, -2.4), Vector3.new(-1.8, 0, 2.4))
				end,
			},
			{
				id = "Spotlight",
				radius = 1.6,
				build = function(k)
					spotlight(k, 4.5, Vector3.new(0, 14, -6))
				end,
			},
			{
				id = "RizzMeterSign",
				radius = 3.6,
				build = function(k)
					for _, x in ipairs({ -3.2, 3.2 }) do
						k:box("MeterLeg", Vector3.new(0.4, 4.6, 0.4), CFrame.new(x, 2.1, 0.4), C.charcoal, Enum.Material.Metal)
					end
					rizzMeter(k:at(CFrame.new(0, 4.4, 0)))
				end,
			},
		},
	})
end

--------------------------------------------------------------------------------
-- Noob Hollow: the tutorial yard nobody asked to do again
--------------------------------------------------------------------------------

do
	local TUTORIAL_BLUE = Color3.fromRGB(60, 140, 230)
	local HINT_YELLOW = Color3.fromRGB(255, 220, 60)
	local PAD_COLORS = { Color3.fromRGB(90, 200, 110), Color3.fromRGB(250, 200, 60), Color3.fromRGB(240, 100, 80) }
	local TIPS = { "TIP: DON'T DIE", "HOLD W TO WALK", "PRESS SPACE TO JUMP", "TIP: LOOT IS GOOD", "YOU ARE DOING GREAT", "TIP: THE STORM IS BAD" }

	-- A giant arrow floating over something, pointing down at it, bobbing.
	local function arrow(k, at, size, phase)
		local shaft = floating(k:trim("TutorialArrow", Vector3.new(size * 0.8, size * 2.4, size * 0.8), CFrame.new(at + Vector3.new(0, size * 1.6, 0)), HINT_YELLOW, Enum.Material.Neon))
		local head = floating(k:trim("TutorialArrow", Vector3.new(size * 2, size * 2, size * 0.5), CFrame.new(at) * CFrame.Angles(0, 0, math.pi / 4), HINT_YELLOW, Enum.Material.Neon))
		for _, part in ipairs({ shaft, head }) do
			Kit.bob(part, size * 0.5, 2.2, phase)
		end
		Kit.light(head, HINT_YELLOW, 12, 0.8)
	end

	local function hintBoard(k, text, width)
		local board = Pieces.board(k, text, width or 4, 1.4, 2.6, C.white, TUTORIAL_BLUE, 1, C.iron)
		board.Name = "HintBoard"
		return board
	end

	local function numberPad(k, height, number)
		-- Turned a quarter about the vertical before it's stood up, so the number on its top reads from
		-- the street (the label audit found all three reading sideways: a tipped-up cylinder's face
		-- label points its "up" along the cylinder's +Y, which lands on -X).
		local tall = height + 0.2
		local pad = k:cyl("JumpPad", tall, 3, CFrame.new(0, tall / 2 - 0.2, 0) * CFrame.Angles(0, math.pi / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
			PAD_COLORS[number], Enum.Material.SmoothPlastic)
		Kit.label(pad, tostring(number), C.white, nil, { Enum.NormalId.Right }, Enum.Font.GothamBlack)
		return pad
	end

	local function trainingBike(k)
		local turned = CFrame.Angles(0, math.pi / 2, 0)
		for _, z in ipairs({ -1.3, 1.3 }) do
			decor(k:cyl("BikeWheel", 0.25, 1.8, CFrame.new(0, 0.9, z) * turned, C.black, Enum.Material.Rubber))
		end
		for _, x in ipairs({ -0.7, 0.7 }) do
			decor(k:cyl("TrainingWheel", 0.2, 0.7, CFrame.new(x, 0.35, 1.5) * turned, C.white, Enum.Material.Rubber))
			decor(k:rod("TrainingStrut", Vector3.new(x, 0.35, 1.5), Vector3.new(0, 1.0, 1.3), 0.12, C.silver, Enum.Material.Metal))
		end
		decor(k:rod("BikeFrame", Vector3.new(0, 0.9, -1.3), Vector3.new(0, 1.6, 0.2), 0.2, TUTORIAL_BLUE, Enum.Material.Metal))
		decor(k:rod("BikeFrame", Vector3.new(0, 1.6, 0.2), Vector3.new(0, 0.9, 1.3), 0.2, TUTORIAL_BLUE, Enum.Material.Metal))
		decor(k:rod("BikeFork", Vector3.new(0, 0.9, -1.3), Vector3.new(0, 2.1, -1.0), 0.18, C.silver, Enum.Material.Metal))
		k:trim("BikeHandlebar", Vector3.new(1.4, 0.15, 0.15), CFrame.new(0, 2.15, -1.0), C.black, Enum.Material.Rubber)
		k:trim("BikeSeat", Vector3.new(0.5, 0.2, 0.9), CFrame.new(0, 1.8, 0.5), C.black, Enum.Material.Leather)
	end

	-- Giant keycaps laid out as they are on a keyboard, for someone standing at the street: A on
	-- their left (+X), D on their right, W beyond S.
	local function wasdKeys(k)
		for _, key in ipairs({ { "W", 0, 1.05 }, { "A", 2.1, -1.05 }, { "S", 0, -1.05 }, { "D", -2.1, -1.05 } }) do
			k:box("KeyBase", Vector3.new(2.0, 0.9, 2.0), CFrame.new(key[2], 0.25, key[3]), Color3.fromRGB(90, 94, 104), Enum.Material.SmoothPlastic)
			local cap = k:box("KeyCap", Vector3.new(1.6, 0.4, 1.6), CFrame.new(key[2], 0.9, key[3]) * READ_FROM_FRONT, Color3.fromRGB(236, 238, 242), Enum.Material.SmoothPlastic)
			Kit.label(cap, key[1], C.black, nil, { Enum.NormalId.Top }, Enum.Font.GothamBlack)
		end
	end

	defineTheme({
		name = "Noob Hollow",
		id = "NoobHollow",
		flag = { emblem = "LVL 1", caption = "NOOB HOLLOW", color = TUTORIAL_BLUE, text = HINT_YELLOW, trim = C.white },
		setPiece = {
			id = "TutorialYard",
			name = "The Tutorial Yard",
			width = 40,
			depth = 30,
			ground = Enum.Material.Ground,
			build = function(k)
				-- The welcome arch at the entrance.
				for _, x in ipairs({ -6, 6 }) do
					k:box("WelcomePost", Vector3.new(0.8, 9.2, 0.8), CFrame.new(x, 4.4, -12.5), C.white, Enum.Material.SmoothPlastic)
				end
				-- In front of its posts, so they don't cover the first and last letters.
				local banner = k:box("WelcomeBanner", Vector3.new(13, 2.2, 0.3), CFrame.new(0, 8.1, -13.05), TUTORIAL_BLUE, Enum.Material.SmoothPlastic)
				Kit.label(banner, "WELCOME, NEW PLAYER!", HINT_YELLOW, TUTORIAL_BLUE, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBlack)

				-- Station one: jump the hurdle.
				local hurdle = k:at(CFrame.new(-14, 0, -4))
				for _, x in ipairs({ -1.9, 1.9 }) do
					hurdle:box("HurdlePost", Vector3.new(0.3, 2.2, 0.3), CFrame.new(x, 0.9, 0), C.white, Enum.Material.SmoothPlastic)
				end
				-- Sat proud of the posts' tops rather than level with them.
				hurdle:box("HurdleBar", Vector3.new(3.9, 0.3, 0.18), CFrame.new(0, 2.05, 0), C.red, Enum.Material.SmoothPlastic)
				hintBoard(k:at(CFrame.new(-14, 0, -8.5)), "PRESS SPACE TO JUMP", 4.6)
				arrow(k, Vector3.new(-14, 5, -4), 1, 0)

				-- Station two: three numbered pads, each a jump higher than the last.
				local pads = { { -8.5, 1.2, 1 }, { -4.6, 4.4, 2 }, { -0.8, 7.8, 3 } }
				for index, pad in ipairs(pads) do
					numberPad(k:at(CFrame.new(pad[1], 0, pad[2])), 0.8 + (index - 1) * 1.0, pad[3])
				end
				arrow(k, Vector3.new(-8.5, 5.5, 1.2), 1, 1.2)

				-- Station three: the balance beam, off the top pad.
				local beam = k:at(CFrame.new(5.6, 0, 9.4))
				beam:box("BalanceBeam", Vector3.new(11.2, 0.8, 1.0), CFrame.new(0, 3.0, 0), Color3.fromRGB(200, 160, 110), Enum.Material.WoodPlanks)
				for _, x in ipairs({ -4.6, 0, 4.6 }) do
					beam:box("BeamLeg", Vector3.new(0.6, 2.8, 0.6), CFrame.new(x, 1.2, 0), C.iron, Enum.Material.Metal)
				end
				hintBoard(k:at(CFrame.new(5.6, 0, 13.2)), "DON'T LOOK DOWN", 4.4)

				-- The checkpoint at the end.
				local checkpoint = k:at(CFrame.new(15, 0, 9.4))
				checkpoint:post("CheckpointPad", 0.5, 4.2, Vector3.new(0, -0.2, 0), Color3.fromRGB(90, 220, 255), Enum.Material.Neon).Transparency = 0.2
				checkpoint:post("CheckpointPole", 7.5, 0.3, Vector3.new(1.6, 0.3, 1.2), C.white, Enum.Material.Metal)
				checkpoint:trim("CheckpointFlag", Vector3.new(2.4, 1.5, 0.1), CFrame.new(0.35, 6.9, 1.2), HINT_YELLOW, Enum.Material.Fabric)
				hintBoard(checkpoint:at(CFrame.new(0, 0, -4)), "CHECKPOINT!", 3.6)
				arrow(k, Vector3.new(15, 6, 9.4), 1.2, 2.4)

				-- The map everyone ignores.
				local map = k:at(CFrame.new(-15, 0, 10))
				for _, x in ipairs({ -2.2, 2.2 }) do
					map:box("MapLeg", Vector3.new(0.3, 4.4, 0.3), CFrame.new(x, 2, 0.3), C.iron, Enum.Material.Metal)
				end
				local board = map:box("MapBoard", Vector3.new(5, 3.4, 0.2), CFrame.new(0, 4.6, 0), Color3.fromRGB(236, 230, 210), Enum.Material.SmoothPlastic)
				Kit.label(board, "NOOB HOLLOW\n\nYOU ARE HERE ★", C.black, nil, { Enum.NormalId.Front }, Enum.Font.GothamBold)
				decor(map:ball("YouAreHere", 0.4, CFrame.new(1.35, 3.95, -0.15), C.red, Enum.Material.Neon))

				-- The starter hut and its starter kit.
				local hut = k:at(CFrame.new(12, 0, -6))
				hut:box("HutBack", Vector3.new(6.6, 5.4, 0.5), CFrame.new(0, 2.4, 2.75), Color3.fromRGB(170, 130, 90), Enum.Material.WoodPlanks)
				for _, x in ipairs({ -3.25, 3.25 }) do
					hut:box("HutSide", Vector3.new(0.5, 5.4, 5), CFrame.new(x, 2.5, 0.25), Color3.fromRGB(160, 120, 84), Enum.Material.WoodPlanks)
				end
				hut:box("HutTop", Vector3.new(7.8, 0.4, 6.4), CFrame.new(0, 5.4, 0.2), TUTORIAL_BLUE, Enum.Material.SmoothPlastic)
				local hutSign = hut:trim("HutSign", Vector3.new(5, 1, 0.2), CFrame.new(0, 6.1, -2.6), C.white, Enum.Material.SmoothPlastic)
				Kit.label(hutSign, "STARTER HUT", TUTORIAL_BLUE, nil, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBlack)
				local kit = hut:box("StarterKitBox", Vector3.new(2.6, 1.8, 1.8), CFrame.new(0, 0.9, 1.2), Color3.fromRGB(200, 170, 110), Enum.Material.WoodPlanks)
				Kit.label(kit, "FREE STARTER KIT\n(EMPTY)", C.black, nil, { Enum.NormalId.Front }, Enum.Font.GothamBold)

				trainingBike(k:at(CFrame.new(3.5, 0, -8.5) * CFrame.Angles(0, 0.9, 0)))
				hintBoard(k:at(CFrame.new(-6, 0, -10.2)), "HOLD W TO WALK", 4)
				wasdKeys(k:at(CFrame.new(-15.8, 0, -11.8)))
				-- A tip hanging in the air, the way tips do.
				local tip = floating(k:trim("FloatingTip", Vector3.new(5, 1.6, 0.2), CFrame.new(1, 10, 1), C.white, Enum.Material.SmoothPlastic))
				Kit.label(tip, "TIP: DON'T DIE", TUTORIAL_BLUE, C.white, { Enum.NormalId.Front, Enum.NormalId.Back }, Enum.Font.GothamBlack)
				Kit.bob(tip, 0.5, 1.2, 0)
			end,
		},
		props = {
			{
				id = "HintSign",
				radius = 2.4,
				build = function(k)
					hintBoard(k, TIPS[k.rng:NextInteger(1, #TIPS)], 4.2)
				end,
			},
			{
				id = "ArrowAtBench",
				radius = 2.8,
				build = function(k)
					Pieces.bench(k, Color3.fromRGB(200, 160, 110))
					arrow(k, Vector3.new(0, 6.5, 0), 0.8, k.rng:NextNumber(0, 6))
					local sign = k:trim("BenchLabel", Vector3.new(2.6, 0.7, 0.1), CFrame.new(0, 2.9, -0.92), C.white, Enum.Material.SmoothPlastic)
					Kit.label(sign, "THIS IS A BENCH", TUTORIAL_BLUE, nil, { Enum.NormalId.Front }, Enum.Font.GothamBold)
				end,
			},
			{ id = "TrainingBike", radius = 2.3, build = trainingBike },
			{ id = "WasdKeys", radius = 3.8, build = wasdKeys },
		},
	})
end

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

local Themes = TownThemes.Themes

-- A line under the town's name, set on the town as its TownTagline attribute for anything that
-- shows the name (the HUD's entering banner, the minimap).
TownThemes.Taglines = {
	["Six Seven Square"] = "The clocks stopped at 6:07.",
	["Speedrun Springs"] = "Any% starts here.",
	["Sahur Junction"] = "Next train: 3:30 AM.",
	["Rotville"] = "Smell you later.",
	["Bonkington"] = "Helmets strongly advised.",
	["Aura Farms"] = "Aura, grown fresh daily.",
	["Sigma Station"] = "Always on time. Always.",
	["NPC Nook"] = "Population: background.",
	["Delulu Downs"] = "You've already won.",
	["Lag Lagoon"] = "Reconnecting...",
	["Oof Oasis"] = "Mind your step.",
	["Mewing Meadows"] = "Hold the pose.",
	["Brainrot Borough"] = "Our greatest resource.",
	["Grass Toucher's Rest"] = "Phones in the locker, please.",
	["Lil Tralala"] = "Very small. Very musical.",
	["Crumbly Creek"] = "Mind the crumbs.",
	["Rizz Ridge"] = "W rizz only.",
	["Noob Hollow"] = "Welcome, new player!",
}

-- The yaw that turns a frame's -Z (a piece's front) to face along `direction`.
local function yawFacing(direction)
	return math.atan2(-direction.X, -direction.Z)
end

-- A point in a turned rectangle's own coordinates, in the world (as CFrame.Angles(0, yaw, 0)).
local function toWorld(center, yaw, localX, localZ)
	local c, s = math.cos(yaw), math.sin(yaw)
	return center.X + localX * c + localZ * s, center.Z - localX * s + localZ * c
end

local function flatDistance(a, b)
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Whether a turned rectangle is clear in `space`. A big circle in the middle first (most sites
-- fail there, and fast), then a grid of small circles over the whole thing. The cells are three
-- studs, so the circles reach at most about two studs past the rectangle's edge: tight enough
-- that a site can sit just behind a pavement without the check tripping over the street's claim.
local function rectFree(space, center, yaw, halfX, halfZ)
	if not space:IsFree(center.X, center.Z, math.min(halfX, halfZ) * 0.9) then
		return false
	end
	local columns = math.max(1, math.ceil(halfX * 2 / 3))
	local rows = math.max(1, math.ceil(halfZ * 2 / 3))
	local cellX, cellZ = halfX * 2 / columns, halfZ * 2 / rows
	local radius = math.sqrt(cellX * cellX + cellZ * cellZ) / 2
	for column = 1, columns do
		for row = 1, rows do
			local x, z = toWorld(center, yaw, -halfX + (column - 0.5) * cellX, -halfZ + (row - 0.5) * cellZ)
			if not space:IsFree(x, z, radius) then
				return false
			end
		end
	end
	return true
end

-- The way in: a set piece opens onto its street (or the square), and nothing solid of the town's --
-- a lamp post, a bench, a bin -- may stand square in front of it between its front edge and the kerb
-- (tools/foundation_check.py found a street lot whose entrance a bench blocked two studs out). The
-- town's street furniture is read from the town itself, as the streets are.
local ENTRANCE_HALF = 3

local function furnitureOf(town)
	local pieces = {}
	for _, child in ipairs(town:GetChildren()) do
		if child:IsA("BasePart") and child.CanCollide and child.Size.Y > 1.5 then
			table.insert(pieces, child)
		end
	end
	return pieces
end

local function entranceClear(ctx, at, front, halfDepth, reach)
	local side = Vector3.new(-front.Z, 0, front.X)
	local door = at + front * halfDepth
	for _, piece in ipairs(ctx.furniture or {}) do
		local offset = Vector3.new(piece.Position.X - door.X, 0, piece.Position.Z - door.Z)
		local grow = math.max(piece.Size.X, piece.Size.Z) / 2
		local along = offset:Dot(front)
		if along >= -grow and along <= reach + grow and math.abs(offset:Dot(side)) <= ENTRANCE_HALF + grow then
			return false
		end
	end
	return true
end

local SAMPLES = {
	{ 0, 0 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 0.5, 0.5 }, { -0.5, 0.5 }, { 0.5, -0.5 }, { -0.5, -0.5 },
}

-- Solid ground to build on. MapGenerator.GroundHeightAt returns the solid height and, where water
-- covers that point, the water's surface (claude-79's contract, 2026-09-17); a miss returns nil.
-- Nothing themed goes in water or over a hole, so both are nil here: no ground, no site.
local function solidGround(groundAt, x, z)
	local height, water = groundAt(x, z)
	if height == nil or water ~= nil then
		return nil
	end
	return height
end

-- The lowest and highest ground over a turned rectangle, or nil where there's no ground to find.
local function groundRange(groundAt, center, yaw, halfX, halfZ)
	local low, high = math.huge, -math.huge
	for _, sample in ipairs(SAMPLES) do
		local x, z = toWorld(center, yaw, sample[1] * halfX, sample[2] * halfZ)
		local height = solidGround(groundAt, x, z)
		if not height then
			return nil
		end
		low, high = math.min(low, height), math.max(high, height)
	end
	return low, high
end

-- The same over a grid a terrain voxel apart, edges included: slower, so only for a site that the
-- quick 13-point look already thinks is flat. A bump between the quick samples would otherwise leave
-- a corner hanging or a wall sunk.
local GRID_STEP = 4

local function groundRangeFine(groundAt, center, yaw, halfX, halfZ)
	local low, high = math.huge, -math.huge
	local nx, nz = math.max(1, math.ceil(halfX * 2 / GRID_STEP)), math.max(1, math.ceil(halfZ * 2 / GRID_STEP))
	for i = 0, nx do
		for j = 0, nz do
			local x, z = toWorld(center, yaw, -halfX + halfX * 2 * i / nx, -halfZ + halfZ * 2 * j / nz)
			local height = solidGround(groundAt, x, z)
			if not height then
				return nil
			end
			low, high = math.min(low, height), math.max(high, height)
		end
	end
	return low, high
end

-- A town's streets, read back from the asphalt it laid: one Asphalt part per street, as long as
-- the street was drawn, with its local -Z running from the street's start to its end.
local function streetsOf(town)
	local streets = {}
	for _, child in ipairs(town:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "Asphalt" and child.Size.Z >= 30 then
			local look = child.CFrame.LookVector
			local direction = Vector3.new(look.X, 0, look.Z)
			if direction.Magnitude > 0.5 then
				direction = direction.Unit
				local mid = Vector3.new(child.Position.X, 0, child.Position.Z)
				local length = child.Size.Z
				table.insert(streets, {
					a = mid - direction * (length / 2),
					dir = direction,
					length = length,
					width = child.Size.X,
				})
			end
		end
	end
	return streets
end

-- The terrain under a site is repainted in the set piece's own ground (cobbles, sand, lawn),
-- the same way towns repaint under their streets: the top four studs of the solid ground, whose
-- top sits the surface lift under the surface, so the ground stays exactly where it was. Only on
-- ground at the town's own level, which is dead flat; anywhere else a repaint could shift it.
local PAINT_CENTRE = -2 - MapTerrain.SurfaceLift

-- Terrain materials whose surface lands exactly where it's filled, to ±0.006 (claude-79's full table,
-- 2026-09-17). The rest move it: Rock, Basalt, Ice, Slate and CrackedLava are rough; Pavement snaps to
-- whole studs, Concrete to even ones, Cobblestone to a finer grid, and Brick and WoodPlanks drop to
-- the voxel boundary below; and all of those disturb the smooth ground beside them for 2-4 studs.
-- So a set piece that wants one of them is painted in a smooth stand-in, and one with no stand-in
-- isn't painted at all.
local SMOOTH_GROUND = {
	[Enum.Material.Asphalt] = true,
	[Enum.Material.Glacier] = true,
	[Enum.Material.Grass] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.LeafyGrass] = true,
	[Enum.Material.Limestone] = true,
	[Enum.Material.Mud] = true,
	[Enum.Material.Salt] = true,
	[Enum.Material.Sand] = true,
	[Enum.Material.Sandstone] = true,
	[Enum.Material.Snow] = true,
}
local GROUND_STAND_IN = {
	[Enum.Material.Pavement] = Enum.Material.Asphalt,
	[Enum.Material.Concrete] = Enum.Material.Asphalt,
	-- Pale stone paving for a town square, where cobbles would step.
	[Enum.Material.Cobblestone] = Enum.Material.Limestone,
	-- A fairground's trodden earth.
	[Enum.Material.WoodPlanks] = Enum.Material.Ground,
	[Enum.Material.Brick] = Enum.Material.Sandstone,
}

local function smoothGround(material)
	if material and SMOOTH_GROUND[material] then
		return material
	end
	return material and GROUND_STAND_IN[material] or nil
end
TownThemes.SmoothGround = smoothGround

local function paintSite(at, yaw, sizeX, sizeZ, material)
	workspace.Terrain:FillBlock(CFrame.new(at.X, PAINT_CENTRE, at.Z) * CFrame.Angles(0, yaw, 0), Vector3.new(sizeX, 4, sizeZ), material)
end

-- Oliver's rule (2026-09-17): a structure stands on a flat floor, never with a corner hanging over a
-- slope or its base swallowed by one. So a set piece either finds ground that's already flat to
-- FLAT_ENOUGH under its whole footprint, or asks the terrain for a pad (MapTerrain.FlattenPad, the
-- one place terrain is cut for structures: roads always win and a refused pad returns nil). A site
-- that varies by up to STREET_PAD_TOLERANCE in town, or RING_PAD_TOLERANCE round the edge, is worth
-- asking for. This module never cuts terrain.
--
-- The hook runs after the pad API lands, so pads are always there in the game. Without them (a test
-- tree, or a pad API that's been pulled) a site may vary by up to UNPADDED_FLAT_ENOUGH, with the base
-- set UNPADDED_BASE of the way up from the lowest ground: an edge hangs at most 0.45 studs and is
-- sunk at most 1.26, inside footing_probe's FLOAT (1.0) and BURY (1.5), rather than a town losing its
-- set piece (RotRidge's flattest lots measure 1.50 to 1.56 over the footprint and its margin, so at
-- 1.5 none of its five towns had one).
local FLAT_ENOUGH = 0.3
local UNPADDED_FLAT_ENOUGH, UNPADDED_BASE = 1.8, 0.3
local STREET_PAD_TOLERANCE, RING_PAD_TOLERANCE = 2.0, 3.5
local PAD_MARGIN = 1

local function canPad()
	return type(MapTerrain.FlattenPad) == "function"
end

-- A flat floor under a set piece: the rectangle `sizeX` by `sizeZ` round `site` (its Y the level
-- wanted, its rotation the set piece's), topped with `material`. The pad API's contract (claude-79):
-- the floor height as a number, or nil and a reason. Returns the same (an error counts as a refusal).
local function requestPad(site, sizeX, sizeZ, material, space)
	if not canPad() then
		return nil, "no pad API"
	end
	-- `space`: the pad's graded edge leaves alone any ground something else has claimed (a street, a
	-- building's lot, the river's banks), so levelling a set piece never regrades a neighbour.
	local ok, level, reason = pcall(MapTerrain.FlattenPad, site, Vector3.new(sizeX, 0, sizeZ), { margin = PAD_MARGIN, material = material, space = space })
	if not ok then
		return nil, "error: " .. tostring(level)
	end
	if type(level) ~= "number" then
		return nil, tostring(reason)
	end
	return level
end

-- Where a set piece `width` x `depth` goes: the free lot nearest the square with a street in front
-- of it, or failing that a spot round the edge of town facing the square. Lots are tried a little
-- out of order (the jitter), so the same town doesn't always put its set piece in the same place.
-- A lot may run past the end of its street (open ground there is fine; anything that isn't is
-- claimed). `ctx.siteDiag` counts what happened, for the build check.
local function findSite(ctx, width, depth, material)
	local diag = { candidates = 0, blocked = 0, sloped = 0, flattest = math.huge, padsAsked = 0, padsRefused = 0 }
	ctx.siteDiag = diag
	local candidates = {}
	for _, street in ipairs(ctx.streets) do
		for _, side in ipairs({ 1, -1 }) do
			local outward = Vector3.new(-street.dir.Z, 0, street.dir.X) * side
			local offset = street.width / 2 + SIDEWALK + VERGE + 1.5 + depth / 2
			local along = width / 2 + 4
			while along <= street.length do
				local at = street.a + street.dir * along + outward * offset
				table.insert(candidates, {
					at = at,
					front = -outward,
					score = flatDistance(at, ctx.center) + ctx.rng:NextNumber(0, 30),
					padTolerance = STREET_PAD_TOLERANCE,
					street = true,
				})
				along += 5
			end
		end
	end
	local ring = ctx.spread + math.max(width, depth) / 2 + 26
	for band = 0, 4 do
		local distance = ring + band * 16
		local start = ctx.rng:NextNumber(0, math.pi * 2)
		for step = 0, 35 do
			local angle = start + step / 36 * math.pi * 2
			local at = Vector3.new(ctx.center.X + math.cos(angle) * distance, 0, ctx.center.Z + math.sin(angle) * distance)
			local toward = Vector3.new(ctx.center.X - at.X, 0, ctx.center.Z - at.Z).Unit
			table.insert(candidates, {
				at = at,
				front = toward,
				score = 100000 + distance + ctx.rng:NextNumber(0, 30),
				padTolerance = RING_PAD_TOLERANCE,
				street = false,
			})
		end
	end
	table.sort(candidates, function(first, second)
		return first.score < second.score
	end)

	-- In order of preference: a street lot that's already flat; a street lot on a pad (a town's
	-- set piece belongs in the town, and on rocky maps the lots are rarely dead flat); a spot round
	-- the edge that's flat; one on a pad. Within each, nearest the square first.
	--
	-- Once the pad API exists every set piece asks it for its floor, flat or not, so the terrain's
	-- footprint registry knows it's there (and paints its ground). A refusal is the terrain saying no
	-- (a road, a neighbour's pad) and the next site along is tried.
	local padding = canPad()
	local flatEnough = padding and FLAT_ENOUGH or UNPADDED_FLAT_ENOUGH
	local halfX, halfZ = width / 2 + PAD_MARGIN, depth / 2 + PAD_MARGIN
	local function settle(found)
		if not padding then
			found.level = found.low + (found.high - found.low) * UNPADDED_BASE
			return found
		end
		diag.padsAsked += 1
		local site = CFrame.new(found.candidate.at.X, (found.low + found.high) / 2, found.candidate.at.Z) * CFrame.Angles(0, found.yaw, 0)
		local floor, reason = requestPad(site, width, depth, material, ctx.space)
		if not floor then
			diag.padsRefused += 1
			diag.lastRefusal = reason
			return nil
		end
		found.padded = true
		found.low, found.high, found.level = floor, floor, floor
		return found
	end
	local function settleFirst(list)
		for _, found in ipairs(list) do
			local settled = settle(found)
			if settled then
				return settled
			end
		end
		return nil
	end

	local flatRings, padStreets, padRings = {}, {}, {}
	for _, candidate in ipairs(candidates) do
		-- The ring sorts after every street lot, nearest first, so a few flat spots on it are plenty.
		if #flatRings >= 3 then
			break
		end
		diag.candidates += 1
		local yaw = yawFacing(candidate.front)
		local reach = candidate.street and (VERGE + 1.5 + SIDEWALK) or 6
		if rectFree(ctx.space, candidate.at, yaw, halfX, halfZ) and entranceClear(ctx, candidate.at, candidate.front, depth / 2, reach) then
			local low, high = groundRange(ctx.groundAt, candidate.at, yaw, halfX, halfZ)
			if low and high - low <= math.max(flatEnough, padding and candidate.padTolerance or 0) then
				low, high = groundRangeFine(ctx.groundAt, candidate.at, yaw, halfX, halfZ)
			end
			if low then
				local range = high - low
				diag.flattest = math.min(diag.flattest, range)
				local found = { candidate = candidate, yaw = yaw, low = low, high = high }
				if range <= flatEnough then
					if candidate.street then
						local settled = settle(found)
						if settled then
							return settled
						end
					else
						table.insert(flatRings, found)
					end
				else
					diag.sloped += 1
					local list = candidate.street and padStreets or padRings
					if padding and range <= candidate.padTolerance and #list < 6 then
						table.insert(list, found)
					end
				end
			end
		else
			diag.blocked += 1
		end
	end
	return settleFirst(padStreets) or settleFirst(flatRings) or settleFirst(padRings)
end

-- Footing attributes (project convention, read by tools/footing_probe.lua): the world Y of a
-- structure's floor and its footprint, measured round its pivot, which goes at the footprint centre.
-- Containers of structures (Theme, Props, Flags) are marked FootingGroup so the probe measures
-- what's inside them rather than one box round a whole town's worth.
local function footing(model, frame, base, sizeX, sizeZ)
	model.WorldPivot = CFrame.new(frame.Position.X, base, frame.Position.Z) * frame.Rotation
	model:SetAttribute("FootingBase", base)
	model:SetAttribute("FootingSize", Vector3.new(sizeX, 0, sizeZ))
end

local function placeSetPiece(ctx, theme, parent)
	local piece = theme.setPiece
	local material = smoothGround(piece.ground)
	local found = findSite(ctx, piece.width, piece.depth, material)
	local diag = ctx.siteDiag
	parent:SetAttribute("SiteCandidates", diag.candidates)
	parent:SetAttribute("SiteBlocked", diag.blocked)
	parent:SetAttribute("SiteSloped", diag.sloped)
	parent:SetAttribute("SiteFlattest", diag.flattest < math.huge and math.floor(diag.flattest * 100) / 100 or -1)
	parent:SetAttribute("SitePadsAsked", diag.padsAsked)
	parent:SetAttribute("SitePadsRefused", diag.padsRefused)
	parent:SetAttribute("SiteLastRefusal", diag.lastRefusal)
	if not found then
		return nil
	end
	local candidate, yaw, level = found.candidate, found.yaw, found.level
	local site = CFrame.new(candidate.at.X, level, candidate.at.Z) * CFrame.Angles(0, yaw, 0)
	ctx.space:AddRect(candidate.at.X, candidate.at.Z, piece.width / 2 + PAD_MARGIN, piece.depth / 2 + PAD_MARGIN, yaw)
	if found.padded then
		task.wait()
	elseif material and ctx.paint and math.abs(ctx.level) < 0.3 and math.abs(found.low - ctx.level) < 0.3 and math.abs(found.high - ctx.level) < 0.3 then
		-- (PAINT_CENTRE is only right for ground whose surface is at 0, which is where towns are laid.)
		-- No pad API yet: a flat lot at the town's own level is repainted in place (the ground doesn't
		-- move). A street lot's paint runs on to the pavement, so no strip of grass is left between.
		local reach = candidate.street and VERGE + 1.5 or 0
		local shift = CFrame.Angles(0, yaw, 0) * Vector3.new(0, 0, -reach / 2)
		paintSite(site.Position + shift, yaw, piece.width, piece.depth + reach, material)
	end
	local kit, model = Kit.new(parent, site, ctx.rng):model(piece.id)
	local built, err = pcall(piece.build, kit, ctx)
	if not built then
		-- Half a set piece is worse than none; the pad and claim stay (the ground is flat and taken).
		model:Destroy()
		error(err, 0)
	end
	model:SetAttribute("SetPiece", piece.name)
	model:SetAttribute("OnStreet", candidate.street)
	model:SetAttribute("Padded", found.padded == true)
	-- The lot itself, for audits: its centre on the ground with -Z toward the street, and its size.
	model:SetAttribute("Site", site)
	model:SetAttribute("SiteSize", Vector3.new(piece.width, 0, piece.depth))
	-- For footing_probe (project convention): the floor's height and footprint round the pivot.
	footing(model, site, level, piece.width, piece.depth)
	return model
end

-- The town's banner on a pole at each corner of the square, hung facing the square's middle.
local function buildFlag(k, flag)
	k:post("FlagFooting", 0.5, 1.6, Vector3.new(0, -0.1, 0), C.concrete, Enum.Material.Concrete)
	k:post("FlagPole", 15.6, 0.5, Vector3.new(0, 0.4, 0), flag.pole or C.iron, Enum.Material.Metal)
	k:ball("FlagFinial", 0.9, CFrame.new(0, 16.3, 0), flag.trim or C.gold, Enum.Material.Metal)
	for _, y in ipairs({ 6.2, 13.6 }) do
		decor(k:cyl("FlagRod", 3.8, 0.24, CFrame.new(0, y, -0.55), flag.trim or C.gold, Enum.Material.Metal))
		k:trim("FlagBracket", Vector3.new(0.2, 0.2, 0.55), CFrame.new(0, y, -0.25), flag.pole or C.iron, Enum.Material.Metal)
	end
	local banner = k:trim("FlagBanner", Vector3.new(3.4, 7.2, 0.14), CFrame.new(0, 9.9, -0.55), flag.color, Enum.Material.Fabric)
	k:trim("FlagFringe", Vector3.new(3.4, 0.35, 0.2), CFrame.new(0, 6.0, -0.55), flag.trim or C.gold, Enum.Material.Fabric)
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 0.4
		gui.MaxDistance = 220
		local emblem = Instance.new("TextLabel")
		emblem.BackgroundTransparency = 1
		emblem.Size = UDim2.fromScale(0.9, 0.62)
		emblem.Position = UDim2.fromScale(0.05, 0.06)
		emblem.Font = flag.font or Enum.Font.FredokaOne
		emblem.Text = flag.emblem
		emblem.TextColor3 = flag.text or C.white
		emblem.TextScaled = true
		emblem.TextStrokeTransparency = 0.7
		emblem.Parent = gui
		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Size = UDim2.fromScale(0.9, 0.24)
		name.Position = UDim2.fromScale(0.05, 0.7)
		name.Font = Enum.Font.GothamBold
		name.Text = flag.caption
		name.TextColor3 = flag.text or C.white
		name.TextScaled = true
		name.Parent = gui
		gui.Parent = banner
	end
end

local function placeFlags(ctx, theme, parent)
	local kit, group = Kit.new(parent, CFrame.identity, ctx.rng):model("Flags")
	group:SetAttribute("FootingGroup", true)
	local placed = 0
	for _, corner in ipairs({ { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }) do
		local x, z = ctx.center.X + corner[1] * FLAG_CORNER, ctx.center.Z + corner[2] * FLAG_CORNER
		if ctx.space:IsFree(x, z, 1.2) then
			local height = solidGround(ctx.groundAt, x, z)
			if height and math.abs(height - ctx.level) < 0.6 then
				ctx.space:AddCircle(x, z, 1.2)
				local inward = Vector3.new(-corner[1], 0, -corner[2]).Unit
				local frame = CFrame.new(x, height, z) * CFrame.Angles(0, yawFacing(inward), 0)
				local flagKit, flagModel = Kit.new(kit.parent, frame, ctx.rng):model("Flag")
				buildFlag(flagKit, theme.flag)
				footing(flagModel, frame, height, 1.6, 1.6)
				placed += 1
			end
		end
	end
	-- An empty FootingGroup reads as a mis-tagged structure to footing_probe, so none is left behind.
	if placed == 0 then
		group:Destroy()
	end
	return placed
end

-- Small themed props on the verges behind the pavements, facing the street, kept well apart. Each
-- stands at the lowest ground under it, so nothing hangs; the rest is sunk by at most this much.
local PROP_SPACING = 18
local PROP_FLAT_ENOUGH = 0.4

local function placeProps(ctx, theme, parent)
	local kinds = theme.props or {}
	if #kinds == 0 or #ctx.streets == 0 then
		return 0
	end
	local kit, group = Kit.new(parent, CFrame.identity, ctx.rng):model("Props")
	group:SetAttribute("FootingGroup", true)

	local totalLength = 0
	for _, street in ipairs(ctx.streets) do
		totalLength += street.length
	end
	local function pickStreet()
		local roll = ctx.rng:NextNumber(0, totalLength)
		for _, street in ipairs(ctx.streets) do
			roll -= street.length
			if roll <= 0 then
				return street
			end
		end
		return ctx.streets[#ctx.streets]
	end

	-- Every kind at least once before any repeats, in a shuffled order.
	local order = {}
	for index = 1, #kinds do
		order[index] = index
	end
	for index = #order, 2, -1 do
		local swap = ctx.rng:NextInteger(1, index)
		order[index], order[swap] = order[swap], order[index]
	end

	local count = theme.propCount or { 7, 10 }
	local wanted = ctx.rng:NextInteger(count[1], count[2])
	local spots = {}
	for index = 1, wanted do
		local kind = kinds[order[(index - 1) % #order + 1]]
		for _ = 1, 30 do
			local street = pickStreet()
			local margin = 8 + kind.radius
			if street.length > margin * 2 then
				local outward = Vector3.new(-street.dir.Z, 0, street.dir.X) * (ctx.rng:NextInteger(0, 1) == 0 and 1 or -1)
				local along = ctx.rng:NextNumber(margin, street.length - margin)
				local at = street.a + street.dir * along + outward * (street.width / 2 + SIDEWALK + VERGE + kind.radius)
				local apart = true
				for _, other in ipairs(spots) do
					if flatDistance(at, other) < PROP_SPACING then
						apart = false
						break
					end
				end
				if apart and ctx.space:IsFree(at.X, at.Z, kind.radius) then
					-- Props never get pads: they only go where the verge is already flat under them.
					local low, high = groundRangeFine(ctx.groundAt, at, 0, kind.radius, kind.radius)
					if low and high - low <= PROP_FLAT_ENOUGH then
						ctx.space:AddCircle(at.X, at.Z, kind.radius)
						table.insert(spots, at)
						local frame = CFrame.new(at.X, low, at.Z) * CFrame.Angles(0, yawFacing(-outward), 0)
						local propKit, propModel = Kit.new(kit.parent, frame, ctx.rng):model(kind.id)
						local built, err = pcall(kind.build, propKit, ctx)
						if built then
							footing(propModel, frame, low, kind.radius * 2, kind.radius * 2)
							-- Street props can be shot apart, each one whole (DestructibleService, #56).
							propModel:SetAttribute("Destructible", "Prop")
						else
							propModel:Destroy()
							warn(string.format("[TownThemes] %s prop %s failed: %s", theme.id, kind.id, tostring(err)))
						end
						break
					end
				end
			end
		end
	end
	if #spots == 0 then
		group:Destroy()
	end
	return #spots
end

local function countParts(root)
	local count = 0
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

local function themeTown(town, theme, space, groundAt, preset, rng)
	-- An attribute, so it comes from the map build rather than a client, but it goes through
	-- SafeValue like every other Vector3: a NaN or an absurd coordinate would put a whole theme
	-- somewhere it can never be found (project rule, enforced by verify.py).
	local center = town:GetAttribute("TownCenter")
	if not SafeValue.Vector3(center) then
		return nil
	end
	local spread = town:GetAttribute("TownSpread") or ((town:GetAttribute("TownRadius") or 150) - 40)
	-- No solid ground at the town's own centre means something is very wrong: leave the town alone.
	local level = solidGround(groundAt, center.X, center.Z)
	if not level then
		warn(string.format("[TownThemes] %s: no ground under the town centre", theme.id))
		return nil
	end
	local ctx = {
		town = town,
		center = Vector3.new(center.X, level, center.Z),
		level = level,
		spread = spread,
		streets = streetsOf(town),
		furniture = furnitureOf(town),
		space = space,
		groundAt = groundAt,
		rng = rng,
		preset = preset,
		paint = true,
	}

	-- Wall clock, for the 15 s per-map build budget: os.clock() is CPU time in Roblox and this
	-- function yields, so it would under-read by exactly the part that matters.
	local started = DateTime.now().UnixTimestampMillis

	local model = Instance.new("Model")
	model.Name = "Theme"
	model:SetAttribute("Theme", theme.id)
	model:SetAttribute("FootingGroup", true)
	model.Parent = town

	-- Each part of the theme on its own: a broken prop builder mustn't take down a set piece that's
	-- already standing on its pad (which would leave a bare pad and a claim with nothing on it).
	local function attempt(what, fn)
		local ok, result = pcall(fn)
		if not ok then
			warn(string.format("[TownThemes] %s %s failed: %s", theme.id, what, tostring(result)))
			model:SetAttribute("Failed", ((model:GetAttribute("Failed") or "") .. " " .. what))
			return nil
		end
		return result
	end
	ctx.setPiece = attempt("set piece", function()
		return placeSetPiece(ctx, theme, model)
	end)
	-- No yield here: a whole town's theme is ~40 ms of work and Build yields once per town; the
	-- second yield was ~16 ms of the 40 (measured, SahurSprings 101), and the padded path yields for
	-- its terrain write on its own.
	ctx.flags = attempt("flags", function()
		return placeFlags(ctx, theme, model)
	end) or 0
	ctx.props = attempt("props", function()
		return placeProps(ctx, theme, model)
	end) or 0
	if #model:GetChildren() == 0 then
		-- Nothing found room: keep the container for its site diagnostics, but not as a footing group.
		model:SetAttribute("FootingGroup", nil)
	end
	local parts = countParts(model)
	model:SetAttribute("ThemeParts", parts)
	local millis = DateTime.now().UnixTimestampMillis - started
	model:SetAttribute("ThemeMillis", millis)
	local tagline = TownThemes.Taglines[theme.name]
	if tagline then
		town:SetAttribute("TownTagline", tagline)
	end
	return {
		setPiece = ctx.setPiece and ctx.setPiece.Name or nil,
		onStreet = ctx.setPiece and ctx.setPiece:GetAttribute("OnStreet") or nil,
		flags = ctx.flags,
		props = ctx.props,
		parts = parts,
		millis = millis,
	}
end

function TownThemes.Build(map, space, groundHeightAt, preset)
	-- The one roll this takes from the global generator; everything after is its own.
	local rng = Random.new(math.random(1, 2147483646))
	local result = { parts = 0, millis = 0, towns = {} }
	for _, town in ipairs(map:GetChildren()) do
		local name = town:IsA("Model") and town:GetAttribute("TownName")
		local theme = name and Themes[name]
		if theme then
			local info = themeTown(town, theme, space, groundHeightAt, preset, rng)
			if info then
				result.towns[name] = info
				result.parts += info.parts
				result.millis += info.millis
			end
			task.wait()
		end
	end
	return result
end

-- For the gallery and the build check only: every theme in a row along X from `origin`, `spacing`
-- apart, each on flat ground at origin.Y -- its set piece facing -Z, a flag in front to one side,
-- and one of each of its props in a line in front of that. Returns one entry per theme with where
-- each piece went, so a gallery can aim a camera at them.
function TownThemes.BuildAll(parent, origin, spacing, names)
	spacing = spacing or 90
	local rng = Random.new(67)
	local entries = {}
	for index, name in ipairs(names or TownThemes.Order) do
		local theme = Themes[name]
		if theme then
			local base = origin + Vector3.new((index - 1) * spacing, 0, 0)
			local model = Instance.new("Model")
			model.Name = "Theme"
			model:SetAttribute("TownName", name)
			model:SetAttribute("Theme", theme.id)
			model.Parent = parent
			local ctx = { rng = rng, paint = false, level = origin.Y, groundAt = function()
				return origin.Y
			end, space = MapSpace.new() }
			local piece = theme.setPiece
			-- Each piece on its own pcall, so one broken builder doesn't hide the rest.
			local function attempt(what, fn)
				local ok, err = pcall(fn)
				if not ok then
					warn(string.format("[TownThemes] %s %s failed: %s", theme.id, what, tostring(err)))
				end
			end
			attempt(piece.id, function()
				piece.build((Kit.new(model, CFrame.new(base), rng):model(piece.id)), ctx)
			end)
			local flagAt = base + Vector3.new(-piece.width / 2 + 2, 0, -piece.depth / 2 - 6)
			attempt("flag", function()
				buildFlag((Kit.new(model, CFrame.new(flagAt), rng):model("Flag")), theme.flag)
			end)
			local props = {}
			local x = base.X - piece.width / 2
			for _, kind in ipairs(theme.props or {}) do
				x += kind.radius
				local at = Vector3.new(x, origin.Y, base.Z - piece.depth / 2 - 16 - kind.radius)
				attempt(kind.id, function()
					kind.build((Kit.new(model, CFrame.new(at), rng):model(kind.id)), ctx)
				end)
				table.insert(props, { id = kind.id, at = at, radius = kind.radius })
				x += kind.radius + 3
			end
			table.insert(entries, { name = name, model = model, base = base, width = piece.width, depth = piece.depth, flagAt = flagAt, props = props })
		end
	end
	return entries
end

return TownThemes
