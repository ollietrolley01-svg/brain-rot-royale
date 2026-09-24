"""Per-frame server cost of the bots against the bot count N, before and after (#131/#126/#113/#99).

No Studio, so this counts WORK rather than milliseconds: it runs the real source of four hot
paths in a Lua interpreter (lupa) with Roblox mocked, once from a git revision (the "before",
default HEAD~1 of this file's commit, pass --before REV) and once from the working tree, and
counts per frame:

  A  BotService.Start's think loop    bot thinks started in one frame, and each bot's think period
  B  BotService.findTarget            raycasts per bot think in a crowd where nobody can see anyone
  C  BotNav.Pump                      ComputeAsync calls started in one pump, burst drain time
  D  CompanionService's Heartbeat     bot companions' target scans in one frame (each scan casts
                                      one ray per enemy in range when nobody is in sight)

Every section also checks an invariant the fix must never break (each bot still thinks once a
BotThinkInterval; a target behind an enemy barricade is still engaged on every think; a destroyed
barricade stops hiding anyone; every queued route starts, urgent first; each companion still
thinks once a THINK_INTERVAL), and --plant runs planted faults against the working tree, every
one of which must be caught.

    python tools/perf_bot_cost.py .                 before/after table and the checks
    python tools/perf_bot_cost.py . --plant         the planted faults; every one must be caught
    python tools/perf_bot_cost.py . --before REV    compare against another revision

What this does NOT measure: milliseconds. A raycast or a ComputeAsync start has no fixed cost
here; tools/perf_tick_probe.lua measures the worst server frame in Studio.
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


def read_tree(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read()


def read_rev(root, rev, path):
    return subprocess.run(["git", "-C", root, "show", f"{rev}:{path}"], capture_output=True, text=True,
                          check=True).stdout


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
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }
Vector3.zero = Vector3.new(0, 0, 0)
Enum = setmetatable({}, { __index = function(_, k) return setmetatable({}, { __index = function(_, j) return k .. "." .. j end }) end })
RaycastParams = { new = function() return {} end }
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
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
"""

# --------------------------------------------------------------------------------------------
# A: the think loop
# --------------------------------------------------------------------------------------------

THINK_HARNESS = PRELUDE + r"""
local src, N, seconds = ...
BotService = {}
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
# B: findTarget's rays
# --------------------------------------------------------------------------------------------

TARGET_HARNESS = PRELUDE + r"""
local src, N, scenario = ...
STATS = setmetatable({}, { __index = function() return 0 end })
MatchConfig = { BotVisionRange = 260, BotPlayerBias = 1.6, BotRearNoticeTime = 1.2 }
hostile = function() return true end
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

if scenario == "crowd" then
    -- N bots within 60 studs of each other, walls between every pair: nobody can see anybody.
    local bots = {}
    for i = 1, N do
        local a = i * 2.399963
        bots[i] = makeBot(i, Vector3.new(math.cos(a) * (i % 7) * 8, 0, math.sin(a) * (i % 7) * 8))
    end
    local worst, total, thinks = 0, 0, 0
    for round = 1, 40 do
        CLOCK = round * 0.25
        refreshCombatants()
        for _, bot in ipairs(bots) do
            local before = rays
            findTarget(bot, bot.root, bot.head, CLOCK)
            worst = math.max(worst, rays - before)
            total = total + (rays - before)
            thinks = thinks + 1
        end
    end
    return worst, total / thinks
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
# C: BotNav.Pump
# --------------------------------------------------------------------------------------------

PUMP_HARNESS = PRELUDE + r"""
local src, N, pumpEvery, urgentEvery = ...
-- Bot i asks with Urgent priority when i is a multiple of urgentEvery, Wander otherwise.
STATS = setmetatable({}, { __index = function() return 0 end })
BotNav = { Priority = { Urgent = 1, Combat = 2, Loot = 3, Wander = 4 }, HasRoute = function() return false end }
REUSE_RADIUS = 10
AGENT = {}
inFlight, waiting = 0, {}
disconnectBlocked = function() end
local startedThisPump, startOrder, computing = 0, {}, {}
local paths = {}
PathfindingService = { CreatePath = function()
    local path = { Status = "Enum.PathStatus.Success" }
    function path:ComputeAsync()
        startedThisPump = startedThisPump + 1
        startOrder[#startOrder + 1] = CURRENT_BOT
        coroutine.yield(0.1)
    end
    function path:GetWaypoints() return { {}, {} } end
    path.Blocked = { Connect = function() return {} end }
    return path
end }
Enum.PathStatus = { Success = "Enum.PathStatus.Success" }
assert(load(src, "Pump", "t", _ENV))()
local bots = {}
for i = 1, N do
    local bot = { id = i, character = { Parent = true, GetPivot = function() return { Position = Vector3.zero } end },
        humanoid = { Health = 100 }, nav = { nextId = 0, failures = 0 } }
    bot.urgent = (i % urgentEvery == 0)
    bots[i] = bot
end
-- Everyone asks at once (the drop, a storm phase): the burst.
for _, bot in ipairs(bots) do
    CURRENT_BOT = bot
    BotNav.Request(bot, Vector3.new(bot.id * 50, 0, 0), bot.urgent and BotNav.Priority.Urgent or BotNav.Priority.Wander)
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
    if drainedAt == nil and #startOrder >= N then drainedAt = CLOCK end
end
return worst, drainedAt or -1
"""


def pump_source(lua_src):
    consts = "\n".join(re.findall(r"^local MAX_(?:CONCURRENT_PATHS|STARTS_PER_PUMP) = \d+$", lua_src, flags=re.M))
    body = between(lua_src, "function BotNav.Request", "-- Whether the last compute toward")
    return luau_to_lua(consts + "\n" + body)


def pump(lua_src, n, pump_every, urgent_every=5):
    lua = LuaRuntime(unpack_returned_tuples=True)
    # Record which bot each ComputeAsync belongs to.
    src = pump_source(lua_src).replace(
        "local path = PathfindingService:CreatePath(AGENT)",
        "CURRENT_BOT = bot\n\t\tlocal path = PathfindingService:CreatePath(AGENT)")
    harness = PUMP_HARNESS.replace("return worst, drainedAt or -1", r"""
local urgentLate = 0
local seenWander = false
for _, b in ipairs(startOrder) do
    if not b.urgent then seenWander = true elseif seenWander then urgentLate = urgentLate + 1 end
end
return worst, drainedAt or -1, #startOrder, urgentLate
""")
    return lua.execute(harness, src, n, pump_every, urgent_every)


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
        root = { Position = Vector3.zero }, gui = {}, stats = { cooldown = 1 }, lastAttackAt = -math.huge }
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
# Checks
# --------------------------------------------------------------------------------------------

def checks(bot_src, nav_src, comp_src, verbose=True):
    """Invariants and bounds on the working-tree source. Returns a list of failures."""
    fails = []
    for n in (30, 50):
        worst, pmin, pmax, tmin, tmax, _ = think_loop(bot_src, n)
        slices = int(re.search(r"^local THINK_SLICES = (\d+)", bot_src, flags=re.M).group(1)) \
            if re.search(r"^local THINK_SLICES = (\d+)", bot_src, flags=re.M) else 2
        if worst > math.ceil(n / 4):
            fails.append(f"A: {worst} thinks in one frame at N={n}, bound ceil(N/4)={math.ceil(n / 4)}")
        # Invariant: every bot still thinks once a BotThinkInterval (0.25 s, quantised to 60 Hz frames).
        if not (0.24 <= pmin and pmax <= 0.30) or tmax - tmin > 1:
            fails.append(f"A: think period {pmin:.3f}-{pmax:.3f} s, thinks per bot {tmin}-{tmax} at N={n}")
    for n in (10, 30, 50):
        worst, mean = find_target(bot_src, n, "crowd")
        if worst > 6:
            fails.append(f"B: {worst} rays in one think at N={n}, bound 2 x LOS_CHECKS_PER_THINK = 6")
    engaged, after = find_target(bot_src, 2, "cover")
    if engaged != "11111":
        fails.append(f"B: target behind an enemy barricade engaged on thinks {engaged}, want 11111")
    if after != 0:
        fails.append(f"B: engaged {after} time(s) after the barricade was shot down, want 0")
    worst, drained, started, late = pump(nav_src, 50, 0.0625)
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
    return fails


def table(label, bot_src, nav_src, comp_src):
    print(f"--- {label}")
    for n in (30, 50):
        worst, pmin, pmax, _, _, pump_rate = think_loop(bot_src, n)
        print(f"  A N={n}: worst frame {worst} bot thinks; each bot every {pmin:.3f}-{pmax:.3f} s; Pump {pump_rate:.0f}/s")
    for n in (10, 30, 50):
        worst, mean = find_target(bot_src, n, "crowd")
        print(f"  B N={n} crowd, all hidden: rays per think worst {worst}, mean {mean:.1f}; "
              f"per think slice {worst * math.ceil(n / (4 if 'THINK_SLICES = 4' in bot_src else 2))}")
    engaged, after = find_target(bot_src, 2, "cover")
    print(f"  B through-cover: engaged on thinks {engaged}; after it was shot down {after}")
    pump_every = 0.0625 if "MAX_STARTS_PER_PUMP" in nav_src else 0.125
    for n in (30, 50):
        worst, drained, started, late = pump(nav_src, n, pump_every)
        print(f"  C N={n} burst: worst {worst} ComputeAsync starts in one pump; all {started} started by {drained:.2f} s; urgent-after-wander {late}")
    for c in (9, 15):
        worst, pmin, pmax, boon_rate, _ = companion(comp_src, c)
        print(f"  D {c} bot companions (30%/50 bots = 15): worst frame {worst} scans = up to {worst * 49} rays at N=50; "
              f"each every {pmin:.3f}-{pmax:.3f} s; boons {boon_rate:.1f}/s")


PLANTS = [
    # Each is (file, before, after, what it breaks). All aimed at invariants or bounds that hold forever.
    (BOTSERVICE, "local THINK_SLICES = 4", "local THINK_SLICES = 1", "bound: every bot thinks in one frame"),
    (BOTSERVICE, "if index % THINK_SLICES == slice then", "if index % (THINK_SLICES + 1) == slice then",
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
        log = subprocess.run(["git", "-C", root, "log", "--format=%H", "--diff-filter=A", "--", "tools/perf_bot_cost.py"],
                             capture_output=True, text=True).stdout.split()
        before_rev = (log[-1] + "~1") if log else "HEAD"
    before = {p: read_rev(root, before_rev, p) for p in tree}
    table(f"before ({before_rev})", before[BOTSERVICE], before[BOTNAV], before[COMPANION])
    table("after (working tree)", tree[BOTSERVICE], tree[BOTNAV], tree[COMPANION])
    fails = checks(tree[BOTSERVICE], tree[BOTNAV], tree[COMPANION])
    for f in fails:
        print("FAIL", f)
    print(f"perf_bot_cost: {len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
