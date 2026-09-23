"""#7 drink pose check: does any drink come through the face at the height of its sip?

Reads ITEM_HIP and the DRINKS use pose out of StarterPlayerScripts/CombatClient.client.lua and applies
them the way the item viewmodel does (view * CF(ITEM_HIP) * Ry(0.2) * useTarget * CF(-grip)), at full
tip, to a point cloud of each drink's glass. The shapes are copied from ItemModels.lua (MiniShield,
ShieldPotion, SpeedSoda branches, design origin = pivot); if those change, update SHAPES.

Invariants, in camera space (the camera looks down -Z):
  1. no point of any drink is less than MIN_DEPTH studs in front of the eye (nothing behind the
     camera, nothing cut by the near plane);
  2. each drink's neck (its highest design point) is on screen at FOV 70, 16:9.
Planted faults, run every time: the pre-fix pose, and the current pose pushed 0.5 studs towards the
camera, must each fail.

    python3 tools/fps_drink_check.py .
"""
import math
import re
import sys
from pathlib import Path

MIN_DEPTH = 0.45
HALF_V = math.tan(math.radians(35))
HALF_H = HALF_V * 16 / 9


def rx(a, p):
    c, s = math.cos(a), math.sin(a)
    return (p[0], c * p[1] - s * p[2], s * p[1] + c * p[2])


def ry(a, p):
    c, s = math.cos(a), math.sin(a)
    return (c * p[0] + s * p[2], p[1], -s * p[0] + c * p[2])


def rz(a, p):
    c, s = math.cos(a), math.sin(a)
    return (c * p[0] - s * p[1], s * p[0] + c * p[1], p[2])


def cloud(parts):
    pts = []
    for kind, h, d, (x, y, z) in parts:
        for i in range(5):
            t = i / 4 - 0.5
            for j in range(16):
                a = j / 16 * 2 * math.pi
                if kind == "col":
                    pts.append((x + d / 2 * math.cos(a), y + t * h, z + d / 2 * math.sin(a)))
                else:
                    ph = t * math.pi
                    pts.append((x + d / 2 * math.cos(ph) * math.cos(a), y + d / 2 * math.sin(ph),
                                z + d / 2 * math.cos(ph) * math.sin(a)))
    return pts


# (points, grip) from ItemModels.lua.
STRAW = [(0.12 + s * 0.275 * math.sin(0.25), 0.8 + s * 0.275 * math.cos(0.25), 0) for s in (-1, -0.5, 0, 0.5, 1)]
SHAPES = {
    "MiniShield": (cloud([("ball", 0, 0.9, (0, 0, 0)), ("col", 0.35, 0.3, (0, 0.55, 0)), ("col", 0.18, 0.26, (0, 0.8, 0))]),
                   (0, -0.1, 0.2)),
    "ShieldPotion": (cloud([("col", 1.1, 0.7, (0, 0, 0)), ("ball", 0, 0.7, (0, 0.45, 0)), ("col", 0.37, 0.26, (0, 0.935, 0)),
                            ("col", 0.25, 0.2, (0, 1.175, 0)), ("ball", 0, 0.2, (0, 1.38, 0)),
                            ("col", 0.11, 0.74, (0, -0.605, 0))]), (0, -0.1, 0.25)),
    "SpeedSoda": (cloud([("col", 1.0, 0.62, (0, 0, 0)), ("col", 0.1, 0.7, (0, 0.55, 0))]) + STRAW, (0, -0.05, 0.2)),
}

NUM = r"(-?[\d.]+)"


def read_pose(src):
    hip = re.search(r"local ITEM_HIP = Vector3\.new\(" + NUM + r", " + NUM + r", " + NUM + r"\)", src)
    body = src[src.index("if DRINKS[id] then"):src.index('elseif id == "Bandage" then')]
    pos = re.search(r"useTarget = CFrame\.new\(" + NUM + r" \* tip, " + NUM + r" \* tip.*?, " + NUM + r" \* tip\)", body, re.S)
    ang = re.search(r"CFrame\.Angles\(" + NUM + r" \* tip, 0, " + NUM + r" \* tip\)", body)
    return tuple(map(float, hip.groups())), tuple(map(float, pos.groups())), tuple(map(float, ang.groups()))


def check(hip, pos, ang):
    fails = []
    offset = ry(0.2, pos)
    for name, (pts, grip) in SHAPES.items():
        placed = []
        for p in pts:
            q = (p[0] - grip[0], p[1] - grip[1], p[2] - grip[2])
            q = ry(0.2, rx(ang[0], rz(ang[1], q)))
            placed.append((hip[0] + offset[0] + q[0], hip[1] + offset[1] + q[1], hip[2] + offset[2] + q[2]))
        depth = min(-p[2] for p in placed)
        if depth < MIN_DEPTH:
            fails.append(f"{name}: nearest point {depth:.3f} studs in front of the eye (< {MIN_DEPTH})")
        neck = placed[max(range(len(pts)), key=lambda i: pts[i][1])]
        d = -neck[2]
        if d <= 0 or abs(neck[0]) > HALF_H * d or abs(neck[1]) > HALF_V * d:
            fails.append(f"{name}: neck off screen at {tuple(round(v, 2) for v in neck)}")
        print(f"  {name:13s} nearest {depth:.3f} studs, neck at {tuple(round(v, 2) for v in neck)}")
    return fails


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    hip, pos, ang = read_pose((root / "StarterPlayerScripts/CombatClient.client.lua").read_text(encoding="utf-8"))
    print(f"drink pose from source: hip {hip}, use {pos}, angles {ang}; {sum(len(p) for p, _ in SHAPES.values())} points over {len(SHAPES)} drinks")
    fails = check(hip, pos, ang)
    for f in fails:
        print("  FAIL", f)
    ok = not fails
    for label, fpos, fang in [("pre-fix pose", (-0.6, 0.62, 1.05), (1.15, 0.35)),
                              ("pose 0.5 studs nearer", (pos[0], pos[1], pos[2] + 0.5), ang)]:
        print(f" planted fault '{label}':")
        planted = check(hip, fpos, fang)
        print(f"  -> {'caught' if planted else 'NOT CAUGHT'} ({len(planted)} failures)")
        ok = ok and bool(planted)
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
