-- Explosions, smoke clouds and the splat where a bullet lands, on the client. ModuleScript.
-- ProjectileClient and HitSplatClient call in here; tools/throwables_gallery.lua renders frozen
-- frames of each.
--
--   ExplosiveFx.Explosion(position, normal, kind, radius, weaponId)
--                                                            a rocket, 40mm or frag going off; a
--                                                            silly gun's weaponId draws its themed
--                                                            blast instead (SillyExplosionFx)
--   ExplosiveFx.Impact(position, normal, weaponId)           a round that only hits (no blast)
--   ExplosiveFx.ThemeCue(weaponId)                           the themed blast's Sfx key, or nil
--   ExplosiveFx.Cloud(position, spec, elapsed)               a smoke cloud `elapsed` seconds into
--                                                            its life; returns its handle
--   ExplosiveFx.Splat(limb, position, normal, options)       a hit mark on a body part in the firing
--                                                            gun's RANK COLOUR (options.color, which
--                                                            every caller must pass -- there is no
--                                                            blood in this game); options.headshot
--                                                            (bigger), options.shield (blue chips)
--   ExplosiveFx.Trail(part)                                  a rocket's exhaust and glow on a model
--   ExplosiveFx.Loop(cueName, part)                          a looping cue following a part (whoosh)
--   ExplosiveFx.Advance(dt)                                  one frame of every live effect
--   ExplosiveFx.Paused                                       true: nothing moves unless Advance is
--                                                            called by hand (the gallery)
--   ExplosiveFx.Clouds                                       live clouds { position, radius, density }
--                                                            for the inside-the-smoke overlay
--
-- Every effect is a function of its age, stepped by Advance, rather than a set of tweens: a frame
-- can be frozen at any moment for the gallery, and the same code draws it live. Textures are the
-- ones the Roblox client ships (the same set GunFx renders). Everything is capped, so a fight with
-- forty bots throwing grenades stays a few hundred instances at worst.
--
-- A smoke cloud is a lumpy ball of OPAQUE parts inside a shell of see-through ones. Only opaque
-- geometry occludes, so the opaque core is what hides nameplates and bodies behind it at every
-- graphics setting; the shell and the particle wisps soften its edge into smoke. From inside, the
-- backs of the balls aren't drawn, so ProjectileClient covers the screen instead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))
-- The silly guns' own blasts (confetti, coffee, coins...): same radius, drawn in a theme.
local SillyExplosionFx = require(script.Parent:WaitForChild("SillyExplosionFx"))

local ExplosiveFx = {}

ExplosiveFx.Paused = false
ExplosiveFx.Clouds = {}

local V = Vector3.new
local NS = NumberSequence.new
local NSK = NumberSequenceKeypoint.new
local CS = ColorSequence.new
local UP = Vector3.yAxis

local TEXTURE = {
	glow = "rbxasset://textures/glow.png",
	fire = "rbxasset://textures/particles/fire_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	sparks = "rbxasset://textures/particles/fire_sparks_main.dds",
}

local GRAVITY = 196.2
local MAX_DEBRIS = 60
-- A scorch is nine patches now (see scorch), so fewer are kept.
local MAX_SCORCH = 20
-- A splat is about 24 parts now (halo, blot, tongues, droplets, runs), so fewer are kept at once.
local MAX_SPLATS = 30

-- How each kind of blast looks, all sized from the blast radius.
--   balls     fireballs; scale, how big the whole thing is against the radius
--   light     the flash's PointLight range
--   smoke, sparks, embers   particle counts
--   debris    chunks thrown out; scorch, the mark left, its width as a share of the radius (0 for
--             none; never wider than SCORCH_WIDEST)
--   column    seconds of rising smoke after the fireball
local KIND = {
	rocket = { balls = 9, scale = 1.0, light = 70, smoke = 26, sparks = 44, embers = 24, debris = 10, scorch = 0.55, column = 1.4 },
	grenade = { balls = 6, scale = 0.85, light = 48, smoke = 16, sparks = 26, embers = 14, debris = 6, scorch = 0.45, column = 0.8 },
	frag = { balls = 8, scale = 1.0, light = 62, smoke = 22, sparks = 56, embers = 20, debris = 10, scorch = 0.5, column = 1.1 },
	impact = { balls = 2, scale = 0.35, light = 18, smoke = 5, sparks = 12, embers = 4, debris = 3, scorch = 0, column = 0 },
}

local FIRE_HOT = Color3.fromRGB(255, 240, 190)
local FIRE = Color3.fromRGB(255, 168, 56)
local FIRE_DEEP = Color3.fromRGB(255, 96, 24)
local FIRE_DONE = Color3.fromRGB(96, 30, 18)
local SMOKE_DARK = Color3.fromRGB(52, 48, 46)
-- There is no blood in this game: a splat is drawn in the RANK COLOUR of the gun that dealt the hit
-- (HitSplatService sends the rank, HitSplatClient turns it into Rarity.Color). This is only what a
-- caller that forgot to pass one gets -- Common's own grey, matching Rarity.Colors.Common -- and
-- forgetting is warned about rather than quietly coloured. The old red constants are deliberately
-- gone: an unreferenced red is a trap for the next caller.
local SPLAT_DEFAULT = Color3.fromRGB(178, 184, 196)
local warnedColourless = false
local SHIELD = Color3.fromRGB(120, 200, 255)

local function clamp01(t)
	return math.clamp(t, 0, 1)
end

local function easeOut(t)
	t = clamp01(t)
	return 1 - (1 - t) * (1 - t)
end

local function smooth(t)
	t = clamp01(t)
	return t * t * (3 - 2 * t)
end

local folder = nil
local function effects()
	if not folder or not folder.Parent then
		folder = Instance.new("Folder")
		folder.Name = "BRR_ExplosiveFx"
		folder.Parent = workspace
	end
	return folder
end
ExplosiveFx.Folder = effects

local function part(name, size, cframe, color, material, transparency, shape)
	local instance = Instance.new("Part")
	instance.Name = name
	if shape then
		instance.Shape = shape
	end
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = color
	instance.Material = material or Enum.Material.SmoothPlastic
	instance.Transparency = transparency or 0
	instance.Anchored = true
	instance.CanCollide = false
	instance.CanQuery = false
	instance.CanTouch = false
	instance.CastShadow = false
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance.Parent = effects()
	return instance
end

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

-- A frame whose -Z is `normal`: parts built in it with their thin axis along Z lie on the surface.
local function surfaceFrame(position, normal)
	local up = math.abs(normal.Y) < 0.99 and UP or Vector3.xAxis
	return CFrame.lookAt(position, position + normal, up)
end

-- A cylinder's length runs along its X. This puts X along the frame's -Z (the normal).
local ALONG_NORMAL = CFrame.Angles(0, math.pi / 2, 0)

--------------------------------------------------------------------------------
-- The loop
--------------------------------------------------------------------------------

-- Every live effect: { age, life, update(entry, age), destroy(entry) }.
local live = {}
local debris = {}

local function add(entry)
	entry.age = entry.age or 0
	table.insert(live, entry)
	if entry.update then
		entry.update(entry, entry.age)
	end
	return entry
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.IgnoreWater = true

local function refreshGround()
	local include = { workspace.Terrain }
	for _, name in ipairs({ "Map", "Defenses", "Deployables" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(include, instance)
		end
	end
	groundParams.FilterDescendantsInstances = include
end

local function stepDebris(dt)
	for index = #debris, 1, -1 do
		local chunk = debris[index]
		chunk.age += dt
		local part = chunk.part
		if chunk.age >= chunk.life or not part.Parent then
			part:Destroy()
			table.remove(debris, index)
		else
			if not chunk.resting then
				chunk.velocity -= UP * (GRAVITY * dt)
				local displacement = chunk.velocity * dt
				local hit = displacement.Magnitude > 1e-4 and workspace:Raycast(chunk.position, displacement + displacement.Unit * chunk.radius, groundParams) or nil
				if hit then
					local into = chunk.velocity:Dot(hit.Normal)
					chunk.position = hit.Position + hit.Normal * chunk.radius
					chunk.velocity = (chunk.velocity - hit.Normal * into) * 0.6 - hit.Normal * (into * 0.3)
					chunk.spin *= 0.5
					if chunk.velocity.Magnitude < 3 and hit.Normal.Y > 0.5 then
						chunk.resting = true
						chunk.velocity = Vector3.zero
					end
				else
					chunk.position += displacement
				end
				if chunk.spin.Magnitude > 1e-4 then
					chunk.rotation = chunk.rotation * CFrame.fromAxisAngle(chunk.spin.Unit, chunk.spin.Magnitude * dt)
				end
			end
			part.CFrame = CFrame.new(chunk.position) * chunk.rotation
			local left = chunk.life - chunk.age
			if left < 1 then
				part.Transparency = 1 - left
			end
		end
	end
end

function ExplosiveFx.Advance(dt)
	dt = math.min(dt, 0.1)
	if #debris > 0 then
		refreshGround()
		stepDebris(dt)
	end
	for index = #live, 1, -1 do
		local entry = live[index]
		entry.age += dt
		if entry.age >= entry.life or (entry.alive and not entry.alive(entry)) then
			entry.destroy(entry)
			table.remove(live, index)
		else
			entry.update(entry, entry.age)
		end
	end
end

RunService.RenderStepped:Connect(function(dt)
	if not ExplosiveFx.Paused then
		ExplosiveFx.Advance(dt)
	end
end)

local function destroyParts(entry)
	for _, instance in ipairs(entry.parts) do
		if instance.Parent then
			instance:Destroy()
		end
	end
end

--------------------------------------------------------------------------------
-- Particle hosts, one per blast kind (particles live on in the world once emitted)
--------------------------------------------------------------------------------

local hosts = {}

-- `look`: a themed blast's palette (SillyExplosionFx), nil for the realistic one. A theme gets its own
-- host, so its colours are set once, never swapped back and forth under particles still in flight.
local function hostFor(kind, look)
	look = look or {}
	local key = look.key and (kind .. ":" .. look.key) or kind
	local host = hosts[key]
	if host and host.part.Parent then
		return host
	end
	local holder = part("BRR_BlastHost", V(0.1, 0.1, 0.1), CFrame.identity, Color3.new(), nil, 1)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	host = { part = holder, attachment = attachment }
	host.sparks = emitter(attachment, "Sparks", {
		Texture = look.sparksTexture or TEXTURE.sparks,
		LightEmission = 1,
		Color = look.sparks or CS(FIRE_HOT, FIRE_DEEP),
		Lifetime = NumberRange.new(0.35, 0.9),
		Speed = NumberRange.new(28, 70),
		SpreadAngle = Vector2.new(75, 75),
		Acceleration = V(0, -60, 0),
		Drag = 1.5,
		Size = NS({ NSK(0, 0.22), NSK(1, 0.05) }),
		Transparency = NS({ NSK(0, 0), NSK(0.7, 0.2), NSK(1, 1) }),
	})
	host.embers = emitter(attachment, "Embers", {
		Texture = TEXTURE.glow,
		LightEmission = 1,
		Color = look.embers or CS(FIRE, FIRE_DEEP),
		Lifetime = NumberRange.new(0.8, 1.6),
		Speed = NumberRange.new(8, 24),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = V(0, -22, 0),
		Drag = 2.5,
		RotSpeed = NumberRange.new(-90, 90),
		Size = NS({ NSK(0, 0.5), NSK(1, 0.1) }),
		Transparency = NS({ NSK(0, 0.1), NSK(1, 1) }),
	})
	host.smoke = emitter(attachment, "Smoke", {
		Texture = TEXTURE.smoke,
		LightInfluence = 1,
		Color = look.smoke or CS(SMOKE_DARK, Color3.fromRGB(120, 116, 112)),
		Lifetime = NumberRange.new(1.4, 2.8),
		Speed = NumberRange.new(6, 18),
		SpreadAngle = Vector2.new(70, 70),
		Acceleration = V(0, 5, 0),
		Drag = 2,
		RotSpeed = NumberRange.new(-40, 40),
		Rotation = NumberRange.new(0, 360),
		Size = NS({ NSK(0, 2.5), NSK(0.4, 6), NSK(1, 10) }),
		Transparency = NS({ NSK(0, 0.35), NSK(0.6, 0.6), NSK(1, 1) }),
	})
	-- Tongues of flame licking out of the fireball cluster: big, short-lived, additive.
	host.flames = emitter(attachment, "Flames", {
		Texture = TEXTURE.fire,
		LightEmission = 1,
		Color = look.flames or CS(FIRE_HOT, FIRE_DEEP),
		Lifetime = NumberRange.new(0.25, 0.5),
		Speed = NumberRange.new(6, 16),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = V(0, 12, 0),
		Drag = 3,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		Size = NS({ NSK(0, 3), NSK(0.5, 5), NSK(1, 2) }),
		Transparency = NS({ NSK(0, 0.15), NSK(0.6, 0.4), NSK(1, 1) }),
	})
	host.dust = emitter(attachment, "Dust", {
		Texture = TEXTURE.smoke,
		LightInfluence = 1,
		Color = look.dust and CS(look.dust) or CS(Color3.fromRGB(150, 140, 126)),
		Lifetime = NumberRange.new(0.8, 1.6),
		Speed = NumberRange.new(20, 40),
		SpreadAngle = Vector2.new(10, 10),
		Drag = 4,
		Rotation = NumberRange.new(0, 360),
		Size = NS({ NSK(0, 1.5), NSK(1, 5) }),
		Transparency = NS({ NSK(0, 0.5), NSK(1, 1) }),
	})
	hosts[key] = host
	return host
end

--------------------------------------------------------------------------------
-- Explosions
--------------------------------------------------------------------------------

-- Where the blast meets a surface, if it does: the point and normal its ground-bound marks (shock
-- ring, dust, scorch) are drawn on. The server's `normal` says what the round struck, and that can
-- be a body, a lamp post or a branch at chest height; a scorch drawn there stood in the air as a
-- black disc ("the explosions leave a giant black circle floating when they blow up off the
-- ground", Oliver, 2026-09-18). So the struck thing counts only if it is terrain or a solid part
-- wide enough to carry the mark; failing that, the ground straight below counts if it is within
-- reach of the blast; failing that it is an airburst and nothing is drawn on anything.
local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Exclude
surfaceParams.IgnoreWater = true

-- true restores the old rule (any normal is a surface), so the gallery can show before and after.
ExplosiveFx.TrustNormal = false

local function carriesMark(instance, span)
	if instance:IsA("Terrain") then
		return true
	end
	if not instance:IsA("BasePart") or not instance.CanCollide then
		return false
	end
	local s = instance.Size
	local largest = math.max(s.X, s.Y, s.Z)
	local middle = s.X + s.Y + s.Z - largest - math.min(s.X, s.Y, s.Z)
	return largest >= span and middle >= span
end

local function castSurface(origin, direction, span)
	local filter = { effects() }
	for _ = 1, 4 do
		surfaceParams.FilterDescendantsInstances = filter
		local hit = workspace:Raycast(origin, direction, surfaceParams)
		if not hit then
			return nil
		end
		if carriesMark(hit.Instance, span) then
			return hit
		end
		table.insert(filter, hit.Instance)
	end
	return nil
end

local scorches = {}
local rng = Random.new()

-- A mark that lies on a surface stays with that surface: re-placed from the part's frame every
-- frame (a scorch on a truck drives off with it, on a lift it goes up with it) and gone the frame
-- the part is destroyed (a floor the blast itself broke can't leave its mark hanging in the air,
-- which would be Oliver's black circle from a different cause: "what about when it's on the second
-- story of a building and destroys the floor under it", 2026-09-18). Terrain is the world, static
-- and never destroyed, so marks on it need no rider. MarksFollow = false plants the old behaviour
-- for the probe's self-test.
ExplosiveFx.MarksFollow = true

local function rider(surface, instance)
	if not ExplosiveFx.MarksFollow or not surface or surface:IsA("Terrain") then
		return nil
	end
	return { part = surface, offset = surface.CFrame:ToObjectSpace(instance.CFrame) }
end

-- Keeps `instance` on its rider's part. False once the part is gone.
local function ride(r, instance)
	if not r then
		return true
	end
	local part = r.part
	if not part.Parent then
		return false
	end
	instance.CFrame = part.CFrame * r.offset
	return true
end

-- A scorch is a cluster of patches, a middle one and a ring round it, each cast onto the surface
-- itself and lying on whatever it found. One flat disc can only be right on a flat, lasting
-- surface: half of it hung in the air off the edge of a floor, and on the ground it was a lid
-- over the crater the same blast dug a moment later (#29, #70). A patch that finds nothing under it
-- isn't drawn. The crater comes from the server after the effect has started, so patches on the
-- ground are laid again a few times over the first seconds and follow the ground down into the
-- hole. Patches on a part ride it and go with it when it breaks.
local SCORCH_WIDEST = 7 -- studs across at most: the old 14-stud rocket mark read as a black pool
local SCORCH_RING = 8
local SCORCH_SHADE = 0.12
local SCORCH_RELAY = { 0.3, 1, 2.5, 5 }
-- How far below the mark's plane a patch may land. On the ground, the floor of the crater this blast
-- digs: one blast's worth, since the plane is the ground as it was (DestructibleService: CRATER_MAX x
-- DEEPEN = 5.6 at the apex, up to half a voxel row more where the rings leave it, Basalt's 0.8 of
-- roughness, and more on a hillside), 11 at most on ground up to 45 degrees (tools/scorch_sink_check.py).
-- No deeper: anything further down is not this crater (a gorge floor, a road in a notch). On a part,
-- a bevel or a step (a kerb is 0.5), never the storey below.
local SCORCH_SINK, SCORCH_LIP = 11.5, 0.6
ExplosiveFx.ScorchWidest = SCORCH_WIDEST

local function layPatch(patch, centre, normal, flat)
	local mark = patch.mark
	if flat then
		mark.CFrame = surfaceFrame(centre + patch.offset + normal * 0.04, normal) * ALONG_NORMAL
		mark.Transparency = SCORCH_SHADE
		patch.laid = true
		return
	end
	local reach = patch.ground and SCORCH_SINK or SCORCH_LIP
	local hit = castSurface(centre + patch.offset + normal, -normal * (1 + reach), patch.size * 0.5)
	if not hit then
		mark.Transparency = 1
		patch.laid, patch.rides = false, nil
		return
	end
	mark.CFrame = surfaceFrame(hit.Position + hit.Normal * 0.04, hit.Normal) * ALONG_NORMAL
	mark.Transparency = SCORCH_SHADE
	patch.laid = true
	patch.rides = rider(hit.Instance, mark)
end

local function scorch(position, normal, diameter, surface)
	diameter = math.min(diameter, SCORCH_WIDEST)
	local frame = surfaceFrame(position, normal)
	-- No surface part: the gallery's TrustNormal "before", drawn flat where it was told.
	local flat = surface == nil
	local ground = surface ~= nil and surface:IsA("Terrain")
	local patches = {}
	local function patchAt(name, offset, size)
		local mark = part(name, V(0.06, size, size), frame * ALONG_NORMAL, Color3.fromRGB(26, 24, 22), Enum.Material.Slate, SCORCH_SHADE, Enum.PartType.Cylinder)
		local patch = { mark = mark, offset = offset, size = size, ground = ground }
		layPatch(patch, position, normal, flat)
		table.insert(patches, patch)
	end
	patchAt("Scorch", Vector3.zero, diameter * 0.42)
	local turn = rng:NextNumber(0, math.pi * 2)
	for index = 1, SCORCH_RING do
		local angle = turn + index / SCORCH_RING * math.pi * 2
		local out = diameter * 0.3 * rng:NextNumber(0.85, 1.1)
		local offset = frame.RightVector * (math.cos(angle) * out) + frame.UpVector * (math.sin(angle) * out)
		patchAt("ScorchEdge", offset, diameter * 0.32 * rng:NextNumber(0.85, 1.15))
	end

	local parts = {}
	for _, patch in ipairs(patches) do
		table.insert(parts, patch.mark)
	end
	local mark = { parts = parts }
	table.insert(scorches, mark)
	if #scorches > MAX_SCORCH then
		destroyParts(table.remove(scorches, 1))
	end
	local relays = 1
	add({
		life = 28,
		parts = parts,
		update = function(entry, age)
			local relay = ExplosiveFx.MarksFollow and not flat and SCORCH_RELAY[relays] ~= nil and age >= SCORCH_RELAY[relays]
			if relay then
				relays += 1
			end
			local left = 0
			for _, patch in ipairs(patches) do
				local piece = patch.mark
				if piece.Parent then
					if patch.rides and not ride(patch.rides, piece) then
						-- Its part broke. On a floor it goes with it; on the ground (rubble it
						-- lay on) it waits for the next lay.
						patch.rides, patch.laid = nil, false
						if patch.ground then
							piece.Transparency = 1
						else
							piece:Destroy()
						end
					end
					if relay and patch.ground and piece.Parent then
						layPatch(patch, position, normal, false)
					end
				end
				if piece.Parent then
					left += 1
					if patch.laid and age > 25 then
						piece.Transparency = SCORCH_SHADE + (age - 25) / 3 * (1 - SCORCH_SHADE)
					end
				end
			end
			if left == 0 then
				entry.life = 0
			end
		end,
		destroy = destroyParts,
	})
end

local function throwDebris(position, normal, count, speed, size, color, material)
	for _ = 1, count do
		if #debris >= MAX_DEBRIS then
			local oldest = table.remove(debris, 1)
			oldest.part:Destroy()
		end
		local chunk = part("Debris", V(size * rng:NextNumber(0.6, 1.4), size * rng:NextNumber(0.4, 1), size * rng:NextNumber(0.6, 1.4)),
			CFrame.new(position), color, material)
		local direction = (V(rng:NextNumber(-1, 1), rng:NextNumber(0.2, 1), rng:NextNumber(-1, 1)).Unit + normal * 0.8).Unit
		table.insert(debris, {
			part = chunk,
			position = position + normal * 0.3,
			velocity = direction * speed * rng:NextNumber(0.5, 1.1),
			spin = V(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12)),
			rotation = CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6)),
			radius = size * 0.5,
			age = 0,
			life = rng:NextNumber(2.5, 4),
		})
	end
end

-- Returns the surface point, its normal and the part it belongs to (nil for none).
local function findSurface(position, normal, r)
	if ExplosiveFx.TrustNormal then
		if normal then
			return position, normal, nil
		end
		return nil, nil, nil
	end
	local span = r * 0.4
	if normal then
		local hit = castSurface(position + normal * 0.5, -normal * 2.5, span)
		if hit then
			return hit.Position, hit.Normal, hit.Instance
		end
	end
	local hit = castSurface(position + UP * 0.5, -UP * (r * 0.6 + 0.5), span)
	if hit then
		return hit.Position, hit.Normal, hit.Instance
	end
	return nil, nil, nil
end

-- What SillyExplosionFx builds with: the same parts, emitters and loop as every other effect here,
-- so Advance steps it, Paused freezes it for the gallery and Clear takes it down.
-- The fire's colour ramp (white-hot, orange, deep red, smoke) for every fireball, and the empty look
-- the realistic blast draws with (every field falls back to the fire's own).
local FIRE_RAMPS = { { FIRE_HOT, FIRE, FIRE_DEEP, FIRE_DONE } }
local NO_LOOK = {}
-- Blasts still in their first 1.3 s, and how many before the next is drawn light.
local LIVE_BLASTS = 3
local liveBlasts = 0
local sillyApi = { part = part, emitter = emitter, add = add, destroyParts = destroyParts, surfaceFrame = surfaceFrame, texture = TEXTURE }

-- The blast: a white flash and its light, a cluster of fireballs that swell, rise and darken to
-- smoke, a shock ring on the surface it hit, dust rolling out along it, sparks, embers, chunks of
-- ground, a column of smoke rising after, and a scorch left behind. The fireballs, flash, shell and
-- particles are at `position`; the ring, dust and scorch lie on the surface findSurface chose.
function ExplosiveFx.Explosion(position, normal, kind, radius, weaponId)
	local spec = KIND[kind] or KIND.rocket
	local r = math.max(3, (radius or 12) * spec.scale)
	local ground, groundNormal, surfacePart = findSurface(position, normal, r)
	local onSurface = ground ~= nil
	local up = groundNormal or normal or UP
	ground = ground or position
	local parts = {}
	-- A silly gun's blast is this same blast, layer for layer, in its theme's palette (`look`), with
	-- the theme's own pieces thrown on top (SillyExplosionFx.Extras). `share` thins the particles at
	-- a distance or in a crowd. The realistic blast has no look and every default below is its own.
	local theme = SillyExplosionFx.ThemeFor(weaponId)
	local look = theme and SillyExplosionFx.LookFor(theme, position) or NO_LOOK
	local share = look.share or 1
	-- The crowd budget (lag, #131): past LIVE_BLASTS blasts still going (a barrel chain, a rocket
	-- volley), the next one is drawn light: half the particles, no chunks, no smoke column.
	local crowded = liveBlasts >= LIVE_BLASTS
	if crowded then
		share *= 0.5
	end
	liveBlasts += 1
	local ramps = look.ramps or FIRE_RAMPS
	local coreNeon = look.coreNeon ~= false

	local flash = part("Flash", V(1, 1, 1), CFrame.new(position + up * 0.5), look.flash or FIRE_HOT, Enum.Material.Neon, 0, Enum.PartType.Ball)
	local light = Instance.new("PointLight")
	light.Color = look.light or FIRE
	light.Range = spec.light
	light.Brightness = 8
	light.Shadows = false
	light.Parent = flash
	table.insert(parts, flash)

	-- Fireballs: a few glowing (neon) cores inside a shell of lit, matte balls. Each runs the same
	-- colour ramp (white-hot, orange, deep red, smoke) but starts at its own point on it, so at any
	-- moment the cluster is a mix of bright and dark rather than one flat yellow dome. The outer ones
	-- are partly see-through, which lets the cores glow through them. A theme's ramps take the place
	-- of the fire's (foam, gold, party colours), one per ball in turn.
	local balls = {}
	for index = 1, spec.balls do
		local core = index <= math.max(2, math.floor(spec.balls * 0.35))
		local ramp = ramps[(index - 1) % #ramps + 1]
		local offset = V(rng:NextNumber(-1, 1), rng:NextNumber(-0.5, 1), rng:NextNumber(-1, 1)) * (r * (core and 0.12 or 0.26)) + up * (r * 0.12)
		local ball = part("Fireball", V(0.5, 0.5, 0.5), CFrame.new(position + offset), ramp[2], (core and coreNeon) and Enum.Material.Neon or Enum.Material.SmoothPlastic, core and 0 or 0.22, Enum.PartType.Ball)
		table.insert(parts, ball)
		table.insert(balls, {
			part = ball,
			core = core,
			ramp = ramp,
			offset = offset,
			final = r * (look.ballScale or 1) * (core and rng:NextNumber(0.45, 0.65) or rng:NextNumber(0.5, 0.85)),
			delay = core and 0 or rng:NextNumber(0.02, 0.1),
			phase = core and rng:NextNumber(0, 0.06) or rng:NextNumber(0.08, 0.3),
			rise = r * rng:NextNumber(0.15, 0.4),
			drift = V(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)) * (r * 0.1),
		})
	end

	-- The shockwave: a translucent shell racing out to three radii, and on a surface a hollow ring of
	-- pressure sweeping across it ahead of the dust. Plain plastic, not Glass: Roblox draws nothing
	-- see-through behind a transparent Glass part (the fireballs, every particle, the smoke), so a
	-- glass shell hid the whole first half-second of the explosion behind a blank dome.
	local wave = part("Shockwave", V(1, 1, 1), CFrame.new(position + up * 0.3), look.wave or Color3.fromRGB(255, 244, 228), Enum.Material.SmoothPlastic, 0.62, Enum.PartType.Ball)
	table.insert(parts, wave)
	local ring, dust
	if onSurface then
		ring = Instance.new("CylinderHandleAdornment")
		ring.Name = "ShockRing"
		ring.Adornee = workspace.Terrain
		ring.CFrame = surfaceFrame(ground + up * 0.2, up)
		ring.Height = 0.35
		ring.Radius = 0.5
		ring.InnerRadius = 0
		ring.Color3 = look.ring or FIRE_HOT
		ring.Transparency = 0.15
		ring.AlwaysOnTop = false
		ring.ZIndex = 1
		ring.Parent = workspace.Terrain
		dust = part("DustRing", V(0.9, 1, 1), surfaceFrame(ground + up * 0.5, up) * ALONG_NORMAL, look.dust or Color3.fromRGB(140, 132, 120), Enum.Material.SmoothPlastic, 0.45, Enum.PartType.Cylinder)
		table.insert(parts, ring)
		table.insert(parts, dust)
	end
	local ringRider = ring and rider(surfacePart, ring) or nil
	local dustRider = dust and rider(surfacePart, dust) or nil

	-- Particles from the shared host (a theme has its own), pointed along the normal.
	local host = hostFor(kind, theme and look or nil)
	local function emit(particles, count)
		count = math.floor(count * share + 0.5)
		if count > 0 then
			particles:Emit(count)
		end
	end
	host.part.CFrame = surfaceFrame(position + up * 0.3, up) * CFrame.Angles(-math.pi / 2, 0, 0)
	emit(host.sparks, spec.sparks * (look.sparkShare or 1))
	emit(host.embers, spec.embers * (look.emberShare or 1))
	emit(host.smoke, spec.smoke * (look.smokeShare or 1))
	host.flames.Size = NS({ NSK(0, r * 0.25), NSK(0.5, r * 0.4), NSK(1, r * 0.18) })
	if look.flames ~= false then
		emit(host.flames, math.floor(spec.balls * 1.5))
	end
	if onSurface then
		emit(host.dust, math.floor(spec.smoke * 0.6))
	end

	-- The column: its own emitter, since it stays lit for a while. A theme's is its own (a steam
	-- plume, golden smoke, coloured smoke); a hit-only round's has none.
	local columnTime = crowded and 0 or look.columnTime or spec.column
	if columnTime > 0 then
		local column = part("SmokeColumn", V(0.1, 0.1, 0.1), CFrame.new(position + up * (r * 0.3)), Color3.new(), nil, 1)
		local attachment = Instance.new("Attachment")
		attachment.Parent = column
		local plume = emitter(attachment, "Plume", {
			Texture = TEXTURE.smoke,
			LightInfluence = 1,
			Color = look.column or CS(SMOKE_DARK, Color3.fromRGB(110, 106, 102)),
			Lifetime = NumberRange.new(2.5, 4),
			Speed = NumberRange.new(6, 12),
			SpreadAngle = Vector2.new(25, 25),
			Acceleration = V(0, 4, 0),
			Drag = 1.2,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-20, 20),
			Rate = 22 * share,
			Size = NS({ NSK(0, r * 0.25), NSK(1, r * 0.7) }),
			Transparency = look.columnFade or NS({ NSK(0, 0.4), NSK(0.7, 0.7), NSK(1, 1) }),
			Enabled = true,
		})
		table.insert(parts, column)
		add({
			life = columnTime + 5,
			parts = { column },
			update = function(_, age)
				if age >= columnTime and plume.Enabled then
					plume.Enabled = false
				end
			end,
			destroy = destroyParts,
		})
	end

	-- A theme throws its own pieces in place of the rock chunks, and leaves no scorch.
	if spec.debris > 0 and not theme and not crowded then
		throwDebris(position, up, spec.debris, r * 3, math.clamp(r * 0.06, 0.25, 0.7), Color3.fromRGB(70, 62, 56), Enum.Material.Slate)
	end
	if onSurface and spec.scorch > 0 and not theme then
		scorch(ground, up, r * spec.scorch, surfacePart)
	end
	if theme then
		SillyExplosionFx.Extras(sillyApi, theme, look, position, up, radius or 12, onSurface and ground or nil)
	end

	add({
		life = 1.3,
		parts = parts,
		update = function(_, age)
			-- Flash: out to the radius in a blink, gone in a sixth of a second.
			local ft = age / 0.16
			if ft < 1 then
				local size = 1 + (r * 1.2 - 1) * easeOut(ft * 1.4)
				flash.Size = V(size, size, size)
				flash.Transparency = ft ^ 0.7
				light.Brightness = 8 * (1 - ft)
			elseif flash.Parent then
				flash:Destroy()
			end
			-- Fireballs: swell fast, rise, run down their ramp (white-orange, red, smoke), fade.
			-- `phase` puts each ball at its own point on that ramp.
			for _, ball in ipairs(balls) do
				local a = clamp01((age - ball.delay) / 0.75)
				local size = ball.final * easeOut(math.min(a * 2.2, 1))
				ball.part.Size = V(size, size, size)
				ball.part.CFrame = CFrame.new(position + ball.offset + up * (ball.rise * a) + ball.drift * a)
				local c = clamp01(a + ball.phase)
				local ramp = ball.ramp
				if c < 0.18 then
					ball.part.Color = ramp[1]:Lerp(ramp[2], c / 0.18)
				elseif c < 0.5 then
					ball.part.Color = ramp[2]:Lerp(ramp[3], (c - 0.18) / 0.32)
				else
					ball.part.Color = ramp[3]:Lerp(ramp[4], (c - 0.5) / 0.5)
					if ball.core and ball.part.Material ~= Enum.Material.SmoothPlastic and c > 0.62 then
						ball.part.Material = Enum.Material.SmoothPlastic
					end
				end
				local base = ball.core and 0 or 0.22
				ball.part.Transparency = a < 0.3 and base or base + (1 - base) * smooth((a - 0.3) / 0.7)
			end
			-- The shockwave shell: out to three radii in four tenths of a second, thinning as it goes.
			local w = age / 0.42
			if w < 1 then
				local size = 1 + (r * 3.2 - 1) * easeOut(w)
				wave.Size = V(size, size, size)
				wave.Transparency = 0.62 + 0.38 * w * w
			elseif wave.Parent then
				wave:Destroy()
			end
			if ring then
				-- Both stay on their surface; if it goes (the blast broke the floor) they go with it.
				if not (ride(ringRider, ring) and ride(dustRider, dust)) then
					if ring.Parent then
						ring:Destroy()
					end
					if dust.Parent then
						dust:Destroy()
					end
				else
					-- The ring: a band that races out across the ground, its leading edge at the wave.
					local t = age / 0.4
					if t < 1 then
						local radius = 0.5 + (r * 3 - 0.5) * easeOut(t)
						local band = math.max(0.3, r * 0.22 * (1 - t))
						ring.Radius = radius
						ring.InnerRadius = math.max(0, radius - band)
						ring.Transparency = 0.15 + 0.85 * t * t
					elseif ring.Parent then
						ring:Destroy()
					end
					local d = age / 1.1
					if d < 1 then
						local size = 1 + (r * 2.2 - 1) * easeOut(d)
						dust.Size = V(0.9 + d * 1.5, size, size)
						dust.Transparency = 0.45 + 0.55 * d * d
					elseif dust.Parent then
						dust:Destroy()
					end
				end
			end
		end,
		destroy = function(entry)
			destroyParts(entry)
			liveBlasts = math.max(0, liveBlasts - 1)
		end,
	})
end

-- A round with no blast landing: a small flash, sparks and a puff.
function ExplosiveFx.Impact(position, normal, weaponId)
	ExplosiveFx.Explosion(position, normal, "impact", 4, weaponId)
end

function ExplosiveFx.ThemeCue(weaponId)
	return SillyExplosionFx.Cue(weaponId)
end

--------------------------------------------------------------------------------
-- Smoke clouds
--------------------------------------------------------------------------------

local CLOUD_LUMPS = 12
local CLOUD_SHELL = 10

-- A cloud `elapsed` seconds into its life (the server's timeline; the hiss has already happened
-- when elapsed is 0). Returns the handle, with .position, .radius and .density kept up to date.
function ExplosiveFx.Cloud(position, spec, elapsed)
	local seed = Random.new()
	local cloud = { position = position, spec = spec, radius = 0, density = 0, elapsed = elapsed or 0 }
	local parts = {}
	local lumps = {}
	-- Matte and warm-grey, lit from above: the lumps near the top are pale, the underside is dark, the
	-- way a cumulus shades. Fabric has no specular highlight, so nothing reads as a glossy ball.
	local base = Color3.fromRGB(158, 155, 150)

	local function lump(kind, direction, distance, diameter, transparency, tint)
		local shade = 0.5 + 0.5 * math.clamp(direction.Y, -1, 1)
		local color = base:Lerp(tint, seed:NextNumber(0, 0.35)):Lerp(Color3.fromRGB(226, 224, 220), shade * 0.55):Lerp(Color3.fromRGB(96, 94, 92), (1 - shade) * 0.45)
		local ball = part(kind, V(0.2, 0.2, 0.2), CFrame.new(position), color, Enum.Material.Fabric, transparency, Enum.PartType.Ball)
		table.insert(parts, ball)
		table.insert(lumps, {
			part = ball,
			direction = direction,
			distance = distance,
			diameter = diameter,
			baseTransparency = transparency,
			phase = seed:NextNumber(0, 6.28),
			bob = seed:NextNumber(0.2, 0.5),
			spin = seed:NextNumber(-0.06, 0.06),
		})
	end

	-- The core: one big opaque ball, the occluder everything else dresses.
	lump("SmokeCore", V(0, 0.2, 0), 0, 1.5, 0, base)
	-- Opaque lumps bulging out of it, spread evenly over the sphere (golden spiral), squashed
	-- toward the top so the cloud is wider than it is tall.
	local golden = math.pi * (3 - math.sqrt(5))
	for index = 0, CLOUD_LUMPS - 1 do
		local y = 1 - (index + 0.5) / CLOUD_LUMPS * 1.6
		local ring = math.sqrt(math.max(0, 1 - y * y))
		local angle = index * golden + seed:NextNumber(-0.2, 0.2)
		local direction = V(math.cos(angle) * ring, y * 0.75, math.sin(angle) * ring).Unit
		lump("SmokeLump", direction, seed:NextNumber(0.48, 0.6), seed:NextNumber(0.7, 0.95), 0, Color3.fromRGB(150, 148, 146))
	end
	-- The shell: smaller, nearly opaque knobs a little further out, so the outline is cauliflower
	-- rather than three big balls. (A see-through shell read as soap bubbles.)
	for index = 0, CLOUD_SHELL - 1 do
		local y = 1 - (index + 0.5) / CLOUD_SHELL * 1.7
		local ring = math.sqrt(math.max(0, 1 - y * y))
		local angle = index * golden * 1.3 + 1.1 + seed:NextNumber(-0.3, 0.3)
		local direction = V(math.cos(angle) * ring, y * 0.7, math.sin(angle) * ring).Unit
		lump("SmokeShell", direction, seed:NextNumber(0.62, 0.78), seed:NextNumber(0.4, 0.62), seed:NextNumber(0.08, 0.2), Color3.fromRGB(190, 188, 184))
	end

	-- Wisps drifting off the surface.
	local wispHost = part("SmokeWisps", V(0.1, 0.1, 0.1), CFrame.new(position), Color3.new(), nil, 1)
	local wispAttachment = Instance.new("Attachment")
	wispAttachment.Parent = wispHost
	local wisps = emitter(wispAttachment, "Wisps", {
		Texture = TEXTURE.smoke,
		LightInfluence = 1,
		Color = CS(Color3.fromRGB(176, 174, 170)),
		Lifetime = NumberRange.new(2.5, 4.5),
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-15, 15),
		Rate = 22,
		Size = NS({ NSK(0, spec.smokeRadius * 0.35), NSK(1, spec.smokeRadius * 0.8) }),
		Transparency = NS({ NSK(0, 0.45), NSK(0.7, 0.7), NSK(1, 1) }),
		Enabled = true,
	})
	table.insert(parts, wispHost)

	local timeline = { position = position, startedAt = 0, spec = spec }
	table.insert(ExplosiveFx.Clouds, cloud)

	add({
		life = math.huge,
		parts = parts,
		alive = function()
			return cloud.elapsed < spec.grow + spec.hold + spec.fade
		end,
		update = function(entry, age)
			cloud.elapsed = (elapsed or 0) + age
			local now = cloud.elapsed
			local radius = Ballistics.SmokeRadius(timeline, now)
			local density = Ballistics.SmokeDensity(timeline, now)
			cloud.radius = radius
			cloud.density = density
			-- The visible ball grows in from nothing over the first moments of the pour.
			local grown = smooth(now / (spec.grow * 0.5)) * radius
			for _, entry in ipairs(lumps) do
				local direction = entry.direction
				if entry.distance > 0 then
					local turn = now * entry.spin + entry.phase
					direction = V(
						direction.X * math.cos(turn) - direction.Z * math.sin(turn),
						direction.Y + math.sin(now * 0.6 + entry.phase) * 0.06,
						direction.X * math.sin(turn) + direction.Z * math.cos(turn)
					)
				end
				local breathe = 1 + math.sin(now * 0.7 + entry.phase) * 0.035
				local size = grown * entry.diameter * breathe
				entry.part.Size = V(size, size, size)
				entry.part.CFrame = CFrame.new(position + direction * (grown * entry.distance) + UP * (math.sin(now * 0.5 + entry.phase) * entry.bob))
				-- Opaque while dense; thinning out with the cloud.
				entry.part.Transparency = entry.baseTransparency + (1 - entry.baseTransparency) * clamp01(1 - density * 1.25)
			end
			wispHost.CFrame = CFrame.new(position + UP * (grown * 0.2))
			wisps.Rate = 22 * density
			wisps.Enabled = density > 0.2
		end,
		destroy = function(entry)
			destroyParts(entry)
			for index, other in ipairs(ExplosiveFx.Clouds) do
				if other == cloud then
					table.remove(ExplosiveFx.Clouds, index)
					break
				end
			end
		end,
	})
	return cloud
end

--------------------------------------------------------------------------------
-- Hit splats
--------------------------------------------------------------------------------

local splats = {}
local splatHost = nil

-- What flies off a hit: fine droplets streaking out along their flight and pulled down hard, a few
-- heavy globs that arc and fall, and a short dark puff of mist at the wound. A shield hit throws
-- bright chips of light instead. One shared host, moved to each hit and told to emit.
local function splatParticles(position, normal, color, count, shield)
	if not splatHost or not splatHost.part.Parent then
		local holder = part("BRR_SplatHost", V(0.1, 0.1, 0.1), CFrame.identity, Color3.new(), nil, 1)
		local attachment = Instance.new("Attachment")
		attachment.Parent = holder
		splatHost = {
			part = holder,
			drops = emitter(attachment, "Drops", {
				Texture = TEXTURE.glow,
				LightEmission = 0,
				LightInfluence = 1,
				Color = CS(SPLAT_DEFAULT),
				Lifetime = NumberRange.new(0.3, 0.6),
				Speed = NumberRange.new(6, 14),
				SpreadAngle = Vector2.new(50, 50),
				Acceleration = V(0, -60, 0),
				Drag = 1,
				Orientation = Enum.ParticleOrientation.VelocityParallel,
				Size = NS({ NSK(0, 0.14), NSK(1, 0.04) }),
				Transparency = NS({ NSK(0, 0.05), NSK(0.7, 0.2), NSK(1, 1) }),
			}),
			globs = emitter(attachment, "Globs", {
				Texture = TEXTURE.glow,
				LightEmission = 0,
				LightInfluence = 1,
				Color = CS(SPLAT_DEFAULT),
				Lifetime = NumberRange.new(0.45, 0.8),
				Speed = NumberRange.new(3, 7),
				SpreadAngle = Vector2.new(40, 40),
				Acceleration = V(0, -50, 0),
				Drag = 0.5,
				Size = NS({ NSK(0, 0.26), NSK(1, 0.1) }),
				Transparency = NS({ NSK(0, 0), NSK(0.8, 0.1), NSK(1, 1) }),
			}),
			mist = emitter(attachment, "Mist", {
				Texture = TEXTURE.smoke,
				LightEmission = 0,
				LightInfluence = 1,
				Color = CS(SPLAT_DEFAULT),
				Lifetime = NumberRange.new(0.2, 0.4),
				Speed = NumberRange.new(1.5, 4),
				SpreadAngle = Vector2.new(70, 70),
				Acceleration = V(0, -6, 0),
				Drag = 3,
				Rotation = NumberRange.new(0, 360),
				RotSpeed = NumberRange.new(-60, 60),
				Size = NS({ NSK(0, 0.5), NSK(1, 1.3) }),
				Transparency = NS({ NSK(0, 0.45), NSK(1, 1) }),
			}),
			sparks = emitter(attachment, "Sparks", {
				Texture = TEXTURE.sparks,
				LightEmission = 1,
				LightInfluence = 0,
				Color = CS(SHIELD),
				Lifetime = NumberRange.new(0.2, 0.4),
				Speed = NumberRange.new(8, 18),
				SpreadAngle = Vector2.new(45, 45),
				Acceleration = V(0, -30, 0),
				Drag = 2,
				Orientation = Enum.ParticleOrientation.VelocityParallel,
				Size = NS({ NSK(0, 0.22), NSK(1, 0.04) }),
				Transparency = NS({ NSK(0, 0), NSK(1, 1) }),
			}),
		}
	end
	splatHost.part.CFrame = surfaceFrame(position + normal * 0.05, normal) * CFrame.Angles(-math.pi / 2, 0, 0)
	if shield then
		splatHost.sparks:Emit(count * 3)
		return
	end
	local dark = color:Lerp(Color3.new(0, 0, 0), 0.35)
	splatHost.drops.Color = CS(color)
	splatHost.globs.Color = CS(dark)
	splatHost.mist.Color = CS(dark)
	splatHost.drops:Emit(count)
	splatHost.globs:Emit(math.max(2, math.floor(count * 0.4)))
	splatHost.mist:Emit(math.max(3, math.floor(count * 0.6)))
end

-- Blood where a bullet landed on `limb`, at `position` on its surface: a dark red star (a central
-- disc, droplets round it, a drip or two running down) that stays put on the limb as it moves, holds
-- a moment and fades. A headshot's is bigger. A hit the shield soaked is blue chips flying off the
-- body instead.
function ExplosiveFx.Splat(limb, position, normal, options)
	options = options or {}
	if #splats >= MAX_SPLATS then
		local oldest = table.remove(splats, 1)
		oldest.life = 0
	end
	local scale = options.headshot and 1.55 or 1
	local frame = surfaceFrame(position + normal * 0.02, normal)
	local parts = {}
	local seed = Random.new()
	-- The blood's colour: the rank of the gun that dealt the hit (options.color), else plain red.
	if not options.color and not options.shield and not warnedColourless then
		warnedColourless = true
		warn("[ExplosiveFx] a splat was drawn with no rank colour: every caller must pass options.color (the firing gun's Rarity.Color). Drawn in Common grey.")
	end
	local blood = options.color or SPLAT_DEFAULT
	local dark = (options.color or SPLAT_DEFAULT):Lerp(Color3.new(0, 0, 0), 0.35)

	if options.shield then
		-- Chips: thin light-blue discs bursting outward along the surface, fading fast.
		local chips = {}
		for index = 1, 4 do
			local angle = index / 4 * math.pi * 2 + seed:NextNumber(-0.4, 0.4)
			local chip = part("ShieldChip", V(0.04, 0.16, 0.16), frame * ALONG_NORMAL, SHIELD, Enum.Material.Neon, 0.1, Enum.PartType.Cylinder)
			table.insert(parts, chip)
			table.insert(chips, { part = chip, direction = V(math.cos(angle), math.sin(angle), 0), speed = seed:NextNumber(3, 5) })
		end
		splatParticles(position, normal, SHIELD, 5, true)
		-- Taken once, so the chips ride the limb as it moves (worked out each frame it was just `frame`).
		local offset = limb.CFrame:ToObjectSpace(frame)
		local entry = add({
			life = 0.4,
			parts = parts,
			update = function(_, age)
				if not limb.Parent then
					return
				end
				local live = limb.CFrame * offset
				for _, chip in ipairs(chips) do
					chip.part.CFrame = live * CFrame.new(chip.direction * (chip.speed * age)) * ALONG_NORMAL
					chip.part.Transparency = 0.1 + 0.9 * (age / 0.4) ^ 1.5
				end
			end,
			alive = function()
				return limb.Parent ~= nil
			end,
			destroy = destroyParts,
		})
		table.insert(splats, entry)
		return entry
	end

	-- The mark: a soft dark halo, a centre made of three overlapping discs (an irregular blot, not a
	-- coin), two splash tongues thrown out from it with a bead at each end, a scatter of droplets
	-- thinning out with distance, and a run or two down the surface ending in a bead. Glossy, since
	-- fresh blood shines. (Oliver, 2026-09-18: "improve the blood splat and add particles too".)
	local pieces = {}
	local function keep(piece, base)
		table.insert(parts, piece)
		table.insert(pieces, { part = piece, offset = limb.CFrame:ToObjectSpace(piece.CFrame), size = piece.Size, base = base or 0 })
	end
	local function disc(diameter, offset, color, lift, transparency)
		local piece = part("Splat", V(0.03, diameter, diameter), frame * CFrame.new(offset + V(0, 0, -(lift or 0))) * ALONG_NORMAL, color, Enum.Material.SmoothPlastic, transparency or 0, Enum.PartType.Cylinder)
		piece.Reflectance = transparency and 0 or 0.18
		keep(piece, transparency)
	end
	-- A strip along the surface from the centre out along `direction` (in the surface frame's plane).
	local function streak(direction, length, width, color, lift)
		local across = V(-direction.Y, direction.X, 0)
		local piece = part("Splat", V(width, length, 0.03), frame * CFrame.new(direction * (length / 2) + V(0, 0, -(lift or 0))) * CFrame.fromMatrix(Vector3.zero, across, direction, across:Cross(direction)), color)
		piece.Reflectance = 0.18
		keep(piece)
	end
	local downOnSurface = frame:VectorToObjectSpace(-UP)
	downOnSurface = V(downOnSurface.X, downOnSurface.Y, 0)
	local hasDown = downOnSurface.Magnitude > 0.2
	if hasDown then
		downOnSurface = downOnSurface.Unit
	end

	disc(0.46 * scale, Vector3.zero, dark, -0.002, 0.55)
	disc(0.3 * scale, Vector3.zero, blood)
	disc(0.22 * scale, V(seed:NextNumber(-0.09, 0.09), seed:NextNumber(-0.09, 0.09), 0) * scale, blood, 0.004)
	disc(0.17 * scale, V(seed:NextNumber(-0.12, 0.12), seed:NextNumber(-0.12, 0.12), 0) * scale, dark, 0.008)
	-- Tongues: two, roughly opposite, both leaning the way gravity runs across the surface.
	local first = seed:NextNumber(0, math.pi * 2)
	for index = 1, 2 do
		local angle = first + (index - 1) * math.pi + seed:NextNumber(-0.5, 0.5)
		local direction = V(math.cos(angle), math.sin(angle), 0)
		if hasDown then
			direction = (direction + downOnSurface * 0.35).Unit
		end
		local length = seed:NextNumber(0.22, 0.4) * scale
		streak(direction, length, 0.07 * scale, index == 1 and blood or dark, 0.003 * index)
		disc(0.1 * scale, direction * length, blood, 0.005 * index)
	end
	local drops = options.headshot and 14 or 10
	for index = 1, drops do
		local angle = index / drops * math.pi * 2 + seed:NextNumber(-0.6, 0.6)
		local distance = seed:NextNumber(0.16, 0.5) * scale
		local diameter = (0.035 + 0.08 * (1 - (distance / (0.5 * scale)))) * scale * seed:NextNumber(0.7, 1.2)
		disc(diameter, V(math.cos(angle) * distance, math.sin(angle) * distance, 0), index % 3 == 0 and dark or blood, 0.002 * (index % 3))
	end
	-- Runs: down the way gravity points across this surface, tapering, with a bead at the end.
	if hasDown then
		local across = V(-downOnSurface.Y, downOnSurface.X, 0)
		local runs = options.headshot and 3 or 2
		for index = 1, runs do
			local length = seed:NextNumber(0.24, 0.46) * scale
			local side = (index - (runs + 1) / 2) * 0.11 * scale + seed:NextNumber(-0.03, 0.03)
			local along = downOnSurface * (length / 2 + 0.08 * scale) + across * side
			-- A frame whose Y runs down the surface (X across it, Z the surface normal, right-handed).
			local drip = part("Drip", V(0.045 * scale, length, 0.03), frame * CFrame.new(along) * CFrame.fromMatrix(Vector3.zero, across, downOnSurface, across:Cross(downOnSurface)), dark)
			drip.Reflectance = 0.18
			table.insert(parts, drip)
			table.insert(pieces, { part = drip, offset = limb.CFrame:ToObjectSpace(drip.CFrame), size = drip.Size, drip = true, base = 0 })
			disc(0.07 * scale, along + downOnSurface * (length / 2), dark, 0.003)
		end
	end
	splatParticles(position, normal, blood, options.headshot and 16 or 10)

	-- Four seconds on the body (Oliver, 2026-09-18: 1.2 s was short enough to miss in play); the
	-- MAX_SPLATS cap is what keeps a dummy under sustained fire from piling up.
	local hold, fade = 3.0, 1.0
	local entry = add({
		life = hold + fade,
		parts = parts,
		update = function(_, age)
			if not limb.Parent then
				return
			end
			local fading = clamp01((age - hold) / fade)
			for _, piece in ipairs(pieces) do
				piece.part.CFrame = limb.CFrame * piece.offset
				piece.part.Transparency = piece.base + (1 - piece.base) * fading * fading
				if piece.drip and age < 0.35 then
					-- The drip runs: it grows downward over its first third of a second.
					local grow = 0.4 + 0.6 * (age / 0.35)
					piece.part.Size = V(piece.size.X, piece.size.Y * grow, piece.size.Z)
				end
			end
		end,
		alive = function()
			return limb.Parent ~= nil
		end,
		destroy = destroyParts,
	})
	table.insert(splats, entry)
	return entry
end

--------------------------------------------------------------------------------
-- Rounds in flight
--------------------------------------------------------------------------------

-- A rocket's exhaust: the sustainer flame out of the back, a smoke trail, and its glow.
function ExplosiveFx.Trail(holder, tail)
	local attachment = Instance.new("Attachment")
	attachment.Position = tail or V(0, 0, 0.9)
	attachment.Parent = holder
	emitter(attachment, "Flame", {
		Texture = TEXTURE.fire,
		LightEmission = 1,
		Color = CS(FIRE_HOT, FIRE_DEEP),
		Lifetime = NumberRange.new(0.06, 0.12),
		Speed = NumberRange.new(4, 8),
		SpreadAngle = Vector2.new(12, 12),
		Rate = 90,
		Size = NS({ NSK(0, 0.55), NSK(1, 0.15) }),
		Transparency = NS({ NSK(0, 0), NSK(1, 1) }),
		Enabled = true,
	})
	emitter(attachment, "Trail", {
		Texture = TEXTURE.smoke,
		LightInfluence = 1,
		Color = CS(Color3.fromRGB(215, 215, 215), Color3.fromRGB(170, 170, 170)),
		Lifetime = NumberRange.new(0.9, 1.6),
		Speed = NumberRange.new(0.5, 1.5),
		Drag = 2,
		Rate = 70,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-30, 30),
		Size = NS({ NSK(0, 0.35), NSK(1, 1.8) }),
		Transparency = NS({ NSK(0, 0.45), NSK(1, 1) }),
		Enabled = true,
	})
	local light = Instance.new("PointLight")
	light.Color = FIRE
	light.Range = 14
	light.Brightness = 2.5
	light.Shadows = false
	light.Parent = holder
	return attachment
end

-- A looping cue (its first layer) following `holder`, through the category's volume group.
function ExplosiveFx.Loop(cueName, holder)
	local config = SoundConfig.Get(cueName)
	local layers = config and SoundConfig.LayersOf(config)
	local layer = layers and layers[1]
	if not layer then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.SoundId = layer.id
	sound.Volume = layer.volume
	sound.PlaybackSpeed = layer.pitch
	sound.Looped = true
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = config.maxDistance or 260
	-- Through the category's volume group, made on demand by Sfx so the sliders apply from the first
	-- play; the by-name lookup is only for a context without Sfx (the gallery).
	local category = config.category or "Effects"
	local group = nil
	local sfxModule = script.Parent:FindFirstChild("Sfx")
	if sfxModule then
		local ok, sfx = pcall(require, sfxModule)
		if ok and type(sfx) == "table" and type(sfx.GroupFor) == "function" then
			group = sfx.GroupFor(category)
		end
	end
	sound.SoundGroup = group or SoundService:FindFirstChild("BRR_" .. category)
	for _, entry in ipairs(config.effects or {}) do
		local ok, effect = pcall(Instance.new, entry[1])
		if ok and effect then
			for property, value in pairs(entry[2] or {}) do
				pcall(function()
					effect[property] = value
				end)
			end
			effect.Parent = sound
		end
	end
	sound.Parent = holder
	sound:Play()
	return sound
end

-- For the gallery and the probe: how much is live.
function ExplosiveFx.Count()
	return #live, #debris, #ExplosiveFx.Clouds
end

-- Everything gone at once (a match ending).
function ExplosiveFx.Clear()
	for index = #live, 1, -1 do
		live[index].destroy(live[index])
		live[index] = nil
	end
	for index = #debris, 1, -1 do
		debris[index].part:Destroy()
		debris[index] = nil
	end
	table.clear(ExplosiveFx.Clouds)
	table.clear(splats)
end

return ExplosiveFx
