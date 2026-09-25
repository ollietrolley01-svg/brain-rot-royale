"""Shed loot: MapWilds' addShedLoot puts a small stash by the door of some outlying structures
(sheds, barns, ruins, watchtowers -- Oliver, 2026-09-24: "make loot spawn in some of the sheds/
structures that are spread around the map"). This checks placement, the share of structures that get
loot, rarity-table parity, the total loot delta and determinism.

    python tools/shed_loot_check.py .            the checks
    python tools/shed_loot_check.py . --plant    the planted faults; every one must be caught

Builds real maps with the REAL MapGenerator.Build (tools/foundation_world.World, the harness
foundation_check.py uses), then tools/shed_loot_measure.lua checks every loot/chest spot MapGenerator
returns against its owning shelter's own FootingSize / FootingBase / WorldPivot attributes (the footing
audit's own convention) for: on the floor, inside the walls, clear of the edges, and on the door side.
--ref reads the game modules as they were at a git revision, for the "before" totals.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from foundation_world import World, luau_to_lua, TOOLS, ROOT  # noqa: E402

MAPS_SEEDS = [("SahurSprings", 101), ("TralalaTown", 101), ("RotRidge", 202), ("BombardiroBay", 303)]
MAX_INCREASE = 0.15

PLANTS = [
    ("a shed item pushed through the door wall (inset flipped outward)",
     [("MapWilds", "centre.Position + along * (spec.halfZ - inset) + side", "centre.Position + along * (spec.halfZ + inset) + side")],
     "bounds", "SahurSprings", 101),
    # TralalaTown seed 1: its nearest wilds shelter to a town centre sits at ~178 studs, just inside
    # SHED_LOOT_KEEPOUT (190) -- the one map/seed in tools/shed_loot_check.py's own scan close enough
    # for the guard to matter, so dropping it here actually lets that shelter roll shed loot ("never
    # in the lobby or a spawn" -- the nearest thing this map has to one is a town's own reach).
    ("the town keepout dropped: shed loot can land inside a town's own reach",
     [("MapWilds", "if nearest < SHED_LOOT_KEEPOUT or not chance(SHED_LOOT_CHANCE) then", "if not chance(SHED_LOOT_CHANCE) then")],
     "keepout", "TralalaTown", 1),
]


def measure(world, built, options=None):
    with open(os.path.join(TOOLS, "shed_loot_measure.lua"), encoding="utf-8") as f:
        source = luau_to_lua(f.read())
    fn = world.lua.execute("local source = ...; return assert(loadstring(source, '=shed_loot_measure'))", source)
    opts = world.lua.table_from(options or {})
    return fn(world.lua.eval("workspace.Map"), built, opts)


def run(map_id, seed, faults=(), ref=None):
    world = World(faults=faults, ref=ref)
    built = world.build(map_id, seed)
    result = measure(world, built)
    violations = [{"what": v["what"], "detail": v["detail"], "x": v["x"], "z": v["z"]} for v in result.violations.values()]
    return {
        "shelterCount": result.shelterCount, "withLoot": result.withLoot,
        "itemSpots": result.itemSpots, "chestSpots": result.chestSpots, "violations": violations,
    }


def total_loot(out):
    return out["itemSpots"] + out["chestSpots"]


def check_placement(args):
    failing = 0
    total_structures = total_with_loot = 0
    for map_id, seed in MAPS_SEEDS:
        out = run(map_id, seed)
        total_structures += out["shelterCount"]
        total_with_loot += out["withLoot"]
        bad = len(out["violations"])
        failing += bad
        print("%-14s seed %-4d shelters %3d  with loot %3d  item spots %3d  chest spots %2d  violations %d" % (
            map_id, seed, out["shelterCount"], out["withLoot"], out["itemSpots"], out["chestSpots"], bad))
        for v in out["violations"][:5]:
            print("    %-8s %s at (%.0f,%.0f)" % (v["what"], v["detail"], v["x"], v["z"]))
    print("structures with loot: %d / %d (%.0f%%)" % (total_with_loot, total_structures,
          100.0 * total_with_loot / total_structures if total_structures else 0))
    return failing


def check_delta(args):
    print("\ntotal map loot (weapon+heal+item spots, plus chests), before -> after:")
    failing = 0
    for map_id, seed in MAPS_SEEDS:
        before = total_loot(run(map_id, seed, ref="HEAD"))
        after = total_loot(run(map_id, seed))
        pct = (after - before) / before if before else 0
        ok = pct <= MAX_INCREASE
        failing += 0 if ok else 1
        print("  %-14s seed %-4d %4d -> %4d  (%+.1f%%)%s" % (map_id, seed, before, after, pct * 100, "" if ok else "  OVER 15%"))
    return failing


def check_determinism(args):
    map_id, seed = MAPS_SEEDS[0]
    a, b = run(map_id, seed), run(map_id, seed)
    same = (a["withLoot"], a["itemSpots"], a["chestSpots"]) == (b["withLoot"], b["itemSpots"], b["chestSpots"])
    print("\ndeterminism (%s seed %d, built twice): %s" % (map_id, seed, "ok" if same else "FAIL -- differs between runs"))
    return 0 if same else 1


def check_rarity_parity(args):
    """MapWilds only ever adds spot positions to the existing weapon/heal/item/chest lists; it must
    never touch a rarity table itself, and LootService's reroll must only redraw from the existing
    rollers -- see LootService.lua's bestOf / spawnGroundWeapon."""
    wilds_src = open(os.path.join(ROOT, "ServerScriptService", "Modules", "MapWilds.lua"), encoding="utf-8").read()
    loot_src = open(os.path.join(ROOT, "ServerScriptService", "Modules", "LootService.lua"), encoding="utf-8").read()
    problems = []
    if re.search(r"\bRarity\.", wilds_src):
        problems.append("MapWilds.lua references Rarity directly -- it must only add spot positions")
    if "bestOf(WeaponData.RollGroundWeapon" not in loot_src or "bestOf(ItemData.RollRecovery" not in loot_src:
        problems.append("LootService's reroll no longer calls the existing WeaponData/ItemData rollers")
    if re.search(r"Rarity\.\w+\s*=\s*", loot_src):
        problems.append("LootService.lua writes to Rarity -- a new tier would show up here")
    print("\nrarity-table parity: %s" % ("ok" if not problems else "FAIL"))
    for p in problems:
        print("  " + p)
    return len(problems)


def plant(args):
    failures = 0
    for label, faults, what, map_id, seed in PLANTS:
        clean = run(map_id, seed)
        planted = run(map_id, seed, faults=faults)

        def hits(out):
            return sum(1 for v in out["violations"] if v["what"] == what)
        before, after = hits(clean), hits(planted)
        ok = before == 0 and after > 0
        failures += 0 if ok else 1
        print("  %s  %-70s %s on %s: %d -> %d" % ("ok  " if ok else "FAIL", label, what, map_id, before, after))
    print("planted faults: %d of %d caught" % (len(PLANTS) - failures, len(PLANTS)))
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--plant", action="store_true")
    args = parser.parse_args()

    if args.plant:
        return 1 if plant(args) else 0

    failing = 0
    failing += check_placement(args)
    failing += check_delta(args)
    failing += check_determinism(args)
    failing += check_rarity_parity(args)
    print("\nTOTAL failing checks: %d" % failing)
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main())
