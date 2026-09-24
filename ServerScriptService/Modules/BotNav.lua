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

-- Every ray this module casts goes through here. BotService replaces it with its per-frame ray
-- budget (BotService.RaycastBudget.Cast) when it loads; this default is the same call with no cap,
-- for a probe that requires BotNav on its own. Returns result, granted: granted == false means the
-- frame's rays are spent and the caller answers cautiously ("can't step", reason "budget") without
-- caching. `priority` is "combat", "navigation" or "idle" (the module's own rays are navigation).
function BotNav.CastRay(origin, direction, params, priority)
	return workspace:Raycast(origin, direction, params), true
end
-- The same budget for a driving bot's block sweeps (BotService hands in RaycastBudget.Spend and
-- .Remaining): Spend counts one query and says whether it was granted; Remaining is what a priority
-- may still spend this frame. These defaults are uncapped.
function BotNav.CastSpend(priority)
	return true
end
function BotNav.CastRemaining(priority)
	return math.huge
end

-- Counters for tools/bot_probe.lua. Cheap increments; nothing reads them in a match.
BotNav.Stats = {
	pathRequests = 0, pathReused = 0, pathShared = 0, pathOk = 0, pathFail = 0, pathTime = 0, pathDiscarded = 0,
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

-- How many of those computes one Pump may START. The cap above bounds how many run at once, but
-- not how many begin in the same frame: a burst of requests (the drop, a storm phase, a fight
-- breaking up) started up to 15 ComputeAsync calls in one think tick, and the cap A/B above is
-- the evidence that computes started together cost frame time. Pump runs every think slice
-- (BotService.ThinkSlices a BotThinkInterval, about 15 a second), so 3 a pump is ~45 starts a second,
-- still room for every one of 50 bots to start a route inside about a second; the most urgent
-- still go first. tools/perf_bot_cost.py counts starts per pump.
local MAX_STARTS_PER_PUMP = 3

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

local sharedRoute, rememberRoute, adoptRoute

-- Ask for a route. Returns immediately; the route arrives in `bot.nav` when its turn comes. A
-- destination next to where the bot is already going is not recomputed, nor one a compute is
-- already in flight for, and a route a neighbour just had computed to the same place is copied
-- rather than computed again (route sharing, below).
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
	if nav.computing and nav.computingTo and (nav.computingTo - destination).Magnitude < REUSE_RADIUS then
		-- The answer is already on its way: asking again would compute the same route twice and
		-- throw the first away.
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
	if adoptRoute(bot, destination) then
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

-- ROUTE SHARING. In a team mode most of a side asks for the same place (the hill, the base's
-- chests, the squad's sighting) from the same few spawn points, and at the drop a knot of bots
-- lands together and heads for the same town: each of those was its own ComputeAsync at 77-120 ms.
-- A route that succeeded in the last ROUTE_SHARE_SECONDS, from within ROUTE_SHARE_START of where
-- this bot stands, to within REUSE_RADIUS of where it wants to go, is copied instead: the bot
-- joins it at the waypoint nearest to itself and walks the rest. The waypoint list is shared
-- read-only (Follow only reads it). A shared route has no Path.Blocked watcher; the stuck ladder
-- covers a barricade dropped across it, as it does for any route that goes stale. Only the last
-- ROUTE_SHARE_KEEP routes are kept; anything older than the window is useless anyway.
-- tools/perf_bot_cost.py counts computes for N bots asking for one place (before: N; after: at
-- most the first pump's starts) and checks a bot standing far from the route's start never adopts it.
local ROUTE_SHARE_START = 12
local ROUTE_SHARE_SECONDS = 8
local ROUTE_SHARE_KEEP = 32
local recentRoutes, recentRouteIndex = {}, 0

function rememberRoute(start, destination, waypoints)
	if #waypoints < 2 then
		return
	end
	recentRouteIndex = recentRouteIndex % ROUTE_SHARE_KEEP + 1
	local slot = recentRoutes[recentRouteIndex]
	if not slot then
		slot = {}
		recentRoutes[recentRouteIndex] = slot
	end
	-- tick(): a wall-clock window; os.clock() is CPU time in Roblox (COORDINATION.md).
	slot.start, slot.destination, slot.waypoints, slot.at = start, destination, waypoints, tick()
end

function sharedRoute(position, destination, now)
	for index = 1, #recentRoutes do
		local route = recentRoutes[index]
		if now - route.at < ROUTE_SHARE_SECONDS and (route.destination - destination).Magnitude < REUSE_RADIUS
			and flatDistance(route.start, position) < ROUTE_SHARE_START then
			return route
		end
	end
	return nil
end

-- Take a neighbour's recent route to `destination` if there is one. Returns true when the bot now
-- has a route.
function adoptRoute(bot, destination)
	local nav = bot.nav
	local position = bot.character:GetPivot().Position
	local route = sharedRoute(position, destination, tick())
	if not route then
		return false
	end
	local waypoints = route.waypoints
	-- Join at the waypoint nearest the bot (never the very last: that is the destination itself).
	local nearest, nearestDistance = 1, math.huge
	for index = 1, #waypoints - 1 do
		local distance = flatDistance(waypoints[index].Position, position)
		if distance < nearestDistance then
			nearest, nearestDistance = index, distance
		end
	end
	STATS.pathShared += 1
	disconnectBlocked(nav)
	nav.waypoints = waypoints
	nav.index = math.min(nearest + 1, #waypoints)
	nav.routeEnd = destination
	nav.jumpedIndex = 0
	nav.failures = 0
	nav.request = nil
	nav.computing = nil
	return true
end

local function compute(bot, request)
	local nav = bot.nav
	nav.computing = request.id
	nav.computingTo = request.destination
	inFlight += 1
	local waited = os.clock() - request.at
	STATS.queueWait += waited
	STATS.queueWaitMax = math.max(STATS.queueWaitMax, waited)

	task.spawn(function()
		local path = PathfindingService:CreatePath(AGENT)
		local started = os.clock()
		local from = bot.character:GetPivot().Position
		local ok = pcall(function()
			path:ComputeAsync(from, request.destination)
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
			rememberRoute(from, request.destination, nav.waypoints)
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
	local started = 0
	while #waiting > 0 and inFlight < MAX_CONCURRENT_PATHS and started < MAX_STARTS_PER_PUMP do
		started += 1
		local bot = table.remove(waiting, 1)
		local request = bot.nav.request
		if request then
			bot.nav.request = nil
			-- A route to the same place landed for a neighbour while this one waited: take it, and
			-- the start it would have used goes to the next in the queue.
			if adoptRoute(bot, request.destination) then
				started -= 1
			else
				compute(bot, request)
			end
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
	table.clear(recentRoutes)
	recentRouteIndex = 0
	-- In-flight computes finish on their own and find their bot's nav replaced or gone.
end

--------------------------------------------------------------------------------
-- Probes
--------------------------------------------------------------------------------

-- With `nav` given, the params are kept on it and refilled only when the character or the loot /
-- effects folders change: a RaycastParams and a filter table per step check was two allocations for
-- every one of a fighting bot's five-a-replan checks. Without `nav` (a probe, or a caller that will
-- change a field such as IgnoreWater), a fresh one.
local STEP_FOLDERS = { "Loot", "Effects" }
local function stepParams(character, nav)
	local loot, effects = workspace:FindFirstChild(STEP_FOLDERS[1]), workspace:FindFirstChild(STEP_FOLDERS[2])
	if nav then
		local cached = nav.stepParams
		if cached and nav.stepParamsFor == character and nav.stepParamsLoot == loot and nav.stepParamsEffects == effects then
			return cached
		end
	end
	local params = nav and nav.stepParams or RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = { character }
	if loot then
		table.insert(filter, loot)
	end
	if effects then
		table.insert(filter, effects)
	end
	params.FilterDescendantsInstances = filter
	-- Undergrowth, spruce skirts and other walk-through decor are CanCollide false.
	params.RespectCanCollide = true
	if nav then
		nav.stepParams, nav.stepParamsFor, nav.stepParamsLoot, nav.stepParamsEffects = params, character, loot, effects
	end
	return params
end
BotNav.StepParams = stepParams

-- The floor under a point, looked for from `fromY` down to `depth` below it. Returns the hit (or nil
-- over a drop) and whether the ray was granted by the budget. Water counts as floor here; callers
-- that care check the material.
function BotNav.FloorAt(x, z, fromY, depth, params, priority)
	return BotNav.CastRay(Vector3.new(x, fromY, z), Vector3.new(0, -depth, 0), params, priority or "navigation")
end

local STEP_LIFTS = { 0, -1.8 }
local STEP_SHARES = { 0.5, 1 }

-- Can a bot standing at `root` walk straight to `point` without meeting a wall, stepping off a drop
-- or into water? Checks a waist ray and a knee ray along the way, and the floor halfway and at the
-- end. Returns ok, or false plus a reason ("wall", "drop", "water") and, for a wall, how far off it is.
--
-- Hills are not walls. The first version treated any ray hit as a wall and any missing floor as a
-- drop, and on the map's rolling terrain that made bots stand still: the knee ray hits an uphill
-- slope ahead, and a floor ray started at waist height begins inside ground that has risen above it.
-- So a hit whose surface is walkable (normal within the agent's max slope) doesn't block, and a floor
-- ray that finds nothing is tried again from above the highest walkable rise at that distance.
--
-- A fifth answer, false plus "budget", means the frame's ray budget refused a ray: nothing is known
-- about the step, so callers neither take it nor remember the refusal.
function BotNav.CanStep(root, character, point, params, priority)
	params = params or stepParams(character)
	priority = priority or "navigation"
	local origin = root.Position
	local delta = flat(point - origin)
	local distance = delta.Magnitude
	if distance < 0.5 then
		return true
	end
	local direction = delta.Unit

	for _, lift in ipairs(STEP_LIFTS) do
		local hit, granted = BotNav.CastRay(origin + Vector3.new(0, lift, 0), direction * (distance + 1.5), params, priority)
		if not granted then
			return false, "budget"
		end
		if hit and hit.Normal.Y < WALKABLE_NORMAL_Y then
			return false, "wall", flat(hit.Position - origin).Magnitude
		end
	end

	local standing = footHeight(character, root)
	local feet = origin.Y - standing
	for _, share in ipairs(STEP_SHARES) do
		local along = distance * share
		local at = origin + direction * along
		local floor, granted = BotNav.FloorAt(at.X, at.Z, origin.Y + 1, standing + 1 + MAX_STEP_DOWN, params, priority)
		if not granted then
			return false, "budget"
		end
		if not floor then
			-- Maybe uphill: look down from above the steepest rise that's still walkable.
			local rise = along * MAX_RISE_PER_STUD + MAX_STEP_UP
			local above
			above, granted = BotNav.FloorAt(at.X, at.Z, feet + rise + 1, rise + 1 - (standing + 1), params, priority)
			if not granted then
				return false, "budget"
			end
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
--
-- Returns nil, nil, "budget" when the frame's ray budget ran out part way: the search did not
-- happen, and the caller should try again next think rather than count it as a search.
local COVER_DIRECTIONS = 8
local COVER_RADII = { 10, 18, 28 }
-- (origin, radius) -> { floor point... } nearest first, or nil. Set by ModeTeams while a team match's
-- battleground stands (TeamBattleground.CoverNear), cleared at its teardown.
BotNav.CoverHints = nil
function BotNav.FindCover(root, character, threatPosition, radii, isAllowed, threatCharacter, priority)
	priority = priority or "navigation"
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

	-- BEGIN BATTLEGROUND COVER. Built cover first: while a team match's battleground stands
	-- (TeamBattleground, via ModeTeams) it hands over the spots behind its walls, sandbags, crates and
	-- containers, and one of those the threat cannot see beats a point on a ring, which is as likely to
	-- be the middle of a lane. Each is floor-level; a spot more than a step above or below the bot's
	-- feet is someone else's storey. Same hidden test and the same straight-walk test as the rings.
	if BotNav.CoverHints then
		local standing = footHeight(character, root)
		local feet = origin.Y - standing
		local ok, hints = pcall(BotNav.CoverHints, origin, (radii and radii[#radii]) or 28)
		for _, floorPoint in ipairs(ok and type(hints) == "table" and hints or {}) do
			if math.abs(floorPoint.Y - feet) <= 3 then
				local point = Vector3.new(floorPoint.X, floorPoint.Y + standing, floorPoint.Z)
				if not isAllowed or isAllowed(point) then
					local eye = point + Vector3.new(0, 1.5, 0)
					-- Through the ray budget like the rings below; a refusal ends the search unfinished.
					local hit, granted = BotNav.CastRay(threatPosition, eye - threatPosition, los, priority)
					if not granted then
						return nil, nil, "budget"
					end
					if hit and (hit.Position - eye).Magnitude > 2 then
						local ok, reason = BotNav.CanStep(root, character, point, params, priority)
						if ok then
							return point, true
						end
						if reason == "budget" then
							return nil, nil, "budget"
						end
					end
				end
			end
		end
	end
	-- END BATTLEGROUND COVER

	local away = flat(origin - threatPosition)
	local baseAngle = away.Magnitude > 0.1 and math.atan2(away.Z, away.X) or 0
	-- A spot that needs a route round the back is the fallback, and only after every ring has been
	-- tried for one the bot can simply walk to.
	local routed = nil
	for _, radius in ipairs(radii or COVER_RADII) do
		for step = 0, COVER_DIRECTIONS - 1 do
			-- Straight away from the threat first, then fanning out either side of it.
			local offset = (step % 2 == 0 and 1 or -1) * math.ceil(step / 2) * (math.pi * 2 / COVER_DIRECTIONS)
			local angle = baseAngle + offset
			local point = origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			if not isAllowed or isAllowed(point) then
				local eye = point + Vector3.new(0, 1.5, 0)
				local toEye = eye - threatPosition
				local hit, granted = BotNav.CastRay(threatPosition, toEye, los, priority)
				if not granted then
					return nil, nil, "budget"
				end
				if hit and (hit.Position - eye).Magnitude > 2 then
					local ok, reason = BotNav.CanStep(root, character, point, params, priority)
					if ok then
						return point, true
					end
					if reason == "budget" then
						return nil, nil, "budget"
					end
					if not routed then
						local standing = footHeight(character, root)
						local floor
						floor, granted = BotNav.FloorAt(point.X, point.Z, origin.Y + 4, standing + 4 + MAX_STEP_DOWN, params, priority)
						if not granted then
							return nil, nil, "budget"
						end
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

local function directSafe(bot, root, goal, now, priority)
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
	-- A check the ray budget refused ("budget") is not an answer and is never served from the cache.
	if now - (nav.directCheckedAt or 0) < DIRECT_RECHECK and nav.directReason ~= "wall" and nav.directReason ~= "budget"
		and nav.directGoal and (nav.directGoal - goal).Magnitude < 2
		and nav.directCheckedFrom and flatDistance(root.Position, nav.directCheckedFrom) < DIRECT_MOVED_RECHECK then
		return nav.directOk, nav.directReason, nav.directWallDistance
	end
	local step = math.min(distance, DIRECT_LOOKAHEAD)
	local point = root.Position + flat(goal - root.Position).Unit * step
	local ok, reason, wallDistance = BotNav.CanStep(root, bot.character, point, stepParams(bot.character, nav), priority)
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
		if not BotNav.CanStep(root, bot.character, approach, stepParams(bot.character, nav)) then
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
			and BotNav.CanStep(root, bot.character, following + Vector3.new(0, standing, 0), stepParams(bot.character, nav)) then
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
-- Returns true while following a real route. `priority` is the ray class for the direct-line check
-- ("idle" for a wandering or looting bot, "navigation" otherwise; see BotNav.CastRay).
function BotNav.Follow(bot, humanoid, root, goal, now, priority)
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
		local safe, reason, wallDistance = directSafe(bot, root, goal, now, priority)
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
		if BotNav.CanStep(root, bot.character, nextPoint.Position + Vector3.new(0, standing, 0), stepParams(bot.character, nav), priority) then
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
		local hit, granted = BotNav.CastRay(root.Position, side * 8, params, "navigation")
		-- A refused ray is no room at all: with both refused the bot backs out, which is safe anywhere.
		local room = not granted and 0 or (hit and (hit.Position - root.Position).Magnitude or 8)
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

--------------------------------------------------------------------------------
-- DRIVING (bot drivers)
--------------------------------------------------------------------------------
-- BotService's BOT VEHICLES section decides WHETHER a bot drives and WHERE to; this section turns
-- that into a throttle, a steer and a handbrake, the same three inputs a player's keys give
-- VehicleDynamics. Nothing here moves a vehicle any other way: a bot drives by the same physics a
-- player does, and can crash, slide and get stuck the same way.
--
--   BotNav.DriveRoute(roads, from, goal, bounds, preferRoads) -> points, roadFlags, onRoads
--   BotNav.NewDrive(chassis, handling, options)  -> drive      (options: wheelbase, params, probeParams)
--   BotNav.DriveTo(drive, goal, options)                       (options: roads, bounds, via, arrive, loiter,
--                                                                preferRoads, maxSpeed)
--   BotNav.DriveSense(drive, now)       -> status   on the bot's own sliced think (BotThinkInterval)
--   BotNav.DriveControl(drive, dt, now) -> throttle, steer, handbrake   every frame
--
-- TWO CLOCKS. Everything that looks at the world is in DriveSense, which runs on the bot's sliced
-- think, four times a second, and makes AT MOST DriveCastsPerSense (4) spatial queries: one sphere
-- swept down the way it is heading (buildings, trees, walls, other vehicles), two feeler rays off
-- the front corners (which side is clearer), and one ray down onto the ground ahead (a river, a
-- drop, a steep slope). DriveControl runs every frame for the handful of bots at a wheel and is
-- arithmetic only: it steers at a point on the route ahead (pure pursuit), and holds the speed under
-- the tightest of what is known: the corners ahead, the obstacle and the hazard DriveSense last
-- found, the people on foot BotService listed (read from their parts, no query), and the goal. Four
-- decisions a second is not enough to steer a car at speed smoothly; four looks a second is plenty
-- to see what is coming, because every look reaches further than the car covers before the next.
--
-- ROUTES. Where the road network makes the trip shorter in time than going straight there (a stud of
-- country counts DRIVE_OFFROAD_COST studs of road), the route joins the nearest road, follows its
-- edges and curves to the one nearest the goal, and leaves it there, keeping DRIVE_LANE to the right
-- of the centre line so two bots meeting on one road pass. `bounds` (the storm's next circle, or a
-- team arena) keeps every road node the route passes inside it; a straight leg between two points
-- inside a circle stays inside it.
--
-- WHAT A DRIVE REPORTS (DriveSense's status): "driving"; "stopping" while it brakes for the goal;
-- "arrived" once stopped there; "hazard" stopped short of water or a drop it cannot go round;
-- "stuck" after DRIVE_STUCK_TRIES reversing manoeuvres that went nowhere; "lost" when the route
-- has made no progress for DRIVE_LOST_AFTER seconds; "flipped" when it has been on its side or roof.
-- BotService gets out (or plans again) on every one of those but "driving" and "stopping".

local DRIVE_CASTS_PER_SENSE = 4
BotNav.DriveCastsPerSense = DRIVE_CASTS_PER_SENSE

local DRIVE_LANE = 3.5            -- studs right of a road's centre line
local DRIVE_OFFROAD_COST = 1.6    -- a stud across country is worth this many studs of road (slower, and less known)
local DRIVE_ROAD_JOIN = 130       -- the network is worth joining only this close to the start and the goal
local DRIVE_ROAD_MIN = 60         -- ...and only for at least this much road
local DRIVE_BRIDGE_CLEAR = 30     -- studs past a bridge's end a route joins or leaves the road (lined up before it)
local DRIVE_CRUISE = 0.86         -- share of top speed a bot cruises at on a road
local DRIVE_OFFROAD_CRUISE = 0.62 -- ...and across country, where the next tree is only four looks away
local DRIVE_LATERAL = 95          -- studs/s^2 of cornering a bot plans for (the tyres hold more; this is the margin)
local DRIVE_DECEL_SHARE = 0.38    -- share of a vehicle's brake it plans to stop with (a look's delay, grip, a slope)
local DRIVE_STOP_MARGIN = 5       -- studs short of an obstacle or a hazard, past its own nose, that it plans to stop
local DRIVE_LOOK_MIN = 9          -- pure pursuit: the point steered at is this far ahead...
local DRIVE_LOOK_PER = 0.42       -- ...plus this many seconds of the current speed
local DRIVE_AVOID_TURN = math.rad(150) -- the most a detour turns from the route (past square: round the back of a wall)
local DRIVE_FEELER_ANGLE = math.rad(28)
local DRIVE_STUCK_SPEED = 2.5     -- slower than this while wanting to go is not going
local DRIVE_STUCK_AFTER = 1.5     -- seconds of it before reversing out
local DRIVE_REVERSE_FOR = 1.4
local DRIVE_STUCK_TRIES = 3       -- reversing manoeuvres before giving the vehicle up
local DRIVE_LOST_AFTER = 25       -- seconds without getting DRIVE_LOST_GAIN studs nearer the end of the route
local DRIVE_LOST_GAIN = 15
local DRIVE_FLIP_UP = 0.3         -- a body whose up points less than this upward is on its side
local DRIVE_FLIP_AFTER = 0.75
local DRIVE_DROP = 8              -- ground ahead this far below the wheels (and steeper than DROP_GRADE) is a drop
local DRIVE_DROP_GRADE = 0.4      -- 22 degrees down: past any road (RoadNetwork holds them under 10%)
local DRIVE_STEEP_DOWN = -0.2     -- a grade ahead steeper than this, downhill, is taken slower
local DRIVE_STOPPED = 3           -- studs/s: stopped, for arriving and for a hazard
local DRIVE_GUARD_HOLD = 2.5      -- seconds stopped for someone on foot before going round them
local DRIVE_DETOUR_SPEED = 32     -- studs/s going round something (a look every ~8 studs at this pace)
local DRIVE_OVERTAKE_CLEAR = 140  -- studs of the other lane that must be free of traffic to pull out
local WATER = Enum.Material.Water

BotNav.DriveStats = { senses = 0, casts = 0, maxCasts = 0, recoveries = 0, hazards = 0, obstacles = 0, blind = 0 }
local DSTATS = BotNav.DriveStats

-- Right of a flat direction, as a CFrame looking along it has it.
local function rightOf(d)
	return Vector3.new(-d.Z, 0, d.X)
end

local function turnFlat(d, angle)
	local c, s = math.cos(angle), math.sin(angle)
	-- Positive turns to the right (clockwise seen from above), as the steer input does.
	return Vector3.new(d.X * c - d.Z * s, 0, d.Z * c + d.X * s)
end

-- The turn from flat unit `a` to flat unit `b`, positive to the right.
local function signedAngle(a, b)
	return math.atan2(rightOf(a):Dot(b), a:Dot(b))
end

-- The same turn measured going round toward `side` (1 right, -1 left), so a detour that has swung
-- past straight back is still on its own side rather than a small turn the other way.
local function sideAngle(a, b, side)
	local angle = signedAngle(a, b) * side
	if angle < -math.rad(10) then
		angle += 2 * math.pi
	end
	return angle
end

local function nearestOnNetwork(roads, point)
	local best, bestEdge, bestDistance = nil, nil, math.huge
	for _, edge in ipairs(roads.edges) do
		local a, b = flat(edge.a.position), flat(edge.b.position)
		local ab = b - a
		local length = ab.Magnitude
		if length > 0.01 then
			local t = math.clamp(flat(point - a):Dot(ab) / (length * length), 0, 1)
			local on = a + ab * t
			local distance = flatDistance(point, on)
			if distance < bestDistance then
				best, bestEdge, bestDistance = on, edge, distance
			end
		end
	end
	return best, bestEdge, bestDistance
end

-- A bend built as a curve (RoadNetwork node.curve) as points along its arc, from the tangent nearer
-- `before`. A square corner stays a single point.
local function bendPoints(node, before)
	local curve = node.curve
	if not curve or not curve.centre or not curve.radius or not curve.a1 or not curve.sweep then
		return { flat(node.position) }
	end
	local a1, sweep = curve.a1, curve.sweep
	local centre = flat(curve.centre)
	local first = centre + Vector3.new(math.cos(a1), 0, math.sin(a1)) * curve.radius
	local last = centre + Vector3.new(math.cos(a1 + sweep), 0, math.sin(a1 + sweep)) * curve.radius
	if before and flatDistance(before, last) < flatDistance(before, first) then
		a1, sweep = a1 + sweep, -sweep
	end
	local steps = math.max(2, math.ceil(math.abs(sweep) / math.rad(15)))
	local points = {}
	for k = 0, steps do
		local angle = a1 + sweep * k / steps
		table.insert(points, centre + Vector3.new(math.cos(angle), 0, math.sin(angle)) * curve.radius)
	end
	return points
end

-- Every point moved DRIVE_LANE to the right of the way the polyline runs (along the bisector at a
-- corner, lengthened so both arms keep the lane).
local function keepRight(points)
	local out = {}
	local n = #points
	for k = 1, n do
		local incoming = k > 1 and flat(points[k] - points[k - 1]) or nil
		local outgoing = k < n and flat(points[k + 1] - points[k]) or nil
		incoming = (incoming and incoming.Magnitude > 0.01) and incoming.Unit or nil
		outgoing = (outgoing and outgoing.Magnitude > 0.01) and outgoing.Unit or nil
		local normal
		if incoming and outgoing then
			normal = rightOf(incoming) + rightOf(outgoing)
			if normal.Magnitude < 0.2 then
				normal = rightOf(incoming)
			else
				normal = normal.Unit / math.max(0.5, normal.Unit:Dot(rightOf(incoming)))
			end
		else
			normal = rightOf(incoming or outgoing or Vector3.new(0, 0, -1))
		end
		out[k] = points[k] + normal * DRIVE_LANE
	end
	return out
end

-- The route from `from` to `goal`: a list of flat points ending at the goal, a flag per point saying
-- whether the leg ending there is road, and whether the network was used. `bounds` = { center, radius }
-- keeps road nodes inside it; `preferRoads` takes the network whenever it reaches both ends (after a
-- hazard stopped a straight run), rather than only when it is quicker.
function BotNav.DriveRoute(roads, from, goal, bounds, preferRoads)
	local direct = { flat(goal) }
	local directFlags = { false }
	local edges = roads and roads.edges
	if not edges or #edges == 0 then
		return direct, directFlags, false
	end
	local entry, entryEdge, entryGap = nearestOnNetwork(roads, from)
	local exit, exitEdge, exitGap = nearestOnNetwork(roads, goal)
	if not entry or not exit or entryGap > DRIVE_ROAD_JOIN or exitGap > DRIVE_ROAD_JOIN then
		return direct, directFlags, false
	end
	local function inside(p)
		return not bounds or flatDistance(p, bounds.center) <= bounds.radius
	end

	local nodes = {}
	if entryEdge == exitEdge then
		-- One edge carries the whole trip.
		local roadLength = flatDistance(entry, exit)
		local total = (entryGap + exitGap) * DRIVE_OFFROAD_COST + roadLength
		if roadLength < DRIVE_ROAD_MIN or (not preferRoads and total >= flatDistance(from, goal) * DRIVE_OFFROAD_COST * 0.95) then
			return direct, directFlags, false
		end
	else
		local dist, prev, done = {}, {}, {}
		local function relax(node, d, via)
			if inside(node.position) and d < (dist[node] or math.huge) then
				dist[node] = d
				prev[node] = via
			end
		end
		relax(entryEdge.a, flatDistance(entry, entryEdge.a.position), false)
		relax(entryEdge.b, flatDistance(entry, entryEdge.b.position), false)
		while true do
			local node, best = nil, math.huge
			for candidate, d in pairs(dist) do
				if not done[candidate] and (d < best or (d == best and node and candidate.index and node.index and candidate.index < node.index)) then
					node, best = candidate, d
				end
			end
			if not node then
				break
			end
			done[node] = true
			for _, edge in pairs(node.arms or {}) do
				local other = edge.a == node and edge.b or edge.a
				if not done[other] then
					relax(other, best + edge.length, node)
				end
			end
		end
		local last, roadCost = nil, math.huge
		for _, node in ipairs({ exitEdge.a, exitEdge.b }) do
			if dist[node] then
				local cost = dist[node] + flatDistance(node.position, exit)
				if cost < roadCost then
					last, roadCost = node, cost
				end
			end
		end
		if not last then
			return direct, directFlags, false
		end
		local total = (entryGap + exitGap) * DRIVE_OFFROAD_COST + roadCost
		if roadCost < DRIVE_ROAD_MIN or (not preferRoads and total >= flatDistance(from, goal) * DRIVE_OFFROAD_COST * 0.95) then
			return direct, directFlags, false
		end
		local node = last
		while node do
			table.insert(nodes, 1, node)
			node = prev[node] or nil
		end
	end

	-- Join the road a little way along it toward where it is going, and leave it a little before the
	-- exit, so the car merges on and off at an angle instead of turning square onto the tarmac (on a
	-- bridge, square off it is into the river).
	local function toward(point, target, share, most)
		local offset = flat(target - point)
		local length = offset.Magnitude
		if length < 0.01 then
			return point
		end
		return point + offset.Unit * math.min(length * 0.8, math.min(most, share))
	end
	local firstTarget = nodes[1] and flat(nodes[1].position) or exit
	entry = toward(entry, firstTarget, entryGap * 0.5 + 6, 20)
	local lastSource = nodes[#nodes] and flat(nodes[#nodes].position) or entry
	exit = toward(exit, lastSource, exitGap * 0.5, 20)
	-- Never on or off the road on a bridge (RoadNetwork edge.bridges, studs along the edge from its
	-- start): across country to a bridge is across the river it spans. The bank on the car's side
	-- (or the goal's), clear of the abutment.
	local function offBridge(edge, point, side)
		local a = flat(edge.a.position)
		local ab = flat(edge.b.position) - a
		local length = ab.Magnitude
		if length < 0.01 or not edge.bridges then
			return point
		end
		local unit = ab.Unit
		local along = flat(point - a):Dot(unit)
		local sideAlong = flat(side - a):Dot(unit)
		for _, span in ipairs(edge.bridges) do
			if along > span.s0 - DRIVE_BRIDGE_CLEAR and along < span.s1 + DRIVE_BRIDGE_CLEAR then
				local before, after = span.s0 - DRIVE_BRIDGE_CLEAR, span.s1 + DRIVE_BRIDGE_CLEAR
				along = math.abs(sideAlong - before) <= math.abs(sideAlong - after) and before or after
				along = math.clamp(along, 0, length)
			end
		end
		return a + unit * along
	end
	-- (Already on the road, on the bridge itself, it just drives on along it.)
	if entryGap > 11 then
		entry = offBridge(entryEdge, entry, from)
	end
	if exitGap > 11 then
		exit = offBridge(exitEdge, exit, goal)
	end

	-- The road part: on at the entry, through each node (a curve's arc for a curved bend), off at the exit.
	local road = { entry }
	for _, node in ipairs(nodes) do
		for _, point in ipairs(bendPoints(node, road[#road])) do
			if flatDistance(point, road[#road]) > 1 then
				table.insert(road, point)
			end
		end
	end
	if flatDistance(exit, road[#road]) > 1 then
		table.insert(road, exit)
	end
	road = keepRight(road)

	local points, flags = {}, {}
	for index, point in ipairs(road) do
		table.insert(points, point)
		-- The leg to the entry is across country; everything after it is road.
		table.insert(flags, index > 1)
	end
	if flatDistance(goal, points[#points]) > 2 then
		table.insert(points, flat(goal))
		table.insert(flags, false)
	end
	return points, flags, true
end

function BotNav.NewDrive(chassis, handling, options)
	options = options or {}
	local size = chassis.Size
	return {
		chassis = chassis,
		handling = handling,
		wheelbase = options.wheelbase or size.Z * 0.62,
		-- A bike is narrow, but it still needs a gap wider than its handlebars.
		halfWidth = math.max(size.X / 2, 1.6),
		halfLength = size.Z / 2,
		params = options.params,
		probeParams = options.probeParams or options.params,
		rideHeight = options.rideHeight or 2.5,
		route = { [0] = flat(chassis.Position) },
		roadLeg = {},
		index = 1,
		goal = flat(chassis.Position),
		arrive = 25,
		senseCap = math.huge,
		maxSpeed = nil,
		guard = {},
		stuck = { tries = 0, anchor = chassis.Position },
		lastSteer = 0,
		stats = { senses = 0, casts = 0, maxCasts = 0, recoveries = 0 },
	}
end

-- (Re)plans the drive toward `goal`. `via` points come first (a base's drive-out lane).
function BotNav.DriveTo(drive, goal, options)
	options = options or {}
	local start = flat(drive.chassis.Position)
	local route, flags = {}, {}
	local from = start
	for _, point in ipairs(options.via or {}) do
		table.insert(route, flat(point))
		table.insert(flags, false)
		from = flat(point)
	end
	local points, roadFlags, onRoads = BotNav.DriveRoute(options.roads, from, goal, options.bounds, options.preferRoads)
	for index, point in ipairs(points) do
		table.insert(route, point)
		table.insert(flags, roadFlags[index])
	end
	route[0] = start
	drive.route = route
	drive.roadLeg = flags
	drive.index = 1
	drive.goal = flat(goal)
	drive.onRoads = onRoads
	drive.arrive = options.arrive or 25
	drive.loiter = options.loiter == true
	drive.maxSpeed = options.maxSpeed
	drive.stopping = false
	drive.hazard = nil
	drive.obstacle = nil
	drive.shift = nil
	drive.lastGoodGround = nil
	drive.bestRemaining = math.huge
	drive.progressAt = nil
	drive.stuckSince = nil
	return onRoads
end

-- How far along what is left of the route, from `position`.
local function remaining(drive, position)
	local route = drive.route
	local total = flatDistance(position, route[drive.index] or position)
	for k = drive.index + 1, #route do
		total += flatDistance(route[k - 1], route[k])
	end
	return total
end

-- Moves drive.index past every point the vehicle has reached or driven by.
local function advance(drive, position, look)
	local route = drive.route
	while drive.index < #route do
		local a, b = route[drive.index - 1], route[drive.index]
		local ab = b - a
		local length = ab.Magnitude
		local t = length > 0.01 and flat(position - a):Dot(ab) / (length * length) or 1
		if t >= 1 or flatDistance(position, b) < math.max(6, look * 0.5) then
			drive.index += 1
		else
			break
		end
	end
end

-- The pure-pursuit point: `look` studs along the route from where the vehicle is on it, moved across
-- by drive.shift (overtaking in the other lane) where one is set.
local function pursuitPoint(drive, position, look)
	local point = BotNav.RoutePoint(drive, position, look)
	local shift = drive.shift
	if shift then
		local route = drive.route
		local k = math.min(drive.index, #route)
		local along = flat(route[k] - route[k - 1])
		if along.Magnitude > 0.01 then
			point += rightOf(along.Unit) * shift.amount
		end
	end
	return point
end

function BotNav.RoutePoint(drive, position, look)
	local route = drive.route
	local k = drive.index
	-- The first leg runs from wherever the car is now, not from where it was when the route was made
	-- (it may since have backed away from a river, or been pushed).
	local a, b = k == 1 and flat(position) or route[k - 1], route[k]
	local ab = flat(b - a)
	local length = ab.Magnitude
	local on = b
	if length > 0.01 then
		local t = math.clamp(flat(position - a):Dot(ab) / (length * length), 0, 1)
		on = a + ab * t
	end
	-- Off the line (a detour round something, or just joined): aim back onto it, not along it from
	-- a point beside us, so the car closes on the route at an angle rather than running parallel.
	local left = math.max(1, look - flatDistance(position, on) * 0.5)
	local from = on
	while true do
		local to = route[k]
		local span = flatDistance(from, to)
		if left <= span or k >= #route then
			if span < 0.01 then
				return to
			end
			return from + (to - from).Unit * math.min(left, span)
		end
		left -= span
		from = to
		k += 1
	end
end

-- The tightest circle the vehicle's wheels can steer at `speed` (the lock narrows with speed, as
-- VehicleDynamics.Step narrows it).
local function turningRadius(h, wheelbase, speed)
	local fraction = math.clamp(speed / h.topSpeed, 0, 1)
	local lock = h.steerLow + (h.steerHigh - h.steerLow) * fraction ^ 0.75
	return wheelbase / math.tan(math.rad(lock))
end

-- The fastest a vehicle can go round a circle of `radius`: within DRIVE_LATERAL of cornering, and
-- no tighter than its steering lock allows at that speed.
local function arcSpeed(h, wheelbase, radius)
	local v = math.min(h.topSpeed, math.sqrt(DRIVE_LATERAL * radius))
	while v > 12 and turningRadius(h, wheelbase, v) > radius * 1.15 do
		v -= 2
	end
	return v
end

-- The speed a vehicle can take a turn of `turn` radians at, round a curve of about `radius` studs
-- (math.huge for a single sharp corner, which pure pursuit rounds off over its lookahead): within
-- DRIVE_LATERAL of cornering, and slow enough that the steering lock can still make the circle.
local function cornerSpeed(turn, radius, h, wheelbase)
	local chord = 2 * math.sin(turn / 2)
	local v = h.topSpeed
	while v > 12 do
		-- Pure pursuit rounds a sharp corner to about lookahead / chord (and runs a little wide of
		-- that, which the lane has room for).
		local path = math.min(radius, (DRIVE_LOOK_MIN + DRIVE_LOOK_PER * v) / chord)
		if v * v <= DRIVE_LATERAL * path and turningRadius(h, wheelbase, v) <= path * 1.15 then
			break
		end
		v -= 2
	end
	-- Past a right angle it is a turn back on itself, taken at a crawl whatever the sums say.
	if turn > math.rad(100) then
		v = math.min(v, 18)
	end
	return v
end

-- The highest speed from which every corner coming up can still be made, braking at `decel`.
local function cornerCap(drive, position, speed, decel)
	local route = drive.route
	local cap = math.huge
	local reach = speed * speed / (2 * decel) + 40
	local first = drive.index
	-- The corner just passed still counts while the car is coming out of it (advance moves on from a
	-- corner half a lookahead early).
	if first > 1 and flatDistance(position, route[first - 1]) < DRIVE_LOOK_MIN + DRIVE_LOOK_PER * speed then
		first -= 1
	end
	local along = 0
	for k = first, #route - 1 do
		if k == drive.index then
			along = flatDistance(position, route[k])
		elseif k > drive.index then
			along += flatDistance(route[k - 1], route[k])
		end
		if along > reach then
			break
		end
		local d1 = flat(route[k] - route[k - 1])
		local d2 = flat(route[k + 1] - route[k])
		local l1, l2 = d1.Magnitude, d2.Magnitude
		if l1 > 0.1 and l2 > 0.1 then
			local turn = math.acos(math.clamp(d1.Unit:Dot(d2.Unit), -1, 1))
			if turn > math.rad(10) then
				-- Short legs either side are an arc; long ones a corner.
				local radius = math.min(l1, l2) < 30 and math.min(l1, l2) / 2 / math.tan(turn / 2) or math.huge
				local v = cornerSpeed(turn, radius, drive.handling, drive.wheelbase)
				cap = math.min(cap, math.sqrt(v * v + 2 * decel * math.max(0, along - 2)))
			end
		end
	end
	return cap
end

-- Speed allowed now to stop `margin` short of something `ahead` studs in front of the nose.
local function stopCap(ahead, margin, decel)
	return math.sqrt(2 * decel * math.max(0, ahead - margin))
end

-- A spatial query that counts toward DriveCastsPerSense: a ray from `origin`, or with `size` a box
-- swept from the CFrame `origin`.
-- Every query DriveSense makes, counted against the bots' shared frame budget as "navigation".
-- DriveSense reserves its whole look before the first one (see "blind"), so none is refused midway.
local function cast(drive, origin, size, direction, params)
	drive.castsThisSense += 1
	if size then
		if not BotNav.CastSpend("navigation") then
			return nil
		end
		return workspace:Blockcast(origin, size, direction, params)
	end
	return (BotNav.CastRay(origin, direction, params, "navigation"))
end

-- Whether what a sweep met is moving toward us along it (another vehicle coming the other way). Read
-- off the part it hit, not queried.
local function oncoming(hit, along)
	local part = hit and hit.Instance
	if not part or not part:IsA("BasePart") or part.Anchored then
		return false
	end
	local velocity = part.AssemblyLinearVelocity
	return velocity ~= nil and Vector3.new(velocity.X, 0, velocity.Z):Dot(along) < -4
end

-- Whether what a sweep met is a vehicle (something loose, not the scenery) standing over to the left
-- of the way we are going, in the other lane, by its own middle: a part's Position is read, not
-- queried. A parked or stopped car in the other lane is passed on the right of, not overtaken into.
local function leftOfUs(hit, position, along)
	local part = hit and hit.Instance
	if not part or not part:IsA("BasePart") or part:IsA("Terrain") or part.Anchored then
		return false
	end
	return rightOf(along):Dot(flat(part.Position - position)) < -2
end

-- Whether the other lane is free to pull out into: no vehicle in drive.traffic (their chassis, read
-- not queried) ahead in it within DRIVE_OVERTAKE_CLEAR, unless it is going our way faster than we are.
local function laneClear(drive, position, along)
	local ownSpeed = drive.chassis.AssemblyLinearVelocity:Dot(along)
	for _, chassis in ipairs(drive.traffic or {}) do
		if chassis.Parent and chassis ~= drive.chassis then
			local offset = flat(chassis.Position - position)
			local ahead = offset:Dot(along)
			local across = rightOf(along):Dot(offset)
			if ahead > -drive.halfLength and ahead < DRIVE_OVERTAKE_CLEAR and across < 3 and across > -(DRIVE_LANE * 2 + 8) then
				if chassis.AssemblyLinearVelocity:Dot(along) < ownSpeed + 2 then
					return false
				end
			end
		end
	end
	return true
end

-- Whether a hit is something a vehicle cannot drive through: not ground it can climb (a face turned
-- up), not a part nothing collides with (road slabs, markings, foliage).
local function blocking(hit)
	if not hit then
		return false
	end
	if hit.Normal.Y > 0.6 then
		return false
	end
	local part = hit.Instance
	if part and part:IsA("BasePart") and not part:IsA("Terrain") and not part.CanCollide then
		return false
	end
	return true
end

function BotNav.DriveSense(drive, now)
	local chassis = drive.chassis
	local frame = chassis.CFrame
	local position = frame.Position
	local velocity = chassis.AssemblyLinearVelocity
	local look = flat(frame.LookVector)
	look = look.Magnitude > 0.05 and look.Unit or Vector3.new(0, 0, -1)
	local speed = velocity:Dot(frame.LookVector)
	local h = drive.handling
	drive.castsThisSense = 0
	drive.stats.senses += 1
	DSTATS.senses += 1

	-- On its side or roof: nothing to steer.
	if frame.UpVector.Y < DRIVE_FLIP_UP then
		drive.flippedSince = drive.flippedSince or now
		if now - drive.flippedSince >= DRIVE_FLIP_AFTER then
			return "flipped"
		end
		return "driving"
	end
	drive.flippedSince = nil

	local lookahead = DRIVE_LOOK_MIN + DRIVE_LOOK_PER * math.abs(speed)
	advance(drive, position, lookahead)
	local left = remaining(drive, position)

	-- Arriving: brake for the goal, then report it.
	if not drive.loiter and drive.index >= #drive.route and flatDistance(position, drive.goal) <= drive.arrive then
		drive.stopping = true
	end
	if drive.stopping then
		if math.abs(speed) < DRIVE_STOPPED then
			return "arrived"
		end
		return "stopping"
	end

	-- Progress: the route has to keep getting shorter, whatever is in the way.
	if left < drive.bestRemaining - DRIVE_LOST_GAIN or not drive.progressAt then
		drive.bestRemaining = math.min(drive.bestRemaining, left)
		drive.progressAt = now
	elseif now - drive.progressAt > DRIVE_LOST_AFTER and not drive.loiter then
		return "lost"
	end

	-- The frame's ray budget can't cover a whole look: nothing is looked at this think, so nothing is
	-- driven into that hasn't been seen (DriveControl eases off until the next look; the last look's
	-- findings stand meanwhile).
	if BotNav.CastRemaining("navigation") < DRIVE_CASTS_PER_SENSE then
		drive.blindUntil = now + 0.4
		DSTATS.blind += 1
		return "driving"
	end
	drive.blindUntil = nil

	-- An overtake ends once what it was passing is a car's length behind (or it has gone on too long).
	local shift = drive.shift
	if shift and (now > shift.untilTime or flat(shift.point - position):Dot(look) < -(drive.halfLength + 6)) then
		drive.shift = nil
	end
	local target = pursuitPoint(drive, position, lookahead)
	local heading = flat(target - position)
	heading = heading.Magnitude > 0.5 and heading.Unit or look
	-- Where it is actually steering: the route, or the way round whatever it is going round. That
	-- way is held in world terms, not as an angle off the route: the route's own pull swings as the
	-- car moves sideways, and an angle off it would swing the detour back into the thing it avoids.
	local avoid = drive.avoid
	if avoid and now >= avoid.untilTime then
		avoid = nil
		drive.avoid = nil
	end
	local steering = avoid and avoid.dir or heading
	local reach = math.clamp(math.abs(speed) * 1.1 + 16, 20, 90)
	local groundHere = position.Y - drive.rideHeight
	local bumper = Vector3.new(0, 1.2, 0)
	local reversing = drive.reverseUntil and now < drive.reverseUntil
	-- Backing round in a three-point turn is backing too.
	local backing = reversing or drive.turning ~= nil

	-- 1: the car's own width swept straight ahead of it, from a stud above the ground up to head
	-- height: buildings, trees, walls, other vehicles; not a kerb, not the road. That is the way it
	-- is going now, and what DriveControl brakes for. While backing out of somewhere, swept behind
	-- instead, so it stops backing before it backs into something.
	local width = drive.halfWidth * 2 + 1
	local boxAt = Vector3.new(position.X, groundHere + 2.6, position.Z)
	local boxSize = Vector3.new(width, 2.6, 1)
	local frontDir = backing and -look or look
	local frontReach = backing and drive.halfLength + 8 or reach
	local front = cast(drive, CFrame.lookAt(boxAt, boxAt + frontDir), boxSize, frontDir * frontReach, drive.params)
	if backing then
		if blocking(front) and front.Distance < drive.halfLength + 3 + math.abs(speed) * 0.3 then
			drive.reverseUntil = now
			if drive.turning then
				-- No room to back round: no more three-point turns for a moment.
				drive.turning = nil
				drive.noTurnUntil = now + 2
			end
		end
		front = nil
	end
	if blocking(front) then
		drive.front = { point = boxAt + look * front.Distance, untilTime = now + 0.5 }
	else
		drive.front = nil
	end
	-- 2: the way it would like to go. Going round something, that is the way back toward the route,
	-- eased in a step, and it is only taken once this sweep finds it clear (turning back without
	-- looking first walks the car back into the corner it was going round). Otherwise, the route. When
	-- that is straight ahead, sweep 1 has looked already and a second feeler is had instead.
	local candidate = heading
	local backOff = 0
	if avoid then
		backOff = sideAngle(heading, avoid.dir, avoid.side)
		candidate = backOff < math.rad(6) and heading or turnFlat(heading, avoid.side * backOff * 0.55)
	end
	local separate = not reversing and look:Dot(candidate) < math.cos(math.rad(10))
	local ahead = front
	if separate then
		ahead = cast(drive, CFrame.lookAt(boxAt, boxAt + candidate), boxSize, candidate * reach, drive.params)
	end
	-- 2/3: feelers off the front corners, either side of the nose: which way is clearer. With two
	-- sweeps this look, only the one on the side it is turning toward.
	local nose = position + look * drive.halfLength + bumper
	local side = rightOf(look) * drive.halfWidth
	local feelerLength = reach * 0.6
	local turnSide = signedAngle(look, candidate) >= 0 and 1 or -1
	local leftClear, rightClear = feelerLength, feelerLength
	if not separate or turnSide < 0 then
		local hit = cast(drive, nose - side, nil, turnFlat(look, -DRIVE_FEELER_ANGLE) * feelerLength, drive.params)
		leftClear = blocking(hit) and (hit.Position - (nose - side)).Magnitude or feelerLength
	end
	if not separate or turnSide > 0 then
		local hit = cast(drive, nose + side, nil, turnFlat(look, DRIVE_FEELER_ANGLE) * feelerLength, drive.params)
		rightClear = blocking(hit) and (hit.Position - (nose + side)).Magnitude or feelerLength
	end

	-- The way along a face that was met, on `turnTo`'s side, a little away from it.
	local function alongFace(hit, turnTo, from)
		local normal = flat(hit.Normal)
		if normal.Magnitude < 0.3 then
			return turnFlat(from, turnTo * math.rad(35))
		end
		local n = normal.Unit
		local tangent = rightOf(n)
		if tangent:Dot(turnFlat(from, turnTo * math.pi / 2)) < 0 then
			tangent = -tangent
		end
		return (tangent + n * 0.3).Unit
	end

	if avoid then
		if not blocking(ahead) then
			-- The way back is clear: take it (all the way, once it is the route).
			if backOff < math.rad(6) then
				drive.avoid = nil
			else
				avoid.dir = candidate
				avoid.untilTime = now + 0.9
			end
		else
			-- Still in the way: keep going round.
			avoid.untilTime = now + 0.9
		end
		-- What it is going round along is itself blocked ahead (a corner turning in): along that face.
		if drive.avoid and blocking(front) and front.Distance - drive.halfLength < reach * 0.6 then
			local dir = alongFace(front, avoid.side, look)
			if sideAngle(avoid.dir, dir, avoid.side) < math.rad(5) then
				dir = turnFlat(avoid.dir, avoid.side * math.rad(20))
			end
			if sideAngle(heading, dir, avoid.side) > DRIVE_AVOID_TURN then
				dir = turnFlat(heading, avoid.side * DRIVE_AVOID_TURN)
			end
			avoid.dir = dir
		end
	elseif blocking(ahead) and (oncoming(ahead, candidate) or (drive.roadLeg[drive.index] and leftOfUs(ahead, position, candidate))) then
		-- Another vehicle coming the other way in our path, or something over in the other lane: over
		-- to the right and slow, as anyone would (pulling out to the left is into it).
		DSTATS.obstacles += 1
		drive.shift = { amount = drive.roadLeg[drive.index] and 3 or 8, point = boxAt + candidate * ahead.Distance, untilTime = now + 3 }
		drive.obstacle = { point = boxAt + candidate * ahead.Distance, untilTime = now + 0.5 }
	elseif blocking(ahead) and drive.roadLeg[drive.index] and not drive.shift and ahead.Distance > drive.halfLength + 12 then
		-- On a road, something in the lane: pull into the other lane to pass it, as anyone would (the
		-- right is the verge), and back once it is behind; but not with traffic coming the other way in
		-- that lane (drive.traffic, BotService's list of the vehicles about): then wait behind it.
		DSTATS.obstacles += 1
		local point = boxAt + candidate * ahead.Distance
		if laneClear(drive, position, candidate) then
			drive.shift = { amount = -(DRIVE_LANE * 2 + 1.5), point = point, untilTime = now + 8 }
		else
			drive.obstacle = { point = point, untilTime = now + 0.5 }
		end
	elseif blocking(ahead) then
		DSTATS.obstacles += 1
		local distance = math.max(1, ahead.Distance - drive.halfLength)
		local normal = flat(ahead.Normal)
		local turnTo
		if math.abs(leftClear - rightClear) > 2 then
			turnTo = rightClear > leftClear and 1 or -1
		elseif drive.roadLeg[drive.index] then
			-- On a road, round it on the left, through the other lane, as anyone would: the right is the verge.
			turnTo = -1
		else
			-- Round whichever side the face it met is turned toward.
			turnTo = (normal.Magnitude > 0.3 and normal.Unit:Dot(rightOf(heading)) >= 0) and 1 or -1
		end
		local dir
		if distance < reach * 0.6 then
			dir = alongFace(ahead, turnTo, heading)
		else
			-- Far off, a nudge that gets the nose a car's width and a margin clear by the time it is there.
			dir = turnFlat(heading, turnTo * 1.6 * math.atan2(drive.halfWidth + 3.5, distance))
		end
		drive.avoid = { side = turnTo, dir = dir, untilTime = now + 0.9 }
		drive.obstacle = { point = boxAt + candidate * ahead.Distance, untilTime = now + 0.5 }
	elseif math.min(leftClear, rightClear) < feelerLength * 0.45 then
		-- Something close off one corner: ease away from it.
		local away = leftClear < rightClear and 1 or -1
		drive.avoid = { side = away, dir = turnFlat(heading, away * math.rad(10)), untilTime = now + 0.4 }
	end
	-- Nose up against something: going forward can't turn it away (a car turns by moving), so that is
	-- stuck, not waiting. Either both corners are on it, or it is right in front.
	drive.blocked = (leftClear < 4 and rightClear < 4)
		or (blocking(front) and front.Distance - drive.halfLength < DRIVE_STOP_MARGIN + 1)

	-- 4: the ground ahead, water counted (a wheel ray ignores it; a river is not a road). Far enough
	-- out that the car can stop short of the last ground it saw was good, which is where it stops
	-- for water or a drop: the edge is somewhere between that and this.
	local probeDistance = math.clamp(math.abs(speed) * 1.1 + 12, 14, 90)
	-- Turning, the car's path runs between where it points and where it steers: probe down the middle.
	local probeAt
	if reversing then
		-- Backing: behind it, a length out.
		probeDistance = 8
		probeAt = position - look * (drive.halfLength + probeDistance)
	else
		-- Where the car will be that far on: round the tightest circle it can steer at this speed until
		-- it points where it is steering, then straight on. (Straight at the steering point would probe
		-- ground the car's arc never reaches, and straight on ground it is turning away from.)
		local reachAlong = drive.halfLength + probeDistance
		local turn = signedAngle(look, steering)
		local radius = turningRadius(h, drive.wheelbase, math.abs(speed))
		local arc = radius * math.abs(turn)
		if arc >= reachAlong then
			local angle = reachAlong / radius
			probeAt = position + look * (radius * math.sin(angle))
				+ rightOf(look) * ((turn > 0 and 1 or -1) * radius * (1 - math.cos(angle)))
		else
			probeAt = position + look * (radius * math.sin(math.abs(turn)))
				+ rightOf(look) * ((turn > 0 and 1 or -1) * radius * (1 - math.cos(turn)))
				+ steering * (reachAlong - arc)
		end
	end
	local below = cast(drive, Vector3.new(probeAt.X, groundHere + 25, probeAt.Z), nil, Vector3.new(0, -80, 0), drive.probeParams)
	local hazard = false
	drive.steepAhead = false
	drive.dropAhead = false
	if not below or below.Material == WATER then
		hazard = true
	else
		local drop = groundHere - below.Position.Y
		if drop > math.max(DRIVE_DROP, probeDistance * DRIVE_DROP_GRADE) then
			hazard = true
		elseif drop > DRIVE_DROP then
			-- Lower by more than a bank, but not steeply for how far off it is: a long slope, or a cliff
			-- whose foot is what this ray found. Slow enough that the next looks, nearer in, can tell.
			drive.dropAhead = true
		elseif -drop / probeDistance < DRIVE_STEEP_DOWN then
			drive.steepAhead = true
		end
	end
	local lastGood = drive.lastGoodGround
	local known = drive.hazard and now < drive.hazard.untilTime
	if reversing then
		-- Water or a drop behind: stop backing. Nothing is learnt about the way ahead.
		if hazard then
			drive.reverseUntil = now
		end
	elseif hazard then
		DSTATS.hazards += 1
		-- Stop short of the last ground that was fine, if it is still ahead; otherwise short of here. A
		-- stop already set nearer stands: a later look from further on only sees further past the edge.
		local stopAt = lastGood and flat(lastGood - position):Dot(look) > drive.halfLength and lastGood
			or position + look * (drive.halfLength + 1)
		if known and flat(drive.hazard.point - position):Dot(look) < flat(stopAt - position):Dot(look) then
			stopAt = drive.hazard.point
		end
		drive.hazard = { point = Vector3.new(stopAt.X, position.Y, stopAt.Z), untilTime = now + 1.5, at = now }
	elseif not drive.dropAhead and not known then
		-- Only ground that is plainly fine counts; a drop that might be a cliff's foot does not.
		drive.lastGoodGround = Vector3.new(probeAt.X, position.Y, probeAt.Z)
	end

	drive.stats.casts += drive.castsThisSense
	drive.stats.maxCasts = math.max(drive.stats.maxCasts, drive.castsThisSense)
	DSTATS.casts += drive.castsThisSense
	DSTATS.maxCasts = math.max(DSTATS.maxCasts, drive.castsThisSense)

	-- The speed this look allows, whatever DriveControl works out between looks.
	local onRoad = drive.roadLeg[drive.index] == true
	local cap = h.topSpeed * (onRoad and DRIVE_CRUISE or DRIVE_OFFROAD_CRUISE)
	if drive.steepAhead then
		cap = math.min(cap, h.topSpeed * 0.5)
	end
	if drive.dropAhead then
		cap = math.min(cap, 20)
	end
	if drive.maxSpeed then
		cap = math.min(cap, drive.maxSpeed)
	end
	drive.senseCap = cap

	-- Stopped short of a hazard: nothing more this route can do. Back off a length first, straight, so
	-- whatever comes next turns away from the edge rather than round over it.
	if drive.hazard and now < drive.hazard.untilTime and math.abs(speed) < DRIVE_STOPPED then
		drive.hazard = nil
		drive.reverseUntil = now + 2.4
		drive.reverseSteer = 0
		return "hazard"
	end

	-- Stuck: wanting to go, and not going. Reverse out turning, then try the other way round.
	reversing = drive.reverseUntil and now < drive.reverseUntil
	-- Standing still counts as stuck whatever is holding it (an obstacle that won't move, a wheel
	-- against a kerb, the nose on a wall), except the goal, someone on foot, or being told to hold.
	local wants = not drive.guardHolding and not drive.hold and ((drive.wantedSpeed or 0) > 6 or drive.blocked
		or (drive.obstacle ~= nil and now < drive.obstacle.untilTime))
	if flatDistance(position, drive.stuck.anchor) > 30 then
		drive.stuck.tries = 0
		drive.stuck.anchor = position
	end
	if reversing then
		drive.stuckSince = nil
	elseif wants and math.abs(speed) < DRIVE_STUCK_SPEED then
		drive.stuckSince = drive.stuckSince or now
		if now - drive.stuckSince >= DRIVE_STUCK_AFTER then
			drive.stuck.tries += 1
			drive.stats.recoveries += 1
			DSTATS.recoveries += 1
			if drive.stuck.tries > DRIVE_STUCK_TRIES then
				return "stuck"
			end
			-- Round the other side from last time, or from whichever corner is more boxed in.
			local turnTo = drive.avoid and -drive.avoid.side or (rightClear >= leftClear and 1 or -1)
			if drive.stuck.tries % 2 == 0 then
				turnTo = -turnTo
			end
			drive.reverseUntil = now + DRIVE_REVERSE_FOR
			-- Backing with the wheels turned one way swings the nose the other.
			drive.reverseSteer = -turnTo
			drive.avoid = { side = turnTo, dir = turnFlat(look, turnTo * math.rad(60)), untilTime = drive.reverseUntil + 1.5 }
			drive.stuckSince = nil
		end
	else
		drive.stuckSince = nil
	end
	return "driving"
end

-- The throttle, steer and handbrake for this frame. Arithmetic on what DriveSense and BotService
-- left on `drive`; no queries.
function BotNav.DriveControl(drive, dt, now)
	local chassis = drive.chassis
	local frame = chassis.CFrame
	local position = frame.Position
	local speed = chassis.AssemblyLinearVelocity:Dot(frame.LookVector)
	local h = drive.handling
	local decel = h.brake * DRIVE_DECEL_SHARE

	if drive.hold then
		drive.wantedSpeed = 0
		if speed > 1.5 then
			return -1, 0, false
		end
		return 0, 0, true
	end
	if drive.reverseUntil and now < drive.reverseUntil then
		drive.wantedSpeed = 0
		-- Backing out at a walk: nothing behind has been looked at for more than a car's length or so.
		return speed < -10 and 0 or -0.8, drive.reverseSteer or 0, false
	end

	local lookahead = DRIVE_LOOK_MIN + DRIVE_LOOK_PER * math.abs(speed)
	advance(drive, position, lookahead)
	local target = pursuitPoint(drive, position, lookahead)
	local toTarget = flat(target - position)
	local distance = toTarget.Magnitude
	local direction = distance > 0.05 and toTarget.Unit or flat(frame.LookVector).Unit
	local avoid = drive.avoid
	if avoid and now < avoid.untilTime then
		direction = avoid.dir
	end

	-- The speed that can be held: the tightest of everything known.
	local cap = drive.senseCap or h.topSpeed
	cap = math.min(cap, cornerCap(drive, position, math.abs(speed), decel))

	if not drive.loiter then
		local toGoal = flatDistance(position, drive.goal)
		if drive.index >= #drive.route then
			cap = math.min(cap, stopCap(toGoal, drive.arrive * 0.4, decel) + (drive.stopping and 0 or 2))
		end
		if drive.stopping then
			cap = 0
		end
	end
	local obstacle = drive.obstacle
	if obstacle and now < obstacle.untilTime then
		-- The way it wants to go is blocked a little way off: take the detour at a pace that can still
		-- change its mind. What it stops for is what is in FRONT of it (below), not what is round the
		-- corner it is steering toward, or it would stop at every corner of what it is going round.
		local gap = flatDistance(obstacle.point, position) - drive.halfLength
		cap = math.min(cap, math.max(14, stopCap(gap, DRIVE_STOP_MARGIN, decel)))
	end
	local front = drive.front
	if front and now < front.untilTime then
		-- Straight ahead of the nose, the way it is pointing now.
		local look = flat(frame.LookVector)
		local gap = flat(front.point - position):Dot(look.Magnitude > 0.05 and look.Unit or direction) - drive.halfLength
		cap = math.min(cap, stopCap(gap, 3, decel) + (gap > 8 and 2 or 0))
	end
	local hazard = drive.hazard
	if hazard and now < hazard.untilTime then
		local rel = frame:PointToObjectSpace(hazard.point)
		cap = math.min(cap, stopCap(-rel.Z - drive.halfLength, DRIVE_STOP_MARGIN, decel))
	end

	-- People on foot BotService listed: stop short of anyone in the way (a teammate always), and
	-- after DRIVE_GUARD_HOLD of waiting, go round them.
	local holding = false
	local swerve = 0
	for _, guard in ipairs(drive.guard) do
		local root = guard.root
		if root and root.Parent then
			local rel = frame:PointToObjectSpace(root.Position)
			local ahead = -rel.Z - drive.halfLength
			local reach = speed * speed / (2 * decel) + 12
			-- Where they will be across the car's path by the time it gets there, as well as where they
			-- are: someone running across the road is in the way before they are in the lane.
			local across = frame:VectorToObjectSpace(root.AssemblyLinearVelocity or Vector3.zero).X
			local later = rel.X + across * math.min(math.max(ahead, 0) / math.max(math.abs(speed), 5), 1.5)
			local nearest = (rel.X > 0) ~= (later > 0) and 0 or math.min(math.abs(rel.X), math.abs(later))
			local lateral = nearest - drive.halfWidth
			if ahead > -2 and ahead < reach and lateral < 3 then
				local allowed = stopCap(ahead, 3.5, decel)
				if guard.hard then
					cap = math.min(cap, allowed)
					holding = holding or allowed < 1
				else
					cap = math.min(cap, math.max(allowed, 6))
				end
				swerve = rel.X > 0 and -1 or 1
			end
		end
	end
	if holding then
		drive.guardSince = drive.guardSince or now
	else
		drive.guardSince = nil
	end
	drive.guardHolding = holding
	if swerve ~= 0 and (not holding or now - drive.guardSince > DRIVE_GUARD_HOLD) then
		direction = turnFlat(direction, swerve * math.rad(35))
		if holding then
			-- Round them at a walk: the cap above lifts once they are no longer in front.
			cap = 5
		end
	end

	-- Pure pursuit: the wheel angle whose arc passes through the point steered at.
	local localDirection = frame:VectorToObjectSpace(direction)
	local alpha = math.atan2(localDirection.X, -localDirection.Z)
	local reachOf = math.max(distance, 6)
	local wheel = math.deg(math.atan(2 * drive.wheelbase * math.sin(alpha) / reachOf))
	local fraction = math.clamp(math.abs(speed) / h.topSpeed, 0, 1)
	local maxSteer = h.steerLow + (h.steerHigh - h.steerLow) * fraction ^ 0.75
	local steer = math.clamp(wheel / maxSteer, -1, 1)

	-- The arc pure pursuit is steering right now, at a speed the tyres and the steering lock can hold
	-- it at (a turn taken too fast runs wide, off the road and toward whatever is beside it). A point
	-- well round to the side wants a slow turn, not a fast arc: the arc goes where no look has been yet.
	if math.abs(alpha) > math.rad(3) then
		cap = math.min(cap, arcSpeed(h, drive.wheelbase, reachOf / (2 * math.sin(math.min(math.abs(alpha), math.pi / 2)))))
	end
	if math.abs(alpha) > math.rad(60) then
		cap = math.min(cap, 22)
	end
	if avoid and now < avoid.untilTime then
		cap = math.min(cap, DRIVE_DETOUR_SPEED)
	end
	-- Behind, at a crawl: back round toward it (a three-point turn) instead of a wide loop, committed
	-- to one side until the nose is round, so a point straight behind can't flip it from side to side.
	local turning = drive.turning
	if not turning and math.abs(alpha) > math.rad(115) and math.abs(speed) < 8 and cap > 1 and now >= (drive.noTurnUntil or 0) then
		local side = alpha > 0 and 1 or -1
		if math.abs(alpha) > math.rad(165) then
			side = drive.turnSide or side
		end
		turning = { side = side, untilTime = now + 3 }
		drive.turning = turning
		drive.turnSide = side
	end
	if turning then
		if math.abs(alpha) < math.rad(70) or now > turning.untilTime or cap <= 1 then
			drive.turning = nil
		else
			drive.wantedSpeed = cap
			-- Backing with the wheels turned one way swings the nose the other; at a walk, as when
			-- backing out (DriveSense sweeps behind for it).
			return speed < -10 and 0 or -0.7, -turning.side, false
		end
	end

	drive.wantedSpeed = cap
	drive.lastSteer = steer
	local throttle, handbrake = 0, false
	if drive.blindUntil and now < drive.blindUntil and cap >= 1 then
		-- A look skipped for the ray budget: nothing new has been seen, so brake lightly (never on into
		-- the unseen) until the next look; the last look's caps above still stand.
		throttle = speed > 1.5 and -0.35 or 0
		handbrake = speed < 2
	elseif cap < 1 then
		-- Stop, and hold: braking below a crawl would start reversing.
		throttle = speed > 1.5 and -math.clamp(speed / 8, 0.4, 1) or 0
		handbrake = speed < 2
	else
		local err = cap - speed
		if err > 0 then
			throttle = math.clamp(err / 8 + 0.3, 0, 1)
		elseif err < -2 then
			throttle = math.clamp(err / 4, -1, 0)
		else
			throttle = 0.15
		end
	end
	return throttle, steer, handbrake
end

return BotNav
