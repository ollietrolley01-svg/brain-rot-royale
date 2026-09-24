-- Plain-Lua stand-ins for the Roblox types the #97 / #122 checks need (tools/hitreg_rewind_check.py,
-- tools/explosive_ammo_check.py): Vector3, CFrame, a few Instance methods, RaycastParams and an
-- independent ray-against-box test for the mocked world. Loaded by lupa, never by the game.
--
-- The world's own raycast here is written separately from LagCompensation's, on purpose: the check
-- compares the two, and a copy of the code under test would agree with it whatever it did.

local M = {}

--------------------------------------------------------------------------------
-- Vector3
--------------------------------------------------------------------------------
local V = {}
local function vec(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V)
end
V.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		return vec(v.X / m, v.Y / m, v.Z / m)
	elseif key == "Dot" then
		return function(a, b)
			return a.X * b.X + a.Y * b.Y + a.Z * b.Z
		end
	end
	return nil
end
V.__add = function(a, b)
	return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V.__sub = function(a, b)
	return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V.__unm = function(a)
	return vec(-a.X, -a.Y, -a.Z)
end
V.__mul = function(a, b)
	if type(a) == "number" then
		a, b = b, a
	end
	if type(b) == "number" then
		return vec(a.X * b, a.Y * b, a.Z * b)
	end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b)
	return vec(a.X / b, a.Y / b, a.Z / b)
end
V.__tostring = function(v)
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end
M.Vector3 = { new = vec, zero = vec(0, 0, 0), yAxis = vec(0, 1, 0) }

--------------------------------------------------------------------------------
-- CFrame: position p and rotation rows r[1..3] (world = p + R * local)
--------------------------------------------------------------------------------
local C = {}
local function cf(p, r)
	return setmetatable({ p = p, r = r or { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } }, C)
end
local function rmul(r, v)
	return vec(
		r[1][1] * v.X + r[1][2] * v.Y + r[1][3] * v.Z,
		r[2][1] * v.X + r[2][2] * v.Y + r[2][3] * v.Z,
		r[3][1] * v.X + r[3][2] * v.Y + r[3][3] * v.Z
	)
end
local function rt(r)
	return { { r[1][1], r[2][1], r[3][1] }, { r[1][2], r[2][2], r[3][2] }, { r[1][3], r[2][3], r[3][3] } }
end
local function rr(a, b)
	local out = {}
	for i = 1, 3 do
		out[i] = {}
		for j = 1, 3 do
			out[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
		end
	end
	return out
end
local methods = {}
function methods.Inverse(c)
	local inv = rt(c.r)
	return cf(-rmul(inv, c.p), inv)
end
function methods.PointToObjectSpace(c, v)
	return rmul(rt(c.r), v - c.p)
end
function methods.VectorToObjectSpace(c, v)
	return rmul(rt(c.r), v)
end
function methods.VectorToWorldSpace(c, v)
	return rmul(c.r, v)
end
function methods.Lerp(a, b, t)
	local r = {}
	for i = 1, 3 do
		r[i] = {}
		for j = 1, 3 do
			r[i][j] = a.r[i][j] + (b.r[i][j] - a.r[i][j]) * t
		end
	end
	return cf(a.p + (b.p - a.p) * t, r)
end
C.__index = function(c, key)
	if key == "Position" then
		return c.p
	end
	return methods[key]
end
C.__mul = function(a, b)
	if getmetatable(b) == C then
		return cf(a.p + rmul(a.r, b.p), rr(a.r, b.r))
	end
	return a.p + rmul(a.r, b)
end
M.CFrame = {
	new = function(x, y, z)
		if type(x) == "table" then
			return cf(x)
		end
		return cf(vec(x, y, z))
	end,
	-- A turn about Y only: all the checks need.
	fromYaw = function(yaw)
		local c, s = math.cos(yaw), math.sin(yaw)
		return cf(vec(0, 0, 0), { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } })
	end,
}

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------
local I = {}
local instanceMethods = {}
I.__index = function(inst, key)
	local raw = rawget(inst, "_props")
	if key == "CFrame" and raw.follow then
		return raw.follow.CFrame * raw.offset
	end
	if raw[key] ~= nil then
		return raw[key]
	end
	if key == "Position" and (raw.follow or raw.CFrame) then
		return inst.CFrame.Position
	end
	return instanceMethods[key]
end
I.__newindex = function(inst, key, value)
	rawget(inst, "_props")[key] = value
end
function instanceMethods.IsA(inst, class)
	if class == "BasePart" then
		return inst.ClassName == "Part" or inst.ClassName == "MeshPart"
	end
	return inst.ClassName == class
end
function instanceMethods.FindFirstChild(inst, name)
	for _, child in ipairs(inst._children) do
		if child.Name == name then
			return child
		end
	end
	return nil
end
function instanceMethods.GetChildren(inst)
	return { table.unpack(inst._children) }
end
function instanceMethods.GetDescendants(inst)
	local out = {}
	local function walk(node)
		for _, child in ipairs(node._children) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(inst)
	return out
end
function instanceMethods.IsDescendantOf(inst, other)
	local node = inst.Parent
	while node do
		if node == other then
			return true
		end
		node = node.Parent
	end
	return false
end
function instanceMethods.FindFirstAncestorWhichIsA(inst, class)
	local node = inst.Parent
	while node and node ~= M.workspace do
		if node:IsA(class) then
			return node
		end
		node = node.Parent
	end
	return nil
end
function instanceMethods.FindFirstAncestorOfClass(inst, class)
	local node = inst.Parent
	while node and node ~= M.workspace do
		if node.ClassName == class then
			return node
		end
		node = node.Parent
	end
	return nil
end

function M.instance(class, name, parent, props)
	local inst = setmetatable({ _props = { ClassName = class, Name = name }, _children = {} }, I)
	for k, v in pairs(props or {}) do
		inst._props[k] = v
	end
	if parent then
		inst._props.Parent = parent
		table.insert(parent._children, inst)
	end
	return inst
end

-- An R15-ish body: root, lower and upper torso, head, arms, legs, and a hat Accessory whose Handle is
-- queryable (a player's own Roblox hat, left at its default). Parts follow the root.
function M.character(name, rootCFrame)
	local model = M.instance("Model", name, M.workspace)
	local root = M.instance("Part", "HumanoidRootPart", model, { Size = vec(2, 2, 1), CanQuery = true, CFrame = rootCFrame })
	local function limb(partName, offset, size, parent)
		return M.instance("MeshPart", partName, parent or model, {
			Size = size,
			CanQuery = true,
			follow = root,
			offset = M.CFrame.new(offset.X, offset.Y, offset.Z),
		})
	end
	limb("UpperTorso", vec(0, 0.4, 0), vec(2, 1.6, 1))
	limb("LowerTorso", vec(0, -0.6, 0), vec(2, 0.4, 1))
	limb("Head", vec(0, 1.8, 0), vec(1.2, 1.2, 1.2))
	limb("LeftUpperArm", vec(-1.5, 0.4, 0), vec(1, 1.6, 1))
	limb("RightUpperArm", vec(1.5, 0.4, 0), vec(1, 1.6, 1))
	limb("LeftUpperLeg", vec(-0.5, -1.8, 0), vec(1, 2, 1))
	limb("RightUpperLeg", vec(0.5, -1.8, 0), vec(1, 2, 1))
	local hat = M.instance("Accessory", "Hat", model)
	limb("Handle", vec(0, 3.0, 0), vec(1.6, 1.6, 1.6), hat)
	return model, root
end

--------------------------------------------------------------------------------
-- The world: boxes (walls) plus every character's parts, tested as they are NOW
--------------------------------------------------------------------------------
M.walls = {}

local function slab(origin, vector, c, size)
	local o = c:PointToObjectSpace(origin)
	local d = c:VectorToObjectSpace(vector)
	local lo, hi = 0, 1
	for _, a in ipairs({ "X", "Y", "Z" }) do
		local h = size[a] / 2
		if math.abs(d[a]) < 1e-12 then
			if o[a] < -h or o[a] > h then
				return nil
			end
		else
			local t1, t2 = (-h - o[a]) / d[a], (h - o[a]) / d[a]
			lo = math.max(lo, math.min(t1, t2))
			hi = math.min(hi, math.max(t1, t2))
			if lo > hi then
				return nil
			end
		end
	end
	return lo
end

local function filtered(inst, filter)
	for _, f in ipairs(filter) do
		if inst == f or inst:IsDescendantOf(f) then
			return true
		end
	end
	return false
end

M.RaycastParams = {
	new = function()
		return { FilterType = "Exclude", FilterDescendantsInstances = {}, IgnoreWater = false, CollisionGroup = "Default", RespectCanCollide = false }
	end,
}
M.Enum = { RaycastFilterType = { Exclude = "Exclude", Include = "Include" } }

M.clock = 0
M.worldCalls = 0
M.workspace = setmetatable({ _props = { ClassName = "Workspace", Name = "Workspace" }, _children = {} }, I)
rawget(M.workspace, "_props").GetServerTimeNow = function()
	return M.clock
end
rawget(M.workspace, "_props").Raycast = function(_, origin, vector, params)
	M.worldCalls = M.worldCalls + 1
	local best, bestPart = math.huge, nil
	local function try(part)
		if part.CanQuery and not filtered(part, params.FilterDescendantsInstances) then
			local t = slab(origin, vector, part.CFrame, part.Size)
			if t and t < best then
				best, bestPart = t, part
			end
		end
	end
	for _, wall in ipairs(M.walls) do
		try(wall)
	end
	for _, inst in ipairs(M.workspace:GetDescendants()) do
		if inst:IsA("BasePart") then
			try(inst)
		end
	end
	if not bestPart then
		return nil
	end
	return { Instance = bestPart, Position = origin + vector * best, Normal = -vector.Unit, Distance = vector.Magnitude * best }
end

function M.wall(name, centre, size)
	local w = M.instance("Part", name, nil, { Size = size, CanQuery = true, CFrame = M.CFrame.new(centre.X, centre.Y, centre.Z) })
	table.insert(M.walls, w)
	return w
end

return M
