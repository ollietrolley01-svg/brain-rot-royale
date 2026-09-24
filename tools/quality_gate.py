"""One command for every offline check in the repo: the quality gate.

    python3 tools/quality_gate.py            run everything from the repo root, print one table
    python3 tools/quality_gate.py -j 8       more checks at once (default: CPU count)
    python3 tools/quality_gate.py -k vehicle only checks whose name contains "vehicle"
    python3 tools/quality_gate.py -v         also print the tail of every failing check's output
    python3 tools/quality_gate.py --timeout-scale 2   double every timeout (a machine shared with workers)

What it runs, found by FILENAME so a new harness joins the gate the moment it lands:
  - the three repo checks: tools/balance.py, tools/lua_static_check.py, tools/verify.py
  - every tools/*_check.py and tools/*_sim.py, and the few named in EXTRA_CHECKS
  - a second run with `--plant` for every harness whose source mentions "--plant" (the convention in
    this repo: `--plant` applies each planted fault in memory and exits non-zero if one is missed)

Each check runs as its own process from the repo root with `.` as its argument (argparse sims get no
positional), in parallel, each with a timeout. A check passes when it exits 0, except balance.py,
which always exits 0 and is judged on its "files unbalanced: 0" line.

The "planted" column is read from the check's own output. Harnesses print it in a few shapes
("3/4 caught", "planted faults caught: 3 of 4", one "CAUGHT"/"MISSED" line per plant); the parser
tries the summary shapes first and falls back to counting the per-plant lines. A dash means the
check prints no planted-fault result at all, which is itself worth knowing: a check with no plant has
never been shown to fail.

The gate never writes to the tree. Every harness here plants its faults in memory (or, for
plant_check.py, in a private copy), so running them side by side is safe. If you add a harness that
edits files in place, it does NOT belong in this gate until it stops doing that.

Exit status: 0 only if every check passed and every planted-fault run caught all its plants.
"""
import argparse
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")

REPO_CHECKS = ["balance.py", "lua_static_check.py", "verify.py"]

# Harnesses whose names don't follow the *_check.py / *_sim.py convention but that are checks all the same
# (they exit non-zero on a failure and run their own plants). Found by name they would never run.
EXTRA_CHECKS = ["bot_driving_combat.py"]

# Checks the gate knows about but does not run. Keep each reason honest: "slow" is not a reason,
# raise its timeout instead.
SKIP = {
    "plant_check.py": "a runner, not a check: it needs a plants.json argument and runs verify.py on a copy",
}

# Per-check timeouts in seconds, for the known-slow ones. Everything else gets DEFAULT_TIMEOUT. These
# are sized for a machine shared with other workers (load ~20 on 4 cores, 09-24: balance.py alone took
# 162 s); on a quiet machine the whole gate is a few minutes. `--timeout-scale` stretches them all.
TIMEOUTS = {
    "lua_static_check.py": 1200,
    "verify.py": 1200,
    "car_placement_check.py": 1800,
    "team_base_ruins_check.py": 1200,
    "vehicle_models_axis_check.py": 1200,
    "gun_tube_check.py": 1200,
    # --plant reruns the whole arsenal once per plant: 1183 s alone on a quiet machine after gun rework
    # batch 3 (65 guns), 1058 s before it.
    "fps_arms_check.py": 2400,
    "hud_layout_check.py": 1200,
    "vehicle_stability_sim.py": 900,
    "parked_car_check.py": 900,
    "killanim_check.py": 900,
    "menu_screens_check.py": 900,
}
DEFAULT_TIMEOUT = 600


def discover():
    names = list(REPO_CHECKS) + [name for name in EXTRA_CHECKS if os.path.exists(os.path.join(TOOLS, name))]
    for name in sorted(os.listdir(TOOLS)):
        if (name.endswith("_check.py") or name.endswith("_sim.py")) and name not in names:
            names.append(name)
    jobs, skipped = [], []
    for name in names:
        if name in SKIP:
            skipped.append((name, SKIP[name]))
            continue
        src = open(os.path.join(TOOLS, name), encoding="utf-8").read()
        argparse_only = "argparse" in src and "sys.argv[1]" not in src
        base = [sys.executable, os.path.join("tools", name)] + ([] if argparse_only else ["."])
        jobs.append((name, base, False))
        if '"--plant"' in src or "'--plant'" in src:
            jobs.append((name + " --plant", base + ["--plant"], True))
    return jobs, skipped


SUMMARY = [
    re.compile(r"(\d+)\s*/\s*(\d+)\s+(?:planted faults\s+)?caught", re.I),
    # Not across a bracket: "caught (botnav: only 0 of 76 cover spots ...)" is one plant's evidence,
    # not a summary, and read as one it turned team_battleground_check's 28/28 into 28/104.
    re.compile(r"caught[^\n\d(]{0,20}?(\d+)\s*(?:/|of)\s*(\d+)", re.I),
    re.compile(r"(\d+)\s+of\s+(\d+)\s+caught", re.I),
    re.compile(r"(\d+)\s*/\s*(\d+)\s+planted faults (?:fired|caught)", re.I),
]
HIT = re.compile(r"\b(caught|fired: True|planted fault fired)\b", re.I)
# Case-sensitive on purpose: "plants missed: 0" is a summary saying nothing was missed, while the
# per-plant verdicts are written in capitals.
MISS = re.compile(r"\bMISSED\b|NOT CAUGHT|fired: False|NOT PLANTED|DID NOT APPLY|PLANT ANCHOR MISSING|anchor (?:moved|missing)")


def planted(out):
    """(caught, total) from a check's output, or None when it reports no plants."""
    got = None
    for line in out.splitlines():
        for rx in SUMMARY:
            m = rx.search(line)
            if m:
                c, t = int(m.group(1)), int(m.group(2))
                got = (c + got[0], t + got[1]) if got else (c, t)
                break
    if got:
        return got
    hits = misses = 0
    for line in out.splitlines():
        if "plant" not in line.lower() and "fault" not in line.lower() and not MISS.search(line):
            continue
        if MISS.search(line):
            misses += 1
        elif HIT.search(line):
            hits += 1
    return (hits, hits + misses) if hits + misses else None


def judge(name, code, out):
    if name.startswith("balance.py"):
        m = re.search(r"files unbalanced:\s*(\d+)", out)
        return bool(m) and m.group(1) == "0"
    return code == 0


SCALE = 1.0


def run(job):
    name, cmd, is_plant = job
    timeout = int(TIMEOUTS.get(name.split()[0], DEFAULT_TIMEOUT) * SCALE)
    start = time.time()
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
        out, code = p.stdout + p.stderr, p.returncode
        ok = judge(name, code, out)
        why = "" if ok else "exit %d" % code
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or "") if isinstance(e.stdout, str) else (e.stdout or b"").decode("utf-8", "replace")
        ok, code, why = False, None, "timeout %ds" % timeout
    plants = planted(out)
    if ok and plants and plants[0] < plants[1]:
        ok, why = False, "missed %d plant(s)" % (plants[1] - plants[0])
    return {"name": name, "ok": ok, "why": why, "plants": plants, "secs": time.time() - start,
            "out": out, "plant_run": is_plant}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("-k", "--filter", default="")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--tail", type=int, default=15, help="output lines shown per failure with -v")
    ap.add_argument("--timeout-scale", type=float, default=1.0, help="multiply every timeout (a busy machine)")
    args = ap.parse_args()
    global SCALE
    SCALE = args.timeout_scale

    jobs, skipped = discover()
    jobs = [j for j in jobs if args.filter in j[0]]
    # Longest first, so the slow ones do not start last and set the wall time.
    jobs.sort(key=lambda j: -TIMEOUTS.get(j[0].split()[0], DEFAULT_TIMEOUT))
    t0 = time.time()
    results = []
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for fut in as_completed([pool.submit(run, j) for j in jobs]):
            r = fut.result()
            results.append(r)
            print("  %-4s %-44s %6.1fs" % ("ok" if r["ok"] else "FAIL", r["name"], r["secs"]), file=sys.stderr)

    results.sort(key=lambda r: (r["ok"], r["name"]))
    width = max([len(r["name"]) for r in results] + [5])
    print()
    print("%-*s  %-6s  %-9s  %8s  %s" % (width, "check", "result", "planted", "runtime", "note"))
    print("-" * (width + 40))
    for r in results:
        pl = "%d/%d" % r["plants"] if r["plants"] else "-"
        print("%-*s  %-6s  %-9s  %7.1fs  %s" % (width, r["name"], "pass" if r["ok"] else "FAIL", pl, r["secs"], r["why"]))
    for name, why in skipped:
        print("%-*s  %-6s  %-9s  %8s  %s" % (width, name, "skip", "-", "", why))
    fails = [r for r in results if not r["ok"]]
    caught = sum(r["plants"][0] for r in results if r["plants"])
    total = sum(r["plants"][1] for r in results if r["plants"])
    print("-" * (width + 40))
    print("%d checks, %d failed, %d skipped; planted faults %d/%d caught; wall %.0fs"
          % (len(results), len(fails), len(skipped), caught, total, time.time() - t0))
    if args.verbose:
        for r in fails:
            print("\n==== %s (%s) ====" % (r["name"], r["why"]))
            print("\n".join(r["out"].rstrip().splitlines()[-args.tail:]))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
