"""The team-base ruins (TeamBaseRuins.lua), checked without Studio.

Runs the REAL ServerScriptService/Modules/TeamBaseRuins.lua (its Layout, the whole geometry), the real
ReplicatedStorage/Shared/ZFight.lua and the real ServerScriptService/Modules/DestructibleService.lua
under the lupa mock from tools/vehicle_models_axis_check.py (extended here with Random, Color3 maths,
TrussPart and Roblox's part defaults), then measures what was built:

  budget     760..1450 parts per base (said, with the count per room)
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
  build      TeamBaseRuins.Build itself, on a mock hillside whose terrain RAYS are stale (they report
             the ground as it was before any write, as a real one does straight after WriteVoxels)
             and whose voxels are true: it clears the small scenery and the loot off the site and
             keeps the big things and the roads, stands FLUSH at the height FlattenPad returns (no
             plinth), grades the ground round it (no step the work made steeper than 1 in 3, the
             gate ramps 1 in 8 along their middles, the ground under a road untouched), takes away
             the scenery left on moved ground, and refuses a site FlattenPad refuses or that did not
             come out level; the pads come out where Layout put them in the site's frame

Planted faults (source edits, rebuilt through the same pipeline) must each be caught:
    python3 tools/team_base_ruins_check.py [repo]            the checks
    python3 tools/team_base_ruins_check.py [repo] --plant    and the planted faults
      --quick skips the 24-seed sweep, --only TEXT plants only the faults whose label has TEXT
"""

import math
import re
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK, luau_to_lua  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

# 760 -> 1450 with the compound's area (92 x 84 -> 134 x 110, x1.91), sized for 25 a side.
BUDGET = (760, 1450)
BODY_RADIUS, BODY_HEIGHT, STEP = 1.0, 5.2, 1.5
GRID = 0.5
# The flat pad round the compound (its footprint and margin), and how far past its middle every bay's
# way out is kept clear: read from TeamBaseRuins' WX, WZ at start (main).
FLAT_X, FLAT_Z = 50.0, 46.0
DOOR_WIDTH, DOOR_HEIGHT = 4.0, 7.0
CHEST_CLEAR = 2.4
PAD_CHEST, PAD_BAY, PAD_LOOT, CHEST_LOOT = 7.0, 18.0, 6.0, 3.0
# A bay must take the BIGGEST vehicle there is, with half a stud all round: its width and length, and
# the height its way out must be clear to, are measured from VehicleModels' real builds at start
# (vehicle_extents, tools/team_base_ruins_modeteams_check.py). These are the floor if that fails.
CAR = (8.9, 16.6)
CORRIDOR_HALF, CORRIDOR_HEIGHT = 4.8, 7.5
CAR_MARGIN = 0.5
# Past the compound's middle, along a bay's nose, that its way out must stay clear to: beyond every
# wall (they stand at 41 and 45).
DRIVE_OUT = 62
# The lane each bay drives out along: the biggest vehicle's width and this much more (Oliver, 2026-09-24).
LANE_SPARE = 6.0
# One bay per base vehicle (MatchConfig.TeamBaseVehicles.Slots, read from the source).
BAYS = None
# One named chest spot per base chest (LootService.BaseStock.chest, read from the source): GameMode
# stocks and refills that many, and ModeTeams puts chests only in the compound's spots.
CHESTS = None
FOOTING_TOLERANCE = 0.5
TOUCH = 0.12
# Trim whose underside is lower than this lies on the pad through whatever floor it is painted on.
TILE_GROUND = 0.6

EXTRA_MOCK = r"""
-- Roblox's part defaults, TrussPart, Random, Color3 maths, script, warn.
PARTS_EXTRA = true
local baseNew = Instance.new
local PART_CLASSES = { Part = true, WedgePart = true, TrussPart = true }
Instance.new = function(class)
    local inst = baseNew(class)
    -- DestructibleService drops its per-instance caches on Destroying (since pc/destruction).
    local p0 = rawget(inst, "props")
    if p0 and p0.Destroying == nil then
        p0.Destroying = { Connect = function() return { Disconnect = function() end } end }
    end
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
RaycastParams = { new = function() return {} end }
OverlapParams = { new = function() return {} end }
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
function pooledModel(part, model)
    local node = part.Parent
    while node and node ~= model do
        if node.ClassName == "Model" and type(node:GetAttribute("Destructible")) == "string" then
            return node.Name
        end
        node = node.Parent
    end
    return ""
end
function makeFrame(x, y, z, yaw)
    return CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0)
end
"""


def chest_stock(repo):
    text = (Path(repo) / "ServerScriptService/Modules/LootService.lua").read_text()
    return int(re.search(r"LootService\.BaseStock = \{[^}]*chest = (\d+)", text).group(1))


def slot_count(repo):
    text = (Path(repo) / "ReplicatedStorage/Shared/MatchConfig.lua").read_text()
    block = text[text.index("MatchConfig.TeamBaseVehicles = {"):]
    slots = re.search(r"Slots = \{([^}]*)\}", block).group(1)
    return len(re.findall(r'"\w+"', slots))


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
            # DestructibleService hooks RunService.Heartbeat at load (its rescue sweep, since the
            # pc/destruction merge); the shared mock's services have no signals, so give them one.
            self.lua.execute("""
                local get = game.GetService
                game.GetService = function(self, name)
                    local s = get(self, name)
                    if type(s) == "table" and s.Heartbeat == nil then
                        s.Heartbeat = { Connect = function() return { Disconnect = function() end } end }
                        s.GetPlayers = s.GetPlayers or function() return {} end
                        s.GetPlayerFromCharacter = s.GetPlayerFromCharacter or function() return nil end
                    end
                    return s
                end
            """)
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


def hits_obb(parts, centre, axes, half, want):
    """Parts passing `want` whose OBB meets the given box."""
    probe = (centre, axes, half)
    ext = [sum(abs(axes[k][i]) * half[k] for k in range(3)) for i in range(3)]
    lo = [centre[i] - ext[i] for i in range(3)]
    hi = [centre[i] + ext[i] for i in range(3)]
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
        self.x0, self.z0 = -(FLAT_X + 6), -(FLAT_Z + 6)
        self.nx, self.nz = int(2 * (FLAT_X + 6) / GRID) + 1, int(2 * (FLAT_Z + 6) / GRID) + 1
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
    if CHESTS is not None and len(chests) != CHESTS:
        problems.append("chest spots: %d, but LootService.BaseStock.chest is %d" % (len(chests), CHESTS))

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
            dx, dz = x - b[0], z - b[2]
            across = abs(dx * b[3] + dz * b[5])
            along = abs(dx * b[9] + dz * b[11])
            if across < CAR[0] / 2 + 0.5 and along < CAR[1] / 2 + 0.5:
                problems.append("loot (%.1f, %.1f) in a bay" % (x, z))
    log("loot spots: %d" % len(loot))

    # bays, each in its own heading: level footing, nothing queryable over it, and a straight way out
    # along its nose from the car's tail to DRIVE_OUT studs past the compound's middle -- which is out
    # through a gate or it hits a wall. Bays must not overlap one another.
    hx, hz = CAR[0] / 2, CAR[1] / 2
    frames = []
    lanes = []
    for name, b in zip(bay_names, bays):
        x, y, z = b[0], b[1], b[2]
        look = (-b[9], 0.0, -b[11])
        side = (b[3], 0.0, b[5])
        frames.append((x, z, look, side))
        if abs(b[10]) > 1e-6 or abs(math.hypot(look[0], look[2]) - 1) > 1e-6:
            problems.append("%s is not level (look %s)" % (name, look))
        heights = []
        for fx, fz in ((1, 1), (-1, 1), (1, -1), (-1, -1), (1, 0), (-1, 0), (0, 1), (0, -1)):
            px = x + side[0] * fx * hx + look[0] * fz * hz
            pz = z + side[2] * fx * hx + look[2] * fz * hz
            heights.append(top_under(parts, px, pz, y + 24, lambda p: p["query"]))
        if None in heights or max(heights) - min(heights) > FOOTING_TOLERANCE or abs(max(heights) - y) > 0.06:
            problems.append("%s: footing %s, bay at %.2f" % (name, heights, y))
        axes = (side, (0.0, 1.0, 0.0), look)
        over = hits_obb(parts, (x, y + 20.3, z), axes, (hx, 19.7, hz), lambda p: p["query"])
        if over:
            problems.append("%s: queryable over the bay (%s)" % (name, ", ".join(sorted({p["name"] for p in over}))))
        # from the tail (-hz) to DRIVE_OUT past the middle, measured along the nose
        reach = DRIVE_OUT - (x * look[0] + z * look[2])
        length = reach + hz
        mid = (reach - hz) / 2
        centre = (x + look[0] * mid, y + (0.6 + CORRIDOR_HEIGHT) / 2, z + look[2] * mid)
        way = hits_obb(parts, centre, axes, (CORRIDOR_HALF, (CORRIDOR_HEIGHT - 0.6) / 2, length / 2), lambda p: p["collide"])
        # A chest there would be in the car's way out (or under it): none may be.
        lane = (centre, axes, (CORRIDOR_HALF, (CORRIDOR_HEIGHT - 0.6) / 2, length / 2))
        for cname, (cx, cy, cz) in zip(chest_names, chests):
            chest_box = ((cx, cy + 1.85, cz), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (CHEST_CLEAR, 1.65, CHEST_CLEAR))
            if obb_overlap(lane, chest_box):
                problems.append("chest %s is in %s's way out" % (cname, name))
        if way:
            problems.append("%s: drive-out blocked by %s" % (name, ", ".join(sorted({p["name"] for p in way}))))
        lanes.append((name, lane))
    # No parked neighbour stands in a bay's lane either: every other bay's car box is clear of it.
    for name, lane in lanes:
        for other, b in zip(bay_names, bays):
            if other == name:
                continue
            ox, oz = b[0], b[2]
            car = ((ox, b[1] + 3, oz), ((b[3], 0.0, b[5]), (0.0, 1.0, 0.0), (-b[9], 0.0, -b[11])), (CAR[0] / 2, 2.5, CAR[1] / 2))
            if obb_overlap(lane, car):
                problems.append("%s: drive-out blocked by the car parked in %s" % (name, other))
    for i in range(len(frames)):
        for j in range(i + 1, len(frames)):
            a, b2 = frames[i], frames[j]
            box_a = ((a[0], 0, a[1]), (a[3], (0, 1, 0), a[2]), (hx, 1, hz))
            box_b = ((b2[0], 0, b2[1]), (b2[3], (0, 1, 0), b2[2]), (hx, 1, hz))
            if obb_overlap(box_a, box_b):
                problems.append("%s and %s overlap" % (bay_names[i], bay_names[j]))
    log("bays: %d (%s)" % (len(bays), ", ".join(bay_names)))
    if len(bays) != BAYS:
        problems.append("bays: %d, want %d (MatchConfig.TeamBaseVehicles slots)" % (len(bays), BAYS))

    # walk
    walk = Walk(parts)
    starts = [(x, z) for x, _, z in pads]
    stuck = [s for s in starts if not walk.ok(*walk.cell(*s))]
    for s in stuck:
        problems.append("walk: a body cannot stand on the pad at %s" % (s,))
    seen = walk.flood(starts)
    targets = [("chest " + n, c[0], c[2]) for n, c in zip(chest_names, chests)]
    targets += [(n, b[0], b[2]) for n, b in zip(bay_names, bays)]
    exits = info["exits"]
    for i in range(1, len(exits) + 1):
        targets.append((exits[i]["name"], exits[i]["x"], exits[i]["z"]))
    if len(exits) < 3:
        problems.append("walk: only %d ways out of the compound" % len(exits))
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
    # Oliver, 2026-09-24: everything breaks except spawns, the lobby, the storm and the map edges.
    # In a base that leaves the spawn shelter (the Model named "Spawn") and nothing else.
    never_names = set()
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
        # Every wall panel outside the spawn shelter: the perimeter's, the armoury's, the ops room's.
        return top != shelter and (part.Name == "Wall" or (top == "Perimeter" and part.Name.endswith("Wall")))

    flags = []
    for part in live:
        can = service.FromPart(part) is not None
        flags.append(can)
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
    # Dressing left hanging: a piece of trim (no collision, no query) that touches only parts which can
    # break must go with them -- by being a wall's dressing (DestructibleService drops it), by sharing
    # the pool's tag, or by being inside the same tagged Model. A crate band that is not in its crate's
    # pool floats when the crate goes.
    pooled = lua.globals().pooledModel
    pool_model = [pooled(p, model) for p in live]
    carries = {"Wall", "Floor", "Roof", "Gable", "Parapet", "Stair", "Balcony"}
    boxes = [obb(p) for p in parts_by_order]
    hanging, trims = [], 0
    for i, t in enumerate(parts_by_order):
        if t["collide"] or t["query"]:
            continue
        lo, hi = t["aabb"]
        touching = []
        for j, c in enumerate(parts_by_order):
            if not c["collide"]:
                continue
            clo, chi = c["aabb"]
            if any(lo[k] > chi[k] + TOUCH or clo[k] > hi[k] + TOUCH for k in range(3)):
                continue
            if obb_overlap(boxes[i], boxes[j], TOUCH):
                touching.append(j)
        if not touching:
            continue
        trims += 1
        # Paint on the paving (bay lines, stains, numbers) lies within a tile's depth of the pad: if
        # the tile goes it is left on the ground, not in the air.
        if lo[1] < TILE_GROUND:
            continue
        held = False
        for j in touching:
            c = parts_by_order[j]
            # DestructibleService.dropDressing walks a breaking part's siblings (any part since
            # pc/destruction, not only a building's walls) and takes the trim attached to it.
            if not flags[j] or (c["path"] == t["path"] and (c["name"] in carries or t["path"])) \
                    or (":" in c["tag"] and c["tag"] == t["tag"] and c["path"] == t["path"]) \
                    or (pool_model[j] and pool_model[j] == pool_model[i]):
                held = True
                break
        if not held:
            hanging.append("%s (on %s)" % (t["name"], ", ".join(sorted({parts_by_order[j]["name"] for j in touching}))))
    for line in hanging[:40]:
        problems.append("destruct: %s is left hanging when that breaks" % line)
    log("destruct: %d parts examined, %d breakable, %d wall panels that must break, %d tagged pools; "
        "%d pieces of dressing on something, %d left hanging when it breaks"
        % (len(live), breakable, required, len(pools), trims, len(hanging)))
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
-- THE GROUND. A voxel terrain over the natural ground T(x, z): ReadVoxels hands back each 4-stud column
-- filled to its ground (less MapTerrain's SurfaceLift), WriteVoxels keeps what was written, and every
-- later read sees it. Terrain RAYCASTS do not: they report T, the ground as it was before any write,
-- which is what a real terrain raycast straight after WriteVoxels does (measured in Studio: every plinth
-- the compounds ever stood on was a raycast reading a slope the pad had already levelled). So nothing
-- Build decides may rest on a terrain raycast, and this world proves it.
local CELL, LIFT = 4, 2
local function partTop(part, x, z, below)
    if part.CanQuery == false then return nil end
    local c, s = part.CFrame, part.Size
    local ex = math.abs(c.r.X) * s.X / 2 + math.abs(c.u.X) * s.Y / 2 + math.abs(c.b.X) * s.Z / 2
    local ey = math.abs(c.r.Y) * s.X / 2 + math.abs(c.u.Y) * s.Y / 2 + math.abs(c.b.Y) * s.Z / 2
    local ez = math.abs(c.r.Z) * s.X / 2 + math.abs(c.u.Z) * s.Y / 2 + math.abs(c.b.Z) * s.Z / 2
    if math.abs(x - c.p.X) > ex or math.abs(z - c.p.Z) > ez then return nil end
    local top = c.p.Y + ey
    if top > below then return nil end
    return top
end
CF.PointToObjectSpace = function(c, v) return c:Inverse() * v end
Region3 = {}
function Region3.new(a, b)
    local r = { min = a, max = b, Size = b - a, CFrame = CFrame.new((a + b) / 2) }
    function r:ExpandToGrid(res)
        local function lo(v) return math.floor(v / res + 1e-9) * res end
        local function hi(v) return math.ceil(v / res - 1e-9) * res end
        return Region3.new(Vector3.new(lo(a.X), lo(a.Y), lo(a.Z)), Vector3.new(hi(b.X), hi(b.Y), hi(b.Z)))
    end
    return r
end
function smoke(Ruins, mode)
    local out = {}
    local function fail(msg) table.insert(out, msg) end
    local ws = Instance.new("Workspace")
    workspace = ws
    local terrain = Instance.new("Terrain")
    rawget(ws, "props").Terrain = terrain
    local map = Instance.new("Folder")
    map.Name = "Map"
    map.Parent = ws
    local base = CFrame.new(100, 3, -50) * CFrame.Angles(0, 0.7, 0)
    local centre = base.p
    local site = CFrame.new(centre) * CFrame.Angles(0, 0.7, 0)
    local function localOf(x, z) return site:Inverse() * Vector3.new(x, centre.Y, z) end
    -- A hillside: level for 10 studs either side of the compound's middle, then climbing 1 in 4 toward
    -- its east (+X, the east gate's side) and falling as far to the west, levelling out 9.5 up and 9.5
    -- down: the east gate opens onto a bank 9.5 high at the pad's edge, the main gate's way out (-Z)
    -- crosses the slope.
    local function T(x, z)
        local here = localOf(x, z)
        local rise = math.clamp(here.X, -100, 100) - math.clamp(here.X, -62, 62)
        return 12.5 + 0.25 * rise + 0.1 * math.sin(x * 0.7) * math.cos(z * 0.9)
    end
    local written = {}
    local function key(x, z) return math.floor(x / CELL) .. "," .. math.floor(z / CELL) end
    local function ground(x, z)
        local w = written[key(x, z)]
        if w then return w end
        return T((math.floor(x / CELL) + 0.5) * CELL, (math.floor(z / CELL) + 0.5) * CELL)
    end
    rawget(terrain, "props").ReadVoxels = function(self, region, res)
        local nx, ny, nz = math.floor(region.Size.X / res + 0.5), math.floor(region.Size.Y / res + 0.5), math.floor(region.Size.Z / res + 0.5)
        local mats, occs = {}, {}
        for ix = 1, nx do
            mats[ix], occs[ix] = {}, {}
            local x = region.min.X + (ix - 0.5) * res
            for iy = 1, ny do
                mats[ix][iy], occs[ix][iy] = {}, {}
                local bottom = region.min.Y + (iy - 1) * res
                for iz = 1, nz do
                    local g = ground(x, region.min.Z + (iz - 0.5) * res)
                    local occ = math.max(0, math.min(1, (g - LIFT - bottom) / res))
                    occs[ix][iy][iz] = occ
                    mats[ix][iy][iz] = occ > 0 and "Enum.Material.Grass" or "Enum.Material.Air"
                end
            end
        end
        return mats, occs
    end
    rawget(terrain, "props").WriteVoxels = function(self, region, res, mats, occs)
        local nx, ny, nz = math.floor(region.Size.X / res + 0.5), math.floor(region.Size.Y / res + 0.5), math.floor(region.Size.Z / res + 0.5)
        for ix = 1, nx do
            local x = region.min.X + (ix - 0.5) * res
            for iz = 1, nz do
                local z = region.min.Z + (iz - 0.5) * res
                for iy = ny, 1, -1 do
                    if occs[ix][iy][iz] > 0 and mats[ix][iy][iz] ~= "Enum.Material.Air" then
                        written[key(x, z)] = region.min.Y + (iy - 1) * res + occs[ix][iy][iz] * res + LIFT
                        break
                    end
                end
            end
        end
    end
    function ws:Raycast(origin, dir, params)
        local best = nil
        local below = origin.Y
        for _, root in ipairs(params.FilterDescendantsInstances or {}) do
            if root == terrain then
                local y = T(origin.X, origin.Z)
                if y <= below and y >= below + dir.Y and (not best or y > best) then best = y end
            else
                local list = root:GetDescendants()
                table.insert(list, root)
                for _, part in ipairs(list) do
                    if part:IsA("BasePart") then
                        local y = partTop(part, origin.X, origin.Z, below)
                        if y and y >= below + dir.Y and (not best or y > best) then best = y end
                    end
                end
            end
        end
        return best and { Position = Vector3.new(origin.X, best, origin.Z) } or nil
    end
    local function item(folderName, name, extents, offset, tag, count, y)
        local folder = map:FindFirstChild(folderName)
        if not folder then
            folder = Instance.new("Model")
            folder.Name = folderName
            folder.Parent = map
        end
        local first
        for index = 1, count or 1 do
            local part = Instance.new("Part")
            part.Name = name
            part.Size = Vector3.new(2, 2, 2)
            part.CFrame = base * CFrame.new(offset.X, 0, offset.Z)
            if y then part.CFrame = CFrame.new(part.CFrame.p.X, y, part.CFrame.p.Z) end
            if tag then part:SetAttribute("Destructible", tag) end
            part.Parent = folder
            first = first or part
        end
        return first, folder
    end
    -- On the site: a tree inside the footprint, one just outside the margin where FlattenPad grades the
    -- ground, a two-piece tree (trunk and leaves, a tag group sharing Props with everything else), a
    -- landmark too big to clear, a road, and a loot pickup of two pieces.
    -- (The ones in the site stand where the hillside crosses the pad's height, so the ground under them
    -- does not move: it is ClearSite that must take them, not the clearing after the ground work.)
    local treeIn = item("Props", "TreeIn", nil, Vector3.new(0, 0, 10))
    local treeOut = item("Props", "TreeOut", nil, Vector3.new(0, 0, 60))
    local trunk = item("Props", "Trunk", nil, Vector3.new(0, 0, -20), "Tree:9")
    local leaves = item("Props", "Leaves", nil, Vector3.new(0, 0, -20), "Tree:9")
    local towerModel = Instance.new("Model")
    towerModel.Name = "Tower"
    rawget(towerModel, "props").Extents = Vector3.new(120, 60, 90)
    local lm = Instance.new("Model"); lm.Name = "Landmarks"; lm.Parent = map
    towerModel.Parent = lm
    local towerPart = Instance.new("Part"); towerPart.Size = Vector3.new(2, 2, 2); towerPart.CFrame = base; towerPart.Parent = towerModel
    local roadPart = item("Roads", "Segment", nil, Vector3.new(5, 0, 5))
    -- Round it, where the ground work reaches but ClearSite's box query never looks (none of them are in
    -- the query's list): flowers on the east bank (non-collidable, cut 17 studs down by the gate ramp), a
    -- tagged tree on the west bank (filled 14 up), a tree far out on untouched ground, and a road across
    -- the west slope whose ground must not move at all.
    local flowers = item("Wilds", "Flowers", nil, Vector3.new(96, 0, 20), nil, 1, T((base * Vector3.new(96, 0, 20)).X, (base * Vector3.new(96, 0, 20)).Z))
    flowers.CanCollide = false
    flowers.CanQuery = false
    local bankTree = item("Props", "BankTree", nil, Vector3.new(-92, 0, 20), "Tree:11")
    local farTree = item("Props", "FarTree", nil, Vector3.new(0, 0, 190), "Tree:12")
    local road = item("Roads", "RoadSurface", nil, Vector3.new(-101, 0, -60))
    road.Size = Vector3.new(18, 0.8, 60)
    local roadGround = {}
    for dz = -86, -34, 4 do
        local p = base * Vector3.new(-101, 0, dz)
        table.insert(roadGround, { p.X, p.Z, ground(p.X, p.Z) })
    end
    local loot = Instance.new("Folder")
    loot.Name = "Loot"
    loot.Parent = ws
    local pickup = Instance.new("Part")
    pickup.Name = "GroundWeapon"
    pickup.Parent = loot
    local gunPiece = Instance.new("Part")
    gunPiece.Name = "Gun"
    gunPiece.Parent = pickup
    function ws:GetPartBoundsInBox(cf, size)
        -- What lies in the box, piece by piece: the trunk but not its leaves, the gun but not its pad.
        local hits = {}
        local function inside(part)
            local d = cf:Inverse() * part.CFrame.p
            return math.abs(d.X) <= size.X / 2 and math.abs(d.Z) <= size.Z / 2
        end
        for _, part in ipairs({ treeIn, treeOut, trunk, towerPart, roadPart }) do
            if part.Parent and inside(part) then table.insert(hits, part) end
        end
        table.insert(hits, gunPiece)
        return hits
    end
    OverlapParams = { new = function() return {} end }
    RaycastParams = { new = function() return {} end }
    -- MapTerrain: the pad flattens the footprint, the margin and two columns past it at 12.5 ("partial":
    -- only 30 studs round the middle; "refused": nothing, a road in the way); PadCost reads the voxels.
    MODULES.MapTerrain.SurfaceLift = LIFT
    MODULES.MapTerrain._padGround = "Enum.Material.Ground"
    MODULES.MapTerrain.PadAt = function() return nil end
    MODULES.MapTerrain.InRiver = function() return false end
    MODULES.MapTerrain.FlattenPad = function(padSite, size, options)
        if mode == "refused" then return nil, "road" end
        for x = -80, 80, 2 do
            for z = -80, 80, 2 do
                local p = base * Vector3.new(x, 0, z)
                local cx, cz = (math.floor(p.X / CELL) + 0.5) * CELL, (math.floor(p.Z / CELL) + 0.5) * CELL
                local l = localOf(cx, cz)
                local flat = math.abs(l.X) <= size.X / 2 + options.margin + 8 and math.abs(l.Z) <= size.Z / 2 + options.margin + 8
                if mode == "partial" then flat = l.Magnitude <= 30 end
                if flat then written[key(cx, cz)] = 12.5 end
            end
        end
        return 12.5
    end
    MODULES.MapTerrain.PadCost = function(padSite, size, options)
        local low, high, total, n = math.huge, -math.huge, 0, 0
        for x = -size.X / 2 - options.margin, size.X / 2 + options.margin, 4 do
            for z = -size.Z / 2 - options.margin, size.Z / 2 + options.margin, 4 do
                local p = padSite * Vector3.new(x, 0, z)
                local g = ground(p.X, p.Z)
                low, high, total, n = math.min(low, g), math.max(high, g), total + g, n + 1
            end
        end
        return low, high, total / n
    end
    local info, why = Ruins.Build(base, Color3.fromRGB(255, 112, 36), { map = map }, 42)
    if mode == "partial" then
        if info then fail("built on ground that is not level (only 30 studs round the middle were levelled)") end
        if not tostring(why):find("not level") then fail("refused for " .. tostring(why) .. ", not the ground under it") end
        return out
    end
    if mode == "refused" then
        if info then fail("built on a site FlattenPad refused") end
        return out
    end
    if not info then fail("not built: " .. tostring(why)) return out end
    if info.model.Parent ~= map then fail("the compound is not in the map") end
    if treeIn.Parent then fail("a tree on the site was left standing") end
    if treeOut.Parent then fail("a tree where the ground is graded was left standing") end
    if leaves.Parent then fail("a tree's leaves were left when its trunk went") end
    if pickup.Parent then fail("a loot pickup on the site was left (only a piece of it went)") end
    if not towerModel.Parent then fail("a landmark too big to clear was removed") end
    if not roadPart.Parent then fail("a road piece was removed") end
    if not road.Parent then fail("the road across the west slope was removed") end
    if flowers.Parent then fail("scenery left where the ground moved: flowers on the east bank") end
    if bankTree.Parent then fail("scenery left where the ground moved: a tree on the west bank") end
    if not farTree.Parent then fail("a tree on ground the grading never touched was removed") end
    for _, g in ipairs(roadGround) do
        if math.abs(ground(g[1], g[2]) - g[3]) > 1e-6 then fail("the ground under a road was moved") break end
    end
    for _, child in ipairs(info.model:GetChildren()) do
        if child.Name == "Foundation" and child.ClassName == "Part" then fail("a plinth under a compound on levelled ground") end
    end
    if math.abs(info.frame.p.Y - 12.5) > 1e-6 then fail(("stands at %.2f, want 12.5"):format(info.frame.p.Y)) end

    -- FLUSH, AND THE GROUND ROUND IT. On the pad's flat, the ground at the floor's (the paving is 0.3
    -- over it). Off it, every step between neighbouring columns the grading moved is no steeper than its
    -- grade -- 1 in 3, or 1 in 8 where both are in a gate's corridor -- or than the hillside was (both
    -- columns clear of the road, where
    -- the pad and the road are too close to be met at a grade and the ground goes halfway).
    local function nearRoad(x, z)
        local c, s = road.CFrame, road.Size
        local ex = math.abs(c.r.X) * s.X / 2 + math.abs(c.u.X) * s.Y / 2 + math.abs(c.b.X) * s.Z / 2 + 40
        local ez = math.abs(c.r.Z) * s.X / 2 + math.abs(c.u.Z) * s.Y / 2 + math.abs(c.b.Z) * s.Z / 2 + 40
        return math.abs(x - c.p.X) <= ex and math.abs(z - c.p.Z) <= ez
    end
    local flatX, flatZ = Ruins.GateCorridors.flat.X, Ruins.GateCorridors.flat.Z
    local function corridor(l)
        local front, east = Ruins.GateCorridors.front, Ruins.GateCorridors.east
        return (l.Z < -flatZ and l.X >= front[1] and l.X <= front[2]) or (l.X > flatX and l.Z >= east[1] and l.Z <= east[2])
    end
    local worstFlat, worstStep, bank = 0, 0, 0
    local cx0, cz0 = math.floor(centre.X / CELL), math.floor(centre.Z / CELL)
    for i = -60, 60 do
        for k = -60, 60 do
            local x, z = (cx0 + i + 0.5) * CELL, (cz0 + k + 0.5) * CELL
            local l = localOf(x, z)
            local g = ground(x, z)
            if math.abs(l.X) <= flatX and math.abs(l.Z) <= flatZ then
                worstFlat = math.max(worstFlat, math.abs(g - 12.5))
            elseif not nearRoad(x, z) and Ruins.FlatDistance(l.X, l.Z) < Ruins.GradeReach - 16 then
                -- (Not the last 16 before the ring the work stops at, which it meets as it stands: where a
                -- hillside runs across a ramp's end, the ramp's flat section cannot match it there.)
                bank = math.max(bank, math.abs(g - 12.5))
                local moved = math.abs(g - T(x, z)) > 0.02
                for _, n in ipairs({ { CELL, 0 }, { 0, CELL } }) do
                    local x2, z2 = x + n[1], z + n[2]
                    local l2 = localOf(x2, z2)
                    if not nearRoad(x2, z2) and Ruins.FlatDistance(l2.X, l2.Z) < Ruins.GradeReach - 16
                        and (moved or math.abs(ground(x2, z2) - T(x2, z2)) > 0.02) then
                        -- (Never steeper than its grade, or than the hillside there already was.)
                        local grade = (corridor(l) and corridor(l2)) and 1 / Ruins.GradeGate or 1 / Ruins.GradeBank
                        local natural = math.abs(T(x2, z2) - T(x, z)) / CELL
                        worstStep = math.max(worstStep, math.abs(ground(x2, z2) - g) / CELL - math.max(grade, natural))
                    end
                end
            end
        end
    end
    if worstFlat > 0.05 then fail(("the ground under the compound and its margin is up to %.2f off the floor's"):format(worstFlat)) end
    if worstStep > 0.02 then fail(("bank: the graded ground climbs %.3f steeper than its grade between neighbouring columns"):format(worstStep)) end
    if bank < 5 then fail(("the hillside was not there to grade (the most off the floor round it is %.2f)"):format(bank)) end
    -- The gate ramps: the steepest step along each gate corridor's middle, and the banks beside the yard.
    -- (The ground between column centres read bilinearly, as smooth terrain draws it: the line is turned
    -- with the compound and the columns are on the world's axes, so a column-to-column step would mix in
    -- the hillside's slope across the line.)
    local function smooth(x, z)
        local fx, fz = x / CELL - 0.5, z / CELL - 0.5
        local ix, iz = math.floor(fx), math.floor(fz)
        local tx, tz = fx - ix, fz - iz
        local function at(i, k) return ground((i + 0.5) * CELL, (k + 0.5) * CELL) end
        return (at(ix, iz) * (1 - tx) + at(ix + 1, iz) * tx) * (1 - tz) + (at(ix, iz + 1) * (1 - tx) + at(ix + 1, iz + 1) * tx) * tz
    end
    local function steepest(from, step, count)
        local worst = 0
        local last = nil
        for k = 0, count * 2 do
            local p = site * (from + step * (k / 2))
            local g = smooth(p.X, p.Z)
            if last then worst = math.max(worst, math.abs(g - last) / (step.Magnitude / 2)) end
            last = g
        end
        return worst
    end
    -- (From one voxel column past the pad's flat: the column where the ramp leaves the pad is read
    -- bilinearly against the last flat one, a kink rather than a slope.)
    local gates = Ruins.GateCorridors
    local eastMid, frontMid = (gates.east[1] + gates.east[2]) / 2, (gates.front[1] + gates.front[2]) / 2
    local east = steepest(Vector3.new(gates.flat.X + 6, 0, eastMid), Vector3.new(4, 0, 0), 30)
    local front = steepest(Vector3.new(frontMid, 0, -(gates.flat.Z + 6)), Vector3.new(0, 0, -4), 30)
    local back = steepest(Vector3.new(-30, 0, gates.flat.Z + 2), Vector3.new(0, 0, 4), 30)
    if east > 1 / 8 + 0.035 then fail(("gate ramp: the east gate's way out climbs %.3f, steeper than 1 in 8"):format(east)) end
    if front > 1 / 8 + 0.035 then fail(("gate ramp: the main gate's way out climbs %.3f, steeper than 1 in 8"):format(front)) end
    if back > 1 / Ruins.GradeBank + 0.035 then fail(("bank: behind the compound the ground climbs %.3f, steeper than 1 in %d"):format(back, Ruins.GradeBank)) end
    if not info.graded or info.graded.moved == 0 then fail("no ground was graded on a hillside") end

    -- Nothing outside the foundation hovers: every rubble chunk out there has its lowest corner at or
    -- under the ground really beneath its centre (the voxels'; the rays are stale).
    local frame = info.frame
    local outside, floating = 0, 0
    for _, part in ipairs(info.model:GetDescendants()) do
        if part:IsA("BasePart") and part.Name == "Rubble" then
            local here = frame:Inverse() * part.CFrame.p
            if math.abs(here.X) > 46 or math.abs(here.Z) > 42 then
                outside = outside + 1
                local c, s = part.CFrame, part.Size
                local lowest = c.p.Y - (math.abs(c.r.Y) * s.X + math.abs(c.u.Y) * s.Y + math.abs(c.b.Y) * s.Z) / 2
                if lowest > ground(c.p.X, c.p.Z) + 0.02 then floating = floating + 1 end
            end
        end
    end
    if outside == 0 then fail("no rubble outside the foundation to measure") end
    if floating > 0 then fail(floating .. " of " .. outside .. " rubble chunks outside the foundation float over the ground") end
    -- Every spot is on a floor of the compound: a ray from 4 up lands exactly on it.
    local own = RaycastParams.new()
    own.FilterDescendantsInstances = { info.model }
    for _, key in ipairs({ "pads", "chestSpots", "lootSpots", "vehicleBays" }) do
        for i, spot in ipairs(info[key]) do
            local hit = ws:Raycast(spot.p + Vector3.new(0, 4, 0), Vector3.new(0, -8, 0), own)
            if not hit or math.abs(hit.Position.Y - spot.p.Y) > 0.01 then
                fail(("%s %d is not on the floor under it"):format(key, i))
                break
            end
        end
    end
    -- SnapSpots puts a spot that is off its floor back on it.
    local moved = { info.chestSpots[1] + Vector3.new(0, 0.4, 0) }
    Ruins.SnapSpots(info.model, moved)
    if math.abs(moved[1].p.Y - info.chestSpots[1].p.Y) > 0.01 then fail("SnapSpots left a spot 0.4 off its floor") end
    local unmarked = 0
    for _, part in ipairs(info.model:GetDescendants()) do
        if part:IsA("BasePart") and not part:GetAttribute("TeamBaseRuin") then unmarked = unmarked + 1 end
    end
    if unmarked > 0 then fail(unmarked .. " parts not marked TeamBaseRuin") end
    out.bank = bank
    out.moved = info.graded and info.graded.moved or 0
    workspace = nil
    return out
end
"""


def check_build(src, log):
    problems = []
    notes = []
    for mode in ("flat", "partial", "refused"):
        b = Build(src)
        b.lua.execute(SMOKE)
        found = b.lua.globals().smoke(b.ruins, mode)
        lines = [found[i] for i in range(1, len(found) + 1)]
        problems += ["build (%s): %s" % (mode, line) for line in lines]
        if mode == "flat" and found["bank"] is not None:
            notes.append("hillside graded: %d columns moved, banks up to %.1f off the floor" % (found["moved"], found["bank"]))
    log("build: flush on a hillside (terrain rays stale, voxels true), a partly levelled site and a refused one refused, "
        "%d problems%s" % (len(problems), ("; " + "; ".join(notes)) if notes else ""))
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
    # Each base's tagged pools are its own: DestructibleService keys a "Kind:id" pool by the string
    # map-wide, so a string both bases carry would make a shot at one count toward the other.
    tags1 = {p["tag"] for p in parts if ":" in p["tag"]}
    shared = sorted(tags1 & {p["tag"] for p in parts2 if ":" in p["tag"]})
    log("pools: %d tagged pool strings at team 1's base, %d shared with team 2's" % (len(tags1), len(shared)))
    if shared:
        problems.append("pools: both bases carry %d of the same pool tags (%s)" % (len(shared), ", ".join(shared[:4])))
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
    ("lamp off its post", [('local lampHead = box(gate, "GateLamp", la, la + 1.6, 10.2, 11.1, z1, z1 + 0.9,',
                            'local lampHead = box(gate, "GateLamp", la, la + 1.6, 10.2, 11.1, z1 + 0.3, z1 + 1.2,'),
                           ('box(gate, "GateLampGlass", la + 0.2, la + 1.4, 10.35, 10.95, z1 + 0.9, z1 + 1.05,',
                            'box(gate, "GateLampGlass", la + 0.2, la + 1.4, 10.35, 10.95, z1 + 1.2, z1 + 1.35,')], "floating"),
    ("dish sized (d, t, d)", [('put(hall, "Dish", Vector3.new(0.35, 4.2, 4.2)', 'put(hall, "Dish", Vector3.new(4.2, 0.35, 4.2)')],
     "cylinder"),
    ("doorway narrowed", [('box(ops, "Wall", -54, -48, 8, top,', 'box(ops, "Wall", -54, -48, 6.6, top,')], "doorway"),
    ("armoury sealed off", [('	table.insert(B.doorways, { name = "ArmouryFront"',
                             '	sandbags(room, "plantA", 9.6, 7.2, 18.4, 7.2, 4, TILE_TOP)\n'
                             '	sandbags(room, "plantB", 3.2, 32.2, 3.2, 42.6, 4, TILE_TOP)\n'
                             '	table.insert(B.doorways, { name = "ArmouryFront"')], "walk: cannot reach chest Armoury"),
    ("tyres in bay 2's way", [('tyres(20.5, 5.6, 3, "tyresA")', 'tyres(25.5, -45, 3, "tyresA")')], "Bay2: drive-out"),
    ("east gate walled up", [('perimeterRun(walls, "z", WX, -WZ + 6.4, EAST_Z0 - 3.9, 1, false, false, -24)',
                              'perimeterRun(walls, "z", WX, -WZ + 6.4, EAST_Z0 + 20, 1, false, false, -24)')], "Bay5: drive-out"),
    ("back row on the front row", [("local EAST_BAYS = { EAST_Z0 + LANE_PITCH / 2,", "local EAST_BAYS = { EAST_Z0 - 30,")],
     "overlap"),
    ("a bay short", [("local EAST_BAYS = { EAST_Z0 + LANE_PITCH / 2, EAST_Z0 + LANE_PITCH * 1.5, EAST_Z0 + LANE_PITCH * 2.5 }",
                      "local EAST_BAYS = { EAST_Z0 + LANE_PITCH / 2, EAST_Z0 + LANE_PITCH * 1.5 }")], "bays: 6, want 7"),
    ("queryable camo net", [("local netOpts = trimWith({ transparency = 0.12 })", "local netOpts = { transparency = 0.12 }")],
     "queryable over the bay"),
    ("spawn shelter breakable", [('hall.Name = "Spawn"\n\thall:SetAttribute("Destructible", false)',
                                  'hall.Name = "Hall"'),
                                 ('return box(hall, "BunkerWall", a, b, -1, y1 or BUNKER_TOP, c, d, color or BUNKER, MAT.Concrete, never)',
                                  'return box(hall, "Wall", a, b, -1, y1 or BUNKER_TOP, c, d, color or BUNKER, MAT.Concrete)')],
     "breaks, and must not"),
    # (a Model named Spawn... is kept whole by DestructibleService's NEVER_PREFIX, whatever is in it)
    ("perimeter unbreakable", [('walls.Name = "Perimeter"', 'walls.Name = "SpawnWalls"')],
     "does not break"),
    ("layout depends on the team", [("tops[index] = rnd(6.6, 9.4)", "tops[index] = rnd(6.6, 9.4) + (B.team.R > 0.5 and 0.3 or 0)")],
     "identical"),
    ("unseeded wear", [("rng = Random.new(seed or 1),", "rng = Random.new((seed or 1) + math.random(1, 100000)),")], "seed"),
    ("over budget", [("paving(ground, -WX + 0.8, 2, -WZ + 0.8, 24, 6, 6,", "paving(ground, -WX + 0.8, 2, -WZ + 0.8, 24, 20, 20,")], "budget"),
    ("scenery left on the site", [("if span <= TeamBaseRuins.ClearableSpan then", "if false then")], "build (flat): a tree on the site"),
    ("clearing only the footprint", [("local reach = TeamBaseRuins.Margin + FLATTEN_REACH", "local reach = TeamBaseRuins.Margin")],
     "build (flat): a tree where the ground is graded"),
    ("half a tree cleared", [("\t\t\t\t\tfor _, piece in ipairs(piecesOf(item)) do", "\t\t\t\t\tfor _, piece in ipairs({ item }) do")],
     "build (flat): a tree's leaves"),
    ("a piece of a pickup cleared", [("\t\t\twhile pickup.Parent and pickup.Parent ~= loot do", "\t\t\twhile false do")],
     "build (flat): a loot pickup"),
    ("levelling taken on trust", [("if not low or worst > LEVEL_SLACK then", "if not low then")],
     "build (partial): built on ground that is not level"),
    ("ground round it left alone", [("local graded = TeamBaseRuins.GradeSurroundings(site, height, mapInfo, after, locked)",
                                     "local graded = { moved = 0, most = 0, bank = 0 }")], "build (flat): gate ramp"),
    ("gate ramp as steep as a bank", [("local GRADE_BANK, GRADE_GATE = 3, 8", "local GRADE_BANK, GRADE_GATE = 3, 3")],
     "build (flat): gate ramp"),
    ("scenery left on moved ground", [("graded.cleared = TeamBaseRuins.ClearMoved(before, after, map, site.Position, reach)",
                                       "graded.cleared = 0")], "build (flat): scenery left where the ground moved"),
    ("road ground regraded", [("local locked = lockedColumns(after, map, site.Position, reach)", "local locked = {}")],
     "build (flat): the ground under a road was moved"),
    ("spots never snapped", [("\t\tlocal hit = workspace:Raycast(spot.Position + Vector3.new(0, 4, 0), Vector3.new(0, -8, 0), params)",
                              "\t\tlocal hit = nil")], "SnapSpots left a spot"),
    ("built at the asked height", [("local frame = CFrame.new(position.X, height, position.Z) * CFrame.Angles(0, yaw, 0)",
                                    "local frame = CFrame.new(position.X, position.Y, position.Z) * CFrame.Angles(0, yaw, 0)")],
     "build (flat): stands at"),
    ("bays sized for the smallest car", [("local LANE_PITCH = 15", "local LANE_PITCH = 9")], "overlap"),
    ("lanes only a car wide", [("local LANE_PITCH = 15", "local LANE_PITCH = 12")], "drive-out blocked by the car parked in"),
    ("a bollard in a lane", [("	-- Where a thrown defense may not go up: each bay and its way out",
                              '	box(yard, "Bollard", 40, 40.6, TILE_TOP, 4, -50, -49.4, STEEL, MAT.Metal)\n'
                              "	-- Where a thrown defense may not go up: each bay and its way out")], "Bay3: drive-out blocked by Bollard"),
    ("canopy masts in front of the bays", [("local mastZ, tipZ, beamY = FRONT_Z + BAY_HALF_LENGTH + 8,",
                                            "local mastZ, tipZ, beamY = FRONT_Z - BAY_HALF_LENGTH - 4,")], "drive-out blocked by CanopyMast"),
    ("gantry under the tallest van", [("local GANTRY_Y = 12.5", "local GANTRY_Y = 11.5")], "drive-out blocked by Gantry"),
    ("drums in a bay", [("{ { 64.1, -16.2 }, { 64.1, -18.3 }, { 61.9, -16.6 } }", "{ { 55.5, -30 }, { 64.1, -18.3 }, { 61.9, -16.6 } }")],
     "Bay4: queryable over the bay (Drum)"),
    ("a chest in bay 5's way", [('table.insert(B.chests, { name = "FuelPoint", at = CFrame.new(54, TILE_TOP, -8) })',
                                 'table.insert(B.chests, { name = "FuelPoint", at = CFrame.new(54, TILE_TOP, 14) })')],
     "is in Bay5's way out"),
    ("a chest spot short", [('	table.insert(B.chests, { name = "TowerBase", at = CFrame.new(mid, TILE_TOP, (z0 + z1) / 2) })\n', '')],
     "but LootService.BaseStock.chest is"),
    ("one pool tag for both bases", [('\t\t\t\ttag = tag .. "@" .. B.site\n', '')], "both bases carry"),
    # (in another Model than its crate: dropDressing walks only the breaking part's siblings)
    ("crate band out of its pool", [('facePlate(room, "CrateBand"', 'facePlate(model, "CrateBand"'),
                                    ('STEEL_DARK, MAT.Metal, trimWith({ tag = stack.tag }))', 'STEEL_DARK, MAT.Metal)')],
     "CrateBand (on Crate) is left hanging"),
    ("crate on a chest spot", [('	table.insert(B.chests, { name = "LeanTo"',
                                '	box(yard, "Crate", -63, -61, TILE_TOP, TILE_TOP + 2.4, 5.4, 7.4, WOOD, MAT.WoodPlanks)\n'
                                '	table.insert(B.chests, { name = "LeanTo"')], "chest LeanTo: not clear"),
]


def sweep_seeds(src, seeds, log):
    """The wear differs by seed and a match rolls its own, so the geometry checks run over a spread of
    seeds too (z-fighting at source, floating, walking, bays, doorways, spots), not only SEED."""
    problems, counts = [], []
    for seed in seeds:
        b = Build(src)
        frame, model, info = b.layout(0, 0, 0, 0, TEAM1, seed)
        found = check_zfight(b, model, lambda *_: None)
        parts = b.dump(model)
        for p in parts:
            p["aabb"] = aabb(p)
        found += check_all(b, frame, model, info, parts, lambda *_: None)
        counts.append(len(parts))
        problems += ["seed %d: %s" % (seed, line) for line in found]
    log("seeds: %d more seeds swept, %d problems, %d..%d parts" % (len(seeds), len(problems), min(counts), max(counts)))
    return problems


def main(argv):
    repo = argv[1] if len(argv) > 1 and not argv[1].startswith("--") else "."
    plant = "--plant" in argv
    global BAYS, CHESTS, CAR, CORRIDOR_HALF, CORRIDOR_HEIGHT
    BAYS = slot_count(repo)
    CHESTS = chest_stock(repo)
    from team_base_ruins_modeteams_check import vehicle_extents
    sizes = vehicle_extents(repo)
    width = max(v[0] for v in sizes.values())
    length = max(v[1] for v in sizes.values())
    height = max(v[2] for v in sizes.values())
    CAR = (width + 2 * CAR_MARGIN, length + 2 * CAR_MARGIN)
    CORRIDOR_HALF = max(CORRIDOR_HALF, CAR[0] / 2, width / 2 + LANE_SPARE / 2)
    global FLAT_X, FLAT_Z, DRIVE_OUT
    ruins = (Path(repo) / "ServerScriptService/Modules/TeamBaseRuins.lua").read_text()
    wx, wz = (float(v) for v in re.search(r"local WX, WZ = ([\d.]+), ([\d.]+)", ruins).groups())
    FLAT_X, FLAT_Z, DRIVE_OUT = wx + 1 + 4, wz + 1 + 4, wx + 16
    CORRIDOR_HEIGHT = max(CORRIDOR_HEIGHT, height + 0.6 + 0.5)
    print("vehicles: %d models, biggest %.2f wide, %.2f long, %.2f tall -> bay box %.2f x %.2f, way out %.2f wide x %.2f tall"
          % (len(sizes), width, length, height, CAR[0], CAR[1], CORRIDOR_HALF * 2, CORRIDOR_HEIGHT))
    # ModeTeams' bay-occupied box must cover the biggest vehicle too.
    mt = (Path(repo) / "ServerScriptService/Modules/ModeTeams.lua").read_text()
    clear = re.search(r"local BAY_CLEAR = Vector3\.new\(([\d.]+), ([\d.]+), ([\d.]+)\)", mt)
    bay_clear_problem = None
    if not clear or float(clear.group(1)) < width + 2 * CAR_MARGIN - 1e-6 or float(clear.group(3)) < length + 2 * CAR_MARGIN - 1e-6:
        bay_clear_problem = "ModeTeams BAY_CLEAR %s is smaller than the biggest vehicle plus %.1f all round" % (
            clear.group(0) if clear else "missing", CAR_MARGIN)
    src = sources(repo)
    problems = run(src, print)
    if "--quick" not in argv:
        problems += sweep_seeds(src, range(1, 25), print)
    if bay_clear_problem:
        problems.append(bay_clear_problem)
    for line in problems:
        print("  FAIL " + line)
    print("team_base_ruins_check: %d problems" % len(problems))
    ok = not problems
    if plant:
        only = argv[argv.index("--only") + 1] if "--only" in argv else ""
        for label, edits, expect in PLANTS:
            if only not in label:
                continue
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
