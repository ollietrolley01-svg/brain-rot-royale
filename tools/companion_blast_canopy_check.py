"""A companion blast never hurts a parachuter (Oliver, 2026-09-25: "enemy brainrots can attack you while
parachuting"; the sweep fixed the direct attacks, and the 1000 handoff left the blast brainrots open).

Runs the REAL CompanionService blastFor and underCanopy (cut from the file) into the REAL
ProjectileService explode (cut out the way tools/explosive_ammo_check.py does it), with the REAL
BrainrotData blast numbers, in lupa against tools/hitreg_mocks.lua, and measures what DealDamage is
handed:

  CANOPY    a companion blast 2 studs from a player wearing a GliderCanopy deals 0 and doesn't shove them
  GROUNDED  the same blast, same distance, at a player without one deals its normal damage
            (BlastPower x stats x BlastScale) and shoves them
  LANDED    lift the canopy off and the same player takes that same normal damage again
  GRENADE   a grenade (a blast with no `spare`) at the parachuter still deals its normal damage
  CALLERS   every call of ProjectileService's explode, counted in the source: only CompanionService's
            passes `spare`, and it passes underCanopy (the direct attacks' own test, not a second one)

    python tools/companion_blast_canopy_check.py .            the checks
    python tools/companion_blast_canopy_check.py . --plant    the planted faults; every one must be caught

Not tested here: a blast brainrot in Studio (the canopy weld's timing, what the client draws).
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("companion_blast_canopy_check: needs lupa (pip install lupa)")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from explosive_ammo_check import blast_sources, cut, luau_to_lua, read  # noqa: E402

SERVICE = ("ServerScriptService", "Modules", "CompanionService.lua")
PROJECTILE = ("ServerScriptService", "Modules", "ProjectileService.lua")
DATA = ("ReplicatedStorage", "Shared", "BrainrotData.lua")

HARNESS = r"""
local M, projectile, ballistics, companion, dataSrc = ...
local Vector3 = M.Vector3
math.clamp = math.clamp or function(x, a, b) return math.max(a, math.min(b, x)) end
rawget(M.workspace, "_props").FindFirstChild = function() return nil end
rawget(M.workspace, "_props").Terrain = {}

Color3 = Color3 or { fromRGB = function(r, g, b) return { r, g, b } end, new = function(r, g, b) return { r, g, b } end }
-- BrainrotData's looks read Enum.Material and the like; any path will do for the numbers used here.
local Any
Any = setmetatable({}, { __index = function() return Any end, __call = function() return Any end })
local BrainrotData = assert(load(dataSrc, "BrainrotData", "t", setmetatable({ Enum = Any }, { __index = _G })))()
local Ballistics = assert(load("local Ballistics = {}\n" .. ballistics .. "\nreturn Ballistics", "Ballistics", "t", _G))()

local victims, dealt, calls, shoved = {}, {}, {}, {}
local env = setmetatable({
    Vector3 = Vector3, Enum = M.Enum, workspace = M.workspace,
    RaycastParams = M.RaycastParams, RunService = { IsRunning = function() return false end },
    OverlapParams = { new = function() return {} end },
    Ballistics = Ballistics, DestructibleService = { GlassName = "WindowGlass" },
    SafeValue = { Vector3 = function() return true end },
    MovementService = { Launch = function(character) shoved[character] = true end },
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
        DealDamage = function(_, token, amount) calls[token] = (calls[token] or 0) + 1 dealt[token] = amount return amount end,
    },
    live = {}, fx = {},
    -- No team mode here: nobody is a forgotten team-mate.
    forgottenMate = function() return false end,
}, { __index = _G })
local explode = assert(load(projectile .. "\nreturn explode", "ProjectileService", "t", env))()

-- blastFor as written, its ProjectileService the real explode. The per-use cap (withinUse) is
-- companion_ability_check's; here it passes the amount through.
local cenv = setmetatable({
    BrainrotData = BrainrotData, Vector3 = Vector3,
    useReport = function() return {} end,
    withinUse = function(_, _, amount) return amount end,
    warn = function() end,
    script = { Parent = { WaitForChild = function() return { Explode = explode } end } },
    require = function(m) return m end,
}, { __index = _G })
local blastFor, underCanopy = assert(load(companion .. "\nreturn blastFor, underCanopy", "CompanionService", "t", cenv))()

local defs = {}
for _, d in ipairs(BrainrotData.Types) do
    if d.blast then table.insert(defs, d) end
end
local function numbers(def)
    local step = (BrainrotData.RarityIndex[def.rarity] or 0) - (BrainrotData.RarityIndex[BrainrotData.BlastMinRarity] or 4)
    return BrainrotData.BlastRadius + BrainrotData.BlastRadiusStep * math.max(0, step)
end
local STATS = 40
local power = STATS * BrainrotData.BlastPower

local out = {}
local function note(ok, line) table.insert(out, { ok = ok, line = line }) end
local owner = { name = "owner" }
local function victim(name, x)
    local character, root = M.character(name, M.CFrame.new(x, 3, 0))
    rawset(root._props, "AssemblyLinearVelocity", Vector3.new(0, 0, 0))
    local v = { token = { name = name }, humanoid = { Health = 100 }, root = root, character = character }
    table.insert(victims, v)
    return v
end
local function reset()
    for _, t in ipairs({ dealt, calls, shoved }) do for k in pairs(t) do t[k] = nil end end
end
local centre = Vector3.new(0, 3, 0)
local D = 2
local function normalAt(radius)
    -- explode measures from 0.3 studs off the surface (the normal is straight up for both blasts here).
    local distance = math.sqrt(D * D + 0.3 * 0.3)
    return power * Ballistics.BlastScale(math.max(0, distance - Ballistics.BodyAllowance), 0, radius)
end

local chuter = victim("Parachuter", D)
local canopy = M.instance("Model", "GliderCanopy", chuter.character, {})
local grounded = victim("Grounded", -D)

-- Every blast brainrot in the collection, at its own radius.
local worstChuter, badGrounded, unused, minNormal = 0, {}, {}, math.huge
local chuterShoved = false
for _, def in ipairs(defs) do
    local radius = numbers(def)
    local normal = normalAt(radius)
    minNormal = math.min(minNormal, normal)
    reset()
    if blastFor(owner, { def = def, stats = { damage = STATS } }, centre) ~= true then table.insert(unused, def.name) end
    worstChuter = math.max(worstChuter, dealt[chuter.token] or 0, calls[chuter.token] and 1e-9 or 0)
    chuterShoved = chuterShoved or shoved[chuter.character] == true
    if not (normal > 0 and math.abs((dealt[grounded.token] or 0) - normal) < 1e-6 and shoved[grounded.character]) then
        table.insert(badGrounded, string.format("%s %.2f (normal %.2f)", def.name, dealt[grounded.token] or 0, normal))
    end
end
note(#defs > 0 and #unused == 0, string.format("%d blast brainrots examined, all used their blast%s", #defs, #unused > 0 and (": not " .. table.concat(unused, ", ")) or ""))
note(worstChuter == 0 and not chuterShoved,
    string.format("CANOPY: a companion blast %d studs from a parachuter deals at most %.2f across all %d, shoved %s", D, worstChuter, #defs, tostring(chuterShoved)))
note(#defs > 0 and #badGrounded == 0,
    string.format("GROUNDED: the same blasts at a grounded player deal their normal damage (at least %.2f) and shove%s",
        minNormal, #badGrounded > 0 and (": wrong for " .. table.concat(badGrounded, "; ")) or ""))

local def = defs[1]
local entry = { def = def, stats = { damage = STATS } }
local radius = numbers(def)
local normal = normalAt(radius)

-- The canopy lifted off (feet down): the same player takes the normal blast again.
table.remove(chuter.character._children, (function() for i, c in ipairs(chuter.character._children) do if c == canopy then return i end end end)())
reset()
blastFor(owner, entry, centre)
note(math.abs((dealt[chuter.token] or 0) - normal) < 1e-6,
    string.format("LANDED: %s, canopy off, the same player takes %.2f (normal %.2f)", def.name, dealt[chuter.token] or 0, normal))

-- A grenade (ProjectileService's own blast table: no spare) still reaches a parachuter.
table.insert(chuter.character._children, canopy)
note(underCanopy(chuter.character) == true and underCanopy(grounded.character) == false, "underCanopy: parachuter yes, grounded no")
reset()
explode({ id = 1, owner = owner, kind = "grenade", weaponId = "FragGrenade", position = centre,
    normal = Vector3.new(0, 1, 0), damage = power, radius = radius, innerRadius = 0, wallDamage = 0 })
note(math.abs((dealt[chuter.token] or 0) - normal) < 1e-6,
    string.format("GRENADE: a grenade at the parachuter deals %.2f (normal %.2f)", dealt[chuter.token] or 0, normal))
return out
"""


def callers(root, sources):
    """Every call of ProjectileService's explode in the server modules: (file:line, passes spare, spare value)."""
    rows = []
    found = []
    for name, src in sources.items():
        lines = src.split("\n")
        for i, line in enumerate(lines):
            code = line.split("--", 1)[0]
            if re.search(r"\b(?:CombatService|projectileService|ProjectileService)\.Explode\(|(?<![\w.:])explode\(", code) \
                    and "function" not in code:
                body = "\n".join(lines[i:i + 40])
                body = body[:body.index("\n\t})") if "\n\t})" in body else len(body)] if "({" in code else ""
                spare = re.search(r"^\s*spare = (\w+),", body, re.M)
                found.append(("%s:%d" % (name, i + 1), spare.group(1) if spare else None))
    companion = [f for f in found if f[0].startswith("CompanionService")]
    others = [f for f in found if not f[0].startswith("CompanionService")]
    rows.append((len(found) >= 4, "CALLERS: %d calls of ProjectileService's explode examined: %s"
                 % (len(found), ", ".join(f[0] for f in found))))
    rows.append((len(companion) == 1 and companion[0][1] == "underCanopy",
                 "CALLERS: the companion blast passes spare = %s" % (companion[0][1] if companion else "(no call)")))
    rows.append((all(f[1] is None for f in others),
                 "CALLERS: no other explosion passes spare (%s)" % ", ".join("%s=%s" % f for f in others)))
    return rows


def all_rows(root, psrc=None, csrc=None):
    psrc = psrc or read(root, *PROJECTILE)
    csrc = csrc or read(root, *SERVICE)
    projectile, ballistics, _ = blast_sources(root, psrc=psrc)
    companion = luau_to_lua(cut(csrc, "local function underCanopy(") + "\nlocal projectileService\nlocal blastId = 0\n"
                            + cut(csrc, "local function blastFor("))
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(read(root, "tools", "hitreg_mocks.lua"))
    run = lua.execute("return function(...) " + HARNESS + " end")
    out = run(mocks, projectile, ballistics, companion, luau_to_lua(read(root, *DATA)))
    rows = [(bool(r["ok"]), r["line"]) for r in out.values()]
    cs = read(root, "ServerScriptService", "Modules", "CombatService.lua")
    return rows + callers(root, {"CombatService.lua": cs, "CompanionService.lua": csrc, "ProjectileService.lua": psrc})


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        ps = read(root, *PROJECTILE)
        cs = read(root, *SERVICE)

        def swap(text, before, after):
            if text.count(before) != 1:
                sys.exit("companion_blast_canopy_check: plant target missing or not unique: " + before)
            return text.replace(before, after, 1)

        skip = "and not (blast.spare and blast.spare(victim.root.Parent)) then"
        plants = [
            # The invariant: a companion blast must never damage a parachuter.
            ("explode ignores spare", dict(psrc=swap(ps, skip, "then"))),
            ("the companion blast passes no spare", dict(csrc=swap(cs, "\t\tspare = underCanopy,\n", ""))),
            ("underCanopy looks for the wrong child", dict(csrc=swap(cs, 'FindFirstChild("GliderCanopy") ~= nil', 'FindFirstChild("Glider") ~= nil'))),
            # The guards: grounded players, and everything that isn't a companion, still take damage.
            ("a companion blast spares everyone", dict(psrc=swap(ps, skip, "and not blast.spare then"))),
            ("every blast spares a parachuter", dict(psrc=swap(ps, skip, 'and not victim.root.Parent:FindFirstChild("GliderCanopy") then'))),
        ]
        caught = 0
        for name, kw in plants:
            rows = all_rows(root, **kw)
            failed = [line for ok, line in rows if not ok]
            print(("CAUGHT  " if failed else "MISSED  ") + name + (("  <- " + failed[0]) if failed else ""))
            caught += bool(failed)
        print("companion_blast_canopy_check plants: %d of %d caught" % (caught, len(plants)))
        sys.exit(0 if caught == len(plants) else 1)
    rows = all_rows(root)
    for ok, line in rows:
        print(("ok    " if ok else "FAIL  ") + line)
    failed = sum(1 for ok, _ in rows if not ok)
    print("companion_blast_canopy_check: %d checks, %d failed" % (len(rows), failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
