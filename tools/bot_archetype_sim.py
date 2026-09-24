"""Bot archetypes and gun classes in a combat sim, from the real source (Oliver, 2026-09-24: bots with
"different strategies in fighting and looting", that "react differently depending on the gun they have").

No Studio, so this runs the WHOLE of BotService.lua in a Lua interpreter (lupa) with Roblox mocked:
a flat mock map with box walls and barricades, a raycast that respects them, humanoids that walk
toward MoveTo at bot speed (0.45x crouched, 1.45x sprinting), a CombatService that applies the
bots' own damage, and ProjectileService / DefenseService / ModeTeams / KOTH mocks that record every
throw and build. The real think loop's job is done by calling updateBot every BotThinkInterval;
THINK_SLICES is tools/perf_bot_cost.py's business. Bots are built from the very table Spawn builds
(extracted from the source), dealt an archetype through BotService.AssignArchetype and given a real
WeaponData gun. Nothing about aim is mocked: shootAt's own roll decides every hit.

What it measures, per archetype and per gun class, against the design (and prints):

  DUELS       archetype vs archetype, rifles, on a map with cover: average shot distance, share of
              fight thinks in cover / hidden / retreating / pushing, first shot, hit rate
  CLASSES     one archetype, each gun class in turn: average shot distance (shotgun < smg < rifle <
              dmr < sniper), and rounds a second at a target it can't kill against the same run of
              the BEFORE source (the burst shape changed per class; the rounds a minute must not)
  FLANK       the largest angle a bot works round a target in 20 s (Flanker vs Rusher)
  THIRD PARTY how much later an Opportunist watching two Rushers fight fires than a Rusher would
  AVOID       whether a Survivor shoots a passive target 85 studs off (a Rusher does)
  REPOSITION  share of shots a sniper Marksman fires from a new spot (a sniper Rusher: few)
  PEEK        share of an Anchor's fight spent hidden behind cover between bursts (a Rusher: none)
  SKIRMISH    3v3 team deathmatch: frags never land on a teammate, walls never go up on one, the
              team's fire converges on one target (focusFire), kills
  FORTIFY     an Anchor holding a KOTH hill builds toward the enemy, and not with a teammate in the way
  THROWABLES  a sticky onto a target in a vehicle; a launcher never frags what it can shoot; a
              shotgun frags a target it can only reach through a barricade
  FLEE        an unarmed Survivor smokes and walls off a pursuer; a Rusher just runs
  AIM         every hitscan shot's hit is compared with the BEFORE source's own hit-chance lines at
              that range, moment and target speed: the hit rate must be statistically identical

--plant runs planted faults against the working tree, aimed at what the code must refuse forever
(aim moved; everyone at 55 studs; a frag or a wall on a teammate; an LMG's rounds a minute up; the
third-party wait, the Survivor's restraint, the sniper's reposition, the peek, the flank, the cover
roll gone); every one must be caught.

    python tools/bot_archetype_sim.py .               the tables and the checks
    python tools/bot_archetype_sim.py . --plant       planted faults; every one must be caught
    python tools/bot_archetype_sim.py . --before REV  another BEFORE revision (default: the commit
                                                     before this tool's first commit)
    python tools/bot_archetype_sim.py . --quick       fewer runs (rougher numbers, same checks)

Not measured: pathfinding (routes are straight lines here; BotNav is mocked), vehicles, animation,
the storm, looting, and feel. tools/bot_archetype_probe.lua measures the same behaviours in Studio.
"""

import importlib.util
import math
import os
import re
import subprocess
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("perf_bot_cost", os.path.join(HERE, "perf_bot_cost.py"))
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)

BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
MATCHCONFIG = "ReplicatedStorage/Shared/MatchConfig.lua"


def luau_to_lua(source):
    """`x += a and b or c` must become `x = x + (a and b or c)`: perf_bot_cost's rewrite has no brackets,
    which is fine for the lines it runs but not for planCombatMove's `score += retreating and 3 or ...`."""
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+?)(\s*--[^\n]*)?$", r"\1\2 = \2 \3 (\4)\5", source, flags=re.M)


perf.luau_to_lua = luau_to_lua

# --------------------------------------------------------------------------------------------
# The mock Roblox: enough of the platform for BotService to run, and a world to run it in.
# --------------------------------------------------------------------------------------------

EXTRA_PRELUDE = r"""
local V = getmetatable(Vector3.new(0, 0, 0))
V.__unm = function(a) return Vector3.new(-a.X, -a.Y, -a.Z) end
V.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V.__tostring = function(a) return string.format("(%.1f, %.1f, %.1f)", a.X, a.Y, a.Z) end
function V.Cross(a, b) return Vector3.new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
Vector3.zAxis = Vector3.new(0, 0, 1)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
math.round = function(x) return math.floor(x + 0.5) end
math.sign = function(x) return x > 0 and 1 or x < 0 and -1 or 0 end
table.clone = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
table.find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
table.create = function(n, v) local t = {} for i = 1, n do t[i] = v end return t end
table.freeze = function(t) return t end
table.unpack = table.unpack or unpack
Color3 = { fromRGB = function(r, g, b) return { R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 } end,
    new = function(r, g, b) return { R = r or 0, G = g or 0, B = b or 0 } end,
    fromHSV = function() return { R = 0, G = 0, B = 0 } end }
BrickColor = { new = function() return { Color = Color3.new() } end }
NumberRange = { new = function(a, b) return { Min = a, Max = b or a } end }
UDim2 = { new = function() return {} end, fromScale = function() return {} end, fromOffset = function() return {} end }
typeof = function(v) local t = type(v) if t == "table" and v.__typeof then return v.__typeof end return t end
CFrame = {}
CFrame.lookAt = function(from, at)
    local d = at - from
    local m = d.Magnitude
    return { LookVector = m > 1e-6 and d / m or Vector3.new(0, 0, -1), Position = from }
end
CFrame.new = function(p) return { Position = p or Vector3.zero, LookVector = Vector3.new(0, 0, -1) } end
CFrame.Angles = function(_, y, _)
    return setmetatable({ y = y }, { __mul = function(cf, v)
        local c, s = math.cos(cf.y), math.sin(cf.y)
        return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
    end })
end
-- task.delay for quickFirstShot's timed shot, run by SIM.step.
TIMERS = {}
task.delay = function(d, fn, ...) local args = { ... } TIMERS[#TIMERS + 1] = { at = CLOCK + d, fn = fn, args = args } end
task.defer = function(fn, ...) fn(...) end
"""

# Module loading: a handle is { __path, Name, Parent }, require loads the real file unless MOCKS has
# a table of that name.
LOADER = r"""
return function(readSource)
    local cache = {}
    MOCKS = {}
    local function handle(dir, name)
        local h = { __path = dir .. "/" .. name .. ".lua", Name = name, __dir = dir }
        h.Parent = setmetatable({ __dir = dir, Name = dir:match("[^/]+$") }, { __index = function(t, k)
            if k == "WaitForChild" or k == "FindFirstChild" then
                return function(_, n) return handle(dir, n) end
            end
        end })
        function h.WaitForChild(_, n) return handle(dir .. "/" .. name, n) end
        function h.FindFirstChild(_, n) return handle(dir .. "/" .. name, n) end
        return h
    end
    require = function(h)
        if type(h) ~= "table" or not h.__path then error("bad require of " .. tostring(h)) end
        if MOCKS[h.Name] ~= nil then return MOCKS[h.Name] end
        if cache[h.__path] ~= nil then return cache[h.__path] end
        local src = readSource(h.__path)
        if not src then error("no module " .. h.__path) end
        local env = setmetatable({ script = h }, { __index = _G })
        local fn = assert(load(src, h.__path, "t", env))
        local r = fn()
        cache[h.__path] = r
        return r
    end
    local services = {
        ReplicatedStorage = setmetatable({}, { __index = function(_, k)
            if k == "WaitForChild" or k == "FindFirstChild" then
                return function(_, n) return handle("ReplicatedStorage", n) end
            end
        end }),
        Players = { GetPlayers = function() return {} end, GetPlayerFromCharacter = function() return nil end,
            PlayerAdded = { Connect = function() return { Disconnect = function() end } end },
            PlayerRemoving = { Connect = function() return { Disconnect = function() end } end } },
        RunService = { Heartbeat = { Connect = function() return { Disconnect = function() end } end },
            IsStudio = function() return false end, IsServer = function() return true end },
        ServerScriptService = setmetatable({}, { __index = function(_, k)
            if k == "WaitForChild" or k == "FindFirstChild" then
                return function(_, n) return handle("ServerScriptService", n) end
            end
        end }),
    }
    game = { GetService = function(_, name) return services[name] or setmetatable({}, { __index = function() return function() return nil end end }) end }
    return handle
end
"""

WORLD = r"""
-- SIM: the world. Positions are studs; a standing root is 3 studs up, its head 1.5 above that.
SIM = { walls = {}, chars = {}, tokens = {}, timers = TIMERS, teamMode = false, modeId = "BattleRoyale",
    hill = nil, holderTeam = nil, smokes = {}, dangers = {}, lastAttacker = {}, nextSlot = 0,
    throws = {}, builds = {}, launcherShots = 0, invulnerable = {}, errors = {}, stats = {} }

local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function flatDistance(a, b) return flat(a - b).Magnitude end

local function makePart(name, owner)
    local part = { Name = name, Parent = owner, CanCollide = true }
    function part.IsDescendantOf(self, a) return a == owner or a == self or (owner and owner.Parent == a and a ~= nil and a == workspace) end
    function part.FindFirstAncestorOfClass(self, cls)
        if cls == "Model" and owner and owner.__isCharacter then return owner end
        if cls == "Model" and owner and owner.__isStructure then return owner end
        return nil
    end
    function part.IsA(self, cls) return cls == "BasePart" or cls == "Part" end
    function part.GetAttribute() return nil end
    return part
end

-- Axis-aligned boxes: walls and barricades. { min, max, part, alive }
function SIM.addWall(centre, size, model)
    local half = size / 2
    local wall = { min = centre - half, max = centre + half, alive = true, centre = centre, size = size }
    wall.part = makePart(model and "BarricadeWall" or "Wall", model or SIM.mapFolder)
    if model then wall.part.structure = model end
    table.insert(SIM.walls, wall)
    return wall
end

local function rayBox(origin, dir, box)
    local tmin, tmax = 0, 1
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        local o, d = origin[axis], dir[axis]
        local lo, hi = box.min[axis], box.max[axis]
        if math.abs(d) < 1e-9 then
            if o < lo or o > hi then return nil end
        else
            local t1, t2 = (lo - o) / d, (hi - o) / d
            if t1 > t2 then t1, t2 = t2, t1 end
            tmin = math.max(tmin, t1)
            tmax = math.min(tmax, t2)
            if tmin > tmax then return nil end
        end
    end
    return tmin
end

local function charBox(c)
    local p = c.root.Position
    return { min = p - Vector3.new(1.2, 2.8, 1.2), max = p + Vector3.new(1.2, 2.2, 1.2) }
end

SIM.mapFolder = { Name = "Map", __isFolder = true }
workspace = { Name = "Workspace", Gravity = 196.2 }
function workspace.FindFirstChild(_, name) return nil end
function workspace.Raycast(_, origin, dir, params)
    local excl = params and params.FilterDescendantsInstances or {}
    local function excluded(inst)
        for _, e in ipairs(excl) do
            if e ~= nil and inst:IsDescendantOf(e) then return true end
        end
        return false
    end
    local best, bestT = nil, 1.0000001
    for _, w in ipairs(SIM.walls) do
        if w.alive then
            local t = rayBox(origin, dir, w)
            if t and t < bestT and not excluded(w.part) then bestT, best = t, w.part end
        end
    end
    for _, c in ipairs(SIM.chars) do
        if c.alive then
            local t = rayBox(origin, dir, charBox(c))
            if t and t < bestT and not excluded(c.root) then bestT, best = t, c.root end
        end
    end
    if best then return { Instance = best, Position = origin + dir * bestT, Normal = Vector3.yAxis } end
    return nil
end

local function pointInWall(p, pad)
    for _, w in ipairs(SIM.walls) do
        if w.alive and p.X > w.min.X - pad and p.X < w.max.X + pad and p.Z > w.min.Z - pad and p.Z < w.max.Z + pad then
            return w
        end
    end
    return nil
end
SIM.pointInWall = pointInWall

local function segmentCrossesWall(a, b)
    local d = b - a
    for _, w in ipairs(SIM.walls) do
        if w.alive then
            local box = { min = Vector3.new(w.min.X - 1, -100, w.min.Z - 1), max = Vector3.new(w.max.X + 1, 100, w.max.Z + 1) }
            if rayBox(a, d, box) then return true end
        end
    end
    return false
end
SIM.segmentCrossesWall = segmentCrossesWall

-- Characters ------------------------------------------------------------------------------------
function SIM.makeCharacter(name, position, team)
    local c = { Name = name, __isCharacter = true, alive = true, attrs = {}, team = team, Parent = workspace }
    c.root = makePart("HumanoidRootPart", c)
    c.root.Position = position
    c.root.CFrame = { LookVector = Vector3.new(0, 0, 1) }
    c.root.AssemblyLinearVelocity = Vector3.zero
    c.head = makePart("Head", c)
    c.head.Position = position + Vector3.new(0, 1.5, 0)
    c.humanoid = { Health = 100, MaxHealth = 100, WalkSpeed = 17, AutoRotate = true, FloorMaterial = "Grass",
        Jump = false, SeatPart = nil, DisplayName = name,
        MoveTo = function(h, p) c.walkTarget = p end,
        GetAttribute = function(h, k) return c.attrs["h_" .. k] end,
        SetAttribute = function(h, k, v) c.attrs["h_" .. k] = v end,
        SetStateEnabled = function() end,
        FindFirstChildOfClass = function() return nil end,
        GetState = function() return "Running" end }
    function c.FindFirstChild(self, n)
        if n == "HumanoidRootPart" then return self.root elseif n == "Head" then return self.head end
        return nil
    end
    function c.FindFirstChildOfClass(self, cls) if cls == "Humanoid" then return self.humanoid end return nil end
    function c.GetAttribute(self, k) return self.attrs[k] end
    function c.SetAttribute(self, k, v) self.attrs[k] = v end
    function c.GetPivot(self) return { Position = self.root.Position } end
    function c.PivotTo(self, cf) self.root.Position = cf.Position end
    function c.IsDescendantOf(self, a) return a == self or a == workspace end
    function c.Destroy(self) self.alive = false; self.Parent = nil end
    function c.GetDescendants() return {} end
    function c.GetChildren() return {} end
    table.insert(SIM.chars, c)
    return c
end

-- The token a dummy registers as: not a bot, not a player.
function SIM.makeDummy(name, position, team, opts)
    opts = opts or {}
    local c = SIM.makeCharacter(name, position, team)
    local token = { isDummy = true, character = c, name = name, shooter = opts.shooter, invulnerable = opts.invulnerable }
    if opts.seated then c.humanoid.SeatPart = { Name = "VehicleSeat" } end
    if opts.health then c.humanoid.Health = opts.health end
    SIM.tokens[c] = token
    if token.invulnerable then SIM.invulnerable[token] = true end
    Combatants.Register(c, token)
    return token
end

-- Hostility: everyone in the battle royale, the other team in a team mode (what ModeTeams tells
-- BotService.IsHostile in the real game).
function SIM.teamOf(token)
    return token and token.character and token.character.team or nil
end
function SIM.hostile(a, b)
    if a == b then return false end
    if not SIM.teamMode then return true end
    local ta, tb = SIM.teamOf(a), SIM.teamOf(b)
    return ta == nil or tb == nil or ta ~= tb
end

-- Module mocks ----------------------------------------------------------------------------------
Combatants = {}
local registry = {}
function Combatants.Register(character, token) registry[character] = token end
function Combatants.Unregister(character) registry[character] = nil end
function Combatants.FromCharacter(character) return registry[character] end
function Combatants.IsPlayer(token) return type(token) == "table" and token.isPlayer == true end
function Combatants.IsBot(token) return type(token) == "table" and token.isBot == true end
function Combatants.GetCharacter(token) return token and token.character end
function Combatants.GetHumanoid(token) return token and token.character and token.character.humanoid end
function Combatants.GetRoot(token) return token and token.character and token.character.alive and token.character.root or nil end
function Combatants.IsAlive(token) local h = Combatants.GetHumanoid(token) return h ~= nil and h.Health > 0 and token.character.alive end
function Combatants.Exists(token) return token ~= nil end
function Combatants.All()
    local all = {}
    for character, token in pairs(registry) do
        if character.alive then all[character] = token end
    end
    return all
end
function Combatants.GetName(token) return token and token.name or "?" end
MOCKS.Combatants = Combatants

CombatService = { HeadshotScale = 1 }
function CombatService.GetLastAttacker(token)
    local e = SIM.lastAttacker[token]
    if e then return e.attacker, e.weaponId, e.at end
    return nil
end
function CombatService.BroadcastShot(shooter, origin, endPoints, rarity)
    if SIM.onShot then SIM.onShot(shooter, origin, endPoints) end
end
function CombatService.BreakGlassAlong() end
function CombatService.DealDamage(attacker, victim, amount, weaponId, headshot)
    if SIM.onDamage then SIM.onDamage(attacker, victim, amount, weaponId) end
end
function CombatService.StructureFromPart(part) return part and part.structure or nil end
function CombatService.DamageStructure(token, model, amount)
    SIM.lastShotWasCover = true
    model.health = model.health - amount
    if model.health <= 0 and model.Parent then
        model.Parent = nil
        model.wall.alive = false
    end
end
function CombatService.SmokeBlocks(a, b)
    local d = b - a
    local len = d.Magnitude
    if len < 1e-6 then return false end
    for _, s in ipairs(SIM.smokes) do
        if CLOCK < s.untilTime then
            local t = math.clamp((s.position - a):Dot(d) / (len * len), 0, 1)
            if (a + d * t - s.position).Magnitude < s.radius then return true end
        end
    end
    return false
end
function CombatService.ForgetToken() end
MOCKS.CombatService = CombatService

DefenseService = {}
local structures = {}
function DefenseService.OwnerOf(model) return model and model.owner end
function DefenseService.Deploy(owner, character, itemId, centre, facing)
    -- findSite: level ground, nothing solid at the site, nobody standing in it.
    local across = Vector3.new(-facing.Z, 0, facing.X)
    for _, c in ipairs(SIM.chars) do
        if c.alive and flatDistance(c.root.Position, centre) < 3 then return nil, "Someone is in the way." end
    end
    if pointInWall(centre, 2) then return nil, "No room." end
    local model = { Name = "RotBarricade", __isStructure = true, Parent = workspace, owner = owner, health = 250 }
    function model.GetPivot(self) return { Position = centre } end
    function model.FindFirstChildOfClass() return nil end
    function model.FindFirstChild() return nil end
    function model.GetAttribute() return nil end
    -- The wall itself: 8 across, 1.5 thick, 5 high, at ground level.
    local size = Vector3.new(math.abs(across.X) * 8 + math.abs(facing.X) * 1.5, 5, math.abs(across.Z) * 8 + math.abs(facing.Z) * 1.5)
    if math.abs(facing.X) > 0.3 and math.abs(facing.Z) > 0.3 then size = Vector3.new(6, 5, 6) end
    local wall = SIM.addWall(Vector3.new(centre.X, 2.5, centre.Z), size, model)
    model.wall = wall
    structures[model] = true
    -- Recorded for the checks: who built, where, and whether a teammate stood in the way of it.
    local friendlyNear = 0
    for character, token in pairs(Combatants.All()) do
        if token ~= owner and character.humanoid.Health > 0 and not SIM.hostile(owner, token)
            and flatDistance(character.root.Position, centre) < 9 then
            friendlyNear = friendlyNear + 1
        end
    end
    table.insert(SIM.builds, { owner = owner, centre = centre, at = CLOCK, friendlyNear = friendlyNear })
    return model
end
MOCKS.DefenseService = DefenseService

BotNav = { Stats = {}, Priority = { Urgent = 1, Combat = 2, Loot = 3, Wander = 4 } }
function BotNav.Attach(bot) bot.nav = { failures = 0, recheckRouteAt = 0, index = 1 } end
function BotNav.Drop(bot) end
function BotNav.HasRoute(bot) return false end
function BotNav.IsPending(bot) return false end
function BotNav.Destination(bot) return nil end
function BotNav.Request(bot, destination, priority) end
function BotNav.Follow(bot, humanoid, root, goal, now) humanoid:MoveTo(goal) end
function BotNav.Progress(bot, humanoid, root, target, now) return nil end
function BotNav.RecentlyFailed() return false end
function BotNav.Pump() end
function BotNav.Clear() end
function BotNav.StepParams(character) return { FilterDescendantsInstances = { character } } end
function BotNav.CanStep(root, character, point, params)
    if pointInWall(point, 1.5) then return false end
    return not segmentCrossesWall(root.Position, point)
end
function BotNav.FloorAt() return 0 end
-- Cover: a point within the radii the threat can't see (a wall between), reachable in a straight line.
function BotNav.FindCover(root, character, threatPosition, radii, isAllowed, threatCharacter)
    local from = root.Position
    local best, bestGap = nil, math.huge
    for _, radius in ipairs(radii) do
        for i = 0, 11 do
            local angle = i / 12 * math.pi * 2
            local candidate = from + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            if (not isAllowed or isAllowed(candidate)) and BotNav.CanStep(root, character, candidate, nil) then
                local excl = { character }
                if threatCharacter then table.insert(excl, threatCharacter) end
                for _, c in ipairs(SIM.chars) do table.insert(excl, c) end
                local eye = candidate + Vector3.new(0, 1.5, 0)
                local hit = workspace:Raycast(threatPosition, eye - threatPosition, { FilterDescendantsInstances = excl })
                if hit and radius < bestGap then
                    best, bestGap = candidate, radius
                end
            end
        end
        if best then break end
    end
    if best then return best, true end
    return nil
end
MOCKS.BotNav = BotNav

MOCKS.StormService = { GetState = function() return { status = "Idle", radius = 0, center = Vector3.zero } end,
    IsOutside = function() return false end }
MOCKS.MapGenerator = { GroundHeightAt = function() return 0 end }
MOCKS.SupplyDropService = { FindNearest = function() return nil end, ClaimForBot = function() return nil end }
MOCKS.LootService = { BaseRadius = 6, ClaimForBot = function() return nil end, ClaimHealForBot = function() return nil end, ClaimTime = 1 }
MOCKS.MovementService = { BotDrop = function() return false end, Launch = function() end, RocketVelocity = function(d) return d end }
MOCKS.NameplateService = { Attach = function() end }
MOCKS.AccessoryService = { Attach = function() end }
MOCKS.CompanionService = { AttachBot = function() end }
MOCKS.WeaponService = {
    Heals = { Bandage = { amount = 15, cap = 75, max = 15 }, MedKit = { amount = 100, cap = 100, max = 3 } },
    Shields = { MiniShield = { amount = 25, cap = 50, max = 6 }, ShieldPotion = { amount = 50, cap = 100, max = 3 } },
    BuildGunModel = function() return nil end, MountGun = function() end,
}
MOCKS.BrainrotData = { OfRarity = function() return {} end }
MOCKS.CosmeticData = {}
MOCKS.AchievementData = { List = { { title = "Bot" } } }
MOCKS.Remotes = { Event = function() return { FireAllClients = function() end, FireClient = function() end } end }
MOCKS.ObjectiveZone = { Radius = function(mode) return mode and mode.hillRadius or 28 end }

-- The lazily reached modules.
MOCKS.MatchService = {
    SetSprinting = function(bot, want) bot.character.sprinting = want return true end,
    GetStamina = function() return 1, false end,
    SetCrouching = function(bot, want) bot.character.crouched = want return true end,
    StartSlide = function() return false end,
    SetBaseSpeed = function() return true end,
}
MOCKS.ModeTeams = {
    IsActive = function() return SIM.teamMode end,
    TeamOf = function(token) return SIM.teamOf(token) end,
    Arena = function() return nil end,
    BaseOf = function() return nil end,
}
-- No vehicles in the sim (the BOT VEHICLES section is another worker's; lazy() reads false as absent).
MOCKS.VehicleWeapons = false
MOCKS.VehicleService = false
MOCKS.ModeKingOfTheHill = {
    Objectives = function() return {} end,
    Position = function(team) return SIM.hill end,
    Occupancy = function(point)
        local counts = { 0, 0 }
        for character, token in pairs(Combatants.All()) do
            local team = SIM.teamOf(token)
            if team and character.humanoid.Health > 0 and flatDistance(character.root.Position, point) <= 28 then
                counts[team] = counts[team] + 1
            end
        end
        return counts
    end,
    Holder = function(a, b) if a > b then return 1 elseif b > a then return 2 end return SIM.holderTeam end,
}
MOCKS.GameMode = { Current = function() return { id = SIM.modeId } end }
MOCKS.ProjectileService = {
    Throw = function(token, itemId, point, options)
        local info = MOCKS.ProjectileService.ProjectileInfo(itemId)
        local friendlyNear = 0
        if info.blastRadius and info.blastRadius > 0 then
            for character, other in pairs(Combatants.All()) do
                if other ~= token and character.humanoid.Health > 0 and not SIM.hostile(token, other)
                    and (character.root.Position - point).Magnitude < info.blastRadius + 3 then
                    friendlyNear = friendlyNear + 1
                end
            end
        end
        local from = token.character.root.Position
        table.insert(SIM.throws, { token = token, itemId = itemId, point = point, at = CLOCK, cook = options and options.cook or 0,
            distance = flatDistance(from, point), friendlyNear = friendlyNear })
        if info.kind == "smoke" then
            table.insert(SIM.smokes, { position = point, radius = 8, untilTime = CLOCK + 16 })
        elseif info.blastRadius > 0 then
            table.insert(SIM.dangers, { position = point, radius = info.blastRadius, owner = token,
                detonateAt = CLOCK + (info.fuse or 2.5) - (options and options.cook or 0), damage = info.blastDamage or 80 })
        end
        return true
    end,
    ProjectileInfo = function(id)
        if id == "CookedCoconut" then return { kind = "frag", fuse = 3.2, blastRadius = 13, blastDamage = 90, throwRange = 60 } end
        if id == "LowkeyLatte" then return { kind = "smoke", blastRadius = 0, smokeRadius = 16, throwRange = 60 } end
        if id == "ClingyCrumpet" then return { kind = "sticky", fuse = 2.5, blastRadius = 12, blastDamage = 110, throwRange = 60 } end
        local def = WeaponData.Get(id)
        if def and def.projectile then return { kind = def.projectile, blastRadius = def.splashRadius or 12, blastDamage = def.damage } end
        return nil
    end,
    Dangers = function(position, radius)
        local found = {}
        for _, d in ipairs(SIM.dangers) do
            if not d.done and (d.position - position).Magnitude <= radius + d.radius then
                table.insert(found, { position = d.position, radius = d.radius, detonatesIn = d.detonateAt - CLOCK, owner = d.owner })
            end
        end
        return found
    end,
    LeadAim = function(weaponId, origin, target, velocity) return target end,
    FireWeapon = function(token, weaponId, origin, aim)
        SIM.launcherShots = SIM.launcherShots + 1
        local def = WeaponData.Get(weaponId)
        local radius = def and def.splashRadius or 12
        for character, other in pairs(Combatants.All()) do
            if other ~= token and character.humanoid.Health > 0 then
                local gap = (character.root.Position - aim).Magnitude
                if gap <= radius then
                    CombatService.DealDamage(token, other, (def and def.damage or 60) * MatchConfig.BotDamageScale * (1 - gap / radius * 0.5), weaponId, false)
                end
            end
        end
        return true
    end,
}
MOCKS.ProjectileService.ThrowableInfo = MOCKS.ProjectileService.ProjectileInfo

-- Damage and the shot ledger --------------------------------------------------------------------
-- A hitscan shot: expected hit chance from the BEFORE source's own lines (CHANCE_AT, set by the
-- driver), the actual hit from DealDamage that follows.
SIM.expected, SIM.expectedVar, SIM.hits, SIM.hitscanShots = 0, 0, 0, 0
SIM.pendingShot = nil
function SIM.onShot(shooter, origin, endPoints)
    if not (shooter and shooter.isBot and #endPoints == 1 and shooter.target) then return end
    local targetRoot = Combatants.GetRoot(shooter.target)
    if not targetRoot then return end
    local distance = (targetRoot.Position - shooter.character.root.Position).Magnitude
    local p = CHANCE_AT and CHANCE_AT(shooter, CLOCK, distance, targetRoot) or 0
    SIM.lastShotWasCover = false
    SIM.pendingShot = { shooter = shooter, p = p, distance = distance }
    local m = shooter.sim
    if m then
        m.shots = m.shots + 1
        m.distSum = m.distSum + distance
        if m.firstShotAt == nil then m.firstShotAt = CLOCK end
        if m.lastShotPos and flatDistance(m.lastShotPos, shooter.character.root.Position) > 4 then
            m.movedBetween = m.movedBetween + 1
        end
        m.lastShotPos = shooter.character.root.Position
        m.hitPending = true
    end
end
-- Called after each think: a shot whose next call wasn't DamageStructure was a real roll.
function SIM.settleShot()
    local s = SIM.pendingShot
    if s then
        if not SIM.lastShotWasCover then
            SIM.hitscanShots = SIM.hitscanShots + 1
            SIM.expected = SIM.expected + s.p
            SIM.expectedVar = SIM.expectedVar + s.p * (1 - s.p)
            if s.hit then SIM.hits = SIM.hits + 1 end
        end
        SIM.pendingShot = nil
    end
end
function SIM.onDamage(attacker, victim, amount, weaponId)
    local def = weaponId and WeaponData.Get(weaponId)
    if def and not def.projectile and SIM.pendingShot and SIM.pendingShot.shooter == attacker then
        SIM.pendingShot.hit = true
        if attacker.sim then attacker.sim.hits = attacker.sim.hits + 1 end
    end
    local character = victim and victim.character
    if not (character and character.alive) then return end
    if not SIM.invulnerable[victim] then
        character.humanoid.Health = math.max(0, character.humanoid.Health - amount)
        if character.humanoid.Health <= 0 then
            SIM.kills = (SIM.kills or 0) + 1
            if attacker and attacker.sim then attacker.sim.kills = attacker.sim.kills + 1 end
        end
    end
    SIM.lastAttacker[victim] = { attacker = attacker, weaponId = weaponId, at = CLOCK }
end

-- Bots -----------------------------------------------------------------------------------------
-- BOT_TABLE (set by the driver) is Spawn's own `local bot = { ... }`, so the sim's bots have exactly
-- the fields a live one has.
function SIM.makeBot(name, archetype, weaponId, position, team, opts)
    opts = opts or {}
    local character = SIM.makeCharacter(name, position, team)
    local humanoid = character.humanoid
    humanoid.MaxHealth = opts.maxHealth or MatchConfig.BotHealth
    humanoid.Health = opts.health or humanoid.MaxHealth
    local bot = BOT_TABLE(name, character, humanoid, nil, SIM.nextSlot, MatchConfig)
    SIM.nextSlot = SIM.nextSlot + 1
    bot.facing = { Enabled = false, CFrame = nil }
    character.facing = bot.facing
    bot.lastHealth = humanoid.Health
    BotNav.Attach(bot)
    if BotService.AssignArchetype and archetype then BotService.AssignArchetype(bot, archetype) end
    Combatants.Register(character, bot)
    SIM.tokens[character] = bot
    if weaponId then
        local def = WeaponData.Get(weaponId)
        assert(def, "no weapon " .. tostring(weaponId))
        bot.weapon = def
        bot.loadoutWeapon = true
        bot.magWeapon = def.id
        bot.mag = def.magSize
    end
    bot.heals = { Bandage = opts.bandages or 0, MedKit = 0 }
    bot.defenses = opts.defenses or 0
    if opts.throwables then
        for itemId, n in pairs(opts.throwables) do bot.throwables[itemId] = n end
    end
    bot.sim = { shots = 0, hits = 0, distSum = 0, firstShotAt = nil, movedBetween = 0, kills = 0, fightThinks = 0,
        coverThinks = 0, hideThinks = 0, retreatThinks = 0, pushThinks = 0, thirdThinks = 0, maxFlank = 0,
        firstBearing = nil, states = {}, minShotDistance = math.huge, firstFightAt = nil }
    table.insert(BotService.GetAll(), bot)
    return bot
end

-- Time -----------------------------------------------------------------------------------------
local function moveCharacter(c, dt)
    local root = c.root
    local old = root.Position
    local moved = false
    if c.walkTarget and c.alive and c.humanoid.Health > 0 then
        local delta = flat(c.walkTarget - old)
        local gap = delta.Magnitude
        if gap > 0.5 then
            local speed = c.humanoid.WalkSpeed * (c.crouched and 0.45 or 1) * (c.sprinting and 1.45 or 1)
            local step = math.min(gap, speed * dt)
            local dir = delta / gap
            local candidates = { old + dir * step, old + Vector3.new(dir.X, 0, 0) * step, old + Vector3.new(0, 0, dir.Z) * step }
            for _, p in ipairs(candidates) do
                if not pointInWall(p, 1.2) then
                    root.Position = Vector3.new(p.X, 3, p.Z)
                    moved = true
                    break
                end
            end
            if moved and not (c.facing and c.facing.Enabled) then root.CFrame.LookVector = dir end
        end
    end
    root.AssemblyLinearVelocity = (root.Position - old) / dt
    if c.facing and c.facing.Enabled and c.facing.CFrame then
        root.CFrame.LookVector = flat(c.facing.CFrame.LookVector).Unit
    end
    c.head.Position = root.Position + Vector3.new(0, 1.5, 0)
end

function SIM.step(dt)
    CLOCK = CLOCK + dt
    for _, c in ipairs(SIM.chars) do
        if c.alive then moveCharacter(c, dt) end
    end
    -- Timed shots (quickFirstShot) and frags going off.
    local due = {}
    for i = #TIMERS, 1, -1 do
        if CLOCK >= TIMERS[i].at - 1e-9 then table.insert(due, table.remove(TIMERS, i)) end
    end
    for _, t in ipairs(due) do
        local ok, err = pcall(t.fn, table.unpack(t.args))
        if not ok then table.insert(SIM.errors, "timer: " .. tostring(err)) end
    end
    for _, d in ipairs(SIM.dangers) do
        if not d.done and CLOCK >= d.detonateAt then
            d.done = true
            for character, token in pairs(Combatants.All()) do
                if character.humanoid.Health > 0 then
                    local gap = (character.root.Position - d.position).Magnitude
                    if gap <= d.radius then
                        CombatService.DealDamage(d.owner, token, d.damage * (1 - gap / d.radius * 0.6), "CookedCoconut", false)
                    end
                end
            end
        end
    end
end

-- Dummy shooters plink their nearest enemy every second (damage only; no shot roll).
function SIM.dummiesAct()
    for character, token in pairs(Combatants.All()) do
        if token.isDummy and token.shooter and character.humanoid.Health > 0 and CLOCK >= (token.nextShotAt or 0) then
            token.nextShotAt = CLOCK + 1
            local best, bestGap = nil, 120
            for other, otherToken in pairs(Combatants.All()) do
                if otherToken ~= token and SIM.hostile(token, otherToken) and other.humanoid.Health > 0 then
                    local gap = flatDistance(other.root.Position, character.root.Position)
                    if gap < bestGap then best, bestGap = otherToken, gap end
                end
            end
            if best then CombatService.DealDamage(token, best, token.shooter, "SahurPistol", false) end
        end
    end
end

-- One think for every living bot, with the per-think metrics.
function SIM.think()
    refreshCombatants()
    for _, bot in ipairs(BotService.GetAll()) do
        if bot.character.alive and bot.humanoid.Health > 0 then
            bot.branch = "idle"
            local ok, err = pcall(updateBot, bot)
            if not ok then table.insert(SIM.errors, tostring(err)) end
            SIM.settleShot()
            local m = bot.sim
            if m and bot.branch == "fight" then
                m.fightThinks = m.fightThinks + 1
                if m.firstFightAt == nil then m.firstFightAt = CLOCK end
                local state = bot.fightState or "engage"
                m.states[state] = (m.states[state] or 0) + 1
                local inCover = (bot.coverUntil and CLOCK < bot.coverUntil) or state == "cover" or state == "peekHide"
                    or state == "peekShoot" or state == "thirdParty"
                if inCover then m.coverThinks = m.coverThinks + 1 end
                if state == "peekHide" then m.hideThinks = m.hideThinks + 1 end
                if state == "retreat" then m.retreatThinks = m.retreatThinks + 1 end
                if state == "push" then m.pushThinks = m.pushThinks + 1 end
                if state == "thirdParty" then m.thirdThinks = m.thirdThinks + 1 end
                local targetRoot = Combatants.GetRoot(bot.target)
                if targetRoot then
                    local away = flat(bot.character.root.Position - targetRoot.Position)
                    if away.Magnitude > 1 then
                        local bearing = math.atan(away.Z, away.X)
                        if m.firstBearing == nil then m.firstBearing = bearing end
                        local diff = math.abs(bearing - m.firstBearing)
                        if diff > math.pi then diff = math.pi * 2 - diff end
                        m.maxFlank = math.max(m.maxFlank, math.deg(diff))
                    end
                end
            end
        end
    end
    SIM.dummiesAct()
end

function SIM.run(seconds)
    local interval = MatchConfig.BotThinkInterval
    local nextThink = CLOCK
    local stop = CLOCK + seconds
    while CLOCK < stop do
        if CLOCK >= nextThink - 1e-9 then
            SIM.think()
            nextThink = nextThink + interval
        end
        SIM.step(interval / 5)
    end
end

function SIM.reset(seed)
    BotService.Clear()
    for _, c in ipairs(SIM.chars) do c.alive = false end
    SIM.walls, SIM.chars, SIM.tokens, SIM.smokes, SIM.dangers, SIM.lastAttacker = {}, {}, {}, {}, {}, {}
    SIM.throws, SIM.builds, SIM.invulnerable, SIM.errors = {}, {}, {}, {}
    SIM.launcherShots, SIM.kills, SIM.nextSlot = 0, 0, 0
    SIM.teamMode, SIM.modeId, SIM.hill, SIM.holderTeam = false, "BattleRoyale", nil, nil
    for k in pairs(registry) do registry[k] = nil end
    for i = #TIMERS, 1, -1 do TIMERS[i] = nil end
    math.randomseed(seed)
    CLOCK = 100 + seed * 0.001
    BotService.IsHostile = function(bot, other) return SIM.hostile(bot, other) end
end

-- The duel map: two pairs of walls a third and two thirds of the way along, a block in the middle.
function SIM.duelMap()
    SIM.addWall(Vector3.new(-14, 2.5, 22), Vector3.new(6, 5, 1.5))
    SIM.addWall(Vector3.new(14, 2.5, 22), Vector3.new(6, 5, 1.5))
    SIM.addWall(Vector3.new(-14, 2.5, 58), Vector3.new(6, 5, 1.5))
    SIM.addWall(Vector3.new(14, 2.5, 58), Vector3.new(6, 5, 1.5))
    SIM.addWall(Vector3.new(0, 2.5, 40), Vector3.new(4, 5, 4))
    SIM.addWall(Vector3.new(-26, 2.5, 40), Vector3.new(1.5, 5, 8))
    SIM.addWall(Vector3.new(26, 2.5, 40), Vector3.new(1.5, 5, 8))
end

function SIM.metrics(bot)
    local m = bot.sim
    local out = {}
    for k, v in pairs(m) do
        if type(v) == "number" then out[k] = v end
    end
    out.avgShotDistance = m.shots > 0 and m.distSum / m.shots or -1
    out.alive = bot.humanoid.Health > 0 and 1 or 0
    out.health = bot.humanoid.Health
    out.firstShotAt = m.firstShotAt or -1
    out.firstFightAt = m.firstFightAt or -1
    for k, v in pairs(m.states) do out["state_" .. k] = v end
    return out
end
"""

# Scenarios, as Lua returning tables of numbers -------------------------------------------------

SCENARIOS = r"""
SCEN = {}

-- A vs B, 80 studs apart on the duel map. Returns both bots' metrics and the ledger.
function SCEN.duel(archA, gunA, archB, gunB, seconds, opts)
    opts = opts or {}
    SIM.duelMap()
    local a = SIM.makeBot("A", archA, gunA, Vector3.new(-4, 3, 0), nil, { bandages = 1 })
    local b = SIM.makeBot("B", archB, gunB, Vector3.new(4, 3, 80), nil, { bandages = 1 })
    a.character.root.CFrame.LookVector = Vector3.new(0, 0, 1)
    b.character.root.CFrame.LookVector = Vector3.new(0, 0, -1)
    SIM.run(seconds)
    return { a = SIM.metrics(a), b = SIM.metrics(b) }
end

-- Rounds a second at a target that cannot die, open ground, from the class's own range.
function SCEN.throughput(arch, gun, seconds)
    local bot = SIM.makeBot("A", arch, gun, Vector3.new(0, 3, 0), nil)
    local dials = BotService.DialsOf and BotService.DialsOf(bot)
    local range = dials and dials.range or 40
    SIM.makeDummy("D", Vector3.new(0, 3, range), nil, { invulnerable = true })
    SIM.run(seconds)
    local m = SIM.metrics(bot)
    m.perSecond = m.shots / seconds
    return m
end

-- How far round a passive target the bot works in `seconds`.
function SCEN.flank(arch, gun, seconds)
    local bot = SIM.makeBot("A", arch, gun, Vector3.new(0, 3, 0), nil)
    SIM.makeDummy("D", Vector3.new(0, 3, 50), nil, { invulnerable = true })
    SIM.run(seconds)
    return SIM.metrics(bot)
end

-- Two tough Rushers (300 health, so neither is "weakened" for a while) fight; an observer of `arch`
-- arrives 1.5 s in and watches from 60 studs. When does it fire, and at what?
function SCEN.thirdParty(arch, seconds)
    local a = SIM.makeBot("A", "Rusher", "CrocodiloRifle", Vector3.new(-14, 3, 60), nil, { maxHealth = 300 })
    local b = SIM.makeBot("B", "Rusher", "CrocodiloRifle", Vector3.new(14, 3, 60), nil, { maxHealth = 300 })
    a.character.root.CFrame.LookVector = Vector3.new(1, 0, 0)
    b.character.root.CFrame.LookVector = Vector3.new(-1, 0, 0)
    SIM.run(1.5)
    local observer = SIM.makeBot("O", arch, "CrocodiloRifle", Vector3.new(0, 3, 0), nil)
    observer.character.root.CFrame.LookVector = Vector3.new(0, 0, 1)
    local firstTargetHealth = -1
    local realOnShot = SIM.onShot
    SIM.onShot = function(shooter, origin, endPoints)
        if shooter == observer and firstTargetHealth < 0 then
            local h = Combatants.GetHumanoid(observer.target)
            firstTargetHealth = h and h.Health or -1
        end
        realOnShot(shooter, origin, endPoints)
    end
    SIM.run(seconds - 1.5)
    SIM.onShot = realOnShot
    local m = SIM.metrics(observer)
    m.firstTargetHealth = firstTargetHealth
    return m
end

-- A passive target 85 studs off. Does the bot start a fight it doesn't need?
function SCEN.avoid(arch, gun, seconds)
    local bot = SIM.makeBot("A", arch, gun, Vector3.new(0, 3, 0), nil)
    SIM.makeDummy("D", Vector3.new(0, 3, 85), nil, { invulnerable = true })
    SIM.run(seconds)
    return SIM.metrics(bot)
end

-- Anchor vs Rusher with cover round the Anchor.
function SCEN.peek(archA, archB, seconds)
    SIM.duelMap()
    SIM.addWall(Vector3.new(-6, 2.5, 6), Vector3.new(5, 5, 1.5))
    SIM.addWall(Vector3.new(6, 2.5, 6), Vector3.new(5, 5, 1.5))
    local a = SIM.makeBot("A", archA, "CrocodiloRifle", Vector3.new(0, 3, 0), nil, { bandages = 1 })
    local b = SIM.makeBot("B", archB, "CrocodiloRifle", Vector3.new(0, 3, 70), nil, { bandages = 1 })
    a.character.root.CFrame.LookVector = Vector3.new(0, 0, 1)
    b.character.root.CFrame.LookVector = Vector3.new(0, 0, -1)
    SIM.run(seconds)
    return { a = SIM.metrics(a), b = SIM.metrics(b) }
end

-- 3v3 team deathmatch on the duel map, everyone kitted with frags, smoke and walls.
function SCEN.skirmish(seconds)
    SIM.teamMode, SIM.modeId = true, "TeamDeathmatch"
    SIM.duelMap()
    local kit = { throwables = { CookedCoconut = 2, LowkeyLatte = 1 }, defenses = 2, bandages = 1 }
    local one = { { "Rusher", -20 }, { "Anchor", 0 }, { "Marksman", 20 } }
    local two = { { "Flanker", -20 }, { "Opportunist", 0 }, { "Survivor", 20 } }
    local bots = {}
    for i, spec in ipairs(one) do
        local bot = SIM.makeBot("T1" .. spec[1], spec[1], "CrocodiloRifle", Vector3.new(spec[2], 3, -4), 1, kit)
        bot.character.root.CFrame.LookVector = Vector3.new(0, 0, 1)
        table.insert(bots, bot)
    end
    for i, spec in ipairs(two) do
        local bot = SIM.makeBot("T2" .. spec[1], spec[1], "CrocodiloRifle", Vector3.new(spec[2], 3, 84), 2, kit)
        bot.character.root.CFrame.LookVector = Vector3.new(0, 0, -1)
        table.insert(bots, bot)
    end
    -- Focus: on each think, how many of a team's fighting bots share the same target.
    local sharedThinks, fightingThinks = 0, 0
    local realThink = SIM.think
    SIM.think = function()
        realThink()
        for team = 1, 2 do
            local counts, fighting = {}, 0
            for _, bot in ipairs(bots) do
                if bot.character.team == team and bot.branch == "fight" and bot.target then
                    counts[bot.target] = (counts[bot.target] or 0) + 1
                    fighting = fighting + 1
                end
            end
            if fighting >= 2 then
                fightingThinks = fightingThinks + 1
                for _, n in pairs(counts) do
                    if n >= 2 then sharedThinks = sharedThinks + 1 break end
                end
            end
        end
    end
    SIM.run(seconds)
    SIM.think = realThink
    local fragFriendly, frags, smokes, buildFriendly = 0, 0, 0, 0
    for _, t in ipairs(SIM.throws) do
        if t.itemId == "CookedCoconut" then frags = frags + 1; fragFriendly = fragFriendly + (t.friendlyNear > 0 and 1 or 0) end
        if t.itemId == "LowkeyLatte" then smokes = smokes + 1 end
    end
    for _, b in ipairs(SIM.builds) do
        if b.friendlyNear > 0 then buildFriendly = buildFriendly + 1 end
    end
    local out = { kills = SIM.kills or 0, frags = frags, fragFriendly = fragFriendly, smokes = smokes, builds = #SIM.builds,
        buildFriendly = buildFriendly, sharedThinks = sharedThinks, fightingThinks = fightingThinks,
        focusFire = (STATS.focusFire or 0), flankMoves = (STATS.flankMoves or 0) }
    return out
end

-- KOTH: team 1 holds the hill; an Anchor with two walls stands its ring. With `friendly`, a
-- teammate stands where the wall would go.
function SCEN.fortify(arch, friendly, seconds)
    SIM.teamMode, SIM.modeId = true, "KingOfTheHill"
    SIM.hill = Vector3.new(0, 3, 0)
    SIM.holderTeam = 1
    local bot = SIM.makeBot("A", arch, "CrocodiloRifle", Vector3.new(12, 3, 0), 1, { defenses = 2 })
    bot.slot = 0 -- the ring seat at angle 0: it stands at +x and walls toward +x
    if friendly then
        SIM.makeDummy("F", Vector3.new(21, 3, 0), 1, { invulnerable = true })
    end
    SIM.run(seconds)
    local fortify = (STATS.buildsFortify or 0)
    local friendlyBuilds = 0
    for _, b in ipairs(SIM.builds) do if b.friendlyNear > 0 then friendlyBuilds = friendlyBuilds + 1 end end
    return { builds = #SIM.builds, fortify = fortify, refusedFriendly = (STATS.buildsRefusedFriendly or 0), friendlyBuilds = friendlyBuilds,
        objective = bot.objectiveKind == "hold" and 1 or 0,
        keptRole = (not BotService.ArchetypeOf or BotService.ArchetypeOf(bot).name == arch) and 1 or 0 }
end

-- A target in a vehicle 30 studs off, a bot with one sticky.
function SCEN.sticky(arch, gun, seconds)
    local bot = SIM.makeBot("A", arch, gun, Vector3.new(0, 3, 0), nil, { throwables = { ClingyCrumpet = 1 } })
    SIM.makeDummy("D", Vector3.new(0, 3, 30), nil, { invulnerable = true, seated = true })
    SIM.run(seconds)
    local n = 0
    for _, t in ipairs(SIM.throws) do if t.itemId == "ClingyCrumpet" then n = n + 1 end end
    return { sticky = n, shots = bot.sim.shots }
end

-- Two targets bunched 40 studs off, a bot with two frags.
function SCEN.bunched(arch, gun, seconds)
    local bot = SIM.makeBot("A", arch, gun, Vector3.new(0, 3, 0), nil, { throwables = { CookedCoconut = 2 } })
    SIM.makeDummy("D1", Vector3.new(-3, 3, 40), nil, { invulnerable = true })
    SIM.makeDummy("D2", Vector3.new(3, 3, 40), nil, { invulnerable = true })
    SIM.run(seconds)
    local n, minDistance, cooked = 0, math.huge, 0
    for _, t in ipairs(SIM.throws) do
        if t.itemId == "CookedCoconut" then n = n + 1; minDistance = math.min(minDistance, t.distance); if t.cook > 0 then cooked = cooked + 1 end end
    end
    return { frags = n, minDistance = minDistance < math.huge and minDistance or -1, cooked = cooked, shots = bot.sim.shots }
end

-- A target behind an enemy barricade 30 studs off, a bot with a frag: flush it or shoot the wall?
function SCEN.flush(arch, gun, seconds)
    local bot = SIM.makeBot("A", arch, gun, Vector3.new(0, 3, 0), nil, { throwables = { CookedCoconut = 2 } })
    local enemy = SIM.makeDummy("D", Vector3.new(0, 3, 30), nil, { invulnerable = true })
    local model = DefenseService.Deploy(enemy, enemy.character, "RotBarricade", Vector3.new(0, 1, 24), Vector3.new(0, 0, -1))
    assert(model, "barricade did not deploy")
    SIM.run(seconds)
    local n = 0
    for _, t in ipairs(SIM.throws) do if t.itemId == "CookedCoconut" then n = n + 1 end end
    return { frags = n, coverShots = (STATS.coverShots or 0) }
end

-- Unarmed, shot at from 40 studs, with a wall and a smoke to spend.
function SCEN.flee(arch, seconds)
    local bot = SIM.makeBot("A", arch, nil, Vector3.new(0, 3, 0), nil, { defenses = 1, throwables = { LowkeyLatte = 1 } })
    SIM.makeDummy("D", Vector3.new(0, 3, 40), nil, { invulnerable = true, shooter = 6 })
    SIM.run(seconds)
    local smokes = 0
    for _, t in ipairs(SIM.throws) do if t.itemId == "LowkeyLatte" then smokes = smokes + 1 end end
    return { blocks = (STATS.buildsBlock or 0), builds = #SIM.builds, smokes = smokes, flees = (STATS.flees or 0), health = bot.humanoid.Health }
end
"""


# --------------------------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------------------------

def read_tree(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read()


def bot_table_source(bot_src):
    body = perf.between(bot_src, "\t\t\tlocal bot = {\n\t\t\t\tisBot = true", "\t\t\t}\n\t\t\tnextSlot")
    return ("return function(name, character, humanoid, weapon, nextSlot, MatchConfig)\n" + perf.luau_to_lua(body)
            + "\t\t\t}\n\t\t\treturn bot\nend\n")


def chance_source(bot_src):
    """The hit-chance lines as the aim check extracts them (tools/bot_aggression_check.py)."""
    acc = perf.between(bot_src, "local function accuracyAt", "-- Magazines,")
    chance = perf.between(bot_src, "\tlocal chance = accuracyAt(distance)", "\tlocal hit = math.random() < chance")
    m = re.search(r"^local AIM_SETTLE_DELAY = ([\d.]+)", bot_src, flags=re.M)
    settle = float(m.group(1)) if m else 0.0
    return (f"local AIM_SETTLE_DELAY = {settle}\n" + perf.luau_to_lua(acc)
            + "\nreturn function(bot, now, distance, targetRoot)\n" + perf.luau_to_lua(chance) + "\treturn chance\nend\n")


class Runtime:
    """One Lua state: the mock world plus one BotService source. `aim_src` is the source whose hit-chance
    lines set the expectation for every shot (the BEFORE revision's, normally)."""

    def __init__(self, root, bot_src, aim_src):
        self.errors = []
        lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua = lua
        lua.execute(perf.PRELUDE + EXTRA_PRELUDE)

        def read_source(path):
            try:
                return perf.luau_to_lua(read_tree(root, path))
            except FileNotFoundError:
                return None

        g = lua.globals()
        g.HANDLE = lua.execute(LOADER)(read_source)
        lua.execute(WORLD)
        g.WeaponData = g.require(self._handle(lua, "ReplicatedStorage/Shared", "WeaponData"))
        g.MatchConfig = g.require(self._handle(lua, "ReplicatedStorage/Shared", "MatchConfig"))
        # The aim expectation, from `aim_src`.
        g.CHANCE_AT = lua.execute(chance_source(aim_src))
        g.BOT_TABLE = lua.execute(bot_table_source(bot_src))
        # The module itself, with its locals the sim needs exported.
        src = perf.luau_to_lua(bot_src)
        assert src.rstrip().endswith("return BotService")
        src = src.rstrip()[: -len("return BotService")] + (
            "\n_ENV.updateBot, _ENV.refreshCombatants, _ENV.STATS = updateBot, refreshCombatants, STATS\n"
            "return BotService\n")
        handle = self._handle(lua, "ServerScriptService/Modules", "BotService")
        loader = lua.eval("function(src, h) local env = setmetatable({ script = h }, { __index = _G }); "
                          "local r = assert(load(src, 'BotService', 't', env))(); "
                          "updateBot, refreshCombatants, STATS = env.updateBot, env.refreshCombatants, env.STATS; return r end")
        g.BotService = loader(src, handle)
        lua.execute(SCENARIOS)
        self.g = g

    @staticmethod
    def _handle(lua, d, name):
        return lua.globals().HANDLE(d, name)

    def run(self, scenario, seed, *args):
        g = self.g
        g.SIM.reset(seed)
        # STATS is cumulative; snapshot and difference for per-run numbers.
        before = {k: g.STATS[k] for k in g.STATS.keys() if isinstance(g.STATS[k], (int, float))}
        result = g.SCEN[scenario](*args)
        errors = list(g.SIM.errors.values())
        if errors:
            raise RuntimeError(f"{scenario}: bot update failed: {errors[0]}")
        out = self._py(result)
        out["_stats"] = {k: g.STATS[k] - before.get(k, 0) for k in g.STATS.keys() if isinstance(g.STATS[k], (int, float))}
        out["_ledger"] = (float(g.SIM.expected), float(g.SIM.expectedVar), int(g.SIM.hits), int(g.SIM.hitscanShots))
        g.SIM.expected, g.SIM.expectedVar, g.SIM.hits, g.SIM.hitscanShots = 0, 0, 0, 0
        return out

    def _py(self, value):
        if hasattr(value, "keys"):
            return {k: self._py(value[k]) for k in value.keys()}
        return value


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


ARCHES = ("Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor")
CLASS_GUNS = [("shotgun", "TralalaShotgun"), ("smg", "RotSMG"), ("rifle", "CrocodiloRifle"), ("dmr", "GrassToucherDMR"),
              ("sniper", "LarilaSniper"), ("lmg", "CameloLMG"), ("launcher", "CappuccinaLauncher")]


def measure(rt, runs, verbose):
    """Every scenario on one runtime. Returns the numbers the checks read."""
    out = {"ledger": [0.0, 0.0, 0, 0], "runs": runs}

    def ledger(r):
        e, v, h, n = r["_ledger"]
        out["ledger"][0] += e
        out["ledger"][1] += v
        out["ledger"][2] += h
        out["ledger"][3] += n

    # DUELS: each archetype against a Rusher, rifles.
    duels = {}
    for arch in ARCHES:
        rows = []
        for seed in range(runs):
            r = rt.run("duel", seed * 7 + 1, arch, "CrocodiloRifle", "Rusher", "CrocodiloRifle", 40.0)
            ledger(r)
            rows.append(r["a"])
        ft = max(1, sum(x["fightThinks"] for x in rows))
        duels[arch] = {
            "dist": mean(x["avgShotDistance"] for x in rows if x["avgShotDistance"] > 0),
            "cover": sum(x["coverThinks"] for x in rows) / ft,
            "hide": sum(x["hideThinks"] for x in rows) / ft,
            "retreat": sum(x["retreatThinks"] for x in rows) / ft,
            "push": sum(x["pushThinks"] for x in rows) / ft,
            "firstShot": mean(x["firstShotAt"] - x["firstFightAt"] for x in rows if x["firstShotAt"] > 0 and x["firstFightAt"] > 0),
            "won": mean(1 if x["kills"] > 0 else 0 for x in rows),
            "shots": sum(x["shots"] for x in rows),
        }
    out["duels"] = duels

    # CLASSES: a Rusher with each gun class: shot distance and rounds a second.
    classes = {}
    for style, gun in CLASS_GUNS:
        rows = [rt.run("duel", seed * 11 + 3, "Rusher", gun, "Anchor", "CrocodiloRifle", 30.0) for seed in range(max(2, runs // 2))]
        for r in rows:
            ledger(r)
        tp = [rt.run("throughput", seed * 5 + 2, "Rusher", gun, 40.0) for seed in range(max(2, runs // 2))]
        classes[style] = {
            "dist": mean(r["a"]["avgShotDistance"] for r in rows if r["a"]["avgShotDistance"] > 0),
            "perSecond": mean(t["perSecond"] for t in tp),
            "tpDist": mean(t["avgShotDistance"] for t in tp if t["avgShotDistance"] > 0),
        }
    out["classes"] = classes

    # FLANK
    out["flank"] = {arch: mean(rt.run("flank", s * 3 + 1, arch, "CrocodiloRifle", 20.0)["maxFlank"] for s in range(runs))
                    for arch in ("Flanker", "Rusher", "Anchor")}
    # THIRD PARTY
    third = {}
    for arch in ("Opportunist", "Rusher"):
        rows = [rt.run("thirdParty", s * 13 + 5, arch, 25.0) for s in range(runs)]
        third[arch] = {"firstShot": mean(r["firstShotAt"] - r["firstFightAt"] for r in rows if r["firstShotAt"] > 0 and r["firstFightAt"] > 0),
                       "neverShot": sum(1 for r in rows if r["firstShotAt"] < 0),
                       "targetHealth": mean(r["firstTargetHealth"] for r in rows if r["firstTargetHealth"] >= 0),
                       "thirdThinks": sum(r["thirdThinks"] for r in rows)}
    out["third"] = third
    # AVOID
    out["avoid"] = {arch: sum(rt.run("avoid", s * 17 + 7, arch, "CrocodiloRifle", 15.0)["shots"] for s in range(runs))
                    for arch in ("Survivor", "Rusher")}
    # REPOSITION (sniper): deliberate repositions (STATS.repositions) per shot; everyone strafes, so
    # "moved between shots" alone says nothing.
    repo = {}
    for arch in ("Marksman", "Rusher"):
        rows = [rt.run("flank", s * 19 + 11, arch, "LarilaSniper", 30.0) for s in range(runs)]
        shots = sum(r["shots"] for r in rows)
        repo[arch] = {"moved": sum(r["movedBetween"] for r in rows) / max(1, shots), "shots": shots,
                      "repositions": sum(r["_stats"].get("repositions", 0) for r in rows) / max(1, shots),
                      "dist": mean(r["avgShotDistance"] for r in rows if r["avgShotDistance"] > 0)}
    out["reposition"] = repo
    # PEEK
    peek = {}
    for arch in ("Anchor", "Rusher"):
        rows = [rt.run("peek", s * 23 + 13, arch, "Rusher", 40.0) for s in range(runs)]
        for r in rows:
            ledger(r)
        ft = max(1, sum(r["a"]["fightThinks"] for r in rows))
        peek[arch] = {"hide": sum(r["a"]["hideThinks"] for r in rows) / ft, "cover": sum(r["a"]["coverThinks"] for r in rows) / ft,
                      "peeks": sum(r["_stats"].get("peeks", 0) for r in rows)}
    out["peek"] = peek
    # SKIRMISH
    rows = [rt.run("skirmish", s * 29 + 17, 60.0) for s in range(runs)]
    for r in rows:
        ledger(r)
    out["skirmish"] = {k: sum(r[k] for r in rows) for k in
                       ("kills", "frags", "fragFriendly", "smokes", "builds", "buildFriendly", "sharedThinks", "fightingThinks")}
    out["skirmish"]["focusFire"] = sum(r["_stats"].get("focusFire", 0) for r in rows)
    out["skirmish"]["flankMoves"] = sum(r["_stats"].get("flankMoves", 0) for r in rows)

    # FORTIFY (STATS is cumulative across a runtime: the per-run deltas are in _stats)
    def fortify(arch, friendly):
        r = rt.run("fortify", 31, arch, friendly, 20.0)
        r["fortify"] = r["_stats"].get("buildsFortify", 0)
        r["refusedFriendly"] = r["_stats"].get("buildsRefusedFriendly", 0)
        return r
    out["fortify"] = {"clear": fortify("Anchor", False), "friendly": fortify("Anchor", True), "rusher": fortify("Rusher", False)}
    # THROWABLES
    out["sticky"] = rt.run("sticky", 37, "Rusher", "CrocodiloRifle", 12.0)
    out["bunched"] = {
        "rifle": rt.run("bunched", 41, "Rusher", "CrocodiloRifle", 15.0),
        "launcher": rt.run("bunched", 41, "Rusher", "CappuccinaLauncher", 15.0),
        "lmg": rt.run("bunched", 41, "Rusher", "CameloLMG", 15.0),
        "marksman": rt.run("bunched", 41, "Marksman", "CrocodiloRifle", 15.0),
    }
    out["flush"] = {
        "shotgun": rt.run("flush", 43, "Rusher", "TralalaShotgun", 15.0),
        "rifle": rt.run("flush", 43, "Rusher", "CrocodiloRifle", 15.0),
    }
    # FLEE
    flee = {}
    for arch in ("Survivor", "Rusher"):
        rows = [rt.run("flee", s * 43 + 19, arch, 15.0) for s in range(runs)]
        flee[arch] = {k: sum(r[k] for r in rows) for k in ("builds", "smokes")}
        flee[arch]["blocks"] = sum(r["_stats"].get("buildsBlock", 0) for r in rows)
        flee[arch]["flees"] = sum(r["_stats"].get("flees", 0) for r in rows)
    out["flee"] = flee
    return out


def checks(after, before):
    """The design, as pass/fail lines. `before` carries the stock source's throughput per class."""
    fails = []
    d = after["duels"]
    if not d["Marksman"]["dist"] > d["Rusher"]["dist"] * 1.3:
        fails.append(f"DUELS: Marksman fights at {d['Marksman']['dist']:.0f} studs, Rusher at {d['Rusher']['dist']:.0f}: want 1.3x")
    if not d["Anchor"]["cover"] > d["Rusher"]["cover"] + 0.1:
        fails.append(f"DUELS: Anchor in cover {d['Anchor']['cover']:.2f} of its fight, Rusher {d['Rusher']['cover']:.2f}: want +0.1")
    if not d["Rusher"]["push"] > d["Anchor"]["push"]:
        fails.append(f"DUELS: Rusher pushing {d['Rusher']['push']:.2f}, Anchor {d['Anchor']['push']:.2f}: the Rusher should push more")
    # The distance a class settles at (tpDist: shots at a target it can't kill, so no approach or
    # push in the average). A duel's average is mostly the walk in.
    c = after["classes"]
    order = ["shotgun", "smg", "rifle", "dmr", "sniper"]
    for a, b in zip(order, order[1:]):
        if not c[a]["tpDist"] < c[b]["tpDist"]:
            fails.append(f"CLASSES: {a} settles at {c[a]['tpDist']:.0f} studs, {b} at {c[b]['tpDist']:.0f}: want {a} closer")
    if c["shotgun"]["tpDist"] > 25:
        fails.append(f"CLASSES: shotgun settles at {c['shotgun']['tpDist']:.0f} studs, want under 25")
    if c["sniper"]["tpDist"] < 70:
        fails.append(f"CLASSES: sniper settles at {c['sniper']['tpDist']:.0f} studs, want over 70")
    for style, row in c.items():
        b = before["classes"][style]["perSecond"]
        if b > 0 and not (0.8 <= row["perSecond"] / b <= 1.2):
            fails.append(f"CLASSES: {style} fires {row['perSecond']:.2f} rounds/s against the stock {b:.2f}: rounds a minute moved "
                         f"{row['perSecond'] / b:.2f}x, want within 20%")
    f = after["flank"]
    if not (f["Flanker"] > 40 and f["Flanker"] > f["Rusher"] + 20):
        fails.append(f"FLANK: Flanker works round {f['Flanker']:.0f} degrees, Rusher {f['Rusher']:.0f}: want > 40 and +20")
    t = after["third"]
    if not (t["Opportunist"]["firstShot"] > t["Rusher"]["firstShot"] + 2):
        fails.append(f"THIRD PARTY: Opportunist fires {t['Opportunist']['firstShot']:.1f} s into the fight, Rusher {t['Rusher']['firstShot']:.1f}: want 2 s later")
    if not (t["Opportunist"]["targetHealth"] < t["Rusher"]["targetHealth"]):
        fails.append(f"THIRD PARTY: Opportunist's first target was at {t['Opportunist']['targetHealth']:.0f} hp, Rusher's at {t['Rusher']['targetHealth']:.0f}: it should wait for the weaker moment")
    if not t["Opportunist"]["thirdThinks"] > 0:
        fails.append("THIRD PARTY: the Opportunist never held back")
    a = after["avoid"]
    if a["Survivor"] != 0 or a["Rusher"] == 0:
        fails.append(f"AVOID: Survivor fired {a['Survivor']} shots at a passive target 85 studs off (want 0), Rusher {a['Rusher']} (want > 0)")
    r = after["reposition"]
    if not (r["Marksman"]["repositions"] > 0.5 and r["Rusher"]["repositions"] < 0.1):
        fails.append(f"REPOSITION: sniper Marksman repositioned {r['Marksman']['repositions']:.2f} times a shot (want > 0.5), "
                     f"sniper Rusher {r['Rusher']['repositions']:.2f} (want < 0.1)")
    p = after["peek"]
    if not (p["Anchor"]["peeks"] >= 3 and p["Rusher"]["peeks"] == 0 and p["Rusher"]["hide"] == 0):
        fails.append(f"PEEK: Anchor peeked {p['Anchor']['peeks']} times (want >= 3), Rusher {p['Rusher']['peeks']} (want 0)")
    s = after["skirmish"]
    if s["fragFriendly"]:
        fails.append(f"SKIRMISH: {s['fragFriendly']} frag(s) thrown with a teammate in the blast")
    if s["buildFriendly"]:
        fails.append(f"SKIRMISH: {s['buildFriendly']} wall(s) built on a teammate")
    if s["focusFire"] == 0:
        fails.append("SKIRMISH: nobody ever pulled a teammate's target closer (focusFire 0)")
    if s["kills"] == 0:
        fails.append("SKIRMISH: nobody died in a 3v3")
    fo = after["fortify"]
    if fo["clear"]["fortify"] < 1 or fo["clear"]["objective"] != 1:
        fails.append(f"FORTIFY: Anchor holding the hill built {fo['clear']['fortify']} fortify wall(s), objective {fo['clear']['objective']}: want >= 1 while holding")
    if fo["friendly"]["friendlyBuilds"] or fo["friendly"]["builds"]:
        fails.append(f"FORTIFY: {fo['friendly']['builds']} wall(s) built with a teammate standing on the site")
    if fo["rusher"]["fortify"] or not fo["rusher"]["keptRole"]:
        fails.append(f"FORTIFY: a Rusher fortified the hill {fo['rusher']['fortify']} time(s) (kept its role: {fo['rusher']['keptRole']})")
    if after["sticky"]["sticky"] < 1:
        fails.append("THROWABLES: no sticky thrown at a target in a vehicle")
    b = after["bunched"]
    if b["rifle"]["frags"] < 1 or b["launcher"]["frags"] or b["lmg"]["frags"]:
        fails.append(f"THROWABLES: frags at two bunched targets: rifle {b['rifle']['frags']} (want >= 1), launcher {b['launcher']['frags']}, LMG {b['lmg']['frags']} (want 0)")
    if b["rifle"]["frags"] and b["rifle"]["minDistance"] < 14:
        fails.append(f"THROWABLES: a frag thrown from {b['rifle']['minDistance']:.0f} studs (point blank)")
    if b["rifle"]["cooked"] or not (b["marksman"]["frags"] == 0):
        fails.append(f"THROWABLES: Rusher cooked {b['rifle']['cooked']} frag(s) (want 0); Marksman threw {b['marksman']['frags']} at two (wants three)")
    fl = after["flush"]
    if fl["shotgun"]["frags"] < 1:
        fails.append(f"THROWABLES: a shotgun facing a target behind a barricade threw {fl['shotgun']['frags']} frags, want >= 1 (fragToFlush)")
    fe = after["flee"]
    if fe["Survivor"]["blocks"] < 1 or fe["Survivor"]["smokes"] < 1 or fe["Rusher"]["blocks"]:
        fails.append(f"FLEE: Survivor blocks {fe['Survivor']['blocks']} smokes {fe['Survivor']['smokes']} (want >= 1 each), Rusher blocks {fe['Rusher']['blocks']} (want 0)")
    e, v, h, n = after["ledger"]
    z = (h - e) / math.sqrt(max(v, 1e-9))
    if n < 120 * after["runs"]:
        fails.append(f"AIM: only {n} hitscan shots rolled, too few to judge the hit rate")
    if abs(z) > 3.5:
        fails.append(f"AIM: {h} hits of {n} shots against {e:.0f} expected from the BEFORE hit-chance lines (z = {z:+.1f}): the hit rate moved")
    return fails


def report(label, m):
    print(f"--- {label}")
    print("  DUELS vs a Rusher (rifles): shot distance / in cover / hidden / retreating / pushing / first shot / won")
    for arch, r in m["duels"].items():
        print(f"    {arch:12} {r['dist']:5.0f} studs  cover {r['cover']:.2f}  hide {r['hide']:.2f}  retreat {r['retreat']:.2f}  "
              f"push {r['push']:.2f}  first shot {r['firstShot']:.2f} s  won {r['won']:.2f}  ({r['shots']} shots)")
    print("  CLASSES (Rusher): shot distance in a duel / rounds a second at an immortal target (and its distance)")
    for style, r in m["classes"].items():
        print(f"    {style:9} {r['dist']:5.0f} studs   {r['perSecond']:.2f} rounds/s at {r['tpDist']:.0f}")
    print("  FLANK max angle worked round a passive target in 20 s: " + ", ".join(f"{k} {v:.0f}" for k, v in m["flank"].items()))
    t = m["third"]
    print("  THIRD PARTY first shot after the fight came into view: " + ", ".join(
        f"{k} {v['firstShot']:.1f} s (target at {v['targetHealth']:.0f} hp, held {v['thirdThinks']} thinks)" for k, v in t.items()))
    print("  AVOID shots at a passive target 85 studs off: " + ", ".join(f"{k} {v}" for k, v in m["avoid"].items()))
    print("  REPOSITION (sniper) deliberate repositions a shot (share of shots from a new spot): " + ", ".join(
        f"{k} {v['repositions']:.2f} ({v['moved']:.2f}) of {v['shots']} at {v['dist']:.0f} studs" for k, v in m["reposition"].items()))
    print("  PEEK share of fight hidden / in cover: " + ", ".join(f"{k} {v['hide']:.2f} / {v['cover']:.2f} ({v['peeks']} peeks)" for k, v in m["peek"].items()))
    s = m["skirmish"]
    print(f"  SKIRMISH 3v3 TDM: kills {s['kills']}, frags {s['frags']} (on a teammate {s['fragFriendly']}), smokes {s['smokes']}, "
          f"walls {s['builds']} (on a teammate {s['buildFriendly']}), thinks two teammates shared a target {s['sharedThinks']}/{s['fightingThinks']}, "
          f"focusFire {s['focusFire']}, flank moves {s['flankMoves']}")
    fo = m["fortify"]
    print(f"  FORTIFY (KOTH hold): Anchor walls {fo['clear']['fortify']}; with a teammate on the site walls {fo['friendly']['builds']} "
          f"(refused {fo['friendly']['refusedFriendly']}); Rusher walls {fo['rusher']['fortify']}")
    b = m["bunched"]
    print(f"  THROWABLES: sticky at a seated target {m['sticky']['sticky']}; frags at two bunched: rifle {b['rifle']['frags']} "
          f"(nearest {b['rifle']['minDistance']:.0f} studs, cooked {b['rifle']['cooked']}), launcher {b['launcher']['frags']}, LMG {b['lmg']['frags']}, "
          f"Marksman {b['marksman']['frags']}; flush through a barricade: shotgun {m['flush']['shotgun']['frags']}, rifle {m['flush']['rifle']['frags']} "
          f"(rifle shot the wall {m['flush']['rifle']['coverShots']} times)")
    fe = m["flee"]
    print("  FLEE unarmed under fire: " + ", ".join(f"{k} walls {v['blocks']} smokes {v['smokes']} flees {v['flees']}" for k, v in fe.items()))
    e, v, h, n = m["ledger"]
    z = (h - e) / math.sqrt(max(v, 1e-9))
    print(f"  AIM: {h} hits of {n} hitscan shots, {e:.0f} expected from the BEFORE hit-chance lines (z = {z:+.1f})")


PLANTS = [
    (BOTSERVICE, "\tchance *= 0.9 + 0.15 * settle\n", "\tchance *= 1.0 + 0.15 * settle\n", "aim: hit chance up a tenth"),
    (BOTSERVICE, "\tlocal preferred = dials.range\n", "\tlocal preferred = 55\n", "range: every gun and personality at 55 studs"),
    (BOTSERVICE, "\t\t-- Nor onto a teammate (Oliver: \"never throw frags at teammates' positions\").\n\t\tfor _, entry in ipairs(combatantList) do\n"
     "\t\t\tif entry.token ~= bot and entry.humanoid.Health > 0 and not hostile(bot, entry.token)\n"
     "\t\t\t\tand (entry.position - point).Magnitude < blast + 3 then\n\t\t\t\tSTATS.throwsRefusedFriendly += 1\n\t\t\t\treturn false\n\t\t\tend\n\t\tend\n",
     "", "throwables: a frag may land on a teammate"),
    (BOTSERVICE, "\t\t\tand flatDistance(entry.position, centre) < 9 then\n\t\t\tSTATS.buildsRefusedFriendly += 1\n\t\t\treturn false\n",
     "\t\t\tand flatDistance(entry.position, centre) < 9 then\n\t\t\tSTATS.buildsRefusedFriendly += 1\n",
     "defenses: a wall may go up on a teammate"),
    (BOTSERVICE, 'lmg          = { range = 60, minRange = 10, peek = "suppress", burst = { 6, 10 }, restScale = 2.75',
     'lmg          = { range = 60, minRange = 10, peek = "suppress", burst = { 6, 10 }, restScale = 1',
     "lethality: an LMG's long burst without the longer rest (more rounds a minute)"),
    (BOTSERVICE, "\tif dials.thirdParty and reacted and targetHumanoid and now - bot.lastHurtAt >= THREAT_WINDOW\n",
     "\tif false and reacted and targetHumanoid and now - bot.lastHurtAt >= THREAT_WINDOW\n", "third party: the Opportunist never waits"),
    (BOTSERVICE, "\tif candidate and ARCH.dialsOf(bot).avoidUnforced then\n", "\tif false then\n", "avoid: the Survivor fights anyone it sees"),
    (BOTSERVICE, "\tlocal overstayed = dials.repositionAfterShots > 0 and", "\tlocal overstayed = false and",
     "reposition: the sniper never moves after a shot"),
    (BOTSERVICE, "\t\tlocal exposed = not (peek and peek.exposed)\n", "\t\tlocal exposed = false\n",
     "peek: a peeker never steps out"),
    (BOTSERVICE, "\t\tif option.flank then\n\t\t\tscore -= 0.8\n", "\t\tif option.flank then\n\t\t\tscore += 0.8\n",
     "flank: the arc points are the worst options"),
    (BOTSERVICE, "\tif wantsCover and bot.coverRoll and bot.coverRoll > dials.coverUse and bot.reloadUntil == nil then\n",
     "\tif false then\n", "cover: coverUse ignored, everyone takes cover like an Anchor"),
]


def main():
    args = sys.argv[1:]
    root = args[0] if args and not args[0].startswith("--") else "."
    runs = 4 if "--quick" in args else 8
    rev = args[args.index("--before") + 1] if "--before" in args else None
    if rev is None:
        log = subprocess.run(["git", "-C", root, "log", "--format=%H", "--diff-filter=A", "--", "tools/bot_archetype_sim.py"],
                             capture_output=True, text=True).stdout.split()
        rev = (log[-1] + "~1") if log else "HEAD"
    tree = read_tree(root, BOTSERVICE)
    before_src = perf.read_rev(root, rev, BOTSERVICE)

    before_rt = Runtime(root, before_src, before_src)
    before = measure(before_rt, runs, False)

    if "--plant" in args:
        caught = 0
        for path, old, new, what in PLANTS:
            assert tree.count(old) == 1, f"plant text not found once: {old!r}"
            planted = tree.replace(old, new)
            try:
                fails = checks(measure(Runtime(root, planted, before_src), runs, False), before)
            except Exception as err:  # a plant that breaks the harness counts as caught, loudly
                fails = [f"harness error: {err}"]
            caught += bool(fails)
            print(f"plant [{'CAUGHT' if fails else 'MISSED'}] {what}: {fails[0] if fails else 'no check failed'}")
        print(f"bot_archetype_sim plants: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)

    report(f"before ({rev})", before)
    after = measure(Runtime(root, tree, before_src), runs, True)
    report("after (working tree)", after)
    fails = checks(after, before)
    for f in fails:
        print("FAIL", f)
    print(f"bot_archetype_sim: {len(fails)} failures ({runs} runs a scenario)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
