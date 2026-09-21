-- Probe for tools/runtest.ps1 -Probe: a trade can't be run twice by confirming again while it saves.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/trade_double_confirm_probe.lua
--
-- The real TradeService, loaded as a copy whose two RemoteEvents are stand-ins (edit mode has no
-- Player to fire at), with stand-in players on real default profiles. PlayerData.Save is stubbed
-- to yield half a second, as a DataStore write does. A has 50 of a Common, B has 2 of a Rare; they
-- trade one for one, and while the trade is saving A confirms again. Afterwards A must have exactly
-- 1 Rare and B exactly 1: a second Rare on A's side means the trade ran twice.
--
-- SOURCE_OVERRIDE (nil here) lets a copy of this probe run older TradeService source through the
-- same test, to show the test fails on the code it was written against.

local SOURCE_OVERRIDE = nil

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))

local function out(fmt, ...)
	print("[AUDIT trade] " .. string.format(fmt, ...))
end

-- The copy: the same code with its remotes swapped for stand-ins that record what they'd send.
local original = modules:WaitForChild("TradeService")
local source = SOURCE_OVERRIDE or original.Source
local patched, swaps = string.gsub(source, 'Remotes%.Event%("Trade(%a+)"%)', '{ FireClient = function() end }')
if swaps ~= 2 then
	out("RESULT INCONCLUSIVE: expected to swap 2 remotes in TradeService, swapped %d", swaps)
	pcall(flush)
	return
end
local copy = Instance.new("ModuleScript")
copy.Name = "TradeServiceProbeCopy"
copy.Source = patched
copy.Parent = modules
local okRequire, TradeService = pcall(require, copy)
if not okRequire then
	out("RESULT INCONCLUSIVE: the copy didn't load: %s", tostring(TradeService))
	copy:Destroy()
	pcall(flush)
	return
end

local realSave, realNotify, realPush = PlayerData.Save, StateSync.Notify, StateSync.Push
local saves = 0
PlayerData.Save = function()
	saves += 1
	task.wait(0.5)
	return true
end
StateSync.Notify = function() end
StateSync.Push = function() end

local function standIn(userId, name)
	return { UserId = userId, Name = name, DisplayName = name, Parent = true }
end
local a, b = standIn(-910001, "TraderA"), standIn(-910002, "TraderB")
PlayerData.Load(a)
PlayerData.Load(b)
local common = BrainrotData.OfRarity("Common")[1].name
local rare = BrainrotData.OfRarity("Rare")[1].name
local dataA, dataB = PlayerData.Get(a), PlayerData.Get(b)
table.clear(dataA.Brainrots)
table.clear(dataB.Brainrots)
for _ = 1, 50 do
	table.insert(dataA.Brainrots, common)
end
for _ = 1, 2 do
	table.insert(dataB.Brainrots, rare)
end

local function count(data, name)
	local n = 0
	for _, owned in ipairs(data.Brainrots) do
		if owned == name then
			n += 1
		end
	end
	return n
end

local steps = {}
local function step(label, ok, message)
	table.insert(steps, string.format("%s %s%s", label, tostring(ok), message and (" (" .. tostring(message) .. ")") or ""))
end
step("request", TradeService.Request(a, b))
step("respond", TradeService.Respond(b, true))
step("offer A", TradeService.Offer(a, common, true))
step("offer B", TradeService.Offer(b, rare, true))
step("confirm A", TradeService.Confirm(a, true))
local secondResult = "not sent"
task.spawn(function()
	-- B's confirm starts the trade, which yields in its first save.
	TradeService.Confirm(b, true)
end)
task.wait(0.1)
local okAgain, messageAgain = TradeService.Confirm(a, true)
secondResult = string.format("%s (%s)", tostring(okAgain), tostring(messageAgain))
task.wait(2)

local rareA, rareB = count(dataA, rare), count(dataB, rare)
local commonA, commonB = count(dataA, common), count(dataB, common)
out("steps: %s", table.concat(steps, "; "))
out("confirm again while saving: %s; saves made %d", secondResult, saves)
out("after: A has %d %s and %d %s; B has %d %s and %d %s", rareA, rare, commonA, common, rareB, rare, commonB, common)
local once = rareA == 1 and rareB == 1 and commonA == 49 and commonB == 1
out("RESULT %s: the trade ran %s", once and "PASS" or "FAIL", once and "once" or ("more than once or not at all (A has " .. rareA .. " Rares)"))

-- Second test: stars live on the profile, so the last copy of a merged brainrot can't be traded away.
local starred = BrainrotData.OfRarity("Epic")[1].name
table.clear(dataA.Brainrots)
table.clear(dataB.Brainrots)
for _ = 1, 2 do
	table.insert(dataA.Brainrots, starred)
end
dataA.Stars = dataA.Stars or {}
dataA.Stars[starred] = 3
local okStar1, whyStar1 = TradeService.Request(a, b)
local okStar2 = TradeService.Respond(b, true)
local okSpare, whySpare = TradeService.Offer(a, starred, true)
local okLast, whyLast = TradeService.Offer(a, starred, true)
out("merged offer: request %s%s, respond %s; first (a spare) %s%s; second (the last copy) %s (%s)",
	tostring(okStar1), whyStar1 and (" (" .. tostring(whyStar1) .. ")") or "", tostring(okStar2), tostring(okSpare),
	whySpare and (" (" .. tostring(whySpare) .. ")") or "", tostring(okLast), tostring(whyLast))
TradeService.Confirm(a, true)
TradeService.Confirm(b, true)
task.wait(2)
local keptCopies, keptStars = count(dataA, starred), dataA.Stars[starred]
out("after trading the spare: A has %d %s, stars %s; B has %d", keptCopies, starred, tostring(keptStars), count(dataB, starred))
local starsHeld = okSpare == true and okLast == false and keptCopies == 1 and keptStars == 3 and count(dataB, starred) == 1
out("RESULT merged last copy %s", starsHeld and "PASS" or "FAIL")

PlayerData.Save, StateSync.Notify, StateSync.Push = realSave, realNotify, realPush
pcall(PlayerData.Release, a)
pcall(PlayerData.Release, b)
copy:Destroy()
pcall(flush)
