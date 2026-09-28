"""Every seat on a bike can fire, a car passenger can, and a car's driver can't, checked without Studio.

Task 22 first barred every bike seat; Oliver reversed that on 2026-09-28 ("i want you to be able to
shoot from bikes"). The rule is CombatService.SeatBarsWeapons: a VehicleSeat, unless it is on a model
whose VehicleKind is "bike". The history below is task 22's.

A gun used to be refused only in a VehicleSeat, the driver's. A bike's pillion is a plain Seat, the
same as a car's passenger seat, so a player or a bot riding pillion could shoot, aim and throw. The
rule is now CombatService.SeatBarsWeapons: a VehicleSeat, or any seat on a model whose VehicleKind is
"bike".

Every drivable model in VehicleModels is mocked with its real kind and its real number of passenger
frames, seated with the classes VehicleService.Create gives them (read from its makeSeat calls), plus
the gun seat of an armed car. Then, cut out of the files as they stand and run in lupa:

  A  CombatService.IsDriving (the gate on Fire, throws and the range) for a player in every seat
  B  CombatClient's drivingVehicle and ProjectileClient's driving, the client mirrors, in every seat
  C  BotService's Vehicles.pickSeat: a bot offered a ride by a teammate at the wheel (VEHICLE.OFFER)
     takes a passenger seat, a bike's pillion included
  D  BotService's Vehicles.passengerThink with a foe in range, in every passenger seat: shoots from a
     car and from a bike's pillion alike (it stays on)
  E  static: the functions botVehicleThink runs for a riding bot (it returns before fight(), where the
     on-foot shots and throws are). None may call shootAt or tryThrow but passengerThink

The invariant: a passenger and every bike seat can always fire, a car's driver never can. The planted faults aim at
it from both sides.

    python3 tools/bike_guns_check.py [repo]            the checks
    python3 tools/bike_guns_check.py [repo] --plant    the planted faults; every one must be caught
"""

import os
import re
import sys

from lupa import LuaRuntime

CS = "ServerScriptService/Modules/CombatService.lua"
BS = "ServerScriptService/Modules/BotService.lua"
VS = "ServerScriptService/Modules/VehicleService.lua"
VM = "ReplicatedStorage/Shared/VehicleModels.lua"
CC = "StarterPlayerScripts/CombatClient.client.lua"
PC = "StarterPlayerScripts/ProjectileClient.client.lua"
FILES = (CS, BS, VS, VM, CC, PC)


def cut(src, header, optional=False):
    m = re.search(r"^" + re.escape(header) + r".*?^end$", src, re.M | re.S)
    if not m and optional:
        return ""
    if not m:
        raise SystemExit("bike_guns_check: cannot find `%s`" % header)
    return m.group(0)


def models(vm):
    """[(id, kind, passenger count, armed)] for every model in VehicleModels.Models."""
    mounts = vm[vm.index("VehicleModels.Mounts = {"):]
    mounts = mounts[:mounts.index("\n}\n")]
    found = []
    defs = list(re.finditer(r"^VehicleModels\.Models\.(\w+) = \{\n\tkind = \"(\w+)\"", vm, re.M))
    for i, m in enumerate(defs):
        body = vm[m.end():defs[i + 1].start() if i + 1 < len(defs) else len(vm)]
        at = body.index("passengers = {") + len("passengers = ")
        depth, frames = 0, 0
        for j in range(at, len(body)):
            ch = body[j]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
            elif depth == 1 and body.startswith("CF(", j):
                frames += 1
        armed = re.search(r"^\t%s = \{" % m.group(1), mounts, re.M) is not None
        found.append((m.group(1), m.group(2), frames, armed))
    return found


def seat_classes(vs):
    create = cut(vs, "function VehicleService.Create")
    classes = {}
    for role, name in (("driver", "DriverSeat"), ("passenger", "PassengerSeat"), ("gunner", "GunnerSeat")):
        m = re.search(r'makeSeat\("(\w+)", "%s' % name, create)
        if not m:
            raise SystemExit("bike_guns_check: VehicleService.Create makes no %s" % name)
        classes[role] = m.group(1)
    return classes


PRELUDE = r"""
local Inst = {}
Inst.__index = Inst
function Inst:IsA(class) return class == self.ClassName or class == "BasePart" or class == "Instance" end
function Inst:GetAttribute(k) return self.attrs[k] end
function Inst:FindFirstChild(name)
    for _, c in ipairs(self.children) do if c.Name == name then return c end end
    return nil
end
function Inst:FindFirstChildOfClass(class)
    for _, c in ipairs(self.children) do if c.ClassName == class then return c end end
    return nil
end
function inst(class, name, parent, attrs)
    local o = setmetatable({ ClassName = class, Name = name, Parent = parent, attrs = attrs or {}, children = {} }, Inst)
    if parent then table.insert(parent.children, o) end
    return o
end
function typeof(v)
    if getmetatable(v) == Inst then return "Instance" end
    return type(v)
end

-- A vehicle as VehicleService.Create leaves it: the model's VehicleKind, and its seats as children.
function vehicle(id, kind, passengers, armed, classes)
    local model = inst("Model", "Vehicle", nil, { VehicleKind = kind, VehicleModel = id })
    local seats = { driver = inst(classes.driver, "DriverSeat", model), passengers = {} }
    for i = 1, passengers do
        table.insert(seats.passengers, inst(classes.passenger, "PassengerSeat" .. i, model))
    end
    if armed and kind ~= "bike" then
        seats.gunner = inst(classes.gunner, "GunnerSeat", model, { Gunner = true })
    end
    model.seats = seats
    return model
end

-- A character sat in `seat` (nil: on foot), and a Player stand-in holding it.
function seated(seat, token)
    local character = inst("Model", "Character")
    character.token = token
    local humanoid = inst("Humanoid", "Humanoid", character)
    humanoid.SeatPart = seat
    return { Character = character }, humanoid
end
"""


def build(sources):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    # Optional only so the check can be pointed at a tree from before task 22 and show it red.
    cs = sources[CS]
    lua.execute("CombatService = {}\n" + cut(cs, "function CombatService.IsDriving") + "\n"
                + cut(cs, "function CombatService.SeatBarsWeapons", optional=True))
    mirrors = {}
    for rel, header, name in ((CC, "local function drivingVehicle()", "drivingVehicle"),
                              (PC, "local function driving()", "driving")):
        chunk = "return function(player)\n" + cut(sources[rel], header) + "\nreturn %s()\nend" % name
        mirrors[rel] = lua.execute(chunk)
    bs = sources[BS]
    lua.execute("Vehicles = {}\n" + cut(bs, "function Vehicles.pickSeat") + "\n" + cut(bs, "function Vehicles.passengerThink"))
    return lua, mirrors


# The world a bot sees in pickSeat and passengerThink: a teammate at the wheel of `model` offering a
# seat (its ride's offerUntil ahead), the bot not fighting, no storm, no gun to man, no trip.
BOT_WORLD = r"""
return function(model)
    local now = 100
    local driverToken = { name = "driver" }
    local _, driverHumanoid = seated(model.seats.driver, driverToken)
    model.seats.driver.Occupant = driverHumanoid
    riders = { [driverToken] = { offerUntil = now + 5 } }
    FLEE_WINDOW = 3
    VEHICLE = { FIGHT_SEEK = 90, RIDE_REACH = 40, FIGHT_CHANCE = 1, ROAM_GUN_CHANCE = 0 }
    MatchConfig = {}
    Combatants = { FromCharacter = function(character) return character.token end }
    flatDistance = function() return 0 end
    local vs = {
        VehiclesNear = function() return { { model = model, distance = 10 } } end,
        SeatsOf = function(m) return m.seats end,
    }
    lazy = function(name) if name == "VehicleService" then return vs end return nil end
    Vehicles.teamOf = function() return "Red" end
    Vehicles.stormPressed = function() return false end
    Vehicles.mountedGunSeat = function() return nil end
    Vehicles.friendlyHolder = function(team, holder) return holder ~= nil end
    Vehicles.botGunners = function() return false end
    Vehicles.preference = function() return 1 end
    Vehicles.shunned = function() return false end
    Vehicles.strangerAboard = function() return false end
    Vehicles.driverRoom = function() return true end
    Vehicles.travelGoal = function() return nil end
    local bot = { target = nil, threat = nil }
    local seat, role, purpose = Vehicles.pickSeat(bot, { Position = 0 }, now)
    return seat and seat.Name or "none", role or "none"
end
"""

PASSENGER = r"""
return function(model, seat)
    local now = 100
    local _, driverHumanoid = seated(model.seats.driver, { name = "driver" })
    model.seats.driver.Occupant = driverHumanoid
    local shots, left = 0, nil
    finishReload = function() end
    findTarget = function() return { token = "foe", root = {}, distance = 20 } end
    shootAt = function() shots = shots + 1 end
    Vehicles.leaveRide = function(_, reason) left = reason end
    local bot = { weapon = { range = 100 } }
    Vehicles.passengerThink(bot, {}, {}, { model = model, seat = seat }, now)
    return shots, left or "stayed"
end
"""


def static_calls(bs):
    """(ride functions examined, problems): what botVehicleThink runs for a riding bot, none of which may
    shoot or throw but passengerThink (D proves its guard). A riding bot returns before fight()."""
    think = cut(bs, "function Vehicles.botVehicleThink")
    riding = think[:think.index("if humanoid.SeatPart then")]
    names = sorted(set(re.findall(r"Vehicles\.(\w+)\(", riding)) - {"botVehicleThink"})
    problems = []
    if "passengerThink" not in names:
        problems.append("E: botVehicleThink no longer runs passengerThink for a riding bot; this check needs a look")
    for name in names:
        body = cut(bs, "function Vehicles.%s(" % name, optional=True)
        if not body:
            problems.append("E: botVehicleThink calls Vehicles.%s, which isn't defined as a function" % name)
            continue
        code = re.sub(r"--[^\n]*", "", body)
        for m in re.finditer(r"(?<![\w.])(shootAt|tryThrow)\(", code):
            if name != "passengerThink":
                problems.append("E: Vehicles.%s calls %s for a bot in a seat" % (name, m.group(1)))
    return len(names), problems


def run(sources):
    lua, mirrors = build(sources)
    classes = seat_classes(sources[VS])
    fleet = models(sources[VM])
    problems, counts = [], {"seats": 0, "vehicles": len(fleet), "bikes": 0, "cars": 0}
    make = lua.globals().vehicle
    pick = lua.execute(BOT_WORLD)
    ride = lua.execute(PASSENGER)
    table = lua.table_from
    for model_id, kind, passengers, armed in fleet:
        counts["bikes" if kind == "bike" else "cars"] += 1
        model = make(model_id, kind, passengers, armed, table(classes))
        seats = [("driver", model.seats.driver)] + [("passenger %d" % i, s) for i, s in model.seats.passengers.items()]
        if model.seats.gunner:
            seats.append(("gunner", model.seats.gunner))
        for label, seat in seats:
            counts["seats"] += 1
            player, _ = lua.globals().seated(seat, "player")
            want_barred = kind != "bike" and label == "driver"
            where = "%s %s (%s) %s seat" % (kind, model_id, seat.ClassName, label)
            if bool(lua.globals().CombatService.IsDriving(player)) != want_barred:
                problems.append("A: IsDriving lets a player %s from the %s" % ("fire" if want_barred else "NOT fire", where))
            for rel, fn in mirrors.items():
                if bool(fn(player)) != want_barred:
                    problems.append("B: %s lets the local player %s from the %s"
                                    % (os.path.basename(rel), "fire" if want_barred else "NOT fire", where))
        name, role = pick(make(model_id, kind, passengers, armed, table(classes)))
        if passengers > 0 and role != "passenger":
            problems.append("C: pickSeat offered a ride in %s gives the bot %s/%s, want a passenger seat" % (model_id, name, role))
        fresh = make(model_id, kind, passengers, armed, table(classes))
        for i, seat in fresh.seats.passengers.items():
            shots, left = ride(fresh, seat)
            if shots == 0 or left != "stayed":
                problems.append("D: a bot in %s passenger seat %d shot %d times and %s, want it shooting" % (model_id, i, shots, left))
    on_foot, _ = lua.globals().seated(None, "player")
    if lua.globals().CombatService.IsDriving(on_foot) or any(fn(on_foot) for fn in mirrors.values()):
        problems.append("A: a player on foot can't fire")
    examined, static = static_calls(sources[BS])
    counts["ride"] = examined
    return problems + static, counts


PLANTS = [
    ("the server rule bars a bike's rider", CS, 'vehicle:GetAttribute("VehicleKind") == "bike"', "false"),
    ("the server rule bars every seat", CS, 'return seat:IsA("VehicleSeat") and not', "return true or"),
    ("the server rule frees a car's driver", CS, 'return seat:IsA("VehicleSeat") and not', "return false and not"),
    ("CombatClient forgets bikes", CC, 'seat.Parent:GetAttribute("VehicleKind") == "bike"', 'seat.Parent:GetAttribute("VehicleKind") == "boat"'),
    ("ProjectileClient forgets bikes", PC, 'seat.Parent:GetAttribute("VehicleKind") == "bike"', 'seat.Parent:GetAttribute("VehicleKind") == "boat"'),
    ("pickSeat skips the pillion", BS, "if not passenger.Occupant and not CombatService.SeatBarsWeapons(passenger) then",
     "if not passenger.Occupant and passenger.Parent:GetAttribute('VehicleKind') ~= 'bike' then"),
    ("passengerThink leaves a bike", BS, "\tif CombatService.SeatBarsWeapons(ride.seat) then\n",
     "\tif ride.seat.Parent:GetAttribute('VehicleKind') == 'bike' then\n"),
    ("a car passenger never shoots", BS, "\tif candidate and candidate.distance <= bot.weapon.range then\n\t\tif bot.target",
     "\tif false then\n\t\tif bot.target"),
    ("the bike driver's think shoots", BS, "function Vehicles.driverThink(bot, root, head, ride, now)\n",
     "function Vehicles.driverThink(bot, root, head, ride, now)\n\tshootAt(bot, nil, nil, 0, head)\n"),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    sources = {rel: open(os.path.join(root, rel), encoding="utf-8").read() for rel in FILES}
    problems, counts = run(sources)
    print("bike_guns_check: %(vehicles)d models (%(bikes)d bikes, %(cars)d cars), %(seats)d seats, "
          "%(ride)d riding-bot functions examined" % counts)
    for p in problems:
        print("PROBLEM", p)
    print("problems: %d" % len(problems))
    ok = not problems
    if "--plant" in sys.argv:
        caught = 0
        for what, rel, anchor, replacement in PLANTS:
            if anchor not in sources[rel]:
                print("plant %-40s ANCHOR MISSING" % (what + ":"))
                ok = False
                continue
            planted = dict(sources)
            planted[rel] = sources[rel].replace(anchor, replacement, 1)
            found, _ = run(planted)
            caught += bool(found)
            print("plant %-40s %s (%d problems)%s" % (what + ":", "caught" if found else "MISSED", len(found),
                                                     (" e.g. " + found[0]) if found else ""))
            ok &= bool(found)
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
