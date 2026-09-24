"""Vehicle gun aim check (Oliver: "the aim to follow your mouse"), without Studio.

Two halves, both on the real source:

  A. The PURE block of StarterPlayerScripts/VehicleWeaponClient.client.lua (lupa), with the real
     ReplicatedStorage/Shared/VehicleWeaponData.lua:
       - which input aims at the mouse (a free mouse) and which at the middle (pad, touch, locked mouse);
       - the aim point is the cursor at 7 screen sizes and 9 cursor spots each, held on the screen;
       - every real mount's arc: a direction inside it comes back unchanged and is not pinned; one
         past the yaw limit or the pitch limits comes back on the limit and is pinned.
  B. The whole script in tools/hud_mock_world.lua (the HUD check's mock client), in an armed car:
     the camera ray goes through the cursor with a mouse and through the middle with a pad, and the
     aim mark is drawn where the ray goes, at every size.

    python3 tools/vehicle_aim_check.py .            the checks
    python3 tools/vehicle_aim_check.py . --plant    the planted faults; every one must be caught
"""

import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lupa import LuaRuntime  # noqa: E402
import hud_layout_check as hud  # noqa: E402

SCRIPT = "VehicleWeaponClient.client.lua"
SIZES = [(1920, 1080), (1366, 768), (1024, 768), (768, 1024), (844, 390), (390, 844), (375, 667)]


def pure(source, weapons_src):
    block = re.search(r"-- PURE BEGIN.*?\n(.*)-- PURE END", source, re.S).group(1)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end\n"
                "math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end")
    api = lua.execute(block + "\nreturn { aimMode = aimMode, aimScreenPoint = aimScreenPoint, "
                      "directionFromAngles = directionFromAngles, pinnedToArc = pinnedToArc }")
    data = lua.execute(hud.luau_to_lua(weapons_src))
    vec = lua.eval("function(x, y, z) return { X = x, Y = y, Z = z } end")
    return lua, api, data, vec


def check_pure(source, weapons_src):
    problems, examined = [], 0
    lua, api, data, vec = pure(source, weapons_src)
    for name, locked, want in [("MouseMovement", False, "mouse"), ("MouseButton1", False, "mouse"),
                               ("Keyboard", False, "mouse"), ("MouseMovement", True, "centre"),
                               ("Gamepad1", False, "centre"), ("Touch", False, "centre")]:
        examined += 1
        got = api.aimMode(name, locked)
        if got != want:
            problems.append(f"aimMode({name}, locked={locked}) = {got}, want {want}")
    for w, h in SIZES:
        for fx, fy in [(0.1, 0.1), (0.5, 0.5), (0.9, 0.2), (0.3, 0.8), (1.0, 1.0), (0.0, 0.5), (0.75, 0.4),
                       (1.3, 0.5), (-0.2, 1.4)]:
            examined += 1
            mx, my = fx * w, fy * h
            x, y = api.aimScreenPoint("mouse", mx, my, w, h)
            want = (min(max(mx, 0), w), min(max(my, 0), h))
            if abs(x - want[0]) > 1e-6 or abs(y - want[1]) > 1e-6:
                problems.append(f"{w}x{h}: cursor at ({mx:.0f},{my:.0f}) aims through ({x:.0f},{y:.0f}), want {want}")
            x, y = api.aimScreenPoint("centre", mx, my, w, h)
            if (x, y) != (w / 2, h / 2):
                problems.append(f"{w}x{h}: a pad aims through ({x},{y}), not the middle")
    specs = data.Weapons
    for key in list(specs.keys()):
        spec = specs[key]
        ylim, pmin, pmax = spec.yawLimit, spec.pitchMin, spec.pitchMax
        cases = []
        for yd in (-0.9 * ylim, 0, 0.5 * ylim):
            for pd in (pmin + 0.1 * (pmax - pmin), pmin + 0.5 * (pmax - pmin), pmin + 0.9 * (pmax - pmin)):
                cases.append((yd, pd, False))
        if ylim < 180:
            cases.append((ylim + 20, 0, True))
            cases.append((-(ylim + 20), 0, True))
        cases.append((0, pmax + 10, True))
        cases.append((0, pmin - 10, True))
        for yd, pd, outside in cases:
            examined += 1
            dx, dy, dz = api.directionFromAngles(math.radians(yd), math.radians(pd))
            yaw, pitch = data.ClampAim(spec, vec(dx * 50, dy * 50, dz * 50))
            pinned = api.pinnedToArc(math.radians(yd), math.radians(pd), yaw, pitch)
            if pinned != outside:
                problems.append(f"{key}: aim yaw {yd:.0f} pitch {pd:.0f} pinned={pinned}, want {outside}")
            if not outside and (abs(math.degrees(yaw) - yd) > 1e-3 or abs(math.degrees(pitch) - pd) > 1e-3):
                problems.append(f"{key}: an aim inside the arc (yaw {yd:.0f}, pitch {pd:.0f}) came back as "
                                f"({math.degrees(yaw):.1f}, {math.degrees(pitch):.1f})")
            if outside:
                edge_y = min(max(yd, -ylim), ylim)
                edge_p = min(max(pd, pmin), pmax)
                if abs(math.degrees(yaw) - edge_y) > 1e-3 or abs(math.degrees(pitch) - edge_p) > 1e-3:
                    problems.append(f"{key}: an aim outside the arc was not held on its edge")
    return problems, examined


def check_wired(root, sources):
    problems, examined = [], 0
    for w, h in SIZES:
        touch = False
        world = hud.World(root, (f"{w}x{h}", w, h, touch), sources)
        world.play("BattleRoyale", "driver")
        for mode, (fx, fy) in [("MouseMovement", (0.25, 0.3)), ("MouseMovement", (0.8, 0.7)), ("Gamepad1", (0.25, 0.3))]:
            examined += 1
            got = world.run("""
                local mode, x, y = select(2, ...)
                W.lastInput = mode
                W.mouse = W.Vector2.new(x, y)
                W.lastRay = nil
                W.frame(1)
                local reticle
                for _, inst in ipairs(W.created) do
                    if W.instSite(inst) and W.instSite(inst):find('VehicleWeaponClient') and inst.Size.X.Offset == 8
                        and inst.Size.Y.Offset == 8 then
                        reticle = inst
                    end
                end
                local r = W.lastRay
                local p = reticle and reticle.Position
                return string.format('%s %s %s %s', r and r.x or 'nil', r and r.y or 'nil',
                    p and (p.X.Scale * W.viewport.X + p.X.Offset) or 'nil', p and (p.Y.Scale * W.viewport.Y + p.Y.Offset) or 'nil')
            """, mode, fx * w, fy * h)
            rx, ry, px, py = got.split()
            want = (fx * w, fy * h) if mode != "Gamepad1" else (w / 2, h / 2)
            if rx == "nil" or abs(float(rx) - want[0]) > 0.01 or abs(float(ry) - want[1]) > 0.01:
                problems.append(f"{w}x{h} {mode}: the gun's ray went through ({rx}, {ry}), want {want}")
            if px == "nil" or abs(float(px) - want[0]) > 0.6 or abs(float(py) - want[1]) > 0.6:
                problems.append(f"{w}x{h} {mode}: the aim mark is at ({px}, {py}), want {want}")
    return problems, examined


def check(root, sources, weapons_src, quiet=False):
    a, na = check_pure(sources[SCRIPT], weapons_src)
    b, nb = check_wired(root, sources)
    if not quiet:
        print(f"vehicle_aim_check: {na} pure cases, {nb} wired cases examined")
    return a + b


PLANTS = [
    ("the aim point ignoring the mouse", SCRIPT,
     "return math.clamp(mouseX, 0, width), math.clamp(mouseY, 0, height)", "return width / 2, height / 2"),
    ("the ray cast through the middle whatever the aim point", SCRIPT,
     "local ray = camera:ViewportPointToRay(screenX, screenY)",
     "local ray = camera:ViewportPointToRay(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)"),
    ("an aim outside the arc not reported as pinned", SCRIPT,
     "return math.abs(wantYaw - yaw) > 1e-4 or math.abs(wantPitch - pitch) > 1e-4", "return false"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {n: hud.read(root, n) for n in hud.SCRIPTS}
    for m in hud.MODULES:
        sources[m + ".lua"] = hud.read(root, m + ".lua")
    weapons_src = open(os.path.join(root, "ReplicatedStorage", "Shared", "VehicleWeaponData.lua"), encoding="utf-8").read()
    if "--plant" in sys.argv:
        missed = 0
        for what, file, anchor, replacement in PLANTS:
            if anchor not in sources[file]:
                print(f"PLANT ANCHOR MISSING ({what}): {anchor!r}")
                missed += 1
                continue
            mutated = dict(sources)
            mutated[file] = sources[file].replace(anchor, replacement, 1)
            problems = check(root, mutated, weapons_src, quiet=True)
            print(f"plant: {what}: {'CAUGHT' if problems else 'MISSED'} ({len(problems)} problems)")
            missed += 0 if problems else 1
        print("plants missed:", missed)
        sys.exit(1 if missed else 0)
    problems = check(root, sources, weapons_src)
    for p in problems:
        print("PROBLEM", p)
    print(f"problems: {len(problems)}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
