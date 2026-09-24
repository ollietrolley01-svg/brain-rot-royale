"""#16 / #94: the kerbside cars are the real designs, built as static scenery.

Runs the REAL VehicleModels.lua, MapDecor.lua and DestructibleService.lua under lupa, on the mocks in
tools/destruct_mocks.lua (real CFrame maths, an Instance tree with attributes), via the World class
of tools/destruct_map_check.py. ZFight is stubbed (it only nudges or grows a face by hundredths).

For every car design (seeded through MapDecor.ParkedCar with `detailed`, and each design once more
straight through VehicleModels.BuildStatic so none is left to chance) and for the plain car, placed
in a town under workspace.Map at a yaw, it checks the invariants a parked car must hold forever:

  A  every BasePart is anchored
  B  nothing that drives or runs: no Seat/VehicleSeat, no joint, weld or constraint, no script,
     and none of the attributes that make VehicleClient or the bots treat it as a vehicle
     (VehicleModel, VehicleKind, Armed, Lamp, Radius, Pivot)
  C  one destructible pool: the Model is named ParkedCar with DestructibleHealth, every part is a
     direct child, every solid or shootable part resolves (DestructibleService.KeyOf) to that one
     Model, and a big enough hit takes every part with it
  D  part count within PART_BUDGET per car
  E  it stands where it was put: the lowest point sits on the ground it was given (within 0.3),
     the nose faces the yaw asked for, and it fits the kerbside footprint MapDecor.Town claims
     (two 3.6-stud circles 3.2 either side of the centre: 13.6 long, 7.2 wide)
  F  it is solid cover: some collidable part rises at least 3 studs above the ground

It prints per-design part counts next to the drivable build and the plain car, and the part cost per
map at the chosen DETAILED_CARS_PER_TOWN.

Planted faults (each aimed at an invariant, applied to the SOURCE and required to fail):
  - BuildStatic stops anchoring (A)
  - BuildStatic keeps the welds (B)
  - BuildStatic keeps the vehicle attributes (B)
  - parkedCar leaves out DestructibleHealth (C)
  - BuildStatic keeps whole wheels (D)
  - BuildStatic stops placing the model (E)
  - MapDecor measures a design's length about its box centre, not the point it is placed by (E:
    the van's body runs a stud further back than forward, so its claim came up short)

    python3 tools/parked_car_check.py
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import destruct_map_check as dmc  # noqa: E402

ROOT = dmc.ROOT
VEHICLES = os.path.join(ROOT, "ReplicatedStorage", "Shared", "VehicleModels.lua")
PART_BUDGET = 300
PLAIN_PARTS = 11

SETUP = r"""
local mock, vehicleSource, fake = ...
local shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
for _, name in ipairs({ "VehicleModels", "ZFight" }) do
  local m = Instance.new("ModuleScript"); m.Name = name; m.Parent = shared
end
-- The mocks' Vector2 is a bare record; the lamps add them.
local V2 = {}
V2.__index = V2
V2.__add = function(a, b) return Vector2.new(a.X + b.X, a.Y + b.Y) end
V2.__sub = function(a, b) return Vector2.new(a.X - b.X, a.Y - b.Y) end
V2.__mul = function(a, b) if type(a) == "number" then a, b = b, a end return Vector2.new(a.X * b, a.Y * b) end
Vector2 = { new = function(x, y) return setmetatable({ X = x or 0, Y = y or 0, __type = "Vector2" }, V2) end }
mock.modules.ZFight ={ Fix = function() return { moved = 0, resized = 0 } end }
mock.modules.VehicleModels = vehicleSource()
-- A Model's PivotTo moves its parts, about its PrimaryPart's pivot (the mock only moves one part).
local I = getmetatable(Instance.new("Part"))
local partPivot = I.PivotTo
I.PivotTo = function(inst, target)
  if inst.ClassName ~= "Model" then return partPivot(inst, target) end
  local primary = inst.PrimaryPart
  local pivot = primary and primary.CFrame * (primary.PivotOffset or CFrame.new()) or CFrame.new()
  local move = target * pivot:Inverse()
  for _, d in ipairs(inst:GetDescendants()) do
    if d:IsA("BasePart") then d.CFrame = move * d.CFrame end
  end
end
-- The mocks' bounding box ignores rotation, which over-states a car's footprint; this one turns
-- every corner (world axes, which is the PrimaryPart's frame for a car built at the identity).
I.GetBoundingBox = function(model)
  local low, high
  for _, d in ipairs(model:GetDescendants()) do
    if d:IsA("BasePart") then
      local s = d.Size / 2
      for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
        local p = d.CFrame * Vector3.new(sx * s.X, sy * s.Y, sz * s.Z)
        low = low and low:Min(p) or p
        high = high and high:Max(p) or p
      end end end
    end
  end
  if not low then return CFrame.new(), Vector3.new(0, 0, 0) end
  return CFrame.new((low + high) / 2), high - low
end
return mock.modules.VehicleModels
"""

EXAMINE = r"""
local car, service, x, ground, yaw = ...
local r = { parts = 0, unanchored = {}, driving = {}, notChild = {}, unresolved = {}, solid = 0, tall = 0 }
for _, d in ipairs(car:GetDescendants()) do
  local cls = d.ClassName
  if d:IsA("BasePart") then
    r.parts = r.parts + 1
    if not d.Anchored then table.insert(r.unanchored, d.Name) end
    if d.Parent ~= car then table.insert(r.notChild, d.Name) end
    if d.CanCollide or d.CanQuery then
      r.solid = r.solid + 1
      if service.KeyOf(d) ~= car then table.insert(r.unresolved, d.Name) end
    end
    if d.CanCollide then
      local top = d.Position.Y
      local halfY = math.abs(d.CFrame.RightVector.Y) * d.Size.X / 2 + math.abs(d.CFrame.UpVector.Y) * d.Size.Y / 2
        + math.abs(d.CFrame.LookVector.Y) * d.Size.Z / 2
      r.tall = math.max(r.tall, top + halfY - ground)
    end
  end
  if cls == "Seat" or cls == "VehicleSeat" or string.find(cls, "Constraint") or string.find(cls, "Script")
    or cls == "Motor6D" or cls == "Weld" or cls == "Motor" or cls == "Snap" then
    table.insert(r.driving, cls .. ":" .. d.Name)
  end
  for _, key in ipairs({ "VehicleModel", "VehicleKind", "Armed", "Lamp", "Radius", "Pivot", "RiderPose" }) do
    if d:GetAttribute(key) ~= nil then table.insert(r.driving, "attr " .. key .. " on " .. d.Name) end
  end
end
for _, key in ipairs({ "VehicleModel", "VehicleKind", "Armed", "RiderPose" }) do
  if car:GetAttribute(key) ~= nil then table.insert(r.driving, "attr " .. key .. " on the car") end
end
r.named = car.Name == "ParkedCar" and type(car:GetAttribute("DestructibleHealth")) == "number"
-- Footprint and ground contact, in the car's own frame about where it was put.
local frame = CFrame.new(x, ground, 0) * CFrame.Angles(0, yaw, 0)
local low, lenLo, lenHi, widLo, widHi = math.huge, 0, 0, 0, 0
local front = 0
for _, d in ipairs(car:GetDescendants()) do
  if d:IsA("BasePart") and d.Transparency < 1 then
    local s = d.Size / 2
    for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
      local corner = frame:PointToObjectSpace(d.CFrame * Vector3.new(sx * s.X, sy * s.Y, sz * s.Z))
      low = math.min(low, corner.Y)
      lenLo, lenHi = math.min(lenLo, corner.Z), math.max(lenHi, corner.Z)
      widLo, widHi = math.min(widLo, corner.X), math.max(widHi, corner.X)
    end end end
    -- Which end the head lamps are: the nose is -Z in the frame asked for.
    local name = d.Name
    if string.find(name, "^Headlamp") or string.find(name, "^Drl") or string.find(name, "^EyeLamp") then front = front + (frame:PointToObjectSpace(d.Position).Z < 0 and 1 or -1) end
  end
end
r.low = low
r.lenLo, r.lenHi, r.widLo, r.widHi = lenLo, lenHi, widLo, widHi
r.front = front
r.healthBefore = car:GetAttribute("DestructibleHealth")
-- Break it through one of its solid parts: every part must go with it.
local anyPart
for _, d in ipairs(car:GetDescendants()) do if d:IsA("BasePart") and d.CanCollide then anyPart = d break end end
local all = {}
for _, d in ipairs(car:GetDescendants()) do if d:IsA("BasePart") then table.insert(all, d) end end
if anyPart then service.Damage(anyPart, 1e6, nil, nil) end
mock_advance(5)
r.survivors = 0
for _, d in ipairs(all) do if d.Parent ~= nil then r.survivors = r.survivors + 1 end end
return r
"""


def luatable_list(t):
    return [t[i] for i in range(1, len(t) + 1)]


def run(decor_faults=(), vehicle_faults=(), quiet=False):
    world = dmc.World()
    vehicle_src = dmc.read(VEHICLES, vehicle_faults)
    loader = world.lua.execute("local source = ...\nreturn function() return assert(load(source, '=VehicleModels'))() end",
                               vehicle_src)
    vm = world.run(SETUP, world.mock, loader)
    world.lua.execute("local mock = ...\nmock_advance = function(dt) mock.advance(dt) end", world.mock)
    service = world.load(dmc.SERVICE, name="DestructibleService")
    decor = world.load(dmc.DECOR, decor_faults, name="MapDecor")
    per_town = int(re.search(r"^local DETAILED_CARS_PER_TOWN = (\d+)", dmc.read(dmc.DECOR, decor_faults), re.M).group(1))
    make = world.lua.eval(
        """function(decor, detailed, x, ground, yaw, seed)
            local map = workspace:FindFirstChild("Map")
            if not map then map = Instance.new("Model"); map.Name = "Map"; map.Parent = workspace end
            local town = Instance.new("Model"); town.Name = "Town"; town.Parent = map
            math.randomseed(seed)
            local design = decor.ParkedCarDesign(detailed)
            return decor.ParkedCar(town, Vector3.new(x, ground, 0), yaw, design), design
        end""")
    drivable = world.lua.eval(
        """function(vm, id)
            local model = vm.Build(id, Random.new(1), { scheme = 1 })
            local n = 0
            for _, d in ipairs(model:GetDescendants()) do if d:IsA("BasePart") then n = n + 1 end end
            return n
        end""")
    examine = world.lua.eval("function(...) local f = assert(load(...)) return f end")(EXAMINE)
    ids = sorted(k for k, v in vm.Models.items() if v.kind == "car")

    cases = [(False, 1)] + [(True, s) for s in range(1, 25)]
    fails, counts = [], {}
    for n, (detailed, seed) in enumerate(cases):
        yaw = 0.7 * n
        ground = 3.0 + n
        car, design = make(decor, detailed, n * 60.0, ground, yaw, seed)
        id_ = design.id
        label = "%s (seed %d)" % (id_, seed) if detailed else "plain car"
        r = examine(car, service, n * 60.0, ground, yaw)
        def bad(letter, why):
            fails.append("%s %s: %s" % (letter, label, why))
        if detailed and not id_:
            bad("D", "asked for a real design, got the plain car")
        if luatable_list(r["unanchored"]):
            bad("A", "unanchored %s" % luatable_list(r["unanchored"])[:4])
        if luatable_list(r["driving"]):
            bad("B", "vehicle bits left %s" % luatable_list(r["driving"])[:4])
        if not r["named"] or luatable_list(r["notChild"]) or luatable_list(r["unresolved"]) or r["survivors"] or r["solid"] == 0:
            bad("C", "pool: named %s, nested %s, unresolved %s, survivors %d, solid %d" % (
                r["named"], luatable_list(r["notChild"])[:3], luatable_list(r["unresolved"])[:3], r["survivors"], r["solid"]))
        if detailed and r["parts"] > PART_BUDGET:
            bad("D", "%d parts, budget %d" % (r["parts"], PART_BUDGET))
        # The claim MapDecor.Town makes for it: two circles `reach` either side, `radius` wide.
        along, across = design.reach + design.radius, design.radius
        fits = max(-r["lenLo"], r["lenHi"]) <= along + 0.1 and max(-r["widLo"], r["widHi"]) <= across + 0.1
        if abs(r["low"]) > 0.3 or (detailed and r["front"] <= 0) or not fits:
            bad("E", "low %+.2f, nose lamps %d, spans z %.2f..%.2f x %.2f..%.2f against a claim of %.2f x %.2f" % (
                r["low"], r["front"], r["lenLo"], r["lenHi"], r["widLo"], r["widHi"], along, across))
        if r["tall"] < 3.0:
            bad("F", "tallest collider top %.2f above ground" % r["tall"])
        first = detailed and id_ not in counts
        if first:
            counts[id_] = (int(r["parts"]), int(drivable(vm, id_)))
        if not quiet and (first or not detailed):
            extra = (" (drivable build %d)" % counts[id_][1]) if detailed else ""
            print("    %-26s %3d parts%s, %2d solid, %.1f x %.1f, claim %.1f x %.1f, cover %.1f tall" % (
                label, r["parts"], extra, r["solid"], r["lenHi"] - r["lenLo"], r["widHi"] - r["widLo"],
                2 * along, 2 * across, r["tall"]))
    missing = sorted(set(ids) - set(counts))
    if missing:
        fails.append("D coverage: designs never picked in %d seeds: %s" % (len(cases) - 1, missing))
    return fails, counts, per_town, len(cases)


def main():
    fails, counts, per_town, examined = run()
    worst = max(c[0] for c in counts.values())
    mean = sum(c[0] for c in counts.values()) / len(counts)
    print("  %d parked cars examined (the plain car, and 24 seeded real ones covering %d designs)" % (examined, len(counts)))
    print("  per map at %d detailed per town, 4 kerbside cars per town: + about %d parts a town (mean design %d vs plain %d),"
          " %d to %d on a 4- to 7-town map" % (per_town, per_town * (mean - PLAIN_PARTS), mean, PLAIN_PARTS,
                                              4 * per_town * (mean - PLAIN_PARTS), 7 * per_town * (mean - PLAIN_PARTS)))
    print("  heaviest design %d parts (budget %d)" % (worst, PART_BUDGET))
    for f in fails:
        print("  FAIL", f)

    plants = [
        ("A", (), [("\t\t\tpart.Anchored = true\n", "\t\t\tpart.Anchored = false\n")]),
        ("B", (), [("\t\t\t\tif joint:IsA(\"JointInstance\") or joint:IsA(\"WeldConstraint\") then\n",
                    "\t\t\t\tif false then\n")]),
        ("B", (), [("\tfor key in pairs(model:GetAttributes()) do\n\t\tmodel:SetAttribute(key, nil)\n",
                    "\tfor key in pairs({}) do\n\t\tmodel:SetAttribute(key, nil)\n")]),
        ("C", [('\tcar:SetAttribute("DestructibleHealth", 240)\n\tcar.Parent = parent\n\treturn car\n',
                "\tcar.Parent = parent\n\treturn car\n")], ()),
        ("D", (), [("\t\treturn STATIC_WHEEL_KEEP[piece] == true\n", "\t\treturn true\n")]),
        ("E", (), [("\tmodel:PivotTo(cframe)\n", "")]),
        ("E", [("length = 2 * (math.abs(box.Position.Z) + size.Z / 2)", "length = size.Z")], ()),
    ]
    caught = 0
    for letter, decor_faults, vehicle_faults in plants:
        pf, _, _, _ = run(decor_faults, vehicle_faults, quiet=True)
        hit = any(f.startswith(letter) and f not in fails for f in pf)
        caught += hit
        print("  planted %s: %s (%s)" % (letter, "caught" if hit else "MISSED", pf[0] if pf else "no failure"))
    ok = not fails and caught == len(plants)
    print("parked_car_check:", "OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
