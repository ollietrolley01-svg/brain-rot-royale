-- Task 26: how long a team-mode bot takes to leave its base and reach the middle, per bot life, over REPS
-- real Team Deathmatch matches (the before|after number for "bots spawn with a kit instead of looting").
--
--   runtest -Probe tools/bot_kit_probe.lua -WaitSeconds 1200 -PlaceFile <build>
--
-- Real wiring: this VM's MatchService runs the matches through its own state machine (MinPlayers 0 so a
-- bots-only match starts, the lobby waits cut to 3 s), with VoteService.Resolve pinned to Team Deathmatch
-- on MAPS[rep] so both builds play the same maps. Nothing in BotService is touched: the probe only reads
-- BotService.GetAll() every 0.25 s.
--
-- Per life (a new body = a new life; wall-clock tick(), which is what the bots' own timers read):
--   left     seconds from first seen to more than BaseRadius + 10 studs from its own base
--   middle   seconds to within MIDDLE of the arena's centre (ModeTeams.Arena)
--   baseLoot the first thing it targeted inside its own base in its first 30 s, if any
--   gear     whether it was ever in the gear-up phase (bot.gearUntil) in its first 30 s
-- Only lives first seen in the first BORN_BY seconds of the window count, so each had WINDOW - BORN_BY
-- seconds to get there; one that didn't is printed as "not within N s", never dropped.
-- Lines start "[BOTKIT]".

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TAG = "[BOTKIT]"
local function out(fmt, ...)
	print(TAG .. " " .. string.format(fmt, ...))
end

local MAPS = { "SahurSprings", "TralalaTown", "RotRidge" }
local REPS = #MAPS
local WINDOW, BORN_BY = 150, 50
local MIDDLE = 90

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(6)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local MatchService = require(Modules:WaitForChild("MatchService"))
local GameMode = require(Modules:WaitForChild("GameMode"))
local VoteService = require(Modules:WaitForChild("VoteService"))
local BotService = require(Modules:WaitForChild("BotService"))
local ModeTeams = require(Modules:WaitForChild("ModeTeams"))
local LootService = require(Modules:WaitForChild("LootService"))

MatchConfig.MinPlayers = 0
MatchConfig.LobbyCountdown = 3
MatchConfig.AllReadyCountdown = 3
MatchConfig.Intermission = 3
MatchConfig.IntermissionAllReady = 3
local rep = 1
VoteService.Resolve = function()
	return MAPS[math.min(rep, REPS)], "TeamDeathmatch"
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

-- Timestamps for each stage of a match start, so a stall says where it is.
local t0 = tick()
local function stage(module, name, label)
	local real = module[name]
	module[name] = function(...)
		out("stage %s start at %.1f s", label, tick() - t0)
		local results = table.pack(real(...))
		out("stage %s done at %.1f s", label, tick() - t0)
		return table.unpack(results, 1, results.n)
	end
end
stage(require(Modules:WaitForChild("MapGenerator")), "Build", "map build")
stage(LootService, "Populate", "loot")
stage(require(Modules:WaitForChild("TeamPicker")), "Run", "team picker")
stage(ModeTeams, "Setup", "ModeTeams.Setup")
stage(BotService, "Spawn", "bot spawn")

-- A bots-only match ends at once (MatchService.concludeIfOver: no real player alive), so each match's
-- first batch also enrols ONE player-shaped token (isBot = false, not a Player) through startMatch's
-- real onSpawned, as tools/storm_lobby_probe.lua does: an anchored, invisible rig parked 400 studs over
-- the arena's centre, out of every bot's reach. The bots themselves are BotService's own.
local Combatants = require(Modules:WaitForChild("Combatants"))
-- Combatants.IsPlayer wants a real Player, so the token counts as one ONLY for realPlayersAlive (the
-- "is anyone real still here" test); every other caller still sees a non-player.
local keepAlive = {}
local realIsPlayer = Combatants.IsPlayer
Combatants.IsPlayer = function(token)
	if keepAlive[token] and debug.info(2, "n") == "realPlayersAlive" then
		return true
	end
	return realIsPlayer(token)
end
local realSpawn = BotService.Spawn
BotService.Spawn = function(count, cframeFor, onSpawned, options)
	if count >= 4 and type(onSpawned) == "function" then
		local model = Instance.new("Model")
		model.Name = "BotKitProbeKeepAlive"
		for _, name in ipairs({ "HumanoidRootPart", "Head" }) do
			local part = Instance.new("Part")
			part.Name = name
			part.Size = Vector3.new(2, 2, 1)
			part.Anchored, part.CanCollide, part.CanQuery, part.Transparency = true, false, false, 1
			part.Parent = model
		end
		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth, humanoid.Health = 1e9, 1e9
		humanoid.RequiresNeck, humanoid.BreakJointsOnDeath = false, false
		humanoid.Parent = model
		model.PrimaryPart = model.HumanoidRootPart
		local centre = ModeTeams.Arena() or Vector3.zero
		model.Parent = workspace
		model:PivotTo(CFrame.new(centre + Vector3.new(0, 400, 0)))
		local token = { isBot = false, name = "BotKitProbeKeepAlive", character = model, humanoid = humanoid }
		keepAlive[token] = true
		Combatants.Register(model, token)
		local ok, err = pcall(onSpawned, token, humanoid)
		out("keep-alive token enrolled before a batch of %d (%s)", count, ok and "ok" or tostring(err))
		-- Placement may have moved it to a base pad; keep it in the sky for the whole match.
		task.spawn(function()
			while model.Parent do
				model:PivotTo(CFrame.new(centre + Vector3.new(0, 400, 0)))
				task.wait(1)
			end
		end)
	end
	local spawned = realSpawn(count, cframeFor, onSpawned, options)
	out("batch of %d: %d spawned", count, #spawned)
	return spawned
end
-- Who ends a match: finishMatch clears the bots.
local realClear = BotService.Clear
BotService.Clear = function(...)
	out("BotService.Clear at %.1f s, state %s: %s", tick() - t0, tostring(MatchService.GetState()), debug.traceback("", 2):gsub("\n", " | "))
	return realClear(...)
end
stage(BotService, "Start", "BotService.Start")
task.spawn(function()
	while true do
		task.wait(15)
		out("tick %.0f s: state %s, bots %d alive of %d", tick() - t0, tostring(MatchService.GetState()), BotService.Count(), #BotService.GetAll())
	end
end)

local function waitForState(target, seconds)
	local deadline = tick() + seconds
	while tick() < deadline do
		if MatchService.GetState() == target then
			return true
		end
		task.wait(0.5)
	end
	return false
end

local function median(list)
	if #list == 0 then
		return 0 / 0
	end
	table.sort(list)
	local mid = (#list + 1) / 2
	return (list[math.floor(mid)] + list[math.ceil(mid)]) / 2
end

local totals = { lives = 0, left = {}, middle = {}, notLeft = 0, notMiddle = 0, baseLoot = 0, gear = 0 }
MatchService.Start()
for r = 1, REPS do
	rep = r
	if not waitForState("InProgress", 400) then
		out("rep %d: FAIL no match reached InProgress (state %s)", r, tostring(MatchService.GetState()))
		break
	end
	local mode = GameMode.Current()
	local centre, radius = ModeTeams.Arena()
	local baseRadius = (LootService.BaseRadius or 85) + 10
	out("rep %d: map %s, mode %s, arena radius %.0f, base 1 %.0f studs from the centre, base 2 %.0f", r, MAPS[r],
		tostring(mode and mode.id), radius or -1, flat(ModeTeams.BaseOf(1) - centre), flat(ModeTeams.BaseOf(2) - centre))

	local lives, order = {}, {}
	local start = tick()
	while tick() - start < WINDOW do
		local now = tick()
		for _, bot in ipairs(BotService.GetAll()) do
			local character = bot.character
			local root = character and character.Parent and character:FindFirstChild("HumanoidRootPart")
			if root and bot.humanoid and bot.humanoid.Health > 0 then
				local life = lives[character]
				if not life then
					local state = BotService.ModeState(bot)
					local team = (state and state.team) or ModeTeams.TeamOf(bot)
					life = { name = bot.name, born = now - start, at = now, team = team, base = team and ModeTeams.BaseOf(team) }
					lives[character] = life
					table.insert(order, life)
				end
				local age = now - life.at
				local p = root.Position
				if life.base and not life.left and flat(p - life.base) > baseRadius then
					life.left = age
				end
				if not life.middle and flat(p - centre) < MIDDLE then
					life.middle = age
				end
				if age < 30 then
					local target = bot.lootTarget
					if not life.baseLoot and life.base and target and target.Parent and flat(target.Position - life.base) <= baseRadius then
						life.baseLoot = target.Name
					end
					if bot.gearUntil and now < bot.gearUntil then
						life.gear = true
					end
				end
			end
		end
		task.wait(0.25)
	end

	local left, middle, counted, notLeft, notMiddle, baseLoot, gear = {}, {}, 0, 0, 0, 0, 0
	local limit = WINDOW - BORN_BY
	for _, life in ipairs(order) do
		if life.born <= BORN_BY then
			counted += 1
			if life.left and life.left <= limit then
				table.insert(left, life.left)
				table.insert(totals.left, life.left)
			else
				notLeft += 1
			end
			if life.middle and life.middle <= limit then
				table.insert(middle, life.middle)
				table.insert(totals.middle, life.middle)
			else
				notMiddle += 1
			end
			baseLoot += life.baseLoot and 1 or 0
			gear += life.gear and 1 or 0
			out("  life %-12s team %s born %5.1f  left %6s  middle %6s  baseLoot %-12s gear %s", life.name, tostring(life.team), life.born,
				life.left and string.format("%.1f", life.left) or "-", life.middle and string.format("%.1f", life.middle) or "-",
				life.baseLoot or "-", life.gear and "yes" or "no")
		end
	end
	out("rep %d: %d lives counted; left base: median %.1f s (%d did not within %d s); middle: median %.1f s (%d did not within %d s); "
		.. "targeted base loot in the first 30 s: %d; in the gear-up phase: %d",
		r, counted, median(left), notLeft, limit, median(middle), notMiddle, limit, baseLoot, gear)
	totals.lives += counted
	totals.notLeft += notLeft
	totals.notMiddle += notMiddle
	totals.baseLoot += baseLoot
	totals.gear += gear

	if r < REPS then
		rep = r + 1
		GameMode.FinishNow()
		-- Out of InProgress before waiting for the next one.
		local deadline = tick() + 60
		while MatchService.GetState() == "InProgress" and tick() < deadline do
			task.wait(0.5)
		end
	end
end
out("TOTAL over %d reps: %d lives; left base: median %.1f s (%d did not); middle: median %.1f s (%d did not); "
	.. "targeted base loot in the first 30 s: %d; in the gear-up phase: %d",
	REPS, totals.lives, median(totals.left), totals.notLeft, median(totals.middle), totals.notMiddle, totals.baseLoot, totals.gear)
pcall(GameMode.FinishNow)
out("done")
