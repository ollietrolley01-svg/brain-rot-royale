"""Companion ability check (OLIVER_LIST A5), without Studio.

Runs the REAL ReplicatedStorage/Shared/BrainrotData.lua and the REAL
ServerScriptService/Modules/CompanionService.lua in a Lua interpreter (lupa), with Roblox mocked, and
checks:

  data       every brainrot resolves to a valid move and (bar the blast ones) a valid style that can go
             on that move; no venom-boon brainrot has a DoT style; every name in AbilityStyleOf exists
  buff kept  with the styles taken away, every brainrot's numbers equal the committed tree's (git HEAD
             or --base REV): the 2026-09-22 companion buff is not undone
  side-grade each style's damage a second (counting its DoT) stays within 0.85-1.2 of the plain move
  variety    distinct parameter sets across the 126, against the plain six-moves baseline
  0 HP       a companion shot to 0 health cannot use its move: plainly, when the attacker's hit
             confirm throws, and when the boon's Clear throws inside down(); nor can a bot's, on the
             think loop
  styles     a slow, a DoT and a leech land on an enemy the move hurt, and never on a teammate it did
             not; a Forking Zap jumps on to a second enemy at 60%
  one-shot   every brainrot at max level and max stars, with its style, venom or blast: one use takes
             no more than BrainrotData.MaxUseDamage[rarity] off a target (hits and DoT together, after
             CombatDamageScale) and never takes a full-health player to 0, with or without a full
             shield; a Secret is never clipped; three uses still kill for every Epic and rarer (two before
             TTK +25%, 2026-09-25)

    python3 tools/companion_ability_check.py .            the checks
    python3 tools/companion_ability_check.py . --plant    planted faults; every one must be caught

Needs `pip install lupa`. Luau compound assignments are rewritten to plain Lua before loading.
"""

import os
import re
import subprocess
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("companion_ability_check: needs lupa (pip install lupa)")

DATA = "ReplicatedStorage/Shared/BrainrotData.lua"
SERVICE = "ServerScriptService/Modules/CompanionService.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()


def git_show(root, rev, rel):
    return subprocess.run(["git", "-C", root, "show", f"{rev}:{rel}"], capture_output=True, text=True, check=True).stdout


PRELUDE = r"""
local AnyMT = {}
local function Any() return setmetatable({}, AnyMT) end
AnyMT.__index = function(t, k) local v = Any(); rawset(t, k, v); return v end
AnyMT.__call = function() return Any() end
AnyMT.__mul = function() return Any() end
AnyMT.__add = function() return Any() end
AnyMT.__sub = function() return Any() end
AnyMT.__div = function() return Any() end
AnyMT.__unm = function() return Any() end
AnyMT.__lt = function() return false end
AnyMT.__le = function() return false end
_G.Any = Any

Color3 = { fromRGB = function(r, g, b) return { r, g, b } end, new = function(r, g, b) return { r, g, b } end }
Enum = Any()
math.clamp = function(x, a, b) if x < a then return a elseif x > b then return b end return x end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
table.find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
"""

LOAD_DATA = r"""
local src = ...
return load(src, "BrainrotData")()
"""

# Everything CompanionService touches, mocked just far enough to run its real logic.
SERVICE_HARNESS = r"""
local dataSrc, serviceSrc = ...
local log = { attacks = {}, downs = {}, hits = {}, slows = {}, venoms = {}, warns = {}, deals = {} }
_G.log = log
local now = 100
os.clock = function() return now end
local queue = {}
task = {
    delay = function(t, fn, ...) table.insert(queue, { fn = fn, args = { ... } }) end,
    spawn = function(fn, ...) fn(...) end,
    wait = function() end,
}
local function flush()
    local guard = 0
    while #queue > 0 do
        local job = table.remove(queue, 1)
        job.fn(table.unpack(job.args))
        guard = guard + 1
        assert(guard < 1000, "task queue runaway")
    end
end
warn = function(...) table.insert(log.warns, table.concat({ ... }, " ")) end

local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); return Vector3.new(v.X / m, v.Y / m, v.Z / m) end
    return V[k]
end
local function isVec(v) return type(v) == "table" and rawget(v, "__vec") ~= nil end
V.__add = function(a, b) if not (isVec(a) and isVec(b)) then return Any() end return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) if not (isVec(a) and isVec(b)) then return Any() end return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
    return Any()
end
V.__div = function(a, b) return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __vec = true }, V) end }
Vector3.yAxis = Vector3.new(0, 1, 0)
CFrame = { new = function() return Any() end, Angles = function() return Any() end }
UDim2 = { fromScale = function() return Any() end }
UDim = { new = function() return Any() end }
Instance = { new = function() return Any() end }
RaycastParams = { new = function() return Any() end }
typeof = function(x)
    if type(x) == "table" then
        if rawget(x, "__vec") then return "Vector3" end
        return "Instance"
    end
    return type(x)
end

local function signal()
    local s = { fns = {} }
    function s:Connect(fn) table.insert(self.fns, fn); return { Disconnect = function() end } end
    function s:Fire(...) for _, fn in ipairs(self.fns) do fn(...) end end
    return s
end

-- Combatants: players and bots as plain tables.
local all = {}
_G.combatants = all
local function makeCombatant(name, isPlayer, x, team)
    local root = { Position = Vector3.new(x, 0, 0), AssemblyLinearVelocity = Vector3.new(0, 0, 0), CFrame = Any() }
    local humanoid = { Health = 100, MaxHealth = 100, Died = signal() }
    local character = { Parent = true }
    function character:FindFirstChild(n) if n == "HumanoidRootPart" then return root end return nil end
    function character:FindFirstChildOfClass(n) if n == "Humanoid" then return humanoid end return nil end
    function character:WaitForChild(n) return self:FindFirstChild(n) end
    local token = { Name = name, UserId = #all + 1, isPlayer = isPlayer, isBot = not isPlayer, team = team,
        Character = character, character = character, root = root, humanoid = humanoid,
        CharacterAdded = signal(), CharacterRemoving = signal(), attrs = {} }
    function token:SetAttribute(k, v) self.attrs[k] = v end
    function token:IsA(c) return c == "Player" and self.isPlayer end
    table.insert(all, token)
    return token
end
_G.makeCombatant = makeCombatant

local throwConfirm, throwClear = false, false
_G.setThrow = function(confirm, clear) throwConfirm, throwClear = confirm, clear end

local mods = {}
mods.Combatants = {
    IsPlayer = function(t) return type(t) == "table" and t.isPlayer == true end,
    IsBot = function(t) return type(t) == "table" and t.isBot == true end,
    GetName = function(t) return t and t.Name or "?" end,
    GetRoot = function(t) return t and t.root end,
    GetCharacter = function(t) return t and t.Character end,
    IsAlive = function(t) return t ~= nil and t.humanoid.Health > 0 end,
    Exists = function() return true end,
    All = function()
        local map = {}
        for _, t in ipairs(all) do map[t.Character] = t end
        return map
    end,
}
mods.MatchConfig = { CombatDamageScale = 0.736, MaxShield = 100 } -- as MatchConfig (TTK +25%, 2026-09-25)
mods.CombatService = {
    IsEnabled = function() return true end,
    ConfirmHit = function() if throwConfirm then error("confirm send failed") end end,
    -- As the real one: the mode's veto, then CombatDamageScale, then the shield soaks first.
    DealDamage = function(attacker, token, amount)
        -- A teammate is protected, as the mode's veto does: 0 dealt.
        if token.team ~= nil and token.team == attacker.team then return 0 end
        if token.humanoid.Health <= 0 or amount <= 0 then return 0 end
        amount = amount * mods.MatchConfig.CombatDamageScale
        local absorbed = math.min(token.shield or 0, amount)
        token.shield = (token.shield or 0) - absorbed
        amount = amount - absorbed
        local dealt = absorbed + math.min(amount, token.humanoid.Health)
        token.humanoid.Health = math.max(0, token.humanoid.Health - amount)
        table.insert(log.deals, { who = token.Name, amount = amount + absorbed })
        return dealt
    end,
    InRadius = function(center, radius, attacker)
        local out = {}
        for _, t in ipairs(all) do
            if t ~= attacker and (t.root.Position - center).Magnitude <= radius then
                table.insert(out, { token = t, root = t.root })
            end
        end
        return out
    end,
}
mods.PlayerData = { Get = function(p) return p.data end }
mods.CompanionBoons = {
    Clear = function() if throwClear then error("boon clear failed") end end,
    Apply = function() end, Tick = function() end, TickVenom = function() end,
    VenomOf = function(def) return def.boon and def.boon.venom or nil end,
    -- As the real one: one slot per victim, refreshed not stacked, ticking every 0.5 s through DealDamage.
    StartVenom = function(owner, victim, venom, tag)
        table.insert(log.venoms, { who = victim.Name, damage = venom.damage, duration = venom.duration })
        local ticks = math.max(1, math.floor(venom.duration / 0.5))
        _G.venomOn[victim] = { owner = owner, perTick = venom.damage / ticks, ticksLeft = ticks }
    end,
}
_G.venomOn = {}
_G.tickVenom = function(seconds)
    for _ = 1, math.floor(seconds / 0.5 + 0.5) do
        for victim, dot in pairs(_G.venomOn) do
            mods.CombatService.DealDamage(dot.owner, victim, dot.perTick)
            dot.ticksLeft = dot.ticksLeft - 1
            if dot.ticksLeft <= 0 or victim.humanoid.Health <= 0 then _G.venomOn[victim] = nil end
        end
    end
end
-- Explode as far as a companion blast needs it: every combatant in the radius but the owner takes
-- at most the full damage once (the centre's; falloff only lowers it).
mods.ProjectileService = { Explode = function(b)
    for _, t in ipairs(all) do
        if t ~= b.owner and (t.root.Position - b.position).Magnitude <= b.radius then
            mods.CombatService.DealDamage(b.owner, t, b.damage)
        end
    end
end }
mods.MatchService = { SetStatusSpeed = function(token, key, factor, duration) table.insert(log.slows, { who = token.Name, factor = factor, duration = duration }) end }
mods.SafeValue = { Vector3 = function(v) return type(v) == "table" and rawget(v, "__vec") ~= nil end }
mods.Rarity = { IsAtLeast = function() return false end, Color = function() return Any() end }
mods.CompanionAnimations = { Windup = 0.3 }
mods.BrainrotModels = {
    Build = function()
        local model = Any()
        local root = { Position = Vector3.new(0, 0, 0), CFrame = Any() }
        rawset(model, "PrimaryPart", root)
        rawset(model, "Parent", true)
        rawset(model, "GetDescendants", function() return {} end)
        rawset(model, "FindFirstChild", function() return nil end)
        rawset(model, "Destroy", function(self) rawset(self, "Parent", nil) end)
        rawset(model, "SetAttribute", function() end)
        return model
    end,
    Metrics = function() return { top = 1 } end,
}
mods.Remotes = { Event = function(name)
    return { FireAllClients = function(_, payload)
        if name == "CompanionAttack" then table.insert(log.attacks, payload)
        elseif name == "CompanionDown" then table.insert(log.downs, payload)
        elseif name == "CompanionHit" then table.insert(log.hits, payload) end
    end, OnServerEvent = signal() }
end }

local container
function container(name)
    local c = { Name = name }
    function c:WaitForChild(n) return container(n) end
    function c:FindFirstChild(n) if n == "ModeTeams" or n == "Loot" then return nil end return container(n) end
    return c
end
local RealBrainrotData = load(dataSrc, "BrainrotData")()
mods.BrainrotData = RealBrainrotData
_G.BrainrotData = RealBrainrotData
local realRequire = require
require = function(m) local r = mods[m.Name]; assert(r ~= nil, "no mock for " .. tostring(m.Name)); return r end

local heartbeat = signal()
local Players = { PlayerAdded = signal(), PlayerRemoving = signal(), GetPlayers = function()
    local out = {}
    for _, t in ipairs(all) do if t.isPlayer then table.insert(out, t) end end
    return out
end }
game = { GetService = function(_, n)
    if n == "Players" then return Players end
    if n == "RunService" then return { Heartbeat = heartbeat } end
    if n == "CollectionService" then return { GetTagged = function() return {} end } end
    return container(n)
end }
workspace = { Raycast = function() return nil end, FindFirstChild = function() return nil end, GetServerTimeNow = function() return now end }
script = { Parent = container("Modules") }

local CompanionService = load(serviceSrc, "CompanionService")()
CompanionService.IsFighting = function() return true end
_G.CS = CompanionService
_G.flush = flush
_G.tick = function(dt) now = now + dt; heartbeat:Fire(dt); flush() end
_G.advance = function(dt) now = now + dt end
CompanionService.Start()
return CompanionService
"""


def run_data_checks(root, data_src, base_src, fails, facts):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    loader = lua.eval("function(src) return load(src, 'BrainrotData')() end")
    data = loader(luau_to_lua(data_src))
    base = loader(luau_to_lua(base_src))

    attacks = set(data.Attacks.keys())
    styles = data.AbilityStyles
    style_of = data.AbilityStyleOf
    names = set()
    for i in range(1, len(data.Types) + 1):
        names.add(data.Types[i].name)
    for name in style_of.keys():
        if name not in names:
            fails.append(f"data: AbilityStyleOf names '{name}', which is not a brainrot")
        if style_of[name] not in styles:
            fails.append(f"data: {name} has style '{style_of[name]}', which is not in AbilityStyles")

    lua.execute("function _strip(d) d.AbilityStyleOf = {} end")
    keys = ["kind", "damage", "cooldown", "range", "splash", "health", "dps"]
    plain_sets, styled_sets, pairs_seen = set(), set(), set()
    styled_rows = []
    for i in range(1, len(data.Types) + 1):
        d = data.Types[i]
        name, kind = d.name, d.attack or "Spit"
        if kind not in attacks:
            fails.append(f"data: {name} has move {kind}, not in Attacks")
            continue
        s = data.Stats(d, 1, 0)
        style, style_name = data.StyleOf(d)
        is_blast = d.blast is True
        venom = d.boon is not None and d.boon.venom is not None
        if is_blast and style_name is not None:
            fails.append(f"data: blast brainrot {name} has a style (Explode carries none)")
        if not is_blast and style_name is None:
            fails.append(f"data: {name} resolves to no valid style (missing, misspelt, or not allowed on {kind})")
        if venom and s.dot is not None:
            fails.append(f"data: {name} has a venom boon AND a DoT style (one venom slot per victim)")
        if not (s.damage > 0 and s.cooldown > 0 and s.range > 0 and s.health > 0):
            fails.append(f"data: {name} has a non-positive number")
        if s.damage > data.MaxAbilityDamage:
            fails.append(f"data: {name} damage {s.damage} over the cap")
        styled_sets.add(tuple(s[k] for k in keys) + (s.style, s.slow, s.slowTime, s.dot, s.dotTime, s.leech, s.forks))
        pairs_seen.add((kind, s.style))
        styled_rows.append((name, d, s))

    # The buff kept: styles stripped, every number equals the base tree's.
    lua.globals()._strip(data)
    # The base tree may itself carry styles (once this lands, HEAD does): compare plain against plain.
    if base.AbilityStyleOf is not None:
        lua.globals()._strip(base)
    for name, d, s in styled_rows:
        plain = data.Stats(d, 1, 0)
        bd = None
        for j in range(1, len(base.Types) + 1):
            if base.Types[j].name == name:
                bd = base.Types[j]
        if bd is None:
            fails.append(f"buff: {name} not in the base tree")
            continue
        was = base.Stats(bd, 1, 0)
        for k in keys:
            if plain[k] != was[k]:
                fails.append(f"buff: {name} plain {k} {plain[k]} != base {was[k]}")
        plain_sets.add(tuple(was[k] for k in keys))
        # Side-grade: damage a second, DoT included, against the plain move.
        eff = s.damage * (1 + (s.dot or 0)) / s.cooldown
        ratio = eff / (plain.damage / plain.cooldown)
        if s.style is not None and not (0.85 <= ratio <= 1.2):
            fails.append(f"side-grade: {name} ({s.style}) damage a second is {ratio:.2f}x the plain move")

    base_moves = set(k for k in keys[:1])
    facts.append(f"brainrots {len(styled_rows)}; distinct (move, style) pairs {len(pairs_seen)} (was 6 moves); "
                 f"distinct level-1 parameter sets {len(styled_sets)} (plain tree: {len(plain_sets)})")
    counts = {}
    for _, _, s in styled_rows:
        counts[s.style or "(blast)"] = counts.get(s.style or "(blast)", 0) + 1
    facts.append("styles: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    if len(pairs_seen) < 30:
        fails.append(f"variety: only {len(pairs_seen)} distinct (move, style) pairs, want >= 30")
    if len(styled_sets) < len(plain_sets) * 2:
        fails.append(f"variety: {len(styled_sets)} parameter sets is not twice the plain {len(plain_sets)}")
    for style_name in styles.keys():
        if counts.get(style_name, 0) < 3:
            fails.append(f"variety: style {style_name} is on {counts.get(style_name, 0)} brainrots, want >= 3")


SCENARIOS = r"""
local CS = _G.CS
local log = _G.log
local out = {}
local function check(ok, msg) if not ok then table.insert(out, msg) end end
local BrainrotData = _G.BrainrotData

local function owned(name) return { Companion = name, Brainrots = { name }, CompanionXp = {}, Stars = {} } end
local function reset() for k in pairs(log) do log[k] = {} end end

-- One owner, one enemy 20 studs away (in every move's range), one teammate 22 away.
local owner = _G.makeCombatant("Owner", true, 0, "A")
local enemy = _G.makeCombatant("Enemy", true, 20, "B")
local mate = _G.makeCombatant("Mate", true, 22, "A")
local shooter = _G.makeCombatant("Shooter", true, -30, "B")

local function equip(name)
    owner.data = owned(name)
    CS.Refresh(owner)
    CS.ResetStats()
end

-- 1. Plain lethal hit: downed, gone, cannot use its move.
equip("Tung Tung Tung Sahur")
check(CS.UseAbility(owner, enemy.root.Position) == true, "setup: a healthy companion could not use its move")
_G.flush()
_G.advance(10)
local model = CS.ModelOf(owner)
check(model ~= nil, "setup: no companion model")
local dealt = CS.Damage(shooter, model, 99999)
check(dealt > 0, "lethal hit dealt nothing")
check(CS.ModelOf(owner) == nil, "0 HP: companion still out after a lethal hit")
reset()
check(CS.UseAbility(owner, enemy.root.Position) == false, "0 HP: downed companion used its move")
check(#log.attacks == 0, "0 HP: downed companion broadcast an attack")
CS.Refresh(owner)
check(CS.ModelOf(owner) == nil, "0 HP: a Refresh brought a downed companion back mid-match")

-- 2. The attacker's hit confirm throws on the lethal hit.
CS.ReviveAll(); CS.ResetStats(); _G.advance(10)
_G.setThrow(true, false)
pcall(CS.Damage, shooter, CS.ModelOf(owner), 99999)
_G.setThrow(false, false)
reset()
check(CS.UseAbility(owner, enemy.root.Position) == false, "0 HP (confirm threw): companion used its move")

-- 3. The boon's Clear throws inside down().
CS.ReviveAll(); CS.ResetStats(); _G.advance(10)
_G.setThrow(false, true)
pcall(CS.Damage, shooter, CS.ModelOf(owner), 99999)
_G.setThrow(false, false)
check(CS.ModelOf(owner) == nil, "0 HP (boon clear threw): companion left in the table")
reset()
check(CS.UseAbility(owner, enemy.root.Position) == false, "0 HP (boon clear threw): companion used its move")
check(#log.attacks == 0, "0 HP (boon clear threw): an attack was broadcast")

-- 4. A bot's companion at 0 HP does not fight on the think loop.
CS.ReviveAll(); CS.ResetStats()
local bot = _G.makeCombatant("Bot", false, 40, "C")
CS.AttachBot(bot, BrainrotData.Get("Tung Tung Tung Sahur"))
_G.setThrow(false, true)
pcall(CS.Damage, shooter, CS.ModelOf(bot), 99999)
_G.setThrow(false, false)
reset()
_G.tick(0.25); _G.advance(10); _G.tick(0.25)
local botAttacked = false
for _, a in ipairs(log.attacks) do if a.companion ~= nil and a.owner == nil then botAttacked = true end end
check(not botAttacked, "0 HP: a downed bot companion attacked on the think loop")
bot.humanoid.Health = 0
table.remove(_G.combatants)

-- 5. Styles land on a hurt enemy only.
local function useOn(name, target)
    CS.ReviveAll(); equip(name); _G.advance(10)
    target.humanoid.Health = 100
    owner.humanoid.Health = 50
    reset()
    check(CS.UseAbility(owner, target.root.Position) == true, name .. ": could not use its move")
    _G.flush()
end
useOn("Bubblo Gummo", enemy) -- Slow Spit
check(#log.slows == 1 and log.slows[1].who == "Enemy" and log.slows[1].factor < 1, "style: a Slow move did not slow the enemy it hit")
useOn("Tung Tung Tung Sahur", enemy) -- Daze Bonk
check(#log.slows >= 1 and log.slows[1].who == "Enemy" and log.slows[1].duration < 1, "style: a Daze move did not stagger the enemy")
useOn("Cactino Pokko", enemy) -- Toxic Spit
check(#log.venoms == 1 and log.venoms[1].who == "Enemy" and log.venoms[1].damage > 0, "style: a Toxic move started no DoT on the enemy")
useOn("Cipollina Lacrima", enemy) -- Leech Zap
check(owner.humanoid.Health > 50, "style: a Leech move did not heal its owner")
-- A teammate the move cannot hurt is not slowed, poisoned or leeched off.
-- The enemy steps out of range, so the teammate is the only one there to aim at.
enemy.root.Position = Vector3.new(0, 0, 900)
useOn("Bubblo Gummo", mate)
check(#log.slows == 0, "style: a teammate the move did not hurt was slowed")
useOn("Cactino Pokko", mate)
check(#log.venoms == 0, "style: a teammate the move did not hurt was poisoned")
useOn("Cipollina Lacrima", mate)
check(owner.humanoid.Health == 50, "style: leeched off a teammate the move did not hurt")
-- A Forking Zap jumps on to a second enemy at 60%.
enemy.root.Position = Vector3.new(20, 0, 0)
mate.root.Position = Vector3.new(0, 0, -900)
local second = _G.makeCombatant("Second", true, 30, "B")
useOn("Bottoncino Cucito", enemy)
local first, fork = nil, nil
for _, d in ipairs(log.deals) do
    if d.who == "Enemy" then first = d.amount elseif d.who == "Second" then fork = d.amount end
end
check(first ~= nil and fork ~= nil and math.abs(fork - first * 0.6) < 0.01, "style: a Forking Zap did not jump to a second enemy at 60%")
check(log.attacks[1] and log.attacks[1].to2 ~= nil and log.attacks[1].style == "Fork", "style: the Forking broadcast carried no fork point or style")
return out
"""


# Every brainrot at max level and stars against one enemy 10 studs off (inside every move's reach).
SWEEP = r"""
local CS = _G.CS
local BrainrotData = _G.BrainrotData
local out, facts = {}, {}
local function check(ok, msg) if not ok then table.insert(out, msg) end end
local scale = 0.736 -- MatchConfig.CombatDamageScale (TTK +25%, 2026-09-25); keep with line 181
local owner = _G.makeCombatant("Owner", true, 0, "A")
local enemy = _G.makeCombatant("Enemy", true, 10, "B")

-- What one use would take with no per-use cap: the hit, the DoT on what it dealt, the venom.
local function uncapped(def, s)
    local hit = s.damage * (def.blast and BrainrotData.BlastPower or 1) * scale
    local total = hit
    if not def.blast then
        total = total + hit * (s.dot or 0) * scale
        if def.boon and def.boon.venom then total = total + def.boon.venom.damage * scale end
    end
    return total
end

local function equip(def, level, stars)
    CS.ReviveAll()
    local xp = (level - 1) * BrainrotData.XpPerLevel
    owner.data = { Companion = def.name, Brainrots = { def.name }, CompanionXp = { [def.name] = xp }, Stars = { [def.name] = stars } }
    CS.Refresh(owner)
    CS.ResetStats()
end

local function fresh(shield)
    for k in pairs(_G.venomOn) do _G.venomOn[k] = nil end
    enemy.humanoid.Health = 100
    enemy.shield = shield
    _G.advance(100)
end

local worst, clipped1, count = {}, {}, {}
for _, def in ipairs(BrainrotData.Types) do
    local cap = BrainrotData.MaxUseDamage[def.rarity]
    local s = BrainrotData.Stats(def, BrainrotData.MaxLevel, BrainrotData.MaxStars)
    local want = uncapped(def, s)
    equip(def, BrainrotData.MaxLevel, BrainrotData.MaxStars)
    for _, shield in ipairs({ 0, 100 }) do
        fresh(shield)
        check(CS.UseAbility(owner, enemy.root.Position) == true, "sweep: a move could not be used")
        _G.flush()
        _G.tickVenom(10)
        local lost = (100 - enemy.humanoid.Health) + (shield - enemy.shield)
        worst[def.rarity] = math.max(worst[def.rarity] or 0, lost)
        if def.rarity == "Secret" then
            check(math.abs(lost - math.min(want, 100 + shield)) < 0.01,
                string.format("one-shot: Secret %s was clipped (%.1f of %.1f)", def.name, lost, want))
        else
            check(cap ~= nil and cap < 100, "one-shot: no MaxUseDamage under 100 for " .. def.rarity)
            check(lost <= (cap or 0) + 0.001, string.format("one-shot: %s (%s) took %.1f in one use, cap %s (shield %d)", def.name, def.rarity, lost, tostring(cap), shield))
            check(enemy.humanoid.Health > 0, string.format("one-shot: %s (%s) one-shot a full-health player (shield %d)", def.name, def.rarity, shield))
            check(lost >= math.min(want, cap or 0) - 0.01, string.format("one-shot: %s took %.1f, less than its %.1f", def.name, lost, math.min(want, cap or 0)))
        end
    end
    -- Three uses (two before TTK +25%, 2026-09-25), each as soon as the move is ready, DoTs ticking between.
    if BrainrotData.RarityIndex[def.rarity] >= BrainrotData.RarityIndex.Epic then
        fresh(0)
        check(CS.UseAbility(owner, enemy.root.Position) == true, "sweep: first use refused")
        _G.flush()
        for use = 2, 3 do
            _G.tickVenom(s.cooldown)
            _G.advance(s.cooldown + 0.01)
            if enemy.humanoid.Health > 0 then
                check(CS.UseAbility(owner, enemy.root.Position) == true, "sweep: use " .. use .. " refused")
                _G.flush()
            end
        end
        _G.tickVenom(10)
        check(enemy.humanoid.Health <= 0, string.format("three uses: %s (%s) left a full-health player on %.1f", def.name, def.rarity, enemy.humanoid.Health))
    end
    -- How often the cap bites on a fresh level-1 copy (for the facts line).
    count[def.rarity] = (count[def.rarity] or 0) + 1
    if cap and uncapped(def, BrainrotData.Stats(def, 1, 0)) > cap then clipped1[def.rarity] = (clipped1[def.rarity] or 0) + 1 end
end
for _, r in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }) do
    table.insert(facts, string.format("%s cap %s: most one max-level use takes %.1f; clipped at level 1: %d/%d", r,
        tostring(BrainrotData.MaxUseDamage[r] or "none"), worst[r] or 0, clipped1[r] or 0, count[r] or 0))
end
return out, facts
"""


def run_sweep(data_src, service_src, fails, facts):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute("function _run(h, a, b) return load(h, 'harness')(a, b) end")
    try:
        lua.globals()._run(SERVICE_HARNESS, luau_to_lua(data_src), luau_to_lua(service_src))
        out, lines = lua.execute(SWEEP)
    except Exception as exc:  # a crash is a failure, not a pass
        fails.append(f"sweep: harness crashed: {exc}")
        return
    for i in range(1, len(lines) + 1):
        facts.append(lines[i])
    for i in range(1, len(out) + 1):
        fails.append(out[i])


def run_service_checks(data_src, service_src, fails):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    lua.execute("function _run(h, a, b) return load(h, 'harness')(a, b) end")
    try:
        lua.globals()._run(SERVICE_HARNESS, luau_to_lua(data_src), luau_to_lua(service_src))
        out = lua.execute(SCENARIOS)
    except Exception as exc:  # a crash is a failure, not a pass
        fails.append(f"service: harness crashed: {exc}")
        return
    for i in range(1, len(out) + 1):
        fails.append("service: " + out[i])


def check(root, data_src, service_src, base_src):
    fails, facts = [], []
    run_data_checks(root, data_src, base_src, fails, facts)
    run_service_checks(data_src, service_src, fails)
    run_sweep(data_src, service_src, fails, facts)
    return fails, facts


PLANTS = [
    ("despawn back to Clear-first (entry left in the table when Clear throws)", SERVICE,
     "\tlocal entry = companions[owner]\n\tcompanions[owner] = nil\n\tif entry then\n\t\towners[entry.model] = nil\n\tend\n",
     "\tCompanionBoons.Clear(owner)\n\tlocal entry = companions[owner]\n\tcompanions[owner] = nil\n\tif entry then\n\t\towners[entry.model] = nil\n\tend\n"),
    ("no 0-HP gate on the hotkey, with the old despawn", SERVICE, None, None),
    ("style applied before the damage check (teammate slowed)", SERVICE,
     "\tlocal dealt = CombatService.DealDamage(player, token, amount, tag)\n",
     "\tlocal dealt = CombatService.DealDamage(player, token, amount, tag)\n\tif companions[player] then applyStyle(player, companions[player], token, amount, tag) end\n"),
    ("a brainrot dropped from AbilityStyleOf", DATA, '["Bubblo Gummo"] = "Slow", ', ""),
    ("Wide put on a Spit", DATA, '["Trippi Troppi"] = "Quick"', '["Trippi Troppi"] = "Wide"'),
    ("the buff undone (Common damage 12 -> 6)", DATA, "RarityDamage = { Common = 12,", "RarityDamage = { Common = 6,"),
    ("a style far over the side-grade band", DATA, 'Quick = { label = "Quick", power = 0.8,', 'Quick = { label = "Quick", power = 1.4,'),
    ("forks dropped from the Zap branch", SERVICE, "\t\t\t\thitForks(player, forks, stats.damage, tag, report)\n\t\t\t\treportHits(entry, report)\n\t\t\tend\n\t\tend)\n\telse\n\t\t-- Spit, Bonk and Lob travel",
     "\t\t\t\treportHits(entry, report)\n\t\t\tend\n\t\tend)\n\telse\n\t\t-- Spit, Bonk and Lob travel"),
    ("per-use cap removed", DATA, "BrainrotData.MaxUseDamage = { Common = 27,", "BrainrotData.MaxUseDamage = { Commonx = 27,"),
    ("cap per hit instead of per use (nothing booked)", SERVICE,
     "\treport.spent[token] = (report.spent[token] or 0) + amount * scale\n", ""),
    ("style DoT outside the cap", SERVICE,
     "local damage = withinUse(report, token, dealt * stats.dot)", "local damage = dealt * stats.dot"),
    ("venom outside the cap", SERVICE,
     "local damage = withinUse(report, token, venom.damage)", "local damage = venom.damage"),
    ("blast outside the cap", SERVICE,
     'damage = withinUse(useReport(entry), "blast", entry.stats.damage * BrainrotData.BlastPower),',
     "damage = entry.stats.damage * BrainrotData.BlastPower,"),
    ("cap counted before CombatDamageScale", SERVICE,
     "\tlocal scale = MatchConfig.CombatDamageScale or 1\n\tlocal left", "\tlocal scale = 1\n\tlocal left"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    base_rev = "HEAD"
    if "--base" in sys.argv:
        base_rev = sys.argv[sys.argv.index("--base") + 1]
    data_src, service_src = read(root, DATA), read(root, SERVICE)
    base_src = git_show(root, base_rev, DATA)

    if "--plant" not in sys.argv:
        fails, facts = check(root, data_src, service_src, base_src)
        for f in facts:
            print("  " + f)
        for f in fails:
            print("FAIL " + f)
        print(f"companion_ability_check: {'PASS' if not fails else 'FAIL'} ({len(fails)} failures)")
        sys.exit(1 if fails else 0)

    missed = 0
    for label, rel, old, new in PLANTS:
        d, s = data_src, service_src
        if old is None:
            # Two faults together: the old despawn order AND no gate on the hotkey.
            s = s.replace(PLANTS[0][2], PLANTS[0][3], 1).replace("\tif not canAct(entry) then\n\t\treturn false\n\tend\n\tlocal now",
                                                                   "\tif not entry then\n\t\treturn false\n\tend\n\tlocal now", 1)
            assert s != service_src
        elif rel == DATA:
            assert d.count(old) == 1, label
            d = d.replace(old, new)
        else:
            assert s.count(old) == 1, label
            s = s.replace(old, new)
        fails, _ = check(root, d, s, base_src)
        print(f"  plant [{label}]: {'CAUGHT' if fails else 'MISSED'}" + (f" -- {fails[0]}" if fails else ""))
        missed += 0 if fails else 1
    print(f"companion_ability_check --plant: {len(PLANTS) - missed}/{len(PLANTS)} caught")
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
