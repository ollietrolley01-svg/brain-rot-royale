"""Behaviour check for the team bases' vehicle respawn (Oliver, 2026-09-25: "make the vehicles at the
bases respawn when destroyed"), without Studio.

Runs the real ModeTeams base-vehicle section in lupa on team_vehicles_check's mock world, and
destroys or loses base vehicles every way the game allows, then drives the respawn clock:
  gun / blast       Wrecked set (what VehicleService.DamageVehicle does at 0 health)
  chassis broken    the chassis deleted, the model left standing, no Wrecked
  emptied           every part deleted, an empty model left standing, no Wrecked
  fell              the chassis below the map
  drowned           sunk in terrain water with nobody in it (and NOT when someone sits in it)
  abandoned         empty and far from base for AbandonSeconds (and NOT while occupied, and NOT near base)
  removed           the model destroyed outright
In a compound's bays (ModeTeams.RuinBays): a bay full of rubble is cleared and reused, a bay walled for
good is given up for another spot after BAY_FALLBACK_FAILS tries, and a bay with a person standing in it
(a non-colliding root part) is never parked in. Throughout: nothing replaced before RespawnDelay, every
loss replaced at it, bays kept full, never more live vehicles than slots, no replacement with nothing lost.
A compound at the arena's edge still parks every bay on both sides: the farthest pair of sites
RankBaseAxes will rank on the smallest arena (radius 600), with TeamBaseRuins' own bay and pad layout
laid out there, keeps every declared bay inside RefuseVehicleSpot's arena rule and parks all its slots.
Also runs VehicleService's own chassis-lost branch (Stepped) on a mock entry: it must set Wrecked.

For the same thing with real physics, in Studio, see tools/base_vehicle_respawn_probe.lua; feed its log
here with --probe-log <file> to judge it.

    python tools/base_vehicle_respawn_check.py .                      the checks
    python tools/base_vehicle_respawn_check.py . --plant              every planted fault must be caught
    python tools/base_vehicle_respawn_check.py . --probe-log <file>   judge a Studio probe run

Needs `pip install lupa`.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from team_vehicles_check import PRELUDE, luau_to_lua, read, region, vehicle_models  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

SEEDS = 12

# TeamBaseRuins' compound layout, as its own `local` lines: the footprint, the motor pool's bays and the
# hall's spawn pads, all in the compound's frame (on the ground, looking at the arena centre).
LAYOUT_NAMES = ("WX, WZ", "LANE_PITCH", "LANE_X0, LANE_X1", "EAST_Z0, EAST_Z1", "FRONT_Z", "FRONT_BAYS", "EAST_X",
                "EAST_BAYS", "PAD_X", "PAD_Z")


def ruin_layout(root):
    """Lua returning { footprint = { x, z }, bays = { { x, z, yaw }... }, pads = { { x, z }... } }, built from
    TeamBaseRuins.lua's own layout lines: the front row at FRONT_Z (yaw 0), the east row at EAST_X (yaw
    -pi/2), and the pads PAD_X by PAD_Z."""
    text = read(root, "ServerScriptService", "Modules", "TeamBaseRuins.lua")
    lines = []
    for name in LAYOUT_NAMES:
        m = re.search(r"^local %s = .*$" % re.escape(name), text, re.M)
        assert m, "TeamBaseRuins: no line for " + name
        lines.append(m.group(0))
    return "\n".join(lines) + r"""
local bays, pads = {}, {}
for _, x in ipairs(FRONT_BAYS) do table.insert(bays, { x, FRONT_Z, 0 }) end
for _, z in ipairs(EAST_BAYS) do table.insert(bays, { EAST_X, z, -math.pi / 2 }) end
for _, z in ipairs(PAD_Z) do for _, x in ipairs(PAD_X) do table.insert(pads, { x, z }) end end
return { footprint = { 2 * (WX + 1), 2 * (WZ + 1) }, bays = bays, pads = pads }
"""

EXTRA = r"""
local R = _R
-- Terrain water: zones { centre, radius, top }; ReadVoxels reports water when the region's middle is in one.
R.water = {}
Region3 = { new = function(a, b)
    local r = { mid = (a + b) * 0.5 }
    function r:ExpandToGrid() return self end
    return r
end }
Enum.Material = { Water = "Water", Air = "Air" }
function workspace.Terrain:ReadVoxels(region)
    for _, zone in ipairs(R.water) do
        if R.flat(region.mid, zone.centre) < zone.radius and region.mid.Y < zone.top then
            return { { { "Water" } } }, { { { 1 } } }
        end
    end
    return { { { "Air" } } }, { { { 0 } } }
end
workspace.FallenPartsDestroyHeight = -500
-- Things put in the world by the checks: rubble, walls, people. Insts with a Position.
R.extra = {}
local baseBounds = workspace.GetPartBoundsInBox
function workspace:GetPartBoundsInBox(cf, size, params)
    local hits = baseBounds(self, cf, size, params)
    for _, part in ipairs(R.extra) do
        if part.Parent and R.inBox(cf, size, part.Position, 1) then table.insert(hits, part) end
    end
    return hits
end
function R.part(position, attrs, collide)
    local part = R.newInst("Part", "Extra")
    rawset(part, "Position", position)
    rawset(part, "CanCollide", collide ~= false)
    for k, v in pairs(attrs or {}) do part:SetAttribute(k, v) end
    part.Parent = workspace
    table.insert(R.extra, part)
    return part
end
function R.person(position)
    local body = R.newInst("Model", "Someone")
    R.newInst("Humanoid", "Humanoid").Parent = body
    local root = R.newInst("Part", "HumanoidRootPart")
    rawset(root, "Position", position)
    rawset(root, "CanCollide", false)
    root.Parent = body
    body.Parent = workspace
    table.insert(R.extra, root)
    return body
end
"""

CHECKS = r"""
local R, M, cfg = _R, ModeTeams, MatchConfig.TeamBaseVehicles
local out = {}
local function fail(msg) table.insert(out, msg) end
if cfg.RespawnDelay > 20 then fail(("RespawnDelay %s, want 20 or less"):format(tostring(cfg.RespawnDelay))) end
if not cfg.AbandonSeconds or not cfg.AbandonDistance then fail("no AbandonSeconds / AbandonDistance in MatchConfig") return out end
local map = R.newInst("Model", "Map")
map.Parent = workspace
R.clock = 1000000
M.Setup({ id = "TeamDeathmatch", teams = true }, { dropSpots = { Vector3.new(0, 0, 0) }, radius = 900, map = map })
local centre = M.Arena()
local folder = M.BaseVehicleFolder()
local SLOTS = #cfg.Slots
local DELAY = cfg.RespawnDelay * 1000
R.examined = 0

function R.teamOf(model)
    local p = model:GetPivot().Position
    return R.flat(p, M.BaseOf(1)) < R.flat(p, M.BaseOf(2)) and 1 or 2
end
-- The slot vehicles of `team`, by slot, as the section holds them.
local function slotModels(team)
    local list = {}
    for i, slot in ipairs(M.BaseVehicleSlots(team)) do list[i] = slot.model end
    return list
end
-- Whole vehicles standing at `team`'s base, measured from the world.
local function atHome(team)
    local n = 0
    for _, c in ipairs(folder:GetChildren()) do
        local chassis = c.PrimaryPart
        if c:GetAttribute("Wrecked") ~= true and chassis and chassis.Parent and chassis.Position.Y > -300
            and R.flat(c:GetPivot().Position, M.BaseOf(team)) < cfg.AbandonDistance then
            n = n + 1
        end
    end
    return n
end
local now = R.clock
local function tick(ms)
    now = now + ms
    M.TickBaseVehicles(now)
    for team = 1, 2 do
        if M.LiveBaseVehicles(team) > SLOTS then fail(("team %d counts %d live, over %d slots"):format(team, M.LiveBaseVehicles(team), SLOTS)) end
    end
end
local function seconds(n) for _ = 1, n do tick(1000) end end
local function moveTo(model, p) rawset(model, "_pivot", CFrame.new(p)) end

-- 1. Every way to lose one, all at once: team 1 takes six, team 2 the rest.
local m1, m2 = slotModels(1), slotModels(2)
local farAway = Vector3.new(centre.X, 10, centre.Z)
local losses = {
    { team = 1, how = "gun", act = function(m) m:SetAttribute("Wrecked", true) end },
    { team = 1, how = "chassis broken", act = function(m) m.PrimaryPart:Destroy() end },
    { team = 1, how = "emptied", act = function(m) for _, c in ipairs(m:GetChildren()) do c:Destroy() end end },
    { team = 1, how = "fell", act = function(m) moveTo(m, Vector3.new(m:GetPivot().Position.X, -450, m:GetPivot().Position.Z)) end },
    { team = 1, how = "drowned", act = function(m)
        local p = m:GetPivot().Position
        table.insert(R.water, { centre = p, radius = 6, top = p.Y + 12 })
    end },
    { team = 1, how = "removed", act = function(m) m:Destroy() end },
    { team = 2, how = "abandoned", act = function(m) moveTo(m, farAway) end },
}
local controls = {
    -- Far away but someone is in it: never lost.
    { team = 2, how = "far but occupied", act = function(m)
        moveTo(m, farAway + Vector3.new(20, 0, 0))
        m:FindFirstChildOfClass("VehicleSeat").Occupant = {}
    end },
    -- Empty, but at home: never lost.
    { team = 2, how = "parked at home", act = function() end },
}
local used = { 0, 0 }
for _, list in ipairs({ losses, controls }) do
    for _, case in ipairs(list) do
        used[case.team] = used[case.team] + 1
        case.model = (case.team == 1 and m1 or m2)[used[case.team]]
        case.act(case.model)
    end
end
local before = R.creates
tick(1000)
for _, case in ipairs(losses) do
    local why = M.BaseVehicleSlots(case.team)[0 + (function() for i, s in ipairs(M.BaseVehicleSlots(case.team)) do if s.model == case.model then return i end end return 0 end)()]
    if case.how ~= "abandoned" and (not why or not why.lostAt) then fail(case.how .. ": the tick does not see it as lost") end
end
-- Nothing before the delay.
seconds(cfg.RespawnDelay - 2)
if R.creates ~= before then fail(("%d replaced before RespawnDelay"):format(R.creates - before)) end
seconds(3)
if R.creates - before ~= 6 then fail(("%d of team 1's 6 losses replaced at RespawnDelay"):format(R.creates - before)) end
if atHome(1) ~= SLOTS then fail(("team 1 has %d at home after its losses were replaced, want %d"):format(atHome(1), SLOTS)) end
for _, case in ipairs(losses) do
    if case.team == 1 and case.model.Parent and #case.model:GetChildren() > 0 and case.how ~= "removed" then
        fail(case.how .. ": the lost vehicle was left in the world")
    end
end
-- The abandoned one: lost after AbandonSeconds, replaced RespawnDelay after that.
local abandonedAt = now
-- Its clock started at the first tick; RespawnDelay + 1 s have gone since.
seconds(cfg.AbandonSeconds - 2)
if R.creates - before ~= 6 then fail("the abandoned vehicle was replaced early") end
seconds(2)
if R.creates - before ~= 7 then fail(("abandoned: %d replacements, want 7 in all"):format(R.creates - before)) end
if atHome(2) < SLOTS - 1 then fail(("team 2 has %d at home, want %d (one is out, occupied)"):format(atHome(2), SLOTS - 1)) end
-- The occupied one is still the base's, and still counted.
if M.LiveBaseVehicles(2) ~= SLOTS then fail(("team 2 counts %d live, want %d"):format(M.LiveBaseVehicles(2), SLOTS)) end
if not controls[1].model.Parent then fail("the occupied far vehicle was taken away") end

-- 2. A loss that comes back: the far car's rider gets out (lost after AbandonSeconds), gets back in
-- before the replacement, then leaves it far again: a whole new wait, not an instant replacement.
local seat = controls[1].model:FindFirstChildOfClass("VehicleSeat")
if not controls[1].model.Parent or not seat then fail("the occupied far vehicle is gone") return out end
seat.Occupant = nil
before = R.creates
seconds(cfg.AbandonSeconds + 2)
seat.Occupant = {}
seconds(cfg.RespawnDelay + 2)
if R.creates ~= before then fail("a vehicle someone got back into was replaced") end
seat.Occupant = nil
seconds(cfg.AbandonSeconds + cfg.RespawnDelay - 3)
if R.creates ~= before then fail("abandoned a second time: replaced before AbandonSeconds + RespawnDelay") end
seconds(6)
if R.creates - before ~= 1 then fail(("abandoned a second time: %d replacements, want 1"):format(R.creates - before)) end

-- 3. No double spawns: a long quiet run creates nothing.
before = R.creates
seconds(200)
if R.creates ~= before then fail(("%d vehicles created with nothing lost"):format(R.creates - before)) end
R.examined = R.examined + 2 * SLOTS

-- 4. Bays (a compound's): rubble cleared, a walled bay given up, a person never parked in.
M.Teardown()
local bayList = { {}, {} }
M.Setup({ id = "TeamDeathmatch", teams = true }, { dropSpots = { Vector3.new(0, 0, 0) }, radius = 900, map = map })
for team = 1, 2 do
    local base = M.BaseOf(team)
    for ring = 0, 40 do
        for k = 0, 23 do
            if #bayList[team] >= SLOTS then break end
            local a = k * math.pi / 12
            local p = base + Vector3.new(math.cos(a) * (24 + ring), 10, math.sin(a) * (24 + ring))
            local ok = not M.RefuseVehicleSpot(team, p, nil, true) and R.footing(p, 0, Vector3.new(8.9, 1, 16.6)) == 0
            for _, b in ipairs(bayList[team]) do if R.flat(b.Position, p) < 22 then ok = false end end
            local probe = workspace:GetPartBoundsInBox(CFrame.new(p), Vector3.new(10, 8, 20.1), nil)
            if #probe > 0 then ok = false end
            if ok then table.insert(bayList[team], CFrame.new(p)) end
        end
    end
end
M.RuinBays = function(team) return bayList[team] end
M.BaseVehicleBays = M.RuinBays
M.SpawnBaseVehicles({ map = map })
folder = M.BaseVehicleFolder()
local b1 = bayList[1]
if #b1 < SLOTS then fail("mock: only " .. #b1 .. " bays found") return out end
local function inBay(model)
    for i, bay in ipairs(b1) do if R.flat(model:GetPivot().Position, bay.Position) < 1 then return i end end
    return nil
end
local byBay = {}
for _, m in ipairs(slotModels(1)) do if m and inBay(m) then byBay[inBay(m)] = m end end
if not (byBay[1] and byBay[2] and byBay[3]) then
    local n = 0 for _ in pairs(byBay) do n = n + 1 end
    local p = slotModels(1)[1] and slotModels(1)[1]:GetPivot().Position
    fail(("mock: bays 1-3 not all filled at the start (%d bays filled; first car %s, bay1 %s)"):format(n, p and ("%.1f,%.1f,%.1f"):format(p.X,p.Y,p.Z) or "-", ("%.1f,%.1f,%.1f"):format(b1[1].Position.X, b1[1].Position.Y, b1[1].Position.Z)))
    return out
end
local rubble = R.part(b1[1].Position + Vector3.new(1, 1, 0), { Rubble = true })
byBay[1]:SetAttribute("Wrecked", true)
local wall = R.part(b1[2].Position + Vector3.new(0, 2, 0), {})
byBay[2]:SetAttribute("Wrecked", true)
local someone = R.person(b1[3].Position + Vector3.new(0, 3, 0))
byBay[3]:SetAttribute("Wrecked", true)
before = R.creates
seconds(cfg.RespawnDelay + 1)
if rubble.Parent then fail("rubble left in its bay") end
local bayNow = {}
for _, m in ipairs(slotModels(1)) do if m and m.Parent and inBay(m) then bayNow[inBay(m)] = m end end
if not bayNow[1] then fail("the rubble bay was not reused") end
if bayNow[2] then fail("a vehicle parked into the wall") end
if bayNow[3] then fail("a vehicle parked into a person") end
seconds(30)
if atHome(1) ~= SLOTS then fail(("walled and occupied bays: team 1 has %d at home, want %d (another spot)"):format(atHome(1), SLOTS)) end
for _, m in ipairs(slotModels(1)) do
    if m and R.flat(m:GetPivot().Position, b1[3].Position) < 5 then fail("a vehicle stands in the person") end
end
if not wall.Parent then fail("a wall was cleared out of a bay") end
before = R.creates
seconds(100)
if R.creates ~= before then fail(("bays: %d vehicles created with nothing lost"):format(R.creates - before)) end
R.examined = R.examined + SLOTS

-- 5. A compound at the arena's edge still parks every bay on both sides. The smallest arena (radius
-- 880 is 600 after the clamp), and a SiteCost that favours the farthest site, so the pair ranked first
-- is the farthest RankBaseAxes allows at all. Its declared bays keep RefuseVehicleSpot's arena rule
-- (on purpose: the arena is a static storm wall in team modes), so every bay must be inside it.
M.Teardown()
M.Setup({ id = "TeamDeathmatch", teams = true }, { dropSpots = { Vector3.new(0, 0, 0) }, radius = 880, map = map })
local edgeCentre, edgeRadius = M.Arena()
CFrame.lookAt = CFrame.lookAt or function(at, target)
    local d = target - at
    return CFrame.new(at) * CFrame.Angles(0, math.atan2(-d.X, -d.Z), 0)
end
TeamBaseRuins = { Footprint = Vector3.new(R.layout.footprint[1], 0, R.layout.footprint[2]),
    SiteCost = function(site) return 1000 - R.flat(site.Position, edgeCentre) end }
-- RankBaseAxes hands the frame back (task.wait) between slices; here, outside any loop, that is a no-op.
local wait = task.wait
task.wait = function() end
local ranked = M.RankBaseAxes(0, { map = map })
task.wait = wait
TeamBaseRuins = nil
local best = ranked[1]
if not best then fail("edge: RankBaseAxes ranked nothing at radius " .. edgeRadius) return out end
R.extra = {}
local edgeBays = { {}, {} }
for team = 1, 2 do
    local heading = best.axis + (team - 1) * math.pi
    local base = edgeCentre + Vector3.new(math.cos(heading), 0, math.sin(heading)) * (edgeRadius * best.fraction)
    local frame = CFrame.lookAt(Vector3.new(base.X, 10, base.Z), Vector3.new(edgeCentre.X, 10, edgeCentre.Z))
    -- Flat, open ground round the compound: nothing of the mock world's own in the way.
    R.features[team] = { base = M.BaseOf(team), hill = Vector3.new(1e6, 0, 1e6), hole = Vector3.new(1e6, 0, 1e6), buildings = {}, loot = {} }
    local pads = M.BasePads(team)
    table.clear(pads)
    for _, p in ipairs(R.layout.pads) do table.insert(pads, (frame * CFrame.new(Vector3.new(p[1], 0, p[2]))).Position) end
    for i, b in ipairs(R.layout.bays) do
        local bay = frame * CFrame.new(Vector3.new(b[1], 0, b[2])) * CFrame.Angles(0, b[3], 0)
        local why = M.RefuseVehicleSpot(team, bay.Position, nil, true)
        if why then
            fail(("edge: team %d's Bay%d refused (%s), %.1f from the centre at fraction %.2f of radius %d")
                :format(team, i, why, R.flat(bay.Position, edgeCentre), best.fraction, edgeRadius))
        end
        table.insert(edgeBays[team], bay)
    end
end
M.RuinBays = function(team) return edgeBays[team] end
M.BaseVehicleBays = M.RuinBays
local parked = M.SpawnBaseVehicles({ map = map })
if parked ~= 2 * SLOTS then fail(("edge: parked %d of %d at the start (fraction %.2f of radius %d)"):format(parked, 2 * SLOTS, best.fraction, edgeRadius)) end
for team = 1, 2 do
    local filled, n = {}, 0
    for _, slot in ipairs(M.BaseVehicleSlots(team)) do
        local p = slot.model and slot.model.Parent and slot.model:GetPivot().Position
        for i, bay in ipairs(edgeBays[team]) do
            if p and not filled[i] and R.flat(p, bay.Position) < 1 then filled[i] = true n = n + 1 end
        end
    end
    if n ~= math.min(SLOTS, #edgeBays[team]) then fail(("edge: team %d has %d of %d bays filled"):format(team, n, #edgeBays[team])) end
end
R.examined = R.examined + 2 * SLOTS
M.Teardown()
return out
"""

VS_CHECK = r"""
local out = {}
local attrs = {}
local model = { Parent = {}, GetAttribute = function(_, k) return attrs[k] end, SetAttribute = function(_, k, v) attrs[k] = v end }
local entry = { model = model, rig = { chassis = { Parent = nil } }, riders = {}, deaths = {} }
BRANCH(entry)
if attrs.Wrecked ~= true or entry.wrecked ~= true then table.insert(out, "VehicleService: a chassis lost under a standing model is not Wrecked") end
return out
"""


def vs_branch(root, plant=None):
    text = read(root, "ServerScriptService", "Modules", "VehicleService.lua")
    if plant:
        assert plant[0] in text, "plant text not found: " + plant[0]
        text = text.replace(plant[0], plant[1], 1)
    head = "if not entry.model.Parent or not entry.rig or not entry.rig.chassis.Parent then\n"
    start = text.index(head) + len(head)
    end = text.index("byModel[entry.model] = nil\n", start) + len("byModel[entry.model] = nil\n")
    body = luau_to_lua(text[start:end])
    return ("local byModel = {}\nlocal function clearRider() end\nlocal function setMassless() end\n"
            "BRANCH = function(entry)\n" + body + "\nend\n")


def run(root, plant=None, vs_plant=None, config_plant=None, seeds=SEEDS):
    models, mounts, pick = vehicle_models(root)
    body = region(root)
    config_src = luau_to_lua(read(root, "ReplicatedStorage", "Shared", "MatchConfig.lua"))
    if plant:
        assert plant[0] in body, "plant text not found: " + plant[0]
        body = body.replace(plant[0], plant[1], 1)
    layout = ruin_layout(root)
    failures, examined = [], 0
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(vs_branch(root, vs_plant))
    failures += ["VehicleService: " + str(x) for x in lua.execute(VS_CHECK).values()]
    for seed in range(1, seeds + 1):
        lua = LuaRuntime(unpack_returned_tuples=True)
        R = lua.eval("{}")
        R.models = lua.table_from([lua.table_from(list(m[:2]) + [int(m[2]), m[3]]) for m in models])
        R.mounts = lua.table_from(mounts)
        lua.execute("math.randomseed(%d)" % seed)
        lua.globals()._R = R
        lua.execute(PRELUDE.replace("local R = ...", "local R = _R"))
        lua.execute(EXTRA)
        lua.execute("_R.layout = (function()\n" + layout + "\nend)()")
        lua.execute("MatchConfig = (function() " + config_src + " end)()")
        if config_plant:
            lua.execute(config_plant)
        lua.execute("VehicleModels.Pick = (function() local VehicleModels = VehicleModels\n" + luau_to_lua(pick)
                    + "\nreturn VehicleModels.Pick end)()")
        lua.execute("function protectionNowMs() return _R.clock end")
        lua.execute("local ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain = "
                    "ModeTeams, GameModes, MatchConfig, VehicleModels, VehicleService, MapTerrain\n" + luau_to_lua(body))
        try:
            lines = list(lua.execute(CHECKS).values())
        except Exception as error:  # a crash is a failure, never a pass
            lines = ["checks crashed: %s" % str(error).splitlines()[0]]
        failures += ["seed %d: %s" % (seed, line) for line in lines]
        examined += int(R.examined or 0)
        if failures and (plant or vs_plant or config_plant):
            break
    return failures, examined


PLANTS = [
    ("broken chassis not lost", ('if not chassis or not chassis.Parent then\n\t\treturn "chassis"', 'if false then\n\t\treturn "chassis"')),
    ("below the map not lost", ('\t\treturn "fell"', '\t\tlocal _ = "fell"')),
    ("drowned not lost", ('if submerged(at) then', 'if false then')),
    ("abandon rule off", ('\t\tif slot.abandoned then', '\t\tif false then')),
    ("occupied far vehicle lost", ('\tif occupied(model) then\n\t\tslot.emptySince', '\tif false then\n\t\tslot.emptySince')),
    ("permanently blocked bay (no fallback)", ("local BAY_FALLBACK_FAILS = 2", "local BAY_FALLBACK_FAILS = 1e9")),
    ("rubble never cleared", ("\t\t\tdebris[junk] = true", "\t\t\treturn true")),
    ("person in a bay ignored", ("\tif personIn(frame, BAY_CLEAR) then\n\t\treturn true", "\tif false then\n\t\treturn true")),
    ("lost clock never resets", ("\t\t\t\t\tslot.lostAt, slot.lostWhy = nil, nil\n", "")),
    ("lost vehicle left standing", ("\t\t\t\t\tif wreck and wreck.Parent then\n\t\t\t\t\t\twreck:Destroy()", "\t\t\t\t\tif false then\n\t\t\t\t\t\twreck:Destroy()")),
    ("no respawn cap", ("\t\t\t\tif nowMs - slot.lostAt >= delayMs and ModeTeams.LiveBaseVehicles(team) < #slots then",
                        "\t\t\t\tif nowMs - (slot.lostAt or 0) >= 0 then")),
    ("compound ranked past the arena's edge", ("if math.sqrt(halfX * halfX + far * far) > arenaRadius - ARENA_EDGE then", "if false then")),
]
VS_PLANTS = [
    ("Wrecked not set by the destruction path", ('\t\t\t\t\tentry.model:SetAttribute("Wrecked", true)\n', "")),
]
CONFIG_PLANTS = [
    ("respawn delay back at 45", "MatchConfig.TeamBaseVehicles.RespawnDelay = 45"),
]


def config_slots(root):
    """How many base vehicles a team gets: #MatchConfig.TeamBaseVehicles.Slots, read as run() reads it."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals()._R = lua.eval("{ models = {}, mounts = {} }")
    lua.execute(PRELUDE.replace("local R = ...", "local R = _R"))  # MatchConfig uses Vector3 and friends
    lua.execute("MatchConfig = (function() " + luau_to_lua(read(root, "ReplicatedStorage", "Shared", "MatchConfig.lua"))
                + " end)()")
    return int(lua.eval("#MatchConfig.TeamBaseVehicles.Slots"))


def judge_probe(path, root="."):
    text = open(path, encoding="utf-8", errors="replace").read()
    lines = re.findall(r"\[BVR\] (.*)", text)
    problems = []
    get = lambda key: next((l for l in lines if l.startswith(key)), None)  # noqa: E731
    physics = get("PHYSICS")
    if not physics or "running=true" not in physics or float(re.search(r"fell=([\d.]+)", physics).group(1)) < 1:
        problems.append("physics did not step: " + str(physics))
    result = get("RESULT")
    if not result:
        problems.append("no RESULT line")
    else:
        m = re.search(r"home1=(\d+)/(\d+) home2=(\d+)/(\d+) creates1=(\d+) want (\d+) creates2=(\d+) want (\d+) tickErrors=(\d+)", result)
        h1, n1, h2, n2, c1, w1, c2, w2, errs = map(int, m.groups())
        # A base that parked short at Setup is filled by the loop too, so "full" is every slot, and each
        # base is owed one replacement per loss plus one per slot it started without.
        slots = config_slots(root)
        if h1 != slots or h2 != slots:
            problems.append("bases not full: " + result)
        if c1 != w1 + slots - n1 or c2 != w2 + slots - n2:
            problems.append("replacements not one per loss: " + result)
        if errs:
            problems.append("the tick raised errors")
    overlap = get("OVERLAP")
    if not overlap or not overlap.endswith("=0"):
        problems.append("a replacement parked in a person or a wall: " + str(overlap))
    rubble = get("BLOCK RubbleChunk")
    if not rubble or "standing=false" not in rubble:
        problems.append("rubble not cleared: " + str(rubble))
    restart = get("RESTART ticksIn6s")
    if not restart or not (4 <= int(restart.split("=")[1]) <= 8):
        problems.append("not exactly one loop after a restart: " + str(restart))
    replaced = get("RESTART replaced")
    if not replaced or "replaced=true" not in replaced:
        problems.append("no replacement after a restart: " + str(replaced))
    teardown = get("TEARDOWN")
    if not teardown or not teardown.endswith("=0"):
        problems.append("the loop outlived Teardown: " + str(teardown))
    for line in problems:
        print("FAIL probe: " + line)
    print("base_vehicle_respawn_check probe log: %d lines, %d failures" % (len(lines), len(problems)))
    return 1 if problems else 0


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "."
    if "--probe-log" in sys.argv:
        sys.exit(judge_probe(sys.argv[sys.argv.index("--probe-log") + 1], root))
    if "--plant" in sys.argv:
        missed, total = 0, 0
        runs = [(n, {"plant": p}) for n, p in PLANTS] + [(n, {"vs_plant": p}) for n, p in VS_PLANTS] \
            + [(n, {"config_plant": p}) for n, p in CONFIG_PLANTS]
        for name, kwargs in runs:
            failures, _ = run(root, **kwargs)
            print(("CAUGHT  " if failures else "MISSED  ") + name + ("  (" + failures[0] + ")" if failures else ""))
            missed += 0 if failures else 1
            total += 1
        print("base_vehicle_respawn_check plants: %d of %d caught" % (total - missed, total))
        sys.exit(1 if missed else 0)
    failures, examined = run(root)
    for line in failures[:20]:
        print("FAIL " + line)
    print("base_vehicle_respawn_check: %d matches, %d base vehicles examined, %d failures" % (SEEDS, examined, len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
