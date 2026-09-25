"""ModeTeams and King of the Hill with the central battleground (TeamBattleground), checked without Studio.

Runs the REAL ModeTeams source (the region tools/team_base_ruins_modeteams_check.py runs: State through
`-- END BASE VEHICLES`, which holds the BEGIN/END BATTLEGROUND block) in the mock world of
tools/team_vehicles_check.py, with TeamBaseRuins and TeamBattleground as stubs -- the battleground's
geometry is tools/team_battleground_check.py's business, this is only the wiring. Then the REAL
ModeKingOfTheHill, in tools/objective_zone_check.py's harness, handed a battleground. Measured:

  * a team match builds the battleground once, after the bases, at the arena's centre on the ground,
    facing team 1's base (its LookVector), from the same seed as the two compounds;
  * its loot is seeded once, and BotNav.CoverHints answers from its cover (TeamBattleground.CoverNear);
  * ModeTeams.Battleground() hands it over while the match runs, and nil after Teardown;
  * Teardown destroys it and clears the cover hints; a second Setup without a Teardown replaces it;
  * a Build that throws, or refuses (nil, why), costs the match its battleground and nothing else:
    the match still has pads for both teams, no hints are left pointing at nothing;
  * a mode without teams builds none;
  * King of the Hill puts its two objectives exactly on the battleground's, and falls back to its own
    sites when there is no battleground (or it gives fewer than two).
  * NOT IN BATTLE ROYALE (Oliver 2026-09-24: "make sure the team bases and battleground don't spawn in
    the battle royale games either"): a battle royale, then a team match, then a battle royale again
    on the same server -- neither battle royale has any of the battleground in the world, its gun
    emplacements included (a BR match runs ModeTeams.Setup, if anything ever does, with a mode that
    has no teams); and by source: only ModeTeams requires TeamBattleground, it builds it only for a
    mode with teams, GameMode's battle royale StartWorld never touches ModeTeams, and GameMode's
    stopWorld tears the team match down.

    python3 tools/team_battleground_modeteams_check.py .            the checks
    python3 tools/team_battleground_modeteams_check.py . --plant    and the planted faults
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from team_vehicles_check import PRELUDE, read, region, vehicle_models  # noqa: E402
from team_base_ruins_modeteams_check import STUB as RUIN_STUB, chest_stock, luau_to_lua  # noqa: E402
import objective_zone_check as OZ  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

STUB = r"""
local R = _R
-- The block requires its two modules by name; here each is the global of that name.
script = { Parent = { WaitForChild = function(_, name) return name end } }
require = function(name) return assert(_G[name], "unmocked require " .. tostring(name)) end
BotNav = {}
R.fields = {}
R.fieldMode = nil  -- nil: builds; "throw": Build errors; "refuse": Build returns nil, "river"
R.loots = 0
R.destroyed = 0
R.coverAsked = nil
TeamBattleground = {
    Build = function(frame, mapInfo, seed)
        table.insert(R.fields, { frame = frame, seed = seed, mapInfo = mapInfo })
        if R.fieldMode == "throw" then error("the ground gave way") end
        if R.fieldMode == "refuse" then return nil, "river" end
        local model = R.newInst("Model", "TeamBattleground")
        model.Parent = mapInfo.map
        -- One of its gun emplacements, as the real one carries (inside the model: it goes with it).
        local gun = R.newInst("Part", "GunEmplacement")
        gun.Parent = model
        local function at(x, y, z) return (frame * CFrame.new(Vector3.new(x, y, z))).p end
        local info = { model = model, objectives = { at(0, 0.8, 0), at(-84, 0.3, 0) }, cover = { at(10, 0, 0) } }
        R.lastField = info
        return info
    end,
    SeedLoot = function(info)
        R.loots = R.loots + 1
        R.lootedField = info
    end,
    CoverNear = function(info, origin, radius)
        R.coverAsked = { info = info, origin = origin, radius = radius }
        return info.cover
    end,
    Destroy = function(info)
        R.destroyed = R.destroyed + 1
        info.model:Destroy()
    end,
}
"""

CHECKS = r"""
local R, M = _R, ModeTeams
local out = {}
local function fail(msg) table.insert(out, msg) end
local map = R.newInst("Model", "Map")
map.Parent = workspace
-- An arena centre off the origin, so a frame built at the origin (or at a base) shows.
local centre = Vector3.new(40, 0, -25)
local info = { dropSpots = { centre }, radius = 900, map = map }
R.clock = 1000000
M.Setup({ id = "TeamDeathmatch", teams = true }, info)
if #R.builds ~= 2 then fail("compounds built: " .. #R.builds) end
if #R.fields ~= 1 then fail("battlegrounds built: " .. #R.fields) return out end
local built = R.fields[1]
if built.seed == nil or built.seed ~= R.builds[1].seed then fail("the battleground did not get the compounds' seed") end
if built.mapInfo ~= info then fail("the battleground was not given the match's map") end
local p = built.frame.p
if R.flat(p, centre) > 1e-6 then fail(("battleground at (%.1f, %.1f), arena centre (%.1f, %.1f)"):format(p.X, p.Z, centre.X, centre.Z)) end
if math.abs(p.Y - 10) > 1e-6 then fail("battleground frame not on the ground: y " .. p.Y) end
local base1, base2 = M.BaseOf(1), M.BaseOf(2)
local look = built.frame.LookVector
local to1 = base1 - centre
local len = math.sqrt(to1.X * to1.X + to1.Z * to1.Z)
if (look.X * to1.X + look.Z * to1.Z) / len < 0.9999 then fail("the battleground does not face team 1's base") end
-- Mirror plane through the centre, square to the axis: the two bases must be equally far from it.
local d1 = (base1 - centre).Magnitude
local d2 = (base2 - centre).Magnitude
if math.abs(d1 - d2) > 1e-6 then fail("the bases are not equally far from the battleground") end
if M.Battleground() ~= R.lastField then fail("ModeTeams.Battleground() is not what was built") end
if R.loots ~= 1 or R.lootedField ~= R.lastField then fail("battleground loot seeded " .. R.loots .. " times") end
if type(BotNav.CoverHints) ~= "function" then fail("BotNav.CoverHints not set") else
    local answer = BotNav.CoverHints(Vector3.new(1, 2, 3), 20)
    if answer ~= R.lastField.cover or not R.coverAsked or R.coverAsked.info ~= R.lastField or R.coverAsked.radius ~= 20 then
        fail("BotNav.CoverHints does not answer from TeamBattleground.CoverNear")
    end
end
-- A second Setup with no Teardown between: the old one comes down first.
local first = R.lastField
M.Setup({ id = "TeamDeathmatch", teams = true }, info)
if first.model.Parent then fail("a second Setup left the first battleground standing") end
if #R.fields ~= 2 then fail("second Setup: " .. #R.fields .. " builds in all") end
-- Teardown: gone, and the hints with it.
local last = R.lastField
M.Teardown()
if last.model.Parent then fail("the battleground survived Teardown") end
if BotNav.CoverHints ~= nil then fail("BotNav.CoverHints still set after Teardown") end
if M.Battleground() ~= nil then fail("ModeTeams.Battleground() answers after Teardown") end
local count = 0
for _, child in ipairs(map:GetChildren()) do if child.Name == "TeamBattleground" then count = count + 1 end end
if count ~= 0 then fail(count .. " battleground models left in the map") end

-- Build throws, then refuses: the match starts anyway, with pads, and no hints.
for _, how in ipairs({ "throw", "refuse" }) do
    R.fieldMode = how
    local warned = R.warnings
    local okSetup, err = pcall(M.Setup, { id = "TeamDeathmatch", teams = true }, info)
    R.fieldMode = nil
    if not okSetup then fail("Setup crashed when Build did '" .. how .. "': " .. tostring(err))
    else
        if M.Battleground() ~= nil then fail("a battleground is reported after Build did '" .. how .. "'") end
        if BotNav.CoverHints ~= nil then fail("cover hints set after Build did '" .. how .. "'") end
        if #M.BasePads(1) == 0 or #M.BasePads(2) == 0 then fail("no pads after Build did '" .. how .. "'") end
        if R.warnings == warned then fail("nothing warned when Build did '" .. how .. "'") end
    end
    M.Teardown()
end

-- No teams, no battleground.
local before = #R.fields
M.Setup({ id = "Other", teams = false }, info)
if #R.fields ~= before then fail("a battleground built in a mode without teams") end
if M.Battleground() ~= nil then fail("a battleground reported in a mode without teams") end
M.Teardown()
return out
"""

BR_CHECKS = r"""
local R, M = _R, ModeTeams
local out = {}
local function fail(msg) table.insert(out, msg) end
local map = R.newInst("Model", "Map")
map.Parent = workspace
local info = { dropSpots = { Vector3.new(-30, 0, 60) }, radius = 900, map = map }
-- Anything of the battleground left anywhere in the world: the model, or a gun emplacement.
local function leftovers(label)
    local found = {}
    local function walk(node)
        for _, child in ipairs(node:GetChildren()) do
            if child.Name == "TeamBattleground" or child.Name == "GunEmplacement" then table.insert(found, child.Name) end
            walk(child)
        end
    end
    walk(workspace)
    if #found > 0 then fail(label .. ": " .. #found .. " battleground pieces in the world (" .. found[1] .. ")") end
    if M.Battleground() ~= nil then fail(label .. ": ModeTeams.Battleground() answers") end
end
-- A battle royale: GameMode.BattleRoyale's StartWorld only starts the storm, so ModeTeams is not
-- called at all -- and were it ever, it would be with a mode with no teams.
local function battleRoyale(label)
    local before = #R.fields
    leftovers(label .. " (before)")
    M.Setup({ id = "BattleRoyale", teams = false }, info)
    leftovers(label)
    if #R.fields ~= before then fail(label .. ": a battleground was built") end
    M.Teardown()
end
M.Teardown()
battleRoyale("the first battle royale")
M.Setup({ id = "TeamDeathmatch", teams = true }, info)
local field = M.Battleground()
if not (field and field.model and field.model.Parent) then fail("the team match between them has no battleground") end
-- GameMode's stopWorld: ModeTeams.Teardown (asserted by source below).
M.Teardown()
battleRoyale("the battle royale after a team match")
return out
"""


def isolation(root, overrides=None):
    """The battleground only ever comes from a team mode, read off the sources."""
    overrides = overrides or {}
    base = Path(root) / "ServerScriptService"

    def text(rel):
        return overrides.get(rel) or (Path(root) / rel).read_text(encoding="utf-8")
    fails = []
    for path in sorted(base.rglob("*.lua")):
        rel = path.relative_to(root).as_posix()
        if rel.endswith("/ModeTeams.lua") or rel.endswith("/TeamBattleground.lua"):
            continue
        src = text(rel)
        if re.search(r"require\([^)]*TeamBattleground", src) or re.search(r"TeamBattleground\.(Build|Layout)\(", src):
            fails.append("%s builds or requires TeamBattleground (only ModeTeams may)" % rel)
    for rel in overrides:
        if rel not in {path.relative_to(root).as_posix() for path in base.rglob("*.lua")}:
            fails.append("override for a file that is not there: " + rel)
    mt = text("ServerScriptService/Modules/ModeTeams.lua")
    if "local withRuins = TeamBaseRuins ~= nil and currentMode ~= nil and currentMode.teams == true" not in mt:
        fails.append("ModeTeams: the compounds and battleground no longer hang on the mode having teams")
    calls = [m.start() for m in re.finditer(r"(?<!function )ModeTeams\.BuildBattleground\(", mt)]
    guarded = [c for c in calls if mt.rfind("\tif withRuins then\n", 0, c) > mt.rfind("\n\tend\n", 0, c)]
    if len(calls) != 1 or len(guarded) != 1:
        fails.append("ModeTeams: BuildBattleground called %d times, %d of them under `if withRuins`" % (len(calls), len(guarded)))
    gm = text("ServerScriptService/Modules/GameMode.lua")
    a = gm.find("GameMode.BattleRoyale = setmetatable({")
    b = gm.find("}, { __index = GameModes.Modes.BattleRoyale })", a)
    if a < 0 or b < 0:
        fails.append("GameMode: the battle royale's behaviour table is not where it was")
    elif re.search(r"ModeTeams|Battleground|TeamBaseRuins", gm[a:b]):
        fails.append("GameMode: the battle royale's StartWorld/StopWorld touch ModeTeams")
    a = gm.find("local function stopWorld()")
    b = gm.find("\nend\n", a)
    if a < 0 or "ModeTeams.Teardown()" not in gm[a:b]:
        fails.append("GameMode: stopWorld does not tear the team match down (ModeTeams.Teardown)")
    return fails


STATIC_PLANTS = [
    ("the battle royale builds the arena", "ServerScriptService/Modules/GameMode.lua",
     "\tStartWorld = function(mapInfo)\n\t\tStormService.Start(mapInfo.radius)\n",
     "\tStartWorld = function(mapInfo)\n\t\tStormService.Start(mapInfo.radius)\n\t\tModeTeams.BuildBattleground(mapInfo, 0, 1)\n"),
    ("stopWorld leaves the arena up", "ServerScriptService/Modules/GameMode.lua",
     "\tModeTeams.Teardown()\n\tStormService.Stop()\n", "\tStormService.Stop()\n"),
    ("shared map generation builds it", "ServerScriptService/Modules/MapGenerator.lua",
     "\n", '\nlocal TeamBattleground = require(script.Parent:WaitForChild("TeamBattleground"))\n'),
]

PLANTS = [
    ("hook removed from Setup", ("\t\tModeTeams.BuildBattleground(mapInfo, axis, ruinSeed)", "\t\tlocal _ = 0")),
    ("a seed of its own", ("\t\tModeTeams.BuildBattleground(mapInfo, axis, ruinSeed)",
                           "\t\tModeTeams.BuildBattleground(mapInfo, axis, math.random(1, 2147483646))")),
    ("faces team 2", ("CFrame.lookAt(at, at + toTeamOne)", "CFrame.lookAt(at, at - toTeamOne)")),
    ("built at the origin", ("local at = Vector3.new(arenaCentre.X, terrainAt(arenaCentre.X, arenaCentre.Z) or 0, arenaCentre.Z)",
                             "local at = Vector3.new(0, terrainAt(0, 0) or 0, 0)")),
    ("built below the ground", ("local at = Vector3.new(arenaCentre.X, terrainAt(arenaCentre.X, arenaCentre.Z) or 0, arenaCentre.Z)",
                                "local at = Vector3.new(arenaCentre.X, 0, arenaCentre.Z)")),
    ("not torn down", ("\tModeTeams.ClearBattleground()\n\tModeTeams.ClearRuins()", "\tModeTeams.ClearRuins()")),
    ("hints left after teardown", ("\tif BotNav then\n\t\tBotNav.CoverHints = nil", "\tif false then\n\t\tBotNav.CoverHints = nil")),
    ("no hints", ("\t\tBotNav.CoverHints = function(origin, radius)", "\t\tlocal _ = function(origin, radius)")),
    ("unguarded build", ("local ok, built, why = pcall(TeamBattleground.Build, CFrame.lookAt(at, at + toTeamOne), mapInfo, seed)",
                         "local ok, built, why = true, TeamBattleground.Build(CFrame.lookAt(at, at + toTeamOne), mapInfo, seed)")),
    ("no loot", ("local seeded, problem = pcall(TeamBattleground.SeedLoot, built)", "local seeded, problem = true, nil")),
    # (Setup calls Teardown first and BuildBattleground wants a seed, which a mode without teams
    # never has: planting "reported after the match", "old one left on re-Setup" or "built without
    # teams" alone changes nothing, the other guard holds. These two have no second guard.)
    ("refusal not warned", ('warn("ModeTeams: no battleground: "', '(function() end)("ModeTeams: no battleground: "')),
    ("Clear forgets to destroy", ("\t\tTeamBattleground.Destroy(battleground)\n", "\n")),
    ("built in a battle royale too", ("\tif withRuins then\n\t\tModeTeams.BuildBattleground(mapInfo, axis, ruinSeed)",
                                      "\tif true then\n\t\tModeTeams.BuildBattleground(mapInfo, axis, ruinSeed or 1)")),
]


def run(root, plant=None, seeds=6):
    models, mounts, pick = vehicle_models(root)
    body = region(root)
    if plant:
        old, new = plant
        if old not in body:
            return ["plant anchor not found: " + old[:60]]
        body = body.replace(old, new, 1)
    config_src = luau_to_lua(read(root, "ReplicatedStorage", "Shared", "MatchConfig.lua"))
    failures = []
    for seed in range(1, seeds + 1):
        lua = LuaRuntime(unpack_returned_tuples=True)
        R = lua.eval("{}")
        R.models = lua.table_from([lua.table_from(list(m[:2]) + [int(m[2])]) for m in models])
        R.mounts = lua.table_from(mounts)
        # The compound stub needs the chest stock; without it every compound failed to build, which
        # this check never noticed until ModeTeams began retrying other sites (it counts the builds).
        R.chestStock = chest_stock(root)
        lua.execute("math.randomseed(%d)" % seed)
        lua.globals()._R = R
        lua.execute(PRELUDE.replace("local R = ...", "local R = _R"))
        lua.execute("MatchConfig = (function() " + config_src + " end)()")
        lua.execute("VehicleModels.Pick = (function() local VehicleModels = VehicleModels\n" + luau_to_lua(pick)
                    + "\nreturn VehicleModels.Pick end)()")
        lua.execute("function protectionNowMs() return _R.clock end")
        lua.execute(RUIN_STUB)
        lua.execute(STUB)
        chunk = ("local ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain, TeamBaseRuins, Combatants = "
                 "ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain, TeamBaseRuins, Combatants\n"
                 + luau_to_lua(body))
        try:
            lua.execute(chunk)
            checks = list(lua.execute(CHECKS).values())
            checks += list(lua.execute(BR_CHECKS).values())
        except Exception as error:  # a crash is a failure, never a pass
            checks = ["crashed: %s" % str(error).splitlines()[0]]
        failures += ["seed %d: %s" % (seed, line) for line in checks]
        if failures and plant:
            break
    return failures


# King of the Hill, in objective_zone_check's harness: its ModeTeams mock hands over a battleground.
KOTH_A, KOTH_B = (37.0, 10.8, -21.0), (-47.0, 10.3, 5.0)


def koth_harness(objectives):
    rows = ", ".join("vec(%r, %r, %r)" % p for p in objectives)
    mock = ("local ModeTeams = {\n    Battleground = function() return { objectives = { %s } } end,\n" % rows)
    harness = OZ.HARNESS.replace("local ModeTeams = {\n", mock, 1)
    assert harness != OZ.HARNESS
    return harness


def koth_run(koth_src, objectives):
    zone = OZ.luau_to_lua(OZ.read(ROOT, "ReplicatedStorage", "Shared", "ObjectiveZone.lua"))
    lua = LuaRuntime(unpack_returned_tuples=True)
    out = lua.execute(koth_harness(objectives), zone, OZ.luau_to_lua(koth_src), 0)
    return [tuple(r["centre"].values()) for r in out["rings"].values()]


def koth_checks(koth_src):
    failures = []
    got = koth_run(koth_src, [KOTH_A, KOTH_B])
    want = [KOTH_A, KOTH_B]
    if len(got) != 2 or any(max(abs(a - b) for a, b in zip(g, w)) > 1e-9 for g, w in zip(got, want)):
        failures.append("KOTH objectives %s, battleground's %s" % (got, want))
    # Fewer than two from the battleground: KOTH picks its own two sites.
    got = koth_run(koth_src, [KOTH_A])
    if len(got) != 2 or any(max(abs(a - b) for a, b in zip(g, KOTH_A)) < 1e-9 for g in got):
        failures.append("KOTH with one battleground objective: %s" % (got,))
    got = koth_run(koth_src, [])
    if len(got) != 2:
        failures.append("KOTH with no battleground objectives: %d built" % len(got))
    return failures


KOTH_PLANTS = [
    ("KOTH ignores the battleground", ("if battleground and battleground.objectives and #battleground.objectives >= 2 then",
                                       "if false then")),
    ("KOTH flattens the objectives to the terrain",
     ("objectives[index] = buildObjective(index, point)", "objectives[index] = buildObjective(index, Vector3.new(point.X, 0, point.Z))")),
    ("KOTH takes one objective", ("#battleground.objectives >= 2 then", "#battleground.objectives >= 1 then")),
]

ROOT = "."


def main(argv):
    global ROOT
    ROOT = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else "."
    koth = read(ROOT, "ServerScriptService", "Modules", "ModeKingOfTheHill.lua")
    failures = run(ROOT)
    for line in failures[:20]:
        print("  FAIL " + line)
    print("team_battleground_modeteams_check: 6 matches, %d failures" % len(failures))
    iso = isolation(ROOT)
    for line in iso:
        print("  FAIL " + line)
    print("team_battleground_modeteams_check battle royale isolation (sources): %d failures" % len(iso))
    failures += iso
    kf = koth_checks(koth)
    for line in kf:
        print("  FAIL " + line)
    print("team_battleground_modeteams_check KOTH: %d failures" % len(kf))
    ok = not failures and not kf
    if "--plant" in argv:
        caught = 0
        total = len(PLANTS) + len(KOTH_PLANTS) + len(STATIC_PLANTS)
        for label, rel, old, new in STATIC_PLANTS:
            src = (Path(ROOT) / rel).read_text(encoding="utf-8")
            found = isolation(ROOT, {rel: src.replace(old, new, 1)}) if old in src else ["plant anchor not found"]
            hit = bool(found) and found != ["plant anchor not found"]
            caught += hit
            print("%s  %s  (%s)" % ("CAUGHT" if hit else "MISSED", label, found[0] if found else "no failure"))
        for label, plant in PLANTS:
            found = run(ROOT, plant, seeds=2)
            hit = bool(found) and not any("anchor not found" in f for f in found)
            caught += hit
            print("%s  %s  (%s)" % ("CAUGHT" if hit else "MISSED", label, found[0] if found else "no failure"))
        for label, (old, new) in KOTH_PLANTS:
            if old not in koth:
                print("MISSED  %s  (plant anchor not found)" % label)
                continue
            try:
                found = koth_checks(koth.replace(old, new, 1))
            except Exception as error:
                found = []
                print("  crashed: %s" % str(error).splitlines()[0])
            caught += bool(found)
            print("%s  %s  (%s)" % ("CAUGHT" if found else "MISSED", label, found[0] if found else "no failure"))
        print("team_battleground_modeteams_check plants: %d of %d caught" % (caught, total))
        ok &= caught == total
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
