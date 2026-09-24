"""Floating foundations and poor placement, measured on whole generated maps (Oliver, 2026-09-24:
"look for floating building foundations and poor placement").

    python3 tools/foundation_check.py                  every map x SEEDS; exit 1 on any violation
    python3 tools/foundation_check.py --maps RotRidge --seeds 7 --verbose
    python3 tools/foundation_check.py --ref ecec2d2    the same measure over the game code at a revision
                                                       (the "before" numbers)
    python3 tools/foundation_check.py --propose        with the proposed edits to files this worker does
                                                       not own applied (PROPOSED below), to show them work
    python3 tools/foundation_check.py --plant          plant each fault below and show the check catches it
    python3 tools/foundation_check.py --json out.json  every violation, for tools/foundation_gallery.lua

tools/foundation_world.py builds each map with the REAL MapGenerator.Build (towns, TownThemes, landmarks,
easter eggs, MapWilds, roads, bridges, river, ziplines) on a voxel terrain that behaves as the map code
was measured to behave in Studio; tools/foundation_measure.lua then measures every structure on it:
floating, buried, door sill, door clearance, facing, overlap, water, trees. See those files for what
each number means.

What this cannot show: the picture. Roblox's own math.noise is not published, so a seed here is not the
same map as that seed in Studio; the terrain surface between voxel columns is modelled two ways and a
gap only counts if both see it. tools/foundation_gallery.lua photographs the worst sites in Studio.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from foundation_world import World, luau_to_lua, TOOLS  # noqa: E402

MAPS = ["SahurSprings", "TralalaTown", "BombardiroBay", "RotRidge", "PatapimPlains"]
SEEDS = [101, 202, 303]

# Structures built by modules outside this check's owner that fail the run only with --strict. Empty:
# the MapDecor shed edit once proposed here landed in 22b6f77, and sheds count like everything else.
ELSEWHERE = {}
PROPOSED = []

# Planted faults, each aimed at an invariant the placement code must keep forever, not at a bug that
# was fixed: (label, [(module, old, new)], map, seed, what, kind prefix). The check must find at least
# one violation of `what` on a `kind` structure with the fault in, where the unplanted build has none.
PLANTS = [
    ("a town building's skirt reaches the ground: built 3.2 over its pad",
     [("MapGenerator", "buildBuilding(town, Vector3.new(lot.X, 0, lot.Z)", "buildBuilding(town, Vector3.new(lot.X, 3.2, lot.Z)")],
     "TralalaTown", 101, "floating", "town:"),
    ("the ground never rises over a floor: buildings sunk 1.2 into their pads",
     [("MapGenerator", "buildBuilding(town, Vector3.new(lot.X, 0, lot.Z)", "buildBuilding(town, Vector3.new(lot.X, -1.2, lot.Z)")],
     "TralalaTown", 101, "buried", "town:"),
    ("a door opens onto its street: every building turned round",
     [("MapGenerator", "chestSpots, lootSpots, plan, yaw)", "chestSpots, lootSpots, plan, yaw + math.pi)")],
     "TralalaTown", 101, "facing", "town:"),
    ("nothing overlaps: the lot's free-space check skipped",
     [("MapGenerator", "if rectFree(space, claimCenter.X, claimCenter.Z, yaw, claimX, claimZ, street.entry) then", "if true then")],
     "TralalaTown", 101, "overlap", "town:"),
    ("nothing of a monument hangs over the ground: no underpinning",
     [("MapTerrain", "function MapTerrain.Underpin(model, base, options)\n", "function MapTerrain.Underpin(model, base, options)\n\tdo return 0 end\n")],
     "SahurSprings", 101, "floating", "landmark:"),
    ("a zipline's rim post stands on the rim: placed at the plateau's middle height",
     [("MapTerrain", "\t\twhile inset < size * 0.5 and groundHeightAt(rim.X, rim.Z) < height - 0.3 do", "\t\twhile false do"),
      ("MapTerrain", "\t\trim = Vector3.new(rim.X, groundHeightAt(rim.X, rim.Z), rim.Z)", "\t\trim = Vector3.new(rim.X, height, rim.Z)")],
     "SahurSprings", 202, "floating", "zipline:"),
    ("a shelter's opening looks out on open ground: the door rule off",
     [("MapWilds", "local DOOR_RISE, DOOR_DROP, DOOR_REACH = 1.5, 2.5, 5", "local DOOR_RISE, DOOR_DROP, DOOR_REACH = 99, 99, 5")],
     "RotRidge", 202, "door", "wilds:"),
    ("trees and shelters keep off what is built: the wilds ignore every claim",
     [("MapWilds", "\t\treturn space:IsFree(x, z, reach, ignore)\n", "\t\treturn true\n")],
     "SahurSprings", 101, "tree", ""),
    ("a set piece's entrance stays clear of street furniture: the entrance check off",
     [("TownThemes", "local function entranceClear(ctx, at, front, halfDepth, reach)\n", "local function entranceClear(ctx, at, front, halfDepth, reach)\n\tdo return true end\n")],
     # Seed 1: on seed 2 no set-piece candidate's entrance meets street furniture any more (0 -> 0 with
     # the check off, already so at 38f0551), so the plant could not bite there. Seed 1: 0 -> 1.
     "BombardiroBay", 1, "door", "theme:setpiece"),
    ("a shed's doorway faces downhill and clears the ground at it (critic C9): facing ignored",
     [("MapDecor", "\t\t\tif y and y < lowest then\n", "\t\t\tif false then\n")],
     "PatapimPlains", 303, "door", "decor:hut"),
    ("a front door's path to the pavement stays clear: the path not claimed",
     [("MapGenerator", "\t\t\t\tspace:AddStrip(doorstep, doorstep - sideVector * (setback + 0.5), MapBuildings.DoorWidth / 2 + 1)\n", "")],
     "SahurSprings", 101, "door", "town:"),
]


def measure(world, built, options=None):
    with open(os.path.join(TOOLS, "foundation_measure.lua"), encoding="utf-8") as f:
        source = luau_to_lua(f.read())
    fn = world.lua.execute("local source = ...; return assert(loadstring(source, '=foundation_measure'))", source)
    terrain_module = world.lua.eval('require(game:GetService("ServerScriptService").Modules.MapTerrain)')
    opts = world.lua.table_from(options or {})
    return fn(world.lua.eval("workspace.Map"), world.terrain, built, terrain_module, opts)


def to_py(world, result):
    out = {"violations": [], "summary": {}, "skipped": result.skipped, "trees": result.trees,
           "obstacles": result.obstacles, "carriageways": result.carriageways, "structures": 0,
           "mockGaps": [str(g) for g in world.mock.mockGaps.values()]}
    for v in result.violations.values():
        out["violations"].append({k: v[k] for k in ("kind", "name", "what", "value", "detail", "x", "z", "base")})
    for kind, e in result.summary.items():
        out["summary"][kind] = {k: e[k] for k in ("n", "maxGap", "maxBury", "maxSill", "minDoor")}
        out["structures"] += e["n"]
    return out


def run(map_id, seed, faults=(), options=None, ref=None):
    world = World(faults=faults, ref=ref)
    built = world.build(map_id, seed)
    result = measure(world, built, options)
    return to_py(world, result)


def tally(out):
    by_what = {}
    for v in out["violations"]:
        by_what.setdefault(v["what"], {}).setdefault(v["kind"], 0)
        by_what[v["what"]][v["kind"]] += 1
    return by_what


def counted(v, strict):
    """Whether a violation fails the run: everything, bar ELSEWHERE kinds unless strict."""
    return strict or v["kind"] not in ELSEWHERE


def plant(args):
    failures = 0
    for label, faults, map_id, seed, what, kind in PLANTS:
        clean = run(map_id, seed, faults=PROPOSED if args.propose else ())
        planted = run(map_id, seed, faults=list(faults) + (PROPOSED if args.propose else []))

        def hits(out):
            return sum(1 for v in out["violations"] if v["what"] == what and v["kind"].startswith(kind))
        before, after = hits(clean), hits(planted)
        ok = before == 0 and after > 0
        failures += 0 if ok else 1
        print("  %s  %-80s %s %d: %s on %s* %d -> %d" % ("ok  " if ok else "FAIL", label, map_id, seed, what, kind, before, after))
    print("planted faults: %d of %d caught" % (len(PLANTS) - failures, len(PLANTS)))
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--maps", nargs="*", default=MAPS)
    parser.add_argument("--seeds", nargs="*", type=int, default=SEEDS)
    parser.add_argument("--json")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--ref", help="measure the game modules as they are at this git revision")
    parser.add_argument("--propose", action="store_true", help="apply PROPOSED (edits for other owners' files)")
    parser.add_argument("--strict", action="store_true", help="fail on ELSEWHERE kinds too")
    parser.add_argument("--plant", action="store_true")
    args = parser.parse_args()

    if args.plant:
        return 1 if plant(args) else 0

    report = {}
    total, failing = 0, 0
    grand = {}
    for map_id in args.maps:
        for seed in args.seeds:
            started = time.time()
            out = run(map_id, seed, faults=PROPOSED if args.propose else (), ref=args.ref)
            report["%s/%d" % (map_id, seed)] = out
            total += len(out["violations"])
            failing += sum(1 for v in out["violations"] if counted(v, args.strict or args.propose))
            failing += len(out["mockGaps"])
            print("%s seed %d: %d structures, %d violations (%.0fs)%s" % (
                map_id, seed, out["structures"], len(out["violations"]), time.time() - started,
                ("  MOCK GAPS %d" % len(out["mockGaps"])) if out["mockGaps"] else ""))
            for what, kinds in sorted(tally(out).items()):
                print("    %-9s %s" % (what, ", ".join("%s %d" % kv for kv in sorted(kinds.items()))))
                for kind, n in kinds.items():
                    grand.setdefault(kind, {}).setdefault(what, 0)
                    grand[kind][what] += n
            for kind, e in out["summary"].items():
                grand.setdefault(kind, {})
                grand[kind]["_n"] = grand[kind].get("_n", 0) + e["n"]
            if args.verbose:
                for v in sorted(out["violations"], key=lambda v: (v["what"], v["kind"], -v["value"])):
                    print("      %-8s %-22s %-18s %7.2f  (%.0f,%.0f) base %.1f %s" % (
                        v["what"], v["kind"], v["name"], v["value"], v["x"], v["z"], v["base"], v["detail"]))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(report, f, indent=1)
    whats = ["floating", "buried", "sill", "door", "facing", "overlap", "water", "tree"]
    print("\nper structure type, all runs (examined, then violations of each kind):")
    print("  %-26s %6s " % ("type", "n") + " ".join("%8s" % w for w in whats))
    for kind in sorted(grand):
        row = grand[kind]
        print("  %-26s %6d " % (kind, row.get("_n", 0)) + " ".join("%8d" % row.get(w, 0) for w in whats))
    for kind, why in ELSEWHERE.items():
        n = sum(r.get(w, 0) for k, r in grand.items() if k == kind for w in whats)
        if n and not (args.strict or args.propose):
            print("NOT COUNTED (another owner's file): %d on %s -- %s" % (n, kind, why))
    print("TOTAL violations: %d, failing: %d" % (total, failing))
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main())
