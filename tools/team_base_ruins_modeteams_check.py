"""ModeTeams with the team-base compounds (TeamBaseRuins), checked without Studio.

Runs the REAL ModeTeams source -- its State section through `-- END BASE VEHICLES` (Setup, BuildPads,
the compound section, BaseLootSpots, Teardown and the base vehicles) plus ClearSpotNear -- in the mock
world of tools/team_vehicles_check.py (flat ground with a hill, a hole, buildings and loot round each
base; VehicleService.Create parks where it is told). TeamBaseRuins itself is a stub here: its geometry
is tools/team_base_ruins_check.py's business. The stub hands back a compound shaped like the real one
(8 pads, one named chest spot per LootService.BaseStock.chest, 6 bays in two rows, 15 loot spots, in the frame it was given) and
records what it was asked for. Measured, per match:

  * each team's spawn pads ARE its compound's pads, and both compounds got the same seed;
  * the chest call GameMode makes today (no kind, gap 14) gets only the compound's free chest spots,
    never a field spot, in order, skipping any with loot lying on it; the same with kind "chest";
  * other pickups fill the compound's loot spots first, then the ground round it;
  * the base vehicles are parked in the compound's bays, noses the bay's way, and NO TWO OVERLAP
    (Oliver's playtest, 2026-09-24: "the vehicles in the team bases are all messed up, like piled
    together"). Vehicles here are boxes of their REAL size, each model's extents measured from
    VehicleModels (tools/vehicle_models_axis_check.py's builder), and they are solid to the bay test.
    Create is modelled with parkOn's step-aside: under a bay one footing ray lands in a crack or on a
    wheel stop, so a car NOT placed exactly is stepped 8 studs onto the next bay (the pile-up);
  * a wreck is replaced into a bay, the wreck gone first; a bay with anything solid in it (a stray
    obstacle) is never parked into, and a slot with no free bay waits rather than going to a field;
  * a site on a road (SiteCost nil) turns the axis until both sites are usable;
  * one compound failing takes both down: open-ground pads for both, no bays handed out;
  * Teardown takes the compounds down and hands back BaseVehicleBays;
  * ClearSpotNear, with a body on the chosen pad, gives the nearest free pad of the compound;
  * a mode without teams builds no compound.

    python3 tools/team_base_ruins_modeteams_check.py .            the checks
    python3 tools/team_base_ruins_modeteams_check.py . --plant    and the planted faults
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from team_vehicles_check import PRELUDE, read, region, vehicle_models  # noqa: E402

from lupa import LuaRuntime  # noqa: E402


def luau_to_lua(source):
    import re
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+-])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def clear_spot(root):
    text = read(root, "ServerScriptService", "Modules", "ModeTeams.lua")
    start = text.index("local SPAWN_CLEARANCE")
    end = text.index("-- Places a body when its team has NO PADS AT ALL", start)
    return text[start:end]


STUB = r"""
local R = _R
-- Vehicles and obstacles as boxes: { centre, yaw, width, length }. Two boxes overlap by SAT in plan.
local function corners(b)
    local c, s = math.cos(b.yaw), math.sin(b.yaw)
    local out = {}
    for _, k in ipairs({ { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }) do
        local x, z = k[1] * b.w / 2, k[2] * b.l / 2
        table.insert(out, { b.p.X + x * c + z * s, b.p.Z - x * s + z * c })
    end
    return out
end
function R.overlap(a, b)
    local ca, cb = corners(a), corners(b)
    for _, box in ipairs({ ca, cb }) do
        for i = 1, 2 do
            local p1, p2 = box[i], box[i + 1]
            local ax, az = p2[2] - p1[2], p1[1] - p2[1]
            local amin, amax, bmin, bmax = math.huge, -math.huge, math.huge, -math.huge
            for _, q in ipairs(ca) do local d = q[1] * ax + q[2] * az; amin = math.min(amin, d); amax = math.max(amax, d) end
            for _, q in ipairs(cb) do local d = q[1] * ax + q[2] * az; bmin = math.min(bmin, d); bmax = math.max(bmax, d) end
            if amax <= bmin + 1e-6 or bmax <= amin + 1e-6 then return false end
        end
    end
    return true
end
function R.boxOf(v)
    local pivot = v.model:GetPivot()
    local e = R.extents[v.modelId] or { 9, 17.5 }
    return { p = pivot.p, yaw = pivot.yaw, w = e[1], l = e[2] }
end
R.obstacles = {}

-- A compound levels its own ground, so the mock's hill and hole round each base are flattened here.
function R.height() return 10 end
local C = getmetatable(CFrame.new(Vector3.zero))
CFrame.lookAt = function(at, target)
    local d = target - at
    return setmetatable({ p = at, yaw = math.atan2(-d.X, -d.Z) }, C)
end
table.clone = table.clone or function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
GameModes.TeamColor = function(team) return "colour" .. team end
R.bodies = {}
Combatants = { All = function() return R.bodies end }
R.builds = {}
R.badSites = {}
R.failTeam = nil
local function nearBay(position)
    for team = 1, 2 do
        local ruin = R.lastRuin and R.lastRuin[team]
        for _, bay in ipairs(ruin and ruin.vehicleBays or {}) do
            if R.flat(bay.Position, position) < 1 then return true end
        end
    end
    return false
end
local baseCreate = VehicleService.Create
VehicleService.Create = function(parent, position, yaw, kind, options)
    if not options.exact and nearBay(position) then
        -- parkOn: a footing ray in a crack or on a wheel stop reads 0.8 of spread, over the tolerance,
        -- and the ring steps the car 8 studs aside.
        position = position + Vector3.new(8, 0, 0)
        R.relocated = (R.relocated or 0) + 1
    end
    return baseCreate(parent, position, yaw, kind, options)
end
local baseBounds = workspace.GetPartBoundsInBox
function workspace:GetPartBoundsInBox(cf, size, params)
    local hits = {}
    for _, hit in ipairs(baseBounds(self, cf, size, params)) do
        -- The mock's buildings round each base stand where a compound has cleared its site.
        local cleared = false
        if hit.r and hit.Position then
            for team = 1, 2 do
                local base = R.ModeTeams.BaseOf(team)
                if base and R.ModeTeams.BaseRuin(team) and R.flat(hit.Position, base) < 70 then cleared = true end
            end
        end
        if not cleared and not hit.vehicleProxy then table.insert(hits, hit) end
    end
    local probe = { p = cf.p, yaw = cf.yaw, w = size.X, l = size.Z }
    for _, v in ipairs(R.vehicles) do
        if v.model:IsDescendantOf(workspace) and R.overlap(probe, R.boxOf(v)) then
            table.insert(hits, { CanCollide = true, vehicleProxy = true })
        end
    end
    for _, o in ipairs(R.obstacles) do
        if R.overlap(probe, o) then table.insert(hits, { CanCollide = true }) end
    end
    return hits
end
local function site(frame, x, z) return frame * CFrame.new(Vector3.new(x, 0, z)) end
TeamBaseRuins = {
    SiteCost = function(frame, mapInfo)
        for _, bad in ipairs(R.badSites) do
            if R.flat(frame.p, bad) < 60 then return nil, "road" end
        end
        return 1
    end,
    Build = function(frame, colour, mapInfo, seed)
        local team = colour == "colour1" and 1 or 2
        table.insert(R.builds, { team = team, seed = seed, frame = frame })
        if R.failTeam == team then error("no ground") end
        local model = R.newInst("Model", "TeamBase")
        model.Parent = mapInfo.map
        local ruin = { model = model, pads = {}, chestSpots = {}, vehicleBays = {}, lootSpots = {} }
        for _, z in ipairs({ 16, 30 }) do
            for _, x in ipairs({ -36, -27, -18, -9 }) do table.insert(ruin.pads, site(frame, x, z)) end
        end
        for i = 1, R.chestStock do table.insert(ruin.chestSpots, site(frame, -40 + ((i - 1) % 7) * 9, 36.9 + math.floor((i - 1) / 7) * 4)) end
        -- Six bays, as the real yard: three facing the gate, three across the east end facing out.
        for _, x in ipairs({ 12.5, 25, 37.5 }) do table.insert(ruin.vehicleBays, site(frame, x, -26)) end
        for _, z in ipairs({ -7, 4, 15 }) do table.insert(ruin.vehicleBays, site(frame, 32, z) * CFrame.Angles(0, -math.pi / 2, 0)) end
        for i = 1, 15 do table.insert(ruin.lootSpots, site(frame, -40 + i * 5, -20)) end
        R.lastRuin = R.lastRuin or {}
        R.lastRuin[team] = ruin
        return ruin
    end,
}
"""

CHECKS = r"""
local R, M = _R, ModeTeams
local out = {}
local function fail(msg) table.insert(out, msg) end
local map = R.newInst("Model", "Map")
map.Parent = workspace
local info = { dropSpots = { Vector3.new(0, 0, 0) }, radius = 900, map = map }
R.clock = 1000000
M.Setup({ id = "TeamDeathmatch", teams = true }, info)
if #R.builds ~= 2 then fail("compounds built: " .. #R.builds) return out end
if R.builds[1].seed ~= R.builds[2].seed then fail("the two compounds got different seeds") end
for team = 1, 2 do
    local ruin = M.BaseRuin(team)
    if not ruin then fail("team " .. team .. " has no compound") return out end
    local list = M.BasePads(team)
    if #list ~= #ruin.pads then fail(("team %d: %d pads, compound has %d"):format(team, #list, #ruin.pads)) end
    for i, pad in ipairs(ruin.pads) do
        if not list[i] or R.flat(list[i], pad.Position) > 1e-6 then fail(("team %d: pad %d is not the compound's"):format(team, i)) break end
    end
    -- The base vehicles: in the bays, the bay's way.
    local inBays = 0
    for _, v in ipairs(R.vehicles) do
        if v.model.Parent then
            local p = v.model:GetPivot()
            for _, bay in ipairs(ruin.vehicleBays) do
                if R.flat(p.p, bay.Position) < 0.01 then
                    inBays = inBays + 1
                    local look, want = p.LookVector, bay.LookVector
                    if look.X * want.X + look.Z * want.Z < 0.999 then fail("a bay vehicle does not face the bay's way") end
                end
            end
        end
    end
    if inBays ~= #ruin.vehicleBays then fail(("team %d: %d vehicles in its %d bays"):format(team, inBays, #ruin.vehicleBays)) end
end
-- No two vehicles (real sizes) overlap: two assemblies in one place is the pile-up.
local function liveVehicles()
    local list = {}
    for _, v in ipairs(R.vehicles) do
        if v.model:IsDescendantOf(workspace) and v.model:GetAttribute("Wrecked") ~= true then table.insert(list, v) end
    end
    return list
end
local function checkOverlap(when)
    local live = liveVehicles()
    for i = 1, #live do
        for j = i + 1, #live do
            if R.overlap(R.boxOf(live[i]), R.boxOf(live[j])) then
                fail(("%s: %s and %s overlap (a pile-up)"):format(when, live[i].modelId, live[j].modelId))
                return
            end
        end
    end
    for _, v in ipairs(live) do
        for _, o in ipairs(R.obstacles) do
            if R.overlap(R.boxOf(v), o) then fail(when .. ": a vehicle was put into an obstacle in its bay") return end
        end
    end
end
checkOverlap("after Setup")
local function inABay(v)
    for team = 1, 2 do
        for _, bay in ipairs(M.BaseRuin(team).vehicleBays) do
            if R.flat(v.model:GetPivot().p, bay.Position) < 0.01 then return true end
        end
    end
    return false
end
-- A wreck in a bay is replaced into its bay, and the wreck is gone.
local victim = nil
for _, v in ipairs(liveVehicles()) do
    if R.flat(v.model:GetPivot().p, M.BaseRuin(1).vehicleBays[1].Position) < 0.01 then victim = v end
end
if victim then
    victim.model:SetAttribute("Wrecked", true)
    local before = R.creates
    M.TickBaseVehicles(R.clock)
    M.TickBaseVehicles(R.clock + MatchConfig.TeamBaseVehicles.RespawnDelay * 1000)
    if R.creates - before ~= 1 then fail("the wreck in bay 1 was not replaced") end
    if victim.model:IsDescendantOf(workspace) then fail("the wreck was left standing") end
    checkOverlap("after a replacement")
    -- Something solid parked in bay 1 (a stray obstacle): wreck what is there; the replacement must
    -- not go into it, and with every other bay full it waits rather than going to a field.
    local bay = M.BaseRuin(1).vehicleBays[1]
    local look = bay.LookVector
    table.insert(R.obstacles, { p = bay.Position, yaw = math.atan2(-look.X, -look.Z), w = 3, l = 3 })
    for _, v in ipairs(liveVehicles()) do
        if R.flat(v.model:GetPivot().p, bay.Position) < 0.01 then v.model:SetAttribute("Wrecked", true) end
    end
    M.TickBaseVehicles(R.clock + 1)
    M.TickBaseVehicles(R.clock + 1 + MatchConfig.TeamBaseVehicles.RespawnDelay * 1000)
    checkOverlap("with an obstacle in bay 1")
    for _, v in ipairs(liveVehicles()) do
        if not inABay(v) then fail("a base vehicle stands outside the bays") break end
    end
    R.obstacles = {}
else
    fail("no vehicle in team 1's bay 1 to wreck")
end

-- Chests: GameMode's call today (no kind, gap 14), then with the kind named. The mock world's own
-- loot round the bases is cleared first, so what lies on a spot is only what this puts there.
for _, item in ipairs(R.lootFolder:GetChildren()) do item.Parent = nil end
local ruin = M.BaseRuin(1)
-- GameMode's call, with `missing` = the whole stock at the start (LootService.BaseStock.chest).
local want = R.chestStock
local spots = M.BaseLootSpots(1, want, 20, 80, 14, "chest")
if #spots ~= want then fail("chest call: " .. #spots .. " spots, want " .. want) end
for i, s in ipairs(spots) do
    if R.flat(s, ruin.chestSpots[i].Position) > 1e-6 then fail("chest call: spot " .. i .. " is not the compound's chest spot") break end
end
-- A caller that does not name the kind (the gap says chest) gets the same.
local legacy = M.BaseLootSpots(1, want, 20, 80, 14)
if #legacy ~= want or R.flat(legacy[1], ruin.chestSpots[1].Position) > 1e-6 then fail("kind-less chest call left the chest spots") end
-- Loot lying on three chest spots: those are skipped and nothing goes in the field instead.
local lying = {}
for _, i in ipairs({ 2, 5, 7 }) do
    local item = R.newInst("Part", "Chest")
    rawset(item, "Position", ruin.chestSpots[i].Position + Vector3.new(0.5, 1, 0.5))
    item.Parent = R.lootFolder
    table.insert(lying, item)
end
-- The refill: three still lying, so GameMode asks for the rest, and gets exactly the free spots.
spots = M.BaseLootSpots(1, want - 3, 20, 80, 14, "chest")
if #spots ~= want - 3 then fail("chest refill with three taken: " .. #spots .. " spots, want " .. (want - 3)) end
for _, s in ipairs(spots) do
    local ok = false
    for i, c in ipairs(ruin.chestSpots) do if R.flat(s, c.Position) < 1e-6 and i ~= 2 and i ~= 5 and i ~= 7 then ok = true end end
    if not ok then fail("chest call gave a spot that is not a free chest spot") break end
end
for _, item in ipairs(lying) do item:Destroy() end
-- Weapons: the compound's loot spots first, then the ground.
spots = M.BaseLootSpots(1, 18, 10, 80, 6)
local fromRuin = 0
for i = 1, math.min(#spots, #ruin.lootSpots) do
    if R.flat(spots[i], ruin.lootSpots[i].Position) < 1e-6 then fromRuin = fromRuin + 1 end
end
if fromRuin ~= #ruin.lootSpots then fail("weapon call: " .. fromRuin .. " of the compound's " .. #ruin.lootSpots .. " loot spots first") end
if #spots <= #ruin.lootSpots then fail("weapon call: nothing past the compound's spots") end

-- ClearSpotNear: a body on pad 1 sends the next arrival to the nearest free pad of the compound.
local pads1 = M.BasePads(1)
local body = { Parent = workspace }
local root = { Position = pads1[1] + Vector3.new(0, 3, 0) }
function body:FindFirstChildOfClass() return { Health = 100 } end
function body:FindFirstChild() return root end
R.bodies = { [body] = true }
local got = M.ClearSpotNear(pads1[1], nil, pads1)
local isPad = false
for i = 2, #pads1 do if R.flat(got, pads1[i]) < 1e-6 then isPad = true end end
if not isPad then fail("ClearSpotNear did not hand over another pad of the compound") end
R.bodies = {}

-- Teardown: compounds gone, bays handed back.
local models = { M.BaseRuin(1).model, M.BaseRuin(2).model }
M.Teardown()
for _, m in ipairs(models) do if m.Parent then fail("a compound survived Teardown") end end
if M.BaseVehicleBays ~= nil then fail("BaseVehicleBays still set after Teardown") end
if M.BaseRuin(1) or M.BaseRuin(2) then fail("BaseRuin still answers after Teardown") end

-- A road on the rolled axis: the axis turns until both sites are usable.
R.builds = {}
R.badSites = {}
math.randomseed(7)
local roll = math.random() * math.pi * 2
local reach = 900 * 0.66 * 0.72
R.badSites = { Vector3.new(math.cos(roll) * reach, 0, math.sin(roll) * reach) }
math.randomseed(7)
M.Setup({ id = "TeamDeathmatch", teams = true }, info)
for _, b in ipairs(R.builds) do
    if R.flat(b.frame.p, R.badSites[1]) < 60 then fail("a compound was built on the bad site") end
end
if #R.builds ~= 2 then fail("after turning the axis: " .. #R.builds .. " compounds") end
M.Teardown()
R.badSites = {}

-- One side failing: neither compound stands, both get open-ground pads, no bays handed out.
R.builds = {}
R.failTeam = 2
M.Setup({ id = "TeamDeathmatch", teams = true }, info)
R.failTeam = nil
if M.BaseRuin(1) or M.BaseRuin(2) then fail("a compound stands while the other failed") end
for _, child in ipairs(map:GetChildren()) do if child.Name:sub(1, 8) == "TeamBase" and child.Name ~= "TeamBaseVehicles" then fail("a failed pair left a model in the map") end end
if #M.BasePads(1) == 0 or #M.BasePads(2) == 0 then fail("no open-ground pads after the fallback") end
if M.BaseVehicleBays == M.RuinBays then fail("bays handed out with no compounds") end
M.Teardown()

-- No teams, no compounds.
R.builds = {}
M.Setup({ id = "Other", teams = false }, info)
if #R.builds ~= 0 then fail("a compound built in a mode without teams") end
M.Teardown()
return out
"""

PLANTS = [
    ("bay parking through parkOn", ("exact = inBay or nil", "exact = nil")),
    ("anything solid in a bay ignored", ("\t\t\t\treturn bayOccupied(bay)", "\t\t\t\treturn false")),
    ("replacement parked beside the wreck", ("\t\t\t\t\tif wreck and wreck.Parent then\n\t\t\t\t\t\twreck:Destroy()",
                                            "\t\t\t\t\tif false then\n\t\t\t\t\t\twreck:Destroy()")),
    ("full bays spill into the field", ("\tif ModeTeams.BaseVehicleBays ~= nil and ModeTeams.BaseVehicleBays == ModeTeams.RuinBays then\n\t\treturn nil",
                                        "\tif false then\n\t\treturn nil")),
    ("field pads kept", ("\t\tif ruin then\n\t\t\tpads[team] = {}", "\t\tif false then\n\t\t\tpads[team] = {}")),
    ("chests left to the field", ("\t\tif kind == nil and gap >= RUIN_CHEST_GAP then", "\t\tif false then")),
    ("chests put in the loot spots", ('freeRuinSpots(kind == "chest" and ruin.chestSpots or ruin.lootSpots, count)', 'freeRuinSpots(ruin.lootSpots, count)')),
    ("taken chest spots reused", ("if item:IsA(\"BasePart\") and Vector3.new(item.Position.X - at.X", "if false and Vector3.new(item.Position.X - at.X")),
    ("a seed per compound", ("\t\t\tModeTeams.BuildRuin(team, bases[team], mapInfo, ruinSeed)",
                             "\t\t\tModeTeams.BuildRuin(team, bases[team], mapInfo, math.random(1, 2147483646))")),
    ("bays never handed out", ("\t\tModeTeams.BaseVehicleBays = ModeTeams.RuinBays\n", "\n")),
    ("one-sided start kept", ("\tif withRuins and not (ruins[1] and ruins[2]) then\n\t\tModeTeams.ClearRuins()",
                              "\tif false then\n\t\tModeTeams.ClearRuins()")),
    # Teardown's own ClearRuins (the battleground's teardown now sits between it and StopBaseVehicles).
    ("compounds left standing", ("\tModeTeams.ClearBattleground()\n\tModeTeams.ClearRuins()\n\tif ModeTeams.BaseVehicleBays == ModeTeams.RuinBays then",
                                 "\tModeTeams.ClearBattleground()\n\tif ModeTeams.BaseVehicleBays == ModeTeams.RuinBays then")),
    ("the rolled axis, road or not", ("\t\taxis, fraction = ModeTeams.PickBaseAxis(axis, mapInfo)", "\t\tlocal _ = 0")),
    ("busy pad reused", ("\t\t\tif not occupiedAt(other, except) then\n\t\t\t\treturn other", "\t\t\tif false then\n\t\t\t\treturn other")),
]


def chest_stock(root):
    import re
    text = read(root, "ServerScriptService", "Modules", "LootService.lua")
    return int(re.search(r"LootService\.BaseStock = \{[^}]*chest = (\d+)", text).group(1))


def vehicle_extents(root):
    """{modelId: (width, length, height)} of every VehicleModels model as built (armed), from its parts."""
    import vehicle_models_axis_check as V
    rt = V.Runtime(V.load_sources(root))
    out = {}
    for mid in rt.ids:
        lo, hi = [1e9] * 3, [-1e9] * 3
        for p in rt.build(mid, "armed"):
            if p["transparency"] >= 1:
                continue
            h = [x / 2 for x in p["size"]]
            for i in range(3):
                e = sum(abs(p["cols"][k][i]) * h[k] for k in range(3))
                lo[i] = min(lo[i], p["pos"][i] - e)
                hi[i] = max(hi[i], p["pos"][i] + e)
        out[mid] = (hi[0] - lo[0], hi[2] - lo[2], hi[1] - lo[1])
    return out


EXTENTS = {}


def run(root, plant=None, seeds=6):
    models, mounts, pick = vehicle_models(root)
    body = region(root) + "\n" + clear_spot(root)
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
        R.chestStock = chest_stock(root)
        if not EXTENTS:
            EXTENTS.update(vehicle_extents(root))
        R.extents = lua.table_from({k: lua.table_from(list(v)) for k, v in EXTENTS.items()})
        lua.execute("math.randomseed(%d)" % seed)
        lua.globals()._R = R
        lua.execute(PRELUDE.replace("local R = ...", "local R = _R"))
        lua.execute("MatchConfig = (function() " + config_src + " end)()")
        lua.execute("VehicleModels.Pick = (function() local VehicleModels = VehicleModels\n" + luau_to_lua(pick)
                    + "\nreturn VehicleModels.Pick end)()")
        lua.execute("function protectionNowMs() return _R.clock end")
        lua.execute(STUB)
        chunk = ("local ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain, TeamBaseRuins, Combatants = "
                 "ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain, TeamBaseRuins, Combatants\n"
                 + luau_to_lua(body))
        try:
            lua.execute(chunk)
            checks = list(lua.execute(CHECKS).values())
        except Exception as error:  # a crash is a failure, never a pass
            checks = ["crashed: %s" % str(error).splitlines()[0]]
        failures += ["seed %d: %s" % (seed, line) for line in checks]
        if failures and plant:
            break
    return failures


def main(argv):
    root = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else "."
    failures = run(root)
    for line in failures[:20]:
        print("  FAIL " + line)
    print("team_base_ruins_modeteams_check: 6 matches, %d failures" % len(failures))
    ok = not failures
    if "--plant" in argv:
        caught = 0
        for label, plant in PLANTS:
            found = run(root, plant, seeds=2)
            hit = bool(found) and not any("anchor not found" in f for f in found)
            caught += hit
            print("%s  %s  (%s)" % ("CAUGHT" if hit else "MISSED", label, found[0] if found else "no failure"))
        print("team_base_ruins_modeteams_check plants: %d of %d caught" % (caught, len(PLANTS)))
        ok &= caught == len(PLANTS)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
