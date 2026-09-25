"""Bug test of the +25% time-to-kill (b668a9e, merge 25839e2: MatchConfig.CombatDamageScale 0.92 -> 0.736).

Runs the game's REAL Lua in lupa. The world is tools/explosive_dispatch_world.lua (with tools/hitreg_mocks.lua),
which loads CombatService, ProjectileService and VehicleWeapons whole; this check adds StatusEffects, VehicleArmor
and MountedGunData to the real list, puts WeaponService's real AbsorbDamage in, and cuts the damage functions of
VehicleService (DamageVehicle and its helpers), MountedGuns (damageGun), CompanionService (withinUse, applyStyle,
hit) and CompanionBoons (StartVenom, TickVenom) out of their files and runs them against that world. Every number
below comes out of those functions; the check does no damage arithmetic of its own except the "exact" count it
compares the real one with.

INVARIANTS (each a line; any failure fails the check, and every planted fault must make one fail):
  I1  DealDamage, one combatant hitting another (a player with a shield, a player without, a bot with a shield):
      the pool (health + shield) loses exactly amount x CombatDamageScale, for three amounts
  I2  DealDamage with no attacker, or the victim's own hit: the pool loses exactly the amount, unscaled
  I3  a ratio'd victim (StatusEffects' DamageTakenScale) takes x scale x ratio from an attacker, and the plain
      amount with no attacker
  I4  every gun's bleed and ignite (StatusEffects, the real module): the whole DoT takes damage x scale, each tick
      scaled once; every echo takes damage x ratio x scale
  I5  VehicleService.DamageVehicle, every car, bike and armoured car, every class: an attacker's hit takes
      amount x VehicleArmor.Scale x CombatDamageScale, a hit with no attacker amount x VehicleArmor.Scale
  I6  MountedGuns' damageGun, both guns, every class: an attacker's hit takes amount x class x scale (to the
      whole number the gun keeps), a hit with no attacker amount x class
  I7  a companion's venom boon (CompanionBoons, real) takes venom.damage x scale: scaled once
  I8  every hand gun, through the real DealDamage and (for launchers) the real explode(): the shots to kill a
      fresh player (100, and 100 + a full 100 shield) equal the exact arithmetic ceil(pool / (hit x scale)),
      so no float edge adds a shot
FINDINGS (measured and printed; they do not fail the check -- they are the bug report):
  F1  a companion's style DoT (Burning, Toxic) is scaled twice: sized off the hit AFTER the scale, then ticked
      through DealDamage, which scales it again
  F2  the same, as the side-grade band companion_ability_check claims to hold (0.85-1.2 of the plain move)
  F3  a blast from a thrower who has left (ProjectileService.creditable -> nil) skips the scale on people, but
      still gets it on vehicles (BlastDamage is handed the raw owner)
  F4  a mounted gun keeps its health as a whole number, so each hit is rounded; small hits (pellets, the shield)
      move by far more or less than 25%, and some stop doing anything
  F5  the owner's own blast on their own vehicle is scaled (self-damage on a person is not)
  F6  gun lifesteal heals off the raw damage, not what the hit took (heal / damage dealt = ratio / scale)
TABLES: every hand gun's shots and seconds to kill a player at 0.92 and now; every hand gun against every
vehicle (tools/vehicle_ttk_check.py's own loader and ttk()); every hand and vehicle gun against both mounted guns.

    python3 tools/ttk_bugtest_check.py [repo]              the check, findings and tables
    python3 tools/ttk_bugtest_check.py [repo] --plant      planted faults; every one must be caught

Needs lupa. "Before" is the same tree with only MatchConfig.CombatDamageScale set back to 0.92.
"""

import math
import os
import re
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import explosive_dispatch_check as edc  # noqa: E402
import vehicle_ttk_check as vt  # noqa: E402

BEFORE = "0.92"
EPS = 1e-6

HARNESS = r"""
local w, S, sources, compile = ...
local M, W = w.M, w.W
local V3 = M.Vector3.new
local CS, PS = S.CS, S.PS
local Combatants = w.module("Combatants")
local MatchConfig = w.module("MatchConfig")
local WeaponService = w.module("WeaponService")
local H = { loadouts = {} }

-- A combatant that has left no longer Exists (ProjectileService.creditable asks).
Combatants.Exists = function(token) return token ~= nil and not (type(token) == "table" and token.left) end

-- WeaponService's real AbsorbDamage, cut from the file, over this harness's loadouts.
WeaponService.PushSoon = function() end
local envMeta = { __index = _G }
local function chunk(name, text, env)
    local fn = assert(compile(text, name, "t", setmetatable(env, envMeta)))
    return fn()
end
chunk("AbsorbDamage", sources.absorb, { loadouts = H.loadouts, syncShield = function() end, WeaponService = WeaponService })

local ground
function H.reset()
    for k in pairs(M.walls) do M.walls[k] = nil end
    local kids = rawget(M.workspace, "_children")
    for k in pairs(kids) do kids[k] = nil end
    for k in pairs(W.tokens) do W.tokens[k] = nil end
    for k in pairs(W.humanoids) do W.humanoids[k] = nil end
    for k in pairs(H.loadouts) do H.loadouts[k] = nil end
    CS.DamageVeto = nil
    CS.SetEnabled(true)
    CS.HeadshotScale = 1
    PS.Clear()
    M.wall("Ground", V3(0, -0.5, 0), V3(600, 1, 600))
end

-- kind "player" (shield in the loadout) or "bot" (shield on the humanoid).
function H.person(name, kind, hp, shield, x, z)
    local model = M.character(name, M.CFrame.new(x or 0, 3, z or 0))
    local token = { name = name, Character = model, isPlayer = kind == "player", isBot = kind == "bot" }
    W.tokens[model] = token
    local humanoid = M.instance("Humanoid", "Humanoid", model, { Health = hp or 100, MaxHealth = hp or 100 })
    W.humanoids[token] = humanoid
    if kind == "player" then
        H.loadouts[token] = { shield = shield or 0 }
    elseif (shield or 0) > 0 then
        humanoid:SetAttribute("Shield", shield)
    end
    return token
end

function H.pool(token)
    local humanoid = W.humanoids[token]
    local shield = token.isPlayer and (H.loadouts[token] and H.loadouts[token].shield or 0) or (humanoid:GetAttribute("Shield") or 0)
    return humanoid.Health + shield, humanoid.Health, shield
end

function H.deal(a, v, amount, id, head)
    return CS.DealDamage(a, v, amount, id, head)
end

-- Shots of one gun until the target is down (hitscan: one DealDamage a pellet; a launcher: the real explode()
-- on a direct hit, or a direct DealDamage for a round that doesn't explode). `head` puts every pellet on the head.
-- The gun's own hit only: the damage listeners (StatusEffects' bleed, echo and ratio mark) are off for it.
function H.shotsToKill(def, hp, shield, head)
    local listeners = CS.DamageListeners
    CS.DamageListeners = {}
    local ok, result = pcall(H.shotsToKillBare, def, hp, shield, head)
    CS.DamageListeners = listeners
    assert(ok, result)
    return result
end
function H.shotsToKillBare(def, hp, shield, head)
    H.reset()
    local a = H.person("A", "player", 100, 0, 0, 0)
    local v = H.person("V", "player", hp, shield, 0, -20)
    local spec = def.projectile and S.B.Rounds[def.projectile]
    local mult = head and (def.headshotMultiplier or 1) or 1
    for shot = 1, 400 do
        if spec then
            local root = Combatants.GetRoot(v)
            if spec.explosive == false then
                CS.DealDamage(a, v, (def.damage + (spec.impactBonus or 0)) * mult, def.id, head)
            else
                PS.Explode({ id = shot, kind = def.projectile, owner = a, weaponId = def.id, position = root.Position,
                    normal = V3(0, 1, 0), damage = def.damage, radius = spec.radius or 8, innerRadius = spec.innerRadius or 0,
                    wallDamage = 0, direct = { token = v, bonus = spec.impactBonus or 0, headshot = head == true, multiplier = mult } })
            end
        else
            for _ = 1, def.pellets or 1 do
                CS.DealDamage(a, v, def.damage * mult, def.id, head)
            end
        end
        if W.humanoids[v].Health <= 0 then
            return shot
        end
    end
    return -1
end

-- A blast from `owner` (a token, possibly one that has left) at a victim 1 stud from its centre.
function H.blastOn(ownerLeft, damage)
    H.reset()
    local owner = H.person("Owner", "player", 100, 0, 40, 0)
    owner.left = ownerLeft
    local v = H.person("V", "player", 100, 0, 0, -20)
    local seen = {}
    local VS = w.module("VehicleService")
    VS.BlastDamage = function(blast) table.insert(seen, blast.owner) end
    local root = Combatants.GetRoot(v)
    PS.Explode({ id = 1, kind = "rocket", owner = owner, weaponId = "CappuccinaLauncher", position = root.Position,
        normal = V3(0, 1, 0), damage = damage, radius = 10, innerRadius = 2, wallDamage = 0 })
    return 100 - H.pool(v), seen[1] == owner
end

-- StatusEffects, the real module, driven by a real hit.
function H.statusRun(def)
    local SE = w.module("StatusEffects")
    local queue = {}
    SE.Delay = function(_, fn) table.insert(queue, fn) end
    SE.Clock = function() return w.now.t end
    H.reset()
    local a = H.person("A", "player", 100, 0, 0, 0)
    local v = H.person("V", "bot", 1000, 0, 0, -20)
    CS.DealDamage(a, v, def.damage, def.id, false)
    local afterHit = H.pool(v)
    local echo = 0
    for _, fn in ipairs(queue) do
        local before = H.pool(v)
        fn()
        echo = echo + before - H.pool(v)
    end
    local before = H.pool(v)
    for _ = 1, 200 do
        SE.Tick()
    end
    return 1000 - afterHit, before - H.pool(v), echo
end

-- A ratio'd victim: `stacks` quick hits, then one more of `amount`, from an attacker and from no one.
function H.ratioRun(def, amount)
    local SE = w.module("StatusEffects")
    SE.Delay = function() end
    SE.Clock = function() return w.now.t end
    H.reset()
    local a = H.person("A", "player", 100, 0, 0, 0)
    local v = H.person("V", "bot", 100000, 0, 0, -20)
    for _ = 1, def.ratio.stacks do
        CS.DealDamage(a, v, 1, def.id, false)
    end
    local marked = SE.DamageTakenScale(v)
    local p = H.pool(v)
    CS.DealDamage(a, v, amount, "Plain", false)
    local fromA = p - H.pool(v)
    p = H.pool(v)
    CS.DealDamage(nil, v, amount, "Plain", false)
    return marked, fromA, p - H.pool(v)
end

-- Lifesteal through the real CombatService.Fire: a shooter on 50 fires once at an enemy's chest 30 studs off.
function H.lifesteal(def)
    H.reset()
    local shooter = H.person("S", "player", 100, 0, 0, 0)
    W.humanoids[shooter].Health = 50
    local enemy = H.person("E", "player", 1000, 0, 0, -30)
    CS.SpreadFor = function() return 0 end
    W.equipped = def
    w.loadout.fireCredit, w.loadout.lastShotAt, w.loadout.reloading = 2, 0, nil
    w.now.t = w.now.t + 10
    CS.Fire(shooter, V3(0, 3.4, -30))
    return W.humanoids[shooter].Health - 50, 1000 - H.pool(enemy)
end

-- VehicleService's damage functions, cut from the file.
local VSmod, byModel
do
    local fn = assert(compile("local byModel = {}\nlocal function releaseRest() end\nlocal VehicleService = {}\n"
        .. sources.ridersOf .. "\n" .. sources.vetoed .. "\n" .. sources.damageVehicle .. "\n" .. sources.DamageVehicle
        .. "\nreturn VehicleService, byModel\n", "VehicleDamage", "t", setmetatable({ VehicleArmor = w.module("VehicleArmor"),
        MatchConfig = MatchConfig, CombatService = CS, Combatants = Combatants, tick = function() return w.now.t end }, envMeta)))
    VSmod, byModel = fn()
end
local function obj(attrs)
    local o = { _a = attrs or {} }
    function o:GetAttribute(k) return self._a[k] end
    function o:SetAttribute(k, v) self._a[k] = v end
    return o
end
-- A vehicle entry (health, the model's attribute), riders by token.
function H.vehicle(modelId, health, riders)
    local model = obj({ VehicleModel = modelId })
    local entry = { model = model, health = health, prompts = {}, occupants = {}, rig = { chassis = { Position = V3(0, 0, 0) } } }
    for i, token in ipairs(riders or {}) do
        entry.occupants[i] = { Parent = token.Character }
    end
    byModel[model] = entry
    return model, entry
end
function H.damageVehicle(attacker, model, amount, class)
    return VSmod.DamageVehicle(attacker, model, amount, class, "X", V3(0, 0, 0))
end

-- MountedGuns' damageGun, cut from the file.
local damageGun = assert(compile("local riders = {}\nlocal function breakGun(model) model:SetAttribute('Wrecked', true) end\n"
    .. sources.damageGun .. "\nreturn damageGun\n", "damageGun", "t", setmetatable({ MountedGunData = w.module("MountedGunData"),
    MatchConfig = MatchConfig, CombatService = CS, Combatants = Combatants }, envMeta)))()
function H.gunModel(health)
    return obj({ VehicleHealth = health, MountedGun = "x" })
end
function H.damageGun(attacker, model, amount, class, shield)
    local part = obj({ Shield = shield or nil })
    return damageGun(attacker, model, amount, class, part, V3(0, 0, 0))
end
-- Hits of `amount` (class `class`, on the shield or not) until the gun breaks; -1 if 2000 don't.
function H.hitsToBreak(attacker, health, amount, class, shield)
    local model = H.gunModel(health)
    for n = 1, 2000 do
        damageGun(attacker, model, amount, class, obj({ Shield = shield or nil }), V3(0, 0, 0))
        if model:GetAttribute("Wrecked") then
            return n
        end
    end
    return -1
end

-- CompanionService's use cap and style, and CompanionBoons' venom, cut from the files.
local companions = {}
local CB = { VenomOf = function(def) return def.venom end }
assert(compile("local venoms = {}\nlocal VENOM_TICK = " .. sources.venomTick .. "\nlocal venomAccumulated = 0\n"
    .. sources.StartVenom .. "\n" .. sources.TickVenom .. "\n", "CompanionBoons", "t",
    setmetatable({ CompanionBoons = CB, Combatants = Combatants, CombatService = CS }, envMeta)))()
-- underCanopy: pc/lag-bug-sweep's hit() asks it (a glider canopy soaks the hit); nobody here has one.
local companionFns = assert(compile("local damageDealt = {}\nlocal MAX_HIT_MARKS = 12\nlocal function awardXp() end\n"
    .. "local function slowTarget() end\nlocal function underCanopy() return false end\n" .. sources.withinUse .. "\n" .. sources.applyStyle .. "\n" .. sources.hit
    .. "\nreturn hit\n", "CompanionUse", "t", setmetatable({ MatchConfig = MatchConfig, CombatService = CS,
    Combatants = Combatants, CompanionBoons = CB, companions = companions }, envMeta)))
local companionHit = companionFns()
-- One hit of `amount` with a style (dot, dotTime) or a venom boon, uncapped: what the hit took, what the DoT took.
function H.companion(amount, dot, dotTime, venom)
    H.reset()
    local owner = H.person("Owner", "player", 100, 0, 0, 0)
    local enemy = H.person("Enemy", "player", 1000, 0, 0, -10)
    companions[owner] = { def = { name = "Test", rarity = "Secret", venom = venom }, stats = { dot = dot, dotTime = dotTime } }
    companionHit(owner, enemy, amount, "Companion:Test", { positions = {}, spent = {} })
    local afterHit = H.pool(enemy)
    for _ = 1, 100 do
        CB.TickVenom(0.5)
    end
    return 1000 - afterHit, afterHit - H.pool(enemy)
end

return H
"""


def sources_for(tree):
    def src(name):
        text = tree.lua(name)
        if text is None:
            sys.exit(f"ttk_bugtest_check: no source for {name}")
        return text
    vs, mg, cs, cb, ws = (src(n) for n in ("VehicleService", "MountedGuns", "CompanionService", "CompanionBoons", "WeaponService"))
    cut = edc.cut
    return {
        "absorb": cut(ws, "function WeaponService.AbsorbDamage("),
        "ridersOf": cut(vs, "local function ridersOf("),
        "vetoed": cut(vs, "local function vetoed("),
        "damageVehicle": cut(vs, "local function damageVehicle("),
        "DamageVehicle": cut(vs, "function VehicleService.DamageVehicle("),
        "damageGun": cut(mg, "local function damageGun("),
        "withinUse": cut(cs, "local function withinUse("),
        "applyStyle": cut(cs, "local function applyStyle("),
        "hit": cut(cs, "local function hit("),
        "StartVenom": cut(cb, "function CompanionBoons.StartVenom("),
        "TickVenom": cut(cb, "function CompanionBoons.TickVenom("),
        "venomTick": re.search(r"local VENOM_TICK = ([\d.]+)", cb).group(1),
    }


def load(root, swaps=None, scale=None):
    """The world at the tree's own scale, or at `scale` (a string) with only that one line changed."""
    swaps = {k: list(v) for k, v in (swaps or {}).items()}
    if scale is not None:
        text = open(os.path.join(root, "ReplicatedStorage/Shared/MatchConfig.lua"), encoding="utf-8").read()
        line = re.search(r"MatchConfig\.CombatDamageScale = [\d.]+", text).group(0)
        swaps.setdefault("MatchConfig", []).append((line, "MatchConfig.CombatDamageScale = " + scale))
    # The world resolves requires through script.Parent only; StatusEffects finds its siblings through
    # ServerScriptService.Modules, so that one line is pointed at script.Parent (the same folder in the game).
    swaps.setdefault("StatusEffects", []).append(('local Modules = ServerScriptService:WaitForChild("Modules")',
                                                  "local Modules = script.Parent"))
    tree = edc.Tree(root, swaps)
    edc.REAL = list(edc.REAL) + [m for m in ("StatusEffects", "VehicleArmor") if m not in edc.REAL]
    lua, w, S = edc.load_world(tree)
    harness = lua.execute("return function(...) " + HARNESS + " end")
    H = harness(w, S, lua.table_from(sources_for(tree)), lua.globals().load)
    return lua, w, S, H


def guns_of(S):
    return sorted(((gid, d) for gid, d in S.WD.Weapons.items()), key=lambda x: x[0])


def exact_shots(per_shot, pool):
    return math.ceil(pool / per_shot) if per_shot > 0 else -1


def invariants(root, swaps=None):
    lua, w, S, H = load(root, swaps)
    s = float(S.module("MatchConfig").CombatDamageScale)
    rows, examined = [], {}

    # I1 / I2
    fails = []
    n = 0
    for kind, shield in (("player", 60), ("player", 0), ("bot", 60)):
        for amount in (7.3, 40, 150):
            for who in ("other", "none", "self"):
                H.reset()
                a = H.person("A", "player", 100, 0, 0, 0)
                v = H.person("V", kind, 100, shield, 0, -20)
                before = H.pool(v)[0]
                attacker = a if who == "other" else (None if who == "none" else v)
                H.deal(attacker, v, amount, "Plain", False)
                lost = before - H.pool(v)[0]
                want = min(amount * (s if who == "other" else 1), before)
                n += 1
                if abs(lost - want) > EPS:
                    fails.append(f"{kind} shield {shield}, {amount} from {who}: lost {lost:.4f}, want {want:.4f}")
    examined["I1/I2 DealDamage cases"] = n
    rows.append((not [f for f in fails if "from other" in f],
                 f"I1 DealDamage: a hit from another combatant takes amount x {s} from the pool (player with and without a shield, bot with one; 3 amounts){'' if not fails else ': ' + '; '.join(f for f in fails if 'from other' in f)}"))
    rows.append((not [f for f in fails if "from other" not in f],
                 f"I2 DealDamage: no attacker, and a victim's own hit, take the whole amount{'' if not fails else ': ' + '; '.join(f for f in fails if 'from other' not in f)}"))

    # I3 ratio'd
    guns = guns_of(S)
    ratio_guns = [(gid, d) for gid, d in guns if d.ratio is not None]
    bad = []
    for gid, d in ratio_guns:
        marked, from_a, from_none = H.ratioRun(d, 30)
        if abs(from_a - 30 * s * marked) > EPS or abs(from_none - 30) > EPS or marked <= 1:
            bad.append(f"{gid}: marked x{marked}, attacker's 30 took {from_a:.3f} (want {30 * s * marked:.3f}), no one's took {from_none:.3f}")
    examined["ratio guns"] = len(ratio_guns)
    rows.append((ratio_guns and not bad, f"I3 ratio'd victim ({len(ratio_guns)} gun(s)): an attacker's hit x scale x mark, no attacker's plain{': ' + '; '.join(bad) if bad else ''}"))

    # I4 DoTs and echoes
    bad, count = [], 0
    for gid, d in guns:
        for field in ("bleed", "ignite"):
            spec = d[field]
            if spec is not None:
                count += 1
                hit, dot, _ = H.statusRun(d)
                want = spec.damage * s
                if abs(dot - want) > 1e-4 or abs(hit - d.damage * s) > 1e-4:
                    bad.append(f"{gid} {field}: hit {hit:.3f} (want {d.damage * s:.3f}), DoT {dot:.3f} (want {want:.3f})")
        if d.echo is not None:
            count += 1
            _, _, echo = H.statusRun(d)
            want = d.damage * d.echo.ratio * s
            if abs(echo - want) > 1e-4:
                bad.append(f"{gid} echo: {echo:.3f}, want {want:.3f}")
    examined["bleed/ignite/echo effects"] = count
    rows.append((count > 0 and not bad, f"I4 {count} DoT/echo effect(s) through the real StatusEffects: each scaled exactly once{': ' + '; '.join(bad[:6]) if bad else ''}"))

    # I5 vehicles
    armour = S.module("VehicleArmor")
    models = list(vt.CARS + vt.BIKES + vt.ARMOURED)
    bad = []
    for model_id in models:
        for cls in ("bullet", "heavy", "explosive"):
            for who in ("attacker", "none"):
                H.reset()
                a = H.person("A", "player", 100, 0, 0, 0)
                model, entry = H.vehicle(model_id, 5000, lua.table())
                H.damageVehicle(a if who == "attacker" else None, model, 100, cls)
                lost = 5000 - entry.health
                want = 100 * armour.Scale(model_id, cls) * (s if who == "attacker" else 1)
                if abs(lost - want) > EPS:
                    bad.append(f"{model_id} {cls} from {who}: {lost:.3f}, want {want:.3f}")
    examined["vehicle x class x attacker cases"] = len(models) * 6
    rows.append((not bad, f"I5 DamageVehicle, {len(models)} vehicles x 3 classes: attacker's hit x armour x scale, no attacker's x armour{': ' + '; '.join(bad[:6]) if bad else ''}"))

    # I6 mounted guns (1000 a hit, so the whole number the gun keeps is exact)
    mgd = S.module("MountedGunData")
    bad, n = [], 0
    for kind in ("hmg", "cannon"):
        for cls in ("bullet", "heavy", "explosive"):
            for who in ("attacker", "none"):
                H.reset()
                a = H.person("A", "player", 100, 0, 0, 0)
                model = H.gunModel(100000)
                H.damageGun(a if who == "attacker" else None, model, 1000, cls, False)
                lost = 100000 - model.GetAttribute(model, "VehicleHealth")
                want = round(1000 * mgd.Classes[cls] * (s if who == "attacker" else 1))
                n += 1
                if abs(lost - want) > 0.5:
                    bad.append(f"{kind} {cls} from {who}: {lost}, want {want}")
    examined["mounted gun cases"] = n
    rows.append((not bad, f"I6 damageGun, 2 guns x 3 classes: attacker's hit x class x scale, no attacker's x class{': ' + '; '.join(bad[:6]) if bad else ''}"))

    # I7 venom boon
    venom = lua.eval("{ damage = 24, duration = 3 }")
    hit, dot = H.companion(40, None, None, venom)
    ok = abs(hit - 40 * s) < 1e-4 and abs(dot - 24 * s) < 1e-4
    rows.append((ok, f"I7 venom boon: the bite took {hit:.3f} (40 x {s}), the venom {dot:.3f} (24 x {s} = {24 * s:.3f}): scaled once"))

    # I8 shots to kill, real vs exact
    bad, n = [], 0
    for gid, d in guns:
        per, per_head = per_shot(S, d, 1), per_shot(S, d, d.headshotMultiplier or 1)
        for pool, shield in ((100, 0), (100, 100)):
            real = H.shotsToKill(d, pool, shield, False)
            want = exact_shots(per * Fraction(str(s)), pool + shield)
            n += 1
            if real != want:
                bad.append(f"{gid} body vs {pool}+{shield}: real {real}, exact {want}")
        real = H.shotsToKill(d, 100, 0, True)
        want = exact_shots(per_head * Fraction(str(s)), 100)
        n += 1
        if real != want:
            bad.append(f"{gid} head vs 100: real {real}, exact {want}")
    examined["hand guns"] = len(guns)
    examined["shots-to-kill cases"] = n
    rows.append((not bad, f"I8 {len(guns)} hand guns, {n} cases: the real path's shots to kill equal ceil(pool / (hit x scale)){': ' + '; '.join(bad[:6]) if bad else ''}"))
    return rows, examined, (lua, w, S, H, s)


def per_shot(S, d, mult):
    """One shot's damage before the scale, as an exact Fraction (the pellets, or a launcher's direct hit)."""
    spec = S.B.Rounds[d.projectile] if d.projectile else None
    if spec is not None:
        # explode(): damage x falloff 1 x exposure 1, plus the impact bonus x the multiplier; a dud: (damage + bonus) x mult.
        if spec.explosive is False:
            return (Fraction(str(d.damage)) + Fraction(str(spec.impactBonus or 0))) * Fraction(str(mult))
        return Fraction(str(d.damage)) + Fraction(str(spec.impactBonus or 0)) * Fraction(str(mult))
    return Fraction(str(d.damage)) * Fraction(str(mult)) * (d.pellets or 1)


# ------------------------------------------------------------------------------------------- findings

def findings(root, ctx):
    lua, w, S, H, s = ctx
    out = []
    # F1 / F2: the companion style DoT, the real hit then the real venom ticker.
    brainrot = open(os.path.join(root, "ReplicatedStorage/Shared/BrainrotData.lua"), encoding="utf-8").read()
    styles = {}
    for name in ("Burn", "Toxic"):
        m = re.search(name + r' = \{ label = "\w+", power = ([\d.]+), dot = ([\d.]+), dotStep = ([\d.]+), dotTime = ([\d.]+)', brainrot)
        styles[name] = tuple(float(x) for x in m.groups())
    for name, (power, dot, step, dot_time) in styles.items():
        hit, took = H.companion(40, dot, dot_time, None)
        ratio = took / hit
        real_sidegrade = power * (1 + dot * s)
        check_model = power * (1 + dot)
        out.append(("F1", f"{name} (dot {dot}): a 40 hit took {hit:.2f}, its DoT {took:.2f} = {ratio:.3f} of the hit; "
                          f"BrainrotData says 'fraction of the hit dealt again' = {dot}; measured/said = {ratio / dot:.3f} (= CombatDamageScale {s}): scaled twice"))
        # Level 1, every rarity step 0..6: the style's real damage a second against the plain move.
        worst = min(power * (1 + (dot + step * k) * s) for k in range(0, 7))
        out.append(("F2", f"{name}: real damage a second vs the plain move at step 0 = {real_sidegrade:.3f} (lowest over steps 0-6 {worst:.3f}); "
                          f"companion_ability_check's model says {check_model:.3f}; at 0.92 the real one was {power * (1 + dot * 0.92):.3f}. Band 0.85-1.2"
                          + ("  <-- BELOW THE BAND" if real_sidegrade < 0.85 else "")))
    # F3: a leaver's blast.
    here, vehicle_here = H.blastOn(False, 60)
    gone, vehicle_gone = H.blastOn(True, 60)
    out.append(("F3", f"a 60 blast 1 stud from a player: thrower present -> {here:.2f} taken, thrower has left -> {gone:.2f} "
                      f"({gone / here:.3f}x); VehicleService.BlastDamage handed the raw owner in both: {vehicle_here and vehicle_gone} (a vehicle gets the scale either way)"))
    # F5: own blast on own vehicle.
    H.reset()
    a = H.person("A", "player", 100, 0, 0, 0)
    model, entry = H.vehicle("Rotster", 5000, lua.table(a))
    H.damageVehicle(a, model, 50, "explosive")
    own = 5000 - entry.health
    armour = S.module("VehicleArmor").Scale("Rotster", "explosive")
    H.reset()
    p = H.person("P", "player", 100, 0, 0, 0)
    H.deal(p, p, 50, "CappuccinaLauncher", False)
    out.append(("F5", f"the owner's own 50 on the car they ride (explosive x{armour}): {own:.2f} taken = x{own / (50 * armour):.3f} (scaled); "
                      f"the same 50 on themselves: {100 - H.pool(p)[0]:.2f} (not scaled)"))
    # F6: lifesteal through the real Fire.
    for gid, d in guns_of(S):
        if d.ability == "lifesteal" and not d.projectile:
            heal, took = H.lifesteal(d)
            if took > 0:
                ratio = d.lifestealRatio or 0.2
                out.append(("F6", f"{gid} (lifestealRatio {ratio}): one shot took {took:.2f}, healed the shooter {heal:.2f} = "
                                  f"{heal / took:.3f} of the damage dealt (WeaponData: 'a fraction of damage dealt' = {ratio}; x{heal / took / ratio:.3f})"))
    return out


# --------------------------------------------------------------------------------------------- tables

def ttk_seconds(shots, d):
    mag = int(d.magSize or 1)
    return (shots - 1) / d.fireRate + ((shots - 1) // mag) * (d.reloadTime or 2)


def gun_table(ctx_now, ctx_before):
    _, _, S, H, s = ctx_now
    _, _, Sb, Hb, sb = ctx_before
    rows, ratios, lost_one = [], [], []
    for gid, d in guns_of(S):
        db = Sb.WD.Get(gid)
        r = {}
        for key, (hp, sh, head) in {"b100": (100, 0, False), "b200": (100, 100, False), "h100": (100, 0, True), "h200": (100, 100, True)}.items():
            r[key] = (Hb.shotsToKill(db, hp, sh, head), H.shotsToKill(d, hp, sh, head))
        t_before, t_now = ttk_seconds(r["b200"][0], d), ttk_seconds(r["b200"][1], d)
        ratio = t_now / t_before if t_before > 0 else float("inf")
        ratios.append((ratio, gid))
        for key in ("b100", "b200", "h100", "h200"):
            if r[key][0] == 1 and r[key][1] > 1:
                lost_one.append(f"{gid} {key}")
        rows.append((gid, d.rarity, "staged" if d.staged else "", r, t_before, t_now, ratio))
    return rows, ratios, lost_one


def vehicle_table(root, s_now):
    lua, armour, data, ballistics, scale, guns = vt.load(root)
    models = list(vt.CARS + vt.BIKES + vt.ARMOURED)
    out = []
    for gid, g in sorted(guns.items()):
        if g["projectile"]:
            rnd = ballistics.Rounds[g["projectile"]]
            if rnd is None:
                continue
            hit = g["damage"] + (rnd.impactBonus or 0)
            for m in models:
                h = armour.HealthOf(m, "bike" if m in vt.BIKES else "car")
                per = lambda sc: hit * sc * armour.Scale(m, "explosive")  # noqa: E731
                nb, nn = math.ceil(h / per(float(BEFORE))), math.ceil(h / per(s_now))
                out.append((gid, m, "rounds", nb, nn))
        else:
            for m in models:
                h = armour.HealthOf(m, "bike" if m in vt.BIKES else "car")
                sb, _ = vt.ttk(h, g, float(BEFORE), armour.Scale(m, "bullet"))
                sn, _ = vt.ttk(h, g, s_now, armour.Scale(m, "bullet"))
                out.append((gid, m, "seconds", sb, sn))
    return out


def mounted_table(ctx_now, ctx_before):
    _, _, S, H, s = ctx_now
    _, _, Sb, Hb, _ = ctx_before
    mgd = S.module("MountedGunData")
    rows = []
    for gid, d in guns_of(S):
        if d.projectile:
            continue
        a_now = H.person("A", "player", 100, 0, 0, 0)
        a_before = Hb.person("A", "player", 100, 0, 0, 0)
        for kind in ("hmg", "cannon"):
            health = mgd.Kinds[kind].health
            for shield in (False, True):
                pellets = d.pellets or 1
                nb = Hb.hitsToBreak(a_before, health, d.damage, "bullet", shield)
                nn = H.hitsToBreak(a_now, health, d.damage, "bullet", shield)
                rows.append((gid, kind, "shield" if shield else "body", d.damage, pellets, nb, nn))
    for key, spec in S.VWD.Weapons.items():
        if spec.kind == "round" or spec.damage is None:
            continue
        cls = spec.damageClass or "bullet"
        a_now = H.person("A", "player", 100, 0, 0, 0)
        a_before = Hb.person("A", "player", 100, 0, 0, 0)
        for kind in ("hmg", "cannon"):
            health = mgd.Kinds[kind].health
            for shield in (False, True):
                nb = Hb.hitsToBreak(a_before, health, spec.damage, cls, shield)
                nn = H.hitsToBreak(a_now, health, spec.damage, cls, shield)
                rows.append(("vehicle:" + key, kind, "shield" if shield else "body", spec.damage, 1, nb, nn))
    return rows


# ------------------------------------------------------------------------------------------------ run

def run(root, swaps=None, verbose=True):
    rows, examined, ctx = invariants(root, swaps)
    if not verbose:
        return rows
    for ok, text in rows:
        print(("ok    " if ok else "FAIL  ") + text)
    print("examined: " + ", ".join(f"{k} {v}" for k, v in examined.items()))
    s = ctx[4]
    before = load(root, scale=BEFORE)
    lua_b, w_b, S_b, H_b = before
    ctx_before = (lua_b, w_b, S_b, H_b, float(BEFORE))

    print(f"\nFINDINGS (CombatDamageScale {s}; before = {BEFORE})")
    found = findings(root, ctx)
    for tag, text in found:
        print(f"{tag}  {text}")

    print(f"\nHAND GUNS vs A PLAYER: shots to kill at {BEFORE} -> {s} (body 100 | body 100+100 shield | head 100 | head 200), "
          "seconds for the 200 pool with reloads, ratio")
    table, ratios, lost_one = gun_table(ctx, ctx_before)
    for gid, tier, staged, r, tb, tn, ratio in table:
        cells = " | ".join(f"{r[k][0]:>2}->{r[k][1]:<2}" for k in ("b100", "b200", "h100", "h200"))
        print(f"  {gid:28} {tier:10} {staged:6} {cells}  {tb:5.2f}s -> {tn:5.2f}s  x{ratio:.3f}")
    rs = sorted(x for x, _ in ratios if x != float("inf"))
    live = sorted((x, g) for x, g in ratios)
    print(f"  TTK ratio (200 pool, seconds) over {len(rs)} guns: min {rs[0]:.3f}, median {rs[len(rs) // 2]:.3f}, max {rs[-1]:.3f}; "
          f"within 1.15-1.35: {sum(1 for x in rs if 1.15 <= x <= 1.35)}; under 1.15: {sum(1 for x in rs if x < 1.15)}; over 1.35: {sum(1 for x in rs if x > 1.35)}")
    print("  lowest: " + ", ".join(f"{g} x{x:.3f}" for x, g in live[:6]))
    print("  highest: " + ", ".join(f"{g} x{x:.3f}" for x, g in live[-6:]))
    print("  one-shots lost: " + (", ".join(lost_one) if lost_one else "none"))

    print(f"\nHAND GUNS vs VEHICLES (vehicle_ttk_check's loader and ttk(); rifle seconds with reloads, launcher direct hits)")
    vrows = vehicle_table(root, s)
    vr = sorted((b and n / b or 0, g, m, kind, b, n) for g, m, kind, b, n in vrows if b > 0)
    print(f"  {len(vrows)} gun x vehicle pairs; ratio min {vr[0][0]:.3f} ({vr[0][1]} on {vr[0][2]}: {vr[0][4]:.2f} -> {vr[0][5]:.2f} {vr[0][3]}), "
          f"median {vr[len(vr) // 2][0]:.3f}, max {vr[-1][0]:.3f} ({vr[-1][1]} on {vr[-1][2]}: {vr[-1][4]:.2f} -> {vr[-1][5]:.2f} {vr[-1][3]})")
    rounds = [x for x in vr if x[3] == "rounds"]
    print(f"  launcher x vehicle pairs {len(rounds)}: rounds needed unchanged in {sum(1 for x in rounds if x[4] == x[5])}, "
          f"+1 in {sum(1 for x in rounds if x[5] - x[4] == 1)}, +2 or more in {sum(1 for x in rounds if x[5] - x[4] >= 2)}")
    for x in sorted(rounds, key=lambda x: (x[1], x[2])):
        if x[5] - x[4] >= 2:
            print(f"    {x[1]} on {x[2]}: {x[4]} -> {x[5]} rounds (x{x[0]:.3f})")
    shots = [x for x in vr if x[3] == "seconds"]
    print(f"  gun x vehicle pairs in seconds {len(shots)}: under x1.15 {sum(1 for x in shots if x[0] < 1.15)}, "
          f"over x1.35 {sum(1 for x in shots if x[0] > 1.35)}; the reference rifle (BananiniBurst): "
          + ", ".join(f"{x[2]} {x[4]:.1f}->{x[5]:.1f}s" for x in sorted(shots, key=lambda x: x[2]) if x[1] == "BananiniBurst"))

    print(f"\nF4  GUNS vs MOUNTED GUNS (real damageGun: the gun keeps whole numbers), hits to break at {BEFORE} -> {s}, one hit a pellet")
    mrows = mounted_table(ctx, ctx_before)
    immune = [r for r in mrows if r[6] == -1 and r[5] != -1]
    odd = sorted(((r[6] / r[5]) if r[5] > 0 and r[6] > 0 else 99, r) for r in mrows)
    print(f"  {len(mrows)} gun x emplacement x face cases; ratio min {odd[0][0]:.3f}, median {odd[len(odd) // 2][0]:.3f}")
    print(f"  now do NOTHING (breaks at {BEFORE}, 2000 hits don't break it now): {len(immune)}"
          + ("".join(f"\n    {r[0]} on the {r[1]}'s {r[2]}: {r[3]} a pellet, {r[5]} hits -> never" for r in immune[:40])))
    far = [(x, r) for x, r in odd if x != 99 and (x < 1.1 or x > 1.45)]
    print(f"  hits-to-break ratio outside 1.10-1.45 (expected 1.25): {len(far)}")
    for x, r in far[:40]:
        print(f"    {r[0]} on the {r[1]}'s {r[2]}: {r[3]} a hit, {r[5]} -> {r[6]} hits (x{x:.3f})")
    failed = sum(1 for ok, _ in rows if not ok)
    print(f"\nttk_bugtest_check: {len(rows)} invariants, {failed} failed, {len(found)} finding line(s)")
    return rows


PLANTS = [
    ("DealDamage drops the scale", {"CombatService": [(
        "\t\tamount *= MatchConfig.CombatDamageScale or 1\n", "")]}),
    ("DealDamage scales every hit, no attacker too", {"CombatService": [(
        "\tif attackerToken ~= nil and attackerToken ~= victimToken then\n\t\tamount *= MatchConfig.CombatDamageScale or 1",
        "\tif true then\n\t\tamount *= MatchConfig.CombatDamageScale or 1")]}),
    ("DealDamage scales twice", {"CombatService": [(
        "\t\tamount *= MatchConfig.CombatDamageScale or 1\n",
        "\t\tamount *= MatchConfig.CombatDamageScale or 1\n\t\tamount *= MatchConfig.CombatDamageScale or 1\n")]}),
    ("the ratio mark counts on a hit with no attacker", {"CombatService": [(
        "\t\tif CombatService.DamageTakenScale then\n\t\t\tamount *= CombatService.DamageTakenScale(victimToken) or 1\n\t\tend\n\tend\n",
        "\tend\n\tif CombatService.DamageTakenScale then\n\t\tamount *= CombatService.DamageTakenScale(victimToken) or 1\n\tend\n")]}),
    ("the shield soaks the unscaled hit", {"WeaponService": [(
        "\tlocal absorbed = math.min(loadout.shield, amount)\n", "\tlocal absorbed = math.min(loadout.shield, amount / 0.736)\n")]}),
    ("health rounded down on every hit", {"CombatService": [(
        "\t\thumanoid:TakeDamage(amount)\n", "\t\thumanoid:TakeDamage(math.floor(amount))\n")]}),
    ("a bleed or ignite pre-scaled before its ticks", {"StatusEffects": [(
        "perTick = damage / ticks", "perTick = damage * 0.8 / ticks")]}),
    ("DamageVehicle drops the scale", {"VehicleService": [(
        "\tif attacker ~= nil then\n\t\tscaled *= MatchConfig.CombatDamageScale or 1\n\tend\n", "")]}),
    ("DamageVehicle scales a hit with no attacker", {"VehicleService": [(
        "\tif attacker ~= nil then\n\t\tscaled *= MatchConfig.CombatDamageScale or 1\n",
        "\tif true then\n\t\tscaled *= MatchConfig.CombatDamageScale or 1\n")]}),
    ("damageGun drops the scale", {"MountedGuns": [(
        "\tif attacker ~= nil then\n\t\tscale *= MatchConfig.CombatDamageScale or 1\n\tend\n", "")]}),
    ("a launcher's direct hit loses its impact bonus", {"ProjectileService": [(
        "\t\t\t\tamount += (blast.direct.bonus or 0) * (blast.direct.multiplier or 1)\n", "")]}),
    ("the venom boon pre-scaled before its ticks", {"CompanionBoons": [(
        "\t\tperTick = venom.damage / ticks,", "\t\tperTick = venom.damage * 0.8 / ticks,")]}),
]


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    if "--plant" in argv:
        caught = 0
        for name, swaps in PLANTS:
            rows = run(root, swaps, verbose=False)
            bad = [text for ok, text in rows if not ok]
            if bad:
                caught += 1
                print(f"  caught  {name}  -> {bad[0][:110]}")
            else:
                print(f"  MISSED  {name}")
        print(f"planted faults: {caught}/{len(PLANTS)} caught")
        return 0 if caught == len(PLANTS) else 1
    rows = run(root)
    return 1 if any(not ok for ok, _ in rows) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
