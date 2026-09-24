"""Behaviour check for #93: the objective ring players see and the capture test agree, without Studio.

Runs the real ReplicatedStorage/Shared/ObjectiveZone.lua and the real
ServerScriptService/Modules/ModeKingOfTheHill.lua in lupa, with Instance, Vector3, CFrame,
Combatants and ModeTeams mocked. Start() builds the objectives; the harness then reads the
HillRing part it built the way Roblox draws it (a Cylinder's length is its X axis, its diameter
the smaller of Y and Z) and stands one body at a time on points just inside, exactly on and just
outside that drawn edge, asking the real Occupancy() whether it counts. Every point must get the
same answer from both. Run for the default radius and for a non-default one, so a hardcoded 28
anywhere shows up.

    python tools/objective_zone_check.py .            the checks
    python tools/objective_zone_check.py . --plant    the planted faults; every one must be caught

Needs `pip install lupa`.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("objective_zone_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    # x += y / x -= y  ->  x = x + y / x = x - y   (the only Luau-only syntax these files use)
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+-])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


HARNESS = r"""
local zoneSrc, kothSrc, hillRadius = ...
local loadChunk = load

-- Vector3 / CFrame, enough for the ring and the capture test.
local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    return V[k]
end
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V) end
V.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return vec(a.X * b, a.Y * b, a.Z * b)
end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }

local C = {}
C.__index = C
local function mat(m, p) return setmetatable({ m = m, Position = p }, C) end
local function mmul(a, b)
    local r = {}
    for i = 0, 2 do for j = 0, 2 do
        local s = 0
        for k = 0, 2 do s = s + a[i * 3 + k + 1] * b[k * 3 + j + 1] end
        r[i * 3 + j + 1] = s
    end end
    return r
end
local function apply(m, v)
    return vec(m[1] * v.X + m[2] * v.Y + m[3] * v.Z, m[4] * v.X + m[5] * v.Y + m[6] * v.Z, m[7] * v.X + m[8] * v.Y + m[9] * v.Z)
end
C.__mul = function(a, b) return mat(mmul(a.m, b.m), a.Position + apply(a.m, b.Position)) end
local I = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
CFrame = {
    new = function(p) return mat(I, p or vec(0, 0, 0)) end,
    Angles = function(x, y, z)
        local cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
        local rx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
        local ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
        local rz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
        return mat(mmul(mmul(rx, ry), rz), vec(0, 0, 0))
    end,
}

-- Instances: plain property bags; every Part is remembered so the harness can read the rings.
local parts = {}
local Inst = {}
Inst.__index = Inst
function Inst:SetAttribute(k, v) self.attributes[k] = v end
function Inst:Destroy() self.Parent = nil end
Instance = { new = function(class)
    local o = setmetatable({ ClassName = class, attributes = {} }, Inst)
    if class == "Part" then table.insert(parts, o) end
    return o
end }
local anyEnum = setmetatable({}, { __index = function(t, k)
    return setmetatable({ Name = k }, { __index = function(_, j) return k .. "." .. j end })
end })
Enum = anyEnum
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end }
UDim2 = { fromOffset = function() return {} end, fromScale = function() return {} end }
UDim = { new = function() return {} end }
RaycastParams = { new = function() return {} end }
workspace = { Terrain = {}, Raycast = function() return nil end }
table.clear = function(t) for k in pairs(t) do t[k] = nil end end

-- The world the capture test sees: one body at a time, team 1.
local bodies = {}
local Combatants = { All = function() return bodies end }
local ModeTeams = {
    Arena = function() return vec(0, 0, 0), 1000 end,
    RefusePad = function() return false end,
    TeamOf = function(token) return token.team end,
    IsDowned = function() return false end,
}
local ZoneModule = assert(loadChunk(zoneSrc, "ObjectiveZone"))()
local shared = { GameModes = { TeamColor = function() return {} end, TeamName = function() return "" end },
    ZFight = { FixTolerance = 0 }, ObjectiveZone = ZoneModule }
local server = { Combatants = Combatants, ModeTeams = ModeTeams }
local sharedFolder = { WaitForChild = function(_, n) return { module = shared[n] } end }
game = { GetService = function() return { WaitForChild = function() return sharedFolder end } end }
script = { Parent = { WaitForChild = function(_, n) return { module = server[n] } end } }
require = function(o) return assert(o.module, "unmocked require") end

local KOTH = assert(loadChunk(kothSrc, "ModeKingOfTheHill"))()
local mode = { hillRadius = hillRadius, hillHeight = 22 }
if hillRadius == 0 then mode = {} end
KOTH.Start(mode, { landmarks = { { X = 100, Z = 50 }, { X = -300, Z = -200 } } })

local function standAt(p)
    for k in pairs(bodies) do bodies[k] = nil end
    local character = { Parent = true }
    local humanoid = { Health = 100 }
    local root = { Position = p }
    function character:FindFirstChildOfClass() return humanoid end
    function character:FindFirstChild() return root end
    bodies[character] = { team = 1 }
end

local out = { rings = {} }
for _, objective in ipairs(KOTH.Objectives()) do
    local ring
    for _, p in ipairs(parts) do
        if p.Name == "HillRing" and p.Parent and (p.CFrame.Position - objective.position - vec(0, p.CFrame.Position.Y - objective.position.Y, 0)).Magnitude < 1e-6 then
            ring = p
        end
    end
    local r = { centre = { objective.position.X, objective.position.Y, objective.position.Z }, samples = {} }
    if ring then
        -- As Roblox draws it: the cylinder's axis is its local X; the disc is flat only if that is up.
        local axis = apply(ring.CFrame.m, vec(1, 0, 0))
        r.shape = tostring(ring.Shape)
        r.axisUp = math.abs(axis.Y)
        r.drawnRadius = math.min(ring.Size.Y, ring.Size.Z) / 2
        r.drawnCentre = { ring.CFrame.Position.X, ring.CFrame.Position.Z }
        r.attrRadius = ring.Parent and ring.Parent.attributes and ring.Parent.attributes.HillRadius
    end
    out.rings[#out.rings + 1] = r
    r.probe = function(dx, dz, dy)
        standAt(objective.position + vec(dx, dy or 3, dz))
        return KOTH.Occupancy(objective.position)[1] == 1
    end
end
return out
"""


def run(zone_src, koth_src, radius):
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(HARNESS, luau_to_lua(zone_src), luau_to_lua(koth_src), radius)


def edge_points(r):
    """(dx, dz) on, inside and outside the edge of a circle of radius r. A point exactly ON the edge
    is only used where it is exactly representable (the axes, and a 3-4-5 triple when r is a
    multiple of 5), so float rounding in building the point cannot decide the answer."""
    pts = []
    for ux, uz in ((1, 0), (0, 1), (-1, 0), (0, -1), (0.6, 0.8), (-0.8, 0.6), (-0.6, -0.8), (0.8, -0.6)):
        exact = r % 5 == 0 or ux == 0 or uz == 0
        for scale in (0.0, 0.5, 1.0 - 1e-3, 1.0, 1.0 + 1e-3, 1.5):
            if scale == 1.0 and not exact:
                continue
            if scale == 1.0:
                pts.append((round(ux * r), round(uz * r)))
            else:
                pts.append((ux * r * scale, uz * r * scale))
    return pts


def checks(zone_src, koth_src):
    results = []
    examined = 0
    for label, radius, expect in (("default mode (no hillRadius)", 0, 28), ("hillRadius 35", 35, 35)):
        out = run(zone_src, koth_src, radius)
        rings = list(out["rings"].values())
        results.append((f"{label}: two objectives built, each with a ring", len(rings) == 2 and all(r["drawnRadius"] for r in rings),
                        f"{len(rings)} objectives"))
        for index, ring in enumerate(rings):
            name = f"{label} objective {'AB'[index]}"
            if not ring["drawnRadius"]:
                continue
            results.append((f"{name}: ring is a Cylinder lying flat", ring["shape"].endswith("Cylinder") and ring["axisUp"] > 0.999,
                            f"shape {ring['shape']}, |axis.Y| {ring['axisUp']:.3f}"))
            results.append((f"{name}: drawn radius is the mode's radius", abs(ring["drawnRadius"] - expect) < 1e-9,
                            f"drawn {ring['drawnRadius']}, mode {expect}"))
            cx, cz = ring["centre"][1], ring["centre"][3]
            dcx, dcz = ring["drawnCentre"][1], ring["drawnCentre"][2]
            disagree = []
            for dx, dz in edge_points(expect):
                examined += 1
                # The drawn disc, closed: its painted edge is part of it.
                drawn = (cx + dx - dcx) ** 2 + (cz + dz - dcz) ** 2 <= ring["drawnRadius"] ** 2 + 1e-9
                captured = ring["probe"](dx, dz)
                if drawn != captured:
                    disagree.append((round(dx, 3), round(dz, 3), "drawn" if drawn else "not drawn", "counts" if captured else "doesn't count"))
            results.append((f"{name}: capture == drawn disc at {len(edge_points(expect))} points", not disagree,
                            f"{len(disagree)} disagree {disagree[:3]}"))
            results.append((f"{name}: a body 30 studs above the ring does not capture", not ring["probe"](0, 0, 30), ""))
    return results, examined


def plants(zone, koth):
    yield "ring diameter = radius (drawn half size)", zone.replace("local diameter = ObjectiveZone.Radius(mode) * 2", "local diameter = ObjectiveZone.Radius(mode)"), koth
    yield "capture excludes the painted edge", zone.replace("<= radius * radius", "< radius * radius"), koth
    yield "capture reaches 2 studs past the paint", zone.replace("<= radius * radius", "<= (radius + 2) * (radius + 2)"), koth
    yield "ring not turned (cylinder stands on edge)", zone.replace(" * CFrame.Angles(0, 0, math.pi / 2)", ""), koth
    yield "capture bypasses the module with a hardcoded 28", zone, koth.replace(
        "if ObjectiveZone.Contains(mode, point, root.Position) then",
        "local o = root.Position - point\n\t\t\t\tif Vector3.new(o.X, 0, o.Z).Magnitude <= 28 and o.Y >= -6 and o.Y <= height() then")
    yield "ring bypasses the module with a hardcoded size", zone, koth.replace(
        "ring.Size = ObjectiveZone.RingSize(mode)", "ring.Size = Vector3.new(0.4, 56, 56)")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    zone = read(root, "ReplicatedStorage", "Shared", "ObjectiveZone.lua")
    koth = read(root, "ServerScriptService", "Modules", "ModeKingOfTheHill.lua")
    if "--plant" in sys.argv:
        caught = total = 0
        for label, z, k in plants(zone, koth):
            total += 1
            if z == zone and k == koth:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            try:
                results, _ = checks(z, k)
            except Exception as err:  # the harness breaking is not a catch
                print(f"  CRASHED: {label}: {str(err).splitlines()[0]}")
                continue
            failed = [name for name, ok, _ in results if not ok]
            if failed:
                caught += 1
                print(f"  caught: {label} -> {failed[0]}")
            else:
                print(f"  MISSED: {label}")
        print(f"objective zone plants: {caught} of {total} caught")
        sys.exit(0 if caught == total else 1)
    results, examined = checks(zone, koth)
    bad = 0
    for name, ok, detail in results:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
        bad += 0 if ok else 1
    print(f"objective zone check: {len(results)} checks ({examined} points examined), {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
