-- The world tools/roadkill_proof_check.py runs the game's REAL modules in (lupa, plain Lua). Not loaded
-- by the game.
--
-- VehicleService, CombatService, RoadkillPass, Combatants, RateLimit, Remotes, SafeValue, VehicleArmor,
-- VehicleCover, MatchConfig and MovementConfig are loaded whole. The rest is a stand-in: VehicleDynamics
-- (the real Handling table, a rig with four grounded wheels, a Step that only records), VehicleModels
-- (a box body per model id), WeaponService (a shield per token), MovementService (records launches) and
-- an inert proxy for anything else a module asks for.
--
-- Physics is not simulated. A test sets a chassis's velocity and moves it; the modules read what a real
-- server would read (AssemblyLinearVelocity, positions, seat occupants, network owner). The world is one
-- machine: the driver's client and the server see the same positions, so network lag is not modelled
-- here (the check's report works out the lag the server's reach test allows from the source instead).
--
-- Called as world(source, compile) where source(name) hands back a module's Lua text (already converted
-- from Luau) or nil and compile is plain Lua's `load` (passed in: this file is read as Luau by the
-- static checks).

local source, compile = ...

local now = { t = 1000 }

--------------------------------------------------------------------------------
-- Inert stand-ins
--------------------------------------------------------------------------------
local proxyMeta = {}
local function proxy(name)
	return setmetatable({ __proxy = name }, proxyMeta)
end
proxyMeta.__index = function(t, k)
	if type(k) == "number" then
		return nil
	end
	local child = proxy(rawget(t, "__proxy") .. "." .. tostring(k))
	rawset(t, k, child)
	return child
end
proxyMeta.__call = function(t)
	return proxy(rawget(t, "__proxy") .. "()")
end
proxyMeta.__tostring = function(t)
	return "<" .. rawget(t, "__proxy") .. ">"
end

--------------------------------------------------------------------------------
-- Vector3
--------------------------------------------------------------------------------
local V = {}
local function vec(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V)
end
local vmethods = {}
function vmethods.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function vmethods.Cross(a, b)
	return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function vmethods.Lerp(a, b, t)
	return vec(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end
function vmethods.Abs(a)
	return vec(math.abs(a.X), math.abs(a.Y), math.abs(a.Z))
end
V.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return vec(0, 0, 0)
		end
		return vec(v.X / m, v.Y / m, v.Z / m)
	end
	return vmethods[key]
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
	if type(b) == "number" then
		return vec(a.X / b, a.Y / b, a.Z / b)
	end
	return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V.__tostring = function(v)
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end
local Vector3 = {
	new = vec,
	zero = vec(0, 0, 0),
	one = vec(1, 1, 1),
	xAxis = vec(1, 0, 0),
	yAxis = vec(0, 1, 0),
	zAxis = vec(0, 0, 1),
}

--------------------------------------------------------------------------------
-- CFrame: position p and the rotation's columns x, y, z (right, up, back)
--------------------------------------------------------------------------------
local C = {}
local function cf(p, x, y, z)
	return setmetatable({ p = p, x = x or Vector3.xAxis, y = y or Vector3.yAxis, z = z or Vector3.zAxis }, C)
end
local function rot(c, v)
	return c.x * v.X + c.y * v.Y + c.z * v.Z
end
local function unrot(c, v)
	return vec(c.x:Dot(v), c.y:Dot(v), c.z:Dot(v))
end
local cmethods = {}
function cmethods.Inverse(c)
	-- The transpose's columns are the rows of the rotation.
	local x = vec(c.x.X, c.y.X, c.z.X)
	local y = vec(c.x.Y, c.y.Y, c.z.Y)
	local z = vec(c.x.Z, c.y.Z, c.z.Z)
	local inv = cf(vec(0, 0, 0), x, y, z)
	inv.p = -rot(inv, c.p)
	return inv
end
function cmethods.PointToObjectSpace(c, v)
	return unrot(c, v - c.p)
end
function cmethods.PointToWorldSpace(c, v)
	return c.p + rot(c, v)
end
function cmethods.VectorToObjectSpace(c, v)
	return unrot(c, v)
end
function cmethods.VectorToWorldSpace(c, v)
	return rot(c, v)
end
function cmethods.ToObjectSpace(c, other)
	return c:Inverse() * other
end
function cmethods.ToWorldSpace(c, other)
	return c * other
end
function cmethods.ToAxisAngle(c)
	local trace = c.x.X + c.y.Y + c.z.Z
	local angle = math.acos(math.max(-1, math.min(1, (trace - 1) / 2)))
	local axis = vec(c.y.Z - c.z.Y, c.z.X - c.x.Z, c.x.Y - c.y.X)
	if axis.Magnitude < 1e-9 then
		axis = Vector3.yAxis
	end
	return axis.Unit, angle
end
C.__index = function(c, key)
	if key == "Position" then
		return c.p
	elseif key == "X" then
		return c.p.X
	elseif key == "Y" then
		return c.p.Y
	elseif key == "Z" then
		return c.p.Z
	elseif key == "LookVector" then
		return -c.z
	elseif key == "UpVector" then
		return c.y
	elseif key == "RightVector" then
		return c.x
	elseif key == "Rotation" then
		return cf(vec(0, 0, 0), c.x, c.y, c.z)
	end
	return cmethods[key]
end
C.__mul = function(a, b)
	if getmetatable(b) == V then
		return a.p + rot(a, b)
	end
	return cf(a.p + rot(a, b.p), rot(a, b.x), rot(a, b.y), rot(a, b.z))
end
C.__add = function(a, v)
	return cf(a.p + v, a.x, a.y, a.z)
end
C.__sub = function(a, v)
	return cf(a.p - v, a.x, a.y, a.z)
end
local function axisAngle(axis, angle)
	local u = axis.Unit
	local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
	local function col(v)
		-- Rodrigues: v cos + (u x v) sin + u (u.v)(1 - cos)
		return v * c + u:Cross(v) * s + u * (u:Dot(v) * t)
	end
	return cf(vec(0, 0, 0), col(Vector3.xAxis), col(Vector3.yAxis), col(Vector3.zAxis))
end
local CFrame = {
	new = function(x, y, z)
		if getmetatable(x) == V then
			return cf(x)
		end
		return cf(vec(x or 0, y or 0, z or 0))
	end,
	Angles = function(rx, ry, rz)
		return axisAngle(Vector3.xAxis, rx or 0) * axisAngle(Vector3.yAxis, ry or 0) * axisAngle(Vector3.zAxis, rz or 0)
	end,
	fromAxisAngle = function(axis, angle)
		return axisAngle(axis, angle)
	end,
	fromMatrix = function(p, x, y, z)
		return cf(p, x, y, z or x:Cross(y))
	end,
	lookAt = function(at, target)
		local look = (target - at).Unit
		local right = look:Cross(Vector3.yAxis).Unit
		return cf(at, right, right:Cross(look), -look)
	end,
}
CFrame.identity = CFrame.new(0, 0, 0)

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------
local function signal()
	local s = { handlers = {} }
	function s:Connect(fn)
		local entry = { fn = fn, on = true }
		table.insert(self.handlers, entry)
		return {
			Connected = true,
			Disconnect = function(conn)
				entry.on = false
				conn.Connected = false
			end,
		}
	end
	function s:Once(fn)
		local conn
		conn = self:Connect(function(...)
			conn:Disconnect()
			fn(...)
		end)
		return conn
	end
	function s:Fire(...)
		local list = {}
		for _, entry in ipairs(self.handlers) do
			table.insert(list, entry)
		end
		for _, entry in ipairs(list) do
			if entry.on then
				entry.fn(...)
			end
		end
	end
	function s:Wait()
		return nil
	end
	return s
end

--------------------------------------------------------------------------------
-- The scheduler (task.*)
--------------------------------------------------------------------------------
local timers = {}
local task = {}
function task.delay(t, fn, ...)
	local args = table.pack(...)
	table.insert(timers, { at = now.t + (t or 0), fn = fn, args = args })
	return #timers
end
function task.defer(fn, ...)
	return task.delay(0, fn, ...)
end
function task.spawn(fn, ...)
	fn(...)
end
function task.wait()
	return 0
end
function task.cancel() end
local function runTimers()
	local ran = true
	while ran do
		ran = false
		for index, timer in ipairs(timers) do
			if timer.at <= now.t then
				table.remove(timers, index)
				timer.fn(table.unpack(timer.args, 1, timer.args.n))
				ran = true
				break
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------
local I = {}
local BASEPART = { Part = true, Seat = true, VehicleSeat = true, MeshPart = true, WedgePart = true }
local EVENTS = {
	Touched = true, Destroying = true, Died = true, Triggered = true, OnServerEvent = true, OnClientEvent = true,
	AncestryChanged = true, ChildAdded = true, ChildRemoved = true, CharacterAdded = true, CharacterRemoving = true,
	PlayerAdded = true, PlayerRemoving = true, Heartbeat = true, Stepped = true, RenderStepped = true,
	StateChanged = true, HealthChanged = true, PromptShown = true, PromptHidden = true,
}
local DEFAULTS = {
	CanCollide = true, CanQuery = true, CanTouch = true, Anchored = false, Massless = false, Transparency = 0,
	AssemblyMass = 900, Enabled = true,
}

local function raw(inst)
	return rawget(inst, "_r")
end

local function isA(inst, class)
	local c = raw(inst).ClassName
	if class == "Instance" or class == c then
		return true
	end
	if class == "BasePart" then
		return BASEPART[c] == true
	end
	if class == "Seat" then
		return c == "Seat"
	end
	return false
end

local imethods = {}
function imethods.IsA(inst, class)
	return isA(inst, class)
end
function imethods.GetChildren(inst)
	local out = {}
	for _, child in ipairs(raw(inst).children) do
		table.insert(out, child)
	end
	return out
end
function imethods.GetDescendants(inst)
	local out = {}
	local function walk(node)
		for _, child in ipairs(raw(node).children) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(inst)
	return out
end
function imethods.FindFirstChild(inst, name)
	for _, child in ipairs(raw(inst).children) do
		if raw(child).props.Name == name then
			return child
		end
	end
	return nil
end
function imethods.WaitForChild(inst, name)
	return inst:FindFirstChild(name)
end
function imethods.FindFirstChildOfClass(inst, class)
	for _, child in ipairs(raw(inst).children) do
		if raw(child).ClassName == class then
			return child
		end
	end
	return nil
end
function imethods.FindFirstChildWhichIsA(inst, class)
	for _, child in ipairs(raw(inst).children) do
		if isA(child, class) then
			return child
		end
	end
	return nil
end
function imethods.FindFirstAncestorOfClass(inst, class)
	local node = raw(inst).props.Parent
	while node do
		if raw(node).ClassName == class then
			return node
		end
		node = raw(node).props.Parent
	end
	return nil
end
function imethods.FindFirstAncestorWhichIsA(inst, class)
	local node = raw(inst).props.Parent
	while node do
		if isA(node, class) then
			return node
		end
		node = raw(node).props.Parent
	end
	return nil
end
function imethods.IsDescendantOf(inst, other)
	local node = raw(inst).props.Parent
	while node do
		if node == other then
			return true
		end
		node = raw(node).props.Parent
	end
	return false
end
function imethods.GetAttribute(inst, name)
	return raw(inst).attributes[name]
end
function imethods.SetAttribute(inst, name, value)
	raw(inst).attributes[name] = value
end
function imethods.GetAttributes(inst)
	return raw(inst).attributes
end
function imethods.GetAttributeChangedSignal(inst, name)
	local r = raw(inst)
	r.attrSignals[name] = r.attrSignals[name] or signal()
	return r.attrSignals[name]
end
function imethods.GetPropertyChangedSignal(inst, name)
	local r = raw(inst)
	r.propSignals[name] = r.propSignals[name] or signal()
	return r.propSignals[name]
end
function imethods.Destroy(inst)
	local r = raw(inst)
	if r.destroyed then
		return
	end
	r.destroyed = true
	inst.Destroying:Fire()
	for _, child in ipairs(inst:GetChildren()) do
		child:Destroy()
	end
	inst.Parent = nil
end
function imethods.ClearAllChildren(inst)
	for _, child in ipairs(inst:GetChildren()) do
		child:Destroy()
	end
end
function imethods.Clone(inst)
	return inst
end
-- Parts
function imethods.SetNetworkOwner(inst, player)
	if inst.Anchored then
		error("Network Ownership API cannot be called on Anchored parts")
	end
	raw(inst).owner = player
	raw(inst).ownerSet = true
end
function imethods.GetNetworkOwner(inst)
	return raw(inst).owner
end
function imethods.GetNetworkOwnershipAuto(inst)
	return not raw(inst).ownerSet
end
function imethods.GetMass()
	return 900
end
function imethods.ApplyImpulse(inst, impulse)
	inst.AssemblyLinearVelocity = inst.AssemblyLinearVelocity + impulse / 900
end
function imethods.ApplyAngularImpulse() end
-- Models
function imethods.GetPivot(inst)
	local r = raw(inst)
	if r.ClassName ~= "Model" then
		return inst.CFrame
	end
	local primary = r.props.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
	return primary and primary.CFrame or CFrame.new(0, 0, 0)
end
function imethods.PivotTo(inst, target)
	local r = raw(inst)
	if r.ClassName ~= "Model" then
		inst.CFrame = target
		return
	end
	local delta = target * inst:GetPivot():Inverse()
	for _, part in ipairs(inst:GetDescendants()) do
		if isA(part, "BasePart") then
			part.CFrame = delta * part.CFrame
		end
	end
end
function imethods.GetExtentsSize(inst)
	local primary = raw(inst).props.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
	return primary and primary.Size or Vector3.one
end
function imethods.GetBoundingBox(inst)
	return inst:GetPivot(), inst:GetExtentsSize()
end
-- Seats and humanoids
function imethods.Sit(seat, humanoid)
	if seat.Occupant or not humanoid then
		return
	end
	raw(humanoid).props.SeatPart = seat
	raw(humanoid).props.Sit = true
	seat.Occupant = humanoid
end
function imethods.TakeDamage(humanoid, amount)
	humanoid.Health = math.max(0, humanoid.Health - amount)
end
function imethods.ChangeState(humanoid, state)
	table.insert(raw(humanoid).states, state)
end
function imethods.GetState()
	return "Running"
end
-- Remotes (server side; the client side is the check's own)
function imethods.FireClient(remote, player, ...)
	table.insert(raw(remote).world.sent, { remote = remote.Name, player = player, args = table.pack(...) })
end
function imethods.FireAllClients(remote, ...)
	table.insert(raw(remote).world.sent, { remote = remote.Name, all = true, args = table.pack(...) })
end

local world = { sent = {}, parts = {} }

local function setProp(inst, key, value)
	local r = raw(inst)
	local props = r.props
	if key == "Parent" then
		local old = props.Parent
		if old == value then
			return
		end
		if old then
			local kids = raw(old).children
			for index, child in ipairs(kids) do
				if child == inst then
					table.remove(kids, index)
					break
				end
			end
		end
		props.Parent = value
		if value then
			table.insert(raw(value).children, inst)
		end
		inst.AncestryChanged:Fire(inst, value)
		return
	end
	if key == "Position" and BASEPART[r.ClassName] then
		local c = props.CFrame
		props.CFrame = cf(value, c.x, c.y, c.z)
		return
	end
	if key == "Health" and r.ClassName == "Humanoid" then
		local before = props.Health
		value = math.max(0, math.min(value, props.MaxHealth or 100))
		props.Health = value
		if before > 0 and value <= 0 then
			inst.Died:Fire()
		end
		return
	end
	if key == "Sit" and r.ClassName == "Humanoid" and value == false and props.SeatPart then
		local seatPart = props.SeatPart
		props.SeatPart = nil
		props.Sit = false
		seatPart.Occupant = nil
		return
	end
	-- A character's root carries the rest of it (its Motor6Ds, in Roblox).
	if key == "CFrame" and props.Name == "HumanoidRootPart" and props.Parent and props.CFrame then
		local delta = value.p - props.CFrame.p
		for _, part in ipairs(raw(props.Parent).children) do
			if part ~= inst and BASEPART[raw(part).ClassName] then
				local c = raw(part).props.CFrame
				raw(part).props.CFrame = cf(c.p + delta, c.x, c.y, c.z)
			end
		end
	end
	local before = props[key]
	props[key] = value
	if before ~= value and r.propSignals[key] then
		r.propSignals[key]:Fire()
	end
end

I.__index = function(inst, key)
	local r = raw(inst)
	if key == "ClassName" then
		return r.ClassName
	elseif key == "Position" and BASEPART[r.ClassName] then
		return r.props.CFrame.p
	end
	local v = r.props[key]
	if v ~= nil then
		return v
	end
	if imethods[key] then
		return imethods[key]
	end
	if EVENTS[key] then
		r.events[key] = r.events[key] or signal()
		return r.events[key]
	end
	-- A child by name, as model.HumanoidRootPart reads in Roblox.
	for _, child in ipairs(r.children) do
		if raw(child).props.Name == key then
			return child
		end
	end
	if key == "AssemblyLinearVelocity" or key == "AssemblyAngularVelocity" then
		return Vector3.zero
	end
	return DEFAULTS[key]
end
I.__newindex = function(inst, key, value)
	setProp(inst, key, value)
end
I.__tostring = function(inst)
	return raw(inst).props.Name or raw(inst).ClassName
end

local function new(class, parent)
	local inst = setmetatable({
		_r = {
			ClassName = class,
			props = { Name = class },
			children = {},
			attributes = {},
			attrSignals = {},
			propSignals = {},
			events = {},
			states = {},
			world = world,
		},
	}, I)
	if BASEPART[class] then
		raw(inst).props.CFrame = CFrame.new(0, 0, 0)
		raw(inst).props.Size = Vector3.new(1, 1, 1)
	end
	if class == "Humanoid" then
		raw(inst).props.Health = 100
		raw(inst).props.MaxHealth = 100
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
local Instance = { new = new }

local function typeof(value)
	local meta = getmetatable(value)
	if meta == V then
		return "Vector3"
	elseif meta == C then
		return "CFrame"
	elseif meta == I then
		return "Instance"
	end
	return type(value)
end

--------------------------------------------------------------------------------
-- The DataModel
--------------------------------------------------------------------------------
local workspace = new("Workspace")
workspace.Name = "Workspace"
workspace.Gravity = 196.2
local terrain = new("Terrain", workspace)
terrain.Name = "Terrain"
workspace.Terrain = terrain

local function excluded(part, params)
	if not params or not params.FilterDescendantsInstances then
		return false
	end
	for _, root in ipairs(params.FilterDescendantsInstances) do
		if part == root or part:IsDescendantOf(root) then
			return true
		end
	end
	return false
end

-- The ground is the plane y = 0, everywhere; nothing else is solid to a ray.
function imethods.Raycast(_, origin, direction)
	if direction.Y >= 0 or origin.Y < 0 then
		return nil
	end
	local t = origin.Y / -direction.Y
	if t > 1 then
		return nil
	end
	local hit = origin + direction * t
	return { Position = hit, Distance = (hit - origin).Magnitude, Normal = Vector3.yAxis, Instance = terrain,
		Material = "Asphalt" }
end
-- Every part in the workspace whose box overlaps the query box (both taken as boxes along the query's
-- own axes, which is exact here: nothing in these scenes is turned).
function imethods.GetPartBoundsInBox(_, frame, size, params)
	local out = {}
	for _, part in ipairs(workspace:GetDescendants()) do
		if isA(part, "BasePart") and part.CanQuery ~= false and not excluded(part, params) then
			local here = frame:PointToObjectSpace(part.Position)
			local half = part.Size / 2
			if math.abs(here.X) <= size.X / 2 + half.X and math.abs(here.Y) <= size.Y / 2 + half.Y
				and math.abs(here.Z) <= size.Z / 2 + half.Z then
				table.insert(out, part)
			end
		end
	end
	return out
end
function imethods.GetPartBoundsInRadius()
	return {}
end
function imethods.GetServerTimeNow()
	return now.t
end

local players = new("Players")
players.Name = "Players"
function imethods.GetPlayers(self)
	if self ~= players then
		return {}
	end
	return self:GetChildren()
end
function imethods.GetPlayerFromCharacter(self, character)
	if self ~= players then
		return nil
	end
	for _, p in ipairs(self:GetChildren()) do
		if p.Character == character and character ~= nil then
			return p
		end
	end
	return nil
end
function imethods.GetPlayerByUserId(self, id)
	for _, p in ipairs(self:GetChildren()) do
		if p.UserId == id then
			return p
		end
	end
	return nil
end

local replicatedStorage = new("ReplicatedStorage")
replicatedStorage.Name = "ReplicatedStorage"
local runService = new("RunService")
function imethods.IsServer(self)
	return raw(self).clientSide ~= true
end
function imethods.IsClient(self)
	return raw(self).clientSide == true
end
function imethods.IsStudio()
	return false
end
function imethods.IsRunning()
	return true
end

-- Module references: script.Parent:WaitForChild("X") and Shared:WaitForChild("X") both hand one back.
local refMeta = {}
refMeta.__index = function(ref, key)
	if key == "WaitForChild" or key == "FindFirstChild" then
		return function(_, name)
			return setmetatable({ __module = name }, refMeta)
		end
	end
	return nil
end
local folder = setmetatable({ __module = "(folder)" }, refMeta)
-- ReplicatedStorage:WaitForChild("Shared") is the modules' folder; "Remotes" is a real child.
local rsWait = imethods.WaitForChild
function imethods.WaitForChild(inst, name)
	if inst == replicatedStorage and name == "Shared" then
		return folder
	end
	return rsWait(inst, name)
end

local services = { Workspace = workspace, Players = players, ReplicatedStorage = replicatedStorage, RunService = runService }
local game = setmetatable({
	GetService = function(_, name)
		return services[name] or proxy(name)
	end,
}, { __index = function(t, k)
	local p = proxy("game." .. k)
	rawset(t, k, p)
	return p
end })
game.Workspace = workspace

--------------------------------------------------------------------------------
-- Stand-in modules
--------------------------------------------------------------------------------
local W = { launches = {}, shield = {}, dynamicsSteps = 0, handling = nil }

local function withProxy(t, name)
	return setmetatable(t, { __index = function(_, k)
		return proxy(name .. "." .. tostring(k))
	end })
end

local VehicleDynamics = withProxy({}, "VehicleDynamics")
VehicleDynamics.Handling = {}
-- A rig: the chassis, the real handling, four wheels on the ground and the downforce actuator the rest
-- hold turns upward. Nil for a model with no Chassis (the service then builds its own stand-in).
function VehicleDynamics.Rig(model)
	local chassis = model:FindFirstChild("Chassis")
	if not chassis then
		return nil
	end
	local id = model:GetAttribute("VehicleModel")
	local handling = VehicleDynamics.Handling[id]
	local wheels = {}
	for _ = 1, 4 do
		table.insert(wheels, { grounded = true, compression = handling.travelDown, normal = Vector3.yAxis })
	end
	return { model = model, chassis = chassis, handling = handling, wheels = wheels,
		downforce = { Force = Vector3.zero }, bike = model:GetAttribute("VehicleKind") == "bike", lean = 0 }
end
function VehicleDynamics.Step()
	W.dynamicsSteps = W.dynamicsSteps + 1
	return { flippedFor = 0 }
end
function VehicleDynamics.Idle() end
function VehicleDynamics.SetIgnore() end
function VehicleDynamics.Right() end

-- VehicleModels: a box body per model id, seats beside the middle. `kinds` is filled by the check from
-- the real VehicleModels (id -> kind, displayName).
local VehicleModels = withProxy({ Models = {} }, "VehicleModels")
function VehicleModels.Pick(kind)
	for id, def in pairs(VehicleModels.Models) do
		if def.kind == kind then
			return id
		end
	end
	return nil
end
function VehicleModels.Build(modelId)
	local def = VehicleModels.Models[modelId]
	local bike = def.kind == "bike"
	local model = new("Model")
	model.Name = modelId
	model:SetAttribute("VehicleModel", modelId)
	model:SetAttribute("VehicleKind", def.kind)
	local chassis = new("Part", model)
	chassis.Name = "Chassis"
	chassis.Size = bike and Vector3.new(2, 2.5, 6) or Vector3.new(6, 2.5, 12)
	chassis.CFrame = CFrame.new(0, 2, 0)
	model.PrimaryPart = chassis
	local seats = { driver = CFrame.new(bike and 0 or -1.4, 3.6, bike and 0.5 or -1), passengers = {} }
	table.insert(seats.passengers, CFrame.new(bike and 0 or 1.4, 3.6, bike and 2 or -1))
	if not bike then
		table.insert(seats.passengers, CFrame.new(-1.4, 3.6, 2.5))
	end
	return model, { chassis = chassis, kind = def.kind, displayName = def.displayName, modelId = modelId, seats = seats,
		exits = {}, hulls = {} }
end

local WeaponService = withProxy({}, "WeaponService")
function WeaponService.GetShield(token)
	return W.shield[token] or 0
end
-- A shield per token (W.shield), soaked first.
function WeaponService.AbsorbDamage(token, amount)
	local shield = W.shield[token] or 0
	local absorbed = math.min(shield, amount)
	W.shield[token] = shield - absorbed
	return amount - absorbed, absorbed
end

local MovementService = withProxy({}, "MovementService")
function MovementService.Launch(character, velocity, kind)
	table.insert(W.launches, { character = character, velocity = velocity, kind = kind })
end

local mocks = {
	VehicleDynamics = VehicleDynamics,
	VehicleModels = VehicleModels,
	WeaponService = WeaponService,
	MovementService = MovementService,
	WeaponData = withProxy({ Get = function()
		return nil
	end }, "WeaponData"),
	ItemData = withProxy({ Get = function()
		return nil
	end }, "ItemData"),
}
local REAL = {
	VehicleService = true, CombatService = true, RoadkillPass = true, Combatants = true, RateLimit = true,
	Remotes = true, SafeValue = true, VehicleArmor = true, VehicleCover = true, MatchConfig = true,
	MovementConfig = true,
}

--------------------------------------------------------------------------------
-- The loader
--------------------------------------------------------------------------------
local loaded = {}
local env
local function requireRef(ref)
	local name = type(ref) == "table" and rawget(ref, "__module") or nil
	if not name then
		return proxy("require(?)")
	end
	if mocks[name] then
		return mocks[name]
	end
	if loaded[name] ~= nil then
		return loaded[name]
	end
	if not REAL[name] then
		loaded[name] = proxy(name)
		return loaded[name]
	end
	local text = source(name)
	if not text then
		error("no source for real module " .. name)
	end
	local moduleEnv = setmetatable({ script = { Parent = folder, Name = name } }, { __index = env })
	local compiled = assert(compile(text, name, "t", moduleEnv))
	loaded[name] = compiled()
	return loaded[name]
end

local warnings = {}
local function clock()
	return now.t
end
env = setmetatable({
	game = game,
	workspace = workspace,
	Vector3 = Vector3,
	CFrame = CFrame,
	Instance = Instance,
	RaycastParams = { new = function()
		return { FilterDescendantsInstances = {} }
	end },
	OverlapParams = { new = function()
		return { FilterDescendantsInstances = {} }
	end },
	Random = { new = function()
		return { NextNumber = function(_, a, b)
			return ((a or 0) + (b or 1)) / 2
		end, NextInteger = function(_, a)
			return a
		end }
	end },
	DateTime = { now = function()
		return { UnixTimestampMillis = math.floor(now.t * 1000) }
	end },
	Enum = setmetatable({}, { __index = function(t, k)
		local p = proxy("Enum." .. k)
		rawset(t, k, p)
		return p
	end }),
	typeof = typeof,
	require = requireRef,
	warn = function(...)
		local parts = {}
		for _, v in ipairs({ ... }) do
			table.insert(parts, tostring(v))
		end
		table.insert(warnings, table.concat(parts, " "))
	end,
	print = function() end,
	tick = clock,
	time = clock,
	os = setmetatable({ clock = clock }, { __index = os }),
	task = task,
	math = setmetatable({
		clamp = function(x, lo, hi)
			return math.max(lo, math.min(hi, x))
		end,
		sign = function(x)
			return x > 0 and 1 or x < 0 and -1 or 0
		end,
		round = function(x)
			return math.floor(x + 0.5)
		end,
	}, { __index = math }),
	table = setmetatable({
		find = function(t, value)
			for i, v in ipairs(t) do
				if v == value then
					return i
				end
			end
			return nil
		end,
		clone = function(t)
			local out = {}
			for k, v in pairs(t) do
				out[k] = v
			end
			return out
		end,
		freeze = function(t)
			return t
		end,
	}, { __index = table }),
}, { __index = function(_, k)
	local v = _G[k]
	if v ~= nil then
		return v
	end
	return proxy(k)
end })

local function module(name)
	return requireRef(setmetatable({ __module = name }, refMeta))
end

-- Loads a cut of game text (a function or two lifted from a file) in the world's environment, with
-- `upvalues` as its globals on top.
local function chunk(text, name, upvalues)
	local e = setmetatable(upvalues or {}, { __index = env })
	return assert(compile(text, name, "t", e))()
end

return {
	now = now,
	W = W,
	world = world,
	env = env,
	proxy = proxy,
	Vector3 = Vector3,
	CFrame = CFrame,
	Instance = Instance,
	workspace = workspace,
	players = players,
	runService = runService,
	replicatedStorage = replicatedStorage,
	signal = signal,
	runTimers = runTimers,
	module = module,
	chunk = chunk,
	warnings = warnings,
	VehicleDynamics = VehicleDynamics,
	VehicleModels = VehicleModels,
	raw = raw,
}
