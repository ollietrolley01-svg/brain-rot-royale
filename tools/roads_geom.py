"""Plain geometry for tools/roads_check.py: the top face of a road piece, point-in-piece, 2D convex hulls
and polygon overlap. Nothing here knows about roads; see roads_check.py for what is measured."""

import math


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def add(a, b, s=1.0):
    return (a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s)


class Piece:
    """A part's upper face as something you can stand a point on.

    Boxes: the face whose outward normal points most nearly up. Flat wedges (a curve's side pieces and
    a pavement taper, built by MapDecor.Triangle with their X axis vertical): the triangular X face on
    top, the solid half being the side of the hypotenuse holding the right angle at local (-Y, +Z).
    """

    __slots__ = ("part", "name", "kind", "n", "c", "a1", "a2", "e1", "e2", "thick", "tri", "bbox", "bottom_c")

    def __init__(self, part):
        self.part = part
        self.name = part["name"]
        axes = (part["r"], part["u"], part["b"])
        size = part["size"]
        idx = max(range(3), key=lambda i: abs(axes[i][1]))
        sign = 1.0 if axes[idx][1] > 0 else -1.0
        n = tuple(v * sign for v in axes[idx])
        half = size[idx] / 2
        self.n = n
        self.c = add(part["p"], n, half)
        self.bottom_c = add(part["p"], n, -half)
        self.thick = size[idx]
        others = [i for i in range(3) if i != idx]
        self.a1, self.a2 = axes[others[0]], axes[others[1]]
        self.e1, self.e2 = size[others[0]] / 2, size[others[1]] / 2
        self.tri = part["cls"] == "WedgePart" and idx == 0
        if part["cls"] == "WedgePart" and idx != 0:
            # An upright wedge (a ramp): treated as its box. None of the road surfaces is one.
            self.tri = False
        self.kind = "tri" if self.tri else "box"
        # XZ bounding box of the top face.
        xs, zs = [], []
        for s1 in (-1, 1):
            for s2 in (-1, 1):
                p = add(add(self.c, self.a1, s1 * self.e1), self.a2, s2 * self.e2)
                xs.append(p[0])
                zs.append(p[2])
        self.bbox = (min(xs), max(xs), min(zs), max(zs))

    def top_y(self, x, z):
        n, c = self.n, self.c
        return c[1] - ((x - c[0]) * n[0] + (z - c[2]) * n[2]) / n[1]

    def local(self, x, z):
        y = self.top_y(x, z)
        d = (x - self.c[0], y - self.c[1], z - self.c[2])
        return dot(d, self.a1), dot(d, self.a2), y

    def inside(self, x, z, eps=0.0):
        """Signed clearance of (x, z) inside the face (positive inside), and the face's height there."""
        l1, l2, y = self.local(x, z)
        clear = min(self.e1 - abs(l1), self.e2 - abs(l2))
        if self.tri:
            # a1 is the wedge's Y, a2 its Z (the X axis is the vertical one).
            hy, hz = self.e1, self.e2
            f = (l2 + hz) * 2 * hy - (l1 + hy) * 2 * hz
            clear = min(clear, f / math.hypot(2 * hy, 2 * hz))
        return clear, y

    def polygon(self, inset=0.0):
        """The top face's outline in XZ, `inset` studs in from its sides."""
        if self.tri:
            # Right angle at (Y=-e1, Z=+e2); legs to (Y=+e1, Z=+e2) and (Y=-e1, Z=-e2).
            pts = [(-1, 1), (1, 1), (-1, -1)]
        else:
            pts = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        out = []
        for s1, s2 in pts:
            p = add(add(self.c, self.a1, s1 * max(0.0, self.e1 - inset)), self.a2, s2 * max(0.0, self.e2 - inset))
            out.append((p[0], p[2]))
        return out


def corners(part):
    """A part's eight box corners in world space."""
    p, r, u, b = part["p"], part["r"], part["u"], part["b"]
    sx, sy, sz = (s / 2 for s in part["size"])
    out = []
    for i in (-1, 1):
        for j in (-1, 1):
            for k in (-1, 1):
                out.append(add(add(add(p, r, i * sx), u, j * sy), b, k * sz))
    return out


def hull(points):
    """Convex hull of 2D points, counter-clockwise."""
    pts = sorted(set((round(x, 5), round(z, 5)) for x, z in points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def ccw(poly):
    area = 0.0
    for i in range(len(poly)):
        x0, z0 = poly[i]
        x1, z1 = poly[(i + 1) % len(poly)]
        area += x0 * z1 - x1 * z0
    return poly if area >= 0 else list(reversed(poly))


def clip(subject, clipper):
    """Sutherland-Hodgman: subject polygon clipped to a convex clipper (both counter-clockwise)."""
    out = list(subject)
    for i in range(len(clipper)):
        if not out:
            break
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]

        def side(p):
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
        src, out = out, []
        for j in range(len(src)):
            p, q = src[j], src[(j + 1) % len(src)]
            sp, sq = side(p), side(q)
            if sp >= 0:
                out.append(p)
            if (sp >= 0) != (sq >= 0):
                t = sp / (sp - sq)
                out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out


def area(poly):
    s = 0.0
    for i in range(len(poly)):
        x0, z0 = poly[i]
        x1, z1 = poly[(i + 1) % len(poly)]
        s += x0 * z1 - x1 * z0
    return abs(s) / 2


def overlap_area(a, b):
    if len(a) < 3 or len(b) < 3:
        return 0.0
    return area(clip(ccw(a), ccw(b)))
