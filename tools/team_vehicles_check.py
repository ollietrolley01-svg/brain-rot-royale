"""Behaviour check for the team-mode base vehicles (Oliver, 2026-09-24: "make vehicles spawn near
the spawns of the teams on team gamemodes"), without Studio.

Runs the real ModeTeams source from its State section to `-- END BASE VEHICLES` (so the real Setup,
BuildPads, RefusePad, Teardown and the base-vehicle section), the real MatchConfig, and the real
VehicleModels.Pick over the model table parsed out of VehicleModels.lua, in lupa. Mocked: terrain
(flat, with a bumpy hill, a hole and a ring of small buildings round each base), loot lying at each
base, VehicleService.Create/FootingAt, and the Instance tree. Measures what was PARKED, per base:
the count and mix, both bases alike, clear of pads, loot, buildings and each other, inside the arena,
level, nose to the arena centre; then wrecks and loses vehicles and drives the clock to watch the
replacements and the cap; then tears the match down.

    python tools/team_vehicles_check.py .            the checks
    python tools/team_vehicles_check.py . --plant    the planted faults; every one must be caught

Needs `pip install lupa`.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("team_vehicles_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+-])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def region(root):
    text = read(root, "ServerScriptService", "Modules", "ModeTeams.lua")
    start = text.index("local active = false")
    end = text.index("-- END BASE VEHICLES", start)
    return text[start:end]


def vehicle_models(root):
    text = read(root, "ReplicatedStorage", "Shared", "VehicleModels.lua")
    models = re.findall(r"^VehicleModels\.Models\.(\w+) = \{\n\tkind = \"(\w+)\",(?:.|\n)*?\n\tweight = (\d+),((?:\n\tdrivableOnly = true,)?)", text, re.M)
    models = [(m[0], m[1], m[2], bool(m[3])) for m in models]
    mounts_block = text[text.index("VehicleModels.Mounts = {"):]
    mounts_block = mounts_block[:mounts_block.index("\n}\n")]
    mounts = re.findall(r"^\t(\w+) = \{", mounts_block, re.M)
    start = text.index("function VehicleModels.Pick(kind, rng")
    pick = text[start:text.index("\nend\n", start) + 5]
    return models, mounts, pick


PRELUDE = r"""
local R = ...
-- Vector3 ------------------------------------------------------------------------------------------
local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) return Vector3.new(v.X / m, v.Y / m, v.Z / m) end
end
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
    return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }
Vector3.zero = Vector3.new(0, 0, 0)
-- CFrame: a position and a yaw, which is all this section makes -----------------------------------
local function rot(v, yaw)
    local c, s = math.cos(yaw), math.sin(yaw)
    return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end
local C = {}
C.__index = function(cf, k)
    if k == "Position" then return cf.p end
    if k == "LookVector" then return rot(Vector3.new(0, 0, -1), cf.yaw) end
end
C.__mul = function(a, b) return setmetatable({ p = a.p + rot(b.p, a.yaw), yaw = a.yaw + b.yaw }, C) end
CFrame = {
    new = function(p) return setmetatable({ p = p, yaw = 0 }, C) end,
    Angles = function(_, y, _) return setmetatable({ p = Vector3.zero, yaw = y }, C) end,
}
R.rot = rot
-- Instances ------------------------------------------------------------------------------------------
local Inst = {}
local IM = {}
IM.__index = function(t, k)
    if k == "Parent" then return rawget(t, "_parent") end
    -- A chassis stands where its model's pivot is, wherever the checks move it.
    if k == "Position" and rawget(t, "_follow") then return rawget(t, "_follow")._pivot.p end
    return Inst[k]
end
IM.__newindex = function(t, k, v)
    if k == "Parent" then
        local old = rawget(t, "_parent")
        if old then old._children[t] = nil end
        rawset(t, "_parent", v)
        if v then v._children[t] = true end
    else
        rawset(t, k, v)
    end
end
local function newInst(class, name)
    return setmetatable({ _class = class, Name = name or class, _attrs = {}, _children = {} }, IM)
end
function Inst:Destroy()
    for child in pairs(self._children) do child:Destroy() end
    self.Parent = nil
    rawset(self, "_destroyed", true)
end
function Inst:GetChildren() local list = {} for c in pairs(self._children) do table.insert(list, c) end return list end
function Inst:FindFirstChild(name) for c in pairs(self._children) do if c.Name == name then return c end end return nil end
function Inst:IsA(class) return class == self._class or (class == "BasePart" and self._class == "Part") end
function Inst:GetAttribute(k) return self._attrs[k] end
function Inst:SetAttribute(k, v) self._attrs[k] = v end
function Inst:GetPivot() return self._pivot end
function Inst:GetDescendants()
    local list = {}
    for c in pairs(self._children) do
        table.insert(list, c)
        for _, d in ipairs(c:GetDescendants()) do table.insert(list, d) end
    end
    return list
end
function Inst:FindFirstChildOfClass(class) for c in pairs(self._children) do if c._class == class then return c end end return nil end
function Inst:IsDescendantOf(root) local p = self.Parent while p do if p == root then return true end p = p.Parent end return false end
Instance = { new = function(class) return newInst(class) end }
R.newInst = newInst
-- Roblox odds and ends ------------------------------------------------------------------------------
Enum = { RaycastFilterType = { Include = "Include", Exclude = "Exclude" } }
RaycastParams = { new = function() return {} end }
OverlapParams = { new = function() return {} end }
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
warn = function(msg) R.warnings = R.warnings + 1 R.lastWarning = tostring(msg) end
R.warnings = 0
R.clock = 0
DateTime = { now = function() return { UnixTimestampMillis = R.clock } end }
Random = { new = function(_)
    return {
        NextNumber = function(_, a, b) a, b = a or 0, b or 1 return a + math.random() * (b - a) end,
        NextInteger = function(_, a, b) return math.random(a, b) end,
    }
end }
R.loops = {}
task = {
    spawn = function(f) local co = coroutine.create(f) table.insert(R.loops, co) coroutine.resume(co) end,
    wait = function() coroutine.yield() end,
    delay = function() end,
}
-- The world, laid out round each base at query time -------------------------------------------------
workspace = newInst("Workspace")
rawset(workspace, "Terrain", newInst("Terrain"))
local lootFolder = newInst("Folder", "Loot")
lootFolder.Parent = workspace
R.lootFolder = lootFolder
R.vehicles = {}
R.features = {}  -- per team: hill, hole, buildings, loot (built once the bases exist)
local function flat(a, b) local dx, dz = a.X - b.X, a.Z - b.Z return math.sqrt(dx * dx + dz * dz) end
R.flat = flat
local function ensureFeatures()
    for team = 1, 2 do
        local base = R.ModeTeams.BaseOf(team)
        local f = R.features[team]
        if base and (not f or f.base ~= base) then
            f = { base = base, hill = base + Vector3.new(35, 0, 35), hole = base + Vector3.new(-40, 0, 25), buildings = {}, loot = {} }
            for i = 0, 7 do
                local a = i * math.pi / 4 + 0.3
                table.insert(f.buildings, { Position = base + Vector3.new(math.cos(a) * 50, 0, math.sin(a) * 50), CanCollide = true, r = 3 })
            end
            for _, off in ipairs({ Vector3.new(30, 0, -20), Vector3.new(-30, 0, -30), Vector3.new(0, 0, 40) }) do
                local item = newInst("Part", "Loot")
                rawset(item, "Position", base + off)
                rawset(item, "CanCollide", false)
                item.Parent = lootFolder
                table.insert(f.loot, item)
            end
            R.features[team] = f
        end
    end
end
R.ensureFeatures = ensureFeatures
function R.height(x, z)
    ensureFeatures()
    local p = Vector3.new(x, 0, z)
    for team = 1, 2 do
        local f = R.features[team]
        if f then
            if flat(p, f.hole) < 14 then return nil end
            if flat(p, f.hill) < 30 then return 10 + 2.5 * math.sin(x / 3) * math.cos(z / 4) end
        end
    end
    return 10
end
function workspace:Raycast(origin)
    local y = R.height(origin.X, origin.Z)
    return y and { Position = Vector3.new(origin.X, y, origin.Z) } or nil
end
local function inBox(cf, size, pos, r)
    local d = rot(pos - cf.p, -cf.yaw)
    return math.abs(d.X) <= size.X / 2 + r and math.abs(d.Z) <= size.Z / 2 + r
end
R.inBox = inBox
function workspace:GetPartBoundsInBox(cf, size)
    ensureFeatures()
    local hits = {}
    for team = 1, 2 do
        local f = R.features[team]
        if f then
            for _, b in ipairs(f.buildings) do if inBox(cf, size, b.Position, b.r) then table.insert(hits, b) end end
            for _, l in ipairs(f.loot) do if l.Parent and inBox(cf, size, l.Position, 0.5) then table.insert(hits, l) end end
        end
    end
    for _, v in ipairs(R.vehicles) do
        if v.model:IsDescendantOf(workspace) and inBox(cf, size, v.model._pivot.p, 3) then
            table.insert(hits, { CanCollide = true })
        end
    end
    return hits
end
-- Modules -------------------------------------------------------------------------------------------
GameModes = { TeamCount = 2 }
MapTerrain = { InRiver = function() return false end }
VehicleModels = { Models = {}, Mounts = {} }
for _, m in ipairs(R.models) do VehicleModels.Models[m[1]] = { kind = m[2], weight = m[3], drivableOnly = m[4] } end
for _, id in ipairs(R.mounts) do VehicleModels.Mounts[id] = true end
local TOL = 0.5
local function footing(centre, yaw, size)
    local lo, hi = math.huge, -math.huge
    for _, pt in ipairs({ {1,1},{-1,1},{1,-1},{-1,-1},{1,0},{-1,0},{0,1},{0,-1} }) do
        local at = centre + rot(Vector3.new(pt[1] * size.X / 2, 0, pt[2] * size.Z / 2), yaw)
        local y = R.height(at.X, at.Z)
        if not y then return nil end
        lo, hi = math.min(lo, y), math.max(hi, y)
    end
    return hi - lo, hi
end
R.footing = footing
VehicleService = {
    FootingTolerance = TOL,
    FootingAt = function(_, centre, yaw, size) return footing(centre, yaw, size) end,
    Create = function(parent, position, yaw, kind, options)
        -- parkOn, roughly: a spot that is not level is stepped eight studs aside.
        local spread = footing(position, yaw, Vector3.new(8.9, 1, 16.6))
        if spread and spread > TOL then position = position + Vector3.new(8, 0, 0) end
        local model = newInst("Model", options.model)
        rawset(model, "_pivot", CFrame.new(position) * CFrame.Angles(0, yaw, 0))
        local chassis = newInst("Part", "Chassis")
        rawset(chassis, "_follow", model)
        chassis.Parent = model
        rawset(model, "PrimaryPart", chassis)
        local seat = newInst("VehicleSeat", "DriveSeat")
        seat.Parent = model
        model.Parent = parent
        table.insert(R.vehicles, { model = model, kind = kind, modelId = options.model, yaw = yaw })
        R.creates = R.creates + 1
        return model
    end,
}
R.creates = 0
ModeTeams = {}
R.ModeTeams = ModeTeams
typeof = function(x) if getmetatable(x) == C then return "CFrame" end return type(x) end
Shared = { WaitForChild = function(_, name) return name end }
script = { Parent = Shared }
require = function(name)
    return ({ MatchConfig = MatchConfig, VehicleModels = VehicleModels, VehicleService = VehicleService })[name]
end
"""


def run(root, plant=None, config_plant=None, seeds=40):
    """Returns a list of failure strings (empty = all good) and a summary line."""
    models, mounts, pick = vehicle_models(root)
    body = region(root)
    config_src = luau_to_lua(read(root, "ReplicatedStorage", "Shared", "MatchConfig.lua"))
    if plant:
        old, new = plant
        assert old in body, "plant text not found: " + old
        body = body.replace(old, new, 1)
    failures = []
    examined = 0
    for seed in range(1, seeds + 1):
        lua = LuaRuntime(unpack_returned_tuples=True)
        R = lua.eval("{}")
        R.models = lua.table_from([lua.table_from(list(m[:2]) + [int(m[2]), m[3]]) for m in models])
        R.mounts = lua.table_from(mounts)
        lua.execute("math.randomseed(%d)" % seed)
        lua.globals()._R = R
        lua.execute(PRELUDE.replace("local R = ...", "local R = _R"))
        lua.execute("MatchConfig = (function() " + config_src + " end)()")
        if config_plant:
            lua.execute(config_plant)
        lua.execute("VehicleModels.Pick = (function() local VehicleModels = VehicleModels\n" + luau_to_lua(pick)
                    + "\nreturn VehicleModels.Pick end)()")
        lua.execute("function protectionNowMs() return _R.clock end")
        chunk = "local ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain = ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain\n" \
                + luau_to_lua(body)
        lua.execute(chunk)
        try:
            checks = list(lua.execute(CHECKS).values())
        except Exception as error:  # a crash in the checks is a failure, never a pass
            checks = ["checks crashed: %s" % str(error).splitlines()[0]]
        for line in checks:
            failures.append("seed %d: %s" % (seed, line))
        examined += int(R.examined)
        if failures and plant:
            break
    return failures, examined


CHECKS = r"""
local R, M, cfg = _R, ModeTeams, MatchConfig.TeamBaseVehicles
local out = {}
local function fail(msg) table.insert(out, msg) end
local map = R.newInst("Model", "Map")
map.Parent = workspace
R.clock = 1000000
M.Setup({ id = "TeamDeathmatch", teams = true }, { dropSpots = { Vector3.new(0, 0, 0) }, radius = 900, map = map })
local centre, radius = M.Arena()
local folder = M.BaseVehicleFolder()
if not folder or folder.Parent ~= map then fail("no TeamBaseVehicles folder under the map") return out end
R.examined = 0

-- Which base a vehicle belongs to: the nearer one (they are hundreds of studs apart). Measured
-- from the world, not from anything the section keeps.
function R.teamOf(model)
    local p = model:GetPivot().Position
    return R.flat(p, M.BaseOf(1)) < R.flat(p, M.BaseOf(2)) and 1 or 2
end
local function liveOf(team)
    local list = {}
    for _, v in ipairs(R.vehicles) do
        if v.model:IsDescendantOf(workspace) and R.teamOf(v.model) == team and v.model:GetAttribute("Wrecked") ~= true then
            table.insert(list, v)
        end
    end
    return list
end
local armedSet = VehicleModels.Mounts
local ids = {}
for team = 1, 2 do
    local live = liveOf(team)
    if #live ~= #cfg.Slots then fail(("team %d: %d vehicles, want %d (%s)"):format(team, #live, #cfg.Slots, tostring(R.lastWarning))) end
    local armed, bikes, armored, list = 0, 0, 0, {}
    for i, v in ipairs(live) do
        R.examined = R.examined + 1
        local def = VehicleModels.Models[v.modelId]
        table.insert(list, v.modelId)
        if def.kind ~= v.kind then fail(v.modelId .. " created as " .. v.kind) end
        if def.kind == "car" and armedSet[v.modelId] then armed = armed + 1 end
        if def.drivableOnly then armored = armored + 1 end
        if def.kind == "bike" then bikes = bikes + 1 end
        local p = v.model:GetPivot().Position
        if R.flat(p, centre) > radius - 40 then fail("outside the arena") end
        if R.height(p.X, p.Z) == nil then fail("parked over a hole") end
        for _, pad in ipairs(M.BasePads(team)) do
            if R.flat(pad, p) < cfg.PadClearance then fail(("team %d %s %.1f from a pad"):format(team, v.modelId, R.flat(pad, p))) break end
        end
        for _, item in ipairs(R.features[team].loot) do
            if R.flat(item.Position, p) < cfg.LootClearance then fail("on the loot") end
        end
        local cf = v.model:GetPivot()
        for _, b in ipairs(R.features[team].buildings) do
            if R.inBox(cf, Vector3.new(8.9, 6, 16.6), b.Position, b.r) then fail("footprint on a building") end
        end
        for j = i + 1, #live do
            if R.flat(live[j].model:GetPivot().Position, p) < cfg.Gap then fail("two vehicles within Gap") end
        end
        local spread = R.footing(p, v.yaw, Vector3.new(8.9, 1, 16.6))
        if not spread or spread > 0.5 then fail(("not level: spread %s"):format(tostring(spread))) end
        local look = cf.LookVector
        local want = Vector3.new(centre.X - p.X, 0, centre.Z - p.Z).Unit
        if look.X * want.X + look.Z * want.Z < 0.999 then fail("not facing the arena centre") end
    end
    if armed < 1 then fail(("team %d: no armed vehicle"):format(team)) end
    -- Armoured cars: exactly the slots that ask for one (each base one, never two, never in a car slot).
    local wantArmored = 0
    for _, slot in ipairs(cfg.Slots) do if slot == "armored" then wantArmored = wantArmored + 1 end end
    if armored ~= wantArmored then fail(("team %d: %d armoured cars, want %d"):format(team, armored, wantArmored)) end
    if bikes > 1 then fail(("team %d: %d bikes"):format(team, bikes)) end
    table.sort(list)
    ids[team] = table.concat(list, ",")
end
if ids[1] ~= ids[2] then fail("bases differ: " .. ids[1] .. " vs " .. ids[2]) end

if #out > 0 then return out end
-- Respawn: wreck one of team 1's, lose one of team 2's off the map.
local wreck = liveOf(1)[1]
wreck.model:SetAttribute("Wrecked", true)
local lost = liveOf(2)[1]
lost.model:Destroy()
local before = R.creates
local t0 = R.clock
M.TickBaseVehicles(t0)
M.TickBaseVehicles(t0 + (cfg.RespawnDelay - 1) * 1000)
if R.creates ~= before then fail("replaced before RespawnDelay") end
M.TickBaseVehicles(t0 + cfg.RespawnDelay * 1000)
if R.creates - before ~= 2 then fail(("%d replacements at RespawnDelay, want 2"):format(R.creates - before)) end
if #liveOf(1) ~= #cfg.Slots or #liveOf(2) ~= #cfg.Slots then fail("bases not back to full after replacement") end
if wreck.model.Parent then fail("the wreck was left at the base") end
local newest = R.vehicles[#R.vehicles - 1]
if newest.modelId ~= wreck.modelId then fail("replacement is a different model") end
-- The cap: nothing lost, a long run of ticks, never more than the slots.
before = R.creates
for i = 1, 300 do
    M.TickBaseVehicles(t0 + cfg.RespawnDelay * 1000 + i * 1000)
    for team = 1, 2 do
        local n = 0
        for _, c in ipairs(folder:GetChildren()) do
            if R.teamOf(c) == team and c:GetAttribute("Wrecked") ~= true then n = n + 1 end
        end
        if n > #cfg.Slots then fail(("team %d holds %d live base vehicles"):format(team, n)) return out end
    end
end
if R.creates ~= before then fail(("%d vehicles created with nothing lost"):format(R.creates - before)) end
-- Wreck a whole base: all come back, and no more.
for _, v in ipairs(liveOf(1)) do v.model:SetAttribute("Wrecked", true) end
local t1 = t0 + 400000
M.TickBaseVehicles(t1)
M.TickBaseVehicles(t1 + cfg.RespawnDelay * 1000)
M.TickBaseVehicles(t1 + cfg.RespawnDelay * 1000 + 1000)
if #liveOf(1) ~= #cfg.Slots then fail(("after a whole base was wrecked it has %d"):format(#liveOf(1))) end

-- Cleanup.
M.Teardown()
if folder.Parent then fail("folder survived Teardown") end
for _, v in ipairs(R.vehicles) do
    if v.model:IsDescendantOf(workspace) then fail("a base vehicle survived Teardown") break end
end
before = R.creates
M.TickBaseVehicles(t1 + 999999)
for _, co in ipairs(R.loops) do
    if coroutine.status(co) ~= "dead" then coroutine.resume(co) end
    if coroutine.status(co) ~= "dead" then fail("respawn loop still running after Teardown") end
end
if R.creates ~= before then fail("vehicles created after Teardown") end
-- A mode without teams parks nothing.
R.vehicles = {}
M.Setup({ id = "Other", teams = false }, { dropSpots = { Vector3.new(0, 0, 0) }, radius = 900, map = map })
if #R.vehicles ~= 0 then fail("vehicles parked in a mode without teams") end
M.Teardown()

-- Bays: a provider hands over a pad-covered bay and a row of three at 20-stud spacing (tighter than
-- Gap, on purpose), pointed 0.7 rad off the centre line. The row is filled exactly; the pad bay never.
R.vehicles = {}
local rows = {}
M.BaseVehicleBays = function(team, base)
    if rows[team] then return rows[team] end
    local padList = M.BasePads(team)
    for i = 0, 199 do
        local a, reach = i * 2.4, 30 + (i % 5) * 10
        local first = base + Vector3.new(math.cos(a) * reach, 0, math.sin(a) * reach)
        local side = Vector3.new(-math.sin(a), 0, math.cos(a))
        local row, ok = {}, true
        for k = 0, 2 do
            -- 20 apart: the cars stand 0.7 rad off the row's normal, so at 10 a 9-wide van overlapped
            -- its neighbour, which ModeTeams' bay test (anything solid in the bay) now refuses.
            local at = first + side * (k * 20)
            if not R.height(at.X, at.Z) or R.flat(at, centre) > radius - 60 then ok = false end
            for _, pad in ipairs(padList) do if R.flat(pad, at) < cfg.PadClearance + 2 then ok = false end end
            local toward = Vector3.new(-at.X, 0, -at.Z).Unit
            local yaw = math.atan2(-toward.X, -toward.Z) + 0.7
            local spread = R.footing(at, yaw, Vector3.new(8.9, 1, 16.6))
            if not spread or spread > 0.5 then ok = false end
            -- And clear of the buildings, as a real bay is (ModeTeams refuses a bay with anything solid in it).
            local frame = CFrame.new(at) * CFrame.Angles(0, yaw, 0)
            for _, b in ipairs(R.features[team].buildings) do
                if R.inBox(frame, Vector3.new(10, 8, 18.5), b.Position, b.r) then ok = false end
            end
            table.insert(row, CFrame.new(Vector3.new(at.X, 10, at.Z)) * CFrame.Angles(0, yaw, 0))
        end
        if ok then
            table.insert(row, 1, CFrame.new(padList[1]))
            rows[team] = row
            return row
        end
    end
    fail("harness: no clear row for bays")
    return {}
end
M.Setup({ id = "TeamDeathmatch", teams = true }, { dropSpots = { Vector3.new(0, 0, 0) }, radius = 900, map = map })
for team = 1, 2 do
    local row = rows[team]
    if row then
        local used = {}
        for _, v in ipairs(liveOf(team)) do
            local p = v.model:GetPivot().Position
            for k = 2, #row do
                if R.flat(p, row[k].Position) < 0.01 then
                    used[k] = true
                    local look, want = v.model:GetPivot().LookVector, row[k].LookVector
                    if look.X * want.X + look.Z * want.Z < 0.999 then fail("bay vehicle not facing the bay's way") end
                end
            end
            if R.flat(p, row[1].Position) < cfg.PadClearance then fail("parked in the bay on a spawn pad") end
        end
        if not (used[2] and used[3] and used[4]) then fail(("team %d: bays not all filled"):format(team)) end
    end
end
-- A wreck in a bay is replaced into a bay.
local inBay = liveOf(1)[1]
if not inBay then fail("team 1 has no live vehicle with bays offered") return out end
inBay.model:SetAttribute("Wrecked", true)
local before2 = R.creates
M.TickBaseVehicles(R.clock)
M.TickBaseVehicles(R.clock + cfg.RespawnDelay * 1000)
if R.creates - before2 ~= 1 then fail("bay wreck not replaced once") end
local fresh = R.vehicles[#R.vehicles].model:GetPivot().Position
local hit = false
for k = 2, 4 do if rows[1] and R.flat(fresh, rows[1][k].Position) < 0.01 then hit = true end end
if not hit then fail("replacement not parked in the freed bay") end
M.Teardown()
M.BaseVehicleBays = nil
return out
"""

# Each is aimed at a rule the section must keep forever, not at a bug.
PLANTS = [
    ("pads ignored", ("if flatDistance(pad, at) < config.PadClearance then", "if false then")),
    ("facing away from the centre", ("return math.atan2(-toward.X, -toward.Z)", "return math.atan2(toward.X, toward.Z)")),
    ("each base rolls its own models", ("for _, modelId in ipairs(modelIds) do",
                                        "for _, modelId in ipairs(ModeTeams.RollBaseVehicleModels(Random.new(1))) do")),
    ("respawn ignores the delay", ("nowMs - slot.lostAt >= delayMs", "nowMs - slot.lostAt >= 0")),
    ("replacement never recorded (cap)", ("\t\t\t\tslot.model = model\n", "\t\t\t\tslot.model = slot.model\n")),
    ("wreck left behind", ("\t\t\t\t\t\twreck:Destroy()", "\t\t\t\t\t\tlocal _ = wreck")),
    ("no respawn at all", ("\t\t\t\t\tif parkSlot(team, slot) then", "\t\t\t\t\tif false then")),
    ("cleanup forgets the vehicles", ("\t\tbaseFolder:Destroy()\n", "\t\tlocal _ = baseFolder\n")),
    ("loop outlives the match", ("\tbaseGeneration += 1\n", "\tlocal _ = baseGeneration\n")),
    ("slope accepted", ("if spread <= VehicleService.FootingTolerance then", "if true then")),
    ("loot ignored", ("flatDistance(item.Position, at) < config.LootClearance", "false")),
    ("footprint not checked", ("\t\tif part.CanCollide then\n\t\t\treturn false", "\t\tif false then\n\t\t\treturn false")),
    ("bays ignored", ("local bayAt, bayYaw = baySpot(team, except)", "local bayAt, bayYaw = nil, nil")),
    ("bay on a pad accepted", ("local free = not ModeTeams.RefuseVehicleSpot(team, at, nil, true)", "local free = true")),
    ("taken bay reused", ("\t\t\tif free and taken() then", "\t\t\tif false then")),
    ("team guard dropped", ("if currentMode and currentMode.teams then", "if currentMode then")),
]
CONFIG_PLANTS = [
    ("two bikes in the slots", "MatchConfig.TeamBaseVehicles.Slots = { 'bike', 'bike', 'car' }"),
    ("no armed slot", "MatchConfig.TeamBaseVehicles.Slots = { 'bike', 'bike', 'bike' }"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "."
    if "--plant" in sys.argv:
        missed = 0
        for name, plant in PLANTS:
            failures, _ = run(root, plant=plant)
            print(("CAUGHT  " if failures else "MISSED  ") + name + ("  (" + failures[0] + ")" if failures else ""))
            missed += 0 if failures else 1
        for name, snippet in CONFIG_PLANTS:
            failures, _ = run(root, config_plant=snippet)
            print(("CAUGHT  " if failures else "MISSED  ") + name + ("  (" + failures[0] + ")" if failures else ""))
            missed += 0 if failures else 1
        print("team_vehicles_check plants: %d of %d caught" % (len(PLANTS) + len(CONFIG_PLANTS) - missed, len(PLANTS) + len(CONFIG_PLANTS)))
        sys.exit(1 if missed else 0)
    failures, examined = run(root)
    for line in failures[:20]:
        print("FAIL " + line)
    print("team_vehicles_check: 40 matches, %d parked base vehicles examined, %d failures" % (examined, len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
