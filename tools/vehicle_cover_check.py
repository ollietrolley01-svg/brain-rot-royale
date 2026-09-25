"""Cover for vehicle riders (Oliver, 2026-09-24: "make the cars provide more protection to the
player/bot as well").

Runs the REAL ReplicatedStorage/Shared/VehicleCover.lua and VehicleArmor.lua under lupa, the reference
rifle out of WeaponData (vehicle_ttk_check's loader), and prints the time a rider in every seat of every
vehicle takes to die to it from the front, side, rear and top, against the same rider on foot. Holds:

  NO IMMUNITY  every seat from every side takes at least 5% of a hit
  BIKE         a bike's rider and pillion: about as open as on foot (at most 1.25x the hits it takes on foot)
  CAR          a car's front seats: 1.5-4x the hits on foot from front / side / rear (cover, not a bunker)
  OPEN         a truck bed and a gunner's mount: at most 1.6x on foot
  ARMOUR       an armoured cabin at least twice a car cabin's time from every side; body > glass
  BLAST        a car cabin takes part of a blast, a bike all of it, an armoured cabin CabinBlast
  BOTS         a bot's rolled shot (Roll then Share) averages what a traced shot does (Expected)
  WIRING       CombatService (body and glass), BotService (the roll) and ProjectileService (blasts) all
               go through VehicleCover

    python tools/vehicle_cover_check.py [repo]           the table and the bands
    python tools/vehicle_cover_check.py [repo] --plant   also the planted faults
"""

import math
import random
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vehicle_ttk_check as ttkc  # noqa: E402

HEALTH = 100
DIRS = ("front", "side", "rear", "top")
COVER = "ReplicatedStorage/Shared/VehicleCover.lua"
COMBAT = "ServerScriptService/Modules/CombatService.lua"
BOTS = "ServerScriptService/Modules/BotService.lua"
BLASTS = "ServerScriptService/Modules/ProjectileService.lua"

# What each of the three damage paths must do, by source.
WIRING = [
    (COMBAT, r'VehicleCover\.Share\(modelId, seat\.Name, "body"\)', "CombatService: a shot through the body reaches the rider behind it at the body's share"),
    (COMBAT, r'local share = VehicleCover\.Share\(coverId, coverSeat\.Name, via\)', "CombatService: a direct hit on a rider takes the glass / open share"),
    (COMBAT, r'damage \*= share', "CombatService: the rider's share is applied to the damage"),
    (BOTS, r'local coverModel, coverSeat, coverId = VehicleCover\.SeatOf\(targetRoot\.Parent\)', "BotService: a bot's shot at a rider asks VehicleCover"),
    (BOTS, r'VehicleCover\.Share\(coverId, coverSeat\.Name, VehicleCover\.Roll\(', "BotService: a bot rolls body / glass / open"),
    (BLASTS, r'amount \*= VehicleCover\.BlastShareFor\(', "ProjectileService: a blast reaches a rider at their seat's share"),
]


def ride_ttk(g, scale, share):
    """Seconds of the rifle's fire (reloads counted, every shot landing) to kill a rider taking `share`."""
    if share <= 0:
        return math.inf
    return ttkc.ttk(HEALTH, g, scale, share)[0]


def measure(repo, sources=None, verbose=True):
    sources = sources or {}
    root = Path(repo)
    read = lambda rel: sources.get(rel) or (root / rel).read_text(encoding="utf-8")  # noqa: E731
    lua, armour, _data, _ball, scale, guns = ttkc.load(repo)
    cover = lua.execute(ttkc.luau(read(COVER)))
    problems = []
    rifle = guns[ttkc.REFERENCE_RIFLE]
    foot = ride_ttk(rifle, scale, 1)
    models = list(ttkc.CARS + ttkc.BIKES + ttkc.ARMOURED)

    def seats(model):
        entry = cover.Models[model]
        names = sorted(entry.seats.keys()) if entry else []
        # A bike carries no gun seat; any car or armoured car may (an armed variant's mount).
        return names + ([] if entry and entry["class"] == "bike" else ["GunnerSeat"])

    table = {}
    for model in models:
        for seat in seats(model):
            table[(model, seat)] = {d: cover.Expected(model, seat, d) for d in DIRS}

    if verbose:
        print(f"reference rifle {ttkc.REFERENCE_RIFLE}: on foot a {HEALTH}-health rider dies in {foot:.2f} s; "
              "each cell: seconds to kill a rider, and the hits it takes against on foot")
        print(f"{'vehicle':18} {'seat':15} " + " ".join(f"{d:>13}" for d in DIRS) + "   blast")
        for (model, seat), shares in table.items():
            cells = " ".join(f"{ride_ttk(rifle, scale, s):5.2f}s {1 / s:4.1f}x" for s in shares.values())
            print(f"{model:18} {seat:15} {cells}   {cover.BlastShare(model, seat):.2f}")

    # The bands hold the damage ratio (how many times the hits it takes on foot); the seconds above are
    # this rifle's, which round to whole shots.
    def ratio(model, seat, d):
        return 1 / table[(model, seat)][d]

    for (model, seat), shares in table.items():
        kind = cover.Models[model]["class"]
        _, profile = cover.Profile(model, seat)
        profile_name = next((k for k, v in cover.Seats.items() if v == profile), "?")
        for d, s in shares.items():
            if s < 0.05:
                problems.append(f"NO IMMUNITY {model} {seat} from the {d}: takes {s:.0%} of a hit")
        if kind == "bike":
            for d in DIRS:
                if ratio(model, seat, d) > 1.25:
                    problems.append(f"BIKE {model} {seat} from the {d}: {ratio(model, seat, d):.2f}x on foot (want about 1x)")
            if cover.BlastShare(model, seat) < 1:
                problems.append(f"BLAST {model} {seat}: a bike's rider shielded from a blast")
        if profile_name == "CABIN":
            for d in ("front", "side", "rear"):
                if not 1.5 <= ratio(model, seat, d) <= 4:
                    problems.append(f"CAR {model} {seat} from the {d}: {ratio(model, seat, d):.2f}x on foot (want 1.5-4)")
            if not cover.BlastShare(model, seat) < 1:
                problems.append(f"BLAST {model} {seat}: a car cabin takes the whole blast")
        if profile_name in ("BED", "HATCH"):
            for d in DIRS:
                if ratio(model, seat, d) > 1.6:
                    problems.append(f"OPEN {model} {seat} from the {d}: {ratio(model, seat, d):.2f}x on foot (want at most 1.6)")
        if profile_name == "SEALED":
            for d in DIRS:
                car = 1 / cover.Expected("Rotster", "DriverSeat", d)
                if ratio(model, seat, d) < 2 * car:
                    problems.append(f"ARMOUR {model} {seat} from the {d}: {ratio(model, seat, d):.2f}x on foot, not twice a car's {car:.2f}x")
            if abs(cover.BlastShare(model, seat) - armour.CabinBlast) > 1e-9:
                problems.append(f"BLAST {model} {seat}: {cover.BlastShare(model, seat)} of a blast, not VehicleArmor.CabinBlast {armour.CabinBlast}")
        # BOTS: the roll, many times over, averages the expected share
        rng = random.Random(7)
        for d in DIRS:
            n = 4000
            mean = sum(cover.Share(model, seat, cover.Roll(model, seat, d, rng.random())) for _ in range(n)) / n
            if abs(mean - shares[d]) > 0.03:
                problems.append(f"BOTS {model} {seat} from the {d}: a bot's roll averages {mean:.2f} of a hit, a traced shot {shares[d]:.2f}")
    for name in ("car", "armored"):
        c = cover.Classes[name]
        if not c.body > c.glass:
            problems.append(f"ARMOUR class {name}: body {c.body} does not stop more than glass {c.glass}")
    if not cover.Classes.armored.body > cover.Classes.car.body:
        problems.append("ARMOUR an armoured body stops no more than a car's")
    for rel, pattern, label in WIRING:
        if not re.search(pattern, read(rel)):
            problems.append(f"WIRING {label} -- not found in {rel}")
    return problems


PLANTS = [
    ("player path: cover not applied", COMBAT, "local share = VehicleCover.Share(coverId, coverSeat.Name, via)", "local share = 1", "WIRING"),
    ("cover at 100%", COVER, "car = { body = 0.8, glass = 0.35 },", "car = { body = 1, glass = 1 },", "NO IMMUNITY"),
    ("bot path ignores cover", BOTS, "local coverModel, coverSeat, coverId = VehicleCover.SeatOf(targetRoot.Parent)", "local coverModel, coverSeat, coverId = nil", "WIRING"),
    ("bot roll mislabels glass as open", COVER, 'elseif r < side.body + side.glass then\n\t\treturn "glass"', 'elseif r < side.body + side.glass then\n\t\treturn "open"', "BOTS"),
    ("bikes made fortresses", COVER, "bike = { body = 0.5, glass = 0 },", "bike = { body = 0.95, glass = 0 },", "BIKE"),
    ("armour no better than a car", COVER, "armored = { body = 0.92, glass = 0.8 },", "armored = { body = 0.8, glass = 0.35 },", "ARMOUR"),
    ("blasts ignore cover", BLASTS, "amount *= VehicleCover.BlastShareFor(victim.root.Parent)", "amount *= 1", "WIRING"),
]


def main(argv):
    repo = argv[1] if len(argv) > 1 and not argv[1].startswith("--") else "."
    problems = measure(repo)
    for p in problems:
        print("PROBLEM " + p)
    failed = bool(problems)
    if "--plant" in argv:
        caught = 0
        for label, rel, old, new, tag in PLANTS:
            source = (Path(repo) / rel).read_text(encoding="utf-8")
            if source.count(old) != 1:
                print(f"plant [{label}]: PLANT ANCHOR MISSING")
                failed = True
                continue
            found = [p for p in measure(repo, {rel: source.replace(old, new)}, verbose=False) if p.startswith(tag)]
            print(f"plant [{label}]: {'CAUGHT -- ' + found[0] if found else 'MISSED'}")
            caught += bool(found)
        print(f"vehicle_cover_check planted faults: {caught}/{len(PLANTS)} caught")
        failed |= caught < len(PLANTS)
    print(f"vehicle_cover_check: {len(problems)} problems")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
