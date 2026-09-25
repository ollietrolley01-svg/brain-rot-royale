-- Where the worst bot tick goes, and how bots move between thinks (#113 / #126 / #131 / #99).
--
-- Run with: runtest.ps1 -Probe tools/bot_lag_worst_tick_probe.lua -WaitSeconds 900
-- NEEDS THE COORDINATOR'S STUDIO. Written by tools/bot_lag_proof_check.py's proof (reports/bot-lag-proof.md);
-- it has never run.
--
-- tools/perf_tick_probe.lua measures the worst frame and the worst think slice. This one says what was IN
-- the worst slices, because the row's 42.6 ms (bot_probe, 09-22, before the quarters, paced route starts and
-- ray budget landed) was never explained and main's worst slice has never been measured at all. Every line is
-- [BRR_Lag]. Nothing in BotService or BotNav is edited: the probe wraps two functions the think loop calls
-- through its module tables, BotNav.Pump (once a slice, before the thinks) and BotService.LodDefers (once for
-- each bot of the slice, just before its think), and reads BotService.Stats.
--
-- PART A, the worst slices. Per think slice (os.clock, CPU time in Roblox):
--   pump      BotNav.Pump, with the ComputeAsync starts it made (bots whose nav.computing it set). Each start
--             runs PathfindingService up to its first yield inside the slice. If the worst slices are the ones
--             with 3 starts, the synchronous part of ComputeAsync is the tick.
--   refresh   Pump's end to the first think: refreshCombatants (snapshot, grid, budget) and LOD checks.
--   thinks    each bot's think, from one LodDefers call to the next; the slice's last think is the slice total
--             (Stats.thinkTime's step) less the rest. The slowest one and the branch it took.
--   gc        gcinfo() at the start of the slice and of the next one: a drop means a collection ran between.
--   frame     the Heartbeat delta of the frame the slice ran in (whole server frame, wall time).
-- Passes: 50 bots spread round the drop spots (the battle royale); 30 bots spawned inside one 30-stud circle
-- (#126, "many bots in one area"). Each: WARM_SECONDS, then MEASURE_SECONDS recorded. Prints the WORST_N
-- slices and the WORST_N frames, each with its parts.
-- Plant A: one Pump stalled PLANT_MS, in a pass of its own. The worst slice must be that one and its largest
-- part must be "pump"; if not, the attribution is VOID.
--
-- PART B, movement between thinks (#99). 20 bots that nobody is hostile to (IsHostile returns false, so they
-- wander and loot, never fight), LOD on and off. Every Heartbeat, for each living bot on a route
-- (nav.waypoints set, last branch wander or loot): stopped (flat speed < 0.5) or moving, the length of each
-- stop, and whether its playing track (bot.currentTrack) fits: walk/run while stopped, idle while moving
-- (flat speed > 2). tools/bot_lag_proof_check.py predicts, with a stand-in Humanoid: near a player about 3% of
-- route frames stopped (stops ~50 ms); with LOD, ~30% (stops ~180 ms); the idle track on 20% of moving
-- frames near a player, far more under LOD.
-- Plant B: one routed bot's root anchored for PLANT_ANCHOR_SECONDS. Its frames in that window must read
-- stopped at least 90%; if not, the stop numbers are VOID.
--
-- What it cannot show: what a client SEES. Server-owned bots reach clients by replication and are
-- interpolated there; a stop, a slide or a snapped turn can look better or worse on screen than these numbers.
-- That needs a playtest with a second client watching bots near and far (through a scope at 300+ studs).

local WORST_N = 8
local MAP_ID = "SahurSprings"
local WARM_SECONDS = 10
local MEASURE_SECONDS = 60
local PLANT_MS = 40
local MOVE_BOTS = 20
local MOVE_SECONDS = 40
local PLANT_ANCHOR_SECONDS = 3

local RunService = game:GetService("RunService")

local function say(fmt, ...)
	print(string.format("[BRR_Lag] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end
local MapGenerator = mod("MapGenerator")
local LootService = mod("LootService")
local CombatService = mod("CombatService")
local StormService = mod("StormService")
mod("DestructibleService")
mod("CompanionService")
local BotService = mod("BotService")
local BotNav = mod("BotNav")
local STATS = BotService.Stats

say("build: ThinkSlices %s, ray cap %s, LOD %s", tostring(BotService.ThinkSlices),
	BotService.RaycastBudget and tostring(BotService.RaycastBudget.FrameCap) or "none", tostring(BotService.LodEnabled))
say("building map %s", MAP_ID)
local info = MapGenerator.Build(MAP_ID)
LootService.Populate(info)
task.wait(4)
CombatService.SetEnabled(true)

--------------------------------------------------------------------------------
-- The wrappers
--------------------------------------------------------------------------------

local recording = false
local slices = {}
local current = nil
local lastFrameDt = 0
local plantPumpOnce = false

local realPump = BotNav.Pump
local realDefers = BotService.LodDefers

local function computingCount()
	local n = 0
	for _, bot in ipairs(BotService.GetAll()) do
		if bot.nav and bot.nav.computing then
			n += 1
		end
	end
	return n
end

-- Closes the slice before this one: its total is the think loop's own figure (Stats.thinkTime's step).
local function closeSlice()
	if not current then
		return
	end
	current.total = (STATS.thinkTime or 0) - current.thinkTime0
	local known = current.pump + current.refresh
	for _, t in ipairs(current.thinks) do
		known += t.ms
	end
	if current.lastBot then
		table.insert(current.thinks, { ms = math.max(0, current.total * 1000 - known), branch = current.lastBot.lastBranch or "?" })
	end
	current.gcAfter = gcinfo()
	if recording then
		table.insert(slices, current)
	end
	current = nil
end

BotNav.Pump = function(...)
	closeSlice()
	local slice = { thinkTime0 = STATS.thinkTime or 0, gcBefore = gcinfo(), thinks = {}, frameDt = 0 }
	local before = computingCount()
	local t0 = os.clock()
	if plantPumpOnce and recording then
		plantPumpOnce = false
		local untilTime = os.clock() + PLANT_MS / 1000
		while os.clock() < untilTime do
		end
		slice.planted = true
	end
	local results = table.pack(realPump(...))
	local t1 = os.clock()
	slice.pump = (t1 - t0) * 1000
	slice.starts = computingCount() - before
	slice.pumpEnd = t1
	slice.refresh = 0
	current = slice
	return table.unpack(results, 1, results.n)
end

BotService.LodDefers = function(bot, now)
	local t = os.clock()
	local slice = current
	if slice then
		if slice.lastBot then
			table.insert(slice.thinks, { ms = (t - slice.lastAt) * 1000, branch = slice.lastBot.lastBranch or "?" })
		elseif slice.refresh == 0 then
			slice.refresh = (t - slice.pumpEnd) * 1000
		end
	end
	local deferred = realDefers(bot, now)
	if slice then
		slice.lastBot = not deferred and bot or nil
		slice.lastAt = os.clock()
	end
	return deferred
end

-- The frame each slice ran in: the Heartbeat after it.
local frames = {}
local heartbeat = RunService.Heartbeat:Connect(function(dt)
	lastFrameDt = dt
	if current and current.frameDt == 0 then
		current.frameDt = dt
	end
	if recording then
		table.insert(frames, { dt = dt, slice = current })
	end
end)

--------------------------------------------------------------------------------
-- Part A
--------------------------------------------------------------------------------

local function describe(slice)
	if not slice then
		return "no think slice in this frame"
	end
	local slowest = { ms = 0, branch = "-" }
	for _, t in ipairs(slice.thinks) do
		if t.ms > slowest.ms then
			slowest = t
		end
	end
	local thinkMs = 0
	for _, t in ipairs(slice.thinks) do
		thinkMs += t.ms
	end
	local parts = { { "pump", slice.pump }, { "refresh", slice.refresh }, { "thinks", thinkMs } }
	table.sort(parts, function(a, b) return a[2] > b[2] end)
	return string.format("slice %.2f ms cpu: pump %.2f (%d ComputeAsync started), refresh %.2f, %d thinks %.2f "
		.. "(slowest %.2f %s); largest part %s; gc %s; frame %.1f ms%s",
		(slice.total or 0) * 1000, slice.pump, slice.starts, slice.refresh, #slice.thinks, thinkMs, slowest.ms,
		slowest.branch, parts[1][1], (slice.gcAfter and slice.gcAfter < slice.gcBefore) and
		string.format("COLLECTED %d KB", slice.gcBefore - slice.gcAfter) or "none", slice.frameDt * 1000,
		slice.planted and " [PLANTED]" or "")
end

local function report(label)
	table.sort(slices, function(a, b) return (a.total or 0) > (b.total or 0) end)
	local byStarts = { [0] = {}, {}, {}, {} }
	for _, s in ipairs(slices) do
		local list = byStarts[math.min(3, s.starts)]
		table.insert(list, (s.total or 0) * 1000)
	end
	for starts = 0, 3 do
		local list = byStarts[starts]
		table.sort(list)
		if #list > 0 then
			say("%s: slices with %d route start%s: %d, median %.2f ms, worst %.2f ms", label, starts,
				starts == 1 and "" or "s", #list, list[math.ceil(#list / 2)], list[#list])
		end
	end
	for i = 1, math.min(WORST_N, #slices) do
		say("%s: worst slice %d: %s", label, i, describe(slices[i]))
	end
	table.sort(frames, function(a, b) return a.dt > b.dt end)
	for i = 1, math.min(WORST_N, #frames) do
		say("%s: worst frame %d: %.1f ms; %s", label, i, frames[i].dt * 1000, describe(frames[i].slice))
	end
end

local function measure(label, seconds)
	table.clear(slices)
	table.clear(frames)
	recording = true
	task.wait(seconds)
	recording = false
	closeSlice()
	report(label)
end

local spots = info.dropSpots or {}
local function spawnBots(count, packed)
	local centre = spots[1] or Vector3.zero
	local bots = BotService.Spawn(count, function(index)
		local angle = index * 2.399963
		local x, z
		if packed then
			local reach = 4 + (index * 7) % 26
			x, z = centre.X + math.cos(angle) * reach, centre.Z + math.sin(angle) * reach
		else
			local spot = spots[(index - 1) % math.max(1, #spots) + 1] or Vector3.zero
			local reach = 18 + (index * 7) % 23
			x, z = spot.X + math.cos(angle) * reach, spot.Z + math.sin(angle) * reach
		end
		return CFrame.new(x, MapGenerator.GroundHeightAt(x, z) + 5, z)
	end, function() end)
	task.wait(1)
	BotService.Start()
	return bots
end

local function clearBots()
	BotService.Clear()
	task.wait(2)
end

-- Plant A: the attribution must name the stalled Pump.
do
	spawnBots(15, false)
	task.wait(3)
	plantPumpOnce = true
	measure("PLANT A (15 bots, one Pump stalled " .. PLANT_MS .. " ms)", 4)
	local caught = false
	for _, s in ipairs(slices) do
		if s.planted then
			caught = s == slices[1] and s.pump >= PLANT_MS * 0.9
		end
	end
	say("plant A: %s", caught and "CAUGHT (the worst slice is the stalled one, its pump part carries the stall)"
		or "MISSED (the slice attribution is VOID)")
	clearBots()
end

for _, pass in ipairs({ { 50, false, "50 bots spread" }, { 30, true, "30 bots in one 30-stud circle (#126)" } }) do
	local count, packed, label = pass[1], pass[2], pass[3]
	StormService.SetSpeed(1)
	StormService.Start(info.radius)
	local bots = spawnBots(count, packed)
	say("%s: %d spawned", label, #bots)
	task.wait(WARM_SECONDS)
	measure(label, MEASURE_SECONDS)
	StormService.Stop()
	clearBots()
end

--------------------------------------------------------------------------------
-- Part B
--------------------------------------------------------------------------------

local ROUTE_BRANCHES = { wander = true, loot = true }

local function movementPass(label, lodOn, plantBot)
	BotService.LodEnabled = lodOn
	local hostileBefore = BotService.IsHostile
	BotService.IsHostile = function()
		return false
	end
	spawnBots(MOVE_BOTS, false)
	task.wait(WARM_SECONDS)
	local tally = { routed = 0, stopped = 0, stops = 0, stopFrames = 0, moving = 0, still = 0, idleMoving = 0, walkStill = 0 }
	local inStop = {}
	local anchored, anchorUntil, anchorFrames, anchorStopped = nil, 0, 0, 0
	local watch = RunService.Heartbeat:Connect(function()
		for _, bot in ipairs(BotService.GetAll()) do
			local root = bot.character and bot.character:FindFirstChild("HumanoidRootPart")
			if root and bot.humanoid and bot.humanoid.Health > 0 then
				local v = root.AssemblyLinearVelocity
				local speed = Vector3.new(v.X, 0, v.Z).Magnitude
				if speed > 2 then
					tally.moving += 1
					if bot.currentTrack == "idle" then
						tally.idleMoving += 1
					end
				elseif speed < 0.5 then
					tally.still += 1
					if bot.currentTrack == "walk" or bot.currentTrack == "run" then
						tally.walkStill += 1
					end
				end
				local routed = bot.nav and bot.nav.waypoints ~= nil and ROUTE_BRANCHES[bot.lastBranch]
				if routed then
					tally.routed += 1
					if speed < 0.5 then
						tally.stopped += 1
						if not inStop[bot] then
							tally.stops += 1
						end
						inStop[bot] = true
					else
						inStop[bot] = nil
					end
					if plantBot and not anchored then
						anchored = bot
						root.Anchored = true
						anchorUntil = tick() + PLANT_ANCHOR_SECONDS
					end
				else
					inStop[bot] = nil
				end
				if anchored == bot and tick() < anchorUntil then
					anchorFrames += 1
					if speed < 0.5 then
						anchorStopped += 1
					end
				end
			end
		end
		if anchored and tick() >= anchorUntil then
			local root = anchored.character and anchored.character:FindFirstChild("HumanoidRootPart")
			if root then
				root.Anchored = false
			end
		end
	end)
	task.wait(plantBot and (PLANT_ANCHOR_SECONDS + 2) or MOVE_SECONDS)
	watch:Disconnect()
	if plantBot then
		local share = anchorFrames > 0 and anchorStopped / anchorFrames or 0
		say("plant B: anchored bot read stopped on %d of %d frames (%.0f%%) -> %s", anchorStopped, anchorFrames,
			share * 100, share >= 0.9 and "CAUGHT" or "MISSED (the stop numbers are VOID)")
	else
		local routed = math.max(1, tally.routed)
		say("%s: on a route %d bot-frames, stopped %d (%.1f%%), %d stops, mean stop %.0f ms; walk/run track while "
			.. "stopped %.1f%% of stopped frames, idle track while moving %.1f%% of moving frames",
			label, tally.routed, tally.stopped, 100 * tally.stopped / routed, tally.stops,
			tally.stops > 0 and tally.stopped / tally.stops * 1000 / 60 or 0,
			100 * tally.walkStill / math.max(1, tally.still), 100 * tally.idleMoving / math.max(1, tally.moving))
	end
	BotService.IsHostile = hostileBefore
	clearBots()
end

local lodDefault = BotService.LodEnabled
movementPass("PLANT B", false, true)
movementPass(string.format("%d bots wandering, LOD off (a player beside every bot)", MOVE_BOTS), false, false)
movementPass(string.format("%d bots wandering, LOD on (no player: every bot far)", MOVE_BOTS), true, false)
BotService.LodEnabled = lodDefault

heartbeat:Disconnect()
BotNav.Pump = realPump
BotService.LodDefers = realDefers
LootService.Clear()
MapGenerator.Clear()
say("probe finished")
