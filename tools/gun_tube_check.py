"""Floating tubes, loose rods and doubled barrels on every gun (OLIVER_LIST #34), without Studio.

The Studio probe (tools/floating_tube_probe.lua) was written and never run. This is its offline twin:
it runs the REAL GunModels.lua -- with the real GunModelsCreative, GunModelsWorkshop, ArsenalFinish,
ZFight and WeaponData (so the whole arsenal, creative and workshop guns included) -- under lupa with
the Vector3 / CFrame / Instance mock from tools/vehicle_models_axis_check.py, builds every weapon id,
and reads every visible part back AFTER the z-fight pass, the frame the game shows.

A Cylinder's length is its own X axis whatever Size.Y and Size.Z say (COORDINATION: the Cylinder
X-axis lesson); its diameter is the smaller of Y and Z.

Three checks, per gun:
  1. FLOATING TUBE (the port of the probe, same numbers): a cylinder at least 60 mm long, lying along
     the bore, more than 8 mm off the bore line, not itself the barrel, with more than 55 mm of its run
     having nothing within 7 mm on its side facing the bore while the gun is within 21 mm across that
     daylight (a slot). The SMG's cocking tube held at one point read as a second barrel floating over
     the first. The probe looked only under the tube, which flags every magazine tube hung beneath its
     barrel; the bore side is where daylight makes a second barrel. BY_DESIGN names the tubes whose
     daylight is the point (bipod legs, a carry handle, a revolver drum).
  2. LOOSE ROD: a rod (a cylinder, or a block with two thin sides, at least 2.5 times as long as it is
     thick) whose surface touches no other visible part (to 0.6 mm). A rod in mid air.
  3. DOUBLED BARREL: two long cylinders along the bore, parallel, of about the same diameter, whose
     walls cut through each other over 20 mm or more of their length without one sitting inside the
     other. A sleeve round a barrel (handguard tube, suppressor, gas block) is nested, so it passes;
     two tubes side by side that merely touch pass; a copy laid through the barrel does not.

Planted faults run through the same pipeline: the gun module's SOURCE is edited and rebuilt, and each
planted gun must fail the check it targets.
    python3 tools/gun_tube_check.py [repo] [weaponId ...]        -> exit 0 when clean
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK, luau_to_lua  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

EXTRA = r"""
table.clone = table.clone or function(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end
table.find = table.find or function(t, v) for i, x in ipairs(t) do if x == v then return i end end end
table.freeze = table.freeze or function(t) return t end
task = { wait = function() end, spawn = function(f, ...) f(...) end, defer = function() end }
os.clock = os.clock
workspace = { Terrain = {}, Raycast = function() return nil end }
RaycastParams = { new = function() return {} end }
local Inst = getmetatable(Instance.new("Part"))
function Inst.FindFirstChild(i, name) for _, k in ipairs(rawget(i, "kids")) do if k.Name == name then return k end end end
local C3 = {}
C3.__index = C3
function C3.Lerp(a, b, t) return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
Color3.new = function(r, g, b) return setmetatable({ __color = true, R = r, G = g, B = b }, C3) end
Color3.fromRGB = function(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
Color3.fromHSV = function(h, s, v) return Color3.new(v, v, v) end
function V3.Lerp(a, b, t) return a + (b - a) * t end
UDim2.new = function() return {} end
Vector2.zero = Vector2.new(0, 0)
Font = { new = function() return {} end, fromEnum = function() return {} end }
NumberRange = { new = function() return {} end }
ColorSequence = { new = function() return {} end }
NumberSequence = { new = function() return {} end }
-- Modules by name: Shared:WaitForChild(name) / FindFirstChild(name) hand back a handle, require loads it.
local handles = {}
local function handle(name)
	if not SOURCES[name] then return nil end
	handles[name] = handles[name] or { __module = name }
	return handles[name]
end
local SharedFolder = { WaitForChild = function(_, n) return handle(n) or error("no module " .. n) end,
	FindFirstChild = function(_, n) return handle(n) end }
script = { Parent = SharedFolder }
local loaded = {}
function require(h)
	local name = h.__module
	if loaded[name] == nil then
		loaded[name] = assert(load(SOURCES[name], "=" .. name))()
	end
	return loaded[name]
end
function buildAll(ids)
	local GunModels = require(handle("GunModels"))
	local WeaponData = require(handle("WeaponData"))
	local Rarity = require(handle("Rarity"))
	local out = {}
	local list = {}
	if ids then for _, id in ipairs(ids) do list[#list + 1] = id end
	else for id in pairs(WeaponData.Weapons) do list[#list + 1] = id end; table.sort(list) end
	for _, id in ipairs(list) do
		local def = WeaponData.Get and WeaponData.Get(id) or WeaponData.Weapons[id]
		local ok, model = pcall(GunModels.Build, def, Rarity.Color(def.rarity), Enum.Material.Metal, {})
		if not ok then out[id] = tostring(model) else out[id] = dumpModel(model) end
	end
	return out, GunModels.StudsPerMillimetre
end
"""

LONG, OFF_BORE, UNDER, STEP, RUN = 60, 8, 7, 4, 55  # mm, as the Studio probe
SLOT = 21  # mm: daylight narrower than this between a tube and the gun is a slot; wider, the tube stands apart
SKIP = {"Bore", "Barrel", "Suppressor", "MuzzleBrake", "Silencer"}
# Tubes whose daylight is the point, each read against its builder: a folded bipod's legs hang from
# their clamp (GunModels Builder:bipod), a carry handle is held at both ends so a hand fits under it,
# and a revolver drum's tubes and axle run between its two plates round nothing. The double broom's two
# bristle heads splay into each other: bristles, not a second barrel.
BY_DESIGN = {"Bipod", "CarryHandle", "DrumTube", "DrumAxle", "Bristles"}
TOUCH = 0.6  # mm
ROD_RATIO = 2.5
DOUBLE_OVERLAP = 20  # mm of shared length
SAME_DIAMETER = 0.2  # within 20%


def load_sources(repo):
    shared = Path(repo) / "ReplicatedStorage/Shared"
    # Every Shared module is on offer; only what the gun modules require is ever parsed.
    return {f.stem: luau_to_lua(f.read_text()) for f in shared.glob("*.lua")}


def build(sources, ids=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    src = lua.table()
    for k, v in sources.items():
        src[k] = v
    lua.globals().SOURCES = src
    lua.execute(EXTRA)
    table, mm = lua.globals().buildAll(lua.table_from(ids) if ids else None)
    guns = {}
    for gid, rows in table.items():
        if isinstance(rows, str):
            guns[gid] = rows
            continue
        parts = []
        for i in range(1, len(rows) + 1):
            v = [rows[i][j] for j in range(1, 21)]
            if v[18] >= 1:
                continue
            parts.append({"name": v[0], "shape": v[2].split(".")[-1], "size": [x / mm for x in v[3:6]],
                          "pos": [x / mm for x in v[6:9]], "cols": (list(v[9:12]), list(v[12:15]), list(v[15:18]))})
        guns[gid] = parts
    return guns


def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def add(a, b): return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
def mul(a, k): return [a[0] * k, a[1] * k, a[2] * k]


def is_cyl(p): return p["shape"] == "Cylinder"
def radius(p): return min(p["size"][1], p["size"][2]) / 2


def world(p, local):
    c = p["cols"]
    return add(p["pos"], add(add(mul(c[0], local[0]), mul(c[1], local[1])), mul(c[2], local[2])))


def to_local(p, point):
    d = sub(point, p["pos"])
    return [dot(d, c) for c in p["cols"]]


def inside(p, point, eps):
    x, y, z = to_local(p, point)
    hx, hy, hz = (s / 2 for s in p["size"])
    if p["shape"] == "Ball":
        r = min(p["size"]) / 2 + eps
        return x * x + y * y + z * z <= r * r
    if is_cyl(p):
        r = radius(p) + eps
        return abs(x) <= hx + eps and y * y + z * z <= r * r
    return abs(x) <= hx + eps and abs(y) <= hy + eps and abs(z) <= hz + eps


def bound(p):
    r = math.sqrt(sum((s / 2) ** 2 for s in p["size"]))
    return p["pos"], r


def near(a, b, pad):
    (pa, ra), (pb, rb) = bound(a), bound(b)
    d = sub(pa, pb)
    return dot(d, d) <= (ra + rb + pad) ** 2


def along_bore(p): return abs(p["cols"][0][2]) > 0.9


def clear_runs(tube, others):
    """The Studio probe's sampler, on the bore side of the tube: (longest stretch with nothing within UNDER
    mm, longest such stretch with the gun less than SLOT mm away across the daylight -- a slot)."""
    r, length = radius(tube), tube["size"][0]
    samples = max(2, int(length // STEP))
    cands = [o for o in others if near(tube, o, SLOT + 2)]
    # The side facing the bore line: under a tube above the barrel (the SMG's cocking tube), over a
    # magazine tube below it, inboard of one beside it. Daylight THERE is what reads as a second barrel;
    # the probe looked only underneath, which flags every magazine tube hung under its barrel.
    toward = [-tube["pos"][0], -tube["pos"][1], 0]
    m = math.hypot(toward[0], toward[1]) or 1
    toward = [toward[0] / m, toward[1] / m, 0]
    held, slot = [], []
    for i in range(samples + 1):
        centre = world(tube, [(i / samples * 2 - 1) * length / 2, 0, 0])
        held.append(any(inside(o, add(centre, mul(toward, r + 1)), UNDER) for o in cands))
        slot.append(any(inside(o, add(centre, mul(toward, r + 1 + d)), UNDER) for o in cands for d in (UNDER, 2 * UNDER)))
    step = length / samples
    best = slotted = 0.0
    i = 0
    while i <= samples:
        if held[i]:
            i += 1
            continue
        j = i
        while j < samples and not held[j + 1]:
            j += 1
        run = (j - i + 1) * step
        best = max(best, run)
        # With the gun just across the daylight the tube reads as a second barrel beside the first. Far
        # from everything (a spoon-handle stock, a buffer tube behind the receiver) it is its own thing.
        if any(slot[i:j + 1]):
            slotted = max(slotted, run)
        i = j + 1
    return best, slotted


def rod_shape(p):
    """(long axis index, length, thickness) or None."""
    if is_cyl(p):
        ln, th = p["size"][0], 2 * radius(p)
        return (0, ln, th) if ln >= ROD_RATIO * th else None
    order = sorted(range(3), key=lambda k: -p["size"][k])
    ln, th = p["size"][order[0]], p["size"][order[1]]
    return (order[0], ln, th) if p["shape"] == "Block" and ln >= ROD_RATIO * th else None


def surface_points(p):
    """Points over a part's surface, spaced about 2 mm, ends included."""
    pts = []
    h = [s / 2 for s in p["size"]]
    if is_cyl(p):
        r = radius(p)
        n = max(2, int(p["size"][0] // 2))
        for i in range(n + 1):
            x = -h[0] + p["size"][0] * i / n
            for k in range(12):
                a = k * math.pi / 6
                pts.append(world(p, [x, r * math.cos(a), r * math.sin(a)]))
        for s in (-1, 1):
            for f in (0, 0.5):
                for k in range(8):
                    a = k * math.pi / 4
                    pts.append(world(p, [s * h[0], f * r * math.cos(a), f * r * math.sin(a)]))
        return pts
    steps = [max(1, int(p["size"][k] // 2)) for k in range(3)]
    for axis in range(3):
        u, v = [k for k in range(3) if k != axis]
        for s in (-1, 1):
            for i in range(steps[u] + 1):
                for j in range(steps[v] + 1):
                    loc = [0, 0, 0]
                    loc[axis] = s * h[axis]
                    loc[u] = -h[u] + p["size"][u] * i / steps[u]
                    loc[v] = -h[v] + p["size"][v] * j / steps[v]
                    pts.append(world(p, loc))
    return pts


def touches(a, b):
    if not near(a, b, TOUCH):
        return False
    return any(inside(b, q, TOUCH) for q in surface_points(a)) or any(inside(a, q, TOUCH) for q in surface_points(b))


def doubled(a, b):
    """Shared length (mm) of two parallel same-size tubes whose walls cut through each other, else 0."""
    if abs(dot(a["cols"][0], b["cols"][0])) < 0.999:
        return 0
    ra, rb = radius(a), radius(b)
    if abs(ra - rb) > SAME_DIAMETER * max(ra, rb):
        return 0
    axis = a["cols"][0]
    d = sub(b["pos"], a["pos"])
    t = dot(d, axis)
    off = sub(d, mul(axis, t))
    gap = math.sqrt(dot(off, off))
    small, big = min(ra, rb), max(ra, rb)
    if gap >= ra + rb - 0.5:  # side by side, touching at most
        return 0
    if gap + small <= big - 0.5:  # one inside the other: a sleeve or a liner
        return 0
    lo = max(-a["size"][0] / 2, t - b["size"][0] / 2)
    hi = min(a["size"][0] / 2, t + b["size"][0] / 2)
    return max(0, hi - lo)


def check_gun(parts):
    found = []
    for p in parts:
        if is_cyl(p) and p["name"] not in SKIP and p["name"] not in BY_DESIGN and along_bore(p) and p["size"][0] >= LONG:
            if abs(p["pos"][1]) > OFF_BORE or abs(p["pos"][0]) > OFF_BORE:
                _, run = clear_runs(p, [o for o in parts if o is not p])
                if run > RUN:
                    found.append(f"FLOATING TUBE {p['name']}: {p['size'][0]:.0f} mm long, {run:.0f} mm of it with a slot "
                                 "of daylight between it and the gun")
    for p in parts:
        shape = rod_shape(p)
        if shape and not any(touches(p, o) for o in parts if o is not p):
            found.append(f"LOOSE ROD {p['name']}: {shape[1]:.0f} x {shape[2]:.1f} mm touches nothing")
    # "...Round" pieces are the rounded edges of one box (Builder:rounded): parallel by design.
    tubes = [p for p in parts if is_cyl(p) and along_bore(p) and p["size"][0] >= LONG / 2
             and not p["name"].endswith("Round") and p["name"] not in BY_DESIGN]
    for i, a in enumerate(tubes):
        for b in tubes[i + 1:]:
            shared = doubled(a, b)
            if shared >= DOUBLE_OVERLAP:
                found.append(f"DOUBLED BARREL {a['name']} / {b['name']}: walls cross over {shared:.0f} mm")
    return found


# -- planted faults: source edits on a real gun, each must be caught by the check it targets --------
def planted(sources):
    gm = sources["GunModels"]
    anchor = "\tlocal receiver = build(g)\n"
    assert anchor in gm, "GunModels.Build anchor moved; update the planted faults"
    body = (
        'do\n'
        # A tube 10 mm clear of a block along its whole run: the SMG's slot, away from the gun itself.
        '\tif PLANT == "float" then g:box("PlantBlock", V(60, 20, 200), CF(0, 400, -200), F.steel); '
        'g:cyl("PlantTube", 150, 14, CF(0, 427, -200), F.steel) end\n'
        '\tif PLANT == "rod" then g:cylY("PlantRod", 60, 4, CF(0, 900, 0), F.steel) end\n'
        '\tif PLANT == "double" then g:cyl("PlantBarrel", 200, 16, CF(0, 5, -300), F.steel); '
        'g:cyl("PlantBarrel2", 200, 16, CF(0, 12, -300), F.steel) end\n'
        'end\n')
    cases = {}
    for kind, want in (("float", "FLOATING TUBE PlantTube"), ("rod", "LOOSE ROD PlantRod"),
                       ("double", "DOUBLED BARREL PlantBarrel")):
        src = dict(sources)
        src["GunModels"] = gm.replace(anchor, anchor + body.replace("PLANT", f'"{kind}"'), 1)
        cases[kind] = (src, want)
    return cases


def main(repo, only=None):
    sources = load_sources(repo)
    if "F.steel" not in sources["GunModels"] and "steel =" not in sources["GunModels"]:
        print("note: F.steel not found; planted faults may not build")
    guns = build(sources, only)
    bad = 0
    for gid in sorted(guns):
        parts = guns[gid]
        if isinstance(parts, str):
            print(f"{gid}: BUILD FAILED {parts}")
            bad += 1
            continue
        for line in check_gun(parts):
            print(f"{gid}: {line}")
            bad += 1
    print(f"{len(guns)} guns built, {bad} findings")
    # Self-test: plant each fault on the first gun and require the matching finding.
    first = sorted(guns)[0]
    selftest_ok = True
    for kind, (src, want) in planted(sources).items():
        parts = build(src, [first])[first]
        lines = check_gun(parts) if not isinstance(parts, str) else [parts]
        hit = any(line.startswith(want) for line in lines)
        selftest_ok &= hit
        print(f"self-test planted {kind} on {first}: {'caught' if hit else 'MISSED'}")
    return 0 if bad == 0 and selftest_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ".", sys.argv[2:] or None))
