"""A whole generated map, built by the real MapGenerator.Build under LuaJIT, for the foundation checks.

    from foundation_world import World
    world = World()                      # one Lua state: mocks + voxel terrain + module loader
    world.build("SahurSprings", 101)      # math.randomseed(seed); MapGenerator.Build(mapId)
    world.lua.eval(...)                   # measure it

Real modules (their source, compound assignment and `continue` rewritten for plain Lua):
MapGenerator, MapTerrain, RoadNetwork, MapSpace, MapDecor, MapBuildings, TownKinds, TownThemes,
Landmarks, EasterEggs, MapWilds, ParkingLots, ZiplineService, and Shared MapData / BrainrotData.
Stubbed, because they build nothing a structure stands on or they are gameplay: VehicleService
(no cars: another worker owns them), VendorService (a stall model on the square), DestructibleService,
ZFight (the map-wide nudge pass; hundredths of a stud), HazardService (Barrel is copied from the real
one's size and pivot: 3.4 across, standing on its cframe), BrainrotModels / VehicleModels (a block of
the right footprint), MovementService, BattlePassService, RewardService, StateSync, Rarity, SafeValue,
Remotes.

`faults` is a list of (module name, old text, new text): the module's SOURCE is edited before it is
loaded, so a planted fault travels the same path as the real code.
"""

import os
import re
import subprocess
import sys

from lupa import luajit21

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
MODULES = os.path.join(ROOT, "ServerScriptService", "Modules")
SHARED = os.path.join(ROOT, "ReplicatedStorage", "Shared")

REAL_MODULES = [
    "MapGenerator", "MapTerrain", "RoadNetwork", "MapSpace", "MapDecor", "MapBuildings", "TownKinds",
    "TownThemes", "Landmarks", "EasterEggs", "MapWilds", "ParkingLots", "ZiplineService",
]
REAL_SHARED = ["MapData", "BrainrotData"]
STUB_MODULES = [
    "VehicleService", "VendorService", "DestructibleService", "HazardService", "MovementService",
    "BattlePassService", "RewardService", "StateSync", "Combatants", "CombatService",
]
STUB_SHARED = ["ZFight", "BrainrotModels", "VehicleModels", "Rarity", "SafeValue", "Remotes", "ItemModels", "ItemData"]

# A target is a name with any indexing: a.b, t[k], self.curveRefused[why or "node"].
TARGET = r"[A-Za-z_][\w.]*(?:\[[^\]=]*\][\w.]*)*"
COMPOUND = re.compile(r"^(\s*)(" + TARGET + r")\s*(\+|-|\*|/|%|\^|\.\.)=\s*(.+?)\s*$")
INLINE = re.compile(r"\b(" + TARGET + r") (\+|-|\*|/)= ([\w.]+)\b")
# `k:disc(...).CFrame *= CFrame.Angles(...)`: a property of a call's result.
CALL_COMPOUND = re.compile(r"^(\s*)(.*\)[\w.]*)\.(\w+)\s*(\+|-|\*|/)=\s*(.+?)\s*$")


def luau_to_lua(source):
    """Compound assignment and `continue` are the only Luau these files use that LuaJIT lacks."""
    lines = source.split("\n")
    out = []
    for line in lines:
        code, comment = line, ""
        cut = line.find("--")
        if cut >= 0 and line.count('"', 0, cut) % 2 == 0 and line.count("'", 0, cut) % 2 == 0:
            code, comment = line[:cut], line[cut:]
        m = COMPOUND.match(code)
        call = CALL_COMPOUND.match(code) if not m else None
        if m:
            indent, target, op, value = m.groups()
            code = "%s%s = %s %s (%s)" % (indent, target, target, op, value)
        elif call:
            indent, obj, prop, op, value = call.groups()
            code = "%sdo local __o = %s; __o.%s = __o.%s %s (%s) end" % (indent, obj, prop, prop, op, value)
        else:
            code = INLINE.sub(lambda m: "%s = %s %s %s" % (m.group(1), m.group(1), m.group(2), m.group(3)), code)
        out.append(code + comment)
    # `continue`: a goto to a label just before the enclosing loop's `end` (same indentation as the
    # loop's own line). Labels at the end of a block are legal after locals in LuaJIT.
    counter = 0
    i = 0
    while i < len(out):
        stripped = out[i].strip()
        if stripped == "continue" or re.match(r"^if .* then continue end$", stripped):
            counter += 1
            label = "continue_%d" % counter
            out[i] = out[i].replace("continue", "goto " + label)
            indent = len(out[i]) - len(out[i].lstrip("\t"))
            j = i - 1
            while j >= 0:
                s = out[j]
                ind = len(s) - len(s.lstrip("\t"))
                if ind < indent and re.match(r"^\s*(for|while)\b.*\bdo\s*(--.*)?$", s):
                    break
                j -= 1
            if j < 0:
                raise SystemExit("continue with no loop at line %d" % (i + 1))
            loop_indent = len(out[j]) - len(out[j].lstrip("\t"))
            k = i + 1
            while k < len(out):
                s = out[k]
                if s.strip() == "end" and len(s) - len(s.lstrip("\t")) == loop_indent:
                    break
                k += 1
            # Same line count: the label shares the `end` line.
            out[k] = "\t" * loop_indent + "::%s:: end" % label
        i += 1
    return "\n".join(out)


STUBS = r"""
local mock = ...
local M = mock.modules
local function blockModel(name, size, cf)
	local model = Instance.new("Model")
	model.Name = name
	local part = Instance.new("Part")
	part.Name = name .. "Body"
	part.Size = size
	part.CFrame = cf * CFrame.new(0, size.Y / 2, 0)
	part.Anchored = true
	part.Parent = model
	return model
end
local noop = setmetatable({}, { __index = function() return function() end end })
M.DestructibleService = noop
M.MovementService = noop
M.BattlePassService = noop
M.RewardService = noop
M.StateSync = noop
M.Combatants = noop
M.CombatService = noop
M.ItemModels = noop
M.ItemData = {}
M.VehicleService = { Create = function() end, ParkInTowns = function() return 0 end }
M.VendorService = { Build = function(parent, cf)
	local stall = blockModel("RotVendor", Vector3.new(6, 7, 4), cf)
	stall.Parent = parent
	return stall
end }
M.HazardService = { Barrel = function(parent, cf)
	local barrel = Instance.new("Model")
	barrel.Name = "ExplosiveBarrel"
	local body = Instance.new("Part")
	body.Name = "Barrel"
	body.Shape = Enum.PartType.Cylinder
	body.Size = Vector3.new(4.6, 3.4, 3.4)
	body.CFrame = cf * CFrame.new(0, 2.3, 0) * CFrame.Angles(0, 0, math.pi / 2)
	body.Anchored = true
	body.Parent = barrel
	barrel.Parent = parent
	return barrel
end }
M.ZFight = { Fix = function() return { moved = 0, remaining = {} } end }
M.BrainrotModels = {
	Metrics = function() return { bottom = 0, height = 4, width = 3, depth = 3 } end,
	Build = function(def, options)
		local scale = options and options.scale or 1
		return blockModel("Brainrot", Vector3.new(3, 4, 3) * scale, options and options.cframe or CFrame.new())
	end,
}
M.VehicleModels = {
	Pick = function() return "sedan" end,
	BuildStatic = function(id, rng, cf) return blockModel("Car", Vector3.new(7, 4, 13), cf or CFrame.new()) end,
}
M.Rarity = { Color = function() return Color3.new(1, 1, 1) end }
M.SafeValue = setmetatable({}, { __index = function() return function(v) return v end end })
M.Remotes = mock.RemotesModule
"""

LOADER = r"""
local mock, sources, modulesFolder, sharedFolder = ...
mock.modules = mock.modules or {}
local loading = {}
-- The modules see Roblox's `type`: a Vector3, CFrame, Color3, EnumItem or Instance is userdata there,
-- not a table (TownKinds' deep copy walks tables and would strip a Color3 of its methods). The
-- mocks themselves keep the plain one.
local rawtype = type
local moduleEnv = setmetatable({
	type = function(value)
		if rawtype(value) == "table" and (rawget(value, "__type") or rawget(value, "__instance")) then
			return "userdata"
		end
		return rawtype(value)
	end,
}, { __index = _G, __newindex = _G })
-- `pairs` in a fixed order. LuaJIT seeds its string hash per process, so plain pairs walks a table
-- in a different order every run and the same seed built a different map each time (a landmark
-- present in one run was missing in the next). Roblox's order is unspecified too; any fixed one will
-- do, and this makes a seed a map.
do
	local rank = { number = 1, string = 2, boolean = 3, table = 4 }
	local function keyOf(k)
		local t = rawtype(k)
		if t == "table" then
			local id = rawget(k, "__id")
			if id then return id end
			if rawget(k, "__type") == "EnumItem" then return rawget(k, "Name") end
			return tostring(k)
		end
		if t == "boolean" then return k and 1 or 0 end
		return k
	end
	local function before(a, b)
		local ta, tb = rank[rawtype(a)] or 5, rank[rawtype(b)] or 5
		if ta ~= tb then return ta < tb end
		local ka, kb = keyOf(a), keyOf(b)
		if rawtype(ka) ~= rawtype(kb) then return rawtype(ka) < rawtype(kb) end
		return ka < kb
	end
	rawset(moduleEnv, "pairs", function(t)
		local mt = getmetatable(t)
		if mt and mt.__pairs then return mt.__pairs(t) end
		local keys = {}
		for k in next, t do keys[#keys + 1] = k end
		if #keys > 1 then table.sort(keys, before) end
		local i = 0
		return function()
			i = i + 1
			local k = keys[i]
			if k == nil then return nil end
			return k, t[k]
		end, t, nil
	end)
	rawset(moduleEnv, "next", next)
end
-- A pcall in the map code (TownThemes, MapWilds, every FlattenPad) would swallow a gap in these
-- mocks and report it as the game refusing a site. Errors that name a missing method or a nil
-- global are recorded, and the check fails on any.
mock.mockGaps = {}
rawset(moduleEnv, "pcall", function(fn, ...)
	local trace = nil
	local results = { xpcall(fn, function(message)
		trace = debug.traceback(tostring(message), 2)
		return message
	end, ...) }
	if not results[1] then
		local message = tostring(results[2])
		if message:find("a nil value") or message:find("foundation mocks") then
			table.insert(mock.mockGaps, trace or message)
		end
	end
	return unpack(results, 1, table.maxn(results))
end)
require = function(inst)
	local name = type(inst) == "table" and inst.Name or tostring(inst)
	local found = mock.modules[name]
	if found ~= nil then return found end
	local source = sources[name]
	if not source then error("no module or stub for " .. tostring(name), 2) end
	if loading[name] then error("require cycle at " .. name, 2) end
	loading[name] = true
	local fn, err = loadstring("local script = ...; " .. source, "=" .. name)
	if not fn then error(err) end
	setfenv(fn, moduleEnv)
	local result = fn(inst)
	loading[name] = nil
	mock.modules[name] = result
	return result
end
"""


class World:
    def __init__(self, faults=(), ref=None):
        self.lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("table.unpack = table.unpack or unpack")
        with open(os.path.join(TOOLS, "destruct_mocks.lua"), encoding="utf-8") as f:
            self.mock = self.lua.execute(f.read())
        with open(os.path.join(TOOLS, "foundation_mocks.lua"), encoding="utf-8") as f:
            self.terrain = self.lua.execute(f.read(), self.mock)
        self.faults = list(faults)
        # `ref`: a git revision to read the game modules from instead of the working tree, so the
        # same measure can be run over the code as it was (the "before" numbers).
        self.ref = ref
        folders = self.lua.execute(
            r"""
local mock, real, realShared, stubs, stubShared = ...
local rs = game:GetService("ReplicatedStorage")
local shared = Instance.new("Folder"); shared.Name = "Shared"; shared.Parent = rs
local sss = game:GetService("ServerScriptService")
local modules = Instance.new("Folder"); modules.Name = "Modules"; modules.Parent = sss
for _, list in ipairs({ { real, modules }, { stubs, modules }, { realShared, shared }, { stubShared, shared } }) do
	for _, name in ipairs(list[1]) do
		local m = Instance.new("ModuleScript"); m.Name = name; m.Parent = list[2]
	end
end
return modules, shared
""",
            self.mock, self.lua.table(*REAL_MODULES), self.lua.table(*REAL_SHARED),
            self.lua.table(*STUB_MODULES), self.lua.table(*STUB_SHARED),
        )
        self.mock.modules = self.lua.table()
        self.lua.execute(STUBS, self.mock)
        sources = self.lua.table()
        for name in REAL_MODULES:
            sources[name] = self._source(os.path.join(MODULES, name + ".lua"), name)
        for name in REAL_SHARED:
            sources[name] = self._source(os.path.join(SHARED, name + ".lua"), name)
        self.lua.execute(LOADER, self.mock, sources, folders[0], folders[1])
        self.generator = self.lua.eval('require(game:GetService("ServerScriptService").Modules.MapGenerator)')

    def _source(self, path, name):
        if self.ref:
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            source = subprocess.run(["git", "-C", ROOT, "show", "%s:%s" % (self.ref, rel)], check=True,
                                    capture_output=True, text=True).stdout
        else:
            with open(path, encoding="utf-8") as f:
                source = f.read()
        for module, old, new in self.faults:
            if module == name:
                if old not in source:
                    raise SystemExit("planted fault did not apply to %s (text not found): %r" % (name, old[:80]))
                source = source.replace(old, new, 1)
        return luau_to_lua(source)

    def build(self, map_id, seed):
        return self.lua.execute(
            r"""
local generator, mapId, seed, T = ...
math.randomseed(seed)
-- LuaJIT's math.random(m, n) wants integers; Luau floors. Keep Luau's behaviour.
local raw = math.random
math.random = function(a, b)
	if a == nil then return raw() end
	if b == nil then return raw(math.floor(a)) end
	return raw(math.floor(a), math.floor(b))
end
local old = workspace:FindFirstChild("Map")
if old then old:Destroy() end
T.clear()
local ok, result = xpcall(function() return generator.Build(mapId) end, debug.traceback)
math.random = raw
if not ok then error(result, 0) end
return result
""",
            self.generator, map_id, seed, self.terrain,
        )
