"""Geometry of the mountable guns, for tools/mounted_guns_check.py (and nothing else).

Runs the PURE block of ReplicatedStorage/Shared/MountedGunModels.lua under lupa and turns its layout into
oriented boxes (a cylinder or ball is held to its bounding box, which only ever over-reports a touch), then
poses the gun at any yaw and pitch the way the Motor6Ds do: the pitch pivot's parts tip about its X axis,
then everything on the yaw pivot turns about its Y axis.
"""

import math
import re
from pathlib import Path

from lupa import LuaRuntime


def pure_source(repo):
    text = (Path(repo) / "ReplicatedStorage/Shared/MountedGunModels.lua").read_text(encoding="utf-8")
    m = re.search(r"-- PURE BEGIN\n(.*?)-- PURE END", text, re.S)
    if not m:
        raise SystemExit("MountedGunModels.lua has no PURE block")
    return m.group(1) + "\nreturn Pure\n"


def load(repo, source=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    pure = lua.execute(source or pure_source(repo))
    return lua, pure


def vec(t):
    return [float(t[1]), float(t[2]), float(t[3])]


def mat(t):
    r = [float(t[i]) for i in range(1, 10)]
    return [[r[0], r[1], r[2]], [r[3], r[4], r[5]], [r[6], r[7], r[8]]]


def layout(pure, kind):
    L = pure.Layout(kind)
    parts = []
    for i in range(1, len(L.parts) + 1):
        p = L.parts[i]
        parts.append({
            "name": p.name, "shape": p.shape, "size": vec(p.size), "pos": vec(p.pos), "m": mat(p.m),
            "group": p.group, "collide": bool(p.collide), "shield": bool(p.shield),
        })
    pivots = {k: {"pos": vec(v.pos), "parent": v.parent} for k, v in L.pivots.items()}
    markers = {k: {"pos": vec(v.pos), "m": mat(v.m), "on": v.on} for k, v in L.markers.items()}
    return {"parts": parts, "pivots": pivots, "markers": markers, "muzzle": vec(L.muzzle), "seat": vec(L.seat),
            "eyeZ": float(L.eyeZ)}


# ---- small linear algebra -------------------------------------------------------------------------

def mmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def mv(a, v):
    return [sum(a[i][k] * v[k] for k in range(3)) for i in range(3)]


def add(a, b):
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]


def sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def norm(a):
    return math.sqrt(dot(a, a))


def rx(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def ry(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


RIDES_PITCH = {"pitch", "recoil", "belt", "bolt"}


def pose_point(lay, group, p, yaw, pitch):
    """A model-space point of `group` with the gun at yaw/pitch (degrees)."""
    yp = lay["pivots"]["TurretYaw"]["pos"]
    pp = lay["pivots"]["TurretPitch"]["pos"]
    if group in RIDES_PITCH:
        p = add(pp, mv(rx(pitch), sub(p, pp)))
    if group != "base":
        p = add(yp, mv(ry(yaw), sub(p, yp)))
    return p


def pose_rot(group, m, yaw, pitch):
    if group in RIDES_PITCH:
        m = mmul(rx(pitch), m)
    if group != "base":
        m = mmul(ry(yaw), m)
    return m


def obb(part, yaw=0.0, pitch=0.0, grow=0.0):
    c = pose_point(part["_lay"], part["group"], part["pos"], yaw, pitch)
    m = pose_rot(part["group"], part["m"], yaw, pitch)
    axes = [[m[0][j], m[1][j], m[2][j]] for j in range(3)]
    half = [s / 2 + grow for s in part["size"]]
    return c, axes, half


def obb_overlap(a, b, margin=0.0):
    """Separating-axis test; True when the boxes overlap by more than `margin` on every axis."""
    ca, aa, ha = a
    cb, ab, hb = b
    d = sub(cb, ca)
    axes = list(aa) + list(ab)
    for u in aa:
        for v in ab:
            c = cross(u, v)
            n = norm(c)
            if n > 1e-6:
                axes.append([c[0] / n, c[1] / n, c[2] / n])
    for axis in axes:
        ra = sum(ha[i] * abs(dot(aa[i], axis)) for i in range(3))
        rb = sum(hb[i] * abs(dot(ab[i], axis)) for i in range(3))
        if abs(dot(d, axis)) > ra + rb - margin:
            return False
    return True


def ray_box(origin, direction, box, length):
    """Distance along the ray to the box, or None."""
    c, axes, half = box
    tmin, tmax = 0.0, length
    rel = sub(origin, c)
    for i in range(3):
        o = dot(rel, axes[i])
        d = dot(direction, axes[i])
        if abs(d) < 1e-9:
            if abs(o) > half[i]:
                return None
            continue
        t1, t2 = (-half[i] - o) / d, (half[i] - o) / d
        if t1 > t2:
            t1, t2 = t2, t1
        tmin, tmax = max(tmin, t1), min(tmax, t2)
        if tmin > tmax:
            return None
    return tmin


def attach(lay):
    for p in lay["parts"]:
        p["_lay"] = lay
    return lay
