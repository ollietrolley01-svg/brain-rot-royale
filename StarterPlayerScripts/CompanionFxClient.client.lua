-- Draws companion abilities from the server's CompanionAttack / CompanionHit broadcasts, and animates
-- every nearby companion (see CompanionAnimations).
--
-- 2026-09-24 (Oliver: "make way better quality and cool animations for the brainrots' abilities").
-- Every move is four beats, and the effects and the creature's body move on the same clock:
--
--   anticipation  0 .. windup: the creature winds up (CompanionAnimations), a charge orb gathers
--                 sparks at its front, a light and a rim glow build on it -- all from one glow curve
--   action        at the windup, when the server applies the damage (or launches the move):
--                 a muzzle flash, then the move's own shape --
--                   Spit       a glob with a trail and drips, straight at the target
--                   Bonk       the creature itself leaps, streaking, and slams down with a ring
--                   Zap        a flickering bolt: a jagged core, a glow sleeve and a crackle
--                   Chain      the bolt, spun out, jumping on to each enemy it forks to
--                   Lob        a spinning glob on a high arc; a ring on the ground fills in so it
--                              closes exactly when the splash lands
--                   Shockwave  two rings racing out to the move's real radius, a dust wall, cracks
--                   Blast      (a blast brainrot) a recoil flash; ProjectileService draws the boom
--   impact        when the damage lands (the windup, plus the flight for Spit, Bonk and Lob): the
--                 move's landing, sized to its real splash or radius
--   follow-through the creature's overshoot and recovery, and the effects fading
--
-- Timing never lies: the server sends `windup` and `lands` with the move (CompanionService), and
-- the launch and landing are scheduled from them, so a beam, a stomp or a splash is drawn on the
-- frame the server applies its damage (tools/companion_fx_check.py holds both ends to it).
--
-- A move's style (BrainrotData.AbilityStyles) rides both broadcasts and draws a signature of its
-- own ON TOP of the move, in the style's colour so a slow reads as a slow on any brainrot:
--
--   Slow   frost sparkles on the shot; a crown of ice shards and falling snow on whoever it chilled
--   Daze   stars orbiting the victim's head
--   Burn   fire on the shot; flames and embers clinging to the victim for the burn's length
--   Toxic  drips off the shot; a puddle, bubbles and drips on the victim for the poison's length
--   Leech  a siphon ribbon from the victim back to the owner, orbs flowing along it, a heal pulse
--   Wide   a second, heavier wave out to the full (wider) splash, and ground cracks
--   Quick  speed streaks off the creature on the strike, and a snappier recovery
--   Long   an aim line to the target through the windup, and a scope glint on the strike
--   Fork   the extra jump drawn as a bright arc, with a split-spark where it forks
--
-- The move itself is tinted by the brainrot: its accent colour for the body of the effect, its
-- rarity colour for the rim, sparkles and light, and a rarer brainrot's effects a little bigger
-- and busier (a Secret's trails run the rainbow).
--
-- Performance caps (tools/companion_fx_check.py measures them under a 40-companion stress run, with a
-- planted fault for each; the animate distance and the hit-mark rate are unchanged from before and
-- only read, not measured):
--   CULL_DISTANCE 450        no effect at all for a move further than this from the camera
--   DETAIL_DISTANCE 160      beyond it (and not your own companion) only the core shapes: no
--                            particles, no lights, no rim glow
--   ANIMATE_DISTANCE 220     companions further than this hold their rest pose
--   16 effects per companion, 64 in all    the oldest is ended early to make room (one Lob
--                            landing on four enemies is about 15 at its busiest)
--   600 live particles       every particle is a counted Emit; none are left emitting on a rate
--   8 lights, 4 rim glows    (Highlights: Roblox draws 31 at most, and other systems use them too)
--   4.5 s lifetime           no effect lives longer (a 4 s poison is the longest)
--   12 hit marks a second    however many companions are landing hits
--
-- All local: nothing here replicates. Companions are posed through Motor6D.Transform, which is
-- local too, so every client animates them itself.
--
-- static-check: globals __companionFxHarness
-- The harness seam: tools/companion_fx_check.py and tools/companion_fx_gallery.lua load this
-- file's source with `__companionFxHarness` set, which hands it their own clock, frame signals,
-- remotes and sound stub, and gets the frame step back so they can freeze any moment. In the game
-- the global is nil and every line below runs as it always did.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Seam = __companionFxHarness
local RunService = Seam and Seam.RunService or game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CompanionAnimations = require(Shared:WaitForChild("CompanionAnimations"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = Seam and Seam.Remotes or require(Shared:WaitForChild("Remotes"))
local Sfx = Seam and Seam.Sfx or require(script.Parent:WaitForChild("Sfx"))
local player = Seam and Seam.LocalPlayer or Players.LocalPlayer

-- Wall time since the game started. (os.clock is CPU time in Roblox and runs slow on a quiet
-- client -- COORDINATION "os.clock is not wall time" -- which would stretch every effect.)
local function now()
	if Seam then
		return Seam.clock()
	end
	return time()
end

local CAPS = {
	CULL_DISTANCE = 450,
	DETAIL_DISTANCE = 160,
	ANIMATE_DISTANCE = 220,
	EFFECTS_PER_COMPANION = 16,
	EFFECTS = 64,
	PARTICLES = 600,
	LIGHTS = 8,
	HIGHLIGHTS = 4,
	EFFECT_LIFE = 4.5,
	IMPACTS_PER_SECOND = 12,
	-- Scheduled launches and landings waiting for their moment.
	PENDING = 256,
	-- How dark the owner's screen-edge pulse ever gets: a hint, not a flash.
	VIGNETTE = 0.22,
}

local WHITE = Color3.new(1, 1, 1)
local UP = Vector3.new(0, 1, 0)
local TEXTURE = {
	glow = "rbxasset://textures/glow.png",
	fire = "rbxasset://textures/particles/fire_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	sparks = "rbxasset://textures/particles/fire_sparks_main.dds",
	sparkle = "rbxasset://textures/sparkle.png",
}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- Each style's colour and sound. Plain colours, not the brainrot's, so a style reads the same on
-- every companion. `on` is when the sound plays: on the hit (the style only lands on a hit that did
-- damage, CompanionService.applyStyle), on the strike, or on the landing.
local STYLE = {
	Slow = { color = rgb(150, 220, 255), cue = "CompanionFxChill", on = "hit" },
	Daze = { color = rgb(255, 236, 110), cue = "CompanionFxDaze", on = "hit" },
	Burn = { color = rgb(255, 120, 30), cue = "CompanionFxBurn", on = "hit" },
	Toxic = { color = rgb(120, 230, 70), cue = "CompanionFxToxic", on = "hit" },
	Leech = { color = rgb(230, 40, 70), cue = "CompanionFxLeech", on = "hit" },
	Wide = { color = rgb(255, 214, 150), cue = "CompanionFxWide", on = "lands" },
	Quick = { color = rgb(120, 240, 255), cue = "CompanionFxQuick", on = "strike" },
	Long = { color = rgb(255, 250, 210), cue = "CompanionFxLong", on = "strike" },
	Fork = { color = rgb(190, 120, 255), cue = "CompanionFxFork", on = "strike" },
}

local folder = Instance.new("Folder")
folder.Name = "CompanionFx"
folder.Parent = Seam and Seam.parent or workspace

local rng = Random.new()

--------------------------------------------------------------------------------
-- Effects: every instance this script makes belongs to one, and goes when it ends
--------------------------------------------------------------------------------

-- Live effects, oldest first, and how many each companion has.
local live = {}
local liveBy = {}
-- Launches and landings waiting for their moment: { at, fn }.
local pending = {}
-- What is out right now, against CAPS.
local budget = { effects = 0, particles = 0, lights = 0, highlights = 0, batches = {} }

-- For the checks: what happened and when. Nothing in the game reads it.
local function mark(what, ctx, extra)
	if Seam and Seam.mark then
		Seam.mark(what, ctx and ctx.key, now(), extra)
	end
end

local function finish(fx)
	if fx.done then
		return
	end
	fx.done = true
	for _, instance in ipairs(fx.owned) do
		instance:Destroy()
	end
	fx.host:Destroy()
	budget.lights -= fx.lights
	budget.highlights -= fx.highlights
	budget.effects -= 1
	local count = (liveBy[fx.key] or 1) - 1
	liveBy[fx.key] = count > 0 and count or nil
end

-- The oldest live effect (of `key`, if given), to end early when a cap is reached.
local function oldest(key)
	for _, fx in ipairs(live) do
		if not fx.done and (key == nil or fx.key == key) then
			return fx
		end
	end
	return nil
end

-- A new effect: an invisible anchored host part at `position` that carries its attachments,
-- emitters, beams and lights, plus any loose parts it adds to `owned`. `detail` false leaves out
-- particles, lights and rim glows (see CAPS.DETAIL_DISTANCE).
local function effect(key, name, position, life, detail)
	if (liveBy[key] or 0) >= CAPS.EFFECTS_PER_COMPANION then
		local old = oldest(key)
		if old then
			finish(old)
		end
	end
	if budget.effects >= CAPS.EFFECTS then
		local old = oldest(nil)
		if old then
			finish(old)
		end
	end
	local host = Instance.new("Part")
	host.Name = name
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CastShadow = false
	host.CFrame = CFrame.new(position)
	host.Parent = folder
	local fx = {
		key = key,
		born = now(),
		life = math.min(life, CAPS.EFFECT_LIFE),
		detail = detail ~= false,
		host = host,
		owned = {},
		lights = 0,
		highlights = 0,
	}
	table.insert(live, fx)
	liveBy[key] = (liveBy[key] or 0) + 1
	budget.effects += 1
	return fx
end

-- Runs one beat. A beat that throws is dropped and warned about (once per kind of beat, so a
-- fault in every Lob landing is one line, not one a second), and never stops the frame: the
-- beats after it and every live effect still run.
local warnedBeats = {}
local function runBeat(kind, fn, t)
	local ok, err = pcall(fn, t)
	if not ok and not warnedBeats[kind] then
		warnedBeats[kind] = true
		warn("[CompanionFx] " .. tostring(kind) .. " beat failed: " .. tostring(err))
	end
end

-- Runs `fn(t)` `delay` seconds from now, on the first frame at or after it. (A tenth of a
-- millisecond's grace, so float rounding in the clock never costs a whole frame.) `kind` names
-- the beat for the warning if it throws.
local function schedule(delay, fn, kind)
	kind = kind or "beat"
	-- Nothing to wait for (a Blast): now, not next frame. Safe here: this is never called from an
	-- effect's update (see `step`).
	if delay <= 0 then
		runBeat(kind, fn, now())
		return
	end
	if #pending >= CAPS.PENDING then
		return
	end
	table.insert(pending, { at = now() + math.max(delay, 0), fn = fn, kind = kind })
end

-- A counted burst of particles, trimmed to what the budget has room for.
local function pruneParticles(t)
	local batches = budget.batches
	local index = 1
	while index <= #batches do
		if batches[index].expires <= t then
			budget.particles -= batches[index].count
			table.remove(batches, index)
		else
			index += 1
		end
	end
end

local function emit(fx, emitter, count)
	if not emitter or not fx.detail or fx.done then
		return 0
	end
	local t = now()
	pruneParticles(t)
	local allowed = math.min(math.floor(count), CAPS.PARTICLES - budget.particles)
	if allowed <= 0 then
		return 0
	end
	emitter:Emit(allowed)
	table.insert(budget.batches, { expires = t + emitter.Lifetime.Max, count = allowed })
	budget.particles += allowed
	return allowed
end

--------------------------------------------------------------------------------
-- Building blocks
--------------------------------------------------------------------------------

local function CS(a, b)
	return ColorSequence.new(a, b or a)
end

local function NS(a, b)
	return NumberSequence.new(a, b or a)
end

-- A loose neon shape belonging to `fx`.
local function shape(fx, size, cframe, color, transparency, partType, material)
	local part = Instance.new("Part")
	part.Name = "Fx"
	if partType then
		part.Shape = partType
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.Neon
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder
	table.insert(fx.owned, part)
	return part
end

local function ball(fx, size, position, color, transparency)
	return shape(fx, Vector3.new(size, size, size), CFrame.new(position), color, transparency, Enum.PartType.Ball)
end

-- A flat disc lying on the ground (a Cylinder's length is its X axis, so it is turned on its side).
local function disc(fx, radius, position, color, transparency)
	return shape(fx, Vector3.new(0.15, radius * 2, radius * 2), CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2),
		color, transparency, Enum.PartType.Cylinder)
end

-- An attachment on the effect's host, at a world position (hosts are never rotated).
local function attach(fx, world)
	local attachment = Instance.new("Attachment")
	attachment.Position = world - fx.host.Position
	attachment.Parent = fx.host
	return attachment
end

local function beam(fx, a0, a1, o)
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.Texture = o.texture or TEXTURE.glow
	b.TextureMode = Enum.TextureMode.Stretch
	b.TextureLength = o.length or 1
	b.TextureSpeed = o.speed or 0
	b.Color = o.colors or CS(o.color or WHITE)
	b.Transparency = NS(o.transparency or 0)
	b.Width0 = o.width
	b.Width1 = o.width1 or o.width
	b.LightEmission = 1
	b.LightInfluence = 0
	b.FaceCamera = true
	b.Segments = o.segments or 1
	b.CurveSize0 = o.curve0 or 0
	b.CurveSize1 = o.curve1 or 0
	b.ZOffset = o.z or 0
	b.Parent = fx.host
	return b
end

-- A particle emitter that never runs on a rate: every particle comes from a counted `emit`.
local function emitter(fx, parent, o)
	if not fx.detail then
		return nil
	end
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Texture = o.texture or TEXTURE.sparkle
	e.Color = o.colors or CS(o.color or WHITE)
	e.Size = o.size or NS(0.4, 0)
	e.Transparency = o.transparency or NS(0, 1)
	e.Lifetime = NumberRange.new(o.life[1], o.life[2])
	e.Speed = NumberRange.new(o.speed[1], o.speed[2])
	e.SpreadAngle = Vector2.new(o.spread or 180, o.spread or 180)
	e.Acceleration = o.accel or Vector3.zero
	e.Drag = o.drag or 0
	e.LightEmission = o.emission or 1
	e.LightInfluence = 0
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-(o.spin or 90), o.spin or 90)
	e.EmissionDirection = o.direction or Enum.NormalId.Top
	e.ZOffset = o.z or 0.5
	if o.inward then
		e.Shape = Enum.ParticleEmitterShape.Sphere
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
	end
	e.Parent = parent or fx.host
	return e
end

local function light(fx, parent, color, range, brightness)
	if not fx.detail or budget.lights >= CAPS.LIGHTS then
		return nil
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent or fx.host
	fx.lights += 1
	budget.lights += 1
	return l
end

-- A rim glow on a companion. Your own companion may always take the last slot; others leave it.
local function rimGlow(fx, model, fill, outline, own)
	if not fx.detail or typeof(model) ~= "Instance" then
		return nil
	end
	local room = own and CAPS.HIGHLIGHTS or CAPS.HIGHLIGHTS - 1
	if budget.highlights >= room then
		return nil
	end
	local h = Instance.new("Highlight")
	h.Adornee = model
	h.FillColor = fill
	h.OutlineColor = outline
	h.FillTransparency = 1
	h.OutlineTransparency = 1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = folder
	table.insert(fx.owned, h)
	fx.highlights += 1
	budget.highlights += 1
	return h
end

-- A hollow ring lying flat: four quarter-circle beams (a Bézier handle of 0.5523 of the radius is a
-- quarter circle), each attachment turned so its axis is the circle's tangent.
local QUARTER = 0.5523
local function ring(fx, centre, o)
	local r = { atts = {}, beams = {}, centre = centre - fx.host.Position }
	for index = 1, 4 do
		local attachment = Instance.new("Attachment")
		attachment.Parent = fx.host
		r.atts[index] = attachment
	end
	for index = 1, 4 do
		r.beams[index] = beam(fx, r.atts[index], r.atts[index % 4 + 1], {
			texture = o.texture or TEXTURE.glow, color = o.color, colors = o.colors, width = o.width or 1,
			transparency = o.transparency or 0, segments = 12, z = o.z,
		})
	end
	return r
end

local function ringSet(r, radius, width, transparency)
	radius = math.max(radius, 0.05)
	for index = 1, 4 do
		local angle = (index - 1) * math.pi / 2
		local c, s = math.cos(angle), math.sin(angle)
		local at = r.centre + Vector3.new(c * radius, 0, s * radius)
		r.atts[index].CFrame = CFrame.fromMatrix(at, Vector3.new(-s, 0, c), UP)
	end
	local sequence = transparency and NS(transparency)
	for _, b in ipairs(r.beams) do
		b.CurveSize0 = radius * QUARTER
		b.CurveSize1 = radius * QUARTER
		if width then
			b.Width0 = width
			b.Width1 = width
		end
		if sequence then
			b.Transparency = sequence
		end
	end
end

-- A jagged bolt from `from` to `to`: a string of attachments with a thin core beam between each
-- pair; `rejag` moves the inner points so it flickers.
local function bolt(fx, from, to, o)
	local distance = (to - from).Magnitude
	local count = math.clamp(math.floor(distance / 4), 3, 8)
	local b = { atts = {}, beams = {}, from = from, to = to, count = count, jag = o.jag or 0.9 }
	for index = 0, count do
		table.insert(b.atts, attach(fx, from:Lerp(to, index / count)))
	end
	for index = 1, count do
		table.insert(b.beams, beam(fx, b.atts[index], b.atts[index + 1], {
			texture = TEXTURE.sparks, color = o.color, width = o.width, transparency = 0, z = 1, speed = 2,
		}))
	end
	return b
end

local function rejag(fx, b)
	local along = b.to - b.from
	if along.Magnitude < 0.1 then
		return
	end
	local dir = along.Unit
	for index = 2, b.count do
		local base = b.from:Lerp(b.to, (index - 1) / b.count)
		local offset = rng:NextUnitVector()
		offset = (offset - dir * offset:Dot(dir)) * b.jag * rng:NextNumber(0.3, 1)
		b.atts[index].Position = base + offset - fx.host.Position
	end
end

local function fadeBeams(beams, transparency)
	local sequence = NS(transparency)
	for _, b in ipairs(beams) do
		b.Transparency = sequence
	end
end

-- Positions along a cubic Bézier.
local function bezier(p0, p1, p2, p3, a)
	local inv = 1 - a
	return p0 * (inv * inv * inv) + p1 * (3 * inv * inv * a) + p2 * (3 * inv * a * a) + p3 * (a * a * a)
end

-- A rainbow for a Secret's trails; everyone else runs from their accent to their rarity colour.
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0.7, 1)),
	ColorSequenceKeypoint.new(0.25, Color3.fromHSV(0.16, 0.7, 1)),
	ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.4, 0.7, 1)),
	ColorSequenceKeypoint.new(0.75, Color3.fromHSV(0.62, 0.7, 1)),
	ColorSequenceKeypoint.new(1, Color3.fromHSV(0.83, 0.7, 1)),
})

local function palette(info)
	local main = typeof(info.color) == "Color3" and info.color or WHITE
	local tier = math.max((Rarity.Index[info.rarity] or 1) - 1, 0)
	return {
		main = main,
		hot = main:Lerp(WHITE, 0.55),
		rarity = Rarity.Color(info.rarity),
		tier = tier,
		-- Rarer brainrots' effects grow a little and throw more particles.
		grow = 1 + tier * 0.07,
		more = 1 + tier * 0.18,
		trail = tier >= 6 and RAINBOW or ColorSequence.new(main, Rarity.Color(info.rarity)),
	}
end

--------------------------------------------------------------------------------
-- Owner feedback: a soft pulse at the screen edges when your own companion strikes or lands a hit
--------------------------------------------------------------------------------

local vignette = nil
local pulses = {}

local function buildVignette()
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CompanionFxScreen"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Under the HUD: this is atmosphere, never something that covers a button.
	gui.DisplayOrder = -1
	local edges = {}
	-- Top, bottom, left, right: each a strip fading from the edge inward.
	local layout = {
		{ UDim2.new(1, 0, 0.2, 0), UDim2.new(0, 0, 0, 0), 90 },
		{ UDim2.new(1, 0, 0.2, 0), UDim2.new(0, 0, 0.8, 0), -90 },
		{ UDim2.new(0.14, 0, 1, 0), UDim2.new(0, 0, 0, 0), 0 },
		{ UDim2.new(0.14, 0, 1, 0), UDim2.new(0.86, 0, 0, 0), 180 },
	}
	for _, spec in ipairs(layout) do
		local frame = Instance.new("Frame")
		frame.Size = spec[1]
		frame.Position = spec[2]
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = WHITE
		frame.BackgroundTransparency = 1
		frame.Visible = false
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = spec[3]
		gradient.Transparency = NumberSequence.new(0, 1)
		gradient.Parent = frame
		frame.Parent = gui
		table.insert(edges, frame)
	end
	gui.Parent = playerGui
	return { gui = gui, edges = edges }
end

-- `strength` 0-1 of CAPS.VIGNETTE, fading out over `time`.
local function pulse(color, strength, time)
	if #pulses >= 4 then
		table.remove(pulses, 1)
	end
	table.insert(pulses, { color = color, peak = math.clamp(strength, 0, 1) * CAPS.VIGNETTE, born = now(), life = time })
end

local function stepVignette(t)
	if #pulses == 0 and not vignette then
		return
	end
	local level, color = 0, WHITE
	local index = 1
	while index <= #pulses do
		local p = pulses[index]
		local age = (t - p.born) / p.life
		if age >= 1 then
			table.remove(pulses, index)
		else
			local value = p.peak * (1 - age) * (1 - age)
			if value > level then
				level, color = value, p.color
			end
			index += 1
		end
	end
	if level > 0 and not vignette then
		vignette = buildVignette()
	end
	if not vignette then
		return
	end
	for _, frame in ipairs(vignette.edges) do
		frame.Visible = level > 0.002
		frame.BackgroundColor3 = color
		frame.BackgroundTransparency = 1 - level
	end
end

--------------------------------------------------------------------------------
-- Rigs
--------------------------------------------------------------------------------

-- model -> rig, for every rigged companion in workspace.Companions. They stream in whole
-- (ModelStreamingMode Atomic), but a model can still show up a moment before its last parts.
local rigs = {}
local companionsFolder = nil

local function track(model)
	if rigs[model] or not model:IsA("Model") then
		return
	end
	local rig = CompanionAnimations.Rig(model)
	if rig then
		rigs[model] = rig
	end
end

task.spawn(function()
	local companions = Seam and Seam.companions or workspace:WaitForChild("Companions")
	companionsFolder = companions
	for _, model in ipairs(companions:GetChildren()) do
		track(model)
	end
	companions.ChildAdded:Connect(function(model)
		track(model)
		if not rigs[model] then
			schedule(0.5, function()
				if model.Parent then
					track(model)
				end
			end, "rig")
		end
	end)
	companions.ChildRemoved:Connect(function(model)
		rigs[model] = nil
	end)
end)

-- Where a rig's Body joint rests in the world: the creature's base, the frame its poses are in.
local function restFrame(rig)
	local joint = rig.joints.Body
	return rig.root.CFrame * joint.C0
end

local function rigFor(info)
	local model = info and info.companion
	if typeof(model) ~= "Instance" then
		return nil
	end
	track(model)
	return rigs[model]
end

local function alive(rig)
	return rig ~= nil and rig.root ~= nil and rig.root.Parent ~= nil
end

-- Where the creature's body is right now, leap included: its rest frame moved by the pose.
local function bodyAt(rig)
	local pose = rig.pose
	local base = restFrame(rig)
	if not pose then
		return base.Position
	end
	return (base * CFrame.new(pose.x, pose.y, pose.z)).Position
end

local function cameraAt()
	local camera = workspace.CurrentCamera
	return camera and camera.CFrame.Position or nil
end

-- Posed in Stepped, the same slot the gun poses use: after physics has placed the root and
-- before the frame renders.
RunService.Stepped:Connect(function()
	local eye = cameraAt()
	local t = now()
	for model, rig in pairs(rigs) do
		if not model.Parent or not alive(rig) then
			rigs[model] = nil
		elseif eye and (rig.root.Position - eye).Magnitude >= CAPS.ANIMATE_DISTANCE then
			-- Out of range: settle into the rest pose once, rather than freezing mid-move (a Bonk
			-- caught mid-leap would otherwise hang in the air until it came back into range).
			if not rig.resting then
				rig.resting = true
				rig.clip, rig.cheer = nil, nil
				CompanionAnimations.Rest(rig)
			end
		else
			rig.resting = false
			local pose = CompanionAnimations.Idle(rig, t)
			for _, key in ipairs({ "clip", "cheer" }) do
				local clip = rig[key]
				if clip then
					if clip.world then
						-- The target in the frame the pose is in, redone every frame because the
						-- companion keeps following its owner through the move.
						clip.target = restFrame(rig):PointToObjectSpace(clip.world)
					end
					if not CompanionAnimations.Layer(pose, rig.body, clip, t - clip.start, rig.scale) then
						rig[key] = nil
					end
				end
			end
			CompanionAnimations.Apply(rig, pose)
		end
	end
end)

--------------------------------------------------------------------------------
-- Pieces every move shares
--------------------------------------------------------------------------------

-- Where a move leaves the creature from: just in front of it, toward its target.
local function frontOf(ctx)
	local rig = ctx.rig
	if alive(rig) then
		local base = rig.root.Position
		local flat = ctx.to - base
		flat = Vector3.new(flat.X, 0, flat.Z)
		local dir = flat.Magnitude > 0.1 and flat.Unit or rig.root.CFrame.LookVector
		return base + dir * 0.9 * rig.scale + UP * 0.3 * rig.scale
	end
	return ctx.from
end

-- The creature's feet, for stomps and launch dust.
local function feetOf(ctx)
	if alive(ctx.rig) then
		return restFrame(ctx.rig).Position
	end
	return ctx.from - UP * 1.5
end

-- The ground under a point (the move's target is a body's middle); a stand-in height if nothing
-- is found within reach. A body in the way (the target's own legs) is stepped past: up to three
-- casts, each leaving out the character the last one hit.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function ground(position)
	local exclude = companionsFolder and { folder, companionsFolder } or { folder }
	for _ = 1, 3 do
		rayParams.FilterDescendantsInstances = exclude
		local result = workspace:Raycast(position + UP, Vector3.new(0, -9, 0), rayParams)
		if not result then
			break
		end
		local model = result.Instance and result.Instance:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			table.insert(exclude, model)
		else
			return result.Position + UP * 0.1
		end
	end
	return position - UP * 2.8
end

-- The anticipation: an orb gathering sparks at the creature's front, its light and rim glow
-- rising on the clip's own glow curve, until the strike; then the orb pops.
local function charge(ctx)
	local pal = ctx.pal
	local fx = effect(ctx.key, "Charge", frontOf(ctx), ctx.strike + 0.2, ctx.detail)
	fx.host.Size = Vector3.new(3, 3, 3) * pal.grow
	local core = ball(fx, 0.2, fx.host.Position, pal.hot, 0)
	local shell = ball(fx, 0.4, fx.host.Position, pal.main, 0.65)
	local gather = emitter(fx, fx.host, {
		texture = TEXTURE.sparkle, colors = ColorSequence.new(pal.rarity, pal.hot), size = NS(0.45, 0.05),
		life = { 0.14, 0.2 }, speed = { 6, 9 }, inward = true, spin = 200,
	})
	emit(fx, gather, 8 * pal.more)
	local glowLight = light(fx, fx.host, pal.main, 8 + pal.tier, 0)
	local rim = rimGlow(fx, ctx.info.companion, pal.main, pal.rarity, ctx.own)
	-- Long: an aim line from the creature to its target, sharpening through the windup.
	local aim = nil
	if ctx.style == "Long" then
		local a0, a1 = attach(fx, fx.host.Position), attach(fx, ctx.to)
		aim = { a0 = a0, a1 = a1, beam = beam(fx, a0, a1, { color = STYLE.Long.color, width = 0.08, transparency = 0.9, z = 1 }) }
	end
	local emittedHalf = false
	fx.update = function(_, age)
		local g = CompanionAnimations.Glow(ctx.clipKind, age, ctx.travel, ctx.style)
		local at = frontOf(ctx)
		fx.host.CFrame = CFrame.new(at)
		if age < ctx.strike then
			local size = (0.25 + 0.75 * g) * pal.grow * ctx.bodySize
			core.Size = Vector3.new(size, size, size)
			core.CFrame = CFrame.new(at)
			shell.Size = core.Size * 1.9
			shell.CFrame = core.CFrame
			if not emittedHalf and age >= ctx.strike * 0.5 then
				emittedHalf = true
				emit(fx, gather, 6 * pal.more)
			end
			if aim then
				aim.a0.Position = Vector3.zero
				aim.a1.Position = ctx.to - at
				aim.beam.Width0 = 0.06 + 0.1 * g
				aim.beam.Width1 = aim.beam.Width0
				aim.beam.Transparency = NS(0.9 - 0.55 * g)
			end
		else
			-- The pop: the orb bursts outward and is gone.
			local a = math.clamp((age - ctx.strike) / 0.15, 0, 1)
			local size = pal.grow * ctx.bodySize * (1 + 1.4 * a)
			core.Size = Vector3.new(size, size, size)
			core.CFrame = CFrame.new(at)
			core.Transparency = a
			shell.Size = core.Size * 1.6
			shell.CFrame = core.CFrame
			shell.Transparency = 0.65 + 0.35 * a
			if aim then
				aim.beam.Transparency = NS(math.min(1, 0.35 + a))
			end
		end
		if glowLight then
			glowLight.Brightness = 5 * g
		end
		if rim then
			rim.FillTransparency = 1 - 0.5 * g
			rim.OutlineTransparency = 1 - 0.85 * g
		end
	end
	return fx
end

-- The strike's muzzle flash at the creature's front: a flash, a cone of sparks toward the target,
-- a light; plus Quick's speed streaks and Long's scope glint.
local function muzzle(ctx, scale)
	local pal = ctx.pal
	local from = frontOf(ctx)
	local fx = effect(ctx.key, "Muzzle", from, 0.4, ctx.detail)
	local look = ctx.to - from
	-- The host stays unturned (every attachment on it is placed by world offset); a nozzle
	-- attachment turned toward the target aims the sparks.
	local nozzle = Instance.new("Attachment")
	if look.Magnitude > 0.1 then
		nozzle.CFrame = CFrame.lookAt(Vector3.zero, look)
	end
	nozzle.Parent = fx.host
	local size = 1.1 * pal.grow * ctx.bodySize * (scale or 1)
	local flash = ball(fx, size, from, pal.hot, 0.1)
	local sparks = emitter(fx, nozzle, {
		texture = TEXTURE.sparks, colors = ColorSequence.new(pal.hot, pal.rarity), size = NS(0.5, 0),
		life = { 0.12, 0.22 }, speed = { 18, 30 }, spread = 28, direction = Enum.NormalId.Front, drag = 4,
	})
	emit(fx, sparks, 10 * pal.more)
	local flashLight = light(fx, fx.host, pal.main, 10 + pal.tier, 6)
	local streaks = nil
	if ctx.style == "Quick" and alive(ctx.rig) then
		-- Three streaks trailing behind the creature, away from its target.
		streaks = {}
		local back = look.Magnitude > 0.1 and -look.Unit or -ctx.rig.root.CFrame.LookVector
		local side = back:Cross(UP)
		side = side.Magnitude > 0.01 and side.Unit or Vector3.new(1, 0, 0)
		for index = -1, 1 do
			local start = ctx.rig.root.Position + side * index * 0.6 * ctx.rig.scale + UP * index * 0.2
			local a0, a1 = attach(fx, start), attach(fx, start + back * 5)
			table.insert(streaks, beam(fx, a0, a1, { color = STYLE.Quick.color, width = 0.18, width1 = 0.02, transparency = 0.2 }))
		end
	end
	local glint = nil
	if ctx.style == "Long" then
		glint = emitter(fx, fx.host, {
			texture = TEXTURE.sparkle, color = STYLE.Long.color, size = NS(3.2, 0), life = { 0.22, 0.26 },
			speed = { 0, 0 }, spin = 0,
		})
		emit(fx, glint, 1)
	end
	fx.update = function(_, age)
		local a = math.clamp(age / 0.14, 0, 1)
		flash.Size = Vector3.new(size, size, size) * (1 + 1.2 * a)
		flash.Transparency = 0.1 + 0.9 * a
		if flashLight then
			flashLight.Brightness = 6 * (1 - math.clamp(age / 0.2, 0, 1))
		end
		if streaks then
			fadeBeams(streaks, math.clamp(0.2 + age / 0.25, 0, 1))
		end
	end
	return fx
end

-- A burst where something lands: a flash, sparks flying out, a light. `killed` makes it bigger.
local function burst(ctx, position, color, size, killed)
	local pal = ctx.pal
	local fx = effect(ctx.key, "Burst", position, killed and 0.6 or 0.45, ctx.detail)
	local flash = ball(fx, size, position, WHITE, 0.05)
	local halo = ball(fx, size * 1.6, position, color, 0.5)
	local sparks = emitter(fx, fx.host, {
		texture = TEXTURE.sparks, colors = ColorSequence.new(WHITE, color), size = NS(0.45, 0),
		life = { 0.2, 0.35 }, speed = { 10, 22 }, drag = 3, accel = Vector3.new(0, -20, 0),
	})
	emit(fx, sparks, (killed and 18 or 10) * pal.more)
	local flashLight = light(fx, fx.host, color, killed and 16 or 10, killed and 8 or 5)
	-- Shards: thin slivers flying out and falling.
	local shards = {}
	for index = 1, killed and 8 or 5 do
		local dir = rng:NextUnitVector()
		dir = Vector3.new(dir.X, math.abs(dir.Y) * 0.8 + 0.1, dir.Z).Unit
		local part = shape(fx, Vector3.new(0.18, 0.18, 0.8), CFrame.lookAt(position, position + dir), index % 2 == 0 and color or WHITE, 0)
		table.insert(shards, { part = part, velocity = dir * rng:NextNumber(12, 20) })
	end
	fx.update = function(_, age)
		local a = math.clamp(age / 0.22, 0, 1)
		flash.Size = Vector3.new(size, size, size) * (1 + 1.5 * a)
		flash.Transparency = 0.05 + 0.95 * a
		halo.Size = Vector3.new(size, size, size) * (1.6 + 2 * a)
		halo.Transparency = 0.5 + 0.5 * a
		if flashLight then
			flashLight.Brightness = (killed and 8 or 5) * (1 - a)
		end
		local fade = math.clamp(age / fx.life, 0, 1)
		for _, shard in ipairs(shards) do
			local v = shard.velocity + Vector3.new(0, -40 * age, 0)
			local at = position + shard.velocity * age + Vector3.new(0, -20 * age * age, 0)
			shard.part.CFrame = CFrame.lookAt(at, at + v)
			shard.part.Transparency = fade
		end
	end
	return fx
end

-- A shockwave on the ground: a bright ring racing out to `radius`, a softer one behind it, a flash
-- disc and a wall of dust. `radius` is the move's real reach, so the ring shows where it hurt.
local function groundWave(ctx, centre, radius, o)
	local pal = ctx.pal
	local fx = effect(ctx.key, o.name or "Wave", centre, o.life or 0.7, ctx.detail)
	local fast = ring(fx, centre + UP * 0.2, { color = o.color or pal.hot, width = (o.width or 1.2) * pal.grow, z = 1 })
	local soft = ring(fx, centre + UP * 0.15, { colors = ColorSequence.new(pal.main, pal.rarity), width = (o.width or 1.2) * 2.2 * pal.grow, transparency = 0.5 })
	local flat = disc(fx, 1, centre + UP * 0.05, pal.main, 0.6)
	-- Dust: soft puffs riding out with the wave.
	local puffs = {}
	for index = 1, o.dust or 8 do
		local angle = index / (o.dust or 8) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local part = shape(fx, Vector3.new(1, 1, 1), CFrame.new(centre), pal.main:Lerp(rgb(150, 140, 125), 0.6), 0.45,
			Enum.PartType.Ball, Enum.Material.SmoothPlastic)
		table.insert(puffs, { part = part, dir = Vector3.new(math.cos(angle), 0, math.sin(angle)) })
	end
	local cracks = nil
	if o.cracks then
		cracks = {}
		for index = 1, 6 do
			local angle = index / 6 * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
			local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local part = shape(fx, Vector3.new(0.25, 0.08, 0.1), CFrame.lookAt(centre, centre + dir), pal.hot, 0)
			table.insert(cracks, { part = part, dir = dir })
		end
	end
	ringSet(fast, 0.5)
	ringSet(soft, 0.3)
	fx.update = function(_, age)
		local quick = math.clamp(age / (o.time or 0.32), 0, 1)
		local slow = math.clamp(age / ((o.time or 0.32) * 1.7), 0, 1)
		local outQuick = 1 - (1 - quick) ^ 3
		local outSlow = 1 - (1 - slow) ^ 2
		ringSet(fast, radius * outQuick, nil, quick * quick)
		ringSet(soft, radius * outSlow, nil, 0.5 + 0.5 * slow)
		local r = math.max(radius * outQuick, 0.1)
		flat.Size = Vector3.new(0.15, r * 2, r * 2)
		flat.Transparency = 0.6 + 0.4 * quick
		for _, puff in ipairs(puffs) do
			local size = 1.2 + 2.2 * outSlow
			puff.part.Size = Vector3.new(size, size * 0.7, size)
			puff.part.CFrame = CFrame.new(centre + puff.dir * radius * 0.92 * outSlow + UP * (0.4 + size * 0.2))
			puff.part.Transparency = 0.45 + 0.55 * slow
		end
		if cracks then
			local grow = math.clamp(age / 0.18, 0, 1)
			local fade = math.clamp((age - 0.25) / 0.4, 0, 1)
			for _, crack in ipairs(cracks) do
				local length = radius * 0.55 * grow + 0.1
				crack.part.Size = Vector3.new(0.25, 0.08, length)
				crack.part.CFrame = CFrame.lookAt(centre + crack.dir * length / 2 + UP * 0.08, centre + crack.dir * (length + 1) + UP * 0.08)
				crack.part.Transparency = fade
			end
		end
	end
	return fx
end

-- A style's accent riding a shot: frost, fire, drips, sparkle. Returns an emitter and how many to
-- emit a frame, or nil for a style with nothing to ride.
local ACCENT = {
	Slow = { texture = TEXTURE.sparkle, size = { 0.5, 0 }, life = { 0.35, 0.5 }, speed = { 0.5, 2 }, accel = Vector3.new(0, -4, 0), rate = 1 },
	Daze = { texture = TEXTURE.sparkle, size = { 0.6, 0 }, life = { 0.25, 0.35 }, speed = { 1, 3 }, rate = 1 },
	Burn = { texture = TEXTURE.fire, size = { 0.9, 0.1 }, life = { 0.2, 0.3 }, speed = { 1, 3 }, accel = Vector3.new(0, 8, 0), rate = 2, emission = 0.9 },
	Toxic = { texture = TEXTURE.smoke, size = { 0.35, 0.1 }, life = { 0.4, 0.55 }, speed = { 0, 1 }, accel = Vector3.new(0, -30, 0), rate = 1, emission = 0.3 },
	Leech = { texture = TEXTURE.glow, size = { 0.45, 0 }, life = { 0.25, 0.35 }, speed = { 0, 1 }, rate = 1 },
}
local function accent(fx, style, parent)
	local a = ACCENT[style]
	if not a then
		return nil, 0
	end
	return emitter(fx, parent, {
		texture = a.texture, color = STYLE[style].color, size = NS(a.size[1], a.size[2]), life = a.life, speed = a.speed,
		accel = a.accel, emission = a.emission,
	}), a.rate
end

-- A glob flying from the front of the creature to `to` over the flight, `arc` studs high at its
-- peak, with a trail, drips and its style's accent. `onArrive` runs from the landing schedule, not
-- from here: this only draws the flight.
local function glob(ctx, size, arc, spin)
	local pal = ctx.pal
	local from = frontOf(ctx)
	local to = ctx.to
	local flight = math.max(ctx.lands - ctx.strike, 0.05)
	local fx = effect(ctx.key, "Glob", from, flight + 0.35, ctx.detail)
	local core = ball(fx, size * 0.6, from, pal.hot, 0)
	local shell = ball(fx, size, from, pal.main, 0.45)
	local a0 = Instance.new("Attachment")
	a0.Position = UP * size * 0.4
	a0.Parent = fx.host
	local a1 = Instance.new("Attachment")
	a1.Position = -UP * size * 0.4
	a1.Parent = fx.host
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Texture = TEXTURE.glow
	trail.Color = pal.trail
	trail.Transparency = NumberSequence.new(0.15, 1)
	trail.WidthScale = NumberSequence.new(1, 0.1)
	trail.Lifetime = ctx.style == "Long" and 0.35 or 0.2
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.FaceCamera = true
	trail.MinLength = 0.05
	trail.Parent = fx.host
	local drips = emitter(fx, fx.host, {
		texture = TEXTURE.glow, color = pal.main, size = NS(0.3 * pal.grow, 0), life = { 0.25, 0.35 }, speed = { 1, 3 },
		accel = Vector3.new(0, -35, 0),
	})
	local styled, rate = accent(fx, ctx.style, fx.host)
	local launched = now()
	fx.update = function(_, age)
		local a = math.clamp((now() - launched) / flight, 0, 1)
		local at = from:Lerp(to, a) + UP * (arc * 4 * a * (1 - a))
		local turn = spin and CFrame.Angles(age * 9, age * 6, 0) or CFrame.new()
		fx.host.CFrame = CFrame.new(at)
		core.CFrame = CFrame.new(at) * turn
		shell.CFrame = core.CFrame
		if a >= 1 then
			-- Arrived: the glob is spent; the trail finishes fading behind it.
			core.Transparency = 1
			shell.Transparency = 1
			trail.Enabled = false
		else
			emit(fx, drips, 1)
			if styled then
				emit(fx, styled, rate)
			end
		end
	end
	return fx
end

-- A three-layer beam between two points: a wide soft glow, a scrolling crackle, and a jagged core
-- that re-jags every few frames. `arc` bends the glow and crackle (a Fork's jump arcs over).
local function zapBeam(ctx, from, to, o)
	local pal = ctx.pal
	local fx = effect(ctx.key, o.name or "Bolt", from, o.life or 0.26, ctx.detail)
	local a0, a1 = attach(fx, from), attach(fx, to)
	local length = (to - from).Magnitude
	local curve = o.arc and length * 0.35 or 0
	if curve > 0 then
		-- Tip both ends' axes upward so the curve bows over the top.
		local dir = (to - from).Unit
		local bend = (dir + UP * 1.2).Unit
		a0.CFrame = CFrame.fromMatrix(a0.Position, bend, dir:Cross(UP).Magnitude > 0.01 and dir:Cross(UP).Unit or Vector3.new(0, 0, 1))
		local bendEnd = (dir - UP * 1.2).Unit
		a1.CFrame = CFrame.fromMatrix(a1.Position, bendEnd, dir:Cross(UP).Magnitude > 0.01 and dir:Cross(UP).Unit or Vector3.new(0, 0, 1))
	end
	local color = o.color or pal.main
	local sleeve = beam(fx, a0, a1, { color = color, width = 1.5 * pal.grow, transparency = 0.35, curve0 = curve, curve1 = curve, segments = curve > 0 and 16 or 1 })
	local crackle = beam(fx, a0, a1, {
		texture = TEXTURE.sparks, colors = ColorSequence.new(pal.hot, pal.rarity), width = 0.8 * pal.grow, transparency = 0.1,
		speed = 5, length = 3, curve0 = curve, curve1 = curve, segments = curve > 0 and 16 or 1, z = 1,
	})
	local core = nil
	if curve == 0 then
		core = bolt(fx, from, to, { color = WHITE:Lerp(color, 0.25), width = 0.24 * pal.grow, jag = math.clamp(length * 0.06, 0.4, 1.4) })
		rejag(fx, core)
	end
	local styled, rate = accent(fx, ctx.style, a1)
	emit(fx, styled, rate * 6)
	local lastJag = 0
	fx.update = function(_, age)
		local a = math.clamp(age / fx.life, 0, 1)
		local flicker = (math.floor(age * 30) % 2 == 0) and 0 or 0.25
		sleeve.Transparency = NS(math.min(1, 0.35 + 0.65 * a + flicker * 0.5))
		crackle.Transparency = NS(math.min(1, 0.1 + 0.9 * a))
		if core then
			if age - lastJag >= 0.035 then
				lastJag = age
				rejag(fx, core)
			end
			fadeBeams(core.beams, math.min(1, a * a + flicker))
		end
	end
	return fx
end

--------------------------------------------------------------------------------
-- The moves: what each draws on its strike and on its landing
--------------------------------------------------------------------------------

local MOVES = {}

MOVES.Spit = {
	cue = "CompanionFxSpit",
	landCue = "CompanionFxSplat",
	strike = function(ctx)
		glob(ctx, 0.9 * ctx.pal.grow, 0.6, false)
	end,
	lands = function(ctx)
		local pal = ctx.pal
		burst(ctx, ctx.to, pal.main, 1.3 * pal.grow)
		-- A splat on the ground under it, spreading and drying.
		local fx = effect(ctx.key, "Splat", ctx.to, 0.9, ctx.detail)
		local spot = disc(fx, 0.5, ground(ctx.to), pal.main, 0.3)
		local drops = emitter(fx, fx.host, {
			texture = TEXTURE.glow, color = pal.main, size = NS(0.35, 0), life = { 0.3, 0.45 }, speed = { 8, 14 },
			accel = Vector3.new(0, -45, 0), drag = 1,
		})
		emit(fx, drops, 12 * pal.more)
		fx.update = function(_, age)
			local r = 0.5 + 1.8 * math.clamp(age / 0.15, 0, 1)
			spot.Size = Vector3.new(0.15, r * 2, r * 2)
			spot.Transparency = 0.3 + 0.7 * math.clamp((age - 0.3) / 0.6, 0, 1)
		end
	end,
}

MOVES.Zap = {
	cue = "CompanionFxZap",
	strike = function(ctx)
		local from = frontOf(ctx)
		zapBeam(ctx, from, ctx.to, {})
		-- The jumps. Zap has none of its own; a Forking style's is the last one.
		local hops = { ctx.to, ctx.info.to2, ctx.info.to3 }
		for index = 2, 3 do
			local a, b = hops[index - 1], hops[index]
			if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
				local forked = ctx.style == "Fork" and index == ctx.forkHop
				zapBeam(ctx, a, b, { name = forked and "ForkArc" or "Bolt", arc = forked, color = forked and STYLE.Fork.color or nil })
				if forked then
					burst(ctx, a, STYLE.Fork.color, 0.9)
				end
			else
				break
			end
		end
	end,
	lands = function(ctx)
		local pal = ctx.pal
		burst(ctx, ctx.to, pal.main, 1.2 * pal.grow)
		for _, point in ipairs({ ctx.info.to2, ctx.info.to3 }) do
			if typeof(point) == "Vector3" then
				burst(ctx, point, pal.main, 1 * pal.grow)
			end
		end
	end,
}

-- A Chain is the Zap flung out with a spin (the body clip) and always at least one jump.
MOVES.Chain = {
	cue = "CompanionFxChain",
	strike = MOVES.Zap.strike,
	lands = MOVES.Zap.lands,
}

MOVES.Lob = {
	cue = "CompanionFxLob",
	landCue = "CompanionFxLobSplash",
	strike = function(ctx)
		local pal = ctx.pal
		glob(ctx, 1.3 * pal.grow, 10, true)
		-- The telegraph: where it will land, and when -- the inner ring fills out to the splash's
		-- edge on the frame the splash lands.
		local splash = math.max(tonumber(ctx.info.splash) or 8, 2)
		local centre = ground(ctx.to)
		local flight = math.max(ctx.lands - ctx.strike, 0.05)
		local fx = effect(ctx.key, "Telegraph", centre, flight + 0.05, ctx.detail)
		local edge = ring(fx, centre + UP * 0.15, { color = pal.main, width = 0.35, transparency = 0.55 })
		local fill = ring(fx, centre + UP * 0.2, { color = pal.hot, width = 0.5, transparency = 0.3 })
		ringSet(edge, splash)
		ringSet(fill, 0.1)
		local started = now()
		fx.update = function()
			local a = math.clamp((now() - started) / flight, 0, 1)
			ringSet(fill, splash * a, nil, 0.3 + 0.2 * (1 - a))
		end
	end,
	lands = function(ctx)
		local pal = ctx.pal
		local splash = math.max(tonumber(ctx.info.splash) or 8, 2)
		local centre = ground(ctx.to)
		burst(ctx, ctx.to, pal.main, 2 * pal.grow)
		groundWave(ctx, centre, splash, { name = "Splash", time = 0.25, dust = 6 })
		-- A dome of the splash, the size of the damage.
		local fx = effect(ctx.key, "Dome", centre, 0.45, ctx.detail)
		local dome = ball(fx, 1, centre, pal.main, 0.55)
		local drops = emitter(fx, fx.host, {
			texture = TEXTURE.glow, color = pal.main, size = NS(0.5, 0), life = { 0.4, 0.6 }, speed = { 14, 24 },
			spread = 50, accel = Vector3.new(0, -60, 0),
		})
		emit(fx, drops, 18 * pal.more)
		fx.update = function(_, age)
			local a = math.clamp(age / 0.3, 0, 1)
			local size = splash * 2 * (1 - (1 - a) ^ 2)
			dome.Size = Vector3.new(size, size * 0.6, size)
			dome.Transparency = 0.55 + 0.45 * a
		end
	end,
}

MOVES.Bonk = {
	cue = "CompanionFxLeap",
	landCue = "CompanionFxSlam",
	strike = function(ctx)
		local pal = ctx.pal
		local rig = ctx.rig
		-- Launch dust at its feet.
		local feet = feetOf(ctx)
		local dust = effect(ctx.key, "LaunchDust", feet, 0.6, ctx.detail)
		local puff = emitter(dust, dust.host, {
			texture = TEXTURE.smoke, color = pal.main:Lerp(rgb(160, 150, 135), 0.6), size = NS(1.2, 2.4),
			transparency = NumberSequence.new(0.4, 1), life = { 0.35, 0.5 }, speed = { 4, 8 }, spread = 70, emission = 0.1, drag = 3,
		})
		emit(dust, puff, 6 * pal.more)
		local flight = math.max(ctx.lands - ctx.strike, 0.05)
		if not alive(rig) then
			-- No rig to throw: a stand-in body flies instead.
			glob(ctx, 1.4 * pal.grow, 6, true)
			return
		end
		-- The streak behind the leaping body.
		local fx = effect(ctx.key, "Streak", bodyAt(rig), flight + 0.3, ctx.detail)
		local a0 = Instance.new("Attachment")
		a0.Position = UP * 0.7 * rig.scale
		a0.Parent = fx.host
		local a1 = Instance.new("Attachment")
		a1.Position = -UP * 0.7 * rig.scale
		a1.Parent = fx.host
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Texture = TEXTURE.glow
		trail.Color = pal.trail
		trail.Transparency = NumberSequence.new(0.3, 1)
		trail.WidthScale = NumberSequence.new(1, 0.2)
		trail.Lifetime = 0.25
		trail.LightEmission = 1
		trail.LightInfluence = 0
		trail.FaceCamera = true
		trail.Parent = fx.host
		local styled, rate = accent(fx, ctx.style, fx.host)
		local launched = now()
		fx.update = function()
			if alive(rig) then
				fx.host.CFrame = CFrame.new(bodyAt(rig) + UP * 0.6 * rig.scale)
			end
			if now() - launched >= flight then
				trail.Enabled = false
			elseif styled then
				emit(fx, styled, rate)
			end
		end
	end,
	lands = function(ctx)
		local pal = ctx.pal
		local splash = math.max(tonumber(ctx.info.splash) or 6, 3)
		local centre = ground(ctx.to)
		burst(ctx, ctx.to - UP * 0.8, pal.main, 2.2 * pal.grow)
		groundWave(ctx, centre, splash, { name = "Slam", time = 0.22, dust = 8, cracks = true })
	end,
}

MOVES.Shockwave = {
	cue = "CompanionFxQuake",
	strike = function()
		-- The stomp IS the landing (a Shockwave hurts on the windup): drawn by `lands`.
	end,
	lands = function(ctx)
		local pal = ctx.pal
		local radius = math.max(tonumber(ctx.info.range) or 18, 4)
		local centre = ground(feetOf(ctx) + UP)
		burst(ctx, feetOf(ctx) + UP * 0.5, pal.main, 2.4 * pal.grow)
		groundWave(ctx, centre, radius, { name = "Quake", time = 0.34, width = 1.6, dust = 12, cracks = true, life = 0.9 })
	end,
}

-- A blast brainrot: the explosion is ProjectileService's; the creature only kicks and flashes.
MOVES.Blast = {
	cue = "CompanionFxBlast",
	strike = function(ctx)
		muzzle(ctx, 1.6)
		groundWave(ctx, ground(feetOf(ctx) + UP), 3.5, { name = "Recoil", time = 0.18, dust = 5, life = 0.45 })
	end,
	lands = function() end,
}

--------------------------------------------------------------------------------
-- Attacks
--------------------------------------------------------------------------------

-- Every cue this script can play, for the checks (each must exist in SoundConfig).
local CUES = { "CompanionFxCharge", "CompanionHit", "CompanionDown", "CompanionAttack", "BallKick", "CrateOpen" }
for _, move in pairs(MOVES) do
	table.insert(CUES, move.cue)
	if move.landCue then
		table.insert(CUES, move.landCue)
	end
end
for _, style in pairs(STYLE) do
	table.insert(CUES, style.cue)
end

local function onAttack(info)
	if type(info) ~= "table" or typeof(info.from) ~= "Vector3" or typeof(info.to) ~= "Vector3" then
		return
	end
	local t0 = now()
	local kind = info.blast == true and "Blast" or info.kind
	if not MOVES[kind] then
		kind = "Spit"
	end
	local style = STYLE[info.style] and info.style or nil
	local travel = math.clamp(tonumber(info.travel) or 0, 0, 3)
	local phases = CompanionAnimations.Phases(kind, travel, style)
	-- The server's own numbers first: it waits `windup` before the move connects and applies the
	-- damage at `lands`. A payload without them (an older server) falls back to the same beats
	-- worked out here from the same constants.
	local windup = kind == "Blast" and 0 or math.clamp(tonumber(info.windup) or phases.strike, 0, 1)
	local lands = math.clamp(tonumber(info.lands) or phases.lands, windup, windup + 3)
	local rig = rigFor(info)
	local key = typeof(info.companion) == "Instance" and info.companion or "world"

	if rig then
		-- A Bonk leaps its body on to the target: land it a little above the target's feet.
		local aim = kind == "Bonk" and info.to - UP * 1.5 or info.to
		rig.clip = { kind = kind, start = t0, world = aim, travel = travel, style = style }
	end

	local eye = cameraAt()
	local distance = eye and (info.from - eye).Magnitude or 0
	if distance > CAPS.CULL_DISTANCE then
		return
	end
	local own = player ~= nil and info.owner ~= nil and info.owner == player.UserId
	local ctx = {
		info = info,
		kind = kind,
		clipKind = kind,
		style = style,
		rig = rig,
		key = key,
		pal = palette(info),
		from = info.from,
		to = info.to,
		travel = travel,
		strike = windup,
		lands = lands,
		own = own,
		detail = own or distance <= CAPS.DETAIL_DISTANCE,
		-- Which jump is the Forking style's own: a Chain's first is its own, so a Fork adds the second.
		forkHop = kind == "Chain" and 3 or 2,
		-- The charge orb and muzzle flash go with the creature's size (companions are built at 0.55).
		bodySize = rig and math.clamp(rig.scale * 1.6, 0.6, 1.4) or 1,
	}
	mark("attack", ctx, { windup = windup, lands = lands, kind = kind, style = style })

	if windup > 0 then
		charge(ctx)
		Sfx.PlayAt("CompanionFxCharge", info.from, 0.1)
	end
	local move = MOVES[kind]
	schedule(windup, function()
		mark("strike", ctx)
		if kind ~= "Shockwave" and kind ~= "Blast" then
			muzzle(ctx)
		end
		move.strike(ctx)
		Sfx.PlayAt(move.cue, frontOf(ctx), 0.08)
		if style and STYLE[style].on == "strike" then
			Sfx.PlayAt(STYLE[style].cue, frontOf(ctx), 0.05)
		end
		if own then
			pulse(ctx.pal.main, 0.35, 0.25)
		end
	end, "strike")
	if kind ~= "Blast" then
		schedule(lands, function()
			mark("lands", ctx)
			move.lands(ctx)
			local at = kind == "Shockwave" and feetOf(ctx) or info.to
			if move.landCue then
				Sfx.PlayAt(move.landCue, at, 0.1)
			end
			if style == "Wide" and (kind == "Bonk" or kind == "Lob" or kind == "Shockwave") then
				-- The wider wave, out to the (wider) splash, heavier and slower.
				local radius = kind == "Shockwave" and (tonumber(info.range) or 18) or (tonumber(info.splash) or 8)
				local centre = ground(kind == "Shockwave" and feetOf(ctx) + UP or info.to)
				groundWave(ctx, centre, radius * 1.02, { name = "WideWave", color = STYLE.Wide.color, time = 0.5, width = 2.4, dust = 10, cracks = true, life = 1 })
				Sfx.PlayAt(STYLE.Wide.cue, at, 0.05)
			end
			-- A lobby demo on a practice target hurts nobody, so no CompanionHit comes back: its thwack
			-- plays here instead, when the move would have connected.
			if info.practice and kind ~= "Shockwave" then
				Sfx.PlayAt("CompanionHit", info.to, 0.12)
			end
		end, "lands")
	end
end

Remotes.Event("CompanionAttack").OnClientEvent:Connect(onAttack)

--------------------------------------------------------------------------------
-- Hits: where the server says damage really landed, and the style that rode it
--------------------------------------------------------------------------------

local impactWindow, impactsInWindow = 0, 0

-- Something to follow: a victim's root if the server named one, else a fixed point.
local function follower(victim, position)
	local root = typeof(victim) == "Instance" and victim:FindFirstChild("HumanoidRootPart")
	return function()
		if root and root.Parent then
			return root.Position
		end
		return position
	end
end

local SIGNATURE = {}

-- Slow: a crown of ice shards at the feet and snow falling, for the slow's length.
SIGNATURE.Slow = function(ctx, where, length)
	local color = STYLE.Slow.color
	local fx = effect(ctx.key, "Style_Slow", where(), length + 0.35, ctx.detail)
	local shards = {}
	for index = 1, 6 do
		local angle = index / 6 * math.pi * 2
		local part = shape(fx, Vector3.new(0.3, 1.2, 0.3), CFrame.new(where()), color, 0.2, nil, Enum.Material.Glass)
		table.insert(shards, { part = part, angle = angle, tall = 0.8 + (index % 3) * 0.35 })
	end
	local frost = ring(fx, where(), { color = color, width = 0.4, transparency = 0.3 })
	local snow = emitter(fx, fx.host, {
		texture = TEXTURE.sparkle, color = color, size = NS(0.35, 0.05), life = { 0.5, 0.7 }, speed = { 0, 1 },
		accel = Vector3.new(0, -6, 0),
	})
	local lastSnow = -1
	fx.update = function(_, age)
		local at = where()
		local feet = at - UP * 2.4
		fx.host.CFrame = CFrame.new(at + UP * 2.2)
		local grow = math.clamp(age / 0.12, 0, 1)
		local fade = math.clamp((age - length) / 0.35, 0, 1)
		for _, shard in ipairs(shards) do
			local out = Vector3.new(math.cos(shard.angle), 0, math.sin(shard.angle))
			local height = shard.tall * grow
			shard.part.Size = Vector3.new(0.3, math.max(height, 0.05), 0.3)
			shard.part.CFrame = CFrame.new(feet + out * 0.9 + UP * height * 0.45) * CFrame.Angles(0, -shard.angle, 0) * CFrame.Angles(0, 0, 0.35)
			shard.part.Transparency = 0.2 + 0.8 * fade
		end
		frost.centre = feet + UP * 0.1 - fx.host.Position
		ringSet(frost, 1.6 + 0.4 * grow, nil, 0.3 + 0.7 * fade)
		if age - lastSnow >= 0.12 and age < length then
			lastSnow = age
			emit(fx, snow, 2)
		end
	end
end

-- Daze: stars circling the head.
SIGNATURE.Daze = function(ctx, where, length)
	local color = STYLE.Daze.color
	local life = math.max(length, 0.6) + 0.4
	local fx = effect(ctx.key, "Style_Daze", where(), life, ctx.detail)
	local stars = {}
	for index = 1, 3 do
		local attachment = Instance.new("Attachment")
		attachment.Parent = fx.host
		local gui = Instance.new("BillboardGui")
		gui.Adornee = attachment
		gui.Size = UDim2.fromScale(0.9, 0.9)
		gui.LightInfluence = 0
		gui.AlwaysOnTop = false
		local image = Instance.new("ImageLabel")
		image.BackgroundTransparency = 1
		image.Size = UDim2.fromScale(1, 1)
		image.Image = TEXTURE.sparkle
		image.ImageColor3 = color
		image.Parent = gui
		gui.Parent = attachment
		table.insert(stars, { attachment = attachment, image = image, phase = index / 3 * math.pi * 2 })
	end
	fx.update = function(_, age)
		fx.host.CFrame = CFrame.new(where() + UP * 2.6)
		local fade = math.clamp((age - (life - 0.3)) / 0.3, 0, 1)
		for _, star in ipairs(stars) do
			local angle = star.phase + age * 7
			star.attachment.Position = Vector3.new(math.cos(angle) * 1.1, math.sin(age * 9 + star.phase) * 0.15, math.sin(angle) * 1.1)
			star.image.ImageTransparency = fade
			star.image.Rotation = age * 360
		end
	end
end

-- Burn: a flare of fire, then flames and embers clinging for the burn's length.
SIGNATURE.Burn = function(ctx, where, length)
	local color = STYLE.Burn.color
	local fx = effect(ctx.key, "Style_Burn", where(), length + 0.4, ctx.detail)
	local flames = emitter(fx, fx.host, {
		texture = TEXTURE.fire, colors = ColorSequence.new(rgb(255, 220, 120), color), size = NS(1.4, 0.3),
		transparency = NumberSequence.new(0.1, 1), life = { 0.3, 0.45 }, speed = { 2, 4 }, accel = Vector3.new(0, 10, 0),
		spread = 25, emission = 0.9,
	})
	local embers = emitter(fx, fx.host, {
		texture = TEXTURE.sparks, color = color, size = NS(0.25, 0), life = { 0.5, 0.8 }, speed = { 3, 6 },
		accel = Vector3.new(0, 6, 0), spread = 40,
	})
	emit(fx, flames, 8)
	local glowLight = light(fx, fx.host, color, 9, 3)
	local last = 0
	fx.update = function(_, age)
		fx.host.CFrame = CFrame.new(where() - UP * 0.5)
		if age - last >= 0.1 and age < length then
			last = age
			emit(fx, flames, 2)
			emit(fx, embers, 1)
		end
		if glowLight then
			local fade = 1 - math.clamp((age - length) / 0.4, 0, 1)
			glowLight.Brightness = (2.4 + math.sin(age * 31) * 0.8) * fade
		end
	end
end

-- Toxic: a puddle where it hit, bubbles rising and drips falling off the victim for the poison's length.
SIGNATURE.Toxic = function(ctx, where, length)
	local color = STYLE.Toxic.color
	local fx = effect(ctx.key, "Style_Toxic", where(), length + 0.4, ctx.detail)
	local puddle = disc(fx, 0.4, ground(where()), color, 0.35)
	local bubbles = emitter(fx, fx.host, {
		texture = TEXTURE.smoke, color = color, size = NS(0.6, 1.3), transparency = NumberSequence.new(0.35, 1),
		life = { 0.6, 0.9 }, speed = { 1, 2 }, accel = Vector3.new(0, 3, 0), spread = 30, emission = 0.4,
	})
	local drips = emitter(fx, fx.host, {
		texture = TEXTURE.glow, color = color, size = NS(0.3, 0.1), life = { 0.35, 0.45 }, speed = { 0, 0.5 },
		accel = Vector3.new(0, -40, 0),
	})
	local last = 0
	fx.update = function(_, age)
		fx.host.CFrame = CFrame.new(where())
		local r = 0.4 + 1.6 * math.clamp(age / 0.2, 0, 1)
		puddle.Size = Vector3.new(0.15, r * 2, r * 2)
		puddle.Transparency = 0.35 + 0.65 * math.clamp((age - length) / 0.4, 0, 1)
		if age - last >= 0.15 and age < length then
			last = age
			emit(fx, bubbles, 1)
			emit(fx, drips, 1)
		end
	end
end

-- Leech: a ribbon from the victim back to the owner (or the creature), with orbs of health flowing
-- along it and a pulse when they arrive.
SIGNATURE.Leech = function(ctx, where)
	local color = STYLE.Leech.color
	local ownerRoot = typeof(ctx.hit.ownerRoot) == "Instance" and ctx.hit.ownerRoot or nil
	local rig = ctx.rig
	local function home()
		if ownerRoot and ownerRoot.Parent then
			return ownerRoot.Position
		end
		if alive(rig) then
			return rig.root.Position
		end
		return nil
	end
	if not home() then
		return
	end
	local fx = effect(ctx.key, "Style_Leech", where(), 0.9, ctx.detail)
	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Parent = fx.host
	a1.Parent = fx.host
	local ribbon = beam(fx, a0, a1, {
		color = color, colors = ColorSequence.new(color, color:Lerp(WHITE, 0.4)), width = 0.7, width1 = 0.35,
		transparency = 0.2, speed = 3, length = 2, segments = 20, z = 1,
	})
	local orbs = {}
	for index = 1, 3 do
		table.insert(orbs, { part = ball(fx, 0.55, where(), color:Lerp(WHITE, 0.2), 0), delay = (index - 1) * 0.1 })
	end
	local healed = false
	local heal = nil
	fx.update = function(_, age)
		local from, to = where(), home() or where()
		fx.host.CFrame = CFrame.new(from)
		-- Bow the ribbon up: both ends' axes lean upward.
		local lift = math.max((to - from).Magnitude * 0.35, 1.5)
		a0.CFrame = CFrame.fromMatrix(Vector3.zero, UP, Vector3.new(1, 0, 0))
		a1.CFrame = CFrame.fromMatrix(to - from, -UP, Vector3.new(1, 0, 0))
		ribbon.CurveSize0 = lift
		ribbon.CurveSize1 = lift
		ribbon.Transparency = NS(math.clamp(0.2 + (age - 0.55) / 0.35, 0.2, 1))
		for _, orb in ipairs(orbs) do
			local a = math.clamp((age - orb.delay) / 0.5, 0, 1)
			local at = bezier(from, from + UP * lift, to + UP * lift, to, a)
			orb.part.CFrame = CFrame.new(at)
			orb.part.Transparency = (a <= 0 or a >= 1) and 1 or 0
		end
		if not healed and age >= 0.7 then
			healed = true
			heal = ball(fx, 1.5, to, color, 0.4)
		end
		if heal then
			local b = math.clamp((age - 0.7) / 0.2, 0, 1)
			heal.Size = Vector3.new(1.5, 1.5, 1.5) * (1 + 2 * b)
			heal.CFrame = CFrame.new(to)
			heal.Transparency = 0.4 + 0.6 * b
		end
	end
	if ctx.own then
		pulse(color, 0.6, 0.45)
	end
end

-- Quick: a double tick of light on the hit.
SIGNATURE.Quick = function(ctx, where)
	local fx = effect(ctx.key, "Style_Quick", where(), 0.25, ctx.detail)
	local tick = ball(fx, 1, where(), STYLE.Quick.color, 0.2)
	fx.update = function(_, age)
		local on = (age < 0.06) or (age > 0.1 and age < 0.16)
		tick.Transparency = on and 0.2 or 1
		tick.Size = Vector3.new(1, 1, 1) * (1 + age * 6)
	end
end

-- Long: a sight ring closing on the target.
SIGNATURE.Long = function(ctx, where)
	local fx = effect(ctx.key, "Style_Long", where(), 0.3, ctx.detail)
	local sight = ring(fx, where(), { color = STYLE.Long.color, width = 0.18, transparency = 0.1 })
	fx.update = function(_, age)
		local a = math.clamp(age / 0.3, 0, 1)
		sight.centre = where() - fx.host.Position
		ringSet(sight, 3 * (1 - a) + 0.4, nil, 0.1 + 0.9 * a)
	end
end

-- Fork: a violet crackle on each enemy the arc reached.
SIGNATURE.Fork = function(ctx, where)
	local fx = effect(ctx.key, "Style_Fork", where(), 0.25, ctx.detail)
	local centre = where()
	local spikes = {}
	for index = 1, 3 do
		local dir = rng:NextUnitVector()
		table.insert(spikes, beam(fx, attach(fx, centre), attach(fx, centre + dir * 2), { texture = TEXTURE.sparks, color = STYLE.Fork.color, width = 0.3, width1 = 0 }))
	end
	fx.update = function(_, age)
		fadeBeams(spikes, math.clamp(age / 0.25, 0, 1))
	end
end

-- Wide shows on the landing (its wider wave), not per victim.
SIGNATURE.Wide = function() end

local function onHit(info)
	if type(info) ~= "table" or type(info.positions) ~= "table" then
		return
	end
	local t = now()
	if t - impactWindow > 1 then
		impactWindow, impactsInWindow = t, 0
	end
	local rig = rigFor(info)
	local key = typeof(info.companion) == "Instance" and info.companion or "world"
	local eye = cameraAt()
	local own = player ~= nil and info.owner ~= nil and info.owner == player.UserId
	local style = STYLE[info.style] and info.style or nil
	local length = math.clamp(tonumber(info.styleTime) or 1, 0.3, CAPS.EFFECT_LIFE - 0.5)
	local victims = type(info.victims) == "table" and info.victims or {}
	local drawn = 0
	for index, position in ipairs(info.positions) do
		if index > 4 or impactsInWindow >= CAPS.IMPACTS_PER_SECOND then
			break
		end
		if typeof(position) == "Vector3" then
			local distance = eye and (position - eye).Magnitude or 0
			if distance <= CAPS.CULL_DISTANCE then
				impactsInWindow += 1
				drawn += 1
				local ctx = {
					key = key, rig = rig, own = own, hit = info, pal = palette(info),
					detail = own or distance <= CAPS.DETAIL_DISTANCE,
				}
				burst(ctx, position, ctx.pal.main, (info.killed == true and 2.4 or 1.4) * ctx.pal.grow, info.killed == true)
				if style then
					SIGNATURE[style](ctx, follower(victims[index], position), length)
					mark("signature", ctx, { style = style })
				end
				if index == 1 then
					Sfx.PlayAt("CompanionHit", position, 0.12)
					if style and STYLE[style].on == "hit" then
						Sfx.PlayAt(STYLE[style].cue, position, 0.06)
					end
				end
			end
		end
	end
	if drawn > 0 and own then
		pulse(style and STYLE[style].color or WHITE, info.killed == true and 1 or 0.55, info.killed == true and 0.5 or 0.3)
	end

	if rig and (not rig.cheer or t - rig.cheer.start > 0.3) then
		rig.cheer = { kind = "Cheer", start = t }
	end
end

Remotes.Event("CompanionHit").OnClientEvent:Connect(onHit)

-- A companion was downed: it bursts into a puff of its colour and a scatter of chunks.
Remotes.Event("CompanionDown").OnClientEvent:Connect(function(info)
	if type(info) ~= "table" or typeof(info.position) ~= "Vector3" then
		return
	end
	local eye = cameraAt()
	local distance = eye and (info.position - eye).Magnitude or 0
	if distance > CAPS.CULL_DISTANCE then
		return
	end
	local position = info.position
	local ctx = { key = "down", pal = palette(info), detail = distance <= CAPS.DETAIL_DISTANCE }
	local color = ctx.pal.main
	Sfx.PlayAt("CompanionDown", position, 0.2)
	burst(ctx, position, color, 3, true)
	groundWave(ctx, ground(position), 9, { name = "Down", time = 0.4, dust = 8 })
	local fx = effect("down", "Chunks", position, 0.8, ctx.detail)
	local chunks = {}
	for _ = 1, 10 do
		local part = shape(fx, Vector3.new(0.5, 0.5, 0.5), CFrame.new(position), color, 0, nil, Enum.Material.SmoothPlastic)
		table.insert(chunks, { part = part, velocity = Vector3.new(rng:NextNumber(-9, 9), rng:NextNumber(6, 14), rng:NextNumber(-9, 9)),
			spin = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), 0) })
	end
	fx.update = function(_, age)
		local a = math.clamp(age / fx.life, 0, 1)
		for _, chunk in ipairs(chunks) do
			local at = position + chunk.velocity * age + Vector3.new(0, -30 * age * age, 0)
			local size = 0.5 - 0.35 * a
			chunk.part.Size = Vector3.new(size, size, size)
			chunk.part.CFrame = CFrame.new(at) * CFrame.Angles(chunk.spin.X * age, chunk.spin.Y * age, 0)
			chunk.part.Transparency = a * a
		end
	end
end)

-- Lobby playground: ball kicks, goals and Cloud Climb clears.
Remotes.Event("PlaygroundFx").OnClientEvent:Connect(function(info)
	if type(info) ~= "table" or typeof(info.position) ~= "Vector3" then
		return
	end
	local eye = cameraAt()
	if eye and (info.position - eye).Magnitude > CAPS.CULL_DISTANCE then
		return
	end
	local position = info.position
	local color = typeof(info.color) == "Color3" and info.color or rgb(255, 214, 110)
	if info.kind == "kick" then
		Sfx.PlayAt("BallKick", position, 0.25)
		return
	end
	local ctx = { key = "playground", pal = palette({ color = color }), detail = true }
	if info.kind == "mine" then
		-- A Rot Mine landing and arming: a small flash and a ring on the ground, nothing more.
		Sfx.PlayAt("CompanionAttack", position, 0.2)
		burst(ctx, position, color, 1.4)
		groundWave(ctx, position - UP * 0.2, 4, { name = "Mine", time = 0.4, dust = 0 })
		return
	end
	local goal = info.kind == "goal"
	Sfx.PlayAt("CrateOpen", position, 0.1)
	burst(ctx, position, color, goal and 5 or 3, true)
	groundWave(ctx, position - UP * 2, goal and 14 or 9, { name = "Confetti", time = 0.5, dust = 0 })
	local fx = effect("playground", "Confetti", position, 1.1, true)
	local bits = {}
	for _ = 1, goal and 24 or 14 do
		local part = shape(fx, Vector3.new(0.5, 0.5, 0.5), CFrame.new(position), Color3.fromHSV(rng:NextNumber(), 0.6, 1), 0)
		table.insert(bits, { part = part, target = position + Vector3.new(rng:NextNumber(-10, 10), rng:NextNumber(4, 14), rng:NextNumber(-10, 10)) })
	end
	fx.update = function(_, age)
		local a = math.clamp(age / fx.life, 0, 1)
		local out = 1 - (1 - a) * (1 - a)
		for _, bit in ipairs(bits) do
			bit.part.CFrame = CFrame.new(position:Lerp(bit.target, out)) * CFrame.Angles(age * 5, age * 4, 0)
			local size = 0.5 - 0.3 * a
			bit.part.Size = Vector3.new(size, size, size)
			bit.part.Transparency = a
		end
	end
end)

--------------------------------------------------------------------------------
-- The frame: scheduled beats first, then every live effect
--------------------------------------------------------------------------------

-- Effects' `update`s only move and fade what they own; anything that makes a NEW effect runs from
-- `pending`, before the effects are walked, so the walk below never sees the list grow under it.
local function step()
	local t = now()
	local index = 1
	while index <= #pending do
		local job = pending[index]
		if t >= job.at - 1e-4 then
			table.remove(pending, index)
			runBeat(job.kind, job.fn, t)
		else
			index += 1
		end
	end
	local write = 0
	local count = #live
	for read = 1, count do
		local fx = live[read]
		if not fx.done then
			local age = t - fx.born
			if age >= fx.life then
				finish(fx)
			elseif fx.update then
				local ok, err = pcall(fx.update, fx, age, t)
				if not ok then
					warn("[CompanionFx] " .. tostring(err))
					finish(fx)
				end
			end
		end
		if not fx.done then
			write += 1
			live[write] = fx
		end
	end
	for clear = count, write + 1, -1 do
		live[clear] = nil
	end
	pruneParticles(t)
	stepVignette(t)
end

RunService.RenderStepped:Connect(step)

if Seam then
	Seam.api = {
		step = step,
		schedule = schedule,
		attack = onAttack,
		hit = onHit,
		caps = CAPS,
		cues = CUES,
		budget = budget,
		live = live,
		pending = pending,
		folder = folder,
		rigs = rigs,
		moves = MOVES,
		styles = STYLE,
		signatures = SIGNATURE,
		vignette = function()
			return vignette
		end,
		pulses = pulses,
	}
end

--------------------------------------------------------------------------------
-- Idle bob
--
-- Your companion is simulated by this client, pulled toward an anchor attachment on your
-- character. Nudging that anchor up and down (and a little side to side) here makes the
-- creature float and sway instead of sitting rigidly at your shoulder — and because this client
-- owns the simulation, everyone else sees the bob too. The server set the anchor's resting
-- position and never touches it again, so the local change isn't overwritten.
--------------------------------------------------------------------------------

-- Each anchor's resting spot, dropped when the anchor goes. Strongly keyed: a weak-keyed table
-- lost the entry now and then, and re-reading the rest mid-bob walked the anchor upward.
local anchorRest = {}

RunService.Heartbeat:Connect(function()
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local anchor = root and root:FindFirstChild("CompanionAnchor")
	if not anchor then
		return
	end

	local rest = anchorRest[anchor]
	if not rest then
		-- Only this character's anchor matters: a new one means the old body is gone, even if its
		-- Destroying never reached this client.
		table.clear(anchorRest)
		rest = anchor.Position
		anchorRest[anchor] = rest
		anchor.Destroying:Connect(function()
			anchorRest[anchor] = nil
		end)
	end

	local t = now()
	anchor.Position = rest + Vector3.new(math.sin(t * 1.3) * 0.25, math.sin(t * 2.2) * 0.4, 0)
end)
