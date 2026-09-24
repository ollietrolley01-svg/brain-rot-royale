"""Every battle royale ends (findings I5): after the last circle the storm closes to nothing.

    python3 tools/storm_end_check.py .            the checks
    python3 tools/storm_end_check.py . --plant    the planted faults; every one must be caught

The REAL StormService.lua and MatchConfig.lua run in lupa on a simulated clock (task.spawn / task.wait
are a tiny scheduler; the remote, Combatants and the terrain ray are mocks). One Start() on a 900-stud
map, with two campers standing at the middle of wherever the circle ends up, each healing a full Med
Kit (100 health) the moment one would finish (every 5 s), forever. INVARIANTS:

  end       both campers are dead before the schedule plus a minute has passed: sudden death closes
            the circle to radius 0 and hurts faster than any heal (the old storm held the last circle
            at 12 dmg/s forever, and a camper inside it was never touched)
  HUD       every StormChanged broadcast is one HudClient can say truthfully: `phase` never exceeds
            `totalPhases`, the phases broadcast are exactly 1..totalPhases, and "Final" (the HUD's
            "Final circle") is only sent once every phase, sudden death included, has run
  client    StormClient keeps drawing a circle whose radius is under 2 studs (it used to drop the wall
            and the storm cues the moment the collapse got there)

Needs `pip install lupa`.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("storm_end_check: needs lupa (pip install lupa)")

STORM = "ServerScriptService/Modules/StormService.lua"
CONFIG = "ReplicatedStorage/Shared/MatchConfig.lua"
CLIENT = "StarterPlayerScripts/StormClient.client.lua"
FILES = (STORM, CONFIG, CLIENT)


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


HARNESS = r"""
local stormSrc, configSrc, mapRadius = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end

-- Vector3, enough of it.
local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Lerp" then return function(a, b, t) return Vector3.new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t) end end
    return nil
end
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }
Vector3.zero = Vector3.new(0, 0, 0)
table.clone = table.clone or function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end

-- The clock and a scheduler for task.spawn / task.wait.
local now, queue = 0, {}
local function schedule(co, at) table.insert(queue, { co = co, at = at }) end
task = {
    spawn = function(fn, ...) local co = coroutine.create(fn); schedule(co, now); return co end,
    wait = function(d) coroutine.yield(d or 0) end,
}
local function resume(co)
    local ok, d = coroutine.resume(co)
    if not ok then error(d) end
    if coroutine.status(co) ~= "dead" then schedule(co, now + (d or 0)) end
end
local function runUntil(limit, each)
    while #queue > 0 do
        table.sort(queue, function(a, b) return a.at < b.at end)
        local job = table.remove(queue, 1)
        if job.at > limit then return end
        now = job.at
        resume(job.co)
        if each then each(now) end
    end
end

local config = assert(load(configSrc, "MatchConfig", "t", setmetatable({ Vector3 = Vector3 }, { __index = _G })))()
local broadcasts = {}
local remote = { FireAllClients = function(_, info) info.at = now; table.insert(broadcasts, info) end }
local characters = {}
local function node(name) return { Name = name, WaitForChild = function(_, n) return node(n) end } end
local function service() return node("service") end
local env = setmetatable({
    game = { GetService = function() return service() end },
    script = { Parent = node("Modules") },
    require = function(m)
        if m.Name == "MatchConfig" then return config end
        if m.Name == "Remotes" then return { Event = function() return remote end } end
        if m.Name == "Combatants" then return { All = function() return characters end } end
        error("no mock for " .. tostring(m.Name))
    end,
    RaycastParams = { new = function() return {} end },
    Enum = { RaycastFilterType = { Include = 1 }, Material = { Water = "Water" } },
    workspace = { Terrain = {}, Raycast = function() return nil end },
    warn = function() end,
    Vector3 = Vector3, task = task,
}, { __index = _G })
local Storm = assert(load(stormSrc, "StormService", "t", env))()
Storm.SetEligibility(function() return true end)

-- Two campers. Each stands wherever the circle is heading (they walked in with it) and drinks a full Med
-- Kit every 5 s, forever.
local function camper(name)
    local humanoid = { Health = 100, MaxHealth = 100 }
    function humanoid:TakeDamage(n) self.Health = math.max(0, self.Health - n) end
    local root = { Position = Vector3.zero }
    local character = { Parent = true, name = name }
    function character:FindFirstChildOfClass() return humanoid end
    function character:FindFirstChild() return root end
    characters[character] = name
    return { humanoid = humanoid, root = root }
end
local a, b = camper("A"), camper("B")
local nextHeal = 5
local deaths = {}

Storm.Start(mapRadius)
local phases = config.StormPhases
local schedule = 0
for _, p in ipairs(phases) do schedule = schedule + p.holdTime + p.shrinkTime end
if config.StormSuddenDeath then schedule = schedule + config.StormSuddenDeath.holdTime + config.StormSuddenDeath.shrinkTime end
local limit = schedule + 60
runUntil(limit, function(t)
    local s = Storm.GetState()
    for name, c in pairs({ A = a, B = b }) do
        -- Standing at the centre of the circle it is closing to, 1 stud apart.
        local offset = name == "A" and 0.5 or -0.5
        c.root.Position = Vector3.new(s.targetCenter.X + offset, 0, s.targetCenter.Z)
        if c.humanoid.Health > 0 and t >= nextHeal then
            c.humanoid.Health = math.min(100, c.humanoid.Health + 100)
        end
        if c.humanoid.Health <= 0 and not deaths[name] then deaths[name] = t end
    end
    if t >= nextHeal then nextHeal = nextHeal + 5 end
end)

check(deaths.A and deaths.B, string.format("two healing campers at the middle of the last circle both die (A at %s s, B at %s s; schedule %d s)",
    tostring(deaths.A), tostring(deaths.B), schedule))
local final = broadcasts[#broadcasts]
check(final and final.status == "Final" and final.radius == 0, string.format("the storm ends Final at radius 0 (last: %s, radius %s)",
    final and final.status or "none", final and tostring(final.radius) or "-"))

-- The HUD's view of it.
local seen, bad, maxPhase, total = {}, nil, 0, nil
local finalBefore = nil
for _, info in ipairs(broadcasts) do
    total = total or info.totalPhases
    if info.totalPhases ~= total then bad = bad or ("totalPhases changed mid-match at " .. info.at .. " s") end
    if info.phase > info.totalPhases then bad = bad or string.format("phase %d of %d at %s s", info.phase, info.totalPhases, info.at) end
    if info.phase > 0 then seen[info.phase] = true; maxPhase = math.max(maxPhase, info.phase) end
    if info.status == "Final" and not finalBefore then finalBefore = info end
end
local contiguous = true
for i = 1, total or 0 do if not seen[i] then contiguous = false end end
check(bad == nil, "no broadcast says a circle past the last one (" .. (bad or "phase <= totalPhases throughout") .. ")")
check(contiguous and maxPhase == total, string.format("the circles broadcast are exactly 1..%s (highest %d)", tostring(total), maxPhase))
check(finalBefore ~= nil and finalBefore.phase == total and finalBefore.radius == 0,
    string.format("\"Final\" is first sent once every circle has closed (phase %s, radius %s)",
        finalBefore and tostring(finalBefore.phase) or "-", finalBefore and tostring(finalBefore.radius) or "-"))
return out
"""


def client_rows(src):
    head = src.index("stormChanged.OnClientEvent:Connect(function(info)")
    handler = src[head:src.index("\nend)\n", head)]
    cond = re.search(r"if (not info or [^\n]*) then", handler)
    hides_small = cond is not None and re.search(r"radius\s*<", cond.group(1)) is not None
    return [(cond is not None and not hides_small,
             "StormClient keeps drawing a circle under 2 studs (hide test: %s)" % (cond.group(1) if cond else "not found"))]


def run_lua(code, *args):
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        result = lua.execute(code, *args)
        return [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]


def all_rows(sources):
    rows = run_lua(HARNESS, luau_to_lua(sources[STORM]), luau_to_lua(sources[CONFIG]), 900)
    try:
        rows += client_rows(sources[CLIENT])
    except ValueError as exc:
        rows.append((False, "client: source shape changed: %s" % exc))
    return rows


PLANTS = [
    ("no sudden death (the old storm)", STORM, "\tif MatchConfig.StormSuddenDeath then\n", "\tif false then\n"),
    ("sudden death that never reaches 0", CONFIG, "radiusScale = 0, damagePerSecond = 25", "radiusScale = 0.02, damagePerSecond = 25"),
    ("sudden death a Med Kit out-heals", CONFIG, "radiusScale = 0, damagePerSecond = 25", "radiusScale = 0, damagePerSecond = 12"),
    ("HUD told the old phase count", STORM, "totalPhases = #StormService.Phases(),", "totalPhases = #MatchConfig.StormPhases,"),
    ("StormClient drops a small circle again", CLIENT, 'info.status == "Idle" or not info.radius then',
     'info.status == "Idle" or not info.radius or info.radius < 2 then'),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {rel: open(os.path.join(root, rel), encoding="utf-8").read() for rel in FILES}
    if "--plant" in sys.argv:
        caught = 0
        for label, rel, old, new in PLANTS:
            if sources[rel].count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            planted = dict(sources)
            planted[rel] = sources[rel].replace(old, new)
            failed = [line for ok, line in all_rows(planted) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"storm_end_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = all_rows(sources)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"storm_end_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
