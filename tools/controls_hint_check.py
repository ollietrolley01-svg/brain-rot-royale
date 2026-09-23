"""Proves the remembered minimise state in StarterPlayerScripts/ControlsHint.client.lua (#90).

Runs the file's own PURE block (collapsedFor / storeFor) under lupa against a fake settings store that
starts from the defaults declared in StarterPlayerScripts/Settings.lua, and holds it to:
  1. a fresh profile: minimised on "handheld" and "upright", open on "desktop";
  2. whatever the player last chose on a device is what that device reads back (every start state,
     every sequence of up to 4 presses);
  3. a choice on one device class never changes what the other reads;
  4. every id storeFor writes is declared in Settings.lua with a boolean default.
Then applies three PERMANENT planted faults and requires each to be caught.

    python3 tools/controls_hint_check.py   -> exit 0 and "controls hint: ... 0 failures, 3/3 faults caught"
"""
import itertools
import pathlib
import re
import sys

from lupa import LuaRuntime

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "StarterPlayerScripts" / "ControlsHint.client.lua").read_text()
SETTINGS = (ROOT / "StarterPlayerScripts" / "Settings.lua").read_text()

FAULTS = {
    "phone reads the desktop flag": ('return phoneOpen ~= true', 'return desktopCollapsed == true'),
    "phone stores without inverting": ('return "ControlsHintPhoneOpen", not collapsed',
                                       'return "ControlsHintPhoneOpen", collapsed'),
    "both devices share one flag": ('return "ControlsHintPhoneOpen", not collapsed',
                                    'return "ControlsHintCollapsed", collapsed'),
}
MODES = ("desktop", "handheld", "upright")


def defaults():
    found = {}
    for ident, value in re.findall(r'id = "(ControlsHint\w*)".*?default = (true|false)', SETTINGS):
        found[ident] = value == "true"
    return found


def run(source):
    block = re.search(r"-- PURE BEGIN.*?\n(.*)-- PURE END", source, re.S).group(1)
    lua = LuaRuntime(unpack_returned_tuples=True)
    mod = lua.execute(block + "\nreturn { collapsedFor = collapsedFor, storeFor = storeFor }")
    declared = defaults()
    failures, cases = [], 0

    def read(store, mode):
        return mod.collapsedFor(mode, store.get("ControlsHintCollapsed"), store.get("ControlsHintPhoneOpen"))

    if "ControlsHint" not in declared or declared["ControlsHint"] is not False:
        failures.append("the legend is not declared off by default")
    fresh = dict(declared)
    for mode in MODES:
        cases += 1
        want = mode != "desktop"
        if read(fresh, mode) != want:
            failures.append(f"fresh profile on {mode}: minimised={read(fresh, mode)}, want {want}")

    for start in itertools.product([None, True, False], repeat=2):
        base = dict(declared)
        for ident, value in zip(("ControlsHintCollapsed", "ControlsHintPhoneOpen"), start):
            if value is not None:
                base[ident] = value
        for length in range(1, 5):
            for presses in itertools.product(MODES, [True, False], repeat=length):
                store = dict(base)
                before = {m: read(store, m) for m in MODES}
                last = {}
                for i in range(0, len(presses), 2):
                    mode, collapsed = presses[i], presses[i + 1]
                    ident, value = mod.storeFor(mode, collapsed)
                    if ident not in declared or not isinstance(value, bool):
                        failures.append(f"storeFor wrote undeclared or non-boolean {ident}={value}")
                        continue
                    store[ident] = value
                    last[mode == "desktop"] = collapsed
                for mode in MODES:
                    cases += 1
                    desk = mode == "desktop"
                    want = last[desk] if desk in last else before[mode]
                    if read(store, mode) != want:
                        failures.append(f"start {start} presses {presses}: {mode} reads {read(store, mode)}, want {want}")
    return cases, failures


def main():
    cases, failures = run(SOURCE)
    for line in failures[:10]:
        print("FAIL", line)
    caught = 0
    for name, (before, after) in FAULTS.items():
        if before not in SOURCE:
            print(f"FAULT TARGET MISSING: {name}")
            continue
        _, planted = run(SOURCE.replace(before, after))
        caught += bool(planted)
        print(f"planted fault '{name}': {'caught' if planted else 'NOT CAUGHT'} ({len(planted)} failures)")
    print(f"controls hint: {cases} cases, {len(failures)} failures, {caught}/{len(FAULTS)} faults caught")
    sys.exit(0 if not failures and caught == len(FAULTS) else 1)


if __name__ == "__main__":
    main()
