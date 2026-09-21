-- Rate-limit probe for tools/runtest.ps1 -Probe: the budgets in ServerScriptService/Modules/RateLimit
-- against how the game's own clients actually send, and against floods.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/ratelimit_probe.lua
--
-- Time runs on a virtual clock (RateLimit.Now, a field for exactly this), so a 30-second stream takes
-- no time at all and the numbers are exact rather than timing-dependent. Nothing here touches a real
-- player or a remote: it drives RateLimit directly with a stand-in player.
--
-- The point of each case:
--   LEGIT streams (what CombatClient / MovementClient / HudClient / MenuClient really send) must lose
--   NOTHING, and a state setter must end on the newest value.
--   FLOODS (a modified client sending every frame) must be bounded by burst + rate * seconds.
--   A planted build with the limiter stubbed out must FAIL the flood cases: that's what makes the
--   passes mean something (run it with the tree in scratchpad/ab/nolimit).
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local RateLimit = require(modules:WaitForChild("RateLimit"))
local WeaponData = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("WeaponData"))

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[RateProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

-- Virtual clock.
local clock = 0
local realNow = RateLimit.Now
RateLimit.Now = function()
	return clock
end
local function advance(seconds)
	clock += seconds
end

local player = { UserId = -424252, Name = "RateProbe" }
local function reset()
	RateLimit.Clear(player)
end

-- A stream of `count` calls spread over `seconds`, at a steady rate.
local function stream(key, count, seconds)
	local sent, allowed = 0, 0
	for index = 1, count do
		if RateLimit.Take(player, key) then
			allowed += 1
		end
		sent += 1
		if index < count then
			advance(seconds / count)
		end
	end
	return allowed, sent
end

-- WeaponData.Weapons already has the expansion and creative packs merged into it at require time.
local fastest = 0
for _, def in pairs(WeaponData.Weapons) do
	if type(def) == "table" and type(def.fireRate) == "number" then
		fastest = math.max(fastest, def.fireRate)
	end
end
expect("the fastest gun's fireRate is under the Fire budget's refill rate", fastest > 0 and fastest < RateLimit.Budgets.Fire.rate,
	string.format("fastest %.1f/s, budget %.1f/s refill, burst %d", fastest, RateLimit.Budgets.Fire.rate, RateLimit.Budgets.Fire.burst))

-- LEGIT ---------------------------------------------------------------------------------------------
reset()
local allowed, sent = stream("Fire", math.floor(fastest * 30), 30)
expect("holding fire at the fastest gun's rate for 30s loses no shots (the touch FIRE button's pattern)", allowed == sent,
	string.format("%d of %d allowed", allowed, sent))

reset()
allowed, sent = stream("UseSelected", 12, 3)
expect("clicking an item 4 times a second for 3s loses nothing", allowed == sent, string.format("%d of %d", allowed, sent))

reset()
allowed, sent = stream("Menu", 8, 1)
expect("spam-clicking OPEN 8 times in a second loses nothing", allowed == sent, string.format("%d of %d", allowed, sent))

reset()
allowed, sent = stream("Reload", 4, 1)
expect("four reload presses in a second lose nothing", allowed == sent, string.format("%d of %d", allowed, sent))

-- A weapon-wheel spin: 12 changes in 0.2s. The final slot must be applied, exactly once.
reset()
local applied = {}
for slot = 1, 12 do
	RateLimit.Latest(player, "EquipSlot", slot, function(value)
		table.insert(applied, value)
	end)
	advance(0.2 / 12)
end
local immediate = #applied
-- The pending one lands when its token is due; the probe's clock doesn't drive task.delay, so wait for it.
advance(2)
task.wait(0.6)
local last = applied[#applied]
local ordered = true
for index = 2, #applied do
	if applied[index] <= applied[index - 1] then
		ordered = false
	end
end
-- The bound is the burst PLUS what refills during the spin itself, plus the one pending apply at the
-- end. (This assertion first said burst + 1 and failed at 10 of 12: the 0.2s spin refills 1.6 tokens.)
local spinBound = math.floor(RateLimit.Budgets.EquipSlot.burst + RateLimit.Budgets.EquipSlot.rate * 0.2) + 1
expect("a 12-slot wheel spin ends on the slot the player stopped on, applied once, never out of order",
	last == 12 and ordered and #applied <= spinBound,
	string.format("applied %d of 12 (%d immediately), last %s, in order %s, bound %d", #applied, immediate, tostring(last), tostring(ordered), spinBound))

-- FLOODS --------------------------------------------------------------------------------------------
reset()
allowed, sent = stream("Fire", 1000, 0)
expect("1000 shots in one instant are cut to the burst", allowed == RateLimit.Budgets.Fire.burst,
	string.format("%d allowed of %d, burst %d", allowed, sent, RateLimit.Budgets.Fire.burst))
advance(1)
allowed = stream("Fire", 1000, 0)
expect("a second later, only a second's refill gets through", allowed == RateLimit.Budgets.Fire.rate,
	string.format("%d allowed, refill %d/s", allowed, RateLimit.Budgets.Fire.rate))

reset()
allowed, sent = stream("Menu", 500, 0)
advance(10)
local second = stream("Menu", 500, 0)
local budget = RateLimit.Budgets.Menu
expect("a menu flood is bounded by burst, then by the refill rate", allowed == budget.burst and second == budget.burst,
	string.format("%d then %d, burst %d, rate %.0f/s over 10s", allowed, second, budget.burst, budget.rate))

reset()
local equipApplied = 0
for _ = 1, 600 do
	RateLimit.Latest(player, "EquipSlot", 1, function()
		equipApplied += 1
	end)
end
task.wait(0.3)
expect("600 equip events in one instant rebuild the held gun at most burst + 1 times", equipApplied <= RateLimit.Budgets.EquipSlot.burst + 1,
	string.format("%d applied, burst %d", equipApplied, RateLimit.Budgets.EquipSlot.burst))

-- LEAVING -------------------------------------------------------------------------------------------
reset()
local afterLeave = 0
for slot = 1, 30 do
	RateLimit.Latest(player, "EquipSlot", slot, function()
		afterLeave += 1
	end)
end
local appliedBeforeLeave = afterLeave
RateLimit.Clear(player) -- they left
advance(5)
task.wait(0.6)
expect("nothing pending is applied after the player leaves", afterLeave == appliedBeforeLeave,
	string.format("%d applied before leaving, %d after", appliedBeforeLeave, afterLeave))

-- Every budget must be usable and sane.
for key, def in pairs(RateLimit.Budgets) do
	if type(def.burst) ~= "number" or type(def.rate) ~= "number" or def.burst < 1 or def.rate <= 0 or def.burst < def.rate * 0.2 then
		expect("budget " .. key .. " is sane", false, string.format("burst %s rate %s", tostring(def.burst), tostring(def.rate)))
	end
end

RateLimit.Now = realNow
RateLimit.Clear(player)

--------------------------------------------------------------------------------
-- THE CLOCK ITSELF, on a real wall clock.
--
-- Everything above runs on the virtual clock, which is what makes a 30-second stream instant — and
-- which is exactly why none of it could ever catch the bug this section exists for. Swapping the
-- clock out proves the ARITHMETIC and says nothing about which real clock ships. `RateLimit.Now`
-- was `os.clock` — process CPU time — while every budget in the table is written in wall-clock
-- terms, so a server that spends its time yielding refilled every bucket slowly and refused
-- legitimate shots the client had already drawn a tracer for.
--
-- This measures the shipped clock against the wall, and then plants the bug itself: `os.clock` put
-- back deliberately, which must FAIL the same measurement. If it ever passes, the check has stopped
-- being able to tell the two apart and the number it prints is worthless.
--------------------------------------------------------------------------------

local WALL_SECONDS = 1.0
-- Generous: this only has to separate "tracks the wall" from "tracks CPU time", and a runtest
-- server is busy enough that a tighter band would be flaky rather than more truthful.
local TOLERANCE = 0.25

local function advanceOverOneSecond(clockFn)
	local start = clockFn()
	-- The wall reading is task.wait's own return: the real elapsed time it slept for, summed. Not
	-- os.time(), which is whole seconds and cannot measure one.
	local waited = 0
	while waited < WALL_SECONDS do
		waited += task.wait(0.05)
	end
	return clockFn() - start, waited
end

local shippedAdvance, shippedWall = advanceOverOneSecond(RateLimit.Now)
local shippedRatio = shippedAdvance / shippedWall
expect("RateLimit.Now tracks the wall clock", math.abs(shippedRatio - 1) <= TOLERANCE,
	string.format("advanced %.3fs over %.3fs of wall time, ratio %.3f", shippedAdvance, shippedWall, shippedRatio))

-- The refill, end to end and in real time: drain the bucket, wait a real second, and the tokens
-- back must be the budget's rate times the seconds that really passed.
local key = "Fire"
local budget = RateLimit.Budgets[key]
RateLimit.Clear(player)
local drained = 0
while RateLimit.Take(player, key) do
	drained += 1
	if drained > budget.burst + 5 then
		break
	end
end
local waited = 0
while waited < WALL_SECONDS do
	waited += task.wait(0.05)
end
local refilled = 0
while RateLimit.Take(player, key) do
	refilled += 1
	if refilled > budget.burst + 5 then
		break
	end
end
-- Capped at the burst: a bucket cannot hold more than that however long you wait, and a budget
-- whose rate exceeds its burst would otherwise fail this for being correct.
local wanted = math.min(budget.burst, budget.rate * waited)
expect("a bucket refills at its budget's rate in WALL seconds", math.abs(refilled - wanted) <= math.max(1, wanted * 0.35),
	string.format("%s: drained %d, %.2fs later got %d back, expected about %.1f", key, drained, waited, refilled, wanted))

-- PLANTED FAULT, every run: the clock this file was shipped with. It must fail the measurement
-- above, and what it prints is the size of the bug.
RateLimit.Now = os.clock
local cpuAdvance, cpuWall = advanceOverOneSecond(RateLimit.Now)
local cpuRatio = cpuAdvance / cpuWall
RateLimit.Now = realNow
expect("planted fault: os.clock FAILS the wall-clock check, so the check can tell them apart",
	math.abs(cpuRatio - 1) > TOLERANCE,
	string.format("os.clock advanced %.3fs over %.3fs of wall time, ratio %.3f -- a bucket would refill at %.0f%% of its budget",
		cpuAdvance, cpuWall, cpuRatio, cpuRatio * 100))

RateLimit.Clear(player)
print(string.format("[RateProbe] finished: %d passed, %d failed", passes, failures))
