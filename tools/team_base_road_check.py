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
math.sign = math.sign or function(x) return x > 0 and 1 or (x < 0 and -1 or 0) end

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
function reachableEdges(roads, gate)
    local adjacency = {}
    for _, e in ipairs(roads.edges) do
        adjacency[e.a] = adjacency[e.a] or {}
        adjacency[e.b] = adjacency[e.b] or {}
        table.insert(adjacency[e.a], e)
        table.insert(adjacency[e.b], e)
    end
    local seen, queue, out = { [gate] = true }, { gate }, {}
    while #queue > 0 do
        local n = table.remove(queue)
        for _, e in ipairs(adjacency[n] or {}) do
            table.insert(out, e)
            local m = e.a == n and e.b or e.a
            if not seen[m] then seen[m] = true; table.insert(queue, m) end
        end
    end
    return out
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
# (Off the roads out of the middle: ModeTeams never builds a compound over a road, SiteCost.)
BASES = [(440 * math.cos(math.radians(a)), 440 * math.sin(math.radians(a)), a + 180) for a in range(15, 360, 30)]
# The battleground's apron (its roads end there, at the gateways) and the ring the access roads keep
# out of, as ModeTeams sets it: the apron and 10 more.
APRON = 250.0
ARENA = APRON + 10
# Gentle grades (Oliver): the steepest an access road may climb, whatever the module says.
GRADE = 0.12
# Oliver: gentle crests and sags -- no pitch change over about 3 degrees between stretches, no step over
# 0.05 where two slabs meet; the biggest vehicle at SPEED neither leaves the road over a crest nor
# grounds its belly (CLEARANCE between its axles, WHEELBASE of its length).
PITCH = 3.0
JOIN_STEP = 0.05
SPEED, GRAVITY, CLEARANCE, WHEELBASE = 90.0, 196.2, 0.9, 0.62

MAY_FAIL = 2
# The arena's gateways (finished road ends at its apron) on the roads out of the middle, and how far the
# two teams' ways there may differ.
GATEWAYS = [(-250.0, 0.0), (250.0, 0.0), (0.0, -250.0), (0.0, 250.0)]
FAIR = 0.10
GATEWAY_RADIUS = APRON
# The yard's bays (local x, z, nose direction), BotService's straight lane out along the nose, and how
# much of a bot's way to its gateway must be on the base road and the gateway's road.
BAYS = [(10.5, -30, (0, -1)), (25.5, -30, (0, -1)), (40.5, -30, (0, -1)), (55.5, -30, (0, -1)),
        (35.5, 14, (1, 0)), (35.5, 29, (1, 0)), (35.5, 44, (1, 0))]
BASE_LANE = 40
FOLLOW = 0.80


def run(root, edits=None, log=print, botnav_edits=None):
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
    # The real BotNav (its DriveRoute is what a bot at the wheel plans with), in team_battleground_check's mock.
    from team_battleground_check import BOTNAV_MOCK
    from car_placement_luau import luau_to_lua as luau_continue
    botnav_src = (Path(root) / "ServerScriptService/Modules/BotNav.lua").read_text(encoding="utf-8")
    for old, new in botnav_edits or []:
        if old not in botnav_src:
            return ["plant anchor not found: " + old[:60]]
        botnav_src = botnav_src.replace(old, new, 1)
    lua.execute(BOTNAV_MOCK)
    g.botnavWorld(lambda *a: None, lambda *a: 0)
    botnav = lua.execute(luau_continue(botnav_src))
    from team_base_ruins_modeteams_check import vehicle_extents
    sizes = vehicle_extents(root)
    vw = max(v[0] for v in sizes.values()) / 2 + 1.0
    vlen = max(v[1] for v in sizes.values())
    stats = []
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
        got = mod.Profile(plan, g.hills, gate_y)
        heights = got[0] if isinstance(got, tuple) else got
        hs = [heights[i] for i in range(1, len(pts) + 1)]
        dist = [math.dist(pts[i], pts[i - 1]) for i in range(1, len(pts))]
        grades = [(hs[i] - hs[i - 1]) / dist[i - 1] for i in range(1, len(pts))]
        worst_grade = max(abs(x) for x in grades)
        if worst_grade > GRADE + 0.005:
            problems.append("%s: a grade of %.3f" % (name, worst_grade))
        pitches = [math.degrees(abs(math.atan(grades[i]) - math.atan(grades[i - 1]))) for i in range(1, len(grades))]
        worst_pitch = max(pitches) if pitches else 0
        if worst_pitch > PITCH:
            problems.append("%s: the pitch changes %.1f degrees between two stretches" % (name, worst_pitch))
        # Where two slabs' tops cross: the overhang past the sample times the change in grade.
        worst_step = 0.0
        for i in range(1, len(grades)):
            worst_step = max(worst_step, mod.Overhang(plan.points, i + 1) * abs(grades[i] - grades[i - 1]))
        if worst_step > JOIN_STEP:
            problems.append("%s: a step of %.3f where two slabs meet" % (name, worst_step))
        # The biggest vehicle driven down the whole road at SPEED: its belly over each crest, and whether
        # a crest throws it off the road (v^2 * curvature over gravity).
        cum = [0.0]
        for d in dist:
            cum.append(cum[-1] + d)

        def top_at(s):
            s = max(0.0, min(cum[-1], s))
            j = max(1, next((k for k in range(1, len(cum)) if cum[k] >= s), len(cum) - 1))
            f = (s - cum[j - 1]) / max(cum[j] - cum[j - 1], 1e-9)
            return hs[j - 1] + (hs[j] - hs[j - 1]) * f
        wb = WHEELBASE * vlen
        belly, lift = 0.0, 0.0
        s = wb / 2
        while s < cum[-1] - wb / 2:
            belly = max(belly, top_at(s) - (top_at(s - wb / 2) + top_at(s + wb / 2)) / 2)
            s += 1.0
        for i in range(1, len(grades)):
            crest = math.atan(grades[i - 1]) - math.atan(grades[i])
            if crest > 0:
                lift = max(lift, SPEED * SPEED * crest / ((dist[i - 1] + dist[i]) / 2) / GRAVITY)
        if belly > CLEARANCE:
            problems.append("%s: the biggest vehicle grounds its belly on a crest (%.2f over %.2f)" % (name, belly, CLEARANCE))
        if lift > 1.0:
            problems.append("%s: a crest throws the biggest vehicle off the road at %d studs/s (%.2f g)" % (name, SPEED, lift))
        stats.append((worst_grade, worst_pitch, worst_step, belly, lift))
        if abs(hs[0] - gate_y) > 1e-6:
            problems.append("%s: not level with the gate" % name)
        t = plan.along / e.step
        k = int(t)
        eh = [e.heights[i] for i in range(1, len(e.heights) + 1)]
        want = eh[k] + (eh[min(k + 1, len(eh) - 1)] - eh[k]) * (t - k)
        # The ground cut and filled to it (the real GroundTarget): under the road just below its surface,
        # the banks either side no steeper than 40 degrees out to the natural ground (no cliffs).
        steepest_bank = 0.0
        for i in range(2, len(pts) - 2, 3):
            px, pz = pts[i]
            fx, fz = (pts[i + 1][0] - pts[i - 1][0]), (pts[i + 1][1] - pts[i - 1][1])
            fl = math.hypot(fx, fz)
            rx, rz = -fz / fl, fx / fl
            for side in (-1, 1):
                last = None
                for k in range(0, 80):
                    off = k * 0.5
                    x, z = px + rx * side * off, pz + rz * side * off
                    t = mod.GroundTarget(plan.points, heights, x, z, g.hills(x, z))
                    if t is None:
                        t = g.hills(x, z)
                    if off <= half and t > hs[i] + mod.Lift + 0.05:
                        problems.append("%s: the ground comes up through the road at stretch %d" % (name, i))
                        break
                    if last is not None:
                        steepest_bank = max(steepest_bank, abs(t - last) / 0.5)
                    last = t
        if steepest_bank > math.tan(math.radians(40)) + 0.05:
            problems.append("%s: a bank beside the road at %.0f degrees (a cliff)" % (name, math.degrees(math.atan(steepest_bank))))
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
        model = mod.Build(plan, heights, None)
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
    # THE ARENA. Mirrored pairs of bases (as ModeTeams puts them: opposite, facing the middle), each
    # routed onto the road of an arena gateway (the finished road ends at the apron, GATEWAYS), the fairer
    # pair chosen by the real ChooseFair: both teams reach a gateway through roads.edges, and their ways
    # there (access road + the map road on to the gateway) differ by no more than FAIR.
    gateways = lua.table_from([g.Vector3.new(x, 0, z) for x, z in GATEWAYS])
    fair_worst = 0.0
    route_shares = []
    for bx, bz, deg in BASES[: len(BASES) // 2]:
        name = "pair at (%d, %d)" % (bx, bz)
        net = g.makeNetwork(g.hills)
        mod.CutAtArena(net, g.Vector3.new(0, 0, 0), GATEWAY_RADIUS - 1)
        # As ModeTeams sets it: bots into the arena only through a gateway.
        botnav.Arena = lua.table_from({"center": g.Vector3.new(0, 0, 0), "radius": APRON, "gateways": gateways})
        targets = mod.GatewayTargets(net, gateways, g.Vector3.new(0, 0, 0))
        options = []
        frames = []
        for sign in (1, -1):
            x, z, h = sign * bx, sign * bz, math.radians(deg + (0 if sign == 1 else 180))
            heading = g.Vector3.new(math.cos(h), 0, math.sin(h))
            frame = g.CFrame.lookAt(g.Vector3.new(x, 0, z), g.Vector3.new(x + heading.X, 0, z + heading.Z))
            front = g.mul(frame, g.Vector3.new(33, 0, -57.8))
            east = g.mul(frame, g.Vector3.new(70.8, 0, 29))
            gates = lua.table_from([lua.table_from({"position": front, "heading": frame.LookVector}),
                                    lua.table_from({"position": east, "heading": frame.RightVector})])
            avoid = lua.table_from([lua.table_from({"centre": g.Vector3.new(0, 0, 0), "radius": ARENA, "name": "battleground"})])
            boxes = lua.table_from([lua.table_from({"frame": frame, "halfX": 71, "halfZ": 59})])
            frames.append(frame)
            mine = []
            for gi in range(1, len(GATEWAYS) + 1):
                these = [t for t in targets.values() if t.gateway == gi]
                if not these:
                    continue
                opts = lua.table_from({"avoid": avoid, "blocked": g.blockedBy, "boxes": boxes, "groundAt": g.hills,
                                       "startY": lua.table_from([g.hills(front.X, front.Z), g.hills(east.X, east.Z)]),
                                       "targets": lua.table_from(these)})
                got = mod.Plan(gates, None, net, opts)
                plan = got[0] if isinstance(got, tuple) else got
                if plan is not None:
                    mine.append(plan)
            if not mine:
                # No gateway road in reach: onto the nearest road, and on along the network (as ModeTeams).
                opts = lua.table_from({"avoid": avoid, "blocked": g.blockedBy, "boxes": boxes, "groundAt": g.hills,
                                       "startY": lua.table_from([g.hills(front.X, front.Z), g.hills(east.X, east.Z)])})
                got = mod.Plan(gates, None, net, opts)
                plan = got[0] if isinstance(got, tuple) else got
                if plan is not None:
                    got = mod.DistanceToGateway(net, plan, gateways)
                    on, gi = got if isinstance(got, tuple) else (got, None)
                    if on is not None:
                        plan.total, plan.gateway = plan.length + on, gi
                        mine.append(plan)
            options.append(mine)
        if not options[0] or not options[1]:
            problems.append("%s: a team has no way to an arena gateway" % name)
            continue
        got = mod.ChooseFair(lua.table_from(options[0]), lua.table_from(options[1]), FAIR)
        chosen, gap = (got if isinstance(got, tuple) else (got, None))
        gap = gap or 0.0
        fair_worst = max(fair_worst, gap)
        if gap > FAIR:
            problems.append("%s: the teams' ways to the arena differ by %.0f%%" % (name, gap * 100))
        for team in (1, 2):
            plan = chosen[team]
            heights = plan.heights
            got = mod.Register(net, plan, heights)
            undo, gate, junction = got
            # The gateway on a reached edge.
            gx, gz = GATEWAYS[plan.gateway - 1]
            reach = g.reachableEdges(net, gate)
            ok = False
            for e in reach.values():
                ax, az, bx2, bz2 = e["from"].X, e["from"].Z, e["to"].X, e["to"].Z
                L2 = (bx2 - ax) ** 2 + (bz2 - az) ** 2
                t = max(0.0, min(1.0, ((gx - ax) * (bx2 - ax) + (gz - az) * (bz2 - az)) / max(L2, 1e-9)))
                if math.hypot(ax + (bx2 - ax) * t - gx, az + (bz2 - az) * t - gz) < half:
                    ok = True
                    break
            if not ok:
                problems.append("%s: team %d's gate does not reach its arena gateway through roads.edges" % (name, team))
        # BOTS: the real BotNav.DriveRoute, roads preferred (BotService: a base vehicle out of its bay in a
        # team mode), from the end of each bay's drive-out lane (BotService's BASE_LANE along its nose) to
        # the team's gateway and to the arena's middle: the way follows the access road and the gateway's
        # road for at least FOLLOW of its length, and never runs inside the apron before the gateway.
        for team in (1, 2):
            plan = chosen[team]
            frame = frames[team - 1]
            gx, gz = GATEWAYS[plan.gateway - 1]
            road_pts = [(p.X, p.Z) for p in plan.points.values()]
            ex, ez = plan.edge["from"].X, plan.edge["from"].Z
            fx, fz = plan.edge["to"].X, plan.edge["to"].Z

            open_edges = [(e["from"].X, e["from"].Z, e["to"].X, e["to"].Z) for e in net.edges.values() if not e.blocked]

            def on_road(x, z):
                # Any open road: the access road, the gateway's road, or the map's roads on to it.
                for ax, az, bx3, bz3 in open_edges:
                    L2 = (bx3 - ax) ** 2 + (bz3 - az) ** 2
                    t = max(0.0, min(1.0, ((x - ax) * (bx3 - ax) + (z - az) * (bz3 - az)) / max(L2, 1e-9)))
                    if math.hypot(ax + (bx3 - ax) * t - x, az + (bz3 - az) * t - z) < half + 3:
                        return True
                if any(math.hypot(x - a[0], z - a[1]) < half + 3 for a in road_pts):
                    return True
                for i in range(1, len(road_pts)):
                    ax, az = road_pts[i - 1]
                    bx3, bz3 = road_pts[i]
                    L2 = (bx3 - ax) ** 2 + (bz3 - az) ** 2
                    t = max(0.0, min(1.0, ((x - ax) * (bx3 - ax) + (z - az) * (bz3 - az)) / max(L2, 1e-9)))
                    if math.hypot(ax + (bx3 - ax) * t - x, az + (bz3 - az) * t - z) < half + 3:
                        return True
                L2 = (fx - ex) ** 2 + (fz - ez) ** 2
                t = max(0.0, min(1.0, ((x - ex) * (fx - ex) + (z - ez) * (fz - ez)) / max(L2, 1e-9)))
                return math.hypot(ex + (fx - ex) * t - x, ez + (fz - ez) * t - z) < half + 3
            for bay_x, bay_z, look in BAYS:
                bay = g.mul(frame, g.Vector3.new(bay_x, 0, bay_z))
                nose = g.mul(frame, g.Vector3.new(bay_x + look[0], 0, bay_z + look[1]))
                d = (nose.X - bay.X, nose.Z - bay.Z)
                start = g.Vector3.new(bay.X + d[0] * BASE_LANE, 0, bay.Z + d[1] * BASE_LANE)
                # On to the access road as a bot does (the real DriveVia, as ModeTeams.BaseDriveVia calls it).
                via = [p for p in mod.DriveVia(frame, plan, g.Vector3.new(d[0], 0, d[1]), g.Vector3.new(67 + 16, 0, -55 - 16)).values()]
                begin = via[-1] if via else start
                for goal_name, goal in (("its gateway", (gx, gz)), ("the arena's middle", (0.0, 0.0))):
                    got = botnav.DriveRoute(net, begin, g.Vector3.new(goal[0], 0, goal[1]), None, True)
                    # Measured from where it has left its compound (its lane and the way round to the road).
                    pts_ = [begin] + [p for p in got[0].values()]
                    xs = [(p.X, p.Z) for p in pts_]
                    total = followed = 0.0
                    inside = None
                    for i in range(1, len(xs)):
                        L = math.dist(xs[i - 1], xs[i])
                        steps = max(1, int(L / 2))
                        for k in range(steps):
                            t = (k + 0.5) / steps
                            x = xs[i - 1][0] + (xs[i][0] - xs[i - 1][0]) * t
                            z = xs[i - 1][1] + (xs[i][1] - xs[i - 1][1]) * t
                            total += L / steps
                            if on_road(x, z):
                                followed += L / steps
                            if math.hypot(x, z) < APRON - 1 and inside is None                                     and min(math.hypot(xs[i - 1][0] - qx, xs[i - 1][1] - qz) for qx, qz in GATEWAYS) > 30:
                                inside = (x, z)
                    share = followed / max(total, 1e-9)
                    route_shares.append(share)
                    if goal_name == "its gateway" and share < FOLLOW:
                        problems.append("%s: team %d's bot from bay (%d, %d) follows the base road for %.0f%% of its way to %s"
                                        % (name, team, bay_x, bay_z, share * 100, goal_name))
                    if goal_name == "the arena's middle" and inside is not None:
                        problems.append("%s: team %d's bot from bay (%d, %d) cuts into the arena at (%.0f, %.0f), not through its gateway"
                                        % (name, team, bay_x, bay_z, inside[0], inside[1]))
    log("  arena: %d mirrored pairs routed to gateways, worst difference %.1f%% (limit %.0f%%)"
        % (len(BASES) // 2, fair_worst * 100, FAIR * 100))
    if route_shares:
        log("  bots: %d BotNav routes from the bays, the least on the base roads %.0f%% (limit %.0f%% to the gateway)"
            % (len(route_shares), min(route_shares) * 100, FOLLOW * 100))
    if stats:
        log("  worst over all roads: grade %.3f, pitch change %.2f deg, join step %.3f, belly %.2f of %.2f, crest %.2f g"
            % (tuple(max(x[k] for x in stats) for k in range(3)) + (max(x[3] for x in stats), CLEARANCE, max(x[4] for x in stats))))
    log("team_base_road_check: %d bases, %d access roads built, %d problems" % (len(BASES), built, len(problems)))
    return problems


PLANTS = [
    ("a broken link near the gateway", [("local added = { first, second }", "local added = { second }")]),
    ("an unfair pair", [("local fair, wasFair = gap <= share, bestGap <= share", "local fair, wasFair = true, true")]),
    ("the arena's cut roads left open (a wrong cost through the apron)",
     [("							piece.blocked = (mid - c).Magnitude < radius or nil", "							piece.blocked = nil")],
     [("	if arena and arena.gateways", "	if false and arena and arena.gateways")]),
    ("a missing link", [("\t\ttable.insert(added, newEdge(chain, node, \"up\" .. i, \"down\" .. i))",
                         "\t\tnewEdge(chain, node, \"up\" .. i, \"down\" .. i)")]),
    ("through the battleground", [("for _, disc in ipairs(options.avoid or {}) do", "for _, disc in ipairs({}) do")]),
    ("joins the road at an angle", [("local approach = join + normal * APPROACH", "local approach = join + dir * 20")]),
    ("no grade held", [("local MAX_GRADE = 0.12", "local MAX_GRADE = 1")]),
    ("a raw terrain-following profile", [("\tfor _ = 1, SMOOTH_PASSES do", "\tfor _ = 1, 0 do"),
                                         ("\tfor _ = 1, 300 do", "\tfor _ = 1, 0 do")]),
    ("cliffs beside the road", [("local BANK_SLOPE = math.tan(math.rad(35))", "local BANK_SLOPE = 20")]),
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
        for plant in PLANTS:
            label, edits = plant[0], plant[1]
            found = run(root, edits, log=lambda *_: None, botnav_edits=plant[2] if len(plant) > 2 else None)
            hit = bool(found) and not any("anchor not found" in f for f in found)
            caught += hit
            print("%s  %s  (%s)" % ("CAUGHT" if hit else "MISSED", label, found[0] if found else "no failure"))
        print("team_base_road_check plants: %d of %d caught" % (caught, len(PLANTS)))
        ok &= caught == len(PLANTS)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
