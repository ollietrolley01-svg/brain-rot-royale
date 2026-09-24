"""The team-base ruins (TeamBaseRuins.lua), checked without Studio.

Runs the REAL ServerScriptService/Modules/TeamBaseRuins.lua (its Layout, the whole geometry), the real
ReplicatedStorage/Shared/ZFight.lua and the real ServerScriptService/Modules/DestructibleService.lua
under the lupa mock from tools/vehicle_models_axis_check.py (extended here with Random, Color3 maths,
TrussPart and Roblox's part defaults), then measures what was built:

  budget     400..700 parts per base (said, with the count per room)
  zfight     ZFight.Scan finds no fighting pair at source (before any fix) and none after ZFight.Fix,
             the pass Build runs; also how many Fix had to move
  floating   every part is connected, through parts it touches (OBBs, 0.12 slack), to the ground (the
             flattened pad at local y 0)
  cylinders  every Cylinder part is round (Size.Y == Size.Z), so its length is X
  doorways   every declared doorway is at least 4 wide and 7 tall with nothing solid in it
  walk       an R15 body (2 wide, 5.2 tall, steps up to 1.5) walks from every spawn pad to every chest
             spot, every vehicle bay and out through every entrance, over a 0.5-stud grid
  pads       each on a floor, headroom over it, 7+ from every chest, 18+ from every bay (PadClearance)
  chests     each on a floor at its height (the chest snap ray), 2.4 clear round it for any yaw
  loot       each on a floor, 6+ from pads, 3+ from chests, off the bays
  bays       level under VehicleService's footing points, nothing queryable over the footprint (the
             footing ray starts 24 up), and a straight corridor 9.6 wide x 7.5 tall out through the gate
  destruct   DestructibleService.FromPart (the real one) breaks every "Wall", and nothing in the spawn
             shelter, no floor, pad, pillar, beam, gate post or rubble; every tagged pool under 90 across
  identical  team 2's base, built turned and moved with the other colour, is team 1's part for part in
             its own frame; the only differences are colours, only on parts named Team*
  seed       the same seed builds the same ruin twice
  build      TeamBaseRuins.Build itself, on a mock map: it clears the small scenery and the loot off
             the site and keeps the big things and the roads, stands at the height FlattenPad
             returns, and where FlattenPad refuses stands on a Foundation plinth down to the lowest
             ground; the pads come out where Layout put them in the site's frame

Planted faults (source edits, rebuilt through the same pipeline) must each be caught:
    python3 tools/team_base_ruins_check.py [repo]            the checks
    python3 tools/team_base_ruins_check.py [repo] --plant    and the planted faults
"""

import math
import re
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK, luau_to_lua  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

BUDGET = (400, 700)
BODY_RADIUS, BODY_HEIGHT, STEP = 1.0, 5.2, 1.5
GRID = 0.5
FLAT_X, FLAT_Z = 50.0, 46.0
DOOR_WIDTH, DOOR_HEIGHT = 4.0, 7.0
CHEST_CLEAR = 2.4
PAD_CHEST, PAD_BAY, PAD_LOOT, CHEST_LOOT = 7.0, 18.0, 6.0, 3.0
CAR = (8.9, 16.6)
CORRIDOR_HALF, CORRIDOR_HEIGHT = 4.8, 7.5
FOOTING_TOLERANCE = 0.5
TOUCH = 0.12

EXTRA_MOCK = r"""
-- Roblox's part defaults, TrussPart, Random, Color3 maths, script, warn.
PARTS_EXTRA = true
local baseNew = Instance.new
local PART_CLASSES = { Part = true, WedgePart = true, TrussPart = true }
Instance.new = function(class)
    local inst = baseNew(class)
    if PART_CLASSES[class] then
        local props = rawget(inst, "props")
        props.CanCollide = true
        props.CanQuery = true
        props.CanTouch = true
        props.Anchored = false
    end
    return inst
end
local baseIsA = getmetatable(baseNew("Part")).__index
Random = {}
Random.__index = Random
function Random.new(seed)
    return setmetatable({ s = (math.floor(seed or 1) % 2147483646) + 1 }, Random)
end
function Random:_next()
    self.s = (self.s * 48271) % 2147483647
    return self.s / 2147483647
end
function Random:NextNumber(a, b)
    local r = self:_next()
    if a then return a + (b - a) * r end
    return r
end
function Random:NextInteger(a, b)
    return a + math.floor(self:_next() * (b - a + 1))
end
local C3 = {}
C3.__index = C3
local function c3(r, g, b) return setmetatable({ R = r, G = g, B = b, __color = true }, C3) end
Color3 = { new = c3, fromRGB = function(r, g, b) return c3(r / 255, g / 255, b / 255) end }
function C3.Lerp(a, b, t) return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
script = { Parent = { WaitForChild = function(_, name) return name end } }
function warn(...) end
os.clock = os.clock or function() return 0 end
local Inst = getmetatable(baseNew("Part")).__index
local InstMeta = getmetatable(baseNew("Part"))
InstMeta.__index = function(i, k)
    if k == "IsDescendantOf" then
        return function(self, root)
            local node = self.Parent
            while node do
                if node == root then return true end
                node = node.Parent
            end
            return false
        end
    elseif k == "FindFirstChild" then
        return function(self, name)
            for _, kid in ipairs(rawget(self, "kids")) do if kid.Name == name then return kid end end
            return nil
        end
    elseif k == "GetExtentsSize" then
        return function(self) return rawget(self, "props").Extents or Vector3.new(4, 4, 4) end
    end
    return Inst(i, k)
end
task = { wait = function() end }
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
"""

DUMP = r"""
local function chain(part, stop)
    local names = {}
    local node = part.Parent
    while node and node ~= stop do
        table.insert(names, 1, node.Name)
        node = node.Parent
    end
    return table.concat(names, "/")
end
function dumpParts(model)
    local out = {}
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            local c, s = p.CFrame, p.Size
            local col = p.Color or {}
            table.insert(out, { p.Name, p.ClassName, tostring(p.Shape), s.X, s.Y, s.Z,
                c.p.X, c.p.Y, c.p.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z,
                p.CanCollide and 1 or 0, p.CanQuery and 1 or 0, p.Transparency or 0,
                tostring(p:GetAttribute("Destructible")), p:GetAttribute("DestructibleHealth") or 0,
                chain(p, model), col.R or 0, col.G or 0, col.B or 0 })
        end
    end
    return out
end
function countLights(model)
    local n, shadows = 0, 0
    for _, p in ipairs(model:GetDescendants()) do
        if p.ClassName == "PointLight" then
            n = n + 1
            if p.Shadows then shadows = shadows + 1 end
        end
    end
    return n, shadows
end
function cfList(list)
    local out = {}
    for _, c in ipairs(list) do
        table.insert(out, { c.p.X, c.p.Y, c.p.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z })
    end
    return out
end
function topOf(part, model)
    local node = part
    while node.Parent and node.Parent ~= model do
        node = node.Parent
    end
    return node == part and "(root)" or node.Name
end
function makeFrame(x, y, z, yaw)
    return CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0)
end
"""


def sources(repo):
    root = Path(repo)
    return {
        "ruins": (root / "ServerScriptService/Modules/TeamBaseRuins.lua").read_text(),
        "zfight": (root / "ReplicatedStorage/Shared/ZFight.lua").read_text(),
        "destruct": (root / "ServerScriptService/Modules/DestructibleService.lua").read_text(),
    }


class Build:
    """One Lua runtime: the modules loaded, able to lay a base out and dump it. Each is a different
    server as far as math.random goes, so a layout that reads it cannot come out the same twice."""

    servers = 0

    def __init__(self, src):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        Build.servers += 1
        self.lua.execute("math.randomseed(%d)" % (7919 * Build.servers))
        mock = MOCK.replace("local PARTS = { Part = true, WedgePart = true }",
                            "local PARTS = { Part = true, WedgePart = true, TrussPart = true }")
        self.lua.execute(mock + EXTRA_MOCK + DUMP)
        modules = self.lua.eval("function() MODULES = {}; return MODULES end")()
        modules["ZFight"] = self.lua.execute(luau_to_lua(src["zfight"]))
        self.zfight = modules["ZFight"]
        modules["MapTerrain"] = self.lua.eval("{}")
        modules["Remotes"] = self.lua.eval("{ Event = function() return { FireAllClients = function() end } end }")
        modules["CombatService"] = self.lua.eval("{}")
        self.ruins = self.lua.execute(luau_to_lua(src["ruins"]))
        self.src = src
        self._destruct = None

    def layout(self, x, y, z, yaw, color, seed):
        g = self.lua.globals()
        frame = g.makeFrame(x, y, z, yaw)
        colour = g.Color3.fromRGB(*color)
        model, info = self.ruins.Layout(frame, colour, seed)
        return frame, model, info

    def dump(self, model):
        rows = self.lua.globals().dumpParts(model)
        parts = []
        for i in range(1, len(rows) + 1):
            r = rows[i]
            v = [r[j] for j in range(1, 28)]
            parts.append({
                "name": v[0], "cls": v[1], "shape": v[2], "size": tuple(v[3:6]),
                "pos": tuple(v[6:9]), "axes": (tuple(v[9:12]), tuple(v[12:15]), tuple(v[15:18])),
                "collide": bool(v[18]), "query": bool(v[19]), "transparency": v[20],
                "tag": v[21], "health": v[22], "path": v[23], "color": tuple(v[24:27]),
            })
        return parts

    def cfs(self, lst):
        rows = self.lua.globals().cfList(lst)
        return [tuple(rows[i][j] for j in range(1, 13)) for i in range(1, len(rows) + 1)]

    def destruct(self):
        """The real DestructibleService, loaded once, and a workspace with a Map in it."""
        if self._destruct is None:
            ws = self.lua.eval('Instance.new("Workspace")')
            self.lua.globals().workspace = ws
            self._destruct = self.lua.execute(luau_to_lua(self.src["destruct"]))
        return self._destruct


# ------------------------------------------------------------------------------------------------
# Geometry
# ------------------------------------------------------------------------------------------------

def obb(p):
    return p["pos"], p["axes"], tuple(s / 2 for s in p["size"])


def aabb(p):
    c, axes, h = obb(p)
    ext = [sum(abs(axes[k][i]) * h[k] for k in range(3)) for i in range(3)]
    return [c[i] - ext[i] for i in range(3)], [c[i] + ext[i] for i in range(3)]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def obb_overlap(a, b, slack=0.0):
    """Separating-axis test for two boxes, each grown by slack/2."""
    ca, aa, ha = a
    cb, ab, hb = b
    ha = [h + slack / 2 for h in ha]
    hb = [h + slack / 2 for h in hb]
    d = (cb[0] - ca[0], cb[1] - ca[1], cb[2] - ca[2])
    axes = list(aa) + list(ab)
    for u in aa:
        for v in ab:
            c = cross(u, v)
            if dot(c, c) > 1e-9:
                axes.append(c)
    for ax in axes:
        ra = sum(abs(dot(ax, aa[k])) * ha[k] for k in range(3))
        rb = sum(abs(dot(ax, ab[k])) * hb[k] for k in range(3))
        if abs(dot(d, ax)) > ra + rb + 1e-9:
            return False
    return True


def box_obb(lo, hi):
    c = tuple((lo[i] + hi[i]) / 2 for i in range(3))
    h = tuple((hi[i] - lo[i]) / 2 for i in range(3))
    return c, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), h


def hits_box(parts, lo, hi, want):
    """Parts passing `want` whose OBB meets the axis-aligned box lo..hi."""
    probe = box_obb(lo, hi)
    out = []
    for p in parts:
        if not want(p):
            continue
        plo, phi = p["aabb"]
        if any(plo[i] > hi[i] or phi[i] < lo[i] for i in range(3)):
            continue
        if obb_overlap(obb(p), probe):
            out.append(p)
    return out


def top_under(parts, x, z, below, want):
    """The highest top of a `want` part covering (x, z) at or below `below` (the footing / snap ray)."""
    best = None
    for p in parts:
        if not want(p):
            continue
        lo, hi = p["aabb"]
        if lo[0] <= x <= hi[0] and lo[2] <= z <= hi[2] and hi[1] <= below:
            # exact for the axis-aligned floors; a turned part is taken by its box
            best = hi[1] if best is None else max(best, hi[1])
    return best


# ------------------------------------------------------------------------------------------------
# The checks
# ------------------------------------------------------------------------------------------------

def check_floating(parts):
    n = len(parts)
    grounded = [p["aabb"][0][1] <= 0.1 and abs(p["pos"][0]) <= FLAT_X and abs(p["pos"][2]) <= FLAT_Z for p in parts]
    boxes = [obb(p) for p in parts]
    # bucket by a coarse grid on x/z so the pair test is not n^2
    cell = 8.0
    buckets = {}
    for i, p in enumerate(parts):
        lo, hi = p["aabb"]
        for gx in range(int(math.floor((lo[0] - TOUCH) / cell)), int(math.floor((hi[0] + TOUCH) / cell)) + 1):
            for gz in range(int(math.floor((lo[2] - TOUCH) / cell)), int(math.floor((hi[2] + TOUCH) / cell)) + 1):
                buckets.setdefault((gx, gz), []).append(i)
    adj = [set() for _ in range(n)]
    for members in buckets.values():
        for a_i in range(len(members)):
            i = members[a_i]
            for b_i in range(a_i + 1, len(members)):
                j = members[b_i]
                if j in adj[i]:
                    continue
                la, ha = parts[i]["aabb"]
                lb, hb = parts[j]["aabb"]
                if any(la[k] > hb[k] + TOUCH or lb[k] > ha[k] + TOUCH for k in range(3)):
                    continue
                if obb_overlap(boxes[i], boxes[j], TOUCH):
                    adj[i].add(j)
                    adj[j].add(i)
    seen = [False] * n
    queue = deque(i for i in range(n) if grounded[i])
    for i in queue:
        seen[i] = True
    while queue:
        i = queue.popleft()
        for j in adj[i]:
            if not seen[j]:
                seen[j] = True
                queue.append(j)
    return [parts[i] for i in range(n) if not seen[i]]


def check_cylinders(parts):
    cyl = [p for p in parts if p["shape"].endswith("Cylinder")]
    bad = [p for p in cyl if abs(p["size"][1] - p["size"][2]) > 1e-6]
    return cyl, bad


def check_doorways(parts, doorways):
    problems = []
    for d in doorways:
        width = max(d["x1"] - d["x0"], d["z1"] - d["z0"])
        height = d["top"] - d["floor"]
        if width < DOOR_WIDTH - 1e-6:
            problems.append("%s only %.2f wide" % (d["name"], width))
        if height < DOOR_HEIGHT - 1e-6:
            problems.append("%s only %.2f tall" % (d["name"], height))
        lo = (d["x0"] + 0.05, d["floor"] + 0.05, d["z0"] + 0.05)
        hi = (d["x1"] - 0.05, d["top"] - 0.05, d["z1"] - 0.05)
        inside = hits_box(parts, lo, hi, lambda p: p["collide"])
        if inside:
            problems.append("%s blocked by %s" % (d["name"], ", ".join(sorted({p["name"] for p in inside}))))
    return problems


class Walk:
    """A grid of where an R15 body can stand, and a flood from the pads."""

    def __init__(self, parts):
        self.x0, self.z0 = -56.0, -52.0
        self.nx, self.nz = int(112 / GRID) + 1, int(104 / GRID) + 1
        n = self.nx * self.nz
        self.stand = [0.0] * n
        self.blocks = [None] * n
        for p in parts:
            if not p["collide"]:
                continue
            lo, hi = p["aabb"]
            i0, i1 = self.index_range(lo[0], hi[0], self.x0, self.nx)
            k0, k1 = self.index_range(lo[2], hi[2], self.z0, self.nz)
            floorish = hi[1] <= 1.6
            for i in range(i0, i1 + 1):
                for k in range(k0, k1 + 1):
                    c = i * self.nz + k
                    if floorish:
                        if hi[1] > self.stand[c]:
                            self.stand[c] = hi[1]
                    else:
                        if self.blocks[c] is None:
                            self.blocks[c] = []
                        self.blocks[c].append((lo[1], hi[1]))
        r = int(round(BODY_RADIUS / GRID))
        self.foot = [(di, dk) for di in range(-r, r + 1) for dk in range(-r, r + 1)
                     if (di * GRID) ** 2 + (dk * GRID) ** 2 <= BODY_RADIUS ** 2 + 1e-9]
        self.memo = {}

    @staticmethod
    def index_range(lo, hi, origin, count):
        a = int(math.ceil((lo - origin) / GRID - 1e-9))
        b = int(math.floor((hi - origin) / GRID + 1e-9))
        return max(a, 0), min(b, count - 1)

    def cell(self, x, z):
        i = int(round((x - self.x0) / GRID))
        k = int(round((z - self.z0) / GRID))
        return i, k

    def ok(self, i, k):
        key = (i, k)
        if key in self.memo:
            return self.memo[key]
        result = True
        if not (0 <= i < self.nx and 0 <= k < self.nz):
            result = False
        else:
            s = self.stand[i * self.nz + k]
            for di, dk in self.foot:
                a, b = i + di, k + dk
                if not (0 <= a < self.nx and 0 <= b < self.nz):
                    result = False
                    break
                c = a * self.nz + b
                if self.stand[c] > s + STEP:
                    result = False
                    break
                blocks = self.blocks[c]
                if blocks and any(t > s + STEP and bottom < s + BODY_HEIGHT for bottom, t in blocks):
                    result = False
                    break
        self.memo[key] = result
        return result

    def flood(self, starts):
        seen = set()
        queue = deque()
        for x, z in starts:
            i, k = self.cell(x, z)
            if self.ok(i, k):
                seen.add((i, k))
                queue.append((i, k))
        while queue:
            i, k = queue.popleft()
            s = self.stand[i * self.nz + k]
            for di in (-1, 0, 1):
                for dk in (-1, 0, 1):
                    if di == 0 and dk == 0:
                        continue
                    a, b = i + di, k + dk
                    if (a, b) in seen or not (0 <= a < self.nx and 0 <= b < self.nz):
                        continue
                    if abs(self.stand[a * self.nz + b] - s) > STEP or not self.ok(a, b):
                        continue
                    seen.add((a, b))
                    queue.append((a, b))
        return seen

    def reached(self, seen, x, z, slack=1.0):
        """Whether any cell within `slack` of (x, z) was reached."""
        i, k = self.cell(x, z)
        r = int(round(slack / GRID))
        return any((i + a, k + b) in seen for a in range(-r, r + 1) for b in range(-r, r + 1))


def local_point(cf):
    return cf[0], cf[1], cf[2]


def check_all(build, frame, model, info, parts, log):
    problems = []
    doorways = []
    raw = info["doorways"]
    for i in range(1, len(raw) + 1):
        d = raw[i]
        doorways.append({k: d[k] for k in ("name", "x0", "x1", "z0", "z1", "floor", "top")})
    pads = [local_point(c) for c in build.cfs(info["localPads"])]
    chests = [local_point(c) for c in build.cfs(info["localChests"])]
    bays = build.cfs(info["localBays"])
    loot = [local_point(c) for c in build.cfs(info["localLoot"])]
    names = info["names"]
    chest_names = [names["chests"][i] for i in range(1, len(chests) + 1)]
    bay_names = [names["bays"][i] for i in range(1, len(bays) + 1)]

    # budget
    rooms = {}
    for p in parts:
        top = p["path"].split("/")[0] if p["path"] else "(root)"
        rooms[top] = rooms.get(top, 0) + 1
    log("parts: %d  (%s)" % (len(parts), ", ".join("%s %d" % kv for kv in sorted(rooms.items()))))
    if not BUDGET[0] <= len(parts) <= BUDGET[1]:
        problems.append("budget: %d parts, outside %d..%d" % (len(parts), *BUDGET))

    # floating
    loose = check_floating(parts)
    log("floating: %d parts examined, %d unsupported" % (len(parts), len(loose)))
    for p in loose[:8]:
        problems.append("floating: %s (%s) at %.2f, %.2f, %.2f" % (p["name"], p["path"], *p["pos"]))

    # cylinders
    cyl, bad = check_cylinders(parts)
    log("cylinders: %d examined, %d not round on Y/Z" % (len(cyl), len(bad)))
    for p in bad[:5]:
        problems.append("cylinder %s sized %s: its length must be X" % (p["name"], p["size"]))

    # doorways
    door_problems = check_doorways(parts, doorways)
    log("doorways: %d examined, %d problems" % (len(doorways), len(door_problems)))
    problems += ["doorway: " + d for d in door_problems]

    # pads
    for x, y, z in pads:
        floor = top_under(parts, x, z, y + 4, lambda p: p["query"])
        if floor is None or abs(floor - y) > 0.06:
            problems.append("pad (%.1f, %.1f): floor at %s, pad at %.2f" % (x, z, floor, y))
        over = hits_box(parts, (x - 1.5, y + 0.2, z - 1.5), (x + 1.5, y + 6, z + 1.5), lambda p: p["collide"])
        if over:
            problems.append("pad (%.1f, %.1f): no headroom (%s)" % (x, z, over[0]["name"]))
        for name, (cx, cy, cz) in zip(chest_names, chests):
            if math.hypot(cx - x, cz - z) < PAD_CHEST:
                problems.append("pad (%.1f, %.1f) within %.0f of chest %s" % (x, z, PAD_CHEST, name))
        for name, b in zip(bay_names, bays):
            if math.hypot(b[0] - x, b[2] - z) < PAD_BAY:
                problems.append("pad (%.1f, %.1f) within %.0f of %s" % (x, z, PAD_BAY, name))
    log("pads: %d" % len(pads))

    # chests
    for name, (x, y, z) in zip(chest_names, chests):
        floor = top_under(parts, x, z, y + 4, lambda p: p["query"])
        if floor is None or abs(floor - y) > 0.06:
            problems.append("chest %s: floor at %s, spot at %.2f" % (name, floor, y))
        inside = hits_box(parts, (x - CHEST_CLEAR, y + 0.2, z - CHEST_CLEAR), (x + CHEST_CLEAR, y + 3.5, z + CHEST_CLEAR),
                          lambda p: p["collide"])
        if inside:
            problems.append("chest %s: not clear (%s)" % (name, ", ".join(sorted({p["name"] for p in inside}))))
    log("chest spots: %d (%s)" % (len(chests), ", ".join(chest_names)))

    # loot
    for x, y, z in loot:
        floor = top_under(parts, x, z, y + 4, lambda p: p["query"])
        if floor is None or abs(floor - y) > 0.06:
            problems.append("loot (%.1f, %.1f): floor at %s, spot at %.2f" % (x, z, floor, y))
        if any(math.hypot(px - x, pz - z) < PAD_LOOT for px, _, pz in pads):
            problems.append("loot (%.1f, %.1f) within %.0f of a pad" % (x, z, PAD_LOOT))
        if any(math.hypot(cx - x, cz - z) < CHEST_LOOT for cx, _, cz in chests):
            problems.append("loot (%.1f, %.1f) within %.0f of a chest" % (x, z, CHEST_LOOT))
        for b in bays:
            if abs(x - b[0]) < CAR[0] / 2 + 0.5 and abs(z - b[2]) < CAR[1] / 2 + 0.5:
                problems.append("loot (%.1f, %.1f) in a bay" % (x, z))
    log("loot spots: %d" % len(loot))

    # bays
    for name, b in zip(bay_names, bays):
        x, y, z = b[0], b[1], b[2]
        look = (-b[9], -b[10], -b[11])
        if not (abs(look[0]) < 1e-6 and abs(look[2] + 1) < 1e-6):
            problems.append("%s does not face the gate (look %s)" % (name, look))
        hx, hz = CAR[0] / 2, CAR[1] / 2
        heights = []
        for fx, fz in ((1, 1), (-1, 1), (1, -1), (-1, -1), (1, 0), (-1, 0), (0, 1), (0, -1)):
            heights.append(top_under(parts, x + fx * hx, z + fz * hz, y + 24, lambda p: p["query"]))
        if None in heights or max(heights) - min(heights) > FOOTING_TOLERANCE or abs(max(heights) - y) > 0.06:
            problems.append("%s: footing %s, bay at %.2f" % (name, heights, y))
        over = hits_box(parts, (x - hx, y + 0.6, z - hz), (x + hx, y + 40, z + hz), lambda p: p["query"])
        if over:
            problems.append("%s: queryable over the bay (%s)" % (name, ", ".join(sorted({p["name"] for p in over}))))
        way = hits_box(parts, (x - CORRIDOR_HALF, y + 0.6, -62), (x + CORRIDOR_HALF, y + CORRIDOR_HEIGHT, z + hz),
                       lambda p: p["collide"])
        if way:
            problems.append("%s: drive-out blocked by %s" % (name, ", ".join(sorted({p["name"] for p in way}))))
    log("bays: %d (%s)" % (len(bays), ", ".join(bay_names)))

    # walk
    walk = Walk(parts)
    starts = [(x, z) for x, _, z in pads]
    stuck = [s for s in starts if not walk.ok(*walk.cell(*s))]
    for s in stuck:
        problems.append("walk: a body cannot stand on the pad at %s" % (s,))
    seen = walk.flood(starts)
    targets = [("chest " + n, c[0], c[2]) for n, c in zip(chest_names, chests)]
    targets += [(n, b[0], b[2]) for n, b in zip(bay_names, bays)]
    targets += [("front breach", -20.5, -48), ("gate", 24, -48), ("west breach", -51, -6.5), ("east gap", 51, 17.5)]
    unreached = [t[0] for t in targets if not walk.reached(seen, t[1], t[2])]
    log("walk: %d cells reached from %d pads; %d targets, %d unreached" % (len(seen), len(starts), len(targets), len(unreached)))
    problems += ["walk: cannot reach " + t for t in unreached]
    return problems


def check_zfight(build, model, log):
    z = build.zfight
    lua = build.lua
    roots = lua.table_from([model])
    before = z.Scan(roots, z.Tolerance)
    wide = z.Scan(roots, z.FixTolerance)
    stats = z.Fix(roots)
    after = z.Scan(roots, z.Tolerance)
    problems = []
    log("zfight: at source %d fighting (%d within Fix's wider tolerance); Fix moved %d, resized %d; after %d"
        % (len(before), len(wide), stats.moved, stats.resized, len(after)))
    if len(wide) and not len(before):
        lines = z.Describe(wide, None, 12)
        if isinstance(lines, tuple):
            lines = lines[0]
        for i in range(1, len(lines) + 1):
            log("  (Fix's margin only) " + lines[i])
    for label, pairs in (("at source", before), ("after the pass", after)):
        if len(pairs):
            lines = z.Describe(pairs, None, 6)
            if isinstance(lines, tuple):
                lines = lines[0]
            for i in range(1, len(lines) + 1):
                problems.append("zfight %s: %s" % (label, lines[i]))
    return problems


def check_destruct(build, model, parts_by_order, log):
    lua = build.lua
    service = build.destruct()
    map_folder = lua.eval('Instance.new("Folder")')
    map_folder.Name = "Map"
    map_folder.Parent = lua.globals().workspace
    model.Parent = map_folder
    live = [p for p in model.GetDescendants(model).values() if p.IsA(p, "BasePart")]
    problems = []
    breakable, required = 0, 0
    never_names = {"Foundation", "Paving", "Pillar", "RoofBeam", "GatePost", "Gantry", "Rubble"}
    # The spawn shelter is whichever room holds the pads, whatever it is called.
    top_of = lua.globals().topOf
    shelter = None
    for part in live:
        if part.Name == "TeamPad":
            shelter = top_of(part, model)
    if shelter is None:
        problems.append("destruct: no room holds the pads")

    def must_break(part, top):
        if not part.CanCollide or part.Name in never_names:
            return False
        if top in ("Perimeter", "Ruin"):
            return True
        if top == "SupplyRoom":
            # the brick infill: 2 thick on the frame's lines
            c, size = part.CFrame.p, part.Size
            on_line = (abs(c.Z - 23) < 0.01 or abs(c.Z - 40.8) < 0.01) and abs(size.Z - 2) < 0.01 \
                or abs(c.X - 44.8) < 0.01 and abs(size.X - 2) < 0.01
            return on_line
        return False

    for part in live:
        can = service.FromPart(part) is not None
        top = top_of(part, model)
        if can:
            breakable += 1
        if must_break(part, top):
            required += 1
            if not can:
                problems.append("destruct: %s in %s does not break" % (part.Name, top))
        if can and (top == shelter or part.Name in never_names):
            problems.append("destruct: %s (%s) breaks, and must not" % (part.Name, top))
    # tagged pools stay under DestructibleService's MAX_POOL_SPAN
    pools = {}
    for p in parts_by_order:
        tag = p["tag"]
        if ":" in tag:
            pools.setdefault((p["path"], tag), []).append(p)
    for (path, tag), members in pools.items():
        lo = [min(m["aabb"][0][i] for m in members) for i in range(3)]
        hi = [max(m["aabb"][1][i] for m in members) for i in range(3)]
        if max(hi[0] - lo[0], hi[2] - lo[2]) > 90:
            problems.append("destruct: pool %s spans more than 90" % tag)
    log("destruct: %d parts examined, %d breakable, %d wall panels that must break, %d tagged pools"
        % (len(live), breakable, required, len(pools)))
    if required < 20:
        problems.append("destruct: only %d wall panels found to check" % required)
    model.Parent = None
    return problems


def local_rows(parts, frame_pos, yaw):
    """Every part's frame taken back into the base's own frame (inverse of a yaw + a move)."""
    c, s = math.cos(yaw), math.sin(yaw)
    out = []
    for p in parts:
        d = [p["pos"][i] - frame_pos[i] for i in range(3)]
        # inverse of ry(yaw): x' = c*x - s*z, z' = s*x + c*z
        def back(v):
            return (c * v[0] - s * v[2], v[1], s * v[0] + c * v[2])
        out.append((p["name"], p["cls"], p["size"], back(d), tuple(back(a) for a in p["axes"]), p["color"]))
    return out


def same_rows(a, b, tol=1e-5):
    if len(a) != len(b):
        return ["part counts differ: %d vs %d" % (len(a), len(b))]
    problems = []
    for ra, rb in zip(a, b):
        if ra[0] != rb[0] or ra[1] != rb[1]:
            problems.append("different part: %s vs %s" % (ra[0], rb[0]))
        elif any(abs(x - y) > tol for x, y in zip(ra[2], rb[2])) or any(abs(x - y) > tol for x, y in zip(ra[3], rb[3])) \
                or any(abs(x - y) > tol for u, v in zip(ra[4], rb[4]) for x, y in zip(u, v)):
            problems.append("%s differs in place or size" % ra[0])
        if len(problems) > 5:
            break
    return problems


TEAM1, TEAM2 = (255, 112, 36), (40, 196, 190)
SEED = 20260924


SMOKE = r"""
function smoke(Ruins, flat)
    local out = {}
    local function fail(msg) table.insert(out, msg) end
    local ws = Instance.new("Workspace")
    workspace = ws
    local terrain = Instance.new("Terrain")
    rawget(ws, "props").Terrain = terrain
    local map = Instance.new("Folder")
    map.Name = "Map"
    map.Parent = ws
    local function item(folderName, name, extents)
        local folder = map:FindFirstChild(folderName)
        if not folder then
            folder = Instance.new("Model")
            folder.Name = folderName
            folder.Parent = map
        end
        local model = Instance.new("Model")
        model.Name = name
        rawget(model, "props").Extents = extents
        model.Parent = folder
        local part = Instance.new("Part")
        part.Name = name .. "Part"
        part.Size = Vector3.new(2, 2, 2)
        part.CFrame = CFrame.new(0, 0, 0)
        part.Parent = model
        return model, part
    end
    local tree, treePart = item("Props", "Tree", Vector3.new(8, 20, 8))
    local tower, towerPart = item("Landmarks", "Tower", Vector3.new(120, 60, 90))
    local road, roadPart = item("Roads", "Segment", Vector3.new(10, 1, 10))
    local loot = Instance.new("Folder")
    loot.Name = "Loot"
    loot.Parent = ws
    local pickup = Instance.new("Part")
    pickup.Name = "GroundWeapon"
    pickup.Parent = loot
    function ws:GetPartBoundsInBox() return { treePart, towerPart, roadPart, pickup } end
    function ws:Raycast() return nil end
    OverlapParams = { new = function() return {} end }
    RaycastParams = { new = function() return {} end }
    MODULES.MapTerrain.FlattenPad = function() if flat then return 12.5 end return nil, "road" end
    MODULES.MapTerrain.PadCost = function() return 8, 14, 11 end
    local base = CFrame.new(100, 3, -50) * CFrame.Angles(0, 0.7, 0)
    local info = Ruins.Build(base, Color3.fromRGB(255, 112, 36), { map = map }, 42)
    if info.model.Parent ~= map then fail("the compound is not in the map") end
    if tree.Parent then fail("the tree on the site was left standing") end
    if pickup.Parent then fail("loot on the site was left lying") end
    if not tower.Parent then fail("a landmark too big to clear was removed") end
    if not road.Parent then fail("a road piece was removed") end
    local want = flat and 12.5 or 14
    if math.abs(info.height - want) > 1e-6 then fail(("stands at %.2f, want %.2f"):format(info.height, want)) end
    local frame = CFrame.new(100, want, -50) * CFrame.Angles(0, 0.7, 0)
    local _, laid = Ruins.Layout(frame, Color3.fromRGB(255, 112, 36), 42)
    for i, pad in ipairs(info.pads) do
        local w = laid.pads[i].p
        local d = pad.p - w
        if d.Magnitude > 1e-6 then fail("pad " .. i .. " is not where Layout puts it in the site's frame") break end
    end
    local plinth = nil
    for _, child in ipairs(info.model:GetChildren()) do
        if child.Name == "Foundation" and child.ClassName == "Part" then plinth = child end
    end
    if flat and plinth then fail("a plinth on levelled ground") end
    if not flat then
        if not plinth then
            fail("no plinth where the ground could not be levelled")
        else
            local bottom = plinth.CFrame.p.Y - plinth.Size.Y / 2
            local top = plinth.CFrame.p.Y + plinth.Size.Y / 2
            if bottom > 8 then fail(("plinth stops at %.2f, above the lowest ground 8"):format(bottom)) end
            if top < 14 - 0.7 or top > 14 then fail(("plinth top %.2f is not under the paving"):format(top)) end
        end
    end
    local unmarked = 0
    for _, part in ipairs(info.model:GetDescendants()) do
        if part:IsA("BasePart") and not part:GetAttribute("TeamBaseRuin") then unmarked = unmarked + 1 end
    end
    if unmarked > 0 then fail(unmarked .. " parts not marked TeamBaseRuin") end
    workspace = nil
    return out
end
"""


def check_build(src, log):
    problems = []
    for flat in (True, False):
        b = Build(src)
        b.lua.execute(SMOKE)
        found = b.lua.globals().smoke(b.ruins, flat)
        lines = [found[i] for i in range(1, len(found) + 1)]
        problems += ["build (%s): %s" % ("levelled" if flat else "plinth", line) for line in lines]
    log("build: levelled and plinth sites, %d problems" % len(problems))
    return problems


def run(src, log):
    problems = []
    build = Build(src)
    frame, model, info = build.layout(0, 0, 0, 0, TEAM1, SEED)
    zproblems = check_zfight(build, model, log)
    problems += zproblems
    parts = build.dump(model)
    for p in parts:
        p["aabb"] = aabb(p)
    problems += check_all(build, frame, model, info, parts, log)
    problems += check_destruct(build, model, parts, log)
    lights, shadows = build.lua.globals().countLights(model)
    log("lights: %d PointLights, %d with shadows" % (lights, shadows))

    # identical: the other team's base, turned and moved, with the other colour, the same seed
    other = Build(src)
    yaw2 = math.pi + 0.37
    _, model2, info2 = other.layout(512.5, 7.25, -300.0, yaw2, TEAM2, SEED)
    other.zfight.Fix(other.lua.table_from([model2]))
    parts2 = other.dump(model2)
    a = local_rows(parts, (0, 0, 0), 0)
    b = local_rows(parts2, (512.5, 7.25, -300.0), yaw2)
    diff = same_rows(a, b)
    recolored = [ra[0] for ra, rb in zip(a, b) if any(abs(x - y) > 1e-6 for x, y in zip(ra[5], rb[5]))]
    stray = sorted({n for n in recolored if not n.startswith("Team")})
    team_parts = [ra[0] for ra in a if ra[0].startswith("Team")]
    unpainted = len(team_parts) - len([n for n in recolored if n.startswith("Team")])
    log("identical: %d parts compared in their own frames, %d differ in place, %d recoloured (%d Team* parts)"
        % (len(a), len(diff), len(recolored), len(team_parts)))
    problems += ["identical: " + d for d in diff]
    if stray:
        problems.append("identical: colour differs on non-team parts %s" % stray[:6])
    if unpainted:
        problems.append("identical: %d Team* parts do not take the team colour" % unpainted)
    for key in ("pads", "chestSpots", "vehicleBays"):
        la, lb = build.cfs(info[key]), other.cfs(info2[key])
        if len(la) != len(lb):
            problems.append("identical: %s count %d vs %d" % (key, len(la), len(lb)))

    # seed: the same seed twice
    again = Build(src)
    _, model3, _ = again.layout(0, 0, 0, 0, TEAM1, SEED)
    again.zfight.Fix(again.lua.table_from([model3]))
    rows3 = local_rows(again.dump(model3), (0, 0, 0), 0)
    rediff = same_rows(a, rows3)
    log("seed: rebuilt with the same seed, %d parts differ" % len(rediff))
    problems += ["seed: " + d for d in rediff]
    problems += check_build(src, log)
    return problems


# Each aims at a rule the build must keep forever.
PLANTS = [
    ("coplanar plates", [("local PROUD_BRICK, PROUD_PAINT, PROUD_SOOT = 0.12, 0.2, 0.28",
                          "local PROUD_BRICK, PROUD_PAINT, PROUD_SOOT = 0.2, 0.2, 0.28")], "zfight"),
    ("lamp off its post", [('box(gate, "GateLamp", 2.6, 4.2, 9.4, 10.4, -39.8, -38.9',
                            'box(gate, "GateLamp", 2.6, 4.2, 9.4, 10.4, -39.5, -38.6'),
                           ('box(gate, "GateLampGlass", 2.8, 4.0, 9.55, 10.25, -38.9, -38.75',
                            'box(gate, "GateLampGlass", 2.8, 4.0, 9.55, 10.25, -38.6, -38.45')], "floating"),
    ("dish sized (d, t, d)", [('put(bunker, "Dish", Vector3.new(0.35, 4.2, 4.2)', 'put(bunker, "Dish", Vector3.new(4.2, 0.35, 4.2)')],
     "cylinder"),
    ("doorway narrowed", [("wall(-9, -4, BUNKER_TOP, 8, 10)", "wall(-12.5, -4, BUNKER_TOP, 8, 10)")], "doorway"),
    ("supply sealed off", [('	table.insert(B.doorways, { name = "SupplyDoor"',
                            '	sandbags(room, "plantA", 19, 21, 28, 21, 3, TILE_TOP)\n'
                            '	sandbags(room, "plantB", 5.3, 27, 5.3, 36, 3, ROOM_FLOOR)\n'
                            '	table.insert(B.doorways, { name = "SupplyDoor"')], "walk: cannot reach chest Supply"),
    ("tyres in bay 2's way", [('tyres(18.75, -24, 3, "tyresA")', 'tyres(25, -24, 3, "tyresA")')], "drive-out"),
    ("queryable camo net", [("local netOpts = trimWith({ transparency = 0.12 })", "local netOpts = { transparency = 0.12 }")],
     "queryable over the bay"),
    ("spawn shelter breakable", [('bunker.Name = "Spawn"\n\tbunker:SetAttribute("Destructible", false)',
                                  'bunker.Name = "Bunker"'),
                                 ('return box(bunker, "BunkerWall", x0, x1, -1, y1, z0, z1, color or BUNKER, MAT.Concrete, never)',
                                  'return box(bunker, "Wall", x0, x1, -1, y1, z0, z1, color or BUNKER, MAT.Concrete)')],
     "breaks, and must not"),
    ("perimeter unbreakable", [('local name = style.name or "Wall"', 'local name = style.name or "PerimeterWall"')],
     "does not break"),
    ("layout depends on the team", [("tops[index] = rnd(6.6, 9.4)", "tops[index] = rnd(6.6, 9.4) + (B.team.R > 0.5 and 0.3 or 0)")],
     "identical"),
    ("unseeded wear", [("rng = Random.new(seed or 1),", "rng = Random.new((seed or 1) + math.random(1, 100000)),")], "seed"),
    ("over budget", [("paving(ground, -44.2, 4, -40.2, 8, 4, 4,", "paving(ground, -44.2, 4, -40.2, 8, 16, 16,")], "budget"),
    ("scenery left on the site", [("if span <= TeamBaseRuins.ClearableSpan then", "if false then")], "build (levelled): the tree"),
    ("no plinth on a refused site", [("if plinthBottom and height - plinthBottom > 0.2 then", "if false then")], "build (plinth): no plinth"),
    ("built at the asked height", [("local frame = CFrame.new(position.X, height, position.Z) * CFrame.Angles(0, yaw, 0)",
                                    "local frame = CFrame.new(position.X, position.Y, position.Z) * CFrame.Angles(0, yaw, 0)")],
     "build (levelled): pad 1 is not where"),
    ("crate on a chest spot", [('	table.insert(B.chests, { name = "LeanTo"',
                                '	box(yard, "Crate", -42, -39.6, TILE_TOP, TILE_TOP + 2.4, -23, -21, WOOD, MAT.WoodPlanks)\n'
                                '	table.insert(B.chests, { name = "LeanTo"')], "chest LeanTo: not clear"),
]


def main(argv):
    repo = argv[1] if len(argv) > 1 and not argv[1].startswith("--") else "."
    plant = "--plant" in argv
    src = sources(repo)
    problems = run(src, print)
    for line in problems:
        print("  FAIL " + line)
    print("team_base_ruins_check: %d problems" % len(problems))
    ok = not problems
    if plant:
        for label, edits, expect in PLANTS:
            planted = dict(src)
            text = src["ruins"]
            anchored = True
            for old, new in edits:
                if old not in text:
                    print("plant %s: anchor moved (%s...)" % (label, old[:50]))
                    anchored = False
                    break
                text = text.replace(old, new, 1)
            if not anchored:
                ok = False
                continue
            planted["ruins"] = text
            try:
                found = run(planted, lambda *_: None)
            except Exception as error:  # a crash is not a catch
                found = []
                print("plant %s: crashed: %s" % (label, str(error).splitlines()[0]))
            caught = any(expect in line for line in found)
            ok &= caught
            print("plant %-28s %s%s" % (label + ":", "caught" if caught else "MISSED",
                                       "" if caught else "  (%d other problems: %s)" % (len(found), found[:2])))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
