"""The gunner's aim holds its world direction when the car turns (Jacob 09-25: "make the gunner aim not
turn with the car"), without Studio.

Runs the REAL StarterPlayerScripts/GunnerView.lua (GunnerView.Start, view:Update, view:AimPoint) with
the real ReplicatedStorage/Shared/VehicleWeaponData.lua under lupa, on tools/gunner_aim_world_mocks.lua's
stand-in turret. For every turret spec, plus the roof gun cut down to a 60-degree arc:

  1. the mouse lays the gun (a real mouse delta through view:look), then goes still;
  2. the chassis yaws at 90 deg/s for 2 s while pitching and rolling over bumps, the mouse still;
  3. every frame the barrel's world direction (view:AimPoint) is compared with where it should be: the
     first world direction, held to the arc as seen from the chassis now (VehicleWeaponData.PitchFloor,
     yawLimit, pitchMax). The camera's look is compared with the barrel (the hip view looks down it).

Holds:
  HOLD    the barrel stays within 0.5 deg of that direction, every frame the aim has been clear of the
          arc's limits for 0.5 s (at a limit, and slewing back from one, it moves at its slew rate)
  RETURN  the chassis stopped and level, the barrel is back within 0.5 deg of it: a limit (the arc's
          edge, a pitch floor under a bump) held the gun back but didn't move the aim
  CAMERA  the hip camera looks within 0.5 deg of the barrel (not the mortar: it looks at the landing)
  ARC     the turret's own angles never leave the arc (|yaw| <= yawLimit, floor <= pitch <= pitchMax)
  STEER   with the chassis turned, 100 px of mouse still turns the barrel 22 deg in the world

    python3 tools/gunner_aim_world_check.py .            the checks
    python3 tools/gunner_aim_world_check.py . --plant    the planted faults; every one must be caught
    python3 tools/gunner_aim_world_check.py . --before REF   the same numbers for GunnerView at a git ref

NOT covered: GunnerView.Start's reading of a real VehicleModels turret (the rig is a stand-in; only the
directions are measured), the server's VehicleWeapons, and everyone else's view of the turret
(VehicleWeaponClient.swingMount, from the 10 Hz aim attributes).
"""

import math
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lupa import LuaRuntime  # noqa: E402
import hud_layout_check as hud  # noqa: E402

FPS = 60
TURN_RATE = 90.0  # deg/s the chassis yaws
TURN_TIME = 2.0
TOL = 0.5  # degrees
SETTLE = 30  # frames (0.5 s) the turret is given to slew back after the aim was at a limit


def value_types(root):
    text = open(os.path.join(root, "tools", "destruct_mocks.lua"), encoding="utf-8").read()
    m = re.search(r"(-- Vector3 -+\n.*?)-- Colours", text, re.S)
    if not m:
        raise SystemExit("tools/destruct_mocks.lua: no Vector3..Colours section to borrow")
    return m.group(1)


def world(root, gunner_src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = open(os.path.join(root, "tools", "gunner_aim_world_mocks.lua"), encoding="utf-8").read()
    M = lua.execute(value_types(root) + "\n" + mocks)
    weapons = open(os.path.join(root, "ReplicatedStorage/Shared/VehicleWeaponData.lua"), encoding="utf-8").read()
    data = M.load("VehicleWeaponData", hud.luau_to_lua(weapons))
    view_mod = M.load("GunnerView", hud.luau_to_lua(gunner_src))
    return lua, M, data, view_mod


def angle_between(a, b):
    dot = (a.X * b.X + a.Y * b.Y + a.Z * b.Z) / (a.Magnitude * b.Magnitude)
    return math.degrees(math.acos(max(-1.0, min(1.0, dot))))


def world_yaw(d):
    return math.degrees(math.atan2(-d.X, -d.Z))


def run_spec(lua, M, data, view_mod, name, spec):
    """One spec through lay, turn and steer. Returns (problems, stats)."""
    problems = []
    Vector3 = lua.globals().Vector3
    turn = lua.eval("function(base, p, y, r) return base * CFrame.Angles(p, y, r) end")
    rest_of = lua.eval("function(v) return v.yawJoint.Part0.CFrame * v.yawJoint.C0 end")
    vehicle, chassis = M.rig()
    view = view_mod.Start(vehicle, spec, lua.table_from({"guiParent": lua.eval("{}")}))
    if view is None:
        return [f"{name}: GunnerView.Start gave no view on the rig"], {}
    dt = 1 / FPS
    base = chassis.CFrame

    def expected(rest, w):
        """World direction `w` as seen from the chassis's `rest` frame, held to the arc (the check's own
        maths; only VehicleWeaponData.PitchFloor is shared). Returns it in the world, and whether the
        arc held it."""
        loc = rest.VectorToObjectSpace(rest, w)
        want_y = math.degrees(math.atan2(-loc.X, -loc.Z))
        want_p = math.degrees(math.asin(max(-1.0, min(1.0, loc.Y / loc.Magnitude))))
        held_y = want_y if limit >= 180 else max(-limit, min(limit, want_y))
        floor = math.degrees(data.PitchFloor(spec, math.radians(held_y)))
        held_p = max(floor, min(spec.pitchMax, want_p))
        y, p = math.radians(held_y), math.radians(held_p)
        world_dir = rest.VectorToWorldSpace(rest, Vector3.new(-math.sin(y) * math.cos(p), math.sin(p),
                                                               -math.cos(y) * math.cos(p)))
        return world_dir, abs(held_y - want_y) > 1e-6 or abs(held_p - want_p) > 1e-6

    def frame(yaw_deg=0.0, bump=0.0):
        chassis.CFrame = turn(base, math.radians(8) * math.sin(bump * 3.1), math.radians(yaw_deg),
                              math.radians(6) * math.sin(bump * 4.7))
        view.Update(view, dt, lua.table_from({"ready": True}))

    # 1. Lay the gun with the mouse: 30 deg left (20 on a short arc), pitch a little up, within its limits.
    limit = spec.yawLimit
    lay_yaw = 30.0 if limit >= 180 else 20.0
    lay_pitch = max(spec.pitchMin + 5, min(6.0, spec.pitchMax - 5))
    rest_pitch = spec.restPitch or 0
    M.setMouse(-lay_yaw / view_mod.Pure.MouseDegrees, -(lay_pitch - rest_pitch) / view_mod.Pure.MouseDegrees)
    frame()
    M.setMouse(0, 0)
    for _ in range(int(1.5 * FPS)):
        frame()
    _, _, w0 = view.AimPoint(view)
    laid = world_yaw(w0)
    if abs(laid - lay_yaw) > 1.0:
        problems.append(f"{name}: the mouse laid the gun to {laid:.1f} deg, wanted {lay_yaw:.1f}")

    # 2. The chassis turns under the still mouse.
    hold_worst = cam_worst = 0.0
    arc_worst = 0.0
    pinned_frames = held_frames = 0
    clear = SETTLE  # frames since the aim was last at a limit
    lobs = view_mod.Pure.lobs(spec)
    frames = int(TURN_TIME * FPS)
    turn_to = TURN_RATE * TURN_TIME if limit >= 180 else 120.0
    for i in range(1, frames + 1):
        yaw_deg = turn_to * i / frames
        frame(yaw_deg, i * dt)
        _, _, d = view.AimPoint(view)
        # Where it should point: the first world direction, in the chassis frame now, held to the arc.
        expect, pinned = expected(rest_of(view), w0)
        clear += 1
        if pinned:
            pinned_frames += 1
            clear = 0
        # At a limit, or slewing back from one (up to SETTLE frames), the turret moves at its slew rate:
        # ARC holds it there, and RETURN below that it gets back.
        if clear >= SETTLE:
            held_frames += 1
            hold_worst = max(hold_worst, angle_between(d, expect))
        if not lobs:
            cam_worst = max(cam_worst, angle_between(M.camera.CFrame.LookVector, d))
        floor = math.degrees(data.PitchFloor(spec, math.radians(view.yaw)))
        out = max(abs(view.yaw) - limit if limit < 180 else 0.0, floor - view.pitch, view.pitch - spec.pitchMax, 0.0)
        arc_worst = max(arc_worst, out)
    if hold_worst > TOL:
        problems.append(f"HOLD {name}: the barrel strayed {hold_worst:.2f} deg from its world aim while the car turned")
    if cam_worst > TOL:
        problems.append(f"CAMERA {name}: the hip view looked {cam_worst:.2f} deg off the barrel")
    if arc_worst > 1e-3:
        problems.append(f"ARC {name}: the turret went {arc_worst:.3f} deg outside its arc")

    # RETURN: the chassis still and level, the gun is back on the first world aim (held to the arc) --
    # the limits it met on the way held it back, they didn't move the aim.
    for _ in range(int(1.0 * FPS)):
        frame(turn_to, 0)
    _, _, before = view.AimPoint(view)
    back = angle_between(before, expected(rest_of(view), w0)[0])
    if back > TOL:
        problems.append(f"RETURN {name}: at rest after the turn the barrel is {back:.2f} deg off its world aim")

    # 3. The mouse still steers with the chassis turned: 100 px left is 22 deg left in the world.
    M.setMouse(-100, 0)
    frame(turn_to, 0)
    M.setMouse(0, 0)
    for _ in range(int(1.5 * FPS)):
        frame(turn_to, 0)
    _, _, after = view.AimPoint(view)
    turned = (world_yaw(after) - world_yaw(before) + 180) % 360 - 180
    want_turn = 100 * view_mod.Pure.MouseDegrees
    steer_ok = True
    if limit >= 180 and abs(turned - want_turn) > TOL:
        steer_ok = False
        problems.append(f"STEER {name}: 100 px of mouse turned the barrel {turned:.2f} deg, want {want_turn:.2f}")
    if limit < 180 and abs(turned) < 1.0 and abs(view.yaw) < limit - 1e-3:
        steer_ok = False
        problems.append(f"STEER {name}: 100 px of mouse turned the barrel {turned:.2f} deg on a short arc")
    view.Stop(view)
    stats = {"held": held_frames, "back": back, "hold": hold_worst, "camera": cam_worst, "arc": arc_worst, "pinned": pinned_frames,
             "frames": frames, "turn": turn_to, "steer": turned, "steer_ok": steer_ok}
    return problems, stats


def check(root, gunner_src, verbose=True):
    lua, M, data, view_mod = world(root, gunner_src)
    specs = []
    for model in sorted(data.ByModel.keys()):
        specs.append((f"{model} {data.ByModel[model]}", data.ForModel(model, "turret")))
    # The roof gun on a 60-degree arc: the edge must push the aim round, never let it past.
    short = lua.eval("function(s) local c = {} for k, v in pairs(s) do c[k] = v end c.yawLimit = 60 return c end")(
        data.Weapons.RotsterRoofGun)
    specs.append(("RotsterRoofGun cut to a 60-deg arc", short))
    problems = []
    for name, spec in specs:
        found, stats = run_spec(lua, M, data, view_mod, name, spec)
        problems += found
        if verbose and stats:
            print(f"  {name}: chassis turned {stats['turn']:.0f} deg over {stats['frames']} frames; "
                  f"barrel off its world aim at worst {stats['hold']:.3f} deg over {stats['held']} frames clear of "
                  f"a limit, {stats['back']:.3f} deg at rest after; camera off the barrel "
                  f"{stats['camera']:.3f} deg; outside the arc {stats['arc']:.3f} deg; aim pinned to the arc's "
                  f"edge {stats['pinned']} frames; 100 px of mouse turned it {stats['steer']:.2f} deg")
    return problems, len(specs)


def mutate(src, old, new, count=1):
    if src.count(old) != count:
        raise SystemExit(f"planted fault is stale: {old!r} found {src.count(old)} times, want {count}")
    return src.replace(old, new)


TURRET_CARRY = "\tif self.lastRest then\n\t\tself.yaw, self.pitch = Pure.clampLook("
HAND_SET = "local handSet = self.aimWorld == nil or self.wantYaw ~= self.leftYaw or self.wantPitch ~= self.leftPitch"
PLANTS = [
    ("nothing held in the world (origin/main before this fix)",
     lambda s: mutate(mutate(s, TURRET_CARRY, TURRET_CARRY.replace("self.lastRest", "false")),
                      HAND_SET, "local handSet = true")),
    ("the wanted aim left on the chassis (only the turret carried)",
     lambda s: mutate(s, HAND_SET, "local handSet = true")),
    ("the turret not carried (it lags the turn by its slew)",
     lambda s: mutate(s, TURRET_CARRY, TURRET_CARRY.replace("self.lastRest", "false"))),
    ("Pure.anglesIn turning the wrong way",
     lambda s: mutate(s, "local d = rest:VectorToObjectSpace(world)", "local d = rest:VectorToWorldSpace(world)")),
    ("the carried turret not held to the arc",
     lambda s: mutate(s, "self.yaw, self.pitch = Pure.clampLook(self.spec, Pure.anglesIn(restNow, Pure.worldOf(self.lastRest, self.yaw, self.pitch)))",
                      "self.yaw, self.pitch = Pure.anglesIn(restNow, Pure.worldOf(self.lastRest, self.yaw, self.pitch))")),
    ("the aim dragged by the arc's limits (a bump ratchets it up the pitch floor)",
     lambda s: mutate(s, "if handSet or self.wantYaw ~= heldYaw or self.wantPitch ~= heldPitch then", "if true then")),
    ("the mouse ignored",
     lambda s: mutate(s, "local delta = UserInputService:GetMouseDelta()", "local delta = Vector2.new(0, 0)")),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    path = os.path.join(root, "StarterPlayerScripts", "GunnerView.lua")
    src = open(path, encoding="utf-8").read()
    if "--before" in sys.argv:
        ref = sys.argv[sys.argv.index("--before") + 1]
        old = subprocess.run(["git", "-C", root, "show", f"{ref}:StarterPlayerScripts/GunnerView.lua"],
                             capture_output=True, text=True, check=True).stdout
        print(f"GunnerView at {ref}:")
        problems, n = check(root, old)
        print(f"gunner aim world check ({ref}): {n} specs, {len(problems)} problems")
        for p in problems:
            print("  " + p)
        return 0
    if "--plant" in sys.argv:
        missed = 0
        for label, plant in PLANTS:
            problems, _ = check(root, plant(src), verbose=False)
            caught = bool(problems)
            missed += 0 if caught else 1
            print(f"  {'CAUGHT' if caught else 'MISSED'}: {label}" + (f" -> {problems[0]}" if caught else ""))
        print(f"planted faults: {len(PLANTS) - missed}/{len(PLANTS)} caught")
        return 1 if missed else 0
    problems, n = check(root, src)
    for p in problems:
        print("  " + p)
    print(f"gunner aim world check: {n} specs, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
