"""Bot lag proof (#113 "the bots are pretty laggy", #126 "too many bots in one area = lag", #131 "fix as
much lag as possible", #99 "bot and player movement is clippy, like low fps").

tools/perf_bot_cost.py proves each fix of 30f6144 / 371c029 / 51251bc on a slice of the code cut out
of the file. This runs the WHOLE of BotService.lua and the WHOLE of BotNav.lua in lupa, through their
real entry points: BotService.Start's own think loop, frame by frame at 60 Hz, with Heartbeat, the
thread scheduler and PathfindingService stood in for (tools/bot_lag_proof_world.lua), on
tools/bot_archetype_sim.py's mock map, characters and module mocks. Bots are real Spawn tables with a
real rifle each, so they look for each other, fight, take cover, hunt and wander.

Per 60 Hz frame it counts what the bots asked the platform for, and from where:
  thinks          updateBot calls (the loop's own pcall)
  rays            every workspace:Raycast from bot code, by the function that asked and by the path
                  updateBot took to it; whether it came through RaycastBudget.Cast, and the budget's
                  spend and priority at the moment it was granted
  overlaps        workspace:GetPartBoundsInRadius from bot code
  computeStarts   PathfindingService ComputeAsync starts, and how many are in flight
  moveTos         Humanoid:MoveTo calls, and any outside a think
  hostileAsks     BotService.IsHostile hook calls (the candidates a think examines)
  claims          SetNetworkOwner(nil) calls (85c3042's re-claim), per bot over time
  samples         game-code VM instructions / 1000 (a profiler hook), by function and by path
  ms              lupa wall time of the frame's bot work, less the mock raycasts' own time
  kb              KB allocated in the frame (mocks included: compare, don't read as Roblox figures)
and per bot, for #99: how often a bot on a route stands at a point it has reached, waiting for the
next think to give it the next one, and how often its walk/idle track disagrees with its motion.

Scenarios (N = 15, 30, 50 bots, one player standing at the centre who is never hurt):
  spread   bots over a 1200-stud square, 30 small buildings (the battle royale's spacing)
  packed   bots inside a 60-stud square round the player, 6 walls (#126's "many bots in one area")
  teams    team deathmatch: two teams of N/2, each packed 40 studs square, 120 studs apart
  stress   packed 50 with RaycastBudget.FrameCap lowered to 40, so the budget has to refuse

Checks (each is an invariant the commits claim; --plant breaks each one in a copy of the source):
  T1  no frame carries more than ceil(N / 4) thinks (30f6144: think in quarters)
  T2  a bot no player is within 300 studs of... never waits longer than 16 frames between thinks
      (packed, where LOD never applies); with LOD, never longer than 32 (spread)
  R1  every ray bot code casts comes through RaycastBudget.Cast (51251bc: the ray budget)
  R2  a slice never grants more than FrameCap rays, and never an idle ray past half of it or a
      navigation ray past three quarters (the refusal order)
  R3  a refusal only happens in a slice that has spent at least half the cap (the budget is opened
      every slice, not once)
  P1  no think slice starts more than 3 ComputeAsync (30f6144: paced route starts)
  P2  never more than 15 computes in flight (MAX_CONCURRENT_PATHS, the cap-15 row)
  L1  LOD never defers a bot within 300 studs of a player, nor one whose last think was a fight,
      flee, dodge or storm
  C1  every living bot's physics is re-claimed at least every 1 s + one think (85c3042)
  E1  no Lua error in any think

What this does NOT measure: milliseconds on a Roblox server. A lupa instruction count or a lupa
millisecond says where the work is and how it scales with N and with packing; it is not a Roblox
frame time. PathfindingService is a stand-in (straight routes, a fixed 0.4 s latency). Vehicles,
companions (CompanionService is mocked; perf_bot_cost.py section D covers its slices), loot and the
storm are not in these scenarios. tools/perf_tick_probe.lua is the Studio measurement.

    python tools/bot_lag_proof_check.py .                    the table, findings and the checks
    python tools/bot_lag_proof_check.py . --plant            the planted faults; every one must be caught
    python tools/bot_lag_proof_check.py . --rev REV          run BotService/BotNav from a git revision
                                                             (e.g. origin/pc/teambase-v2)
"""

import importlib.util
import math
import os
import re
import subprocess
import sys
import time

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sim = _load("bot_archetype_sim")
perf = sim.perf

BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
BOTNAV = "ServerScriptService/Modules/BotNav.lua"
NAV_SOURCE = BOTNAV  # the chunk name BotNav loads under (LOADER's require uses the path)

FRAME = 1 / 60
FRAME_CAP = 240           # BotService.RaycastBudget.FrameCap, the figure 51251bc sets
SLICE_FRAMES = 4          # BotThinkInterval / THINK_SLICES = 0.0625 s, rounded up to 60 Hz frames
THINK_FRAMES = 16         # four slices: each bot once a BotThinkInterval (0.267 s at 60 Hz)
LOD_SKIP = 2
MAX_STARTS = 3
MAX_IN_FLIGHT = 15


def read_tree(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read()


def read_rev(root, rev, path):
    return subprocess.run(["git", "-C", root, "show", f"{rev}:{path}"], capture_output=True, text=True,
                          check=True).stdout


# Function names by the line they are defined on, for the profiler and the ray attribution.
def function_names(source, file_tag):
    names = {}
    current = None
    for number, line in enumerate(source.split("\n"), 1):
        m = re.match(r"^\s*(?:local\s+)?function\s+([\w.:]+)\s*\(", line)
        if m:
            current = m.group(1).replace(":", ".")
            names[number] = current
            continue
        if "Heartbeat:Connect(function" in line and "servo" in line:
            names[number] = "Vehicles.servo"
        elif "task.spawn(function" in line and current == "BotService.Start":
            names[number] = "Start.loop"
        elif "function(" in line:
            m = re.match(r"^\s*(?:local\s+)?([\w.\[\]\"]+)\s*=\s*function\s*\(", line)
            names[number] = m.group(1) if m else f"{current}.<anon:{file_tag}{number}>"
    return names


SCENARIO_LUA = r"""
LAGSCEN = {}
local ARCHES = { "Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor" }

local function wallsAt(list)
    for _, w in ipairs(list) do SIM.addWall(w[1], w[2]) end
end

local function clearOf(p)
    return not SIM.pointInWall(p, 3)
end

local function randomIn(half, centre)
    for _ = 1, 50 do
        local p = Vector3.new(centre.X + (math.random() * 2 - 1) * half, 3, centre.Z + (math.random() * 2 - 1) * half)
        if clearOf(p) and (Vector3.new(p.X, 0, p.Z)).Magnitude > 4 then return p end
    end
    return Vector3.new(centre.X, 3, centre.Z + half)
end

-- Build the scenario and start the real loop. opts: n, layout, seed, frameCap, health.
function LAGSCEN.setup(opts)
    SIM.reset(opts.seed)
    LAG.resetWorld()
    LAG.frames, LAG.frame = {}, 0
    LAG.raysLeaf, LAG.raysTop, LAG.samplesSelf, LAG.samplesTop, LAG.unbudgeted = {}, {}, {}, {}, {}
    LAG.grants, LAG.claims, LAG.deferrals, LAG.thinksAt, LAG.sliceLog, LAG.deferAt = {}, {}, {}, {}, {}, {}
    LAG.pathInFlight, LAG.pathInFlightMax, LAG.pathStarted, LAG.mockTime = 0, 0, 0, 0
    LAG.slice, LAG.sliceSpent, LAG.sliceDenied0 = 0, 0, STATS.raysDenied or 0
    LAG.profile = opts.profile
    LAG.errors = {}
    LAG.move = {}
    for _, band in ipairs({ "near", "far" }) do
        LAG.move[band] = { routedFrames = 0, stoppedRouted = 0, stops = 0, movingFrames = 0, stillFrames = 0,
            animWrongMoving = 0, animWrongStill = 0, botFrames = 0 }
    end
    LAG.thinkYields = 0
    BotService.RaycastBudget.FrameCap = opts.frameCap or 240
    SIM.teamMode = opts.layout == "teams"
    SIM.modeId = SIM.teamMode and "TeamDeathmatch" or "BattleRoyale"
    local hostileHook = BotService.IsHostile
    BotService.IsHostile = function(bot, other)
        LAG.cur.hostileAsks = LAG.cur.hostileAsks + 1
        return hostileHook(bot, other)
    end

    local centre = Vector3.new(0, 0, 0)
    if opts.layout == "spread" then
        for i = 1, 30 do
            local p = Vector3.new((math.random() * 2 - 1) * 580, 4, (math.random() * 2 - 1) * 580)
            SIM.addWall(p, Vector3.new(10, 8, 10))
        end
    elseif opts.layout == "roam" then
        for i = 1, 12 do
            local p = Vector3.new((math.random() * 2 - 1) * 200, 4, (math.random() * 2 - 1) * 200)
            if Vector3.new(p.X, 0, p.Z).Magnitude > 20 then SIM.addWall(p, Vector3.new(10, 8, 10)) end
        end
    elseif opts.layout == "packed" then
        wallsAt({ { Vector3.new(-18, 2.5, -10), Vector3.new(8, 5, 1.5) }, { Vector3.new(18, 2.5, 10), Vector3.new(8, 5, 1.5) },
            { Vector3.new(0, 2.5, 22), Vector3.new(1.5, 5, 8) }, { Vector3.new(-22, 2.5, 20), Vector3.new(4, 5, 4) },
            { Vector3.new(24, 2.5, -22), Vector3.new(4, 5, 4) }, { Vector3.new(6, 2.5, -26), Vector3.new(8, 5, 1.5) } })
    else
        wallsAt({ { Vector3.new(0, 2.5, 0), Vector3.new(4, 5, 12) }, { Vector3.new(-30, 2.5, 15), Vector3.new(8, 5, 1.5) },
            { Vector3.new(30, 2.5, -15), Vector3.new(8, 5, 1.5) }, { Vector3.new(-60, 2.5, 30), Vector3.new(6, 5, 1.5) },
            { Vector3.new(60, 2.5, -30), Vector3.new(6, 5, 1.5) } })
    end
    LAG.player = SIM.makePlayer("Player1", Vector3.new(0, 3, opts.layout == "teams" and 70 or 0))

    for i = 1, opts.n do
        local p, team
        if opts.layout == "spread" then
            p = randomIn(600, centre)
        elseif opts.layout == "roam" then
            p = randomIn(200, centre)
        elseif opts.layout == "packed" then
            p = randomIn(30, centre)
        else
            team = (i % 2) + 1
            p = randomIn(20, Vector3.new(team == 1 and -60 or 60, 0, 0))
        end
        local gun = opts.layout ~= "roam" and "CrocodiloRifle" or nil
        local bot = SIM.makeBot("Bot" .. i, ARCHES[(i - 1) % #ARCHES + 1], gun, p, team,
            { maxHealth = opts.health, bandages = 2 })
        LAG.giveTracks(bot)
    end
    BotService.Start()
end

-- #99: per frame, for each living bot, whether it is on a route and standing at the point it last
-- walked to, and whether its movement track fits what it is doing.
function LAGSCEN.watch()
    local playerAt = LAG.player.character.root.Position
    for _, bot in ipairs(BotService.GetAll()) do
        local c = bot.character
        if c.alive and bot.humanoid.Health > 0 then
            local gap = Vector3.new(c.root.Position.X - playerAt.X, 0, c.root.Position.Z - playerAt.Z).Magnitude
            local m = LAG.move[gap <= 300 and "near" or "far"]
            m.botFrames = m.botFrames + 1
            local speed = c.speedNow or 0
            local moving = speed > 0.5
            if moving then m.movingFrames = m.movingFrames + 1 else m.stillFrames = m.stillFrames + 1 end
            local track = bot.animPlaying
            if moving and track == "idle" then m.animWrongMoving = m.animWrongMoving + 1 end
            if not moving and (track == "walk" or track == "run") then m.animWrongStill = m.animWrongStill + 1 end
            local nav = bot.nav
            local routed = nav and nav.waypoints ~= nil and (bot.lastBranch == "wander" or bot.lastBranch == "loot")
            if routed then
                m.routedFrames = m.routedFrames + 1
                local t = c.walkTarget
                local reached = t and Vector3.new(t.X - c.root.Position.X, 0, t.Z - c.root.Position.Z).Magnitude < 0.6
                if reached and not moving then
                    m.stoppedRouted = m.stoppedRouted + 1
                    if not bot.lagStopped then m.stops = m.stops + 1 end
                    bot.lagStopped = true
                else
                    bot.lagStopped = false
                end
            else
                bot.lagStopped = false
            end
        end
    end
end

function LAGSCEN.run(seconds)
    local frames = math.floor(seconds * 60 + 0.5)
    for _ = 1, frames do
        LAG.frameStep(1 / 60)
        LAGSCEN.watch()
    end
    LAG.closeSlice()
end

function LAGSCEN.alive()
    local n = 0
    for _, bot in ipairs(BotService.GetAll()) do
        if bot.character.alive and bot.humanoid.Health > 0 then n = n + 1 end
    end
    return n
end
"""

# Wrappers around the loop's own calls: they watch, and hand straight on.
WRAP_LUA = r"""
-- A slice starts with BotNav.Pump (the loop calls it through the module table, before it opens the
-- ray budget in refreshCombatants; Pump casts no rays).
function LAG.closeSlice()
    if LAG.slice > 0 then
        LAG.sliceLog[#LAG.sliceLog + 1] = { spent = LAG.sliceSpent, denied = (STATS.raysDenied or 0) - LAG.sliceDenied0 }
    end
end
local realPump = BotNav.Pump
BotNav.Pump = function(...)
    LAG.closeSlice()
    LAG.slice = LAG.slice + 1
    LAG.sliceSpent = 0
    LAG.sliceDenied0 = STATS.raysDenied or 0
    return realPump(...)
end
local realDefers = BotService.LodDefers
BotService.LodDefers = function(bot, now)
    local deferred = realDefers(bot, now)
    if deferred then
        local root = bot.character:FindFirstChild("HumanoidRootPart")
        local list = LAG.deferAt[bot]
        if not list then list = {} LAG.deferAt[bot] = list end
        list[#list + 1] = CLOCK
        LAG.deferrals[#LAG.deferrals + 1] = { branch = bot.lastBranch or "none",
            playerDistance = root and BotService.SpatialQuery.NearestPlayerDistance(root.Position) or -1,
            hurt = bot.humanoid.Health < bot.lastHealth }
    end
    return deferred
end
"""


class Harness:
    """One Lua state with the whole of BotService and BotNav loaded from `sources` (path -> text)."""

    def __init__(self, root, sources):
        lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua = lua
        lua.execute("REAL_CLOCK = os.clock")
        lua.execute(perf.PRELUDE + sim.EXTRA_PRELUDE)

        def read_source(path):
            if path in sources:
                return perf.luau_to_lua(sources[path])
            try:
                return perf.luau_to_lua(read_tree(root, path))
            except FileNotFoundError:
                return None

        g = lua.globals()
        g.HANDLE = lua.execute(sim.LOADER)(read_source)
        lua.execute(sim.WORLD)
        lua.execute(open(os.path.join(HERE, "bot_lag_proof_world.lua"), encoding="utf-8").read(), g)
        g.WeaponData = g.require(g.HANDLE("ReplicatedStorage/Shared", "WeaponData"))
        g.MatchConfig = g.require(g.HANDLE("ReplicatedStorage/Shared", "MatchConfig"))
        g.CHANCE_AT = lua.execute(sim.chance_source(sources[BOTSERVICE]))
        g.BOT_TABLE = lua.execute(sim.bot_table_source(sources[BOTSERVICE]))
        m = re.search(r"^local THREAT_WINDOW = ([\d.]+)", sources[BOTSERVICE], flags=re.M)
        g.THREAT_WINDOW = float(m.group(1)) if m else 3

        fnames = lua.eval("FNAMES")
        for tag, path, chunk in (("S", BOTSERVICE, "BotService"), ("N", BOTNAV, NAV_SOURCE)):
            t = lua.table()
            for line, name in function_names(sources[path], tag).items():
                t[line] = name
            fnames[chunk] = t

        # The real BotNav, in place of the sim's mock.
        lua.execute("MOCKS.BotNav = nil")
        g.BotNav = g.require(g.HANDLE("ServerScriptService/Modules", "BotNav"))

        src = perf.luau_to_lua(sources[BOTSERVICE]).rstrip()
        assert src.endswith("return BotService")
        src = src[: -len("return BotService")] + (
            "\n_ENV.updateBot, _ENV.refreshCombatants, _ENV.STATS = updateBot, refreshCombatants, STATS\n"
            "return BotService\n")
        loader = lua.eval(r"""function(src, h)
            local env = setmetatable({ script = h }, { __index = _G })
            -- The loop calls pcall(updateBot, bot): count the think, then run it.
            env.pcall = function(f, ...)
                if f ~= nil and f == env.updateBot then
                    local bot = ...
                    LAG.cur.thinks = LAG.cur.thinks + 1
                    local list = LAG.thinksAt[bot]
                    if not list then list = {} LAG.thinksAt[bot] = list end
                    list[#list + 1] = CLOCK
                    LAG.inThink = true
                    local r = table.pack(pcall(f, ...))
                    LAG.inThink = false
                    if not r[1] then table.insert(LAG.errors, tostring(r[2])) end
                    return table.unpack(r, 1, r.n)
                end
                return pcall(f, ...)
            end
            local r = assert(load(src, 'BotService', 't', env))()
            updateBot, refreshCombatants, STATS = env.updateBot, env.refreshCombatants, env.STATS
            return r
        end""")
        g.BotService = loader(src, g.HANDLE("ServerScriptService/Modules", "BotService"))
        lua.execute(WRAP_LUA)
        lua.execute(SCENARIO_LUA)
        self.g = g

    def run(self, n, layout, seconds, seed=7, frame_cap=240, health=None, profile=False):
        g = self.g
        opts = self.lua.table_from({"n": n, "layout": layout, "seed": seed, "frameCap": frame_cap,
                                    "health": health or 100, "profile": profile})
        t0 = time.perf_counter()
        g.LAGSCEN.setup(opts)
        g.LAGSCEN.run(seconds)
        wall = time.perf_counter() - t0
        return self._collect(n, layout, seconds, frame_cap, wall)

    def _collect(self, n, layout, seconds, frame_cap, wall):
        g, lag = self.g, self.g.LAG
        frames = []
        for i in range(1, int(lag.frame) + 1):
            f = lag.frames[i]
            frames.append({k: f[k] for k in ("thinks", "rays", "raysBot", "unbudgeted", "overlaps", "blockcasts",
                                             "computeStarts", "moveTos", "moveTosOutsideThink", "hostileAsks",
                                             "claims", "samples", "ms", "mockMs", "sliceRays")}
                          | {"top": dict(f.top.items())})

        def pydict(t):
            return {k: t[k] for k in t.keys()}

        # Each gap between a bot's thinks, and whether LOD deferred it inside that gap.
        periods = []
        for bot in g.BotService.GetAll().values():
            ts = lag.thinksAt[bot]
            ts = list(ts.values()) if ts else []
            ds = lag.deferAt[bot]
            ds = list(ds.values()) if ds else []
            periods.append([(b - a, any(a < d < b for d in ds)) for a, b in zip(ts, ts[1:])])
        claim_gaps = []
        for bot in g.BotService.GetAll().values():
            if bot.character.alive and bot.humanoid.Health > 0:
                ts = lag.claims[bot.character]
                ts = list(ts.values()) if ts else []
                claim_gaps.append((len(ts), max([b - a for a, b in zip(ts, ts[1:])] or [0]),
                                   ts[0] if ts else None))
        grants = [(int(r.slice), int(r.n), str(r.priority)) for r in lag.grants.values()]
        slices = [(int(r.spent), int(r.denied)) for r in lag.sliceLog.values()]
        deferrals = [(str(r.branch), float(r.playerDistance), bool(r.hurt)) for r in lag.deferrals.values()]
        errors = list(lag.errors.values()) + list(g.SIM.errors.values())
        move = {band: pydict(lag.move[band]) for band in ("near", "far")}
        return {
            "n": n, "layout": layout, "seconds": seconds, "frameCap": frame_cap, "wall": wall,
            "frames": frames, "periods": periods, "claimGaps": claim_gaps, "grants": grants, "slices": slices,
            "deferrals": deferrals, "errors": errors, "move": move,
            "raysLeaf": pydict(lag.raysLeaf), "raysTop": pydict(lag.raysTop), "unbudgeted": pydict(lag.unbudgeted),
            "samplesSelf": pydict(lag.samplesSelf), "samplesTop": pydict(lag.samplesTop),
            "pathStarted": int(lag.pathStarted), "pathInFlightMax": int(lag.pathInFlightMax),
            "alive": int(g.LAGSCEN.alive()), "thinkYields": int(lag.thinkYields),
            "stats": {k: g.STATS[k] for k in g.STATS.keys() if isinstance(g.STATS[k], (int, float))},
        }


SCENARIOS = [
    # (name, n, layout, seconds, frame cap)
    ("spread-15", 15, "spread", 12, 240),
    ("spread-30", 30, "spread", 12, 240),
    ("spread-50", 50, "spread", 12, 240),
    ("packed-15", 15, "packed", 12, 240),
    ("packed-30", 30, "packed", 12, 240),
    ("packed-50", 50, "packed", 12, 240),
    ("teams-30", 30, "teams", 12, 240),
    ("roam-30", 30, "roam", 12, 240),
    ("stress-50", 50, "packed", 8, 40),
]


def run_all(harness, scenarios=SCENARIOS, profile=True):
    out = {}
    for name, n, layout, seconds, cap in scenarios:
        # Tanky bots: a packed 50 would otherwise be a dozen bots two seconds in, and the question
        # is what a crowd costs while it is a crowd. Health changes no budget.
        r = harness.run(n, layout, seconds, frame_cap=cap, health=400, profile=profile)
        if profile:
            # The profiler hook slows the Lua it samples: the milliseconds come from a second,
            # unprofiled run of the same scenario and seed.
            plain = harness.run(n, layout, seconds, frame_cap=cap, health=400, profile=False)
            r["msFrames"] = [f["ms"] - f["mockMs"] for f in plain["frames"]]
            r["msThinkFrames"] = [f["ms"] - f["mockMs"] for f in plain["frames"] if f["thinks"] > 0]
        out[name] = r
    return out


# --------------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------------

def checks(results):
    fails = []
    for name, r in results.items():
        n, frames = r["n"], r["frames"]
        # E1
        if r["errors"]:
            fails.append(f"E1 {name}: {len(r['errors'])} errors, first: {r['errors'][0][:160]}")
        # Y1
        if r["thinkYields"]:
            fails.append(f"Y1 {name}: {r['thinkYields']} thinks yielded part way (the slice stalls and its timing includes other work)")
        # T1
        worst = max(f["thinks"] for f in frames)
        if worst > math.ceil(n / 4):
            fails.append(f"T1 {name}: a frame carried {worst} thinks (> ceil({n}/4) = {math.ceil(n / 4)})")
        # T2: a gap with no deferral in it is one think period; with one, LodSkip periods.
        gaps = [p for ps in r["periods"] for p in ps]
        plain = [g for g, deferred in gaps if not deferred]
        lod = [g for g, deferred in gaps if deferred]
        if plain and max(plain) > THINK_FRAMES * FRAME + 1e-6:
            fails.append(f"T2 {name}: a bot LOD did not defer waited {max(plain):.3f} s between thinks "
                         f"(> {THINK_FRAMES} frames = {THINK_FRAMES * FRAME:.3f} s)")
        if lod and max(lod) > THINK_FRAMES * LOD_SKIP * FRAME + 1e-6:
            fails.append(f"T2 {name}: a deferred bot waited {max(lod):.3f} s between thinks "
                         f"(> {THINK_FRAMES * LOD_SKIP} frames)")
        if not plain:
            fails.append(f"T2 {name}: no bot thought twice")
        # R1
        if r["unbudgeted"]:
            rays = {k: v for k, v in r["unbudgeted"].items() if not k.startswith("GetPartBoundsInRadius")}
            if rays:
                fails.append(f"R1 {name}: rays from bot code outside the budget: {rays}")
        # R2
        cap = r["frameCap"]
        share = {"combat": 1, "navigation": 0.75, "idle": 0.5}
        over = [(s, k, p) for s, k, p in r["grants"] if k >= math.floor(cap * share.get(p, 0.75))]
        if over:
            fails.append(f"R2 {name}: {len(over)} rays granted past their share of {cap}, first slice {over[0][0]} "
                         f"ray #{over[0][1] + 1} ({over[0][2]})")
        worst_slice = max((s for s, _ in r["slices"]), default=0)
        if worst_slice > cap:
            fails.append(f"R2 {name}: a slice granted {worst_slice} rays (> cap {cap})")
        # R3
        early = [(s, d) for s, d in r["slices"] if d > 0 and s < math.floor(cap * 0.5)]
        if early:
            fails.append(f"R3 {name}: {len(early)} slices refused rays after spending only {early[0][0]} of {cap}")
        # P1 / P2
        starts = max(f["computeStarts"] for f in frames)
        if starts > MAX_STARTS:
            fails.append(f"P1 {name}: {starts} ComputeAsync started in one frame (> {MAX_STARTS})")
        if r["pathInFlightMax"] > MAX_IN_FLIGHT:
            fails.append(f"P2 {name}: {r['pathInFlightMax']} computes in flight (> {MAX_IN_FLIGHT})")
        # L1
        bad = [d for d in r["deferrals"] if d[1] <= 300 or d[0] in ("fight", "flee", "dodge", "storm") or d[2]]
        if bad:
            fails.append(f"L1 {name}: {len(bad)} deferrals of a bot near a player, fighting or hurt; first {bad[0]}")
        # C1
        limit = 1 + (THINK_FRAMES * (LOD_SKIP if r["deferrals"] else 1) + 1) * FRAME + 1e-6
        unclaimed = [g for g in r["claimGaps"] if g[0] == 0]
        late = [g for g in r["claimGaps"] if g[0] > 0 and g[1] > limit]
        if unclaimed:
            fails.append(f"C1 {name}: {len(unclaimed)} living bots never re-claimed")
        if late:
            fails.append(f"C1 {name}: a bot went {max(g[1] for g in late):.2f} s between claims (> {limit:.2f})")
    # P2 proves something only where the route queue actually filled the in-flight cap (roam-30 does).
    if "roam-30" in results and max(r["pathInFlightMax"] for r in results.values()) < MAX_IN_FLIGHT:
        fails.append(f"P2: no scenario reached {MAX_IN_FLIGHT} computes in flight (the cap was not exercised)")
    # The stress run must actually press the budget, or R2/R3 prove nothing there.
    s = results.get("stress-50")
    if s and not any(d > 0 for _, d in s["slices"]):
        fails.append("R2 stress-50: the lowered cap never refused a ray (the budget was not exercised)")
    return fails


# --------------------------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------------------------

def pct(xs, q):
    if not xs:
        return 0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def summary_line(name, r):
    frames = r["frames"][60:] or r["frames"]  # skip the first second's settling for means
    allf = r["frames"]

    def col(key):
        return [f[key] for f in allf]

    thinks = col("thinks")
    rays = col("raysBot")
    samples = col("samples")
    think_frames = [f for f in frames if f["thinks"] > 0]
    ms = r.get("msFrames") or [f["ms"] - f["mockMs"] for f in allf]
    ms_think = r.get("msThinkFrames") or [f["ms"] - f["mockMs"] for f in think_frames]
    mean = lambda xs: sum(xs) / len(xs) if xs else 0
    return (f"{name:10s} alive {r['alive']:2d}/{r['n']:2d}  thinks/frame worst {max(thinks):2d}  "
            f"rays/frame worst {max(rays):3d} mean(think frames) {mean([f['raysBot'] for f in think_frames]):5.1f}  "
            f"hostile asks/frame worst {max(col('hostileAsks')):4d}  "
            f"computes/frame worst {max(col('computeStarts'))} in flight max {r['pathInFlightMax']:2d}  "
            f"moveTo/frame worst {max(col('moveTos')):2d}  "
            f"kinstr/frame worst {max(samples):5d} p50(think frames) {pct([f['samples'] for f in think_frames], 0.5):4d}  "
            f"lupa ms worst {max(ms):5.2f} mean(think frames) {mean(ms_think):4.2f}")


def top_items(d, k=8):
    total = sum(d.values()) or 1
    items = sorted(d.items(), key=lambda kv: -kv[1])[:k]
    return ", ".join(f"{name} {v} ({100 * v / total:.0f}%)" for name, v in items)


def worst_frame_breakdown(r):
    f = max(r["frames"], key=lambda f: f["samples"])
    return f, top_items(f["top"], 6)


def report(results):
    print("--- per frame (60 Hz), whole BotService + BotNav in lupa; kinstr = thousands of game-code VM instructions")
    for name, r in results.items():
        print(summary_line(name, r))
    print("--- where the work goes (instruction samples by path updateBot took; whole run)")
    for name in ("spread-50", "packed-50", "teams-30"):
        r = results.get(name)
        if r:
            print(f"  {name} by path: {top_items(r['samplesTop'], 9)}")
            print(f"  {name} by function (self): {top_items(r['samplesSelf'], 9)}")
            f, br = worst_frame_breakdown(r)
            print(f"  {name} worst frame: {f['samples']} kinstr, {f['thinks']} thinks, {f['raysBot']} rays: {br}")
    print("--- rays by the function that asked (whole run)")
    for name in ("spread-50", "packed-50", "teams-30"):
        r = results.get(name)
        if r:
            print(f"  {name}: {top_items(r['raysLeaf'], 8)}")
            print(f"  {name} by path: {top_items(r['raysTop'], 6)}")
    print("--- not through the ray budget (whole run)")
    for name, r in results.items():
        if r["unbudgeted"]:
            print(f"  {name}: {r['unbudgeted']}")
    print("--- budget and LOD")
    for name, r in results.items():
        slices = r["slices"]
        denied = sum(d for _, d in slices)
        refusing = sum(1 for _, d in slices if d > 0)
        print(f"  {name}: {len(slices)} slices, most rays in a slice {max((s for s, _ in slices), default=0)} of cap "
              f"{r['frameCap']}; {denied} refused in {refusing} slices; LOD deferrals {len(r['deferrals'])}; "
              f"ComputeAsync {r['pathStarted']}, shared {int(r['stats'].get('pathShared', 0))}")
    print("--- #99 movement between thinks (living bots, every frame)")
    for name, r in results.items():
      for band in ("near", "far"):
        m = r["move"][band]
        if not m["botFrames"]:
            continue
        routed = m["routedFrames"] or 1
        print(f"  {name} {band}: on a route {m['routedFrames']} bot-frames, standing at a reached point {m['stoppedRouted']} "
              f"({100 * m['stoppedRouted'] / routed:.1f}%), {m['stops']} stops, mean stop "
              f"{(m['stoppedRouted'] / m['stops'] * 1000 / 60) if m['stops'] else 0:.0f} ms; walk/run track while standing "
              f"{100 * m['animWrongStill'] / max(1, m['stillFrames']):.1f}% of standing frames, idle track while moving "
              f"{100 * m['animWrongMoving'] / max(1, m['movingFrames']):.1f}% of moving frames; "
              f"MoveTo outside a think {sum(f['moveTosOutsideThink'] for f in r['frames'])}")
    print("--- linear scans of the whole combatant snapshot that remain (instruction samples, self)")
    for name, r in results.items():
        scans = {k: r["samplesSelf"].get(k, 0) for k in ("modeObjective", "BotService.Loot.threatened",
                 "BotService.Loot.enemiesNear", "placeBarricade", "tryThrow", "grid.Near")}
        total = sum(r["samplesSelf"].values()) or 1
        print(f"  {name}: " + ", ".join(f"{k} {v} ({100 * v / total:.1f}%)" for k, v in scans.items()))
    print("--- #126 packed vs spread (same N)")
    for n in (15, 30, 50):
        a, b = results.get(f"spread-{n}"), results.get(f"packed-{n}")
        if a and b:
            def per_think(r, key):
                t = sum(f["thinks"] for f in r["frames"]) or 1
                return sum(f[key] for f in r["frames"]) / t
            print(f"  N={n}: per think, hostile asks {per_think(a, 'hostileAsks'):.1f} spread / {per_think(b, 'hostileAsks'):.1f} packed; "
                  f"rays {per_think(a, 'raysBot'):.2f} / {per_think(b, 'raysBot'):.2f}; "
                  f"kinstr {per_think(a, 'samples'):.2f} / {per_think(b, 'samples'):.2f}; "
                  f"worst frame kinstr {max(f['samples'] for f in a['frames'])} / {max(f['samples'] for f in b['frames'])}")


# --------------------------------------------------------------------------------------------
# Planted faults: each breaks one invariant above in a copy of the source.
# --------------------------------------------------------------------------------------------

PLANTS = [
    (BOTSERVICE, "local THINK_SLICES = 4\n", "local THINK_SLICES = 1\n", "T1: every bot thinks in one frame (no slices)"),
    (BOTSERVICE, "\t\t\tslice = (slice + 1) % THINK_SLICES\n", "\t\t\tslice = (slice + 1) % (THINK_SLICES + 1)\n",
     "T2: a fifth, empty slice (each bot every 5 slices, not 4)"),
    (BOTSERVICE, "\t\tresult, granted = castRay(fromPart.Position, toPart.Position - fromPart.Position, params, \"combat\")\n",
     "\t\tresult, granted = workspace:Raycast(fromPart.Position, toPart.Position - fromPart.Position, params), true\n",
     "R1: sight lines cast round the budget"),
    (BOTSERVICE, "\t\tif spent >= budget.FrameCap * share then\n\t\t\tSTATS.raysDenied += 1\n\t\t\treturn nil, false\n",
     "\t\tif spent >= budget.FrameCap * 2 then\n\t\t\tSTATS.raysDenied += 1\n\t\t\treturn nil, false\n",
     "R2: the cap and the shares are twice what they say"),
    (BOTSERVICE, "\t\tBotService.RaycastBudget.BeginFrame()\n\t\tlocal count = 0\n", "\t\tlocal count = 0\n",
     "R3: the budget is never reopened after the first slice"),
    (BOTNAV, "local MAX_STARTS_PER_PUMP = 3\n", "local MAX_STARTS_PER_PUMP = 15\n", "P1: route starts unpaced (15 a pump)"),
    (BOTNAV, "local MAX_CONCURRENT_PATHS = 15\n", "local MAX_CONCURRENT_PATHS = 40\n", "P2: the in-flight cap 15 -> 40"),
    (BOTSERVICE, "BotService.LodActiveBranches = { fight = true, flee = true, dodge = true, storm = true }\n",
     "BotService.LodActiveBranches = { flee = true, dodge = true, storm = true }\n", "L1: a fighting bot far from players may be deferred"),
    (BOTSERVICE, "\tif not root or BotService.SpatialQuery.NearestPlayerDistance(root.Position) <= BotService.LodDistance then\n",
     "\tif not root then\n", "L1: LOD ignores where the players are"),
    (BOTSERVICE, "\tupdateAnimation(bot, humanoid)\n", "\tupdateAnimation(bot, humanoid)\n\tif math.random() < 0.02 then task.wait() end\n",
     "Y1: a think yields now and then"),
    (BOTSERVICE, "\tif now - (bot.claimedAt or 0) > 1 then\n", "\tif now - (bot.claimedAt or 0) > 3 then\n",
     "C1: physics re-claimed every 3 s, not every 1 s"),
]

# The scenarios each plant needs (a plant's run is a subset, for time).
PLANT_SCENARIOS = [s for s in SCENARIOS if s[0] in ("spread-30", "packed-30", "roam-30", "stress-50")]


def load_sources(root, rev=None):
    if rev:
        return {BOTSERVICE: read_rev(root, rev, BOTSERVICE), BOTNAV: read_rev(root, rev, BOTNAV)}
    return {BOTSERVICE: read_tree(root, BOTSERVICE), BOTNAV: read_tree(root, BOTNAV)}


def main():
    args = sys.argv[1:]
    root = args[0] if args and not args[0].startswith("--") else "."
    rev = args[args.index("--rev") + 1] if "--rev" in args else None
    sources = load_sources(root, rev)

    if "--plant" in args:
        caught = 0
        for path, old, new, what in PLANTS:
            assert sources[path].count(old) == 1, f"plant text not found once in {path}: {old!r}"
            planted = dict(sources)
            planted[path] = sources[path].replace(old, new)
            try:
                fails = checks(run_all(Harness(root, planted), PLANT_SCENARIOS, profile=False))
            except Exception as err:  # a plant that breaks the harness counts as caught, loudly
                fails = [f"harness error: {err}"]
            caught += bool(fails)
            print(f"plant [{'CAUGHT' if fails else 'MISSED'}] {what}: {fails[0] if fails else 'no check failed'}")
        print(f"bot_lag_proof_check plants: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)

    tree = f"revision {rev}" if rev else "working tree"
    print(f"bot_lag_proof_check: BotService + BotNav from the {tree}; ComputeAsync latency 0.4 s (stand-in); 60 Hz frames")
    harness = Harness(root, sources)
    results = run_all(harness, SCENARIOS, profile=True)
    report(results)
    fails = checks(results)
    examined = sum(len(r["frames"]) for r in results.values())
    thinks = sum(sum(f["thinks"] for f in r["frames"]) for r in results.values())
    rays = sum(sum(f["raysBot"] for f in r["frames"]) for r in results.values())
    for f in fails:
        print("FAIL", f)
    print(f"bot_lag_proof_check: {len(SCENARIOS)} scenarios, {examined} frames, {thinks} thinks, {rays} bot rays examined; "
          f"{len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
