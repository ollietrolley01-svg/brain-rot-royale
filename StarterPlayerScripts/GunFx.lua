-- Gunfire effects on the client: muzzle flashes, tracer rounds, spent cases, dropped magazines and
-- impact sparks. ModuleScript; CombatClient calls it for your own shots (from the viewmodel's muzzle)
-- and everyone else's (from their gun's muzzle in the world).
--
--   GunFx.Flash(cframe, kind, scale, firstPerson)  -- cframe looks out of the muzzle
--   GunFx.Tracer(origin, target, kind, onArrive)
--   GunFx.Casing(cframe, kind)                      -- cframe at the ejection port, looking out of it
--   GunFx.Drop(model, up)                           -- a magazine or box let go of
--   GunFx.Impact(position, normal)
--
-- Textures are ones the Roblox client ships under rbxasset:// (glow.png, the particle set), checked
-- by rendering them in the gallery rather than assumed. Everything is pooled or capped: a firefight
-- between forty bots must not become thousands of instances.

local RunService = game:GetService("RunService")

local GunFx = {}

local TEXTURE = {
	glow = "rbxasset://textures/glow.png",
	fire = "rbxasset://textures/particles/fire_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	sparks = "rbxasset://textures/particles/fire_sparks_main.dds",
	sparkle = "rbxasset://textures/sparkle.png",
}

local V = Vector3.new
local NS = NumberSequence.new
local NSK = NumberSequenceKeypoint.new
local CS = ColorSequence.new

local folder = nil
local function effects()
	if not folder or not folder.Parent then
		folder = Instance.new("Folder")
		folder.Name = "BRR_GunFx"
		folder.Parent = workspace
	end
	return folder
end
GunFx.Folder = effects

local function anchoredPart(name, size)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size or V(0.1, 0.1, 0.1)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	return part
end

--------------------------------------------------------------------------------
-- Muzzle flash
--------------------------------------------------------------------------------

-- What each gun's muzzle does: the size of the fireball, how far its flame reaches forward, whether a
-- brake throws flame out to the sides, the colour, and how much smoke hangs after.
local FLASH = {
	rifle = { core = 0.9, flame = 1.0, sides = 0, color = Color3.fromRGB(255, 196, 120), smoke = 0.6, light = 9 },
	smg = { core = 0.7, flame = 0.8, sides = 0, color = Color3.fromRGB(255, 200, 130), smoke = 0.4, light = 8 },
	pistol = { core = 0.6, flame = 0.5, sides = 0, color = Color3.fromRGB(255, 190, 110), smoke = 0.35, light = 7 },
	revolver = { core = 1.0, flame = 0.7, sides = 0.6, color = Color3.fromRGB(255, 180, 100), smoke = 0.8, light = 9 },
	brake = { core = 0.8, flame = 0.6, sides = 1.2, color = Color3.fromRGB(255, 196, 120), smoke = 1.0, light = 10 },
	shotgun = { core = 1.3, flame = 1.1, sides = 0.3, color = Color3.fromRGB(255, 176, 96), smoke = 1.2, light = 11 },
	suppressed = { core = 0.18, flame = 0.1, sides = 0, color = Color3.fromRGB(255, 210, 160), smoke = 0.3, light = 0 },
	rotary = { core = 0.8, flame = 0.9, sides = 0.2, color = Color3.fromRGB(255, 200, 120), smoke = 0.5, light = 9 },
	cannon = { core = 1.8, flame = 1.3, sides = 0.8, color = Color3.fromRGB(255, 170, 70), smoke = 2.0, light = 14 },
	rocket = { core = 1.2, flame = 0.4, sides = 0.2, color = Color3.fromRGB(255, 190, 110), smoke = 2.4, light = 12 },
	launcher = { core = 0.9, flame = 0.4, sides = 0.2, color = Color3.fromRGB(255, 190, 110), smoke = 1.4, light = 9 },
	rail = { core = 1.1, flame = 1.4, sides = 0, color = Color3.fromRGB(140, 226, 255), smoke = 0.2, light = 12 },
	bubble = { core = 0.3, flame = 0, sides = 0, color = Color3.fromRGB(210, 244, 255), smoke = 0, light = 0, bubbles = 7 },
	crossbow = { core = 0, flame = 0, sides = 0, color = Color3.new(1, 1, 1), smoke = 0, light = 0 },

	-- The creative guns (claude-3b's GunModelsCreative). `bubbles` is a burst of sparkles in `bubbleColor`
	-- (a colour or a ColorSequence); `sparks` a burst of sparks whatever the flame. Tune freely.
	squeak = { core = 0.3, flame = 0, sides = 0, color = Color3.fromRGB(255, 226, 110), smoke = 0, light = 0,
		bubbles = 6, bubbleColor = Color3.fromRGB(255, 236, 140) },
	droplets = { core = 0.2, flame = 0, sides = 0, color = Color3.fromRGB(150, 210, 255), smoke = 0, light = 0,
		bubbles = 10, bubbleColor = Color3.fromRGB(120, 196, 255) },
	noodle = { core = 0.5, flame = 0.3, sides = 0, color = Color3.fromRGB(255, 214, 120), smoke = 0.5, light = 4 },
	bassring = { core = 1.2, flame = 0, sides = 0.8, color = Color3.fromRGB(170, 90, 255), smoke = 0, light = 10 },
	gumball = { core = 0.6, flame = 0.2, sides = 0, color = Color3.fromRGB(255, 130, 196), smoke = 0.3, light = 5,
		bubbles = 4, bubbleColor = Color3.fromRGB(255, 150, 210) },
	zap = { core = 1.0, flame = 0, sides = 0.4, color = Color3.fromRGB(140, 214, 255), smoke = 0, light = 10, sparks = 6 },
	disco = { core = 0.9, flame = 0, sides = 0, color = Color3.fromRGB(255, 240, 255), smoke = 0, light = 8, bubbles = 12,
		bubbleColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 120)), ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 220, 80)),
			ColorSequenceKeypoint.new(0.66, Color3.fromRGB(80, 220, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 110, 255)),
		}) },
	snow = { core = 0.4, flame = 0, sides = 0, color = Color3.fromRGB(214, 240, 255), smoke = 0.5, light = 3,
		bubbles = 10, bubbleColor = Color3.fromRGB(248, 252, 255) },
	-- The Lava Lamp Lancer spits molten wax: a fat slow glob of a flash, hot orange, with the smoke of
	-- something burning rather than something fired.
	lava = { core = 0.8, flame = 0.5, sides = 0, color = Color3.fromRGB(255, 130, 40), smoke = 1.1, light = 8,
		bubbles = 5, bubbleColor = Color3.fromRGB(255, 170, 60) },

	-- The workshop guns (WorkshopArsenal): household things, so each muzzle throws what the thing throws.
	leaves = { core = 0.35, flame = 0, sides = 0.3, color = Color3.fromRGB(180, 220, 120), smoke = 0.4, light = 2,
		bubbles = 14, bubbleColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 180, 70)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(214, 166, 60)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 96, 44)),
		}) },
	spray = { core = 0.25, flame = 0, sides = 0, color = Color3.fromRGB(150, 214, 255), smoke = 0, light = 0,
		bubbles = 12, bubbleColor = Color3.fromRGB(120, 196, 255) },
	dust = { core = 0.3, flame = 0, sides = 0.2, color = Color3.fromRGB(206, 196, 176), smoke = 1.3, light = 0,
		bubbles = 8, bubbleColor = Color3.fromRGB(214, 202, 180) },
	confetti = { core = 1.0, flame = 0.2, sides = 0.6, color = Color3.fromRGB(255, 246, 214), smoke = 0.5, light = 9, sparks = 4,
		bubbles = 18, bubbleColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 140)), ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 224, 90)),
			ColorSequenceKeypoint.new(0.7, Color3.fromRGB(90, 226, 180)), ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 130, 255)),
		}) },
	keycap = { core = 0.45, flame = 0.2, sides = 0, color = Color3.fromRGB(226, 236, 255), smoke = 0.2, light = 4, sparks = 3 },
}

-- One emitter host per flash kind is enough: particles live in the world once emitted, so the host can
-- move on to the next shot straight away.
local hosts = {}

local function emitter(parent, name, props)
	local particles = Instance.new("ParticleEmitter")
	particles.Name = name
	particles.Enabled = false
	particles.LightInfluence = 0
	particles.LockedToPart = false
	for property, value in pairs(props) do
		particles[property] = value
	end
	particles.Parent = parent
	return particles
end

local function hostFor(kind)
	local host = hosts[kind]
	if host and host.part.Parent then
		return host
	end
	local spec = FLASH[kind] or FLASH.rifle
	local part = anchoredPart("BRR_FlashHost")
	part.Parent = effects()
	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	local color = spec.color
	host = { part = part, attachment = attachment }
	host.core = emitter(attachment, "Core", {
		Texture = TEXTURE.glow,
		LightEmission = 1,
		Color = CS(color:Lerp(Color3.new(1, 1, 1), 0.45), color),
		Lifetime = NumberRange.new(0.05, 0.07),
		Speed = NumberRange.new(0),
		Rotation = NumberRange.new(0, 360),
		Size = NS({ NSK(0, 0.4), NSK(1, 0.6) }),
		Transparency = NS({ NSK(0, 0), NSK(0.6, 0.3), NSK(1, 1) }),
		ZOffset = 0.2,
	})
	host.flame = emitter(attachment, "Flame", {
		Texture = TEXTURE.fire,
		LightEmission = 1,
		Color = CS(color:Lerp(Color3.new(1, 1, 1), 0.3), color),
		Lifetime = NumberRange.new(0.035, 0.055),
		Speed = NumberRange.new(14, 22),
		EmissionDirection = Enum.NormalId.Front,
		SpreadAngle = Vector2.new(6, 6),
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Size = NS({ NSK(0, 0.18), NSK(1, 0.32) }),
		Squash = NS(-0.6),
		Transparency = NS({ NSK(0, 0.05), NSK(1, 1) }),
	})
	host.sides = emitter(attachment, "Sides", {
		Texture = TEXTURE.fire,
		LightEmission = 1,
		Color = CS(color),
		Lifetime = NumberRange.new(0.04, 0.06),
		Speed = NumberRange.new(10, 16),
		EmissionDirection = Enum.NormalId.Right,
		SpreadAngle = Vector2.new(12, 12),
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Size = NS({ NSK(0, 0.14), NSK(1, 0.26) }),
		Squash = NS(-0.5),
		Transparency = NS({ NSK(0, 0.1), NSK(1, 1) }),
	})
	host.sidesLeft = host.sides:Clone()
	host.sidesLeft.EmissionDirection = Enum.NormalId.Left
	host.sidesLeft.Parent = attachment
	host.smoke = emitter(attachment, "Smoke", {
		Texture = TEXTURE.smoke,
		LightEmission = 0,
		LightInfluence = 1,
		Color = CS(Color3.fromRGB(196, 196, 196)),
		Lifetime = NumberRange.new(0.7, 1.3),
		Speed = NumberRange.new(1.5, 4),
		EmissionDirection = Enum.NormalId.Front,
		SpreadAngle = Vector2.new(25, 25),
		Drag = 4,
		Acceleration = V(0, 1.2, 0),
		RotSpeed = NumberRange.new(-60, 60),
		Rotation = NumberRange.new(0, 360),
		Size = NS({ NSK(0, 0.25), NSK(1, 1.3) }),
		Transparency = NS({ NSK(0, 0.72), NSK(1, 1) }),
	})
	host.sparks = emitter(attachment, "Sparks", {
		Texture = TEXTURE.sparks,
		LightEmission = 1,
		Color = CS(Color3.fromRGB(255, 214, 140)),
		Lifetime = NumberRange.new(0.12, 0.25),
		Speed = NumberRange.new(8, 18),
		EmissionDirection = Enum.NormalId.Front,
		SpreadAngle = Vector2.new(18, 18),
		Drag = 3,
		Size = NS({ NSK(0, 0.05), NSK(1, 0.01) }),
		Transparency = NS({ NSK(0, 0), NSK(1, 1) }),
	})
	local bubbleColor = spec.bubbleColor or Color3.fromRGB(220, 246, 255)
	host.bubbles = emitter(attachment, "Bubbles", {
		Texture = TEXTURE.sparkle,
		LightEmission = 0.4,
		Color = typeof(bubbleColor) == "ColorSequence" and bubbleColor or CS(bubbleColor),
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(4, 9),
		EmissionDirection = Enum.NormalId.Front,
		SpreadAngle = Vector2.new(22, 22),
		Drag = 2.5,
		Acceleration = V(0, 0.6, 0),
		Size = NS({ NSK(0, 0.08), NSK(1, 0.18) }),
		Transparency = NS({ NSK(0, 0.2), NSK(1, 1) }),
	})
	host.light = Instance.new("PointLight")
	host.light.Color = color
	host.light.Brightness = 0
	host.light.Range = spec.light
	host.light.Parent = part
	hosts[kind] = host
	return host
end

function GunFx.Flash(cframe, kind, scale, firstPerson)
	local spec = FLASH[kind] or FLASH.rifle
	if spec.core <= 0 and not spec.bubbles then
		return
	end
	scale = scale or 1
	local host = hostFor(kind)
	-- Particle size is in studs; a flash seen from arm's length reads bigger than one down the street,
	-- so first person draws it a little smaller.
	local size = scale * (firstPerson and 0.8 or 1.25)
	host.part.CFrame = cframe
	if spec.core > 0 then
		host.core.Size = NS({ NSK(0, 0.34 * spec.core * size), NSK(1, 0.5 * spec.core * size) })
		host.core:Emit(2)
	end
	if spec.flame > 0 then
		host.flame.Size = NS({ NSK(0, 0.14 * spec.flame * size), NSK(1, 0.26 * spec.flame * size) })
		host.flame:Emit(math.max(2, math.floor(4 * spec.flame)))
	end
	if spec.sides > 0 then
		host.sides:Emit(math.floor(2 * spec.sides + 0.5))
		host.sidesLeft:Emit(math.floor(2 * spec.sides + 0.5))
	end
	if spec.smoke > 0 then
		host.smoke.Size = NS({ NSK(0, 0.22 * size), NSK(1, 1.1 * spec.smoke * size) })
		host.smoke:Emit(math.max(1, math.floor(2 * spec.smoke)))
	end
	if spec.sparks then
		host.sparks:Emit(spec.sparks)
	elseif spec.flame > 0.5 then
		host.sparks:Emit(math.random(1, 3))
	end
	if spec.bubbles then
		host.bubbles:Emit(spec.bubbles)
	end
	if spec.light > 0 then
		local light = host.light
		light.Brightness = 5
		light.Shadows = firstPerson == true
		local token = (host.lightToken or 0) + 1
		host.lightToken = token
		task.delay(0.05, function()
			if host.lightToken == token then
				light.Brightness = 0
			end
		end)
	end
end

-- A rocket's backblast: a cone of smoke and flame out of the venturi.
function GunFx.Backblast(cframe)
	local host = hostFor("rocket")
	host.part.CFrame = cframe
	host.smoke.Size = NS({ NSK(0, 0.5), NSK(1, 3) })
	host.smoke:Emit(8)
	host.flame:Emit(6)
end

--------------------------------------------------------------------------------
-- Tracers
--------------------------------------------------------------------------------

-- A tracer is two camera-facing beams between a tail and a head that fly down the shot: a hot core
-- and a softer glow round it, bright at the head and fading to nothing along the streak. Beams rather
-- than a stretched neon part, because a part reads as a solid rod from the side and a beam always
-- faces you.
-- How visible a tracer is, over and above the per-kind numbers below, which set each kind's character
-- against the others rather than its absolute size. Against a bright map a tracer read as a thin faint
-- thread, so all three are scaled in one place: wider core, wider and less transparent glow, and a
-- longer streak so a fast round is a line rather than a dot.
local TRACER_CORE, TRACER_GLOW, TRACER_STREAK = 1.6, 1.45, 1.35

local TRACER = {
	bullet = { speed = 950, streak = 7, core = 0.045, glow = 0.2, color = Color3.fromRGB(255, 180, 90), hot = Color3.fromRGB(255, 244, 214) },
	pellet = { speed = 760, streak = 3, core = 0.03, glow = 0.12, color = Color3.fromRGB(255, 170, 90), hot = Color3.fromRGB(255, 236, 200) },
	heavy = { speed = 820, streak = 10, core = 0.07, glow = 0.3, color = Color3.fromRGB(255, 120, 60), hot = Color3.fromRGB(255, 226, 190) },
	energy = { speed = 0, streak = 0, core = 0.12, glow = 0.6, color = Color3.fromRGB(110, 210, 255), hot = Color3.fromRGB(230, 250, 255), life = 0.28 },
	bubble = { speed = 170, projectile = "bubble" },
	rocket = { speed = 170, projectile = "rocket" },
	grenade = { speed = 130, projectile = "grenade" },
	bolt = { speed = 330, projectile = "bolt" },

	-- The creative guns. A streak takes the bullet fields; `projectile = "ball"` flies a ball of `size`
	-- studs in `color` and `material` (with `transparency`).
	squeak = { speed = 620, streak = 3, core = 0.05, glow = 0.22, color = Color3.fromRGB(255, 220, 90), hot = Color3.fromRGB(255, 252, 220) },
	droplets = { speed = 420, streak = 2.5, core = 0.035, glow = 0.14, color = Color3.fromRGB(110, 190, 255), hot = Color3.fromRGB(225, 244, 255) },
	noodle = { speed = 380, streak = 12, core = 0.08, glow = 0.16, color = Color3.fromRGB(240, 206, 120), hot = Color3.fromRGB(255, 240, 200) },
	bassring = { speed = 0, streak = 0, core = 0.16, glow = 0.8, color = Color3.fromRGB(170, 90, 255), hot = Color3.fromRGB(236, 214, 255), life = 0.22 },
	gumball = { speed = 210, projectile = "ball", size = 0.26, color = Color3.fromRGB(255, 110, 180), material = Enum.Material.SmoothPlastic },
	-- The workshop guns: a leaf turning over, a lance of water, broom bristles, a party streamer, a dust
	-- bunny and a keycap.
	leaf = { speed = 150, projectile = "leaf" },
	waterjet = { speed = 240, streak = 9, core = 0.05, glow = 0.24, color = Color3.fromRGB(120, 196, 255), hot = Color3.fromRGB(226, 246, 255) },
	bristle = { speed = 520, streak = 2.5, core = 0.03, glow = 0.12, color = Color3.fromRGB(226, 196, 120), hot = Color3.fromRGB(255, 238, 200) },
	streamer = { speed = 130, projectile = "streamer" },
	dustbunny = { speed = 190, projectile = "ball", size = 0.3, color = Color3.fromRGB(198, 190, 176), material = Enum.Material.Fabric },
	keycap = { speed = 430, projectile = "keycap" },
	zap = { speed = 0, streak = 0, core = 0.08, glow = 0.5, color = Color3.fromRGB(130, 206, 255), hot = Color3.fromRGB(245, 252, 255), life = 0.16 },
	disco = { speed = 900, streak = 6, core = 0.05, glow = 0.28, color = Color3.fromRGB(255, 120, 240), hot = Color3.fromRGB(255, 255, 255) },
	snow = { speed = 240, projectile = "ball", size = 0.24, color = Color3.fromRGB(246, 250, 255), material = Enum.Material.Snow },
	lava = { speed = 300, projectile = "ball", size = 0.3, color = Color3.fromRGB(255, 120, 40), material = Enum.Material.Neon },
}
GunFx.TracerKinds = TRACER

local flying = {}
local MAX_FLYING = 90

local function beam(attachment0, attachment1, width, color, transparency)
	local b = Instance.new("Beam")
	b.Attachment0 = attachment0
	b.Attachment1 = attachment1
	b.FaceCamera = true
	b.Segments = 1
	b.LightEmission = 1
	b.LightInfluence = 0
	b.Width0 = width * 0.35
	b.Width1 = width
	b.Color = CS(color)
	b.Transparency = transparency
	b.Parent = attachment0
	return b
end

local function projectileModel(kind, spec)
	local model = Instance.new("Model")
	local mm = 0.0038
	local function piece(shape, size, cframe, color, material, transparency)
		local part = anchoredPart("Projectile", size)
		part.Shape = shape
		part.CFrame = cframe
		part.Color = color
		part.Material = material
		part.Transparency = transparency or 0
		part.Parent = model
	end
	local along = CFrame.Angles(0, math.pi / 2, 0)
	if kind == "bubble" then
		piece(Enum.PartType.Ball, V(0.36, 0.36, 0.36), CFrame.identity, Color3.fromRGB(210, 240, 255), Enum.Material.Glass, 0.55)
	elseif kind == "rocket" then
		piece(Enum.PartType.Cylinder, V(120 * mm, 85 * mm, 85 * mm), along, Color3.fromRGB(84, 96, 70), Enum.Material.SmoothPlastic)
		piece(Enum.PartType.Cylinder, V(80 * mm, 50 * mm, 50 * mm), CFrame.new(0, 0, -100 * mm) * along, Color3.fromRGB(84, 96, 70), Enum.Material.SmoothPlastic)
		piece(Enum.PartType.Cylinder, V(200 * mm, 38 * mm, 38 * mm), CFrame.new(0, 0, 160 * mm) * along, Color3.fromRGB(60, 64, 56), Enum.Material.Metal)
	elseif kind == "grenade" then
		piece(Enum.PartType.Ball, V(40 * mm, 40 * mm, 40 * mm), CFrame.identity, Color3.fromRGB(84, 96, 70), Enum.Material.SmoothPlastic)
	elseif kind == "bolt" then
		piece(Enum.PartType.Cylinder, V(470 * mm, 8 * mm, 8 * mm), along, Color3.fromRGB(30, 30, 32), Enum.Material.SmoothPlastic)
		piece(Enum.PartType.Cylinder, V(60 * mm, 14 * mm, 14 * mm), CFrame.new(0, 0, 200 * mm) * along, Color3.fromRGB(176, 34, 36), Enum.Material.Fabric)
	elseif kind == "ball" then
		local size = spec and spec.size or 0.25
		piece(Enum.PartType.Ball, V(size, size, size), CFrame.identity, spec and spec.color or Color3.new(1, 1, 1),
			spec and spec.material or Enum.Material.SmoothPlastic, spec and spec.transparency)
	elseif kind == "leaf" then
		piece(Enum.PartType.Block, V(0.34, 0.03, 0.2), CFrame.identity, Color3.fromRGB(126, 186, 74), Enum.Material.Grass)
		piece(Enum.PartType.Block, V(0.36, 0.05, 0.05), CFrame.identity, Color3.fromRGB(92, 132, 56), Enum.Material.Grass)
	elseif kind == "keycap" then
		piece(Enum.PartType.Block, V(0.16, 0.1, 0.16), CFrame.identity, Color3.fromRGB(38, 40, 48), Enum.Material.SmoothPlastic)
		piece(Enum.PartType.Block, V(0.13, 0.03, 0.13), CFrame.new(0, 0.052, 0), Color3.fromRGB(228, 234, 246), Enum.Material.SmoothPlastic)
	elseif kind == "streamer" then
		-- A ribbon: a head and three segments trailing behind it, alternating party colours.
		local colours = { Color3.fromRGB(255, 90, 140), Color3.fromRGB(255, 224, 90), Color3.fromRGB(90, 226, 180), Color3.fromRGB(150, 130, 255) }
		for index = 0, 3 do
			piece(Enum.PartType.Block, V(0.05, 0.02, 0.26), CFrame.new(math.sin(index * 1.7) * 0.06, math.cos(index * 1.3) * 0.05, index * 0.26),
				colours[index + 1], Enum.Material.SmoothPlastic)
		end
	end
	return model
end

-- A smoke trail behind a rocket.
local function trailEmitter(parent)
	return emitter(parent, "Trail", {
		Texture = TEXTURE.smoke,
		LightInfluence = 1,
		Color = CS(Color3.fromRGB(210, 210, 210)),
		Lifetime = NumberRange.new(0.8, 1.4),
		Rate = 60,
		Speed = NumberRange.new(0.5, 1.5),
		Drag = 2,
		Size = NS({ NSK(0, 0.3), NSK(1, 1.6) }),
		Transparency = NS({ NSK(0, 0.5), NSK(1, 1) }),
		Enabled = true,
	})
end

function GunFx.Tracer(origin, target, kind, onArrive)
	local spec = TRACER[kind] or TRACER.bullet
	local delta = target - origin
	local distance = delta.Magnitude
	if distance < 0.5 then
		if onArrive then
			onArrive()
		end
		return
	end
	local direction = delta.Unit
	if #flying >= MAX_FLYING then
		local oldest = table.remove(flying, 1)
		oldest.destroy()
		if oldest.onArrive then
			oldest.onArrive()
		end
	end

	local terrain = workspace.Terrain
	local entry = { origin = origin, direction = direction, distance = distance, spec = spec, travelled = 0, age = 0, onArrive = onArrive }

	if spec.projectile then
		local model = projectileModel(spec.projectile, spec)
		model.Parent = effects()
		entry.model = model
		entry.parts = model:GetChildren()
		entry.offsets = {}
		for _, part in ipairs(entry.parts) do
			entry.offsets[part] = part.CFrame
		end
		if spec.projectile == "rocket" then
			local host = anchoredPart("TrailHost")
			host.Parent = model
			local attachment = Instance.new("Attachment")
			attachment.Position = V(0, 0, 0.8)
			attachment.Parent = host
			entry.trail = trailEmitter(attachment)
			entry.trailHost = host
		end
		entry.destroy = function()
			model:Destroy()
		end
	else
		local tail = Instance.new("Attachment")
		local head = Instance.new("Attachment")
		tail.Parent = terrain
		head.Parent = terrain
		tail.WorldPosition = origin
		head.WorldPosition = origin
		beam(tail, head, spec.core * TRACER_CORE, spec.hot, NS({ NSK(0, 1), NSK(0.6, 0.2), NSK(1, 0) }))
		beam(tail, head, spec.glow * TRACER_GLOW, spec.color, NS({ NSK(0, 1), NSK(0.7, 0.55), NSK(1, 0.25) }))
		entry.tail, entry.head = tail, head
		entry.destroy = function()
			tail:Destroy()
			head:Destroy()
		end
		if spec.speed == 0 then
			-- Energy: the whole line at once, fading.
			head.WorldPosition = target
			entry.instant = true
		end
	end
	table.insert(flying, entry)
end

--------------------------------------------------------------------------------
-- Spent cases and dropped magazines
--------------------------------------------------------------------------------

-- Thrown things fall, bounce off whatever they land on and lie there a while before fading. The
-- physics is a raycast step rather than real parts in the solver: a case weighs nothing, and a hundred
-- of them rattling against a player's feet should cost nothing.
local thrown = {}
local MAX_THROWN = 70
local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude

local CASE = {
	rifle = { length = 0.17, diameter = 0.04, color = Color3.fromRGB(206, 162, 82) },
	pistol = { length = 0.075, diameter = 0.038, color = Color3.fromRGB(206, 162, 82) },
	shell = { length = 0.25, diameter = 0.078, color = Color3.fromRGB(176, 34, 36) },
}

GunFx.IgnoreList = {}

-- Called with (position, kind) the first time a spent case hits something, for its tink. Set by
-- CombatClient; nil means silent.
GunFx.OnCasingLand = nil

local function track(model, parts, velocity, spin, life, sizeHint, casing)
	if #thrown >= MAX_THROWN then
		local oldest = table.remove(thrown, 1)
		oldest.model:Destroy()
	end
	local pivot = model:GetPivot()
	local offsets = {}
	for _, part in ipairs(parts) do
		offsets[part] = pivot:ToObjectSpace(part.CFrame)
	end
	table.insert(thrown, {
		model = model, parts = parts, offsets = offsets, cframe = pivot, velocity = velocity, spin = spin,
		age = 0, life = life, resting = false, radius = sizeHint or 0.05, casing = casing,
	})
end

function GunFx.Casing(cframe, kind)
	local spec = CASE[kind] or CASE.rifle
	local model = Instance.new("Model")
	model.Name = "BRR_Casing"
	local body = anchoredPart("Case", V(spec.length, spec.diameter, spec.diameter))
	body.Shape = Enum.PartType.Cylinder
	body.Transparency = 0
	body.Color = spec.color
	body.Material = kind == "shell" and Enum.Material.SmoothPlastic or Enum.Material.Metal
	body.Reflectance = kind == "shell" and 0 or 0.12
	body.CFrame = cframe * CFrame.Angles(0, math.random() * 0.4, 0)
	body.Parent = model
	if kind == "shell" then
		local base = anchoredPart("CaseBase", V(spec.length * 0.2, spec.diameter * 1.06, spec.diameter * 1.06))
		base.Shape = Enum.PartType.Cylinder
		base.Transparency = 0
		base.Color = Color3.fromRGB(206, 162, 82)
		base.Material = Enum.Material.Metal
		base.CFrame = body.CFrame * CFrame.new(spec.length * 0.42, 0, 0)
		base.Parent = model
	end
	model.Parent = effects()
	-- Out of the port, up and a little back, tumbling.
	local out = cframe.LookVector
	local velocity = out * (5 + math.random() * 2.5) + cframe.UpVector * (3 + math.random() * 2) + cframe.ZVector * (0.5 + math.random())
	local spin = V(math.random() * 30 - 15, math.random() * 30 - 15, math.random() * 30 - 15)
	track(model, model:GetChildren(), velocity, spin, 4, spec.length * 0.5, CASE[kind] and kind or "rifle")
end

function GunFx.Drop(model, up)
	model.Name = "BRR_DroppedMag"
	local parts = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = true
			table.insert(parts, part)
		end
	end
	if #parts == 0 then
		model:Destroy()
		return
	end
	model.PrimaryPart = parts[1]
	model.Parent = effects()
	local _, size = model:GetBoundingBox()
	local velocity = -(up or Vector3.yAxis) * 2 + V(math.random() - 0.5, 0, math.random() - 0.5)
	track(model, parts, velocity, V(math.random() * 4 - 2, math.random() * 2 - 1, math.random() * 4 - 2), 7, math.min(size.X, size.Y, size.Z) * 0.5)
end

--------------------------------------------------------------------------------
-- Impacts
--------------------------------------------------------------------------------

local impactHost = nil
function GunFx.Impact(position, normal)
	if not impactHost or not impactHost.part.Parent then
		local part = anchoredPart("BRR_ImpactHost")
		part.Parent = effects()
		local attachment = Instance.new("Attachment")
		attachment.Parent = part
		impactHost = {
			part = part,
			sparks = emitter(attachment, "Sparks", {
				Texture = TEXTURE.sparks,
				LightEmission = 1,
				Color = CS(Color3.fromRGB(255, 220, 160)),
				Lifetime = NumberRange.new(0.1, 0.3),
				Speed = NumberRange.new(6, 16),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(50, 50),
				Acceleration = V(0, -30, 0),
				Size = NS({ NSK(0, 0.06), NSK(1, 0.01) }),
				Transparency = NS({ NSK(0, 0), NSK(1, 1) }),
			}),
			dust = emitter(attachment, "Dust", {
				Texture = TEXTURE.smoke,
				LightInfluence = 1,
				Color = CS(Color3.fromRGB(170, 160, 148)),
				Lifetime = NumberRange.new(0.4, 0.8),
				Speed = NumberRange.new(1, 3),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(35, 35),
				Drag = 4,
				Size = NS({ NSK(0, 0.2), NSK(1, 0.8) }),
				Transparency = NS({ NSK(0, 0.55), NSK(1, 1) }),
			}),
		}
	end
	normal = normal or Vector3.yAxis
	local up = math.abs(normal.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
	impactHost.part.CFrame = CFrame.lookAt(position, position + normal, up) * CFrame.Angles(-math.pi / 2, 0, 0)
	impactHost.sparks:Emit(math.random(3, 6))
	impactHost.dust:Emit(2)
end

--------------------------------------------------------------------------------
-- The loop
--------------------------------------------------------------------------------

RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 0.1)

	for index = #flying, 1, -1 do
		local entry = flying[index]
		local spec = entry.spec
		entry.age += dt
		if entry.instant then
			local fade = entry.age / (spec.life or 0.25)
			if fade >= 1 then
				entry.destroy()
				table.remove(flying, index)
				if entry.onArrive then
					entry.onArrive()
				end
			end
		else
			entry.travelled = math.min(entry.distance, entry.travelled + spec.speed * dt)
			local head = entry.origin + entry.direction * entry.travelled
			if entry.model then
				local look = CFrame.lookAt(head, head + entry.direction)
				if spec.projectile == "bubble" then
					look = look * CFrame.new(math.sin(entry.age * 18) * 0.08, math.cos(entry.age * 14) * 0.08, 0)
				elseif spec.projectile == "ball" or spec.projectile == "keycap" then
					look = look * CFrame.Angles(entry.age * 12, entry.age * 7, 0)
				elseif spec.projectile == "leaf" then
					-- A leaf turns over and slips from side to side as it flies.
					look = look * CFrame.new(math.sin(entry.age * 9) * 0.22, 0, 0)
						* CFrame.Angles(entry.age * 5, math.sin(entry.age * 7) * 0.6, entry.age * 11)
				elseif spec.projectile == "streamer" then
					look = look * CFrame.Angles(0, 0, math.sin(entry.age * 14) * 0.5)
				end
				local parts, cframes = {}, {}
				for _, part in ipairs(entry.parts) do
					if part:IsA("BasePart") and entry.offsets[part] then
						parts[#parts + 1] = part
						cframes[#cframes + 1] = look * entry.offsets[part]
					end
				end
				if entry.trailHost then
					parts[#parts + 1] = entry.trailHost
					cframes[#cframes + 1] = look
				end
				workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
			else
				entry.head.WorldPosition = head
				entry.tail.WorldPosition = entry.origin + entry.direction * math.max(0, entry.travelled - spec.streak * TRACER_STREAK)
			end
			if entry.travelled >= entry.distance then
				if entry.trail then
					-- Let the smoke already in the air drift off before the host goes.
					entry.trail.Enabled = false
					local model = entry.model
					for _, part in ipairs(entry.parts) do
						if part:IsA("BasePart") and part ~= entry.trailHost then
							part.Transparency = 1
						end
					end
					task.delay(1.5, function()
						model:Destroy()
					end)
				else
					entry.destroy()
				end
				table.remove(flying, index)
				if entry.onArrive then
					entry.onArrive()
				end
			end
		end
	end

	-- Rebuilding the filter copies the whole ignore list, so only on frames something is falling.
	if #thrown > 0 then
		castParams.FilterDescendantsInstances = { effects(), table.unpack(GunFx.IgnoreList) }
	end
	for index = #thrown, 1, -1 do
		local entry = thrown[index]
		entry.age += dt
		if entry.age > entry.life or not entry.model.Parent then
			entry.model:Destroy()
			table.remove(thrown, index)
		else
			if not entry.resting then
				entry.velocity += V(0, -workspace.Gravity * 0.45 * dt, 0)
				local step = entry.velocity * dt
				local from = entry.cframe.Position
				local hit = workspace:Raycast(from, step + step.Unit * entry.radius, castParams)
				if hit then
					if entry.casing and not entry.landed then
						entry.landed = true
						if GunFx.OnCasingLand then
							GunFx.OnCasingLand(hit.Position, entry.casing)
						end
					end
					local normal = hit.Normal
					local along = entry.velocity - normal * entry.velocity:Dot(normal)
					local bounce = -normal * entry.velocity:Dot(normal) * 0.32
					entry.velocity = along * 0.55 + bounce
					entry.spin *= 0.5
					entry.cframe = CFrame.new(hit.Position + normal * entry.radius) * entry.cframe.Rotation
					if entry.velocity.Magnitude < 1.2 then
						entry.resting = true
					end
				else
					entry.cframe = (entry.cframe + step) * CFrame.Angles(entry.spin.X * dt, entry.spin.Y * dt, entry.spin.Z * dt)
				end
				local parts, cframes = {}, {}
				for _, part in ipairs(entry.parts) do
					parts[#parts + 1] = part
					cframes[#cframes + 1] = entry.cframe * entry.offsets[part]
				end
				workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
			end
			local fadeFrom = entry.life - 0.8
			if entry.age > fadeFrom then
				local alpha = (entry.age - fadeFrom) / 0.8
				for _, part in ipairs(entry.parts) do
					part.LocalTransparencyModifier = alpha
				end
			end
		end
	end
end)

return GunFx
