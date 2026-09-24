"""B7: the showcase podiums against the REAL lobby, without Studio.

Builds the lobby by running the real LobbyService.Build (and the real CloudClimbCourse it reads)
under lupa with a small Roblox mock, and reads back every anchored, visible or solid part that
stands proud of the plaza's paving and below the podium's top: the arena's terrace and ramps, the
pitch's turf, goal and floodlights, the statue, the tree and its roots, the lamp posts, the stalls,
the boards, the Walk of Fame, the pier's arch. (Modules that only dress a piece -- the statue's
figure, the practice dummies, the crate on the altar -- are stubbed; each stands on a plinth, terrace
or altar that is counted.) Then it runs the real ShowcaseService.Refresh for
every player count from 1 to 50 (players joining one at a time, then leaving in a shuffled order)
and checks, after every Refresh:

  1. Every podium's footprint (the halo round its foot, POD_RADIUS) clears every lobby part and the
     walkways by CLEARANCE in plan, stays on the plaza, and stands on the plaza's floor.
  2. No two podiums' footprints come within SPACING of each other.
  3. At most ShowcaseService.MAX_PODIUMS are shown, and never fewer than min(players, cap).
  4. Refresh is incremental: a player whose podium is already standing keeps the SAME instance at
     the SAME place through anybody else joining or leaving; a player's podium is rebuilt only
     when what it shows changes.

Planted faults (each must fail, run every time), edited into the ShowcaseService SOURCE (PLANTS):
the old r44 ring round the whole plaza, a slot on the pitch and the foot a stud under the plaza (1),
no cap (2), and a Refresh that rebuilds everything or leaves an old display behind (4).

Usage: python3 tools/showcase_layout_check.py [repo_root]  (exit 1 on any failure)
"""
import math
import random
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parent))
from car_placement_luau import luau_to_lua  # noqa: E402

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
MODULES = ROOT / "ServerScriptService/Modules"

# The podium's footprint: the halo on the floor round its foot is 16 across (ShowcaseService's
# "Halo"); nothing else on it reaches further out.
POD_RADIUS = 8.0
# Walking room kept between a podium's halo and anything else, and between two halos (the numbers
# ShowcaseService's SLOTS comment promises).
CLEARANCE = 2.0
SPACING = 4.0
# The band a podium occupies: from the paving (0.17 over the plaza's centre height) to the top
# of its nameplate (13 over the foot). Parts wholly outside it do not get in its way.
BAND_LOW, BAND_HIGH = 0.2, 14.0
PLAZA_RADIUS = float(re.search(r"local PLAZA_RADIUS = ([\d.]+)",
                               (MODULES / "LobbyService.lua").read_text(encoding="utf-8")).group(1))

MOCK = r"""
table.create = table.create or function() return {} end
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
table.find = table.find or function(t, v) for i, x in ipairs(t) do if x == v then return i end end end
math.clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
math.sign = function(v) return v > 0 and 1 or (v < 0 and -1 or 0) end
math.round = function(v) return math.floor(v + 0.5) end

-- Anything the lobby touches that has no bearing on where its parts stand: every index and call
-- returns it again.
local Stub = {}
STUB = setmetatable({}, Stub)
-- (Not for integer keys, so ipairs over it ends at once.)
Stub.__index = function(_, k) if type(k) == "number" then return nil end; return STUB end
Stub.__call = function() return STUB end
Stub.__len = function() return 0 end
Stub.__newindex = function() end

local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3) end
V3 = {}
V3.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); if m == 0 then return vec(0, 0, 0) end; return vec(v.X / m, v.Y / m, v.Z / m) end
	return V3[k]
end
V3.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
V3.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then return vec(a.X / b, a.Y / b, a.Z / b) end
	return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V3.__tostring = function(v) return string.format("%.3f, %.3f, %.3f", v.X, v.Y, v.Z) end
function V3.Cross(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
function V3.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function V3.Lerp(a, b, t) return a + (b - a) * t end
function V3.Min(a, b) return vec(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z)) end
function V3.Max(a, b) return vec(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z)) end
function V3.Abs(a) return vec(math.abs(a.X), math.abs(a.Y), math.abs(a.Z)) end
function V3.FuzzyEq(a, b, e) return (a - b).Magnitude <= (e or 1e-5) end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
Vector3.zero, Vector3.one = vec(0, 0, 0), vec(1, 1, 1)
Vector3.xAxis, Vector3.yAxis, Vector3.zAxis = vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1)
Vector2 = { new = function(x, y) return { X = x or 0, Y = y or 0 } end }
Vector2.zero = Vector2.new(0, 0)

-- A CFrame is a position and three columns: right (X), up (Y), back (Z = -look).
CF = {}
local function cf(p, r, u, b) return setmetatable({ p = p, r = r, u = u, b = b }, CF) end
local function rot(c, v) return c.r * v.X + c.u * v.Y + c.b * v.Z end
CF.__index = function(c, k)
	if k == "Position" then return c.p end
	if k == "RightVector" or k == "XVector" then return c.r end
	if k == "UpVector" or k == "YVector" then return c.u end
	if k == "ZVector" then return c.b end
	if k == "LookVector" then return -c.b end
	if k == "Rotation" then return cf(Vector3.zero, c.r, c.u, c.b) end
	if k == "X" then return c.p.X end
	if k == "Y" then return c.p.Y end
	if k == "Z" then return c.p.Z end
	return CF[k]
end
CF.__mul = function(a, b)
	if getmetatable(b) == V3 then return a.p + rot(a, b) end
	return cf(a.p + rot(a, b.p), rot(a, b.r), rot(a, b.u), rot(a, b.b))
end
CF.__add = function(a, v) return cf(a.p + v, a.r, a.u, a.b) end
CF.__sub = function(a, v) return cf(a.p - v, a.r, a.u, a.b) end
function CF.Inverse(c)
	local t = cf(Vector3.zero, vec(c.r.X, c.u.X, c.b.X), vec(c.r.Y, c.u.Y, c.b.Y), vec(c.r.Z, c.u.Z, c.b.Z))
	t.p = -rot(t, c.p)
	return t
end
function CF.ToObjectSpace(a, b) return a:Inverse() * b end
function CF.ToWorldSpace(a, b) return a * b end
function CF.PointToWorldSpace(a, v) return a * v end
function CF.PointToObjectSpace(a, v) return a:Inverse() * v end
function CF.VectorToWorldSpace(a, v) return rot(a, v) end
function CF.VectorToObjectSpace(a, v) return rot(a:Inverse(), v) end
function CF.Lerp(a, b, t) return cf(a.p:Lerp(b.p, t), a.r, a.u, a.b) end
local X, Y, Z = vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1)
CFrame = {}
function CFrame.new(x, y, z, ...)
	if type(x) == "table" then
		if y then return CFrame.lookAt(x, y) end
		return cf(x, X, Y, Z)
	end
	return cf(vec(x or 0, y or 0, z or 0), X, Y, Z)
end
CFrame.identity = CFrame.new()
function CFrame.fromMatrix(p, r, u, b) return cf(p, r, u, b or r:Cross(u)) end
local function rx(a) local c, s = math.cos(a), math.sin(a); return cf(Vector3.zero, X, vec(0, c, s), vec(0, -s, c)) end
local function ry(a) local c, s = math.cos(a), math.sin(a); return cf(Vector3.zero, vec(c, 0, -s), Y, vec(s, 0, c)) end
local function rz(a) local c, s = math.cos(a), math.sin(a); return cf(Vector3.zero, vec(c, s, 0), vec(-s, c, 0), Z) end
function CFrame.Angles(x, y, z) return rx(x or 0) * ry(y or 0) * rz(z or 0) end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
function CFrame.fromEulerAnglesYXZ(x, y, z) return ry(y or 0) * rx(x or 0) * rz(z or 0) end
CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ
function CFrame.fromAxisAngle(axis, a)
	axis = axis.Unit
	local function r(v) return v * math.cos(a) + axis:Cross(v) * math.sin(a) + axis * axis:Dot(v) * (1 - math.cos(a)) end
	return cf(Vector3.zero, r(X), r(Y), r(Z))
end
function CFrame.lookAt(at, target, up)
	local look = (target - at).Unit
	up = up or Y
	local right = look:Cross(up)
	if right.Magnitude < 1e-6 then right = look:Cross(Z) end
	right = right.Unit
	return cf(at, right, right:Cross(look), -look)
end

-- Random: a seeded LCG, so the tree's dressing lands the same way every run.
Random = {}
function Random.new(seed)
	local state = math.floor(math.abs(seed or 1)) % 2147483647 + 1
	local r = {}
	local function next01() state = (state * 48271) % 2147483647; return state / 2147483647 end
	function r.NextNumber(_, a, b) a, b = a or 0, b or 1; return a + (b - a) * next01() end
	function r.NextInteger(_, a, b) return a + math.floor(next01() * (b - a + 1)) end
	function r.NextUnitVector() return Vector3.new(next01() - 0.5, next01() - 0.5, next01() - 0.5).Unit end
	return r
end

Color3 = {}
local C3 = { __index = function(c, k) if k == "Lerp" then return function(a) return a end end; if k == "ToHSV" then return function() return 0, 0, 0 end end end }
function Color3.new(r, g, b) return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3) end
function Color3.fromRGB(r, g, b) return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end
Color3.fromHSV = Color3.new
Color3.fromHex = function() return Color3.new() end
for _, name in ipairs({ "UDim2", "UDim", "NumberSequence", "ColorSequence", "NumberRange", "PhysicalProperties",
	"NumberSequenceKeypoint", "ColorSequenceKeypoint", "TweenInfo", "Rect", "Ray", "RaycastParams", "OverlapParams", "BrickColor", "Font" }) do
	_G[name] = STUB
end
local function enumOf(path)
	return setmetatable({ Name = path:match("[^.]+$") }, { __index = function(t, k)
		local e = enumOf(path .. "." .. k); rawset(t, k, e); return e
	end, __tostring = function() return path end })
end
Enum = enumOf("Enum")

function typeof(v)
	local mt = getmetatable(v)
	if mt == V3 then return "Vector3" elseif mt == CF then return "CFrame" elseif mt == C3 then return "Color3" end
	if type(v) == "table" and rawget(v, "kids") then return "Instance" end
	return type(v)
end

-- Instances: properties, Parent, children, attributes. Anything else (signals, methods the lobby
-- calls for effects) is the stub.
local Inst = {}
local PARTS = { Part = true, WedgePart = true, MeshPart = true, Seat = true, TrussPart = true, CornerWedgePart = true, SpawnLocation = true }
local CONTAINERS = { Model = true, Folder = true }
Inst.__index = function(i, k)
	local props = rawget(i, "props")
	if k == "Position" and props.CFrame then return props.CFrame.p end
	if k == "Orientation" then return Vector3.zero end
	local m = Inst[k]; if m then return m end
	local v = props[k]
	if v ~= nil then return v end
	if k == "Parent" or k == "Adornee" or k == "PrimaryPart" or k == "Part0" or k == "Part1" or k == "Attachment0" or k == "Attachment1" then return nil end
	-- Anything else unset: a signal, or a property the lobby only writes.
	return STUB
end
Inst.__newindex = function(i, k, v)
	local props = rawget(i, "props")
	if k == "Parent" then
		local old = props.Parent
		if old then
			local kids = rawget(old, "kids")
			for n = #kids, 1, -1 do if kids[n] == i then table.remove(kids, n) end end
		end
		if v then table.insert(rawget(v, "kids"), i) end
	elseif k == "Position" then
		local c = props.CFrame or CFrame.new()
		props.CFrame = cf(v, c.r, c.u, c.b); return
	end
	props[k] = v
end
Inst.__tostring = function(i) return rawget(i, "props").Name or "?" end
function Inst.IsA(i, c)
	if c == "BasePart" then return PARTS[i.ClassName] == true end
	if c == "PVInstance" then return PARTS[i.ClassName] == true or i.ClassName == "Model" end
	if c == "Instance" then return true end
	return i.ClassName == c
end
function Inst.GetChildren(i) local t = {}; for n, k in ipairs(rawget(i, "kids")) do t[n] = k end; return t end
function Inst.GetDescendants(i)
	local out = {}
	local function walk(x) for _, k in ipairs(rawget(x, "kids")) do out[#out + 1] = k; walk(k) end end
	walk(i)
	return out
end
function Inst.FindFirstChild(i, name, deep)
	for _, k in ipairs(rawget(i, "kids")) do if k.Name == name then return k end end
	if deep then for _, k in ipairs(rawget(i, "kids")) do local f = k:FindFirstChild(name, true); if f then return f end end end
end
function Inst.WaitForChild(i, name) return i:FindFirstChild(name) or STUB end
function Inst.FindFirstChildOfClass(i, c) for _, k in ipairs(rawget(i, "kids")) do if k.ClassName == c then return k end end end
function Inst.FindFirstChildWhichIsA(i, c) for _, k in ipairs(rawget(i, "kids")) do if k:IsA(c) then return k end end end
function Inst.FindFirstAncestorOfClass(i, c) local p = i.Parent; while p do if p.ClassName == c then return p end; p = p.Parent end end
function Inst.FindFirstAncestor(i, n) local p = i.Parent; while p do if p.Name == n then return p end; p = p.Parent end end
function Inst.IsDescendantOf(i, a) local p = i.Parent; while p do if p == a then return true end; p = p.Parent end; return false end
function Inst.GetFullName(i) return i.Name end
function Inst.Destroy(i) i.Parent = nil; rawget(i, "props").destroyed = true end
function Inst.ClearAllChildren(i) for _, k in ipairs(i:GetChildren()) do k:Destroy() end end
function Inst.Clone(i)
	local c = Instance.new(i.ClassName)
	for k, v in pairs(rawget(i, "props")) do if k ~= "Parent" then rawget(c, "props")[k] = v end end
	for k, v in pairs(rawget(i, "attrs")) do rawget(c, "attrs")[k] = v end
	for _, kid in ipairs(i:GetChildren()) do kid:Clone().Parent = c end
	return c
end
function Inst.SetAttribute(i, k, v) rawget(i, "attrs")[k] = v end
function Inst.GetAttribute(i, k) return rawget(i, "attrs")[k] end
function Inst.GetAttributes(i) local t = {}; for k, v in pairs(rawget(i, "attrs")) do t[k] = v end; return t end
function Inst.GetPivot(i)
	if i.PrimaryPart then return i.PrimaryPart.CFrame end
	return rawget(i, "props").CFrame or CFrame.new()
end
function Inst.PivotTo(i, target)
	local from = i:GetPivot()
	local delta = target * from:Inverse()
	if PARTS[i.ClassName] then i.CFrame = target end
	for _, d in ipairs(i:GetDescendants()) do
		if PARTS[d.ClassName] and d.CFrame then d.CFrame = delta * d.CFrame end
	end
end
function Inst.GetBoundingBox(i) return i:GetPivot(), Vector3.new(1, 1, 1) end
function Inst.ScaleTo() end
function Inst.GetScale() return 1 end
function Inst.GetPropertyChangedSignal() return STUB end
function Inst.GetAttributeChangedSignal() return STUB end
function Inst.AddTag() end
function Inst.HasTag() return false end
-- `id` tells one instance from another across Refreshes.
local nextId = 0
Instance = { new = function(c, parent)
	nextId = nextId + 1
	local i = setmetatable({ props = { ClassName = c, Name = c, Transparency = 0, Anchored = false, CanCollide = true,
		Size = Vector3.new(4, 1, 2), Shape = Enum.PartType.Block }, kids = {}, attrs = {}, id = nextId }, Inst)
	if parent then i.Parent = parent end
	return i
end }

workspace = Instance.new("Workspace")
workspace.Name = "Workspace"
PLAYERS = {}
local services = {}
local function service(name)
	if services[name] then return services[name] end
	local s = setmetatable({}, { __index = function() return STUB end })
	services[name] = s
	return s
end
service("Players").GetPlayers = function() local t = {}; for n, p in ipairs(PLAYERS) do t[n] = p end; return t end
service("Players").GetPlayerFromCharacter = function() return nil end
service("Players").LocalPlayer = nil
local sharedFolder = setmetatable({}, { __index = function() return STUB end })
sharedFolder.WaitForChild = function(_, name) return "Shared/" .. name end
sharedFolder.FindFirstChild = sharedFolder.WaitForChild
service("ReplicatedStorage").WaitForChild = function() return sharedFolder end
service("ReplicatedStorage").FindFirstChild = service("ReplicatedStorage").WaitForChild
service("RunService").IsStudio = function() return false end
service("RunService").IsServer = function() return true end
service("RunService").IsClient = function() return false end
game = { GetService = function(_, name) return service(name) end, Workspace = workspace, PlaceId = 0, JobId = "" }
setmetatable(game, { __index = function() return STUB end })
task = { spawn = function() end, defer = function() end, delay = function() end, wait = function() return 0 end, cancel = function() end }
wait, spawn, delay = task.wait, task.spawn, task.delay
tick, time = function() return 0 end, function() return 0 end
os.clock = function() return 0 end
warn = function() end

-- script.Parent:WaitForChild("X") / Shared:WaitForChild("X") hand back a name that require()
-- looks up.
MODULES = {}
local scriptParent = { WaitForChild = function(_, name) return name end, FindFirstChild = function(_, name) return name end }
script = setmetatable({ Parent = scriptParent }, { __index = function() return STUB end })
-- Modules whose answers decide whether a piece is built at all get a real, empty answer: the
-- statue's figure stands on its plinth, which is built either way.
local function stubModule(fields)
	return setmetatable(fields, { __index = function() return STUB end })
end
MODULES.BrainrotData = stubModule({ Get = function() return nil end, Types = {} })
function require(name)
	if type(name) == "string" then name = name:gsub("^Shared/", "") end
	local m = MODULES[name]
	if m == nil then return STUB end
	return m
end
"""

SHARED = ROOT / "ReplicatedStorage/Shared"


def read(path):
    return path.read_text(encoding="utf-8")


# Places the podiums must leave room round, that no part marks: the walk in from the pier to the
# statue (the pier arch's columns stand at x = +-12) and the run-up to the arena's two ramps (their
# feet are at x = 34, z = +-12, and they are 8 wide). (x0, z0, x1, z1), relative to the plaza centre.
KEEP_CLEAR = {
    "the walk from the pier": (-12, 37, 12, 100),
    "the run-up to the arena ramps": (22, -16, 34, 16),
}

# Every part of the built lobby, one line each (lupa's per-element access is slow), relative to the
# plaza centre: group, name, shape, anchored, cancollide, transparency, collision group, size, frame.
DUMP_LOBBY = r"""
function(LobbyService, base)
	local lobby = Instance.new("Model")
	lobby.Name = "Lobby"
	lobby.Parent = workspace
	LobbyService.Build(lobby, base)
	local out = {}
	for _, p in ipairs(lobby:GetDescendants()) do
		if p:IsA("BasePart") and p.CFrame then
			local group, node = nil, p
			while node and node ~= lobby and not group do
				group = node:GetAttribute("Group")
				node = node.Parent
			end
			local c, s = p.CFrame, p.Size
			local o = c.p - base
			out[#out + 1] = table.concat({ group or "?", p.Name, tostring(p.Shape), tostring(p.Anchored), tostring(p.CanCollide),
				string.format("%.4f", p.Transparency), tostring(rawget(p, "props").CollisionGroup or "Default"),
				string.format("%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f",
					s.X, s.Y, s.Z, o.X, o.Y, o.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z) }, "|")
		end
	end
	return table.concat(out, "\n")
end
"""


def hull(points):
    pts = sorted(set((round(x, 4), round(z, 4)) for x, z in points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def lobby_obstacles():
    """The real lobby's footprint on the plaza: [(label, "circle", (x, z, r)) | (label, "poly", points)]."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    modules = lua.globals().MODULES
    for name in ("Rarity", "CrateData", "DailySpinData", "MatchConfig", "CosmeticData"):
        modules[name] = lua.execute(luau_to_lua(read(SHARED / f"{name}.lua")))
    modules["CloudClimbCourse"] = lua.execute(luau_to_lua(read(MODULES / "CloudClimbCourse.lua")))
    lobby_service = lua.execute(luau_to_lua(read(MODULES / "LobbyService.lua")))
    base = modules["MatchConfig"].LobbyPosition
    wall_group = re.search(r'local WALL_GROUP = "(\w+)"', read(MODULES / "LobbyService.lua")).group(1)
    obstacles, counted = [], 0
    for row in lua.eval(DUMP_LOBBY)(lobby_service, base).split("\n"):
        group, name, shape, anchored, collide, transparency, collision, nums = row.split("|")
        sx, sy, sz, px, py, pz, rx, ry, rz, ux, uy, uz, bx, by, bz = map(float, nums.split())
        counted += 1
        # Loose play balls roll about; the balls' walls are walked through; an invisible part nobody
        # bumps into (a trigger zone) is not in the way.
        if anchored != "true" or collision == wall_group or (float(transparency) >= 0.98 and collide != "true"):
            continue
        corners = [(px + rx * sx / 2 * a + ux * sy / 2 * b + bx * sz / 2 * c,
                    py + ry * sx / 2 * a + uy * sy / 2 * b + by * sz / 2 * c,
                    pz + rz * sx / 2 * a + uz * sy / 2 * b + bz * sz / 2 * c)
                   for a in (-1, 1) for b in (-1, 1) for c in (-1, 1)]
        low, high = min(c[1] for c in corners), max(c[1] for c in corners)
        upright = "Cylinder" in shape and abs(ry) > 0.999
        # The paving: the plaza's stack of discs round the centre, which everything stands on.
        if upright and group == "Island" and math.hypot(px, pz) < 1 and high <= 0.3:
            continue
        if high <= BAND_LOW or low >= BAND_HIGH:
            continue
        label = f"{group}:{name}"
        if upright:
            obstacles.append((label, "circle", (px, pz, min(sy, sz) / 2)))
        elif "Ball" in shape:
            obstacles.append((label, "circle", (px, pz, min(sx, sy, sz) / 2)))
        else:
            obstacles.append((label, "poly", hull([(c[0], c[2]) for c in corners])))
    for label, (x0, z0, x1, z1) in KEEP_CLEAR.items():
        obstacles.append((label, "poly", [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]))
    return obstacles, counted


def distance(obstacle, x, z):
    """Plan distance from (x, z) to an obstacle's footprint; negative inside it."""
    _, kind, shape = obstacle
    if kind == "circle":
        cx, cz, r = shape
        return math.hypot(x - cx, z - cz) - r
    inside, best = True, math.inf
    for i, (ax, az) in enumerate(shape):
        bx, bz = shape[(i + 1) % len(shape)]
        if (bx - ax) * (z - az) - (bz - az) * (x - ax) < 0:
            inside = False
        dx, dz = bx - ax, bz - az
        length = dx * dx + dz * dz
        t = 0 if length == 0 else max(0.0, min(1.0, ((x - ax) * dx + (z - az) * dz) / length))
        best = min(best, math.hypot(x - ax - t * dx, z - az - t * dz))
    return -best if inside else best


# The real ShowcaseService with its neighbours stood in for: players are tables, PlayerData hands back
# what the driver says, and a brainrot model is one part.
SHOWCASE_HARNESS = r"""
local src = ...
local base = MODULES.MatchConfig.LobbyPosition
local defs, data = {}, {}
for _, rarity in ipairs({ "Common", "Rare", "Epic", "Legendary", "Mythic" }) do
	defs[rarity .. "Rot"] = { name = rarity .. "Rot", rarity = rarity, coinValue = 10 }
end
MODULES.BrainrotData = {
	Get = function(name) return defs[name] end,
	LevelForXp = function(xp) return 1 + math.floor(xp / 100) end,
	StarText = function(stars) return string.rep("*", stars) end,
	Stats = function() return { move = "Bite", damage = 10 } end,
}
MODULES.BrainrotModels = { Build = function()
	local model = Instance.new("Model")
	Instance.new("Part").Parent = model
	return model
end }
MODULES.ZFight = { Fix = function() return { moved = 0, remaining = {} } end }
MODULES.PlayerData = { Get = function(player) return data[player.UserId] end }
local Showcase = assert(load(src, "=ShowcaseService"))()
Showcase.Start()
local api = {}
function api.join(uid, showcase)
	table.insert(PLAYERS, { UserId = uid, DisplayName = "P" .. uid, Name = "P" .. uid })
	data[uid] = { Showcase = showcase, CompanionXp = {}, Stars = {} }
end
function api.leave(uid)
	for i, p in ipairs(PLAYERS) do
		if p.UserId == uid then
			table.remove(PLAYERS, i)
			data[uid] = nil
			return
		end
	end
end
function api.set(uid, showcase) data[uid].Showcase = showcase end
function api.refresh() Showcase.Refresh() end
-- "name id x y z" for everything in the folder, relative to the plaza centre.
function api.snapshot()
	local folder = workspace:FindFirstChild("Showcase")
	local out = {}
	for _, c in ipairs(folder and folder:GetChildren() or {}) do
		local p = c.CFrame.p
		out[#out + 1] = string.format("%s %d %.3f %.3f %.3f", c.Name, c.id, p.X - base.X, p.Y - base.Y, p.Z - base.Z)
	end
	return table.concat(out, "\n")
end
function api.maxPodiums() return Showcase.MAX_PODIUMS end
return api
"""

RARITIES = ["CommonRot", "RareRot", "EpicRot", "LegendaryRot", "MythicRot"]


def showcase_api(source):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCK)
    modules = lua.globals().MODULES
    for name in ("Rarity", "MatchConfig"):
        modules[name] = lua.execute(luau_to_lua(read(SHARED / f"{name}.lua")))
    return lua.execute(SHOWCASE_HARNESS, luau_to_lua(source))


def snapshot(api):
    """({uid: (instance id, x, foot y, z)}, [(x, z) of each display]) for what the folder holds."""
    podiums, displays = {}, []
    for line in filter(None, api.snapshot().split("\n")):
        name, ident, x, y, z = line.split()
        if name.startswith("Podium_"):
            # The podium's centre is PODIUM_HEIGHT / 2 over its foot.
            podiums[int(name[len("Podium_"):])] = (int(ident), float(x), float(y), float(z))
        elif name == "Display":
            displays.append((float(x), float(z)))
    return podiums, displays


def check(source, obstacles):
    """Drives the real Refresh through 1..50 players and back; returns (problems, stats)."""
    api = showcase_api(source)
    cap = api.maxPodiums()
    height = float(re.search(r"local PODIUM_HEIGHT = ([\d.]+)", source).group(1))
    problems, stats = [], {"refreshes": 0, "placements": 0, "closest": math.inf, "tightest": math.inf, "spots": set()}
    clearance_at, showcases, previous = {}, {}, {}

    def clearance(x, z):
        key = (round(x, 2), round(z, 2))
        if key not in clearance_at:
            near = min(obstacles, key=lambda o: distance(o, x, z))
            clearance_at[key] = (distance(near, x, z) - POD_RADIUS, near[0])
        return clearance_at[key]

    def step(what, changed=()):
        nonlocal previous
        api.refresh()
        stats["refreshes"] += 1
        podiums, displays = snapshot(api)
        n = len(showcases)
        where = f"{what} ({n} players)"
        want = min(n, int(cap)) if cap is not None else n
        if len(podiums) != want or not set(podiums) <= set(showcases):
            problems.append(f"3: {where}: {len(podiums)} podiums shown, want {want} (cap {cap})")
        for uid, (_, x, y, z) in podiums.items():
            stats["placements"] += 1
            stats["spots"].add((round(x, 1), round(z, 1)))
            gap, nearest = clearance(x, z)
            stats["closest"] = min(stats["closest"], gap)
            if gap < CLEARANCE:
                problems.append(f"1: {where}: P{uid}'s podium at ({x:.1f}, {z:.1f}) is {gap:.1f} from {nearest} (want {CLEARANCE})")
            if math.hypot(x, z) + POD_RADIUS > PLAZA_RADIUS:
                problems.append(f"1: {where}: P{uid}'s podium at ({x:.1f}, {z:.1f}) runs off the plaza")
            if abs(y - height / 2) > 0.01:
                problems.append(f"1: {where}: P{uid}'s podium's foot is {y - height / 2:+.2f} off the plaza (its halo is under the paving)")
        items = sorted(podiums.items())
        for i, (a, pa) in enumerate(items):
            for b, pb in items[i + 1:]:
                gap = math.hypot(pa[1] - pb[1], pa[3] - pb[3]) - 2 * POD_RADIUS
                stats["tightest"] = min(stats["tightest"], gap)
                if gap < SPACING:
                    problems.append(f"2: {where}: P{a}'s and P{b}'s podiums are {gap:.1f} apart (want {SPACING})")
        spots = {(round(p[1], 2), round(p[3], 2)) for uid, p in podiums.items() if showcases.get(uid)}
        shown = sum(1 for uid in podiums if showcases.get(uid))
        if len(displays) != shown or any((round(x, 2), round(z, 2)) not in spots for x, z in displays):
            problems.append(f"4: {where}: {len(displays)} displays for {shown} showcased podiums, or one off its podium")
        for uid, (ident, x, _, z) in podiums.items():
            if uid not in previous:
                continue
            old = previous[uid]
            if (old[1], old[3]) != (x, z):
                problems.append(f"4: {where}: P{uid}'s podium moved from ({old[1]:.1f}, {old[3]:.1f}) to ({x:.1f}, {z:.1f})")
            elif uid in changed and old[0] == ident:
                problems.append(f"4: {where}: P{uid} changed what they showcase and the podium was not rebuilt")
            elif uid not in changed and old[0] != ident:
                problems.append(f"4: {where}: P{uid}'s podium was rebuilt though nothing about it changed")
        previous = podiums

    order = list(range(1, 51))
    for uid in order:
        showcases[uid] = None if uid % 3 == 0 else RARITIES[uid % len(RARITIES)]
        api.join(uid, showcases[uid])
        step(f"P{uid} joins")
        if uid in (3, 20):
            step("a refresh with nothing changed (a match end)")
        if uid == 20:
            showcases[5] = "MythicRot"
            api.set(5, "MythicRot")
            step("P5 showcases another brainrot", changed=(5,))
            showcases[4] = None
            api.set(4, None)
            step("P4 clears their showcase", changed=(4,))
    random.Random(7).shuffle(order)
    for uid in order:
        del showcases[uid]
        api.leave(uid)
        step(f"P{uid} leaves")
    return problems, stats


PLANTS = [
    # (what, the invariant that must trip, text in ShowcaseService.lua, what it becomes)
    ("the old ring: every slot on r44 round the whole plaza", "1",
     "local angle = math.rad(slot[1])\n\treturn MatchConfig.LobbyPosition + Vector3.new(math.cos(angle) * slot[2], 0, math.sin(angle) * slot[2])",
     "local angle = index / #SLOTS * math.pi * 2\n\treturn MatchConfig.LobbyPosition + Vector3.new(math.cos(angle) * 44, 0, math.sin(angle) * 44)"),
    ("a slot on the pitch", "1", "{ 204.0, 90 }", "{ 180.0, 70 }"),
    ("the podium's foot a stud under the plaza again", "1",
     "return MatchConfig.LobbyPosition + Vector3.new(", "return MatchConfig.LobbyPosition - Vector3.new(0, 1, 0) + Vector3.new("),
    ("no cap: past the last slot, round again", "2",
     "if not slot then\n\t\treturn nil\n\tend", "if not slot then\n\t\tslot = SLOTS[(index - 1) % #SLOTS + 1]\n\tend"),
    ("every Refresh rebuilds every podium", "4",
     "local parent = ensureContainer()\n", "local parent = ensureContainer()\n\tparent:ClearAllChildren()\n\tpodiums = {}\n"),
    ("a rebuild leaves the old display turning", "4",
     "\tif entry.display then\n\t\tentry.display:Destroy()\n\tend\n", ""),
]


def main():
    source = read(MODULES / "ShowcaseService.lua")
    obstacles, counted = lobby_obstacles()
    print(f"showcase_layout_check: built the real lobby, {counted} parts; {len(obstacles) - len(KEEP_CLEAR)} stand in a "
          f"podium's way ({BAND_LOW}..{BAND_HIGH} over the plaza), plus {len(KEEP_CLEAR)} walkways")
    problems, stats = check(source, obstacles)
    for p in problems[:40]:
        print("FAIL", p)
    if len(problems) > 40:
        print(f"FAIL ... and {len(problems) - 40} more")
    print(f"showcase_layout_check: {stats['refreshes']} refreshes, {stats['placements']} podium placements on "
          f"{len(stats['spots'])} spots; closest to the lobby {stats['closest']:.2f}, tightest pair {stats['tightest']:.2f} "
          f"(want >= {CLEARANCE} and {SPACING})")
    caught = 0
    for what, code, old, new in PLANTS:
        if source.count(old) != 1:
            print(f"PLANT {what}: the text to break is not in ShowcaseService.lua (once) any more")
            continue
        try:
            planted, _ = check(source.replace(old, new, 1), obstacles)
        except Exception as err:  # a plant that breaks the run is caught too
            planted = [f"{code}: run failed: {str(err)[:200]}"]
        hit = [p for p in planted if p.startswith(code + ":")]
        caught += bool(hit)
        print(f"{'CAUGHT' if hit else 'MISSED'} plant: {what}" + (f" -- {hit[0]}" if hit else ""))
    print(f"showcase_layout_check: {len(problems)} problem(s), planted faults caught {caught} of {len(PLANTS)}")
    return 1 if problems or caught != len(PLANTS) else 0


if __name__ == "__main__":
    sys.exit(main())
