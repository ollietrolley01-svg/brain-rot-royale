-- Things on the map breaking, drawn locally (#71). DestructibleService removes whatever broke on the
-- server and sends everything that broke that frame in one BreakFx event:
-- { cframe, size, color, material, class, from } each, where `class` is the material's family
-- (wood, stone, metal, foliage, cloth, glass, plastic) and `from` is where the shot or blast came
-- from, when known. Here each piece comes apart the way its material would:
--
--   wood      splinters and a couple of broken boards, a puff of sawdust
--   stone     chunks and wedges of itself, and a cloud of grey dust
--   metal     bent plates, and sparks
--   foliage   leaves that flutter down, and a green puff
--   cloth     scraps that drift
--   glass     shards (a car's windows; building panes go through GlassFxClient)
--   plastic   chunks
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
local PUFFS_PER_EVENT = 6
local SOUNDS_PER_EVENT = 3
-- Seconds a piece may tumble before it is laid to rest regardless; how long it then lies there; how
-- long it takes to fade. MAX_LIFE is the backstop: nothing outlives it.
local SETTLE_AFTER = 2.2
local REST_TIME = 1.2
local FADE_TIME = 0.6
local MAX_LIFE = SETTLE_AFTER + REST_TIME + FADE_TIME + 0.5
-- Moving slower than this (after its first moments) counts as at rest.
local AT_REST_SPEED = 0.6
local LIGHT = PhysicalProperties.new(0.08, 0.5, 0.2)

-- Proposed SoundConfig cues first, then the nearest existing one, so this sounds right the day the
-- cues land and isn't silent before.
local SOUNDS = {
	wood = { "BreakWood", "BodyFall" },
	stone = { "BreakStone", "GoldCrumble" },
	metal = { "BreakMetal", "CasingTink" },
	foliage = { "BreakFoliage" },
	cloth = { "BreakFoliage" },
	glass = { "Shatter" },
	plastic = { "BreakStone", "GoldCrumble" },
}

-- How each family breaks: the pieces' shape (a size range per axis, as fractions of the broken part's
-- smallest side, then clamped to studs), how hard they're thrown, and the puff.
local PROFILES = {
	wood = { shape = "splinter", speed = 14, spin = 10, puff = Color3.fromRGB(196, 170, 130), puffSize = 1.6 },
	stone = { shape = "chunk", speed = 12, spin = 8, puff = Color3.fromRGB(170, 166, 158), puffSize = 3 },
	metal = { shape = "plate", speed = 16, spin = 12, sparks = true },
	foliage = { shape = "leaf", speed = 7, spin = 6, puff = Color3.fromRGB(96, 140, 70), puffSize = 1.8, drift = true },
	cloth = { shape = "leaf", speed = 6, spin = 5, drift = true },
	glass = { shape = "shard", speed = 14, spin = 16 },
	plastic = { shape = "chunk", speed = 12, spin = 9 },
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

local function playBreak(class, position)
	for _, name in ipairs(SOUNDS[class] or {}) do
		if SoundConfig.Get(name) then
			Sfx.PlayAt(name, position, 0.2)
			return
		end
	end
end

-- One burst from a throwaway emitter: dust for stone, wood and leaves, sparks for metal.
local function puff(position, color, size, sparks)
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
	if sparks then
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 214, 120), Color3.fromRGB(255, 120, 40))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new(0.18, 0)
		emitter.Lifetime = NumberRange.new(0.25, 0.55)
		emitter.Speed = NumberRange.new(14, 26)
		emitter.SpreadAngle = Vector2.new(70, 70)
		emitter.Acceleration = Vector3.new(0, -60, 0)
		emitter.Drag = 2
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
	emitter:Emit(sparks and 16 or 10)
	task.delay(1.8, function()
		holder:Destroy()
	end)
end

local function retire(piece)
	pieces[piece] = nil
	piece.Anchored = true
	piece.CanCollide = false
	TweenService:Create(piece, TweenInfo.new(FADE_TIME), { Transparency = 1 }):Play()
	task.delay(FADE_TIME, function()
		piece:Destroy()
	end)
end

-- A piece's size in studs for its family, given the broken part's size.
local function pieceSize(shape, size)
	local r = math.random
	local scale = math.clamp(math.min(size.X, size.Y, size.Z) * 0.6 + math.max(size.X, size.Y, size.Z) * 0.08, 0.5, 2.4)
	if shape == "splinter" then
		return Vector3.new(0.18 + r() * 0.2, 0.18 + r() * 0.2, (0.8 + r() * 1.4) * scale)
	elseif shape == "plate" then
		return Vector3.new((0.5 + r() * 0.8) * scale, 0.08 + r() * 0.06, (0.4 + r() * 0.7) * scale)
	elseif shape == "leaf" then
		return Vector3.new(0.35 + r() * 0.4, 0.05, 0.3 + r() * 0.35)
	elseif shape == "shard" then
		return Vector3.new(0.05, 0.2 + r() * 0.5, 0.15 + r() * 0.4)
	end
	local edge = (0.3 + r() * 0.6) * scale
	return Vector3.new(edge * (0.7 + r() * 0.6), edge * (0.6 + r() * 0.5), edge * (0.7 + r() * 0.6))
end

local function burst(cframe, size, color, material, class, from, budget)
	local profile = PROFILES[class] or PROFILES.plastic
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
	for index = 1, count do
		local shape = profile.shape
		-- Stone throws a few wedges among its blocks; wood a couple of whole board ends.
		local className = "Part"
		if (shape == "chunk" and index % 3 == 0) or shape == "shard" then
			className = "WedgePart"
		end
		local piece = Instance.new(className)
		piece.Name = "BreakPiece"
		piece.Size = pieceSize(shape, size)
		local offset = Vector3.new((math.random() - 0.5) * size.X * 0.8, (math.random() - 0.5) * size.Y * 0.8,
			(math.random() - 0.5) * size.Z * 0.8)
		piece.CFrame = cframe * CFrame.new(offset) * CFrame.Angles(math.random() * 6.3, math.random() * 6.3, math.random() * 6.3)
		-- The broken thing's own colour, a little varied and darker inside.
		piece.Color = color:Lerp(Color3.new(0, 0, 0), math.random() * 0.25)
		piece.Material = material
		if class == "glass" then
			piece.Transparency = 0.3
		end
		piece.CanCollide = true
		piece.CanQuery = false
		piece.CanTouch = false
		piece.CastShadow = false
		piece.CustomPhysicalProperties = LIGHT
		piece.Parent = fxFolder
		local outward = (cframe:VectorToWorldSpace(offset)).Unit
		if outward ~= outward then
			outward = Vector3.new(0, 1, 0)
		end
		local push = away and (away * 0.6 + outward * 0.4) or outward
		local speed = profile.speed * (0.5 + math.random() * 0.7)
		local lift = profile.drift and (1 + math.random() * 3) or (4 + math.random() * 8)
		piece.AssemblyLinearVelocity = push * speed + Vector3.new(0, lift, 0)
		local spin = profile.spin
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
	return count
end

breakFx.OnClientEvent:Connect(function(batch)
	if type(batch) ~= "table" or not camera then
		return
	end
	local budget, puffs, sounds = MAX_PER_EVENT, 0, 0
	for _, entry in ipairs(batch) do
		local cframe, size, color, material, class, from = entry[1], entry[2], entry[3], entry[4], entry[5], entry[6]
		if typeof(cframe) == "CFrame" and typeof(size) == "Vector3" and typeof(color) == "Color3"
			and typeof(material) == "EnumItem" and (cframe.Position - camera.CFrame.Position).Magnitude <= EFFECT_DISTANCE then
			local profile = PROFILES[class] or PROFILES.plastic
			if sounds < SOUNDS_PER_EVENT then
				sounds += 1
				playBreak(class, cframe.Position)
			end
			if puffs < PUFFS_PER_EVENT and (profile.puff or profile.sparks) then
				puffs += 1
				puff(cframe.Position, profile.puff or color, profile.puffSize or 1, profile.sparks)
			end
			if budget > 0 and active < MAX_ACTIVE then
				budget -= burst(cframe, size, color, material, class, from, budget)
			end
		end
	end
end)

-- Leaves and cloth fall slowly; everything comes to rest (still, or after SETTLE_AFTER), lies a
-- moment, and fades. MAX_LIFE is the backstop for anything that never settles.
RunService.Heartbeat:Connect(function(dt)
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
