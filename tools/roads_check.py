"""Every road on every map flush and connected (Oliver 09-24: "looks over every road and touches it up and
makes sure all roads are flush and connected"), measured on whole maps built by the REAL
MapGenerator.Build (tools/roads_map.py, on tools/car_placement_map.py's world).

    python3 tools/roads_check.py                  every map in MapData.Order x SEEDS
    python3 tools/roads_check.py --quick          two maps x one seed
    python3 tools/roads_check.py --plant          the planted faults, each required to fail its rule
    python3 tools/roads_check.py --show           every violation located, not just the counts
    python3 tools/roads_check.py --map RotRidge --seed 2

What is measured, on the pieces as built (their CFrames and sizes), never on what the code meant:

  FLUSH (the surface)
    Every road and street is walked along lines a few studs apart across its carriageway: each country
    road from node to node (into the town street 3 studs at a mouth, 1 stud round onto a curve), each
    curve round its arc, each town street and junction box end to end and 1 stud past each end. Along
    each line the exact stretch every surface piece covers is worked out (line against the piece's top
    face), so:
      gap      a stretch no surface covers, longer than 0.01 (a seam you could see)
      step     at every place one piece ends and another begins, the heights of their tops there:
               more than 0.02 apart is a step or a lip
      overlap  two pieces covering the same stretch for more than 0.05: same top height is two faces
               in one plane (z-fighting); different is one surface stacked over another
      end      where a street's or road's surface stops with nothing beyond: CAPPED when a kerb closes
               it off (a street past its last building), RAW otherwise (a fault)
    ground (the harness's ground: MapTerrain's own shaped relief, the pads and the river channel), at
    every stud of every line, exactly and as 4-stud voxels drawn between their centres:
      poke     terrain within 0.05 of the road's top, or above it
      float    the underside of a piece above the ground by more than 0.02 at the carriageway's edge (a
               slab edge standing in the air)
      pad      a pad's flat (FlattenPad writes its margin and 8 studs past it, whatever stands there;
               the harness's ground only models the margin) under a town street at any height but
               the street's own ground
      shoulder ground beside a country road (out to the corridor's flat, 20 studs) off the road's ground
               by more than 0.05
    markings: every line, dash, stop line, crossing stripe's underside against the surface under its
    middle and corners: off by more than 0.01 either way is floating or buried; a corner over no surface
    is an overhang; two markings overlapping in one plane z-fight. The road edge lines are walked along
    their own paths round every curve and along every road: a break longer than 0.15 is a gap in a
    line that should run unbroken.
    kerbs and pavements: every piece's top over the ground under it, which should be one height for
    kerbs and one for pavements everywhere.

  CONNECTED
    graph      the network's own nodes and edges: how many separate pieces the towns fall into
               (want 1), and nodes of kind "end" (a road stopping in open ground)
    surface    every drivable surface rastered on a 1-stud grid (grown 0.3 so a hairline doesn't cut
               it) and joined where neighbours' tops are within 0.3: how many separate pieces of
               road there are (want 1), and whether every town square is on the main one
    arms       every road's slab run starting exactly at its junction box, curve tangent or town
               street end (gap or overshoot, more than 0.01)
    bridges    every point of every road over the river's channel on a bridge deck; both ends of each
               bridge on land
    access     each car park and driveway with a dropped kerb at the edge of a street in front of it,
               and nothing solid standing on the way between them
    width      country road slabs and junction boxes one width; each road meets its town street at
               the street's width

  TOUCH-UPS
    kinks      the sharpest change of direction between two pieces anywhere but a junction: along a
               road (grade, degrees), round a curve (per piece), where a straight meets a curve
    in road    anything standing in a carriageway between 0.15 and 4.5 above it (a lamp, a sign, a
               post), parked and drivable cars excepted (their own check is car_placement_check)

Planted faults (--plant) are each aimed at an invariant the builders must hold forever; see PLANTS.
"""

import math
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roads_map  # noqa: E402
from roads_geom import Piece, corners, hull, overlap_area, ccw, clip, area  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEEDS = (1, 2, 3)


def _const(pattern, name, text):
    m = re.search(pattern, text)
    if not m:
        raise SystemExit("roads_check: can't find %s in the source; update the pattern" % name)
    return float(m.group(1))


_RN = roads_map.cpm.source_of("RoadNetwork")
_MD = roads_map.cpm.source_of("MapDecor")
HALF = _const(r"RoadNetwork\.Width = ([\d.]+)", "RoadNetwork.Width", _RN) / 2
SHOULDER = _const(r"\nlocal SHOULDER = ([\d.]+)", "SHOULDER", _RN)
BANK_SETBACK = _const(r"\nlocal BANK_SETBACK = ([\d.]+)", "BANK_SETBACK", _RN)
LIFT = _const(r"MapDecor\.RoadLift = ([\d.]+)", "MapDecor.RoadLift", _MD)
EDGE_INSET = _const(r"MapDecor\.EdgeLineInset = ([\d.]+)", "MapDecor.EdgeLineInset", _MD)

# What things are, by part name.
DRIVE = {"RoadSurface", "BridgeRoad", "RoadCurve", "JunctionAsphalt", "Asphalt"}
# The roundabouts' carriageway (MapDecor.Roundabout): a surface, walked and joined like the rest, but not
# a carriageway for "in road" -- its island, splitters and signs stand on it by design, and
# tools/roundabout_check.py measures what stands in its lanes.
RING = {"RingAsphalt"}
SURFACE = DRIVE | {"Paving"} | RING
CARRIAGEWAY = DRIVE
MARKS = {"RoadEdge", "RoadDash", "RoadCentreLine", "StopLine", "Dash", "Crossing"}
KERBS = {"Kerb", "Pavement", "PavementTaper", "DroppedKerb"}
ROAD_OWN = SURFACE | MARKS | KERBS | {"Cobbles", "BridgeDeck", "Driveway"}

TOL_STEP = 0.02
TOL_GAP = 0.01
TOL_OVERLAP = 0.05
TOL_MARK = 0.01


def lanes(width):
    h = width / 2 - 0.1
    return [-h, -width / 4, 0.0, width / 4, h]


ROAD_LANES = [-(HALF - 0.1), -6.0, -3.0, 0.0, 3.0, 6.0, HALF - 0.1]


class Index:
    def __init__(self, cell=16.0):
        self.cell = cell
        self.cells = defaultdict(list)

    def add(self, item, bbox):
        c = self.cell
        for i in range(math.floor(bbox[0] / c), math.floor(bbox[1] / c) + 1):
            for j in range(math.floor(bbox[2] / c), math.floor(bbox[3] / c) + 1):
                self.cells[(i, j)].append(item)

    def query(self, bbox):
        c = self.cell
        seen, out = set(), []
        for i in range(math.floor(bbox[0] / c), math.floor(bbox[1] / c) + 1):
            for j in range(math.floor(bbox[2] / c), math.floor(bbox[3] / c) + 1):
                for item in self.cells.get((i, j), ()):
                    if id(item) not in seen:
                        seen.add(id(item))
                        out.append(item)
        return out

    def at(self, x, z):
        return self.cells.get((math.floor(x / self.cell), math.floor(z / self.cell)), ())


def segment_clip(piece, x0, z0, x1, z1):
    """The part of the segment (x0,z0)->(x1,z1) over the piece's top face, as (t0, t1) in [0, 1], or None."""
    poly = ccw(piece.polygon())
    t0, t1 = 0.0, 1.0
    dx, dz = x1 - x0, z1 - z0
    for i in range(len(poly)):
        ax, az = poly[i]
        bx, bz = poly[(i + 1) % len(poly)]
        # Inside is the left of a->b.
        ex, ez = bx - ax, bz - az
        num = ex * (z0 - az) - ez * (x0 - ax)
        den = ex * dz - ez * dx
        if abs(den) < 1e-12:
            if num < 0:
                return None
            continue
        t = -num / den
        if den > 0:
            t0 = max(t0, t)
        else:
            t1 = min(t1, t)
        if t0 > t1:
            return None
    return (t0, t1)


class Line:
    """A path across the road (a polyline in XZ), measured by distance along it."""

    def __init__(self, pts, kind, where, ext0=0.0, ext1=0.0, meta=None):
        self.pts = pts
        self.kind = kind
        self.where = where
        self.ext0, self.ext1 = ext0, ext1
        self.meta = meta or {}
        self.cum = [0.0]
        for i in range(1, len(pts)):
            self.cum.append(self.cum[-1] + math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]))
        self.length = self.cum[-1]

    def point(self, s):
        s = min(max(s, 0.0), self.length)
        lo, hi = 0, len(self.cum) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.cum[mid] <= s:
                lo = mid
            else:
                hi = mid
        seg = self.cum[hi] - self.cum[lo]
        f = 0.0 if seg < 1e-12 else (s - self.cum[lo]) / seg
        a, b = self.pts[lo], self.pts[hi]
        return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)


def cover(line, index, names=None):
    """Every stretch of the line over a piece: [(s0, s1, piece)] sorted by s0."""
    out = []
    for i in range(1, len(line.pts)):
        x0, z0 = line.pts[i - 1]
        x1, z1 = line.pts[i]
        bbox = (min(x0, x1) - 0.5, max(x0, x1) + 0.5, min(z0, z1) - 0.5, max(z0, z1) + 0.5)
        seg = line.cum[i] - line.cum[i - 1]
        for piece in index.query(bbox):
            if names and piece.name not in names:
                continue
            hit = segment_clip(piece, x0, z0, x1, z1)
            if hit and (hit[1] - hit[0]) * seg > 1e-6:
                out.append([line.cum[i - 1] + hit[0] * seg, line.cum[i - 1] + hit[1] * seg, piece])
    # Merge each piece's consecutive stretches (a curve line is many short segments).
    out.sort(key=lambda r: (id(r[2]), r[0]))
    merged = []
    for r in out:
        if merged and merged[-1][2] is r[2] and r[0] <= merged[-1][1] + 1e-6:
            merged[-1][1] = max(merged[-1][1], r[1])
        else:
            merged.append(r)
    merged.sort(key=lambda r: r[0])
    return merged


class Ground:
    """The ground two ways: exactly (the height function), and as 4-stud voxels drawn between centres."""

    def __init__(self, geo):
        self.geo = geo
        self.voxel = {}

    def exact(self, pts):
        return self.geo.ground(pts)

    def voxels(self, pts):
        need = set()
        cells = []
        for x, z in pts:
            i, j = math.floor((x - 2) / 4), math.floor((z - 2) / 4)
            cells.append((i, j, (x - 2) / 4 - i, (z - 2) / 4 - j))
            for di in (0, 1):
                for dj in (0, 1):
                    key = (i + di, j + dj)
                    if key not in self.voxel:
                        need.add(key)
        need = sorted(need)
        if need:
            heights = self.geo.ground([(k[0] * 4 + 2, k[1] * 4 + 2) for k in need])
            for key, h in zip(need, heights):
                self.voxel[key] = h
        out = []
        for i, j, fx, fz in cells:
            v = self.voxel
            h0 = v[(i, j)] * (1 - fx) + v[(i + 1, j)] * fx
            h1 = v[(i, j + 1)] * (1 - fx) + v[(i + 1, j + 1)] * fx
            out.append(h0 * (1 - fz) + h1 * fz)
        return out


def fmt_xz(p):
    return "(%.1f, %.1f)" % (p[0], p[1])


def measure(geo, show=False):
    r = Counter()
    worst = {}
    notes = defaultdict(list)

    def note(key, text, value=None):
        if value is not None and value > worst.get(key, (-1, ""))[0]:
            worst[key] = (value, text)
        if len(notes[key]) < (50 if show else 3):
            notes[key].append(text)

    parts = geo.parts
    pieces = [Piece(p) for p in parts if p["name"] in SURFACE and not p["invisible"]]
    surf_index = Index()
    for pc in pieces:
        surf_index.add(pc, pc.bbox)
    kerb_pieces = [Piece(p) for p in parts if p["name"] in KERBS]
    kerb_index = Index()
    for pc in kerb_pieces:
        kerb_index.add(pc, pc.bbox)
    nodes = {n["index"]: n for n in geo.nodes}
    edges = {e["index"]: e for e in geo.edges}

    # ---------------------------------------------------------------- the lines
    lines = []
    for e in geo.edges:
        a, b = nodes[e["a"]], nodes[e["b"]]
        start = a["box"] - 1 if a["curve"] else (-3.0 if a["kind"] == "mouth" else 0.0)
        end = e["length"] - (b["box"] - 1 if b["curve"] else (-3.0 if b["kind"] == "mouth" else 0.0))
        right = (-e["dz"], e["dx"])
        for lat in ROAD_LANES:
            p0 = (e["fx"] + e["dx"] * start + right[0] * lat, e["fz"] + e["dz"] * start + right[1] * lat)
            p1 = (e["fx"] + e["dx"] * end + right[0] * lat, e["fz"] + e["dz"] * end + right[1] * lat)
            lines.append(Line([p0, p1], "road", "edge %d %s-to-%s lateral %.1f" % (e["index"], a["kind"], b["kind"], lat),
                              ext0=max(0.0, -start), ext1=max(0.0, end - e["length"]),
                              meta={"edge": e, "lat": lat, "start": start, "outer": abs(lat) >= HALF - 0.1 - 1e-6}))
    for n in geo.nodes:
        c = n["curve"]
        if not c:
            continue
        # The curve's edges are chords between the radii its pieces share (RoadNetwork's curveBand), so
        # its lines are chords too, run on half a stud along the straights at each end. The outermost
        # keeps inside the outer chords, which cut inside the arc by their sagitta.
        count = max(1, c["pieces"])
        for lat in ROAD_LANES:
            rad = c["radius"] + lat
            if lat > 0:
                sag = (c["radius"] + HALF) * (1 - math.cos(abs(c["sweep"]) / count / 2))
                rad = c["radius"] + min(lat, HALF - 0.1 - sag)
            if rad < 0.5:
                continue
            pts = [(c["cx"] + math.cos(c["a1"] + c["sweep"] * k / count) * rad,
                    c["cz"] + math.sin(c["a1"] + c["sweep"] * k / count) * rad) for k in range(count + 1)]
            ends = []
            for k0, k1 in ((0, 1), (len(pts) - 1, len(pts) - 2)):
                dx, dz = pts[k0][0] - pts[k1][0], pts[k0][1] - pts[k1][1]
                norm = math.hypot(dx, dz)
                ends.append((pts[k0][0] + dx / norm * 0.5, pts[k0][1] + dz / norm * 0.5))
            pts = [ends[0]] + pts + [ends[1]]
            lines.append(Line(pts, "curve", "curve at node %d radius %.0f lateral %.1f" % (n["index"], c["radius"], lat),
                              meta={"node": n, "lat": lat, "outer": abs(lat) >= HALF - 0.1 - 1e-6}))
    # Town streets and every junction box, end to end and a stud past each end.
    for p in parts:
        if p["name"] not in ("Asphalt", "JunctionAsphalt"):
            continue
        pc = Piece(p)
        axes = [(pc.a1, pc.e1), (pc.a2, pc.e2)]
        dirs = [0, 1] if p["name"] == "JunctionAsphalt" else [max(range(2), key=lambda i: axes[i][1])]
        for d in dirs:
            along, half_len = axes[d]
            across, half_w = axes[1 - d]
            ax, az = along[0], along[2]
            norm = math.hypot(ax, az)
            ax, az = ax / norm, az / norm
            cx, cz = across[0], across[2]
            norm = math.hypot(cx, cz)
            cx, cz = cx / norm, cz / norm
            for lat in lanes(half_w * 2):
                ox, oz = pc.c[0] + cx * lat, pc.c[2] + cz * lat
                p0 = (ox - ax * (half_len + 1), oz - az * (half_len + 1))
                p1 = (ox + ax * (half_len + 1), oz + az * (half_len + 1))
                lines.append(Line([p0, p1], "street" if p["name"] == "Asphalt" else "box",
                                  "%s %s at %s lateral %.1f" % (p["name"], p["chain"].split("/")[0], fmt_xz((pc.c[0], pc.c[2])), lat),
                                  ext0=1.0, ext1=1.0, meta={"piece": pc, "lat": lat, "outer": abs(lat) >= half_w - 0.1 - 1e-6}))

    # ---------------------------------------------------------------- flush along the lines
    ground = Ground(geo)
    r["lines"] = len(lines)
    terrain_pts, terrain_meta = [], []
    for line in lines:
        runs = cover(line, surf_index)
        r["line_studs"] += line.length
        lo, hi = line.ext0, line.length - line.ext1
        # Gaps within the line proper, and ends in the extensions.
        covered = []
        for s0, s1, _ in runs:
            covered.append((max(s0, 0.0), min(s1, line.length)))
        covered.sort()
        cursor = 0.0
        holes = []
        for s0, s1 in covered:
            if s0 > cursor + TOL_GAP:
                holes.append((cursor, s0))
            cursor = max(cursor, s1)
        if line.length > cursor + TOL_GAP:
            holes.append((cursor, line.length))
        for h0, h1 in holes:
            inner0, inner1 = max(h0, lo), min(h1, hi)
            if inner1 - inner0 > TOL_GAP:
                r["gap"] += 1
                p = line.point((inner0 + inner1) / 2)
                note("gap", "%.2f-stud gap at %s on %s" % (inner1 - inner0, fmt_xz(p), line.where), inner1 - inner0)
            # A hole reaching the line's own end, in an extension: the surface stops there.
            if (h0 <= lo + 1e-6 and h1 >= lo - 1e-6 and lo > 0) or (h1 >= hi - 1e-6 and h0 <= hi + 1e-6 and line.ext1 > 0):
                if abs(line.meta.get("lat", 1)) < 1e-6:
                    at_start = h0 <= lo + 1e-6 and lo > 0
                    s_end = lo if at_start else hi
                    direction = -1 if at_start else 1
                    probe = line.point(s_end + direction * 0.4)
                    over = [k.name for k in kerb_index.at(*probe) if k.inside(probe[0], probe[1])[0] >= -0.01]
                    # A kerb across the end closes the street off; a dropped one opens it into a car park.
                    key = "end_capped" if "Kerb" in over else ("end_carpark" if "DroppedKerb" in over else "end_raw")
                    # A country junction box's side with no arm (the top of a T): the road's edge line
                    # runs across it and the verge is beyond, as at any road's edge.
                    if key == "end_raw" and line.kind == "box" and line.meta["piece"].part["chain"].startswith("Roads"):
                        key = "end_junction_side"
                    capped = key != "end_raw"
                    r[key] += 1
                    if not capped:
                        note("end_raw", "surface stops with no kerb at %s on %s" % (fmt_xz(line.point(s_end)), line.where))
        # Steps at every boundary.
        bounds = set()
        for s0, s1, _ in runs:
            for s in (s0, s1):
                if -1e-6 <= s <= line.length + 1e-6:
                    bounds.add(round(s, 4))
        for s in sorted(bounds):
            here = [pc for s0, s1, pc in runs if s0 - 0.05 <= s <= s1 + 0.05]
            if len(here) < 2:
                continue
            x, z = line.point(s)
            tops = [pc.top_y(x, z) for pc in here]
            spread = max(tops) - min(tops)
            r["joints"] += 1
            worst_step = worst.get("step_max", (0, ""))[0]
            if spread > worst_step:
                worst["step_max"] = (spread, "%.3f at %s (%s) on %s" % (spread, fmt_xz((x, z)), "/".join(sorted(set(pc.name for pc in here))), line.where))
            if spread > TOL_STEP:
                r["step"] += 1
                note("step", "%.3f step at %s between %s on %s" % (spread, fmt_xz((x, z)), "/".join(pc.name for pc in here), line.where), spread)
                names = set(pc.name for pc in here)
                if "BridgeRoad" in names and len(names) > 1:
                    r["bridge_step"] += 1
        # Overlaps.
        for i in range(len(runs)):
            for j in range(i + 1, len(runs)):
                a0, a1, pa = runs[i]
                b0, b1, pb = runs[j]
                if b0 >= a1:
                    break
                ov = min(a1, b1) - max(a0, b0)
                if ov > TOL_OVERLAP:
                    x, z = line.point((max(a0, b0) + min(a1, b1)) / 2)
                    d = abs(pa.top_y(x, z) - pb.top_y(x, z))
                    key = "overlap_coplanar" if d < 0.005 else "overlap_stacked"
                    r[key] += 1
                    note(key, "%s/%s overlap %.2f along, tops %.3f apart, at %s on %s" % (pa.name, pb.name, ov, d, fmt_xz((x, z)), line.where), ov)
        # Terrain samples every stud on country roads, curves and streets.
        if line.kind in ("road", "curve", "street"):
            s = max(lo, 0.0) + 0.5
            while s < hi - 0.5:
                here = [pc for s0, s1, pc in runs if s0 <= s <= s1]
                if here:
                    if line.kind == "road":
                        e = line.meta["edge"]
                        along = line.meta["start"] + s
                        if any(b0 - 4 <= along <= b1 + 4 for b0, b1 in e["bridges"]):
                            s += 1.0
                            continue
                    x, z = line.point(s)
                    top_piece = max(here, key=lambda pc: pc.top_y(x, z))
                    terrain_pts.append((x, z))
                    terrain_meta.append((line, top_piece.top_y(x, z), top_piece.thick / abs(top_piece.n[1]), top_piece.name))
                s += 1.0

    # ---------------------------------------------------------------- terrain under the roads
    exact = ground.exact(terrain_pts)
    vox = ground.voxels(terrain_pts)
    edge_lat = HALF - 0.1
    for (x, z), (line, top, thick, name), g, gv in zip(terrain_pts, terrain_meta, exact, vox):
        is_edge = line.meta.get("outer", False)
        for label, gh in (("", g), ("_vox", gv)):
            r["ground_samples" + label] += 1
            clearance = top - gh
            if label == "":
                worst["lift_lo"] = min(worst.get("lift_lo", (9, ""))[0], clearance), ""
                worst["lift_hi"] = max(worst.get("lift_hi", (-9, ""))[0], clearance), ""
            if clearance < 0.05:
                r["poke" + label] += 1
                note("poke" + label, "terrain %.2f from the top of %s at %s on %s" % (clearance, name, fmt_xz((x, z)), line.where), 0.05 - clearance)
            if is_edge and gh < top - thick - 0.02:
                r["float" + label] += 1
                note("float" + label, "%s edge %.2f over the ground at %s on %s" % (name, top - thick - gh, fmt_xz((x, z)), line.where), top - thick - gh)
    # A pad's flat reaches 8 studs past its margin whatever stands there (MapTerrain.FlattenPad), which
    # the harness's ground doesn't model: under a town street it must be at the street's own ground.
    # (Under a country road the second RestoreRoadGround puts the road's ground back after the towns.)
    for (x, z), (line, top, thick, name), pad in zip(terrain_pts, terrain_meta, geo.pad_flat(terrain_pts)):
        if line.kind == "street" and pad is not None:
            r["pad_samples"] += 1
            if abs(pad - (top - LIFT)) > 0.05:
                r["pad_under"] += 1
                note("pad_under", "a pad's flat at %.2f under the street (ground %.2f) at %s on %s" % (pad, top - LIFT, fmt_xz((x, z)), line.where),
                     abs(pad - (top - LIFT)))

    # Shoulders beside country roads and curves: flat at the road's ground out to the corridor's flat.
    sh_pts, sh_meta = [], []
    for e in geo.edges:
        a, b = nodes[e["a"]], nodes[e["b"]]
        start = a["box"] if a["curve"] else 0.0
        end = e["length"] - (b["box"] if b["curve"] else 0.0)
        right = (-e["dz"], e["dx"])
        along = start + 0.5
        while along < end - 0.5:
            if not any(b0 - 6 <= along <= b1 + 6 for b0, b1 in e["bridges"]):
                road = geo.edge_height(e, along)
                for lat in (HALF + 0.5, HALF + SHOULDER, HALF + SHOULDER + BANK_SETBACK - 1):
                    for side in (-1, 1):
                        sh_pts.append((e["fx"] + e["dx"] * along + right[0] * side * lat, e["fz"] + e["dz"] * along + right[1] * side * lat))
                        sh_meta.append((road, "edge %d %.0f along, %.1f out" % (e["index"], along, side * lat)))
            along += 2.0
    for n in geo.nodes:
        c = n["curve"]
        if not c:
            continue
        steps = max(4, int(abs(c["sweep"]) * c["radius"] / 2))
        for k in range(steps + 1):
            ang = c["a1"] + c["sweep"] * k / steps
            for lat in (HALF + 0.5, HALF + SHOULDER, HALF + SHOULDER + BANK_SETBACK - 1):
                for side in (-1, 1):
                    rad = c["radius"] + side * lat
                    if rad > 1:
                        sh_pts.append((c["cx"] + math.cos(ang) * rad, c["cz"] + math.sin(ang) * rad))
                        sh_meta.append((n["height"], "curve at node %d %.0f%% round, %.1f out" % (n["index"], 100 * k / steps, side * lat)))
    in_water = geo.in_river(sh_pts)
    for (x, z), (road, where), g, wet in zip(sh_pts, sh_meta, ground.exact(sh_pts), in_water):
        if wet:
            continue
        r["shoulder_samples"] += 1
        if abs(g - road) > 0.05:
            r["shoulder"] += 1
            note("shoulder", "ground %.2f off the road's at %s (%s)" % (g - road, fmt_xz((x, z)), where), abs(g - road))

    # ---------------------------------------------------------------- markings
    # (A car's interior has a "Dash" too.)
    marks = [Piece(p) for p in parts if p["name"] in MARKS and "ParkedCar" not in p["chain"] and not p["chain"].startswith("Vehicles")]
    r["markings"] = len(marks)
    for mk in marks:
        pts = [(mk.c[0], mk.c[2])]
        for s1 in (-1, 1):
            for s2 in (-1, 1):
                q1, q2 = s1 * max(0, mk.e1 - 0.02), s2 * max(0, mk.e2 - 0.02)
                pts.append((mk.c[0] + mk.a1[0] * q1 + mk.a2[0] * q2, mk.c[2] + mk.a1[2] * q1 + mk.a2[2] * q2))
        offs, bare = [], 0
        for x, z in pts:
            tops = [pc.top_y(x, z) for pc in surf_index.at(x, z) if pc.inside(x, z)[0] > -0.005]
            if not tops:
                bare += 1
                continue
            bottom = mk.top_y(x, z) - mk.thick / abs(mk.n[1])
            offs.append(bottom - max(tops))
        if bare:
            r["mark_overhang"] += 1
            note("mark_overhang", "%s at %s: %d of 5 points over no surface" % (mk.name, fmt_xz((mk.c[0], mk.c[2])), bare), bare)
        if offs:
            off = max(offs, key=abs)
            if off > TOL_MARK:
                r["mark_float"] += 1
                note("mark_float", "%s at %s floats %.3f" % (mk.name, fmt_xz((mk.c[0], mk.c[2])), off), off)
            elif off < -TOL_MARK:
                r["mark_buried"] += 1
                note("mark_buried", "%s at %s buried %.3f" % (mk.name, fmt_xz((mk.c[0], mk.c[2])), -off), -off)
    mark_index = Index()
    for mk in marks:
        mark_index.add(mk, mk.bbox)
    seen = set()
    for mk in marks:
        for other in mark_index.query(mk.bbox):
            if other is mk or (id(other), id(mk)) in seen:
                continue
            seen.add((id(mk), id(other)))
            bb, ob = mk.bbox, other.bbox
            if bb[1] < ob[0] or ob[1] < bb[0] or bb[3] < ob[2] or ob[3] < bb[2]:
                continue
            ov = clip(ccw(mk.polygon()), ccw(other.polygon()))
            if len(ov) >= 3 and area(ov) > 0.005:
                cx = sum(p[0] for p in ov) / len(ov)
                cz = sum(p[1] for p in ov) / len(ov)
                if abs(mk.top_y(cx, cz) - other.top_y(cx, cz)) < 0.005:
                    r["mark_zfight"] += 1
                    note("mark_zfight", "%s/%s share %.2f sq studs in one plane at %s" % (mk.name, other.name, area(ov), fmt_xz((cx, cz))), area(ov))

    # Edge lines, walked along their own paths.
    edge_marks = Index()
    for mk in marks:
        if mk.name == "RoadEdge":
            edge_marks.add(mk, mk.bbox)
    edge_paths = []
    lateral = HALF - EDGE_INSET
    for e in geo.edges:
        a, b = nodes[e["a"]], nodes[e["b"]]
        s0 = a["box"]
        s1 = e["length"] - b["box"]
        right = (-e["dz"], e["dx"])
        for side in (-1, 1):
            p0 = (e["fx"] + e["dx"] * s0 + right[0] * side * lateral, e["fz"] + e["dz"] * s0 + right[1] * side * lateral)
            p1 = (e["fx"] + e["dx"] * s1 + right[0] * side * lateral, e["fz"] + e["dz"] * s1 + right[1] * side * lateral)
            edge_paths.append(Line([p0, p1], "edgeline", "edge line of edge %d side %d" % (e["index"], side)))
    for n in geo.nodes:
        c = n["curve"]
        if not c:
            continue
        for side in (-1, 1):
            # Along the chords between the radii the curve's pieces share, where its lines are laid.
            rad = c["radius"] + side * lateral
            steps = max(1, c["pieces"])
            pts = [(c["cx"] + math.cos(c["a1"] + c["sweep"] * k / steps) * rad, c["cz"] + math.sin(c["a1"] + c["sweep"] * k / steps) * rad)
                   for k in range(steps + 1)]
            edge_paths.append(Line(pts, "edgeline", "edge line round the curve at node %d side %d" % (n["index"], side)))
    for path in edge_paths:
        # Only the middle of the line counts as on it: 0.1 in from either side of a 0.6 line.
        runs = []
        for s0, s1, mk in cover(path, edge_marks):
            runs.append((s0, s1, mk))
        good = []
        for s0, s1, mk in runs:
            x, z = path.point((s0 + s1) / 2)
            if mk.inside(x, z)[0] >= 0.1:
                good.append((s0, s1))
        good.sort()
        cursor = 0.0
        for s0, s1 in good:
            if s0 - cursor > 0.15:
                r["edgeline_gap"] += 1
                note("edgeline_gap", "%.2f break at %s in the %s" % (s0 - cursor, fmt_xz(path.point(cursor)), path.where), s0 - cursor)
            cursor = max(cursor, s1)
        if path.length - cursor > 0.15:
            r["edgeline_gap"] += 1
            note("edgeline_gap", "%.2f break at %s in the %s" % (path.length - cursor, fmt_xz(path.point(cursor)), path.where), path.length - cursor)
        r["edgeline_studs"] += path.length

    # Kerbs and pavements: one height each everywhere.
    tops = defaultdict(Counter)
    kp = [(pc, (pc.c[0], pc.c[2])) for pc in kerb_pieces]
    for (pc, xz), g in zip(kp, ground.exact([xz for _, xz in kp])):
        tops[pc.name][round(pc.c[1] - g, 2)] += 1
    kerb_heights = {name: dict(c) for name, c in tops.items()}
    for name, c in tops.items():
        if len(c) > 1:
            r["kerb_heights"] += len(c) - 1
            note("kerb_heights", "%s tops over the ground: %s" % (name, dict(c)))

    # ---------------------------------------------------------------- connected: the graph
    parent = {}

    def find(k):
        while parent.setdefault(k, k) != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    def union(a, b):
        parent[find(a)] = find(b)
    for e in geo.edges:
        union(("n", e["a"]), ("n", e["b"]))
    for n in geo.nodes:
        if n["town"]:
            union(("n", n["index"]), ("t", n["town"]))
        find(("n", n["index"]))
    for t in geo.towns:
        find(("t", str(t["index"])))
    comps = set(find(("t", str(t["index"]))) for t in geo.towns)
    r["graph_components"] = len(comps)
    r["towns"] = len(geo.towns)
    kinds = Counter(n["kind"] for n in geo.nodes)
    r["dead_ends"] = kinds.get("end", 0)
    for n in geo.nodes:
        if n["kind"] == "end":
            note("dead_ends", "a road ends in open ground at %s" % fmt_xz((n["x"], n["z"])))
    if len(comps) > 1:
        note("graph_components", "towns fall into %d separate networks" % len(comps))
    r["square_bends"] = sum(1 for n in geo.nodes if n["kind"] == "bend" and not n["curve"])

    # Junction arms: each edge's slab run starts exactly at its node's box (or tangent, or street end).
    for e in geo.edges:
        slabs = e["slabs"]
        if not slabs:
            r["arm_gap"] += 1
            note("arm_gap", "edge %d has no slabs at all" % e["index"])
            continue
        a, b = nodes[e["a"]], nodes[e["b"]]
        for node, gap in ((a, slabs[0][0] - a["box"]), (b, (e["length"] - b["box"]) - slabs[-1][1])):
            r["arms"] += 1
            if abs(gap) > 0.01:
                r["arm_gap"] += 1
                note("arm_gap", "edge %d's slabs %s %.2f %s its %s at %s" % (e["index"], "stop" if gap > 0 else "run", abs(gap),
                                                                           "short of" if gap > 0 else "into", node["kind"], fmt_xz((node["x"], node["z"]))), abs(gap))
        for i in range(1, len(slabs)):
            if abs(slabs[i][0] - slabs[i - 1][1]) > 1e-3:
                r["arm_gap"] += 1
                note("arm_gap", "edge %d's slabs %d and %d don't meet (%.3f)" % (e["index"], i, i + 1, slabs[i][0] - slabs[i - 1][1]))

    # ---------------------------------------------------------------- connected: the surface
    cells = {}
    for pc in pieces:
        if pc.name not in DRIVE and pc.name != "Paving" and pc.name not in RING:
            continue
        x0, x1, z0, z1 = pc.bbox
        for i in range(math.floor(x0 - 0.3), math.floor(x1 + 0.3) + 1):
            for j in range(math.floor(z0 - 0.3), math.floor(z1 + 0.3) + 1):
                clear, y = pc.inside(i + 0.5, j + 0.5)
                if clear > -0.3:
                    if (i, j) not in cells or y > cells[(i, j)]:
                        cells[(i, j)] = y
    label = {}
    comp_sizes = []
    for start in cells:
        if start in label:
            continue
        cid = len(comp_sizes)
        stack = [start]
        label[start] = cid
        size = 0
        while stack:
            cell = stack.pop()
            size += 1
            h = cells[cell]
            for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nb = (cell[0] + di, cell[1] + dj)
                if nb in cells and nb not in label and abs(cells[nb] - h) < 0.3:
                    label[nb] = cid
                    stack.append(nb)
        comp_sizes.append(size)
    main = max(range(len(comp_sizes)), key=lambda k: comp_sizes[k]) if comp_sizes else None
    r["surface_cells"] = len(cells)
    r["surface_components"] = len(comp_sizes)
    for cid, size in enumerate(comp_sizes):
        if cid != main:
            some = next(c for c, v in label.items() if v == cid)
            note("surface_components", "a separate piece of road surface, %d sq studs, at %s" % (size, fmt_xz(some)))
    for t in geo.towns:
        cell = (math.floor(t["x"] + 20), math.floor(t["z"]))
        if label.get(cell) != main:
            r["town_off_network"] += 1
            note("town_off_network", "town %d's square at %s is not on the main road surface" % (t["index"], fmt_xz((t["x"], t["z"]))))

    # Road over water only on bridges; both ends of every bridge on land.
    wet_pts, wet_meta = [], []
    for e in geo.edges:
        along = 0.25
        while along < e["length"]:
            wet_pts.append((e["fx"] + e["dx"] * along, e["fz"] + e["dz"] * along))
            on_bridge = any(s0 <= along <= s1 and br for s0, s1, br in e["slabs"])
            wet_meta.append((e, along, on_bridge))
            along += 0.5
        for s0, s1 in e["bridges"]:
            r["bridges"] += 1
            for along in (s0 - 2, s1 + 2):
                wet_pts.append((e["fx"] + e["dx"] * along, e["fz"] + e["dz"] * along))
                wet_meta.append((e, along, "end"))
    for n in geo.nodes:
        c = n["curve"]
        if c:
            steps = max(4, int(abs(c["sweep"]) * c["radius"] / 0.5))
            for k in range(steps + 1):
                ang = c["a1"] + c["sweep"] * k / steps
                wet_pts.append((c["cx"] + math.cos(ang) * c["radius"], c["cz"] + math.sin(ang) * c["radius"]))
                wet_meta.append((None, 0, False))
    for (x, z), (e, along, on_bridge), wet in zip(wet_pts, wet_meta, geo.in_river(wet_pts)):
        if not wet:
            continue
        if on_bridge == "end":
            r["bridge_end_wet"] += 1
            note("bridge_end_wet", "a bridge on edge %d ends over water %.0f along" % (e["index"], along))
        elif not on_bridge:
            r["water_unbridged"] += 1
            note("water_unbridged", "road over the river with no bridge at %s" % fmt_xz((x, z)))
    deck_bad = 0
    decks = [Piece(p) for p in parts if p["name"] == "BridgeDeck"]
    bridge_roads = [pc for pc in pieces if pc.name == "BridgeRoad"]
    for rd in bridge_roads:
        under = [d for d in decks if d.inside(rd.c[0], rd.c[2])[0] > 0]
        bottom = rd.c[1] - rd.thick / abs(rd.n[1])
        if not under or abs(max(d.top_y(rd.c[0], rd.c[2]) for d in under) - bottom) > 0.01:
            deck_bad += 1
            note("deck", "bridge road at %s not sitting on its deck" % fmt_xz((rd.c[0], rd.c[2])))
    r["deck"] = deck_bad

    # Access: car parks and driveways.
    # Each car park is its asphalt (ParkingLots' LotSurface): every car park's pieces share one chain
    # (Town/ParkingLot), so they are told apart by that one piece each, not by chain.
    lots = [p for p in parts if p["name"] == "LotSurface" and "ParkingLot" in p["chain"]]
    # A car park or driveway is connected when a dropped kerb stands at a street's edge in front of it
    # and nothing solid stands on the way between them. A pavement is 5 studs; a car park's asphalt
    # starts behind its own front kerb (0.8), with its apron across the pavement.
    drive_cells = set(cells)
    dropped = [Piece(p) for p in parts if p["name"] == "DroppedKerb"]
    solid = []
    for p in parts:
        if p["collide"] and not p["invisible"] and p["name"] not in ROAD_OWN and not p["chain"].startswith("Vehicles") \
                and "ParkedCar" not in p["chain"]:
            cs = corners(p)
            solid.append((hull([(c[0], c[2]) for c in cs]), min(c[1] for c in cs), max(c[1] for c in cs), p))
    solid_index = Index()
    for item in solid:
        xs = [q[0] for q in item[0]]
        zs = [q[1] for q in item[0]]
        solid_index.add(item, (min(xs), max(xs), min(zs), max(zs)))

    def way_in(outline, reach, what):
        """The dropped kerb serving `outline` (within `reach` of it and at a street's edge), and
        whatever solid stands between them, or (None, None)."""
        for dk in dropped:
            at = (dk.c[0], dk.c[2])
            if poly_distance(outline, at) > reach:
                continue
            if not any((math.floor(at[0] + dx), math.floor(at[1] + dz)) in drive_cells for dx in (-1, 0, 1) for dz in (-1, 0, 1)):
                continue
            # From the kerb to the outline's nearest point (where the driveway meets the lot, not its middle,
            # which from a side entrance cuts across the kerbed rows), carried 3 studs on inside, a car's
            # width: anything solid in it?
            nx, nz = nearest_on_poly(outline, at)
            d = math.hypot(nx - at[0], nz - at[1])
            if d > 1e-6:
                nx, nz = nx + (nx - at[0]) / d * 3, nz + (nz - at[1]) / d * 3
            cx, cz = nx, nz
            blocked = None
            steps = 12
            for k in range(steps + 1):
                t = k / steps
                x, z = at[0] + (cx - at[0]) * t, at[1] + (cz - at[1]) * t
                for poly, y0, y1, part in solid_index.at(x, z):
                    if y1 > dk.c[1] + 0.3 and y0 < dk.c[1] + 4.5 and poly_distance(poly, (x, z)) < 1.5:
                        blocked = part
                        break
                if blocked:
                    break
            return dk, blocked
        return None, None
    for lot in lots:
        poly = hull([(c[0], c[2]) for c in corners(lot)])
        r["lots"] += 1
        centre = (sum(q[0] for q in poly) / len(poly), sum(q[1] for q in poly) / len(poly))
        dk, blocked = way_in(poly, 5.0 + 2.0 + 1.5, "car park")
        if not dk:
            r["lot_unconnected"] += 1
            note("lot_unconnected", "car park at %s has no way in from a street" % fmt_xz(centre))
        elif blocked:
            r["lot_unconnected"] += 1
            note("lot_unconnected", "car park at %s: %s (%s) stands in its way in" % (fmt_xz(centre), blocked["name"], blocked["chain"]))
    for p in parts:
        if p["name"] != "Driveway":
            continue
        pc = Piece(p)
        r["driveways"] += 1
        dk, blocked = way_in(pc.polygon(), 5.0 + 1.0, "driveway")
        if not dk or blocked:
            r["driveway_unconnected"] += 1
            note("driveway_unconnected", "driveway at %s %s" % (fmt_xz((pc.c[0], pc.c[2])),
                                                               "has no dropped kerb to a street" if not dk else "is blocked by " + blocked["name"]))

    # Width: country slabs and boxes; every mouth meeting a street of the road's width.
    widths = Counter()
    for pc in pieces:
        if pc.name in ("RoadSurface", "BridgeRoad") or (pc.name == "JunctionAsphalt" and pc.part["chain"].startswith("Roads")):
            # A slab's X is across the road (its first face axis); a box is square.
            widths[(pc.name, round(pc.e1 * 2, 2))] += 1
    r["road_widths"] = len(set(w for (_, w) in widths))
    for n in geo.nodes:
        if n["kind"] != "mouth":
            continue
        arm, eidx = next(iter(n["arms"].items()))
        e = edges[eidx]
        sgn = 1 if e["a"] == n["index"] else -1
        # 2 studs back into the town along the road's line.
        x = n["x"] - e["dx"] * sgn * 2
        z = n["z"] - e["dz"] * sgn * 2
        street = [pc for pc in surf_index.at(x, z) if pc.name == "Asphalt" and pc.inside(x, z)[0] > 0]
        r["mouths"] += 1
        if not street:
            r["mouth_mismatch"] += 1
            note("mouth_mismatch", "no town street where the road enters town at %s" % fmt_xz((n["x"], n["z"])))
            continue
        w = min(street[0].e1, street[0].e2) * 2
        if abs(w - 2 * HALF) > 0.01:
            r["mouth_mismatch"] += 1
            note("mouth_mismatch", "road meets a %.1f-wide street at %s" % (w, fmt_xz((n["x"], n["z"]))), abs(w - 2 * HALF))

    # ---------------------------------------------------------------- kinks
    vertical = 0.0
    for e in geo.edges:
        slabs = e["slabs"]
        for i in range(1, len(slabs)):
            def angle(s0, s1):
                return math.atan((geo.edge_height(e, s1) - geo.edge_height(e, s0)) / max(1e-6, s1 - s0))
            k = abs(math.degrees(angle(slabs[i][0], slabs[i][1]) - angle(slabs[i - 1][0], slabs[i - 1][1])))
            vertical = max(vertical, k)
            if k > 1.0:
                r["kink_vertical"] += 1
                note("kink_vertical", "%.2f deg crease on edge %d at %.0f along" % (k, e["index"], slabs[i][0]), k)
    worst["kink_vertical_max"] = (vertical, "")
    horizontal = 0.0
    for n in geo.nodes:
        c = n["curve"]
        if not c:
            continue
        per_piece = math.degrees(abs(c["sweep"]) / max(1, c["pieces"]))
        horizontal = max(horizontal, per_piece)
        if per_piece > 10.01:
            r["kink_curve"] += 1
            note("kink_curve", "curve at node %d turns %.1f deg a piece" % (n["index"], per_piece), per_piece)
        for t, arm_name in ((0, None), (1, None)):
            ang = c["a1"] + c["sweep"] * t
            tangent = (-math.sin(ang) * (1 if c["sweep"] > 0 else -1), math.cos(ang) * (1 if c["sweep"] > 0 else -1))
            px, pz = c["cx"] + math.cos(ang) * c["radius"], c["cz"] + math.sin(ang) * c["radius"]
            best = 180.0
            for eidx in n["arms"].values():
                e = edges[eidx]
                cross = abs((px - e["fx"]) * e["dz"] - (pz - e["fz"]) * e["dx"])
                if cross < 0.01:
                    dotp = abs(tangent[0] * e["dx"] + tangent[1] * e["dz"])
                    best = min(best, math.degrees(math.acos(min(1.0, dotp))))
            horizontal = max(horizontal, best)
            if best > 0.5:
                r["kink_tangent"] += 1
                note("kink_tangent", "curve at node %d meets its road at %.1f deg" % (n["index"], best), best)
    worst["kink_horizontal_max"] = (horizontal, "")

    # ---------------------------------------------------------------- in the road
    carriage = [pc for pc in pieces if pc.name in CARRIAGEWAY]
    carr_index = Index()
    for pc in carriage:
        carr_index.add(pc, pc.bbox)
    for p in parts:
        if p["name"] in ROAD_OWN or p["invisible"] or p["chain"].startswith("Vehicles") or "ParkedCar" in p["chain"] \
                or p["name"] in ("ParkedCar",) or "Bridge" in p["name"]:
            continue
        cs = corners(p)
        y0, y1 = min(c[1] for c in cs), max(c[1] for c in cs)
        xs = [c[0] for c in cs]
        zs = [c[2] for c in cs]
        cand = carr_index.query((min(xs), max(xs), min(zs), max(zs)))
        if not cand:
            continue
        poly = hull([(c[0], c[2]) for c in cs])
        for pc in cand:
            top = pc.top_y((min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2)
            if y1 < top + 0.15 or y0 > top + 4.5:
                continue
            a = overlap_area(poly, pc.polygon(0.3))
            if a > 0.01:
                r["in_road"] += 1
                note("in_road", "%s (%s) stands in the %s at %s" % (p["name"], p["chain"], pc.name, fmt_xz(((min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2))), a)
                break

    r["pieces"] = len(pieces)
    r["curves"] = sum(1 for n in geo.nodes if n["curve"])
    return r, worst, notes, kerb_heights


def nearest_on_poly(poly, p):
    """The point on a polygon's boundary nearest p."""
    best, at = math.inf, p
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        ex, ez = b[0] - a[0], b[1] - a[1]
        L = ex * ex + ez * ez
        t = 0 if L < 1e-12 else max(0, min(1, ((p[0] - a[0]) * ex + (p[1] - a[1]) * ez) / L))
        q = (a[0] + ex * t, a[1] + ez * t)
        d = math.hypot(p[0] - q[0], p[1] - q[1])
        if d < best:
            best, at = d, q
    return at


def poly_distance(poly, p):
    """Distance from p to a convex polygon (0 inside)."""
    inside = True
    best = math.inf
    poly = ccw(poly)
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        ex, ez = b[0] - a[0], b[1] - a[1]
        if ex * (p[1] - a[1]) - ez * (p[0] - a[0]) < 0:
            inside = False
        L = ex * ex + ez * ez
        t = 0 if L < 1e-12 else max(0, min(1, ((p[0] - a[0]) * ex + (p[1] - a[1]) * ez) / L))
        best = min(best, math.hypot(p[0] - a[0] - ex * t, p[1] - a[1] - ez * t))
    return 0.0 if inside else best


# The rules: which counts must be zero, printed in this order.
FAULTS = ["gap", "step", "overlap_coplanar", "overlap_stacked", "end_raw", "poke", "poke_vox", "float", "float_vox", "pad_under", "shoulder",
          "mark_float", "mark_buried", "mark_overhang", "mark_zfight", "edgeline_gap", "kerb_heights", "graph_components_extra",
          "dead_ends", "square_bends", "arm_gap", "surface_components_extra", "town_off_network", "water_unbridged",
          "bridge_end_wet", "bridge_step", "deck", "lot_unconnected", "driveway_unconnected", "road_widths_extra",
          "mouth_mismatch", "kink_vertical", "kink_curve", "kink_tangent", "in_road"]


def faults_of(r):
    f = Counter()
    for key in FAULTS:
        if key == "graph_components_extra":
            f[key] = max(0, r["graph_components"] - 1)
        elif key == "surface_components_extra":
            f[key] = max(0, r["surface_components"] - 1)
        elif key == "road_widths_extra":
            # Slabs alternate full width and SLAB_STAGGER narrower; the boxes are the full width: two.
            f[key] = max(0, r["road_widths"] - 2)
        else:
            f[key] = r[key]
    return f


def run_one(args):
    map_id, seed, faults, show = args
    geo = roads_map.build(map_id, seed, faults)
    r, worst, notes, kerbs = measure(geo, show)
    return map_id, seed, geo.seconds, dict(r), {k: v for k, v in worst.items()}, dict(notes), kerbs, geo.warnings


def run_many(jobs):
    if len(jobs) == 1 or os.environ.get("ROADS_SERIAL"):
        return [run_one(j) for j in jobs]
    import multiprocessing
    with multiprocessing.Pool(min(len(jobs), max(1, (os.cpu_count() or 2)))) as pool:
        return pool.map(run_one, jobs)


def report(results, show):
    totals = Counter()
    examined = Counter()
    for map_id, seed, seconds, r, worst, notes, kerbs, warnings in results:
        f = faults_of(Counter(r))
        totals.update(f)
        for key in ("lines", "line_studs", "joints", "ground_samples", "shoulder_samples", "markings", "edgeline_studs",
                    "arms", "surface_cells", "bridges", "lots", "driveways", "mouths", "pieces", "curves", "towns", "pad_samples",
                    "end_capped", "end_carpark", "end_junction_side"):
            examined[key] += r.get(key, 0)
        bad = {k: v for k, v in f.items() if v}
        print("%-14s seed %d  %5.1fs  %d towns, %d pieces, %d curves, %d bridges, %d lines (%.0f studs), %d joints;"
              " max step %.3f; lift %.2f..%.2f; kinks: grade %.2f deg, plan %.1f deg; faults: %s" % (
                  map_id, seed, seconds, r.get("towns", 0), r.get("pieces", 0), r.get("curves", 0), r.get("bridges", 0),
                  r.get("lines", 0), r.get("line_studs", 0), r.get("joints", 0), worst.get("step_max", (0, ""))[0],
                  worst.get("lift_lo", (0, ""))[0], worst.get("lift_hi", (0, ""))[0],
                  worst.get("kink_vertical_max", (0, ""))[0], worst.get("kink_horizontal_max", (0, ""))[0],
                  ", ".join("%s %d" % kv for kv in sorted(bad.items())) or "none"))
        print("    kerb/pavement tops over ground: %s" % kerbs)
        for w in warnings:
            if "road" in w.lower() or "bridge" in w.lower() or "parking" in w.lower():
                print("    warn: %s" % w[:200])
        for key in FAULTS:
            base = key.replace("_extra", "")
            if f.get(key) and base in notes:
                for text in notes[base][: (50 if show else 3)]:
                    print("    %-22s %s" % (key, text))
    print()
    print("examined: " + ", ".join("%s %d" % (k, v) for k, v in sorted(examined.items())))
    print("TOTAL faults: " + ", ".join("%s %d" % (k, totals[k]) for k in FAULTS))
    return totals


# Planted faults: (name, the rule that must fire, { module: [(old, new)] }). Each breaks something the
# builders must hold forever, not a bug that happens to be there today.
PLANTS = [
    ("every other slab lifted 0.05", "step",
     {"RoadNetwork": [("frame * CFrame.new(0, -thickness / 2, 0), ASPHALT", "frame * CFrame.new(0, -thickness / 2 + (staggered and 0.05 or 0), 0), ASPHALT")]}),
    ("slabs stop 0.3 short of the junction box", "arm_gap",
     {"RoadNetwork": [("local startAt, endAt = edge.a.box, edge.length - edge.b.box\n\tlocal marks",
                       "local startAt, endAt = edge.a.box + 0.3, edge.length - edge.b.box\n\tlocal marks")]}),
    ("markings 0.03 proud of the asphalt", "mark_float",
     {"RoadNetwork": [("local MARK_RAISE = MapDecor.MarkRaise\n", "local MARK_RAISE = MapDecor.MarkRaise + 0.03\n")]}),
    ("the ground graded 0.5 high under the carriageway", "poke",
     {"RoadNetwork": [("\t\treturn road, bestDistance <= HALF + 1.5 and Enum.Material.Asphalt",
                       "\t\treturn road + (bestDistance <= HALF + 1.5 and 0.5 or 0), bestDistance <= HALF + 1.5 and Enum.Material.Asphalt")]}),
    ("one road left unbuilt", "surface_components_extra",
     {"RoadNetwork": [("\t\tlocal merged = edge.bridges or {}\n\t\tlocal slabs = buildSurface(parent, edge, merged)",
                       "\t\tlocal merged = edge.bridges or {}\n\t\tlocal slabs = buildSurface(index == 2 and Instance.new(\"Model\") or parent, edge, merged)")]}),
    ("curves in 30-degree pieces", "kink_curve",
     {"RoadNetwork": [("local CURVE_MAX_TURN = math.rad(10)", "local CURVE_MAX_TURN = math.rad(30)"),
                      ("local CURVE_PIECE = 8 ", "local CURVE_PIECE = 80 ")]}),
    ("road lamps on the carriageway", "in_road",
     {"RoadNetwork": [("right * side * (HALF + SHOULDER + 0.8)", "right * side * (HALF - 2)")]}),
    ("the curve's edge lines off the straights' by a line's width", "edgeline_gap",
     {"RoadNetwork": [("curve.radius + side * (HALF - EDGE_INSET", "curve.radius + side * (HALF - EDGE_INSET - EDGE_WIDTH")]}),
    ("every bridge only 4 studs long", "water_unbridged",
     {"RoadNetwork": [("local s0 = math.max(edge.a.box + 2, along - cross.span / 2)",
                       "local s0 = math.max(edge.a.box + 2, along - 2)"),
                      ("local s1 = math.min(edge.length - edge.b.box - 2, along + cross.span / 2)",
                       "local s1 = math.min(edge.length - edge.b.box - 2, along + 2)")]}),
    ("no kerb ever dropped (car parks and driveways behind a kerb)", "lot_unconnected",
     {"MapDecor": [("\treach = reach or 12\n\tlocal dropped = 0\n", "\treach = reach or 12\n\tlocal dropped = 0\n\tif reach then return 0 end\n")]}),
    ("no kerb ever dropped, seen from the driveways", "driveway_unconnected",
     {"MapDecor": [("\treach = reach or 12\n\tlocal dropped = 0\n", "\treach = reach or 12\n\tlocal dropped = 0\n\tif reach then return 0 end\n")]}),
    ("a car park's sign stood in the middle of its way in", "lot_unconnected",
     {"ParkingLots": [("local signAt = (base * CFrame.new(aisleX + signSide * (AISLE / 2 + 1.6), 0.5, -depth / 2 + KERB / 2)).Position",
                       "local signAt = (base * CFrame.new(aisleX, 0.5, -depth / 2 + KERB / 2)).Position")]}),
    ("the street's kerb cap left off", "end_raw",
     {"MapDecor": [("\tif startSpec.closed then\n\t\tclose(true)\n\tend\n\tif endSpec.closed then\n\t\tclose(false)\n\tend",
                    "")]}),
]

PLANT_RUNS = [("TralalaTown", 1), ("RotRidge", 1)]


def main(argv):
    show = "--show" in argv
    if "--plant" in argv:
        clean = run_many([(m, s, None, False) for m, s in PLANT_RUNS])
        base = Counter()
        for res in clean:
            base.update(faults_of(Counter(res[3])))
        print("clean (%s): %s" % (", ".join("%s %d" % x for x in PLANT_RUNS),
                                   ", ".join("%s %d" % (k, v) for k, v in sorted(base.items()) if v) or "no faults"))
        jobs = []
        for name, rule, faults in PLANTS:
            for m, s in PLANT_RUNS:
                jobs.append((m, s, faults, False))
        results = run_many(jobs)
        failed = 0
        for k, (name, rule, faults) in enumerate(PLANTS):
            got = Counter()
            for res in results[k * len(PLANT_RUNS):(k + 1) * len(PLANT_RUNS)]:
                got.update(faults_of(Counter(res[3])))
            caught = got[rule] > base[rule]
            failed += 0 if caught else 1
            print("  plant %-58s %-26s %s (%d, clean %d)" % (name, rule, "CAUGHT" if caught else "MISSED", got[rule], base[rule]))
        print("planted faults caught: %d of %d" % (len(PLANTS) - failed, len(PLANTS)))
        return 1 if failed else 0
    maps = roads_map.map_ids()
    seeds = SEEDS
    if "--quick" in argv:
        maps, seeds = ["TralalaTown", "RotRidge"], (1,)
    if "--map" in argv:
        maps = [argv[argv.index("--map") + 1]]
    if "--seed" in argv:
        seeds = (int(argv[argv.index("--seed") + 1]),)
    results = run_many([(m, s, None, show) for m in maps for s in seeds])
    totals = report(results, show)
    return 1 if sum(totals.values()) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
