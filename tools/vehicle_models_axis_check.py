"""Rod and bat axis audit for VehicleModels (OLIVER_LIST #61 / #116 / #50), without Studio.

Runs the REAL ReplicatedStorage/Shared/VehicleModels.lua under lupa with a small CFrame /
Vector3 / Instance mock, builds each vehicle, and reads every part's world frame back. That is the
same frame the game builds, apart from the z-fight pass (mocked out here: it only grows a face or
nudges a part a few hundredths, it never turns one).

For every part it works out the LONG axis the way Roblox draws it -- a Cylinder's length is its
own X axis whatever Size.Y and Size.Z say (COORDINATION: the Cylinder X-axis lesson), a block's
is its longest side -- and treats as a candidate any rod: two thin sides (<= 0.6) and a length at
least 2.5 times the thicker of them. Every candidate is printed, flagged or not.

Invariants, each aimed at something the models must refuse forever:
  1. A rod runs along a world axis (within 6 degrees) unless it is named in INTENDED_ANGLED with
     the reason it leans. A leaning rod nobody meant is what "a pole sticking out" and "a bat part
     sideways" look like.
  2. A bat is straight: every Bat* round part (and the end cap's disc) is coaxial with the line from
     BatKnob to BatEnd, within 1 degree, and the bat runs along the van in plan (heading within 3 degrees of Z; a rake is fine).
  3. No rod (and no bat part) reaches more than 0.3 studs past the envelope of the vehicle's non-rod parts.
  4. A cylinder is round: Size.Y equals Size.Z (Roblox draws the smaller one, so a mismatch means
     someone passed the length in Y).

Planted faults travel the same pipeline as the real input: the module SOURCE is edited and rebuilt.
    python3 tools/vehicle_models_axis_check.py [repo]        -> exit 0 when clean
"""

import math
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

MOCK = r"""
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
function V3.Cross(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
function V3.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
Vector3.zero = vec(0, 0, 0)
Vector2 = {}
local V2 = { __add = function(a, b) return Vector2.new(a.X + b.X, a.Y + b.Y) end }
V2.__index = V2
function Vector2.new(x, y) return setmetatable({ X = x, Y = y }, V2) end

-- A CFrame is a position and three columns: right (X), up (Y), back (Z = -look).
CF = {}
local function cf(p, r, u, b) return setmetatable({ p = p, r = r, u = u, b = b }, CF) end
local function rot(c, v) return c.r * v.X + c.u * v.Y + c.b * v.Z end
CF.__index = function(c, k)
	if k == "Position" then return c.p end
	if k == "RightVector" then return c.r end
	if k == "UpVector" then return c.u end
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

-- Instances: enough for the builder -- properties, Parent, children, attributes.
local Inst = {}
Inst.__index = function(i, k)
	if k == "Position" then return rawget(i, "props").CFrame.p end
	local m = Inst[k]; if m then return m end
	return rawget(i, "props")[k]
end
Inst.__newindex = function(i, k, v)
	if k == "Parent" then table.insert(rawget(v, "kids"), i) end
	rawget(i, "props")[k] = v
end
function Inst.IsA(i, c) return i.ClassName == c or (c == "BasePart" and (i.ClassName == "Part" or i.ClassName == "WedgePart")) end
function Inst.GetChildren(i) return rawget(i, "kids") end
function Inst.SetAttribute(i, k, v) rawget(i, "attrs")[k] = v end
function Inst.GetAttribute(i, k) return rawget(i, "attrs")[k] end
Instance = { new = function(c) return setmetatable({ props = { ClassName = c, Shape = Enum.PartType.Block }, kids = {}, attrs = {} }, Inst) end }

local shared = { WaitForChild = function(_, name) return name end }
game = { GetService = function() return { WaitForChild = function() return shared end } end }
function require(name) return { Fix = function() return { moved = 0 } end } end

function dumpModel(model)
	local out = {}
	for _, p in ipairs(model:GetChildren()) do
		if p.ClassName == "Part" or p.ClassName == "WedgePart" then
			local c, s = p.CFrame, p.Size
			table.insert(out, { p.Name, p.ClassName, tostring(p.Shape), s.X, s.Y, s.Z,
				c.p.X, c.p.Y, c.p.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z,
				p.Transparency or 0 })
		end
	end
	return out
end
"""

MODELS = ("CrocodiloRanger", "SahurVan")
ROD_THIN, ROD_RATIO = 0.6, 2.5
AXIS_TOL, BAT_COAXIAL_TOL, BAT_ALONG_TOL = 6.0, 1.0, 3.0
PROTRUDE = 0.3

# Rods that lean on purpose, by name prefix, with why. Anything leaning and NOT here is flagged.
INTENDED_ANGLED = {
    "PillarA": "A-pillar follows the raked windscreen",
    "ScreenDivider": "follows the raked windscreen",
    "Column": "steering column points at the driver",
    "GearStick": "cabin lever",
    "TransferStick": "cabin lever",
    "Snorkel": "snorkel bends up the A-pillar to the roof",
    "RollBrace": "roll bar brace, corner down to the bed rail",
    "MirrorArm": "arm out from the door to the mirror",
    "DrumRope": "zig-zag lacing round the drum",
    "Drumstick": "two sticks crossed on the drum skin",
    "RollBar2": "roll bar's chamfered top corner",
    "RollBar4": "roll bar's chamfered top corner",
    "Lip": "segment of a wheel-arch lip (a ring)",
    "SteeringWheel_": "steering wheel rim segment / spoke, tilted to the driver",
    "Wheel_": "wheel spoke, turns with the wheel",
    "Seat": "seat back raked for the rider",
}


def load_source(repo):
    src = (Path(repo) / "ReplicatedStorage/Shared/VehicleModels.lua").read_text()
    # Luau compound assignment -> Lua 5.x
    return re.sub(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", src, flags=re.M)


def build(source, model_id):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    vm = lua.execute(source)
    make = lua.eval("function(vm, id) local m = vm.Build(id, nil, { scheme = 1 }); return dumpModel(m) end")
    rows = make(vm, model_id)
    parts = []
    for i in range(1, len(rows) + 1):
        r = rows[i]
        v = [r[j] for j in range(1, 20)]
        parts.append({
            "name": v[0], "cls": v[1], "shape": v[2], "size": v[3:6], "pos": v[6:9],
            "cols": (v[9:12], v[12:15], v[15:18]), "transparency": v[18],
        })
    return parts


def dot(a, b): return sum(x * y for x, y in zip(a, b))
def norm(a): m = math.sqrt(dot(a, a)); return [x / m for x in a]
def angle(a, b): return math.degrees(math.acos(min(1.0, abs(dot(norm(a), norm(b))))))


def long_axis(p):
    """(axis vector, length, thickness) as Roblox draws the part."""
    sx, sy, sz = p["size"]
    if p["shape"].endswith("Cylinder"):
        return p["cols"][0], sx, min(sy, sz), max(sy, sz)
    order = sorted(range(3), key=lambda k: -p["size"][k])
    return p["cols"][order[0]], p["size"][order[0]], p["size"][order[2]], p["size"][order[1]]


def world_extent(p):
    lo, hi = [], []
    for k in range(3):
        half = sum(abs(p["cols"][a][k]) * p["size"][a] / 2 for a in range(3))
        lo.append(p["pos"][k] - half)
        hi.append(p["pos"][k] + half)
    return lo, hi


def audit(parts, model_id, verbose=True):
    faults, rods = [], []
    for p in parts:
        if p["transparency"] >= 1:
            continue  # hulls, hubs, pivots: never drawn
        if p["shape"].endswith("Cylinder") and abs(p["size"][1] - p["size"][2]) > 1e-6:
            faults.append(f"{model_id}/{p['name']}: cylinder not round, Size {p['size']} (length passed in Y?)")
        axis, length, thin, thick = long_axis(p)
        if thick <= ROD_THIN and length >= ROD_RATIO * thick:
            rods.append((p, axis, length, thick))
        elif p["name"].startswith("Bat"):
            rods.append((p, axis, length, thick))  # too fat to be a rod, but held to the same reach
    rodset = {id(r[0]) for r in rods}
    body_lo, body_hi = [1e9] * 3, [-1e9] * 3
    for p in parts:
        if p["transparency"] < 1 and id(p) not in rodset:
            lo, hi = world_extent(p)
            body_lo = [min(a, b) for a, b in zip(body_lo, lo)]
            body_hi = [max(a, b) for a, b in zip(body_hi, hi)]
    if verbose:
        print(f"{model_id}: {len(parts)} parts, {len(rods)} rod candidates examined "
              f"(thin <= {ROD_THIN}, length >= {ROD_RATIO}x thickness); body envelope "
              f"x {body_lo[0]:.2f}..{body_hi[0]:.2f} y {body_lo[1]:.2f}..{body_hi[1]:.2f} z {body_lo[2]:.2f}..{body_hi[2]:.2f}")
    for p, axis, length, thick in rods:
        off = min(angle(axis, w) for w in ((1, 0, 0), (0, 1, 0), (0, 0, 1)))
        lo, hi = world_extent(p)
        out = max(max(b - x for b, x in zip(body_lo, lo)), max(x - b for b, x in zip(body_hi, hi)), 0)
        why = next((r for k, r in INTENDED_ANGLED.items() if p["name"].startswith(k)), None)
        verdict = "ok"
        if off > AXIS_TOL and not why and not p["name"].startswith("Bat"):
            verdict = "FLAG leaning"
            faults.append(f"{model_id}/{p['name']}: rod leans {off:.1f} deg off every world axis and is not an intended lean")
        if out > PROTRUDE:
            verdict = "FLAG protrudes"
            faults.append(f"{model_id}/{p['name']}: rod reaches {out:.2f} studs past the body envelope")
        if verbose:
            a = ",".join(f"{x:+.2f}" for x in axis)
            print(f"  {verdict:15s} {p['name']:18s} {p['shape'].split('.')[-1]:8s} len {length:5.2f} thick {thick:4.2f} "
                  f"axis ({a}) off-axis {off:5.1f} past body {out:4.2f}" + (f"  [{why}]" if why and off > AXIS_TOL else ""))
    bat = {p["name"]: p for p in parts if p["name"].startswith("Bat")}
    if bat:
        knob, end = bat.get("BatKnob"), bat.get("BatEnd")
        line = [e - k for e, k in zip(end["pos"], knob["pos"])]
        along = angle((line[0], 0, line[2]), (0, 0, 1))  # heading in plan: the rake is allowed
        if verbose:
            print(f"  bat line knob->end ({','.join(f'{x:+.2f}' for x in norm(line))}), {along:.1f} deg off the van's length in plan")
        if along > BAT_ALONG_TOL:
            faults.append(f"{model_id}/bat: runs {along:.1f} deg off the van's length (across the roof = sideways)")
        for name, p in sorted(bat.items()):
            if not p["shape"].endswith("Cylinder"):
                continue
            off = angle(p["cols"][0], line)
            if verbose:
                print(f"  bat part {name:10s} X axis {off:5.2f} deg off the bat line")
            if off > BAT_COAXIAL_TOL:
                faults.append(f"{model_id}/{name}: bat part {off:.2f} deg off the bat's own line (kinked or sideways)")
    return faults


def main(repo="."):
    source = load_source(repo)
    failed = False
    for model_id in MODELS:
        faults = audit(build(source, model_id), model_id)
        for f in faults:
            print("  FAULT " + f)
        failed |= bool(faults)
        print(f"{model_id}: {len(faults)} faults")

    # Planted faults, each through the real pipeline (edited source, rebuilt, audited).
    plants = [
        ("cylinder length in Y (the X-axis lesson)", "SahurVan",
         'local part = self:make("Part", name, V(length, diameter, diameter), at, role, anchor)',
         'local part = self:make("Part", name, (name == "BatBarrel") and V(diameter, length, diameter) or V(length, diameter, diameter), at, role, anchor)', "BatBarrel: cylinder not round"),
        ("bat turned across the roof", "SahurVan",
         "local bat = CF(V(batX, batY, batZ)) * A(",
         "local bat = CF(V(batX, batY, batZ)) * A(0, 25, 0) * A(", "bat: runs"),
        ("unintended leaning pole", "CrocodiloRanger",
         'b:box("BumperStep"',
         'b:tube("PlantPole", V(0, 3, 6), V(1.5, 5, 7), 0.2, "trim")\n\t\tb:box("BumperStep"', "PlantPole: rod leans"),
        ("pole sticking out of the body", "CrocodiloRanger",
         'b:box("BumperStep"',
         'b:tube("PlantPole", V(0, 3, 6), V(0, 3, 10.5), 0.2, "trim")\n\t\tb:box("BumperStep"', "PlantPole: rod reaches"),
        ("kinked bat (a lift on one piece)", "SahurVan",
         'b:tube("BatThroat", batAt(0.7), batAt(1.6)',
         'b:tube("BatThroat", batAt(0.7), batAt(1.6, 0.2)', "BatThroat: bat part"),
    ]
    for label, model_id, old, new, tag in plants:
        assert source.count(old) == 1, f"plant anchor missing or ambiguous: {old!r}"
        faults = audit(build(source.replace(old, new), model_id), model_id, verbose=False)
        caught = any(tag in f for f in faults)
        print(f"plant [{label}] on {model_id}: {'CAUGHT' if caught else 'MISSED'}" + (f" -- {faults[0]}" if caught else ""))
        failed |= not caught
    print("vehicle_models_axis_check: " + ("FAIL" if failed else "OK"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
