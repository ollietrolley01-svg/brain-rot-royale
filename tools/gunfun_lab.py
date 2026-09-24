"""The gun rework's offline workbench: build any gun with the REAL GunModels (and every Shared module it
pulls in) under lupa, dump its parts and contract, draw it, and check its sight line. No Studio.

    python3 tools/gunfun_lab.py dump   <repo> <weaponId>            parts, keypoints, attributes
    python3 tools/gunfun_lab.py render <repo> <outdir> [ids...]     PNG views per gun (side, 3/4, ADS, hip)
    python3 tools/gunfun_lab.py sight  <repo> [ids...]              sight-line check (exit 1 on a finding)

Rendering is a small z-buffered rasteriser over the built parts (boxes, wedges, cylinders along their own
X, balls), so what it draws is the frame the game shows after the z-fight pass -- the same parts
gun_tube_check reads. It is a picture for a person to judge shape and proportion by, NOT a Roblox render:
no materials beyond a neon/glass distinction, no SurfaceGuis, no lighting model. Oliver's machine renders
the real thing (tools/gunfun_gallery.lua).

The sight check: the eye sits EyeRelief studs behind KP_Sight on its line, and the line runs from the
eye out to 200 studs. Anything solid on that line (a part whose volume it crosses) is a finding unless
it is part of the sight picture -- a part whose name says it is a sight, a lens, a reticle, a dot, a
scope's own tube (scoped guns hand over to the full-screen scope, so their tube is solid by design) or
glass. Examined-count and flagged-count are both printed. A planted fault (a slab laid across the line
on the first gun checked) must be caught, or the check says so and fails.
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gun_tube_check import EXTRA, load_sources  # noqa: E402
from vehicle_models_axis_check import MOCK  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

DUMP = r"""
function weaponData() return require(handle("WeaponData")) end
function dumpGun(id)
	local GunModels = require(handle("GunModels"))
	local WeaponData = require(handle("WeaponData"))
	local Rarity = require(handle("Rarity"))
	local def = WeaponData.Get(id)
	if not def then return nil, "no weapon " .. tostring(id) end
	local ok, model = pcall(GunModels.Build, def, Rarity.Color(def.rarity), Enum.Material.Metal, {})
	if not ok then return nil, tostring(model) end
	local mm = GunModels.StudsPerMillimetre
	local parts = {}
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") then
			local c = p.CFrame
			local col = p.Color or Color3.new(0.5, 0.5, 0.5)
			parts[#parts + 1] = {
				p.Name, p.ClassName, tostring(p.Shape), p.Size.X / mm, p.Size.Y / mm, p.Size.Z / mm,
				c.p.X / mm, c.p.Y / mm, c.p.Z / mm, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z,
				col.R or 0.5, col.G or 0.5, col.B or 0.5, tostring(p.Material), p.Transparency or 0,
				p:GetAttribute("Anim") or "",
			}
		end
	end
	local attrs = {}
	for k, v in pairs(model:GetAttributes()) do
		if typeof(v) == "CFrame" then
			attrs[k] = { v.p.X / mm, v.p.Y / mm, v.p.Z / mm, v.b.X, v.b.Y, v.b.Z, v.u.X, v.u.Y, v.u.Z }
		else
			attrs[k] = v
		end
	end
	return { parts = parts, attrs = attrs, def = def }
end
"""


class Lab:
    def __init__(self, repo, sources=None):
        self.repo = repo
        self.sources = sources or load_sources(repo)
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCK)
        src = self.lua.table()
        for k, v in self.sources.items():
            src[k] = v
        self.lua.globals().SOURCES = src
        # One chunk: EXTRA's module loader (`handle`) is local to it.
        self.lua.execute(EXTRA + "\n" + DUMP)

    def ids(self):
        wd = self.lua.globals().weaponData()
        return sorted(wd.Weapons.keys())

    def gun(self, gid):
        res = self.lua.globals().dumpGun(gid)
        out, err = (res if isinstance(res, tuple) else (res, None))
        if out is None:
            raise RuntimeError(f"{gid}: {err}")
        parts = []
        rows = out.parts
        for i in range(1, len(rows) + 1):
            v = [rows[i][j] for j in range(1, 25)]
            parts.append({
                "name": v[0], "cls": v[1], "shape": v[2].split(".")[-1], "size": v[3:6], "pos": v[6:9],
                "cols": (v[9:12], v[12:15], v[15:18]), "color": v[18:21], "mat": v[21].split(".")[-1],
                "trans": v[22] or 0, "anim": v[23],
            })
        attrs = {}
        for k in out.attrs.keys():
            val = out.attrs[k]
            if hasattr(val, "keys") and not isinstance(val, str):
                attrs[k] = [val[j] for j in range(1, 10)]
            else:
                attrs[k] = val
        d = out["def"]
        return {"id": gid, "parts": parts, "attrs": attrs, "style": d.style, "rarity": d.rarity, "name": d.name}


# ------------------------------------------------------------------------------------------------ geometry

def _box_tris(hx, hy, hz):
    v = [(sx * hx, sy * hy, sz * hz) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    idx = lambda sx, sy, sz: ((sx > 0) * 4 + (sy > 0) * 2 + (sz > 0))
    faces = [
        [(1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)], [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)],
        [(-1, 1, -1), (-1, 1, 1), (1, 1, 1), (1, 1, -1)], [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)],
        [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)], [(-1, -1, -1), (-1, 1, -1), (1, 1, -1), (1, -1, -1)],
    ]
    tris = []
    for f in faces:
        q = [v[idx(*c)] for c in f]
        tris.append((q[0], q[1], q[2]))
        tris.append((q[0], q[2], q[3]))
    return tris


def _wedge_tris(hx, hy, hz):
    # Roblox wedge: bottom face full, back (+Z) face full, the slope from the top back edge to the bottom
    # front edge.
    a = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, -hy, hz), (-hx, -hy, hz)]  # bottom
    t = [(-hx, hy, hz), (hx, hy, hz)]  # top back edge
    tris = [(a[0], a[1], a[2]), (a[0], a[2], a[3]),
            (a[3], a[2], t[1]), (a[3], t[1], t[0]),  # back
            (a[0], t[0], t[1]), (a[0], t[1], a[1]),  # slope
            (a[0], a[3], t[0]), (a[1], t[1], a[2])]  # sides
    return tris


def _cyl_tris(hx, r, n=16):
    tris = []
    ring = [(math.cos(2 * math.pi * k / n) * r, math.sin(2 * math.pi * k / n) * r) for k in range(n)]
    for k in range(n):
        (y0, z0), (y1, z1) = ring[k], ring[(k + 1) % n]
        tris.append(((-hx, y0, z0), (hx, y0, z0), (hx, y1, z1)))
        tris.append(((-hx, y0, z0), (hx, y1, z1), (-hx, y1, z1)))
        tris.append(((hx, 0, 0), (hx, y0, z0), (hx, y1, z1)))
        tris.append(((-hx, 0, 0), (-hx, y1, z1), (-hx, y0, z0)))
    return tris


def _ball_tris(r, n=10):
    tris = []
    for i in range(n):
        t0, t1 = math.pi * i / n, math.pi * (i + 1) / n
        for j in range(2 * n):
            p0, p1 = 2 * math.pi * j / (2 * n), 2 * math.pi * (j + 1) / (2 * n)
            def pt(t, p):
                return (r * math.sin(t) * math.cos(p), r * math.cos(t), r * math.sin(t) * math.sin(p))
            tris.append((pt(t0, p0), pt(t1, p0), pt(t1, p1)))
            tris.append((pt(t0, p0), pt(t1, p1), pt(t0, p1)))
    return tris


def part_tris(p):
    hx, hy, hz = (s / 2 for s in p["size"])
    if p["cls"] == "WedgePart":
        local = _wedge_tris(hx, hy, hz)
    elif p["shape"] == "Cylinder":
        local = _cyl_tris(hx, min(hy, hz))
    elif p["shape"] == "Ball":
        local = _ball_tris(min(hx, hy, hz))
    else:
        local = _box_tris(hx, hy, hz)
    r, u, b = p["cols"]
    px, py, pz = p["pos"]
    out = []
    for tri in local:
        out.append(tuple((px + r[0] * x + u[0] * y + b[0] * z, py + r[1] * x + u[1] * y + b[1] * z,
                          pz + r[2] * x + u[2] * y + b[2] * z) for x, y, z in tri))
    return out


# ------------------------------------------------------------------------------------------------ render

def render(gun, camera, size=(900, 520), fov=None, ortho_span=None, bg=(34, 37, 44), extra=None):
    """camera = (eye, target, up). Perspective with `fov` degrees, or orthographic spanning `ortho_span` mm."""
    import numpy as np
    W, H = size
    eye, target, up = (np.array(v, float) for v in camera)
    fwd = target - eye
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, up)
    right /= np.linalg.norm(right)
    upv = np.cross(right, fwd)
    img = np.zeros((H, W, 3), float)
    img[:] = np.array(bg, float) / 255
    zbuf = np.full((H, W), np.inf)
    light = np.array([0.35, 0.8, 0.45])
    light /= np.linalg.norm(light)
    parts = list(gun["parts"]) + list(extra or [])
    for p in parts:
        if p["trans"] >= 0.85 or any(x != x for x in p["pos"] + list(p["cols"][0]) + list(p["cols"][1])):
            continue
        col = np.array(p["color"], float)
        glow = p["mat"] == "Neon"
        glass = p["mat"] == "Glass" or p["trans"] >= 0.3
        for tri in part_tris(p):
            v = np.array(tri, float)
            n = np.cross(v[1] - v[0], v[2] - v[0])
            nl = np.linalg.norm(n)
            if nl < 1e-9:
                continue
            n /= nl
            rel = v - eye
            cx, cy, cz = rel @ right, rel @ upv, rel @ fwd
            if ortho_span:
                if (cz < 1).any():
                    continue
                s = W / ortho_span
                sx = W / 2 + cx * s
                sy = H / 2 - cy * s
            else:
                if (cz < 5).any():
                    continue
                f = (W / 2) / math.tan(math.radians(fov) / 2)
                sx = W / 2 + cx / cz * f
                sy = H / 2 - cy / cz * f
            x0, x1 = int(max(0, math.floor(sx.min()))), int(min(W - 1, math.ceil(sx.max())))
            y0, y1 = int(max(0, math.floor(sy.min()))), int(min(H - 1, math.ceil(sy.max())))
            if x0 > x1 or y0 > y1:
                continue
            xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
            d = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0])
            if abs(d) < 1e-12:
                continue
            w1 = ((xs - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (ys - sy[0])) / d
            w2 = ((sx[1] - sx[0]) * (ys - sy[0]) - (xs - sx[0]) * (sy[1] - sy[0])) / d
            w0 = 1 - w1 - w2
            mask = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
            if not mask.any():
                continue
            depth = w0 * cz[0] + w1 * cz[1] + w2 * cz[2]
            sub = zbuf[y0:y1 + 1, x0:x1 + 1]
            m = mask & (depth < sub)
            if not m.any():
                continue
            facing = n @ (-fwd) if ortho_span else n @ (-(v.mean(0) - eye) / np.linalg.norm(v.mean(0) - eye))
            nn = n if facing >= 0 else -n
            shade = 1.0 if glow else 0.32 + 0.68 * max(0.0, float(nn @ light)) + 0.12 * abs(float(nn @ upv))
            c = np.clip(col * min(shade, 1.15), 0, 1)
            region = img[y0:y1 + 1, x0:x1 + 1]
            if glass:
                region[m] = region[m] * 0.55 + c * 0.45
            else:
                region[m] = c
                sub[m] = depth[m]
    return (np.clip(img, 0, 1) * 255).astype("uint8")


def bounds(gun):
    xs, ys, zs = [], [], []
    for p in gun["parts"]:
        if p["trans"] >= 0.85 or any(x != x for x in p["pos"] + list(p["cols"][0]) + list(p["cols"][1])):
            continue
        for tri in part_tris(p):
            for x, y, z in tri:
                xs.append(x); ys.append(y); zs.append(z)
    return (min(xs), max(xs)), (min(ys), max(ys)), (min(zs), max(zs))


def views(gun):
    """name -> (camera, kwargs). mm, gun space (bore on Z, muzzle -Z, right +X)."""
    (x0, x1), (y0, y1), (z0, z1) = bounds(gun)
    cx, cy, cz = (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
    span = max(z1 - z0, (y1 - y0) * 1.9) * 1.12
    out = {
        "side": (((cx + 3000, cy, cz), (cx, cy, cz), (0, 1, 0)), {"ortho_span": span}),
        "left": (((cx - 3000, cy, cz), (cx, cy, cz), (0, 1, 0)), {"ortho_span": span}),
        "three": (((cx + span * 0.55, cy + span * 0.32, cz - span * 0.6), (cx, cy, cz), (0, 1, 0)), {"fov": 55}),
        "top": (((cx, cy + 3000, cz), (cx, cy, cz), (0, 0, -1)), {"ortho_span": span}),
    }
    sight = gun["attrs"].get("KP_Sight")
    if sight:
        relief = float(gun["attrs"].get("EyeRelief") or 0.6) / 0.0038
        sp = sight[:3]
        back = sight[3:6]
        eye = (sp[0] + back[0] * relief, sp[1] + back[1] * relief, sp[2] + back[2] * relief)
        tgt = (sp[0] - back[0] * 1000, sp[1] - back[1] * 1000, sp[2] - back[2] * 1000)
        out["ads"] = ((eye, tgt, (0, 1, 0)), {"fov": 50})
    grip = gun["attrs"].get("KP_GripHand")
    if grip:
        # The viewmodel's hip pose (Viewmodel HOLD by class): gun = camera * CF(hip) * Angles(pitch, yaw, 0) *
        # CF(-grip), so in gun space the camera sits at grip + R^-1 * (-hip) and turns by R^-1.
        cls = {"pistol": "handgun", "revolver": "handgun", "lmg": "heavy", "minigun": "heavy"}.get(gun["style"], "rifle")
        if gun["style"] == "launcher" and gun["attrs"].get("Action") == "rocket":
            cls = "shoulder"
        hold = {"handgun": ((0.46, -0.66, -1.55), -4, 2), "rifle": ((0.5, -0.74, -0.98), -3, 1),
                "heavy": ((0.46, -0.86, -0.92), -4, 2), "shoulder": ((0.52, -0.58, -0.42), -2, 0)}[cls]
        (hx, hy, hz), yaw, pitch = hold
        behind = ((sight[2] if sight else grip[2]) - grip[2]) * 0.0038
        hz = min(hz, -0.6 - behind)
        hip = [v / 0.0038 for v in (hx, hy, hz)]
        cy_, sy_ = math.cos(math.radians(-yaw)), math.sin(math.radians(-yaw))
        cp_, sp_ = math.cos(math.radians(-pitch)), math.sin(math.radians(-pitch))

        def rinv(v):  # Ry(-yaw) * Rx(-pitch) * v
            x, y, z = v
            y, z = y * cp_ - z * sp_, y * sp_ + z * cp_
            return (x * cy_ + z * sy_, y, -x * sy_ + z * cy_)
        off = rinv((-hip[0], -hip[1], -hip[2]))
        eye = (grip[0] + off[0], grip[1] + off[1], grip[2] + off[2])
        fwd, up = rinv((0, 0, -1)), rinv((0, 1, 0))
        out["hip"] = ((eye, (eye[0] + fwd[0] * 1000, eye[1] + fwd[1] * 1000, eye[2] + fwd[2] * 1000), up), {"fov": 45})
    return out


def contact_sheet(gun, shots, path):
    """The four views that matter on one page: side, three-quarter, sight picture, hip."""
    from PIL import Image, ImageDraw
    w, h = 900, 520
    sheet = Image.new("RGB", (w * 2, h * 2 + 30), (18, 18, 22))
    for index, name in enumerate(("side", "three", "ads", "hip")):
        if name in shots:
            sheet.paste(Image.fromarray(shots[name]).resize((w, h)), ((index % 2) * w, 30 + (index // 2) * h))
    ImageDraw.Draw(sheet).text((10, 8), f"{gun['id']}  {gun['name']}  ({gun['rarity']} {gun['style']}, "
                               f"Action {gun['attrs'].get('Action')}, Flair {gun['attrs'].get('Flair')})", fill=(255, 230, 90))
    sheet.save(path)


def save_png(arr, path):
    from PIL import Image
    Image.fromarray(arr).save(path)


# ------------------------------------------------------------------------------------------------ sight line

SIGHT_OK = re.compile(r"(Sight|Scope|Lens|Reticle|Dot|Holo|Window|Glass|Aperture|Ring|Post|Notch|Bead|Hood|Tritium|Optic|Objective|Ocular|AimPoint|Turret|Eyepiece)", re.I)


def seg_hits(p, a, b):
    """Length of segment a->b (mm) inside part p's volume (boxes, cylinders along X, balls; wedges as boxes)."""
    r, u, bb = p["cols"]
    def loc(q):
        d = (q[0] - p["pos"][0], q[1] - p["pos"][1], q[2] - p["pos"][2])
        return (d[0] * r[0] + d[1] * r[1] + d[2] * r[2], d[0] * u[0] + d[1] * u[1] + d[2] * u[2],
                d[0] * bb[0] + d[1] * bb[1] + d[2] * bb[2])
    la, lb = loc(a), loc(b)
    hx, hy, hz = (s / 2 for s in p["size"])
    d = [lb[i] - la[i] for i in range(3)]
    L = math.dist(a, b)
    t0, t1 = 0.0, 1.0

    def slab(o, dd, h):
        nonlocal t0, t1
        if abs(dd) < 1e-12:
            return -h <= o <= h
        ta, tb = (-h - o) / dd, (h - o) / dd
        if ta > tb:
            ta, tb = tb, ta
        t0, t1 = max(t0, ta), min(t1, tb)
        return t0 <= t1

    def quad(oy, oz, dy, dz, rr):
        nonlocal t0, t1
        A = dy * dy + dz * dz
        B = 2 * (oy * dy + oz * dz)
        C = oy * oy + oz * oz - rr * rr
        if A < 1e-12:
            return C <= 0
        disc = B * B - 4 * A * C
        if disc < 0:
            return False
        sq = math.sqrt(disc)
        t0, t1 = max(t0, (-B - sq) / (2 * A)), min(t1, (-B + sq) / (2 * A))
        return t0 <= t1

    if p["shape"] == "Ball" and p["cls"] != "WedgePart":
        rr = min(hx, hy, hz)
        A = sum(x * x for x in d)
        B = 2 * sum(la[i] * d[i] for i in range(3))
        C = sum(x * x for x in la) - rr * rr
        disc = B * B - 4 * A * C
        if disc < 0:
            return 0.0
        sq = math.sqrt(disc)
        t0, t1 = max(t0, (-B - sq) / (2 * A)), min(t1, (-B + sq) / (2 * A))
        ok = t0 <= t1
    elif p["shape"] == "Cylinder" and p["cls"] != "WedgePart":
        ok = slab(la[0], d[0], hx) and quad(la[1], la[2], d[1], d[2], min(hy, hz))
    else:
        ok = slab(la[0], d[0], hx) and slab(la[1], d[1], hy) and slab(la[2], d[2], hz)
    return max(0.0, t1 - t0) * L if ok else 0.0


def sight_findings(gun):
    attrs = gun["attrs"]
    sight = attrs.get("KP_Sight")
    if not sight:
        return None, 0
    back = sight[3:6]
    relief = float(attrs.get("EyeRelief") or 0.6) / 0.0038
    eye = tuple(sight[i] + back[i] * relief for i in range(3))
    far = tuple(sight[i] - back[i] * 2000 for i in range(3))
    scoped = attrs.get("Optic") in ("scope", "lpvo", "long") or any(p["name"] == "Scope" for p in gun["parts"])
    found, examined = [], 0
    for p in gun["parts"]:
        if p["trans"] >= 0.3 or p["mat"] == "Glass" or any(x != x for x in p["pos"] + list(p["cols"][0]) + list(p["cols"][1])):
            continue
        # Quick reject: distance from part centre to the line vs its half diagonal.
        c = p["pos"]
        d = [far[i] - eye[i] for i in range(3)]
        L = math.sqrt(sum(x * x for x in d))
        un = [x / L for x in d]
        w = [c[i] - eye[i] for i in range(3)]
        t = max(0, min(L, sum(w[i] * un[i] for i in range(3))))
        closest = [eye[i] + un[i] * t for i in range(3)]
        if math.dist(closest, c) > math.sqrt(sum((s / 2) ** 2 for s in p["size"])) + 1:
            continue
        examined += 1
        if SIGHT_OK.search(p["name"]) or (scoped and p["name"].startswith("Scope")):
            continue
        # A post or bead the eye lines up is ON the line by design only at its tip; anything the line crosses
        # for more than 2 mm is in the way.
        inside = seg_hits(p, eye, far)
        if inside > 2:
            found.append((p["name"], round(inside, 1)))
    return found, examined


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, repo = argv[1], argv[2]
    if cmd == "dump":
        lab = Lab(repo)
        g = lab.gun(argv[3])
        print(f"{g['id']} {g['name']} {g['rarity']} style={g['style']} parts={len(g['parts'])}")
        for k in sorted(g["attrs"]):
            v = g["attrs"][k]
            if isinstance(v, list):
                print(f"  {k}: pos=({v[0]:.1f},{v[1]:.1f},{v[2]:.1f}) back=({v[3]:.2f},{v[4]:.2f},{v[5]:.2f}) up=({v[6]:.2f},{v[7]:.2f},{v[8]:.2f})")
            else:
                print(f"  {k}: {v}")
        for p in g["parts"]:
            s, q = p["size"], p["pos"]
            print(f"  {p['name']:<22} {p['cls'][:5]:<5} {p['shape'][:4]:<4} size=({s[0]:.1f},{s[1]:.1f},{s[2]:.1f}) at=({q[0]:.1f},{q[1]:.1f},{q[2]:.1f}) {p['mat']} {p['anim']}")
        return 0
    if cmd == "render":
        out = Path(argv[3])
        out.mkdir(parents=True, exist_ok=True)
        lab = Lab(repo)
        ids = argv[4:] or lab.ids()
        for gid in ids:
            g = lab.gun(gid)
            shots = {}
            for name, (cam, kw) in views(g).items():
                shots[name] = render(g, cam, **kw)
                save_png(shots[name], out / f"{gid}_{name}.png")
            contact_sheet(g, shots, out / f"{gid}_sheet.png")
            print(f"rendered {gid}")
        return 0
    if cmd == "sight":
        lab = Lab(repo)
        ids = argv[3:] or lab.ids()
        bad, examined_total = 0, 0
        for gid in ids:
            g = lab.gun(gid)
            found, examined = sight_findings(g)
            examined_total += examined
            if found:
                bad += 1
                print(f"FLAG {gid}: {found}")
        # Planted fault: a slab across the line of the first gun.
        g = lab.gun(ids[0])
        s = g["attrs"]["KP_Sight"]
        g["parts"].append({"name": "PlantedSlab", "cls": "Part", "shape": "Block", "size": [40, 40, 4],
                           "pos": [s[0] - s[3] * 60, s[1] - s[4] * 60, s[2] - s[5] * 60],
                           "cols": ((1, 0, 0), (0, 1, 0), (0, 0, 1)), "color": [1, 0, 0], "mat": "Metal", "trans": 0, "anim": ""})
        planted = sight_findings(g)[0]
        caught = any(n == "PlantedSlab" for n, _ in planted)
        print(f"sight line: {len(ids)} guns, {examined_total} parts near a line examined, {bad} guns flagged; planted slab {'caught' if caught else 'MISSED'}")
        return 0 if bad == 0 and caught else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
