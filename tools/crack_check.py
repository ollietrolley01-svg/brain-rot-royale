"""#71 cracking: damage never fades anything toward clear, and every material cracks its own way.

    python3 tools/crack_check.py            the checks and the planted faults; exit 1 on any failure

Runs the REAL source of DestructibleService, CrackFxClient, BreakFxClient and GlassFxClient together
in one lupa world (tools/destruct_mocks.lua: real CFrame maths, an Instance tree with attributes and
a Destroying signal, a clock the harness moves), the server's events played straight into the
clients. Checks, each with a planted fault aimed at the invariant rather than at a bug:

  F  NEVER FADES. Every write to Transparency or LocalTransparencyModifier on any part under the Map
     is watched, whoever makes it (server or any of the three clients, directly or by a tween). A
     part still standing must never have either go UP. Exercised over every damage path: bullets
     through CombatService.DamageDestructible (exact hit point and normal), hits with only a `from`,
     blasts (DamageInRadius), a building's named Wall/Floor/Roof/Crate/Stair parts, the balcony and
     rail that fall with their wall, panes shattered directly, by a blast and by their wall
     breaking, a tagged group (a tree), a tagged part, a tagged Model (a parked car of metal, glass,
     fabric, plastic and neon), a lone DestructibleHealth part; every material family.
     plants: the old server fade (Transparency bumped at each stage), and a client-side one
             (LocalTransparencyModifier raised as the cracks are drawn)
  S  STAGES. A pool's DamageStage is 0 above 75% health, 1 at or below 75%, 2 at or below 50%, 3 at
     or below 25%, stepping on exactly the hit that crosses (hits of 1% of max, and hits landing
     exactly on 75/50/25); it never goes down; at most three writes per pool, on the Model for a
     Model pool; hit sites at most 4 per part and 8 per pool, their attribute rewritten only when
     one opens; one DamageFx record per part per frame, at most HITS_PER_FRAME per event.
     plants: `<=` turned into `<` at the thresholds; the per-part site cap removed
  C  CRACKS ON THE HIT FACE, PER MATERIAL. For each family (wood, stone, brick, metal, glass,
     foliage, plastic, cloth) a turned part is hit on one face and taken through the four stages:
     every piece CrackFxClient draws lies on that face (at most 1.6 studs proud of it, inside its
     edges, near the hit); each stage keeps every piece of the last and adds more; each hit throws
     a burst and plays a sound; each family draws its own look (stone: dark branching lines and
     chips; brick: lines along the courses and loose bricks; wood: splits along the grain,
     splinters, a loose board; metal: dent rings, bright scratches, a peeled plate; glass: white
     web lines; foliage: drooping twigs; plastic: whitened lines; cloth: a tear and a flap). A
     player who joins after the damage (the Damaged tag) draws the same pieces. When the part
     breaks, its marks are gone that instant and its BreakFx debris carries the cracks; a Map
     taken away takes every mark with it at the next sweep. The client's family table agrees with
     the server's (brick apart).
     plants: the face frame put on the opposite face; brick drawn as stone; the Destroying cleanup
             removed; the out-of-workspace sweep removed; one entry of the client family table wrong
  K  CAPS. 200 damaged parts, 4 sites each, at 25%: at most MAX_BUILT parts drawn (the nearest),
     MAX_PIECES pieces, PER_SITE_CAP per site, MAX_TRICKLES dust emitters, MAX_BITS flying bits (all
     gone after their life); nothing drawn past DROP_BEYOND.
     plant: the MAX_BUILT cap removed
  G  GLASS. A pane shatters at one touch and never fades first; the GlassShatter record carries the
     impact point; GlassFxClient draws a spiderweb from it on the pane's plane, gone after WEB_TIME
     when the shards fly.

What it can't show: how any of it looks (crack widths, colours against real materials, whether the
brick courses line up with Roblox's Brick texture), real physics, real replication order. The
gallery tools/crack_gallery.lua renders every family at 100/75/50/25% and breaking.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from destruct_map_check import ROOT, SERVICE, World, luau_to_lua  # noqa: E402

CRACK = os.path.join(ROOT, "StarterPlayerScripts", "CrackFxClient.client.lua")
BREAK = os.path.join(ROOT, "StarterPlayerScripts", "BreakFxClient.client.lua")
GLASS = os.path.join(ROOT, "StarterPlayerScripts", "GlassFxClient.client.lua")

CRACK_EXPORT = (
    "\nreturn { tracked = tracked, totals = totals, bits = bits, FAMILY = FAMILY, sweep = sweep, profiles = PROFILES,"
    " anims = anims, counts = counts,"
    " caps = { MAX_BUILT = MAX_BUILT, MAX_PIECES = MAX_PIECES, PER_SITE_CAP = PER_SITE_CAP, MAX_ANIMATING = MAX_ANIMATING,"
    " MAX_TRICKLES = MAX_TRICKLES, MAX_BITS = MAX_BITS, MAX_PUFFS = MAX_PUFFS, BUILD_WITHIN = BUILD_WITHIN, DROP_BEYOND = DROP_BEYOND } }\n"
)


def source(path, faults=(), export=""):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    for old, new in faults:
        if old not in text:
            raise SystemExit("planted fault did not apply (text not found): %r" % old[:80])
        text = text.replace(old, new, 1)
    return luau_to_lua(text + export)


def load(world, path, faults=(), export="", name="chunk"):
    chunk = world.lua.execute(
        "local source, name = ...\nreturn assert(load(source, '=' .. name))", source(path, faults, export), name)
    runner = world.lua.eval(
        """function(fn, mock)
            script = Instance.new("LocalScript")
            script.Parent = mock.modulesFolder
            return fn()
        end"""
    )
    return runner(chunk, world.mock)


# Shared Lua: the Transparency watch, tags, and helpers every scenario uses.
PRELUDE = r"""
local mock = ...
local H = { fails = {}, writes = 0, watched = {}, tagged = {} }
function H.fail(tag, why) table.insert(H.fails, tag .. ": " .. why) end

-- Tags: the server's AddTag is recorded so the client's GetTagged finds what it tagged.
local collection = game:GetService("CollectionService")
local added, removed = mock.signal(), mock.signal()
collection.GetTagged = function(_, tag)
    local out = {}
    for inst, tags in pairs(H.tagged) do if tags[tag] and inst.Parent then table.insert(out, inst) end end
    return out
end
collection.GetInstanceAddedSignal = function() return added end
collection.GetInstanceRemovedSignal = function() return removed end
local probe = Instance.new("Part")
local I = getmetatable(probe)
I.AddTag = function(inst, tag)
    H.tagged[inst] = H.tagged[inst] or {}
    if not H.tagged[inst][tag] then H.tagged[inst][tag] = true; added:Fire(inst) end
end

-- F: every write to a watched part's Transparency or LocalTransparencyModifier, from anyone.
local rawNewIndex = I.__newindex
I.__newindex = function(inst, key, value)
    if (key == "Transparency" or key == "LocalTransparencyModifier") and H.watched[inst] then
        H.writes += 1
        local old = rawget(inst, "__props")[key] or 0
        if type(value) == "number" and value > old + 1e-9 and inst.Parent ~= nil then
            H.fail("F", string.format("%s (%s) %s went %.2f -> %.2f while still standing", inst.Name,
                inst.Material.Name, key, old, value))
        end
    end
    rawNewIndex(inst, key, value)
end

H.map = Instance.new("Folder"); H.map.Name = "Map"; H.map.Parent = workspace
function H.part(parent, name, size, cframe, material, props)
    local p = Instance.new("Part")
    p.Name = name; p.Size = size; p.CFrame = cframe; p.Anchored = true; p.Material = material
    p.Color = Color3.fromRGB(150, 130, 110)
    for k, v in pairs(props or {}) do p[k] = v end
    p.Parent = parent
    H.watched[p] = true
    return p
end
-- Plays whatever the server sent this frame into the clients, the way the network would.
H.played = { DamageFx = 0, BreakFx = 0, GlassShatter = 0 }
function H.deliver()
    mock.runDue()
    for name, count in pairs(H.played) do
        local remote = mock.remotes[name]
        if remote then
            for index = count + 1, #remote.fired do
                remote.OnClientEvent:Fire(table.unpack(remote.fired[index]))
            end
            H.played[name] = #remote.fired
        end
    end
end
workspace.CurrentCamera.CFrame = CFrame.new(0, 10, -40)
-- Flat ground at y = 0, 72 deep, so nothing here stands over the void.
mock.raycast = mock.flatWorld(0, -72)
return H
"""

# ---------------------------------------------------------------------------------------------
# F: never fades, over every damage path and material

FADE_LUA = r"""
local DS, H, mock = ...
local combat = mock.modules.CombatService
local calls = 0
local function shoot(part, amount, offset)
    -- A bullet: exact point on the face towards the camera side, and its normal.
    local cf = part.CFrame
    local at = cf * Vector3.new(offset or 0.5, 0.3, -part.Size.Z / 2)
    calls += 1
    combat.DamageDestructible(nil, part, amount, at + cf.LookVector * 30, at, cf.LookVector)
    H.deliver()
    mock.advance(0.05)
end

-- A house: named parts of every family, a pane in the wall, a balcony and rail on the wall.
local house = Instance.new("Model"); house.Name = "House_1"; house.Parent = H.map
local M = Enum.Material
local wall = H.part(house, "Wall", Vector3.new(16, 10, 1), CFrame.new(0, 5, 0), M.Concrete)
local brick = H.part(house, "Wall", Vector3.new(16, 10, 1), CFrame.new(30, 5, 0) * CFrame.Angles(0, 0.5, 0), M.Brick)
local floor = H.part(house, "Floor", Vector3.new(16, 1, 16), CFrame.new(60, 10, 0), M.WoodPlanks)
local roof = H.part(house, "Roof", Vector3.new(16, 1, 16), CFrame.new(90, 20, 0), M.Slate)
local crate = H.part(house, "Crate", Vector3.new(4, 4, 4), CFrame.new(120, 2, 0), M.Wood)
local stair = H.part(house, "Stair", Vector3.new(4, 8, 12), CFrame.new(150, 4, 0), M.Concrete)
local pane = H.part(house, "WindowGlass", Vector3.new(3, 3, 0.2), CFrame.new(3, 5, 0), M.Glass, { Transparency = 0.45 })
local balcony = H.part(house, "Balcony", Vector3.new(6, 0.5, 3.2), CFrame.new(-3, 8, -2.1), M.Concrete)
local rail = H.part(house, "BalconyRail", Vector3.new(6, 1.4, 0.25), CFrame.new(-3, 9, -3.6), M.Metal)
local sill = H.part(house, "Sill", Vector3.new(3.4, 0.3, 0.4), CFrame.new(3, 3.3, -0.6), M.Concrete, { CanCollide = false, CanQuery = false })

-- Tagged: a tree (group), a rock (single part), a parked car (Model pool), a lone plate.
local woods = Instance.new("Model"); woods.Name = "Woods"; woods.Parent = H.map
local trunk = H.part(woods, "Trunk", Vector3.new(2.6, 12, 2.6), CFrame.new(200, 6, 0), M.Wood)
local leaves = H.part(woods, "Leaves", Vector3.new(8, 6, 8), CFrame.new(200, 14, 0), M.LeafyGrass, { CanCollide = false })
trunk:SetAttribute("Destructible", "Tree:T1"); leaves:SetAttribute("Destructible", "Tree:T1")
local rock = H.part(woods, "Boulder", Vector3.new(5, 4, 5), CFrame.new(230, 2, 0), M.Rock)
rock:SetAttribute("Destructible", "Rock")
local car = Instance.new("Model"); car.Name = "ParkedCar"; car.Parent = H.map
car:SetAttribute("DestructibleHealth", 240)
local body = H.part(car, "Body", Vector3.new(6, 3, 12), CFrame.new(260, 2, 0), M.Metal)
local glass = H.part(car, "Window", Vector3.new(5, 1.5, 0.2), CFrame.new(260, 4, -3), M.Glass, { Transparency = 0.3 })
local seat = H.part(car, "Seat", Vector3.new(2, 1, 2), CFrame.new(260, 3, 0), M.Fabric)
local bumper = H.part(car, "Bumper", Vector3.new(6, 0.6, 0.5), CFrame.new(260, 1, -6.2), M.Plastic)
local light = H.part(car, "Headlight", Vector3.new(1, 0.5, 0.2), CFrame.new(262, 2, -6.1), M.Neon)
local plate = H.part(H.map, "Part", Vector3.new(6, 3, 6), CFrame.new(300, 1.5, 0), M.Foil)
plate:SetAttribute("DestructibleHealth", 90)

local transparencyBefore = {}
for part in pairs(H.watched) do transparencyBefore[part] = part.Transparency end

-- Bullets, in steps of 7% of max, to breaking: named parts of every family.
for _, part in ipairs({ wall, brick, floor, roof, crate, stair, plate, body }) do
    local guard = 0
    while part.Parent and guard < 40 do
        shoot(part, 11, (guard % 5) - 2)
        guard += 1
    end
end
-- Hits with only a `from` (bots, vehicle guns without the proposed edit) on the rock.
while rock.Parent do
    calls += 1
    DS.Damage(rock, 9, nil, rock.Position + Vector3.new(0, 1, -20))
    H.deliver(); mock.advance(0.05)
end
-- Blasts on the tree until it goes (each pool once per blast).
leaves.CanQuery = true
while trunk.Parent do
    calls += 1
    DS.DamageInRadius(Vector3.new(200, 8, -4), 12, 17, nil)
    H.deliver(); mock.advance(0.05)
end
local out = {}
out.balconyGone = balcony.Parent == nil and rail.Parent == nil and sill.Parent == nil and pane.Parent == nil
-- Panes: one straight on, one by a blast (ProjectileService's glassInRadius path).
local pane2 = H.part(house, "WindowGlass", Vector3.new(3, 3, 0.2), CFrame.new(40, 5, 20), M.Glass, { Transparency = 0.45 })
local pane3 = H.part(house, "WindowGlass", Vector3.new(3, 3, 0.2), CFrame.new(50, 5, 20), M.Glass, { Transparency = 0.45 })
calls += 2
combat.DamageDestructible(nil, pane2, 1, Vector3.new(40, 5, -10), Vector3.new(40.5, 5.5, 19.9), Vector3.new(0, 0, -1))
DS.Damage(pane3, 1, nil, Vector3.new(50, 5, 15))
H.deliver(); mock.advance(1)
out.panesGone = pane2.Parent == nil and pane3.Parent == nil
out.calls = calls
out.writes = H.writes
local standing = 0
for part in pairs(H.watched) do if part.Parent then standing += 1 end end
out.standing = standing
local watched = 0
for _ in pairs(H.watched) do watched += 1 end
out.watched = watched
return out
"""

# ---------------------------------------------------------------------------------------------
# S: stages at the right health; sites and events capped

STAGE_LUA = r"""
local DS, H, mock = ...
local M = Enum.Material
local out = { steps = 0, pools = 0 }
local writes = {}
local I = getmetatable(H.map)
local rawSet = I.SetAttribute
I.SetAttribute = function(inst, name, value)
    writes[inst] = writes[inst] or {}
    writes[inst][name] = (writes[inst][name] or 0) + 1
    return rawSet(inst, name, value)
end
local function expected(fraction)
    if fraction <= 0.25 then return 3 elseif fraction <= 0.5 then return 2 elseif fraction <= 0.75 then return 1 end
    return 0
end
local function walk(label, carrier, hitPart, max, step)
    out.pools += 1
    local health = max
    local last = 0
    while health > step + 1e-9 do
        DS.Damage(hitPart, step, nil, hitPart.Position + Vector3.new(0, 0, -30))
        health -= step
        out.steps += 1
        local stage = carrier:GetAttribute("DamageStage") or 0
        local want = expected(health / max)
        if stage ~= want then
            H.fail("S", string.format("%s at %.0f%% health is stage %d, expected %d", label, health / max * 100, stage, want))
            return
        end
        if stage < last then H.fail("S", label .. " went back a stage") return end
        last = stage
    end
    local count = writes[carrier] and writes[carrier].DamageStage or 0
    if count > 3 then H.fail("S", label .. " stage written " .. count .. " times") end
end
-- A wall in hits of 1% (100 health), a wall in hits landing exactly on 75/50/25 (4 x 25).
local house = Instance.new("Model"); house.Name = "House_S"; house.Parent = H.map
local a = H.part(house, "Wall", Vector3.new(10, 8, 1), CFrame.new(0, 4, 400), M.Concrete)
walk("wall in 1% hits", a, a, 100, 1)
local b = H.part(house, "Wall", Vector3.new(10, 8, 1), CFrame.new(20, 4, 400), M.Brick)
walk("wall in 25% hits", b, b, 100, 25)
-- A Model pool: the stage is on the Model, not on its parts.
local car = Instance.new("Model"); car.Name = "ParkedCar"; car.Parent = H.map
car:SetAttribute("DestructibleHealth", 200)
local body = H.part(car, "Body", Vector3.new(6, 3, 12), CFrame.new(60, 2, 400), M.Metal)
H.part(car, "Wheel", Vector3.new(1, 2, 2), CFrame.new(57, 1, 396), M.Plastic)
walk("car in 2% hits", car, body, 200, 4)
if body:GetAttribute("DamageStage") ~= nil then H.fail("S", "a Model pool's stage was written on its part") end
-- A tagged group: every member carries it.
local woods = Instance.new("Model"); woods.Name = "Woods_S"; woods.Parent = H.map
local trunk = H.part(woods, "Trunk", Vector3.new(2, 10, 2), CFrame.new(100, 5, 400), M.Wood)
local crown = H.part(woods, "Leaves", Vector3.new(6, 5, 6), CFrame.new(100, 12, 400), M.Grass, { CanCollide = false })
trunk:SetAttribute("Destructible", "Tree:S1"); crown:SetAttribute("Destructible", "Tree:S1")
local max = DS.PoolHealth("Tree", { trunk, crown })
walk("tree in 5% hits", trunk, trunk, max, max / 20)
if crown:GetAttribute("DamageStage") ~= trunk:GetAttribute("DamageStage") then H.fail("S", "a tree's leaves don't carry its stage") end
mock.runDue()

-- Sites: a slab hit from 12 directions: at most 4 sites, the attribute written once per site.
local slab = H.part(H.map, "Part", Vector3.new(8, 8, 8), CFrame.new(0, 4, 500), M.Concrete)
slab:SetAttribute("DestructibleHealth", 5000)
local dirs = { {1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1},{1,1,0},{-1,0,1},{0,1,-1},{1,0,1},{-1,1,0},{0,-1,-1} }
for _, d in ipairs(dirs) do
    DS.Damage(slab, 1, nil, slab.Position + Vector3.new(d[1], d[2], d[3]) * 20)
    mock.runDue()
end
local text = slab:GetAttribute("DamageSites") or ""
local sites = 0
for _ in string.gmatch(text, "[^;]+") do sites += 1 end
out.sites = sites
out.siteWrites = writes[slab] and writes[slab].DamageSites or 0
if sites > DS.MaxSitesPerPart then H.fail("S", "a part carries " .. sites .. " sites") end
if out.siteWrites > sites then H.fail("S", "sites attribute written " .. out.siteWrites .. " times for " .. sites .. " sites") end
-- The same spot again: no new site, no write.
local before = writes[slab].DamageSites
DS.Damage(slab, 1, nil, slab.Position + Vector3.new(20, 0, 0))
mock.runDue()
if writes[slab].DamageSites ~= before then H.fail("S", "a repeat hit on a site rewrote the attribute") end

-- Events: 60 parts hit 3 times each in one frame: one record per part, at most HITS_PER_FRAME.
local fired0 = #mock.remotes.DamageFx.fired
local row = {}
for i = 1, 60 do
    local p = H.part(H.map, "Part", Vector3.new(2, 2, 2), CFrame.new(i * 3, 1, 600), M.Wood)
    p:SetAttribute("DestructibleHealth", 500)
    row[i] = p
end
for _ = 1, 3 do for i = 1, 60 do DS.Damage(row[i], 1, nil, row[i].Position + Vector3.new(0, 0, -10)) end end
mock.runDue()
local events = #mock.remotes.DamageFx.fired - fired0
local batch = mock.remotes.DamageFx.fired[#mock.remotes.DamageFx.fired][1]
local seen, dupes = {}, 0
for _, r in ipairs(batch) do if seen[r[1]] then dupes += 1 end seen[r[1]] = true end
out.events, out.records, out.dupes, out.lastCount = events, #batch, dupes, batch[1][4]
if events ~= 1 then H.fail("S", events .. " DamageFx events for one frame") end
if #batch > DS.HitsPerFrame then H.fail("S", #batch .. " records in one event") end
if dupes > 0 then H.fail("S", dupes .. " parts sent twice in one event") end
if batch[1][4] ~= 3 then H.fail("S", "three hits on a part in a frame counted " .. tostring(batch[1][4])) end
return out
"""

# ---------------------------------------------------------------------------------------------
# C: per material, on the hit face, growing, bursting, cleaned up

MATERIALS_LUA = r"""
local DS, H, mock, CF, names, signatures = ...
local out = { rows = {}, pieces = 0 }
local folder = workspace:FindFirstChild("CrackFx")
local function kids(name)
    local n = 0
    for _, c in ipairs(folder:GetChildren()) do if c.Name == name then n += 1 end end
    return n
end
local function key(p)
    local q = p.Position
    return string.format("%.2f,%.2f,%.2f", q.X, q.Y, q.Z)
end
for index, name in ipairs(names) do
    local material = Enum.Material[name]
    local x = index * 40
    local cf = CFrame.new(x, 6, 0) * CFrame.Angles(0, 0.6, 0.15)
    local part = H.part(H.map, "Part", Vector3.new(12, 10, 1), cf, material)
    part:SetAttribute("DestructibleHealth", 400)
    -- Close enough for every detail (LOD near) and for the stage changes to play.
    workspace.CurrentCamera.CFrame = CFrame.new(cf * Vector3.new(0, 0, -25))
    local from = cf * Vector3.new(2.2, 1.1, -30)
    local steps = { 20, 90, 100, 100 }   -- to 95%, 72.5%, 47.5%, 22.5%: stages 0, 1, 2, 3
    local previous, counts = nil, {}
    local sounds0 = #mock.sounds
    local row = { name = name }
    for stage, amount in ipairs(steps) do
        local bits0 = #CF.bits + kids("CrackPuff")
        DS.Damage(part, amount, nil, from)
        H.deliver()
        local burst = #CF.bits + kids("CrackPuff") - bits0
        mock.advance(1.2)
        local record = CF.tracked[part]
        if not record then H.fail("C", name .. ": not tracked after a hit") break end
        if record.stage ~= stage - 1 then H.fail("C", name .. ": client stage " .. record.stage .. ", expected " .. (stage - 1)) end
        if burst <= 0 then H.fail("C", name .. ": hit " .. stage .. " threw no burst") end
        local pieces = {}
        for _, piece in ipairs(record.pieces) do
            pieces[key(piece)] = true
            out.pieces += 1
            -- On the hit face (-Z, local), proud of it by no more than 2, inside its edges, near the hit.
            local l = part.CFrame:PointToObjectSpace(piece.Position)
            local proud = -l.Z - 0.5
            if proud < -0.25 or proud > 2.0 or math.abs(l.X) > 6 + 1.2 or math.abs(l.Y) > 5 + 1.2 then
                H.fail("C", string.format("%s: a %s at local (%.2f, %.2f, %.2f) is off the hit face", name, piece.Name, l.X, l.Y, l.Z))
                break
            end
            if piece.CanCollide or piece.CanQuery or piece.CastShadow or not piece.Anchored then
                H.fail("C", name .. ": a crack piece collides, casts or can be hit") break
            end
        end
        local n = #record.pieces
        counts[stage] = n
        if n == 0 then H.fail("C", name .. ": nothing drawn at stage " .. (stage - 1)) end
        if previous then
            for k in pairs(previous) do
                if not pieces[k] then H.fail("C", name .. ": stage " .. (stage - 1) .. " lost a piece of the stage before") break end
            end
            if n <= counts[stage - 1] then H.fail("C", name .. ": stage " .. (stage - 1) .. " added nothing") end
        end
        previous = pieces
    end
    local heard = #mock.sounds - sounds0
    if heard < 8 then H.fail("C", name .. ": " .. heard .. " sound layers for 4 hits (want two a hit)") end
    -- Its look at 25%: the set of what it drew.
    local record = CF.tracked[part]
    local seen = {}
    for _, p in ipairs(record and record.pieces or {}) do seen[p.Name] = (seen[p.Name] or 0) + 1 end
    local list = {}
    for n in pairs(seen) do table.insert(list, n) end
    table.sort(list)
    row.look = table.concat(list, ",")
    row.drawn = record and #record.pieces or 0
    row.heard = heard
    local missing = {}
    for _, want in ipairs(signatures[name] or {}) do
        if not seen[want] then table.insert(missing, want) end
    end
    if #missing > 0 then H.fail("C", name .. " doesn't look like " .. name .. ": no " .. table.concat(missing, ", ") .. " (drew " .. row.look .. ")") end
    -- Breaking: the marks go that instant; the debris carries the cracks.
    local held = {}
    for _, p in ipairs(record and record.pieces or {}) do table.insert(held, p) end
    DS.Damage(part, 1e6, nil, from)
    for _, p in ipairs(held) do
        if p.Parent then H.fail("C", name .. ": a crack outlived its part") break end
    end
    if CF.tracked[part] then H.fail("C", name .. ": still tracked after breaking") end
    H.deliver()
    local sent = mock.remotes.BreakFx.fired[#mock.remotes.BreakFx.fired][1]
    if sent[1][7] ~= 3 then H.fail("C", name .. ": BreakFx sent stage " .. tostring(sent[1][7])) end
    out.rows[index] = row
    mock.advance(6)
end
out.totalsAfter = CF.totals.pieces
return out
"""

# How each stage change plays, per material, near: right after the stage rises the new pieces are
# mid-arrival; by 1.2 s every one is where it rests; the pieces nearer the hit start first.
ANIM_LUA = r"""
local DS, H, mock, CF, name = ...
local material = Enum.Material[name]
local cf = CFrame.new(5000, 6, 0) * CFrame.Angles(0, 0.4, 0)
local part = H.part(H.map, "Part", Vector3.new(12, 10, 1), cf, material)
part:SetAttribute("DestructibleHealth", 400)
workspace.CurrentCamera.CFrame = CFrame.new(cf * Vector3.new(0, 0, -20))
local from = cf * Vector3.new(1.5, 0.8, -30)
DS.Damage(part, 110, nil, from)   -- to 72.5%: stage 1, drawn
H.deliver()
mock.advance(1.2)
local record = CF.tracked[part]
local before = record and #record.pieces or 0
DS.Damage(part, 100, nil, from)   -- to 47.5%: stage 2, PLAYED
H.deliver()
local out = { before = before, starts = {}, rings = {}, rays = {}, flashes = 0 }
local fresh = {}
for index = before + 1, record and #record.pieces or 0 do table.insert(fresh, record.pieces[index]) end
out.fresh = #fresh
out.animating = #CF.anims
for _, c in ipairs(workspace:FindFirstChild("CrackFx"):GetChildren()) do
    if c.Name == "CrackFlash" then out.flashes += 1 end
end
-- Starts against distance along the crack, for the lines (the main cracks).
local byPiece = {}
for _, a in ipairs(CF.anims) do byPiece[a.piece] = a end
local pairs_ = {}
for _, p in ipairs(fresh) do
    local a = byPiece[p]
    if a and a.spec.line then
        table.insert(pairs_, { a.spec.dist or 0, a.start - mock.clock, a.spec.kind, a.spec.branch or 0 })
        if a.spec.kind == "CrackWebRing" then table.insert(out.rings, a.start - mock.clock) end
        if a.spec.kind == "CrackWeb" then table.insert(out.rays, a.start - mock.clock) end
    end
end
-- Rank agreement: how often, of two lines, the one further out starts no sooner.
local agree, total, latest, levels = 0, 0, 0, {}
for i = 1, #pairs_ do
    latest = math.max(latest, pairs_[i][2])
    levels[string.format("%.3f", pairs_[i][2] - pairs_[i][4] * 0.06)] = true
    for j = i + 1, #pairs_ do
        if math.abs(pairs_[i][1] - pairs_[j][1]) > 0.2 then
            total += 1
            local a, b = pairs_[i], pairs_[j]
            if (a[1] < b[1]) == (a[2] <= b[2] + 1e-6) then agree += 1 end
        end
    end
end
local nLevels = 0
for _ in pairs(levels) do nLevels += 1 end
out.order = total > 0 and agree / total or 1
out.latest = latest
out.levels = nLevels
out.lines = #pairs_
-- Frame by frame for 1.5 s: how many frames have something still arriving (started, not at its
-- size), and how far a dent swells past its size before it settles (metal overshoots).
local midway, overshoot = 0, 0
for _ = 1, 45 do
    mock.advance(1 / 30)
    local moving = false
    for _, a in ipairs(CF.anims) do
        if a.started and math.abs(a.piece.Size.Magnitude - a.size.Magnitude) > a.size.Magnitude * 0.02 then moving = true end
        if a.started and a.spec.kind == "CrackDent" then
            overshoot = math.max(overshoot, a.piece.Size.Y / a.size.Y)
        end
    end
    if moving then midway += 1 end
end
out.midway = midway
out.overshoot = overshoot
out.after = #CF.anims
local wrong = 0
for index = before + 1, #record.pieces do
    local p, spec = record.pieces[index], record.pieceSpecs[index]
    if spec and math.abs(p.Size.X - (spec.size.X)) > 1e-3 and not spec.grow and not spec.core then wrong += 1 end
end
out.unsettled = wrong
DS.Damage(part, 1e6, nil, from)
H.deliver()
mock.advance(4)
return out
"""

# LOD: the same damage seen near, at middle distance and far: fewer pieces further off, the main
# cracks bolder far off.
LOD_LUA = r"""
local DS, H, mock, CF = ...
local cf = CFrame.new(6000, 6, 0)
local part = H.part(H.map, "Part", Vector3.new(12, 10, 1), cf, Enum.Material.Concrete)
part:SetAttribute("DestructibleHealth", 400)
workspace.CurrentCamera.CFrame = CFrame.new(cf * Vector3.new(0, 0, -20))
for _, d in ipairs({ { 2, 1 }, { -2, -1 }, { 0, 2 } }) do
    DS.Damage(part, 100, nil, cf * Vector3.new(d[1], d[2], -30))
    H.deliver()
    mock.advance(1.2)
end
local out = {}
local function look(distance)
    workspace.CurrentCamera.CFrame = CFrame.new(cf * Vector3.new(0, 0, -distance))
    mock.advance(0.6)
    local record = CF.tracked[part]
    local n, coreWidth = 0, 0
    for index, p in ipairs(record.pieces) do
        n += 1
        local spec = record.pieceSpecs[index]
        if spec and spec.core and spec.branch == 0 and coreWidth == 0 then coreWidth = p.Size.Y / spec.size.Y end
    end
    return n, record.lod, coreWidth
end
out.nearN, out.nearLod, out.nearW = look(20)
out.midN, out.midLod, out.midW = look(75)
out.farN, out.farLod, out.farW = look(135)
out.backN, out.backLod = look(20)
return out
"""

LATE_LUA = r"""
local DS, H, mock = ...
local M = Enum.Material
local cf = CFrame.new(0, 6, 800) * CFrame.Angles(0, -0.4, 0)
local part = H.part(H.map, "Wall", Vector3.new(12, 10, 1), cf, M.Concrete)
workspace.CurrentCamera.CFrame = CFrame.new(cf * Vector3.new(0, 0, -25))
DS.Damage(part, 60, nil, cf * Vector3.new(-2, 1, -30))
DS.Damage(part, 1, nil, cf * Vector3.new(3, -2, -30))
mock.runDue()
return part
"""

LATE_CLIENT_LUA = r"""
local CF, part, mock, earlier = ...
mock.advance(0.3)
local record = CF.tracked[part]
local out = { drawn = record and #record.pieces or 0, same = true }
if earlier then
    local mine = {}
    for _, p in ipairs(record and record.pieces or {}) do mine[string.format("%.3f,%.3f,%.3f", p.Position.X, p.Position.Y, p.Position.Z)] = true end
    for k in pairs(earlier) do if not mine[k] then out.same = false end end
end
return out
"""

UNLOAD_LUA = r"""
local DS, H, mock, CF = ...
local M = Enum.Material
local map2 = Instance.new("Folder"); map2.Name = "Map"; map2.Parent = workspace
H.map.Name = "OldMap"
local parts = {}
for i = 1, 6 do
    local p = H.part(map2, "Wall", Vector3.new(10, 8, 1), CFrame.new(i * 14, 4, 900), M.Brick)
    DS.Damage(p, 60, nil, p.Position + Vector3.new(0, 0, -30))
    table.insert(parts, p)
end
workspace.CurrentCamera.CFrame = CFrame.new(40, 6, 870)
H.deliver()
mock.advance(0.3)
local drawn = CF.totals.pieces
-- The map is taken away (not destroyed: just unparented), and the next sweep clears it all.
map2.Parent = nil
mock.advance(0.3)
local tracked = 0
for _ in pairs(CF.tracked) do tracked += 1 end
local left = 0
for _, c in ipairs(workspace:FindFirstChild("CrackFx"):GetChildren()) do
    if c.Name ~= "CrackBit" and c.Name ~= "CrackPuff" then left += 1 end
end
return { drawn = drawn, after = CF.totals.pieces, tracked = tracked, left = left }
"""

FAMILY_TABLE_LUA = r"""
local DS, CF = ...
local bad, examined = {}, 0
for material, class in pairs(DS.ClassTable) do
    examined += 1
    local mine = CF.FAMILY[material]
    local want = material.Name == "Brick" and "brick" or class
    if mine ~= want then table.insert(bad, material.Name .. ": server " .. class .. ", client " .. tostring(mine)) end
end
for material, family in pairs(CF.FAMILY) do
    if DS.ClassTable[material] == nil then examined += 1; table.insert(bad, material.Name .. ": client only (" .. family .. ")") end
end
return table.concat(bad, "; "), examined
"""

# ---------------------------------------------------------------------------------------------
# K: caps

CAPS_LUA = r"""
local DS, H, mock, CF = ...
local M = Enum.Material
local out = {}
local parts = {}
workspace.CurrentCamera.CFrame = CFrame.new(60, 10, 1030)
local dirs = { {1,0,0},{-1,0,0},{0,1,0},{0,0,1},{0,0,-1},{-1,0,1} }
local peakBits, peakBuilt, peakPieces, peakTrickles = 0, 0, 0, 0
for i = 0, 199 do
    local p = H.part(H.map, "Part", Vector3.new(4, 4, 4), CFrame.new((i % 20) * 6, 2, 1000 + math.floor(i / 20) * 6), M.Concrete)
    p:SetAttribute("DestructibleHealth", 1000)
    table.insert(parts, p)
end
for round, d in ipairs(dirs) do
    for _, p in ipairs(parts) do
        DS.Damage(p, round == 1 and 780 or 1, nil, p.Position + Vector3.new(d[1], d[2], d[3]) * 12)
    end
    H.deliver()
    peakBits = math.max(peakBits, #CF.bits)
    peakAnim = math.max(peakAnim or 0, #CF.anims)
    mock.advance(0.3)
    peakBuilt = math.max(peakBuilt, CF.totals.built)
    peakPieces = math.max(peakPieces, CF.totals.pieces)
    peakTrickles = math.max(peakTrickles, CF.totals.trickles)
end
local maxSite, maxPerPart = 0, 0
for _, record in pairs(CF.tracked) do
    local perSite = {}
    for _, s in ipairs(record.pieceSites) do perSite[s] = (perSite[s] or 0) + 1 end
    for _, n in pairs(perSite) do maxSite = math.max(maxSite, n) end
    maxPerPart = math.max(maxPerPart, #record.sites)
end
local built = 0
for _, record in pairs(CF.tracked) do if record.built then built += 1 end end
out.peakBits, out.peakBuilt, out.peakPieces, out.peakTrickles, out.maxSite, out.maxSites, out.builtNow = peakBits, peakBuilt, peakPieces, peakTrickles, maxSite, maxPerPart, built
out.peakAnim = peakAnim or 0
mock.advance(4)
out.bitsAfter = #CF.bits
-- Walk away: nothing drawn past DROP_BEYOND.
workspace.CurrentCamera.CFrame = CFrame.new(60, 10, 1030 + CF.caps.DROP_BEYOND + 200)
mock.advance(0.3)
out.farPieces, out.farBuilt = CF.totals.pieces, CF.totals.built
local counted = 0
for _, c in ipairs(workspace:FindFirstChild("CrackFx"):GetChildren()) do
    if c.Name ~= "CrackBit" and c.Name ~= "CrackPuff" then counted += 1 end
end
out.farCounted = counted
return out
"""

# ---------------------------------------------------------------------------------------------
# G: glass

GLASS_LUA = r"""
local DS, H, mock = ...
local M = Enum.Material
local house = Instance.new("Model"); house.Name = "House_G"; house.Parent = H.map
local cf = CFrame.new(0, 5, 1200) * CFrame.Angles(0, 0.3, 0)
local pane = H.part(house, "WindowGlass", Vector3.new(4, 3, 0.2), cf, M.Glass, { Transparency = 0.45 })
workspace.CurrentCamera.CFrame = CFrame.new(cf * Vector3.new(0, 0, -20))
local impact = cf * Vector3.new(1.2, -0.6, -0.1)
mock.modules.CombatService.DamageDestructible(nil, pane, 1, cf * Vector3.new(0, 0, -40), impact, cf.LookVector)
local out = { gone = pane.Parent == nil }
H.deliver()
local record = mock.remotes.GlassShatter.fired[#mock.remotes.GlassShatter.fired][1][1]
out.impactOff = record[5] and (record[5] - impact).Magnitude or -1
out.transparency = record[6]
local folder = workspace:FindFirstChild("GlassFx")
local web, onPlane, fromImpact = 0, 0, 0
for _, c in ipairs(folder:GetChildren()) do
    if c.Name == "GlassCrack" then
        web += 1
        local l = cf:PointToObjectSpace(c.Position)
        if math.abs(l.Z) < 0.01 then onPlane += 1 end
        -- A ray's middle lies on the line from the impact: its direction points back at it.
        local dir = cf:VectorToObjectSpace(c.CFrame.RightVector)
        local toImpact = Vector3.new(1.2 - l.X, -0.6 - l.Y, 0)
        if toImpact.Magnitude > 0.05 then
            local cross = math.abs(dir.X * toImpact.Y - dir.Y * toImpact.X) / toImpact.Magnitude
            if cross < 0.05 then fromImpact += 1 end
        end
    end
end
out.web, out.onPlane, out.fromImpact = web, onPlane, fromImpact
mock.advance(0.2)
local after, shards = 0, 0
for _, c in ipairs(folder:GetChildren()) do
    if c.Name == "GlassCrack" or c.Name == "GlassCrackPane" then after += 1 end
    if c.Name == "GlassShard" then shards += 1 end
end
out.webAfter, out.shards = after, shards
return out
"""

failures = []


def check(ok, label):
    print("  %s  %s" % ("ok  " if ok else "FAIL", label))
    if not ok:
        failures.append(label)
    return ok


def sound_names():
    import re
    with open(os.path.join(ROOT, "ReplicatedStorage", "Shared", "SoundConfig.lua"), encoding="utf-8") as f:
        return re.findall(r"^\t(\w+) = \{", f.read(), re.M)


SOUNDS = sound_names()


def world(ds_faults=(), crack_faults=(), with_clients=True):
    w = World()
    # The real cue names, so a family whose cue exists in the game is heard here too.
    w.run("""local mock, names = ...
        local known = {}
        for _, name in ipairs(names) do known[name] = true end
        mock.modules.SoundConfig.Get = function(name) return known[name] and {} or nil end""", w.mock, w.lua.table_from(SOUNDS))
    for name in ("BreakFx", "GlassShatter", "DamageFx"):
        w.run("local mock, name = ...; mock.remote(name)", w.mock, name)
    h = w.run(PRELUDE, w.mock)
    ds = w.load(SERVICE, ds_faults, name="DestructibleService")
    cf = None
    if with_clients:
        cf = load(w, CRACK, crack_faults, CRACK_EXPORT, name="CrackFxClient")
        load(w, BREAK, (), "", name="BreakFxClient")
        load(w, GLASS, (), "", name="GlassFxClient")
    return w, h, ds, cf


def fails_of(h, tag=None):
    fs = [h["fails"][i] for i in range(1, len(h["fails"]) + 1)]
    return [f for f in fs if tag is None or f.startswith(tag)]


def run_fade(ds_faults=(), crack_faults=(), quiet=False):
    w, h, ds, _ = world(ds_faults, crack_faults)
    out = w.run(FADE_LUA, ds, h, w.mock)
    fs = fails_of(h, "F")
    if not quiet:
        print("    %d damage calls over %d map parts of 11 materials; %d Transparency/LocalTransparencyModifier writes seen on them;"
              " %d still standing at the end" % (out["calls"], out["watched"], out["writes"], out["standing"]))
        check(not fs, "F  no part's Transparency or LocalTransparencyModifier rises before it breaks%s" % (": " + fs[0] if fs else ""))
        check(out["balconyGone"], "F  the wall took its pane, sill, balcony and rail with it")
        check(out["panesGone"], "F  panes shattered at one touch, straight on and by a blast")
        check(out["standing"] == 0, "F  every damaged thing broke in the end (%d left standing)" % out["standing"])
    return fs


def run_stage(ds_faults=(), quiet=False):
    w, h, ds, _ = world(ds_faults, with_clients=False)
    out = w.run(STAGE_LUA, ds, h, w.mock)
    fs = fails_of(h, "S")
    if not quiet:
        print("    %d pools walked in %d hits; slab hit from 12 directions: %d sites, %d attribute writes;"
              " 60 parts x 3 hits in one frame: %d event(s), %d records, %d duplicates, first counted %d"
              % (out["pools"], out["steps"], out["sites"], out["siteWrites"], out["events"], out["records"], out["dupes"], out["lastCount"]))
        check(not fs, "S  stages step at 75/50/25%%, never back, <= 3 writes, on the pool's carrier; sites and events capped%s"
              % (": " + fs[0] if fs else ""))
    return fs


def all_materials():
    """Every Roblox part material, from the API dump: not Air or Water (terrain only), and not the two
    legacy aliases (Aluminum is Foil; "Corroded Metal" is CorrodedMetal)."""
    import json
    with open(os.path.join(ROOT, "tools", "roblox_api_subset.json"), encoding="utf-8") as f:
        names = json.load(f)["enums"]["Material"]
    return [n for n in names if n not in ("Air", "Water", "Aluminum", "Corroded Metal")]


MATERIALS = all_materials()

# What each material must show by 25% (near): the pieces that make it read as itself.
SIGNATURES = {
    "Concrete": ["CrackRebar", "CrackDisplaced", "CrackAggregate", "CrackLip", "CrackShade"],
    "Brick": ["CrackBrick", "CrackBrickGap", "CrackLip"],
    "Marble": ["CrackVein", "CrackScallop", "CrackShard"],
    "Granite": ["CrackFracture", "CrackCrystal", "CrackFacet", "CrackDisplaced"],
    "Slate": ["CrackCleave", "CrackFlake", "CrackLayer", "CrackStep"],
    "Sandstone": ["CrackCrumble", "CrackPit", "CrackHollow", "CrackHeap"],
    "Basalt": ["CrackJoint", "CrackColumn", "CrackSocket"],
    "Limestone": ["CrackChalk", "CrackPowder", "CrackDisplaced"],
    "Rock": ["CrackFissure", "CrackSlab", "CrackScar", "CrackDisplaced"],
    "Cobblestone": ["CrackJoint", "CrackCobble", "CrackSocket"],
    "Pebble": ["CrackSocket", "CrackMatrix"],
    "Pavement": ["CrackJoint", "CrackSplit", "CrackTipped"],
    "Asphalt": ["CrackAlligator", "CrackPothole", "CrackGravel", "CrackRavel", "CrackDisplaced"],
    "CrackedLava": ["CrackGlowLine", "CrackGlow", "CrackMolten", "CrackCrust"],
    "Salt": ["CrackCleave", "CrackCubePit", "CrackCrystal"],
    "Ice": ["CrackFracture", "CrackBruise", "CrackPlane", "CrackShard"],
    "Glacier": ["CrackFracture", "CrackBruise", "CrackPlane", "CrackCrevasse"],
    "Glass": ["CrackWeb", "CrackWebRing", "CrackImpact"],
    "Wood": ["CrackGrain", "CrackSplinter", "CrackBoard", "CrackCore"],
    "WoodPlanks": ["CrackSeam", "CrackPlank", "CrackNail", "CrackCore"],
    "Metal": ["CrackDent", "CrackScratch", "CrackHole", "CrackPeel", "CrackBareMetal"],
    "DiamondPlate": ["CrackBuckle", "CrackTorn", "CrackDent"],
    "CorrodedMetal": ["CrackRustFlake", "CrackBloom", "CrackRustHole", "CrackBareMetal"],
    "Foil": ["CrackCrinkle", "CrackTear", "CrackCurl"],
    "LeafyGrass": ["CrackTwig", "CrackBare"],
    "Grass": ["CrackGouge", "CrackTuft", "CrackDivot", "CrackTurfFlap"],
    "Ground": ["CrackDry", "CrackClodPit", "CrackSlump", "CrackHeap"],
    "Sand": ["CrackDimple", "CrackSlump"],
    "Snow": ["CrackSnowHole", "CrackSnowSlab", "CrackPacked"],
    "Mud": ["CrackSplat", "CrackSplatRim", "CrackDrip"],
    "Fabric": ["CrackTear", "CrackFray", "CrackFlap"],
    "Leather": ["CrackSlash", "CrackSuede", "CrackPuncture", "CrackStitch"],
    "Carpet": ["CrackTuft", "CrackBacking", "CrackWeave", "CrackFlap"],
    "Cardboard": ["CrackCrease", "CrackCorrugation", "CrackFold"],
    "Rubber": ["CrackGouge", "CrackTornRim", "CrackGash", "CrackStrand"],
    "Plaster": ["CrackCraze", "CrackUnder", "CrackMortar", "CrackPlasterEdge"],
    "CeramicTiles": ["CrackGrout", "CrackTileStar", "CrackTileGone", "CrackTrowel"],
    "ClayRoofTiles": ["CrackSlipped", "CrackBatten", "CrackTileGone"],
    "RoofShingles": ["CrackCurl", "CrackFelt"],
    "Plastic": ["CrackBloom", "CrackWhitened", "CrackLip", "CrackHole"],
    "SmoothPlastic": ["CrackCrisp", "CrackCraze", "CrackConchoid", "CrackChunk"],
    "Neon": ["CrackDead", "CrackDeadLine"],
    "ForceField": ["CrackHexFault", "CrackFizz"],
}
# Pieces every material may share, so they don't count toward telling two looks apart.
GENERIC = {"CrackLine", "CrackLip", "CrackShade", "CrackHair", "CrackChip", "CrackStick", "CrackPlate", "CrackDent"}


def run_materials(crack_faults=(), quiet=False):
    w, h, ds, cf = world(crack_faults=crack_faults)
    sigs = w.lua.table_from({k: w.lua.table_from(v) for k, v in SIGNATURES.items()})
    out = w.run(MATERIALS_LUA, ds, h, w.mock, cf, w.lua.table_from(MATERIALS), sigs)
    fs = fails_of(h, "C")
    rows = [out["rows"][i] for i in range(1, len(MATERIALS) + 1) if out["rows"][i] is not None]
    looks = {}
    for row in rows:
        own = frozenset(n for n in row["look"].split(",") if n not in GENERIC)
        looks.setdefault(own, []).append(row["name"])
    twins = [names for names in looks.values() if len(names) > 1]
    if not quiet:
        for row in rows:
            print("    %-14s %3d pieces at 25%%, %d sound layers: %s" % (row["name"], row["drawn"], row["heard"], row["look"]))
        check(not fs, "C  every material (%d) draws on the hit face, grows each stage, bursts and plays two sound layers each hit,"
              " shows its own signature pieces, clears on break%s" % (len(MATERIALS), (": " + fs[0]) if fs else ""))
        check(not twins, "C  no two materials look the same (their own pieces differ)%s" % ((": " + str(twins)) if twins else ""))
        check(out["totalsAfter"] == 0, "C  nothing left drawn once everything broke (%d)" % out["totalsAfter"])
    return fs + (["twins"] if twins else [])


# Materials whose stage change is watched as it plays, and what their style must show.
ANIMATED = ["Concrete", "Brick", "WoodPlanks", "Glass", "Metal", "Ice", "Plaster", "Sand", "Neon"]


def run_anim(crack_faults=(), quiet=False):
    results, bad = {}, []
    for name in ANIMATED:
        w, h, ds, cf = world(crack_faults=crack_faults)
        out = w.run(ANIM_LUA, ds, h, w.mock, cf, name)
        results[name] = out
        style = cf["profiles"][name]["style"]
        problems = []
        if out["fresh"] <= 0 or out["animating"] <= 0:
            problems.append("nothing played (%d new, %d moving)" % (out["fresh"], out["animating"]))
        if out["midway"] < 2:
            problems.append("nothing seen arriving (%d frames)" % out["midway"])
        if out["after"] != 0:
            problems.append("%d still moving after 1.5 s" % out["after"])
        if style != "web" and out["lines"] >= 4 and out["order"] < 0.7:
            problems.append("cracks further out did not start later (%.0f%% in order)" % (out["order"] * 100))
        if style == "steps" and out["levels"] > 4:
            problems.append("steps: %d start times, not three jumps" % out["levels"])
        rings = list(out["rings"].values()) if out["rings"] else []
        rays = list(out["rays"].values()) if out["rays"] else []
        if style == "web" and not (rings and rays and min(rings) > max(rays)):
            problems.append("web: the rings did not start after the rays")
        if style == "race" and out["flashes"] <= 0:
            problems.append("race: no white flash")
        if style == "push" and out["overshoot"] < 1.02:
            problems.append("push: the dent did not overshoot (%.3f)" % out["overshoot"])
        if style == "creep" and out["latest"] < 0.3:
            problems.append("creep: the split ran out in %.2f s, not creeping" % out["latest"])
        if name == "Glass" and rays and max(rays) > 0.12:
            problems.append("glass: the web took %.2f s, not almost at once" % max(rays))
        if problems:
            bad.append("%s (%s): %s" % (name, style, "; ".join(problems)))
    if not quiet:
        for name in ANIMATED:
            o = results[name]
            print("    %-11s %-7s %3d new pieces, %3d moving at once; %2d frames with something arriving; lines in order %3.0f%%;"
                  " last starts at %.2f s; %d start levels; flash %d; overshoot %.3f; moving after 1.5 s: %d"
                  % (name, cf_style(name), o["fresh"], o["animating"], o["midway"], o["order"] * 100, o["latest"], o["levels"],
                     o["flashes"], o["overshoot"], o["after"]))
        check(not bad, "A  every stage change plays in its material's own time (steps, web, race, creep, push, flicker, slump)%s"
              % ((": " + bad[0]) if bad else ""))
    return bad


_STYLES = {}


def cf_style(name):
    if not _STYLES:
        w, h, ds, cf = world()
        for n in ANIMATED:
            _STYLES[n] = cf["profiles"][n]["style"]
    return _STYLES.get(name, "?")


def run_lod(crack_faults=(), quiet=False):
    w, h, ds, cf = world(crack_faults=crack_faults)
    out = w.run(LOD_LUA, ds, h, w.mock, cf)
    ok = (out["nearLod"] == 1 and out["midLod"] == 2 and out["farLod"] == 3 and out["nearN"] > out["midN"] > out["farN"] > 0
          and out["farW"] > out["nearW"] * 1.5 and out["backN"] == out["nearN"])
    if not quiet:
        print("    concrete, three sites at 25%%: near (20 studs) %d pieces, core width x%.2f; middle (75) %d; far (135) %d, core width x%.2f;"
              " back near %d" % (out["nearN"], out["nearW"], out["midN"], out["farN"], out["farW"], out["backN"]))
        check(ok, "L  fewer pieces further off, the main cracks drawn bolder far off, and the same again coming back")
    return ok


def run_table(crack_faults=(), quiet=False):
    w, h, ds, cf = world(crack_faults=crack_faults)
    bad, examined = w.run(FAMILY_TABLE_LUA, ds, cf)
    # Every material in every table: the server's family, the client's family and look, and a break.
    missing = []
    names = w.lua.table_from(MATERIALS)
    gaps = w.run(r"""
        local DS, CF, names, breakSource = ...
        local out = {}
        for _, name in ipairs(names) do
            local m = Enum.Material[name]
            if DS.ClassTable[m] == nil then table.insert(out, name .. ": no server family") end
            if CF.FAMILY[m] == nil then table.insert(out, name .. ": no client family") end
            if CF.profiles[name] == nil or CF.profiles[name].look == nil then table.insert(out, name .. ": no crack look") end
            if not string.find(breakSource, "\n\t" .. name .. " = {", 1, true) then table.insert(out, name .. ": no break of its own") end
        end
        return table.concat(out, "; ")
    """, ds, cf, names, open(BREAK, encoding="utf-8").read())
    if gaps:
        missing.append(gaps)
    if not quiet:
        check(bad == "", "T  client family table agrees with the server's, brick apart (%d materials examined)%s"
              % (examined, ": " + bad if bad else ""))
        check(not missing, "T  every one of the %d part materials has a server family, a client family, its own crack look and its own break%s"
              % (len(MATERIALS), (": " + missing[0]) if missing else ""))
    return bad == "" and not missing


def run_late(quiet=False):
    # The same damage seen live and by a player who joins after it.
    w, h, ds, cf = world()
    part = w.run(LATE_LUA, ds, h, w.mock)
    w.run("local h = ...; h.deliver()", h)
    live = w.run(LATE_CLIENT_LUA, cf, part, w.mock, None)
    keys = dict(w.run("""local CF, part = ...
        local t = {}
        for _, p in ipairs(CF.tracked[part].pieces) do t[string.format("%.3f,%.3f,%.3f", p.Position.X, p.Position.Y, p.Position.Z)] = true end
        return t""", cf, part))
    w2, h2, ds2, _ = world(with_clients=False)
    part2 = w2.run(LATE_LUA, ds2, h2, w2.mock)
    cf2 = load(w2, CRACK, (), CRACK_EXPORT, name="CrackFxClient")
    late = w2.run(LATE_CLIENT_LUA, cf2, part2, w2.mock, w2.lua.table_from(keys))
    if not quiet:
        print("    live client drew %d pieces; a client joining afterwards drew %d" % (live["drawn"], late["drawn"]))
        check(late["drawn"] == live["drawn"] and live["drawn"] > 0 and late["same"],
              "C  a late joiner finds the damage by its tag and draws exactly the same pieces")
    return late["drawn"] == live["drawn"] and late["same"] and live["drawn"] > 0


def run_unload(crack_faults=(), quiet=False):
    w, h, ds, cf = world(crack_faults=crack_faults)
    out = w.run(UNLOAD_LUA, ds, h, w.mock, cf)
    ok = out["drawn"] > 0 and out["after"] == 0 and out["tracked"] == 0 and out["left"] == 0
    if not quiet:
        print("    6 damaged walls drew %d pieces; after the Map was taken away: %d pieces, %d tracked, %d parts left in CrackFx"
              % (out["drawn"], out["after"], out["tracked"], out["left"]))
        check(ok, "C  a Map taken away takes every mark with it at the next sweep")
    return ok


def run_caps(crack_faults=(), quiet=False):
    w, h, ds, cf = world(crack_faults=crack_faults)
    out = w.run(CAPS_LUA, ds, h, w.mock, cf)
    caps = cf["caps"]
    ok = (out["peakBuilt"] <= caps["MAX_BUILT"] and out["peakPieces"] <= caps["MAX_PIECES"]
          and out["maxSite"] <= caps["PER_SITE_CAP"] and out["peakTrickles"] <= caps["MAX_TRICKLES"]
          and out["peakBits"] <= caps["MAX_BITS"] and out["bitsAfter"] == 0 and out["maxSites"] <= 4
          and out["peakAnim"] <= caps["MAX_ANIMATING"]
          and out["farPieces"] == 0 and out["farBuilt"] == 0 and out["farCounted"] == 0 and out["peakBuilt"] > 0)
    if not quiet:
        print("    200 parts, 6 hits each from 6 sides, at 22%%: peak %d parts drawn (cap %d), %d pieces (cap %d), %d per site"
              " (cap %d), %d sites per part (cap 4), %d dust trickles (cap %d), %d bits (cap %d), %d bits after 4 s;"
              " %d pieces moving at once (cap %d); walked %d studs off: %d pieces, %d parts drawn"
              % (out["peakBuilt"], caps["MAX_BUILT"], out["peakPieces"], caps["MAX_PIECES"], out["maxSite"], caps["PER_SITE_CAP"],
                 out["maxSites"], out["peakTrickles"], caps["MAX_TRICKLES"], out["peakBits"], caps["MAX_BITS"], out["bitsAfter"],
                 out["peakAnim"], caps["MAX_ANIMATING"], caps["DROP_BEYOND"] + 200, out["farPieces"], out["farBuilt"]))
        check(ok, "K  every cap holds, bits expire, nothing drawn out of range")
    return ok


def run_glass(quiet=False):
    w, h, ds, cf = world()
    out = w.run(GLASS_LUA, ds, h, w.mock)
    fs = fails_of(h, "F")
    ok = (out["gone"] and 0 <= out["impactOff"] < 0.25 and out["transparency"] == 0.45 and out["web"] >= 14
          and out["onPlane"] == out["web"] and out["fromImpact"] >= 7 and out["webAfter"] == 0 and out["shards"] > 0 and not fs)
    if not quiet:
        print("    pane gone at once: %s; impact sent %.2f studs from the hit; web of %d lines (%d on the pane's plane, %d rays"
              " from the impact); after WEB_TIME: %d web parts, %d shards"
              % (out["gone"], out["impactOff"], out["web"], out["onPlane"], out["fromImpact"], out["webAfter"], out["shards"]))
        check(ok, "G  a pane shatters at a touch, never fading first, with a spiderweb from the impact then shards")
    return ok


def main():
    print("F: never fades")
    run_fade()
    print("S: stages")
    run_stage()
    print("C: cracks per material (%d part materials)" % len(MATERIALS))
    run_materials()
    run_late()
    run_unload()
    run_table()
    print("A: every stage change plays")
    run_anim()
    print("L: detail by distance")
    run_lod()
    print("K: caps")
    run_caps()
    print("G: glass")
    run_glass()

    print("\nplanted faults (each must FAIL its check):")
    ds_fade = ("\t\t\tmember.Color = base:Lerp(tint[1], tint[2] * stage)\n",
               "\t\t\tmember.Color = base:Lerp(tint[1], tint[2] * stage)\n\t\t\tmember.Transparency = math.min(1, member.Transparency + 0.25)\n")
    client_fade = ("\t\trecord.built = true\n\t\ttotals.built += 1\n",
                   "\t\trecord.built = true\n\t\ttotals.built += 1\n\t\tpart.LocalTransparencyModifier = 0.25 * math.max(record.stage, 1)\n")
    plants = [
        ("F the old fade, server side", lambda: (run_fade([ds_fade], quiet=True))),
        ("F a fade on the client (LocalTransparencyModifier)", lambda: (run_fade((), [client_fade], quiet=True))),
        ("S thresholds taken as < instead of <=", lambda: (run_stage([("\t\tif fraction <= at then\n", "\t\tif fraction < at then\n")], quiet=True))),
        ("S per-part site cap removed", lambda: (run_stage([("\tif #list >= MAX_SITES_PER_PART or entry.siteCount >= MAX_SITES_PER_POOL then\n",
                                                               "\tif false then\n")], quiet=True))),
        ("C cracks drawn on the opposite face", lambda: (run_materials([("CFrame.fromMatrix(g.face.n * g.depth,", "CFrame.fromMatrix(g.face.n * -g.depth,")], quiet=True))),
        ("C brick drawn as concrete", lambda: (run_materials([('profile("Brick", "Brick",', 'profile("Brick", "Concrete",')], quiet=True))),
        ("C Destroying cleanup removed", lambda: (run_materials([("\trecord.connection = part.Destroying:Connect(function()\n\t\tuntrack(part)\n\tend)\n",
                                                                     "\trecord.connection = part.Destroying:Connect(function() end)\n")], quiet=True))),
        ("C out-of-workspace sweep removed", lambda: not run_unload([("if not part.Parent or not part:IsDescendantOf(workspace) then", "if not part.Parent then")], quiet=True)),
        ("T client family table wrong for Foil", lambda: not run_table([('[M.Foil] = "metal"', '[M.Foil] = "plastic"')], quiet=True)),
        ("T a material with no look of its own (Salt)", lambda: not run_table([('profile("Salt", "Salt",', 'profile("SaltX", "Salt",')], quiet=True)),
        ("A stage changes not played (everything appears finished)", lambda: run_anim([("local animated = play and record.distance and record.distance <= ANIMATE_WITHIN",
                                                                                          "local animated = false")], quiet=True)),
        ("L one level of detail everywhere", lambda: not run_lod([("if (spec.lod or 3) >= lod and drawn[1]", "if true and drawn[1]")], quiet=True)),
        ("K MAX_BUILT cap removed", lambda: not run_caps([("\t\tif rank > MAX_BUILT then\n", "\t\tif false then\n")], quiet=True)),
    ]
    caught = 0
    for label, fn in plants:
        result = fn()
        hit = bool(result)
        caught += hit
        why = (": " + str(result[0])[:120]) if isinstance(result, list) and result else ""
        print("  %s  %s%s" % ("caught" if hit else "MISSED", label, why))
    check(caught == len(plants), "planted faults caught: %d/%d" % (caught, len(plants)))
    print("\ncrack_check:", "OK" if not failures else "FAILED (%d)" % len(failures))
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
