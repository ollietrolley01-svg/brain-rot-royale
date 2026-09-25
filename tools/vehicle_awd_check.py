"""All-wheel drive check (Oliver 09-25: "the cars need awd"), on a tools/vehicle_awd_probe.lua log.
    python tools/vehicle_awd_check.py <awd probe log> [--rough <vehicle_rough_terrain_probe log>]
    python tools/vehicle_awd_check.py <awd probe log> --plant     the planted faults; every one must be caught
Every car model (bikes and scooters stay rear-drive):
  * drives all four of its wheels;
  * 0 to 95% of top speed on the flat within DRAG_TOLERANCE of its time before AWD (AWD is for
    climbing and traction, not a faster car);
  * climbs at least the grade it climbed before AWD.
And the centre split itself (the REAL VehicleDynamics.DriveSplit, run in lupa): the rear axle in the air
gives the front all the drive, the front in the air gives it none, even weight gives FRONT_SPLIT, and
the front's share stays within 0..1 and never falls as the front takes more of the load.
With --rough, the rough-terrain course leaves no more runs unfinished than before AWD.
BEFORE is measured on the build before AWD (the same probe, 2026-09-25; the best climb of two runs).
"""
import os
import re
import sys

BEFORE = {  # model: (seconds 0 to 95% of top, steepest grade climbed)
    "Rotster": (3.21, 35), "CrocodiloRanger": (4.44, 55), "TralalaGT": (3.29, 40),
    "SahurVan": (11.22, 40), "TartarugaScout": (3.59, 50), "CameloCarrier": (12.03, 30),
}
BEFORE_ROUGH_UNFINISHED = 2   # SahurVan and TartarugaScout at 90%, stuck on the rocky climb at s 184-188
DRAG_TOLERANCE = 0.05
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def split_source():
    src = open(os.path.join(ROOT, "ReplicatedStorage", "Shared", "VehicleDynamics.lua"), encoding="utf-8").read()
    const = re.search(r"local FRONT_SPLIT = [\d.]+", src).group(0)
    start = src.index("function VehicleDynamics.DriveSplit(")
    end = src.index("\nend\n", start) + 5
    return const, src[start:end]


def split_problems(const, fn):
    """The REAL centre split in lupa: every problem with it."""
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    f, front_split = lua.execute("local VehicleDynamics = {}\n" + const + "\n" + fn + "\nreturn VehicleDynamics.DriveSplit, FRONT_SPLIT")
    found = []
    if f(100, 0) != 1:
        found.append("rear axle in the air: the front gets %.2f of the drive, not all of it" % f(100, 0))
    if f(0, 100) != 0:
        found.append("front axle in the air: the front still gets %.2f" % f(0, 100))
    if abs(f(100, 100) - front_split) > 1e-6:
        found.append("even weight: front share %.2f, not FRONT_SPLIT %.2f" % (f(100, 100), front_split))
    last = -1
    for front in range(0, 101, 5):
        share = f(front, 100 - front)
        if share < 0 or share > 1 or share < last - 1e-9:
            found.append("front share %.2f with %d%% of the load on the front (must stay 0..1 and never fall as the front loads)" % (share, front))
            break
        last = share
    return found


def problems(text, rough=None):
    found = split_problems(*split_source())
    rows = {m.group(1): (int(m.group(2)), int(m.group(3)), float(m.group(4)), int(m.group(5)))
            for m in re.finditer(r"\[AWD\] (\S+) driven=(\d+)/(\d+) drag=([-\d.]+) climb=(\d+)", text)}
    if "[AWD] done" not in text:
        found.append("the probe did not finish")
    for model, (drag0, climb0) in BEFORE.items():
        if model not in rows:
            found.append("%s: no result" % model)
            continue
        driven, wheels, drag, climb = rows[model]
        if wheels != 4 or driven != 4:
            found.append("%s: drives %d of %d wheels" % (model, driven, wheels))
        if drag <= 0 or abs(drag / drag0 - 1) > DRAG_TOLERANCE:
            found.append("%s: 0-95%% in %.2f s against %.2f before (more than %d%% off)" % (model, drag, drag0, DRAG_TOLERANCE * 100))
        if climb < climb0:
            found.append("%s: climbs %d deg against %d before" % (model, climb, climb0))
    if rough is not None:
        unfinished = [m.group(1) for m in re.finditer(r"\[ROUGH\] run (\S+ \d+) total finished=false", rough)
                      if not m.group(1).startswith(("CASE_", "FAULT_"))]
        harness = {m.group(1) for m in re.finditer(r"\[ROUGH\] HARNESS (\S+ \d+) ", rough)}
        real = [u for u in unfinished if u not in harness]
        if len(real) > BEFORE_ROUGH_UNFINISHED:
            found.append("rough course: %d runs unfinished against %d before (%s)" % (len(real), BEFORE_ROUGH_UNFINISHED, ", ".join(real)))
        print("rough course: %d unfinished (before AWD %d)" % (len(real), BEFORE_ROUGH_UNFINISHED))
    return found, rows


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if os.path.isdir(sys.argv[1]):
        print("%s: reads a Studio probe log (see the docstring); nothing to read in the offline gate" % os.path.basename(__file__))
        sys.exit(0)
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    if "--plant" in sys.argv:
        plants = {
            "a car left rear-drive": lambda t: t.replace("Rotster driven=4/4", "Rotster driven=2/4", 1),
            "AWD made a car 10% quicker": lambda t: re.sub(r"(TralalaGT driven=\d/\d drag=)([\d.]+)",
                                                         lambda m: m.group(1) + "%.2f" % (float(m.group(2)) * 0.9), t, 1),
            "a car climbs less": lambda t: re.sub(r"(CrocodiloRanger driven=\d/\d drag=[\d.]+ climb=)(\d+)",
                                                  lambda m: m.group(1) + str(int(m.group(2)) - 10), t, 1),
        }
        missed = 0
        for name, plant in plants.items():
            caught = problems(plant(text))[0]
            print("  planted %s: %s" % (name, "caught" if caught else "MISSED"))
            missed += 0 if caught else 1
        const, fn = split_source()
        capped = fn[:fn.index("\n") + 1] + "\treturn math.min(FRONT_SPLIT, frontLoad / math.max(frontLoad + rearLoad, 1e-9))\nend"
        caught = split_problems(const, capped)
        print("  planted the capped 40%% split (rear in the air loses drive): %s" % ("caught" if caught else "MISSED"))
        missed += 0 if caught else 1
        rough_plant ="[ROUGH] run SahurVan 90 total finished=false\n" * 3
        caught = problems(text, rough_plant)[0]
        print("  planted more rough runs unfinished: %s" % ("caught" if caught else "MISSED"))
        missed += 0 if caught else 1
        print("vehicle_awd_check --plant: %s" % ("all caught" if not missed else "%d MISSED" % missed))
        sys.exit(1 if missed else 0)
    rough = None
    if "--rough" in sys.argv:
        rough = open(sys.argv[sys.argv.index("--rough") + 1], encoding="utf-8", errors="replace").read()
    found, rows = problems(text, rough)
    for model, (driven, wheels, drag, climb) in sorted(rows.items()):
        before = BEFORE.get(model)
        print("%-16s driven %d/%d  0-95%% %5.2f s (was %5.2f)  climb %2d deg (was %2d)" % (
            model, driven, wheels, drag, before[0] if before else 0, climb, before[1] if before else 0))
    for f in found:
        print("FAIL " + f)
    print("vehicle_awd_check: %s" % ("PASS" if not found else "%d failure(s)" % len(found)))
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
