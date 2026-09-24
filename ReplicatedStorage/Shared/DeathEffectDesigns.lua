-- The death effects themselves (#24; CosmeticData kind "KillAnimation", "Death Effects" on screen),
-- keyed by CosmeticData id, built on Shared/DeathEffectFx. Read that file first: it explains the
-- timeline, the budgets and what a design may do to the body.
--
-- Every design runs in four beats, because that is what makes an effect read at a glance from
-- across a street rather than as a pile of parts:
--   anticipation  the body reacts first (winds up, flushes a colour, looks up at what's coming)
--   burst         the one big moment: a flash, a light, the sound, the body popped or flattened
--   follow-through the pieces carry on and overshoot (arcs, bounces, a wobble that settles)
--   settle        everything eases out and fades, and the body is gone by the end
--
-- Fields per design:
--   life     seconds (DeathEffectFx.MAX_LIFETIME at most); the body is gone by then
--   peak     the moment a thumbnail shows (the burst, just after the flash)
--   moments  three stills for the gallery: anticipation, burst, follow-through
--   view     where a preview camera looks, relative to the feet: focus and a radius to fit
--   cues     every SoundConfig cue it plays (the harness checks each exists)
--   build    function(fx): declares the whole timeline up front; fx:step does the rest
--
-- `Default` holds the plain death's two little effects (DeathFxClient), which are not cosmetics.

local Shared = script.Parent
local DeathEffectFx = require(Shared:WaitForChild("DeathEffectFx"))

local Ease = DeathEffectFx.Ease
local V = Vector3.new
local UPRIGHT = DeathEffectFx.UPRIGHT
local BALL = Enum.PartType.Ball
local CYLINDER = Enum.PartType.Cylinder
local NEON = Enum.Material.Neon
local SMOOTH = Enum.Material.SmoothPlastic
local WOOD = Enum.Material.Wood
local GLASS = Enum.Material.Glass
local FOIL = Enum.Material.Foil
local SLATE = Enum.Material.Slate
local BASALT = Enum.Material.Basalt

local rgb = Color3.fromRGB
local WHITE = rgb(255, 255, 255)
local CONFETTI = { rgb(255, 120, 190), rgb(70, 214, 236), rgb(255, 214, 64), rgb(80, 220, 120), rgb(150, 80, 240), rgb(255, 132, 36) }
local GOO = rgb(150, 196, 96)
local GOO_DARK = rgb(96, 140, 56)
local GOO_GLOW = rgb(178, 255, 102)
local BAT = rgb(168, 122, 72)
local GRIP = rgb(60, 40, 30)
local TAPE = rgb(206, 48, 48)
local STAR = rgb(255, 214, 64)
local DUST = rgb(200, 186, 160)
local GHOST = rgb(214, 236, 255)
local GHOST_GLOW = rgb(170, 220, 255)
local EYE = rgb(24, 24, 28)
local DRUM = rgb(206, 150, 80)
local DRUM_HEAD = rgb(244, 226, 190)
local RIM = rgb(206, 48, 48)
local STAMP = rgb(255, 132, 36)
local GOLD = rgb(255, 196, 64)
local GOLD_PALE = rgb(255, 238, 160)
local BRAIN = rgb(255, 150, 176)
local BRAIN_DARK = rgb(206, 92, 124)
local BRAIN_HOT = rgb(255, 90, 160)
local BALLOONS = { rgb(255, 84, 104), rgb(70, 190, 255), rgb(255, 214, 64) }
local STRING = rgb(236, 236, 236)
local INK = rgb(34, 22, 52)
local INK_EDGE = rgb(150, 60, 255)
local CYAN = rgb(60, 240, 255)
local MAGENTA = rgb(255, 60, 220)
local STORM = rgb(58, 60, 72)
local STORM_LIGHT = rgb(96, 100, 118)
local BOLT = rgb(210, 236, 255)
local CHAR = rgb(26, 22, 20)
local ASH = rgb(96, 92, 88)
local ICE = rgb(150, 226, 255)
local ICE_WHITE = rgb(236, 250, 255)
local ROT = rgb(110, 200, 70)
local ROT_DARK = rgb(52, 110, 40)
local MUD = rgb(96, 78, 52)
local ROCK = rgb(70, 58, 52)
local MAGMA = rgb(255, 110, 20)
local EMBER = rgb(255, 196, 60)
local SCORCH = rgb(30, 22, 20)
local VOID = rgb(6, 4, 10)
local VIOLET = rgb(150, 70, 255)
local ORCHID = rgb(255, 90, 230)
local SOUL = rgb(170, 255, 200)

local function where(at)
	if type(at) == "function" then
		return at()
	end
	return at
end

-- Deterministic shiver: two sines out of step, -1..1.
local function shiver(t, seed)
	return math.sin(t * 83.1 + seed * 12.7) * 0.6 + math.sin(t * 47.3 + seed * 5.1) * 0.4
end

-- A neon ball that swells and fades: the flash of a pop.
local function flash(fx, t, at, color, size, duration)
	fx:at(t, function()
		local ball = fx:part(V(1, 1, 1), CFrame.new(where(at)), color, NEON, BALL, 0.05)
		if not ball then
			return
		end
		fx:tween(t, duration, function(e)
			local d = 1 + (size - 1) * e
			ball.Size = V(d, d, d)
			ball.Transparency = 0.05 + 0.95 * e
		end, Ease.quadOut)
	end)
end

-- A flat neon disc racing outwards and fading: a shockwave. `turn` tilts it off the ground.
local function shock(fx, t, at, color, from, to, duration, turn)
	fx:at(t, function()
		local disc = fx:part(V(0.12, from, from), CFrame.new(where(at)) * (turn or CFrame.identity) * UPRIGHT, color, NEON, CYLINDER, 0.3)
		if not disc then
			return
		end
		fx:tween(t, duration, function(e)
			local d = from + (to - from) * e
			disc.Size = V(0.12, d, d)
			disc.Transparency = 0.3 + 0.7 * e
		end, Ease.quadOut)
	end)
end

local function disc(fx, at, diameter, color, material, transparency, thick)
	return fx:part(V(thick or 0.1, diameter, diameter), CFrame.new(at) * UPRIGHT, color, material, CYLINDER, transparency)
end

-- Transparency from what it is now to 1.
local function fadeOut(fx, part, t, duration)
	if not part then
		return
	end
	local base = part.Transparency
	fx:tween(t, duration, function(e)
		part.Transparency = base + (1 - base) * e
	end, Ease.quadIn)
end

-- Where something thrown from `p0` at `v` is after `tau` seconds under `gravity`, bouncing once off
-- `floor` (keeping `bounce` of its speed) and sliding to a stop.
local function hop(p0, v, gravity, tau, floor, bounce)
	local y = p0.Y + v.Y * tau - 0.5 * gravity * tau * tau
	if y >= floor then
		return V(p0.X + v.X * tau, y, p0.Z + v.Z * tau), false
	end
	local a, b, c = -0.5 * gravity, v.Y, p0.Y - floor
	local land = (-b - math.sqrt(math.max(0, b * b - 4 * a * c))) / (2 * a)
	local after = tau - land
	local up = -(v.Y - gravity * land) * (bounce or 0.3)
	local rise = math.max(0, up * after - 0.5 * gravity * after * after)
	local slide = land + math.min(after, 0.5) * 0.35
	return V(p0.X + v.X * slide, floor + rise, p0.Z + v.Z * slide), true
end

local Designs = {}

--------------------------------------------------------------------------------
-- Common
--------------------------------------------------------------------------------

-- They wind up like a spring and POP: streamers, confetti and a popper left smoking on the spot.
Designs.KillConfettiPop = {
	life = 2.4,
	peak = 0.42,
	moments = { 0.2, 0.42, 1.3 },
	view = { focus = V(0, 3.4, 0), radius = 8 },
	cues = { "DeathFuse", "Confetti" },
	build = function(fx)
		local g = fx.ground
		local chest = fx.origin + V(0, 0.8, 0)
		local POP = 0.3

		-- Anticipation: squash down, then stretch up and flush white.
		fx:sound(0, "DeathFuse", 0.1)
		fx:tween(0, 0.18, function(e)
			fx:bodyPose({ scale = V(1 + 0.12 * e, 1 - 0.2 * e, 1 + 0.12 * e) })
		end, Ease.quadOut)
		fx:tween(0.18, POP - 0.18, function(e)
			fx:bodyPose({ scale = V(1.12 - 0.22 * e, 0.8 + 0.42 * e, 1.12 - 0.22 * e), tint = WHITE, tintAlpha = 0.75 * e })
		end, Ease.backIn)
		fx:burst(0.02, chest + V(0, 1.6, 0), { count = 6, color = { STAR, WHITE }, texture = "sparks", size = { 0.35, 0 },
			speed = { 3, 6 }, life = { 0.2, 0.35 }, spread = 40, glow = 1 })

		-- Burst.
		fx:sound(POP, "Confetti", 0.15)
		fx:at(POP, function()
			fx:hideBody()
		end)
		flash(fx, POP, chest, rgb(255, 236, 246), 7, 0.3)
		fx:light(POP, 0.5, chest, CONFETTI[1], 18, 6)
		fx:burst(POP, chest, { count = 16, color = { CONFETTI[1], CONFETTI[3], CONFETTI[2] }, texture = "sparkle", size = { 0.55, 0.2 },
			speed = { 14, 22 }, life = { 0.8, 1.5 }, accel = V(0, -18, 0), drag = 1.4, spin = 300, glow = 0.6 })
		fx:burst(POP, chest, { count = 14, color = { CONFETTI[4], CONFETTI[5], CONFETTI[6] }, texture = "sparkle", size = { 0.5, 0.2 },
			speed = { 10, 18 }, life = { 0.8, 1.6 }, accel = V(0, -16, 0), drag = 1.6, spin = 300, glow = 0.6 })
		fx:burst(POP + 0.05, chest + V(0, 1, 0), { count = 10, color = { GOLD_PALE, GOLD }, texture = "sparkle", size = { 0.3, 0.1 },
			speed = { 2, 5 }, life = { 1.2, 1.9 }, accel = V(0, -2, 0), drag = 1, glow = 1 })

		-- Streamers: out and up with the pop, then fluttering down to lie flat.
		fx:at(POP, function()
			for index = 1, 14 do
				local angle = index / 14 * math.pi * 2 + fx.random:NextNumber() * 0.4
				local out = V(math.cos(angle), 0, math.sin(angle))
				local peak = chest + out * (2.4 + fx.random:NextNumber() * 2.4) + V(0, 3 + fx.random:NextNumber() * 3, 0)
				local land = V(peak.X, g.Y + 0.06, peak.Z) + out * (0.8 + fx.random:NextNumber())
				local spinA, spinB = fx.random:NextNumber() * 9 + 4, fx.random:NextNumber() * 9 + 4
				local streamer = fx:part(V(0.6, 0.08, 0.26), CFrame.new(chest), CONFETTI[index % #CONFETTI + 1], NEON)
				if streamer then
					fx:tween(POP, 0.4, function(e)
						streamer.CFrame = CFrame.new(chest:Lerp(peak, e)) * CFrame.Angles(e * spinA, e * spinB, 0)
					end, Ease.quadOut)
					local fall = 1.65 - index * 0.02
					fx:tween(POP + 0.4, fall, function(e, raw)
						local sway = math.sin(raw * math.pi * 3 + index) * 0.7 * (1 - raw)
						local settle = math.clamp((raw - 0.8) / 0.2, 0, 1)
						local position = peak:Lerp(land, e) + out * sway
						local tumble = CFrame.Angles((1 - settle) * (spinA + raw * 8), (spinB + raw * 5), 0)
						streamer.CFrame = CFrame.new(position) * tumble:Lerp(CFrame.Angles(0, spinB, 0), settle)
					end, Ease.sineInOut)
					fadeOut(fx, streamer, 2.0, 0.35)
				end
			end
		end)

		-- The popper, left smoking where they stood.
		fx:at(POP, function()
			local lean = CFrame.Angles(math.rad(18), fx.random:NextNumber() * math.pi * 2, 0)
			local base = CFrame.new(g) * lean
			local tube = fx:part(V(1.5, 0.9, 0.9), base * CFrame.new(0, 0.75, 0) * UPRIGHT, CONFETTI[5], SMOOTH, CYLINDER)
			local rim = fx:part(V(0.18, 1.1, 1.1), base * CFrame.new(0, 1.5, 0) * UPRIGHT, STAR, NEON, CYLINDER)
			fx:tween(POP, 0.3, function(e, raw)
				local s = math.max(0.05, e)
				if tube then
					tube.Size = V(1.5 * s, 0.9 * s, 0.9 * s)
					tube.CFrame = base * CFrame.new(0, 0.75 * s, 0) * UPRIGHT
				end
				if rim then
					rim.Size = V(0.18, 1.1 * s, 1.1 * s)
					rim.CFrame = base * CFrame.new(0, 1.5 * s, 0) * UPRIGHT
				end
			end, Ease.backOut)
			fx:tween(1.9, 0.45, function(e)
				if tube then
					tube.CFrame = base * CFrame.new(0, 0.75 - 1.6 * e, 0) * UPRIGHT
				end
				if rim then
					rim.CFrame = base * CFrame.new(0, 1.5 - 1.6 * e, 0) * UPRIGHT
				end
			end, Ease.quadIn)
			fadeOut(fx, tube, 2.0, 0.35)
			fadeOut(fx, rim, 2.0, 0.35)
			fx:burst(POP + 0.05, (base * CFrame.new(0, 1.6, 0)).Position, { count = 8, color = { rgb(255, 214, 236), rgb(160, 150, 170) },
				texture = "smoke", size = { 0.8, 2.4 }, speed = { 2, 4 }, life = { 0.9, 1.4 }, spread = 25, direction = lean.UpVector,
				accel = V(0, 2, 0), glow = 0, fade = 0.3 })
		end)
	end,
}

-- They go green, tremble and melt into a bubbling puddle that ripples, stinks and dries up.
Designs.KillRotPuddle = {
	life = 2.8,
	peak = 0.95,
	moments = { 0.25, 0.8, 1.7 },
	view = { focus = V(0, 2.6, 0), radius = 7.5 },
	cues = { "StickySquelch", "DeathBubble" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local MELT = 0.35

		-- Anticipation: rot creeps over them and they tremble.
		fx:tween(0, MELT, function(e, raw)
			fx:bodyPose({ to = pivot * CFrame.new(shiver(raw * MELT, 1) * 0.08 * e, 0, shiver(raw * MELT, 2) * 0.06 * e),
				scale = V(1, 1, 1), tint = GOO, tintAlpha = 0.85 * e })
		end, Ease.sineInOut)

		-- Burst: down they go, spreading as they sink.
		fx:sound(MELT - 0.05, "StickySquelch", 0.15)
		fx:tween(MELT, 0.75, function(e)
			fx:bodyPose({ scale = V(1 + 0.6 * e, 1 - 0.94 * e, 1 + 0.6 * e), fade = 0.25 * e })
		end, Ease.quadIn)
		fx:tween(MELT + 0.6, 0.25, function(e)
			fx:bodyPose({ fade = 0.25 + 0.75 * e })
		end)

		local puddle = disc(fx, g + V(0, 0.06, 0), 0.4, GOO, SMOOTH, 0.12, 0.12)
		local core = disc(fx, g + V(0, 0.1, 0), 0.3, GOO_DARK, SMOOTH, 0.1, 0.1)
		fx:tween(MELT, 0.8, function(e)
			if puddle then
				puddle.Size = V(0.12, 0.4 + 8.2 * e, 0.4 + 8.2 * e)
			end
			if core then
				core.Size = V(0.1, 0.3 + 5 * e, 0.3 + 5 * e)
			end
		end, Ease.backOut)
		fx:burst(MELT + 0.1, g + V(0, 0.6, 0), { count = 18, color = { GOO_GLOW, GOO_DARK }, texture = "glow", size = { 0.5, 0.15 },
			speed = { 8, 14 }, life = { 0.5, 0.8 }, spread = 50, accel = V(0, -40, 0), glow = 0.3 })
		fx:light(MELT, 0.9, g + V(0, 1, 0), GOO_GLOW, 14, 2.5)

		-- Follow-through: bubbles swell, rise a little and pop; the surface ripples.
		for index = 1, 5 do
			local angle = index * 2.4
			local radius = 0.8 + (index % 3) * 0.9
			local at = g + V(math.cos(angle) * radius, 0.25, math.sin(angle) * radius)
			local start = 0.95 + index * 0.17
			local bubble = fx:part(V(0.05, 0.05, 0.05), CFrame.new(at), index % 2 == 0 and GOO_GLOW or GOO, SMOOTH, BALL, 1)
			fx:tween(start, 0.4, function(e)
				if bubble then
					local d = 0.2 + 0.95 * e
					bubble.Size = V(d, d, d)
					bubble.CFrame = CFrame.new(at + V(0, 0.55 * e, 0))
					bubble.Transparency = 0.15
				end
			end, Ease.backOut)
			fx:at(start + 0.42, function()
				if bubble then
					bubble.Transparency = 1
				end
			end)
			if index % 2 == 1 then
				fx:burst(start + 0.42, at + V(0, 0.6, 0), { count = 4, color = GOO_GLOW, texture = "glow", size = { 0.3, 0 },
					speed = { 3, 5 }, life = { 0.25, 0.4 }, spread = 60, accel = V(0, -20, 0) })
			end
		end
		fx:sound(1.35, "DeathBubble", 0.25, g)
		fx:sound(1.8, "DeathBubble", 0.25, g)
		shock(fx, MELT + 0.75, g + V(0, 0.14, 0), GOO_GLOW, 4, 10, 0.6)
		fx:burst(1.2, g + V(0, 0.8, 0), { count = 10, color = { GOO, rgb(120, 140, 90) }, texture = "smoke", size = { 1, 2.6 },
			speed = { 1, 2 }, life = { 1, 1.4 }, spread = 30, accel = V(0, 1.5, 0), glow = 0, fade = 0.45 })

		-- Settle: the puddle dries up.
		fx:tween(2.1, 0.6, function(e)
			if puddle then
				puddle.Size = V(0.12, 8.6 - 7.8 * e, 8.6 - 7.8 * e)
				puddle.Transparency = 0.12 + 0.88 * e
			end
			if core then
				core.Size = V(0.1, 5.3 - 5 * e, 5.3 - 5 * e)
				core.Transparency = 0.1 + 0.9 * e
			end
		end, Ease.quadIn)
	end,
}

-- They float off under three balloons, drifting and turning, until one pops.
Designs.KillBalloonFloat = {
	life = 3.1,
	peak = 1.2,
	moments = { 0.3, 1.1, 2.4 },
	view = { focus = V(0, 6.5, 0), radius = 10 },
	cues = { "DeathBalloonInflate", "DeathBalloonPop" },
	build = function(fx)
		local pivot = fx.pivot
		local LIFT = 0.45
		local RISE = 12
		local POP = 2.35
		-- Where the whole body is at `raw` (0..1) through the climb: slow, then faster, with a sway.
		local function bodyFrame(t)
			local climb = math.max(0, t - LIFT)
			local height = RISE * (climb / (3 - LIFT)) ^ 1.6
			local sway = math.sin(climb * 3.1) * 0.12 * math.min(1, climb * 2)
			return pivot * CFrame.new(0, height, 0) * CFrame.Angles(0, climb * 0.9, sway)
		end

		fx:sound(0, "DeathBalloonInflate", 0.1)
		-- Hands up, where the strings will be.
		local anchors = { V(-1.5, 2.4, 0), V(0, 4.8, 0.3), V(1.5, 2.4, 0) }
		local offsets = { V(-2.1, 9.2, 0.4), V(0.2, 10.4, -0.3), V(2.3, 9, 0.2) }
		local balloons = {}
		for index = 1, 3 do
			local balloon = fx:part(V(0.05, 0.05, 0.05), bodyFrame(0) * CFrame.new(offsets[index]), BALLOONS[index], SMOOTH, BALL, 0.05)
			local knot = fx:part(V(0.3, 0.3, 0.3), bodyFrame(0) * CFrame.new(offsets[index] - V(0, 1.3, 0)), BALLOONS[index], SMOOTH, BALL, 1)
			local line = fx:part(V(0.06, 0.06, 0.06), bodyFrame(0) * CFrame.new(anchors[index]), STRING, SMOOTH, nil, 1)
			balloons[index] = { balloon = balloon, knot = knot, line = line }
			if balloon then
				balloon.Reflectance = 0.15
			end
		end

		-- Every frame from the start: each balloon inflating (springy, one after another: the
		-- anticipation), then the body on its climb with the balloons bobbing above it.
		fx:tween(0, 3.1, function(_, raw)
			local t = raw * 3.1
			local frame = bodyFrame(t)
			if t >= LIFT then
				fx:bodyPose({ to = frame })
			end
			for index, entry in ipairs(balloons) do
				local bob = V(math.sin(t * 2.3 + index) * 0.25, math.sin(t * 3.1 + index * 2) * 0.2, 0)
				local top = frame * CFrame.new(offsets[index] + bob)
				local grown = math.max(0.05, Ease.elasticOut(math.clamp((t - index * 0.08) / 0.4, 0, 1)))
				-- Settle: after the middle one pops, they all drift out of sight.
				local gone = Ease.quadIn(math.clamp((t - 2.3) / 0.65, 0, 1))
				local shown = grown > 0.06 and gone or 1
				if entry.balloon then
					entry.balloon.Size = V(2.1, 2.5, 2.1) * grown
					entry.balloon.CFrame = top
					entry.balloon.Transparency = (index == 2 and t >= POP) and 1 or math.max(0.05, shown)
				end
				local knotAt = top * CFrame.new(0, -1.3 * grown, 0)
				if entry.knot then
					entry.knot.CFrame = knotAt
					entry.knot.Transparency = shown
				end
				if entry.line then
					entry.line.Transparency = math.max(0.1, shown)
					local hand = (frame * CFrame.new(anchors[index])).Position
					local length = (knotAt.Position - hand).Magnitude
					entry.line.Size = V(0.06, 0.06, math.max(0.05, length))
					entry.line.CFrame = CFrame.lookAt((hand + knotAt.Position) / 2, knotAt.Position)
				end
			end
		end)
		fx:burst(0.9, function()
			return (bodyFrame(0.9) * CFrame.new(0, 0.2, 0)).Position
		end, { count = 6, color = { WHITE, BALLOONS[2] }, texture = "sparkle", size = { 0.4, 0 }, speed = { 1, 2 },
			life = { 0.6, 1 }, accel = V(0, -3, 0), glow = 1 })
		fx:burst(1.6, function()
			return (bodyFrame(1.6) * CFrame.new(0, 0.2, 0)).Position
		end, { count = 6, color = { WHITE, BALLOONS[1] }, texture = "sparkle", size = { 0.4, 0 }, speed = { 1, 2 },
			life = { 0.6, 1 }, accel = V(0, -3, 0), glow = 1 })

		fx:sound(POP, "DeathBalloonPop", 0.1, function()
			return (bodyFrame(POP) * CFrame.new(offsets[2])).Position
		end)
		flash(fx, POP, function()
			return (bodyFrame(POP) * CFrame.new(offsets[2])).Position
		end, BALLOONS[2], 3.5, 0.2)
		fx:light(POP, 0.35, function()
			return (bodyFrame(POP) * CFrame.new(offsets[2])).Position
		end, BALLOONS[2], 14, 3)
		fx:burst(POP, function()
			return (bodyFrame(POP) * CFrame.new(offsets[2])).Position
		end, { count = 10, color = { BALLOONS[2], WHITE }, texture = "sparkle", size = { 0.45, 0 }, speed = { 6, 10 },
			life = { 0.3, 0.5 }, glow = 0.8 })
		fx:tween(2.3, 0.65, function(e)
			fx:bodyPose({ fade = e })
		end, Ease.quadIn)
	end,
}

--------------------------------------------------------------------------------
-- Uncommon
--------------------------------------------------------------------------------

-- A bat the size of a lamppost winds up behind them, swings, and flattens them. Stars.
Designs.KillBigBonk = {
	life = 2.4,
	peak = 0.52,
	moments = { 0.28, 0.5, 1.3 },
	view = { focus = V(6, 6, 3.3), radius = 12 },
	cues = { "DeathWhoosh", "DeathBonk" },
	build = function(fx)
		local g = fx.ground
		local LENGTH = 14
		local WIND, HIT = 0.3, 0.46
		-- The hinge the bat turns about, LENGTH from the spot, so it comes down ON the spot. It stands
		-- off their right side and a little behind (give or take; a character faces -Z, so its right
		-- is +X), so seen from the front the swing is side-on: the shop's stage camera, which looks
		-- at them from the front, sees the whole arc.
		local yaw = 2.65 + (fx.random:NextNumber() - 0.5) * 0.6
		local hinge = fx.pivot * CFrame.Angles(0, yaw, 0) * CFrame.new(-LENGTH, 1.2, 0)
		local pieces = {
			{ 0, fx:part(V(1.5, 1.5, 1.5), hinge, GRIP, SMOOTH, BALL) },
			{ 2.6, fx:part(V(5, 0.9, 0.9), hinge, GRIP, SMOOTH, CYLINDER) },
			{ 5.2, fx:part(V(0.5, 1.05, 1.05), hinge, TAPE, SMOOTH, CYLINDER) },
			{ 9.6, fx:part(V(9, 2.4, 2.4), hinge, BAT, WOOD, CYLINDER) },
		}
		-- The bat at `angle`: 0 is upright, pi/2 flat on the ground across the spot. Turning -angle
		-- about Z takes the hinge's +Y to its +X, which points at the spot.
		local function place(angle, lift)
			local bat = hinge * CFrame.new(0, lift or 0, 0) * CFrame.Angles(0, 0, -angle)
			for _, piece in ipairs(pieces) do
				if piece[2] then
					piece[2].CFrame = bat * CFrame.new(0, piece[1], 0) * UPRIGHT
				end
			end
		end
		place(0)

		-- Anticipation: the bat leans back while its shadow grows over them; they cower.
		local shadow = disc(fx, g + V(0, 0.05, 0), 0.5, rgb(20, 18, 24), SMOOTH, 0.6)
		fx:tween(0, HIT, function(e)
			if shadow then
				shadow.Size = V(0.1, 0.5 + 5 * e, 0.5 + 5 * e)
				shadow.Transparency = 0.6 - 0.25 * e
			end
		end, Ease.quadIn)
		fx:tween(0, WIND, function(e)
			place(-0.35 * e)
			fx:bodyPose({ scale = V(1 + 0.05 * e, 1 - 0.08 * e, 1 + 0.05 * e) })
		end, Ease.quadOut)
		fx:sound(WIND - 0.05, "DeathWhoosh", 0.1)
		fx:tween(WIND, HIT - WIND, function(e)
			place(-0.35 + (math.pi / 2 + 0.35) * e)
		end, Ease.quadIn)

		-- Burst: BONK. Pancake.
		fx:sound(HIT, "DeathBonk", 0.1)
		fx:tween(HIT, 0.14, function(e)
			fx:bodyPose({ scale = V(1.05 + 0.5 * e, 0.92 - 0.8 * e, 1.05 + 0.5 * e) })
		end, Ease.backOut)
		fx:burst(HIT, g + V(0, 0.5, 0), { count = 22, color = { DUST, rgb(150, 140, 120) }, texture = "smoke", size = { 1.2, 3 },
			speed = { 10, 16 }, life = { 0.5, 0.9 }, spread = 80, drag = 3, accel = V(0, 2, 0), glow = 0, fade = 0.25 })
		fx:burst(HIT, g + V(0, 2.4, 0), { count = 10, color = { STAR, WHITE }, texture = "sparkle", size = { 0.7, 0.1 },
			speed = { 8, 14 }, life = { 0.4, 0.7 }, glow = 1, accel = V(0, -10, 0) })
		shock(fx, HIT, g + V(0, 0.12, 0), WHITE, 2, 11, 0.35)
		fx:light(HIT, 0.3, g + V(0, 2, 0), WHITE, 16, 3)
		if shadow then
			fadeOut(fx, shadow, HIT, 0.2)
		end

		-- Follow-through: the bat bounces off and settles; stars circle the pancake.
		fx:tween(HIT, 0.5, function(_, raw)
			place(math.pi / 2 - 0.3 * math.sin(raw * math.pi) * (1 - raw) - 0.06 * (1 - raw))
		end)
		fx:at(HIT, function()
			for index = 1, 5 do
				local star = fx:part(V(0.8, 0.8, 0.2), CFrame.new(g + V(0, 1.4, 0)), STAR, NEON)
				if star then
					fx:tween(HIT, 1.5, function(e, raw)
						local angle = index / 5 * math.pi * 2 + raw * math.pi * 4
						local radius = 2.2 * Ease.backOut(math.min(1, raw * 4))
						local height = 1.2 + math.sin(raw * math.pi * 6 + index) * 0.2
						star.CFrame = CFrame.new(g + V(math.cos(angle) * radius, height, math.sin(angle) * radius))
							* CFrame.Angles(0, -angle, math.pi / 4 + raw * 6)
					end)
					fadeOut(fx, star, 1.65, 0.3)
				end
			end
		end)

		-- Settle: the bat lifts away; the pancake fades.
		fx:tween(1.4, 0.7, function(e)
			place(math.pi / 2 - 0.9 * e, 6 * e)
		end, Ease.quadIn)
		for _, piece in ipairs(pieces) do
			fadeOut(fx, piece[2], 1.7, 0.45)
		end
		fx:tween(1.8, 0.45, function(e)
			fx:bodyPose({ fade = e })
		end)
	end,
}

-- They shiver, go pale and sink away; their ghost pops out, waves, and drifts up with a trailing tail.
Designs.KillRotGhost = {
	life = 2.9,
	peak = 0.8,
	moments = { 0.25, 0.7, 1.9 },
	view = { focus = V(0, 6, 0), radius = 9 },
	cues = { "FloatAway", "DeathGhostWail" },
	build = function(fx)
		local pivot = fx.pivot
		local OUT = 0.35
		local chest = fx.origin + V(0, 0.8, 0)

		fx:tween(0, OUT, function(e, raw)
			fx:bodyPose({ to = pivot * CFrame.new(shiver(raw * OUT, 3) * 0.1 * e, 0, 0), scale = V(1, 1, 1),
				tint = GHOST, tintAlpha = 0.7 * e, fade = 0.35 * e })
		end, Ease.sineInOut)
		-- The body sinks into the ground and is gone.
		fx:tween(OUT, 0.9, function(e)
			fx:bodyPose({ to = pivot * CFrame.new(0, -3 * e, 0), scale = V(1, 1 - 0.3 * e, 1), fade = 0.35 + 0.65 * e })
		end, Ease.quadIn)

		-- The ghost, in its own frame: +Y up, facing where the body faced (-Z).
		local shape = {
			{ V(0, 0, 0), V(2.6, 2.6, 2.6), GHOST, BALL, 0.25 },
			{ V(0, -1.3, 0), V(2.2, 2.2, 2.2), GHOST, BALL, 0.3 },
			{ V(0.25, -2.3, 0.1), V(1.5, 1.5, 1.5), GHOST, BALL, 0.4 },
			{ V(0.6, -3.1, 0.2), V(0.9, 0.9, 0.9), GHOST, BALL, 0.5 },
			{ V(-1.35, -0.9, 0), V(0.8, 0.8, 0.8), GHOST, BALL, 0.3 },
			{ V(1.35, -0.9, 0), V(0.8, 0.8, 0.8), GHOST, BALL, 0.3 },
			{ V(-0.45, 0.25, -1.15), V(0.42, 0.62, 0.2), EYE, nil, 0 },
			{ V(0.45, 0.25, -1.15), V(0.42, 0.62, 0.2), EYE, nil, 0 },
			{ V(0, -0.45, -1.2), V(0.5, 0.5, 0.2), EYE, BALL, 0 },
		}
		local built = {}
		for index, piece in ipairs(shape) do
			local part = fx:part(V(0.05, 0.05, 0.05), CFrame.new(chest), piece[3], piece[4] and piece[3] == GHOST and NEON or SMOOTH, piece[4], 1)
			built[index] = { part = part, offset = piece[1], size = piece[2], base = piece[5] }
		end
		-- Where the ghost's centre is at time t (the tail pieces read it a little in the past, so they
		-- trail behind the turns like a real tail).
		local function centre(t)
			local climb = math.max(0, t - OUT)
			local grow = Ease.backOut(math.min(1, climb / 0.35))
			local height = 1 + climb * 3.6
			local sway = math.sin(climb * 4.2) * 0.9
			return pivot * CFrame.new(sway, chest.Y - fx.ground.Y + height, 0) * CFrame.Angles(0, 0, math.sin(climb * 4.2) * 0.15), grow
		end
		fx:tween(OUT, 2.9 - OUT, function(_, raw)
			local t = OUT + raw * (2.9 - OUT)
			for index, entry in ipairs(built) do
				local part = entry.part
				if part then
					local lag = index >= 3 and index <= 4 and (index - 2) * 0.09 or 0
					local frame, grow = centre(t - lag)
					local blink = (t > 1.3 and t < 1.42) and (index == 7 or index == 8) and 0.15 or 1
					local wave = 0
					if index == 5 then
						wave = math.sin(t * 9) * 0.35
					end
					part.Size = V(entry.size.X, entry.size.Y * blink, entry.size.Z) * math.max(0.05, grow)
					part.CFrame = frame * CFrame.new(entry.offset * math.max(0.05, grow) + V(0, wave, 0))
					local fade = math.clamp((t - 2.25) / 0.55, 0, 1)
					part.Transparency = entry.base + (1 - entry.base) * fade
				end
			end
		end)
		fx:sound(OUT, "FloatAway", 0.1)
		fx:sound(OUT + 0.15, "DeathGhostWail", 0.1)
		fx:burst(OUT, chest, { count = 14, color = { WHITE, GHOST_GLOW }, texture = "glow", size = { 0.8, 0 }, speed = { 3, 6 },
			life = { 0.5, 0.9 }, drag = 2, glow = 1 })
		fx:burst(1.1, function()
			return (centre(1.0)).Position - V(0, 2.4, 0)
		end, { count = 8, color = { GHOST_GLOW, WHITE }, texture = "sparkle", size = { 0.5, 0 }, speed = { 0.5, 1.5 },
			life = { 0.6, 1 }, accel = V(0, -1, 0), glow = 1 })
		fx:burst(1.7, function()
			return (centre(1.6)).Position - V(0, 2.4, 0)
		end, { count = 8, color = { GHOST_GLOW, WHITE }, texture = "sparkle", size = { 0.5, 0 }, speed = { 0.5, 1.5 },
			life = { 0.6, 1 }, accel = V(0, -1, 0), glow = 1 })
		fx:light(OUT, 2, built[1].part, GHOST_GLOW, 12, 2)
	end,
}

-- They darken to ink, bulge, and SPLAT: a puddle of ink with a splash crown and flung blobs.
Designs.KillInkSplat = {
	life = 2.7,
	peak = 0.45,
	moments = { 0.2, 0.42, 1.2 },
	view = { focus = V(0, 2.2, 0), radius = 8.5 },
	cues = { "DeathInkSplat" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local SPLAT = 0.3
		local chest = fx.origin + V(0, 0.4, 0)

		fx:tween(0, SPLAT, function(e, raw)
			local bulge = 1 + 0.14 * e + math.sin(raw * math.pi * 5) * 0.03
			fx:bodyPose({ scale = V(bulge, 1 - 0.08 * e, bulge), tint = INK, tintAlpha = e })
		end, Ease.quadIn)
		fx:sound(SPLAT, "DeathInkSplat", 0.1)
		fx:at(SPLAT, function()
			fx:hideBody()
		end)
		flash(fx, SPLAT, chest, INK_EDGE, 5, 0.18)
		fx:light(SPLAT, 0.4, chest, INK_EDGE, 14, 3)

		-- The splat itself: a glowing rim under an ink pool, both springing out.
		local rim = disc(fx, g + V(0, 0.05, 0), 0.4, INK_EDGE, NEON, 0.35, 0.08)
		local pool = disc(fx, g + V(0, 0.09, 0), 0.4, INK, SMOOTH, 0, 0.1)
		for _, part in ipairs({ rim, pool }) do
			part.Transparency = 1
		end
		fx:tween(SPLAT, 0.35, function(e)
			if pool then
				pool.Transparency = 0
				pool.Size = V(0.1, 0.4 + 7 * e, 0.4 + 7 * e)
			end
			if rim then
				rim.Transparency = 0.35
				rim.Size = V(0.08, 0.4 + 7.8 * e, 0.4 + 7.8 * e)
			end
		end, Ease.backOut)

		-- The crown: spikes of ink jump up round the edge and fall back.
		fx:at(SPLAT, function()
			for index = 1, 6 do
				local angle = index / 6 * math.pi * 2 + 0.3
				local base = g + V(math.cos(angle) * 2.4, 0, math.sin(angle) * 2.4)
				local lean = CFrame.Angles(0, -angle, 0) * CFrame.Angles(0, 0, -0.35)
				local spike = fx:part(V(0.5, 0.1, 0.5), CFrame.new(base) * lean, INK, SMOOTH)
				fx:tween(SPLAT, 0.55, function(_, raw)
					if spike then
						local height = math.sin(raw * math.pi) * (1.6 + (index % 3) * 0.5)
						spike.Size = V(0.5 - 0.25 * raw, math.max(0.1, height), 0.5 - 0.25 * raw)
						spike.CFrame = CFrame.new(base) * lean * CFrame.new(0, height / 2, 0)
					end
				end)
				fx:at(SPLAT + 0.56, function()
					if spike then
						spike.Transparency = 1
					end
				end)
			end
		end)

		-- Blobs flung out, landing and flattening into drops.
		fx:at(SPLAT, function()
			for index = 1, 7 do
				local angle = index / 7 * math.pi * 2 + fx.random:NextNumber() * 0.5
				local reach = 4 + fx.random:NextNumber() * 3
				local from = chest
				local to = g + V(math.cos(angle) * reach, 0.08, math.sin(angle) * reach)
				local size = 0.6 + fx.random:NextNumber() * 0.5
				local blob = fx:part(V(size, size, size), CFrame.new(from), index % 3 == 0 and INK_EDGE or INK,
					index % 3 == 0 and NEON or SMOOTH, BALL)
				local flight = 0.38 + index * 0.02
				fx:tween(SPLAT, flight, function(_, raw)
					if blob then
						local arc = math.sin(raw * math.pi) * (2 + index % 3)
						blob.CFrame = CFrame.new(from:Lerp(to, raw) + V(0, arc, 0))
					end
				end)
				fx:tween(SPLAT + flight, 0.2, function(e)
					if blob then
						blob.Shape = Enum.PartType.Cylinder
						blob.Size = V(0.12, size * (1 + 0.9 * e), size * (1 + 0.9 * e))
						blob.CFrame = CFrame.new(to) * UPRIGHT
					end
				end, Ease.backOut)
				fadeOut(fx, blob, 1.95 + index * 0.03, 0.45)
			end
		end)
		fx:burst(SPLAT, chest, { count = 20, color = { INK_EDGE, INK }, texture = "glow", size = { 0.6, 0.2 }, speed = { 12, 20 },
			life = { 0.4, 0.7 }, spread = 70, accel = V(0, -45, 0), glow = 0.4 })

		-- Follow-through: the rim pulses as the ink settles.
		fx:tween(SPLAT + 0.35, 1.3, function(_, raw)
			if rim then
				rim.Transparency = 0.35 + 0.25 * math.sin(raw * math.pi * 4) ^ 2
			end
		end)

		-- Settle: it all soaks away.
		fx:tween(2.0, 0.65, function(e)
			if pool then
				pool.Size = V(0.1, 7.4 - 5 * e, 7.4 - 5 * e)
				pool.Transparency = e
			end
			if rim then
				rim.Size = V(0.08, 8.2 - 5 * e, 8.2 - 5 * e)
				rim.Transparency = 0.35 + 0.65 * e
			end
		end, Ease.quadIn)
	end,
}

--------------------------------------------------------------------------------
-- Rare
--------------------------------------------------------------------------------

-- A target glows under them, a war drum drops out of the sky spinning, STAMPS them flat, bounces,
-- and leaves a burning ring of tiles.
Designs.KillDrumStamp = {
	life = 2.6,
	peak = 0.55,
	moments = { 0.4, 0.55, 1.3 },
	view = { focus = V(0, 4, 0), radius = 10 },
	cues = { "DeathWhoosh", "DeathDrumBoom" },
	build = function(fx)
		local g = fx.ground
		local LAND = 0.5
		local target = disc(fx, g + V(0, 0.05, 0), 0.5, STAMP, NEON, 0.5)
		fx:tween(0, LAND, function(e, raw)
			if target then
				target.Size = V(0.1, 0.5 + 5.5 * e, 0.5 + 5.5 * e)
				target.Transparency = 0.35 + 0.35 * math.sin(raw * math.pi * 6) ^ 2
			end
		end, Ease.quadOut)
		if target then
			fadeOut(fx, target, LAND, 0.15)
		end

		local pieces = {
			{ 0, fx:part(V(3.4, 5, 5), CFrame.new(g + V(0, 20, 0)), DRUM, WOOD, CYLINDER) },
			{ 1.72, fx:part(V(0.12, 4.8, 4.8), CFrame.new(g + V(0, 20, 0)), DRUM_HEAD, SMOOTH, CYLINDER) },
			{ 1.6, fx:part(V(0.4, 5.3, 5.3), CFrame.new(g + V(0, 20, 0)), RIM, SMOOTH, CYLINDER) },
			{ -1.6, fx:part(V(0.4, 5.3, 5.3), CFrame.new(g + V(0, 20, 0)), RIM, SMOOTH, CYLINDER) },
		}
		local function place(height, spin, wobble)
			local centre = CFrame.new(g + V(0, height, 0)) * CFrame.Angles(0, spin, 0) * CFrame.Angles(wobble or 0, 0, 0)
			for _, piece in ipairs(pieces) do
				if piece[2] then
					piece[2].CFrame = centre * CFrame.new(0, piece[1], 0) * UPRIGHT
				end
			end
		end
		-- Anticipation: down it comes, spinning; they shrink from it.
		fx:sound(0.05, "DeathWhoosh", 0.1)
		fx:tween(0, LAND, function(e, raw)
			place(1.9 + (1 - e) * 18, raw * math.pi * 3)
			fx:bodyPose({ scale = V(1 + 0.06 * e, 1 - 0.1 * e, 1 + 0.06 * e) })
		end, Ease.quadIn)

		-- Burst: stamped.
		fx:sound(LAND, "DeathDrumBoom", 0.08)
		fx:tween(LAND, 0.06, function(e)
			fx:bodyPose({ scale = V(1.06 + 0.6 * e, 0.9 - 0.82 * e, 1.06 + 0.6 * e) })
		end, Ease.quadOut)
		fx:burst(LAND, g + V(0, 0.4, 0), { count = 22, color = { DUST, rgb(160, 130, 100) }, texture = "smoke", size = { 1.4, 3.4 },
			speed = { 12, 18 }, life = { 0.6, 1 }, spread = 85, drag = 3, accel = V(0, 2, 0), glow = 0, fade = 0.25 })
		fx:burst(LAND, g + V(0, 0.3, 0), { count = 14, color = { EMBER, STAMP }, texture = "sparks", size = { 0.5, 0 },
			speed = { 14, 22 }, life = { 0.3, 0.6 }, spread = 80, accel = V(0, -30, 0), glow = 1 })
		shock(fx, LAND, g + V(0, 0.15, 0), STAMP, 3, 14, 0.4)
		fx:light(LAND, 0.45, g + V(0, 2, 0), STAMP, 20, 5)

		-- Follow-through: two bounces, the rims wobbling; a ring of tiles lights up round it.
		fx:tween(LAND, 0.6, function(_, raw)
			local bounce = math.abs(math.sin(raw * math.pi * 2)) * (1 - raw) * 2.4
			place(1.9 + bounce, math.pi * 3 + raw * 0.4, math.sin(raw * math.pi * 5) * 0.12 * (1 - raw))
		end)
		fx:at(LAND + 0.02, function()
			for index = 1, 10 do
				local angle = index / 10 * math.pi * 2
				local frame = CFrame.new(g + V(math.cos(angle) * 3.9, 0.07, math.sin(angle) * 3.9)) * CFrame.Angles(0, -angle, 0)
				local tile = fx:part(V(0.05, 0.12, 0.05), frame, STAMP, NEON)
				fx:tween(LAND + 0.02 + index * 0.02, 0.22, function(e)
					if tile then
						tile.Size = V(1.8 * e + 0.05, 0.12, 0.75 * e + 0.05)
					end
				end, Ease.backOut)
				fadeOut(fx, tile, 1.7, 0.7)
			end
		end)

		-- Settle: it lifts back into the sky; the pancake fades.
		fx:tween(1.3, 0.8, function(e)
			place(1.9 + 14 * e, math.pi * 3.4 - e * 2)
		end, Ease.quadIn)
		for _, piece in ipairs(pieces) do
			fadeOut(fx, piece[2], 1.75, 0.35)
		end
		fx:tween(1.6, 0.6, function(e)
			fx:bodyPose({ fade = e })
		end)
	end,
}

-- They turn to gold, shake, and burst into a fountain of spinning coins that bounce and settle.
Designs.KillCoinFountain = {
	life = 2.8,
	peak = 0.62,
	moments = { 0.28, 0.55, 1.4 },
	view = { focus = V(0, 5, 0), radius = 10 },
	cues = { "Gold", "GoldCrumble", "DeathCoinJingle" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local BURST = 0.42
		local chest = fx.origin + V(0, 0.8, 0)

		fx:sound(0, "Gold", 0.1)
		fx:tween(0, 0.25, function(e)
			fx:bodyPose({ tint = GOLD, tintAlpha = e })
		end, Ease.quadOut)
		fx:at(0.12, function()
			fx:bodyPose({ material = FOIL })
		end)
		fx:tween(0.12, BURST - 0.12, function(e, raw)
			local amount = 0.12 * e
			fx:bodyPose({ to = pivot * CFrame.new(shiver(raw, 4) * amount, 0, shiver(raw, 5) * amount), scale = V(1 + 0.08 * e, 1 + 0.04 * e, 1 + 0.08 * e) })
		end, Ease.quadIn)
		fx:light(0.05, BURST, chest, GOLD, 12, 1.5)

		fx:sound(BURST, "GoldCrumble", 0.15)
		fx:sound(BURST + 0.15, "DeathCoinJingle", 0.2)
		fx:at(BURST, function()
			fx:hideBody()
		end)
		flash(fx, BURST, chest, GOLD_PALE, 7, 0.3)
		fx:light(BURST, 0.5, chest, GOLD, 18, 5)
		fx:burst(BURST, chest, { count = 22, color = { GOLD_PALE, GOLD }, texture = "sparkle", size = { 0.6, 0.1 },
			speed = { 10, 18 }, life = { 0.6, 1.1 }, accel = V(0, -20, 0), drag = 1, glow = 1 })
		fx:burst(BURST + 0.1, chest + V(0, 2, 0), { count = 12, color = { WHITE, GOLD }, texture = "sparkle", size = { 0.35, 0 },
			speed = { 1, 3 }, life = { 1.2, 1.8 }, accel = V(0, -2, 0), glow = 1 })

		-- Coins: up and out, spinning, bouncing once, then lying flat and fading.
		fx:at(BURST, function()
			for index = 1, 16 do
				local angle = index * 2.4 + fx.random:NextNumber() * 0.3
				local spread = 3 + fx.random:NextNumber() * 4
				local velocity = V(math.cos(angle) * spread, 12 + fx.random:NextNumber() * 7, math.sin(angle) * spread)
				local coin = fx:part(V(0.2, 1.2, 1.2), CFrame.new(chest), GOLD, FOIL, CYLINDER)
				local delay = (index % 4) * 0.03
				local spin = 10 + fx.random:NextNumber() * 8
				if coin then
					coin.Reflectance = 0.3
					fx:tween(BURST + delay, 2.8 - BURST - delay, function(_, raw)
						local tau = raw * (2.8 - BURST - delay)
						local position, landed = hop(chest, velocity, 32, tau, g.Y + 0.12, 0.35)
						local turn = landed and CFrame.Angles(0, spin, math.pi / 2) or CFrame.Angles(tau * spin, tau * spin * 0.5, 0)
						coin.CFrame = CFrame.new(position) * turn
					end)
					fadeOut(fx, coin, 2.1 + index * 0.01, 0.45)
				end
			end
		end)
	end,
}

-- They glitch, and a scan line sweeps up them, deleting them into voxels that float away.
Designs.KillPixelDissolve = {
	life = 2.6,
	peak = 0.85,
	moments = { 0.2, 0.8, 1.6 },
	view = { focus = V(0, 3.8, 0), radius = 8 },
	cues = { "DeathGlitch" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local SCAN, TOP = 0.3, 1.5
		local height = 6.3

		fx:sound(0, "DeathGlitch", 0.1)
		-- Anticipation: flicker between themselves and a neon cyan copy, jittering sideways.
		fx:tween(0, SCAN, function(_, raw)
			local tick = math.floor(raw * SCAN * 30)
			local on = tick % 3 ~= 1
			fx:bodyPose({ to = pivot * CFrame.new(on and 0 or shiver(tick, 6) * 0.25, 0, 0), scale = V(1, 1, 1),
				tint = tick % 2 == 0 and CYAN or MAGENTA, tintAlpha = on and 0.2 or 0.9 })
		end)
		fx:at(SCAN, function()
			fx:bodyPose({ to = pivot, scale = V(1, 1, 1), tint = CYAN, tintAlpha = 0.35, material = NEON })
		end)

		-- The scan line.
		local plane = disc(fx, g + V(0, 0.1, 0), 4.2, CYAN, NEON, 0.45, 0.06)
		fx:tween(SCAN, TOP - SCAN, function(e)
			if plane then
				plane.CFrame = CFrame.new(g + V(0, 0.1 + height * e, 0)) * UPRIGHT
			end
		end)
		if plane then
			fadeOut(fx, plane, TOP, 0.25)
		end
		fx:sound(SCAN, "DeathGlitch", 0.2)
		fx:light(SCAN, TOP - SCAN, plane, CYAN, 12, 2)

		-- Each piece of the body goes as the line passes it: gone in a blink, leaving voxels.
		local pieces = fx:bodyPieces()
		if pieces then
			for _, piece in ipairs(pieces) do
				local when = SCAN + math.clamp(piece.height / height, 0, 1) * (TOP - SCAN)
				fx:tween(when - 0.05, 0.15, function(e)
					fx:fadePiece(piece, e)
					fx:tintPiece(piece, WHITE, e)
				end)
			end
		end
		fx:tween(TOP, 0.1, function(e)
			fx:bodyPose({ fade = 1 })
		end)
		fx:at(SCAN, function()
			for index = 1, 18 do
				local rise = (index - 1) / 17
				local when = SCAN + rise * (TOP - SCAN)
				local angle = index * 2.2
				local from = g + V(math.cos(angle) * 0.7 * fx.random:NextNumber(), 0.3 + rise * (height - 0.6), math.sin(angle) * 0.5)
				local drift = V(math.cos(angle) * (0.8 + fx.random:NextNumber() * 1.6), 2 + fx.random:NextNumber() * 2.2, math.sin(angle) * (0.8 + fx.random:NextNumber()))
				local size = 0.32 + (index % 3) * 0.1
				local color = ({ CYAN, MAGENTA, WHITE })[index % 3 + 1]
				local voxel = fx:part(V(size, size, size), CFrame.new(from), color, NEON, nil, 1)
				local span = 0.9
				fx:tween(when, span, function(e, raw)
					if voxel then
						local shrink = math.max(0.05, size * (1 - raw))
						voxel.Transparency = raw < 0.9 and 0.05 or 1
						voxel.Size = V(shrink, shrink, shrink)
						voxel.CFrame = CFrame.new(from + drift * e) * CFrame.Angles(raw * 3, raw * 4, 0)
					end
				end, Ease.quadOut)
			end
		end)
		fx:burst(SCAN, g + V(0, 1, 0), { count = 12, color = { CYAN, WHITE }, texture = "sparkle", size = { 0.5, 0 }, speed = { 3, 6 },
			life = { 0.4, 0.7 }, glow = 1 })
		fx:burst(0.9, g + V(0, 3.2, 0), { count = 14, color = { MAGENTA, CYAN }, texture = "sparkle", size = { 0.5, 0 }, speed = { 3, 6 },
			life = { 0.4, 0.8 }, glow = 1 })
		fx:burst(TOP - 0.05, g + V(0, height, 0), { count = 12, color = { WHITE, CYAN }, texture = "sparkle", size = { 0.6, 0 },
			speed = { 4, 8 }, life = { 0.4, 0.8 }, glow = 1 })
	end,
}

--------------------------------------------------------------------------------
-- Epic
--------------------------------------------------------------------------------

-- A brain swells out of their head, throbbing faster and faster while they flush pink and inflate,
-- then POPS: two shockwaves, a pink flash, and chunks raining down.
Designs.KillBrainBlast = {
	life = 2.8,
	peak = 1.0,
	moments = { 0.55, 0.98, 1.6 },
	view = { focus = V(0, 5.5, 0), radius = 11 },
	cues = { "DeathBrainSwell", "Vaporize" },
	build = function(fx)
		local g = fx.ground
		local POP = 0.95
		local centre = fx.origin + V(0, 3.4, 0)

		fx:sound(0, "DeathBrainSwell", 0.05)
		fx:tween(0, POP, function(e)
			fx:bodyPose({ scale = V(1 + 0.2 * e, 1 + 0.08 * e, 1 + 0.2 * e), tint = BRAIN_HOT, tintAlpha = 0.65 * e })
		end, Ease.quadIn)
		fx:light(0.1, POP, centre, BRAIN_HOT, 16, 2.5)
		fx:burst(0.25, centre, { count = 14, color = { BRAIN, WHITE }, texture = "glow", size = { 0.6, 0.1 }, life = { 0.5, 0.65 },
			inward = 6, glow = 1 })

		local lobes = {
			fx:part(V(0.4, 0.4, 0.4), CFrame.new(centre), BRAIN, SMOOTH, BALL),
			fx:part(V(0.4, 0.4, 0.4), CFrame.new(centre), BRAIN, SMOOTH, BALL),
		}
		local folds = {
			fx:part(V(0.2, 0.2, 0.2), CFrame.new(centre), BRAIN_DARK, NEON),
			fx:part(V(0.2, 0.2, 0.2), CFrame.new(centre), BRAIN_DARK, NEON),
		}
		local stem = fx:part(V(0.4, 0.3, 0.3), CFrame.new(centre), BRAIN_DARK, SMOOTH, CYLINDER)
		-- Anticipation: it grows and throbs, the throb speeding up as it nears the pop.
		fx:tween(0, POP, function(e, raw)
			local size = 0.6 + e * 5
			local throb = 1 + math.sin(raw * raw * math.pi * 14) * 0.07 * raw
			for side, lobe in ipairs(lobes) do
				if lobe then
					lobe.Size = V(size * 0.6 * throb, size * 0.72, size * throb)
					lobe.CFrame = CFrame.new(centre + V((side == 1 and -1 or 1) * size * 0.26, 0, 0))
				end
				local fold = folds[side]
				if fold then
					fold.Size = V(size * 0.08, size * 0.08, size * 0.85 * throb)
					fold.CFrame = CFrame.new(centre + V((side == 1 and -1 or 1) * size * 0.26, size * 0.33, 0))
				end
			end
			if stem then
				stem.Size = V(size * 0.5, size * 0.22, size * 0.22)
				stem.CFrame = CFrame.new(centre - V(0, size * 0.45, 0)) * UPRIGHT
			end
		end, Ease.sineInOut)

		-- Burst.
		fx:sound(POP, "Vaporize", 0.1)
		fx:at(POP, function()
			fx:hideBody()
			for _, part in ipairs({ lobes[1], lobes[2], folds[1], folds[2], stem }) do
				part.Transparency = 1
			end
		end)
		flash(fx, POP, centre, rgb(255, 214, 230), 13, 0.35)
		fx:light(POP, 0.6, centre, BRAIN_HOT, 26, 8)
		shock(fx, POP, centre, BRAIN_HOT, 2, 24, 0.5)
		shock(fx, POP + 0.06, centre, BRAIN, 2, 16, 0.55, CFrame.Angles(math.pi / 2, 0, 0))
		fx:burst(POP, centre, { count = 22, color = { BRAIN_HOT, WHITE }, texture = "sparkle", size = { 0.8, 0.1 }, speed = { 16, 26 },
			life = { 0.5, 1 }, drag = 1.5, accel = V(0, -10, 0), glow = 1 })
		fx:burst(POP + 0.05, centre, { count = 14, color = { BRAIN, rgb(200, 120, 150) }, texture = "smoke", size = { 2, 4.5 },
			speed = { 4, 8 }, life = { 0.9, 1.4 }, drag = 2, glow = 0.2, fade = 0.4 })

		-- Follow-through: chunks of brain fly out, drop and bounce.
		fx:at(POP, function()
			for index = 1, 10 do
				local angle = index / 10 * math.pi * 2 + fx.random:NextNumber() * 0.4
				local velocity = V(math.cos(angle) * (8 + fx.random:NextNumber() * 5), 8 + fx.random:NextNumber() * 8, math.sin(angle) * (8 + fx.random:NextNumber() * 5))
				local size = 0.7 + fx.random:NextNumber() * 0.5
				local chunk = fx:part(V(size, size * 0.8, size), CFrame.new(centre), index % 2 == 0 and BRAIN or BRAIN_DARK, SMOOTH, BALL)
				fx:tween(POP, 2.8 - POP, function(_, raw)
					if chunk then
						local tau = raw * (2.8 - POP)
						local position, _ = hop(centre, velocity, 36, tau, g.Y + size * 0.4, 0.3)
						chunk.CFrame = CFrame.new(position)
					end
				end)
				fadeOut(fx, chunk, 2.1 + index * 0.02, 0.45)
			end
		end)
	end,
}

-- Storm clouds gather over them; lightning strikes, they flash white to the bone and char black,
-- smoke, a second smaller bolt, and they crumble to ash.
Designs.KillLightningSmite = {
	life = 3.0,
	peak = 0.62,
	moments = { 0.35, 0.6, 1.6 },
	view = { focus = V(0, 6.5, 0), radius = 11 },
	cues = { "DeathThunder", "Shock" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local STRIKE = 0.55
		local sky = g + V(0, 13, 0)
		local head = fx.origin + V(0, 2.2, 0)

		-- Anticipation: the cloud gathers and churns, crackling, and they look up.
		local puffs = {}
		for index = 1, 4 do
			local offset = V(math.cos(index * 1.7) * 2.2, (index % 2) * 0.6, math.sin(index * 1.7) * 1.6)
			local puff = fx:part(V(0.05, 0.05, 0.05), CFrame.new(sky + offset), index % 2 == 0 and STORM or STORM_LIGHT, SMOOTH, BALL, 0.1)
			puffs[index] = { part = puff, offset = offset, size = 3.4 + (index % 3) * 0.9 }
		end
		fx:tween(0, 3.0, function(_, raw)
			local t = raw * 3
			local grow = Ease.quadOut(math.min(1, t / 0.5))
			local fade = math.clamp((t - 2.1) / 0.8, 0, 1)
			for index, entry in ipairs(puffs) do
				if entry.part then
					local d = entry.size * grow * (1 + fade * 0.5)
					entry.part.Size = V(d, d * 0.7, d)
					entry.part.CFrame = CFrame.new(sky + entry.offset + V(math.sin(t * 2 + index) * 0.4, 0, math.cos(t * 1.7 + index) * 0.3))
					entry.part.Transparency = 0.1 + 0.9 * fade
				end
			end
		end)
		fx:burst(0.3, sky, { count = 6, color = { BOLT, CYAN }, texture = "sparks", size = { 0.4, 0 }, speed = { 4, 8 },
			life = { 0.15, 0.3 }, glow = 1 })
		fx:tween(0, STRIKE, function(e)
			fx:bodyPose({ tint = BOLT, tintAlpha = 0.3 * e })
		end)

		-- The bolt: six jagged segments from the cloud to the head.
		local segments = {}
		for index = 1, 6 do
			segments[index] = fx:part(V(0.35, 0.35, 1), CFrame.new(sky), BOLT, NEON, nil, 1)
		end
		local function strike(seed, from, to, width)
			local points = { from }
			for index = 1, 5 do
				local along = from:Lerp(to, index / 6)
				local kink = V(math.sin(seed * 7.1 + index * 3.3) * 1.3, 0, math.cos(seed * 5.3 + index * 2.1) * 1.3)
				table.insert(points, along + kink)
			end
			table.insert(points, to)
			for index, segment in ipairs(segments) do
				if segment then
					local a, b = points[index], points[index + 1]
					segment.Size = V(width, width, (b - a).Magnitude + width)
					segment.CFrame = CFrame.lookAt((a + b) / 2, b)
				end
			end
		end
		local function flicker(t0, duration)
			fx:tween(t0, duration, function(_, raw)
				for _, segment in ipairs(segments) do
					if segment then
						segment.Transparency = raw >= 1 and 1 or (math.floor(raw * 8) % 2 == 0 and 0 or 0.5)
					end
				end
			end)
		end
		fx:at(STRIKE, function()
			strike(1, sky, head, 0.45)
		end)
		flicker(STRIKE, 0.3)
		fx:at(0.85, function()
			strike(2, sky + V(1.5, 0, -1), g + V(1.2, 0, 0.8), 0.25)
		end)
		flicker(0.85, 0.14)

		-- Burst: the strike.
		fx:sound(STRIKE, "DeathThunder", 0.08)
		fx:sound(STRIKE + 0.05, "Shock", 0.2)
		flash(fx, STRIKE, head, BOLT, 9, 0.25)
		fx:light(STRIKE, 0.4, head, BOLT, 30, 10)
		shock(fx, STRIKE, g + V(0, 0.12, 0), BOLT, 2, 12, 0.3)
		-- White to the bone for a blink, then charred.
		fx:tween(STRIKE, 0.2, function(_, raw)
			if raw < 0.4 then
				fx:bodyPose({ tint = WHITE, tintAlpha = 1, material = NEON })
			else
				fx:bodyPose({ tint = CHAR, tintAlpha = 1, material = SLATE })
			end
		end)
		fx:burst(STRIKE, head, { count = 24, color = { WHITE, BOLT, CYAN }, texture = "sparks", size = { 0.5, 0 }, speed = { 16, 26 },
			life = { 0.3, 0.6 }, accel = V(0, -30, 0), glow = 1 })
		fx:burst(0.8, fx.origin, { count = 12, color = { rgb(70, 66, 62), rgb(40, 40, 40) }, texture = "smoke", size = { 1, 3 },
			speed = { 2, 4 }, life = { 1, 1.5 }, spread = 25, accel = V(0, 3, 0), glow = 0, fade = 0.35 })

		-- Follow-through: they twitch; then crumble into ash.
		fx:tween(STRIKE + 0.1, 0.5, function(_, raw)
			local twitch = math.floor(raw * 10) % 2 == 0 and 0.1 or -0.1
			fx:bodyPose({ to = pivot * CFrame.Angles(0, 0, twitch * (1 - raw)), scale = V(1, 1, 1) })
		end)
		fx:tween(1.25, 0.85, function(e)
			fx:bodyPose({ to = pivot, scale = V(1 + 0.25 * e, 1 - 0.75 * e, 1 + 0.25 * e), tint = CHAR:Lerp(ASH, e), tintAlpha = 1 })
		end, Ease.quadIn)
		fx:tween(1.8, 0.45, function(e)
			fx:bodyPose({ fade = e })
		end)
		fx:burst(1.3, fx.origin, { count = 14, color = { ASH, rgb(60, 58, 56) }, texture = "smoke", size = { 0.8, 2 }, speed = { 1, 3 },
			life = { 0.8, 1.3 }, accel = V(2, 2, 0), drag = 1, glow = 0, fade = 0.3 })
	end,
}

--------------------------------------------------------------------------------
-- Legendary (crate exclusives)
--------------------------------------------------------------------------------

-- Crystals grow up round them and freeze them solid, glowing; then the whole lot SHATTERS into
-- glittering shards that skitter across the ground.
Designs.KillCrystalShatter = {
	life = 2.9,
	peak = 0.86,
	moments = { 0.45, 0.85, 1.6 },
	view = { focus = V(0, 3.4, 0), radius = 9 },
	cues = { "Freeze", "Shatter" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local BREAK = 0.8
		local chest = fx.origin + V(0, 0.6, 0)

		fx:sound(0, "Freeze", 0.1)
		fx:tween(0.15, 0.45, function(e)
			fx:bodyPose({ tint = ICE, tintAlpha = e, fade = 0.25 * e })
		end, Ease.sineInOut)
		fx:at(0.3, function()
			fx:bodyPose({ material = GLASS })
		end)
		fx:light(0.1, BREAK, chest, ICE, 14, 2.5)
		fx:burst(0.2, chest, { count = 12, color = { ICE_WHITE, ICE }, texture = "sparkle", size = { 0.4, 0 }, speed = { 2, 4 },
			life = { 0.5, 0.8 }, glow = 1 })

		-- Anticipation: spikes grow out of the ground round their feet, leaning in to encase them.
		local spikes = {}
		for index = 1, 7 do
			local angle = index / 7 * math.pi * 2
			local base = g + V(math.cos(angle) * 1.5, 0, math.sin(angle) * 1.5)
			local tall = 3.2 + (index % 3) * 1.1
			local lean = CFrame.Angles(0, -angle, 0) * CFrame.Angles(0, 0, 0.32 + (index % 2) * 0.1)
			local spike = fx:part(V(0.9, 0.05, 0.9), CFrame.new(base) * lean, index % 2 == 0 and ICE or ICE_WHITE, GLASS, nil, 0.3)
			spikes[index] = spike
			fx:tween(0.05 + index * 0.06, 0.4, function(e)
				if spike then
					local h = math.max(0.05, tall * e)
					spike.Size = V(0.9 - 0.2 * e, h, 0.9 - 0.2 * e)
					spike.CFrame = CFrame.new(base) * lean * CFrame.new(0, h / 2, 0) * CFrame.Angles(0, index, 0)
				end
			end, Ease.backOut)
		end

		-- Burst: shatter.
		fx:sound(BREAK, "Shatter", 0.15)
		fx:at(BREAK, function()
			fx:hideBody()
			for _, spike in ipairs(spikes) do
				spike.Transparency = 1
			end
		end)
		flash(fx, BREAK, chest, ICE_WHITE, 8, 0.25)
		fx:light(BREAK, 0.5, chest, ICE, 22, 7)
		shock(fx, BREAK, g + V(0, 0.12, 0), ICE, 2, 12, 0.4)
		fx:burst(BREAK, chest, { count = 26, color = { WHITE, ICE }, texture = "sparkle", size = { 0.6, 0.1 }, speed = { 12, 22 },
			life = { 0.5, 1 }, drag = 1, accel = V(0, -18, 0), glow = 1 })

		-- Follow-through: shards fly, tumble, bounce, skitter.
		fx:at(BREAK, function()
			for index = 1, 14 do
				local angle = index / 14 * math.pi * 2 + fx.random:NextNumber() * 0.3
				local from = pivot * CFrame.new(math.cos(angle) * 0.6, 1 + (index % 5) * 1, math.sin(angle) * 0.4)
				local velocity = V(math.cos(angle) * (7 + fx.random:NextNumber() * 6), 5 + fx.random:NextNumber() * 8, math.sin(angle) * (7 + fx.random:NextNumber() * 6))
				local size = V(0.35 + fx.random:NextNumber() * 0.4, 0.8 + fx.random:NextNumber() * 0.9, 0.3)
				local shard = fx:part(size, from, index % 3 == 0 and ICE_WHITE or ICE, GLASS, nil, 0.2)
				local tumble = V(fx.random:NextNumber() * 12, fx.random:NextNumber() * 12, fx.random:NextNumber() * 12)
				if shard then
					shard.Reflectance = 0.3
					fx:tween(BREAK, 2.9 - BREAK, function(_, raw)
						local tau = raw * (2.9 - BREAK)
						local position, landed = hop(from.Position, velocity, 34, tau, g.Y + size.Y * 0.15, 0.3)
						local spin = math.min(tau, landed and 0.6 or tau)
						shard.CFrame = CFrame.new(position) * CFrame.Angles(tumble.X * spin, tumble.Y * spin, landed and math.pi / 2 or tumble.Z * spin)
					end)
					fadeOut(fx, shard, 2.1 + index * 0.02, 0.5)
				end
			end
		end)
		fx:burst(1.2, g + V(0, 0.5, 0), { count = 12, color = { ICE_WHITE, ICE }, texture = "sparkle", size = { 0.35, 0 },
			speed = { 1, 2 }, life = { 0.8, 1.3 }, spread = 60, glow = 1 })
	end,
}

-- A swirl of rot opens under them and winds up into a funnel that lifts them, spinning and
-- shrinking, into itself; the funnel collapses upward with a pop.
Designs.KillRotVortex = {
	life = 3.0,
	peak = 1.15,
	moments = { 0.45, 1.1, 2.1 },
	view = { focus = V(0, 6, 0), radius = 11 },
	cues = { "DeathVortex", "Vaporize" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local LIFT, GONE, POP = 0.5, 1.7, 2.05
		local top = g + V(0, 11, 0)

		fx:sound(0, "DeathVortex", 0.05)
		-- The ground swirl.
		local swirls = {}
		for index = 1, 3 do
			swirls[index] = disc(fx, g + V(0, 0.05 + index * 0.02, 0), 0.4, ({ ROT, ROT_DARK, GOO_GLOW })[index], index == 3 and NEON or SMOOTH, 0.45)
		end
		fx:tween(0, 3.0, function(_, raw)
			local t = raw * 3
			local grow = Ease.backOut(math.min(1, t / 0.6))
			local shrink = math.clamp((t - GONE) / 0.4, 0, 1)
			for index, swirl in ipairs(swirls) do
				if swirl then
					local d = (7.5 - index * 1.6) * grow * (1 - 0.8 * shrink)
					local wobble = V(math.cos(t * (5 + index) + index) * 0.4, 0, math.sin(t * (5 + index) + index) * 0.4)
					swirl.Size = V(0.1, math.max(0.1, d), math.max(0.1, d))
					swirl.CFrame = CFrame.new(g + V(0, 0.05 + index * 0.02, 0) + wobble) * UPRIGHT
					swirl.Transparency = 0.45 + 0.55 * math.clamp((t - POP) / 0.7, 0, 1)
				end
			end
		end)

		-- The funnel: rings stacked up to the sky, each wobbling round its own axis.
		local rings = {}
		for index = 1, 6 do
			rings[index] = fx:part(V(0.14, 0.1, 0.1), CFrame.new(g), index % 2 == 0 and ROT or GOO_GLOW, NEON, CYLINDER, 0.55)
		end
		local function ringAt(index, t)
			local rise = index / 6
			local grow = Ease.backOut(math.clamp((t - LIFT - index * 0.05) / 0.35, 0, 1))
			local collapse = Ease.quadIn(math.clamp((t - GONE) / (POP - GONE), 0, 1))
			local height = 0.6 + rise * 10
			local d = (1.6 + rise * 7) * grow * (1 - collapse)
			local position = g + V(math.cos(t * 7 + index) * 0.5 * rise, height + (top.Y - g.Y - height) * collapse, math.sin(t * 7 + index) * 0.5 * rise)
			return CFrame.new(position) * CFrame.Angles(math.sin(t * 3 + index) * 0.12, 0, 0) * UPRIGHT, d
		end
		fx:tween(LIFT, POP - LIFT, function(_, raw)
			local t = LIFT + raw * (POP - LIFT)
			for index, ring in ipairs(rings) do
				if ring then
					local frame, d = ringAt(index, t)
					ring.CFrame = frame
					ring.Size = V(0.14, math.max(0.1, d), math.max(0.1, d))
					ring.Transparency = raw >= 1 and 1 or 0.55
				end
			end
		end)

		-- The body: tint, then up the funnel, spinning faster and shrinking away.
		fx:tween(0, LIFT, function(e)
			fx:bodyPose({ tint = ROT, tintAlpha = 0.5 * e })
		end)
		fx:tween(LIFT, GONE - LIFT, function(e, raw)
			local spin = raw * raw * math.pi * 7
			local s = 1 - 0.85 * e
			fx:bodyPose({ to = pivot * CFrame.new(0, 7 * e, 0) * CFrame.Angles(0, spin, math.sin(raw * math.pi) * 0.4),
				scale = V(s, s, s), fade = math.clamp((raw - 0.7) / 0.3, 0, 1) })
		end, Ease.quadIn)

		-- Debris spiralling up the funnel.
		fx:at(LIFT, function()
			for index = 1, 8 do
				local size = 0.4 + (index % 3) * 0.2
				local chunk = fx:part(V(size, size, size), CFrame.new(g), index % 2 == 0 and MUD or ROT_DARK, SMOOTH, index % 3 == 0 and BALL or nil)
				local phase = index / 8 * math.pi * 2
				fx:tween(LIFT + index * 0.04, 1.4, function(e, raw)
					if chunk then
						local angle = phase + raw * math.pi * 5
						local radius = 4.5 * (1 - e) + 0.6
						chunk.CFrame = CFrame.new(g + V(math.cos(angle) * radius, 0.4 + e * 9, math.sin(angle) * radius)) * CFrame.Angles(raw * 7, raw * 5, 0)
						chunk.Transparency = raw >= 0.97 and 1 or 0
					end
				end, Ease.quadIn)
			end
		end)
		fx:burst(0.2, g + V(0, 0.4, 0), { count = 10, color = { ROT, GOO_GLOW }, texture = "smoke", size = { 1, 2.4 }, speed = { 2, 4 },
			life = { 0.8, 1.2 }, spread = 70, accel = V(0, 3, 0), glow = 0.2, fade = 0.4 })
		fx:light(LIFT, POP - LIFT, g + V(0, 4, 0), GOO_GLOW, 20, 3)

		-- Burst at the top: the funnel pops.
		fx:sound(POP, "Vaporize", 0.15, top)
		flash(fx, POP, top, GOO_GLOW, 9, 0.3)
		fx:light(POP, 0.5, top, GOO_GLOW, 26, 7)
		fx:burst(POP, top, { count = 20, color = { GOO_GLOW, WHITE }, texture = "sparkle", size = { 0.7, 0.1 }, speed = { 10, 18 },
			life = { 0.5, 0.85 }, accel = V(0, -14, 0), glow = 1 })
		fx:burst(POP + 0.05, top, { count = 10, color = { ROT, rgb(120, 150, 100) }, texture = "smoke", size = { 2, 4 }, speed = { 3, 5 },
			life = { 0.7, 0.85 }, drag = 2, glow = 0, fade = 0.45 })
	end,
}

--------------------------------------------------------------------------------
-- Mythic (crate exclusive)
--------------------------------------------------------------------------------

-- A target glows under them and a burning brainrot meteor streaks down out of the sky: a huge flash,
-- two shockwaves, a glowing crater, flying rock, fire and smoke.
Designs.KillMeteorStrike = {
	life = 3.2,
	peak = 0.95,
	moments = { 0.78, 0.92, 1.8 },
	view = { focus = V(0, 5, 0), radius = 13 },
	cues = { "DeathMeteorFall", "DeathMeteorImpact" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local FALL, IMPACT = 0.1, 0.85
		-- In from behind them and off to their right, give or take, so from the front (the shop's stage
		-- camera) it streaks across the sky rather than straight down the lens.
		local heading = 0.49 + (fx.random:NextNumber() - 0.5) * 0.6
		local start = (pivot * CFrame.new(math.cos(heading) * 30, 55, math.sin(heading) * 30)).Position
		local finish = g + V(0, 1.5, 0)
		local function path(t)
			local e = Ease.quadIn(math.clamp((t - FALL) / (IMPACT - FALL), 0, 1))
			return start:Lerp(finish, e)
		end

		-- Anticipation: the target, the meteor coming, them glowing in its light.
		local target = disc(fx, g + V(0, 0.05, 0), 0.5, MAGMA, NEON, 0.5)
		fx:tween(0, IMPACT, function(e, raw)
			if target then
				target.Size = V(0.1, 0.5 + 6.5 * e, 0.5 + 6.5 * e)
				target.Transparency = 0.3 + 0.4 * math.sin(raw * math.pi * 7) ^ 2
			end
		end, Ease.quadOut)
		fx:tween(0.3, IMPACT - 0.3, function(e)
			fx:bodyPose({ tint = MAGMA, tintAlpha = 0.45 * e })
		end, Ease.quadIn)
		fx:sound(FALL, "DeathMeteorFall", 0.05)
		local rock = fx:part(V(3.2, 3.2, 3.2), CFrame.new(start), ROCK, BASALT, BALL)
		local shell = fx:part(V(3.8, 3.8, 3.8), CFrame.new(start), MAGMA, NEON, BALL, 0.45)
		local trail = {}
		for index = 1, 3 do
			local d = 3.2 - index * 0.7
			trail[index] = { part = fx:part(V(d, d, d), CFrame.new(start), index == 1 and MAGMA or EMBER, NEON, BALL, 0.3 + index * 0.15), lag = index * 0.035 }
		end
		fx:tween(0, IMPACT, function(_, raw)
			local t = raw * IMPACT
			local visible = t >= FALL
			if rock then
				rock.CFrame = CFrame.new(path(t)) * CFrame.Angles(t * 5, t * 3, 0)
				rock.Transparency = visible and 0 or 1
			end
			if shell then
				shell.CFrame = CFrame.new(path(t))
				shell.Transparency = visible and 0.45 or 1
			end
			for index, entry in ipairs(trail) do
				if entry.part then
					entry.part.CFrame = CFrame.new(path(t - entry.lag))
					entry.part.Transparency = visible and (0.3 + index * 0.15) or 1
				end
			end
		end)
		fx:light(FALL, IMPACT - FALL, shell, MAGMA, 22, 4)
		if target then
			fadeOut(fx, target, IMPACT, 0.1)
		end

		-- Burst: impact.
		fx:sound(IMPACT, "DeathMeteorImpact", 0.08, g)
		fx:at(IMPACT, function()
			fx:hideBody()
			for _, part in ipairs({ rock, shell, trail[1].part, trail[2].part, trail[3].part }) do
				part.Transparency = 1
			end
		end)
		flash(fx, IMPACT, g + V(0, 2, 0), rgb(255, 230, 180), 16, 0.35)
		fx:light(IMPACT, 0.7, g + V(0, 3, 0), MAGMA, 34, 12)
		shock(fx, IMPACT, g + V(0, 0.2, 0), EMBER, 2, 26, 0.4)
		shock(fx, IMPACT + 0.08, g + V(0, 0.25, 0), MAGMA, 2, 14, 0.7)
		fx:burst(IMPACT, g + V(0, 1, 0), { count = 24, color = { EMBER, MAGMA }, texture = "sparks", size = { 0.6, 0 },
			speed = { 18, 30 }, life = { 0.5, 1 }, spread = 70, accel = V(0, -30, 0), glow = 1 })
		fx:burst(IMPACT + 0.03, g + V(0, 0.8, 0), { count = 14, color = { EMBER, MAGMA, rgb(120, 40, 20) }, texture = "fire",
			size = { 2, 0.5 }, speed = { 4, 9 }, life = { 0.5, 0.9 }, spread = 45, accel = V(0, 6, 0), glow = 1 })
		fx:burst(IMPACT + 0.1, g + V(0, 1.5, 0), { count = 14, color = { rgb(90, 80, 74), rgb(40, 38, 36) }, texture = "smoke",
			size = { 2.5, 6 }, speed = { 3, 7 }, life = { 1.2, 2 }, spread = 60, drag = 1.5, accel = V(0, 2, 0), glow = 0, fade = 0.3 })

		-- The crater: a scorched pit in a molten rim that cools.
		local rim = disc(fx, g + V(0, 0.06, 0), 0.5, MAGMA, NEON, 1, 0.1)
		local pit = disc(fx, g + V(0, 0.1, 0), 0.5, SCORCH, BASALT, 1, 0.12)
		fx:tween(IMPACT, 0.3, function(e)
			if rim then
				rim.Transparency = 0.1
				rim.Size = V(0.1, 0.5 + 10 * e, 0.5 + 10 * e)
			end
			if pit then
				pit.Transparency = 0
				pit.Size = V(0.12, 0.5 + 8 * e, 0.5 + 8 * e)
			end
		end, Ease.backOut)
		fx:tween(IMPACT + 0.3, 2.4 - IMPACT, function(e)
			if rim then
				rim.Color = MAGMA:Lerp(rgb(90, 20, 10), e)
			end
		end)
		fx:tween(2.5, 0.65, function(e)
			if rim then
				rim.Transparency = 0.1 + 0.9 * e
			end
			if pit then
				pit.Transparency = e
			end
		end, Ease.quadIn)

		-- Rocks thrown out of the crater.
		fx:at(IMPACT, function()
			for index = 1, 8 do
				local angle = index / 8 * math.pi * 2 + fx.random:NextNumber() * 0.4
				local velocity = V(math.cos(angle) * (9 + fx.random:NextNumber() * 7), 10 + fx.random:NextNumber() * 9, math.sin(angle) * (9 + fx.random:NextNumber() * 7))
				local size = 0.8 + fx.random:NextNumber() * 0.8
				local from = g + V(0, 0.8, 0)
				local chunk = fx:part(V(size, size * 0.8, size), CFrame.new(from), index % 3 == 0 and MAGMA or ROCK, index % 3 == 0 and NEON or BASALT)
				local spin = V(fx.random:NextNumber() * 8, fx.random:NextNumber() * 8, 0)
				fx:tween(IMPACT, 3.2 - IMPACT, function(_, raw)
					if chunk then
						local tau = raw * (3.2 - IMPACT)
						local position, landed = hop(from, velocity, 38, tau, g.Y + size * 0.4, 0.25)
						local turn = math.min(tau, landed and 0.9 or tau)
						chunk.CFrame = CFrame.new(position) * CFrame.Angles(spin.X * turn, spin.Y * turn, 0)
					end
				end)
				fadeOut(fx, chunk, 2.5 + index * 0.02, 0.5)
			end
		end)
	end,
}

--------------------------------------------------------------------------------
-- Secret (crate exclusive)
--------------------------------------------------------------------------------

-- A pinprick of nothing opens above them with a spinning accretion disc. It pulls them in, stretched
-- and spinning, swallows the ground around them, collapses to a point, and goes off like a star.
Designs.KillBlackHole = {
	life = 3.2,
	peak = 1.2,
	moments = { 0.5, 1.2, 2.2 },
	view = { focus = V(0, 5.5, 0), radius = 11 },
	cues = { "DeathSingularity", "Vaporize" },
	build = function(fx)
		local g, pivot = fx.ground, fx.pivot
		local OPEN, PULL, GONE, POP = 0.6, 0.6, 1.7, 2.0
		local centre = g + V(0, 8, 0)
		local tilt = CFrame.Angles(math.rad(18), 0, math.rad(10))

		fx:sound(0, "DeathSingularity", 0.05)
		local hole = fx:part(V(0.05, 0.05, 0.05), CFrame.new(centre), VOID, SMOOTH, BALL)
		local halo = fx:part(V(0.05, 0.05, 0.05), CFrame.new(centre), VIOLET, NEON, BALL, 0.75)
		local discs = {
			fx:part(V(0.08, 0.1, 0.1), CFrame.new(centre) * tilt * UPRIGHT, VIOLET, NEON, CYLINDER, 0.35),
			fx:part(V(0.06, 0.1, 0.1), CFrame.new(centre) * tilt * UPRIGHT, ORCHID, NEON, CYLINDER, 0.55),
		}
		local clumps = {}
		for index = 1, 4 do
			clumps[index] = fx:part(V(0.4, 0.4, 0.4), CFrame.new(centre), index % 2 == 0 and WHITE or ORCHID, NEON, BALL)
		end
		-- The hole's size at t: opens, holds and throbs, then collapses to nothing before the pop.
		local function scaleAt(t)
			local open = Ease.backOut(math.clamp(t / OPEN, 0, 1))
			local collapse = Ease.quadIn(math.clamp((t - GONE) / (POP - GONE), 0, 1))
			return open * (1 - collapse) * (1 + math.sin(t * 9) * 0.05)
		end
		fx:tween(0, POP, function(_, raw)
			local t = raw * POP
			local s = scaleAt(t)
			local done = raw >= 1
			if hole then
				local d = math.max(0.05, 2.2 * s)
				hole.Size = V(d, d, d)
				hole.Transparency = done and 1 or 0
			end
			if halo then
				local d = math.max(0.05, 3.2 * s)
				halo.Size = V(d, d, d)
				halo.Transparency = done and 1 or 0.72
			end
			for index, part in ipairs(discs) do
				if part then
					local d = math.max(0.1, (index == 1 and 7 or 9.5) * s)
					part.Size = V(part.Size.X, d, d)
					part.CFrame = CFrame.new(centre) * tilt * CFrame.Angles(0, t * (index == 1 and 2 or -1.5), 0) * UPRIGHT
					part.Transparency = done and 1 or (index == 1 and 0.35 or 0.55)
				end
			end
			for index, clump in ipairs(clumps) do
				if clump then
					local angle = index / 4 * math.pi * 2 + t * (4 + t * 3)
					local radius = (2.4 + (index % 2) * 1) * s
					clump.CFrame = CFrame.new(centre) * tilt * CFrame.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
					clump.Transparency = done and 1 or 0
				end
			end
		end)
		fx:burst(0.2, centre, { count = 18, color = { WHITE, VIOLET }, texture = "glow", size = { 0.5, 0.1 }, life = { 0.6, 0.8 },
			inward = 7, glow = 1 })
		fx:burst(0.9, centre, { count = 12, color = { ORCHID, VIOLET }, texture = "sparkle", size = { 0.5, 0.1 }, life = { 0.6, 0.8 },
			inward = 6, glow = 1 })
		fx:light(0.05, GONE, halo, VIOLET, 22, 3)

		-- Anticipation, then the pull: they tip toward it, stretch, spin, and are swallowed.
		fx:tween(0, PULL, function(e)
			fx:bodyPose({ to = pivot * CFrame.Angles(0.15 * e, 0, 0), scale = V(1, 1 + 0.1 * e, 1), tint = VIOLET, tintAlpha = 0.3 * e })
		end, Ease.sineInOut)
		fx:tween(PULL, GONE - PULL, function(e, raw)
			local rise = (centre.Y - g.Y - 2) * e
			local spin = raw * raw * math.pi * 6
			fx:bodyPose({ to = pivot * CFrame.new(0, rise, 0) * CFrame.Angles(0.15, spin, 0),
				scale = V(1 - 0.85 * e, 1 + 1.4 * e - 1.9 * math.max(0, e - 0.6), 1 - 0.85 * e),
				tint = VIOLET, tintAlpha = 0.3 + 0.5 * e, fade = math.clamp((raw - 0.75) / 0.25, 0, 1) })
		end, Ease.quadIn)
		-- Ground debris pulled up and in.
		fx:at(0.7, function()
			for index = 1, 6 do
				local angle = index / 6 * math.pi * 2
				local from = g + V(math.cos(angle) * 4, 0.3, math.sin(angle) * 4)
				local size = 0.5 + (index % 3) * 0.25
				local chunk = fx:part(V(size, size * 0.7, size), CFrame.new(from), index % 2 == 0 and ROCK or MUD, SLATE)
				fx:tween(0.7 + index * 0.05, 0.85, function(e, raw)
					if chunk then
						local swirl = angle + raw * math.pi * 3
						local radius = 4 * (1 - e)
						local height = from.Y + (centre.Y - from.Y) * e
						chunk.CFrame = CFrame.new(V(g.X + math.cos(swirl) * radius, height, g.Z + math.sin(swirl) * radius)) * CFrame.Angles(raw * 6, raw * 4, 0)
						local s = math.max(0.05, size * (1 - 0.8 * e))
						chunk.Size = V(s, s * 0.7, s)
						chunk.Transparency = raw >= 0.97 and 1 or 0
					end
				end, Ease.quadIn)
			end
		end)

		-- Burst: collapse, then it goes off like a star.
		fx:sound(POP, "Vaporize", 0.1, centre)
		flash(fx, POP, centre, rgb(246, 230, 255), 13, 0.35)
		fx:light(POP, 0.6, centre, ORCHID, 30, 9)
		shock(fx, POP, centre, ORCHID, 1, 20, 0.5, tilt)
		shock(fx, POP + 0.05, centre, WHITE, 1, 12, 0.45, CFrame.Angles(math.pi / 2, 0, 0))
		fx:burst(POP, centre, { count = 24, color = { WHITE, ORCHID, VIOLET }, texture = "sparkle", size = { 0.8, 0.1 }, speed = { 14, 24 },
			life = { 0.5, 0.9 }, drag = 1.5, glow = 1 })
		-- Settle: stardust drifting down.
		fx:burst(POP + 0.15, centre, { count = 8, color = { WHITE, VIOLET }, texture = "sparkle", size = { 0.4, 0 }, speed = { 1, 3 },
			life = { 0.8, 1 }, accel = V(0, -2, 0), glow = 1 })
	end,
}

--------------------------------------------------------------------------------
-- The plain death (DeathFxClient): no cosmetic equipped, or a gun effect. Never moves the body,
-- which is the server's ragdoll.
--------------------------------------------------------------------------------

Designs.Default = {
	-- The hit: a white flash over them, a spit of rot sparks, a thud of dust where they land and a
	-- little rot-soul wisp that rises and fades.
	Impact = {
		life = 2.6,
		peak = 0.9,
		moments = { 0.05, 0.4, 1.3 },
		view = { focus = V(0, 4, 0), radius = 8 },
		cues = {},
		build = function(fx)
			local g = fx.ground
			fx:flashBody(0, 0.3, WHITE)
			fx:burst(0, function()
				return fx:bodyCenter()
			end, { count = 10, color = { BRAIN, GOO_GLOW }, texture = "sparkle", size = { 0.5, 0 }, speed = { 6, 11 },
				life = { 0.3, 0.55 }, accel = V(0, -20, 0), glow = 1 })
			fx:light(0, 0.25, function()
				return fx:bodyCenter()
			end, BRAIN, 10, 1.5)
			fx:burst(0.35, g + V(0, 0.3, 0), { count = 8, color = { DUST, rgb(150, 140, 120) }, texture = "smoke", size = { 0.8, 2 },
				speed = { 3, 6 }, life = { 0.5, 0.8 }, spread = 80, drag = 3, glow = 0, fade = 0.35 })
			-- The wisp.
			local wisp, halo
			local from
			fx:at(0.7, function()
				from = fx:bodyCenter()
				wisp = fx:part(V(0.9, 0.9, 0.9), CFrame.new(from), SOUL, Enum.Material.Neon, BALL, 0.2)
				halo = fx:part(V(1.9, 1.9, 1.9), CFrame.new(from), SOUL, Enum.Material.Neon, BALL, 0.75)
				fx:light(0.7, 1.6, wisp, SOUL, 8, 1.2)
			end)
			fx:tween(0.7, 1.7, function(e, raw)
				if wisp and from then
					local s = math.max(0.05, 0.9 * (1 - 0.5 * raw))
					local at = CFrame.new(from + V(math.sin(raw * math.pi * 3) * 0.6, 6 * e, 0))
					local gone = math.clamp((raw - 0.6) / 0.4, 0, 1)
					wisp.Size = V(s, s, s)
					wisp.CFrame = at
					wisp.Transparency = 0.2 + 0.8 * gone
					if halo then
						local h = s * (2.1 + math.sin(raw * math.pi * 6) * 0.2)
						halo.Size = V(h, h, h)
						halo.CFrame = at
						halo.Transparency = 0.75 + 0.25 * gone
					end
				end
			end, Ease.sineInOut)
			fx:burst(1.1, function()
				return wisp and wisp.Position or fx:bodyCenter()
			end, { count = 5, color = { SOUL, WHITE }, texture = "sparkle", size = { 0.35, 0 }, speed = { 0.5, 1.5 },
				life = { 0.5, 0.8 }, accel = V(0, -2, 0), glow = 1 })
			fx:burst(1.6, function()
				return wisp and wisp.Position or fx:bodyCenter()
			end, { count = 5, color = { SOUL, WHITE }, texture = "sparkle", size = { 0.35, 0 }, speed = { 0.5, 1.5 },
				life = { 0.4, 0.7 }, accel = V(0, -2, 0), glow = 1 })
		end,
	},
	-- The end: as the server fades the ragdoll out, it goes in a soft puff rather than just thinning.
	Poof = {
		life = 1.5,
		peak = 0.3,
		moments = { 0.1, 0.3, 0.8 },
		view = { focus = V(0, 3, 0), radius = 7 },
		cues = {},
		build = function(fx)
			local centre = fx:bodyCenter()
			fx:burst(0, centre, { count = 12, color = { rgb(200, 210, 190), rgb(120, 130, 120) }, texture = "smoke", size = { 1.4, 3.2 },
				speed = { 2, 5 }, life = { 0.7, 1.2 }, drag = 2, accel = V(0, 2, 0), glow = 0, fade = 0.35 })
			fx:burst(0.05, centre, { count = 8, color = { SOUL, WHITE }, texture = "sparkle", size = { 0.4, 0 }, speed = { 3, 6 },
				life = { 0.4, 0.8 }, glow = 1 })
		end,
	},
}

--------------------------------------------------------------------------------

-- The cosmetic designs by id (Default is not one).
function Designs.Get(id)
	if id == "Default" or id == "Get" or id == "Ids" then
		return nil
	end
	local design = Designs[id]
	return type(design) == "table" and design.build and design or nil
end

-- Every cosmetic design's id, sorted.
function Designs.Ids()
	local ids = {}
	for id, design in pairs(Designs) do
		if type(design) == "table" and design.build then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

return Designs
