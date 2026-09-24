"""Parked vehicles stand on the ground, not over a bank (OLIVER_LIST #39), without Studio.

The last in-game measurement (tools/vehicle_probe.lua, vehicle loop running): 0 buried, mean tyre gap
-0.17, and 1 of 13 parked vehicles hanging 1.48 studs clear at a corner, parked where MapGenerator's
verge loop asked. The verge spot is RoadNetwork.Width / 2 + 7 = 16 studs off the centre line and the
road's flat corridor ends at 20 (CorridorHalfWidth: 9 + 3 + 8); a car's half-width and a few degrees of
yaw put its outer corners at about 20.4, over the bank. VehicleService judged the footing at the four
corners of the CHASSIS collider only, which stop short of the bumpers and arches, so the spot read level.

This runs the real placement code under lupa with the mock from tools/vehicle_models_axis_check.py:
  * VehicleService.lua from FOOTING_TOLERANCE to the end of parkOn (footingAt, the step aside, the pad),
  * the footprint block of VehicleService.Create (from `local footprint` to the parkOn call),
  * the `inward` offset MapGenerator's verge call passes,
over ground that is flat to 20 studs off a road along Z and then falls away (a voxel bank: 4 in 1), with
workspace:Raycast answering from that ground and from any hardstanding the code lays.

Measured the way the probe measures: the gap under each bottom corner of the vehicle's bounding box.
  1. a car and a bike at the verge's worst yaw hang no more than HANG at any corner,
  2. and stay on the verge: the inner side at least on the carriageway's edge (9 studs out),
  3. a car on level verge is left exactly where it was asked to park.
Planted faults: the chassis-only footprint (the old code), and no `inward` from MapGenerator.
    python3 tools/vehicle_place_check.py [repo]        -> exit 0 when clean
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vehicle_models_axis_check import MOCK, luau_to_lua  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

CORRIDOR, BANK_GRADE = 20.0, 4.0
CARRIAGEWAY = 9.0
VERGE = 16.0
HANG = 1.0  # the probe's "hangs more than a stud clear"
# Chassis collider and whole-model extents (X across, Z along), from VehicleModels' hulls; the extents
# are the chassis plus bumpers, arches and mirrors, and a bike's bars and pegs.
CAR = ((6.1, 2.1, 12.6), (7.0, 4.2, 13.6))
BIKE = ((1.0, 1.6, 5.0), (2.6, 3.6, 6.2))

EXTRA = r"""
local Inst = getmetatable(Instance.new("Part"))
function Inst.FindFirstChild(i, name) for _, k in ipairs(rawget(i, "kids")) do if k.Name == name then return k end end end
function CF.PointToWorldSpace(c, v) return c * v end
Color3.new = Color3.fromRGB
RaycastParams = { new = function() return {} end }
function warn() end
PADS = {}
workspace = { Raycast = function(_, origin, direction)
	local y = GROUND(origin.X, origin.Z)
	for _, pad in ipairs(PADS) do
		local l = pad.CFrame:Inverse() * origin
		if math.abs(l.X) <= pad.Size.X / 2 and math.abs(l.Z) <= pad.Size.Z / 2 then
			y = math.max(y, pad.CFrame.p.Y + pad.Size.Y / 2)
		end
	end
	if y <= origin.Y and y >= origin.Y + direction.Y then return { Position = Vector3.new(origin.X, y, origin.Z) } end
	return nil
end }
"""


def sources(repo):
    vs = (Path(repo) / "ServerScriptService/Modules/VehicleService.lua").read_text()
    mg = (Path(repo) / "ServerScriptService/Modules/MapGenerator.lua").read_text()
    start = vs.index("local FOOTING_TOLERANCE")
    end = vs.index("-- Other tabs' vehicle types")
    park = vs[start:end].rsplit("\n----", 1)[0]
    fp = re.search(r"\n(\tlocal footprint = .*?position, yaw = parkOn\(.*?\)\n)", vs, re.S)
    assert fp, "VehicleService.Create's footprint block moved; update this check"
    call = re.search(r"VehicleService\.Create\(vehicles,.*?\n.*?\)\n", mg)
    assert call, "MapGenerator's verge Create call moved; update this check"
    inward = re.search(r"inward = (.+?) \}", call.group(0))
    return park, fp.group(1), inward.group(1) if inward else None


def run(park, footprint, inward, kind, x, yaw):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK + EXTRA)
    lua.globals().GROUND = lambda gx, gz: 0.0 if abs(gx) <= CORRIDOR else -(abs(gx) - CORRIDOR) * BANK_GRADE
    chassis, extents = kind
    place = lua.execute(luau_to_lua(park) + "\nreturn function(parent, position, yaw, chassis, model, options, info)\n"
                        + luau_to_lua(footprint) + "\treturn position, yaw\nend\n")
    # The map, the Vehicles folder in it, and pads land beside it, as MapGenerator lays them out.
    lua.execute("""MAP = Instance.new("Model"); VEH = Instance.new("Model"); VEH.Parent = MAP""")
    side = lua.eval("Vector3.new(1, 0, 0)")  # the verge is on +X of a road along Z
    options = lua.table()
    if inward:
        options["inward"] = lua.eval(f"function(side) return {inward} end")(side)
    model = lua.eval("function(x, y, z) return { GetExtentsSize = function() return Vector3.new(x, y, z) end } end")(*extents)
    chassis_part = lua.eval("function(x, y, z) return { Size = Vector3.new(x, y, z) } end")(*chassis)
    pos, yaw_out = place(lua.globals().VEH, lua.eval(f"Vector3.new({x}, 0, 0)"), yaw, chassis_part, model, options,
                         lua.eval('{ displayName = "test" }'))
    # Pads the code laid: register them with the raycast.
    pads = lua.eval("""function() local n = 0
        for _, f in ipairs(MAP:GetChildren()) do if f.Name == "VehiclePads" then
            for _, p in ipairs(f:GetChildren()) do table.insert(PADS, p); n = n + 1 end end end
        return n end""")()
    ray = lua.globals().workspace.Raycast
    corners, hang, inner = [], 0.0, math.inf
    for sx in (-1, 1):
        for sz in (-1, 1):
            lx, lz = sx * extents[0] / 2, sz * extents[2] / 2
            wx = pos.X + lx * math.cos(yaw_out) + lz * math.sin(yaw_out)
            wz = pos.Z - lx * math.sin(yaw_out) + lz * math.cos(yaw_out)
            hit = ray(None, lua.eval(f"Vector3.new({wx}, {pos.Y + 1}, {wz})"), lua.eval("Vector3.new(0, -40, 0)"))
            ground = hit.Position.Y if hit else pos.Y - 40
            hang = max(hang, pos.Y - ground)
            inner = min(inner, abs(wx))
            corners.append((wx, wz))
    return {"x": pos.X, "y": pos.Y, "hang": hang, "inner": inner, "pads": pads, "moved": abs(pos.X - x) + abs(pos.Z)}


def verdict(res, label):
    bad = []
    if res["hang"] > HANG:
        bad.append(f"hangs {res['hang']:.2f} clear at a corner")
    if res["inner"] < CARRIAGEWAY - 0.05:
        bad.append(f"inner side {res['inner']:.2f} out, on the carriageway")
    print(f"  {label}: parked at x {res['x']:.2f} y {res['y']:.2f}, worst corner gap {res['hang']:.2f}, inner side "
          f"{res['inner']:.2f}, pads {res['pads']} -> {'ok' if not bad else 'FAIL ' + '; '.join(bad)}")
    return not bad


def suite(park, footprint, inward, quiet=False):
    ok = True
    for name, kind in (("car", CAR), ("bike", BIKE)):
        for yaw in (-0.15, 0.0, 0.15):
            ok &= verdict(run(park, footprint, inward, kind, VERGE, yaw), f"{name} at the verge, yaw {yaw:+.2f}")
    level = run(park, footprint, inward, CAR, 13.0, 0.0)
    still = level["moved"] < 1e-9 and level["pads"] == 0
    print(f"  car on level verge (x 13): {'left where asked' if still else 'MOVED or padded'}")
    return ok and still


def main(repo):
    park, footprint, inward = sources(repo)
    print(f"MapGenerator's verge call passes inward = {inward}")
    ok = suite(park, footprint, inward)
    print("as built:", "PASS" if ok else "FAIL")
    print("self-test, planted chassis-only footprint (the old code):")
    chassis_only = "\tposition, yaw = parkOn(parent, position, yaw, chassis.Size, info.displayName,\n\t\ttype(options) == \"table\" and options.inward or nil)\n"
    caught1 = not suite(park, chassis_only, inward)
    print("self-test, planted no inward from MapGenerator:")
    caught2 = not suite(park, footprint, None)
    print(f"self-test: chassis-only {'caught' if caught1 else 'MISSED'}, no inward {'caught' if caught2 else 'MISSED'}")
    return 0 if ok and caught1 and caught2 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
