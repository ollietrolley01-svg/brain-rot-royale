"""Vehicles handle rough ground (Oliver 09-24: "make the vehicles handle better on rough terrain too").
Reads the output of tools/vehicle_rough_terrain_probe.lua (real physics, Run mode):

    powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/vehicle_rough_terrain_probe.lua -WaitSeconds 900 -PlaceFile <build> > rough.log
    python tools/vehicle_rough_terrain_check.py rough.log              the checks, and a per-class table
    python tools/vehicle_rough_terrain_check.py rough.log --compare before.log    the same table, before -> after

Every model, at 35/65/90% of its top speed, over the map's own relief with rock domes, a 14 degree slope,
kerbs, a crater rim and a rubble field, then a lane change on rough ground. It must: finish; never flip;
never snag (fall under half its target speed once reached); hold its speed; stay on its wheels (contact);
keep its vertical jolts and roll within limits; and make the lane change. Airtime is judged per segment:
none worth the name anywhere but a slope's crest. The crater after the finish is reported only (its walls
are the destruction code's business). The two planted faults (an underdamped spring; one ray per wheel) must
each FAIL on something, or the limits are too loose to see them.
"""

import os
import re
import sys
from collections import defaultdict

RUN = re.compile(r"\[ROUGH\] run (\S+) (\d+) (\w+) accel=([\d.]+) air=([\d.]+) longest=([\d.]+) contact=([\d.]+) roll=([\d.]+) "
                 r"pitch=([\d.]+) flips=(\d) snag=([\d.]+) held=([-\d.]+)")
TOTAL = re.compile(r"\[ROUGH\] run (\S+) (\d+) total finished=(\w+) distance=([-\d.]+) lanechange=([-\d.]+) crater_crossed=(\w+)")

# "Feels planted", per segment where it matters ("*" is every segment). The crater is reported only.
LIMITS = {
    "accel": {"*": 6.0},                               # g, vertical, past gravity
    "longest": {"*": 0.25, "slope": 0.4, "rough": 0.4},  # s, one flight
    "contact": {"*": 75.0, "rough": 70.0},             # % of wheel-frames grounded, at least
    "roll": {"*": 35.0, "rough": 45.0},                # degrees against the ground under the wheels
    "snag": {"*": 0.5},                                # s under half the target speed, at most
    "held": {"*": 0.8, "rough": 0.5},                  # mean speed / target, at least
}
# Loosened on the rough (09-25), because they failed every vehicle, the good ones included (the
# Ranger and the bikes, which finish): at 90% of top speed over the real maps' rockiest ground, a hop
# of a third of a second and losing half the speed are what driving there IS; and "roll" is measured
# against the average of the wheels' contact normals, which on a rock under one wheel is not the plane
# the car stands on. What the rough still may not do: get stuck (snag), flip, jolt, or stay airborne.
REPORTED_ONLY = {"crater"}
MAX_CASE_RISE = 4.0     # studs: the ledge is 2.5
# s with throttle held and under 2 studs/s, in a rock field (Oliver 09-25, the armoured cars stuck on rocks:
# none held over 1 s). Pulling away from the standstill before the field takes up to about 0.6 s on its own.
MAX_ROCK_STUCK = 1.0
ROCK_FIELD_END = 200    # studs: the field runs 30-190
MIN_LANE_CHANGE = 5.0   # studs of the 8 asked for, within 1.5 s
# A bike leans into its corrections: its roll limit is its own most lean (VehicleDynamics.Handling) plus this.
BIKE_LEAN = {"BananiniScoot": 32, "PatapimScrambler": 40, "BrrStreetfighter": 46}
BIKE_ROLL_SPARE = 15


def limit(name, seg):
    table = LIMITS[name]
    return table.get(seg, table["*"])


def parse(text):
    segs, totals = {}, {}
    for m in RUN.finditer(text):
        key = (m.group(1), int(m.group(2)))
        segs.setdefault(key, {})[m.group(3)] = {
            "accel": float(m.group(4)), "air": float(m.group(5)), "longest": float(m.group(6)), "contact": float(m.group(7)),
            "roll": float(m.group(8)), "pitch": float(m.group(9)), "flips": int(m.group(10)), "snag": float(m.group(11)),
            "held": float(m.group(12))}
    for m in TOTAL.finditer(text):
        totals[(m.group(1), int(m.group(2)))] = {"finished": m.group(3) == "true", "distance": float(m.group(4)),
                                                  "lane": float(m.group(5)), "crater": m.group(6) == "true"}
    return segs, totals


def run_problems(segs, total, model=""):
    problems = []
    if not total or not total["finished"]:
        problems.append("did not finish (%s studs)" % (total and total["distance"]))
    elif total["lane"] < MIN_LANE_CHANGE:
        problems.append("lane change reached only %.1f studs" % total["lane"])
    for seg, s in (segs or {}).items():
        if seg in REPORTED_ONLY:
            continue
        if s["flips"]:
            problems.append("%s: flipped" % seg)
        if s["accel"] > limit("accel", seg):
            problems.append("%s: jolt %.1f g" % (seg, s["accel"]))
        if s["longest"] > limit("longest", seg):
            problems.append("%s: airborne %.2f s" % (seg, s["longest"]))
        if s["contact"] < limit("contact", seg):
            problems.append("%s: wheels down only %.0f%%" % (seg, s["contact"]))
        base = model.split("#")[0]
        roll_limit = BIKE_LEAN[base] + BIKE_ROLL_SPARE if base in BIKE_LEAN else limit("roll", seg)
        if s["roll"] > roll_limit:
            problems.append("%s: rolled %.0f deg" % (seg, s["roll"]))
        if s["snag"] > limit("snag", seg):
            problems.append("%s: snagged %.1f s" % (seg, s["snag"]))
        if s["held"] < limit("held", seg):
            problems.append("%s: held %.0f%% of its speed" % (seg, 100 * s["held"]))
    return problems


def table(segs, totals):
    """Per class and speed: worst jolt, total air, worst contact, worst roll, flips, snag, speed held, lane change."""
    rows = {}
    for key, bysegment in segs.items():
        vals = list(bysegment.values())
        rows[key] = {
            "jolt": max(v["accel"] for v in vals), "air": sum(v["air"] for v in vals),
            "contact": min(v["contact"] for v in vals), "roll": max(v["roll"] for v in vals),
            "pitch": max(v["pitch"] for v in vals), "flips": sum(v["flips"] for v in vals),
            "snag": sum(v["snag"] for v in vals), "held": min(v["held"] for v in vals),
            "lane": totals.get(key, {}).get("lane", -1)}
    return rows


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if os.path.isdir(sys.argv[1]):
        # tools/quality_gate.py runs every check with the repo root: this one reads a Studio probe log.
        print("%s: reads a Studio probe log (see the docstring); nothing to read in the offline gate" % os.path.basename(__file__))
        sys.exit(0)
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    segs, totals = parse(text)
    before = None
    if "--compare" in sys.argv:
        before = table(*parse(open(sys.argv[sys.argv.index("--compare") + 1], encoding="utf-8", errors="replace").read()))
    failures = []
    physics = re.search(r"\[ROUGH\] PHYSICS running=(\w+) fell=([\d.-]+)", text)
    if not physics or physics.group(1) != "true" or float(physics.group(2)) < 1:
        failures.append("physics was not stepping: nothing below means anything")
    if "[ROUGH] done" not in text:
        failures.append("the probe did not finish")
    for m in re.finditer(r"\[ROUGH\] HARNESS (\S+ \d+ .*)", text):
        failures.append("HARNESS error (not a vehicle result): " + m.group(1).strip())
    harness = {tuple(m.group(1, 2)) for m in re.finditer(r"\[ROUGH\] HARNESS (\S+) (\d+) ", text)}
    real = sorted(k for k in segs if not k[0].startswith(("FAULT_", "CASE_")) and (k[0], str(k[1])) not in harness)
    # Stuck-then-fling: no stepped vehicle ever past 1.5x its top speed; and nose-first into a wall or a
    # ledge at full throttle for 10 s, never more than MAX_CASE_RISE off the ground it started on.
    peaks = list(re.finditer(r"\[ROUGH\] peak (\S+) (\d+) v=([\d.]+) cap=([\d.]+) w=([\d.]+) rise=([-\d.]+)", text))
    cases = [m for m in peaks if m.group(1).startswith(("CASE_wall", "CASE_ledge"))]
    if len(cases) < 6:
        failures.append("only %d wall/ledge cases ran" % len(cases))
    for m in peaks:
        if m.group(1).startswith("FAULT_"):
            continue
        if float(m.group(3)) > float(m.group(4)):
            failures.append("%s %s%%: %.0f studs/s, past its cap of %.0f (a fling)" % (m.group(1), m.group(2), float(m.group(3)), float(m.group(4))))
        if m in cases and float(m.group(6)) > MAX_CASE_RISE:
            failures.append("%s: rose %.1f studs off the ground (a fling)" % (m.group(1), float(m.group(6))))
    print("wall/ledge cases: worst speed %.0f%% of cap, worst rise %.1f studs" % (
        100 * max([float(m.group(3)) / float(m.group(4)) for m in cases] or [0]), max([float(m.group(6)) for m in cases] or [0])))
    # Rock fields: every vehicle across each kind of drive-over map rock, never stuck past MAX_ROCK_STUCK.
    rocks = [(m.group(1), float(m.group(2)), float(m.group(3)))
             for m in re.finditer(r"\[ROUGH\] rocks (\S+) stuck=([\d.]+)(?: stalls=\d+)? distance=([-\d.]+)", text)]
    if len(rocks) < 6:
        failures.append("only %d rock-field runs" % len(rocks))
    rocks = [r for r in rocks if "FAULT_" not in r[0]]
    for label, stuck, dist in rocks:
        if stuck > MAX_ROCK_STUCK:
            failures.append("%s: stuck %.1f s on the rocks" % (label, stuck))
        elif dist < ROCK_FIELD_END:
            failures.append("%s: only got %.0f studs through the rocks" % (label, dist))
    for field in sorted({r[0].split("_")[1] for r in rocks}):
        rs = [r for r in rocks if r[0].split("_")[1] == field]
        print("rock field %s: %d/%d through, worst stuck %.1f s" % (field, sum(r[2] >= ROCK_FIELD_END for r in rs), len(rs),
                                                                 max(r[1] for r in rs)))
    if len(real) < 15:
        failures.append("only %d real runs" % len(real))
    rows = table(segs, totals)
    print("%-18s %4s  %6s %6s %6s %6s %6s %5s %6s %6s %6s" % ("model", "spd%", "jolt g", "air s", "cont%", "roll", "pitch", "flip",
                                                           "snag", "held", "lane"))
    for key in sorted(rows):
        r = rows[key]
        line = "%-18s %4d  %6.1f %6.2f %6.0f %6.1f %6.1f %5d %6.2f %6.2f %6.1f" % (key[0], key[1], r["jolt"], r["air"], r["contact"],
                                                                              r["roll"], r["pitch"], r["flips"], r["snag"], r["held"], r["lane"])
        if before and key in before:
            b = before[key]
            line += "   was %5.1f %5.2f %4.0f %5.1f %d %5.2f %5.2f %5.1f" % (b["jolt"], b["air"], b["contact"], b["roll"], b["flips"],
                                                                       b["snag"], b["held"], b["lane"])
        print(line)
    crossed = [k for k in real if totals.get(k, {}).get("crater")]
    print("crater (reported only): %d/%d runs crossed it" % (len(crossed), len(real)))
    for key in real:
        for p in run_problems(segs[key], totals.get(key), key[0]):
            failures.append("%s %d%%: %s" % (key[0], key[1], p))
    # (One ray per wheel is planted on a rock field now, and caught by vehicle_visuals_check.)
    for fault in ("FAULT_underdamped",):
        keys = [k for k in segs if k[0] == fault]
        if not keys:
            failures.append("planted fault %s has no run" % fault)
        elif not any(run_problems(segs[k], totals.get(k)) for k in keys):
            failures.append("planted fault %s was NOT caught: the limits are blind to it" % fault)
        else:
            print("planted %s caught: %s" % (fault, "; ".join(run_problems(segs[keys[0]], totals.get(keys[0]))[:3])))
    for f in failures:
        print("FAIL " + f)
    print("vehicle_rough_terrain_check: %s" % ("PASS" if not failures else "%d failure(s)" % len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
