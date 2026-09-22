-- Storm vs the lobby (#108): a body that is NOT a live participant of the running match never takes
-- storm damage -- from EITHER tick (Start's, the battle royale; StartStatic's, the team modes at 4 dps).
--
-- Run: powershell tools/runtest.ps1 -Probe tools/storm_lobby_probe.lua -WaitSeconds 600 [-PlaceFile <private.rbxlx>]
--
-- Written against the INVARIANT, not the bug: "a token MatchService does not hold alive never loses
-- health to the storm tick". Real wiring, real enrolment:
--   * requiring MatchService runs its module-level StormService.SetEligibility(...) into THIS VM's
--     StormService -- the probe installs no predicate of its own except as a planted fault;
--   * two REAL matches run through MatchService's own state machine (this VM's MatchConfig.MinPlayers
--     lowered to 0 so a bots-only match starts): match 1 is the battle royale (Start's tick), match 2
--     Team Deathmatch (StartStatic's tick), by GameModes.Rotation;
--   * the tokens it measures were enrolled by startMatch's own onSpawned callback (participants/alive/
--     watchDeath). BotService.Spawn is wrapped to hand that callback anchored probe rigs instead of
--     R15s from the web: deterministic, no fall deaths (a bot death in a bots-only royale ends the
--     match), and the callback -- the thing under test -- is untouched. One extra PLAYER-SHAPED token
--     (isBot = false, not a Player) goes through the same callback: MatchService.eliminate treats it
--     as it treats a player (the respawn-mode branch returns BEFORE alive[token] is cleared), which
--     is the ordering claim this probe pins, since a Studio window has no Player to die.
--   * the lobby body is a rig at the lobby spawn registered into Combatants exactly as OnCharacterAdded
--     registers every character, and never enrolled.
--
-- Every window prints: examined N registered bodies, E eligible, I ineligible, flagged F. Plants (on
-- BOTH ticks): "everyone" predicate; NO predicate; "nobody" predicate (a dead storm must be flagged,
-- not passed). Plus the shipped code's own alarm: Start/StartStatic warn when they begin unwired, and
-- do NOT warn when wired.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local LogService = game:GetService("LogService")

local function say(fmt, ...)
	print(string.format("[storm108] " .. fmt, ...))
end

local checks, failures, inconclusive = 0, 0, 0
local function pass(name, detail)
	checks += 1
	say("PASS  %-40s %s", name, detail or "")
end
local function fail(name, detail)
	checks += 1
	failures += 1
	say("FAIL  %-40s %s", name, detail or "")
end
local function unknown(name, detail)
	checks += 1
	inconclusive += 1
	say("INCONCLUSIVE %-33s %s", name, detail or "")
end
local function selftest(name, caught, what)
	checks += 1
	if caught then
		say("PLANT ok   %-35s caught: %s", name, what)
	else
		failures += 1
		say("PLANT DEAD %-35s did NOT catch %s -- this check tests nothing", name, what)
	end
end
local function section(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		failures += 1
		say("SECTION ERROR %s: %s", name, tostring(err))
	end
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local StormService = require(Modules:WaitForChild("StormService"))
local VoteService = require(Modules:WaitForChild("VoteService"))
local BotService = require(Modules:WaitForChild("BotService"))
local LobbyService = require(Modules:WaitForChild("LobbyService"))

--------------------------------------------------------------------------------
-- This VM's knobs: a bots-only match that starts on its own, on the smallest map, quickly.
--------------------------------------------------------------------------------
MatchConfig.MinPlayers = 0
MatchConfig.LobbyCountdown = 2
MatchConfig.DropSelectSeconds = 1
MatchConfig.Intermission = 3
MatchConfig.BotFillTarget = 3
-- The battle royale's first hold is where this probe moves the circle by hand; keep the phase walker
-- holding (not shrinking over the numbers) for as long as the checks take.
MatchConfig.StormPhases[1].holdTime = 900
VoteService.Resolve = function()
	return "RotRidge", nil -- nil mode = GameModes.Rotation: match 1 BattleRoyale, match 2 TeamDeathmatch
end

--------------------------------------------------------------------------------
-- Rigs and tokens
--------------------------------------------------------------------------------
local LOBBY_SPAWN = MatchConfig.LobbyPosition + LobbyService.SpawnOffset
local FAR = Vector3.new(6000, 0, 6000)
local rigs = {}

local function makeRig(name, at)
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored, root.CanCollide, root.Transparency = true, false, 1
	root.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Anchored, head.CanCollide, head.Transparency = true, false, 1
	head.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	model:PivotTo(CFrame.new(at))
	table.insert(rigs, model)
	return model, humanoid
end

-- Per-match records handed through startMatch's REAL onSpawned callback by the Spawn wrapper.
local current = { records = {}, shaped = nil }
BotService.Spawn = function(count, cframeFor, onSpawned, options)
	current = { records = {}, shaped = nil }
	local spawned = {}
	for index = 1, count do
		local at = cframeFor(index).Position
		local rig, humanoid = makeRig("ProbeBot" .. index, at)
		local record = { isBot = true, name = "ProbeBot" .. index, character = rig, humanoid = humanoid, weapon = nil, heals = {}, shields = {} }
		Combatants.Register(rig, record) -- as BotService.lua does for every rig it builds
		onSpawned(record, humanoid)
		table.insert(spawned, record)
		table.insert(current.records, record)
	end
	local rig, humanoid = makeRig("ProbePlayerShaped", cframeFor(1).Position + Vector3.new(4, 0, 0))
	local shaped = { isBot = false, name = "ProbePlayerShaped", character = rig, humanoid = humanoid }
	Combatants.Register(rig, shaped)
	onSpawned(shaped, humanoid)
	current.shaped = shaped
	return spawned
end

-- Requiring MatchService is the wire under test: its module body calls StormService.SetEligibility.
local MatchService = require(Modules:WaitForChild("MatchService"))
local GameMode = require(Modules:WaitForChild("GameMode"))

section("wire installed", function()
	local fn = StormService.GetEligibility and StormService.GetEligibility()
	if type(fn) == "function" then
		pass("predicate installed by MatchService", "GetEligibility() is a function after require(MatchService)")
	else
		fail("predicate installed by MatchService", "GetEligibility() = " .. tostring(fn))
	end
end)

-- The lobby body: registered the way OnCharacterAdded registers every character, never enrolled.
local lobbyRig, lobbyHumanoid = makeRig("ProbeLobbyBody", LOBBY_SPAWN + Vector3.new(0, 3, 0))
local lobbyToken = { name = "LobbyToken", character = lobbyRig }
Combatants.Register(lobbyRig, lobbyToken)
task.wait(1)
section("rig precondition", function()
	if lobbyHumanoid.Health > 0 then
		pass("probe rigs are alive", string.format("lobby rig health %.0f at %s", lobbyHumanoid.Health, tostring(lobbyRig:GetPivot().Position)))
	else
		unknown("probe rigs are alive", "lobby rig died on its own; every damage window below is void")
	end
end)

--------------------------------------------------------------------------------
-- The detector: one pure function, used by the real check and by every plant
--------------------------------------------------------------------------------
local function candidates()
	local rows = {}
	for character, token in pairs(Combatants.All()) do
		if character.Parent then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				table.insert(rows, { character = character, token = token, humanoid = humanoid, name = Combatants.GetName(token) })
			end
		end
	end
	return rows
end

local function topUp(rows)
	for _, row in ipairs(rows) do
		row.humanoid.Health = row.humanoid.MaxHealth
	end
end

-- Moves the live circle far away and shrinks it so EVERY body is outside; 5 dps keeps the eligible
-- rigs alive across all windows (a death in a bots-only royale ends the match).
local function exile()
	local st = StormService.GetState()
	st.center, st.targetCenter = FAR, FAR
	st.radius, st.targetRadius = 5, 5
	st.damagePerSecond = 5
end

local function measure(seconds)
	local rows = candidates()
	topUp(rows)
	exile()
	for _, row in ipairs(rows) do
		row.eligible = MatchService.IsAlive(row.token)
		row.before = row.humanoid.Health
	end
	task.wait(seconds)
	for _, row in ipairs(rows) do
		row.after = row.humanoid.Health
		row.damaged = (row.before - row.after) > 0
	end
	return rows
end

local function judge(rows)
	local verdict = { examined = #rows, eligible = 0, ineligible = 0, flagged = {}, liveHits = 0, lobbySeen = false }
	for _, row in ipairs(rows) do
		if row.token == lobbyToken then
			verdict.lobbySeen = true
		end
		if row.eligible then
			verdict.eligible += 1
			if row.damaged then
				verdict.liveHits += 1
			end
		else
			verdict.ineligible += 1
			if row.damaged then
				table.insert(verdict.flagged, string.format("%s lost %.0f", row.name, row.before - row.after))
			end
		end
	end
	return verdict
end

local function describe(v)
	return string.format("examined %d (eligible %d, ineligible %d), eligible bodies hit %d, ineligible bodies flagged %d%s",
		v.examined, v.eligible, v.ineligible, v.liveHits, #v.flagged, #v.flagged > 0 and (": " .. table.concat(v.flagged, "; ")) or "")
end

local function waitForState(target, seconds)
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		if MatchService.GetState() == target then
			return true
		end
		task.wait(0.5)
	end
	return false
end

--------------------------------------------------------------------------------
-- One block per tick: the invariant, then the three plants, on the LIVE storm of a REAL match
--------------------------------------------------------------------------------
local function stormBlock(label)
	local st = StormService.GetState()
	say("%s: storm status %s, phase %d, dps %.0f, radius %.0f, mode %s", label, tostring(st.status), st.phase or 0, st.damagePerSecond or 0, st.radius or 0, tostring(GameMode.Current().id))
	if st.status == "Idle" then
		unknown(label .. " storm live", "storm is Idle; nothing to measure")
		return
	end

	local realPredicate = StormService.GetEligibility()

	section(label .. " invariant", function()
		local v = judge(measure(3.5))
		say("%s window: %s", label, describe(v))
		if not v.lobbySeen then
			unknown(label .. " lobby body examined", "the lobby rig never entered the comparison")
		elseif #v.flagged > 0 then
			fail(label .. " no storm damage outside the match", describe(v))
		else
			pass(label .. " no storm damage outside the match", string.format("%d ineligible bodies, lobby included, unharmed", v.ineligible))
		end
		if v.liveHits > 0 then
			pass(label .. " storm still hurts the match", string.format("%d of %d eligible bodies lost health", v.liveHits, v.eligible))
		else
			fail(label .. " storm still hurts the match", "no eligible body lost health: the tick is dead or the predicate spares everyone")
		end
	end)

	section(label .. " plant: everyone", function()
		StormService.SetEligibility(function()
			return true
		end)
		local v = judge(measure(2.5))
		StormService.SetEligibility(realPredicate)
		selftest(label .. " everyone-predicate", #v.flagged > 0, "the lobby body took damage under an everyone predicate (" .. describe(v) .. ")")
	end)

	section(label .. " plant: unwired", function()
		StormService.SetEligibility(nil)
		local v = judge(measure(2.5))
		StormService.SetEligibility(realPredicate)
		selftest(label .. " no-predicate fallback", #v.flagged > 0, "the lobby body took damage with no predicate installed (fail-open, as designed: " .. describe(v) .. ")")
	end)

	section(label .. " plant: nobody", function()
		StormService.SetEligibility(function()
			return false
		end)
		local v = judge(measure(2.5))
		StormService.SetEligibility(realPredicate)
		selftest(label .. " dead-storm detector", v.liveHits == 0 and v.eligible > 0, "a storm that hurt nobody was reported as such (" .. describe(v) .. ")")
	end)

	-- Everything back the way the match had it.
	StormService.SetEligibility(realPredicate)
end

--------------------------------------------------------------------------------
-- Match 1: battle royale (Start's tick)
--------------------------------------------------------------------------------
MatchService.Start()
say("MatchService started in this VM; waiting for the battle royale to reach InProgress")
if not waitForState("InProgress", 300) then
	fail("battle royale started", "state " .. tostring(MatchService.GetState()) .. " after 300 s")
else
	pass("battle royale started", string.format("mode %s, %d bot records + shaped token enrolled by startMatch", tostring(GameMode.Current().id), #current.records))
	task.wait(3)
	stormBlock("BR/Start")

	-- Ordering, the battle-royale half: a death here IS an elimination, so alive[] must be cleared and
	-- the token must stop being eligible. This is the natural plant for the check in match 2.
	section("BR death clears eligibility", function()
		local shaped = current.shaped
		if not shaped then
			unknown("BR death clears eligibility", "no shaped token")
			return
		end
		local wasAlive = MatchService.IsAlive(shaped)
		shaped.humanoid.Health = 0
		task.wait(1.5)
		local stillAlive = MatchService.IsAlive(shaped)
		selftest("elimination detector", wasAlive and not stillAlive, string.format("IsAlive went %s -> %s after a battle-royale death", tostring(wasAlive), tostring(stillAlive)))
	end)
end

--------------------------------------------------------------------------------
-- Match 2: Team Deathmatch (StartStatic's tick), reached through Results -> Intermission -> Countdown
--------------------------------------------------------------------------------
say("waiting for the state machine to leave match 1 (state now %s)", tostring(MatchService.GetState()))
local left = false
do
	local deadline = os.clock() + 120
	while os.clock() < deadline do
		local s = MatchService.GetState()
		if s == "Results" or s == "Intermission" or s == "Waiting" or s == "Countdown" or s == "Loading" then
			left = true
			break
		end
		task.wait(0.5)
	end
end
if not left then
	-- A shaped death should have ended a bots-only royale (realPlayersAlive() == 0); if not, end it.
	say("match 1 did not end on the death; finishing it by hand")
	GameMode.FinishNow()
end

if not waitForState("InProgress", 300) then
	fail("team deathmatch started", "state " .. tostring(MatchService.GetState()) .. " after 300 s")
else
	local mode = GameMode.Current()
	if mode.id ~= "TeamDeathmatch" then
		unknown("team deathmatch started", "match 2 resolved to " .. tostring(mode.id))
	else
		pass("team deathmatch started", string.format("%d bot records + shaped token enrolled by startMatch", #current.records))
	end
	task.wait(3)
	stormBlock("TDM/StartStatic")

	-- Ordering, the respawn-mode half (condition 2): a token that dies in a respawn mode is STILL
	-- eligible on the next tick. MatchService.eliminate returns to the mode's OnDeath before the line
	-- that clears alive[token]; reorder those lines and this fails.
	section("respawn-mode death keeps eligibility", function()
		local shaped = current.shaped
		if not shaped then
			unknown("respawn-mode death keeps eligibility", "no shaped token")
			return
		end
		if not MatchService.IsAlive(shaped) then
			unknown("respawn-mode death keeps eligibility", "shaped token was not alive before its death")
			return
		end
		shaped.humanoid.Health = 0
		task.wait(1.5)
		if MatchService.IsAlive(shaped) then
			pass("alive[] survives a respawn-mode death", "MatchService.IsAlive(shaped) still true 1.5 s after Health = 0 (real eliminate, real ordering)")
		else
			fail("alive[] survives a respawn-mode death", "IsAlive(shaped) is false: eliminate cleared alive[] before (or instead of) handing the death to the mode")
		end
		-- The respawn: a fresh body for the same token, as LoadCharacter -> OnCharacterAdded would give a
		-- player, registered the same way, standing outside the (exiled) circle.
		local rig2, humanoid2 = makeRig("ProbePlayerShapedRespawn", Vector3.new(200, 60, 200))
		shaped.character, shaped.humanoid = rig2, humanoid2
		Combatants.Register(rig2, shaped)
		exile()
		local before = humanoid2.Health
		task.wait(2.5)
		local lost = before - humanoid2.Health
		if lost > 0 then
			pass("respawned token eligible on the next tick", string.format("new body lost %.0f in 2.5 s at 5 dps", lost))
		else
			fail("respawned token eligible on the next tick", "new body took no storm damage")
		end
	end)

	GameMode.FinishNow()
end

--------------------------------------------------------------------------------
-- The shipped alarm: unwired Start/StartStatic warn; wired ones do not
--------------------------------------------------------------------------------
section("unwired warning", function()
	task.wait(1)
	local realPredicate = StormService.GetEligibility()
	local warns = {}
	local conn = LogService.MessageOut:Connect(function(message, messageType)
		if messageType == Enum.MessageType.MessageWarning and string.find(message, "NO eligibility predicate", 1, true) then
			table.insert(warns, message)
		end
	end)

	StormService.SetEligibility(nil)
	StormService.StartStatic(FAR, 5, 0, "probe")
	task.wait(0.5)
	local afterStatic = #warns
	StormService.Start(880)
	task.wait(0.5)
	local afterStart = #warns
	StormService.Stop()

	StormService.SetEligibility(realPredicate)
	StormService.StartStatic(FAR, 5, 0, "probe")
	task.wait(0.5)
	StormService.Start(880)
	task.wait(0.5)
	StormService.Stop()
	conn:Disconnect()

	selftest("StartStatic warns when unwired", afterStatic == 1, string.format("%d warning(s) from an unwired StartStatic", afterStatic))
	selftest("Start warns when unwired", afterStart - afterStatic == 1, string.format("%d warning(s) from an unwired Start", afterStart - afterStatic))
	if #warns == afterStart then
		pass("wired starts stay quiet", "no warning from StartStatic or Start with the predicate installed")
	else
		fail("wired starts stay quiet", string.format("%d spurious warning(s) with the predicate installed", #warns - afterStart))
	end
end)

--------------------------------------------------------------------------------
for _, model in ipairs(rigs) do
	if model.Parent then
		Combatants.Unregister(model)
		model:Destroy()
	end
end
say("SUMMARY checks=%d failures=%d inconclusive=%d", checks, failures, inconclusive)
say(failures == 0 and (inconclusive == 0 and "RESULT PASS" or "RESULT PASS-WITH-INCONCLUSIVE") or "RESULT FAIL")
