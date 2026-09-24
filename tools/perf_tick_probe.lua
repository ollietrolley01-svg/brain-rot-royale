-- Worst server frame with 30 and 50 bots (#131 / #126 / #113 / #99), and the shared-infrastructure
-- pass (spatial grid, ray budget, route sharing, LOD): the same passes with LOD on and off.
--
-- Run with: runtest.ps1 -Probe tools/perf_tick_probe.lua -WaitSeconds 900
--
-- tools/perf_bot_cost.py counts the work per frame without Studio; this measures the frame. One map
-- build (MAP_ID), its loot, the storm at STORM_SPEED, then for each bot count and each LOD setting:
-- spawn round the drop spots, BotService.Start, WARM_SECONDS to let the drop's route burst settle,
-- MEASURE_SECONDS sampled. Every line is [BRR_Perf]. Run it on the build before a change and on the
-- build after; only a pair from ONE map snapshot is a before/after (COORDINATION.md, the cap A/B).
-- The probe has no player in the world, so with LOD on EVERY bot is "far from players" and defers
-- its idle thinks: the LOD-on pass is the floor of what LOD can save, the LOD-off pass is the match
-- with a player next to every bot.
--
-- What each number is:
--   frame        RunService.Heartbeat's delta: the WALL time of a whole server frame, everything in
--                it (physics, every Heartbeat handler, the bots, replication). This is the "tick".
--   think cpu    BotService.Stats.maxTick: the bots' own think slice, os.clock (CPU time in Roblox).
--   think wall   BotService.Stats.maxTickWall: the same slice on the wall clock. Far above think cpu
--                means a think yielded; far below frame means the worst frame was not the bots.
--   worst think  the slowest single bot think and its branch (BotService.MaxBotBranch).
--   rays         BotService.Stats: rays per bot-update by class, the most in one frame
--                (raysFrameMax), and how many the budget refused (raysDenied); sight rays refused
--                (sightDenied) should be 0 or near it, or the cap (RaycastBudget.FrameCap) is too low.
--   candidates   combatants findTarget examined per think (the grid); the linear scan was N-1.
--   routes       ComputeAsync run (pathOk + pathFail) against routes copied from a neighbour
--                (pathShared) and kept (pathReused).
--   lod          thinks deferred (lodSkips) against thinks taken by far bots (lodThinks).
-- The planted fault: a deliberate PLANT_MS stall inside one Heartbeat, once, in its own pass. The
-- probe must report a worst frame at least that long; if it does not, its numbers are not frames.
-- A second plant: with the ray budget's cap forced to 1 for one short pass, raysDenied must climb
-- and sightDenied with it; if they do not, the rays are not going through the budget.

local MAP_ID = "SahurSprings"
local BOT_COUNTS = { 30, 50 }
local LOD_PASSES = { true, false }
local WARM_SECONDS = 15
local MEASURE_SECONDS = 90
local STORM_SPEED = 1
local PLANT_MS = 60
local BUDGET_PLANT_SECONDS = 6

local RunService = game:GetService("RunService")

local function say(fmt, ...)
	print(string.format("[BRR_Perf] " .. fmt, ...))
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

say("build: BotService.ThinkSlices = %s (nil = the two-halves loop from before #131); RaycastBudget %s; SpatialQuery %s; LOD %s",
	tostring(BotService.ThinkSlices), BotService.RaycastBudget and ("cap " .. tostring(BotService.RaycastBudget.FrameCap)) or "none",
	BotService.SpatialQuery and "grid" or "none", BotService.LodDefers and ("skip " .. tostring(BotService.LodSkip)) or "none")

say("building map %s", MAP_ID)
local info = MapGenerator.Build(MAP_ID)
LootService.Populate(info)
task.wait(4)
CombatService.SetEnabled(true)

-- Frame times on the wall clock, from Heartbeat's own delta.
local frames = {}
local recording = false
local heartbeat = RunService.Heartbeat:Connect(function(dt)
	if recording then
		table.insert(frames, dt)
	end
end)

local function percentile(sorted, share)
	if #sorted == 0 then
		return 0
	end
	return sorted[math.max(1, math.ceil(#sorted * share))]
end

local function resetMaxima()
	local stats = BotService.Stats
	for _, key in ipairs({ "maxTick", "maxTickWall", "maxBotUpdate", "raysFrameMax" }) do
		if stats and stats[key] then
			stats[key] = 0
		end
	end
	if BotNav.Stats then
		BotNav.Stats.queueWaitMax = 0
	end
end

local function measure(label, seconds)
	table.clear(frames)
	resetMaxima()
	local before = BotService.Stats and table.clone(BotService.Stats) or {}
	recording = true
	task.wait(seconds)
	recording = false
	local after = BotService.Stats and table.clone(BotService.Stats) or {}
	local sorted = table.clone(frames)
	table.sort(sorted)
	local over33, over50 = 0, 0
	for _, dt in ipairs(frames) do
		if dt > 1 / 30 then
			over33 += 1
		end
		if dt > 0.05 then
			over50 += 1
		end
	end
	local function d(key)
		return (after[key] or 0) - (before[key] or 0)
	end
	local updates = math.max(1, d("updates"))
	say("%s: %d frames over %.0f s; frame median %.1f ms, 99th %.1f ms, WORST %.1f ms; frames over 33 ms %d, over 50 ms %d",
		label, #frames, seconds, percentile(sorted, 0.5) * 1000, percentile(sorted, 0.99) * 1000,
		percentile(sorted, 1) * 1000, over33, over50)
	say("%s: think slice worst cpu %.1f ms, wall %.1f ms; think %.0f us/bot-update; worst single think %.1f ms (%s); sight rays %.2f, barricade rays %.2f per bot-update; route wait max %.2f s",
		label, (after.maxTick or 0) * 1000, (after.maxTickWall or 0) * 1000, d("thinkTime") / updates * 1e6,
		(after.maxBotUpdate or 0) * 1000, tostring(BotService.MaxBotBranch), d("sightChecks") / updates,
		d("coverChecks") / updates, BotNav.Stats and BotNav.Stats.queueWaitMax or -1)
	say("%s: rays per bot-update combat %.2f, navigation %.2f, idle %.2f; most in one frame %d; refused %d (sight %d); candidates examined %.1f per think; routes computed %d, shared %d, reused %d; lod deferred %d, far thinks %d",
		label, d("raysCombat") / updates, d("raysNavigation") / updates, d("raysIdle") / updates, after.raysFrameMax or 0,
		d("raysDenied"), d("sightDenied"), d("candidatesExamined") / updates, d("pathOk") + d("pathFail"), d("pathShared"),
		d("pathReused"), d("lodSkips"), d("lodThinks"))
	return percentile(sorted, 1), d("raysDenied"), d("sightDenied")
end

-- The planted fault, in a pass of its own with no bots: one frame stalled PLANT_MS.
do
	local planted = false
	local stall = RunService.Heartbeat:Connect(function()
		if not planted and recording then
			planted = true
			local untilTime = os.clock() + PLANT_MS / 1000
			while os.clock() < untilTime do
			end
		end
	end)
	local worst = measure("PLANT (no bots, one stalled frame)", 5)
	stall:Disconnect()
	say("plant: worst frame %.1f ms against a %d ms stall -> %s", worst * 1000, PLANT_MS,
		worst * 1000 >= PLANT_MS * 0.9 and "CAUGHT" or "MISSED (these numbers are not frames; results VOID)")
end
measure("baseline (map, no bots)", 10)

local spots = info.dropSpots or {}
local function spawnBots(count)
	local bots = BotService.Spawn(count, function(index)
		local spot = spots[(index - 1) % math.max(1, #spots) + 1] or Vector3.zero
		local angle = index * 2.399963
		local reach = 18 + (index * 7) % 23
		local x, z = spot.X + math.cos(angle) * reach, spot.Z + math.sin(angle) * reach
		return CFrame.new(x, MapGenerator.GroundHeightAt(x, z) + 5, z)
	end, function() end)
	task.wait(1)
	StormService.SetSpeed(STORM_SPEED)
	StormService.Start(info.radius)
	BotService.Start()
	return bots
end

local function clearBots()
	BotService.Clear()
	StormService.Stop()
	-- Clear() stops the think loop by flag; let it wake and exit before the next Start().
	task.wait(2)
end

-- The second plant: the ray budget with its cap forced to 1 must refuse rays, sight rays included.
if BotService.RaycastBudget then
	local budget = BotService.RaycastBudget
	local cap = budget.FrameCap
	spawnBots(BOT_COUNTS[1])
	budget.FrameCap = 1
	local _, denied, sightDenied = measure(string.format("PLANT (ray cap 1, %d bots)", BOT_COUNTS[1]), BUDGET_PLANT_SECONDS)
	budget.FrameCap = cap
	say("plant: ray cap 1 refused %d rays (%d sight) in %d s -> %s", denied, sightDenied, BUDGET_PLANT_SECONDS,
		(denied > 0 and sightDenied > 0) and "CAUGHT" or "MISSED (bot rays are not going through the budget; the rays lines are VOID)")
	clearBots()
end

local defaultLod = BotService.LodEnabled
for _, count in ipairs(BOT_COUNTS) do
	for _, lodOn in ipairs(LOD_PASSES) do
		if BotService.LodDefers == nil and not lodOn then
			-- No LOD in this build: one pass is the whole story.
			continue
		end
		if BotService.LodDefers then
			BotService.LodEnabled = lodOn
		end
		local tag = string.format("%d bots, LOD %s", count, BotService.LodDefers and (lodOn and "on" or "off") or "n/a")
		local bots = spawnBots(count)
		say("%s: %d spawned (%d asked for)", tag, #bots, count)
		measure(string.format("%s, first %d s (the drop's route burst)", tag, WARM_SECONDS), WARM_SECONDS)
		measure(string.format("%s, settled", tag), MEASURE_SECONDS)
		local alive = 0
		for _, bot in ipairs(BotService.GetAll()) do
			if bot.humanoid and bot.humanoid.Health > 0 then
				alive += 1
			end
		end
		say("%s: %d alive at the end", tag, alive)
		clearBots()
	end
end
if BotService.LodDefers then
	BotService.LodEnabled = defaultLod
end

heartbeat:Disconnect()
LootService.Clear()
MapGenerator.Clear()
say("probe finished")
