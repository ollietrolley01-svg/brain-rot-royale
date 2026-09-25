"""House interior furnishing audit, without Studio.

Runs the REAL interior code sliced out of ServerScriptService/Modules/MapBuildings.lua (windowOffsets,
claimOpenings, partitionZ, freeSpot, interiorStyle, buildInterior and the furniture it builds) under
the CFrame/Vector3/Instance mock from tools/vehicle_models_axis_check.py, with the REAL MapSpace.lua
as the room grid and a seeded Random stand-in. Each floor is set up the way buildBuilding sets one
up, in its order: the window and door lanes (claimOpenings, from buildWall's own window list), the
stair strip, the doorway circle, the partition (partitionZ), the loot, then buildInterior. A textual
guard fails the run if buildBuilding stops making those calls, so this mirror cannot drift silently.

Checks, on the parts actually built (world boxes, not claim circles), over seeds x sizes x floors x
town palettes:
  BUDGET          instances one floor's interior adds <= INTERIOR_PART_BUDGET, PointLights <= 1.
  NO_CLIP         no part of one piece intersects a solid part of another piece, the skirting or the
                  door frames (a table top resting on its own legs is one piece and is fine).
  IN_BOUNDS       every part inside the walls' inner faces, on the floor and under the ceiling.
  CLEAR_ZONES     no solid part in the door lane, the stair strip, or a window's vault lane.
  WINDOW_BLOCK    nothing taller than the sill (less a margin) stands in front of any window, solid
                  or trim; nothing but the rug in the door opening.
  PARTITION       a partition never meets a side wall across one of its windows.
  SOLID           every furniture piece has collidable parts, anchored, each tagged
                  Destructible = "Furniture:<id>" (one DestructibleService pool per piece), and that
                  pool resolves in DestructibleService's KINDS table.
  DETERMINISTIC   the same seed twice builds byte-identical floors.
  COVERAGE        over the seeds, all four purposes and every furniture piece get built, and the
                  town palettes give more than one interior style.

Planted faults (source edits, rebuilt; each must be caught by its own finding, else FAIL):
  P1 a collidable sofa dropped in the doorway          -> CLEAR_ZONES door
  P2 a wardrobe stood in front of a back-wall window   -> WINDOW_BLOCK
  P3 a solid piece left unregistered (no Destructible) -> SOLID unregistered
  P4 every furniture part non-collide (the old bug)    -> SOLID not collidable
  P5 pieces pushed back into the wall                  -> IN_BOUNDS
  P6 partitionZ ignoring the side windows              -> PARTITION

    python tools/interior_check.py [repo]        -> exit 0 when clean
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK  # noqa: E402
from car_placement_luau import luau_to_lua  # noqa: E402 (handles `continue` and compound assignment)

from lupa import LuaRuntime  # noqa: E402

INTERIOR_PART_BUDGET = 40
SEEDS = range(1, 61)
# width, depth, floors, this floor. Sizes span DEFAULT_SIZES' house range and the Cities profiles.
HOUSE_FLOORS = [(32, 30, 2, 0), (32, 30, 2, 1), (40, 34, 3, 2), (26, 26, 1, 0), (36, 32, 2, 0)]
OTHER_ARCHETYPE_FLOORS = [("tower", 30, 30, 4, 0), ("tower", 30, 30, 4, 2), ("warehouse", 34, 28, 1, 0)]
PALETTES = [None, "farm", "upscale", "pastel", "ruin", "harbour"]
FLOOR_HEIGHT = 15
ORIGIN = (37.0, 0.0, -21.0)   # off-centre on purpose: a formula that forgets origin shows up
SILL_MARGIN = 0.3             # a piece may stand under a window only if its top clears the sill by this
WINDOW_SIDE_MARGIN = 0.5      # a window's zone runs this far past each jamb
WINDOW_ZONE_DEPTH = 4.0       # ... and this far into the room
DOOR_LANE_DEPTH = 6.0
EPS = 0.02

FURNITURE_TRIM = {"Rug", "Skirting", "DoorFrame", "WallArt"}
STOCKROOM = {"Crate", "Barrel", "Table", "Shelf", "Part"}

PRELUDE = r"""
local function makeRandom(seed)
	seed = seed or 1
	local state = (seed * 2654435761) % 2147483647
	if state == 0 then state = 1 end
	local function nextFloat()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	for _ = 1, 6 do nextFloat() end
	local obj = {}
	function obj:NextNumber() return nextFloat() end
	function obj:NextInteger(m, n) return m + math.floor(nextFloat() * (n - m + 1)) end
	return obj
end
Random = { new = makeRandom }

-- Color3 with Lerp (the shared mock's is a bare table).
local C3 = {}
C3.__index = C3
local function color(r, g, b) return setmetatable({ R = r, G = g, B = b }, C3) end
function C3.Lerp(a, b, t) return color(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
Color3 = { fromRGB = function(r, g, b) return color(r / 255, g / 255, b / 255) end, new = color }

table.clone = table.clone or function(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end

HazardService = { Barrel = function(parent, cframe)
	local part = Instance.new("Part")
	part.Name = "Barrel"
	part.Size = Vector3.new(4, 4, 4)
	part.CFrame = cframe * CFrame.new(0, 2, 0)
	part.Parent = parent
end }
"""

HARNESS = r"""
local function dumpFloor(model, origin)
	local parts, lights = {}, 0
	for _, p in ipairs(model:GetDescendants()) do
		if p.ClassName == "PointLight" then
			lights = lights + 1
		elseif p.ClassName == "Part" then
			local c, s = p.CFrame, p.Size
			local ex = math.abs(c.r.X) * s.X / 2 + math.abs(c.u.X) * s.Y / 2 + math.abs(c.b.X) * s.Z / 2
			local ey = math.abs(c.r.Y) * s.X / 2 + math.abs(c.u.Y) * s.Y / 2 + math.abs(c.b.Y) * s.Z / 2
			local ez = math.abs(c.r.Z) * s.X / 2 + math.abs(c.u.Z) * s.Y / 2 + math.abs(c.b.Z) * s.Z / 2
			table.insert(parts, {
				p.Name, c.p.X - origin.X, c.p.Y - origin.Y, c.p.Z - origin.Z, ex, ey, ez,
				p.CanCollide ~= false, p.Anchored == true, p:GetAttribute("Destructible") or "",
			})
		end
	end
	return parts, lights
end

-- How many distinct interior styles four town palettes give over 40 houses.
function styleSpread()
	local seen, n = {}, 0
	for seed = 1, 40 do
		rng = Random.new(seed)
		for _, name in ipairs({ "farm", "upscale", "pastel", "ruin" }) do
			local s = interiorStyle({ name = name })
			if not seen[s] then seen[s] = true; n = n + 1 end
		end
	end
	return n
end

-- One floor, set up the way buildBuilding sets one up (see the module docstring).
function runFloor(archetype, width, depth, floors, floor, seed, paletteName)
	rng = Random.new(seed)
	local MapSpace = (assert(load(MAPSPACE_SRC)))()
	local room = MapSpace.new()
	local origin = Vector3.new(ORIGIN_X, 0, ORIGIN_Z)
	local halfW, halfD = width / 2, depth / 2
	local isGround = floor == 0
	local style = archetype == "house" and interiorStyle(paletteName and { name = paletteName } or nil) or nil
	local wallWindows = {
		isGround and {} or windowOffsets(width, FLOOR_HEIGHT),
		windowOffsets(width, FLOOR_HEIGHT),
		windowOffsets(depth - WALL_THICKNESS, FLOOR_HEIGHT),
		windowOffsets(depth - WALL_THICKNESS, FLOOR_HEIGHT),
	}
	claimOpenings(room, origin, halfW, halfD, wallWindows, isGround)
	local stairSide = 1 + STAIR_WIDTH + STAIR_EXIT
	local stairClear = 1 + STAIR_LANDING + STAIR_RUN + STAIR_EXIT
	local canClimb = floors > 1 and width >= 26 and depth >= stairClear + WALL_THICKNESS
	if canClimb then
		room:AddRect(origin.X - halfW + stairSide / 2, origin.Z - halfD + stairClear / 2, stairSide / 2, stairClear / 2)
	end
	if isGround then
		room:AddCircle(origin.X, origin.Z - halfD + 3, 6)
	end
	local sideWindows = table.clone(wallWindows[3])
	for _, offset in ipairs(wallWindows[4]) do table.insert(sideWindows, offset) end
	local partitionLimit = math.max(3, math.floor(halfD - 4))
	local partitionAt = width > 30 and random() < 0.6 and partitionZ(random(2, partitionLimit), partitionLimit, sideWindows) or nil
	if partitionAt then
		local wallZ = origin.Z + partitionAt
		local besideStairs = canClimb and wallZ - WALL_THICKNESS / 2 < origin.Z - halfD + stairClear
		room:AddStrip(Vector3.new(origin.X - halfW, 0, wallZ), Vector3.new(origin.X + halfW, 0, wallZ), 2.2)
		if not besideStairs then room:AddCircle(origin.X, wallZ, 5) end
	end
	local reachX, reachZ = math.max(1, halfW - 3.5), math.max(1, halfD - 3.5)
	if isGround or canClimb then
		freeSpot(room, origin, reachX, reachZ, 2.6)
		freeSpot(room, origin, reachX, reachZ, 1.8, origin.Z + halfD - 3)
	end
	if isGround then freeSpot(room, origin, reachX, reachZ, 1.8) end

	local model = Instance.new("Model")
	buildInterior(model, origin, width, depth, 0, FLOOR_HEIGHT, room, archetype, floor, style, canClimb and stairClear or nil, wallWindows)
	local parts, lights = dumpFloor(model, origin)
	return parts, lights, wallWindows, partitionAt or false, canClimb, stairSide, stairClear
end
"""

GUARDS = [  # buildBuilding must still set a floor up the way the harness mirrors it
    r"claimOpenings\(room, origin, halfW, halfD, wallWindows, isGround\)",
    r"partitionZ\(random\(2, partitionLimit\), partitionLimit, sideWindows\)",
    r"buildInterior\(model, origin, width, depth, baseY, floorHeight, room, archetype, floor, style,",
    r"interiorStyle\(palette\)",
    r"windows = windowOffsets\(length, height\)",
]


def slice_source(text, start_pat, end_pat):
    start = re.search(start_pat, text, re.M)
    end = re.search(end_pat, text, re.M)
    if not start or not end:
        raise SystemExit(f"could not find slice bounds {start_pat!r} .. {end_pat!r}")
    return text[start.start():end.start()]


def repr_lua_string(s):
    level = 0
    while ("]" + "=" * level + "]") in s:
        level += 1
    eq = "=" * level
    return f"[{eq}[\n{s}\n]{eq}]"


def build_runtime(repo, patch=None):
    src = (Path(repo) / "ServerScriptService/Modules/MapBuildings.lua").read_text(encoding="utf-8")
    if patch:
        src = patch(src)
    consts = "\n".join(m.group(0) for m in re.finditer(
        r"^local (?:WALL_THICKNESS|SILL_HEIGHT|WINDOW_TOP|WINDOW_WIDTH|DOOR_WIDTH|STAIR_WIDTH|STAIR_LANDING"
        r"|STAIR_RUN|STAIR_EXIT) = .+$", src, re.M))
    helpers = slice_source(src, r"^local currentName = ", r"^local AWNING_COLORS")
    interior = slice_source(src, r"^local FURNITURE_RADIUS = \{", r"^-- Buildings\n")
    mapspace = (Path(repo) / "ServerScriptService/Modules/MapSpace.lua").read_text(encoding="utf-8")
    lua_src = "\n".join([
        MOCK, "MAPSPACE_SRC = " + repr_lua_string(mapspace), PRELUDE, consts,
        f"FLOOR_HEIGHT = {FLOOR_HEIGHT}\nORIGIN_X, ORIGIN_Z = {ORIGIN[0]}, {ORIGIN[2]}",
        luau_to_lua(helpers), luau_to_lua(interior), HARNESS,
    ])
    rt = LuaRuntime(unpack_returned_tuples=True)
    rt.execute(lua_src)
    return rt


def const(src, name):
    m = re.search(rf"^local {name} = ([\d.]+)", src, re.M)
    return float(m.group(1))


def boxes_intersect(a, b, eps=EPS):
    return all(abs(a[i] - b[i]) < a[i + 3] + b[i + 3] - eps for i in (0, 1, 2))


class Floor:
    def __init__(self, rt, archetype, width, depth, floors, floor, seed, palette):
        parts, lights, windows, partition, can_climb, stair_side, stair_clear = rt.globals().runFloor(
            archetype, width, depth, floors, floor, seed, palette)
        self.parts = [tuple(parts[i + 1][j + 1] for j in range(10)) for i in range(len(parts))]
        self.lights = lights
        self.windows = [[windows[w + 1][k + 1] for k in range(len(windows[w + 1]))] for w in range(4)]
        self.partition = partition if partition is not False else None
        self.can_climb, self.stair_side, self.stair_clear = can_climb, stair_side, stair_clear
        self.archetype, self.width, self.depth, self.floor = archetype, width, depth, floor


def window_zones(fl, wt, window_width):
    """Each window's zone inside the room, as an (x, z, hx, hz) box relative to the origin."""
    half_w, half_d, face = fl.width / 2, fl.depth / 2, wt / 2
    ha = window_width / 2 + WINDOW_SIDE_MARGIN
    hd = WINDOW_ZONE_DEPTH / 2
    zones = []
    for index, offsets in enumerate(fl.windows):
        for off in offsets:
            if index == 0:
                zones.append((off, -half_d + face + hd, ha, hd))
            elif index == 1:
                zones.append((off, half_d - face - hd, ha, hd))
            elif index == 2:
                zones.append((-half_w + face + hd, off, hd, ha))
            else:
                zones.append((half_w - face - hd, off, hd, ha))
    return zones


def overlaps_xz(part, zone):
    _, x, _, z, ex, _, ez = part[:7]
    zx, zz, zhx, zhz = zone
    return abs(x - zx) < ex + zhx - EPS and abs(z - zz) < ez + zhz - EPS


def check_floor(fl, label, findings, c, kinds):
    wt, sill, win_w, door_w = c["WALL_THICKNESS"], c["SILL_HEIGHT"], c["WINDOW_WIDTH"], c["DOOR_WIDTH"]
    floor_top = 0.5
    parts = fl.parts
    house = fl.archetype == "house"
    if len(parts) > INTERIOR_PART_BUDGET:
        findings.append(f"{label}: BUDGET {len(parts)} parts > {INTERIOR_PART_BUDGET}")
    if fl.lights > 1:
        findings.append(f"{label}: BUDGET {fl.lights} PointLights > 1")

    half_w, half_d, face = fl.width / 2, fl.depth / 2, wt / 2
    boxes = [(p[1], p[2], p[3], p[4], p[5], p[6]) for p in parts]

    # SOLID: every furniture piece collidable, anchored and registered.
    groups = {}
    for p in parts:
        name, collide, anchored, tag = p[0], p[7], p[8], p[9]
        if house and name not in FURNITURE_TRIM:
            if not tag.startswith("Furniture:"):
                if collide:
                    findings.append(f"{label}: SOLID unregistered {name} (collidable, no Destructible tag)")
                else:
                    findings.append(f"{label}: SOLID untagged trim {name}")
                continue
            groups.setdefault(tag, []).append(p)
            if collide and not anchored:
                findings.append(f"{label}: SOLID {name} not anchored")
        elif collide and name in FURNITURE_TRIM:
            findings.append(f"{label}: SOLID {name} is trim but collides")
    for tag, members in groups.items():
        if not any(m[7] for m in members):
            findings.append(f"{label}: SOLID {members[0][0]} not collidable (no part of {tag} collides)")
        kind = tag.split(":")[0]
        if kind not in kinds:
            findings.append(f"{label}: SOLID {tag} pool kind {kind} not in DestructibleService KINDS")

    # NO_CLIP between different pieces (and into the skirting / door frames).
    # A piece is its Destructible group. The stockroom set (towers, warehouses) is untagged: there a
    # piece is its Name (a crate stack, a table and its legs), and a shelf owns the clutter on it.
    def owner(p):
        if p[9]:
            return p[9]
        return "Shelf" if p[0] == "Part" else p[0]
    for i, a in enumerate(parts):
        if a[0] == "Rug":
            continue
        for j in range(i + 1, len(parts)):
            b = parts[j]
            if b[0] == "Rug" or owner(a) == owner(b):
                continue
            if not (a[7] or b[7] or a[0] in FURNITURE_TRIM or b[0] in FURNITURE_TRIM):
                continue
            if a[0] in FURNITURE_TRIM and b[0] in FURNITURE_TRIM:
                continue
            if boxes_intersect(boxes[i], boxes[j]):
                findings.append(f"{label}: NO_CLIP {a[0]} clips {b[0]} at ({a[1]:.1f},{a[3]:.1f})")

    # IN_BOUNDS
    for p, (x, y, z, ex, ey, ez) in zip(parts, boxes):
        if abs(x) + ex > half_w - face + EPS or abs(z) + ez > half_d - face + EPS:
            findings.append(f"{label}: IN_BOUNDS {p[0]} reaches past the wall at ({x:.1f},{z:.1f})")
        if y - ey < floor_top - EPS or y + ey > FLOOR_HEIGHT - 0.5 + EPS:
            findings.append(f"{label}: IN_BOUNDS {p[0]} through the floor or ceiling (y {y - ey:.2f}..{y + ey:.2f})")

    # CLEAR_ZONES and WINDOW_BLOCK
    zones = window_zones(fl, wt, win_w)
    door_lane = (0.0, -half_d + face + DOOR_LANE_DEPTH / 2, door_w / 2 + 1.0, DOOR_LANE_DEPTH / 2)
    door_open = (0.0, -half_d + face + DOOR_LANE_DEPTH / 2, door_w / 2, DOOR_LANE_DEPTH / 2)
    stair = (-half_w + fl.stair_side / 2, -half_d + fl.stair_clear / 2, fl.stair_side / 2, fl.stair_clear / 2)
    for p, (x, y, z, ex, ey, ez) in zip(parts, boxes):
        if p[0] == "Rug":
            continue
        top = y + ey
        if p[7]:
            if fl.floor == 0 and overlaps_xz(p, door_lane):
                findings.append(f"{label}: CLEAR_ZONES {p[0]} (solid) stands in the doorway lane")
            if fl.can_climb and overlaps_xz(p, stair):
                findings.append(f"{label}: CLEAR_ZONES {p[0]} (solid) stands on the stair strip")
        if fl.floor == 0 and overlaps_xz(p, door_open) and p[0] != "DoorFrame":
            findings.append(f"{label}: WINDOW_BLOCK {p[0]} stands in the door opening")
        for zone in zones:
            if overlaps_xz(p, zone):
                if top > floor_top + sill - SILL_MARGIN:
                    findings.append(f"{label}: WINDOW_BLOCK {p[0]} (top {top - floor_top:.1f} above the floor) "
                                    f"stands in front of a window at ({zone[0]:.1f},{zone[1]:.1f})")
                elif p[7]:
                    findings.append(f"{label}: CLEAR_ZONES {p[0]} (solid) in a window's vault lane")

    # PARTITION
    if fl.partition is not None:
        side = fl.windows[2] + fl.windows[3]
        for off in side:
            if abs(fl.partition - off) < win_w / 2 + wt / 2:
                findings.append(f"{label}: PARTITION meets a side wall across its window (z {fl.partition} vs {off:.1f})")
    return parts


def run_suite(rt, c, kinds, seeds, floors_list, others, palettes):
    findings, names, purposes = [], set(), set()
    counts = []
    signature = {"kitchen": {"Counter", "Fridge", "Stove"}, "living": {"Sofa", "TvUnit"},
                 "bedroom": {"Bed"}, "bathroom": {"Toilet", "Vanity"}}
    for seed in seeds:
        palette = palettes[seed % len(palettes)]
        for w, d, n, f in floors_list:
            fl = Floor(rt, "house", w, d, n, f, seed, palette)
            parts = check_floor(fl, f"house w{w}d{d}f{n}/{f} seed{seed} {palette}", findings, c, kinds)
            here = {p[0] for p in parts}
            counts.append(len({p[9] for p in parts if p[9]}))
            names |= here
            purposes |= {k for k, v in signature.items() if here & v}
        for arch, w, d, n, f in others:
            fl = Floor(rt, arch, w, d, n, f, seed, palette)
            check_floor(fl, f"{arch} w{w}d{d}f{n}/{f} seed{seed}", findings, c, kinds)
    if counts and len(counts) > 20:
        mean = sum(counts) / len(counts)
        sparse = sum(1 for n in counts if n < 3) / len(counts)
        print(f"  pieces per house floor: mean {mean:.1f}, min {min(counts)}, under three {sparse:.0%}")
        if mean < 4.5 or sparse > 0.05:
            findings.append(f"LIVED_IN: rooms too bare (mean {mean:.1f} pieces, {sparse:.0%} under three)")
    return findings, names, purposes


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else "."
    src = (Path(repo) / "ServerScriptService/Modules/MapBuildings.lua").read_text(encoding="utf-8")
    ds = (Path(repo) / "ServerScriptService/Modules/DestructibleService.lua").read_text(encoding="utf-8")
    kinds_block = re.search(r"^local KINDS = \{(.*?)^\}", ds, re.M | re.S).group(1)
    kinds = set(re.findall(r"(\w+)\s*=", kinds_block))
    c = {n: const(src, n) for n in ("WALL_THICKNESS", "SILL_HEIGHT", "WINDOW_WIDTH", "DOOR_WIDTH")}
    ok = True
    for guard in GUARDS:
        if not re.search(guard, src):
            print(f"  GUARD: buildBuilding no longer matches the harness: {guard}")
            ok = False

    rt = build_runtime(repo)
    findings, names, purposes = run_suite(rt, c, kinds, SEEDS, HOUSE_FLOORS, OTHER_ARCHETYPE_FLOORS, PALETTES)
    missing = {"kitchen", "living", "bedroom", "bathroom"} - purposes
    if missing:
        findings.append(f"COVERAGE: never saw {sorted(missing)}")
    pieces = set(re.findall(r"= \"(\w+)\"", re.search(r"^local FURNITURE_NAME = \{(.*?)^\}", src, re.M | re.S).group(1)))
    unseen = pieces - STOCKROOM - names - {"Crate"}
    if unseen:
        findings.append(f"COVERAGE: pieces never built: {sorted(unseen)}")

    # Styles: interiorStyle, run in Lua, must spread four town palettes over at least four styles.
    spread = rt.globals().styleSpread()
    if spread < 4:
        findings.append(f"COVERAGE: only {spread} interior styles across four town palettes")

    a = Floor(rt, "house", 32, 30, 2, 0, 777, "farm").parts
    b = Floor(rt, "house", 32, 30, 2, 0, 777, "farm").parts
    if a != b:
        findings.append("DETERMINISTIC: seed 777 built two different floors")

    # Planted faults.
    def plant(label, old, new, expect, floors_list, others=()):
        s2 = src.replace(old, new, 1)
        if s2 == src:
            raise SystemExit(f"{label} plant text not found")
        rtp = build_runtime(repo, lambda _s: s2)
        f, _, _ = run_suite(rtp, c, kinds, range(1, 41), floors_list, others, PALETTES)
        caught = any(expect in x for x in f)
        print(f"  plant {label}: {'caught' if caught else 'MISSED'} ({expect})")
        return caught

    place_head = "local function placeOnWall(ctx, name)\n\tlocal spec = PIECES[name]\n"
    ground = [(32, 30, 2, 0), (36, 32, 2, 0)]
    upper = [(32, 30, 2, 1), (40, 34, 3, 2)]
    plants = [
        plant("P1 sofa in doorway", place_head, place_head +
              "\tif name == \"sofa\" then\n\t\tlocal px, pz = ctx.faces[1].at(0, WALL_GAP + 1.5)\n"
              "\t\tbuildPiece(ctx.parent, name, px, ctx.floorY, pz, 0, ctx.style, \"P1\", ctx.lights)\n\t\treturn true\n\tend\n",
              "CLEAR_ZONES Sofa (solid) stands in the doorway lane", ground),
        plant("P2 wardrobe over window", place_head, place_head +
              "\tif name == \"wardrobe\" then\n\t\tlocal face = ctx.faces[2]\n"
              "\t\tlocal along = windowOffsets(2 * (face.reach + WALL_THICKNESS / 2), 15)[1]\n"
              "\t\tlocal px, pz = face.at(along, WALL_GAP + 1.2)\n"
              "\t\tbuildPiece(ctx.parent, name, px, ctx.floorY, pz, face.yaw, ctx.style, \"P2\", ctx.lights)\n\t\treturn true\n\tend\n",
              "WINDOW_BLOCK Wardrobe", upper),
        plant("P3 unregistered solid",
              "\t\tlocal part = makePart(parent, size, frame * CFrame.new(px, py, pz), color, material)\n\t\tpart:SetAttribute(\"Destructible\", group)\n",
              "\t\tlocal part = makePart(parent, size, frame * CFrame.new(px, py, pz), color, material)\n",
              "SOLID unregistered", ground + upper),
        plant("P4 all non-collide",
              "\t\tlocal part = makePart(parent, size, frame * CFrame.new(px, py, pz), color, material)\n",
              "\t\tlocal part = trim(parent, size, frame * CFrame.new(px, py, pz), color, material)\n",
              "not collidable", ground + upper),
        plant("P5 into the wall", "local WALL_GAP = 0.35", "local WALL_GAP = -1", "IN_BOUNDS", ground + upper),
        plant("P6 partition across window", "local clear = WINDOW_WIDTH / 2 + WALL_THICKNESS / 2 + 0.4",
              "local clear = -1", "PARTITION", [(36, 32, 2, 0), (40, 34, 3, 2)]),
    ]

    print(f"interior_check: {len(list(SEEDS))} seeds x {len(HOUSE_FLOORS)} house floors "
          f"+ {len(OTHER_ARCHETYPE_FLOORS)} other floors x palettes {PALETTES}, budget <= {INTERIOR_PART_BUDGET}")
    print(f"purposes seen: {sorted(purposes)}; pieces seen: {len(names & pieces)}; styles: {spread}")
    if findings:
        ok = False
        print(f"{len(findings)} finding(s):")
        for f in findings[:40]:
            print(" ", f)
    ok = ok and all(plants)
    print("interior_check:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
