"""#79 lean: prove MovementConfig.ClampLean can never put the eye (or a shot's origin) inside a wall.

    python tools/lean_clamp_check.py .

Runs the REAL ReplicatedStorage/Shared/MovementConfig.lua in lupa. The world is one wall per side at a
distance from the head; the fake Spherecast returns how far a sphere of Lean.Radius travels before it
touches that wall, exactly as workspace:Spherecast reports Distance. Over a grid of leans and wall
distances it holds four invariants:
  1. never more than Lean.Offset either way;
  2. never flips side (a left lean stays left or becomes 0);
  3. the leaned eye keeps at least Radius + Margin from the wall's surface, so the view and the
     head-to-origin segment never touch geometry (the point of the whole clamp);
  4. with nothing in reach the lean is exactly what was asked for (the clamp doesn't eat free leans).
Plus: NaN and non-numbers give 0.

Planted faults (permanent): the same source with the margin added instead of taken away, and with the
cast always aimed right. Each must break an invariant, or this check is reported as unable to fail.
Exit code 1 on any failure.
"""

import sys
from pathlib import Path

from lupa import LuaRuntime

SOURCE = Path("ReplicatedStorage/Shared/MovementConfig.lua")


def run(source):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("math.clamp = function(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end")
    config = lua.execute(source)
    lean = config.Lean
    offset, radius, margin = lean.Offset, lean.Radius, lean.Margin
    clamp = config.ClampLean
    wrap = lua.eval("function(f) return function(r) return f(r) end end")
    failures = []
    examined = 0
    walls = [None, radius + 0.01, radius + margin, 0.5, 0.8, 1.0, 1.3, offset + radius,
             offset + radius + margin + 0.5, 5.0]
    leans = [i / 20 * 2.4 - 1.2 for i in range(21)] + [-5.0, 5.0, offset, -offset]
    for left_wall in walls:
        for right_wall in walls:
            def cast(reach, lw=left_wall, rw=right_wall):
                wall = rw if reach > 0 else lw
                if wall is None:
                    return None
                travel = wall - radius
                return travel if travel <= abs(reach) else None
            fn = wrap(cast)
            for wanted in leans:
                examined += 1
                got = clamp(wanted, fn)
                tag = f"wanted={wanted:+.2f} left={left_wall} right={right_wall} -> {got:+.3f}"
                if abs(got) > offset + 1e-9:
                    failures.append("1 over Offset: " + tag)
                if got * wanted < 0:
                    failures.append("2 flipped side: " + tag)
                wall = right_wall if got > 0 else left_wall if got < 0 else None
                if wall is not None and wall - abs(got) < radius + margin - 1e-9:
                    failures.append("3 eye within Radius+Margin of the wall: " + tag)
                want = max(-offset, min(offset, wanted))
                free = right_wall if want > 0 else left_wall
                if want != 0 and (free is None or free - radius > abs(want) + margin) and abs(got - want) > 1e-9:
                    failures.append("4 free lean clamped: " + tag)
    nothing = lua.eval("function() return nil end")
    for bad in (float("nan"), "x", None):
        examined += 1
        if clamp(bad, nothing) != 0:
            failures.append(f"non-number {bad!r} not 0")
    return examined, failures


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    source = (root / SOURCE).read_text()
    examined, failures = run(source)
    print(f"lean clamp: {examined} cases examined, {len(failures)} failures")
    for line in failures[:10]:
        print("  " + line)
    ok = not failures

    faults = {
        "margin added, not taken": ("hit - lean.Margin", "hit + lean.Margin"),
        "cast always aimed right": ("cast(sign * (size + lean.Margin))", "cast(size + lean.Margin)"),
    }
    for name, (before, after) in faults.items():
        if before not in source:
            print(f"planted fault '{name}': ANCHOR MISSING, the check cannot be shown to fail")
            ok = False
            continue
        n, found = run(source.replace(before, after, 1))
        caught = len(found) > 0
        print(f"planted fault '{name}': {'CAUGHT' if caught else 'NOT CAUGHT'} ({len(found)} failures of {n})")
        ok = ok and caught
    print("lean clamp check: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
