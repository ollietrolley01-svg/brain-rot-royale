-- The silly guns' own explosions, on the client. ModuleScript. ("give the silly explosives their own
-- silly explosion", Oliver, 2026-09-25.) ExplosiveFx.Explosion hands a blast here when its weaponId
-- is in Silly.Weapons; everything else keeps the realistic fireball. tools/silly_explosion_gallery.lua
-- renders each one, tools/silly_explosion_check.py holds the list and the budget.
--
-- LOOK ONLY. The server's blast (damage, radius, wall damage, destruction) is untouched; this draws
-- the same radius in a theme. So that a cartoon blast never reads as harmless, every one that hurts
-- (not the two hit-only rounds) draws the DANGER MARKS first: a bright flash, a see-through dome
-- swelling to exactly the blast radius and a ring racing out to the same radius on the ground.
--
--   theme    weapon                     what it throws
--   coffee   Cappuccina Launcher        a coffee splash (stretched droplets), a foam cloud, a mug-ring stain
--   gold     Golden Sahur Cannon        a fountain of spinning gold coins and a sparkle burst
--   drum     Tamburo Tung Tung          three sound rings (tung, tung, TUNG), drumsticks tumbling out
--   toast    Toaster Mortar             toast slices popping high, a pat of butter, crumbs
--   slipper  Grandma's Slipper (hit)    a cartoon POW star, two slippers bouncing away
--   fidget   Fidget Disc Launcher (hit) spinning fidget spinners skating out
-- Each also pops a comic word (SPLOSH! / KA-CHING! / TUNG! / POP! / POW! / ZING!) on a BillboardGui.
--
-- BUDGET (lag, #131), enforced here and held by tools/silly_explosion_check.py:
--   parts      at most PART_BUDGET parts and adornments per blast (make() refuses past it)
--   particles  at most PARTICLE_BUDGET emitted per blast, from one shared host per theme
--   lifetime   every part is gone within LIFE seconds (the loop's hard end), under the 3 s rule
--   blasts     at most MAX_BLASTS drawn in full at once; past that a new one gets the FAR look
--   distance   full within LOD_FULL studs, MID (half the pieces, no word) to LOD_MID, FAR (the danger
--              marks, two puffs and a few particles) past it; ProjectileClient culls at 650
-- Nothing here touches the map: no wall or prop is faded or moved (#71). Things shrink away (the
-- cartoon pop) rather than fade, so a piece is never a ghost hanging in the air.
--
-- Sound: ProjectileClient plays Silly.Cue(weaponId) ("Explosion" .. theme.sound, e.g.
-- ExplosionCoffee) through Sfx when SoundConfig has that key, and the plain blast cue when not.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundConfig"))

local Silly = {}

Silly.PART_BUDGET = 28
Silly.PARTICLE_BUDGET = 48
Silly.LIFE = 2.5
Silly.MAX_BLASTS = 6
Silly.LOD_FULL = 160
Silly.LOD_MID = 350

-- Which weapons are silly, and their theme. The realistic ones (the Tralala Thumper, the grenades,
-- the mounted and vehicle launchers, the collector's AK, companions, mines and barrels) are
-- deliberately absent; tools/silly_explosion_check.py lists both sides.
Silly.Weapons = {
	CappuccinaLauncher = "coffee",
	GoldenSahurCannon = "gold",
	TamburoTungTung = "drum",
	ToasterMortar = "toast",
	GrandmasSlipperLauncher = "slipper",
	FidgetDiscLauncher = "fidget",
}

-- Parts each piece costs (the check adds these up against PART_BUDGET).
Silly.PieceCost = { droplet = 1, coin = 1, stick = 2, toast = 2, butter = 1, slipper = 2, spinner = 4, pow = 9, soundRing = 1, mugRing = 1 }
-- Parts every blast costs whatever its theme: flash, dome, danger ring, the word's anchor (puffs extra).
Silly.CommonCost = { flash = 1, dome = 1, ring = 1, word = 1 }

local C = Color3.fromRGB

--   hit        a round with no blast: no dome, no ring (it must not look like it has a radius)
--   puffs      cartoon cloud balls; pieces, how many of each; particles { bits, stars, wisps }
Silly.Themes = {
	coffee = {
		sound = "Coffee", word = "SPLOSH!", ink = C(255, 244, 222), stroke = C(96, 52, 22),
		flash = C(255, 226, 170), ring = C(255, 150, 50), puff = C(252, 240, 216),
		puffs = 6, pieces = { droplet = 8, mugRing = 1 },
		particles = { bits = 20, stars = 6, wisps = 8 },
		bit = C(118, 64, 28), star = C(255, 240, 210), wisp = C(255, 250, 240),
	},
	gold = {
		sound = "Gold", word = "KA-CHING!", ink = C(255, 222, 60), stroke = C(110, 64, 10),
		flash = C(255, 244, 170), ring = C(255, 190, 30), puff = C(255, 246, 206),
		puffs = 4, pieces = { coin = 10 },
		particles = { bits = 10, stars = 28, wisps = 0 },
		bit = C(255, 206, 60), star = C(255, 236, 120), wisp = C(255, 250, 230),
	},
	drum = {
		sound = "Drum", word = "TUNG!", ink = C(255, 255, 255), stroke = C(200, 30, 40),
		flash = C(255, 236, 230), ring = C(235, 40, 50), puff = C(255, 250, 246),
		puffs = 4, pieces = { soundRing = 3, stick = 2 },
		particles = { bits = 12, stars = 20, wisps = 0 },
		bit = C(235, 50, 60), star = C(255, 220, 90), wisp = C(255, 255, 255),
	},
	toast = {
		sound = "Toast", word = "POP!", ink = C(255, 236, 190), stroke = C(130, 70, 30),
		flash = C(255, 200, 120), ring = C(255, 130, 40), puff = C(236, 226, 210),
		puffs = 4, pieces = { toast = 3, butter = 1 },
		particles = { bits = 24, stars = 6, wisps = 6 },
		bit = C(196, 132, 64), star = C(255, 230, 150), wisp = C(230, 224, 214),
	},
	slipper = {
		hit = true,
		sound = "Slipper", word = "POW!", ink = C(255, 255, 255), stroke = C(220, 40, 60),
		flash = C(255, 240, 200), ring = C(255, 90, 60), puff = C(255, 250, 250),
		puffs = 3, pieces = { pow = 1, slipper = 2 },
		particles = { bits = 0, stars = 12, wisps = 0 },
		bit = C(255, 150, 190), star = C(255, 230, 80), wisp = C(255, 255, 255),
	},
	fidget = {
		hit = true,
		sound = "Fidget", word = "ZING!", ink = C(120, 255, 210), stroke = C(200, 30, 140),
		flash = C(220, 255, 240), ring = C(90, 255, 200), puff = C(245, 255, 252),
		puffs = 2, pieces = { spinner = 3 },
		particles = { bits = 0, stars = 14, wisps = 0 },
		bit = C(255, 80, 180), star = C(120, 255, 210), wisp = C(255, 255, 255),
	},
}

local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"
local UP = Vector3.yAxis
local V = Vector3.new
local GRAVITY = 196.2
local rng = Random.new()

Silly.Active = 0

function Silly.ThemeFor(weaponId)
	if type(weaponId) ~= "string" then
		return nil
	end
	return Silly.Weapons[weaponId]
end

-- The Sfx key for a themed blast, or nil when SoundConfig has no such key yet (the caller falls back
-- to the plain blast cue, so a missing key is silent, never an error).
function Silly.Cue(weaponId)
	local name = Silly.ThemeFor(weaponId)
	local theme = name and Silly.Themes[name]
	if not theme then
		return nil
	end
	local key = "Explosion" .. theme.sound
	local ok, config = pcall(SoundConfig.Get, key)
	if ok and config then
		return key
	end
	return nil
end

--------------------------------------------------------------------------------
-- Shapes of time
--------------------------------------------------------------------------------

local function clamp01(t)
	return math.clamp(t, 0, 1)
end

local function easeOut(t)
	t = clamp01(t)
	return 1 - (1 - t) ^ 3
end

-- Overshoots to about 1.1 and settles: the cartoon "pop" in.
local function easeOutBack(t)
	t = clamp01(t)
	local c1 = 1.70158
	return 1 + (c1 + 1) * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

-- Popped in over `grow` seconds, gone (shrunk to nothing) over the last `shrink` of `life`.
local function popScale(age, life, grow, shrink)
	local s = easeOutBack(age / grow)
	local left = (life - age) / shrink
	if left < 1 then
		s *= math.max(0, left) ^ 0.7
	end
	return math.max(0, s)
end

local function basis(up)
	local ref = math.abs(up.Y) < 0.99 and UP or Vector3.xAxis
	local right = up:Cross(ref)
	right = right.Magnitude > 1e-3 and right.Unit or Vector3.xAxis
	return right, right:Cross(up).Unit
end

--------------------------------------------------------------------------------
-- Building, inside the budget
--------------------------------------------------------------------------------

-- Every part and adornment of a blast goes through here, and past PART_BUDGET nothing is made.
local function make(b, name, size, cframe, color, material, transparency, shape)
	if b.count >= Silly.PART_BUDGET then
		return nil
	end
	b.count += 1
	local instance = b.api.part(name, size, cframe, color, material, transparency, shape)
	table.insert(b.parts, instance)
	return instance
end

-- A stretchable ball: a block with a sphere mesh, so it can squash and stretch (a Ball can't).
local function blob(b, name, size, cframe, color, material, transparency)
	local instance = make(b, name, size, cframe, color, material, transparency)
	if instance then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = instance
	end
	return instance
end

local function ringOn(b, name, cframe, color, transparency)
	if b.count >= Silly.PART_BUDGET then
		return nil
	end
	b.count += 1
	local ring = Instance.new("CylinderHandleAdornment")
	ring.Name = name
	ring.Adornee = workspace.Terrain
	ring.CFrame = cframe
	ring.Height = 0.3
	ring.Radius = 0.1
	ring.InnerRadius = 0
	ring.Color3 = color
	ring.Transparency = transparency
	ring.AlwaysOnTop = false
	ring.ZIndex = 1
	ring.Parent = workspace.Terrain
	table.insert(b.parts, ring)
	return ring
end

-- A thing thrown out of the blast: parts held at offsets from its centre, flying under (light,
-- cartoon) gravity, spinning about a local axis, bouncing off the blast's surface and shrinking away
-- at the end of its life. `subs` is { { part, size, at, turn } }.
local function flyer(b, subs, velocity, options)
	if #subs == 0 then
		return nil
	end
	local f = {
		subs = subs,
		position = b.position + b.up * (options.lift or 0.5),
		velocity = velocity,
		rotation = options.rotation or CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)),
		axis = options.axis or V(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)).Unit,
		rate = options.rate or 8,
		gravity = options.gravity or 0.45,
		bounce = options.bounce or 0.5,
		radius = options.radius or 0.4,
		life = math.min(options.life or 1.6, Silly.LIFE - 0.05),
		stretch = options.stretch,
		grow = options.grow or 0.1,
		splat = options.splat,
	}
	table.insert(b.flyers, f)
	return f
end

local function sub(part, at, turn)
	return { part = part, size = part.Size, at = at or Vector3.zero, turn = turn or CFrame.identity }
end

local function stepFlyers(b, age, dt)
	for _, f in ipairs(b.flyers) do
		if f.gone then
			continue
		end
		if age >= f.life then
			f.gone = true
			for _, s in ipairs(f.subs) do
				s.part:Destroy()
			end
			continue
		end
		f.velocity -= UP * (GRAVITY * f.gravity * dt)
		f.position += f.velocity * dt
		if b.ground then
			local height = (f.position - b.ground):Dot(b.up)
			local into = f.velocity:Dot(b.up)
			if height < f.radius and into < 0 then
				f.position += b.up * (f.radius - height)
				if f.splat then
					-- A droplet lands and is gone in a blink.
					f.velocity = Vector3.zero
					f.life = math.min(f.life, age + 0.12)
				else
					f.velocity = (f.velocity - b.up * into) * 0.8 - b.up * (into * f.bounce)
					f.rate *= 0.7
				end
			end
		end
		local s = popScale(age, f.life, f.grow, 0.3)
		local frame
		if f.stretch then
			-- Stretched along its flight, thinner as it goes faster (squash and stretch).
			local speed = f.velocity.Magnitude
			local k = 1 + math.clamp(speed / 30, 0, 1.3)
			local part = f.subs[1].part
			local base = f.subs[1].size
			part.Size = V(base.X / math.sqrt(k), base.Y / math.sqrt(k), base.Z * k) * s
			part.CFrame = speed > 0.1 and CFrame.lookAt(f.position, f.position + f.velocity) or CFrame.new(f.position)
		else
			f.rotation = f.rotation * CFrame.fromAxisAngle(f.axis, f.rate * dt)
			frame = CFrame.new(f.position) * f.rotation
			for _, piece in ipairs(f.subs) do
				piece.part.Size = piece.size * math.max(s, 0.01)
				piece.part.CFrame = frame * CFrame.new(piece.at * s) * piece.turn
			end
		end
	end
end

--------------------------------------------------------------------------------
-- The pieces
--------------------------------------------------------------------------------

local function outward(b, index, count, horizontal, vertical, jitter)
	local angle = (index - 1) / count * math.pi * 2 + rng:NextNumber(-jitter, jitter)
	local flat = b.right * math.cos(angle) + b.forward * math.sin(angle)
	return flat * horizontal * rng:NextNumber(0.8, 1.15) + b.up * vertical * rng:NextNumber(0.85, 1.15)
end

local BUILD = {}

function BUILD.droplet(b, count, theme)
	local w = math.clamp(b.radius * 0.09, 0.55, 1.3)
	for index = 1, count do
		local drop = blob(b, "CoffeeDrop", V(w, w, w * 1.2), CFrame.new(b.position), theme.bit, Enum.Material.SmoothPlastic, 0)
		if not drop then
			return
		end
		drop.Reflectance = 0.15
		flyer(b, { sub(drop) }, outward(b, index, count, b.radius * 1.5, b.radius * 1.5, 0.3), {
			stretch = true, gravity = 0.6, life = rng:NextNumber(0.9, 1.2), splat = true, radius = w * 0.5, lift = b.radius * 0.15,
		})
	end
end

function BUILD.coin(b, count)
	local d = math.clamp(b.radius * 0.28, 0.9, 1.6)
	for index = 1, count do
		local coin = make(b, "GoldCoin", V(d * 0.16, d, d), CFrame.new(b.position), C(255, 196, 36), Enum.Material.SmoothPlastic, 0, Enum.PartType.Cylinder)
		if not coin then
			return
		end
		coin.Reflectance = 0.25
		local rim = index % 2 == 0 and C(255, 214, 80) or C(245, 176, 20)
		coin.Color = rim
		flyer(b, { sub(coin) }, outward(b, index, count, rng:NextNumber(3, 9), rng:NextNumber(26, 38), 0.6), {
			axis = V(0, 1, 0), rate = rng:NextNumber(10, 18), gravity = 0.5, bounce = 0.45, radius = d * 0.5,
			life = rng:NextNumber(1.8, 2.3), rotation = CFrame.Angles(0, rng:NextNumber(0, 6.28), math.pi / 2 + rng:NextNumber(-0.4, 0.4)),
		})
	end
end

function BUILD.stick(b, count)
	for index = 1, count do
		local shaft = make(b, "Drumstick", V(2.6, 0.24, 0.24), CFrame.new(b.position), C(226, 190, 140), Enum.Material.Wood, 0, Enum.PartType.Cylinder)
		local tip = make(b, "DrumstickTip", V(0.46, 0.46, 0.46), CFrame.new(b.position), C(255, 250, 240), Enum.Material.SmoothPlastic, 0, Enum.PartType.Ball)
		local subs = {}
		if shaft then
			table.insert(subs, sub(shaft))
		end
		if tip then
			table.insert(subs, sub(tip, V(1.3, 0, 0)))
		end
		flyer(b, subs, outward(b, index, count, 12, 26, 0.5), { rate = 13, gravity = 0.5, bounce = 0.5, radius = 0.3, life = 1.9, lift = b.radius * 0.3 })
	end
end

function BUILD.toast(b, count)
	for index = 1, count do
		local crust = make(b, "ToastCrust", V(1.9, 1.9, 0.38), CFrame.new(b.position), C(168, 100, 44), Enum.Material.SmoothPlastic)
		local face = make(b, "ToastFace", V(1.6, 1.55, 0.42), CFrame.new(b.position), C(244, 208, 140), Enum.Material.SmoothPlastic)
		local subs = {}
		if crust then
			table.insert(subs, sub(crust))
		end
		if face then
			table.insert(subs, sub(face, V(0, -0.1, 0)))
		end
		flyer(b, subs, outward(b, index, count, 7, 34, 0.4), { rate = 7, gravity = 0.5, bounce = 0.35, radius = 0.5, life = 2.2 })
	end
end

function BUILD.butter(b, count)
	for index = 1, count do
		local pat = make(b, "Butter", V(0.9, 0.34, 0.65), CFrame.new(b.position), C(255, 232, 110), Enum.Material.SmoothPlastic)
		if pat then
			flyer(b, { sub(pat) }, outward(b, index, count, 10, 22, 3), { rate = 9, gravity = 0.5, bounce = 0.3, radius = 0.2, life = 2 })
		end
	end
end

function BUILD.slipper(b, count)
	for index = 1, count do
		local sole = make(b, "Slipper", V(0.75, 0.24, 1.7), CFrame.new(b.position), C(255, 140, 186), Enum.Material.SmoothPlastic)
		local strap = make(b, "SlipperStrap", V(0.82, 0.3, 0.55), CFrame.new(b.position), C(255, 244, 250), Enum.Material.SmoothPlastic)
		local subs = {}
		if sole then
			table.insert(subs, sub(sole))
		end
		if strap then
			table.insert(subs, sub(strap, V(0, 0.2, -0.35)))
		end
		flyer(b, subs, outward(b, index, count, 13, 17, 0.8), { rate = 11, gravity = 0.5, bounce = 0.6, radius = 0.15, life = 1.7 })
	end
end

function BUILD.spinner(b, count, theme)
	for index = 1, count do
		local subs = {}
		local hub = make(b, "SpinnerHub", V(0.55, 0.55, 0.55), CFrame.new(b.position), C(245, 245, 250), Enum.Material.SmoothPlastic, 0, Enum.PartType.Ball)
		if hub then
			table.insert(subs, sub(hub))
		end
		for lobe = 1, 3 do
			local angle = (lobe - 1) / 3 * math.pi * 2
			local disc = make(b, "SpinnerLobe", V(0.22, 0.75, 0.75), CFrame.new(b.position), lobe == 1 and theme.bit or theme.star,
				lobe == 1 and Enum.Material.SmoothPlastic or Enum.Material.Neon, 0, Enum.PartType.Cylinder)
			if disc then
				-- A cylinder's length is its X; turned so the disc lies flat in the spinner's plane.
				table.insert(subs, sub(disc, V(math.cos(angle), 0, math.sin(angle)) * 0.62, CFrame.Angles(0, 0, math.pi / 2)))
			end
		end
		flyer(b, subs, outward(b, index, count, 20, 9, 0.4), {
			axis = V(0, 1, 0), rate = 32, gravity = 0.4, bounce = 0.5, radius = 0.15, life = 1.7,
			rotation = CFrame.Angles(rng:NextNumber(-0.25, 0.25), 0, rng:NextNumber(-0.25, 0.25)),
		})
	end
end

-- The POW star: a spiky burst facing the camera, popping in with an overshoot and a wobble.
function BUILD.pow(b)
	local camera = workspace.CurrentCamera
	local towards = camera and (camera.CFrame.Position - b.position) or b.forward
	towards = towards.Magnitude > 0.1 and towards.Unit or b.forward
	local centre = b.position + towards * 0.6 + b.up * 0.6
	local subs = {}
	local disc = make(b, "PowCentre", V(0.2, 1.9, 1.9), CFrame.new(centre), C(255, 226, 50), Enum.Material.Neon, 0, Enum.PartType.Cylinder)
	if disc then
		table.insert(subs, sub(disc, Vector3.zero, CFrame.Angles(0, math.pi / 2, 0)))
	end
	for index = 1, 8 do
		local long = index % 2 == 1
		local length = long and 3.4 or 2.3
		local spike = make(b, "PowSpike", V(length, 0.55, 0.12), CFrame.new(centre), long and C(255, 214, 40) or C(255, 84, 50), Enum.Material.Neon)
		if spike then
			local angle = (index - 1) / 8 * math.pi * 2
			local turn = CFrame.Angles(0, 0, angle)
			table.insert(subs, sub(spike, turn:VectorToWorldSpace(V(length * 0.45, 0, 0)), turn))
		end
	end
	local look = CFrame.lookAt(centre, centre + towards)
	flyer(b, subs, Vector3.zero, {
		rotation = look.Rotation, axis = V(0, 0, 1), rate = 1.2, gravity = 0, life = 0.75, grow = 0.14, lift = 0,
	})
	if #b.flyers > 0 then
		b.flyers[#b.flyers].position = centre
	end
end

-- Three sound rings racing out one after another (tung, tung, TUNG), each to the blast radius.
function BUILD.soundRing(b, count)
	local colours = { C(235, 40, 50), C(255, 255, 255), C(255, 206, 60) }
	for index = 1, count do
		local ring = ringOn(b, "SoundRing", b.api.surfaceFrame(b.position + b.up * (b.radius * 0.3 + 0.5 * index), b.up), colours[(index - 1) % 3 + 1], 0.05)
		if ring then
			table.insert(b.rings, { ring = ring, delay = (index - 1) * 0.16, reach = b.radius, span = 0.34 })
		end
	end
end

-- The mug ring: a brown ring stain where the cup "stood", popping in and shrinking away before 3 s.
function BUILD.mugRing(b)
	if not b.ground then
		return
	end
	local ring = ringOn(b, "MugRing", b.api.surfaceFrame(b.ground + b.up * 0.08, b.up), C(110, 62, 26), 0.1)
	if ring then
		ring.Height = 0.12
		b.mug = { ring = ring, reach = math.clamp(b.radius * 0.42, 2, 6) }
	end
end

local PIECE_ORDER = { "pow", "soundRing", "mugRing", "droplet", "coin", "toast", "butter", "stick", "slipper", "spinner" }

--------------------------------------------------------------------------------
-- Particles: one shared host per theme (particles live on in the world once emitted)
--------------------------------------------------------------------------------

local hosts = {}

local function hostFor(api, name, theme)
	local host = hosts[name]
	if host and host.part.Parent then
		return host
	end
	local holder = api.part("BRR_SillyHost", V(0.1, 0.1, 0.1), CFrame.identity, Color3.new(), nil, 1)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	host = { part = holder }
	host.bits = api.emitter(attachment, "Bits", {
		Texture = api.texture.glow,
		LightEmission = 0.3,
		Color = ColorSequence.new(theme.bit),
		Lifetime = NumberRange.new(0.5, 1.1),
		SpreadAngle = Vector2.new(70, 70),
		Acceleration = V(0, -70, 0),
		Drag = 1.2,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0.15) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.8, 0.1), NumberSequenceKeypoint.new(1, 1) }),
	})
	host.stars = api.emitter(attachment, "Stars", {
		Texture = SPARKLES,
		LightEmission = 1,
		Color = ColorSequence.new(theme.star),
		Lifetime = NumberRange.new(0.5, 1.2),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = V(0, -10, 0),
		Drag = 2,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-200, 200),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(0.5, 0.9), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.3) }),
	})
	host.wisps = api.emitter(attachment, "Wisps", {
		Texture = api.texture.smoke,
		LightInfluence = 1,
		Color = ColorSequence.new(theme.wisp),
		Lifetime = NumberRange.new(0.8, 1.4),
		Speed = NumberRange.new(4, 9),
		SpreadAngle = Vector2.new(35, 35),
		Acceleration = V(0, 8, 0),
		Drag = 1.5,
		Rotation = NumberRange.new(0, 360),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 4) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) }),
	})
	hosts[name] = host
	return host
end

local function emitParticles(b, name, theme, share)
	local want = theme.particles
	local host = hostFor(b.api, name, theme)
	host.part.CFrame = CFrame.fromMatrix(b.position + b.up * 0.4, b.right, b.up)
	local left = Silly.PARTICLE_BUDGET
	for _, key in ipairs({ "bits", "stars", "wisps" }) do
		local count = math.min(left, math.ceil((want[key] or 0) * share))
		if count > 0 then
			local emitter = host[key]
			if key ~= "wisps" then
				emitter.Speed = NumberRange.new(math.max(6, b.radius * 1.3), math.max(12, b.radius * 2.8))
			end
			emitter:Emit(count)
			left -= count
		end
	end
end

--------------------------------------------------------------------------------
-- The blast
--------------------------------------------------------------------------------

local LOD = {
	full = { pieces = 1, puffs = 1, particles = 1, word = true },
	mid = { pieces = 0.5, puffs = 0.5, particles = 0.5, word = false },
	far = { pieces = 0, puffs = 0.34, particles = 0.25, word = false },
}
Silly.Lod = LOD

function Silly.LodFor(position)
	if Silly.ForceLod then
		return Silly.ForceLod
	end
	if Silly.Active >= Silly.MAX_BLASTS then
		return "far"
	end
	local camera = workspace.CurrentCamera
	local distance = camera and (camera.CFrame.Position - position).Magnitude or 0
	if distance <= Silly.LOD_FULL then
		return "full"
	elseif distance <= Silly.LOD_MID then
		return "mid"
	end
	return "far"
end

-- `api` is ExplosiveFx's (part, emitter, add, destroyParts, surfaceFrame, texture); `radius` is the
-- server's blast radius, which the dome and the ring reach exactly; `ground` is where the blast met a
-- surface (nil in the air).
function Silly.Blast(api, name, position, up, radius, ground)
	local theme = Silly.Themes[name]
	if not theme then
		return nil
	end
	local lodName = Silly.LodFor(position)
	local lod = LOD[lodName]
	up = up.Magnitude > 0.1 and up.Unit or UP
	local right, forward = basis(up)
	local r = math.max(2, radius)
	local b = {
		api = api, theme = theme, position = position, up = up, right = right, forward = forward,
		radius = r, ground = ground, count = 0, parts = {}, flyers = {}, rings = {}, puffs = {}, lod = lodName,
	}
	Silly.Active += 1

	-- The danger marks, first and always (except on a hit-only round): nobody reads this as harmless.
	local flashSize = theme.hit and 2.4 or r * 0.95
	local flash = blob(b, "SillyFlash", V(1, 1, 1), CFrame.new(position + up * 0.4), theme.flash, Enum.Material.Neon, 0)
	local light
	if flash then
		light = Instance.new("PointLight")
		light.Color = theme.flash
		light.Range = theme.hit and 12 or math.min(60, r * 3)
		light.Brightness = 5
		light.Shadows = false
		light.Parent = flash
	end
	local dome, ring
	if not theme.hit then
		dome = make(b, "SillyDome", V(1, 1, 1), CFrame.new(position), theme.ring, Enum.Material.SmoothPlastic, 0.7, Enum.PartType.Ball)
		if ground then
			ring = ringOn(b, "DangerRing", api.surfaceFrame(ground + up * 0.15, up), theme.ring, 0.05)
		end
	end

	-- The cartoon cloud: round puffs in a ring, swelling with a squash and floating up.
	local puffCount = math.max(theme.hit and 1 or 2, math.floor(theme.puffs * lod.puffs + 0.5))
	local puffSize = theme.hit and 1.6 or math.clamp(r * 0.42, 1.6, 6.5)
	for index = 1, puffCount do
		local angle = (index - 1) / puffCount * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local offset = (right * math.cos(angle) + forward * math.sin(angle)) * (theme.hit and 0.9 or r * 0.3) + up * (puffSize * 0.35)
		local puff = blob(b, "SillyPuff", V(1, 1, 1), CFrame.new(position + offset), theme.puff, Enum.Material.SmoothPlastic, 0)
		if puff then
			table.insert(b.puffs, {
				part = puff, offset = offset, size = puffSize * rng:NextNumber(0.8, 1.2), delay = rng:NextNumber(0.03, 0.12),
				life = rng:NextNumber(1.05, 1.35), rise = puffSize * rng:NextNumber(0.5, 0.9), wobble = rng:NextNumber(0, 6.28),
			})
		end
	end

	-- The theme's own pieces, in budget order.
	if lod.pieces > 0 then
		for _, piece in ipairs(PIECE_ORDER) do
			local count = theme.pieces[piece]
			if count then
				count = piece == "pow" and 1 or math.max(1, math.ceil(count * lod.pieces))
				BUILD[piece](b, count, theme)
			end
		end
	end

	-- The word: a comic pop that squashes in and bounces out.
	local word, anchor
	if lod.word then
		anchor = make(b, "SillyWord", V(0.2, 0.2, 0.2), CFrame.new(position + up * ((theme.hit and 2.6 or r * 0.55) + 1.2)), Color3.new(), nil, 1)
		if anchor then
			word = Instance.new("BillboardGui")
			word.Name = "Word"
			word.Adornee = anchor
			word.LightInfluence = 0
			word.AlwaysOnTop = false
			word.MaxDistance = Silly.LOD_FULL
			word.Size = UDim2.fromScale(0, 0)
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Text = theme.word
			label.Font = Enum.Font.FredokaOne
			label.TextScaled = true
			label.TextColor3 = theme.ink
			label.TextStrokeColor3 = theme.stroke
			label.TextStrokeTransparency = 0
			label.Rotation = rng:NextNumber(-12, 12)
			local stroke = Instance.new("UIStroke")
			stroke.Color = theme.stroke
			stroke.Thickness = 3
			stroke.Parent = label
			label.Parent = word
			word.Parent = anchor
		end
	end
	local wordWidth = theme.hit and 5 or math.clamp(r * 0.85, 5, 11)

	emitParticles(b, name, theme, lod.particles)

	local last = 0
	api.add({
		life = Silly.LIFE,
		parts = b.parts,
		update = function(_, age)
			local dt = math.max(0, age - last)
			last = age
			-- Flash: stretched tall as it bursts, squashed wide as it peaks, popped away by 0.32 s.
			if flash and flash.Parent then
				local t = age / 0.32
				if t < 1 then
					local grow = easeOut(t * 2.4)
					local shrink = t < 0.55 and 1 or math.max(0, 1 - (t - 0.55) / 0.45) ^ 0.6
					local size = flashSize * grow * shrink
					local squash = t < 0.2 and 0.75 or 1.25
					flash.Size = V(size * squash, size / squash, size * squash)
					if light then
						light.Brightness = 5 * (1 - t)
					end
				else
					flash:Destroy()
				end
			end
			-- The dome: out to exactly the blast radius in a fifth of a second, then thinning away.
			if dome and dome.Parent then
				local t = age / 0.45
				if t < 1 then
					local size = r * 2 * easeOut(t / 0.45)
					dome.Size = V(size, size, size)
					dome.Transparency = 0.7 + 0.3 * clamp01((t - 0.45) / 0.55)
				else
					dome:Destroy()
				end
			end
			-- The danger ring: races out to the radius, holds a bold rim there, thins and goes.
			if ring and ring.Parent then
				local t = age / 0.85
				if t < 1 then
					local reach = 0.5 + (r - 0.5) * easeOut(age / 0.22)
					local band = math.max(0.35, r * 0.12) * (t < 0.7 and 1 or 1 - (t - 0.7) / 0.3)
					ring.Radius = reach
					ring.InnerRadius = math.max(0, reach - math.max(0.1, band))
					ring.Transparency = t < 0.7 and 0.05 or 0.05 + 0.95 * (t - 0.7) / 0.3
				else
					ring:Destroy()
				end
			end
			for _, puff in ipairs(b.puffs) do
				if puff.part.Parent then
					local t = age - puff.delay
					if t >= puff.life then
						puff.part:Destroy()
					elseif t > 0 then
						local s = popScale(t, puff.life, 0.2, 0.35) * puff.size
						local squash = 1 + 0.18 * math.sin(t * 14 + puff.wobble) * math.max(0, 1 - t)
						puff.part.Size = V(s * squash, s / squash, s * squash)
						puff.part.CFrame = CFrame.new(position + puff.offset * (1 + t * 0.6) + up * (puff.rise * easeOut(t / puff.life)))
					else
						puff.part.Size = Vector3.zero
					end
				end
			end
			for _, sound in ipairs(b.rings) do
				if sound.ring.Parent then
					local t = (age - sound.delay) / sound.span
					if t >= 1 then
						sound.ring:Destroy()
					elseif t > 0 then
						local reach = 0.5 + (sound.reach - 0.5) * easeOut(t)
						sound.ring.Radius = reach
						sound.ring.InnerRadius = math.max(0, reach - 0.55)
						sound.ring.Transparency = 0.05 + 0.95 * t * t
					else
						sound.ring.Transparency = 1
					end
				end
			end
			if b.mug and b.mug.ring.Parent then
				local s = popScale(math.max(0, age - 0.1), 2.3, 0.2, 0.4)
				local reach = b.mug.reach * s
				b.mug.ring.Radius = math.max(0.05, reach)
				b.mug.ring.InnerRadius = math.max(0, reach - 0.55 * s)
			end
			if word and word.Parent then
				local s = popScale(age, 1.15, 0.16, 0.2)
				local squash = 1 + 0.15 * math.sin(age * 20) * math.max(0, 1 - age * 1.6)
				word.Size = UDim2.fromScale(wordWidth * s * squash, wordWidth * 0.42 * s / squash)
				if age >= 1.15 then
					anchor:Destroy()
				end
			end
			stepFlyers(b, age, dt)
		end,
		destroy = function(entry)
			api.destroyParts(entry)
			Silly.Active = math.max(0, Silly.Active - 1)
		end,
	})
	return b
end

return Silly
