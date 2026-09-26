"""Bots see and target vehicle riders (task 21), from the real source.

No Studio. This runs BotService's real `hostile`, `hasLineOfSight` and `findTarget` (with the sight
cache and the combatant grid they sit in) and the real VehicleCover module in a Lua interpreter (lupa),
against a mock world of axis-aligned boxes and a ray caster that honours the ray filter and CanQuery:

  a car (Rotster: doors, hood, trunk, roof; its glass is CanQuery=false, as VehicleModels builds it),
  a pickup (CrocodiloRanger: the car's cab plus a bed with low walls and riders in it),
  an armoured car (TartarugaScout: plate all round, queryable ArmorGlass, a roof hatch with a gunner),
  and a map wall.

A bot stands on the ground at 16 bearings x 30, 80 and 150 studs from each target (plus one case from
steeply above), and every case is a fresh bot, so the sight cache never answers for it. For each case it
records whether the target was seen (hasLineOfSight) and picked (findTarget), once for a git revision
(the "before", default the commit before this tool's first commit, pass --before REV) and once for the
working tree. The working tree must hold:

  OPEN     a rider on an open or car seat (car driver, passenger, bed, armoured car's hatch) is seen and
           picked from every side at every range (the target's own car is not a wall for its rider)
  SEALED   a rider inside an armoured cabin is never seen: its plate and armoured glass stay cover
  ROOF     a car rider seen from steeply above is hidden by the roof; a bed rider is not
  WALL     a car rider behind a map wall is never seen
  OWN CAR  a bot at the wheel still sees out through its own vehicle's body (the pickup's cab wall)
  FOOT     a target on foot: seen in the open, hidden behind a wall, the same before and after
  TRUCE    a bot never picks someone riding its own vehicle

    python tools/bot_rider_sight_check.py .              before/after and the checks
    python tools/bot_rider_sight_check.py . --plant      planted faults; every one must be caught

Not measured: the real car geometry (the boxes here are a stand-in for VehicleModels), the ray budget
under load, and anything a bot does after picking a target (shootAt applies the cover split).
"""

import importlib.util
import os
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("perf_bot_cost", os.path.join(HERE, "perf_bot_cost.py"))
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)

BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
VEHICLECOVER = "ReplicatedStorage/Shared/VehicleCover.lua"
PATHS = (BOTSERVICE, VEHICLECOVER)

HARNESS = perf.PRELUDE + r"""
local hostileSrc, targetSrc, coverSrc = ...
STATS = setmetatable({}, { __index = function() return 0 end })
MatchConfig = { BotVisionRange = 260, BotPlayerBias = 1.6, BotRearNoticeTime = 0.7 }
flat = function(v) return Vector3.new(v.X, 0, v.Z) end
-- Every bot faces its target, so the rear-notice delay never hides a result.
flatLook = function(root) return root.look end

-- Instances: a name, a parent, attributes, and the few methods the code under test calls.
local Inst = {}
Inst.__index = Inst
local function inst(name, parent, fields)
    local o = setmetatable(fields or {}, Inst)
    o.Name, o.Parent, o.attrs, o.children = name, parent, {}, {}
    if parent and parent.children then table.insert(parent.children, o) end
    return o
end
function Inst:IsDescendantOf(other)
    local node = self.Parent
    while node do
        if node == other then return true end
        node = node.Parent
    end
    return false
end
function Inst:GetAttribute(k) return self.attrs[k] end
function Inst:FindFirstChild(name)
    for _, c in ipairs(self.children) do if c.Name == name then return c end end
end
function Inst:FindFirstChildOfClass(class)
    for _, c in ipairs(self.children) do if c.class == class then return c end end
end
function Inst:IsA(class) return self.class == class end

workspace = inst("Workspace", nil)
local parts = {}
local rays = 0
local function box(name, parent, lo, hi, canQuery)
    local p = inst(name, parent, { class = "Part", lo = lo, hi = hi, CanQuery = canQuery ~= false })
    p.Position = (lo + hi) * 0.5
    parts[#parts + 1] = p
    return p
end
local function filtered(part, filter)
    for _, f in ipairs(filter or {}) do
        if part == f or part:IsDescendantOf(f) then return true end
    end
    return false
end
function workspace:Raycast(origin, direction, params)
    rays = rays + 1
    local best, bestT = nil, math.huge
    for _, p in ipairs(parts) do
        if p.CanQuery and p.Parent and not filtered(p, params.FilterDescendantsInstances) then
            local enter, leave, miss = 0, 1, false
            for _, axis in ipairs({ "X", "Y", "Z" }) do
                local o, d, lo, hi = origin[axis], direction[axis], p.lo[axis], p.hi[axis]
                if math.abs(d) < 1e-12 then
                    if o < lo or o > hi then miss = true end
                else
                    local t1, t2 = (lo - o) / d, (hi - o) / d
                    if t1 > t2 then t1, t2 = t2, t1 end
                    enter, leave = math.max(enter, t1), math.min(leave, t2)
                end
            end
            if not miss and enter <= leave and enter < bestT then best, bestT = p, enter end
        end
    end
    if best then return { Instance = best, Position = origin + direction * bestT } end
    return nil
end

-- Window panes on the map pass a sight ray (DestructibleService); nothing else does.
CombatService = {
    GetLastAttacker = function() return nil end,
    StructureFromPart = function() return nil end,
    DamageStructure = function() end,
    DestructiblePassesThrough = function(part) return part.Name == "WindowPane" end,
}
DefenseService = { OwnerOf = function() return nil end }

local IDENTITY = { VectorToObjectSpace = function(_, v) return v end }
VehicleCover = assert(load(coverSrc, "VehicleCover", "t", _ENV))()

local all, characters = {}, {}
Combatants = {
    All = function() return all end,
    IsPlayer = function() return false end,
    GetCharacter = function(token) return characters[token] end,
}
hostile = assert(load(hostileSrc, "hostile", "t", _ENV))()
local findTarget, refreshCombatants, hasLineOfSight = assert(load(targetSrc, "findTarget", "t", _ENV))()

local V = Vector3.new
local function character(name, rootPos)
    local c = inst(name, workspace, { class = "Model" })
    local root = box("HumanoidRootPart", c, rootPos - V(1, 1, 0.5), rootPos + V(1, 1, 0.5))
    root.look = V(0, 0, 1)
    local humanoid = inst("Humanoid", c, { class = "Humanoid", Health = 100, MaxHealth = 100 })
    return c, root, humanoid
end

-- A vehicle model at `at` (front toward -Z), built from boxes given relative to it.
local function vehicle(id, at, pieces, seats)
    local m = inst(id, workspace, { class = "Model" })
    m.attrs.VehicleModel = id
    m.PrimaryPart = { CFrame = IDENTITY }
    for _, p in ipairs(pieces) do box(p[1], m, at + p[2], at + p[3], p[4]) end
    local seatParts = {}
    for name, offset in pairs(seats) do
        seatParts[name] = box(name, m, at + offset - V(0.8, 0.2, 0.8), at + offset + V(0.8, 0, 0.8))
        seatParts[name].class = "Seat"
    end
    return m, seatParts
end
local CAB = {
    { "Chassis", V(-3, 0, -6), V(3, 1.5, 6) },
    { "Hood", V(-3, 1.5, -6), V(3, 2.3, -2.5) },
    { "DoorL", V(-3, 1.5, -2.5), V(-2.8, 3.4, 2.3) },
    { "DoorR", V(2.8, 1.5, -2.5), V(3, 3.4, 2.3) },
    { "Roof", V(-3, 5, -2.5), V(3, 5.3, 2.3) },
    { "Windscreen", V(-2.8, 3.4, -2.6), V(2.8, 5, -2.5), false },
    { "SideGlassL", V(-3, 3.4, -2.5), V(-2.8, 5, 2.3), false },
    { "SideGlassR", V(2.8, 3.4, -2.5), V(3, 5, 2.3), false },
}
local CAB_SEATS = { DriverSeat = V(-1.3, 1.7, -0.5), PassengerSeat1 = V(1.3, 1.7, -0.5) }
local function car(at)
    local pieces = { { "Trunk", V(-3, 1.5, 2.3), V(3, 2.6, 6) } }
    for _, p in ipairs(CAB) do pieces[#pieces + 1] = p end
    return vehicle("Rotster", at, pieces, CAB_SEATS)
end
local function pickup(at)
    local pieces = {
        { "CabBack", V(-3, 1.5, 2.3), V(3, 5, 2.5) },
        { "BedFloor", V(-3, 0, 2.5), V(3, 1.8, 9) },
        { "BedWallL", V(-3, 1.8, 2.5), V(-2.8, 3.0, 9) },
        { "BedWallR", V(2.8, 1.8, 2.5), V(3, 3.0, 9) },
        { "Tailgate", V(-3, 1.8, 8.8), V(3, 3.0, 9) },
    }
    for _, p in ipairs(CAB) do pieces[#pieces + 1] = p end
    return vehicle("CrocodiloRanger", at, pieces,
        { DriverSeat = CAB_SEATS.DriverSeat, PassengerSeat1 = CAB_SEATS.PassengerSeat1,
          PassengerSeat2 = V(-1.6, 1.7, 5.5) })
end
local function armoured(at)
    return vehicle("TartarugaScout", at, {
        { "Hull", V(-3.2, 0, -6), V(3.2, 1.5, 6) },
        { "ArmorGlacis", V(-3.2, 1.5, -6), V(3.2, 3.2, -2.6) },
        { "ArmorGlass1", V(-3.2, 3.2, -2.8), V(3.2, 5.2, -2.6) },
        { "ArmorFlankL", V(-3.2, 1.5, -2.6), V(-2.9, 5.2, 6) },
        { "ArmorFlankR", V(2.9, 1.5, -2.6), V(3.2, 5.2, 6) },
        { "HullRear", V(-3.2, 1.5, 5.7), V(3.2, 5.2, 6) },
        { "RoofL", V(-3.2, 5.2, -2.8), V(-1.2, 5.5, 6) },
        { "RoofR", V(1.2, 5.2, -2.8), V(3.2, 5.5, 6) },
        { "RoofF", V(-1.2, 5.2, -2.8), V(1.2, 5.5, 1.2) },
        { "RoofB", V(-1.2, 5.2, 3.2), V(1.2, 5.5, 6) },
        { "HatchRingF", V(-1.2, 5.5, 1.0), V(1.2, 6.5, 1.2) },
        { "HatchRingB", V(-1.2, 5.5, 3.2), V(1.2, 6.5, 3.4) },
        { "HatchRingL", V(-1.2, 5.5, 1.2), V(-1.0, 6.5, 3.2) },
        { "HatchRingR", V(1.0, 5.5, 1.2), V(1.2, 6.5, 3.2) },
    }, { DriverSeat = V(-1.3, 1.7, -0.5), PassengerSeat1 = V(1.3, 1.7, -0.5), GunnerSeat = V(0, 4.9, 2.2) })
end
-- Seat `c` (its humanoid) in `seat`, rooted 1.3 above it.
local function seatIn(seat, name)
    local c, root, humanoid = character(name, seat.Position + V(0, 1.3, 0))
    humanoid.SeatPart = seat
    return c, root, humanoid
end
local function clear()
    for _, p in ipairs(parts) do p.Parent = nil end
    parts = {}
    workspace.children = {}
    for k in pairs(all) do all[k] = nil end
end
local function addCombatant(token, c) all[c] = token; characters[token] = c end

-- One case: a fresh bot at `botAt` (a head 1.5 above its root), facing the target; returns seen, picked.
local function case(botAt, target, opts)
    opts = opts or {}
    local botChar, botRoot, botHumanoid
    if opts.botSeat then
        botChar, botRoot, botHumanoid = seatIn(opts.botSeat, "Bot")
    else
        botChar, botRoot, botHumanoid = character("Bot", botAt)
    end
    local bot = { character = botChar, humanoid = botHumanoid, lastHurtAt = -math.huge, weapon = { range = 300 },
        sight = {}, seen = {}, ownStructures = {}, ride = opts.ride }
    local head = { Position = botRoot.Position + V(0, 1.5, 0), Parent = true }
    local to = flat(target.root.Position - botRoot.Position)
    botRoot.look = to.Magnitude > 1e-6 and to.Unit or V(0, 0, 1)
    addCombatant(bot, botChar)
    addCombatant(target.token, target.character)
    CLOCK = CLOCK + 1
    refreshCombatants()
    local seen = hasLineOfSight(head, target.character, botChar)
    local c = findTarget(bot, botRoot, head, CLOCK)
    all[botChar] = nil
    botChar.Parent = nil
    for _, p in ipairs(botChar.children) do p.Parent = nil end
    return seen, c ~= nil and c.token == target.token
end

local BEARINGS, RANGES = 16, { 30, 80, 150 }
-- Sweep a target in a vehicle (or on foot) at the origin from every bearing and range.
-- build() makes the world and returns the target { token, character, root }.
local function sweep(build, opts)
    opts = opts or {}
    local seen, picked, total = 0, 0, 0
    for _, range in ipairs(RANGES) do
        for i = 0, BEARINGS - 1 do
            clear()
            local target = build()
            local a = i * 2 * math.pi / BEARINGS
            local centre = target.focus or target.root.Position
            local botAt = V(centre.X + math.sin(a) * range, 3, centre.Z - math.cos(a) * range)
            if opts.wall then
                -- A map wall across the line, 8 studs in front of the target, taller than any car.
                local mid = centre + (botAt - centre).Unit * 9
                box("MapWall", workspace, V(mid.X - 4, 0, mid.Z - 4), V(mid.X + 4, 14, mid.Z + 4))
            end
            local s, p = case(botAt, target)
            seen, picked, total = seen + (s and 1 or 0), picked + (p and 1 or 0), total + 1
        end
    end
    return seen, picked, total
end
local function above(build)
    clear()
    local target = build()
    local r = target.root.Position
    local s, p = case(V(r.X + 6, r.Y + 50, r.Z), target)
    return s and 1 or 0, p and 1 or 0, 1
end

local function rider(make, seatName)
    return function()
        local _, seats = make(V(0, 0, 0))
        local c, root = seatIn(seats[seatName], "Rider")
        return { token = { name = "rider" }, character = c, root = root, focus = V(0, 3, 0) }
    end
end
local function onFoot()
    local c, root = character("Walker", V(0, 3, 0))
    return { token = { name = "walker" }, character = c, root = root }
end

local out = {}
local function row(name, s, p, t) out[#out + 1] = { name, s, p, t } end
row("car driver", sweep(rider(car, "DriverSeat")))
row("car passenger", sweep(rider(car, "PassengerSeat1")))
row("pickup bed rider", sweep(rider(pickup, "PassengerSeat2")))
row("armoured hatch gunner", sweep(rider(armoured, "GunnerSeat")))
row("armoured cabin driver", sweep(rider(armoured, "DriverSeat")))
row("armoured cabin passenger", sweep(rider(armoured, "PassengerSeat1")))
row("car driver from above", above(rider(car, "DriverSeat")))
row("pickup bed rider from above", above(rider(pickup, "PassengerSeat2")))
row("car driver behind a map wall", sweep(rider(car, "DriverSeat"), { wall = true }))
row("on foot, open", sweep(onFoot))
row("on foot, behind a map wall", sweep(onFoot, { wall = true }))

-- OWN CAR: a bot at the wheel of the pickup, a target on foot all round it (the cab's back wall is
-- in the way to everyone behind).
do
    local seen, total = 0, 0
    for _, range in ipairs(RANGES) do
        for i = 0, BEARINGS - 1 do
            clear()
            local m, seats = pickup(V(0, 0, 0))
            local a = i * 2 * math.pi / BEARINGS
            local c, root = character("Walker", V(math.sin(a) * range, 3, -math.cos(a) * range))
            local s = case(nil, { token = { name = "walker" }, character = c, root = root },
                { botSeat = seats.DriverSeat, ride = { model = m } })
            seen, total = seen + (s and 1 or 0), total + 1
        end
    end
    row("own car: bot at the wheel sees out", seen, seen, total)
end

-- TRUCE: the bot rides the pickup's cab, the target its bed (in plain sight over the cab's back).
do
    clear()
    local m, seats = pickup(V(0, 0, 0))
    local c, root = seatIn(seats.PassengerSeat2, "Mate")
    local _, p = case(nil, { token = { name = "mate" }, character = c, root = root },
        { botSeat = seats.PassengerSeat1, ride = { model = m } })
    row("fellow rider picked", p and 1 or 0, p and 1 or 0, 1)
end

local flatOut = {}
for _, r in ipairs(out) do flatOut[#flatOut + 1] = table.concat({ r[1], r[2], r[3], r[4] }, "|") end
return table.concat(flatOut, "\n"), rays
"""


def hostile_source(bot_src):
    src = perf.between(bot_src, "local function hostile(bot, token)", "\nend\n", include_end=True)
    return perf.luau_to_lua(src.replace("local function hostile", "local function hostileFn", 1)) + "\nreturn hostileFn\n"


def target_source(bot_src):
    src = perf.between(bot_src, "local function hasLineOfSight", "-- Where a target was last seen")
    return perf.luau_to_lua(src) + "\nreturn findTarget, refreshCombatants, hasLineOfSight\n"


def measure(tree):
    lua = LuaRuntime(unpack_returned_tuples=True)
    text, rays = lua.execute(HARNESS, hostile_source(tree[BOTSERVICE]), target_source(tree[BOTSERVICE]),
                             perf.luau_to_lua(tree[VEHICLECOVER]))
    rows = {}
    for line in text.split("\n"):
        name, s, p, t = line.split("|")
        rows[name] = (int(s), int(p), int(t))
    return rows, int(rays)


def run(tree, before, verbose=True):
    after, rays = measure(tree)
    prior, _ = measure(before)
    if verbose:
        print(f"{'case':38} {'before seen/picked':>20} {'after seen/picked':>20}")
        for name, (s, p, t) in after.items():
            bs, bp, bt = prior.get(name, (0, 0, 0))
            print(f"  {name:36} {bs:>6}/{bp:<3} of {bt:<5} {s:>6}/{p:<3} of {t:<5}")
        print(f"candidate sight rays cast (after): {rays}")
    fails = []

    def want(name, seen_all=None, picked_all=None, none=False):
        s, p, t = after[name]
        if none and (s or p):
            fails.append(f"{name}: seen {s}, picked {p} of {t}, want 0")
        if seen_all and s != t:
            fails.append(f"{name}: seen {s} of {t}, want all")
        if picked_all and p != t:
            fails.append(f"{name}: picked {p} of {t}, want all")

    for name in ("car driver", "car passenger", "pickup bed rider", "armoured hatch gunner"):
        want(name, seen_all=True, picked_all=True)                      # OPEN
    for name in ("armoured cabin driver", "armoured cabin passenger"):
        want(name, none=True)                                           # SEALED
    want("car driver from above", none=True)                            # ROOF
    want("pickup bed rider from above", seen_all=True, picked_all=True)
    want("car driver behind a map wall", none=True)                     # WALL
    want("own car: bot at the wheel sees out", seen_all=True)           # OWN CAR
    want("on foot, open", seen_all=True, picked_all=True)               # FOOT
    want("on foot, behind a map wall", none=True)
    for name in ("on foot, open", "on foot, behind a map wall"):
        if name in prior and prior[name] != after[name]:
            fails.append(f"{name}: {prior[name]} before, {after[name]} after: foot targets changed")
    want("fellow rider picked", none=True)                              # TRUCE
    return fails


PLANTS = [
    (BOTSERVICE, "\t\tif side.body < 1 then\n", "\t\tif true then\n",
     "sealed: bots see through an armoured cabin"),
    (BOTSERVICE, "\tif node and node ~= workspace then\n\t\ttable.insert(filter, node)\n\tend\n", "",
     "own car: a bot at the wheel is walled in by its own vehicle"),
    (BOTSERVICE, "if not (result and CombatService.DestructiblePassesThrough and CombatService.DestructiblePassesThrough(result.Instance)) then",
     "if not result or result.Instance:IsDescendantOf(toCharacter) then",
     "wall: everything but the target is looked past like glass"),
    (BOTSERVICE, "if seat and seat.Parent == ride.model then", "if seat and seat.Parent == nil then",
     "truce: a bot targets its fellow rider"),
    (BOTSERVICE, "\tif coverModel and coverModel ~= node then\n", "\tif false then\n",
     "open: the target's car is a wall for its rider again"),
]


def main():
    args = sys.argv[1:]
    root = args[0] if args and not args[0].startswith("--") else "."
    tree = {p: perf.read_tree(root, p) for p in PATHS}
    rev = args[args.index("--before") + 1] if "--before" in args else perf.default_before(root, "tools/bot_rider_sight_check.py")
    try:
        before = {p: perf.read_rev(root, rev, p) for p in PATHS}
    except perf.NoRevision as err:
        perf.no_before_note("bot_rider_sight_check", err)
        rev, before = "working tree: no git", dict(tree)

    if "--plant" in args:
        caught = 0
        for path, old, new, what in PLANTS:
            assert tree[path].count(old) == 1, f"plant text not found once in {path}: {old!r}"
            planted = dict(tree)
            planted[path] = tree[path].replace(old, new)
            try:
                fails = run(planted, before, verbose=False)
            except Exception as err:  # a plant that breaks the harness counts as caught, loudly
                fails = [f"harness error: {err}"]
            caught += bool(fails)
            print(f"plant [{'CAUGHT' if fails else 'MISSED'}] {what}: {fails[0] if fails else 'no check failed'}")
        print(f"bot_rider_sight_check plants: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)

    print(f"--- before {rev}, after the working tree")
    fails = run(tree, before)
    for f in fails:
        print("FAIL", f)
    print(f"bot_rider_sight_check: {len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
