-- Just enough of a Roblox client to run StarterPlayerScripts/GunnerView.lua (Start, Update, AimPoint)
-- under plain Lua (lupa), for tools/gunner_aim_world_check.py. The value types (Vector3, Vector2,
-- CFrame: real rotation matrices) come first, from tools/destruct_mocks.lua's section, prepended by the
-- check. Everything drawn (the sight, the arms) is a sink that takes any property; the world has no
-- geometry (every raycast misses); the mouse delta is whatever the check sets.
--
-- Returns a table:
--   rig()                 -> vehicle, chassis   a turret on a chassis part, the parts GunnerView.Start reads
--   setMouse(dx, dy)      the mouse delta the next frames read
--   load(name, source)    a ModuleScript's source, run once and handed to require by name
-- static-check: globals load

math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end

-- Enum.A.B is the string "A.B"; comparisons against it work as Roblox's own enums would.
-- CFrame:Lerp, which the borrowed CFrame lacks: the position lerped, the rotation the nearer end's
-- (the check never aims down the sight, so the view's lerp is always at 0).
do
	local C = getmetatable(CFrame.new())
	function C.Lerp(a, b, t)
		if t <= 0 then return a end
		if t >= 1 then return b end
		local r = t < 0.5 and a or b
		return (r - r.Position) + a.Position:Lerp(b.Position, t)
	end
end

Enum = setmetatable({}, { __index = function(_, a)
	return setmetatable({}, { __index = function(_, b) return a .. "." .. b end })
end })

UDim = { new = function(s, o) return { s, o } end }
UDim2 = {
	new = function(...) return { ... } end,
	fromOffset = function(x, y) return { 0, x, 0, y } end,
	fromScale = function(x, y) return { x, 0, y, 0 } end,
}
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end }

local function signal()
	return { Connect = function() return { Disconnect = function() end } end }
end

-- A drawn thing: takes any property, answers any method with nothing.
local function sink(name)
	return setmetatable({ Name = name }, { __index = function(_, key)
		if key == "GetChildren" or key == "GetDescendants" then
			return function() return {} end
		end
		return function() return nil end
	end })
end
Instance = { new = function(class, parent) return sink(class) end }
RaycastParams = { new = function() return {} end }

local mouseDelta = Vector2.new(0, 0)
local UserInputService = {
	MouseBehavior = "MouseBehavior.Default",
	InputChanged = signal(),
	GetMouseDelta = function() return mouseDelta end,
}
local player = {
	Name = "Gunner",
	attributes = {},
	GetAttribute = function(self, k) return self.attributes[k] end,
	SetAttribute = function(self, k, v) self.attributes[k] = v end,
	WaitForChild = function(_, name) return sink(name) end,
}
local camera = {
	CFrame = CFrame.new(),
	FieldOfView = 70,
	CameraType = "CameraType.Custom",
	WorldToViewportPoint = function() return Vector3.new(0, 0, 0), false end,
}
workspace = {
	CurrentCamera = camera,
	Gravity = 196.2,
	Raycast = function() return nil end,
	BulkMoveTo = function() end,
	FindFirstChild = function() return nil end,
}

-- ModuleScripts by name: a marker from WaitForChild, its table from require.
local modules = {}
local function folder(name)
	return { Name = name, WaitForChild = function(_, child) return { module = child } end }
end
local services = {
	Players = { LocalPlayer = player },
	ReplicatedStorage = { WaitForChild = function(_, name) return folder(name) end },
	RunService = { RenderStepped = signal(), Heartbeat = signal() },
	UserInputService = UserInputService,
}
game = { GetService = function(_, name) return services[name] end }
script = { Parent = folder("StarterPlayerScripts") }
function require(marker)
	local found = modules[marker.module]
	if found == nil then
		error("no module " .. tostring(marker.module))
	end
	return found
end

modules.Ballistics = {
	Rounds = {},
	RoundState = function(round, origin, direction, gravity, t)
		return origin + direction * ((round.speed or 200) * t)
	end,
}
local arms = {
	pose = function() end,
	SetHidden = function() end,
}
modules.Viewmodel = { Arms = { new = function() return arms end } }

local M = {}

function M.load(name, source)
	local chunk = assert(load(source, "=" .. name))
	modules[name] = chunk()
	return modules[name]
end

function M.setMouse(dx, dy)
	mouseDelta = Vector2.new(dx, dy)
end

M.camera = camera

-- A part with a CFrame (and Position read off it) and named children.
local function part(name, cframe, children)
	local self = { Name = name, CFrame = cframe, children = children or {} }
	return setmetatable(self, { __index = function(t, key)
		if key == "Position" then return rawget(t, "CFrame").Position end
		if key == "FindFirstChild" then
			return function(s, n) return s.children[n] end
		end
		if key == "GetChildren" then
			return function(s)
				local out = {}
				for _, c in pairs(s.children) do table.insert(out, c) end
				return out
			end
		end
		if key == "IsA" then
			return function(_, class) return class == "BasePart" end
		end
		return nil
	end })
end

local function motor(part0, c0)
	return {
		Part0 = part0,
		C0 = c0,
		Transform = CFrame.new(),
		IsA = function(_, class) return class == "Motor6D" end,
	}
end

-- A turret as VehicleModels builds one, in round numbers: the yaw pivot 3 studs over the chassis, the
-- pitch pivot 0.8 up and 0.3 forward of it, the muzzle 3 studs down the barrel, the eye behind and over
-- the pitch pivot. Only the directions matter to the check; the geometry is a stand-in.
function M.rig()
	local chassis = part("Chassis", CFrame.new(0, 2, 0))
	local yawC0 = CFrame.new(0, 3, 0)
	local pitchC0 = CFrame.new(0, 0.8, -0.3)
	local yawJoint = motor(chassis, yawC0)
	local pitchFrame = chassis.CFrame * yawC0 * pitchC0
	local muzzle = part("TurretMuzzle", pitchFrame * CFrame.new(0, 0, -3))
	local pitchPart = part("TurretPitch", pitchFrame, {
		GunnerSight = { CFrame = CFrame.new(0, 0.35, 0.6) },
		GripR = { CFrame = CFrame.new(0.3, -0.1, 0.9) },
		GripL = { CFrame = CFrame.new(-0.3, -0.1, 0.9) },
	})
	pitchPart.children.Joint = motor(nil, pitchC0)
	local yawPart = part("TurretYaw", chassis.CFrame * yawC0, {
		Joint = yawJoint,
		GunnerEye = { CFrame = CFrame.new(0, 1.2, 1.4) },
	})
	local vehicle = part("Vehicle", chassis.CFrame, {
		TurretYaw = yawPart,
		TurretPitch = pitchPart,
		TurretMuzzle = muzzle,
	})
	vehicle.Parent = workspace
	return vehicle, chassis
end

return M
