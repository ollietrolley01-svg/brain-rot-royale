-- Probe for tools/runtest.ps1 -Probe: progression in a LIVE SERVER, with nothing stubbed.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/progression_runtime_probe.lua
--
-- tools/progression_probe.lua tests the modules in edit mode, where StateSync, Monetization and the
-- remotes are stand-ins. This one starts Run mode and injects a Script into ServerScriptService, which
-- runs in the SERVER's context and shares its module cache (proved by tools/runtime_script_probe.lua),
-- so every module it touches is the one Bootstrap wired. What that catches and the edit-mode probe
-- can't: a hook Bootstrap forgot to connect, a remote that was never created, a snapshot that only
-- builds because the edit-mode probe replaced StateSync, and the real size of a push.
--
-- Run mode runs no client scripts, so the rank-up toast, the results card and the Pass tab are NOT
-- checked here -- those need a hand playtest. This probe says what it proved, not what it hoped.
--
-- It uses a real Player when Studio will make one (Players:CreateLocalPlayer) and a stand-in table
-- otherwise; the stand-in is left unparented so StateSync skips it instead of firing a remote at a
-- table. Which one it got is reported, and the push checks only run for a real Player.

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[PROBE] %s %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

if not RunService:IsRunning() then
	print("[PROBE] starting run mode")
	RunService:Run()
end

-- Bootstrap's progression remotes are the last thing it makes, so their arrival means it got that far.
local waited, remotes = 0, nil
while waited < 60 do
	remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes and remotes:FindFirstChild("BuyCellOffer") then
		break
	end
	task.wait(0.5)
	waited += 0.5
end
expect("the server booted and Bootstrap wired the progression remotes", remotes ~= nil and remotes:FindFirstChild("BuyCellOffer") ~= nil,
	string.format("%.1fs", waited))
if not (remotes and remotes:FindFirstChild("BuyCellOffer")) then
	print("[PROBE] progression runtime: 1 failed (the server never finished booting; nothing below ran)")
	return
end
task.wait(2)

local RESULT = "BRR_ProgRuntime"
workspace:SetAttribute(RESULT, nil)

local worker = Instance.new("Script")
worker.Name = "BRR_ProgressionRuntimeProbe"
worker.Source = [==[
	local Players = game:GetService("Players")
	local HttpService = game:GetService("HttpService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

	local ProgressionData = require(ReplicatedStorage.Shared.ProgressionData)
	local ProgressionService = require(modules.ProgressionService)
	local PlayerData = require(modules.PlayerData)
	local BattlePassService = require(modules.BattlePassService)
	local MatchService = require(modules.MatchService)
	local StateSync = require(modules.StateSync)

	local out = {}
	-- This probe loads a profile and pays it Cells. In Studio with live API services that profile
	-- would be written to the real DataStore on release, so it refuses to run there at all.
	if PlayerData.HasStore and PlayerData.HasStore() then
		out.refused = true
		workspace:SetAttribute("BRR_ProgRuntime", HttpService:JSONEncode(out))
		return
	end

	local function try(name, fn)
		local ok, err = pcall(fn)
		if not ok then
			out[name .. "Error"] = tostring(err)
		end
		return ok
	end

	-- 1. Wiring Bootstrap is responsible for.
	out.onXpWired = BattlePassService.OnXp == ProgressionService.OnPassXp
	out.summaryWired = type(MatchService.ProgressionSummary) == "function"
	out.killWired = type(ProgressionService.OnKillCredited) == "function"
	local names = {}
	for _, remote in ipairs(ReplicatedStorage.Remotes:GetChildren()) do
		names[remote.Name] = true
	end
	out.remotes = names.Prestige == true and names.ClaimIndex == true and names.BuyCellOffer == true

	-- 2. A player to work with: a real one if Studio will make it, a stand-in otherwise. The stand-in is
	-- left unparented, so StateSync skips it rather than firing a remote at a table.
	local player, real = nil, false
	local ok, made = pcall(function()
		return Players:CreateLocalPlayer(-7090001)
	end)
	if ok and typeof(made) == "Instance" and made:IsA("Player") then
		player, real = made, true
	else
		local attributes = {}
		player = { UserId = -7090002, Name = "RuntimeProbe", DisplayName = "RuntimeProbe", Parent = nil, attributes = attributes }
		function player:SetAttribute(key, value)
			attributes[key] = value
		end
		function player:GetAttribute(key)
			return attributes[key]
		end
	end
	out.realPlayer = real

	local data = PlayerData.Load(player)
	out.loaded = type(data) == "table" and type(data.Progression) == "table"
	if not out.loaded then
		workspace:SetAttribute("BRR_ProgRuntime", HttpService:JSONEncode(out))
		return
	end
	local progression = data.Progression
	out.paidRankField = progression.paidRank ~= nil
	ProgressionService.OnProfileLoaded(player)

	-- 3. Pass XP through the real hook: BattlePassService is what the game calls, and rank XP must
	-- follow it without the pass losing anything.
	local passXpBefore = data.Pass and data.Pass.xp or 0
	local rankXpBefore, cellsBefore = progression.xp, progression.cells
	try("passXp", function()
		BattlePassService.AddXp(player, 900)
	end)
	task.wait(0.5)
	out.passXpGained = (data.Pass and data.Pass.xp or 0) - passXpBefore
	out.rankXpGained = progression.xp - rankXpBefore
	out.cellsPaid = progression.cells - cellsBefore

	-- 4. Earning the same XP again must not pay the same ranks again.
	local cellsAfterFirst = progression.cells
	local xpAfterFirst = progression.xp
	progression.xp = rankXpBefore
	try("replay", function()
		ProgressionService.AddXp(player, xpAfterFirst - rankXpBefore)
	end)
	out.replayCells = progression.cells - cellsAfterFirst

	-- 5. The results line, from the real MatchService entry point.
	try("summary", function()
		ProgressionService.BeginMatch({ player })
		ProgressionService.AddXp(player, 400)
		local summary = MatchService.ProgressionSummary(player)
		out.summary = summary and {
			rankFrom = summary.rankFrom, rank = summary.rank, xp = summary.xp,
			cells = summary.cells, xpNeed = summary.xpNeed,
		} or nil
	end)

	-- Read the rank, the attribute and paidRank together, after the last XP above: comparing a rank
	-- taken earlier against a snapshot taken now would just be measuring the gap between them.
	out.rank = ProgressionData.RankForXp(progression.xp)
	out.rankAttribute = player:GetAttribute("RotRank")
	out.paidRank = progression.paidRank

	-- 6. The snapshot the client actually receives, built by the real StateSync.
	try("state", function()
		local state = StateSync.Build(player)
		out.stateHasProgression = state ~= nil and state.progression ~= nil
		if state and state.progression then
			out.snapshotBytes = #HttpService:JSONEncode(state.progression)
			out.stateBytes = #HttpService:JSONEncode(state)
			out.snapshotRank = state.progression.rank
			out.snapshotCells = state.progression.cells
		end
	end)
	if real then
		try("push", function()
			StateSync.Push(player)
		end)
		task.wait(0.5)
	end

	-- 7. Leave nothing behind. PlayerData.Release is never called: it saves, and this profile is a
	-- test one. Nothing above can reach a DataStore anyway -- the refusal at the top saw to that.
	if real and typeof(player) == "Instance" then
		pcall(function()
			player:Destroy()
		end)
	end

	workspace:SetAttribute("BRR_ProgRuntime", HttpService:JSONEncode(out))
]==]
worker.Parent = ServerScriptService

local deadline = os.clock() + 30
while os.clock() < deadline and workspace:GetAttribute(RESULT) == nil do
	task.wait(0.25)
end
local raw = workspace:GetAttribute(RESULT)
worker:Destroy()
expect("the worker ran in the server and reported", type(raw) == "string", raw == nil and "no result in 30s" or nil)
if type(raw) ~= "string" then
	print(string.format("[PROBE] progression runtime: %d passed, %d failed", passes, failures))
	return
end

local out = HttpService:JSONDecode(raw)
print("[PROBE] runtime result: " .. raw)
if out.refused then
	-- Correct behaviour, but the run proved nothing, so it must not read as a pass.
	expect("this Studio has live DataStore access, so the probe refused to load a test profile", false,
		"run it in an unpublished place, or with Studio Access to API Services off")
	print(string.format("[PROBE] progression runtime: %d passed, %d failed", passes, failures))
	return
end
for key, value in pairs(out) do
	if string.sub(key, -5) == "Error" then
		expect("no error from " .. string.sub(key, 1, -6), false, value)
	end
end

expect("Bootstrap wired BattlePassService.OnXp to ProgressionService.OnPassXp", out.onXpWired == true)
expect("Bootstrap wired MatchService.ProgressionSummary", out.summaryWired == true)
expect("ProgressionService.OnKillCredited exists for MatchService's elimination hook", out.killWired == true)
expect("the Prestige, ClaimIndex and BuyCellOffer remotes all exist", out.remotes == true)
print("[PROBE] player used: " .. (out.realPlayer and "a real Player instance" or "a stand-in table (CreateLocalPlayer unavailable)"))
expect("a profile loads in the live server with a Progression table", out.loaded == true)
expect("the profile carries paidRank", out.paidRankField == true)
expect("pass XP still reaches the pass", out.passXpGained == 900, out.passXpGained)
expect("the same XP reaches Rot Rank through the live hook", out.rankXpGained == 900, out.rankXpGained)
expect("ranks crossed paid Cells", (out.cellsPaid or 0) > 0, out.cellsPaid)
expect("the rank attribute the nameplate reads is set", out.rankAttribute == out.rank, string.format("attribute %s, rank %s", tostring(out.rankAttribute), tostring(out.rank)))
expect("paidRank tracked the rank reached", out.paidRank == out.rank, string.format("%s vs %s", tostring(out.paidRank), tostring(out.rank)))
expect("re-earning the same XP pays nothing a second time", out.replayCells == 0, out.replayCells)
expect("the results card gets a summary with a rank and XP into the next", out.summary ~= nil and out.summary.rank ~= nil
	and out.summary.xp == 400 and out.summary.xpNeed ~= nil, out.summary and HttpService:JSONEncode(out.summary) or "nil")
expect("the real StateSync build carries the progression snapshot", out.stateHasProgression == true)
expect("the snapshot agrees with the profile", out.snapshotRank == out.rank, string.format("%s vs %s", tostring(out.snapshotRank), tostring(out.rank)))
-- A push happens on every rank-up and every Cell Shop buy; it has to stay small enough to be cheap.
expect("the progression snapshot stays under 6 KB", (out.snapshotBytes or 1e9) < 6144, out.snapshotBytes)
print(string.format("[PROBE] snapshot %s bytes of a %s byte state push", tostring(out.snapshotBytes), tostring(out.stateBytes)))

print(string.format("[PROBE] progression runtime: %d passed, %d failed", passes, failures))
