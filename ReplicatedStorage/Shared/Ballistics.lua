-- Flight, bounce and blast math for everything that flies and blows up: launcher rounds, grenades and
-- smoke bombs. Shared, so the server's ProjectileService, the client that draws the rounds and the
-- arc preview, and tools/projectile_probe.lua all run exactly the same numbers. A preview drawn with
-- different maths from the real throw would be a lie on the screen.
--
--   Ballistics.Rounds[kind]                    launcher rounds ("rocket", "grenade"), by WeaponData's `projectile`
--   Ballistics.Throwables[itemId]              thrown items, by ItemData id
--   Ballistics.RoundState(spec, origin, direction, gravity, t)     position, velocity of a round at time t
--   Ballistics.RoundTimeFor(spec, distance)    how long a round takes to travel `distance` along its line
--   Ballistics.LeadAim(spec, origin, target, targetVelocity, gravity)   a point to aim at so the round hits
--   Ballistics.ThrowOrigin(head, direction)    where a thrown item leaves the hand
--   Ballistics.ThrowVelocity(spec, origin, aimPoint, carrierVelocity)
--   Ballistics.CarrierVelocity(velocity)       the thrower's run as a throw may carry it (flat, capped)
--   Ballistics.LobVelocity(origin, target, gravity, gravityScale)       lands on `target` (bots)
--   Ballistics.StepBody(body, dt, gravity, cast)   one step of a bouncing thrown body
--   Ballistics.BlastScale(distance, innerRadius, radius)   damage multiplier at a distance from a blast
--   Ballistics.SmokeRadius(cloud, now), Ballistics.SmokeDensity(cloud, now)
--   Ballistics.SmokeChord(cloud, a, b, now)    studs of dense smoke on the line from a to b
--
-- Gravity is always passed in (workspace.Gravity when the thing was launched), never read here, so a
-- Low Gravity match changes every arc the same way everywhere.

local Ballistics = {}

local UP = Vector3.yAxis

-- Launcher rounds: a registry keyed by WeaponData's `projectile`, so a new kind of round is data (and,
-- if it needs it, a few behaviour callbacks), never an edit to ProjectileService's loop. Add one with
-- Ballistics.RegisterRound(kind, spec). Damage and blast radius stay with the gun in WeaponData
-- (`damage`, `splashRadius`); a spec is how the round flies and what it does when it meets something.
--
--   motion        "line" (default): leaves at `speed`, reaches `maxSpeed` after `boostTime`, feels
--                 `gravityScale` of gravity; exact at any time, so clients replay it from one event.
--                 "body": bounces from the launch velocity (Ballistics.StepBody) like a thrown grenade.
--                 "free": velocity integrated each step, for rounds that steer; clients get a position
--                 correction every `syncEvery` seconds.
--   radius        collision radius
--   maxTime       bursts in the air after this long
--   armTime       ("line") a hit before this is a dud: it bounces and bursts `dudFuse` later
--   restitution, friction   ("body", and duds) how it bounces
--   fuse          ("body") bursts this long after launch; `impact = true` bursts on first contact instead
--   maxBounces    ("body") bursts on this contact at the latest
--   explosive     false: no blast, it only hurts whatever it hits directly (damage + impactBonus)
--   impactBonus   extra damage to whoever it hits directly
--   innerRadius   full blast damage inside this
--   wallDamage    what walls, floors and roofs within half the blast radius take
--   syncEvery     seconds between position corrections sent to clients ("free")
--
-- Behaviour callbacks, server-side, all optional. `api` is ProjectileService's toolkit (Explode,
-- DealDamage, Creditable, Targets, Report, Remove, Clock); `entry` is the live round (owner, weaponId, def (the gun,
-- for launcher rounds), kind, age, position, velocity, body, damage, radius). A round in flight that
-- strikes a Head part is a headshot: the direct part of its damage (impactBonus, or all of it when
-- `explosive = false`) takes the gun's headshotMultiplier; the blast never does.
--   onLaunch(entry, api)
--   steer(entry, dt, api)                 change entry.velocity ("free" motion)
--   onContact(entry, contact, api)        return "detonate", "bounce", "stop" (gone, no burst), "pass"
--                                         (fly on through it) or nil for the default rules
--   onDetonate(entry, blast, api)         adjust `blast` before it happens, or return false to cancel it
Ballistics.Rounds = {
	-- A PG-7V-style rocket: a booster kick out of the tube, then the sustainer carries it flat and fast.
	rocket = {
		speed = 120,
		maxSpeed = 260,
		boostTime = 0.35,
		gravityScale = 0.06,
		radius = 0.3,
		maxTime = 2.2,
		armTime = 0,
		impactBonus = 25,
		innerRadius = 3.5,
		wallDamage = 150,
	},
	-- A 40mm grenade: slower than a rocket, and it still drops, but it reaches now.
	--
	-- Oliver's #87, "make the grenade launcher launch grenades further". Measured through these very
	-- numbers at the live gravity (196.2), which is the arithmetic the server, the client's draw and
	-- the arc preview all share, so the figures below are the arcs he actually flies:
	--   was  speed 140, gravityScale 0.45 -> a LEVEL shot from eye height hit the ground at 45.1 studs
	--                                        (so a target sixty studs away needed guesswork), best arc 227
	--   now  speed 180, gravityScale 0.36 -> a level shot reaches 64.8 studs (+44%), best arc 463 (+104%)
	-- The level number is the one a player feels; the best arc is what a lobbed shot can reach.
	-- 200 / 0.34 was measured too (level 74.0, best arc 604) and deliberately NOT taken: it turns a
	-- grenade launcher into a 600-stud indirect weapon, which overshoots "further".
	grenade = {
		speed = 180,
		maxSpeed = 180,
		boostTime = 0,
		gravityScale = 0.36,
		radius = 0.22,
		maxTime = 5,
		armTime = 0.12,
		dudFuse = 0.8,
		restitution = 0.3,
		friction = 0.5,
		impactBonus = 12,
		innerRadius = 2.5,
		wallDamage = 110,
	},
}

function Ballistics.RegisterRound(kind, spec)
	assert(type(kind) == "string" and type(spec) == "table", "Ballistics.RegisterRound(kind, spec)")
	Ballistics.Rounds[kind] = spec
	return spec
end

-- Thrown items, keyed by ItemData id. Every one is thrown the same way (`speed` along the aim with a
-- little `lift`, plus `inherit` of the thrower's own run), bounces (`restitution`, `friction`) and
-- settles; `kind` says what it does.
--   frag    blows `fuse` seconds after the throw (less whatever was cooked off in the hand)
--   smoke   starts pouring smoke once it settles (or after `deployAfter` at most)
--   impact  bursts on the first thing it touches
--   sticky  sticks to the first thing it touches (a wall, a vehicle, a player) and rides with it;
--           blows `fuse` seconds after sticking. `stickOffset` is how far the model's origin sits
--           off the surface (its underside), for the stuck frame and the placement ghost.
Ballistics.Throwables = {
	CookedCoconut = {
		kind = "frag",
		speed = 85,
		lift = 0.1,
		inherit = 0.5,
		gravityScale = 0.5,
		radius = 0.42,
		restitution = 0.38,
		friction = 0.55,
		fuse = 3.2,
		cookable = true,
		blastDamage = 100,
		blastRadius = 13,
		innerRadius = 3.5,
		wallDamage = 120,
	},
	LowkeyLatte = {
		kind = "smoke",
		speed = 85,
		lift = 0.1,
		inherit = 0.5,
		gravityScale = 0.5,
		radius = 0.4,
		restitution = 0.22,
		friction = 0.7,
		deployAfter = 2.5,
		hiss = 0.6,
		smokeRadius = 16,
		grow = 2.2,
		hold = 14,
		fade = 4,
	},
	ClingyCrumpet = {
		kind = "sticky",
		speed = 82,
		lift = 0.12,
		inherit = 0.5,
		gravityScale = 0.55,
		radius = 0.45,
		restitution = 0,
		friction = 1,
		fuse = 2.5,
		stickOffset = 0.2,
		blastDamage = 110,
		blastRadius = 12,
		innerRadius = 3.5,
		wallDamage = 130,
	},
}

-- The frame of a stuck item: its origin `offset` off the surface point along the normal, its +Y along
-- the normal (underside on the surface), turned so it sits square to the world rather than to the
-- throw. The live model, the placement ghost and the gallery all place a stuck thing with this.
function Ballistics.StuckFrame(position, normal, offset)
	local up = normal.Magnitude > 1e-4 and normal.Unit or UP
	local reference = math.abs(up.Y) < 0.99 and UP or Vector3.xAxis
	local right = reference:Cross(up).Unit
	return CFrame.fromMatrix(position + up * (offset or 0), right, up, right:Cross(up))
end

-- A body this close to the blast counts as touching it: distances are measured from the root, and a
-- rocket at your feet is a metre or so from it.
Ballistics.BodyAllowance = 1.2
-- Damage at the very edge of the blast radius, as a share of full.
Ballistics.EdgeScale = 0.2
-- Smoke you can see through: a line with less than this much dense smoke on it isn't hidden.
Ballistics.SeeThrough = 6
-- Below this share of full density, a thinning cloud no longer hides anything.
Ballistics.HidingDensity = 0.5

-- A normal speed below this doesn't bounce: the body slides instead. Below `REST_SPEED` on the
-- ground, it stops.
local SLIDE_SPEED = 8
local REST_SPEED = 2.5
-- How far off a surface a body is left after touching it, so the next cast doesn't start inside it.
local SKIN = 0.02

--------------------------------------------------------------------------------
-- Launcher rounds
--------------------------------------------------------------------------------

-- Distance along the line and speed along it at time t.
local function travel(spec, t)
	local boost = spec.boostTime or 0
	local v0, v1 = spec.speed, spec.maxSpeed or spec.speed
	if boost <= 0 or v1 == v0 then
		return v0 * t, v0
	end
	local accel = (v1 - v0) / boost
	if t <= boost then
		return v0 * t + 0.5 * accel * t * t, v0 + accel * t
	end
	return v0 * boost + 0.5 * accel * boost * boost + v1 * (t - boost), v1
end

-- Where a round launched from `origin` along the unit `direction` is at time t, and its velocity.
function Ballistics.RoundState(spec, origin, direction, gravity, t)
	local g = gravity * spec.gravityScale
	local distance, speed = travel(spec, t)
	return origin + direction * distance - UP * (0.5 * g * t * t), direction * speed - UP * (g * t)
end

-- One step of a "free" round (one that steers): the kind's own `steer` with `api`, then gravity,
-- integrated the one way everyone integrates it. Returns the new position and velocity without
-- assigning them, since the server sweeps from the old position to the new one before it moves.
-- The server, the client's replay and the probe all step through here, so with the same dt and
-- the same targets they trace the same path.
function Ballistics.FreeStep(entry, dt, gravity, api)
	local spec = entry.spec
	if spec.steer then
		spec.steer(entry, dt, api)
	end
	local velocity = entry.velocity - UP * (gravity * (spec.gravityScale or 0) * dt)
	local position = entry.position + (entry.velocity + velocity) * (dt / 2)
	return position, velocity
end

-- How a round sits in the air, from its look's `spin` (see ThrowableModels' contract):
--   "none"   nose (-Z) along its velocity
--   "roll"   nose along its velocity, rolled about it by `angle`
--   "flat"   level, nose along the flat part of its velocity, spun about the up axis by `angle`
-- ("tumble" is a bouncing body's own rotation and isn't built here.)
function Ballistics.RoundOrientation(spin, position, velocity, angle)
	local speed = velocity.Magnitude
	local forward = speed > 1e-3 and velocity / speed or -Vector3.zAxis
	if spin == "flat" then
		local flat = Vector3.new(forward.X, 0, forward.Z)
		flat = flat.Magnitude > 1e-3 and flat.Unit or -Vector3.zAxis
		return CFrame.lookAt(position, position + flat, UP) * CFrame.Angles(0, angle or 0, 0)
	elseif spin == "roll" then
		return CFrame.lookAt(position, position + forward) * CFrame.Angles(0, 0, angle or 0)
	end
	local up = math.abs(forward.Y) > 0.98 and Vector3.xAxis or UP
	return CFrame.lookAt(position, position + forward, up)
end

-- How fast each spin turns, in radians a second.
Ballistics.SpinRate = { flat = 22, roll = 30 }

-- The time at which a round has gone `distance` along its line (the inverse of `travel`).
function Ballistics.RoundTimeFor(spec, distance)
	local boost = spec.boostTime or 0
	local v0, v1 = spec.speed, spec.maxSpeed or spec.speed
	if boost <= 0 or v1 == v0 then
		return distance / v0
	end
	local accel = (v1 - v0) / boost
	local boosted = v0 * boost + 0.5 * accel * boost * boost
	if distance <= boosted then
		return (-v0 + math.sqrt(v0 * v0 + 2 * accel * distance)) / accel
	end
	return boost + (distance - boosted) / v1
end

-- A point to aim at from `origin` so a round meets a target now at `target` moving at `targetVelocity`:
-- ahead of it by the flight time, and above it by the drop over that time. The line the round is fired
-- along goes through the returned point. A few rounds of refinement settle it for anything in range.
function Ballistics.LeadAim(spec, origin, target, targetVelocity, gravity)
	local g = gravity * spec.gravityScale
	local velocity = targetVelocity or Vector3.zero
	local t = Ballistics.RoundTimeFor(spec, (target - origin).Magnitude)
	local line = target - origin
	for _ = 1, 6 do
		local predicted = target + velocity * t
		line = predicted - origin + UP * (0.5 * g * t * t)
		t = Ballistics.RoundTimeFor(spec, line.Magnitude)
	end
	return origin + line
end

--------------------------------------------------------------------------------
-- Thrown items
--------------------------------------------------------------------------------

-- The aim line from the head, lifted a touch, so the arc rises through the crosshair.
function Ballistics.ThrowDirection(spec, head, aimPoint)
	local offset = aimPoint - head
	local direction = offset.Magnitude > 0.01 and offset.Unit or -Vector3.zAxis
	return (direction + UP * (spec.lift or 0)).Unit
end

function Ballistics.ThrowOrigin(head, direction)
	return head + direction * 1.2
end

-- The fastest a thrower's own run is taken to be: MatchConfig.BaseWalkSpeed 18 x SprintMultiplier 1.45 x
-- MovementConfig.Slide.PeakMultiplier 1.75 = 45.7, a flat-out slide. A player's root velocity is written
-- by their own client, so uncapped a modified client could report any speed and throw a grenade across the
-- map; faster legitimate carriers (a boosted sprint, a passenger in a car) carry this much and no more.
-- tools/throw_carry_check.py keeps this in step with those three numbers.
Ballistics.MaxCarrierSpeed = 46

-- The part of a thrower's velocity a throw inherits before `inherit` scales it: horizontal only, and never
-- faster than MaxCarrierSpeed. Anything that isn't a finite velocity carries nothing.
function Ballistics.CarrierVelocity(velocity)
	if not velocity then
		return Vector3.zero
	end
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	if speed ~= speed or speed == math.huge then
		return Vector3.zero
	end
	if speed > Ballistics.MaxCarrierSpeed then
		return flat * (Ballistics.MaxCarrierSpeed / speed)
	end
	return flat
end

-- The launch velocity of a throw toward `aimPoint` from a head at `head`, by someone moving at
-- `carrierVelocity` (its horizontal part, capped, carries into the throw: CarrierVelocity).
function Ballistics.ThrowVelocity(spec, head, aimPoint, carrierVelocity)
	local direction = Ballistics.ThrowDirection(spec, head, aimPoint)
	return direction * spec.speed + Ballistics.CarrierVelocity(carrierVelocity) * (spec.inherit or 0)
end

-- A lob from `origin` that comes down on `target`: longer throws hang longer. For bots, which know
-- where they want it rather than where they're looking.
function Ballistics.LobVelocity(origin, target, gravity, gravityScale)
	local g = gravity * (gravityScale or 1)
	local offset = target - origin
	local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
	local t = math.clamp(flat / 45, 0.45, 1.6)
	return Vector3.new(offset.X / t, offset.Y / t + 0.5 * g * t, offset.Z / t), t
end

-- One step of a thrown body. `body` is { position, velocity, spec, resting }; `cast(origin, radius,
-- displacement)` sweeps a sphere and returns what it hit ({ Position, Normal, Distance, Instance }) or
-- nil, and is where the caller decides what counts as solid (the server breaks glass inside it and
-- sweeps on). Returns the strongest contact this step as { position, normal, speed, instance }, or nil.
--
-- Up to three contacts are resolved in one step, so a body dropped into a corner doesn't stall a frame
-- per wall. A contact reflects the normal part of the velocity by `restitution` (or kills it below
-- SLIDE_SPEED, which is what turns a bounce into a slide) and takes `friction` off the tangential part
-- in proportion to how hard it landed, which is what makes a rolling grenade slow down on the ground.
function Ballistics.StepBody(body, dt, gravity, cast)
	if body.resting then
		return nil
	end
	local spec = body.spec
	local g = gravity * (spec.gravityScale or 1)
	-- A kind may bounce without saying how (a "bounce" verdict from a round with no numbers).
	local restitution = spec.restitution or 0.3
	local friction = spec.friction or 0.5
	local remaining = dt
	local strongest = nil

	for _ = 1, 3 do
		if remaining <= 1e-5 then
			break
		end
		local velocity = body.velocity
		local displacement = velocity * remaining - UP * (0.5 * g * remaining * remaining)
		local length = displacement.Magnitude
		if length < 1e-5 then
			body.velocity = velocity - UP * (g * remaining)
			break
		end
		local hit = cast(body.position, spec.radius, displacement)
		if not hit then
			body.position += displacement
			body.velocity = velocity - UP * (g * remaining)
			break
		end

		local fraction = math.clamp(hit.Distance / length, 0, 1)
		local elapsed = remaining * fraction
		body.position += displacement.Unit * math.max(0, hit.Distance - SKIN)
		velocity -= UP * (g * elapsed)
		remaining -= elapsed

		local normal = hit.Normal
		local into = velocity:Dot(normal)
		if into < 0 then
			local tangent = velocity - normal * into
			local bounce = -into > SLIDE_SPEED and -into * restitution or 0
			local grip = math.clamp(friction * (-into / 20), 0, 0.9)
			velocity = tangent * (1 - grip) + normal * bounce
			if not strongest or -into > strongest.speed then
				strongest = { position = hit.Position, normal = normal, speed = -into, instance = hit.Instance }
			end
		end
		body.position += normal * SKIN
		body.velocity = velocity

		-- Settled on something flat enough to lie on.
		if normal.Y > 0.6 and velocity.Magnitude < REST_SPEED then
			body.velocity = Vector3.zero
			body.resting = true
			break
		end
	end
	return strongest
end

--------------------------------------------------------------------------------
-- Blasts
--------------------------------------------------------------------------------

-- Full damage inside `innerRadius`, falling in a straight line to EdgeScale at `radius`, nothing past
-- it. `distance` is from the blast to the body with BodyAllowance already taken off.
function Ballistics.BlastScale(distance, innerRadius, radius)
	if distance > radius then
		return 0
	end
	if distance <= innerRadius or radius <= innerRadius then
		return 1
	end
	local t = (distance - innerRadius) / (radius - innerRadius)
	return 1 - t * (1 - Ballistics.EdgeScale)
end

--------------------------------------------------------------------------------
-- Smoke
--------------------------------------------------------------------------------

-- A cloud is { position, startedAt, spec }: `startedAt` is when it began pouring (after the hiss).

local function smoothstep(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function Ballistics.SmokeRadius(cloud, now)
	local spec = cloud.spec
	return spec.smokeRadius * (0.25 + 0.75 * smoothstep((now - cloud.startedAt) / spec.grow))
end

-- 0 before it starts and after it's gone, 1 while it holds.
function Ballistics.SmokeDensity(cloud, now)
	local spec = cloud.spec
	local age = now - cloud.startedAt
	if age < 0 then
		return 0
	end
	local fill = smoothstep(age / (spec.grow * 0.6))
	local thin = 1 - smoothstep((age - spec.grow - spec.hold) / spec.fade)
	return math.min(fill, thin)
end

function Ballistics.SmokeEndsAt(cloud)
	local spec = cloud.spec
	return cloud.startedAt + spec.grow + spec.hold + spec.fade
end

-- How many studs of the line from `a` to `b` pass through this cloud while it's dense enough to hide
-- anything (0 otherwise). A sphere, measured exactly: the chord of the segment inside it.
function Ballistics.SmokeChord(cloud, a, b, now)
	if Ballistics.SmokeDensity(cloud, now) < Ballistics.HidingDensity then
		return 0
	end
	local radius = Ballistics.SmokeRadius(cloud, now)
	local line = b - a
	local length = line.Magnitude
	if length < 1e-4 then
		return 0
	end
	local unit = line / length
	local toCentre = cloud.position - a
	local along = toCentre:Dot(unit)
	local missSquared = toCentre:Dot(toCentre) - along * along
	if missSquared >= radius * radius then
		return 0
	end
	local half = math.sqrt(radius * radius - missSquared)
	local enter = math.max(0, along - half)
	local exit = math.min(length, along + half)
	return math.max(0, exit - enter)
end

--------------------------------------------------------------------------------
-- The gun rework's rounds (2026-09-24): the three new guns' own kinds
--------------------------------------------------------------------------------
-- Registered here rather than in a module of their own, so they exist wherever Ballistics is loaded:
-- the server before ProjectileService looks one up, and every client that draws them. Their models are
-- hand-built in GunModelsRounds (ThrowableModels.RoundBuilders); `look` is the fallback if that module is
-- not loaded.
--
--   mosquitoDart  Zanzarino Pikpik. A fast little dart with next to no drop that noses toward whoever is
--                 most nearly ahead of it, gently: inside a 10-degree cone, 6 degrees at most over its
--                 flight, so it forgives a near miss and never turns a wide miss into a hit.
--                 Non-explosive; the gun's `bleed` (the itch) comes from its WeaponData.
--   drumlet       Tamburo Tung Tung. A little drum lobbed with a kick upward. It bounces and goes off on
--                 its third contact, on anyone it touches, or 1.6 s after launch, whichever comes first.
--                 Three a shot, fanned (CombatService.Patterns.fan).
--   bananerang    Bananerang. Thrown out, it slows to a hang at the far end of its reach and comes back
--                 along the same curve (a slight bend to the right) to where it was thrown. It passes
--                 through people and cuts each one once on the way out and once on the way back; a wall
--                 stops it. Its path is a function of its age alone (Ballistics.BoomerangVelocity), so
--                 every client traces exactly the server's path.
--
-- `steer` runs on clients too and stays pure (see CreativeRounds). The boomerang's steer also clears, on
-- the server only, the people it passed through from its sweep filter as it turns, so it can meet them
-- again on the way back; that touches the filter, never the path.

local function roundHitInstance(contact)
	return contact and (contact.Instance or contact.instance) or nil
end

local function roundHitsCharacter(instance)
	local model = instance and instance:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- Homing: gently, and only toward someone already nearly in line.
Ballistics.DartHoming = { delay = 0.06, cone = math.rad(10), total = math.rad(6), rate = math.rad(60), range = 80 }

Ballistics.RegisterRound("mosquitoDart", {
	motion = "free",
	speed = 175,
	gravityScale = 0.05,
	radius = 0.18,
	maxTime = 1.6,
	explosive = false,
	impactBonus = 0,
	syncEvery = 0.1,
	look = { shape = "cylinder", size = 0.6, color = Color3.fromRGB(40, 40, 46), trim = Color3.fromRGB(240, 240, 240), spin = "none" },
	steer = function(entry, dt, api)
		local homing = Ballistics.DartHoming
		local turned = type(entry.turned) == "number" and entry.turned or 0
		if entry.age < homing.delay or turned >= homing.total then
			return
		end
		local speed = entry.velocity.Magnitude
		if speed < 1 then
			return
		end
		local forward = entry.velocity / speed
		local best, bestDot = nil, math.cos(homing.cone)
		for _, target in ipairs(api.Targets(entry.position, homing.range, entry.owner)) do
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
		local turn = math.min(angle, homing.rate * dt, homing.total - turned)
		if angle <= 1e-4 or turn <= 0 then
			return
		end
		entry.turned = turned + turn
		entry.velocity = forward:Lerp(best, turn / angle).Unit * speed
	end,
	onContact = function(_entry, contact)
		if roundHitsCharacter(roundHitInstance(contact)) then
			return "detonate"
		end
		return "stop"
	end,
})

Ballistics.DrumletLift = 16

Ballistics.RegisterRound("drumlet", {
	motion = "body",
	speed = 115,
	gravityScale = 0.9,
	radius = 0.26,
	maxTime = 3,
	fuse = 1.6,
	maxBounces = 3,
	restitution = 0.55,
	friction = 0.35,
	impactBonus = 4,
	innerRadius = 1.5,
	wallDamage = 40,
	look = { shape = "cylinder", size = 0.5, color = Color3.fromRGB(200, 40, 50), trim = Color3.fromRGB(245, 240, 230), spin = "tumble" },
	onLaunch = function(entry)
		if entry.body then
			entry.body.velocity += Vector3.new(0, Ballistics.DrumletLift, 0)
		end
	end,
	onContact = function(_entry, contact)
		if roundHitsCharacter(roundHitInstance(contact)) then
			return "detonate"
		end
		return nil
	end,
})

-- The boomerang's flight: out along the throw, slowing to a hang at the far end (the reach is
-- speed x time / pi), and back the same way, bent `curve` x the reach to the right at the far end.
-- Past `catch` of its time it is back at the thrower's end: its time running out there is a catch.
Ballistics.Boomerang = { time = 1.5, curve = 0.1, catch = 0.9 }

-- The velocity of a boomerang `age` seconds after it was thrown along `memory.dir` at `memory.speed`.
function Ballistics.BoomerangVelocity(memory, age)
	local spec = Ballistics.Boomerang
	local u = math.clamp(age / spec.time, 0, 1)
	return memory.dir * (memory.speed * math.cos(math.pi * u))
		+ memory.side * (memory.speed * spec.curve * math.sin(2 * math.pi * u))
end

-- The boomerang's memory, from the velocity it was thrown with.
function Ballistics.BoomerangMemory(velocity)
	local speed = velocity.Magnitude
	local dir = speed > 1e-3 and velocity / speed or -Vector3.zAxis
	local reference = math.abs(dir.Y) > 0.95 and Vector3.xAxis or UP
	return { dir = dir, side = dir:Cross(reference).Unit, speed = speed }
end

Ballistics.RegisterRound("bananerang", {
	motion = "free",
	speed = 115,
	gravityScale = 0,
	radius = 0.45,
	maxTime = Ballistics.Boomerang.time,
	explosive = false,
	impactBonus = 0,
	syncEvery = 0.12,
	look = { shape = "disc", size = 1.1, color = Color3.fromRGB(250, 214, 60), glow = Color3.fromRGB(255, 240, 140), spin = "flat" },
	steer = function(entry, dt)
		local memory = entry.turned
		if type(memory) ~= "table" then
			memory = Ballistics.BoomerangMemory(entry.velocity)
			entry.turned = memory
			-- Server only: what the sweep filter held at the throw (the thrower), kept through the turn.
			if type(entry.filter) == "table" then
				memory.base = #entry.filter
			end
		end
		-- Sampled mid-step, so the stepped path keeps to the exact one.
		entry.velocity = Ballistics.BoomerangVelocity(memory, math.max(0, entry.age - dt / 2))
		if memory.base and not memory.back and entry.age >= Ballistics.Boomerang.time / 2 then
			memory.back = true
			for index = #entry.filter, memory.base + 1, -1 do
				table.remove(entry.filter, index)
			end
			entry.params.FilterDescendantsInstances = entry.filter
		end
	end,
	onContact = function(entry, contact, api)
		local instance = roundHitInstance(contact)
		if not roundHitsCharacter(instance) then
			return "detonate"
		end
		local pass = entry.age < Ballistics.Boomerang.time / 2 and 1 or 2
		entry.cut = entry.cut or {}
		local at = contact.Position or contact.position
		for _, target in ipairs(api.Targets(at, 10, entry.owner)) do
			local character = target.root.Parent
			if character and instance:IsDescendantOf(character) then
				if entry.cut[target.token] ~= pass then
					entry.cut[target.token] = pass
					-- Credited as a burst credits its hit: to nobody once the thrower has left.
					local attacker = entry.owner
					if api.Creditable then
						attacker = api.Creditable(entry.owner)
					end
					api.DealDamage(attacker, target.token, entry.damage, entry.weaponId, false)
				end
				break
			end
		end
		return "pass"
	end,
	onDetonate = function(entry, blast)
		if not blast.direct and entry.age >= Ballistics.Boomerang.time * Ballistics.Boomerang.catch then
			return false
		end
		return nil
	end,
})

return Ballistics
