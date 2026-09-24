"""Behaviour check for the kill animations (#24), without Studio.

Runs the real source, in a Lua interpreter (lupa) with Roblox mocked, of:
  * CosmeticData          every KillAnimation entry: named, described, priced, not a crate exclusive,
                          and priced inside the band the other kinds use for its rarity
  * RewardService         EquipCosmetic: equip, re-equip takes it off, unowned refused, nil clears it,
                          and the other slots untouched
  * PlayerData            reconcile(): a save from before the field loads exactly as the working
                          branch's reconcile loads it, and a save with the field keeps it
  * StateSync             sends cosmetics.killAnimation
  * ShopRotation          2000 rotations: every other kind's stock identical to the working branch's,
                          two kill animations on sale in each, and every one of them turns up
  * KillAnimService       plays only an owned, equipped kill animation, for a real player, and its
                          Chain passes the kill on to the previous hook even when it fails itself
  * KillAnimFxClient      every CosmeticData kill animation has a builder; each stays under the part
                          and particle caps; nothing (tween, delay, particle) outlives its folder; at
                          most MAX_LIVE at once; far ones culled; a greedy builder is cut off at the cap

    python tools/killanim_check.py .            the checks
    python tools/killanim_check.py . --plant    the planted faults; every one must be caught

Needs `pip install lupa`. Luau's compound assignments are rewritten to plain Lua before loading.
"""

import os
import re
import subprocess
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("killanim_check: needs lupa (pip install lupa)")

BASE_BRANCH = "claude/roblox-game-tasks-wv7n8k"

COSMETIC = "ReplicatedStorage/Shared/CosmeticData.lua"
ROTATION = "ReplicatedStorage/Shared/ShopRotation.lua"
PLAYERDATA = "ServerScriptService/Modules/PlayerData.lua"
REWARD = "ServerScriptService/Modules/RewardService.lua"
STATESYNC = "ServerScriptService/Modules/StateSync.lua"
SERVICE = "ServerScriptService/Modules/KillAnimService.lua"
CLIENT = "StarterPlayerScripts/KillAnimFxClient.client.lua"
BOOTSTRAP = "ServerScriptService/Bootstrap.server.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-]|\.\.)= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read()


def base_version(root, path):
    try:
        return subprocess.run(["git", "-C", root, "show", f"{BASE_BRANCH}:{path}"], capture_output=True,
                              text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def reconcile_block(text):
    start = text.index("local function defaultData()")
    rec = text.index("local function reconcile(saved)", start)
    end = text.index("\nend\n", rec) + 5
    return "local PlayerData = {}\n" + text[start:end] + "return reconcile\n"


def equip_block(text):
    start = text.index("function RewardService.EquipCosmetic")
    end = text.index("\nend\n", start) + 5
    return "local RewardService = {}\n" + text[start:end] + "return RewardService\n"


PRELUDE = r"""
-- Values that absorb anything: CFrames, colours, enums, sequences.
local Proxy = {}
local function proxy() return setmetatable({}, Proxy) end
Proxy.__index = function() return proxy() end
Proxy.__call = function() return proxy() end
for _, op in ipairs({ "__add", "__sub", "__mul", "__div", "__unm", "__mod", "__pow" }) do
    Proxy[op] = function() return proxy() end
end

local Vec = {}
function vec(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vec) end
function isvec(v) return getmetatable(v) == Vec end
Vec.__index = function(v, key)
    if key == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if key == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); return vec(v.X / m, v.Y / m, v.Z / m) end
    return proxy()
end
Vec.__add = function(a, b) if isvec(a) and isvec(b) then return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end return proxy() end
Vec.__sub = function(a, b) if isvec(a) and isvec(b) then return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end return proxy() end
Vec.__mul = function(a, b)
    if type(a) == "number" and isvec(b) then return vec(a * b.X, a * b.Y, a * b.Z) end
    if isvec(a) and type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
    if isvec(a) and isvec(b) then return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z) end
    return proxy()
end
Vec.__div = function(a, b) if isvec(a) and type(b) == "number" then return vec(a.X / b, a.Y / b, a.Z / b) end return proxy() end
Vec.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end

Vector3 = { new = vec, zero = vec(0, 0, 0), yAxis = vec(0, 1, 0), xAxis = vec(1, 0, 0), zAxis = vec(0, 0, 1) }
CFrame = setmetatable({
    new = function(v) local c = proxy(); if isvec(v) then rawset(c, "Position", v) end return c end,
}, { __index = function() return function() return proxy() end end })
Color3 = setmetatable({}, { __index = function() return function() return proxy() end end })
Vector2 = { new = function() return proxy() end }
UDim2 = Vector2
ColorSequence = Vector2
NumberSequence = Vector2
NumberRange = { new = function(a, b) return { Min = a, Max = b or a } end }
TweenInfo = { new = function(t) return { Time = t } end }
RaycastParams = { new = function() return {} end }
Enum = proxy()
table.find = table.find or function(list, value) for i, v in ipairs(list) do if v == value then return i end end end
typeof = function(v)
    if isvec(v) then return "Vector3" end
    if type(v) == "table" and rawget(v, "__instance") then return "Instance" end
    return type(v)
end
warn = function() end

function marker(name) return { Name = name, WaitForChild = function(_, n) return marker(n) end, FindFirstChild = function(_, n) return marker(n) end } end
MODULES = {}
require = function(m)
    local found = MODULES[m.Name]
    if found == nil then error("unexpected require " .. tostring(m.Name)) end
    return found
end
script = { Parent = marker("Parent") }

function serialise(v, seen)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do table.insert(keys, tostring(k)) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local value = v[k]
        if value == nil then value = v[tonumber(k)] end
        table.insert(out, k .. "=" .. serialise(value))
    end
    return "{" .. table.concat(out, ",") .. "}"
end
"""

CHECKS = r"""
local sources = ...
local fails = {}
REPORT = {}
local function fail(fmt, ...) table.insert(fails, string.format(fmt, ...)) end

-- Deterministic stand-in for Roblox's Random, the same for both versions of ShopRotation.
Random = { new = function(seed)
    local state = math.floor(seed) % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return { NextNumber = function() state = (state * 48271) % 2147483647; return state / 2147483647 end,
             NextInteger = function(_, a, b) state = (state * 48271) % 2147483647; return a + state % (b - a + 1) end }
end }
workspace = { GetServerTimeNow = function() return 0 end }

-- 1. CosmeticData ----------------------------------------------------------------------------
local CosmeticData = load(sources.cosmetic, "CosmeticData")()
MODULES.CosmeticData = CosmeticData
MODULES.CrateData = { Order = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Accessory", "Skin", "Aura", "Parachute", "Super" } }

local bands = {}
for id, item in pairs(CosmeticData.Items) do
    if item.kind ~= "KillAnimation" and item.price and not item.crateOnly and not item.rankOnly and not item.bundleOnly then
        local band = bands[item.rarity] or { lo = math.huge, hi = 0 }
        band.lo, band.hi = math.min(band.lo, item.price), math.max(band.hi, item.price)
        bands[item.rarity] = band
    end
end
local killIds = CosmeticData.OfKind("KillAnimation")
if #killIds < 6 or #killIds > 8 then fail("%d kill animations in the shop, want 6 to 8", #killIds) end
for _, id in ipairs(killIds) do
    local item = CosmeticData.Get(id)
    if type(item.name) ~= "string" or item.name == "" then fail("%s has no name", id) end
    if type(item.description) ~= "string" or item.description == "" then fail("%s has no description", id) end
    if item.crateOnly then fail("%s is crateOnly, but no crate draws kill animations", id) end
    local band = bands[item.rarity]
    if not band then
        fail("%s: rarity %s has no price band", id, tostring(item.rarity))
    elseif type(item.price) ~= "number" or item.price < band.lo or item.price > band.hi then
        fail("%s costs %s, outside the %s band %d-%d", id, tostring(item.price), item.rarity, band.lo, band.hi)
    end
end

-- 2. EquipCosmetic ---------------------------------------------------------------------------
local profile
local pushes = 0
local Reward = load(sources.equip, "EquipCosmetic", "t", setmetatable({
    PlayerData = { Get = function() return profile end },
    CosmeticData = CosmeticData,
    StateSync = { Push = function() pushes = pushes + 1 end },
}, { __index = _G }))()
local anim = killIds[1]
profile = { Cosmetics = { owned = { [anim] = true, GoldSahur = true }, gunSkin = "GoldSahur" } }
local ok = Reward.EquipCosmetic({}, anim)
if not ok or profile.Cosmetics.killAnimation ~= anim then fail("equipping owned %s didn't fill the killAnimation slot", anim) end
if profile.Cosmetics.gunSkin ~= "GoldSahur" then fail("equipping a kill animation touched the gun skin") end
Reward.EquipCosmetic({}, anim)
if profile.Cosmetics.killAnimation ~= nil then fail("re-equipping %s didn't take it off", anim) end
ok = Reward.EquipCosmetic({}, killIds[2])
if ok or profile.Cosmetics.killAnimation ~= nil then fail("an unowned kill animation was equipped") end
Reward.EquipCosmetic({}, anim)
Reward.EquipCosmetic({}, nil)
if profile.Cosmetics.killAnimation ~= nil then fail("EquipCosmetic(nil) left the kill animation on") end

-- 3. PlayerData reconcile --------------------------------------------------------------------
MODULES.BrainrotData = { ClampStars = function(s) return s end, Get = function() return nil end, MaxStars = 5 }
MODULES.ProgressionData = { Default = function() return {} end, Reconcile = function() return {} end }
local env = setmetatable({ BrainrotData = MODULES.BrainrotData, ProgressionData = MODULES.ProgressionData }, { __index = _G })
local reconcile = load(sources.reconcile, "reconcile", "t", env)()
local function oldSave()
    return { SahurCoins = 1234, Brainrots = { "Tung" },
        Cosmetics = { owned = { GoldSahur = true, SharkChute = true }, gunSkin = "GoldSahur", aura = "RotAura", parachute = "SharkChute" } }
end
local loaded = reconcile(oldSave())
if loaded.Cosmetics.killAnimation ~= nil then fail("an old save loaded with a kill animation") end
if loaded.Cosmetics.gunSkin ~= "GoldSahur" or loaded.Cosmetics.parachute ~= "SharkChute" or not loaded.Cosmetics.owned.SharkChute then
    fail("an old save lost its cosmetics")
end
if sources.baseReconcile then
    local baseReconcile = load(sources.baseReconcile, "baseReconcile", "t", env)()
    if serialise(baseReconcile(oldSave())) ~= serialise(loaded) then fail("an old save loads differently from the working branch") end
end
local withField = oldSave()
withField.Cosmetics.killAnimation = anim
withField.Cosmetics.owned[anim] = true
if reconcile(withField).Cosmetics.killAnimation ~= anim then fail("a saved kill animation didn't load") end

-- 4. ShopRotation ----------------------------------------------------------------------------
local ShopRotation = load(sources.rotation, "ShopRotation")()
local BaseRotation = sources.baseRotation and load(sources.baseRotation, "BaseRotation")()
local seen, mismatches, badCounts = {}, 0, 0
for window = 1, 2000 do
    local at = window * ShopRotation.RotationSeconds + 1
    local onSale = 0
    for id, item in pairs(CosmeticData.Items) do
        local inStock = ShopRotation.IsCosmeticInStock(id, at)
        if item.kind == "KillAnimation" then
            if inStock then onSale = onSale + 1; seen[id] = true end
        elseif BaseRotation and inStock ~= BaseRotation.IsCosmeticInStock(id, at) then
            mismatches = mismatches + 1
        end
    end
    if onSale ~= (ShopRotation.KillAnimationSlots or 0) or onSale == 0 then badCounts = badCounts + 1 end
end
if mismatches > 0 then fail("%d other-kind stock slots differ from the working branch's rotation", mismatches) end
if badCounts > 0 then fail("%d rotations didn't have exactly KillAnimationSlots kill animations on sale", badCounts) end
for _, id in ipairs(killIds) do
    if not seen[id] then fail("%s never came up in 2000 rotations", id) end
end

-- 5. KillAnimService -------------------------------------------------------------------------
local fired = {}
local playersProfile = {}
local function player(name) return { __instance = true, Name = name, IsA = function(_, c) return c == "Player" end } end
MODULES.Remotes = { Event = function() return { FireAllClients = function(_, data) table.insert(fired, data) end } end }
MODULES.Combatants = {
    IsPlayer = function(t) return type(t) == "table" and rawget(t, "__instance") == true end,
    GetRoot = function(t) return t.root end,
    GetCharacter = function(t) return t.character end,
}
MODULES.PlayerData = { Get = function(p) return playersProfile[p] end }
MODULES.SafeValue = load(sources.safevalue, "SafeValue")()
game = { GetService = function(_, n) return marker(n) end }
local Service = load(sources.service, "KillAnimService")()
local killer, victim = player("Killer"), { isBot = true, root = { Position = vec(10, 5, 3) } }
playersProfile[killer] = { Cosmetics = { owned = { [anim] = true }, killAnimation = anim } }
Service.Play(killer, victim)
if #fired ~= 1 or fired[1].id ~= anim or fired[1].position.Y ~= 5 then fail("an owned, equipped kill animation wasn't sent to clients") end
fired = {}
playersProfile[killer].Cosmetics.owned[anim] = nil
Service.Play(killer, victim)
if #fired > 0 then fail("an unowned kill animation played") end
playersProfile[killer].Cosmetics = { owned = { GoldSahur = true }, killAnimation = "GoldSahur" }
Service.Play(killer, victim)
if #fired > 0 then fail("a gun skin in the killAnimation slot played") end
Service.Play({ isBot = true }, victim)
if #fired > 0 then fail("a bot's kill played an animation") end
local passed
local chained = Service.Chain(function(k, v, w) passed = { k, v, w } end)
playersProfile[killer] = { Cosmetics = { owned = { [anim] = true }, killAnimation = anim } }
chained(killer, { root = false, character = false }, "Pistol")
if not passed or passed[1] ~= killer or passed[3] ~= "Pistol" then fail("Chain didn't pass the kill on to the previous hook") end
passed = nil
MODULES.Combatants.GetRoot = function() error("boom") end
local chainOk = pcall(chained, killer, victim, "Pistol")
if not chainOk or not passed then fail("an error in KillAnimService stopped the previous hook") end
if not sources.bootstrap:find('MatchService.OnKillCredited = require(Modules:WaitForChild("KillAnimService")).Chain(MatchService.OnKillCredited)', 1, true) then
    fail("Bootstrap doesn't chain KillAnimService onto OnKillCredited")
end
if not sources.statesync:find("killAnimation = data.Cosmetics.killAnimation", 1, true) then fail("StateSync doesn't send killAnimation") end

-- 6. KillAnimFxClient ------------------------------------------------------------------------
local now, queue = 0, {}
local function schedule(at, fn) table.insert(queue, { at = at, fn = fn }) end
local function runUntil(limit)
    while true do
        table.sort(queue, function(a, b) return a.at < b.at end)
        local nextItem = queue[1]
        if not nextItem or nextItem.at > limit then break end
        table.remove(queue, 1)
        now = nextItem.at
        nextItem.fn()
    end
    now = limit
end
task = { delay = function(t, fn) schedule(now + t, fn) end, spawn = function(fn) fn() end }
local stats
local function resetStats() stats = { parts = 0, particles = 0, lastEnd = 0, folders = {} } end
resetStats()
local function instance(class)
    local signalFns = {}
    local obj = { __instance = true, ClassName = class }
    obj.Changed = { Connect = function(_, fn) table.insert(signalFns, fn) end }
    obj.Destroy = function(self) self.destroyed = true end
    obj.Emit = function(self, n)
        stats.particles = stats.particles + n
        stats.lastEnd = math.max(stats.lastEnd, now + (self.Lifetime and self.Lifetime.Max or 0))
    end
    obj.__fire = function(v) for _, fn in ipairs(signalFns) do fn(v) end end
    if class == "Part" then stats.parts = stats.parts + 1 end
    if class == "Folder" then table.insert(stats.folders, obj) end
    return obj
end
Instance = { new = instance }
local camera = { CFrame = CFrame.new(vec(0, 0, 0)) }
workspace = { CurrentCamera = camera, Raycast = function() return nil end }
local TweenService = { Create = function(_, inst, info, goal)
    return { Play = function()
        local ends = now + info.Time
        stats.lastEnd = math.max(stats.lastEnd, ends)
        -- Drive NumberValues through a few steps so the step functions really run.
        if inst.__fire and goal.Value then
            for i = 1, 4 do local a = i / 4; schedule(now + info.Time * a, function() inst.__fire(a) end) end
        end
    end }
end }
local handler
MODULES.Remotes = { Event = function() return { OnClientEvent = { Connect = function(_, fn) handler = fn end } } end }
MODULES.Sfx = { PlayAt = function() end }
game = { GetService = function(_, n)
    if n == "TweenService" then return TweenService end
    if n == "Players" then return { GetPlayers = function() return {} end } end
    return marker(n)
end }
local clientSrc = sources.client
local caps = {}
for name in ("MAX_LIVE MAX_PARTS MAX_PARTICLES MAX_LIFETIME CULL_DISTANCE"):gmatch("%S+") do
    caps[name] = tonumber(clientSrc:match("local " .. name .. " = ([%d%.]+)"))
    if not caps[name] then fail("KillAnimFxClient has no %s", name) end
end
local function lifeOf(id)
    return tonumber(clientSrc:match("\n\t" .. id .. " = {\n\t\tlife = ([%d%.]+)"))
end
-- A builder that asks for far more than it may have. The cap has to stop it.
clientSrc = clientSrc:gsub("local EFFECTS = {\n", "local EFFECTS = {\n\t__Greedy = { life = 1, build = function(ctx) ctx:burst(ctx.position, nil, 500) for _ = 1, 100 do ctx:part(V(1, 1, 1), CFrame.new(ctx.position), nil) end end },\n", 1)
warn = function(message) fail("client warned: %s", tostring(message)) end
load(clientSrc, "KillAnimFxClient")()
if not handler then fail("KillAnimFxClient never connected to KillAnimFx") end

local function playOne(id, at)
    handler({ id = id, position = at or vec(5, 3, 5) })
end
for _, id in ipairs(killIds) do
    local life = lifeOf(id)
    if not life then
        fail("KillAnimFxClient has no builder for %s", id)
    else
        resetStats(); queue = {}; now = 0
        playOne(id)
        runUntil(10)
        if stats.parts == 0 then fail("%s built nothing", id) end
        table.insert(REPORT, string.format("%-17s %2d parts %2d particles, done by %.2f s of %.1f", id, stats.parts, stats.particles, stats.lastEnd, life))
        if stats.parts > caps.MAX_PARTS then fail("%s made %d parts, cap %d", id, stats.parts, caps.MAX_PARTS) end
        if stats.particles > caps.MAX_PARTICLES then fail("%s emitted %d particles, cap %d", id, stats.particles, caps.MAX_PARTICLES) end
        if life > caps.MAX_LIFETIME then fail("%s lives %.1f s, cap %.1f", id, life, caps.MAX_LIFETIME) end
        if stats.lastEnd > math.min(life, caps.MAX_LIFETIME) + 1e-6 then fail("%s is still animating at %.2f s, after its folder goes at %.2f", id, stats.lastEnd, life) end
        if not (stats.folders[1] and stats.folders[1].destroyed) then fail("%s's folder was never destroyed", id) end
    end
end
resetStats(); queue = {}; now = 0
playOne("__Greedy")
runUntil(10)
if stats.parts > caps.MAX_PARTS then fail("a greedy builder got %d parts past the cap of %d", stats.parts, caps.MAX_PARTS) end
if stats.particles > caps.MAX_PARTICLES then fail("a greedy builder got %d particles past the cap of %d", stats.particles, caps.MAX_PARTICLES) end
resetStats(); queue = {}; now = 0
for _ = 1, caps.MAX_LIVE + 3 do playOne(killIds[1]) end
if #stats.folders ~= caps.MAX_LIVE then fail("%d animations at once, cap %d", #stats.folders, caps.MAX_LIVE) end
runUntil(10)
playOne(killIds[1])
if #stats.folders ~= caps.MAX_LIVE + 1 then fail("the live count didn't come back down after the animations ended") end
runUntil(20)
resetStats()
playOne(killIds[1], vec(caps.CULL_DISTANCE + 50, 0, 0))
playOne("NoSuchAnimation")
handler({ id = killIds[1], position = "nowhere" })
if #stats.folders ~= 0 then fail("a far, unknown or malformed animation was built") end
return fails
"""


def run(root, mutate=None, report=False):
    sources = {
        "cosmetic": read(root, COSMETIC), "rotation": read(root, ROTATION), "service": read(root, SERVICE),
        "client": read(root, CLIENT), "bootstrap": read(root, BOOTSTRAP), "statesync": read(root, STATESYNC), "safevalue": read(root, "ReplicatedStorage/Shared/SafeValue.lua"),
        "reconcile": reconcile_block(read(root, PLAYERDATA)), "equip": equip_block(read(root, REWARD)),
    }
    base_pd, base_rot = base_version(root, PLAYERDATA), base_version(root, ROTATION)
    if mutate:
        mutate(sources)
    sources = {k: luau_to_lua(v) for k, v in sources.items()}
    sources["baseReconcile"] = luau_to_lua(reconcile_block(base_pd)) if base_pd else None
    sources["baseRotation"] = luau_to_lua(base_rot) if base_rot else None
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    table = lua.table_from(sources)
    try:
        result = lua.execute(CHECKS, table)
    except Exception as err:  # a crash counts as caught for a plant, a failure otherwise
        return [f"harness error: {err}"]
    if report:
        for line in lua.globals().REPORT.values():
            print("  " + line)
    return list(result.values()) if result is not None else []


def swap(key, old, new):
    def mutate(sources):
        if old not in sources[key]:
            raise SystemExit(f"killanim_check: plant text not found in {key}: {old!r}")
        sources[key] = sources[key].replace(old, new, 1)
    return mutate


PLANTS = [
    ("kill animation priced out of band", swap("cosmetic", "price = 7000,\n\t\tcolor = Color3.fromRGB(168, 122, 72)", "price = 70000,\n\t\tcolor = Color3.fromRGB(168, 122, 72)")),
    ("EquipCosmetic without the slot", swap("equip", ', KillAnimation = "killAnimation"', "")),
    ("EquipCosmetic(nil) leaves it on", swap("equip", "data.Cosmetics.killAnimation = nil\n", "")),
    ("PlayerData forgets to load it", swap("reconcile", "data.Cosmetics.killAnimation = saved.Cosmetics.killAnimation", "")),
    ("PlayerData defaults it on", swap("reconcile", "killAnimation = nil }", 'killAnimation = "KillBigBonk" }')),
    ("StateSync doesn't send it", swap("statesync", "killAnimation = data.Cosmetics.killAnimation,", "")),
    ("shop draws them with the main Random", swap("rotation", '{ kind = "GunSkin", count = 3 },', '{ kind = "KillAnimation", count = 2 },\n\t{ kind = "GunSkin", count = 3 },')),
    ("server skips the ownership check", swap("service", 'or not data.Cosmetics.owned[id] then', "then")),
    ("server skips the kind check", swap("service", 'item.kind ~= "KillAnimation" or ', "")),
    ("Chain lets an error through", swap("service", "local ok, err = pcall(KillAnimService.Play, killer, victim)", "local ok, err = true, KillAnimService.Play(killer, victim)")),
    ("client part cap removed", swap("client", "if not self.alive or self.parts >= MAX_PARTS then", "if not self.alive then")),
    ("client particle cap removed", swap("client", "count = math.min(count, MAX_PARTICLES - self.particles)", "")),
    ("client live cap removed", swap("client", "if not effect or live >= MAX_LIVE then", "if not effect then")),
    ("client never tears down", swap("client", "\t\tctx.folder:Destroy()\n", "")),
    ("a tween outlives its folder", swap("client", "\tKillRotGhost = {\n\t\tlife = 2.6,", "\tKillRotGhost = {\n\t\tlife = 1.5,")),
    ("a kill animation with no builder", swap("client", "\tKillDrumStamp = {", "\tKillDrumStampTypo = {")),
    ("culling removed", swap("client", "(camera.CFrame.Position - position).Magnitude > CULL_DISTANCE", "false")),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        missed = 0
        for name, mutate in PLANTS:
            fails = run(root, mutate)
            print(("caught  " if fails else "MISSED  ") + name + (f"  ({fails[0]})" if fails else ""))
            missed += 0 if fails else 1
        print(f"killanim_check: {len(PLANTS) - missed}/{len(PLANTS)} planted faults caught")
        sys.exit(1 if missed else 0)
    fails = run(root, report=True)
    for line in fails:
        print("FAIL " + line)
    print(f"killanim_check: {len(fails)} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
