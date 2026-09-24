"""Behaviour check: a network stall is not a crash (VehicleService collision damage), without Studio.

    python3 tools/vehicle_collision_check.py .            the checks
    python3 tools/vehicle_collision_check.py . --plant    the planted faults; every one must be caught

A client-owned vehicle's velocity reaches the server in bursts. After a stall the reading sits unchanged
for several frames and then drops all at once, and checkCollisionDamage read ordinary braking over the
whole stall as one impact (bug hunt A2: 48 damage for braking from 84 to 52 across half a second).
Runs the REAL checkCollisionDamage and updateOwnership, cut from VehicleService.lua, in lupa:

  * braking at the handling's full `brake` every 60 Hz frame never damages;
  * the same braking hidden by a 0.5 s stall and delivered in one reading never damages;
  * a real impact (84 -> 0 in one frame) still damages, (drop - COLLISION_FLOOR) x COLLISION_DAMAGE_PER;
  * a real impact straight after a stall still damages (the allowance is the stall's braking, not a pass);
  * a change of network owner starts the check fresh (no "drop" from the old owner's last reading).

What this cannot show offline: real replication timing. The numbers are the handling's own.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("vehicle_collision_check: needs lupa (pip install lupa)")

SERVICE = "ServerScriptService/Modules/VehicleService.lua"


def cut(src, head):
    a = src.index(head)
    b = src.index("\nend\n", a) + 5
    return src[a:b]


def constant(src, name):
    return float(re.search(r"^local %s = ([\d.]+)" % name, src, re.M).group(1))


HARNESS = r"""
local src, floor, per = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local damage = 0
local env = setmetatable({
    COLLISION_FLOOR = floor, COLLISION_DAMAGE_PER = per,
    damageVehicle = function(_, amount) damage = damage + amount end,
    Players = {},
}, { __index = _G })
local check_, own = assert(load(src .. "\nreturn checkCollisionDamage, updateOwnership", "VehicleService", "t", env))()
local function car()
    local chassis = { Position = 0 }
    function chassis:SetNetworkOwner() end
    local model = { attrs = {} }
    function model:SetAttribute() end
    function model:GetPivot() return 0 end
    return { rig = { chassis = chassis, handling = { brake = 100 } }, model = model, owner = false, serverHoldUntil = 0 }
end
local dt = 1 / 60

-- Braking at full `brake` every frame, from 84 to 0.
local e = car()
local t, v = 0, 84
check_(e, v, t, dt)
while v > 0 do t = t + dt; v = math.max(0, v - 100 * dt); check_(e, v, t, dt) end
check(damage == 0, string.format("full braking at 60 Hz: %.1f damage", damage))

-- The same braking hidden by a 0.5 s stall: 84 unchanged for 30 frames, then 34 in one reading.
damage = 0
e, t = car(), 0
check_(e, 84, t, dt)
for _ = 1, 30 do t = t + dt; check_(e, 84, t, dt) end
t = t + dt
check_(e, 84 - 100 * 0.5, t, dt)
check(damage == 0, string.format("braking hidden by a 0.5 s stall and delivered at once: %.1f damage", damage))

-- A real impact: 84 to 0 in one frame.
damage = 0
e, t = car(), 0
check_(e, 84, t, dt)
t = t + dt; check_(e, 0, t, dt)
local want = (84 - floor) * per
check(math.abs(damage - want) < 1e-6, string.format("84 -> 0 in one frame: %.1f damage (want %.1f)", damage, want))

-- A real impact straight after a 0.2 s stall: the allowance is the stall's braking (20), no more.
damage = 0
e, t = car(), 0
check_(e, 84, t, dt)
for _ = 1, 12 do t = t + dt; check_(e, 84, t, dt) end
t = t + dt; check_(e, 0, t, dt)
check(damage > 0, string.format("a wall after a 0.2 s stall still damages: %.1f", damage))

-- A change of owner starts fresh: the new owner's first reading is no drop from the old one's last.
damage = 0
e = car()
check_(e, 84, 0, dt)
e.driverPlayer = { Parent = env.Players }
own(e, dt)
check_(e, 0, 2 * dt, dt)
check(damage == 0, string.format("a new network owner's first reading: %.1f damage", damage))
return out
"""


def run(src):
    try:
        code = cut(src, "local function checkCollisionDamage(") + "\n" + cut(src, "local function updateOwnership(")
        lua = LuaRuntime(unpack_returned_tuples=True)
        rows = lua.execute(HARNESS, code, constant(src, "COLLISION_FLOOR"), constant(src, "COLLISION_DAMAGE_PER"))
        return [(bool(r["ok"]), r["line"]) for r in rows.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]


PLANTS = [
    ("the floor ignores the stall (the old check)", "\tlocal floor = COLLISION_FLOOR + brake * stale\n", "\tlocal floor = COLLISION_FLOOR\n"),
    ("an unchanged reading judged as a new one", "\tif last ~= nil and flatSpeed == last then\n\t\treturn\n\tend\n", ""),
    ("the allowance never ends (a crash after a stall is free)", "\tlocal floor = COLLISION_FLOOR + brake * stale\n",
     "\tlocal floor = COLLISION_FLOOR + brake * stale * 100\n"),
    ("the owner change keeps the last reading", "\t\tentry.lastFlatSpeed = nil\n\tend\nend", "\tend\nend"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    src = open(os.path.join(root, SERVICE), encoding="utf-8").read()
    if "--plant" in sys.argv:
        caught = 0
        for label, old, new in PLANTS:
            if src.count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            failed = [line for ok, line in run(src.replace(old, new)) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"vehicle_collision_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = run(src)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"vehicle_collision_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
