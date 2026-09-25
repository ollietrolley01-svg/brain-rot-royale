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
per victim per debounce window. And the momentum rule's server half (RoadkillPass, Oliver 09-24): a
survivor is thrown along the direction of travel, a body carries the same throw into its ragdoll, the
hit opens the crash grace (the speed change is never collision damage), the server lets the body
through too, and a driver's client's report of a hit is believed only from the driver whose client
simulates that car, for a body beside the hull, at no more than the speed the server saw. (The
client half, RoadkillPass itself, is tools/roadkill_momentum_check.py.) What it cannot prove: that Roblox fires chassis.Touched on the server
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
    roadkill = between(vs, "-- Roadkill (#57)", "\n-- Weapons against vehicles", include_end=False)
    roadkill = roadkill[:roadkill.rindex("\n----")]
    deal = between(cs, "function CombatService.DealDamage(", "\n\treturn dealt\nend\n")
    last = between(cs, "function CombatService.GetLastAttacker(", "\nend\n")
    veto = between(mt, "function ModeTeams.DamageVeto(", "\nend\n")
    shared = os.path.join(root, "ReplicatedStorage", "Shared")
    rp = open(os.path.join(shared, "RoadkillPass.lua"), encoding="utf-8").read()
    va = open(os.path.join(shared, "VehicleArmor.lua"), encoding="utf-8").read()
    return consts, roadkill, deal, last, veto, rp, va


HARNESS = r"""
local consts, roadkill, deal, last, veto, rpSource, vaSource = ...
local now = 1000
tick = function() return now end
os = setmetatable({ clock = function() return now end }, { __index = os })

local V3 = {}
V3.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) return Vector3.new(v.X / m, v.Y / m, v.Z / m) end
    return nil
end
V3.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b)
    if type(a) == "number" then return Vector3.new(b.X * a, b.Y * a, b.Z * a) end
    if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
    return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b) return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __v3 = true }, V3) end }
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end

-- The real RoadkillPass (its pure half: Throw, After, Toll) on the real VehicleArmor.
local VehicleArmor = load(vaSource, "VehicleArmor")()
game = { GetService = function() return { WaitForChild = function() return { WaitForChild = function(_, n) return n end } end } end }
require = function(name) if name == "VehicleArmor" then return VehicleArmor end return nil end
RoadkillPass = load(rpSource, "RoadkillPass")()
ROADKILL_PASS_FLOOR = RoadkillPass.FLOOR

-- The throw, and the passes the server makes.
local launches, passes = {}, {}
script = { Parent = { WaitForChild = function() return "MovementService" end } }
local realRequire = require
require = function(name)
    if name == "MovementService" then
        return { Launch = function(character, velocity, kind) table.insert(launches, { character = character, velocity = velocity, kind = kind }) end }
    end
    return realRequire(name)
end
task = { delay = function() end }
-- Nobody here sits in an armoured cabin (roadkill_proof_check runs that rule, I8).
VehicleService = { ShieldingVehicle = function() return nil end }
local playerOf = {}
Players = { GetPlayerFromCharacter = function(_, c) return playerOf[c] end }
Enum = { HumanoidStateType = { FallingDown = "FallingDown" } }
SafeValue = { Number = function(v, limit) return type(v) == "number" and v == v and math.abs(v) <= (limit or math.huge) end }
byModel = {}
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
local function newCharacter(token, at)
    local character = { attributes = {}, Parent = true }
    instances[character] = true
    function character:IsA(c) return c == "Model" end
    function character:SetAttribute(k, v) self.attributes[k] = v end
    function character:GetAttribute(k) return self.attributes[k] end
    local root = { Position = at or Vector3.new(4, 0, 0) }
    function character:FindFirstChild(n) if n == "HumanoidRootPart" then return root end end
    local humanoid = { Health = 100, Parent = character, Destroying = signal(), states = {} }
    function humanoid:ChangeState(state) table.insert(self.states, state) end
    if typeof(token) == "Instance" then playerOf[character] = token end
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
ModeTeams = { IsProtected = function() return false end, BreakProtection = function() end }
load("local teamOf, active = ...\n" .. veto, "veto")(teamOf, false)
MatchConfig = { CombatDamageScale = 1 }
WeaponService = { AbsorbDamage = function(_, amount) return amount, 0 end }
QuestService = { Progress = function() end }
CombatService = { DamageListeners = {} }
-- The module's own game clock (the death recap's stamps), on the harness's time.
CombatService.Clock = function() return now end
CombatService.DamageVeto = function(...) return ModeTeams.DamageVeto(...) end
local lastAttacker, recent, stats = {}, {}, {}
local function statsFor(t) stats[t] = stats[t] or { hits = 0, headshots = 0, damageTaken = 0 } return stats[t] end
local remote = { FireClient = function() end }
local env = setmetatable({ lastAttacker = lastAttacker, recent = recent, statsFor = statsFor,
    damageDealt = remote, damageTaken = remote, RECAP_HITS = 8, ATTACKER_MEMORY = 10 }, { __index = _G })
load(deal, "DealDamage", "t", env)()
load(last, "GetLastAttacker", "t", env)()

-- hullDistance (the weapons section's): the harness's hull is a point at the chassis.
local chunk = consts .. "\n" .. roadkill .. "\nhullDistance = function(entry, point) return (point - entry.rig.chassis.Position).Magnitude end"
    .. "\nreturn onChassisTouched, onRoadkillReport, ROADKILL_FLOOR"
local onChassisTouched, onRoadkillReport, ROADKILL_FLOOR_SERVER = load(chunk, "roadkill")()

local function vehicle(speed, driverCharacter, driverPlayer, passengers)
    local seat = { Occupant = driverCharacter and driverCharacter:FindFirstChildOfClass("Humanoid") or nil }
    local occupants = { [seat] = seat.Occupant }
    for i, h in ipairs(passengers or {}) do occupants[i] = h end
    return {
        seat = seat, occupants = occupants, driverPlayer = driverPlayer, roadkillCooldown = {},
        rig = { chassis = { AssemblyLinearVelocity = Vector3.new(speed, 0, 0), Position = Vector3.new(0, 0, 0) } },
        roadkillPass = { Pass = function(_, character) table.insert(passes, character) return true end },
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

-- 9. the momentum rule's server half. One floor for both halves.
check("one floor: VehicleService's ROADKILL_FLOOR is RoadkillPass.FLOOR", ROADKILL_FLOOR_SERVER == ROADKILL_PASS_FLOOR,
    tostring(ROADKILL_FLOOR_SERVER) .. " vs " .. tostring(ROADKILL_PASS_FLOOR))
-- A survivor is thrown on along the direction of travel (+X here), up, and as a "blast" launch.
local jan = newPlayer("jan")
local janChar, janHum = newCharacter(jan, Vector3.new(3, 0, 1))
janHum.Health = 1000
for k in pairs(launches) do launches[k] = nil end
for k in pairs(passes) do passes[k] = nil end
local truck = vehicle(50, aliceChar, alice)
touch(truck, janChar)
local l = launches[1]
check("a survivor is thrown along the direction of travel, up and off to its own side", l ~= nil and l.character == janChar
    and l.kind == "blast" and l.velocity.X > 20 and l.velocity.Y > 10 and l.velocity.Z > 5 and l.velocity.Z < l.velocity.X,
    l and string.format("(%.1f, %.1f, %.1f) %s", l.velocity.X, l.velocity.Y, l.velocity.Z, tostring(l.kind)) or "no launch")
check("the hit opens the crash grace (the speed change is never collision damage)",
    truck.roadkillGraceUntil ~= nil and truck.roadkillGraceUntil > now, tostring(truck.roadkillGraceUntil))
check("the server lets the body through as well", passes[1] == janChar, tostring(passes[1]))
check("a survivor keeps no RoadkillThrow mark", janChar:GetAttribute("RoadkillThrow") == nil, "")
-- A lethal hit: no launch (the dead are the ragdoll's), the body carries the throw into it.
local kim = newPlayer("kim")
local kimChar, kimHum = newCharacter(kim, Vector3.new(3, 0, -1))
kimHum.Health = 5
for k in pairs(launches) do launches[k] = nil end
touch(vehicle(60, aliceChar, alice), kimChar)
local mark = kimChar:GetAttribute("RoadkillThrow")
check("a body carries the throw into its ragdoll", kimHum.Health <= 0 and #launches == 0 and mark ~= nil and mark.X > 20
    and mark.Z < -5,
    mark and string.format("(%.1f, %.1f, %.1f)", mark.X, mark.Y, mark.Z) or "no mark")
-- A bot is knocked down first (its humanoid would stand straight back up and walk off the launch); a
-- player's own client does that for a "blast", so the server leaves a player's state alone.
local botVictim = newBot("rolled")
local botVictimChar, botVictimHum = newCharacter(botVictim, Vector3.new(3, 0, 1))
botVictimHum.Health = 1000
for k in pairs(launches) do launches[k] = nil end
touch(vehicle(50, aliceChar, alice), botVictimChar)
check("a bot victim is knocked down before its throw; a player's state is its own client's",
    botVictimHum.states[1] == "FallingDown" and #launches == 1 and #janHum.states == 0,
    tostring(botVictimHum.states[1]) .. ", " .. #janHum.states .. " state changes on the player")
-- Under the floor there is nothing to throw and no grace.
local lou = newPlayer("lou")
local louChar = newCharacter(lou)
for k in pairs(launches) do launches[k] = nil end
local crawl = vehicle(10, aliceChar, alice)
touch(crawl, louChar)
check("under the floor: no throw, no grace", #launches == 0 and crawl.roadkillGraceUntil == nil, "")

-- 10. a driver's client's report (the car it simulates went through someone).
local function driven(speed, driver, driverChar)
    local v = vehicle(speed, driverChar, driver)
    v.owner = driver
    v.model = {}
    instances[v.model] = true
    byModel[v.model] = v
    driverChar.Parent = true
    driver.Character = driverChar
    return v
end
local max, ned, oz = newPlayer("max"), newPlayer("ned"), newPlayer("oz")
local maxChar = newCharacter(max)
local nedChar, nedHum = newCharacter(ned, Vector3.new(5, 0, 0))
local ozChar, ozHum = newCharacter(oz, Vector3.new(200, 0, 0))
local report = driven(40, max, maxChar)
onRoadkillReport(max, report.model, nedChar, 40)
check("a report from the driver whose client simulates the car lands", nedHum.Health < 100, "health " .. nedHum.Health)
onRoadkillReport(max, report.model, ozChar, 40)
check("a report of a body far from the hull is refused", ozHum.Health == 100, "health " .. ozHum.Health)
local pat = newPlayer("pat")
local patChar, patHum = newCharacter(pat, Vector3.new(5, 0, 0))
onRoadkillReport(ned, report.model, patChar, 40)
report.owner = false
onRoadkillReport(max, report.model, patChar, 40)
check("a report from anyone else, or while the server simulates the car, is refused", patHum.Health == 100, "health " .. patHum.Health)
report.owner = max
local quin = newPlayer("quin")
local quinChar, quinHum = newCharacter(quin, Vector3.new(5, 0, 0))
quinHum.Health = 1000
onRoadkillReport(max, report.model, quinChar, 900)
local capped = (40 * 1.15 + 4 - ROADKILL_FLOOR_V) * ROADKILL_PER_V
check("a report's speed is held to what the server saw", math.abs((1000 - quinHum.Health) - capped) < 1e-6,
    "dealt " .. (1000 - quinHum.Health) .. ", want " .. capped)

return results
"""


def run(root, mutate=None):
    consts, roadkill, deal, last, veto, rp, va = sources(root)
    if mutate:
        roadkill = mutate(roadkill)
    floor = float(re.search(r"ROADKILL_FLOOR = ([\d.]+)", consts).group(1))
    per = float(re.search(r"ROADKILL_DAMAGE_PER = ([\d.]+)", consts).group(1))
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROADKILL_FLOOR_V = floor
    lua.globals().ROADKILL_PER_V = per
    results = lua.execute(HARNESS, *(luau_to_lua(x) for x in (consts, roadkill, deal, last, veto, rp, va)))
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
    ("the survivor not thrown", sub("\t\tlaunch(character, throw)\n", "\n")),
    ("a bot's launch walked off (never knocked down)", sub("humanoid:ChangeState(Enum.HumanoidStateType.FallingDown)", "local _ = humanoid")),
    ("no crash grace after a hit", sub("entry.roadkillGraceUntil = now + ROADKILL_GRACE", "local _ = ROADKILL_GRACE")),
    ("a report from any player believed", sub("if not entry or entry.wrecked or entry.owner ~= player then",
                                              "if not entry or entry.wrecked then")),
    ("a report's reach not checked", sub("if hullDistance(entry, root.Position) > ROADKILL_REACH + seen * ROADKILL_LAG then",
                                         "if false then")),
    ("a report's speed taken on trust", sub("math.min(speed, seen * 1.15 + 4)", "speed")),
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
