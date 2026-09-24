"""The gun rework's per-gun model gate: every existing model check, run on just the guns named.

    python3 tools/gunfun_check.py [repo] id [id ...]

Runs, on only those ids, the project's own checks through their own code (nothing re-implemented):
  tube   tools/gun_tube_check.check_gun  -- floating tubes, loose rods, doubled barrels
  arms   tools/fps_arms_check.run        -- J1-J5, C1, H1, H2, A1 on three rigs x seven moments
  body   tools/fps_arms_body_check.run   -- the third-person reload/aim pose, B1-B6
  sight  tools/gunfun_lab.sight_findings -- nothing solid on the sight line
It is the quick loop while building; the full-arsenal runs of the same tools (and their planted faults)
are the gate a commit has to pass.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fps_arms_body_check  # noqa: E402
import fps_arms_check  # noqa: E402
import gun_tube_check  # noqa: E402
from gunfun_lab import Lab, sight_findings  # noqa: E402


def main(argv):
    repo = argv[1] if len(argv) > 1 else "."
    ids = argv[2:]
    if not ids:
        print(__doc__)
        return 2
    bad = 0
    guns = gun_tube_check.build(gun_tube_check.load_sources(repo), ids)
    for gid in ids:
        parts = guns.get(gid)
        if isinstance(parts, str) or parts is None:
            print(f"tube  {gid}: BUILD FAILED {parts}")
            bad += 1
            continue
        for line in gun_tube_check.check_gun(parts):
            print(f"tube  {gid}: {line}")
            bad += 1
    src = fps_arms_check.sources(repo)
    faults, examined, _ = fps_arms_check.run(repo, src, only=ids)
    for fault in faults:
        print("arms  " + fault)
    bad += len(faults)
    print(f"arms: {examined} poses examined, {len(faults)} flagged")
    bsrc = fps_arms_body_check.sources(repo)
    bfaults, bexamined, _ = fps_arms_body_check.run(repo, bsrc, only=ids)
    for fault in bfaults:
        print("body  " + fault)
    bad += len(bfaults)
    print(f"body: {bexamined} moments examined, {len(bfaults)} flagged")
    lab = Lab(repo)
    for gid in ids:
        found, examined = sight_findings(lab.gun(gid))
        if found:
            print(f"sight {gid}: {found}")
            bad += 1
    print(f"gunfun_check: {len(ids)} guns, {bad} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
