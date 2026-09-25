"""Seed sweep for tools/base_vehicle_respawn_check.py, without Studio.

That check runs 12 seeds. Its failures ("the abandoned vehicle was replaced early", "8 replacements,
want 7") turn up only on some seeds, so twelve can pass while the fault stands. This runs the same
check, unchanged, over many seeds. It also watches every replacement the respawn tick parks. A
replacement lost again within 2 s of being parked (it was parked straight into water, a wall, off
the map...) is reported with the reason the game gives. It passes only when no seed fails and no
replacement is lost at once.

    python tools/base_vehicle_respawn_seed_sweep.py .                  seeds 1..300
    python tools/base_vehicle_respawn_seed_sweep.py . --seeds 1000
    python tools/base_vehicle_respawn_seed_sweep.py . --plant          the planted fault must be caught

The planted fault floods the spot of every vehicle parked after the match starts (terrain water
over it), so every replacement is under water the moment it lands. The invariant it aims at: a base
never gets a replacement that counts as lost the tick after it was parked. A game that refuses
flooded spots never parks those replacements, and then the check's "at home" counts fail instead,
so the plant fires whether or not the water-parking fault is fixed.

Needs `pip install lupa`.
"""

import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base_vehicle_respawn_check as check  # noqa: E402

# Wraps the check's Lua. Watches each slot after every tick: a slot that went live with a model and
# is lost again, with that same model, within 2 s is a replacement lost at once. _R.flood (the plant)
# puts water over every vehicle VehicleService.Create parks once the tick has started.
WATCH = r"""
local R, M = _R, ModeTeams
local relost = {}
local liveAt = {}
local realCreate = VehicleService.Create
VehicleService.Create = function(...)
    local model = realCreate(...)
    if R.flood and R.ticking and model then
        local p = model:GetPivot().Position
        table.insert(R.water, { centre = p, radius = 4, top = p.Y + 12 })
    end
    return model
end
local realTick = M.TickBaseVehicles
M.TickBaseVehicles = function(nowMs)
    R.ticking = true
    realTick(nowMs)
    for team = 1, 2 do
        for i, slot in ipairs(M.BaseVehicleSlots(team)) do
            local key = team * 100 + i
            local seen = liveAt[key]
            if not slot.lostAt then
                if not seen or seen.model ~= slot.model then liveAt[key] = { at = nowMs, model = slot.model } end
            elseif seen and seen.model == slot.model then
                if nowMs - seen.at <= 2000 then
                    table.insert(relost, ("RELOST team %d slot %d %s"):format(team, i, tostring(slot.lostWhy)))
                end
                liveAt[key] = nil
            end
        end
    end
end
local realTeardown = M.Teardown
M.Teardown = function(...)
    liveAt, R.ticking = {}, false
    return realTeardown(...)
end
local out = (function()
"""
WATCH_END = "\nend)()\nfor _, line in ipairs(relost) do table.insert(out, line) end\nreturn out\n"


def sweep(root, seeds, flood=False):
    """Runs the check over seeds 1..`seeds`. Returns { seed: [check failures] }, { seed: [re-loss
    reasons] } and the base vehicles examined."""
    original = check.CHECKS
    check.CHECKS = WATCH + ("_R.flood = true\n" if flood else "") + original + WATCH_END
    try:
        lines, examined = check.run(root, seeds=seeds)
    finally:
        check.CHECKS = original
    failed, relost = collections.defaultdict(list), collections.defaultdict(list)
    for line in lines:
        head, msg = line.split(": ", 1)
        if not head.startswith("seed "):  # VehicleService's own branch: not per seed
            failed[0].append(line)
        elif msg.startswith("RELOST "):
            relost[int(head.split()[1])].append(msg.split()[-1])
        else:
            failed[int(head.split()[1])].append(msg)
    return failed, relost, examined


def report(failed, relost, seeds, examined):
    reasons = collections.Counter(r for rs in relost.values() for r in rs)
    print("failing seeds: %d of %d %s" % (len(failed), seeds, sorted(failed)))
    for seed in sorted(failed)[:10]:
        print("  seed %d: %s" % (seed, "; ".join(failed[seed][:3])))
    print("replacements lost within 2 s of parking: %d, on seeds %s, reasons %s"
          % (sum(reasons.values()), sorted(relost), dict(reasons)))
    unexplained = sorted(set(failed) - set(relost))
    print("failing seeds with no replacement lost at once: %s" % unexplained)
    print("base_vehicle_respawn_seed_sweep: %d seeds, %d base vehicles examined, %d failing seeds"
          % (seeds, examined, len(set(failed) | set(relost))))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "."
    seeds = int(sys.argv[sys.argv.index("--seeds") + 1]) if "--seeds" in sys.argv else 300
    if "--plant" in sys.argv:
        failed, relost, _ = sweep(root, 3, flood=True)
        caught = all(s in failed or s in relost for s in (1, 2, 3))
        first = next((m for ms in failed.values() for m in ms), None) or next(iter(relost.values()), ["-"])[0]
        print(("CAUGHT  " if caught else "MISSED  ") + "every replacement parked under water, seeds 1-3  (" + str(first) + ")")
        print("base_vehicle_respawn_seed_sweep plants: %d of 1 caught" % (1 if caught else 0))
        sys.exit(0 if caught else 1)
    failed, relost, examined = sweep(root, seeds)
    report(failed, relost, seeds, examined)
    sys.exit(1 if failed or relost else 0)


if __name__ == "__main__":
    main()
