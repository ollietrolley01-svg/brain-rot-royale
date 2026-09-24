"""Whole-map destructibility (#56) and the per-material break (#71), run on the real Luau source.

    python3 tools/destruct_map_check.py            the checks; exit 1 on any failure
    python3 tools/destruct_map_check.py --plant    also plants each fault and shows the check catches it

Runs DestructibleService, BreakFxClient, MapWilds.Specimens and MapDecor's builders under lupa with
the mocks in tools/destruct_mocks.lua (real CFrame maths, an Instance tree with attributes and a
Destroying signal, a clock the harness moves). Checks, each with a planted fault aimed at the
invariant rather than at a bug:

  coverage   what share of the parts MapWilds and MapDecor build are tagged breakable; every tree,
             shelter, rock and street prop is one pool (one tag across all its parts); undergrowth,
             roads and bridges carry no tag at all
             plant: a group left open after a street prop, so the road built next is tagged
  exclusion  a tag on anything under a Bridge, Road, Footing...; a building's ground-floor slab
             (Destructible = false); anything outside the Map; anything unanchored; a pool wider
             than a building: none of them can be damaged
             plant: the NEVER table emptied
  per blast  a blast reaching every part of a tree hurts the tree ONCE (its pool), not once per part
             plant: the per-blast dedupe removed
  break      a pool at zero loses every member, leaves included; one BreakFx event, capped per pool;
             listeners told once with the box round it; a tagged Model goes whole
  craters    capped per Map, reset by a new Map; never on asphalt, never under something built
             plant: the cap removed
  debris     the client never has more than MAX_ACTIVE pieces, never adds more than MAX_PER_EVENT per
             event, and nothing outlives MAX_LIFE; each family throws pieces in the broken part's
             material (metal also sparks)
             plants: the total cap removed; the settle/lifetime backstop removed

What it can't show: how any of it looks, the real physics of the debris, or the real map's tagged
share (a real map is built from terrain this can't run). tools/destruct_gallery.lua does those in
Studio.
"""

import os
import re
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOCKS = os.path.join(ROOT, "tools", "destruct_mocks.lua")
SERVICE = os.path.join(ROOT, "ServerScriptService", "Modules", "DestructibleService.lua")
CLIENT = os.path.join(ROOT, "StarterPlayerScripts", "BreakFxClient.client.lua")
WILDS = os.path.join(ROOT, "ServerScriptService", "Modules", "MapWilds.lua")
DECOR = os.path.join(ROOT, "ServerScriptService", "Modules", "MapDecor.lua")
COLLAPSE = os.path.join(ROOT, "ServerScriptService", "Modules", "CollapseService.lua")

COMPOUND = re.compile(r"^(\s*)([A-Za-z_][\w.\[\]\"]*)\s*(\+|-|\*|/|%|\^|\.\.)=\s*(.+?)\s*$")


INLINE = re.compile(r"\b([A-Za-z_][\w.]*) (\+|-)= ([\w.]+)\b")


def luau_to_lua(source):
    """Compound assignment is the only Luau these files use that plain Lua lacks."""
    out = []
    for line in source.split("\n"):
        code, comment = line, ""
        cut = line.find(" --")
        if cut >= 0 and line.count('"', 0, cut) % 2 == 0:
            code, comment = line[:cut], line[cut:]
        m = COMPOUND.match(code)
        if m:
            indent, target, op, value = m.groups()
            code = "%s%s = %s %s (%s)" % (indent, target, target, op, value)
        else:
            # Inline, with a single-token right side: `do n += 1 end`.
            code = INLINE.sub(lambda m: "%s = %s %s %s" % (m.group(1), m.group(1), m.group(2), m.group(3)), code)
        out.append(code + comment)
    return "\n".join(out)


def read(path, faults=()):
    with open(path, encoding="utf-8") as f:
        source = f.read()
    for old, new in faults:
        if old not in source:
            raise SystemExit("planted fault did not apply (text not found): %r" % old[:80])
        source = source.replace(old, new, 1)
    return luau_to_lua(source)


class World:
    """One fresh Lua state with the mocks loaded and module stubs wired for require()."""

    def __init__(self, collapse=False):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        with open(MOCKS, encoding="utf-8") as f:
            self.mock = self.lua.execute(f.read())
        setup = self.lua.eval(
            """function(mock)
            mock.modules = {}
            local shared = Instance.new("Folder")
            shared.Name = "Shared"
            shared.Parent = game:GetService("ReplicatedStorage")
            for _, name in ipairs({ "Remotes", "SoundConfig", "BrainrotModels", "BrainrotData", "Rarity", "MatchConfig", "VehicleModels" }) do
                local m = Instance.new("ModuleScript"); m.Name = name; m.Parent = shared
            end
            mock.modulesFolder = Instance.new("Folder")
            for _, name in ipairs({ "CombatService", "Sfx", "MapTerrain" }) do
                local m = Instance.new("ModuleScript"); m.Name = name; m.Parent = mock.modulesFolder
            end
            mock.modules.Remotes = mock.RemotesModule
            mock.modules.CombatService = { ConfirmHit = function() end }
            mock.sounds = {}
            mock.modules.Sfx = { PlayAt = function(name) table.insert(mock.sounds, name) end }
            mock.modules.SoundConfig = { Get = function(name)
                if name == "GoldCrumble" or name == "BodyFall" or name == "CasingTink" or name == "Shatter" then return {} end
                return nil
            end }
            mock.modules.BrainrotModels = setmetatable({}, { __index = function() return function() end end })
            -- MapDecor's parked cars (#16 / #94); nothing here builds one (tools/parked_car_check.py does).
            mock.modules.VehicleModels = setmetatable({}, { __index = function() return function() end end })
            require = function(inst)
                local name = type(inst) == "table" and inst.Name or tostring(inst)
                local found = mock.modules[name]
                if found == nil then error("no mock module for " .. tostring(name)) end
                return found
            end
        end"""
        )
        setup(self.mock)
        if collapse:
            # The real CollapseService, for DestructibleService to find beside it (no physics here: a
            # dropped chunk is unanchored and welded, and lies where it was until it settles).
            self.run("""local mock = ...
                local m = Instance.new("ModuleScript"); m.Name = "CollapseService"; m.Parent = mock.modulesFolder""", self.mock)
            collapse_mod = self.load(COLLAPSE, name="CollapseService")
            self.run("local mock, mod = ...; mock.modules.CollapseService = mod", self.mock, collapse_mod)

    def load(self, path, faults=(), name="chunk"):
        """Runs a module's source with `script` set; returns what it returns."""
        chunk = self.lua.execute(
            "local source, name, mock = ...\n"
            "local fn = assert(load(source, '=' .. name))\n"
            "return fn",
            read(path, faults), name, self.mock,
        )
        runner = self.lua.eval(
            """function(fn, mock)
                script = Instance.new("ModuleScript")
                script.Parent = mock.modulesFolder
                return fn()
            end"""
        )
        return runner(chunk, self.mock)

    def run(self, code, *args):
        return self.lua.execute(luau_to_lua(code), *args)


failures = []


def check(ok, label):
    print("  %s  %s" % ("ok  " if ok else "FAIL", label))
    if not ok:
        failures.append(label)
    return ok


# ---------------------------------------------------------------------------------------------
# Coverage: what the builders tag

COVERAGE_LUA = r"""
local MapWilds, MapDecor, mock = ...
local out = {}
local map = Instance.new("Folder"); map.Name = "Map"; map.Parent = workspace

-- Wilds: one of everything the wilds build places.
local row, entries = MapWilds.Specimens(map, Vector3.new(0, 0, 0), function() return 0, Enum.Material.Grass end, 7)
local total, tagged = 0, 0
out.wilds = {}
for _, entry in ipairs(entries) do
    local parts, tags, solid, solidTagged = 0, {}, 0, 0
    for _, d in ipairs(entry.model:GetDescendants()) do
        if d:IsA("BasePart") then
            parts += 1
            local tag = d:GetAttribute("Destructible")
            if tag ~= nil then tags[tostring(tag)] = true end
            if d.CanCollide or d.CanQuery then
                solid += 1
                if tag ~= nil then solidTagged += 1 end
            end
        end
    end
    local distinct = 0
    local anyTag
    for t in pairs(tags) do distinct += 1; anyTag = t end
    local taggedParts = 0
    for _, d in ipairs(entry.model:GetDescendants()) do
        if d:IsA("BasePart") and d:GetAttribute("Destructible") ~= nil then taggedParts += 1 end
    end
    total += parts
    tagged += taggedParts
    table.insert(out.wilds, { name = entry.name, parts = parts, tagged = taggedParts, groups = distinct, tag = anyTag or "",
        solid = solid, solidTagged = solidTagged })
end
out.wildsTotal, out.wildsTagged = total, tagged

-- Decor: the street furniture and the open-country props, each several times.
local decor = Instance.new("Model"); decor.Name = "Town"; decor.Parent = map
local presets = { Enum.Material.Grass, Enum.Material.Sand, Enum.Material.Rock, Enum.Material.LeafyGrass }
math.randomseed(3)
for i = 1, 160 do
    MapDecor.Prop(decor, Vector3.new(i * 30, 0, 0), { terrainMaterial = presets[(i % 4) + 1] }, nil, function() return 0 end, nil)
end
MapDecor.StreetLamp(decor, Vector3.new(0, 0, 60), Vector3.new(0, 0, 1))
local dTotal, dTagged, sheds = 0, 0, 0
local groups = {}
for _, d in ipairs(decor:GetDescendants()) do
    if d:IsA("BasePart") then
        dTotal += 1
        local tag = d:GetAttribute("Destructible")
        if tag ~= nil then
            dTagged += 1
            groups[tag] = (groups[tag] or 0) + 1
        elseif d.Name == "Wall" or d.Name == "Roof" or d.Name == "Crate" then
            sheds += 1
        end
    end
end
local nGroups = 0
for _ in pairs(groups) do nGroups += 1 end
out.decorTotal, out.decorTagged, out.decorGroups, out.decorNamed = dTotal, dTagged, nGroups, sheds

-- Roads and bridges straight after a prop: nothing they build may carry a tag.
local roads = Instance.new("Model"); roads.Name = "Roads"; roads.Parent = map
MapDecor.StreetLamp(roads, Vector3.new(0, 0, 90), Vector3.new(0, 0, 1))
local lampParts = #roads:GetChildren()
local ok, err = pcall(function()
    MapDecor.Street(roads, Vector3.new(0, 0, 0), Vector3.new(0, 0, 200), 16, 6, {})
end)
out.streetError = ok and "" or tostring(err)
local ok2, err2 = pcall(function()
    MapDecor.Bridge(roads, CFrame.new(0, 5, 300), 60, 8)
end)
out.bridgeError = ok2 and "" or tostring(err2)
local roadParts, roadTagged = 0, 0
for index, d in ipairs(roads:GetChildren()) do
    if index > lampParts and d:IsA("BasePart") then
        roadParts += 1
        if d:GetAttribute("Destructible") ~= nil then roadTagged += 1 end
    end
end
out.roadParts, out.roadTagged = roadParts, roadTagged
return out
"""

# Which specimen kinds must be one breakable pool, and which must stay untouched.
MUST_POOL = re.compile(r"^(Tree_(?!spruceSnowy)|Shelter_|Ground_(log|stump|boulder|cairn|picnic))")
MUST_NOT = re.compile(r"^Ground_(fern|tuft|flowers|mushrooms|shrub)$")


def coverage(decor_faults=(), quiet=False):
    world = World()
    wilds = world.load(WILDS, name="MapWilds")
    decor = world.load(DECOR, decor_faults, name="MapDecor")
    out = world.run(COVERAGE_LUA, wilds, decor, world.mock)
    results = []
    rows = list(out["wilds"].values())
    pooled_ok, pooled_n, bare_ok, bare_n = True, 0, True, 0
    for r in rows:
        name = r["name"]
        if MUST_POOL.match(name):
            pooled_n += 1
            good = r["groups"] == 1 and r["tagged"] == r["parts"]
            if not good:
                pooled_ok = False
                if not quiet:
                    print("      %s: %d/%d parts tagged in %d groups" % (name, r["tagged"], r["parts"], r["groups"]))
        elif MUST_NOT.match(name):
            bare_n += 1
            if r["tagged"] != 0:
                bare_ok = False
    wt, wtag = out["wildsTotal"], out["wildsTagged"]
    dt, dtag = out["decorTotal"], out["decorTagged"]
    if not quiet:
        print("    wilds specimens: %d kinds, %d parts, %d tagged (%.0f%%)" % (len(rows), wt, wtag, 100.0 * wtag / max(wt, 1)))
        print("    decor props x160: %d parts, %d tagged in %d pools (%.0f%%), %d more breakable by name (shed walls/roof/crate)"
              % (dt, dtag, out["decorGroups"], 100.0 * dtag / max(dt, 1), out["decorNamed"]))
        print("    road + bridge after a prop: %d parts, %d tagged%s%s" % (
            out["roadParts"], out["roadTagged"],
            (" [Street: %s]" % out["streetError"][:90]) if out["streetError"] else "",
            (" [Bridge: %s]" % out["bridgeError"][:90]) if out["bridgeError"] else ""))
    results.append(check(pooled_ok and pooled_n >= 30, "every tree/shelter/clutter specimen (%d) is exactly one pool over all its parts" % pooled_n))
    results.append(check(bare_ok and bare_n == 5, "undergrowth specimens (%d) carry no tag" % bare_n))
    results.append(check(dtag > 0 and out["decorGroups"] >= 100, "decor props are tagged (%d pools)" % out["decorGroups"]))
    results.append(check(out["roadParts"] > 0 and out["roadTagged"] == 0,
                         "roads and bridges built after a prop carry no tag (%d parts examined)" % out["roadParts"]))
    return all(results)


# ---------------------------------------------------------------------------------------------
# The service: pools, exclusions, blasts, breaking, craters

SERVICE_LUA = r"""
local DS, mock = ...
local out = {}
local function part(parent, name, size, pos, props)
    local p = Instance.new("Part")
    p.Name = name; p.Size = size; p.CFrame = CFrame.new(pos); p.Anchored = true
    for k, v in pairs(props or {}) do p[k] = v end
    p.Parent = parent
    return p
end
local map = Instance.new("Folder"); map.Name = "Map"; map.Parent = workspace
local woods = Instance.new("Model"); woods.Name = "Woods_1"; woods.Parent = map

-- A tree: trunk plus four leaf balls (not solid, not hittable), all one group; and a second tree.
local function tree(id, x)
    local parts = {}
    local trunk = part(woods, "Trunk", Vector3.new(12, 2.6, 2.6), Vector3.new(x, 6, 0), { Material = Enum.Material.Wood })
    table.insert(parts, trunk)
    for i = 1, 4 do
        table.insert(parts, part(woods, "Leaves", Vector3.new(6, 6, 6), Vector3.new(x + i - 2, 13, 0),
            { Material = Enum.Material.Grass, CanCollide = false, CanQuery = false }))
    end
    for _, p in ipairs(parts) do p:SetAttribute("Destructible", "Tree:" .. id) end
    return parts
end
local treeA = tree("W1", 0)
local treeB = tree("W2", 40)

-- 1. Per blast: every part of tree A in reach, and 30 damage: tree A loses exactly 30 once.
local key = DS.KeyOf(treeA[1])
out.keyIsGroup = key == "Tree:W1"
local before = DS.Damage(treeA[1], 0.0001)  -- makes the entry
mock.raycast = function() return nil end
-- Make the leaves hittable by the overlap for this test, the way a blast reaches everything.
for _, p in ipairs(treeA) do p.CanQuery = true end
DS.DamageInRadius(Vector3.new(0, 9, 0), 30, 30, nil)
-- Probe what's left with one more big hit and read what it took.
local left = DS.Damage(treeA[1], 1e6, nil, Vector3.new(0, 9, -10))
out.health = DS.PoolHealth("Tree", treeA)
out.leftAfterBlast = left
out.treeBAfterBlast = treeB[1].Parent ~= nil

-- 2. Break: every member of A gone, leaves too; B still standing (out of reach? it was at 40 studs)
local gone = 0
for _, p in ipairs(treeA) do if p.Parent == nil then gone += 1 end end
out.membersGone, out.members = gone, #treeA
mock.runDue()
local fx = mock.remotes.BreakFx and mock.remotes.BreakFx.fired or {}
out.fxEvents = #fx
out.fxPieces = fx[1] and #fx[1][1] or 0
local told = 0
DS.OnPartBroken(function() told += 1 end)

-- 2b. A window pane in a tagged cabin still shatters at a touch, and the cabin takes nothing.
local cabinWall = part(woods, "Wall", Vector3.new(10, 8, 1), Vector3.new(-60, 4, 0), { Material = Enum.Material.WoodPlanks })
local cabinPane = part(woods, "WindowGlass", Vector3.new(3, 3, 0.2), Vector3.new(-60, 4, 0), { Material = Enum.Material.Glass })
cabinWall:SetAttribute("Destructible", "Shelter:W9"); cabinPane:SetAttribute("Destructible", "Shelter:W9")
out.paneDealt = DS.Damage(cabinPane, 1, nil, Vector3.new(-60, 4, -10))
out.paneGone = cabinPane.Parent == nil and cabinWall.Parent ~= nil
out.cabinDealt = DS.Damage(cabinWall, 10)
out.cabinMax = DS.PoolHealth("Shelter", { cabinWall })

-- 3. A tagged Model (a TownThemes prop): hitting any part hurts the model; it goes whole.
local props = Instance.new("Model"); props.Name = "Props"; props.Parent = map
local prop = Instance.new("Model"); prop.Name = "FountainProp"; prop.Parent = props
prop:SetAttribute("Destructible", "Prop")
local base = part(prop, "Base", Vector3.new(4, 2, 4), Vector3.new(100, 1, 0), { Material = Enum.Material.Concrete })
local top = part(prop, "Top", Vector3.new(2, 3, 2), Vector3.new(100, 3.5, 0), { Material = Enum.Material.Concrete })
out.modelFromPart = DS.FromPart(top) == top
DS.Damage(top, 1e6)
out.modelGone = prop.Parent == nil and base.Parent == nil
out.toldModel = told

-- 4. Exclusions (on flat ground, so nothing here is over the void).
mock.raycast = mock.flatWorld(0, -72)
local bridge = Instance.new("Model"); bridge.Name = "Bridge"; bridge.Parent = map
local deckRock = part(bridge, "Part", Vector3.new(4, 4, 4), Vector3.new(200, 2, 0))
deckRock:SetAttribute("Destructible", "Rock:X1")
out.bridgeFrom = DS.FromPart(deckRock) ~= nil
out.bridgeDealt = DS.Damage(deckRock, 1e6)
local road = part(map, "Asphalt", Vector3.new(4, 1, 40), Vector3.new(220, 0, 0))
road:SetAttribute("Destructible", "Rock")
out.roadDealt = DS.Damage(road, 1e6)
local house = Instance.new("Model"); house.Name = "House_1"; house.Parent = map
local ground = part(house, "Floor", Vector3.new(20, 1, 20), Vector3.new(300, 0, 0))
ground:SetAttribute("Destructible", false)
local upper = part(house, "Floor", Vector3.new(20, 1, 20), Vector3.new(300, 12, 0))
out.groundFloorFrom = DS.FromPart(ground) ~= nil
out.groundFloorDealt = DS.Damage(ground, 1e6)
out.upperFloorDealt = DS.Damage(upper, 50)
local lobby = Instance.new("Folder"); lobby.Name = "Lobby"; lobby.Parent = workspace
local bench = part(lobby, "Part", Vector3.new(6, 1, 2), Vector3.new(0, 1, 500))
bench:SetAttribute("Destructible", "Bench:D1")
out.lobbyDealt = DS.Damage(bench, 1e6)
local loose = part(map, "Part", Vector3.new(2, 2, 2), Vector3.new(400, 1, 0), { Anchored = false })
loose:SetAttribute("Destructible", "Rock")
out.looseDealt = DS.Damage(loose, 1e6)
local slabA = part(map, "Part", Vector3.new(60, 1, 60), Vector3.new(500, 0, 0))
local slabB = part(map, "Part", Vector3.new(60, 1, 60), Vector3.new(600, 0, 0))
slabA:SetAttribute("Destructible", "Rock:BIG"); slabB:SetAttribute("Destructible", "Rock:BIG")
out.hugeDealt = DS.Damage(slabA, 1e6, nil, Vector3.new(480, 5, -20), Vector3.new(480, 0.5, -20))
-- The four kept whole: a spawn (by name, and anything in a Spawn model), the storm, the lobby.
local spawnModel = Instance.new("Model"); spawnModel.Name = "Spawn"; spawnModel.Parent = map
local bunkerWall = part(spawnModel, "BunkerWall", Vector3.new(10, 8, 1), Vector3.new(800, 4, 0))
local spawnPad = part(map, "SpawnPad", Vector3.new(6, 1, 6), Vector3.new(820, 0.5, 0))
local storm = part(map, "StormWall", Vector3.new(6, 20, 1), Vector3.new(840, 10, 0))
out.spawnDealt = DS.Damage(bunkerWall, 1e6) + DS.Damage(spawnPad, 1e6)
out.stormDealt = DS.Damage(storm, 1e6)
local w1, r1 = DS.Explain(bunkerWall)
local w2, r2 = DS.Explain(storm)
out.keptWhy = w1 .. ":" .. tostring(r1) .. ", " .. w2 .. ":" .. tostring(r2)

-- 4b. Solid attachments (#56): a balcony and its rail come down with the wall that holds them,
-- and a ridge cap stays while either roof slab still holds it, then goes with the last one.
local house2 = Instance.new("Model"); house2.Name = "House_2"; house2.Parent = map
local wall2 = part(house2, "Wall", Vector3.new(12, 10, 1), Vector3.new(700, 5, 0), { Material = Enum.Material.Brick })
local balcony = part(house2, "Balcony", Vector3.new(6, 0.5, 3.2), Vector3.new(700, 8, -2.1), { Material = Enum.Material.Concrete })
local rail = part(house2, "BalconyRail", Vector3.new(6, 1.4, 0.25), Vector3.new(700, 9, -3.6), { Material = Enum.Material.Metal })
local roofA = part(house2, "Roof", Vector3.new(10, 1, 10), Vector3.new(695, 20, 0), { Material = Enum.Material.Slate })
local roofB = part(house2, "Roof", Vector3.new(10, 1, 10), Vector3.new(705, 20, 0), { Material = Enum.Material.Slate })
local ridge = part(house2, "RidgeCap", Vector3.new(1, 0.5, 10), Vector3.new(700, 20.75, 0), { Material = Enum.Material.Slate })
out.balconyShootable = DS.FromPart(balcony) ~= nil and DS.FromPart(ridge) ~= nil
local toldBefore = told
DS.Damage(wall2, 1e6)
out.balconyFell = balcony.Parent == nil and rail.Parent == nil
out.balconyTold = told - toldBefore
DS.Damage(roofA, 1e6)
out.ridgeHeld = ridge.Parent ~= nil
DS.Damage(roofB, 1e6)
out.ridgeFell = ridge.Parent == nil

-- 5. Craters (rockets: blast reach 7, wall damage 150). 450 blasts spread over open grass: the cap.
mock.fills = {}
mock.raycast = mock.flatWorld(0, -72)
for i = 1, 450 do
    DS.DamageInRadius(Vector3.new(1000 + (i % 40) * 30, 0.5, math.floor(i / 40) * 30), 7, 150, nil)
    mock.advance(0.07)
end
out.craters = DS.GroundState.count
out.craterCap = DS.CraterCap
local maxRadius = 0
for _, f in ipairs(mock.fills) do maxRadius = math.max(maxRadius, f[2]) end
out.craterMaxRadius = maxRadius
out.rocketSize, out.grenadeSize, out.smallSize = DS.CraterSize(7, 150), DS.CraterSize(6, 110), DS.CraterSize(3, 40)
-- A new Map: the count starts again, and the same spot takes 40 blasts in a row. It must bottom out
-- at the dig floor (DigDepth under the ground it was built with) and never go under it.
map.Name = "OldMap"; map.Parent = nil
local map2 = Instance.new("Folder"); map2.Name = "Map"; map2.Parent = workspace
mock.fills = {}
mock.raycast = mock.flatWorld(0, -72)
local spot = Vector3.new(0, 0, 0)
local depths, dug = {}, 0
local fillsBefore = #mock.fills
for i = 1, 40 do
    local at = spot + Vector3.new(math.cos(i * 2.4) * (i % 4), 0, math.sin(i * 2.4) * (i % 4))
    local y = mock.surfaceAt(at.X, at.Z)
    local ok = DS.CraterAt(Vector3.new(at.X, y + 0.5, at.Z), 7, 150, map2)
    if ok then dug += 1 end
    table.insert(depths, string.format("%.1f", mock.surfaceAt(spot.X, spot.Z)))
    mock.advance(0.2)
end
out.newMapCraters = #mock.fills > fillsBefore
local deepest = 0
for x = -12, 12, 1 do for z = -12, 12, 1 do deepest = math.min(deepest, mock.surfaceAt(x, z)) end end
out.deepest, out.dugInARow, out.depths = deepest, dug, table.concat(depths, " ")
out.floorY = -DS.DigDepth
-- Getting out: walking out from the bottom in eight directions, the steepest stretch (over 2 studs).
local steepest, riser = 0, 0
for k = 0, 7 do
    local a = k / 8 * math.pi * 2
    local prev = mock.surfaceAt(0, 0)
    for r = 4, 60, 4 do
        local y = mock.surfaceAt(math.cos(a) * r, math.sin(a) * r)
        steepest = math.max(steepest, math.deg(math.atan((y - prev) / 4)))
        prev = y
    end
    prev = mock.surfaceAt(0, 0)
    for r = 0.25, 60, 0.25 do
        local y = mock.surfaceAt(math.cos(a) * r, math.sin(a) * r)
        riser = math.max(riser, y - prev)
        prev = y
    end
end
out.steepest, out.riser = steepest, riser
-- Asphalt; under a roof; water in reach; the map's edge.
local before = DS.GroundState.count
mock.raycast = mock.flatWorld(0, -72, Enum.Material.Asphalt)
DS.DamageInRadius(Vector3.new(200, 0.5, 200), 7, 150, nil)
out.asphaltCraters = DS.GroundState.count - before
local roof = part(map2, "Roof", Vector3.new(10, 1, 10), Vector3.new(300, 0, 300))
local flat = mock.flatWorld(0, -72)
mock.raycast = function(o, d, p)
    if math.abs(o.X - 300) < 5 and math.abs(o.Z - 300) < 5 and d.Y < 0 and o.Y > 0 then
        return { Instance = roof, Position = Vector3.new(o.X, 0.5, o.Z), Material = Enum.Material.Slate }
    end
    return flat(o, d, p)
end
DS.DamageInRadius(Vector3.new(300, 1, 300), 7, 150, nil)
out.builtCraters = DS.GroundState.count - before
mock.raycast = mock.flatWorld(0, -72)
mock.voxel = function(x, y, z) if x >= 390 and x < 420 and y < 0 then return Enum.Material.Water end return nil end
DS.DamageInRadius(Vector3.new(400, 0.5, 400), 7, 150, nil)
mock.voxel = nil
out.waterCraters = DS.GroundState.count - before
mock.raycast = mock.flatWorld(0, -72, Enum.Material.Grass, 600)
DS.DamageInRadius(Vector3.new(597, 0.5, 0), 7, 150, nil)
out.edgeCraters = DS.GroundState.count - before
-- Thin ground: the underside only 12 under the top.
mock.raycast = mock.flatWorld(0, -12)
DS.DamageInRadius(Vector3.new(-300, 0.5, -300), 7, 150, nil)
out.thinCraters = DS.GroundState.count - before
return out
"""

SERVICE_DEDUPE = ("\t\tif key and not seen[key] then\n\t\t\tseen[key] = true\n", "\t\tif key then\n")
SERVICE_NEVER = ("local NEVER = {\n", "local NEVER = {}\nlocal _unusedNever = {\n")
SERVICE_ATTACHED = ("(isTrim(other) or (ATTACHED[other.Name] and other.CanCollide))", "isTrim(other)")
SERVICE_CAP = ("\tif ground.count >= CRATER_CAP then\n\t\treturn false, \"cap\"\n\tend\n", "")
SERVICE_FLOOR = ("\t\t\t\t\ttarget = math.min(target, original - (here - DIG_DEPTH) + rise)\n", "")
SERVICE_FLOOR2 = ("local target = math.min(DIG_DEPTH, depthNow + size * DEEPEN)", "local target = depthNow + size * DEEPEN")


def service(faults=(), quiet=False):
    world = World()
    ds = world.load(SERVICE, faults, name="DestructibleService")
    out = world.run(SERVICE_LUA, ds, world.mock)
    health = out["health"]
    left = out["leftAfterBlast"]
    if not quiet:
        print("    oak-sized tree pool health %d; after one blast of 30 reaching all 5 parts, %s left" % (health, left))
        print("    now breakable: bridge %s, road %s, ground floor (tagged false) %s, a piece of a 120-stud pool %s; upper floor %s"
              % (out["bridgeDealt"], out["roadDealt"], out["groundFloorDealt"], out["hugeDealt"], out["upperFloorDealt"]))
        print("    kept whole: spawn %s, storm %s, lobby %s, unanchored %s (%s)"
              % (out["spawnDealt"], out["stormDealt"], out["lobbyDealt"], out["looseDealt"], out["keptWhy"]))
        print("    craters: %d from 450 rocket blasts (cap %d, largest radius %.1f); sizes rocket %.1f, grenade %.1f, drumlet %.1f"
              % (out["craters"], out["craterCap"], out["craterMaxRadius"], out["rocketSize"], out["grenadeSize"], out["smallSize"]))
        print("    one spot, 40 blasts in a row: %d dug before it bottomed out; deepest ground %.2f (dig floor %.1f); steepest wall %.0f deg;"
              " surface after each: %s" % (out["dugInARow"], out["deepest"], out["floorY"], out["steepest"], out["depths"]))
        print("    refused: asphalt %d, under a roof %d, water in reach %d, map edge %d, thin ground %d"
              % (out["asphaltCraters"], out["builtCraters"] - out["asphaltCraters"], out["waterCraters"] - out["builtCraters"],
                 out["edgeCraters"] - out["waterCraters"], out["thinCraters"] - out["edgeCraters"]))
    r = []
    r.append(check(out["keyIsGroup"], "a tree's parts share one pool key (its tag)"))
    r.append(check(abs(left - (health - 30)) < 0.01, "per blast: pool hurt once (%s left of %d after 30, want %d)" % (left, health, health - 30)))
    r.append(check(out["membersGone"] == out["members"], "a broken pool loses every member, leaves included (%d/%d)" % (out["membersGone"], out["members"])))
    r.append(check(out["treeBAfterBlast"], "the neighbouring tree (another pool) still stands"))
    r.append(check(out["fxEvents"] == 1 and 1 <= out["fxPieces"] <= 10, "one BreakFx event, %d pieces (cap 10 per pool)" % out["fxPieces"]))
    r.append(check(out["paneDealt"] == 1 and out["paneGone"] and out["cabinDealt"] == 10,
                   "a pane in a tagged cabin shatters at a touch on its own; the cabin pool is separate"))
    r.append(check(out["modelFromPart"] and out["modelGone"] and out["toldModel"] == 1,
                   "a tagged Model is hit through any part, goes whole, and listeners hear once"))
    excluded = [out["spawnDealt"], out["stormDealt"], out["lobbyDealt"], out["looseDealt"]]
    r.append(check(all(x == 0 for x in excluded), "spawns, the storm, the lobby and anything unanchored take nothing (5 examined)"))
    now = [out["bridgeDealt"], out["roadDealt"], out["groundFloorDealt"], out["hugeDealt"]]
    r.append(check(all(x > 0 for x in now) and out["bridgeFrom"] and out["groundFloorFrom"],
                   "a bridge, a road, a builder's `false` ground floor and a piece of an oversized pool all take damage now"))
    r.append(check(out["upperFloorDealt"] == 50, "control: an upper floor still takes damage"))
    r.append(check(out["balconyShootable"], "a balcony and a ridge cap can be shot on their own"))
    r.append(check(out["balconyFell"] and out["balconyTold"] >= 3,
                   "a broken wall takes its balcony and rail down, and says so (%d told)" % out["balconyTold"]))
    r.append(check(out["ridgeHeld"] and out["ridgeFell"], "a ridge cap stays while one roof slab holds it, goes with the last"))
    r.append(check(out["craters"] == out["craterCap"], "craters capped per Map (%d of 450 blasts)" % out["craters"]))
    r.append(check(out["rocketSize"] > out["grenadeSize"] > out["smallSize"] >= 1.5 and out["rocketSize"] <= 7,
                   "crater size follows the weapon (rocket > grenade > drumlet), never past 7 studs"))
    r.append(check(out["newMapCraters"] and out["dugInARow"] >= 2 and out["deepest"] >= out["floorY"] - 1e-6
                   and out["deepest"] <= out["floorY"] + 1,
                   "the same spot blasted 40 times deepens down to the dig floor and never under it (deepest %.2f, floor %.1f)"
                   % (out["deepest"], out["floorY"])))
    # (Exact geometry here: the bowl is rings, 2 studs up every 4 out. Real terrain smooths them into a
    # slope: tools/ground_probe.lua measures the built map.)
    r.append(check(out["steepest"] <= 35 and out["riser"] <= 2.05,
                   "you can walk (and drive) out: the steepest 4-stud stretch of the bowl is %.0f degrees (want <= 35), the tallest step %.2f"
                   % (out["steepest"], out["riser"])))
    r.append(check(out["asphaltCraters"] == 1 and out["builtCraters"] == out["asphaltCraters"],
                   "asphalt ground digs like any ground; nothing is dug under something built"))
    r.append(check(out["waterCraters"] == out["builtCraters"] and out["edgeCraters"] == out["waterCraters"]
                   and out["thinCraters"] == out["edgeCraters"], "no crater with water in reach, at the map's edge, or on thin ground"))
    return all(r)


# ---------------------------------------------------------------------------------------------
# Opt-out (Oliver 2026-09-24, "make sure everything is destructible"): untagged parts break, compact
# untagged Models break whole, the kept-whole rules hold, and nothing is left in the air.

OPTOUT_LUA = r"""
local DS, mock = ...
local out = {}
local M = Enum.Material
local function part(parent, name, size, pos, props)
    local p = Instance.new("Part")
    p.Name = name; p.Size = size; p.CFrame = CFrame.new(pos); p.Anchored = true
    for k, v in pairs(props or {}) do p[k] = v end
    p.Parent = parent
    return p
end
-- Flat ground at y = 0 (72 deep), ending 5000 studs out: past that is the void.
mock.raycast = mock.flatWorld(0, -72, M.Grass, 5000)
local map = Instance.new("Folder"); map.Name = "Map"; map.Parent = workspace
local town = Instance.new("Model"); town.Name = "Town"; town.Parent = map

-- 1. An untagged post in a town is a pool of one.
local post = part(town, "Post", Vector3.new(0.6, 8, 0.6), Vector3.new(0, 4, 0), { Material = M.Wood })
out.postPool = DS.KeyOf(post) == post
out.postDealt = DS.Damage(post, 5, nil, Vector3.new(0, 4, -10))

-- 2. An untagged compact Model (a flag: footing, pole, finial, cloth dressing) is one pool, goes whole.
local flag = Instance.new("Model"); flag.Name = "Flag"; flag.Parent = town
local footing = part(flag, "FlagFooting", Vector3.new(1.6, 0.5, 1.6), Vector3.new(20, 0.25, 0), { Material = M.Concrete })
local pole = part(flag, "FlagPole", Vector3.new(0.5, 15, 0.5), Vector3.new(20, 8, 0), { Material = M.Metal })
local finial = part(flag, "FlagFinial", Vector3.new(0.9, 0.9, 0.9), Vector3.new(20, 16, 0), { Material = M.Metal })
local cloth = part(flag, "FlagCloth", Vector3.new(4, 2.5, 0.1), Vector3.new(22.2, 13, 0), { Material = M.Fabric, CanCollide = false, CanQuery = false })
out.flagOnePool = DS.KeyOf(pole) == flag and DS.KeyOf(footing) == flag and DS.KeyOf(finial) == flag
out.footingNotNever = not DS.NeverName("FlagFooting") and not DS.NeverName("Ground_log") and not DS.NeverName("Roads")
DS.Damage(pole, 1e6, nil, Vector3.new(20, 8, -10))
out.flagGone = flag.Parent == nil and cloth.Parent == nil and footing.Parent == nil

-- 3. A building is never one thing: its untagged pieces (a chimney) are pools of one, and the
--    chimney's cap (dressing) goes with it.
local house = Instance.new("Model"); house.Name = "House_1"; house.Parent = town
local wall = part(house, "Wall", Vector3.new(12, 10, 1), Vector3.new(40, 5, 0), { Material = M.Brick })
local chimney = part(house, "Chimney", Vector3.new(3, 5, 3), Vector3.new(40, 12.5, 1.5), { Material = M.Brick })
local cap = part(house, "ChimneyCap", Vector3.new(3.4, 0.4, 3.4), Vector3.new(40, 15.2, 1.5), { CanCollide = false, CanQuery = false })
out.chimneyPool = DS.KeyOf(chimney) == chimney and DS.KeyOf(wall) == wall
DS.Damage(chimney, 1e6, nil, Vector3.new(40, 12, -10))
mock.runDue()
out.chimneyGone = chimney.Parent == nil and cap.Parent == nil and wall.Parent ~= nil

-- 4. Kept whole by design.
local roads = Instance.new("Model"); roads.Name = "Roads"; roads.Parent = map
local surface = part(roads, "RoadSurface", Vector3.new(18, 0.8, 30), Vector3.new(0, 0.4, 100), { Material = M.Asphalt })
local dash = part(roads, "RoadDash", Vector3.new(0.5, 0.1, 5), Vector3.new(0, 0.85, 100), { Material = M.SmoothPlastic })
local lamp = part(roads, "LampPost", Vector3.new(0.6, 12, 0.6), Vector3.new(10, 6, 100), { Material = M.Metal })
local plaza = part(town, "Part", Vector3.new(30, 1, 30), Vector3.new(0, 0.5, 200), { Material = M.Concrete })
local skyDeck = part(town, "Part", Vector3.new(30, 1, 30), Vector3.new(5200, 20, 0), { Material = M.Concrete })
local deck = part(town, "Part", Vector3.new(30, 1, 30), Vector3.new(60, 12, 200), { Material = M.Concrete })
local blocker = part(town, "Part", Vector3.new(4, 20, 40), Vector3.new(100, 10, 200), { Transparency = 1 })
local barrel = Instance.new("Model"); barrel.Name = "ExplosiveBarrel"; barrel.Parent = town
local drum = part(barrel, "Barrel", Vector3.new(4.6, 3.4, 3.4), Vector3.new(120, 2, 200), { Material = M.Metal })
local vendor = Instance.new("Model"); vendor.Name = "RotVendor"; vendor.Parent = town
local cabinet = part(vendor, "VendorBody", Vector3.new(5, 8, 3), Vector3.new(130, 4, 200), { Material = M.Metal })
local outside = Instance.new("Folder"); outside.Name = "Loot"; outside.Parent = workspace
local chest = part(outside, "Chest", Vector3.new(3, 2, 2), Vector3.new(0, 1, 300))
local spawnPad = part(town, "SpawnPad", Vector3.new(6, 1, 6), Vector3.new(160, 0.5, 200))
out.kept = {
    road = DS.FromPart(surface) == surface,
    marking = DS.FromPart(dash) == dash,
    lamp = DS.FromPart(lamp) == lamp,
    groundBreaks = DS.FromPart(plaza) == plaza,
    overVoid = DS.FromPart(skyDeck) == skyDeck,
    upperSlab = DS.FromPart(deck) == deck,
    invisible = DS.FromPart(blocker) == blocker,
    hazard = DS.FromPart(drum) == nil,
    vendor = DS.FromPart(cabinet) == cabinet,
    outside = DS.FromPart(chest) == nil,
    spawn = DS.FromPart(spawnPad) == nil and DS.Damage(spawnPad, 1e6) == 0,
}
-- A road hit once breaks where it is hit: the slab is cut into tiles and only the tile struck is hurt.
local roadBefore = #roads:GetChildren()
local hitAt = Vector3.new(4, 0.8, 110)
DS.Damage(surface, 60, nil, hitAt + Vector3.new(0, 10, 0), hitAt, Vector3.new(0, 1, 0))
local tiles, hurt = 0, 0
for _, c in ipairs(roads:GetChildren()) do
    if c.Name == "RoadSurface" then
        tiles += 1
        if c:GetAttribute("DamageStage") ~= nil or c:GetAttribute("DamageSites") ~= nil then hurt += 1 end
    end
end
mock.runDue()
for _, c in ipairs(roads:GetChildren()) do
    if c.Name == "RoadSurface" and c:GetAttribute("DamageSites") ~= nil then hurt = math.max(hurt, 1) end
end
out.roadTiles, out.roadHurt, out.roadWhole = tiles, hurt, surface.Parent ~= nil
-- A zipline, however long, is one thing: shooting its post snaps the whole line.
local lines = Instance.new("Model"); lines.Name = "Ziplines"; lines.Parent = map
local zip = Instance.new("Model"); zip.Name = "Zipline"; zip.Parent = lines
local zpost = part(zip, "Part", Vector3.new(1.2, 9, 1.2), Vector3.new(900, 4.5, 0), { Material = M.Metal })
part(zip, "Part", Vector3.new(1.2, 9, 1.2), Vector3.new(1000, 4.5, 0), { Material = M.Metal })
local rope = part(zip, "Part", Vector3.new(100, 0.28, 0.28), Vector3.new(950, 9, 0), { Material = M.Fabric, CanCollide = false, CanQuery = false })
out.zipOnePool = DS.KeyOf(zpost) == zip
DS.Damage(zpost, 1e6, nil, Vector3.new(900, 4, -10))
out.zipSnapped = zip.Parent == nil and rope.Parent == nil
local why = {}
for _, p in ipairs({ spawnPad, drum, chest }) do
    local status, reason = DS.Explain(p)
    table.insert(why, p.Name .. "=" .. status .. ":" .. tostring(reason))
end
out.why = table.concat(why, "; ")

-- 5. Nothing left in the air. An awning on two posts stays while either stands, then comes down.
local porch = Instance.new("Model"); porch.Name = "Shop_1"; porch.Parent = town
part(porch, "Wall", Vector3.new(14, 10, 1), Vector3.new(300, 5, 10), { Material = M.Brick })
local posts = {}
for i, x in ipairs({ 294, 300, 306 }) do
    for j, z in ipairs({ -2.2, 2.2 }) do
        posts[#posts + 1] = part(porch, "Part", Vector3.new(0.6, 9, 0.6), Vector3.new(x, 4.5, z), { Material = M.Wood })
    end
end
local awning = part(porch, "Part", Vector3.new(13, 0.5, 5), Vector3.new(300, 9.25, 0), { Material = M.Fabric })
local function down(p) return p.Parent == nil or not p.Anchored end
DS.Damage(posts[1], 1e6, nil, Vector3.new(294, 4, -10))
mock.runDue()
out.awningHeldByOne = not down(awning) and posts[1].Parent == nil
-- The front row (z = -2.2) all goes: what is left holds it along one edge only.
DS.Damage(posts[3], 1e6, nil, Vector3.new(300, 4, -10))
DS.Damage(posts[5], 1e6, nil, Vector3.new(306, 4, -10))
mock.runDue()
out.awningFell = down(awning)
out.awningHow = awning.Parent == nil and "broke" or (awning.Anchored and "stood" or "dropped")
-- A crate on an upper floor comes down with the floor; a bench on the ground beside a broken post stays.
local shed = Instance.new("Model"); shed.Name = "House_2"; shed.Parent = town
local floor2 = part(shed, "Floor", Vector3.new(16, 1, 16), Vector3.new(400, 12, 0), { Material = M.WoodPlanks })
local crate = part(shed, "Crate", Vector3.new(3, 3, 3), Vector3.new(400, 14, 0), { Material = M.Wood })
local stool = part(shed, "Part", Vector3.new(1.5, 1.5, 1.5), Vector3.new(404, 13.25, 3), { Material = M.Wood })
local bench = part(town, "Part", Vector3.new(6, 1.5, 2), Vector3.new(410, 0.75, 20), { Material = M.WoodPlanks })
local lonePost = part(town, "Part", Vector3.new(0.6, 6, 0.6), Vector3.new(413.3, 3, 20), { Material = M.Wood })
DS.Damage(floor2, 1e6, nil, Vector3.new(400, 12, -10))
mock.runDue()
out.crateFell = down(crate) and down(stool)
DS.Damage(lonePost, 1e6, nil, Vector3.new(413, 3, 10))
mock.runDue()
out.benchStayed = bench.Parent ~= nil
-- A stack of 60 blocks, the bottom one shot: the 59 over it are one chunk with nothing under it, and
-- come down together, the frame after.
local tower = Instance.new("Model"); tower.Name = "Stack"; tower.Parent = map
local blocks = {}
for i = 1, 60 do
    blocks[i] = part(tower, "Part", Vector3.new(6, 2, 6), Vector3.new(600, 1 + (i - 1) * 2.02, 0), { Material = M.Concrete })
end
DS.Damage(blocks[1], 1e6, nil, Vector3.new(600, 1, -30))
local frames, worst, left = 0, 0, 60
mock.runDue()
while frames < 20 do
    local before = left
    left = 0
    for _, b in ipairs(blocks) do if b.Parent and b.Anchored then left += 1 end end
    worst = math.max(worst, before - left)
    if left == 0 then break end
    frames += 1
    mock.advance(1 / 30)
end
out.stackLeft, out.stackFrames, out.stackWorst = left, frames, worst
return out
"""

OPTOUT_PREFIX = ('local NEVER_PREFIX = { "Spawn", ', 'local NEVER_PREFIX = { "NoSuchPrefix", ')
OPTOUT_THING = ("\tlocal thing = thingOf(part)\n\tif thing then\n", "\tlocal thing = nil\n\tif thing then\n")
OPTOUT_SLAB = ("\tif subdividable(part) then\n", "\tif false then\n")
OPTOUT_OWNER = ("\t\tlocal why = OWN_HEALTH_MODELS[node.Name]\n", "\t\tlocal why = nil\n")


def optout(faults=(), support=True, quiet=False):
    world = World(collapse=True)
    ds = world.load(SERVICE, faults, name="DestructibleService")
    if not support:
        world.run("local DS = ...; DS.SupportEnabled = false", ds)
    out = world.run(OPTOUT_LUA, ds, world.mock)
    kept = dict(out["kept"])
    if not quiet:
        print("    kept whole: %s" % ", ".join("%s %s" % (k, "ok" if v else "WRONG") for k, v in sorted(kept.items())))
        print("    why: %s" % out["why"])
        print("    stack of 60 on one shot block: %d left standing after %d frames (%d came down in one frame)"
              % (out["stackLeft"], out["stackFrames"], out["stackWorst"]))
    r = []
    r.append(check(out["postPool"] and out["postDealt"] == 5, "an untagged post in a town is a pool of one and takes damage"))
    r.append(check(out["flagOnePool"] and out["flagGone"], "an untagged compact Model (a flag) is one pool and goes whole, dressing too"))
    r.append(check(out["footingNotNever"], "FlagFooting, Ground_log and Roads are not NEVER names (the prefix rule is a word match)"))
    r.append(check(out["chimneyPool"] and out["chimneyGone"], "a building is never one thing: its chimney is a pool of one, and its cap goes with it"))
    r.append(check(all(kept.values()), "roads, markings, slabs over the void, invisible colliders, vendors, lamps, ground and upper"
                   " slabs all break; a spawn pad and anything outside the Map do not; a barrel keeps its own health (%d examined)" % len(kept)))
    r.append(check(out["roadTiles"] > 1 and out["roadHurt"] >= 1 and not out["roadWhole"],
                   "a road hit once is cut into %d tiles where it lies, and only the tile struck is hurt" % out["roadTiles"]))
    r.append(check(out["zipOnePool"] and out["zipSnapped"], "a 100-stud zipline is one thing: shooting its post snaps the whole line"))
    r.append(check(out["awningHeldByOne"] and out["awningFell"], "an awning on six posts stands when one goes, and comes down (%s) when"
                   " its front row is gone" % out["awningHow"]))
    r.append(check(out["crateFell"], "a crate and a stool on an upper floor come down with the floor"))
    r.append(check(out["benchStayed"], "a bench standing on the ground stays when the post beside it breaks"))
    r.append(check(out["stackLeft"] == 0 and out["stackFrames"] <= 1,
                   "a stack of 60 on a shot block comes down as one chunk, the frame after"))
    return all(r)


# ---------------------------------------------------------------------------------------------
# The client: debris caps, lifetime, per-material pieces

CLIENT_LUA = r"""
local mock = ...
local out = {}
local event = mock.remotes.BreakFx
local camera = workspace.CurrentCamera
local folder = workspace:FindFirstChild("BreakFx")
local function live()
    local n = 0
    for _, c in ipairs(folder:GetChildren()) do if c.Name == "BreakPiece" then n += 1 end end
    return n
end
local function batch(n, material, class, size)
    local b = {}
    for i = 1, n do
        table.insert(b, { CFrame.new(i * 2, 5, 0), size or Vector3.new(8, 8, 8), Color3.fromRGB(150, 150, 150), material, class, Vector3.new(0, 5, -20) })
    end
    return b
end
-- One event of 60 big stone pieces, then five more, with no time passing.
event.OnClientEvent:Fire(batch(60, Enum.Material.Concrete, "stone"))
out.firstEvent = live()
local peak = out.firstEvent
for _ = 1, 5 do
    event.OnClientEvent:Fire(batch(60, Enum.Material.Concrete, "stone"))
    peak = math.max(peak, live())
end
out.peak = peak
-- Materials: every piece of a stone break is concrete.
local wrong = 0
for _, c in ipairs(folder:GetChildren()) do
    if c.Name == "BreakPiece" and c.Material ~= Enum.Material.Concrete then wrong += 1 end
end
out.wrongMaterial = wrong
-- Time passes: everything is gone within MAX_LIFE (plus the fade).
mock.advance(8)
out.after8 = live()
-- Per family: a metal break sparks, a wood break throws wood.
mock.emitted = 0
event.OnClientEvent:Fire(batch(1, Enum.Material.Metal, "metal", Vector3.new(6, 3, 12)))
out.metalSparks = mock.emitted
event.OnClientEvent:Fire(batch(1, Enum.Material.WoodPlanks, "wood", Vector3.new(6, 1, 2)))
local wood = 0
for _, c in ipairs(folder:GetChildren()) do
    if c.Name == "BreakPiece" and c.Material == Enum.Material.WoodPlanks then wood += 1 end
end
out.woodPieces = wood
-- Far away: nothing.
local n0 = live()
event.OnClientEvent:Fire({ { CFrame.new(5000, 0, 0), Vector3.new(4, 4, 4), Color3.new(1, 1, 1), Enum.Material.Slate, "stone" } })
out.farAdded = live() - n0
out.sounds = #mock.sounds
return out
"""

CLIENT_CAP = ("\tcount = math.min(count, budget, MAX_ACTIVE - active)\n", "\tcount = math.min(count, budget)\n")
CLIENT_CAP2 = ("\t\t\tif budget > 0 and active < MAX_ACTIVE then\n", "\t\t\tif true then\n")
CLIENT_LIFE = ("local SETTLE_AFTER = 2.2\n", "local SETTLE_AFTER = 1e9\n")


def client(faults=(), quiet=False):
    world = World()
    world.run("local mock = ...; mock.remote('BreakFx')", world.mock)
    world.load(CLIENT, faults, name="BreakFxClient")
    out = world.run(CLIENT_LUA, world.mock)
    if not quiet:
        print("    one event of 60 stone breaks: %d pieces; peak after 6 events: %d; after 8 s: %d"
              % (out["firstEvent"], out["peak"], out["after8"]))
        print("    metal sparks emitted %d; wood pieces %d; far-off break added %d; sounds played %d"
              % (out["metalSparks"], out["woodPieces"], out["farAdded"], out["sounds"]))
    r = []
    r.append(check(out["firstEvent"] <= 70, "one event adds at most MAX_PER_EVENT (70) pieces (%d)" % out["firstEvent"]))
    r.append(check(out["peak"] <= 160, "never more than MAX_ACTIVE (160) pieces alive (peak %d)" % out["peak"]))
    r.append(check(out["after8"] == 0, "nothing outlives its lifetime (%d left after 8 s)" % out["after8"]))
    r.append(check(out["wrongMaterial"] == 0, "debris is made of the broken part's material"))
    r.append(check(out["metalSparks"] > 0 and out["woodPieces"] >= 3, "metal sparks; wood throws wood (%d)" % out["woodPieces"]))
    r.append(check(out["farAdded"] == 0, "a break out of range spawns nothing"))
    return all(r)


def main():
    plant = "--plant" in sys.argv
    print("coverage (MapWilds specimens, MapDecor props, roads and bridges)")
    coverage()
    print("service (DestructibleService)")
    service()
    print("opt-out (everything breaks; kept-whole rules; nothing left in the air)")
    optout()
    print("client (BreakFxClient)")
    client()
    if plant:
        print("\nplanted faults (each must FAIL its check):")
        global failures
        real = list(failures)
        plants = [
            ("a group left open after a street prop tags the road", lambda: coverage(
                [("\t\tcurrentGroup = nil\n\t\tif not results[1] then", "\t\tif not results[1] then")], quiet=True)),
            ("per-blast dedupe removed", lambda: service([SERVICE_DEDUPE], quiet=True)),
            ("NEVER table emptied", lambda: service([SERVICE_NEVER], quiet=True)),
            ("crater cap removed", lambda: service([SERVICE_CAP], quiet=True)),
            ("dig floor removed (a hole through the map)", lambda: service([SERVICE_FLOOR, SERVICE_FLOOR2], quiet=True)),
            ("solid attachments left hanging", lambda: service([SERVICE_ATTACHED], quiet=True)),
            ("support pass switched off (things left in the air)", lambda: optout(support=False, quiet=True)),
            ("NEVER prefixes emptied (a spawn pad breakable)", lambda: optout([OPTOUT_PREFIX], quiet=True)),
            ("compact Models not pooled (a flag's cloth left hanging)", lambda: optout([OPTOUT_THING], quiet=True)),
            ("big parts not cut into tiles (a road hole takes the whole road)", lambda: optout([OPTOUT_SLAB], quiet=True)),
            ("own-health Models not refused (barrels, vendors)", lambda: optout([OPTOUT_OWNER], quiet=True)),
            ("client total cap removed", lambda: client([CLIENT_CAP, CLIENT_CAP2], quiet=True)),
            ("client settle/lifetime backstop removed", lambda: client([CLIENT_LIFE], quiet=True)),
        ]
        caught = 0
        for label, run in plants:
            failures = []
            print("  [plant] %s" % label)
            ok = run()
            if ok:
                print("  PLANT NOT CAUGHT: %s" % label)
            else:
                caught += 1
        failures = real
        print("planted faults caught: %d/%d" % (caught, len(plants)))
        if caught != len(plants):
            failures.append("planted faults")
    print("\n%s: %d failure(s)" % ("FAIL" if failures else "OK", len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
