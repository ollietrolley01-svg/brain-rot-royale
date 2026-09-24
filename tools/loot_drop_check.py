"""Behaviour check for loot that lands on the floor: supply-crate spills and battle-royale death drops.

Runs the REAL ServerScriptService/Modules/LootService.lua and SupplyDropService.lua (whole modules),
the REAL dropLoot from MatchService.lua and the real ItemData / Rarity / WeaponData tables in a Lua
interpreter (lupa), over a mocked Roblox: instances with parents, attributes and signals, a flat
ground plane for raycasts, and a virtual clock driving task.delay / task.wait / task.defer.

    python tools/loot_drop_check.py .            the checks
    python tools/loot_drop_check.py . --plant    the planted faults; every one must be caught

Oliver's playtest, 2026-09-24: "the supply drops still deposit straight to inventory" and "no one's
dropping loot in battle royale".

  Supply: a crate is claimed by HOLDING the key for 1.2 s, and the spill lands 7 studs toward the
  opener, inside the 10-stud reach of its zero-hold pickup prompts. The key is still down when the
  pickups appear, and each one taken puts the next nearest under the same held key, so the whole
  spill ran into the bag in the same moment. The harness models that: straight after the claim,
  every enabled pickup prompt in reach is triggered as the held key would. The check is that
  nothing reaches the inventory then, that everything is still on the ground, and that a fresh
  press a moment later does take it.

  Deaths: a player's and a bot's drops must exist on the ground 1 s, 10 s and 60 s after the death,
  including in a busy match where the dropped-item cap is already full.

What it cannot prove: Roblox's own prompt input (whether a held key really re-arms onto the next
prompt; the fix does not depend on it either way), replication and streaming to clients, or real
map geometry (walls and roofs are left to the ground-plane mock). tools/audit_loot.lua in Studio.

Needs `pip install lupa`. Luau's compound assignments and `continue` are rewritten to plain Lua.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("loot_drop_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    source = re.sub(r"^(\s*)([\w.\[\]()\"]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)
    return source


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def sources(root):
    shared = os.path.join("ReplicatedStorage", "Shared")
    modules = os.path.join("ServerScriptService", "Modules")
    match = read(root, modules, "MatchService.lua")
    a = match.index("local function deathSpot(token)")
    b = match.index("\nend\n", match.index("local function dropLoot(token)")) + 5
    return {
        "Rarity": read(root, shared, "Rarity.lua"),
        "ItemData": read(root, shared, "ItemData.lua"),
        "WeaponData": read(root, shared, "WeaponData.lua"),
        "ArsenalExpansion": read(root, shared, "ArsenalExpansion.lua"),
        "CreativeArsenal": read(root, shared, "CreativeArsenal.lua"),
        "WorkshopArsenal": read(root, shared, "WorkshopArsenal.lua"),
        "LootService": read(root, modules, "LootService.lua"),
        "SupplyDropService": read(root, modules, "SupplyDropService.lua"),
        "dropLoot": match[a:b] + "\nreturn dropLoot\n",
        "__root": root,
    }


PRELUDE = r"""
local SOURCES = ...

-- Clock and scheduler -------------------------------------------------------------------------
local now = 0
local queue = {}
local function schedule(at, co, args) table.insert(queue, { at = at, co = co, args = args }) end
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
        table.sort(queue, function(a, b) return a.at < b.at end)
        local nextJob = queue[1]
        if not nextJob or nextJob.at > target then break end
        table.remove(queue, 1)
        now = math.max(now, nextJob.at)
        if coroutine.status(nextJob.co) == "suspended" then resume(nextJob.co, table.unpack(nextJob.args, 1, nextJob.args.n)) end
    end
    now = target
end
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
local realFormat = string.format
string.format = function(fmt, ...)
    local args = table.pack(...)
    for i = 1, args.n do if type(args[i]) == "number" and fmt:find("%%d") then args[i] = math.floor(args[i]) end end
    return realFormat(fmt, table.unpack(args, 1, args.n))
end

-- Values ---------------------------------------------------------------------------------------
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
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) return m > 0 and vec(v.X / m, v.Y / m, v.Z / m) or vec() end
    if k == "Dot" then return function(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end end
    if k == "Cross" then return function(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end end
end
Vector3 = { new = vec, zero = vec(0, 0, 0), one = vec(1, 1, 1), yAxis = vec(0, 1, 0), xAxis = vec(1, 0, 0), zAxis = vec(0, 0, 1) }
Vector2 = { new = function(x, y) return { X = x, Y = y, Magnitude = math.sqrt(x * x + y * y) } end }

-- Translation-only frames: everything these checks measure is a position.
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
    if k == "PointToObjectSpace" then return function(self, p) return p - self.Position end end
    if k == "ToObjectSpace" then return function(self, o) return cf(o.Position - self.Position) end end
    if k == "Inverse" then return function(self) return cf(-self.Position) end end
end
CFrame = {
    new = function(x, y, z) if type(x) == "table" then return cf(x) end return cf(vec(x, y, z)) end,
    Angles = function() return cf(vec()) end,
    fromEulerAnglesXYZ = function() return cf(vec()) end,
    lookAt = function(p) return cf(p) end,
    identity = cf(vec()),
}
Color3 = { fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end, new = function(r, g, b) return { R = r, G = g, B = b } end }
Color3.fromHSV = Color3.new
UDim2 = { new = function() return {} end, fromScale = function() return {} end, fromOffset = function() return {} end }
TweenInfo = { new = function() return {} end }
NumberSequence = { new = function() return {} end }
NumberRange = { new = function() return {} end }
ColorSequence = { new = function() return {} end }
local function enumTable(path)
    return setmetatable({}, { __index = function(t, k) local v = enumTable(path .. "." .. k) rawset(t, k, v) return v end,
        __tostring = function() return path end })
end
Enum = enumTable("Enum")
RaycastParams = { new = function() return { FilterDescendantsInstances = {} } end }
OverlapParams = RaycastParams

-- Instances ------------------------------------------------------------------------------------
local SIGNALS = { Triggered = true, PromptButtonHoldBegan = true, PromptButtonHoldEnded = true, ChildAdded = true,
    ChildRemoved = true, Destroying = true, Touched = true, Died = true, AncestryChanged = true, OnServerEvent = true,
    Completed = true, PromptShown = true, PromptHidden = true }
local BASEPART = { Part = true, MeshPart = true, WedgePart = true, UnionOperation = true, TrussPart = true }
local function signal()
    local s = { handlers = {} }
    function s:Connect(f) table.insert(self.handlers, f) return { Disconnect = function() for i, h in ipairs(s.handlers) do if h == f then table.remove(s.handlers, i) break end end end, Connected = true } end
    function s:Once(f) return self:Connect(f) end
    function s:Fire(...) for _, f in ipairs({ table.unpack(self.handlers) }) do f(...) end end
    function s:Wait() return end
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
            o._parent.ChildRemoved:Fire(o)
        end
        rawset(o, "_parent", v)
        if v then table.insert(v._kids, o) v.ChildAdded:Fire(o) end
        return
    end
    if k == "Position" then o._p.CFrame = cf(v) return end
    o._p[k] = v
end
I.__tostring = function(o) return o._p.Name end
function M:IsA(c)
    local cls = self._p.ClassName
    return c == cls or c == "Instance" or (c == "BasePart" and BASEPART[cls] == true) or (c == "PVInstance" and (BASEPART[cls] or cls == "Model"))
end
function M:GetChildren() return { table.unpack(self._kids) } end
function M:GetDescendants()
    local out = {}
    local function walk(o) for _, c in ipairs(o._kids) do table.insert(out, c) walk(c) end end
    walk(self)
    return out
end
function M:FindFirstChild(name, recursive)
    for _, c in ipairs(recursive and self:GetDescendants() or self._kids) do if c._p.Name == name then return c end end
end
function M:WaitForChild(name) return self:FindFirstChild(name) end
function M:FindFirstChildOfClass(c) for _, k in ipairs(self._kids) do if k._p.ClassName == c then return k end end end
function M:FindFirstChildWhichIsA(c) for _, k in ipairs(self._kids) do if k:IsA(c) then return k end end end
function M:FindFirstAncestor(name) local p = self._parent while p do if p._p.Name == name then return p end p = p._parent end end
function M:IsDescendantOf(a) local p = self._parent while p do if p == a then return true end p = p._parent end return false end
function M:SetAttribute(k, v) self._attr[k] = v local s = self._asig[k] if s then s:Fire() end end
function M:GetAttribute(k) return self._attr[k] end
function M:GetAttributes() return table.clone(self._attr) end
function M:GetAttributeChangedSignal(k) local s = self._asig[k] if not s then s = signal() self._asig[k] = s end return s end
function M:Destroy()
    if self._destroyed then return end
    self.Destroying:Fire()
    for _, c in ipairs(self:GetChildren()) do c:Destroy() end
    if self._parent then self.Parent = nil end
    rawset(self, "_destroyed", true)
end
function M:ClearAllChildren() for _, c in ipairs(self:GetChildren()) do c:Destroy() end end
function M:PivotTo(frame) self._p.CFrame = frame end
function M:GetPivot() return self._p.CFrame or cf(vec()) end
function M:GetBoundingBox() return self._p.CFrame or cf(vec()), self._p.Size or vec(1, 1, 1) end
function M:SetNetworkOwner() end
function M:Clone() local c = new(self._p.ClassName, self._p.Name) for k, v in pairs(self._p) do c._p[k] = v end return c end
Instance = { new = function(class, parent) local o = new(class) if parent then o.Parent = parent end return o end }

-- World ----------------------------------------------------------------------------------------
workspace = new("Workspace", "Workspace")
local terrain = new("Terrain", "Terrain")
terrain.Parent = workspace
local map = new("Model", "Map")
map.Parent = workspace
GROUND_Y = 0
-- A flat ground plane: a ray that crosses it hits it; nothing else is solid.
function M:Raycast(origin, direction)
    if direction.Y >= 0 or origin.Y < GROUND_Y then return nil end
    local t = (origin.Y - GROUND_Y) / -direction.Y
    if t > 1 then return nil end
    return { Position = vec(origin.X + direction.X * t, GROUND_Y, origin.Z + direction.Z * t), Instance = terrain,
        Normal = vec(0, 1, 0), Material = Enum.Material.Grass }
end
function M:GetPartBoundsInBox() return {} end
function M:GetPartBoundsInRadius() return {} end
function M:GetServerTimeNow() return now end
local services = {}
game = { GetService = function(_, name)
    if name == "Workspace" then return workspace end
    local s = services[name]
    if not s then
        s = new(name, name)
        services[name] = s
    end
    return s
end }
game.Workspace = workspace
local tween = game:GetService("TweenService")
function tween.Create(_, inst, _, props)
    return { Play = function() for k, v in pairs(props) do inst[k] = v end end, Completed = signal(), Cancel = function() end }
end
typeof = function(v)
    local mt = getmetatable(v)
    if mt == I then return "Instance" elseif mt == V then return "Vector3" elseif mt == C then return "CFrame" end
    return type(v)
end

-- Modules --------------------------------------------------------------------------------------
local loaded, loaders = {}, {}
function require(marker)
    local name = type(marker) == "table" and marker._p and marker._p.Name or marker
    if loaded[name] == nil then
        local f = loaders[name]
        if not f and SHARED_SOURCE then
            local text = SHARED_SOURCE(name)
            if text then source(name, text) f = loaders[name] end
        end
        if not f then error("no module " .. tostring(name)) end
        loaded[name] = f()
    end
    return loaded[name]
end
local folder
function folder(name) return setmetatable({ _p = { Name = name } }, { __index = function(_, k)
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
mock("ItemModels", { Build = function(id) local m = new("Model", id) local body = part(m, "Body") return m, body end })
mock("CrateModels", { Chest = function(frame) local c = new("Part", "Chest") c.CFrame = frame part(c, "Lid") return c end })
mock("Remotes", { Event = function() return { FireAllClients = function() end, FireClient = function() end, OnServerEvent = signal() } end })
mock("DestructibleService", { OnPartBroken = function(fn) return fn end, RestingOn = function() return {} end, SettleDown = function() end })
mock("QuestService", { Progress = function() end })
notices = {}
mock("StateSync", { Notify = function(player, text) table.insert(notices, text) end, Push = function() end })
mock("StormService", { GetState = function() return { center = vec(0, 0, 0), radius = 400 } end })

-- The bag: every way anything reaches a player's inventory lands here.
bag = {}
loadouts = {}
mock("WeaponService", {
    GiveWeapon = function(player, id, carried) table.insert(bag, "weapon:" .. id) return true, "Picked up " .. id, nil end,
    GiveConsumable = function(player, id, amount) table.insert(bag, "item:" .. id) return amount end,
    GiveAmmo = function() return true end,
    BuildStaticGun = function(def, color, material, frame, parent)
        if def.id == BROKEN_GUN then error("model builder fault for " .. def.id) end
        local g = part(parent, "Gun") g.CFrame = frame return g
    end,
    Get = function(player) return loadouts[player] end,
    SwapHeldForItem = function() return nil, 0 end,
})
"""

HARNESS = r"""
local results = {}
local function check(name, ok, detail) table.insert(results, { name, ok and true or false, detail or "" }) end

local LootService = require("LootService")
local SupplyDropService = require("SupplyDropService")
local ItemData = require("ItemData")
local WeaponData = require("WeaponData")

local function lootFolder() return workspace:FindFirstChild("Loot") end
local function onGround()
    local out = {}
    local f = lootFolder()
    for _, item in ipairs(f and f:GetChildren() or {}) do
        if item.Name == "GroundWeapon" then table.insert(out, "weapon:" .. tostring(item:GetAttribute("WeaponId")))
        elseif item.Name == "HealPickup" or item.Name == "ItemPickup" then table.insert(out, "item:" .. tostring(item:GetAttribute("ItemId"))) end
    end
    table.sort(out)
    return out
end
local function has(list, entry) for _, e in ipairs(list) do if e == entry then return true end end return false end
local function count(list, prefix) local n = 0 for _, e in ipairs(list) do if e:sub(1, #prefix) == prefix then n = n + 1 end end return n end

local function newPlayer(at)
    local player = new("Player", "Oliver")
    local character = new("Model", "Oliver")
    local root = part(character, "HumanoidRootPart")
    root.CFrame = CFrame.new(at)
    character.PrimaryPart = root
    player.Character = character
    return player, root
end

-- The held key: every enabled pickup prompt in reach, nearest first, the way a key still down from the
-- crate's 1.2 s hold reaches whichever prompt the player is shown next.
local function heldKeySweep(root)
    for _ = 1, 20 do
        local best, bestDistance = nil, math.huge
        local f = lootFolder()
        for _, item in ipairs(f and f:GetChildren() or {}) do
            local prompt = item:FindFirstChildOfClass("ProximityPrompt")
            if prompt and prompt.Enabled and not prompt._swept then
                local d = (item.Position - root.Position).Magnitude
                if d <= prompt.MaxActivationDistance and d < bestDistance then best, bestDistance = prompt, d end
            end
        end
        if not best then return end
        best._p._swept = true
        best.Triggered:Fire(PLAYER)
    end
end

-- 1. A supply crate: dropped, landed, claimed by a player standing beside it ----------------------
SupplyDropService.SetInterval(600, 1)
SupplyDropService.Start()
advance(1.1)
advance(10)
local drops = workspace:FindFirstChild("SupplyDrops")
local crate = drops and drops:FindFirstChild("SupplyCrate")
check("supply: a crate lands and takes a prompt", crate ~= nil and crate:GetAttribute("Landed") == true and crate:FindFirstChildOfClass("ProximityPrompt") ~= nil)
local root
PLAYER, root = newPlayer(crate.Position + Vector3.new(9, -1, 0))
local weaponId = crate:GetAttribute("WeaponId")
local cratePrompt = crate:FindFirstChildOfClass("ProximityPrompt")
cratePrompt.PromptButtonHoldBegan:Fire(PLAYER)
cratePrompt.Triggered:Fire(PLAYER)
local spilled = onGround()
check("supply: the claim puts the gun, MedKit, Shield Potion and Pop-up Bunker on the ground",
    has(spilled, "weapon:" .. weaponId) and has(spilled, "item:MedKit") and has(spilled, "item:ShieldPotion") and has(spilled, "item:PopupBunker"),
    table.concat(spilled, ", "))
check("supply: the claim itself puts nothing in the bag", #bag == 0, table.concat(bag, ", "))
-- The same moment: the crate's key is still held.
heldKeySweep(root)
check("supply: the key still held from the crate collects nothing in the same instant", #bag == 0, "bag: " .. table.concat(bag, ", "))
-- A take that reaches the server anyway (a client ahead of the prompt) is refused while it settles.
for _, item in ipairs(lootFolder():GetChildren()) do
    local prompt = item:FindFirstChildOfClass("ProximityPrompt")
    if prompt then prompt.Triggered:Fire(PLAYER) end
end
check("supply: the server refuses a take while the spill settles", #bag == 0, "bag: " .. table.concat(bag, ", "))
cratePrompt.PromptButtonHoldEnded:Fire(PLAYER)
advance(0.1)
check("supply: 0.1 s on, all four still on the ground", #onGround() == 4, table.concat(onGround(), ", "))
-- A fresh press a moment later does pick up (the spill is real loot, not decoration).
advance(1.5)
local f = lootFolder()
local fresh = nil
for _, item in ipairs(f and f:GetChildren() or {}) do
    local prompt = item:FindFirstChildOfClass("ProximityPrompt")
    if item.Name == "GroundWeapon" and prompt then fresh = prompt end
end
local wasEnabled = fresh and fresh.Enabled
if fresh then fresh.Triggered:Fire(PLAYER) end
check("supply: a fresh press on the gun a moment later picks it up", wasEnabled and has(bag, "weapon:" .. weaponId), "bag: " .. table.concat(bag, ", "))
SupplyDropService.Stop()

-- 2. Battle-royale deaths ----------------------------------------------------------------------
local byChar = {}
Combatants = {
    IsBot = function(t) return type(t) == "table" and t.isBot == true end,
    GetCharacter = function(t) if type(t) == "table" and t.isBot then return t.character end return t.Character end,
    GetRoot = function(t) local c = type(t) == "table" and t.isBot and t.character or t.Character return c and c:FindFirstChild("HumanoidRootPart") end,
}
for id in pairs(WeaponData.Weapons) do if id ~= "CrocodiloRifle" and (not BROKEN_GUN or id < BROKEN_GUN) then BROKEN_GUN = id end end
local dropLoot = load(DROPLOOT, "=dropLoot", "t", setmetatable({ Combatants = Combatants, LootService = LootService,
    WeaponService = require("WeaponService") }, { __index = _G }))()

local function deathScene(label, busy, rootless)
    LootService.Clear()
    workspace:FindFirstChild("Loot")
    if busy then
        -- A busy match: the dropped-item cap already full of older spills and drops.
        for i = 1, 60 do LootService.DropItem("Bandage", Vector3.new(500 + i * 3, 3, 500), 1) end
    end
    local victim, vroot = newPlayer(Vector3.new(40, 3, 40))
    -- The second gun's pickup can't be built: it costs that pickup, never the rest of the drop.
    loadouts[victim] = { slots = {
        { kind = "weapon", id = "CrocodiloRifle", mag = 7, reserve = 30 },
        { kind = "weapon", id = BROKEN_GUN, mag = 1, reserve = 1 },
        { kind = "item", id = "MedKit", count = 2 },
    } }
    local botChar = new("Model", "Bot")
    botChar.Parent = workspace
    local broot = part(botChar, "HumanoidRootPart")
    broot.CFrame = CFrame.new(Vector3.new(-60, 3, -60))
    local bot = { isBot = true, name = "Bot", character = botChar, weapon = WeaponData.Get("CrocodiloRifle"),
        heals = { Bandage = 2, MedKit = 0 }, shields = { MiniShield = 1, ShieldPotion = 0 }, defenses = 1 }
    if rootless then
        -- A body without its HumanoidRootPart (fell out of the world, the rig's root came away).
        botChar._p.CFrame = broot.CFrame
        broot:Destroy()
        broot = { Position = botChar._p.CFrame.Position }
    end
    local okPlayer, errPlayer = pcall(dropLoot, victim)
    local okBot, errBot = pcall(dropLoot, bot)
    check(label .. ": a fault building one pickup never escapes the drop (eliminate carries on)", okPlayer and okBot,
        tostring(errPlayer) .. " / " .. tostring(errBot))
    local function near(centre)
        local out = {}
        local f = lootFolder()
        for _, item in ipairs(f and f:GetChildren() or {}) do
            if item.Parent and (item.Position - centre).Magnitude < 20 then table.insert(out, item.Name .. ":" .. tostring(item:GetAttribute("WeaponId") or item:GetAttribute("ItemId"))) end
        end
        return out
    end
    for _, t in ipairs({ 1, 10, 60 }) do
        advance(t - (t == 1 and 0 or (t == 10 and 1 or 10)))
        local mine, its = near(vroot.Position), near(broot.Position)
        check(label .. ": the player's gun and stack are on the ground " .. t .. " s after the death",
            #mine == 2, table.concat(mine, ", "))
        check(label .. ": the bot's gun, heal, shield and barricade are on the ground " .. t .. " s after the death",
            #its == 4, table.concat(its, ", "))
    end
end
deathScene("BR death", false)
deathScene("BR death in a busy match", true)
deathScene("BR death of a body without its root part", false, true)

return results
"""


def run(srcs):
    lua = LuaRuntime(unpack_returned_tuples=True)
    shared = os.path.join(srcs["__root"], "ReplicatedStorage", "Shared")

    def shared_source(name):
        path = os.path.join(shared, str(name) + ".lua")
        return luau_to_lua(open(path, encoding="utf-8").read()) if os.path.exists(path) else None
    lua.globals().SHARED_SOURCE = shared_source
    table = lua.table_from({k: luau_to_lua(v) for k, v in srcs.items() if k not in ("dropLoot", "__root")})
    lua.execute(PRELUDE, table)
    lua.globals().DROPLOOT = luau_to_lua(srcs["dropLoot"])
    results = lua.execute(HARNESS)
    return [(r[1], bool(r[2]), r[3]) for r in results.values()]


def plant(key, old, new):
    def mutate(srcs):
        if old not in srcs[key]:
            raise SystemExit("loot_drop_check: plant target not found in " + key + ": " + old)
        srcs = dict(srcs)
        srcs[key] = srcs[key].replace(old, new, 1)
        return srcs
    return mutate


PLANTS = [
    ("supply claim hands the gun straight over (the pre-#85 code)",
     plant("SupplyDropService", "LootService.DropWeapon(def.id, spill, nil, crate.Position)", "WeaponService.GiveWeapon(player, def.id)")),
    ("a spill can be taken the instant it lands (Oliver's 09-24 report: straight to inventory)",
     plant("LootService", "\tsettle(base)\n\ttable.insert(dropped, base)", "\ttable.insert(dropped, base)")),
    ("a settled pickup never comes back on",
     plant("LootService", "\t\t\tbase:SetAttribute(\"Settling\", nil)\n\t\t\tprompt.Enabled = true", "\t\t\tbase:SetAttribute(\"Settling\", nil)")),
    ("the server takes a gun while it settles",
     plant("LootService", "if not base.Parent or base:GetAttribute(\"Settling\") then", "if not base.Parent then")),
    ("the server takes an item while it settles",
     plant("LootService", "or base:GetAttribute(\"Settling\") then\n\t\t\treturn\n\t\tend\n\t\tlocal added", "then\n\t\t\treturn\n\t\tend\n\t\tlocal added")),
    ("a death drop needs the root part (the old silent return)",
     plant("dropLoot", "local character = Combatants.GetCharacter(token)", "local character = nil")),
    ("one pickup's fault costs the whole drop and the elimination",
     plant("dropLoot", "local ok, err = pcall(drop, ...)", "local ok, err = true, drop(...)")),
    ("the dropped-item cap throws out the newest drop",
     plant("LootService", "local oldest = table.remove(dropped, 1)", "local oldest = table.remove(dropped)")),
    ("dropped loot expires after 30 s",
     plant("LootService", "\tsettle(base)\n", "\tsettle(base)\n\ttask.delay(30, function() base:Destroy() end)\n")),
    ("the bot branch drops nothing",
     plant("dropLoot", "if Combatants.IsBot(token) then\n\t\tif token.weapon then", "if Combatants.IsBot(token) then\n\t\tdo return end\n\t\tif token.weapon then")),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    base = sources(root)
    if "--plant" in sys.argv:
        missed = 0
        for name, mutate in PLANTS:
            try:
                failed = [r[0] for r in run(mutate(base)) if not r[1]]
            except Exception as err:  # a plant that breaks the run outright is caught too
                failed = ["run failed: " + str(err).splitlines()[0]]
            print(("CAUGHT " if failed else "MISSED ") + name + (" -> " + "; ".join(failed) if failed else ""))
            missed += 0 if failed else 1
        print(f"loot_drop plants: {len(PLANTS) - missed}/{len(PLANTS)} caught")
        sys.exit(1 if missed else 0)
    results = run(base)
    bad = 0
    for name, ok, detail in results:
        print(("ok   " if ok else "FAIL ") + name + ("  (" + detail + ")" if detail else ""))
        bad += 0 if ok else 1
    print(f"loot_drop check: {len(results)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
