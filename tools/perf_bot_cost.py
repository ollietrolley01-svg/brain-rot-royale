"""Per-frame server cost of the bots against the bot count N, before and after (#131/#126/#113/#99,
and the shared-infrastructure pass: spatial grid, ray budget, route sharing, LOD, pooled rows).

No Studio, so this counts WORK rather than milliseconds: it runs the real source of the hot paths
in a Lua interpreter (lupa) with Roblox mocked, once from a git revision (the "before", default
HEAD~1 of this file's first commit, pass --before REV) and once from the working tree, and counts
per frame:

  A  BotService.Start's think loop    bot thinks started in one frame, and each bot's think period
  B  BotService.findTarget            raycasts per bot think in a crowd where nobody can see anyone;
                                      candidates examined (hostile() asked) per think in a crowd and
                                      spread over a 1280-stud map; KB allocated per think
  C  BotNav.Pump                      ComputeAsync calls started in one pump, burst drain time
  D  CompanionService's Heartbeat     bot companions' target scans in one frame (each scan casts
                                      one ray per enemy in range when nobody is in sight)
  E  BotService.SpatialQuery          the uniform grid answers exactly what the linear scan did
  F  BotService.RaycastBudget         rays one frame of 13 cover searches casts, and the order in
                                      which the budget refuses idle, navigation and combat rays
  G  BotNav route sharing             ComputeAsync calls for N bots asking for one place
  H  BotService.LodDefers             think period of far-from-players idle bots against near,
                                      fighting and hurt ones

Every section also checks an invariant the fix must never break (each bot still thinks once a
BotThinkInterval; a target behind an enemy barricade is still engaged on every think; a destroyed
barricade stops hiding anyone; every queued route starts, urgent first; each companion still
thinks once a THINK_INTERVAL; the grid never misses a combatant in range; a sight ray is never
refused before a footing ray; a bot far from a shared route's start never adopts it; a fighting,
hurt or watched bot is never deferred), and --plant runs planted faults against the working tree,
every one of which must be caught.

    python tools/perf_bot_cost.py .                 before/after table and the checks
    python tools/perf_bot_cost.py . --plant         the planted faults; every one must be caught
    python tools/perf_bot_cost.py . --before REV    compare against another revision

Without git, or outside a checkout, there is no "before": it says so in one NOTE line and runs the
working tree's table and checks alone (bot_archetype_sim and bot_aggression_check, which read their
before through read_rev too, use the working tree as their own baseline).

What this does NOT measure: milliseconds. A raycast or a ComputeAsync start has no fixed cost
here; tools/perf_tick_probe.lua measures the worst server frame in Studio. The KB figure counts
the interpreter's allocations, Vector3 mocks included, so only its before/after difference means
anything.
"""

import math
import os
import re
import subprocess
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("perf_bot_cost: needs lupa (pip install lupa)")

BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
BOTNAV = "ServerScriptService/Modules/BotNav.lua"
COMPANION = "ServerScriptService/Modules/CompanionService.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def between(text, start, end, include_end=False):
    a = text.index(start)
    b = text.index(end, a + len(start))
    return text[a:b + (len(end) if include_end else 0)]


def has(text, *anchors):
    return all(anchor in text for anchor in anchors)


def read_tree(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read()


class NoRevision(Exception):
    """A "before" revision can't be read: git is not installed, `root` is not a checkout (a tarball, a
    zip), or the revision or the file isn't in it. The message says which."""


def read_rev(root, rev, path):
    try:
        return subprocess.run(["git", "-C", root, "show", f"{rev}:{path}"], capture_output=True, text=True,
                              check=True).stdout
    except FileNotFoundError:
        raise NoRevision("git is not installed") from None
    except subprocess.CalledProcessError as err:
        reason = (err.stderr or "").strip().splitlines()
        raise NoRevision(f"git show {rev}:{path}: {reason[0] if reason else 'failed'}") from None


def default_before(root, tool):
    """The commit before `tool`'s first commit; HEAD if it is not committed yet or git can't say."""
    try:
        log = subprocess.run(["git", "-C", root, "log", "--format=%H", "--diff-filter=A", "--", tool],
                             capture_output=True, text=True).stdout.split()
    except FileNotFoundError:
        log = []
    return (log[-1] + "~1") if log else "HEAD"


def no_before_note(tool, err):
    print(f"NOTE {tool}: no \"before\" revision to compare against ({err}); the before/after comparison is "
          f"skipped and only the working tree's own checks run.")


# Also imported by tools/bot_aggression_check.py: keep the names and the MatchConfig line below.
PRELUDE = r"""
local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); return Vector3.new(v.X / m, v.Y / m, v.Z / m) end
    return V[k]
end
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return Vector3.new(a.X * b, a.Y * b, a.Z * b)
end
V.__div = function(a, b) return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
V.__unm = function(a) return Vector3.new(-a.X, -a.Y, -a.Z) end
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }
Vector3.zero = Vector3.new(0, 0, 0)
Enum = setmetatable({}, { __index = function(_, k) return setmetatable({}, { __index = function(_, j) return k .. "." .. j end }) end })
RaycastParams = { new = function() return {} end }
OverlapParams = { new = function() return {} end }
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
math.clamp = math.clamp or function(x, a, b) return math.max(a, math.min(b, x)) end
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
CLOCK = 0
os.clock = function() return CLOCK end
tick = function() return CLOCK end
warn = function(...) print("warn", ...) end
-- task: spawn runs a coroutine; wait yields its delay to the driver.
task = {
    spawn = function(fn, ...)
        local entry = { co = coroutine.create(fn), wake = math.huge }
        THREADS[#THREADS + 1] = entry
        local ok, d = coroutine.resume(entry.co, ...)
        if not ok then error(d) end
        entry.wake = CLOCK + (d or 0)
    end,
    wait = function(d) return coroutine.yield(d or 0) end,
}
THREADS = {}
function stepThreads()
    for _, t in ipairs(THREADS) do
        if coroutine.status(t.co) == "suspended" and CLOCK >= t.wake - 1e-9 then
            local ok, d = coroutine.resume(t.co)
            if not ok then error(d) end
            t.wake = CLOCK + (d or 0)
        end
    end
end
-- The bot infrastructure a sliced-out region reaches for but does not define (BotService's ray
-- budget and LOD live outside the perception slice): pass-through defaults. Sections E, F and H
-- load the real ones over these.
BotService = { Tick = 0, LodDefers = function() return false end }
BotService.RaycastBudget = {
    BeginFrame = function() end,
    Folders = function() return {} end,
    Filter = function(filter, first) table.clear(filter); filter[1] = first; return filter end,
    LosParams = {}, LosFilter = {}, CoverParams = {}, CoverFilter = {}, ExposedParams = {}, ExposedFilter = {},
}
castRay = function(origin, direction, params, priority) return workspace:Raycast(origin, direction, params), true end
-- Nobody here rides a vehicle (hasLineOfSight asks whose car a target sits in).
VehicleCover = { SeatOf = function() return nil end }
"""

# --------------------------------------------------------------------------------------------
# A: the think loop
# --------------------------------------------------------------------------------------------

THINK_HARNESS = PRELUDE + r"""
local src, N, seconds = ...
running, loopGeneration = false, 0
MatchConfig = { BotThinkInterval = 0.25 }
STATS = { thinkTime = 0, thinkTicks = 0, updates = 0, maxTick = 0, maxTickWall = 0, maxBotUpdate = 0 }
local pumps = 0
BotNav = { Pump = function() pumps = pumps + 1 end }
refreshCombatants = function() end
local frame = 0
local perFrame, lastAt, periods = {}, {}, {}
updateBot = function(bot)
    perFrame[frame] = (perFrame[frame] or 0) + 1
    if lastAt[bot] then periods[#periods + 1] = CLOCK - lastAt[bot] end
    lastAt[bot] = CLOCK
    bot.thinks = (bot.thinks or 0) + 1
end
bots = {}
for i = 1, N do bots[i] = { id = i } end
local chunk = assert(load(src, "Start", "t", _ENV))
chunk()
BotService.Start()
local dt = 1 / 60
while CLOCK < seconds do
    CLOCK = CLOCK + dt
    frame = frame + 1
    stepThreads()
end
local worst = 0
for _, n in pairs(perFrame) do worst = math.max(worst, n) end
local pmin, pmax = math.huge, 0
for _, p in ipairs(periods) do pmin = math.min(pmin, p); pmax = math.max(pmax, p) end
local tmin, tmax = math.huge, 0
for _, b in ipairs(bots) do tmin = math.min(tmin, b.thinks or 0); tmax = math.max(tmax, b.thinks or 0) end
return worst, pmin, pmax, tmin, tmax, pumps / seconds
"""


def think_loop(lua_src, n, seconds=20.0):
    src = between(lua_src, "-- Bots think every BotThinkInterval", "function BotService.Clear()")
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(THINK_HARNESS, luau_to_lua(src), n, seconds)


# --------------------------------------------------------------------------------------------
# B: findTarget's rays, candidates and allocations
# --------------------------------------------------------------------------------------------

TARGET_HARNESS = PRELUDE + r"""
local src, N, scenario = ...
STATS = setmetatable({}, { __index = function() return 0 end })
MatchConfig = { BotVisionRange = 260, BotPlayerBias = 1.6, BotRearNoticeTime = 1.2 }
local hostileAsked = 0
hostile = function() hostileAsked = hostileAsked + 1; return true end
flat = function(v) return Vector3.new(v.X, 0, v.Z) end
flatLook = function() return Vector3.new(0, 0, 1) end
local rays = 0
local world = { IsDescendantOf = function() return false end }
local barricadePart = { IsDescendantOf = function() return false end }
local structure = { Name = "RotBarricade", Parent = true }
local barricadeUp = false
workspace = {
    FindFirstChild = function() return nil end,
    Raycast = function(_, origin, direction, params)
        rays = rays + 1
        if barricadeUp then return { Instance = barricadePart, Position = origin + direction * 0.5 } end
        return { Instance = world, Position = origin + direction * 0.5 }
    end,
}
CombatService = {
    GetLastAttacker = function() return nil end,
    StructureFromPart = function(part) if part == barricadePart then return structure end return nil end,
    DamageStructure = function() end,
}
DefenseService = { OwnerOf = function() return nil end }
local all = {}
Combatants = { All = function() return all end, IsPlayer = function() return false end }
local function makeBot(i, position)
    local root = { Position = position }
    local humanoid = { Health = 100, MaxHealth = 100 }
    local character = { Parent = true }
    character.FindFirstChild = function(_, name) if name == "HumanoidRootPart" then return root end end
    character.FindFirstChildOfClass = function() return humanoid end
    local bot = { id = i, character = character, root = root, head = root, lastHurtAt = -math.huge, weapon = { range = 100 },
        sight = {}, seen = {}, ownStructures = {} }
    all[character] = bot
    return bot
end
findTarget, refreshCombatants = assert(load(src, "findTarget", "t", _ENV))()

if scenario == "crowd" or scenario == "spread" then
    -- crowd: N bots within 60 studs of each other, walls between every pair: nobody can see anybody.
    -- spread: the same N over a 1280-stud map, on a lattice about 180 studs apart.
    local bots = {}
    local side = math.ceil(math.sqrt(N))
    for i = 1, N do
        if scenario == "crowd" then
            local a = i * 2.399963
            bots[i] = makeBot(i, Vector3.new(math.cos(a) * (i % 7) * 8, 0, math.sin(a) * (i % 7) * 8))
        else
            local gx, gz = (i - 1) % side, math.floor((i - 1) / side)
            bots[i] = makeBot(i, Vector3.new(-640 + (gx + 0.5) * 1280 / side, 0, -640 + (gz + 0.5) * 1280 / side))
        end
    end
    local worst, total, thinks, askedTotal = 0, 0, 0, 0
    collectgarbage("collect")
    collectgarbage("stop")
    local kbBefore = collectgarbage("count")
    for round = 1, 40 do
        CLOCK = round * 0.25
        refreshCombatants()
        for _, bot in ipairs(bots) do
            local before, asked = rays, hostileAsked
            findTarget(bot, bot.root, bot.head, CLOCK)
            worst = math.max(worst, rays - before)
            total = total + (rays - before)
            askedTotal = askedTotal + (hostileAsked - asked)
            thinks = thinks + 1
        end
    end
    local kb = (collectgarbage("count") - kbBefore) / thinks
    collectgarbage("restart")
    return worst, total / thinks, askedTotal / thinks, kb
end

-- "cover": one bot, one enemy 50 studs ahead behind an enemy barricade. Engaged through the cover
-- on every think while it stands; not once it is shot down.
local a = makeBot(1, Vector3.new(0, 0, 0))
local b = makeBot(2, Vector3.new(0, 0, 50))
barricadeUp = true
local engaged = {}
for round = 1, 5 do
    CLOCK = round * 0.25
    refreshCombatants()
    local c = findTarget(a, a.root, a.head, CLOCK)
    engaged[#engaged + 1] = (c ~= nil and c.throughCover == structure) and 1 or 0
end
-- Shot down between thinks: the ray now meets the wall behind where it stood.
structure.Parent = nil
barricadeUp = false
local after = 0
-- Round 6 falls inside round 5's sight cache, so it is answered from the cached row.
for round = 6, 8 do
    CLOCK = round * 0.25
    refreshCombatants()
    if findTarget(a, a.root, a.head, CLOCK) ~= nil then after = after + 1 end
end
return table.concat(engaged, ""), after
"""


def target_source(lua_src):
    src = between(lua_src, "local function hasLineOfSight", "-- Where a target was last seen")
    return luau_to_lua(src) + "\nreturn findTarget, refreshCombatants\n"


def find_target(lua_src, n, scenario):
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(TARGET_HARNESS, target_source(lua_src), n, scenario)


# --------------------------------------------------------------------------------------------
# C: BotNav.Pump (and G: route sharing, the same slice)
# --------------------------------------------------------------------------------------------

PUMP_HARNESS = PRELUDE + r"""
local src, N, pumpEvery, urgentEvery, shared = ...
-- Bot i asks with Urgent priority when i is a multiple of urgentEvery, Wander otherwise.
-- `shared`: every bot asks for ONE destination (route sharing, G); bot N-1 (wander priority, so it
-- is served after the first routes land) stands 100 studs from the rest and must compute its own.
-- After the burst a late bot asks from the crowd's spot and must have its route at once.
STATS = setmetatable({}, { __index = function() return 0 end })
BotNav = { Priority = { Urgent = 1, Combat = 2, Loot = 3, Wander = 4 } }
function BotNav.HasRoute(bot)
    local nav = bot.nav
    return nav ~= nil and nav.waypoints ~= nil and nav.index <= #nav.waypoints
end
REUSE_RADIUS = 10
AGENT = {}
inFlight, waiting = 0, {}
disconnectBlocked = function() end
flatDistance = function(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end
local startedThisPump, startOrder, computing = 0, {}, {}
local paths = {}
PathfindingService = { CreatePath = function()
    local path = { Status = "Enum.PathStatus.Success" }
    function path:ComputeAsync(from, to)
        startedThisPump = startedThisPump + 1
        startOrder[#startOrder + 1] = CURRENT_BOT
        coroutine.yield(0.1)
    end
    function path:GetWaypoints() return { { Position = Vector3.zero }, { Position = Vector3.new(250, 0, 0) }, { Position = Vector3.new(500, 0, 0) } } end
    path.Blocked = { Connect = function() return {} end }
    return path
end }
Enum.PathStatus = { Success = "Enum.PathStatus.Success" }
assert(load(src, "Pump", "t", _ENV))()
local bots = {}
for i = 1, N do
    local at = (shared and i == N - 1) and Vector3.new(100, 0, 0) or Vector3.zero
    local bot = { id = i, character = { Parent = true, GetPivot = function() return { Position = at } end },
        humanoid = { Health = 100 }, nav = { nextId = 0, failures = 0, index = 1 } }
    bot.urgent = (i % urgentEvery == 0)
    bots[i] = bot
end
-- Everyone asks at once (the drop, a storm phase): the burst.
for _, bot in ipairs(bots) do
    CURRENT_BOT = bot
    local destination = shared and Vector3.new(500, 0, 0) or Vector3.new(bot.id * 50, 0, 0)
    BotNav.Request(bot, destination, bot.urgent and BotNav.Priority.Urgent or BotNav.Priority.Wander)
end
-- compute()'s task.spawn runs ComputeAsync up to its yield; each takes 0.1 s, the low end of the
-- 77-120 ms measured in BotNav's comment.
local worst, pumps, drainedAt = 0, 0, nil
while CLOCK < 10 do
    CLOCK = CLOCK + pumpEvery
    startedThisPump = 0
    BotNav.Pump()
    pumps = pumps + 1
    worst = math.max(worst, startedThisPump)
    stepThreads()
    local routed = 0
    for _, bot in ipairs(bots) do if BotNav.HasRoute(bot) then routed = routed + 1 end end
    if drainedAt == nil and routed >= N then
        drainedAt = CLOCK
        if shared then
            -- A late bot asks from the crowd's spot while the routes are fresh (within ROUTE_SHARE_SECONDS).
            local late = { id = N + 1, character = { Parent = true, GetPivot = function() return { Position = Vector3.zero } end },
                humanoid = { Health = 100 }, nav = { nextId = 0, failures = 0, index = 1 } }
            CURRENT_BOT = late
            BotNav.Request(late, Vector3.new(500, 0, 0), BotNav.Priority.Wander)
            IMMEDIATE = BotNav.HasRoute(late) and 1 or 0
        end
    end
end
local urgentLate = 0
local seenWander = false
for _, b in ipairs(startOrder) do
    if not b.urgent then seenWander = true elseif seenWander then urgentLate = urgentLate + 1 end
end
local routed, farComputed = 0, 0
for _, bot in ipairs(bots) do if BotNav.HasRoute(bot) then routed = routed + 1 end end
for _, b in ipairs(startOrder) do if b.id == N - 1 then farComputed = farComputed + 1 end end
return worst, drainedAt or -1, #startOrder, urgentLate, routed, farComputed, IMMEDIATE or 0
"""


def pump_source(lua_src):
    consts = "\n".join(re.findall(r"^local (?:MAX_(?:CONCURRENT_PATHS|STARTS_PER_PUMP)|ROUTE_SHARE_\w+) = \d+$", lua_src, flags=re.M))
    body = between(lua_src, "function BotNav.Request", "-- Whether the last compute toward")
    return luau_to_lua(consts + "\n" + body)


def pump(lua_src, n, pump_every, urgent_every=5, shared=False):
    lua = LuaRuntime(unpack_returned_tuples=True)
    # Record which bot each ComputeAsync belongs to.
    src = pump_source(lua_src).replace(
        "local path = PathfindingService:CreatePath(AGENT)",
        "CURRENT_BOT = bot\n\t\tlocal path = PathfindingService:CreatePath(AGENT)")
    return lua.execute(PUMP_HARNESS, src, n, pump_every, urgent_every, shared)


# --------------------------------------------------------------------------------------------
# D: CompanionService's Heartbeat
# --------------------------------------------------------------------------------------------

COMPANION_HARNESS = PRELUDE + r"""
local src, C, seconds = ...
THINK_INTERVAL = 0.2
TELEPORT_DISTANCE = 80
local beat
RunService = { Heartbeat = { Connect = function(_, fn) beat = fn end } }
local boons = 0
CompanionBoons = { Tick = function() boons = boons + 1 end, TickVenom = function() end }
CompanionService = { IsFighting = function() return true end }
CombatService = { IsEnabled = function() return true end }
Combatants = { IsBot = function() return true end }
despawn = function() end
attack = function() end
-- Locals of the real module that the sliced-out Heartbeat body calls: the cooldown clock and the
-- 0-HP gate (every mock companion is healthy, so the gate never hides a scan).
clockNow = function() return CLOCK end
canAct = function(entry) return entry ~= nil and type(entry.health) == "number" and entry.health > 0 end
local frame, perFrame, lastScan, periods = 0, {}, {}, {}
pickTarget = function(owner)
    perFrame[frame] = (perFrame[frame] or 0) + 1
    if lastScan[owner] then periods[#periods + 1] = CLOCK - lastScan[owner] end
    lastScan[owner] = CLOCK
    owner.scans = (owner.scans or 0) + 1
    return nil -- nobody in sight: the full-cost scan, every think
end
companions = {}
local owners = {}
for i = 1, C do
    local owner = { id = i }
    owners[i] = owner
    companions[owner] = { model = { Parent = true }, anchor = { Parent = true, WorldPosition = Vector3.zero },
        root = { Position = Vector3.zero }, gui = {}, stats = { cooldown = 1 }, lastAttackAt = -math.huge, health = 100 }
end
assert(load(src, "Companion", "t", _ENV))()
local dt = 1 / 60
while CLOCK < seconds do
    CLOCK = CLOCK + dt
    frame = frame + 1
    beat(dt)
end
local worst = 0
for _, n in pairs(perFrame) do worst = math.max(worst, n) end
local pmin, pmax = math.huge, 0
for _, p in ipairs(periods) do pmin = math.min(pmin, p); pmax = math.max(pmax, p) end
local fewest = math.huge
for _, owner in ipairs(owners) do fewest = math.min(fewest, owner.scans or 0) end
return worst, pmin, pmax, boons / C / seconds, fewest
"""


def companion_source(lua_src):
    end = "\tend)\nend\n\nreturn CompanionService"
    if "-- The boons tick every THINK_INTERVAL" in lua_src:
        src = between(lua_src, "\t-- The boons tick every THINK_INTERVAL", end)
    else:
        src = between(lua_src, "\tlocal accumulated = 0\n\tRunService.Heartbeat", end)
    return luau_to_lua(src + "\tend)\n")


def companion(lua_src, c, seconds=20.0):
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(COMPANION_HARNESS, companion_source(lua_src), c, seconds)


# --------------------------------------------------------------------------------------------
# E: the spatial grid against the linear scan
# --------------------------------------------------------------------------------------------

GRID_HARNESS = PRELUDE + r"""
local src = ...
STATS = setmetatable({}, { __index = function() return 0 end })
Combatants = { All = function() return {} end, IsPlayer = function() return false end }
assert(load(src, "grid", "t", _ENV))()
local grid = BotService.SpatialQuery.NewGrid(128)
-- A fixed pseudo-random layout: 200 rows over +-1500 studs, 60 queries of radius 5..400.
local seed = 12345
local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end
local rows = {}
for i = 1, 200 do
    rows[i] = { id = i, position = Vector3.new((rnd() - 0.5) * 3000, rnd() * 40, (rnd() - 0.5) * 3000) }
end
grid.Rebuild(rows)
local mismatches, examined, queries = 0, 0, 0
for q = 1, 60 do
    local at = Vector3.new((rnd() - 0.5) * 3000, rnd() * 40, (rnd() - 0.5) * 3000)
    local radius = 5 + rnd() * 395
    local expect = {}
    for _, row in ipairs(rows) do
        if (row.position - at).Magnitude <= radius then expect[row.id] = true end
    end
    local got, n = grid.Near(at, radius)
    local seen = {}
    for i = 1, n do seen[got[i].id] = true end
    for id in pairs(expect) do if not seen[id] then mismatches = mismatches + 1 end end
    for id in pairs(seen) do if not expect[id] then mismatches = mismatches + 1 end end
    examined = examined + n
    queries = queries + 1
end
-- Rebuild with fewer rows must forget the rest.
grid.Rebuild({ rows[1] })
local _, left = grid.Near(rows[1].position, 3000)
return mismatches, examined / queries, left
"""


def grid_check(lua_src):
    if not has(lua_src, "BotService.SpatialQuery = {}"):
        return None
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(GRID_HARNESS, target_source(lua_src))


# --------------------------------------------------------------------------------------------
# F: the ray budget: a frame of cover searches, and the order of refusal
# --------------------------------------------------------------------------------------------

BUDGET_HARNESS = PRELUDE + r"""
local budgetSrc, navSrc, bots = ...
STATS = setmetatable({}, { __index = function() return 0 end })
local rays = 0
-- Every ray hits: a wall (Normal.Y = 0) for the level rays, floor (Normal.Y = 1) for the downward
-- ones, so a cover candidate is always hidden and never steppable: the exhaustive search, 8
-- directions x 3 rings, each 1 sight ray + 1 wall ray, plus one floor ray for the routed fallback.
workspace = {
    FindFirstChild = function() return nil end,
    Raycast = function(_, origin, direction, params)
        rays = rays + 1
        local down = direction.Y < 0 and math.abs(direction.X) < 1e-9 and math.abs(direction.Z) < 1e-9
        return { Position = origin + direction * 0.5, Normal = { Y = down and 1 or 0 }, Material = "Enum.Material.Grass", Instance = {} }
    end,
    GetPartBoundsInRadius = function() return {} end,
}
BotNav = {}
if budgetSrc then
    assert(load(budgetSrc, "budget", "t", _ENV))()
else
    BotNav.CastRay = function(origin, direction, params, priority) return workspace:Raycast(origin, direction, params), true end
end
-- BotNav's probes (stepParams, FloorAt, CanStep, FindCover) with the module locals they read.
flat = function(v) return Vector3.new(v.X, 0, v.Z) end
flatDistance = function(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end
footHeight = function() return 3 end
WALKABLE_NORMAL_Y = math.cos(math.rad(55))
MAX_RISE_PER_STUD = math.tan(math.rad(55))
MAX_STEP_UP = 3
MAX_STEP_DOWN = 14
assert(load(navSrc, "nav", "t", _ENV))()

-- One frame: `bots` bots each search for cover from a threat 40 studs north.
if BotService.RaycastBudget.BeginFrame then BotService.RaycastBudget.BeginFrame() end
local searched, refused = 0, 0
local perBot = {}
for i = 1, bots do
    local before = rays
    local root = { Position = Vector3.new(i * 3, 3, 0) }
    local point, direct, why = BotNav.FindCover(root, { id = i }, Vector3.new(i * 3, 4.5, 40), nil, nil, nil, "navigation")
    perBot[i] = rays - before
    if why == "budget" then refused = refused + 1 else searched = searched + 1 end
end
local frameRays = rays
local frameDenied = STATS.raysDenied

-- The order of refusal, from a fresh frame: idle first, then navigation, then combat; a new frame
-- gives everything back.
local order = "n/a"
local combatDeniedFirst = 0
if budgetSrc then
    BotService.RaycastBudget.BeginFrame()
    local budget = BotService.RaycastBudget
    local cap = budget.FrameCap
    local granted = { idle = 0, navigation = 0, combat = 0 }
    local firstDenied = {}
    local n = 0
    for step = 1, cap * 2 do
        for _, class in ipairs({ "idle", "navigation", "combat" }) do
            local _, ok = budget.Cast(Vector3.zero, Vector3.new(0, 0, 1), {}, class)
            if ok then granted[class] = granted[class] + 1
            elseif not firstDenied[class] then n = n + 1; firstDenied[class] = n end
        end
    end
    order = string.format("idle %d, navigation %d, combat %d granted of %d each", granted.idle, granted.navigation, granted.combat, cap * 2)
    combatDeniedFirst = (firstDenied.combat or 4) < (firstDenied.navigation or 4) and 1 or 0
    if (firstDenied.navigation or 4) < (firstDenied.idle or 4) then combatDeniedFirst = combatDeniedFirst + 1 end
    budget.BeginFrame()
    local _, again = budget.Cast(Vector3.zero, Vector3.new(0, 0, 1), {}, "idle")
    if not again then combatDeniedFirst = combatDeniedFirst + 10 end
    return frameRays, searched, refused, perBot[1], order, combatDeniedFirst, granted.idle, granted.navigation, granted.combat, cap, frameDenied
end
return frameRays, searched, refused, perBot[1], order, combatDeniedFirst
"""


def budget_source(bot_src):
    if not has(bot_src, "-- RAYCAST BUDGET", "-- Returns visible, denied."):
        return None
    return luau_to_lua(between(bot_src, "local castRay\n", "-- Returns visible, denied."))


def nav_probe_source(nav_src):
    start = "local STEP_FOLDERS" if "local STEP_FOLDERS" in nav_src else "local function stepParams"
    probes = between(nav_src, start, "-- Walking straight at a goal")
    return luau_to_lua(probes)


def budget(bot_src, nav_src, bots=13):
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(BUDGET_HARNESS, budget_source(bot_src), nav_probe_source(nav_src), bots)


# --------------------------------------------------------------------------------------------
# H: LOD, the think loop with far, near, fighting and hurt bots
# --------------------------------------------------------------------------------------------

LOD_HARNESS = PRELUDE + r"""
local src, N, seconds, lodEnabled = ...
running, loopGeneration = false, 0
MatchConfig = { BotThinkInterval = 0.25 }
STATS = setmetatable({}, { __index = function() return 0 end })
FLEE_WINDOW = 3
BotNav = { Pump = function() end }
refreshCombatants = function() end
-- One player at the origin. Bot i is near it (80 studs) when i is odd, far (1000) when even. Of the
-- far ones, every third fights, every fifth was hurt since its last think.
BotService.SpatialQuery = { NearestPlayerDistance = function(position) return position.Magnitude end }
local frame = 0
local perFrame, lastAt = {}, {}
updateBot = function(bot)
    perFrame[frame] = (perFrame[frame] or 0) + 1
    if lastAt[bot] then
        bot.pmin = math.min(bot.pmin or math.huge, CLOCK - lastAt[bot])
        bot.pmax = math.max(bot.pmax or 0, CLOCK - lastAt[bot])
    end
    lastAt[bot] = CLOCK
    bot.thinks = (bot.thinks or 0) + 1
    bot.branch = bot.scripted
    bot.lastHealth = bot.humanoid.Health
    if bot.hurt then bot.humanoid.Health = bot.humanoid.Health - 1 end
end
bots = {}
for i = 1, N do
    local far = i % 2 == 0
    local position = far and Vector3.new(1000, 0, 0) or Vector3.new(80, 0, 0)
    local root = { Position = position }
    local humanoid = { Health = 100 }
    bots[i] = {
        id = i, far = far, humanoid = humanoid, lastHealth = 100,
        scripted = (far and i % 3 == 0) and "fight" or "wander",
        hurt = far and i % 5 == 0,
        character = { FindFirstChild = function() return root end },
    }
end
local chunk = assert(load(src, "Lod", "t", _ENV))
chunk()
BotService.LodEnabled = lodEnabled
BotService.Start()
local dt = 1 / 60
while CLOCK < seconds do
    CLOCK = CLOCK + dt
    frame = frame + 1
    stepThreads()
end
local worst = 0
for _, n in pairs(perFrame) do worst = math.max(worst, n) end
local function span(pick)
    local pmin, pmax, tmin, tmax = math.huge, 0, math.huge, 0
    for _, b in ipairs(bots) do
        if pick(b) then
            pmin = math.min(pmin, b.pmin or math.huge); pmax = math.max(pmax, b.pmax or 0)
            tmin = math.min(tmin, b.thinks or 0); tmax = math.max(tmax, b.thinks or 0)
        end
    end
    return pmin, pmax, tmin, tmax
end
local nearMin, nearMax, nearT = span(function(b) return not b.far end)
local fightMin, fightMax, fightT = span(function(b) return b.far and b.scripted == "fight" and not b.hurt end)
local hurtMin, hurtMax, hurtT = span(function(b) return b.far and b.hurt and b.scripted ~= "fight" end)
local idleMin, idleMax, idleT = span(function(b) return b.far and b.scripted ~= "fight" and not b.hurt end)
return worst, nearMin, nearMax, fightMin, fightMax, hurtMin, hurtMax, idleMin, idleMax, nearT, idleT, STATS.lodSkips
"""


def lod(bot_src, n, enabled=True, seconds=20.0):
    if not has(bot_src, "-- LEVEL OF DETAIL"):
        return None
    src = between(bot_src, "-- LEVEL OF DETAIL", "function BotService.Clear()")
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(LOD_HARNESS, luau_to_lua(src), n, seconds, enabled)


# --------------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------------

def checks(bot_src, nav_src, comp_src, verbose=True):
    """Invariants and bounds on the working-tree source. Returns a list of failures."""
    fails = []
    for n in (30, 50):
        worst, pmin, pmax, tmin, tmax, _ = think_loop(bot_src, n)
        if worst > math.ceil(n / 4):
            fails.append(f"A: {worst} thinks in one frame at N={n}, bound ceil(N/4)={math.ceil(n / 4)}")
        # Invariant: every bot still thinks once a BotThinkInterval (0.25 s, quantised to 60 Hz frames).
        if not (0.24 <= pmin and pmax <= 0.30) or tmax - tmin > 1:
            fails.append(f"A: think period {pmin:.3f}-{pmax:.3f} s, thinks per bot {tmin}-{tmax} at N={n}")
    for n in (10, 30, 50):
        worst, mean, asked, kb = find_target(bot_src, n, "crowd")
        if worst > 6:
            fails.append(f"B: {worst} rays in one think at N={n}, bound 2 x LOS_CHECKS_PER_THINK = 6")
        # Bound: a think allocates little beyond the mock vectors (two per candidate, one per ray).
        # Measured 6.1 / 11.7 / 17.3 KB at N=10/30/50 with pooled rows (lupa, Lua 5.5), against
        # 11.4 / 19.2 / 27.1 with a fresh list, a row per candidate and a sort closure per think;
        # the plant that stops pooling rows adds a table per candidate and must cross this.
        if kb > 0.3 * n + 4:
            fails.append(f"B: {kb:.2f} KB allocated per think at N={n}, bound {0.3 * n + 4:.2f}")
    for n in (30, 50):
        _, _, asked, _ = find_target(bot_src, n, "spread")
        # Bound: spread over the map, a bot asks hostile() only about combatants inside its reach
        # (260 studs: at most the 8 lattice neighbours plus itself's ring), never the whole lobby.
        if asked > 9:
            fails.append(f"B: {asked:.1f} candidates examined per think spread over the map at N={n}, bound 9")
    engaged, after = find_target(bot_src, 2, "cover")
    if engaged != "11111":
        fails.append(f"B: target behind an enemy barricade engaged on thinks {engaged}, want 11111")
    if after != 0:
        fails.append(f"B: engaged {after} time(s) after the barricade was shot down, want 0")
    worst, drained, started, late, routed, _, _ = pump(nav_src, 50, 0.0625)
    if worst > 3:
        fails.append(f"C: {worst} ComputeAsync started in one pump, bound 3")
    if started < 50 or drained < 0 or drained > 1.5:
        fails.append(f"C: {started}/50 burst routes started, drained at {drained:.2f} s (want all, within 1.5 s)")
    if late:
        fails.append(f"C: {late} urgent route(s) started after a wander route")
    for c in (9, 15):
        worst, pmin, pmax, boon_rate, fewest = companion(comp_src, c)
        if fewest < 20 / 0.25:
            fails.append(f"D: a companion scanned only {fewest} times in 20 s, want one a THINK_INTERVAL")
        if worst > math.ceil(c / 4):
            fails.append(f"D: {worst} companion scans in one frame with {c} companions, bound {math.ceil(c / 4)}")
        if not (0.19 <= pmin and pmax <= 0.25):
            fails.append(f"D: companion think period {pmin:.3f}-{pmax:.3f} s, want ~0.2")
        # Once a THINK_INTERVAL, which the 60 Hz accumulator quantises to 13 frames (4.6/s).
        if not (4.4 <= boon_rate <= 5.1):
            fails.append(f"D: boons ticked {boon_rate:.2f}/s per companion, want once a THINK_INTERVAL (4.6-5/s)")
    grid = grid_check(bot_src)
    if grid is None:
        fails.append("E: BotService.SpatialQuery is missing")
    else:
        mismatches, _, left = grid
        # Invariant: the grid answers exactly the linear scan, at every radius, including a row
        # sitting on a cell edge; a rebuild forgets rows that are gone.
        if mismatches:
            fails.append(f"E: grid disagreed with the linear scan on {mismatches} row(s) over 60 queries")
        if left != 1:
            fails.append(f"E: after a rebuild with one row the grid still held {left}")
    result = budget(bot_src, nav_src)
    if len(result) < 10:
        fails.append("F: BotService.RaycastBudget is missing")
    else:
        frame_rays, searched, refused, per_search, order, misorder, idle_ok, nav_ok, combat_ok, cap, denied = result
        # Invariant: a refused search stops at its first refusal (one refused ray per refused
        # search) and reports "budget", so its caller retries next think instead of counting it.
        if denied != refused or searched + refused != 13:
            fails.append(f"F: {denied} rays refused for {refused} refused searches ({searched} completed of 13): a search must stop at its first refusal and say so")
        # Bound: one frame of 13 cover searches casts at most the navigation share of the cap plus
        # the one search that crosses it; unbudgeted it is 13 x 49.
        if frame_rays > cap * 0.75 + per_search:
            fails.append(f"F: {frame_rays} rays in one frame of 13 cover searches, bound {cap * 0.75 + per_search:.0f}")
        if searched < 3:
            fails.append(f"F: only {searched} of 13 cover searches completed inside the budget, want at least 3")
        # Invariant: refusal order idle, then navigation, then combat; a new frame gives it all back;
        # combat keeps the whole cap.
        if misorder:
            fails.append(f"F: refusal order wrong or a new frame did not reset the budget (code {misorder}); {order}")
        if not (idle_ok < nav_ok < combat_ok and idle_ok + nav_ok + combat_ok == cap):
            fails.append(f"F: shares wrong: {order}, cap {cap}")
    for n in (30, 50):
        result = lod(bot_src, n)
        if result is None:
            fails.append("H: BotService.LodDefers is missing")
            break
        worst, near_min, near_max, fight_min, fight_max, hurt_min, hurt_max, idle_min, idle_max, near_t, idle_t, skips = result
        interval = 0.25
        # Invariant: a bot near a player, a far bot that is fighting, and a far bot hit since its
        # last think all think every interval; only far idle bots are deferred, and never more
        # than one turn in a row.
        if not (0.24 <= near_min and near_max <= 0.30):
            fails.append(f"H: near-player bots thought every {near_min:.3f}-{near_max:.3f} s at N={n}, want one interval")
        if not (0.24 <= fight_min and fight_max <= 0.30):
            fails.append(f"H: far FIGHTING bots thought every {fight_min:.3f}-{fight_max:.3f} s at N={n}, want one interval")
        if not (0.24 <= hurt_min and hurt_max <= 0.30):
            fails.append(f"H: far HURT bots thought every {hurt_min:.3f}-{hurt_max:.3f} s at N={n}, want one interval")
        if not (0.5 <= idle_min and idle_max <= 0.6):
            fails.append(f"H: far idle bots thought every {idle_min:.3f}-{idle_max:.3f} s at N={n}, want two intervals")
        if skips == 0:
            fails.append(f"H: LOD never deferred a think at N={n}")
    worst, drained, started, late, routed, far_computed, immediate = pump(nav_src, 50, 0.0625, shared=True)
    # Bound: fifty bots standing together asking for one place compute at most three pumps' worth
    # (a compute takes 0.1 s, a pump comes every 0.0625 s) before the first route lands and the
    # rest copy it; every bot ends with a route; the bot standing 100 studs away computes its own.
    if started > 10:
        fails.append(f"G: {started} ComputeAsync for 50 bots asking for one place, bound 10 (three pumps + the far bot)")
    if routed < 50:
        fails.append(f"G: only {routed}/50 bots ended with a route when sharing")
    if far_computed != 1:
        fails.append(f"G: the bot 100 studs from the shared route's start computed {far_computed} route(s), want its own 1")
    # Bound: a request for a place a neighbour has just routed to is answered at the request, not
    # a pump later (a queue slot and up to a slice of standing still).
    if immediate != 1:
        fails.append("G: a bot asking for a place a neighbour just routed to did not get the route at the request")
    return fails


def table(label, bot_src, nav_src, comp_src):
    print(f"--- {label}")
    for n in (30, 50):
        worst, pmin, pmax, _, _, pump_rate = think_loop(bot_src, n)
        print(f"  A N={n}: worst frame {worst} bot thinks; each bot every {pmin:.3f}-{pmax:.3f} s; Pump {pump_rate:.0f}/s")
    slices = 4 if "THINK_SLICES = 4" in bot_src else 2
    for n in (10, 30, 50):
        worst, mean, asked, kb = find_target(bot_src, n, "crowd")
        print(f"  B N={n} crowd, all hidden: rays per think worst {worst}, mean {mean:.1f}; per frame {worst * math.ceil(n / slices)}; "
              f"candidates examined {asked:.1f}/think; {kb:.2f} KB allocated/think")
    for n in (30, 50):
        worst, mean, asked, kb = find_target(bot_src, n, "spread")
        print(f"  B N={n} spread over 1280 studs: candidates examined {asked:.1f}/think (linear scan would be {n - 1}); "
              f"rays {mean:.1f}/think; {kb:.2f} KB/think")
    engaged, after = find_target(bot_src, 2, "cover")
    print(f"  B through-cover: engaged on thinks {engaged}; after it was shot down {after}")
    pump_every = 0.0625 if "MAX_STARTS_PER_PUMP" in nav_src else 0.125
    for n in (30, 50):
        worst, drained, started, late, _, _, _ = pump(nav_src, n, pump_every)
        print(f"  C N={n} burst: worst {worst} ComputeAsync starts in one pump; {started} started, all routed by {drained:.2f} s; urgent-after-wander {late}")
    for c in (9, 15):
        worst, pmin, pmax, boon_rate, _ = companion(comp_src, c)
        print(f"  D {c} bot companions (30%/50 bots = 15): worst frame {worst} scans = up to {worst * 49} rays at N=50; "
              f"each every {pmin:.3f}-{pmax:.3f} s; boons {boon_rate:.1f}/s")
    grid = grid_check(bot_src)
    if grid is None:
        print("  E spatial grid: none (linear scans)")
    else:
        mismatches, examined, _ = grid
        print(f"  E spatial grid vs linear scan: {mismatches} mismatches over 60 queries of 200 rows; {examined:.1f} rows returned per query")
    result = budget(bot_src, nav_src)
    frame_rays, searched, refused, per_search, order = result[:5]
    denied = result[10] if len(result) > 10 else 0
    print(f"  F one frame of 13 cover searches (exhaustive, {per_search} rays each): {frame_rays} rays; {searched} completed, {refused} refused by the budget ({denied} rays refused); refusal order: {order}")
    for n in (30, 50):
        worst, drained, started, late, routed, far_computed, immediate = pump(nav_src, n, pump_every, shared=True)
        print(f"  G N={n} asking for ONE place: {started} ComputeAsync (the far bot {far_computed}); {routed}/{n} routed by {drained:.2f} s; a late request routed at once: {immediate}")
    for n in (30, 50):
        result = lod(bot_src, n)
        if result is None:
            print(f"  H N={n} LOD: none (every bot every interval)")
        else:
            worst, near_min, near_max, fight_min, fight_max, hurt_min, hurt_max, idle_min, idle_max, near_t, idle_t, skips = result
            print(f"  H N={n} LOD (half the bots 1000 studs from the player): worst frame {worst} thinks; near {near_min:.3f}-{near_max:.3f} s, "
                  f"far fighting {fight_min:.3f}-{fight_max:.3f} s, far hurt {hurt_min:.3f}-{hurt_max:.3f} s, far idle {idle_min:.3f}-{idle_max:.3f} s; "
                  f"thinks in 20 s near {near_t}, far idle {idle_t}; {skips} deferred")


PLANTS = [
    # Each is (file, before, after, what it breaks). All aimed at invariants or bounds that hold forever.
    (BOTSERVICE, "local THINK_SLICES = 4", "local THINK_SLICES = 1", "bound: every bot thinks in one frame"),
    (BOTSERVICE, "if index % THINK_SLICES == slice and", "if index % (THINK_SLICES + 1) == slice and",
     "invariant: some bots stop thinking once an interval"),
    (BOTSERVICE, "if computed or entry.cover == nil then", "if true then",
     "bound: a barricade ray for every hidden candidate every think (the #126 shape)"),
    (BOTSERVICE, "\t\t\t\tstructure = entry.cover\n", "\t\t\t\tstructure = nil\n",
     "invariant: a target behind a barricade is dropped on cached thinks"),
    (BOTSERVICE, "if structure and structure.Parent then", "if structure then",
     "invariant: a shot-down barricade keeps hiding its target"),
    (BOTNAV, "local MAX_STARTS_PER_PUMP = 3", "local MAX_STARTS_PER_PUMP = 15", "bound: burst of starts in one pump"),
    (BOTNAV, "and started < MAX_STARTS_PER_PUMP do", "and started < MAX_STARTS_PER_PUMP and inFlight < 1 do",
     "invariant: the burst never drains"),
    (BOTNAV, "\t\tif ra.priority ~= rb.priority then\n\t\t\treturn ra.priority < rb.priority",
     "\t\tif ra.priority ~= rb.priority then\n\t\t\treturn ra.priority > rb.priority",
     "invariant: urgent routes wait behind wander routes"),
    (COMPANION, "\tlocal THINK_SLICES = 4\n\tlocal accumulated, sliceAccumulated",
     "\tlocal THINK_SLICES = 1\n\tlocal accumulated, sliceAccumulated", "bound: every companion scans in one frame"),
    (COMPANION, "nextSlot = (nextSlot + 1) % THINK_SLICES", "nextSlot = (nextSlot + 1) % (THINK_SLICES + 1)",
     "invariant: some companions never think"),
    (COMPANION, "\t\t\tCompanionBoons.TickVenom(THINK_INTERVAL)\n\t\tend\n",
     "\t\t\tCompanionBoons.TickVenom(THINK_INTERVAL)\n\t\tend\n\t\tfor owner in pairs(companions) do\n\t\t\tCompanionBoons.Tick(owner, THINK_INTERVAL)\n\t\tend\n",
     "invariant: boons tick more than once an interval"),
    # The shared infrastructure.
    (BOTSERVICE, "local minX, maxX = FLOOR((px - radius) / cellSize), FLOOR((px + radius) / cellSize)",
     "local minX, maxX = FLOOR((px - radius) / cellSize), FLOOR((px + radius) / cellSize) - 1",
     "invariant: the grid misses combatants in the last cell of a query"),
    (BOTSERVICE, "\t\t\tgrid.count = #rows\n", "\t\t\tgrid.count = #rows\n\t\t\tused[1] = nil\n",
     "invariant: a rebuilt grid keeps rows that are gone"),
    (BOTSERVICE, "local near, nearCount = combatantsNear(position, reach)",
     "local near, nearCount = combatantList, #combatantList",
     "bound: findTarget walks the whole lobby again (candidates examined = N-1)"),
    (BOTSERVICE, "\tlocal row = scratch.candidatePool[slot]\n", "\tlocal row = nil\n",
     "bound: a fresh row per candidate per think (allocation)"),
    (BOTSERVICE, "\t\tif spent >= budget.FrameCap * share then\n", "\t\tif false then\n",
     "bound: the ray budget refuses nothing"),
    (BOTSERVICE, "Share = { combat = 1, navigation = 0.75, idle = 0.5 }", "Share = { combat = 0.5, navigation = 0.75, idle = 1 }",
     "invariant: sight rays are refused before footing rays"),
    (BOTSERVICE, "\t\tspent = 0\n\tend\n", "\tend\n", "invariant: a new frame does not give the budget back"),
    (BOTNAV, "\t\t\t\tif not granted then\n\t\t\t\t\treturn nil, nil, \"budget\"\n\t\t\t\tend\n\t\t\t\tif hit and (hit.Position - eye).Magnitude > 2 then",
     "\t\t\t\tif hit and (hit.Position - eye).Magnitude > 2 then",
     "bound: a cover search carries on casting after the budget refused it"),
    (BOTNAV, "\t\t\tand flatDistance(route.start, position) < ROUTE_SHARE_START then", "\t\t\tthen",
     "invariant: a bot far from a route's start adopts it"),
    (BOTNAV, "\tif adoptRoute(bot, destination) then\n\t\treturn\n\tend\n", "",
     "bound: a request never copies a neighbour's route (Pump-time adoption alone is too late for a burst)"),
    (BOTSERVICE, "\tif BotService.LodActiveBranches[bot.lastBranch] then\n\t\treturn false\n\tend\n", "",
     "invariant: a fighting bot far from players is deferred"),
    (BOTSERVICE, "\tif humanoid and humanoid.Health < bot.lastHealth then\n\t\treturn false\n\tend\n", "",
     "invariant: a bot hit since its last think is deferred"),
    (BOTSERVICE, "BotService.SpatialQuery.NearestPlayerDistance(root.Position) <= BotService.LodDistance",
     "BotService.SpatialQuery.NearestPlayerDistance(root.Position) < 0",
     "invariant: a bot next to a player is deferred"),
    (BOTSERVICE, "BotService.LodSkip = 2", "BotService.LodSkip = 4", "bound: a far idle bot waits four turns"),
]


def main():
    args = sys.argv[1:]
    root = args[0] if args and not args[0].startswith("--") else "."
    before_rev = args[args.index("--before") + 1] if "--before" in args else None
    tree = {p: read_tree(root, p) for p in (BOTSERVICE, BOTNAV, COMPANION)}

    if "--plant" in args:
        caught = 0
        for path, old, new, what in PLANTS:
            assert tree[path].count(old) == 1, f"plant text not found once in {path}: {old!r}"
            planted = dict(tree)
            planted[path] = tree[path].replace(old, new)
            try:
                fails = checks(planted[BOTSERVICE], planted[BOTNAV], planted[COMPANION])
            except Exception as err:  # a plant that breaks the harness counts as caught, loudly
                fails = [f"harness error: {err}"]
            status = "CAUGHT" if fails else "MISSED"
            caught += bool(fails)
            print(f"plant [{status}] {what}: {fails[0] if fails else 'no check failed'}")
        print(f"perf_bot_cost plants: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)

    if before_rev is None:
        # The commit before this tool's first commit; HEAD if the tool is not committed yet.
        before_rev = default_before(root, "tools/perf_bot_cost.py")
    try:
        before = {p: read_rev(root, before_rev, p) for p in tree}
        table(f"before ({before_rev})", before[BOTSERVICE], before[BOTNAV], before[COMPANION])
    except NoRevision as err:
        # Outside a git checkout (or without git) the table is the working tree's alone; every check
        # below reads only the working tree, so nothing it decides depends on the before.
        no_before_note("perf_bot_cost", err)
    table("after (working tree)", tree[BOTSERVICE], tree[BOTNAV], tree[COMPANION])
    fails = checks(tree[BOTSERVICE], tree[BOTNAV], tree[COMPANION])
    for f in fails:
        print("FAIL", f)
    print(f"perf_bot_cost: {len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
