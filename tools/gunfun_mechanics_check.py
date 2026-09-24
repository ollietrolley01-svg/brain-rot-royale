"""Behaviour check for the gun rework's mechanics (2026-09-24), without Studio.

Runs the REAL code under lupa -- nothing here re-implements what it checks:
  * CombatService.lua: the signature-mechanics block (LifestealRatio / bloodthirst, Reflect, the pellet
    Patterns and PelletDirection) and the whole hitscan path (applySpread, fireAbility, bulletBlast,
    firePellet with its ricochet), cut out of the module's source and run against a small scripted world
    (a wall, a person) -- Luau's `continue` becomes a `goto` to the loop's end, the only rewrite;
  * StatusEffects.lua: the whole module, with its services mocked, driven through its own OnDamage
    listener and a delay queue run by hand, for `echo` and `ratio`;
  * the stats: every reworked gun's body DPS and time-to-kill through a full 200 pool (100 health + 100
    shield, CombatDamageScale from MatchConfig), mechanic included, against the SAME gun's stats before the
    rework (hard-coded below from 4de048f, the tree the rework started from). A reworked gun must stay within
    12% of its own old TTK, and no gun outside the snipers may kill a full pool with one headshot.

What it holds (each a line in the output):
  M1  bloodthirst: the ratio climbs by perHit per hit inside the window, caps at max, and a pause longer
      than the window or a change of gun starts it over;
  M2  ricochet: a shot glancing off a wall at 45 degrees hits a person standing where the reflection goes,
      for `scale` of its damage, and reports the segment to broadcast; the same shot without `ricochet`
      hits nobody; a bullet that stops in a PERSON never ricochets; `bounces` caps the count;
  M3  patterns: every pellet of a patterned shot goes out within jitter of its point of the shape, scaled
      by the spread, and inside the cone; a gun without a pattern still sprays at random;
  M4  echo: a hit comes back `delay` later for `ratio` of the body damage; not on a dead victim; an echo
      never echoes;
  M5  ratio: `stacks` quick hits mark the victim (DamageTakenScale = scale) for `duration`; a gap longer
      than `window` resets the count; a marked victim does not re-mark early;
  B1  every reworked gun's TTK is within 12% of its old one, and the one-shot rule holds.
The new guns' rounds run from the REAL Ballistics.lua (its steer / onContact / onLaunch / onDetonate, and
Ballistics.FreeStep, the step the server and every client take):
  N1  mosquitoDart: a near miss (2 studs at 40) is pulled onto the target, a wide one (8 studs) is not turned
      at all, the turn never passes its cap; a person bursts it, a wall stops it. Also reports from how far a
      bot's narrowest miss (6 studs) would be pulled back into a hit;
  N2  drumlet: bursts on a person, bounces off anything else, three contacts or 1.6 s at most, kicked up;
  N3  bananerang: reaches speed x time / pi, comes back to within a stud and a half of the thrower along its
      own outward path, lands in the same place at 30 and 240 fps; cuts one person once a pass (two cuts from
      six contacts, never a headshot), passes through people, bursts on a wall, and is caught (no burst) when
      its time runs out back at the thrower; the server's sweep filter is back to just the thrower at the turn;
  N4  the new guns' listed DPS inside their classes (pistols; Epic launchers; slow Legendaries, both boomerang
      passes counted), and none can take a fresh player's 100 with one shot's worth of hits.
Planted faults (`--plant`): each breaks the real source one way and the check that guards it must fail.

    python3 tools/gunfun_mechanics_check.py [repo]
    python3 tools/gunfun_mechanics_check.py [repo] --plant
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK, luau_to_lua  # noqa: E402
import weapon_stats  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

TTK_BAND = 0.12
POOL = 200

# The reworked Epic guns' stats before the rework (4de048f): damage, fireRate, headshotMultiplier, pellets.
BEFORE = {
    "GlitchSMG": (19, 14, 1.6, 1),
    "CameloLMG": (24, 10, 1.6, 1),
    "SixSevenMarksman": (62, 2.2, 2.3, 1),
    "RatioPDW": (20, 12.5, 1.6, 1),
    "BackroomsBreacher": (13, 1.85, 1.3, 9),
    "RizzRotary": (27, 8.5, 1.8, 1),
    "ReceiptPrinterLMG": (26, 10.5, 1.6, 1),
    "PatapimChaingun": (29, 13, 1.7, 1),
    "NonnaDoubleBarrel": (16, 3.2, 1.5, 10),
    "AuraAuditRifle": (29, 8.0, 1.9, 1),
    "AdminOverride": (34, 3.5, 2.0, 1),
    "FinalNotice": (33, 6.5, 1.9, 1),
}
SNIPER_STYLES = {"sniper", "railgun"}

WORLD = r"""
V3.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); return Vector3.new(v.X / m, v.Y / m, v.Z / m) end
	return V3[k]
end
function time() return CLOCK end
CLOCK = 0
RaycastParams = { new = function() return { FilterDescendantsInstances = {} } end }
Enum = Enum or {}
workspace = { FindFirstChild = function() return nil end }
local function instance(name, model)
	return { Name = name, model = model, FindFirstAncestorOfClass = function(self) return self.model end }
end
VICTIM_MODEL = { Name = "Victim" }
WALLS = {}
PEOPLE = {}
-- A world of axis-aligned walls (x = const planes) and people (spheres). Nearest hit along the segment,
-- skipping anything whose model is in the params' filter.
function worldRaycast(origin, vector, params)
	local best, bestT = nil, math.huge
	local filter = params.FilterDescendantsInstances or {}
	local function filtered(model)
		for _, f in ipairs(filter) do if f == model then return true end end
		return false
	end
	for _, wall in ipairs(WALLS) do
		if math.abs(vector.X) > 1e-9 then
			local t = (wall.x - origin.X) / vector.X
			if t > 1e-6 and t <= 1 and t < bestT then
				local p = origin + vector * t
				if p.Z >= wall.z0 and p.Z <= wall.z1 then
					best, bestT = { Instance = instance("Wall", nil), Position = p, Normal = Vector3.new(wall.nx, 0, 0) }, t
				end
			end
		end
	end
	for _, person in ipairs(PEOPLE) do
		if not filtered(person.model) then
			local oc = origin - person.at
			local a = vector:Dot(vector)
			local b = 2 * oc:Dot(vector)
			local c = oc:Dot(oc) - person.r * person.r
			local disc = b * b - 4 * a * c
			if disc >= 0 then
				local t = (-b - math.sqrt(disc)) / (2 * a)
				if t > 1e-6 and t <= 1 and t < bestT then
					local p = origin + vector * t
					best, bestT = { Instance = instance(person.part, person.model), Position = p, Normal = (p - person.at).Unit }, t
				end
			end
		end
	end
	return best
end
"""


def extract_combat(src):
    start = src.index("local function applySpread(direction, spreadDegrees)")
    end = src.index("-- workspace:Raycast for a shot from `shooterToken`")
    block = src[start:end]
    # Luau's `continue` -> a goto to the end of firePellet's loop (a label at the end of a block may be jumped
    # to past the locals declared in it).
    loop_end = "\t\tend\n\tend\n\n\tif stopped then"
    assert loop_end in block, "firePellet's loop end moved; update the harness"
    block = block.replace(loop_end, "\t\tend\n\t\t::continue_::\n\tend\n\n\tif stopped then", 1)
    block = re.sub(r"\bcontinue\b(?!_)", "goto continue_", block)
    return luau_to_lua(block)


COMBAT_HARNESS = r"""
local block = ...
local dealt = {}
CombatService = { HeadshotScale = 1, DamageListeners = {} }
Combatants = {
	FromCharacter = function(model) return model and model.token or nil end,
	IsAlive = function(token) return true end,
	GetRoot = function(token) return ROOTS and ROOTS[token] or nil end,
	GetHumanoid = function() return nil end,
}
EXPLODED = {}
CombatService.Explode = function(blast) table.insert(EXPLODED, blast) return {} end
CombatService.DealDamage = function(attacker, victim, amount, weaponId, headshot)
	table.insert(dealt, { victim = victim, amount = amount })
	return amount
end
CombatService.InRadius = function() return RADIUS_LIST or {} end
local combatantsInRadius = CombatService.InRadius
LagCompensation = { Raycast = function(origin, vector, params, rewindTo) return worldRaycast(origin, vector, params) end }
PIERCE_TARGETS = 2
local chunk = assert(load(block .. "\nreturn { firePellet = firePellet, applySpread = applySpread }", "=CombatBlock", "t",
	setmetatable({ combatantsInRadius = combatantsInRadius }, { __index = _G })))
local fns = chunk()
return fns, dealt
"""


def lua_runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    lua.execute(WORLD)
    return lua


def combat(lua, src):
    return lua.execute(COMBAT_HARNESS, extract_combat(src))


def check_combat(repo, src):
    out = []
    lua = lua_runtime()
    fns, dealt = combat(lua, src)
    cs = lua.globals().CombatService
    V = lua.eval("Vector3.new")

    # M1 bloodthirst
    spec = lua.eval("{ id = 'Camelo', lifestealRatio = 0.14, bloodthirst = { perHit = 0.03, max = 0.38, window = 0.5 } }")
    ratios = [cs.LifestealRatio("p1", spec, t * 0.1) for t in range(12)]
    want = [min(0.38, 0.14 + 0.03 * i) for i in range(12)]
    ok = all(abs(a - b) < 1e-9 for a, b in zip(ratios, want))
    after_pause = cs.LifestealRatio("p1", spec, 1.1 + 0.6)
    other = lua.eval("{ id = 'Other', lifestealRatio = 0.14, bloodthirst = { perHit = 0.03, max = 0.38, window = 0.5 } }")
    switched = cs.LifestealRatio("p1", other, 1.1 + 0.7)
    plain = cs.LifestealRatio("p2", lua.eval("{ id = 'X', lifestealRatio = 0.22 }"), 0)
    ok = ok and abs(after_pause - 0.14) < 1e-9 and abs(switched - 0.14) < 1e-9 and abs(plain - 0.22) < 1e-9
    out.append((ok, f"M1 bloodthirst: {', '.join('%.2f' % r for r in ratios)}; after a pause {after_pause:.2f}, new gun {switched:.2f}, plain gun {plain:.2f}"))

    # M2 ricochet: wall at x = 10 facing -x, person at (0, 0, -20).
    victim_model = lua.eval("{ Name = 'Victim', token = 'victim' }")
    lua.execute("WALLS = { { x = 10, nx = -1, z0 = -100, z1 = 100 } }")
    people = lua.eval("function(m) PEOPLE = { { at = Vector3.new(0, 0, -20), r = 1.5, part = 'UpperTorso', model = m } } end")
    people(victim_model)
    d = 1 / math.sqrt(2)

    def shot(defsrc, direction, origin=(0, 0, 0)):
        lua.execute("for k in pairs(DEALT) do DEALT[k] = nil end") if False else None
        while len(dealt) > 0:
            dealt[len(dealt)] = None
        segments = lua.table()
        definition = lua.eval(defsrc)
        fns.firePellet("shooter", None, V(*origin), V(*direction), definition, None, segments, None)
        hits = [dealt[i + 1] for i in range(len(dealt))]
        return hits, len(segments)

    hits, segs = shot("{ id = 'SixSeven', damage = 62, range = 900, ricochet = { bounces = 1, scale = 0.8 } }", (d, 0, -d))
    ok = len(hits) == 1 and hits[0].victim == "victim" and abs(hits[0].amount - 62 * 0.8) < 1e-6 and segs == 1
    out.append((ok, f"M2 ricochet: 45-degree bank shot hits {len(hits)} ({', '.join('%.1f' % h.amount for h in hits)}; want 49.6), {segs} segment(s) to broadcast"))
    hits, segs = shot("{ id = 'Plain', damage = 62, range = 900 }", (d, 0, -d))
    out.append((len(hits) == 0 and segs == 0, f"M2 no ricochet field: {len(hits)} hits, {segs} segments (want 0, 0)"))
    # A person between the shooter and the wall: the bullet stops in them and must not bounce.
    people2 = lua.eval("function(m, n) PEOPLE = { { at = Vector3.new(5, 0, -5), r = 1.5, part = 'UpperTorso', model = n }, { at = Vector3.new(0, 0, -20), r = 1.5, part = 'UpperTorso', model = m } } end")
    near_model = lua.eval("{ Name = 'Near', token = 'near' }")
    people2(victim_model, near_model)
    hits, segs = shot("{ id = 'SixSeven', damage = 62, range = 900, ricochet = { bounces = 1, scale = 0.8 } }", (d, 0, -d))
    ok = len(hits) == 1 and hits[0].victim == "near" and segs == 0
    out.append((ok, f"M2 stopped in a person: hits {[h.victim for h in hits]}, {segs} segments (want only 'near', no bounce)"))
    # Two walls facing each other: bounces caps the count.
    lua.execute("WALLS = { { x = 10, nx = -1, z0 = -1000, z1 = 1000 }, { x = -10, nx = 1, z0 = -1000, z1 = 1000 } }; PEOPLE = {}")
    counts = []
    for bounces in (1, 3):
        _, segs = shot("{ id = 'B', damage = 62, range = 900, ricochet = { bounces = %d, scale = 0.8 } }" % bounces, (d, 0, -d))
        counts.append(segs)
    out.append((counts == [1, 3], f"M2 bounce cap: {counts[0]} segment(s) at bounces = 1, {counts[1]} at bounces = 3"))

    # M3 patterns
    unit = V(0, 0, -1)
    worst, inside = 0.0, True
    spread = 6
    for name in ("door", "heart"):
        pattern = cs.Patterns[name]
        definition = lua.eval("{ pattern = '%s' }" % name)
        for index in range(1, len(pattern) + 1):
            direction = cs.PelletDirection(unit, spread, definition, index)
            # Angles off the aim, in degrees: right (x) and up (y).
            x = math.degrees(math.atan2(direction.X, -direction.Z))
            y = math.degrees(math.atan2(direction.Y, -direction.Z))
            px, py = pattern[index][1] * spread, pattern[index][2] * spread
            worst = max(worst, abs(x - px), abs(y - py))
            inside = inside and math.hypot(x, y) <= spread * 1.1
    jitter = cs.PatternJitter * spread / 2 + 0.2
    plain = [cs.PelletDirection(unit, spread, lua.eval("{}"), i) for i in range(1, 30)]
    spreadOk = len({(round(p.X, 6), round(p.Y, 6)) for p in plain}) > 20
    out.append((worst <= jitter and inside and spreadOk,
                f"M3 patterns: worst pellet {worst:.2f} deg off its point (allowed {jitter:.2f}), all inside the cone: {inside}; unpatterned gun still random: {spreadOk}"))

    # M6 noclip: a wall at x = 10, a person behind it at x = 15; a second wall at x = 12 for the cap.
    lua.execute("WALLS = { { x = 10, nx = -1, z0 = -100, z1 = 100 } }")
    lua.eval("function(m) PEOPLE = { { at = Vector3.new(15, 0, 0), r = 1.5, part = 'UpperTorso', model = m } } end")(victim_model)
    hits, _ = shot("{ id = 'Admin', damage = 34, range = 335, noclip = { walls = 1, scale = 0.7 } }", (1, 0, 0))
    through_one = [round(h.amount, 3) for h in hits]
    hits, _ = shot("{ id = 'Plain', damage = 34, range = 335 }", (1, 0, 0))
    plain_hits = len(hits)
    lua.execute("WALLS = { { x = 10, nx = -1, z0 = -100, z1 = 100 }, { x = 12, nx = -1, z0 = -100, z1 = 100 } }")
    hits, _ = shot("{ id = 'Admin', damage = 34, range = 335, noclip = { walls = 1, scale = 0.7 } }", (1, 0, 0))
    two_walls = len(hits)
    ok = through_one == [23.8] and plain_hits == 0 and two_walls == 0
    out.append((ok, f"M6 noclip: through one wall hits for {through_one} (want [23.8]); without noclip {plain_hits} hits; through two walls {two_walls} hits (want 0, 0)"))

    # M7 streak payouts: ten hits on one target a tenth of a second apart.
    lua.execute("WALLS = {}; ROOTS = { victim = { Position = Vector3.new(0, 0, -20) } }; RADIUS_LIST = { { token = 'victim' }, { token = 'a' }, { token = 'b' }, { token = 'c' } }")
    lua.eval("function(m) PEOPLE = { { at = Vector3.new(0, 0, -20), r = 1.5, part = 'UpperTorso', model = m } } end")(victim_model)

    def run_streak(defsrc, gaps):
        while len(dealt) > 0:
            dealt[len(dealt)] = None
        lua.execute("for k in pairs(EXPLODED) do EXPLODED[k] = nil end")
        definition = lua.eval(defsrc)
        for gap in gaps:
            lua.execute(f"CLOCK = CLOCK + {gap}")
            fns.firePellet("shooter", None, V(0, 0, 0), V(0, 0, -1), definition, None, lua.table(), None)
        return [(dealt[i + 1].victim, round(dealt[i + 1].amount, 3)) for i in range(len(dealt))], len(lua.globals().EXPLODED)

    log, _ = run_streak("{ id = 'Receipt', damage = 25, range = 400, receipt = { every = 10, bonus = 30, window = 1 } }", [0.1] * 10)
    bonus = [a for v, a in log if a == 30]
    log2, _ = run_streak("{ id = 'Receipt', damage = 25, range = 400, receipt = { every = 10, bonus = 30, window = 1 } }", [0.1] * 5 + [2] + [0.1] * 4)
    bonus2 = [a for v, a in log2 if a == 30]
    _, blasts = run_streak("{ id = 'Final', damage = 31, range = 490, collect = { every = 5, damage = 20, radius = 6, window = 1.5 } }", [0.15] * 10)
    log3, _ = run_streak("{ id = 'Audit', damage = 29, range = 470, chainRadius = 12, audit = { every = 8, ratio = 0.6, targets = 2, window = 1 } }", [0.12] * 8)
    arcs = [(v, a) for v, a in log3 if v != "victim"]
    ok = len(bonus) == 1 and len(bonus2) == 0 and blasts == 2 and len(arcs) == 2 and all(abs(a - 29 * 0.6) < 1e-6 for _, a in arcs)
    out.append((ok, f"M7 streaks: receipt pays {len(bonus)} bonus in 10 quick hits (want 1), {len(bonus2)} across a 2 s gap (want 0); "
                    f"collect blasts {blasts} times in 10 hits (want 2); audit arcs to {len(arcs)} others for {[a for _, a in arcs]} (want 2 x 17.4)"))
    return out


SE_HARNESS = r"""
local src = ...
math.clamp = math.clamp or function(x, a, b) return math.max(a, math.min(b, x)) end
local delayed = {}
local dealtLog = {}
local listener
local alive = { victim = true, other = true, shooter = true }
local Combatants = {
	IsAlive = function(t) return alive[t] == true end,
	Exists = function(t) return alive[t] ~= nil end,
	GetRoot = function() return nil end,
	GetCharacter = function() return nil end,
}
local CombatService = {
	IsEnabled = function() return true end,
	OnDamage = function(fn) listener = fn end,
}
CombatService.DealDamage = function(attacker, victim, amount, weaponId, headshot)
	table.insert(dealtLog, { victim = victim, amount = amount, at = CLOCK })
	-- As the real DealDamage does: every listener hears the hit.
	listener(attacker, victim, amount, weaponId, headshot, false)
	return amount
end
local defs = {
	Echo = { id = "Echo", damage = 15, echo = { ratio = 0.3, delay = 0.25 } },
	Ratio = { id = "Ratio", damage = 19, ratio = { stacks = 5, window = 1.5, duration = 3, scale = 1.12 } },
}
local modules = {
	CombatService = CombatService, Combatants = Combatants,
	MatchService = { SetStatusSpeed = function() end }, MovementService = { Launch = function() end },
	WeaponData = { Get = function(id) return defs[id] end },
}
local function folder() return { WaitForChild = function(_, name) return modules[name] or folder() end } end
local env = setmetatable({
	game = { GetService = function(_, name) if name == "Debris" then return { AddItem = function() end } end return folder() end },
	require = function(m) return m end,
	task = { spawn = function() end, delay = function() end, wait = function() end },
	warn = function(...) print("warn", ...) end,
}, { __index = _G })
local StatusEffects = assert(load(src, "=StatusEffects", "t", env))()
StatusEffects.Clock = function() return CLOCK end
StatusEffects.Delay = function(seconds, fn) table.insert(delayed, { at = CLOCK + seconds, fn = fn }) end
local api = {}
function api.hit(attacker, victim, weaponId, amount)
	CombatService.DealDamage(attacker, victim, amount, weaponId, false)
end
function api.advance(seconds)
	CLOCK = CLOCK + seconds
	local ran = true
	while ran do
		ran = false
		for i, entry in ipairs(delayed) do
			if entry.at <= CLOCK then
				table.remove(delayed, i)
				entry.fn()
				ran = true
				break
			end
		end
	end
end
function api.log() return dealtLog end
function api.clear() for k in pairs(dealtLog) do dealtLog[k] = nil end end
function api.pending() return #delayed end
function api.kill(t) alive[t] = false end
function api.revive(t) alive[t] = true end
api.scale = StatusEffects.DamageTakenScale
return api
"""


def check_status(repo, src):
    out = []
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("CLOCK = 0")
    api = lua.execute(SE_HARNESS, luau_to_lua(src))
    # M4 echo
    api.hit("shooter", "victim", "Echo", 15)
    first = len(api.log())
    pending = api.pending()
    api.advance(0.2)
    before = len(api.log())
    api.advance(0.1)
    log = api.log()
    echoes = [log[i + 1] for i in range(len(log))][first:]
    api.advance(1)
    ok = first == 1 and pending == 1 and before == 1 and len(echoes) == 1 and abs(echoes[0].amount - 4.5) < 1e-9 and api.pending() == 0 and len(api.log()) == 2
    out.append((ok, f"M4 echo: 1 hit -> {len(api.log()) - 1} echo of {echoes[0].amount if echoes else 0:.2f} after 0.25 s (want 1 of 4.50), none before, no echo of the echo"))
    api.clear()
    api.hit("shooter", "victim", "Echo", 15)
    api.kill("victim")
    api.advance(0.5)
    out.append((len(api.log()) == 1, f"M4 dead victim: {len(api.log()) - 1} echoes land on a body (want 0)"))
    api.revive("victim")
    # M5 ratio
    api.clear()
    scales = []
    for index in range(5):
        api.hit("shooter", "other", "Ratio", 19)
        scales.append(api.scale("other"))
        api.advance(0.3)
    marked = scales[-1]
    api.advance(3.0)
    after = api.scale("other")
    ok = scales[:4] == [1, 1, 1, 1] and abs(marked - 1.12) < 1e-9 and after == 1
    # A gap longer than the window resets the count.
    for index in range(4):
        api.hit("shooter", "victim", "Ratio", 19)
        api.advance(0.2)
    api.advance(2)
    api.hit("shooter", "victim", "Ratio", 19)
    gapped = api.scale("victim")
    ok = ok and gapped == 1
    out.append((ok, f"M5 ratio: scale per hit {scales} (want 1 x4 then 1.12), {after} once it lapses, {gapped} after a gap resets the count"))
    return out


def check_balance(repo):
    out = []
    stats = weapon_stats.read_all(repo) if hasattr(weapon_stats, "read_all") else None
    if stats is None:
        # weapon_stats exposes entries(src); read the files ourselves.
        stats = {}
        for rel in weapon_stats.FILES:
            text = (Path(repo) / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
            stats.update(weapon_stats.entries(text))
    scale = float(re.search(r"CombatDamageScale\s*=\s*([\d.]+)", (Path(repo) / "ReplicatedStorage/Shared/MatchConfig.lua").read_text()).group(1))

    def num(body, key, default=None):
        m = re.search(rf"\b{key}\s*=\s*([\d.]+)", body)
        return float(m.group(1)) if m else default

    def ttk(damage, rate, pellets, extra=1.0, mark=None, every=None):
        """Seconds to empty a 200 pool with every pellet landing on the body, from the first shot. `every` =
        (n, bonus): every nth hit adds `bonus` (a receipt's total, a collection's blast at its centre)."""
        per = damage * pellets * scale
        pool, t, hits = POOL, 0.0, 0
        while True:
            hits += 1
            hit = per * extra
            if mark and hits > mark[0]:
                hit *= mark[1]
            if every and hits % every[0] == 0:
                hit += every[1] * scale
            pool -= hit
            if pool <= 1e-9:
                return t
            t += 1 / rate

    for gun, (d0, r0, h0, p0) in BEFORE.items():
        body = stats.get(gun)
        if body is None:
            out.append((False, f"B1 {gun}: not found in the arsenal files"))
            continue
        d, r, p = num(body, "damage"), num(body, "fireRate"), num(body, "pellets", 1)
        extra, mark = 1.0, None
        echo = re.search(r"echo\s*=\s*\{\s*ratio\s*=\s*([\d.]+)", body)
        if echo:
            extra += float(echo.group(1))
        ratio = re.search(r"ratio\s*=\s*\{\s*stacks\s*=\s*(\d+).*?scale\s*=\s*([\d.]+)", body)
        if ratio:
            mark = (int(ratio.group(1)), float(ratio.group(2)))
        every = None
        payout = re.search(r"(?:receipt|collect)\s*=\s*\{\s*every\s*=\s*(\d+),\s*(?:bonus|damage)\s*=\s*([\d.]+)", body)
        if payout:
            every = (int(payout.group(1)), float(payout.group(2)))
        old, new = ttk(d0, r0, p0), ttk(d, r, p, extra, mark, every)
        ok = abs(new - old) <= TTK_BAND * old + 1e-9
        out.append((ok, f"B1 {gun}: TTK {old:.3f}s -> {new:.3f}s ({(new / old - 1) * 100:+.1f}%), body DPS {d0 * p0 * r0:.0f} -> {d * p * r * extra:.0f}"))
    # One-shot rule over the whole arsenal: only snipers may end a full pool with one headshot.
    offenders = []
    for gun, body in stats.items():
        style = re.search(r'style\s*=\s*"(\w+)"', body)
        d, h, p = num(body, "damage"), num(body, "headshotMultiplier", 1), num(body, "pellets", 1)
        if d is None or style is None or style.group(1) in SNIPER_STYLES or "projectile" in body:
            continue
        if d * h * scale >= POOL:
            offenders.append(gun)
    out.append((not offenders, f"B1 one-shot rule: {len(stats)} guns examined, non-sniper hitscan guns killing a full pool with one headshot: {offenders or 'none'}"))
    return out


ROUNDS_HARNESS = r"""
local src = ...
V3.Lerp = V3.Lerp or function(a, b, t) return a + (b - a) * t end
local B = assert(load(src, "=Ballistics", "t", _G))()

-- Parts and characters: a part knows its model; a character model has a Humanoid.
function part(name, model)
	return {
		Name = name, model = model,
		FindFirstAncestorOfClass = function(self) return self.model end,
		IsDescendantOf = function(self, other) return self.model ~= nil and self.model == other end,
	}
end
function character(token)
	return { token = token, FindFirstChildOfClass = function(self, class) return class == "Humanoid" and {} or nil end }
end

-- A dart fired from the origin along `aim` at a target standing at `at`: the closest it comes to the target's
-- centre, and how far it turned.
function simDart(at, aim, dt)
	local spec = B.Rounds.mosquitoDart
	local entry = { spec = spec, owner = "me", age = 0, position = Vector3.new(0, 0, 0), velocity = aim.Unit * spec.speed }
	local api = { Targets = function(position, range)
		if (at - position).Magnitude <= range then return { { root = { Position = at } } } end
		return {}
	end }
	local closest = math.huge
	while entry.age < spec.maxTime do
		entry.age = entry.age + dt
		local p, v = B.FreeStep(entry, dt, 196.2, api)
		local seg = p - entry.position
		local l2 = seg:Dot(seg)
		local t = l2 > 0 and math.max(0, math.min(1, (at - entry.position):Dot(seg) / l2)) or 0
		closest = math.min(closest, (entry.position + seg * t - at).Magnitude)
		entry.position, entry.velocity = p, v
	end
	return closest, type(entry.turned) == "number" and entry.turned or 0
end

-- A boomerang thrown from the origin along -Z: its positions by age, stepped at dt, and the entry. `server`
-- gives it a sweep filter holding the thrower, and adds a person's part to it at age 0.3 (a pass).
function simBoomerang(dt, server)
	local spec = B.Rounds.bananerang
	local entry = { spec = spec, owner = "me", age = 0, position = Vector3.new(0, 0, 0), velocity = Vector3.new(0, 0, -spec.speed) }
	if server then
		entry.filter = { "thrower" }
		entry.params = { FilterDescendantsInstances = entry.filter }
	end
	local track, added = {}, false
	while entry.age < spec.maxTime - 1e-9 do
		local step = math.min(dt, spec.maxTime - entry.age)
		entry.age = entry.age + step
		local p, v = B.FreeStep(entry, step, 196.2, {})
		entry.position, entry.velocity = p, v
		table.insert(track, { age = entry.age, position = p })
		if server and not added and entry.age >= 0.3 then
			added = true
			table.insert(entry.filter, "victimPart")
			entry.params.FilterDescendantsInstances = entry.filter
		end
	end
	local trimmed = server and #entry.filter == 1 and entry.params.FilterDescendantsInstances == entry.filter or false
	return track, entry, trimmed
end

function dist(a, b)
	return (a - b).Magnitude
end

function at(track, age)
	local best, bestGap = nil, math.huge
	for _, sample in ipairs(track) do
		local gap = math.abs(sample.age - age)
		if gap < bestGap then best, bestGap = sample.position, gap end
	end
	return best
end

-- The boomerang meeting people: returns the damage calls.
function cuts(ages)
	local spec = B.Rounds.bananerang
	local victim = character("victim")
	local calls = {}
	local api = {
		Targets = function() return { { token = "victim", root = { Position = Vector3.new(0, 0, -20), Parent = victim } } } end,
		DealDamage = function(attacker, token, amount, weaponId, headshot)
			table.insert(calls, { attacker = attacker or "nobody", token = token, amount = amount, headshot = headshot })
		end,
		-- The thrower leaves between the passes.
		Creditable = function(token)
			if LEFT then
				return nil
			end
			return token
		end,
	}
	local entry = { spec = spec, owner = "me", damage = 45, weaponId = "Bananerang", age = 0 }
	local verdicts = {}
	LEFT = false
	for _, age in ipairs(ages) do
		LEFT = age > 0.75
		entry.age = age
		table.insert(verdicts, spec.onContact(entry, { Instance = part("UpperTorso", victim), Position = Vector3.new(0, 0, -20) }, api))
	end
	local wall = spec.onContact(entry, { Instance = part("Wall", nil), Position = Vector3.new(0, 0, -20) }, api)
	return calls, verdicts, wall
end

return B
"""


NEW_GUNS = {"ZanzarinoPikpik", "TamburoTungTung", "Bananerang"}


def check_rounds(repo, ballistics_src, weapon_text=None):
    out = []
    lua = lua_runtime()
    B = lua.execute(ROUNDS_HARNESS, luau_to_lua(ballistics_src))
    g = lua.globals()
    V = lua.eval("Vector3.new")

    # N1 the mosquito dart: a near miss is forgiven, a wide one left alone, the turn capped.
    homing = B.DartHoming
    total = math.degrees(homing.total)
    near, near_turn = g.simDart(V(0, 0, -40), V(2, 0, -40), 1 / 60)
    wide, wide_turn = g.simDart(V(0, 0, -40), V(8, 0, -40), 1 / 60)
    far_turns = []
    converted = []
    for d in range(20, 101, 10):
        closest, turned = g.simDart(V(0, 0, -d), V(6, 0, -d), 1 / 60)
        far_turns.append(math.degrees(turned))
        if closest < 1.2:
            converted.append(d)
    spec = B.Rounds.mosquitoDart
    char = g.character("v")
    hit_verdict = spec.onContact(lua.table(), lua.table_from({"Instance": g.part("Head", char)}))
    wall_verdict = spec.onContact(lua.table(), lua.table_from({"Instance": g.part("Wall", None)}))
    ok = (near < 1.2 and wide > 3 and wide_turn == 0 and max(far_turns + [math.degrees(near_turn)]) <= total + 1e-6
          and hit_verdict == "detonate" and wall_verdict == "stop")
    out.append((ok, f"N1 mosquitoDart: 2 studs off at 40 -> passes {near:.2f} from the centre (turned {math.degrees(near_turn):.1f} deg); "
                    f"8 off -> {wide:.2f} (turned {math.degrees(wide_turn):.1f}); cap {total:.0f} deg, most turned {max(far_turns):.1f}; "
                    f"a bot's 6-stud miss becomes a hit at {converted or 'no'} studs; person -> {hit_verdict}, wall -> {wall_verdict}"))

    # N2 the drumlet: bursts on a person, bounces off the rest, three contacts or 1.6 s at most, kicked up.
    spec = B.Rounds.drumlet
    entry = lua.eval("{ body = { velocity = Vector3.new(0, 0, -115) } }")
    spec.onLaunch(entry)
    lift = entry.body.velocity.Y
    person = spec.onContact(lua.table(), lua.table_from({"instance": g.part("Head", char)}))
    wall = spec.onContact(lua.table(), lua.table_from({"instance": g.part("Wall", None)}))
    ok = (person == "detonate" and wall is None and spec.maxBounces == 3 and abs(spec.fuse - 1.6) < 1e-9
          and abs(lift - B.DrumletLift) < 1e-9 and spec.motion == "body")
    out.append((ok, f"N2 drumlet: person -> {person}, wall -> {wall or 'default (bounce until the last)'}, maxBounces {spec.maxBounces}, "
                    f"fuse {spec.fuse}s, launch lift {lift:.0f} studs/s"))

    # N3 the boomerang: out to its reach, back to the thrower along the same curve, whatever the frame rate.
    track, _, _ = g.simBoomerang(1 / 60, False)
    positions = [track[i + 1].position for i in range(len(track))]
    reach = max(-p.Z for p in positions)
    bend = max(abs(p.X) for p in positions)
    end = positions[-1]
    back = end.Magnitude
    T = B.Boomerang.time
    retrace = max(g.dist(g.at(track, t), g.at(track, T - t)) for t in (0.2, 0.35, 0.5, 0.65))
    coarse, _, _ = g.simBoomerang(1 / 30, False)
    fine, _, _ = g.simBoomerang(1 / 240, False)
    agree = g.dist(coarse[len(coarse)].position, fine[len(fine)].position)
    agree_mid = g.dist(g.at(coarse, 0.5), g.at(fine, 0.5))
    want_reach = B.Rounds.bananerang.speed * T / math.pi
    _, _, trimmed = g.simBoomerang(1 / 60, True)
    calls, verdicts, wall = g.cuts(lua.table_from([0.2, 0.3, 0.45, 0.9, 1.0, 1.3]))
    ncalls = len(calls)
    amounts = [calls[i + 1].amount for i in range(ncalls)]
    headshots = [calls[i + 1].headshot for i in range(ncalls)]
    credited = [calls[i + 1].attacker for i in range(ncalls)]
    all_pass = all(verdicts[i + 1] == "pass" for i in range(len(verdicts)))
    catch = B.Rounds.bananerang.onDetonate(lua.eval("{ age = 1.45 }"), lua.eval("{}"))
    thud = B.Rounds.bananerang.onDetonate(lua.eval("{ age = 0.5 }"), lua.eval("{}"))
    struck = B.Rounds.bananerang.onDetonate(lua.eval("{ age = 1.45 }"), lua.eval("{ direct = { token = 'v' } }"))
    ok = (abs(reach - want_reach) < 1.0 and back < 1.5 and retrace < 0.5 and agree < 0.5 and agree_mid < 0.5
          and 3 < bend < 8 and trimmed and ncalls == 2 and all(a == 45 for a in amounts) and not any(headshots)
          and credited == ["me", "nobody"]
          and all_pass and wall == "detonate" and catch is False and thud is None and struck is None)
    out.append((ok, f"N3 bananerang: reach {reach:.1f} studs (want {want_reach:.1f}), bend {bend:.1f}, back within {back:.2f} of the thrower, "
                    f"out/back paths {retrace:.2f} apart, 30 vs 240 fps {agree:.2f} apart at the end ({agree_mid:.2f} mid-flight); "
                    f"filter back to the thrower at the turn: {trimmed}; six contacts on one person over both passes -> {ncalls} cuts "
                    f"{amounts} (headshots {any(headshots)}) credited to {credited} (the thrower leaves between), all pass: {all_pass}; wall -> {wall}; "
                    f"time out at the thrower -> {'caught' if catch is False else catch}, mid-air -> {thud or 'bursts'}"))

    # N4 the new guns' numbers against their classes, and no one-shot from a single shot's worth of hits.
    stats = {}
    for rel in weapon_stats.FILES:
        text = (Path(repo) / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
        if weapon_text is not None and rel.endswith("/WeaponData.lua"):
            text = weapon_text
        stats.update(weapon_stats.entries(text))
    scale = float(re.search(r"CombatDamageScale\s*=\s*([\d.]+)", (Path(repo) / "ReplicatedStorage/Shared/MatchConfig.lua").read_text()).group(1))

    def num(body, key, default=None):
        m = re.search(rf"\b{key}\s*=\s*([\d.]+)", body)
        return float(m.group(1)) if m else default

    def listed(body):
        return num(body, "damage") * num(body, "pellets", 1) * num(body, "fireRate")

    def band(pred):
        dps = [listed(b) for gid, b in stats.items() if gid not in NEW_GUNS and "staged = true" not in b and pred(b)]
        return min(dps), max(dps)

    def style(body):
        m = re.search(r'style\s*=\s*"(\w+)"', body)
        return m.group(1) if m else None

    def rarity(body):
        m = re.search(r'rarity\s*=\s*"(\w+)"', body)
        return m.group(1) if m else None

    lines, ok = [], True
    pik = stats["ZanzarinoPikpik"]
    bleed = re.search(r"bleed\s*=\s*\{\s*damage\s*=\s*([\d.]+),\s*duration\s*=\s*([\d.]+)", pik)
    pik_dps = listed(pik) + (float(bleed.group(1)) / float(bleed.group(2)) if bleed else 0)
    lo, hi = band(lambda b: style(b) == "pistol")
    pik_head = num(pik, "damage") * num(pik, "headshotMultiplier") * scale
    good = lo * (1 - TTK_BAND) <= pik_dps <= hi * (1 + TTK_BAND) and pik_head < 100
    ok &= good
    lines.append(f"Pikpik {pik_dps:.1f} DPS with the itch (pistols {lo:.0f}-{hi:.0f}), headshot {pik_head:.0f}")
    tam = stats["TamburoTungTung"]
    volley = num(tam, "pellets") * (num(tam, "damage") + B.Rounds.drumlet.impactBonus) * scale
    lo, hi = band(lambda b: style(b) == "launcher" and rarity(b) == "Epic")
    good = lo * (1 - TTK_BAND) <= listed(tam) <= hi * (1 + TTK_BAND) and volley < 100
    ok &= good
    lines.append(f"Tamburo {listed(tam):.0f} DPS (Epic launchers {lo:.0f}-{hi:.0f}), a whole volley on one person {volley:.0f}")
    ban = stats["Bananerang"]
    both = listed(ban) * 2
    throw = 2 * num(ban, "damage") * scale
    lo, hi = band(lambda b: rarity(b) == "Legendary" and num(b, "fireRate") <= 1.5)
    good = lo * (1 - TTK_BAND) <= both <= hi * (1 + TTK_BAND) and throw < 100
    ok &= good
    lines.append(f"Bananerang {both:.0f} DPS with both passes (slow Legendaries {lo:.0f}-{hi:.0f}), one throw on one person {throw:.0f}")
    out.append((ok, "N4 new guns: " + "; ".join(lines) + " (a fresh player has 100)"))
    return out


def run(repo, combat_src=None, status_src=None, ballistics_src=None, weapon_text=None):
    root = Path(repo)
    combat_src = combat_src or (root / "ServerScriptService/Modules/CombatService.lua").read_text(encoding="utf-8")
    status_src = status_src or (root / "ServerScriptService/Modules/StatusEffects.lua").read_text(encoding="utf-8")
    ballistics_src = ballistics_src or (root / "ReplicatedStorage/Shared/Ballistics.lua").read_text(encoding="utf-8")
    return (check_combat(repo, combat_src) + check_status(repo, status_src) + check_balance(repo)
            + check_rounds(repo, ballistics_src, weapon_text))


PLANTS = [
    ("M2 a ricochet off a person", "combat", "if spec and onMap and stopped", "if spec and stopped"),
    ("M2 the ricochet at full damage", "combat", "def.damage * (spec.scale or 0.8)", "def.damage"),
    ("M1 bloodthirst never resets", "combat", "if not entry or now - entry.at > spec.window or entry.weaponId ~= def.id then",
     "if not entry then"),
    ("M3 patterns ignored", "combat", "local pattern = def.pattern and CombatService.Patterns[def.pattern]", "local pattern = nil"),
    ("M4 an echo that echoes", "status", "\t\tticking = true\n\t\tlocal ok, err = pcall(CombatService.DealDamage, attacker, victim, def.damage * ratio",
     "\t\tlocal ok, err = pcall(CombatService.DealDamage, attacker, victim, def.damage * ratio"),
    ("M6 noclip through every wall", "combat", "if victimToken == nil and walls > 0 then\n\t\t\t\twalls -= 1", "if victimToken == nil and walls > 0 then\n\t\t\t\twalls -= 0"),
    ("M7 a streak that never breaks", "combat", "entry.weaponId ~= def.id or now - entry.at > window then", "entry.weaponId ~= def.id then"),
    ("M5 a ratio with no window", "status", "if now - state.at > window then", "if false then"),
    # The new guns' rounds (Ballistics) and numbers (WeaponData).
    ("N1 a dart that homes on a wide miss", "ballistics", "cone = math.rad(10)", "cone = math.rad(40)"),
    ("N2 drumlets that bounce off people", "ballistics",
     'onContact = function(_entry, contact)\n\t\tif roundHitsCharacter(roundHitInstance(contact)) then\n\t\t\treturn "detonate"\n\t\tend\n\t\treturn nil',
     'onContact = function(_entry, contact)\n\t\tif roundHitsCharacter(roundHitInstance(contact)) then\n\t\t\treturn nil\n\t\tend\n\t\treturn nil'),
    ("N3 a boomerang that cuts on every contact", "ballistics", "if entry.cut[target.token] ~= pass then", "if true then"),
    ("N3 a boomerang that can't meet anyone twice", "ballistics", "table.remove(entry.filter, index)", "local _ = index"),
    ("N3 a boomerang that never comes back", "ballistics", "memory.dir * (memory.speed * math.cos(math.pi * u))", "memory.dir * memory.speed"),
    ("N4 a drumlet volley that kills", "weapons", "\t\tdamage = 26,\n\t\theadshotMultiplier = 1,\n\t\tfireRate = 1.0,",
     "\t\tdamage = 40,\n\t\theadshotMultiplier = 1,\n\t\tfireRate = 1.0,"),
]


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    repo = args[0] if args else "."
    root = Path(repo)
    sources = {
        "combat": (root / "ServerScriptService/Modules/CombatService.lua").read_text(encoding="utf-8"),
        "status": (root / "ServerScriptService/Modules/StatusEffects.lua").read_text(encoding="utf-8"),
        "ballistics": (root / "ReplicatedStorage/Shared/Ballistics.lua").read_text(encoding="utf-8"),
        "weapons": (root / "ReplicatedStorage/Shared/WeaponData.lua").read_text(encoding="utf-8"),
    }
    if "--plant" in argv:
        caught = 0
        for name, target, old, new in PLANTS:
            src = sources[target]
            if src.count(old) != 1:
                print(f"PLANT {name}: the text to break is not there (once) any more")
                continue
            broken = src.replace(old, new, 1)
            try:
                results = run(repo, broken if target == "combat" else None, broken if target == "status" else None,
                              broken if target == "ballistics" else None, broken if target == "weapons" else None)
                code = name.split()[0]
                hit = [line for ok, line in results if not ok and line.startswith(code)]
            except Exception as exc:  # a plant that breaks the run outright is caught too
                hit = [f"run failed: {exc}"]
            caught += bool(hit)
            print(f"{'CAUGHT' if hit else 'MISSED'} {name}{': ' + hit[0] if hit else ''}")
        print(f"planted faults caught: {caught} of {len(PLANTS)}")
        return 0 if caught == len(PLANTS) else 1
    results = run(repo)
    bad = 0
    for ok, line in results:
        print(("ok    " if ok else "FAIL  ") + line)
        bad += not ok
    print(f"gunfun mechanics: {len(results)} checks, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
