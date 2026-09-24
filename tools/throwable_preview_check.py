"""Checks for #63 (the throw preview lingering after a throw) and #69 (the Clingy Crumpet in hand
reading as a remote detonator).

Runs the real throwGate block out of StarterPlayerScripts/ProjectileClient.client.lua under lupa
through four throw timelines, and holds three source invariants that must stay true forever:
  - every use-remote send in ProjectileClient (a throw) tells throwGate it happened;
  - preview.update's hide condition consults throwGate;
  - the crumpet is built with no neon "Glow" (unlit in hand) and onStuck lights it via Arm.
Each check carries a planted fault that it must reject.

    python3 tools/throwable_preview_check.py [repo_root]
"""
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
CLIENT = (ROOT / "StarterPlayerScripts/ProjectileClient.client.lua").read_text()
MODELS = (ROOT / "ReplicatedStorage/Shared/ThrowableModels.lua").read_text()


def gate_source(text):
    match = re.search(r"-- BEGIN throwGate\n(.*?)-- END throwGate", text, re.S)
    assert match, "throwGate markers missing"
    return re.sub(r"(\w+) \+= ", r"\1 = \1 + ", match.group(1)) + "\nreturn throwGate\n"


# (name, loadout arrives after (s) or None for a refused throw, times that must be hidden,
#  times that must be drawn again). Stack of three, so the item is still in hand afterwards and
# only the gate can hide the preview.
TIMELINES = [
    ("fast ping", 0.05, [0.0, 0.1, 0.29], [0.31, 2.0]),
    ("normal ping", 0.15, [0.0, 0.14, 0.29], [0.31]),
    ("slow ping", 0.6, [0.0, 0.3, 0.59], [0.61]),
    ("refused (no loadout)", None, [0.0, 0.5, 0.99], [1.01]),
]


def run_timelines(source):
    failures, cases = [], 0
    for name, arrives, hidden, drawn in TIMELINES:
        lua = LuaRuntime(unpack_returned_tuples=True)
        gate = lua.execute(source)
        t0 = 1000.0
        if gate.Hidden(t0 - 5):
            failures.append(f"{name}: hidden before any throw")
        gate.Thrown(t0)
        events = sorted([(t, "check") for t in hidden + drawn] + ([(arrives, "arrive")] if arrives is not None else []))
        for t, kind in events:
            if kind == "arrive":
                gate.LoadoutArrived()
                continue
            cases += 1
            want = t in hidden
            if bool(gate.Hidden(t0 + t)) != want:
                failures.append(f"{name}: at +{t}s hidden={bool(gate.Hidden(t0 + t))}, want {want}")
    return failures, cases


def source_invariants(client, models):
    failures = []
    sends = len(re.findall(r"useRemote:FireServer\(", client))
    marks = len(re.findall(r"useRemote:FireServer\([^\n]*\)\n\s*throwGate\.Thrown\(", client))
    if sends == 0 or sends != marks:
        failures.append(f"{sends} throw sends, {marks} followed by throwGate.Thrown")
    update = re.search(r"function preview\.update\(\)(.*?)\n\t\t\thide\(\)", client, re.S)
    if not update or "throwGate.Hidden(" not in update.group(1):
        failures.append("preview.update's hide condition does not consult throwGate")
    crumpet = re.search(r"local function buildCrumpet\(.*?\n(.*?)\nend\n", models, re.S)
    glows = re.findall(r'b\.\w+\("Glow"[^\n]*', crumpet.group(1)) if crumpet else []
    if not glows or any("Neon" in line for line in glows):
        failures.append(f"crumpet Glow parts built lit ({len(glows)} examined)")
    stuck = re.search(r"local function onStuck\(info\)(.*?)\nend\n", client, re.S)
    if not stuck or "ThrowableModels.Arm(" not in stuck.group(1):
        failures.append("onStuck does not light the crumpet")
    return failures, sends, len(glows)


def main():
    ok = True
    source = gate_source(CLIENT)
    failures, cases = run_timelines(source)
    print(f"throwGate: {len(TIMELINES)} timelines, {cases} instants checked, {len(failures)} failures")
    for line in failures:
        print("  FAIL", line)
    ok &= not failures

    # Planted fault: a gate that never hides (the old behaviour) must fail the timelines.
    planted = source.replace("return since < HIDE_MIN or (waiting and since < HIDE_MAX)", "return false")
    assert planted != source
    caught, _ = run_timelines(planted)
    print(f"planted never-hide gate: {len(caught)} failures (must be > 0)")
    ok &= bool(caught)
    # Planted fault: a gate that waits forever for a loadout (a refused throw would blind it).
    planted = source.replace("(waiting and since < HIDE_MAX)", "waiting")
    caught, _ = run_timelines(planted)
    print(f"planted wait-forever gate: {len(caught)} failures (must be > 0)")
    ok &= bool(caught)

    failures, sends, glows = source_invariants(CLIENT, MODELS)
    print(f"source: {sends} throw sends, {glows} crumpet Glow parts examined, {len(failures)} failures")
    for line in failures:
        print("  FAIL", line)
    ok &= not failures

    # Planted faults: a new throw path without the gate; a crumpet built lit again.
    bad_client = CLIENT.replace("local function throwHeld()", "local function stray()\n\tuseRemote:FireServer(aimPoint())\nend\n\nlocal function throwHeld()", 1)
    bad_models = MODELS.replace('EMBER_DARK, Enum.Material.SmoothPlastic)', 'EMBER_DARK, Enum.Material.Neon)', 1)
    for label, client, models in (("ungated throw path", bad_client, MODELS), ("lit crumpet", CLIENT, bad_models)):
        caught, _, _ = source_invariants(client, models)
        print(f"planted {label}: {len(caught)} failures (must be > 0)")
        ok &= bool(caught)

    print("throwable preview check:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
