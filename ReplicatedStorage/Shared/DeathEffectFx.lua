-- Death effects (#24; called kill animations in the code and the save, "Death Effects" on screen):
-- the engine every one of them is built on. The same module plays them in the world
-- (StarterPlayerScripts/KillAnimFxClient), loops them in the shop's previews (CosmeticPreview) and
-- freezes them for the gallery (tools/deathfx_gallery.lua), so what a player previews is what plays.
--
-- An effect is a TIMELINE, not a pile of tweens and delays. Its design (DeathEffectDesigns) declares
-- parts, then what each does between two moments (`fx:tween`), what happens at a moment (`fx:at`),
-- particle bursts, light flashes and sounds. `fx:step(t)` puts everything where it is at t seconds.
-- Nothing in here waits or schedules anything: whoever owns the effect steps it. That buys three
-- things this project has paid for the lack of before:
--   * the world, a looping shop preview and a gallery still show the same frames: a still at 0.8 s
--     is frame 0.8 s of the game, not an approximation of it;
--   * teardown is one Destroy of one folder, with nothing left running behind it;
--   * a harness can step it on a stand-in clock and measure every frame (tools/killanim_check.py).
--
-- Budgets, per effect, because a grenade can drop five bodies in one frame and every client builds
-- every effect near enough to see. `fx:part`, `fx:burst` and `fx:light` refuse past them and every
-- design copes with a refusal (nil):
--   MAX_PARTS      parts, including the invisible anchors that carry emitters and lights
--   MAX_PARTICLES  particles emitted over the whole effect
--   MAX_LIGHTS     PointLights (a flash each)
--   MAX_LIFETIME   seconds; the owner destroys the effect at its design's `life`, never later
--   MAX_SPARKS     preview only: the parts that stand in for particles (see below)
-- Raised on 2026-09-24 from 24 parts / 40 particles / 3 s, for the multi-stage versions.
--
-- The body. When the effect has been handed the victim's body (KillAnimService claimed it, so the
-- server has anchored it and will hide it once the effect is over), the design moves, squashes,
-- tints and fades it through `fx:bodyPose` and friends. Those are LOCAL changes to anchored parts, so
-- no physics fights them, every client does the same thing in step with its own effect, and nothing
-- replicates. Geometry is only ever written to anchored parts; a body that isn't ours (the default
-- ragdoll, still simulated) can be read and flashed but never moved. With no body every body call is
-- a no-op, so each design also reads right on its own.
--
-- Previews. A ViewportFrame draws neither particles nor lights, so in preview mode (`preview = true`)
-- a burst becomes a handful of small neon "sparks" flying the same way, and lights are skipped: the
-- neon flash parts that go with every light carry the flash on their own. Sparks come out of their
-- own budget, so a preview never has fewer real parts than the game.
--
-- Cylinders run along their X axis, so every upright or flat-lying one here is turned a quarter
-- about Z (UPRIGHT).

local DeathEffectFx = {}

DeathEffectFx.MAX_PARTS = 32
DeathEffectFx.MAX_PARTICLES = 64
DeathEffectFx.MAX_LIGHTS = 2
DeathEffectFx.MAX_LIFETIME = 3.2
DeathEffectFx.MAX_SPARKS = 24

-- Particle textures. Only files the Roblox client itself ships, and only the five this project has
-- already seen load (GunFx.lua, ExplosiveFx.lua): no uploaded assets.
DeathEffectFx.Textures = {
	glow = "rbxasset://textures/glow.png",
	sparkle = "rbxasset://textures/sparkle.png",
	fire = "rbxasset://textures/particles/fire_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	sparks = "rbxasset://textures/particles/fire_sparks_main.dds",
}

local V = Vector3.new
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
DeathEffectFx.UPRIGHT = UPRIGHT

local SMOOTH = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon
local WHITE = Color3.new(1, 1, 1)
local MIN_SIZE = 0.05

--------------------------------------------------------------------------------
-- Easing. Each takes 0..1 and gives 0 at 0 and exactly 1 at 1 (the harness holds every one to
-- that), so a tween always lands where it says. Back and Elastic overshoot on the way.
--------------------------------------------------------------------------------

local C1 = 1.70158
local C3 = C1 + 1
local C4 = (2 * math.pi) / 3

local Ease = {}
Ease.linear = function(a)
	return a
end
Ease.quadIn = function(a)
	return a * a
end
Ease.quadOut = function(a)
	return 1 - (1 - a) * (1 - a)
end
Ease.quadInOut = function(a)
	return a < 0.5 and 2 * a * a or 1 - (-2 * a + 2) ^ 2 / 2
end
Ease.cubicIn = function(a)
	return a * a * a
end
Ease.cubicOut = function(a)
	return 1 - (1 - a) ^ 3
end
Ease.sineInOut = function(a)
	return -(math.cos(math.pi * a) - 1) / 2
end
Ease.expoOut = function(a)
	return a >= 1 and 1 or 1 - 2 ^ (-10 * a)
end
Ease.backOut = function(a)
	return 1 + C3 * (a - 1) ^ 3 + C1 * (a - 1) ^ 2
end
Ease.backIn = function(a)
	return C3 * a * a * a - C1 * a * a
end
Ease.elasticOut = function(a)
	if a <= 0 then
		return 0
	elseif a >= 1 then
		return 1
	end
	return 2 ^ (-10 * a) * math.sin((a * 10 - 0.75) * C4) + 1
end
Ease.bounceOut = function(a)
	local n, d = 7.5625, 2.75
	if a < 1 / d then
		return n * a * a
	elseif a < 2 / d then
		a -= 1.5 / d
		return n * a * a + 0.75
	elseif a < 2.5 / d then
		a -= 2.25 / d
		return n * a * a + 0.9375
	end
	a -= 2.625 / d
	return n * a * a + 0.984375
end
DeathEffectFx.Ease = Ease

--------------------------------------------------------------------------------
-- One effect
--------------------------------------------------------------------------------

local Fx = {}
Fx.__index = Fx

local function flatYaw(look)
	local flat = V(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return 0
	end
	return math.atan2(-flat.X, -flat.Z)
end

local function torsoOf(model)
	return model and (model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
		or model:FindFirstChild("HumanoidRootPart")) or nil
end

-- options:
--   parent     where the effect's folder goes (workspace, a ViewportFrame, a gallery folder)
--   origin     the body's root position (about three studs above the ground)
--   ground     the ground under it
--   life       seconds, capped at MAX_LIFETIME; a burst's particles are cut to die before it
--   body       the victim's Model, or nil
--   ownsBody   true when the body is ours to move (claimed and anchored, or a preview dummy)
--   preview    sparks instead of particles, no lights, and the body put back on Destroy
--   seed       for the design's Random, so a still or a thumbnail is the same every time
--   sound      function(cue, position, pitchJitter), or nil for silence
function DeathEffectFx.new(options)
	local folder = Instance.new("Folder")
	folder.Name = options.name or "DeathEffectFx"
	local fx = setmetatable({
		folder = folder,
		origin = options.origin,
		ground = options.ground or (options.origin - V(0, 3, 0)),
		life = math.min(options.life or DeathEffectFx.MAX_LIFETIME, DeathEffectFx.MAX_LIFETIME),
		preview = options.preview == true,
		random = Random.new(options.seed or 1),
		soundHook = options.sound,
		bodyModel = options.body,
		ownsBody = options.body ~= nil and options.ownsBody == true,
		parts = 0,
		particles = 0,
		lights = 0,
		sparkCount = 0,
		tracks = {},
		events = {},
		seq = 0,
		now = 0,
		alive = true,
	}, Fx)
	-- Where the body stands and which way it faces: every design places things relative to this, so
	-- a bat swings onto the spot and a ghost's face looks the way the body did.
	local torso = torsoOf(options.body)
	local yaw = torso and flatYaw(torso.CFrame.LookVector) or (options.yaw or 0)
	fx.pivot = CFrame.new(fx.ground) * CFrame.Angles(0, yaw, 0)
	folder.Parent = options.parent
	return fx
end

-- An anchored, untouchable part, or nil once the budget is spent.
function Fx:part(size, cframe, color, material, shape, transparency)
	if not self.alive or self.parts >= DeathEffectFx.MAX_PARTS then
		return nil
	end
	self.parts += 1
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color or WHITE
	part.Material = material or SMOOTH
	part.Transparency = transparency or 0
	part.Parent = self.folder
	return part
end

-- `fn(eased, raw)` is called every step while t is inside [t0, t0 + duration], and once more at
-- exactly 1 when t passes the end, so it always lands. It must SET state from alpha (never add to
-- it), which is what lets a still jump straight to any moment.
function Fx:tween(t0, duration, fn, ease)
	self.seq += 1
	table.insert(self.tracks, { t0 = t0, t1 = t0 + math.max(duration, 0), fn = fn, ease = ease or Ease.linear, seq = self.seq })
	self.tracksDirty = true
end

-- `fn()` once, the first step at or after `t`.
function Fx:at(t, fn)
	self.seq += 1
	table.insert(self.events, { t = t, fn = fn, seq = self.seq })
end

local function byStart(a, b)
	if a.t0 ~= b.t0 then
		return a.t0 < b.t0
	end
	return a.seq < b.seq
end

-- Everything where it is at `t`, and the same whether it got there in one jump or sixty frames:
--   1. everything DUE by t, in the order it fell due: each event at its moment, and each tween that
--      has finished landing (its final call, at 1) at its end. A tween landing and an event at the
--      same instant: the tween lands first, so an event that hides a part a tween was moving wins.
--      An event may add more events and tweens; they are picked up in the same pass.
--   2. then every tween still in progress, in start order, so a later tween on the same property
--      wins over an earlier one.
-- Without (1), a still that jumped straight to 1.6 s ran a bubble's "pop" event and THEN its swell
-- tween's last frame, and the popped bubble came back.
function Fx:step(t)
	if not self.alive then
		return
	end
	self.now = t
	for _ = 1, 1024 do
		local best, bestTime, bestKind = nil, 0, 0
		for _, event in ipairs(self.events) do
			if not event.done and event.t <= t then
				-- kind 1: an event goes after a tween landing at the same instant.
				if not best or event.t < bestTime or (event.t == bestTime and (bestKind == 1 and event.seq < best.seq)) then
					best, bestTime, bestKind = event, event.t, 1
				end
			end
		end
		for _, track in ipairs(self.tracks) do
			if not track.done and track.t1 <= t then
				if not best or track.t1 < bestTime or (track.t1 == bestTime and (bestKind == 1 or track.seq < best.seq)) then
					best, bestTime, bestKind = track, track.t1, 0
				end
			end
		end
		if not best then
			break
		end
		best.done = true
		if bestKind == 0 then
			best.fn(best.ease(1), 1)
		else
			best.fn()
		end
		if not self.alive then
			return
		end
	end
	if self.tracksDirty then
		table.sort(self.tracks, byStart)
		self.tracksDirty = false
	end
	for _, track in ipairs(self.tracks) do
		if not track.done and track.t0 <= t then
			local raw = math.clamp((t - track.t0) / (track.t1 - track.t0), 0, 1)
			track.fn(track.ease(raw), raw)
		end
	end
end

--------------------------------------------------------------------------------
-- Particles, lights, sound
--------------------------------------------------------------------------------

local function sequenceOf(color)
	if typeof(color) == "Color3" then
		return ColorSequence.new(color)
	end
	local keypoints = {}
	for index, each in ipairs(color) do
		table.insert(keypoints, ColorSequenceKeypoint.new((index - 1) / math.max(#color - 1, 1), each))
	end
	if #keypoints == 1 then
		return ColorSequence.new(color[1])
	end
	return ColorSequence.new(keypoints)
end

local function firstColor(color)
	return typeof(color) == "Color3" and color or color[1]
end

local function where(at)
	if type(at) == "function" then
		return at()
	end
	return at
end

-- Preview stand-ins for a burst: a few neon balls flying the way the particles would, shrinking and
-- fading over the same life. Deterministic (the effect's own Random), so a still is repeatable.
function Fx:sparks(t, at, spec)
	local count = math.min(math.ceil((spec.count or 10) / 4), 7, DeathEffectFx.MAX_SPARKS - self.sparkCount)
	local life = math.min(((spec.life and (spec.life[1] + spec.life[2]) / 2) or 1), math.max(0.05, self.life - t - 0.05))
	local speed = spec.speed or { 6, 12 }
	local accel = spec.accel or Vector3.zero
	local drag = spec.drag or 0
	local spread = math.rad(math.clamp(spec.spread or 180, 0, 180))
	local colors = typeof(spec.color) == "Color3" and { spec.color } or (spec.color or { WHITE })
	local size = math.clamp((spec.size and spec.size[1] or 0.5) * 0.45, 0.12, 0.6)
	local up = spec.direction or V(0, 1, 0)
	-- Any vector not parallel to `up`, to build the cone around it.
	local side = math.abs(up.Y) < 0.9 and V(0, 1, 0) or V(1, 0, 0)
	local right = up:Cross(side).Unit
	local forward = right:Cross(up).Unit
	for index = 1, count do
		self.sparkCount += 1
		local spark = Instance.new("Part")
		spark.Anchored = true
		spark.CanCollide = false
		spark.CanQuery = false
		spark.CanTouch = false
		spark.CastShadow = false
		spark.Shape = Enum.PartType.Ball
		spark.Material = NEON
		spark.Color = colors[(index - 1) % #colors + 1]
		spark.Size = V(size, size, size)
		spark.CFrame = CFrame.new(at)
		spark.Parent = self.folder
		-- A direction inside the cone: `spread` from `up`, evenly round it.
		local theta = spread * math.sqrt(self.random:NextNumber())
		local phi = (index / count + self.random:NextNumber() * 0.3) * math.pi * 2
		local dir = up * math.cos(theta) + (right * math.cos(phi) + forward * math.sin(phi)) * math.sin(theta)
		local velocity = dir * (speed[1] + (speed[2] - speed[1]) * self.random:NextNumber())
		local start = at
		if spec.inward then
			-- Starts out on the sphere and falls to its middle, the way an Inward emitter does.
			start = at + dir * spec.inward
			velocity = Vector3.zero
		end
		self:tween(t, life, function(_, raw)
			local tau = raw * life
			local travel
			if spec.inward then
				travel = (at - start) * Ease.quadIn(raw)
			elseif drag > 0 then
				travel = velocity * ((1 - math.exp(-drag * tau)) / drag) + accel * (0.5 * tau * tau)
			else
				travel = velocity * tau + accel * (0.5 * tau * tau)
			end
			spark.CFrame = CFrame.new(start + travel)
			local shrink = math.max(MIN_SIZE, size * (1 - raw * 0.7))
			spark.Size = V(shrink, shrink, shrink)
			spark.Transparency = 0.1 + 0.9 * raw * raw
		end)
	end
end

-- A one-off burst of particles at `t` from `at` (a position, or a function returning one, read at
-- that moment). spec: count, color (a Color3 or a list, over the particle's life), texture (a key of
-- Textures), size = { start, finish }, speed = { min, max }, life = { min, max }, spread (degrees
-- from `direction`, default up; 180 is every way), accel, drag, glow (LightEmission), spin, inward
-- (a radius: particles start on that sphere and fall to its middle).
--
-- Costs one invisible anchor part and `count` particles, cut to what's left of the budget. The
-- particles' lifetime is cut so the last one is gone before the effect is.
function Fx:burst(t, at, spec)
	self:at(t, function()
		local position = where(at)
		if not position then
			return
		end
		if self.preview then
			self:sparks(t, position, spec)
			return
		end
		local count = math.min(spec.count or 10, DeathEffectFx.MAX_PARTICLES - self.particles)
		if count <= 0 then
			return
		end
		local size = spec.inward and V(spec.inward * 2, spec.inward * 2, spec.inward * 2) or V(0.2, 0.2, 0.2)
		local frame = CFrame.new(position)
		if spec.direction then
			frame = CFrame.lookAt(position, position + spec.direction) * CFrame.Angles(-math.pi / 2, 0, 0)
		end
		local anchor = self:part(size, frame, WHITE, SMOOTH, spec.inward and Enum.PartType.Ball or nil, 1)
		if not anchor then
			return
		end
		self.particles += count
		local lifeMax = math.max(0.05, math.min((spec.life or { 0.6, 1.2 })[2], self.life - t - 0.05))
		local lifeMin = math.min((spec.life or { 0.6, 1.2 })[1], lifeMax)
		local emitter = Instance.new("ParticleEmitter")
		emitter.Enabled = false
		emitter.Rate = 0
		emitter.Texture = DeathEffectFx.Textures[spec.texture or "sparkle"] or DeathEffectFx.Textures.sparkle
		emitter.Color = sequenceOf(spec.color or WHITE)
		emitter.LightEmission = spec.glow or 0.5
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, (spec.size or { 0.5, 0 })[1]),
			NumberSequenceKeypoint.new(1, (spec.size or { 0.5, 0 })[2]),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, spec.fade or 0.05),
			NumberSequenceKeypoint.new(0.7, math.min(1, (spec.fade or 0.05) + 0.25)),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Lifetime = NumberRange.new(lifeMin, lifeMax)
		local speed = spec.speed or { 6, 12 }
		emitter.Speed = NumberRange.new(speed[1], speed[2])
		local spread = spec.spread or 180
		emitter.SpreadAngle = Vector2.new(spread, spread)
		emitter.Acceleration = spec.accel or Vector3.zero
		emitter.Drag = spec.drag or 0
		emitter.Rotation = NumberRange.new(0, 360)
		local spin = spec.spin or 90
		emitter.RotSpeed = NumberRange.new(-spin, spin)
		if spec.inward then
			emitter.Shape = Enum.ParticleEmitterShape.Sphere
			emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
			emitter.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
			emitter.Speed = NumberRange.new(spec.inward / lifeMax * 0.8, spec.inward / lifeMax)
		end
		emitter.Parent = anchor
		emitter:Emit(count)
	end)
end

-- A light flash: up to `peak` brightness in the first eighth of `duration`, then away. `at` is a
-- position, a function returning one, or a Part (the light rides on it and costs no anchor).
-- Nothing in a preview: the neon flash part that goes with every light carries it there.
function Fx:light(t, duration, at, color, range, peak)
	if self.preview then
		return
	end
	self:at(t, function()
		if self.lights >= DeathEffectFx.MAX_LIGHTS then
			return
		end
		local holder = typeof(at) == "Instance" and at or nil
		if not holder then
			local position = where(at)
			holder = position and self:part(V(0.2, 0.2, 0.2), CFrame.new(position), WHITE, SMOOTH, nil, 1)
		end
		if not holder then
			return
		end
		self.lights += 1
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = range
		light.Brightness = 0
		light.Shadows = false
		light.Parent = holder
		self:tween(t, duration, function(_, raw)
			light.Brightness = peak * (raw < 0.125 and raw / 0.125 or (1 - (raw - 0.125) / 0.875) ^ 2)
		end)
	end)
end

-- A cue from SoundConfig at `t`, where the body is (or `at`).
function Fx:sound(t, cue, jitter, at)
	self:at(t, function()
		if self.soundHook then
			self.soundHook(cue, where(at) or self.origin, jitter or 0.1)
		end
	end)
end

--------------------------------------------------------------------------------
-- The body
--------------------------------------------------------------------------------

-- The body's pieces, snapshotted the first time a design asks (by then the server's anchoring has
-- arrived: it is sent before the effect is). nil when the effect has no body of its own.
function Fx:bodyPieces()
	if not self.ownsBody or not self.bodyModel then
		return nil
	end
	if self.pieces then
		return self.pieces
	end
	local pieces = {}
	local inverse = self.pivot:Inverse()
	for _, part in ipairs(self.bodyModel:GetDescendants()) do
		if part:IsA("BasePart") then
			local decals = {}
			for _, child in ipairs(part:GetChildren()) do
				if child:IsA("Decal") or child:IsA("Texture") then
					table.insert(decals, { decal = child, transparency = child.Transparency })
				end
			end
			local rel = inverse * part.CFrame
			table.insert(pieces, {
				part = part,
				cf = part.CFrame,
				rel = rel,
				height = rel.Position.Y,
				size = part.Size,
				transparency = part.Transparency,
				color = part.Color,
				material = part.Material,
				decals = decals,
			})
		end
	end
	self.pieces = pieces
	return pieces
end

-- The middle of the body right now (it may be falling): the torso, else where it died.
function Fx:bodyCenter()
	local torso = torsoOf(self.bodyModel)
	if torso and torso.Parent then
		return torso.Position
	end
	return self.origin
end

-- Puts one piece at `cframe`, `scale` times its own size (a Vector3 along the pivot's axes, turned
-- into the piece's own through its pose at the snapshot). Only an anchored piece is moved: an
-- unanchored one is being simulated, and a local CFrame on it would be overwritten next frame anyway.
function Fx:placePiece(piece, cframe, scale)
	local part = piece.part
	if not part.Parent or not part.Anchored then
		return
	end
	part.CFrame = cframe
	if scale then
		local rot = piece.rel
		local function along(axis)
			return math.abs(axis.X) * scale.X + math.abs(axis.Y) * scale.Y + math.abs(axis.Z) * scale.Z
		end
		part.Size = V(
			math.max(MIN_SIZE, piece.size.X * along(rot.RightVector)),
			math.max(MIN_SIZE, piece.size.Y * along(rot.UpVector)),
			math.max(MIN_SIZE, piece.size.Z * along(-rot.LookVector))
		)
	end
end

-- 0 is as it was, 1 is gone. A part that was invisible to begin with (the root) stays invisible.
function Fx:fadePiece(piece, fade)
	local part = piece.part
	if not part.Parent then
		return
	end
	part.Transparency = piece.transparency + (1 - piece.transparency) * math.clamp(fade, 0, 1)
	for _, entry in ipairs(piece.decals) do
		if entry.decal.Parent then
			entry.decal.Transparency = entry.transparency + (1 - entry.transparency) * math.clamp(fade, 0, 1)
		end
	end
end

function Fx:tintPiece(piece, color, alpha)
	if piece.part.Parent then
		piece.part.Color = piece.color:Lerp(color, math.clamp(alpha, 0, 1))
	end
end

-- The whole body at once. pose (every field optional; only the ones given are written):
--   to      the pivot's new CFrame (the body moves and turns with it)
--   scale   a Vector3 along the pivot's axes, about the ground point: Y 0.1 is a pancake
--   fade    0..1
--   tint    Color3, with `tintAlpha` 0..1
--   material
function Fx:bodyPose(pose)
	local pieces = self:bodyPieces()
	if not pieces then
		return
	end
	local geometry = pose.to ~= nil or pose.scale ~= nil
	local to = pose.to or self.pivot
	local scale = pose.scale or V(1, 1, 1)
	for _, piece in ipairs(pieces) do
		if geometry then
			local rel = piece.rel
			local moved = to * CFrame.new(rel.Position * scale) * (rel - rel.Position)
			self:placePiece(piece, moved, scale)
		end
		if pose.fade then
			self:fadePiece(piece, pose.fade)
		end
		if pose.tint then
			self:tintPiece(piece, pose.tint, pose.tintAlpha or 1)
		end
		if pose.material and piece.part.Parent and piece.transparency < 1 then
			piece.part.Material = pose.material
		end
	end
end

-- Gone, at once (the pop of a pop).
function Fx:hideBody()
	self:bodyPose({ fade = 1 })
end

-- A white flash over the whole body, for a body we may not move (the default ragdoll): a Highlight in
-- the world, a quick tint in a preview. Cheap, and gone after `duration`.
function Fx:flashBody(t, duration, color)
	if not self.bodyModel then
		return
	end
	if self.preview then
		local pieces = self.ownsBody and self:bodyPieces()
		if pieces then
			self:tween(t, duration, function(_, raw)
				for _, piece in ipairs(pieces) do
					self:tintPiece(piece, color, 1 - raw)
				end
			end)
		end
		return
	end
	self:at(t, function()
		if not self.bodyModel.Parent then
			return
		end
		local highlight = Instance.new("Highlight")
		highlight.Adornee = self.bodyModel
		highlight.FillColor = color
		highlight.OutlineTransparency = 1
		highlight.FillTransparency = 0.2
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = self.folder
		self:tween(t, duration, function(eased)
			highlight.FillTransparency = 0.2 + 0.8 * eased
		end, Ease.quadIn)
	end)
end

--------------------------------------------------------------------------------
-- Done
--------------------------------------------------------------------------------

-- Tears the effect down. A preview also puts its dummy back exactly as it found it, so the next loop
-- starts from a whole body. A body in the world is left as it is: the server hides it.
function Fx:destroy()
	if not self.alive then
		return
	end
	self.alive = false
	self.folder:Destroy()
	if self.preview and self.pieces then
		for _, piece in ipairs(self.pieces) do
			local part = piece.part
			if part.Parent then
				part.CFrame = piece.cf
				part.Size = piece.size
				part.Transparency = piece.transparency
				part.Color = piece.color
				part.Material = piece.material
			end
			for _, entry in ipairs(piece.decals) do
				entry.decal.Transparency = entry.transparency
			end
		end
	end
end

--------------------------------------------------------------------------------
-- A stand-in body for previews and the gallery
--------------------------------------------------------------------------------

-- A blocky R15 body, feet on y = 0, facing -Z like a character, root at (0, 3.2, 0): the fifteen
-- limbs by their R15 names and proportions, so an effect treats it exactly as it treats a player.
local SKIN = Color3.fromRGB(246, 206, 150)
local SHIRT = Color3.fromRGB(70, 170, 190)
local PANTS = Color3.fromRGB(52, 62, 96)
local SHOE = Color3.fromRGB(40, 36, 36)
local DUMMY = {
	{ "HumanoidRootPart", V(2, 2, 1), V(0, 3.2, 0), SHIRT, 1 },
	{ "Head", V(1.2, 1.2, 1.2), V(0, 5.3, 0), SKIN },
	{ "UpperTorso", V(2, 1.6, 1), V(0, 3.9, 0), SHIRT },
	{ "LowerTorso", V(2, 0.4, 1), V(0, 2.9, 0), PANTS },
	{ "LeftUpperArm", V(1, 1.2, 1), V(-1.5, 4.1, 0), SHIRT },
	{ "LeftLowerArm", V(1, 1, 1), V(-1.5, 3, 0), SKIN },
	{ "LeftHand", V(1, 0.3, 1), V(-1.5, 2.35, 0), SKIN },
	{ "RightUpperArm", V(1, 1.2, 1), V(1.5, 4.1, 0), SHIRT },
	{ "RightLowerArm", V(1, 1, 1), V(1.5, 3, 0), SKIN },
	{ "RightHand", V(1, 0.3, 1), V(1.5, 2.35, 0), SKIN },
	{ "LeftUpperLeg", V(1, 1.2, 1), V(-0.5, 2.1, 0), PANTS },
	{ "LeftLowerLeg", V(1, 1.2, 1), V(-0.5, 0.9, 0), PANTS },
	{ "LeftFoot", V(1, 0.3, 1.1), V(-0.5, 0.15, -0.05), SHOE },
	{ "RightUpperLeg", V(1, 1.2, 1), V(0.5, 2.1, 0), PANTS },
	{ "RightLowerLeg", V(1, 1.2, 1), V(0.5, 0.9, 0), PANTS },
	{ "RightFoot", V(1, 0.3, 1.1), V(0.5, 0.15, -0.05), SHOE },
	-- The face, as parts: a ViewportFrame draws decals, but there's no uploaded face to draw.
	{ "LeftEye", V(0.2, 0.3, 0.05), V(-0.25, 5.4, -0.61), SHOE },
	{ "RightEye", V(0.2, 0.3, 0.05), V(0.25, 5.4, -0.61), SHOE },
}
DeathEffectFx.DummyRoot = V(0, 3.2, 0)

function DeathEffectFx.Dummy(at)
	local model = Instance.new("Model")
	model.Name = "DeathEffectDummy"
	local base = at or CFrame.new()
	for _, entry in ipairs(DUMMY) do
		local part = Instance.new("Part")
		part.Name = entry[1]
		part.Size = entry[2]
		part.CFrame = base * CFrame.new(entry[3])
		part.Color = entry[4]
		part.Transparency = entry[5] or 0
		part.Material = SMOOTH
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
	end
	model.PrimaryPart = model:FindFirstChild("HumanoidRootPart")
	return model
end

return DeathEffectFx
