"""#122 explosive ammo, end to end: does every gun that should explode reach the blast?

Runs the game's REAL modules in lupa (tools/explosive_dispatch_world.lua): CombatService, ProjectileService
and VehicleWeapons are loaded whole, with the real WeaponData (every pack merged), Ballistics (with
CreativeRounds), VehicleWeaponData (with MountedGunData merged), VehicleCover and MatchConfig. A blast is
counted where every blast in the game announces itself: ProjectileService's explode() broadcasts
"detonate" before it deals any damage.

  A. Inventory. Every hand gun and every vehicle or emplacement gun is examined. A gun PROMISES a blast
     when its data says so (ability "explosive", explosiveAmmo, splashRadius, a streak `collect` blast) or
     its name or description does (explode, explosive, blast, detonate, "go off", cannon, mortar, rocket,
     grenade, launcher). Each promise must have a ROUTE to the blast: a hitscan gun through
     CombatService.BulletBlast (the real function decides), a launcher through a Ballistics round that is
     not `explosive = false`, a `collect` gun through its streak payout. A name that promises without a
     route has to be in REVIEWED below, with the reason; a stale REVIEWED entry fails too.
  B. Hand guns through the real CombatService.Fire, table-driven over every gun A flagged, at: an enemy,
     a wall, bare map (terrain), a vehicle's hull, a pane with open air behind, a pane with a wall behind,
     a team-mate in front of an enemy, a team-mate alone, the open sky, and (solo) a body in front with no
     friendly-fire veto at all, as in the battle royale. Then stepped through the real ProjectileService
     until every round has gone off. A bullet AND a round fly on through a team-mate (efccfa5; rounds since
     pc/explosive-followups): at the enemy behind, and a team-mate alone is the open sky. With no veto the
     round still stops on the body, as before. A streak gun (`collect`) is fired `every` - 1 and `every`
     times at a target that lives through it: no blast, then one.
  C. The blast's rules on the real explode(): the struck enemy and a neighbour take splash, a team-mate
     beside the enemy takes none (the mode's veto, stood in for here as "same team"), the shooter beside a
     wall they shoot takes half.
  D. Vehicle and emplacement guns through the real VehicleWeapons.Fire, every spec.
  E. Bots: BotService's own shootAt (cut from the real file) for every flagged gun a bot may hold
     (BotService.Loot.usable, also cut from the real file). A bot's hitscan HIT with explosive ammo sets off
     one blast a pellet on the target (Oliver, 2026-09-25), a MISS none.
  F. Many pellets: the real BulletBlast splits a multi-pellet gun's blast (damage and wall damage over the
     pellets, a smaller radius, never under 2 studs) and leaves a one-pellet gun's alone; a test shotgun
     (the cannon's ammo on 4 pellets, added for this run only) fired at a wall makes 4 small blasts.

    python tools/explosive_dispatch_check.py .            the checks
    python tools/explosive_dispatch_check.py . --plant    the planted faults; every one must be caught

Not covered: the blast's look and sound on clients, lag compensation (rewind is off here), and a live
server. The world is boxes: a character is the hitreg_mocks body, the ground a slab, a wall a box.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime, LuaError
except ImportError:
    sys.exit("explosive_dispatch_check: needs lupa (pip install lupa)")

HERE = os.path.dirname(os.path.abspath(__file__))

# Names that sound explosive but carry no blast, each checked by a person against the gun's own text.
REVIEWED = {
    "PartyFoulCannon": "a party popper: 'corks, confetti and a shove'; no blast promised (staged, weight 0)",
    "FidgetDiscLauncher": "throws a spinner that 'glances off the first wall'",
    "GrandmasSlipperLauncher": "throws a homing slipper; hits, does not burst",
}

PROMISE_TEXT = re.compile(r"explo|\bblast(s|ed|ing)?\b|detonat|\bgoes? off\b|\bblows? up\b", re.I)
PROMISE_NAME = re.compile(r"cannon|mortar|rocket|grenade|launcher|\bbomb\b", re.I)


# ---------------------------------------------------------------------------------------------- Luau

def _strip(line, state):
    """The line with strings and comments blanked (keyword scanning only), and the long-bracket state."""
    out, i, n = [], 0, len(line)
    while i < n:
        if state:
            j = line.find(state, i)
            if j < 0:
                return "".join(out), state
            i, state = j + len(state), None
            continue
        if line.startswith("--", i):
            m = re.match(r"--\[(=*)\[", line[i:])
            if not m:
                break
            state, i = "]" + m.group(1) + "]", i + len(m.group(0))
            continue
        m = re.match(r"\[(=*)\[", line[i:])
        if m:
            state, i = "]" + m.group(1) + "]", i + len(m.group(0))
            out.append('""')
            continue
        c = line[i]
        if c in "\"'`":
            j = i + 1
            while j < n and line[j] != c:
                j += 2 if line[j] == "\\" else 1
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), state


def luau_to_lua(src):
    """Compound assignment and `continue` (as a goto to a label at the end of its loop)."""
    src = re.sub(r"^(\s*)([\w.\[\]\"':()]+) ([+\-*/%^]|\.\.)= (.+?)(\s*--.*)?$",
                 lambda m: "%s%s = %s %s (%s)%s" % (m.group(1), m.group(2), m.group(2), m.group(3), m.group(4), m.group(5) or ""),
                 src, flags=re.M)
    stack, state, pending, count, out = [], None, 0, 0, []
    for line in src.split("\n"):
        code, state = _strip(line, state)
        new, closes = line, []
        for t in re.findall(r"[A-Za-z_]\w*", code):
            if t == "function" or t == "if":
                stack.append([t, None])
            elif t in ("while", "for"):
                stack.append(["loop", None])
                pending += 1
            elif t == "do":
                if pending:
                    pending -= 1
                else:
                    stack.append(["do", None])
            elif t == "repeat":
                stack.append(["repeat", None])
            elif t == "continue":
                loop = next(e for e in reversed(stack) if e[0] in ("loop", "repeat"))
                if loop[1] is None:
                    count += 1
                    loop[1] = "continue_%d" % count
                new = re.sub(r"\bcontinue\b", "goto " + loop[1], new, count=1)
            elif t in ("end", "until"):
                e = stack.pop()
                if e[1]:
                    closes.append(e[1])
        for label in closes:
            new = re.sub(r"\bend\b", "::%s:: end" % label, new, count=1)
        out.append(new)
    if stack:
        raise SyntaxError("unbalanced blocks")
    return "\n".join(out)


def cut(src, head):
    """A top-level function from its header to the `end` at column 0, or a one-line definition."""
    a = src.index(head)
    if "function" not in head:
        return src[a:src.index("\n", a) + 1]
    return src[a:src.index("\nend\n", a) + 5]


# ---------------------------------------------------------------------------------------------- world

PATHS = [("ReplicatedStorage", "Shared"), ("ServerScriptService", "Modules")]
REAL = ["CombatService", "ProjectileService", "VehicleWeapons", "WeaponData", "ArsenalExpansion", "CreativeArsenal",
        "WorkshopArsenal", "CreativeRounds", "Ballistics", "SafeValue", "VehicleCover", "MatchConfig",
        "VehicleWeaponData", "MountedGunData", "MovementConfig", "ItemData", "Rarity"]


class Tree:
    """The game's text, read from `root`, with in-memory replacements (the planted faults)."""

    def __init__(self, root, swaps=None):
        self.root, self.swaps = root, swaps or {}

    def text(self, name):
        for p in PATHS:
            f = os.path.join(self.root, *p, name + ".lua")
            if os.path.exists(f):
                text = open(f, encoding="utf-8").read()
                for before, after in self.swaps.get(name, []):
                    if text.count(before) != 1:
                        sys.exit("explosive_dispatch_check: plant anchor missing or not unique in %s: %r" % (name, before[:80]))
                    text = text.replace(before, after, 1)
                return text
        return None

    def lua(self, name):
        text = self.text(name)
        return luau_to_lua(text) if text is not None else None


SCENE = r"""
local w, S, defId, case, shots, hp = ...
local M, W = w.M, w.W
local V3 = M.Vector3.new
local CS, PS = S.CS, S.PS
for k in pairs(M.walls) do M.walls[k] = nil end
local kids = rawget(M.workspace, "_children")
for k in pairs(kids) do kids[k] = nil end
for k in pairs(W.tokens) do W.tokens[k] = nil end
for k in pairs(W.humanoids) do W.humanoids[k] = nil end
for k in pairs(W.vehicleHits) do W.vehicleHits[k] = nil end
for k in pairs(w.recorders.fired) do w.recorders.fired[k] = nil end
local dealt = {}
S.dealt = dealt
PS.Clear()

local function person(name, x, z, team)
	local model, root = M.character(name, M.CFrame.new(x, 3, z))
	local token = { name = name, Character = model, team = team }
	W.tokens[model] = token
	W.humanoids[token] = M.instance("Humanoid", "Humanoid", model, { Health = hp or 100, MaxHealth = hp or 100 })
	return token, model, root
end
local function box(name, centre, size, props)
	local p = M.wall(name, centre, size)
	for k, v in pairs(props or {}) do rawget(p, "_props")[k] = v end
	return p
end

local shooter = person("Shooter", 0, 0, "A")
shooter.isPlayer = true
box("Ground", V3(0, -0.5, 0), V3(600, 1, 600))
local who = { shooter = shooter }
-- `stop`: the z of the face a straight shot along -Z at head height is expected to stop on (nil: none).
local stop = nil
if case == "enemy" then
	who.enemy = person("Enemy", 0, -30, "B"); stop = -29.4
elseif case == "wall" then
	box("Wall", V3(0, 4, -30), V3(20, 12, 1), { destructible = true }); stop = -29.5
elseif case == "terrain" then
	box("Rock", V3(0, 4, -30), V3(20, 12, 1)); stop = -29.5
elseif case == "vehicle" then
	box("Hull", V3(0, 4, -30), V3(8, 6, 12), { vehicle = true }); stop = -24
elseif case == "glass" then
	box("WindowGlass", V3(0, 4, -10), V3(20, 12, 0.2), { destructible = true, glass = true })
elseif case == "glass+wall" then
	box("WindowGlass", V3(0, 4, -10), V3(20, 12, 0.2), { destructible = true, glass = true })
	box("Wall", V3(0, 4, -30), V3(20, 12, 1), { destructible = true }); stop = -29.5
elseif case == "mate+enemy" then
	who.mate = person("Mate", 0, -15, "A"); who.enemy = person("Enemy", 0, -30, "B"); stop = -29.4
elseif case == "mate" then
	who.mate = person("Mate", 0, -15, "A")
elseif case == "solo" then
	who.other = person("Other", 0, -15, "A")
elseif case == "splash" then
	-- the enemy struck, an enemy 2 studs to their side, a team-mate 2 studs to the other side
	who.enemy = person("Enemy", 0, -30, "B"); who.near = person("Near", 2.5, -30, "B"); who.mate = person("Mate", -2.5, -30, "A"); stop = -29.4
elseif case == "self" then
	box("Wall", V3(0, 4, -2.2), V3(20, 12, 1), { destructible = true }); stop = -1.7
end

CS.DestructibleFromPart = function(p) return p.destructible and p or nil end
CS.DestructiblePassesThrough = function(p) return p.glass == true end
CS.DamageDestructible = function() end
CS.VehicleFromPart = function(p) return p.vehicle and p or nil end
CS.DamageVehicle = function(_, _, _, class, id) table.insert(W.vehicleHits, { how = class, weaponId = id }) end
CS.DamageVeto = function(a, v) return a ~= nil and a ~= v and a.team ~= nil and a.team == v.team end
-- solo: the battle royale hangs no veto at all (GameMode clears it), so nobody is a team-mate.
if case == "solo" then CS.DamageVeto = nil end
CS.SpreadFor = function() return 0 end
CS.DamageListeners = { function(a, v, amount, weaponId) table.insert(dealt, { a = a, v = v, amount = amount, weaponId = weaponId }) end }
CS.SetEnabled(true)

local def = S.WD.Get(defId)
W.equipped = def
w.loadout.fireCredit, w.loadout.lastShotAt, w.loadout.reloading = 2, 0, nil
w.now.t = w.now.t + 10
-- Head height, dead ahead; the splash case aims at the chest so the struck enemy takes a body shot.
-- `shots` in a row, a quarter-second apart (a streak gun's payout needs several).
for _ = 1, shots or 1 do
	w.loadout.fireCredit, w.loadout.lastShotAt = 2, 0
	CS.Fire(shooter, case == "splash" and V3(0, 3.4, -30) or V3(0, 4.8, -60))
	w.now.t = w.now.t + 0.25
end
for _ = 1, 480 do
	w.now.t = w.now.t + 1 / 60
	PS.Step(1 / 60)
end

local blasts = {}
for _, f in ipairs(w.recorders.fired) do
	if f.action == "detonate" then
		table.insert(blasts, { x = f.info.position.X, y = f.info.position.Y, z = f.info.position.Z, kind = f.info.kind, radius = f.info.radius })
	end
end
local took = {}
for _, d in ipairs(dealt) do
	for role, token in pairs(who) do
		if d.v == token then took[role] = (took[role] or 0) + d.amount end
	end
end
local vehicle = {}
for _, h in ipairs(W.vehicleHits) do table.insert(vehicle, h.how) end
return { blasts = blasts, stop = stop, took = took, hits = #dealt, vehicle = table.concat(vehicle, "+") }
"""

VEHICLE_SCENE = r"""
local w, S, key = ...
local M, W = w.M, w.W
local V3 = M.Vector3.new
local CS, PS, VW, VWD = S.CS, S.PS, S.VW, S.VWD
for k in pairs(M.walls) do M.walls[k] = nil end
local kids = rawget(M.workspace, "_children")
for k in pairs(kids) do kids[k] = nil end
for k in pairs(W.tokens) do W.tokens[k] = nil end
for k in pairs(w.recorders.fired) do w.recorders.fired[k] = nil end
PS.Clear()
local model = M.character("Gunner", M.CFrame.new(12, 3, 0))
local gunner = { name = "Gunner", Character = model, team = "A" }
W.tokens[model] = gunner
W.humanoids[gunner] = M.instance("Humanoid", "Humanoid", model, { Health = 100, MaxHealth = 100 })
M.wall("Ground", V3(0, -0.5, 0), V3(600, 1, 600))
local wall = M.wall("Wall", V3(0, 4, -40), V3(40, 20, 1))
rawget(wall, "_props").destructible = true
local vehicle = M.instance("Model", "Vehicle", M.workspace, {})
local names = VWD.Parts.turret
M.instance("Part", names.yaw, vehicle, { CFrame = M.CFrame.new(0, 5, 0), Size = V3(1, 1, 1) })
M.instance("Part", names.pitch, vehicle, { CFrame = M.CFrame.new(0, 5.5, 0), Size = V3(1, 1, 1) })
M.instance("Part", names.muzzle, vehicle, { CFrame = M.CFrame.new(0, 5.5, -3), Size = V3(0.2, 0.2, 0.2) })
local spec = VWD.Weapons[key]
VW.DrivenBy = function() return vehicle, spec, model, W.humanoids[gunner], "turret" end
CS.DestructibleFromPart = function(p) return p.destructible and p or nil end
CS.DestructiblePassesThrough = function() return false end
CS.DamageDestructible = function() end
CS.SetEnabled(true)
w.now.t = w.now.t + 60
local ok, why = VW.Fire(gunner, V3(0, 5.5, -40))
for _ = 1, 480 do
	w.now.t = w.now.t + 1 / 60
	PS.Step(1 / 60)
end
local blasts = {}
for _, f in ipairs(w.recorders.fired) do
	if f.action == "detonate" then
		table.insert(blasts, { z = f.info.position.Z, radius = f.info.radius })
	end
end
return { ok = ok, why = why, blasts = blasts }
"""

BOT_SCENE = r"""
local w, S, shootAt, defId, roll, env = ...
local M, W = w.M, w.W
local V3 = M.Vector3.new
local PS = S.PS
for k in pairs(M.walls) do M.walls[k] = nil end
local kids = rawget(M.workspace, "_children")
for k in pairs(kids) do kids[k] = nil end
for k in pairs(W.tokens) do W.tokens[k] = nil end
for k in pairs(w.recorders.fired) do w.recorders.fired[k] = nil end
PS.Clear()
M.wall("Ground", V3(0, -0.5, 0), V3(600, 1, 600))
local model, root = M.character("Bot", M.CFrame.new(0, 3, 0))
local bot = { name = "Bot", Character = model, team = "A", weapon = S.WD.Get(defId), nextShotAt = 0, burstLeft = 3, acquiredAt = 0 }
W.tokens[model] = bot
W.humanoids[bot] = M.instance("Humanoid", "Humanoid", model, { Health = 100, MaxHealth = 100 })
local tmodel, troot = M.character("Target", M.CFrame.new(0, 3, -30))
local target = { name = "Target", Character = tmodel, team = "B" }
W.tokens[tmodel] = target
W.humanoids[target] = M.instance("Humanoid", "Humanoid", tmodel, { Health = 100, MaxHealth = 100 })
local hits = 0
S.CS.DealDamage = function() hits = hits + 1 return 1 end
env.roll.v = roll or 0.01
w.now.t = w.now.t + 60
shootAt(bot, target, troot, 30, model:FindFirstChild("Head"))
for _ = 1, 480 do
	w.now.t = w.now.t + 1 / 60
	PS.Step(1 / 60)
end
local blasts, zs = 0, {}
for _, f in ipairs(w.recorders.fired) do
	if f.action == "detonate" then blasts = blasts + 1; table.insert(zs, f.info.position.Z) end
end
return { blasts = blasts, hits = hits, zs = zs }
"""


def bot_source(tree):
    """shootAt and the rules that pick which guns a bot may hold, cut from the real BotService."""
    src = tree.text("BotService")
    parts = [
        "local BotService = { Loot = {} }",
        cut(src, "local BOT_WEAPON_HOLD = {"),
        cut(src, "local BOT_PROJECTILE_KINDS = {"),
        "local BOT_HEADSHOT_CHANCE = 0.12",
        cut(src, "local AIM_SETTLE_DELAY ="),
        cut(src, "local function accuracyAt("),
        cut(src, "local function shootAt("),
        cut(src, "function BotService.Loot.usable("),
        "return shootAt, BotService.Loot.usable",
    ]
    return luau_to_lua("\n".join(parts))


BOT_ENV = r"""
local w, S, block = ...
local proxy = w.proxy
-- The dice: every roll comes out at `roll.v` (0.01, a hit; 0.99, a miss), and a ranged roll at its low end.
local roll = { v = 0.01 }
local env = setmetatable({
	CombatService = S.CS,
	MatchConfig = S.module("MatchConfig"),
	VehicleCover = S.module("VehicleCover"),
	lazy = function(name) if name == "ProjectileService" then return S.PS end return nil end,
	hostile = function() return true end,
	coverBetween = function() return nil end,
	magazineOf = function() return nil end,
	startReload = function() end,
	STATS = setmetatable({}, { __index = function() return 0 end }),
	ARCH = { dialsOf = function() return { burst = { 3, 3 }, restScale = 1, aimLow = false } end },
	tick = function() return w.now.t end,
	-- the question is where a hit (or a miss) goes, not how often a bot lands one
	math = setmetatable({ random = function(a, b) if a then return a end return roll.v end }, { __index = math }),
	roll = roll,
}, { __index = function(_, k) local v = _G[k] if v ~= nil then return v end return proxy(k) end })
local shootAt, usable = assert(load(block, "BotService", "t", env))()
return shootAt, usable, env
"""


def load_world(tree):
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(open(os.path.join(HERE, "hitreg_mocks.lua"), encoding="utf-8").read())
    world = lua.execute("return function(...) " + open(os.path.join(HERE, "explosive_dispatch_world.lua"), encoding="utf-8").read() + " end")
    w = world(mocks, tree.lua, lua.table_from(REAL), lua.globals().load)
    S = lua.table()
    S.module = w.module
    S.CS = w.module("CombatService")
    S.PS = w.module("ProjectileService")
    S.VW = w.module("VehicleWeapons")
    S.WD = w.module("WeaponData")
    S.B = w.module("Ballistics")
    S.VWD = w.module("VehicleWeaponData")
    return lua, w, S


def pyval(v):
    if hasattr(v, "items"):
        return {k: pyval(x) for k, x in v.items()}
    return v


# ---------------------------------------------------------------------------------------------- A

def inventory(S):
    rows, hand, vehicle = [], [], []
    rounds = S.B.Rounds
    for gid, d in S.WD.Weapons.items():
        name, desc = d.name or gid, d.description or ""
        round_ = rounds[d.projectile] if d.projectile else None
        if d.projectile:
            route = "round" if round_ is not None and round_.explosive is not False else None
        else:
            route = "bullet" if S.CS.BulletBlast(d) is not None else None
        if route is None and d.collect is not None:
            route = "streak"
        data_promise = d.ability == "explosive" or d.explosiveAmmo is not None or d.splashRadius is not None or d.collect is not None
        text_promise = bool(PROMISE_TEXT.search(desc) or PROMISE_TEXT.search(name))
        name_promise = bool(PROMISE_NAME.search(name) or PROMISE_NAME.search(gid))
        hand.append(dict(id=gid, route=route, data=data_promise, text=text_promise, name=name_promise,
                         projectile=d.projectile, pellets=d.pellets or 1, staged=bool(d.staged)))
        if d.explosiveAmmo is not None and d.projectile:
            rows.append((False, "%s carries explosiveAmmo on a launcher: Fire hands it to ProjectileService, which never reads it" % gid))
    for key, spec in S.VWD.Weapons.items():
        round_ = rounds[spec.projectile] if spec.projectile else None
        route = "round" if spec.kind == "round" and round_ is not None and round_.explosive is not False else None
        promise = spec.kind == "round" or spec.splashRadius is not None or bool(PROMISE_NAME.search(str(spec.id)) or PROMISE_NAME.search(key))
        vehicle.append(dict(id=key, route=route, promise=promise, kind=spec.kind))
        if spec.explosiveAmmo is not None:
            rows.append((False, "vehicle gun %s carries explosiveAmmo: VehicleWeapons' traceBullet never reads it" % key))

    for g in sorted(hand, key=lambda g: g["id"]):
        if g["route"]:
            continue
        if g["data"] or g["text"]:
            rows.append((False, "%s promises a blast (data or description) and nothing routes it to one" % g["id"]))
        elif g["name"] and g["id"] not in REVIEWED:
            rows.append((False, "%s has an explosive name and no blast, and is not in REVIEWED" % g["id"]))
    for gid in REVIEWED:
        g = next((g for g in hand if g["id"] == gid), None)
        if g is None or g["route"] or not g["name"]:
            rows.append((False, "REVIEWED entry %s is stale (gone, renamed, or now has a blast)" % gid))
    for v in vehicle:
        if v["promise"] and not v["route"]:
            rows.append((False, "vehicle gun %s promises a blast and has no explosive round" % v["id"]))

    flagged = [g for g in hand if g["route"]]
    vflagged = [v for v in vehicle if v["route"]]
    rows.insert(0, (len(flagged) > 0,
                    "inventory: %d hand guns examined, %d route to a blast (%s); %d vehicle/emplacement guns examined, %d fire explosive rounds (%s)"
                    % (len(hand), len(flagged), ", ".join("%s:%s" % (g["id"], g["route"]) for g in sorted(flagged, key=lambda g: g["id"])),
                       len(vehicle), len(vflagged), ", ".join(sorted(v["id"] for v in vflagged)))))
    return rows, hand, vehicle


# ---------------------------------------------------------------------------------------------- B, C

CASES = ["enemy", "wall", "terrain", "vehicle", "glass", "glass+wall", "mate+enemy", "mate", "sky", "solo"]


def hand_guns(lua, w, S, hand):
    scene = lua.execute("return function(...) " + SCENE + " end")
    rows, table_ = [], {}
    for g in sorted(hand, key=lambda g: g["id"]):
        if g["route"] not in ("bullet", "round"):
            continue
        d = S.WD.Get(g["id"])
        try:
            results = {case: pyval(scene(w, S, g["id"], case)) for case in CASES}
        except LuaError as e:
            rows.append((False, "%s: the fire path errored: %s" % (g["id"], str(e).splitlines()[0])))
            continue
        table_[g["id"]] = results
        n = lambda case: len(results[case]["blasts"])
        want = g["pellets"]
        for case in ("enemy", "wall", "terrain", "vehicle", "glass+wall", "mate+enemy"):
            rows.append((n(case) == want, "%s -> %s: %d blast(s), want %d (one a %s)" % (g["id"], case, n(case), want, "pellet" if g["route"] == "bullet" else "round")))
        if g["route"] == "bullet":
            ammo = S.CS.BulletBlast(d)
            for case in ("enemy", "wall", "terrain", "vehicle", "glass+wall", "mate+enemy"):
                r = results[case]
                b = r["blasts"][1] if r["blasts"] else None
                ok = b is not None and abs(b["z"] - r["stop"]) < 0.05 and abs(b["x"]) < 0.05 and b["radius"] == ammo.radius
                rows.append((ok, "%s -> %s: blast at z %s (the hit point is z %.1f; muzzle z 0, target root z -30), radius %s (ammo %s)"
                             % (g["id"], case, "%.2f" % b["z"] if b else "-", r["stop"], b["radius"] if b else "-", ammo.radius)))
            r = results["vehicle"]
            rows.append((r["vehicle"] == "bullet+blast", "%s -> vehicle: the hull takes %s (the bullet, then the blast through VehicleService.BlastDamage)" % (g["id"], r["vehicle"])))
            for case in ("glass", "mate", "sky"):
                rows.append((n(case) == 0, "%s -> %s: %d blast(s) (a hitscan bullet that stops on nothing blows up nothing)" % (g["id"], case, n(case))))
        else:
            # Rounds that burst on contact: at the thing they struck.
            if S.B.Rounds[g["projectile"]].motion != "body" or S.B.Rounds[g["projectile"]].impact:
                for case in ("enemy", "wall", "terrain", "vehicle"):
                    r = results[case]
                    b = r["blasts"][1] if r["blasts"] else None
                    ok = b is not None and abs(b["z"] - r["stop"]) < 1.0 and b["radius"] == d.splashRadius
                    rows.append((ok, "%s -> %s: burst at z %s (struck face z %.1f), radius %s (splashRadius %s)"
                                 % (g["id"], case, "%.2f" % b["z"] if b else "-", r["stop"], b["radius"] if b else "-", d.splashRadius)))
            # A round flies on through its owner's team-mate (as a bullet does since efccfa5): with an enemy
            # behind, every round bursts where it does on the enemy alone; a team-mate alone is the open sky.
            zs = lambda case: sorted(round(b["z"], 1) for b in results[case]["blasts"].values())
            rows.append((zs("mate+enemy") == zs("enemy"), "%s -> mate+enemy: bursts at z %s, as at the enemy alone (z %s): the round flew on through the team-mate"
                         % (g["id"], zs("mate+enemy"), zs("enemy"))))
            rows.append((zs("mate") == zs("sky"), "%s -> mate: bursts at z %s, as into the open sky (z %s): the team-mate stops nothing"
                         % (g["id"], zs("mate"), zs("sky"))))
            # No veto (the battle royale): the body in front stops the round, as it always has (it stands at z -15).
            rows.append((len(zs("solo")) > 0 and all(z > -20 for z in zs("solo")), "%s -> solo: bursts at z %s, on or before the body at z -15 (no veto: nobody is flown through)"
                         % (g["id"], zs("solo"))))
    # A streak gun (`collect`): its blast is the payout for `every` hits in a row, set on the target.
    for g in sorted(hand, key=lambda g: g["id"]):
        if g["route"] != "streak":
            continue
        spec = S.WD.Get(g["id"]).collect
        # Everyone at 1000 health, standing in for a shielded target that lives through the run.
        short = pyval(scene(w, S, g["id"], "enemy", spec.every - 1, 1000))
        full = pyval(scene(w, S, g["id"], "enemy", spec.every, 1000))
        b = full["blasts"][1] if full["blasts"] else None
        ok = len(short["blasts"]) == 0 and len(full["blasts"]) == 1 and abs(b["z"] - (-30)) < 0.05 and b["radius"] == spec.radius
        rows.append((ok, "%s: %d hits in a row -> %d blast(s); %d hits -> %d blast(s), at z %s (the target's root, z -30), radius %s (collect radius %s)"
                     % (g["id"], spec.every - 1, len(short["blasts"]), spec.every, len(full["blasts"]),
                        "%.2f" % b["z"] if b else "-", b["radius"] if b else "-", spec.radius)))
    return rows, table_


def blast_rules(lua, w, S, hand):
    scene = lua.execute("return function(...) " + SCENE + " end")
    rows = []
    scale = S.module("MatchConfig").CombatDamageScale or 1
    for g in sorted(hand, key=lambda g: g["id"]):
        if g["route"] != "bullet":
            continue
        d = S.WD.Get(g["id"])
        ammo = S.CS.BulletBlast(d)
        r = pyval(scene(w, S, g["id"], "splash"))
        took = r["took"]
        rows.append((took.get("near", 0) > 0 and took.get("mate", 0) == 0,
                     "%s splash: the enemy 2.5 studs from the struck one takes %s, a team-mate 2.5 studs the other side takes %s"
                     % (g["id"], took.get("near", 0), took.get("mate", 0))))
        body = d.damage * scale
        rows.append((body < took.get("enemy", 0) < 100,
                     "%s: the enemy struck in the chest takes %s in all: the bullet (%s x CombatDamageScale %s = %.1f) and the blast, still short of a one-shot"
                     % (g["id"], took.get("enemy", 0), d.damage, scale, body)))
        r = pyval(scene(w, S, g["id"], "self"))
        mine = r["took"].get("shooter", 0)
        rows.append((len(r["blasts"]) == 1 and 0 < mine <= round(ammo.damage * 0.5 + 0.5),
                     "%s: the shooter 1.7 studs from the wall they shoot takes %s of the blast's %s (half at most, as a launcher's owner)" % (g["id"], mine, ammo.damage)))
    return rows


# ---------------------------------------------------------------------------------------------- D

def vehicle_guns(lua, w, S, vehicle):
    scene = lua.execute("return function(...) " + VEHICLE_SCENE + " end")
    rows = []
    for v in sorted(vehicle, key=lambda v: v["id"]):
        try:
            r = pyval(scene(w, S, v["id"]))
        except LuaError as e:
            rows.append((False, "vehicle %s: VehicleWeapons.Fire errored: %s" % (v["id"], str(e).splitlines()[0])))
            continue
        n = len(r["blasts"])
        if v["route"]:
            spec = S.VWD.Weapons[v["id"]]
            b = r["blasts"][1] if n else None
            ok = r["ok"] is True and n == 1 and abs(b["z"] - (-39.5)) < 1.0 and b["radius"] == spec.splashRadius
            rows.append((ok, "vehicle %s (%s round) fired at a wall 40 studs off: fired %s, %d burst(s) at z %s, radius %s (splashRadius %s)"
                         % (v["id"], spec.projectile, r["ok"], n, "%.2f" % b["z"] if b else "-", b["radius"] if b else "-", spec.splashRadius)))
        else:
            rows.append((r["ok"] is True and n == 0, "vehicle %s (hitscan): fired %s, %d blast(s)" % (v["id"], r["ok"], n)))
    return rows


# ---------------------------------------------------------------------------------------------- E

def bots(lua, w, S, tree, hand):
    shootAt, usable, env = lua.execute("return function(...) " + BOT_ENV + " end")(w, S, bot_source(tree))
    scene = lua.execute("return function(...) " + BOT_SCENE + " end")
    rows, findings = [], []
    real_deal = S.CS.DealDamage
    try:
        for g in sorted(hand, key=lambda g: g["id"]):
            if g["route"] not in ("bullet", "round", "streak"):
                continue
            d = S.WD.Get(g["id"])
            if not usable(d):
                rows.append((True, "bot: %s is never held by a bot (BotService.Loot.usable says no)" % g["id"]))
                continue
            r = pyval(scene(w, S, shootAt, g["id"], 0.01, env))
            line = "bot: %s fired by a bot at a target 30 studs off, a certain hit: %d blast(s), %d damage call(s)" % (g["id"], r["blasts"], r["hits"])
            if g["route"] == "streak":
                rows.append((True, line + " (a streak blast needs 5 hits in a row; bots never run fireAbility)"))
            elif g["route"] == "round":
                rows.append((r["blasts"] >= 1, line))
            else:
                # A hitscan hit: one blast a pellet on the target's face toward the bot (root z -30, half a
                # stud back), as a player's shot (Oliver, 2026-09-25). A miss: none, like a shot into the open.
                zs = sorted(r["zs"].values())
                ok = r["blasts"] == g["pellets"] and all(abs(z - (-29.5)) < 0.1 for z in zs)
                rows.append((ok, line + ", want %d at z -29.5 (the target's face; root z -30): at z %s"
                             % (g["pellets"], ", ".join("%.2f" % z for z in zs) or "-")))
                miss = pyval(scene(w, S, shootAt, g["id"], 0.99, env))
                rows.append((miss["blasts"] == 0, "bot: %s fired by a bot, a certain miss: %d blast(s) (a miss blows up nothing)" % (g["id"], miss["blasts"])))
    finally:
        S.CS.DealDamage = real_deal
    return rows, findings


# ---------------------------------------------------------------------------------------------- F

PELLET_PROBE = "ExplosiveDispatchProbeShotgun"


def pellets(lua, w, S):
    """Many pellets, many small blasts (Oliver, 2026-09-25): the real BulletBlast on the cannon's ammo."""
    rows = []
    cannon = S.WD.Get("GoldenSahurCannon")
    ammo = cannon.explosiveAmmo
    one = S.CS.BulletBlast(cannon)
    rows.append((one.damage == ammo.damage and one.radius == ammo.radius and one.wallDamage == ammo.wallDamage,
                 "pellets: a one-pellet gun's blast is its ammo, untouched: damage %s, radius %s, wall %s (ammo %s, %s, %s)"
                 % (one.damage, one.radius, one.wallDamage, ammo.damage, ammo.radius, ammo.wallDamage)))
    probe = lua.execute("return function(def) local t = {} for k, v in pairs(def) do t[k] = v end return t end")(cannon)
    probe.id, probe.name, probe.spread = PELLET_PROBE, "Probe Shotgun", 0
    for n in (2, 4, 10):
        probe.pellets = n
        b = S.CS.BulletBlast(probe)
        ok = (abs(b.damage * n - ammo.damage) < 1e-6 and abs(b.wallDamage * n - ammo.wallDamage) < 1e-6
              and 2 <= b.radius < ammo.radius)
        rows.append((ok, "pellets: %d pellets -> each blast damage %s (x%d = %s), wall %s, radius %s (ammo %s, wall %s, radius %s: split over the pellets, smaller, at least 2)"
                     % (n, b.damage, n, b.damage * n, b.wallDamage, b.radius, ammo.damage, ammo.wallDamage, ammo.radius)))
    probe.pellets = 4
    S.WD.Weapons[PELLET_PROBE] = probe
    try:
        scene = lua.execute("return function(...) " + SCENE + " end")
        r = pyval(scene(w, S, PELLET_PROBE, "wall"))
    finally:
        S.WD.Weapons[PELLET_PROBE] = None
    small = S.CS.BulletBlast(probe).radius
    bl = list(r["blasts"].values())
    ok = len(bl) == 4 and all(b["radius"] == small and abs(b["z"] - r["stop"]) < 0.05 for b in bl)
    rows.append((ok, "pellets: a 4-pellet test gun on the cannon's ammo fired at a wall: %d blast(s), radius %s, at z %s (want 4, radius %s, at the face z %.1f)"
                 % (len(bl), ",".join(str(b["radius"]) for b in bl) or "-", ",".join("%.2f" % b["z"] for b in bl) or "-", small, r["stop"])))
    return rows


# ---------------------------------------------------------------------------------------------- run

def run(root, swaps=None):
    tree = Tree(root, swaps)
    lua, w, S = load_world(tree)
    rows, hand, vehicle = inventory(S)
    hrows, table_ = hand_guns(lua, w, S, hand)
    rows += hrows
    rows += blast_rules(lua, w, S, hand)
    rows += vehicle_guns(lua, w, S, vehicle)
    brows, findings = bots(lua, w, S, tree, hand)
    rows += brows
    rows += pellets(lua, w, S)
    return rows, findings, table_


PLANTS = [
    ("a new hitscan gun described as explosive, with no explosiveAmmo", {"WeaponData": [(
        "\t-- Common ------------------------------------------------------------------\n",
        "\t-- Common ------------------------------------------------------------------\n\tPlantShellPistol = { name = \"Plant Pistol\", rarity = \"Common\", style = \"pistol\", description = \"Fires explosive rounds.\", damage = 20, headshotMultiplier = 1.5, fireRate = 4, magSize = 10, reserveAmmo = 40, reloadTime = 1, range = 200, spread = 1, pellets = 1, groundWeight = 0, chestWeight = 0 },\n")]}),
    ("a new gun named Mortar with a round that does not explode", {"WeaponData": [(
        "\t-- Common ------------------------------------------------------------------\n",
        "\t-- Common ------------------------------------------------------------------\n\tPlantMortar = { name = \"Plant Mortar\", rarity = \"Common\", style = \"launcher\", damage = 20, headshotMultiplier = 1, fireRate = 1, magSize = 1, reserveAmmo = 4, reloadTime = 1, range = 200, spread = 0, pellets = 1, projectile = \"ricochetDisc\", groundWeight = 0, chestWeight = 0 },\n")]}),
    ("explosiveAmmo put on a launcher (ignored by the round path)", {"WeaponData": [(
        "\t\tprojectile = \"grenade\",\n", "\t\tprojectile = \"grenade\",\n\t\texplosiveAmmo = { damage = 5, radius = 5, wallDamage = 0 },\n")]}),
    ("firePellet never calls the bullet's blast", {"CombatService": [(
        "\tif stopped then\n\t\tbulletBlast(shooterToken, def, stopped.Position, stopped.Normal)\n\tend\n", "")]}),
    ("the bullet's blast at the muzzle, not the hit point", {"CombatService": [(
        "bulletBlast(shooterToken, def, stopped.Position, stopped.Normal)", "bulletBlast(shooterToken, def, origin, stopped.Normal)")]}),
    ("the bullet's blast at the target's root, not the hit point", {"CombatService": [(
        "bulletBlast(shooterToken, def, stopped.Position, stopped.Normal)",
        "bulletBlast(shooterToken, def, (function() local m = stopped.Instance:FindFirstAncestorOfClass(\"Model\"); local r = m and m:FindFirstChild(\"HumanoidRootPart\"); return r and r.Position or stopped.Position end)(), stopped.Normal)")]}),
    ("a round's burst no longer explodes", {"ProjectileService": [(
        "\treturn explode(blast)\nend\n\nlocal function launchRound(", "\treturn nil\nend\n\nlocal function launchRound(")]}),
    ("a team-mate soaks the bullet (and the blast goes off on them)", {"CombatService": [(
        "if CombatService.DamageVeto and CombatService.DamageVeto(shooterToken, victimToken, def.id) then", "if false then")]}),
    ("the blast ignores the friendly-fire veto", {"CombatService": [(
        "\tif CombatService.DamageVeto and CombatService.DamageVeto(attackerToken, victimToken, weaponId) then\n\t\t-- Not silent",
        "\tif false then\n\t\t-- Not silent")]}),
    ("the owner takes their whole blast", {"ProjectileService": [("local SELF_SCALE = 0.5", "local SELF_SCALE = 1")]}),
    ("a streak gun's collect payout no longer explodes", {"CombatService": [(
        "elseif def.collect and victimRoot and CombatService.Explode then", "elseif false then")]}),
    ("a vehicle's round fired as a bullet", {"VehicleWeapons": [("\tif spec.kind == \"round\" then\n\t\tlaunchRound(", "\tif spec.kind == \"rounds\" then\n\t\tlaunchRound(")]}),
    ("a bullet that flew into the open sky explodes at its range", {"CombatService": [(
        "\t\tif not result then\n\t\t\tbreak\n\t\tend\n\n\t\tendPoint = result.Position\n\t\tstopped = result\n",
        "\t\tif not result then\n\t\t\tstopped = { Position = currentOrigin + direction * (def.range - travelled), Normal = -direction }\n\t\t\tbreak\n\t\tend\n\n\t\tendPoint = result.Position\n\t\tstopped = result\n")]}),
    # pc/explosive-followups: Oliver's three rules of 2026-09-25.
    ("a bot's hitscan hit never sets off its explosive ammo", {"BotService": [(
        "\t\tif CombatService.BulletBlastAt and CombatService.BulletBlast(def) then\n\t\t\tlocal back = head.Position - targetRoot.Position",
        "\t\tif false then\n\t\t\tlocal back = head.Position - targetRoot.Position")]}),
    ("a bot's miss blows up where it lands", {"BotService": [(
        "\tCombatService.BroadcastShot(bot, head.Position, { endPoint }, def.rarity)\n",
        "\tCombatService.BroadcastShot(bot, head.Position, { endPoint }, def.rarity)\n\tif not hit then CombatService.BulletBlastAt(bot, def, endPoint, Vector3.new(0, 1, 0)) end\n")]}),
    ("a launcher round bursts on a team-mate again", {"ProjectileService": [(
        "\t\tlocal mate = mateInTheWay(entry, instance)\n", "\t\tlocal mate = nil\n")]}),
    ("a launcher round flies through everyone in the battle royale", {"ProjectileService": [(
        "\treturn CombatService.DamageVeto(owner, token, entry.weaponId) and model or nil\n",
        "\treturn model\n"), (
        "\tif entry.thrown or not CombatService.DamageVeto then\n\t\treturn nil\n\tend\n\tlocal owner = creditable(entry.owner)",
        "\tif entry.thrown then\n\t\treturn nil\n\tend\n\tlocal owner = creditable(entry.owner)")]}),
    ("a multi-pellet gun's blasts are each full size", {"CombatService": [(
        "\tif pellets > 1 then\n\t\treturn {", "\tif false then\n\t\treturn {")]}),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    if "--plant" in sys.argv:
        caught = 0
        for name, swaps in PLANTS:
            rows, _, _ = run(root, swaps)
            failed = [line for ok, line in rows if not ok]
            print(("CAUGHT  " if failed else "MISSED  ") + name + (("  <- " + failed[0]) if failed else ""))
            caught += bool(failed)
        print("explosive_dispatch_check plants: %d of %d caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows, findings, table_ = run(root)
    for ok, line in rows:
        print(("ok    " if ok else "FAIL  ") + line)
    print()
    print("where each flagged hand gun's shot went off (blast count, and the z of each; the shooter stands at z 0):")
    for gid, results in table_.items():
        cells = []
        for case in CASES:
            b = results[case]["blasts"]
            cells.append("%s %d%s" % (case, len(b), "" if not b else " @" + ",".join("%.1f" % b[i]["z"] for i in sorted(b))))
        print("  %-20s %s" % (gid, " | ".join(cells)))
    for line in findings:
        print(line)
    failed = sum(1 for ok, _ in rows if not ok)
    print("explosive_dispatch_check: %d checks, %d failed, %d finding(s)" % (len(rows), failed, len(findings)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
