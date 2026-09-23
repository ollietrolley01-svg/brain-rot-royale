"""#71: things break by what they are made of, and damage never fades them toward clear.

Runs the REAL DestructibleService source under the mocks in destruct_car_check.py, breaks a wood
crate, a concrete wall and a metal part inside workspace.Map, and checks:

  W  wood throws splinters: long thin sticks (two sides 0.25, the third at least 1)
  S  concrete throws chunky lumps and a dust burst (a ParticleEmitter, not light-emitting)
  M  metal throws thin plates (0.15 thick) and sparks (a light-emitting ParticleEmitter)
  T  a wall at half health is darker but exactly as opaque as before

Planted faults, each of which must be caught: wood's entry dropped from BREAKS_AS (W), and the
old see-through bump put back into the battered step (T).

    python3 tools/destruct_material_check.py .
"""
import sys
from pathlib import Path

from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).parent))
from destruct_car_check import MOCKS, luau_to_lua  # noqa: E402

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")

CHECK = r"""
return function(service)
  local fails = {}
  local function fail(tag, why) table.insert(fails, tag .. ": " .. why) end
  local map = Instance.new("Model") map.Name = "Map" map.Parent = workspace
  local function breakOne(name, material, size, attr)
    local holder = Instance.new("Model") holder.Parent = map
    local part = Instance.new("Part")
    part.Name = name part.Material = material part.Size = size
    if attr then part:SetAttribute("DestructibleHealth", attr) end
    part.Parent = holder
    service.Damage(part, 1e6, nil, nil)
    if part.Parent ~= nil then fail(name, "did not break") end
    local chunks, emitters = {}, {}
    for _, d in ipairs(holder:GetDescendants()) do
      if d.ClassName == "ParticleEmitter" then table.insert(emitters, d)
      elseif d.Name == "Rubble" and d.Transparency < 1 then table.insert(chunks, d) end
    end
    return chunks, emitters
  end
  local function sorted(v) local t = { v.X, v.Y, v.Z } table.sort(t) return t end

  local chunks = breakOne("Crate", "Material.Wood", Vector3.new(3, 3, 3))
  if #chunks == 0 then fail("W", "no rubble") end
  for _, c in ipairs(chunks) do
    local s = sorted(c.Size)
    if not (s[1] == 0.25 and s[2] == 0.25 and s[3] >= 1) then fail("W", "wood chunk is not a splinter") break end
  end

  local stone, dust = breakOne("Wall", "Material.Concrete", Vector3.new(12, 10, 1))
  if #stone == 0 then fail("S", "no rubble") end
  for _, c in ipairs(stone) do
    local s = sorted(c.Size)
    if s[1] < 0.4 then fail("S", "concrete chunk is a sliver") break end
  end
  if #dust ~= 1 or dust[1].LightEmission == 1 then fail("S", "no dust burst") end

  local plates, sparks = breakOne("Sign", "Material.Metal", Vector3.new(6, 4, 0.4), 50)
  if #plates == 0 then fail("M", "no rubble") end
  for _, c in ipairs(plates) do if c.Size.Y ~= 0.15 then fail("M", "metal chunk is not a plate") break end end
  if #sparks ~= 1 or sparks[1].LightEmission ~= 1 then fail("M", "no sparks") end

  local wall = Instance.new("Part") wall.Name = "Wall" wall.Size = Vector3.new(12, 10, 1) wall.Parent = map
  service.Damage(wall, 60, nil, nil)
  if wall.Transparency ~= 0 then fail("T", "a battered wall went see-through (" .. tostring(wall.Transparency) .. ")") end
  return fails
end
"""


def run(source):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCKS)
    service = lua.execute(luau_to_lua(source))
    fails = lua.execute(CHECK)(service)
    return [fails[i] for i in range(1, len(fails) + 1)]


def main():
    source = (ROOT / "ServerScriptService/Modules/DestructibleService.lua").read_text()
    fails = run(source)
    print(f"real: 4 parts broken or battered (wood, concrete, metal, wall), {len(fails)} failures")
    for f in fails:
        print("  FAIL", f)
    darken = "piece.Color = piece.Color:Lerp(Color3.new(0, 0, 0), 0.25)\n"
    planted = [
        ("W", "[M.Wood] = SPLINTER, ", ""),
        ("T", darken, darken + "piece.Transparency = math.max(piece.Transparency, 0.12)\n"),
    ]
    caught = 0
    for tag, old, new in planted:
        assert source.count(old) == 1, f"planted fault {tag}: anchor not found"
        pf = run(source.replace(old, new))
        hit = any(f.startswith(tag) for f in pf)
        caught += hit
        print(f"planted {tag}: {'caught' if hit else 'MISSED'} ({pf[0] if pf else 'no failure'})")
    ok = not fails and caught == len(planted)
    print("destruct_material_check:", "OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
