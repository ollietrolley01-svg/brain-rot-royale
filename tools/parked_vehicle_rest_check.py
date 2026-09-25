"""Parked vehicles stay parked (Oliver 09-24: "the cars bounce around and are unstable until someone starts
driving them"). Reads the output of tools/parked_vehicle_rest_probe.lua, which measures with real physics:

    powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/parked_vehicle_rest_probe.lua -WaitSeconds 600 -PlaceFile <build> > rest.log
    python tools/parked_vehicle_rest_check.py rest.log            the checks
    python tools/parked_vehicle_rest_check.py rest.log --plant    also corrupts the log's numbers; each must be caught

Asserts, for every empty vehicle (test lanes: flat, slopes, a paved and marked bay, a base-yard bay; and
every vehicle the real map parks), over 60 s of stepped physics with nobody near: drift under 0.05 studs
and 0.5 degrees, no vertical bounce, and its physics pinned to the server. Then: a bot
that sits in drives off with no lurch, and a blast and a ram each move a resting car. The probe's two
planted faults (the rest hold switched off; the base-yard start with the ownership retry and guard off)
must each FAIL, or the check can't see what it claims to.
"""

import os
import re
import sys

MAX_DRIFT = 0.05
MAX_ANGLE = 0.5
MAX_LURCH = 1.5        # studs/s in the second after sitting, before any throttle
MIN_DROVE = 10.0       # studs in 2 s at full throttle
MIN_BLAST = 2.0
MIN_RAM = 1.0

ROW = re.compile(r"\[REST\] row (\S+) drift=([\d.]+) angle=([\d.]+) maxV=([\d.]+) maxW=([\d.]+) bounces=(\d+) pinned=(\w+) owner=(\S+)")


def row_problems(r):
    problems = []
    if r["drift"] >= MAX_DRIFT:
        problems.append("drift %.3f studs" % r["drift"])
    if r["angle"] >= MAX_ANGLE:
        problems.append("turned %.2f deg" % r["angle"])
    if r["bounces"] > 0:
        problems.append("%d bounces" % r["bounces"])
    if not r["pinned"]:
        problems.append("its physics was never pinned to the server")
    if r["owner"] != "server":
        problems.append("owned by " + r["owner"])
    return problems


def parse(text):
    rows = []
    for m in ROW.finditer(text):
        rows.append({"name": m.group(1), "drift": float(m.group(2)), "angle": float(m.group(3)), "maxV": float(m.group(4)),
                     "maxW": float(m.group(5)), "bounces": int(m.group(6)), "pinned": m.group(7) == "true", "owner": m.group(8)})
    wake = {}
    for m in re.finditer(r"\[REST\] wake (\w+) (.*)", text):
        wake[m.group(1)] = {k: v for k, v in re.findall(r"(\w+)=(\S+)", m.group(2))}
    physics = re.search(r"\[REST\] PHYSICS running=(\w+) fell=([\d.-]+)", text)
    return rows, wake, physics


def check(text, quiet=False):
    say = (lambda *a: None) if quiet else print
    failures = []
    rows, wake, physics = parse(text)
    if not physics or physics.group(1) != "true" or float(physics.group(2)) < 1:
        failures.append("physics was not stepping (a falling part did not fall): nothing below means anything")
    if "[REST] done" not in text:
        failures.append("the probe did not finish")
    real = [r for r in rows if not r["name"].startswith("FAULT_")]
    if len(real) < 20:
        failures.append("only %d real rows" % len(real))
    if not any(r["name"].startswith("map:") for r in real):
        failures.append("no map-parked vehicles measured")
    worst = {"drift": 0, "angle": 0}
    for r in real:
        worst["drift"] = max(worst["drift"], r["drift"])
        worst["angle"] = max(worst["angle"], r["angle"])
        problems = row_problems(r)
        if problems:
            failures.append("%s: %s" % (r["name"], ", ".join(problems)))
    say("rest: %d empty vehicles, worst drift %.4f studs, worst turn %.4f deg" % (len(real), worst["drift"], worst["angle"]))
    for fault in ("FAULT_nohold", "FAULT_owner"):
        mine = [r for r in rows if r["name"].startswith(fault + ":")]
        caught = [r for r in mine if row_problems(r)]
        if not mine:
            failures.append("planted fault %s has no rows" % fault)
        elif not caught:
            failures.append("planted fault %s was NOT caught: the check is blind to it" % fault)
        else:
            say("planted %s caught on %d/%d vehicles" % (fault, len(caught), len(mine)))
    drive = wake.get("drive")
    if not drive or drive.get("sat") != "true":
        failures.append("wake: the bot never sat in the resting car")
    else:
        if float(drive["lurch"]) > MAX_LURCH:
            failures.append("wake: lurched at %s studs/s on sitting" % drive["lurch"])
        if float(drive["drove"]) < MIN_DROVE:
            failures.append("wake: drove only %s studs in 2 s" % drive["drove"])
        say("wake drive: lurch %s studs/s, drove %s studs" % (drive["lurch"], drive["drove"]))
    for name, least in (("blast", MIN_BLAST), ("ram", MIN_RAM)):
        w = wake.get(name)
        if not w or float(w.get("moved", 0)) < least:
            failures.append("wake: a %s moved the resting car only %s studs" % (name, w and w.get("moved")))
        else:
            say("wake %s: moved %s studs" % (name, w["moved"]))
    return failures


def plant(text):
    """Each corruption must turn a passing log into a failing one."""
    real_row = next((m for m in ROW.finditer(text) if not m.group(1).startswith("FAULT_")), None)
    if not real_row:
        return ["no real row to plant into"]
    line = real_row.group(0)
    plants = {
        "drift": line.replace("drift=" + real_row.group(2), "drift=0.3000"),
        "bounce": line.replace("bounces=" + real_row.group(6), "bounces=4"),
        "owner": line.replace("pinned=" + real_row.group(7), "pinned=false"),
    }
    missed = []
    for name, bad in plants.items():
        if not check(text.replace(line, bad, 1), quiet=True):
            missed.append(name)
    for name, pattern, bad in (("lurch", r"lurch=[\d.]+", "lurch=9.000"), ("ram", r"ram moved=[\d.]+", "ram moved=0.00")):
        if not check(re.sub(pattern, bad, text, count=1), quiet=True):
            missed.append(name)
    return ["plant %s was not caught" % m for m in missed]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if os.path.isdir(sys.argv[1]):
        # tools/quality_gate.py runs every check with the repo root: this one reads a Studio probe log.
        print("%s: reads a Studio probe log (see the docstring); nothing to read in the offline gate" % os.path.basename(__file__))
        sys.exit(0)
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    failures = check(text)
    if "--plant" in sys.argv:
        failures += plant(text)
    for f in failures:
        print("FAIL " + f)
    print("parked_vehicle_rest_check: %s" % ("PASS" if not failures else "%d failure(s)" % len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
