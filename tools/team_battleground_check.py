"""The central battleground (ServerScriptService/Modules/TeamBattleground.lua), checked without Studio.

Runs the REAL TeamBattleground source (its Layout, the whole geometry, and its Build on a mock town),
the real ReplicatedStorage/Shared/ZFight.lua, the real DestructibleService and the real BotNav
(FindCover and CanStep, against a raycaster over the built parts) under the lupa mock of
tools/team_base_ruins_check.py, then measures what was built:

  budget      900..1400 parts (said, with the count per section)
  mirror      team 2's half is team 1's reflected in z = 0, part for part (a wedge's slope the right way
              round); every piece on the mirror is its own reflection; no pool tag is shared
  zfight      ZFight.Scan finds nothing at source and nothing after ZFight.Fix
  floating    every part connects, through parts it touches, to the ground
  cylinders   every Cylinder is round on Y/Z (its length is X)
  doorways    4 wide and 7 tall for a player and 5 wide for a bot (PathfindingService's agent), clear
  walk        a multi-level grid of where an R15 body can stand (2 wide, 5.2 tall, steps of 1.5): from
              each team's end it reaches both objectives, every piece of high ground, every loot spot,
              every zipline handle and every built cover spot, and both teams' walks are the same length
  bots        the same for PathfindingService's agent (5 wide, 6 tall) with one-way drops of up to 14:
              nothing it can get into that it cannot get out of again
  high ground every power position has two or more separate ways up, and stays reachable with any one
              of them taken away
  sightlines  the longest unbroken eye-level line straight down each lane
  cover       the longest stretch of each route with nothing at crouch height within 6 studs
  objectives  on the mirror (so equidistant from both bases) and on the floor built for them; every
              point BotService sends a bot to (15.4 out, all round) is floor a bot can stand on
  vehicles    the cut's corridor (6 either side of its line, 0.7 to 8 up) clear, and away from the keep
  loot        each spot on a floor with room round it, off the vehicle route; the rarer the floor, the
              more exposed the spot
  ziplines    a rider's body clears everything from top to bottom; the handle is in reach of the floor
  destruct    the real DestructibleService: walls, sandbags, crates, containers and props break; no
              floor, stair, ramp or structure does
  seed        the same seed builds the same battleground twice; more seeds pass the geometry checks
  build       Build on a mock town: scenery cleared (queryable or not: the town's streets, signal heads
              and lamp arms are non-queryable), every road reaching the disc cut SQUARE at the apron's
              edge (all its pieces on one line) and finished (kerbs across the pavements, markings
              stopped at a give-way line, a gateway whose beam clears the tallest vehicle), a road that
              only passes by kept whole, no battleground part on a road; landmarks and bases kept, the
              height FlattenPad returns used (and its town-level retry), a river site refused, four
              ziplines hung
  botnav      the real BotNav.FindCover, handed the battleground's cover, takes it; every spot it
              returns is hidden from the threat by this file's own rays

    python3 tools/team_battleground_check.py [repo]            the checks
    python3 tools/team_battleground_check.py [repo] --plant    and the planted faults
    python3 tools/team_battleground_check.py [repo] --plant-only [words]   only the plants (those named)

tools/team_battleground_preview.py draws the layout offline (a plan and eye-level views, PNG).
"""

import math
import sys
from collections import deque
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_base_ruins_check as TBR  # noqa: E402
from vehicle_models_axis_check import luau_to_lua  # noqa: E402
# BotNav uses Luau's `continue`; this converter turns it into a goto.
from car_placement_luau import luau_to_lua as luau_to_lua_continue  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

BUDGET = (900, 3000)
RADIUS = 172.0
EXTENT = 178.0
GRID = 0.5
STEP = 1.5
# A body: its radius and height, how steep the stairs round it may climb, and the steepest surface it
# can stand on (the normal's Y: 60 degrees for a player, PathfindingService's 55 for a bot).
R15 = dict(radius=1.0, height=5.2, slope=1.0, floorNormal=math.cos(math.radians(60)))
BOT = dict(radius=2.5, height=6.0, slope=math.tan(math.radians(55)), floorNormal=math.cos(math.radians(55)))
BOT_DROP = 14.0
EYE = 5.2
LANE_SIGHT = {"left": (-110, -50), "centre": (-36, 36), "right": (50, 110)}
SIGHT_LIMIT = 90.0  # 80 on the 126 disc; the lanes are 1.37x longer on the 172 one
COVER_REACH, COVER_HIGH, COVER_GAP = 6.0, 2.4, 15.0
CAR_HALF, CAR_LOW, CAR_HIGH = 6.0, 0.7, 8.0
HILL_RADIUS, HILL_SPREAD = 28.0, 0.55
DOOR_WIDTH, DOOR_HEIGHT, BOT_WIDTH = 4.0, 7.0, 5.0
TOUCH = 0.12
SEED = 20260924

EXTRA = r"""
do
    -- DestructibleService now hooks RunService.Heartbeat and asks Players at load: give every service
    -- the mock hands out a signal that never fires and an empty player list.
    local base = game.GetService
    -- CollectionService records its tags, so the emplacement check can see them.
    TAGS = {}
    local collection = {
        AddTag = function(_, instance, tag) TAGS[instance] = TAGS[instance] or {}; TAGS[instance][tag] = true end,
        HasTag = function(_, instance, tag) return TAGS[instance] ~= nil and TAGS[instance][tag] == true end,
    }
    game.GetService = function(self, name)
        if name == "CollectionService" then return collection end
        local service = base(self, name)
        service.Heartbeat = service.Heartbeat or { Connect = function() return { Disconnect = function() end } end }
        service.GetPlayers = service.GetPlayers or function() return {} end
        service.GetPlayerFromCharacter = service.GetPlayerFromCharacter or function() return nil end
        return service
    end
end
table.clone = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
do
    -- Clone: the properties and attributes, no children (what ClearSite's street cutting needs).
    local meta = getmetatable(Instance.new("Part"))
    local previous = meta.__index
    meta.__index = function(i, k)
        if k == "Clone" then
            return function(self)
                local copy = Instance.new(self.ClassName)
                for key, value in pairs(rawget(self, "props")) do
                    if key ~= "Parent" then rawget(copy, "props")[key] = value end
                end
                for key, value in pairs(rawget(self, "attrs")) do rawget(copy, "attrs")[key] = value end
                return copy
            end
        end
        if k == "Destroying" then
            -- DestructibleService's opt-out caches drop an entry when its instance goes.
            return { Connect = function() return { Disconnect = function() end } end }
        end
        return previous(i, k)
    end
end
do
    -- Vector3:Min/Max (DestructibleService's "is it a small thing" bounds).
    local meta = getmetatable(Vector3.new(0, 0, 0))
    local previous = meta.__index
    local function pick(f)
        return function(a, b) return Vector3.new(f(a.X, b.X), f(a.Y, b.Y), f(a.Z, b.Z)) end
    end
    local extra = { Min = pick(math.min), Max = pick(math.max) }
    meta.__index = function(v, k)
        if extra[k] then return extra[k] end
        if type(previous) == "function" then return previous(v, k) end
        return previous[k]
    end
end
function dumpAll(model)
    local out = {}
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            local c, s = p.CFrame, p.Size
            local col = p.Color or {}
            local names = {}
            local node = p.Parent
            while node and node ~= model do table.insert(names, 1, node.Name); node = node.Parent end
            table.insert(out, { p.Name, p.ClassName, tostring(p.Shape), s.X, s.Y, s.Z,
                c.p.X, c.p.Y, c.p.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z,
                p.CanCollide and 1 or 0, p.CanQuery and 1 or 0, p.Transparency or 0,
                tostring(p:GetAttribute("Destructible")), p:GetAttribute("DestructibleHealth") or 0,
                table.concat(names, "/"), col.R or 0, col.G or 0, col.B or 0, tostring(p.Material) })
        end
    end
    return out
end
function taggedIn(model, tag)
    local out = {}
    for _, p in ipairs(model:GetDescendants()) do
        if TAGS[p] and TAGS[p][tag] then table.insert(out, p.Name) end
    end
    return out
end
function vecList(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = { v.X, v.Y, v.Z } end
    return out
end
"""


def sources(repo):
    root = Path(repo)
    return {
        "bg": (root / "ServerScriptService/Modules/TeamBattleground.lua").read_text(),
        "zfight": (root / "ReplicatedStorage/Shared/ZFight.lua").read_text(),
        "destruct": (root / "ServerScriptService/Modules/DestructibleService.lua").read_text(),
        "botnav": (root / "ServerScriptService/Modules/BotNav.lua").read_text(),
    }


class Runtime:
    """One Lua runtime with the modules loaded. Each is a different server as far as math.random goes
    (as team_base_ruins_check's Build is): runtimes made in one process start from the same
    math.random stream otherwise, and the seed check's second build could not see a layout that
    reads it."""

    servers = 0

    def __init__(self, src):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        Runtime.servers += 1
        self.lua.execute("math.randomseed(%d)" % (7919 * Runtime.servers))
        mock = TBR.MOCK.replace("local PARTS = { Part = true, WedgePart = true }",
                                "local PARTS = { Part = true, WedgePart = true, TrussPart = true }")
        self.lua.execute(mock + TBR.EXTRA_MOCK + TBR.DUMP + EXTRA)
        modules = self.lua.eval("function() MODULES = {}; return MODULES end")()
        modules["ZFight"] = self.lua.execute(luau_to_lua(src["zfight"]))
        self.zfight = modules["ZFight"]
        modules["MapTerrain"] = self.lua.eval("{}")
        modules["Remotes"] = self.lua.eval("{ Event = function() return { FireAllClients = function() end } end }")
        modules["CombatService"] = self.lua.eval("{}")
        self.bg = self.lua.execute(luau_to_lua(src["bg"]))
        self.src = src
        self._destruct = None

    def layout(self, seed, x=0.0, y=0.0, z=0.0, yaw=0.0):
        g = self.lua.globals()
        return self.bg.Layout(g.makeFrame(x, y, z, yaw), seed)

    def dump(self, model):
        rows = self.lua.globals().dumpAll(model)
        parts = []
        for i in range(1, len(rows) + 1):
            r = rows[i]
            v = [r[j] for j in range(1, 29)]
            shape = v[2]
            kind = "box"
            if v[1] == "WedgePart":
                kind = "wedge"
            elif shape.endswith("Cylinder"):
                kind = "cyl"
            elif shape.endswith("Ball"):
                kind = "ball"
            p = {
                "name": v[0], "cls": v[1], "shape": shape, "kind": kind, "size": tuple(v[3:6]),
                "pos": tuple(v[6:9]), "axes": (tuple(v[9:12]), tuple(v[12:15]), tuple(v[15:18])),
                "collide": bool(v[18]), "query": bool(v[19]), "transparency": v[20],
                "tag": v[21], "health": v[22], "path": v[23], "color": tuple(v[24:27]), "material": v[27],
            }
            p["aabb"] = TBR.aabb(p)
            parts.append(p)
        return parts

    def vecs(self, lst):
        rows = self.lua.globals().vecList(lst)
        return [tuple(rows[i][j] for j in range(1, 4)) for i in range(1, len(rows) + 1)]

    def destruct(self):
        return TBR.Build.destruct(self)


def vec(v):
    return (v.X, v.Y, v.Z)


def read_info(rt, info):
    """The Lua info table as plain Python (local-space lists)."""
    out = {"objectives": rt.vecs(info.objectivesLocal), "cover": rt.vecs(info.coverLocal), "loot": [], "doorways": [],
           "routes": {}, "power": [], "lanes": {}, "zips": []}
    spots = info.lootSpots
    for i in range(1, len(spots) + 1):
        s = spots[i]
        out["loot"].append({"name": s.name, "at": vec(s.localPosition), "kind": s.kind, "floor": s.floor})
    doors = info.doorways
    for i in range(1, len(doors) + 1):
        d = doors[i]
        out["doorways"].append({k: d[k] for k in ("name", "x0", "x1", "z0", "z1", "floor", "top")})
    for name, points in info.routes.items():
        out["routes"][name] = rt.vecs(points)
    for name, points in info.lanes.items():
        out["lanes"][name] = rt.vecs(points)
    power = info.power
    for i in range(1, len(power) + 1):
        p = power[i]
        b = p.box
        out["power"].append({"name": p.name, "point": vec(p.point), "box": (b[1], b[2], b[3], b[4]), "minY": p.minY})
    out["emplacements"] = []
    emps = info.emplacements
    for i in range(1, len(emps) + 1):
        out["emplacements"].append({"name": emps[i].name, "covers": emps[i].covers})
    zips = info.zips
    for i in range(1, len(zips) + 1):
        z = zips[i]
        out["zips"].append({"name": z.name, "fromTop": vec(z.fromTopLocal), "to": vec(z.toLocal)})
    return out


# ------------------------------------------------------------------------------------------------
# Columns: every solid part cut by the vertical line through each cell of a grid
# ------------------------------------------------------------------------------------------------

class Columns:
    """Solid intervals on the vertical line through each grid cell's centre, merged per cell, with the
    ground (the flattened pad, top at 0) solid under everything. LO/HI are (K, NX, NZ), padded with +inf."""

    def __init__(self, parts, extent=EXTENT, grid=GRID, want=lambda p: p["collide"]):
        self.grid = grid
        self.x0 = self.z0 = -extent
        self.n = int(round(2 * extent / grid)) + 1
        xs = self.x0 + np.arange(self.n) * grid
        self.xs = xs
        cells, los, his, nys, owners = [], [], [], [], []
        for index, p in enumerate(parts):
            if not want(p):
                continue
            lo_b, hi_b = p["aabb"]
            pad = grid / 2  # vertical_interval thickens thin boards to a cell; look that far round them
            i0 = max(0, int(math.ceil((lo_b[0] - pad - self.x0) / grid - 1e-9)))
            i1 = min(self.n - 1, int(math.floor((hi_b[0] + pad - self.x0) / grid + 1e-9)))
            k0 = max(0, int(math.ceil((lo_b[2] - pad - self.z0) / grid - 1e-9)))
            k1 = min(self.n - 1, int(math.floor((hi_b[2] + pad - self.z0) / grid + 1e-9)))
            if i1 < i0 or k1 < k0:
                continue
            ii, kk = np.meshgrid(np.arange(i0, i1 + 1), np.arange(k0, k1 + 1), indexing="ij")
            ii, kk = ii.ravel(), kk.ravel()
            lo, hi, ny = vertical_interval(p, xs[ii], xs[kk])
            ok = hi > lo + 1e-6
            if ok.any():
                cells.append(ii[ok] * self.n + kk[ok])
                los.append(lo[ok])
                his.append(hi[ok])
                nys.append(ny[ok])
                owners.append(np.full(int(ok.sum()), index))
        allcells = np.arange(self.n * self.n)
        cells.append(allcells)
        los.append(np.full(allcells.size, -60.0))
        his.append(np.zeros(allcells.size))
        nys.append(np.ones(allcells.size))
        owners.append(np.full(allcells.size, -1))
        cell = np.concatenate(cells)
        lo = np.concatenate(los)
        hi = np.concatenate(his)
        ny = np.concatenate(nys)
        owner = np.concatenate(owners)
        # Merge per cell: sort by (cell, lo); a key that puts each cell in its own band keeps the running
        # maximum of the tops from leaking between cells.
        band = 1000.0
        order = np.lexsort((lo, cell))
        cell, lo, hi, ny, owner = cell[order], lo[order], hi[order], ny[order], owner[order]
        klo, khi = lo + cell * band, hi + cell * band
        run = np.maximum.accumulate(khi)
        start = np.ones(cell.size, bool)
        start[1:] = klo[1:] > run[:-1] + 1e-9
        group = np.cumsum(start) - 1
        mlo = klo[start] - cell[start] * band
        mhi_key = np.zeros(group[-1] + 1)
        np.maximum.at(mhi_key, group, khi)
        mcell = cell[start]
        mhi = mhi_key - mcell * band
        # Whose top each merged solid's top is, and how steep it is there: the raw interval with the
        # highest top in each group.
        top_order = np.lexsort((khi, group))
        last = np.ones(top_order.size, bool)
        last[:-1] = group[top_order][1:] != group[top_order][:-1]
        winner = top_order[last]
        mny = ny[winner]
        mowner = owner[winner]
        # Layer index within each cell.
        first = np.ones(mcell.size, bool)
        first[1:] = mcell[1:] != mcell[:-1]
        idx = np.arange(mcell.size) - np.maximum.accumulate(np.where(first, np.arange(mcell.size), 0))
        self.K = int(idx.max()) + 1
        self.LO = np.full((self.K, self.n * self.n), np.inf)
        self.HI = np.full((self.K, self.n * self.n), np.inf)
        self.NY = np.ones((self.K, self.n * self.n))
        self.OWNER = np.full((self.K, self.n * self.n), -1, np.int64)
        self.LO[idx, mcell] = mlo
        self.HI[idx, mcell] = mhi
        self.NY[idx, mcell] = mny
        self.OWNER[idx, mcell] = mowner
        self.LO = self.LO.reshape(self.K, self.n, self.n)
        self.HI = self.HI.reshape(self.K, self.n, self.n)
        self.NY = self.NY.reshape(self.K, self.n, self.n)
        self.OWNER = self.OWNER.reshape(self.K, self.n, self.n)

    def cell(self, x, z):
        return int(round((x - self.x0) / self.grid)), int(round((z - self.z0) / self.grid))

    def solid_at(self, x, z, y):
        i, k = self.cell(x, z)
        return bool(((self.LO[:, i, k] <= y) & (self.HI[:, i, k] >= y)).any())


def vertical_interval(p, X, Z):
    """Where the vertical line through each (X, Z) passes through part p's solid: (lo, hi, ny) arrays,
    lo >= hi for a miss, and ny the Y of the surface's normal where the line leaves the top (1 for a
    level top; a wheel's round side or a tipped slab is steeper). Boxes and trusses exactly, a wedge
    with its slope, a cylinder and a ball exactly."""
    c = np.array(p["pos"])
    axes = np.array(p["axes"])
    h = np.array(p["size"]) / 2
    # A board thinner than the grid could slip between two cell centres and vanish: across any mostly
    # horizontal axis, every part is at least one cell thick.
    if p["kind"] in ("box", "wedge"):
        for i in range(3):
            if abs(axes[i][1]) < 0.7:
                h[i] = max(h[i], GRID / 2 + 1e-6)
    n = X.size
    lo = np.full(n, -np.inf)
    hi = np.full(n, np.inf)
    ny = np.ones(n)
    a = axes[:, 0][:, None] * (X - c[0])[None, :] + axes[:, 2][:, None] * (Z - c[2])[None, :] - axes[:, 1][:, None] * c[1]
    b = axes[:, 1]

    def top(t, normal_y):
        nonlocal hi, ny
        lower = t < hi
        hi = np.where(lower, t, hi)
        ny = np.where(lower, normal_y, ny)

    def slab(i, half):
        nonlocal lo
        if abs(b[i]) < 1e-9:
            miss = np.abs(a[i]) > half
            lo = np.where(miss, np.inf, lo)
        else:
            t1 = (-half - a[i]) / b[i]
            t2 = (half - a[i]) / b[i]
            lo = np.maximum(lo, np.minimum(t1, t2))
            top(np.maximum(t1, t2), abs(b[i]))

    kind = p["kind"]
    if kind == "ball":
        r = h.min()
        d2 = (X - c[0]) ** 2 + (Z - c[2]) ** 2
        miss = d2 > r * r
        root = np.sqrt(np.where(miss, 0, r * r - d2))
        lo = np.where(miss, np.inf, c[1] - root)
        hi = c[1] + root
        ny = root / r
    elif kind == "cyl":
        slab(0, h[0])
        r = min(h[1], h[2])
        A = b[1] ** 2 + b[2] ** 2
        if A < 1e-12:
            lo = np.where(a[1] ** 2 + a[2] ** 2 > r * r, np.inf, lo)
        else:
            B = 2 * (a[1] * b[1] + a[2] * b[2])
            C = a[1] ** 2 + a[2] ** 2 - r * r
            disc = B * B - 4 * A * C
            miss = disc < 0
            root = np.sqrt(np.where(miss, 0, disc))
            t1 = (-B - root) / (2 * A)
            t2 = (-B + root) / (2 * A)
            lo = np.where(miss, np.inf, np.maximum(lo, t1))
            ly, lz = a[1] + b[1] * t2, a[2] + b[2] * t2
            top(t2, (b[1] * ly + b[2] * lz) / r)
    else:
        for i in range(3):
            slab(i, h[i])
        if kind == "wedge":
            # solid where ly <= hy * lz / hz (the tall face is +Z)
            k = h[1] / h[2]
            coef = b[1] - k * b[2]
            const = a[1] - k * a[2]
            if abs(coef) < 1e-9:
                lo = np.where(const > 0, np.inf, lo)
            else:
                t = -const / coef
                if coef > 0:
                    top(np.full(n, t) if np.ndim(t) == 0 else t, coef / math.sqrt(1 + k * k))
                else:
                    lo = np.maximum(lo, t)
    return lo, hi, ny


# ------------------------------------------------------------------------------------------------
# Walking
# ------------------------------------------------------------------------------------------------

def disc_offsets(radius, grid):
    r = int(math.ceil(radius / grid))
    out = []
    for di in range(-r, r + 1):
        for dk in range(-r, r + 1):
            d = math.hypot(di, dk) * grid
            if d <= radius + 1e-9:
                out.append((di, dk, d))
    return out


def shifted(arr, di, dk, fill):
    """arr[..., i + di, k + dk] at [i, k], `fill` past the edge."""
    out = np.full_like(arr, fill)
    n = arr.shape[-1]
    si0, si1 = max(0, di), min(n, n + di)
    ti0, ti1 = max(0, -di), min(n, n - di)
    sk0, sk1 = max(0, dk), min(n, n + dk)
    tk0, tk1 = max(0, -dk), min(n, n - dk)
    out[..., ti0:ti1, tk0:tk1] = arr[..., si0:si1, sk0:sk1]
    return out


class Walk:
    """Nodes: (layer k, cell) where a body stands on top of merged solid k with room above it.
    Edges: to the 8 neighbours at a height within STEP (both ways), and for bots drops of up to BOT_DROP
    (one way)."""

    def __init__(self, cols, body, drops=False):
        with np.errstate(invalid="ignore"):
            self._build(cols, body, drops)

    def _build(self, cols, body, drops):
        self.cols = cols
        K, n = cols.K, cols.n
        S = cols.HI  # the top of each merged solid is a surface
        # ...and one a body can stand on only where it is no steeper than the body's own limit.
        valid = np.isfinite(S) & (S > -50) & (cols.NY >= body["floorNormal"])
        stand = valid.copy()
        H, slope = body["height"], body["slope"]
        for di, dk, d in disc_offsets(body["radius"], cols.grid):
            LOn = shifted(cols.LO, di, dk, np.inf)
            HIn = shifted(cols.HI, di, dk, np.inf)
            for k in range(K):
                s = S[k]
                low = s + STEP + d * slope
                top = s + H
                hit = ((LOn < top[None]) & (HIn > low[None])).any(axis=0)
                stand[k] &= ~hit
        self.stand = stand
        self.S = S
        ids = np.full((K, n, n), -1, np.int64)
        count = int(stand.sum())
        ids[stand] = np.arange(count)
        self.ids = ids
        self.count = count
        where = np.argwhere(stand)
        self.node_k, self.node_i, self.node_j = where[:, 0], where[:, 1], where[:, 2]
        self.node_y = S[stand]
        self.node_owner = cols.OWNER[stand]
        self.node_x = cols.x0 + self.node_i * cols.grid
        self.node_z = cols.z0 + self.node_j * cols.grid
        src, dst = [], []
        for di, dk in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            idn = shifted(ids, di, dk, -1)
            Sn = shifted(S, di, dk, np.nan)
            LOn = shifted(cols.LO, di, dk, np.inf)
            for k1 in range(K):
                a = ids[k1]
                for k2 in range(K):
                    b = idn[k2]
                    rise = Sn[k2] - S[k1]
                    ok = (a >= 0) & (b >= 0) & (np.abs(rise) <= STEP)
                    if drops:
                        # down off an edge: the neighbour's column is clear from its floor to our head
                        above = LOn[k2 + 1] if k2 + 1 < K else np.full_like(rise, np.inf)
                        ok |= (a >= 0) & (b >= 0) & (rise < -STEP) & (rise >= -BOT_DROP) & (above >= S[k1] + H)
                    if ok.any():
                        src.append(a[ok])
                        dst.append(b[ok])
        if drops:
            self._far_drops(cols, body, ids, S, src, dst)
        src = np.concatenate(src)
        dst = np.concatenate(dst)
        self.src, self.dst = src, dst
        self.indptr, self.indices = csr(src, dst, count)
        self.rindptr, self.rindices = csr(dst, src, count)

    def _far_drops(self, cols, body, ids, S, src, dst):
        """Drops that land further out than the next cell. Beside a wall or a platform's face the
        cells within a body's radius are no place to stand, so off an edge into a pocket beside it
        there is no neighbour to drop to -- but a body walking off the edge carries on and lands
        there. Up to radius + a cell out, straight along one of the 8 directions, where every
        column passed over is clear from a step above the edge to head height."""
        K = cols.K
        H = body["height"]
        reach = int(math.ceil(body["radius"] / cols.grid)) + 1
        for di, dk in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            for k1 in range(K):
                a = ids[k1]
                if not (a >= 0).any():
                    continue
                s = S[k1]
                clear = np.ones_like(a, dtype=bool)
                for t in range(1, reach + 1):
                    LOt = shifted(cols.LO, t * di, t * dk, np.inf)
                    HIt = shifted(cols.HI, t * di, t * dk, np.inf)
                    if t >= 2:
                        idn = shifted(ids, t * di, t * dk, -1)
                        Sn = shifted(S, t * di, t * dk, np.nan)
                        for k2 in range(K):
                            b = idn[k2]
                            rise = Sn[k2] - s
                            above = LOt[k2 + 1] if k2 + 1 < K else np.full_like(rise, np.inf)
                            ok = clear & (a >= 0) & (b >= 0) & (rise < -STEP) & (rise >= -BOT_DROP) & (above >= s + H)
                            if ok.any():
                                src.append(a[ok])
                                dst.append(b[ok])
                    # this column, passed over on the way to anything further out
                    clear &= ~((LOt < (s + H)[None]) & (HIt > (s + STEP)[None])).any(axis=0)
                    if not clear.any():
                        break

    def near(self, x, y, z, reach=1.0, rise=1.6):
        """Node ids standing within `reach` (flat) of (x, z) at a height within `rise` of y."""
        c = self.cols
        i, k = c.cell(x, z)
        r = int(math.ceil(reach / c.grid))
        out = []
        for di in range(-r, r + 1):
            for dk in range(-r, r + 1):
                a, b = i + di, k + dk
                if 0 <= a < c.n and 0 <= b < c.n and math.hypot(di, dk) * c.grid <= reach + 1e-9:
                    for layer in range(c.K):
                        node = self.ids[layer, a, b]
                        if node >= 0 and abs(self.S[layer, a, b] - y) <= rise:
                            out.append(int(node))
        return out

    def bfs(self, starts, reverse=False, banned=None):
        indptr, indices = (self.rindptr, self.rindices) if reverse else (self.indptr, self.indices)
        dist = np.full(self.count, -1, np.int64)
        starts = np.unique(np.array(starts, np.int64))
        if banned is not None:
            starts = starts[~banned[starts]]
        dist[starts] = 0
        frontier = starts
        depth = 0
        while frontier.size:
            depth += 1
            counts = indptr[frontier + 1] - indptr[frontier]
            total = int(counts.sum())
            if total == 0:
                break
            base = np.repeat(indptr[frontier], counts)
            offs = np.arange(total) - np.repeat(np.cumsum(counts) - counts, counts)
            nb = indices[base + offs]
            nb = nb[dist[nb] < 0]
            if banned is not None:
                nb = nb[~banned[nb]]
            nb = np.unique(nb)
            dist[nb] = depth
            frontier = nb
        return dist


def csr(src, dst, n):
    order = np.argsort(src, kind="stable")
    s, d = src[order], dst[order]
    indptr = np.zeros(n + 1, np.int64)
    np.add.at(indptr, s + 1, 1)
    indptr = np.cumsum(indptr)
    return indptr, d


def entries(walk, side):
    """Where a team walks in: the edge of the disc on its side (side -1 is team 1, at -Z)."""
    starts = []
    for x in np.arange(-100, 101, 4.0):
        z = side * math.sqrt(max(0.0, (RADIUS - 2) ** 2 - x * x))
        starts += walk.near(x, 0.0, z, reach=1.5)
    return starts


def mirror(p):
    return (p[0], p[1], -p[2])


# ------------------------------------------------------------------------------------------------
# The checks
# ------------------------------------------------------------------------------------------------

def check_budget(parts, log):
    counts = {}
    for p in parts:
        bits = p["path"].split("/")
        key = bits[1] if len(bits) > 1 else bits[0]
        counts[key] = counts.get(key, 0) + 1
    log("parts: %d  (%s)" % (len(parts), ", ".join("%s %d" % kv for kv in sorted(counts.items(), key=lambda kv: -kv[1]))))
    if not BUDGET[0] <= len(parts) <= BUDGET[1]:
        return ["budget: %d parts, outside %d..%d" % (len(parts), *BUDGET)]
    return []


def reflect_axes(axes):
    return tuple((a[0], a[1], -a[2]) for a in axes)


def same_box(a, b, tol=1e-4):
    """Whether part b is part a reflected in z = 0 (as solids): mirrored centre, and each of a's
    reflected axes parallel to one of b's with the same half-size. A wedge's slope is not symmetric in
    its own Y or Z, so there the reflected Y and Z axes must match b's exactly (not just up to sign)."""
    if abs(a["pos"][0] - b["pos"][0]) > tol or abs(a["pos"][1] - b["pos"][1]) > tol or abs(a["pos"][2] + b["pos"][2]) > tol:
        return False
    ra = reflect_axes(a["axes"])
    for i in range(3):
        found = False
        for j in range(3):
            dot = sum(ra[i][t] * b["axes"][j][t] for t in range(3))
            if abs(abs(dot) - 1) < 1e-4 and abs(a["size"][i] - b["size"][j]) < tol:
                if a["kind"] == "cyl" and i == 0 and j != 0:
                    continue
                if a["kind"] == "wedge" and i > 0 and (j != i or dot < 0):
                    continue
                found = True
                break
        if not found:
            return False
    return True


def base_tag(tag):
    if ":" in tag and tag[-1] in "sn":
        return tag[:-1]
    return tag


def check_mirror(parts, log):
    problems = []
    one = [p for p in parts if p["path"].startswith("Team1Half")]
    two = [p for p in parts if p["path"].startswith("Team2Half")]
    middle = [p for p in parts if p["path"].startswith("Middle")]
    if len(one) != len(two):
        problems.append("mirror: %d parts in team 1's half, %d in team 2's" % (len(one), len(two)))
    buckets = {}
    for q in two:
        key = (round(q["pos"][0], 2), round(q["pos"][1], 2), round(-q["pos"][2], 2))
        buckets.setdefault(key, []).append(q)
    unmatched = 0
    for p in one:
        key = (round(p["pos"][0], 2), round(p["pos"][1], 2), round(p["pos"][2], 2))
        match = None
        for q in buckets.get(key, []):
            if q["name"] == p["name"] and q["cls"] == p["cls"] and q["kind"] == p["kind"] and same_box(p, q) \
                    and q["color"] == p["color"] and q["material"] == p["material"] and q["collide"] == p["collide"] \
                    and base_tag(q["tag"]) == base_tag(p["tag"]) and q["path"].split("/")[1:] == p["path"].split("/")[1:]:
                match = q
                break
        if match is None:
            unmatched += 1
            if unmatched <= 5:
                problems.append("mirror: %s (%s) at %.2f, %.2f, %.2f has no reflection in team 2's half"
                                % (p["name"], p["path"], *p["pos"]))
        else:
            buckets[key].remove(match)
    selfless = [p for p in middle if not same_box(p, p)]
    for p in selfless[:5]:
        problems.append("mirror: %s on the mirror is not its own reflection" % p["name"])
    tags_one = {p["tag"] for p in one if ":" in p["tag"]}
    tags_two = {p["tag"] for p in two if ":" in p["tag"]}
    shared = tags_one & tags_two
    if shared:
        problems.append("mirror: pool tags shared by both halves: %s" % sorted(shared)[:4])
    log("mirror: %d parts in each half compared, %d without a reflection; %d on the mirror, %d not their own "
        "reflection; %d pool tags, %d shared" % (len(one), unmatched, len(middle), len(selfless), len(tags_one) + len(tags_two), len(shared)))
    return problems


def check_floating(parts, log):
    n = len(parts)
    grounded = [p["aabb"][0][1] <= 0.1 and math.hypot(p["pos"][0], p["pos"][2]) <= RADIUS + 4 for p in parts]
    boxes = [TBR.obb(p) for p in parts]
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
                if TBR.obb_overlap(boxes[i], boxes[j], TOUCH):
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
    loose = [parts[i] for i in range(n) if not seen[i]]
    log("floating: %d parts examined, %d not connected to the ground" % (n, len(loose)))
    return ["floating: %s (%s) at %.2f, %.2f, %.2f" % (p["name"], p["path"], *p["pos"]) for p in loose[:8]]


def check_cylinders(parts, log):
    cyl, bad = TBR.check_cylinders(parts)
    log("cylinders: %d examined, %d not round on Y/Z" % (len(cyl), len(bad)))
    return ["cylinder %s sized %s: its length must be X" % (p["name"], p["size"]) for p in bad[:5]]


def check_doorways(parts, doors, log):
    problems = []
    for d in doors:
        width = max(d["x1"] - d["x0"], d["z1"] - d["z0"])
        # A half-built doorway on the mirror (the other half is the reflection) is as wide as both.
        if abs(d["z0"]) < 1e-6 or abs(d["z1"]) < 1e-6:
            width = max(d["x1"] - d["x0"], 2 * (d["z1"] - d["z0"]))
        height = d["top"] - d["floor"]
        if width < max(DOOR_WIDTH, BOT_WIDTH) - 1e-6:
            problems.append("doorway %s only %.2f wide" % (d["name"], width))
        if height < DOOR_HEIGHT - 1e-6:
            problems.append("doorway %s only %.2f tall" % (d["name"], height))
        lo = (d["x0"] + 0.05, d["floor"] + 0.05, d["z0"] + 0.05)
        hi = (d["x1"] - 0.05, min(d["top"], d["floor"] + 9) - 0.05, d["z1"] - 0.05)
        inside = TBR.hits_box(parts, lo, hi, lambda p: p["collide"])
        if inside:
            problems.append("doorway %s blocked by %s" % (d["name"], ", ".join(sorted({p["name"] for p in inside}))))
    log("doorways: %d examined (4 wide / 7 tall for a player, 5 wide for a bot), %d problems" % (len(doors), len(problems)))
    return problems


def targets_of(info):
    out = []
    for i, o in enumerate(info["objectives"]):
        out.append(("objective " + "AB"[i], o))
    for p in info["power"]:
        out.append(("high ground " + p["name"], p["point"]))
    for s in info["loot"]:
        out.append(("loot " + s["name"], s["at"]))
    return out


def check_walk(walk, info, log, label="walk"):
    problems = []
    one = entries(walk, -1)
    two = entries(walk, 1)
    if not one or not two:
        return ["%s: no way in at a team's end (%d, %d entry cells)" % (label, len(one), len(two))], None, None
    d1 = walk.bfs(one)
    d2 = walk.bfs(two)
    reached1 = int((d1 >= 0).sum())
    unreached = []
    unequal = []
    for name, p in targets_of(info):
        # An objective is a ring 28 across: its floor is anywhere near its middle (B's middle is the
        # fountain itself).
        nodes = walk.near(p[0], p[1], p[2], reach=7.0 if name.startswith("objective") else 1.5, rise=0.8)
        a = [d1[n] for n in nodes if d1[n] >= 0]
        b = [d2[n] for n in nodes if d2[n] >= 0]
        if not a or not b:
            unreached.append(name)
            continue
        if name.startswith("objective") and abs(min(a) - min(b)) > 1:
            unequal.append("%s: %d vs %d steps" % (name, min(a), min(b)))
    for c in info["cover"]:
        nodes = walk.near(c[0], c[1], c[2], reach=1.0, rise=0.9)
        if not any(d1[n] >= 0 for n in nodes):
            unreached.append("cover spot (%.1f, %.1f, %.1f)" % c)
    log("%s: %d cells reachable from team 1's end; %d targets (objectives, high ground, loot) and %d cover spots, "
        "%d unreached; objectives %s" % (label, reached1, len(targets_of(info)), len(info["cover"]), len(unreached),
                                          "equal from both ends" if not unequal else "UNEQUAL"))
    problems += ["%s: cannot reach %s" % (label, t) for t in unreached[:10]]
    problems += ["%s: %s" % (label, u) for u in unequal]
    return problems, d1, d2


def check_traps(walk, log):
    """Nodes a bot can get into (from either end, walking and dropping) and not get back out of."""
    starts = entries(walk, -1) + entries(walk, 1)
    fwd = walk.bfs(starts)
    back = walk.bfs(starts, reverse=True)
    trapped = np.nonzero((fwd >= 0) & (back < 0))[0]
    problems = []
    if trapped.size:
        xs, zs, ys = walk.node_x[trapped], walk.node_z[trapped], walk.node_y[trapped]
        groups = cluster(list(zip(xs, ys, zs)), 3.0)
        for g in groups[:6]:
            problems.append("bots: a trap of %d cells round (%.1f, %.1f, %.1f)" % (len(g), *np.mean(np.array(g), axis=0)))
    log("bots: %d cells a bot can reach, %d it could not get back out of" % (int((fwd >= 0).sum()), trapped.size))
    return problems


def cluster(points, gap):
    """Single-linkage clusters of (x, y, z) points, `gap` apart on the flat."""
    pts = np.array(points)
    if len(pts) == 0:
        return []
    left = set(range(len(pts)))
    groups = []
    while left:
        seed = left.pop()
        group = [seed]
        queue = [seed]
        while queue:
            i = queue.pop()
            near = [j for j in left if math.hypot(pts[i][0] - pts[j][0], pts[i][2] - pts[j][2]) <= gap and abs(pts[i][1] - pts[j][1]) < 4]
            for j in near:
                left.discard(j)
                group.append(j)
                queue.append(j)
        groups.append([tuple(pts[i]) for i in group])
    groups.sort(key=len, reverse=True)
    return groups


def check_high_ground(walk, info, log):
    """Every power position: the ways up into it from the ground network -- edges from outside its region
    into it, grouped by the part the climber stands on just before (a stair's top step, a lintel, the
    bridge) and, within one part, by where they are (3 studs apart) -- number two or more, and with any
    one of them taken away it can still be reached."""
    problems = []
    starts = entries(walk, -1) + entries(walk, 1)
    whole = walk.bfs(starts)
    lines = []
    for p in info["power"]:
        x0, x1, z0, z1 = p["box"]
        inside = (walk.node_x >= x0 - 0.01) & (walk.node_x <= x1 + 0.01) & (walk.node_z >= z0 - 0.01) & (walk.node_z <= z1 + 0.01) \
            & (walk.node_y >= p["minY"])
        ground = walk.bfs(starts, banned=inside)
        into = inside[walk.dst] & ~inside[walk.src] & (ground[walk.src] >= 0)
        srcs, ends = walk.src[into], walk.dst[into]
        by_owner = {}
        for s_id, d_id in zip(srcs, ends):
            owner = int(walk.node_owner[s_id])
            if owner < 0:
                owner = int(walk.node_owner[d_id])
            by_owner.setdefault(owner, []).append(int(d_id))
        groups = []
        for owner, ids in by_owner.items():
            pts = [(float(walk.node_x[i]), float(walk.node_y[i]), float(walk.node_z[i])) for i in ids]
            for g in cluster(pts, 3.0):
                gset = {(round(q[0], 3), round(q[2], 3)) for q in g}
                groups.append((g, [i for i in ids if (round(float(walk.node_x[i]), 3), round(float(walk.node_z[i]), 3)) in gset]))
        point = walk.near(*p["point"], reach=1.5, rise=0.8)
        if not any(whole[n] >= 0 for n in point):
            problems.append("high ground %s cannot be reached at all" % p["name"])
            continue
        fragile = []
        for index, (g, ids) in enumerate(groups):
            # Take this way up away: ban the cells it arrives on.
            ban = np.zeros(walk.count, bool)
            ban[ids] = True
            left = walk.bfs(starts, banned=ban)
            if not any(left[n] >= 0 for n in point if not ban[n]):
                fragile.append(index)
        where = ["(%.0f, %.0f, %.0f)" % tuple(np.mean(np.array(g), axis=0)) for g, _ in groups]
        lines.append("%s %d [%s]" % (p["name"], len(groups), " ".join(where)))
        if len(groups) < 2:
            problems.append("high ground %s: %d way(s) up (%s)" % (p["name"], len(groups), ", ".join(where)))
        elif fragile:
            problems.append("high ground %s: cut off if the way up at %s goes" % (p["name"], where[fragile[0]]))
    log("high ground: %d positions; ways up: %s" % (len(info["power"]), "; ".join(lines)))
    return problems


def longest_clear(flags, step):
    best, run, best_end = 0.0, 0.0, 0
    for index, clear in enumerate(flags):
        if clear:
            run += step
            if run > best:
                best, best_end = run, index
        else:
            run = 0.0
    return best, best_end


def check_sightlines(cols, log, limit=SIGHT_LIMIT):
    problems = []
    lines = []
    y = EYE
    for lane, (xa, xb) in LANE_SIGHT.items():
        worst = (0.0, None, None)
        for x in np.arange(xa, xb + 0.01, 1.0):
            span = math.sqrt(max(0.0, RADIUS ** 2 - x * x))
            i = int(round((x - cols.x0) / cols.grid))
            ks = np.nonzero(np.abs(cols.xs) <= span)[0]
            zs = cols.xs[ks]
            lo, hi = cols.LO[:, i, ks], cols.HI[:, i, ks]
            flags = list(~((lo <= y) & (hi >= y)).any(axis=0))
            length, end = longest_clear(flags, cols.grid)
            if length > worst[0]:
                worst = (length, x, zs[end] - length)
        lines.append("%s %.0f (x %.0f from z %.0f)" % (lane, worst[0], worst[1], worst[2]))
        if worst[0] > limit:
            problems.append("sightline: %s lane has a clear eye-level line %.0f long down x = %.0f from z = %.0f"
                            % (lane, worst[0], worst[1], worst[2]))
    log("sightlines: longest eye-level line (%.1f up) straight down each lane: %s (limit %.0f)" % (y, "; ".join(lines), limit))
    return problems


def polyline_samples(points, step=1.0):
    out = []
    for a, b in zip(points, points[1:]):
        length = math.dist((a[0], a[2]), (b[0], b[2]))
        count = max(1, int(length / step))
        for i in range(count):
            t = i / count
            out.append(tuple(a[j] + (b[j] - a[j]) * t for j in range(3)))
    out.append(points[-1])
    return out


def check_cover(cols, info, log):
    problems = []
    lines = []
    r = int(math.ceil(COVER_REACH / cols.grid))
    offs = [(di, dk) for di in range(-r, r + 1) for dk in range(-r, r + 1) if math.hypot(di, dk) * cols.grid <= COVER_REACH]
    for name, points in sorted(info["routes"].items()):
        samples = polyline_samples(points, 1.0)
        covered = []
        for x, y, z in samples:
            i, k = cols.cell(x, z)
            found = False
            for di, dk in offs:
                a, b = i + di, k + dk
                if 0 <= a < cols.n and 0 <= b < cols.n:
                    lo, hi = cols.LO[:, a, b], cols.HI[:, a, b]
                    if ((lo <= y + 1.0) & (hi >= y + COVER_HIGH)).any():
                        found = True
                        break
            covered.append(found)
        gap, end = longest_clear([not c for c in covered], 1.0)
        lines.append("%s %.0f" % (name, gap))
        if gap > COVER_GAP:
            at = samples[end]
            problems.append("cover: route %s runs %.0f studs with nothing at crouch height within %.0f (to %.0f, %.0f)"
                            % (name, gap, COVER_REACH, at[0], at[2]))
    log("cover: longest stretch with no cover %.1f+ high within %.0f studs, per route: %s (limit %.0f)"
        % (COVER_HIGH, COVER_REACH, ", ".join(lines), COVER_GAP))
    return problems


def check_objectives(walk, cols, info, log, parts=None):
    problems = []
    a, b = info["objectives"]
    # Objective A stands ON the keep's floor: a ray straight down at its exact middle (the gallery's
    # measure) lands on a queryable top at its height. With every flagstone stopping 0.1 short of the
    # mirror, the middle was the crack between the halves and the ray found nothing ("floor NONE").
    # (B is the middle of the fountain, which it stands in by design.)
    if parts is not None:
        top = None
        for p in parts:
            lo, hi = p["aabb"]
            if p["query"] and lo[0] + 1e-3 < a[0] < hi[0] - 1e-3 and lo[2] + 1e-3 < a[2] < hi[2] - 1e-3 and hi[1] <= a[1] + 3:
                top = hi[1] if top is None else max(top, hi[1])
        if top is None or abs(top - a[1]) > 0.05:
            problems.append("objective A: a ray down at its middle finds %s, not the keep's floor at %.2f"
                            % ("nothing" if top is None else "a top at %.2f" % top, a[1]))
    for name, o in (("A", a), ("B", b)):
        if abs(o[2]) > 1e-6:
            problems.append("objective %s is off the mirror (z %.3f): not equidistant from the bases" % (name, o[2]))
        for base in (500.0, 900.0):
            d1 = math.dist(o, (0, 0, -base))
            d2 = math.dist(o, (0, 0, base))
            if abs(d1 - d2) > 1e-6:
                problems.append("objective %s: %.3f from base 1, %.3f from base 2" % (name, d1, d2))
        nodes = walk.near(o[0], o[1], o[2], reach=7.0, rise=0.3)
        if not nodes:
            problems.append("objective %s: no floor a body stands on within 7 of its middle at its height %.2f" % (name, o[1]))
        bad = []
        for step in range(24):
            ang = step * math.pi * 2 / 24
            px, pz = o[0] + math.cos(ang) * HILL_RADIUS * HILL_SPREAD, o[2] + math.sin(ang) * HILL_RADIUS * HILL_SPREAD
            if not walk.near(px, o[1], pz, reach=0.5, rise=0.6):
                bad.append("%.0f deg" % math.degrees(ang))
        if bad:
            problems.append("objective %s: BotService's hold points not standable at %s" % (name, ", ".join(bad[:6])))
    gap = math.dist(a, b)
    log("objectives: A (%.1f, %.2f, %.1f) and B (%.1f, %.2f, %.1f), %.0f apart, both on the mirror; 24 bot hold points "
        "round each checked" % (*a, *b, gap))
    return problems


def lane_polyline(info):
    south = info["lanes"]["S"]
    north = info["lanes"]["N"]
    return south + list(reversed(north))[1:]


def check_vehicles(cols, info, log):
    problems = []
    line = lane_polyline(info)
    samples = polyline_samples(line, 0.5)
    r = int(math.ceil(CAR_HALF / cols.grid))
    offs = [(di, dk) for di in range(-r, r + 1) for dk in range(-r, r + 1) if math.hypot(di, dk) * cols.grid <= CAR_HALF]
    blocked = []
    for x, _, z in samples:
        if math.hypot(x, z) > RADIUS + 6:
            continue
        i, k = cols.cell(x, z)
        for di, dk in offs:
            a, b = i + di, k + dk
            lo, hi = cols.LO[:, a, b], cols.HI[:, a, b]
            if ((lo < CAR_HIGH) & (hi > CAR_LOW)).any():
                blocked.append((cols.x0 + a * cols.grid, cols.z0 + b * cols.grid))
                break
    for p in blocked[:6]:
        problems.append("vehicles: the cut is blocked at (%.1f, %.1f)" % p)
    # Round the core, not through it: nowhere near the keep or objective A's ring.
    nearest = min(math.hypot(x, z) for x, _, z in samples)
    if nearest < HILL_RADIUS + CAR_HALF + 20:
        problems.append("vehicles: the cut passes %.0f from the keep's middle" % nearest)
    turns = []
    for a, b, c in zip(line, line[1:], line[2:]):
        u = (b[0] - a[0], b[2] - a[2])
        v = (c[0] - b[0], c[2] - b[2])
        cosang = (u[0] * v[0] + u[1] * v[1]) / (math.hypot(*u) * math.hypot(*v))
        turns.append(math.degrees(math.acos(max(-1, min(1, cosang)))))
    straights = [math.dist((a[0], a[2]), (b[0], b[2])) for a, b in zip(line, line[1:])]
    if max(turns) > 50:
        problems.append("vehicles: a bend of %.0f degrees in the cut" % max(turns))
    log("vehicles: the cut, %d samples of a corridor %.0f wide and %.1f..%.0f up: %d blocked; bends %s deg; straights %s; "
        "nearest the keep's middle %.0f" % (len(samples), CAR_HALF * 2, CAR_LOW, CAR_HIGH, len(blocked),
                                           "/".join("%.0f" % t for t in turns), "/".join("%.0f" % s for s in straights), nearest))
    return problems


def exposure(cols, walk, x, y, z, reach=60.0, stride=4):
    """How exposed a spot is to the other team: of the places a player could stand within `reach` (every
    `stride` cells, every storey) on the far side of the mirror from the spot (the side the other team
    holds; both sides for a spot on the mirror), how many see a body crouched on it (eye 4.5 up there,
    the spot's middle 2.5 up)."""
    side = 0 if abs(z) < 1e-6 else (1 if z > 0 else -1)
    far = (walk.node_z * side <= 0) if side else np.ones(walk.count, bool)
    sel = far & (np.abs(walk.node_x - x) <= reach) & (np.abs(walk.node_z - z) <= reach) \
        & (walk.node_i % stride == 0) & (walk.node_j % stride == 0)
    ex, ey, ez = walk.node_x[sel], walk.node_y[sel] + 4.5, walk.node_z[sel]
    d = np.hypot(ex - x, ez - z)
    keep = (d <= reach) & (d > 3)
    ex, ey, ez = ex[keep], ey[keep], ez[keep]
    ty = y + 2.5
    samples = np.linspace(0.02, 0.97, 160)
    px = ex[:, None] + (x - ex)[:, None] * samples[None, :]
    py = ey[:, None] + (ty - ey)[:, None] * samples[None, :]
    pz = ez[:, None] + (z - ez)[:, None] * samples[None, :]
    i = np.clip(np.rint((px - cols.x0) / cols.grid).astype(int), 0, cols.n - 1)
    k = np.clip(np.rint((pz - cols.z0) / cols.grid).astype(int), 0, cols.n - 1)
    lo = cols.LO[:, i, k]
    hi = cols.HI[:, i, k]
    blocked = ((lo <= py[None]) & (hi >= py[None])).any(axis=0).any(axis=1)
    return int((~blocked).sum())


RANK = {None: 0, "Common": 1, "Uncommon": 2, "Rare": 3, "Epic": 4, "Legendary": 5}


def check_loot(walk, cols, parts, info, log):
    problems = []
    lane = polyline_samples(lane_polyline(info), 1.0)
    tiers = {}
    for s in info["loot"]:
        x, y, z = s["at"]
        if not walk.near(x, y, z, reach=0.8, rise=0.35):
            problems.append("loot %s: no floor at (%.1f, %.2f, %.1f)" % (s["name"], x, y, z))
        clear = 2.4 if s["kind"] == "chest" else 1.5
        inside = TBR.hits_box(parts, (x - clear, y + 0.35, z - clear), (x + clear, y + 3.0, z + clear), lambda p: p["collide"])
        if inside:
            problems.append("loot %s: not clear (%s)" % (s["name"], ", ".join(sorted({p["name"] for p in inside}))))
        if any(math.hypot(x - lx, z - lz) < TBR_LANE_CLEAR for lx, _, lz in lane):
            problems.append("loot %s: on the vehicle route" % s["name"])
        if s["kind"] == "weapon":
            tiers.setdefault(s["floor"], []).append((exposure(cols, walk, x, y, z), s["name"]))
    means = {k: sum(e for e, _ in v) / len(v) for k, v in tiers.items()}
    order = sorted(means, key=lambda k: RANK.get(k, 0))
    for lower, higher in zip(order, order[1:]):
        if means[higher] <= means[lower]:
            problems.append("loot: %s spots (seen from %.0f places on average) are no more exposed than %s spots (%.0f)"
                            % (higher, means[higher], lower or "unfloored", means[lower]))
    log("loot: %d spots; weapon spots by rarity floor, seen from how many places a player can stand within 60: %s"
        % (len(info["loot"]), "; ".join("%s %.0f [%s]" % (k or "any", means[k], " ".join("%s %d" % (n, e) for e, n in tiers[k]))
                                        for k in order)))
    return problems


TBR_LANE_CLEAR = 7.0
HANG, BODY_UP, BODY_DOWN, POST = 4.4, 2.2, 3.0, 9.0


def check_ziplines(walk, cols, info, log):
    problems = []
    lines = []
    for z in info["zips"]:
        top_a = z["fromTop"]
        to = z["to"]
        top_b = (to[0], to[1] + POST, to[2])
        if top_b[1] >= top_a[1] - 4:
            problems.append("zipline %s: not a drop (%.1f to %.1f)" % (z["name"], top_a[1], top_b[1]))
        length = math.dist(top_a, top_b)
        hits = []
        for t in np.arange(0.0, 1.0001, 0.5 / length):
            px, py, pz = (top_a[i] + (top_b[i] - top_a[i]) * t for i in range(3))
            root = py - HANG
            lo_y, hi_y = root - BODY_DOWN, root + BODY_UP
            for dx, dz in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
                i, k = cols.cell(px + dx, pz + dz)
                if ((cols.LO[:, i, k] < hi_y) & (cols.HI[:, i, k] > lo_y)).any():
                    hits.append((px, py, pz))
                    break
            if hits:
                break
        if hits:
            problems.append("zipline %s: a rider hits something at (%.1f, %.1f, %.1f)" % (z["name"], *hits[0]))
        direction = [(top_b[i] - top_a[i]) / length for i in range(3)]
        handle = tuple(top_a[i] + direction[i] * 2 for i in range(3))
        reach = [n for n in walk.near(handle[0], handle[1] - 4, handle[2], reach=10, rise=6)]
        if not reach:
            problems.append("zipline %s: no floor within reach of the handle" % z["name"])
        # the foot: post, plate and mat on clear ground
        i, k = cols.cell(to[0], to[2])
        rr = int(3.5 / cols.grid)
        foot = cols.LO[:, i - rr:i + rr + 1, k - rr:k + rr + 1], cols.HI[:, i - rr:i + rr + 1, k - rr:k + rr + 1]
        if ((foot[0] < to[1] + POST) & (foot[1] > to[1] + 0.3)).any():
            problems.append("zipline %s: its foot at (%.1f, %.1f) is not on clear ground" % (z["name"], to[0], to[2]))
        lines.append("%s %.0f long, %.1f drop" % (z["name"], length, top_a[1] - top_b[1]))
    log("ziplines: %d (%s)" % (len(info["zips"]), "; ".join(lines)))
    return problems


DESTRUCT_WHOLE_LIMIT = 0
NEVER_TOPS = {"Keep", "Gatehouse", "Pit", "Gantry", "Bridge", "Crane", "SahurColossus", "RotKiosk", "Middle", "Paving"}
MUST_BREAK = {"Wall", "Sandbag", "Crate", "Container", "Barrier", "Tyre", "Drum", "WreckBody", "StallCounter", "StallPost",
              "SignPost", "RotColaMachine", "BrazierBowl", "Hedgehog"}


def check_destruct(rt, model, parts, log):
    lua = rt.lua
    service = rt.destruct()
    map_folder = lua.eval('Instance.new("Folder")')
    map_folder.Name = "Map"
    map_folder.Parent = lua.globals().workspace
    model.Parent = map_folder
    live = [p for p in model.GetDescendants(model).values() if p.IsA(p, "BasePart")]
    problems = []
    breakable = 0
    must = 0
    whole = []
    names_never = {"Foundation", "Paving", "GalleryFloor", "KeepStair", "KeepRamp", "KeepBalcony", "ScaffoldDeck", "ScaffoldStair",
                   "PitRim", "BermStep", "RimStair", "GateWalk", "GateTower", "GateStair", "GantryDeck", "GantryStair", "BridgeDeck",
                   "BridgePier", "KeepWall", "Plinth"}
    same = lua.eval("function(a, b) return rawequal(a, b) end")  # two lupa proxies of one table are not ==
    for part in live:
        chain = []
        node = part.Parent
        while node is not None and not same(node, model):
            chain.append(node.Name)
            node = node.Parent
        can = service.FromPart(part) is not None
        breakable += can
        if part.Name in MUST_BREAK and part.CanCollide:
            must += 1
            if not can:
                problems.append("destruct: %s (%s) does not break" % (part.Name, "/".join(reversed(chain))))
        # Oliver 2026-09-24: EVERYTHING breaks but spawns, the lobby, the storm and the map edges, so
        # the keep, the pit, the gantry, the bridge, every floor and stair break too (DestructibleService
        # ignores Destructible=false now). A solid piece that cannot is a fault, unless the service
        # itself calls it ground (a wide thin slab) or it is buried where no one can see it.
        if not can and part.CanCollide and part.Transparency < 1:
            whole.append("%s (%s)" % (part.Name, "/".join(reversed(chain))))
    pools = {}
    for p in parts:
        if ":" in p["tag"]:
            pools.setdefault(p["tag"], []).append(p)
    for tag, members in pools.items():
        lo = [min(m["aabb"][0][i] for m in members) for i in range(3)]
        hi = [max(m["aabb"][1][i] for m in members) for i in range(3)]
        if max(hi[0] - lo[0], hi[2] - lo[2]) > 90:
            problems.append("destruct: pool %s spans more than 90" % tag)
        parents = {m["path"] for m in members}
        if len(parents) > 1:
            problems.append("destruct: pool %s is split across %s (a pool is one parent's children)" % (tag, sorted(parents)))
    log("destruct: %d parts examined, %d breakable, %d that must break, %d tagged pools; %d solid pieces kept whole%s"
        % (len(live), breakable, must, len(pools), len(whole), (" (e.g. %s)" % ", ".join(whole[:4])) if whole else ""))
    if len(whole) > DESTRUCT_WHOLE_LIMIT:
        problems.append("destruct: %d solid pieces never break (limit %d), e.g. %s" % (len(whole), DESTRUCT_WHOLE_LIMIT, ", ".join(whole[:6])))
    if must < 100:
        problems.append("destruct: only %d breakable pieces found to check" % must)
    model.Parent = None
    return problems


# ------------------------------------------------------------------------------------------------
# Gun emplacements
# ------------------------------------------------------------------------------------------------

EMPLACEMENTS = (8, 12)
BASE_DISTANCE = 432.0  # ModeTeams: BASE_FRACTION 0.72 of an arena radius of at least 600
GUN_REACH = 160.0      # how far down a lane a gun's line is counted
LANE_SHARE = 0.4       # the most of any one lane a gun may see
LANE_END = 25.0        # the stretch inside each team's way in that no gun may see from closer than NEAR_END
NEAR_END = 100.0


def clear_rays(cols, eye, targets, step=0.4, start=0.8, chunk=600):
    """For each target, whether the straight line from `eye` to it is clear of every solid in the
    columns (sampled every `step`; outside the columns' extent nothing is known, so nothing blocks)."""
    eye = np.asarray(eye, float)
    targets = np.asarray(targets, float).reshape(-1, 3)
    out = np.ones(len(targets), bool)
    lim = -cols.x0 - 0.5
    for a in range(0, len(targets), chunk):
        T = targets[a:a + chunk]
        D = T - eye
        L = np.linalg.norm(D, axis=1)
        M = max(2, int(math.ceil(L.max() / step)))
        s = np.linspace(0, 1, M)[None, :]
        t = s * L[:, None]
        valid = (t >= start) & (t <= L[:, None] - 0.3)
        px = eye[0] + D[:, 0, None] * s
        py = eye[1] + D[:, 1, None] * s
        pz = eye[2] + D[:, 2, None] * s
        valid &= (np.abs(px) <= lim) & (np.abs(pz) <= lim)
        i = np.clip(np.rint((px - cols.x0) / cols.grid).astype(int), 0, cols.n - 1)
        k = np.clip(np.rint((pz - cols.z0) / cols.grid).astype(int), 0, cols.n - 1)
        hit = np.zeros(i.shape, bool)
        for layer in range(cols.K):
            lo, hi = cols.LO[layer, i, k], cols.HI[layer, i, k]
            hit |= (lo <= py) & (hi >= py)
        out[a:a + chunk] = ~(hit & valid).any(axis=1)
    return out


def in_arc(base, look, points, arc):
    d = np.asarray(points, float)[:, [0, 2]] - np.array([base[0], base[2]])
    n = np.linalg.norm(d, axis=1)
    f = np.array([look[0], look[2]])
    f = f / np.linalg.norm(f)
    cos = (d @ f) / np.maximum(n, 1e-9)
    return cos >= math.cos(math.radians(arc / 2)) - 1e-9


def spawn_targets(side):
    out = [(x, y, side * BASE_DISTANCE) for x in (-60, -30, 0, 30, 60) for y in (2.0, 5.0)]
    out += [(x, y, side * (BASE_DISTANCE - 40)) for x in (-40, 0, 40) for y in (2.0, 5.0)]
    return out


def lanes_of(info):
    """Each lane whole, team 1's way in to team 2's: the two halves' routes joined, and the cut."""
    out = {}
    for name, pts in info["routes"].items():
        if name.endswith("S") and name[:-1] + "N" in info["routes"]:
            south, north = pts, info["routes"][name[:-1] + "N"]
            out[name[:-1]] = south + list(reversed(north))
    out["Cut"] = lane_polyline(info)
    return out


def emplacement_rows(parts):
    return [p for p in parts if p["name"] == "GunEmplacement"]


def check_emplacements(rt, model, parts, cols, walk, info, log, arc=None, eye=None):
    """The gun emplacements: 8..12, the same number a half and each the other's reflection, tagged,
    invisible and non-colliding; each on a flat floor both teams can walk to, with room round it,
    cover beside or behind the gunner, neither base in any line from the gunner's eye, a real field
    of fire onto the lanes but none of a lane's way in and no more than LANE_SHARE of any lane, and
    a way in for the other team that the gun cannot see."""
    problems = []
    arc = arc or float(rt.bg.GunArc)
    eye_up = eye or float(rt.bg.GunEye)
    emps = emplacement_rows(parts)
    tagged = list(rt.lua.globals().taggedIn(model, rt.bg.EmplacementTag).values())
    if len(tagged) != len(emps) or any(n != "GunEmplacement" for n in tagged):
        problems.append("emplacements: %d parts, %d tagged %s" % (len(emps), len(tagged), rt.bg.EmplacementTag))
    if not EMPLACEMENTS[0] <= len(emps) <= EMPLACEMENTS[1]:
        problems.append("emplacements: %d, want %d..%d" % (len(emps), *EMPLACEMENTS))
    if len(info.get("emplacements", [])) != len(emps):
        problems.append("emplacements: info lists %d, %d built" % (len(info.get("emplacements", [])), len(emps)))
    one = [p for p in emps if p["pos"][2] < -0.5]
    two = [p for p in emps if p["pos"][2] > 0.5]
    if len(one) != len(two) or len(one) + len(two) != len(emps):
        problems.append("emplacements: %d in team 1's half, %d in team 2's, %d on the mirror"
                        % (len(one), len(two), len(emps) - len(one) - len(two)))
    for p in emps:
        x, y, z = p["pos"]
        if p["collide"] or p["query"] or p["transparency"] < 1:
            problems.append("emplacement at (%.1f, %.1f, %.1f): not invisible and non-colliding" % (x, y, z))
        look = tuple(-c for c in p["axes"][2])
        twin = [q for q in emps if math.dist(q["pos"], (x, y, -z)) < 0.05
                and math.dist(tuple(-c for c in q["axes"][2]), (look[0], look[1], -look[2])) < 1e-3]
        if not twin:
            problems.append("emplacement at (%.1f, %.1f, %.1f): no mirror twin" % (x, y, z))
    d = {s: walk.bfs(entries(walk, s)) for s in (-1, 1)}
    rows = []
    lane_pts = {name: polyline_samples(pts, 1.0) for name, pts in lanes_of(info).items()}
    for p in emps:
        x, y, z = p["pos"]
        look = tuple(-c for c in p["axes"][2])
        where = "emplacement at (%.1f, %.1f, %.1f)" % (x, y, z)
        e = (x, y + eye_up, z)
        # On a floor: a flat top under the base and a stud either side, and a body can stand by it
        # and get there from both ends.
        for dx, dz in ((0, 0), (0.9, 0), (-0.9, 0), (0, 0.9), (0, -0.9)):
            i, k = cols.cell(x + dx, z + dz)
            tops = cols.HI[:, i, k]
            ok = np.isfinite(tops) & (tops >= y - 0.25) & (tops <= y + 0.1) & (cols.NY[:, i, k] >= 0.95)
            if not ok.any():
                problems.append(where + ": no floor under it at (%.1f, %.1f)" % (x + dx, z + dz))
                break
        near = walk.near(x, y, z, reach=3.0, rise=1.0)
        if not near or not all(any(d[s][n] >= 0 for n in near) for s in (-1, 1)):
            problems.append(where + ": nowhere to stand by it that both teams can walk to")
        # Room for the gun and its gunner: nothing solid within 2.2 of it, from the floor to 5.5 up.
        i0, k0 = cols.cell(x, z)
        r = int(math.ceil(2.2 / cols.grid))
        crowded = False
        for di in range(-r, r + 1):
            for dk in range(-r, r + 1):
                if math.hypot(di, dk) * cols.grid > 2.2:
                    continue
                lo, hi = cols.LO[:, i0 + di, k0 + dk], cols.HI[:, i0 + di, k0 + dk]
                if ((lo < y + 5.5) & (hi > y + 0.3)).any():
                    crowded = True
        if crowded:
            problems.append(where + ": something solid within 2.2 of the gun")
        # Cover beside or behind the gunner: of 13 directions round the back half, how many meet
        # something within 4.5 at both 1 and 2 studs up.
        fx, fz = look[0], look[2]
        n = math.hypot(fx, fz)
        fx, fz = fx / n, fz / n
        covered = 0
        for a in range(13):
            ang = math.radians(90 + a * 15)
            dx, dz = fx * math.cos(ang) - fz * math.sin(ang), fx * math.sin(ang) + fz * math.cos(ang)
            both = True
            for up in (1.0, 2.0):
                if clear_rays(cols, (x, y + up, z), [(x + dx * 4.5, y + up, z + dz * 4.5)], step=0.25, start=0.3)[0]:
                    both = False
            covered += both
        if covered < 4:
            problems.append(where + ": no cover beside or behind the gunner (%d of 13 ways covered)" % covered)
        # Neither team's base in any line from the gunner's eye.
        for side in (-1, 1):
            if clear_rays(cols, e, spawn_targets(side)).any():
                problems.append(where + ": sees team %d's base" % (1 if side < 0 else 2))
        # Its field of fire: the lanes in its arc, within reach, that it can see.
        total, longest, shares = 0, 0.0, []
        for name, pts in lane_pts.items():
            P = np.array(pts, float)
            dist = np.hypot(P[:, 0] - x, P[:, 2] - z)
            cand = in_arc((x, y, z), look, P, arc) & (dist <= GUN_REACH) & (dist > 2)
            vis = np.zeros(len(P), bool)
            if cand.any():
                vis[cand] = clear_rays(cols, e, P[cand] + np.array([0, 3.0, 0]))
            total += int(vis.sum())
            if vis.any():
                longest = max(longest, float(dist[vis].max()))
            share = vis.mean()
            if share > 0:
                shares.append("%s %.0f%%" % (name, 100 * share))
            if share > LANE_SHARE:
                problems.append(where + ": sees %.0f%% of the %s lane" % (100 * share, name))
            ends = int(LANE_END)
            near_end = vis & (dist <= NEAR_END)
            if near_end[:ends].any() or near_end[-ends:].any():
                problems.append(where + ": sees into the %s lane's way in" % name)
        if total < 12 or longest < 35:
            problems.append(where + ": no real field of fire (%d lane points seen, the furthest %.0f)" % (total, longest))
        # A covered way in for the other team: from its end of the disc to the gun, never through a
        # place the gun (in its arc, within 40) can see.
        enemy = 1 if z < 0 else -1
        sel = np.nonzero((np.abs(walk.node_x - x) <= 40) & (np.abs(walk.node_z - z) <= 40))[0]
        pts = np.stack([walk.node_x[sel], walk.node_y[sel], walk.node_z[sel]], axis=1)
        cand = in_arc((x, y, z), look, pts, arc) & (np.hypot(pts[:, 0] - x, pts[:, 2] - z) > 3.5)
        banned = np.zeros(walk.count, bool)
        if cand.any():
            vis = clear_rays(cols, e, pts[cand] + np.array([0, 2.6, 0]))
            banned[sel[cand][vis]] = True
        goal = walk.near(x, y, z, reach=3.5, rise=1.2)
        reach = walk.bfs(entries(walk, enemy), banned=banned)
        if not any(reach[g] >= 0 for g in goal):
            problems.append(where + ": no covered way in for the other team")
        facing_s = "+X" if fx > 0.7 else "-X" if fx < -0.7 else "+Z" if fz > 0.7 else "-Z"
        rows.append("(%.0f, %.1f, %.0f) %s sees %d lane pts to %.0f [%s]" % (x, y, z, facing_s, total, longest, " ".join(shares)))
    log("emplacements: %d (%d a half), %d tagged; team 1's half: %s" % (len(emps), len(one), len(tagged),
                                                                       "; ".join(r for r, p in zip(rows, emps) if p["pos"][2] < 0)))
    return problems


ZONE_BELOW, ZONE_HEIGHT = 6.0, 22.0  # ObjectiveZone.Below / DefaultHeight
ZONE_ENTRANCES = 3        # distinct ways into each capture area, one of them high
ZONE_HIGH = 4.0           # a high way in crosses the boundary this far over the objective's floor
ZONE_COVER = (4, 4)       # cover spots inside the ring, and within ZONE_EDGE outside it
ZONE_EDGE = 8.0
ZONE_MARKS = 7            # of 12 30-degree sectors round each ring, how many carry its marks at least (the
                          # keep's corners, its ramp and scaffold stair stand across the rest of A's)
ZONE_TIME = 0.03          # the two teams' walk to a zone may differ by this share


def check_zones(rt, parts, cols, walk, info, log):
    """The objective capture areas, the ring KOTH's capture radius draws round each objective: marked
    out on the floor (CaptureRing marks round it), cover inside it and at its edge, at least three
    separate ways in from the walk graph (one of them high), none of which alone keeps either team
    out, no spawn in sight of its middle, no gun emplacement that sees its middle, and both teams
    the same walk from their end of the arena."""
    problems = []
    R = HILL_RADIUS
    arc = float(rt.bg.GunArc)
    emps = emplacement_rows(parts)
    x, y, z = walk.node_x, walk.node_y, walk.node_z
    d = {s: walk.bfs(entries(walk, s)) for s in (-1, 1)}
    notes = []
    for name, o in zip("AB", info["objectives"]):
        where = "zone %s" % name
        # The ring's marks: on the ring (within 1.2 of R, flat), round most of it.
        sectors = set()
        for p in parts:
            if p["name"] == "CaptureRing":
                px, _, pz = p["pos"]
                r = math.hypot(px - o[0], pz - o[2])
                if abs(r - R) <= 1.2:
                    sectors.add(int((math.degrees(math.atan2(pz - o[2], px - o[0])) % 360) // 30))
        if len(sectors) < ZONE_MARKS:
            problems.append("%s: its ring is marked in %d of 12 sectors, want %d" % (where, len(sectors), ZONE_MARKS))
        # Cover: the cover spots inside the ring, and just outside it.
        flat = [math.hypot(c[0] - o[0], c[2] - o[2]) for c in info["cover"]]
        inner = sum(1 for f in flat if f <= R)
        edge = sum(1 for f in flat if R < f <= R + ZONE_EDGE)
        if inner < ZONE_COVER[0] or edge < ZONE_COVER[1]:
            problems.append("%s: %d cover spots inside, %d at its edge, want %d and %d" % (where, inner, edge, *ZONE_COVER))
        # The ways in: walk edges from just outside the ring (within ZONE_EDGE) to inside it, their
        # inner ends grouped where they touch (within 2); a way in is a group at least 3 wide.
        fr = np.hypot(x - o[0], z - o[2])
        dy = y - o[1]
        inside = (fr <= R) & (dy >= -ZONE_BELOW) & (dy <= ZONE_HEIGHT)
        outside = ~inside & (fr <= R + ZONE_EDGE)
        cross = inside[walk.dst] & outside[walk.src]
        gates = np.unique(walk.dst[cross])
        root = {int(g): int(g) for g in gates}

        def find(a):
            while root[a] != a:
                root[a] = root[root[a]]
                a = root[a]
            return a
        pts = np.stack([x[gates], y[gates], z[gates]], axis=1)
        for i in range(len(gates)):
            near = np.nonzero(np.linalg.norm(pts[i + 1:] - pts[i], axis=1) <= 2.0)[0]
            for j in near:
                root[find(int(gates[i]))] = find(int(gates[i + 1 + j]))
        groups = {}
        for g in gates:
            groups.setdefault(find(int(g)), []).append(int(g))
        ways = []
        for members in groups.values():
            m = np.array(members)
            span = np.max(np.linalg.norm(pts[np.searchsorted(gates, m)][:, None] - pts[np.searchsorted(gates, m)][None], axis=2))
            if span >= 3.0:
                ways.append(m)
        high = [m for m in ways if float(np.mean(y[m])) >= o[1] + ZONE_HIGH]
        if len(ways) < ZONE_ENTRANCES or not high:
            problems.append("%s: %d ways in (%d high), want %d with one high" % (where, len(ways), len(high), ZONE_ENTRANCES))
        # No one way in keeps a team out: each team still reaches the middle with any one of them shut.
        middle = walk.near(o[0], o[1], o[2], reach=6.0, rise=1.0)
        for s in (-1, 1):
            if not any(d[s][n] >= 0 for n in middle):
                problems.append("%s: team %d cannot walk to its middle" % (where, 1 if s < 0 else 2))
                continue
            for m in ways:
                banned = np.zeros(walk.count, bool)
                banned[m] = True
                dd = walk.bfs(entries(walk, s), banned=banned)
                if not any(dd[n] >= 0 for n in middle):
                    problems.append("%s: one way in (at %.0f, %.1f, %.0f) is team %d's only way to its middle"
                                    % (where, float(np.mean(x[m])), float(np.mean(y[m])), float(np.mean(z[m])), 1 if s < 0 else 2))
                    break
        # The same walk for both teams (the depth of the walk graph's search to the middle: time).
        t = [min((d[s][n] for n in middle if d[s][n] >= 0), default=-1) for s in (-1, 1)]
        if min(t) > 0 and abs(t[0] - t[1]) > ZONE_TIME * max(t):
            problems.append("%s: team 1 walks %d steps to it, team 2 %d" % (where, t[0], t[1]))
        # No spawn in sight of its middle, no gun emplacement seeing its middle.
        eyes = [(o[0] + dx, o[1] + 5.2, o[2] + dz) for dx, dz in ((0, 0), (6, 0), (-6, 0), (0, 6), (0, -6))]
        for s in (-1, 1):
            for e in eyes:
                if clear_rays(cols, e, spawn_targets(s)).any():
                    problems.append("%s: team %d's spawn in sight from (%.0f, %.1f, %.0f)" % (where, 1 if s < 0 else 2, *e))
                    break
        for p in emps:
            ex, ey, ez = p["pos"]
            gun = (ex, ey + float(rt.bg.GunEye), ez)
            look = tuple(-c for c in p["axes"][2])
            spots = [(o[0] + dx, o[1] + 1.5, o[2] + dz) for dx in (-4, 0, 4) for dz in (-4, 0, 4)]
            spots = [q for q, ok in zip(spots, in_arc(gun, look, spots, arc)) if ok]
            if spots and clear_rays(cols, gun, spots).any():
                problems.append("%s: the emplacement at (%.1f, %.1f, %.1f) sees its middle" % (where, ex, ey, ez))
        notes.append("%s %d ways in (%d high), cover %d+%d, ring %d/12, walk %s" % (name, len(ways), len(high), inner, edge, len(sectors), t))
    log("zones: " + "; ".join(notes) + ", %d problems" % len(problems))
    return problems


def check_zfight(rt, model, log):
    return TBR.check_zfight(rt, model, log)


def local_rows(parts):
    return [(p["name"], p["cls"], p["size"], p["pos"], p["axes"], p["color"]) for p in parts]


# ------------------------------------------------------------------------------------------------
# Build on a mock town
# ------------------------------------------------------------------------------------------------

SMOKE = r"""
CF.PointToObjectSpace = CF.PointToObjectSpace or function(c, v) return c:Inverse() * v end
function smoke(BG, mode)
    local out = {}
    local function fail(msg) table.insert(out, msg) end
    local ws = Instance.new("Workspace")
    workspace = ws
    rawget(ws, "props").Terrain = Instance.new("Terrain")
    local map = Instance.new("Folder")
    map.Name = "Map"
    map.Parent = ws
    local all = {}
    local function inst(class, name, parent)
        local i = Instance.new(class)
        i.Name = name
        i.Parent = parent
        return i
    end
    local function part(name, parent, size, cf)
        local p = inst("Part", name, parent)
        p.Size = size
        p.CFrame = cf
        table.insert(all, p)
        return p
    end
    local centre = Vector3.new(300, 0, -200)
    local town = inst("Model", "Town", map)
    town:SetAttribute("TownName", "Rotville")
    local shop = inst("Model", "Building", town)
    rawget(shop, "props").Extents = Vector3.new(30, 20, 24)
    part("Wall", shop, Vector3.new(30, 12, 1), CFrame.new(centre + Vector3.new(40, 6, 30)))
    local far = inst("Model", "Building", town)
    rawget(far, "props").Extents = Vector3.new(30, 20, 24)
    part("Wall", far, Vector3.new(30, 12, 1), CFrame.new(centre + Vector3.new(400, 6, 0)))
    -- THE ROADS. A town street along X straight through the middle, 600 long, as MapDecor.Street lays
    -- it: asphalt, a kerb and a pavement each side, dashes down the middle, every piece non-queryable.
    local function clutter(p) p.CanQuery = false p.CanCollide = false return p end
    local street = clutter(part("Asphalt", town, Vector3.new(600, 0.4, 18), CFrame.new(centre + Vector3.new(0, 0.2, 12))))
    for _, side in ipairs({ -1, 1 }) do
        clutter(part("Kerb", town, Vector3.new(600, 0.56, 0.8), CFrame.new(centre + Vector3.new(0, 0.22, 12 + side * 9.4))))
        clutter(part("Pavement", town, Vector3.new(600, 0.41, 4.2), CFrame.new(centre + Vector3.new(0, 0.145, 12 + side * 11.9))))
    end
    for k = -11, 11 do
        clutter(part("Dash", town, Vector3.new(6, 0.07, 0.6), CFrame.new(centre + Vector3.new(k * 18 + 2, 0.435, 12))))
    end
    -- The square's crossroads 83 south of the middle, its traffic lights' heads and arms non-queryable
    -- (ClearSite's old box query took the queryable poles and left the heads in the air), and a street
    -- lamp: the post queryable, its arm and lamp not, all three one tag group.
    local junction = clutter(part("JunctionAsphalt", town, Vector3.new(18, 0.4, 18), CFrame.new(centre + Vector3.new(0, 0.2, -83))))
    local signalPole = part("SignalPole", town, Vector3.new(15.5, 0.9, 0.9), CFrame.new(centre + Vector3.new(12, 7.75, -95)))
    local signalHead = clutter(part("SignalHousing", town, Vector3.new(1.5, 4.3, 1.2), CFrame.new(centre + Vector3.new(6, 12, -95))))
    local lampPost = part("LampPost", town, Vector3.new(14, 0.7, 0.7), CFrame.new(centre + Vector3.new(-60, 7, 30)))
    local lampArm = clutter(part("LampArm", town, Vector3.new(0.35, 0.35, 3.4), CFrame.new(centre + Vector3.new(-60, 13.6, 31.7))))
    for _, p in ipairs({ lampPost, lampArm }) do p:SetAttribute("Destructible", "Lamp:D7") end
    local theme = inst("Model", "Theme", town)
    theme:SetAttribute("FootingGroup", true)
    local piece = inst("Model", "SetPiece", theme)
    rawget(piece, "props").Extents = Vector3.new(40, 20, 40)
    part("Statue", piece, Vector3.new(4, 10, 4), CFrame.new(centre + Vector3.new(-30, 5, -20)))
    local landmarks = inst("Model", "Landmarks", map)
    local tower = inst("Model", "Tower", landmarks)
    rawget(tower, "props").Extents = Vector3.new(140, 60, 120)
    part("TowerWall", tower, Vector3.new(10, 40, 10), CFrame.new(centre + Vector3.new(120, 20, 60)))
    local roads = inst("Model", "Roads", map)
    -- A road out of town from the square's north mouth, 144 out (as RoadNetwork starts one), running on
    -- north: its slab and edge lines are cut square at the apron's edge, the rest kept.
    local mouthRoad = part("RoadSurface", roads, Vector3.new(18, 0.8, 156), CFrame.new(centre + Vector3.new(0, 0, 144 + 78)))
    local mouthEdges = {}
    for _, side in ipairs({ -1, 1 }) do
        table.insert(mouthEdges, part("RoadEdge", roads, Vector3.new(0.4, 0.07, 156), CFrame.new(centre + Vector3.new(side * 8.2, 0.435, 144 + 78))))
    end
    -- A road that only passes by, 137 west of the middle at its nearest (clear of the disc and its
    -- margin): kept whole, but its lamp on the arena's side of it (133 out, in the apron) goes.
    local road = part("RoadSurface", roads, Vector3.new(18, 0.8, 600), CFrame.new(centre + Vector3.new(-200, 0, 0)))
    local innerLamp = part("LampPost", roads, Vector3.new(14, 0.7, 0.7), CFrame.new(centre + Vector3.new(-187.2, 7, 20)))
    innerLamp:SetAttribute("Destructible", "Lamp:D8")
    local outerLamp = part("LampPost", roads, Vector3.new(14, 0.7, 0.7), CFrame.new(centre + Vector3.new(-212.8, 7, -20)))
    outerLamp:SetAttribute("Destructible", "Lamp:D9")
    -- A road out of the square's south mouth as RoadNetwork lays one: straight to 186 out in slabs
    -- shorter than the road is wide (as it lays them on a grade, each along its LookVector), then a bend
    -- (its Curve model: a block and two wedges a piece, edge chords) turning west to run on 216 south,
    -- the bend crossing the apron's edge. Cut at a joint of the bend and finished there.
    for k = 0, 5 do
        local z0 = -144 - k * 7
        local at = centre + Vector3.new(0, 0, z0 - 3.5)
        part("RoadSurface", roads, Vector3.new(18, 0.8, 7), CFrame.lookAt(at, at + Vector3.new(0, 0, -1)))
    end
    local bend = inst("Model", "Curve", roads)
    do
        local cx, cz, R, sweep, count = -30, -186, 30, -math.pi / 2, 9
        local step, delta = sweep / count, math.abs(sweep / count) / 2
        for index = 1, count do
            local mid = step * (index - 0.5)
            local o = Vector3.new(math.cos(mid), 0, math.sin(mid))
            local side = Vector3.new(-math.sin(mid), 0, math.cos(mid))
            local at = centre + Vector3.new(cx, 0, cz) + o * (R * math.cos(delta))
            part("RoadCurve", bend, Vector3.new(2 * (R - 9) * math.sin(delta), 0.8, 18 * math.cos(delta)), CFrame.lookAt(at, at + o))
            for _, hand in ipairs({ -1, 1 }) do
                local w = Instance.new("WedgePart")
                w.Name = "RoadCurve"
                w.Parent = bend
                w.Size = Vector3.new(0.8, 18 * math.sin(delta), 18 * math.cos(delta))
                local wat = centre + Vector3.new(cx, 0, cz) + o * (R * math.cos(delta) + 4) + side * (hand * R * math.sin(delta))
                w.CFrame = CFrame.lookAt(wat, wat + o)
                table.insert(all, w)
            end
            for _, edge in ipairs({ -1, 1 }) do
                local r = R + edge * 8.2
                local a0, a1 = step * (index - 1), step * index
                local from = centre + Vector3.new(cx + math.cos(a0) * r, 0.435, cz + math.sin(a0) * r)
                local to = centre + Vector3.new(cx + math.cos(a1) * r, 0.435, cz + math.sin(a1) * r)
                part("RoadEdge", bend, Vector3.new(0.4, 0.07, (to - from).Magnitude - 0.1), CFrame.lookAt((from + to) / 2, to))
            end
        end
    end
    -- A road coming in from the north-east, 60 east of the middle, stopping 150 out, laid in slabs 7
    -- long and 18 wide: it crosses the apron's edge 191 out and is ended there like any other.
    local slabRoad = {}
    for k = 0, 15 do
        local at = centre + Vector3.new(60, 0, 150 + k * 7 + 3.5)
        table.insert(slabRoad, part("RoadSurface", roads, Vector3.new(18, 0.8, 7), CFrame.lookAt(at, at + Vector3.new(0, 0, 1))))
    end
    -- A road heading in from the east 91..109 south of the middle, stopping 182 east (204 out, short of the
    -- apron's edge, the junction it ran into gone with the site): drawn on to the edge and ended there.
    local stubAt = centre + Vector3.new(241, 0, -100)
    local stubRoad = part("RoadSurface", roads, Vector3.new(18, 0.8, 118), CFrame.lookAt(stubAt, stubAt + Vector3.new(1, 0, 0)))
    -- A road ending 1.6 past the cut (196 out here) (the bend it runs on into is not a straight: nothing more of it
    -- is a stretch), 60 west of the middle going north: still ended at the cut.
    local shortAt = centre + Vector3.new(-60, 0, 196 + 0.8)
    local shortRoad = part("RoadSurface", roads, Vector3.new(18, 0.8, 1.6), CFrame.lookAt(shortAt, shortAt + Vector3.new(0, 0, 1)))
    local westAt = centre + Vector3.new(-180, 0, -216)
    local westRoad = part("RoadSurface", roads, Vector3.new(18, 0.8, 300), CFrame.lookAt(westAt, westAt + Vector3.new(-1, 0, 0)))
    local vehicles = inst("Model", "Vehicles", map)
    local car = inst("Model", "Car", vehicles)
    rawget(car, "props").Extents = Vector3.new(9, 6, 17)
    part("Body", car, Vector3.new(8, 3, 16), CFrame.new(centre + Vector3.new(-60, 1.5, 40)))
    local wilds = inst("Model", "Wilds", map)
    local woods = inst("Model", "Woods", wilds)
    woods:SetAttribute("FootingSkip", true)
    rawget(woods, "props").Extents = Vector3.new(600, 40, 600)
    local tree = inst("Model", "Tree", woods)
    rawget(tree, "props").Extents = Vector3.new(8, 20, 8)
    part("Trunk", tree, Vector3.new(2, 14, 2), CFrame.new(centre + Vector3.new(90, 7, -70)))
    local base = inst("Model", "TeamBase1", map)
    rawget(base, "props").Extents = Vector3.new(90, 20, 90)
    part("Wall", base, Vector3.new(10, 8, 1), CFrame.new(centre + Vector3.new(0, 4, -260)))
    local loot = inst("Folder", "Loot", ws)
    local pickup = part("GroundWeapon", loot, Vector3.new(2, 1, 2), CFrame.new(centre + Vector3.new(10, 0.5, 10)))
    function ws:GetPartBoundsInBox() local list = {} for _, p in ipairs(all) do if p.Parent then table.insert(list, p) end end return list end
    function ws:FindFirstChild(name) for _, kid in ipairs(rawget(self, "kids")) do if kid.Name == name then return kid end end end
    function ws:Raycast() return nil end
    OverlapParams = { new = function() return {} end }
    RaycastParams = { new = function() return {} end }
    local flatCalls = {}
    MODULES.MapTerrain.FlattenPad = function(site, size, options)
        table.insert(flatCalls, options.height)
        if mode == "pad" and #flatCalls == 1 then return nil, "pad" end
        if mode == "bumpy" or mode == "flatstand" then return nil, "road" end
        if mode == "pad" then return options.height end
        return 3.25
    end
    MODULES.MapTerrain.PadAt = function() return 0.5 end
    MODULES.MapTerrain.PadCost = function() if mode == "bumpy" then return 1, 9, 5 end return 2.0, 2.8, 2.4 end
    MODULES.MapTerrain.InRiver = function(river, x, z) return mode == "river" and math.abs(x - 350) < 5 end
    local zips = {}
    MODULES.ZiplineService = { Create = function(parent, from, to, fromTop)
        table.insert(zips, { parent = parent, to = to, fromTop = fromTop })
        local m = Instance.new("Model"); m.Name = "Zipline"; m.Parent = parent; return m end }
    local toTeamOne = Vector3.new(math.cos(0.6), 0, math.sin(0.6))
    local at = CFrame.lookAt(centre, centre + toTeamOne)
    local info, why = BG.Build(at, { map = map, river = mode == "river" and {} or nil }, 77)
    out.why = why
    if mode == "river" then
        if info then fail("built across a river") end
        if why ~= "river" then fail("refused for " .. tostring(why) .. ", not the river") end
        return out
    end
    if mode == "bumpy" then
        if info then fail("built on ground it could not level (1..9)") end
        return out
    end
    if not info then fail("not built: " .. tostring(why)) return out end
    local want = ({ flat = 3.25, pad = 0.5, flatstand = 2.4 })[mode]
    if math.abs(info.height - want) > 1e-6 then fail(("stands at %.2f, want %.2f"):format(info.height, want)) end
    if mode == "pad" and flatCalls[2] ~= 0.5 then fail("the retry did not ask for the town's pad level") end
    if info.model.Parent ~= map then fail("the battleground is not in the map") end
    if shop.Parent then fail("a building in the disc was left standing") end
    if not far.Parent then fail("a building far outside the apron was removed") end
    if piece.Parent then fail("a themes set piece in the disc was left standing") end
    if not theme.Parent then fail("the town's whole themes group went") end
    if not tower.Parent then fail("a landmark too big to clear was removed") end
    if not road.Parent then fail("a road passing by, clear of the disc, was removed") end
    if road.Size.Z ~= 600 then fail("a road passing by, clear of the disc, was cut") end
    if innerLamp.Parent then fail("a road's lamp standing in the apron was left") end
    if not outerLamp.Parent then fail("a road's lamp on the far side of it went") end
    if junction.Parent then fail("the square's crossroads (non-queryable) was left in the disc") end
    if signalPole.Parent or signalHead.Parent then fail("a traffic light (its head non-queryable) was left in the disc") end
    if lampPost.Parent or lampArm.Parent then fail("a street lamp in the disc was left, whole or in part") end
    if car.Parent then fail("a parked car in the disc was left") end
    if tree.Parent then fail("a tree in the disc was left") end
    if not woods.Parent then fail("a whole woods group went") end
    if not base.Parent then fail("a team base was touched") end
    if pickup.Parent then fail("loot in the disc was left lying") end
    -- THE ROADS AT THE ARENA. No road piece anywhere inside RoadReach; every road that reached the disc
    -- ends square, all its pieces on one line at least RoadEnd out (on the terrain's 4-stud grid), each
    -- such end finished with a gateway whose beam clears the carriageway; the pavements closed with a kerb.
    local ROAD = { RoadSurface = true, RoadEdge = true, Asphalt = true, Kerb = true, Pavement = true, Dash = true, JunctionAsphalt = true }
    local function plan(p)
        local c, sz = p.CFrame, p.Size
        local ex = math.abs(c.r.X) * sz.X / 2 + math.abs(c.u.X) * sz.Y / 2 + math.abs(c.b.X) * sz.Z / 2
        local ez = math.abs(c.r.Z) * sz.X / 2 + math.abs(c.u.Z) * sz.Y / 2 + math.abs(c.b.Z) * sz.Z / 2
        return c.p.X, c.p.Z, ex, ez
    end
    local roadLeft = {}
    for _, kid in ipairs(map:GetDescendants()) do
        if kid:IsA("BasePart") and ROAD[kid.Name] and not kid:GetAttribute("TeamBattleground") then
            table.insert(roadLeft, kid)
            local x, z, ex, ez = plan(kid)
            local dx = math.max(0, math.abs(x - centre.X) - ex)
            local dz = math.max(0, math.abs(z - centre.Z) - ez)
            local near = math.sqrt(dx * dx + dz * dz)
            if near < BG.RoadReach then fail(("a road piece (%s) is left %.1f from the middle, inside the disc"):format(kid.Name, near)) end
        end
    end
    -- The street: its asphalt, kerbs and pavements each in two, every inner end on one line per side
    -- (the pavements a kerb's width shorter: the kerb across their end stands there).
    local ends = { [1] = {}, [-1] = {} }
    for _, kid in ipairs(town:GetChildren()) do
        if kid.Name == "Asphalt" or kid.Name == "Kerb" or kid.Name == "Pavement" then
            local a0, a1 = kid.CFrame.p.X - kid.Size.X / 2 - centre.X, kid.CFrame.p.X + kid.Size.X / 2 - centre.X
            local side = a0 > 0 and 1 or -1
            table.insert(ends[side], { kid.Name, side > 0 and a0 or -a1, side > 0 and a1 or -a0 })
        end
    end
    for side, list in pairs(ends) do
        local asphalt = nil
        for _, e in ipairs(list) do if e[1] == "Asphalt" then asphalt = e end end
        if not asphalt then fail("the street's asphalt is gone on the " .. (side > 0 and "east" or "west")) else
            if asphalt[2] < BG.RoadEnd - 1e-6 or asphalt[2] > BG.RoadEnd + 4 then
                fail(("the street ends %.2f from the middle, want %.0f..%.0f"):format(asphalt[2], BG.RoadEnd, BG.RoadEnd + 4)) end
            if math.abs(asphalt[3] - 300) > 0.05 then fail("the street lost its far end") end
            for _, e in ipairs(list) do
                local want = asphalt[2] + (e[1] == "Pavement" and 0.8 or 0)
                if math.abs(e[2] - want) > 0.02 then fail(("the street's %s ends at %.2f, not square with its asphalt (%.2f)"):format(e[1], e[2], want)) end
            end
            if #list ~= 5 then fail(#list .. " pieces of the street's asphalt, kerbs and pavements left one side, want 5") end
        end
    end
    -- The road from the north mouth: cut once, its slab and edge lines kept to the north.
    if not mouthRoad.Parent then fail("the road out of the north mouth went entirely") else
        local inner = mouthRoad.CFrame.p.Z - mouthRoad.Size.Z / 2 - centre.Z
        if inner < BG.RoadEnd - 1e-6 or inner > BG.RoadEnd + 4 then fail(("the north road ends %.2f out, want %.0f..%.0f"):format(inner, BG.RoadEnd, BG.RoadEnd + 4)) end
        for _, edge in ipairs(mouthEdges) do
            local e = edge.Parent and (edge.CFrame.p.Z - edge.Size.Z / 2 - centre.Z) or nil
            if not e or math.abs(e - (inner + 2.6)) > 0.02 then fail("an edge line of the north road does not stop at the give-way line") end
        end
    end
    -- The finished ends: three (the street's two, the north road's), each with its gateway, a clear way in.
    local roadEnds = info.roadEnds
    local count = 0
    if not roadEnds or roadEnds.Parent ~= info.model then fail("the road ends are not in the battleground") else
        for _, e in ipairs(roadEnds:GetChildren()) do
            if e.Name == "RoadEnd" then
                count = count + 1
                local pillars, beams, signs, kerbs = 0, 0, 0, 0
                local beamBottom = math.huge
                for _, p in ipairs(e:GetDescendants()) do
                    if p.Name == "GatewayPillar" then pillars = pillars + 1 end
                    if p.Name == "GatewaySign" then signs = signs + 1 end
                    if p.Name == "Kerb" then kerbs = kerbs + 1 end
                    if p.Name == "GatewayBeam" then beams = beams + 1 beamBottom = p.CFrame.p.Y - p.Size.Y / 2 end
                end
                if pillars ~= 2 or beams ~= 1 or signs ~= 1 then fail(("a road end has %d pillars, %d beams, %d signs"):format(pillars, beams, signs)) end
                if beamBottom < 12 then fail(("a gateway's beam is %.1f over the road, under the tallest vehicle and its margin"):format(beamBottom)) end
                local line = e:FindFirstChild("StopLine", true)
                local onStreet = line and math.abs(line.CFrame.p.Z - (centre.Z + 12)) < 1
                if onStreet and kerbs ~= 2 then fail("the street's end has " .. kerbs .. " kerbs across its pavements, want 2") end
            end
        end
    end
    if count ~= 7 then fail(count .. " finished road ends, want 7 (the street's two, the north road's, the south road's bend, the slab road's, the stub's, the short road's)") end
    local stubInner = stubRoad.Parent and (stubRoad.CFrame.p.X - stubRoad.Size.Z / 2 - centre.X)
    if not stubInner or stubInner > 180.01 or stubInner < 176 then fail("the road stopping short in the east was not drawn on to the apron's edge (" .. tostring(stubInner) .. ")") end
    if not westRoad.Parent or westRoad.Size.Z ~= 300 then fail("the road on from the south bend was cut or removed") end
    -- The audit tools/team_battleground_roadends_probe.lua runs on every real map: at least 2 finished
    -- ends, and no road left stopping short on open ground within 60 of the apron's edge.
    local finished, open = roadEndAudit(map, centre, BG.RoadEnd, 60, roadEnds)
    if finished < 2 then fail(finished .. " finished road ends by the audit, want at least 2") end
    for _, line in ipairs(open) do fail("a road stops short: " .. line) end
    -- Nothing of the battleground on a road: no part's plan overlaps a road piece's.
    local overlaps = 0
    for _, p in ipairs(info.model:GetDescendants()) do
        if p:IsA("BasePart") and not (roadEnds and p:IsDescendantOf(roadEnds)) and p.Parent and p.Parent.Name ~= "Zipline" then
            local x, z, px, pz = plan(p)
            for _, r in ipairs(roadLeft) do
                if r.Parent then
                    local rx, rz, ex, ez = plan(r)
                    if math.abs(x - rx) < px + ex - 0.05 and math.abs(z - rz) < pz + ez - 0.05 then overlaps = overlaps + 1 end
                end
            end
        end
    end
    if overlaps > 0 then fail(overlaps .. " battleground parts stand on a road") end
    -- Facing: team 1 along the LookVector, the objectives on the mirror at the floor heights.
    local lookFrame = info.frame
    local l = lookFrame.LookVector
    if math.abs(l.X - toTeamOne.X) > 1e-6 or math.abs(l.Z - toTeamOne.Z) > 1e-6 then fail("the frame does not face team 1") end
    local a = info.objectives[1]
    if math.abs(a.X - centre.X) > 1e-6 or math.abs(a.Z - centre.Z) > 1e-6 or math.abs(a.Y - (want + 0.8)) > 1e-6 then
        fail(("objective A at %s, want the middle at floor %.2f"):format(tostring(a), want + 0.8)) end
    if #zips ~= 4 then fail(#zips .. " ziplines hung, want 4") end
    for i, z in ipairs(zips) do
        local w = info.zips[i]
        if (z.fromTop - w.fromTop).Magnitude > 1e-6 or (z.to - w.to).Magnitude > 1e-6 then fail("zipline " .. i .. " not where Layout put it") end
    end
    local unmarked = 0
    for _, p in ipairs(info.model:GetDescendants()) do
        if p:IsA("BasePart") and not p:GetAttribute("TeamBattleground") then unmarked = unmarked + 1 end
    end
    if unmarked > 0 then fail(unmarked .. " parts not marked TeamBattleground") end
    -- CoverNear: nearest first, within the radius, a storey only.
    local near = BG.CoverNear(info, centre + Vector3.new(0, want + 0.8, -30), 20)
    local last = -1
    for _, p in ipairs(near) do
        local d = (Vector3.new(p.X, 0, p.Z) - Vector3.new(centre.X, 0, centre.Z - 30)).Magnitude
        if d > 20 + 1e-6 then fail("CoverNear gave a spot outside its radius") break end
    end
    if #near == 0 then fail("CoverNear found nothing 30 from the middle") end
    BG.Destroy(info)
    if info.model.Parent then fail("Destroy left the model") end
    if #BG.CoverNear(info, centre, 60) ~= 0 then fail("CoverNear still answers after Destroy") end
    workspace = nil
    return out
end
"""


def road_audit_source():
    """The road-end audit, shared with tools/team_battleground_roadends_probe.lua (between its markers)."""
    text = (Path(__file__).resolve().parent / "team_battleground_roadends_probe.lua").read_text(encoding="utf-8")
    return text[text.index("-- AUDIT BEGIN"):text.index("-- AUDIT END")]


def check_build(src, log):
    problems = []
    for mode in ("flat", "pad", "flatstand", "bumpy", "river"):
        rt = Runtime(src)
        rt.lua.execute(SMOKE)
        rt.lua.globals().roadEndAudit = rt.lua.execute(road_audit_source() + "\nreturn roadEndAudit")
        found = rt.lua.globals().smoke(rt.bg, mode)
        problems += ["build (%s): %s" % (mode, found[i]) for i in range(1, len(found) + 1)]
    log("build: on a mock town (levelled, the pad-level retry, flat enough to stand as it is, too rough, a river), %d problems"
        % len(problems))
    return problems


# ------------------------------------------------------------------------------------------------
# The real BotNav, finding cover among the built parts
# ------------------------------------------------------------------------------------------------

class Raycaster:
    """workspace:Raycast over the built parts (boxes, wedges by their slope, cylinders and balls by their
    boxes) and the flat ground at y = 0."""

    def __init__(self, parts):
        self.parts = [p for p in parts if p["collide"]]
        self.c = np.array([p["pos"] for p in self.parts])
        self.ax = np.array([p["axes"] for p in self.parts])
        self.h = np.array([p["size"] for p in self.parts]) / 2
        self.wedge = np.array([p["kind"] == "wedge" for p in self.parts])

    def cast(self, origin, direction):
        o = np.array(origin, float)
        d = np.array(direction, float)
        length = np.linalg.norm(d)
        if length < 1e-9:
            return None
        u = d / length
        rel = o[None, :] - self.c
        lo = np.einsum("nij,nj->ni", self.ax, rel)
        ld = np.einsum("nij,j->ni", self.ax, u)
        with np.errstate(divide="ignore", invalid="ignore"):
            t1 = (-self.h - lo) / ld
            t2 = (self.h - lo) / ld
        tmin = np.where(np.abs(ld) < 1e-12, np.where(np.abs(lo) <= self.h, -np.inf, np.inf), np.minimum(t1, t2))
        tmax = np.where(np.abs(ld) < 1e-12, np.where(np.abs(lo) <= self.h, np.inf, -np.inf), np.maximum(t1, t2))
        enter = tmin.max(axis=1)
        leave = tmax.min(axis=1)
        axis_in = tmin.argmax(axis=1)
        best, normal = None, None
        # Wedges: clip with the slope plane ly <= (hy/hz) lz.
        for n in np.nonzero((enter <= leave) & (leave >= 0) & (enter <= length))[0]:
            t0 = max(enter[n], 0.0)
            nrm = None
            if self.wedge[n]:
                k = self.h[n][1] / self.h[n][2]
                f0 = lo[n][1] - k * lo[n][2]
                fd = ld[n][1] - k * ld[n][2]
                # inside the half-space where f(t) = f0 + fd t <= 0
                if abs(fd) < 1e-12:
                    if f0 > 0:
                        continue
                else:
                    tp = -f0 / fd
                    if fd > 0:
                        if tp < t0:
                            continue
                        leave_n = min(leave[n], tp)
                        if leave_n < t0:
                            continue
                    else:
                        if tp > leave[n]:
                            continue
                        if tp > t0:
                            t0 = tp
                            local_n = np.array([0.0, 1.0, -k])
                            nrm = self.ax[n].T @ (local_n / np.linalg.norm(local_n))
            if t0 > length:
                continue
            if best is None or t0 < best:
                best = t0
                if nrm is None:
                    i = axis_in[n]
                    sign = -1.0 if ld[n][i] > 0 else 1.0
                    nrm = self.ax[n][i] * sign
                normal = nrm
        # the ground
        if u[1] < -1e-9:
            tg = -o[1] / u[1]
            if 0 <= tg <= length and (best is None or tg < best):
                best, normal = tg, np.array([0.0, 1.0, 0.0])
        if best is None:
            return None
        p = o + u * best
        return tuple(p), tuple(normal)

    def hidden(self, threat, eye):
        hit = self.cast(threat, tuple(np.array(eye) - np.array(threat)))
        return hit is not None and math.dist(hit[0], eye) > 2


BOTNAV_MOCK = r"""
RaycastParams = { new = function() return {} end }
OverlapParams = { new = function() return {} end }
function botnavWorld(cast, around)
    local ws = { }
    function ws:Raycast(origin, direction, params)
        local hit = cast(origin.X, origin.Y, origin.Z, direction.X, direction.Y, direction.Z)
        if not hit then return nil end
        return { Position = Vector3.new(hit[1], hit[2], hit[3]), Normal = Vector3.new(hit[4], hit[5], hit[6]), Material = "Grass" }
    end
    function ws:GetPartBoundsInRadius(point, radius) local n = around(point.X, point.Y, point.Z, radius) local t = {} for i = 1, n do t[i] = i end return t end
    function ws:FindFirstChild() return nil end
    workspace = ws
end
function botCharacter(x, y, z)
    local humanoid = { HipHeight = 2, ClassName = "Humanoid" }
    local root = { Position = Vector3.new(x, y, z), Size = Vector3.new(2, 2, 1) }
    local character = { }
    function character:FindFirstChildOfClass(c) if c == "Humanoid" then return humanoid end end
    return character, root
end
function findCover(BotNav, x, y, z, tx, ty, tz)
    local character, root = botCharacter(x, y, z)
    local point, direct = BotNav.FindCover(root, character, Vector3.new(tx, ty, tz), { 10, 18, 28 })
    if not point then return nil end
    return { point.X, point.Y, point.Z, direct and 1 or 0 }
end
"""


def check_botnav(src, parts, info, log, hints=True):
    """The real BotNav.FindCover from points down every route, the threat 35 studs further on toward the
    middle: how often it finds cover, how often that cover is the battleground's own, and whether every spot
    it returns is hidden from the threat by this file's own rays."""
    rc = Raycaster(parts)
    lua = LuaRuntime(unpack_returned_tuples=True)
    mock = TBR.MOCK.replace("local PARTS = { Part = true, WedgePart = true }",
                            "local PARTS = { Part = true, WedgePart = true, TrussPart = true }")
    lua.execute(mock + TBR.EXTRA_MOCK + BOTNAV_MOCK)

    def cast(ox, oy, oz, dx, dy, dz):
        hit = rc.cast((ox, oy, oz), (dx, dy, dz))
        if hit is None:
            return None
        return lua.table_from(list(hit[0]) + list(hit[1]))

    boxes = [TBR.obb(p) for p in rc.parts]

    def around(x, y, z, r):
        probe = ((x, y, z), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (r, r, r))
        return sum(1 for b in boxes if abs(b[0][0] - x) < 40 and abs(b[0][2] - z) < 40 and TBR.obb_overlap(b, probe))

    lua.globals().botnavWorld(cast, around)
    botnav = lua.execute(luau_to_lua_continue(src["botnav"]))
    cover = [tuple(c) for c in info["cover"]]
    if hints:
        def near(ox, oy, oz, radius):
            found = sorted((math.hypot(c[0] - ox, c[2] - oz), c) for c in cover
                           if math.hypot(c[0] - ox, c[2] - oz) <= radius and abs(c[1] - oy) < 12)
            return lua.table_from([lua.eval("Vector3.new")(c[0], c[1], c[2]) for _, c in found[:16]])
        lua.execute("function setHints(f) BotNavRef.CoverHints = function(o, r) return f(o.X, o.Y, o.Z, r) end end")
        lua.globals().BotNavRef = botnav
        lua.globals().setHints(near)
    tries = found = built = hidden = 0
    problems = []
    for name, points in sorted(info["routes"].items()):
        samples = polyline_samples(points, 1.0)
        for index in range(0, len(samples) - 36, 9):
            x, y, z = samples[index]
            ahead = samples[index + 35]
            tries += 1
            result = lua.globals().findCover(botnav, x, y + 3, z, ahead[0], ahead[1] + 4.5, ahead[2])
            if result is None:
                continue
            found += 1
            px, py, pz = result[1], result[2], result[3]
            if any(abs(px - c[0]) < 1e-6 and abs(pz - c[2]) < 1e-6 for c in cover):
                built += 1
            if rc.hidden((ahead[0], ahead[1] + 4.5, ahead[2]), (px, py + 1.5, pz)):
                hidden += 1
            else:
                problems.append("botnav: cover at (%.1f, %.1f, %.1f) is in view of the threat" % (px, py, pz))
    log("botnav: FindCover from %d points on the routes: found cover %d times, %d of them the battleground's own spots, "
        "%d hidden by this file's rays%s" % (tries, found, built, hidden, "" if hints else " (no CoverHints)"))
    if hints and found and built < found * 0.5:
        problems.append("botnav: only %d of %d cover spots were the battleground's own" % (built, found))
    return problems[:6], (tries, found, built)


# ------------------------------------------------------------------------------------------------

def run(src, log, deep=True):
    problems = []
    rt = Runtime(src)
    model, info_lua = rt.layout(SEED)
    info = read_info(rt, info_lua)
    # The geometry as built, before the z-fight pass nudges anything by its hundredths.
    parts = rt.dump(model)
    problems += check_zfight(rt, model, log)
    problems += check_budget(parts, log)
    problems += check_mirror(parts, log)
    problems += check_floating(parts, log)
    problems += check_cylinders(parts, log)
    problems += check_doorways(parts, info["doorways"], log)
    cols = Columns(parts)
    walk = Walk(cols, R15)
    found, _, _ = check_walk(walk, info, log)
    problems += found
    bots = Walk(cols, BOT, drops=True)
    found, _, _ = check_walk(bots, info, log, label="bots")
    problems += [f for f in found if "cover spot" not in f]
    problems += check_traps(bots, log)
    problems += check_high_ground(walk, info, log)
    problems += check_sightlines(cols, log)
    problems += check_cover(cols, info, log)
    problems += check_objectives(bots, cols, info, log, parts)
    problems += check_vehicles(cols, info, log)
    problems += check_loot(walk, cols, parts, info, log)
    problems += check_ziplines(walk, cols, info, log)
    problems += check_emplacements(rt, model, parts, cols, walk, info, log)
    problems += check_zones(rt, parts, cols, walk, info, log)
    problems += check_destruct(rt, model, parts, log)
    if deep:
        again = Runtime(src)
        model2, _ = again.layout(SEED)
        again.zfight.Fix(again.lua.table_from([model2]))
        rt.zfight.Fix(rt.lua.table_from([model]))
        a = local_rows(rt.dump(model))
        b = local_rows(again.dump(model2))
        diff = TBR.same_rows(a, b)
        log("seed: rebuilt with the same seed, %d parts differ" % len(diff))
        problems += ["seed: " + d for d in diff]
        problems += check_build(src, log)
        found, _ = check_botnav(src, parts, info, log)
        problems += found
    return problems


def sweep_seeds(src, seeds, log):
    problems, counts = [], []
    for seed in seeds:
        rt = Runtime(src)
        model, info_lua = rt.layout(seed)
        info = read_info(rt, info_lua)
        quiet = lambda *_: None  # noqa: E731
        parts = rt.dump(model)
        found = check_zfight(rt, model, quiet)
        found += check_mirror(parts, quiet)
        found += check_floating(parts, quiet)
        cols = Columns(parts)
        walk = Walk(cols, R15)
        f, _, _ = check_walk(walk, info, quiet)
        found += f
        found += check_budget(parts, quiet)
        counts.append(len(parts))
        problems += ["seed %d: %s" % (seed, line) for line in found]
    log("seeds: %d more seeds swept (z-fighting, mirror, floating, walk, budget), %d problems, %d..%d parts"
        % (len(seeds), len(problems), min(counts), max(counts)))
    return problems


# ------------------------------------------------------------------------------------------------
# Planted faults. Each is an edit to a source (the battleground's own unless said), the checks that
# must catch it, and a piece of the failure they must give: a plant that trips some other check
# instead has not been caught by the one meant for it. Only the named checks run, on SEED, so the
# whole list takes minutes, not an hour.

def run_only(src, names, log=lambda *_: None):
    rt = Runtime(src)
    model, info_lua = rt.layout(SEED)
    info = read_info(rt, info_lua)
    parts = rt.dump(model)
    cache = {}

    def cols():
        if "cols" not in cache:
            cache["cols"] = Columns(parts)
        return cache["cols"]

    def walk():
        if "walk" not in cache:
            cache["walk"] = Walk(cols(), R15)
        return cache["walk"]

    def bots():
        if "bots" not in cache:
            cache["bots"] = Walk(cols(), BOT, drops=True)
        return cache["bots"]

    def seed():
        again = Runtime(src)
        model2, _ = again.layout(SEED)
        diff = TBR.same_rows(local_rows(parts), local_rows(again.dump(model2)))
        return ["seed: " + d for d in diff]

    checks = {
        "zfight": lambda: check_zfight(rt, model, log),
        "budget": lambda: check_budget(parts, log),
        "mirror": lambda: check_mirror(parts, log),
        "floating": lambda: check_floating(parts, log),
        "cylinders": lambda: check_cylinders(parts, log),
        "doorways": lambda: check_doorways(parts, info["doorways"], log),
        "walk": lambda: check_walk(walk(), info, log)[0],
        "traps": lambda: check_traps(bots(), log),
        "high_ground": lambda: check_high_ground(walk(), info, log),
        "sightlines": lambda: check_sightlines(cols(), log),
        "cover": lambda: check_cover(cols(), info, log),
        "objectives": lambda: check_objectives(bots(), cols(), info, log, parts),
        "vehicles": lambda: check_vehicles(cols(), info, log),
        "loot": lambda: check_loot(walk(), cols(), parts, info, log),
        "ziplines": lambda: check_ziplines(walk(), cols(), info, log),
        "destruct": lambda: check_destruct(rt, model, parts, log),
        "emplacements": lambda: check_emplacements(rt, model, parts, cols(), walk(), info, log),
        "zones": lambda: check_zones(rt, parts, cols(), walk(), info, log),
        "seed": seed,
        "build": lambda: check_build(src, log),
        "botnav": lambda: check_botnav(src, parts, info, log)[0],
    }
    found = []
    for name in names:
        found += checks[name]()
    return found


# The bot trap: a ramp up to a platform 10 high on the clear ground by the pit approach, and past it
# a walled pocket 10 down -- a bot walks up, drops in (a drop PathfindingService takes) and never gets
# out. Both halves get one.
TRAP = """	box(approach, "TrapPlatform", -71, -63, 0, 10, -57, -49, STONE, MAT.Slate, NEVER)
	put(approach, "TrapRamp", Vector3.new(8, 10, 14), CFrame.new(-78, 5, -53) * CFrame.Angles(0, math.pi / 2, 0), STONE, MAT.Slate,
		{ class = "WedgePart", tag = false })
	box(approach, "TrapWall", -63, -56, 0, 12, -58, -57, STONE, MAT.Slate, NEVER)
	box(approach, "TrapWall", -63, -56, 0, 12, -49, -48, STONE, MAT.Slate, NEVER)
	box(approach, "TrapWall", -57, -56, 0, 12, -57, -49, STONE, MAT.Slate, NEVER)
"""

KEEP_DOOR = '\tdoorway("KeepDoor", -15, -9, -22, -20, KF, 9.8)\n'


def after_keep_door(line):
    return [(KEEP_DOOR, KEEP_DOOR + "\t" + line + "\n")]


PLANTS = [
    ("the second half from its own seed", "bg",
     [("B.rng = Random.new(seed or 1)", "B.rng = Random.new((seed or 1) + (mirror and 1 or 0))")], ["mirror"], "mirror"),
    ("a piece in one half only", "bg",
     [('\tlocal court = folder(root, "Forecourt")\n',
       '\tlocal court = folder(root, "Forecourt")\n\tif not B.mirror then box(court, "Odd", 30, 31, 0, 2, -60, -59, STONE, MAT.Slate, NEVER) end\n')],
     ["mirror"], "mirror"),
    ("a coplanar plate on the keep floor", "bg",
     after_keep_door('box(keep, "Paving", -19.9, -12.1, 0.5, KF, -19.9, -10, BASALT, MAT.Slate, NEVER)'), ["zfight"], "zfight"),
    ("a lamp in mid-air", "bg", after_keep_door('box(keep, "Lamp", 0, 1, 30, 31, -10, -9, WARM, MAT.Neon, NEVER)'), ["floating"], "Lamp"),
    ("cylinders stood on end", "bg",
     [("return put(parent, name, Vector3.new((b - a).Magnitude, diameter, diameter), rodFrame(a, b)",
       "return put(parent, name, Vector3.new(diameter, (b - a).Magnitude, diameter), rodFrame(a, b)")], ["cylinders"], "ylinder"),
    ("a post in the keep's door", "bg",
     after_keep_door('box(keep, "Post", -12.6, -11.4, KF, 9.8, -21.6, -20.4, STONE, MAT.Slate, NEVER)'), ["doorways"], "KeepDoor"),
    ("the gatehouse's east stair gone", "bg",
     [('\tflightZ(gate, "GateStair", 20, 26, -80.6, -68, 0, GATE_TOP, 10, STONE_DARK, MAT.Cobblestone, -0.5)\n', "")],
     ["high_ground"], "Gatehouse"),
    ("a bot trap", "bg",
     [('\ttramCar(approach, -84, -62, -41, -36, "RotTramA", true)\n', '\ttramCar(approach, -84, -62, -41, -36, "RotTramA", true)\n' + TRAP)],
     ["traps"], "trap"),
    ("the colossus's pedestal gone", "bg",
     [('local pedestal = folder(court, "ColossusPedestal", true)', 'local pedestal = Instance.new("Model")')], ["sightlines"], "centre"),
    ("the entry's dragon's teeth gone", "bg",
     [("\tteeth(entry, 3.2, -116, 2)\n\tteeth(entry, 3.2, -94, 2)\n", "")], ["cover"], "cover"),
    ("objective A off the mirror", "bg",
     [("TeamBattleground.ObjectivesLocal = { Vector3.new(0, KF, 0),", "TeamBattleground.ObjectivesLocal = { Vector3.new(0, KF, -3),")],
     ["objectives"], "objective"),
    ("a pillar where bots hold A", "bg",
     after_keep_door('box(keep, "Pillar", 13, 15.5, KF, 9, -8, -5.5, STONE, MAT.Slate, NEVER)'), ["objectives"], "objective"),
    ("a crate on the vehicle route", "bg",
     [("local function buildLane(root)\n", 'local function buildLane(root)\n\tbox(root, "Crate", 69, 71, 0, 2, -101, -99, WOOD, MAT.Wood, NEVER)\n')],
     ["vehicles"], "vehicle"),
    ("forecourt loot inside the kiosk", "bg",
     [('lootSpot("Forecourt", 1.5, TILE, -38.5, "weapon")', 'lootSpot("Forecourt", 9.5, TILE, -38, "weapon")')], ["loot"], "Forecourt"),
    ("the best loot in the safest spot", "bg",
     [('lootSpot("KeepHall", -15.5, KF, -6.5, "heal")', 'lootSpot("KeepHall", -15.5, KF, -6.5, "weapon", "Legendary")')], ["loot"], "Legendary"),
    ("zipline masts cut down", "bg", [("local ZIP_TOP = GAL + 9.6", "local ZIP_TOP = GAL + 3")], ["ziplines"], "zip"),
    # Everything breaks now (DestructibleService is opt-out): the plants give a piece a name the
    # service keeps whole (a spawn's), which only this check's "kept whole" count sees.
    ("the keep's ramp kept whole", "bg",
     [('put(keep, "KeepRamp",', 'put(keep, "SpawnRamp",')], ["destruct"], "never break"),
    ("the gallery floor kept whole", "bg",
     [('box(keep, "GalleryFloor", -20, 20, GAL - 1, GAL, -20, -VOID,', 'box(keep, "StormFloor", -20, 20, GAL - 1, GAL, -20, -VOID,')],
     ["destruct"], "never break"),
    # The gun emplacements: a bad spot of each kind, and the check rejects it.
    ("a gun that sees its own team's way in", "bg",
     [('box(gate, "Hoarding", -13, 0.4, GATE_TOP, GATE_TOP + 5.4,', 'box(gate, "Hoarding", -13, 0.4, GATE_TOP, GATE_TOP + 0.8,')],
     ["emplacements"], "base"),
    ("a gun down the centre lane", "bg",
     [("\tlocal ground = folder(entry, \"Paving\", true)\n",
       "\tlocal ground = folder(entry, \"Paving\", true)\n\templacement(entry, \"Lane\", facing(0, 0, -150, 0, 0), \"the whole lane\")\n")],
     ["emplacements"], "emplacement"),
    ("a gun in mid-air", "bg",
     [("local frame = facing(-89.8, ROOF, -61, -60, -61)", "local frame = facing(-89.8, ROOF + 3, -61, -60, -61)")], ["emplacements"], "no floor"),
    ("a gun in one half only", "bg",
     [('emplacement(sb, "SignalBox", frame, "west lane, tram approach")',
       'if not B.mirror then emplacement(sb, "SignalBox", frame, "west lane, tram approach") end')], ["emplacements"], "emplacement"),
    ("a gun in a merlon", "bg",
     [("local bayGun = facing(-6.4, GATE_TOP, -62.6, -6.4, 0)", "local bayGun = facing(-1.5, GATE_TOP, -66, -1.5, 0)")],
     ["emplacements"], "solid within"),
    ("guns with no mantlets", "bg", [("\tif sides ~= false then\n", "\tif false then\n")], ["emplacements"], "emplacement"),
    ("a gun nobody can get round", "bg", [("TeamBattleground.GunArc = 110", "TeamBattleground.GunArc = 359")], ["emplacements"], "covered way"),
    ("guns untagged", "bg", [("\tCollectionService:AddTag(part, TeamBattleground.EmplacementTag)\n", "")], ["emplacements"], "tagged"),
    ("unseeded wear", "bg", [("B.rng = Random.new(seed or 1)", "B.rng = Random.new((seed or 1) + math.random(1, 100000))")], ["seed"], "seed"),
    ("over budget", "bg",
     [('\tlocal middle = folder(root, "Middle", true)\n',
       '\tlocal middle = folder(root, "Middle", true)\n\tfor i = 1, 800 do box(middle, "Junk", -0.5, 0.5, 0, 1, 150 + i * 2, 151 + i * 2, STONE, MAT.Slate, NEVER) end\n')],
     ["budget"], "budget"),
    ("an objective in the open (the pit not built round it)", "bg", [("buildPit(half)", "")], ["zones"], "ways in"),
    ("a zone reachable from only one side", "bg", [('doorway("PitCut", -76, -66, -26, -18, TILE, 40)',
     'doorway("PitCut", -76, -66, -26, -18, TILE, 40) if B.mirror then box(pit, "Wall", -118, -44, -1, 30, -31, -29.5, STONE, MAT.Limestone) end')],
     ["zones"], "zone B"),
    ("the capture rings not marked", "bg", [("\tbuildCaptureRings(model)\n", "")], ["zones"], "ring is marked"),
    ("a gun turned onto a zone's middle", "bg", [("facing(-52.7, RIM, -22.5, -90, -42.3)", "facing(-52.7, RIM, -22.5, -90, -22.5)")], ["zones"], "sees its middle"),
    ("the road-end pass switched off", "bg", [("for _, spec in ipairs(ends) do", "for _, spec in ipairs({}) do"),
     ("for _, spec in ipairs(curveEnds) do", "for _, spec in ipairs({}) do")], ["build"], "build"),
    ("RoadNetwork's short slabs read across their road", "bg", [("local lengthwise = ROAD_SLABS[part.Name]", "local lengthwise = false")], ["build"], "build"),
    ("a road stopping short of the edge left as it is", "bg", [("if not stopsInside and lateral < outer - 9 then", "if false then")], ["build"], "build"),
    ("a road cut a stud or two short of its end left unfinished", "bg", [("if road.a1 > high + 0.5 then", "if road.a1 > high + 2 then"), ("if road.a0 < low - 0.5 then", "if road.a0 < low - 2 then")], ["build"], "build"),
    ("bends not cut at a joint (left to the odd pieces' rule)", "bg", [("local found = cutCurve(curves[curve], centre, outer, keptBoxes)", "local found = nil")], ["build"], "build"),
    ("the site not cleared", "bg", [("local _, _, _, roadEnds = TeamBattleground.ClearSite(site, map)", "local roadEnds = nil")], ["build"], "build"),
    ("roads left running through", "bg",
     [("if math.sqrt(along * along + lateral * lateral) <= TeamBattleground.RoadReach or stopsInside or stub then", "if false then")],
     ["build"], "inside the disc"),
    ("only what a box query sees cleared", "bg",
     [('if part:IsA("BasePart") and not part:GetAttribute("TeamBaseRuin") and not part:GetAttribute("TeamBattleground") then',
       'if part:IsA("BasePart") and part.CanQuery ~= false and not part:GetAttribute("TeamBaseRuin") and not part:GetAttribute("TeamBattleground") then')],
     ["build"], "non-queryable"),
    ("a road passing by cut too", "bg",
     [("TeamBattleground.RoadReach = TeamBattleground.Radius + TeamBattleground.Margin + 6",
       "TeamBattleground.RoadReach = TeamBattleground.Radius + TeamBattleground.Margin + 30")], ["build"], "was cut"),
    ("road ends left raw", "bg",
     [("local built = roadEnd(model, spec.road, spec.cut, spec.outward, centre)", "local built = nil")], ["build"], "finished road ends"),
    ("gateway beam under the tallest van", "bg", [("local GATEWAY_CLEAR = 12.3", "local GATEWAY_CLEAR = 9.5")], ["build"], "tallest vehicle"),
    ("pavements left open", "bg", [('box(model, "Kerb", math.min(x0, x1)', 'box(model, "KerbCap", math.min(x0, x1)')], ["build"], "kerbs across"),
    ("objective A on the crack", "bg",
     [('\tbox(middle, "Paving", -3.9, 3.9, 0.5, KF, -3.9, 3.9, BASALT_LIGHT, MAT.Slate, NEVER)\n', ""),
      ('box(keep, "Paving", x0 + 0.1, x0 + 7.9, 0.5, KF, -19.9, i == 2 and -4.1 or -0.1,', 'box(keep, "Paving", x0 + 0.1, x0 + 7.9, 0.5, KF, -19.9, -0.1,')],
     ["objectives"], "objective A: a ray down"),
    ("the levelled height ignored", "bg",
     [("local frame = CFrame.new(position.X, height, position.Z) * CFrame.Angles(0, yaw, 0)",
       "local frame = CFrame.new(position.X, position.Y, position.Z) * CFrame.Angles(0, yaw, 0)")], ["build"], "build"),
    ("no town-level retry", "bg", [('if not height and why == "pad" then', "if false then")], ["build"], "build"),
    ("a river site accepted", "bg", [("local refusal = TeamBattleground.SiteRefusal(site, mapInfo)", "local refusal = nil")], ["build"], "build"),
    ("no ziplines hung", "bg",
     [("ok, line = pcall(ZiplineService.Create, lines, zip.fromTop, zip.to, zip.fromTop)", 'ok, line = false, "cut"')], ["build"], "zipline"),
    ("BotNav ignores the hints", "botnav", [("\tif BotNav.CoverHints then\n", "\tif false then\n")], ["botnav"], "botnav"),
    ("BotNav takes a hint the threat can see", "botnav",
     # The hints loop's own hidden test (five tabs deep; the rings' copy below it is four). Since the ray
     # budget (#131) it is a line of its own ahead of the CanStep test.
     [("\t\t\t\t\tif hit and (hit.Position - eye).Magnitude > 2 then\n\t\t\t\t\t\tlocal ok, reason = BotNav.CanStep(",
       "\t\t\t\t\tif true then\n\t\t\t\t\t\tlocal ok, reason = BotNav.CanStep(")], ["botnav"], "botnav"),
]


def run_plants(src, only=None):
    caught = 0
    chosen = [p for p in PLANTS if not only or any(o in p[0] for o in only)]
    for label, key, edits, names, expect in chosen:
        planted = dict(src)
        text = planted[key]
        moved = [old for old, _ in edits if text.count(old) != 1]
        if moved:
            print("plant %-44s ANCHOR MOVED (%s...)" % (label + ":", moved[0][:50]), flush=True)
            continue
        for old, new in edits:
            text = text.replace(old, new)
        planted[key] = text
        try:
            found = run_only(planted, names)
        except Exception as error:  # a crash is not a catch
            print("plant %-44s CRASHED: %s" % (label + ":", str(error).splitlines()[0]), flush=True)
            continue
        hits = [f for f in found if expect.lower() in f.lower()]
        caught += bool(hits)
        print("plant %-44s %s%s" % (label + ":", "caught" if hits else "MISSED",
                                    " (%s)" % (hits or found or ["no failure"])[0][:110]), flush=True)
    print("team_battleground_check plants: %d of %d caught" % (caught, len(chosen)))
    return caught == len(chosen)


def main(argv):
    repo = argv[1] if len(argv) > 1 and not argv[1].startswith("--") else "."
    src = sources(repo)
    if "--plant-only" in argv:
        # --plant-only [words...]: just the plants (those whose label holds one of the words).
        words = argv[argv.index("--plant-only") + 1:]
        return 0 if run_plants(src, words) else 1
    problems = run(src, print)
    problems += sweep_seeds(src, (1, 2, 3, 11, 777), print)
    for line in problems:
        print("  FAIL " + line)
    print("team_battleground_check: %d problems" % len(problems))
    ok = not problems
    if "--plant" in argv:
        ok &= run_plants(src)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
