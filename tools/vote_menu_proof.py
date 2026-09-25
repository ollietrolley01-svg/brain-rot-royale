"""#107 proof: does anything put the vote screen, its reveal, the drop picker or the team picker over a match?

    python3 tools/vote_menu_proof.py [root]            the proof run (exit 0 = invariants hold, every plant caught)
    python3 tools/vote_menu_proof.py [root] --quick    skips the throw sweep and the reorder/join variants

WHAT RUNS. Everything below is the REAL source, loaded under lupa with mocks for the engine:

  server  ServerScriptService/Modules/VoteService.lua and TeamPicker.lua whole (with the real
          Shared/GameModes, Rarity, MatchConfig, TeamPickerRules), and these pieces cut out of
          MatchService.lua by their own text: isReady, readyPlayers, countKeys, broadcast, SetReady,
          IsSpectating, LeaveSpectate, startMatch (whole), the body of Start's 1 s loop (whole, including
          the failed-start fallback), and the Results -> Intermission step inside finishMatch. Bootstrap's
          join-time vote re-broadcast is cut out of Bootstrap.server.lua. Everything else those pieces
          call (LootService, BotService, MapGenerator, ...) is an auto-stub that returns nil.
  client  StarterPlayerScripts/VoteDropClient.client.lua and TeamPickerClient.client.lua whole, with the
          real Shared/VoteReveal, VoteCursor, GameModes, TeamPickerRules and StarterPlayerScripts/
          MenuOpenClaims. The three screens are mocks that record visibility: VoteScreen:Render uses the
          real VoteCursor.Screen (the one line VoteScreen.lua:217 uses), DropPicker:SetVisible and
          TeamPickerScreen:Show/Hide set the same flags the real ones do. A source-shape guard fails the run
          if those lines stop being what the mocks copy.

THE SCENARIO. Players A and B ready up on a fresh server, vote Battle Royale, play it (B dies, leaves
spectating, re-readies and votes mid-match; J joins mid-match; L, never in the match, readies mid-match),
the match ends, the break opens the next vote, everyone votes Team Deathmatch, the team picker runs, A
dies and respawns, K joins mid-match, the match ends and the next break's vote opens. Every remote the
server fires and every Ready attribute it sets goes on a wire with the server's state at that moment.
Each client (A, B, L, J, K) replays its share of the wire.

INVARIANTS (checked at every client moment: every delivery and every client timer; the server's truth is
the state when the newest message this client has received was sent):
  V1  the vote screen (either face) is never drawn while the match is InProgress or Results   (#107)
  V2  the drop picker is only drawn in Loading, for a participant
  V3  the team picker is only drawn in Loading, for a participant
and on the server, at every send and every loop tick:
  S1  the vote is never open while the match is InProgress or Results
  S2  dropSelect, S3 the team picker, S4 teamSelect: only ever set in Loading
  S5  no VoteChanged or TeamPickerChanged is fired while the match is InProgress or Results

VARIANTS. (a) in-order delivery; (b) every adjacent pair of messages on two different channels swapped
(Roblox only documents ordering WITHIN one RemoteEvent); (c) a client that joins at every point of A's
stream; (d) HOSTILE: at every moment the server is InProgress/Results, the client is also handed a late
copy of an open vote snapshot, a fresh open->closed-with-winner transition, and an open team-picker
snapshot. (d) is the client's own guard on its own: the server never sends those in a match.
THROW SWEEP. Every stubbed call and every remote send made inside startMatch is an injection point; the
scenario is re-run once per point with that one call throwing, which is how a failed start happens.

PLANTED FAULTS (permanent, aimed at the invariants, applied to the real source in memory): each must
produce at least one V or S violation or the run fails. FINDING lines (the throw sweep, the stuck-flag probe)
report what the real code does; they do not fail the run. `--trace N` prints the timeline of throw point N.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("vote_menu_proof: needs lupa (pip install lupa)")

MATCH = "ServerScriptService/Modules/MatchService.lua"
VOTE = "ServerScriptService/Modules/VoteService.lua"
PICKER = "ServerScriptService/Modules/TeamPicker.lua"
BOOT = "ServerScriptService/Bootstrap.server.lua"
SHARED = "ReplicatedStorage/Shared/"
CLIENT = "StarterPlayerScripts/"
FILES = [MATCH, VOTE, PICKER, BOOT,
         SHARED + "MatchConfig.lua", SHARED + "GameModes.lua", SHARED + "Rarity.lua", SHARED + "TeamPickerRules.lua",
         SHARED + "VoteReveal.lua", SHARED + "VoteCursor.lua",
         CLIENT + "VoteDropClient.client.lua", CLIENT + "TeamPickerClient.client.lua", CLIENT + "MenuOpenClaims.lua",
         CLIENT + "VoteScreen.lua", CLIENT + "DropPicker.lua", CLIENT + "TeamPickerScreen.lua"]


def luau_to_lua(source):
    # x += y  ->  x = x + (y); the only Luau-only syntax these files use.
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/]|\.\.)= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def between(src, start, stop, include_start=True):
    a = src.index(start)
    b = src.index(stop, a + len(start))
    return src[a if include_start else a + len(start):b]


def cut_function(src, header):
    """A top-level function from its header line to the first `end` in column 0."""
    body = between(src, header, "\nend\n") + "\nend\n"
    return body


def pieces(files):
    """The real code, cut out of MatchService and Bootstrap. Raises ValueError if a shape moved."""
    m = files[MATCH]
    out = {}
    for name, header in [("isReady", "local function isReady(player)"),
                         ("readyPlayers", "local function readyPlayers()"),
                         ("countKeys", "local function countKeys(map)"),
                         ("broadcast", "local function broadcast()"),
                         ("SetReady", "function MatchService.SetReady(player, value)"),
                         ("IsSpectating", "function MatchService.IsSpectating(player)"),
                         ("LeaveSpectate", "function MatchService.LeaveSpectate(player)"),
                         ("startMatch", "local function startMatch()")]:
        text = cut_function(m, header)
        # One environment holds every piece, so a chunk-local function becomes a global of it.
        text = text.replace("local function startMatch()", "function startMatchReal()", 1)
        text = re.sub(r"^local function (\w+)\(", r"function \1(", text, count=1)
        out[name] = luau_to_lua(text)
    start = between(m, "function MatchService.Start()", "\nreturn MatchService")
    out["loop"] = luau_to_lua(between(start, "\t\t\ttask.wait(1)\n", "\n\t\tend\n\tend)\nend", include_start=False))
    finish = between(m, "local function finishMatch()", "\nend\n")
    out["break"] = luau_to_lua(between(finish, "task.delay(MatchConfig.ResultsDuration, function()\n", "\n\tend)",
                                       include_start=False))
    boot = files[BOOT]
    join = between(boot, "\t-- Re-broadcast so someone joining mid-countdown", "\tShowcaseService.Refresh()")
    out["join"] = luau_to_lua(join)
    return out


# The engine, the auto-stubs, the real server modules and the scenario. Returns W (the wire and the log).
SERVER = r"""
local S, P, opts = ...
local W = { now = 0, seq = 0, wire = {}, actions = {}, nAction = 0, points = {}, pointCount = 0,
	inStart = false, sviol = {}, snCount = 0, warnings = {}, attempts = 0, completed = 0, loopTicks = 0,
	failedStarts = 0, events = {} }
local function note(s) table.insert(W.events, string.format("%7.2f %s", W.now, s)) end

-- Virtual time. Actions run in (time, insertion) order; task.wait advances through them.
local function schedule(at, fn)
	W.nAction = W.nAction + 1
	table.insert(W.actions, { at = at, fn = fn, n = W.nAction })
end
local function advanceTo(target)
	while true do
		local best = nil
		for i, a in ipairs(W.actions) do
			if a.at <= target and (best == nil or a.at < W.actions[best].at
				or (a.at == W.actions[best].at and a.n < W.actions[best].n)) then
				best = i
			end
		end
		if not best then break end
		local a = table.remove(W.actions, best)
		if a.at > W.now then W.now = a.at end
		a.fn()
	end
	if target > W.now then W.now = target end
end
local function wait(s) advanceTo(W.now + (s or 0.03)); return s or 0.03 end
W.advanceTo = advanceTo

-- Injection points: every stubbed call and every remote send made inside startMatch.
local function point(label)
	if not W.inStart then return end
	W.pointCount = W.pointCount + 1
	table.insert(W.points, label)
	if opts.throwAt == W.pointCount then
		W.thrown = label
		note("PLANTED THROW at point " .. W.pointCount .. ": " .. label)
		error("planted throw at point " .. W.pointCount .. " (" .. label .. ")", 0)
	end
end

local function deepcopy(v, seen)
	if type(v) ~= "table" then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local c = {}
	seen[v] = c
	for k, x in pairs(v) do c[deepcopy(k, seen)] = deepcopy(x, seen) end
	return c
end
W.deepcopy = deepcopy

local function signal()
	local s = { handlers = {} }
	function s:Connect(fn) table.insert(self.handlers, fn) return { Disconnect = function() end } end
	function s:Fire(...) for _, f in ipairs(self.handlers) do f(...) end end
	return s
end

local M -- the MatchService environment, filled below
local Vote, Picker

local MATCH_STATES = { InProgress = true, Results = true }
local function truth()
	local t = { state = M.state, dropSelect = M.dropSelect == true, teamSelect = M.teamSelect == true,
		voteOpen = Vote and Vote.IsOpen() or false, pickerOpen = Picker and Picker.IsOpen() or false,
		participants = {}, mode = M.currentMode and M.currentMode.id }
	for p in pairs(M.participants or {}) do
		if type(p) == "table" and p.Name then t.participants[p.Name] = true end
	end
	return t
end
local function sviolate(kind, detail)
	W.snCount = W.snCount + 1
	if #W.sviol < 12 then
		table.insert(W.sviol, string.format("%s t=%.2f state=%s: %s", kind, W.now, tostring(M.state), detail))
	end
end
local function serverInvariants(where)
	local st = M.state
	if Vote and Vote.IsOpen() and MATCH_STATES[st] then sviolate("S1", "the vote is open (" .. where .. ")") end
	if M.dropSelect and st ~= "Loading" then sviolate("S2", "dropSelect is set (" .. where .. ")") end
	if Picker and Picker.IsOpen() and st ~= "Loading" then sviolate("S3", "the team picker is open (" .. where .. ")") end
	if M.teamSelect and st ~= "Loading" then sviolate("S4", "teamSelect is set (" .. where .. ")") end
end
W.serverInvariants = serverInvariants

local onSend -- the scenario's reactions to what the server says
local function record(remote, toName, payload)
	W.seq = W.seq + 1
	local entry = { seq = W.seq, t = W.now, remote = remote, to = toName, payload = deepcopy(payload), truth = truth() }
	table.insert(W.wire, entry)
	return entry
end
local function send(remote, toName, payload)
	point(remote .. (toName and ":FireClient" or ":FireAllClients"))
	local entry = record(remote, toName, payload)
	if (remote == "VoteChanged" or remote == "TeamPickerChanged") and MATCH_STATES[M.state] then
		sviolate("S5", remote .. " fired during a match" .. (toName and (" to " .. toName) or ""))
	end
	serverInvariants("send " .. remote)
	if onSend then onSend(entry) end
end

-- Players. SetAttribute fires its changed signal at once (VoteService.watchReady listens); Ready also
-- goes on the wire, to its owner, as an attribute replication.
local Players = { list = {}, PlayerAdded = signal(), PlayerRemoving = signal() }
function Players:GetPlayers() local c = {} for i, p in ipairs(self.list) do c[i] = p end return c end
local function newPlayer(name, id)
	local p = { Name = name, DisplayName = name, UserId = id, Parent = true, attrs = {}, sigs = {} }
	function p:GetAttribute(k) return self.attrs[k] end
	function p:SetAttribute(k, v)
		self.attrs[k] = v
		if k == "Ready" then record("attr:Ready", self.Name, v) end
		for _, f in ipairs(self.sigs[k] or {}) do f() end
	end
	function p:GetAttributeChangedSignal(k)
		local owner = self
		return { Connect = function(_, fn)
			owner.sigs[k] = owner.sigs[k] or {}
			table.insert(owner.sigs[k], fn)
			return { Disconnect = function() end }
		end }
	end
	function p:LoadCharacter() end
	return p
end

-- Shared modules, real.
local modules = {}
local function marker(name)
	return { __module = name, WaitForChild = function(_, n) return marker(n) end, FindFirstChild = function(_, n) return marker(n) end }
end
local function folder() return { WaitForChild = function(_, n) return marker(n) end, FindFirstChild = function(_, n) return marker(n) end } end
local function color(r, g, b) return { R = r, G = g, B = b } end
local Color3 = { fromRGB = function(r, g, b) return color(r / 255, g / 255, b / 255) end, new = color }
local rngState = 12345
local function rnd(a, b)
	rngState = (rngState * 1103515245 + 12345) % 2147483648
	return a + (rngState % (b - a + 1))
end
local base = setmetatable({
	table = setmetatable({ clear = function(t) for k in pairs(t) do t[k] = nil end end,
		clone = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end }, { __index = table }),
	math = setmetatable({ clamp = function(x, a, b) return math.max(a, math.min(b, x)) end,
		random = function(a, b) if a then return rnd(a, b or a) end return 0.5 end }, { __index = math }),
	Color3 = Color3,
	Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z } end },
	typeof = function(v) return type(v) end,
	warn = function(...) table.insert(W.warnings, table.concat({ tostring((...)) }, " ")) end,
	tick = function() return W.now end,
	os = setmetatable({ clock = function() return W.now end }, { __index = os }),
	DateTime = { now = function() return { UnixTimestampMillis = W.now * 1000 } end },
	Random = { new = function() return { NextInteger = function(_, a, b) return rnd(a, b) end } end },
}, { __index = _G })
local function env(extra)
	local e = setmetatable(extra or {}, { __index = base })
	return e
end
local serverRemotes -- set per module
local sharedEnv = env({ game = { GetService = function(_, n) return ({ ReplicatedStorage = folder() })[n] or {} end } })
local function loadShared(name)
	if modules[name] ~= nil then return modules[name] end
	local src = S[name]
	if not src then error("no source for " .. name) end
	sharedEnv.require = function(m) return loadShared(m.__module) end
	local chunk = assert(load(src, "=" .. name, "t", sharedEnv))
	modules[name] = chunk()
	return modules[name]
end
local MapData = { Order = { "Bay", "Arena", "Hills", "Town", "Dunes" } }
function MapData.Get(id) return { name = id, description = "", radius = 500 } end

local function serverModule(name, remotes)
	local e = env({
		game = { GetService = function(_, n)
			if n == "Players" then return Players end
			if n == "ReplicatedStorage" then return { WaitForChild = function() return folder() end } end
			return {}
		end },
		script = { Parent = folder() },
	})
	e.require = function(m)
		local n = m.__module
		if n == "Remotes" then return remotes end
		if n == "MapData" then return MapData end
		if n == "ModeTeams" then return { SetPicks = function() point("ModeTeams.SetPicks()") end } end
		return loadShared(n)
	end
	local chunk = assert(load(S[name], "=" .. name, "t", e))
	return chunk()
end

Vote = serverModule("VoteService", { Event = function(n)
	return { FireAllClients = function(_, snap) send(n, nil, snap) end }
end })
Picker = serverModule("TeamPicker", { Event = function(n)
	return { FireClient = function(_, p, snap) send(n, p.Name, snap) end }
end })
Picker.Clock = function() return W.now end
Picker.Wait = wait
Picker.ModeTeams = { SetPicks = function() point("ModeTeams.SetPicks()") end }
local GameModes = loadShared("GameModes")
local MatchConfig = loadShared("MatchConfig")

-- MatchService's environment: its own state as plain values, the real Vote/Picker, and an auto-stub for
-- every other name (a service, a remote, a local helper), which counts as an injection point when called.
local stubs = {}
local returns = {}
local function stub(path)
	local s = stubs[path]
	if s then return s end
	s = setmetatable({}, {
		__index = function(t, k) local c = stub(path .. "." .. tostring(k)) rawset(t, k, c) return c end,
		__call = function(_, ...)
			point(path .. "()")
			local r = returns[path]
			if type(r) == "function" then return r(...) end
			return r
		end,
	})
	stubs[path] = s
	return s
end
local function makeMode(modeId)
	local def = GameModes.Get(modeId)
	local mode = { StartWorld = function() point("mode.StartWorld()") end, StopWorld = function() end,
		Broadcast = function() return nil end }
	if def.respawn then mode.PlaceAtStart = function() end end
	return setmetatable(mode, { __index = def })
end
returns["GameMode.Resolve"] = function(_, modeId) return makeMode(modeId or "BattleRoyale") end
returns["GameMode.AllowsEvent"] = true
returns["MapGenerator.Build"] = function(mapId) return { mapName = mapId, radius = 500, dropSpots = {} } end
returns["BotService.Count"] = 0
local NILS = { mapInfo = true, currentEvent = true, bountyToken = true }
M = setmetatable({
	state = "Waiting", countdown = 0, dropSelect = false, teamSelect = false, chosenDrop = {}, participants = {},
	alive = {}, leftSpectate = {}, placements = {}, aliveCount = 0, matchId = 0, streaks = {},
	lastReadyToggle = {}, deathConnections = {}, bountyReward = 0,
	afk = { players = {}, tick = 0, every = 15, sample = function() end },
	regen = { lastCombat = {}, lastHealth = {}, step = function() end },
	-- Bootstrap sets these two hooks in the game; here they are injection points like any other call.
	MatchService = { BroadcastCount = 0,
		OnMatchStart = function() point("MatchService.OnMatchStart()") end,
		OnMapBuilt = function() point("MatchService.OnMapBuilt()") end },
	Players = Players, MatchConfig = MatchConfig, VoteService = Vote, TeamPicker = Picker,
	matchChanged = { FireAllClients = function(_, payload) send("MatchChanged", nil, payload) end },
	task = { wait = wait, spawn = function() end, delay = function(s, fn) schedule(W.now + s, function() pcall(fn) end) end },
	tick = base.tick, os = base.os, math = base.math, table = base.table, warn = base.warn, typeof = base.typeof,
	require = function() return stub("required") end,
}, { __index = function(_, k)
	if NILS[k] then return nil end
	local g = _G[k]
	if g ~= nil then return g end
	return stub(k)
end })
M.currentMode = makeMode("BattleRoyale")
for _, name in ipairs({ "isReady", "readyPlayers", "countKeys", "broadcast", "SetReady", "IsSpectating",
	"LeaveSpectate", "startMatch" }) do
	assert(load(P[name], "=MatchService." .. name, "t", M))()
end
local loopBody = assert(load(P.loop, "=MatchService.Start loop", "t", M))
local breakBody = assert(load(P["break"], "=MatchService finishMatch break", "t", M))
local joinBody = assert(load(P.join, "=Bootstrap join", "t", env({ VoteService = Vote,
	Remotes = { Event = function(n) return { FireAllClients = function(_, snap) send(n, nil, snap) end } end } })))
function M.startMatch()
	W.attempts = W.attempts + 1
	W.inStart = true
	local ok, err = pcall(M.startMatchReal)
	W.inStart = false
	if not ok then
		W.failedStarts = W.failedStarts + 1
		note("startMatch threw: " .. tostring(err))
		error(err, 0)
	end
end

-- The scenario.
local MS = M.MatchService
local players = {}
local function join(name)
	local p = newPlayer(name, #players + 1)
	players[name] = p
	table.insert(Players.list, p)
	W.joinSeq = W.joinSeq or {}
	W.joinSeq[name] = W.seq
	Players.PlayerAdded:Fire(p)
	joinBody()   -- Bootstrap's re-broadcast, at profile load
	note("join " .. name .. " (state " .. M.state .. ")")
	return p
end
W.players = players

local function desiredMode() return W.attempts == 0 and "BattleRoyale" or "TeamDeathmatch" end
local lastCards = nil
local dropSeen, pickerSeen = -1, -1
onSend = function(entry)
	local p = entry.payload
	if entry.remote == "VoteChanged" and p.open then
		local key = {}
		for i, c in ipairs(p.candidates or {}) do key[i] = c.id end
		key = table.concat(key, ",")
		if key ~= lastCards then
			lastCards = key
			schedule(W.now + 0.2, function()
				for _, c in ipairs(Vote.GetCandidates()) do
					if c.modeId == desiredMode() then
						for _, name in ipairs({ "A", "B", "L" }) do
							if players[name] then Vote.CastVote(players[name], c.id) end
						end
					end
				end
			end)
		end
	elseif entry.remote == "MatchChanged" and p.dropSelect and dropSeen ~= W.attempts then
		dropSeen = W.attempts
		-- A picks a landing spot 3 s in (stand-in for MatchService.ChooseDrop); B never picks.
		schedule(W.now + 3, function() if players.A then M.chosenDrop[players.A] = { X = 1, Y = 1 } end end)
	elseif entry.remote == "TeamPickerChanged" and p.open and pickerSeen ~= W.attempts then
		pickerSeen = W.attempts
		schedule(W.now + 1, function() Picker.Pick(players.A, 1) end)
		schedule(W.now + 2, function() Picker.Pick(players.B, 2) end)
	end
end

local function finish()
	-- Stand-in for finishMatch's head (rewards, results): state and its broadcast. The step that follows
	-- it, ResultsDuration later, is the real code.
	W.completed = W.completed + 1
	note("match ends (stand-in for finishMatch's head)")
	M.state = "Results"
	M.broadcast()
	M.thisMatch = M.matchId
	schedule(W.now + MatchConfig.ResultsDuration, function() breakBody() end)
end

local function duringMatch(mode)
	local t0 = W.now
	if mode == "BattleRoyale" then
		schedule(t0 + 5, function()   -- B is killed: the elimination's own broadcast (stand-in)
			M.alive[players.B] = nil
			M.aliveCount = M.aliveCount - 1
			M.broadcast()
			note("B eliminated")
		end)
		schedule(t0 + 10, function() note("B leaves spectating: " .. tostring(MS.LeaveSpectate(players.B))) end)
		schedule(t0 + 12, function() MS.SetReady(players.B, false) end)
		schedule(t0 + 12.5, function() MS.SetReady(players.B, true) end)
		schedule(t0 + 14, function()
			local c = Vote.GetCandidates()[1]
			note("B votes mid-match: " .. tostring(select(2, Vote.CastVote(players.B, c and c.id or "x"))))
		end)
		schedule(t0 + 15, function() join("J") end)
		schedule(t0 + 20, function() MS.SetReady(players.L, true) end)
	else
		schedule(t0 + 5, function() M.broadcast() note("A dies (respawn mode)") end)
		schedule(t0 + 10, function() M.broadcast() note("A respawns") end)
		schedule(t0 + 8, function() join("K") end)
		schedule(t0 + 12, function() MS.SetReady(players.L, false) end)
		schedule(t0 + 12.5, function() MS.SetReady(players.L, true) end)
	end
	schedule(t0 + 30, finish)
end

join("A"); join("B"); join("L")
M.broadcast()
schedule(0.5, function() MS.SetReady(players.A, true) end)
schedule(0.9, function() MS.SetReady(players.B, true) end)

local prev = M.state
local seenBreakAfter = 0
while W.now < 900 do
	advanceTo(W.now + 1)
	W.loopTicks = W.loopTicks + 1
	local ok, err = pcall(loopBody)
	if not ok then
		W.tickerDied = tostring(err)
		note("THE 1 s LOOP THREW (the real thread would die here): " .. tostring(err))
		break
	end
	serverInvariants("loop tick")
	if M.state ~= prev then
		note("state " .. tostring(prev) .. " -> " .. tostring(M.state))
		if M.state == "InProgress" then duringMatch(M.currentMode.id) end
		prev = M.state
	end
	if W.completed >= 2 and M.state == "Countdown" then break end
end
W.finalState = M.state
return W
"""

# One client: VoteDropClient and TeamPickerClient, real, replaying `stream` (a list of wire entries).
CLIENT_LUA = r"""
local S, stream, me, opt = ...
local C = { now = 0, tasks = {}, deferred = {}, viol = {}, nviol = 0, moments = 0,
	seen = { interactive = 0, reveal = 0, picker = 0, team = 0 }, finding = 0, findings = {}, errors = {},
	byState = {}, revealLobby = 0, revealLobbySpan = 0 }
local truth = nil

-- Threads and timers.
local function resume(co, ...)
	local ok, wake = coroutine.resume(co, ...)
	if not ok then table.insert(C.errors, tostring(wake)) return end
	if coroutine.status(co) ~= "dead" then table.insert(C.tasks, { at = wake or C.now, co = co }) end
end
local function spawn(fn, ...) resume(coroutine.create(fn), ...) end
local task = {
	spawn = spawn,
	defer = spawn,
	delay = function(s, fn, ...) local a = table.pack(...) table.insert(C.tasks, { at = C.now + (s or 0), fn = fn, args = a }) end,
	wait = function(s)
		if coroutine.isyieldable() then return coroutine.yield(C.now + (s or 0)) end
		return 0
	end,
}
local function runDue(limit)
	for _ = 1, 10000 do
		local best = nil
		for i, t in ipairs(C.tasks) do
			if t.at <= limit and (best == nil or t.at < C.tasks[best].at) then best = i end
		end
		if not best then return end
		local t = table.remove(C.tasks, best)
		if t.at > C.now then C.now = t.at end
		if t.co then resume(t.co) else spawn(t.fn, table.unpack(t.args, 1, t.args.n)) end
		-- deferred attribute signals run at the next resumption point
		while #C.deferred > 0 do spawn(table.remove(C.deferred, 1)) end
	end
	table.insert(C.errors, "scheduler did not settle")
end

local function signal()
	local s = { handlers = {} }
	function s:Connect(fn) table.insert(self.handlers, fn) return { Disconnect = function() end } end
	function s:Fire(...) for _, f in ipairs(self.handlers) do spawn(f, ...) end end
	return s
end

-- Engine mocks.
local function enumStub()
	return setmetatable({}, { __index = function(t, k)
		local v = setmetatable({ Name = k }, { __index = function(t2, k2) local e = { Name = k2 } rawset(t2, k2, e) return e end })
		rawset(t, k, v)
		return v
	end })
end
local Enum = enumStub()
local function instance(class)
	local sigs = {}
	return setmetatable({ ClassName = class }, { __index = function(t, k)
		if k == "GetPropertyChangedSignal" then
			return function(_, prop) sigs[prop] = sigs[prop] or signal() return sigs[prop] end
		end
		if k == "Destroy" or k == "ClearAllChildren" then return function() end end
		if k == "FindFirstChild" or k == "FindFirstChildOfClass" then return function() return nil end end
		return nil
	end })
end
local P = { Name = me, DisplayName = me, UserId = opt.userId or 1, attrs = {}, sigs = {} }
function P:GetAttribute(k) return self.attrs[k] end
function P:SetAttribute(k, v)
	if self.attrs[k] == v then return end
	self.attrs[k] = v
	for _, f in ipairs(self.sigs[k] or {}) do table.insert(C.deferred, f) end
end
function P:GetAttributeChangedSignal(k)
	local owner = self
	return { Connect = function(_, fn)
		owner.sigs[k] = owner.sigs[k] or {}
		table.insert(owner.sigs[k], fn)
		return { Disconnect = function() end }
	end }
end
local playerGui = instance("PlayerGui")
function P:WaitForChild(n) if n == "PlayerGui" then return playerGui end return instance(n) end
function P:FindFirstChild() return nil end

local remotes = {}
local function remote(name)
	remotes[name] = remotes[name] or { OnClientEvent = signal(), FireServer = function() end }
	return remotes[name]
end
local Remotes = {
	Event = function(name) return remote(name) end,
	Function = function(name) return { InvokeServer = function() if name == "GetDropMap" then return {} end return true end } end,
}
local camera = { ViewportSize = { X = 1920, Y = 1080 },
	GetPropertyChangedSignal = function() return signal() end }
local workspace = { CurrentCamera = camera, GetPropertyChangedSignal = function() return signal() end }
local services = {
	Players = { LocalPlayer = P },
	UserInputService = { InputBegan = signal(), LastInputTypeChanged = signal(), TouchEnabled = false,
		KeyboardEnabled = true, GamepadEnabled = false,
		GetLastInputType = function() return Enum.UserInputType.MouseMovement end },
	GuiService = { GetGuiInset = function() return { X = 0, Y = 36 } end },
	TextChatService = { FindFirstChildOfClass = function() return nil end },
}
local function marker(name, side)
	return { __module = name, __side = side, WaitForChild = function(_, n) return marker(n, side) end }
end
local sharedFolder = { WaitForChild = function(_, n) return marker(n, "shared") end }
services.ReplicatedStorage = { WaitForChild = function() return sharedFolder end }
local game = { GetService = function(_, n) return services[n] or instance(n) end }
local clientFolder = { WaitForChild = function(_, n) return marker(n, "client") end }

-- The three screens, recording what is drawn. See the module docstring for what each copies.
local VoteCursor
local VS, DP, TS
local mocks = {
	VoteScreen = { new = function(options)
		VS = { state = { open = false, candidates = {} }, visible = false, held = false }
		function VS:Render(state)
			if state then self.state = state end
			local visible, wants = VoteCursor.Screen(self.state.open, self.state.decided, self.state.ready)
			self.visible = visible
			if wants ~= self.held then
				self.held = wants
				if options.onMenuOpen then options.onMenuOpen(wants) end
			end
		end
		function VS:CandidateAt(i) local c = self.state.candidates and self.state.candidates[i] return c and c.id end
		function VS:Relayout() end
		return VS
	end },
	DropPicker = { new = function(options)
		DP = { visible = false, held = false }
		function DP:SetVisible(v)
			v = v == true
			self.visible = v
			if v and not self.held then self.held = true options.onMenuOpen(true)
			elseif not v and self.held then self.held = false options.onMenuOpen(false) end
		end
		function DP:SetPayload() end
		function DP:SetSeconds() end
		function DP:Layout() end
		return DP
	end },
	TeamPickerScreen = { new = function()
		TS = { shown = false, input = "keyboard" }
		function TS:Show() self.shown = true end
		function TS:Hide() self.shown = false end
		function TS:Render() end
		function TS:Layout() end
		function TS:SetInput(k) self.input = k end
		function TS:Countdown() end
		function TS:FocusTarget() return nil end
		function TS:Choose() end
		return TS
	end },
	TeamPickerLayout = { Compute = function() return {} end, Measure = function() return {} end,
		rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end },
	PhoneLayout = { Active = function() return false end, Rects = function() return {} end },
	EventBanner = { HoldFor = function() end },
	Settings = { KeyLabel = function() return "R" end },
}
local modules = {}
local base = setmetatable({
	game = game, workspace = workspace, Enum = Enum, task = task,
	Instance = { new = function(c) return instance(c) end },
	Vector2 = { new = function(x, y) return { X = x, Y = y } end },
	Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z } end },
	Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end, new = function(r, g, b) return { R = r, G = g, B = b } end },
	UDim2 = { new = function() return {} end, fromScale = function() return {} end, fromOffset = function() return {} end },
	typeof = function(v) return type(v) end,
	tick = function() return C.now end,
	os = setmetatable({ clock = function() return C.now end }, { __index = os }),
	warn = function() end, print = function() end,
	script = { Parent = clientFolder },
	table = setmetatable({ clear = function(t) for k in pairs(t) do t[k] = nil end end,
		clone = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end }, { __index = table }),
	math = setmetatable({ clamp = function(x, a, b) return math.max(a, math.min(b, x)) end }, { __index = math }),
}, { __index = _G })
local function req(m)
	local n = m.__module
	if modules[n] ~= nil then return modules[n] end
	local result
	if n == "Remotes" then result = Remotes
	elseif mocks[n] then result = mocks[n]
	elseif S[n] then
		local e = setmetatable({ require = req }, { __index = base })
		result = assert(load(S[n], "=" .. n, "t", e))()
	else error("client: no module " .. tostring(n)) end
	modules[n] = result
	return result
end
base.require = req
VoteCursor = req(marker("VoteCursor", "shared"))
for _, script in ipairs({ "VoteDropClient", "TeamPickerClient" }) do
	local e = setmetatable({ require = req }, { __index = base })
	spawn(assert(load(S[script], "=" .. script, "t", e)))
end
while #C.deferred > 0 do spawn(table.remove(C.deferred, 1)) end
runDue(C.now)

local MATCH_STATES = { InProgress = true, Results = true }
local function violate(kind, detail)
	C.nviol = C.nviol + 1
	local key = kind .. " " .. me .. " " .. (truth and truth.state or "?")
	C.byState[key] = (C.byState[key] or 0) + 1
	if #C.viol < 6 then
		table.insert(C.viol, string.format("%s %s t=%.2f server=%s: %s", kind, me, C.now, truth and truth.state or "?", detail))
	end
end
local function observe(where)
	if not truth then return end
	C.moments = C.moments + 1
	local st = truth.state
	local interactive = VS.visible and VS.state.open == true
	local reveal = VS.visible and VS.state.decided ~= nil
	if interactive then C.seen.interactive = C.seen.interactive + 1 end
	if reveal then C.seen.reveal = C.seen.reveal + 1 end
	-- Not an invariant: the reveal drawn after the server has already gone back to the lobby (a failed
	-- start's VoteService.Close() carries a winner). Timed, to say how long a player could see it.
	if reveal and (st == "Waiting" or st == "Intermission") then
		C.revealLobby = C.revealLobby + 1
		C.revealLobbyFrom = C.revealLobbyFrom or C.now
		C.revealLobbySpan = math.max(C.revealLobbySpan, C.now - C.revealLobbyFrom)
	else
		C.revealLobbyFrom = nil
	end
	if DP.visible then C.seen.picker = C.seen.picker + 1 end
	if TS.shown then C.seen.team = C.seen.team + 1 end
	if VS.visible and MATCH_STATES[st] then
		violate("V1", (interactive and "the interactive vote" or "the winner reveal") .. " is drawn (" .. where .. ")")
	end
	if DP.visible and (st ~= "Loading" or not truth.participants[me]) then
		violate("V2", "the drop picker is drawn" .. (truth.participants[me] and "" or " for a non-participant") .. " (" .. where .. ")")
	end
	if TS.shown and (st ~= "Loading" or not truth.participants[me]) then
		violate("V3", "the team picker is drawn" .. (truth.participants[me] and "" or " for a non-participant") .. " (" .. where .. ")")
	end
end

local function deliver(entry)
	if entry.remote == "attr:Ready" then
		P:SetAttribute("Ready", entry.payload)
	else
		remote(entry.remote).OnClientEvent:Fire(S.deepcopy(entry.payload))
	end
	while #C.deferred > 0 do spawn(table.remove(C.deferred, 1)) end
end

local lastOpenVote, lastOpenTeam = nil, opt.anyOpenTeam
local maxSeq = -1
for i, entry in ipairs(stream) do
	-- timers due before this message arrives
	while true do
		local nextAt = nil
		for _, t in ipairs(C.tasks) do if nextAt == nil or t.at < nextAt then nextAt = t.at end end
		if nextAt == nil or nextAt >= entry.t then break end
		runDue(nextAt)
		observe("timer")
	end
	if entry.t > C.now then C.now = entry.t end
	if entry.seq > maxSeq then maxSeq = entry.seq truth = entry.truth end
	deliver(entry)
	runDue(C.now)
	observe(entry.remote)
	if entry.remote == "VoteChanged" and entry.payload.open then lastOpenVote = entry.payload end
	if entry.remote == "TeamPickerChanged" and entry.payload.open then lastOpenTeam = entry.payload end
	if opt.hostile and MATCH_STATES[truth.state] then
		-- The client's guards on their own: things the server never sends in a match.
		if lastOpenVote then
			remote("VoteChanged").OnClientEvent:Fire(S.deepcopy(lastOpenVote))
			runDue(C.now) observe("hostile: a late open vote snapshot")
			local closed = S.deepcopy(lastOpenVote)
			closed.open = false
			closed.winner = closed.candidates and closed.candidates[1] and closed.candidates[1].id or "X"
			remote("VoteChanged").OnClientEvent:Fire(closed)
			runDue(C.now) observe("hostile: an open->closed transition with a winner")
			remote("VoteChanged").OnClientEvent:Fire(S.deepcopy(entry.lastVote or { open = false, candidates = {}, votes = {} }))
			runDue(C.now)
		end
		if lastOpenTeam then
			local snap = S.deepcopy(lastOpenTeam)
			snap.mode = truth.mode or snap.mode
			remote("TeamPickerChanged").OnClientEvent:Fire(snap)
			runDue(C.now) observe("hostile: an open team-picker snapshot")
			snap = S.deepcopy(snap) snap.open = false
			remote("TeamPickerChanged").OnClientEvent:Fire(snap)
			runDue(C.now)
		end
	end
	if opt.stuckDrop and truth.state == "InProgress" and entry.remote == "MatchChanged" then
		-- FINDING PROBE, not an invariant row: the real payload with dropSelect left set.
		local p = S.deepcopy(entry.payload)
		p.dropSelect = true
		remote("MatchChanged").OnClientEvent:Fire(p)
		runDue(C.now)
		if DP.visible then C.finding = C.finding + 1 end
		remote("MatchChanged").OnClientEvent:Fire(S.deepcopy(entry.payload))
		runDue(C.now)
	end
end
-- let the last timers run out
for _ = 1, 50 do
	local nextAt = nil
	for _, t in ipairs(C.tasks) do if nextAt == nil or t.at < nextAt then nextAt = t.at end end
	if nextAt == nil then break end
	runDue(nextAt)
	observe("timer")
end
return C
"""

def load_files(root, overrides=None):
    files = {}
    for rel in FILES:
        if overrides and rel in overrides:
            files[rel] = overrides[rel]
        else:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                files[rel] = f.read()
    return files


def shape_guards(files):
    """The screen mocks copy three lines; if the real ones change, the mocks are stale."""
    problems = []
    need = [
        (CLIENT + "VoteScreen.lua", "local visible, wantsCursor = VoteCursor.Screen(state.open, state.decided, state.ready)"),
        (CLIENT + "VoteScreen.lua", "self.root.Visible = visible"),
        (CLIENT + "DropPicker.lua", "self.visible = visible\n\tself.root.Visible = visible"),
        (CLIENT + "TeamPickerScreen.lua", "self.shown = true\n\tself.panel.Visible = true"),
        (CLIENT + "TeamPickerScreen.lua", "function TeamPickerScreen:Hide()\n\tself.shown = false"),
    ]
    for rel, text in need:
        if text not in files[rel]:
            problems.append(f"shape guard: {rel} no longer contains {text!r}; the screen mock copies it")
    return problems


class World:
    """One server run and the clients that replay it."""

    def __init__(self, files, throw_at=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        src = {}
        names = {"VoteService": VOTE, "TeamPicker": PICKER, "MatchConfig": SHARED + "MatchConfig.lua",
                 "GameModes": SHARED + "GameModes.lua", "Rarity": SHARED + "Rarity.lua",
                 "TeamPickerRules": SHARED + "TeamPickerRules.lua", "VoteReveal": SHARED + "VoteReveal.lua",
                 "VoteCursor": SHARED + "VoteCursor.lua", "VoteDropClient": CLIENT + "VoteDropClient.client.lua",
                 "TeamPickerClient": CLIENT + "TeamPickerClient.client.lua",
                 "MenuOpenClaims": CLIENT + "MenuOpenClaims.lua"}
        for name, rel in names.items():
            src[name] = luau_to_lua(files[rel])
        self.src = self.lua.table_from(src)
        self.pieces = self.lua.table_from(pieces(files))
        opts = self.lua.table_from({"throwAt": throw_at} if throw_at else {})
        self.W = self.lua.execute(SERVER, self.src, self.pieces, opts)
        self.src["deepcopy"] = self.W.deepcopy
        self.wire = [self.W.wire[i] for i in range(1, len(self.W.wire) + 1)]

    def stream(self, name):
        start = self.W.joinSeq[name] if self.W.joinSeq and self.W.joinSeq[name] is not None else 0
        return [e for e in self.wire if e.seq > start and (e.to is None or e.to == name)]

    def any_open_team(self):
        for e in self.wire:
            if e.remote == "TeamPickerChanged" and e.payload.open:
                return e.payload
        return None

    def client(self, name, entries, **opt):
        # Each hostile injection is followed by the last real VoteChanged, to put the client back.
        last_vote = None
        for e in entries:
            if e.remote == "VoteChanged":
                last_vote = e.payload
            e.lastVote = last_vote
        stream = self.lua.table_from(entries)
        o = dict(opt)
        o["userId"] = {"A": 1, "B": 2, "L": 3, "J": 4, "K": 5}.get(name, 9)
        if opt.get("hostile"):
            o["anyOpenTeam"] = self.any_open_team()
        return self.lua.execute(CLIENT_LUA, self.src, stream, name, self.lua.table_from(o))

    def clients(self):
        return [n for n in ("A", "B", "L", "J", "K") if self.W.players[n] is not None]


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


def run_world(files, throw_at=None, hostile=False, stuck=False):
    """Returns a summary dict for the in-order (and optionally hostile) replay of every client."""
    w = World(files, throw_at)
    out = {"world": w, "sviol": lua_list(w.W.sviol), "sn": w.W.snCount, "cviol": [], "cn": 0, "moments": 0,
           "seen": {"interactive": 0, "reveal": 0, "picker": 0, "team": 0}, "errors": [], "finding": 0,
           "hostile_moments": 0, "byState": {}, "revealLobby": 0, "revealLobbySpan": 0.0}
    for name in w.clients():
        c = w.client(name, w.stream(name), hostile=hostile, stuckDrop=stuck)
        out["cviol"] += lua_list(c.viol)
        out["cn"] += c.nviol
        out["moments"] += c.moments
        out["finding"] += c.finding
        out["revealLobby"] += c.revealLobby
        out["revealLobbySpan"] = max(out["revealLobbySpan"], c.revealLobbySpan)
        out["errors"] += lua_list(c.errors)
        for k, v in c.byState.items():
            out["byState"][k] = out["byState"].get(k, 0) + v
        for k in out["seen"]:
            out["seen"][k] += c.seen[k]
    return out


def swap_variants(w, name):
    """Every adjacent pair of messages on two different channels, delivered the other way round."""
    entries = w.stream(name)
    n, bad, first = 0, 0, None
    for i in range(len(entries) - 1):
        if entries[i].remote == entries[i + 1].remote:
            continue
        swapped = entries[:i] + [entries[i + 1], entries[i]] + entries[i + 2:]
        c = w.client(name, swapped)
        n += 1
        if c.nviol:
            bad += 1
            first = first or lua_list(c.viol)[0]
    return n, bad, first


def join_variants(w, name):
    entries = w.stream(name)
    n, bad, first = 0, 0, None
    for k in range(1, len(entries)):
        c = w.client(name, entries[k:])
        n += 1
        if c.nviol:
            bad += 1
            first = first or lua_list(c.viol)[0]
    return n, bad, first


# Planted faults. Each is (label, file, old, new); each must break a V or S invariant.
PLANTS = [
    ("client: the vote drawn whatever the match state (VoteReveal.View)", SHARED + "VoteReveal.lua",
     'local open = voteOpen == true and (state == "Countdown" or (LOBBY_VOTE[state] == true and ready == true))',
     "local open = voteOpen == true"),
    ("client: the winner reveal allowed over a running match (VoteReveal.View)", SHARED + "VoteReveal.lua",
     'and (state == "Loading" or state == "Countdown")', 'and state ~= "Waiting"'),
    ("client: VoteDropClient bypasses View for the open face", CLIENT + "VoteDropClient.client.lua",
     "local open = stateOpen and not menuUp", "local open = voteState.open == true and not menuUp"),
    ("client: the team picker's match-state gate removed (TeamPickerClient.isOpen)", CLIENT + "TeamPickerClient.client.lua",
     'if matchState and (matchState.state ~= "Loading" or matchState.mode ~= snapshot.mode) then',
     "if false then"),
    ("server: startMatch no longer closes the vote", MATCH,
     "\tlocal winningMap = VoteService.Resolve()\n\tVoteService.Close()\n",
     "\tlocal winningMap = VoteService.Resolve()\n"),
    ("server: Bootstrap re-broadcasts the vote on every join", BOOT,
     "\tif VoteService.IsOpen() then\n\t\tVoteService.Broadcast()\n\tend\n",
     "\tVoteService.Broadcast()\n"),
    ("server: the drop window never clears dropSelect", MATCH,
     "\t\tdropSelect = false\n\t\tcountdown = 0\n\t\tbroadcast()\n",
     "\t\tcountdown = 0\n\t\tbroadcast()\n"),
    ("server: TeamPicker.Close leaves the window open", PICKER,
     "\tlocal sides = Rules.Resolve(order, picks, firstTie)\n\topen = false\n",
     "\tlocal sides = Rules.Resolve(order, picks, firstTie)\n"),
]


def plant_caught(files, label, rel, old, new, throw_at=None, hostile=True):
    if files[rel].count(old) != 1:
        return None, "plant did not apply (source changed)"
    planted = dict(files)
    planted[rel] = files[rel].replace(old, new)
    try:
        r = run_world(planted, throw_at=throw_at, hostile=hostile)
    except Exception as exc:  # a crash is not a catch
        return False, "harness crashed: " + str(exc).splitlines()[0]
    hits = r["sviol"] + r["cviol"]
    return bool(hits), (hits[0] if hits else "no violation")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    quick = "--quick" in sys.argv
    files = load_files(root)
    if "--trace" in sys.argv:
        k = int(sys.argv[sys.argv.index("--trace") + 1])
        r = run_world(files, throw_at=k)
        print("\n".join(lua_list(r["world"].W.events)))
        for v in r["sviol"] + r["cviol"]:
            print("  " + v)
        for k2, v in sorted(r["byState"].items()):
            print(f"  {k2}: {v}")
        return 0
    ok = True

    for p in shape_guards(files):
        print("FAIL " + p)
        ok = False

    # 1. The clean scenario, in order, and the hostile replay.
    clean = run_world(files)
    w = clean["world"]
    kinds = {}
    for e in w.wire:
        kinds[e.remote] = kinds.get(e.remote, 0) + 1
    print(f"scenario: {len(w.wire)} messages on the wire ({', '.join(f'{k} {v}' for k, v in sorted(kinds.items()))}), "
          f"{w.W.loopTicks} loop ticks, {w.W.attempts} starts ({w.W.failedStarts} failed), {w.W.completed} matches "
          f"completed, final state {w.W.finalState}")
    print("  timeline: " + " | ".join(lua_list(w.W.events)))
    print(f"clean, in order: {len(w.clients())} clients, {clean['moments']} client moments examined; drawn: "
          f"interactive vote {clean['seen']['interactive']}, reveal {clean['seen']['reveal']}, "
          f"drop picker {clean['seen']['picker']}, team picker {clean['seen']['team']}; "
          f"{clean['cn']} V violations, {clean['sn']} S violations")
    for v in (clean["sviol"] + clean["cviol"])[:6]:
        print("  " + v)
    for e in clean["errors"][:3]:
        print("  client error: " + e)
    if clean["cn"] or clean["sn"] or clean["errors"]:
        ok = False
    if min(clean["seen"].values()) == 0:
        print("FAIL: a screen was never drawn in the clean run; the scenario is not exercising it")
        ok = False

    hostile = run_world(files, hostile=True)
    print(f"hostile (client guards alone): {hostile['moments']} client moments, "
          f"{hostile['cn']} V violations")
    for v in hostile["cviol"][:4]:
        print("  " + v)
    if hostile["cn"] or hostile["errors"]:
        ok = False

    stuck = run_world(files, stuck=True)
    print(f"FINDING PROBE (not pass/fail): a MatchChanged with dropSelect still set, replayed at each InProgress "
          f"broadcast, opened the drop picker at {stuck['finding']} moments (the picker has no match-state gate "
          f"of its own)")

    # 2. Reorders and late joins.
    if not quick:
        total_n = total_bad = 0
        firsts = []
        for name in w.clients():
            n, bad, first = swap_variants(w, name)
            total_n += n
            total_bad += bad
            if first:
                firsts.append(first)
        print(f"cross-channel swaps: {total_n} variants (every adjacent pair on two channels, every client), "
              f"{total_bad} with a V violation")
        for f in firsts[:3]:
            print("  " + f)
        n, bad, first = join_variants(w, "A")
        print(f"late joins: {n} variants (A's stream started at every message), {bad} with a V violation"
              + (f"; first: {first}" if first else ""))
        if total_bad or bad:
            ok = False

    # 3. The throw sweep: a failed start at every point startMatch reaches.
    if not quick:
        points = lua_list(w.W.points)
        print(f"throw sweep: {len(points)} injection points inside startMatch (both matches)")
        results = []
        for k in range(1, len(points) + 1):
            r = run_world(files, throw_at=k)
            rw = r["world"]
            results.append((k, points[k - 1], rw.W.failedStarts, r["sn"], r["cn"], (r["sviol"] + r["cviol"])[:1],
                            rw.W.tickerDied, r["byState"], r["revealLobby"], r["revealLobbySpan"]))
        failed = sum(1 for x in results if x[2])
        viol = [x for x in results if x[3] or x[4]]
        died = [x for x in results if x[6]]
        print(f"  {failed} of {len(points)} throws became a failed start (the rest are swallowed by a pcall); "
              f"{len(viol)} broke an invariant; {len(died)} killed the 1 s loop")
        groups = {}
        flash = [x for x in results if x[8]]
        print(f"  info: {len(flash)} failed starts drew the winner reveal after the server was back in the lobby "
              f"(a winner for a match that never started); longest on screen {max([x[9] for x in flash] or [0]):.2f} s "
              f"of virtual time, points {', '.join(str(x[0]) for x in flash[:12])}")
        for k, label, fs, sn, cn, first, dead, by, *_ in viol:
            sig = (sn > 0, tuple(sorted(by)))
            groups.setdefault(sig, []).append((k, label, sn, cn, first, by))
        for (has_s, keys), members in groups.items():
            ks = [m[0] for m in members]
            labels = sorted(set(m[1] for m in members))
            by = members[0][5]
            print(f"  FINDING points {ks[0]}-{ks[-1]} ({len(ks)} points: {', '.join(labels)}): "
                  f"{members[0][2]} S + {members[0][3]} V violations each; first: {members[0][4][0] if members[0][4] else ''}")
            print("    V violations by kind/client/server state: "
                  + ", ".join(f"{k} x{v}" for k, v in sorted(by.items())))
        for k, label, *_ in died[:3]:
            print(f"  FINDING point {k} ({label}): the loop thread died")

    # 4. Planted faults.
    caught = 0
    for label, rel, old, new in PLANTS:
        hit, detail = plant_caught(files, label, rel, old, new)
        if hit is None:
            print(f"FAIL planted fault '{label}': {detail}")
            ok = False
            continue
        caught += bool(hit)
        print(f"planted fault '{label}': {'CAUGHT' if hit else 'MISSED'} ({detail})")
        ok = ok and hit
    # The layers together: the vote's Close broadcast lost (VoteService's announce swallows a throw) with
    # View's match-state gate removed. No hostile replay here -- only what the real server sent.
    points = lua_list(w.W.points)
    close_at = points.index("VoteChanged:FireAllClients") + 1 if "VoteChanged:FireAllClients" in points else None
    total = len(PLANTS)
    if close_at:
        label, rel, old, new = PLANTS[0]
        hit, detail = plant_caught(files, label, rel, old, new, throw_at=close_at, hostile=False)
        total += 1
        caught += bool(hit)
        print(f"planted fault 'the Close broadcast lost (point {close_at}) AND View ungated, real server only': "
              f"{'CAUGHT' if hit else 'MISSED'} ({detail})")
        ok = ok and bool(hit)
    print(f"planted faults: {caught}/{total} caught")
    print("vote_menu_proof: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
