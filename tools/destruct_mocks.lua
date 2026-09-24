-- Just enough of Roblox to run DestructibleService, BreakFxClient, MapWilds and MapDecor under plain
-- Lua (lupa), for tools/destruct_map_check.py. Values, not rendering: CFrames are real rotation
-- matrices, Instances keep their tree, attributes and Destroying signal, and time only moves when
-- the harness calls __advance(dt).

local mock = {}

-- Vector3 -------------------------------------------------------------------------------------
local V = {}
V.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		return Vector3.new(v.X / m, v.Y / m, v.Z / m)
	end
	return V[key]
end
local function vec(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __type = "Vector3" }, V)
end
V.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
V.__mul = function(a, b)
	if type(a) == "number" then return vec(a * b.X, a * b.Y, a * b.Z) end
	if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b)
	if type(b) == "number" then return vec(a.X / b, a.Y / b, a.Z / b) end
	return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function V.Cross(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
function V.Lerp(a, b, t) return a + (b - a) * t end
function V.Abs(a) return vec(math.abs(a.X), math.abs(a.Y), math.abs(a.Z)) end
function V.Min(a, b) return vec(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z)) end
function V.Max(a, b) return vec(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z)) end
Vector3 = { new = vec, zero = vec(0, 0, 0), one = vec(1, 1, 1), xAxis = vec(1, 0, 0), yAxis = vec(0, 1, 0), zAxis = vec(0, 0, 1) }
Vector2 = { new = function(x, y) return { X = x or 0, Y = y or 0, __type = "Vector2" } end }

-- CFrame: position p and rotation columns r (right), u (up), b (back) ------------------------
local C = {}
local function cf(p, r, u, b)
	return setmetatable({ p = p, r = r, u = u, b = b, __type = "CFrame" }, C)
end
local function rot(c, v) return c.r * v.X + c.u * v.Y + c.b * v.Z end
local function unrot(c, v) return vec(c.r:Dot(v), c.u:Dot(v), c.b:Dot(v)) end
C.__index = function(c, key)
	if key == "Position" then return c.p
	elseif key == "X" then return c.p.X
	elseif key == "Y" then return c.p.Y
	elseif key == "Z" then return c.p.Z
	elseif key == "RightVector" or key == "XVector" then return c.r
	elseif key == "UpVector" or key == "YVector" then return c.u
	elseif key == "ZVector" then return c.b
	elseif key == "LookVector" then return -c.b
	elseif key == "Rotation" then return cf(vec(0, 0, 0), c.r, c.u, c.b)
	end
	return C[key]
end
C.__mul = function(a, b)
	if getmetatable(b) == C then
		return cf(a.p + rot(a, b.p), rot(a, b.r), rot(a, b.u), rot(a, b.b))
	end
	return a.p + rot(a, b)
end
C.__add = function(a, v) return cf(a.p + v, a.r, a.u, a.b) end
C.__sub = function(a, v) return cf(a.p - v, a.r, a.u, a.b) end
function C.Inverse(c)
	-- Transpose of the rotation; columns of the inverse are the rows of the original.
	local r = vec(c.r.X, c.u.X, c.b.X)
	local u = vec(c.r.Y, c.u.Y, c.b.Y)
	local b = vec(c.r.Z, c.u.Z, c.b.Z)
	local inv = cf(vec(0, 0, 0), r, u, b)
	return cf(-rot(inv, c.p), r, u, b)
end
function C.ToObjectSpace(a, b) return a:Inverse() * b end
function C.ToWorldSpace(a, b) return a * b end
function C.PointToObjectSpace(a, v) return unrot(a, v - a.p) end
function C.PointToWorldSpace(a, v) return a * v end
function C.VectorToWorldSpace(a, v) return rot(a, v) end
function C.VectorToObjectSpace(a, v) return unrot(a, v) end
function C.GetComponents(c)
	return c.p.X, c.p.Y, c.p.Z, c.r.X, c.u.X, c.b.X, c.r.Y, c.u.Y, c.b.Y, c.r.Z, c.u.Z, c.b.Z
end
local IDR, IDU, IDB = vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1)
local function lookAt(at, target, up)
	up = up or vec(0, 1, 0)
	local look = (target - at)
	if look.Magnitude < 1e-9 then return cf(at, IDR, IDU, IDB) end
	look = look.Unit
	local right = look:Cross(up)
	if right.Magnitude < 1e-6 then right = look:Cross(vec(0, 0, 1)) end
	right = right.Unit
	local upv = right:Cross(look).Unit
	return cf(at, right, upv, -look)
end
local function axisRot(axis, angle)
	local c, s = math.cos(angle), math.sin(angle)
	if axis == "x" then return cf(vec(0, 0, 0), vec(1, 0, 0), vec(0, c, s), vec(0, -s, c)) end
	if axis == "y" then return cf(vec(0, 0, 0), vec(c, 0, -s), vec(0, 1, 0), vec(s, 0, c)) end
	return cf(vec(0, 0, 0), vec(c, s, 0), vec(-s, c, 0), vec(0, 0, 1))
end
CFrame = {
	new = function(x, y, z, ...)
		if x == nil then return cf(vec(0, 0, 0), IDR, IDU, IDB) end
		if type(x) == "table" then
			if y then return lookAt(x, y) end
			return cf(x, IDR, IDU, IDB)
		end
		local extra = { ... }
		if #extra == 9 then
			local m = extra
			return cf(vec(x, y, z), vec(m[1], m[4], m[7]), vec(m[2], m[5], m[8]), vec(m[3], m[6], m[9]))
		end
		return cf(vec(x, y, z), IDR, IDU, IDB)
	end,
	lookAt = lookAt,
	fromMatrix = function(p, r, u, b)
		b = b or r:Cross(u).Unit
		return cf(p, r, u, b)
	end,
	Angles = function(rx, ry, rz)
		return axisRot("x", rx or 0) * axisRot("y", ry or 0) * axisRot("z", rz or 0)
	end,
	fromAxisAngle = function(axis, angle)
		axis = axis.Unit
		local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
		local x, y, z = axis.X, axis.Y, axis.Z
		return cf(vec(0, 0, 0), vec(t * x * x + c, t * x * y + s * z, t * x * z - s * y),
			vec(t * x * y - s * z, t * y * y + c, t * y * z + s * x), vec(t * x * z + s * y, t * y * z - s * x, t * z * z + c))
	end,
}
CFrame.fromEulerAnglesXYZ = CFrame.Angles
CFrame.identity = CFrame.new()

-- Colours, enums, misc value types ----------------------------------------------------------
local Col = {}
Col.__index = Col
local function col(r, g, b) return setmetatable({ R = r, G = g, B = b, __type = "Color3" }, Col) end
function Col.Lerp(a, b, t) return col(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
function Col.ToHSV(c) return 0, 0, (c.R + c.G + c.B) / 3 end
Col.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
Color3 = { new = col, fromRGB = function(r, g, b) return col(r / 255, g / 255, b / 255) end,
	fromHSV = function(h, s, v) return col(v, v, v) end }

local enumCache = {}
Enum = setmetatable({}, { __index = function(_, group)
	enumCache[group] = enumCache[group] or setmetatable({}, { __index = function(t, name)
		local item = { Name = name, EnumType = group, __type = "EnumItem" }
		rawset(t, name, item)
		return item
	end })
	return enumCache[group]
end })

local function passthrough(kind)
	return setmetatable({}, { __index = function() return function(...) return { __type = kind, args = { ... } } end end })
end
ColorSequence = passthrough("ColorSequence")
NumberSequence = passthrough("NumberSequence")
NumberSequenceKeypoint = passthrough("NumberSequenceKeypoint")
ColorSequenceKeypoint = passthrough("ColorSequenceKeypoint")
NumberRange = passthrough("NumberRange")
PhysicalProperties = passthrough("PhysicalProperties")
TweenInfo = passthrough("TweenInfo")
UDim2 = passthrough("UDim2")
UDim = passthrough("UDim")
Rect = passthrough("Rect")
Font = passthrough("Font")
Font.fromEnum = function(...) return { __type = "Font" } end
DateTime = { now = function() return { UnixTimestampMillis = 0 } end }

function typeof(value)
	if type(value) == "table" then
		if rawget(value, "__type") then return rawget(value, "__type") end
		if rawget(value, "__instance") then return "Instance" end
	end
	return type(value)
end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
math.sign = function(x) return x > 0 and 1 or (x < 0 and -1 or 0) end
math.round = function(x) return math.floor(x + 0.5) end
math.noise = function() return 0 end
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
math.pow = math.pow or function(a, b) return a ^ b end
table.find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
table.clone = function(t)
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = v
	end
	return copy
end
table.freeze = function(t) return t end
string.split = function(s, sep)
	local out = {}
	for piece in string.gmatch(s, "([^" .. sep .. "]+)") do table.insert(out, piece) end
	return out
end
warn = function(...) end

Random = { new = function(seed)
	local state = (seed or 1) % 2147483647
	if state <= 0 then state = state + 2147483646 end
	local function nxt()
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
	return {
		NextNumber = function(_, a, b) if a then return a + (b - a) * nxt() end return nxt() end,
		NextInteger = function(_, a, b) return a + math.floor(nxt() * (b - a + 1)) end,
	}
end }

-- Signals, time and tasks -------------------------------------------------------------------
mock.clock = 0
local queue = {}
local function signal()
	local s = { handlers = {} }
	function s:Connect(fn)
		table.insert(self.handlers, fn)
		return { Disconnect = function() for i, h in ipairs(s.handlers) do if h == fn then table.remove(s.handlers, i) break end end end }
	end
	function s:Once(fn) return self:Connect(fn) end
	function s:Fire(...) for _, h in ipairs({ table.unpack(self.handlers) }) do h(...) end end
	return s
end
mock.signal = signal
task = {
	spawn = function(fn, ...) if type(fn) == "function" then fn(...) end end,
	defer = function(fn, ...) table.insert(queue, { at = mock.clock, fn = fn, args = { ... } }) end,
	delay = function(t, fn, ...) table.insert(queue, { at = mock.clock + (t or 0), fn = fn, args = { ... } }) end,
	wait = function() return 0 end,
}
function time() return mock.clock end
function tick() return mock.clock end
os.clock = function() return mock.clock end
local function runDue()
	local ran = true
	while ran do
		ran = false
		for i, job in ipairs(queue) do
			if job.at <= mock.clock + 1e-9 then
				table.remove(queue, i)
				job.fn(table.unpack(job.args))
				ran = true
				break
			end
		end
	end
end
mock.runDue = runDue

-- Instances ---------------------------------------------------------------------------------
local PART_CLASSES = { Part = true, WedgePart = true, CornerWedgePart = true, TrussPart = true, MeshPart = true, SpawnLocation = true, Seat = true }
local I = {}
local instanceCount = 0
mock.created = {}
local function newInstance(className)
	instanceCount = instanceCount + 1
	local inst = { __instance = true, __props = { ClassName = className, Name = className, Transparency = 0,
		CanCollide = true, CanQuery = true, CanTouch = true, Anchored = false, Size = vec(4, 1, 2),
		CFrame = CFrame.new(), Color = col(0.6, 0.6, 0.6), Material = Enum.Material.Plastic, Massless = false,
		AssemblyLinearVelocity = vec(0, 0, 0), AssemblyAngularVelocity = vec(0, 0, 0) },
		__children = {}, __attributes = {}, __destroying = signal(), __id = instanceCount }
	table.insert(mock.created, inst)
	return setmetatable(inst, I)
end
I.__index = function(inst, key)
	local props = rawget(inst, "__props")
	if key == "Parent" then return rawget(inst, "__parent") end
	if key == "Destroying" then return rawget(inst, "__destroying") end
	if key == "Position" and props.CFrame then return props.CFrame.Position end
	if I[key] then return I[key] end
	if props[key] ~= nil then return props[key] end
	-- A child by name, the way Roblox resolves inst.Child.
	for _, child in ipairs(rawget(inst, "__children")) do
		if child.Name == key then return child end
	end
	return nil
end
I.__newindex = function(inst, key, value)
	local props = rawget(inst, "__props")
	if key == "Parent" then
		local old = rawget(inst, "__parent")
		if old then
			local list = rawget(old, "__children")
			for i, c in ipairs(list) do if c == inst then table.remove(list, i) break end end
		end
		rawset(inst, "__parent", value)
		if value then table.insert(rawget(value, "__children"), inst) end
		if value and rawget(value, "__childAdded") then rawget(value, "__childAdded"):Fire(inst) end
		return
	end
	if key == "Position" then
		local c = props.CFrame
		props.CFrame = cf(value, c.r, c.u, c.b)
		return
	end
	if key == "Shape" and value == Enum.PartType.Ball then
		props.Shape = value
		return
	end
	props[key] = value
end
I.__tostring = function(inst) return inst.Name end
function I.IsA(inst, className)
	local cls = inst.ClassName
	if className == cls or className == "Instance" then return true end
	if className == "BasePart" or className == "PVInstance" then return PART_CLASSES[cls] == true end
	if className == "Model" then return cls == "Model" or cls == "Workspace" end
	return false
end
function I.GetChildren(inst) return { table.unpack(rawget(inst, "__children")) } end
function I.GetDescendants(inst)
	local out = {}
	local function walk(node)
		for _, c in ipairs(rawget(node, "__children")) do table.insert(out, c); walk(c) end
	end
	walk(inst)
	return out
end
function I.FindFirstChild(inst, name, recursive)
	for _, c in ipairs(rawget(inst, "__children")) do if c.Name == name then return c end end
	if recursive then
		for _, c in ipairs(rawget(inst, "__children")) do
			local found = c:FindFirstChild(name, true)
			if found then return found end
		end
	end
	return nil
end
I.WaitForChild = I.FindFirstChild
function I.FindFirstChildOfClass(inst, cls)
	for _, c in ipairs(rawget(inst, "__children")) do if c.ClassName == cls then return c end end
end
function I.FindFirstAncestor(inst, name)
	local node = inst.Parent
	while node do if node.Name == name then return node end node = node.Parent end
end
function I.IsDescendantOf(inst, other)
	local node = inst.Parent
	while node do if node == other then return true end node = node.Parent end
	return false
end
function I.GetAttribute(inst, name) return rawget(inst, "__attributes")[name] end
function I.SetAttribute(inst, name, value)
	mock.attributeWrites = (mock.attributeWrites or 0) + 1
	rawget(inst, "__attributes")[name] = value
end
function I.GetAttributes(inst) return rawget(inst, "__attributes") end
function I.Destroy(inst)
	if rawget(inst, "__destroyed") then return end
	for _, c in ipairs(inst:GetChildren()) do c:Destroy() end
	rawset(inst, "__destroyed", true)
	rawget(inst, "__destroying"):Fire()
	inst.Parent = nil
end
function I.ClearAllChildren(inst) for _, c in ipairs(inst:GetChildren()) do c:Destroy() end end
function I.Clone(inst)
	local copy = newInstance(inst.ClassName)
	for k, v in pairs(rawget(inst, "__props")) do rawget(copy, "__props")[k] = v end
	for k, v in pairs(rawget(inst, "__attributes")) do rawget(copy, "__attributes")[k] = v end
	return copy
end
function I.GetPivot(inst) return inst.CFrame or CFrame.new() end
function I.PivotTo(inst, c) inst.CFrame = c end
function I.Emit(inst, n) mock.emitted = (mock.emitted or 0) + n end
function I.AddTag() end
function I.HasTag() return false end
function I.GetPropertyChangedSignal() return signal() end
function I.GetBoundingBox(model)
	local low, high
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local a, b = d.Position - d.Size / 2, d.Position + d.Size / 2
			low = low and low:Min(a) or a
			high = high and high:Max(b) or b
		end
	end
	if not low then return CFrame.new(), vec(0, 0, 0) end
	return CFrame.new((low + high) / 2), high - low
end
function I.GetExtentsSize(model)
	local _, extent = model:GetBoundingBox()
	return extent
end
Instance = { new = function(className, parent)
	local inst = newInstance(className)
	if className == "Model" or className == "Folder" then
		rawget(inst, "__props").CFrame = nil
		rawget(inst, "__props").Size = nil
	end
	if parent then inst.Parent = parent end
	return inst
end }
mock.newInstance = newInstance

workspace = newInstance("Workspace")
workspace.Name = "Workspace"
local terrain = newInstance("Terrain")
terrain.Name = "Terrain"
terrain.Parent = workspace
mock.fills = {}
function terrain.FillBall(_, centre, radius, material) table.insert(mock.fills, { centre, radius, material }) end
function terrain.FillBlock() end
function terrain.ReplaceMaterial() end
workspace.CurrentCamera = { CFrame = CFrame.new() }
-- Raycasts answer from a harness-set function: mock.raycast(origin, direction, params) -> result or nil.
mock.raycast = function() return nil end
function workspace.Raycast(_, origin, direction, params) return mock.raycast(origin, direction, params) end
-- Overlaps: every BasePart under the include list whose box reaches the sphere.
function workspace.GetPartBoundsInRadius(_, centre, radius, params)
	local out = {}
	for _, root in ipairs(params and params.FilterDescendantsInstances or { workspace }) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and d.CanQuery then
				local local_ = d.CFrame:PointToObjectSpace(centre)
				local h = d.Size / 2
				local cx = math.clamp(local_.X, -h.X, h.X)
				local cy = math.clamp(local_.Y, -h.Y, h.Y)
				local cz = math.clamp(local_.Z, -h.Z, h.Z)
				if (vec(cx, cy, cz) - local_).Magnitude <= radius then table.insert(out, d) end
			end
		end
	end
	return out
end
RaycastParams = { new = function() return { FilterDescendantsInstances = {} } end }
OverlapParams = { new = function() return { FilterDescendantsInstances = {} } end }

-- Services ----------------------------------------------------------------------------------
mock.heartbeat = signal()
mock.remotes = {}
local services = {
	RunService = { Heartbeat = mock.heartbeat, RenderStepped = signal(), Stepped = signal(),
		IsServer = function() return true end, IsClient = function() return false end, IsStudio = function() return true end },
	TweenService = { Create = function(_, inst, info, goal)
		return { Play = function() for k, v in pairs(goal) do inst[k] = v end end, Completed = signal(), Cancel = function() end }
	end },
	Debris = { AddItem = function(_, inst, t) task.delay(t, function() inst:Destroy() end) end },
	CollectionService = { AddTag = function() end, GetTagged = function() return {} end, HasTag = function() return false end },
	Players = { LocalPlayer = newInstance("Player"), GetPlayers = function() return {} end },
	Lighting = newInstance("Lighting"),
}
services.ReplicatedStorage = newInstance("ReplicatedStorage")
services.ServerScriptService = newInstance("ServerScriptService")
services.Workspace = workspace
game = { GetService = function(_, name) return services[name] or newInstance(name) end, Workspace = workspace }

-- A RemoteEvent that records what the server fires and lets the harness play the client side.
function mock.remote(name)
	if not mock.remotes[name] then
		local r = { fired = {}, OnClientEvent = signal(), OnServerEvent = signal() }
		function r:FireAllClients(...) table.insert(self.fired, { ... }) end
		function r:FireClient(_, ...) table.insert(self.fired, { ... }) end
		mock.remotes[name] = r
	end
	return mock.remotes[name]
end
mock.RemotesModule = { Event = function(name) return mock.remote(name) end, Function = function(name) return mock.remote(name) end }

function mock.advance(dt, step)
	step = step or (1 / 30)
	local target = mock.clock + dt
	while mock.clock < target - 1e-9 do
		mock.clock = math.min(target, mock.clock + step)
		runDue()
		mock.heartbeat:Fire(step)
		runDue()
	end
end

return mock
