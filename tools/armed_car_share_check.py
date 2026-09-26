"""Armed cars are a quarter of battle royale's parked cars, and nothing else changes (task 29).

    python tools/armed_car_share_check.py            the check, then its planted faults
    python tools/armed_car_share_check.py --no-maps  the Pick part only (seconds, not minutes)

Part 1 runs the real VehicleModels.Pick (the module's own source under lupa) 100,000 times per case:
  battle royale   Pick("car", rng, { drivable = true, armedShare = 0.25 }): armed (a turret in
                  VehicleModels.Mounts) within TOLERANCE of 25%, each model within TOLERANCE of its
                  scaled weight, and the armoured pair (drivableOnly) still the two rarest cars
  team bases      Pick("car", rng, { drivable = true }): each model within TOLERANCE of its written
                  weight, so armed stays at the old 81% (78 of 96)
  kerbside props  Pick("car", rng): the same against the props' weights, and never an armoured car
  bikes           Pick("bike", rng, { armedShare = 0.25 }): the written weights (no bike is armed)
and in every case exactly one rng roll a pick, so a map's later rolls don't shift.

Part 2 builds every map at SEEDS with the real MapGenerator.Build, ParkInTowns and Create's model
choice (tools/car_placement_map.py), logs every Pick call, and requires every drivable car pick to carry
armedShare 0.25 (the car parks and the verge alike) and every kerbside prop pick to carry none. It also
prints the armed share of the parked cars it built (a handful a map, so a count, not a tolerance).

Planted faults, each must go red:
  F1 the option leaks into the default pick (the brief's invariant: team bases and props unchanged)
  F2 a spare roll when the option is set (a map's later rolls would shift)
  F3 the armoured pair left out of the scaling (no longer the rarest)
  F4 ParkInTowns doesn't pass the option on (most battle royale cars come from the car parks)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from car_placement_luau import luau_to_lua  # noqa: E402
import car_placement_map as cpm  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PICKS = 100000
TOLERANCE = 0.01  # a share within one point; the standard error at 100,000 picks is under 0.16
TARGET = 0.25
SEEDS = (1, 2, 3)

PICK_HEAD = "function VehicleModels.Pick(kind, rng, opts)\n"
# Instrumentation for part 2: every Pick call says what it was asked for.
PICK_LOG = [(PICK_HEAD, PICK_HEAD + "\tPICK_LOG = PICK_LOG or {}\n\ttable.insert(PICK_LOG, kind .. \"|\" .. "
             "tostring(type(opts) == \"table\" and opts.drivable == true) .. \"|\" .. "
             "tostring(type(opts) == \"table\" and opts.armedShare or nil))\n")]

FAULTS = {
    "F1": {"VehicleModels": [("opts.armedShare or nil\n", "opts.armedShare or 0.25\n")]},
    "F2": {"VehicleModels": [("\tlocal roll = rng:NextNumber() * total\n",
                              "\tif share then rng:NextNumber() end\n\tlocal roll = rng:NextNumber() * total\n")]},
    "F3": {"VehicleModels": [("(VehicleModels.Mounts[id] and scale or 1)",
                              "(VehicleModels.Mounts[id] and not VehicleModels.Models[id].drivableOnly and scale or 1)")]},
    "F4": {"VehicleService": [("exact = true, armedShare = armedShare }", "exact = true }")]},
}

LOADER = """
local source = ...
local stub = setmetatable({}, { __index = function() return function() end end })
local folder = { WaitForChild = function(self) return self end }
game = { GetService = function() return folder end }
require = function() return stub end
return load(source, "=VehicleModels")()
"""

COUNTER = """
local VehicleModels, seed = ...
local state, rolls = seed, 0
local rng = { NextNumber = function()
	rolls = rolls + 1
	state = (state * 16807) % 2147483647
	return state / 2147483647
end }
return function(kind, opts, n)
	local counts = {}
	for _ = 1, n do
		local id = VehicleModels.Pick(kind, rng, opts)
		counts[id] = (counts[id] or 0) + 1
	end
	return counts, rolls
end
"""


def load_models(faults):
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(ROOT, "tools", "destruct_mocks.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    src = cpm.apply(cpm.source_of("VehicleModels"), faults.get("VehicleModels"), "VehicleModels")
    return lua, lua.execute(LOADER, luau_to_lua(src))


def pick_part(faults, say):
    lua, vm = load_models(faults)
    models = {}
    for id_, d in vm.Models.items():
        models[id_] = {"kind": d.kind, "weight": d.weight, "only": bool(d.drivableOnly), "armed": vm.Mounts[id_] is not None}
    run = lua.execute(COUNTER, vm, 12345)
    fails = []

    def case(name, kind, opts, drivable, share):
        pool = {i: m for i, m in models.items() if m["kind"] == kind and (drivable or not m["only"])}
        armed = sum(m["weight"] for m in pool.values() if m["armed"])
        plain = sum(m["weight"] for m in pool.values() if not m["armed"])
        scale = share * plain / ((1 - share) * armed) if share is not None and armed and plain else 1
        want = {i: m["weight"] * (scale if m["armed"] else 1) for i, m in pool.items()}
        total = sum(want.values())
        _, before = run(kind, None, 0)
        counts, after = run(kind, lua.table_from(opts) if opts else None, PICKS)
        got = {i: counts[i] / PICKS for i in counts}
        say("  %s: %s" % (name, ", ".join("%s %.1f%% (weights %.1f%%)" % (i, 100 * got.get(i, 0), 100 * want[i] / total)
                                          for i in sorted(pool, key=lambda i: -want[i]))))
        armed_got = sum(v for i, v in got.items() if models[i]["armed"])
        armed_want = sum(w for i, w in want.items() if models[i]["armed"]) / total
        say("    armed %.2f%% (from the weights %.2f%%), %d candidates, %d rolls for %d picks"
            % (100 * armed_got, 100 * armed_want, len(pool), after - before, PICKS))
        for i in got:
            if i not in pool:
                fails.append("%s: picked %s, which isn't in its pool" % (name, i))
        for i in pool:
            if abs(got.get(i, 0) - want[i] / total) > TOLERANCE:
                fails.append("%s: %s at %.2f%%, its weight says %.2f%%" % (name, i, 100 * got.get(i, 0), 100 * want[i] / total))
        if after - before != PICKS:
            fails.append("%s: %d rolls for %d picks (must be one each)" % (name, after - before, PICKS))
        return got, armed_got

    got, armed = case("battle royale", "car", {"drivable": True, "armedShare": TARGET}, True, TARGET)
    if abs(armed - TARGET) > TOLERANCE:
        fails.append("battle royale: armed cars %.2f%%, want %.0f%% +- %.0f" % (100 * armed, 100 * TARGET, 100 * TOLERANCE))
    armoured = [i for i, m in models.items() if m["kind"] == "car" and m["only"]]
    rest = [i for i, m in models.items() if m["kind"] == "car" and not m["only"]]
    if armoured and rest and max(got.get(i, 0) for i in armoured) >= min(got.get(i, 0) for i in rest):
        fails.append("battle royale: the armoured pair (%s) isn't the rarest" % ", ".join(sorted(armoured)))
    case("team bases (no option)", "car", {"drivable": True}, True, None)
    case("kerbside props (no option)", "car", None, False, None)
    case("bikes (option set)", "bike", {"drivable": True, "armedShare": TARGET}, True, TARGET)
    return fails


def map_part(faults, say, maps, seeds):
    runtimes = []
    real = cpm.LuaRuntime

    def capture(*a, **k):
        runtimes.append(real(*a, **k))
        return runtimes[-1]

    cpm.LuaRuntime = capture
    faults = dict(faults)
    faults["VehicleModels"] = list(faults.get("VehicleModels", [])) + PICK_LOG
    fails, cars, armed, calls = [], 0, 0, {"drivable": 0, "prop": 0}
    try:
        for map_id in maps:
            for seed in seeds:
                m = cpm.build(map_id, seed, faults)
                log = runtimes[-1].globals().PICK_LOG
                entries = [log[i] for i in range(1, len(log) + 1)] if log else []
                for e in entries:
                    kind, drivable, share = e.split("|")
                    if drivable == "true":
                        calls["drivable"] += 1
                        if kind == "car" and share != str(TARGET):
                            fails.append("%s seed %d: a parked drivable car picked with armedShare %s" % (map_id, seed, share))
                    else:
                        calls["prop"] += 1
                        if share != "nil":
                            fails.append("%s seed %d: a kerbside prop picked with armedShare %s" % (map_id, seed, share))
                driven = [c for c in m.cars if c["kind"] == "drivable-car"]
                n_armed = sum(1 for c in driven if c["model"] in ARMED)
                bikes = sum(1 for c in m.cars if c["kind"] == "drivable-bike")
                say("  %s seed %d: %d drivable cars (%d armed), %d bikes" % (map_id, seed, len(driven), n_armed, bikes))
                cars, armed = cars + len(driven), armed + n_armed
                if not driven:
                    fails.append("%s seed %d: no drivable cars parked" % (map_id, seed))
    finally:
        cpm.LuaRuntime = real
    say("  %d Pick calls for parked drivables, %d for kerbside props; %d drivable cars, %d armed (%.1f%%)"
        % (calls["drivable"], calls["prop"], cars, armed, 100 * armed / max(cars, 1)))
    if calls["drivable"] == 0:
        fails.append("no drivable Pick calls logged: the instrumentation missed")
    return fails


ARMED = set()


def run(faults, say, maps, seeds):
    _, vm = load_models({})
    ARMED.clear()
    ARMED.update(k for k in vm.Mounts.keys())
    fails = pick_part(faults, say)
    if maps:
        fails += map_part(faults, say, maps, seeds)
    return fails


def main():
    with_maps = "--no-maps" not in sys.argv
    maps = cpm.map_ids() if with_maps else []
    print("armed car share check (task 29): %d picks a case, tolerance %.0f point" % (PICKS, 100 * TOLERANCE))
    fails = run({}, print, maps, SEEDS)
    for f in fails:
        print("  FAIL " + f)
    print("the check: " + ("RED, %d failures" % len(fails) if fails else "green"))
    fired = 0
    for name, fault in FAULTS.items():
        needs_maps = "VehicleService" in fault
        if needs_maps and not with_maps:
            print("planted %s: skipped (--no-maps)" % name)
            continue
        got = run(fault, lambda *_: None, maps[:1] if needs_maps else [], SEEDS[:1])
        fired += bool(got)
        print("planted %s: %s" % (name, ("red (%d): %s" % (len(got), got[0])) if got else "GREEN (the check missed it)"))
    wanted = len(FAULTS) if with_maps else sum("VehicleService" not in f for f in FAULTS.values())
    print("planted faults caught: %d of %d" % (fired, wanted))
    ok = not fails and fired == wanted
    print("RESULT: " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
