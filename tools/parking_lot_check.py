"""Every town car park where a driver would use it, built like a real one, part full and good to fight in
(Oliver 09-24: "the parking lot locations still are terrible and the parking lots don't all need to be
full", then "way better"), measured on whole maps built by the REAL MapGenerator.Build
(tools/car_placement_map.py).

    python3 tools/parking_lot_check.py               every map in MapData.Order x SEEDS
    python3 tools/parking_lot_check.py --quick       two maps x two seeds (what the plants run on)
    python3 tools/parking_lot_check.py --plant       also plants each fault and shows it caught
    python3 tools/parking_lot_check.py --show        every violation, not just the first few

A car park is found by its surface (LotSurface, whose LookVector points out of it toward its street),
its model's record (kind, layout, aisle, parts: ParkingLots.Build) and everything laid in it, and is
scored on the pieces as built, never on what the code meant:

  WHERE
    front     its front edge lies along the back of a town street's pavement (that street's centre line
              width / 2 + SIDEWALK away, within FRONT_TOL), wholly beside the street's drawn length
    align     square to that street: its axes within ALIGN_DEG of the street's
    beside    a town building within BESIDE studs of it on the same side of the street, or the town
              square's paving: a car park stands in a row of buildings, not out in a field
    entrance  every way in (an apron) is one flush, unbroken surface from the street to the car park:
              along three lines from the street's centre line in (its middle and a stud in from each
              side) every point is on the street's asphalt, a dropped kerb, the apron or the surface,
              all at the street's asphalt top within STEP_TOL, and none on a kerb, pavement or curb left
              standing across it; one way in (double) or two, in and out (angled)
    overlap   nothing but its own pieces inside its footprint: no street, pavement, junction, square,
              road, building, driveway, tree or prop of anyone else's; not within a country road's flat
              corridor (CORRIDOR); not in the river
    level     the ground under the whole footprint dead flat (LEVEL_TOL) at its surface's underside, which
              is its street's: not floating, not sunk
  LOOK
    edge      its surface edged all round (a curb, an island's curb, the walkway, or timber edging in
              gravel), open only at its ways in, each as wide as its apron
    bays      every bay and accessible stall wholly on the surface, at the layout's angle to the street
              (double: along it, 90 degrees to the aisle; angled: 60 degrees) within 1 degree, nosed in
              (pointing away from the aisle); at least MIN_BAYS
    painted   paved: every stall's two side lines painted through their middle (a hairpin), the
              accessible stall blue, its hatched bay, the arrows, the stop bar and the crossing there;
              yard: every stall's side lines; gravel: no paint but tyre tracks
    stops     a wheel stop across every stall near its head end, low and not solid
    fit       every vehicle design fits a bay with FIT_MARGIN a side, as measured on the built cars
    furniture paved: a light pole, the sign, two or more planted islands, the walkway with bollards;
              gravel: its board and fence; yard: floodlight, sign, chain-link fence and barrier
    theme     a paved lot on sand grows palms and cacti, one elsewhere never does
    flush     every piece of paint lies on the surface (or on the paint it belongs to), none floating or
              sunk, and no two in one plane overlap (z-fighting)
    props     everything standing up stands on what's under it (the surface, the walkway, an island's
              soil or the ground: never above it, never more than PROP_SINK into it), and nothing solid
              stands in a stall or the aisle
    budget    the car park's parts within ParkingLots.PartBudget for its kind, and as it counts them
  CARS
    parked    every car in a stall wholly inside it (a straddler: inside the two it's across), square to
              it within PARK_DEG (LOOSE in gravel), nosed or backed in, its middle within PARK_OFF across
              and PARK_ALONG along of the stall's (LOOSE in gravel)
    occupancy per car park: at least one car and one empty bay, never more than FILL_MOST full (the
              accessible stalls apart); across the run: the mean share between MEAN_FILL, at least
              QUIET_SHARE a third full or less, at least one half full or more, the fill dealt within
              ParkingLots' FILL_MIN..FILL_MAX, the parked scenery nearer the way in than the back
              (FRONT_MEAN), at least MODELS designs parked, some backed in (REVERSED), at most one car
              in an accessible stall a map and at most one straddler a map
    towns     a town whose blurb says "no cars" has no car park; every other town has one in at least
              HAVE_SHARE of builds
    variety   across the run: every kind (paved, gravel, yard) and both layouts (double, angled)

Planted faults, each aimed at an invariant the car park code must hold forever and each required to
turn the clean quick run into a failing one in the rule named: see PLANTS at the bottom.
"""

import math
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car_placement_map as cpm  # noqa: E402
from car_placement_check import Grid, angle_between, hull, in_rect, overlap, rect_poly, seg_distance  # noqa: E402

SEEDS = (1, 2, 3, 4)
SIDEWALK = 5.0          # MapGenerator's SIDEWALK: kerb and pavement
FRONT_TOL = 0.3
ALIGN_DEG = 2.0
BESIDE = 14.0
STEP_TOL = 0.02
LEVEL_TOL = 0.05
CORRIDOR = 20.0         # a country road's flat corridor either side of its centre line
MIN_BAYS = 4
FIT_MARGIN = 0.4
PARK_DEG, PARK_DEG_LOOSE, PARK_DEG_STRADDLE = 2.0, 3.5, 4.0
PARK_OFF, PARK_ALONG = 0.4, 0.65
PARK_OFF_LOOSE, PARK_ALONG_LOOSE = 0.6, 1.1
FILL_MOST = 0.7
MEAN_FILL = (0.2, 0.5)
QUIET_SHARE = 0.25
MODELS = 3
FRONT_MEAN = 0.5
REVERSED = 0.05         # at least this share of the parked scenery backed in, across the run
PROP_SINK = 1.0
ZFIGHT = 0.045          # ZFight.Tolerance
RULES = ("front", "align", "beside", "entrance", "overlap", "level", "edge", "bays", "painted", "stops", "fit", "furniture",
         "theme", "flush", "props", "budget", "parked", "occupancy", "towns", "variety")

BUILDINGS = ("Town/house", "Town/tower", "Town/warehouse")
EDGES = {"LotCurb", "IslandCurb", "Walkway", "WalkwayRamp", "TimberEdging"}
GROUND = {"LotSurface", "LotApron", "Walkway", "IslandSoil", "LotCurb", "IslandCurb", "TimberEdging"}
PAINT = {"StallLine", "HatchLine", "AccessibleFill", "AisleArrow", "StopBar", "CrossingStripe", "OilStain", "AsphaltPatch",
         "DrainGrate", "TyreTrack", "ExpansionJoint"}
PAINT_ON_PAINT = {"AccessibleSign"}
STANDING = {"LampPost", "LampPostFoot", "TreeTrunk", "PalmTrunk", "Shrub", "Cactus", "Bollard", "FencePost", "Hedge", "PayMachine", "Bin",
            "BarrierPost", "SignPost", "ParkingSignPost", "CartCorralPost", "Crate", "Cart"}


def source_const(name, pattern, module):
    m = re.search(pattern, cpm.source_of(module))
    if not m:
        raise SystemExit("parking_lot_check: can't find %s in %s; update the pattern" % (name, module))
    return m


FILL_MIN = float(source_const("FILL_MIN", r"local FILL_MIN, FILL_MAX, FILL_SKEW = ([\d.]+)", "ParkingLots").group(1))
FILL_MAX = float(source_const("FILL_MAX", r"local FILL_MIN, FILL_MAX, FILL_SKEW = [\d.]+, ([\d.]+)", "ParkingLots").group(1))
BUDGET = {k: int(v) for k, v in re.findall(r"(\w+) = (\d+)", source_const(
    "PartBudget", r"ParkingLots\.PartBudget = \{([^}]*)\}", "ParkingLots").group(1))}


class Lot:
    """A car park as built: its surface's frame, in which u runs along its right and v toward its street."""

    def __init__(self, s):
        self.s = s
        self.x, self.z = s["x"], s["z"]
        self.r = (s["rx"], s["rz"])
        self.l = (s["lx"], s["lz"])
        self.hx, self.hz = s["sx"] / 2, s["sz"] / 2
        self.top = s["y"] + s["sy"] / 2
        self.bottom = s["y"] - s["sy"] / 2
        self.parts = defaultdict(list)
        self.record = None

    def local(self, p):
        dx, dz = p[0] - self.x, p[1] - self.z
        return dx * self.r[0] + dz * self.r[1], dx * self.l[0] + dz * self.l[1]

    def world(self, u, v):
        return (self.x + self.r[0] * u + self.l[0] * v, self.z + self.r[1] * u + self.l[1] * v)


def top_of(s):
    return s["y"] + s["sy"] / 2


def score(m):
    violations = []

    def bad(rule, text):
        violations.append((rule, text))

    lots = [Lot(s) for s in m.surfaces if s["name"] == "LotSurface"]
    for p in m.parts:
        p["hull"] = hull(p["pts"])
    pgrid = Grid([p for p in m.parts if p["hull"]], lambda p: p["hull"])
    # Each car park's own surface records and parts: those in a ParkingLot model nearest it.
    for s in m.surfaces:
        if "ParkingLot" in s["chain"] and s["name"] != "LotSurface":
            best = min(lots, key=lambda lot: math.hypot(s["x"] - lot.x, s["z"] - lot.z), default=None)
            if best is not None:
                best.parts[s["name"]].append(s)
    own = defaultdict(list)
    for p in m.parts:
        if "ParkingLot" in p["chain"] and p["hull"]:
            cx = sum(q[0] for q in p["hull"]) / len(p["hull"])
            cz = sum(q[1] for q in p["hull"]) / len(p["hull"])
            best = min(lots, key=lambda lot: math.hypot(cx - lot.x, cz - lot.z), default=None)
            if best is not None:
                own[id(best)].append(p)
    for rec in m.lots:
        best = min(lots, key=lambda lot: math.hypot(rec["x"] - lot.x, rec["z"] - lot.z), default=None)
        if best is not None and math.hypot(rec["x"] - best.x, rec["z"] - best.z) < 1:
            best.record = rec
    streets = [s for s in m.surfaces if s["name"] == "Asphalt" and s["chain"] == "Town"]

    rows = []
    for lot in lots:
        town = min(m.towns, key=lambda t: math.hypot(t["x"] - lot.x, t["z"] - lot.z))
        rec = lot.record or {}
        kind, layout = rec.get("kind", "?"), rec.get("layout", "?")
        where = "%s %s %s car park at (%.0f, %.0f)" % (town["name"], kind, layout, lot.x, lot.z)
        mine = own[id(lot)]
        # The whole footprint: every piece of its own but the aprons (which cross the pavement).
        us, vs = [], []
        for p in mine:
            if p["name"] == "LotApron":
                continue
            for q in p["hull"]:
                u, v = lot.local(q)
                us.append(u)
                vs.append(v)
        u0, u1, v0, v1 = min(us), max(us), min(vs), max(vs)
        foot = [lot.world(u0, v0), lot.world(u1, v0), lot.world(u1, v1), lot.world(u0, v1)]
        front = lot.world((u0 + u1) / 2, v1)
        # front / align ---------------------------------------------------------------------------
        street, best = None, None
        for s in streets:
            dx, dz = front[0] - s["x"], front[1] - s["z"]
            along = dx * s["lx"] + dz * s["lz"]
            across = abs(dx * s["rx"] + dz * s["rz"])
            if abs(along) <= s["sz"] / 2 + 1:
                gap = abs(across - (s["sx"] / 2 + SIDEWALK))
                if best is None or gap < best:
                    street, best = s, gap
        if street is None or best > FRONT_TOL:
            bad("front", "%s: its front is %s off the back of any street's pavement" % (where, "%.2f" % best if best is not None else "nowhere near"))
        else:
            ends = [(q[0] - street["x"]) * street["lx"] + (q[1] - street["z"]) * street["lz"] for q in (lot.world(u0, v1), lot.world(u1, v1))]
            if min(ends) < -street["sz"] / 2 - 0.05 or max(ends) > street["sz"] / 2 + 0.05:
                bad("front", "%s: runs past the end of its street" % where)
        if street is not None:
            a = angle_between(lot.r[0], lot.r[1], street["lx"], street["lz"])
            if min(a, 180 - a) > ALIGN_DEG:
                bad("align", "%s: %.1f degrees off its street" % (where, min(a, 180 - a)))
        # beside ---------------------------------------------------------------------------------
        grown = [lot.world(u0 - BESIDE, v0 - BESIDE), lot.world(u1 + BESIDE, v0 - BESIDE), lot.world(u1 + BESIDE, v1),
                 lot.world(u0 - BESIDE, v1)]
        side = (lot.x - street["x"]) * street["rx"] + (lot.z - street["z"]) * street["rz"] if street else None
        near = False
        for p in pgrid.near(grown):
            if p["chain"].startswith(BUILDINGS) and p["collide"] and overlap(grown, p["hull"]):
                cx = sum(q[0] for q in p["hull"]) / len(p["hull"])
                cz = sum(q[1] for q in p["hull"]) / len(p["hull"])
                if side is None or ((cx - street["x"]) * street["rx"] + (cz - street["z"]) * street["rz"]) * side > 0:
                    near = True
                    break
        if not near:
            near = any(p["name"] in ("Paving", "Cobbles") and p["chain"] == "Town" and overlap(grown, p["hull"]) for p in pgrid.near(grown))
        if not near:
            bad("beside", "%s: no building within %.0f studs on its side of its street, and not by the square" % (where, BESIDE))
        # entrance -------------------------------------------------------------------------------
        aprons = lot.parts.get("LotApron", [])
        want = 2 if layout == "angled" else 1
        if len(aprons) != want or street is None:
            bad("entrance", "%s: %d ways in (a %s lot has %d)%s" % (where, len(aprons), layout, want, "" if street else ", no street in front"))
        if street is not None:
            street_top = top_of(street)
            near_ = lambda s: math.hypot(s["x"] - lot.x, s["z"] - lot.z) < max(lot.hx, lot.hz) + 40
            carriers = [street] + [s for s in m.surfaces if s["name"] == "DroppedKerb" and near_(s)] + aprons + [lot.s]
            blockers = [s for s in m.surfaces if (s["name"] in ("Kerb", "Pavement") and s["chain"] == "Town" or s["name"] in EDGES) and near_(s)]
            reach = SIDEWALK + street["sx"] / 2
            for ap in aprons:
                au, av = lot.local((ap["x"], ap["z"]))
                v_in = lot.hz - 0.5 - (lot.hz - av) if False else av - ap["sz"] / 2 - 1.5
                fault = None
                for du in (0.0, -(ap["sx"] / 2 - 1), ap["sx"] / 2 - 1):
                    v = v_in
                    while v <= av + ap["sz"] / 2 + reach and not fault:
                        p = lot.world(au + du, v)
                        under = [s for s in carriers if in_rect(p, s, 0.01)]
                        if not under:
                            fault = "a gap at %.1f in from the street" % (av + ap["sz"] / 2 + reach - v)
                        elif any(abs(top_of(s) - street_top) > STEP_TOL for s in under):
                            fault = "a step of %.2f" % max(abs(top_of(s) - street_top) for s in under)
                        elif any(in_rect(p, s, -0.01) for s in blockers):
                            fault = "a kerb, pavement or curb across it"
                        v += 0.25
                if fault:
                    bad("entrance", "%s: the way in at (%.0f, %.0f) has %s" % (where, ap["x"], ap["z"], fault))
        # overlap --------------------------------------------------------------------------------
        shrunk = [lot.world(u0 + 0.05, v0 + 0.05), lot.world(u1 - 0.05, v0 + 0.05), lot.world(u1 - 0.05, v1 - 0.05), lot.world(u0 + 0.05, v1 - 0.05)]
        for p in pgrid.near(shrunk):
            if "ParkingLot" in p["chain"] or not overlap(shrunk, p["hull"]):
                continue
            if p["invisible"] and not p["collide"]:
                continue
            bad("overlap", "%s: a %s (%s) inside it" % (where, p["name"], p["chain"] or "map"))
            break
        for e in m.edges:
            if any(seg_distance(q[0], q[1], e["ax"], e["az"], e["bx"], e["bz"]) < CORRIDOR for q in foot):
                bad("overlap", "%s: within %.0f of a country road's centre line" % (where, CORRIDOR))
                break
        if m.river:
            rp = m.river["pts"]
            if any(seg_distance(q[0], q[1], rp[i][0], rp[i][1], rp[i + 1][0], rp[i + 1][1]) < m.river["width"] / 2 + 2
                   for q in foot for i in range(len(rp) - 1)):
                bad("overlap", "%s: in the river" % where)
        # level ----------------------------------------------------------------------------------
        g = min(m.lot_ground, key=lambda r: math.hypot(r["x"] - lot.x, r["z"] - lot.z), default=None)
        if g is None or math.hypot(g["x"] - lot.x, g["z"] - lot.z) > 0.5:
            bad("level", "%s: no ground measured under it" % where)
        elif g["high"] - g["low"] > LEVEL_TOL or abs(g["low"] - lot.bottom) > LEVEL_TOL or abs(g["high"] - lot.bottom) > LEVEL_TOL:
            bad("level", "%s: its surface's underside at %.2f over ground at %.2f..%.2f" % (where, lot.bottom, g["low"], g["high"]))
        if street is not None and abs(lot.top - top_of(street)) > STEP_TOL:
            bad("level", "%s: its top %.2f, its street's %.2f" % (where, lot.top, top_of(street)))
        # edge -----------------------------------------------------------------------------------
        edges = [s for name in EDGES for s in lot.parts.get(name, [])]
        missing, opening = 0, 0.0
        step = 0.5
        ring = []
        u = -lot.hx + 0.25
        while u < lot.hx:
            ring.append(((u, lot.hz + 0.35), True))
            ring.append(((u, -lot.hz - 0.35), False))
            u += step
        v = -lot.hz + 0.25
        while v < lot.hz:
            ring.append(((lot.hx + 0.35, v), False))
            ring.append(((-lot.hx - 0.35, v), False))
            v += step
        for (u, v), is_front in ring:
            p = lot.world(u, v)
            if any(in_rect(p, k, 0.02) for k in edges):
                continue
            if is_front and any(in_rect(p, a, 0.02) for a in aprons):
                opening += step
                continue
            missing += 1
        if missing:
            bad("edge", "%s: %d points of its surface's edge with nothing edging them" % (where, missing))
        if aprons and abs(opening - sum(a["sx"] for a in aprons)) > 1.5:
            bad("edge", "%s: its edge opens %.1f for %.1f of way in" % (where, opening, sum(a["sx"] for a in aprons)))
        # bays -----------------------------------------------------------------------------------
        tbays = [b for b in m.bays if b["town"] == town["name"]]
        stalls = []
        for b in tbays:
            n = math.hypot(b["lx"], b["lz"]) or 1
            nose = (b["lx"] / n, b["lz"] / n)
            across = (-nose[1], nose[0])
            b["nose"] = nose
            b["rectl"] = {"x": b["x"], "z": b["z"], "rx": across[0], "rz": across[1], "lx": nose[0], "lz": nose[1], "sx": b["w"], "sz": b["d"]}
            stalls.append(b)
        if sum(1 for b in stalls if not b["accessible"]) < MIN_BAYS:
            bad("bays", "%s: %d bays" % (where, len(stalls)))
        want_angle = 60.0 if layout == "angled" else 0.0
        a0 = (rec.get("ax", 0), rec.get("az", 0))
        a1 = (rec.get("bx", 0), rec.get("bz", 0))
        for b in stalls:
            if not all(in_rect(q, lot.s, 0.05) for q in rect_poly(b["rectl"])):
                bad("bays", "%s: stall %d not wholly on its surface" % (where, b["index"]))
            a = angle_between(b["nose"][0], b["nose"][1], lot.r[0], lot.r[1])
            a = min(a, 180 - a)
            if abs(a - want_angle) > 1.0:
                bad("bays", "%s: stall %d at %.1f degrees to its street (a %s lot's are at %.0f)" % (where, b["index"], a, layout, want_angle))
            # Nosed in: from the aisle's line to the stall's middle is the way its nose points.
            ax, az = a1[0] - a0[0], a1[1] - a0[1]
            ll = ax * ax + az * az
            t = max(0.0, min(1.0, ((b["x"] - a0[0]) * ax + (b["z"] - a0[1]) * az) / ll)) if ll else 0
            ox, oz = b["x"] - (a0[0] + ax * t), b["z"] - (a0[1] + az * t)
            if ox * b["nose"][0] + oz * b["nose"][1] <= 0:
                bad("bays", "%s: stall %d noses toward the aisle, not in" % (where, b["index"]))
        # painted --------------------------------------------------------------------------------
        lines = lot.parts.get("StallLine", [])
        names = Counter(p["name"] for p in mine)
        if kind in ("paved", "yard"):
            unpainted = 0
            for b in stalls:
                ax_, az_ = -b["nose"][1], b["nose"][0]
                for sgn in (-1, 1):
                    for t in (0.35, 0.5, 0.65):
                        along = (t - 0.5) * b["d"]
                        q = (b["x"] + ax_ * sgn * b["w"] / 2 + b["nose"][0] * along, b["z"] + az_ * sgn * b["w"] / 2 + b["nose"][1] * along)
                        if not any(in_rect(q, ln, 0.45) for ln in lines):
                            unpainted += 1
            if unpainted:
                bad("painted", "%s: %d points of its stalls' side lines unpainted" % (where, unpainted))
        if kind == "paved":
            for name, what in (("AccessibleFill", "accessible stall"), ("HatchLine", "hatched bay"), ("AisleArrow", "arrows"),
                               ("StopBar", "stop bar"), ("CrossingStripe", "crossing")):
                if not names[name]:
                    bad("painted", "%s: no %s painted" % (where, what))
        if kind == "gravel":
            if lines:
                bad("painted", "%s: stall lines in a gravel lot" % where)
            if not names["TyreTrack"]:
                bad("painted", "%s: no tyre tracks" % where)
        # stops ----------------------------------------------------------------------------------
        stops = [p for p in mine if p["name"] in ("WheelStop", "TimberWheelStop")]
        for b in stalls:
            head = (b["x"] + b["nose"][0] * (b["d"] / 2 - 1.5), b["z"] + b["nose"][1] * (b["d"] / 2 - 1.5))
            hit = [p for p in stops if math.hypot(sum(q[0] for q in p["hull"]) / len(p["hull"]) - head[0],
                                                   sum(q[1] for q in p["hull"]) / len(p["hull"]) - head[1]) < 1.0]
            if not hit:
                bad("stops", "%s: stall %d has no wheel stop at its head" % (where, b["index"]))
            elif any(p["collide"] or p["y1"] > lot.top + 0.5 for p in hit):
                bad("stops", "%s: stall %d's wheel stop is solid or stands over half a stud" % (where, b["index"]))
        # furniture and theme ----------------------------------------------------------------------
        need = {"paved": ("LampPost", "ParkingSignPost", "Walkway", "Bollard"), "gravel": ("SignPost", "FenceRail"),
                "yard": ("LampPost", "ParkingSignPost", "FenceMesh", "BarrierArm")}.get(kind, ())
        for name in need:
            if not names[name]:
                bad("furniture", "%s: no %s" % (where, name))
        if kind == "paved":
            soils = [p for p in mine if p["name"] == "IslandSoil"]
            planted = 0
            for sp in soils:
                if any(q["name"] in ("TreeTrunk", "PalmTrunk", "Shrub", "Cactus") and overlap(sp["hull"], q["hull"]) for q in mine):
                    planted += 1
            if planted < 2:
                bad("furniture", "%s: %d planted islands" % (where, planted))
            sand = "BombardiroBay" in m.map_id
            palms = names["PalmTrunk"] + names["Cactus"]
            broad = names["TreeCrown"] + names["Shrub"]
            if sand and (not palms or broad):
                bad("theme", "%s: on sand with %d palms or cacti and %d broadleaves or shrubs" % (where, palms, broad))
            if not sand and palms:
                bad("theme", "%s: palms or cacti off the sand" % where)
        # flush ----------------------------------------------------------------------------------
        paint = [p for p in mine if p["name"] in PAINT]
        for p in paint:
            if abs(p["y0"] - lot.top) > 0.01:
                bad("flush", "%s: a %s %s" % (where, p["name"], "floating %.2f" % (p["y0"] - lot.top) if p["y0"] > lot.top else "sunk %.2f" % (lot.top - p["y0"])))
                break
        for i, p in enumerate(paint):
            for q in paint[i + 1:]:
                if abs(p["y1"] - q["y1"]) < ZFIGHT and overlap(p["hull"], q["hull"], 0.02):
                    bad("flush", "%s: a %s and a %s overlap in one plane" % (where, p["name"], q["name"]))
                    break
            else:
                continue
            break
        # props ----------------------------------------------------------------------------------
        ground = [s for name in GROUND for s in lot.parts.get(name, [])] + [lot.s]
        for p in mine:
            if p["name"] not in STANDING:
                continue
            cx = sum(q[0] for q in p["hull"]) / len(p["hull"])
            cz = sum(q[1] for q in p["hull"]) / len(p["hull"])
            under = [top_of(s) for s in ground if in_rect((cx, cz), s, 0.05)]
            # Or another standing thing it's stacked on (a crate on a crate).
            under += [q["y1"] for q in mine if q is not p and q["name"] in STANDING and q["y1"] <= p["y0"] + 0.5
                      and overlap(q["hull"], [(cx - 0.1, cz - 0.1), (cx + 0.1, cz - 0.1), (cx + 0.1, cz + 0.1), (cx - 0.1, cz + 0.1)])]
            support = max(under) if under else 0.0
            if p["y0"] > support + 0.02 and p["name"] not in ("Shrub", "Cart"):
                bad("props", "%s: a %s floats %.2f over what's under it" % (where, p["name"], p["y0"] - support))
            elif p["y0"] < support - PROP_SINK:
                bad("props", "%s: a %s sunk %.2f" % (where, p["name"], support - p["y0"]))
            if p["collide"] and p["name"] not in ("Crate", "CartCorralPost", "Cart"):
                for b in stalls:
                    if overlap(rect_poly(dict(b["rectl"], sx=b["w"] - 0.4, sz=b["d"] - 0.4)), p["hull"]):
                        bad("props", "%s: a %s stands in stall %d" % (where, p["name"], b["index"]))
                        break
                if rec:
                    # In the aisle: beside its line (not past either end of it) within its half-width.
                    w = rec["aisle"] / 2 - 0.3
                    ax_, az_ = a1[0] - a0[0], a1[1] - a0[1]
                    ll = ax_ * ax_ + az_ * az_ or 1
                    for q in p["hull"]:
                        t = ((q[0] - a0[0]) * ax_ + (q[1] - a0[1]) * az_) / ll
                        lateral = abs((q[0] - a0[0]) * az_ - (q[1] - a0[1]) * ax_) / math.sqrt(ll)
                        if 0 < t < 1 and lateral < w:
                            bad("props", "%s: a %s stands in the aisle" % (where, p["name"]))
                            break
        # budget ---------------------------------------------------------------------------------
        if rec:
            limit = BUDGET.get(kind)
            if limit is None or rec["parts"] > limit:
                bad("budget", "%s: %d parts (budget %s)" % (where, rec["parts"], limit))
            if rec["partsAttr"] != rec["parts"]:
                bad("budget", "%s: counts %d parts, has %d" % (where, rec["partsAttr"], rec["parts"]))
        else:
            bad("budget", "%s: no record of its model" % where)
        rows.append({"lot": lot, "town": town, "stalls": stalls, "where": where, "kind": kind, "layout": layout,
                     "parts": rec.get("parts", 0)})

    # cars ---------------------------------------------------------------------------------------------
    stats = {"fills": [], "fronts": [], "models": Counter(), "styles": Counter(), "accessible": 0, "straddlers": 0}
    for row in rows:
        stalls, where, kind = row["stalls"], row["where"], row["kind"]
        bays = [b for b in stalls if not b["accessible"]]
        loose = kind == "gravel"
        filled = set()
        for c in m.cars:
            n = math.hypot(c["lx"], c["lz"]) or 1
            look = (c["lx"] / n, c["lz"] / n)
            right = (-look[1], look[0])
            mx, mz = (c["x0"] + c["x1"]) / 2, (c["z0"] + c["z1"]) / 2
            cx, cz = c["x"] + right[0] * mx - look[0] * mz, c["z"] + right[1] * mx - look[1] * mz
            b = next((b for b in stalls if in_rect((cx, cz), b["rectl"], 0.3)), None)
            if not b:
                continue
            style = c.get("style", "")
            stats["styles"][style or c["kind"]] += 1
            stats["models"][c["model"] or c["kind"]] += 1
            label = "%s %s%s in stall %d" % (where, c["kind"], (" " + c["model"]) if c["model"] else "", b["index"])
            area = b["rectl"]
            if b["accessible"]:
                stats["accessible"] += 1
            if style == "straddle":
                stats["straddlers"] += 1
                other = next((o for o in bays if o is not b and (o["index"] == b.get("next") or b["index"] == o.get("next"))
                              and math.hypot(o["x"] - cx, o["z"] - cz) < b["w"] * 1.1), None)
                if other is None:
                    bad("parked", "%s: straddles nothing" % label)
                    continue
                filled.update((b["index"], other["index"]))
                area = dict(b["rectl"], x=(b["x"] + other["x"]) / 2, z=(b["z"] + other["z"]) / 2, sx=2 * b["w"])
            elif not b["accessible"]:
                filled.add(b["index"])
            want = b["nose"] if style != "reverse" else (-b["nose"][0], -b["nose"][1])
            a = angle_between(look[0], look[1], want[0], want[1])
            limit = PARK_DEG_LOOSE if loose else (PARK_DEG_STRADDLE if style == "straddle" else PARK_DEG)
            if a > limit:
                bad("parked", "%s: %.1f degrees off its stall%s" % (label, a, " (nosed out)" if a > 90 else ""))
            if style != "straddle":
                du, dv = cx - b["x"], cz - b["z"]
                off_across = abs(du * -b["nose"][1] + dv * b["nose"][0])
                off_along = abs(du * b["nose"][0] + dv * b["nose"][1])
                if off_across > (PARK_OFF_LOOSE if loose else PARK_OFF) or off_along > (PARK_ALONG_LOOSE if loose else PARK_ALONG):
                    bad("parked", "%s: %.2f across and %.2f along off its stall's middle" % (label, off_across, off_along))
            hw, hl = (c["x1"] - c["x0"]) / 2, (c["z1"] - c["z0"]) / 2
            for su, sv in ((-1, -1), (-1, 1), (1, -1), (1, 1)):
                q = (cx + right[0] * su * hw + look[0] * sv * hl, cz + right[1] * su * hw + look[1] * sv * hl)
                if not in_rect(q, area, 0.3 if loose else 0.05):
                    bad("parked", "%s: reaches out of its stall" % label)
                    break
            if c["kind"] == "static" and b["index"] > 0 and bays:
                stats["fronts"].append((b["index"] - 0.5) / len(bays))
        if bays:
            share = len(filled) / len(bays)
            stats["fills"].append(share)
            if not filled:
                bad("occupancy", "%s: empty" % where)
            if share > FILL_MOST + 1e-9 or len(filled) == len(bays):
                bad("occupancy", "%s: %d of %d bays full (at most %.0f%%, never every one)" % (where, len(filled), len(bays), 100 * FILL_MOST))
        fill = row["town"].get("fill")
        if fill is None or not (FILL_MIN - 1e-6 <= fill <= FILL_MAX + 1e-6):
            bad("occupancy", "%s: dealt a fill of %s (%.2f..%.2f)" % (where, fill, FILL_MIN, FILL_MAX))
    if stats["accessible"] > 1:
        bad("occupancy", "%d cars in accessible stalls on one map (at most one)" % stats["accessible"])
    if stats["straddlers"] > 1:
        bad("occupancy", "%d straddlers on one map (at most one)" % stats["straddlers"])
    # towns ------------------------------------------------------------------------------------------
    have = {}
    for t in m.towns:
        lotted = any(row["town"] is t for row in rows)
        if "no cars" in t["blurb"]:
            if lotted:
                bad("towns", "%s says no cars but has a car park" % t["name"])
        else:
            have[t["name"]] = lotted
    stats.update({"have": have, "lots": len(rows), "bays": sum(len(r["stalls"]) for r in rows),
                  "kinds": Counter((r["kind"], r["layout"]) for r in rows), "parts": [(r["kind"], r["parts"]) for r in rows]})
    return violations, stats


def fit(sizes, bay):
    out = []
    for model, (length, width) in sorted(sizes.items()):
        if bay[0] - width < 2 * FIT_MARGIN or bay[1] - length < 2 * FIT_MARGIN:
            out.append(("fit", "%s is %.2f long x %.2f wide: a %.1f x %.1f bay leaves %.2f a side across, %.2f an end" % (
                model, length, width, bay[1], bay[0], (bay[0] - width) / 2, (bay[1] - length) / 2)))
    return out


def build_one(job):
    """One map built and scored, in a worker process: what the run adds up."""
    map_id, seed, faults = job
    m = cpm.build(map_id, seed, faults)
    violations, stats = score(m)
    sizes = {}
    for c in m.cars:
        key = c["model"] or c["kind"]
        length, width = c["z1"] - c["z0"], c["x1"] - c["x0"]
        old = sizes.get(key, (0.0, 0.0))
        sizes[key] = (max(old[0], length), max(old[1], width))
    bay = (m.bays[0]["w"], m.bays[0]["d"]) if m.bays else None
    return map_id, seed, m.seconds, violations, stats, sizes, bay


def plant_one(job):
    try:
        return build_one(job)
    except SystemExit as e:
        return str(e)


def pool_map(fn, jobs):
    """In parallel, one process per job up to the CPU count (a build is 5 to 15 s of pure Lua);
    PARKING_SERIAL=1 runs them in this process."""
    if len(jobs) == 1 or os.environ.get("PARKING_SERIAL"):
        return [fn(j) for j in jobs]
    import multiprocessing
    with multiprocessing.Pool(min(len(jobs), max(1, (os.cpu_count() or 2) - 1))) as pool:
        return pool.map(fn, jobs)


def run(maps, seeds, faults=None, show=False, quiet=False, results=None):
    totals = Counter()
    examples = defaultdict(list)
    fills, fronts, models, styles, kinds = [], [], Counter(), Counter(), Counter()
    parts = defaultdict(list)
    have = defaultdict(list)
    sizes = {}
    bay = None
    lots = bays = 0
    if results is None:
        results = pool_map(build_one, [(map_id, seed, faults) for map_id in maps for seed in seeds])
    for map_id, seed, seconds, violations, stats, built_sizes, built_bay in results:
        for key, (length, width) in built_sizes.items():
            old = sizes.get(key, (0.0, 0.0))
            sizes[key] = (max(old[0], length), max(old[1], width))
        bay = built_bay or bay
        fills += stats["fills"]
        fronts += stats["fronts"]
        models.update(stats["models"])
        styles.update(stats["styles"])
        kinds.update(stats["kinds"])
        for kind, n in stats["parts"]:
            parts[kind].append(n)
        for name, lotted in stats["have"].items():
            have[name].append(lotted)
        lots += stats["lots"]
        bays += stats["bays"]
        counts = Counter(v[0] for v in violations)
        totals.update(counts)
        for v in violations:
            examples[v[0]].append("%s/%d %s" % (map_id, seed, v[1]))
        if not quiet:
            print("  %-14s seed %d  %5.1fs  %d car parks (%s), fill %s  %s" % (
                map_id, seed, seconds, stats["lots"], " ".join("%s-%s" % k for k in sorted(stats["kinds"].elements())),
                " ".join("%.2f" % f for f in stats["fills"]) or "-",
                "  ".join("%s %d" % (r, counts[r]) for r in RULES if counts[r]) or "clean"))
    extra = []
    if bay:
        extra += fit(sizes, bay)
    if fills:
        mean = sum(fills) / len(fills)
        quiet_share = sum(1 for f in fills if f <= 1 / 3 + 1e-9) / len(fills)
        if not (MEAN_FILL[0] <= mean <= MEAN_FILL[1]):
            extra.append(("occupancy", "car parks %.0f%% full on average (%.0f..%.0f%%)" % (100 * mean, 100 * MEAN_FILL[0], 100 * MEAN_FILL[1])))
        if quiet_share < QUIET_SHARE:
            extra.append(("occupancy", "only %.0f%% of car parks a third full or less (at least %.0f%%)" % (100 * quiet_share, 100 * QUIET_SHARE)))
        if len(fills) >= 8 and max(fills) < 0.5:
            extra.append(("occupancy", "no car park half full or more in %d" % len(fills)))
        if len(fronts) >= 8 and sum(fronts) / len(fronts) > FRONT_MEAN:
            extra.append(("occupancy", "parked cars sit %.2f of the way back from the way in on average (at most %.2f)"
                          % (sum(fronts) / len(fronts), FRONT_MEAN)))
        if len(fills) >= 8 and len(models) < MODELS:
            extra.append(("occupancy", "only %d designs parked in %d car parks" % (len(models), len(fills))))
        parked = sum(n for k, n in styles.items() if k in ("offset", "reverse", "straddle", "accessible"))
        if parked >= 10 and styles["reverse"] / parked < REVERSED:
            extra.append(("occupancy", "%d of %d parked cars backed in (at least %.0f%%)" % (styles["reverse"], parked, 100 * REVERSED)))
    for name, seen in sorted(have.items()):
        if len(seen) >= 3 and sum(seen) / len(seen) < 0.6:
            extra.append(("towns", "%s has a car park in %d of %d builds" % (name, sum(seen), len(seen))))
    if lots >= 12:
        for kind in ("paved", "gravel", "yard"):
            if not any(k[0] == kind for k in kinds):
                extra.append(("variety", "no %s car park in %d" % (kind, lots)))
        for layout in ("double", "angled"):
            if not any(k[1] == layout for k in kinds):
                extra.append(("variety", "no %s layout in %d" % (layout, lots)))
    for rule, text in extra:
        totals[rule] += 1
        examples[rule].append("run: " + text)
    if not quiet:
        for rule in RULES:
            for text in examples[rule][: (1000 if show else 3)]:
                print("    [%s] %s" % (rule, text))
        if fills:
            hist = Counter(min(6, int(f * 10)) for f in fills)
            print("  %d car parks, %d stalls: %s; share full: mean %.2f, min %.2f, max %.2f; by tenths %s; parked scenery %.2f of the way back"
                  % (lots, bays, ", ".join("%s %s %d" % (k[0], k[1], n) for k, n in sorted(kinds.items())), sum(fills) / len(fills), min(fills),
                     max(fills), " ".join("%d0%%:%d" % (k, hist[k]) for k in sorted(hist)), sum(fronts) / max(1, len(fronts))))
            print("  parked: %s; styles: %s" % (", ".join("%s %d" % kv for kv in models.most_common()),
                                                 ", ".join("%s %d" % kv for kv in styles.most_common())))
        print("  parts a car park (budget %s): %s" % (", ".join("%s %d" % kv for kv in sorted(BUDGET.items())),
                                                     ", ".join("%s %d..%d" % (k, min(v), max(v)) for k, v in sorted(parts.items()))))
        print("  vehicle footprints (length x width, mirrors in) against a %s bay: %s" % (
            "%.1f x %.1f" % (bay[1], bay[0]) if bay else "?", ", ".join("%s %.2f x %.2f" % (k, v[0], v[1]) for k, v in sorted(sizes.items()))))
    return totals


# (rule, what, { module: [(old, new), ...] }): each must turn the clean quick run into a failing one in
# `rule`. Aimed at what a car park must be forever, not at bugs that happened to be there.
PL = "ParkingLots"
PLANTS = [
    ("align", "car parks turned 5 degrees off their street",
     {PL: [("\tlocal yaw = math.atan2(out.X, out.Z)\n", "\tlocal yaw = math.atan2(out.X, out.Z) + math.rad(5)\n")]}),
    ("front", "car parks set 3 studs back from the pavement",
     {PL: [("out * (street.width / 2 + sidewalk + shape.depth / 2)", "out * (street.width / 2 + sidewalk + 3 + shape.depth / 2)")]}),
    ("beside", "car parks at the far end of their street, past the town (the old spot)",
     {PL: [("\tlocal start = type(frontage.built) == \"number\" and frontage.built + CLAIM_MARGIN + 0.5 or frontage.cursor\n",
            "\tlocal start = street.length - shape.width - 5\n")]}),
    ("entrance", "the pavement left standing across the way in",
     {PL: [("\tMapDecor.CutPavement(town, mouth.Position", "\t(function() end)(town, mouth.Position")]}),
    ("entrance", "no apron across the pavement",
     {PL: [("box(lot, \"LotApron\", ", "box(lot, \"LotApronNot\", ")]}),
    ("level", "car parks laid half a stud above their street",
     {PL: [("model = model, base = plan.frame,", "model = model, base = plan.frame + Vector3.new(0, 0.5, 0),")]}),
    ("overlap", "the plot's free-space check skipped",
     {PL: [("\t\tif ctx.rectFree(ctx.space, frame.X, frame.Z, yaw, halfX, halfZ, street.entry) then\n", "\t\tif true then\n")]}),
    ("edge", "no curb across the back",
     {PL: [("\ttable.insert(g.curbs, { b0, b1, zb, zb + CURB })\n", "")]}),
    ("painted", "every other stall line left unpainted",
     {PL: [("\t\t\t\tsideLine(lot, px, pz, s.nx, s.nz, BAY.length, style)\n",
            "\t\t\t\tif k % 2 == 0 then sideLine(lot, px, pz, s.nx, s.nz, BAY.length, style) end\n")]}),
    ("bays", "stalls nosing toward the aisle (nose out)",
     {PL: [("x = x, z = zs + (index - 0.5) * BAY.width, nx = nx, nz = 0,", "x = x, z = zs + (index - 0.5) * BAY.width, nx = -nx, nz = 0,")]}),
    ("stops", "no wheel stops",
     {PL: [("wheelStop(lot, slot, 1.5)", "local _ = slot")]}),
    ("fit", "bays sized as before, 8.9 x 16.6, off the Ranger's chassis",
     {"TownKinds": [("TownKinds.Bay = { width = 10.2, length = 18.6 }", "TownKinds.Bay = { width = 8.9, length = 16.6 }")]}),
    ("furniture", "no lights on the islands",
     {PL: [("lightPole(lot, x, cz, SOIL_TOP, { r.aisleX, cz - 7 })", "local _ = x")]}),
    ("theme", "palms on every map",
     {PL: [("\tif lot.terrain == Enum.Material.Sand then\n\t\tlocal trunk", "\tif true then\n\t\tlocal trunk")]}),
    ("flush", "paint half a tenth off the surface",
     {PL: [("return strip(lot, name, ax, az, bx, bz, width, LIFT, LIFT + MARK,", "return strip(lot, name, ax, az, bx, bz, width, LIFT + 0.05, LIFT + 0.05 + MARK,")]}),
    ("flush", "hairpin lines run into their cap (two pieces of paint in one plane)",
     {PL: [("sx - nx * (length / 2 - w / 2) + ox, sz - nz * (length / 2 - w / 2) + oz", "sx - nx * (length / 2) + ox, sz - nz * (length / 2) + oz")]}),
    ("props", "bollards in the stalls",
     {PL: [("table.insert(g.bollards, { X(WALK - 0.6), z })", "table.insert(g.bollards, { X(WALK + 3), z })")]}),
    ("budget", "a hundred parts more a car park",
     {PL: [("\tlocal g = shape.layout == \"angled\" and angledLayout(shape, bs, o) or doubleLayout(shape, bs, o)\n",
            "\tlocal g = shape.layout == \"angled\" and angledLayout(shape, bs, o) or doubleLayout(shape, bs, o)\n"
            "\tfor _ = 1, 100 do box(lot, \"Clutter\", 0, 0.2, 0, 0.2, 0, 0.2, WHITE) end\n")]}),
    ("parked", "parked cars a stud off the middle of their stall",
     {"MapDecor": [("\tlocal at = frame * CFrame.new(-centre.X, 0, -centre.Z)\n", "\tlocal at = frame * CFrame.new(-centre.X + 1.2, 0, -centre.Z)\n")]}),
    ("occupancy", "every car park filled as full as it may be",
     {"MapDecor": [("\tlocal share = fill or tonumber(town:GetAttribute(\"ParkingFill\")) or LOT_FILL_DEFAULT\n", "\tlocal share = 0.95\n")]}),
    ("occupancy", "every car park dealt the same fill",
     {PL: [("town:SetAttribute(\"ParkingFill\", FILL_MIN + (FILL_MAX - FILL_MIN) * u ^ FILL_SKEW)", "town:SetAttribute(\"ParkingFill\", 0.45)")]}),
    ("occupancy", "car parks filled from the back",
     {"MapDecor": [("math.floor(#free * math.random() ^ FRONT_LEAN) + 1", "#free - math.floor(#free * math.random() ^ FRONT_LEAN)")]}),
    ("occupancy", "a straddler and a car in the accessible stall in every car park",
     {"MapGenerator": [("{ straddle = town == straddler, accessible = town == blueBadge })", "{ straddle = true, accessible = true })")]}),
    ("occupancy", "no car ever backed in",
     {"MapDecor": [("local REVERSE_SHARE = 0.2\n", "local REVERSE_SHARE = 0\n")]}),
    ("towns", "a town with no cars still gets a car park",
     {"MapGenerator": [("\tlocal lotTried = noCars\n", "\tlocal lotTried = false\n")]}),
    ("variety", "every car park paved",
     {PL: [("function ParkingLots.KindFor(profile, terrainMaterial)\n", "function ParkingLots.KindFor(profile, terrainMaterial)\n\tdo return \"paved\" end\n")]}),
]


def main(argv):
    quick = "--quick" in argv
    maps = cpm.map_ids()[:2] if quick else cpm.map_ids()
    seeds = SEEDS[:2] if quick else SEEDS
    totals = run(maps, seeds, show="--show" in argv)
    print("parking lots: %d maps built, violations: %s" % (len(maps) * len(seeds), ", ".join("%s %d" % (r, totals[r]) for r in RULES)))
    ok = sum(totals.values()) == 0
    if "--plant" in argv:
        pmaps, pseeds = cpm.map_ids()[:2], SEEDS[:2]
        caught = 0
        jobs = [(map_id, seed, faults) for _, _, faults in PLANTS for map_id in pmaps for seed in pseeds]
        results = pool_map(plant_one, jobs)
        per = len(pmaps) * len(pseeds)
        for index, (rule, what, faults) in enumerate(PLANTS):
            mine = results[index * per:(index + 1) * per]
            missing = [r for r in mine if isinstance(r, str)]
            if missing:
                print("  planted %-64s DID NOT APPLY: %s" % (what, missing[0]))
                hit, pt = False, Counter()
            else:
                pt = run(pmaps, pseeds, faults, quiet=True, results=mine)
                hit = pt[rule] > 0
            caught += hit
            print("  planted %-64s -> %s (%s %d)" % (what, "caught" if hit else "MISSED", rule, pt[rule]))
        ok = ok and caught == len(PLANTS)
        print("planted faults: %d of %d caught" % (caught, len(PLANTS)))
    print("parking_lot_check:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
