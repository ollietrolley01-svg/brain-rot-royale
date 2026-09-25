-- Things on the map breaking, drawn locally (#71). DestructibleService removes whatever broke on the
-- server and sends everything that broke that frame in one BreakFx event:
-- { cframe, size, color, material, class, from, stage } each, where `class` is the material's family
-- (wood, stone, metal, foliage, soil, cloth, glass, plastic), `from` is where the shot or blast came
-- from, when known, and `stage` how cracked it was when it went (CrackFxClient drew the cracks; the
-- first CRACKED_PIECES pieces carry them on, with more lines the further gone it was).
--
-- EVERY MATERIAL BREAKS ITS OWN WAY (MATERIALS, one per material; the family's profile is only the
-- fallback): concrete in lumps with its rebar, brick in bricks, marble in white shards, granite in
-- angular chunks, slate in thin plates, sandstone crumbling into grains, basalt in columns,
-- limestone in a chalk cloud, rock in boulders, cobbles and pebbles in round stones, paving in
-- slabs, asphalt in black crumbs, cracked lava in black crust and embers, salt in cubes, ice and
-- glacier in clear shards and frost, wood in splinters, planks in planks, metal in bent plates and
-- sparks, diamond plate in tread plates, rust in flakes, foil in crumpled scraps, grass in turf and
-- clods, leaves falling, earth in clods, sand in a spray, snow in clumps and powder, mud in splats,
-- cloth, leather and carpet in scraps, cardboard in flaps, rubber bouncing, plaster in flakes and its
-- lath, tiles in tiles, roof tiles and shingles sliding off, plastic in chunks, smooth plastic in
-- sharp shards, neon in glass and sparks, a force field in motes of light.
--
-- The debris is real physics: unanchored, collides with the world, tumbles and comes to rest, then
-- lies still a moment and fades. It is feather-light, so it never shoves a player. Nothing
-- replicates: every client throws its own, and the thing itself is already gone for everyone.
--
-- Lag (#131): pieces are capped per break, per event and in total, skipped out of sight range, and
-- every piece has a hard lifetime, so a rocket through a street of props costs a bounded number of
-- small local parts. Dust and sparks are one emitter burst each, capped per event.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local breakFx = Remotes.Event("BreakFx")
local camera = workspace.CurrentCamera

local EFFECT_DISTANCE = 300
-- Pieces alive at once, across everything breaking.
local MAX_ACTIVE = 160
-- Pieces one event may add, however much broke that frame.
local MAX_PER_EVENT = 70
local PER_BREAK_MIN, PER_BREAK_MAX = 3, 12
-- The most extra pieces (rebar, lath, planks, tiles, pebbles...) one break adds, within the caps.
local EXTRA_PER_BREAK = 4
local PUFFS_PER_EVENT = 6
local SOUNDS_PER_EVENT = 3
-- Pieces per break that carry the cracks of what broke.
local CRACKED_PIECES = 4
-- Seconds a piece may tumble before it is laid to rest regardless; how long it then lies there; how
-- long it takes to fade. MAX_LIFE is the backstop: nothing outlives it.
local SETTLE_AFTER = 2.2
local REST_TIME = 1.2
local FADE_TIME = 0.6
local MAX_LIFE = SETTLE_AFTER + REST_TIME + FADE_TIME + 0.5
-- Moving slower than this (after its first moments) counts as at rest.
local AT_REST_SPEED = 0.6
local LIGHT = PhysicalProperties.new(0.08, 0.5, 0.2)
local BOUNCY = PhysicalProperties.new(0.9, 0.4, 0.6)

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- Proposed SoundConfig cues first, then the nearest existing one, so this sounds right the day the
-- cues land and isn't silent before.
local SOUNDS = {
	wood = { "BreakWood", "BodyFall" },
	stone = { "BreakStone", "GoldCrumble" },
	metal = { "BreakMetal", "CasingTink" },
	foliage = { "BreakFoliage" },
	soil = { "FootstepSand", "GoldCrumble" },
	cloth = { "BreakFoliage" },
	glass = { "Shatter" },
	plastic = { "BreakStone", "GoldCrumble" },
}

-- How each family breaks, when its material has no line of its own: the pieces' shape (a size
-- range per axis, as fractions of the broken part's smallest side, then clamped to studs), how hard
-- they're thrown, and the puff.
local PROFILES = {
	wood = { shape = "splinter", speed = 14, spin = 10, puff = rgb(196, 170, 130), puffSize = 1.6 },
	stone = { shape = "chunk", speed = 12, spin = 8, puff = rgb(170, 166, 158), puffSize = 3 },
	metal = { shape = "plate", speed = 16, spin = 12, sparks = true },
	foliage = { shape = "leaf", speed = 7, spin = 6, puff = rgb(96, 140, 70), puffSize = 1.8, drift = true },
	soil = { shape = "ball", speed = 9, spin = 6, puff = rgb(150, 120, 90), puffSize = 2.4 },
	cloth = { shape = "leaf", speed = 6, spin = 5, drift = true },
	glass = { shape = "shard", speed = 14, spin = 16 },
	plastic = { shape = "chunk", speed = 12, spin = 9 },
}

-- Every material's own break: { shape, speed, spin, puff colour and size, sparks / embers / glint /
-- spray / splash / motes, drift (falls like a leaf), bouncy, extra = { kind, count, colour,
-- material } pieces thrown besides its own, sounds }. tools/crack_check.py holds every material to
-- having one.
local RUST = rgb(128, 62, 30)
local MATERIALS = {
	Concrete = { shape = "chunk", speed = 12, spin = 8, puff = rgb(176, 172, 164), puffSize = 3.2,
		extra = { kind = "rod", count = 2, color = RUST, material = Enum.Material.CorrodedMetal }, sounds = { "BreakStone", "GoldCrumble" } },
	Brick = { shape = "brick", speed = 12, spin = 7, puff = rgb(172, 120, 98), puffSize = 3, sounds = { "BreakStone", "GoldCrumble" } },
	Marble = { shape = "shard", speed = 13, spin = 10, puff = rgb(244, 242, 238), puffSize = 2.2, glint = true, sounds = { "BreakStone", "CasingTink" } },
	Granite = { shape = "wedge", speed = 12, spin = 8, puff = rgb(170, 164, 160), puffSize = 2.6, glint = true, sounds = { "BreakStone" } },
	Slate = { shape = "flake", speed = 12, spin = 10, puff = rgb(110, 114, 120), puffSize = 2.2, sounds = { "GoldCrumble", "BreakStone" } },
	Sandstone = { shape = "chunk", speed = 9, spin = 6, puff = rgb(222, 196, 150), puffSize = 3.4, spray = true,
		extra = { kind = "grain", count = 4, color = rgb(220, 190, 140), material = Enum.Material.Sand }, sounds = { "FootstepSand", "GoldCrumble" } },
	Basalt = { shape = "column", speed = 11, spin = 6, puff = rgb(96, 96, 100), puffSize = 2.6, sounds = { "BreakStone" } },
	Limestone = { shape = "chunk", speed = 11, spin = 7, puff = rgb(248, 246, 240), puffSize = 4, sounds = { "GoldCrumble", "BreakStone" } },
	Rock = { shape = "boulder", speed = 10, spin = 6, puff = rgb(160, 150, 138), puffSize = 3, sounds = { "BreakStone", "GoldCrumble" } },
	Cobblestone = { shape = "ball", speed = 11, spin = 6, puff = rgb(164, 160, 154), puffSize = 2.4, bouncy = true, sounds = { "FlairRattle", "BreakStone" } },
	Pebble = { shape = "pebble", speed = 10, spin = 6, puff = rgb(170, 164, 150), puffSize = 1.8, bouncy = true, sounds = { "FlairPop", "FlairRattle" } },
	Pavement = { shape = "slab", speed = 11, spin = 6, puff = rgb(180, 178, 172), puffSize = 2.6, sounds = { "BreakStone", "GoldCrumble" } },
	Asphalt = { shape = "chunk", speed = 10, spin = 7, puff = rgb(70, 70, 72), puffSize = 2.2,
		extra = { kind = "grain", count = 4, color = rgb(120, 118, 112), material = Enum.Material.Pebble }, sounds = { "GoldCrumble" } },
	CrackedLava = { shape = "chunk", speed = 12, spin = 8, embers = true, sounds = { "Burn", "BreakStone" } },
	Salt = { shape = "cube", speed = 11, spin = 9, puff = rgb(252, 252, 252), puffSize = 2, glint = true, sounds = { "CasingTink", "GoldCrumble" } },
	Ice = { shape = "shard", speed = 14, spin = 14, puff = rgb(236, 246, 255), puffSize = 1.8, glint = true, clear = 0.35, sounds = { "Freeze", "Shatter" } },
	Glacier = { shape = "wedge", speed = 12, spin = 10, puff = rgb(244, 250, 255), puffSize = 2.4, glint = true, clear = 0.2, sounds = { "Freeze", "BreakStone" } },
	Glass = { shape = "shard", speed = 14, spin = 16, clear = 0.3, glint = true, sounds = { "Shatter" } },
	Wood = { shape = "splinter", speed = 14, spin = 10, puff = rgb(196, 170, 130), puffSize = 1.6, sounds = { "BreakWood", "BodyFall" } },
	WoodPlanks = { shape = "splinter", speed = 14, spin = 10, puff = rgb(206, 180, 136), puffSize = 1.6,
		extra = { kind = "plank", count = 2 }, sounds = { "BreakWood", "FlairKnock" } },
	Metal = { shape = "plate", speed = 16, spin = 12, sparks = true, sounds = { "BreakMetal", "CasingTink" } },
	DiamondPlate = { shape = "plate", speed = 15, spin = 10, sparks = true, sounds = { "FlairClank", "BreakMetal" } },
	CorrodedMetal = { shape = "plate", speed = 13, spin = 10, puff = rgb(160, 86, 44), puffSize = 2,
		extra = { kind = "flake", count = 4, color = rgb(150, 72, 30), material = Enum.Material.CorrodedMetal }, sounds = { "BreakMetal", "GoldCrumble" } },
	Foil = { shape = "scrap", speed = 8, spin = 12, drift = true, glint = true, sounds = { "FlairTear", "CasingTink" } },
	Grass = { shape = "ball", speed = 9, spin = 6, puff = rgb(118, 96, 64), puffSize = 2.2,
		extra = { kind = "tuft", count = 4, color = rgb(96, 140, 60), material = Enum.Material.Grass }, sounds = { "FootstepGrass", "BreakFoliage" } },
	LeafyGrass = { shape = "leaf", speed = 7, spin = 6, puff = rgb(96, 140, 70), puffSize = 1.8, drift = true, sounds = { "BreakFoliage" } },
	Ground = { shape = "ball", speed = 9, spin = 6, puff = rgb(150, 122, 92), puffSize = 2.8, sounds = { "FootstepSand", "GoldCrumble" } },
	Sand = { shape = "grain", speed = 8, spin = 4, puff = rgb(226, 206, 160), puffSize = 3.2, spray = true, sounds = { "FootstepSand" } },
	Snow = { shape = "ball", speed = 8, spin = 5, puff = rgb(252, 252, 255), puffSize = 3.4, sounds = { "FootstepSand", "FootstepGrass" } },
	Mud = { shape = "ball", speed = 9, spin = 4, splash = true, sounds = { "StickySquelch", "HitSplat" } },
	Fabric = { shape = "scrap", speed = 6, spin = 5, drift = true, sounds = { "FlairTear", "BreakFoliage" } },
	Leather = { shape = "scrap", speed = 7, spin = 5, drift = true, sounds = { "FlairTear", "FlairTap" } },
	Carpet = { shape = "scrap", speed = 6, spin = 5, drift = true, puff = rgb(200, 190, 176), puffSize = 1.4, sounds = { "FlairTear" } },
	Cardboard = { shape = "flap", speed = 8, spin = 7, drift = true, sounds = { "FlairStamp", "FlairTear" } },
	Rubber = { shape = "chunk", speed = 12, spin = 9, bouncy = true, sounds = { "FlairSqueak", "FlairBounce" } },
	Plaster = { shape = "flake", speed = 10, spin = 8, puff = rgb(240, 236, 228), puffSize = 3.4,
		extra = { kind = "lath", count = 2, color = rgb(150, 110, 70), material = Enum.Material.Wood }, sounds = { "GoldCrumble", "BreakStone" } },
	CeramicTiles = { shape = "tile", speed = 12, spin = 10, puff = rgb(214, 212, 208), puffSize = 1.8, glint = true, sounds = { "FlairTap", "CasingTink" } },
	ClayRoofTiles = { shape = "tile", speed = 11, spin = 8, puff = rgb(196, 118, 88), puffSize = 2, sounds = { "FlairRattle", "BreakStone" } },
	RoofShingles = { shape = "flap", speed = 10, spin = 8, puff = rgb(90, 88, 86), puffSize = 1.8, sounds = { "FlairRattle", "FlairTear" } },
	Plastic = { shape = "chunk", speed = 12, spin = 9, sounds = { "FlairTap", "BreakStone" } },
	SmoothPlastic = { shape = "shard", speed = 13, spin = 12, glint = true, sounds = { "CasingTink", "FlairTap" } },
	Neon = { shape = "shard", speed = 14, spin = 14, sparks = true, sounds = { "Shock", "Shatter" } },
	ForceField = { shape = "none", motes = true, sounds = { "Shock", "FlairBuzz" } },
}

local fxFolder = Instance.new("Folder")
fxFolder.Name = "BreakFx"
fxFolder.Parent = workspace

-- piece -> { born, rested }. Strong keys: every piece is removed from here when it is destroyed.
local pieces = {}
local active = 0

local function now()
	-- Wall clock, not os.clock (process CPU time in Roblox).
	return time()
end

local function playBreak(material, class, position)
	local own = MATERIALS[material.Name]
	for _, name in ipairs((own and own.sounds) or SOUNDS[class] or {}) do
		if SoundConfig.Get(name) then
			Sfx.PlayAt(name, position, 0.2)
			return
		end
	end
end

-- One burst from a throwaway emitter: dust, sparks, embers, a glint, a spray of sand, a splash of
-- mud, motes of light.
local function puff(position, color, size, kind)
	local holder = Instance.new("Part")
	holder.Name = "BreakPuff"
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.new(position)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Parent = fxFolder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	local count = 10
	if kind == "sparks" or kind == "embers" or kind == "motes" then
		local hot = kind == "embers" and rgb(255, 132, 36) or (kind == "motes" and color or rgb(255, 214, 120))
		emitter.Color = ColorSequence.new(hot, kind == "motes" and color or rgb(255, 120, 40))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new(0.18, 0)
		emitter.Lifetime = NumberRange.new(kind == "sparks" and 0.25 or 0.6, kind == "sparks" and 0.55 or 1.2)
		emitter.Speed = NumberRange.new(kind == "sparks" and 14 or 4, kind == "sparks" and 26 or 9)
		emitter.SpreadAngle = Vector2.new(70, 70)
		emitter.Acceleration = Vector3.new(0, kind == "sparks" and -60 or 6, 0)
		emitter.Drag = 2
		count = 16
	elseif kind == "glint" then
		emitter.Color = ColorSequence.new(rgb(235, 245, 255))
		emitter.LightEmission = 0.6
		emitter.Size = NumberSequence.new(0.22, 0)
		emitter.Lifetime = NumberRange.new(0.2, 0.4)
		emitter.Speed = NumberRange.new(5, 10)
		emitter.SpreadAngle = Vector2.new(180, 180)
		count = 12
	elseif kind == "spray" or kind == "splash" then
		emitter.Color = ColorSequence.new(color)
		emitter.Size = NumberSequence.new(kind == "splash" and 0.3 or 0.18, 0.08)
		emitter.Lifetime = NumberRange.new(0.5, 0.9)
		emitter.Speed = NumberRange.new(8, 16)
		emitter.SpreadAngle = Vector2.new(60, 60)
		emitter.Acceleration = Vector3.new(0, -40, 0)
		count = 30
	else
		emitter.Color = ColorSequence.new(color)
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.6), NumberSequenceKeypoint.new(1, size * 1.6) })
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(0.8, 1.4)
		emitter.Speed = NumberRange.new(3, 7)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = Vector3.new(0, 1.5, 0)
		emitter.Drag = 3
		emitter.Rotation = NumberRange.new(0, 360)
	end
	emitter.Parent = holder
	emitter:Emit(count)
	task.delay(1.8, function()
		holder:Destroy()
	end)
end

local function retire(piece)
	pieces[piece] = nil
	piece.Anchored = true
	piece.CanCollide = false
	TweenService:Create(piece, TweenInfo.new(FADE_TIME), { Transparency = 1 }):Play()
	-- A SurfaceGui draws whatever its part's Transparency, so the crack lines fade with the piece.
	local cracks = piece:FindFirstChild("Cracks")
	if cracks then
		for _, crack in ipairs(cracks:GetChildren()) do
			TweenService:Create(crack, TweenInfo.new(FADE_TIME), { BackgroundTransparency = 1 }):Play()
		end
	end
	task.delay(FADE_TIME, function()
		piece:Destroy()
	end)
end

-- A piece's size in studs for its shape, given the broken part's size.
local function pieceSize(shape, size)
	local r = math.random
	local scale = math.clamp(math.min(size.X, size.Y, size.Z) * 0.6 + math.max(size.X, size.Y, size.Z) * 0.08, 0.5, 2.4)
	if shape == "splinter" then
		return Vector3.new(0.18 + r() * 0.2, 0.18 + r() * 0.2, (0.8 + r() * 1.4) * scale)
	elseif shape == "plate" or shape == "slab" then
		return Vector3.new((0.5 + r() * 0.8) * scale, shape == "slab" and 0.3 + r() * 0.2 or 0.08 + r() * 0.06, (0.4 + r() * 0.7) * scale)
	elseif shape == "leaf" or shape == "scrap" then
		return Vector3.new(0.35 + r() * 0.4, 0.05, 0.3 + r() * 0.35)
	elseif shape == "flap" then
		return Vector3.new((0.5 + r() * 0.5) * scale, 0.06, (0.4 + r() * 0.4) * scale)
	elseif shape == "flake" then
		return Vector3.new((0.3 + r() * 0.4) * scale, 0.05 + r() * 0.04, (0.25 + r() * 0.35) * scale)
	elseif shape == "shard" then
		return Vector3.new(0.05, 0.2 + r() * 0.5, 0.15 + r() * 0.4)
	elseif shape == "brick" then
		local k = 0.6 + r() * 0.4
		return Vector3.new(2 * k, 0.8 * k, 1 * k)
	elseif shape == "tile" then
		return Vector3.new(0.9 + r() * 0.3, 0.12, 0.9 + r() * 0.3)
	elseif shape == "column" then
		local e = (0.4 + r() * 0.4) * scale
		return Vector3.new(e, e * 2.2, e)
	elseif shape == "cube" then
		local e = 0.2 + r() * 0.3
		return Vector3.new(e, e, e)
	elseif shape == "ball" or shape == "pebble" or shape == "grain" then
		local e = shape == "grain" and 0.12 + r() * 0.1 or (shape == "pebble" and 0.2 + r() * 0.2 or (0.35 + r() * 0.5) * math.min(scale, 1.4))
		return Vector3.new(e, e, e)
	elseif shape == "boulder" then
		local e = (0.6 + r() * 0.9) * scale
		return Vector3.new(e * (0.8 + r() * 0.4), e * (0.6 + r() * 0.4), e * (0.8 + r() * 0.4))
	end
	local edge = (0.3 + r() * 0.6) * scale
	return Vector3.new(edge * (0.7 + r() * 0.6), edge * (0.6 + r() * 0.5), edge * (0.7 + r() * 0.6))
end

-- Pieces besides the thing's own material: rebar out of concrete, lath out of plaster, planks out of a
-- plank floor, grains out of sandstone, tufts out of turf, rust flakes out of corroded metal.
local function extraSize(kind, size)
	local r = math.random
	if kind == "rod" then
		return Vector3.new(0.14, 0.14, math.clamp(math.max(size.X, size.Y, size.Z) * 0.35, 1.5, 4.5))
	elseif kind == "lath" then
		return Vector3.new(1.4 + r(), 0.14, 0.3)
	elseif kind == "plank" then
		return Vector3.new(2 + r() * 1.5, 0.22, 0.9)
	elseif kind == "grain" then
		local e = 0.1 + r() * 0.08
		return Vector3.new(e, e, e)
	elseif kind == "tuft" then
		return Vector3.new(0.06, 0.4, 0.06)
	elseif kind == "flake" then
		return Vector3.new(0.3, 0.03, 0.24)
	end
	return Vector3.new(0.3, 0.3, 0.3)
end

-- The cracks a broken thing had, carried on one of its pieces: dark lines across its broadest face
-- (a crack on a tumbling chunk reads the same whichever way the face is drawn), one more per stage.
local function crackLook(piece, stage, color)
	local size = piece.Size
	local face = Enum.NormalId.Front
	if size.X * size.Z >= size.X * size.Y and size.X * size.Z >= size.Y * size.Z then
		face = Enum.NormalId.Top
	elseif size.Y * size.Z > size.X * size.Y then
		face = Enum.NormalId.Right
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Cracks"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 1
	local line = color:Lerp(Color3.new(0, 0, 0), 0.72)
	for _ = 1, stage + 1 do
		local crack = Instance.new("Frame")
		crack.AnchorPoint = Vector2.new(0.5, 0.5)
		crack.Position = UDim2.fromScale(0.25 + math.random() * 0.5, 0.25 + math.random() * 0.5)
		crack.Size = UDim2.new(0.5 + math.random() * 0.5, 0, 0, 2 + stage)
		crack.Rotation = math.random() * 180
		crack.BackgroundColor3 = line
		crack.BorderSizePixel = 0
		crack.Parent = gui
	end
	gui.Parent = piece
	return gui
end

local ROUND = { ball = true, pebble = true, grain = true }
local WEDGE = { shard = true, wedge = true }

local function throw(name, size, cframe, offset, color, material, profile, away, stage, index, crackable, clear)
	local shape = profile.shape
	local className = (WEDGE[shape] or (shape == "chunk" and index % 3 == 0)) and "WedgePart" or "Part"
	local piece = Instance.new(className)
	piece.Name = name
	piece.Size = size
	if ROUND[shape] and piece:IsA("Part") and name == "BreakPiece" then
		piece.Shape = Enum.PartType.Ball
	end
	piece.CFrame = cframe * CFrame.new(offset) * CFrame.Angles(math.random() * 6.3, math.random() * 6.3, math.random() * 6.3)
	-- The broken thing's own colour, a little varied and darker inside.
	piece.Color = color:Lerp(Color3.new(0, 0, 0), math.random() * 0.25)
	piece.Material = material
	if clear then
		piece.Transparency = clear
	end
	piece.CanCollide = true
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CastShadow = false
	piece.CustomPhysicalProperties = profile.bouncy and BOUNCY or LIGHT
	if crackable and stage > 0 and index <= CRACKED_PIECES then
		crackLook(piece, stage, color)
	end
	piece.Parent = fxFolder
	local outward = (cframe:VectorToWorldSpace(offset)).Unit
	if outward ~= outward then
		outward = Vector3.new(0, 1, 0)
	end
	local push = away and (away * 0.6 + outward * 0.4) or outward
	local speed = (profile.speed or 12) * (0.5 + math.random() * 0.7)
	local lift = profile.drift and (1 + math.random() * 3) or (4 + math.random() * 8)
	piece.AssemblyLinearVelocity = push * speed + Vector3.new(0, lift, 0)
	local spin = profile.spin or 8
	piece.AssemblyAngularVelocity = Vector3.new(math.random(-spin, spin), math.random(-spin, spin), math.random(-spin, spin))
	active += 1
	pieces[piece] = { born = now(), drift = profile.drift }
	piece.Destroying:Connect(function()
		if pieces[piece] then
			pieces[piece] = nil
		end
		active -= 1
	end)
end

local function burst(cframe, size, color, material, class, from, budget, stage)
	local profile = MATERIALS[material.Name] or PROFILES[class] or PROFILES.plastic
	if profile.shape == "none" then
		return 0
	end
	local volume = size.X * size.Y * size.Z
	local count = math.clamp(math.floor(volume ^ (1 / 3) * 1.6), PER_BREAK_MIN, PER_BREAK_MAX)
	count = math.min(count, budget, MAX_ACTIVE - active)
	local away = nil
	if typeof(from) == "Vector3" then
		local offset = cframe.Position - from
		if offset.Magnitude > 0.01 then
			away = offset.Unit
		end
	end
	local crackable = class ~= "foliage" and class ~= "cloth" and class ~= "soil"
	local clear = profile.clear or (class == "glass" and 0.3 or nil)
	for index = 1, count do
		local offset = Vector3.new((math.random() - 0.5) * size.X * 0.8, (math.random() - 0.5) * size.Y * 0.8, (math.random() - 0.5) * size.Z * 0.8)
		throw("BreakPiece", pieceSize(profile.shape, size), cframe, offset, color, material, profile, away, stage, index, crackable, clear)
	end
	local extra = profile.extra
	local extras = 0
	if extra then
		extras = math.min(extra.count, EXTRA_PER_BREAK, budget - count, MAX_ACTIVE - active)
		for _ = 1, extras do
			local offset = Vector3.new((math.random() - 0.5) * size.X * 0.6, (math.random() - 0.5) * size.Y * 0.6, (math.random() - 0.5) * size.Z * 0.6)
			throw("BreakExtra", extraSize(extra.kind, size), cframe, offset, extra.color or color, extra.material or material, profile, away, 0, 99, false, nil)
		end
	end
	return count + math.max(0, extras)
end

breakFx.OnClientEvent:Connect(function(batch)
	if type(batch) ~= "table" or not camera then
		return
	end
	local budget, puffs, sounds = MAX_PER_EVENT, 0, 0
	for _, entry in ipairs(batch) do
		local cframe, size, color, material, class, from = entry[1], entry[2], entry[3], entry[4], entry[5], entry[6]
		local stage = type(entry[7]) == "number" and math.clamp(math.floor(entry[7]), 0, 3) or 0
		if typeof(cframe) == "CFrame" and typeof(size) == "Vector3" and typeof(color) == "Color3"
			and typeof(material) == "EnumItem" and (cframe.Position - camera.CFrame.Position).Magnitude <= EFFECT_DISTANCE then
			local profile = MATERIALS[material.Name] or PROFILES[class] or PROFILES.plastic
			if sounds < SOUNDS_PER_EVENT then
				sounds += 1
				playBreak(material, class, cframe.Position)
			end
			if puffs < PUFFS_PER_EVENT then
				local kind = (profile.sparks and "sparks") or (profile.embers and "embers") or (profile.motes and "motes")
					or (profile.spray and "spray") or (profile.splash and "splash") or nil
				if kind then
					puffs += 1
					puff(cframe.Position, kind == "splash" and color:Lerp(Color3.new(0, 0, 0), 0.4) or (profile.puff or color), profile.puffSize or 1, kind)
				end
				if profile.puff and kind ~= "spray" and puffs < PUFFS_PER_EVENT then
					puffs += 1
					puff(cframe.Position, profile.puff, profile.puffSize or 1, "dust")
				end
				if profile.glint and puffs < PUFFS_PER_EVENT then
					puffs += 1
					puff(cframe.Position, color, 1, "glint")
				end
			end
			if budget > 0 and active < MAX_ACTIVE then
				budget -= burst(cframe, size, color, material, class, from, budget, stage)
			end
		end
	end
end)

-- Leaves and cloth fall slowly; everything comes to rest (still, or after SETTLE_AFTER), lies a
-- moment, and fades. MAX_LIFE is the backstop for anything that never settles.
RunService.Heartbeat:Connect(function()
	local clock = now()
	for piece, info in pairs(pieces) do
		local age = clock - info.born
		if not piece.Parent then
			pieces[piece] = nil
		elseif age > MAX_LIFE or piece.Position.Y < -500 then
			pieces[piece] = nil
			piece:Destroy()
		elseif info.rested then
			if clock - info.rested > REST_TIME then
				retire(piece)
			end
		else
			local velocity = piece.AssemblyLinearVelocity
			if info.drift and velocity.Y < -4 then
				-- Air under a leaf: it falls at a flutter, not a drop.
				piece.AssemblyLinearVelocity = Vector3.new(velocity.X * 0.96, -4, velocity.Z * 0.96)
			end
			if age > SETTLE_AFTER or (age > 0.5 and velocity.Magnitude < AT_REST_SPEED) then
				info.rested = clock
				piece.Anchored = true
				piece.CanCollide = false
			end
		end
	end
end)
