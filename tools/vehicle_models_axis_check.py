"""Rod, bat and mount audit for VehicleModels (OLIVER_LIST #61 / #116 / #50), without Studio.

Runs the REAL ReplicatedStorage/Shared/VehicleModels.lua AND the real Shared/ZFight.lua under lupa
with a small CFrame / Vector3 / Instance mock, builds every model in every scheme three ways --
drivable (Build, armed where VehicleModels.Mounts says so), unarmed, and BuildStatic (the parked
prop, which drops parts) -- and reads every part's world frame back AFTER the z-fight pass, which is
the frame the game shows. (The first version of this check stubbed ZFight out; a pass that grows or
nudges a thin part is exactly what could push a pole out or split a bat, so it runs for real now.)

For every part it works out the LONG axis the way Roblox draws it -- a Cylinder's length is its
own X axis whatever Size.Y and Size.Z say (COORDINATION: the Cylinder X-axis lesson), a block's
is its longest side -- and treats as a rod anything with two thin sides (<= 0.6) and a length at
least 2.5 times the thicker of them.

Invariants, each aimed at something the models must refuse forever:
  1. A cylinder is round: Size.Y equals Size.Z (Roblox draws the smaller one, so a mismatch means
     someone passed the length in Y).
  2. No rod reaches more than 0.3 studs past the envelope of the vehicle's non-rod parts.
  3. No rod has a bare end: walking in from each end, its surface meets another visible part
     within 0.4 studs (or twice its thickness, if more). A bare end is "a pole coming out of the
     vehicle", whatever angle it is at. There is no allow-list any more: a lean is fine only because
     the rod runs between things it is fixed to, and this proves it for every one (A-pillars,
     snorkel, roll-bar braces, mirror arms, drumsticks, rope, arch lips, spokes, seat backs,
     steering wheel -- all 0.15 or less). Turret parts are exempt: a gun barrel is meant to stick out.
  4. The z-fight pass never pushes a rod out: any rod it moves or grows along its length has no
     barer end afterwards than as built (to 0.05), and it does not touch the bat at all.
  5. The bat (Sahur Van), in every build that has it:
       - every piece is present (BuildStatic keeps it too),
       - it is straight: every round piece coaxial with BatKnob->BatEnd within 1 degree, and it runs
         along the van in plan (heading within 3 degrees of Z; the rake is fine),
       - it is one object: consecutive pieces meet end to end (gap <= 0.02), the knob sits on the
         handle's end and the end cap on the barrel's,
       - it rests on the rack: handle and barrel each sit on a rack bar (underside 0..0.05 above
         the bar's top), and the straps touch both bat and bar,
       - nothing else overlaps it except the straps and the bars it rests on.
  6. An armed build's weapons clear the rest of the vehicle through their WHOLE aim arcs (yaw and
     pitch limits from VehicleWeaponData, 5 degree steps): no part of the turret comes within 0.05 of
     a visible part that is not the turret's own, and the same for the driver's gun (DriverGun*,
     VehicleModels.DriverMounts, VehicleWeaponData.DriverByModel).

Planted faults travel the same pipeline as the real input: the module SOURCE is edited and rebuilt.
    python3 tools/vehicle_models_axis_check.py [repo]        -> exit 0 when clean
"""

import math
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

MOCK = r"""
table.create = table.create or function() return {} end
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end
V3 = {}
V3.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); return vec(v.X / m, v.Y / m, v.Z / m) end
	return V3[k]
end
V3.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
V3.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b) return vec(a.X / b, a.Y / b, a.Z / b) end
V3.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V3.__tostring = function(v) return string.format("%.3f, %.3f, %.3f", v.X, v.Y, v.Z) end
function V3.Cross(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
function V3.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
Vector3.zero = vec(0, 0, 0)
Vector3.xAxis, Vector3.yAxis, Vector3.zAxis = vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1)
Vector2 = {}
local V2 = { __add = function(a, b) return Vector2.new(a.X + b.X, a.Y + b.Y) end }
V2.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y) end
	if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y); return Vector2.new(v.X / m, v.Y / m) end
	if k == "Dot" then return function(a, b) return a.X * b.X + a.Y * b.Y end end
	return nil
end
function Vector2.new(x, y) return setmetatable({ X = x, Y = y }, V2) end

-- A CFrame is a position and three columns: right (X), up (Y), back (Z = -look).
CF = {}
local function cf(p, r, u, b) return setmetatable({ p = p, r = r, u = u, b = b }, CF) end
local function rot(c, v) return c.r * v.X + c.u * v.Y + c.b * v.Z end
CF.__index = function(c, k)
	if k == "Position" then return c.p end
	if k == "RightVector" or k == "XVector" then return c.r end
	if k == "UpVector" or k == "YVector" then return c.u end
	if k == "ZVector" then return c.b end
	if k == "LookVector" then return -c.b end
	if k == "Rotation" then return cf(Vector3.zero, c.r, c.u, c.b) end
	if k == "X" then return c.p.X end
	if k == "Y" then return c.p.Y end
	if k == "Z" then return c.p.Z end
	return CF[k]
end
CF.__mul = function(a, b)
	if getmetatable(b) == V3 then return a.p + rot(a, b) end
	return cf(a.p + rot(a, b.p), rot(a, b.r), rot(a, b.u), rot(a, b.b))
end
CF.__add = function(a, v) return cf(a.p + v, a.r, a.u, a.b) end
CF.__sub = function(a, v) return cf(a.p - v, a.r, a.u, a.b) end
function CF.Inverse(c)
	local t = cf(Vector3.zero, vec(c.r.X, c.u.X, c.b.X), vec(c.r.Y, c.u.Y, c.b.Y), vec(c.r.Z, c.u.Z, c.b.Z))
	t.p = -rot(t, c.p)
	return t
end
function CF.ToObjectSpace(a, b) return a:Inverse() * b end
local X, Y, Z = vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1)
CFrame = {}
function CFrame.new(x, y, z)
	if type(x) == "table" then return cf(x, X, Y, Z) end
	return cf(vec(x or 0, y or 0, z or 0), X, Y, Z)
end
CFrame.identity = CFrame.new()
function CFrame.fromMatrix(p, r, u, b) return cf(p, r, u, b or r:Cross(u)) end
function CFrame.Angles(x, y, z)
	local function rx(a) local c, s = math.cos(a), math.sin(a); return cf(Vector3.zero, X, vec(0, c, s), vec(0, -s, c)) end
	local function ry(a) local c, s = math.cos(a), math.sin(a); return cf(Vector3.zero, vec(c, 0, -s), Y, vec(s, 0, c)) end
	local function rz(a) local c, s = math.cos(a), math.sin(a); return cf(Vector3.zero, vec(c, s, 0), vec(-s, c, 0), Z) end
	return rx(x) * ry(y) * rz(z)
end
function CFrame.lookAt(at, target)
	local look = (target - at).Unit
	local right = look:Cross(Y).Unit
	return cf(at, right, right:Cross(look), -look)
end

function typeof(v)
	local mt = getmetatable(v)
	if mt == V3 then return "Vector3" elseif mt == CF then return "CFrame" end
	if type(v) == "table" and v.__color then return "Color3" end
	if type(v) == "table" and v.kids then return "Instance" end
	return type(v)
end
Color3 = { fromRGB = function(r, g, b) return { __color = true, r, g, b } end }
PhysicalProperties = { new = function() return {} end }
UDim2 = { fromScale = function() return {} end }
local function enumOf(path)
	return setmetatable({}, { __index = function(t, k) local v = path .. "." .. k; if path:find("%.") then return v end; local e = enumOf(v); rawset(t, k, e); return e end })
end
Enum = enumOf("Enum")
math.clamp = function(v, a, b) return math.max(a, math.min(b, v)) end

-- Instances: enough for the builder, BuildStatic and ZFight -- properties, Parent, children,
-- attributes, descendants.
local Inst = {}
Inst.__index = function(i, k)
	if k == "Position" then return rawget(i, "props").CFrame.p end
	local m = Inst[k]; if m then return m end
	return rawget(i, "props")[k]
end
Inst.__newindex = function(i, k, v)
	if k == "Parent" then
		local old = rawget(i, "props").Parent
		if old then
			local kids = rawget(old, "kids")
			for n = #kids, 1, -1 do if kids[n] == i then table.remove(kids, n) end end
		end
		if v then table.insert(rawget(v, "kids"), i) end
	end
	rawget(i, "props")[k] = v
end
local PARTS = { Part = true, WedgePart = true }
function Inst.IsA(i, c)
	if c == "BasePart" then return PARTS[i.ClassName] == true end
	if c == "JointInstance" then return i.ClassName == "Motor6D" end
	return i.ClassName == c
end
function Inst.GetChildren(i) local t = {}; for n, k in ipairs(rawget(i, "kids")) do t[n] = k end; return t end
function Inst.GetDescendants(i)
	local out = {}
	local function walk(x) for _, k in ipairs(rawget(x, "kids")) do out[#out + 1] = k; walk(k) end end
	walk(i)
	return out
end
function Inst.FindFirstChildOfClass(i, c) for _, k in ipairs(rawget(i, "kids")) do if k.ClassName == c then return k end end end
function Inst.IsDescendantOf() return false end
function Inst.GetFullName(i) return i.Name end
function Inst.Destroy(i) i.Parent = nil end
function Inst.PivotTo() end
function Inst.SetAttribute(i, k, v) rawget(i, "attrs")[k] = v end
function Inst.GetAttribute(i, k) return rawget(i, "attrs")[k] end
function Inst.GetAttributes(i) local t = {}; for k, v in pairs(rawget(i, "attrs")) do t[k] = v end; return t end
Instance = { new = function(c) return setmetatable({ props = { ClassName = c, Shape = Enum.PartType.Block, Transparency = 0 }, kids = {}, attrs = {} }, Inst) end }

local shared = { WaitForChild = function(_, name) return name end }
game = { GetService = function() return { WaitForChild = function() return shared end, AddTag = function() end } end }
function require(name) return MODULES[name] end

function dumpModel(model)
	local out = {}
	for _, p in ipairs(model:GetChildren()) do
		if p.ClassName == "Part" or p.ClassName == "WedgePart" then
			local c, s = p.CFrame, p.Size
			local anchor = ""
			for _, k in ipairs(p:GetChildren()) do
				if k.ClassName == "WeldConstraint" or k.ClassName == "Motor6D" then anchor = k.Part0.Name end
			end
			table.insert(out, { p.Name, p.ClassName, tostring(p.Shape), s.X, s.Y, s.Z,
				c.p.X, c.p.Y, c.p.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z,
				p.Transparency or 0, anchor })
		end
	end
	return out
end
"""

ROD_THIN, ROD_RATIO = 0.6, 2.5
BAT_COAXIAL_TOL, BAT_ALONG_TOL = 1.0, 3.0
PROTRUDE, HELD, ZFIGHT_DRIFT, CLEAR = 0.3, 0.06, 0.05, 0.05
# A bare end longer than both of these reads as a pole. Under 0.4 it is a trim end at a panel's
# edge: the arch lips' last segments on the van and the GT stop 0.07 past the arch panel's back
# edge, 0.36 of their 0.67 clear of it.
BARE, BARE_RATIO = 0.4, 2.0
# The mount itself (ring, yoke, cheeks, cradle, trunnion) is squat; only the weapon's own barrel or
# tubes may be long. The Ranger's pod stood on a 3.9-stud post, which read as a pole in the bed.
MOUNT_POST = 2.5
BAT_CHAIN = ("BatHandle", "BatFlare", "BatTaper", "BatThroat", "BatShoulder", "BatBarrel")
BAT_PIECES = ("BatKnob",) + BAT_CHAIN + ("BatEnd", "BatStrap1", "BatStrap2")
TURRET = re.compile(r"^(Turret|Gun|Pod|Mortar|DriverGun)")
# The weapon itself (not its mount), which is allowed to be long: barrels, tubes.
WEAPON = re.compile(r"^(Gun|Pod|Mortar|DriverGun(Jacket|Barrel|Flash))")
DRIVER_GUN = re.compile(r"^DriverGun")


def luau_to_lua(src):
    return re.sub(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", src, flags=re.M)


def load_sources(repo):
    shared = Path(repo) / "ReplicatedStorage/Shared"
    return {name: luau_to_lua((shared / f"{name}.lua").read_text())
            for name in ("VehicleModels", "ZFight", "VehicleWeaponData")}


def weapon_arcs(data_src, table="ByModel"):
    """{modelId: (yawLimit, pitchMin, pitchMax, guard)} read from VehicleWeaponData's source: the
    turrets (ByModel) or, with table="DriverByModel", the drivers' guns. `guard` is the spec's
    frontGuard as (arc, pitchMin), or None: inside that arc the barrel never goes below its floor."""
    arcs, specs = {}, {}
    for m in re.finditer(r"\n\t(\w+) = \{(.*?)\n\t\}", data_src, re.S):
        body = m.group(2)
        vals = [re.search(rf"\n\t\t{k} = (-?[\d.]+)", body) for k in ("yawLimit", "pitchMin", "pitchMax")]
        guard = re.search(r"frontGuard = \{ arc = (-?[\d.]+), pitchMin = (-?[\d.]+) \}", body)
        if all(vals):
            specs[m.group(1)] = tuple(float(v.group(1)) for v in vals) + (
                (float(guard.group(1)), float(guard.group(2))) if guard else None,)
    block = re.search(r"\nVehicleWeaponData\." + table + r" = \{(.*?)\n\}", data_src, re.S)
    for model_id, spec in re.findall(r"\n\t(\w+) = \"(\w+)\",", block.group(1) if block else ""):
        if spec in specs:
            arcs[model_id] = specs[spec]
    return arcs


class Runtime:
    def __init__(self, sources, zfight=True):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCK)
        modules = self.lua.eval("function() MODULES = {}; return MODULES end")()
        modules["ZFight"] = self.lua.execute(sources["ZFight"])
        if not zfight:
            modules["ZFight"]["Enabled"] = False
        self.vm = self.lua.execute(sources["VehicleModels"])
        self.make = self.lua.eval("""function(vm, id, how, scheme)
            local m
            if how == "static" then m = vm.BuildStatic(id, nil, CFrame.identity, { scheme = scheme })
            else m = vm.Build(id, nil, { scheme = scheme, unarmed = how == "unarmed" }) end
            return dumpModel(m)
        end""")
        self.ids = [k for k in self.lua.eval("function(vm) local t = {}; for k in pairs(vm.Models) do t[#t + 1] = k end; table.sort(t); return t end")(self.vm).values()]
        self.schemes = {i: len(self.vm.Models[i].schemes) for i in self.ids}
        self.mounts = {k for k in self.lua.eval("function(vm) local t = {}; for k in pairs(vm.Mounts) do t[#t + 1] = k end; return t end")(self.vm).values()}

    def build(self, model_id, how, scheme=1):
        rows = self.make(self.vm, model_id, how, scheme)
        parts = []
        for i in range(1, len(rows) + 1):
            r = rows[i]
            v = [r[j] for j in range(1, 21)]
            parts.append({
                "name": v[0], "cls": v[1], "shape": v[2].split(".")[-1], "size": list(v[3:6]), "pos": list(v[6:9]),
                "cols": (list(v[9:12]), list(v[12:15]), list(v[15:18])), "transparency": v[18], "anchor": v[19],
            })
        return parts


# -- vector helpers --------------------------------------------------------------------------------
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def add(a, b): return [x + y for x, y in zip(a, b)]
def sub(a, b): return [x - y for x, y in zip(a, b)]
def mul(a, k): return [x * k for x in a]
def norm(a): m = math.sqrt(dot(a, a)); return [x / m for x in a]
def angle(a, b): return math.degrees(math.acos(min(1.0, abs(dot(norm(a), norm(b))))))
def length(a): return math.sqrt(dot(a, a))


def long_axis(p):
    """(axis vector, length, thin, thick) as Roblox draws the part."""
    sx, sy, sz = p["size"]
    if p["shape"] == "Cylinder":
        return p["cols"][0], sx, min(sy, sz), min(sy, sz)
    order = sorted(range(3), key=lambda k: -p["size"][k])
    return p["cols"][order[0]], p["size"][order[0]], p["size"][order[2]], p["size"][order[1]]


def is_rod(p):
    axis, ln, thin, thick = long_axis(p)
    return thick <= ROD_THIN and ln >= ROD_RATIO * thick


def rod_ends(p):
    axis, ln, _, _ = long_axis(p)
    return add(p["pos"], mul(axis, ln / 2)), sub(p["pos"], mul(axis, ln / 2))


def world_extent(p):
    lo, hi = [], []
    for k in range(3):
        half = sum(abs(p["cols"][a][k]) * p["size"][a] / 2 for a in range(3))
        lo.append(p["pos"][k] - half)
        hi.append(p["pos"][k] + half)
    return lo, hi


def half_sizes(p):
    sx, sy, sz = p["size"]
    if p["shape"] == "Cylinder":
        r = min(sy, sz) / 2
        return [sx / 2, r, r]
    if p["shape"] == "Ball":
        r = min(p["size"]) / 2
        return [r, r, r]
    return [sx / 2, sy / 2, sz / 2]


def point_distance(p, q):
    """How far point q is outside part p (0 inside), with cylinders and balls drawn round."""
    d = sub(q, p["pos"])
    h = half_sizes(p)
    local = [dot(d, c) for c in p["cols"]]
    if p["shape"] == "Ball":
        return max(0.0, length(d) - h[0])
    if p["shape"] == "Cylinder":
        radial = max(0.0, math.hypot(local[1], local[2]) - h[1])
        along = max(0.0, abs(local[0]) - h[0])
        return math.hypot(radial, along)
    out = [max(0.0, abs(local[k]) - h[k]) for k in range(3)]
    if p.get("cls") == "WedgePart":
        # A wedge is its box cut by the slope from its low front edge (y -h, z -h) to its high back
        # edge (y +h, z +h): a point above the slope is outside by its distance from that plane.
        n = [0.0, h[2], -h[1]]
        m = math.hypot(n[1], n[2]) or 1.0
        above = (local[1] * n[1] + local[2] * n[2]) / m
        return max(length(out), above)
    return length(out)


def samples(p):
    """Points through a part's solid, and the radius each stands for (round parts are their axis)."""
    h = half_sizes(p)
    if p["shape"] == "Ball":
        return [(p["pos"], h[0])]
    if p["shape"] == "Cylinder":
        axis = p["cols"][0]
        return [(add(p["pos"], mul(axis, h[0] * t / 4)), h[1]) for t in range(-4, 5)]
    pts = []
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            for k in (-1, 0, 1):
                pts.append((add(p["pos"], add(add(mul(p["cols"][0], h[0] * i), mul(p["cols"][1], h[1] * j)), mul(p["cols"][2], h[2] * k))), 0.0))
    return pts


def seg_seg(p1, q1, p2, q2):
    """Closest distance between segments p1q1 and p2q2."""
    d1, d2, r = sub(q1, p1), sub(q2, p2), sub(p1, p2)
    a, e, f = dot(d1, d1), dot(d2, d2), dot(d2, r)
    if a < 1e-12 and e < 1e-12:
        return length(r)
    if a < 1e-12:
        s, t = 0.0, min(1.0, max(0.0, f / e))
    else:
        c = dot(d1, r)
        if e < 1e-12:
            t, s = 0.0, min(1.0, max(0.0, -c / a))
        else:
            b = dot(d1, d2)
            den = a * e - b * b
            s = min(1.0, max(0.0, (b * f - c * e) / den)) if den > 1e-12 else 0.0
            t = (b * s + f) / e
            if t < 0:
                t, s = 0.0, min(1.0, max(0.0, -c / a))
            elif t > 1:
                t, s = 1.0, min(1.0, max(0.0, (b - c) / a))
    return length(sub(add(p1, mul(d1, s)), add(p2, mul(d2, t))))


def obb_overlap(p, q, margin):
    """Separating-axis test on the two parts' boxes, each grown by margin/2. True when they overlap."""
    hp, hq = [x + margin / 2 for x in half_sizes(p)], [x + margin / 2 for x in half_sizes(q)]
    t = sub(q["pos"], p["pos"])
    axes = list(p["cols"]) + list(q["cols"])
    for a in p["cols"]:
        for b in q["cols"]:
            c = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
            if length(c) > 1e-6:
                axes.append(norm(c))
    for ax in axes:
        rp = sum(hp[k] * abs(dot(p["cols"][k], ax)) for k in range(3))
        rq = sum(hq[k] * abs(dot(q["cols"][k], ax)) for k in range(3))
        if abs(dot(t, ax)) > rp + rq:
            return False
    return True


def capsule(p):
    """A round part as (a, b, radius): cylinders along X, balls as a point."""
    if p["shape"] == "Ball":
        return p["pos"], p["pos"], half_sizes(p)[0]
    h = half_sizes(p)
    return add(p["pos"], mul(p["cols"][0], h[0])), sub(p["pos"], mul(p["cols"][0], h[0])), h[1]


def overlaps(p, q, margin):
    """Whether two parts come within `margin` of each other. For two round parts the slimmer one is
    taken as a capsule (a hair generous at its flat ends) and its axis is walked against the other
    solid exactly, so a short fat drum is not mistaken for a long pill; anything with a box in it is
    measured by boxes."""
    plo, phi = world_extent(p)
    qlo, qhi = world_extent(q)
    if any(plo[k] > qhi[k] + margin or qlo[k] > phi[k] + margin for k in range(3)):
        return False
    # A ball against anything, and anything against a wedge's slope, measured exactly (a ball's box
    # reaches 0.4 of its size out at a corner; a wedge's box counts the air over its slope as solid).
    for a, b in ((p, q), (q, p)):
        if a["shape"] == "Ball" and b["shape"] != "Ball":
            return point_distance(b, a["pos"]) < half_sizes(a)[0] + margin
        if b.get("cls") == "WedgePart" and a.get("cls") != "WedgePart":
            return any(point_distance(b, x) < r + margin for x, r in samples(a))
    if p["shape"] in ("Cylinder", "Ball") and q["shape"] in ("Cylinder", "Ball"):
        def slim(x): return 0 if x["shape"] == "Ball" else x["size"][0] / half_sizes(x)[1]
        if slim(p) < slim(q):
            p, q = q, p
        a, b, r = capsule(p)
        n = max(1, int(length(sub(b, a)) / 0.05))
        return any(point_distance(q, add(a, mul(sub(b, a), i / n))) < r + margin for i in range(n + 1))
    return obb_overlap(p, q, margin)


# -- the audit -------------------------------------------------------------------------------------
def visible(parts):
    return [p for p in parts if p["transparency"] < 1]


def audit_rods(parts, label, verbose):
    faults, lines = [], []
    shown = visible(parts)
    for p in shown:
        if p["shape"] == "Cylinder" and abs(p["size"][1] - p["size"][2]) > 1e-6:
            faults.append(f"{label}/{p['name']}: cylinder not round, Size {[round(x, 3) for x in p['size']]} (length passed in Y?)")
    rods = [p for p in shown if is_rod(p)]
    rodset = {id(p) for p in rods}
    body = [p for p in shown if id(p) not in rodset]
    body_lo, body_hi = [1e9] * 3, [-1e9] * 3
    for p in body:
        lo, hi = world_extent(p)
        body_lo = [min(a, b) for a, b in zip(body_lo, lo)]
        body_hi = [max(a, b) for a, b in zip(body_hi, hi)]

    # Invariant 3: no free end. Walk in from each end of the rod until its surface meets another
    # visible part; what is walked is the bare length sticking out.
    leaning = []
    for p in rods:
        axis, ln, _, thick = long_axis(p)
        off = min(angle(axis, w) for w in ((1, 0, 0), (0, 1, 0), (0, 0, 1)))
        lo, hi = world_extent(p)
        out = max(max(b - x for b, x in zip(body_lo, lo)), max(x - b for b, x in zip(body_hi, hi)), 0)
        bare = free_ends(p, shown, lo, hi)
        verdict = "ok"
        if out > PROTRUDE:
            verdict = "FLAG protrudes"
            faults.append(f"{label}/{p['name']}: rod reaches {out:.2f} studs past the body envelope")
        worst = max(bare)
        if worst > max(BARE, BARE_RATIO * thick) and not TURRET.match(p["name"]):
            verdict = "FLAG free end"
            faults.append(f"{label}/{p['name']}: rod end sticks out {worst:.2f} studs with nothing round it (a pole sticking out)")
        if TURRET.match(p["name"]) and ln > MOUNT_POST and not WEAPON.match(p["name"]):
            verdict = "FLAG post"
            faults.append(f"{label}/{p['name']}: a {ln:.1f}-stud rod in the weapon mount (a pole standing out of the vehicle)")
        if off > 6:
            leaning.append((worst, p["name"]))
        if verbose and (verdict != "ok" or worst > 0.25):
            lines.append(f"  {verdict:14s} {p['name']:22s} len {ln:5.2f} thick {thick:4.2f} lean {off:5.1f} past body {out:4.2f} bare ends {bare[0]:.2f} / {bare[1]:.2f}")
    if verbose:
        top = ", ".join(f"{n} {w:.2f}" for w, n in sorted(leaning, reverse=True)[:3])
        print(f"{label}: {len(shown)} visible parts, {len(rods)} rods; {len(leaning)} lean, barest ends among those: {top or '-'}")
        for line in lines:
            print(line)
    return faults


def free_ends(p, shown, lo, hi):
    """Bare length at each end of rod p: how far in from the end before its surface touches another part."""
    axis, ln, _, thick = long_axis(p)
    reach = thick / 2 + HELD
    others = []
    for q in shown:
        if q is p:
            continue
        qlo, qhi = world_extent(q)
        if all(qlo[k] <= hi[k] + reach and lo[k] - reach <= qhi[k] for k in range(3)):
            others.append(q)
    a, b = rod_ends(p)
    n = max(2, int(ln / 0.05))
    points = [add(b, mul(sub(a, b), i / n)) for i in range(n + 1)]
    bare = []
    for seq in (points, points[::-1]):
        k = 0
        while k < len(seq) and not any(point_distance(q, seq[k]) <= reach for q in others):
            k += 1
        bare.append(k * ln / n)
    return bare


def audit_zfight(fixed, raw, label, verbose):
    """Invariant 4: the real z-fight pass never pushes a rod's end out, and never touches the bat.
    (Growing a rod ACROSS its length -- a seam a hair wider -- is what the pass is for.)"""
    faults, pushed = [], 0
    before = {}
    shown, shown_raw = visible(fixed), visible(raw)
    for p in raw:
        before.setdefault(p["name"], []).append(p)
    for p in visible(fixed):
        bat = p["name"].startswith("Bat")
        if not (is_rod(p) or bat) or not before.get(p["name"]):
            continue
        q = min(before[p["name"]], key=lambda c: length(sub(c["pos"], p["pos"])))
        drift = length(sub(q["pos"], p["pos"]))
        grow = max(abs(a - b) for a, b in zip(p["size"], q["size"]))
        if bat:
            if drift > 1e-6 or grow > 1e-6:
                faults.append(f"{label}/{p['name']}: z-fight pass moved it {drift:.3f} / resized it {grow:.3f} (the bat must stay as built)")
            continue
        axis, ln, _, _ = long_axis(p)
        ln0 = long_axis(q)[1]
        along = abs(dot(sub(p["pos"], q["pos"]), axis))
        if ln - ln0 > 0.01 or along > 0.01:
            # It went along its length: did that leave more of an end bare than was built?
            now, was = free_ends(p, shown, *world_extent(p)), free_ends(q, shown_raw, *world_extent(q))
            pushed += 1
            if max(now) > max(was) + ZFIGHT_DRIFT:
                faults.append(f"{label}/{p['name']}: z-fight pass pushed an end out, bare {max(was):.2f} -> {max(now):.2f}")
    if verbose:
        print(f"  z-fight pass: {pushed} rods moved or grown along their length, none left with a barer end; bat untouched")
    return faults


def audit_bat(parts, label, verbose):
    faults = []
    bat = {p["name"]: p for p in parts if p["name"].startswith("Bat")}
    missing = [n for n in BAT_PIECES if n not in bat or bat[n]["transparency"] >= 1]
    if missing:
        return [f"{label}/bat: pieces missing {missing}"]
    knob, end = bat["BatKnob"], bat["BatEnd"]
    line = norm(sub(end["pos"], knob["pos"]))
    along = angle((line[0], 0, line[2]), (0, 0, 1))
    if along > BAT_ALONG_TOL:
        faults.append(f"{label}/bat: runs {along:.1f} deg off the van's length (across the roof = sideways)")
    for name in BAT_CHAIN + ("BatEnd",):
        off = angle(bat[name]["cols"][0], line)
        if off > BAT_COAXIAL_TOL:
            faults.append(f"{label}/{name}: bat part {off:.2f} deg off the bat's own line (kinked or sideways)")
    # One object: each piece's far end is the next one's near end.
    def span(p):
        a, b = add(p["pos"], mul(p["cols"][0], p["size"][0] / 2)), sub(p["pos"], mul(p["cols"][0], p["size"][0] / 2))
        return (a, b) if dot(sub(b, a), line) > 0 else (b, a)
    joins = []
    for n1, n2 in zip(BAT_CHAIN, BAT_CHAIN[1:]):
        g = length(sub(span(bat[n1])[1], span(bat[n2])[0]))
        joins.append(g)
        if g > 0.02:
            faults.append(f"{label}/{n1}->{n2}: bat pieces {g:.3f} apart (a break in the bat)")
    def off_line(q):
        d = sub(q, knob["pos"])
        return length(sub(d, mul(line, dot(d, line))))
    k = length(sub(knob["pos"], span(bat["BatHandle"])[0]))
    if k > knob["size"][0] / 2 or off_line(knob["pos"]) > 0.01:
        faults.append(f"{label}/BatKnob: knob centre {k:.3f} from the handle's end, radius {knob['size'][0] / 2:.2f} (floating)")
    barrel_end = span(bat["BatBarrel"])[1]
    face = dot(sub(end["pos"], barrel_end), line) - end["size"][0] / 2
    if off_line(end["pos"]) > 0.01 or not (-0.05 <= face <= 0.0):
        faults.append(f"{label}/BatEnd: end cap {face:+.3f} from the barrel's end (floating or buried)")
    # Resting on the rack: the bar under the handle and the barrel.
    bars = [p for p in parts if p["name"].startswith("RackBar")]
    rests = []
    for name in ("BatHandle", "BatBarrel"):
        p = bat[name]
        a, b = span(p)
        r = half_sizes(p)[1]
        best = None
        for bar in bars:
            z = bar["pos"][2]
            if min(a[2], b[2]) <= z <= max(a[2], b[2]):
                t = (z - a[2]) / (b[2] - a[2])
                under = a[1] + (b[1] - a[1]) * t - r / math.cos(math.atan2(b[1] - a[1], abs(b[2] - a[2])))
                gap = under - (bar["pos"][1] + half_sizes(bar)[1])
                best = gap if best is None or abs(gap) < abs(best) else best
        rests.append(best)
        if best is None or not (-0.005 <= best <= 0.05):
            faults.append(f"{label}/{name}: not resting on a rack bar (underside {best if best is None else round(best, 3)} above its top)")
    for s in ("BatStrap1", "BatStrap2"):
        strap = bat[s]
        if not any(overlaps(strap, bat[n], 0.0) for n in BAT_CHAIN):
            faults.append(f"{label}/{s}: strap does not touch the bat")
        if not any(overlaps(strap, bar, 0.0) for bar in bars):
            faults.append(f"{label}/{s}: strap does not reach a rack bar")
    # Nothing else runs through it.
    for p in visible(parts):
        if p["name"].startswith("Bat") or p["name"].startswith("RackBar") or p["name"].startswith("Hull_") or p["name"] == "Chassis":
            continue
        for n in BAT_CHAIN + ("BatKnob", "BatEnd"):
            if overlaps(p, bat[n], 0.0):
                faults.append(f"{label}/{n}: {p['name']} runs into the bat")
    if verbose:
        print(f"  bat: {along:.1f} deg off the van's length in plan, pieces coaxial, joins {', '.join(f'{g:.3f}' for g in joins)}, "
              f"handle / barrel rest {rests[0]:+.3f} / {rests[1]:+.3f} above their bars")
    return faults


def rotate(v, axis, a):
    """Rodrigues: v turned by a radians about unit axis."""
    c, s = math.cos(a), math.sin(a)
    cr = [axis[1] * v[2] - axis[2] * v[1], axis[2] * v[0] - axis[0] * v[2], axis[0] * v[1] - axis[1] * v[0]]
    return add(add(mul(v, c), mul(cr, s)), mul(axis, dot(axis, v) * (1 - c)))


def posed(p, pivot, axis, a):
    return dict(p, pos=add(pivot, rotate(sub(p["pos"], pivot), axis, a)), cols=tuple(rotate(c, axis, a) for c in p["cols"]))


def audit_turret(parts, label, arc, verbose, mount="turret"):
    """Invariant 6: a weapon clears the vehicle through its whole arc."""
    faults = []
    byname = {p["name"]: p for p in parts}
    yaw_name, pitch_name = ("TurretYaw", "TurretPitch") if mount == "turret" else ("DriverGunYaw", "DriverGunPitch")
    yaw_p, pitch_p = byname.get(yaw_name), byname.get(pitch_name)
    if not (yaw_p and pitch_p and arc):
        return [f"{label}: armed build without a {mount} mount or an arc"]
    yaw_parts = [p for p in visible(parts) if p["anchor"] == yaw_name]
    pitch_parts = [p for p in visible(parts) if p["anchor"] == pitch_name]
    # Obstacles: everything visible that is not this mount's own (its fixed base included, which it
    # stands on). The turret's sweep meets the driver's gun like any other part, and the other way round.
    own = (lambda n: TURRET.match(n) and not DRIVER_GUN.match(n)) if mount == "turret" else DRIVER_GUN.match
    fixed = [p for p in visible(parts) if not own(p["name"])]
    yaw_limit, pmin, pmax, guard = arc
    worst, hits = 1e9, {}
    yaws = [math.radians(y) for y in range(-int(yaw_limit), int(yaw_limit) + 1, 5)]

    def pitches_at(yaw):
        low = max(pmin, guard[1]) if guard and abs(math.degrees(yaw)) < guard[0] else pmin
        return [math.radians(low + (pmax - low) * i / 10) for i in range(11)]
    pitches = pitches_at(math.pi)
    up, right = yaw_p["cols"][1], pitch_p["cols"][0]
    # Only parts that could possibly be reached: within the turret's swing radius of the yaw pivot.
    reach = max(length(sub(p["pos"], yaw_p["pos"])) + length(p["size"]) / 2 for p in yaw_parts + pitch_parts)
    near = [q for q in fixed if length(sub(q["pos"], yaw_p["pos"])) - length(q["size"]) / 2 <= reach + CLEAR]
    for yaw in yaws:
        pitch_pivot = add(yaw_p["pos"], rotate(sub(pitch_p["pos"], yaw_p["pos"]), up, yaw))
        right_now = rotate(right, up, yaw)
        moving = [posed(p, yaw_p["pos"], up, yaw) for p in yaw_parts]
        for pitch in pitches_at(yaw):
            # Positive pitch is up: CFrame.Angles(pitch, 0, 0) about the pivot's X, front -Z.
            moving2 = moving + [posed(posed(p, yaw_p["pos"], up, yaw), pitch_pivot, right_now, pitch) for p in pitch_parts]
            for m in moving2:
                for q in near:
                    if overlaps(m, q, CLEAR):
                        hits.setdefault((m["name"], q["name"]), (round(math.degrees(yaw)), round(math.degrees(pitch))))
    for (m, q), (y, pt) in sorted(hits.items()):
        faults.append(f"{label}/{m}: {'turret' if mount == 'turret' else 'driver gun'} runs into {q} (first at yaw {y}, pitch {pt})")
    if verbose:
        print(f"  {mount}: {len(yaws)} yaws x {len(pitches)} pitches over yaw +-{yaw_limit:g}, pitch {pmin:g}..{pmax:g}; "
              f"{len(near)} nearby parts checked, {len(hits)} contacts")
    return faults


def audit_model(rt, rt_raw, arcs, model_id, verbose=True, driver_arcs=None):
    faults = []
    for scheme in range(1, rt.schemes[model_id] + 1):
        hows = ["drive", "static"] + (["unarmed"] if model_id in rt.mounts else [])
        for how in hows:
            label = f"{model_id}[{how} s{scheme}]"
            talk = verbose and scheme == 1
            parts = rt.build(model_id, how, scheme)
            faults += audit_rods(parts, label, talk)
            faults += audit_zfight(parts, rt_raw.build(model_id, how, scheme), label, talk)
            if model_id == "SahurVan":
                faults += audit_bat(parts, label, talk)
            if how == "drive" and model_id in rt.mounts and scheme == 1:
                faults += audit_turret(parts, label, arcs.get(model_id), talk)
                faults += audit_turret(parts, label, (driver_arcs or {}).get(model_id), talk, "driver")
    return faults


def run(sources, only=None, verbose=True):
    rt, raw = Runtime(sources), Runtime(sources, zfight=False)
    arcs = weapon_arcs(sources["VehicleWeaponData"])
    driver_arcs = weapon_arcs(sources["VehicleWeaponData"], "DriverByModel")
    faults = []
    for model_id in rt.ids:
        if only and model_id != only:
            continue
        found = audit_model(rt, raw, arcs, model_id, verbose, driver_arcs)
        if verbose:
            for f in found:
                print("  FAULT " + f)
            print(f"{model_id}: {len(found)} faults")
        faults += found
    return faults


def main(repo="."):
    sources = load_sources(repo)
    failed = bool(run(sources))

    # Planted faults, each through the real pipeline (edited source, rebuilt, audited).
    VM, ZF = "VehicleModels", "ZFight"
    plants = [
        ("cylinder length in Y (the X-axis lesson)", "SahurVan", VM,
         'local part = self:make("Part", name, V(length, diameter, diameter), at, role, anchor)',
         'local part = self:make("Part", name, (name == "BatBarrel") and V(diameter, length, diameter) or V(length, diameter, diameter), at, role, anchor)', "BatBarrel: cylinder not round"),
        ("bat turned across the roof", "SahurVan", VM,
         "local bat = CF(V(batX, batY, batZ)) * A(",
         "local bat = CF(V(batX, batY, batZ)) * A(0, 25, 0) * A(", "bat: runs"),
        ("kinked bat (a lift on one piece)", "SahurVan", VM,
         'b:tube("BatBarrel", batAt(1.6), batAt(4.0)',
         'b:tube("BatBarrel", batAt(1.6), batAt(4.0, 0.2)', "BatBarrel: bat part"),
        ("bat in two pieces (gap before the barrel)", "SahurVan", VM,
         'b:tube("BatBarrel", batAt(1.6)', 'b:tube("BatBarrel", batAt(1.75)', "BatShoulder->BatBarrel"),
        ("knob floating off the handle", "SahurVan", VM,
         'b:ball("BatKnob", 0.46, batAt(-3.8)', 'b:ball("BatKnob", 0.46, batAt(-4.2)', "BatKnob: knob"),
        ("bat floating above the rack", "SahurVan", VM,
         "local bat = CF(V(batX, batY, batZ))", "local bat = CF(V(batX, batY + 0.3, batZ))", "not resting on a rack bar"),
        ("parked van loses its bat", "SahurVan", VM,
         'local STATIC_DROP = { ', 'local STATIC_DROP = { "^BatThroat", ', "pieces missing"),
        ("straps back in the bat's own frame (hanging off the bars)", "SahurVan", VM,
         "local z = (barZ - batZ) / math.cos(math.rad(rake))", "local z = barZ", "strap does not reach a rack bar"),
        ("mortar back on its old 0.4 plinth (swings through the bat)", "SahurVan", VM,
         "base = V(0, 7.8, 5.2), column = 0.9", "base = V(0, 7.8, 5.2), column = 0.4", "turret runs into BatBarrel"),
        ("the Ranger's pedestal thinned to a bare pole", "CrocodiloRanger", VM,
         'b:cyl("TurretColumn", yokeY - (yawAt.Y + 0.3), 0.72,',
         'b:cyl("TurretColumn", yokeY - (yawAt.Y + 0.3), 0.5,', "rod in the weapon mount"),
        ("the Ranger's pedestal moved forward against its roll bar", "CrocodiloRanger", VM,
         'CrocodiloRanger = { style = "pedestal", base = V(0, 3.1, 4.55) },', 'CrocodiloRanger = { style = "pedestal", base = V(0, 3.1, 3.6) },', "turret runs into RollBar"),
        ("the Rotster's nose gun sunk into its bonnet", "Rotster", VM,
         'Rotster = { style = "cowl", base = V(0, 3.52, -4.6), depth = 1.1, length = 1.8 },',
         'Rotster = { style = "cowl", base = V(0, 3.02, -4.6), depth = 1.1, length = 1.8 },', "driver gun runs into"),
        ("parked car keeps its bare steering column", "TralalaGT", VM,
         'local STATIC_CAR_DROP = { "^Column$" }', "local STATIC_CAR_DROP = {}", "Column: rod end sticks out"),
        ("z-fight pass shoves a bat piece", "SahurVan", ZF,
         "ZFight.Gap = 0.06", "ZFight.Gap = 0.06\nZFight.PlantBat = true", "z-fight pass moved it"),
        ("pole sticking out of the body", "CrocodiloRanger", VM,
         'b:box("BumperStep"',
         'b:tube("PlantPole", V(0, 3, 6), V(0, 3, 10.5), 0.2, "trim")\n\t\tb:box("BumperStep"', "PlantPole: rod reaches"),
        ("leaning pole with a free end (inside the envelope)", "CrocodiloRanger", VM,
         'b:box("BumperStep"',
         'b:tube("PlantPole", V(0, 4.5, 3), V(1.2, 6.2, 3.8), 0.2, "trim")\n\t\tb:box("BumperStep"', "PlantPole: rod end"),
    ]
    for label, model_id, module, old, new, tag, *more in plants:
        src = sources[module]
        for o, n in [(old, new)] + list(more):
            assert src.count(o) == 1, f"plant anchor missing or ambiguous: {o!r}"
            src = src.replace(o, n)
        planted = dict(sources, **{module: src})
        if module == ZF:
            # The pass itself misbehaving: after it runs, one bat piece is pushed 0.3 off its line.
            planted[ZF] = planted[ZF].replace("\treturn stats\nend\n\n-- The pairs",
                "\tif ZFight.PlantBat then for _, r in pairs(roots) do for _, p in ipairs(r:GetChildren()) do if p.Name == \"BatThroat\" then p.CFrame = p.CFrame + Vector3.new(0.3, 0, 0) end end end end\n\treturn stats\nend\n\n-- The pairs", 1)
            assert "PlantBat then" in planted[ZF]
        faults = run(planted, only=model_id, verbose=False)
        caught = [f for f in faults if tag in f]
        print(f"plant [{label}] on {model_id}: {'CAUGHT -- ' + caught[0] if caught else 'MISSED'}")
        failed |= not caught
    print("vehicle_models_axis_check: " + ("FAIL" if failed else "OK"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
