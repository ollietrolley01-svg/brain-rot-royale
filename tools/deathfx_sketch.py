"""Offline sketches of the death effects (#24): every design at its three gallery moments, drawn from the
REAL parts the engine builds, as a contact sheet PNG. NOT a render: flat-shaded boxes, balls and discs in
their real positions, sizes, rotations, colours and transparencies, seen from where the shop's stage camera
looks. It is for catching gross mistakes without Studio (a bat landing beside the body, a crater in the
air, a disc stood on edge, the body not doing anything); how an effect FEELS is tools/deathfx_gallery.lua
on Oliver's machine.

    python3 tools/deathfx_sketch.py [out.png]      default: deathfx_sketch.png in the current directory

Runs DeathEffectFx and DeathEffectDesigns under lupa with tools/deathfx_mocks.lua, in preview mode (the
sparks stand in for particles), stepped straight to each moment (killanim_check proves that is the frame
the game shows). Needs lupa, numpy and matplotlib.
"""
import os
import sys

import numpy as np
from lupa import LuaRuntime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from killanim_check import luau_to_lua  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DUMP = r"""
local M, engineSrc, designsSrc, cosmeticSrc = ...
M.install()
local MODULES = {}
local function marker(name) return { Name = name, WaitForChild = function(_, c) return marker(c) end } end
require = function(m) return MODULES[m.Name] end
script = { Parent = marker("Shared") }
game = { GetService = function(_, n) return marker(n) end }
workspace = M.new("Workspace")
MODULES.DeathEffectFx = load(engineSrc, "=DeathEffectFx")()
MODULES.DeathEffectDesigns = load(designsSrc, "=DeathEffectDesigns")()
local CosmeticData = load(cosmeticSrc, "=CosmeticData")()
local Fx, Designs = MODULES.DeathEffectFx, MODULES.DeathEffectDesigns
local out = {}
local ids = CosmeticData.OfKind("KillAnimation")
table.insert(ids, "Default.Impact")
for _, id in ipairs(ids) do
	local design = id == "Default.Impact" and Designs.Default.Impact or Designs.Get(id)
	for index, moment in ipairs(design.moments) do
		local dummy = Fx.Dummy()
		dummy.Parent = workspace
		local fx = Fx.new({ parent = workspace, origin = Fx.DummyRoot, ground = M.vec(0, 0, 0), life = design.life,
			body = dummy, ownsBody = true, preview = true, seed = 7 })
		design.build(fx)
		fx:step(moment)
		local parts = {}
		local function add(model)
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") and part.Transparency < 0.98 then
					local c = part.CFrame
					table.insert(parts, { c.p.X, c.p.Y, c.p.Z, c.r[1], c.r[2], c.r[3], c.r[4], c.r[5], c.r[6], c.r[7], c.r[8], c.r[9],
						part.Size.X, part.Size.Y, part.Size.Z, part.Color.R, part.Color.G, part.Color.B, part.Transparency,
						part.Shape.Name })
				end
			end
		end
		add(dummy)
		add(fx.folder)
		table.insert(out, { id = id, index = index, moment = moment, parts = parts,
			focus = { design.view.focus.X, design.view.focus.Y, design.view.focus.Z }, radius = design.view.radius })
		fx:destroy()
		dummy:Destroy()
	end
end
return out
"""


def load_scenes():
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(open(os.path.join(ROOT, "tools/deathfx_mocks.lua"), encoding="utf-8").read())

    def src(path):
        return luau_to_lua(open(os.path.join(ROOT, path), encoding="utf-8").read())

    dump = lua.eval("function(s) return load(s, '=dump') end")(DUMP)
    out = dump(mocks, src("ReplicatedStorage/Shared/DeathEffectFx.lua"), src("ReplicatedStorage/Shared/DeathEffectDesigns.lua"),
               src("ReplicatedStorage/Shared/CosmeticData.lua"))
    scenes = []
    for scene in out.values():
        parts = [list(p.values()) for p in scene.parts.values()]
        scenes.append({"id": scene.id, "index": scene.index, "moment": scene.moment, "parts": parts,
                       "focus": np.array(list(scene.focus.values())), "radius": scene.radius})
    return scenes


CUBE = np.array([[x, y, z] for x in (-0.5, 0.5) for y in (-0.5, 0.5) for z in (-0.5, 0.5)])


def draw(ax, scene):
    from matplotlib.patches import Circle, Polygon
    focus, radius = scene["focus"], scene["radius"]
    # The stage camera's direction (CosmeticPreview.frameDeath): from +X, a little up, from -Z.
    back = np.array([0.45, 0.28, -0.85])
    back /= np.linalg.norm(back)
    right = np.cross(np.array([0, 1.0, 0]), back)
    right /= np.linalg.norm(right)
    up = np.cross(back, right)
    shapes = []
    for p in scene["parts"]:
        pos = np.array(p[0:3])
        rot = np.array(p[3:12]).reshape(3, 3)
        size = np.array(p[12:15])
        color = (p[15], p[16], p[17])
        alpha = max(0.08, 1 - p[18])
        shape = p[19]
        depth = np.dot(pos - focus, back)
        centre2 = np.array([np.dot(pos - focus, right), np.dot(pos - focus, up)])
        if shape == "Ball":
            shapes.append((depth, "ball", centre2, size.min() / 2, color, alpha))
        else:
            corners = (CUBE * size) @ rot.T + pos - focus
            pts = np.stack([corners @ right, corners @ up], axis=1)
            shapes.append((depth, "poly", pts, None, color, alpha))
    # Farthest first (smallest depth along the direction to the camera), so nearer shapes paint over.
    for depth, kind, geo, r, color, alpha in sorted(shapes, key=lambda s: s[0]):
        if kind == "ball":
            ax.add_patch(Circle(geo, r, facecolor=color, edgecolor="none", alpha=alpha))
        else:
            hull = convex_hull(geo)
            ax.add_patch(Polygon(hull, closed=True, facecolor=color, edgecolor=(0, 0, 0, 0.25 * alpha), linewidth=0.3, alpha=alpha))
    # The ground: a 16-stud square around the feet, drawn first-ish in faint green.
    ground = np.array([[x, 0, z] for x, z in ((-8, -8), (8, -8), (8, 8), (-8, 8))]) - focus
    ax.add_patch(Polygon(np.stack([ground @ right, ground @ up], axis=1), closed=True, facecolor=(0.3, 0.5, 0.3, 0.25),
                         edgecolor="none", zorder=0))
    ax.set_xlim(-radius, radius)
    ax.set_ylim(-radius * 0.75, radius * 0.75)
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    ax.set_facecolor((0.16, 0.18, 0.24))


def convex_hull(points):
    pts = sorted(map(tuple, points))
    if len(pts) <= 2:
        return np.array(pts)

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
    return np.array(lower[:-1] + upper[:-1])


def main():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    out = sys.argv[1] if len(sys.argv) > 1 else "deathfx_sketch.png"
    scenes = load_scenes()
    ids = []
    for scene in scenes:
        if scene["id"] not in ids:
            ids.append(scene["id"])
    fig, axes = plt.subplots(len(ids), 3, figsize=(9, 3 * len(ids)))
    beats = ["anticipation", "burst", "follow-through"]
    for scene in scenes:
        row = ids.index(scene["id"])
        ax = axes[row][scene["index"] - 1]
        draw(ax, scene)
        ax.set_title(f"{scene['id']}  {beats[scene['index'] - 1]} {scene['moment']:.2f}s  ({len(scene['parts'])} parts)", fontsize=7)
    fig.tight_layout()
    fig.savefig(out, dpi=90)
    print(f"deathfx sketch: {len(scenes)} stills of {len(ids)} effects -> {out}")


if __name__ == "__main__":
    main()
