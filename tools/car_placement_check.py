"""Every car on the map parked the way a real car would be (Oliver 09-24, "make all the car placements
make sense"), measured on whole maps built by the REAL MapGenerator.Build (tools/car_placement_map.py).

    python3 tools/car_placement_check.py                 every map in MapData.Order x SEEDS seeds
    python3 tools/car_placement_check.py --quick         two maps x two seeds (what the plants run on)
    python3 tools/car_placement_check.py --plant         also plants each fault and shows it caught
    python3 tools/car_placement_check.py --show          prints every violation, not just the counts

Every placed car (MapDecor's static ParkedCar, and every drivable VehicleService.Create parked) is
found on the built map with the frame it was put at and the extent of its own parts in that frame,
and is classed by WHERE it ended up, not by which code put it there:

  bay        its centre in one of a town's published parking bays (ParkingBay_<i>)
  kerb       its centre on a town street's asphalt
  driveway   its centre on a driveway slab
  verge      its centre within 22 studs of a country road's centre line, on a straight part of it
  stray      anywhere else: a field, a forest, the river, a square: a violation on its own

and then scored against these rules (one car can break several):

  surface    the footprint (mirrors in, shrunk 0.4 a side) lies wholly on what its class allows: all
             inside its bay; all on one street's asphalt (not up on the kerb or pavement); all on the
             driveway; on the verge, the inner side clear of the carriageway's lane (8.5 out) and the
             outer side on the road's flat corridor (20 out). Never in water. A stray always fails.
  align      square to its bay and nose the bay's way (1.5 degrees); parallel to its street or road
             and facing the traffic flow of the side it's on -- traffic drives on the right
             (MapDecor.Street) -- within 3 degrees; along its driveway within 3 degrees.
  blocking   kerb: not within JUNCTION_CLEAR of a junction box, nor CROSSING_CLEAR of a crossing or
             stop line, along the street; not across a
             driveway's mouth, and at least CLEAR_LANE studs of the street left clear beside it
             (every kerb car overlapping it along the street counted); verge: not within 34 studs
             of a road node (junction, bend, town mouth) nor within 20 of a bridge span.
  spacing    no two cars' footprints overlap; two kerb cars in line keep a 2-stud gap.
  obstacle   nothing solid of the map's own (a wall, a tree, a lamp post, a fence, a bench, a sign)
             inside the footprint between 0.6 above the ground and the car's roof.
  exit       a drivable car can be driven away: out of a bay, 8 studs clear straight back into the
             aisle (or ahead); off the verge, nothing between it and the carriageway and 4 studs clear
             ahead or behind to turn out; anywhere else, 12 studs clear ahead or behind. Clear means no
             obstacle and no other car.
  counts     per town: cars at the kerb take at most a quarter of the town's kerb length; a car park
             is part filled (at least one car, at most 70 percent, at least one bay empty); a town has at least 2 cars
             unless its blurb says "no cars" (and then none at the kerb or on a driveway); the map
             keeps the drivable count MapGenerator asks for (wantedVehicles).

Planted faults, each aimed at an invariant the placement code must hold forever, and each required to
turn the clean quick run (two maps, two seeds) into a failing one in the rule named: see PLANTS at
the bottom (kerb cars facing one way, up the kerb, with no gap, up to the junctions; bay cars off the
middle of the bay; car parks filled to the last bay; driveways without their clearance check; the
old verge yaw wobble; verge vehicles with a post between them and the road; the old ring step-aside).
"""

import math
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car_placement_map as cpm  # noqa: E402

SEEDS = (1, 2, 3)
HALF = 9.0              # RoadNetwork.Width / 2
LANE_EDGE = 8.5         # the verge car's inner side keeps out past here (the edge line is at 8)
CORRIDOR = 20.0         # the road's flat corridor: HALF + SHOULDER + BANK_SETBACK
JUNCTION_CLEAR = 18    # a kerb car's ends from a junction box (the UK's 10 m is about 37 studs; streets are short)
CROSSING_CLEAR = 8     # and from a zebra crossing or a stop line
CLEAR_LANE = 9.0        # street left clear beside kerb cars: one car's lane and a bit
SHRINK = 0.4
BAY_OVERHANG = 0.6      # past a bay's end line (with SHRINK: a stud of the raw footprint), a big car's nose
BAY_SKEW = 2.0          # a car in a stall is square to it within this (MapDecor.ParkBays leaves them 1.4 askew at most)
BAY_SKEW_LOOSE = 3.5    # in a gravel lot, no lines to go by (3)
BAY_SKEW_STRADDLE = 4.0 # the one straddling a line (3)
EXIT_RUN = 12           # clear run ahead or behind for a drivable car; 8 out of a bay (the aisle is 14)
LOT_MOST = 0.7          # no car park more full than this (MapDecor.ParkBays' LOT_FILL_MAX)
RULES = ("surface", "align", "blocking", "spacing", "obstacle", "exit", "counts")

# Flat things that are never obstacles, whatever their height (markings, surfaces, the car park's
# lines, a map's own ground pieces), and chains that are never obstacles (the cars' own pads).
FLAT = {"Asphalt", "JunctionAsphalt", "Crossing", "StopLine", "Dash", "Kerb", "Pavement", "PavementTaper",
        "RoadSurface", "RoadEdge", "RoadCentreLine", "RoadDash", "RoadCurve", "BridgeRoad", "Driveway",
        "DroppedKerb", "Layby", "Hardstanding", "Paving", "Cobbles"}


# ---------------------------------------------------------------------------------------------
# Geometry

def car_frame(car):
    lx, lz = car["lx"], car["lz"]
    n = math.hypot(lx, lz) or 1.0
    lx, lz = lx / n, lz / n
    # Roblox: right = look x up; a local (X, Z) point is pos + right*X + back*Z, back = -look.
    return (car["x"], car["z"]), (lx, lz), (-lz, lx)


def car_corners(car, shrink=0.0, grow=(0.0, 0.0, 0.0, 0.0)):
    """Footprint corners. `grow` = (left, right, front, back) extra studs."""
    (px, pz), (lx, lz), (rx, rz) = car_frame(car)
    x0, x1 = car["x0"] + shrink - grow[0], car["x1"] - shrink + grow[1]
    # Local -Z is the nose.
    zf, zb = car["z0"] + shrink - grow[2], car["z1"] - shrink + grow[3]
    pts = []
    for X, Z in ((x0, zf), (x1, zf), (x1, zb), (x0, zb)):
        pts.append((px + rx * X - lx * Z, pz + rz * X - lz * Z))
    return pts


def samples(car, shrink=SHRINK):
    c = car_corners(car, shrink)
    mids = [((c[i][0] + c[(i + 1) % 4][0]) / 2, (c[i][1] + c[(i + 1) % 4][1]) / 2) for i in range(4)]
    return c + mids + [(car["x"], car["z"])]


def hull(points):
    pts = sorted(set(points))
    if len(pts) <= 2:
        return pts
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def overlap(a, b, margin=0.0):
    """Separating axis test for two convex polygons; `margin` shrinks the overlap needed."""
    for poly in (a, b):
        n = len(poly)
        if n < 2:
            continue
        for i in range(n):
            x1, z1 = poly[i]
            x2, z2 = poly[(i + 1) % n]
            ax, az = z1 - z2, x2 - x1
            m = math.hypot(ax, az)
            if m < 1e-9:
                continue
            ax, az = ax / m, az / m
            pa = [p[0] * ax + p[1] * az for p in a]
            pb = [p[0] * ax + p[1] * az for p in b]
            if max(pa) - margin <= min(pb) or max(pb) - margin <= min(pa):
                return False
    return True


def in_rect(point, s, pad=0.0):
    dx, dz = point[0] - s["x"], point[1] - s["z"]
    u = dx * s["rx"] + dz * s["rz"]
    v = dx * s["lx"] + dz * s["lz"]
    return abs(u) <= s["sx"] / 2 + pad and abs(v) <= s["sz"] / 2 + pad


def rect_poly(s, pad=0.0):
    hx, hz = s["sx"] / 2 + pad, s["sz"] / 2 + pad
    return [(s["x"] + s["rx"] * u + s["lx"] * v, s["z"] + s["rz"] * u + s["lz"] * v)
            for u, v in ((-hx, -hz), (hx, -hz), (hx, hz), (-hx, hz))]


def angle_between(ax, az, bx, bz):
    d = (ax * bx + az * bz) / ((math.hypot(ax, az) * math.hypot(bx, bz)) or 1)
    return math.degrees(math.acos(max(-1.0, min(1.0, d))))


def seg_distance(px, pz, ax, az, bx, bz):
    abx, abz = bx - ax, bz - az
    ll = abx * abx + abz * abz
    t = 0 if ll == 0 else max(0.0, min(1.0, ((px - ax) * abx + (pz - az) * abz) / ll))
    return math.hypot(ax + abx * t - px, az + abz * t - pz)


class Grid:
    def __init__(self, items, key, cell=32):
        self.cell, self.cells = cell, defaultdict(list)
        for item in items:
            xs = [p[0] for p in key(item)]
            zs = [p[1] for p in key(item)]
            if not xs:
                continue
            for cx in range(int(math.floor(min(xs) / cell)), int(math.floor(max(xs) / cell)) + 1):
                for cz in range(int(math.floor(min(zs) / cell)), int(math.floor(max(zs) / cell)) + 1):
                    self.cells[(cx, cz)].append(item)

    def near(self, pts):
        xs = [p[0] for p in pts]
        zs = [p[1] for p in pts]
        seen, out = set(), []
        for cx in range(int(math.floor(min(xs) / self.cell)), int(math.floor(max(xs) / self.cell)) + 1):
            for cz in range(int(math.floor(min(zs) / self.cell)), int(math.floor(max(zs) / self.cell)) + 1):
                for item in self.cells.get((cx, cz), ()):
                    if id(item) not in seen:
                        seen.add(id(item))
                        out.append(item)
        return out


# ---------------------------------------------------------------------------------------------
# Scoring

def score(m):
    """Returns (violations, cars): violations a list of (rule, class, text)."""
    violations = []

    def bad(rule, car, text):
        violations.append((rule, car.get("cls", "map") if car else "map", text))

    for p in m.parts:
        p["hull"] = hull(p["pts"])
    obstacles = [p for p in m.parts if p["name"] not in FLAT and "VehiclePads" not in p["chain"]
                 and not (p["invisible"] and not p["collide"]) and p["hull"]]
    ogrid = Grid(obstacles, lambda p: p["hull"])
    sgrid = Grid(m.surfaces, lambda s: rect_poly(s))
    for s in m.surfaces:
        s["poly"] = rect_poly(s)
    bays = m.bays
    for b in bays:
        n = math.hypot(b["lx"], b["lz"]) or 1
        b["dir"] = (b["lx"] / n, b["lz"] / n)
        # A bay as a rectangle: its width across, its depth along the nose.
        b["rect"] = {"x": b["x"], "z": b["z"], "rx": -b["dir"][1], "rz": b["dir"][0], "lx": b["dir"][0], "lz": b["dir"][1],
                     "sx": b["w"], "sz": b["d"]}
    for e in m.edges:
        dx, dz = e["bx"] - e["ax"], e["bz"] - e["az"]
        e["len"] = math.hypot(dx, dz)
        e["dir"] = (dx / e["len"], dz / e["len"]) if e["len"] else (1, 0)

    def edge_at(x, z):
        best = None
        for e in m.edges:
            dx, dz = x - e["ax"], z - e["az"]
            along = dx * e["dir"][0] + dz * e["dir"][1]
            lateral = -dx * e["dir"][1] + dz * e["dir"][0]  # + on the right of the edge's direction
            if e["from"] - 2 <= along <= e["to"] + 2 and abs(lateral) <= 22:
                if best is None or abs(lateral) < abs(best[2]):
                    best = (e, along, lateral)
        return best

    def in_water(x, z):
        if m.river:
            pts = m.river["pts"]
            for i in range(len(pts) - 1):
                if seg_distance(x, z, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]) < m.river["width"] / 2:
                    return True
        return False

    streets = [s for s in m.surfaces if s["name"] == "Asphalt" and s["chain"].startswith("Town")]

    def street_dir(s):
        # A street's Asphalt is (width, lift, length) along its look.
        return (s["lx"], s["lz"])

    cars = m.cars

    def straddled(car):
        """The two stalls a straddling car stands across, as one rect: its bay and the one beside it."""
        b = car["bay"]
        best = None
        for other in bays:
            if other is b or other["town"] != b["town"] or other["accessible"]:
                continue
            if other["index"] == b.get("next") or b["index"] == other.get("next"):
                if best is None or math.hypot(other["x"] - car["x"], other["z"] - car["z"]) < math.hypot(best["x"] - car["x"], best["z"] - car["z"]):
                    best = other
        if not best:
            return None
        car["pair"] = (b, best)
        return dict(b["rect"], x=(b["x"] + best["x"]) / 2, z=(b["z"] + best["z"]) / 2, sx=b["w"] + math.hypot(b["x"] - best["x"], b["z"] - best["z"]))

    for car in cars:
        car.setdefault("style", "")
        car["drivable"] = car["kind"].startswith("drivable")
        car["poly"] = car_corners(car)
        cx, cz = car["x"], car["z"]
        car["bay"] = next((b for b in bays if in_rect((cx, cz), b["rect"])), None)
        car["street"] = next((s for s in streets if in_rect((cx, cz), s)), None)
        car["driveway"] = next((s for s in m.surfaces if s["name"] == "Driveway" and in_rect((cx, cz), s)), None)
        car["edge"] = edge_at(cx, cz) if not (car["bay"] or car["street"] or car["driveway"]) else None
        car["cls"] = ("bay" if car["bay"] else "kerb" if car["street"] else "driveway" if car["driveway"]
                      else "verge" if car["edge"] else "stray")
    label = lambda car: "%s %s%s at (%.0f, %.0f)" % (car["cls"], car["kind"], (" " + car["model"]) if car["model"] else "",
                                                    car["x"], car["z"])

    for car in cars:
        cls = car["cls"]
        pts = samples(car)
        _, (lx, lz), (rx, rz) = car_frame(car)
        # surface ----------------------------------------------------------------------------
        if cls == "stray":
            bad("surface", car, label(car) + ": not on a street, bay, driveway or road verge")
        elif cls == "bay":
            # Wholly between its bay's side lines; a big car may overhang an end line by BAY_OVERHANG. A car
            # left straddling the line between two stalls (MapDecor.ParkBays' one a map) is held to the two.
            r = car["bay"]["rect"]
            if car["style"] == "straddle":
                pair = straddled(car)
                r = pair or r
            out = [p for p in pts if not in_rect(p, dict(r, sz=r["sz"] + 2 * BAY_OVERHANG))]
            if out:
                bad("surface", car, label(car) + ": %d of %d footprint points outside its bay" % (len(out), len(pts)))
        elif cls == "kerb":
            s = car["street"]
            off = [p for p in pts if not in_rect(p, s)]
            if off:
                bad("surface", car, label(car) + ": %d of %d footprint points off its street's asphalt (up the kerb)"
                    % (len(off), len(pts)))
        elif cls == "driveway":
            off = [p for p in pts if not any(in_rect(p, d) for d in m.surfaces if d["name"] == "Driveway")]
            if off:
                bad("surface", car, label(car) + ": %d footprint points off the driveway" % len(off))
        elif cls == "verge":
            e = car["edge"][0]
            lats = []
            for p in car_corners(car):
                dx, dz = p[0] - e["ax"], p[1] - e["az"]
                lats.append(abs(-dx * e["dir"][1] + dz * e["dir"][0]))
            if min(lats) < LANE_EDGE:
                bad("surface", car, label(car) + ": inner side %.1f off the centre line, in the lane (keep past %.1f)"
                    % (min(lats), LANE_EDGE))
            if max(lats) > CORRIDOR + 0.3:
                bad("surface", car, label(car) + ": outer side %.1f out, past the flat corridor (%.0f)" % (max(lats), CORRIDOR))
        if any(in_water(*p) for p in pts):
            bad("surface", car, label(car) + ": in the river")
        # align ------------------------------------------------------------------------------
        if cls == "bay":
            # Square to its stall, nosed in or (REVERSE) backed in, within BAY_SKEW degrees: more in a gravel
            # lot with no lines to go by, and for the straddler.
            want = car["bay"]["dir"]
            if car["style"] == "reverse":
                want = (-want[0], -want[1])
            a = angle_between(lx, lz, *want)
            limit = BAY_SKEW_LOOSE if car["bay"]["lotKind"] == "gravel" else (BAY_SKEW_STRADDLE if car["style"] == "straddle" else BAY_SKEW)
            if a > limit:
                bad("align", car, label(car) + ": %.1f degrees off its bay's %s direction" % (a, "reverse" if car["style"] == "reverse" else "nose"))
        elif cls in ("kerb", "verge"):
            if cls == "kerb":
                s = car["street"]
                dx, dz = street_dir(s)
                side = (car["x"] - s["x"]) * (-dz) + (car["z"] - s["z"]) * dx
            else:
                e, _, side = car["edge"]
                dx, dz = e["dir"]
            # Right of (dx, dz) is (-dz, dx): a car on that side drives, and so parks, along (dx, dz).
            want = (dx, dz) if side > 0 else (-dx, -dz)
            a = angle_between(lx, lz, *want)
            if a > 3.0:
                why = "facing against the traffic on its side" if a > 90 else "askew"
                bad("align", car, label(car) + ": %.1f degrees off the traffic direction (%s)" % (a, why))
        elif cls == "driveway":
            d = car["driveway"]
            a = angle_between(lx, lz, d["lx"], d["lz"])
            a = min(a, 180 - a)
            if a > 3.0:
                bad("align", car, label(car) + ": %.1f degrees off its driveway" % a)
        # blocking ---------------------------------------------------------------------------
        if cls == "kerb":
            # Along the street (its ends are where it meets a junction, a crossing or the square).
            for name, clear in (("JunctionAsphalt", JUNCTION_CLEAR), ("Crossing", CROSSING_CLEAR), ("StopLine", CROSSING_CLEAR)):
                grown = car_corners(car, 0, (0, 0, clear, clear))
                hit = next((s for s in sgrid.near(grown) if s["name"] == name and overlap(grown, s["poly"])), None)
                if hit:
                    bad("blocking", car, label(car) + ": within %d studs of a %s" % (clear, name))
                    break
            # Across a driveway's mouth: the car reached out over the pavement on its kerb side.
            s = car["street"]
            dx, dz = street_dir(s)
            side = (car["x"] - s["x"]) * (-dz) + (car["z"] - s["z"]) * dx
            reach = car_corners(car, 0, (0, 7, 0, 0) if (rx * -dz + rz * dx) * side > 0 else (7, 0, 0, 0))
            for d in sgrid.near(reach):
                if d["name"] == "Driveway" and overlap(reach, d["poly"], 0.2):
                    bad("blocking", car, label(car) + ": across a driveway's mouth")
                    break
            # Street left clear beside it.
            lo, hi = [], []
            for other in cars:
                if other.get("street") is s and other["cls"] == "kerb":
                    along = [((p[0] - s["x"]) * dx + (p[1] - s["z"]) * dz) for p in other["poly"]]
                    lats = [((p[0] - s["x"]) * (-dz) + (p[1] - s["z"]) * dx) for p in other["poly"]]
                    lo.append((min(along), max(along), min(lats), max(lats)))
            mine = [((p[0] - s["x"]) * dx + (p[1] - s["z"]) * dz) for p in car["poly"]]
            a0, a1 = min(mine), max(mine)
            half = s["sx"] / 2
            left_edge, right_edge = -half, half
            for (b0, b1, l0, l1) in lo:
                if b1 > a0 and b0 < a1:
                    if (l0 + l1) / 2 < 0:
                        left_edge = max(left_edge, l1)
                    else:
                        right_edge = min(right_edge, l0)
            if right_edge - left_edge < CLEAR_LANE:
                bad("blocking", car, label(car) + ": leaves %.1f studs of a %.0f-stud street clear (need %.0f)"
                    % (right_edge - left_edge, s["sx"], CLEAR_LANE))
        elif cls == "verge":
            for n in m.nodes:
                if math.hypot(n["x"] - car["x"], n["z"] - car["z"]) < 34:
                    bad("blocking", car, label(car) + ": %.0f studs from a road %s" % (
                        math.hypot(n["x"] - car["x"], n["z"] - car["z"]), n["kind"]))
                    break
            e, along, _ = car["edge"]
            for s0, s1 in e["bridges"]:
                if s0 - 20 <= along <= s1 + 20:
                    bad("blocking", car, label(car) + ": at a bridge")
        # obstacle ---------------------------------------------------------------------------
        y0, y1 = car["y"] + 0.6, car["y"] + max(car["y1"], 3.0)
        poly = car["poly"]
        for p in ogrid.near(poly):
            if p["y1"] > y0 and p["y0"] < y1 and overlap(poly, p["hull"], 0.05):
                bad("obstacle", car, label(car) + ": into a %s (%s)" % (p["name"], p["chain"] or "map"))
                break
        # exit (drivable only) ---------------------------------------------------------------
        if car["drivable"]:
            clear = False
            run_ = 8 if cls == "bay" else EXIT_RUN
            if cls == "verge":
                # Pulled over beside the road: the way out is sideways into the lane, so nothing may stand
                # between it and the carriageway, and it needs a little room ahead or behind to turn out.
                e, _, side = car["edge"]
                toward = (-e["dir"][1] * (1 if side > 0 else -1), e["dir"][0] * (1 if side > 0 else -1))
                inner = min((((p[0] - e["ax"]) * -e["dir"][1] + (p[1] - e["az"]) * e["dir"][0]) * (1 if side > 0 else -1))
                            for p in car["poly"])
                strip = [(p[0] - toward[0] * (inner - HALF), p[1] - toward[1] * (inner - HALF)) for p in car["poly"]]
                strip = hull(car["poly"] + strip)
                for p in ogrid.near(strip):
                    if p["y1"] > y0 and p["y0"] < y1 and overlap(strip, p["hull"], 0.05):
                        bad("exit", car, label(car) + ": a %s between it and the road" % p["name"])
                        break
                run_ = 4
            for grow in ((0, 0, run_, 0), (0, 0, 0, run_)):
                box = car_corners(car, 0, grow)
                ahead = [q for q in box]
                hit = False
                for p in ogrid.near(ahead):
                    if p["y1"] > y0 and p["y0"] < y1 and overlap(ahead, p["hull"], 0.05):
                        hit = True
                        break
                for other in cars:
                    if other is not car and overlap(ahead, other["poly"], 0.05):
                        hit = True
                        break
                if not hit:
                    clear = True
                    break
            if not clear:
                bad("exit", car, label(car) + ": boxed in, no clear 12 studs ahead or behind")

    # spacing ----------------------------------------------------------------------------------
    for i, a in enumerate(cars):
        for b in cars[i + 1:]:
            if abs(a["x"] - b["x"]) > 30 or abs(a["z"] - b["z"]) > 30:
                continue
            if overlap(a["poly"], b["poly"], 0.05):
                bad("spacing", a, label(a) + ": overlaps " + label(b))
            elif a["cls"] == "kerb" and b["cls"] == "kerb" and a["street"] is b["street"]:
                grown = car_corners(a, 0, (0, 0, 2, 2))
                if overlap(grown, b["poly"], 0.05):
                    bad("spacing", a, label(a) + ": under 2 studs from " + label(b))

    # counts -----------------------------------------------------------------------------------
    per_town = []
    for t in m.towns:
        radius = t["spread"] + 60
        mine = [c for c in cars if math.hypot(c["x"] - t["x"], c["z"] - t["z"]) <= radius and c["cls"] != "verge"]
        kerb = [c for c in mine if c["cls"] == "kerb"]
        tstreets = [s for s in streets if s["chain"].startswith("Town") and math.hypot(s["x"] - t["x"], s["z"] - t["z"]) <= radius]
        kerb_length = sum(2 * s["sz"] for s in tstreets)
        used = sum(c["z1"] - c["z0"] for c in kerb)
        # The accessible stalls aren't counted: they're not for filling. A straddler fills the two it's across.
        tbays = [b for b in bays if b["town"] == t["name"] and not b["accessible"]]
        filled = [b for b in tbays if any(c["bay"] is b or b in c.get("pair", ()) for c in cars)]
        row = {"town": t["name"], "kind": t["kind"], "kerb": len(kerb), "bays": len(tbays), "filled": len(filled),
               "driveway": sum(1 for c in mine if c["cls"] == "driveway"), "total": len(mine),
               "kerbShare": used / kerb_length if kerb_length else 0}
        per_town.append(row)
        nocars = "no cars" in t["blurb"]
        if kerb_length and used / kerb_length > 0.25:
            bad("counts", None, "%s: kerb cars take %.0f%% of its kerb (at most 25%%)" % (t["name"], 100 * used / kerb_length))
        if tbays:
            # Part filled, each to its own fill (Oliver 09-24: "the parking lots don't all need to be
            # full"): at least one car, at most LOT_MOST of the bays, never the last one. How the fills
            # spread across car parks is tools/parking_lot_check.py's (occupancy).
            share = len(filled) / len(tbays)
            if share > LOT_MOST + 1e-9 or len(filled) == len(tbays):
                bad("counts", None, "%s: car park %d of %d full (at most %.0f%%)" % (t["name"], len(filled), len(tbays), 100 * LOT_MOST))
            elif not filled and not nocars:
                bad("counts", None, "%s: car park empty" % t["name"])
        if not nocars and len(mine) < 2:
            bad("counts", None, "%s (%s): only %d cars in town" % (t["name"], t["kind"], len(mine)))
        if nocars and len(mine):
            bad("counts", None, "%s says no cars, has %d (%d at the kerb, %d in its car park, %d on driveways)" % (
                t["name"], len(mine), row["kerb"], len(filled), row["driveway"]))
    # The map keeps the drivable count MapGenerator asks for: parking sensibly must not cost the players
    # their vehicles.
    wanted = max(6, min(16, int(m.attrs["radius"] // 95)))
    drivable = sum(1 for c in cars if c["drivable"])
    if drivable < wanted:
        bad("counts", None, "%d drivable vehicles on the map, %d wanted" % (drivable, wanted))
    return violations, per_town


def run(maps, seeds, faults=None, show=False, quiet=False):
    """Builds every (map, seed) and scores it. Returns ({rule: count}, per-map rows, total cars)."""
    totals = Counter()
    by_map = {}
    cars_seen = 0
    examples = defaultdict(list)
    for map_id in maps:
        for seed in seeds:
            m = cpm.build(map_id, seed, faults)
            violations, towns = score(m)
            cars_seen += len(m.cars)
            classes = Counter(c["cls"] for c in m.cars)
            counts = Counter(v[0] for v in violations)
            totals.update(counts)
            by_map[(map_id, seed)] = (counts, classes, towns, m)
            for v in violations:
                examples[v[0]].append("%s/%d %s" % (map_id, seed, v[2]))
            if not quiet:
                print("  %-14s seed %d  %5.1fs  %3d cars (%s)  %s" % (
                    map_id, seed, m.seconds, len(m.cars),
                    ", ".join("%s %d" % (k, classes[k]) for k in ("kerb", "bay", "driveway", "verge", "stray") if classes[k]),
                    "  ".join("%s %d" % (r, counts[r]) for r in RULES if counts[r]) or "clean"))
                if m.attrs.get("ThemesFailed") or m.attrs.get("WildsFailed"):
                    print("      map attrs:", m.attrs)
    if show and not quiet:
        for rule in RULES:
            for text in examples[rule]:
                print("    [%s] %s" % (rule, text))
    elif not quiet:
        for rule in RULES:
            for text in examples[rule][:3]:
                print("    e.g. [%s] %s" % (rule, text))
    return totals, by_map, cars_seen


def town_table(by_map):
    print("  per town (kerb / bays filled of bays / driveway / total, kerb share):")
    for (map_id, seed), (_, _, towns, _) in sorted(by_map.items()):
        print("    %s/%d: %s" % (map_id, seed, "; ".join(
            "%s [%s] %d / %d of %d / %d / %d, %.0f%%" % (t["town"], t["kind"], t["kerb"], t["filled"], t["bays"], t["driveway"],
                                                       t["total"], 100 * t["kerbShare"]) for t in towns)))


PLANTS = [
    ("align", "kerb cars face one way down the street, whichever kerb",
     {"MapDecor": [("\t\t\t\tlocal facing = direction * lane.side\n", "\t\t\t\tlocal facing = direction\n")]}),
    ("surface", "kerb cars stand a stud further out, up the kerb",
     {"MapDecor": [("local lateral = street.width / 2 + 0.1 - design.halfWidth", "local lateral = street.width / 2 + 1.1 - design.halfWidth")]}),
    ("spacing", "kerb cars in a row keep no gap (KERB_GAP -4)",
     {"MapDecor": [("local KERB_GAP = 2\n", "local KERB_GAP = -4\n")]}),
    ("blocking", "kerb cars park up to the junctions (KERB_END_CLEAR 2)",
     {"MapDecor": [("local KERB_END_CLEAR = 22\n", "local KERB_END_CLEAR = 2\n")]}),
    ("surface", "parked cars stand a stud off the middle of their bay, sideways",
     {"MapDecor": [("\tlocal at = frame * CFrame.new(-centre.X, 0, -centre.Z)\n", "\tlocal at = frame * CFrame.new(-centre.X + 1.2, 0, -centre.Z)\n")]}),
    ("counts", "the car parks are filled to the last bay",
     {"MapDecor": [("\tlocal target = math.clamp(math.floor(count * share + 0.5), 1, math.max(1, math.floor(count * LOT_FILL_MAX)))\n",
                    "\tlocal target = count\n")]}),
    ("obstacle", "driveways skip their clearance check",
     {"MapDecor": [("\t\t\t\tif rectClear(space, slab, halfSlabX, halfSlabZ) then\n", "\t\t\t\tif true then\n")]}),
    ("align", "verge vehicles get the old +/-0.15 yaw wobble",
     {"MapGenerator": [("local yaw = math.atan2(-facing.X, -facing.Z) + (math.random() - 0.5) * 0.03", "local yaw = math.atan2(-facing.X, -facing.Z) + (math.random() - 0.5) * 0.3")]}),
    ("exit", "verge vehicles stand 4 studs further out, right behind one of the road's posts",
     {"MapGenerator": [("\t\t\tif (post.X - at.X) ^ 2 + (post.Z - at.Z) ^ 2 < 12 * 12 then\n\t\t\t\treturn false\n\t\t\tend\n\t\tend\n\t\treturn true\n",
                        "\t\t\tif (post.X - at.X) ^ 2 + (post.Z - at.Z) ^ 2 < 8 * 8 then\n\t\t\t\treturn true\n\t\t\tend\n\t\tend\n\t\treturn false\n"),
                       ("local VERGE = RoadNetwork.Width / 2 + 5.5\n", "local VERGE = RoadNetwork.Width / 2 + 9.5\n"),
                       ("and levelAt(at, along, side) and apart(at)", "and apart(at)")]}),
    ("surface", "a verge vehicle that isn't level steps round a ring, not along its road (the old parkOn)",
     {"VehicleService": [("\t\tif across then\n\t\t\tlocal alongRoad", "\t\tif false then\n\t\t\tlocal alongRoad")],
      "MapGenerator": [("and levelAt(at, along, side) and apart(at)", "and apart(at)")]}),
]


def main(argv):
    quick = "--quick" in argv
    maps = cpm.map_ids()[:2] if quick else cpm.map_ids()
    seeds = SEEDS[:2] if quick else SEEDS
    totals, by_map, cars = run(maps, seeds, show="--show" in argv)
    town_table(by_map)
    examined = len(by_map)
    print("car placement: %d maps built, %d cars examined, violations: %s" % (
        examined, cars, ", ".join("%s %d" % (r, totals[r]) for r in RULES)))
    ok = sum(totals.values()) == 0
    if "--plant" in argv:
        pmaps, pseeds = cpm.map_ids()[:2], SEEDS[:2]
        caught = 0
        for rule, what, faults in PLANTS:
            try:
                pt, _, _ = run(pmaps, pseeds, faults, quiet=True)
                hit = pt[rule] > 0
            except SystemExit as e:
                print("  planted %-44s DID NOT APPLY: %s" % (what, e))
                hit = False
            caught += hit
            print("  planted %-50s -> %s (%s %d)" % (what, "caught" if hit else "MISSED", rule, pt[rule] if hit else 0))
        ok = ok and caught == len(PLANTS)
        print("planted faults: %d of %d caught" % (caught, len(PLANTS)))
    print("car_placement_check:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
