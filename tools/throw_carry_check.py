"""Behaviour check: a thrown item inherits at most a flat-out slide's worth of the thrower's run.

    python3 tools/throw_carry_check.py .            the checks
    python3 tools/throw_carry_check.py . --plant    the planted faults; every one must be caught

A player's root velocity is written by their own client. Ballistics.ThrowVelocity used to add
`inherit` of whatever it said, so a modified client reporting 2,000 studs/s threw a grenade across the
map (bug hunt B8). Runs the REAL ReplicatedStorage/Shared/Ballistics.lua in lupa and checks:

  * an ordinary sprint carries exactly as before (inherit x the flat run, nothing lost);
  * a run over Ballistics.MaxCarrierSpeed carries MaxCarrierSpeed, in the same direction;
  * vertical velocity never carries; NaN or infinite velocity carries nothing;
  * MaxCarrierSpeed is the fastest legitimate run: MatchConfig.BaseWalkSpeed x SprintMultiplier x
    MovementConfig.Slide.PeakMultiplier, read from those files (within a stud/s, rounded up);
  * ProjectileService throws and cooks off through it, never with the raw root velocity.

Needs `pip install lupa`.
"""
import math
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("throw_carry_check: needs lupa (pip install lupa)")

BALLISTICS = "ReplicatedStorage/Shared/Ballistics.lua"
PROJECTILE = "ServerScriptService/Modules/ProjectileService.lua"
MATCHCONFIG = "ReplicatedStorage/Shared/MatchConfig.lua"
MOVEMENT = "ReplicatedStorage/Shared/MovementConfig.lua"

HARNESS = r"""
local src = ...
local V = {}
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V) end
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); return vec(v.X / m, v.Y / m, v.Z / m) end
end
V.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b) if type(a) == "number" then a, b = b, a end return vec(a.X * b, a.Y * b, a.Z * b) end
Vector3 = { new = vec, zero = vec(0, 0, 0), yAxis = vec(0, 1, 0), xAxis = vec(1, 0, 0), zAxis = vec(0, 0, 1) }
-- Whatever else the module builds at load time (colours, frames) only has to exist.
local anyMT = {}
anyMT.__index = function() return function() return setmetatable({}, anyMT) end end
anyMT.__call = function() return setmetatable({}, anyMT) end
local function any() return setmetatable({}, anyMT) end
Color3, CFrame, NumberSequence, ColorSequence = any(), any(), any(), any()
local B = assert(load(src, "Ballistics"))()
local spec = B.Throwables.CookedCoconut
local head, aim = vec(0, 5, 0), vec(0, 5, -100)
local still = B.ThrowVelocity(spec, head, aim, vec(0, 0, 0))
local function carry(v)
    local t = B.ThrowVelocity(spec, head, aim, v)
    return vec(t.X - still.X, t.Y - still.Y, t.Z - still.Z)
end
return {
    cap = B.MaxCarrierSpeed,
    inherit = spec.inherit,
    sprint = carry(vec(26, 0, 0)),
    hacked = carry(vec(2000, 0, 2000)),
    falling = carry(vec(0, -300, 0)),
    nan = carry(vec(0 / 0, 0, 0)),
    inf = carry(vec(math.huge, 0, 0)),
}
"""


def luau_to_lua(source):
    # x += y  ->  x = x + (y)   (the only Luau-only syntax Ballistics uses)
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/]|\.\.)= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def number(text, pattern):
    return float(re.search(pattern, text, re.M).group(1))


def rows_for(sources):
    rows = []
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        r = lua.execute(HARNESS, luau_to_lua(sources[BALLISTICS]))
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]
    cap, inherit = r["cap"], r["inherit"]

    def flat(v):
        return math.hypot(v["X"], v["Z"])

    s = r["sprint"]
    rows.append((abs(s["X"] - 26 * inherit) < 1e-6 and abs(s["Z"]) < 1e-6 and abs(s["Y"]) < 1e-6,
                 "a 26 studs/s sprint carries %.2f (inherit %.2f x 26, untouched)" % (s["X"], inherit)))
    h = r["hacked"]
    rows.append((abs(flat(h) - cap * inherit) < 1e-6 and abs(h["X"] - h["Z"]) < 1e-6,
                 "a client claiming 2,828 studs/s carries %.2f (the cap %s x inherit), in its own direction" % (flat(h), cap)))
    f = r["falling"]
    rows.append((abs(f["X"]) + abs(f["Y"]) + abs(f["Z"]) < 1e-6, "falling carries nothing into the throw"))
    for key in ("nan", "inf"):
        v = r[key]
        finite = all(v[a] == v[a] and abs(v[a]) < 1e9 for a in ("X", "Y", "Z"))
        rows.append((finite and flat(v) < 1e-6, "%s velocity carries nothing" % ("a NaN" if key == "nan" else "an infinite")))

    base = number(sources[MATCHCONFIG], r"^MatchConfig\.BaseWalkSpeed = ([\d.]+)")
    sprint = number(sources[MATCHCONFIG], r"^MatchConfig\.SprintMultiplier = ([\d.]+)")
    peak = number(sources[MOVEMENT], r"^\s*PeakMultiplier = ([\d.]+)")
    fastest = base * sprint * peak
    rows.append((fastest <= cap <= fastest + 1,
                 "MaxCarrierSpeed %s is a flat-out slide (%.0f x %.2f x %.2f = %.1f, rounded up)" % (cap, base, sprint, peak, fastest)))

    proj = sources[PROJECTILE]
    raw = [line.strip() for line in proj.splitlines()
           if "AssemblyLinearVelocity" in line and "spawnThrown(" in line and "Ballistics.CarrierVelocity(" not in line]
    rows.append((not raw, "ProjectileService never throws with a raw root velocity (%d site(s))" % len(raw)))
    rows.append(("Ballistics.ThrowVelocity(spec, head.Position, target, root.AssemblyLinearVelocity)" in proj,
                 "ProjectileService's throw goes through ThrowVelocity"))
    return rows


PLANTS = [
    ("no cap (the old carry)", BALLISTICS,
     "\tif speed > Ballistics.MaxCarrierSpeed then\n\t\treturn flat * (Ballistics.MaxCarrierSpeed / speed)\n\tend\n", ""),
    ("the cap raised far past a slide", BALLISTICS, "Ballistics.MaxCarrierSpeed = 46", "Ballistics.MaxCarrierSpeed = 400"),
    ("the vertical carried too", BALLISTICS, "local flat = Vector3.new(velocity.X, 0, velocity.Z)", "local flat = velocity"),
    ("NaN passed through", BALLISTICS, "if speed ~= speed or speed == math.huge then", "if false then"),
    ("the cook-off spawns with the raw velocity", PROJECTILE,
     "Ballistics.CarrierVelocity(root.AssemblyLinearVelocity), spec.fuse)", "root.AssemblyLinearVelocity, spec.fuse)"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {rel: open(os.path.join(root, rel), encoding="utf-8").read() for rel in (BALLISTICS, PROJECTILE, MATCHCONFIG, MOVEMENT)}
    if "--plant" in sys.argv:
        caught = 0
        for label, rel, old, new in PLANTS:
            if sources[rel].count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            planted = dict(sources)
            planted[rel] = sources[rel].replace(old, new)
            failed = [line for ok, line in rows_for(planted) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"throw_carry_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = rows_for(sources)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"throw_carry_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
