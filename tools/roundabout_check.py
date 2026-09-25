"""Every town's roundabout (MapDecor.Roundabout, Oliver 09-24: "make high quality roundabouts around the
fountain at the center of the towns ... so things don't clip inside each other"), measured on whole maps built
by the REAL MapGenerator.Build under lupa (tools/car_placement_map.py's world, as tools/roads_check.py uses).

    python3 tools/roundabout_check.py                  every map x SEEDS
    python3 tools/roundabout_check.py --quick          two maps x one seed
    python3 tools/roundabout_check.py --plant          the planted faults, each required to fail its rule
    python3 tools/roundabout_check.py --show           every violation, not just the first few
    python3 tools/roundabout_check.py --map RotRidge --seed 2

Measured on the pieces as built (CFrames, sizes, shapes), per roundabout:

  geometry   ring width, island and fountain sizes against each other and the vehicles: the asphalt ring
             at least the widest vehicle plus 4, no entry lane beside a splitter narrower than it; the island holds the
             fountain with 2 studs to spare; the band a vehicle sweeps going round the circulating path (its
             body turned along it) stays off the island and inside the outer kerb. Classes grow village <
             town < city.
  tangency   the drivable outline (the RingAsphalt pieces' edges with road on one side only) chained round
             O: consecutive edges meet end to end (0.02) and turn no more than TURN_MAX; each fillet ends on
             its street's kerb line at the street's start, running along the street (TANGENT_MAX).
  flush      a 0.5-stud grid over the outline: every point covered by the ring's or the streets' asphalt
             (gap), at the streets' height (seam, 0.01), and by one piece only away from their edges
             (zfight: two faces in one plane); on the carriageway, paint no more than 0.075 proud and
             anything else lying on it (drain grates, covers) no more than 0.02 (raised), no two tops in
             one plane (zfight).
  sweeps     every vehicle design's footprint (VehicleModels, measured built, the biggest and the smallest)
             driven round the circulating path and from every approach to every exit (right, straight on,
             left, U-turn), its front wheels on the path and its rear trailing (a tractrix): each wheel on asphalt at the road's height with nothing raised
             under it but paint (snag_wheel), and the body clear of anything that collides (snag_body).
  clip       no roundabout piece inside anything that isn't the roundabout (buildings, props, lots, trees,
             flags, cars): convex solids, SAT, more than CLIP_TOL deep. Furniture may stand in a street's
             pavement (its foot), but no roundabout surface may overlap a street's.
  float      every roundabout piece standing above the ground touches something.
  in_carriageway  nothing a stud or more tall stands in the carriageway below 4.5 up (lamps and signs go on the
             footway, the island or a splitter); tilt: every post of the roundabout's stands straight.
  fountain   the basin (12 walls, 12 copings), pool, column, bowl and plinth all there, round O, inside the
             island.
  splitter   every approach has its splitter island, give-way line and chevron board; approach: and its give-way
             triangle on the road, keep-right bollard, blue roundabout sign, warning triangle, zebra with dropped
             kerbs, and the edge line round its flare.
  budget     parts per roundabout <= MapDecor.RoundaboutBudget.
  determinism  the first map built twice with its seed gives the same roundabouts, part for part.

Planted faults (--plant): a building overlapping the ring, a kinked approach, a raised seam, a raised drain grate, lamps in
the carriageway, no give-way line,
a missing splitter.
"""

import hashlib
import math
import os
import re
import sys
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car_placement_map as cpm  # noqa: E402
import roads_map  # noqa: E402
from car_placement_luau import luau_to_lua  # noqa: E402
from lupa import LuaRuntime  # noqa: E402

SEEDS = (1, 2)
TURN_MAX = 12.5          # degrees between consecutive outline edges (ring steps 8, fillets <= 10)
TANGENT_MAX = 6.0        # degrees between a fillet's last edge and its street
CLIP_TOL = 0.03
FLUSH_TOL = 0.01
WHEEL_TOL = 0.02
PAINT_MAX = 0.08         # anything this thin over the road is paint, a patch, a drain lid
SHOW = 3
PAINT = {"GiveWay", "GiveWayTriangle", "EdgeLine", "RingArrow", "Crossing", "Dash", "StopLine"}
POSTS = {"LampPost", "LampBase", "SignPost", "Bollard", "BeaconPole", "BeaconBand", "TreeTrunk"}
REAR = 2.6               # a vehicle's axles from its ends (the front wheels follow the path)

_MD = cpm.source_of("MapDecor")
BUDGET = int(re.search(r"MapDecor\.RoundaboutBudget = (\d+)", _MD).group(1))
LIFT = float(re.search(r"MapDecor\.RoadLift = ([\d.]+)", _MD).group(1))

ROAD_NAMES = {"Asphalt", "Kerb", "Pavement", "Crossing", "Dash", "StopLine", "PavementTaper", "DroppedKerb", "JunctionAsphalt",
              "RoadSurface", "RoadCurve", "RoadEdge", "RoadDash", "RoadCentreLine", "BridgeRoad"}
SURFACES = {"RingAsphalt", "Asphalt"}
DRIVABLE = SURFACES | {"JunctionAsphalt", "RoadSurface", "RoadCurve", "BridgeRoad"}

DUMP = r"""
local map, fmt = ...
local out = {}
local function v(x) return fmt("%.4f,%.4f,%.4f", x.X, x.Y, x.Z) end
local function walk(node, chain)
	for _, child in ipairs(node:GetChildren()) do
		if child:IsA("BasePart") then
			local c = child.CFrame
			local shape = child:IsA("Part") and child.Shape and child.Shape.Name or ""
			table.insert(out, fmt("P|%s|%s|%s|%s|%s|%s|%s|%s|%d|%d|%s", child.Name, child.ClassName, chain, v(c.Position),
				v(c.XVector), v(c.YVector), v(c.ZVector), v(child.Size), child.CanCollide and 1 or 0, child.Transparency >= 1 and 1 or 0, shape))
		end
		local name = child.Name
		if child:GetAttribute("TownName") then
			name = "Town:" .. child:GetAttribute("TownName")
		end
		if child.Name == "Roundabout" and child:GetAttribute("Island") then
			local c = child:GetAttribute("Center")
			table.insert(out, fmt("R|%s|%.4f|%.4f|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s", chain, c.X, c.Z, child:GetAttribute("Class"),
				child:GetAttribute("Island"), child:GetAttribute("Outer"), child:GetAttribute("Fillet"), child:GetAttribute("Approach"),
				child:GetAttribute("StreetHalf"), child:GetAttribute("Sidewalk"), child:GetAttribute("Circulate"), child:GetAttribute("Splitter"), child:GetAttribute("ApronOuter")))
		end
		walk(child, chain == "" and name or (chain .. "/" .. name))
	end
end
walk(map, "")
local VehicleModels = require("VehicleModels")
for id in pairs(VehicleModels.Models) do
	local ok, probe = pcall(VehicleModels.BuildStatic, id, Random.new(1), CFrame.new())
	if ok and probe then
		local box, size = probe:GetBoundingBox()
		table.insert(out, fmt("V|%s|%.3f|%.3f", tostring(id), 2 * (math.abs(box.Position.Z) + size.Z / 2), 2 * (math.abs(box.Position.X) + size.X / 2)))
	end
end
return table.concat(out, "\n")
"""


def _vec(text):
    return tuple(float(x) for x in text.split(","))


def build(map_id, seed, faults=None):
    faults = faults or {}
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(cpm.TOOLS, "destruct_mocks.lua"), encoding="utf-8") as f:
        mock = lua.execute(f.read())
    sources = {}
    for name in cpm.REAL_MODULES + cpm.REAL_SHARED:
        src = cpm.terrain_source(faults.get(name)) if name == "MapTerrain" else cpm.apply(cpm.source_of(name), faults.get(name), name)
        sources[name] = luau_to_lua(src)
    lua.globals().VEHICLE_SOURCE = luau_to_lua(cpm.vehicle_source(faults.get("VehicleService")))
    standins = lua.execute(cpm.STANDINS)
    lua.execute(cpm.WORLD, mock, lua.table_from(sources), standins)
    lua.execute(roads_map.MATERIALS, mock)
    lua.execute("math.randomseed(...)", seed)
    started = time.time()
    result = lua.eval('function(mapId) return require("MapGenerator").Build(mapId) end')(map_id)
    seconds = time.time() - started
    text = lua.execute(DUMP, result.map, lua.eval("string.format"))
    sampler = lua.execute(roads_map.SAMPLER)
    parts, rounds, vehicles = [], [], {}
    for line in text.split("\n"):
        f = line.split("|")
        if f[0] == "P":
            parts.append({"name": f[1], "cls": f[2], "chain": f[3], "p": _vec(f[4]), "r": _vec(f[5]), "u": _vec(f[6]), "b": _vec(f[7]),
                          "size": _vec(f[8]), "collide": f[9] == "1", "invisible": f[10] == "1", "shape": f[11]})
        elif f[0] == "R":
            keys = ("class", "island", "outer", "fillet", "approach", "half", "sidewalk", "circulate", "splitter", "apronOuter")
            r = {"chain": f[1] + "/Roundabout", "x": float(f[2]), "z": float(f[3])}
            for k, val in zip(keys, f[4:]):
                r[k] = val if k == "class" else float(val)
            rounds.append(r)
        elif f[0] == "V":
            vehicles[f[1]] = (float(f[2]), float(f[3]))

    def ground(points):
        xs = lua.table_from([p[0] for p in points])
        zs = lua.table_from([p[1] for p in points])
        res = sampler(xs, zs, "ground")
        return [res[i + 1] for i in range(len(points))]
    return {"map": map_id, "seed": seed, "seconds": seconds, "parts": parts, "rounds": rounds, "vehicles": vehicles, "ground": ground}


# ---------------------------------------------------------------- solids

def _add(a, b, s=1.0):
    return (a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s)


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _norm(a):
    n = math.sqrt(_dot(a, a))
    return (a[0] / n, a[1] / n, a[2] / n) if n > 1e-9 else None


class Solid:
    """A part as a convex solid: its corners, face normals and edge directions (cylinders as 12-gon prisms,
    balls as their inscribed box), its XZ bounding box and its top where a vertical line meets it."""

    def __init__(self, part, ball_scale=0.7, cyl_scale=1.0):
        self.part = part
        p, axes, size = part["p"], (part["r"], part["u"], part["b"]), part["size"]
        h = [s / 2 for s in size]
        self.kind = "box"
        if part["cls"] == "WedgePart":
            self.kind = "wedge"
        elif "Cylinder" in part["shape"]:
            self.kind = "cyl"
        elif "Ball" in part["shape"]:
            self.kind = "ball"
        pts, normals, edges = [], list(axes), list(axes)
        if self.kind == "cyl":
            radius = min(h[1], h[2]) * cyl_scale
            normals, edges = [axes[0]], [axes[0]]
            for k in range(12):
                a = k / 12 * 2 * math.pi
                ca, sa = math.cos(a), math.sin(a)
                for sx in (-1, 1):
                    pts.append(_add(_add(_add(p, axes[0], sx * h[0]), axes[1], ca * radius), axes[2], sa * radius))
                normals.append(_add(_add((0, 0, 0), axes[1], math.cos(a + math.pi / 12)), axes[2], math.sin(a + math.pi / 12)))
                edges.append(_add(_add((0, 0, 0), axes[1], -math.sin(a + math.pi / 12)), axes[2], math.cos(a + math.pi / 12)))
            self.radius, self.axis = radius, axes[0]
        else:
            scale = ball_scale if self.kind == "ball" else 1.0
            for sx in (-1, 1):
                for sy in (-1, 1):
                    for sz in (-1, 1):
                        if self.kind == "wedge" and sy > 0 and sz < 0:
                            continue
                        pts.append(_add(_add(_add(p, axes[0], sx * h[0] * scale), axes[1], sy * h[1] * scale), axes[2], sz * h[2] * scale))
            if self.kind == "wedge":
                slope = _norm(_add(_add((0, 0, 0), axes[1], size[2]), axes[2], -size[1]))
                normals.append(slope)
                edges.append(_norm(_add(_add((0, 0, 0), axes[1], size[1]), axes[2], size[2])))
        self.pts, self.normals, self.edges = pts, [n for n in normals if n], [e for e in edges if e]
        xs, ys, zs = [q[0] for q in pts], [q[1] for q in pts], [q[2] for q in pts]
        self.bbox = (min(xs), max(xs), min(zs), max(zs))
        self.y0, self.y1 = min(ys), max(ys)
        self.flat = self.kind in ("box", "wedge") or (self.kind == "cyl" and abs(self.axis[1]) > 0.99)
        if self.kind in ("box", "wedge"):
            from roads_geom import Piece
            self.piece = Piece(part)

    def top_at(self, x, z, eps=0.0):
        """(clearance inside the top face, the top's height) where the vertical through (x, z) meets it."""
        if self.kind == "cyl" and abs(self.axis[1]) > 0.99:
            d = math.hypot(x - self.part["p"][0], z - self.part["p"][2])
            return self.radius - d, self.y1
        if self.kind in ("box", "wedge"):
            return self.piece.inside(x, z)
        c = self.part["p"]
        r = min(self.part["size"]) / 2
        return r - math.hypot(x - c[0], z - c[2]), self.y1


def _project(pts, axis):
    lo = hi = _dot(pts[0], axis)
    for q in pts[1:]:
        d = _dot(q, axis)
        if d < lo:
            lo = d
        elif d > hi:
            hi = d
    return lo, hi


def penetration(a, b):
    """How deep two convex solids overlap (SAT): 0 or less when they don't."""
    if a.bbox[1] < b.bbox[0] or b.bbox[1] < a.bbox[0] or a.bbox[3] < b.bbox[2] or b.bbox[3] < a.bbox[2] or a.y1 < b.y0 or b.y1 < a.y0:
        return -1.0
    axes = a.normals + b.normals
    for e in a.edges:
        for f in b.edges:
            n = _norm(_cross(e, f))
            if n:
                axes.append(n)
    best = math.inf
    for axis in axes:
        a0, a1 = _project(a.pts, axis)
        b0, b1 = _project(b.pts, axis)
        depth = min(a1, b1) - max(a0, b0)
        if depth < best:
            best = depth
            if best <= 0:
                return best
    return best


class Grid:
    def __init__(self, cell=8.0):
        self.cell, self.cells = cell, defaultdict(list)

    def add(self, item, bbox):
        c = self.cell
        for i in range(math.floor(bbox[0] / c), math.floor(bbox[1] / c) + 1):
            for j in range(math.floor(bbox[2] / c), math.floor(bbox[3] / c) + 1):
                self.cells[(i, j)].append(item)

    def near(self, bbox):
        c, seen, out = self.cell, set(), []
        for i in range(math.floor(bbox[0] / c), math.floor(bbox[1] / c) + 1):
            for j in range(math.floor(bbox[2] / c), math.floor(bbox[3] / c) + 1):
                for item in self.cells.get((i, j), ()):
                    if id(item) not in seen:
                        seen.add(id(item))
                        out.append(item)
        return out

    def at(self, x, z):
        return self.cells.get((math.floor(x / self.cell), math.floor(z / self.cell)), ())


# ---------------------------------------------------------------- the layout, recomputed from the spec

ARMS = (("E", 0.0), ("N", math.pi / 2), ("W", math.pi), ("S", 3 * math.pi / 2))


def arm_point(r, theta, u, v):
    c, s = math.cos(theta), math.sin(theta)
    return (r["x"] + c * u - s * v, r["z"] + s * u + c * v)


def outline(r):
    """The drivable outline the spec asks for (MapDecor.RoundaboutOutline's circles, finely), as a polygon."""
    L, h, rf, ro = r["approach"], r["half"], r["fillet"], r["outer"]
    phi = math.atan2(h + rf, L)
    pts = []
    for _, theta in ARMS:
        fm = arm_point(r, theta, L, -(h + rf))
        for k in range(21):
            b = theta + (math.pi - phi) + (math.pi / 2 - (math.pi - phi)) * k / 20
            pts.append((fm[0] + math.cos(b) * rf, fm[1] + math.sin(b) * rf))
        fp = arm_point(r, theta, L, h + rf)
        for k in range(21):
            b = theta - math.pi / 2 + (-(math.pi - phi) + math.pi / 2) * k / 20
            pts.append((fp[0] + math.cos(b) * rf, fp[1] + math.sin(b) * rf))
        for k in range(1, 20):
            a = theta + phi + (math.pi / 2 - 2 * phi) * k / 20
            pts.append((r["x"] + math.cos(a) * ro, r["z"] + math.sin(a) * ro))
    return pts


def margin(r, x, z):
    """How far (x, z) is inside the drivable outline the spec asks for (negative outside): the ring's disc,
    or an approach's throat between its two fillets up to the street's start."""
    dx, dz = x - r["x"], z - r["z"]
    dist = math.hypot(dx, dz)
    best = r["outer"] - dist
    L, h, rf = r["approach"], r["half"], r["fillet"]
    phi = math.atan2(h + rf, L)
    for _, theta in ARMS:
        c, s = math.cos(theta), math.sin(theta)
        u, v = c * dx + s * dz, -s * dx + c * dz
        if u <= 0 or abs(math.atan2(v, u)) > phi:
            continue
        side = 1 if v >= 0 else -1
        fillet = math.hypot(u - L, v - side * (h + rf)) - rf
        best = max(best, min(L - u, fillet))
    return best


def inside_poly(poly, x, z):
    hit = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, zi = poly[i]
        xj, zj = poly[j]
        if (zi > z) != (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi:
            hit = not hit
        j = i
    return hit


def poly_edge_distance(poly, x, z):
    best = math.inf
    for i in range(len(poly)):
        ax, az = poly[i]
        bx, bz = poly[(i + 1) % len(poly)]
        dx, dz = bx - ax, bz - az
        L2 = dx * dx + dz * dz
        t = max(0.0, min(1.0, ((x - ax) * dx + (z - az) * dz) / L2)) if L2 > 0 else 0.0
        best = min(best, math.hypot(ax + dx * t - x, az + dz * t - z))
    return best


def ring_path(r, vehicles):
    """The circle the front wheels go round: far enough out that every vehicle's rear, cutting inside,
    keeps its body half a stud off the island."""
    need = 0.0
    for vl, vw in vehicles.values():
        need = max(need, math.hypot(r["island"] + 0.5 + vw / 2, vl - 2 * REAR))
    return need + 0.2


def lane_centre(r, u):
    """The middle of the entry lane (v < 0) at `u` in an arm's frame: between the splitter (or the centre
    line) and the kerb."""
    L, h, rf, ro, s = r["approach"], r["half"], r["fillet"], r["outer"], r["splitter"]
    u0, u1 = ro + 1.2, L - 6
    if u >= u1 or u < u0:
        inner = 0.0 if u >= u1 else 0.45
    else:
        inner = 0.45 + (s - 0.45) * (u1 - u) / (u1 - u0)
    if u >= L:
        # On the street, a quarter of the way across from the kerb, a little toward the centre line.
        return -(r["half"] / 2 + 0.25)
    else:
        outer = (h + rf) - math.sqrt(max(0.0, rf * rf - (u - L) ** 2))
    return -(inner + outer) / 2


def lane_width(r, u):
    c = lane_centre(r, u)
    if u >= r["approach"]:
        return r["half"]
    L, h, rf, ro, s = r["approach"], r["half"], r["fillet"], r["outer"], r["splitter"]
    outer = (h + rf) - math.sqrt(max(0.0, rf * rf - (u - L) ** 2))
    return 2 * (outer + c)


def ENTRY_LINE(r):
    """In: down the middle of the entry lane to 2 past the ring, on to the circle at the mouth's angle,
    handles 0.6 of the way (tuned on the longest vehicles)."""
    return (r["outer"] + 2.0, 1.0, 0.6, 0)


# The first exit (a right turn) leaves the circle 1.1 times the mouth past its arm, handles 0.4, held 1
# toward the centre line (tuned on the longest vehicles).
FIRST_EXIT_TURN = 1.1
FIRST_EXIT_HAND = 0.4
FIRST_EXIT_HOLD = 1.0


def EXIT_LINE(r):
    """Out: join the street's lane 2 past its start, leave the circle at 1.8 times the mouth's angle,
    handles 0.4 of the way, held 2 toward the centre line (tuned on the longest vehicles)."""
    return (r["approach"] + 2.0, 1.8, 0.4, 2.0)


def paths(r, vehicles):
    """The rear wheels' paths: the circle, and per arm the entry (down the middle of the entry lane, then a
    smooth curve on to the circle) and the exit (its mirror), as lists of (x, z, heading angle)."""
    rp, L, ro = ring_path(r, vehicles), r["approach"], r["outer"]
    out = {"ring": []}
    n = int(2 * math.pi * rp / 0.5)
    for k in range(n):
        a = k / n * 2 * math.pi
        out["ring"].append((r["x"] + math.cos(a) * rp, r["z"] + math.sin(a) * rp, a - math.pi / 2))
    def line(u_join, turn, hand, hold):
        """Down the lane to `u_join`, then a cubic on to the circle at `turn` times the mouth's angle."""
        pts = []
        u = L + 8
        while u > u_join:
            v = lane_centre(r, u)
            pts.append((u, v + hold))
            u -= 0.5
        ax, av = pts[-1]
        alpha = -turn * math.atan2(r["half"] + r["fillet"], L)
        bx, bv = rp * math.cos(alpha), rp * math.sin(alpha)
        tb = (math.sin(alpha), -math.cos(alpha))
        k = hand * math.hypot(bx - ax, bv - av)
        p1 = (ax - k, av)
        p2 = (bx - tb[0] * k, bv - tb[1] * k)
        for i in range(1, 41):
            t = i / 40
            mt = 1 - t
            pts.append((mt ** 3 * ax + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t ** 3 * bx,
                        mt ** 3 * av + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t ** 3 * bv))
        return pts
    # In: down the middle of the entry lane, on to the circle a little past the mouth. Out: leaving the
    # circle earlier and turning more gently straight into the street's lane, so the rear wheels, cutting
    # inside the right turn toward the kerb, have the whole flare to do it in.
    local = line(*ENTRY_LINE(r))
    leaving = line(*EXIT_LINE(r))
    ex = EXIT_LINE(r)
    leaving_first = line(ex[0], FIRST_EXIT_TURN, FIRST_EXIT_HAND, FIRST_EXIT_HOLD)
    entry_turn, exit_turn = ENTRY_LINE(r)[1], EXIT_LINE(r)[1]
    mouth = math.atan2(r["half"] + r["fillet"], L)

    def world(theta, seq, sign):
        return [arm_point(r, theta, u, v * sign) for u, v in seq]

    def headed(points):
        pts = []
        for i, (x, z) in enumerate(points):
            j, k = min(i + 1, len(points) - 1), max(i - 1, 0)
            pts.append((x, z, math.atan2(points[j][1] - points[k][1], points[j][0] - points[k][0])))
        return pts

    names = [a[0] for a in ARMS]
    for i, (name, theta) in enumerate(ARMS):
        # Every way through from this arm: right (the next arm round), straight on, left, and back the
        # way it came.
        for turn, label in ((1, "right"), (2, "straight"), (3, "left"), (4, "U-turn")):
            other = (i - turn) % 4
            theta_out = ARMS[other][1]
            out_seq = world(theta_out, list(reversed(leaving)), -1)
            if True:
                # The first exit leaves the circle sooner, a quarter-turn round from the entry.
                seq_out = leaving_first if turn == 1 else leaving
                out_seq = world(theta_out, list(reversed(seq_out)), -1)
                a_in = theta - entry_turn * mouth
                a_out = theta_out + (FIRST_EXIT_TURN if turn == 1 else exit_turn) * mouth
                while a_out > a_in - 0.05:
                    a_out -= 2 * math.pi
                arc = []
                steps = max(2, int((a_in - a_out) * rp / 0.5))
                for n in range(1, steps):
                    a = a_in + (a_out - a_in) * n / steps
                    arc.append((r["x"] + math.cos(a) * rp, r["z"] + math.sin(a) * rp))
                pts = world(theta, local, 1) + arc + out_seq
            out["%s %s to %s" % (label, name, names[other])] = headed(pts)
    return out


# ---------------------------------------------------------------- measuring

def measure(m, show=False):
    faults = Counter()
    notes = defaultdict(list)
    info = {"rounds": 0, "classes": Counter(), "parts": [], "sweeps": 0}

    def note(rule, text):
        faults[rule] += 1
        notes[rule].append("%s s%d: %s" % (m["map"], m["seed"], text))

    solids = [Solid(p) for p in m["parts"] if not p["invisible"] or p["name"] in SURFACES]
    grid = Grid()
    for s in solids:
        grid.add(s, s.bbox)
    classes_seen = {}
    loose_cache = {}

    def loose(solid):
        # Round things by the polygon round them rather than inside them, for touching.
        if solid.kind not in ("ball", "cyl"):
            return solid
        if id(solid) not in loose_cache:
            loose_cache[id(solid)] = Solid(solid.part, 1.0, 1 / math.cos(math.pi / 12))
        return loose_cache[id(solid)]
    for r in m["rounds"]:
        info["rounds"] += 1
        info["classes"][r["class"]] += 1
        chain = r["chain"]
        cx, cz = r["x"], r["z"]
        reach = math.hypot(r["approach"], r["half"] + r["sidewalk"]) + 30
        box = (cx - reach, cx + reach, cz - reach, cz + reach)
        near = grid.near(box)
        own = [s for s in near if s.part["chain"] == chain or s.part["chain"].startswith(chain + "/")]
        others = [s for s in near if not (s.part["chain"] == chain or s.part["chain"].startswith(chain + "/"))]
        where = "%s (%s) at (%.0f, %.0f)" % (chain.split("/")[0], r["class"], cx, cz)
        info["parts"].append(len(own))
        classes_seen.setdefault(r["class"], (r["island"], r["outer"] - r["island"]))

        # ---- budget
        if len(own) > BUDGET:
            note("budget", "%s has %d parts (budget %d)" % (where, len(own), BUDGET))

        # ---- fountain
        names = Counter(s.part["name"] for s in own)
        for name, least in (("FountainWall", 12), ("FountainCoping", 12), ("FountainPool", 1), ("FountainColumn", 1), ("FountainBowl", 2),
                            ("FountainPlinth", 1), ("IslandKerb", 1)):
            if names[name] < least:
                note("fountain", "%s: %d %s (want %d)" % (where, names[name], name, least))
        fountain_reach = 0.0
        for s in own:
            if s.part["name"].startswith("Fountain") and s.part["name"] != "FountainPlinth":
                for q in s.pts:
                    fountain_reach = max(fountain_reach, math.hypot(q[0] - cx, q[2] - cz))
        pool = [s for s in own if s.part["name"] == "FountainPool"]
        if pool and math.hypot(pool[0].part["p"][0] - cx, pool[0].part["p"][2] - cz) > 0.05:
            note("fountain", "%s: the pool is off the centre" % where)

        # ---- geometry
        island, outer, lane = r["island"], r["outer"], r["outer"] - r["island"]
        if island < fountain_reach + 2 - 1e-6:
            note("geometry", "%s: island %.1f holds a fountain reaching %.1f with under 2 to spare" % (where, island, fountain_reach))
        rc = ring_path(r, m["vehicles"])
        for vid, (vl, vw) in m["vehicles"].items():
            inner = math.sqrt(max(0.0, rc * rc - (vl - 2 * REAR) ** 2)) - vw / 2
            far = math.hypot(rc + vw / 2, REAR)
            if inner < island + 0.5 or far > outer - 0.3:
                note("geometry", "%s: %s (%.1f x %.1f) sweeps %.1f..%.1f round a %.1f..%.1f ring" % (where, vid, vl, vw, inner, far, island, outer))
        wmax = max(vw for _, vw in m["vehicles"].values())
        carriageway = outer - r["apronOuter"]
        if carriageway < wmax + 4 - 1e-6:
            note("geometry", "%s: the ring's asphalt is %.1f wide, under the widest vehicle (%.1f) plus 4" % (where, carriageway, wmax))
        # The splitters never pinch a lane below the widest vehicle.
        u = outer + 1.2
        while u < r["approach"] - 6:
            if lane_width(r, u) < wmax - 1e-6:
                note("geometry", "%s: the entry lane is %.1f wide beside the splitter %.1f out" % (where, lane_width(r, u), u))
                break
            u += 0.5

        # ---- tangency: the RingAsphalt outline, chained
        ring = [s for s in own if s.part["name"] == "RingAsphalt"]
        surf = [s for s in near if s.part["name"] in SURFACES]
        sgrid = Grid(4.0)
        for s in surf:
            sgrid.add(s, s.bbox)

        def covered(x, z, skip=None, eps=0.0):
            for s in sgrid.at(x, z):
                if s is skip:
                    continue
                clear, _ = s.top_at(x, z)
                if clear > eps - 0.005:
                    return True
            return False
        edges = []
        for s in ring:
            poly = s.piece.polygon() if s.kind in ("box", "wedge") else []
            for i in range(len(poly)):
                a, b = poly[i], poly[(i + 1) % len(poly)]
                length = math.hypot(b[0] - a[0], b[1] - a[1])
                if length < 0.05:
                    continue
                nx, nz = -(b[1] - a[1]) / length, (b[0] - a[0]) / length
                mx, mz = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                left = covered(mx + nx * 0.03, mz + nz * 0.03)
                right = covered(mx - nx * 0.03, mz - nz * 0.03)
                if left != right:
                    edges.append((a, b))
        # Order round O, then each edge from its lower-angle end.
        chain_edges = []
        for a, b in edges:
            aa = math.atan2(a[1] - cz, a[0] - cx)
            ab = math.atan2(b[1] - cz, b[0] - cx)
            d = (ab - aa + math.pi) % (2 * math.pi) - math.pi
            if d < 0:
                a, b, aa = b, a, ab
            chain_edges.append(((aa + 2 * math.pi) % (2 * math.pi), a, b))
        chain_edges.sort()
        worst_turn = 0.0
        for i in range(len(chain_edges)):
            _, a, b = chain_edges[i]
            _, c2, d2 = chain_edges[(i + 1) % len(chain_edges)]
            gap = math.hypot(c2[0] - b[0], c2[1] - b[1])
            if gap > 0.02:
                # Allowed only across a street's end: from (L, -h) to (L, h) of some arm.
                ok = False
                for _, theta in ARMS:
                    p1 = arm_point(r, theta, r["approach"], -r["half"])
                    p2 = arm_point(r, theta, r["approach"], r["half"])
                    if math.hypot(b[0] - p1[0], b[1] - p1[1]) < 0.02 and math.hypot(c2[0] - p2[0], c2[1] - p2[1]) < 0.02:
                        ok = True
                        # Both fillets' last edges run along the street there.
                        for (e0, e1), toward in (((a, b), 1), ((c2, d2), -1)):
                            dx, dz = e1[0] - e0[0], e1[1] - e0[1]
                            ang = abs(math.degrees(math.atan2(-math.sin(theta) * dx + math.cos(theta) * dz,
                                                              math.cos(theta) * dx + math.sin(theta) * dz)))
                            ang = min(ang, 180 - ang)
                            if ang > TANGENT_MAX:
                                note("kink", "%s: a fillet meets its street at %.1f deg" % (where, ang))
                if not ok:
                    note("kink", "%s: the outline breaks %.2f studs at (%.1f, %.1f)" % (where, gap, b[0], b[1]))
                continue
            t1 = math.atan2(b[1] - a[1], b[0] - a[0])
            t2 = math.atan2(d2[1] - c2[1], d2[0] - c2[0])
            turn = abs(math.degrees((t2 - t1 + math.pi) % (2 * math.pi) - math.pi))
            worst_turn = max(worst_turn, turn)
            if turn > TURN_MAX:
                note("kink", "%s: the kerb line turns %.1f deg at (%.1f, %.1f)" % (where, turn, b[0], b[1]))
        info.setdefault("worst_turn", 0.0)
        info["worst_turn"] = max(info["worst_turn"], worst_turn)

        # ---- flush and gaps over the ideal outline
        ogrid_flat = Grid(4.0)
        for s in near:
            if s.part["name"] not in SURFACES and not s.part["invisible"] and s.flat and s.y0 >= LIFT - 0.05 and s.y1 <= LIFT + 0.3:
                ogrid_flat.add(s, s.bbox)
        top0 = LIFT
        step = 0.5
        x = cx - reach
        while x <= cx + reach:
            z = cz - reach
            while z <= cz + reach:
                if margin(r, x, z) > 0.25:
                    hits = []
                    for s in sgrid.at(x, z):
                        clear, y = s.top_at(x, z)
                        if clear > -0.005:
                            hits.append((clear, y, s))
                    if not hits:
                        note("gap", "%s: no asphalt at (%.1f, %.1f)" % (where, x, z))
                    else:
                        for clear, y, s in hits:
                            if abs(y - top0) > FLUSH_TOL:
                                note("seam", "%s: %s top %.3f off the road's at (%.1f, %.1f)" % (where, s.part["name"], y - top0, x, z))
                        deep = [h for h in hits if h[0] > 0.02]
                        if len(deep) > 1:
                            note("zfight", "%s: %d surface pieces overlap at (%.1f, %.1f)" % (where, len(deep), x, z))
                    # What lies on the carriageway (off the apron): paint up to 0.075 proud, anything else (a
                    # patch, a grate, a cover) up to 0.02, and no two of them with their tops in one plane.
                    if math.hypot(x - cx, z - cz) > r["apronOuter"] + 0.05:
                        tops = []
                        for s in ogrid_flat.at(x, z):
                            clear, y = s.top_at(x, z)
                            if clear > 0.02:
                                tops.append((y, s))
                                limit = 0.075 if s.part["name"] in PAINT else 0.02
                                if y - top0 > limit + 1e-4:
                                    note("raised", "%s: %s stands %.3f proud of the road at (%.1f, %.1f)" % (where, s.part["name"], y - top0, x, z))
                        tops.sort(key=lambda t: t[0])
                        for (ya, sa), (yb, sb) in zip(tops, tops[1:]):
                            if abs(ya - yb) < 0.004:
                                note("zfight", "%s: %s and %s tops in one plane at (%.1f, %.1f)" % (where, sa.part["name"], sb.part["name"], x, z))
                z += step
            x += step

        # ---- sweeps
        wheel_grid = Grid(4.0)
        body_grid = Grid(8.0)
        for s in near:
            if s.part["invisible"]:
                continue
            wheel_grid.add(s, s.bbox)
            if s.part["collide"]:
                body_grid.add(s, s.bbox)
        cars = [(vid, vl, vw) for vid, (vl, vw) in sorted(m["vehicles"].items())]
        for key, pts in paths(r, m["vehicles"]).items():
            for vid, vl, vw in cars:
                bad_wheel = bad_body = None
                wb = vl - 2 * REAR
                # The front axle follows the path; the rear trails it (a tractrix), cutting the corners.
                laps = pts + pts[: len(pts) // 2] if key == "ring" else pts
                fx0, fz0 = math.cos(laps[0][2]), math.sin(laps[0][2])
                rx, rz = laps[0][0] - fx0 * wb, laps[0][1] - fz0 * wb
                for i, (px, pz, _) in enumerate(laps):
                    dx, dz = px - rx, pz - rz
                    d = math.hypot(dx, dz)
                    fx, fz = dx / d, dz / d
                    rx, rz = px - fx * wb, pz - fz * wb
                    if (key == "ring" and i < len(pts) // 2) or i % 2:
                        continue
                    info["sweeps"] += 1
                    sx, sz = -fz, fx
                    for ax, ay in ((rx, rz), (px, pz)):
                        for b in (1, -1):
                            wx, wz = ax + sx * b * (vw / 2 - 1.2), ay + sz * b * (vw / 2 - 1.2)
                            road, raised = None, None
                            for s in wheel_grid.at(wx, wz):
                                clear, y = s.top_at(wx, wz)
                                # A seam between two pieces is on both (a point exactly on it can read as on neither).
                                if clear <= (-0.01 if s.part["name"] in DRIVABLE else 0):
                                    continue
                                if s.part["name"] in DRIVABLE:
                                    road = y if road is None else max(road, y)
                                elif y > top0 + PAINT_MAX and s.y0 < top0 + 1.5 and s.flat:
                                    raised = s
                            if road is None or abs(road - top0) > WHEEL_TOL or raised:
                                bad_wheel = bad_wheel or (wx, wz, raised.part["name"] if raised else ("no road" if road is None else "road at %.3f" % road))
                    mx, mz = (px + rx) / 2, (pz + rz) / 2
                    body = {"name": "body", "cls": "Part", "chain": "", "shape": "", "p": (mx, top0 + 0.6 + 2.8, mz),
                            "r": (sx, 0, sz), "u": (0, 1, 0), "b": (fx, 0, fz), "size": (vw, 5.6, vl), "collide": True, "invisible": False}
                    bs = Solid(body)
                    for s in body_grid.near(bs.bbox):
                        if penetration(bs, s) > CLIP_TOL:
                            bad_body = bad_body or (px, pz, s.part["name"])
                            break
                if bad_wheel:
                    note("snag_wheel", "%s: %s on %s: a wheel at (%.1f, %.1f) on %s" % (where, vid, key, bad_wheel[0], bad_wheel[1], bad_wheel[2]))
                if bad_body:
                    note("snag_body", "%s: %s on %s hits %s at (%.1f, %.1f)" % (where, vid, key, bad_body[2], bad_body[0], bad_body[1]))

        # ---- clip: roundabout pieces inside anything else
        ogrid = Grid(8.0)
        for s in others:
            if not s.part["invisible"]:
                ogrid.add(s, s.bbox)
        for s in own:
            if s.part["invisible"]:
                continue
            for o in ogrid.near(s.bbox):
                if o.part["name"] in ROAD_NAMES:
                    # A foot in a street's pavement is standing on it; a surface or kerb of the roundabout
                    # may only meet a street's edge to edge.
                    if s.part["name"] not in SURFACES and s.part["name"] not in ("Kerb", "Pavement") and s.y0 >= o.y1 - 0.2:
                        continue
                d = penetration(s, o)
                if d > CLIP_TOL:
                    note("clip", "%s: %s inside %s (%s) by %.2f at (%.1f, %.1f)" % (where, s.part["name"], o.part["name"], o.part["chain"][-40:], d,
                                                                                 (s.bbox[0] + s.bbox[1]) / 2, (s.bbox[2] + s.bbox[3]) / 2))
                    break

        # ---- furniture of its own standing in its own pavement, kerbs or road (a foot may stand on them)
        base = [s for s in own if s.part["name"] in SURFACES or s.part["name"] in ("Kerb", "Pavement")]
        bgrid = Grid(8.0)
        for s in base:
            bgrid.add(s, s.bbox)
        standing = {"IslandKerb", "IslandApron", "IslandEdge", "IslandBed", "FountainPlinth", "SplitterKerb", "SplitterTop"}
        for s in own:
            n = s.part["name"]
            if n in SURFACES or n in ("Kerb", "Pavement") or n in standing or s.part["invisible"] or s.y1 < LIFT + PAINT_MAX + 0.01:
                continue
            for o in bgrid.near(s.bbox):
                if s.y0 >= o.y1 - 0.25:
                    continue
                d = penetration(s, o)
                if d > CLIP_TOL:
                    note("clip", "%s: %s inside its own %s by %.2f at (%.1f, %.1f)" % (where, n, o.part["name"], d, (s.bbox[0] + s.bbox[1]) / 2,
                                                                                    (s.bbox[2] + s.bbox[3]) / 2))
                    break

        # ---- float
        lows = [((s.bbox[0] + s.bbox[1]) / 2, (s.bbox[2] + s.bbox[3]) / 2) for s in own]
        heights = m["ground"](lows)
        for s, g in zip(own, heights):
            # The fountain's spray and jets are water in the air.
            if s.y0 <= g + 0.1 or s.part["name"] in ("FountainSpray", "FountainJet"):
                continue
            support = False
            for o in grid.near((s.bbox[0] - 0.05, s.bbox[1] + 0.05, s.bbox[2] - 0.05, s.bbox[3] + 0.05)):
                if o is not s and penetration(loose(s), loose(o)) > -0.03:
                    support = True
                    break
            if not support:
                note("float", "%s: %s at (%.1f, %.1f) %.2f up touches nothing" % (where, s.part["name"], lows[own.index(s)][0], lows[own.index(s)][1], s.y0 - g))

        # ---- nothing upright stands in the carriageway (off the island and the splitters), and posts stand straight
        for s in near:
            p = s.part
            if p["invisible"] or s.y1 - s.y0 < 1.0 or s.y0 > LIFT + 4.5:
                continue
            x, z = p["p"][0], p["p"][2]
            if margin(r, x, z) <= 0.3 or math.hypot(x - cx, z - cz) < island + 0.3:
                continue
            on_splitter = False
            for _, theta in ARMS:
                c, sn = math.cos(theta), math.sin(theta)
                u, v = c * (x - cx) + sn * (z - cz), -sn * (x - cx) + c * (z - cz)
                if outer + 1.0 < u < r["approach"] - 5.8 and abs(v) < r["splitter"] + 0.2:
                    on_splitter = True
            if not on_splitter:
                note("in_carriageway", "%s: %s (%s) stands in the carriageway at (%.1f, %.1f)" % (where, p["name"], p["chain"][-30:], x, z))
        for s in own:
            if s.part["name"] in POSTS and abs(s.part["r"][1]) < 0.999:
                note("tilt", "%s: %s leans %.1f deg at (%.1f, %.1f)" % (where, s.part["name"], math.degrees(math.acos(min(1, abs(s.part["r"][1])))),
                                                                     s.part["p"][0], s.part["p"][2]))

        # ---- splitters, give way, chevrons
        for name, theta in ARMS:
            c, sn = math.cos(theta), math.sin(theta)

            def local(s):
                px, pz = s.part["p"][0] - cx, s.part["p"][2] - cz
                return c * px + sn * pz, -sn * px + c * pz
            splits = [s for s in own if s.part["name"] == "SplitterKerb" and outer < local(s)[0] < r["approach"] and abs(local(s)[1]) < r["splitter"] + 0.5]
            if not splits:
                note("splitter", "%s: no splitter island on the %s approach" % (where, name))
            gives = [s for s in own if s.part["name"] == "GiveWay" and local(s)[0] > outer - 1 and local(s)[1] < 0 and local(s)[0] < r["approach"]]
            if len(gives) < 4:
                note("splitter", "%s: %d give-way dashes on the %s entry" % (where, len(gives), name))
            chev = [s for s in own if s.part["name"] == "ChevronBoard" and 0 < local(s)[0] < island and abs(local(s)[1]) < 1]
            if not chev:
                note("splitter", "%s: no chevron board facing the %s entry" % (where, name))
            L = r["approach"]
            wants = (
                ("give-way triangle marking", own, lambda s: s.part["name"] == "GiveWayTriangle" and outer < local(s)[0] < L and local(s)[1] < 0, 3),
                ("keep-right bollard", own, lambda s: s.part["name"] == "Bollard" and outer < local(s)[0] < L and abs(local(s)[1]) < 1, 1),
                ("blue roundabout sign", own, lambda s: s.part["name"] == "RoundaboutSign" and L - 4 < local(s)[0] < L + 2 and local(s)[1] < 0, 1),
                ("warning triangle", own, lambda s: s.part["name"] == "WarningSign" and L + 2 < local(s)[0] < L + 12 and local(s)[1] < 0, 2),
                ("zebra crossing", others, lambda s: s.part["name"] == "Crossing" and L < local(s)[0] < L + 6, 4),
                ("dropped kerbs at the crossing", others, lambda s: s.part["name"] == "DroppedKerb" and L < local(s)[0] < L + 6, 2),
                ("edge line round the flare", own, lambda s: s.part["name"] == "EdgeLine" and outer - 2 < local(s)[0] < L + 1, 6),
            )
            for what, pool_, test, least in wants:
                got = sum(1 for s in pool_ if test(s))
                if got < least:
                    note("approach", "%s: the %s approach has %d pieces of %s (want %d)" % (where, name, got, what, least))

    info["class_sizes"] = classes_seen
    return faults, notes, info


def own_digest(m):
    rows = []
    for p in m["parts"]:
        if "/Roundabout" in p["chain"]:
            rows.append("%s|%s|%s|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f" % (p["chain"], p["name"], p["cls"], *p["p"], *p["size"]))
    rows.sort()
    return hashlib.sha1("\n".join(rows).encode()).hexdigest(), len(rows)


RULES = ["budget", "fountain", "geometry", "kink", "gap", "seam", "zfight", "raised", "snag_wheel", "snag_body", "clip", "float", "in_carriageway", "tilt",
         "splitter", "approach", "determinism"]

PLANTS = [
    ("a building overlapping the ring (the streets and their buildings start at the old square's edge)", "clip",
     {"MapGenerator": [("local HUB = hub.approach\n", "local HUB = 25\n")]}),
    ("a kinked approach (the streets start 3 studs past the fillets' tangent)", "kink",
     {"MapDecor": [("local approach = math.sqrt((outer + fillet) ^ 2 - (h + fillet) ^ 2)\n",
                    "local approach = math.sqrt((outer + fillet) ^ 2 - (h + fillet) ^ 2) + 3\n")]}),
    ("a raised seam (one piece of the ring 0.05 proud)", "seam",
     {"MapDecor": [("flatTriangle(model, c, a, b, 0, lift, MapDecor.AsphaltColor",
                    "flatTriangle(model, c, a, b, index == 5 and 0.05 or 0, lift + (index == 5 and 0.05 or 0), MapDecor.AsphaltColor")]}),
    ("the medium ring 3 studs too narrow", "geometry",
     {"MapDecor": [("medium = { island = 14.5, apron = 4, lane = 13,", "medium = { island = 14.5, apron = 4, lane = 10,")]}),
    ("a drain grate built as a solid plate 0.2 proud", "raised",
     {"MapDecor": [("\t\tcarrier.Transparency = 1\n", "\t\tcarrier.Transparency = 0\n\t\tcarrier.CFrame += Vector3.new(0, 0.2, 0)\n")]}),
    ("the ring's lamps stood in the carriageway", "in_carriageway",
     {"MapDecor": [("ringLamp(model, polar(c, angle, ro + KERB + 1.6, PAVEMENT_TOP)", "ringLamp(model, polar(c, angle, ro - 3, PAVEMENT_TOP)")]}),
    ("no give-way line on the N entry", "splitter",
     {"MapDecor": [("for _, row in ipairs({ 0.75, 1.45 }) do", "for _, row in ipairs(name == \"N\" and {} or { 0.75, 1.45 }) do")]}),
    ("a missing splitter (the N approach's left off)", "splitter",
     {"MapDecor": [("currentName = \"SplitterKerb\"\n\t\tfor _, tri in ipairs({", "currentName = \"SplitterKerb\"\n\t\tfor _, tri in ipairs(name == \"N\" and {} or {")]}),
]


def run_one(job):
    map_id, seed, faults = job
    m = build(map_id, seed, faults)
    f, n, info = measure(m)
    return map_id, seed, m["seconds"], f, n, info


def main(argv):
    show = "--show" in argv
    quick = "--quick" in argv
    maps = cpm.map_ids()
    seeds = SEEDS
    if "--map" in argv:
        maps = [argv[argv.index("--map") + 1]]
    if "--seed" in argv:
        seeds = (int(argv[argv.index("--seed") + 1]),)
    if quick:
        maps, seeds = maps[:2], (1,)
    if "--plant" in argv:
        failed = 0
        for what, rule, faults in PLANTS:
            total = Counter()
            for map_id in maps[:2]:
                _, _, _, f, _, _ = run_one((map_id, 1, faults))
                total.update(f)
            caught = total[rule] > 0
            failed += 0 if caught else 1
            print("%-8s %-100s %s %d  (all: %s)" % ("CAUGHT" if caught else "MISSED", what, rule, total[rule],
                                                  ", ".join("%s %d" % kv for kv in sorted(total.items()) if kv[1])))
        print("plants: %d of %d caught" % (len(PLANTS) - failed, len(PLANTS)))
        return 1 if failed else 0
    from multiprocessing import Pool
    jobs = [(mid, s, None) for mid in maps for s in seeds]
    with Pool(min(len(jobs), max(1, (os.cpu_count() or 2) - 1))) as pool:
        results = pool.map(run_one, jobs)
    totals = Counter()
    parts, classes, sizes = [], Counter(), {}
    turn = 0.0
    for map_id, seed, seconds, f, n, info in results:
        totals.update(f)
        parts += info["parts"]
        classes.update(info["classes"])
        sizes.update(info["class_sizes"])
        turn = max(turn, info.get("worst_turn", 0.0))
        print("%-14s seed %d %6.1fs  %d roundabouts (%s), parts %s, %d sweeps; faults: %s" % (
            map_id, seed, seconds, info["rounds"], ", ".join("%s %d" % kv for kv in sorted(info["classes"].items())),
            "..".join(str(v) for v in (min(info["parts"]), max(info["parts"]))) if info["parts"] else "-", info["sweeps"],
            ", ".join("%s %d" % kv for kv in sorted(f.items())) or "none"))
        for rule in RULES:
            for text in n.get(rule, [])[: (10000 if show else SHOW)]:
                print("    %-11s %s" % (rule, text))
    # Determinism: the first job again.
    mid, s = jobs[0][0], jobs[0][1]
    a, b = build(mid, s), build(mid, s)
    da, db = own_digest(a), own_digest(b)
    if da != db:
        totals["determinism"] += 1
        print("    determinism %s seed %d built twice differs (%s vs %s)" % (mid, s, da, db))
    order = ["small", "medium", "large"]
    seen = [c for c in order if c in sizes]
    for x, y in zip(seen, seen[1:]):
        if not (sizes[x][0] < sizes[y][0] and sizes[x][1] <= sizes[y][1]):
            totals["geometry"] += 1
            print("    geometry    %s isn't smaller than %s" % (x, y))
    print()
    print("classes built: %s; sizes (island, ring width): %s; parts per roundabout %d..%d (budget %d); worst outline turn %.1f deg; "
          "determinism %s (%d parts)" % (", ".join("%s %d" % kv for kv in sorted(classes.items())),
                                         ", ".join("%s %s" % (k, v) for k, v in sorted(sizes.items())), min(parts), max(parts), BUDGET, turn,
                                         da[0][:10], da[1]))
    print("TOTAL faults: " + ", ".join("%s %d" % (k, totals[k]) for k in RULES))
    return 1 if sum(totals.values()) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
