-- How a bot at the wheel drives near enemies (Oliver, 2026-09-24: "the bots need to be more strategic
-- about where and how they drive too, especially when driving near enemies").
--
-- BotNav's DRIVING section is HOW a car gets from here to a point (roads, obstacles, water, drops,
-- stuck recovery). This module is WHERE to point it and WHEN to get out, made from what the bot knows:
-- the hostiles it has seen or been shot by, the manned guns about, its vehicle's health and speed. It
-- is pure decisions over plain tables (no Instances, no queries of its own): BotService's driverThink
-- gathers the context, calls T.Think once per think, and applies the plan. tools/bot_driving_tactics_check.py
-- runs this file whole against BotNav's real driving and VehicleDynamics' real handling, in scenarios
-- with enemies that shoot back.
--
-- In order of precedence, per think:
--   bail      the car is about to be wrecked: its health under BAIL_HEALTH, or under what the biggest
--             single hit of the last few seconds would take off (a rocket takes a fifth at once, so
--             waiting for 15% is waiting to die in it). Out on the side away from the shooter.
--   unstick   stuck or lost: once, back off and go round (a detour point to the side, the roads
--             toggled); stuck again within STUCK_SAME studs of the same spot, give the car up and shun
--             it, so a bot never loops against one obstacle.
--   evade     just hit: turn off the line of fire (50 degrees from straight away, to the side nearer
--             the heading, so no U-turn stall) and floor it, for EVADE_FOR seconds.
--   retreat   under RETREAT_HEALTH with a hostile about: away from them.
--   ram       only when it pays: the target is on foot, the car has RAM_HEALTH, nobody else hostile
--             stands near the approach or the target (a crowd, or a friend covering them), and no
--             manned gun covers the target. Aimed through the target, led by its run, committed for
--             RAM_COMMIT seconds.
--   crowd     CROWD_COUNT hostiles together: never into them. An armed car with a gunner circles
--             them at CROWD_KEEP; anything else goes round (or away).
--   orbit     an armed car with its gunner: round the target at the gun's range so the gun can work,
--             moving (a parked car is the easiest thing on the map to hit); the circle flips when the
--             target has been out of the gunner's arc for ARC_FLIP seconds (the driver holds the
--             gunner's firing line).
--   broadside no gun, a hostile within DISMOUNT_RANGE: turn side-on to them, stop, and get out on the
--             far side, the car between the bot and the shooter.
--   travel    anywhere else: to the goal, going round the nearest known hostile's reach (EXPOSE_RADIUS)
--             or a manned gun's field of fire when the straight line crosses it, on the side that has
--             something between the detour and the shooter where there is one (SIGHTS rays, only when
--             the detour is worked out again). Stopped in view of a hostile for PARK_EXPOSED seconds:
--             out, on the far side.
--
-- COST. Arithmetic over the hostiles within reach (BotService passes at most MAX_ENEMIES) and the
-- guns about, plus at most SIGHTS sight rays when a detour is (re)chosen, which is at most every
-- REPLAN_EVERY seconds or when the goal or the hostile moves.

local T = {}

T.BAIL_HEALTH = 0.15
T.BURST_MEMORY = 6        -- seconds a big hit is remembered for the bail line
T.BURST_MARGIN = 1.15     -- ...and the bail line sits this much over it
T.BURST_CAP = 0.45        -- the bail line never climbs past this
T.RETREAT_HEALTH = 0.35
T.RAM_HEALTH = 0.5
T.RAM_RANGE = 140         -- a lone body on foot this close is run down rather than driven round
T.RAM_MIN = 14            -- closer than this a ram is not started (no run-up); one under way carries on
T.RAM_CLEAR = 35          -- no other hostile this close to the approach line or the target
T.RAM_COMMIT = 5
T.RAM_THROUGH = 25        -- studs past the target the ram is aimed
T.CROWD_RADIUS = 45
T.CROWD_COUNT = 3
T.CROWD_KEEP = 130
T.EXPOSE_RADIUS = 150     -- a known hostile's reach, for the route
T.GUN_MARGIN = 20         -- studs outside a gun's range a detour keeps
T.DETOUR_OUT = 1.15       -- a detour point this far out past a reach
T.EVADE_FOR = 2.5
T.EVADE_HIT = 0.03        -- a single drop this big (a share of the vehicle) is a hit worth turning away from
T.EVADE_HEAT = 0.06       -- ...and so is this much in the last second or so of steady fire
T.EVADE_TURN = math.rad(50)
T.EVADE_DISTANCE = 140
T.DISMOUNT_RANGE = 45
T.BROADSIDE_COS = 0.5     -- |cos| between heading and the hostile under this is side-on enough
T.BROADSIDE_WAIT = 3
T.STUCK_SAME = 30
T.STUCK_MEMORY = 90
T.STUCK_SHUN = 60
T.PARK_EXPOSED = 2
T.PARK_RANGE = 150
T.ARC_FLIP = 1.5
T.REPLAN_EVERY = 3
T.SIGHTS = 2
T.MAX_ENEMIES = 12
T.GUN_RANGE = { hitscan = 70, rocket = 80, grenade = 200 }

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function unit(v, fallback)
	if v.Magnitude < 1e-3 then
		return fallback
	end
	return v.Unit
end

local function rightOf(d)
	return Vector3.new(-d.Z, 0, d.X)
end

local function turn(d, angle)
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(d.X * c - d.Z * s, 0, d.Z * c + d.X * s)
end

-- Closest point to `p` on the segment a..b, and the share along it.
local function closestOnSegment(a, b, p)
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-6 then
		return a, 0
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return a + ab * t, t
end

function T.new()
	return { stuckSpots = {}, detourSide = 1 }
end

local function leave(reason, dismount, cooldown, shun)
	return { mode = "leave", leave = reason, dismount = dismount, cooldown = cooldown, shun = shun }
end

-- Where to get out: beside the car, on the far side from `threat`.
local function farSide(ctx, threat)
	if not threat then
		return nil
	end
	local away = unit(ctx.pos - flat(threat), -ctx.look)
	return ctx.pos + away * ((ctx.halfWidth or 3) + 3)
end

-- The hostiles within `radius` of `point` (not counting `except`), and their middle.
local function around(enemies, point, radius, except)
	local count, sum = 0, Vector3.new(0, 0, 0)
	for _, enemy in ipairs(enemies) do
		if enemy ~= except and (enemy.pos - point).Magnitude <= radius then
			count = count + 1
			sum = sum + enemy.pos
		end
	end
	return count, count > 0 and sum / count or nil
end

-- A gun's field of fire covers `point`.
local function gunCovers(gun, point, margin)
	local to = point - gun.pos
	local distance = to.Magnitude
	if distance > gun.range + (margin or 0) then
		return false
	end
	if distance < 1 or not gun.facing or (gun.cosArc or -1) <= -1 then
		return true
	end
	return gun.facing:Dot(to / distance) >= gun.cosArc
end

-- The first reach (a hostile's, a manned gun's) the leg from..to runs through, nearest `from` first.
local function firstThreat(ctx, from, to, crowd)
	local best, bestT = nil, math.huge
	if crowd then
		local radius = T.CROWD_KEEP + T.CROWD_RADIUS
		local point, t = closestOnSegment(from, to, crowd)
		if (point - crowd).Magnitude < radius then
			best, bestT = { centre = crowd, radius = radius, eye = crowd }, t
		end
	end
	for _, enemy in ipairs(ctx.enemies) do
		local point, t = closestOnSegment(from, to, enemy.pos)
		if (point - enemy.pos).Magnitude < T.EXPOSE_RADIUS and t < bestT
			and not (crowd and (enemy.pos - crowd).Magnitude < T.CROWD_RADIUS * 1.5)
			and (to - enemy.pos).Magnitude > T.EXPOSE_RADIUS * 0.5 then
			best, bestT = { centre = enemy.pos, radius = T.EXPOSE_RADIUS, eye = enemy.pos }, t
		end
	end
	for _, gun in ipairs(ctx.guns or {}) do
		local point, t = closestOnSegment(from, to, gun.pos)
		if gunCovers(gun, point, T.GUN_MARGIN) and t < bestT then
			best, bestT = { centre = gun.pos, radius = gun.range + T.GUN_MARGIN, eye = gun.pos }, t
		end
	end
	return best
end

local function inBounds(ctx, point)
	local b = ctx.bounds
	return not b or (flat(point) - flat(b.center)).Magnitude <= b.radius
end

-- A point to go by that keeps the leg pos..goal out of `threat`'s reach: out from the threat square
-- to the leg, on the side the leg already passes (or the car is on), or the other; the one with cover
-- from the threat's eye first (ctx.sight, SIGHTS rays at most).
local function detourAround(state, ctx, threat, goal)
	local closest = closestOnSegment(ctx.pos, goal, threat.centre)
	local out = closest - threat.centre
	local along = unit(goal - ctx.pos, ctx.look)
	if out.Magnitude < 2 then
		out = rightOf(along) * (rightOf(along):Dot(ctx.pos - threat.centre) >= 0 and 1 or -1)
	end
	out = out.Unit
	local reach = threat.radius * T.DETOUR_OUT
	local first = threat.centre + out * reach
	local second = threat.centre - out * reach
	local options = {}
	if inBounds(ctx, first) then
		table.insert(options, first)
	end
	if inBounds(ctx, second) then
		table.insert(options, second)
	end
	if #options == 0 then
		return nil
	end
	if ctx.sight then
		for index = 1, math.min(#options, T.SIGHTS) do
			local point = options[index]
			state.sights = (state.sights or 0) + 1
			if not ctx.sight(threat.eye, point) then
				return point
			end
		end
	end
	return options[1]
end

-- The way to `goal`, round what it knows of: nil (straight) or a via point, kept between looks.
local function coverVia(state, ctx, goal, crowd)
	local now = ctx.now
	local cached = state.via
	if cached and now < cached.untilTime and (cached.goal - goal).Magnitude < 40 then
		if not cached.point then
			return nil, false
		end
		-- Past the detour point (or it is behind the car): straight on from here.
		if (cached.point - ctx.pos).Magnitude < 25 or (cached.point - ctx.pos):Dot(goal - ctx.pos) < 0 then
			state.via = { goal = goal, point = nil, untilTime = cached.untilTime }
			return nil, true
		end
		return cached.point, false
	end
	local threat = firstThreat(ctx, ctx.pos, goal, crowd)
	local point = threat and detourAround(state, ctx, threat, goal) or nil
	local changed = not cached or cached.point ~= point
	if cached and cached.point and point and (cached.point - point).Magnitude < 30 then
		point = cached.point
		changed = false
	end
	state.via = { goal = goal, point = point, untilTime = now + T.REPLAN_EVERY }
	return point, changed
end

-- Round `centre` at `range`, a little ahead of where the car is on that circle.
local function orbitGoal(state, ctx, centre, range)
	local away = unit(ctx.pos - centre, -ctx.look)
	if not state.orbit or ctx.now > (state.orbitFlipAt or 0) then
		state.orbit = state.orbit and -state.orbit or (ctx.random() < 0.5 and 1 or -1)
		state.orbitFlipAt = ctx.now + 12 + ctx.random() * 8
	end
	return centre + turn(away, state.orbit * math.rad(35)) * range
end

local function nearestEnemy(ctx)
	local best, bestDistance = nil, math.huge
	for _, enemy in ipairs(ctx.enemies) do
		local distance = (enemy.pos - ctx.pos).Magnitude
		if distance < bestDistance then
			best, bestDistance = enemy, distance
		end
	end
	return best, bestDistance
end

-- Ramming pays: on foot, the car fit for it, nobody else near the target or the approach, no gun on it.
function T.RamFavourable(ctx, target)
	if not target or not target.onFoot or ctx.health < T.RAM_HEALTH then
		return false
	end
	for _, enemy in ipairs(ctx.enemies) do
		if enemy ~= target then
			if (enemy.pos - target.pos).Magnitude < T.RAM_CLEAR then
				return false
			end
			local point = closestOnSegment(ctx.pos, target.pos, enemy.pos)
			if (point - enemy.pos).Magnitude < T.RAM_CLEAR then
				return false
			end
		end
	end
	for _, gun in ipairs(ctx.guns or {}) do
		if gunCovers(gun, target.pos, 0) then
			return false
		end
	end
	return true
end

-- One decision. `ctx`: now, pos/look (flat), speed, health (0..1), halfWidth, armed, gunner (its gun
-- seat manned), gunKind ("hitscan"/"rocket"/"grenade"), goal/arrive (where it is going, or nil),
-- enemies { pos, vel, onFoot, token, seen }, target (one of enemies, or nil), guns { pos, facing,
-- cosArc, range }, shotAt/threatPos (the last shot at the bot itself), status (DriveSense's last),
-- inArc(point) for the gunner's mount, sight(from, to) -> true when clear, bounds, random().
-- Returns { mode, goal, options, via, replan, ram, leave, dismount, cooldown, shun }.
function T.Think(state, ctx)
	local now = ctx.now
	ctx.random = ctx.random or math.random
	local enemies = ctx.enemies

	-- Incoming fire: the vehicle's health dropping, or a shot at the bot itself.
	local last = state.lastHealth or ctx.health
	local elapsed = math.clamp(now - (state.thoughtAt or now), 0, 2)
	state.thoughtAt = now
	state.heat = (state.heat or 0) * (0.4 ^ elapsed)
	if ctx.health < last - 0.005 then
		local size = last - ctx.health
		state.hitAt = now
		if not state.bigHitAt or now - state.bigHitAt > T.BURST_MEMORY or size > state.bigHit then
			state.bigHit, state.bigHitAt = size, now
		end
		state.heat = state.heat + size
		if size >= T.EVADE_HIT or state.heat >= T.EVADE_HEAT then
			state.evadeAt = now
			state.heat = 0
		end
	end
	state.lastHealth = ctx.health
	if ctx.shotAt and ctx.shotAt > (state.hitAt or -math.huge) then
		state.hitAt = ctx.shotAt
		state.evadeAt = ctx.shotAt
	end
	local nearest, nearestDistance = nearestEnemy(ctx)
	local threatPos = ctx.threatPos or (nearest and nearest.pos)
	local underFire = state.hitAt ~= nil and now - state.hitAt < T.BURST_MEMORY

	-- bail
	local bailLine = T.BAIL_HEALTH
	if underFire and state.bigHitAt and now - state.bigHitAt < T.BURST_MEMORY then
		bailLine = math.max(bailLine, math.min(T.BURST_CAP, state.bigHit * T.BURST_MARGIN))
	end
	if ctx.health < bailLine then
		return leave("wrecked", farSide(ctx, threatPos))
	end

	-- unstick
	local status = ctx.status
	if status == "flipped" then
		return leave("flipped", farSide(ctx, threatPos))
	end
	if status == "stuck" or status == "lost" then
		local spots = state.stuckSpots
		for index = #spots, 1, -1 do
			if now - spots[index].at > T.STUCK_MEMORY then
				table.remove(spots, index)
			end
		end
		for _, spot in ipairs(spots) do
			if (spot.pos - ctx.pos).Magnitude < T.STUCK_SAME then
				return leave(status, farSide(ctx, threatPos), 30, T.STUCK_SHUN)
			end
		end
		table.insert(spots, { pos = ctx.pos, at = now })
		state.detourSide = -(state.detourSide or 1)
		local point = ctx.pos - ctx.look * 12 + rightOf(ctx.look) * (state.detourSide * 35)
		state.unstick = { point = point, untilTime = now + 8 }
		state.via = nil
		state.ram = nil
	end
	if state.unstick and (now > state.unstick.untilTime or (state.unstick.point - ctx.pos).Magnitude < 12) then
		state.unstick = nil
	end

	-- evade
	local closing = ctx.target and not ctx.armed and (ctx.target.pos - ctx.pos).Magnitude < T.DISMOUNT_RANGE
	if state.evadeAt and now - state.evadeAt < T.EVADE_FOR and threatPos and not closing
		and not (state.ram and now < state.ram.untilTime) then
		if not state.evade or state.evade.from ~= state.evadeAt then
			local away = unit(ctx.pos - flat(threatPos), ctx.look)
			local a, b = turn(away, T.EVADE_TURN), turn(away, -T.EVADE_TURN)
			local dir = a:Dot(ctx.look) >= b:Dot(ctx.look) and a or b
			state.evade = { from = state.evadeAt, goal = ctx.pos + dir * T.EVADE_DISTANCE }
			state.evadeCount = (state.evadeCount or 0) + 1
		end
		return { mode = "evade", goal = state.evade.goal, options = { arrive = 10 } }
	end

	-- retreat
	if ctx.health < T.RETREAT_HEALTH and nearest and nearestDistance < T.EXPOSE_RADIUS * 1.5 then
		local _, middle = around(enemies, ctx.pos, T.EXPOSE_RADIUS * 1.5)
		local away = unit(ctx.pos - (middle or nearest.pos), ctx.look)
		return { mode = "retreat", goal = ctx.pos + away * 220, options = { arrive = 25 } }
	end

	-- ram
	local target = ctx.target
	if state.ram then
		local keep = now < state.ram.untilTime and target and target.token == state.ram.token and target.onFoot
			and ctx.health >= T.RAM_HEALTH
		if not keep then
			state.ram = nil
		end
	end
	if not state.ram and target and T.RamFavourable(ctx, target) then
		local distance = (target.pos - ctx.pos).Magnitude
		if distance >= T.RAM_MIN and distance <= T.RAM_RANGE then
			state.ram = { token = target.token, untilTime = now + T.RAM_COMMIT }
			state.rams = (state.rams or 0) + 1
		end
	end
	if state.ram and target then
		local distance = (target.pos - ctx.pos).Magnitude
		local lead = math.min(1, distance / math.max(20, ctx.speed))
		local aim = target.pos + flat(target.vel or Vector3.new(0, 0, 0)) * lead
		local through = aim + unit(aim - ctx.pos, ctx.look) * T.RAM_THROUGH
		return { mode = "ram", goal = through, options = { arrive = 4 }, ram = target }
	end

	-- crowd
	local crowdCount, crowdMiddle = 0, nil
	if target then
		crowdCount, crowdMiddle = around(enemies, target.pos, T.CROWD_RADIUS)
	elseif nearest then
		crowdCount, crowdMiddle = around(enemies, nearest.pos, T.CROWD_RADIUS)
	end
	local crowded = crowdCount >= T.CROWD_COUNT and (crowdMiddle - ctx.pos).Magnitude < T.CROWD_KEEP * 1.6
	if crowded and ctx.armed and ctx.gunner then
		local range = math.max(T.CROWD_KEEP, T.GUN_RANGE[ctx.gunKind or "hitscan"] or 70)
		return { mode = "crowd", goal = orbitGoal(state, ctx, crowdMiddle, range),
			options = { arrive = 8, maxSpeed = 40, loiter = true } }
	end

	-- orbit
	if target and ctx.armed and ctx.gunner then
		if ctx.inArc then
			if ctx.inArc(target.pos) then
				state.outOfArcSince = nil
			else
				state.outOfArcSince = state.outOfArcSince or now
				if now - state.outOfArcSince > T.ARC_FLIP then
					state.orbitFlipAt = 0
					state.outOfArcSince = nil
				end
			end
		end
		local range = T.GUN_RANGE[ctx.gunKind or "hitscan"] or 70
		return { mode = "orbit", goal = orbitGoal(state, ctx, target.pos, range),
			options = { arrive = 8, maxSpeed = 40, loiter = true } }
	end

	-- broadside
	if target and not ctx.armed and not crowded and (target.pos - ctx.pos).Magnitude < T.DISMOUNT_RANGE then
		-- Side-on to the middle of whoever is close, not just the target.
		local _, middle = around(enemies, ctx.pos, T.DISMOUNT_RANGE + 30)
		local centre = middle or target.pos
		local to = unit(centre - ctx.pos, ctx.look)
		if not state.broadside then
			local side = rightOf(to)
			if side:Dot(ctx.look) < 0 then
				side = -side
			end
			state.broadside = { since = now, goal = ctx.pos + side * 22 }
		end
		local sideOn = math.abs(ctx.look:Dot(to)) < T.BROADSIDE_COS
		if (ctx.speed < 4 and sideOn) or now - state.broadside.since > T.BROADSIDE_WAIT then
			state.broadside = nil
			return leave("fight", farSide(ctx, centre), 6)
		end
		return { mode = "broadside", goal = state.broadside.goal, options = { arrive = 3, maxSpeed = 18 } }
	end
	state.broadside = nil

	-- travel
	local goal = ctx.goal
	if crowded and not goal then
		local away = unit(ctx.pos - crowdMiddle, ctx.look)
		goal = ctx.pos + away * 200
	end
	if not goal then
		return leave("nowhere", farSide(ctx, nearest and nearestDistance < T.PARK_RANGE and nearest.pos or nil), 8)
	end
	goal = flat(goal)
	-- Stopped in plain view: out, behind the car.
	local seenNear = false
	for _, enemy in ipairs(enemies) do
		if enemy.seen and (enemy.pos - ctx.pos).Magnitude < T.PARK_RANGE then
			seenNear = true
			break
		end
	end
	if seenNear and ctx.speed < 3 and (goal - ctx.pos).Magnitude > (ctx.arrive or 25) then
		state.parkedSince = state.parkedSince or now
		if now - state.parkedSince > T.PARK_EXPOSED then
			state.parkedSince = nil
			return leave("exposed", farSide(ctx, nearest.pos), 8)
		end
	else
		state.parkedSince = nil
	end
	if state.unstick then
		return { mode = "unstick", goal = goal, options = { arrive = ctx.arrive }, via = { state.unstick.point },
			replan = status == "stuck" or status == "lost", toggleRoads = status == "stuck" or status == "lost" }
	end
	local via, changed = coverVia(state, ctx, goal, crowded and crowdMiddle or nil)
	return { mode = via and "cover" or "travel", goal = goal, options = { arrive = ctx.arrive },
		via = via and { via } or nil, replan = changed }
end

-- Hands a plan to BotNav: DriveTo again only when the goal has moved (12 studs circling, 40 else),
-- the mode or the detour has changed, or the plan asks. `route` is the ride's { roads, bounds,
-- preferRoads, lane }; the lane (a base yard's way out) goes first, once. True when it replanned.
function T.Apply(state, drive, plan, nav, route)
	local goal = flat(plan.goal)
	local options = plan.options or {}
	local loiter = options.loiter == true
	local moved = state.goal and (state.goal - goal).Magnitude or math.huge
	if not (plan.replan or route.replan or moved > (loiter and 12 or 40) or state.goalLoiter ~= loiter
		or state.mode ~= plan.mode) then
		return false
	end
	if plan.toggleRoads and route.roads then
		route.preferRoads = not route.preferRoads
	end
	local via = {}
	if route.lane then
		table.insert(via, route.lane)
		route.lane = nil
	end
	-- A base vehicle's way on from its lane to its base's access road (ModeTeams.BaseDriveVia).
	for _, point in ipairs(route.laneVia or {}) do
		table.insert(via, point)
	end
	route.laneVia = nil
	for _, point in ipairs(plan.via or {}) do
		table.insert(via, point)
	end
	nav.DriveTo(drive, goal, { arrive = options.arrive, maxSpeed = options.maxSpeed, loiter = loiter,
		roads = route.roads, bounds = route.bounds, preferRoads = route.preferRoads, via = #via > 0 and via or nil })
	if plan.mode == "unstick" and plan.replan and drive.stuck then
		drive.stuck.tries = 0
		drive.stuck.anchor = drive.chassis.Position
	end
	state.goal, state.goalLoiter, state.mode = goal, loiter, plan.mode
	route.replan = false
	return true
end

return T
