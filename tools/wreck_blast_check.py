"""The wreck blast (VehicleWreckFx.OnWreck): one blast per wreck, at the moment it happens, at any range.

Runs the game's REAL code in lupa (tools/wreck_blast_world.lua is the stand-in client): VehicleWreckFx
whole, ProjectileClient's OnWreck hook and its BLAST_CULL, and VehicleClient's track / watchFolder /
lampsOf / updateLamps and its vehicle Stepped loop (the range-gated one), each cut from the real file.
A vehicle is a model in the map's Vehicles folder with a Chassis part; the camera is the player.

The invariants:
  A. A vehicle wrecked at 50, 400 or 2000 studs blasts exactly once, in the frame Wrecked turns true, and
     never again when the player later walks up to it, leaves, and comes back. Heard at every range
     (Sfx.Blast does its own falloff); drawn only inside BLAST_CULL, like every other blast.
     Its smoke keeps VehicleClient's range gate: on within a frame when near, not before the player
     comes within ANIMATE_DISTANCE when far.
  B. A vehicle seen whole up close, left behind (920 studs), wrecked, and returned to 120 s later blasts
     once, at the wreck (PR #48's F2: it used to blast at the return).
  C. A vehicle that arrives already wrecked (streamed in, joined late, or wrecked while streamed out)
     never blasts, near or far, however long the player stays or wherever they go.
  D. Wrecks and respawns: a second server write of Wrecked = true adds nothing; a respawned base vehicle
     (a new model) blasts at its own wreck. A vehicle streamed out and in (or re-parented) while whole
     blasts once when wrecked.
  E. VehicleWreckFx.Watch called again for a model already watched adds no second blast.

    python tools/wreck_blast_check.py .               the checks (exit 1 on any failure)
    python tools/wreck_blast_check.py . --plant       the planted faults; every one must be caught
    python tools/wreck_blast_check.py . --before REF  the same checks on REF's files (e.g. origin/main); report only

Not covered: how the blast looks or sounds (a render and a listen on Oliver's machine), real streaming
and replication timing, and the Studio client itself: the world is a recorder, not an engine.
"""
import re
import subprocess
import sys
from pathlib import Path

from lupa import LuaRuntime

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
ROOT = Path(ARGS[0] if ARGS else ".")
FRAME = 1 / 60

FILES = {
    "wreck": "ReplicatedStorage/Shared/VehicleWreckFx.lua",
    "vehicle": "StarterPlayerScripts/VehicleClient.client.lua",
    "projectile": "StarterPlayerScripts/ProjectileClient.client.lua",
}

# Each plant breaks one invariant in the real text; the check must fail for every one of them.
WATCH_IN_TRACK = "\trigs[model] = false\n\t-- Its blast goes off the moment it's wrecked, however far away (the loop below is range-gated).\n\tVehicleWreckFx.Watch(model)\n"
PLANTS = [
    ("track() stops watching (no vehicle ever blasts)", "vehicle", WATCH_IN_TRACK, "\trigs[model] = false\n"),
    ("the watch moves into the range-gated loop (a far wreck never blasts)", "vehicle", [
        (WATCH_IN_TRACK, "\trigs[model] = false\n"),
        ("\tVehicleWreckFx.SetSmoke(model, wrecked)\n", "\tVehicleWreckFx.Watch(model)\n\tVehicleWreckFx.SetSmoke(model, wrecked)\n")]),
    ("a second Watch connects again (two blasts)", "wreck", "\tif watched[model] then\n\t\treturn\n\tend\n", ""),
    ("the per-frame smoke path blasts too", "wreck", "function VehicleWreckFx.SetSmoke(model, wrecked)\n",
     "function VehicleWreckFx.SetSmoke(model, wrecked)\n\tif wrecked and VehicleWreckFx.OnWreck then\n\t\tVehicleWreckFx.OnWreck(model)\n\tend\n"),
    ("a vehicle already wrecked when first seen blasts", "wreck", "\tif watched[model] then\n\t\treturn\n\tend\n",
     "\tif watched[model] then\n\t\treturn\n\tend\n\tif model:GetAttribute(\"Wrecked\") == true and VehicleWreckFx.OnWreck then\n\t\tVehicleWreckFx.OnWreck(model)\n\tend\n"),
    ("the blast goes off a second after the wreck", "wreck", "\t\t\tVehicleWreckFx.OnWreck(model)\n\t\tend\n\tend)\n",
     "\t\t\ttask.delay(1, VehicleWreckFx.OnWreck, model)\n\t\tend\n\tend)\n"),
    ("the blast is drawn at any range", "projectile",
     "\t\tif (chassis.Position - camera.CFrame.Position).Magnitude < BLAST_CULL then\n", "\t\tif true then\n"),
    ("smoke loses its range gate", "vehicle", "local ANIMATE_DISTANCE = 320\n", "local ANIMATE_DISTANCE = 100000\n"),
]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def git_show(ref, rel):
    out = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{rel}"], capture_output=True, check=True)
    return out.stdout.decode("utf-8").replace("\r\n", "\n")


def sources(ref=None, plant=None):
    srcs = {k: (git_show(ref, v) if ref else read(v)) for k, v in FILES.items()}
    if plant:
        _, key, *swap = plant
        swaps = swap[0] if isinstance(swap[0], list) else [tuple(swap)]
        for before, after in swaps:
            if srcs[key].count(before) != 1:
                sys.exit("wreck_blast_check: plant anchor missing or not unique in %s: %r" % (key, before[:80]))
            srcs[key] = srcs[key].replace(before, after, 1)
    return srcs


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w\.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def cut(src, head, tail="\nend\n"):
    if src.count(head) != 1:
        sys.exit("wreck_blast_check: anchor missing or not unique: %r" % head[:80])
    a = src.index(head)
    return src[a:src.index(tail, a) + len(tail)]


def const(src, name):
    m = re.search(r"^local %s = .*$" % name, src, re.M)
    if not m:
        sys.exit("wreck_blast_check: no `local %s` in the file" % name)
    return m.group(0) + "\n"


def chunks(srcs):
    v = srcs["vehicle"]
    vehicle = ("local VehicleWreckFx, VehicleDynamics, RunService, camera, poseRiders, updateEngine = ...\n"
               "local rigs, driving, frameCount, lamps = {}, nil, 0, {}\n"
               + const(v, "ANIMATE_DISTANCE") + const(v, "FULL_RATE_DISTANCE")
               + cut(v, "local function track(model)") + cut(v, "local function watchFolder(folder)")
               + cut(v, "local function lampsOf(model)") + cut(v, "local function updateLamps(model, distance)")
               + cut(v, "RunService.Stepped:Connect(function(_, dt)\n\tframeCount += 1", "\nend)\n")
               + "return watchFolder\n")
    p = srcs["projectile"]
    projectile = ("local VehicleWreckFx, ExplosiveFx, Sfx, camera = ...\n" + const(p, "BLAST_CULL")
                  + cut(p, "VehicleWreckFx.OnWreck = function(model)"))
    return luau_to_lua(srcs["wreck"]), luau_to_lua(vehicle), luau_to_lua(projectile)


def scenario(srcs, body):
    """Runs `body` (Lua, with W the world) on a fresh client; returns the world."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    world = lua.execute(read("tools/wreck_blast_world.lua"))
    wreck, vehicle, projectile = chunks(srcs)
    W = world.new(lua.compile(wreck), lua.compile(vehicle), lua.compile(projectile))
    lua.globals().W = W
    lua.execute(body)
    return W


def blasts(W):
    t = W.blasts
    return [dict(t=t[i].t, id=t[i].id, drawn=bool(t[i].drawn), heard=t[i].heard, distance=t[i].distance)
            for i in range(1, len(t) + 1)]


def at_wreck(b, when):
    """In the frame of the wreck: the first frame at or after `when`."""
    return when - 1e-9 <= b["t"] < when + FRAME + 1e-9


def fmt_blasts(bs):
    return "none" if not bs else ", ".join("#%d at %.2f s%s%s" % (b["id"], b["t"], " drawn" if b["drawn"] else "",
                                                                   " heard" if b["heard"] else "") for b in bs)


COUNTS = {"vehicles": 0, "wrecks": 0, "frames": 0}


def tally(W, vehicles, wrecks):
    COUNTS["vehicles"] += vehicles
    COUNTS["wrecks"] += wrecks
    COUNTS["frames"] += round(W.clock / FRAME)


# ------------------------------------------------------------------------------------------ the checks
def check_a(srcs):
    rows = []
    for d in (50, 400, 2000):
        W = scenario(srcs, f"""
            local car = W.vehicle({d}, false)
            W.at(10, function() W.wreck(car) end)
            W.at(20, function() W.camera({d} - 30) end)  -- walk up to it
            W.at(30, function() W.camera(0) end)         -- leave
            W.at(40, function() W.camera({d} - 30) end)  -- and come back
            W.run(50)
        """)
        tally(W, 1, 1)
        bs = blasts(W)
        smoke = W.smoke[1]
        once = len(bs) == 1 and at_wreck(bs[0], 10)
        look = once and bs[0]["drawn"] == (d < 650) and bs[0]["heard"] == "ExplosionVehicle"
        smoke_ok = smoke is not None and (smoke <= 10 + 2 * FRAME if d < 320 else 20 - 1e-9 <= smoke <= 20 + 2 * FRAME)
        rows.append((once, "A %4d studs: one blast in the wreck's frame (10.00 s), none on the walk-up: %s" % (d, fmt_blasts(bs))))
        rows.append((look, "A %4d studs: heard always, drawn only inside BLAST_CULL (650): %s" % (d, fmt_blasts(bs))))
        rows.append((smoke_ok, "A %4d studs: smoke keeps its 320-stud gate: first on at %s (want %s)" % (
            d, "never" if smoke is None else "%.2f s" % smoke, "10.00-10.03 s" if d < 320 else "20.00-20.03 s, when the player comes near")))
    return rows


def check_b(srcs):
    W = scenario(srcs, """
        local car = W.vehicle(20, false)
        W.at(5, function() W.camera(-900) end)
        W.at(10, function() W.wreck(car) end)
        W.at(130, function() W.camera(0) end)
        W.run(140)
    """)
    tally(W, 1, 1)
    bs = blasts(W)
    return [(len(bs) == 1 and at_wreck(bs[0], 10),
             "B seen whole, left 920 studs behind, wrecked at 10 s, returned to at 130 s: %s" % fmt_blasts(bs))]


def check_c(srcs):
    W = scenario(srcs, """
        W.vehicle(20, true)                               -- #1 already a wreck, near
        W.vehicle(400, true)                              -- #2 already a wreck, far
        local car = W.vehicle(60, false)                  -- #3 whole, streamed out, wrecked out there
        W.at(5, function() W.streamOut(car) end)
        W.at(20, function() W.streamIn(car, true) end)    -- back in: already a wreck
        W.at(30, function() W.camera(380) end)
        W.at(40, function() W.camera(0) end)
        W.run(50)
    """)
    tally(W, 3, 1)
    bs = blasts(W)
    near_smoke = W.smoke[1]
    return [(not bs, "C three vehicles already wrecked on arrival (20, 400 studs; one wrecked while streamed out): "
                     "blasts %s (want none)" % fmt_blasts(bs)),
            (near_smoke is not None and near_smoke <= 2 * FRAME,
             "C an already-wrecked vehicle still smokes: first on at %s" % ("never" if near_smoke is None else "%.2f s" % near_smoke))]


def check_d(srcs):
    W = scenario(srcs, """
        local a = W.vehicle(30, false)                    -- #1
        W.at(10, function() W.wreck(a) end)
        W.at(11, function() W.wreck(a) end)               -- the server's second write (chassis-gone path)
        W.at(20, function() a:Destroy() end)              -- ModeTeams clears the wreck...
        W.at(25, function() W.vehicle(30, false, 2) end)  -- ...and respawns a new model, #2
        W.at(40, function() W.wreck(W.models[2]) end)
        local c = W.vehicle(500, false, 3)                -- #3 streamed out and in, then re-parented, while whole
        W.at(3, function() W.streamOut(c) end)
        W.at(4, function() c = W.streamIn(c, false) end)
        W.at(5, function() W.detach(c) end)
        W.at(6, function() W.attach(c) end)
        W.at(15, function() W.wreck(c) end)
        W.run(50)
    """)
    tally(W, 4, 4)
    bs = blasts(W)
    by = {i: [b for b in bs if b["id"] == i] for i in (1, 2, 3)}
    return [(len(by[1]) == 1 and at_wreck(by[1][0], 10), "D a wreck written twice by the server: %s (want one, 10 s)" % fmt_blasts(by[1])),
            (len(by[2]) == 1 and at_wreck(by[2][0], 40), "D the respawned model's own wreck: %s (want one, 40 s)" % fmt_blasts(by[2])),
            (len(by[3]) == 1 and at_wreck(by[3][0], 15),
             "D streamed out/in and re-parented while whole, then wrecked: %s (want one, 15 s)" % fmt_blasts(by[3]))]


def check_e(srcs):
    W = scenario(srcs, """
        local car = W.vehicle(30, false)
        W.at(1, function() W.VehicleWreckFx.Watch(car) W.VehicleWreckFx.Watch(car) end)
        W.at(10, function() W.wreck(car) end)
        W.run(20)
    """)
    tally(W, 1, 1)
    bs = blasts(W)
    return [(bool(W.hooked), "E ProjectileClient sets VehicleWreckFx.OnWreck"),
            (len(bs) == 1 and at_wreck(bs[0], 10), "E Watch called twice more for the same model: %s (want one)" % fmt_blasts(bs))]


CHECKS = [check_a, check_b, check_c, check_d, check_e]


def run(srcs):
    rows = []
    for check in CHECKS:
        try:
            rows += check(srcs)
        except Exception as problem:  # a tree without the API (the --before run) reports, not crashes
            rows.append((False, "%s could not run: %s" % (check.__name__, str(problem).splitlines()[0][:160])))
    return rows


def main():
    if "--plant" in sys.argv:
        caught = 0
        for plant in PLANTS:
            failed = [line for ok, line in run(sources(plant=plant)) if not ok]
            print(("CAUGHT  " if failed else "MISSED  ") + plant[0] + (("  <- " + failed[0]) if failed else ""))
            caught += bool(failed)
        print("wreck_blast_check plants: %d of %d caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    ref = sys.argv[sys.argv.index("--before") + 1] if "--before" in sys.argv else None
    rows = run(sources(ref=ref))
    for ok, line in rows:
        print(("ok    " if ok else "FAIL  ") + line)
    failed = sum(1 for ok, _ in rows if not ok)
    print("examined: %d vehicles, %d wreck events, %d frames at 60 Hz" % (COUNTS["vehicles"], COUNTS["wrecks"], COUNTS["frames"]))
    print("wreck blast check%s: %d checks, %d failed" % (" on " + ref if ref else "", len(rows), failed))
    sys.exit(0 if ref or not failed else 1)


if __name__ == "__main__":
    main()
