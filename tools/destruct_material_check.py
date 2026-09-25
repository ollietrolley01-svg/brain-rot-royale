"""#71: things break by what they are made of, and damage never fades them toward clear.

The server no longer makes rubble: DestructibleService sends one BreakFx event per frame and
BreakFxClient throws the debris. This runs the REAL source of both under lupa (the mocks in
tools/destruct_mocks.lua, via destruct_map_check.World), breaks a wood crate, a concrete wall and
a metal part inside workspace.Map, plays what the server sent through the client, and checks:

  E  the server names each broken part's family in the event (wood, stone, metal) and makes no
     part of its own for the debris
  W  wood throws splinters: long thin sticks (two sides at most 0.4, the third at least 0.8)
  S  concrete throws chunky lumps and a dust puff (an emitter that doesn't glow)
  M  metal throws thin plates (at most 0.14 thick) and sparks (a glowing emitter)
  T  a wall at half health is at damage stage 2 (DamageStage attribute), weathered darker, and
     exactly as opaque as before (tools/crack_check.py holds every damage path to that)

  H  wall health by material (Oliver 09-24: "increase the health of the walls in the map depending
     on the material"): a building's named Wall and an untagged structural part rank glass < cloth
     < wood <= plaster < brick < concrete <= stone < metal < diamond plate, diamond plate at least
     3.5x wood; every wall but glass and cloth is at least the old flat 100; a rifle round (18)
     still breaks the toughest wall in at most 40 shots; one rocket blast (wallDamage 150, the
     real DamageInRadius) breaks a wood, plaster or brick wall, two break concrete, metal and
     diamond plate; a tagged prop (a parked car) keeps its family toughness.

Planted faults, each of which must be caught: wood's profile turned into chunks (W), a
see-through bump put into the stage step (T), the material spread flattened (metal back to wood's
toughness: H), and the blast bonus on structure removed (H).

    python3 tools/destruct_material_check.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from destruct_map_check import CLIENT, SERVICE, World  # noqa: E402

LUA = r"""
local DS, mock = ...
local fails = {}
local function fail(tag, why) table.insert(fails, tag .. ": " .. why) end
local map = Instance.new("Folder"); map.Name = "Map"; map.Parent = workspace
local house = Instance.new("Model"); house.Name = "House_1"; house.Parent = map
local function part(name, size, pos, material)
    local p = Instance.new("Part")
    p.Name = name; p.Size = size; p.CFrame = CFrame.new(pos); p.Anchored = true; p.Material = material
    p.Color = Color3.fromRGB(150, 120, 90); p.Parent = house
    return p
end
local crate = part("Crate", Vector3.new(4, 4, 4), Vector3.new(0, 2, 0), Enum.Material.WoodPlanks)
local wall = part("Wall", Vector3.new(12, 10, 1), Vector3.new(20, 5, 0), Enum.Material.Concrete)
local plate = part("Part", Vector3.new(6, 3, 6), Vector3.new(40, 1.5, 0), Enum.Material.Metal)
plate:SetAttribute("DestructibleHealth", 50)

-- T: half health is stage 2 and weathers the colour, never fades.
local before = wall.Transparency
local r0 = wall.Color.R
DS.Damage(wall, DS.NamedHealth(wall) * 0.6)
if wall.Transparency ~= before then fail("T", "battered wall went from transparency " .. before .. " to " .. wall.Transparency) end
if wall:GetAttribute("DamageStage") ~= 2 then fail("T", "battered wall at stage " .. tostring(wall:GetAttribute("DamageStage"))) end
if not (wall.Color.R < r0) then fail("T", "battered wall did not darken") end

-- H: wall health by material.
local order = { "Glass", "Fabric", "WoodPlanks", "Plaster", "Brick", "Concrete", "Granite", "Metal", "DiamondPlate" }
local strict = { Fabric = true, WoodPlanks = true, Brick = true, Concrete = true, Metal = true, DiamondPlate = true }
local named, auto = {}, {}
for i, name in ipairs(order) do
    local m = Enum.Material[name]
    local w = part("Wall", Vector3.new(12, 10, 1), Vector3.new(i * 30, 5, 200), m)
    named[name] = DS.NamedHealth(w)
    local lone = part("Pier", Vector3.new(8, 12, 1), Vector3.new(i * 30, 6, 260), m)
    auto[name] = DS.PoolHealth("Prop", { lone }, true)
    lone:Destroy()
    if i > 1 then
        local prev = order[i - 1]
        for label, t in pairs({ named = named, untagged = auto }) do
            if t[name] < t[prev] or (strict[name] and t[name] == t[prev]) then
                fail("H", string.format("%s %s wall %d is not above %s's %d", label, name, t[name], prev, t[prev]))
            end
        end
    end
    if name ~= "Glass" and name ~= "Fabric" and named[name] < 100 then fail("H", name .. " wall health " .. named[name] .. " is under the old flat 100") end
    w:Destroy()
end
if named.DiamondPlate < named.WoodPlanks * 3.5 then fail("H", "the spread is narrow: diamond plate " .. named.DiamondPlate .. " vs wood " .. named.WoodPlanks) end
if math.ceil(named.DiamondPlate / 18) > 40 then fail("H", "a rifle needs " .. math.ceil(named.DiamondPlate / 18) .. " shots for diamond plate") end
-- Rockets: the real blast path, one wall at a time.
local want = { WoodPlanks = 1, Plaster = 1, Brick = 1, Concrete = 2, Metal = 2, DiamondPlate = 2 }
local k = 0
for name, most in pairs(want) do
    k += 1
    local w = part("Wall", Vector3.new(12, 10, 1), Vector3.new(0, 5, 600 + k * 60), Enum.Material[name])
    local blasts = 0
    while w.Parent and blasts < 10 do
        blasts += 1
        DS.DamageInRadius(w.Position + Vector3.new(0, 0, -2), 8, 150, nil)
        mock.runDue()
    end
    if blasts > most then fail("H", string.format("%s wall took %d rockets (want at most %d)", name, blasts, most)) end
end
-- A tagged prop keeps its family toughness: a parked car of metal is not a metal wall.
local carBody = part("Body", Vector3.new(6, 3, 12), Vector3.new(0, 2, 900), Enum.Material.Metal)
if DS.PoolHealth("Car", { carBody }) ~= DS.PoolHealth("Car", { carBody }, false) then fail("H", "a tagged car's health moved with the structure table") end
carBody:Destroy()
local healthRows = { named = named, auto = auto }

-- E: break all three in one frame; the server sends families and makes no debris parts itself.
local made = #mock.created
local firedBefore = #mock.remotes.BreakFx.fired
DS.Damage(crate, 1e6); DS.Damage(wall, 1e6); DS.Damage(plate, 1e6)
mock.runDue()
for i = made + 1, #mock.created do
    local inst = mock.created[i]
    fail("E", "the server made a " .. inst.ClassName .. " (" .. tostring(inst.Name) .. ") while breaking")
    break
end
local sent = { mock.remotes.BreakFx.fired[firedBefore + 1] }
local classes = {}
for _, entry in ipairs(sent[1] and sent[1][1] or {}) do classes[entry[4].Name] = entry[5] end
if classes.WoodPlanks ~= "wood" or classes.Concrete ~= "stone" or classes.Metal ~= "metal" then
    fail("E", string.format("families sent: wood=%s concrete=%s metal=%s", tostring(classes.WoodPlanks), tostring(classes.Concrete), tostring(classes.Metal)))
end
return sent[1] and sent[1][1] or {}, fails, healthRows
"""

CLIENT_LUA = r"""
local mock, batch, fails = ...
local function fail(tag, why) table.insert(fails, tag .. ": " .. why) end
local folder = workspace:FindFirstChild("BreakFx")
for _, entry in ipairs(batch) do
    local material = entry[4]
    local seen = #folder:GetChildren()
    mock.emitters = {}
    mock.remotes.BreakFx.OnClientEvent:Fire({ entry })
    local pieces = {}
    for index, child in ipairs(folder:GetChildren()) do
        if index > seen and child.Name == "BreakPiece" then table.insert(pieces, child) end
    end
    if #pieces == 0 then fail(material.Name, "no debris") end
    local glowing, plain = 0, 0
    for _, e in ipairs(mock.emitters) do
        if (e.LightEmission or 0) > 0 then glowing = glowing + 1 else plain = plain + 1 end
    end
    for _, p in ipairs(pieces) do
        local s = p.Size
        local sides = { s.X, s.Y, s.Z }
        table.sort(sides)
        if p.Material ~= material then fail("E", "a " .. material.Name .. " break threw " .. p.Material.Name) break end
        if material.Name == "WoodPlanks" and not (sides[2] <= 0.4 and sides[3] >= 0.8) then
            fail("W", string.format("wood threw a %.2f x %.2f x %.2f piece, not a splinter", sides[1], sides[2], sides[3])) break
        end
        if material.Name == "Concrete" and not (sides[1] >= 0.15 and sides[3] / sides[1] < 4) then
            fail("S", string.format("concrete threw a %.2f x %.2f x %.2f piece, not a lump", sides[1], sides[2], sides[3])) break
        end
        if material.Name == "Metal" and not (sides[1] <= 0.14) then
            fail("M", string.format("metal threw a %.2f-thick piece, not a plate", sides[1])) break
        end
    end
    if material.Name == "Concrete" and plain == 0 then fail("S", "no dust") end
    if material.Name == "Metal" and glowing == 0 then fail("M", "no sparks") end
end
return fails
"""


def run(service_faults=(), client_faults=()):
    world = World()
    world.run("local mock = ...; mock.remote('BreakFx')", world.mock)
    ds = world.load(SERVICE, service_faults, name="DestructibleService")
    world.load(CLIENT, client_faults, name="BreakFxClient")
    batch, fails, rows = world.run(LUA, ds, world.mock)
    fails = world.run(CLIENT_LUA, world.mock, batch, fails)
    run.rows = rows
    return [fails[i] for i in range(1, len(fails) + 1)], len(list(batch.values()))


def main():
    fails, examined = run()
    print(f"real: {examined} breaks examined, {len(fails)} failures")
    for f in fails:
        print("  FAIL", f)
    rows = run.rows
    if rows is not None:
        order = ["Glass", "Fabric", "WoodPlanks", "Plaster", "Brick", "Concrete", "Granite", "Metal", "DiamondPlate"]
        print("  named Wall health: " + ", ".join("%s %d" % (n, rows["named"][n]) for n in order))
        print("  untagged 8x12x1:   " + ", ".join("%s %d" % (n, rows["auto"][n]) for n in order))
    planted = [
        ("W", (), [("WoodPlanks = { shape = \"splinter\"", "WoodPlanks = { shape = \"chunk\"")]),
        ("T", [("\t\t\tmember.Color = base:Lerp(tint[1], tint[2] * stage)\n",
                "\t\t\tmember.Color = base:Lerp(tint[1], tint[2] * stage)\n\t\t\tmember.Transparency = math.max(member.Transparency, 0.12)\n")], ()),
        ("H", [("[M.Metal] = 3.4,", "[M.Metal] = 1,")], ()),
        ("H", [("scale = 1.5, blast = 2 }", "scale = 1.5, blast = 1 }")], ()),
    ]
    caught = 0
    for tag, service_faults, client_faults in planted:
        pf, _ = run(service_faults, client_faults)
        hit = any(f.startswith(tag) for f in pf)
        caught += hit
        print(f"planted {tag}: {'caught' if hit else 'MISSED'} ({pf[0] if pf else 'no failure'})")
    ok = not fails and caught == len(planted)
    print("destruct_material_check:", "OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
