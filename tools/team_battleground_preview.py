"""An offline preview of the central battleground (TeamBattleground.lua): the real Layout, run under the
lupa mock of tools/team_battleground_check.py, drawn by a small raycaster (boxes, wedges by their slope,
cylinders and balls by their boxes; the part's own colour, lit by one sun; no textures, no lights, no
terrain but a flat ground). It is NOT a render of the game -- tools/team_battleground_gallery.lua is,
on Oliver's machine -- but it shows the layout, the heights and anything badly out of place.

    python3 tools/team_battleground_preview.py [repo] OUTDIR
"""

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_battleground_check as C  # noqa: E402

SUN = np.array([0.45, 0.8, 0.35])
SUN = SUN / np.linalg.norm(SUN)
GROUND = np.array([0.42, 0.36, 0.27])
SKY = np.array([0.66, 0.78, 0.9])


def render(parts, eye, target, width, height, fov=60.0):
    eye = np.array(eye, float)
    fwd = np.array(target, float) - eye
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0, 1, 0])
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    tan = math.tan(math.radians(fov) / 2)
    aspect = width / height
    xs = (np.arange(width) + 0.5) / width * 2 - 1
    ys = 1 - (np.arange(height) + 0.5) / height * 2
    gx, gy = np.meshgrid(xs * tan * aspect, ys * tan)
    dirs = fwd[None, None, :] + gx[..., None] * right + gy[..., None] * up
    dirs = dirs / np.linalg.norm(dirs, axis=-1, keepdims=True)
    # the ground
    dy = dirs[..., 1]
    down = dy < -1e-6
    best = np.where(down, -eye[1] / np.where(down, dy, -1), np.inf)
    normal = np.zeros((height, width, 3))
    normal[:] = [0, 1, 0]
    colour = np.zeros((height, width, 3))
    colour[:] = GROUND

    def span(lo, hi, size):
        return max(0, int(math.floor(lo)) - 1), min(size, int(math.ceil(hi)) + 1)

    for p in parts:
        if p["transparency"] >= 0.9:
            continue
        c = np.array(p["pos"])
        ax = np.array(p["axes"])
        h = np.array(p["size"]) / 2
        # Only the pixels the part's bounding sphere can cover: a 1390-part frame is otherwise
        # 1390 passes over every ray.
        rad = float(np.linalg.norm(h))
        rel_c = c - eye
        zc, xc, yc = rel_c @ fwd, rel_c @ right, rel_c @ up
        if zc + rad < 0.05:
            continue
        if zc - rad > 0.05:
            us = [(xc - rad) / (zc - rad), (xc - rad) / (zc + rad), (xc + rad) / (zc - rad), (xc + rad) / (zc + rad)]
            vs = [(yc - rad) / (zc - rad), (yc - rad) / (zc + rad), (yc + rad) / (zc - rad), (yc + rad) / (zc + rad)]
            c0, c1 = span((min(us) / (tan * aspect) + 1) / 2 * width, (max(us) / (tan * aspect) + 1) / 2 * width, width)
            r0, r1 = span((1 - max(vs) / tan) / 2 * height, (1 - min(vs) / tan) / 2 * height, height)
            if c0 >= c1 or r0 >= r1:
                continue
        else:
            r0, r1, c0, c1 = 0, height, 0, width
        d = dirs[r0:r1, c0:c1].reshape(-1, 3)
        b = best[r0:r1, c0:c1].reshape(-1)
        lo = ax @ (eye - c)
        ld = d @ ax.T
        with np.errstate(divide="ignore", invalid="ignore"):
            t1 = (-h - lo) / ld
            t2 = (h - lo) / ld
        par = np.abs(ld) < 1e-12
        inside = np.abs(lo) <= h
        tmin = np.where(par, np.where(inside, -np.inf, np.inf), np.minimum(t1, t2))
        tmax = np.where(par, np.where(inside, np.inf, -np.inf), np.maximum(t1, t2))
        enter = tmin.max(axis=1)
        leave = tmax.min(axis=1)
        face = tmin.argmax(axis=1)
        hit = (enter <= leave) & (leave > 0) & (enter < b)
        nrm = None
        if p["kind"] == "wedge" and hit.any():
            k = h[1] / h[2]
            f0 = lo[1] - k * lo[2]
            fd = ld[:, 1] - k * ld[:, 2]
            with np.errstate(divide="ignore", invalid="ignore"):
                tp = -f0 / fd
            enter2 = np.where((fd < 0) & (tp > enter), tp, enter)
            leave2 = np.where((fd > 0) & (tp < leave), tp, leave)
            ok = np.where(np.abs(fd) < 1e-12, f0 <= 0, enter2 <= leave2)
            slope = (fd < 0) & (tp > enter)
            enter = enter2
            hit = hit & ok & (enter < b) & (leave2 > 0)
            wn = ax.T @ (np.array([0, 1, -k]) / math.sqrt(1 + k * k))
            nrm = np.where(slope[:, None], wn[None, :], 0)
        if not hit.any():
            continue
        idx = np.nonzero(hit)[0]
        b[idx] = np.maximum(enter[idx], 0)
        f = face[idx]
        sign = -np.sign(ld[idx, f])
        base = ax[f] * sign[:, None]
        if nrm is not None:
            use = np.abs(nrm[idx]).sum(axis=1) > 0
            base = np.where(use[:, None], nrm[idx], base)
        rows, cols = np.divmod(idx, c1 - c0)
        best[r0 + rows, c0 + cols] = b[idx]
        normal[r0 + rows, c0 + cols] = base
        colour[r0 + rows, c0 + cols] = np.array(p["color"])
    lit = np.clip(normal @ SUN, 0, 1) * 0.65 + 0.35
    img = colour * lit[..., None]
    far = ~np.isfinite(best)
    img[far] = SKY
    fog = np.clip((np.where(far, 0, best) - 120) / 400, 0, 0.5)[..., None]
    img = img * (1 - fog) + SKY * fog
    return np.clip(img, 0, 1)


def top_down(parts, size=900, extent=132.0):
    """Straight down from above: each pixel the top part's colour, shaded by height."""
    cols = C.Columns(parts, extent=extent, grid=2 * extent / (size - 1), want=lambda p: p["transparency"] < 0.9)
    top = np.full((cols.n, cols.n), -1, np.int64)
    height = np.zeros((cols.n, cols.n))
    for k in range(cols.K):
        hi = cols.HI[k]
        ok = np.isfinite(hi) & (hi > height - 1e9)
        better = ok & (hi >= height)
        height = np.where(better, hi, height)
        top = np.where(better, cols.OWNER[k], top)
    img = np.zeros((cols.n, cols.n, 3))
    img[:] = GROUND
    has = top >= 0
    palette = np.array([p["color"] for p in parts])
    img[has] = palette[top[has]]
    shade = 0.55 + 0.45 * np.clip(height / 20, 0, 1)
    img = img * shade[..., None]
    # x across, z down the page with team 1 (-Z) at the bottom
    return np.flipud(np.transpose(img, (1, 0, 2)))


def main(argv):
    from PIL import Image

    def imsave(path, img):
        Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(path)
    repo = argv[1] if len(argv) > 2 else "."
    out = Path(argv[-1])
    out.mkdir(parents=True, exist_ok=True)
    rt = C.Runtime(C.sources(repo))
    model, _ = rt.layout(C.SEED)
    parts = rt.dump(model)
    if not (out / "00_plan.png").exists():
        imsave(out / "00_plan.png", top_down(parts))
    views = {
        "01_overview_from_team1": ((0, 150, -230), (0, 0, -10)),
        "02_overview_high_west": ((-230, 170, -60), (-10, 0, 0)),
        "03_centre_lane_eye": ((0, 5.2, -120), (0, 5, 0)),
        "04_left_lane_eye": ((-62, 5.2, -110), (-80, 4, 0)),
        "05_right_lane_eye": ((70, 5.2, -114), (84, 5, -20)),
        "06_keep_gallery": ((-15, 15.8, -16), (10, 9, 8)),
        "07_objective_B_pit": ((-60, 12, -24), (-86, 1, 2)),
        "08_objective_A_hall": ((14, 5.5, -14), (-4, 3, 4)),
        "09_market_eye": ((50, 5.2, -70), (48, 4, -10)),
        "10_bridge_to_gantry": ((32, 16, -1), (104, 11, 0)),
    }
    for name, (eye, target) in views.items():
        img = render(parts, eye, target, 640, 360)
        imsave(out / (name + ".png"), img)
        print("wrote", name, flush=True)


if __name__ == "__main__":
    main(sys.argv)
