"""Behaviour check for #122 explosive ammo: hitscan bullets that go off where they stop.

Runs the real source, cut out function by function (CombatService uses Luau's `continue`, rewritten to
a goto here), in lupa against tools/hitreg_mocks.lua:

  A. WeaponData, the MERGED table (every pack: ArsenalExpansion, CreativeArsenal, WorkshopArsenal),
     loaded for real the way tools/explosive_dispatch_check.py loads it: which guns carry `explosiveAmmo`,
     and that each is small (radius 4-6 studs), well below the gun's own damage, on a hitscan gun, and
     leaves the Golden Sahur Cannon's body shot short of a kill as its comment wants.
  B. CombatService.firePellet: one blast per bullet, where it stopped (the victim, the wall behind a
     broken pane), none for a bullet that flew off into the open or broke a pane and flew on, none for
     a gun without the ammo; the blast carries the ammo's numbers, not the bullet's; the pellet
     hands its rewind instant (#97) to LagCompensation.Raycast untouched; a bullet through a
     team-mate (the mode's veto) flies on to the enemy behind them instead of stopping; and a gun with
     several pellets makes a small blast a pellet (the ammo split over the pellets, a smaller radius).
  C. ProjectileService's blast (the one launchers use) as the ammo's blast drives it: damage falls off
     with distance to a fifth at the edge and nothing past it, cover stops it, the owner takes half,
     and DestructibleService.DamageInRadius hurts each wall pool within half the radius ONCE.

    python tools/explosive_ammo_check.py .            the checks
    python tools/explosive_ammo_check.py . --plant    the planted faults; every one must be caught

Untested here: the blast's look and sound on clients (ProjectileClient "detonate", kind "impact"), and
bots, which don't trace bullets (BotService rolls against accuracy); a bot's cannon blast, launcher rounds
and team-mates, and the whole fire path are tools/explosive_dispatch_check.py's.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("explosive_ammo_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def cut(src, head):
    """A top-level function from its header to the `end` at column 0."""
    a = src.index(head)
    b = src.index("\nend\n", a) + 5
    return src[a:b]


# ---------------------------------------------------------------------------------------------- A

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import explosive_dispatch_check as dispatch  # noqa: E402  (Jacob's loader: the real WeaponData, every pack merged)


def number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def weapons(root, swaps=None):
    """Every hand gun in the merged table (WeaponData plus its packs), read from the real modules, not a
    regex over WeaponData.lua: a pack gun given explosiveAmmo is checked like a stock one. `swaps`
    ({ module: [(before, after)] }) plants a fault in the source first."""
    _, _, S = dispatch.load_world(dispatch.Tree(root, swaps))
    scale = S.module("MatchConfig").CombatDamageScale or 1
    rows = []
    examined = 0
    for gid, d in sorted(S.WD.Weapons.items()):
        examined += 1
        ammo = d.explosiveAmmo
        if ammo is None:
            continue
        splash, radius, wall = ammo.damage, ammo.radius, ammo.wallDamage
        if not (number(splash) and number(radius) and number(wall)):
            rows.append((False, "%s: explosiveAmmo not in the { damage, radius, wallDamage } shape" % gid))
            continue
        dmg = d.damage
        rows.append((d.projectile is None, "%s carries explosiveAmmo and is hitscan" % gid))
        rows.append((4 <= radius <= 6, "%s blast radius %.1f studs (4-6)" % (gid, radius)))
        rows.append((splash <= dmg * 0.25, "%s splash %.0f against a %.0f bullet (at most a quarter)" % (gid, splash, dmg)))
        rows.append((wall > 0, "%s blast damages walls (%.0f)" % (gid, wall)))
        if gid == "GoldenSahurCannon":
            total = (dmg + splash) * scale
            rows.append((total < 100, "Cannon body shot + a centre-of-blast splash = %.1f (x CombatDamageScale %s; < 100: still not a one-shot)" % (total, scale)))
    flagged = sum(1 for ok, line in rows if "carries explosiveAmmo" in line)
    rows.insert(0, (flagged > 0 and examined > 30, "WeaponData (merged, every pack): %d guns examined, %d carry explosiveAmmo" % (examined, flagged)))
    return rows


# ---------------------------------------------------------------------------------------------- B

PELLET_HARNESS = r"""
local M, block = ...
local Vector3 = M.Vector3
local blasts, dealt, rays = {}, {}, {}
local script_ = {}
local victimChar = M.character("Victim", M.CFrame.new(0, 3, -20))
local victimToken = { isBot = true }
local mateChar = M.character("Mate", M.CFrame.new(0, 3, -10))
local mateToken = { isBot = true, mate = true }
local glass = M.instance("Part", "WindowGlass", nil, {})
local wall = M.instance("Part", "Wall", nil, {})
local queue = {}
local env = setmetatable({
    PIERCE_TARGETS = 2,
    RaycastParams = M.RaycastParams,
    Enum = M.Enum,
    workspace = { FindFirstChild = function() return nil end },
    Combatants = {
        FromCharacter = function(c) return (c == victimChar and victimToken) or (c == mateChar and mateToken) or nil end,
        IsAlive = function() return true end,
        GetRoot = function() return nil end,
    },
    -- Nobody here rides a vehicle (VehicleCover: no cover to apply).
    VehicleCover = { SeatOf = function() return nil end },
    LagCompensation = { Raycast = function(origin, vector, params, at)
        table.insert(rays, at)
        return table.remove(queue, 1)
    end },
    CombatService = {
        HeadshotScale = 1,
        DestructibleFromPart = function(p) if p == glass or p == wall then return p end end,
        DestructiblePassesThrough = function(p) return p == glass end,
        DamageDestructible = function() end,
        DealDamage = function(_, token, amount) table.insert(dealt, { token = token, amount = amount }) return amount end,
        -- The mode's friendly-fire veto: the shooter's team-mate takes nothing.
        DamageVeto = function(_, token) return token == mateToken end,
        Explode = function(blast) table.insert(blasts, blast) return {} end,
    },
}, { __index = _G })
local chunk = assert(load(block .. "\nreturn firePellet", "CombatService", "t", env))
local firePellet = chunk()

local function hit(part, z)
    return { Instance = part, Position = Vector3.new(0, 3, z), Normal = Vector3.new(0, 0, 1) }
end
local out = {}
local function note(ok, line) table.insert(out, { ok = ok, line = line }) end
local shooter = { __player = true }
local origin, dir = Vector3.new(0, 4.5, 0), Vector3.new(0, 0, -1)
local function shot(def, results, rewindTo)
    for k in pairs(blasts) do blasts[k] = nil end
    for k in pairs(rays) do rays[k] = nil end
    queue = results
    firePellet(shooter, {}, origin, dir, def, rewindTo)
    return blasts
end

local cannon = { id = "GoldenSahurCannon", damage = 92, range = 700, explosiveAmmo = { damage = 12, radius = 5, wallDamage = 60 } }
local pistol = { id = "SahurPistol", damage = 22, range = 250 }
local body = victimChar:FindFirstChild("UpperTorso")

local b = shot(cannon, { hit(body, -19.5) }, 7.25)
note(#b == 1 and b[1].position.Z == -19.5 and b[1].owner == shooter and b[1].weaponId == "GoldenSahurCannon",
    string.format("cannon bullet into a player: %d blast(s), at the hit point, credited to the shooter", #b))
note(#b == 1 and b[1].damage == 12 and b[1].radius == 5 and b[1].wallDamage == 60,
    string.format("the blast carries the ammo's numbers (damage %s, radius %s, walls %s), not the bullet's 92", tostring(b[1] and b[1].damage), tostring(b[1] and b[1].radius), tostring(b[1] and b[1].wallDamage)))
note(rays[1] == 7.25, "the pellet hands its rewind instant to LagCompensation.Raycast untouched: " .. tostring(rays[1]))
b = shot(cannon, { hit(glass, -10), hit(wall, -30) })
note(#b == 1 and b[1].position.Z == -30, string.format("through a pane into a wall: %d blast(s), at the wall (z %s)", #b, tostring(b[1] and b[1].position.Z)))
b = shot(cannon, { hit(glass, -10) })
note(#b == 0, string.format("through a pane and off into the open: %d blast(s)", #b))
b = shot(cannon, {})
note(#b == 0, string.format("a miss into the sky: %d blast(s)", #b))
b = shot(pistol, { hit(body, -19.5) })
note(#b == 0, string.format("a gun without explosive ammo: %d blast(s)", #b))
-- A team-mate between the shooter and an enemy: the bullet passes them (the veto) and hits the enemy.
for k in pairs(dealt) do dealt[k] = nil end
shot(pistol, { hit(mateChar:FindFirstChild("UpperTorso"), -10), hit(body, -19.5) })
local toMate, toEnemy = 0, 0
for _, d in ipairs(dealt) do
    if d.token == mateToken then toMate = toMate + 1 elseif d.token == victimToken then toEnemy = toEnemy + 1 end
end
note(toEnemy == 1 and toMate == 0, string.format("a shot through a team-mate hits the enemy behind (enemy %d hit(s), mate %d)", toEnemy, toMate))
local total = 0
for _ = 1, 8 do total = total + #shot(cannon, { hit(wall, -30) }) end
note(total == 8, string.format("eight bullets into a wall: %d blasts (one each)", total))
-- Many pellets (Oliver, 2026-09-25): each pellet's blast is small, the ammo split over the pellets and a
-- smaller radius (never under 2 studs). firePellet runs once a pellet, so this is one pellet's blast.
local shotgun = { id = "ProbeShotgun", damage = 10, range = 100, pellets = 4, explosiveAmmo = cannon.explosiveAmmo }
b = shot(shotgun, { hit(wall, -30) })
note(#b == 1 and b[1].damage * 4 == 12 and b[1].wallDamage * 4 == 60 and b[1].radius >= 2 and b[1].radius < 5,
    string.format("a 4-pellet gun on the cannon's ammo: each pellet's blast damage %s, walls %s, radius %s (12, 60, 5 split over 4, smaller, at least 2)",
        tostring(b[1] and b[1].damage), tostring(b[1] and b[1].wallDamage), tostring(b[1] and b[1].radius)))
return out
"""


def pellet_source(root, src=None):
    src = src or read(root, "ServerScriptService", "Modules", "CombatService.lua")
    parts = [
        cut(src, "local function buildRaycastParams("),
        cut(src, "local function fireAbility("),
        # BulletBlast with the pellet-blast constants above it.
        cut(src, "local PELLET_BLAST_RADIUS_SCALE"),
        cut(src, "local function bulletBlast("),
        cut(src, "local function strikeBody("),
        cut(src, "local function firePellet("),
    ]
    block = luau_to_lua("\n".join(parts))
    # Luau's `continue` -> a goto to the end of the while body (the only loop in firePellet).
    loop_end = "\t\tend\n\tend\n\n\tif stopped then"
    if loop_end not in block:
        sys.exit("explosive_ammo_check: firePellet's loop end moved; update the harness")
    block = block.replace(loop_end, "\t\tend\n\t\t::continue_::\n\tend\n\n\tif stopped then")
    block = re.sub(r"^(\s*)continue$", r"\1goto continue_", block, flags=re.M)
    return block


def pellets(root, src=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(read(root, "tools", "hitreg_mocks.lua"))
    run = lua.execute("return function(...) " + PELLET_HARNESS + " end")
    rows = run(mocks, pellet_source(root, src))
    return [(bool(r["ok"]), r["line"]) for r in rows.values()]


# ---------------------------------------------------------------------------------------------- C

BLAST_HARNESS = r"""
local M, projectile, ballistics, destructible, damage, radius, wallDamage = ...
math.clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local Vector3 = M.Vector3
M.walls = {}
rawget(M.workspace, "_props").Raycast = function(_, origin, vector, params)
    -- clearLine's world: only the walls (its Include filter is the map)
    local best, part = math.huge, nil
    for _, w in ipairs(M.walls) do
        local o = w.CFrame:PointToObjectSpace(origin)
        local d = w.CFrame:VectorToObjectSpace(vector)
        local lo, hi, ok = 0, 1, true
        for _, a in ipairs({ "X", "Y", "Z" }) do
            local h = w.Size[a] / 2
            if math.abs(d[a]) < 1e-12 then
                if math.abs(o[a]) > h then ok = false end
            else
                local t1, t2 = (-h - o[a]) / d[a], (h - o[a]) / d[a]
                lo, hi = math.max(lo, math.min(t1, t2)), math.min(hi, math.max(t1, t2))
                if lo > hi then ok = false end
            end
        end
        if ok and lo < best then best, part = lo, w end
    end
    if not part then return nil end
    return { Instance = part, Position = origin + vector * best }
end
local map = M.instance("Folder", "Map", M.workspace)
local poolParts = {}
rawget(M.workspace, "_props").FindFirstChild = function(_, name) if name == "Map" then return map end end
rawget(M.workspace, "_props").GetPartBoundsInRadius = function(_, position, r)
    local found = {}
    for _, p in ipairs(poolParts) do
        if (p.CFrame.Position - position).Magnitude <= r then table.insert(found, p) end
    end
    return found
end
rawget(M.workspace, "_props").Terrain = {}

local dealt, poolHits = {}, {}
local victims = {}
local owner = { name = "owner" }
local Ballistics = assert(load("local Ballistics = {}\n" .. ballistics .. "\nreturn Ballistics", "Ballistics", "t", _G))()
local DestructibleService = { GlassName = "WindowGlass" }
DestructibleService.Damage = function(part, amount) poolHits[part.pool] = (poolHits[part.pool] or 0) + 1 end
DestructibleService.ClearCoverInRadius = function() end
-- DamageInRadius's file-level upvalues (d370e62 on): ROOTS is the real table, cut from the file with the
-- function; nothing here is big enough to be cut into tiles, and no part is the map's own structure.
local denv = setmetatable({
    DestructibleService = DestructibleService,
    keyOf = function(part) return part.pool end,
    craterAt = function() end,
    subdividable = function() return false end,
    subdivide = function() return nil end,
    tileAt = function() return nil, math.huge end,
    entryFor = function() return nil end,
    STRUCTURE = { blast = 1 },
    OverlapParams = { new = function() return {} end },
    Enum = M.Enum, workspace = M.workspace,
}, { __index = _G })
assert(load(destructible, "DestructibleService", "t", denv))()
local env = setmetatable({
    Vector3 = Vector3, Enum = M.Enum, workspace = M.workspace,
    RaycastParams = M.RaycastParams, RunService = { IsRunning = function() return false end },
    OverlapParams = { new = function() return {} end },
    Ballistics = Ballistics, DestructibleService = DestructibleService,
    SafeValue = { Vector3 = function() return true end },
    MovementService = { Launch = function() end },
    VehicleService = {},
    VehicleCover = { BlastShareFor = function() return 1 end },
    Combatants = { Exists = function() return true end },
    CombatService = {
        InRadius = function(position, r)
            local found = {}
            for _, v in ipairs(victims) do
                if (v.root.Position - position).Magnitude <= r then table.insert(found, v) end
            end
            return found
        end,
        DealDamage = function(_, token, amount) dealt[token] = amount return amount end,
        DamageDestructiblesInRadius = DestructibleService.DamageInRadius,
    },
    live = {}, fx = {},
}, { __index = _G })
local explode = assert(load(projectile .. "\nreturn explode", "ProjectileService", "t", env))()

local out = {}
local function note(ok, line) table.insert(out, { ok = ok, line = line }) end
local function victim(name, x, token)
    local character, root = M.character(name, M.CFrame.new(x, 3, 0))
    rawset(root._props, "AssemblyLinearVelocity", Vector3.new(0, 0, 0))
    local v = { token = token or { name = name }, humanoid = { Health = 100 }, root = root }
    table.insert(victims, v)
    return v
end
local function blast(position)
    for k in pairs(dealt) do dealt[k] = nil end
    for k in pairs(poolHits) do poolHits[k] = nil end
    return explode({ owner = owner, weaponId = "GoldenSahurCannon", kind = "impact", position = position,
        normal = Vector3.new(0, 0, 0), damage = damage, radius = radius, innerRadius = 0, wallDamage = wallDamage })
end

-- Falloff: victims on a line at growing distances from the blast (root at y 3, blast at y 3).
local distances = { 0.5, 2, 3.5, 5, radius + 1.2, radius + 2 }
local line = {}
for i, d in ipairs(distances) do line[i] = victim("V" .. i, d) end
blast(Vector3.new(0, 3, 0))
local amounts, falling = {}, true
for i, v in ipairs(line) do
    amounts[i] = dealt[v.token] or 0
    if i > 1 and amounts[i] > amounts[i - 1] + 1e-9 then falling = false end
end
local function expected(d)
    return damage * Ballistics.BlastScale(math.max(0, d - Ballistics.BodyAllowance), 0, radius)
end
local exact = true
for i, d in ipairs(distances) do
    if math.abs(amounts[i] - expected(d)) > 1e-6 then exact = false end
end
note(falling and exact, string.format("splash by distance %s: %s", table.concat(distances, "/"),
    table.concat((function() local t = {} for i = 1, #amounts do t[i] = string.format("%.2f", amounts[i]) end return t end)(), " / ")))
note(amounts[1] == damage, string.format("point blank takes the full %s", tostring(damage)))
note(math.abs(amounts[5] - damage * Ballistics.EdgeScale) < 1e-6, string.format("the edge takes a fifth (%.2f)", amounts[5]))
note(amounts[6] == 0, "past the edge takes nothing")
for i = #victims, 1, -1 do table.remove(victims, i) end

-- Cover: a wall between the blast and a victim 3 studs away stops all of it.
local behind = victim("Behind", 3)
table.insert(M.walls, M.instance("Part", "Wall", nil, { CanCollide = true, Size = Vector3.new(0.5, 20, 20), CFrame = M.CFrame.new(1.5, 3, 0) }))
blast(Vector3.new(0, 3, 0))
note((dealt[behind.token] or 0) == 0, "a victim behind a wall takes " .. tostring(dealt[behind.token] or 0))
M.walls = {}
for i = #victims, 1, -1 do table.remove(victims, i) end

-- The owner, standing in their own blast, takes half.
local me = victim("Owner", 0.5, owner)
blast(Vector3.new(0, 3, 0))
note(math.abs((dealt[owner] or 0) - damage * 0.5) < 1e-6, string.format("the shooter in their own blast takes %.2f (half)", dealt[owner] or 0))
for i = #victims, 1, -1 do table.remove(victims, i) end

-- Walls: pool A is three parts near the centre, B one part near it, C one part past half the radius.
local function poolPart(pool, x)
    local p = M.instance("Part", "Brick", map, { Size = Vector3.new(1, 1, 1), CFrame = M.CFrame.new(x, 3, 0) })
    rawset(p._props, "pool", pool)
    table.insert(poolParts, p)
end
poolPart("A", 0.5) poolPart("A", 1.0) poolPart("A", 1.5) poolPart("B", -1.0) poolPart("C", radius * 0.5 + 1)
blast(Vector3.new(0, 3, 0))
note(poolHits.A == 1 and poolHits.B == 1 and poolHits.C == nil,
    string.format("wall pools hit: A (3 parts) %s, B %s, C (past half the radius) %s -- each once, %d parts examined",
        tostring(poolHits.A or 0), tostring(poolHits.B or 0), tostring(poolHits.C or 0), #poolParts))
return out
"""


def blast_sources(root, psrc=None, bsrc=None, dsrc=None):
    psrc = psrc or read(root, "ServerScriptService", "Modules", "ProjectileService.lua")
    consts = "\n".join(re.findall(r"^local [A-Z_, ]+ = [-\w., ]+$", psrc, re.M))
    consts = consts.replace("Vector3.yAxis", "Vector3.new(0, 1, 0)")
    exposure_params = psrc[psrc.index("local exposureParams = RaycastParams.new()"):psrc.index("local function exposureFilter(")]
    fns = [cut(psrc, "local function " + name + "(") for name in
           ("broadcast", "creditable", "exposureFilter", "clearLine", "exposure", "glassInRadius", "kickBodies", "explode")]
    projectile = luau_to_lua(consts + "\n" + exposure_params + "\n" + "\n".join(fns))
    bsrc = bsrc or read(root, "ReplicatedStorage", "Shared", "Ballistics.lua")
    ballistics = "\n".join(re.findall(r"^Ballistics\.(?:BodyAllowance|EdgeScale) = [\d.]+$", bsrc, re.M))
    ballistics += "\n" + cut(bsrc, "function Ballistics.BlastScale(")
    dsrc = dsrc or read(root, "ServerScriptService", "Modules", "DestructibleService.lua")
    roots = re.search(r"^local ROOTS = .+$", dsrc, re.M)
    if not roots:
        sys.exit("explosive_ammo_check: DestructibleService's ROOTS moved; update the harness")
    destructible = luau_to_lua(roots.group(0) + "\n" + cut(dsrc, "function DestructibleService.DamageInRadius("))
    return projectile, ballistics, destructible


def blasts(root, ammo=(12, 5, 60), **sources):
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(read(root, "tools", "hitreg_mocks.lua"))
    run = lua.execute("return function(...) " + BLAST_HARNESS + " end")
    rows = run(mocks, *blast_sources(root, **sources), *ammo)
    return [(bool(r["ok"]), r["line"]) for r in rows.values()]


def cannon_ammo(root):
    _, _, S = dispatch.load_world(dispatch.Tree(root))
    ammo = S.WD.Get("GoldenSahurCannon").explosiveAmmo
    return (ammo.damage, ammo.radius, ammo.wallDamage) if ammo is not None else (12, 5, 60)


def all_rows(root, weapon_swaps=None, combat=None, **sources):
    return weapons(root, weapon_swaps) + pellets(root, combat) + blasts(root, cannon_ammo(root), **sources)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        cs = read(root, "ServerScriptService", "Modules", "CombatService.lua")
        ps = read(root, "ServerScriptService", "Modules", "ProjectileService.lua")
        bs = read(root, "ReplicatedStorage", "Shared", "Ballistics.lua")
        ds = read(root, "ServerScriptService", "Modules", "DestructibleService.lua")

        def swap(text, before, after):
            if text.count(before) != 1:
                sys.exit("explosive_ammo_check: plant target missing or not unique: " + before)
            return text.replace(before, after, 1)

        plants = [
            ("a big blast (radius 12)", dict(weapon_swaps={"WeaponData": [("radius = 5, wallDamage", "radius = 12, wallDamage")]})),
            ("splash as big as the bullet", dict(weapon_swaps={"WeaponData": [("explosiveAmmo = { damage = 12,", "explosiveAmmo = { damage = 92,")]})),
            # A pack gun (not in WeaponData.lua) given a big blast: the old regex over WeaponData.lua never saw it.
            ("a pack gun with a big blast", dict(weapon_swaps={"CreativeArsenal": [(
                "\t\tkillEffect = \"confetti\",\n\t\tdescription = \"A chunky bath-toy pistol",
                "\t\tkillEffect = \"confetti\",\n\t\texplosiveAmmo = { damage = 12, radius = 12, wallDamage = 60 },\n\t\tdescription = \"A chunky bath-toy pistol")]})),
            ("a multi-pellet gun's blasts each full size", dict(combat=swap(cs, "\tif pellets > 1 then\n\t\treturn {", "\tif false then\n\t\treturn {"))),
            ("the blast takes the bullet's damage", dict(combat=swap(cs, "damage = ammo.damage,", "damage = def.damage,"))),
            ("a pane counts as where the bullet stopped", dict(combat=swap(
                cs,
                "DestructiblePassesThrough(result.Instance) then\n\t\t\t\tlocal filter = params.FilterDescendantsInstances\n"
                "\t\t\t\ttable.insert(filter, result.Instance)\n\t\t\t\tparams.FilterDescendantsInstances = filter\n"
                "\t\t\t\tcurrentOrigin = result.Position + direction * 0.05\n\t\t\t\tstopped = nil\n",
                "DestructiblePassesThrough(result.Instance) then\n\t\t\t\tlocal filter = params.FilterDescendantsInstances\n"
                "\t\t\t\ttable.insert(filter, result.Instance)\n\t\t\t\tparams.FilterDescendantsInstances = filter\n"
                "\t\t\t\tcurrentOrigin = result.Position + direction * 0.05\n"))),
            ("a blast for every gun", dict(combat=swap(cs, "if not ammo or not CombatService.Explode then", "ammo = ammo or { damage = 1, radius = 1 }\n\tif not CombatService.Explode then"))),
            ("the rewind instant dropped", dict(combat=swap(cs, "params, rewindTo)\n\t\tif not result", "params, nil)\n\t\tif not result"))),
            ("no falloff", dict(bsrc=swap(bs, "return 1 - t * (1 - Ballistics.EdgeScale)", "return 1"))),
            ("cover ignored", dict(psrc=swap(ps, "if not passable then\n\t\t\treturn false", "if false then\n\t\t\treturn false"))),
            ("a pool hit once per part", dict(dsrc=swap(ds, "\t\t\tseen[key] = true\n", ""))),
            ("a team-mate soaks the bullet", dict(combat=swap(
                cs, "if CombatService.DamageVeto and CombatService.DamageVeto(shooterToken, victimToken, def.id) then",
                "if false then"))),
        ]
        caught = 0
        for name, kw in plants:
            rows = all_rows(root, **kw)
            failed = [line for ok, line in rows if not ok]
            print(("CAUGHT  " if failed else "MISSED  ") + name + (("  <- " + failed[0]) if failed else ""))
            caught += bool(failed)
        print("explosive_ammo_check plants: %d of %d caught" % (caught, len(plants)))
        sys.exit(0 if caught == len(plants) else 1)
    rows = all_rows(root)
    for ok, line in rows:
        print(("ok    " if ok else "FAIL  ") + line)
    failed = sum(1 for ok, _ in rows if not ok)
    print("explosive_ammo_check: %d checks, %d failed" % (len(rows), failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
