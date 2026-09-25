-- The world tools/explosive_dispatch_check.py runs the game's REAL modules in (lupa, plain Lua 5.x). Not
-- loaded by the game.
--
-- It loads CombatService, ProjectileService and VehicleWeapons whole, with the real WeaponData (every
-- pack merged), Ballistics (with CreativeRounds' kinds), VehicleWeaponData, MountedGunData, VehicleCover,
-- SafeValue and MatchConfig. Everything else a module requires is either a small recorder below
-- (Combatants, LagCompensation, WeaponService, Remotes, VehicleService, ...) or an inert stand-in that
-- swallows any call. Blasts are counted where every blast in the game announces itself: ProjectileService's
-- explode() broadcasts "detonate" before it deals any damage, so the count is taken on the real path.
--
-- Called as world(M, source, realModules, compile) where M is tools/hitreg_mocks.lua, source(name) hands
-- back a module's Lua text (already converted from Luau) or nil, realModules names the modules to load for
-- real, and compile is plain Lua's `load` (passed in: this file is read as Luau by the static checks).

local M, source, realModules, compile = ...

--------------------------------------------------------------------------------
-- Inert stand-ins
--------------------------------------------------------------------------------
local proxyMeta = {}
local function proxy(name)
	return setmetatable({ __proxy = name }, proxyMeta)
end
proxyMeta.__index = function(t, k)
	-- A number key is nil, so `ipairs` over a stand-in ends at once instead of running forever.
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
for _, op in ipairs({ "__add", "__sub", "__mul", "__div", "__unm", "__mod", "__pow", "__concat" }) do
	proxyMeta[op] = function(a)
		return a
	end
end
proxyMeta.__lt = function()
	return false
end
proxyMeta.__le = function()
	return false
end
proxyMeta.__len = function()
	return 0
end
proxyMeta.__tostring = function(t)
	return "<" .. rawget(t, "__proxy") .. ">"
end

--------------------------------------------------------------------------------
-- Roblox globals the loaded modules touch
--------------------------------------------------------------------------------
local Vector3 = M.Vector3
local V = getmetatable(Vector3.new(0, 0, 0))
local baseIndex = V.__index
V.__index = function(v, key)
	if key == "Cross" then
		return function(a, b)
			return Vector3.new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
		end
	elseif key == "Lerp" then
		return function(a, b, t)
			return a + (b - a) * t
		end
	elseif key == "Abs" then
		return function(a)
			return Vector3.new(math.abs(a.X), math.abs(a.Y), math.abs(a.Z))
		end
	elseif key == "Max" then
		return function(a, b)
			return Vector3.new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
		end
	elseif key == "Min" then
		return function(a, b)
			return Vector3.new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
		end
	end
	return baseIndex(v, key)
end
V.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.zAxis = Vector3.new(0, 0, 1)
Vector3.one = Vector3.new(1, 1, 1)

local vectorMeta = V
local cframeMeta = getmetatable(M.CFrame.new(0, 0, 0))
local instanceMeta = getmetatable(M.workspace)
local cframeIndex = cframeMeta.__index
cframeMeta.__index = function(c, key)
	if key == "PointToWorldSpace" then
		return function(self, v)
			return self * v
		end
	end
	return cframeIndex(c, key)
end

local function typeof(value)
	local meta = getmetatable(value)
	if meta == vectorMeta then
		return "Vector3"
	elseif meta == cframeMeta then
		return "CFrame"
	elseif meta == instanceMeta then
		return "Instance"
	elseif meta == proxyMeta then
		return "userdata"
	end
	return type(value)
end

math.clamp = function(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end
math.atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end
math.sign = function(x)
	return x > 0 and 1 or x < 0 and -1 or 0
end
math.round = function(x)
	return math.floor(x + 0.5)
end
table.clone = function(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return setmetatable(out, getmetatable(t))
end
table.find = function(t, value)
	for i, v in ipairs(t) do
		if v == value then
			return i
		end
	end
	return nil
end
table.freeze = function(t)
	return t
end
table.create = function(n, value)
	local out = {}
	for i = 1, n do
		out[i] = value
	end
	return out
end

-- The clock: every module's clock is this one, moved by the harness.
local now = { t = 1000 }

local ws = rawget(M.workspace, "_props")
ws.Gravity = 196.2
ws.GetServerTimeNow = function()
	return now.t
end
-- An Include ray (a blast's line of sight: Terrain, Map, Defenses) sees only the map, which here is the
-- harness's boxes (M.walls), never a body.
local worldRaycast = ws.Raycast
ws.Raycast = function(self, origin, vector, params)
	if params and params.FilterType == "Include" then
		local kids = rawget(M.workspace, "_children")
		rawset(M.workspace, "_children", {})
		local result = worldRaycast(self, origin, vector, { FilterDescendantsInstances = {} })
		rawset(M.workspace, "_children", kids)
		return result
	end
	return worldRaycast(self, origin, vector, params)
end
ws.Spherecast = function(self, origin, _radius, vector, params)
	return ws.Raycast(self, origin, vector, params)
end
ws.GetPartBoundsInRadius = function()
	return {}
end
ws.GetPartsInPart = function()
	return {}
end
ws.Terrain = proxy("Terrain")
ws.CurrentCamera = proxy("Camera")

-- Every mocked instance also answers the Roblox members these modules ask for: attributes, a child by
-- class, the signals (inert), and CanCollide defaulting to true as a Part's does.
local extra = {}
function extra.GetAttribute(self, name)
	local a = rawget(self, "_attributes")
	return a and a[name] or nil
end
function extra.SetAttribute(self, name, value)
	local a = rawget(self, "_attributes") or {}
	rawset(self, "_attributes", a)
	a[name] = value
end
function extra.FindFirstChildOfClass(self, class)
	for _, child in ipairs(rawget(self, "_children")) do
		if child.ClassName == class then
			return child
		end
	end
	return nil
end
function extra.TakeDamage(self, amount)
	self.Health = math.max(0, (self.Health or 0) - amount)
end
function extra.GetAttributeChangedSignal()
	return proxy("Signal")
end
local instanceIndex = instanceMeta.__index
instanceMeta.__index = function(inst, key)
	local v = instanceIndex(inst, key)
	if v ~= nil then
		return v
	end
	if extra[key] then
		return extra[key]
	elseif key == "CanCollide" then
		return true
	elseif key == "AssemblyLinearVelocity" then
		return Vector3.new(0, 0, 0)
	elseif key == "AncestryChanged" or key == "Destroying" or key == "ChildAdded" or key == "ChildRemoved" then
		return proxy(key)
	end
	return nil
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

local recorders = {
	fired = {}, -- Remotes: { event, action, info }
}
local function remoteEvent(name)
	return {
		FireAllClients = function(_, action, info)
			table.insert(recorders.fired, { event = name, action = action, info = info })
		end,
		FireClient = function() end,
		OnServerEvent = proxy("OnServerEvent"),
	}
end
local remotes = { events = {} }
remotes.Event = function(name)
	remotes.events[name] = remotes.events[name] or remoteEvent(name)
	return remotes.events[name]
end
remotes.Function = function(name)
	return proxy("RemoteFunction " .. name)
end

local services = {
	ReplicatedStorage = setmetatable({ __module = "ReplicatedStorage" }, refMeta),
	RunService = setmetatable({
		IsRunning = function()
			return true
		end,
		IsStudio = function()
			return false
		end,
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
	}, { __index = function(t, k)
		local p = proxy("RunService." .. k)
		rawset(t, k, p)
		return p
	end }),
	Players = setmetatable({
		GetPlayers = function()
			return {}
		end,
	}, { __index = function(t, k)
		local p = proxy("Players." .. k)
		rawset(t, k, p)
		return p
	end }),
}
local game = setmetatable({
	GetService = function(_, name)
		return services[name] or proxy(name)
	end,
}, { __index = function(t, k)
	local p = proxy("game." .. k)
	rawset(t, k, p)
	return p
end })

--------------------------------------------------------------------------------
-- Stand-in server modules: just what the fire and blast paths ask of them
--------------------------------------------------------------------------------
local W = { tokens = {}, humanoids = {}, team = {}, equipped = nil, dealt = {}, vehicleHits = {}, wallHits = {} }

local Combatants = {}
function Combatants.FromCharacter(model)
	return W.tokens[model]
end
function Combatants.IsAlive(token)
	local humanoid = token ~= nil and W.humanoids[token]
	return humanoid ~= nil and humanoid ~= false and humanoid.Health > 0
end
function Combatants.GetCharacter(token)
	return type(token) == "table" and token.Character or nil
end
function Combatants.GetRoot(token)
	local c = Combatants.GetCharacter(token)
	return c and c:FindFirstChild("HumanoidRootPart")
end
function Combatants.GetHumanoid(token)
	return W.humanoids[token]
end
function Combatants.IsPlayer(token)
	return type(token) == "table" and token.isPlayer == true
end
function Combatants.GetName(token)
	return type(token) == "table" and token.name or nil
end
function Combatants.Exists(token)
	return token ~= nil
end
function Combatants.All()
	local out = {}
	for character, token in pairs(W.tokens) do
		out[character] = token
	end
	return out
end

local LagCompensation = {
	RewindTime = function()
		return nil
	end,
	Now = function()
		return now.t
	end,
	Raycast = function(origin, vector, params)
		return M.workspace:Raycast(origin, vector, params)
	end,
}

local loadout = { fireCredit = 2, lastShotAt = 0 }
local WeaponService = {
	Get = function()
		return loadout
	end,
	GetEquipped = function()
		return W.equipped
	end,
	IsReady = function()
		return true
	end,
	ConsumeAmmo = function()
		return true
	end,
	Shields = {},
	-- No shield on anyone here: the whole hit reaches health.
	AbsorbDamage = function(_, amount)
		return amount, 0
	end,
	StartUse = function()
		return false
	end,
}

local VehicleService = {
	BlastDamage = function(blast)
		table.insert(W.vehicleHits, { how = "blast", weaponId = blast.weaponId, position = blast.position })
	end,
}

local mocks = {
	DestructibleService = { GlassName = "WindowGlass" },
	Remotes = remotes,
	Combatants = Combatants,
	LagCompensation = LagCompensation,
	WeaponService = WeaponService,
	VehicleService = VehicleService,
}

--------------------------------------------------------------------------------
-- The loader
--------------------------------------------------------------------------------
local real = {}
for _, name in ipairs(realModules) do
	real[name] = true
end
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
	if not real[name] then
		loaded[name] = proxy(name)
		return loaded[name]
	end
	local text = source(name)
	if not text then
		error("no source for real module " .. name)
	end
	local moduleEnv = setmetatable({ script = { Parent = folder, Name = name } }, { __index = env })
	local chunk = assert(compile(text, name, "t", moduleEnv))
	loaded[name] = proxy(name .. "(loading)")
	loaded[name] = chunk()
	return loaded[name]
end

local warnings = {}
env = setmetatable({
	game = game,
	workspace = M.workspace,
	Vector3 = Vector3,
	CFrame = M.CFrame,
	RaycastParams = M.RaycastParams,
	OverlapParams = { new = function()
		return {}
	end },
	Enum = setmetatable(M.Enum, { __index = function(t, k)
		local p = proxy("Enum." .. k)
		rawset(t, k, p)
		return p
	end }),
	typeof = typeof,
	require = requireRef,
	warn = function(...)
		table.insert(warnings, table.concat({ ... }, " "))
	end,
	tick = function()
		return now.t
	end,
	time = function()
		return now.t
	end,
	os = setmetatable({ clock = function()
		return now.t
	end }, { __index = os }),
	task = proxy("task"),
	Instance = proxy("Instance"),
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

return {
	M = M,
	W = W,
	now = now,
	proxy = proxy,
	module = module,
	recorders = recorders,
	warnings = warnings,
	loadout = loadout,
}
