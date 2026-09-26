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
  C. The mouse lock across a ride (task 08: "aiming for the vehicle guns dont work in 3rd person
     sometimes and locks your cursor in the middle"). CombatClient's real setThirdPerson and
     updateCameraMode, cut from its source, run in the same mock world as the real
     VehicleWeaponClient and GunnerView, sharing one UserInputService. The walk, in third and in first
     person: combat on foot, board the driver's seat, drive (updateCameraMode called again, as a
     loadout, aim or match change does), leave, board the gunner's seat, move gunner -> driver and
     driver -> gunner, leave. Invariants: in a vehicle with no GunnerView running the mouse is never
     LockCenter and the driver's gun ray goes through the cursor in all four corners; while
     GunnerView runs the mouse stays LockCenter, even straight after updateCameraMode; on foot in
     combat it is LockCenter again.

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
COMBAT = "CombatClient.client.lua"
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
        guard, rear = spec.frontGuard, spec.rearGuard

        # The lowest the barrel goes at this yaw: a front guard (the Ranger's pod over its own cab)
        # lifts the floor within its arc of straight ahead, a rear guard within its arc of straight behind.
        def floor_at(yd):
            if guard is not None and abs(yd) < guard.arc:
                return max(pmin, guard.pitchMin)
            if rear is not None and abs(yd) > 180 - rear.arc:
                return max(pmin, rear.pitchMin)
            return pmin

        cases = []
        for yd in (-0.9 * ylim, 0, 0.5 * ylim):
            lo = floor_at(yd)
            for pd in (lo + 0.1 * (pmax - lo), lo + 0.5 * (pmax - lo), lo + 0.9 * (pmax - lo)):
                cases.append((yd, pd, False))
        if ylim < 180:
            cases.append((ylim + 20, 0, True))
            cases.append((-(ylim + 20), 0, True))
        cases.append((0, pmax + 10, True))
        cases.append((0, floor_at(0) - 10, True))
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
                edge_p = min(max(pd, floor_at(edge_y)), pmax)
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


# CombatClient's camera-mode code, cut from the real source: setThirdPerson, updateCameraMode and the
# InVehicle listener that calls it. updateThirdPersonCamera is bound per frame while third person is on;
# only its mouse lock is taken (the rest is the camera's placement, which needs a real world).
CAMERA_BLOCK = re.compile(r"(local function setThirdPerson\(.*?\nplayer:GetAttributeChangedSignal\(\"InVehicle\"\)"
                          r":Connect\(function\(\)\n\tupdateCameraMode\(\)\nend\)\n)", re.S)
THIRD_PERSON_LOCK = re.compile(r"local function updateThirdPersonCamera\(delta\).*?\n(\tif not player:GetAttribute"
                               r"\(\"MenuOpen\"\) then\n\t\tUserInputService\.MouseBehavior = [^\n]*\n\tend\n)", re.S)
CORNERS = [(0.05, 0.05), (0.95, 0.05), (0.05, 0.95), (0.95, 0.95)]


def camera_harness(combat_src):
    block, lock = CAMERA_BLOCK.search(combat_src), THIRD_PERSON_LOCK.search(combat_src)
    if not block or not lock:
        raise SystemExit("vehicle_aim_check: CombatClient's setThirdPerson/updateCameraMode block not found")
    return hud.luau_to_lua("""
local W = ...
local player, UserInputService = W.player, W.UserInputService
local S = { combat = true, third = true }
local camera = { CFrame = { LookVector = Vector3.new(0, 0, -1) } }
local bound = {}
local RunService = {}
function RunService:BindToRenderStep(name, _, fn) bound[name] = fn end
function RunService:UnbindFromRenderStep(name) bound[name] = nil end
W.RenderStepped:Connect(function(dt)
    for _, fn in pairs(bound) do fn(dt) end
    -- Roblox's camera module, the one part of it this walk meets: in first person it locks the mouse every
    -- frame (CameraModule:Update -> BaseCamera:UpdateMouseBehavior -> setMouseBehaviorOverride(LockCenter)).
    -- Only under LockFirstPerson, which a vehicle never is, so it can't hide a lock left on in the car.
    if player.CameraMode == Enum.CameraMode.LockFirstPerson
        and W.workspace.CurrentCamera.CameraType ~= Enum.CameraType.Scriptable then
        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
    end
end)
local thirdPersonActive, aiming = false, false
local lookYaw, lookPitch, shoulderDistance = 0, 0, 0
local zoomDistance, THIRD_PERSON_AIM_DISTANCE, PITCH_LIMIT = 12, 6, math.rad(80)
local touchDelta, gamepadLook = Vector2.zero, Vector2.zero
local function inCombat() return S.combat end
local function wantsThirdPerson() return S.third end
local function updateThirdPersonCamera(delta)
""" + lock.group(1) + "end\n" + block.group(1) + """
return { S = S, updateCameraMode = updateCameraMode }
""")


def check_camera_mode(root, sources):
    problems, examined = [], 0
    world = hud.World(root, ("1920x1080", 1920, 1080, False), sources)
    world.play("BattleRoyale", "gunner")  # the Rotster with both seats; the walk seats the player itself
    cam = world.lua.execute(camera_harness(sources[COMBAT]), world.W)
    world.run("""
        local car = W.special(W.character.Humanoid).SeatPart.Parent
        W.seats = { driver = car:FindFirstChild('DriverSeat'), gunner = car:FindFirstChild('GunnerSeat') }
        W.special(W.character.Humanoid).SeatPart = nil
        W.lastInput = 'MouseMovement'
        W.frame(3)
    """)
    errors_before = len(world.W.errors)

    def seat(which, in_vehicle):
        world.run("""
            local which, inVehicle = select(2, ...)
            W.special(W.character.Humanoid).SeatPart = which and W.seats[which] or nil
            W.player:SetAttribute('InVehicle', inVehicle or nil)
        """, which, in_vehicle)

    def state():
        return world.run("""
            local b = W.UserInputService.MouseBehavior
            return b and b.Name or 'nil', W.player:GetAttribute('GunnerView') == true,
                W.player:GetAttribute('InVehicle') == true
        """)

    def ray_at(fx, fy):
        return world.run("""
            local x, y = select(2, ...)
            W.mouse = W.Vector2.new(x, y)
            W.lastRay = nil
            W.frame(1)
            return W.lastRay and W.lastRay.x, W.lastRay and W.lastRay.y
        """, fx * 1920, fy * 1080)

    def expect(tag, want):
        # want: "free" (driver's gun on the cursor), "gunner" (GunnerView's lock) or "combat" (on foot, locked).
        nonlocal examined
        examined += 1
        behaviour, gunner, in_vehicle = state()
        if want == "combat":
            if in_vehicle or behaviour != "LockCenter":
                problems.append(f"{tag}: on foot in combat the mouse is {behaviour}, want LockCenter")
            return
        if want == "gunner":
            if not gunner or behaviour != "LockCenter":
                problems.append(f"{tag}: gunner (GunnerView={gunner}) has the mouse {behaviour}, want LockCenter")
            return
        if in_vehicle and not gunner and behaviour == "LockCenter":
            problems.append(f"{tag}: in the driver's seat with no GunnerView the mouse is LockCenter")
        for fx, fy in CORNERS:
            examined += 1
            rx, ry = ray_at(fx, fy)
            if rx is None or abs(rx - fx * 1920) > 0.01 or abs(ry - fy * 1080) > 0.01:
                problems.append(f"{tag}: cursor at ({fx * 1920:.0f},{fy * 1080:.0f}) but the driver's gun "
                                f"aims through ({rx}, {ry})")
                break

    for view in ("third", "first"):
        cam.S.third = view == "third"
        cam.S.combat = True
        seat(None, False)
        cam.updateCameraMode()
        world.W.frame(3)
        expect(f"{view}: combat on foot", "combat")
        seat("driver", True)
        world.W.frame(3)
        expect(f"{view}: boarded the driver's seat in combat", "free")
        for _ in range(3):
            cam.updateCameraMode()  # a loadout, aim or match change while driving
            world.W.frame(2)
        expect(f"{view}: driving, updateCameraMode called again", "free")
        seat(None, False)
        world.W.frame(3)
        expect(f"{view}: left the car", "combat")
        seat("gunner", True)
        world.W.frame(3)
        expect(f"{view}: boarded the gunner's seat in combat", "gunner")
        cam.updateCameraMode()  # straight after: CombatClient must not free the gunner's mouse
        expect(f"{view}: gunner, straight after updateCameraMode", "gunner")
        world.W.frame(2)
        seat("driver", True)
        world.W.frame(3)
        expect(f"{view}: moved gunner -> driver", "free")
        seat("gunner", True)
        world.W.frame(3)
        expect(f"{view}: moved driver -> gunner", "gunner")
        seat(None, False)
        world.W.frame(3)
        expect(f"{view}: left the car from the gunner's seat", "combat")
    # GunnerView's barrel maths needs CFrame methods the mock doesn't have; it fails after look() has
    # already set the lock, as it does in the HUD check's gunner scene. Any other error is a failure.
    errors = list(world.W.errors.values())
    for err in errors[errors_before:]:
        if not re.search(r"GunnerView:\d+: attempt to index a number value \(local 'rest'\)", err):
            problems.append(f"mock world error during the walk: {err}")
    return problems, examined


def check(root, sources, weapons_src, quiet=False):
    a, na = check_pure(sources[SCRIPT], weapons_src)
    b, nb = check_wired(root, sources)
    c, nc = check_camera_mode(root, sources)
    if not quiet:
        print(f"vehicle_aim_check: {na} pure cases, {nb} wired cases, {nc} mouse-lock cases examined")
    return a + b + c


PLANTS = [
    ("the aim point ignoring the mouse", SCRIPT,
     "return math.clamp(mouseX, 0, width), math.clamp(mouseY, 0, height)", "return width / 2, height / 2"),
    ("the ray cast through the middle whatever the aim point", SCRIPT,
     "local ray = camera:ViewportPointToRay(screenX, screenY)",
     "local ray = camera:ViewportPointToRay(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)"),
    ("an aim outside the arc not reported as pinned", SCRIPT,
     "return math.abs(wantYaw - yaw) > 1e-4 or math.abs(wantPitch - pitch) > 1e-4", "return false"),
    # Aimed at the invariant (in a vehicle with no GunnerView the mouse is never LockCenter), both ways
    # it can break: the vehicle branch leaving the lock alone, or taking it.
    ("the vehicle branch leaving combat's mouse lock in place", COMBAT,
     "\t\tif not player:GetAttribute(\"GunnerView\") then\n\t\t\tUserInputService.MouseBehavior = Enum.MouseBehavior.Default\n\t\tend\n", ""),
    ("the vehicle branch locking the mouse", COMBAT,
     "\t\tplayer.CameraMode = Enum.CameraMode.Classic\n\t\t-- The mouse is freed too",
     "\t\tplayer.CameraMode = Enum.CameraMode.Classic\n\t\tUserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter\n\t\tdo return end\n\t\t-- The mouse is freed too"),
    # And the gunner's side: CombatClient must never free the mouse GunnerView locked.
    ("CombatClient freeing a gunner's locked mouse", COMBAT,
     "\t\tif not player:GetAttribute(\"GunnerView\") then\n\t\t\tUserInputService", "\t\tif true then\n\t\t\tUserInputService"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {n: hud.read(root, n) for n in hud.SCRIPTS}
    for m in hud.MODULES:
        sources[m + ".lua"] = hud.read(root, m + ".lua")
    sources[COMBAT] = hud.read(root, COMBAT)
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
