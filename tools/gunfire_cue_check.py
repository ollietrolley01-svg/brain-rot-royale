"""Proves the direction maths in StarterPlayerScripts/GunfireCueClient.client.lua (#22).

Runs the file's own PURE block (real source, under lupa) and holds it to:
  1. a shot at relative bearing B (0 ahead, +90 right) comes out as angle B, for 36 camera yaws x
     7 pitches (straight down to straight up) x 24 bearings x 3 heights -- truth built by rotating a
     camera-local direction, not by the formula under test;
  2. the chevron lands on screen, clear of the crosshair, on the correct side, on a circular ring,
     for every viewport in a sweep of 320..3840 x 320..2160 (both orientations);
  3. a source on top of you has no direction (nil), and near shots draw stronger than far ones.
Then applies four PERMANENT planted faults to the source and requires each to be caught.

    python3 tools/gunfire_cue_check.py      -> exit 0 and "gunfire cue: ... 0 failures, 4/4 faults caught"
"""
import math
import pathlib
import re
import sys

from lupa import LuaRuntime

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "StarterPlayerScripts" / "GunfireCueClient.client.lua").read_text()

FAULTS = {
    "across sign flipped (left/right mirrored)": ("local across = offset.X * rx + offset.Z * rz",
                                                  "local across = -(offset.X * rx + offset.Z * rz)"),
    "screen y sign flipped (ahead drawn below)": ("height / 2 - radius * math.cos(angle)",
                                                  "height / 2 + radius * math.cos(angle)"),
    "radius from width, not short side": ("math.min(width, height) * 0.26", "width * 0.26"),
    "flattened LookVector used as forward": ("local fx, fz = rz, -rx",
                                             "local fx, fz = look.X, look.Z"),
}


def pure_block(source):
    block = re.search(r"-- PURE BEGIN.*?\n(.*)-- PURE END", source, re.S).group(1)
    earshot = re.search(r"local EARSHOT = \d+", source).group(0)
    return earshot + "\n" + block + "\nreturn { cueAngle = cueAngle, ringPoint = ringPoint, ringRadius = ringRadius, cueStrength = cueStrength }"


def load(block):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end")
    return lua, lua.execute(block)


def camera(yaw, pitch):
    """Roblox CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0): right and look vectors."""
    right = (math.cos(yaw), 0.0, -math.sin(yaw))
    look = (-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch))
    return right, look


def world_offset(yaw, bearing, dist, height):
    # Camera-local level direction (right = +X, forward = -Z), turned by the camera's yaw about +Y.
    lx, lz = math.sin(bearing) * dist, -math.cos(bearing) * dist
    return (lx * math.cos(yaw) + lz * math.sin(yaw), height, -lx * math.sin(yaw) + lz * math.cos(yaw))


def run(block):
    failures, cases = [], 0
    lua, mod = load(block)
    table = lua.table_from

    # 1. direction
    for yi in range(36):
        yaw = math.radians(yi * 10 + 3)
        for pitch_deg in (-89.9, -60, -20, 0, 20, 60, 89.9):
            right, look = camera(yaw, math.radians(pitch_deg))
            # The fault that swaps in the LookVector reads a global `look`; the real code never does.
            lua.globals().look = table({"X": look[0], "Y": look[1], "Z": look[2]})
            r = table({"X": right[0], "Y": right[1], "Z": right[2]})
            for bi in range(24):
                bearing = math.radians(bi * 15 - 165)
                for height in (-40, 0, 60):
                    off = world_offset(yaw, bearing, 120, height)
                    got = mod.cueAngle(r, table({"X": off[0], "Y": off[1], "Z": off[2]}))
                    cases += 1
                    err = None if got is None else abs((got - bearing + math.pi) % (2 * math.pi) - math.pi)
                    if err is None or err > 1e-6:
                        failures.append(f"yaw {math.degrees(yaw):.0f} pitch {pitch_deg} bearing {math.degrees(bearing):.0f}: got {got}")

    # 3. no direction when on top of you; strength falls with distance
    cases += 2
    if mod.cueAngle(table({"X": 1, "Y": 0, "Z": 0}), table({"X": 1, "Y": 30, "Z": 1})) is not None:
        failures.append("a source 1.4 studs away horizontally still got a direction")
    if not (mod.cueStrength(5) > mod.cueStrength(200) > mod.cueStrength(400) > 0):
        failures.append("strength does not fall with distance")

    # 2. screen placement
    sizes = [(w, h) for w in range(320, 3841, 80) for h in range(320, 2161, 80)]
    sizes += [(667, 375), (844, 390), (390, 844), (1280, 720), (1920, 1080), (3840, 2160)]
    for w, h in sizes:
        radius = mod.ringRadius(w, h)
        for deg in range(0, 360, 15):
            a = math.radians(deg)
            x, y = mod.ringPoint(w, h, a)
            cases += 1
            dx, dy = x - w / 2, y - h / 2
            where = f"{w}x{h} at {deg}"
            if not (20 <= x <= w - 20 and 20 <= y <= h - 20):
                failures.append(f"{where}: chevron off screen ({x:.0f},{y:.0f})")
            if math.hypot(dx, dy) < 70:
                failures.append(f"{where}: on the crosshair")
            if abs(math.hypot(dx, dy) - radius) > 1e-6:
                failures.append(f"{where}: ring not circular")
            if 0 < deg < 180 and dx <= 0 or 180 < deg < 360 and dx >= 0:
                failures.append(f"{where}: wrong side left/right")
            if (deg < 90 or deg > 270) and dy >= 0 or 90 < deg < 270 and dy <= 0:
                failures.append(f"{where}: wrong side ahead/behind")
    return cases, failures, len(sizes)


def main():
    real = pure_block(SOURCE)
    cases, failures, sizes = run(real)
    for line in failures[:10]:
        print("FAIL", line)
    caught = 0
    for name, (before, after) in FAULTS.items():
        if before not in SOURCE:
            print(f"FAULT TARGET MISSING: {name}")
            continue
        try:
            _, planted, _ = run(pure_block(SOURCE.replace(before, after)))
        except Exception as error:  # a fault that crashes the block is caught too
            planted = [str(error)]
        caught += bool(planted)
        print(f"planted fault '{name}': {'caught' if planted else 'NOT CAUGHT'} ({len(planted)} failures)")
    print(f"gunfire cue: {cases} cases over {sizes} viewports, {len(failures)} failures, {caught}/{len(FAULTS)} faults caught")
    sys.exit(0 if not failures and caught == len(FAULTS) else 1)


if __name__ == "__main__":
    main()
