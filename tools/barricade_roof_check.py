"""Can a player climb onto the legendary barricade's roof? (OLIVER_LIST #35), without Studio.

The Brainrot Fortress (ItemData: Legendary) has a second-floor deck with a hatch and a TrussPart up
through it. This runs the REAL buildFortress from ServerScriptService/Modules/DefenseService.lua (its
piece / decor helpers and colours sliced out of the module source) and the real ZFight pass the deploy
runs after it (DefenseService: ZFight.Fix({ model }, { all = true })), under the lupa mock from
tools/vehicle_models_axis_check.py, and measures the result against an R15 body.

The body is the collider a Humanoid climbs with: the torso column, 2 studs across, 1 deep, 5.2 tall
from the feet (R15 limbs do not collide; HumanoidRootPart and torso do). On a truss it stands about a
stud off the rungs (0.5 to 1.0 is swept). Crouching does not apply on a truss; its height (HipHeight
scaled by MovementConfig Crouch.HipScale) is printed for reference only.

Checks, on at least one face of the truss:
  1. CLIMB: the body, set off that face, sweeps from the pad up until its feet are level with the deck
     top without touching any collidable part but the truss. This is the hatch opening test: the old
     3.8 x 3.8 hatch with the truss in its middle stopped the body's back on the floor edge.
  2. TOP: the truss top is no more than MAX_STEP below the deck top (a Humanoid walks up that much),
     and not more than MAX_STEP above it.
  3. OFF: at the top, the body walks forward over the truss top and on until it stands wholly on the
     deck beyond, with its full 5.2 of headroom clear all the way.
Planted faults (source edits, rebuilt): the old hatch, a lid over the hatch, a short truss.
    python3 tools/barricade_roof_check.py [repo]        -> exit 0 when clean
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK, luau_to_lua  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

WIDTH, DEPTH, HEIGHT = 2.0, 1.0, 5.2
OFFSETS = (0.5, 0.75, 1.0)  # studs between the rungs and the body's front
MAX_STEP = 1.0
STEP = 0.05

DUMP = r"""
function dumpAll(model)
	local out = {}
	for _, p in ipairs(model:GetChildren()) do
		local c, s = p.CFrame, p.Size
		-- World extents of the (axis-aligned, maybe quarter-turned) box; a skewed one is refused.
		local e = {}
		for _, k in ipairs({ "X", "Y", "Z" }) do
			e[k] = math.abs(c.r[k]) * s.X + math.abs(c.u[k]) * s.Y + math.abs(c.b[k]) * s.Z
		end
		local skew = math.abs(c.r.X) + math.abs(c.u.X) + math.abs(c.b.X) > 1.01
		table.insert(out, { p.ClassName, e.X, e.Y, e.Z, c.p.X, c.p.Y, c.p.Z, skew and 1 or 0, p.CanCollide == false and 0 or 1 })
	end
	return out
end
"""


def fortress_source(repo):
    src = (Path(repo) / "ServerScriptService/Modules/DefenseService.lua").read_text()
    colours = "\n".join(re.findall(r"^local [A-Z]+ = Color3\.fromRGB\(.*\)$", src, re.M))
    start = src.index("local function piece(")
    end = src.index("\n-- Sizes live in DefensePlacement")
    return colours + "\n" + src[start:end] + "\nreturn buildFortress\n"


def build(repo, fortress_src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK + DUMP)
    zfight = lua.execute(luau_to_lua((Path(repo) / "ReplicatedStorage/Shared/ZFight.lua").read_text()))
    build_fortress = lua.execute(luau_to_lua(fortress_src))
    model = lua.eval('Instance.new("Model")')
    build_fortress(model, lua.eval("CFrame.identity"), lua.eval("Color3.fromRGB(255, 184, 48)"))
    zfight.Fix(lua.table_from([model]), lua.table_from({"all": True}))
    rows = lua.globals().dumpAll(model)
    parts = []
    for i in range(1, len(rows) + 1):
        v = [rows[i][j] for j in range(1, 10)]
        if v[7]:
            raise SystemExit("a fortress part is rotated off the axes; this check boxes axis-aligned parts only")
        size, pos = v[1:4], v[4:7]
        parts.append({"cls": v[0], "lo": [pos[k] - size[k] / 2 for k in range(3)],
                      "hi": [pos[k] + size[k] / 2 for k in range(3)], "collide": bool(v[8])})
    return parts


def overlaps(a_lo, a_hi, p):
    return all(a_lo[k] < p["hi"][k] - 1e-6 and a_hi[k] > p["lo"][k] + 1e-6 for k in range(3))


def body(cx, cz, feet, along_x):
    """The torso column: DEPTH along the climb direction, WIDTH across it."""
    hx, hz = (DEPTH / 2, WIDTH / 2) if along_x else (WIDTH / 2, DEPTH / 2)
    return [cx - hx, feet, cz - hz], [cx + hx, feet + HEIGHT, cz + hz]


def blocked(lo, hi, solids):
    return [p for p in solids if overlaps(lo, hi, p)]


def measure(parts):
    truss = next(p for p in parts if p["cls"] == "TrussPart")
    solids = [p for p in parts if p["collide"] and p is not truss]
    ground = min(p["lo"][1] for p in parts)
    pad = max(p["hi"][1] for p in solids if p["lo"][1] <= ground + 1e-6 and p["hi"][1] - p["lo"][1] <= 1)
    # The deck: flat collidable slabs whose tops are near the truss top.
    ttop = truss["hi"][1]
    deck = max(p["hi"][1] for p in solids if p["hi"][1] - p["lo"][1] <= 1 and abs(p["hi"][1] - ttop) <= 3)
    tc = [(truss["lo"][k] + truss["hi"][k]) / 2 for k in range(3)]
    results = []
    for axis, sign in ((0, -1), (0, 1), (2, -1), (2, 1)):
        face = truss["lo"][axis] if sign < 0 else truss["hi"][axis]
        along_x = axis == 0
        name = ("-" if sign < 0 else "+") + ("X" if along_x else "Z")
        for off in OFFSETS:
            centre = face + sign * (off + DEPTH / 2)
            cx, cz = (centre, tc[2]) if along_x else (tc[0], centre)
            why = None
            feet = pad
            while feet <= deck + 1e-6 and not why:
                hit = blocked(*body(cx, cz, feet, along_x), solids)
                if hit:
                    why = f"CLIMB blocked at feet {feet:.2f} by a part spanning {fmt(hit[0])}"
                feet += STEP
            if not why and not (-MAX_STEP <= ttop - deck <= MAX_STEP):
                why = f"TOP truss top {ttop:.2f} vs deck {deck:.2f}"
            if not why:
                # Walk forward over the truss and on until the body stands wholly on deck beyond it.
                stand = max(ttop, deck) + 0.01
                far = (truss["hi"][axis] if sign < 0 else truss["lo"][axis]) - sign * (DEPTH / 2 + 0.01)
                pos, landed = centre, False
                while (pos - far) * sign >= -1e-6 or not landed:
                    bx, bz = (pos, tc[2]) if along_x else (tc[0], pos)
                    lo, hi = body(bx, bz, stand, along_x)
                    hit = blocked(lo, hi, solids)
                    if hit:
                        why = f"OFF blocked walking off at {pos:.2f} by {fmt(hit[0])}"
                        break
                    past = (pos - far) * sign < -1e-6
                    if past:
                        # wholly supported: every corner over deck
                        corners = [(x, z) for x in (lo[0] + 0.01, hi[0] - 0.01) for z in (lo[2] + 0.01, hi[2] - 0.01)]
                        landed = all(any(p["lo"][0] <= x <= p["hi"][0] and p["lo"][2] <= z <= p["hi"][2]
                                         and abs(p["hi"][1] - deck) < 0.2 for p in solids) for x, z in corners)
                        if not landed and abs(pos - far) > 12:
                            why = "OFF no deck to stand on past the truss"
                            break
                    pos -= sign * STEP
            results.append((name, off, why))
    return {"pad": pad, "deck": deck, "truss_top": ttop, "results": results}


def fmt(p):
    return "x %.2f..%.2f y %.2f..%.2f z %.2f..%.2f" % (p["lo"][0], p["hi"][0], p["lo"][1], p["hi"][1], p["lo"][2], p["hi"][2])


def passes(m):
    ok_faces = {}
    for name, _, why in m["results"]:
        ok_faces.setdefault(name, True)
        ok_faces[name] &= why is None
    return [f for f, ok in ok_faces.items() if ok]


def hatch(parts, m):
    """The opening round the truss at deck level: how far the deck is from the truss on each side."""
    truss = next(p for p in parts if p["cls"] == "TrussPart")
    slabs = [p for p in parts if p["collide"] and p["cls"] != "TrussPart" and abs(p["hi"][1] - m["deck"]) < 0.2]
    tc = [(truss["lo"][k] + truss["hi"][k]) / 2 for k in range(3)]
    out = {}
    for axis in (0, 2):
        other = 2 - axis
        lo = max((p["hi"][axis] for p in slabs if p["hi"][axis] <= tc[axis] and p["lo"][other] <= tc[other] <= p["hi"][other]), default=None)
        hi = min((p["lo"][axis] for p in slabs if p["lo"][axis] >= tc[axis] and p["lo"][other] <= tc[other] <= p["hi"][other]), default=None)
        out["XZ"[axis // 2]] = (lo, hi)
    return out


def main(repo):
    src = fortress_source(repo)
    parts = build(repo, src)
    m = measure(parts)
    h = hatch(parts, m)
    mc = (Path(repo) / "ReplicatedStorage/Shared/MovementConfig.lua").read_text()
    hip = re.search(r"HipScale = ([\d.]+)", mc)
    print(f"pad top {m['pad']:.2f}, deck top {m['deck']:.2f}, truss top {m['truss_top']:.2f}; "
          f"hatch X {h['X'][0]:.2f}..{h['X'][1]:.2f}, Z {h['Z'][0]:.2f}..{h['Z'][1]:.2f}; "
          f"clear above the deck to the sky over the hatch")
    if hip:
        print(f"(crouch, for reference: HipHeight 2 x {hip.group(1)} lowers an R15 by {2 - 2 * float(hip.group(1)):.2f}; "
              "a Humanoid on a truss is standing)")
    for name, off, why in m["results"]:
        print(f"  face {name} body {off:.2f} off the rungs: {'ok' if why is None else why}")
    good = passes(m)
    print(f"climbable faces: {', '.join(good) or 'NONE'}")

    # Planted faults: each must leave no face passable.
    plants = {
        # The pre-09-18 hatch: 3.8 x 3.8 with the truss in its middle.
        "old hatch": [("piece(model, Vector3.new(6, 0.6, 17.8), origin * CFrame.new(x, 8.3, 0)",
                       "piece(model, Vector3.new(7, 0.6, 17.8), origin * CFrame.new(x * 5.4 / 5.9, 8.3, 0)"),
                      ("piece(model, Vector3.new(5.8, 0.6, 7), origin * CFrame.new(0, 8.3, z)",
                       "piece(model, Vector3.new(3.8, 0.6, 7), origin * CFrame.new(0, 8.3, z)"),
                      ("truss.CFrame = origin * CFrame.new(1.9, 4.5, 0)", "truss.CFrame = origin * CFrame.new(0, 4.5, 0)")],
        "lid over the hatch": [("\tlocal truss = Instance.new(\"TrussPart\")",
                                "\tpiece(model, Vector3.new(6, 0.4, 4), origin * CFrame.new(0, 12, 0), IRON)\n\tlocal truss = Instance.new(\"TrussPart\")")],
        "short truss": [("truss.Size = Vector3.new(2, 8, 2)\n\ttruss.CFrame = origin * CFrame.new(1.9, 4.5, 0)",
                         "truss.Size = Vector3.new(2, 6, 2)\n\ttruss.CFrame = origin * CFrame.new(1.9, 3.5, 0)")],
    }
    selftest = True
    for label, edits in plants.items():
        planted = src
        for old, new in edits:
            if old not in planted:
                print(f"self-test {label}: anchor moved, update the plant ({old[:40]}...)")
                selftest = False
                break
            planted = planted.replace(old, new, 1)
        else:
            caught = not passes(measure(build(repo, planted)))
            selftest &= caught
            print(f"self-test planted {label}: {'caught' if caught else 'MISSED'}")
    return 0 if good and selftest else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
