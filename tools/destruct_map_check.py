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

    def __init__(self):
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

-- 4. Exclusions.
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
out.hugeDealt = DS.Damage(slabA, 1e6)

-- 5. Craters: 100 blasts on open grass; then on asphalt; then over a building; then a new Map.
mock.fills = {}
local grass = { Instance = workspace.Terrain, Position = Vector3.new(0, 0, 0), Material = Enum.Material.Grass }
mock.raycast = function() return grass end
for i = 1, 100 do DS.DamageInRadius(Vector3.new(1000 + i * 20, 1, 0), 10, 1, nil) end
out.craters = #mock.fills
out.craterCap = DS.CraterCap
local maxRadius = 0
for _, f in ipairs(mock.fills) do maxRadius = math.max(maxRadius, f[2]) end
out.craterMaxRadius = maxRadius
map.Name = "OldMap"; map.Parent = nil
local map2 = Instance.new("Folder"); map2.Name = "Map"; map2.Parent = workspace
mock.fills = {}
mock.raycast = function() return { Instance = workspace.Terrain, Position = Vector3.new(0, 0, 0), Material = Enum.Material.Asphalt } end
DS.DamageInRadius(Vector3.new(0, 1, 0), 10, 1, nil)
out.asphaltCraters = #mock.fills
local roof = part(map2, "Roof", Vector3.new(10, 1, 10), Vector3.new(0, 0, 0))
mock.raycast = function() return { Instance = roof, Position = Vector3.new(0, 0, 0), Material = Enum.Material.Slate } end
DS.DamageInRadius(Vector3.new(0, 1, 0), 10, 1, nil)
out.builtCraters = #mock.fills
mock.raycast = function() return grass end
DS.DamageInRadius(Vector3.new(0, 1, 0), 10, 1, nil)
out.newMapCraters = #mock.fills
return out
"""

SERVICE_DEDUPE = ("\t\tif key and not seen[key] then\n\t\t\tseen[key] = true\n", "\t\tif key then\n")
SERVICE_NEVER = ("local NEVER = {\n", "local NEVER = {}\nlocal _unusedNever = {\n")
SERVICE_CAP = ("\tif craterCount >= CRATER_CAP then\n\t\treturn false\n\tend\n", "")


def service(faults=(), quiet=False):
    world = World()
    ds = world.load(SERVICE, faults, name="DestructibleService")
    out = world.run(SERVICE_LUA, ds, world.mock)
    health = out["health"]
    left = out["leftAfterBlast"]
    if not quiet:
        print("    oak-sized tree pool health %d; after one blast of 30 reaching all 5 parts, %s left" % (health, left))
        print("    exclusions dealt: bridge %s, road %s, ground floor %s, lobby %s, unanchored %s, 120-stud pool %s; upper floor %s"
              % (out["bridgeDealt"], out["roadDealt"], out["groundFloorDealt"], out["lobbyDealt"], out["looseDealt"],
                 out["hugeDealt"], out["upperFloorDealt"]))
        print("    craters: %d from 100 blasts (cap %d, largest radius %.1f); asphalt %d, under a roof %d, new Map %d"
              % (out["craters"], out["craterCap"], out["craterMaxRadius"], out["asphaltCraters"],
                 out["builtCraters"] - out["asphaltCraters"], out["newMapCraters"] - out["builtCraters"]))
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
    excluded = [out["bridgeDealt"], out["roadDealt"], out["groundFloorDealt"], out["lobbyDealt"], out["looseDealt"], out["hugeDealt"]]
    r.append(check(all(x == 0 for x in excluded) and not out["bridgeFrom"] and not out["groundFloorFrom"],
                   "bridge, road, ground floor, lobby, unanchored and oversized pools take nothing (6 examined)"))
    r.append(check(out["upperFloorDealt"] == 50, "control: an upper floor still takes damage"))
    r.append(check(out["craters"] == out["craterCap"], "craters capped per Map (%d of 100 blasts)" % out["craters"]))
    r.append(check(out["craterMaxRadius"] <= 4.5, "crater radius at most 4.5 studs"))
    r.append(check(out["asphaltCraters"] == 0 and out["builtCraters"] == 0, "no crater on asphalt or under something built"))
    r.append(check(out["newMapCraters"] - out["builtCraters"] == 1, "a new Map resets the crater count"))
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
