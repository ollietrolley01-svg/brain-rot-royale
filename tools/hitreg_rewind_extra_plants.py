"""More planted faults for tools/hitreg_rewind_check.py, written by someone who did not write the rewind.

Each plant breaks ServerScriptService/Modules/LagCompensation.lua in memory (the file on disk is never
touched) and runs hitreg_rewind_check's own dynamic rows against it. A plant that no row fails is a
hole in that check's coverage, and is printed as MISSED with what it shows.

    python tools/hitreg_rewind_extra_plants.py .

Then the same plants against a VARIANT of the check's harness in which the victim A-D strafes
(reversing every 0.15 s) and turns at 3 rad/s, instead of crossing in a straight line facing one way.
Straight constant-speed motion interpolates exactly between ANY two samples, and a victim who never
turns makes `past * now:Inverse()` and `now:Inverse() * past` the same transform, so two kinds of
fault are invisible to the check as written. The variant keeps only the check's "strafing ..." rows
(the geometry and headshot rows); its wall rows assume straight-line motion.

Exit status: 1 if the UNPLANTED module fails the variant (a real bug), else 0. MISSED here is a
finding about the check's coverage, not a failure of the game.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hitreg_rewind_check as check  # noqa: E402

PLANTS = [
    # GetNetworkPing is round trip (Roblox docs); a builder who read it as one-way would halve the rewind.
    ("rewind by half the ping (ping read as one-way)", [("return arrival - ping", "return arrival - ping / 2")]),
    # Walk the ring forwards from the newest sample: reads the OLDEST samples first.
    ("walk the ring the wrong way", [("index = (index - 2) % count + 1", "index = index % count + 1")]),
    # Take the older neighbour and don't blend: up to one Heartbeat (~0.3 studs at 18 studs/s) stale.
    ("no interpolation (older sample as-is)", [("return sample.cframe:Lerp(newerCFrame, (at - sample.t) / span)", "return sample.cframe")]),
    # Blend with the fraction reversed.
    ("interpolation fraction reversed", [("(at - sample.t) / span)", "(newerT - at) / span)")]),
    # 6 samples is 83 ms at 60 Hz: shorter than the 200 ms cap.
    ("ring shorter than the cap (6 samples)", [("LagCompensation.Samples = 20", "LagCompensation.Samples = 6")]),
    # Stamp the ring with os.clock while RewindTime/RootAt read GetServerTimeNow: two timebases.
    ("record on a different clock (os.clock)", [("LagCompensation.Record(LagCompensation.Now())", "LagCompensation.Record(os.clock())")]),
    # Carry the parts with the transforms multiplied the wrong way round. Identical for a pure
    # translation; wrong as soon as the victim has turned between then and now.
    ("carry composed in the wrong order", [("local carry = past * root.CFrame:Inverse()", "local carry = root.CFrame:Inverse() * past")]),
    # Leave the parts where they are now and only move... nothing: test the boxes at the live pose.
    ("boxes tested at the live pose", [("rayBox(origin, vector, carry * part.CFrame, part.Size)", "rayBox(origin, vector, part.CFrame, part.Size)")]),
    # A reach too small to include the head (1.8 studs above the root in the mock rig).
    ("reach too small for the head (1 stud)", [("LagCompensation.Reach = 8", "LagCompensation.Reach = 1")]),
    # The cap compared in milliseconds: every real ping (0.03-0.2 s) passes, and so does 0.25.
    ("cap in the wrong unit (200 instead of 0.2)", [("LagCompensation.Cap = 0.2", "LagCompensation.Cap = 200")]),
]


# The check's harness, with the victim's path swapped for MOTION. Each anchor must still be found.
VARIANT = [
    ("local STEP = 1 / 60\n",
     "local STEP = 1 / 60\n"
     "local function MOTION(speed, t)\n"
     "    local period = 0.3\n"
     "    local phase = (t % period) / period\n"
     "    local tri = phase < 0.5 and phase * 2 or 2 - phase * 2\n"
     "    return CFrame.new(-6 + speed * period / 2 * tri, 3, -40) * CFrame.fromYaw(3 * t)\n"
     "end\n"),
    ('rawget(root, "_props").CFrame = CFrame.new(-6 + opts.speed * t, 3, -40)',
     'rawget(root, "_props").CFrame = MOTION(opts.speed, t)'),
    ("Vector3.new(-6 + opts.speed * seen, 3, -40)", "MOTION(opts.speed, seen).Position"),
]


def variant(root, plant=None):
    lua = check.LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(check.read(root, "tools", "hitreg_mocks.lua"))
    harness = check.HARNESS
    for before, after in VARIANT:
        if before not in harness:
            sys.exit("hitreg_rewind_extra_plants: harness anchor missing: " + before)
        harness = harness.replace(before, after, 1)
    run = lua.execute("return function(...) " + harness + " end")
    rows = run(mocks, check.load_lag(root, plant), check.walk_speed(root))
    return [(bool(r["ok"]), r["line"]) for r in rows.values() if str(r["line"]).startswith("strafing")]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    caught = 0
    for name, plant in PLANTS:
        rows = check.dynamic(root, plant)
        failed = [line for ok, line in rows if not ok]
        print(("CAUGHT  " if failed else "MISSED  ") + name + (("  <- " + failed[0]) if failed else ""))
        caught += bool(failed)
    print("hitreg_rewind_extra_plants: %d of %d caught by hitreg_rewind_check's %d dynamic rows" % (caught, len(PLANTS), len(check.dynamic(root))))

    print("\n-- variant harness: A-D strafe + turning victim --")
    clean = variant(root)
    for ok, line in clean:
        print(("ok    " if ok else "FAIL  ") + line)
    bad = sum(1 for ok, _ in clean if not ok)
    print("unplanted LagCompensation on the variant: %d rows, %d failed" % (len(clean), bad))
    vcaught = 0
    for name, plant in PLANTS:
        failed = [line for ok, line in variant(root, plant) if not ok]
        print(("CAUGHT  " if failed else "MISSED  ") + name + (("  <- " + failed[0]) if failed else ""))
        vcaught += bool(failed)
    print("hitreg_rewind_extra_plants (variant): %d of %d caught" % (vcaught, len(PLANTS)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
