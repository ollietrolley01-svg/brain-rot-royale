-- The lobby: Rot Island, a floating island high above the maps.
--
--   The island      a round plaza on a grass rim, a tapered rock underside hung with glowing
--                   crystals, and four waterfalls pouring off the edge into the sky
--   The pier        where you spawn: a wooden pier out over the edge, with the Rot Express
--                   moored at the end of it
--   The Rot Express an airship — hull, cabin, balloon, propellers. Walk up the gangway onto
--                   the deck and stand on the ready pad to ready up. It's where you board for
--                   the next drop.
--   The Rot Tree    a giant tree in the middle of the plaza, its canopy hung with blossom, the
--                   golden Sahur statue in front of it
--   Cloud Climb     the obby, built of nothing but the tree's branches: forked limbs up the
--                   trunk, a long bough out from under the leaves, limbs spiralling up round the
--                   canopy, deadwood that snaps, springy limbs, thorn rotors, three checkpoints,
--                   and the summit on a spire above it all (course from CloudClimbCourse)
--   Market Row      stalls along the far side: the Trading Post (with stools and benches you can
--                   sit on), the Cosmetics stall with the featured accessory on a mannequin, the
--                   Crate Altar (what anyone pulls from a crate appears there) with its console
--                   of crate tiers, and the Daily Spin's wheel out in the open on its own dais
--   The Arena       a raised terrace to the east: companion practice targets, three Legendary
--                   guns turning on pedestals, and the firing range — take a gun off the rack
--                   and shoot the targets, and it is taken back when you leave the terrace
--                   (RangeService)
--   The Pitch       turf to the west with a goal; kick a play ball in for coins
--   Boards          the server's top players and the all-time winners on holo pylons by the
--                   pier, the how-to board at the market, and a Walk of Fame of the top three
--   Ambience        lamp posts, lanterns floating over the
--                   plaza, fireflies, and fireworks over the tree every so often
--   Wayfinding      (lobby v2) the Rot Road, a raised purple-stone road with glowing studs from the
--                   pier head to the statue and on to every district, and a gate over each
--                   district's way in (FIRING RANGE, PLAY BALL, MARKET ROW, CRATES + SPIN, and ALL
--                   ABOARD at the gangway), each in its colour with a Rotling on top and swinging
--                   banners (tools/lobby_layout_check.py walks it from the spawn)
--
-- Layout, relative to the centre (+X east, +Z the pier and spawn side); angles are degrees
-- with 0 = +X and 90 = +Z: plaza r100, grass rim r132, tree at the centre, statue (0, 30),
-- pier z 98–126, airship z 128–182, market stalls at r74 from 225° to 315° with the Crate
-- Altar at 270° r84, arena terrace centred (86, 0), pitch centred (-74, 0),
-- boards at 55° and 125° r84, Walk of Fame at 150°–170° r88, waterfalls at 45°, 135°, 225°,
-- 315° on the rim. The showcase podiums (ShowcaseService's SLOTS) stand in arcs on the open paving
-- at r44, r70 and r90, clear of all of this (tools/showcase_layout_check.py).

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local CrateModels = require(Shared:WaitForChild("CrateModels"))
local DailySpinData = require(Shared:WaitForChild("DailySpinData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local AccessoryService = require(script.Parent:WaitForChild("AccessoryService"))
local PracticeDummy = require(script.Parent:WaitForChild("PracticeDummy"))
local CloudClimbCourse = require(script.Parent:WaitForChild("CloudClimbCourse"))
local GlobalBoardService = require(script.Parent:WaitForChild("GlobalBoardService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local LobbyService = {}

-- THE CLOCK EVERY COOLDOWN AND TIMER IN THIS FILE RUNS ON. tick(), never os.clock(): os.clock() is
-- process CPU time in Roblox, which runs slow against the wall while the server waits, so the pad
-- and ball cooldowns, the goal window, the wheel's spin and the Cloud Climb's clock all stretched
-- under load. Same clock as PlayerData's wallNow and RateLimit.Now.
local function wallNow()
	return tick()
end

-- Set by Bootstrap.
LobbyService.OnReadyPad = function() end
-- (player, seconds, firstClear, isRecord): announce and reward a Cloud Climb clear.
LobbyService.OnObbyComplete = function() end
-- (player): a paid goal on the pitch.
LobbyService.OnGoal = function() end
-- (player) -> ok, message, segment: claim the daily spin; `segment` is where the wheel stops.
LobbyService.OnDailySpin = function()
	return false, "Not set up."
end
-- (player, crateTier) -> ok, message: open one of the player's crates at the Crate Altar.
LobbyService.OnAltarOpen = function()
	return false, "Not set up."
end

-- Tells a player's menu to open on a tab (the booths' prompts).
local openMenuTab = Remotes.Event("OpenMenuTab")

-- The play balls and the invisible walls that keep them on the island collide with each other
-- and nothing else — players walk straight through the walls.
local BALL_GROUP = "PlayBalls"
local WALL_GROUP = "BallWalls"
pcall(function()
	PhysicsService:RegisterCollisionGroup(BALL_GROUP)
	PhysicsService:RegisterCollisionGroup(WALL_GROUP)
	PhysicsService:CollisionGroupSetCollidable(WALL_GROUP, "Default", false)
	PhysicsService:CollisionGroupSetCollidable(WALL_GROUP, WALL_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(WALL_GROUP, BALL_GROUP, true)
	PhysicsService:CollisionGroupSetCollidable(BALL_GROUP, "Default", true)
end)

-- Where MatchService puts the spawn pad and drops players, relative to the lobby centre: the
-- middle of the pier.
LobbyService.SpawnOffset = Vector3.new(0, 0.9, 110)
LobbyService.SpawnHalfWidth = 12

local LEADERBOARD_ROWS = 10
local LEADERBOARD_REFRESH = 8
local GLOBAL_BOARD_REFRESH = 60
local PAD_COOLDOWN = 1.5

local PLAZA_RADIUS = 100
local RIM_RADIUS = 132
local STALL_RADIUS = 74

local GOLD = Color3.fromRGB(255, 196, 64)
local PINK = Color3.fromRGB(255, 110, 200)
local GREEN = Color3.fromRGB(94, 214, 122)
local SKY = Color3.fromRGB(110, 210, 255)
local WHITE = Color3.fromRGB(230, 234, 244)
local MUTED = Color3.fromRGB(170, 176, 194)
local DARK = Color3.fromRGB(24, 26, 36)
local IRON = Color3.fromRGB(60, 56, 70)
local WOOD = Color3.fromRGB(128, 90, 56)
local WOOD_DARK = Color3.fromRGB(88, 62, 40)
local PLAZA = Color3.fromRGB(214, 202, 178)
local PLAZA_DARK = Color3.fromRGB(168, 156, 134)
local GRASS = Color3.fromRGB(92, 164, 84)
local LEAF = Color3.fromRGB(84, 170, 92)
local BARK = Color3.fromRGB(98, 66, 44)
local WATER = Color3.fromRGB(96, 190, 240)
local STONE = Color3.fromRGB(120, 118, 122)
local CRYSTAL = Color3.fromRGB(120, 230, 255)

local playgroundFx = Remotes.Event("PlaygroundFx")

local leaderboardRows = nil
local globalRows = nil
local hallPlates = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Every part is stamped with the set piece it belongs to (a "Group" attribute), so the build
-- check can tell an intentional overlap inside one piece from two pieces built through each
-- other. Builders set this as they start.
local currentGroup = "Island"

local function part(parent, size, cframe, color, material, shape)
	local instance = Instance.new("Part")
	if shape then
		instance.Shape = shape
	end
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = color
	instance.Material = material or Enum.Material.SmoothPlastic
	instance.Anchored = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance:SetAttribute("Group", currentGroup)
	instance.Parent = parent
	return instance
end

-- A wedge: vertical face at the back (+Z), sloping down to the front.
local function wedge(parent, size, cframe, color, material)
	local instance = Instance.new("WedgePart")
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = color
	instance.Material = material or Enum.Material.SmoothPlastic
	instance.Anchored = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance:SetAttribute("Group", currentGroup)
	instance.Parent = parent
	return instance
end

-- A Seat: something a player can actually sit on. Same conventions as `part` — anchored, smooth
-- surfaces, tagged with the piece it belongs to. Roblox sits a character that walks into one.
local function seat(parent, size, cframe, color, material, shape)
	local instance = Instance.new("Seat")
	if shape then
		instance.Shape = shape
	end
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = color
	instance.Material = material or Enum.Material.SmoothPlastic
	instance.Anchored = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance:SetAttribute("Group", currentGroup)
	instance.Parent = parent
	return instance
end

-- Upright cylinder standing on `position`.
local function column(parent, height, diameter, position, color, material)
	return part(parent, Vector3.new(height, diameter, diameter),
		CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), color, material,
		Enum.PartType.Cylinder)
end

-- A flat disc lying on `position`, `thickness` tall.
local function disc(parent, diameter, thickness, position, color, material)
	return part(parent, Vector3.new(thickness, diameter, diameter),
		CFrame.new(position + Vector3.new(0, thickness / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), color, material,
		Enum.PartType.Cylinder)
end

-- A bar from one point to another.
local function beam(parent, from, to, thickness, color, material)
	return part(parent, Vector3.new(thickness, thickness, (to - from).Magnitude), CFrame.lookAt(from:Lerp(to, 0.5), to), color, material)
end

-- Purely visual: walks through, doesn't block shots or fire touches.
local function decor(instance)
	instance.CanCollide = false
	instance.CanQuery = false
	instance.CanTouch = false
	return instance
end

local function pointLight(parent, color, range, brightness)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Parent = parent
	return light
end

local function spin(instance, degreesPerSecond)
	instance:SetAttribute("SpinSpeed", degreesPerSecond)
	CollectionService:AddTag(instance, "AmbientSpin")
	return instance
end

local function bob(instance, height, speed, phase)
	instance:SetAttribute("BobHeight", height)
	instance:SetAttribute("BobSpeed", speed)
	instance:SetAttribute("BobPhase", phase or math.random() * 6)
	-- A thing that bobs hangs in the air on purpose; saying so keeps it out of the lobby audit's
	-- floating list, which is for things that float by mistake.
	instance:SetAttribute("IntentionalFloat", true)
	CollectionService:AddTag(instance, "AmbientBob")
	return instance
end

-- Floating label sized in studs (`width` x `height`), not pixels, so it shrinks with distance
-- like a real sign; the text size is capped so it doesn't balloon up close. Returns the label.
local function billboard(adornee, text, color, offset, width, height, maxDistance)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(width, height)
	gui.StudsOffsetWorldSpace = offset
	gui.MaxDistance = maxDistance or MatchConfig.LobbyLabelDistance
	gui.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Parent = gui

	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 40
	cap.Parent = label

	gui.Parent = adornee
	return label
end

-- A label that names a key the player can rebind. The server's own text names no key;
-- StarterPlayerScripts/KeyHintClient swaps in `template` for keyboard players, each {ActionId}
-- replaced by that player's key for the Settings action (Settings.KeyLabel).
local function keyHint(label, template)
	label:SetAttribute("KeyHint", template)
	CollectionService:AddTag(label, "KeyHint")
	return label
end

-- Text on one face of a part.
local function surfaceText(instance, face, rows, pixelsPerStud, maxDistance)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 25
	gui.LightInfluence = 0
	gui.MaxDistance = maxDistance or MatchConfig.LobbySignDistance
	local labels = {}
	for index, row in ipairs(rows) do
		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromScale(0, row.y)
		label.Size = UDim2.fromScale(1, row.h)
		label.BackgroundTransparency = 1
		label.Font = row.font or Enum.Font.FredokaOne
		label.Text = row.text
		label.TextColor3 = row.color or WHITE
		label.TextStrokeTransparency = row.stroke or 0.4
		label.TextScaled = true
		label.Parent = gui
		labels[index] = label
	end
	gui.Parent = instance
	return labels
end

-- A point on the plaza from (degrees, radius).
local function spot(base, degrees, radius)
	local angle = math.rad(degrees)
	return base + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

-- A frame at `position` whose -Z faces the plaza centre.
local function facingCentre(position, base)
	return CFrame.lookAt(position, Vector3.new(base.X, position.Y, base.Z))
end

local function livingPlayerFromHit(hit)
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if player and humanoid and humanoid.Health > 0 then
		return player
	end
	return nil
end

-- A neon lamp post: iron, a glass lantern, a warm light.
local function lampPost(lobby, position, height)
	height = height or 11
	part(lobby, Vector3.new(2.4, 0.6, 2.4), CFrame.new(position + Vector3.new(0, 0.3, 0)), IRON, Enum.Material.Metal)
	-- The post starts 0.1 inside its base, not on the base's own underside (every lamp on the
	-- island and the pier had the two coincident, a pair for the pass on each).
	column(lobby, height - 0.1, 0.7, position + Vector3.new(0, 0.1, 0), IRON, Enum.Material.Metal)
	part(lobby, Vector3.new(1.8, 0.3, 1.8), CFrame.new(position + Vector3.new(0, height + 0.1, 0)), IRON, Enum.Material.Metal)
	local glass = part(lobby, Vector3.new(1.6, 2, 1.6), CFrame.new(position + Vector3.new(0, height + 1.2, 0)),
		Color3.fromRGB(255, 236, 200), Enum.Material.Glass)
	glass.Transparency = 0.4
	local core = decor(part(lobby, Vector3.new(1, 1.2, 1), CFrame.new(position + Vector3.new(0, height + 1.2, 0)),
		Color3.fromRGB(255, 220, 150), Enum.Material.Neon))
	part(lobby, Vector3.new(2, 0.4, 2), CFrame.new(position + Vector3.new(0, height + 2.4, 0)), IRON, Enum.Material.Metal)
	pointLight(core, Color3.fromRGB(255, 214, 156), 30, 1.6)
end

-- Wooden railing along a line, posts every few studs. Runs that share an end (the rim ring, the
-- deck's corner) share the post there rather than building it twice on top of itself.
local railPosts = {}

local function railing(lobby, from, to, height)
	height = height or 2.6
	local length = (to - from).Magnitude
	local posts = math.max(1, math.floor(length / 5))
	for index = 0, posts do
		local position = from:Lerp(to, index / posts)
		local key = string.format("%d,%d,%d", math.round(position.X * 4), math.round(position.Y * 4), math.round(position.Z * 4))
		if not railPosts[key] then
			railPosts[key] = true
			part(lobby, Vector3.new(0.5, height, 0.5), CFrame.new(position + Vector3.new(0, height / 2, 0)), WOOD_DARK, Enum.Material.Wood)
		end
	end
	-- The rails stop at the posts' faces instead of running through them. Two runs meeting at a
	-- shared post at an angle (the rim ring turns 12 degrees a segment) overlapped in a lens over a
	-- stud long, tops and undersides flush, at every joint round the island; and the upper rail's
	-- top sat 0.05 under the post's top, inside the pass's tolerance, wherever a rail crossed a
	-- post. Now the end of a rail is buried in its post and its top is a clear 0.2 below the post's.
	local direction = length > 0.01 and (to - from).Unit or Vector3.zAxis
	local inset = math.min(0.25, length * 0.25)
	for _, y in ipairs({ height - 0.35, height * 0.5 }) do
		decor(beam(lobby, from + direction * inset + Vector3.new(0, y, 0), to - direction * inset + Vector3.new(0, y, 0), 0.3, WOOD, Enum.Material.Wood))
	end
end

--------------------------------------------------------------------------------
-- The island
--------------------------------------------------------------------------------

local WATERFALL_ANGLES = { 45, 135, 225, 315 }

local function buildIsland(lobby, base)
	-- The plaza floor, then the paving as a stack of discs: a dark band round the edge (r98.5 to
	-- r100) and a gold ring round a dark centre. Each disc sits a clear step above the one under
	-- it and starts a step lower inside the slab, so no two of their faces are ever flush, and the
	-- paving tops out at 0.17 across the plaza (0.29 inside the gold ring) — everything that
	-- stands on the plaza is built to clear that.
	disc(lobby, PLAZA_RADIUS * 2, 3, base - Vector3.new(0, 3, 0), PLAZA, Enum.Material.Marble)
	-- The layers' undersides start 0.17 inside the slab and step 0.07 apart. They used to start at
	-- -0.05, and everything standing on the plaza with its foot at 0 (the tree's trunk, the statue's
	-- plinth, every stall floor, the arena's stone, the boards' bases) had its underside 0.05 from
	-- the first layer's: inside the z-fight pass's 0.055, so the pass sank or thickened all of them
	-- on every build. Things set 0.1 into the plaza (posts, trunks, signs — the "sunk into the grass"
	-- convention) have their undersides at -0.1, so the first layer starts a clear 0.07 under that.
	for index, layer in ipairs({
		{ 200, PLAZA_DARK, Enum.Material.Marble }, { 197, PLAZA, Enum.Material.Marble },
		{ 66, GOLD, Enum.Material.Foil }, { 58, PLAZA_DARK, Enum.Material.Marble },
	}) do
		local top = 0.11 + (index - 1) * 0.06
		local bottom = -0.17 - (index - 1) * 0.07
		decor(disc(lobby, layer[1], top - bottom, base + Vector3.new(0, bottom, 0), layer[2], layer[3]))
	end
	disc(lobby, RIM_RADIUS * 2, 3.2, base - Vector3.new(0, 3.3, 0), GRASS, Enum.Material.Grass)

	-- The underside tapers away in rock, down to a point hung with crystals. Each layer reaches down
	-- into the next. (The first was 10 deep, which left a 2-stud slit of sky right through the island
	-- between it and the second.)
	for index, layer in ipairs({ { 128, 14 }, { 112, 12 }, { 90, 14 }, { 62, 16 }, { 34, 18 }, { 14, 12 } }) do
		local top = -3.3 - (index - 1) * 12
		disc(lobby, layer[1] * 2, layer[2], base + Vector3.new(0, top - layer[2], 0),
			STONE:Lerp(Color3.new(0, 0, 0), index * 0.08), index > 4 and Enum.Material.Basalt or Enum.Material.Rock)
	end
	for index = 1, 9 do
		local angle = index / 9 * math.pi * 2
		local radius = index % 2 == 0 and 22 or 40
		local tip = base + Vector3.new(math.cos(angle) * radius, -78 - (index % 3) * 6, math.sin(angle) * radius)
		local crystal = decor(part(lobby, Vector3.new(3, 12, 3), CFrame.new(tip + Vector3.new(0, 6, 0)) * CFrame.Angles(0.15 * (index % 2 == 0 and 1 or -1), angle, 0),
			CRYSTAL, Enum.Material.Neon))
		crystal.Transparency = 0.25
		-- Hung in the air under the island on purpose, bobbing.
		crystal:SetAttribute("IntentionalFloat", true)
		pointLight(crystal, CRYSTAL, 26, 1.4)
		bob(crystal, 0.8, 0.8, index)
	end
	local keel = decor(part(lobby, Vector3.new(5, 18, 5), CFrame.new(base + Vector3.new(0, -96, 0)), CRYSTAL, Enum.Material.Neon))
	keel.Transparency = 0.2
	keel:SetAttribute("IntentionalFloat", true)
	pointLight(keel, CRYSTAL, 40, 2)

	-- Waterfalls off the rim: a pool cut into the grass, the cascade hanging over the edge, mist
	-- at the bottom.
	for _, degrees in ipairs(WATERFALL_ANGLES) do
		local edge = spot(base, degrees, RIM_RADIUS - 8)
		local look = facingCentre(edge, base)
		local pool = decor(disc(lobby, 18, 0.5, edge - Vector3.new(0, 0.2, 0), WATER, Enum.Material.Glass))
		pool.Transparency = 0.3
		local cascade = decor(part(lobby, Vector3.new(12, 52, 2.2), look * CFrame.new(0, -26, 8), WATER, Enum.Material.Neon))
		cascade.Transparency = 0.45
		local foam = decor(part(lobby, Vector3.new(13, 1.6, 3), look * CFrame.new(0, -0.4, 8), Color3.fromRGB(220, 245, 255), Enum.Material.Neon))
		foam.Transparency = 0.2
		bob(foam, 0.2, 5, degrees)
		pointLight(cascade, WATER, 30, 1.2)
		local mist = Instance.new("ParticleEmitter")
		mist.Color = ColorSequence.new(Color3.fromRGB(225, 245, 255))
		mist.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 6) })
		mist.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
		mist.Lifetime = NumberRange.new(2, 3.5)
		mist.Speed = NumberRange.new(2, 4)
		mist.Rate = 6
		mist.SpreadAngle = Vector2.new(60, 60)
		mist.Parent = cascade
		-- Rocks either side of the pool.
		for _, side in ipairs({ -1, 1 }) do
			part(lobby, Vector3.new(4, 3, 4), look * CFrame.new(side * 9, 1.2, 2) * CFrame.Angles(0.3, side, 0.2), STONE, Enum.Material.Rock,
				Enum.PartType.Ball)
		end
	end

	-- Invisible walls the balls can't pass (players can): all the way round the rim, and across
	-- the end of the pier so nothing rolls onto the airship.
	for index = 0, 35 do
		local a = math.rad(index * 10)
		local b = math.rad((index + 1) * 10)
		local from = base + Vector3.new(math.cos(a) * (RIM_RADIUS - 1), 0, math.sin(a) * (RIM_RADIUS - 1))
		local to = base + Vector3.new(math.cos(b) * (RIM_RADIUS - 1), 0, math.sin(b) * (RIM_RADIUS - 1))
		local wall = part(lobby, Vector3.new(0.6, 12, (to - from).Magnitude + 0.6), CFrame.lookAt(from:Lerp(to, 0.5) + Vector3.new(0, 6, 0), to + Vector3.new(0, 6, 0)),
			WATER, Enum.Material.SmoothPlastic)
		wall.Transparency = 1
		wall.CanQuery = false
		wall.CanTouch = false
		wall.CollisionGroup = WALL_GROUP
		wall.Name = "BallWall"
	end
	local pierWall = part(lobby, Vector3.new(46, 12, 0.6), CFrame.new(base + Vector3.new(0, 6, 128.5)), WATER, Enum.Material.SmoothPlastic)
	pierWall.Transparency = 1
	pierWall.CanQuery = false
	pierWall.CanTouch = false
	pierWall.CollisionGroup = WALL_GROUP
	pierWall.Name = "BallWall"

	-- A low rail round the rim, with gaps at the waterfalls and the pier.
	for index = 0, 29 do
		local degrees = index * 12
		local skip = math.abs(((degrees - 90 + 180) % 360) - 180) < 20
		for _, fall in ipairs(WATERFALL_ANGLES) do
			if math.abs(((degrees - fall + 180) % 360) - 180) < 12 then
				skip = true
			end
		end
		if not skip then
			-- Posts set into the grass (top -0.1), rails at the same heights as before. (The posts used
			-- to start at 0, a tenth of a stud above the ground.)
			local sink = Vector3.new(0, 0.4, 0)
			railing(lobby, spot(base, degrees, RIM_RADIUS - 2) - sink, spot(base, degrees + 12, RIM_RADIUS - 2) - sink, 2.8)
		end
	end

	-- Trees round the rim, between everything else (none within reach of the arena's targets at
	-- (108, ±22)).
	for _, degrees in ipairs({ 24, 40, 60, 112, 155, 175, 195, 210, 240, 300, 322, 338 }) do
		local position = spot(base, degrees, RIM_RADIUS - 18)
		-- The trunk's foot is set into the grass (whose top is at -0.1); it used to stand a tenth
		-- of a stud above it.
		column(lobby, 10.4, 1.6, position - Vector3.new(0, 0.4, 0), BARK, Enum.Material.Wood)
		local size = 9 + (degrees % 3) * 1.5
		part(lobby, Vector3.new(size, size, size), CFrame.new(position + Vector3.new(0, 13, 0)), LEAF, Enum.Material.Grass, Enum.PartType.Ball)
		part(lobby, Vector3.new(size * 0.7, size * 0.7, size * 0.7), CFrame.new(position + Vector3.new(2.5, 11, 1.5)),
			LEAF:Lerp(Color3.new(1, 1, 1), 0.1), Enum.Material.Grass, Enum.PartType.Ball)
	end

	-- Lamp posts round the plaza, clear of the ramps, the pitch and the walkway from the pier.
	for _, degrees in ipairs({ 45, 105, 140, 220, 255, 315 }) do
		lampPost(lobby, spot(base, degrees, 56))
	end
end

--------------------------------------------------------------------------------
-- The pier and the Rot Express
--------------------------------------------------------------------------------

local function buildPier(lobby, base)
	-- The deck starts just past the plaza's edge (r100) and runs out over the grass rim to z128,
	-- laid on the grass (its underside on the rim's top, at -0.1) with its walking surface at 0.4.
	local deck = part(lobby, Vector3.new(44, 0.5, 27.5), CFrame.new(base + Vector3.new(0, 0.15, 114.25)), WOOD, Enum.Material.WoodPlanks)
	deck.Name = "Pier"
	-- Plank lines proud of the deck, and a kerb along each edge.
	-- The plank lines are set into the deck and stand 0.08 above it (they used to hover 0.05 over
	-- it); the kerbs overlap its edges (they stood 0.35 off them, leaving a slit down each side).
	for index = 0, 9 do
		-- Plank lines set inside the deck rather than ending exactly level with its sides: matching
		-- its 44 put twenty face-pairs in the same two planes for the pass to pull apart.
		-- Plank lines a clear 0.07 over the deck's top (0.4), so their undersides never share a
		-- plane with the lamp bases' and rail posts' standing on it.
		decor(part(lobby, Vector3.new(43.8, 0.06, 0.2), CFrame.new(base + Vector3.new(0, 0.5, 101.5 + index * 2.8)), WOOD_DARK, Enum.Material.Wood))
	end
	for _, x in ipairs({ -22.2, 22.2 }) do
		-- Likewise the edge beams stop inside the deck's ends.
		-- Edge beams with their undersides 0.07 above the deck's (-0.1), not in it.
		part(lobby, Vector3.new(0.6, 0.7, 27.3), CFrame.new(base + Vector3.new(x, 0.32, 114.25)), WOOD_DARK, Enum.Material.Wood)
	end
	railing(lobby, base + Vector3.new(-22, 0.4, 101), base + Vector3.new(-22, 0.4, 127), 2.6)
	railing(lobby, base + Vector3.new(22, 0.4, 101), base + Vector3.new(22, 0.4, 127), 2.6)
	for _, x in ipairs({ -18, 18 }) do
		lampPost(lobby, base + Vector3.new(x, 0.4, 101), 9)
	end
	-- A welcome arch over the landward end of the pier.
	for _, x in ipairs({ -12, 12 }) do
		column(lobby, 12, 1.2, base + Vector3.new(x, 0, 96), WOOD_DARK, Enum.Material.Wood)
	end
	local arch = part(lobby, Vector3.new(27, 3.4, 1), CFrame.new(base + Vector3.new(0, 12.6, 96)), WOOD_DARK, Enum.Material.WoodPlanks)
	-- The greeting faces the pier. Everyone arrives on the +Z side (the spawn pad is at z 110,
	-- SpawnOffset; the airship docks there too) looking towards the plaza, so the face they walk up to
	-- is Back (+Z); Front (-Z) is the one seen from the plaza on the way out. It was the other way
	-- round, and the welcome faced the people leaving (#86).
	surfaceText(arch, Enum.NormalId.Back, {
		{ y = 0.05, h = 0.9, text = "WELCOME TO ROT ISLAND", color = GOLD },
	}, 30, 200)
	surfaceText(arch, Enum.NormalId.Front, {
		{ y = 0.05, h = 0.9, text = "ROT ISLAND", color = GOLD },
	}, 30, 200)
	for index = 0, 8 do
		-- Bulbs sitting on the arch's top edge (at 14.3), not hovering over it.
		local bulb = decor(part(lobby, Vector3.new(0.6, 0.6, 0.6), CFrame.new(base + Vector3.new(-12 + index * 3, 14.55, 96)),
			index % 2 == 0 and GOLD or PINK, Enum.Material.Neon, Enum.PartType.Ball))
		if index % 4 == 0 then
			pointLight(bulb, bulb.Color, 10, 0.8)
		end
	end
end

-- MODULE SCOPE, NOT A LOCAL INSIDE buildReadyPad. It is the debounce for a Touched connection that
-- lives as long as the server does, so as an upvalue it grew by one entry for every player who ever
-- stepped on the ready pad and released none of them -- a slow leak keyed by Player, which also holds
-- the Instance alive. Cleared in the PlayerRemoving handler beside climbRuns and lastGoalPaidAt,
-- which are at module scope for exactly this reason.
local readyPadLastTouch = {}

local function buildReadyPad(lobby, center)
	local ring = decor(disc(lobby, 13, 0.3, center, GREEN, Enum.Material.Neon))
	-- The pad stands clear of the ring's underside. At 0.05 the two undersides were within the
	-- z-fight pass's reach and it pushed them apart itself on every build.
	local pad = disc(lobby, 11, 0.4, center + Vector3.new(0, 0.07, 0), Color3.fromRGB(30, 44, 36), Enum.Material.DiamondPlate)
	pad.Name = "ReadyPad"
	for index = 0, 3 do
		-- Arrows set into the pad's top (0.47 above `center`), not hovering over it.
		decor(part(lobby, Vector3.new(1.2, 0.2, 3), CFrame.new(center + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, index / 4 * math.pi * 2, 0)
			* CFrame.new(0, 0, 3.2), GREEN, Enum.Material.Neon))
	end
	pointLight(pad, GREEN, 20, 2)
	billboard(pad, "STAND HERE TO READY UP", GREEN, Vector3.new(0, 5.5, 0), 12, 1.8)
	-- The ready key can be rebound, so it's filled in per player (it said F whatever you'd bound).
	keyHint(billboard(pad, "(or use your ready key anywhere)", WHITE, Vector3.new(0, 4.3, 0), 9, 1), "(or press [{Ready}] anywhere)")

	pad.Touched:Connect(function(hit)
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if not player then
			return
		end
		local now = wallNow()
		if readyPadLastTouch[player] and now - readyPadLastTouch[player] < PAD_COOLDOWN then
			return
		end
		readyPadLastTouch[player] = now
		LobbyService.OnReadyPad(player)
	end)
	return ring
end

local function buildAirship(lobby, base)
	local hullColor = Color3.fromRGB(150, 104, 62)
	local trimColor = Color3.fromRGB(200, 160, 80)
	local balloonColor = Color3.fromRGB(196, 60, 72)
	local balloonAlt = Color3.fromRGB(236, 214, 170)
	-- Moored clear of the island: the bow wedge reaches 33 studs forward of the centre, and the
	-- hull hangs a stud below deck level, so its tip stays past the grass rim (r132).
	local center = base + Vector3.new(0, 0, 172)

	-- The hull: a box with a wedge bow and stern, a deck on top, ribs along the sides.
	part(lobby, Vector3.new(18, 5, 46), CFrame.new(center + Vector3.new(0, 1.5, 0)), hullColor, Enum.Material.WoodPlanks)
	wedge(lobby, Vector3.new(18, 5, 10), CFrame.new(center + Vector3.new(0, 1.5, -28)), hullColor, Enum.Material.WoodPlanks)
	wedge(lobby, Vector3.new(18, 5, 8), CFrame.new(center + Vector3.new(0, 1.5, 27)) * CFrame.Angles(0, math.pi, 0), hullColor, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -9.1, 9.1 }) do
		for index = 0, 5 do
			decor(part(lobby, Vector3.new(0.4, 5.2, 0.8), CFrame.new(center + Vector3.new(x, 1.5, -20 + index * 8)), WOOD_DARK, Enum.Material.Wood))
		end
		-- The rail stands clear of BOTH the hull and the ribs it runs over. At 9.1 its faces were
		-- 0.05 from each, which is inside the z-fight pass's reach: fourteen fighting pairs on one
		-- airship, and the pass grew the rail on every build.
		decor(part(lobby, Vector3.new(0.3, 0.6, 46), CFrame.new(center + Vector3.new(x + (x < 0 and -0.12 or 0.12), 3.6, 0)), trimColor, Enum.Material.Foil))
	end
	-- The deck sits inside the hull rather than ending exactly level with it on all four sides.
	local deck = part(lobby, Vector3.new(17.8, 0.6, 45.8), CFrame.new(center + Vector3.new(0, 4.1, 0)), WOOD, Enum.Material.WoodPlanks)
	deck.Name = "AirshipDeck"
	railing(lobby, center + Vector3.new(-8.6, 4.4, -22), center + Vector3.new(-8.6, 4.4, 14), 2.4)
	railing(lobby, center + Vector3.new(8.6, 4.4, -22), center + Vector3.new(8.6, 4.4, 14), 2.4)
	railing(lobby, center + Vector3.new(-8.6, 4.4, -22), center + Vector3.new(8.6, 4.4, -22), 2.4)

	-- The cabin at the stern, with a wheel and windows.
	part(lobby, Vector3.new(14, 8, 10), CFrame.new(center + Vector3.new(0, 8.4, 18)), hullColor:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.WoodPlanks)
	part(lobby, Vector3.new(15, 0.8, 11), CFrame.new(center + Vector3.new(0, 12.8, 18)), WOOD_DARK, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -3.5, 3.5 }) do
		-- 0.07 proud of the sign board behind them (their backs shared its front face).
		local window = decor(part(lobby, Vector3.new(2.4, 2.2, 0.2), CFrame.new(center + Vector3.new(x, 9, 13.02)), Color3.fromRGB(255, 226, 150),
			Enum.Material.Neon))
		pointLight(window, Color3.fromRGB(255, 220, 150), 12, 1)
	end
	local wheel = decor(part(lobby, Vector3.new(0.4, 3.2, 3.2), CFrame.new(center + Vector3.new(0, 6.8, 12)) * CFrame.Angles(0, math.pi / 2, 0),
		WOOD_DARK, Enum.Material.Wood, Enum.PartType.Cylinder))
	-- The wheel stands on a binnacle post from the deck (it used to hang in the air in front of the cabin).
	part(lobby, Vector3.new(0.6, 2.6, 0.5), CFrame.new(center + Vector3.new(0, 5.7, 12.4)), WOOD_DARK, Enum.Material.Wood)
	-- The four spokes cross at the hub, so they can't share one plane: each sits a tenth further
	-- forward than the last, all in front of the wheel's own face. (In one plane, every pair's
	-- faces were coincident where they crossed, and the pass fattened three of them to 0.42, 0.54
	-- and 0.66 studs to pull them apart.)
	for index = 0, 3 do
		decor(part(lobby, Vector3.new(0.3, 4.6, 0.3), CFrame.new(center + Vector3.new(0, 6.8, 11.58 + index * 0.1)) * CFrame.Angles(0, 0, index * math.pi / 4),
			trimColor, Enum.Material.Foil))
	end
	wheel.Name = "ShipWheel"

	-- The balloon: a stretched sphere, banded, with rigging down to the rails.
	local balloon = part(lobby, Vector3.new(30, 26, 74), CFrame.new(center + Vector3.new(0, 36, -2)), balloonColor, Enum.Material.Fabric)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = balloon
	decor(balloon)
	-- The envelope is an ellipsoid, 15 wide, 13 tall and 37 long (half-axes), so everything on it is
	-- fitted to that shape. `envelope(dz)` is its half-width and half-height at `dz` along its length.
	local function envelope(dz)
		local s = math.sqrt(math.max(0, 1 - (dz / 37) ^ 2))
		return 15 * s, 13 * s
	end
	-- Bands: a thin lens of the envelope's own cross-section, a quarter stud bigger, so each wraps
	-- the balloon as a rim. (They were round discs on an oval balloon and stood two studs proud of
	-- its top and bottom.)
	for _, z in ipairs({ -18, 0, 18 }) do
		local halfWidth, halfHeight = envelope(z)
		local band = decor(part(lobby, Vector3.new(halfWidth * 2 + 0.5, halfHeight * 2 + 0.5, 7), CFrame.new(center + Vector3.new(0, 36, z - 2)),
			balloonAlt, Enum.Material.Fabric))
		local bandMesh = Instance.new("SpecialMesh")
		bandMesh.MeshType = Enum.MeshType.Sphere
		bandMesh.Parent = band
	end
	-- Name boards on the flanks: short and thick enough that their back corners sink into the
	-- curve while the lettered face stands clear of it. (Thirty studs long and flat, their ends
	-- stood 1.5 studs off the balloon.)
	for _, side in ipairs({ 1, -1 }) do
		local board = decor(part(lobby, Vector3.new(1.4, 6, 18), CFrame.new(center + Vector3.new(side * 14.8, 36, -2)), balloonAlt, Enum.Material.Fabric))
		surfaceText(board, side > 0 and Enum.NormalId.Right or Enum.NormalId.Left, {
			{ y = 0.05, h = 0.9, text = "ROT EXPRESS", color = balloonColor, stroke = 1 },
		}, 24, 300)
	end
	-- Rigging from the rails up into the envelope's underside. (It stopped at a fixed height,
	-- several studs short of the balloon.)
	for _, x in ipairs({ -8.6, 8.6 }) do
		for _, z in ipairs({ -20, -6, 8 }) do
			local topX, topZ = x * 1.3, z - 1
			local halfWidth, halfHeight = envelope(topZ + 2)
			local reach = halfWidth > 0 and math.sqrt(math.max(0, 1 - (topX / halfWidth) ^ 2)) or 0
			local topY = 36 - halfHeight * reach + 0.4
			decor(beam(lobby, center + Vector3.new(x, 6.5, z), center + Vector3.new(topX, topY, topZ), 0.2, DARK, Enum.Material.Fabric))
		end
	end

	-- Propellers at the stern on shafts out of the hull's stern face, spun locally; a bar through a
	-- hub reads as two blades. (The mounts used to hang in the air over the sloping stern.)
	for _, x in ipairs({ -6, 6 }) do
		part(lobby, Vector3.new(1, 1, 8.4), CFrame.new(center + Vector3.new(x, 2.5, 27)), IRON, Enum.Material.Metal)
		local hub = decor(part(lobby, Vector3.new(1.2, 1.2, 1.2), CFrame.new(center + Vector3.new(x, 2.5, 31.5)), trimColor, Enum.Material.Foil, Enum.PartType.Ball))
		local blade = decor(part(lobby, Vector3.new(7, 0.3, 0.9), CFrame.new(center + Vector3.new(x, 2.5, 31.8)) * CFrame.Angles(math.pi / 2, 0, 0),
			WOOD_DARK, Enum.Material.Wood))
		spin(blade, x < 0 and 420 or -420)
		hub.Name = "PropHub"
	end
	-- A lantern at the bow and a flag at the stern.
	-- The bow lantern sits on the bow rail (it hung in the air seven studs past the deck's end).
	local lantern = decor(part(lobby, Vector3.new(1.2, 1.6, 1.2), CFrame.new(center + Vector3.new(0, 7.4, -22)), GOLD, Enum.Material.Neon))
	pointLight(lantern, GOLD, 24, 1.5)
	part(lobby, Vector3.new(0.3, 6, 0.3), CFrame.new(center + Vector3.new(0, 16, 23)), IRON, Enum.Material.Metal)
	decor(part(lobby, Vector3.new(0.15, 2.2, 3.4), CFrame.new(center + Vector3.new(0, 18, 24.8)), PINK, Enum.Material.Fabric))

	-- The gangway from the pier's end (deck top 0.4) to the hull's bow face (deck top 4.4): its
	-- walking surface runs flush from one to the other, its ends meeting theirs rather than
	-- running into them.
	local from = base + Vector3.new(0, 0.15, 128)
	local to = center + Vector3.new(0, 4.15, -23)
	local ramp = part(lobby, Vector3.new(6, 0.5, (to - from).Magnitude), CFrame.lookAt(from:Lerp(to, 0.5), to), WOOD, Enum.Material.WoodPlanks)
	ramp.Name = "Gangway"
	for _, side in ipairs({ -1, 1 }) do
		decor(beam(lobby, from + Vector3.new(side * 3, 2.45, 0), to + Vector3.new(side * 3, 2.45, 0), 0.3, WOOD_DARK, Enum.Material.Wood))
		part(lobby, Vector3.new(0.4, 2.2, 0.4), CFrame.new(from + Vector3.new(side * 3, 1.35, 0.4)), WOOD_DARK, Enum.Material.Wood)
	end

	-- Boarding sign on the cabin (set a hair into its front face at z 13; it used to hang 0.1 off
	-- it) and the ready pad on the deck.
	local sign = decor(part(lobby, Vector3.new(12, 3, 0.4), CFrame.new(center + Vector3.new(0, 10.5, 12.85)), DARK, Enum.Material.Metal))
	surfaceText(sign, Enum.NormalId.Front, {
		{ y = 0, h = 0.55, text = "NOW BOARDING", color = GREEN },
		{ y = 0.55, h = 0.45, text = "The next drop leaves when the countdown ends", color = WHITE, font = Enum.Font.GothamBold },
	}, 30, 160)
	buildReadyPad(lobby, center + Vector3.new(0, 4.4, -6))
	-- The name over the top of the balloon (whose crown is 49 up). At 24 it sat inside the
	-- envelope's underside, which cut the lettering off.
	billboard(deck, "THE ROT EXPRESS", GOLD, Vector3.new(0, 47.5, -2), 16, 2.4, MatchConfig.LobbySignDistance)
end

--------------------------------------------------------------------------------
-- The Rot Tree and the statue
--------------------------------------------------------------------------------

-- A point { x, y, z, ... } from CloudClimbCourse, relative to the foot of the tree, in the world.
local function at(base, point)
	return base + Vector3.new(point[1], point[2], point[3])
end

-- A cylinder from one point to another.
local function rod(parent, from, to, diameter, color, material)
	local along = to - from
	local up = math.abs(along.Unit.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
	return part(parent, Vector3.new(along.Magnitude, diameter, diameter),
		CFrame.lookAt(from:Lerp(to, 0.5), to, up) * CFrame.Angles(0, math.pi / 2, 0), color, material, Enum.PartType.Cylinder)
end

-- A limb from CloudClimbCourse (the climb's branches, the tree's roots): a cylinder per segment
-- of its centre line (short ones, along a smooth curve) and a ball at each joint, so it bends
-- without seams, plus a rounded end on a live limb.
-- Segments before solidFrom are inside the trunk or the leaves and don't collide. Returns the parts.
local function climbLimb(parent, base, limb, color)
	local parts = {}
	local points = limb.points
	local count = #points - 1
	for k = 1, count do
		local a, b = points[k], points[k + 1]
		local solid = k >= limb.solidFrom
		local diameter = (a[4] + b[4]) / 2
		-- One colour the whole length: shading segment by segment showed every joint as a band.
		local shade = color
		local segment = rod(parent, at(base, a), at(base, b), diameter, shade, Enum.Material.Wood)
		segment.Name = solid and "ClimbBranch" or "BranchScenery"
		table.insert(parts, solid and segment or decor(segment))
		if k > 1 then
			-- A touch wider than the wider segment: any narrower, even exactly as wide, and the
			-- segments' end caps show as a dark seam line round every joint. The bulge is a
			-- hundredth of the limb's width, too small to see or to feel underfoot.
			local size = math.max(diameter, (points[k - 1][4] + a[4]) / 2) * 1.025
			local knuckle = part(parent, Vector3.new(size, size, size), CFrame.new(at(base, a)), shade, Enum.Material.Wood, Enum.PartType.Ball)
			knuckle.Name = segment.Name
			table.insert(parts, solid and knuckle or decor(knuckle))
		end
	end
	if limb.roundTip and count >= 1 then
		local size = (points[count][4] + points[count + 1][4]) / 2
		local tip = part(parent, Vector3.new(size, size, size), CFrame.new(at(base, points[count + 1])), color, Enum.Material.Wood, Enum.PartType.Ball)
		tip.Name = "ClimbBranch"
		table.insert(parts, tip)
	end
	return parts
end

-- Whether a point (relative to the foot of the tree) is within `radius` of the surface of any
-- Cloud Climb limb or of a rotor's sweep, so scenery can keep out of the way of the climb.
local function nearClimb(offset, radius)
	for _, element in ipairs(CloudClimbCourse.elements) do
		for _, limb in ipairs(element.limbs) do
			local points = limb.points
			for k = 1, #points - 1 do
				local a = Vector3.new(points[k][1], points[k][2], points[k][3])
				local ab = Vector3.new(points[k + 1][1], points[k + 1][2], points[k + 1][3]) - a
				local t = math.clamp((offset - a):Dot(ab) / math.max(ab:Dot(ab), 1e-6), 0, 1)
				if (a + ab * t - offset).Magnitude < radius + math.max(points[k][4], points[k + 1][4]) / 2 then
					return true
				end
			end
		end
	end
	for _, rotor in ipairs(CloudClimbCourse.rotors) do
		local hub = Vector3.new(rotor.hub[1], rotor.hub[2], rotor.hub[3])
		local flat = (offset - hub) * Vector3.new(1, 0, 1)
		if flat.Magnitude < rotor.arm + radius and math.abs(offset.Y - hub.Y) < radius + 1 then
			return true
		end
	end
	-- The air every jump flies through (a body's height above the line between its two spots), and
	-- round the summit.
	for _, jump in ipairs(CloudClimbCourse.jumps) do
		local a = Vector3.new(jump.from[1], jump.from[2] + 2.5, jump.from[3])
		local ab = Vector3.new(jump.to[1], jump.to[2] + 2.5, jump.to[3]) - a
		local t = math.clamp((offset - a):Dot(ab) / math.max(ab:Dot(ab), 1e-6), 0, 1)
		if (a + ab * t - offset).Magnitude < radius + 3.5 then
			return true
		end
	end
	if (offset - Vector3.new(0, CloudClimbCourse.summitTop, 0)).Magnitude < radius + CloudClimbCourse.summitDiameter / 2 + 3 then
		return true
	end
	return false
end

-- Balls of leaves: (centre relative to the foot of the tree, diameter). Every one is scenery you
-- fall straight through. The centre ball used to be solid, and a humanoid walks slopes up to 89
-- degrees, so anyone who reached its upper half could stroll up it to the summit past the whole
-- climb. tools/climb_design.py reads this table to keep the course out of the leaves: change it,
-- rerun that.
local CANOPY = {
	{ Vector3.new(0, 84, 0), 60 },
	{ Vector3.new(22, 76, 14), 44 },
	{ Vector3.new(-22, 76, 14), 44 },
	{ Vector3.new(0, 74, -26), 40 },
	{ Vector3.new(16, 90, -8), 32 },
	{ Vector3.new(-16, 92, 6), 30 },
}

local function buildTree(lobby, base)
	-- Roots flare out over the plaza, one down each gap in the bench ring, tapering from the trunk
	-- and diving into the paving; each throws off a smaller rootlet on the way. Their shapes are
	-- CloudClimbCourse's, because their tops are ramps up to the trunk and the course is checked
	-- against them.
	local rootlets = Random.new(31)
	for _, limb in ipairs(CloudClimbCourse.roots) do
		for _, piece in ipairs(climbLimb(lobby, base, limb, BARK)) do
			piece.Name = "Root"
		end
		local points = limb.points
		local middle = points[math.max(limb.solidFrom, math.floor(#points * 0.55))]
		local from = at(base, middle)
		local out = (from - base) * Vector3.new(1, 0, 1)
		local side = Vector3.new(-out.Z, 0, out.X).Unit * (rootlets:NextNumber() < 0.5 and -1 or 1)
		local bend = from + (out.Unit * 1.4 + side * 1.6) - Vector3.new(0, middle[4] * 0.25, 0)
		local tip = bend + (out.Unit * 1.6 + side * 1.2) - Vector3.new(0, 0.9, 0)
		local thick = middle[4] * 0.5
		decor(rod(lobby, from, bend, thick, BARK, Enum.Material.Wood))
		decor(part(lobby, Vector3.one * thick, CFrame.new(bend), BARK, Enum.Material.Wood, Enum.PartType.Ball))
		decor(rod(lobby, bend, tip, thick * 0.6, BARK, Enum.Material.Wood))
	end
	-- The trunk tapers in short stacked lengths, each a sixth of a stud narrower than the one
	-- below. It used to be three lengths with 1-stud ledges at 30 and 56: rings you could walk
	-- round the whole trunk on and jump from onto any branch in reach, which is to say skip the
	-- climb. The sizes are CloudClimbCourse's, which the course was checked against.
	local trunk = CloudClimbCourse.trunk
	local length = trunk.height / trunk.lengths
	for index = 0, trunk.lengths - 1 do
		local radius = trunk.bottomRadius + (trunk.topRadius - trunk.bottomRadius) * index / (trunk.lengths - 1)
		column(lobby, length, radius * 2, base + Vector3.new(0, index * length, 0), BARK, Enum.Material.Wood).Name = "Trunk"
	end
	-- Bark ridges running up the taper, some long, some breaking off partway.
	for index = 0, 9 do
		local angle = index / 10 * math.pi * 2 + (index % 3) * 0.13
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local from = 0.6 + (index % 4) * 3
		local to = trunk.height - 2 - (index % 3) * 9
		local function surface(y)
			return base + out * (trunk.bottomRadius + (trunk.topRadius - trunk.bottomRadius) * y / trunk.height - 0.25) + Vector3.new(0, y, 0)
		end
		decor(beam(lobby, surface(from), surface(to), 1.1, BARK:Lerp(Color3.new(0, 0, 0), 0.22 + (index % 2) * 0.08), Enum.Material.Wood))
	end
	-- Burls: knobbly swellings half sunk in the bark, kept away from where the climb's limbs leave
	-- the trunk.
	local burls = Random.new(7)
	local made = 0
	for _ = 1, 60 do
		if made >= 8 then
			break
		end
		local angle = burls:NextNumber(0, math.pi * 2)
		local y = burls:NextNumber(3, 52)
		local radius = trunk.bottomRadius + (trunk.topRadius - trunk.bottomRadius) * math.floor(y / length) / (trunk.lengths - 1)
		local size = burls:NextNumber(2.4, 3.6)
		-- Sunk most of the way, so a burl swells out of the bark instead of sitting on it.
		local offset = Vector3.new(math.cos(angle) * (radius - size * 0.32), y, math.sin(angle) * (radius - size * 0.32))
		if not nearClimb(offset, 3.5) then
			made += 1
			decor(part(lobby, Vector3.new(size, size, size), CFrame.new(base + offset), BARK:Lerp(Color3.new(0, 0, 0), 0.05), Enum.Material.Wood,
				Enum.PartType.Ball))
		end
	end

	-- The canopy: overlapping balls of leaves, broken up by clumps. Everything in it keeps clear of
	-- the climb: it's scenery, and a clump over a limb you're lining a jump up on, or a blossom sat
	-- on the tip you're aiming for, makes the jump harder to read without making it any more honest.
	local random = Random.new(84)
	for index, ball in ipairs(CANOPY) do
		local leaves = decor(part(lobby, Vector3.new(ball[2], ball[2], ball[2]), CFrame.new(base + ball[1]),
			index % 2 == 0 and LEAF or LEAF:Lerp(Color3.new(1, 1, 1), 0.08), Enum.Material.Grass, Enum.PartType.Ball))
		leaves.Name = "Canopy"
	end
	-- Clumps swelling out of every ball, so the crown has a leafy outline instead of six smooth
	-- spheres: a few shades lighter on top where the sun is, darker underneath.
	local clumps = {}
	for index, ball in ipairs(CANOPY) do
		local radius = ball[2] / 2
		local own = index % 2 == 0 and LEAF or LEAF:Lerp(Color3.new(1, 1, 1), 0.08)
		local wanted = math.floor(radius * 0.9)
		local tries = 0
		while wanted > 0 and tries < wanted * 10 do
			tries += 1
			local direction = Vector3.new(random:NextNumber(-1, 1), random:NextNumber(-0.3, 1), random:NextNumber(-1, 1))
			if direction.Magnitude > 0.2 then
				direction = direction.Unit
				-- Half out of the ball: enough to change its outline, sat close to its own colour so
				-- it reads as more leaves rather than a spot.
				local size = random:NextNumber(0.3, 0.52) * radius
				local centre = ball[1] + direction * (radius - size * 0.06)
				if not nearClimb(centre, size / 2 + 2.5) then
					wanted -= 1
					local shade
					if direction.Y > 0.35 then
						shade = own:Lerp(Color3.fromRGB(150, 205, 96), random:NextNumber(0.04, 0.12))
					elseif direction.Y < -0.05 then
						shade = own:Lerp(Color3.new(0, 0, 0), random:NextNumber(0.06, 0.12))
					else
						shade = own:Lerp(Color3.new(0, 0, 0), random:NextNumber(0, 0.06))
					end
					decor(part(lobby, Vector3.one * size, CFrame.new(base + centre), shade, Enum.Material.Grass, Enum.PartType.Ball)).Name = "CanopyClump"
					table.insert(clumps, { centre = centre, radius = size / 2 })
				end
			end
		end
	end
	-- Then smaller clumps, which fit closer in round the climb than the big ones can, so the leaves
	-- along the route aren't left smooth.
	for _, ball in ipairs(CANOPY) do
		local radius = ball[2] / 2
		local wanted = math.floor(radius * 0.8)
		local tries = 0
		while wanted > 0 and tries < wanted * 10 do
			tries += 1
			local direction = Vector3.new(random:NextNumber(-1, 1), random:NextNumber(-0.5, 1), random:NextNumber(-1, 1))
			if direction.Magnitude > 0.2 then
				direction = direction.Unit
				local size = random:NextNumber(0.13, 0.22) * radius
				local centre = ball[1] + direction * (radius - size * 0.1)
				if not nearClimb(centre, size / 2 + 1.8) then
					wanted -= 1
					local shade = LEAF:Lerp(direction.Y > 0.3 and Color3.fromRGB(150, 205, 96) or Color3.new(0, 0, 0), random:NextNumber(0.02, 0.1))
					decor(part(lobby, Vector3.one * size, CFrame.new(base + centre), shade, Enum.Material.Grass, Enum.PartType.Ball)).Name = "CanopyClump"
					table.insert(clumps, { centre = centre, radius = size / 2 })
				end
			end
		end
	end
	-- Blossom on the clumps and the balls.
	local placed, attempts = 0, 0
	while placed < 40 and attempts < 400 do
		attempts += 1
		local host
		if #clumps > 0 and random:NextNumber() < 0.6 then
			host = clumps[random:NextInteger(1, #clumps)]
		else
			local ball = CANOPY[random:NextInteger(1, #CANOPY)]
			host = { centre = ball[1], radius = ball[2] / 2 }
		end
		local direction = Vector3.new(random:NextNumber(-1, 1), random:NextNumber(-0.1, 1), random:NextNumber(-1, 1)).Unit
		local offset = host.centre + direction * (host.radius + 0.3)
		if not nearClimb(offset, 4) then
			placed += 1
			local blossom = decor(part(lobby, Vector3.one * random:NextNumber(1.1, 1.7), CFrame.new(base + offset), placed % 3 == 0 and GOLD or PINK,
				Enum.Material.Neon, Enum.PartType.Ball))
			if placed % 6 == 0 then
				pointLight(blossom, blossom.Color, 12, 0.7)
			end
		end
	end
	-- Vines hanging from the underside of the leaves: jointed, a little crooked, leafing as they go.
	local vines = 0
	for _ = 1, 80 do
		if vines >= 16 then
			break
		end
		local ball = CANOPY[random:NextInteger(1, #CANOPY)]
		local angle = random:NextNumber(0, math.pi * 2)
		local spread = random:NextNumber(0.25, 0.6) * ball[2] / 2
		local lip = ball[1] + Vector3.new(math.cos(angle) * spread, 0, math.sin(angle) * spread)
		local depth = math.sqrt(math.max(0, (ball[2] / 2) ^ 2 - spread * spread))
		local top = lip - Vector3.new(0, depth - 1, 0)
		local length = random:NextNumber(8, 15)
		if not nearClimb(top - Vector3.new(0, length / 2, 0), length / 2 + 3) then
			vines += 1
			local from = top
			local links = 4
			for link = 1, links do
				local to = from + Vector3.new(random:NextNumber(-0.6, 0.6), -length / links, random:NextNumber(-0.6, 0.6))
				decor(rod(lobby, base + from, base + to, 0.3 - link * 0.03, LEAF:Lerp(Color3.new(0, 0, 0), 0.3), Enum.Material.Grass))
				decor(part(lobby, Vector3.one * random:NextNumber(0.7, 1.1), CFrame.new(base + to + Vector3.new(random:NextNumber(-0.4, 0.4), 0.3, random:NextNumber(-0.4, 0.4))),
					LEAF:Lerp(Color3.new(0, 0, 0), random:NextNumber(0.05, 0.2)), Enum.Material.Grass, Enum.PartType.Ball))
				from = to
			end
		end
	end

	-- A bench ring round the trunk, facing out across the plaza rather than in at the bark, and
	-- you can actually sit on them: the frame is turned to look away from the trunk, which puts
	-- the backrest against the tree where it belongs.
	for index = 0, 7 do
		local angle = index / 8 * math.pi * 2 + math.pi / 8
		local position = base + Vector3.new(math.cos(angle) * 15, 0, math.sin(angle) * 15)
		local look = CFrame.lookAt(position, Vector3.new(base.X, position.Y, base.Z)) * CFrame.Angles(0, math.pi, 0)
		seat(lobby, Vector3.new(7, 0.5, 1.8), look * CFrame.new(0, 1.6, 0), WOOD, Enum.Material.WoodPlanks)
		part(lobby, Vector3.new(7, 1.6, 0.4), look * CFrame.new(0, 2.6, 0.9), WOOD, Enum.Material.WoodPlanks)
		for _, x in ipairs({ -2.8, 2.8 }) do
			part(lobby, Vector3.new(0.5, 1.4, 1.6), look * CFrame.new(x, 0.7, 0), IRON, Enum.Material.Metal)
		end
	end
end

-- The golden Sahur on a plinth in front of the tree, turning slowly.
local function buildStatue(lobby, base)
	local center = base + Vector3.new(0, 0, 30)
	disc(lobby, 14, 2, center, PLAZA_DARK, Enum.Material.Marble)
	disc(lobby, 10, 2, center + Vector3.new(0, 2, 0), STONE, Enum.Material.Marble)
	decor(disc(lobby, 10.6, 0.3, center + Vector3.new(0, 4, 0), GOLD, Enum.Material.Neon))
	local def = BrainrotData.Get("Golden Sahur") or BrainrotData.Types[#BrainrotData.Types]
	if def then
		local scale = 1.6
		local size = def.look and def.look.size or 1
		local metrics = BrainrotModels.Metrics(def)
		local foot = center + Vector3.new(0, 4.2 - metrics.bottom * scale * size, 0)
		local statue = BrainrotModels.Build(def, { scale = scale, glow = GOLD, cframe = CFrame.lookAt(foot, Vector3.new(base.X, foot.Y, base.Z + 200)) })
		statue.Name = "Statue"
		statue.Parent = lobby
		local plate = decor(part(lobby, Vector3.new(6, 1.6, 0.3), CFrame.new(center + Vector3.new(0, 2.8, 5.2)), DARK, Enum.Material.Metal))
		surfaceText(plate, Enum.NormalId.Front, {
			{ y = 0, h = 0.6, text = def.name, color = GOLD },
			{ y = 0.6, h = 0.4, text = "The one they all want", color = WHITE, font = Enum.Font.GothamBold },
		}, 40, 80)
	end
	pointLight(disc(lobby, 1, 0.2, center + Vector3.new(0, 4.3, 0), GOLD, Enum.Material.Neon), GOLD, 30, 2)
end

--------------------------------------------------------------------------------
-- Market Row
--------------------------------------------------------------------------------

-- A market stall facing the plaza: a plank floor, posts, a striped awning, a counter, string
-- lights along the front and a hanging name. Returns the frame (-Z toward the plaza) and its
-- centre.
local function buildStall(lobby, base, degrees, name, color, width)
	width = width or 14
	local center = spot(base, degrees, STALL_RADIUS)
	local look = facingCentre(center, base)
	-- The floor, then everything standing on it (from 0.6 up), the side panels running between
	-- the posts and the back wall a clear step inside the posts' backs: nothing flush.
	part(lobby, Vector3.new(width, 0.6, 10), look * CFrame.new(0, 0.3, 0), WOOD, Enum.Material.WoodPlanks)
	-- The awning slopes up from the front edge to past the back wall, and the posts and back wall
	-- run up into it, so it is held up and closes the stall over. (It used to stop 1.9 studs short
	-- of the back wall, leaving a strip of open sky across the stall, and it floated clear of the
	-- post tops.) `awningUnderside(z)` is the height of its underside above the floor's base.
	-- The front edge is 10.3 up: high enough that the mannequin's head and whatever it wears show
	-- under it from the plaza (at 8.8 the awning and its sign hid everything above the shoulders).
	local AWNING_SLOPE = 0.18
	local AWNING_HEIGHT = 10.5
	local awningFront, awningBack = -5.7, 4.95
	local function awningUnderside(z)
		return AWNING_HEIGHT + (z + 4.5) * math.tan(AWNING_SLOPE)
	end
	for _, x in ipairs({ -width / 2 + 0.5, width / 2 - 0.5 }) do
		for _, z in ipairs({ -4.5, 4.5 }) do
			local top = awningUnderside(z) + (z < 0 and 0.12 or 0.2)
			part(lobby, Vector3.new(0.7, top - 0.6, 0.7), look * CFrame.new(x, (top + 0.6) / 2, z), WOOD_DARK, Enum.Material.Wood)
		end
	end
	-- Back wall and side panels.
	local wallTop = awningUnderside(4.75) + 0.04
	-- Down into the floor like the side panels, so its underside isn't the rear posts'.
	part(lobby, Vector3.new(width - 1.4, wallTop - 0.4, 0.4), look * CFrame.new(0, (wallTop + 0.4) / 2, 4.55), WOOD, Enum.Material.WoodPlanks)
	-- The side panels run down INTO the floor rather than starting on the posts' own base plane:
	-- both began at 0.6 and each panel overlaps the post beside it, so their undersides were flush.
	for _, x in ipairs({ -width / 2 + 0.5, width / 2 - 0.5 }) do
		part(lobby, Vector3.new(0.4, 4.2, 9), look * CFrame.new(x, 2.5, 0), WOOD, Enum.Material.WoodPlanks)
	end
	-- The counter across the front.
	part(lobby, Vector3.new(width - 2, 3, 1.6), look * CFrame.new(0, 2.1, -4), WOOD_DARK, Enum.Material.WoodPlanks)
	part(lobby, Vector3.new(width - 1.6, 0.3, 2), look * CFrame.new(0, 3.7, -4), WOOD, Enum.Material.WoodPlanks)
	-- The awning: sloping stripes, front edge scalloped with bulbs.
	-- Neighbouring stripes overlap a hair so no sky shows between them; the coloured ones are
	-- thicker, so where they overlap the two surfaces are on different planes.
	-- Every stripe shares the thick stripes' centre plane; the edge stripes (over the posts) are thick.
	local stripes = math.floor(width / 2)
	local awningLength = (awningBack - awningFront) / math.cos(AWNING_SLOPE)
	local awningMid = (awningFront + awningBack) / 2
	local awningCentre = awningUnderside(awningMid) + 0.185 / math.cos(AWNING_SLOPE)
	for index = 0, stripes - 1 do
		local x = -width / 2 + (index + 0.5) * width / stripes
		-- The thin stripes are 0.07 shorter at each end: neighbours overlap in width on purpose, so
		-- with equal lengths every pair's end faces shared a plane.
		decor(part(lobby, Vector3.new(width / stripes + 0.05, index % 2 == 0 and 0.37 or 0.25, awningLength - (index % 2 == 0 and 0 or 0.14)),
			look * CFrame.new(x, awningCentre, awningMid) * CFrame.Angles(-AWNING_SLOPE, 0, 0),
			index % 2 == 0 and color or WHITE, Enum.Material.Fabric))
	end
	for index = 0, stripes do
		local x = -width / 2 + index * width / stripes
		local bulb = decor(part(lobby, Vector3.new(0.5, 0.5, 0.5), look * CFrame.new(x, awningUnderside(-5.6), -5.6), index % 2 == 0 and GOLD or color,
			Enum.Material.Neon, Enum.PartType.Ball))
		if index % 3 == 0 then
			pointLight(bulb, bulb.Color, 10, 0.7)
		end
	end
	-- The name board stands on the awning's front edge, its foot set into the fabric, clear of the
	-- bulbs. (It used to hang in the stall's opening, in front of whatever the stall shows.)
	local sign = decor(part(lobby, Vector3.new(width * 0.7, 2.5, 0.3), look * CFrame.new(0, AWNING_HEIGHT + 1.25, -5.15), DARK, Enum.Material.Metal))
	surfaceText(sign, Enum.NormalId.Front, {
		{ y = 0.03, h = 0.78, text = name, color = color },
	}, 40, MatchConfig.LobbySignDistance)
	pointLight(sign, color, 18, 1)
	return look, center
end

-- A prompt that opens the player's menu on a tab.
local function tabPrompt(parent, action, object, tab)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	prompt.Triggered:Connect(function(player)
		openMenuTab:FireClient(player, tab)
	end)
	return prompt
end

-- The Trading Hall: a stone hall with an open colonnaded front, a long table down the middle
-- with stools, a counter at the back with the trade board, banners and lanterns. Walk in and
-- use the counter to open the trade board.
local function buildTradingHall(lobby, base)
	local center = spot(base, 225, 88)
	local look = facingCentre(center, base)
	local stone = Color3.fromRGB(196, 186, 168)
	local dark = Color3.fromRGB(120, 112, 100)
	local width, depth = 34, 24

	-- Floor, back and side walls, a plinth step at the front.
	part(lobby, Vector3.new(width, 1, depth), look * CFrame.new(0, 0.5, 0), dark, Enum.Material.Marble)
	part(lobby, Vector3.new(width + 4, 0.6, 4), look * CFrame.new(0, 0.3, -depth / 2 - 2), PLAZA_DARK, Enum.Material.Marble)
	-- The walls run up into the roof slab (its underside is at 16.4). They used to stop at 15, which
	-- left a 1.4-stud slit of sky all round under the roof on three sides.
	part(lobby, Vector3.new(width, 15.7, 1.2), look * CFrame.new(0, 8.85, depth / 2), stone, Enum.Material.Marble)
	for _, side in ipairs({ -1, 1 }) do
		-- The side walls stop AT the back wall rather than running through it: where two walls
		-- overlap in a corner they share their tops and their undersides, which is four pairs of
		-- faces in one plane for the pass to find.
		part(lobby, Vector3.new(1.2, 15.7, depth - 0.6), look * CFrame.new(side * width / 2, 8.85, -0.3), stone, Enum.Material.Marble)
		-- Arched windows in the side walls: a lit pane with a round head. The head is a full disc
		-- the pane's width centred on its top edge, a little thinner so its faces sit inside the
		-- pane's; it used to be a small circle on top, which read as a person's head and shoulders.
		for _, z in ipairs({ -6, 4 }) do
			decor(part(lobby, Vector3.new(0.4, 5, 3.6), look * CFrame.new(side * (width / 2 + 0.5), 8, z), Color3.fromRGB(255, 226, 170), Enum.Material.Neon))
			-- Thicker than the pane, not thinner: at 0.28 the head's outer face sat 0.04 proud of the
			-- wall's, inside the pass's tolerance; at 0.54 it stands 0.07 proud of the pane's face
			-- and 0.07 inside it at the back.
			decor(part(lobby, Vector3.new(0.54, 3.6, 3.6), look * CFrame.new(side * (width / 2 + 0.5), 10.5, z), Color3.fromRGB(255, 226, 170), Enum.Material.Neon,
				Enum.PartType.Cylinder))
		end
	end
	-- The open front: four columns holding the lintel, the roof over the lot.
	for _, x in ipairs({ -width / 2 + 1, -width / 6, width / 6, width / 2 - 1 }) do
		-- From 0.1 inside the floor: the corner columns overlap the side walls' ends in plan, and
		-- standing on the floor's top their undersides lay in the walls'.
		column(lobby, 13.1, 1.8, (look * CFrame.new(x, 0.9, -depth / 2 + 1)).Position, stone, Enum.Material.Marble)
		part(lobby, Vector3.new(2.6, 1, 2.6), look * CFrame.new(x, 14.5, -depth / 2 + 1), stone, Enum.Material.Marble)
	end
	part(lobby, Vector3.new(width + 1, 1.6, 2.4), look * CFrame.new(0, 15.8, -depth / 2 + 1), stone, Enum.Material.Marble)
	part(lobby, Vector3.new(width + 3, 1, depth + 3), look * CFrame.new(0, 16.9, 0), dark, Enum.Material.Slate)
	wedge(lobby, Vector3.new(width + 3, 6, (depth + 3) / 2), look * CFrame.new(0, 20.4, -(depth + 3) / 4) * CFrame.Angles(0, 0, 0), Color3.fromRGB(70, 60, 56), Enum.Material.Slate)
	wedge(lobby, Vector3.new(width + 3, 6, (depth + 3) / 2), look * CFrame.new(0, 20.4, (depth + 3) / 4) * CFrame.Angles(0, math.pi, 0), Color3.fromRGB(70, 60, 56), Enum.Material.Slate)
	local sign = decor(part(lobby, Vector3.new(18, 3, 0.4), look * CFrame.new(0, 19.5, -depth / 2 - 1.2), DARK, Enum.Material.Metal))
	-- Two brackets from the roof slab up into the sign's foot. (It stood half a stud clear of the
	-- roof's slope, on nothing.) Narrower than the sign front to back, so no face lies on its faces.
	for _, x in ipairs({ -6, 6 }) do
		decor(part(lobby, Vector3.new(0.4, 1, 0.2), look * CFrame.new(x, 17.7, -depth / 2 - 1.2), IRON, Enum.Material.Metal))
	end
	surfaceText(sign, Enum.NormalId.Front, { { y = 0.05, h = 0.9, text = "TRADING HALL", color = GOLD } }, 30, MatchConfig.LobbySignDistance)
	pointLight(sign, GOLD, 30, 1.4)

	-- The long table with stools, and a rug under it.
	decor(part(lobby, Vector3.new(16, 0.15, 12), look * CFrame.new(0, 1.08, -1), Color3.fromRGB(120, 40, 50), Enum.Material.Fabric))
	part(lobby, Vector3.new(14, 0.6, 5), look * CFrame.new(0, 3.3, -1), WOOD, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -6, 6 }) do
		-- Legs from 0.1 inside the floor to the table's underside (they used to reach the floor's
		-- own underside).
		part(lobby, Vector3.new(0.7, 2.1, 4), look * CFrame.new(x, 1.95, -1), WOOD_DARK, Enum.Material.Wood)
	end
	-- Stools you can actually sit on: a turned wooden leg with a Seat for its top, so walking into
	-- one sits you at the table. The floor's top is y = 1 and the table's is 3.6.
	-- A Seat faces its occupant along the part's own -Z, so the seat's orientation is the sitting
	-- direction and cannot be chosen for the shape's convenience. These stools used to be
	-- cylinders, and a cylinder only lies flat if the part is turned on its side, which turned the
	-- sitting direction with it and sat everyone sideways. Flat pads instead, each turned to face
	-- the table.
	for _, z in ipairs({ -4.6, 2.6 }) do
		local facing = z < -1 and math.pi or 0
		for _, x in ipairs({ -4.5, 0, 4.5 }) do
			local foot = (look * CFrame.new(x, 1, z)).Position
			column(lobby, 1.6, 1.1, foot - Vector3.new(0, 0.1, 0), WOOD_DARK, Enum.Material.Wood)
			seat(lobby, Vector3.new(2.2, 0.5, 2.2), look * CFrame.new(x, 2.75, z) * CFrame.Angles(0, facing, 0),
				WOOD, Enum.Material.WoodPlanks)
		end
	end
	-- Benches down both side walls. The frame is turned a quarter so the bench runs along the wall
	-- and the sitter faces into the room; left unturned, its length lay along -Z and everyone sat
	-- facing down the bench instead of across it.
	for _, side in ipairs({ -1, 1 }) do
		local bench = look * CFrame.new(side * (width / 2 - 3.4), 1, 1) * CFrame.Angles(0, side * math.pi / 2, 0)
		part(lobby, Vector3.new(9, 1.4, 1.6), bench * CFrame.new(0, 0.7, 0), WOOD_DARK, Enum.Material.Wood)
		seat(lobby, Vector3.new(9, 0.5, 2.6), bench * CFrame.new(0, 1.65, 0), WOOD, Enum.Material.WoodPlanks)
		-- The backrest stands on the seat's back edge (it used to stand just past it, on nothing).
		part(lobby, Vector3.new(9, 2.6, 0.4), bench * CFrame.new(0, 3.2, 1), WOOD, Enum.Material.WoodPlanks)
	end
	-- Trade tokens turning on the table.
	for index, x in ipairs({ -4, 0, 4 }) do
		local token = decor(part(lobby, Vector3.new(0.3, 1.4, 1.4), look * CFrame.new(x, 4.4, -1) * CFrame.Angles(0, 0, math.pi / 2),
			index == 2 and GOLD or SKY, Enum.Material.Neon, Enum.PartType.Cylinder))
		token:SetAttribute("IntentionalFloat", true)
		spin(token, 40 + index * 15)
	end

	-- The counter and the trade board at the back.
	local counter = part(lobby, Vector3.new(16, 3.4, 2), look * CFrame.new(0, 2.7, depth / 2 - 3), WOOD_DARK, Enum.Material.WoodPlanks)
	counter.Name = "TradeCounter"
	part(lobby, Vector3.new(16.4, 0.3, 2.4), look * CFrame.new(0, 4.5, depth / 2 - 3), WOOD, Enum.Material.WoodPlanks)
	local board = decor(part(lobby, Vector3.new(16, 6, 0.4), look * CFrame.new(0, 9.5, depth / 2 - 0.7), DARK, Enum.Material.Metal))
	surfaceText(board, Enum.NormalId.Front, {
		{ y = 0.02, h = 0.34, text = "TRADE BOARD", color = GOLD },
		{ y = 0.38, h = 0.2, text = "Offer up to 6 brainrots each way; both sides confirm.", color = WHITE, font = Enum.Font.GothamBold },
		{ y = 0.6, h = 0.2, text = "Nothing changes hands until you both agree.", color = WHITE, font = Enum.Font.GothamBold },
		{ y = 0.8, h = 0.18, text = "Use the counter to open the board", color = MUTED, font = Enum.Font.Gotham },
	}, 30)
	pointLight(board, GOLD, 20, 1)
	tabPrompt(counter, "Open", "Trade Board", "Trade")

	-- Banners hung from the back of the lintel between the columns, and lanterns mounted on the
	-- walls. (The banners used to hang in mid-air a stud under the lintel, and the lanterns floated
	-- half a stud off the walls.)
	for _, x in ipairs({ -width / 3, 0, width / 3 }) do
		decor(part(lobby, Vector3.new(3, 8, 0.2), look * CFrame.new(x, 11.1, -depth / 2 + 2.2), x == 0 and GOLD or Color3.fromRGB(120, 40, 50), Enum.Material.Fabric))
	end
	for _, side in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -8, 0, 8 }) do
			local lantern = decor(part(lobby, Vector3.new(1, 1.4, 1), look * CFrame.new(side * (width / 2 - 1.05), 10, z), GOLD, Enum.Material.Neon))
			pointLight(lantern, Color3.fromRGB(255, 220, 160), 16, 1)
		end
	end
	-- Crates of goods in the corners: two on the floor's top (they used to reach the floor's own
	-- underside), the third stacked on one and turned a little further, so no side of it lies in a
	-- side of the one beneath (stacked square, three pairs of faces shared a plane).
	for index, corner in ipairs({ Vector3.new(-width / 2 + 3, 2.5, depth / 2 - 3), Vector3.new(width / 2 - 3, 2.5, depth / 2 - 3), Vector3.new(width / 2 - 3, 5.5, depth / 2 - 3) }) do
		part(lobby, Vector3.new(3, 3, 3), look * CFrame.new(corner) * CFrame.Angles(0, index == 3 and 0.55 or 0.3, 0), WOOD, Enum.Material.WoodPlanks)
	end
end

-- The featured accessory of the day on a mannequin, turning on the counter of its stall.
local function buildCosmeticsStall(lobby, base)
	local look = buildStall(lobby, base, 250, "COSMETICS", PINK)
	local accessories = CosmeticData.OfKind("Accessory", true)
	if #accessories == 0 then
		return
	end
	local featured = CosmeticData.Get(accessories[(math.floor(os.time() / 86400) % #accessories) + 1])
	local plastic = Color3.fromRGB(236, 234, 228)

	local turntable = decor(disc(lobby, 5, 0.4, (look * CFrame.new(0, 0.6, 0)).Position, PINK, Enum.Material.Neon))
	local mannequin = Instance.new("Model")
	mannequin.Name = "Mannequin"
	local stand = look * CFrame.new(0, 1, 0)
	local function limb(name, size, offset, shape)
		local piece = Instance.new("Part")
		piece.Name = name
		if shape then
			piece.Shape = shape
		end
		piece.Size = size
		piece.CFrame = stand * CFrame.new(offset)
		piece.Color = plastic
		piece.Material = Enum.Material.SmoothPlastic
		piece.Anchored = true
		piece.TopSurface = Enum.SurfaceType.Smooth
		piece.BottomSurface = Enum.SurfaceType.Smooth
		piece.Parent = mannequin
		return piece
	end
	for _, x in ipairs({ -0.5, 0.5 }) do
		limb("Leg", Vector3.new(0.9, 3, 0.9), Vector3.new(x, 1.5, 0))
		-- Arms against the torso's sides (at 1.45 out they stood 0.05 clear of it).
		limb("Arm", Vector3.new(0.8, 2.8, 0.8), Vector3.new(x * 2.76, 4.3, 0))
	end
	limb("LowerTorso", Vector3.new(2, 0.8, 1), Vector3.new(0, 3.4, 0))
	limb("UpperTorso", Vector3.new(2, 1.8, 1), Vector3.new(0, 4.7, 0))
	limb("Neck", Vector3.new(0.5, 0.4, 0.5), Vector3.new(0, 5.8, 0))
	limb("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 6.6, 0), Enum.PartType.Ball)
	AccessoryService.Attach(mannequin, featured.id)
	mannequin.Parent = lobby
	pointLight(turntable, PINK, 14, 1)

	-- What's on the mannequin, on a board across the counter's front at eye height. (It used to be
	-- three floating labels over the mannequin's head, which covered the accessory being shown and
	-- ran up through the awning.)
	local board = decor(part(lobby, Vector3.new(10, 2.5, 0.16), look * CFrame.new(0, 2.15, -4.88), DARK, Enum.Material.Metal))
	surfaceText(board, Enum.NormalId.Front, {
		{ y = 0.04, h = 0.34, text = "FEATURED TODAY", color = PINK },
		{ y = 0.4, h = 0.32, text = string.format("%s  •  %d C", featured.name, featured.price or 0), color = Rarity.Color(featured.rarity) },
		{ y = 0.76, h = 0.2, text = "Use the counter to browse", color = WHITE, font = Enum.Font.GothamBold },
	}, 40, MatchConfig.LobbyLabelDistance)
	local counter = part(lobby, Vector3.new(4, 0.4, 1.6), look * CFrame.new(0, 3.95, -4), PINK, Enum.Material.Neon)
	tabPrompt(counter, "Browse", "Cosmetics", "Cosmetics")
end

--------------------------------------------------------------------------------
-- The Crate Altar
--
-- Whatever anyone in the server pulls from a crate appears here for a few seconds — the
-- brainrot itself, or a gem in the cosmetic's colour — turning under the lights with their name
-- over it and a burst of confetti. Pulls queue up; a Legendary or better gets longer and louder.
--------------------------------------------------------------------------------

local STAGE_TIME = 7
local STAGE_TIME_BIG = 10
local STAGE_QUEUE_LIMIT = 6

local stageQueue = {}
local stagePresenting = false
local stageSpot = nil
local stageTitle, stageSubtitle = nil, nil
local stageFolder = nil
local stageIdleProp = nil

local function ensureStageFolder()
	if stageFolder and stageFolder.Parent then
		return stageFolder
	end
	local existing = workspace:FindFirstChild("StageDisplay")
	if existing then
		existing:Destroy()
	end
	stageFolder = Instance.new("Folder")
	stageFolder.Name = "StageDisplay"
	stageFolder.Parent = workspace
	return stageFolder
end

-- An invisible base at `position` that AmbientClient turns, with everything under it.
local function newDisplay(position)
	local display = Instance.new("Part")
	display.Name = "Display"
	display.Size = Vector3.new(1, 1, 1)
	display.Transparency = 1
	display.Anchored = true
	display.CanCollide = false
	display.CanQuery = false
	display.CanTouch = false
	display.CFrame = CFrame.new(position)
	return display
end

local function displayPart(display, size, cframe, color, material, shape, transparency)
	local piece = Instance.new("Part")
	if shape then
		piece.Shape = shape
	end
	piece.Size = size
	piece.CFrame = cframe
	piece.Color = color
	piece.Material = material
	piece.Transparency = transparency or 0
	piece.Anchored = true
	piece.CanCollide = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.Parent = display
	return piece
end

-- The crate that sits on the altar between pulls: the same CrateModels crate the menu opens, in
-- a tier that changes with the day, turning on the stage like a pull does.
local IDLE_TIERS = { "Rare", "Epic", "Legendary", "Mythic" }

local function buildIdleProp()
	local display = newDisplay(stageSpot + Vector3.new(0, 2.5, 0))
	local tier = IDLE_TIERS[(math.floor(os.time() / 86400) % #IDLE_TIERS) + 1]
	local model = CrateModels.Crate(tier, { scale = 1.15 })
	model:PivotTo(CFrame.new(stageSpot) * CFrame.Angles(0, math.pi, 0))
	for _, piece in ipairs(model:GetDescendants()) do
		if piece:IsA("BasePart") then
			piece.Parent = display
		end
	end
	model:Destroy()
	display.Parent = ensureStageFolder()
	return display
end

local function buildCrateAltar(lobby, base)
	local center = spot(base, 270, 84)
	local look = facingCentre(center, base)
	local plum = Color3.fromRGB(58, 34, 78)

	-- A round dais up three steps, four pillars round it and a ring of lights over the top.
	for index, size in ipairs({ 26, 21, 16 }) do
		disc(lobby, size, 1, center + Vector3.new(0, (index - 1), 0), index % 2 == 0 and PLAZA_DARK or plum, Enum.Material.Marble)
	end
	decor(disc(lobby, 16.6, 0.3, center + Vector3.new(0, 3, 0), PINK, Enum.Material.Neon))
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + math.pi / 4
		local foot = center + Vector3.new(math.cos(angle) * 11, 0, math.sin(angle) * 11)
		-- Standing on the plinth's top, not reaching down to its underside (a coincident pair each).
		column(lobby, 14.9, 2, foot + Vector3.new(0, 1.1, 0), STONE, Enum.Material.Marble)
		part(lobby, Vector3.new(3, 1, 3), CFrame.new(foot + Vector3.new(0, 16.5, 0)), STONE, Enum.Material.Marble)
	end
	for index = 0, 15 do
		local angle = index / 16 * math.pi * 2
		-- The ring rests on the pillar caps (tops at 17); it used to hover 0.15 above them. Alternate
		-- segments sit a little higher: each is 4.5 long against a 4.32 gap round the ring, so
		-- neighbours overlap, and turning a segment about the ring doesn't turn its top or bottom —
		-- all sixteen shared two planes and the z-fight pass spread every one of them.
		local position = center + Vector3.new(math.cos(angle) * 11, 16.9 + (index % 2) * 0.08, math.sin(angle) * 11)
		local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		decor(part(lobby, Vector3.new(0.5, 0.5, 4.5), CFrame.lookAt(position, position + tangent), IRON, Enum.Material.Metal))
		local fixture = decor(part(lobby, Vector3.new(0.9, 0.9, 0.9), CFrame.new(position - Vector3.new(0, 0.7, 0)), index % 2 == 0 and PINK or GOLD,
			Enum.Material.Neon))
		if index % 4 == 0 then
			local spotLight = Instance.new("SpotLight")
			spotLight.Face = Enum.NormalId.Bottom
			spotLight.Angle = 60
			spotLight.Range = 24
			spotLight.Brightness = 2.5
			spotLight.Color = fixture.Color
			spotLight.Parent = fixture
		end
	end
	-- Picking a crate is one console at the front of the dais: a lit key per tier on a tilted
	-- panel, instead of a shelf of crate models. The call behind each key is unchanged — the
	-- crate itself is what turns on the stage when you pull.
	local tiers = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Super" }
	local deskAt = look * CFrame.new(0, 0, -14.5)
	part(lobby, Vector3.new(17, 3, 3), deskAt * CFrame.new(0, 1.5, 0), PLAZA_DARK, Enum.Material.Marble)
	decor(part(lobby, Vector3.new(17.4, 0.3, 3.4), deskAt * CFrame.new(0, 3.15, 0), PINK, Enum.Material.Neon))
	-- The keys sit on a face tilted back toward whoever walks up to it. A SurfaceGui on a Top face
	-- reads with its up along the part's -X, so the panel and keys are turned a quarter about their
	-- own Y (lengths swapped to match): their -X then runs up the slope, away from the player, and the
	-- key letters read upright from the front. (Unturned, every key's letters and the panel's title
	-- ran sideways, and the title was squeezed into the panel's 2.6-stud depth.)
	local faceAt = deskAt * CFrame.new(0, 3.9, 0.35) * CFrame.Angles(math.rad(-32), 0, 0)
	local quarter = CFrame.Angles(0, math.pi / 2, 0)
	part(lobby, Vector3.new(2.6, 0.4, 16.2), faceAt * quarter, DARK, Enum.Material.Metal)
	-- Words go on the desk's front, which faces the player: the title, and each tier's name on a plate
	-- under its key. (Seven 5-stud billboards 2.3 studs apart over the keys ran into one another.)
	-- A player in front has the desk's +X on their left, so the keys run Common to Super left to right.
	local title = decor(part(lobby, Vector3.new(12, 1.3, 0.08), deskAt * CFrame.new(0, 1.1, -1.54), DARK, Enum.Material.Metal))
	surfaceText(title, Enum.NormalId.Front, { { y = 0.08, h = 0.84, text = "PICK A CRATE", color = GOLD } }, 40)
	for index, tier in ipairs(tiers) do
		local crateDef = CrateData.Get(tier)
		local color = crateDef and (crateDef.color or Rarity.Color(tier)) or GOLD
		local x = 6.9 - (index - 1) * 2.3
		local key = part(lobby, Vector3.new(1.7, 0.35, 1.9), faceAt * CFrame.new(x, 0.35, 0) * quarter, color, Enum.Material.Neon)
		key.Name = "CrateKey_" .. tier
		surfaceText(key, Enum.NormalId.Top, { { y = 0.1, h = 0.8, text = string.sub(tier, 1, 3), color = DARK, font = Enum.Font.GothamBlack } }, 60)
		local plate = decor(part(lobby, Vector3.new(2.1, 0.6, 0.08), deskAt * CFrame.new(x, 2.45, -1.54), DARK, Enum.Material.Metal))
		surfaceText(plate, Enum.NormalId.Front, { { y = 0.1, h = 0.8, text = string.upper(tier), color = color } }, 60)

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Open one"
		prompt.ObjectText = (crateDef and crateDef.name or tier) .. "s"
		prompt.HoldDuration = 0.3
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = key
		prompt.Triggered:Connect(function(player)
			local ok, message = LobbyService.OnAltarOpen(player, tier)
			StateSync.Notify(player, message or (ok and "Opened." or "Couldn't open that."), not ok)
		end)
	end

	local header = decor(part(lobby, Vector3.new(1, 1, 1), CFrame.new(center + Vector3.new(0, 19, 0)), plum, Enum.Material.SmoothPlastic))
	header.Transparency = 1
	billboard(header, "CRATE ALTAR", GOLD, Vector3.new(0, 2.6, 0), 12, 2, MatchConfig.LobbySignDistance)
	-- Two short lines rather than one long one, which scaled down to text too small to read.
	billboard(header, "Open your crates at the console", WHITE, Vector3.new(0, 1.2, 0), 13, 1)
	billboard(header, "Everyone in the lobby sees the pull", WHITE, Vector3.new(0, 0.15, 0), 13, 0.9)

	-- The pull's name floats over the altar; readable from across the plaza.
	local anchor = decor(part(lobby, Vector3.new(1, 1, 1), CFrame.new(center + Vector3.new(0, 12.5, 0)), plum, Enum.Material.SmoothPlastic))
	anchor.Transparency = 1
	stageTitle = billboard(anchor, "", GOLD, Vector3.new(0, 1.2, 0), 18, 2.2, 160)
	stageSubtitle = billboard(anchor, "", WHITE, Vector3.new(0, -0.5, 0), 16, 1.2, 160)

	stageSpot = center + Vector3.new(0, 3, 0)
	ensureStageFolder()
	stageIdleProp = buildIdleProp()
end

local function presentQueue()
	while #stageQueue > 0 do
		local show = table.remove(stageQueue, 1)
		local player, result = show.player, show.result
		if stageSpot and player.Parent then
			local rarity = result.rarity or "Common"
			local color = Rarity.Color(rarity)
			local big = (Rarity.Index[rarity] or 1) >= 5

			if stageIdleProp then
				stageIdleProp:Destroy()
				stageIdleProp = nil
			end

			stageTitle.Text = string.format("%s pulled %s!", player.DisplayName, result.name or "something")
			stageTitle.TextColor3 = color
			stageSubtitle.Text = string.format("%s  •  %s%s", result.crate or "Crate", rarity,
				result.jackpot and string.format("  •  +%d coin JACKPOT", result.jackpot) or "")

			local def = result.kind == "Brainrot" and BrainrotData.Get(result.name) or nil
			local display
			if def then
				local scale = big and 1.8 or 1.5
				local size = def.look and def.look.size or 1
				local metrics = BrainrotModels.Metrics(def)
				local foot = Vector3.new(stageSpot.X, stageSpot.Y - metrics.bottom * scale * size, stageSpot.Z)
				display = newDisplay(foot)
				local model = BrainrotModels.Build(def, { scale = scale, glow = color, cframe = CFrame.new(foot) })
				for _, piece in ipairs(model:GetChildren()) do
					if piece:IsA("BasePart") then
						piece.Parent = display
					end
				end
				model:Destroy()
			else
				-- A cosmetic (or a refund): a gem in its colour, ringed with sparks.
				local at = CFrame.new(stageSpot + Vector3.new(0, 3.2, 0))
				display = newDisplay(at.Position)
				displayPart(display, Vector3.new(4.4, 4.4, 4.4), at, Color3.fromRGB(230, 240, 255), Enum.Material.Glass, Enum.PartType.Ball, 0.5)
				displayPart(display, Vector3.new(3, 3, 3), at, result.color or color, Enum.Material.Neon, Enum.PartType.Ball)
				for index = 0, 5 do
					local angle = index / 6 * math.pi * 2
					displayPart(display, Vector3.new(0.5, 0.5, 0.5), at * CFrame.new(math.cos(angle) * 3.2, 0, math.sin(angle) * 3.2), GOLD,
						Enum.Material.Neon, Enum.PartType.Ball)
				end
				pointLight(display, result.color or color, 18, 2)
			end
			display.Parent = ensureStageFolder()

			playgroundFx:FireAllClients({ kind = "stage", position = stageSpot + Vector3.new(0, 5, 0), color = color })
			if big then
				for _, delay in ipairs({ 0.6, 1.3 }) do
					task.delay(delay, function()
						playgroundFx:FireAllClients({ kind = "stage", position = stageSpot + Vector3.new(0, 6, 0), color = color })
					end)
				end
			end

			task.wait(big and STAGE_TIME_BIG or STAGE_TIME)
			if display.Parent then
				display:Destroy()
			end
			stageTitle.Text = ""
			stageSubtitle.Text = ""
		end
	end
	if stageSpot and not stageIdleProp then
		stageIdleProp = buildIdleProp()
	end
	stagePresenting = false
end

-- `result` is what CrateService.Open sends the opener: kind, name, rarity, crate, color, jackpot.
function LobbyService.PresentCrate(player, result)
	if type(result) ~= "table" or not stageSpot then
		return
	end
	-- A flurry of opens shows the latest few rather than backing up for minutes.
	while #stageQueue >= STAGE_QUEUE_LIMIT do
		table.remove(stageQueue, 1)
	end
	table.insert(stageQueue, { player = player, result = result })
	if not stagePresenting then
		stagePresenting = true
		task.spawn(presentQueue)
	end
end

--------------------------------------------------------------------------------
-- Daily Spin booth
--
-- The daily login reward from the Pass tab, as a wheel you spin in person. Claiming is the same
-- server call either way; here it also spins the wheel for everyone to see.
--------------------------------------------------------------------------------

local SPIN_TIME = 4

-- How big the wheel is, measured from the axle to the rim.
local WHEEL_RADIUS = 11

-- Who hears "X spun Y on the Daily Spin!": everyone else still in the lobby. Not a player in a match
-- (InMatch, MatchService's own tag, spectators included): a toast about a lobby wheel landing mid-fight
-- is noise, and it took the one toast slot over whatever the match had just said (findings C6).
function LobbyService.SpinWitnesses(spinner, players)
	local list = {}
	for _, other in ipairs(players) do
		if other ~= spinner and other:GetAttribute("InMatch") ~= true then
			table.insert(list, other)
		end
	end
	return list
end

local function buildDailySpin(lobby, base)
	-- No booth: the wheel stands in the open on its own dais, twice the size it was, so it reads
	-- from across the plaza.
	local center = spot(base, 292, STALL_RADIUS)
	local look = facingCentre(center, base)
	local segments = DailySpinData.Segments
	local count = #segments
	local step = math.pi * 2 / count

	-- The dais, the two posts and the axle the wheel turns on.
	disc(lobby, 28, 1, center, PLAZA_DARK, Enum.Material.Marble)
	disc(lobby, 22, 1, center + Vector3.new(0, 1, 0), Color3.fromRGB(58, 34, 78), Enum.Material.Marble)
	-- 0.07 lower than the console's underside (both were at 2.0).
	decor(disc(lobby, 22.6, 0.3, center + Vector3.new(0, 1.93, 0), GOLD, Enum.Material.Neon))
	local hubHeight = WHEEL_RADIUS + 4.5
	local hub = look * CFrame.new(0, hubHeight, 1.2)
	-- The posts stand on the lower step (its top is at 1), inside its edge. They used to start at 2,
	-- the upper step's height, but stand outside that step, so the whole wheel hung a stud in the air.
	for _, x in ipairs({ -WHEEL_RADIUS - 1.8, WHEEL_RADIUS + 1.8 }) do
		column(lobby, hubHeight - 1, 2.2, (look * CFrame.new(x, 1, 1.2)).Position, IRON, Enum.Material.Metal)
		decor(part(lobby, Vector3.new(1.5, 1.5, 1.5), look * CFrame.new(x, hubHeight, 1.2), GOLD, Enum.Material.Foil, Enum.PartType.Ball))
	end
	decor(part(lobby, Vector3.new(WHEEL_RADIUS * 2 + 4.8, 0.6, 0.6), hub, IRON, Enum.Material.Metal))

	-- The wheel: one wedge of colour per prize with its name on it, hung on a gold rim. Segment
	-- k sits k steps clockwise from the pointer at the top, so landing on it is a matter of
	-- turning the wheel back by that much.
	local wheel = Instance.new("Model")
	wheel.Name = "DailyWheel"
	local function wheelPart(size, cframe, color, material, shape)
		return decor(part(wheel, size, cframe, color, material, shape))
	end
	local span = WHEEL_RADIUS * 2
	wheelPart(Vector3.new(0.8, span, span), hub * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(40, 36, 48), Enum.Material.Metal, Enum.PartType.Cylinder)
	-- The rim is deep enough to stand clear of the backing disc's own faces. At 0.9 its front face
	-- landed 0.05 in front of the disc's, inside the z-fight pass's reach, so the pass moved one of
	-- them on every build.
	wheelPart(Vector3.new(1.2, span + 0.8, span + 0.8), hub * CFrame.new(0, 0, 0.1) * CFrame.Angles(0, math.pi / 2, 0), GOLD, Enum.Material.Foil,
		Enum.PartType.Cylinder)
	-- Each prize is a real pie slice, tiled out of small cells rather than drawn as one rectangle.
	-- A single box per segment cannot fill a wedge: it overlaps its neighbours near the hub and
	-- leaves gaps at the rim, which is what made this read as a pile of sticks instead of a wheel.
	-- Cells within a ring sit at different angles, so their side faces are never parallel, and
	-- cells in neighbouring rings butt end to end facing opposite ways — neither arrangement can
	-- produce the coplanar same-facing faces the z-fight pass has to resolve.
	local RINGS = { { 1.4, 3.4 }, { 3.4, 5.6 }, { 5.6, 7.8 }, { 7.8, 9.8 }, { 9.8, WHEEL_RADIUS + 0.2 } }
	local CELLS = 4
	for index, segment in ipairs(segments) do
		local frame = hub * CFrame.Angles(0, 0, -(index - 1) * step)
		local cell = step / CELLS
		-- Alternate segments are darkened a shade. The prize colours are pale, and two pale
		-- neighbours read as one blur from across the plaza.
		local face = index % 2 == 0 and segment.color or segment.color:Lerp(Color3.new(0, 0, 0), 0.22)
		for ringIndex, ring in ipairs(RINGS) do
			local inner, outer = ring[1], ring[2]
			local mid = (inner + outer) / 2
			for slice = 0, CELLS - 1 do
				local offset = -step / 2 + cell * (slice + 0.5)
				-- Width is the arc at the cell's OUTER edge, not its middle. Sized to the middle,
				-- every cell came up slightly narrow at its outer end and left a hairline gap, and
				-- with 32 cells a ring that covered the wheel in dark radial seams. Sized to the
				-- outer edge they always overlap instead, and overlapping is invisible. Neighbours
				-- are rotated relative to each other, so this still cannot make coplanar faces.
				-- Neighbouring cells sit at slightly different depths. Turning a cell about the
				-- wheel's axis leaves its front face in the same plane as every other cell's, so
				-- overlapping neighbours at one depth means coplanar faces the z-fight pass cannot
				-- pull apart. The stagger is what separates them; the rotation is only shape.
				-- Three depths, keyed on the ring as well as the slice. Alternating on the slice
				-- alone separated a cell from its immediate neighbour but gave slices 0 and 2 the
				-- same depth, and because each cell is sized to the arc at its OUTER edge they
				-- overlap near the hub -- two identical faces in one plane, which is the one
				-- z-fight pair the pass cannot resolve, since neither is the smaller one to grow.
				-- Keyed on where the cell sits all the way round the wheel, not on where it sits
				-- within its own segment. Numbering within the segment gave the last cell of one
				-- segment and the first of the next the same depth, and those two are neighbours
				-- that overlap -- exactly the tie this stagger exists to prevent. Thirty-two
				-- cells to a ring is not a multiple of three, but the wrap lands on a different
				-- value anyway, so going right round never repeats at the join.
				local around = (index - 1) * CELLS + slice
				-- Four depths, not three. Each cell is sized to the arc at its OUTER edge, so at
				-- the innermost ring it comes out about 2.4 times wider than its share of the arc
				-- at the inner edge and reaches well past its neighbours. Three depths left cells
				-- three apart sharing one, and that far in they still touch -- an exact tie, which
				-- is the pair the z-fight pass can never resolve. At four, only cells four apart
				-- share, and by then they are clear of each other even at the hub.
				-- The step has to CLEAR the pass's reach, not merely exist: at 0.05 every neighbouring
				-- pair sat inside FixTolerance (0.055) and the pass pulled them apart itself, 153 parts
				-- of this wheel on every build and one of them by 0.63 in total. 0.08 is past it.
				local depth = -0.55 - ((around + ringIndex) % 4) * 0.08
				wheelPart(Vector3.new(2 * outer * math.sin(cell / 2), outer - inner, 0.3),
					frame * CFrame.Angles(0, 0, -offset) * CFrame.new(0, mid, depth),
					face, Enum.Material.SmoothPlastic)
			end
		end
		-- The prize name, on the wedge it belongs to. A number here meant reading the wheel and
		-- then hunting the same number down on a board beside it before you knew what you had
		-- won, which is not a prize wheel. Names wrap over up to three short lines so even the
		-- long ones come out at a readable size inside the wedge's arc, and the plate itself is
		-- invisible so the wedge colour still shows and only the lettering reads.
		local lines, line = {}, nil
		for word in segment.label:gmatch("%S+") do
			if line and #line + 1 + #word <= 7 then
				line = line .. " " .. word
			else
				if line then
					table.insert(lines, line)
				end
				line = word
			end
		end
		table.insert(lines, line)
		local rows = {}
		local rowHeight = 1 / #lines
		for row, text in ipairs(lines) do
			table.insert(rows, {
				y = (row - 1) * rowHeight,
				h = rowHeight,
				text = text,
				color = WHITE,
				font = Enum.Font.GothamBlack,
				stroke = 0,
			})
		end
		-- Sized to the arc at its INNER edge (4.38 studs at radius 6.4), so the corners can never
		-- cross into the neighbouring wedge. Left unrotated on purpose: the lettering then runs
		-- along the arc and stays upright with the wheel, with no dependence on how a SurfaceGui
		-- maps its own X axis onto a part face.
		-- Stood clear in front of the cells and the dividers, and staggered between segments, so
		-- the plate's own faces share a plane with nothing. It's invisible, but the z-fight pass
		-- doesn't care about that, and standing proud also keeps a gold divider from cutting
		-- across the lettering.
		local plate = wheelPart(Vector3.new(4.2, 3.2, 0.08), frame * CFrame.new(0, 8, -1.0 - (index % 2) * 0.04), DARK, Enum.Material.SmoothPlastic)
		plate.Transparency = 1
		surfaceText(plate, Enum.NormalId.Front, rows, 70, 150)
		-- Divider along the segment boundary, standing clearly proud of the colour: both its faces
		-- clear every one of the four cell depths by 0.08 or more. At 0.34 thick and -0.74 its back
		-- face sat 0.02 off the deepest cells' backs.
		wheelPart(Vector3.new(0.5, WHEEL_RADIUS - 1.2, 0.28),
			frame * CFrame.Angles(0, 0, step / 2) * CFrame.new(0, (WHEEL_RADIUS + 1.4) / 2, -0.88), GOLD, Enum.Material.Foil)
	end
	wheelPart(Vector3.new(3.4, 3.4, 3.4), hub * CFrame.new(0, 0, -0.5), GOLD, Enum.Material.Foil, Enum.PartType.Ball)
	wheel.WorldPivot = hub
	wheel.Parent = lobby

	-- The pointer at the top and lights round the rim.
	-- Both sit on the gold rim (its edge is WHEEL_RADIUS + 0.4 out, and it runs from 0.35 in front of
	-- the hub's plane to 0.55 behind). They used to hover in front of it and outside it: the pointer
	-- a quarter stud off the wheel, the lights 0.4 beyond the rim's edge.
	decor(part(lobby, Vector3.new(1.4, 2.8, 0.6), hub * CFrame.new(0, WHEEL_RADIUS + 1.6, -0.5), Color3.fromRGB(230, 60, 60), Enum.Material.Neon))
	for index = 0, 19 do
		local angle = index / 20 * math.pi * 2
		local bulb = decor(part(lobby, Vector3.new(0.6, 0.6, 0.6),
			hub * CFrame.new(math.cos(angle) * (WHEEL_RADIUS + 0.55), math.sin(angle) * (WHEEL_RADIUS + 0.55), -0.2),
			index % 2 == 0 and GOLD or PINK, Enum.Material.Neon, Enum.PartType.Ball))
		if index % 4 == 0 then
			pointLight(bulb, bulb.Color, 10, 0.8)
		end
	end

	-- No legend board: the names are on the wedges now, which is the whole point of a prize wheel.

	-- The console you spin from, out in front of the wheel.
	local counter = part(lobby, Vector3.new(6, 3.4, 2.4), look * CFrame.new(0, 3.7, -8), GOLD, Enum.Material.Foil)
	counter.Name = "DailySpinConsole"
	-- The title goes above the wheel rather than on the console. On the console it floated across
	-- the wheel's lower half and covered the prizes.
	local titleAnchor = decor(part(lobby, Vector3.new(0.2, 0.2, 0.2), look * CFrame.new(0, hubHeight + WHEEL_RADIUS + 3.5, 1.2),
		DARK, Enum.Material.SmoothPlastic))
	titleAnchor.Transparency = 1
	billboard(titleAnchor, "DAILY SPIN", GOLD, Vector3.new(0, 0, 0), 14, 2.2, MatchConfig.LobbySignDistance)
	-- Two short lines, kept in the band between the counter's top and the prizes low on the wheel.
	-- As one 100-character line the label scaled its text down to a smudge.
	billboard(counter, "One free spin a day  •  streaks pay more", WHITE, Vector3.new(0, 2.9, 0), 13, 0.9)
	billboard(counter, "coins • crates • accessories • brainrots • day passes", GOLD, Vector3.new(0, 2.15, 0), 13, 0.7)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Spin"
	prompt.ObjectText = "Daily Spin"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter

	local spinning = false
	local restAngle = 0
	prompt.Triggered:Connect(function(player)
		if spinning then
			StateSync.Notify(player, "The wheel is still turning. One moment.", true)
			return
		end
		local ok, message, landed = LobbyService.OnDailySpin(player)
		if not ok then
			StateSync.Notify(player, message or "Not now.", true)
			return
		end

		spinning = true
		-- Three full turns, then on to the prize, plus a little scatter within its segment. The
		-- wheel turns the segments clockwise past the pointer, so segment k comes under the
		-- pointer after k steps.
		local index = tonumber(landed) or 1
		-- Segment k was placed k steps clockwise (a negative turn), so the wheel's own turn has to
		-- undo that: it stops at -k steps, give or take a little scatter within the segment.
		local target = (-(index - 1) * step + (math.random() - 0.5) * step * 0.6) % (math.pi * 2)
		local total = math.pi * 2 * 3 + ((target - restAngle) % (math.pi * 2))
		local from = restAngle
		restAngle = (restAngle + total) % (math.pi * 2)
		local started = wallNow()
		local connection
		connection = RunService.Heartbeat:Connect(function()
			local t = math.min(1, (wallNow() - started) / SPIN_TIME)
			local eased = 1 - (1 - t) ^ 3
			if wheel.Parent then
				wheel:PivotTo(hub * CFrame.Angles(0, 0, -(from + total * eased)))
			end
			if t >= 1 then
				connection:Disconnect()
				spinning = false
				local segment = DailySpinData.Segments[index]
				playgroundFx:FireAllClients({ kind = "spin", position = hub.Position, color = segment and segment.color or GOLD })
				-- The prize is announced when the wheel stops, not when it starts.
				StateSync.Notify(player, message or "Spun!")
				for _, other in ipairs(LobbyService.SpinWitnesses(player, Players:GetPlayers())) do
					StateSync.Notify(other, string.format("%s spun %s on the Daily Spin!", player.DisplayName, segment and segment.label or "a prize"))
				end
			end
		end)
	end)
end

--------------------------------------------------------------------------------
-- Boards and the Walk of Fame
--------------------------------------------------------------------------------

-- A holo pylon: a dark board between two neon uprights with a title and text rows. Returns the
-- rows so the caller can fill and refresh them.
local function buildPylon(lobby, position, base, title, titleColor, rowCount, rowHeight)
	local look = facingCentre(position, base)
	-- A long plinth under both uprights. It used to be a small round base under the board's middle,
	-- and the uprights, starting a stud up, stood on nothing beside it.
	part(lobby, Vector3.new(28.4, 1, 3), look * CFrame.new(0, 0.5, 0.3), PLAZA_DARK, Enum.Material.Marble)
	for _, x in ipairs({ -13, 13 }) do
		part(lobby, Vector3.new(1.2, 24, 1.2), look * CFrame.new(x, 13, 0.6), IRON, Enum.Material.Metal)
		decor(part(lobby, Vector3.new(0.3, 23, 0.3), look * CFrame.new(x, 13, -0.1), titleColor, Enum.Material.Neon))
	end
	local board = part(lobby, Vector3.new(26, 19, 0.8), look * CFrame.new(0, 14.5, 0), DARK, Enum.Material.SmoothPlastic)
	board.Transparency = 0.12
	decor(part(lobby, Vector3.new(26.4, 0.4, 1.0), look * CFrame.new(0, 24.2, 0), titleColor, Enum.Material.Neon))
	decor(part(lobby, Vector3.new(26.4, 0.4, 1.0), look * CFrame.new(0, 4.8, 0), titleColor, Enum.Material.Neon))
	pointLight(board, titleColor, 28, 1.2)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 25
	gui.LightInfluence = 0
	gui.MaxDistance = MatchConfig.LobbySignDistance

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = gui
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 16)
	padding.PaddingLeft = UDim.new(0, 26)
	padding.PaddingRight = UDim.new(0, 26)
	padding.Parent = gui

	local heading = Instance.new("TextLabel")
	heading.Size = UDim2.new(1, 0, 0, 56)
	heading.BackgroundTransparency = 1
	heading.Font = Enum.Font.FredokaOne
	heading.Text = title
	heading.TextColor3 = titleColor
	heading.TextScaled = true
	heading.LayoutOrder = 0
	heading.Parent = gui

	local rows = {}
	for index = 1, rowCount do
		local row = Instance.new("TextLabel")
		row.Size = UDim2.new(1, 0, 0, rowHeight)
		row.BackgroundTransparency = 1
		row.Font = Enum.Font.GothamBold
		row.Text = ""
		row.TextColor3 = WHITE
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextScaled = true
		row.LayoutOrder = index
		row.Parent = gui
		rows[index] = row
	end
	gui.Parent = board
	return rows
end

-- Gold, silver and bronze statues of the top three all-time winners, each with a plate the
-- all-time refresh fills in.
--
-- THESE THREE COLOURS ARE THE PODIUM AND THEY ARE SAID ONCE, HERE. The statues, the all-time
-- plates and the two leaderboards all rank the same top three, and they stand within sight of
-- each other on the Walk of Fame, so a first place written one way on a statue and another way
-- on the row beside it is simply two different golds. It was: the podium was written out three
-- times, silver and bronze agreed to the byte across all three, and gold did not — statues
-- rgb(255,196,64), rows rgb(255,200,60). Two of three matching is how you can tell that was a
-- slip and not a choice. Gold is now the island's own GOLD, and the boards read
-- HALL_METALS[place][1] rather than keeping a copy.
local HALL_METALS = {
	{ GOLD, Enum.Material.Foil, 3.4 },
	{ Color3.fromRGB(210, 214, 226), Enum.Material.Metal, 2.6 },
	{ Color3.fromRGB(214, 146, 90), Enum.Material.Metal, 2 },
}

-- How much bigger than life the Walk of Fame's statues stand.
local FAME_SCALE = 1.7

local function buildFameStatue(lobby, position, base, metal, place, scale)
	scale = scale or 1
	local color, material, plinthHeight = metal[1], metal[2], metal[3] * scale
	local look = facingCentre(position, base)
	local plinth = disc(lobby, 5.5 * scale, plinthHeight, position, Color3.fromRGB(70, 74, 94), Enum.Material.Marble)
	decor(disc(lobby, 6 * scale, 0.3, position + Vector3.new(0, plinthHeight - 0.2, 0), color, Enum.Material.Neon))
	pointLight(plinth, color, 14 * scale, 1.3)

	local stand = look * CFrame.new(0, plinthHeight, 0)
	local function limb(size, offset, shape)
		return decor(part(lobby, size * scale, stand * CFrame.new(offset.Position * scale) * offset.Rotation, color, material, shape))
	end
	for _, x in ipairs({ -0.5, 0.5 }) do
		limb(Vector3.new(0.9, 3, 0.9), CFrame.new(x, 1.5, 0))
	end
	-- Arms against the torso's sides (at 1.45 out they stood 0.05 clear of it).
	limb(Vector3.new(0.8, 2.8, 0.8), CFrame.new(-1.38, 4.3, 0))
	limb(Vector3.new(0.8, 2.8, 0.8), CFrame.new(1.38, 6.4, 0) * CFrame.Angles(0, 0, math.rad(-12)))
	limb(Vector3.new(2, 0.8, 1), CFrame.new(0, 3.4, 0))
	limb(Vector3.new(2, 1.8, 1), CFrame.new(0, 4.7, 0))
	limb(Vector3.new(0.5, 0.4, 0.5), CFrame.new(0, 5.8, 0))
	local head = limb(Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 6.6, 0), Enum.PartType.Ball)
	-- The laurel, in two layers. All ten leaves at one height overlapped their neighbours round the
	-- crown — turning a leaf about the crown doesn't turn its top and bottom, so all twenty of those
	-- faces lay in two planes and the z-fight pass had to spread every leaf on every statue. Leaves
	-- two apart share a height and are a whole leaf's width from each other.
	for index = 0, 9 do
		local angle = index / 10 * math.pi * 2
		decor(part(lobby, Vector3.new(0.3, 0.16, 0.5) * scale,
			stand * CFrame.new(math.cos(angle) * 0.7 * scale, (6.85 + (index % 2) * 0.09) * scale, math.sin(angle) * 0.7 * scale)
				* CFrame.Angles(0, -angle, 0),
			GREEN, Enum.Material.Grass))
	end
	local ordinal = ({ "1ST", "2ND", "3RD" })[place]
	billboard(head, ordinal .. "  ALL-TIME", color, Vector3.new(0, 2.6 * scale, 0), 7 * scale, 1.1 * scale)
	return billboard(head, "—", WHITE, Vector3.new(0, 1.5 * scale, 0), 9 * scale, 1.2 * scale)
end

local function buildBoards(lobby, base)
	leaderboardRows = buildPylon(lobby, spot(base, 60, 88), base, "TOP PLAYERS IN THIS SERVER", GOLD, LEADERBOARD_ROWS, 34)
	globalRows = buildPylon(lobby, spot(base, 120, 88), base, "ALL-TIME MOST WINS", SKY, LEADERBOARD_ROWS, 34)
	globalRows[1].Text = "Loading…"
	hallPlates = {}
	-- Bigger statues, spread wider apart, standing straight on the plaza. They get no terrace of
	-- their own: at this radius a platform overlaps both the plaza disc and the pitch.
	-- Kept off the pitch. The turf is 60 by 44 centred at (-74, 0), so it runs to z = 22, and at
	-- 1.7 times life size a statue out at 170 degrees stood inside it. These three angles put
	-- every plinth clear of that edge.
	for place, degrees in ipairs({ 150, 141, 159 }) do
		hallPlates[place] = buildFameStatue(lobby, spot(base, degrees, 94), base, HALL_METALS[place], place, FAME_SCALE)
	end
	-- The title on a low board on the plaza in front of the gold statue, the middle of the three.
	-- (It used to hang in the sky 18 studs up with nothing holding it, eight degrees off to one
	-- side, where the bronze statue's arm and labels covered it.) The plinth is set into the paving
	-- (top 0.17 here) and the board stands in a slot along its top.
	local plaque = facingCentre(spot(base, 150, 84), base)
	part(lobby, Vector3.new(17, 1, 1.6), plaque * CFrame.new(0, 0.4, 0), PLAZA_DARK, Enum.Material.Marble)
	local sign = decor(part(lobby, Vector3.new(16, 2.6, 0.4), plaque * CFrame.new(0, 2.1, 0), DARK, Enum.Material.Metal))
	surfaceText(sign, Enum.NormalId.Front, { { y = 0.08, h = 0.84, text = "WALK OF FAME", color = GOLD } }, 30)
	pointLight(sign, GOLD, 16, 1.2)
end

-- The all-time board reads a DataStore, which Studio and an unpublished place can't reach.
function LobbyService.RefreshGlobalBoard()
	if not globalRows then
		return
	end
	local top = GlobalBoardService.Top(LEADERBOARD_ROWS)
	local medal = { HALL_METALS[1][1], HALL_METALS[2][1], HALL_METALS[3][1] }
	if hallPlates then
		for place, plate in ipairs(hallPlates) do
			local entry = top and top[place]
			plate.Text = entry and string.format("%s  •  %d win%s", entry.name, entry.wins, entry.wins == 1 and "" or "s") or "Unclaimed"
		end
	end
	for index, row in ipairs(globalRows) do
		local entry = top and top[index]
		if entry then
			row.Text = string.format("%d.  %s   —   %d win%s", index, entry.name, entry.wins, entry.wins == 1 and "" or "s")
			row.TextColor3 = medal[index] or WHITE
		elseif index == 1 then
			row.Text = top and "Nobody has won a match yet. Be the first." or "Available once the game is published to Roblox."
			row.TextColor3 = MUTED
		else
			row.Text = ""
		end
	end
end

function LobbyService.RefreshLeaderboard()
	if not leaderboardRows then
		return
	end
	local entries = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local data = PlayerData.Get(player)
		if data then
			table.insert(entries, { name = player.DisplayName, wins = data.Stats.wins, kills = data.Stats.kills })
		end
	end
	table.sort(entries, function(a, b)
		if a.wins ~= b.wins then
			return a.wins > b.wins
		end
		return a.kills > b.kills
	end)
	local medal = { HALL_METALS[1][1], HALL_METALS[2][1], HALL_METALS[3][1] }
	for index, row in ipairs(leaderboardRows) do
		local entry = entries[index]
		if entry then
			row.Text = string.format("%d.  %s   —   %d wins   •   %d kills", index, entry.name, entry.wins, entry.kills)
			row.TextColor3 = medal[index] or WHITE
		else
			row.Text = index == 1 and "Win a match to get on the board!" or ""
		end
	end
end

--------------------------------------------------------------------------------
-- The Arena
--
-- A raised terrace to the east: practice targets for companions (CompanionService finds them by
-- tag), two of them bobbing, and three Legendary guns turning on pedestals.
--------------------------------------------------------------------------------

local ARENA_HEIGHT = 7

-- A target dummy on its stand, facing the terrace. PracticeDummy owns the body, its health and its
-- respawn. These replaced boards on posts, two of which bobbed on the client while their server
-- collision stayed put — so the target you saw was not where your shots landed.
local function buildPracticeTarget(lobby, position, base)
	PracticeDummy.Build(lobby, facingCentre(position, base), currentGroup)
end

local function buildArena(lobby, base)
	local center = base + Vector3.new(86, 0, 0)
	-- The terrace: stone, with a wall round the outer edge and two ramps up from the plaza.
	disc(lobby, 64, ARENA_HEIGHT, center - Vector3.new(0, 0, 0), STONE, Enum.Material.Cobblestone)
	-- The terrace top is three skins, each 0.07 above the last so no two faces are within the pass's
	-- tolerance and each shows where it should: the gold rim over the stone (its top 0.07 up, so it
	-- reads as a ring round the marble and a lip outside it), then the marble over the gold (top at
	-- 0.14). The marble was a 0.3 non-colliding slab that players walked inside; now it is thin and
	-- solid, the surface everything on the terrace stands on. (A first cut put the gold's top above
	-- the marble's, and the render showed a terrace of solid gold foil.)
	decor(disc(lobby, 64.4, 0.27, center + Vector3.new(0, ARENA_HEIGHT - 0.2, 0), GOLD, Enum.Material.Foil))
	disc(lobby, 60, 0.07, center + Vector3.new(0, ARENA_HEIGHT + 0.07, 0), PLAZA_DARK, Enum.Material.Marble)
	-- The terrace is a circle, so where its edge sits depends on how far off centre you are. The
	-- ramps used to stop at a fixed x of 54.5, which is short of the edge at their own offset and
	-- left them ending in mid-air; the railings sit four studs further out again, where the edge
	-- is further still, so they hung off worse. Both now meet the circle at their own offset.
	local terraceRadius = 32
	local function terraceEdgeX(offsetZ)
		local span = math.max(0, terraceRadius * terraceRadius - offsetZ * offsetZ)
		return center.X - math.sqrt(span)
	end
	for _, side in ipairs({ -1, 1 }) do
		-- The foot sits on the paving; the head meets the terrace edge flush.
		-- The slab is 0.6 thick, so its walking surface is 0.31 above its centreline at this slope.
		-- The centreline used to run from 0.32 above the plaza to 0.32 above the terrace, which put
		-- the surface about half a stud proud of the floor at BOTH ends — a lip to step up onto the
		-- ramp and another to step off it. It now runs 0.31 under each floor's top (the paving at
		-- 0.17, the marble at ARENA_HEIGHT + 0.14), so the surface meets both floors flush.
		local from = base + Vector3.new(34, 0.17 - 0.31, side * 12)
		local to = Vector3.new(terraceEdgeX(12) + 0.6, base.Y + ARENA_HEIGHT + 0.14 - 0.31, base.Z + side * 12)
		local ramp = part(lobby, Vector3.new(8, 0.6, (to - from).Magnitude + 1), CFrame.lookAt(from:Lerp(to, 0.5), to), STONE, Enum.Material.Cobblestone)
		ramp.Name = "ArenaRamp"
		local railFrom = from + Vector3.new(0, 0.3, side * 4)
		local railTo = Vector3.new(terraceEdgeX(16) + 0.6, to.Y + 0.3, base.Z + side * 16)
		railing(lobby, railFrom, railTo, 2.2)
	end
	-- The firing range. There is no rack: you take one of the Legendary guns off the podiums below,
	-- which were already standing there. Required here rather than at the top of the file so the
	-- module loads with the lobby; a require is cached, so doing it in the builder costs nothing.
	local RangeService = require(script.Parent:WaitForChild("RangeService"))
	RangeService.SetArea(center, terraceRadius)

	-- Target dummies along the far edge. Pulled in from 22: at that offset the outer pair sat 31
	-- studs from the centre of a 32 stud terrace and their stands overhung the rim.
	-- On the marble's top face (a butt joint), not on the stone inside it: a dummy is rebuilt at
	-- runtime, after the z-fight pass has run, so its stand has to be clean as placed.
	for _, z in ipairs({ -18, -9, 0, 9, 18 }) do
		buildPracticeTarget(lobby, center + Vector3.new(18, ARENA_HEIGHT + 0.14, z), base)
	end
	-- The practice sign: a title and a smaller line under it (one 16-stud label squeezed both into
	-- tiny text), on an invisible anchor like every other lobby label's (it was a dark 0.2 cube
	-- hanging in the sky). The key is filled in per player, since the companion key can be rebound.
	local practiceAnchor = decor(part(lobby, Vector3.new(0.2, 0.2, 0.2), CFrame.new(center + Vector3.new(22, ARENA_HEIGHT + 14, 0)), DARK,
		Enum.Material.SmoothPlastic))
	practiceAnchor.Transparency = 1
	billboard(practiceAnchor, "TARGET PRACTICE", GOLD, Vector3.new(0, 0.9, 0), 14, 2, MatchConfig.LobbySignDistance)
	keyHint(billboard(practiceAnchor, "Stand near a target and use your companion's move", WHITE, Vector3.new(0, -0.65, 0), 14, 1,
		MatchConfig.LobbySignDistance), "Stand near a target and press [{Companion}]")

	-- Three Legendary guns on lit pedestals, turning.
	local legendaries = {}
	for id, weapon in pairs(WeaponData.Weapons) do
		-- A staged gun is one still being finished: it is kept out of players' hands everywhere, and the
		-- podiums hand theirs to you for the range, so they skip it too.
		if weapon.rarity == "Legendary" and not weapon.staged then
			-- The id comes along too: taking one off its podium needs it.
			table.insert(legendaries, { id = id, def = weapon })
		end
	end
	if #legendaries == 0 then
		warn("[LobbyService] no unstaged Legendary guns: the range podiums stand empty")
	end
	table.sort(legendaries, function(a, b)
		return a.def.name < b.def.name
	end)
	-- The podium guns get a folder of their own in the workspace, outside the lobby model and
	-- StageDisplay (see below), which goes when the lobby does. AmbientClient turns its displays.
	local oldGunDisplays = workspace:FindFirstChild("GunDisplays")
	if oldGunDisplays then
		oldGunDisplays:Destroy()
	end
	local gunDisplays = Instance.new("Folder")
	gunDisplays.Name = "GunDisplays"
	gunDisplays.Parent = workspace
	lobby.Destroying:Connect(function()
		gunDisplays:Destroy()
	end)
	for index, z in ipairs({ -18, 0, 18 }) do
		local entry = legendaries[((math.floor(os.time() / 86400) + index) % math.max(1, #legendaries)) + 1]
		local def = entry and entry.def
		if def then
			-- On the marble's top face, like the dummies' stands: at ARENA_HEIGHT the podium's
			-- underside shared the marble skin's, and the pass sank every podium 0.06.
			local foot = center + Vector3.new(-10, ARENA_HEIGHT + 0.14, z)
			local pedestal = disc(lobby, 6, 3, foot, DARK, Enum.Material.Metal)
			pedestal.Name = "RangePodium"
			-- Take the gun off the podium and shoot the targets with it. It goes back by itself
			-- when you walk off the terrace.
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = "Take"
			prompt.ObjectText = def.name
			prompt.HoldDuration = 0.25
			-- Under half the 18 studs between podiums, so nowhere on the terrace is in reach of two:
			-- at 12 there was a band between each pair where either prompt could be the one that
			-- fired, and which it was turned on where you were looking. #117
			prompt.MaxActivationDistance = 8
			prompt.RequiresLineOfSight = false
			prompt.Parent = pedestal
			prompt.Triggered:Connect(function(player)
				local ok, message = RangeService.Give(player, entry.id)
				StateSync.Notify(player, message or (ok and "Taken." or "Not now."), not ok)
			end)
			decor(disc(lobby, 6.4, 0.3, foot + Vector3.new(0, 2.9, 0), Rarity.Color(def.rarity), Enum.Material.Neon))
			local display = newDisplay(foot + Vector3.new(0, 5.4, 0))
			local color = Rarity.Color(def.rarity)
			local receiver, pieces, top = WeaponService.BuildStaticGun(def, color, Enum.Material.Metal,
				display.CFrame * CFrame.Angles(0, math.pi / 2, math.rad(-12)), display)
			for _, piece in ipairs(pieces) do
				piece.CanQuery = false
			end
			receiver.Name = "DisplayGun"
			-- In GunDisplays, never StageDisplay or the lobby: the lobby's z-fight pass covers both at
			-- map scale, and it turned these guns' millimetre detail into black blocks.
			display.Parent = gunDisplays
			pointLight(display, color, 14, 1.2)
			-- The labels stand clear over the gun's highest point, whatever the gun.
			local labelAt = math.max(2, top + 0.75)
			billboard(display, def.name, color, Vector3.new(0, labelAt + 1, 0), 9, 1.2)
			-- Says where the real ones come from (supply drops roll Legendary 28%; a chest about 2%) and
			-- that this one can be taken: "chest loot only" read as a display case, and sent players to
			-- the wrong source (#86).
			billboard(display, "LEGENDARY  •  take it and shoot the targets", WHITE, Vector3.new(0, labelAt, 0), 9, 0.9)
		end
	end
	local arenaAnchor = decor(part(lobby, Vector3.new(0.2, 0.2, 0.2), CFrame.new(center + Vector3.new(0, ARENA_HEIGHT + 20, 0)), DARK,
		Enum.Material.SmoothPlastic))
	arenaAnchor.Transparency = 1
	billboard(arenaAnchor, "THE ARENA", GOLD, Vector3.new(0, 0, 0), 12, 2.2, MatchConfig.LobbySignDistance)
end

--------------------------------------------------------------------------------
-- The edge
--
-- #103, "people can jump off the edge in the lobby". The rim's rail is posts with non-colliding
-- rails between them, low enough to hop, with gaps at the four waterfalls; the invisible wall
-- round the rim only stops balls (its collision group ignores players); and the pier and the
-- airship run out past the rim altogether, so a wall players could not cross would have to leave
-- a hole exactly where they board. And nothing put a faller back: the island is 500 up, so they
-- fell for the best part of ten seconds, and with a match on they landed in it.
--
-- So a safety net rather than more wall: anyone not in a match who drops well below the island
-- while still over it is put back on the pier, where everyone spawns, and told so. The net is a
-- band of height as well as a circle, and the band is the part that keeps it off match players:
-- its floor is well above anywhere a match puts anyone (the drop opens at DropHeight, 170, over
-- ground far below), so nobody in a match can ever be in it, whatever their InMatch says.
--------------------------------------------------------------------------------

-- How far below the plaza a fall is caught: under the rim, well clear of anything you could be
-- standing on (the underside's rock is out of reach below the grass), and above the match.
local NET_TOP = 30
local NET_BOTTOM = 220
-- Past the airship's stern (z182) with room for a run-up jump off it.
local NET_RADIUS = 260
local NET_INTERVAL = 0.2

-- Whether someone at `position` has fallen off the island. Pure, so tools/lobby_edge_check.py can
-- run it against the island's real heights.
function LobbyService.HasFallen(position, base)
	local below = base.Y - position.Y
	if below < NET_TOP or below > NET_BOTTOM then
		return false
	end
	local flat = Vector3.new(position.X - base.X, 0, position.Z - base.Z)
	return flat.Magnitude <= NET_RADIUS
end

local function catchFallers()
	local base = MatchConfig.LobbyPosition
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and player:GetAttribute("InMatch") ~= true
			and LobbyService.HasFallen(root.Position, base) then
			-- The same pier spot MatchService spawns people on, facing the island.
			local spawn = base + LobbyService.SpawnOffset
			local position = spawn + Vector3.new(math.random(-LobbyService.SpawnHalfWidth + 2, LobbyService.SpawnHalfWidth - 2), 2.2,
				math.random(-8, 8))
			character:PivotTo(CFrame.lookAt(position, Vector3.new(base.X, position.Y, base.Z)))
			-- Or they arrive still falling at a hundred studs a second and bounce off the pier.
			root.AssemblyLinearVelocity = Vector3.zero
			StateSync.Notify(player, "Back on the island.")
		end
	end
end

-- Started once with the module rather than per build: it reads nothing the build makes, only
-- where the island is, so a rebuilt lobby needs no second loop.
task.spawn(function()
	while true do
		task.wait(NET_INTERVAL)
		if workspace:FindFirstChild("Lobby") then
			local ok, err = pcall(catchFallers)
			if not ok then
				warn("[LobbyService] lobby edge net failed: " .. tostring(err))
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- The Pitch and the play balls
--
-- Big googly-eyed balls loose on the plaza to kick around. They're simulated by the server;
-- running into one boots it away from you, harder the faster you're going. One that somehow
-- leaves the island is put back where it started. Kick one into the goal on the pitch and it's
-- a goal for whoever touched it last.
--------------------------------------------------------------------------------

local KICK_COOLDOWN = 0.25
local KICK_MEMORY = 15
local GOAL_PAY_COOLDOWN = 20

local BALLS = {
	{ diameter = 4, color = Color3.fromRGB(255, 140, 200), kick = 1, spot = Vector3.new(-56, 0, -14) },
	{ diameter = 4, color = Color3.fromRGB(110, 210, 255), kick = 1, spot = Vector3.new(-56, 0, 14) },
	{ diameter = 5, color = Color3.fromRGB(140, 240, 140), kick = 0.9, spot = Vector3.new(-66, 0, 0) },
	{ diameter = 5, color = Color3.fromRGB(255, 170, 70), kick = 0.9, spot = Vector3.new(-30, 0, 46) },
	{ diameter = 6, color = Color3.fromRGB(190, 140, 255), kick = 0.8, spot = Vector3.new(34, 0, 46) },
	{ diameter = 8, color = Color3.fromRGB(255, 200, 60), kick = 0.55, spot = Vector3.new(0, 0, 60) },
}

local playgroundGeneration = 0
local ballEntries = {}
local lastGoalPaidAt = {}

local function buildBall(spec, position)
	local ball = Instance.new("Part")
	ball.Name = "PlayBall"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(spec.diameter, spec.diameter, spec.diameter)
	ball.Color = spec.color
	ball.Material = Enum.Material.SmoothPlastic
	ball.CFrame = CFrame.new(position)
	ball.CustomPhysicalProperties = PhysicalProperties.new(0.25, 0.35, 0.55, 1, 1)
	ball.TopSurface = Enum.SurfaceType.Smooth
	ball.BottomSurface = Enum.SurfaceType.Smooth
	ball.CollisionGroup = BALL_GROUP
	for _, side in ipairs({ -1, 1 }) do
		local eyeFrame = CFrame.new(position) * CFrame.Angles(0, side * 0.38, 0) * CFrame.new(0, spec.diameter * 0.16, -spec.diameter * 0.44)
		for _, layer in ipairs({ { 0.34, Color3.fromRGB(250, 250, 250), 0 }, { 0.16, Color3.fromRGB(20, 20, 24), 0.13 } }) do
			local size = spec.diameter * layer[1]
			local eye = Instance.new("Part")
			eye.Shape = Enum.PartType.Ball
			eye.Size = Vector3.new(size, size, size)
			eye.Color = layer[2]
			eye.Material = Enum.Material.SmoothPlastic
			eye.CFrame = eyeFrame * CFrame.new(0, 0, -layer[3] * spec.diameter)
			eye.Massless = true
			decor(eye)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = ball
			weld.Part1 = eye
			weld.Parent = eye
			eye.Parent = ball
		end
	end
	return ball
end

local function resetBall(entry)
	entry.ball.AssemblyLinearVelocity = Vector3.zero
	entry.ball.AssemblyAngularVelocity = Vector3.zero
	entry.ball.CFrame = CFrame.new(entry.home)
end

local function buildPlayBalls(lobby, base)
	playgroundGeneration += 1
	local generation = playgroundGeneration
	local balls = {}
	ballEntries = {}
	for _, spec in ipairs(BALLS) do
		local home = base + spec.spot + Vector3.new(0, spec.diameter / 2 + 1, 0)
		local ball = buildBall(spec, home)
		ball.Parent = lobby
		pcall(function()
			ball:SetNetworkOwner(nil)
		end)
		local entry = { ball = ball, home = home, kick = spec.kick, lastKick = 0, lastKicker = nil, scored = false }
		table.insert(balls, entry)
		ballEntries[ball] = entry

		ball.Touched:Connect(function(hit)
			local character = hit:FindFirstAncestorOfClass("Model")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local player = character and Players:GetPlayerFromCharacter(character)
			if not root or not player then
				return
			end
			local now = wallNow()
			if now - entry.lastKick < KICK_COOLDOWN then
				return
			end
			entry.lastKick = now
			entry.lastKicker = player
			local away = Vector3.new(ball.Position.X - root.Position.X, 0, ball.Position.Z - root.Position.Z)
			if away.Magnitude < 0.1 then
				away = root.CFrame.LookVector * Vector3.new(1, 0, 1)
			end
			local running = root.AssemblyLinearVelocity
			local runSpeed = Vector3.new(running.X, 0, running.Z).Magnitude
			local power = (22 + runSpeed * 1.3) * entry.kick
			ball.AssemblyLinearVelocity = away.Unit * power + Vector3.new(0, (10 + runSpeed * 0.4) * entry.kick, 0)
			playgroundFx:FireAllClients({ kind = "kick", position = ball.Position })
		end)
	end

	task.spawn(function()
		while generation == playgroundGeneration and lobby.Parent do
			task.wait(2)
			for _, entry in ipairs(balls) do
				if entry.ball.Parent and not entry.scored then
					local offset = entry.ball.Position - base
					if offset.Y < -20 or Vector3.new(offset.X, 0, offset.Z).Magnitude > RIM_RADIUS + 10 then
						resetBall(entry)
					end
				end
			end
		end
	end)
end

local function buildPitch(lobby, base)
	local center = base + Vector3.new(-74, 0, 0)
	local white = Color3.fromRGB(240, 240, 236)
	-- Turf, with a touchline and a centre circle. The turf's top (0.25) clears the plaza paving
	-- (0.17); the lines sit on the turf, and the circle's inner grass sits a step above the line.
	decor(part(lobby, Vector3.new(60, 0.2, 44), CFrame.new(center + Vector3.new(0, 0.15, 0)), GRASS, Enum.Material.Grass))
	for _, z in ipairs({ -21.5, 21.5 }) do
		decor(part(lobby, Vector3.new(60, 0.12, 0.6), CFrame.new(center + Vector3.new(0, 0.31, z)), white, Enum.Material.SmoothPlastic))
	end
	-- The end line stops where the touchlines start rather than crossing them: markings that
	-- overlap share their tops, their undersides and an end face, which is six fighting pairs at
	-- each corner. Butted like this, they meet with no seam and nothing to fix.
	decor(part(lobby, Vector3.new(0.6, 0.12, 42.4), CFrame.new(center + Vector3.new(29.7, 0.31, 0)), white, Enum.Material.SmoothPlastic))
	-- The centre circle: a white disc with a grass one laid into it to leave a ring. Both used to
	-- start at the same height, so their undersides were the same plane.
	decor(disc(lobby, 12, 0.12, center + Vector3.new(6, 0.2, 0), white, Enum.Material.SmoothPlastic))
	decor(disc(lobby, 10.8, 0.12, center + Vector3.new(6, 0.27, 0), GRASS, Enum.Material.Grass))

	-- The goal at the west end, facing the plaza.
	local goalCenter = center + Vector3.new(-26, 0, 0)
	local look = CFrame.lookAt(goalCenter, goalCenter + Vector3.new(1, 0, 0))
	local net = Color3.fromRGB(220, 224, 230)
	-- The frame's feet are set 0.2 into the ground (at 0 they were 0.05 from the turf's underside,
	-- inside the pass's tolerance), and the net panels stop short of the frame instead of sharing
	-- its planes: the sides' tops used to lie in the crossbar's top, the back's in the sides', the
	-- top panel's ends in the crossbar's ends, and the sides' backs 0.05 from the back panel's —
	-- ten pairs of faces the pass pulled apart by widening the crossbar 0.42.
	for _, x in ipairs({ -7, 7 }) do
		part(lobby, Vector3.new(0.8, 8.2, 0.8), look * CFrame.new(x, 3.9, 0), white, Enum.Material.SmoothPlastic)
	end
	local crossbar = part(lobby, Vector3.new(14.8, 0.8, 0.8), look * CFrame.new(0, 8.4, 0), white, Enum.Material.SmoothPlastic)
	for _, spec in ipairs({
		{ Vector3.new(14.4, 8.5, 0.3), CFrame.new(0, 4.15, 4.2) },
		{ Vector3.new(0.3, 8.5, 4.4), CFrame.new(-7.4, 4.15, 2.1) },
		{ Vector3.new(0.3, 8.5, 4.4), CFrame.new(7.4, 4.15, 2.1) },
		{ Vector3.new(14.4, 0.3, 4.0), CFrame.new(0, 8.55, 2.0) },
	}) do
		local mesh = part(lobby, spec[1], look * spec[2], net, Enum.Material.Fabric)
		mesh.Transparency = 0.55
	end
	for _, x in ipairs({ -11, 11 }) do
		decor(part(lobby, Vector3.new(0.6, 0.12, 16), look * CFrame.new(x, 0.31, -8), white, Enum.Material.SmoothPlastic))
	end
	decor(part(lobby, Vector3.new(21.4, 0.12, 0.6), look * CFrame.new(0, 0.31, -16), white, Enum.Material.SmoothPlastic))
	billboard(crossbar, "GOAL", GREEN, Vector3.new(0, 3.2, 0), 8, 2)
	billboard(crossbar, "Kick a ball in for SahurCoins", WHITE, Vector3.new(0, 1.7, 0), 11, 1)
	-- Floodlights at the corners.
	for _, corner in ipairs({ Vector3.new(-29, 0, -21), Vector3.new(-29, 0, 21), Vector3.new(29, 0, -21), Vector3.new(29, 0, 21) }) do
		local foot = center + corner
		-- The pole's foot 0.2 into the ground: at 0 it was 0.05 from the turf's underside.
		column(lobby, 16.45, 0.8, foot - Vector3.new(0, 0.45, 0), IRON, Enum.Material.Metal)
		local lamp = decor(part(lobby, Vector3.new(3, 1.2, 1), CFrame.lookAt(foot + Vector3.new(0, 16.5, 0), center + Vector3.new(0, 8, 0)),
			Color3.fromRGB(255, 250, 230), Enum.Material.Neon))
		pointLight(lamp, Color3.fromRGB(255, 250, 230), 40, 1.4)
	end

	local zone = part(lobby, Vector3.new(13.6, 7.6, 1), look * CFrame.new(0, 4, 1.6), GREEN, Enum.Material.Neon)
	zone.Name = "GoalZone"
	zone.Transparency = 1
	zone.CanCollide = false
	zone.CanQuery = false
	zone.Touched:Connect(function(hit)
		local entry = ballEntries[hit]
		if not entry or entry.scored then
			return
		end
		entry.scored = true
		local now = wallNow()
		local scorer = entry.lastKicker
		if scorer and (not scorer.Parent or now - entry.lastKick > KICK_MEMORY) then
			scorer = nil
		end
		playgroundFx:FireAllClients({ kind = "goal", position = zone.Position + Vector3.new(0, 2, 0), color = GREEN })
		if scorer then
			for _, other in ipairs(Players:GetPlayers()) do
				StateSync.Notify(other, string.format("GOAL by %s!", scorer.DisplayName))
			end
			-- At most one paid goal every GOAL_PAY_COOLDOWN, and at most 5 in any 10 minutes (Oliver,
			-- 2026-09-22, ECONOMY.md s.2: a player who never readied could farm up to 6,300 coins an
			-- hour here, more than a player who keeps losing earns in matches). 5 covers every goal a
			-- player gets to score between matches; the cap only bites on someone who never leaves.
			local paid = lastGoalPaidAt[scorer] or {}
			lastGoalPaidAt[scorer] = paid
			while paid[1] and now - paid[1] > 600 do
				table.remove(paid, 1)
			end
			if now - (paid[#paid] or -math.huge) >= GOAL_PAY_COOLDOWN and #paid < 5 then
				table.insert(paid, now)
				LobbyService.OnGoal(scorer)
			end
		end
		task.delay(1.6, function()
			if entry.ball.Parent then
				resetBall(entry)
			end
			entry.scored = false
		end)
	end)
end

--------------------------------------------------------------------------------
-- Cloud Climb
--
-- The obby up the Rot Tree, built of nothing but its branches. Where every limb goes is
-- CloudClimbCourse, laid out by tools/climb_design.py and checked there against jump reach
-- measured in Studio (tools/jump_probe.lua): every jump possible with room to spare, none you can
-- skip, and no limb through another or through a body standing on one. This builds the course,
-- dresses it and runs it.
--
--   Forks           two limbs from one knot on the trunk, splayed into a V. Land on the tip of
--                   one, walk it in to the knot, walk the other out and jump from its tip.
--   The Long Bough  sags out from under the leaves to the rim of the canopy
--   Crown limbs     poke out of the leaves, spiralling up round the canopy to twigs through its
--                   top, and the summit on the tree's leader above it all
--   Deadwood        pale dead limbs: they creak and redden when you land, snap a moment later (a
--                   copy tumbles away) and grow back
--   Springers       limbs that flap up and down about where they leave the trunk or the leaves
--                   (AmbientSway on the client, timed off the server's clock)
--   Thorns          thorny rotors across the route, and a thorn wheel turning round the trunk
--   Checkpoints     three limbs with a glowing sap knot. Once you've reached one, the Sap Lantern
--                   at the foot of the climb puts you back on it; the clock keeps running.
--
-- The start root starts the clock, unless your run already has a checkpoint: walking back over
-- it to reach the lantern mustn't throw that away. The lantern can start you over instead.
--------------------------------------------------------------------------------

-- player -> { started = wallNow() when the run began, checkpoint = number, spot = CFrame }
local climbRuns = {}

-- What makes a clear count. The summit used to pay any run that existed: touch the start root,
-- teleport to the disc, and that was a server record and 250 SahurCoins. A clear now needs every
-- checkpoint, in order, and no stretch of the climb done faster than a body can move.
--
-- The floor on each is the straight-line distance through every jump's easiest crossing
-- (CloudClimbCourse.jumps, tools/climb_design.py) from the first fork's takeoff, where a run can
-- start, at CLIMB_TOP_SPEED: sprinting with the Rot Runner pass and a 1.5x speed boost, faster than
-- anyone moves in the lobby. The real route winds along the limbs and waits on deadwood and rotors,
-- so an honest climb is far over it. tools/climb_rules_check.py runs this block.
local CLIMB_TOP_SPEED = (MatchConfig.BaseWalkSpeed + 4) * MatchConfig.SprintMultiplier * 1.5

-- Element name -> the fewest seconds from a run's start to landing on it.
local function climbFloors(course)
	local floors, travelled, last = {}, 0, nil
	for index, jump in ipairs(course.jumps) do
		if index >= 2 then
			local from, to = jump.from, jump.to
			if last then
				travelled += math.sqrt((from[1] - last[1]) ^ 2 + (from[3] - last[3]) ^ 2)
			end
			travelled += math.sqrt((to[1] - from[1]) ^ 2 + (to[3] - from[3]) ^ 2)
			last = to
			local landing = string.match(jump.name, "%-> (.+)$")
			if landing then
				floors[landing] = travelled / CLIMB_TOP_SPEED
			end
		end
	end
	return floors
end

-- Whether touching checkpoint `number` counts: only the next one, and not sooner than it can be
-- climbed to.
local function climbCheckpointCounts(run, number, floor, now)
	return number == (run.checkpoint or 0) + 1 and now - run.started >= (floor or 0)
end

-- The seconds a summit touch clears in, or nil and why it doesn't count.
local function climbSummitVerdict(run, checkpoints, floor, now)
	local seconds = now - run.started
	if (run.checkpoint or 0) < checkpoints then
		return nil, "every checkpoint"
	end
	if seconds < (floor or 0) then
		return nil, "the climb itself"
	end
	return seconds
end

-- A match ends a climb run: without this, a run started before the match was still live after it,
-- so the lantern sent you to the old checkpoint and the summit paid a clear (first-clear coins and
-- the quest) timed across the whole match, without climbing the lower course again.
function LobbyService.ClearClimb(player)
	climbRuns[player] = nil
end
local obbyBest = nil
local obbyBestLabel = nil

local LIVEWOOD = Color3.fromRGB(112, 78, 50)
local LIVEWOOD_DARK = Color3.fromRGB(78, 53, 35)
-- Bleached, dry tan rather than grey: under the lobby's sun any neutral grey on a smooth cylinder
-- reads as metal pipe.
local DEADWOOD = Color3.fromRGB(148, 126, 98)
local CRACKING = Color3.fromRGB(218, 124, 84)
local SPRINGWOOD = Color3.fromRGB(124, 106, 62)
local SAP = Color3.fromRGB(255, 176, 64)
local THORN = Color3.fromRGB(255, 52, 72)
local THORNWOOD = Color3.fromRGB(58, 34, 30)

-- How long deadwood holds once someone lands on it: long enough to run a fork's limb out, short
-- enough that a limb out of the crown is land-and-go. Then how long it takes to grow back.
local SNAP_HOLD = { fork = 1.1, stub = 0.7 }
local SNAP_REGROW = 3.2
-- The Sap Lantern only answers someone this close to the tree, so nobody in a match is pulled back.
local LANTERN_RANGE = 300
-- From the Roblox client's own sounds, which tools/sound_probe.lua measured as present.
local SNAP_SOUND = "rbxasset://sounds/snap.mp3"
-- The creak before deadwood snaps: `switch3` (a heavy latch) at half speed is a 0.74 s wooden crick,
-- about the `hold` before the snap. (#120: it was `collide`, the brick-collision crash, 2.4 s at
-- half speed for a branch that breaks 0.7-1.1 s after you land on it.)
local CREAK_SOUND = "rbxasset://sounds/switch3.wav"
local CHECKPOINT_SOUND = "rbxasset://sounds/electronicpingshort.wav"

local function renderObbyBest()
	if obbyBestLabel then
		obbyBestLabel.Text = obbyBest and string.format("Server best: %s  %.1fs", obbyBest.name, obbyBest.seconds)
			or "Server best: nobody yet"
	end
end

-- The trunk's radius at a height above its foot (CloudClimbCourse's stacked lengths).
local function trunkRadiusAt(y)
	local trunk = CloudClimbCourse.trunk
	local index = math.clamp(math.floor(y / (trunk.height / trunk.lengths)), 0, trunk.lengths - 1)
	return trunk.bottomRadius + (trunk.topRadius - trunk.bottomRadius) * index / (trunk.lengths - 1)
end

local function climbSound(parent, id, volume, speed)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume
	sound.PlaybackSpeed = speed
	sound.RollOffMaxDistance = 100
	sound.Parent = parent
	return sound
end

-- Where a limb's visible part runs, as world points with the diameter there: the solid segments.
local function visibleRun(base, limb)
	local run = {}
	for k = math.max(1, limb.solidFrom), #limb.points do
		table.insert(run, { position = at(base, limb.points[k]), diameter = limb.points[k][4] })
	end
	return run
end

-- The point `distance` along a run, with the direction and diameter there.
local function alongRun(run, distance)
	local travelled = 0
	for index = 1, #run - 1 do
		local a, b = run[index], run[index + 1]
		local length = (b.position - a.position).Magnitude
		if travelled + length >= distance or index == #run - 1 then
			local t = length > 0 and math.clamp((distance - travelled) / length, 0, 1) or 0
			local direction = length > 0 and (b.position - a.position).Unit or Vector3.xAxis
			return a.position:Lerp(b.position, t), direction, a.diameter + (b.diameter - a.diameter) * t
		end
		travelled += length
	end
	return run[1].position, Vector3.xAxis, run[1].diameter
end

local function runLength(run)
	local length = 0
	for index = 1, #run - 1 do
		length += (run[index + 1].position - run[index].position).Magnitude
	end
	return length
end

-- Leaves and a blossom bunched off the end of a live limb, all below the top you land on.
local function leafTuft(parent, tip, out, diameter, random, count)
	for _ = 1, count do
		local size = random:NextNumber(1.5, 2.3)
		local position = tip + out * (diameter / 2 + random:NextNumber(0.3, 1))
			+ Vector3.new(random:NextNumber(-0.9, 0.9), -(diameter / 2 + size * 0.4) + random:NextNumber(-0.3, 0.05), random:NextNumber(-0.9, 0.9))
		decor(part(parent, Vector3.new(size, size, size), CFrame.new(position), LEAF:Lerp(Color3.new(0, 0, 0), random:NextNumber(0, 0.2)),
			Enum.Material.Grass, Enum.PartType.Ball))
	end
	if random:NextNumber() < 0.65 then
		decor(part(parent, Vector3.new(0.7, 0.7, 0.7), CFrame.new(tip + out * (diameter / 2 + 0.8) - Vector3.new(0, diameter * 0.35, 0)),
			random:NextNumber() < 0.35 and GOLD or PINK, Enum.Material.Neon, Enum.PartType.Ball))
	end
end

-- Twigs, knots and cracks along the part of a limb you can see, all scenery. Twigs droop or run
-- level off the sides and knots sit low on the flanks, never up over the top you walk on. On
-- deadwood the twigs are broken stubs and pale cracks ring the wood.
local function dressLimb(parent, base, limb, color, random, dead)
	local run = visibleRun(base, limb)
	if #run < 2 then
		return
	end
	local length = runLength(run)
	-- A spot every three studs or so, stopping short of the tip, which gets its own dressing.
	local spots = math.floor((length - 1.5) / 3)
	for spot = 1, spots do
		local point, along, diameter = alongRun(run, (spot - random:NextNumber(0.2, 0.8)) * 3)
		local flat = Vector3.new(along.X, 0, along.Z)
		local side = flat.Magnitude > 1e-3 and Vector3.new(-flat.Z, 0, flat.X).Unit or Vector3.xAxis
		local sign = random:NextNumber() < 0.5 and -1 or 1
		local roll = random:NextNumber()
		if roll < 0.42 then
			local direction = (side * sign + along * random:NextNumber(0.2, 0.7) + Vector3.new(0, random:NextNumber(-0.7, 0.05), 0)).Unit
			local from = point + side * sign * diameter * 0.25 - Vector3.new(0, diameter * 0.15, 0)
			local to = from + direction * ((dead and random:NextNumber(0.6, 1.1) or random:NextNumber(1.4, 2.6)) + diameter * 0.3)
			decor(rod(parent, from, to, dead and 0.34 or 0.26, color:Lerp(Color3.new(0, 0, 0), 0.1), Enum.Material.Wood))
			if not dead then
				local size = random:NextNumber(0.9, 1.4)
				decor(part(parent, Vector3.new(size, size, size), CFrame.new(to), LEAF:Lerp(Color3.new(0, 0, 0), random:NextNumber(0, 0.2)),
					Enum.Material.Grass, Enum.PartType.Ball))
			end
		elseif roll < 0.68 then
			local size = diameter * random:NextNumber(0.42, 0.55)
			decor(part(parent, Vector3.new(size, size, size), CFrame.new(point + side * sign * diameter * 0.4 - Vector3.new(0, diameter * 0.12, 0)),
				color:Lerp(Color3.new(0, 0, 0), 0.18), Enum.Material.Wood, Enum.PartType.Ball))
		elseif dead then
			-- A split in the grain down the flank, and pale lichen beside it.
			local split = random:NextNumber(0.8, 1.6)
			local flank = point + side * sign * diameter * 0.43 - Vector3.new(0, diameter * 0.1, 0)
			decor(rod(parent, flank - along * split / 2, flank + along * split / 2, 0.16, Color3.fromRGB(58, 50, 44), Enum.Material.Wood))
			for _ = 1, 2 do
				local size = random:NextNumber(0.3, 0.5)
				decor(part(parent, Vector3.one * size, CFrame.new(point + side * sign * diameter * 0.45 + along * random:NextNumber(-0.6, 0.6)
					- Vector3.new(0, diameter * random:NextNumber(0.15, 0.3), 0)), Color3.fromRGB(170, 184, 140), Enum.Material.Fabric, Enum.PartType.Ball))
			end
		end
	end
	-- Thick limbs get bark ridges running along their lower flanks, which break up the smooth
	-- look of a big cylinder and hide its joints.
	if run[1].diameter >= 1.8 then
		local ridge = color:Lerp(Color3.new(0, 0, 0), 0.3)
		for _, sign in ipairs({ -1, 1 }) do
			for index = 1, #run - 1 do
				local a, b = run[index], run[index + 1]
				local along = b.position - a.position
				local flat = Vector3.new(along.X, 0, along.Z)
				if along.Magnitude > 0.2 and flat.Magnitude > 1e-3 then
					local side = Vector3.new(-flat.Z, 0, flat.X).Unit * sign
					local function flank(point)
						return point.position + side * point.diameter * 0.42 - Vector3.new(0, point.diameter * 0.26, 0)
					end
					-- Stopped a hair short of each joint: ended exactly there, a ridge's end caps lay in
					-- the same plane as the limb segments' and the build's z-fight pass had to nudge them.
					local from, to = flank(a) + along.Unit * 0.09, flank(b) - along.Unit * 0.09
					if index == #run - 1 then
						to = from:Lerp(to, 0.6)
					end
					decor(rod(parent, from, to, math.max(0.2, a.diameter * 0.1), ridge, Enum.Material.Wood))
				end
			end
		end
	end
	-- Deadwood ends broken, not rounded: splinters standing off the end.
	if dead then
		local tip, before = run[#run], run[#run - 1]
		local along = (tip.position - before.position).Unit
		local flat = Vector3.new(along.X, 0, along.Z)
		local side = flat.Magnitude > 1e-3 and Vector3.new(-flat.Z, 0, flat.X).Unit or Vector3.zAxis
		for splinter = 1, 3 do
			local angle = splinter / 3 * math.pi * 2 + random:NextNumber(-0.4, 0.4)
			local offset = (side * math.cos(angle) + Vector3.yAxis * math.sin(angle)) * tip.diameter * 0.28
			local from = tip.position + offset - along * 0.2
			local to = from + (along + offset.Unit * 0.25).Unit * random:NextNumber(0.5, 1.0)
			decor(rod(parent, from, to, tip.diameter * random:NextNumber(0.18, 0.3), color:Lerp(Color3.new(1, 1, 1), 0.12), Enum.Material.Wood))
		end
	end
end

-- The end of a live limb goes on as twigs: two thin shoots angled up and apart from the rounded
-- tip, each ending in a spray of leaves, so a limb finishes the way a branch does rather than
-- sawn off. Scenery, and all of it past the tip or below its top.
local function twigTip(parent, base, limb, color, random)
	local run = visibleRun(base, limb)
	if #run < 2 then
		return
	end
	local tip, before = run[#run], run[#run - 1]
	local along = tip.position - before.position
	along = along.Magnitude > 1e-3 and along.Unit or Vector3.xAxis
	local flat = Vector3.new(along.X, 0, along.Z)
	local side = flat.Magnitude > 1e-3 and Vector3.new(-flat.Z, 0, flat.X).Unit or Vector3.zAxis
	for _, sign in ipairs({ -1, 1 }) do
		local direction = (along + side * sign * random:NextNumber(0.35, 0.6) + Vector3.new(0, random:NextNumber(0.25, 0.55), 0)).Unit
		-- 0.07 clear of the tip's end cap, not touching it. At `diameter * 0.2` the shoot's face and
		-- the branch's landed 0.03-0.04 apart, inside ZFight's 0.055 tolerance, and the lobby's
		-- written-pairs probe counted 30 flush pairs here. Scenery only (decor is CanCollide and
		-- CanQuery false), so nothing a player stands on or jumps to moves by this.
		local from = tip.position + along * (tip.diameter * 0.2 + 0.07)
		local length = random:NextNumber(1.6, 2.5)
		local knee = from + direction * length * 0.55
		local to = knee + (direction + Vector3.new(0, -0.15, 0) + side * sign * 0.2).Unit * length * 0.45
		decor(rod(parent, from, knee, math.max(0.22, tip.diameter * 0.32), color, Enum.Material.Wood))
		decor(part(parent, Vector3.one * math.max(0.22, tip.diameter * 0.32), CFrame.new(knee), color, Enum.Material.Wood, Enum.PartType.Ball))
		decor(rod(parent, knee, to, 0.18, color, Enum.Material.Wood))
		for leaf = 1, 2 do
			local size = random:NextNumber(0.9, 1.5)
			decor(part(parent, Vector3.one * size, CFrame.new(to + Vector3.new(random:NextNumber(-0.5, 0.5), random:NextNumber(-0.2, 0.4), random:NextNumber(-0.5, 0.5))),
				LEAF:Lerp(Color3.new(0, 0, 0), random:NextNumber(0, 0.18)), Enum.Material.Grass, Enum.PartType.Ball))
		end
	end
end

-- Where a crown limb comes out of the canopy, a ruff of leaves round it on the sides and
-- underneath, so it grows out of the foliage instead of being stuck into a ball.
local function leafRuff(parent, base, limb, random)
	local run = visibleRun(base, limb)
	if #run < 2 then
		return
	end
	local root = run[1]
	local along = (run[2].position - root.position)
	along = along.Magnitude > 1e-3 and along.Unit or Vector3.xAxis
	local flat = Vector3.new(along.X, 0, along.Z)
	local side = flat.Magnitude > 1e-3 and Vector3.new(-flat.Z, 0, flat.X).Unit or Vector3.zAxis
	for index = 1, 5 do
		-- Round the lower half only, from low on one side, under, to low on the other: a ball any
		-- higher up the flank would sit in the legs of whoever's walking out along the limb.
		local angle = math.pi * (0.2 + 0.15 * (index - 1))
		local size = random:NextNumber(1.7, 2.5)
		local offset = side * math.cos(angle) * (root.diameter * 0.5 + size * 0.3) - Vector3.new(0, math.sin(angle) * (root.diameter * 0.5 + size * 0.25), 0)
		decor(part(parent, Vector3.one * size, CFrame.new(root.position + offset - along * random:NextNumber(0.2, 0.9)),
			LEAF:Lerp(Color3.new(0, 0, 0), random:NextNumber(0.02, 0.2)), Enum.Material.Grass, Enum.PartType.Ball))
	end
end

-- A lantern on a cord under a limb, `from` being the limb's underside.
local function hangLantern(parent, from, color)
	local cord = 2.2
	decor(part(parent, Vector3.new(0.12, cord, 0.12), CFrame.new(from - Vector3.new(0, cord / 2, 0)), DARK, Enum.Material.Fabric))
	decor(part(parent, Vector3.new(1.3, 0.25, 1.3), CFrame.new(from - Vector3.new(0, cord, 0)), IRON, Enum.Material.Metal))
	local glass = decor(part(parent, Vector3.new(1, 1.4, 1), CFrame.new(from - Vector3.new(0, cord + 0.8, 0)), color, Enum.Material.Neon))
	pointLight(glass, color, 18, 1.1)
end

-- The hinge a springy limb flaps about: an invisible part at the limb's first point, its X axis
-- the level line across the limb. Everything built under it moves with it. Built unparented, so
-- the whole limb reaches a client in one piece.
local function springHinge(base, limb)
	local first, second = limb.points[1], limb.points[2]
	local flat = Vector3.new(second[1] - first[1], 0, second[3] - first[3])
	local across = flat.Magnitude > 1e-3 and Vector3.new(-flat.Z, 0, flat.X).Unit or Vector3.xAxis
	local hinge = decor(part(nil, Vector3.new(0.4, 0.4, 0.4), CFrame.fromMatrix(at(base, first), across, Vector3.yAxis), LIVEWOOD))
	hinge.Transparency = 1
	hinge.Name = "SpringHinge"
	hinge:SetAttribute("SwayAxis", "X")
	hinge:SetAttribute("SwayAngle", limb.flap.angle)
	hinge:SetAttribute("SwaySpeed", limb.flap.speed)
	hinge:SetAttribute("SwayPhase", limb.flap.phase)
	CollectionService:AddTag(hinge, "AmbientSway")
	return hinge
end

-- Deadwood: creaks and reddens the moment someone lands on it, snaps `hold` seconds later while a
-- copy tumbles away, and grows back SNAP_REGROW after that. `model` holds the limb and its dressing.
local function deadwood(model, hold)
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, { part = descendant, color = descendant.Color, transparency = descendant.Transparency,
				collide = descendant.CanCollide, query = descendant.CanQuery })
		end
	end
	if #parts == 0 then
		return
	end
	local creak = climbSound(parts[1].part, CREAK_SOUND, 0.45, 0.5)
	local snap = climbSound(parts[1].part, SNAP_SOUND, 0.9, 0.72)
	local busy = false

	local function regrow()
		if not model.Parent then
			return
		end
		for _, entry in ipairs(parts) do
			entry.part.Color = entry.color
			TweenService:Create(entry.part, TweenInfo.new(0.5), { Transparency = entry.transparency }):Play()
		end
		task.delay(0.5, function()
			for _, entry in ipairs(parts) do
				entry.part.CanCollide = entry.collide
				entry.part.CanQuery = entry.query
			end
			busy = false
		end)
	end

	local function breakOff()
		if not model.Parent then
			return
		end
		snap:Play()
		local falling = Instance.new("Model")
		falling.Name = "SnappedDeadwood"
		local root = nil
		for _, entry in ipairs(parts) do
			local copy = entry.part:Clone()
			copy:ClearAllChildren()
			copy.Anchored = false
			copy.CanCollide = false
			copy.CanQuery = false
			copy.CanTouch = false
			copy.Parent = falling
			if root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0, weld.Part1 = root, copy
				weld.Parent = copy
			else
				root = copy
			end
			entry.part.Transparency = 1
			entry.part.CanCollide = false
			entry.part.CanQuery = false
		end
		falling.Parent = model.Parent
		root.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 5
		Debris:AddItem(falling, 2.5)
		task.delay(SNAP_REGROW, regrow)
	end

	local function onTouched(hit)
		if busy or not livingPlayerFromHit(hit) then
			return
		end
		busy = true
		creak:Play()
		for _, entry in ipairs(parts) do
			if entry.collide then
				entry.part.Color = entry.color:Lerp(CRACKING, 0.6)
			end
		end
		task.delay(hold, breakOff)
	end
	for _, entry in ipairs(parts) do
		if entry.collide then
			entry.part.Touched:Connect(onTouched)
		end
	end
end

-- A glowing blob of sap under a checkpoint limb, with sparks for when someone reaches it.
local function sapKnot(parent, position, number)
	local knot = decor(part(parent, Vector3.new(1.3, 1.3, 1.3), CFrame.new(position), SAP, Enum.Material.Neon, Enum.PartType.Ball))
	knot.Name = "SapKnot"
	pointLight(knot, SAP, 16, 1.4)
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(SAP, Color3.fromRGB(255, 240, 180))
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	sparks.Lifetime = NumberRange.new(0.6, 1.1)
	sparks.Speed = NumberRange.new(4, 9)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Rate = 0
	sparks.Parent = knot
	billboard(knot, "CHECKPOINT " .. number, SAP, Vector3.new(0, 2.4, 0), 5, 1.1, 70)
	return knot, sparks
end

-- A thorn rotor: thorny arms on a hub turning about the vertical (AmbientSway spin). Round the
-- trunk the hub hides in a bark collar; out on a limb it's a knot on a twig growing up beside it.
-- The thorns stick out sideways only, in the plane the arms turn in, so what you see sweeping is
-- no taller than what can hit you, which is what tools/climb_design.py cleared the limbs for.
local function thornRotor(model, base, spec)
	local centre = at(base, spec.hub)
	local hub, inner
	if spec.aroundTrunk then
		local radius = trunkRadiusAt(spec.hub[2])
		hub = decor(part(model, Vector3.new(1, 1, 1), CFrame.new(centre), LIVEWOOD_DARK))
		hub.Transparency = 1
		inner = radius + 0.35
		decor(part(hub, Vector3.new(1.4, (radius + 0.55) * 2, (radius + 0.55) * 2), CFrame.new(centre) * CFrame.Angles(0, 0, math.pi / 2),
			LIVEWOOD_DARK, Enum.Material.Wood, Enum.PartType.Cylinder))
	else
		-- A gnarled knot on a crooked twig growing up out of the limb, a couple of leaves on it.
		hub = decor(part(model, Vector3.new(1.2, 1.2, 1.2), CFrame.new(centre), THORNWOOD, Enum.Material.Wood, Enum.PartType.Ball))
		decor(part(hub, Vector3.one * 0.8, CFrame.new(centre + Vector3.new(0.35, 0.25, -0.2)), THORNWOOD, Enum.Material.Wood, Enum.PartType.Ball))
		inner = 0.45
		if spec.post then
			-- The twig grows from the limb's flank on the hub's side, not its top, so it isn't
			-- standing in the path of anyone walking out along the limb.
			local axis = at(base, spec.post)
			local toward = (centre - axis) * Vector3.new(1, 0, 1)
			toward = toward.Magnitude > 1e-3 and toward.Unit or Vector3.xAxis
			local foot = axis + toward * 0.95 - Vector3.new(0, 0.35, 0)
			local knee = foot:Lerp(centre - Vector3.new(0, 0.5, 0), 0.5) + toward * 0.8
			decor(rod(model, foot, knee, 0.5, LIVEWOOD, Enum.Material.Wood))
			decor(part(model, Vector3.one * 0.5, CFrame.new(knee), LIVEWOOD, Enum.Material.Wood, Enum.PartType.Ball))
			decor(rod(model, knee, centre - Vector3.new(0, 0.5, 0), 0.42, LIVEWOOD, Enum.Material.Wood))
			decor(part(model, Vector3.one * 1.1, CFrame.new(knee + toward * 0.8 - Vector3.new(0, 0.2, 0)), LEAF, Enum.Material.Grass, Enum.PartType.Ball))
		end
	end
	hub.Name = "ThornRotor"
	-- Each arm is a dark thorny switch: the solid rod the design cleared, thorns curling off both
	-- sides in the plane it turns in, a red point on every thorn and a claw of three at the end.
	for index = 0, spec.arms - 1 do
		local angle = index / spec.arms * math.pi * 2
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local across = Vector3.new(-out.Z, 0, out.X)
		rod(hub, centre + out * inner, centre + out * spec.arm, spec.thickness, THORNWOOD, Enum.Material.Wood).Name = "ThornArm"
		local spikes = math.max(2, math.floor((spec.arm - inner) / 0.62))
		for spike = 1, spikes do
			local along = inner + (spike - 0.5) * (spec.arm - inner) / spikes
			local root = centre + out * along
			local sign = spike % 2 == 0 and 1 or -1
			local length = spec.thickness / 2 + 0.5 + 0.3 * (1 - along / spec.arm)
			local tip = root + (across * sign + out * 0.55).Unit * length
			decor(rod(hub, root, root:Lerp(tip, 0.55), 0.24, THORNWOOD, Enum.Material.Wood))
			decor(rod(hub, root:Lerp(tip, 0.5), tip, 0.13, THORNWOOD, Enum.Material.Wood))
			decor(part(hub, Vector3.one * 0.24, CFrame.new(tip), THORN, Enum.Material.Neon, Enum.PartType.Ball))
		end
		local claw = centre + out * spec.arm
		for prong = -1, 1 do
			local tip = claw + (out + across * prong * 0.7).Unit * 0.55
			decor(rod(hub, claw - out * 0.15, tip, 0.16, THORNWOOD, Enum.Material.Wood))
			decor(part(hub, Vector3.one * 0.2, CFrame.new(tip), THORN, Enum.Material.Neon, Enum.PartType.Ball))
		end
	end
	hub:SetAttribute("SwayAxis", "Y")
	hub:SetAttribute("SwaySpin", spec.speed)
	CollectionService:AddTag(hub, "AmbientSway")
	return hub
end

local function buildCloudClimb(lobby, base)
	local course = CloudClimbCourse
	local random = Random.new(2609)
	local lanternColors = { GOLD, PINK, SAP }
	local lanterns = 0
	local floors = climbFloors(course)
	local checkpoints, firstCheckpoint = 0, nil
	for _, element in ipairs(course.elements) do
		if element.checkpoint then
			checkpoints += 1
			firstCheckpoint = firstCheckpoint or element.name
		end
	end

	-- The start root (re)starts a run, unless it already has a checkpoint; the first fork only
	-- starts one if there isn't one going, so falling back onto it changes nothing.
	local function startRun(player, restart)
		local run = climbRuns[player]
		if run and (run.checkpoint or not restart) then
			return
		end
		climbRuns[player] = { started = wallNow() }
	end

	for index, element in ipairs(course.elements) do
		local model = Instance.new("Model")
		model.Name = "Climb " .. element.name
		-- Reaches a client whole, so a springy limb's hinge never arrives without the limb on it.
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		local solids = {}

		for limbIndex, limb in ipairs(element.limbs) do
			local wood = (limb.dead and DEADWOOD) or (limb.motion == "flap" and SPRINGWOOD) or (element.kind == "start" and LIVEWOOD_DARK) or LIVEWOOD
			local color = wood:Lerp(Color3.new(0, 0, 0), random:NextNumber(0, 0.12))
			local holder = model
			if limb.motion == "flap" then
				holder = springHinge(base, limb)
			elseif limb.motion == "snap" then
				holder = Instance.new("Model")
				holder.Name = "Deadwood"
			end
			for _, piece in ipairs(climbLimb(holder, base, limb, color)) do
				if piece.CanCollide then
					table.insert(solids, piece)
				end
			end
			dressLimb(holder, base, limb, color, random, limb.dead)
			local points = limb.points
			if limb.roundTip and element.kind ~= "start" then
				local tip = at(base, points[#points])
				local out = (tip - at(base, points[#points - 1])) * Vector3.new(1, 0, 1)
				leafTuft(holder, tip, out.Magnitude > 1e-3 and out.Unit or Vector3.xAxis, points[#points][4], random,
					element.kind == "bough" and 3 or 2)
				twigTip(holder, base, limb, color, random)
			end
			-- A crown limb's visible part starts where it leaves the leaves.
			if element.kind == "stub" and limb.solidFrom <= #points - 1 then
				leafRuff(holder, base, limb, random)
			end
			-- A lantern under each fork's landing limb lights the climb up the trunk, in the shade
			-- of the leaves.
			if element.kind == "fork" and limbIndex == 1 then
				lanterns += 1
				local middle = points[2]
				hangLantern(holder, at(base, middle) - Vector3.new(0, middle[4] / 2 - 0.25, 0), lanternColors[(lanterns % #lanternColors) + 1])
			end
			if limb.motion == "snap" then
				deadwood(holder, SNAP_HOLD[element.kind] or 0.8)
			end
			if holder ~= model then
				holder.Parent = model
			end
		end

		for _, ball in ipairs(element.balls or {}) do
			local size = ball[4]
			local centre = at(base, ball)
			local knot = part(model, Vector3.new(size, size, size), CFrame.new(centre), element.kind == "knob" and LIVEWOOD_DARK or LIVEWOOD,
				Enum.Material.Wood, Enum.PartType.Ball)
			knot.Name = element.kind == "knob" and "ClimbKnob" or "ClimbBranch"
			table.insert(solids, knot)
			if element.kind == "knob" then
				local out = (centre - base) * Vector3.new(1, 0, 1)
				leafTuft(model, centre, out.Magnitude > 1e-3 and out.Unit or Vector3.xAxis, size, random, 2)
			end
		end
		-- Where a fork leaves the trunk the bark swells round it, as it does round a real branch.
		for _, collar in ipairs(element.collars or {}) do
			local from, to = at(base, collar.from), at(base, collar.to)
			for step, share in ipairs({ 0.92, 0.74 }) do
				local size = collar.diameter * share
				-- Sunk a little, so the swelling stays under the top of the knot you walk across.
				decor(part(model, Vector3.one * size, CFrame.new(from:Lerp(to, 0.35 + step * 0.22) - Vector3.new(0, collar.diameter * 0.2, 0)),
					BARK:Lerp(LIVEWOOD, 0.3 * step),
					Enum.Material.Wood, Enum.PartType.Ball)).Name = "BranchCollar"
			end
		end

		if element.checkpoint then
			local number = element.checkpoint
			local spot, sapAt
			if element.kind == "fork" then
				-- Back on the knot, facing out along the limb you leave from.
				local ball = element.balls[1]
				local centre = at(base, ball)
				local stand = centre + Vector3.new(0, ball[4] / 2 + 3, 0)
				local climbing = element.limbs[2].points
				spot = CFrame.lookAt(stand, stand + (at(base, climbing[#climbing]) - centre) * Vector3.new(1, 0, 1))
				sapAt = centre - Vector3.new(0, ball[4] / 2 + 0.25, 0)
			else
				local limb = element.limbs[#element.limbs]
				local from, to = at(base, limb.points[limb.solidFrom]), at(base, limb.points[#limb.points])
				local width = (limb.points[limb.solidFrom][4] + limb.points[#limb.points][4]) / 2
				local stand = from:Lerp(to, 0.55) + Vector3.new(0, width / 2 + 3, 0)
				spot = CFrame.lookAt(stand, stand + (to - from) * Vector3.new(1, 0, 1))
				sapAt = from:Lerp(to, 0.3) - Vector3.new(0, width / 2 + 0.3, 0)
				-- A checkpoint limb is a sturdy one that forks: a leafy shoot curves up and away off
				-- its side, on the side away from the next jump, so it reads as a branch and not a stump.
				local along = to - from
				local flat = Vector3.new(along.X, 0, along.Z)
				local side = Vector3.new(-flat.Z, 0, flat.X).Unit
				local following = course.elements[index + 1]
				if following then
					local limbs = following.limbs
					local ahead = at(base, limbs[#limbs].points[#limbs[#limbs].points])
					if (ahead - from):Dot(side) > 0 then
						side = -side
					end
				end
				local root = from:Lerp(to, 0.45) + side * width * 0.3 - Vector3.new(0, width * 0.1, 0)
				local knee = root + side * 1.8 + along.Unit * 1.0 + Vector3.new(0, 1.1, 0)
				local shootTip = knee + side * 1.4 + along.Unit * 1.4 + Vector3.new(0, 1.3, 0)
				decor(rod(model, root, knee, width * 0.42, LIVEWOOD, Enum.Material.Wood))
				decor(part(model, Vector3.one * width * 0.42, CFrame.new(knee), LIVEWOOD, Enum.Material.Wood, Enum.PartType.Ball))
				decor(rod(model, knee, shootTip, width * 0.28, LIVEWOOD, Enum.Material.Wood))
				for leaf = 1, 4 do
					local size = random:NextNumber(1.3, 2.1)
					decor(part(model, Vector3.one * size, CFrame.new(shootTip + Vector3.new(random:NextNumber(-0.9, 0.9), random:NextNumber(-0.3, 0.8), random:NextNumber(-0.9, 0.9))),
						LEAF:Lerp(Color3.new(0, 0, 0), random:NextNumber(0, 0.18)), Enum.Material.Grass, Enum.PartType.Ball))
				end
			end
			local sap, sparks = sapKnot(model, sapAt, number)
			local ping = climbSound(sap, CHECKPOINT_SOUND, 0.6, 0.8)
			for _, piece in ipairs(solids) do
				piece.Touched:Connect(function(hit)
					local player = livingPlayerFromHit(hit)
					local run = player and climbRuns[player]
					if not run or not climbCheckpointCounts(run, number, floors[element.name], wallNow()) then
						return
					end
					run.checkpoint, run.spot = number, spot
					sparks:Emit(28)
					ping:Play()
					StateSync.Notify(player, string.format("Checkpoint %d of %d: %s. If you fall, the Sap Lantern at the foot of the tree brings you back here.",
						number, checkpoints, element.name))
				end)
			end
		end

		if element.kind == "start" or index == 2 then
			local restart = element.kind == "start"
			for _, piece in ipairs(solids) do
				piece.Touched:Connect(function(hit)
					local player = livingPlayerFromHit(hit)
					if player then
						startRun(player, restart)
					end
				end)
			end
			if restart then
				-- Where the root breaks up through the paving: shards of it, tipped up round the root.
				local points = element.limbs[1].points
				local under, over = at(base, points[1]), at(base, points[2])
				local emerge = under:Lerp(over, (base.Y - under.Y) / (over.Y - under.Y))
				for shard = 1, 6 do
					local angle = shard / 6 * math.pi * 2 + random:NextNumber(-0.3, 0.3)
					local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * random:NextNumber(1.6, 2.6)
					decor(part(model, Vector3.new(random:NextNumber(1.1, 1.8), 0.3, random:NextNumber(0.8, 1.3)),
						CFrame.new(emerge + offset + Vector3.new(0, 0.22, 0)) * CFrame.Angles(0, -angle, 0) * CFrame.Angles(0, 0, random:NextNumber(0.25, 0.5)),
						shard % 2 == 0 and PLAZA or PLAZA_DARK, Enum.Material.Marble))
				end
				local knee = at(base, points[#points - 1])
				local marker = decor(part(model, Vector3.new(0.2, 0.2, 0.2), CFrame.new(knee + Vector3.new(0, 1.6, 0)), GREEN))
				marker.Transparency = 1
				billboard(marker, "START", GREEN, Vector3.new(0, 2.4, 0), 5, 1.3, 90)
			end
		end

		model.Parent = lobby
	end

	for _, spec in ipairs(course.rotors) do
		local model = Instance.new("Model")
		model.Name = "Climb " .. spec.name
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		thornRotor(model, base, spec)
		model.Parent = lobby
	end

	-- The summit, on the tree's leader: its topmost shoot, up through the middle of the leaves.
	-- All scenery but the golden disc on top.
	local summitTop, summitDiameter = course.summitTop, course.summitDiameter
	local summitCenter = base + Vector3.new(0, summitTop, 0)
	local crownY = CANOPY[1][1].Y
	local leaderFoot = course.trunk.height - 1
	decor(column(lobby, crownY - leaderFoot, 4.2, base + Vector3.new(0, leaderFoot, 0), BARK, Enum.Material.Wood)).Name = "Leader"
	decor(column(lobby, summitTop - 1.6 - crownY, 2.8, base + Vector3.new(0, crownY, 0), BARK, Enum.Material.Wood)).Name = "Leader"
	decor(disc(lobby, 4.6, 1.45, summitCenter - Vector3.new(0, 2.4, 0), BARK, Enum.Material.Wood))
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + 0.4
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local from = summitCenter - Vector3.new(0, 5.5 + index * 0.9, 0) + out * 1.1
		local to = from + (out * 1.6 + Vector3.new(0, 0.5, 0))
		decor(rod(lobby, from, to, 0.3, LIVEWOOD, Enum.Material.Wood))
		decor(part(lobby, Vector3.new(1.3, 1.3, 1.3), CFrame.new(to), LEAF, Enum.Material.Grass, Enum.PartType.Ball))
	end
	-- The leader forks into a cradle of five curving shoots that hold the nest up at its rim.
	for index = 0, 4 do
		local angle = index / 5 * math.pi * 2 + 0.9
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local foot = summitCenter + out * 1.2 - Vector3.new(0, 7.2, 0)
		local knee = summitCenter + out * 2.9 - Vector3.new(0, 4.6, 0)
		local top = summitCenter + out * (summitDiameter / 2 - 0.6) - Vector3.new(0, 1.7, 0)
		decor(rod(lobby, foot, knee, 0.6, BARK, Enum.Material.Wood))
		decor(part(lobby, Vector3.one * 0.6, CFrame.new(knee), BARK, Enum.Material.Wood, Enum.PartType.Ball))
		decor(rod(lobby, knee, top, 0.45, BARK, Enum.Material.Wood))
		decor(part(lobby, Vector3.one * 1.2, CFrame.new(knee + out * 0.6 - Vector3.new(0, 0.3, 0)), LEAF, Enum.Material.Grass, Enum.PartType.Ball))
	end
	local summit = disc(lobby, summitDiameter, 1, summitCenter - Vector3.new(0, 1, 0), GOLD, Enum.Material.Foil)
	summit.Name = "SummitDisc"
	-- A glowing rim: a neon disc sunk inside the gold one, so only its edge shows.
	decor(disc(lobby, summitDiameter + 0.6, 0.3, summitCenter - Vector3.new(0, 0.6, 0), Color3.fromRGB(255, 240, 170), Enum.Material.Neon))
	pointLight(summit, GOLD, 34, 2)
	-- A nest of woven twigs under the rim.
	for index = 0, 11 do
		local function rim(step, low)
			local angle = step / 12 * math.pi * 2
			return summitCenter + Vector3.new(math.cos(angle) * (summitDiameter / 2 - 0.3), -1.35 - (low and 0.35 or 0), math.sin(angle) * (summitDiameter / 2 - 0.3))
		end
		decor(rod(lobby, rim(index, index % 2 == 1), rim(index + 1.3, index % 2 == 0), 0.45, LIVEWOOD, Enum.Material.Wood))
	end
	local def = BrainrotData.Get("Golden Sahur")
	if def then
		local scale = 1.1
		local size = def.look and def.look.size or 1
		local metrics = BrainrotModels.Metrics(def)
		local foot = summitCenter + Vector3.new(0, -metrics.bottom * scale * size, -2.6)
		local trophy = BrainrotModels.Build(def, { scale = scale, glow = GOLD, cframe = CFrame.lookAt(foot, foot + Vector3.new(0, 0, 1)) })
		trophy.Name = "SkyWalkTrophy"
		trophy.Parent = lobby
	end
	local padPosition = summitCenter + Vector3.new(0, 0.1, 1.9)
	local pad = decor(disc(lobby, 3.4, 0.3, padPosition, GREEN, Enum.Material.Neon))
	pad.CanTouch = true
	pad.Name = "SkyWalkSummit"
	billboard(pad, "SUMMIT", GOLD, Vector3.new(0, 5, 0), 6, 1.4)

	-- Out on the plaza by the start root: the sign, and the Sap Lantern.
	local rootPoint = course.elements[1].limbs[1].points[2]
	local rootAt = Vector3.new(rootPoint[1], 0, rootPoint[3])
	local outward = rootAt.Unit
	local sideways = Vector3.new(-outward.Z, 0, outward.X)

	local signPosition = base + rootAt + outward * 4 + sideways * 6.5
	local sign = part(lobby, Vector3.new(13, 5.6, 0.4), CFrame.lookAt(signPosition + Vector3.new(0, 5.2, 0), signPosition + Vector3.new(0, 5.2, 0) + outward),
		Color3.fromRGB(40, 36, 44), Enum.Material.Slate)
	sign.Name = "ClimbSign"
	-- Posts, and the lantern's post and plate below, stand a tenth of a stud down in the paving: set
	-- on its surface their bottoms were flush with the paving discs' own.
	for _, x in ipairs({ -5.5, 5.5 }) do
		part(lobby, Vector3.new(0.6, 2.7, 0.6), CFrame.new(signPosition + Vector3.new(0, 1.25, 0)) * CFrame.new(sign.CFrame.RightVector * x),
			WOOD_DARK, Enum.Material.Wood)
	end
	local labels = surfaceText(sign, Enum.NormalId.Front, {
		{ y = 0, h = 0.34, text = "CLOUD CLIMB", color = GOLD },
		{ y = 0.34, h = 0.2, text = "Branches all the way up. Deadwood snaps. Thorns sweep.", color = WHITE, font = Enum.Font.GothamBold },
		{ y = 0.54, h = 0.17, text = string.format("Sprint for the long leaps  -  %d checkpoints  -  the Sap Lantern takes you back", checkpoints),
			color = MUTED, font = Enum.Font.GothamBold },
		{ y = 0.72, h = 0.26, text = "", color = GREEN, font = Enum.Font.GothamBold },
	}, 30)
	obbyBestLabel = labels[4]
	-- Names the sprint key where the player is told to sprint: nothing else on screen ever does, and
	-- the sprint leaps cannot be made without it (#86). Filled per player by KeyHintClient; a pad or a
	-- touch screen keeps the key-free line above.
	keyHint(labels[3], string.format("Hold [{Sprint}] for the long leaps  -  %d checkpoints  -  the Sap Lantern takes you back", checkpoints))
	renderObbyBest()

	local lanternPosition = base + rootAt + outward * 4 - sideways * 6
	part(lobby, Vector3.new(2.2, 0.6, 2.2), CFrame.new(lanternPosition + Vector3.new(0, 0.2, 0)), WOOD_DARK, Enum.Material.Wood)
	-- The post starts 0.1 INSIDE its base rather than level with it. `column` puts its base at the
	-- point given, and the plinth above spans lanternPosition.y -0.1 to +0.5, so starting the post
	-- at -0.1 put both undersides on the same plane — one written flush pair, found by the lobby's
	-- written-pairs probe. Height drops by the same 0.2 so the top, and the lantern on it, do not
	-- move at all.
	column(lobby, 7.4, 0.7, lanternPosition + Vector3.new(0, 0.1, 0), WOOD_DARK, Enum.Material.Wood)
	local reach = -sideways
	decor(beam(lobby, lanternPosition + Vector3.new(0, 7.1, 0), lanternPosition + Vector3.new(0, 7.1, 0) + reach * 2.2, 0.4, WOOD_DARK, Enum.Material.Wood))
	local hangAt = lanternPosition + reach * 2 + Vector3.new(0, 6.9, 0)
	decor(part(lobby, Vector3.new(0.12, 1, 0.12), CFrame.new(hangAt - Vector3.new(0, 0.5, 0)), DARK, Enum.Material.Fabric))
	decor(part(lobby, Vector3.new(1.7, 0.3, 1.7), CFrame.new(hangAt - Vector3.new(0, 1, 0)), IRON, Enum.Material.Metal))
	local glass = decor(part(lobby, Vector3.new(1.4, 1.9, 1.4), CFrame.new(hangAt - Vector3.new(0, 2.05, 0)), SAP, Enum.Material.Neon))
	glass.Name = "SapLantern"
	pointLight(glass, SAP, 22, 1.6)
	billboard(glass, "SAP LANTERN", SAP, Vector3.new(0, 2.2, 0), 6, 1.2, 60)

	local back = Instance.new("ProximityPrompt")
	back.Name = "BackToCheckpoint"
	back.ActionText = "Back to checkpoint"
	back.ObjectText = "Sap Lantern"
	back.HoldDuration = 0
	back.MaxActivationDistance = 11
	back.RequiresLineOfSight = false
	back.Parent = glass
	back.Triggered:Connect(function(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (root and humanoid and humanoid.Health > 0) or (root.Position - base).Magnitude > LANTERN_RANGE then
			return
		end
		local run = climbRuns[player]
		if not (run and run.spot) then
			StateSync.Notify(player, string.format("No checkpoint yet. Step onto the start root, then reach the first: %s.", firstCheckpoint or "?"), true)
			return
		end
		character:PivotTo(run.spot)
	end)

	local over = Instance.new("ProximityPrompt")
	over.Name = "StartOver"
	over.ActionText = "Start over"
	over.ObjectText = "Cloud Climb"
	-- H and B: F is the Ready key (Settings), and within 11 studs of the lantern the ready key showed a
	-- Start-over ring and a held press wiped the run; Y is the companion's (CombatClient). Neither H
	-- nor B is bound to anything a player does beside the lantern (#86).
	over.KeyboardKeyCode = Enum.KeyCode.H
	over.GamepadKeyCode = Enum.KeyCode.ButtonB
	over.HoldDuration = 0.8
	over.MaxActivationDistance = 11
	over.RequiresLineOfSight = false
	over.Parent = glass
	over.Triggered:Connect(function(player)
		climbRuns[player] = nil
		StateSync.Notify(player, "Run cleared. The clock starts again when you step onto the start root.")
	end)

	-- No ledge-grabbing anywhere on the climb or the tree it's built on: every jump here is
	-- measured against a plain jump, and a mantle up the trunk or onto the next limb would skip
	-- them. The mantle and vault honour NoMantle on a part or any of its ancestors; the climb is
	-- many models plus loose trunk and root parts, so every one of them carries it.
	for _, descendant in ipairs(lobby:GetDescendants()) do
		if descendant:IsA("BasePart") or descendant:IsA("Model") then
			local group = descendant:GetAttribute("Group")
			local isClimbModel = descendant:IsA("Model") and string.sub(descendant.Name, 1, 6) == "Climb "
			if isClimbModel or group == "CloudClimb" or (group == "Tree" and (descendant.Name == "Trunk" or descendant.Name == "Root")) then
				descendant:SetAttribute("NoMantle", true)
			end
		end
	end

	pad.Touched:Connect(function(hit)
		local player = livingPlayerFromHit(hit)
		local run = player and climbRuns[player]
		if not run then
			return
		end
		climbRuns[player] = nil
		local seconds, missing = climbSummitVerdict(run, checkpoints, floors.Summit, wallNow())
		if not seconds then
			StateSync.Notify(player, string.format("That run skipped %s, so it doesn't count. Step onto the start root to climb again.", missing), true)
			return
		end
		local isRecord = obbyBest == nil or seconds < obbyBest.seconds
		if isRecord then
			obbyBest = { name = player.DisplayName, seconds = seconds }
			renderObbyBest()
		end
		-- First clear of the PROFILE: counting per server let the 250 coins be collected again on
		-- every server a player visited. A profile still loading pays nothing now and counts nothing.
		local data = PlayerData.Get(player)
		local firstClear = data ~= nil and data.Stats.climbs == 0
		if data then
			data.Stats.climbs += 1
		end
		playgroundFx:FireAllClients({ kind = "summit", position = padPosition, color = GOLD })
		LobbyService.OnObbyComplete(player, seconds, firstClear, isRecord)
	end)
end

--------------------------------------------------------------------------------
-- Wayfinding (lobby v2): the Rot Road and the district gates
--------------------------------------------------------------------------------
-- A new player lands on the pier facing a plaza full of things. The Rot Road takes them round it:
-- a raised purple-stone road with glowing studs down its middle, from the pier head to the statue,
-- then forking east to the firing range, west past the pitch and on to Market Row, and along the
-- stalls to the crates and the Daily Spin. Each district has a gate over its way in, in the
-- district's colour, its name on a board both ways, a Rotling (the island's goggle-eyed blob
-- mascot) on top and two banners swinging under the lintel (AmbientSway, on the client). Nothing
-- here is interactive and nothing moves on the server.
--
-- Everything stands clear of the showcase podiums' slots (tools/showcase_layout_check.py) and of
-- every other set piece, rests on the paving or the pier, and is held to its own part budget
-- (tools/lobby_layout_check.py, which also walks the island from the spawn to every prompt).

-- One local out of this block (the main chunk is near Luau's 200-local limit).
local buildWayfinding
do
	local ROAD_BED = Color3.fromRGB(86, 66, 112)
	local ROAD_KERB = Color3.fromRGB(58, 44, 78)
	local ROAD_TOP = 0.36
	local ROAD_WIDTH = 3.4
	local STUD_SPACING = 8

	-- Road legs as points on the plaza (x, z from the centre). Clear of the podium slots by 10 studs or
	-- more, of the gold ring round the tree, and of the arena's ramps.
	local ROAD_LEGS = {
		{ color = GOLD, points = { { 0, 95 }, { 0, 44 } } },
		{ color = SKY, points = { { 0, 52 }, { 28, 8 } } },
		{ color = GREEN, points = { { 0, 52 }, { -18, 26 }, { -22, 23 }, { -39.5, 22 }, { -41.5, 16 }, { -42, -29 } } },
		{ color = PINK, points = { { -42, -29 }, { -47.3, -35 }, { -46.2, -38.6 } } },
		{ color = PINK, arc = { radius = 60, from = 220, to = 245, step = 5 } },
		{ color = GOLD, arc = { radius = 60, from = 245, to = 280, step = 5 } },
	}

	-- The district gates: where (x, z), the way a player walks through (degrees, 0 = +X), the span
	-- between the pillars, and what they say.
	local GATES = {
		{ key = "Range", x = 31, z = 0, heading = 0, span = 38, height = 13, color = SKY, title = "FIRING RANGE",
			subtitle = "Take a gun off the podium, shoot the targets" },
		{ key = "Pitch", x = -47, z = 0, heading = 180, span = 14, height = 8, floor = 0.25, color = GREEN, title = "PLAY BALL",
			subtitle = "Kick a ball into the goal for coins" },
		{ key = "Market", degrees = 240, radius = 60, tangent = true, span = 11, height = 11, color = PINK, title = "MARKET ROW",
			subtitle = "Trading Hall  -  Cosmetics" },
		{ key = "Crates", degrees = 270, radius = 60, tangent = true, span = 11, height = 11, color = GOLD, title = "CRATES + SPIN",
			subtitle = "Open crates at the altar, spin the wheel daily" },
		{ key = "Ship", x = 0, z = 125.5, heading = 90, span = 12, height = 11, floor = 0.55, color = GREEN, title = "ALL ABOARD",
			subtitle = "Stand on the pad on deck to ready up" },
	}

	-- Banners hang this far under the lintel's underside (0 = from it).
	local BANNER_DROP = 0

	local function roadSegment(lobby, base, a, b, color)
		local from = base + Vector3.new(a[1], 0, a[2])
		local to = base + Vector3.new(b[1], 0, b[2])
		local length = (to - from).Magnitude
		-- One stud of overlap each end so legs meet without a gap at the corners.
		local frame = CFrame.lookAt(from:Lerp(to, 0.5), to)
		local bed = part(lobby, Vector3.new(ROAD_WIDTH, ROAD_TOP - 0.05, length + 1), frame + Vector3.new(0, 0.05 + (ROAD_TOP - 0.05) / 2, 0),
			ROAD_BED, Enum.Material.Slate)
		bed.Name = "RotRoad"
		for _, side in ipairs({ -1, 1 }) do
			decor(part(lobby, Vector3.new(0.3, ROAD_TOP - 0.02, length + 1),
				frame * CFrame.new(side * (ROAD_WIDTH / 2 + 0.1), 0.05 + (ROAD_TOP - 0.02) / 2, 0), ROAD_KERB, Enum.Material.Cobblestone))
		end
		local studs = math.max(1, math.floor(length / STUD_SPACING))
		for index = 1, studs do
			local at = from:Lerp(to, (index - 0.5) / studs)
			local glow = decor(part(lobby, Vector3.new(1.1, 0.12, 1.1),
				CFrame.lookAt(at, at + (to - from)) * CFrame.new(0, ROAD_TOP + 0.02, 0) * CFrame.Angles(0, math.rad(45), 0), color, Enum.Material.Neon))
			glow.Name = "RoadStud"
		end
	end

	local function buildRoad(lobby, base)
		for _, leg in ipairs(ROAD_LEGS) do
			if leg.arc then
				local points = {}
				for degrees = leg.arc.from, leg.arc.to, leg.arc.step do
					local angle = math.rad(degrees)
					table.insert(points, { math.cos(angle) * leg.arc.radius, math.sin(angle) * leg.arc.radius })
				end
				for index = 1, #points - 1 do
					roadSegment(lobby, base, points[index], points[index + 1], leg.color)
				end
			else
				for index = 1, #leg.points - 1 do
					roadSegment(lobby, base, leg.points[index], leg.points[index + 1], leg.color)
				end
			end
		end
	end

	-- The Rotling: a round blob in the district's colour with two goggle eyes, sat on the lintel.
	local function rotling(lobby, seatFrame, color, size)
		local body = part(lobby, Vector3.one * size, seatFrame * CFrame.new(0, size * 0.5 - 0.25, 0), color, Enum.Material.SmoothPlastic,
			Enum.PartType.Ball)
		body.Name = "Rotling"
		for _, side in ipairs({ -1, 1 }) do
			local eyeAt = seatFrame * CFrame.new(side * size * 0.2, size * 0.62, -size * 0.36)
			decor(part(lobby, Vector3.one * size * 0.32, eyeAt, WHITE, Enum.Material.SmoothPlastic, Enum.PartType.Ball))
			decor(part(lobby, Vector3.one * size * 0.14, eyeAt * CFrame.new(side * 0.03 * size, -0.02 * size, -size * 0.12), DARK,
				Enum.Material.SmoothPlastic, Enum.PartType.Ball))
		end
		pointLight(body, color, 22, 1.4)
		return body
	end

	local function buildGate(lobby, base, gate)
		local centre, frame
		if gate.degrees then
			centre = spot(base, gate.degrees, gate.radius)
			-- Facing the plaza's centre, or back along the road (tangent) where the road runs through.
			local look = facingCentre(centre, base)
			frame = gate.tangent and look * CFrame.Angles(0, math.rad(-90), 0) or look
		else
			centre = base + Vector3.new(gate.x, 0, gate.z)
			local heading = math.rad(gate.heading)
			frame = CFrame.lookAt(centre, centre - Vector3.new(math.cos(heading), 0, math.sin(heading)))
		end
		-- Either way the gate's front (-Z) faces the players walking up to it.
		local floor = gate.floor or 0.17
		frame = frame + Vector3.new(0, floor, 0)
		local half = gate.span / 2
		local top = gate.height
		-- Pillars: a stone plinth, a round column, a capital; the lintel sits on the capitals.
		for _, side in ipairs({ -1, 1 }) do
			local foot = frame * CFrame.new(side * half, 0, 0)
			part(lobby, Vector3.new(3, 1, 3), foot * CFrame.new(0, 0.45, 0), STONE, Enum.Material.Slate)
			column(lobby, top - 1.3, 2, foot.Position + Vector3.new(0, 0.8, 0), IRON, Enum.Material.Metal)
			part(lobby, Vector3.new(2.8, 0.8, 2.8), foot * CFrame.new(0, top - 0.4, 0), gate.color, Enum.Material.SmoothPlastic)
			-- A glowing band a third of the way up.
			decor(disc(lobby, 2.3, 0.5, foot.Position + Vector3.new(0, top * 0.35, 0), gate.color, Enum.Material.Neon))
		end
		local lintel = part(lobby, Vector3.new(gate.span + 3.6, 2.4, 2.4), frame * CFrame.new(0, top + 1.2 - 0.05, 0), DARK, Enum.Material.Metal)
		lintel.Name = "GateLintel"
		for _, face in ipairs({ -1, 1 }) do
			decor(part(lobby, Vector3.new(gate.span + 3.4, 0.3, 0.2), frame * CFrame.new(0, top + 0.35, face * 1.25), gate.color, Enum.Material.Neon))
		end
		-- The name board stands on the lintel, readable from both ways.
		local board = part(lobby, Vector3.new(math.min(gate.span + 2, 22), 3.4, 0.5), frame * CFrame.new(0, top + 2.4 + 1.7 - 0.05, 0), DARK, Enum.Material.Metal)
		board.Name = "GateSign"
		for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
			surfaceText(board, face, {
				{ y = 0.04, h = 0.6, text = gate.title, color = gate.color },
				{ y = 0.64, h = 0.3, text = gate.subtitle, color = WHITE, font = Enum.Font.GothamBold },
			}, 30)
		end
		decor(part(lobby, Vector3.new(board.Size.X + 0.4, 0.3, 0.7), board.CFrame * CFrame.new(0, 1.7 + 0.1, 0), gate.color, Enum.Material.Neon))
		-- The Rotling sits on the board's end, looking down the way in.
		rotling(lobby, frame * CFrame.new(board.Size.X / 2 - 0.2, top + 2.4 + 3.4 - 0.1, 0), gate.color, 2.6)
		-- Two banners on sway rods under the lintel, halfway to the pillars.
		for _, side in ipairs({ -1, 1 }) do
			local rodAt = frame * CFrame.new(side * half * 0.5, top - 0.1 - BANNER_DROP, 0)
			local rod = part(lobby, Vector3.new(3.4, 0.3, 0.3), rodAt, WOOD_DARK, Enum.Material.Wood)
			rod.Name = "BannerRod"
			rod.CanCollide = false
			rod:SetAttribute("SwayAxis", "X")
			rod:SetAttribute("SwayAngle", 7)
			rod:SetAttribute("SwaySpeed", 1.3)
			rod:SetAttribute("SwayPhase", side + gate.span)
			CollectionService:AddTag(rod, "AmbientSway")
			local cloth = decor(part(rod, Vector3.new(3, 4.6, 0.15), rodAt * CFrame.new(0, -2.4, 0), gate.color:Lerp(DARK, 0.25), Enum.Material.Fabric))
			cloth.Name = "Banner"
			decor(part(rod, Vector3.new(3.05, 0.5, 0.2), rodAt * CFrame.new(0, -4.5, 0), gate.color, Enum.Material.Neon))
			decor(part(rod, Vector3.new(1.2, 1.2, 0.2), rodAt * CFrame.new(0, -2.2, 0) * CFrame.Angles(0, 0, math.rad(45)), WHITE, Enum.Material.Neon))
		end
		return lintel
	end

	function buildWayfinding(lobby, base)
		buildRoad(lobby, base)
		for _, gate in ipairs(GATES) do
			buildGate(lobby, base, gate)
		end
	end
end

--------------------------------------------------------------------------------
-- Ambience: lanterns, string lights, fireflies, fireworks, signposts
--------------------------------------------------------------------------------

local function buildAmbience(lobby, base)
	-- Lanterns floating over the plaza.
	for index = 1, 18 do
		local angle = index / 18 * math.pi * 2 + 0.2
		local radius = 34 + (index % 4) * 14
		local position = base + Vector3.new(math.cos(angle) * radius, 15 + (index % 3) * 3, math.sin(angle) * radius)
		local lantern = decor(part(lobby, Vector3.new(1.3, 1.7, 1.3), CFrame.new(position), index % 3 == 0 and PINK or (index % 3 == 1 and GOLD or SKY),
			Enum.Material.Neon))
		if index % 2 == 0 then
			pointLight(lantern, lantern.Color, 14, 0.9)
		end
		bob(lantern, 0.6, 0.7 + (index % 3) * 0.2, index)
	end
	-- Fireflies over the grass rim.
	local fireflies = Instance.new("ParticleEmitter")
	fireflies.Color = ColorSequence.new(Color3.fromRGB(255, 240, 150))
	fireflies.Size = NumberSequence.new(0.3)
	fireflies.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) })
	fireflies.Lifetime = NumberRange.new(4, 7)
	fireflies.Speed = NumberRange.new(0.5, 1.5)
	fireflies.Rate = 14
	fireflies.LightEmission = 1
	fireflies.SpreadAngle = Vector2.new(180, 180)
	local emitter = decor(part(lobby, Vector3.new(RIM_RADIUS * 2, 6, RIM_RADIUS * 2), CFrame.new(base + Vector3.new(0, 6, 0)), WHITE, Enum.Material.SmoothPlastic))
	emitter.Transparency = 1
	fireflies.Parent = emitter

	-- Signpost at the head of the pier: a finger for each place on the island, each pointing straight
	-- at it, its pointed end painted in that place's colour.
	--
	-- Where a finger points is MEASURED from the lobby that has just been built (this runs after every
	-- other builder), not copied from the layout. Set pieces get moved and removed, and a copied
	-- position is how the old signpost kept pointing at a Rot Disco and a Market Row long after both
	-- were gone. A place is found by the sign it already carries (the text players look for), or, for
	-- one with no sign of its own, by the biggest footprint among its set piece's parts (the turf of
	-- the pitch). A place that can't be found gets no finger and a warning, never a finger to nowhere.
	-- tools/hud_ux_probe.lua measures every finger's bearing against the real destination.
	do
		local POST_HEIGHT = 12.6
		local BOARD_LENGTH, BOARD_HEIGHT, BOARD_THICKNESS, TIP_LENGTH, SPACING = 6, 1, 0.36, 0.8, 1.2
		local INK = Color3.fromRGB(30, 22, 14)
		local PLANK = Color3.fromRGB(150, 110, 70)

		local post = base + Vector3.new(20, 0, 78)
		part(lobby, Vector3.new(2.6, 0.5, 2.6), CFrame.new(post + Vector3.new(0, 0.25, 0)), WOOD_DARK, Enum.Material.Wood)
		-- The post starts 0.1 inside its base rather than on the base's own underside.
		column(lobby, POST_HEIGHT - 0.1, 0.8, post + Vector3.new(0, 0.1, 0), WOOD, Enum.Material.Wood)
		local knob = decor(part(lobby, Vector3.new(1.2, 1.2, 1.2), CFrame.new(post + Vector3.new(0, POST_HEIGHT + 0.4, 0)), GOLD, Enum.Material.Neon,
			Enum.PartType.Ball))
		pointLight(knob, GOLD, 14, 1)

		-- Everything the destinations are found by, in one pass over the lobby.
		local signAt, biggest = {}, {}
		for _, item in ipairs(lobby:GetDescendants()) do
			if item:IsA("BasePart") then
				local group = item:GetAttribute("Group")
				local footprint = item.Size.X * item.Size.Z
				if item:IsA("Part") and item.Shape == Enum.PartType.Cylinder then
					footprint = item.Size.Y * item.Size.Z
				end
				if group and (not biggest[group] or footprint > biggest[group].footprint) then
					biggest[group] = { footprint = footprint, position = item.Position }
				end
			elseif item:IsA("TextLabel") and item.Parent and (item.Parent:IsA("BillboardGui") or item.Parent:IsA("SurfaceGui")) then
				local host = item.Parent.Parent
				if host and host:IsA("BasePart") and not signAt[item.Text] then
					signAt[item.Text] = host.Position
				end
			end
		end

		local places = {
			{ label = "ROT EXPRESS", color = GREEN, sign = "THE ROT EXPRESS" },
			{ label = "CLOUD CLIMB", color = SAP, sign = "CLOUD CLIMB" },
			{ label = "CRATE ALTAR", color = PINK, sign = "CRATE ALTAR" },
			{ label = "DAILY SPIN", color = GOLD, sign = "DAILY SPIN" },
			{ label = "TRADING HALL", color = GOLD, sign = "TRADING HALL" },
			{ label = "COSMETICS", color = PINK, sign = "COSMETICS" },
			{ label = "THE ARENA", color = SKY, sign = "THE ARENA" },
			{ label = "THE PITCH", color = GREEN, group = "Pitch" },
			{ label = "WALK OF FAME", color = GOLD, sign = "WALK OF FAME" },
		}
		local built = 0
		for _, place in ipairs(places) do
			local target = place.sign and signAt[place.sign] or (place.group and biggest[place.group] and biggest[place.group].position)
			if not target then
				warn(string.format("[LobbyService] signpost: couldn't find %s in the lobby, so it gets no arrow", place.label))
				continue
			end
			local hub = post + Vector3.new(0, POST_HEIGHT - 0.9 - built * SPACING, 0)
			built += 1
			local look = CFrame.lookAt(hub, Vector3.new(target.X, hub.Y, target.Z))
			-- The board runs from just inside the post out to where the point starts.
			local boardEnd = BOARD_LENGTH - 0.25
			local board = decor(part(lobby, Vector3.new(BOARD_THICKNESS, BOARD_HEIGHT, BOARD_LENGTH), look * CFrame.new(0, 0, -(boardEnd - BOARD_LENGTH / 2)),
				PLANK, Enum.Material.WoodPlanks))
			board.Name = "SignpostArrow"
			board:SetAttribute("Destination", place.label)
			board:SetAttribute("Target", target)
			-- The point: two wedges meeting on the board's centre line. A shade thinner than the board
			-- and than each other, so no face lies in another's plane.
			local tipCentre = -(boardEnd + TIP_LENGTH / 2)
			decor(wedge(lobby, Vector3.new(BOARD_THICKNESS - 0.06, BOARD_HEIGHT / 2, TIP_LENGTH),
				look * CFrame.new(0, BOARD_HEIGHT / 4, tipCentre), place.color, Enum.Material.Neon))
			decor(wedge(lobby, Vector3.new(BOARD_THICKNESS - 0.08, BOARD_HEIGHT / 2, TIP_LENGTH),
				look * CFrame.new(0, -BOARD_HEIGHT / 4, tipCentre) * CFrame.Angles(0, 0, math.pi), place.color, Enum.Material.Neon))
			for _, face in ipairs({ Enum.NormalId.Left, Enum.NormalId.Right }) do
				local labels = surfaceText(board, face, { { y = 0.08, h = 0.84, text = place.label, color = INK, font = Enum.Font.GothamBlack, stroke = 1 } },
					40, MatchConfig.LobbyLabelDistance)
				-- Clear of both ends: the post hides the first stud of the board, and a name run right up
				-- to it lost its first letter.
				labels[1].Position = UDim2.fromScale(0.13, 0.08)
				labels[1].Size = UDim2.fromScale(0.74, 0.84)
			end
		end
	end
end

-- Fireworks over the tree: a shell climbs, bursts into a ring of sparks, and everything fades.
local fireworksGeneration = 0

local function launchFirework(lobby, base)
	local color = ({ GOLD, PINK, SKY, GREEN })[math.random(1, 4)]
	local from = base + Vector3.new(math.random(-30, 30), 40, math.random(-30, 30))
	local to = from + Vector3.new(math.random(-10, 10), 70 + math.random(0, 30), math.random(-10, 10))
	local shell = decor(part(lobby, Vector3.new(0.8, 0.8, 0.8), CFrame.new(from), color, Enum.Material.Neon, Enum.PartType.Ball))
	pointLight(shell, color, 20, 2)
	TweenService:Create(shell, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = to }):Play()
	task.delay(1.1, function()
		if not shell.Parent then
			return
		end
		shell:Destroy()
		playgroundFx:FireAllClients({ kind = "stage", position = to, color = color })
		for index = 1, 14 do
			local direction = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit
			local spark = decor(part(lobby, Vector3.new(0.6, 0.6, 0.6), CFrame.new(to), color, Enum.Material.Neon, Enum.PartType.Ball))
			TweenService:Create(spark, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = to + direction * (14 + math.random() * 8) - Vector3.new(0, 6, 0), Transparency = 1 }):Play()
			Debris:AddItem(spark, 1.5)
		end
	end)
end

--------------------------------------------------------------------------------

-- Builds the whole island under `lobby`, centred on `base`.
function LobbyService.Build(lobby, base)
	railPosts = {}
	for _, step in ipairs({
		{ "Island", buildIsland }, { "Pier", buildPier }, { "Airship", buildAirship }, { "Tree", buildTree },
		{ "Statue", buildStatue }, { "TradingHall", buildTradingHall }, { "Cosmetics", buildCosmeticsStall },
		{ "CrateAltar", buildCrateAltar }, { "DailySpin", buildDailySpin },
		{ "Boards", buildBoards }, { "Arena", buildArena }, { "Pitch", buildPitch }, { "Balls", buildPlayBalls },
		{ "CloudClimb", buildCloudClimb }, { "Wayfinding", buildWayfinding }, { "Ambience", buildAmbience },
	}) do
		currentGroup = step[1]
		step[2](lobby, base)
	end
	currentGroup = "Island"

	-- Nothing left flush with anything else: the z-fight pass nudges coplanar faces a hair
	-- apart, the stage's displays included.
	local zfight = ZFight.Fix({ lobby, workspace:FindFirstChild("StageDisplay") })
	lobby:SetAttribute("ZFightMoved", zfight.moved)
	lobby:SetAttribute("ZFightRemaining", #zfight.remaining)

	fireworksGeneration += 1
	local generation = fireworksGeneration
	task.spawn(function()
		while generation == fireworksGeneration and lobby.Parent do
			task.wait(18 + math.random() * 14)
			if generation == fireworksGeneration and lobby.Parent and #Players:GetPlayers() > 0 then
				launchFirework(lobby, base)
				if math.random() < 0.5 then
					task.delay(0.6, function()
						if lobby.Parent then
							launchFirework(lobby, base)
						end
					end)
				end
			end
		end
	end)

	LobbyService.RefreshLeaderboard()
	task.spawn(LobbyService.RefreshGlobalBoard)
end

function LobbyService.Start()
	Players.PlayerRemoving:Connect(function(player)
		climbRuns[player] = nil
		lastGoalPaidAt[player] = nil
		readyPadLastTouch[player] = nil
	end)

	task.spawn(function()
		local ticks = 0
		while true do
			task.wait(LEADERBOARD_REFRESH)
			LobbyService.RefreshLeaderboard()
			ticks += 1
			if ticks % math.max(1, math.floor(GLOBAL_BOARD_REFRESH / LEADERBOARD_REFRESH)) == 0 then
				task.spawn(LobbyService.RefreshGlobalBoard)
			end
		end
	end)
end

return LobbyService
