"""Run planted-fault tests against a PRIVATE COPY of the tree, never the shared one.

    python tools/plant_check.py plants.json [--root .]

`plants.json` is a list of plants:

    [
      {"label": "the cap literal coming back",
       "file": "ServerScriptService/Modules/DefenseService.lua",
       "old":  "local MAX_PER_PLAYER = ItemData.MaxStructuresPerPlayer",
       "new":  "local MAX_PER_PLAYER = 3"}
    ]

Each plant is applied to a throwaway copy, `verify.py` is run there, and the plant is reported
CAUGHT (verify went red) or MISSED (verify stayed green, so the check is worthless). The real tree is
never written to, so nothing can be observed broken by anyone else.

WHY THIS EXISTS, and it cost two other tabs an hour between them: planting a fault means deliberately
breaking a file, and `verify.py` is the gate EVERY tab runs. Doing it in place puts the shared tree in
a state that fails for everybody for as long as the plant is in, and the tab that runs verify in that
window has no way to know the red is someone else's experiment rather than their own landing. A
planted fault is a test of YOUR check; it is not an event the rest of the project should be able to
see.

The other half of the same rule: land a feature and its check in ONE operation. A check that arrives
first asserts something the tree does not do yet, which is the same red from a different direction.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

# Enough of the tree for verify.py to run; it reads Lua sources, the README and the root scripts.
COPY = ["ReplicatedStorage", "ServerScriptService", "StarterPlayerScripts", "StarterGui",
        "ServerStorage", "Workspace", "Lighting", "tools", "coordination"]
COPY_FILES = ["README.md", "COORDINATION.md", "OLIVER_LIST.md", "build_place.py"]


def copy_tree(root, into):
    for name in COPY:
        source = os.path.join(root, name)
        if os.path.isdir(source):
            shutil.copytree(source, os.path.join(into, name))
    for name in COPY_FILES:
        source = os.path.join(root, name)
        if os.path.isfile(source):
            shutil.copy2(source, os.path.join(into, name))


def run_verify(root):
    result = subprocess.run([sys.executable, os.path.join("tools", "verify.py"), "."],
                            capture_output=True, text=True, cwd=root)
    return result.stdout + result.stderr


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    plants_path = argv[0]
    root = "."
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    plants = json.load(open(plants_path, encoding="utf-8"))

    work = tempfile.mkdtemp(prefix="brr_plant_")
    try:
        copy_tree(root, work)
        baseline = run_verify(work)
        if "OK: no problems" not in baseline:
            print("the COPY is already red before any plant -- fix the tree first, not the plants:")
            print("\n".join(line for line in baseline.splitlines() if "OK:" not in line)[:600])
            return 1
        print("copy is green; planting %d fault(s)\n" % len(plants))

        failures = 0
        for plant in plants:
            target = os.path.join(work, plant["file"].replace("/", os.sep))
            original = open(target, encoding="utf-8").read()
            if original.count(plant["old"]) != 1:
                print("SKIPPED %s -- its anchor appears %d times, so the plant would be ambiguous"
                      % (plant.get("label", plant["file"]), original.count(plant["old"])))
                failures += 1
                continue
            open(target, "w", encoding="utf-8", newline="").write(original.replace(plant["old"], plant["new"]))
            out = run_verify(work)
            caught = "OK: no problems" not in out
            if not caught:
                failures += 1
            print(("CAUGHT  " if caught else "MISSED  ") + plant.get("label", plant["file"]))
            if caught:
                # The line about THIS plant, not merely the first line verify happened to print.
                # verify emits informational lines too, and showing one of those beside a CAUGHT
                # reads as the evidence when it is nothing of the kind.
                subject = os.path.splitext(os.path.basename(plant["file"]))[0]
                lines = [l.strip() for l in out.splitlines() if l.strip() and "OK:" not in l]
                line = next((l for l in lines if subject in l), None)
                print("        " + (line[:110] if line else
                      "(verify went red, but no line names %s -- check which problem this plant actually triggered)" % subject))
            open(target, "w", encoding="utf-8", newline="").write(original)

        print("\n%d plant(s), %d not caught" % (len(plants), failures))
        return 1 if failures else 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
