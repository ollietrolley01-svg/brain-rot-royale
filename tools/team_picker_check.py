"""The team picker, checked without Studio: the server's rules, the hand-off to ModeTeams, and the screen.

    python3 tools/team_picker_check.py .            the checks
    python3 tools/team_picker_check.py . --plant    and the planted faults (every one must be caught)

SERVER (the REAL ReplicatedStorage/Shared/TeamPickerRules, ServerScriptService/Modules/TeamPicker and
RateLimit, and the TEAM PICKER region of ModeTeams plus its Counts/Assign/Forget, under lupa):
  balance     a side holds at most ceil(humans / 2); a pick past that is refused "full"; a party fills a
              side while there is room; 600 random pick/leave sequences all close with the two sides at
              most one human apart and every human on a side
  auto        whoever did not pick is dealt onto the side with fewer humans when the window closes
  timeout     Run waits out the vote's reveal before it opens, ends at its deadline, and a pick after the
              deadline (or after Close) is refused "stale"/"closed" -- including one the rate limiter
              held back and applied late
  rate limit  PickTeam has a budget, Bootstrap routes the remote through RateLimit, and a burst past it
              is held rather than applied
  leavers     a leaver frees a seat, and a side left over the cap has its newest picks sent back to AUTO
  hand-off    ModeTeams.Assign puts each picked player on their side even when every bot is dealt
              first, the bots fill round them to even sides, and a late joiner with no pick goes to
              the smaller side (no picker mid-match)
  no BR       the battle royale never opens it (Open, Run), and MatchService only runs it for `teams`

SCREEN (the REAL TeamPickerClient, TeamPickerScreen, TeamPickerLayout, PhoneLayout, UiKit, MenuOpenClaims
with the REAL HudClient and the rest of tools/hud_layout_check.py's lobby HUD, in its mock world), at every
size the HUD, menu and results checks use plus two console screens, in a team mode's Loading:
  overlap     the panel touches no drawn HUD element (measured), nor Roblox's top bar, the chat window,
              the MENU stack or coin chip (from MenuClient and MenuStackToggle's own numbers), nor, on a
              touch screen, any lobby rect PhoneLayout gives or Roblox's jump button and thumbstick
  text        every text in it is at least 12 px
  fits        the panel and everything in it are on screen, under the top bar, and inside a notched
              phone's safe area when there is one
  gamepad     the focus starts on AUTO, moves card -> card -> AUTO and back, and A/B/L1/R1 and 1/2/3 send
              the right pick; the keycaps follow the input
  no BR       a battle royale snapshot draws nothing, and the vote is never up with it
"""

import os
import random
import re
import sys

from lupa import LuaRuntime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hud_layout_check as H  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RULES = "ReplicatedStorage/Shared/TeamPickerRules.lua"
PICKER = "ServerScriptService/Modules/TeamPicker.lua"
RATELIMIT = "ServerScriptService/Modules/RateLimit.lua"
MODETEAMS = "ServerScriptService/Modules/ModeTeams.lua"
MATCH = "ServerScriptService/Modules/MatchService.lua"
BOOT = "ServerScriptService/Bootstrap.server.lua"
LAYOUT = "StarterPlayerScripts/TeamPickerLayout.lua"
SCREEN = "StarterPlayerScripts/TeamPickerScreen.lua"
CLIENT = "StarterPlayerScripts/TeamPickerClient.client.lua"
MENU = "StarterPlayerScripts/MenuClient.client.lua"
STACK = "StarterPlayerScripts/MenuStackToggle.lua"
HUD = "StarterPlayerScripts/HudClient.client.lua"
VOTEDROP = "StarterPlayerScripts/VoteDropClient.client.lua"


def read(path, overrides=None):
    if overrides and path in overrides:
        return overrides[path]
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def lua_src(text):
    return H.luau_to_lua(text)


# ---------------------------------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------------------------------

SERVER_ENV = r"""
local sources = ...
local W = { clock = 1000, sent = {}, delayed = {}, warnings = {} }
local modules = {}
local function loadModule(name, env)
	local chunk, err = load(sources[name], "=" .. name, "t", env)
	if not chunk then error("compile " .. name .. ": " .. tostring(err)) end
	return chunk()
end
local function folder(kind)
	return { WaitForChild = function(_, name) return { __module = name, __kind = kind } end,
		FindFirstChild = function(_, name) return { __module = name, __kind = kind } end }
end
local signal = function() return { Connect = function() return { Disconnect = function() end } end } end
local services = {
	Players = { PlayerRemoving = signal(), GetPlayers = function() return {} end },
	ReplicatedStorage = { WaitForChild = function(_, name) return folder("shared") end },
	RunService = { IsServer = function() return true end, Heartbeat = signal() },
}
local game = { GetService = function(_, name) return services[name] or {} end }
local env
local function req(target)
	local name = target.__module
	if modules[name] ~= nil then return modules[name] end
	local result
	if name == "Remotes" then
		result = { Event = function(n) return { FireClient = function(_, p, s) table.insert(W.sent, { n, p, s }) end,
			FireAllClients = function() end, OnServerEvent = signal() } end }
	elseif name == "MatchConfig" then
		result = { TeamPickSeconds = 12 }
	else
		result = loadModule(name, env)
	end
	modules[name] = result
	return result
end
local function color(r, g, b) return { R = r, G = g, B = b, Lerp = function(self) return self end } end
env = setmetatable({
	table = setmetatable({ clear = function(t) for k in pairs(t) do t[k] = nil end end }, { __index = table }),
	Color3 = { fromRGB = function(r, g, b) return color(r / 255, g / 255, b / 255) end, new = color },
	game = game,
	script = { Parent = folder("server") },
	require = req,
	typeof = function(v) return type(v) end,
	warn = function(...) table.insert(W.warnings, table.concat({ ... }, " ")) end,
	tick = function() return W.clock end,
	DateTime = { now = function() return { UnixTimestampMillis = W.clock * 1000 } end },
	task = {
		wait = function(s) W.clock = W.clock + (s or 0) end,
		delay = function(s, fn) table.insert(W.delayed, { at = W.clock + s, fn = fn }) return {} end,
		spawn = function(fn, ...) fn(...) end,
	},
}, { __index = _G })
W.req = req
W.env = env
W.modules = modules
return W
"""

SERVER_TESTS = r"""
local W, rng, fuzzRuns = ...
local fails = {}
local function fail(msg) table.insert(fails, msg) end
local Rules = W.req({ __module = "TeamPickerRules" })
local GameModes = W.req({ __module = "GameModes" })
local TeamPicker = W.req({ __module = "TeamPicker" })
local RateLimit = W.req({ __module = "RateLimit" })
TeamPicker.Clock = function() return W.clock end
TeamPicker.Wait = function(s) W.clock = W.clock + s end
local handed = nil
TeamPicker.ModeTeams = { SetPicks = function(map) handed = map end }
local TDM, KOTH, BR = GameModes.Get("TeamDeathmatch"), GameModes.Get("KingOfTheHill"), GameModes.Get("BattleRoyale")
local function humans(n)
	local list = {}
	for i = 1, n do list[i] = { Name = "P" .. i, DisplayName = "Player" .. i } end
	return list
end
local function split(sides, list)
	local c = { 0, 0 }
	for _, p in ipairs(list) do
		local t = sides[p]
		if t ~= 1 and t ~= 2 then return nil end
		c[t] = c[t] + 1
	end
	return c
end

-- balance: 4 humans, cap 2
do
	local list = humans(4)
	if not TeamPicker.Open(list, 30, TDM) then fail("balance: Open refused a team mode") end
	local a = TeamPicker.Pick(list[1], 1)
	local b = TeamPicker.Pick(list[2], 1)
	local c, why = TeamPicker.Pick(list[3], 1)
	if not (a and b) then fail("balance: two picks of one side refused with a cap of 2") end
	if c or why ~= "full" then fail("balance: a third human was let onto a side of 4 humans (" .. tostring(why) .. ")") end
	if not TeamPicker.Pick(list[3], 2) then fail("balance: the open side refused") end
	local snap = TeamPicker.Snapshot(list[4])
	if not snap.teams[1].full or snap.teams[2].full then fail("balance: snapshot 'full' flags wrong") end
	if snap.teams[1].size + snap.teams[2].size ~= 30 then fail("balance: sides do not add up to the match") end
	if snap.teams[1].bots + snap.teams[1].projected ~= snap.teams[1].size then fail("balance: bots do not fill side 1") end
	local sides = TeamPicker.Close()
	local c2 = split(sides, list)
	if not c2 or math.abs(c2[1] - c2[2]) > 1 then fail("balance: 4 humans closed uneven") end
	if sides[list[4]] ~= 2 then fail("auto: the undecided player was not dealt onto the side with fewer humans") end
	if handed ~= sides then fail("hand-off: Close did not hand the sides to ModeTeams.SetPicks") end
end

-- a party of three fills one side of six while there is room, the fourth is refused
do
	local list = humans(6)
	TeamPicker.Open(list, 30, KOTH)
	for i = 1, 3 do
		if not TeamPicker.Pick(list[i], 2) then fail("party: friend " .. i .. " refused a side with room") end
	end
	if TeamPicker.Pick(list[4], 2) then fail("party: a 4th human onto a side of 6 humans") end
	local sides = TeamPicker.Close()
	local c = split(sides, list)
	if not c or c[1] ~= 3 or c[2] ~= 3 then fail("party: 6 humans did not close 3/3") end
end

-- timeout: Run waits out the reveal, ends on the deadline, stale picks refused
do
	local list = humans(3)
	local start = W.clock
	local ticks = {}
	local picker = TeamPicker
	local openedAt = nil
	local realOpen = picker.Open
	picker.Open = function(...) openedAt = W.clock return realOpen(...) end
	local sides = picker.Run(list, 30, TDM, start + picker.RevealGuard, function(left) table.insert(ticks, left) end)
	picker.Open = realOpen
	if not openedAt or openedAt < start + picker.RevealGuard - 1e-6 then fail("timeout: opened before the vote's reveal was over") end
	if W.clock < openedAt + picker.Seconds - 1e-6 then fail("timeout: closed before its deadline") end
	if W.clock > openedAt + picker.Seconds + 0.5 then fail("timeout: ran past its deadline") end
	if #ticks < picker.Seconds then fail("timeout: the countdown ticked " .. #ticks .. " times for " .. picker.Seconds .. " s") end
	local c = split(sides or {}, list)
	if not c or math.abs(c[1] - c[2]) > 1 then fail("timeout: players left undecided were not all dealt, evenly") end
	local ok, why = picker.Pick(list[1], 1)
	if ok or why ~= "closed" then fail("timeout: a pick after Close was taken (" .. tostring(why) .. ")") end
	-- past the deadline but before Close
	picker.Open(list, 30, TDM)
	W.clock = W.clock + picker.Seconds + 0.01
	ok, why = picker.Pick(list[1], 1)
	if ok or why ~= "stale" then fail("timeout: a pick after the deadline was taken (" .. tostring(why) .. ")") end
	picker.Close()
	-- everyone picked: the window closes after the grace, not the full count
	picker.Open(list, 30, TDM)
	local t0 = W.clock
	picker.Pick(list[1], 1) picker.Pick(list[2], 2) picker.Pick(list[3], 1)
	if picker.SecondsLeft() > picker.AllPickedGrace + 1e-6 then fail("timeout: everyone picked and the full count still runs") end
	picker.Close()
end

-- rate limit: a burst is held, and the held pick is refused once the window has closed
do
	if not RateLimit.Budgets.PickTeam then fail("rate limit: no PickTeam budget") end
	RateLimit.Now = function() return W.clock end
	local list = humans(2)
	TeamPicker.Open(list, 30, TDM)
	local applied, results = 0, {}
	local burst = (RateLimit.Budgets.PickTeam or { burst = 4 }).burst
	for i = 1, burst + 3 do
		RateLimit.Latest(list[1], "PickTeam", (i % 2) + 1, function(team)
			applied = applied + 1
			table.insert(results, { TeamPicker.Pick(list[1], team) })
		end)
	end
	if applied > burst then fail("rate limit: " .. applied .. " picks applied from a burst of " .. (burst + 3)) end
	if #W.delayed == 0 then fail("rate limit: nothing held back from the burst") end
	TeamPicker.Close()
	for _, d in ipairs(W.delayed) do d.fn() end
	local last = results[#results]
	if applied <= burst or not last or last[1] ~= false then fail("rate limit: the held pick landed after the window closed") end
	W.delayed = {}
end

-- leavers: 3 humans, 2 on one side, one leaves the other -> cap 1, newest pick bumped to AUTO
do
	local list = humans(3)
	TeamPicker.Open(list, 30, TDM)
	TeamPicker.Pick(list[1], 1)
	TeamPicker.Pick(list[2], 2)
	TeamPicker.Forget(list[2])
	TeamPicker.Pick(list[3], 1)
	local before = TeamPicker.PickOf(list[3])
	-- 2 humans left, both on side 1? the cap is 1, so the second is refused
	if before == 1 then fail("leavers: a side took 2 of 2 humans") end
	local list2 = humans(4)
	TeamPicker.Open(list2, 30, TDM)
	TeamPicker.Pick(list2[1], 1) TeamPicker.Pick(list2[2], 1)
	TeamPicker.Forget(list2[3]) TeamPicker.Forget(list2[4])
	if TeamPicker.PickOf(list2[1]) ~= 1 or TeamPicker.PickOf(list2[2]) ~= 0 then
		fail("leavers: the cap dropped to 1 and the newest pick was not sent back to AUTO")
	end
	TeamPicker.Close()
end

-- the battle royale never opens it
do
	local before = #W.sent
	if TeamPicker.Open(humans(4), 50, BR) then fail("no BR: Open accepted the battle royale") end
	if TeamPicker.Run(humans(4), 50, BR, 0) ~= nil then fail("no BR: Run ran for the battle royale") end
	if #W.sent ~= before then fail("no BR: a snapshot went out for the battle royale") end
	if Rules.ShowsFor(BR) then fail("no BR: ShowsFor(BattleRoyale) is true") end
	if not (Rules.ShowsFor(TDM) and Rules.ShowsFor(KOTH)) then fail("ShowsFor misses a team mode") end
end

-- fuzz: random picks, switches, AUTOs and leaves always close within one human, everyone placed
for run = 1, fuzzRuns do
	local n = rng(1, 16)
	local list = humans(n)
	TeamPicker.Open(list, math.max(n, 30), TDM)
	local here = {}
	for i = 1, n do here[i] = list[i] end
	for _ = 1, rng(0, 40) do
		local r = rng(1, 10)
		if r == 1 and #here > 1 then
			local gone = table.remove(here, rng(1, #here))
			TeamPicker.Forget(gone)
		else
			local who = here[rng(1, #here)]
			TeamPicker.Pick(who, rng(0, 2))
		end
		-- the rule holds at every step, not only at the end
		local counts = Rules.Counts((function()
			local m = {}
			for _, p in ipairs(here) do local t = TeamPicker.PickOf(p) if t ~= 0 then m[p] = t end end
			return m
		end)())
		local cap = Rules.HumanCap(#here)
		if counts[1] > cap or counts[2] > cap then
			fail(string.format("fuzz %d: a side holds %d picks over a cap of %d", run, math.max(counts[1], counts[2]), cap))
			break
		end
	end
	local sides = TeamPicker.Close()
	local c = split(sides, here)
	if not c then
		fail("fuzz " .. run .. ": a human was left without a side")
	elseif math.abs(c[1] - c[2]) > 1 then
		fail(string.format("fuzz %d: closed %d / %d", run, c[1], c[2]))
	end
	if #fails > 8 then break end
end
return fails
"""

# ModeTeams: Counts, the TEAM PICKER block, Assign, Forget and AssignTo -- the real text.
MODETEAMS_ENV = r"""
local src = ...
local teamOf = {}
local protectedUntil, downed = {}, {}
local nextTeam = 1
local ModeTeams = {}
local GameModes = { OtherTeam = function(i) if i == 1 then return 2 elseif i == 2 then return 1 end end }
local Combatants = { GetCharacter = function() return nil end }
local env = setmetatable({ ModeTeams = ModeTeams, GameModes = GameModes, Combatants = Combatants }, { __index = _G })
local chunk, err = load("local teamOf, protectedUntil, downed, nextTeam, ModeTeams, GameModes, Combatants = ... \n" .. src, "=ModeTeams", "t", env)
if not chunk then error(err) end
chunk(teamOf, protectedUntil, downed, nextTeam, ModeTeams, GameModes, Combatants)
return ModeTeams
"""

MODETEAMS_TESTS = r"""
local M = ...
local fails = {}
local function fail(m) table.insert(fails, m) end
-- 3 humans picked 1,1,2; 27 bots, EVERY bot dealt before any human's body arrives
local p = { {}, {}, {} }
M.SetPicks({ [p[1]] = 1, [p[2]] = 1, [p[3]] = 2 })
local bots = {}
for i = 1, 27 do bots[i] = {} M.Assign(bots[i]) end
for i = 1, 3 do M.Assign(p[i]) end
if M.TeamOf(p[1]) ~= 1 or M.TeamOf(p[2]) ~= 1 or M.TeamOf(p[3]) ~= 2 then fail("hand-off: a picked player was not put on their side") end
local c = M.Counts()
if math.abs(c[1] - c[2]) > 1 then fail(string.format("hand-off: bots did not fill round the picks: %d / %d", c[1], c[2])) end
-- a late joiner, no pick: the smaller side
local late = {}
local smaller = (c[1] < c[2]) and 1 or ((c[2] < c[1]) and 2 or nil)
M.Assign(late)
if smaller and M.TeamOf(late) ~= smaller then fail("late joiner: not dealt onto the smaller side") end
-- a leaver's unused pick stops counting as a seat
M.SetPicks({ [{}] = 1 })
local ghost = {}
M.SetPicks({ [ghost] = 1 })
M.Forget(ghost)
if M.PickOf(ghost) ~= nil then fail("hand-off: Forget left a leaver's pick behind") end
return fails
"""


def modeteams_region(src):
    """Counts, then the TEAM PICKER block through AssignTo -- the shipped text, sliced out by its markers."""
    counts = re.search(r"function ModeTeams\.Counts\(\).*?\nend\n", src, re.S)
    team_of = re.search(r"function ModeTeams\.TeamOf\(token\).*?\nend\n", src, re.S)
    start = src.find("-- BEGIN TEAM PICKER")
    forget = re.search(r"function ModeTeams\.Forget\(token\).*?\nend\n", src, re.S)
    if not (counts and team_of and forget) or start < 0 or forget.start() < start:
        return None
    return team_of.group(0) + counts.group(0) + src[start:forget.end()]


def server_checks(overrides=None, fuzz=600):
    fails = []
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = {
        "TeamPickerRules": lua_src(read(RULES, overrides)),
        "TeamPicker": lua_src(read(PICKER, overrides)),
        "RateLimit": lua_src(read(RATELIMIT, overrides)),
        "GameModes": lua_src(read("ReplicatedStorage/Shared/GameModes.lua", overrides)),
        "Rarity": lua_src(read("ReplicatedStorage/Shared/Rarity.lua", overrides)),
    }
    W = lua.execute(SERVER_ENV, lua.table_from(sources))
    rnd = random.Random(1234)
    got = lua.execute(SERVER_TESTS, W, lambda a, b: rnd.randint(int(a), int(b)), fuzz)
    fails += list(got.values())

    region = modeteams_region(read(MODETEAMS, overrides))
    if not region:
        fails.append("hand-off: ModeTeams has no TEAM PICKER block before Forget")
    else:
        lua2 = LuaRuntime(unpack_returned_tuples=True)
        M = lua2.execute(MODETEAMS_ENV, lua_src(region))
        fails += list(lua2.execute(MODETEAMS_TESTS, M).values())

    # Wiring the harness cannot run: the remote goes through RateLimit, and MatchService runs the
    # picker only for a mode with sides, after the drop window and before anyone is placed.
    boot = read(BOOT, overrides)
    m = re.search(r'Remotes\.Event\("PickTeam"\)\.OnServerEvent:Connect\(function\(player, team\)(.*?)\nend\)', boot, re.S)
    if not m or 'RateLimit.Latest(player, "PickTeam"' not in m.group(1) or "TeamPicker.Pick" not in m.group(1):
        fails.append("rate limit: Bootstrap's PickTeam handler does not go through RateLimit to TeamPicker.Pick")
    match = read(MATCH, overrides)
    gate = re.search(r"\n\tif currentMode\.teams then\n\t\tteamSelect = true\n(.*?)\n\tend\n", match, re.S)
    if not gate or "TeamPicker.Run" not in gate.group(1):
        fails.append("no BR: MatchService does not gate TeamPicker.Run on currentMode.teams")
    else:
        place = match.find("currentMode.StartWorld(mapInfo)", gate.end())
        if place < 0:
            fails.append("hand-off: the team picker does not run before StartWorld places anyone")
    if "revealUntil" not in match or "TeamPicker.RevealGuard" not in match:
        fails.append("vote: MatchService does not hold the picker until the vote's reveal is over")
    reveal = re.search(r"local REVEAL_SECONDS = ([\d.]+)", read(VOTEDROP, overrides))
    guard = re.search(r"TeamPicker\.RevealGuard = ([\d.]+)", read(PICKER, overrides))
    if not reveal or not guard or float(guard.group(1)) <= float(reveal.group(1)):
        fails.append("vote: TeamPicker.RevealGuard is not longer than VoteDropClient's REVEAL_SECONDS")
    return fails


# ---------------------------------------------------------------------------------------------------
# Screen
# ---------------------------------------------------------------------------------------------------

# Every size the HUD check, the menu check and the results check use, and two console screens.
SIZES = [(tag, w, h, touch, "touch" if touch else "keyboard") for tag, w, h, touch in H.SIZES] + [
    ("phone-small 320x640", 320, 640, True, "touch"),
    ("phone on its side 640x360", 640, 360, True, "touch"),
    ("console 1920x1080", 1920, 1080, False, "gamepad"),
    ("console 1280x720", 1280, 720, False, "gamepad"),
]

SNAP = r"""
local mode, names1, names2 = ...
local function roster(n, prefix, meAt)
	local list = {}
	for i = 1, n do list[i] = { name = prefix .. "_DisplayNameThatIsLong_" .. i, me = i == meAt } end
	return list
end
return {
	open = true, mode = mode, secondsLeft = 9, seconds = 12, cap = 8, humans = 16, total = 30, undecided = 3,
	mine = 0, autoSide = 2,
	teams = {
		{ picked = names1, roster = roster(math.min(names1, 8), "Ember", 2), more = math.max(0, names1 - 8) + 4, bots = 7,
			size = 15, projected = 8, full = names1 >= 8 },
		{ picked = names2, roster = roster(math.min(names2, 8), "Teal", 0), more = 0, bots = 7, size = 15,
			projected = 8, full = false },
	},
}
"""

PLAY = r"""
local mode, input = select(2, ...)
W.player.Character = W.character
W.character.Parent = W.workspace
local added = rawget(W.player, '__lazy').CharacterAdded
if added then added:Fire(W.character) end
if input == 'gamepad' then
	W.UserInputService.GamepadEnabled = true
	W.lastInput = 'Gamepad1'
end
W.picks = {}
local pick = W.remotes.PickTeam or nil
W.fire('ProfileChanged', { companion = 'Tralalero Tralala', brainrots = {} })
W.fire('MatchChanged', { state = 'Loading', mode = mode, countdown = 9, teamSelect = mode ~= 'BattleRoyale',
	minPlayers = 2, playerCount = 16, aliveCount = 30 })
W.frame(2)
"""


def screen_world(size, overrides=None, notch=None):
    tag, w, h, touch, input_kind = size
    sources = {n: read("StarterPlayerScripts/" + n, overrides) for n in H.SCRIPTS}
    for m in H.MODULES + H.EYE_MODULES:
        sources[m + ".lua"] = read("StarterPlayerScripts/" + m + ".lua", overrides)
    for m in ("TeamPickerLayout", "TeamPickerScreen", "MenuOpenClaims"):
        sources[m + ".lua"] = read("StarterPlayerScripts/" + m + ".lua", overrides)
    sources["TeamPickerClient.client.lua"] = read(CLIENT, overrides)
    shared = {n: read("ReplicatedStorage/Shared/" + n + ".lua", overrides) for n in ("GameModes", "Rarity", "TeamPickerRules")}
    world = H.World(ROOT, (tag, w, h, touch), sources, shared=shared,
                    extra_modules=("TeamPickerLayout", "TeamPickerScreen", "MenuOpenClaims"))
    return world


def picker_client(world):
    world.W.runScript("TeamPickerClient.client")


LUA_MEASURE = r"""
-- The picker's panel (TeamPickerUi's drawn element), every text in it, and the safe probe.
local out = { texts = {}, spill = {}, panel = nil, focus = nil, graph = {}, keys = {} }
local gui = W.playerGui:FindFirstChild('TeamPickerUi')
if not gui then return out end
local panel = gui:FindFirstChild('TeamPicker')
if not panel or not panel.Visible then return out end
local r = W.rectOf(panel)
out.panel = { x = r.x, y = r.y, w = r.w, h = r.h }
out.scale = panel:GetAttribute('Scale')
out.variant = panel:GetAttribute('Variant')
out.readable = panel:GetAttribute('Readable')
local function shown(inst)
	local node = inst
	while node and node ~= gui do
		if node.Visible == false then return false end
		node = node.Parent
	end
	return true
end
for _, inst in ipairs(panel:GetDescendants()) do
	local cls = W.instClass(inst)
	if (cls == 'TextLabel' or cls == 'TextButton') and shown(inst) and (inst.Text or '') ~= '' then
		table.insert(out.texts, { text = inst.Text, size = inst.TextSize })
	end
	if (cls == 'Frame' or cls == 'TextLabel' or cls == 'TextButton') and shown(inst) and (inst.Rotation or 0) == 0 then
		local c = W.rectOf(inst)
		if c and c.w > 0 and c.h > 0 and (c.x < r.x - 0.5 or c.y < r.y - 0.5 or c.x + c.w > r.x + r.w + 0.5 or c.y + c.h > r.y + r.h + 0.5) then
			table.insert(out.spill, inst.Name .. string.format(' (%d,%d %dx%d)', c.x, c.y, c.w, c.h))
		end
	end
end
local gs = W.game:GetService('GuiService')
local sel = gs.SelectedObject
out.focus = sel and sel.Name or nil
local t1, t2, auto = panel:FindFirstChild('Team1'), panel:FindFirstChild('Team2'), panel:FindFirstChild('Auto')
local function nm(x) return x and x.Name or 'nil' end
if t1 and t2 and auto then
	out.graph = {
		t1R = nm(t1.NextSelectionRight), t2L = nm(t2.NextSelectionLeft), t1D = nm(t1.NextSelectionDown),
		t2D = nm(t2.NextSelectionDown), t2U = nm(t2.NextSelectionUp), autoU = nm(auto.NextSelectionUp),
		t1U = nm(t1.NextSelectionUp), autoD = nm(auto.NextSelectionDown),
		sel = tostring(t1.Selectable) .. tostring(t2.Selectable) .. tostring(auto.Selectable),
	}
	local k1 = t1:FindFirstChild('Keycap', true)
	local ka = auto:FindFirstChild('Keycap', true)
	out.keys = { card = k1 and k1.Visible and k1:FindFirstChild('Key') and k1:FindFirstChild('Key').Text or '',
		auto = ka and ka.Visible and ka:FindFirstChild('Key') and ka:FindFirstChild('Key').Text or '' }
end
return out
"""


def zones_independent(world, w, h, touch):
    """What the picker must not touch, from the owners' own sources, NOT from TeamPickerLayout."""
    inset = float(world.run("return W.inset"))
    zones = [("top bar", 0, 0, w, inset)]
    # Roblox's default chat window, top-left under the bar (TextChatService), open from the start on a
    # desktop screen: about 400 x 250. On a touch screen chat starts closed behind its top-bar button
    # (PhoneLayout's topBar below); an OPEN phone chat window is the "live chat" case in notch_checks.
    if not touch:
        zones.append(("chat", 0, inset, min(400, w * 0.5), 250))
    if touch:
        rects = world.run("""
            local pl = require(W.scriptsFolder:WaitForChild('PhoneLayout'))
            local out = {}
            for k, v in pairs(pl.Rects(W.viewport)) do
                if type(v) == 'table' and v.w then out[k] = { v.x, v.y, v.w, v.h } end
            end
            return out
        """)
        # (The ready button and the event pill are down in Loading; if either is drawn, the measured
        # overlap check above sees it.)
        for name in ("topBar", "menu", "stackTab", "cam", "banner", "coins", "companion", "petIcon",
                     "jump", "stick"):
            r = rects[name] if name in rects else None
            if r is not None:
                zones.append((name, r[1], r[2], r[3], r[4]))
    else:
        menu = read(MENU)
        stack = read(STACK)
        hud = read(HUD)
        cm = re.search(r"local coinChip = create\(\"Frame\", \{\s*Position = UDim2\.new\(0, (\d+), 0, (\d+)\),\s*Size = UDim2\.new\(0, (\d+), 0, (\d+)\)", menu)
        st = re.search(r"local STACK_TOP = (\d+)\s*\nlocal STACK_SIZE = Vector2\.new\((\d+), (\d+)\)", stack)
        bn = re.search(r"local banner = create\(\"Frame\", \{\s*AnchorPoint = Vector2\.new\(0\.5, 0\),\s*Position = UDim2\.new\(0\.5, 0, 0, (\d+)\),\s*Size = UDim2\.new\(0, (\d+), 0, (\d+)\)", hud)
        rd = re.search(r"local readyButton = create\(\"TextButton\", \{\s*Position = UDim2\.new\(0\.5, (\d+), 0, (\d+)\),\s*Size = UDim2\.fromOffset\((\d+), (\d+)\)", hud)
        if not (cm and st and bn and rd):
            return None
        x, y, cw, ch = map(int, cm.groups())
        zones.append(("coin chip", x, y + inset, cw, ch))
        top, sw, sh = map(int, st.groups())
        zones.append(("MENU stack", 0, top + inset, sw, min(sh, h - top - inset)))
        by, bw, bh = map(int, bn.groups())
        zones.append(("banner", w / 2 - bw / 2, by, bw, bh))
        rx, ry, rw, rh = map(int, rd.groups())
        zones.append(("ready", w / 2 + rx, ry, rw, rh))
    return zones


def overlap(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw - 0.5 and bx < ax + aw - 0.5 and ay < by + bh - 0.5 and by < ay + ah - 0.5


def screen_checks(overrides=None, sizes=SIZES, report=None):
    fails = []
    for size in sizes:
        tag, w, h, touch, input_kind = size
        world = screen_world(size, overrides)
        world.run(PLAY, "TeamDeathmatch", input_kind)
        picker_client(world)
        world.run("""
            local fired = {}
            W.pickLog = fired
            local r = W.remotes['PickTeam']
            if r then r.FireServer = function(_, t) table.insert(fired, t) end end
        """)
        # The HUD without the picker, measured first: what is on screen when it opens.
        names = H.site_names({})
        snap = world.lua.execute(SNAP, "TeamDeathmatch", 7, 5)
        world.run("W.fire('TeamPickerChanged', select(2, ...)) ; W.frame(2) ; W.advance(0.1) ; W.frame(1)", snap)
        errs, _ = world.errors()
        for e in errs:
            if "TeamPicker" in e:
                fails.append(f"[{tag}] error: {e[:240]}")
        m = world.run(LUA_MEASURE)
        if m.panel is None:
            fails.append(f"[{tag}] the picker is not drawn for a team mode")
            continue
        p = (m.panel.x, m.panel.y, m.panel.w, m.panel.h)
        if report is not None:
            report.append(f"  {tag:30} panel {p[2]:4.0f}x{p[3]:4.0f} at ({p[0]:4.0f},{p[1]:4.0f}), {m.variant} x{m.scale:.2f}")
        if not m.readable:
            fails.append(f"[{tag}] no room for a readable picker: {m.variant} at x{m.scale:.2f} puts text under 12 px")
        # overlap: every drawn element of every other ScreenGui
        for e in world.drawn(names):
            if e["gui"] in ("TeamPickerUi", "TeamPickerSafeArea") or e["full"]:
                continue
            for part in e["parts"]:
                if overlap(p, part):
                    fails.append(f"[{tag}] overlaps the HUD's {e['name']} ({e['gui']}) at {tuple(round(v) for v in part)}")
                    break
        zones = zones_independent(world, w, h, touch)
        if zones is None:
            fails.append(f"[{tag}] could not read the lobby HUD's numbers from MenuClient/MenuStackToggle/HudClient")
            zones = []
        for name, zx, zy, zw, zh in zones:
            if overlap(p, (zx, zy, zw, zh)):
                fails.append(f"[{tag}] overlaps {name} at {(round(zx), round(zy), round(zw), round(zh))}: panel {tuple(round(v) for v in p)}")
        # text
        for t in m.texts.values():
            if (t.size or 0) < 12:
                fails.append(f"[{tag}] text '{t.text}' is {t.size} px, under 12")
        # fits
        if p[0] < -0.5 or p[1] < -0.5 or p[0] + p[2] > w + 0.5 or p[1] + p[3] > h + 0.5:
            fails.append(f"[{tag}] the panel is partly off the screen: {p}")
        for s in m.spill.values():
            fails.append(f"[{tag}] {s} is outside the panel")
        # gamepad / keyboard
        g = m.graph
        tall = m.variant in ("tall", "compactTall")
        header = m.variant in ("compact", "compactTall")
        if header:
            want = {"t1U": "Auto", "autoD": "Team1"}
            want.update({"t2U": "Team1", "t1D": "Team2"} if tall else {"t1R": "Team2", "t2L": "Team1", "t2U": "Auto"})
        elif tall:
            want = {"t2U": "Team1", "t1D": "Team2", "t2D": "Auto", "autoU": "Team2"}
        else:
            want = {"t1R": "Team2", "t2L": "Team1", "t1D": "Auto", "t2D": "Auto", "autoU": "Team1"}
        for key, target in want.items():
            if g[key] != target:
                fails.append(f"[{tag}] focus order: {key} goes to {g[key]}, want {target}")
        if g["sel"] != "truetruetrue":
            fails.append(f"[{tag}] the cards and AUTO are not all selectable")
        if input_kind == "gamepad":
            if m.focus != "Auto":
                fails.append(f"[{tag}] the gamepad focus starts on {m.focus}, not AUTO")
            if m["keys"]["auto"] != "B":
                fails.append(f"[{tag}] AUTO's keycap reads '{m["keys"]['auto']}' on a gamepad, not B")
            presses = ["ButtonL1", "ButtonR1", "ButtonB"]
            want_picks = [1, 2, 0]
        elif input_kind == "keyboard":
            if m["keys"]["card"] != "1" or m["keys"]["auto"] != "3":
                fails.append(f"[{tag}] the keycaps read '{m["keys"]['card']}'/'{m["keys"]['auto']}', not 1/3")
            presses = ["One", "Two", "Three"]
            want_picks = [1, 2, 0]
        else:
            if m["keys"]["card"] or m["keys"]["auto"]:
                fails.append(f"[{tag}] keycaps drawn on a touch screen")
            presses, want_picks = [], []
        if presses:
            got = world.run("""
                local keys = select(2, ...)
                local uit = W.lastInput and Enum.UserInputType.Gamepad1 or Enum.UserInputType.Keyboard
                for i = 1, #keys do
                    local k = keys[i]
                    W.UserInputService.InputBegan:Fire({ KeyCode = Enum.KeyCode[k], UserInputType = uit }, false)
                end
                local out = {}
                for i, v in ipairs(W.pickLog) do out[i] = v end
                return out
            """, world.lua.table_from(presses))
            got = list(got.values())
            if got != want_picks:
                fails.append(f"[{tag}] {input_kind} presses {presses} sent {got}, want {want_picks}")
        # The battle royale: a snapshot for it draws nothing.
        br = screen_world(size, overrides)
        br.run(PLAY, "BattleRoyale", input_kind)
        picker_client(br)
        br.run("W.fire('TeamPickerChanged', select(2, ...)) ; W.frame(2) ; W.advance(0.1) ; W.frame(1)", br.lua.execute(SNAP, "BattleRoyale", 3, 3))
        if br.run(LUA_MEASURE).panel is not None:
            fails.append(f"[{tag}] the picker is drawn in the battle royale")
        if len(fails) > 40:
            break
    return fails


# A notched phone: the layout alone, with the device's safe area pulled in, must keep the panel inside it.
NOTCH = r"""
local src, pl = ...
local L = load(src, '=TeamPickerLayout', 't', setmetatable({ workspace = { CurrentCamera = nil } }, { __index = _G }))()
local out = {}
local cases = {
	{ 844, 390, 47, 0, 47, 21 }, { 932, 430, 59, 0, 59, 21 }, { 390, 844, 0, 47, 0, 34 }, { 1024, 768, 0, 24, 0, 20 },
}
for _, c in ipairs(cases) do
	local vp = { X = c[1], Y = c[2] }
	local safe = L.rect(c[3], c[4], c[1] - c[3] - c[5], c[2] - c[4] - c[6])
	local fit = L.Compute(vp, { inset = 58, touch = true, safe = safe, phone = nil })
	local p = fit.panel
	if p.x < safe.x - 0.5 or p.y < safe.y - 0.5 or p.x + p.w > safe.x + safe.w + 0.5 or p.y + p.h > safe.y + safe.h + 0.5 then
		table.insert(out, string.format('notch %dx%d: panel (%d,%d %dx%d) leaves the safe area (%d,%d %dx%d)', c[1], c[2], p.x, p.y, p.w, p.h, safe.x, safe.y, safe.w, safe.h))
	end
	if p.y < 58 then table.insert(out, string.format('notch %dx%d: panel under the top bar', c[1], c[2])) end
	-- The same phone with its chat window open (the live rect TeamPickerClient reads): kept clear of it.
	local chat = L.rect(safe.x, 58, math.floor(c[1] * 0.4), math.floor(c[2] * 0.35))
	local open = L.Compute(vp, { inset = 58, touch = true, safe = safe, chat = chat })
	if L.intersects(open.panel, chat) then
		table.insert(out, string.format('live chat %dx%d: panel (%d,%d %dx%d) over the open chat window', c[1], c[2], open.panel.x, open.panel.y, open.panel.w, open.panel.h))
	end
end
return out
"""


def notch_checks(overrides=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("Vector2 = { new = function(x, y) return { X = x, Y = y } end }")
    return list(lua.execute(NOTCH, lua_src(read(LAYOUT, overrides)), None).values())


def run_all(overrides=None, report=None, fuzz=600, sizes=SIZES):
    fails = []
    fails += server_checks(overrides, fuzz=fuzz)
    fails += notch_checks(overrides)
    fails += screen_checks(overrides, sizes=sizes, report=report)
    return fails


def plant(path, old, new):
    text = read(path)
    if old not in text:
        return None
    return {path: text.replace(old, new, 1)}


PLANTS = [
    ("the picker overlaps chat (no chat zone)",
     LAYOUT, '\tadd("chat", rect(chat.x, chat.y, chat.w, chat.h))\n', "\n"),
    ("picks allowed to make teams uneven (no cap)",
     RULES, "\tif counts[team] + 1 > TeamPickerRules.HumanCap(humanCount) then", "\tif false then"),
    ("the picker shown in the battle royale",
     RULES, 'return type(mode) == "table" and mode.teams == true and mode.id ~= "BattleRoyale"', 'return type(mode) == "table"'),
    ("a pick after the deadline accepted",
     PICKER, "\tif TeamPicker.Clock() >= deadline then\n\t\treturn false, \"stale\"", "\tif false then\n\t\treturn false, \"stale\""),
    ("undecided players all dealt to side 1",
     RULES, "\t\t\tif counts[1] < counts[2] then\n\t\t\t\tteam = 1", "\t\t\tif true then\n\t\t\t\tteam = 1"),
    ("ModeTeams ignores the picks",
     MODETEAMS, "\tlocal team = picks[token]\n", "\tlocal team = nil\n"),
    ("gamepad cannot reach AUTO",
     SCREEN, "c1.NextSelectionDown, c2.NextSelectionDown, auto.NextSelectionUp = auto, auto, c1",
     "c1.NextSelectionDown, c2.NextSelectionDown, auto.NextSelectionUp = nil, nil, c1"),
    ("the picker opens under the vote's reveal",
     PICKER, "TeamPicker.RevealGuard = 3.5", "TeamPicker.RevealGuard = 0"),
]


def main():
    if "--plant" in sys.argv:
        caught = 0
        quick = [s for s in SIZES if s[0] in ("desktop 1366x768", "phone 844x390", "phone upright 390x844", "console 1280x720")]
        for label, path, old, new in PLANTS:
            override = plant(path, old, new)
            if override is None:
                print(f"  PLANT ANCHOR MISSING: {label}")
                continue
            got = run_all(override, fuzz=150, sizes=quick)
            caught += bool(got)
            print(f"  {'CAUGHT' if got else 'MISSED'}: {label}" + (f" ({got[0][:150]})" if got else ""))
        print(f"team_picker_check plant: {caught} of {len(PLANTS)} planted faults caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    report = []
    fails = run_all(report=report)
    print(f"team_picker_check: server rules + hand-off + {len(SIZES)} screen sizes")
    for line in report:
        print(line)
    for f in fails:
        print("  FAIL: " + f)
    print(f"  {len(fails)} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
