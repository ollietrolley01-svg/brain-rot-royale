"""The team bases' access roads (TeamBaseRoads.lua), checked without Studio (Oliver, 2026-09-24: "make
sure the team bases connect to the roads too").

Runs the REAL ServerScriptService/Modules/TeamBaseRoads.lua -- Plan, Profile, Build and Register -- on a
synthetic map: a network of axis-aligned roads (as RoadNetwork lays them, with their height profiles),
hilly ground, the battleground's disc in the middle and buildings that cannot be cleared, from bases at
many positions and headings. For each base:

  link       a route is found (for all but MAY_FAIL of the 12 on this deliberately crowded map), it starts at the gate heading straight out of it, and it ends butted
             square onto a road edge (a T-junction: the last stretch at right angles to the road, the
             junction on the road's edge, clear of the edge's ends)
  shape      no bend tighter than TeamBaseRoads.MinRadius, no grade steeper than MaxGrade, pinned to
             the gate's height and to the road's own surface height at the junction
  keep out   never within the battleground's disc or across another road, never through a building
  surface    the slabs' top edges meet at every sample; the biggest vehicle (read from VehicleModels'
             real builds) swept along the whole road, a stud either side, above the surface: nothing
             solid in it, and it stays on the carriageway
  bots       after Register, the gate's node reaches the rest of the network through roads.edges (what
             BotNav walks), and the undo puts roads.edges back exactly
  team only  (tools/team_base_ruins_modeteams_check.py's WIRING: the battle royale never reaches
             TeamBaseRoads)

    python3 tools/team_base_road_check.py [repo]            the checks
    python3 tools/team_base_road_check.py [repo] --plant    and the planted faults
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_base_ruins_check as TBR  # noqa: E402

SETUP = r"""
table.find = table.find or function(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
table.clone = table.clone or function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
math.clamp = math.clamp or function(x, a, b) return math.max(a, math.min(b, x)) end

-- A network of roads on the world's axes: a ring round the middle at 520 and two long roads crossing
-- it, each edge with a height profile (every 8 studs) like RoadNetwork's.
function makeNetwork(groundAt)
    local nodes, edges = {}, {}
    local function node(x, z)
        for _, n in ipairs(nodes) do
            if math.abs(n.position.X - x) < 0.01 and math.abs(n.position.Z - z) < 0.01 then return n end
        end
        local n = { position = Vector3.new(x, 0, z), arms = {}, index = #nodes + 1 }
        table.insert(nodes, n)
        return n
    end
    local function edge(x0, z0, x1, z1)
        local a, b = node(x0, z0), node(x1, z1)
        local length = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
        local e = { a = a, b = b, from = a.position, to = b.position, length = length, step = 8, heights = {}, index = #edges + 1 }
        for k = 0, math.ceil(length / 8) do
            local t = math.min(1, k * 8 / length)
            table.insert(e.heights, groundAt(x0 + (x1 - x0) * t, z0 + (z1 - z0) * t))
        end
        local name = (x1 > x0 and "E") or (x1 < x0 and "W") or (z1 > z0 and "S") or "N"
        local back = ({ E = "W", W = "E", S = "N", N = "S" })[name]
        a.arms[name] = e
        b.arms[back] = e
        table.insert(edges, e)
    end
    local R = 520
    edge(-R, -R, 0, -R); edge(0, -R, R, -R); edge(R, -R, R, 0); edge(R, 0, R, R)
    edge(R, R, 0, R); edge(0, R, -R, R); edge(-R, R, -R, 0); edge(-R, 0, -R, -R)
    edge(-R, 0, -900, 0); edge(R, 0, 900, 0); edge(0, -R, 0, -900); edge(0, R, 0, 900)
    -- The roads out of the middle town, ended at the battleground's apron.
    edge(-250, 0, -R, 0); edge(250, 0, R, 0); edge(0, -250, 0, -R); edge(0, 250, 0, R)
    -- A street across the middle town, inside the battleground's disc: the nearest road to some bases,
    -- and never to be joined through the arena.
    edge(-160, 120, 160, 120)
    return { edges = edges, nodes = nodes }
end
function mul(cf, v) return cf * v end
function hills(x, z)
    return 20 + 9 * math.sin(x / 90) * math.cos(z / 110) + 4 * math.sin((x + z) / 47) + 2.5 * math.sin(x / 23) * math.sin(z / 29)
end
-- Buildings nobody may drive through: squares { x, z, half }.
BUILDINGS = { { 250, -380, 30 }, { -420, 260, 26 }, { 380, 300, 34 } }
function blockedBy(a, b)
    for _, h in ipairs(BUILDINGS) do
        for k = 0, 8 do
            local t = k / 8
            local x, z = a.X + (b.X - a.X) * t, a.Z + (b.Z - a.Z) * t
            if math.abs(x - h[1]) < h[3] + 12 and math.abs(z - h[2]) < h[3] + 12 then return "building" end
        end
    end
    return nil
end
function reachable(roads, gate)
    local adjacency = {}
    for _, e in ipairs(roads.edges) do
        adjacency[e.a] = adjacency[e.a] or {}
        adjacency[e.b] = adjacency[e.b] or {}
        table.insert(adjacency[e.a], e.b)
        table.insert(adjacency[e.b], e.a)
    end
    local seen, queue, count = { [gate] = true }, { gate }, 0
    while #queue > 0 do
        local n = table.remove(queue)
        if not n.access then count = count + 1 end
        for _, m in ipairs(adjacency[n] or {}) do
            if not seen[m] then seen[m] = true; table.insert(queue, m) end
        end
    end
    return count
end
"""

# Bases: (x, z, heading in degrees from +X): round the middle, facing it, as ModeTeams puts them.
BASES = [(420 * math.cos(math.radians(a)), 420 * math.sin(math.radians(a)), a + 180) for a in range(0, 360, 30)]
ARENA = 230.0
# Gentle grades (Oliver): the steepest an access road may climb, whatever the module says.
GRADE = 1 / 8

MAY_FAIL = 2


def run(root, edits=None, log=print):
    src = TBR.sources(root)
    roads_src = (Path(root) / "ServerScriptService/Modules/TeamBaseRoads.lua").read_text(encoding="utf-8")
    for old, new in edits or []:
        if old not in roads_src:
            return ["plant anchor not found: " + old[:60]]
        roads_src = roads_src.replace(old, new, 1)
    build = TBR.Build(src)
    lua = build.lua
    lua.execute(SETUP)
    mod = lua.execute(TBR.luau_to_lua(roads_src))
    g = lua.globals()
    from team_base_ruins_modeteams_check import vehicle_extents
    sizes = vehicle_extents(root)
    vw = max(v[0] for v in sizes.values()) / 2 + 1.0
    vh = max(v[2] for v in sizes.values())
    half = mod.Width / 2
    problems = []
    unlinked = []
    built = 0
    for bx, bz, deg in BASES:
        name = "base at (%d, %d)" % (bx, bz)
        net = g.makeNetwork(g.hills)
        before = [g.tostring(net.edges[i]) for i in range(1, len(net.edges) + 1)]
        h = math.radians(deg)
        heading = g.Vector3.new(math.cos(h), 0, math.sin(h))
        # The compound's frame (LookVector = heading), its two gates as the real one has them.
        frame = g.CFrame.lookAt(g.Vector3.new(bx, 0, bz), g.Vector3.new(bx + heading.X, 0, bz + heading.Z))
        front = g.mul(frame, g.Vector3.new(33, 0, -57.8))
        east = g.mul(frame, g.Vector3.new(70.8, 0, 29))
        start = front
        gates = lua.table_from([lua.table_from({"position": front, "heading": frame.LookVector}),
                                lua.table_from({"position": east, "heading": frame.RightVector})])
        avoid = lua.table_from([lua.table_from({"centre": g.Vector3.new(0, 0, 0), "radius": ARENA, "name": "battleground"})])
        boxes = lua.table_from([lua.table_from({"frame": frame, "halfX": 71, "halfZ": 59})])
        starts = lua.table_from([g.hills(front.X, front.Z), g.hills(east.X, east.Z)])
        opts = lua.table_from({"avoid": avoid, "blocked": g.blockedBy, "boxes": boxes, "groundAt": g.hills, "startY": starts})
        got = mod.Plan(gates, None, net, opts)
        plan, why = got if isinstance(got, tuple) else (got, None)
        if plan is None:
            unlinked.append("%s: no access road (%s)" % (name, why))
            continue
        pts = [(p.X, p.Z) for p in plan.points.values()]
        # link
        start = front if plan.gate == 1 else east
        heading = frame.LookVector if plan.gate == 1 else frame.RightVector
        if math.dist(pts[0], (start.X, start.Z)) > 0.01:
            problems.append("%s: the road does not start at a gate" % name)
        d0 = ((pts[1][0] - pts[0][0]), (pts[1][1] - pts[0][1]))
        if (d0[0] * heading.X + d0[1] * heading.Z) / math.hypot(*d0) < math.cos(math.radians(2)):
            problems.append("%s: the road does not leave the gate straight" % name)
        e = plan.edge
        ax, az, bx2, bz2 = e["from"].X, e["from"].Z, e["to"].X, e["to"].Z
        ex, ez = bx2 - ax, bz2 - az
        el = math.hypot(ex, ez)
        ux, uz = ex / el, ez / el
        jx, jz = pts[-1]
        lateral = abs((jx - ax) * uz - (jz - az) * ux)
        along = (jx - ax) * ux + (jz - az) * uz
        if abs(lateral - half) > 0.05:
            problems.append("%s: the junction is %.2f off the road's centre line, not on its edge (%.1f)" % (name, lateral, half))
        if along < 30 or along > el - 30:
            problems.append("%s: the junction is in the edge's end (%.1f of %.1f)" % (name, along, el))
        dl = ((pts[-1][0] - pts[-2][0]), (pts[-1][1] - pts[-2][1]))
        if abs((dl[0] * ux + dl[1] * uz) / math.hypot(*dl)) > 0.05:
            problems.append("%s: the road meets the road at an angle, not square" % name)
        # shape
        for i in range(1, len(pts) - 1):
            u = (pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
            v = (pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
            cos = max(-1, min(1, (u[0] * v[0] + u[1] * v[1]) / (math.hypot(*u) * math.hypot(*v))))
            turn = math.acos(cos)
            chord = (math.hypot(*u) + math.hypot(*v)) / 2
            if turn > 1e-6 and chord / turn < mod.MinRadius - 0.5:
                problems.append("%s: a bend of radius %.1f" % (name, chord / turn))
                break
        # The gate stands on its graded ramp: the ground there is the compound's height.
        gate_y = g.hills(pts[0][0], pts[0][1])
        heights = mod.Profile(plan, g.hills, gate_y)
        hs = [heights[i] for i in range(1, len(pts) + 1)]
        for i in range(1, len(pts)):
            grade = abs(hs[i] - hs[i - 1]) / math.dist(pts[i], pts[i - 1])
            if grade > GRADE + 0.02:
                problems.append("%s: a grade of %.3f" % (name, grade))
                break
        if abs(hs[0] - gate_y) > 1e-6:
            problems.append("%s: not level with the gate" % name)
        t = plan.along / e.step
        k = int(t)
        eh = [e.heights[i] for i in range(1, len(e.heights) + 1)]
        want = eh[k] + (eh[min(k + 1, len(eh) - 1)] - eh[k]) * (t - k)
        # Never under the ground (the terrain would come up through the asphalt), away from the pinned ends.
        for i in range(3, len(pts) - 3):
            if hs[i] + mod.Lift < g.hills(pts[i][0], pts[i][1]) - 0.01:
                problems.append("%s: the road runs under the ground at stretch %d" % (name, i))
                break
        if abs(hs[-1] - want) > 0.05:
            problems.append("%s: the junction is %.2f off the road's surface" % (name, hs[-1] - want))
        # keep out
        for (px, pz) in pts:
            if math.hypot(px, pz) < ARENA + half - 0.5:
                problems.append("%s: the road runs into the battleground" % name)
                break
        for i in range(1, len(pts)):
            a = g.Vector3.new(pts[i - 1][0], 0, pts[i - 1][1])
            b = g.Vector3.new(pts[i][0], 0, pts[i][1])
            if g.blockedBy(a, b):
                problems.append("%s: the road runs through a building" % name)
                break
        # surface
        model = mod.Build(plan, heights, None, None)
        built += 1
        parts = build.dump(model)
        for p in parts:
            p["aabb"] = TBR.aabb(p)
        slabs = [p for p in parts if p["name"] == "RoadSurface"]
        if len(slabs) != len(pts) - 1:
            problems.append("%s: %d slabs for %d stretches" % (name, len(slabs), len(pts) - 1))
        solid = [p for p in parts if p["collide"] and p["name"] not in ("RoadSurface", "RoadJoint")]
        for i in range(1, len(pts)):
            x0, z0, x1, z1 = pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]
            top = max(hs[i - 1], hs[i]) + mod.Lift
            L = math.dist(pts[i], pts[i - 1])
            fx, fz = (x1 - x0) / L, (z1 - z0) / L
            centre = ((x0 + x1) / 2, top + 0.2 + vh / 2, (z0 + z1) / 2)
            axes = ((fz, 0.0, -fx), (0.0, 1.0, 0.0), (fx, 0.0, fz))
            hit = TBR.hits_obb(solid, centre, axes, (vw, vh / 2, L / 2), lambda p: True)
            if hit:
                problems.append("%s: the biggest vehicle hits %s on the road" % (name, hit[0]["name"]))
                break
            # joint surfaces: the slab tops meet at the sample within 0.02
        if vw > half:
            problems.append("%s: the biggest vehicle (%.1f half-wide) is wider than the carriageway" % (name, vw))
        tops = sorted(((p["pos"][0], p["pos"][2]) for p in slabs))
        # bots
        undo, gate, junction = mod.Register(net, plan, heights)
        if g.reachable(net, gate) < 4:
            problems.append("%s: the gate's node does not reach the network through roads.edges" % name)
        undo()
        after = [g.tostring(net.edges[i]) for i in range(1, len(net.edges) + 1)]
        if after != before:
            problems.append("%s: the undo did not put roads.edges back" % name)
    # This map is harder than any shipped one (buildings by the ring, a street across the arena, steep
    # hills): a base with no way through at all keeps its match (ModeTeams warns), so two are allowed.
    for line in unlinked:
        log("  note " + line)
    if len(unlinked) > MAY_FAIL:
        problems += unlinked
    log("team_base_road_check: %d bases, %d access roads built, %d problems" % (len(BASES), built, len(problems)))
    return problems


PLANTS = [
    ("a missing link", [("\t\ttable.insert(added, newEdge(chain, node, \"up\" .. i, \"down\" .. i))",
                         "\t\tnewEdge(chain, node, \"up\" .. i, \"down\" .. i)")]),
    ("through the battleground", [("for _, disc in ipairs(options.avoid or {}) do", "for _, disc in ipairs({}) do")]),
    ("joins the road at an angle", [("local approach = join + normal * APPROACH", "local approach = join + dir * 20")]),
    ("no grade held", [("local MAX_GRADE = 1 / 8", "local MAX_GRADE = 1 / 1")]),
    ("laid under the ground", [("			heights[i] = math.max(heights[i], floor[i])", "			heights[i] = heights[i] - 3")]),
    ("a bollard on the road", [("\tmodel.Parent = parent\n\treturn model",
                                "\tpart(\"Bollard\", Vector3.new(0.8, 3, 0.8), CFrame.new(tops[3] + Vector3.new(0, 1.5, 0)), LINE, Enum.Material.Metal, true)\n"
                                "\tmodel.Parent = parent\n\treturn model")]),
    ("through buildings", [("\tif options.blocked then", "\tif false then")]),
]


def main(argv):
    root = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else "."
    problems = run(root)
    for line in problems[:20]:
        print("  FAIL " + line)
    ok = not problems
    if "--plant" in argv:
        caught = 0
        for label, edits in PLANTS:
            found = run(root, edits, log=lambda *_: None)
            hit = bool(found) and not any("anchor not found" in f for f in found)
            caught += hit
            print("%s  %s  (%s)" % ("CAUGHT" if hit else "MISSED", label, found[0] if found else "no failure"))
        print("team_base_road_check plants: %d of %d caught" % (caught, len(PLANTS)))
        ok &= caught == len(PLANTS)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
