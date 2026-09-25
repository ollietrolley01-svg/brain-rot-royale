"""Where team-mode bodies spawn, checked without Studio (Oliver, 2026-09-24: "make players and bots spawn
inside the bases", and "the bases need to be bigger to accommodate all the players of each team").

Builds BOTH teams' compounds from the REAL ServerScriptService/Modules/TeamBaseRuins.lua (through
tools/team_base_ruins_check.py's runtime: team 1's facing team 2's, 700 studs apart, the same seed, as
ModeTeams builds them), then runs the REAL ModeTeams placement -- PickPad, ClearSpotNear and PlaceAt, the
one path GameMode's `place` sends every player and every bot through, at match start and on every
respawn -- over the compounds' own pads, with bodies standing where they were put. Per seed:

  * a full server: 25 a side placed one after another (the opening spawns), then 300 deaths and
    respawns, with enemies pushing into the base now and then (so PickPad refuses pads near them and
    falls back to the least bad one);
  * every placement lands INSIDE its own team's compound (inside the perimeter's inner faces, in that
    base's own frame), on one of that compound's pads;
  * on a walkable floor (a queryable top right under the feet, at the pad's height) with room for a
    body (2 wide, 5.2 tall: nothing solid in it), out of every vehicle bay;
  * nobody on top of anybody: at least SPREAD from every other living body while any pad is free, and
    the 25 opening spawns on 25 different pads;
  * spawn protection granted every time (ModeTeams' grantProtection with the mode's seconds);
  * at least 25 pads a side.

Planted faults (source edits) must each be caught:
    python3 tools/team_base_spawn_check.py [repo]            the checks
    python3 tools/team_base_spawn_check.py [repo] --plant    and the planted faults
"""

import math
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_base_ruins_check as TBR  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

TEAM_SIZE = 25
SPREAD = 3.0
SEEDS = range(1, 9)
RESPAWNS = 300
APART = 700.0

HARNESS = r"""
local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    return V[k]
end
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b) return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }
CFrame = { lookAt = function(at) return { Position = at } end }
function table.clone(t) local out = {} for k, v in pairs(t) do out[k] = v end return out end
workspace = {}
H = { bodies = {}, protected = {} }
Combatants = {
    All = function() local out = {} for body in pairs(H.bodies) do out[body] = true end return out end,
    GetCharacter = function(token) return token end,
}
function newBody()
    local body = { Parent = workspace, health = 100, root = { Position = Vector3.new(0, 500, 0) } }
    function body:FindFirstChildOfClass() return { Health = self.health } end
    function body:FindFirstChild(name) if name == "HumanoidRootPart" then return self.root end end
    function body:PivotTo(cf) self.root.Position = cf.Position end
    function body:SetAttribute() end
    H.bodies[body] = true
    return body
end
function grantProtection(token, seconds) H.protected[token] = seconds end
function terrainAt(x, z) return 0 end
function blocked() return false end
ENEMY_CLEARANCE = 90
function enemySees() return false end
ModeTeams = {}
teamOf, downed, pads, ruins = {}, {}, { {}, {} }, {}
arenaCentre = Vector3.new(0, 0, -350)
mode = { spawnProtection = 3 }
function ModeTeams.Assign(token) return teamOf[token] end
"""


def luau_to_lua(text):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+-])= (.+)$", r"\1\2 = \2 \3 \4", text, flags=re.M)


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]


def placement_source(modeteams):
    return "\n".join([
        between(modeteams, "function ModeTeams.PickPad", "-- Ground of last resort"),
        between(modeteams, "local SPAWN_CLEARANCE", "-- Places a body when its team has NO PADS AT ALL"),
        between(modeteams, "function ModeTeams.PlaceAt", "-- Marks a combatant down"),
    ]).replace("--------------------------------------------------------------------------------", "")


def to_local(point, origin, yaw):
    dx, dz = point[0] - origin[0], point[2] - origin[2]
    c, s = math.cos(yaw), math.sin(yaw)
    # the inverse of a turn by `yaw` about Y
    return (c * dx - s * dz, point[1] - origin[1], s * dx + c * dz)


def build_bases(src, seed):
    bases = []
    for team, (origin, yaw, colour) in enumerate((((0.0, 0.0, 0.0), 0.0, TBR.TEAM1), ((0.0, 0.0, -APART), math.pi, TBR.TEAM2)), 1):
        build = TBR.Build(src)
        frame, model, info = build.layout(origin[0], origin[1], origin[2], yaw, colour, seed)
        parts = build.dump(model)
        for p in parts:
            p["aabb"] = TBR.aabb(p)
        pads = [tuple(c[:3]) for c in build.cfs(info["pads"])]
        bays = build.cfs(info["localBays"])
        bases.append({"team": team, "origin": origin, "yaw": yaw, "parts": parts, "pads": pads, "bays": bays})
    return bases


def check_spot(base, point, wx, wz):
    """Problems with a body put at `point` (world, the feet) for `base`'s team."""
    problems = []
    lx, ly, lz = to_local(point, base["origin"], base["yaw"])
    if abs(lx) > wx - 0.8 or abs(lz) > wz - 0.8:
        problems.append("outside its compound (local %.1f, %.1f)" % (lx, lz))
        return problems
    parts = base["parts"]
    # The parts were dumped in the world frame the base was laid out in.
    x, y, z = point
    floor = TBR.top_under(parts, x, z, y + 4, lambda p: p["query"])
    if floor is None or abs(floor - y) > 0.3:
        problems.append("no floor under the feet (local %.1f, %.1f: floor %s, feet %.2f)" % (lx, lz, floor, y))
    inside = TBR.hits_box(parts, (x - 1.0, y + 0.25, z - 1.0), (x + 1.0, y + 5.2, z + 1.0), lambda p: p["collide"])
    if inside:
        problems.append("inside %s (local %.1f, %.1f)" % (inside[0]["name"], lx, lz))
    for b in base["bays"]:
        dx, dz = lx - b[0], lz - b[2]
        if abs(dx * b[3] + dz * b[5]) < 5.5 and abs(dx * b[9] + dz * b[11]) < 9.8:
            problems.append("in a vehicle bay (local %.1f, %.1f)" % (lx, lz))
    return problems


def run(root, edits=None, seeds=SEEDS, log=print):
    base_root = Path(root)
    src = TBR.sources(root)
    modeteams = (base_root / "ServerScriptService/Modules/ModeTeams.lua").read_text(encoding="utf-8")
    for rel, old, new in edits or []:
        if rel.endswith("TeamBaseRuins.lua"):
            if old not in src["ruins"]:
                return ["plant anchor not found: " + old[:50]]
            src = dict(src)
            src["ruins"] = src["ruins"].replace(old, new, 1)
        else:
            if old not in modeteams:
                return ["plant anchor not found: " + old[:50]]
            modeteams = modeteams.replace(old, new, 1)
    ruins = src["ruins"]
    wx, wz = (float(v) for v in re.search(r"local WX, WZ = ([\d.]+), ([\d.]+)", ruins).groups())
    code = luau_to_lua(placement_source(modeteams))
    problems = []
    placed_total = 0
    for seed in seeds:
        try:
            bases = build_bases(src, seed)
        except Exception as error:  # a crash is a failure
            return ["seed %d: the compounds did not build: %s" % (seed, str(error).splitlines()[0])]
        for base in bases:
            if len(base["pads"]) < TEAM_SIZE:
                problems.append("seed %d: team %d has %d pads, fewer than a full side of %d" % (seed, base["team"], len(base["pads"]), TEAM_SIZE))
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HARNESS)
        g = lua.globals()
        for base in bases:
            g.pads[base["team"]] = lua.table_from([g.Vector3.new(*p) for p in base["pads"]])
            g.ruins[base["team"]] = lua.table_from({"model": True})
        lua.execute(code)
        rng = random.Random(seed)
        bodies = []
        order = [1, 2] * TEAM_SIZE
        rng.shuffle(order)

        def place(body, team, when):
            nonlocal placed_total
            ok, _, where = g.ModeTeams.PlaceAt(body, body, None, True)
            placed_total += 1
            if not ok or where is None:
                problems.append("seed %d %s: team %d body was not placed" % (seed, when, team))
                return None
            feet = (where.X, where.Y - 4, where.Z)
            for line in check_spot(bases[team - 1], feet, wx, wz):
                problems.append("seed %d %s: team %d spawned %s" % (seed, when, team, line))
            if not g.H.protected[body] or g.H.protected[body] <= 0:
                problems.append("seed %d %s: team %d spawned without spawn protection" % (seed, when, team))
            return feet

        def spread_problem(body, feet, team, when):
            # Only while a pad of this team is free of every other body.
            others = [b for b in bodies if b["body"] is not body and b["body"].health > 0]
            free = any(all(math.dist(p, (o["body"].root.Position.X, o["body"].root.Position.Y - 4, o["body"].root.Position.Z)) >= SPREAD
                           for o in others) for p in bases[team - 1]["pads"])
            if not free:
                return
            for o in others:
                q = o["body"].root.Position
                if math.hypot(q.X - feet[0], q.Z - feet[2]) < SPREAD and abs(q.Y - 4 - feet[1]) < 3:
                    problems.append("seed %d %s: team %d spawned on top of somebody (%.1f apart)" % (seed, when, team, math.hypot(q.X - feet[0], q.Z - feet[2])))
                    return

        opening = {1: set(), 2: set()}
        for team in order:
            body = g.newBody()
            g.teamOf[body] = team
            entry = {"body": body, "team": team}
            bodies.append(entry)
            feet = place(body, team, "opening")
            if feet:
                opening[team].add((round(feet[0], 2), round(feet[2], 2)))
                spread_problem(body, feet, team, "opening")
        for team in (1, 2):
            if len(opening[team]) < TEAM_SIZE:
                problems.append("seed %d: team %d's %d opening spawns used only %d pads" % (seed, team, TEAM_SIZE, len(opening[team])))
        for event in range(RESPAWNS):
            entry = rng.choice(bodies)
            body, team = entry["body"], entry["team"]
            body.health = 0
            # Now and then the enemy pushes into this team's compound, so pads near them are refused.
            if rng.random() < 0.3:
                enemies = [b for b in bodies if b["team"] != team and b["body"].health > 0]
                base = bases[team - 1]
                for enemy in rng.sample(enemies, min(len(enemies), rng.randint(1, 4))):
                    lx, lz = rng.uniform(-wx + 4, wx - 4), rng.uniform(-wz + 4, 10)
                    c, s = math.cos(base["yaw"]), math.sin(base["yaw"])
                    x = base["origin"][0] + c * lx + s * lz
                    z = base["origin"][2] - s * lx + c * lz
                    enemy["body"].root.Position = g.Vector3.new(x, 4.3, z)
            body.health = 100
            g.H.protected[body] = None
            feet = place(body, team, "respawn %d" % (event + 1))
            if feet:
                spread_problem(body, feet, team, "respawn %d" % (event + 1))
        if problems and edits:
            break
    log("team_base_spawn_check: %d seeds, %d placements (%d a side at the start, %d respawns a seed), %d problems"
        % (len(list(seeds)), placed_total, TEAM_SIZE, RESPAWNS, len(problems)))
    return problems


PLANTS = [
    ("respawns ring out of the compound", [("ModeTeams.lua", "if inCompound and others and #others > 0 then", "if false then")]),
    ("a busy pad counts as free", [("ModeTeams.lua", "local PAD_CLEARANCE = 3.5", "local PAD_CLEARANCE = 0")]),
    ("pads for half a side", [("TeamBaseRuins.lua", "local PAD_Z = { 30, 36.5, 43, 49.5 }", "local PAD_Z = { 30, 36.5 }")]),
    ("a pad column in the wall", [("TeamBaseRuins.lua", "local PAD_X = { -60.5,", "local PAD_X = { -63.9,")]),
    ("placed on the enemy's pads", [("ModeTeams.lua", "local pad, _, leastBad = ModeTeams.PickPad(team, extra)",
                                     "local pad, _, leastBad = ModeTeams.PickPad(3 - team, extra)")]),
    ("spawn protection dropped", [("ModeTeams.lua", "\tpad = ModeTeams.ClearSpotNear(pad, character, ruins[team] and pads[team] or nil, ruins[team] ~= nil)\n"
                                   "\tlocal position = pad + Vector3.new(0, 4, 0)\n"
                                   "\tcharacter:PivotTo(CFrame.lookAt(position, Vector3.new(arenaCentre.X, position.Y, arenaCentre.Z)))\n"
                                   "\tcharacter:SetAttribute(\"Team\", team)\n"
                                   "\tdowned[token] = nil\n"
                                   "\tgrantProtection(token, mode and mode.spawnProtection or 0)",
                                   "\tpad = ModeTeams.ClearSpotNear(pad, character, ruins[team] and pads[team] or nil, ruins[team] ~= nil)\n"
                                   "\tlocal position = pad + Vector3.new(0, 4, 0)\n"
                                   "\tcharacter:PivotTo(CFrame.lookAt(position, Vector3.new(arenaCentre.X, position.Y, arenaCentre.Z)))\n"
                                   "\tcharacter:SetAttribute(\"Team\", team)\n"
                                   "\tdowned[token] = nil\n"
                                   "\tgrantProtection(token, 0)")]),
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
            found = run(root, [(("ServerScriptService/Modules/" + f), a, b) for f, a, b in edits], seeds=range(1, 3), log=lambda *_: None)
            hit = bool(found) and not any("anchor not found" in f for f in found)
            caught += hit
            print("%s  %s  (%s)" % ("CAUGHT" if hit else "MISSED", label, found[0] if found else "no failure"))
        print("team_base_spawn_check plants: %d of %d caught" % (caught, len(PLANTS)))
        ok &= caught == len(PLANTS)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
