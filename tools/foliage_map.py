"""How evenly the foliage covers each map: the real MapGenerator.Build (tools/car_placement_map.py's
harness), then the foliage measured on a grid over the playable ground.

    python3 tools/foliage_map.py [--maps A,B] [--seeds 1,2,3] [--jobs 3] [--json out.json] [--fault NAME]

Foliage is every part of the wild scatter (Map/Wilds models whose names are in FOLIAGE below: woods,
single trees, clutter, ground cover, meadows, hedgerows, walls, orchards, long grass, reeds, the
fill) and MapDecor's props (Map/Props, less the sheds). Shelters are not foliage.

Per map and seed it reports:
  parts       every part in the map, and the foliage's share of them (the part budget, #121)
  coverage    of the ELIGIBLE 64x64 cells (inside 0.93 R, outside every town's edge + 40, and at
              least a quarter of their 16-stud samples on open ground: not a road's corridor, not
              water, not a flattened pad), the share holding at least one foliage clump (>= 2
              foliage parts rooted in the cell)
  largest bare the biggest 4-connected run of eligible cells with no clump, in cells (x 4096 sq studs)
  dispersion  variance / mean of foliage parts per eligible cell: 1 is random, lower is more even,
              much higher is clumped into a few places and bare elsewhere
  edge / bank coverage of the eligible cells in the outer ring (0.75..0.93 R) and within 60 studs of
              the river
  (fails)     coverage under --min-coverage (0.75) or a bare run over --max-bare (16) cells, on any map
  violations  foliage rooted where it must never be: in a road corridor, on a flattened pad (building
              lots, car parks, landmarks), in water, on any road / pavement / driveway / car park /
              bridge surface, or inside a town's edge. Must be 0.
  unclearable foliage parts near the team-base ring (ModeTeams: 0.64..0.72 of the arena radius round
              town 1, where TeamBaseRuins.ClearSite removes scenery up to 70 studs across) that
              belong to a model too big for ClearSite to remove -- it would be left standing inside
              a compound's walls.

A planted fault (--fault) must make the check fail; see FAULTS.
CAR_PLACEMENT_SOURCE=<dir> builds another copy of the source (the "before"), as car_placement_map does.
"""

import argparse
import json
import math
import os
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car_placement_map as cpm  # noqa: E402

CELL = 64
SAMPLE = 16
FOLIAGE = {"Woods", "Trees", "Clutter", "GroundCover", "Meadow", "Hedgerow", "StoneWall", "Orchard", "Grass",
           "Fill", "Reeds", "Copse", "Thicket", "Verge"}
SHED = {"Wall", "Roof", "Crate"}
SURFACES = {"Asphalt", "JunctionAsphalt", "Crossing", "RoadSurface", "BridgeRoad", "BridgeDeck", "Driveway",
            "DroppedKerb", "Layby", "Hardstanding", "Paving", "Cobbles", "Pavement", "Kerb"}
CLEARABLE = 70

# The raycast reports water over the river and the lakes, as the real terrain does (the plain harness
# calls everything Grass, which would let foliage stand in the river where the game's own ray vetoes it).
WATER_RAY = ("return { Position = Vector3.new(origin.X, y, origin.Z), Material = Enum.Material.Grass,",
             "local wet = (WORLD.river and mock.modules.MapTerrain.InRiver(WORLD.river, origin.X, origin.Z, 0))\n"
             "\t\tfor _, lake in ipairs(WORLD.lakes) do if (origin.X - lake.x) ^ 2 + (origin.Z - lake.z) ^ 2 < lake.radius ^ 2 then wet = true end end\n"
             "\t\treturn { Position = Vector3.new(origin.X, y, origin.Z), Material = wet and Enum.Material.Water or Enum.Material.Grass,")

# Appended to the harness's dump: the ground grid and the foliage's feet, tested with the real queries.
GRID_DUMP = r"""
local MapTerrain = require("MapTerrain")
local radius = map:GetAttribute("HarnessRadius")
local limit = radius * 0.93
local STEP = %d
for z = -radius, radius, STEP do
	local row = {}
	for x = -radius, radius, STEP do
		local c
		if x * x + z * z > limit * limit then
			c = "O"
		elseif roads:WithinCorridor(x, z) then
			c = "R"
		elseif WORLD.river and MapTerrain.InRiver(WORLD.river, x, z, 0) then
			c = "W"
		elseif MapTerrain.PadNear(x, z, 0) then
			c = "P"
		else
			c = "."
			for _, lake in ipairs(WORLD.lakes) do
				if (x - lake.x) ^ 2 + (z - lake.z) ^ 2 < lake.radius ^ 2 then c = "W" end
			end
		end
		table.insert(row, c)
	end
	table.insert(out, fmt("G|%%d|%%s", z, table.concat(row)))
end
-- Every foliage part that stands on the ground (its bottom within 2.5 studs of the ground under its
-- middle): where it is rooted, checked against the same queries.
local FOLIAGE = FOLIAGE_SET
local SHED = { Wall = true, Roof = true, Crate = true }
local function foliageModel(part)
	local node, top = part, nil
	while node.Parent and node.Parent ~= map do
		top = node
		node = node.Parent
	end
	if node.Name == "Wilds" and top and top ~= part then
		local prefix = top.Name:match("^(%%a+)")
		if FOLIAGE[prefix] then return top end
	elseif node.Name == "Props" and not SHED[part.Name] and not part.Name:match("^Lake") and not part.Name:match("^Dock")
		and part.Name ~= "Reed" then
		return node
	end
	return nil
end
table.insert(out, fmt("A|WildsParts|%%d", map:GetAttribute("WildsParts") or -1))
for _, part in ipairs(map:GetDescendants()) do
	if part:IsA("BasePart") then
		local item = foliageModel(part)
		if item then
			local p = part.Position
			local g = GROUND(p.X, p.Z)
			local bottom = p.Y - part.Size.Y / 2
			local low = bottom < g + 2.5
			local why = ""
			if low then
				if roads:WithinCorridor(p.X, p.Z) then why = "corridor"
				elseif WORLD.river and MapTerrain.InRiver(WORLD.river, p.X, p.Z, 0) then why = "river"
				elseif MapTerrain.PadAt(p.X, p.Z) then why = "pad" end
			end
			table.insert(out, fmt("L|%%s|%%s|%%.1f|%%.1f|%%d|%%s", item.Name, part.Name, p.X, p.Z, low and 1 or 0, why))
		end
	end
end
""" % SAMPLE

FAULTS = {
    # The fill's ground cover stops asking MapSpace and the roads: it lands on roads, lots and car parks,
    # which the violation count must catch.
    "fillopen": {"MapWilds": [("\t\t\t\t\tif not placed and open(x, z, 1.5) then", "\t\t\t\t\tif not placed then")]},
    # The roadside hedges stop asking the road's corridor (they already set its claim aside): hedges in the road.
    "verge": {"MapWilds": [("if clear and townFactor(p.X, p.Z) > 0.15 and not roads:WithinCorridor(p.X, p.Z)",
                            "if clear and townFactor(p.X, p.Z) > 0.15")]},
    # The whole even base layer is switched off: coverage must fall and the bare region grow.
    "nofill": {"MapWilds": [("local FILL_ENABLED = true", "local FILL_ENABLED = false")]},
}


_installed = {}


def install():
    if _installed:
        return
    _installed["done"] = True
    if WATER_RAY[0] not in cpm.WORLD:
        raise SystemExit("car_placement_map's raycast moved; update tools/foliage_map.py WATER_RAY")
    cpm.WORLD = cpm.WORLD.replace(WATER_RAY[0], WATER_RAY[1], 1)
    # And the river claims its channel and banks in MapSpace, as the real MapTerrain.River does (the plain
    # harness's stand-in doesn't, which let bank planting reach the water here and nowhere in the game).
    claim = "\tWORLD.river = river\n"
    assert claim in cpm.TERRAIN_TAIL
    cpm.TERRAIN_TAIL = cpm.TERRAIN_TAIL.replace(claim, claim + (
        "\tfor index = 1, #plan.points - 1 do space:AddStrip(plan.points[index], plan.points[index + 1], RIVER_WIDTH / 2 + 8) end\n"), 1)
    marker = 'return table.concat(out, "\\n")'
    assert marker in cpm.DUMP
    lua_set = "{ " + ", ".join("%s = true" % f for f in sorted(FOLIAGE)) + " }"
    cpm.DUMP = cpm.DUMP.replace(marker, GRID_DUMP.replace("FOLIAGE_SET", lua_set) + marker)
    _installed["dump"] = cpm.DUMP
    original = cpm.Map.__init__

    def init(self, map_id, seed, text, seconds, attrs):
        original(self, map_id, seed, text, seconds, attrs)
        self.grid, self.feet = {}, []
        for line in text.split("\n"):
            if line.startswith("G|"):
                _, z, row = line.split("|")
                self.grid[int(float(z))] = row
            elif line.startswith("A|"):
                self.attrs[line.split("|")[1]] = int(line.split("|")[2])
            elif line.startswith("L|"):
                f = line.split("|")
                self.feet.append((f[1], f[2], float(f[3]), float(f[4]), f[5] == "1", f[6]))
    cpm.Map.__init__ = init


def radius_of(map_id):
    import re
    text = cpm.source_of("MapData")
    block = text[text.index("\t%s = {" % map_id):]
    return int(re.search(r"radius = (\d+)", block).group(1))


def build(map_id, seed, faults):
    radius = radius_of(map_id)
    # The dump reads the radius from an attribute the harness sets on the map before dumping.
    cpm.DUMP = _installed["dump"].replace('map:GetAttribute("HarnessRadius")', str(radius))
    return cpm.build(map_id, seed, faults), radius


def in_rect(s, x, z, pad=0.0):
    dx, dz = x - s["x"], z - s["z"]
    u = dx * s["rx"] + dz * s["rz"]
    v = dx * s["lx"] + dz * s["lz"]
    return abs(u) <= s["sx"] / 2 + pad and abs(v) <= s["sz"] / 2 + pad


def analyse(m, radius):
    towns = m.towns
    limit = radius * 0.93

    def in_town(x, z, extra=40):
        return any(math.hypot(x - t["x"], z - t["z"]) < t["spread"] + extra for t in towns)

    # Ground samples, per 64-stud cell.
    n = int(2 * radius // CELL) + 2
    open_samples, all_samples = {}, {}
    for z, row in m.grid.items():
        for i, c in enumerate(row):
            x = -radius + i * SAMPLE
            if c == "O":
                continue
            key = (int((x + radius) // CELL), int((z + radius) // CELL))
            all_samples[key] = all_samples.get(key, 0) + 1
            if c == "." and not in_town(x, z):
                open_samples[key] = open_samples.get(key, 0) + 1
    eligible = {k for k, total in all_samples.items() if open_samples.get(k, 0) >= max(4, total * 0.25)}

    # Foliage parts per cell (rooted parts only: a canopy is counted with its trunk's cell), models' spans.
    per_cell, spans = {}, {}
    violations = {}
    surfaces = [s for s in m.surfaces if s["name"] in SURFACES]
    buckets = {}
    for s in surfaces:
        r = math.hypot(s["sx"], s["sz"]) / 2
        for bx in range(int((s["x"] - r) // 64), int((s["x"] + r) // 64) + 1):
            for bz in range(int((s["z"] - r) // 64), int((s["z"] + r) // 64) + 1):
                buckets.setdefault((bx, bz), []).append(s)
    foliage_parts = 0
    by_prefix = {}
    for item, name, x, z, low, why in m.feet:
        foliage_parts += 1
        prefix = item.split("_")[0]
        by_prefix[prefix] = by_prefix.get(prefix, 0) + 1
        lo_x, hi_x, lo_z, hi_z = spans.get(item, (x, x, z, z))
        spans[item] = (min(lo_x, x), max(hi_x, x), min(lo_z, z), max(hi_z, z))
        if not low:
            continue
        key = (int((x + radius) // CELL), int((z + radius) // CELL))
        per_cell[key] = per_cell.get(key, 0) + 1
        if not why:
            for s in buckets.get((int(x // 64), int(z // 64)), ()):
                if in_rect(s, x, z):
                    why = "surface:" + s["name"]
                    break
        if not why and in_town(x, z, 0):
            why = "town"
        if why:
            violations[why] = violations.get(why, 0) + 1
            if len(violations.get("_examples", [])) < 6:
                violations.setdefault("_examples", []).append("%s/%s at %.0f,%.0f (%s)" % (item, name, x, z, why))

    covered = {k for k in eligible if per_cell.get(k, 0) >= 2}
    bare = eligible - covered
    # Largest 4-connected bare region.
    seen, largest = set(), 0
    for start in bare:
        if start in seen:
            continue
        stack, size = [start], 0
        seen.add(start)
        while stack:
            cx, cz = stack.pop()
            size += 1
            for nb in ((cx + 1, cz), (cx - 1, cz), (cx, cz + 1), (cx, cz - 1)):
                if nb in bare and nb not in seen:
                    seen.add(nb)
                    stack.append(nb)
        largest = max(largest, size)
    counts = [per_cell.get(k, 0) for k in eligible]
    mean = sum(counts) / max(1, len(counts))
    var = sum((c - mean) ** 2 for c in counts) / max(1, len(counts))

    def centre(k):
        return (k[0] + 0.5) * CELL - radius, (k[1] + 0.5) * CELL - radius

    def share(sub):
        sub = [k for k in eligible if sub(*centre(k))]
        return (sum(1 for k in sub if k in covered) / len(sub)) if sub else None

    edge = share(lambda x, z: math.hypot(x, z) > radius * 0.75)
    river = None
    if m.river:
        pts = m.river["pts"]

        def near_river(x, z):
            for (ax, az), (bx, bz) in zip(pts, pts[1:]):
                abx, abz = bx - ax, bz - az
                ll = abx * abx + abz * abz
                t = max(0, min(1, ((x - ax) * abx + (z - az) * abz) / ll)) if ll else 0
                if math.hypot(ax + abx * t - x, az + abz * t - z) < m.river["width"] / 2 + 60:
                    return True
            return False
        river = share(near_river)

    # Team-base ring (ModeTeams): the arena is centred on town 1 (the first dropSpot, the centre town).
    arena = min(max(radius * 0.66, 600), 875)
    centre_town = min(towns, key=lambda t: math.hypot(t["x"], t["z"])) if towns else {"x": 0, "z": 0}
    unclearable = 0
    big = {item for item, (a, b, c, d) in spans.items() if max(b - a, d - c) > CLEARABLE - 20}
    for item, name, x, z, low, why in m.feet:
        if item in big:
            d = math.hypot(x - centre_town["x"], z - centre_town["z"])
            if arena * 0.64 - 60 < d < arena * 0.72 + 60:
                unclearable += 1

    return {
        "map": m.map_id, "seed": m.seed, "radius": radius,
        "parts": len(m.parts), "foliage": foliage_parts, "wilds": m.attrs.get("WildsParts"),
        "eligible": len(eligible), "coverage": round(len(covered) / max(1, len(eligible)), 3),
        "largest_bare": largest, "dispersion": round(var / mean, 2) if mean else None,
        "mean_per_cell": round(mean, 1),
        "edge": edge and round(edge, 3), "river": river and round(river, 3),
        "violations": violations, "unclearable": unclearable, "by_prefix": by_prefix,
        "wilds_failed": m.attrs.get("WildsFailed"),
        "seconds": round(m.seconds, 1),
    }


def job(args):
    map_id, seed, fault = args
    install()
    m, radius = build(map_id, seed, FAULTS.get(fault, {}) if fault else {})
    return analyse(m, radius)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--maps", default=",".join(cpm.map_ids()))
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--json")
    ap.add_argument("--fault")
    # The bar the spread must clear, per map and seed: before the change every map missed it
    # (coverage 0.45 to 0.68, bare runs up to 160 cells).
    ap.add_argument("--min-coverage", type=float, default=0.75)
    ap.add_argument("--max-bare", type=int, default=16)
    a = ap.parse_args()
    tasks = [(mp, int(s), a.fault) for mp in a.maps.split(",") for s in a.seeds.split(",")]
    with Pool(a.jobs) as pool:
        results = pool.map(job, tasks, chunksize=1)
    print("%-14s %4s %6s %6s %5s %6s %5s %5s %5s %5s %s" % ("map", "seed", "parts", "fol", "elig", "cover", "bare",
                                                          "disp", "edge", "river", "violations/unclearable"))
    bad = 0
    for r in results:
        v = {k: c for k, c in r["violations"].items() if k != "_examples"}
        bad += sum(v.values())
        if r["coverage"] < a.min_coverage or r["largest_bare"] > a.max_bare:
            bad += 1
            print("SPREAD FAIL: %s seed %d coverage %.3f (min %.2f), largest bare %d cells (max %d)" % (
                r["map"], r["seed"], r["coverage"], a.min_coverage, r["largest_bare"], a.max_bare))
        print("%-14s %4d %6d %6d %5d %6.3f %5d %5s %5s %5s %s / %d%s" % (
            r["map"], r["seed"], r["parts"], r["foliage"], r["eligible"], r["coverage"], r["largest_bare"],
            r["dispersion"], r["edge"], r["river"], v or 0, r["unclearable"],
            ("  FAILED " + r["wilds_failed"][:120]) if r["wilds_failed"] else ""))
        for ex in r["violations"].get("_examples", []):
            print("      ", ex)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(results, f, indent=1)
    print("failures: %d" % bad)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
