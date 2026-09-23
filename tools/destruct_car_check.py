"""#51: every parked car on the map can be shot apart.

Runs the REAL source of DestructibleService.lua and of MapDecor's parkedCar (sliced out of
MapDecor.lua) under lupa with small Roblox mocks, builds cars inside a town inside workspace.Map,
and checks the invariants the fix rests on:

  A  every solid part of a parked car resolves to a damageable entry, and all to the SAME one
     (the car), so shooting the cabin or a wheel wears the car down
  B  enough damage breaks the car: every piece of it is gone and it resolves to nothing after
  C  scope: a generic "Part" beside it in the town (a bench) is still scenery, and a car model
     outside workspace.Map (lobby, deployables) is never damageable
  D  one blast covering the whole car hurts it once, not once per part

Then it plants three faults in DestructibleService's source, one per invariant it must refuse
forever, and requires the check to FAIL on each: the model attribute lookup removed (A), the map
root check removed (C), the per-blast dedupe removed (D).

MapDecor.lua is not this file's owner's to edit; the parked car becomes a pooled Model only once
the proposed parkedCar edit lands (see PROPOSED below). Until then the check applies that edit
in memory and says so; `--as-is` runs the tree's MapDecor unpatched (expected to fail A today).

    python3 tools/destruct_car_check.py .
"""
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ".")
AS_IS = "--as-is" in sys.argv

ANCHOR = "\tlocal paint = pick(CAR_COLORS)\n"
PROPOSED = ANCHOR + (
    "\t-- One Model, one health pool (DestructibleService reads the attribute): shot apart as a car, #51.\n"
    "\tlocal car = Instance.new(\"Model\")\n"
    "\tcar.Name = \"ParkedCar\"\n"
    "\tcar:SetAttribute(\"DestructibleHealth\", 240)\n"
    "\tcar.Parent = parent\n"
    "\tparent = car\n"
)

MOCKS = r"""
local Instances = {}
local function signal()
  local s = { fns = {} }
  function s:Connect(fn) table.insert(self.fns, fn) end
  function s:Fire(...) for _, fn in ipairs(self.fns) do fn(...) end end
  return s
end
Vector3 = {}
local V = {}
V.__index = V
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b)
  if type(a) == "number" then a, b = b, a end
  if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
  return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b) return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
function Vector3.new(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end
function V:Dot(o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
CFrame = {}
local C = {}
C.__index = C
-- Positions only: rotation is irrelevant to what this check measures.
C.__mul = function(a, b) return CFrame.new(a.Position + b.Position) end
C.__add = function(a, v) return CFrame.new(a.Position + v) end
function CFrame.new(x, y, z)
  if type(x) == "table" then return setmetatable({ Position = x }, C) end
  return setmetatable({ Position = Vector3.new(x, y, z) }, C)
end
function CFrame.Angles() return CFrame.new(0, 0, 0) end
Color3 = {}
local K = {}
K.__index = K
function K:Lerp() return self end
function Color3.new(r, g, b) return setmetatable({ r, g, b }, K) end
Color3.fromRGB = Color3.new
Enum = setmetatable({}, { __index = function(t, k)
  local e = setmetatable({}, { __index = function(u, j) return k .. "." .. j end })
  rawset(t, k, e) return e end })
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
typeof = function(v) if getmetatable(v) == V then return "Vector3" end return type(v) end
task = { spawn = function(fn, ...) fn(...) end, defer = function(fn) fn() end, delay = function() end }

local BASE = { Part = true, WedgePart = true }
local I = {}
I.__index = function(self, k)
  local p = rawget(self, "_p")
  if p[k] ~= nil then return p[k] end
  return I[k]
end
I.__newindex = function(self, k, v)
  local p = rawget(self, "_p")
  if k == "Parent" then
    local old = p.Parent
    if old then local c = rawget(old, "_kids") for i = #c, 1, -1 do if c[i] == self then table.remove(c, i) end end end
    if v then table.insert(rawget(v, "_kids"), self) end
  end
  p[k] = v
end
Instance = {}
function Instance.new(class)
  local o = setmetatable({ _p = { ClassName = class, Name = class, CanCollide = true, CanQuery = true,
    Transparency = 0, Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(0, 0, 0), Color = Color3.new(1, 1, 1),
    Destroying = signal() }, _kids = {}, _attr = {} }, I)
  table.insert(Instances, o)
  return o
end
function I:IsA(c) return c == self.ClassName or (c == "BasePart" and BASE[self.ClassName] == true) or c == "Instance" end
function I:GetAttribute(k) return rawget(self, "_attr")[k] end
function I:SetAttribute(k, v) rawget(self, "_attr")[k] = v end
function I:GetChildren() local t = {} for i, c in ipairs(rawget(self, "_kids")) do t[i] = c end return t end
function I:GetDescendants()
  local t = {}
  local function walk(n) for _, c in ipairs(rawget(n, "_kids")) do table.insert(t, c) walk(c) end end
  walk(self) return t
end
function I:FindFirstChild(name) for _, c in ipairs(rawget(self, "_kids")) do if c.Name == name then return c end end end
function I:WaitForChild(name)
  local found = self:FindFirstChild(name)
  if not found then found = Instance.new("Folder") found.Name = name end
  return found
end
function I:Destroy()
  for _, c in ipairs(self:GetChildren()) do c:Destroy() end
  self.Destroying:Fire()
  self.Parent = nil
end
function I:GetBoundingBox() return CFrame.new(0, 0, 0), Vector3.new(6, 6, 12) end
I.__tostring = function(self) return self.ClassName .. ":" .. self.Name end

workspace = Instance.new("Workspace")
workspace.Name = "Workspace"
function workspace:GetPartBoundsInRadius(position, radius)
  local found = {}
  for _, d in ipairs(self:GetDescendants()) do
    if d:IsA("BasePart") then
      local o = d.CFrame.Position - position
      if math.sqrt(o:Dot(o)) <= radius then table.insert(found, d) end
    end
  end
  return found
end
OverlapParams = { new = function() return {} end }
RaycastParams = { new = function() return {} end }

local fired = {}
local services = { Debris = { AddItem = function() end }, ReplicatedStorage = Instance.new("Folder") }
game = { GetService = function(_, name) return services[name] end }
local combat = { ConfirmHit = function() end }
local remotes = { Event = function() return { FireAllClients = function(_, b) table.insert(fired, b) end } end }
require = function(m) if m == "CombatService" or m.Name == "CombatService" then return combat end return remotes end
script = { Parent = { WaitForChild = function(_, n) return n end } }
"""


def luau_to_lua(source):
    """Luau compound assignment is the only syntax these two files use that Lua 5.4 lacks."""
    return re.sub(r"^(\s*)([\w\.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def slice_mapdecor(text):
    head = text[text.index('local currentName = "Part"'):text.index("local function pick")]
    head += text[text.index("local function pick"):text.index("-- Road and street surfaces")]
    car = text[text.index("local CAR_COLORS"):text.index("local function townSign")]
    return head + car + "\nreturn parkedCar\n"


def run(destructible_src, mapdecor_src):
    """Returns a list of failed invariant letters with reasons (empty = all hold)."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCKS)
    service = lua.execute(luau_to_lua(destructible_src))
    parked_car = lua.execute(luau_to_lua(slice_mapdecor(mapdecor_src)))
    helper = lua.execute(r"""
     return function(service, parkedCar)
      local fails, examined = {}, 0
      local function fail(tag, why) table.insert(fails, tag .. ": " .. why) end
      local map = Instance.new("Model") map.Name = "Map" map.Parent = workspace
      local town = Instance.new("Model") town.Name = "Rotville" town.Parent = map
      local function carParts(parent, before)
        local new = {}
        for _, d in ipairs(parent:GetDescendants()) do if d:IsA("BasePart") and not before[d] then table.insert(new, d) end end
        return new
      end
      local function snapshot(p) local s = {} for _, d in ipairs(p:GetDescendants()) do s[d] = true end return s end

      -- A: every solid part resolves, all to the one car.
      local before = snapshot(town)
      parkedCar(town, Vector3.new(0, 0, 0), 0)
      local parts = carParts(town, before)
      local solid = {}
      for _, p in ipairs(parts) do if p.CanCollide then table.insert(solid, p) end end
      if #solid == 0 then fail("A", "parkedCar built no solid parts") end
      local owner = nil
      for _, p in ipairs(solid) do
        examined = examined + 1
        if service.FromPart(p) ~= p then fail("A", tostring(p) .. " is not damageable") end
      end
      local car = solid[1] and solid[1].Parent
      for _, p in ipairs(solid) do
        if p.Parent ~= car or car == town then fail("A", tostring(p) .. " is not pooled in a car model") break end
      end
      -- Shooting one wheel must wear down the car: damage lands on the pool, and the body shows it.
      if #fails == 0 then
        local wheel = solid[#solid]
        local dealt = service.Damage(wheel, 30, nil, nil)
        if dealt ~= 30 then fail("A", "a wheel hit dealt " .. tostring(dealt)) end
      end

      -- D: a blast over the whole car hurts it once.
      if #fails == 0 then
        local before2 = snapshot(town)
        parkedCar(town, Vector3.new(200, 0, 0), 0)
        local second = {}
        for _, p in ipairs(carParts(town, before2)) do if p.CanCollide then table.insert(second, p) end end
        local model = second[1].Parent
        service.DamageInRadius(Vector3.new(200, 0, 0), 20, 50, nil)
        local health = model:GetAttribute("DestructibleHealth")
        -- One more hit of (health - 50) must break it exactly; if the blast landed per part it is already gone.
        if model.Parent == nil then fail("D", "one blast of 50 destroyed a " .. tostring(health) .. " car")
        else
          local rest = service.Damage(second[1], 1e6, nil, nil)
          if rest ~= health - 50 then fail("D", "blast took " .. tostring(health - rest) .. ", expected 50") end
        end
      end

      -- B: enough damage breaks it, every piece gone.
      if #fails == 0 then
        service.Damage(solid[1], 1e6, nil, nil)
        for _, p in ipairs(parts) do if p.Parent ~= nil then fail("B", tostring(p) .. " survived the car breaking") break end end
        if car.Parent ~= nil then fail("B", "car model survived") end
        if service.FromPart(solid[1]) ~= nil then fail("B", "broken car still damageable") end
      end

      -- C: scope. A bench's generic Part in the town, and a car outside Map.
      local bench = Instance.new("Part") bench.Parent = town
      examined = examined + 1
      if service.FromPart(bench) ~= nil then fail("C", "a generic Part in town is damageable") end
      local lobby = Instance.new("Model") lobby.Name = "Lobby" lobby.Parent = workspace
      local b3 = snapshot(lobby)
      parkedCar(lobby, Vector3.new(0, 0, 0), 0)
      for _, p in ipairs(carParts(lobby, b3)) do
        examined = examined + 1
        if p.CanCollide and service.FromPart(p) ~= nil then fail("C", "a car outside Map is damageable") break end
      end
      return fails, examined
     end
    """)
    fails, examined = helper(service, parked_car)
    return [fails[i] for i in range(1, len(fails) + 1)], examined


def main():
    dest = (ROOT / "ServerScriptService/Modules/DestructibleService.lua").read_text()
    decor = (ROOT / "ServerScriptService/Modules/MapDecor.lua").read_text()
    patched = "DestructibleHealth" in slice_mapdecor(decor)
    if not patched and not AS_IS:
        assert decor.count(ANCHOR) == 1, "parkedCar anchor line moved: update PROPOSED"
        decor = decor.replace(ANCHOR, PROPOSED)
        print("note: MapDecor parkedCar edit NOT in tree; applied the proposed edit in memory")

    fails, examined = run(dest, decor)
    print(f"real: {examined} parts examined, {len(fails)} failures")
    for f in fails:
        print("  FAIL", f)

    planted = [
        ("A", "node:GetAttribute(DestructibleService.HealthAttribute)", "nil"),
        ("C", "not ROOTS[root.Name]", "false"),
        ("D", "if key and not hit[key] then", "if key then"),
    ]
    caught = 0
    for tag, old, new in planted:
        assert dest.count(old) == 1, f"planted fault {tag}: anchor not found"
        pf, _ = run(dest.replace(old, new), decor)
        hit = any(f.startswith(tag) for f in pf)
        caught += hit
        print(f"planted {tag}: {'caught' if hit else 'MISSED'} ({pf[0] if pf else 'no failure'})")

    ok = not fails and caught == len(planted)
    print("destruct_car_check:", "OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
