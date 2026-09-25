-- The silly guns' own explosions, on the client. ModuleScript. ("give the silly explosives their own
-- silly explosion", Oliver, 2026-09-25; "way higher quality, at least up to the standard of the
-- current grenades", the same day.) tools/silly_explosion_gallery.lua renders each one beside the
-- grenade; tools/silly_explosion_check.py holds the list and the budget.
--
-- A silly blast IS the grenade's blast: ExplosiveFx.Explosion draws every layer of it (flash and
-- light, the fireball cluster running down its colour ramp, the shockwave shell, the shock ring and
-- dust ring on the ground, sparks, embers, smoke, the column), only in the theme's palette (its
-- `look`), and then hands over to Extras here for the theme's own pieces in place of the rock
-- chunks and the scorch. So each one has the grenade's structure, timing and blast read, and on top:
--
--   theme    weapon                       palette (the blast's layers)           pieces (Extras)
--   coffee   Cappuccina Launcher          foam cloud, latte smoke, steam plume   a liquid splash crown, droplets, a mug-ring stain
--   gold     Golden Sahur Cannon          gold flash, gold fire, golden smoke    a burst of spinning coins, glints
--   party    Tamburo Tung Tung            party-coloured puffs and smoke         fluttering confetti, spiralling streamers
--   toast    Toaster Mortar               toasty fire, crumb sparks, toast smoke toast slices popping high, a pat of butter
--   slipper  Grandma's Slipper (hit)      a dust puff and impact ring            two slippers tumbling away in an arc
--   fidget   Fidget Disc Launcher (hit)   a mint flash, a shower of sparks       spinners skating out, each with a trail
--
-- No words and no cartoon stars (Oliver): the theme is in the materials, shapes and debris alone.
--
-- LOOK ONLY. The server's blast (damage, radius, wall damage, destruction) is untouched. So that no
-- theme ever reads as harmless, every one that hurts also draws a DANGER RING on the ground at
-- exactly the server's radius, on top of the grenade's own shock ring and shell.
--
-- BUDGET (lag, #131), enforced here and held by tools/silly_explosion_check.py:
--   parts      the grenade's own layers, plus at most EXTRA_BUDGET pieces and adornments per blast
--              (make() refuses past it)
--   particles  the grenade's counts times the look's shares (never above 2x a layer), plus at most
--              EXTRA_PARTICLES from the theme's own host
--   lifetime   every piece is gone within LIFE seconds (the loop's hard end), under the 3 s rule
--   blasts     at most MAX_BLASTS drawn in full at once; past that a new one gets the FAR look
--   distance   full within LOD_FULL studs, MID (half the pieces, 0.6 of the particles) to LOD_MID,
--              FAR (no pieces, the danger ring, 0.35 of the particles) past it; the client culls at 650
-- Nothing here touches the map: no wall or prop is faded or moved (#71). Pieces shrink away at the
-- end of their life rather than fading, so none hangs in the air as a ghost.
--
-- Sound: ProjectileClient plays Silly.Cue(weaponId) ("Explosion" .. theme.sound, e.g.
-- ExplosionCoffee) through Sfx when SoundConfig has that key, and the plain blast cue when not.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundConfig"))

local Silly = {}

Silly.EXTRA_BUDGET = 26
Silly.EXTRA_PARTICLES = 30
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
	TamburoTungTung = "party",
	ToasterMortar = "toast",
	GrandmasSlipperLauncher = "slipper",
	FidgetDiscLauncher = "fidget",
}

-- Parts each piece costs (the check adds these up against EXTRA_BUDGET).
Silly.PieceCost = { sheet = 1, droplet = 1, mugRing = 1, coin = 1, confetti = 1, streamer = 3, toast = 2, butter = 1, slipper = 3, spinner = 7, dangerRing = 1 }

local C = Color3.fromRGB
local CS = ColorSequence.new
local NS = NumberSequence.new
local NSK = NumberSequenceKeypoint.new

local function rainbow(colours)
	local keys = {}
	for index, colour in ipairs(colours) do
		table.insert(keys, ColorSequenceKeypoint.new((index - 1) / (#colours - 1), colour))
	end
	return CS(keys)
end

local PARTY = { C(255, 60, 170), C(40, 200, 255), C(255, 214, 40), C(160, 80, 255), C(90, 230, 90), C(255, 120, 60) }
local GLOW = "rbxasset://textures/glow.png"
local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"

--   look       the blast's palette (ExplosiveFx.Explosion reads it: flash, light, ramps, coreNeon,
--              ballScale, wave, ring, dust, sparks, embers, smoke, flames, column, columnTime,
--              sparkShare/emberShare/smokeShare)
--   hit        a round with no blast: no danger ring (it must not look like it has a radius)
--   pieces     how many of each piece; particles, the theme host's { glints, bits }
Silly.Themes = {
	coffee = {
		sound = "Coffee",
		pieces = { sheet = 8, droplet = 10, mugRing = 1 },
		particles = { glints = 0, bits = 18 },
		glint = C(255, 250, 235), bit = C(110, 60, 26),
		look = {
			flash = C(255, 240, 215), light = C(255, 190, 120),
			ramps = {
				{ C(255, 253, 247), C(250, 238, 215), C(222, 196, 160), C(205, 186, 166) },
				{ C(236, 196, 150), C(150, 88, 42), C(110, 64, 30), C(150, 118, 92) },
				{ C(252, 244, 230), C(232, 208, 170), C(190, 145, 100), C(176, 150, 124) },
			},
			coreNeon = false, ballScale = 1.05,
			wave = C(255, 246, 232), ring = C(170, 100, 45), dust = C(180, 140, 100),
			sparks = CS(C(255, 236, 200), C(205, 150, 95)), sparkShare = 0.6,
			embers = CS(C(255, 246, 225), C(230, 200, 160)),
			smoke = CS(C(150, 104, 66), C(215, 190, 160)),
			flames = false,
			column = CS(C(255, 255, 255), C(232, 232, 238)), columnTime = 0.9,
		},
	},
	gold = {
		sound = "Gold",
		pieces = { coin = 14 },
		particles = { glints = 24, bits = 0 },
		glint = C(255, 244, 170), bit = C(255, 206, 60),
		look = {
			flash = C(255, 244, 200), light = C(255, 196, 70),
			ramps = {
				{ C(255, 252, 225), C(255, 214, 80), C(236, 160, 30), C(170, 124, 56) },
				{ C(255, 246, 200), C(255, 196, 40), C(210, 140, 20), C(146, 110, 64) },
			},
			wave = C(255, 240, 200), ring = C(255, 200, 60), dust = C(220, 195, 130),
			sparks = CS(C(255, 252, 220), C(255, 196, 40)), sparkShare = 1.5,
			embers = CS(C(255, 222, 90), C(230, 160, 30)),
			smoke = CS(C(150, 108, 36), C(205, 170, 96)), smokeShare = 0.7,
			flames = CS(C(255, 245, 190), C(255, 180, 40)),
			column = CS(C(160, 118, 44), C(210, 180, 110)),
		},
	},
	party = {
		sound = "Party",
		pieces = { confetti = 14, streamer = 3 },
		particles = { glints = 14, bits = 16 },
		glint = C(255, 255, 255), bit = C(255, 120, 220),
		look = {
			flash = C(255, 246, 252), light = C(255, 120, 220),
			ramps = {
				{ C(255, 240, 250), C(255, 60, 170), C(255, 140, 205), C(255, 215, 235) },
				{ C(235, 255, 255), C(40, 200, 255), C(130, 220, 255), C(210, 240, 255) },
				{ C(255, 255, 230), C(255, 214, 40), C(255, 230, 120), C(255, 245, 200) },
				{ C(245, 235, 255), C(160, 80, 255), C(200, 150, 255), C(235, 220, 255) },
				{ C(240, 255, 235), C(90, 230, 90), C(160, 240, 150), C(220, 250, 215) },
			},
			wave = C(255, 240, 252), ring = C(255, 80, 200), dust = C(255, 205, 235),
			sparks = rainbow(PARTY), sparkShare = 1.4,
			embers = rainbow({ C(255, 150, 220), C(150, 220, 255), C(255, 240, 150) }),
			smoke = CS(C(235, 80, 175), C(100, 130, 235)), smokeShare = 0.55,
			flames = false,
			column = CS(C(240, 110, 190), C(140, 110, 240)), columnTime = 0.8,
		},
	},
	toast = {
		sound = "Toast",
		pieces = { toast = 3, butter = 1 },
		particles = { glints = 0, bits = 20 },
		glint = C(255, 240, 200), bit = C(196, 132, 64),
		look = {
			flash = C(255, 232, 185), light = C(255, 170, 80),
			ramps = { { C(255, 244, 210), C(252, 196, 100), C(206, 128, 56), C(120, 82, 54) } },
			ring = C(255, 150, 60), dust = C(190, 150, 110),
			sparks = CS(C(240, 190, 120), C(170, 110, 50)),
			embers = CS(C(255, 170, 70), C(230, 100, 30)),
			smoke = CS(C(95, 75, 60), C(150, 130, 112)),
			column = CS(C(90, 72, 60), C(145, 128, 112)),
		},
	},
	slipper = {
		hit = true,
		sound = "Slipper",
		pieces = { slipper = 2 },
		particles = { glints = 0, bits = 10 },
		glint = C(255, 255, 255), bit = C(255, 190, 215),
		look = {
			flash = C(255, 248, 240), light = C(255, 200, 220),
			ramps = { { C(250, 242, 232), C(236, 218, 202), C(214, 196, 180), C(196, 186, 176) } },
			coreNeon = false, ballScale = 1.2,
			wave = C(255, 244, 248), ring = C(255, 160, 200), dust = C(215, 195, 180),
			sparks = CS(C(255, 225, 238), C(255, 255, 255)),
			embers = CS(C(255, 190, 215)),
			smoke = CS(C(205, 190, 175), C(235, 225, 215)),
			flames = false,
		},
	},
	fidget = {
		hit = true,
		sound = "Fidget",
		pieces = { spinner = 3 },
		particles = { glints = 12, bits = 0 },
		glint = C(160, 255, 225), bit = C(255, 80, 180),
		look = {
			flash = C(225, 255, 248), light = C(110, 255, 215),
			ramps = {
				{ C(235, 255, 250), C(90, 255, 200), C(150, 240, 220), C(210, 245, 240) },
				{ C(255, 235, 250), C(255, 80, 190), C(255, 160, 220), C(250, 225, 240) },
			},
			wave = C(225, 255, 248), ring = C(90, 255, 200), dust = C(200, 225, 220),
			sparks = CS(C(170, 255, 230), C(255, 100, 200)), sparkShare = 2,
			embers = CS(C(120, 255, 210)),
			smoke = CS(C(220, 235, 235)), smokeShare = 0.5,
			flames = false,
		},
	},
}
for name, theme in pairs(Silly.Themes) do
	theme.look.key = name
end

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
-- Level of detail
--------------------------------------------------------------------------------

local LOD = {
	full = { pieces = 1, share = 1 },
	mid = { pieces = 0.5, share = 0.6 },
	far = { pieces = 0, share = 0.35 },
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

-- The palette ExplosiveFx.Explosion draws this theme's blast in, with the level of detail for a blast
-- at `position` folded in (`share` thins its particles, `lod` tells Extras how many pieces).
function Silly.LookFor(name, position)
	local theme = Silly.Themes[name]
	local lod = Silly.LodFor(position)
	return setmetatable({ lod = lod, share = LOD[lod].share }, { __index = theme.look })
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

-- Popped in over `grow` seconds (a slight overshoot), shrunk to nothing over the last `shrink` of `life`.
local function popScale(age, life, grow, shrink)
	local t = clamp01(age / grow)
	local s = 1 + 2.2 * (t - 1) ^ 3 + 1.2 * (t - 1) ^ 2
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

-- Every piece and adornment of a blast's extras goes through here, and past EXTRA_BUDGET nothing is made.
local function make(b, name, size, cframe, color, material, transparency, shape)
	if b.count >= Silly.EXTRA_BUDGET then
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
	if b.count >= Silly.EXTRA_BUDGET then
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

local function sub(part, at, turn)
	return { part = part, size = part.Size, at = at or Vector3.zero, turn = turn or CFrame.identity }
end

-- A thing thrown out of the blast: parts held at offsets from its centre, flying under gravity,
-- spinning about a local axis, bouncing off the blast's surface and shrinking away at the end of its
-- life. `flutter`: paper (confetti) -- after its first burst it sails down slowly, swaying.
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
		grow = options.grow or 0.08,
		splat = options.splat,
		flutter = options.flutter,
		phase = rng:NextNumber(0, 6.28),
		sway = (b.right * rng:NextNumber(-1, 1) + b.forward * rng:NextNumber(-1, 1)).Unit,
	}
	table.insert(b.flyers, f)
	return f
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
		if f.flutter and age > 0.2 then
			-- Paper: air takes its speed, it falls no faster than a few studs a second, and it swings.
			local vertical = math.max(f.velocity.Y, -6)
			local flat = V(f.velocity.X, 0, f.velocity.Z) * math.max(0, 1 - dt * 3)
			f.velocity = flat + UP * vertical
			f.position += f.sway * (math.cos(age * 7 + f.phase) * 2.2 * dt)
		end
		f.position += f.velocity * dt
		if b.ground then
			local height = (f.position - b.ground):Dot(b.up)
			local into = f.velocity:Dot(b.up)
			if height < f.radius and into < 0 then
				f.position += b.up * (f.radius - height)
				if f.splat then
					f.velocity = Vector3.zero
					f.life = math.min(f.life, age + 0.1)
				else
					f.velocity = (f.velocity - b.up * into) * 0.7 - b.up * (into * f.bounce)
					f.rate *= 0.6
				end
			end
		end
		local s = popScale(age, f.life, f.grow, 0.3)
		if f.stretch then
			-- A droplet: stretched along its flight, thinner the faster it goes.
			local speed = f.velocity.Magnitude
			local k = 1 + math.clamp(speed / 25, 0, 1.6)
			local piece = f.subs[1]
			piece.part.Size = V(piece.size.X / math.sqrt(k), piece.size.Y / math.sqrt(k), piece.size.Z * k) * math.max(s, 0.01)
			piece.part.CFrame = speed > 0.1 and CFrame.lookAt(f.position, f.position + f.velocity) or CFrame.new(f.position)
		else
			f.rotation = f.rotation * CFrame.fromAxisAngle(f.axis, f.rate * dt)
			local frame = CFrame.new(f.position) * f.rotation
			for _, piece in ipairs(f.subs) do
				piece.part.Size = piece.size * math.max(s, 0.01)
				piece.part.CFrame = frame * CFrame.new(piece.at * s) * piece.turn
			end
		end
	end
end

-- A ribbon: flat segments laid along the recent path of a point, a streamer's own flight or a
-- flyer's (a spinner's trail). The newest segment is the widest; the tail tapers.
local SAMPLE = 0.035
local function ribbon(b, segments, width, colours, material, follow, velocity, curl, life)
	local rb = { segs = {}, hist = {}, width = width, follow = follow, velocity = velocity, curl = curl or 0, life = math.min(life, Silly.LIFE - 0.05), last = -1 }
	rb.position = follow and follow.position or (b.position + b.up * 0.6)
	for index = 1, segments do
		local seg = make(b, "Ribbon", V(width, 0.06, 0.1), CFrame.new(rb.position), colours[(index - 1) % #colours + 1], material)
		if not seg then
			break
		end
		table.insert(rb.segs, seg)
	end
	if #rb.segs == 0 then
		return nil
	end
	table.insert(b.ribbons, rb)
	return rb
end

local function stepRibbons(b, age, dt)
	for _, rb in ipairs(b.ribbons) do
		if rb.gone then
			continue
		end
		if age >= rb.life or (rb.follow and rb.follow.gone) then
			rb.gone = true
			for _, seg in ipairs(rb.segs) do
				seg:Destroy()
			end
			continue
		end
		if rb.follow then
			rb.position = rb.follow.position
		else
			-- A streamer: flung out and up, its heading curling round (the spiral), then sailing down.
			rb.velocity -= UP * (GRAVITY * 0.3 * dt)
			local flat = V(rb.velocity.X, 0, rb.velocity.Z)
			local turn = CFrame.fromAxisAngle(UP, rb.curl * dt)
			flat = turn:VectorToWorldSpace(flat) * math.max(0, 1 - dt * 0.8)
			rb.velocity = flat + UP * math.max(rb.velocity.Y, -7)
			rb.position += rb.velocity * dt
		end
		if age - rb.last >= SAMPLE then
			rb.last = age
			table.insert(rb.hist, 1, rb.position)
			if #rb.hist > #rb.segs + 2 then
				table.remove(rb.hist)
			end
		end
		-- The path: where it is now, then each sample back in time (samples on top of it skipped).
		local points = { rb.position }
		for _, point in ipairs(rb.hist) do
			if (point - points[#points]).Magnitude > 0.05 then
				table.insert(points, point)
			end
		end
		local shrink = math.clamp((rb.life - age) / 0.3, 0, 1)
		for index, seg in ipairs(rb.segs) do
			local from, to = points[index], points[index + 1]
			if not to then
				seg.Size = V(0.01, 0.01, 0.01)
			else
				local w = rb.width * (1 - (index - 1) / #rb.segs * 0.55) * shrink
				seg.Size = V(math.max(0.01, w), 0.06, (from - to).Magnitude + 0.05)
				seg.CFrame = CFrame.lookAt((from + to) / 2, to) * CFrame.Angles(0, 0, age * 9 + index)
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

-- The coffee's splash: a crown of liquid sheets thrown up and out round the blast, falling back.
function BUILD.sheet(b, count)
	local r = b.radius
	for index = 1, count do
		local angle = (index - 1) / count * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
		local colour = index % 2 == 0 and C(150, 88, 38) or C(112, 62, 26)
		local sheet = blob(b, "CoffeeSheet", V(1, 1, 1), CFrame.new(b.position), colour, Enum.Material.SmoothPlastic, 0)
		if not sheet then
			return
		end
		sheet.Reflectance = 0.12
		table.insert(b.sheets, { part = sheet, angle = angle, height = r * rng:NextNumber(0.7, 0.9), width = r * rng:NextNumber(0.34, 0.42), delay = rng:NextNumber(0, 0.05) })
	end
end

function BUILD.droplet(b, count)
	local w = math.clamp(b.radius * 0.09, 0.6, 1.4)
	for index = 1, count do
		local colour = index % 3 == 0 and C(236, 214, 180) or C(118, 66, 28)
		local drop = blob(b, "CoffeeDrop", V(w, w, w * 1.3), CFrame.new(b.position), colour, Enum.Material.SmoothPlastic, 0)
		if not drop then
			return
		end
		drop.Reflectance = 0.15
		flyer(b, { sub(drop) }, outward(b, index, count, b.radius * 1.4, b.radius * 1.7, 0.3), {
			stretch = true, gravity = 0.6, life = rng:NextNumber(0.9, 1.3), splat = true, radius = w * 0.5, lift = b.radius * 0.2,
		})
	end
end

-- The mug ring: a coffee stain where the cup "stood", there until the blast's pieces are gone.
function BUILD.mugRing(b)
	if not b.ground then
		return
	end
	local ring = ringOn(b, "MugRing", b.api.surfaceFrame(b.ground + b.up * 0.08, b.up), C(96, 54, 22), 0.15)
	if ring then
		ring.Height = 0.1
		b.mug = { ring = ring, reach = math.clamp(b.radius * 0.35, 2, 5) }
	end
end

function BUILD.coin(b, count)
	local d = math.clamp(b.radius * 0.24, 0.9, 1.5)
	for index = 1, count do
		local shade = index % 3 == 0 and C(255, 222, 90) or (index % 3 == 1 and C(255, 190, 30) or C(236, 164, 20))
		local coin = make(b, "GoldCoin", V(d * 0.14, d, d), CFrame.new(b.position), shade, Enum.Material.Foil, 0, Enum.PartType.Cylinder)
		if not coin then
			return
		end
		coin.Reflectance = 0.15
		flyer(b, { sub(coin) }, outward(b, index, count, rng:NextNumber(5, 12), rng:NextNumber(24, 40), 0.6), {
			axis = V(0, 1, 0), rate = rng:NextNumber(12, 22), gravity = 0.55, bounce = 0.45, radius = d * 0.5,
			life = rng:NextNumber(1.9, 2.4), rotation = CFrame.Angles(0, rng:NextNumber(0, 6.28), math.pi / 2 + rng:NextNumber(-0.5, 0.5)),
		})
	end
end

function BUILD.confetti(b, count)
	for index = 1, count do
		local colour = PARTY[(index - 1) % #PARTY + 1]
		local long = index % 3 == 0
		local piece = make(b, "Confetti", long and V(0.45, 0.06, 1.4) or V(0.9, 0.06, 0.65), CFrame.new(b.position), colour, Enum.Material.SmoothPlastic)
		if not piece then
			return
		end
		flyer(b, { sub(piece) }, outward(b, index, count, rng:NextNumber(8, 18), rng:NextNumber(18, 32), 0.5), {
			flutter = true, rate = rng:NextNumber(9, 16), gravity = 0.5, bounce = 0.1, radius = 0.05, life = rng:NextNumber(2, 2.4), lift = 1,
		})
	end
end

function BUILD.streamer(b, count)
	for index = 1, count do
		local colour = PARTY[(index * 2 - 1) % #PARTY + 1]
		local velocity = outward(b, index, count, rng:NextNumber(10, 14), rng:NextNumber(24, 30), 0.4)
		ribbon(b, 3, 0.75, { colour, colour:Lerp(C(255, 255, 255), 0.25) }, Enum.Material.SmoothPlastic, nil, velocity, (index % 2 == 0 and 1 or -1) * 6, 2.2)
	end
end

function BUILD.toast(b, count)
	for index = 1, count do
		local crust = make(b, "ToastCrust", V(2.6, 2.6, 0.5), CFrame.new(b.position), C(160, 94, 40), Enum.Material.SmoothPlastic)
		local face = make(b, "ToastFace", V(2.2, 2.15, 0.56), CFrame.new(b.position), C(236, 196, 124), Enum.Material.Sand)
		local subs = {}
		if crust then
			table.insert(subs, sub(crust))
		end
		if face then
			table.insert(subs, sub(face, V(0, -0.14, 0)))
		end
		flyer(b, subs, outward(b, index, count, 8, 36, 0.4), { rate = 7, gravity = 0.5, bounce = 0.35, radius = 0.5, life = 2.3 })
	end
end

function BUILD.butter(b, count)
	for index = 1, count do
		local pat = make(b, "Butter", V(1.2, 0.45, 0.85), CFrame.new(b.position), C(255, 230, 110), Enum.Material.SmoothPlastic)
		if pat then
			flyer(b, { sub(pat) }, outward(b, index, count, 11, 24, 3), { rate = 9, gravity = 0.5, bounce = 0.3, radius = 0.2, life = 2.1 })
		end
	end
end

function BUILD.slipper(b, count)
	for index = 1, count do
		local sole = make(b, "Slipper", V(1.15, 0.38, 2.6), CFrame.new(b.position), C(255, 120, 172), Enum.Material.SmoothPlastic)
		local strap = make(b, "SlipperStrap", V(1.22, 0.48, 0.9), CFrame.new(b.position), C(255, 244, 248), Enum.Material.SmoothPlastic)
		local pom = make(b, "SlipperPom", V(0.7, 0.7, 0.7), CFrame.new(b.position), C(255, 200, 225), Enum.Material.SmoothPlastic, 0, Enum.PartType.Ball)
		local subs = {}
		if sole then
			table.insert(subs, sub(sole))
		end
		if strap then
			table.insert(subs, sub(strap, V(0, 0.3, -0.6)))
		end
		if pom then
			table.insert(subs, sub(pom, V(0, 0.65, -0.6)))
		end
		-- A proper arc: up and away, spinning end over end about its width, bouncing once or twice.
		flyer(b, subs, outward(b, index, count, 13, 22, 0.7), {
			axis = V(1, 0, 0), rate = rng:NextNumber(11, 15), gravity = 0.6, bounce = 0.45, radius = 0.2, life = 1.9,
			rotation = CFrame.Angles(0, (index - 1) * math.pi + rng:NextNumber(-0.5, 0.5), 0),
		})
	end
end

function BUILD.spinner(b, count, theme)
	for index = 1, count do
		local subs = {}
		local hub = make(b, "SpinnerHub", V(0.55, 0.55, 0.55), CFrame.new(b.position), C(235, 238, 245), Enum.Material.Metal, 0, Enum.PartType.Ball)
		if hub then
			table.insert(subs, sub(hub))
		end
		for lobe = 1, 3 do
			local angle = (lobe - 1) / 3 * math.pi * 2
			local disc = make(b, "SpinnerLobe", V(0.22, 0.75, 0.75), CFrame.new(b.position), lobe == 1 and theme.bit or theme.glint,
				lobe == 1 and Enum.Material.SmoothPlastic or Enum.Material.Neon, 0, Enum.PartType.Cylinder)
			if disc then
				-- A cylinder's length is its X; turned so the disc lies flat in the spinner's plane.
				table.insert(subs, sub(disc, V(math.cos(angle), 0, math.sin(angle)) * 0.62, CFrame.Angles(0, 0, math.pi / 2)))
			end
		end
		local f = flyer(b, subs, outward(b, index, count, 22, 10, 0.4), {
			axis = V(0, 1, 0), rate = 34, gravity = 0.4, bounce = 0.5, radius = 0.15, life = 1.8,
			rotation = CFrame.Angles(rng:NextNumber(-0.25, 0.25), 0, rng:NextNumber(-0.25, 0.25)),
		})
		if f then
			ribbon(b, 3, 0.5, { theme.glint, theme.bit }, Enum.Material.Neon, f, nil, 0, 1.8)
		end
	end
end

local PIECE_ORDER = { "sheet", "mugRing", "droplet", "coin", "streamer", "confetti", "toast", "butter", "slipper", "spinner" }

--------------------------------------------------------------------------------
-- The theme's own particles: one shared host per theme (particles live on once emitted)
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
	host.glints = api.emitter(attachment, "Glints", {
		Texture = SPARKLES,
		LightEmission = 1,
		Color = CS(theme.glint),
		Lifetime = NumberRange.new(0.5, 1.2),
		SpreadAngle = Vector2.new(60, 60),
		Acceleration = V(0, -30, 0),
		Drag = 1.5,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-220, 220),
		Size = NS({ NSK(0, 0.9), NSK(0.3, 1.3), NSK(1, 0) }),
		Transparency = NS({ NSK(0, 0), NSK(1, 0.2) }),
	})
	host.bits = api.emitter(attachment, "Bits", {
		Texture = GLOW,
		LightEmission = 0,
		LightInfluence = 1,
		Color = CS(theme.bit),
		Lifetime = NumberRange.new(0.5, 1.1),
		SpreadAngle = Vector2.new(70, 70),
		Acceleration = V(0, -80, 0),
		Drag = 1,
		Size = NS({ NSK(0, 0.45), NSK(1, 0.2) }),
		Transparency = NS({ NSK(0, 0), NSK(0.8, 0.1), NSK(1, 1) }),
	})
	hosts[name] = host
	return host
end

local function emitParticles(b, name, theme, share)
	local host = hostFor(b.api, name, theme)
	host.part.CFrame = CFrame.fromMatrix(b.position + b.up * 0.4, b.right, b.up)
	local left = Silly.EXTRA_PARTICLES
	for _, key in ipairs({ "glints", "bits" }) do
		local count = math.min(left, math.floor((theme.particles[key] or 0) * share + 0.5))
		if count > 0 then
			local particles = host[key]
			particles.Speed = NumberRange.new(math.max(8, b.radius * 1.4), math.max(16, b.radius * 3))
			particles:Emit(count)
			left -= count
		end
	end
end

--------------------------------------------------------------------------------
-- The extras
--------------------------------------------------------------------------------

-- Called by ExplosiveFx.Explosion after it has drawn the blast's layers in `look`. `api` is
-- ExplosiveFx's (part, emitter, add, destroyParts, surfaceFrame); `radius` is the server's blast
-- radius, which the danger ring reaches exactly; `ground` is where the blast met a surface (nil in
-- the air).
function Silly.Extras(api, name, look, position, up, radius, ground)
	local theme = Silly.Themes[name]
	if not theme then
		return nil
	end
	local lod = LOD[look.lod or "full"]
	up = up.Magnitude > 0.1 and up.Unit or UP
	local right, forward = basis(up)
	local r = math.max(2, radius)
	local b = {
		api = api, position = position, up = up, right = right, forward = forward, radius = r, ground = ground,
		count = 0, parts = {}, flyers = {}, ribbons = {}, sheets = {},
	}
	-- Only blasts count toward the crowd cap: a stream of slipper or disc hits must not push the
	-- next real explosion down to the FAR look.
	local counted = not theme.hit
	if counted then
		Silly.Active += 1
	end

	-- The danger ring, always (except on a hit-only round): a bold rim at exactly the blast radius.
	local ring
	if not theme.hit and ground then
		ring = ringOn(b, "DangerRing", api.surfaceFrame(ground + up * 0.15, up), look.ring or C(255, 150, 50), 0.05)
	end

	if lod.pieces > 0 then
		for _, piece in ipairs(PIECE_ORDER) do
			local count = theme.pieces[piece]
			if count then
				BUILD[piece](b, math.max(1, math.ceil(count * lod.pieces)), theme)
			end
		end
	end
	emitParticles(b, name, theme, look.share or 1)

	local last = 0
	api.add({
		life = Silly.LIFE,
		parts = b.parts,
		update = function(_, age)
			local dt = math.max(0, age - last)
			last = age
			if ring and ring.Parent then
				local t = age / 0.85
				if t < 1 then
					local reach = 0.5 + (r - 0.5) * easeOut(age / 0.22)
					local band = math.max(0.35, r * 0.1) * (t < 0.7 and 1 or 1 - (t - 0.7) / 0.3)
					ring.Radius = reach
					ring.InnerRadius = math.max(0, reach - math.max(0.1, band))
					ring.Transparency = t < 0.7 and 0.05 or 0.05 + 0.95 * (t - 0.7) / 0.3
				else
					ring:Destroy()
				end
			end
			-- The splash crown: each sheet rises and leans out, then falls back and thins away by 0.8 s.
			for _, sheet in ipairs(b.sheets) do
				if sheet.part.Parent then
					local t = (age - sheet.delay) / 0.8
					if t >= 1 then
						sheet.part:Destroy()
					else
						t = math.max(0, t)
						local rise = easeOut(t / 0.35)
						local fall = t < 0.45 and 1 or math.max(0, 1 - (t - 0.45) / 0.55)
						local height = sheet.height * rise * fall
						local lean = math.rad(20 + 45 * t)
						local flat = right * math.cos(sheet.angle) + forward * math.sin(sheet.angle)
						local base = position + flat * (r * (0.16 + 0.3 * t))
						local tangent = flat:Cross(up)
						local axis = (up * math.cos(lean) + flat * math.sin(lean)).Unit
						sheet.part.Size = V(sheet.width * (0.6 + 0.4 * rise), math.max(0.05, height), 0.55 * fall + 0.05)
						sheet.part.CFrame = CFrame.fromMatrix(base + axis * (height * 0.5), tangent, axis)
					end
				end
			end
			if b.mug and b.mug.ring.Parent then
				local s = popScale(math.max(0, age - 0.15), 2.25, 0.25, 0.4)
				local reach = b.mug.reach * s
				b.mug.ring.Radius = math.max(0.05, reach)
				b.mug.ring.InnerRadius = math.max(0, reach - 0.5 * s)
			end
			stepFlyers(b, age, dt)
			stepRibbons(b, age, dt)
		end,
		destroy = function(entry)
			api.destroyParts(entry)
			if counted then
				Silly.Active = math.max(0, Silly.Active - 1)
			end
		end,
	})
	return b
end

return Silly
