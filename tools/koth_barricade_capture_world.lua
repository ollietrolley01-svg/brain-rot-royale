-- The objective half of tools/koth_barricade_proof_check.py (#114 b: "two objectives on KOTH").
-- Plain Lua (lupa). Runs the REAL GameMode.lua (its match driver: the 0.25 s objective tick, the
-- once-a-second score, the score target and the time limit), ModeKingOfTheHill.lua, and the shipped
-- mode numbers in GameModes.lua, ObjectiveZone.lua and MatchConfig.lua. task.spawn / task.wait /
-- task.delay are a scheduler this file steps through time, so the loops that run are the shipped ones.
--
-- Mocked: the players and bots (a table with a root position the scenes move by hand), ModeTeams (the
-- teams, and the battleground's two objective points), the loot, storm, rewards and remotes. Parts are
-- inert: this half measures who owns what and the score, never a picture.

local sources = ...
-- Plain Lua's loader (the modules are compiled with their own `script`).
local compileChunk = rawget(_G, "load")
local W = { failures = {}, warns = {} }

table.clone = function(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return setmetatable(c, getmetatable(t)) end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
table.find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
math.clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end
function warn(msg) table.insert(W.warns, tostring(msg)) end

-- The clock and the scheduler: task.wait parks a coroutine until the clock reaches its wake time.
local clock = 0
local sleepers = {}
local function resumeSafely(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then table.insert(W.failures, "task error: " .. tostring(err) .. "\n" .. debug.traceback(co)) end
end
task = {
	spawn = function(fn, ...)
		local co = coroutine.create(fn)
		resumeSafely(co, ...)
		return co
	end,
	wait = function(t)
		local co = coroutine.running()
		table.insert(sleepers, { co = co, at = clock + (t or 0) })
		coroutine.yield()
		return t
	end,
	delay = function(t, fn, ...)
		local args = table.pack(...)
		return task.spawn(function() task.wait(t); fn(table.unpack(args, 1, args.n)) end)
	end,
}
task.defer = task.spawn
-- Wakes every sleeper due by `seconds` from now, in time order, and calls `each` after each wake-up
-- that moved the clock (the scenes sample the score there).
function W.advance(seconds)
	local target = clock + seconds
	while true do
		local best, index = nil, nil
		for i, s in ipairs(sleepers) do
			if s.at <= target + 1e-9 and (not best or s.at < best.at) then best, index = s, i end
		end
		if not best then break end
		table.remove(sleepers, index)
		clock = math.max(clock, best.at)
		resumeSafely(best.co)
	end
	clock = target
end
function W.now() return clock end
DateTime = { now = function() return { UnixTimestampMillis = math.floor(clock * 1000 + 0.5) } end }
os.clock = function() return clock end

-- Datatypes. Vector3 does arithmetic; everything a part is drawn with is inert.
local V3 = {}
V3.__index = function(self, key)
	if key == "Magnitude" then return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2) end
	return nil
end
local function vec(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3) end
V3.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b) if type(a) == "number" then a, b = b, a end return vec(a.X * b, a.Y * b, a.Z * b) end
Vector3 = { new = vec }
W.vec = vec
local anyMT = {}
anyMT.__index = function() return function() return setmetatable({}, anyMT) end end
anyMT.__mul = function(a) return a end
anyMT.__add = function(a) return a end
local function any() return setmetatable({}, anyMT) end
CFrame = { new = any, Angles = any, lookAt = any }
Color3 = { fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end, new = function(r, g, b) return { R = r, G = g, B = b } end }
UDim2 = { fromOffset = any, fromScale = any, new = any }
UDim = { new = any }
RaycastParams = { new = function() return {} end }
Random = nil
Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function(_, k) return k end }) end })
local instMT = {}
instMT.__index = function(self, key)
	return rawget(self, "__attrs") and instMT.methods[key] or nil
end
instMT.methods = {
	SetAttribute = function(self, k, v) self.__attrs[k] = v end,
	GetAttribute = function(self, k) return self.__attrs[k] end,
	Destroy = function(self) self.Parent = nil end,
}
Instance = { new = function(class) return setmetatable({ ClassName = class, __attrs = {} }, instMT) end }
workspace = { Terrain = {}, Raycast = function() return nil end }

-- Combatants. A token is a table with a Character whose root the scenes move.
local function character(position)
	local root = { Position = position }
	local humanoid = { Health = 100 }
	local ch = { Parent = true, root = root, humanoid = humanoid }
	function ch:FindFirstChildOfClass(class) return class == "Humanoid" and humanoid or nil end
	function ch:FindFirstChild(name) return name == "HumanoidRootPart" and root or nil end
	return ch
end
W.teams = {}
local tokens = {}
function W.token(name, team, position)
	local t = { kind = "bot", Name = name }
	t.Character = character(position or vec(0, 0, 900))
	W.teams[t] = team
	table.insert(tokens, t)
	return t
end
function W.move(token, position) token.Character.root.Position = position end

-- Mocked modules.
local mocks = {}
local BATTLEGROUND = nil
function W.setBattleground(points) BATTLEGROUND = points and { objectives = points } or nil end
W.bases = { vec(-400, 0, 0), vec(400, 0, 0) }
W.arena = 600
mocks.ModeTeams = {
	TeamOf = function(t) return W.teams[t] end,
	IsDowned = function(t) return type(t) == "table" and t.downed == true end,
	MarkDown = function(t) t.downed = true end,
	Setup = function() return vec(0, 0, 0), W.arena end,
	Arena = function() return vec(0, 0, 0), W.arena end,
	Battleground = function() return BATTLEGROUND end,
	BaseOf = function(team) return W.bases[team] end,
	BaseLootSpots = function() return {} end,
	RefusePad = function() return false end,
	Teardown = function() end,
	Assign = function(t) W.teams[t] = W.teams[t] or 1; return W.teams[t] end,
	AssignTo = function(t, team) W.teams[t] = team end,
	Forget = function() end,
	GroundNear = function() return nil end,
	RollGreenWeapon = function() return "GreenGun" end,
	DamageVeto = function() return false end,
	IsHostile = function() return true end,
	BreakProtection = function() end,
	PlacedTolerance = 150,
}
mocks.Combatants = {
	IsPlayer = function() return false end,
	IsBot = function(t) return type(t) == "table" and t.kind == "bot" end,
	GetName = function(t) return type(t) == "table" and t.Name or "?" end,
	GetUserId = function() return 0 end,
	GetRoot = function(t) return type(t) == "table" and t.Character and t.Character.root or nil end,
	All = function()
		local all = {}
		for token in pairs(W.teams) do
			if token.Character then all[token.Character] = token end
		end
		return all
	end,
	Unregister = function() end,
}
mocks.Remotes = { Event = function() return { FireAllClients = function() end, FireClient = function() end } end }
mocks.ProgressionData = { Playtime = { MoveStuds = 4 } }
mocks.BotService = { Spawn = function() end, Forget = function() return true end, Clear = function() end }
mocks.CombatService = { OnDamage = function() end, ForgetToken = function() end }
mocks.LootService = { CountNear = function() return {} end, BaseStock = {}, BaseRadius = 85, SeedAt = function() end }
mocks.StormService = { Stop = function() end, Start = function() end, StartStatic = function() end }
mocks.StateSync = { Notify = function() end, Push = function() end }
mocks.QuestService = { Progress = function() end }
mocks.RewardService = {
	TeamPerformanceValue = function() return 0 end,
	TeamBreakdown = function() return {}, 0, 0 end,
	AwardTeamResult = function() return {} end,
	AwardPlacement = function() return {} end,
}
mocks.ZFight = { FixTolerance = 0.055 }

local loaded = {}
-- A folder whose children are module markers (and folders: Shared:WaitForChild("Rarity") chains).
local function folder(name)
	return { __module = name, WaitForChild = function(_, child) return folder(child) end }
end
local function load_(name)
	if loaded[name] ~= nil then return loaded[name] end
	if mocks[name] then loaded[name] = mocks[name]; return mocks[name] end
	local source = sources[name]
	if not source then error("no module " .. name) end
	local env = setmetatable({ script = { Parent = folder() } }, { __index = _G })
	local chunk, err = compileChunk(source, "@" .. name, "t", env)
	if not chunk then error("compile " .. name .. ": " .. tostring(err)) end
	loaded[name] = chunk()
	return loaded[name]
end
require = function(marker) return load_(marker.__module) end
local servicesByName = {
	Players = { PlayerRemoving = { Connect = function() end }, GetPlayers = function() return {} end },
	RunService = { Heartbeat = {} },
	ReplicatedStorage = { WaitForChild = function() return folder() end },
}
game = { GetService = function(_, name) return servicesByName[name] end }

W.GameModes = load_("GameModes")
W.ObjectiveZone = load_("ObjectiveZone")
W.KOTH = load_("ModeKingOfTheHill")
W.GameMode = load_("GameMode")
W.BotService = mocks.BotService
W.finishes = 0
W.GameMode.Bind({
	Finish = function()
		W.finishes = W.finishes + 1
		W.finishedAt = clock - W.startedAt
	end,
	IsParticipant = function() return false end,
})

-- Starts an Objective Capture match the way MatchService does: resolve the voted mode, start its world.
function W.start(mapInfo)
	for t in pairs(W.teams) do W.teams[t] = nil end
	W.finishes, W.finishedAt, W.startedAt = 0, nil, clock
	W.GameMode.Resolve(1, "KingOfTheHill")
	local mode = W.GameMode.Current()
	mode.StartWorld(mapInfo or { radius = 900 })
	return mode
end
function W.stop()
	W.GameMode.Current().StopWorld()
	-- Let the stopped loops notice and end.
	W.advance(1)
end

--------------------------------------------------------------------------------
-- The scenes
--------------------------------------------------------------------------------
-- Every check is an invariant the mode must keep for good, measured on the score and the owners the
-- shipped code produces.
function W.runScenes(battlegroundPoints)
	local out = { problems = {}, lines = {}, counts = { checks = 0, ticks = 0 } }
	local function check(ok, tag, text)
		out.counts.checks = out.counts.checks + 1
		if not ok then table.insert(out.problems, string.format("[%s] %s", tag, text)) end
	end
	local function line(text) table.insert(out.lines, text) end
	local GM, KOTH, OZ = W.GameMode, W.KOTH, W.ObjectiveZone
	local def = W.GameModes.Modes.KingOfTheHill
	-- How far below the centre still counts: Below, plus DigDepth where the tree has it (the lag/bug sweep
	-- adds the crater allowance).
	local R, H, BELOW = OZ.Radius(def), OZ.Height(def), OZ.Below + (OZ.DigDepth or 0)
	local TARGET, LIMIT = def.scoreTarget, def.timeLimit
	line(string.format("mode: %s, radius %d, height %d (below %d), score target %d, time limit %d s",
		tostring(def.name), R, H, BELOW, TARGET, LIMIT))
	local A, B = battlegroundPoints[1], battlegroundPoints[2]
	local function on(point, dx, dy, dz) return vec(point.X + (dx or 0), point.Y + (dy or 3), point.Z + (dz or 0)) end
	local away1, away2 = vec(-400, 0, 0), vec(400, 0, 0)
	local function owners()
		local list = KOTH.Objectives()
		return list[1] and list[1].owner, list[2] and list[2].owner, list[1] and list[1].status, list[2] and list[2].status
	end
	local function score() return GM.Scores() end

	-- 1. Two objectives, on the battleground's two points (floor heights kept).
	W.setBattleground({ A, B })
	W.start()
	local positions = KOTH.Positions()
	check(KOTH.SiteCount() == 2, "two", "battleground match: " .. KOTH.SiteCount() .. " objectives, want 2")
	check(positions[1] and positions[2] and (positions[1] - A).Magnitude < 1e-6 and (positions[2] - B).Magnitude < 1e-6,
		"two", "the objectives are not the battleground's two points")
	line(string.format("battleground: %d objectives, A (%.1f, %.1f, %.1f) B (%.1f, %.1f, %.1f), %.1f apart",
		KOTH.SiteCount(), A.X, A.Y, A.Z, B.X, B.Y, B.Z, (vec(A.X, 0, A.Z) - vec(B.X, 0, B.Z)).Magnitude))

	-- 2. Capture, hold, lose, contest, on the shipped 0.25 s tick and the once-a-second score.
	local p1 = W.token("Red1", 1, away1)
	local p2 = W.token("Blue1", 2, away2)
	W.move(p1, on(A))
	W.advance(0.25)
	local a = owners()
	check(a == 1, "capture", "team 1 alone on A for one tick: A's owner is " .. tostring(a))
	W.advance(9.75)
	local s1, s2 = score()
	check(s1 == 10 and s2 == 0, "score", string.format("A held 10 s: score %d-%d, want 10-0", s1, s2))
	line(string.format("t=10  team 1 on A alone: A=%s, score %d-%d", tostring(a), s1, s2))
	W.move(p1, away1)
	W.advance(10)
	a = owners()
	s1, s2 = score()
	check(a == 1, "hold", "A stays team 1's after they walk off: owner " .. tostring(a))
	check(s1 == 20, "hold", "an owned objective scores with nobody on it: " .. s1 .. " after 20 s, want 20")
	line(string.format("t=20  nobody on A: A=%s, score %d-%d", tostring(a), s1, s2))
	W.move(p2, on(A, R * 0.5, 3, 0))
	W.advance(0.25)
	a = owners()
	check(a == 2, "capture", "team 2 alone on A takes it back: owner " .. tostring(a))
	W.advance(4.75)
	W.move(p1, on(A, -R * 0.5, 3, 0))
	local before1, before2 = score()
	W.advance(5)
	local owner, _, status = owners()
	s1, s2 = score()
	check(owner == 2 and status == "Contested", "contest", string.format("both sides on A: owner %s status %s, want 2 Contested", tostring(owner), tostring(status)))
	check(s1 == before1, "contest", "team 1 scored on an objective it does not own while contesting")
	line(string.format("t=30  both on A: owner %s, %s; score %d-%d (team 2 scored %d while contested)",
		tostring(owner), tostring(status), s1, s2, s2 - before2))
	-- Dead and downed bodies hold nothing.
	p2.Character.humanoid.Health = 0
	W.advance(0.25)
	a = owners()
	check(a == 1, "alive", "team 2's body lies dead on A: team 1 alone should take it, owner " .. tostring(a))
	p2.Character.humanoid.Health = 100
	W.move(p2, away2)
	p1.downed = true
	W.move(p2, on(A))
	W.advance(0.25)
	a = owners()
	check(a == 2, "alive", "a downed team 1 body does not contest: owner " .. tostring(a))
	p1.downed = nil
	W.move(p1, away1)
	W.move(p2, away2)
	W.stop()

	-- 3. The ring's edge, with the real ObjectiveZone numbers: in by half a stud counts, out by half does not.
	local edges = {
		{ "inside the radius", on(A, R - 0.5, 3, 0), true },
		{ "outside the radius", on(A, R + 0.5, 3, 0), false },
		{ "diagonal inside", on(A, (R - 0.5) / math.sqrt(2), 3, (R - 0.5) / math.sqrt(2)), true },
		{ "above the height", on(A, 0, H + 1, 0), false },
		{ "below the floor band", on(A, 0, -(BELOW + 1), 0), false },
	}
	local right = 0
	for _, edge in ipairs(edges) do
		W.start()
		W.token("Edge", 1, edge[2])
		W.advance(0.25)
		local got = owners() == 1
		right = right + (got == edge[3] and 1 or 0)
		check(got == edge[3], "edge", string.format("%s: captured %s, want %s", edge[1], tostring(got), tostring(edge[3])))
		W.stop()
	end
	line(string.format("edges: %d of %d points (radius +-0.5, a diagonal, above %d, below %d) answered as the ring says",
		right, #edges, H, BELOW))

	-- 4. Rates and the win: holding both scores twice as fast, and the score target ends the match.
	for _, case in ipairs({ { "both", 2 }, { "A only", 1 } }) do
		W.start()
		local holders = { W.token("HoldA", 1, on(A)) }
		if case[2] == 2 then table.insert(holders, W.token("HoldB", 1, on(B))) end
		W.advance(10)
		local ten = score()
		check(ten == 10 * case[2], "rate", string.format("%s held 10 s: %d points, want %d", case[1], ten, 10 * case[2]))
		local want = TARGET / case[2]
		W.advance(want + 30 - 10)
		local f1, f2 = score()
		check(W.finishes == 1, "win", string.format("%s: the match finished %d times, want once", case[1], W.finishes))
		check(W.finishedAt and math.abs(W.finishedAt - want) < 1e-6, "win", string.format("%s: finished at %s s, want %d", case[1], tostring(W.finishedAt), want))
		check(f1 == TARGET and f2 == 0, "win", string.format("%s: final score %d-%d, want %d-0 (nothing after the win)", case[1], f1, f2, TARGET))
		line(string.format("win: team 1 holding %s scores %d in 10 s; reaches %d and finishes at t=%s s (limit %d); final %d-%d",
			case[1], ten, TARGET, tostring(W.finishedAt), LIMIT, f1, f2))
		W.stop()
	end

	-- 5. Nobody takes anything: the time limit ends it.
	W.start()
	W.token("Idle", 1, away1)
	W.advance(LIMIT + 5)
	local i1, i2 = score()
	check(W.finishes == 1 and W.finishedAt and math.abs(W.finishedAt - LIMIT) <= 0.25 + 1e-6, "limit",
		string.format("no captures: finished %d times at %s, want once at %d", W.finishes, tostring(W.finishedAt), LIMIT))
	line(string.format("limit: nobody captures; finished at t=%s s, %d-%d", tostring(W.finishedAt), i1, i2))
	W.stop()

	-- 6. Bots get the same kit, through the SpawnLoadout GameMode hands BotService.
	W.start()
	local structures = { RotBarricade = true, PopupBunker = true, BrainrotFortress = true }
	local botKits, badBot, shield = 0, nil, nil
	for n = 1, 60 do
		local humanoid = { attrs = {} }
		function humanoid:SetAttribute(k, v) self.attrs[k] = v end
		local ok, gun, kit = pcall(W.BotService.SpawnLoadout, {}, humanoid)
		local found = 0
		for _, entry in ipairs(ok and kit or {}) do
			if structures[entry.id] and entry.count >= 1 then found = found + 1 end
		end
		shield = humanoid.attrs.Shield
		if found == 1 then botKits = botKits + 1 else badBot = badBot or string.format("roll %d: %d structures (%s)", n, found, tostring(ok and "" or gun)) end
	end
	check(botKits == 60, "bots", "a bot's kit has exactly one pop-up structure: " .. botKits .. " of 60 (" .. tostring(badBot) .. ")")
	line(string.format("bots: %d of 60 rolled bot kits carry one pop-up structure; spawn shield %s", botKits, tostring(shield)))
	W.stop()

	for _, msg in ipairs(W.failures) do table.insert(out.problems, "[error] " .. msg) end
	for _, msg in ipairs(W.warns) do table.insert(out.problems, "[warn] " .. msg) end
	return out
end

-- The open-arena fallback (no battleground standing): how far apart the two objectives land over seeds.
function W.fallback(arena, seeds, landmarks)
	local gaps = {}
	W.arena = arena
	W.setBattleground(nil)
	for seed = 1, seeds do
		math.randomseed(seed)
		W.start({ radius = 900, landmarks = landmarks })
		local p = W.KOTH.Positions()
		local gap = (#p == 2) and (vec(p[1].X, 0, p[1].Z) - vec(p[2].X, 0, p[2].Z)).Magnitude or -1
		table.insert(gaps, { count = #p, gap = gap })
		W.stop()
	end
	W.arena = 600
	return gaps
end
return W
