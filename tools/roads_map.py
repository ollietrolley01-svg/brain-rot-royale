"""Builds a whole map with the REAL MapGenerator.Build under lupa and hands back its roads as geometry,
for tools/roads_check.py.

    build(map_id, seed, faults={}) -> Geo

The world is tools/car_placement_map.py's (the mocks, the ground as a height function, the real
MapGenerator, MapDecor, RoadNetwork, MapTerrain planning, TownKinds, ParkingLots and the rest), so what
is measured is exactly what that harness builds; see its docstring for what is stood in. On top of it
this dumps:

  every BasePart on the map   name, class, where it sits in the map (its ancestors' names), its whole
                              CFrame and size, CanCollide and whether it is invisible
  the road network            every node (kind, position, road height, box, arms, curve, town) and
                              every edge (ends, direction, length, height samples, bridges, slabs)
  the towns and the river     each town's footprint as the planner had it; the planned river's course
  the ground                  sampled on request (Geo.ground / Geo.in_river), from the same GROUND the
                              harness answers raycasts with: MapTerrain's shaped relief (the road
                              corridors graded into it), the pads laid since, the river's channel

`faults` is { module name: [(old, new), ...] }, applied to the source text before it runs (planted
faults). CAR_PLACEMENT_SOURCE=<dir> builds another copy of the game's source (before/after counts).
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car_placement_map as cpm  # noqa: E402
from car_placement_luau import luau_to_lua  # noqa: E402
from lupa import LuaRuntime  # noqa: E402

DUMP = r"""
local map, roads, fmt = ...
local out = {}
local function v(x) return fmt("%.4f,%.4f,%.4f", x.X, x.Y, x.Z) end
local function walk(node, chain)
	for _, child in ipairs(node:GetChildren()) do
		if child:IsA("BasePart") then
			local c = child.CFrame
			table.insert(out, fmt("P|%s|%s|%s|%s|%s|%s|%s|%s|%d|%d", child.Name, child.ClassName, chain, v(c.Position),
				v(c.XVector), v(c.YVector), v(c.ZVector), v(child.Size), child.CanCollide and 1 or 0, child.Transparency >= 1 and 1 or 0))
		end
		local name = child.Name
		if child:GetAttribute("TownName") then
			name = "Town:" .. child:GetAttribute("TownName")
		end
		walk(child, chain == "" and name or (chain .. "/" .. name))
	end
end
walk(map, "")
local index = {}
for i, node in ipairs(roads.nodes) do index[node] = i end
for i, node in ipairs(roads.nodes) do
	local arms = {}
	for name, edge in pairs(node.arms) do table.insert(arms, name .. ":" .. edge.index) end
	table.sort(arms)
	local curve = ""
	if node.curve then
		local c = node.curve
		curve = fmt("%.4f,%.4f,%.4f,%.6f,%.6f,%d", c.centre.X, c.centre.Z, c.radius, c.a1, c.sweep, c.pieces or 0)
	end
	table.insert(out, fmt("N|%d|%s|%.4f|%.4f|%.4f|%.4f|%s|%s|%s|%s|%s", i, node.kind or "?", node.position.X, node.position.Z,
		node.height or 0, node.box or 0, table.concat(arms, ";"), curve, tostring(node.town or ""), node.control or "", node.stem or ""))
end
for i, edge in ipairs(roads.edges) do
	local heights = {}
	for _, h in ipairs(edge.heights or {}) do table.insert(heights, fmt("%.5f", h)) end
	local spans = {}
	for _, span in ipairs(edge.bridges or {}) do table.insert(spans, fmt("%.4f,%.4f", span.s0, span.s1)) end
	local slabs = {}
	for _, slab in ipairs(edge.slabs or {}) do table.insert(slabs, fmt("%.4f,%.4f,%d", slab.s0, slab.s1, slab.bridge and 1 or 0)) end
	table.insert(out, fmt("E|%d|%d|%d|%.4f|%.4f|%.4f|%.4f|%.4f,%.4f|%.6f|%.6f|%s|%s|%s", i, index[edge.a], index[edge.b], edge.from.X, edge.from.Z,
		edge.to.X, edge.to.Z, edge.dir.X, edge.dir.Z, edge.length, edge.step or 0, table.concat(heights, ";"), table.concat(spans, ";"),
		table.concat(slabs, ";")))
end
for i, town in ipairs(roads.towns) do
	table.insert(out, fmt("T|%d|%.4f|%.4f|%.4f|%.4f|%.4f", i, town.center.X, town.center.Z, town.half, town.cross, town.zext))
end
if WORLD.river then
	local pts = {}
	for _, p in ipairs(WORLD.river.points) do table.insert(pts, fmt("%.3f,%.3f", p.X, p.Z)) end
	table.insert(out, fmt("R|%.3f|%s", WORLD.river.width, table.concat(pts, ";")))
end
for _, w in ipairs(WORLD.warnings) do table.insert(out, "W|" .. w:gsub("\n", " ")) end
return table.concat(out, "\n")
"""

# The harness's raycasts answer Grass everywhere. The game's terrain under a road is painted: asphalt
# under the carriageway, gravel on the shoulders, the apron material beyond (RoadNetwork:GroundAt's
# override, written by MapTerrain.Relief), and MapWilds keeps its long grass off asphalt by reading
# that material. Without this the harness grows grass on the carriageway's edge that the game never
# would.
MATERIALS = r"""
local mock = ...
local MapTerrain = require("MapTerrain")
local base = mock.raycast
mock.raycast = function(origin, direction, params)
	local hit = base(origin, direction, params)
	if hit and hit.Instance == workspace.Terrain then
		local roads = MapTerrain._padRoads
		if roads and roads.grid then
			local _, material = roads:GroundAt(origin.X, origin.Z, hit.Position.Y)
			if material then
				hit.Material = material
			end
		end
	end
	return hit
end
"""

SAMPLER = r"""
local MapTerrain = require("MapTerrain")
return function(xs, zs, what)
	local out = {}
	for i = 1, #xs do
		if what == "ground" then
			out[i] = GROUND(xs[i], zs[i])
		elseif what == "pad" then
			-- The flat a pad writes: its margin and two voxels past it, whatever is claimed there
			-- (MapTerrain.FlattenPad). The harness's ground only knows the margin; the game's reaches
			-- 8 studs further, so this is the height the terrain really takes there, or 1e9 for none.
			out[i] = 1e9
			for _, pad in ipairs(MapTerrain.Pads) do
				if pad.outside(xs[i], zs[i]) <= pad.margin + 8 then
					out[i] = pad.height
					break
				end
			end
		else
			out[i] = (WORLD.river and MapTerrain.InRiver(WORLD.river, xs[i], zs[i], 0)) and 1 or 0
		end
	end
	return out
end
"""


def _vec(text):
    return tuple(float(x) for x in text.split(","))


class Geo:
    """One built map: parts, network nodes and edges, towns, river, and a ground sampler."""

    def __init__(self, map_id, seed, text, seconds, sampler, lua):
        self.map_id, self.seed, self.seconds = map_id, seed, seconds
        self._sampler, self._lua = sampler, lua
        self.parts, self.nodes, self.edges, self.towns, self.warnings = [], [], [], [], []
        self.river = None
        for line in text.split("\n"):
            f = line.split("|")
            tag = f[0]
            if tag == "P":
                self.parts.append({"name": f[1], "cls": f[2], "chain": f[3], "p": _vec(f[4]), "r": _vec(f[5]),
                                   "u": _vec(f[6]), "b": _vec(f[7]), "size": _vec(f[8]), "collide": f[9] == "1",
                                   "invisible": f[10] == "1"})
            elif tag == "N":
                arms = {}
                for item in f[7].split(";") if f[7] else []:
                    name, edge = item.split(":")
                    arms[name] = int(edge)
                curve = None
                if f[8]:
                    cx, cz, radius, a1, sweep, pieces = _vec(f[8])
                    curve = {"cx": cx, "cz": cz, "radius": radius, "a1": a1, "sweep": sweep, "pieces": int(pieces)}
                self.nodes.append({"index": int(f[1]), "kind": f[2], "x": float(f[3]), "z": float(f[4]),
                                   "height": float(f[5]), "box": float(f[6]), "arms": arms, "curve": curve,
                                   "town": f[9], "control": f[10], "stem": f[11]})
            elif tag == "E":
                dx, dz = _vec(f[8])
                self.edges.append({
                    "index": int(f[1]), "a": int(f[2]), "b": int(f[3]), "fx": float(f[4]), "fz": float(f[5]),
                    "tx": float(f[6]), "tz": float(f[7]), "dx": dx, "dz": dz, "length": float(f[9]),
                    "step": float(f[10]), "heights": [float(h) for h in f[11].split(";")] if f[11] else [],
                    "bridges": [_vec(s) for s in f[12].split(";")] if f[12] else [],
                    "slabs": [_vec(s) for s in f[13].split(";")] if f[13] else [],
                })
            elif tag == "T":
                self.towns.append({"index": int(f[1]), "x": float(f[2]), "z": float(f[3]), "half": float(f[4]),
                                   "cross": float(f[5]), "zext": float(f[6])})
            elif tag == "R":
                self.river = {"width": float(f[1]), "pts": [_vec(p) for p in f[2].split(";")]}
            elif tag == "W":
                self.warnings.append(line[2:])

    def _sample(self, points, what):
        out = []
        for start in range(0, len(points), 20000):
            chunk = points[start:start + 20000]
            xs = self._lua.table_from([p[0] for p in chunk])
            zs = self._lua.table_from([p[1] for p in chunk])
            result = self._sampler(xs, zs, what)
            out.extend(result[i + 1] for i in range(len(chunk)))
        return out

    def ground(self, points):
        """Ground height at each (x, z)."""
        return self._sample(points, "ground")

    def pad_flat(self, points):
        """The height a pad's flat (margin and two voxels past it) writes at each (x, z), or None."""
        return [None if v > 1e8 else v for v in self._sample(points, "pad")]

    def in_river(self, points):
        """Whether each (x, z) is in the planned river's channel."""
        return [v == 1 for v in self._sample(points, "river")]

    def edge_height(self, edge, along):
        """RoadNetwork's edgeHeight: the road's ground height `along` studs from the edge's start."""
        heights = edge["heights"]
        t = min(max(along, 0), edge["length"]) / edge["step"]
        k = int(t)
        if k >= len(heights) - 1:
            return heights[-1]
        f = t - k
        return heights[k] + (heights[k + 1] - heights[k]) * f


def build(map_id, seed, faults=None):
    faults = faults or {}
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(cpm.TOOLS, "destruct_mocks.lua"), encoding="utf-8") as f:
        mock = lua.execute(f.read())
    sources = {}
    for name in cpm.REAL_MODULES + cpm.REAL_SHARED:
        if name == "MapTerrain":
            src = cpm.terrain_source(faults.get(name))
        else:
            src = cpm.apply(cpm.source_of(name), faults.get(name), name)
        sources[name] = luau_to_lua(src)
    lua.globals().VEHICLE_SOURCE = luau_to_lua(cpm.vehicle_source(faults.get("VehicleService")))
    standins = lua.execute(cpm.STANDINS)
    lua.execute(cpm.WORLD, mock, lua.table_from(sources), standins)
    lua.execute(MATERIALS, mock)
    lua.execute("math.randomseed(...)", seed)
    started = time.time()
    result = lua.eval('function(mapId) return require("MapGenerator").Build(mapId) end')(map_id)
    seconds = time.time() - started
    text = lua.execute(DUMP, result.map, result.roads, lua.eval("string.format"))
    sampler = lua.execute(SAMPLER)
    return Geo(map_id, seed, text, seconds, sampler, lua)


def map_ids():
    return cpm.map_ids()


if __name__ == "__main__":
    g = build(sys.argv[1] if len(sys.argv) > 1 else "TralalaTown", int(sys.argv[2]) if len(sys.argv) > 2 else 1)
    from collections import Counter
    print("%s seed %d: %.1fs, %d parts, %d nodes, %d edges, %d towns" % (g.map_id, g.seed, g.seconds, len(g.parts),
                                                                         len(g.nodes), len(g.edges), len(g.towns)))
    roadish = Counter(p["name"] for p in g.parts if p["chain"].startswith("Roads") or "Town:" in p["chain"])
    print(sorted(roadish.items(), key=lambda kv: -kv[1])[:80])
    for w in g.warnings:
        print("  warn:", w[:300])
