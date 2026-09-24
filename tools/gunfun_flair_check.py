"""Flair check: every gun's signature handling keeps the arms whole (the gun rework, 2026-09-24).

A gun's `Flair` (GunModelsSignature sets it; Viewmodel's FLAIR table plays it) adds three things to the
viewmodel: its own inspect, a flourish as it is drawn, and a flourish over the last stretch of a reload.
fps_arms_check poses every gun at the hip, aimed, and at three points of the reload and the rack; it never
poses an inspect or a draw, and its reload moments stop at 70%, before any flourish. This poses exactly
what it leaves out, through fps_arms_check's own harness (its mock, its measure, its judge), on its three
rigs:
  inspect   at 5% steps from 5% to 95%
  draw      at 20, 40, 60 and 80%
  reload    at 88, 91, 94 and 97%, full and empty (a flourish only lands on the clip's last stretch)
and holds every pose to the same limits: J1 joints meet, J2 bent elbows closed, J3 no bone stretched past
1.10, J4 no shoulder in view, J5 no wrist bent past 85 degrees.

Candidates are the guns whose built model carries a Flair; the count examined is printed next to the
count flagged. `--plant` runs the planted faults: a flair inspect that turns the gun until the wrist
breaks, and a reload flourish that does the same, each on the real Viewmodel source; both must be caught.

    python3 tools/gunfun_flair_check.py [repo]
    python3 tools/gunfun_flair_check.py [repo] --plant
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fps_arms_check  # noqa: E402
from gunfun_lab import Lab  # noqa: E402

MOMENTS = (
    [("inspect%02d" % int(p * 100), {"clip": "inspect", "progress": p}, 95) for p in [i / 20 for i in range(1, 20)]]
    + [("draw%02d" % int(p * 100), {"clip": "draw", "progress": p}, 95) for p in (0.2, 0.4, 0.6, 0.8)]
    + [("reload%02d" % int(p * 100), {"clip": "reload", "progress": p, "roundsLeft": 5}, 95) for p in (0.88, 0.91, 0.94, 0.97)]
    + [("reloadEmpty%02d" % int(p * 100), {"clip": "reload", "progress": p, "roundsLeft": 0}, 95) for p in (0.88, 0.94)]
)

# Each breaks the flair clips in the real Viewmodel source; the check must catch it.
PLANTS = [
    ("J5 a drum inspect turned until the wrist gives", "Viewmodel",
     "key(0.72, V(-0.12, 0.1, 0.04), V(8, 34, -26))", "key(0.72, V(-0.12, 0.1, 0.04), V(8, 160, -110))"),
    ("J5 a toss reload flourish flung past the wrist", "Viewmodel",
     "reload = { gun = { key(0.92, V(0, 0.05, 0), V(-14, 0, 0)) }", "reload = { gun = { key(0.92, V(0, 0.05, 0), V(-14, 140, -100)) }"),
]
PLANT_GUNS = {"J5 a drum inspect turned until the wrist gives": ["SahurPistol"],
              "J5 a toss reload flourish flung past the wrist": ["PocketPopper"]}


def flair_guns(repo):
    lab = Lab(repo)
    out = {}
    for gid in lab.ids():
        flair = lab.gun(gid)["attrs"].get("Flair")
        if flair:
            out[gid] = flair
    return out


def check(repo, src, ids):
    names = tuple(m[0] for m in MOMENTS)
    saved = fps_arms_check.WRISTED
    fps_arms_check.WRISTED = tuple(saved) + names
    try:
        return fps_arms_check.run(repo, src, moments=MOMENTS, only=ids)
    finally:
        fps_arms_check.WRISTED = saved


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    repo = args[0] if args else "."
    src = fps_arms_check.sources(repo)
    if "--plant" in argv:
        caught = 0
        for name, target, old, new in PLANTS:
            if old not in src[target]:
                print("PLANT %s: the text to break is not in %s any more" % (name, target))
                continue
            broken = dict(src)
            broken[target] = src[target].replace(old, new, 1)
            faults, examined, _ = check(repo, broken, PLANT_GUNS[name])
            hit = [f for f in faults if f.startswith("J5 ")]
            caught += bool(hit)
            print("%s %s: %d flags over %d poses%s" % ("CAUGHT" if hit else "MISSED", name, len(hit), examined,
                                                        (" (" + hit[0] + ")") if hit else ""))
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
        return 0 if caught == len(PLANTS) else 1
    guns = flair_guns(repo)
    faults, examined, count = check(repo, src, sorted(guns))
    for fault in faults:
        print(fault)
    kinds = sorted(set(guns.values()))
    print("flair check: %d flair guns (%d flairs: %s) x %d rigs x %d moments = %d poses examined, %d flagged" % (
        count, len(kinds), ", ".join(kinds), len(fps_arms_check.RIGS), len(MOMENTS), examined, len(faults)))
    return 1 if faults else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
