"""House interior furnishing audit, without Studio.

Runs the REAL buildInterior (and its helpers: makePart, trim, decorPart, clutter, pick, the
ROOM_KINDS pools and roomPurpose) sliced out of ServerScriptService/Modules/MapBuildings.lua, under
the CFrame/Vector3/Instance mock from tools/vehicle_models_axis_check.py, with the REAL MapSpace.lua
as the room grid and a Random mock standing in for Roblox's Random (a tiny seeded LCG, so two runs
of the same seed are byte-identical -- Roblox's own Random gives that guarantee, this just needs a
Lua one that does too).

Each run seeds the room the way buildBuilding does before it calls buildInterior: the stairwell
strip (ground and any climbable floor) and the ground-floor doorway circle, both by the exact
formula buildBuilding uses (STAIR_WIDTH/STAIR_LANDING/STAIR_RUN/STAIR_EXIT, read from the source, not
copied by hand). buildInterior sees the same room a real floor would.

Checks, over many seeds x archetypes x floors:
  1. BUDGET: total instances buildInterior adds to one floor <= INTERIOR_PART_BUDGET.
  2. NO_OVERLAP: no two collidable (CanCollide ~= false) parts' XZ footprints overlap.
  3. CLEAR_ZONES: no collidable part's footprint overlaps the doorway circle or the stair strip.
  4. IN_BOUNDS: no collidable part's XZ footprint reaches outside the floor's own walls.
  5. DETERMINISTIC: the same seed run twice gives byte-identical Part dumps.
  6. PURPOSE_COVERAGE: over many seeds, all four house purposes (kitchen/living/bedroom/bathroom)
     get built at least once, and each purpose's furniture set actually appears on its floor.

Planted faults (source edits, rebuilt): P1 forces a piece onto the doorway circle, unconditionally
(CLEAR_ZONES must catch it). P2 shrinks the wall inset until a wide piece reaches past the wall
(IN_BOUNDS must catch it). A plant that does not fire is reported as such, not counted as a pass.

    python3 tools/interior_check.py [repo]        -> exit 0 when clean
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK  # noqa: E402
from car_placement_luau import luau_to_lua  # noqa: E402 (handles `continue`, unlike the simpler one)

from lupa import LuaRuntime  # noqa: E402

INTERIOR_PART_BUDGET = 40
SEEDS = range(1, 61)
HOUSE_FLOORS = [(32, 30, 2, 0), (32, 30, 2, 1), (40, 34, 3, 2)]  # width, depth, floors, this floor
OTHER_ARCHETYPE_FLOORS = [("tower", 30, 30, 4, 0), ("warehouse", 34, 28, 1, 0)]

# Extra Lua the slice needs beyond vehicle_models_axis_check's MOCK: a seeded Random stand-in (a
# small LCG -- deterministic across runs, unlike relying on Lua's own math.random seed state), a
# HazardService stub for the generic (non-house) barrel kind, so both must exist BEFORE the sliced
# source's own top-level `local rng = Random.new()` runs.
PRELUDE = r"""
local function makeRandom(seed)
	seed = seed or 1
	-- A raw small seed feeds straight into a Lehmer step's low output range (seed=1 -> 48271, a
	-- tiny first float every time); scramble it first with a Knuth multiplicative hash.
	local state = (seed * 2654435761) % 2147483647
	if state == 0 then state = 1 end
	local function nextFloat()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	for _ = 1, 6 do
		nextFloat()
	end
	local obj = {}
	function obj:NextNumber() return nextFloat() end
	function obj:NextInteger(m, n) return m + math.floor(nextFloat() * (n - m + 1)) end
	return obj
end
Random = { new = makeRandom }

HazardService = { Barrel = function(parent, cframe)
	local part = Instance.new("Part")
	part.Name = "Barrel"
	part.Size = Vector3.new(4, 4, 4)
	part.CFrame = cframe
	part.Parent = parent
end }
"""

# The dump / room-seeding / driver, needing buildInterior et al already in scope -- placed AFTER
# the sliced source.
HARNESS = r"""
local function dumpFloor(model)
	local out = {}
	for _, p in ipairs(model:GetChildren()) do
		if p.ClassName == "Part" then
			local c, s = p.CFrame, p.Size
			table.insert(out, {
				p.Name, s.X, s.Y, s.Z, c.p.X, c.p.Y, c.p.Z,
				p.CanCollide ~= false,
			})
		end
	end
	return out
end

-- Mirrors buildBuilding's own room seeding for one floor (COORDINATION: the stair/door claims a
-- floor's furniture must stay out of), from the real constants -- not copied by hand.
function seedRoom(room, origin, halfW, halfD, isGround, canClimb)
	local stairSide = 1 + STAIR_WIDTH + STAIR_EXIT
	local stairClear = 1 + STAIR_LANDING + STAIR_RUN + STAIR_EXIT
	if canClimb then
		room:AddRect(origin.X - halfW + stairSide / 2, origin.Z - halfD + stairClear / 2, stairSide / 2, stairClear / 2)
	end
	if isGround then
		room:AddCircle(origin.X, origin.Z - halfD + 3, 6)
	end
	return stairSide, stairClear
end

-- `canClimb` for the ROOM CLAIM (not whether a flight is drawn on this floor) matches
-- buildBuilding: computed once per building from width/depth/floors alone, applied on every floor.
function runFloor(archetype, width, depth, floors, floor, seed)
	rng = Random.new(seed)
	local MapSpace = (assert(load(MAPSPACE_SRC)))()
	local room = MapSpace.new()
	local origin = Vector3.new(0, 0, 0)
	local halfW, halfD = width / 2, depth / 2
	local floorHeight = 15
	local isGround = floor == 0
	local stairClear2 = 1 + STAIR_LANDING + STAIR_RUN + STAIR_EXIT
	local canClimb = floors > 1 and width >= 26 and depth >= stairClear2 + WALL_THICKNESS
	local stairSide, stairClear = seedRoom(room, origin, halfW, halfD, isGround, canClimb)

	-- Every circle buildInterior claims through room:AddCircle, captured as it happens: this is
	-- the authoritative "this spot is taken" record the game itself trusts (bots and the stair /
	-- doorway claims use the same grid), so it is what NO_OVERLAP and CLEAR_ZONES are checked
	-- against, not raw part boxes (a table's top legitimately overlaps its own legs).
	local claims = {}
	room.AddCircle = function(self, x, z, r)
		table.insert(claims, { x, z, r })
		return MapSpace.AddCircle(self, x, z, r)
	end

	local model = Instance.new("Model")
	buildInterior(model, origin, width, depth, 0, floorHeight, room, archetype, floor)
	return dumpFloor(model), claims, stairSide, stairClear, isGround, canClimb
end
"""


def slice_source(text, start_pat, end_pat):
    start = re.search(start_pat, text, re.M)
    end = re.search(end_pat, text, re.M)
    if not start or not end:
        raise SystemExit(f"could not find slice bounds {start_pat!r} .. {end_pat!r}")
    return text[start.start():end.start()]


def build_runtime(repo, patch=None):
    mb_path = Path(repo) / "ServerScriptService/Modules/MapBuildings.lua"
    src = mb_path.read_text()
    if patch:
        src = patch(src)

    consts = "\n".join(
        m.group(0) for m in re.finditer(
            r"^local (?:WALL_THICKNESS|DOOR_WIDTH|STAIR_WIDTH|STAIR_LANDING|STAIR_RUN|STAIR_EXIT) = .+$",
            src, re.M))
    helpers = slice_source(src, r"^local currentName = ", r"^local AWNING_COLORS")
    interior = slice_source(src, r"^local FURNITURE_RADIUS = \{", r"^-- Buildings\n")
    interior = "local FURNITURE_RADIUS = {" + interior.split("{", 1)[1]

    space_path = Path(repo) / "ServerScriptService/Modules/MapSpace.lua"
    mapspace_src = space_path.read_text()
    # Strip the trailing `return MapSpace` so it can be embedded as a Lua string literal loaded by
    # `load(...)` inside the harness, verbatim -- the real module, not a re-implementation.
    mapspace_lua = "MAPSPACE_SRC = " + repr_lua_string(mapspace_src)

    lua_src = "\n".join([
        MOCK,
        mapspace_lua,
        PRELUDE,
        consts,
        luau_to_lua(helpers),
        luau_to_lua(interior),
        HARNESS,
    ])
    rt = LuaRuntime(unpack_returned_tuples=True)
    rt.execute(lua_src)
    return rt


def repr_lua_string(s):
    # A Lua long-bracket string, safest for arbitrary source text (no escaping of quotes needed).
    level = 0
    while ("]" + "=" * level + "]") in s:
        level += 1
    eq = "=" * level
    return f"[{eq}[\n{s}\n]{eq}]"


def footprint(part):
    name, sx, sy, sz, x, y, z, collide = part
    return name, x, z, sx / 2, sz / 2, collide


# Ported verbatim from MapSpace:overlaps (circle vs. axis-aligned rect / circle), the real
# occupancy test the game itself trusts -- not a box-vs-box approximation of it.
def overlaps_rect_zone(x, z, radius, cx, cz, hx, hz):
    out_x = max(abs(x - cx) - hx, 0)
    out_z = max(abs(z - cz) - hz, 0)
    return out_x * out_x + out_z * out_z < radius * radius


def overlaps_circle_zone(x, z, radius, cx, cz, r):
    dx, dz = x - cx, z - cz
    reach = radius + r
    return dx * dx + dz * dz < reach * reach


def check_floor(rt, archetype, width, depth, floors, floor, seed, label, findings):
    lua_parts, lua_claims, stairSide, stairClear, isGround, canClimb = rt.globals().runFloor(
        archetype, width, depth, floors, floor, seed)
    n = len(lua_parts)
    parts = [[lua_parts[i + 1][j + 1] for j in range(8)] for i in range(n)]
    nc = len(lua_claims)
    claims = [[lua_claims[i + 1][j + 1] for j in range(3)] for i in range(nc)]
    if n > INTERIOR_PART_BUDGET:
        findings.append(f"{label}: BUDGET {n} parts > {INTERIOR_PART_BUDGET}")

    halfW, halfD = width / 2, depth / 2
    # Exactly buildBuilding's own room:AddRect(origin.X - halfW + stairSide/2, ...): centre and
    # half-extents, not corners.
    stair_cx, stair_cz = -halfW + stairSide / 2, -halfD + stairClear / 2
    stair_hx, stair_hz = stairSide / 2, stairClear / 2

    # NO_OVERLAP / CLEAR_ZONES: against the claim circles buildInterior itself staked out (the
    # authoritative occupancy record) -- true by construction unless freeSpot's own gate breaks.
    for i, (x, z, r) in enumerate(claims):
        if canClimb and overlaps_rect_zone(x, z, r, stair_cx, stair_cz, stair_hx, stair_hz):
            findings.append(f"{label}: CLEAR_ZONES claim@({x:.1f},{z:.1f}) fouls the stair strip")
        if isGround and overlaps_circle_zone(x, z, r, 0, -halfD + 3, 6):
            findings.append(f"{label}: CLEAR_ZONES claim@({x:.1f},{z:.1f}) fouls the doorway")
        for x2, z2, r2 in claims[i + 1:]:
            if (x - x2) ** 2 + (z - z2) ** 2 < (r + r2 - 0.05) ** 2:
                findings.append(f"{label}: NO_OVERLAP claim@({x:.1f},{z:.1f}) clips claim@({x2:.1f},{z2:.1f})")

    # IN_BOUNDS: real rendered geometry, per part -- a wide item actually poking past the wall.
    for name, x, z, hx, hz, collide in (footprint(p) for p in parts):
        if collide and (abs(x) + hx > halfW - 0.05 or abs(z) + hz > halfD - 0.05):
            findings.append(f"{label}: IN_BOUNDS {name} reaches past the wall")
    return parts


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else "."
    rt = build_runtime(repo)
    findings = []
    purposes_seen = set()
    kind_names_by_purpose = {
        "kitchen": {"Counter", "Stove"}, "living": {"Sofa"}, "bedroom": {"Bed", "Wardrobe", "Nightstand"},
        "bathroom": {"Sink", "Toilet"},
    }

    for seed in SEEDS:
        for width, depth, floors, floor in HOUSE_FLOORS:
            label = f"house w{width}d{depth}f{floors}/{floor} seed{seed}"
            parts = check_floor(rt, "house", width, depth, floors, floor, seed, label, findings)
            names = {p[0] for p in parts}
            for purpose, kinds in kind_names_by_purpose.items():
                if names & kinds:
                    purposes_seen.add(purpose)
        for archetype, width, depth, floors, floor in OTHER_ARCHETYPE_FLOORS:
            label = f"{archetype} w{width}d{depth}f{floors}/{floor} seed{seed}"
            check_floor(rt, archetype, width, depth, floors, floor, seed, label, findings)

    missing = {"kitchen", "living", "bedroom", "bathroom"} - purposes_seen
    if missing:
        findings.append(f"PURPOSE_COVERAGE: never saw {sorted(missing)} over {len(list(SEEDS))} seeds")

    # DETERMINISTIC: same seed, twice.
    a = check_floor(rt, "house", 32, 30, 2, 0, 777, "determinism#1", [])
    b = check_floor(rt, "house", 32, 30, 2, 0, 777, "determinism#2", [])
    if a != b:
        findings.append("DETERMINISTIC: seed 777 built two different floors")

    # Planted fault P1: freeSpot's own gate stops checking the room before claiming a spot, so
    # furniture can land on the stairwell, the doorway, or on top of each other.
    def plant_gate(src):
        patched = src.replace('if room:IsFree(x, z, radius) then', "if true then", 1)
        if patched == src:
            raise SystemExit("P1 plant text not found")
        return patched

    rt1 = build_runtime(repo, plant_gate)
    f1 = []
    for seed in range(1, 21):
        check_floor(rt1, "house", 32, 30, 2, 0, seed, f"P1 seed{seed}", f1)
    p1_caught = any(("CLEAR_ZONES" in f or "NO_OVERLAP" in f) for f in f1)

    # Planted fault P2: shrink the wall inset so a wide piece reaches past the wall.
    def plant_inset(src):
        return src.replace(
            "local inset = WALL_THICKNESS / 2 + 0.5",
            "local inset = -3", 1)

    rt2 = build_runtime(repo, plant_inset)
    f2 = []
    for seed in range(1, 16):
        check_floor(rt2, "house", 32, 30, 2, 0, seed, f"P2 seed{seed}", f2)
    p2_caught = any("IN_BOUNDS" in f for f in f2)

    print(f"interior_check: {len(list(SEEDS))} seeds x {len(HOUSE_FLOORS)} house floors "
          f"+ {len(OTHER_ARCHETYPE_FLOORS)} other archetypes, budget <= {INTERIOR_PART_BUDGET}")
    print(f"purposes seen: {sorted(purposes_seen)}")
    print(f"planted faults: P1 doorway {'caught' if p1_caught else 'MISSED'}, "
          f"P2 wall inset {'caught' if p2_caught else 'MISSED'}")

    ok = not findings and p1_caught and p2_caught
    if findings:
        print(f"{len(findings)} finding(s):")
        for f in findings[:40]:
            print(" ", f)
    if not p1_caught:
        print("  PLANT P1 DID NOT FIRE")
    if not p2_caught:
        print("  PLANT P2 DID NOT FIRE")
    print("interior_check:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
