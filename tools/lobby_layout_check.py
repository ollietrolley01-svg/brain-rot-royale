"""The lobby as a place people walk round (lobby v2): builds the REAL lobby (LobbyService.Build under
lupa, with tools/showcase_layout_check.py's Roblox mock), turns every part into solid geometry and
checks, without Studio:

  A  every interactive element is there: the spawn, the ready pad on the Rot Express (the queue for
     the next drop and its vote), the Trade Board and Cosmetics vendors, every crate key on the
     altar, the Daily Spin, the three range guns and the range terrace, the play balls and the goal,
     both leaderboard pylons, the Cloud Climb's prompts
  B  every one of them is REACHABLE ON FOOT FROM THE SPAWN: a walk over a 1-stud grid (steps up to
     STEP, jumps up to JUMP, any drop, a player's radius clear of walls, head room) from the pier,
     then for a prompt a standing spot inside its MaxActivationDistance with a clear line from the
     player's chest to it (a vendor walled in fails even though its prompts ignore line of sight),
     for a pad a spot on it, for a board a spot it can be read from
  C  the lobby's own dressing (the Wayfinding set piece: gateways, paths, banners, lights) neither
     clips into another set piece nor floats: every connected lump of it rests on something that
     is not itself, unless it bobs on purpose
  D  the part budget: the whole lobby within LOBBY_BUDGET parts and LIGHT_BUDGET lights, the
     Wayfinding piece within its own WAYFINDING_BUDGET (players load in here first; #131)
  E  the lobby cannot break: MatchService builds it under a model named "Lobby" and
     DestructibleService's NEVER list keeps that name

Planted faults (each must fail, run every time): the Cosmetics vendor's prompt gone (A), the Trade
Board sealed behind four walls (B), a gateway sunk into the Trading Hall (C), a banner hung in the
air (C), the budget blown (D), "Lobby" dropped from NEVER (E).

    python tools/lobby_layout_check.py [repo_root]            the checks (exit 1 on any failure)
    python tools/lobby_layout_check.py [repo_root] --map F    also draw a top-down map (PNG) of the
                                                              walk: grey = solid, green = reached
"""
import math
import re
import sys
from collections import deque
from pathlib import Path

import numpy as np
from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parent))
import showcase_layout_check as SC  # noqa: E402

ROOT = SC.ROOT
MODULES = SC.MODULES
LOBBY_FILE = MODULES / "LobbyService.lua"

# Budgets, counted on this harness's build (Studio's is ~200 more: the real display guns, the
# mannequin's accessory, the statue's figure; 3,601 in the v2 gallery). Before v2 the lobby was 3,158
# parts and 89 lights here; v2's Wayfinding adds 231 parts and 5 lights, and the budget leaves a
# little room, no more.
LOBBY_BUDGET = 3600
WAYFINDING_BUDGET = 260
LIGHT_BUDGET = 110

# The walker: a player is ~2 studs across and 5 tall; Humanoids walk up ~2 studs without jumping and
# jump ~7 (JumpPower 50); a phone player's jump is held to 4.5 so nothing asks for a perfect one.
CELL = 1.0
RADIUS = 0.9
STEP = 2.1
JUMP = 4.5
HEAD = 5.0

GRID_X = (-150, 150)
GRID_Z = (-150, 200)

DUMP = r"""
function(LobbyService, base, plant)
	local lobby = Instance.new("Model")
	lobby.Name = "Lobby"
	lobby.Parent = workspace
	LobbyService.Build(lobby, base)
	if plant == "seal" then
		local counter
		for _, d in ipairs(lobby:GetDescendants()) do if d.Name == "TradeCounter" then counter = d end end
		local c = counter.CFrame.p
		for _, o in ipairs({ { 7, 0, 1, 16 }, { -7, 0, 1, 16 }, { 0, 7, 16, 1 }, { 0, -7, 16, 1 } }) do
			local w = Instance.new("Part")
			w.Name = "PlantedWall"
			w.Anchored = true
			w.Size = Vector3.new(o[3], 14, o[4])
			w.CFrame = CFrame.new(c + Vector3.new(o[1], 4, o[2]))
			w:SetAttribute("Group", "Plant")
			w.Parent = lobby
		end
	end
	local out = {}
	local function groupOf(p)
		local node = p
		while node and node ~= lobby do
			local g = node:GetAttribute("Group")
			if g then return g end
			node = node.Parent
		end
		return "?"
	end
	local function bobs(p)
		local node = p
		while node and node ~= lobby do
			if node:GetAttribute("IntentionalFloat") or node:GetAttribute("BobHeight") then return "1" end
			node = node.Parent
		end
		return "0"
	end
	for _, p in ipairs(lobby:GetDescendants()) do
		if p:IsA("BasePart") and p.CFrame then
			local c, s = p.CFrame, p.Size
			local o = c.p - base
			out[#out + 1] = table.concat({ "P", groupOf(p), p.Name, p.ClassName, tostring(p.Shape), tostring(p.Anchored),
				tostring(p.CanCollide), string.format("%.4f", p.Transparency), tostring(rawget(p, "props").CollisionGroup or "Default"),
				bobs(p), string.format("%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f",
					s.X, s.Y, s.Z, o.X, o.Y, o.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z) }, "|")
		elseif p.ClassName == "ProximityPrompt" and p.Parent and p.Parent.CFrame then
			local o = p.Parent.CFrame.p - base
			out[#out + 1] = table.concat({ "Q", groupOf(p.Parent), p.Parent.Name, tostring(p.ObjectText), tostring(p.ActionText),
				tostring(rawget(p, "props").MaxActivationDistance or 10), string.format("%.4f %.4f %.4f", o.X, o.Y, o.Z) }, "|")
		elseif p.ClassName == "PointLight" or p.ClassName == "SpotLight" or p.ClassName == "SurfaceLight" then
			out[#out + 1] = "L"
		end
	end
	local sp = LobbyService.SpawnOffset
	out[#out + 1] = string.format("S|%.4f|%.4f|%.4f|%.4f", sp.X, sp.Y, sp.Z, LobbyService.SpawnHalfWidth)
	return table.concat(out, "\n")
end
"""


class Part:
    __slots__ = ("group", "name", "cls", "shape", "anchored", "collide", "transparency", "cgroup", "bobs",
                 "size", "pos", "r", "u", "b", "planes", "index")


def build(source=None, plant=None):
    """Runs the real LobbyService.Build; returns (parts, prompts, lights, spawn)."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SC.MOCK)
    # Three Legendary guns for the range's podiums (the real WeaponData pulls in half the arsenal).
    lua.execute("MODULES.WeaponData = setmetatable({ Weapons = { GunA = { rarity = 'Legendary', name = 'Gun A' }, "
                "GunB = { rarity = 'Legendary', name = 'Gun B' }, GunC = { rarity = 'Legendary', name = 'Gun C' } } }, "
                "{ __index = function() return STUB end })")
    lua.execute("MODULES.WeaponService = setmetatable({ BuildStaticGun = function() return Instance.new('Part'), {}, 0 end }, "
                "{ __index = function() return STUB end })")
    modules = lua.globals().MODULES
    for name in ("Rarity", "CrateData", "DailySpinData", "MatchConfig", "CosmeticData"):
        modules[name] = lua.execute(SC.luau_to_lua(SC.read(SC.SHARED / f"{name}.lua")))
    modules["CloudClimbCourse"] = lua.execute(SC.luau_to_lua(SC.read(MODULES / "CloudClimbCourse.lua")))
    lobby_service = lua.execute(SC.luau_to_lua(source if source is not None else SC.read(LOBBY_FILE)))
    base = modules["MatchConfig"].LobbyPosition
    parts, prompts, lights, spawn = [], [], 0, None
    for row in lua.eval(DUMP)(lobby_service, base, plant).split("\n"):
        f = row.split("|")
        if f[0] == "P":
            p = Part()
            p.group, p.name, p.cls, p.shape = f[1], f[2], f[3], f[4]
            p.anchored, p.collide = f[5] == "true", f[6] == "true"
            p.transparency, p.cgroup, p.bobs = float(f[7]), f[8], f[9] == "1"
            n = list(map(float, f[10].split()))
            p.size, p.pos = np.array(n[0:3]), np.array(n[3:6])
            p.r, p.u, p.b = np.array(n[6:9]), np.array(n[9:12]), np.array(n[12:15])
            p.planes = planes_of(p)
            p.index = len(parts)
            parts.append(p)
        elif f[0] == "Q":
            prompts.append({"group": f[1], "parent": f[2], "object": f[3], "action": f[4], "reach": float(f[5]),
                            "pos": np.array(list(map(float, f[6].split())))})
        elif f[0] == "L":
            lights += 1
        elif f[0] == "S":
            spawn = (float(f[1]), float(f[2]), float(f[3]), float(f[4]))
    return parts, prompts, lights, spawn


def planes_of(p):
    """Half-spaces (n, d), n.x <= d, bounding the part (a cylinder as a 16-sided prism)."""
    sx, sy, sz = p.size / 2
    c = p.pos
    out = []
    if "Ball" in p.shape:
        return None
    if "Cylinder" in p.shape:
        rad = min(sy, sz)
        out += [(p.r, sx + p.r @ c), (-p.r, sx - p.r @ c)]
        for k in range(16):
            a = k / 16 * 2 * math.pi
            n = math.cos(a) * p.u + math.sin(a) * p.b
            out.append((n, rad + n @ c))
        return out
    out += [(p.r, sx + p.r @ c), (-p.r, sx - p.r @ c), (-p.u, sy - (p.u @ c))]
    if p.cls == "WedgePart":
        out.append((p.b, sz + p.b @ c))
        n = sz * p.u - sy * p.b
        n = n / np.linalg.norm(n)
        out.append((n, n @ c))
    else:
        out += [(p.u, sy + p.u @ c), (p.b, sz + p.b @ c), (-p.b, sz - p.b @ c)]
    return out


def column_extent(p, X, Z, margin=0.0):
    """Where a vertical line at each (X, Z) passes through the part: (lo, hi) arrays, lo > hi = missed.
    `margin` grows the part sideways (a player's radius)."""
    if p.planes is None:
        rad = min(p.size) / 2 + margin
        d2 = rad * rad - (X - p.pos[0]) ** 2 - (Z - p.pos[2]) ** 2
        h = np.sqrt(np.maximum(d2, 0))
        lo, hi = p.pos[1] - h, p.pos[1] + h
        return np.where(d2 > 0, lo, np.inf), np.where(d2 > 0, hi, -np.inf)
    lo = np.full(X.shape, -np.inf)
    hi = np.full(X.shape, np.inf)
    for n, d in p.planes:
        nh = math.hypot(n[0], n[2])
        rhs = d + margin * nh - n[0] * X - n[2] * Z
        if n[1] > 1e-6:
            hi = np.minimum(hi, rhs / n[1])
        elif n[1] < -1e-6:
            lo = np.maximum(lo, rhs / n[1])
        else:
            bad = rhs < 0
            lo = np.where(bad, np.inf, lo)
    return lo, hi


def plan_box(p, margin=0.0):
    ext = np.abs(p.r) * p.size[0] / 2 + np.abs(p.u) * p.size[1] / 2 + np.abs(p.b) * p.size[2] / 2
    return p.pos - ext - margin, p.pos + ext + margin


def solid(p):
    """Does a player stand on / bump into it? Anchored, collidable, not a wall only the balls hit."""
    return p.anchored and p.collide and p.cgroup != "BallWalls"


class World:
    """Per-cell lists of what stands in the column: (lo, hi) solid, and (lo, hi) grown by a radius."""

    def __init__(self, parts):
        self.nx = int((GRID_X[1] - GRID_X[0]) / CELL)
        self.nz = int((GRID_Z[1] - GRID_Z[0]) / CELL)
        self.solid = [[] for _ in range(self.nx * self.nz)]
        self.block = [[] for _ in range(self.nx * self.nz)]
        for p in parts:
            if not solid(p):
                continue
            for store, margin in ((self.solid, 0.0), (self.block, RADIUS)):
                lo_b, hi_b = plan_box(p, margin)
                i0 = max(0, int(math.floor((lo_b[0] - GRID_X[0]) / CELL)))
                i1 = min(self.nx - 1, int(math.ceil((hi_b[0] - GRID_X[0]) / CELL)))
                k0 = max(0, int(math.floor((lo_b[2] - GRID_Z[0]) / CELL)))
                k1 = min(self.nz - 1, int(math.ceil((hi_b[2] - GRID_Z[0]) / CELL)))
                if i1 < i0 or k1 < k0:
                    continue
                I, K = np.meshgrid(np.arange(i0, i1 + 1), np.arange(k0, k1 + 1), indexing="ij")
                X = GRID_X[0] + (I + 0.5) * CELL
                Z = GRID_Z[0] + (K + 0.5) * CELL
                lo, hi = column_extent(p, X, Z, margin)
                hit = lo < hi
                for i, k, a, c in zip(I[hit], K[hit], lo[hit], hi[hit]):
                    store[i * self.nz + k].append((float(a), float(c), p.index))

    def cell(self, x, z):
        i = int(math.floor((x - GRID_X[0]) / CELL))
        k = int(math.floor((z - GRID_Z[0]) / CELL))
        if 0 <= i < self.nx and 0 <= k < self.nz:
            return i * self.nz + k
        return None

    def centre(self, idx):
        return GRID_X[0] + (idx // self.nz + 0.5) * CELL, GRID_Z[0] + (idx % self.nz + 0.5) * CELL

    def floors(self, idx):
        """Heights a player can stand at in this cell: tops of solids with head room over them."""
        out = []
        for _, top, _ in self.solid[idx]:
            if any(lo < top + HEAD and hi > top + 0.05 for lo, hi, _ in self.solid[idx]):
                continue
            if any(lo < top + HEAD and hi > top + STEP for lo, hi, _ in self.block[idx]):
                continue
            if all(abs(top - h) > 0.05 for h in out):
                out.append(top)
        return out

    def walk(self, starts):
        """Flood from the start cells; returns {(cell, height)}."""
        floor_cache = {}

        def floors(idx):
            if idx not in floor_cache:
                floor_cache[idx] = self.floors(idx)
            return floor_cache[idx]
        seen = set()
        queue = deque()
        for idx, h in starts:
            for f in floors(idx):
                if abs(f - h) < 1.0 and (idx, f) not in seen:
                    seen.add((idx, f))
                    queue.append((idx, f))
        while queue:
            idx, h = queue.popleft()
            i, k = divmod(idx, self.nz)
            for di in (-2, -1, 0, 1, 2):
                for dk in (-2, -1, 0, 1, 2):
                    if not (di or dk):
                        continue
                    ni, nk = i + di, k + dk
                    if not (0 <= ni < self.nx and 0 <= nk < self.nz):
                        continue
                    near = abs(di) <= 1 and abs(dk) <= 1
                    nidx = ni * self.nz + nk
                    for f in floors(nidx):
                        rise = f - h
                        if rise > (STEP if near else JUMP) or (not near and rise < -JUMP * 3):
                            continue
                        if rise > STEP and not near and not self.clear_above(i * self.nz + k, h, f + HEAD):
                            continue
                        if (nidx, f) not in seen:
                            seen.add((nidx, f))
                            queue.append((nidx, f))
        return seen

    def clear_above(self, idx, h, top):
        return not any(lo < top and hi > h + 0.05 for lo, hi, _ in self.solid[idx])

    def line_clear(self, a, b, ignore):
        """Nothing solid (bar `ignore`) on the segment a->b, sampled every 0.4 studs; the last stud is
        the prompt's own fixture."""
        length = float(np.linalg.norm(b - a))
        steps = max(1, int(length / 0.4))
        for s in range(steps):
            t = s / steps
            if length * (1 - t) < 1.0:
                break
            q = a + (b - a) * t
            idx = self.cell(q[0], q[2])
            if idx is None:
                continue
            for lo, hi, pi in self.solid[idx]:
                if pi not in ignore and lo < q[1] < hi:
                    return False
        return True


# What has to be there, and how it is reached. `find` picks prompts/parts; `need` how many at least.
PROMPTS = [
    ("Trade Board vendor", lambda q: q["object"] == "Trade Board", 1),
    ("Cosmetics vendor", lambda q: q["object"] == "Cosmetics", 1),
    ("Daily Spin", lambda q: q["object"] == "Daily Spin", 1),
    ("crate keys", lambda q: q["parent"].startswith("CrateKey_"), 3),
    ("range guns", lambda q: q["parent"] == "RangePodium", 3),
]
OBBY_PROMPTS = [
    ("Cloud Climb start-over", lambda q: q["object"] == "Cloud Climb", 1),
    ("Cloud Climb checkpoints", lambda q: q["object"] == "Sap Lantern", 1),
]
PADS = [  # stood on
    ("ready pad (the queue for the next drop)", lambda p: p.name == "ReadyPad", 1),
]
NEAR = [  # (label, find, need, how close a standing spot must come in plan)
    ("range terrace", lambda p: p.name == "ArenaRamp", 2, 3.0),
    ("play balls", lambda p: p.name == "PlayBall", 1, 4.0),
    ("goal", lambda p: p.name == "GoalZone", 1, 6.0),
    ("leaderboard pylons", lambda p: p.group == "Boards", 1, 16.0),
]


def reach_checks(parts, prompts, spawn, world, reached):
    problems, stats = [], {}
    stand = {}
    for idx, h in reached:
        stand.setdefault(idx, []).append(h)
    spots = [(world.centre(idx), h) for idx, hs in stand.items() for h in hs]
    xs = np.array([s[0][0] for s in spots])
    zs = np.array([s[0][1] for s in spots])
    hs = np.array([s[1] for s in spots])

    for label, find, need in PROMPTS + OBBY_PROMPTS:
        hits = [q for q in prompts if find(q)]
        if len(hits) < need:
            problems.append(f"A: {label}: {len(hits)} prompt(s), want {need}+")
            continue
        if (label, find, need) in OBBY_PROMPTS:
            continue  # reached by the climb itself (cloud_climb checks), not on foot
        for q in hits:
            px, py, pz = q["pos"]
            reach = q["reach"] - 0.5
            chest = hs + 2.5
            d = np.sqrt((xs - px) ** 2 + (zs - pz) ** 2 + (chest - py) ** 2)
            order = np.argsort(d)
            ok = False
            own = {p.index for p in parts if p.name == q["parent"] and np.linalg.norm(p.pos - q["pos"]) < 0.01}
            for n in order[:400]:
                if d[n] > reach:
                    break
                if world.line_clear(np.array([xs[n], chest[n], zs[n]]), q["pos"], own):
                    ok = True
                    break
            where = f"({px:.0f}, {py:.0f}, {pz:.0f})"
            if not ok:
                problems.append(f"B: {label} '{q['action']} {q['object']}' at {where}: no spot walkable from the spawn "
                                f"within {q['reach']:.0f} studs with a clear line to it (nearest walkable {d[order[0]]:.1f})")
        stats[label] = len(hits)

    for label, find, need in PADS:
        hits = [p for p in parts if find(p)]
        if len(hits) < need:
            problems.append(f"A: {label}: missing")
            continue
        for p in hits:
            top = float(column_extent(p, np.array([p.pos[0]]), np.array([p.pos[2]]))[1][0])
            lo_b, hi_b = plan_box(p)
            on = (xs > lo_b[0]) & (xs < hi_b[0]) & (zs > lo_b[2]) & (zs < hi_b[2]) & (np.abs(hs - top) < 0.6)
            if not on.any():
                problems.append(f"B: {label} at ({p.pos[0]:.0f}, {p.pos[2]:.0f}): nobody can walk onto it from the spawn")
        stats[label] = len(hits)

    for label, find, need, near in NEAR:
        hits = [p for p in parts if find(p)]
        if len(hits) < need:
            problems.append(f"A: {label}: {len(hits)}, want {need}+")
            continue
        for p in hits:
            lo_b, hi_b = plan_box(p)
            dx = np.maximum(0, np.maximum(lo_b[0] - xs, xs - hi_b[0]))
            dz = np.maximum(0, np.maximum(lo_b[2] - zs, zs - hi_b[2]))
            if not (np.hypot(dx, dz) <= near).any():
                problems.append(f"B: {label} '{p.name}' at ({p.pos[0]:.0f}, {p.pos[2]:.0f}): no walkable spot within {near}")
                break
        stats[label] = len(hits)
    return problems, stats


def obb_overlap(p, q):
    """Penetration depth of two parts as boxes (separating axes); <= 0 means apart."""
    axes = [p.r, p.u, p.b, q.r, q.u, q.b]
    for a in (p.r, p.u, p.b):
        for c in (q.r, q.u, q.b):
            x = np.cross(a, c)
            n = np.linalg.norm(x)
            if n > 1e-6:
                axes.append(x / n)
    t = q.pos - p.pos
    depth = math.inf
    for ax in axes:
        rp = abs(p.r @ ax) * p.size[0] / 2 + abs(p.u @ ax) * p.size[1] / 2 + abs(p.b @ ax) * p.size[2] / 2
        rq = abs(q.r @ ax) * q.size[0] / 2 + abs(q.u @ ax) * q.size[1] / 2 + abs(q.b @ ax) * q.size[2] / 2
        depth = min(depth, rp + rq - abs(t @ ax))
        if depth <= 0:
            return depth
    return depth


def is_ground(p):
    """The island's paving and turf: upright discs round the plaza centre, which dressing stands in."""
    upright = "Cylinder" in p.shape and abs(p.r[1]) > 0.999
    return p.group == "Island" and upright and math.hypot(p.pos[0], p.pos[2]) < 1


def dressing_checks(parts, group="Wayfinding"):
    problems = []
    mine = [p for p in parts if p.group == group and p.transparency < 0.98]
    others = [p for p in parts if p.group != group and p.transparency < 0.98 and p.anchored]
    boxes = {p.index: plan_box(p) for p in parts}

    def near(a, b, grow):
        la, ha = boxes[a.index]
        lb, hb = boxes[b.index]
        return np.all(la - grow <= hb) and np.all(lb - grow <= ha)
    # C1 clipping: into another set piece (the ground excepted, which posts stand in).
    for p in mine:
        for q in others:
            if is_ground(q) or not near(p, q, 0):
                continue
            depth = obb_overlap(p, q)
            if depth > 0.08:
                problems.append(f"C: clipping: {group}:{p.name} at ({p.pos[0]:.1f}, {p.pos[1]:.1f}, {p.pos[2]:.1f}) "
                                f"is {depth:.2f} into {q.group}:{q.name}")
                break
    # C2 floating: lumps of touching dressing that touch nothing else.
    parent = {p.index: p.index for p in mine}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for n, p in enumerate(mine):
        for q in mine[n + 1:]:
            if near(p, q, 0.05) and obb_overlap(p, q) > -0.05:
                parent[find(p.index)] = find(q.index)
    lumps = {}
    for p in mine:
        lumps.setdefault(find(p.index), []).append(p)
    for lump in lumps.values():
        if any(p.bobs for p in lump):
            continue
        grounded = any(near(p, q, 0.05) and obb_overlap(p, q) > -0.05 for p in lump for q in others)
        if not grounded:
            p = lump[0]
            problems.append(f"C: floating: {len(lump)} {group} part(s) round {p.name} at "
                            f"({p.pos[0]:.1f}, {p.pos[1]:.1f}, {p.pos[2]:.1f}) touch nothing else")
    return problems, len(mine), len(lumps)


def budget_checks(parts, lights, lobby_budget=LOBBY_BUDGET):
    problems = []
    way = sum(1 for p in parts if p.group == "Wayfinding")
    if len(parts) > lobby_budget:
        problems.append(f"D: {len(parts)} lobby parts, budget {lobby_budget}")
    if way > WAYFINDING_BUDGET:
        problems.append(f"D: {way} Wayfinding parts, budget {WAYFINDING_BUDGET}")
    if lights > LIGHT_BUDGET:
        problems.append(f"D: {lights} lights, budget {LIGHT_BUDGET}")
    return problems, way


def exemption_checks(destructible, match):
    problems = []
    if not re.search(r'lobby\.Name = "Lobby"', match) or "LobbyService.Build(lobby, base)" not in match:
        problems.append('E: MatchService no longer builds the lobby under a model named "Lobby"')
    never = re.search(r"local NEVER = \{(.*?)\}", destructible, re.S)
    if not never or not re.search(r"\bLobby = true", never.group(1)):
        problems.append('E: DestructibleService.NEVER no longer keeps "Lobby" whole')
    return problems


_BUILT = {}


def run(source=None, plant=None, destructible=None, match=None, lobby_budget=LOBBY_BUDGET, draw=None, walk=True):
    """All five checks; `walk=False` skips the walk (A and B), for plants that cannot touch it."""
    key = (source, plant)
    if key not in _BUILT:
        _BUILT.clear()
        _BUILT[key] = build(source, plant)
    parts, prompts, lights, spawn = _BUILT[key]
    problems = []
    if not walk:
        problems += dressing_checks(parts)[0]
        problems += budget_checks(parts, lights, lobby_budget)[0]
        problems += exemption_checks(destructible or SC.read(MODULES / "DestructibleService.lua"),
                                     match or SC.read(MODULES / "MatchService.lua"))
        return problems, {}
    world = World(parts)
    sx, sy, sz, half = spawn
    starts = []
    for x in np.arange(-half + 2, half - 1, 1.0):
        for z in np.arange(-8, 9, 2.0):
            idx = world.cell(sx + x, sz + z)
            if idx is not None:
                starts.append((idx, sy + 0.5))
    reached = world.walk(starts)
    if not reached:
        problems.append("B: nowhere walkable at the spawn")
    rp, stats = reach_checks(parts, prompts, spawn, world, reached)
    problems += rp
    dp, dressing, lumps = dressing_checks(parts)
    problems += dp
    bp, way = budget_checks(parts, lights, lobby_budget)
    problems += bp
    problems += exemption_checks(destructible or SC.read(MODULES / "DestructibleService.lua"),
                                 match or SC.read(MODULES / "MatchService.lua"))
    if draw:
        draw_map(world, reached, prompts, draw)
    info = dict(parts=len(parts), lights=lights, way=way, reached=len(reached), stats=stats, lumps=lumps)
    return problems, info


def draw_map(world, reached, prompts, path):
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (world.nx, world.nz), (20, 20, 28))
    px = img.load()
    for idx in range(world.nx * world.nz):
        if world.solid[idx]:
            top = max(h for _, h, _ in world.solid[idx])
            g = int(max(40, min(200, 120 + top * 6)))
            px[idx // world.nz, idx % world.nz] = (g, g, g)
    for idx, _ in reached:
        px[idx // world.nz, idx % world.nz] = (80, 200, 110)
    d = ImageDraw.Draw(img)
    for q in prompts:
        x = (q["pos"][0] - GRID_X[0]) / CELL
        z = (q["pos"][2] - GRID_Z[0]) / CELL
        d.ellipse([x - 2, z - 2, x + 2, z + 2], fill=(255, 60, 60))
    img = img.resize((world.nx * 3, world.nz * 3), Image.NEAREST)
    img.save(path)


def plants(source):
    """(what, code, run kwargs)"""
    out = []
    cos = 'tabPrompt(counter, "Browse", "Cosmetics", "Cosmetics")'
    out.append(("the Cosmetics vendor's prompt gone", "A", dict(source=source.replace(cos, "", 1)) if cos in source else None))
    out.append(("the Trade Board sealed behind four walls", "B", dict(source=source, plant="seal")))
    sink = '{ key = "Market", degrees = 240, radius = 60,'
    out.append(("a gateway sunk into the Trading Hall", "C",
                dict(source=source.replace(sink, '{ key = "Market", degrees = 225, radius = 80,', 1), walk=False)
                if sink in source else None))
    hang = "local BANNER_DROP = 0\n"
    out.append(("a banner hung in the air", "C",
                dict(source=source.replace(hang, "local BANNER_DROP = -30\n", 1), walk=False) if hang in source else None))
    out.append(("the part budget blown", "D", dict(source=source, lobby_budget=1000, walk=False)))
    destructible = SC.read(MODULES / "DestructibleService.lua")
    out.append(('"Lobby" dropped from NEVER', "E",
                dict(source=source, destructible=destructible.replace("Lobby = true,", "", 1), walk=False)))
    return out


def main():
    source = SC.read(LOBBY_FILE)
    draw = sys.argv[sys.argv.index("--map") + 1] if "--map" in sys.argv else None
    problems, info = run(source, draw=draw)
    for p in problems[:40]:
        print("FAIL", p)
    print(f"lobby_layout_check: {info['parts']} parts (budget {LOBBY_BUDGET}), Wayfinding {info['way']} "
          f"(budget {WAYFINDING_BUDGET}) in {info['lumps']} lumps, {info['lights']} lights (budget {LIGHT_BUDGET}); "
          f"{info['reached']} standing spots walkable from the spawn; "
          + ", ".join(f"{k} {v}" for k, v in info["stats"].items()))
    caught = 0
    cases = plants(source)
    for what, code, kwargs in cases:
        if kwargs is None:
            print(f"PLANT {what}: the text to break is not in LobbyService.lua any more")
            continue
        try:
            planted, _ = run(**kwargs)
        except Exception as err:  # a plant that breaks the run is caught too
            planted = [f"{code}: run failed: {str(err)[:200]}"]
        hit = [p for p in planted if p.startswith(code + ":") and p not in problems]
        caught += bool(hit)
        print(f"{'CAUGHT' if hit else 'MISSED'} plant: {what}" + (f" -- {hit[0]}" if hit else ""))
    print(f"lobby_layout_check: {len(problems)} problem(s), planted faults caught {caught} of {len(cases)}")
    return 1 if problems or caught != len(cases) else 0


if __name__ == "__main__":
    sys.exit(main())
