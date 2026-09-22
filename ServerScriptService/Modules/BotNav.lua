-- How bots get from A to B. BotService decides where a bot wants to be; this module gets it there:
-- queued path requests, following a route, checking a step is safe before taking it, finding cover,
-- and a stuck ladder for when none of that worked.
--
-- Requests are queued, not dropped. ComputeAsync is expensive, so only a few paths are computed at
-- once. The old cap threw a request away when it was full, and a bot whose request was thrown away
-- walked a straight line toward a goal up to 220 studs off, into whatever stood in between. Now each
-- bot holds at most one request (a newer destination replaces the older one) and requests are
-- served most urgent first.
--
-- Everything here keeps its per-bot state in `bot.nav`, made by BotNav.Attach. Nothing outside
-- BotService and this module reads it.

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BotNav = {}

BotNav.Priority = { Urgent = 1, Combat = 2, Loot = 3, Wander = 4 }

-- Counters for tools/bot_probe.lua. Cheap increments; nothing reads them in a match.
BotNav.Stats = {
	pathRequests = 0, pathReused = 0, pathOk = 0, pathFail = 0, pathTime = 0, pathDiscarded = 0,
	queueWait = 0, queueWaitMax = 0, queuePeak = 0,
	fallbackMoves = 0, pathMoves = 0, lookAheads = 0, blocked = 0,
	jumps = 0, sidesteps = 0, hops = 0, parkour = 0, parkourFromJump = 0, abandons = 0, recovers = 0,
	directBlocked = 0, parkourAttempts = 0, waypointsSkipped = 0, offRoute = 0,
}
local STATS = BotNav.Stats

-- How many PathfindingService computes run at once; the rest wait in Pump's priority queue. A bot
-- whose route is waiting does not freeze: BotNav.Follow's direct-line fallback walks it,
-- floor-checked, until the route lands, so the cap trades route freshness for frame time. Each
-- ComputeAsync costs 77-120 ms of server time, and Oliver's complaint is lag (#126/#131). Measured
-- (tools/bot_probe.lua free roam; the A/B on ONE map build, 40 bots, 110 s a pass, 2026-09-22):
--   cap 4 : worst tick 43.0 ms, think 53 us/bot-update, route wait avg 0.20 s max 1.35 s, 0 rejected
--   cap 6 : worst tick 40.9 ms, think 64 us/bot-update, route wait avg 0.18 s max 1.36 s, 0 rejected
--   cap 16: that A/B pass was lost (Studio closed itself at 292 s); its only figure is run 14 on
--           another seed, worst tick 116 ms / 87 us, against 36-64 ms for cap 4 over four earlier runs.
-- 15 is Oliver's call ("make it 15", 2026-09-22, after "cap it at 10"), one under the 16 that cost
-- frames on the other seed. Measured at 15 on its own build (run 15a, 40 bots, 150 s free roam, a
-- third seed): worst tick 32.4 ms, think 38 us/bot-update, route wait max 0.24 s, 0 rejected, 2% of
-- paths failed. Change it only with an A/B on one snapshot; BotNav.Stats.queueWaitMax and
-- BotService.Stats.maxTick are the numbers to read.
local MAX_CONCURRENT_PATHS = 15

-- A destination this close to where the current route already ends keeps the route.
local REUSE_RADIUS = 10

-- A waypoint counts as reached within this many flat studs, and only when the bot is at its height.
-- The old test was 7 flat studs and ignored height, so bots turned early round every corner and
-- clipped the wall they were turning round, and "reached" a waypoint on the floor above them.
local ADVANCE_FLAT = 4
local ADVANCE_RISE = 5

-- Waypoints sit on the floor, so everything here needs to know how far the root is above the feet.
-- It is NOT a constant: crouching and sliding lower the rig by about a stud (MatchService.updateHeight
-- scales HipHeight), and a body measured as 3 studs tall while it is actually 2 would read floors,
-- drops, ledges and climb heights a stud out. This is the same expression Shared/Parkour and
-- MovementClient use, so their measurements and these agree by construction.
local ROOT_ABOVE_FLOOR = 3 -- the default R15 figure, used only when there's no rig to ask

local function footHeight(character, root)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and root then
		return humanoid.HipHeight + root.Size.Y / 2
	end
	return ROOT_ABOVE_FLOOR
end
BotNav.FootHeight = footHeight

local JUMP_TRIGGER = 6

-- The furthest a bot will walk off an edge on purpose. It is this high only because nothing in the
-- game does fall damage (checked across the server), so the question is just whether it can get out
-- again: a wall top or a low roof is fine, a void or a pit is not. If fall damage is ever added, this
-- has to come back down to a drop a bot can take. (At 6 a bot that had climbed a 9-stud wall was
-- stranded on top of it.)
local MAX_STEP_DOWN = 14

local AGENT = {
	AgentRadius = 2.5,
	AgentHeight = 6,
	AgentCanJump = true,
	AgentMaxSlope = 55,
	-- Swimming is slow and leaves a bot a sitting duck, so a bridge is worth a real detour.
	Costs = { Water = 20 },
}

-- A surface this upright is ground you can walk up, not a wall (the agent's max slope).
local WALKABLE_NORMAL_Y = math.cos(math.rad(AGENT.AgentMaxSlope))
local MAX_RISE_PER_STUD = math.tan(math.rad(AGENT.AgentMaxSlope))
-- A kerb or step walked straight up, on top of any slope.
local MAX_STEP_UP = 3

local inFlight = 0
local waiting = {}

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

--------------------------------------------------------------------------------
-- Per-bot state
--------------------------------------------------------------------------------

function BotNav.Attach(bot)
	bot.nav = {
		waypoints = nil,
		index = 1,
		routeEnd = nil,
		blockedConnection = nil,
		jumpedIndex = 0,
		lookAheadAt = 0,

		request = nil, -- { destination, priority, at, id }
		computing = nil, -- id of the request being computed
		nextId = 0,
		failures = 0, -- consecutive failed computes

		moveTarget = nil, -- the point Follow last walked toward
		lastFailure = nil,
		lastFailureAt = 0,

		progressAt = 0,
		progressPosition = nil,
		progressDistance = nil,
		stuckSince = nil,
		stage = 0,
		detour = nil,
		detourUntil = 0,
		lastHopAt = 0,
		lastGood = nil,
		lastGoodAt = 0,
		groundY = nil, -- feet height of the last surface stood on, for parkour
		climbing = false, -- a jump-then-climb attempt is watching the jump
	}
	return bot.nav
end

local function disconnectBlocked(nav)
	if nav.blockedConnection then
		nav.blockedConnection:Disconnect()
		nav.blockedConnection = nil
	end
end

-- Forget the route (and any request still waiting). A computation already in flight finishes, but
-- its result is thrown away.
function BotNav.Drop(bot)
	local nav = bot.nav
	if not nav then
		return
	end
	disconnectBlocked(nav)
	nav.waypoints = nil
	nav.routeEnd = nil
	nav.request = nil
	nav.computing = nil
	nav.detour = nil
	nav.detourUntil = 0
end

function BotNav.HasRoute(bot)
	local nav = bot.nav
	return nav ~= nil and nav.waypoints ~= nil and nav.index <= #nav.waypoints
end

function BotNav.IsPending(bot)
	local nav = bot.nav
	return nav ~= nil and (nav.request ~= nil or nav.computing ~= nil)
end

-- Where the current route or the request after it is headed, if anywhere.
function BotNav.Destination(bot)
	local nav = bot.nav
	if not nav then
		return nil
	end
	return nav.request and nav.request.destination or nav.routeEnd
end

--------------------------------------------------------------------------------
-- Path requests
--------------------------------------------------------------------------------

-- Ask for a route. Returns immediately; the route arrives in `bot.nav` when its turn comes. A
-- destination next to where the bot is already going is not recomputed.
function BotNav.Request(bot, destination, priority)
	local nav = bot.nav
	if not nav or not destination then
		return
	end
	priority = priority or BotNav.Priority.Wander
	STATS.pathRequests += 1

	if nav.routeEnd and BotNav.HasRoute(bot) and (nav.routeEnd - destination).Magnitude < REUSE_RADIUS and not nav.request then
		STATS.pathReused += 1
		return
	end
	local pending = nav.request
	if pending and (pending.destination - destination).Magnitude < REUSE_RADIUS then
		-- Same place: keep its place in the queue, but take the more urgent priority.
		pending.priority = math.min(pending.priority, priority)
		pending.destination = destination
		return
	end

	nav.nextId += 1
	local fresh = { destination = destination, priority = priority, at = os.clock(), id = nav.nextId }
	if not pending then
		table.insert(waiting, bot)
	else
		-- Replacing a waiting request keeps the time it has already waited.
		fresh.at = pending.at
	end
	nav.request = fresh
	STATS.queuePeak = math.max(STATS.queuePeak, #waiting)
end

local function compute(bot, request)
	local nav = bot.nav
	nav.computing = request.id
	inFlight += 1
	local waited = os.clock() - request.at
	STATS.queueWait += waited
	STATS.queueWaitMax = math.max(STATS.queueWaitMax, waited)

	task.spawn(function()
		local path = PathfindingService:CreatePath(AGENT)
		local started = os.clock()
		local ok = pcall(function()
			path:ComputeAsync(bot.character:GetPivot().Position, request.destination)
		end)
		STATS.pathTime += os.clock() - started
		inFlight -= 1

		-- Dropped, replaced, or the bot is gone: this answer is for a question nobody is asking now.
		if bot.nav ~= nav or nav.computing ~= request.id or not bot.character.Parent then
			STATS.pathDiscarded += 1
			return
		end
		nav.computing = nil

		if ok and path.Status == Enum.PathStatus.Success then
			STATS.pathOk += 1
			disconnectBlocked(nav)
			nav.waypoints = path:GetWaypoints()
			nav.index = math.min(2, #nav.waypoints) -- the first waypoint is where we already are
			nav.routeEnd = request.destination
			nav.jumpedIndex = 0
			nav.failures = 0
			-- A barricade thrown down or a car parked across the route after it was computed.
			nav.blockedConnection = path.Blocked:Connect(function(blockedIndex)
				if bot.nav == nav and nav.waypoints and blockedIndex >= nav.index then
					STATS.blocked += 1
					disconnectBlocked(nav)
					nav.waypoints = nil
					nav.routeEnd = nil
				end
			end)
		else
			STATS.pathFail += 1
			-- Failures count per destination: one failed loot route and then one failed wander leg are
			-- two different problems, not two strikes against the same goal.
			if nav.lastFailure and (nav.lastFailure - request.destination).Magnitude < REUSE_RADIUS then
				nav.failures += 1
			else
				nav.failures = 1
			end
			nav.waypoints = nil
			nav.routeEnd = nil
			nav.lastFailure = request.destination
			nav.lastFailureAt = os.clock()
		end
	end)
end

-- Serve waiting requests, most urgent then oldest first, while there is capacity. Called by
-- BotService every think tick.
function BotNav.Pump()
	if #waiting == 0 or inFlight >= MAX_CONCURRENT_PATHS then
		return
	end
	-- Drop entries whose request was served, replaced by Drop, or whose bot has gone.
	-- A bot dropped and re-queued can be listed twice; keep one entry.
	local live, listed = {}, {}
	for _, bot in ipairs(waiting) do
		if not listed[bot] then
			listed[bot] = true
			if bot.nav and bot.nav.request and bot.character.Parent and bot.humanoid.Health > 0 then
				table.insert(live, bot)
			elseif bot.nav then
				bot.nav.request = nil
			end
		end
	end
	table.sort(live, function(a, b)
		local ra, rb = a.nav.request, b.nav.request
		if ra.priority ~= rb.priority then
			return ra.priority < rb.priority
		end
		return ra.at < rb.at
	end)
	waiting = live
	while #waiting > 0 and inFlight < MAX_CONCURRENT_PATHS do
		local bot = table.remove(waiting, 1)
		local request = bot.nav.request
		if request then
			bot.nav.request = nil
			compute(bot, request)
		end
	end
end

-- Whether the last compute toward (near) this destination failed within `window` seconds.
function BotNav.RecentlyFailed(bot, destination, window)
	local nav = bot.nav
	return nav ~= nil and nav.lastFailure ~= nil and os.clock() - nav.lastFailureAt < (window or 5)
		and (nav.lastFailure - destination).Magnitude < REUSE_RADIUS
end

function BotNav.Clear()
	table.clear(waiting)
	-- In-flight computes finish on their own and find their bot's nav replaced or gone.
end

--------------------------------------------------------------------------------
-- Probes
--------------------------------------------------------------------------------

local function stepParams(character)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = { character }
	for _, name in ipairs({ "Loot", "Effects" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	params.FilterDescendantsInstances = filter
	-- Undergrowth, spruce skirts and other walk-through decor are CanCollide false.
	params.RespectCanCollide = true
	return params
end
BotNav.StepParams = stepParams

-- The floor under a point, looked for from `fromY` down to `depth` below it. Returns the hit, or nil
-- over a drop. Water counts as floor here; callers that care check the material.
function BotNav.FloorAt(x, z, fromY, depth, params)
	return workspace:Raycast(Vector3.new(x, fromY, z), Vector3.new(0, -depth, 0), params)
end

-- Can a bot standing at `root` walk straight to `point` without meeting a wall, stepping off a drop
-- or into water? Checks a waist ray and a knee ray along the way, and the floor halfway and at the
-- end. Returns ok, or false plus a reason ("wall", "drop", "water") and, for a wall, how far off it is.
--
-- Hills are not walls. The first version treated any ray hit as a wall and any missing floor as a
-- drop, and on the map's rolling terrain that made bots stand still: the knee ray hits an uphill
-- slope ahead, and a floor ray started at waist height begins inside ground that has risen above it.
-- So a hit whose surface is walkable (normal within the agent's max slope) doesn't block, and a floor
-- ray that finds nothing is tried again from above the highest walkable rise at that distance.
function BotNav.CanStep(root, character, point, params)
	params = params or stepParams(character)
	local origin = root.Position
	local delta = flat(point - origin)
	local distance = delta.Magnitude
	if distance < 0.5 then
		return true
	end
	local direction = delta.Unit

	for _, lift in ipairs({ 0, -1.8 }) do
		local hit = workspace:Raycast(origin + Vector3.new(0, lift, 0), direction * (distance + 1.5), params)
		if hit and hit.Normal.Y < WALKABLE_NORMAL_Y then
			return false, "wall", flat(hit.Position - origin).Magnitude
		end
	end

	local standing = footHeight(character, root)
	local feet = origin.Y - standing
	for _, share in ipairs({ 0.5, 1 }) do
		local along = distance * share
		local at = origin + direction * along
		local floor = BotNav.FloorAt(at.X, at.Z, origin.Y + 1, standing + 1 + MAX_STEP_DOWN, params)
		if not floor then
			-- Maybe uphill: look down from above the steepest rise that's still walkable.
			local rise = along * MAX_RISE_PER_STUD + MAX_STEP_UP
			local above = BotNav.FloorAt(at.X, at.Z, feet + rise + 1, rise + 1 - (standing + 1), params)
			if above and above.Normal.Y >= WALKABLE_NORMAL_Y then
				floor = above
			end
		end
		if not floor then
			return false, "drop"
		end
		if floor.Material == Enum.Material.Water then
			return false, "water"
		end
		if floor.Position.Y < feet - MAX_STEP_DOWN then
			return false, "drop"
		end
	end
	return true
end

-- A spot within reach that `threatPosition` can't see, with floor under it and room to stand.
-- Returns the point and whether it can be walked to in a straight line; nil when there's nowhere.
--
-- The best cover is usually right behind the thing that blocks the shot, and a straight walk to
-- there goes through that thing. So a hidden spot with a clear walk wins within its ring, but a
-- hidden spot that needs a route round (floor under it, nothing solid where the bot would stand) is
-- accepted too, and the caller paths to it. Rings of 10, 18 and 28 studs, nearest first, eight
-- directions each starting straight away from the threat; callers rate-limit this. `threatCharacter`,
-- when given, is left out of the sight line: the shooter's own gun or arm hides nothing.
local COVER_DIRECTIONS = 8
function BotNav.FindCover(root, character, threatPosition, radii, isAllowed, threatCharacter)
	local params = stepParams(character)
	local los = RaycastParams.new()
	los.FilterType = Enum.RaycastFilterType.Exclude
	local losFilter = params.FilterDescendantsInstances
	if threatCharacter then
		table.insert(losFilter, threatCharacter)
	end
	los.FilterDescendantsInstances = losFilter
	-- Water is not cover, and this ray is what decides whether a spot is hidden. Left at the default
	-- (IgnoreWater false) the river counted as something to hide behind, so a hurt bot would have run
	-- INTO the water and stood there. The step checks below deliberately keep water visible, because
	-- there it means "don't walk in".
	los.IgnoreWater = true
	los.RespectCanCollide = true
	local room = OverlapParams.new()
	room.FilterType = Enum.RaycastFilterType.Exclude
	room.FilterDescendantsInstances = params.FilterDescendantsInstances
	room.RespectCanCollide = true

	local origin = root.Position
	local away = flat(origin - threatPosition)
	local baseAngle = away.Magnitude > 0.1 and math.atan2(away.Z, away.X) or 0
	-- A spot that needs a route round the back is the fallback, and only after every ring has been
	-- tried for one the bot can simply walk to.
	local routed = nil
	for _, radius in ipairs(radii or { 10, 18, 28 }) do
		for step = 0, COVER_DIRECTIONS - 1 do
			-- Straight away from the threat first, then fanning out either side of it.
			local offset = (step % 2 == 0 and 1 or -1) * math.ceil(step / 2) * (math.pi * 2 / COVER_DIRECTIONS)
			local angle = baseAngle + offset
			local point = origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			if not isAllowed or isAllowed(point) then
				local eye = point + Vector3.new(0, 1.5, 0)
				local toEye = eye - threatPosition
				local hit = workspace:Raycast(threatPosition, toEye, los)
				if hit and (hit.Position - eye).Magnitude > 2 then
					if BotNav.CanStep(root, character, point, params) then
						return point, true
					end
					if not routed then
						local standing = footHeight(character, root)
						local floor = BotNav.FloorAt(point.X, point.Z, origin.Y + 4, standing + 4 + MAX_STEP_DOWN, params)
						if floor and floor.Material ~= Enum.Material.Water and floor.Normal.Y >= WALKABLE_NORMAL_Y then
							local stand = Vector3.new(point.X, floor.Position.Y + standing, point.Z)
							if #workspace:GetPartBoundsInRadius(stand, 1.2, room) == 0 then
								routed = stand
							end
						end
					end
				end
			end
		end
	end
	if routed then
		return routed, false
	end
	return nil
end

--------------------------------------------------------------------------------
-- Following
--------------------------------------------------------------------------------

-- Walking straight at a goal with no route is only safe when the next stretch has floor under it and
-- nothing in the way. Without this check a bot whose route failed walked off the ledge it stood on or
-- into the wall it was facing. Checked at most a few times a second.
local DIRECT_LOOKAHEAD = 10
local DIRECT_RECHECK = 0.6
local DIRECT_MOVED_RECHECK = 4

local function directSafe(bot, root, goal, now)
	local nav = bot.nav
	local distance = flatDistance(root.Position, goal)
	if distance < 1.5 then
		return true
	end
	-- The check looked DIRECT_LOOKAHEAD studs ahead; a sprinting bot covers more than that in
	-- DIRECT_RECHECK seconds, so it's redone once the bot has moved a few studs, not only on the timer.
	-- A wall's distance goes stale the moment the bot steps toward it: parkourAcross walks up to the
	-- wall between checks, and an approach aimed with the old figure lands inside the wall, fails its
	-- own step check, and navigate abandoned the goal (the 9-stud course in run 14: closest approach
	-- 1.7 studs, the bot never asked to climb; run 15b with this line: over the wall at 2.3 s). Walls
	-- are re-measured every think; the cache serves the open-ground, drop and water answers, which
	-- don't change while the bot stands still.
	if now - (nav.directCheckedAt or 0) < DIRECT_RECHECK and nav.directReason ~= "wall" and nav.directGoal
		and (nav.directGoal - goal).Magnitude < 2
		and nav.directCheckedFrom and flatDistance(root.Position, nav.directCheckedFrom) < DIRECT_MOVED_RECHECK then
		return nav.directOk, nav.directReason, nav.directWallDistance
	end
	local step = math.min(distance, DIRECT_LOOKAHEAD)
	local point = root.Position + flat(goal - root.Position).Unit * step
	local ok, reason, wallDistance = BotNav.CanStep(root, bot.character, point)
	nav.directCheckedAt = now
	nav.directCheckedFrom = root.Position
	nav.directGoal = goal
	nav.directOk = ok == true
	nav.directReason = reason
	nav.directWallDistance = wallDistance
	return nav.directOk, reason, wallDistance
end

-- A wall straight across the way with no route round it (a garden wall, a crate stack, a pad edge
-- fence) is exactly what a climb or vault is for. Walk up within reach, then ask MovementService;
-- if a climb from standing isn't on, try it from the top of a jump. At most once every
-- PARKOUR_RETRY seconds, so a wall nobody can get over costs one attempt, not one per think.
local PARKOUR_REACH = 1.6
local PARKOUR_RETRY = 3

local climbFromJump -- defined with the stuck ladder below

local function parkourAcross(bot, humanoid, root, goal, wallDistance, now)
	local nav = bot.nav
	if not BotNav.TryParkour or now < (nav.parkourRetryAt or 0) then
		return false
	end
	local direction = flat(goal - root.Position)
	if direction.Magnitude < 0.1 then
		return false
	end
	direction = direction.Unit
	if wallDistance and wallDistance > PARKOUR_REACH + 0.5 then
		local approach = root.Position + direction * (wallDistance - PARKOUR_REACH)
		if not BotNav.CanStep(root, bot.character, approach) then
			return false
		end
		nav.moveTarget = approach
		humanoid:MoveTo(approach)
		return true
	end
	nav.parkourRetryAt = now + PARKOUR_RETRY
	STATS.parkourAttempts += 1
	if BotNav.TryParkour(bot.character, direction, nav.groundY) then
		STATS.parkour += 1
		nav.recheckRouteAt = now
		return true
	end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		climbFromJump(bot, humanoid, root, direction, function() end)
		return true
	end
	return false
end

-- After something carried the bot along faster or further than walking would (a vault, a climb, a
-- slide), the waypoints it went past are behind it: skip each one it can walk straight past, and if
-- it ended well away from the route, drop the route so a fresh one is asked for. Without this a bot
-- that vaulted a fence turned round and walked back to the waypoint on the far side of it.
local OFF_ROUTE = 25

local function catchUpRoute(bot, root)
	local nav = bot.nav
	local waypoints = nav.waypoints
	if not waypoints then
		return
	end
	local position = root.Position
	local standing = footHeight(bot.character, root)
	local feetY = position.Y - standing
	for _ = 1, 6 do
		if nav.index >= #waypoints then
			break
		end
		local current, following = waypoints[nav.index].Position, waypoints[nav.index + 1].Position
		local segment = flat(following - current)
		local passed = segment.Magnitude > 0.1 and flat(position - current):Dot(segment.Unit) > 0.5
		if passed and math.abs(following.Y - feetY) < ADVANCE_RISE + 3
			and BotNav.CanStep(root, bot.character, following + Vector3.new(0, standing, 0)) then
			nav.index += 1
			STATS.waypointsSkipped += 1
		else
			break
		end
	end
	if flatDistance(position, waypoints[nav.index].Position) > OFF_ROUTE then
		STATS.offRoute += 1
		disconnectBlocked(nav)
		nav.waypoints = nil
		nav.routeEnd = nil
	end
end

-- Walk the route toward `goal`. Without a route (none yet, or it failed) this walks straight at the
-- goal when the way looks clear, which is right for short hops and the best there is while a request
-- waits its turn; when it doesn't, it stands and sets `nav.directBlockedAt`.
-- Returns true while following a real route.
function BotNav.Follow(bot, humanoid, root, goal, now)
	local nav = bot.nav
	now = now or os.clock()

	-- Watching a jump for the moment to climb: keep going the way it was going.
	if nav.climbing then
		return false
	end
	if nav.recheckRouteAt and now >= nav.recheckRouteAt then
		nav.recheckRouteAt = nil
		catchUpRoute(bot, root)
	end

	if nav.detour and now < nav.detourUntil then
		nav.moveTarget = nav.detour
		humanoid:MoveTo(nav.detour)
		return false
	end
	nav.detour = nil

	local waypoints = nav.waypoints
	if not waypoints or nav.index > #waypoints then
		local safe, reason, wallDistance = directSafe(bot, root, goal, now)
		if not safe and reason == "wall" and parkourAcross(bot, humanoid, root, goal, wallDistance, now) then
			return false
		end
		if not safe then
			STATS.directBlocked += 1
			nav.directBlockedAt = now
			nav.moveTarget = nil
			humanoid:MoveTo(root.Position)
			return false
		end
		STATS.fallbackMoves += 1
		nav.moveTarget = goal
		humanoid:MoveTo(goal)
		return false
	end

	local position = root.Position
	local standing = footHeight(bot.character, root)
	local feetY = position.Y - standing
	local waypoint = waypoints[nav.index]
	while flatDistance(position, waypoint.Position) < ADVANCE_FLAT and math.abs(waypoint.Position.Y - feetY) < ADVANCE_RISE do
		nav.index += 1
		if nav.index > #waypoints then
			disconnectBlocked(nav)
			nav.waypoints = nil
			STATS.fallbackMoves += 1
			nav.moveTarget = goal
			humanoid:MoveTo(goal)
			return false
		end
		waypoint = waypoints[nav.index]
	end

	-- Cut a corner only when the straight line to the waypoint after this one is walkable, so a
	-- zig-zag route over open ground smooths out without ever cutting through a wall.
	local nextPoint = waypoints[nav.index + 1]
	if nextPoint and now - nav.lookAheadAt > 1 and waypoint.Action == Enum.PathWaypointAction.Walk
		and nextPoint.Action == Enum.PathWaypointAction.Walk
		and math.abs(nextPoint.Position.Y - feetY) < 2 and humanoid.FloorMaterial ~= Enum.Material.Air then
		nav.lookAheadAt = now
		if BotNav.CanStep(root, bot.character, nextPoint.Position + Vector3.new(0, standing, 0)) then
			STATS.lookAheads += 1
			nav.index += 1
			waypoint = nextPoint
		end
	end

	-- Jump once for each jump waypoint, as it comes into reach. Setting Jump every tick all the way
	-- there made bots bunny-hop along the approach.
	if waypoint.Action == Enum.PathWaypointAction.Jump and nav.jumpedIndex ~= nav.index
		and flatDistance(position, waypoint.Position) < JUMP_TRIGGER and humanoid.FloorMaterial ~= Enum.Material.Air then
		nav.jumpedIndex = nav.index
		humanoid.Jump = true
	end

	STATS.pathMoves += 1
	nav.moveTarget = waypoint.Position
	humanoid:MoveTo(waypoint.Position)
	return true
end

--------------------------------------------------------------------------------
-- Stuck ladder
--------------------------------------------------------------------------------

-- Set by BotService when the movement tab's server parkour exists:
-- (character, forward, groundY) -> kind|nil.
BotNav.TryParkour = nil

-- A wall too tall to climb from standing can still be climbed from the top of a jump: the movement
-- tab measured a 9-stud wall climbable once the feet are about 2.2 studs up. So jump, watch the jump
-- frame by frame (a think tick is too coarse to catch that window), and try again at that height.
local CLIMB_FROM_JUMP_HEIGHT = 2.2
local CLIMB_WATCH_SECONDS = 0.7

function climbFromJump(bot, humanoid, root, forward, onFail)
	local nav = bot.nav
	local groundY = nav.groundY or (root.Position.Y - footHeight(bot.character, root))
	nav.climbing = true
	humanoid.Jump = true
	task.spawn(function()
		local started = os.clock()
		while os.clock() - started < CLIMB_WATCH_SECONDS do
			RunService.Heartbeat:Wait()
			if bot.nav ~= nav or not root.Parent or humanoid.Health <= 0 then
				nav.climbing = false
				return
			end
			if root.Position.Y - footHeight(bot.character, root) - groundY >= CLIMB_FROM_JUMP_HEIGHT then
				nav.climbing = false
				if BotNav.TryParkour(bot.character, forward, groundY) then
					STATS.parkour += 1
					STATS.parkourFromJump += 1
					nav.recheckRouteAt = os.clock()
				else
					onFail()
				end
				return
			end
		end
		nav.climbing = false
		onFail()
	end)
end

local function sidestepPoint(root, character)
	local params = stepParams(character)
	local look = flat(root.CFrame.LookVector)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
	local right = Vector3.new(-look.Z, 0, look.X)
	local best, bestRoom = nil, 0
	for _, side in ipairs({ right, -right }) do
		local hit = workspace:Raycast(root.Position, side * 8, params)
		local room = hit and (hit.Position - root.Position).Magnitude or 8
		if room > bestRoom then
			best, bestRoom = side, room
		end
	end
	if not best or bestRoom < 2.5 then
		-- Hemmed in on both sides: back out instead.
		return root.Position - look * 6
	end
	return root.Position + best * math.min(6, bestRoom - 1.5)
end

local function hop(root, humanoid)
	local look = flat(root.CFrame.LookVector)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	root.AssemblyLinearVelocity = look * 26 + Vector3.new(0, 58, 0)
end

local function playerNear(position, radius)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - position).Magnitude < radius then
			return true
		end
	end
	return false
end

-- Call once per think tick with whether the bot is trying to get somewhere (`target`, the point it
-- is walking toward right now, normally `bot.nav.moveTarget`; or nil when it is standing still on
-- purpose: holding loot, behind cover, waiting out a reaction). Progress is measured as distance
-- closed on that point, not distance moved, so a bot circling a waypoint it can't reach counts as
-- stuck too; and it is the current waypoint, not the final goal, so walking the long way round a
-- building on a good route never looks like being stuck.
--
-- Returns "abandon" when the caller should give up its current goal, otherwise nil. Everything
-- else on the ladder is handled here: jump, sidestep with a fresh route, parkour or a hop, and as a
-- last resort, well away from any player, a return to the last place it was walking freely.
function BotNav.Progress(bot, humanoid, root, target, now)
	local nav = bot.nav
	if not target then
		nav.stuckSince = nil
		nav.stage = 0
		nav.progressPosition = nil
		return nil
	end

	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if grounded then
		nav.groundY = root.Position.Y - footHeight(bot.character, root)
	end
	if nav.climbing then
		return nil
	end
	if grounded and flat(root.AssemblyLinearVelocity).Magnitude > 6 and now - nav.lastGoodAt > 3 then
		nav.lastGood = root.Position
		nav.lastGoodAt = now
	end

	local distance = flatDistance(root.Position, target)
	if not nav.progressPosition or now - nav.progressAt >= 1 then
		local closed = nav.progressDistance and (nav.progressDistance - distance) or math.huge
		local moved = nav.progressPosition and flatDistance(root.Position, nav.progressPosition) or math.huge
		-- A target that moved (a new waypoint, a new goal) resets the comparison, so judge that
		-- second on distance moved instead.
		local sameTarget = nav.progressTarget and flatDistance(nav.progressTarget, target) < 2
		local progressed = (sameTarget and closed >= 1.5) or (not sameTarget and moved >= 3) or distance < 3
		nav.progressPosition = root.Position
		nav.progressDistance = distance
		nav.progressTarget = target
		nav.progressAt = now
		if progressed then
			nav.stuckSince = nil
			nav.ladderSince = nil
			nav.recoverTried = false
			nav.stage = 0
			return nil
		end
		nav.stuckSince = nav.stuckSince or (now - 1)
		nav.ladderSince = nav.ladderSince or nav.stuckSince
	end
	if not nav.stuckSince then
		return nil
	end

	-- The rungs run on time since the ladder (re)started; the last resort on time since the bot last
	-- made any progress at all.
	local stuckFor = now - (nav.ladderSince or nav.stuckSince)
	local totalStuck = now - nav.stuckSince
	-- Tried once per stuck spell; if a player is near, the ladder just carries on instead.
	if totalStuck >= 20 and not nav.recoverTried then
		nav.recoverTried = true
		if nav.lastGood and not playerNear(root.Position, 200) and not playerNear(nav.lastGood, 200) then
			STATS.recovers += 1
			BotNav.Drop(bot)
			bot.character:PivotTo(CFrame.new(nav.lastGood))
			return nil
		end
	end
	if nav.stage < 1 and stuckFor >= 1 then
		nav.stage = 1
		if grounded then
			STATS.jumps += 1
			humanoid.Jump = true
		end
	elseif nav.stage < 2 and stuckFor >= 2 then
		nav.stage = 2
		STATS.sidesteps += 1
		local destination = BotNav.Destination(bot) or target
		BotNav.Drop(bot)
		nav.detour = sidestepPoint(root, bot.character)
		nav.detourUntil = now + 0.8
		BotNav.Request(bot, destination, BotNav.Priority.Urgent)
	elseif nav.stage < 3 and stuckFor >= 4 then
		nav.stage = 3
		local look = flat(target - root.Position)
		look = look.Magnitude > 0.1 and look.Unit or flat(root.CFrame.LookVector).Unit
		-- Wedged against something a route keeps walking back into (a fence, a car, a ledge): hop
		-- over it the way a player would with a Rot Rocket. Bots are simulated by the server, so the
		-- push can be applied directly. The fallback when climbing and vaulting don't apply.
		local function hopOver()
			if humanoid.Health > 0 and humanoid.FloorMaterial ~= Enum.Material.Air and os.clock() - nav.lastHopAt > 6 then
				nav.lastHopAt = os.clock()
				STATS.hops += 1
				hop(root, humanoid)
			end
		end
		if BotNav.TryParkour then
			STATS.parkourAttempts += 1
		end
		if BotNav.TryParkour and BotNav.TryParkour(bot.character, look, nav.groundY) then
			STATS.parkour += 1
			nav.recheckRouteAt = now
		elseif BotNav.TryParkour and grounded then
			climbFromJump(bot, humanoid, root, look, hopOver)
		elseif grounded then
			hopOver()
		end
	elseif nav.stage < 4 and stuckFor >= 8 then
		STATS.abandons += 1
		BotNav.Drop(bot)
		-- Start the rungs again for whatever the caller picks next.
		nav.stage = 0
		nav.ladderSince = now
		return "abandon"
	end
	return nil
end

return BotNav
