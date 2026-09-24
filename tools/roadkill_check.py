"""Behaviour check for roadkill (#57 / #110), without Studio.

Runs the REAL roadkill section of ServerScriptService/Modules/VehicleService.lua (onChassisTouched and
its driver lookup), the REAL CombatService.DealDamage / GetLastAttacker and the REAL
ModeTeams.DamageVeto in a Lua interpreter (lupa), with instances, tokens and the clock mocked, and
touches a vehicle's chassis against players and bots the way chassis.Touched would.

    python tools/roadkill_check.py .            the checks
    python tools/roadkill_check.py . --plant    the planted faults; every one must be caught

What it proves: a car over the speed floor damages whoever it touches through the gun pathway and the
kill is credited to whoever is in the driving seat, player OR bot (the credit is what the kill feed,
rewards and streaks read, via CombatService.GetLastAttacker -> HandleDeath -> OnElimination); a bot
driver's team is respected in a team mode; nothing under the floor, never the car's own riders, once
per victim per debounce window. What it cannot prove: that Roblox fires chassis.Touched on the server
for a client-owned car hitting a character (tools/vehicle_health_probe.lua's roadkill test, in Studio).

Needs `pip install lupa`. Luau's compound assignments are rewritten to plain Lua before loading.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("roadkill_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]()]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def between(text, start, end, include_end=True):
    a = text.index(start)
    b = text.index(end, a)
    return text[a:b + (len(end) if include_end else 0)]


def sources(root):
    vs = open(os.path.join(root, "ServerScriptService", "Modules", "VehicleService.lua"), encoding="utf-8").read()
    cs = open(os.path.join(root, "ServerScriptService", "Modules", "CombatService.lua"), encoding="utf-8").read()
    mt = open(os.path.join(root, "ServerScriptService", "Modules", "ModeTeams.lua"), encoding="utf-8").read()
    consts = "\n".join(re.findall(r"^local ROADKILL_\w+ = [\d.]+", vs, flags=re.M))
    roadkill = between(vs, "-- Roadkill (#57)", "\n-- Create\n", include_end=False)
    roadkill = roadkill[:roadkill.rindex("\n----")]
    deal = between(cs, "function CombatService.DealDamage(", "\n\treturn dealt\nend\n")
    last = between(cs, "function CombatService.GetLastAttacker(", "\nend\n")
    veto = between(mt, "function ModeTeams.DamageVeto(", "\nend\n")
    return consts, roadkill, deal, last, veto


HARNESS = r"""
local consts, roadkill, deal, last, veto = ...
local now = 1000
tick = function() return now end
os = setmetatable({ clock = function() return now end }, { __index = os })

Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z) } end }
local function signal() return { Connect = function() return { Disconnect = function() end } end } end

-- Tokens: a player is an "Instance" that IsA Player; a bot is a table with isBot.
local instances = {}
typeof = function(v) if instances[v] then return "Instance" end return type(v) end
local function newPlayer(name)
    local p = { Name = name, IsA = function(_, c) return c == "Player" end }
    instances[p] = true
    return p
end
local function newBot(name) return { isBot = true, name = name } end

local byCharacter, humanoidOf = {}, {}
local function newCharacter(token)
    local character = {}
    local humanoid = { Health = 100, Parent = character, Destroying = signal() }
    function humanoid:TakeDamage(n) self.Health = math.max(0, self.Health - n) end
    function humanoid:GetAttribute() return 0 end
    function humanoid:SetAttribute() end
    function character:FindFirstChildOfClass(c) if c == "Humanoid" then return humanoid end end
    byCharacter[character], humanoidOf[token] = token, humanoid
    return character, humanoid
end

Combatants = {
    FromCharacter = function(c) return c and byCharacter[c] end,
    IsPlayer = function(t) return typeof(t) == "Instance" end,
    GetHumanoid = function(t) return humanoidOf[t] end,
    GetRoot = function() return nil end,
    GetName = function(t) return tostring(t) end,
}
local teamOf, active = {}, false
ModeTeams = { IsProtected = function() return false end }
load("local teamOf, active = ...\n" .. veto, "veto")(teamOf, false)
MatchConfig = { CombatDamageScale = 1 }
WeaponService = { AbsorbDamage = function(_, amount) return amount, 0 end }
QuestService = { Progress = function() end }
CombatService = { DamageListeners = {} }
CombatService.DamageVeto = function(...) return ModeTeams.DamageVeto(...) end
local lastAttacker, recent, stats = {}, {}, {}
local function statsFor(t) stats[t] = stats[t] or { hits = 0, headshots = 0, damageTaken = 0 } return stats[t] end
local remote = { FireClient = function() end }
local env = setmetatable({ lastAttacker = lastAttacker, recent = recent, statsFor = statsFor,
    damageDealt = remote, damageTaken = remote, RECAP_HITS = 8, ATTACKER_MEMORY = 10 }, { __index = _G })
load(deal, "DealDamage", "t", env)()
load(last, "GetLastAttacker", "t", env)()

local chunk = consts .. "\n" .. roadkill .. "\nreturn onChassisTouched"
local onChassisTouched = load(chunk, "roadkill")()

local function vehicle(speed, driverCharacter, driverPlayer, passengers)
    local seat = { Occupant = driverCharacter and driverCharacter:FindFirstChildOfClass("Humanoid") or nil }
    local occupants = { [seat] = seat.Occupant }
    for i, h in ipairs(passengers or {}) do occupants[i] = h end
    return {
        seat = seat, occupants = occupants, driverPlayer = driverPlayer, roadkillCooldown = {},
        rig = { chassis = { AssemblyLinearVelocity = Vector3.new(speed, 0, 0) } },
    }
end
local function touch(entry, character) onChassisTouched(entry, { Parent = character }) end
local function setTeams(on, map)
    for k in pairs(teamOf) do teamOf[k] = nil end
    for k, v in pairs(map or {}) do teamOf[k] = v end
    load("local teamOf, active = ...\n" .. veto, "veto")(teamOf, on)
end

local results = {}
local function check(name, ok, detail) table.insert(results, { name, ok and true or false, detail or "" }) end

-- 1. player driver at 40 studs/s into a player.
local alice, bob = newPlayer("alice"), newPlayer("bob")
local aliceChar = newCharacter(alice)
local bobChar, bobHum = newCharacter(bob)
local car = vehicle(40, aliceChar, alice)
touch(car, bobChar)
local who, weapon = CombatService.GetLastAttacker(bob)
check("player driver: victim damaged", bobHum.Health < 100, "health " .. bobHum.Health)
check("player driver: credited to the driver as Roadkill", who == alice and weapon == "Roadkill", tostring(who) .. " " .. tostring(weapon))

-- 2. bot driver (armed vehicles are the ones BotService drives) into a player.
local bot, carol = newBot("bot"), newPlayer("carol")
local botChar = newCharacter(bot)
local carolChar, carolHum = newCharacter(carol)
touch(vehicle(40, botChar, nil), carolChar)
who = CombatService.GetLastAttacker(carol)
check("bot driver: victim damaged", carolHum.Health < 100, "health " .. carolHum.Health)
check("bot driver: credited to the bot", who == bot, tostring(who))

-- 3. bot driver into a bot on its own team, team mode on: vetoed; on the other team: lands.
local mate, foe = newBot("mate"), newBot("foe")
local mateChar, mateHum = newCharacter(mate)
local foeChar, foeHum = newCharacter(foe)
setTeams(true, { [bot] = 1, [mate] = 1, [foe] = 2 })
touch(vehicle(40, botChar, nil), mateChar)
touch(vehicle(40, botChar, nil), foeChar)
check("team mode: bot driver never roadkills its own team", mateHum.Health == 100, "health " .. mateHum.Health)
check("team mode: bot driver still roadkills the other team", foeHum.Health < 100, "health " .. foeHum.Health)
setTeams(false)

-- 4. under the floor: nothing, across the whole band a parked or crawling car lives in.
local dave = newPlayer("dave")
local daveChar, daveHum = newCharacter(dave)
for _, s in ipairs({ 0, 4, 8, 11.9, 12 }) do touch(vehicle(s, aliceChar, alice), daveChar) end
check("at or under the floor: no damage (5 speeds)", daveHum.Health == 100, "health " .. daveHum.Health)
-- ...and a crawl never arms the debounce: the same car speeding up into dave a moment later lands.
local creep = vehicle(8, aliceChar, alice)
touch(creep, daveChar)
now = now + 0.1
creep.rig.chassis.AssemblyLinearVelocity = Vector3.new(40, 0, 0)
touch(creep, daveChar)
check("a touch under the floor never swallows the real hit that follows", daveHum.Health < 100, "health " .. daveHum.Health)

-- 5. never the car's own passenger (nor its driver).
local erin = newPlayer("erin")
local erinChar, erinHum = newCharacter(erin)
local bus = vehicle(40, aliceChar, alice, { erinHum })
touch(bus, erinChar)
touch(bus, aliceChar)
check("never the car's own riders", erinHum.Health == 100 and humanoidOf[alice].Health == 100,
    "erin " .. erinHum.Health .. " alice " .. humanoidOf[alice].Health)

-- 6. debounce: sixty touches inside half a second are one hit; after the window, a second.
local fred = newPlayer("fred")
local fredChar, fredHum = newCharacter(fred)
fredHum.Health = 1000
local van = vehicle(30, aliceChar, alice)
for _ = 1, 60 do touch(van, fredChar) now = now + 0.005 end
local one = 1000 - fredHum.Health
now = now + 0.6
touch(van, fredChar)
local two = 1000 - fredHum.Health
check("debounce: 60 touches in 0.3 s deal one hit", one > 0 and math.abs(one - (30 - ROADKILL_FLOOR_V) * ROADKILL_PER_V) < 1e-6, "dealt " .. one)
check("debounce: a touch after the window deals a second hit", math.abs(two - 2 * one) < 1e-6, "dealt " .. two)

-- 7. damage scales with speed over the floor.
local gus, hal = newPlayer("gus"), newPlayer("hal")
local gusChar, gusHum = newCharacter(gus)
local halChar, halHum = newCharacter(hal)
touch(vehicle(20, aliceChar, alice), gusChar)
touch(vehicle(50, aliceChar, alice), halChar)
check("faster hits harder", (100 - halHum.Health) > (100 - gusHum.Health) and gusHum.Health < 100,
    "20 studs/s " .. (100 - gusHum.Health) .. ", 50 studs/s " .. (100 - halHum.Health))

-- 8. a driverless car (bail at speed, rolling wreck) still hurts, credited to no one.
local ivy = newPlayer("ivy")
local ivyChar, ivyHum = newCharacter(ivy)
touch(vehicle(40, nil, nil), ivyChar)
check("driverless car: hurts, credits no one", ivyHum.Health < 100 and CombatService.GetLastAttacker(ivy) == nil, "health " .. ivyHum.Health)

return results
"""


def run(root, mutate=None):
    consts, roadkill, deal, last, veto = sources(root)
    if mutate:
        roadkill = mutate(roadkill)
    floor = float(re.search(r"ROADKILL_FLOOR = ([\d.]+)", consts).group(1))
    per = float(re.search(r"ROADKILL_DAMAGE_PER = ([\d.]+)", consts).group(1))
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROADKILL_FLOOR_V = floor
    lua.globals().ROADKILL_PER_V = per
    results = lua.execute(HARNESS, *(luau_to_lua(x) for x in (consts, roadkill, deal, last, veto)))
    return [(r[1], bool(r[2]), r[3]) for r in results.values()]


def sub(old, new):
    def f(text):
        if old not in text:
            raise SystemExit("roadkill_check: plant target not found: " + old)
        return text.replace(old, new, 1)
    return f


PLANTS = [
    ("credit goes to driverPlayer only (the pre-#110 code)",
     sub("return (character and Combatants.FromCharacter(character)) or entry.driverPlayer", "return entry.driverPlayer")),
    ("no speed floor", sub("if flat <= ROADKILL_FLOOR then", "if flat < 0 then")),
    ("riders not excluded", sub("if occupant == humanoid then", "if false then")),
    ("no debounce", sub("if last and now - last < ROADKILL_DEBOUNCE then", "if false then")),
    ("damage flat, not scaled by speed", sub("(flat - ROADKILL_FLOOR) * ROADKILL_DAMAGE_PER", "30")),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        missed = 0
        for name, mutate in PLANTS:
            failed = [r[0] for r in run(root, mutate) if not r[1]]
            print(("CAUGHT " if failed else "MISSED ") + name + (" -> " + "; ".join(failed) if failed else ""))
            missed += 0 if failed else 1
        print(f"roadkill plants: {len(PLANTS) - missed}/{len(PLANTS)} caught")
        sys.exit(1 if missed else 0)
    results = run(root)
    bad = 0
    for name, ok, detail in results:
        print(("ok   " if ok else "FAIL ") + name + ("  (" + detail + ")" if detail else ""))
        bad += 0 if ok else 1
    print(f"roadkill check: {len(results)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
