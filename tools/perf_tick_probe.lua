-- Worst server frame with 30 and 50 bots (#131 / #126 / #113 / #99).
--
-- Run with: runtest.ps1 -Probe tools/perf_tick_probe.lua -WaitSeconds 600
--
-- tools/perf_bot_cost.py counts the work per frame without Studio; this measures the frame. One map
-- build (MAP_ID), its loot, the storm at STORM_SPEED, then for each bot count: spawn round the drop
-- spots, BotService.Start, WARM_SECONDS to let the drop's route burst settle, MEASURE_SECONDS
-- sampled. Every line is [BRR_Perf]. Run it on the build before a change and on the build after;
-- only a pair from ONE map snapshot is a before/after (COORDINATION.md, the cap A/B).
--
-- What each number is:
--   frame        RunService.Heartbeat's delta: the WALL time of a whole server frame, everything in
--                it (physics, every Heartbeat handler, the bots, replication). This is the "tick".
--   think cpu    BotService.Stats.maxTick: the bots' own think slice, os.clock (CPU time in Roblox).
--   think wall   BotService.Stats.maxTickWall: the same slice on the wall clock. Far above think cpu
--                means a think yielded; far below frame means the worst frame was not the bots.
--   worst think  the slowest single bot think and its branch (BotService.MaxBotBranch).
-- The planted fault: a deliberate PLANT_MS stall inside one Heartbeat, once, in its own pass. The
-- probe must report a worst frame at least that long; if it does not, its numbers are not frames.

local MAP_ID = "SahurSprings"
local BOT_COUNTS = { 30, 50 }
local WARM_SECONDS = 15
local MEASURE_SECONDS = 90
local STORM_SPEED = 1
local PLANT_MS = 60

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

say("build: BotService.ThinkSlices = %s (nil = the two-halves loop from before #131)", tostring(BotService.ThinkSlices))

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
	for _, key in ipairs({ "maxTick", "maxTickWall", "maxBotUpdate" }) do
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
	return percentile(sorted, 1)
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
for _, count in ipairs(BOT_COUNTS) do
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
	say("%d bots spawned (%d asked for)", #bots, count)
	measure(string.format("%d bots, first %d s (the drop's route burst)", count, WARM_SECONDS), WARM_SECONDS)
	measure(string.format("%d bots, settled", count), MEASURE_SECONDS)
	local alive = 0
	for _, bot in ipairs(BotService.GetAll()) do
		if bot.humanoid and bot.humanoid.Health > 0 then
			alive += 1
		end
	end
	say("%d bots: %d alive at the end", count, alive)
	BotService.Clear()
	StormService.Stop()
	-- Clear() stops the think loop by flag; let it wake and exit before the next Start().
	task.wait(2)
end

heartbeat:Disconnect()
LootService.Clear()
MapGenerator.Clear()
say("probe finished")
