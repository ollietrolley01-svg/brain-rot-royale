"""Repro for critic finding C2 (tools/critic_findings.md): ModeTeams.bayOccupied asks
workspace:GetPartBoundsInBox, which matches a part by its WORLD-AXIS-ALIGNED bounding box. A compound
built at a yaw that is not a multiple of 90 degrees then "occupies" its own bays with walls, tyres,
drums and gate leaves that never touch them, and those bays are never parked.

Builds the real TeamBaseRuins.Layout (through tools/team_base_ruins_check.py's Build) at 10 yaws and, for
each bay, lists every CanCollide part whose world AABB meets ModeTeams' BAY_CLEAR box (read from
ModeTeams.lua) and whether its real box does too.

    python3 tools/critic_bay_aabb_repro.py [repo]     exit 1 while any bay is taken by an AABB-only hit
    python3 tools/critic_bay_aabb_repro.py [repo] --exact   the same, counting only real overlaps (the fix)

Until ModeTeams confirms each hit exactly (the fix in critic_findings.md C2), the first form fails; the
second must pass today (0 real overlaps), which is the invariant the fix relies on.
"""
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_base_ruins_check as T  # noqa: E402

YAWS = (0, 15, 30, 45, 60, 75, 90, 120, 135, 160)


def bay_clear(repo):
    text = (Path(repo) / "ServerScriptService/Modules/ModeTeams.lua").read_text()
    m = re.search(r"local BAY_CLEAR = Vector3\.new\(([\d.]+), ([\d.]+), ([\d.]+)\)", text)
    return tuple(float(v) for v in m.groups())


def box_of(centre, yaw, size):
    c, s = math.cos(yaw), math.sin(yaw)
    return centre, ((c, 0, -s), (0, 1, 0), (s, 0, c)), tuple(v / 2 for v in size)


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    exact_only = "--exact" in sys.argv
    size = bay_clear(repo)
    src = T.sources(repo)
    examined = taken = 0
    for deg in YAWS:
        b = T.Build(src)
        _, model, info = b.layout(0, 0, 0, math.radians(deg), (200, 60, 60), 1)
        parts = b.dump(model)
        bays = b.cfs(info["vehicleBays"])
        names = [info["names"]["bays"][i] for i in range(1, len(bays) + 1)]
        for name, bay in zip(names, bays):
            examined += 1
            yaw = math.atan2(bay[9], bay[11])  # LookVector = -back; atan2(-look.X, -look.Z)
            q = box_of((bay[0], bay[1] + 0.6 + size[1] / 2, bay[2]), yaw, size)
            hits = []
            for p in parts:
                if not p["collide"]:
                    continue
                lo, hi = T.aabb(p)
                centre = tuple((lo[i] + hi[i]) / 2 for i in range(3))
                half = tuple((hi[i] - lo[i]) / 2 for i in range(3))
                real = T.obb_overlap(q, T.obb(p))
                if real or (not exact_only and T.obb_overlap(q, (centre, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), half))):
                    hits.append(p["name"] + ("" if real else " (aabb only)"))
            if hits:
                taken += 1
                print("yaw %3d %s taken by: %s" % (deg, name, ", ".join(sorted(set(hits)))))
    print("critic_bay_aabb_repro: %d bay-yaw cases examined, %d taken%s" % (examined, taken,
                                                                          " (real overlaps only)" if exact_only else ""))
    sys.exit(1 if taken else 0)


if __name__ == "__main__":
    main()
