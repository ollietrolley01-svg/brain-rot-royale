-- The stand-in world for tools/bot_lag_proof_check.py (#113/#126/#131/#99). Loaded AFTER
-- tools/bot_archetype_sim.py's PRELUDE, LOADER and WORLD, whose mock map, characters, combat and
-- module mocks it reuses. What this adds:
--   * the REAL BotNav in place of the sim's mock (routes, CanStep, FindCover, the stuck ladder), with
--     a PathfindingService whose ComputeAsync yields for PATH_LATENCY and returns waypoints every 4
--     studs (Roblox's default WaypointSpacing) along the straight line;
--   * a raycast with face normals and a ground plane at y = 0 (the sim's raycast has neither, and
--     BotNav.CanStep reads both), plus GetPartBoundsInRadius and Blockcast;
--   * RunService.Heartbeat (Connect and Wait) and a thread scheduler, so BotService.Start's real think
--     loop runs frame by frame at 60 Hz;
--   * counters on every platform call a bot makes, per frame, and an instruction-count profiler that
--     attributes the game code's work to the BotService / BotNav function doing it.
-- Nothing here changes what BotService decides: the counters only watch.
--
-- Called as chunk(G) with G the Lua state's globals (the sim's SIM, Combatants and CLOCK live there). It
-- publishes G.LAG and G.FNAMES; everything else stays local, since the static checks read this file as Luau.

local G = ...
local REAL_CLOCK = G.REAL_CLOCK
local SIM = G.SIM
local Combatants = G.Combatants
local THREADS = {}
local HB = {}
local PLAYER_LIST = {}

local LAG = {
	frame = 0,
	frames = {},            -- one row per frame (see LAG.newFrame)
	raysLeaf = {},          -- rays by the function that asked for them
	raysTop = {},           -- rays by the path updateBot took to them (the function updateBot called)
	samplesSelf = {},       -- instruction samples by the game function running
	samplesTop = {},        -- instruction samples by top-level path (think callee, Pump, refresh, servo)
	unbudgeted = {},        -- bot-code rays that did not come through RaycastBudget.Cast, by function
	grants = {},            -- per slice: { spentBefore, priority } of every granted ray, for the share check
	claims = {},            -- per character: times SetNetworkOwner(nil) ran
	deferrals = {},         -- LodDefers answers that deferred: { bot, branch, playerDistance }
	thinksAt = {},          -- per bot: times it thought
	pathInFlight = 0,
	pathInFlightMax = 0,
	pathStarted = 0,
	sampleEvery = 1000,
	mockTime = 0,
	thinkYields = 0,
	pathLatency = 0.4,
}
G.LAG = LAG

local function newFrame()
	return { thinks = 0, rays = 0, raysBot = 0, unbudgeted = 0, overlaps = 0, blockcasts = 0, computeStarts = 0,
		moveTos = 0, moveTosOutsideThink = 0, hostileAsks = 0, claims = 0, samples = 0, ms = 0,
		mockMs = 0, denied = 0, sliceRays = 0, runningEvents = 0, finishedEvents = 0, eventInstr = 0, top = {} }
end
LAG.newFrame = newFrame
LAG.cur = newFrame()

-- Source names ------------------------------------------------------------------------------------
-- FNAMES[source][linedefined] = "name", filled by the driver from the real files.
local FNAMES = {}
G.FNAMES = FNAMES
local function isGame(source)
	return FNAMES[source] ~= nil
end
local function fnName(info)
	local names = FNAMES[info.source]
	if not names then
		return nil
	end
	return names[info.linedefined] or ("<fn@" .. info.linedefined .. ">")
end
LAG.fnName = fnName

-- The path a piece of work belongs to: the function updateBot called, or the loop's own steps.
local TOP_ROOTS = { updateBot = true }
local function topPath(level)
	local below = nil
	local l = level
	while true do
		local info = debug.getinfo(l, "S")
		if not info then
			break
		end
		if isGame(info.source) then
			local name = fnName(info)
			if TOP_ROOTS[name] then
				return below or name
			end
			if name == "BotNav.Pump" or name == "refreshCombatants" or name == "Vehicles.servo" then
				return name
			end
			below = name
		end
		l = l + 1
	end
	return below or "?"
end
LAG.topPath = topPath

-- The first game function on the stack from `level` up, skipping the budget's own Cast.
local function leafGame(level)
	local l = level
	while true do
		local info = debug.getinfo(l, "S")
		if not info then
			return nil, nil
		end
		if isGame(info.source) then
			local name = fnName(info)
			if name ~= "budget.Cast" and name ~= "BotNav.CastRay" and name ~= "castRay" then
				return name, l
			end
		end
		l = l + 1
	end
end

-- Profiler: every LAG.sampleEvery VM instructions, one sample for the game function running (self)
-- and for its top-level path. Samples landing in mock code count toward the nearest game frame's
-- path but not its self time (the mocks' cost is not the game's).
local function hook()
	local info = debug.getinfo(2, "S")
	if not info then
		return
	end
	local f = LAG.cur
	if isGame(info.source) then
		local name = fnName(info)
		LAG.samplesSelf[name] = (LAG.samplesSelf[name] or 0) + 1
		f.samples = f.samples + 1
		local top = topPath(2)
		f.top[top] = (f.top[top] or 0) + 1
		LAG.samplesTop[top] = (LAG.samplesTop[top] or 0) + 1
	end
end
function LAG.hookThread(co)
	if LAG.profile then
		debug.sethook(co, hook, "", LAG.sampleEvery)
	end
end

-- Threads and Heartbeat -----------------------------------------------------------------------------
-- A fresh world for the next scenario: no threads, no Heartbeat handlers, no players. Route computes
-- still in flight from the last scenario are finished first (their results are thrown away, as
-- BotNav.Clear expects): dropped unfinished, BotNav's in-flight count never came back down, and each
-- later scenario ran with fewer route slots than MAX_CONCURRENT_PATHS.
local COMPUTES = {}
function LAG.resetWorld()
	for co in pairs(COMPUTES) do
		if coroutine.status(co) == "suspended" then
			pcall(coroutine.resume, co)
		end
	end
	COMPUTES = {}
	THREADS, HB, PLAYER_LIST = {}, {}, {}
end
task.spawn = function(fn, ...)
	local entry = { co = coroutine.create(fn), wake = math.huge }
	LAG.hookThread(entry.co)
	THREADS[#THREADS + 1] = entry
	local ok, d = coroutine.resume(entry.co, ...)
	if not ok then
		error(d)
	end
	entry.wake = G.CLOCK + (d or 0)
	return entry.co
end
task.wait = function(d)
	return coroutine.yield(d or 0)
end
local function stepThreads()
	local list = THREADS
	local n = #list
	for i = 1, n do
		local t = list[i]
		if coroutine.status(t.co) == "suspended" and G.CLOCK >= t.wake - 1e-9 then
			local ok, d = coroutine.resume(t.co)
			if not ok then
				table.insert(SIM.errors, "thread: " .. tostring(d))
				d = 0 -- a dead thread: its error is recorded (E1), and it is dropped below
			end
			t.wake = G.CLOCK + (d or 0)
			-- The think loop suspended while a think was still running: that think yielded.
			if LAG.inThink then
				LAG.thinkYields = LAG.thinkYields + 1
				LAG.inThink = false
			end
		end
	end
	local live = {}
	for _, t in ipairs(THREADS) do
		if coroutine.status(t.co) ~= "dead" then
			live[#live + 1] = t
		end
	end
	THREADS = live
end
local RunService = {
	Heartbeat = {
		Connect = function(_, fn)
			local c = { fn = fn, on = true }
			HB[#HB + 1] = c
			return { Disconnect = function() c.on = false end, Connected = true }
		end,
		Wait = function() return coroutine.yield(0) end,
	},
	Stepped = { Connect = function() return { Disconnect = function() end } end },
	IsStudio = function() return false end,
	IsServer = function() return true end,
}
local function stepHeartbeat(dt)
	for _, c in ipairs(HB) do
		if c.on then
			local ok, err = pcall(c.fn, dt)
			if not ok then
				table.insert(SIM.errors, "heartbeat: " .. tostring(err))
			end
		end
	end
end

-- Pathfinding: ComputeAsync yields LAG.pathLatency, then a straight route with a waypoint every 4 studs.
-- A route whose straight line crosses a wall fails (NoPath), as a route round it is not modelled.
local PathfindingService = {}
function PathfindingService.CreatePath(_, agent)
	local path = { Status = "PathStatus.NoPath", waypoints = {} }
	path.Blocked = { Connect = function() return { Disconnect = function() end } end }
	function path.ComputeAsync(self, from, to)
		LAG.cur.computeStarts = LAG.cur.computeStarts + 1
		LAG.pathStarted = LAG.pathStarted + 1
		LAG.pathInFlight = LAG.pathInFlight + 1
		if LAG.pathInFlight > LAG.pathInFlightMax then
			LAG.pathInFlightMax = LAG.pathInFlight
		end
		local co = coroutine.running()
		COMPUTES[co] = true
		coroutine.yield(LAG.pathLatency)
		COMPUTES[co] = nil
		LAG.pathInFlight = LAG.pathInFlight - 1
		local a = Vector3.new(from.X, 0, from.Z)
		local b = Vector3.new(to.X, 0, to.Z)
		if SIM.segmentCrossesWall(a + Vector3.new(0, 1, 0), b + Vector3.new(0, 1, 0)) then
			self.Status = "PathStatus.NoPath"
			return
		end
		local d = b - a
		local len = d.Magnitude
		local n = math.max(1, math.ceil(len / 4))
		local wps = {}
		for i = 0, n do
			wps[#wps + 1] = { Position = a + d * (i / n), Action = "PathWaypointAction.Walk" }
		end
		self.waypoints = wps
		self.Status = "PathStatus.Success"
	end
	function path.GetWaypoints(self)
		return self.waypoints
	end
	return path
end

local Players = {
	GetPlayers = function() return PLAYER_LIST end,
	GetPlayerFromCharacter = function(_, c)
		for _, p in ipairs(PLAYER_LIST) do
			if p.Character == c then
				return p
			end
		end
		return nil
	end,
	PlayerAdded = { Connect = function() return { Disconnect = function() end } end },
	PlayerRemoving = { Connect = function() return { Disconnect = function() end } end },
}

local baseGet = game.GetService
game.GetService = function(self, name)
	if name == "RunService" then
		return RunService
	elseif name == "PathfindingService" then
		return PathfindingService
	elseif name == "Players" then
		return Players
	end
	return baseGet(self, name)
end

-- Raycast with normals and a ground plane ---------------------------------------------------------
local ground = { Name = "Ground", CanCollide = true, Material = "Material.Grass", Parent = SIM.mapFolder }
function ground.IsDescendantOf(self, a) return a == self or a == SIM.mapFolder or a == workspace end
function ground.FindFirstAncestorOfClass() return nil end
function ground.IsA(_, cls) return cls == "BasePart" or cls == "Part" or cls == "Terrain" end
function ground.GetAttribute() return nil end
LAG.ground = ground

local function rayBoxN(origin, dir, box)
	local tmin, tmax, axisHit, sign = 0, 1, nil, 0
	for _, axis in ipairs({ "X", "Y", "Z" }) do
		local o, d = origin[axis], dir[axis]
		local lo, hi = box.min[axis], box.max[axis]
		if math.abs(d) < 1e-9 then
			if o < lo or o > hi then
				return nil
			end
		else
			local t1, t2 = (lo - o) / d, (hi - o) / d
			local s = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				s = 1
			end
			if t1 > tmin then
				tmin, axisHit, sign = t1, axis, s
			end
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	local normal = Vector3.new(axisHit == "X" and sign or 0, axisHit == "Y" and sign or 0, axisHit == "Z" and sign or 0)
	if not axisHit then
		normal = Vector3.new(0, 1, 0) -- started inside
	end
	return tmin, normal
end

local function charBox(c)
	local p = c.root.Position
	return { min = p - Vector3.new(1.2, 2.8, 1.2), max = p + Vector3.new(1.2, 2.2, 1.2) }
end

local function excludedBy(params)
	local list = params and params.FilterDescendantsInstances or {}
	return function(inst)
		for _, e in ipairs(list) do
			if e ~= nil and e ~= false and inst:IsDescendantOf(e) then
				return true
			end
		end
		return false
	end
end

local function castWorld(origin, dir, params)
	local excluded = excludedBy(params)
	local best, bestT, bestN = nil, 1.0000001, nil
	for _, w in ipairs(SIM.walls) do
		if w.alive then
			local t, n = rayBoxN(origin, dir, w)
			if t and t < bestT and not excluded(w.part) then
				bestT, best, bestN = t, w.part, n
			end
		end
	end
	for _, c in ipairs(SIM.chars) do
		if c.alive then
			local t, n = rayBoxN(origin, dir, charBox(c))
			if t and t < bestT and not excluded(c.root) then
				bestT, best, bestN = t, c.root, n
			end
		end
	end
	if dir.Y < 0 and origin.Y >= 0 then
		local t = origin.Y / -dir.Y
		if t <= 1 and t < bestT and not excluded(ground) then
			bestT, best, bestN = t, ground, Vector3.new(0, 1, 0)
		end
	end
	if best then
		return { Instance = best, Position = origin + dir * bestT, Normal = bestN, Material = best.Material or "Material.Plastic",
			Distance = (dir * bestT).Magnitude }
	end
	return nil
end
LAG.castWorld = castWorld

-- Who is casting: a ray from bot code must come through RaycastBudget.Cast (its caller at level 3).
local function noteRay(kind)
	local f = LAG.cur
	f.rays = f.rays + 1
	local caller = debug.getinfo(3, "S")
	local viaBudget = caller and isGame(caller.source) and fnName(caller) == "budget.Cast"
	local leaf = leafGame(3)
	if not leaf then
		return -- not bot code (the mock world's own rays)
	end
	f.raysBot = f.raysBot + 1
	local top = topPath(3)
	LAG.raysTop[top] = (LAG.raysTop[top] or 0) + 1
	if viaBudget then
		LAG.raysLeaf[leaf] = (LAG.raysLeaf[leaf] or 0) + 1
		-- The budget's priority argument and spend at the moment it granted this ray.
		local _, priority = debug.getlocal(3, 4)
		f.sliceRays = f.sliceRays + 1
		LAG.grants[#LAG.grants + 1] = { slice = LAG.slice or 0, n = LAG.sliceSpent, priority = priority or "navigation" }
		LAG.sliceSpent = LAG.sliceSpent + 1
	else
		f.unbudgeted = f.unbudgeted + 1
		local key = kind .. " " .. leaf
		LAG.unbudgeted[key] = (LAG.unbudgeted[key] or 0) + 1
	end
end

function workspace.Raycast(_, origin, dir, params)
	local t0 = REAL_CLOCK()
	noteRay("Raycast")
	local r = castWorld(origin, dir, params)
	LAG.mockTime = LAG.mockTime + (REAL_CLOCK() - t0)
	return r
end

function workspace.Blockcast(_, cf, size, dir, params)
	local t0 = REAL_CLOCK()
	local f = LAG.cur
	f.blockcasts = f.blockcasts + 1
	noteRay("Blockcast")
	local origin = cf.Position or cf
	local r = castWorld(origin, dir, params)
	LAG.mockTime = LAG.mockTime + (REAL_CLOCK() - t0)
	return r
end

function workspace.GetPartBoundsInRadius(_, point, radius, params)
	local t0 = REAL_CLOCK()
	local f = LAG.cur
	f.overlaps = f.overlaps + 1
	local leaf = leafGame(2)
	-- Budgeted when RaycastBudget.Spend granted it just before (the driver's WRAP sets spendGranted);
	-- otherwise it is outside the budget, like a ray cast round it.
	if leaf and not LAG.spendGranted then
		local key = "GetPartBoundsInRadius " .. leaf
		LAG.unbudgeted[key] = (LAG.unbudgeted[key] or 0) + 1
	end
	LAG.spendGranted = false
	local found = {}
	local w = SIM.pointInWall(point, radius)
	if w then
		found[1] = w.part
	end
	LAG.mockTime = LAG.mockTime + (REAL_CLOCK() - t0)
	return found
end

-- Characters: what the real BotNav and the claim read, and the movement / animation watch ---------
local baseMake = SIM.makeCharacter
function SIM.makeCharacter(name, position, team)
	local c = baseMake(name, position, team)
	c.humanoid.HipHeight = 2
	c.humanoid.MoveDirection = Vector3.zero
	c.humanoid.ChangeState = function() end -- the stuck ladder's hop
	c.humanoid.FloorMaterial = "Material.Grass"
	c.root.Size = Vector3.new(2, 2, 1)
	c.root.Anchored = false
	c.head.Size = Vector3.new(1, 1, 1)
	c.root.SetNetworkOwner = function(self, owner)
		LAG.cur.claims = LAG.cur.claims + 1
		local list = LAG.claims[c]
		if not list then
			list = {}
			LAG.claims[c] = list
		end
		list[#list + 1] = G.CLOCK
	end
	-- The Humanoid events BotService/BotNav listen to: Running (speed, on a change of speed),
	-- StateChanged (the sim never leaves Running, so it never fires) and MoveToFinished (reached).
	local function signal()
		local s = { handlers = {} }
		function s.Connect(self, fn)
			self.handlers[#self.handlers + 1] = fn
			return { Disconnect = function() end, Connected = true }
		end
		function s.Fire(self, ...)
			for _, fn in ipairs(self.handlers) do
				local ok, err = pcall(fn, ...)
				if not ok then
					table.insert(SIM.errors, "humanoid event: " .. tostring(err))
				end
			end
		end
		return s
	end
	c.humanoid.Running = signal()
	c.humanoid.StateChanged = signal()
	c.humanoid.MoveToFinished = signal()
	local moveTo = c.humanoid.MoveTo
	c.humanoid.MoveTo = function(h, p)
		LAG.cur.moveTos = LAG.cur.moveTos + 1
		if not LAG.inThink then
			LAG.cur.moveTosOutsideThink = LAG.cur.moveTosOutsideThink + 1
		end
		c.moveToAt = G.CLOCK
		c.moveToFinished = false
		return moveTo(h, p)
	end
	return c
end

-- Animation tracks: what a Play/Stop pair leaves playing, per bot.
function LAG.giveTracks(bot)
	local tracks = {}
	for _, name in ipairs({ "idle", "walk", "run", "fall", "jump", "hold" }) do
		local track = { IsPlaying = false, name = name }
		function track.Play(self) self.IsPlaying = true if name ~= "hold" then bot.animPlaying = name end end
		function track.Stop(self) self.IsPlaying = false end
		tracks[name] = track
	end
	bot.tracks = tracks
	bot.currentTrack = nil
end

-- After the sim moved everyone: MoveDirection is what the Humanoid reports while walking. Then the
-- Humanoid's events, as Roblox fires them after its physics step: Running when the speed changed,
-- MoveToFinished(true) once when the walk reached its MoveTo point (the sim stops within 0.5).
-- Handlers run outside any think; their game-code instructions are counted in LAG.eventSamples.
function LAG.afterMove(dt)
	for _, c in ipairs(SIM.chars) do
		if c.alive then
			local prev = c.prevPos or c.root.Position
			local d = Vector3.new(c.root.Position.X - prev.X, 0, c.root.Position.Z - prev.Z)
			c.speedNow = d.Magnitude / dt
			c.humanoid.MoveDirection = d.Magnitude > 1e-6 and d / d.Magnitude or Vector3.zero
			c.prevPos = c.root.Position
		end
	end
	LAG.inEvent = true
	local f = LAG.cur
	-- Every VM instruction the handlers run (the mock signal and tracks included, so an overstatement).
	local function counted(event, ...)
		if LAG.profile then
			debug.sethook(function() f.eventInstr = f.eventInstr + 1 end, "", 1)
		end
		event:Fire(...)
		if LAG.profile then
			debug.sethook()
		end
	end
	for _, c in ipairs(SIM.chars) do
		if c.alive and c.humanoid.Health > 0 then
			local h = c.humanoid
			if #h.Running.handlers > 0 and math.abs((c.speedNow or 0) - (c.reportedSpeed or -1)) > 0.01 then
				c.reportedSpeed = c.speedNow
				LAG.cur.runningEvents = LAG.cur.runningEvents + 1
				counted(h.Running, c.speedNow)
			end
			local t = c.walkTarget
			if t and not c.moveToFinished
				and Vector3.new(t.X - c.root.Position.X, 0, t.Z - c.root.Position.Z).Magnitude <= 0.5 then
				c.moveToFinished = true
				LAG.cur.finishedEvents = LAG.cur.finishedEvents + 1
				counted(h.MoveToFinished, true)
			end
		end
	end
	LAG.inEvent = false
end

-- A player: a token Combatants reads as a player, standing still, not hurt by anything.
function SIM.makePlayer(name, position)
	local c = SIM.makeCharacter(name, position, nil)
	local token = { isPlayer = true, UserId = 1, Name = name, character = c, name = name }
	SIM.tokens[c] = token
	SIM.invulnerable[token] = true
	Combatants.Register(c, token)
	PLAYER_LIST[#PLAYER_LIST + 1] = { Character = c, UserId = 1, Name = name }
	return token
end

-- One 60 Hz frame: the world moves, then the scheduler resumes whatever is due (the think loop, the
-- path computes), then Heartbeat. Returns nothing; the frame's row is LAG.cur.
function LAG.frameStep(dt)
	LAG.frame = LAG.frame + 1
	LAG.cur = newFrame()
	SIM.step(dt)
	LAG.afterMove(dt)
	local mock0 = LAG.mockTime
	local t0 = REAL_CLOCK()
	stepThreads()
	stepHeartbeat(dt)
	local f = LAG.cur
	f.ms = (REAL_CLOCK() - t0) * 1000
	f.mockMs = (LAG.mockTime - mock0) * 1000
	LAG.frames[LAG.frame] = f
end
