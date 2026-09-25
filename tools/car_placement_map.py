"""Builds a whole map with the REAL MapGenerator.Build under lupa, for tools/car_placement_check.py.

    build(map_id, seed, faults={}) -> Map   (see the class at the bottom for what it holds)

The mocks are tools/destruct_mocks.lua plus WORLD below (the ground, raycasts, module wiring). What runs is the real source of MapGenerator, MapDecor, MapSpace, RoadNetwork,
TownKinds, TownThemes, ParkingLots, MapBuildings, MapWilds, MapData, VehicleModels and SafeValue.
Stood in, with what that costs:

  MapTerrain   the real module, with the voxel writers replaced: Relief runs for real up to where it
               starts writing voxels (so the roads' heights and the shaped ground are the real ones),
               FlattenPad is re-done over the height function (same refusals: a road's corridor, too
               much cut or fill, another pad's flat), the river is its real planned course with a
               flat channel, and no hills or plateau tops are raised (their ground stays claimed).
  VehicleService   rebuilt from its own source: everything from FOOTING_TOLERANCE to the end of parkOn,
               ParkInTowns and ParkLots verbatim, and Create's model choice and footprint block
               verbatim; what it leaves out is the seats, prompts, physics rig and health.
  Landmarks, EasterEggs, VendorService, HazardService, ZFight, BrainrotData, ZiplineService,
  MovementService, DestructibleService: empty stand-ins. The landmarks and eggs only claim ground
  (every car asks MapSpace before it parks, so it keeps off whatever they would have claimed).

`faults` is { module name: [(old, new), ...] } applied to the source text before it runs.
"""

import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from car_placement_luau import luau_to_lua  # noqa: E402

from lupa import LuaRuntime  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# CAR_PLACEMENT_SOURCE=<dir> runs another copy of the game's source (e.g. `git archive` of an older
# commit), for before-and-after counts; the harness itself always comes from this tree.
SOURCE = os.environ.get("CAR_PLACEMENT_SOURCE") or ROOT
MODULES = os.path.join(SOURCE, "ServerScriptService", "Modules")
SHARED = os.path.join(SOURCE, "ReplicatedStorage", "Shared")
TOOLS = os.path.join(ROOT, "tools")

REAL_MODULES = ["MapGenerator", "MapDecor", "MapSpace", "RoadNetwork", "TownKinds", "TownThemes", "ParkingLots",
                "MapBuildings", "MapWilds", "MapTerrain"]
REAL_SHARED = ["MapData", "VehicleModels", "SafeValue"]


def source_of(name):
    for folder in (MODULES, SHARED):
        path = os.path.join(folder, name + ".lua")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                return f.read()
    raise SystemExit("no source for " + name)


def apply(source, faults, name):
    for old, new in faults or ():
        if old not in source:
            raise SystemExit("planted fault did not apply to %s (text not found): %r" % (name, old[:90]))
        source = source.replace(old, new, 1)
    return source


# MapTerrain: the voxel writers go; the planning, the river's course and the pad bookkeeping stay.
TERRAIN_TAIL = r"""
function MapTerrain.Plateaus(terrain, parent, preset, radius, centers, townSpread, space, chestSpots, lootSpots, groundHeightAt, placed)
	return placed or {}
end
function MapTerrain.Hills() return 0 end
function MapTerrain.RestoreRoadGround() end
function MapTerrain.PaintPatches() end
function MapTerrain.PaintPatch() return nil end
function MapTerrain.SetClouds() end
function MapTerrain.RewritePads() return #MapTerrain.Pads end
function MapTerrain.River(terrain, parent, preset, radius, centers, townSpread, plateaus, roads, space, lootSpots, groundHeightAt, plan)
	plan = plan or MapTerrain.PlanRiver(radius, centers, townSpread, plateaus, roads)
	if not plan then
		return nil
	end
	local river = { points = plan.points, width = RIVER_WIDTH, bridges = {}, roadCrossings = {}, pond = plan.pond }
	WORLD.river = river
	return river
end
-- FlattenPad over the height function: the same refusals as the voxel version, the same record.
function MapTerrain.FlattenPad(site, size, options)
	options = options or {}
	local margin = options.margin or PAD_MARGIN
	if options.material and not RoadNetwork.SmoothMaterials[options.material] then
		return nil, "material"
	end
	local outside, reach = padShape(site, size, options)
	local roads = MapTerrain._padRoads
	local p = site.Position
	local R = reach + margin + PAD_CELL
	local low, high, total, samples = math.huge, -math.huge, 0, 0
	local cells = {}
	for x = p.X - R, p.X + R, PAD_CELL do
		for z = p.Z - R, p.Z + R, PAD_CELL do
			if outside(x, z) <= margin then
				if roads and roads:WithinCorridor(x, z) then
					return nil, "road"
				end
				local h = GROUND(x, z)
				low, high, total, samples = math.min(low, h), math.max(high, h), total + h, samples + 1
				table.insert(cells, { x, z })
			end
		end
	end
	if samples == 0 then
		return nil, "nothing"
	end
	local height = options.height
	if height == nil then
		height = site.Position.Y
	elseif height == "mid" then
		height = (low + high) / 2
	elseif height == "mean" then
		height = total / samples
	elseif height == "low" then
		height = low
	elseif height == "high" then
		height = high
	end
	if options.maxCut and high - height > options.maxCut then
		return nil, "cut"
	end
	if options.maxFill and height - low > options.maxFill then
		return nil, "fill"
	end
	for _, cell in ipairs(cells) do
		local other = MapTerrain.PadAt(cell[1], cell[2])
		if other and math.abs(other - height) > 0.05 then
			return nil, "pad"
		end
	end
	table.insert(MapTerrain.Pads, { outside = outside, margin = margin, blend = options.retain and 0 or PAD_BLEND_MAX,
		height = height, site = site, size = size, material = options.material, shape = options.shape })
	return height
end
"""


def terrain_source(faults):
    src = apply(source_of("MapTerrain"), faults, "MapTerrain")
    start = src.index("function MapTerrain.Relief(")
    cut = src.index("\tlocal span = RELIEF_TILE / 4", start)
    end = src.index("\nend\n", cut)
    src = src[:cut] + "\tWORLD.relief = true\n" + src[end:]
    head, tail = src.rsplit("return MapTerrain", 1)
    return head + TERRAIN_TAIL + "\nreturn MapTerrain" + tail


def vehicle_source(faults):
    vs = apply(source_of("VehicleService"), faults, "VehicleService")
    park = vs[vs.index("local FOOTING_TOLERANCE"):vs.index("-- Other tabs' vehicle types")].rsplit("\n----", 1)[0]
    # ParkInTowns with whatever constants and helpers sit with it: from its header comment to Count.
    region = re.search(r"\n-- Parks vehicles on .*?(?=\nfunction VehicleService\.Count\(\))", vs, re.S)
    if not region:
        raise SystemExit("VehicleService.ParkInTowns moved; update tools/car_placement_map.py")
    funcs, helpers = [region.group(0) + "\n"], []
    create = re.search(r"\nfunction VehicleService\.Create\(.*?\n\tlocal chassis = info\.chassis\n", vs, re.S)
    footprint = re.search(r"\n(\tlocal footprint = chassis\.Size\n.*?\n\tmodel:PivotTo\([^\n]*\n)", vs, re.S)
    assert create and footprint, "VehicleService.Create's shape moved; update tools/car_placement_map.py"
    lift = re.search(r"\nlocal SPAWN_LIFT = [\d.]+\n", vs).group(0)
    return ("local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\n"
            "local Shared = ReplicatedStorage:WaitForChild(\"Shared\")\n"
            "local VehicleModels = require(Shared:WaitForChild(\"VehicleModels\"))\n"
            "local VehicleService = {}\nlocal registered = {}\nlocal active = {}\n" + lift + park + "\n"
            + "".join(helpers) + "".join(funcs)
            + create.group(0) + footprint.group(1)
            + "\tmodel.Parent = parent\n"
            + "\tmodel:SetAttribute(\"HarnessCF\", CFrame.new(position) * CFrame.Angles(0, yaw, 0))\n"
            + "\tmodel:SetAttribute(\"HarnessKind\", info.kind or kind)\n"
            + "\tmodel:SetAttribute(\"HarnessModel\", info.modelId or \"?\")\n"
            + "\ttable.insert(active, model)\n\treturn model\nend\n"
            + "function VehicleService.Count() return #active end\n"
            # ParkInTowns parks a car again after centring it in its bay; the rest hold isn't modelled here.
            + "function VehicleService.Repark() end\n"
            + "return VehicleService\n")


# The parked cars say where they were put (instrumentation only: the harness reads the frame back).
DECOR_PROBE = [('\tcar.Name = "ParkedCar"\n', '\tcar.Name = "ParkedCar"\n\tcar:SetAttribute("HarnessCF", cf)\n'
                '\tcar:SetAttribute("HarnessModel", design and design.id or "plain")\n')]

# The world: loaded after tools/destruct_mocks.lua. Plain Lua (lupa's), not Luau, so it lives here
# rather than in a .lua file the Luau static check would read.
WORLD = r"""
-- The whole-map world for tools/car_placement_check.py: it
-- adds what MapGenerator.Build needs on top of those mocks and wires require() to the real module
-- sources (passed in from Python) or to the stand-ins below.
--
-- Real: MapGenerator, MapDecor, MapSpace, RoadNetwork, TownKinds, TownThemes, ParkingLots,
-- MapBuildings, MapWilds, MapData, VehicleModels, SafeValue, and MapTerrain's planning, river and
-- pad bookkeeping. Stood in: everything that writes voxels (the ground is a height function here,
-- the one MapTerrain.Relief itself shapes: the natural relief field, flat under towns and dead flat
-- across every road's corridor at the road's own height), the landmarks and easter eggs (they only
-- claim ground the cars must keep off, and every car placement asks MapSpace, which is real), and
-- VehicleService, which is rebuilt from its own source: parkOn, ParkInTowns and Create's model
-- choice and footprint, verbatim (see the Python side).

local mock, sources, standins = ...

-- Smooth value noise in place of math.noise (the mocks return 0, which would make every map flat).
local function hash(ix, iy, iz)
	local h = (ix * 374761393 + iy * 668265263 + iz * 2147483647) % 4294967296
	h = ((h ~ (h >> 13)) * 1274126177) % 4294967296
	return (h % 100000) / 100000 - 0.5
end
math.noise = function(x, y, z)
	y, z = y or 0, z or 0
	local ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
	local fx, fy, fz = x - ix, y - iy, z - iz
	local function s(t) return t * t * (3 - 2 * t) end
	local ux, uy, uz = s(fx), s(fy), s(fz)
	local function lerp(a, b, t) return a + (b - a) * t end
	local c = {}
	for dx = 0, 1 do for dy = 0, 1 do for dz = 0, 1 do
		c[dx * 4 + dy * 2 + dz] = hash(ix + dx, iy + dy, iz + dz)
	end end end
	local x00 = lerp(c[0], c[4], ux)
	local x01 = lerp(c[1], c[5], ux)
	local x10 = lerp(c[2], c[6], ux)
	local x11 = lerp(c[3], c[7], ux)
	return lerp(lerp(x00, x10, uy), lerp(x01, x11, uy), uz)
end
math.lerp = math.lerp or function(a, b, t) return a + (b - a) * t end
table.create = table.create or function(n, v) local t = {} for i = 1, n do t[i] = v end return t end
-- Luau's %d takes a float (it truncates); Lua 5.4+ refuses one.
local rawformat = string.format
string.format = function(pattern, ...)
	local ok, result = pcall(rawformat, pattern, ...)
	if ok then return result end
	local args = table.pack(...)
	for i = 1, args.n do
		if type(args[i]) == "number" and args[i] ~= math.floor(args[i]) then args[i] = math.floor(args[i] + 0.5) end
	end
	return rawformat(pattern, table.unpack(args, 1, args.n))
end

-- Vector2 with arithmetic (the lamps and signs add them).
local V2 = {}
V2.__index = function(v, key)
	if key == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y) end
	if key == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y) return Vector2.new(v.X / m, v.Y / m) end
	return V2[key]
end
V2.__add = function(a, b) return Vector2.new(a.X + b.X, a.Y + b.Y) end
V2.__sub = function(a, b) return Vector2.new(a.X - b.X, a.Y - b.Y) end
V2.__mul = function(a, b) if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return Vector2.new(a.X * b, a.Y * b) end return Vector2.new(a.X * b.X, a.Y * b.Y) end
V2.__div = function(a, b) return Vector2.new(a.X / b, a.Y / b) end
function V2.Dot(a, b) return a.X * b.X + a.Y * b.Y end
Vector2 = { new = function(x, y) return setmetatable({ X = x or 0, Y = y or 0, __type = "Vector2" }, V2) end }
Vector2.zero = Vector2.new(0, 0)
Vector2.one = Vector2.new(1, 1)

-- CFrame:ToOrientation (Y, then X, then Z), which the pads read their yaw from.
local C = getmetatable(CFrame.new())
function C.ToOrientation(c)
	local rx = math.asin(math.clamp(-c.b.Y, -1, 1))
	local ry = math.atan(c.b.X, c.b.Z)
	local rz = math.atan(c.r.Y, c.u.Y)
	return rx, ry, rz
end
C.ToEulerAnglesYXZ = C.ToOrientation

-- pairs in a fixed order for string and number keys: Lua seeds its string hashing per state, so plain
-- pairs walks the same table differently from run to run, and a map would not rebuild the same twice.
local rawpairs = pairs
local function orderedPairs(t)
	local mt = getmetatable(t)
	if mt and mt.__pairs then return rawpairs(t) end
	local keys, others = {}, {}
	for k in rawpairs(t) do
		local kt = type(k)
		if kt == "string" or kt == "number" then table.insert(keys, k) else table.insert(others, k) end
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return a < b
	end)
	for _, k in ipairs(others) do table.insert(keys, k) end
	local i = 0
	return function()
		i = i + 1
		local k = keys[i]
		if k == nil then return nil end
		return k, t[k]
	end, t, nil
end
ORDERED_PAIRS = orderedPairs

local I = getmetatable(Instance.new("Part"))
-- A Model's PivotTo moves its parts, about its PrimaryPart's pivot (or its own pivot record).
I.PivotTo = function(inst, target)
	if inst.ClassName ~= "Model" then inst.CFrame = target return end
	local primary = inst.PrimaryPart
	local pivot = primary and primary.CFrame * (primary.PivotOffset or CFrame.new()) or (rawget(inst, "__pivot") or CFrame.new())
	local move = target * pivot:Inverse()
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then d.CFrame = move * d.CFrame end
	end
	rawset(inst, "__pivot", target)
end
I.GetPivot = function(inst)
	if inst.ClassName == "Model" or inst.ClassName == "Folder" then
		local primary = inst.PrimaryPart
		if primary then return primary.CFrame * (primary.PivotOffset or CFrame.new()) end
		return rawget(inst, "__pivot") or CFrame.new()
	end
	return inst.CFrame or CFrame.new()
end
-- Turned to the PrimaryPart (else the pivot), as Roblox's is: a box in world axes put a turned car's
-- middle off its own (a SahurVan in an angled bay 0.5 along off its stall), where the game's is not.
I.GetBoundingBox = function(model)
	local primary = model.PrimaryPart
	local frame = primary and primary.CFrame or model:GetPivot()
	local low, high
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local s = d.Size / 2
			for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
				local p = frame:PointToObjectSpace(d.CFrame * Vector3.new(sx * s.X, sy * s.Y, sz * s.Z))
				low = low and low:Min(p) or p
				high = high and high:Max(p) or p
			end end end
		end
	end
	if not low then return CFrame.new(), Vector3.new(0, 0, 0) end
	local centre = frame * ((low + high) / 2)
	return frame.Rotation + centre, high - low
end
I.GetExtentsSize = function(model) local _, size = model:GetBoundingBox() return size end
I.ScaleTo = function() end
I.GetScale = function() return 1 end
I.GetFullName = function(inst) return inst.Name end
I.Clone = function(inst)
	local copy = Instance.new(inst.ClassName)
	for k, v in pairs(rawget(inst, "__props")) do rawget(copy, "__props")[k] = v end
	for k, v in pairs(rawget(inst, "__attributes")) do rawget(copy, "__attributes")[k] = v end
	for _, child in ipairs(inst:GetChildren()) do child:Clone().Parent = copy end
	return copy
end
I.GetTouchingParts = function() return {} end
I.ApplyImpulse = function() end
I.SetNetworkOwner = function() end
I.BreakJoints = function() end

workspace.BulkMoveTo = function(_, parts, cframes)
	for index, part in ipairs(parts) do part.CFrame = cframes[index] end
end
workspace.GetPartBoundsInBox = function() return {} end

-- The terrain. Everything that writes voxels is a no-op; the ground is GROUND(x, z) below.
local terrain = workspace.Terrain
for _, name in ipairs({ "FillBlock", "FillBall", "FillWedge", "FillRegion", "Clear", "ReplaceMaterial",
	"WriteVoxels", "SetMaterialColor", "PasteRegion" }) do
	terrain[name] = function() end
end
-- Voxel reads come back empty (air, occupancy 0) however they're indexed.
local function grid(default)
	return setmetatable({}, { __index = function(t, i)
		local row = setmetatable({}, { __index = function(r, j)
			local column = setmetatable({}, { __index = function() return default end })
			rawset(r, j, column)
			return column
		end })
		rawset(t, i, row)
		return row
	end })
end
terrain.ReadVoxels = function() return grid(Enum.Material.Air), grid(0) end
-- Water cut into the ground (the lakes): remembered, so the ground there reads as water.
terrain.FillCylinder = function(_, cframe, height, radius, material)
	if material == Enum.Material.Water then
		table.insert(WORLD.lakes, { x = cframe.X, z = cframe.Z, radius = radius })
	end
end
Region3 = { new = function(low, high)
	local region = { CFrame = CFrame.new((low + high) / 2), Size = high - low, __type = "Region3" }
	region.ExpandToGrid = function(self, cell)
		local lo = Vector3.new(math.floor(low.X / cell) * cell, math.floor(low.Y / cell) * cell, math.floor(low.Z / cell) * cell)
		local hi = Vector3.new(math.ceil(high.X / cell) * cell, math.ceil(high.Y / cell) * cell, math.ceil(high.Z / cell) * cell)
		return Region3.new(lo, hi)
	end
	return region
end }

-- The ground: the relief MapTerrain.Relief worked out (roads shaped into it), the river's channel,
-- and the flat pads laid since (car parks, building lots).
WORLD = { river = nil, hardstanding = {}, lakes = {}, warnings = {} }
warn = function(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	table.insert(WORLD.warnings, table.concat(parts, " "))
end
function GROUND(x, z)
	local MapTerrain = mock.modules.MapTerrain
	local padded = MapTerrain and MapTerrain.PadAt(x, z)
	if padded then
		return padded
	end
	local y = MapTerrain and MapTerrain.ReliefAt(x, z) or 0
	if WORLD.river and MapTerrain.InRiver(WORLD.river, x, z, -4) then
		y = math.min(y, -6)
	end
	for _, lake in ipairs(WORLD.lakes) do
		if (x - lake.x) ^ 2 + (z - lake.z) ^ 2 < lake.radius ^ 2 then
			y = math.min(y, -4)
		end
	end
	return y
end
-- Raycasts: straight down only, against the ground, and (unless excluded) the Hardstanding pads
-- VehicleService lays.
mock.raycast = function(origin, direction, params)
	local y = GROUND(origin.X, origin.Z)
	local excluded = {}
	if params and params.FilterType == Enum.RaycastFilterType.Exclude then
		for _, inst in ipairs(params.FilterDescendantsInstances or {}) do excluded[inst] = true end
	end
	local includeOnlyTerrain = params and params.FilterType == Enum.RaycastFilterType.Include
	if not includeOnlyTerrain and WORLD.hardstanding then
		for _, pad in ipairs(WORLD.hardstanding) do
			if pad.Parent and not excluded[pad.Parent] then
				local l = pad.CFrame:PointToObjectSpace(origin)
				if math.abs(l.X) <= pad.Size.X / 2 and math.abs(l.Z) <= pad.Size.Z / 2 then
					y = math.max(y, pad.CFrame.Y + pad.Size.Y / 2)
				end
			end
		end
	end
	if y <= origin.Y and y >= origin.Y + direction.Y then
		return { Position = Vector3.new(origin.X, y, origin.Z), Material = Enum.Material.Grass,
			Instance = terrain, Normal = Vector3.new(0, 1, 0) }
	end
	return nil
end

-- Modules ---------------------------------------------------------------------------------------
local shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
if not shared then
	shared = Instance.new("Folder"); shared.Name = "Shared"; shared.Parent = game:GetService("ReplicatedStorage")
end
local modulesFolder = Instance.new("Folder")
modulesFolder.Name = "Modules"
modulesFolder.Parent = game:GetService("ServerScriptService")
mock.modules = mock.modules or {}
local loading = {}
local function register(name, folder)
	local m = Instance.new("ModuleScript"); m.Name = name; m.Parent = folder
end
-- Every name in both folders: require() resolves by name, so where a module lives doesn't matter.
for _, list in ipairs({ sources, standins }) do
	for name in pairs(list) do
		register(name, modulesFolder)
		register(name, shared)
	end
end

script = modulesFolder:FindFirstChild("MapGenerator")
-- Roblox's value types and Instances are userdata, so module code that deep-copies "tables" (TownKinds'
-- profile merge) leaves a Color3 alone; the mocks' are tables, so the modules see them as userdata.
local rawtype = type
local moduleEnv = setmetatable({
	pairs = ORDERED_PAIRS,
	type = function(value)
		if rawtype(value) == "table" and (rawget(value, "__type") or rawget(value, "__instance")) then
			return "userdata"
		end
		return rawtype(value)
	end,
}, { __index = _G, __newindex = _G })
require = function(inst)
	local name = type(inst) == "table" and inst.Name or tostring(inst)
	if mock.modules[name] ~= nil then return mock.modules[name] end
	if standins[name] then
		mock.modules[name] = standins[name]()
		return mock.modules[name]
	end
	local source = sources[name]
	if not source then error("no module for " .. tostring(name)) end
	if loading[name] then error("require cycle at " .. name) end
	loading[name] = true
	local chunk = assert(load(source, "=" .. name, "t", moduleEnv))
	local saved = script
	script = modulesFolder:FindFirstChild(name)
	local result = chunk()
	script = saved
	loading[name] = nil
	mock.modules[name] = result
	return result
end

return mock
"""

STANDINS = r"""
local S = {}
local function empty() return setmetatable({}, { __index = function() return function() end end }) end
S.ZFight = function() return { Fix = function() return { moved = 0, resized = 0, remaining = {} } end } end
S.BrainrotData = function() return { OfRarity = function() return {} end } end
S.BrainrotModels = empty
S.Landmarks = function() return { Place = function() return {}, {} end } end
S.EasterEggs = function() return { Place = function() return {}, nil end } end
S.VendorService = empty
S.DestructibleService = empty
S.ZiplineService = function() return { Create = function() return false end } end
S.MovementService = empty
S.Remotes = function() return { Event = function() return { FireAllClients = function() end } end } end
S.HazardService = function()
	return { Barrel = function(parent, cframe)
		local p = Instance.new("Part"); p.Name = "Barrel"; p.Anchored = true
		p.Size = Vector3.new(2.6, 3.4, 2.6); p.CFrame = cframe * CFrame.new(0, 1.7, 0); p.Parent = parent
		return p
	end }
end
S.VehicleService = function()
	return assert(load(VEHICLE_SOURCE, "=VehicleService"))()
end
return S
"""

# Everything the rules need, as text (lupa's per-element access is slow): one line per part.
DUMP = r"""
local map, roads, fmt = ...
local SPAWN_LIFT_ = 0.25
local out = {}
-- The flat things a car may stand on, or must keep off, as exact rectangles.
local SURFACES = { Asphalt = true, JunctionAsphalt = true, Crossing = true, StopLine = true, Kerb = true, Pavement = true,
	RoadSurface = true, BridgeRoad = true, BridgeDeck = true, Driveway = true, DroppedKerb = true, Layby = true,
	Hardstanding = true, Paving = true, Cobbles = true, LotSurface = true, LotApron = true, BayLine = true, StallLine = true,
	LotCurb = true, IslandCurb = true, IslandSoil = true, Walkway = true, WalkwayRamp = true, TimberEdging = true, WheelStop = true,
	TimberWheelStop = true, AccessibleFill = true, HatchLine = true, AisleArrow = true, StopBar = true, CrossingStripe = true,
	OilStain = true, AsphaltPatch = true, DrainGrate = true, TyreTrack = true, ExpansionJoint = true, AccessibleSign = true }
local function chain(inst)
	local names = {}
	local node = inst.Parent
	while node and node ~= map do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	return table.concat(names, "/")
end
-- A parked car's frame is the one it was built at; a drivable's is wherever its pivot is now (a
-- placement may move it after Create), levelled to a yaw.
local function frameOf(car)
	local cf = car:GetAttribute("HarnessCF")
	if car.Name ~= "ParkedCar" and cf then
		local pivot = car:GetPivot()
		local look = pivot.LookVector
		cf = CFrame.lookAt(pivot.Position - Vector3.new(0, SPAWN_LIFT_, 0),
			pivot.Position - Vector3.new(0, SPAWN_LIFT_, 0) + Vector3.new(look.X, 0, look.Z))
	end
	return cf
end
-- Cars: the frame they were put at, and their parts' extent in that frame.
local cars = {}
for _, d in ipairs(map:GetDescendants()) do
	if (d.Name == "ParkedCar" or d:GetAttribute("HarnessKind")) and frameOf(d) then
		table.insert(cars, d)
	end
end
local isCar = {}
for index, car in ipairs(cars) do
	isCar[car] = index
	local cf = frameOf(car)
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	for _, part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 then
			local s = part.Size / 2
			for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
				local p = cf:PointToObjectSpace(part.CFrame * Vector3.new(sx * s.X, sy * s.Y, sz * s.Z))
				lo[1], lo[2], lo[3] = math.min(lo[1], p.X), math.min(lo[2], p.Y), math.min(lo[3], p.Z)
				hi[1], hi[2], hi[3] = math.max(hi[1], p.X), math.max(hi[2], p.Y), math.max(hi[3], p.Z)
			end end end
		end
	end
	local look = cf.LookVector
	table.insert(out, fmt("C|%d|%s|%s|%s|%.3f|%.3f|%.3f|%.5f|%.5f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%s", index,
		d_kind(car), chain(car), tostring(car:GetAttribute("HarnessModel") or ""), cf.X, cf.Y, cf.Z, look.X, look.Z,
		lo[1], hi[1], lo[2], hi[2], lo[3], hi[3], tostring(car:GetAttribute("ParkStyle") or "")))
end
-- Parts that aren't a car's: their turned corners' XZ hull is taken on the Python side.
local function inCar(part)
	local node = part.Parent
	while node and node ~= map do
		if isCar[node] then return true end
		node = node.Parent
	end
	return false
end
for _, part in ipairs(map:GetDescendants()) do
	if part:IsA("BasePart") and not inCar(part) then
		local s = part.Size / 2
		local c = part.CFrame
		local pts = {}
		local ylo, yhi = math.huge, -math.huge
		for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
			local p = c * Vector3.new(sx * s.X, sy * s.Y, sz * s.Z)
			ylo, yhi = math.min(ylo, p.Y), math.max(yhi, p.Y)
			table.insert(pts, fmt("%.2f,%.2f", p.X, p.Z))
		end end end
		table.insert(out, fmt("P|%s|%s|%.2f|%.2f|%s|%d|%d", part.Name, chain(part), ylo, yhi, table.concat(pts, ";"),
			part.CanCollide and 1 or 0, part.Transparency >= 1 and 1 or 0))
		if SURFACES[part.Name] then
			local r, l = c.RightVector, c.LookVector
			table.insert(out, fmt("F|%s|%s|%.3f|%.3f|%.3f|%.5f|%.5f|%.5f|%.5f|%.3f|%.3f|%.3f", part.Name, chain(part),
				c.X, c.Y, c.Z, r.X, r.Z, l.X, l.Z, part.Size.X, part.Size.Y, part.Size.Z))
		end
	end
end
-- Towns: centre, spread, kind, blurb, bays.
local towns = map:FindFirstChild("Towns") or map
for _, town in ipairs(towns:GetChildren()) do
	if town.Name == "Town" then
		local c = town:GetAttribute("TownCenter")
		table.insert(out, fmt("T|%s|%s|%.2f|%.2f|%.2f|%s|%s", town:GetAttribute("TownName") or "?", town:GetAttribute("TownKind") or "?",
			c.X, c.Z, town:GetAttribute("TownSpread") or 0, ((town:GetAttribute("TownBlurb") or ""):gsub("|", "/")),
			tostring(town:GetAttribute("ParkingFill") or "")))
		local size = town:GetAttribute("ParkingBaySize")
		-- Bays, then the accessible stalls (index negative), with the car park's kind and the bay beside.
		local kind = tostring(town:GetAttribute("ParkingKind") or "")
		for index = 1, town:GetAttribute("ParkingBays") or 0 do
			local cf = town:GetAttribute("ParkingBay_" .. index)
			table.insert(out, fmt("B|%s|%d|%.3f|%.3f|%.3f|%.5f|%.5f|%.2f|%.2f|%s|%d", town:GetAttribute("TownName") or "?", index,
				cf.X, cf.Y, cf.Z, cf.LookVector.X, cf.LookVector.Z, size and size.X or 8.9, size and size.Z or 16.6, kind,
				town:GetAttribute("ParkingBayNext_" .. index) or 0))
		end
		for index = 1, town:GetAttribute("ParkingAccessible") or 0 do
			local cf = town:GetAttribute("ParkingAccessible_" .. index)
			table.insert(out, fmt("B|%s|%d|%.3f|%.3f|%.3f|%.5f|%.5f|%.2f|%.2f|%s|0", town:GetAttribute("TownName") or "?", -index,
				cf.X, cf.Y, cf.Z, cf.LookVector.X, cf.LookVector.Z, size and size.X or 8.9, size and size.Z or 16.6, kind))
		end
		-- The car park's model: its kind, layout, aisle, and its parts (counted here, and as it counts them).
		local lot = town:FindFirstChild("ParkingLot")
		if lot then
			local parts = 0
			for _, d in ipairs(lot:GetDescendants()) do
				if d:IsA("BasePart") then parts = parts + 1 end
			end
			local a, b = lot:GetAttribute("AisleA"), lot:GetAttribute("AisleB")
			local surface = lot:FindFirstChild("LotSurface")
			table.insert(out, fmt("K|%s|%s|%s|%.3f|%.3f|%.3f|%.3f|%.2f|%d|%d|%.3f|%.3f", town:GetAttribute("TownName") or "?",
				tostring(lot:GetAttribute("Kind")), tostring(lot:GetAttribute("Layout")), a and a.X or 0, a and a.Z or 0, b and b.X or 0,
				b and b.Z or 0, lot:GetAttribute("AisleWidth") or 0, lot:GetAttribute("Parts") or -1, parts,
				surface and surface.Position.X or 0, surface and surface.Position.Z or 0))
		end
	end
end
-- Country roads: every edge (from, to, the straight part, bridges) and every node.
for index, edge in ipairs(roads.edges) do
	local from = edge.a.curve and edge.a.box or 0
	local to = edge.length - (edge.b.curve and edge.b.box or 0)
	local spans = {}
	for _, span in ipairs(edge.bridges or {}) do table.insert(spans, fmt("%.1f,%.1f", span.s0, span.s1)) end
	table.insert(out, fmt("E|%d|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%s|%s|%s", index, edge.from.X, edge.from.Z, edge.to.X, edge.to.Z,
		from, to, table.concat(spans, ";"), edge.a.kind or "?", edge.b.kind or "?"))
end
for _, node in ipairs(roads.nodes) do
	table.insert(out, fmt("N|%s|%.2f|%.2f|%s", node.kind or "?", node.position.X, node.position.Z,
		node.curve and fmt("%.1f", node.curve.radius or 0) or ""))
end
-- Car parks: the ground under each one's whole footprint (its asphalt and the kerb round it), sampled
-- every 2 studs, for tools/parking_lot_check.py's level rule.
for _, part in ipairs(map:GetDescendants()) do
	if part.Name == "LotSurface" then
		local low, high = math.huge, -math.huge
		local hx, hz = part.Size.X / 2 + 0.8, part.Size.Z / 2 + 0.8
		for x = -hx, hx + 0.01, 2 do
			for z = -hz, hz + 0.01, 2 do
				local p = part.CFrame * Vector3.new(math.min(x, hx), 0, math.min(z, hz))
				local g = GROUND(p.X, p.Z)
				low, high = math.min(low, g), math.max(high, g)
			end
		end
		table.insert(out, fmt("L|%.3f|%.3f|%.3f|%.3f", part.Position.X, part.Position.Z, low, high))
	end
end
if WORLD.river then
	local pts = {}
	for _, p in ipairs(WORLD.river.points) do table.insert(pts, fmt("%.1f,%.1f", p.X, p.Z)) end
	table.insert(out, fmt("R|%.1f|%s", WORLD.river.width, table.concat(pts, ";")))
end
for _, w in ipairs(WORLD.warnings) do table.insert(out, "W|" .. w:gsub("\n", " ")) end
return table.concat(out, "\n")
"""


class Map:
    """What one build left: cars, parts, towns, bays, road edges and nodes, the river."""

    def __init__(self, map_id, seed, text, seconds, attrs):
        self.map_id, self.seed, self.seconds, self.attrs = map_id, seed, seconds, attrs
        self.cars, self.parts, self.towns, self.bays, self.edges, self.nodes = [], [], [], [], [], []
        self.river = None
        self.warnings = []
        self.surfaces = []
        self.lot_ground = []
        self.lots = []
        for line in text.split("\n"):
            f = line.split("|")
            tag = f[0]
            if tag == "C":
                self.cars.append({
                    "index": int(f[1]), "kind": f[2], "chain": f[3], "model": f[4],
                    "x": float(f[5]), "y": float(f[6]), "z": float(f[7]), "lx": float(f[8]), "lz": float(f[9]),
                    "x0": float(f[10]), "x1": float(f[11]), "y0": float(f[12]), "y1": float(f[13]),
                    "z0": float(f[14]), "z1": float(f[15]), "style": f[16] if len(f) > 16 else "",
                })
            elif tag == "P":
                pts = [tuple(float(v) for v in p.split(",")) for p in f[5].split(";")] if f[5] else []
                self.parts.append({"name": f[1], "chain": f[2], "y0": float(f[3]), "y1": float(f[4]), "pts": pts,
                                   "collide": f[6] == "1", "invisible": f[7] == "1"})
            elif tag == "T":
                self.towns.append({"name": f[1], "kind": f[2], "x": float(f[3]), "z": float(f[4]), "spread": float(f[5]),
                                   "blurb": f[6], "fill": float(f[7]) if len(f) > 7 and f[7] else None})
            elif tag == "L":
                self.lot_ground.append({"x": float(f[1]), "z": float(f[2]), "low": float(f[3]), "high": float(f[4])})
            elif tag == "B":
                self.bays.append({"town": f[1], "index": int(f[2]), "x": float(f[3]), "y": float(f[4]), "z": float(f[5]),
                                  "lx": float(f[6]), "lz": float(f[7]), "w": float(f[8]), "d": float(f[9]),
                                  "lotKind": f[10] if len(f) > 10 else "", "next": int(f[11]) if len(f) > 11 else 0,
                                  "accessible": int(f[2]) < 0})
            elif tag == "K":
                self.lots.append({"town": f[1], "kind": f[2], "layout": f[3], "ax": float(f[4]), "az": float(f[5]), "bx": float(f[6]),
                                  "bz": float(f[7]), "aisle": float(f[8]), "partsAttr": int(f[9]), "parts": int(f[10]),
                                  "x": float(f[11]), "z": float(f[12])})
            elif tag == "E":
                spans = [tuple(float(v) for v in s.split(",")) for s in f[8].split(";")] if f[8] else []
                self.edges.append({"index": int(f[1]), "ax": float(f[2]), "az": float(f[3]), "bx": float(f[4]),
                                   "bz": float(f[5]), "from": float(f[6]), "to": float(f[7]), "bridges": spans,
                                   "akind": f[9], "bkind": f[10]})
            elif tag == "N":
                self.nodes.append({"kind": f[1], "x": float(f[2]), "z": float(f[3]), "curve": f[4]})
            elif tag == "F":
                self.surfaces.append({"name": f[1], "chain": f[2], "x": float(f[3]), "y": float(f[4]), "z": float(f[5]),
                                      "rx": float(f[6]), "rz": float(f[7]), "lx": float(f[8]), "lz": float(f[9]),
                                      "sx": float(f[10]), "sy": float(f[11]), "sz": float(f[12])})
            elif tag == "W":
                self.warnings.append(line[2:])
            elif tag == "R":
                self.river = {"width": float(f[1]), "pts": [tuple(float(v) for v in p.split(",")) for p in f[2].split(";")]}


def build(map_id, seed, faults=None):
    faults = faults or {}
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(TOOLS, "destruct_mocks.lua"), encoding="utf-8") as f:
        mock = lua.execute(f.read())
    sources = {}
    for name in REAL_MODULES + REAL_SHARED:
        if name == "MapTerrain":
            src = terrain_source(faults.get(name))
        else:
            src = apply(source_of(name), faults.get(name), name)
            if name == "MapDecor":
                src = apply(src, DECOR_PROBE, name)
        sources[name] = luau_to_lua(src)
    lua.globals().VEHICLE_SOURCE = luau_to_lua(vehicle_source(faults.get("VehicleService")))
    standins = lua.execute(STANDINS)
    lua.execute(WORLD, mock, lua.table_from(sources), standins)
    lua.execute("math.randomseed(...)", seed)
    started = time.time()
    run = lua.eval("""function(mapId)
        local MapGenerator = require("MapGenerator")
        local result = MapGenerator.Build(mapId)
        return result
    end""")
    result = run(map_id)
    seconds = time.time() - started
    lua.globals().d_kind = lua.eval("""function(car)
        if car.Name == "ParkedCar" then return "static" end
        return "drivable-" .. tostring(car:GetAttribute("HarnessKind"))
    end""")
    text = lua.execute(DUMP, result.map, result.roads, lua.eval("string.format"))
    attrs = {"radius": result.radius}
    for key in ("ThemesFailed", "WildsFailed", "WildsTrees"):
        value = result.map.GetAttribute(result.map, key)
        if value is not None:
            attrs[key] = value
    return Map(map_id, seed, text, seconds, attrs)


def map_ids():
    text = source_of("MapData")
    return re.search(r"MapData\.Order = \{ (.*?) \}", text).group(1).replace('"', "").replace(" ", "").split(",")


if __name__ == "__main__":
    m = build(sys.argv[1] if len(sys.argv) > 1 else "TralalaTown", int(sys.argv[2]) if len(sys.argv) > 2 else 1)
    print("%s seed %d: %.1fs, %d cars, %d parts, %d towns, %d bays, %d edges, attrs %s" % (
        m.map_id, m.seed, m.seconds, len(m.cars), len(m.parts), len(m.towns), len(m.bays), len(m.edges), m.attrs))
    for w in m.warnings:
        print("  warn:", w[:300])
