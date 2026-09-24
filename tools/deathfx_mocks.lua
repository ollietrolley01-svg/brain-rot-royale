-- Roblox stand-ins with REAL arithmetic, for tools/killanim_check.py (the death effects, #24).
--
-- The older checks mock Vector3 and CFrame as values that absorb anything, which is enough to count
-- parts but not to ask where they are. The death effects are a timeline whose whole promise is that a
-- still at t is frame t of the game, and that a body is really moved, squashed and put back: checking
-- that needs positions, rotations, sizes and colours that are numbers. So:
--
--   Vector3   components, + - * / unary minus, Magnitude, Unit, Lerp, Cross, Dot
--   CFrame    a position and a 3x3 rotation: new, Angles (X then Y then Z, like fromEulerAnglesXYZ),
--             lookAt, identity, * (with a CFrame or a Vector3), + and - a Vector3, Inverse,
--             ToObjectSpace, Lerp (quaternion slerp), Position, Right/Up/LookVector
--   Color3    fromRGB, new, Lerp
--   Instance  a class, properties (with a write log), children and descendants, attributes,
--             IsA over the few hierarchies used, Destroy (which marks the whole subtree), and the
--             ParticleEmitter's Emit (logged with the clock)
--   clock     task.delay / task.spawn / task.defer on a virtual time line, and a Heartbeat signal the
--             harness fires with a fixed frame time
--
-- Returns a table of constructors and hooks; install() puts the globals in place.

local M = {}

--------------------------------------------------------------------------------
-- Vector3
--------------------------------------------------------------------------------

local Vec = {}
Vec.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return M.vec(0, 0, 0)
		end
		return M.vec(v.X / m, v.Y / m, v.Z / m)
	end
	return Vec[key]
end
local function isvec(v)
	return getmetatable(v) == Vec
end
function M.vec(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __type = "Vector3" }, Vec)
end
Vec.__add = function(a, b)
	return M.vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vec.__sub = function(a, b)
	return M.vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vec.__mul = function(a, b)
	if type(a) == "number" then
		return M.vec(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return M.vec(a.X * b, a.Y * b, a.Z * b)
	end
	return M.vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vec.__div = function(a, b)
	if type(b) == "number" then
		return M.vec(a.X / b, a.Y / b, a.Z / b)
	end
	return M.vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vec.__unm = function(a)
	return M.vec(-a.X, -a.Y, -a.Z)
end
Vec.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vec.__tostring = function(v)
	return string.format("(%.3f, %.3f, %.3f)", v.X, v.Y, v.Z)
end
function Vec.Lerp(a, b, t)
	return a + (b - a) * t
end
function Vec.Cross(a, b)
	return M.vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function Vec.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end

--------------------------------------------------------------------------------
-- CFrame: p (Vector3) and r = { r00, r01, r02, r10, ... } row-major; columns are right, up, back.
--------------------------------------------------------------------------------

local CF = {}
local function isCF(v)
	return getmetatable(v) == CF
end
local function cf(p, r)
	return setmetatable({ p = p, r = r, __type = "CFrame" }, CF)
end
local IDENTITY_R = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local function mulR(a, b)
	local out = {}
	for i = 0, 2 do
		for j = 0, 2 do
			out[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[3 + j + 1] + a[i * 3 + 3] * b[6 + j + 1]
		end
	end
	return out
end
local function rotV(r, v)
	return M.vec(r[1] * v.X + r[2] * v.Y + r[3] * v.Z, r[4] * v.X + r[5] * v.Y + r[6] * v.Z, r[7] * v.X + r[8] * v.Y + r[9] * v.Z)
end
local function transpose(r)
	return { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] }
end
CF.__index = function(c, key)
	if key == "Position" or key == "p" then
		return rawget(c, "p")
	elseif key == "X" then
		return c.p.X
	elseif key == "Y" then
		return c.p.Y
	elseif key == "Z" then
		return c.p.Z
	elseif key == "RightVector" then
		return M.vec(c.r[1], c.r[4], c.r[7])
	elseif key == "UpVector" then
		return M.vec(c.r[2], c.r[5], c.r[8])
	elseif key == "LookVector" then
		return M.vec(-c.r[3], -c.r[6], -c.r[9])
	elseif key == "Rotation" then
		return cf(M.vec(0, 0, 0), c.r)
	end
	return CF[key]
end
CF.__mul = function(a, b)
	if isCF(b) then
		return cf(a.p + rotV(a.r, b.p), mulR(a.r, b.r))
	end
	return a.p + rotV(a.r, b)
end
CF.__add = function(a, v)
	return cf(a.p + v, a.r)
end
CF.__sub = function(a, v)
	return cf(a.p - v, a.r)
end
function CF.Inverse(c)
	local t = transpose(c.r)
	return cf(-rotV(t, c.p), t)
end
function CF.ToObjectSpace(a, b)
	return a:Inverse() * b
end
function CF.ToWorldSpace(a, b)
	return a * b
end

local function toQuat(r)
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = table.unpack(r)
	local trace = m00 + m11 + m22
	local w, x, y, z
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		w, x, y, z = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		w, x, y, z = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
	end
	return w, x, y, z
end
local function fromQuat(w, x, y, z)
	local n = math.sqrt(w * w + x * x + y * y + z * z)
	w, x, y, z = w / n, x / n, y / n, z / n
	return {
		1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
		2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
		2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
	}
end
function CF.Lerp(a, b, t)
	local aw, ax, ay, az = toQuat(a.r)
	local bw, bx, by, bz = toQuat(b.r)
	if aw * bw + ax * bx + ay * by + az * bz < 0 then
		bw, bx, by, bz = -bw, -bx, -by, -bz
	end
	local r = fromQuat(aw + (bw - aw) * t, ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t)
	return cf(a.p:Lerp(b.p, t), r)
end

local function axisR(axis, angle)
	local c, s = math.cos(angle), math.sin(angle)
	if axis == "x" then
		return { 1, 0, 0, 0, c, -s, 0, s, c }
	elseif axis == "y" then
		return { c, 0, s, 0, 1, 0, -s, 0, c }
	end
	return { c, -s, 0, s, c, 0, 0, 0, 1 }
end

M.CFrame = {
	new = function(x, y, z)
		if x == nil then
			return cf(M.vec(0, 0, 0), IDENTITY_R)
		end
		if isvec(x) then
			return cf(x, IDENTITY_R)
		end
		return cf(M.vec(x, y, z), IDENTITY_R)
	end,
	Angles = function(rx, ry, rz)
		return cf(M.vec(0, 0, 0), mulR(mulR(axisR("x", rx), axisR("y", ry)), axisR("z", rz)))
	end,
	lookAt = function(at, target, up)
		up = up or M.vec(0, 1, 0)
		local look = (target - at).Unit
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			right = look:Cross(M.vec(0, 0, 1))
		end
		right = right.Unit
		local up2 = right:Cross(look)
		return cf(at, { right.X, up2.X, -look.X, right.Y, up2.Y, -look.Y, right.Z, up2.Z, -look.Z })
	end,
	identity = nil,
}
M.CFrame.identity = M.CFrame.new()
M.CFrame.fromEulerAnglesXYZ = M.CFrame.Angles

--------------------------------------------------------------------------------
-- Color3
--------------------------------------------------------------------------------

local Col = {}
Col.__index = Col
function M.color(r, g, b)
	return setmetatable({ R = r, G = g, B = b, __type = "Color3" }, Col)
end
function Col.Lerp(a, b, t)
	return M.color(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
Col.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
M.Color3 = {
	new = function(r, g, b)
		return M.color(r or 0, g or 0, b or 0)
	end,
	fromRGB = function(r, g, b)
		return M.color((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
	fromHSV = function()
		return M.color(1, 1, 1)
	end,
}

--------------------------------------------------------------------------------
-- Enums: Enum.Material.Neon is the same table every time it's asked for.
--------------------------------------------------------------------------------

local enumCache = {}
M.Enum = setmetatable({}, { __index = function(_, family)
	enumCache[family] = enumCache[family] or setmetatable({}, { __index = function(items, name)
		local item = { Name = name, EnumType = family, __type = "EnumItem" }
		rawset(items, name, item)
		return item
	end })
	return enumCache[family]
end })

--------------------------------------------------------------------------------
-- The clock
--------------------------------------------------------------------------------

M.now = 0
local queue = {}
local seq = 0
function M.schedule(delay, fn)
	seq = seq + 1
	table.insert(queue, { at = M.now + (delay or 0), fn = fn, seq = seq })
end
M.task = {
	delay = function(delay, fn, ...)
		local args = { ... }
		M.schedule(delay, function() fn(table.unpack(args)) end)
	end,
	spawn = function(fn, ...)
		fn(...)
	end,
	defer = function(fn, ...)
		local args = { ... }
		M.schedule(0, function() fn(table.unpack(args)) end)
	end,
	wait = function()
		return 0
	end,
}

local heartbeat = {}
local function signal(list)
	return {
		Connect = function(_, fn)
			local entry = { fn = fn, live = true }
			table.insert(list, entry)
			return { Disconnect = function() entry.live = false end, Connected = true }
		end,
	}
end
M.Heartbeat = signal(heartbeat)
function M.heartbeatCount()
	local count = 0
	for _, entry in ipairs(heartbeat) do
		if entry.live then
			count = count + 1
		end
	end
	return count
end

-- Runs the time line to `limit`: due delays in order, and a Heartbeat every `frame` seconds.
function M.runTo(limit, frame)
	frame = frame or (1 / 60)
	while M.now < limit - 1e-9 do
		local nextFrame = math.min(limit, M.now + frame)
		-- delays due by the next frame
		while true do
			table.sort(queue, function(a, b)
				if a.at ~= b.at then return a.at < b.at end
				return a.seq < b.seq
			end)
			local item = queue[1]
			if not item or item.at > nextFrame then
				break
			end
			table.remove(queue, 1)
			M.now = math.max(M.now, item.at)
			item.fn()
		end
		local dt = nextFrame - M.now
		M.now = nextFrame
		local list = {}
		for _, entry in ipairs(heartbeat) do
			if entry.live then
				table.insert(list, entry)
			end
		end
		for _, entry in ipairs(list) do
			if entry.live then
				entry.fn(dt > 0 and dt or frame)
			end
		end
	end
end

function M.resetClock()
	M.now = 0
	queue = {}
	for _, entry in ipairs(heartbeat) do
		entry.live = false
	end
	heartbeat = {}
	M.Heartbeat = signal(heartbeat)
end

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

local ISA = {
	BasePart = { Part = true, MeshPart = true, WedgePart = true },
	GuiObject = { Frame = true, TextLabel = true, ViewportFrame = true },
}
M.log = { writes = {}, created = {}, emits = {} }
M.logging = true

local Inst = {}
local InstMeta = {}

local DEFAULTS = {
	Part = function()
		return { Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CastShadow = true, Transparency = 0,
			Reflectance = 0, Size = M.vec(4, 1, 2), CFrame = M.CFrame.new(), Color = M.color(0.6, 0.6, 0.6),
			Material = M.Enum.Material.Plastic, Shape = M.Enum.PartType.Block }
	end,
	Decal = function()
		return { Transparency = 0 }
	end,
	ParticleEmitter = function()
		return { Enabled = true, Rate = 5 }
	end,
	PointLight = function()
		return { Brightness = 1, Range = 8 }
	end,
	Highlight = function()
		return { FillTransparency = 0.5 }
	end,
}

function M.new(class)
	local props = DEFAULTS[class] and DEFAULTS[class]() or {}
	props.ClassName = class
	props.Name = class
	local obj = setmetatable({ __props = props, __children = {}, __attrs = {}, __instance = true, __type = "Instance" }, InstMeta)
	table.insert(M.log.created, { obj = obj, class = class, at = M.now })
	return obj
end

InstMeta.__index = function(obj, key)
	if Inst[key] then
		return Inst[key]
	end
	local props = rawget(obj, "__props")
	if key == "Position" and props.CFrame then
		return props.CFrame.Position
	end
	local value = props[key]
	if value == nil then
		-- A child by name, the way Roblox resolves obj.Child.
		for _, child in ipairs(rawget(obj, "__children")) do
			if child.Name == key then
				return child
			end
		end
	end
	return value
end
InstMeta.__newindex = function(obj, key, value)
	local props = rawget(obj, "__props")
	if key == "Parent" then
		local old = props.Parent
		if old then
			local list = rawget(old, "__children")
			for index = #list, 1, -1 do
				if list[index] == obj then
					table.remove(list, index)
				end
			end
		end
		props.Parent = value
		if value then
			table.insert(rawget(value, "__children"), obj)
		end
		return
	end
	if key == "Position" then
		key, value = "CFrame", M.CFrame.new(value) * (props.CFrame and props.CFrame.Rotation or M.CFrame.new())
	end
	if M.logging then
		table.insert(M.log.writes, { obj = obj, key = key, at = M.now, destroyed = rawget(obj, "__destroyed") == true })
	end
	props[key] = value
end

function Inst.IsA(obj, class)
	local mine = obj.ClassName
	if mine == class or class == "Instance" then
		return true
	end
	return ISA[class] ~= nil and ISA[class][mine] == true
end
function Inst.GetChildren(obj)
	local out = {}
	for _, child in ipairs(rawget(obj, "__children")) do
		table.insert(out, child)
	end
	return out
end
function Inst.GetDescendants(obj)
	local out = {}
	local function walk(node)
		for _, child in ipairs(rawget(node, "__children")) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(obj)
	return out
end
function Inst.FindFirstChild(obj, name)
	for _, child in ipairs(rawget(obj, "__children")) do
		if child.Name == name then
			return child
		end
	end
	return nil
end
Inst.WaitForChild = Inst.FindFirstChild
function Inst.FindFirstChildOfClass(obj, class)
	for _, child in ipairs(rawget(obj, "__children")) do
		if child.ClassName == class then
			return child
		end
	end
	return nil
end
function Inst.FindFirstChildWhichIsA(obj, class)
	for _, child in ipairs(rawget(obj, "__children")) do
		if child:IsA(class) then
			return child
		end
	end
	return nil
end
function Inst.FindFirstAncestorWhichIsA(obj, class)
	local node = obj.Parent
	while node do
		if node:IsA(class) then
			return node
		end
		node = node.Parent
	end
	return nil
end
function Inst.IsDescendantOf(obj, ancestor)
	local node = obj.Parent
	while node do
		if node == ancestor then
			return true
		end
		node = node.Parent
	end
	return false
end
function Inst.Destroy(obj)
	local function mark(node)
		rawset(node, "__destroyed", true)
		for _, child in ipairs(rawget(node, "__children")) do
			mark(child)
		end
	end
	mark(obj)
	obj.Parent = nil
end
function Inst.SetAttribute(obj, name, value)
	rawget(obj, "__attrs")[name] = value
end
function Inst.GetAttribute(obj, name)
	return rawget(obj, "__attrs")[name]
end
function Inst.GetMass()
	return 1
end
function Inst.GetPivot(obj)
	local primary = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
	return primary and primary.CFrame or M.CFrame.new()
end
function Inst.SetNetworkOwner() end
function Inst.Emit(obj, count)
	table.insert(M.log.emits, { obj = obj, count = count, at = M.now })
end
function Inst.Connect() end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

function M.typeof(v)
	if type(v) == "table" then
		local t = rawget(v, "__type")
		if t then
			return t
		end
	end
	return type(v)
end

-- Random with Roblox's methods, deterministic per seed (Park-Miller).
M.Random = {
	new = function(seed)
		local state = math.floor(tonumber(seed) or 1) % 2147483647
		if state <= 0 then
			state = state + 2147483646
		end
		local function nextRaw()
			state = (state * 48271) % 2147483647
			return state / 2147483647
		end
		return {
			NextNumber = function(_, a, b)
				local x = nextRaw()
				if a then
					return a + (b - a) * x
				end
				return x
			end,
			NextInteger = function(_, a, b)
				return a + math.floor(nextRaw() * (b - a + 1))
			end,
		}
	end,
}

local function plain(kind)
	return {
		new = function(...)
			return { __type = kind, args = { ... } }
		end,
	}
end

function M.install(env)
	env = env or _G
	env.Vector3 = { new = M.vec, zero = M.vec(0, 0, 0), one = M.vec(1, 1, 1), xAxis = M.vec(1, 0, 0), yAxis = M.vec(0, 1, 0), zAxis = M.vec(0, 0, 1) }
	env.CFrame = M.CFrame
	env.Color3 = M.Color3
	env.Enum = M.Enum
	env.Vector2 = { new = function(x, y) return { X = x or 0, Y = y or 0, __type = "Vector2" } end }
	env.UDim2 = plain("UDim2")
	env.ColorSequence = {
		new = function(a, b)
			return { __type = "ColorSequence", first = type(a) == "table" and rawget(a, "__type") == nil and a or { a, b } }
		end,
	}
	env.ColorSequenceKeypoint = plain("ColorSequenceKeypoint")
	env.NumberSequence = plain("NumberSequence")
	env.NumberSequenceKeypoint = plain("NumberSequenceKeypoint")
	env.NumberRange = { new = function(a, b) return { Min = a, Max = b or a, __type = "NumberRange" } end }
	env.TweenInfo = { new = function(t) return { Time = t } end }
	env.RaycastParams = { new = function() return {} end }
	env.Random = M.Random
	env.Instance = { new = M.new }
	env.typeof = M.typeof
	env.task = M.task
	math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
	-- Luau keeps atan2; Lua 5.4 folded it into atan.
	math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
	table.find = table.find or function(list, value)
		for index, item in ipairs(list) do
			if item == value then
				return index
			end
		end
	end
	table.unpack = table.unpack or unpack
end

return M
