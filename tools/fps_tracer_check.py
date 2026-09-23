"""#30 tracer visibility check: runs the real TRACER_* constants and GunFx.TracerWidthScale /
GunFx.TracerFade out of StarterPlayerScripts/GunFx.lua under lupa and checks what a player sees.

Invariants (on-screen pixels at 1080p, FOV 70):
  1. a rifle tracer's glow is never under the 3px floor out to where the widening caps;
  2. near tracers are never resized (scale exactly 1 where the base width already reads);
  3. widening stays within [1, 5], so a far tracer cannot become a rod;
  4. the widening is the same for every kind, so per-kind character (heavy fatter than pellet) holds;
  5. a streak lingers after arriving for 3-9 frames at 60 fps, then goes (nil).
Each run also plants three faults in a copy of the source and demands the check fail on each.

    python3 tools/fps_tracer_check.py .
"""
import math
import sys
from pathlib import Path

from lupa import LuaRuntime

FAULTS = [
    ("narrows near tracers", "math.max(TRACER_MIN_GLOW_PX / glowPixels, 1)", "TRACER_MIN_GLOW_PX / glowPixels"),
    ("no widening cap", "local TRACER_MAX_WIDEN = 5", "local TRACER_MAX_WIDEN = 60"),
    ("no afterglow", "local TRACER_AFTERGLOW = 0.08", "local TRACER_AFTERGLOW = 0"),
]


def section(src):
    start = src.index("local TRACER_CORE, TRACER_GLOW, TRACER_STREAK")
    end = src.index("local TRACER = {")
    kinds = src[end:src.index("GunFx.TracerKinds = TRACER")]
    return ("local GunFx = {}\n" + src[start:end] + "\n" + kinds
            + "\nreturn GunFx, TRACER_GLOW, TRACER\n")


def check(src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("Color3 = { fromRGB = function() return 0 end }"
                " Enum = { Material = setmetatable({}, { __index = function() return 0 end }) }")
    gunfx, glow_mult, kinds = lua.execute(section(src))
    scale, fade = gunfx.TracerWidthScale, gunfx.TracerFade
    px = 1080 / (2 * math.tan(math.radians(70) / 2))  # pixels per stud at one stud away
    fails, examined = [], 0
    base_glow = kinds.bullet.glow * glow_mult
    ratio = kinds.heavy.glow / kinds.pellet.glow
    for d in range(1, 1001):
        examined += 1
        s = scale(d, px)
        seen = base_glow * s * px / d
        if s < 1 - 1e-9 or s > 5 + 1e-9:
            fails.append(f"scale {s:.3f} at {d} studs is outside [1, 5]")
        if base_glow * px / d >= 3 and abs(s - 1) > 1e-9:
            fails.append(f"near tracer at {d} studs resized (scale {s:.3f})")
        if s < 5 - 1e-9 and seen < 3 - 1e-6:
            fails.append(f"glow {seen:.2f}px at {d} studs, under the 3px floor")
        if abs((kinds.heavy.glow * s) / (kinds.pellet.glow * s) - ratio) > 1e-9:
            fails.append(f"kind ratio changed at {d} studs")
    frames, t = 0, 0.0
    while fade(t) is not None and frames < 1000:
        f = fade(t)
        if not (0 < f <= 1):
            fails.append(f"fade {f} at {t:.3f}s outside (0, 1]")
        frames += 1
        t += 1 / 60
    if not (3 <= frames <= 9):
        fails.append(f"afterglow lasts {frames} frames at 60 fps, want 3-9")
    return fails, examined, frames


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    src = (root / "StarterPlayerScripts/GunFx.lua").read_text()
    fails, examined, frames = check(src)
    print(f"tracer check: {examined} distances examined, afterglow {frames} frames, {len(fails)} failures")
    for f in fails[:10]:
        print("  FAIL", f)
    ok = not fails
    for name, before, after in FAULTS:
        if before not in src:
            print(f"  planted fault '{name}': anchor text missing from GunFx.lua")
            ok = False
            continue
        planted, _, _ = check(src.replace(before, after))
        print(f"  planted fault '{name}': {'caught' if planted else 'NOT CAUGHT'} ({len(planted)} failures)")
        ok = ok and bool(planted)
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
