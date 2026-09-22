"""Designs the Cloud Climb and checks it can be climbed. Usage: python tools/climb_design.py [project]

The obby up the Rot Tree is built only from branches, and a hard obby is only fun if every jump
is possible and nothing lets you skip a jump. Neither can be judged by eye, so the course is laid
out here, checked against jump reach measured in Studio, and written to
ServerScriptService/Modules/CloudClimbCourse.lua for LobbyService to build. Edit this file and
rerun it; don't hand-edit the generated module. Exits 1 if any check fails.

Reach numbers come from tools/jump_probe.lua (an R15 rig with the player's jump settings, run
off one block onto another, binary-searching the widest gap for each rise). They are edge to edge
and made with perfect timing, so they are ceilings: jumps are designed as a fraction of them.

The layout, bottom to top (bearings in degrees, 0 = +X, 90 = +Z, like the rest of the lobby):

  Start      a root breaking up through the paving, the on-ramp
  Stage 1    three forks. A fork is a pair of limbs leaving the trunk at one knot and splaying
             out into a V. You land on the tip of one limb, walk it in to the knot, walk the other
             limb out, and jump from its tip to the next fork's. The V is what stops skipping:
             two neighbouring forks are only close at their tips, so the tip jump is the only
             one on offer, and knots are a full 8 studs apart vertically, beyond the 7.9-stud
             step a jump can make.
  Checkpoint 1 a fork of thick limbs
  Stage 2    a fork under a thorn wheel turning round the trunk, a fork reached by a sprint leap
             whose landing limb flaps, then the Long Bough: a limb sagging out from under the
             leaves to the rim of the canopy, with a thorn rotor across it and a springy tip
  Checkpoint 2 the first limb out of the leaves
  Stage 3    limbs poking out of the canopy, spiralling up round it: snapping deadwood, flapping
             tips, rotors, sprint leaps
  Checkpoint 3 a thick limb halfway up the crown
  Stage 4    more of the same, thinner, then twigs up through the top of the leaves to the summit

Every leaf ball is scenery now. When the centre ball was solid, anyone who reached its upper half
could walk up it to the summit, since a humanoid stands on slopes up to 89 degrees.
"""
import math
import os
import re
import sys

# --check: write nothing; exit 1 if a check fails or CloudClimbCourse.lua isn't what this script
# would write (tools/verify.py runs it that way).
CHECK_ONLY = "--check" in sys.argv
_args = [a for a in sys.argv[1:] if not a.startswith("--")]
ROOT = _args[0] if _args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LOBBY = os.path.join(ROOT, "ServerScriptService", "Modules", "LobbyService.lua")
OUT = os.path.join(ROOT, "ServerScriptService", "Modules", "CloudClimbCourse.lua")

# --- Measured reach ------------------------------------------------------------------------------
# (rise, widest edge-to-edge gap) at walk speed 18 and sprint speed 26.1; tools/jump_probe.lua,
# 2026-09-16. Gravity 196.2, JumpPower 50. The highest step a jump makes, from right below the
# ledge, is 7.86.
WALK = [(-6, 12.06), (-3, 11.46), (0, 10.57), (1.5, 10.28), (3, 9.76), (4, 9.31), (5, 8.79), (6, 8.35)]
SPRINT = [(-6, 17.85), (-3, 16.81), (0, 15.62), (1.5, 14.95), (3, 14.21), (4, 13.69), (5, 13.10), (6, 12.43)]
MAX_RISE = 7.86


def reach(table, rise, generous):
    """Widest gap clearable at this rise. `generous` overestimates past the measured range (for
    proving a jump can NOT be made); otherwise it underestimates (for proving one can)."""
    if generous:
        # As if every jump rose 0.3 less than it does.
        rise -= 0.3
    if rise > MAX_RISE:
        return -1.0
    if rise > table[-1][0]:
        # Between the last measured rise and the highest step, reach falls to the 1.2-stud gap
        # the step was measured over.
        t = (rise - table[-1][0]) / (MAX_RISE - table[-1][0])
        return table[-1][1] * (1 - t) + 1.2 * t
    if rise < table[0][0]:
        slope = (table[0][1] - table[1][1]) / (table[1][0] - table[0][0])
        extra = (table[0][0] - rise) * slope
        return table[0][1] + (extra * 1.5 if generous else extra * 0.5)
    for (r0, g0), (r1, g1) in zip(table, table[1:]):
        if r0 <= rise <= r1:
            return g0 + (g1 - g0) * (rise - r0) / (r1 - r0)
    return table[-1][1]


# --- The tree ------------------------------------------------------------------------------------
# The trunk tapers in stacked lengths whose steps are too narrow to stand on (LobbyService builds
# it from these same numbers). The old trunk was three lengths with 1-stud ledges at 30 and 56:
# a ring you could walk round, and jump from onto any branch within reach of it.
TRUNK_HEIGHT = 78
TRUNK_LENGTHS = 13
TRUNK_BOTTOM_RADIUS = 6.5
TRUNK_TOP_RADIUS = 4.5


def trunk_radius(y):
    if y < 0 or y > TRUNK_HEIGHT:
        return 0.0
    k = min(TRUNK_LENGTHS - 1, int(y / (TRUNK_HEIGHT / TRUNK_LENGTHS)))
    return TRUNK_BOTTOM_RADIUS + (TRUNK_TOP_RADIUS - TRUNK_BOTTOM_RADIUS) * k / (TRUNK_LENGTHS - 1)


def read_canopy():
    source = open(LOBBY, encoding="utf-8").read()
    block = re.search(r"local CANOPY = \{(.*?)\n\}", source, re.S).group(1)
    balls = []
    for m in re.finditer(r"Vector3\.new\(([-\d.]+),\s*([-\d.]+),\s*([-\d.]+)\),\s*([\d.]+)", block):
        balls.append(((float(m.group(1)), float(m.group(2)), float(m.group(3))), float(m.group(4)) / 2))
    assert balls, "couldn't read CANOPY from LobbyService.lua"
    return balls


CANOPY = read_canopy()
CROWN_CENTRE, CROWN_RADIUS = CANOPY[0]
# The summit stands on the tree's leader, a spire up out of the top of the leaves. Sat right on the
# crown it was a 10-stud target within a sprint leap of the last three limbs.
SUMMIT_TOP = CROWN_CENTRE[1] + CROWN_RADIUS + 8.0
SUMMIT_DIAMETER = 9.0


def in_foliage(p, margin):
    for (cx, cy, cz), radius in CANOPY:
        if (p[0] - cx) ** 2 + (p[1] - cy) ** 2 + (p[2] - cz) ** 2 < (radius + margin) ** 2:
            return True
    return False


def wood_hidden(p, margin=0.0):
    """Is the WOOD hidden -- not just its centre line?

    A limb is a cylinder, so a point whose centre line is a fraction inside a leaf ball still shows
    half its thickness of bare wood. Testing the centre line is how 3.8 studs of 3.09-wide branch on
    Leafbreak read as "inside the leaves" while standing clear of them in the picture. The ball (or
    the trunk) has to swallow the branch's RADIUS as well.

    `margin` is extra slack in the hiding direction, for the caller that wants to be conservative.
    """
    radius = p[3] / 2
    if radius_of(p) + radius < trunk_radius(p[1]) + 0.05 + margin:
        return True
    for (cx, cy, cz), ball in CANOPY:
        if (p[0] - cx) ** 2 + (p[1] - cy) ** 2 + (p[2] - cz) ** 2 < (ball + margin - radius) ** 2:
            return True
    return False


def foliage_exit(bearing, y, margin):
    """How far out along `bearing`, at height `y`, you leave every leaf ball by `margin`."""
    dx, dz = math.cos(math.radians(bearing)), math.sin(math.radians(bearing))
    out = 0.0
    for (cx, cy, cz), radius in CANOPY:
        r = radius + margin
        dy = y - cy
        if abs(dy) >= r:
            continue
        cut = math.sqrt(r * r - dy * dy)
        toward = cx * dx + cz * dz
        disc = toward * toward - (cx * cx + cz * cz - cut * cut)
        if disc > 0:
            out = max(out, toward + math.sqrt(disc))
    return out


# Other solid things round the foot of the tree, as oriented boxes (centre, three unit axes, half
# sizes), matching buildTree and buildStatue: the bench ring (seat at r15, backrest at r14.1 and
# 3.4 up) and the statue. The roots are limbs, laid out below with the course.
OBSTACLES = []
for i in range(8):
    angle = math.radians(i / 8 * 360 + 22.5)
    out, across = (math.cos(angle), 0, math.sin(angle)), (-math.sin(angle), 0, math.cos(angle))
    OBSTACLES.append(((14.8 * out[0], 1.7, 14.8 * out[2]), (across, (0, 1, 0), out), (3.5, 1.72, 1.15), "bench"))
OBSTACLES.append(((0, 7, 30), ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (7.2, 7.2, 7.2), "statue"))


def in_obstacle(p, pad):
    for centre, axes, half, name in OBSTACLES:
        d = (p[0] - centre[0], p[1] - centre[1], p[2] - centre[2])
        if all(abs(d[0] * a[0] + d[1] * a[1] + d[2] * a[2]) < h + pad for a, h in zip(axes, half)):
            return name
    return None


# --- Geometry ------------------------------------------------------------------------------------
def polar(radius, bearing, y):
    return (radius * math.cos(math.radians(bearing)), y, radius * math.sin(math.radians(bearing)))


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))


def hdist(a, b):
    return math.hypot(a[0] - b[0], a[2] - b[2])


def dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def bearing_of(p):
    return math.degrees(math.atan2(p[2], p[0])) % 360


def radius_of(p):
    return math.hypot(p[0], p[2])


def seg_seg(p1, q1, p2, q2):
    """Closest distance between two 3D segments."""
    def sub(a, b):
        return (a[0] - b[0], a[1] - b[1], a[2] - b[2])

    def dot(a, b):
        return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

    d1, d2, r = sub(q1, p1), sub(q2, p2), sub(p1, p2)
    a, e, f = dot(d1, d1), dot(d2, d2), dot(d2, r)
    if a < 1e-9 and e < 1e-9:
        return math.sqrt(dot(r, r))
    if a < 1e-9:
        s, t = 0.0, min(1, max(0, f / e))
    else:
        c = dot(d1, r)
        if e < 1e-9:
            t, s = 0.0, min(1, max(0, -c / a))
        else:
            b = dot(d1, d2)
            denom = a * e - b * b
            s = min(1, max(0, (b * f - c * e) / denom)) if denom > 1e-9 else 0.0
            t = (b * s + f) / e
            if t < 0:
                t, s = 0.0, min(1, max(0, -c / a))
            elif t > 1:
                t, s = 1.0, min(1, max(0, (b - c) / a))
    c1 = (p1[0] + d1[0] * s, p1[1] + d1[1] * s, p1[2] + d1[2] * s)
    c2 = (p2[0] + d2[0] * t, p2[1] + d2[1] * t, p2[2] + d2[2] * t)
    return dist(c1, c2)


SMOOTH_SPACING = 1.9


def smooth(points, spacing=SMOOTH_SPACING):
    """A centripetal Catmull-Rom curve through (x, y, z, diameter) control points, cut into
    segments about `spacing` long, diameter eased linearly between controls. Returns the points
    and the indices where the controls landed.

    Three long straight cylinders meeting at two balls read as plumbing: the cylinders' flat ends
    stick out of the ball at every bend. Short segments along a curve turn a few degrees at each
    joint, where the ball hides the ends completely. Centripetal, because the uniform form
    overshoots between controls spaced as unevenly as a limb's buried root and its tip."""
    if len(points) < 3:
        return [tuple(p) for p in points], list(range(len(points)))
    P = [p[:3] for p in points]
    ext = [tuple(2 * a - b for a, b in zip(P[0], P[1]))] + P + [tuple(2 * a - b for a, b in zip(P[-1], P[-2]))]

    def mix(a, b, wa, wb):
        return tuple(a[i] * wa + b[i] * wb for i in range(3))

    out, controls = [tuple(points[0])], [0]
    for span in range(len(points) - 1):
        p0, p1, p2, p3 = ext[span], ext[span + 1], ext[span + 2], ext[span + 3]
        t0 = 0.0
        t1 = t0 + max(dist(p0, p1), 1e-4) ** 0.5
        t2 = t1 + max(dist(p1, p2), 1e-4) ** 0.5
        t3 = t2 + max(dist(p2, p3), 1e-4) ** 0.5
        steps = max(1, math.ceil(dist(p1, p2) / spacing))
        for step in range(1, steps + 1):
            t = t1 + (t2 - t1) * step / steps
            a1 = mix(p0, p1, (t1 - t) / (t1 - t0), (t - t0) / (t1 - t0))
            a2 = mix(p1, p2, (t2 - t) / (t2 - t1), (t - t1) / (t2 - t1))
            a3 = mix(p2, p3, (t3 - t) / (t3 - t2), (t - t2) / (t3 - t2))
            b1 = mix(a1, a2, (t2 - t) / (t2 - t0), (t - t0) / (t2 - t0))
            b2 = mix(a2, a3, (t3 - t) / (t3 - t1), (t - t1) / (t3 - t1))
            c = mix(b1, b2, (t2 - t) / (t2 - t1), (t - t1) / (t2 - t1))
            d = points[span][3] + (points[span + 1][3] - points[span][3]) * step / steps
            out.append(c + (d,))
        controls.append(len(out) - 1)
    return out, controls


class Limb:
    """A branch as a polyline of (x, y, z, diameter) on its centre line. Built as one cylinder per
    segment, at the mean of its end diameters, with a ball at every bend and, on a live limb, a
    rounded tip. Segments before `solid_from` are scenery (inside the trunk or the leaves) and
    don't collide. With `curve`, the points are controls a smooth curve is drawn through."""

    def __init__(self, points, motion=None, dead=False, curve=False):
        if curve:
            self.points, controls = smooth(points)
            self.control = [i in controls for i in range(len(self.points))]
        else:
            self.points = [tuple(p) for p in points]
            self.control = [True] * len(self.points)
        self.solid_from = 0
        self.motion = motion  # None, "snap" or "flap"
        self.dead = dead
        self.flap = None
        self.round_tip = not dead
        # Declared scenery: visible wood that deliberately does not hold you up (the knob stalks).
        # Check 7 exempts these BY NAME and counts them.
        self.decorative = False

    def segments(self):
        for k in range(len(self.points) - 1):
            a, b = self.points[k], self.points[k + 1]
            yield k, a, b, (a[3] + b[3]) / 2

    def solid_segments(self):
        for k, a, b, d in self.segments():
            if k >= self.solid_from:
                yield a, b, d

    def cut_at_exit(self, margin, foliage=True):
        """Split the limb where its centre line leaves the trunk (and the leaves) for good, and
        make everything before that scenery.

        ONLY GEOMETRY DECIDES THIS, and it has to stay that way. LobbyService builds a scenery
        segment as an ordinary wooden cylinder and then calls decor() on it, which clears
        CanCollide, CanQuery and CanTouch -- and never touches Transparency. So a scenery segment
        that is not actually buried is VISIBLE BRANCH A PLAYER FALLS THROUGH.

        This used to take a `body` flag which also called a point "inside" when the limb itself was
        out in open air but a body standing on it would have had its head in the leaves -- the idea
        being that a climber there cannot see. The effect was 36 exposed scenery segments and 35.9
        studs of visible branch with no collision, including 9.1 studs on Leafbreak (checkpoint 2)
        and 7.2 on The Long Bough, the widest limb in the course at 3.4 studs across. Oliver, #28:
        "parts of the treehouse obby branches aren't solid and you fall through them." A player aims
        for the fattest part of a branch, which is exactly where it was.
        The headroom intent is not lost: stub() already places its TIP past foliage_exit measured at
        top + 2.5, +5.0 and +7.0, which is the same idea applied where it belongs -- to where the
        limb ENDS, not to whether the wood you can see holds you up.
        Check 7 below now fails the build if an exposed scenery segment ever comes back."""
        steps = []
        for k, a, b, d in self.segments():
            n = max(2, int(dist(a, b) / 0.1))
            for i in range(n + 1):
                steps.append((k, i / n, lerp(a, b, i / n)))
        last_inside = None
        for index, (k, t, p) in enumerate(steps):
            inside = wood_hidden(p, margin) if foliage else (radius_of(p) + p[3] / 2 < trunk_radius(p[1]) + 0.05 + margin)
            if inside:
                last_inside = index
        if last_inside is None:
            return
        if last_inside >= len(steps) - 1:
            self.solid_from = len(self.points)
            return
        k, t, p = steps[last_inside + 1]
        if t <= 1e-6:
            self.solid_from = k
        elif t >= 1 - 1e-6:
            self.solid_from = k + 1
        else:
            a, b = self.points[k], self.points[k + 1]
            self.points.insert(k + 1, lerp(a, b, t))
            self.control.insert(k + 1, True)
            self.solid_from = k + 1
        # Nobody sees the buried part, so it needn't follow the curve: keep only its controls,
        # which saves a few hundred parts inside the leaves.
        # A scenery stretch that's out in the open (under the leaves, say, where a body wouldn't
        # have headroom) is seen, so it keeps its curve.
        def hidden(p):
            return wood_hidden(p, margin) if foliage else (radius_of(p) + p[3] / 2 < trunk_radius(p[1]) + 0.05 + margin)

        keep = [i for i in range(self.solid_from) if self.control[i] or i == 0 or not hidden(self.points[i])]
        self.points = [self.points[i] for i in keep] + self.points[self.solid_from:]
        self.control = [True] * len(keep) + self.control[self.solid_from:]
        self.solid_from = len(keep)


class Element:
    def __init__(self, name, kind, stage):
        self.name, self.kind, self.stage = name, kind, stage
        self.limbs, self.balls, self.collars = [], [], []
        self.checkpoint = None
        self.sprint = False  # the jump INTO this element needs a sprint
        self.hard = False
        self.bearing = 0.0
        self.samples = []

    def solid_balls(self):
        return [b for b in self.balls if b[4]]


# --- The roots -----------------------------------------------------------------------------------
# Eight roots flaring out from the foot of the trunk, one down each gap in the bench ring, tapering
# as they go and diving into the paving. They're laid out here rather than left to LobbyService
# because they're solid and their tops are ramps up to the trunk anyone can walk: the skip check
# has to know exactly where they go. (They used to be seven 4 x 3.5 x 14 boxes tipped into the
# paving: blocky, and 7 studs high at the trunk.)
ROOTS = []
for index in range(8):
    bearing = 45 * index
    wiggle = 1.6 if index % 3 == 0 else -1.4
    out = 18.2 - (index % 3) * 1.1
    root = Limb([
        polar(trunk_radius(4.5) - 1.6, bearing, 4.6) + (4.4,),
        polar(7.4, bearing + wiggle * 0.25, 3.45) + (3.5,),
        polar(10.8, bearing + wiggle, 2.15) + (2.5,),
        polar(out - 3.0, bearing + wiggle * 0.5, 1.3) + (1.45,),
        polar(out, bearing - wiggle * 0.3, 0.3) + (0.7,),
    ], curve=True)
    root.cut_at_exit(0, foliage=False)
    root.round_tip = False
    ROOTS.append(root)


# --- The course ----------------------------------------------------------------------------------
elements = []
rotors = []


def fork(name, stage, bearing, knot_top, reach_radius, spread, a_rise, b_rise, d_knot, d_tip, **options):
    """Two limbs from one knot on the trunk: A (landed on, spread degrees back) and B (left from,
    spread degrees on), their tops at knot_top + a_rise and knot_top + b_rise."""
    element = Element(name, "fork", stage)
    # The knot ball spans d_knot of height, maybe across a step in the trunk: clear the wider length.
    trunk = max(trunk_radius(knot_top - d_knot), trunk_radius(knot_top - 0.01))
    knot = polar(trunk + d_knot / 2 + 0.05, bearing, knot_top - d_knot / 2)
    element.balls.append(knot + (d_knot, True))
    element.collars.append((polar(trunk - 0.9, bearing, knot[1]), polar(trunk + 0.45, bearing, knot[1]), d_knot * 1.3))
    for side, rise in ((-1, a_rise), (1, b_rise)):
        tip_bearing = bearing + side * spread
        tip = polar(reach_radius, tip_bearing, knot_top + rise - d_tip / 2)
        # A slight bow so a limb reads as grown rather than drawn: in toward the middle of the V,
        # never out toward the neighbouring fork, which would bring the two limbs' middles close
        # enough to jump between and make the tip jump optional. B, the limb that climbs, sags a
        # little before it rises, which keeps it low near the trunk where the thorn wheel turns.
        mid = lerp(knot, tip, 0.5)
        across = (-(tip[2] - knot[2]), 0, tip[0] - knot[0])
        length = math.hypot(across[0], across[2]) or 1
        bow = -options.get("bow", 0.8) * side
        arch = options.get("arch", 0.3) if side == -1 else -options.get("sag", 0.9)
        mid = (mid[0] + across[0] / length * bow, mid[1] + arch, mid[2] + across[2] / length * bow)
        d_mid = (d_knot + d_tip) / 2
        limb = Limb([knot + (d_knot,), mid + (d_mid,), tip + (d_tip,)], curve=True)
        if side == 1 and options.get("dead_b"):
            limb.motion, limb.dead, limb.round_tip = "snap", True, False
        if side == -1 and options.get("flap_a"):
            limb.motion = "flap"
            limb.flap = options["flap_a"]
        element.limbs.append(limb)
    element.bearing = bearing
    return element


def bough(name, stage, bearing, points, **options):
    """A long limb from the trunk, as (radius, bearing offset, top, diameter) stations."""
    element = Element(name, "bough", stage)
    stations = [polar(r, bearing + off, top - d / 2) + (d,) for r, off, top, d in points]
    hinge = options.get("hinge")
    # One curve through every station, then cut at the hinge, so the springy outer part carries on
    # the bough's line instead of kinking where it starts.
    curve, controls = smooth(stations)
    cut = controls[hinge] if hinge else len(curve) - 1
    inner = Limb(curve[: cut + 1])
    inner.control = [i in controls for i in range(cut + 1)]
    inner.round_tip = False
    inner.cut_at_exit(0.3)
    element.limbs.append(inner)
    if hinge:
        outer = Limb(curve[cut:], motion="flap")
        outer.flap = options["flap"]
        element.limbs.append(outer)
        element.balls.append(curve[cut][:3] + (curve[cut][3] * 1.12, True))
    else:
        inner.round_tip = True
    # What comes next is placed on from where the bough ends, not where it leaves the trunk.
    element.bearing = bearing + points[-1][1]
    element.trunk_bearing = bearing
    return element


def stub(name, stage, bearing, top, out, d_exit, d_tip, motion=None, flap=None, margin=0.6, rise_in=4.0):
    """A limb from inside the leaves, poking `out` studs past the point where a body standing on it,
    and jumping from it, is clear of them."""
    element = Element(name, "stub", stage)
    clear = 0.0
    for h in (top - d_exit, top, top + 2.5, top + 5.0, top + 7.0):
        clear = max(clear, foliage_exit(bearing, h, margin))
    tip_radius = clear + out
    inner = polar(max(trunk_radius(top - rise_in) + 0.5, 2.0), bearing, top - rise_in - d_exit / 2)
    elbow = polar(tip_radius - out - 2.5, bearing + 1.5, top - 0.9 - d_exit / 2)
    # A little dip before the tip, so the end lifts the way a limb reaching for light does.
    dip = polar(tip_radius - out * 0.45, bearing + 0.8, top - 0.35 - (d_exit + d_tip) / 4)
    tip = polar(tip_radius, bearing, top - d_tip / 2)
    limb = Limb([inner + (d_exit * 1.3,), elbow + (d_exit,), dip + ((d_exit + d_tip) / 2,), tip + (d_tip,)],
                motion=motion, dead=(motion == "snap"), curve=True)
    limb.cut_at_exit(0.25)
    if motion in ("snap", "flap") and limb.solid_from < len(limb.points) - 1:
        # Only the part out of the leaves moves: split there so the scenery inside stays put.
        cut = limb.solid_from
        still = Limb(limb.points[: cut + 1])
        still.solid_from = len(still.points)
        still.round_tip = False
        moving = Limb(limb.points[cut:], motion=motion, dead=(motion == "snap"))
        moving.flap = flap
        element.limbs += [still, moving]
    else:
        element.limbs.append(limb)
    element.bearing = bearing
    return element


def knob(name, stage, bearing, radius, top, d_knob=1.5):
    """A twig up through the top of the leaves, ending in a knot you land on."""
    element = Element(name, "knob", stage)
    centre = polar(radius, bearing, top - d_knob / 2)
    base = polar(radius * 0.72, bearing - 6, top - 8)
    # The stalk is scenery all the way up: solid, it was a slope you could land on halfway up and
    # the knot on top stopped being the target.
    # It is therefore the ONE place in the course where visible wood deliberately does not hold you
    # up, so it is DECLARED rather than silently allowed -- check 7 exempts limbs flagged this way
    # and prints how many it exempted, so a flag added later to quiet a finding is visible. It is
    # honest here because the stalk is 0.55-0.9 studs across and near vertical: nothing a player
    # stands on, unlike the 3.4-wide Long Bough that #28 was actually about.
    limb = Limb([base + (0.9,), centre + (0.55,)])
    limb.decorative = True
    limb.solid_from = len(limb.points)
    element.limbs.append(limb)
    element.balls.append(centre + (d_knob, True))
    element.bearing = bearing
    return element


def sample_element(element):
    """Standing spots: along the top of every solid segment, and on top of solid balls."""
    element.samples = []
    for limb in element.limbs:
        for a, b, d in limb.solid_segments():
            n = max(1, int(dist(a, b) / 0.45))
            for i in range(n + 1):
                p = lerp(a[:3], b[:3], i / n)
                element.samples.append((p[0], p[1] + d / 2, p[2], d / 2, limb))
    for x, y, z, d, solid in element.balls:
        if not solid:
            continue
        if element.kind == "summit":
            for r in (0, SUMMIT_DIAMETER / 4, SUMMIT_DIAMETER / 2 - 0.2):
                for k in range(8 if r else 1):
                    q = polar(r, k * 45, 0)
                    element.samples.append((x + q[0], SUMMIT_TOP, z + q[2], 0.2, None))
        else:
            element.samples.append((x, y + d / 2, z, d * 0.3, None))
    return element


def where(sample):
    return f"b{bearing_of(sample):.0f} r{radius_of(sample):.1f} y{sample[1]:.1f}"


def best_jump(a, b, table, generous):
    """Easiest pair of standing spots from element a to b: (ratio of gap to reach, gap, rise, from, to)."""
    best = None
    for p in a.samples:
        for q in b.samples:
            rise = q[1] - p[1]
            if rise > MAX_RISE + 0.5:
                continue
            gap = math.hypot(p[0] - q[0], p[2] - q[2]) - p[3] - q[3]
            if gap > 20:
                continue
            r = reach(table, rise, generous)
            if r <= 0:
                continue
            ratio = max(gap, 0) / r
            if best is None or ratio < best[0]:
                best = (ratio, gap, rise, p, q)
    return best


def place(make, lo, hi, target, sprint=False, step=0.25):
    """Builds `make(bearing)` at the first bearing from lo to hi where the easiest crossing from the
    last element is `target` of walking reach, and adds it to the course. For a sprint leap the
    target is on walking reach too (above 1, so walking can't make it); its sprint share is checked
    afterwards."""
    # Turn it on from `lo` until the easiest crossing has been closer than the target and then
    # reaches it. Just taking the first bearing at or past the target would accept one that is
    # already far out of reach at `lo`.
    previous = elements[-1]
    bearing = lo
    been_closer = False
    while bearing <= hi:
        candidate = sample_element(make(bearing))
        found = best_jump(previous, candidate, WALK, sprint)
        ratio = found[0] if found else 99
        if ratio < target:
            been_closer = True
        elif been_closer:
            candidate.sprint = sprint
            elements.append(candidate)
            return candidate
        bearing += step
    raise SystemExit(f"couldn't place {make(lo).name}: never came within {target} of reach and back out between {lo} and {hi}")


def rotor(name, hub, arm, speed, arms=2, thickness=0.7, post=None, around_trunk=False):
    rotors.append({"name": name, "hub": hub, "arm": arm, "speed": speed, "arms": arms, "thickness": thickness,
                   "post": post, "trunk": around_trunk})


# The start: a root arching up out of the paving, its knee a short hop from fork 1's landing tip.
FORK_REACH = 17.0
FORK_SPREAD = 28.0
FIRST_FORK = 196.0

start = Element("Start", "start", 0)
_aim = FIRST_FORK - FORK_SPREAD
start.limbs.append(Limb([polar(32.0, _aim - 10.5, -0.5) + (2.2,), polar(29.4, _aim - 8.6, 2.2) + (2.8,),
                         polar(26.4, _aim - 6.6, 3.9) + (2.8,), polar(23.8, _aim - 5.0, 4.7) + (2.4,),
                         polar(22.2, _aim - 3.8, 4.2) + (1.8,)], curve=True))
# Solid from where the root is clear of the paving (whose top is 0): below that it's scenery
# breaking up through the stone.
_root = start.limbs[0]
_root.solid_from = next(k for k in range(len(_root.points) - 1)
                        if min(_root.points[k][1] - _root.points[k][3] / 2, _root.points[k + 1][1] - _root.points[k + 1][3] / 2) > 0.05)
start.bearing = _aim
elements.append(sample_element(start))


def fork_maker(name, stage, knot_top, a_rise, b_rise, d_knot, d_tip, **options):
    return lambda bearing: fork(name, stage, bearing, knot_top, FORK_REACH, FORK_SPREAD, a_rise, b_rise, d_knot, d_tip, **options)


# Stage 1: three forks and the checkpoint fork, knots 8 apart, each turned round the trunk until
# the easiest crossing from the last one is the share of reach asked for.
elements.append(sample_element(fork("Fork 1", 1, FIRST_FORK, 10, FORK_REACH, FORK_SPREAD, 0.5, 7.0, 2.4, 1.6)))
place(fork_maker("Fork 2", 1, 18, 0.5, 7.0, 2.2, 1.5), elements[-1].bearing + 40, elements[-1].bearing + 170, 0.72)
place(fork_maker("Fork 3", 1, 26, 0.5, 7.0, 2.0, 1.35, dead_b=True), elements[-1].bearing + 40, elements[-1].bearing + 170, 0.75)
cp1 = place(fork_maker("The Great Fork", 1, 34, 0.5, 7.0, 3.2, 2.2), elements[-1].bearing + 40, elements[-1].bearing + 170, 0.72)
cp1.checkpoint = 1

# Stage 2: under the leaves. A thorn wheel turns round the trunk over the Thorn Fork's knot,
# the Leap Fork is a sprint away, and the Long Bough carries you out to the canopy's rim.
f5 = place(fork_maker("Thorn Fork", 2, 42, 0.5, 6.5, 1.7, 1.15), elements[-1].bearing + 40, elements[-1].bearing + 170, 0.78)
f5.hard = True
rotor("Thorn Wheel", (0, 42 + 3.55, 0), 9.6, 105, arms=3, around_trunk=True)
place(fork_maker("Leap Fork", 2, 50, 0.5, 5.0, 1.8, 1.3, flap_a={"angle": 6, "speed": 2.3, "phase": 0.0}),
      elements[-1].bearing + 40, elements[-1].bearing + 200, 1.08, sprint=True)

BOUGH_STATIONS = [
    # radius, bearing offset, top, diameter
    # It curls back round the trunk as it goes out, so it leaves the leaves in the gap between
    # two of the big side balls rather than straight into one.
    (4.0, 0, 59.8, 3.6),
    (11.0, -5, 56.4, 3.2),
    (17.5, -12, 53.2, 2.6),
    (23.5, -19, 54.2, 2.1),
    (29.0, -25, 58.2, 1.7),
    (36.5, -31, 63.6, 1.15),
]
lb = place(lambda bearing: bough("The Long Bough", 2, bearing, BOUGH_STATIONS, hinge=4,
                                 flap={"angle": 6.5, "speed": 1.7, "phase": 1.3}),
           elements[-1].bearing + 20, elements[-1].bearing + 160, 0.76)
lb.hard = True
# A thorn rotor beside the bough's sag, on a twig growing up off its far side.
_along = lerp(BOUGH_STATIONS[2], BOUGH_STATIONS[3], 0.55)
_axis = polar(_along[0], lb.trunk_bearing + _along[1], _along[2] - _along[3] / 2)
_side = math.radians(lb.trunk_bearing + _along[1] + 90)
_hub = (_axis[0] + 2.7 * math.cos(_side), _along[2] + 2.55, _axis[2] + 2.7 * math.sin(_side))
rotor("Bough Rotor", _hub, 3.8, -170, arms=2, post=_axis)

# Stages 3 and 4: limbs out of the crown, spiralling up round it.
CROWN = [
    # name, stage, rise, out, exit and tip diameters, motion, flap, share of reach, flags
    ("Leafbreak", 3, 3.0, 4.4, 2.6, 2.3, None, None, 0.7, {"checkpoint": 2}),
    ("Springer", 3, 3.3, 4.6, 1.6, 1.25, "flap", {"angle": 9, "speed": 2.1, "phase": 0.4}, 0.74, {}),
    ("Needle", 3, 3.3, 4.4, 1.5, 1.1, None, None, 0.8, {"hard": True}),
    ("Deadfall", 3, 3.3, 4.8, 1.6, 1.2, "snap", None, 0.74, {}),
    ("Long Reach", 3, 1.0, 4.6, 1.6, 1.3, None, None, 1.08, {"sprint": True, "rotor": True}),
    ("Whipcrack", 3, 3.3, 4.6, 1.5, 1.1, "flap", {"angle": 10, "speed": 2.5, "phase": 2.1}, 0.76, {}),
    ("Hollow Rung", 3, 3.3, 4.4, 1.5, 1.05, None, None, 0.8, {"hard": True}),
    ("Crow's Rest", 4, 3.3, 4.4, 2.8, 2.4, None, None, 0.72, {"checkpoint": 3}),
    ("Brittle", 4, 3.3, 4.8, 1.4, 1.0, "snap", None, 0.8, {"hard": True}),
    ("Thornguard", 4, 3.3, 4.6, 1.4, 1.05, None, None, 0.76, {"rotor": True}),
    ("Wide Gap", 4, 1.0, 4.6, 1.4, 1.1, "flap", {"angle": 8, "speed": 2.8, "phase": 0.9}, 1.08, {"sprint": True}),
    ("Rotten Rung", 4, 3.3, 4.8, 1.3, 1.0, "snap", None, 0.78, {}),
    ("Hairline", 4, 3.3, 4.4, 1.3, 0.95, None, None, 0.82, {"hard": True}),
    ("Gale Twig", 4, 3.3, 4.6, 1.3, 1.0, "flap", {"angle": 11, "speed": 2.6, "phase": 1.7}, 0.78, {"rotor": True}),
    ("Deadwood Crown", 4, 3.3, 4.6, 1.3, 1.0, "snap", None, 0.8, {"hard": True}),
    ("Lookout", 4, 3.2, 4.4, 1.4, 1.1, None, None, 0.76, {}),
]
top = BOUGH_STATIONS[-1][2]
for index, (name, stage, rise, out, d_exit, d_tip, motion, flap, target, flags) in enumerate(CROWN):
    top += rise
    make = (lambda name, stage, top, out, d_exit, d_tip, motion, flap:
            lambda bearing: stub(name, stage, bearing, top, out, d_exit, d_tip, motion=motion, flap=flap))(
        name, stage, top, out, d_exit, d_tip, motion, flap)
    element = place(make, elements[-1].bearing + 4, elements[-1].bearing + 90, target, sprint=flags.get("sprint", False))
    element.checkpoint = flags.get("checkpoint")
    element.hard = flags.get("hard", False)
    if flags.get("rotor"):
        # On a twig growing up beside the limb just out of the leaves, turning over its tip.
        limb = element.limbs[-1]
        cut, tip = limb.points[limb.solid_from], limb.points[-1]
        base = lerp(cut, tip, 0.2)
        hub = lerp(cut, tip, 0.62)
        across = (-(tip[2] - cut[2]), tip[0] - cut[0])
        length = math.hypot(*across) or 1
        side = 1 if index % 2 else -1
        hub = (hub[0] + across[0] / length * 1.7 * side, tip[1] + tip[3] / 2 + 2.6, hub[2] + across[1] / length * 1.7 * side)
        rotor(name + " Rotor", hub, 3.5, 150 if index % 2 else -160, arms=2, thickness=0.6, post=base[:3])

# Over the crown to the summit: twigs up through the top of the leaves.
# Topknot's radius puts the last jump, onto the summit, at the same share of reach as the rest.
k1 = place(lambda bearing: knob("Crown Twig", 4, bearing, 15.5, top + 3.2), elements[-1].bearing + 4, elements[-1].bearing + 120, 0.74)
_rise = SUMMIT_TOP - (top + 6.5)
_topknot_radius = SUMMIT_DIAMETER / 2 + 0.72 * reach(WALK, _rise, False) + 0.65
k2 = place(lambda bearing: knob("Topknot", 4, bearing, _topknot_radius, top + 6.5, d_knob=1.3),
           elements[-1].bearing + 4, elements[-1].bearing + 150, 0.74)

summit = Element("Summit", "summit", 4)
summit.balls.append((CROWN_CENTRE[0], SUMMIT_TOP - 0.5, CROWN_CENTRE[2], SUMMIT_DIAMETER, True))
summit.bearing = 0
elements.append(sample_element(summit))

START_INDEX = 0

for element in elements:
    sample_element(element)

# Static things you can stand on that aren't the course: bench seats and backs, root tops.
STATICS = []
for centre, axes, half, name in OBSTACLES:
    if name == "bench":
        for fa in (-0.9, 0, 0.9):
            for fc in (-0.9, -0.45, 0, 0.45, 0.9):
                p = tuple(centre[i] + axes[1][i] * half[1] + axes[0][i] * half[0] * fa + axes[2][i] * half[2] * fc for i in range(3))
                if radius_of(p) > trunk_radius(p[1]):
                    STATICS.append((p[0], p[1], p[2], 0.3, name))
for root in ROOTS:
    for a, b, d in root.solid_segments():
        for t in (0, 0.5, 1):
            p = lerp(a[:3], b[:3], t)
            STATICS.append((p[0], p[1] + d / 2, p[2], d / 2, "root"))


problems, notes = [], []
# The easiest crossing of every jump, for tools/climb_gallery.lua to have a rig actually make.
jumps = []

# 1. Every jump on the route is possible, and a real jump.
for index in range(len(elements) - 1):
    a, b = elements[index], elements[index + 1]
    walk = best_jump(a, b, WALK, False)
    sprint = best_jump(a, b, SPRINT, False)
    tag = f"{a.name} -> {b.name}"
    if walk is None and sprint is None:
        problems.append(f"{tag}: no pair of spots within reach at all")
        continue
    chosen = sprint if b.sprint else (walk or sprint)
    jumps.append((tag, chosen[3], chosen[4], b.sprint, chosen[0]))
    if b.sprint:
        if walk and walk[0] < 1.04:
            problems.append(f"{tag}: meant as a sprint leap but a walking jump makes it (gap {walk[1]:.2f}, rise {walk[2]:+.2f}, {walk[0]:.2f} of reach)")
        if not sprint or sprint[0] > 0.86:
            problems.append(f"{tag}: sprint leap too long ({sprint[0] if sprint else 'n/a'})")
        notes.append(f"{tag}: SPRINT gap {sprint[1]:.2f} rise {sprint[2]:+.2f} = {sprint[0]:.2f} of sprint reach, {walk[0] if walk else 9:.2f} of walking, {where(sprint[3])} -> {where(sprint[4])}")
    else:
        if walk is None or walk[0] > 0.9:
            problems.append(f"{tag}: too long to walk-jump ({walk[0] if walk else 'n/a'})")
            continue
        limit = (0.66, 0.9) if b.hard else (0.55, 0.86)
        if index == START_INDEX:
            limit = (0.3, 0.8)
        if walk[0] < limit[0] and b.kind not in ("summit",):
            problems.append(f"{tag}: too easy, {walk[0]:.2f} of reach (gap {walk[1]:.2f}, rise {walk[2]:+.2f})")
        notes.append(f"{tag}: gap {walk[1]:.2f} rise {walk[2]:+.2f} = {walk[0]:.2f} of reach, {where(walk[3])} -> {where(walk[4])}")
    if walk and walk[1] < 1.8 and b.kind != "summit":
        problems.append(f"{tag}: the easiest crossing is a {walk[1]:.2f} gap, a step rather than a jump")

# 2. Nothing skips ahead: from any element, nothing two or more further on is reachable even
#    sprinting with generous reach.
for i, a in enumerate(elements):
    for j in range(i + 2, len(elements)):
        b = elements[j]
        top_a = max(s[1] for s in a.samples)
        low_b = min(s[1] for s in b.samples)
        if low_b - top_a > MAX_RISE + 0.5:
            continue
        found = best_jump(a, b, SPRINT, True)
        if found and found[0] < 1.05:
            problems.append(f"skip: {a.name} -> {b.name} (gap {found[1]:.2f}, rise {found[2]:+.2f}, {found[0]:.2f} of sprint reach)")
# ...including from the benches and roots.
for x, y, z, hw, name in STATICS:
    probe = Element(name, "static", 0)
    probe.samples = [(x, y, z, hw, None)]
    for j in range(2, len(elements)):
        found = best_jump(probe, elements[j], SPRINT, True)
        if found and found[0] < 1.05:
            problems.append(f"skip from a {name}: -> {elements[j].name} ({found[0]:.2f} of sprint reach)")

# 3. Nothing solid clips anything else: limbs of different elements, the obstacles, the trunk
#    (outside the knot a limb grows from).
def solid_parts(element):
    for limb in element.limbs:
        for a, b, d in limb.solid_segments():
            yield a[:3], b[:3], d / 2
    for x, y, z, d, solid in element.balls:
        if solid and element.kind != "summit":
            yield (x, y, z), (x, y, z), d / 2


for i, a in enumerate(elements):
    for j in range(i + 1, len(elements)):
        b = elements[j]
        for p1, q1, r1 in solid_parts(a):
            for p2, q2, r2 in solid_parts(b):
                if abs((p1[1] + q1[1]) / 2 - (p2[1] + q2[1]) / 2) > 40:
                    continue
                if seg_seg(p1, q1, p2, q2) < r1 + r2 + 0.3:
                    problems.append(f"clip: {a.name} and {b.name}")
                    break
            else:
                continue
            break
    for root_index, root in enumerate(ROOTS):
        if any(seg_seg(p1, q1, ra[:3], rb[:3]) < r1 + rd / 2 + 0.3
               for p1, q1, r1 in solid_parts(a) for ra, rb, rd in root.solid_segments()):
            problems.append(f"clip: {a.name} and root {root_index + 1}")
    for p1, q1, r1 in solid_parts(a):
        for t in (0, 0.25, 0.5, 0.75, 1):
            p = lerp(p1, q1, t)
            hit = in_obstacle(p, r1 + 0.2)
            if hit:
                problems.append(f"clip: {a.name} into a {hit} at {tuple(round(v, 1) for v in p)}")
                break
            if 0 < p[1] < TRUNK_HEIGHT and radius_of(p) < trunk_radius(p[1]) + r1 - 0.05 and radius_of(p) > 0:
                # a limb's own knot end touches the trunk by design; anything else is a clip
                if dist(p, p1) > 0.2 or a.kind not in ("fork", "bough", "stub"):
                    problems.append(f"clip: {a.name} into the trunk at {tuple(round(v, 1) for v in p)}")
                    break

# ...and the roots don't run into the benches or the statue, or bury more than their dipping tips
# in the paving.
for root_index, root in enumerate(ROOTS):
    segments = list(root.solid_segments())
    for number, (a, b, d) in enumerate(segments):
        # The last few segments dive into the paving on purpose.
        if number >= len(segments) - 3:
            break
        for t in (0, 0.5, 1):
            p = lerp(a[:3], b[:3], t)
            hit = in_obstacle(p, d / 2 + 0.2)
            if hit:
                problems.append(f"clip: root {root_index + 1} into a {hit} at {tuple(round(v, 1) for v in p)}")
            if radius_of(p) < 16 and p[1] - d / 2 < -0.05:
                problems.append(f"root {root_index + 1} sunk into the paving at {tuple(round(v, 1) for v in p)}")

# 4. Headroom: a body standing anywhere on a limb doesn't have another limb through it.
def body_blocked(sample, owner):
    x, y, z, hw, limb = sample
    feet, head = (x, y + 0.3, z), (x, y + 4.8, z)
    for element in elements:
        if element is owner:
            continue
        for p, q, r in solid_parts(element):
            if abs((p[1] + q[1]) / 2 - y) > 25:
                continue
            if seg_seg(feet, head, p, q) < r + 0.9:
                return element.name
    return None


for element in elements:
    blocked = {}
    for sample in element.samples[:: 2]:
        who = body_blocked(sample, element)
        if who:
            blocked[who] = blocked.get(who, 0) + 1
    for who, count in blocked.items():
        problems.append(f"headroom: standing on {element.name}, {who} is through you ({count} spots)")

# 5. Landing tips out in the open: a body on the far end of every limb is clear of the leaves.
for element in elements:
    if element.kind in ("stub", "fork", "bough"):
        for limb in element.limbs:
            if limb.solid_from >= len(limb.points) or limb.points[-1] is None:
                continue
            tip = limb.points[-1]
            for h in (0.5, 2.5, 4.5):
                if in_foliage((tip[0], tip[1] + tip[3] / 2 + h, tip[2]), -0.6):
                    notes.append(f"leaves: {element.name}'s tip has a body in the leaves at +{h}")
                    break

# 7. EXPOSED SCENERY (#28): no segment that a player can SEE may be non-solid.
#
# A scenery segment is meant to be buried in the trunk or the leaves. LobbyService draws it as
# ordinary wood and only clears its collision, so one that is out in the open is visible branch you
# fall through. PLANTED FAULT: a synthetic limb held out in clear air with every segment marked
# scenery must be caught here, every run -- if it is not, this check has stopped working and the
# build fails whatever the real course measures.
PLAZA_TOP = 0.5
LEAF_SKIN = 0.35


def exposed_scenery(limb):
    """Scenery segments whose centre line is outside the trunk, outside the leaves and above the
    plaza paving, with how many studs of each are in the open."""
    out = []
    for k, a, b, d in limb.segments():
        if k >= limb.solid_from:
            continue
        n = 9
        open_air = 0
        worst = None
        for i in range(n + 1):
            p = lerp(a, b, i / n)
            # Wood whose UNDERSIDE is in the paving is standing on the paving: the Start root is
            # meant to break up through the stone, and nothing there can drop a player, because the
            # stone is under it. Testing the underside rather than the centre line is what makes
            # this a reason instead of a fudge.
            if p[1] - p[3] / 2 <= PLAZA_TOP:
                continue
            # The same wood_hidden the cut uses, so the check and the generator cannot drift apart.
            if not wood_hidden(p, LEAF_SKIN):
                open_air += 1
                worst = worst or p
        if open_air:
            out.append((k, dist(a, b) * open_air / (n + 1), worst, d))
    return out


_plant = Limb([(0.0, 200.0, 60.0, 2.0), (6.0, 200.0, 60.0, 2.0), (12.0, 200.0, 60.0, 2.0)])
_plant.solid_from = len(_plant.points)
if not exposed_scenery(_plant):
    problems.append("PLANTED FAULT MISSED: the exposed-scenery check no longer sees open-air scenery")
_buried = Limb([(0.0, 20.0, 0.0, 2.0), (1.0, 20.0, 0.0, 2.0), (2.0, 20.0, 0.0, 2.0)])
_buried.solid_from = len(_buried.points)
if exposed_scenery(_buried):
    problems.append("PLANTED FAULT MISSED: the exposed-scenery check calls buried wood exposed")

_exposed_total, _exposed_count, _declared = 0.0, 0, 0
for element in elements:
    for limb in element.limbs:
        if limb.decorative:
            _declared += 1
            continue
        for k, studs, worst, d in exposed_scenery(limb):
            _exposed_count += 1
            _exposed_total += studs
            # A gap under 1 stud along a limb cannot drop anybody: a player capsule is about 2
            # studs across, so it bridges the solid wood either side of it. The Long Bough's 0.7
            # stud at the trunk face is of that kind -- the trunk is on one side of it and solid
            # bough on the other. The TOTAL is reported either way, so nothing is hidden by this.
            if studs >= 1.0:
                problems.append(
                    f"exposed scenery: {element.name} segment {k} is {studs:.1f} studs of visible "
                    f"{d:.2f}-wide branch with no collision at {tuple(round(v, 1) for v in worst)}")
notes.append(f"exposed scenery: {_exposed_count} segment(s), {_exposed_total:.1f} studs; "
             f"{_declared} limb(s) exempt as declared decorative (the knob stalks); "
             f"2 planted faults checked")

# 6. Rotors: clear of every limb they don't sit on, and actually crossing a standing spot.
for rotor_spec in rotors:
    hx, hy, hz = rotor_spec["hub"]
    reach_out = rotor_spec["arm"] + rotor_spec["thickness"] / 2
    band = rotor_spec["thickness"] / 2
    inner = trunk_radius(hy) + 0.35 if rotor_spec["trunk"] else 0
    for element in elements:
        for p, q, r in solid_parts(element):
            n = max(1, int(dist(p, q) / 0.3))
            for i in range(n + 1):
                s = lerp(p, q, i / n)
                h = math.hypot(s[0] - hx, s[2] - hz)
                if h - r <= reach_out and h + r >= inner and abs(s[1] - hy) < band + r + 0.15:
                    problems.append(f"rotor {rotor_spec['name']} hits {element.name} at {tuple(round(v, 1) for v in s)}")
                    break
            else:
                continue
            break
    threatened = 0
    for element in elements:
        for x, y, z, hw, limb in element.samples:
            if math.hypot(x - hx, z - hz) <= rotor_spec["arm"] and y + 0.4 < hy < y + 4.6:
                threatened += 1
    if threatened < 6:
        problems.append(f"rotor {rotor_spec['name']} sweeps over only {threatened} standing spots")
    notes.append(f"rotor {rotor_spec['name']}: sweeps {threatened} standing spots")

# --- Report --------------------------------------------------------------------------------------
for line in notes:
    print("  " + line)
print(f"{len(elements)} elements, {len(rotors)} rotors, "
      f"{sum(1 for e in elements for l in e.limbs for _ in l.solid_segments())} solid limb segments")
for p in problems:
    print("PROBLEM " + p)


# --- Output --------------------------------------------------------------------------------------
def v(p):
    return "{ %.2f, %.2f, %.2f }" % tuple(p[:3])


def lua_limb(limb):
    points = ", ".join("{ %.2f, %.2f, %.2f, %.2f }" % p for p in limb.points)
    fields = [f"points = {{ {points} }}", f"solidFrom = {limb.solid_from + 1}"]
    if limb.motion:
        fields.append(f'motion = "{limb.motion}"')
    if limb.dead:
        fields.append("dead = true")
    if limb.round_tip and limb.solid_from < len(limb.points) - 1:
        fields.append("roundTip = true")
    if limb.flap:
        fields.append("flap = { angle = %.1f, speed = %.2f, phase = %.2f }" % (limb.flap["angle"], limb.flap["speed"], limb.flap["phase"]))
    return "{ " + ", ".join(fields) + " }"


lines = [
    "-- GENERATED by tools/climb_design.py -- edit that and rerun it, don't edit this by hand.",
    "--",
    "-- The Cloud Climb's course, relative to the foot of the Rot Tree: every branch you climb, in",
    "-- the order you climb them. The script checks every jump against reach measured in Studio",
    "-- (tools/jump_probe.lua), that nothing lets you skip ahead, that no limb runs through another",
    "-- or through a body standing on one, and that each rotor clears the limbs it turns over.",
    "--",
    "-- A limb is a centre line of { x, y, z, diameter } points, built as a cylinder per segment",
    "-- and a ball at each bend; segments before solidFrom are inside the trunk or the leaves and",
    "-- don't collide. motion \"snap\" limbs are deadwood that breaks under you, \"flap\" limbs",
    "-- bounce about their first point.",
    "",
    "return {",
    f"\ttrunk = {{ height = {TRUNK_HEIGHT}, lengths = {TRUNK_LENGTHS}, bottomRadius = {TRUNK_BOTTOM_RADIUS}, topRadius = {TRUNK_TOP_RADIUS} }},",
    f"\tsummitTop = {SUMMIT_TOP:.2f},",
    f"\tsummitDiameter = {SUMMIT_DIAMETER:.2f},",
    "\telements = {",
]
for element in elements:
    if element.kind == "summit":
        continue
    fields = [f'name = "{element.name}"', f'kind = "{element.kind}"', f"stage = {element.stage}"]
    if element.checkpoint:
        fields.append(f"checkpoint = {element.checkpoint}")
    if element.sprint:
        fields.append("sprint = true")
    lines.append("\t\t{ " + ", ".join(fields) + ",")
    lines.append("\t\t\tlimbs = {")
    for limb in element.limbs:
        lines.append("\t\t\t\t" + lua_limb(limb) + ",")
    lines.append("\t\t\t},")
    if element.balls:
        lines.append("\t\t\tballs = { " + ", ".join("{ %.2f, %.2f, %.2f, %.2f }" % b[:4] for b in element.balls) + " },")
    if element.collars:
        lines.append("\t\t\tcollars = { " + ", ".join("{ from = %s, to = %s, diameter = %.2f }" % (v(a), v(b), d) for a, b, d in element.collars) + " },")
    lines.append("\t\t},")
lines.append("\t},")
lines.append("\t-- The tree's roots: solid, walkable ramps up to the trunk, so the skip check has them too.")
lines.append("\troots = {")
for root in ROOTS:
    lines.append("\t\t" + lua_limb(root) + ",")
lines.append("\t},")
lines.append("\trotors = {")
for r in rotors:
    fields = [f'name = "{r["name"]}"', f"hub = {v(r['hub'])}", f"arm = {r['arm']:.2f}", f"speed = {r['speed']}",
              f"arms = {r['arms']}", f"thickness = {r['thickness']:.2f}"]
    if r.get("post"):
        fields.append(f"post = {v(r['post'])}")
    if r["trunk"]:
        fields.append("aroundTrunk = true")
    lines.append("\t\t{ " + ", ".join(fields) + " },")
lines.append("\t},")
lines.append("\t-- The easiest crossing of each jump (standing spots on top of the limbs) and its share of")
lines.append("\t-- reach, walking or, for a sprint leap, sprinting. tools/climb_gallery.lua has a rig make them.")
lines.append("\tjumps = {")
for tag, p, q, sprint_leap, ratio in jumps:
    lines.append('\t\t{ name = "%s", from = %s, fromWidth = %.2f, to = %s, toWidth = %.2f, sprint = %s, share = %.2f },'
                 % (tag, v(p), p[3] * 2, v(q), q[3] * 2, "true" if sprint_leap else "false", ratio))
lines.append("\t},")
lines.append("}")
lines.append("")

text = "\n".join(lines)
if CHECK_ONLY:
    current = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
    if current != text:
        # Say WHAT differs, not just that something does. An outside contributor cannot rerun the
        # generator (this file is outside every task brief's ownership) and cannot see this machine,
        # so a bare "out of date" is unactionable and gets pasted into pull requests as a failure
        # nobody caused. Reported 2026-09-21 by the outside clone, where it fires on pristine main;
        # it does not reproduce here, so the check now carries its own evidence.
        a, b = current.split("\n"), text.split("\n")
        where = None
        if not current:
            where = "the file is missing"
        else:
            for i in range(min(len(a), len(b))):
                if a[i] != b[i]:
                    where = "first difference at line %d; on disk %.100r, generated %.100r" % (
                        i + 1, a[i], b[i])
                    break
            if where is None:
                where = "every shared line agrees; %d lines on disk against %d generated" % (
                    len(a), len(b))
        problems.append(
            "CloudClimbCourse.lua is out of date: rerun python tools/climb_design.py (" + where + ")")
        print("PROBLEM " + problems[-1])
else:
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote " + os.path.relpath(OUT, ROOT))
sys.exit(1 if problems else 0)
