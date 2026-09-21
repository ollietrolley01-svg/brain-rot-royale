-- The creative guns' own rounds, registered into Ballistics' round registry by kind (WeaponData
-- `projectile`). Required by CreativeArsenal, so the kinds exist wherever WeaponData is loaded -- on the
-- server before ProjectileService looks one up, and on the client for whatever draws them.
--
-- Callbacks run on the server only and reach server tools through the `api` ProjectileService passes
-- (Targets, DealDamage, ...); nothing here requires a server module. A sweep contact on a flying round
-- is { Instance, Position, Normal, Distance }; a contact on a bouncing body is { instance, position,
-- normal, speed }, so both spellings are read.
--
--   ricochetDisc   Fidget Disc Launcher. Flies flat and fast; the first wall it meets it glances off
--                  (becoming a bouncing body), and whatever body it meets next it cuts -- a person takes
--                  the hit, anything else just stops it. Non-explosive.
--   homingSlipper  Grandma's Slipper Launcher. Flies at a moderate speed with a slight drop and, after a
--                  moment, curves toward the enemy most nearly ahead of it inside a 25-degree cone,
--                  turning at most 20 degrees over its whole flight. Non-explosive, hits hard.
--   lobbedToast    Toaster Mortar. Pops out with an upward kick and arcs under full gravity, bursting on
--                  the first thing it touches.
--
-- `look` is how ProjectileClient draws the round (claude-a4's contract, documented in ThrowableModels):
--   shape  "disc" | "slipper" | "toast" | "ball" | "box" | "cylinder"
--   size   studs, the longest dimension
--   color  Color3; trim (optional accent) and glow (optional neon accent) likewise
--   spin   "roll" (about its velocity) | "flat" (level, spinning like a frisbee) | "tumble" (end over
--          end) | "none" (nose along its velocity)
-- `steer` also runs on the client, against a client api whose Targets lists living characters near
-- the round, so the curve bends on screen as it does on the server. It must stay pure: it reads dt,
-- entry.age/velocity/position/owner/turned and api.Targets only, keeps its memory in entry.turned,
-- and uses no services, randomness or module state. onContact and onLaunch are server-only.

local Ballistics = require(script.Parent:WaitForChild("Ballistics"))

local CreativeRounds = {}

local HOMING_CONE = math.rad(25)
local HOMING_TOTAL = math.rad(20)
local HOMING_RATE = math.rad(90)
local HOMING_DELAY = 0.12
local HOMING_RANGE = 70
local TOAST_LIFT = 22

local function hitInstance(contact)
	return contact and (contact.Instance or contact.instance) or nil
end

local function isCharacter(instance)
	local model = instance and instance:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

CreativeRounds.ricochetDisc = Ballistics.RegisterRound("ricochetDisc", {
	motion = "free",
	speed = 150,
	gravityScale = 0.03,
	radius = 0.35,
	maxTime = 2.2,
	explosive = false,
	impactBonus = 0,
	restitution = 0.55,
	friction = 0.3,
	syncEvery = 0.1,
	look = { shape = "disc", size = 0.9, color = Color3.fromRGB(255, 80, 180), glow = Color3.fromRGB(90, 255, 200), spin = "flat" },
	onContact = function(entry, contact)
		if isCharacter(hitInstance(contact)) then
			return "detonate"
		end
		if not entry.ricocheted then
			entry.ricocheted = true
			return "bounce"
		end
		return "stop"
	end,
})

CreativeRounds.homingSlipper = Ballistics.RegisterRound("homingSlipper", {
	motion = "free",
	speed = 115,
	gravityScale = 0.08,
	radius = 0.4,
	maxTime = 3,
	explosive = false,
	impactBonus = 10,
	syncEvery = 0.08,
	look = { shape = "slipper", size = 1.1, color = Color3.fromRGB(255, 150, 190), trim = Color3.fromRGB(255, 240, 250), spin = "none" },
	steer = function(entry, dt, api)
		if entry.age < HOMING_DELAY or (entry.turned or 0) >= HOMING_TOTAL then
			return
		end
		local speed = entry.velocity.Magnitude
		if speed < 1 then
			return
		end
		local forward = entry.velocity / speed
		local best, bestDot = nil, math.cos(HOMING_CONE)
		for _, target in ipairs(api.Targets(entry.position, HOMING_RANGE, entry.owner)) do
			local to = target.root.Position - entry.position
			local distance = to.Magnitude
			if distance > 0.5 then
				local dot = (to / distance):Dot(forward)
				if dot > bestDot then
					best, bestDot = to / distance, dot
				end
			end
		end
		if not best then
			return
		end
		local angle = math.acos(math.clamp(forward:Dot(best), -1, 1))
		local turn = math.min(angle, HOMING_RATE * dt, HOMING_TOTAL - (entry.turned or 0))
		if angle <= 1e-4 or turn <= 0 then
			return
		end
		local direction = forward:Lerp(best, turn / angle).Unit
		entry.turned = (entry.turned or 0) + turn
		entry.velocity = direction * speed
	end,
	onContact = function(entry, contact)
		if isCharacter(hitInstance(contact)) then
			return "detonate"
		end
		return "stop"
	end,
})

CreativeRounds.lobbedToast = Ballistics.RegisterRound("lobbedToast", {
	motion = "body",
	speed = 95,
	gravityScale = 1,
	radius = 0.3,
	maxTime = 4,
	impact = true,
	restitution = 0.2,
	friction = 0.6,
	impactBonus = 15,
	innerRadius = 3,
	wallDamage = 80,
	look = { shape = "toast", size = 0.8, color = Color3.fromRGB(206, 150, 80), trim = Color3.fromRGB(150, 96, 48), spin = "tumble" },
	onLaunch = function(entry)
		if entry.body then
			entry.body.velocity += Vector3.new(0, TOAST_LIFT, 0)
		end
	end,
})

return CreativeRounds
