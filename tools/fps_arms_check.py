"""First-person arms check (#11 joints, #26 crosshair, #92 hands on the gun, #44 avatar arms), without Studio.

Runs the REAL StarterPlayerScripts/Viewmodel.lua on the REAL GunModels (with ZFight, ArsenalFinish and the
creative and workshop modules) under lupa, with the small Roblox mock in tools/fps_arms_mock.lua.txt, and poses
every gun in WeaponData with Viewmodel:Pose -- the call the galleries use -- at the hip, fully aimed, aimed
through a shot, three points of the reload and the rack. It does that three times: with a mock R15 avatar
whose rig attachments sit OFF the parts' centre lines and inside them (as a body package's do), with an R6
avatar, and with no avatar (the stand-in blocks). Then it reads back where every arm, hand and finger part
actually is (tools/fps_arms_measure.lua.txt) and holds these, every one of them on every gun:

  J1  joints meet: the upper arm's elbow joint on the forearm's, the forearm's wrist joint on the hand's,
      within 0.01 studs (an R15 arm's joints are read off its own attachments, not the Viewmodel's record);
  J2  a bent elbow is closed: points half the arm's thickness out on the outside of the bend lie on an arm
      part, to 0.01 studs, for any bend up to a right angle;
  J3  no bone is stretched past 1.10 of its length;
  J4  the shoulder, which may come forward toward a far hand, never shows in the widest view (95 degrees);
  J5  at every moment, the reload and rack clips included, no wrist bends past 85 degrees (as far as a
      wrist goes) between forearm and hand. The charging-handle, crossbow-string and feed-cover anchors
      were re-aimed on the palm for this (a side handle reached across the gun with the fingers straight
      down, a string taken with the fingers pointing back, had no elbow at all that straightened them);
  C1  at the hip and aimed, nothing of either arm lies on the centre ray or on a ring 4% of half the
      screen's height round it, at the widest field of view (95, and 95 x 0.64 aimed) -- unless the gun is
      scoped in, when CombatClient hides the whole viewmodel;
  H1  at the hip and aimed, each palm lies on the gun: some point of its inner face within 5 mm of a
      visible part;
  H2  each hand on a grip or a handguard shows at least two fingers -- closed round what it holds, or
      lying along it where there is no room to close -- rather than a bare palm with every finger parked
      inside it (an R6 arm has no hand, so no fingers);
  A1  (#44) an avatar's arms keep its colours -- upper arm, forearm and hand each the colour of the part it
      was copied from, the fingers the hand's -- and its shirt (a Humanoid and the Shirt in the arms
      model), at the viewmodel's arm thickness; and when the appearance lands after the gun is drawn (a
      character spawns as a grey rig), the arms follow it within two seconds.

It prints how many poses it examined next to how many it flagged. `--plant` breaks the Viewmodel source
one invariant at a time (the same path the real source takes) and every one must be caught.

    python3 tools/fps_arms_check.py [repo]            the checks
    python3 tools/fps_arms_check.py [repo] --plant    the planted faults; every one must be caught
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("fps_arms_check: needs lupa (pip install lupa)")

# (name, state, field of view). The FOV is the widest the settings allow (Settings.lua: 60..95), and aimed
# it is that times CombatClient's ADS_ZOOM (0.64): the ring is widest there, so hardest to keep clear.
MOMENTS = [
    ("hip", {"aim": 0}, 95),
    ("ads", {"aim": 1}, 95 * 0.64),
    ("adsFire", {"aim": 1, "clip": "fire", "progress": 0.3, "roundsLeft": 5}, 95 * 0.64),
    ("reload20", {"clip": "reload", "progress": 0.2, "roundsLeft": 0}, 95),
    ("reload45", {"clip": "reload", "progress": 0.45, "roundsLeft": 0}, 95),
    ("reload70", {"clip": "reload", "progress": 0.7, "roundsLeft": 0}, 95),
    ("rack", {"clip": "rack", "progress": 0.5}, 95),
]
HELD = ("hip", "ads")
AIMING = ("hip", "ads", "adsFire")
WRISTED = tuple(m[0] for m in MOMENTS)
RIGS = ("r15", "r6", "standin")
RING = 0.04

GAP, NOTCH, STRETCH, WRIST = 0.01, 0.01, 1.10, 85.0
PALM, FINGERS = 0.019, 2  # 5 mm (0.0038 studs a millimetre)


def luau_to_lua(src):
    return re.sub(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", src, flags=re.M)


def sources(repo):
    shared = os.path.join(repo, "ReplicatedStorage", "Shared")
    out = {}
    for name in os.listdir(shared):
        if name.endswith(".lua"):
            out[name[:-4]] = open(os.path.join(shared, name), encoding="utf-8").read()
    out["Viewmodel"] = open(os.path.join(repo, "StarterPlayerScripts", "Viewmodel.lua"), encoding="utf-8").read()
    return out


def run(repo, src, rigs=RIGS, moments=MOMENTS, only=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    tools = os.path.join(repo, "tools")
    lua.execute(open(os.path.join(tools, "fps_arms_mock.lua.txt"), encoding="utf-8").read())
    lua.execute(luau_to_lua(open(os.path.join(tools, "fps_arms_measure.lua.txt"), encoding="utf-8").read()))
    table = lua.globals().SOURCES
    for name, text in src.items():
        table[name] = luau_to_lua(text)
    weapons = lua.eval('loadModule("WeaponData")')
    vm = lua.eval('loadModule("Viewmodel")')
    measure = lua.globals().measure
    ids = [i for i in sorted(weapons.Weapons.keys()) if not only or i in only]
    faults, examined = [], 0
    for gun in ids:
        definition = weapons.Get(gun)
        for rig in rigs:
            for name, state, fov in moments:
                out = measure(vm, definition, rig, lua.table_from(state), fov, RING)
                examined += 1
                faults += judge(gun, rig, name, out)
    # A1, late: the appearance lands after the gun is drawn (a character spawns grey), on one gun of each
    # hold class; the arms must follow within a couple of seconds, with no second set left behind.
    late = lua.globals().lateLook
    for gun in [g for g in ("SahurPistol", "CrocodiloRifle", "CameloLMG") if g in ids]:
        out = late(vm, weapons.Get(gun))
        examined += 1
        if out.upper != out.want or out.hand != out.wantHand or not out.shirt or out.models != 1:
            faults.append("A1 %s r15 late : arms %s / hand %s after the avatar dressed as %s / %s, shirt %s, %d arms models"
                          % (gun, out.upper, out.hand, out.want, out.wantHand, out.shirt, out.models))
    return faults, examined, len(ids)


def judge(gun, rig, moment, out):
    bad = []

    def flag(code, side, text):
        bad.append("%s %s %s %s %s: %s" % (code, gun, rig, moment, {1: "right", -1: "left"}.get(side, ""), text))

    for side in (1, -1):
        r = out.sides[side]
        if r.elbowGap > GAP or r.wristGap > GAP:
            flag("J1", side, "elbow gap %.4f, wrist gap %.4f" % (r.elbowGap, r.wristGap))
        if r.elbowBend <= 90 and r.elbowNotch > NOTCH:
            flag("J2", side, "open wedge %.3f outside a %.0f degree elbow" % (r.elbowNotch, r.elbowBend))
        if r.stretch > STRETCH:
            flag("J3", side, "a bone at %.2f of its length" % r.stretch)
        if r.shoulderShown > 0:
            flag("J4", side, "shoulder %.3f inside the widest view" % r.shoulderShown)
        if moment in WRISTED and r.wristBend > WRIST:
            flag("J5", side, "wrist bent %.0f degrees" % r.wristBend)
        if moment in AIMING and r.blockers:
            flag("C1", side, "on the crosshair: " + r.blockers)
        if moment in HELD and not out.hidden:
            if r.palmGap > PALM:
                flag("H1", side, "palm %.1f mm off the gun (nearest %s)" % (r.palmGap / 0.0038, r.palmOn))
            if r.heldShape and r.fingersClosed < FINGERS:
                flag("H2", side, "%d fingers shown on %s" % (r.fingersClosed, r.heldShape))
    if rig != "standin":
        for what in ("upper", "lower", "hand"):
            want, have = out.sourceColour[what], out.colour[what]
            if want and want != have:
                flag("A1", 0, "%s is %s, the avatar's is %s" % (what, have, want))
        if out.colour.finger and out.colour.finger != out.colour.hand:
            flag("A1", 0, "fingers %s, hand %s" % (out.colour.finger, out.colour.hand))
        if not (out.hasShirt and out.hasHumanoid):
            flag("A1", 0, "the shirt is not carried over")
        if abs(out.thickness - 0.34) > 0.005:
            flag("A1", 0, "arm %.3f thick" % out.thickness)
    return bad


# Flags that are known and whose fix is outside the files this check was written with. Each is still
# printed and counted; only these exact flags may stand, and one that stops appearing is reported so the
# entry is removed. Empty: the last two (YardWorkBlower and DustDevilRotary, whose ammunition bags stood
# against the grip's front strap) were cleared by moving the bags forward in GunModelsWorkshop.
KNOWN = set()


# Each breaks one invariant in the Viewmodel source; the check must catch it. Aimed at what the code
# must refuse forever, not at any one gun.
PLANTS = [
    ("J1 bone laid along the part, not its joint line", "Viewmodel",
     "local joint = b.joint\n", "local joint = nil\n"),
    ("J2 no run-on past the elbow", "Viewmodel",
     "local ELBOW_OVERRUN = ARM_THICKNESS / 2", "local ELBOW_OVERRUN = 0"),
    ("J3 the shoulder never comes forward", "Viewmodel",
     "local SHOULDER_TRAVEL = 1.3", "local SHOULDER_TRAVEL = 0"),
    ("J4 the shoulder allowed into view", "Viewmodel",
     "local SHOULDER_HIDE = 0.2", "local SHOULDER_HIDE = -1.5"),
    ("J5 the elbow ignores the wrist", "Viewmodel",
     "local WRIST_FOLLOW = 0.75", "local WRIST_FOLLOW = 0"),
    ("C1 fingers may close into the sight picture", "Viewmodel",
     "local SIGHT_CLEAR = math.tan(math.rad(3))", "local SIGHT_CLEAR = 0"),
    ("H1 the hand held off what it holds", "Viewmodel",
     "hand = hand * CF(0, HAND_THICKNESS / 2 - HAND_SINK, 0)", "hand = hand * CF(0, HAND_THICKNESS / 2 - HAND_SINK + 0.05, 0)"),
    ("H2 every finger with no room to close parked in the palm", "Viewmodel",
     "if shape.cap < FINGER_MIN_CLOSE and shape.blocker then", "if shape.cap < FINGER_MIN_CLOSE then"),
    ("J5 a charging handle taken with the fingers straight down", "GunModels",
     'g:hand("ChargeHand", V(40, 26, -80), V(0.41, -0.74, -0.53), V(0.57, -0.25, 0.78))',
     'g:hand("ChargeHand", V(40, 26, -80), V(0.2, -1, 0.1), V(0.3, 0.2, 1))'),
    ("A1 the arms never look at the avatar again", "Viewmodel",
     "local LOOK_CHECK = 1\n", "local LOOK_CHECK = math.huge\n"),
    ("A1 copied arms lose the avatar's colour", "Viewmodel",
     "\tpart.LocalTransparencyModifier = 0\n\treturn part\n",
     "\tpart.LocalTransparencyModifier = 0\n\tpart.Color = Color3.new(1, 1, 1)\n\treturn part\n"),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = args[0] if args else "."
    src = sources(repo)
    if "--plant" in sys.argv:
        caught = 0
        for name, target, old, new in PLANTS:
            if old not in src[target]:
                print("PLANT %s: the text to break is not in %s any more" % (name, target))
                continue
            broken = dict(src)
            broken[target] = src[target].replace(old, new, 1)
            code = name.split()[0]
            faults, examined, guns = run(repo, broken, rigs=("r15", "standin"))
            hit = [f for f in faults if f.startswith(code + " ")]
            caught += bool(hit)
            print("%s %s: %d flags over %d poses%s" % ("CAUGHT" if hit else "MISSED", name, len(hit), examined,
                                                        (" (" + hit[0] + ")") if hit else ""))
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    faults, examined, guns = run(repo, src)
    known = [f for f in faults if (f.split()[0], f.split()[1], f.split()[4].rstrip(":")) in KNOWN]
    seen = {(f.split()[0], f.split()[1], f.split()[4].rstrip(":")) for f in known}
    for fault in faults:
        print(("KNOWN " if fault in known else "") + fault)
    for entry in sorted(KNOWN - seen):
        print("KNOWN entry no longer flagged, remove it: %s %s %s" % entry)
    codes = {}
    for fault in faults:
        codes[fault.split()[0]] = codes.get(fault.split()[0], 0) + 1
    print("fps arms: %d guns x %d rigs x %d moments = %d poses examined, %d flagged %s, %d of them known" % (
        guns, len(RIGS), len(MOMENTS), examined, len(faults), codes or "", len(known)))
    sys.exit(1 if len(faults) > len(known) or seen != KNOWN else 0)


if __name__ == "__main__":
    main()
