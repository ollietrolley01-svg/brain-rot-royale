"""Behaviour check for the per-material footsteps (#120), without Studio.

Runs the real StarterPlayerScripts/FootstepClient.client.lua and ReplicatedStorage/Shared/SoundConfig.lua
in a Lua interpreter (lupa) with bodies, Heartbeat and Sfx mocked, drives ten seconds of frames and
counts the steps each body made and what they sounded like.

    python tools/sound_footstep_check.py .            the checks
    python tools/sound_footstep_check.py . --plant    the planted faults; every one must be caught

The cadence is re-derived here from gait figures (1.4 + 0.3 x speed in m/s steps a second, 0.28 m
a stud), not read back from SoundConfig. The asset side of the step cues is held by
tools/sound_acoustics_check.py (every layer a measured rbxasset file).

Needs `pip install lupa`. Luau's compound assignments are rewritten to plain Lua before loading.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("sound_footstep_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*/%])= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def cadence(speed):
    if speed < 2:
        return 0
    return min(3.4, max(1.6, 1.4 + 0.3 * speed * 0.28))


HARNESS = r"""
local scSrc, clientSrc, stepVolume = ...
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end

local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    return V[k]
end
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }

local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        table.insert(self.handlers, fn)
        return { Disconnect = function() for i, h in ipairs(s.handlers) do if h == fn then table.remove(s.handlers, i) end end end }
    end
    function s:Fire(...) for _, h in ipairs(self.handlers) do h(...) end end
    return s
end

-- A proxy instance: properties in _d, changes fire GetPropertyChangedSignal.
local P = {}
P.__index = function(t, k)
    local d = rawget(t, "_d")
    if d[k] ~= nil then return d[k] end
    return P[k]
end
P.__newindex = function(t, k, v)
    local d = rawget(t, "_d")
    d[k] = v
    if d.signals[k] then d.signals[k]:Fire() end
end
function P:IsA(c) return self._d.ClassName == c or (c == "Model" and self._d.ClassName == "Model") end
function P:GetPropertyChangedSignal(k)
    self._d.signals[k] = self._d.signals[k] or signal()
    return self._d.signals[k]
end
function P:GetChildren() return self._d.kids end
function P:FindFirstChild(n) for _, c in ipairs(self._d.kids) do if c.Name == n then return c end end end
function P:FindFirstChildOfClass(cn) for _, c in ipairs(self._d.kids) do if c._d.ClassName == cn then return c end end end
function P:GetAttribute(n) return self._d.attrs[n] end
function P:GetState() return self._d.state end
function P:WaitForChild(n) return self:FindFirstChild(n) end
local function inst(className, props)
    local d = { ClassName = className, Name = className, kids = {}, attrs = {}, signals = {} }
    for k, v in pairs(props or {}) do d[k] = v end
    return setmetatable({ _d = d }, P)
end
local function add(parent, child)
    table.insert(parent._d.kids, child)
    child._d.Parent = parent
    if parent._d.ChildAdded then parent._d.ChildAdded:Fire(child) end
end

Enum = { HumanoidStateType = { Swimming = "Swimming", Climbing = "Climbing", Running = "Running" } }
workspace = inst("Workspace")
workspace._d.CurrentCamera = { CFrame = { Position = Vector3.new(0, 0, 0) } }

local heartbeat = signal()
local localPlayer = { Character = nil }
local plays = {}
local Sfx = {
    Play = function(cue, j, p, gain) table.insert(plays, { flat = true, cue = cue, gain = gain }) end,
    PlayAt = function(cue, pos, j, t, gain) table.insert(plays, { flat = false, cue = cue, x = pos.X, gain = gain }) end,
}
local SoundConfig = load(scSrc, "SoundConfig")()
local MovementConfig = { Crouch = { StepVolume = stepVolume } }
local mods = { SoundConfig = SoundConfig, MovementConfig = MovementConfig }
local shared = { WaitForChild = function(_, n) return n end }
local services = {
    Players = { LocalPlayer = localPlayer },
    ReplicatedStorage = { WaitForChild = function() return shared end },
    RunService = { Heartbeat = heartbeat },
}
game = { GetService = function(_, n) return services[n] end }
script = { Parent = { WaitForChild = function() return "Sfx" end } }
local realRequire = require
require = function(m)
    if m == "Sfx" then return Sfx end
    if mods[m] then return mods[m] end
    return realRequire(m)
end
load(clientSrc, "FootstepClient")()

local api = { SC = SoundConfig }
-- A body at x on `material`, moving at `speed` studs/s across the ground.
function api.body(x, material, speed, opts)
    opts = opts or {}
    local model = inst("Model", { Name = "Body" .. x })
    local humanoid = inst("Humanoid", { Health = 100, HipHeight = 2, FloorMaterial = { Name = material }, state = opts.state or "Running" })
    local root = inst("Part", { Name = "HumanoidRootPart", Position = Vector3.new(x, 3, 0), Size = Vector3.new(2, 2, 1),
        AssemblyLinearVelocity = Vector3.new(0, opts.vy or 0, speed), ChildAdded = signal() })
    add(model, humanoid)
    add(model, root)
    if opts.crouch then model._d.attrs.Crouching = true end
    if opts.running then add(root, inst("Sound", { Name = "Running", SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3" })) end
    add(workspace, model)
    if opts.self then localPlayer.Character = model end
    return model, root
end
function api.addRunning(root)
    local s = inst("Sound", { Name = "Running", SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3" })
    add(root, s)
    return s
end
function api.run(seconds, dt)
    for _ = 1, math.floor(seconds / dt + 0.5) do heartbeat:Fire(dt) end
end
function api.takePlays() local out = plays; plays = {}; return out end
return api
"""


def sources(root):
    read = lambda *p: open(os.path.join(root, *p), encoding="utf-8").read()
    sc = read("ReplicatedStorage", "Shared", "SoundConfig.lua")
    client = read("StarterPlayerScripts", "FootstepClient.client.lua")
    step_volume = float(re.search(r"StepVolume = ([\d.]+)", read("ReplicatedStorage", "Shared", "MovementConfig.lua")).group(1))
    return sc, client, step_volume


def checks(sc, client, step_volume):
    lua = LuaRuntime(unpack_returned_tuples=True)
    api = lua.execute(HARNESS, luau_to_lua(sc), luau_to_lua(client), step_volume)
    SC = api.SC
    results = []
    tbl = lambda **k: lua.table_from(k)

    # The map: every family reachable, every cue real, Air silent, an unknown floor a hard one.
    families = {"Grass": "FootstepGrass", "Concrete": "FootstepConcrete", "WoodPlanks": "FootstepWood",
                "DiamondPlate": "FootstepMetal", "Water": "FootstepWater", "Sand": "FootstepSand",
                "Plastic": "FootstepConcrete", "Air": None}
    wrong = {m: SC.FootstepCue(m) for m, want in families.items() if SC.FootstepCue(m) != want}
    unresolved = [c for c in SC.Footsteps.MATERIAL.values() if not SC.Get(c)]
    reach = [SC.Rolloff(c, SC.Sounds[c])[1] for c in set(families.values()) if c]
    results.append(("each floor gets its own step; air none; every step cue resolves and fits REACH",
                    not wrong and not unresolved and max(reach) <= SC.Footsteps.REACH,
                    f"{len(list(SC.Footsteps.MATERIAL.keys()))} materials mapped; wrong {wrong} unresolved {unresolved}"))

    # Cadence against gait figures.
    bad = [(v, round(SC.StepRate(v), 3), round(cadence(v), 3)) for v in (0, 1, 5, 8, 16, 22, 26, 40)
           if abs(SC.StepRate(v) - cadence(v)) > 1e-6]
    results.append(("cadence: ~1.8 steps/s at a walk, 2.74 at 16 studs/s, capped at 3.4", not bad, f"{bad}"))

    # Ten seconds of frames with a street of bodies.
    api.body(20, "Grass", 16)
    api.body(10, "Concrete", 0)                       # standing
    api.body(15, "Air", 16, tbl(vy=30))               # mid-jump
    api.body(200, "Concrete", 16)                     # out of reach
    api.body(12, "WoodPlanks", 8, tbl(crouch=True))
    api.body(25, "Water", 16)
    api.body(18, "Grass", 16, tbl(state="Swimming"))
    _, late_root = api.body(30, "DiamondPlate", 22)
    api.body(1, "Plastic", 16, tbl(self=True, running=True))
    api.run(0.5, 1 / 60)
    running = api.addRunning(late_root)               # made after the body was first seen
    api.run(9.5, 1 / 60)
    plays = list(api.takePlays().values())
    by_x = {}
    for p in plays:
        key = "self" if p.flat else round(p.x)
        by_x.setdefault(key, []).append(p)
    errors = []
    for key, cue, speed in ((20, "FootstepGrass", 16), (25, "FootstepWater", 16), (30, "FootstepMetal", 22),
                            (12, "FootstepWood", 8), ("self", "FootstepConcrete", 16)):
        got = by_x.get(key, [])
        want = 10 * cadence(speed)
        if abs(len(got) - want) > 1.5 or any(p.cue != cue for p in got):
            errors.append(f"{key}: {len(got)} steps ({set(p.cue for p in got)}), want ~{want:.1f} {cue}")
    for key in (10, 15, 200, 18):
        if by_x.get(key):
            errors.append(f"{key}: {len(by_x[key])} steps from a body that shouldn't step")
    results.append(("steps at the gait cadence on the right floor; none standing, airborne, swimming or out of reach",
                    not errors, f"{len(plays)} steps from 9 bodies over 10 s; {errors[:3]}"))

    crouched = by_x.get(12, [])
    want_gain = max(0.7, min(1.25, 8 / 16)) * step_volume
    selfs = by_x.get("self", [])
    ok = crouched and all(abs(p.gain - want_gain) < 1e-6 for p in crouched) and selfs and all(
        abs(p.gain - SC.Footsteps.SELF_GAIN) < 1e-6 for p in selfs)
    results.append(("a crouched body steps at StepVolume; your own steps flat and quieter", bool(ok),
                    f"crouched {crouched[0].gain if crouched else None} want {want_gain:.3f}"))

    # The built-in loop: silenced when seen, when made later, and when something sets it back.
    running.SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3"
    results.append(("Roblox's Running loop is silenced and stays silenced", running.SoundId == "",
                    f"after reset: {running.SoundId!r}"))

    # A crowd: only the nearest MAX_BODIES step.
    api2 = lua.execute(HARNESS, luau_to_lua(sc), luau_to_lua(client), step_volume)
    for i in range(14):
        api2.body(5 + i * 5, "Grass", 16)
    api2.run(5, 1 / 60)
    heard = sorted({round(p.x) for p in api2.takePlays().values()})
    cap = api2.SC.Footsteps.MAX_BODIES
    results.append((f"a crowd is capped to the nearest {cap}", len(heard) == cap and max(heard) == 5 + (cap - 1) * 5,
                    f"14 walking bodies, {len(heard)} heard: {heard}"))
    return results


def plants(sc, client):
    yield "air steps like a floor", sc.replace('if materialName == nil or materialName == "Air" then', "if materialName == nil then"), client
    yield "no cap on bodies", sc, client.replace("math.min(#near, STEPS.MAX_BODIES)", "#near")
    yield "cadence from studs as if metres", sc.replace("local metres = speed * Acoustics.METRES_PER_STUD", "local metres = speed"), client
    yield "the loop is silenced once only", sc, client.replace(
        '\t\t\ttable.insert(entry.connections, child:GetPropertyChangedSignal("SoundId"):Connect(function()\n\t\t\t\tsilence(child)',
        '\t\t\ttable.insert(entry.connections, child:GetPropertyChangedSignal("SoundId"):Connect(function()\n\t\t\t\tlocal _ = child')
    yield "water sounds like concrete", sc.replace('\t\tWater = "FootstepWater",\n', ""), client
    yield "crouching is not quieter", sc, client.replace("\t\tgain *= CROUCH.StepVolume\n", "")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sc, client, step_volume = sources(root)
    if "--plant" in sys.argv:
        caught = total = 0
        for label, psc, pclient in plants(sc, client):
            total += 1
            if psc == sc and pclient == client:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            try:
                failed = [name for name, ok, _ in checks(psc, pclient, step_volume) if not ok]
            except Exception as err:
                failed = [f"crashed: {str(err).splitlines()[0][:80]}"]
            if failed:
                caught += 1
                print(f"  caught: {label} -> {failed[0]}")
            else:
                print(f"  MISSED: {label}")
        print(f"footstep planted faults: {caught}/{total} caught")
        sys.exit(0 if caught == total else 1)
    results = checks(sc, client, step_volume)
    for name, ok, detail in results:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
    failed = sum(1 for _, ok, _ in results if not ok)
    print(f"footsteps: {len(results) - failed}/{len(results)} checks pass")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
