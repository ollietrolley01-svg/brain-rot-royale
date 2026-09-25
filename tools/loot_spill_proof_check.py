"""Proof check for OLIVER_LIST #85: chests and supply drops put their contents on the ground, not in the bag.

Runs the REAL ServerScriptService/Modules/LootService.lua and SupplyDropService.lua (whole modules), the
real ItemData / Rarity / WeaponData tables, TeamBattleground's real loot seeding (SeedLoot and the
functions it calls, cut from the file) and BotService's real BotService.Loot.claimConsumable (cut), in
lupa, over a stand-in Roblox world: instances with attributes and signals, a virtual clock for
task.delay / task.wait / task.defer, and a raycaster over oriented boxes. The boxes are either a few
hand-made scenes (a wall, a roof, a narrow gallery) or the REAL geometry of a team-base compound
(TeamBaseRuins.Layout, via tools/team_base_ruins_check.py) and of the battleground
(TeamBattleground.Layout, via tools/team_battleground_check.py).

    python tools/loot_spill_proof_check.py .            the checks
    python tools/loot_spill_proof_check.py . --plant    the planted faults; every one must be caught

What is measured:
  A  every container, opened by a player through its real prompt: a map chest (Populate), a team-base
     chest (SeedAt, GameMode's call), the battleground's chest (TeamBattleground.SeedLoot), a chest
     rebuilt after its floor broke (LootService.Resettle), and the supply crate (SupplyDropService.Start).
     Every roll lands as exactly one pickup; nothing reaches the opener's bag but ammo.
  S  the 1 s settle (3441c0f): the prompt is off and the server refuses a take while it runs, then a
     fresh press works; no pickup has a Touched handler (no walk-over pickup).
  R  races: two presses in one frame, a player and a bot, two players on one spilled gun; spills
     outlive the chest, the crate and 600 s.
  P  where a spill lands: on the floor it was thrown from, inside no solid part, reachable (the compound's
     walk grid), in a corridor, on a roof, on a gallery, in the real compound and battleground.
  FINDING lines are measured behaviour the report ranks (bots, stacking, the cap, Resettle, restock).

What it cannot prove: Roblox's prompt input, replication, the real shapes of wedges and cylinders (they
are boxes here), a real map's terrain, or how a spill LOOKS. tools/loot_spill_gallery.lua is the render.
Needs lupa and numpy (the battleground's check imports numpy).
"""

import math
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("loot_spill_proof_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]()\"]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def read(root, rel):
    return (Path(root) / rel).read_text(encoding="utf-8")


def cut(text, start, end_marker="\nend\n"):
    a = text.index(start)
    b = text.index(end_marker, a) + len(end_marker)
    return text[a:b]


def sources(root):
    shared = "ReplicatedStorage/Shared/"
    modules = "ServerScriptService/Modules/"
    bot = read(root, modules + "BotService.lua")
    bg = read(root, modules + "TeamBattleground.lua")
    events = read(root, shared + "MatchEvents.lua")
    frenzy = re.search(r"chestGuns = (\d+)", events)
    return {
        "Rarity": read(root, shared + "Rarity.lua"),
        "ItemData": read(root, shared + "ItemData.lua"),
        "WeaponData": read(root, shared + "WeaponData.lua"),
        "ArsenalExpansion": read(root, shared + "ArsenalExpansion.lua"),
        "CreativeArsenal": read(root, shared + "CreativeArsenal.lua"),
        "WorkshopArsenal": read(root, shared + "WorkshopArsenal.lua"),
        "LootService": read(root, modules + "LootService.lua"),
        "SupplyDropService": read(root, modules + "SupplyDropService.lua"),
        # BotService.Loot.claimConsumable: how a bot takes a shield or throwable pickup.
        "claimConsumable": cut(bot, "function BotService.Loot.claimConsumable(bot, item)"),
        # TeamBattleground's loot: spotFree, RollWeapon, seedSpot and SeedLoot with its restock loop.
        "bgLoot": bg[bg.index("-- Loot on the battleground's spots"):bg.index("-- Takes it down (the match ending).")],
        "frenzyGuns": int(frenzy.group(1)) if frenzy else 3,
        "__root": str(root),
    }


# ------------------------------------------------------------------------------------------------
# The stand-in world
# ------------------------------------------------------------------------------------------------

WORLD = r"""
local SOURCES = ...

-- Clock and scheduler ------------------------------------------------------------------------------
local now = 0
local queue = {}
local seq = 0
local function schedule(at, co, args) seq = seq + 1 table.insert(queue, { at = at, seq = seq, co = co, args = args }) end
local function resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(debug.traceback(co, tostring(err)), 0) end
end
task = {
    delay = function(t, f, ...) local co = coroutine.create(f) schedule(now + (t or 0), co, table.pack(...)) return co end,
    defer = function(f, ...) local co = coroutine.create(f) schedule(now, co, table.pack(...)) return co end,
    spawn = function(f, ...) local co = coroutine.create(f) resume(co, ...) return co end,
    wait = function(t) local co = coroutine.running() schedule(now + (t or 0.03), co, table.pack()) coroutine.yield() return t end,
}
function advance(dt)
    local target = now + dt
    while true do
        table.sort(queue, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.seq < b.seq end)
        local job = queue[1]
        if not job or job.at > target then break end
        table.remove(queue, 1)
        now = math.max(now, job.at)
        if coroutine.status(job.co) == "suspended" then resume(job.co, table.unpack(job.args, 1, job.args.n)) end
    end
    now = target
end
function clock() return now end
warnings = {}
warn = function(text) table.insert(warnings, tostring(text)) end
os = setmetatable({ clock = function() return now end }, { __index = os })
tick = function() return now end
function table.clone(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
function table.clear(t) for k in pairs(t) do t[k] = nil end end
function math.clamp(x, a, b) return math.max(a, math.min(b, x)) end
local realRandom = math.random
math.random = function(a, b)
    if a == nil then return realRandom() end
    if b == nil then return realRandom(1, math.floor(a)) end
    return realRandom(math.floor(a), math.floor(b))
end
-- Luau's %d takes a float; Lua 5.4's refuses one. Floor only the arguments a %d/%i/%x reads.
local luaFormat = string.format
string.format = function(fmt, ...)
    local args = table.pack(...)
    local i = 0
    for spec in fmt:gmatch("%%[-+ #0]*%d*%.?%d*([%a%%])") do
        if spec ~= "%" then
            i = i + 1
            if (spec == "d" or spec == "i" or spec == "x") and type(args[i]) == "number" then args[i] = math.floor(args[i]) end
        end
    end
    return luaFormat(fmt, table.unpack(args, 1, args.n))
end
realFormat = string.format

-- Values ------------------------------------------------------------------------------------------
local V = {}
local function vec(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end
V.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
    return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b) return vec(a.X / b, a.Y / b, a.Z / b) end
V.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V.__tostring = function(v) return realFormat("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z) end
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) return m > 0 and vec(v.X / m, v.Y / m, v.Z / m) or vec() end
    if k == "Dot" then return function(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end end
end
Vector3 = { new = vec, zero = vec(0, 0, 0), one = vec(1, 1, 1), yAxis = vec(0, 1, 0), xAxis = vec(1, 0, 0), zAxis = vec(0, 0, 1) }
Vector2 = { new = function(x, y) return { X = x, Y = y, Magnitude = math.sqrt(x * x + y * y) } end }

-- Translation-only frames: a spill is judged by where things are, and every chest spot is upright.
local C = {}
local function cf(p) return setmetatable({ Position = p or vec() }, C) end
C.__mul = function(a, b)
    if getmetatable(b) == V then return a.Position + b end
    return cf(a.Position + b.Position)
end
C.__add = function(a, b) return cf(a.Position + b) end
C.__sub = function(a, b) return cf(a.Position - b) end
C.__index = function(c, k)
    if k == "Rotation" then return cf(vec()) end
    if k == "LookVector" then return vec(0, 0, -1) end
    if k == "X" then return c.Position.X elseif k == "Y" then return c.Position.Y elseif k == "Z" then return c.Position.Z end
    if k == "Inverse" then return function(self) return cf(-self.Position) end end
end
CFrame = {
    new = function(x, y, z) if type(x) == "table" then return cf(x) end return cf(vec(x, y, z)) end,
    Angles = function() return cf(vec()) end,
    lookAt = function(p) return cf(p) end,
    identity = cf(vec()),
}
Color3 = { fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end, new = function(r, g, b) return { R = r, G = g, B = b } end }
Color3.fromHSV = Color3.new
UDim2 = { new = function() return {} end, fromScale = function() return {} end, fromOffset = function() return {} end }
TweenInfo = { new = function() return {} end }
local function enumTable(path)
    return setmetatable({}, { __index = function(t, k) local v = enumTable(path .. "." .. k) rawset(t, k, v) return v end,
        __tostring = function() return path end })
end
Enum = enumTable("Enum")
RaycastParams = { new = function() return { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude } end }
OverlapParams = RaycastParams

-- Instances ---------------------------------------------------------------------------------------
local SIGNALS = { Triggered = true, PromptButtonHoldBegan = true, PromptButtonHoldEnded = true, ChildAdded = true,
    ChildRemoved = true, Destroying = true, Touched = true, AncestryChanged = true, OnServerEvent = true, Completed = true }
local BASEPART = { Part = true, MeshPart = true, WedgePart = true, UnionOperation = true, TrussPart = true }
local function signal()
    local s = { handlers = {} }
    function s:Connect(f) table.insert(self.handlers, f) return { Disconnect = function() for i, h in ipairs(s.handlers) do if h == f then table.remove(s.handlers, i) break end end end, Connected = true } end
    function s:Once(f) return self:Connect(f) end
    function s:Fire(...) for _, f in ipairs({ table.unpack(self.handlers) }) do f(...) end end
    return s
end
local M = {}
local I = {}
function new(class, name)
    local o = setmetatable({ _p = { Name = name or class, ClassName = class }, _kids = {}, _attr = {}, _sig = {}, _asig = {} }, I)
    if BASEPART[class] then
        o._p.CFrame = cf(vec()) o._p.Size = vec(1, 1, 1) o._p.Anchored = false o._p.CanCollide = true
        o._p.CanQuery = true o._p.Transparency = 0
    end
    if class == "ProximityPrompt" then
        o._p.Enabled = true o._p.HoldDuration = 0 o._p.MaxActivationDistance = 10
    end
    return o
end
I.__index = function(o, k)
    if M[k] then return M[k] end
    if SIGNALS[k] then local s = o._sig[k] if not s then s = signal() o._sig[k] = s end return s end
    if k == "Parent" then return o._parent end
    if k == "Position" and o._p.CFrame then return o._p.CFrame.Position end
    local v = o._p[k]
    if v ~= nil then return v end
    for _, c in ipairs(o._kids) do if c._p.Name == k then return c end end
    return nil
end
I.__newindex = function(o, k, v)
    if k == "Parent" then
        if o._destroyed then error("The Parent property of " .. o._p.Name .. " is locked", 2) end
        if o._parent then
            local kids = o._parent._kids
            for i, c in ipairs(kids) do if c == o then table.remove(kids, i) break end end
        end
        rawset(o, "_parent", v)
        if v then table.insert(v._kids, o) end
        return
    end
    if k == "Position" then o._p.CFrame = cf(v) return end
    o._p[k] = v
end
I.__tostring = function(o) return o._p.Name end
function M:IsA(c)
    local cls = self._p.ClassName
    return c == cls or c == "Instance" or (c == "BasePart" and BASEPART[cls] == true)
end
function M:GetChildren() return { table.unpack(self._kids) } end
function M:GetDescendants()
    local out = {}
    local function walk(o) for _, c in ipairs(o._kids) do table.insert(out, c) walk(c) end end
    walk(self)
    return out
end
function M:FindFirstChild(name) for _, c in ipairs(self._kids) do if c._p.Name == name then return c end end end
function M:WaitForChild(name) return self:FindFirstChild(name) end
function M:FindFirstChildOfClass(c) for _, k in ipairs(self._kids) do if k._p.ClassName == c then return k end end end
function M:IsDescendantOf(a) local p = self._parent while p do if p == a then return true end p = p._parent end return false end
function M:SetAttribute(k, v) self._attr[k] = v end
function M:GetAttribute(k) return self._attr[k] end
function M:Destroy()
    if self._destroyed then return end
    self.Destroying:Fire()
    for _, c in ipairs(self:GetChildren()) do c:Destroy() end
    if self._parent then self.Parent = nil end
    rawset(self, "_destroyed", true)
end
function M:PivotTo(frame) self._p.CFrame = frame end
function M:GetPivot() return self._p.CFrame or cf(vec()) end
Instance = { new = function(class, parent) local o = new(class) if parent then o.Parent = parent end return o end }

-- World: a ground plane (Terrain) and oriented boxes (the Map) --------------------------------------
workspace = new("Workspace", "Workspace")
local terrain = new("Terrain", "Terrain")
terrain.Parent = workspace
local map = new("Model", "Map")
map.Parent = workspace
workspace._p.Terrain = terrain
GROUND_Y = 0

-- Each box: c (centre), a (three unit axes), h (half sizes), collide, query, name. Bucketed in 8-stud
-- columns so a ray only tests the boxes whose footprint it crosses.
BOXES = {}
local CELL = 8
local grid = {}
local stamp = 0
local function cellKey(i, k) return i * 100003 + k end
function setBoxes(list)
    BOXES = list
    grid = {}
    for index, b in ipairs(list) do
        local ex, ez = 0, 0
        for k = 1, 3 do ex = ex + math.abs(b.a[k].X) * b.h[k] ez = ez + math.abs(b.a[k].Z) * b.h[k] end
        b.lo = vec(b.c.X - ex, 0, b.c.Z - ez) b.hi = vec(b.c.X + ex, 0, b.c.Z + ez)
        for i = math.floor(b.lo.X / CELL), math.floor(b.hi.X / CELL) do
            for k = math.floor(b.lo.Z / CELL), math.floor(b.hi.Z / CELL) do
                local key = cellKey(i, k)
                grid[key] = grid[key] or {}
                table.insert(grid[key], index)
            end
        end
        b.stamp = 0
    end
end
function box(cx, cy, cz, sx, sy, sz, name)
    return { c = vec(cx, cy, cz), a = { vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1) }, h = { sx / 2, sy / 2, sz / 2 },
        collide = true, query = true, name = name or "Box" }
end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
-- Entry distance along d (0..1) of a ray from o, or nil. A ray starting inside a box does not hit it
-- (as in Roblox).
local function rayBox(o, d, b)
    local rel = o - b.c
    local t0, t1 = -math.huge, math.huge
    for k = 1, 3 do
        local e, f, h = dot(rel, b.a[k]), dot(d, b.a[k]), b.h[k]
        if math.abs(f) < 1e-12 then
            if e < -h or e > h then return nil end
        else
            local ta, tb = (-h - e) / f, (h - e) / f
            if ta > tb then ta, tb = tb, ta end
            if ta > t0 then t0 = ta end
            if tb < t1 then t1 = tb end
            if t0 > t1 then return nil end
        end
    end
    if t0 < 0 or t0 > 1 then return nil end
    return t0
end
local function candidates(o, d, fn)
    stamp = stamp + 1
    local x0, x1 = math.min(o.X, o.X + d.X), math.max(o.X, o.X + d.X)
    local z0, z1 = math.min(o.Z, o.Z + d.Z), math.max(o.Z, o.Z + d.Z)
    for i = math.floor(x0 / CELL), math.floor(x1 / CELL) do
        for k = math.floor(z0 / CELL), math.floor(z1 / CELL) do
            for _, index in ipairs(grid[cellKey(i, k)] or {}) do
                local b = BOXES[index]
                if b.stamp ~= stamp then b.stamp = stamp fn(b) end
            end
        end
    end
end
local function includes(params, inst)
    for _, x in ipairs(params and params.FilterDescendantsInstances or {}) do if x == inst then return true end end
    return false
end
RAYS = 0
function M:Raycast(o, d, params)
    RAYS = RAYS + 1
    local include = params and params.FilterType == Enum.RaycastFilterType.Include
    local useMap = not include or includes(params, map)
    local useGround = not include or includes(params, terrain)
    local best, bestBox = nil, nil
    if useMap then
        candidates(o, d, function(b)
            if b.query then
                local t = rayBox(o, d, b)
                if t and (not best or t < best) then best, bestBox = t, b end
            end
        end)
    end
    if useGround and d.Y < 0 and o.Y > GROUND_Y then
        local t = (o.Y - GROUND_Y) / -d.Y
        if t <= 1 and (not best or t < best) then best, bestBox = t, nil end
    end
    if not best then return nil end
    return { Position = o + d * best, Instance = bestBox and map or terrain, Normal = vec(0, 1, 0), Distance = d.Magnitude * best }
end
-- Whether a point is inside a solid (collide) box, by more than `margin`.
function insideSolid(p, margin)
    margin = margin or 0.05
    local hit = nil
    candidates(p, vec(0, 0, 0), function(b)
        if b.collide and not hit then
            local rel = p - b.c
            local inside = true
            for k = 1, 3 do if math.abs(dot(rel, b.a[k])) > b.h[k] - margin then inside = false break end end
            if inside then hit = b.name end
        end
    end)
    return hit
end
-- The loot folder's parts whose position is in the box (what LootService.Resettle asks for).
function M:GetPartBoundsInBox(frame, size, params)
    local out = {}
    for _, root in ipairs(params and params.FilterDescendantsInstances or {}) do
        for _, p in ipairs(root:GetDescendants()) do
            if p:IsA("BasePart") and p._p.CFrame then
                local d = p._p.CFrame.Position - frame.Position
                if math.abs(d.X) <= size.X / 2 and math.abs(d.Y) <= size.Y / 2 and math.abs(d.Z) <= size.Z / 2 then
                    table.insert(out, p)
                end
            end
        end
    end
    return out
end
function M:GetServerTimeNow() return now end
local services = {}
game = { GetService = function(_, name)
    if name == "Workspace" then return workspace end
    local s = services[name]
    if not s then s = new(name, name) services[name] = s end
    return s
end }
local tween = game:GetService("TweenService")
function tween.Create(_, inst, _, props)
    return { Play = function() for k, v in pairs(props) do inst[k] = v end end, Completed = signal(), Cancel = function() end }
end

-- Modules ------------------------------------------------------------------------------------------
local loaded, loaders = {}, {}
function require(marker)
    local name = type(marker) == "table" and marker._p and marker._p.Name or marker
    if loaded[name] == nil then
        local f = loaders[name]
        if not f then
            -- Any other shared module WeaponData pulls in (CreativeRounds, ...): the real file.
            local text = SOURCES.__shared(name)
            if text then source(name, text) f = loaders[name] end
        end
        if not f then error("no module " .. tostring(name)) end
        loaded[name] = f()
    end
    return loaded[name]
end
local function folder(name) return setmetatable({ _p = { Name = name } }, { __index = function(_, k)
    if k == "WaitForChild" or k == "FindFirstChild" then return function(_, child) return folder(child) end end
end }) end
services.ReplicatedStorage = folder("ReplicatedStorage")
function source(name, text)
    loaders[name] = function()
        local env = setmetatable({ script = { Parent = folder("Parent"), Name = name } }, { __index = _G })
        local chunk, err = load(text, "=" .. name, "t", env)
        if not chunk then error(name .. ": " .. err) end
        return chunk()
    end
end
function mock(name, value) loaded[name] = value end
for _, name in ipairs({ "Rarity", "ItemData", "WeaponData", "ArsenalExpansion", "CreativeArsenal", "WorkshopArsenal",
    "LootService", "SupplyDropService" }) do
    source(name, SOURCES[name])
end

function part(parent, name)
    local p = new("Part", name or "Part")
    p.Parent = parent
    return p
end
mock("ZFight", { Fix = function() end })
mock("ItemModels", { Build = function(id) local m = new("Model", id) part(m, "Body") return m end })
mock("CrateModels", { Chest = function(frame) local c = new("Part", "Chest") c.CFrame = frame * CFrame.new(0, 1.3, 0) c.Size = vec(3.6, 2, 2.6) part(c, "Lid") return c end })
mock("Remotes", { Event = function() return { FireAllClients = function() end, FireClient = function() end, OnServerEvent = signal() } end })
BROKEN = {}
mock("DestructibleService", { OnPartBroken = function(fn) table.insert(BROKEN, fn) return fn end,
    RestingOn = function() return {} end, SettleDown = function() end })
QUESTS = {}
mock("QuestService", { Progress = function(player, key, n) table.insert(QUESTS, player.Name .. ":" .. key) end })
NOTICES = {}
mock("StateSync", { Notify = function(player, text) NOTICES[player.Name] = NOTICES[player.Name] or {} table.insert(NOTICES[player.Name], text) end, Push = function() end })
mock("StormService", { GetState = function() return { center = vec(0, 0, 0), radius = 400 } end })

-- The bag: every way anything reaches a player's inventory lands in BAG[name]. Ammo is kept apart:
-- there is no ground pickup for ammo, and #85 leaves it going straight to the opener.
BAG, AMMO = {}, {}
local function bagOf(player) BAG[player.Name] = BAG[player.Name] or {} return BAG[player.Name] end
local shields = {}
mock("WeaponService", {
    GiveWeapon = function(player, id, carried) table.insert(bagOf(player), "weapon:" .. id) return true, "Picked up " .. id, nil end,
    GiveConsumable = function(player, id, amount) table.insert(bagOf(player), "item:" .. id .. "x" .. amount) return amount end,
    SwapHeldForItem = function(player, id, amount) table.insert(bagOf(player), "item:" .. id .. "x" .. amount) return nil, 0 end,
    GiveAmmo = function(player, fraction) AMMO[player.Name] = (AMMO[player.Name] or 0) + fraction return true end,
    HasFreeSlot = function() return true end,
    Get = function() return nil end,
    Shields = shields,
    BuildStaticGun = function(def, color, material, frame, parent) local g = part(parent, "Gun") g.CFrame = frame return g end,
})
for id, item in pairs(require("ItemData").Items) do if item.kind == "shield" then shields[id] = { name = item.name } end end

-- BotService.Loot.claimConsumable, cut from BotService.lua, with the bot's stock recorded.
BOTGOT = {}
local ItemDataRef = require("ItemData")
local claimEnv = setmetatable({
    LootService = require("LootService"), WeaponService = require("WeaponService"),
    STATS = { lootStocked = 0 },
    BotService = { Loot = { throwableKind = function(id) local it = ItemDataRef.Get(id) return it and it.kind == "throwable" and id or nil end } },
    giveBotHeal = function(bot, id, n) table.insert(BOTGOT, "heal:" .. id) end,
    giveBotShield = function(bot, id, n) table.insert(BOTGOT, "shield:" .. id) end,
    giveBotThrowable = function(bot, kind, n) table.insert(BOTGOT, "throwable:" .. kind) end,
}, { __index = _G })
assert(load(SOURCES.claimConsumable, "=claimConsumable", "t", claimEnv))()
claimConsumable = claimEnv.BotService.Loot.claimConsumable

-- TeamBattleground's loot seeding, cut from TeamBattleground.lua.
local bgEnv = setmetatable({ TeamBattleground = {}, ReplicatedStorage = services.ReplicatedStorage,
    script = { Parent = folder("Modules") } }, { __index = _G })
assert(load(SOURCES.bgLoot .. "\nreturn TeamBattleground", "=TeamBattlegroundLoot", "t", bgEnv))()
Battleground = bgEnv.TeamBattleground
"""


HARNESS = r"""
local FRENZY_GUNS = ...
local results = {}
local function check(tag, name, ok, detail) table.insert(results, { tag, name, ok and "ok" or "FAIL", detail or "" }) end
local function finding(tag, name, detail) table.insert(results, { tag, name, "FINDING", detail or "" }) end

local LootService = require("LootService")
local SupplyDropService = require("SupplyDropService")
local ItemData = require("ItemData")
local WeaponData = require("WeaponData")
local Rarity = require("Rarity")

-- What a container rolls, recorded as it rolls it.
local ROLLS = nil
local function wrap(tbl, key, fmt)
    local f = tbl[key]
    tbl[key] = function(...) local r = f(...) if ROLLS then table.insert(ROLLS, fmt(r)) end return r end
end
wrap(WeaponData, "RollChestWeapon", function(def) return "weapon:" .. def.id end)
for _, key in ipairs({ "RollRecovery", "RollMovement", "RollDefense", "RollThrowable" }) do
    wrap(ItemData, key, function(item) return "item:" .. item.id .. "x" .. item.pickup end)
end

local PICKUP = { GroundWeapon = true, HealPickup = true, ItemPickup = true }
local function lootFolder() return workspace:FindFirstChild("Loot") end
local function pickups()
    local out = {}
    local f = lootFolder()
    for _, item in ipairs(f and f:GetChildren() or {}) do if PICKUP[item.Name] then table.insert(out, item) end end
    return out
end
local function keyOf(item)
    if item.Name == "GroundWeapon" then return "weapon:" .. tostring(item:GetAttribute("WeaponId")) end
    return "item:" .. tostring(item:GetAttribute("ItemId")) .. "x" .. tostring(item:GetAttribute("Amount"))
end
local function keys(list) local out = {} for _, i in ipairs(list) do table.insert(out, keyOf(i)) end table.sort(out) return out end
local function joined(list) return table.concat(list, ",") end
local function sorted(list) local c = table.clone(list) table.sort(c) return c end
local function newItems(before)
    local seen = {}
    for _, i in ipairs(before) do seen[i] = true end
    local out = {}
    for _, i in ipairs(pickups()) do if not seen[i] then table.insert(out, i) end end
    return out
end
local players = 0
local function newPlayer(at)
    players = players + 1
    local player = new("Player", "P" .. players)
    if at then
        local character = new("Model", player.Name)
        local root = part(character, "HumanoidRootPart")
        root.CFrame = CFrame.new(at)
        character.PrimaryPart = root
        player.Character = character
    end
    return player
end
local function promptOf(inst) return inst and inst:FindFirstChildOfClass("ProximityPrompt") end
-- A press as the server sees it: Triggered fires whatever the client's prompt showed.
local function press(inst, player) local prompt = promptOf(inst) if prompt then prompt.Triggered:Fire(player) end end
local function chests()
    local out = {}
    local f = lootFolder()
    for _, item in ipairs(f and f:GetChildren() or {}) do if item.Name == "Chest" then table.insert(out, item) end end
    return out
end
local function reset()
    LootService.Clear()
    SupplyDropService.Stop()
    advance(5)
    BAG, AMMO, NOTICES = {}, {}, {}
end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function around(centre, r)
    local a = math.random() * math.pi * 2
    return centre + Vector3.new(math.cos(a) * r, 3, math.sin(a) * r)
end

-- Opens `chest` as `player` and returns what landed and what was rolled.
local function openChest(chest, player)
    local before = pickups()
    ROLLS = {}
    press(chest, player)
    local rolled = ROLLS
    ROLLS = nil
    return newItems(before), rolled
end

-- Positions of a spill, for the P rows.
SPILLS = {}
local function record(scene, name, centre, floorY, items, kind)
    local row = { scene = scene, name = name, cx = centre.X, cy = centre.Y, cz = centre.Z, floor = floorY, kind = kind, items = {} }
    for _, i in ipairs(items) do
        local p = i.Position - Vector3.new(0, 0.3, 0)
        local below = workspace:Raycast(p + Vector3.new(0, 0.5, 0), Vector3.new(0, -1.2, 0), { FilterType = Enum.RaycastFilterType.Exclude })
        table.insert(row.items, { x = p.X, y = p.Y, z = p.Z, key = keyOf(i),
            inside = insideSolid(p + Vector3.new(0, 0.3, 0)) or "", supported = below ~= nil })
    end
    table.insert(SPILLS, row)
end

------------------------------------------------------------------------------------------------------
-- A. Every container, opened by a player
------------------------------------------------------------------------------------------------------
setBoxes({})
local stats = { chests = 0, mismatched = {}, bagged = {}, notices = 0, items = 0 }
local function tally(label, items, rolled, player)
    stats.chests = stats.chests + 1
    stats.items = stats.items + #items
    if joined(keys(items)) ~= joined(sorted(rolled)) then
        table.insert(stats.mismatched, label .. ": rolled " .. joined(sorted(rolled)) .. " landed " .. joined(keys(items)))
    end
    if #(BAG[player.Name] or {}) > 0 then table.insert(stats.bagged, label .. ": " .. joined(BAG[player.Name])) end
    local n = NOTICES[player.Name] or {}
    if n[#n] and n[#n]:find("on the ground", 1, true) then stats.notices = stats.notices + 1 end
end

-- A1: map chests, through Populate (the battle royale's call), 2 guns a chest and then Loot Frenzy's.
local function populateChests(count, spacing)
    local spots = {}
    for i = 1, count do spots[i] = CFrame.new(((i - 1) % 10) * spacing, 0, math.floor((i - 1) / 10) * spacing) end
    task.spawn(LootService.Populate, { chestSpots = spots })
    advance(1)
    return chests()
end
for _, guns in ipairs({ 2, FRENZY_GUNS }) do
    LootService.ChestGuns = guns
    for round = 1, 8 do
        reset()
        for _, chest in ipairs(populateChests(40, 40)) do
            local player = newPlayer(around(chest.Position, 5))
            local items, rolled = openChest(chest, player)
            tally("map chest (" .. guns .. " guns)", items, rolled, player)
            local c = chest.Position
            record("flat", "map", c, c.Y - 1.3, items, "chest")
        end
    end
end
LootService.ChestGuns = 2
local mapChests = stats.chests
check("A", "A1 a map chest (Populate) spills every roll as exactly one pickup, 2 guns and Loot Frenzy's " .. FRENZY_GUNS,
    #stats.mismatched == 0 and mapChests > 100, realFormat("%d chests, %d pickups, %d mismatched%s", mapChests, stats.items,
        #stats.mismatched, stats.mismatched[1] and (": " .. stats.mismatched[1]) or ""))
check("A", "A1 a map chest puts nothing in the opener's bag (ammo only), and the toast says on the ground",
    #stats.bagged == 0 and stats.notices == stats.chests, realFormat("%d bags touched%s; %d/%d toasts", #stats.bagged,
        stats.bagged[1] and (": " .. stats.bagged[1]) or "", stats.notices, stats.chests))

-- A1b: an Aura Farm floor (the first gun rerolled to Epic or better): still one pickup per gun.
reset()
LootService.ChestRarityFloor = "Epic"
local floorBad, floorN = 0, 0
for _, chest in ipairs(populateChests(40, 40)) do
    local player = newPlayer(around(chest.Position, 5))
    local items = openChest(chest, player)
    floorN = floorN + 1
    local guns, best = 0, 0
    for _, i in ipairs(items) do
        if i.Name == "GroundWeapon" then
            guns = guns + 1
            best = math.max(best, Rarity.Index[WeaponData.Get(i:GetAttribute("WeaponId")).rarity] or 0)
        end
    end
    if guns ~= 2 or #(BAG[player.Name] or {}) > 0 then floorBad = floorBad + 1 end
end
LootService.ChestRarityFloor = nil
check("A", "A1 with a rarity floor (Aura Farm) a chest still spills its 2 guns, none in the bag", floorBad == 0,
    realFormat("%d chests, %d wrong", floorN, floorBad))

-- A2: team-base chests, through SeedAt (GameMode's restock call).
stats = { chests = 0, mismatched = {}, bagged = {}, notices = 0, items = 0 }
reset()
local spots = {}
for i = 1, 60 do spots[i] = Vector3.new((i % 10) * 40, 0, math.floor(i / 10) * 40 + 600) end
task.spawn(LootService.SeedAt, spots, "chest")
advance(1)
for _, chest in ipairs(chests()) do
    local player = newPlayer(around(chest.Position, 4))
    local items, rolled = openChest(chest, player)
    tally("base chest", items, rolled, player)
end
check("A", "A2 a team-base chest (LootService.SeedAt) spills every roll as one pickup, nothing in the bag",
    stats.chests == 60 and #stats.mismatched == 0 and #stats.bagged == 0,
    realFormat("%d chests, %d pickups, %d mismatched, %d bags touched", stats.chests, stats.items, #stats.mismatched, #stats.bagged))

-- A3: the battleground's chest, through TeamBattleground.SeedLoot.
stats = { chests = 0, mismatched = {}, bagged = {}, notices = 0, items = 0 }
for round = 1, 20 do
    reset()
    local info = { alive = true, lootSpots = { { name = "KeepGallery", position = Vector3.new(15, 0, -15), kind = "chest" } } }
    Battleground.SeedLoot(info)
    advance(1)
    info.alive = false
    for _, chest in ipairs(chests()) do
        local player = newPlayer(around(chest.Position, 4))
        local items, rolled = openChest(chest, player)
        tally("battleground chest", items, rolled, player)
    end
end
advance(80)
check("A", "A3 the battleground's chest (TeamBattleground.SeedLoot) spills every roll as one pickup, nothing in the bag",
    stats.chests == 20 and #stats.mismatched == 0 and #stats.bagged == 0,
    realFormat("%d chests, %d pickups, %d mismatched, %d bags touched", stats.chests, stats.items, #stats.mismatched, #stats.bagged))

-- A4: a chest rebuilt by Resettle (its floor broke under it) still spills.
stats = { chests = 0, mismatched = {}, bagged = {}, notices = 0, items = 0 }
local resettled = 0
for round = 1, 20 do
    reset()
    local platform = box(0, 9.5, 0, 12, 1, 12, "Platform")
    setBoxes({ platform })
    task.spawn(LootService.SeedAt, { Vector3.new(0, 10, 0) }, "chest")
    advance(0.1)
    setBoxes({})
    for _, fn in ipairs(BROKEN) do fn(CFrame.new(0, 9.5, 0), Vector3.new(12, 1, 12)) end
    advance(0.1)
    for _, chest in ipairs(chests()) do
        if chest.Position.Y < 3 then resettled = resettled + 1 end
        local player = newPlayer(around(chest.Position, 4))
        local items, rolled = openChest(chest, player)
        tally("resettled chest", items, rolled, player)
    end
end
check("A", "A4 a chest rebuilt on the ground after its floor broke (Resettle) spills every roll as one pickup",
    resettled == 20 and stats.chests == 20 and #stats.mismatched == 0 and #stats.bagged == 0,
    realFormat("%d of 20 came down, %d opened, %d mismatched, %d bags touched", resettled, stats.chests, #stats.mismatched, #stats.bagged))

-- A5: the supply crate, through SupplyDropService.Start (first drop at 75 s, 9 s fall).
local function landedCrate()
    local f = workspace:FindFirstChild("SupplyDrops")
    for _, c in ipairs(f and f:GetChildren() or {}) do
        if c.Name == "SupplyCrate" and c:GetAttribute("Landed") and not c:GetAttribute("Claimed") then return c end
    end
end
local function dropCrate()
    SupplyDropService.Stop()
    SupplyDropService.Start()
    advance(75 + 9 + 0.05)
    return landedCrate()
end
local crateBad, crateN, crateBag, crateAmmo, crateNotice = {}, 0, 0, 0, 0
for round = 1, 60 do
    reset()
    local crate = dropCrate()
    if crate then
        crateN = crateN + 1
        local player = newPlayer(around(crate.Position, 8))
        local before = pickups()
        press(crate, player)
        local items = newItems(before)
        local want = sorted({ "weapon:" .. crate:GetAttribute("WeaponId"), "item:MedKitx1", "item:ShieldPotionx1", "item:PopupBunkerx1" })
        if joined(keys(items)) ~= joined(want) then table.insert(crateBad, joined(keys(items))) end
        if #(BAG[player.Name] or {}) > 0 then crateBag = crateBag + 1 end
        if (AMMO[player.Name] or 0) == 1 then crateAmmo = crateAmmo + 1 end
        local n = NOTICES[player.Name] or {}
        if n[1] and n[1]:find("on the ground", 1, true) then crateNotice = crateNotice + 1 end
        record("flat", "crate", crate.Position, crate.Position.Y - 4, items, "crate")
    end
end
check("A", "A5 a supply crate (SupplyDropService.Start) spills its gun, MedKit, Shield Potion and Pop-up Bunker as one pickup each",
    crateN == 60 and #crateBad == 0, realFormat("%d crates, %d wrong%s", crateN, #crateBad, crateBad[1] and (": " .. crateBad[1]) or ""))
check("A", "A5 a supply crate puts nothing in the bag; the opener gets a full ammo refill and a toast naming the spill",
    crateBag == 0 and crateAmmo == crateN and crateNotice == crateN, realFormat("%d bags touched, %d/%d refills, %d/%d toasts",
        crateBag, crateAmmo, crateN, crateNotice, crateN))

-- A6: an opener with no character (a fault or a respawn mid-hold) still gets a spill, not a bag.
reset()
local lone = populateChests(20, 40)[1]
local ghost = newPlayer(nil)
local ghostItems, ghostRolled = openChest(lone, ghost)
reset()
local ghostCrate = dropCrate()
local ghost2 = newPlayer(nil)
local before = pickups()
press(ghostCrate, ghost2)
local ghostCrateItems = newItems(before)
check("A", "A6 an opener with no character: the chest and the crate still spill (in front, +Z), nothing in the bag",
    #ghostItems == #ghostRolled and #ghostItems > 0 and #ghostCrateItems == 4 and #(BAG[ghost.Name] or {}) == 0
        and #(BAG[ghost2.Name] or {}) == 0, realFormat("chest %d of %d, crate %d of 4", #ghostItems, #ghostRolled, #ghostCrateItems))

-- Bots open containers through a different door.
reset()
local botChest = populateChests(20, 40)[1]
local before2 = pickups()
local botDef = LootService.ClaimForBot(botChest)
local botChestLanded = #newItems(before2)
finding("B", "B1 a bot opening a chest (LootService.ClaimForBot) takes ONE gun straight to itself; nothing lands",
    realFormat("got %s; pickups landed %d; chest opened %s (a player's opening of the same chest lands %d guns + 1-5 items)",
        botDef and botDef.id or "nil", botChestLanded, tostring(botChest:GetAttribute("Opened")), LootService.ChestGuns))
reset()
local botCrate = dropCrate()
local before3 = pickups()
local botCrateDef = SupplyDropService.ClaimForBot(botCrate)
finding("B", "B2 a bot opening a supply crate (SupplyDropService.ClaimForBot) takes the gun straight to itself; nothing lands",
    realFormat("got %s (crate's %s); pickups landed %d", botCrateDef and botCrateDef.id or "nil", tostring(botCrate:GetAttribute("WeaponId")),
        #newItems(before3)))

------------------------------------------------------------------------------------------------------
-- S. The settle second
------------------------------------------------------------------------------------------------------
local function spillOf(kind)
    reset()
    if kind == "crate" then
        local crate = dropCrate()
        local player = newPlayer(around(crate.Position, 8))
        local b = pickups()
        press(crate, player)
        return newItems(b), player
    end
    LootService.ChestGuns = 2
    local chest = populateChests(20, 40)[1]
    local player = newPlayer(around(chest.Position, 5))
    return (openChest(chest, player)), player
end
for _, kind in ipairs({ "crate", "chest" }) do
    local items, opener = spillOf(kind)
    local off, marked = 0, 0
    for _, i in ipairs(items) do
        if (promptOf(i) or {}).Enabled == false then off = off + 1 end
        if i:GetAttribute("Settling") then marked = marked + 1 end
    end
    check("S", "S1 " .. kind .. ": every spilled pickup lands with its prompt off and Settling set", off == #items and marked == #items and #items > 0,
        realFormat("%d pickups, %d prompts off, %d settling", #items, off, marked))
    -- The held key and a forged press, at 0, 0.5 and 0.95 s: the server refuses every one.
    local taken = 0
    for _, at in ipairs({ 0, 0.5, 0.45 }) do
        advance(at)
        for _, i in ipairs(items) do if i.Parent then press(i, opener) end end
        taken = taken + #(BAG[opener.Name] or {})
    end
    local still = 0
    for _, i in ipairs(items) do if i.Parent then still = still + 1 end end
    check("S", "S2 " .. kind .. ": presses at 0, 0.5 and 0.95 s take nothing (the server checks Settling, not only the prompt)",
        taken == 0 and still == #items, realFormat("taken %d, still on the ground %d of %d", taken, still, #items))
    advance(0.051)
    local on = 0
    for _, i in ipairs(items) do if (promptOf(i) or {}).Enabled and not i:GetAttribute("Settling") then on = on + 1 end end
    for _, i in ipairs(items) do press(i, opener) end
    local got = sorted(BAG[opener.Name] or {})
    check("S", "S3 " .. kind .. ": at 1.0 s every prompt is back on and a fresh press takes each pickup into the bag",
        on == #items and joined(got) == joined(keys(items)), realFormat("%d of %d back on; bag %s", on, #items, joined(got)))
end
-- The exact delay, stepped in 10 ms.
do
    local items = spillOf("crate")
    local gun
    for _, i in ipairs(items) do if i.Name == "GroundWeapon" then gun = i end end
    local t0, waited = clock(), nil
    for step = 1, 300 do
        advance(0.01)
        if not gun:GetAttribute("Settling") then waited = clock() - t0 break end
    end
    check("S", "S4 the settle lasts 1.00 s (DROP_SETTLE), measured in 10 ms steps", waited and math.abs(waited - 1) < 0.011,
        realFormat("%.2f s", waited or -1))
end
-- No walk-over pickup: nothing on any pickup, chest or crate listens for Touched.
do
    local touched, examined = 0, 0
    reset()
    local chest = populateChests(20, 40)[1]
    local items = openChest(chest, newPlayer(around(chest.Position, 5)))
    local crate = dropCrate()
    local b = pickups()
    press(crate, newPlayer(around(crate.Position, 8)))
    for _, i in ipairs(newItems(b)) do table.insert(items, i) end
    for _, i in ipairs(items) do
        for _, p in ipairs({ i, table.unpack(i:GetDescendants()) }) do
            examined = examined + 1
            if p._sig.Touched and #p._sig.Touched.handlers > 0 then touched = touched + 1 end
        end
    end
    check("S", "S5 no pickup takes itself on touch: 0 Touched handlers on every spilled pickup and its parts", touched == 0 and examined > 20,
        realFormat("%d instances examined, %d with a Touched handler", examined, touched))
end
-- Bots don't wait for the settle.
do
    local items = spillOf("crate")
    local gun, med, shield
    for _, i in ipairs(items) do
        if i.Name == "GroundWeapon" then gun = i elseif i:GetAttribute("ItemId") == "MedKit" then med = i
        elseif i:GetAttribute("ItemId") == "ShieldPotion" then shield = i end
    end
    advance(0.05)
    local a = gun and LootService.ClaimForBot(gun)
    local b = { med and LootService.ClaimHealForBot(med) }
    BOTGOT = {}
    local c = shield and claimConsumable({}, shield)
    finding("B", "B3 bots skip the settle: 0.05 s after a crate spill lands a bot can claim its gun, MedKit and Shield Potion",
        realFormat("ClaimForBot -> %s, ClaimHealForBot -> %s, claimConsumable -> %s (%s); the player's prompts are still off",
            a and a.id or "nil", tostring(b[1]), tostring(c), joined(BOTGOT)))
end

------------------------------------------------------------------------------------------------------
-- R. Races, duplication, lifetime
------------------------------------------------------------------------------------------------------
do
    reset()
    local chest = populateChests(20, 40)[1]
    local p1, p2 = newPlayer(around(chest.Position, 5)), newPlayer(around(chest.Position, 5))
    local b = pickups()
    ROLLS = {}
    press(chest, p1)
    press(chest, p2)
    local rolled = ROLLS
    ROLLS = nil
    local items = newItems(b)
    local crate = dropCrate()
    local q1, q2 = newPlayer(around(crate.Position, 8)), newPlayer(around(crate.Position, 8))
    local cb = pickups()
    press(crate, q1)
    press(crate, q2)
    local crateItems = newItems(cb)
    check("R", "R1 two presses in one frame spill once: a chest's roll lands once, a crate's 4 pieces once",
        #items == #rolled and joined(keys(items)) == joined(sorted(rolled)) and #crateItems == 4 and not NOTICES[p2.Name] and not NOTICES[q2.Name],
        realFormat("chest %d pickups for %d rolls, crate %d pickups; second presser's toasts %s/%s", #items, #rolled, #crateItems,
            tostring(NOTICES[p2.Name] and #NOTICES[p2.Name]), tostring(NOTICES[q2.Name] and #NOTICES[q2.Name])))
end
do
    reset()
    local pair = populateChests(20, 40)
    local c1, c2 = pair[1], pair[2]
    local p = newPlayer(around(c1.Position, 5))
    press(c1, p)
    local botAfterPlayer = LootService.ClaimForBot(c1)
    local botFirst = LootService.ClaimForBot(c2)
    local b = pickups()
    press(c2, p)
    local afterBot = #newItems(b)
    local cr = dropCrate()
    press(cr, newPlayer(around(cr.Position, 8)))
    local crateBotAfter = SupplyDropService.ClaimForBot(cr)
    local cr2 = dropCrate()
    local botCrateFirst = SupplyDropService.ClaimForBot(cr2)
    local b2 = pickups()
    press(cr2, newPlayer(around(cr2.Position, 8)))
    local crateAfterBot = #newItems(b2)
    check("R", "R2 a player and a bot never both open one container, in either order (chest and crate)",
        botAfterPlayer == nil and botFirst ~= nil and afterBot == 0 and crateBotAfter == nil and botCrateFirst ~= nil and crateAfterBot == 0,
        realFormat("bot after player: %s/%s; player after bot: %d/%d pickups", tostring(botAfterPlayer), tostring(crateBotAfter), afterBot, crateAfterBot))
end
do
    local items = spillOf("crate")
    advance(1.05)
    local gun, med
    for _, i in ipairs(items) do
        if i.Name == "GroundWeapon" then gun = i elseif i:GetAttribute("ItemId") == "MedKit" then med = i end
    end
    local a, b = newPlayer(Vector3.new(0, 3, 0)), newPlayer(Vector3.new(0, 3, 0))
    -- Both presses reach the server in one frame: the second arrives on the prompt of a pickup the first took.
    local gp, mp = promptOf(gun), promptOf(med)
    if gp then gp.Triggered:Fire(a) gp.Triggered:Fire(b) end
    if mp then mp.Triggered:Fire(a) mp.Triggered:Fire(b) end
    local got = #(BAG[a.Name] or {}) + #(BAG[b.Name] or {})
    check("R", "R3 two players pressing one spilled gun and one MedKit in the same frame: each goes to exactly one bag",
        gun and med and got == 2 and not gun.Parent and not med.Parent, realFormat("%d grants for 2 pickups (gun %s, MedKit %s)", got,
            tostring(gun ~= nil), tostring(med ~= nil)))
end
do
    reset()
    local chest = populateChests(20, 40)[1]
    local p = newPlayer(around(chest.Position, 5))
    local chestPrompt = promptOf(chest)
    local items = openChest(chest, p)
    advance(2.3)
    local chestGone = chest.Parent == nil
    local crate = dropCrate()
    local cb = pickups()
    press(crate, newPlayer(around(crate.Position, 8)))
    for _, i in ipairs(newItems(cb)) do table.insert(items, i) end
    advance(1.7)
    local crateGone = crate.Parent == nil
    local b = pickups()
    chestPrompt.Triggered:Fire(p)
    local again = #newItems(b)
    SupplyDropService.Stop()
    advance(600)
    local left = 0
    for _, i in ipairs(items) do if i.Parent then left = left + 1 end end
    check("R", "R4 the chest (2.2 s) and the crate (1.6 s) go, a late press spills nothing, and the spill outlives both, the drops' Stop and 600 s",
        chestGone and crateGone and again == 0 and left == #items,
        realFormat("chest gone %s, crate gone %s, late press %d, %d of %d still there", tostring(chestGone), tostring(crateGone), again, left, #items))
end
-- The dropped-item cap (Oliver 09-22: 50) removes the oldest drop, spills included.
do
    local items = spillOf("crate")
    local n, firstGone = 0, nil
    for k = 1, 60 do
        LootService.DropHeal(Vector3.new(500 + k * 5, 0, 500))
        n = k
        local gone = 0
        for _, i in ipairs(items) do if not i.Parent then gone = gone + 1 end end
        if gone > 0 and not firstGone then firstGone = k end
    end
    finding("R", "R5 the 50-drop cap: an untouched crate spill (a Legendary can be in it) starts going after this many newer drops anywhere",
        realFormat("%s newer drops (4-piece spill; a bot's death drops 1-5, a chest spill 3-%d)", tostring(firstGone), FRENZY_GUNS + 5))
end
-- Resettle rebuilds a pickup without the settle and outside the cap's list.
do
    reset()
    setBoxes({ box(0, 9.5, 0, 16, 1, 16, "Platform") })
    local chest = nil
    task.spawn(LootService.SeedAt, { Vector3.new(0, 10, 0) }, "chest")
    advance(0.1)
    chest = chests()[1]
    local p = newPlayer(chest.Position + Vector3.new(0, 1, -5))
    local items = openChest(chest, p)
    setBoxes({})
    for _, fn in ipairs(BROKEN) do fn(CFrame.new(0, 9.5, 0), Vector3.new(16, 1, 16)) end
    advance(0.05)
    local rebuilt = {}
    for _, i in ipairs(pickups()) do if i.Position.Y < 3 then table.insert(rebuilt, i) end end
    local open = 0
    for _, i in ipairs(rebuilt) do if (promptOf(i) or {}).Enabled and not i:GetAttribute("Settling") then open = open + 1 end end
    for k = 1, 60 do LootService.DropHeal(Vector3.new(800 + k * 5, 0, 800)) end
    local survived = 0
    for _, i in ipairs(rebuilt) do if i.Parent then survived = survived + 1 end end
    finding("R", "R6 a spill whose floor breaks inside its settle second is rebuilt (Resettle) takeable at once and outside the 50-drop cap",
        realFormat("%d of %d spilled pickups came down; %d of them with the prompt already on, 0.05 s after the spill; %d of them still there after 60 newer drops",
            #rebuilt, #items, open, survived))
end

------------------------------------------------------------------------------------------------------
-- P. Where a spill lands: hand-made scenes (checked here), real geometry (rows back to Python)
------------------------------------------------------------------------------------------------------
local function sceneTrials(scene, boxes, chestAt, openerAt, trials)
    local rows = 0
    for t = 1, trials do
        reset()
        setBoxes(boxes)
        task.spawn(LootService.SeedAt, { chestAt }, "chest")
        advance(0.1)
        local chest = chests()[1]
        if chest then
            local items = openChest(chest, newPlayer(openerAt))
            record(scene, scene, chest.Position, chest.Position.Y - 1.3, items, "chest")
            rows = rows + 1
        end
    end
    setBoxes({})
    return rows
end
-- A 6-wide corridor (walls 1 thick at x = +-3.5), the opener down the corridor.
sceneTrials("corridor", { box(-3.5, 5, 0, 1, 10, 60, "WallW"), box(3.5, 5, 0, 1, 10, 60, "WallE") },
    Vector3.new(0, 0, 0), Vector3.new(0, 3, -5), 60)
-- A 12x12 roof, top at 12, the opener on it toward the edge.
sceneTrials("roof", { box(0, 11.5, 0, 12, 1, 12, "Roof") }, Vector3.new(0, 12, 0), Vector3.new(0, 15, -4), 60)
-- A 3-wide gallery 11 up, the opener along it.
sceneTrials("gallery", { box(0, 10.5, 0, 40, 1, 3, "Gallery") }, Vector3.new(0, 11, 0), Vector3.new(-4, 14, 0), 60)

-- Real geometry: GEOMETRY = { name = { boxes, chests = { {name, x, y, z, openers = {{x,y,z}...}} } } }
function realTrials(scene, chestList, trials)
    local n = 0
    for _, spot in ipairs(chestList) do
        for _, opener in ipairs(spot.openers) do
            for t = 1, trials do
                LootService.Clear()
                advance(3)
                BAG = {}
                task.spawn(LootService.SeedAt, { Vector3.new(spot.x, spot.y, spot.z) }, "chest")
                advance(0.1)
                local chest = chests()[1]
                if chest then
                    local items = openChest(chest, newPlayer(Vector3.new(opener.x, opener.y + 3, opener.z)))
                    record(scene, spot.name, chest.Position, chest.Position.Y - 1.3, items, "chest")
                    n = n + 1
                end
            end
        end
    end
    return n
end
function chestFloor(x, y, z)
    LootService.Clear()
    advance(3)
    task.spawn(LootService.SeedAt, { Vector3.new(x, y, z) }, "chest")
    advance(0.1)
    local chest = chests()[1]
    local out = chest and (chest.Position.Y - 1.3) or nil
    LootService.Clear()
    return out
end
function rayDown(x, y, z, reach)
    local hit = workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -reach, 0), { FilterType = Enum.RaycastFilterType.Exclude })
    return hit and hit.Position.Y or nil
end
function clearLine(x0, y0, z0, x1, y1, z1)
    local o = Vector3.new(x0, y0, z0)
    return workspace:Raycast(o, Vector3.new(x1, y1, z1) - o, { FilterType = Enum.RaycastFilterType.Exclude }) == nil
end
function solidAt(x, y, z)
    return insideSolid(Vector3.new(x, y, z), 0.0) ~= nil
end

-- The battleground's restock (every 75 s, a spot counts as taken while a pickup lies within 3 studs of it).
function restockTrial(boxes, spotList, restocks)
    reset()
    setBoxes(boxes)
    local info = { alive = true, lootSpots = spotList }
    Battleground.SeedLoot(info)
    advance(1)
    local counts = {}
    local gallery = nil
    for _, s in ipairs(spotList) do if s.kind == "chest" then gallery = s end end
    -- A player opens the gallery chest at 10 s and leaves the spill.
    advance(9)
    local spill = {}
    local chest = nil
    for _, c in ipairs(chests()) do if (flat(c.Position) - flat(gallery.position)).Magnitude < 4 then chest = c end end
    if chest then spill = openChest(chest, newPlayer(chest.Position + Vector3.new(0, 1, 4))) end
    local spillGoneAt = nil
    for r = 1, restocks do
        advance(75)
        -- Each gun once, however many floor spots it lies near.
        local near = 0
        for _, i in ipairs(pickups()) do
            if i.Name == "GroundWeapon" then
                for _, s in ipairs(spotList) do
                    if s.kind == "weapon" and s.floor and (flat(i.Position) - flat(s.position)).Magnitude < 12 then near = near + 1 break end
                end
            end
        end
        counts[r] = near
        if not spillGoneAt then
            for _, i in ipairs(spill) do if not i.Parent then spillGoneAt = r break end end
        end
    end
    info.alive = false
    advance(80)
    setBoxes({})
    return counts, #spill, spillGoneAt
end

return results
"""


# ------------------------------------------------------------------------------------------------
# Real geometry
# ------------------------------------------------------------------------------------------------

def load_geometry(root):
    """The team-base compound and the battleground, laid out by their real modules, as boxes."""
    import team_base_ruins_check as TBR
    out = {}
    build = TBR.Build(TBR.sources(root))
    frame, model, info = build.layout(0, 0, 0, 0, TBR.TEAM1, TBR.SEED)
    parts = build.dump(model)
    for p in parts:
        p["aabb"] = TBR.aabb(p)
    chests = build.cfs(info["localChests"])
    names = [info["names"]["chests"][i + 1] for i in range(len(chests))]
    pads = [c[:3] for c in build.cfs(info["localPads"])]
    walk = TBR.Walk(parts)
    seen = walk.flood([(p[0], p[2]) for p in pads])
    out["ruin"] = {"parts": parts, "chests": [(n, c[0], c[1], c[2]) for n, c in zip(names, chests)], "walk": walk, "seen": seen}
    try:
        import team_battleground_check as TBG
    except ImportError as err:
        out["battleground_error"] = str(err)
        return out
    rt = TBG.Runtime(TBG.sources(root))
    model, info_lua = rt.layout(TBG.SEED)
    bparts = rt.dump(model)
    binfo = TBG.read_info(rt, info_lua)
    out["battleground"] = {"parts": bparts, "loot": binfo["loot"],
                           "chests": [(s["name"], *s["at"]) for s in binfo["loot"] if s["kind"] == "chest"]}
    return out


def lua_boxes(lua, parts):
    make = lua.eval("function(cx, cy, cz, a1x, a1y, a1z, a2x, a2y, a2z, a3x, a3y, a3z, hx, hy, hz, collide, query, name) "
                    "return { c = Vector3.new(cx, cy, cz), a = { Vector3.new(a1x, a1y, a1z), Vector3.new(a2x, a2y, a2z), "
                    "Vector3.new(a3x, a3y, a3z) }, h = { hx, hy, hz }, collide = collide, query = query, name = name } end")
    rows = []
    for p in parts:
        (a1, a2, a3) = p["axes"]
        rows.append(make(*p["pos"], *a1, *a2, *a3, *(s / 2 for s in p["size"]), bool(p["collide"]), bool(p["query"]), p["name"]))
    return lua.table_from(rows)


def pick_openers(g, spot, floor, walk=None, seen=None):
    """Up to four places a player could stand to open the chest: on its floor, 2.5-6.5 studs out, body clear,
    nothing solid between them and the chest at knee height, and (in the compound) walkable from the pads."""
    x, _, z = spot[1], spot[2], spot[3]
    found = []
    for r in (2.5, 3.5, 5.0, 6.5):
        for k in range(16):
            a = k / 16 * math.tau
            px, pz = x + math.cos(a) * r, z + math.sin(a) * r
            top = g.rayDown(px, floor + 3.0, pz, 6.0)
            if top is None or abs(top - floor) > 1.6:
                continue
            if any(g.solidAt(px + dx, top + h, pz + dz) for h in (1.0, 2.5, 4.5) for dx, dz in ((0, 0), (0.8, 0), (-0.8, 0), (0, 0.8), (0, -0.8))):
                continue
            if not g.clearLine(x, floor + 1.0, z, px, top + 1.0, pz):
                continue
            if walk is not None and not walk.reached(seen, px, pz, slack=0.5):
                continue
            found.append((a, px, top, pz))
    # Spread round the chest: every fourth of the candidates, at most four.
    if not found:
        return []
    step = max(1, len(found) // 4)
    return [(px, top, pz) for (_, px, top, pz) in found[::step][:4]]


# ------------------------------------------------------------------------------------------------
# Running
# ------------------------------------------------------------------------------------------------

def spill_rows(g):
    rows = []
    for i in range(1, len(g.SPILLS) + 1):
        r = g.SPILLS[i]
        items = [dict(r["items"][j]) for j in range(1, len(r["items"]) + 1)]
        rows.append({"scene": r["scene"], "name": r["name"], "c": (r["cx"], r["cy"], r["cz"]), "floor": r["floor"],
                     "kind": r["kind"], "items": items})
    return rows


def spill_stats(rows, footprint):
    """Per spill: the closest two pads, pads inside the container's footprint while it stands."""
    spills = len(rows)
    pads = sum(len(r["items"]) for r in rows)
    stacked = overlapped = inside = same = 0
    worst = math.inf
    far = 0.0
    for r in rows:
        its = r["items"]
        close = math.inf
        for a in range(len(its)):
            for b in range(a + 1, len(its)):
                d = math.hypot(its[a]["x"] - its[b]["x"], its[a]["z"] - its[b]["z"])
                close = min(close, d)
        if close < 0.5:
            stacked += 1
        if close < 0.01:
            same += 1
        if close < 2.4:
            overlapped += 1
        worst = min(worst, close)
        for it in its:
            dx, dz = it["x"] - r["c"][0], it["z"] - r["c"][2]
            far = max(far, math.hypot(dx, dz))
            if footprint(dx, dz):
                inside += 1
    return {"spills": spills, "pads": pads, "stacked": stacked, "same": same, "overlapped": overlapped, "inside": inside,
            "closest": worst, "far": far}


PROMPT_REACH = 9.0  # a pickup prompt's 10 studs, from a root 3 up: 9.5 across the ground, less a margin


def in_reach(walk, seen, x, y, z):
    """Whether a player can stand somewhere walkable from the pads, on the pad's level, within prompt reach
    (the prompts need no line of sight)."""
    i0, k0 = walk.cell(x, z)
    r = int(PROMPT_REACH / 0.5)
    for a in range(-r, r + 1):
        for b in range(-r, r + 1):
            if (a * 0.5) ** 2 + (b * 0.5) ** 2 > PROMPT_REACH ** 2:
                continue
            key = (i0 + a, k0 + b)
            if key in seen and abs(walk.stand[key[0] * walk.nz + key[1]] - y) <= 2.5:
                return True
    return False


def placement_problems(rows, walk=None, seen=None):
    """For every pad: on the floor it was thrown from (within the 2.5 step), resting on something, inside
    no solid part, and (in the compound) in prompt reach of ground walkable from the spawn pads, and
    whether a body can stand on it."""
    bad = {"level": [], "unsupported": [], "inside": [], "unreachable": [], "unstandable": []}
    for r in rows:
        for it in r["items"]:
            where = "%s %s at (%.1f, %.1f, %.1f)" % (r["name"], it["key"], it["x"], it["y"], it["z"])
            if abs(it["y"] - r["floor"]) > 2.5 + 1e-6:
                bad["level"].append(where + " floor %.1f" % r["floor"])
            if not it["supported"]:
                bad["unsupported"].append(where)
            if it["inside"]:
                bad["inside"].append(where + " in " + it["inside"])
            if walk is not None and not walk.reached(seen, it["x"], it["z"], slack=1.0):
                bad["unstandable"].append(where)
                if not in_reach(walk, seen, it["x"], it["y"], it["z"]):
                    bad["unreachable"].append(where)
    return bad


def run(src, geo, log, trials=12):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("math.randomseed(20260925)")
    texts = {k: (luau_to_lua(v) if isinstance(v, str) else v) for k, v in src.items() if not k.startswith("__")}
    shared = Path(src["__root"]) / "ReplicatedStorage" / "Shared"
    texts["__shared"] = lambda name: luau_to_lua((shared / (name + ".lua")).read_text(encoding="utf-8")) \
        if (shared / (name + ".lua")).is_file() else None
    world = lua.execute(WORLD, lua.table_from(texts))  # noqa: F841
    results = lua.execute(HARNESS, src["frenzyGuns"])
    g = lua.globals()
    out = [(results[i][1], results[i][2], results[i][3], results[i][4]) for i in range(1, len(results) + 1)]

    def check(tag, name, ok, detail):
        out.append((tag, name, "ok" if ok else "FAIL", detail))

    def finding(tag, name, detail):
        out.append((tag, name, "FINDING", detail))

    texts = {"ServerScriptService/Modules/LootService.lua": src["LootService"],
             "ServerScriptService/Modules/SupplyDropService.lua": src["SupplyDropService"]}
    sites = grant_sites(src["__root"], texts)
    inside = container_grants(src["__root"], texts)
    check("Q", "Q5 no grant (GiveWeapon, GiveConsumable, GiveHeal, GiveItem, SwapHeldForItem, GiveOrDrop) inside spawnChest or the crate's attachPrompt",
          not inside, "%d grant call sites in ServerScriptService; in the container code: %s" % (len(sites), "; ".join(inside) or "none"))
    by_owner = {}
    for where, call, owner in sites:
        key = where.split(":")[0].rsplit("/", 1)[1] + " " + owner
        by_owner.setdefault(key, []).append(call + "@" + where.rsplit(":", 1)[1])
    finding("Q", "Q5 every grant call site in ServerScriptService, by function",
            "; ".join("%s: %s" % (k, ", ".join(v)) for k, v in sorted(by_owner.items())))

    rows = spill_rows(g)
    chest_fp = lambda dx, dz: math.hypot(dx, dz) < 1.3  # inside a 3.6 x 2.6 chest whatever its yaw
    crate_fp = lambda dx, dz: abs(dx) < 4.5 and abs(dz) < 4.5
    flat_chest = [r for r in rows if r["scene"] == "flat" and r["kind"] == "chest"]
    flat_crate = [r for r in rows if r["scene"] == "flat" and r["kind"] == "crate"]
    for label, subset in (("flat ground, map chests", flat_chest), ("flat ground, supply crates", flat_crate)):
        bad = placement_problems(subset)
        n = sum(len(v) for v in bad.values())
        check("P", "P1 %s: every pad on the floor, resting on it, inside nothing" % label, n == 0 and subset,
              "%d spills, %d pads; %d level, %d unsupported, %d inside" % (len(subset), sum(len(r["items"]) for r in subset),
                                                                        len(bad["level"]), len(bad["unsupported"]), len(bad["inside"])))
    cs, ks = spill_stats(flat_chest, chest_fp), spill_stats(flat_crate, crate_fp)
    finding("P", "P2 flat ground: how a spill lies (pads are 2.4 across; a stacked pair is under 0.5 apart)",
            "chests: %d spills, %d with a stacked pair (%d of them on the very same point), %d with overlapping pads, %d of %d pads inside "
            "the chest while it stands 2.2 s, furthest %.1f from its centre; crates: %d spills, %d stacked (%d same point), %d overlapping, "
            "%d of %d pads inside the 9x9 crate while it stands 1.6 s"
            % (cs["spills"], cs["stacked"], cs["same"], cs["overlapped"], cs["inside"], cs["pads"], cs["far"],
               ks["spills"], ks["stacked"], ks["same"], ks["overlapped"], ks["inside"], ks["pads"]))

    # Hand-made scenes.
    for scene, rule in (("corridor", lambda it, r: abs(it["x"]) <= 3.0 + 1e-6),
                        ("roof", lambda it, r: abs(it["y"] - 12) < 0.01 and abs(it["x"]) <= 6 and abs(it["z"]) <= 6),
                        ("gallery", lambda it, r: abs(it["y"] - 11) < 0.01 and abs(it["z"]) <= 1.5)):
        subset = [r for r in rows if r["scene"] == scene]
        wrong = [(r, it) for r in subset for it in r["items"] if not rule(it, r)]
        bad = placement_problems(subset)
        st = spill_stats(subset, chest_fp)
        what = {"corridor": "between the walls", "roof": "on the roof", "gallery": "on the gallery"}[scene]
        check("P", "P3 %s: every pad %s, on the floor, inside nothing" % (scene, what),
              not wrong and not any(bad.values()) and len(subset) >= 50,
              "%d spills, %d pads, %d off%s" % (len(subset), st["pads"], len(wrong) + sum(len(v) for v in bad.values()),
                                              (": %s at (%.1f, %.1f, %.1f)" % (wrong[0][1]["key"], wrong[0][1]["x"], wrong[0][1]["y"], wrong[0][1]["z"])) if wrong else ""))
        if scene != "corridor":
            finding("P", "P4 %s: pads thrown over the edge fall back onto the chest's own spot and stack there" % scene,
                    "%d of %d spills have a stacked pair, %d overlapping; %d of %d pads inside the chest while it stands"
                    % (st["stacked"], st["spills"], st["overlapped"], st["inside"], st["pads"]))

    # Real geometry.
    for scene in ("ruin", "battleground"):
        if scene not in geo:
            check("P", "P5 %s geometry loads" % scene, False, geo.get("battleground_error", "missing"))
            continue
        data = geo[scene]
        boxes = lua_boxes(lua, data["parts"])
        walk, seen = data.get("walk"), data.get("seen")
        chest_list, skipped = [], []
        g.setBoxes(boxes)
        for spot in data["chests"]:
            floor = g.chestFloor(spot[1], spot[2], spot[3])
            if floor is None:
                skipped.append(spot[0])
                continue
            openers = pick_openers(g, spot, floor, walk, seen)
            if not openers:
                skipped.append(spot[0])
                continue
            chest_list.append({"name": spot[0], "x": spot[1], "y": spot[2], "z": spot[3],
                               "openers": lua.table_from([lua.table_from({"x": o[0], "y": o[1], "z": o[2]}) for o in openers])})
        before = len(g.SPILLS)
        g.realTrials(scene, lua.table_from([lua.table_from(c) for c in chest_list]), trials)
        g.setBoxes(lua.table_from([]))
        subset = [r for r in spill_rows(g)[before:]]
        bad = placement_problems(subset, walk, seen)
        label = {"ruin": "a team-base compound (TeamBaseRuins.Layout)", "battleground": "the battleground (TeamBattleground.Layout)"}[scene]
        for key, what in (("level", "on the floor it was thrown from"), ("unsupported", "resting on something"),
                          ("inside", "inside no solid part"), ("unreachable", "in prompt reach of ground walkable from the spawn pads")):
            if key == "unreachable" and walk is None:
                continue
            if key == "inside" and bad[key]:
                # Measured on main and reported (clearOfWalls), not held as a check that fails there.
                finding("P", "P7 %s: a pad pushed into a solid part" % label,
                        "%d of %d pads: %s" % (len(bad[key]), sum(len(r["items"]) for r in subset), "; ".join(bad[key][:3])))
                continue
            check("P", "P5 %s: every pad %s" % (label, what), not bad[key] and subset,
                  "%d chest spots (%d openers), %d spills, %d pads, %d off%s%s"
                  % (len(chest_list), sum(len(c["openers"]) for c in chest_list), len(subset), sum(len(r["items"]) for r in subset),
                     len(bad[key]), (": " + "; ".join(bad[key][:2])) if bad[key] else "",
                     ("; no opener found at " + ", ".join(skipped)) if skipped else ""))
        per = {}
        for r in subset:
            per.setdefault(r["name"], []).append(r)
        worst = sorted(((spill_stats(v, chest_fp), k) for k, v in per.items()), key=lambda s: -s[0]["overlapped"])
        st = spill_stats(subset, chest_fp)
        finding("P", "P6 %s: how the spills lie" % label,
                "%d spills: %d with a stacked pair (<0.5 apart), %d with overlapping pads (<2.4); %d of %d pads inside the chest while it stands; "
                "%d pads no body can stand on (behind the chest, under a bench), all in prompt reach; "
                "worst spots: %s" % (st["spills"], st["stacked"], st["overlapped"], st["inside"], st["pads"], len(bad["unstandable"]),
                                     ", ".join("%s %d/%d overlapping, %d stacked" % (k, s["overlapped"], s["spills"], s["stacked"]) for s, k in worst[:4])))
        if scene == "battleground":
            spots = []
            for s in data["loot"]:
                row = {"name": s["name"], "position": g.Vector3.new(*s["at"]), "kind": s["kind"]}
                if s["floor"]:
                    row["floor"] = s["floor"]
                spots.append(lua.table_from(row))
            # A team match runs 480 s (GameModes timeLimit): six restocks. Five matches.
            finals, series, lost = [], None, 0
            for _ in range(5):
                counts, spilled, gone = g.restockTrial(boxes, lua.table_from(spots), 6)
                run_series = [counts[i] for i in range(1, 7)]
                series = series or run_series
                finals.append(run_series[-1])
                lost += 1 if gone else 0
            floors = sum(1 for s in data["loot"] if s["kind"] == "weapon" and s["floor"])
            finding("R", "R7 battleground restock: a floor-weapon spot is seeded through DropWeapon, scattered up to 5.7 studs off, "
                    "and counts as free unless a pickup lies within 3, so untouched spots pile up guns every 75 s",
                    "%d floor-weapon spots seeded with %d guns; nobody taking any, guns within 12 studs of them after each of the "
                    "6 restocks of a 480 s match: %s; at the end of 5 such matches: %s; a player's chest spill left on the gallery "
                    "lost a piece to the 50-drop cap in %d of 5" % (floors, floors, series, sorted(finals), lost))
    return out


# ------------------------------------------------------------------------------------------------
# Every server call that puts something straight into a player's inventory
# ------------------------------------------------------------------------------------------------

GRANT = re.compile(r"\b(?:WeaponService|modules\(\)\.Weapon)\.(GiveWeapon|GiveConsumable|GiveHeal|GiveItem|SwapHeldForItem)\(|"
                   r"\bLootService\.GiveOrDrop\(")
# The two ways a container opens for a player: spawnChest (its prompt) and the crate's attachPrompt.
CONTAINERS = (("ServerScriptService/Modules/LootService.lua", "local function spawnChest(cframe)"),
              ("ServerScriptService/Modules/SupplyDropService.lua", "local function attachPrompt(crate, def, beam, landing)"))


def grant_sites(root, texts=None):
    """(file:line, call, enclosing function) for every grant call in ServerScriptService, skipping
    comments and the definitions in WeaponService itself."""
    sites = []
    base = Path(root) / "ServerScriptService"
    for path in sorted(base.rglob("*.lua")):
        rel = path.relative_to(root).as_posix()
        text = (texts or {}).get(rel) or path.read_text(encoding="utf-8")
        owner = "?"
        for number, line in enumerate(text.splitlines(), 1):
            # The enclosing top-level function, or a handler table's `Name = function` one tab in.
            head = re.match(r"^(?:local\s+)?function\s+([\w.:]+)", line) or re.match(r"^\t(\w+) = function", line)
            if head:
                owner = head.group(1)
            if re.match(r"^\s*(?:local\s+)?function\s", line):
                continue  # a definition, not a call
            code = line.split("--", 1)[0]
            for m in GRANT.finditer(code):
                if rel.endswith("WeaponService.lua"):
                    continue
                sites.append((rel + ":" + str(number), m.group(1) or "GiveOrDrop", owner))
    return sites


def container_grants(root, texts=None):
    """Grant calls inside the container-opening functions (must be none), and how many were read."""
    found = []
    for rel, start in CONTAINERS:
        text = (texts or {}).get(rel) or (Path(root) / rel).read_text(encoding="utf-8")
        body = cut(text, start)
        for line in body.splitlines():
            code = line.split("--", 1)[0]
            if GRANT.search(code):
                found.append(rel.rsplit("/", 1)[1] + ": " + code.strip())
    return found


# ------------------------------------------------------------------------------------------------
# Planted faults: each breaks an invariant the code must keep forever
# ------------------------------------------------------------------------------------------------

PLANTS = [
    ("a chest hands its first gun straight to the opener", "LootService",
     "\t\t\tLootService.DropWeapon(def.id, spill, nil, chest.Position)\n",
     "\t\t\tif gunIndex == 1 then WeaponService.GiveWeapon(player, def.id) else LootService.DropWeapon(def.id, spill, nil, chest.Position) end\n",
     ["A1", "A2", "A3", "A4", "Q5"]),
    ("the crate hands its MedKit straight to the opener", "SupplyDropService",
     "\t\t\tLootService.DropItem(id, spill, 1, crate.Position)\n",
     "\t\t\tif id == \"MedKit\" then WeaponService.GiveConsumable(player, id, 1) else LootService.DropItem(id, spill, 1, crate.Position) end\n",
     ["A5", "Q5"]),
    ("a chest's spill loses its throwable", "LootService",
     "\t\t\tLootService.DropItem(item.id, spill, item.pickup, chest.Position)\n",
     "\t\t\tif item.kind ~= \"throwable\" then LootService.DropItem(item.id, spill, item.pickup, chest.Position) end\n",
     ["A1"]),
    ("drops never settle", "LootService", "\tsettle(base)\n\ttable.insert(dropped, base)", "\ttable.insert(dropped, base)", ["S1"]),
    ("the server takes a gun while it settles", "LootService",
     "\t\tif not base.Parent or base:GetAttribute(\"Settling\") then", "\t\tif not base.Parent then", ["S2"]),
    ("the server takes an item while it settles", "LootService",
     "if not base.Parent or base:GetAttribute(\"Claimed\") or base:GetAttribute(\"Settling\") then",
     "if not base.Parent or base:GetAttribute(\"Claimed\") then", ["S2"]),
    ("the settle never ends", "LootService", "\t\t\tbase:SetAttribute(\"Settling\", nil)\n\t\t\tprompt.Enabled = true\n", "", ["S3", "S4"]),
    ("a pickup takes itself on touch", "LootService",
     "\tbase.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0))\n",
     "\tbase.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0))\n\tbase.Touched:Connect(function() end)\n", ["S5"]),
    ("a chest opens twice", "LootService",
     "\t\tif chest:GetAttribute(\"Claimed\") or not chest.Parent then", "\t\tif not chest.Parent then", ["R1"]),
    ("a crate opens twice", "SupplyDropService",
     "\t\tif crate:GetAttribute(\"Claimed\") or not crate.Parent then\n\t\t\treturn\n\t\tend\n\t\tcrate:SetAttribute(\"Claimed\", true)\n\t\tprompt.Enabled = false\n",
     "\t\tif not crate.Parent then\n\t\t\treturn\n\t\tend\n\t\tcrate:SetAttribute(\"Claimed\", true)\n\t\tprompt.Enabled = false\n", ["R1"]),
    ("a bot claims an opened chest", "LootService",
     "function LootService.ClaimForBot(item)\n\tif not item or not item.Parent or item:GetAttribute(\"Claimed\") then",
     "function LootService.ClaimForBot(item)\n\tif not item or not item.Parent then", ["R2"]),
    ("dropped loot expires after 60 s", "LootService",
     "\tsettle(base)\n\ttable.insert(dropped, base)",
     "\tsettle(base)\n\ttask.delay(60, function() if base.Parent then base:Destroy() end end)\n\ttable.insert(dropped, base)", ["R4"]),
    ("a throw goes through walls", "LootService",
     "\t\tlocal reach = hit and math.max(0, (hit.Position - knee).Magnitude - PAD_CLEARANCE) or throw.Magnitude\n",
     "\t\tlocal reach = throw.Magnitude\n", ["P3 corridor", "P5"]),
    ("a throw over an edge lands on whatever is below", "LootService",
     "\t\tif land and math.abs(land.Position.Y - floor.Y) <= STEP_TOLERANCE then",
     "\t\tland = workspace:Raycast(cleared + Vector3.new(0, 3, 0), Vector3.new(0, -400, 0), params)\n\t\tif land then", ["P3 roof", "P3 gallery", "P5"]),
]


def apply(src, plant):
    name, key, old, new, _ = plant
    text = src[key]
    if text.count(old) != 1:
        raise SystemExit("plant '%s': expected one match in %s, found %d" % (name, key, text.count(old)))
    out = dict(src)
    out[key] = text.replace(old, new)
    return out


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    src = sources(root)
    geo = load_geometry(root)
    if "--plant" in argv:
        caught = 0
        for plant in PLANTS:
            name, _, _, _, expect = plant
            try:
                rows = run(apply(src, plant), geo, lambda *_: None, trials=4)
                failed = [r for r in rows if r[2] == "FAIL"]
                hit = [r[1] for r in failed if any(r[1].startswith(e) for e in expect)]
                crashed = None
            except Exception as err:  # a plant that breaks the run outright is caught too, and says so
                failed, hit, crashed = [], [], str(err).splitlines()[0][:160]
            if hit or crashed:
                caught += 1
                print("CAUGHT %s -> %s" % (name, "; ".join(hit) if hit else "the run failed: " + crashed))
            else:
                print("MISSED %s (failed: %s)" % (name, "; ".join(r[1] for r in failed) or "nothing"))
        print("loot_spill proof plants: %d/%d caught" % (caught, len(PLANTS)))
        return 0 if caught == len(PLANTS) else 1
    rows = run(src, geo, print)
    bad = 0
    findings = 0
    for tag, name, status, detail in rows:
        label = {"ok": "ok     ", "FAIL": "FAIL   ", "FINDING": "FINDING"}[status]
        print("%s %s  (%s)" % (label, name, detail))
        bad += status == "FAIL"
        findings += status == "FINDING"
    checks = sum(1 for r in rows if r[2] != "FINDING")
    print("loot_spill proof: %d checks, %d failed, %d findings" % (checks, bad, findings))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
