"""Behaviour check for the momentum rule of roadkill (RoadkillPass), without Studio.

Oliver 09-24: "make vehicles keep their momentum when they do a roadkill". Runs the REAL
ReplicatedStorage/Shared/RoadkillPass.lua (on the real VehicleArmor) in a Lua interpreter (lupa), with
parts, bodies, the overlap query and the constraints mocked, and steps it the way VehicleClient's drive
loop and VehicleService's step do: once per frame, before the physics.

    python tools/roadkill_momentum_check.py .            the checks
    python tools/roadkill_momentum_check.py . --plant    the planted faults; every one must be caught

What it proves: over the floor, a live body in the vehicle's path is let through BEFORE the contact
(constraints between every collider and every limb), the vehicle gives up exactly its toll of flat speed
(armoured less than a car, a car less than a bike, a few percent at most) with its heading, vertical
speed and spin kept, and the hit is reported once; a body that came in from the side and already cost
some speed has that given back; a dead body goes through for nothing; the vehicle's own riders are never
hit; under the floor nothing happens (bodies collide, a nudge stays a nudge); a body is let go again only
once it is clear. What it cannot prove: what Roblox's physics does with the constraints and the new
velocity -- tools/roadkill_momentum_probe.lua measures that in Studio (Run mode, a server-simulated car
and a server-simulated body).
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("roadkill_momentum_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]()]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


HARNESS = r"""
local rpSource, vaSource = ...

local V3 = {}
V3.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
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
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3) end }
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end

-- Frames without rotation: the vehicles here drive along -Z.
local CF = {}
CF.__index = CF
CF.__add = function(f, v) return setmetatable({ Position = f.Position + v }, CF) end
function CF:VectorToObjectSpace(v) return v end
local function frame(p) return setmetatable({ Position = p }, CF) end

Enum = { RaycastFilterType = { Exclude = "Exclude" } }
OverlapParams = { new = function() return {} end }

local live = 0
Instance = { new = function(class)
    assert(class == "NoCollisionConstraint", class)
    live = live + 1
    local c = { ClassName = class }
    function c:Destroy() if not self.gone then self.gone = true live = live - 1 end end
    return c
end }

-- The world: every part the overlap query can find.
local world = {}
local function isA(self, c)
    if c == "BasePart" then return self.kind == "part" or self.kind == "seat" or self.kind == "vseat" end
    if c == "Seat" then return self.kind == "seat" end
    if c == "VehicleSeat" then return self.kind == "vseat" end
    if c == "Model" then return self.kind == "model" end
    return false
end
local function ancestorModel(self)
    local p = self.Parent
    while p do
        if p.kind == "model" then return p end
        p = p.Parent
    end
    return nil
end
local function newModel(name, parent)
    local m = { kind = "model", Name = name, Parent = parent, children = {}, attrs = {} }
    m.IsA = isA
    m.FindFirstAncestorOfClass = function(self, c) return c == "Model" and ancestorModel(self) or nil end
    function m:GetAttribute(k) return self.attrs[k] end
    function m:GetChildren() return self.children end
    function m:GetDescendants()
        local out = {}
        local function walk(x) for _, c in ipairs(x.children or {}) do table.insert(out, c) walk(c) end end
        walk(self)
        return out
    end
    function m:FindFirstChildOfClass(c)
        for _, x in ipairs(self.children) do if x.class == c then return x end end
        return nil
    end
    function m:FindFirstChild(n)
        for _, x in ipairs(self.children) do if x.Name == n then return x end end
        return nil
    end
    if parent then table.insert(parent.children, m) end
    return m
end
local function newPart(name, parent, at, size, collide, kind)
    local p = { kind = kind or "part", Name = name, Parent = parent, Position = at, Size = size, CanCollide = collide ~= false,
        children = {} }
    p.CFrame = frame(at)
    p.IsA = isA
    p.FindFirstAncestorOfClass = function(self, c) return c == "Model" and ancestorModel(self) or nil end
    table.insert(parent.children, p)
    table.insert(world, p)
    return p
end

workspace = {}
function workspace:GetPartBoundsInBox(f, size, params)
    local out = {}
    local lo, hi = f.Position - size / 2, f.Position + size / 2
    for _, p in ipairs(world) do
        local excluded = false
        for _, ex in ipairs(params.FilterDescendantsInstances or {}) do
            local a = p
            while a do if a == ex then excluded = true break end a = a.Parent end
        end
        if not excluded and p.Parent and p.inWorld ~= false then
            local q, h = p.Position, p.Size / 2
            if q.X + h.X >= lo.X and q.X - h.X <= hi.X and q.Y + h.Y >= lo.Y and q.Y - h.Y <= hi.Y
                and q.Z + h.Z >= lo.Z and q.Z - h.Z <= hi.Z then
                table.insert(out, p)
            end
        end
    end
    return out
end

local VehicleArmor = load(vaSource, "VehicleArmor")()
game = { GetService = function() return { WaitForChild = function() return { WaitForChild = function(_, n) return n end } end } end }
require = function(name) if name == "VehicleArmor" then return VehicleArmor end return nil end
local RP = load(rpSource, "RoadkillPass")()

-- A vehicle: chassis 6 x 3 x 12 at `at`, one hull on its roof, a driving seat and a passenger seat.
local function vehicle(modelId, kind, at, velocity)
    local model = newModel(modelId, scene)
    model.attrs.VehicleModel = modelId
    model.attrs.VehicleKind = kind
    local chassis = newPart("Chassis", model, at, Vector3.new(6, 3, 12))
    chassis.AssemblyLinearVelocity = velocity
    chassis.AssemblyAngularVelocity = Vector3.new(0, 0.7, 0)
    newPart("Hull_Roof", model, at + Vector3.new(0, 2.5, 1), Vector3.new(5, 2, 6))
    newPart("Wheel", model, at + Vector3.new(3, -1.5, -4), Vector3.new(1, 2, 2), false)
    local seat = newPart("DriverSeat", model, at + Vector3.new(-1, 1, 0), Vector3.new(2, 1, 2), false, "vseat")
    local rideSeat = newPart("Passenger1", model, at + Vector3.new(1, 1, 0), Vector3.new(2, 1, 2), false, "seat")
    return model, chassis, seat, rideSeat
end

-- A body: root and limbs (R15-ish, 5 parts here) around `at`, with a humanoid.
local scene = { kind = "folder", Name = "Workspace", children = {} }
local function body(name, at, health)
    local m = newModel(name, scene)
    local humanoid = { class = "Humanoid", Health = health or 100, Parent = m, IsA = function() return false end }
    table.insert(m.children, humanoid)
    newPart("HumanoidRootPart", m, at, Vector3.new(2, 2, 1))
    newPart("UpperTorso", m, at + Vector3.new(0, 0.5, 0), Vector3.new(2, 1, 1))
    newPart("LowerTorso", m, at + Vector3.new(0, -0.5, 0), Vector3.new(2, 0.5, 1))
    newPart("LeftLeg", m, at + Vector3.new(-0.5, -2, 0), Vector3.new(1, 2, 1))
    newPart("RightLeg", m, at + Vector3.new(0.5, -2, 0), Vector3.new(1, 2, 1))
    return m, humanoid
end

local function move(m, by)
    for _, p in ipairs(m:GetDescendants()) do if p.Position then p.Position = p.Position + by p.CFrame = frame(p.Position) end end
end

local results = {}
local function check(name, ok, detail) table.insert(results, { name, ok and true or false, detail or "" }) end
local function flat(v) return math.sqrt(v.X * v.X + v.Z * v.Z) end
local dt = 1 / 60
local now = 100

-- 1. the tolls.
local tA, tA2 = RP.Toll("CameloCarrier", "car"), RP.Toll("TartarugaScout", "car")
local tC, tB = RP.Toll("Rotster", "car"), RP.Toll("BrrStreetfighter", "bike")
check("tolls: armoured < car < bike, each a few percent at most", tA > 0 and tA2 == tA and tA < tC and tC < tB and tB <= 0.05,
    string.format("armoured %.3f, car %.3f, bike %.3f", tA, tC, tB))

-- 2. a live body just ahead of a car at 60: let through before contact, the toll and nothing more, once.
local hits = {}
local model, chassis = vehicle("Rotster", "car", Vector3.new(0, 3, 0), Vector3.new(0, -1.5, -60))
local pass = RP.new(model, chassis, function(character, speed, velocity) table.insert(hits, { character = character, speed = speed, velocity = velocity }) end)
-- 1.4 studs clear of the chassis's front face (z = -6), past the margin: only the look-ahead finds it
-- (the car covers 1 stud a step, so the contact would come in the step after next).
local bob = body("Bob", Vector3.new(0, 3, -7.9))
local n = pass:Sweep(dt, now)
local v = chassis.AssemblyLinearVelocity
local want = 60 * (1 - tC)
check("over the floor: a body in the path is one hit, reported at the speed before the toll",
    n == 1 and #hits == 1 and hits[1].character == bob and math.abs(hits[1].speed - 60) < 1e-6,
    string.format("%d hits, speed %s", #hits, hits[1] and string.format("%.2f", hits[1].speed) or "-"))
check("the vehicle keeps its speed less the toll, its heading and its vertical speed",
    math.abs(flat(v) - want) < 1e-6 and math.abs(v.X) < 1e-9 and v.Z < 0 and math.abs(v.Y + 1.5) < 1e-9,
    string.format("(%.3f, %.3f, %.3f), want flat %.3f", v.X, v.Y, v.Z, want))
check("the vehicle keeps its spin", math.abs(chassis.AssemblyAngularVelocity.Y - 0.7) < 1e-9, "")
check("the body is let through before the contact (every collider x every limb)", live == 2 * 5, live .. " constraints")
-- The next steps the car is through it: no second hit, no second toll.
for _ = 1, 10 do now = now + dt pass:Sweep(dt, now) end
check("one body is one hit: no second toll while it is going through", #hits == 1 and math.abs(flat(chassis.AssemblyLinearVelocity) - want) < 1e-6,
    #hits .. " hits")

-- 3. a body well beyond this step's travel is not touched yet.
local far = body("Far", Vector3.new(0, 3, -30))
now = now + dt
pass:Sweep(dt, now)
check("a body beyond this step's reach is left alone", #hits == 1 and live == 10, #hits .. " hits, " .. live .. " constraints")
far.Parent = nil
for _, p in ipairs(far:GetDescendants()) do p.inWorld = false end

-- 4. a dead body (a ragdoll on the road): let through, for nothing.
local speedBefore = flat(chassis.AssemblyLinearVelocity)
local corpse = body("Corpse", Vector3.new(1, 1.5, -7), 0)
now = now + dt
pass:Sweep(dt, now)
check("a dead body is let through for nothing: no toll, no hit", #hits == 1 and live == 20
    and math.abs(flat(chassis.AssemblyLinearVelocity) - speedBefore) < 1e-9, #hits .. " hits, " .. live .. " constraints")

-- 4b. a body let through the hull is let through the riders inside it too (their solid parts only).
local modelR, chassisR, seatR = vehicle("TralalaGT", "car", Vector3.new(500, 3, 0), Vector3.new(0, 0, -50))
local passR = RP.new(modelR, chassisR, function() end)
local driverR, driverRHum = body("DriverR", Vector3.new(499, 4, 0))
seatR.Occupant = driverRHum
for _, p in ipairs(driverR:GetChildren()) do if p.Name == "LeftLeg" or p.Name == "RightLeg" then p.CanCollide = false end end
local beforeR = live
body("Walker", Vector3.new(500, 3, -6.9))
passR:Sweep(dt, now)
check("the riders' solid parts are let through too (colliders + solid rider parts, x the body's parts)",
    live - beforeR == (2 + 3) * 5, (live - beforeR) .. " constraints, want " .. (2 + 3) * 5)

-- 5. the vehicle's own riders are never hit.
local model2, chassis2, seat2, ride2 = vehicle("SahurVan", "car", Vector3.new(100, 3, 0), Vector3.new(0, 0, -50))
local hits2 = {}
local pass2 = RP.new(model2, chassis2, function(c) table.insert(hits2, c) end)
local rider, riderHum = body("Rider", Vector3.new(101, 4, 0))
ride2.Occupant = riderHum
local driverBody, driverHum = body("Driver", Vector3.new(99, 4, 0))
seat2.Occupant = driverHum
pass2:Sweep(dt, now)
check("never the vehicle's own riders", #hits2 == 0 and flat(chassis2.AssemblyLinearVelocity) == 50, #hits2 .. " hits")

-- 6. under the floor: nothing at all -- the body collides, a nudge stays a nudge.
local model3, chassis3 = vehicle("TralalaGT", "car", Vector3.new(200, 3, 0), Vector3.new(0, 0, -(RP.FLOOR - 0.5)))
local hits3 = {}
local pass3 = RP.new(model3, chassis3, function(c) table.insert(hits3, c) end)
local before = live
body("Nudged", Vector3.new(200, 3, -6.5))
pass3:Sweep(dt, now)
check("at or under the floor nothing is let through and nothing is charged", #hits3 == 0 and live == before
    and flat(chassis3.AssemblyLinearVelocity) == RP.FLOOR - 0.5, #hits3 .. " hits, " .. (live - before) .. " constraints")

-- 7. from the side: the body touched last step and the car lost 10; that is given back, less the toll.
local model4, chassis4 = vehicle("Rotster", "car", Vector3.new(300, 3, 0), Vector3.new(0, 0, -60))
chassis4.AssemblyAngularVelocity = Vector3.new(0, 0.2, 0)
local hits4 = {}
local pass4 = RP.new(model4, chassis4, function(c, s) table.insert(hits4, s) end)
pass4:Sweep(dt, now)
chassis4.AssemblyLinearVelocity = Vector3.new(0, 0, -50)
chassis4.AssemblyAngularVelocity = Vector3.new(0, 1.9, 0)
body("Sider", Vector3.new(303.4, 3, 0))
now = now + dt
pass4:Sweep(dt, now)
local v4 = chassis4.AssemblyLinearVelocity
check("a body from the side: what its contact cost is given back, less the toll, spin as before",
    #hits4 == 1 and math.abs(hits4[1] - 60) < 1e-6 and math.abs(flat(v4) - 60 * (1 - tC)) < 1e-6
    and math.abs(chassis4.AssemblyAngularVelocity.Y - 0.2) < 1e-9,
    string.format("speed %.2f, spin %.2f", flat(v4), chassis4.AssemblyAngularVelocity.Y))

-- 8. an armoured car gives up less than a car to the same body at the same speed.
local model5, chassis5 = vehicle("CameloCarrier", "car", Vector3.new(400, 3, 0), Vector3.new(0, 0, -60))
local pass5 = RP.new(model5, chassis5, function() end)
body("Armour", Vector3.new(400, 3, -6.9))
pass5:Sweep(dt, now)
check("an armoured car keeps more of its speed than a car", flat(chassis5.AssemblyLinearVelocity) > want
    and math.abs(flat(chassis5.AssemblyLinearVelocity) - 60 * (1 - tA)) < 1e-6,
    string.format("armoured %.2f vs car %.2f", flat(chassis5.AssemblyLinearVelocity), want))

-- 9. letting go: not while the body is still beside the vehicle, then once it is clear, and always
-- after PASS_MAX.
local count = live
now = now + RP.PASS_SECONDS + 0.1
chassis.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
pass:Sweep(dt, now)
check("a body still beside the vehicle stays let through", live == count, (count - live) .. " released")
move(bob, Vector3.new(0, 0, -60))
move(corpse, Vector3.new(0, 0, -60))
now = now + dt
pass:Sweep(dt, now)
check("once clear (and its time is up), the body collides again", live == count - 20, (count - live) .. " released")
local stuck = body("Stuck", Vector3.new(300, 3, -6.9))
chassis4.AssemblyLinearVelocity = Vector3.new(0, 0, -40)
pass4:Sweep(dt, now)
local held = live
now = now + RP.PASS_MAX + 0.1
chassis4.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
pass4:Sweep(dt, now)
check("and after PASS_MAX whatever happens", live < held, (held - live) .. " released")
return results
"""


def run(root, mutate=None):
    shared = os.path.join(root, "ReplicatedStorage", "Shared")
    rp = open(os.path.join(shared, "RoadkillPass.lua"), encoding="utf-8").read()
    va = open(os.path.join(shared, "VehicleArmor.lua"), encoding="utf-8").read()
    if mutate:
        rp = mutate(rp)
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        results = lua.execute(HARNESS, luau_to_lua(rp), luau_to_lua(va))
    except Exception as exc:  # a crash is a failure, not a pass
        return [("harness ran", False, str(exc).splitlines()[0])]
    return [(r[1], bool(r[2]), r[3]) for r in results.values()]


def sub(old, new):
    def f(text):
        if old not in text:
            raise SystemExit("roadkill_momentum_check: plant target not found: " + old)
        return text.replace(old, new, 1)
    return f


PLANTS = [
    ("no toll taken", sub("velocity = RoadkillPass.After(velocity, self.toll)", "velocity = velocity")),
    ("a corpse charged as a hit", sub("if self:Pass(character, now) and humanoid.Health > 0 then", "if self:Pass(character, now) then")),
    ("no floor", sub("if flat <= RoadkillPass.FLOOR then\n\t\treturn 0", "if false then\n\t\treturn 0")),
    ("no look-ahead (the contact happens first)", sub("local lead = velocity * (dt * RoadkillPass.LEAD_STEPS)",
                                                        "local lead = velocity * 0")),
    ("riders hit", lambda t: sub("if occupant and occupant.Parent then", "if false then")(sub("not self:isRider(humanoid)", "true")(t))),
    ("never let go", sub("\t\t\trelease(pass)\n\t\t\tself.passed[character] = nil\n", "")),
    ("let go while still inside", sub("done = root == nil or (root.Position - self.chassis.Position).Magnitude > self.reach",
                                      "done = true")),
    ("spin lost", sub("\t\tchassis.AssemblyAngularVelocity = spin\n", "\t\tchassis.AssemblyAngularVelocity = Vector3.new(0, 0, 0)\n")),
    ("the side hit's cost kept", sub("if lastFlat > flat + 1 then", "if false then")),
    ("the riders left solid (the body meets the driver inside)", sub("if rider and rider ~= character then", "if false then")),
    ("armour tolled like a car", sub("armored = 0.01", "armored = 0.025")),
    ("a bike tolled like an armoured car", sub("bike = 0.04", "bike = 0.01")),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        missed = 0
        for name, mutate in PLANTS:
            failed = [r[0] for r in run(root, mutate) if not r[1]]
            print(("CAUGHT " if failed else "MISSED ") + name + (" -> " + "; ".join(failed[:2]) if failed else ""))
            missed += 0 if failed else 1
        print(f"roadkill momentum plants: {len(PLANTS) - missed}/{len(PLANTS)} caught")
        sys.exit(1 if missed else 0)
    results = run(root)
    bad = 0
    for name, ok, detail in results:
        print(("ok   " if ok else "FAIL ") + name + ("  (" + detail + ")" if detail else ""))
        bad += 0 if ok else 1
    print(f"roadkill momentum check: {len(results)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
