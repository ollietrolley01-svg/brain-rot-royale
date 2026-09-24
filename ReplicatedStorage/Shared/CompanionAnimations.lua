-- Companion animation: procedural poses for the part-built brainrots that follow players.
--
-- A companion built with `BrainrotModels.Build(def, { rig = true })` has its parts welded to a few
-- invisible pivots: Body, and on it Head (for stacked bodies), ArmL/ArmR, WingL/WingR, Tail and
-- FootL/FootR, each joined to its parent by a Motor6D named after its group. Motor6D.Transform is
-- local to each machine and never replicates, the same as a character's Animator, so every client
-- poses every nearby companion itself (bots' ones, simulated by the server, included) while the
-- server keeps the rest pose for hit detection.
--
-- Everything here is a pure function of time, so the gallery can render a clip mid-swing on an
-- anchored build and the checks can hold clip timing to the server's without a client.
--
--   CompanionAnimations.Rig(model)                        -> rig, or nil if the model isn't rigged
--   CompanionAnimations.Idle(rig, now)                    -> pose parameters
--   CompanionAnimations.Layer(pose, body, clip, t, scale) -> adds a clip at time t onto a pose
--   CompanionAnimations.Transforms(pose)                  -> { group = CFrame } joint transforms
--   CompanionAnimations.Apply(rig, pose)                  -> sets the joints' Transforms
--   CompanionAnimations.Duration(kind, travel, style)     -> how long a clip runs
--   CompanionAnimations.Phases(kind, travel, style)       -> { strike, lands, duration }
--   CompanionAnimations.Glow(kind, t, travel, style)      -> 0-1, how hard the creature is glowing
--
-- A clip is { kind = "Spit" | "Bonk" | "Zap" | "Chain" | "Lob" | "Shockwave" | "Blast" | "Cheer",
-- start = seconds, target = Vector3 (the target in the root's space, from the Body pivot),
-- travel = seconds, style = BrainrotData.AbilityStyles name or nil }.
--
-- Every move is four beats (2026-09-24, Oliver: "make way better quality and cool animations for
-- the brainrots' abilities"):
--
--   anticipation  0 .. Windup: the wind-up pose, a squash as it gathers itself, the glow building
--   action        at Windup: the lunge, spin, rear-up, slam or recoil -- the frame the server
--                 applies the damage (it waits the same Windup), so the strike never lies
--   follow-through the overshoot past the action, and the settle back through it
--   recovery      back to exactly nothing by Duration, so the clip hands back to the idle without
--                 a pop (tools/companion_fx_check.py holds every clip to that on every body)
--
-- A blast brainrot's move explodes the moment it is used (ProjectileService.Explode, no windup), so
-- its "Blast" clip has no anticipation: it recoils from the frame it starts.

local CompanionAnimations = {}

CompanionAnimations.Windup = 0.15
local WINDUP = CompanionAnimations.Windup

-- Stacked bodies nod their top half on its own; the neck height is where it splits.
CompanionAnimations.Neck = { Pear = 0.3, Stack = 0.2, Totem = -0.16 }

-- How each body moves. hop scales jumps, tilt scales leans; tumble bodies flip rigidly through
-- the air, spinners turn on the spot instead of jumping, floaters swoop and bob more.
local STYLES = {
	Blob = { hop = 1.0, tilt = 1.0 },
	Bean = { hop = 1.1, tilt = 1.1 },
	Cube = { hop = 0.8, tilt = 0.45, tumble = true },
	Pear = { hop = 0.9, tilt = 1.2 },
	Disc = { hop = 0.5, tilt = 0.5, spinner = true },
	Stack = { hop = 1.0, tilt = 1.15 },
	Egg = { hop = 0.9, tilt = 1.35, wobble = true },
	Mushroom = { hop = 1.2, tilt = 0.8 },
	Cloud = { hop = 0.6, tilt = 0.6, spinner = true, floats = true },
	Can = { hop = 0.7, tilt = 0.5, tumble = true },
	Cone = { hop = 0.8, tilt = 1.0, wobble = true },
	Ghost = { hop = 0.6, tilt = 0.8, spinner = true, floats = true },
	Loaf = { hop = 0.6, tilt = 0.4, tumble = true },
	Totem = { hop = 0.7, tilt = 0.9 },
}
CompanionAnimations.Styles = STYLES

local function clamp01(x)
	return math.clamp(x, 0, 1)
end

local function smooth(x)
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

-- 0 before a, 1 after b, linear between.
local function span(t, a, b)
	return clamp01((t - a) / (b - a))
end

-- A sine bump: 0 at a, 1 halfway, 0 at b.
local function bump(t, a, b)
	if t <= a or t >= b then
		return 0
	end
	return math.sin(math.pi * (t - a) / (b - a))
end

--------------------------------------------------------------------------------
-- Tracks: a channel of a clip as keys, eased between
--------------------------------------------------------------------------------

-- `keys` is { { time, value, ease }, ... } in time order; `ease` shapes the stretch that ENDS at that
-- key: "in" accelerates into it (a slam), "out" decelerates into it (a leap reaching its top),
-- anything else is smoothstep. Every clip's tracks start at 0 at time 0 and end at 0 at its
-- Duration, which is what makes a clip start and finish on the idle pose.
local EASE = {
	["in"] = function(x)
		return x * x * x
	end,
	out = function(x)
		local inv = 1 - x
		return 1 - inv * inv * inv
	end,
}

local function track(keys, t)
	local first = keys[1]
	if t <= first[1] then
		return first[2]
	end
	for index = 2, #keys do
		local key = keys[index]
		if t <= key[1] then
			local previous = keys[index - 1]
			local width = key[1] - previous[1]
			local x = width > 0 and (t - previous[1]) / width or 1
			local shape = EASE[key[3]]
			x = shape and shape(x) or smooth(x)
			return previous[2] + (key[2] - previous[2]) * x
		end
	end
	return keys[#keys][2]
end
CompanionAnimations.Track = track

-- The beats every clip is written against. `W` is the windup; D the clip's own length.
local W = WINDUP

-- Clip lengths before any style changes them.
local BASE_DURATION = {
	Spit = 0.62,
	Zap = 0.58,
	Chain = 0.75,
	Lob = 0.78,
	Shockwave = 0.85,
	Blast = 0.6,
	Cheer = 0.45,
}
-- A Bonk's length depends on how far it flies: the windup, the flight, then this to land and hop home.
local BONK_RECOVER = 0.6

-- How much faster a Quick style's follow-through and recovery run (the windup never changes: the
-- server's damage waits for it).
local QUICK_TAIL = 0.72

-- The tracks of each move, as keys. Channel names are pose fields; `fwd` is a lunge along the way
-- the creature faces (scaled by its size), `y` a rise (scaled too), `swing`/`raise` move both arms.
local D = BASE_DURATION
local TRACKS = {
	Spit = {
		-- Rears back and gathers (squash) over the windup, snaps forward stretched on the strike, bounces
		-- back past its rest and settles.
		pitch = { { 0, 0 }, { W * 0.8, 0.42 }, { W + 0.06, -0.5, "out" }, { W + 0.2, 0.14 }, { W + 0.34, -0.04 }, { D.Spit, 0 } },
		squash = { { 0, 0 }, { W * 0.8, 0.65 }, { W + 0.05, -0.6, "out" }, { W + 0.16, 0.25 }, { W + 0.3, 0 }, { D.Spit, 0 } },
		fwd = { { 0, 0 }, { W * 0.8, -0.14 }, { W + 0.06, 0.45, "out" }, { W + 0.22, 0.04 }, { D.Spit, 0 } },
		y = { { 0, 0 }, { W * 0.8, 0.06 }, { W + 0.06, 0.1 }, { D.Spit, 0 } },
		nod = { { 0, 0 }, { W * 0.8, -0.4 }, { W + 0.06, 0.55, "out" }, { W + 0.22, -0.1 }, { D.Spit, 0 } },
		swing = { { 0, 0 }, { W * 0.8, -0.6 }, { W + 0.06, 1.0, "out" }, { W + 0.25, 0.1 }, { D.Spit, 0 } },
		flap = { { 0, 0 }, { W, 0.3 }, { W + 0.08, 0.8 }, { W + 0.3, 0 }, { D.Spit, 0 } },
		lift = { { 0, 0 }, { W * 0.8, -0.3 }, { W + 0.08, 0.6 }, { W + 0.3, 0 }, { D.Spit, 0 } },
		glow = { { 0, 0 }, { W, 1, "in" }, { W + 0.1, 0 }, { D.Spit, 0 } },
	},
	Zap = {
		-- Charges on the spot (a shiver, the arm coming up to point), then the beam's kick pushes it
		-- back on its heels.
		y = { { 0, 0 }, { W, 0.14 }, { W + 0.1, 0.02 }, { D.Zap, 0 } },
		squash = { { 0, 0 }, { W * 0.85, 0.45 }, { W + 0.03, -0.35, "out" }, { W + 0.16, 0.15 }, { W + 0.3, 0 }, { D.Zap, 0 } },
		fwd = { { 0, 0 }, { W, 0.08 }, { W + 0.05, -0.5, "out" }, { W + 0.25, -0.1 }, { D.Zap, 0 } },
		pitch = { { 0, 0 }, { W, -0.12 }, { W + 0.05, 0.32, "out" }, { W + 0.22, -0.06 }, { D.Zap, 0 } },
		swingR = { { 0, 0 }, { W * 0.7, 1.5 }, { W + 0.2, 1.5 }, { W + 0.34, 0.3 }, { D.Zap, 0 } },
		swingL = { { 0, 0 }, { W * 0.7, 0.5 }, { W + 0.2, 0.5 }, { D.Zap, 0 } },
		flap = { { 0, 0 }, { W, 0.9 }, { W + 0.1, 0.3 }, { D.Zap, 0 } },
		nod = { { 0, 0 }, { W + 0.05, 0.25 }, { D.Zap, 0 } },
		glow = { { 0, 0 }, { W, 1, "in" }, { W + 0.08, 0.2 }, { D.Zap, 0 } },
		shiver = { { 0, 0 }, { W, 1, "in" }, { W + 0.03, 0 }, { D.Zap, 0 } },
	},
	Chain = {
		-- The Zap's charge, then a full spin that flings the chain out, arms thrown wide.
		y = { { 0, 0 }, { W, 0.14 }, { W + 0.2, 0.18 }, { W + 0.45, 0 }, { D.Chain, 0 } },
		squash = { { 0, 0 }, { W * 0.85, 0.5 }, { W + 0.04, -0.4, "out" }, { W + 0.3, -0.1 }, { W + 0.48, 0.15 }, { D.Chain, 0 } },
		fwd = { { 0, 0 }, { W, 0.08 }, { W + 0.05, -0.35, "out" }, { W + 0.3, -0.1 }, { D.Chain, 0 } },
		pitch = { { 0, 0 }, { W, -0.12 }, { W + 0.05, 0.25 }, { W + 0.3, -0.05 }, { D.Chain, 0 } },
		swingR = { { 0, 0 }, { W * 0.7, 1.5 }, { W + 0.1, 1.2 }, { W + 0.4, 0.2 }, { D.Chain, 0 } },
		swingL = { { 0, 0 }, { W * 0.7, 0.5 }, { W + 0.4, 0.2 }, { D.Chain, 0 } },
		raise = { { 0, 0 }, { W, 0.2 }, { W + 0.2, 1.0 }, { W + 0.45, 0 }, { D.Chain, 0 } },
		flap = { { 0, 0 }, { W, 0.9 }, { W + 0.3, 0.6 }, { D.Chain, 0 } },
		glow = { { 0, 0 }, { W, 1, "in" }, { W + 0.3, 0.3 }, { D.Chain, 0 } },
		shiver = { { 0, 0 }, { W, 1, "in" }, { W + 0.03, 0 }, { D.Chain, 0 } },
		-- One full turn, from the strike: 2*pi is the same pose as 0, so it ends where it began.
		spinTurn = { { 0, 0 }, { W, 0 }, { W + 0.45, 1 }, { D.Chain, 1 } },
	},
	Lob = {
		-- Arms right back over its head and a crouch; the toss throws it up and forward, stretched,
		-- and it lands back into a little squash.
		swing = { { 0, 0 }, { W * 0.9, 2.7 }, { W + 0.1, 1.2, "out" }, { W + 0.3, 0.2 }, { D.Lob, 0 } },
		pitch = { { 0, 0 }, { W * 0.9, 0.45 }, { W + 0.08, -0.42, "out" }, { W + 0.25, 0.08 }, { D.Lob, 0 } },
		squash = { { 0, 0 }, { W * 0.9, 0.55 }, { W + 0.06, -0.55, "out" }, { W + 0.2, 0.2 }, { W + 0.36, 0 }, { D.Lob, 0 } },
		y = { { 0, 0 }, { W * 0.9, -0.08 }, { W + 0.1, 0.4, "out" }, { W + 0.3, 0 }, { D.Lob, 0 } },
		nod = { { 0, 0 }, { W * 0.9, -0.3 }, { W + 0.1, 0.35 }, { D.Lob, 0 } },
		flap = { { 0, 0 }, { W + 0.1, 0.8 }, { W + 0.35, 0 }, { D.Lob, 0 } },
		lift = { { 0, 0 }, { W * 0.9, 0.4 }, { W + 0.12, -0.3 }, { D.Lob, 0 } },
		glow = { { 0, 0 }, { W, 1, "in" }, { W + 0.1, 0 }, { D.Lob, 0 } },
	},
	Shockwave = {
		-- Rears up, stretched, arms high; drops (accelerating) to slam on the windup; a big squash,
		-- a tremble and back up.
		y = { { 0, 0 }, { W * 0.6, 0.95, "out" }, { W, 0, "in" }, { W + 0.06, -0.22 }, { W + 0.2, 0.04 }, { D.Shockwave, 0 } },
		squash = { { 0, 0 }, { W * 0.6, -0.5 }, { W, -0.3, "in" }, { W + 0.05, 0.9 }, { W + 0.18, -0.15 }, { W + 0.32, 0.05 }, { D.Shockwave, 0 } },
		raise = { { 0, 0 }, { W * 0.6, 1.7 }, { W, 1.5 }, { W + 0.08, 0.2 }, { D.Shockwave, 0 } },
		flap = { { 0, 0 }, { W * 0.6, 1.0 }, { W + 0.1, 0 }, { D.Shockwave, 0 } },
		step = { { 0, 0 }, { W, 0 }, { W + 0.05, 0.25 }, { W + 0.2, 0 }, { D.Shockwave, 0 } },
		pitch = { { 0, 0 }, { W * 0.6, -0.12 }, { W, 0 }, { W + 0.05, 0.12 }, { W + 0.25, 0 }, { D.Shockwave, 0 } },
		glow = { { 0, 0 }, { W, 1, "in" }, { W + 0.12, 0 }, { D.Shockwave, 0 } },
		tremble = { { 0, 0 }, { W, 0 }, { W + 0.04, 1 }, { W + 0.24, 0 }, { D.Shockwave, 0 } },
	},
	-- The spinners' Shockwave: a wind-up turn, a small hop and the slam.
	ShockwaveSpin = {
		y = { { 0, 0 }, { W * 0.6, 0.4, "out" }, { W, 0, "in" }, { W + 0.05, -0.12 }, { D.Shockwave, 0 } },
		squash = { { 0, 0 }, { W * 0.6, -0.3 }, { W + 0.05, 0.7 }, { W + 0.2, -0.1 }, { D.Shockwave, 0 } },
		raise = { { 0, 0 }, { W * 0.6, 1.5 }, { W + 0.08, 0.2 }, { D.Shockwave, 0 } },
		flap = { { 0, 0 }, { W * 0.6, 1.0 }, { W + 0.1, 0 }, { D.Shockwave, 0 } },
		glow = { { 0, 0 }, { W, 1, "in" }, { W + 0.12, 0 }, { D.Shockwave, 0 } },
		tremble = { { 0, 0 }, { W, 0 }, { W + 0.04, 1 }, { W + 0.24, 0 }, { D.Shockwave, 0 } },
		spinTurn = { { 0, 0 }, { W + 0.22, 1 }, { D.Shockwave, 1 } },
	},
	-- No windup: kicked straight back by its own explosion.
	Blast = {
		fwd = { { 0, 0 }, { 0.05, -0.6, "out" }, { 0.25, -0.15 }, { D.Blast, 0 } },
		pitch = { { 0, 0 }, { 0.05, 0.45, "out" }, { 0.22, -0.1 }, { 0.36, 0.04 }, { D.Blast, 0 } },
		squash = { { 0, 0 }, { 0.04, -0.6, "out" }, { 0.14, 0.7 }, { 0.3, -0.1 }, { D.Blast, 0 } },
		y = { { 0, 0 }, { 0.06, 0.25, "out" }, { 0.2, 0 }, { D.Blast, 0 } },
		raise = { { 0, 0 }, { 0.05, 1.2 }, { 0.3, 0.1 }, { D.Blast, 0 } },
		flap = { { 0, 0 }, { 0.05, 1.0 }, { 0.3, 0 }, { D.Blast, 0 } },
		glow = { { 0, 0 }, { 0.03, 1 }, { 0.22, 0 }, { D.Blast, 0 } },
		tremble = { { 0, 0 }, { 0.03, 1 }, { 0.3, 0 }, { D.Blast, 0 } },
	},
	Cheer = {
		y = { { 0, 0 }, { 0.2, 0.32, "out" }, { D.Cheer, 0, "in" } },
		squash = { { 0, 0 }, { 0.06, 0.35 }, { 0.2, -0.3 }, { 0.38, 0.2 }, { D.Cheer, 0 } },
		raise = { { 0, 0 }, { 0.2, 1.1 }, { D.Cheer, 0 } },
		flap = { { 0, 0 }, { 0.2, 0.9 }, { D.Cheer, 0 } },
		wiggle = { { 0, 0 }, { 0.1, 1 }, { 0.35, 1 }, { D.Cheer, 0 } },
	},
}
CompanionAnimations.Tracks = TRACKS

-- The anticipation and recovery of a Bonk; the flight itself is worked out from the target.
local function bonkKeys(travel, recover)
	local land = W + travel
	local d = land + recover
	return {
		squash = { { 0, 0 }, { W * 0.85, 0.8 }, { W + 0.05, -0.55, "out" }, { land - 0.02, -0.3 }, { land + 0.04, 1.0, "in" },
			{ land + 0.16, -0.2 }, { land + 0.3, 0.1 }, { d, 0 } },
		crouch = { { 0, 0 }, { W * 0.85, 1 }, { W + 0.04, 0 }, { d, 0 } },
		arms = { { 0, 0 }, { W * 0.85, 2.2 }, { W + 0.05, 2.4 }, { land, 2.4 }, { land + 0.12, 0.4 }, { d, 0 } },
		glow = { { 0, 0 }, { W, 1, "in" }, { land, 0.5 }, { land + 0.15, 0 }, { d, 0 } },
		tremble = { { 0, 0 }, { land, 0 }, { land + 0.03, 1 }, { land + 0.2, 0 }, { d, 0 } },
	}
end

--------------------------------------------------------------------------------
-- Timing
--------------------------------------------------------------------------------

-- Whether a move's damage travels after the strike (and so lands `travel` later).
local TRAVELS = { Spit = true, Bonk = true, Lob = true }
CompanionAnimations.Travels = TRAVELS

-- How long a clip runs. `style` is optional: a Quick style runs its follow-through faster.
function CompanionAnimations.Duration(kind, travel, style)
	travel = travel or 0.35
	local base
	if kind == "Bonk" then
		base = WINDUP + travel + BONK_RECOVER
	else
		base = BASE_DURATION[kind] or 0.5
	end
	if style == "Quick" and kind ~= "Cheer" then
		local strike = kind == "Blast" and 0 or WINDUP
		local tail = base - strike
		-- A Bonk's flight is the server's, not the creature's: only what comes after it speeds up.
		if kind == "Bonk" then
			return strike + travel + BONK_RECOVER * QUICK_TAIL
		end
		return strike + tail * QUICK_TAIL
	end
	return base
end

-- The beats the client times its effects to, from the same numbers as the clip:
--   strike  the action frame: the launch, the beam, the stomp (the server's windup; 0 for a Blast)
--   lands   when the server applies the damage: the strike, plus the flight for Spit, Bonk and Lob
--   duration when the creature is back on its idle
function CompanionAnimations.Phases(kind, travel, style)
	local strike = kind == "Blast" and 0 or WINDUP
	local lands = strike + ((TRAVELS[kind] and (travel or 0)) or 0)
	return { strike = strike, lands = lands, duration = CompanionAnimations.Duration(kind, travel, style) }
end

-- The clock a style's clip reads: a Quick style's tail runs faster, the windup never does.
local function styledTime(kind, t, style)
	if style ~= "Quick" or kind == "Cheer" then
		return t
	end
	local strike = kind == "Blast" and 0 or WINDUP
	if t <= strike then
		return t
	end
	return strike + (t - strike) / QUICK_TAIL
end

--------------------------------------------------------------------------------
-- Clips
--------------------------------------------------------------------------------

function CompanionAnimations.Blank()
	return {
		x = 0, y = 0, z = 0, yaw = 0, spin = 0, pitch = 0, roll = 0,
		swingL = 0, swingR = 0, raiseL = 0, raiseR = 0,
		flap = 0, sweep = 0, wag = 0, lift = 0, nod = 0, turn = 0, stepL = 0, stepR = 0,
		-- squash > 0 gathers (body sinks, feet and arms splay, the head settles); < 0 stretches.
		squash = 0,
		-- 0-1: how hard the creature is glowing (read by the effects, not by a joint).
		glow = 0,
		scale = 1,
	}
end

-- Moves the body `amount` along the way it's facing.
local function forward(pose, amount)
	pose.x -= math.sin(pose.yaw) * amount
	pose.z -= math.cos(pose.yaw) * amount
end

-- A style's own flourish on top of the move, always back to 0 by the end: a Daze wobble, a Leech's
-- gulp as the health comes back, a Long move holding its aim tall through the windup. (A Wide move's
-- bigger stomp is its clip's `amp`; a Quick one's snappier tail is `styledTime`.)
local function styleFlourish(pose, style, kind, t, d, s)
	if not style then
		return
	end
	local strike = kind == "Blast" and 0 or WINDUP
	local after = math.max(t - strike, 0)
	local tail = math.max(d - strike, 0.01)
	if style == "Daze" then
		pose.roll += math.sin(after * 22) * 0.1 * bump(t, strike, d)
	elseif style == "Leech" then
		pose.squash += 0.35 * bump(t, strike + tail * 0.45, strike + tail * 0.8)
	elseif style == "Slow" then
		pose.x += math.sin(after * 70) * 0.03 * s * bump(t, strike, strike + tail * 0.5)
	elseif style == "Burn" then
		pose.y += 0.08 * s * bump(t, strike + tail * 0.2, strike + tail * 0.6)
	elseif style == "Toxic" then
		pose.nod += 0.25 * bump(t, strike + tail * 0.3, strike + tail * 0.85)
	elseif style == "Long" then
		-- Holds its aim a beat longer: stays stretched tall through the strike.
		pose.squash -= 0.25 * bump(t, 0, strike + tail * 0.5)
	elseif style == "Fork" then
		pose.turn += 0.35 * bump(t, strike, strike + tail * 0.6)
	end
end

-- One channel of a clip at time t; 0 for a channel the clip doesn't move.
local function channel(keys, name, t)
	local k = keys[name]
	return k and track(k, t) or 0
end

-- Adds the tracks in `keys` at time t. `style` is the body's way of moving (STYLES), `amp` a Wide
-- move's bigger body language.
local function applyTracks(pose, keys, style, t, s, amp)
	local body = amp or 1
	forward(pose, channel(keys, "fwd", t) * s)
	pose.y += channel(keys, "y", t) * s * style.hop * body
	pose.pitch += channel(keys, "pitch", t) * style.tilt
	pose.squash += channel(keys, "squash", t) * body
	pose.nod += channel(keys, "nod", t)
	local swing = channel(keys, "swing", t)
	pose.swingL += swing + channel(keys, "swingL", t)
	pose.swingR += swing + channel(keys, "swingR", t)
	local raise = channel(keys, "raise", t) * body
	pose.raiseL += raise
	pose.raiseR += raise
	pose.flap += channel(keys, "flap", t)
	pose.lift += channel(keys, "lift", t)
	local step = channel(keys, "step", t) * s * body
	pose.stepL += step
	pose.stepR += step
	pose.glow = math.max(pose.glow, channel(keys, "glow", t))
	local shiver = channel(keys, "shiver", t)
	if shiver ~= 0 then
		pose.x += math.sin(t * 90) * 0.05 * shiver * s
	end
	local tremble = channel(keys, "tremble", t)
	if tremble ~= 0 then
		pose.roll += math.sin(t * 40) * 0.07 * tremble
	end
	local turn = channel(keys, "spinTurn", t)
	if turn ~= 0 then
		pose.spin += math.pi * 2 * turn
	end
	local wiggle = channel(keys, "wiggle", t)
	if wiggle ~= 0 then
		pose.roll += math.sin(t * 28) * 0.12 * wiggle
		pose.wag += math.sin(t * 30) * 0.5 * wiggle
	end
end

local CLIPS = {}

for _, kind in ipairs({ "Spit", "Zap", "Chain", "Lob", "Blast", "Cheer" }) do
	CLIPS[kind] = function(pose, style, t, s)
		applyTracks(pose, TRACKS[kind], style, t, s)
	end
end

CLIPS.Shockwave = function(pose, style, t, s, clip)
	local amp = clip.style == "Wide" and 1.25 or 1
	if style.spinner then
		applyTracks(pose, TRACKS.ShockwaveSpin, style, t, s, amp)
	else
		applyTracks(pose, TRACKS.Shockwave, style, t, s, amp)
		pose.pitch += (style.tumble and 0.25 or 0) * bump(t, W, W + 0.18) * style.tilt
	end
end

CLIPS.Bonk = function(pose, style, t, s, clip)
	local target = clip.target or Vector3.new(0, 0, -6)
	local travel = clip.travel or 0.35
	local recover = clip.style == "Quick" and BONK_RECOVER * QUICK_TAIL or BONK_RECOVER
	-- Built once per clip (the flight time is fixed when the move is used), not every frame.
	local keys = clip.bonkKeys
	if not keys or clip.bonkTravel ~= travel or clip.bonkRecover ~= recover then
		keys = bonkKeys(travel, recover)
		clip.bonkKeys, clip.bonkTravel, clip.bonkRecover = keys, travel, recover
	end
	local amp = clip.style == "Wide" and 1.2 or 1
	local crouch = track(keys.crouch, t)
	pose.y -= 0.2 * crouch * s
	pose.pitch += 0.28 * crouch * style.tilt
	pose.squash += track(keys.squash, t) * amp
	local arms = track(keys.arms, t)
	pose.swingL += arms
	pose.swingR += arms
	pose.glow = math.max(pose.glow, track(keys.glow, t))
	local tremble = track(keys.tremble, t)
	if tremble ~= 0 then
		pose.roll += math.sin(t * 60) * 0.1 * tremble
	end

	local land = WINDUP + travel
	local horizontal = Vector3.new(target.X, 0, target.Z).Magnitude
	local arc = (1.5 + horizontal * 0.12) * amp
	if t >= WINDUP and t < land then
		local a = span(t, WINDUP, land)
		local at = target * a
		pose.x += at.X
		pose.y += at.Y + arc * 4 * a * (1 - a)
		pose.z += at.Z
		if style.tumble then
			pose.pitch -= math.pi * 2 * a
		else
			pose.pitch -= 0.55 * bump(a, 0, 1) * style.tilt
		end
		pose.flap += math.sin(a * math.pi * 6) * 0.8
	elseif t >= land then
		-- Home again: a smaller hop back over the recovery.
		local b = smooth(span(t, land + 0.12, land + recover - 0.05))
		local at = target * (1 - b)
		pose.x += at.X
		pose.y += at.Y + arc * 0.3 * 4 * b * (1 - b)
		pose.z += at.Z
	end
end

-- Where the clip wants the creature to face: toward its target, blended in at the start and out
-- at the end so it turns rather than snaps.
local function facing(clip, t, duration)
	local target = clip.target
	if not target or Vector3.new(target.X, 0, target.Z).Magnitude < 0.5 then
		return 0
	end
	local yaw = math.atan2(-target.X, -target.Z)
	local weight = smooth(span(t, 0, 0.08)) * (1 - smooth(span(t, duration - 0.18, duration)))
	return yaw * weight
end

-- Adds `clip` at `t` seconds into it onto `pose`. Returns false once the clip has finished.
function CompanionAnimations.Layer(pose, body, clip, t, scale)
	local fn = CLIPS[clip.kind]
	local duration = CompanionAnimations.Duration(clip.kind, clip.travel, clip.style)
	if not fn or t < 0 or t > duration then
		return false
	end
	local style = STYLES[body] or STYLES.Blob
	local s = scale or 1
	-- Facing turns the body about its base; a Bonk's leap is a translation in the root's frame,
	-- which the turn doesn't rotate, so it faces its target and still lands on it.
	pose.yaw += facing(clip, t, duration)
	-- A Bonk's flight runs on the real clock (the server's travel); everything else reads the
	-- styled clock, so a Quick follow-through is quicker without the windup moving.
	local clipTime = clip.kind == "Bonk" and t or styledTime(clip.kind, t, clip.style)
	fn(pose, style, clipTime, s, clip)
	styleFlourish(pose, clip.style, clip.kind, t, duration, s)
	return true
end

-- How hard a move's creature glows `t` seconds in: the build-up peaks on the strike. The effects
-- light the creature from this, so its glow and its pose are one curve.
-- One scratch pose and clip, reused: the effects ask this every frame for every charging creature.
local glowPose = CompanionAnimations.Blank()
local glowClip = {}
function CompanionAnimations.Glow(kind, t, travel, style)
	for key in pairs(glowPose) do
		glowPose[key] = 0
	end
	glowClip.kind, glowClip.travel, glowClip.style = kind, travel, style
	if not CompanionAnimations.Layer(glowPose, "Blob", glowClip, t, 1) then
		return 0
	end
	return clamp01(glowPose.glow)
end

-- Always-on life: a breathing bob and sway, arms swinging a little, wings fluttering, tail
-- wagging. `seed` keeps a crowd of companions out of step with each other.
function CompanionAnimations.IdlePose(body, now, seed, scale, into)
	local style = STYLES[body] or STYLES.Blob
	local s = scale or 1
	local t = now + (seed or 0)
	local pose = into or CompanionAnimations.Blank()
	if into then
		for key in pairs(pose) do
			pose[key] = 0
		end
	end
	pose.scale = s
	pose.y = math.sin(t * 2.1) * (style.floats and 0.1 or 0.05) * s
	pose.roll = math.sin(t * 1.3) * (style.wobble and 0.07 or 0.035)
	pose.pitch = math.sin(t * 1.7) * 0.025
	pose.swingL = math.sin(t * 2.1) * 0.14
	pose.swingR = -math.sin(t * 2.1) * 0.14
	pose.raiseL = 0.06 + math.sin(t * 1.6) * 0.04
	pose.raiseR = 0.06 + math.sin(t * 1.6 + 0.8) * 0.04
	pose.flap = math.sin(t * (style.floats and 9 or 6.5)) * 0.3
	pose.wag = math.sin(t * 3.2) * 0.35
	pose.nod = math.sin(t * 1.9) * 0.06
	-- A slow breath: in and out a little.
	pose.squash = math.sin(t * 2.1 + 1.2) * 0.06
	return pose
end

local JOINT_NAMES = { "Body", "Head", "ArmR", "ArmL", "WingR", "WingL", "Tail", "FootR", "FootL" }
CompanionAnimations.JointNames = JOINT_NAMES

-- One joint's transform from the pose. Squash can't scale a part, so it is shown the way a
-- puppeteer would: the body sinks, the head settles into it, the feet and arms splay; a stretch
-- does the opposite.
local function transformFor(name, pose)
	local s = pose.scale or 1
	local squash = pose.squash or 0
	if name == "Body" then
		return CFrame.new(pose.x, pose.y - 0.1 * squash * s, pose.z) * CFrame.Angles(0, pose.yaw + pose.spin, 0)
			* CFrame.Angles(pose.pitch, 0, pose.roll)
	elseif name == "Head" then
		return CFrame.new(0, -0.16 * squash * s, 0) * CFrame.Angles(pose.nod, pose.turn, 0)
	elseif name == "ArmR" then
		return CFrame.Angles(pose.swingR, 0, pose.raiseR + 0.3 * squash)
	elseif name == "ArmL" then
		return CFrame.Angles(pose.swingL, 0, -pose.raiseL - 0.3 * squash)
	elseif name == "WingR" then
		return CFrame.Angles(0, pose.sweep, pose.flap + 0.25 * squash)
	elseif name == "WingL" then
		return CFrame.Angles(0, -pose.sweep, -pose.flap - 0.25 * squash)
	elseif name == "Tail" then
		return CFrame.Angles(pose.lift, pose.wag, 0)
	elseif name == "FootR" then
		return CFrame.new(0.1 * squash * s, pose.stepR, 0)
	elseif name == "FootL" then
		return CFrame.new(-0.1 * squash * s, pose.stepL, 0)
	end
	return nil
end

function CompanionAnimations.Transforms(pose)
	local transforms = {}
	for _, name in ipairs(JOINT_NAMES) do
		transforms[name] = transformFor(name, pose)
	end
	return transforms
end

-- A phase offset in [0, 2π) from every character of a name.
local function seedFor(name)
	local hash = 0
	for index = 1, #name do
		hash = (hash * 31 + string.byte(name, index)) % 100003
	end
	return hash / 100003 * math.pi * 2
end

-- The joints of a rigged companion, or nil.
function CompanionAnimations.Rig(model)
	local joints = {}
	local any = false
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") and string.sub(child.Name, 1, 5) == "Pivot" then
			local joint = child:FindFirstChildOfClass("Motor6D")
			if joint then
				joints[joint.Name] = joint
				any = true
			end
		end
	end
	if not any or not joints.Body then
		return nil
	end
	return {
		model = model,
		joints = joints,
		root = model.PrimaryPart or model:FindFirstChild("Root"),
		body = model:GetAttribute("RigBody") or "Blob",
		scale = model:GetAttribute("RigScale") or 1,
		seed = seedFor(model.Name),
	}
end

-- Fills and returns the rig's own pose table, so animating a crowd allocates nothing per frame.
function CompanionAnimations.Idle(rig, now)
	rig.pose = CompanionAnimations.IdlePose(rig.body, now, rig.seed, rig.scale, rig.pose)
	return rig.pose
end

-- Every joint back to its rest pose.
function CompanionAnimations.Rest(rig)
	for _, joint in pairs(rig.joints) do
		joint.Transform = CFrame.new()
	end
end

-- Every frame, for every rig in range: no table of transforms is built to be thrown away.
function CompanionAnimations.Apply(rig, pose)
	for name, joint in pairs(rig.joints) do
		local transform = transformFor(name, pose)
		if transform then
			joint.Transform = transform
		end
	end
end

return CompanionAnimations
