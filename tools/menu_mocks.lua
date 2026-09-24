-- Roblox stand-ins for tools/menu_screens_check.py: enough of Instance, the datatypes, the services and
-- a GUI layout engine for the REAL MenuClient, MenuShell, UiKit, UiParts, ProgressionPanel and
-- MenuScreens to build the whole menu under plain Lua (lupa), be clicked through, and be measured.
--
-- What is modelled and what is not, because a harness is only as good as that line:
--   modelled   UDim2 sizing and positioning, AnchorPoint, UIPadding, UIListLayout (both directions,
--              all alignments, LayoutOrder), UIGridLayout, AutomaticSize from children, ScrollingFrame
--              canvases, UISizeConstraint, Visible, property-changed signals, Activated
--   estimated  text: a glyph is 0.55 of TextSize wide, a wrapped line 1.2 x TextSize tall, the same
--              in TextService:GetTextSize as in AutomaticSize. Good enough to find a label a whole
--              word too narrow; it cannot tell you a font's real kerning
--   ignored    UIScale (the whole panel scales together, so nothing moves relative to its parent),
--              UIAspectRatioConstraint, rendering, 3D. Model builders are stubs.

local M = {}

--------------------------------------------------------------------------------
-- Datatypes
--------------------------------------------------------------------------------

local function class(name, fields)
	local mt = { __type = name }
	mt.__index = fields or {}
	return mt
end

local V2 = class("Vector2")
local function Vector2new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2)
end
V2.__add = function(a, b) return Vector2new(a.X + b.X, a.Y + b.Y) end
V2.__sub = function(a, b) return Vector2new(a.X - b.X, a.Y - b.Y) end
V2.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return Vector2new(a.X * b, a.Y * b) end
	return Vector2new(a.X * b.X, a.Y * b.Y)
end
V2.__div = function(a, b)
	if type(b) == "number" then return Vector2new(a.X / b, a.Y / b) end
	return Vector2new(a.X / b.X, a.Y / b.Y)
end
V2.__unm = function(a) return Vector2new(-a.X, -a.Y) end
V2.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
V2.__index = function(self, key)
	if key == "Magnitude" then return math.sqrt(self.X ^ 2 + self.Y ^ 2) end
	if key == "Unit" then local m = math.sqrt(self.X ^ 2 + self.Y ^ 2); return m > 0 and Vector2new(self.X / m, self.Y / m) or Vector2new() end
	if key == "Lerp" then return function(a, b, t) return Vector2new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t) end end
	if key == "Dot" then return function(a, b) return a.X * b.X + a.Y * b.Y end end
	if key == "Min" then return function(a, b) return Vector2new(math.min(a.X, b.X), math.min(a.Y, b.Y)) end end
	if key == "Max" then return function(a, b) return Vector2new(math.max(a.X, b.X), math.max(a.Y, b.Y)) end end
	return nil
end
Vector2 = { new = Vector2new, zero = Vector2new(0, 0), one = Vector2new(1, 1), xAxis = Vector2new(1, 0), yAxis = Vector2new(0, 1) }

local V3 = class("Vector3")
local function Vector3new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
end
V3.__add = function(a, b) return Vector3new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return Vector3new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return Vector3new(a.X * b, a.Y * b, a.Z * b) end
	return Vector3new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then return Vector3new(a.X / b, a.Y / b, a.Z / b) end
	return Vector3new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__unm = function(a) return Vector3new(-a.X, -a.Y, -a.Z) end
V3.__index = function(self, key)
	if key == "Magnitude" then return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2) end
	if key == "Unit" then local m = math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2); return m > 0 and self / m or Vector3new() end
	if key == "Lerp" then return function(a, b, t) return a + (b - a) * t end end
	if key == "Dot" then return function(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end end
	if key == "Cross" then return function(a, b) return Vector3new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end end
	if key == "Abs" then return function(a) return Vector3new(math.abs(a.X), math.abs(a.Y), math.abs(a.Z)) end end
	if key == "Min" then return function(a, b) return Vector3new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z)) end end
	if key == "Max" then return function(a, b) return Vector3new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z)) end end
	return nil
end
Vector3 = { new = Vector3new, zero = Vector3new(), one = Vector3new(1, 1, 1), xAxis = Vector3new(1, 0, 0), yAxis = Vector3new(0, 1, 0), zAxis = Vector3new(0, 0, 1) }

-- A CFrame that keeps its position and nothing else: nothing under test reads an orientation.
local CF = class("CFrame")
local function CFrameat(p)
	return setmetatable({ Position = p or Vector3new() }, CF)
end
CF.__mul = function(a, b)
	if getmetatable(b) == V3 then return a.Position + b end
	return CFrameat(a.Position + b.Position)
end
CF.__add = function(a, b) return CFrameat(a.Position + b) end
CF.__sub = function(a, b) return CFrameat(a.Position - b) end
CF.__index = function(self, key)
	if key == "p" then return self.Position end
	if key == "X" then return self.Position.X end
	if key == "Y" then return self.Position.Y end
	if key == "Z" then return self.Position.Z end
	if key == "LookVector" then return Vector3new(0, 0, -1) end
	if key == "UpVector" then return Vector3new(0, 1, 0) end
	if key == "RightVector" then return Vector3new(1, 0, 0) end
	if key == "Rotation" then return CFrameat() end
	if key == "Inverse" then return function(c) return CFrameat(-c.Position) end end
	if key == "Lerp" then return function(a, b, t) return CFrameat(a.Position:Lerp(b.Position, t)) end end
	if key == "PointToWorldSpace" or key == "VectorToWorldSpace" or key == "PointToObjectSpace" or key == "VectorToObjectSpace" then
		return function(c, v) return v end
	end
	if key == "ToWorldSpace" or key == "ToObjectSpace" then return function(c, o) return o end end
	if key == "ToEulerAnglesXYZ" or key == "ToOrientation" or key == "ToEulerAnglesYXZ" then return function() return 0, 0, 0 end end
	if key == "GetComponents" then return function(c) return c.Position.X, c.Position.Y, c.Position.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1 end end
	return nil
end
CFrame = setmetatable({
	new = function(x, y, z)
		if type(x) == "table" then return CFrameat(x) end
		return CFrameat(Vector3new(x, y, z))
	end,
	lookAt = function(p) return CFrameat(p) end,
	identity = CFrameat(),
}, { __index = function() return function() return CFrameat() end end })

local UD = class("UDim")
function UD.__add(a, b) return setmetatable({ Scale = a.Scale + b.Scale, Offset = a.Offset + b.Offset }, UD) end
UDim = { new = function(s, o) return setmetatable({ Scale = s or 0, Offset = o or 0 }, UD) end }
local UD2 = class("UDim2")
local function UDim2new(xs, xo, ys, yo)
	return setmetatable({ X = UDim.new(xs, xo), Y = UDim.new(ys, yo), Width = UDim.new(xs, xo), Height = UDim.new(ys, yo) }, UD2)
end
UD2.__add = function(a, b) return UDim2new(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset) end
UD2.__sub = function(a, b) return UDim2new(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset) end
UD2.__index = { Lerp = function(a, b, t) return b end }
UDim2 = {
	new = function(xs, xo, ys, yo)
		if type(xs) == "table" then return UDim2new(xs.Scale, xs.Offset, xo.Scale, xo.Offset) end
		return UDim2new(xs or 0, xo or 0, ys or 0, yo or 0)
	end,
	fromScale = function(x, y) return UDim2new(x, 0, y, 0) end,
	fromOffset = function(x, y) return UDim2new(0, x or 0, 0, y or 0) end,
}

local C3 = class("Color3")
local function Color3new(r, g, b) return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3) end
C3.__index = {
	Lerp = function(a, b, t) return Color3new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end,
	ToHSV = function(c) return 0, 0, math.max(c.R, c.G, c.B) end,
	ToHex = function() return "ffffff" end,
}
C3.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
Color3 = {
	new = Color3new,
	fromRGB = function(r, g, b) return Color3new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end,
	fromHSV = function(h, s, v) return Color3new(v, v, v) end,
	fromHex = function() return Color3new(1, 1, 1) end,
}
Color3.toHSV = function(c) return c:ToHSV() end

local function opaque(name)
	local mt = class(name)
	return function(...) return setmetatable({ args = { ... } }, mt) end
end
NumberSequenceKeypoint = { new = opaque("NumberSequenceKeypoint") }
NumberSequence = { new = opaque("NumberSequence") }
ColorSequenceKeypoint = { new = opaque("ColorSequenceKeypoint") }
ColorSequence = { new = opaque("ColorSequence") }
NumberRange = { new = opaque("NumberRange") }
Rect = { new = opaque("Rect") }
TweenInfo = { new = opaque("TweenInfo") }
PhysicalProperties = { new = opaque("PhysicalProperties") }
Font = { new = opaque("Font"), fromEnum = opaque("Font"), fromName = opaque("Font") }
BrickColor = setmetatable({}, { __index = function() return function() return setmetatable({ Color = Color3new(1, 1, 1) }, class("BrickColor")) end end })

-- Enum.X.Y: one table per item, so identity compares work; Name and EnumType for anything that reads them.
local EnumItem = class("EnumItem")
Enum = setmetatable({}, {
	__index = function(enums, typeName)
		local items = setmetatable({}, {
			__index = function(list, itemName)
				local item = setmetatable({ Name = itemName, EnumType = typeName, Value = 0 }, EnumItem)
				rawset(list, itemName, item)
				return item
			end,
		})
		items.GetEnumItems = function() return {} end
		rawset(enums, typeName, items)
		return items
	end,
})
EnumItem.__tostring = function(item) return "Enum." .. item.EnumType .. "." .. item.Name end

local RandomMT = class("Random")
RandomMT.__index = {
	NextNumber = function(self, a, b)
		self.state = (self.state * 1103515245 + 12345) % 2147483648
		local u = self.state / 2147483648
		if a then return a + (b - a) * u end
		return u
	end,
	NextInteger = function(self, a, b)
		self.state = (self.state * 1103515245 + 12345) % 2147483648
		return a + math.floor(self.state / 2147483648 * (b - a + 1))
	end,
	Clone = function(self) return setmetatable({ state = self.state }, RandomMT) end,
}
Random = { new = function(seed) return setmetatable({ state = math.floor(math.abs(seed or 1)) % 2147483648 + 1 }, RandomMT) end }

--------------------------------------------------------------------------------
-- Globals Luau has and Lua does not
--------------------------------------------------------------------------------

function math.clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
function math.round(x) return math.floor(x + 0.5) end
function math.sign(x) return x > 0 and 1 or (x < 0 and -1 or 0) end
function math.noise() return 0 end
function table.find(t, value, init)
	for index = init or 1, #t do
		if t[index] == value then return index end
	end
	return nil
end
function table.clear(t)
	for key in pairs(t) do
		t[key] = nil
	end
end
function table.clone(t)
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = v
	end
	return copy
end
function table.freeze(t) return t end
function table.isfrozen() return false end
function table.create(n, v)
	local list = {}
	for i = 1, n do
		list[i] = v
	end
	return list
end
function string.split(s, sep)
	local out, start = {}, 1
	sep = sep or ","
	while true do
		local a, b = string.find(s, sep, start, true)
		if not a then table.insert(out, string.sub(s, start)); return out end
		table.insert(out, string.sub(s, start, a - 1))
		start = b + 1
	end
end
-- Luau's %d accepts 2.0 and so does 5.4's, but Luau also takes 2.5 (truncating) where 5.4 throws.
do
	local format = string.format
	string.format = function(fmt, ...)
		local args = table.pack(...)
		local index = 0
		for spec in string.gmatch(fmt, "%%[-+ #0]*%d*%.?%d*([%a%%])") do
			if spec ~= "%" then
				index = index + 1
				if (spec == "d" or spec == "i" or spec == "x" or spec == "X") and type(args[index]) == "number" then
					args[index] = math.floor(args[index])
				end
			end
		end
		return format(fmt, table.unpack(args, 1, args.n))
	end
end
local rawtostring = tostring
function tostring(value)
	-- Luau prints 2.0 as "2": the menu builds labels with `.. number`.
	if math.type and math.type(value) == "float" and value == math.floor(value) and math.abs(value) < 1e15 then
		return rawtostring(math.floor(value))
	end
	return rawtostring(value)
end
M.warnings = {}
function warn(...)
	local parts = {}
	for _, v in ipairs({ ... }) do table.insert(parts, tostring(v)) end
	table.insert(M.warnings, table.concat(parts, " "))
end
function tick() return os.time() end
utf8 = utf8 or {}

function typeof(value)
	local mt = getmetatable(value)
	if type(value) == "table" and mt then
		if mt.__type then return mt.__type end
		if rawget(value, "__instance") then return "Instance" end
	end
	return type(value)
end

-- task.wait parks the calling coroutine for good: the harness drives everything it needs by firing
-- signals, so a loop that waits is simply never resumed. Spawned work runs at once, up to its first wait.
task = {
	spawn = function(fn, ...)
		local co = type(fn) == "thread" and fn or coroutine.create(fn)
		local ok, err = coroutine.resume(co, ...)
		if not ok then table.insert(M.warnings, "task error: " .. tostring(err)) end
		return co
	end,
	wait = function()
		if coroutine.isyieldable() then coroutine.yield() end
		return 0
	end,
	delay = function() return nil end,
	cancel = function() end,
}
task.defer = task.spawn
function wait() return task.wait() end
function spawn(fn) return task.spawn(fn) end
function delay() end

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------

local SignalMT = class("RBXScriptSignal")
SignalMT.__index = {
	Connect = function(self, fn)
		local connection = { Connected = true, fn = fn }
		connection.Disconnect = function(c) c.Connected = false end
		table.insert(self.handlers, connection)
		return connection
	end,
	Once = function(self, fn)
		local connection
		connection = self:Connect(function(...)
			connection.Connected = false
			fn(...)
		end)
		return connection
	end,
	Wait = function() if coroutine.isyieldable() then coroutine.yield() end end,
	Fire = function(self, ...)
		for _, connection in ipairs(self.handlers) do
			if connection.Connected then connection.fn(...) end
		end
	end,
	Count = function(self)
		local n = 0
		for _, connection in ipairs(self.handlers) do
			if connection.Connected then n = n + 1 end
		end
		return n
	end,
}
local function Signal() return setmetatable({ handlers = {} }, SignalMT) end
M.Signal = Signal

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

local EVENTS = {
	Activated = true, MouseButton1Click = true, MouseButton1Down = true, MouseButton1Up = true, MouseButton2Click = true,
	MouseEnter = true, MouseLeave = true, MouseMoved = true, InputBegan = true, InputEnded = true, InputChanged = true,
	Changed = true, ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true,
	Destroying = true, AncestryChanged = true, FocusLost = true, Focused = true, Completed = true,
	Heartbeat = true, RenderStepped = true, Stepped = true, PreRender = true, PostSimulation = true,
	OnClientEvent = true, OnServerEvent = true, Event = true, Touched = true, SelectionGained = true, SelectionLost = true,
	TouchTap = true, LastInputTypeChanged = true, InputTypeChanged = true, CharacterAdded = true, CharacterRemoving = true,
	PromptProductPurchaseFinished = true, PromptGamePassPurchaseFinished = true, PromptPurchaseFinished = true,
	WindowFocused = true, WindowFocusReleased = true, MenuOpened = true, MenuClosed = true, PlayerAdded = true, PlayerRemoving = true,
	AttributeChanged = true, ReturnPressedFromOnScreenKeyboard = true,
}

local ISA = {
	GuiObject = { Frame = 1, TextLabel = 1, TextButton = 1, TextBox = 1, ImageLabel = 1, ImageButton = 1, ScrollingFrame = 1, ViewportFrame = 1, CanvasGroup = 1, VideoFrame = 1 },
	GuiButton = { TextButton = 1, ImageButton = 1 },
	GuiBase2d = { Frame = 1, TextLabel = 1, TextButton = 1, TextBox = 1, ImageLabel = 1, ImageButton = 1, ScrollingFrame = 1, ViewportFrame = 1, CanvasGroup = 1, ScreenGui = 1, BillboardGui = 1, SurfaceGui = 1 },
	LayerCollector = { ScreenGui = 1, BillboardGui = 1, SurfaceGui = 1 },
	UIComponent = {}, UILayout = { UIListLayout = 1, UIGridLayout = 1, UITableLayout = 1, UIPageLayout = 1 },
	UIGridStyleLayout = { UIListLayout = 1, UIGridLayout = 1 },
	BasePart = { Part = 1, MeshPart = 1, WedgePart = 1, CornerWedgePart = 1, TrussPart = 1, UnionOperation = 1 },
	PVInstance = { Part = 1, MeshPart = 1, WedgePart = 1, CornerWedgePart = 1, Model = 1 },
	LuaSourceContainer = { ModuleScript = 1, LocalScript = 1, Script = 1 },
	ValueBase = { StringValue = 1, NumberValue = 1, IntValue = 1, BoolValue = 1, ObjectValue = 1 },
}

local DEFAULTS = {
	Visible = true, Size = UDim2new(0, 0, 0, 0), Position = UDim2new(0, 0, 0, 0), AnchorPoint = Vector2new(0, 0),
	BackgroundTransparency = 0, TextTransparency = 0, ImageTransparency = 0, Transparency = 0, ZIndex = 1, LayoutOrder = 0,
	Text = "", TextSize = 14, TextWrapped = false, TextScaled = false, Rotation = 0, ClipsDescendants = false,
	Enabled = true, Active = false, AutoButtonColor = true, Selectable = false, Archived = true,
	ScrollBarThickness = 12, CanvasSize = UDim2new(0, 0, 0, 0), CanvasPosition = Vector2new(0, 0),
	Scale = 1, Padding = UDim.new(0, 0), CellSize = UDim2new(0, 100, 0, 100), CellPadding = UDim2new(0, 5, 0, 5),
	PaddingTop = UDim.new(0, 0), PaddingBottom = UDim.new(0, 0), PaddingLeft = UDim.new(0, 0), PaddingRight = UDim.new(0, 0),
	CFrame = CFrameat(), Anchored = false, CanCollide = true, Color = Color3new(0.6, 0.6, 0.6), Material = Enum.Material.Plastic,
	FieldOfView = 70, MaxVisibleGraphemes = -1, ImageColor3 = Color3new(1, 1, 1), BackgroundColor3 = Color3new(1, 1, 1),
	TextColor3 = Color3new(0, 0, 0), Thickness = 1, CornerRadius = UDim.new(0, 0), Value = nil, ResetOnSpawn = true,
	IgnoreGuiInset = false, DisplayOrder = 0, ScrollingEnabled = true, MaxTextSize = 100, MinTextSize = 1,
}
local ENUM_DEFAULTS = {
	FillDirection = "FillDirection.Vertical", HorizontalAlignment = "HorizontalAlignment.Left", VerticalAlignment = "VerticalAlignment.Top",
	SortOrder = "SortOrder.Name", AutomaticSize = "AutomaticSize.None", AutomaticCanvasSize = "AutomaticSize.None",
	TextXAlignment = "TextXAlignment.Center", TextYAlignment = "TextYAlignment.Center", TextTruncate = "TextTruncate.None",
	Font = "Font.Legacy", ScrollingDirection = "ScrollingDirection.XY", SizeConstraint = "SizeConstraint.RelativeXY",
	FillDirectionMaxCells = nil, ApplyStrokeMode = "ApplyStrokeMode.Contextual", ZIndexBehavior = "ZIndexBehavior.Sibling",
	StartCorner = "StartCorner.TopLeft", Shape = "PartType.Block",
}

local Methods = {}
local InstanceMT = { __type = "Instance" }
M.layoutVersion = 0

local function newInstance(className, name)
	local self = setmetatable({ __instance = true, __class = className, __props = {}, __children = {}, __signals = {},
		__propSignals = {}, __attributes = {} }, InstanceMT)
	self.__props.Name = name or className
	return self
end
M.newInstance = newInstance

InstanceMT.__index = function(self, key)
	if key == "ClassName" then return rawget(self, "__class") end
	if key == "Parent" then return rawget(self, "__parent") end
	local props = rawget(self, "__props")
	local value = props[key]
	if value ~= nil then return value end
	if key == "AbsoluteSize" then return M.absSize(self) end
	if key == "AbsolutePosition" then return M.absPos(self) end
	if key == "AbsoluteCanvasSize" then return M.absSize(self) end
	if key == "TextBounds" then return M.textBounds(self) end
	local method = Methods[key]
	if method then return method end
	if EVENTS[key] then
		local signals = rawget(self, "__signals")
		signals[key] = signals[key] or Signal()
		return signals[key]
	end
	if key == "Active" then return Methods.IsA(self, "GuiButton") end
	if DEFAULTS[key] ~= nil then return DEFAULTS[key] end
	if ENUM_DEFAULTS[key] then
		local t, item = string.match(ENUM_DEFAULTS[key], "(%w+)%.(%w+)")
		return Enum[t][item]
	end
	local child = Methods.FindFirstChild(self, key)
	if child then return child end
	local hook = rawget(self, "__index_hook")
	if hook then return hook(self, key) end
	return nil
end

InstanceMT.__newindex = function(self, key, value)
	if key == "Parent" then
		local old = rawget(self, "__parent")
		if old == value then return end
		if old then
			local list = rawget(old, "__children")
			for index = #list, 1, -1 do
				if list[index] == self then table.remove(list, index) end
			end
		end
		rawset(self, "__parent", value)
		if value then
			table.insert(rawget(value, "__children"), self)
			local signals = rawget(value, "__signals")
			if signals.ChildAdded then signals.ChildAdded:Fire(self) end
		end
		M.layoutVersion = M.layoutVersion + 1
		return
	end
	local props = rawget(self, "__props")
	if props[key] == value then return end
	props[key] = value
	M.layoutVersion = M.layoutVersion + 1
	local signal = rawget(self, "__propSignals")[key]
	if signal then signal:Fire() end
	local changed = rawget(self, "__signals").Changed
	if changed then changed:Fire(key) end
end
InstanceMT.__tostring = function(self) return rawget(self, "__props").Name end

function Methods.IsA(self, className)
	local class = rawget(self, "__class")
	if class == className or className == "Instance" then return true end
	if className == "UIComponent" then return string.sub(class, 1, 2) == "UI" end
	local set = ISA[className]
	return set ~= nil and set[class] ~= nil
end
function Methods.GetChildren(self)
	local out = {}
	for index, child in ipairs(rawget(self, "__children")) do out[index] = child end
	return out
end
function Methods.GetDescendants(self)
	local out = {}
	local function walk(node)
		for _, child in ipairs(rawget(node, "__children")) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end
function Methods.FindFirstChild(self, name, recursive)
	for _, child in ipairs(rawget(self, "__children")) do
		if rawget(child, "__props").Name == name then return child end
	end
	if recursive then
		for _, child in ipairs(rawget(self, "__children")) do
			local found = Methods.FindFirstChild(child, name, true)
			if found then return found end
		end
	end
	return nil
end
function Methods.FindFirstChildOfClass(self, className)
	for _, child in ipairs(rawget(self, "__children")) do
		if rawget(child, "__class") == className then return child end
	end
	return nil
end
function Methods.FindFirstChildWhichIsA(self, className, recursive)
	for _, child in ipairs(rawget(self, "__children")) do
		if Methods.IsA(child, className) then return child end
	end
	if recursive then
		for _, child in ipairs(rawget(self, "__children")) do
			local found = Methods.FindFirstChildWhichIsA(child, className, true)
			if found then return found end
		end
	end
	return nil
end
function Methods.FindFirstAncestor(self, name)
	local node = rawget(self, "__parent")
	while node do
		if rawget(node, "__props").Name == name then return node end
		node = rawget(node, "__parent")
	end
	return nil
end
function Methods.FindFirstAncestorOfClass(self, className)
	local node = rawget(self, "__parent")
	while node do
		if rawget(node, "__class") == className then return node end
		node = rawget(node, "__parent")
	end
	return nil
end
function Methods.FindFirstAncestorWhichIsA(self, className)
	local node = rawget(self, "__parent")
	while node do
		if Methods.IsA(node, className) then return node end
		node = rawget(node, "__parent")
	end
	return nil
end
function Methods.WaitForChild(self, name)
	local child = Methods.FindFirstChild(self, name)
	if child then return child end
	local hook = rawget(self, "__wait_hook")
	if hook then
		child = hook(self, name)
		if child then return child end
	end
	error("WaitForChild would wait forever: " .. tostring(self) .. "." .. name, 2)
end
function Methods.IsDescendantOf(self, ancestor)
	local node = rawget(self, "__parent")
	while node do
		if node == ancestor then return true end
		node = rawget(node, "__parent")
	end
	return false
end
function Methods.IsAncestorOf(self, descendant) return Methods.IsDescendantOf(descendant, self) end
function Methods.Destroy(self)
	local signals = rawget(self, "__signals")
	if signals.Destroying then signals.Destroying:Fire() end
	for _, child in ipairs(Methods.GetChildren(self)) do Methods.Destroy(child) end
	self.Parent = nil
	rawset(self, "__destroyed", true)
end
function Methods.ClearAllChildren(self)
	for _, child in ipairs(Methods.GetChildren(self)) do Methods.Destroy(child) end
end
function Methods.Clone(self)
	local copy = newInstance(rawget(self, "__class"))
	for key, value in pairs(rawget(self, "__props")) do rawget(copy, "__props")[key] = value end
	for key, value in pairs(rawget(self, "__attributes")) do rawget(copy, "__attributes")[key] = value end
	for _, child in ipairs(rawget(self, "__children")) do Methods.Clone(child).Parent = copy end
	return copy
end
function Methods.GetAttribute(self, name) return rawget(self, "__attributes")[name] end
function Methods.SetAttribute(self, name, value)
	rawget(self, "__attributes")[name] = value
	local signals = rawget(self, "__attrSignals")
	if signals and signals[name] then signals[name]:Fire() end
end
function Methods.GetAttributes(self) return table.clone(rawget(self, "__attributes")) end
function Methods.GetAttributeChangedSignal(self, name)
	local signals = rawget(self, "__attrSignals") or {}
	rawset(self, "__attrSignals", signals)
	signals[name] = signals[name] or Signal()
	return signals[name]
end
function Methods.GetPropertyChangedSignal(self, name)
	local signals = rawget(self, "__propSignals")
	signals[name] = signals[name] or Signal()
	return signals[name]
end
function Methods.GetFullName(self)
	local parts, node = {}, self
	while node do
		table.insert(parts, 1, rawget(node, "__props").Name)
		node = rawget(node, "__parent")
	end
	return table.concat(parts, ".")
end
-- Models and parts: enough for a preview camera to be framed.
function Methods.GetBoundingBox() return CFrameat(), Vector3new(2, 2, 2) end
function Methods.GetExtentsSize() return Vector3new(2, 2, 2) end
function Methods.PivotTo() end
function Methods.GetPivot() return CFrameat() end
function Methods.SetPrimaryPartCFrame() end
function Methods.ScaleTo() end
function Methods.GetScale() return 1 end
function Methods.BreakJoints() end
function Methods.CaptureFocus() end
function Methods.ReleaseFocus() end
function Methods.TweenSize() return true end
function Methods.TweenPosition() return true end
function Methods.TweenSizeAndPosition() return true end
-- BindableEvent:Fire (Settings.Changed is one).
function Methods.Fire(self, ...) self.Event:Fire(...) end
function Methods.Play() end
function Methods.Stop() end
function Methods.Pause() end
function Methods.Cancel() end

Instance = {
	new = function(className, parent)
		local inst = newInstance(className)
		if className == "ViewportFrame" then
			-- `CurrentCamera` is a property a caller sets; nothing to seed.
		end
		if parent then inst.Parent = parent end
		return inst
	end,
}

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local cache = { version = -1, size = {}, pos = {} }
local function fresh()
	if cache.version ~= M.layoutVersion then
		cache = { version = M.layoutVersion, size = {}, pos = {} }
	end
end

local function prop(inst, key) return inst[key] end
local function isGui(inst) return Methods.IsA(inst, "GuiObject") end
local function enumName(value) return value and value.Name or nil end

local function paddingOf(inst)
	local pad = Methods.FindFirstChildOfClass(inst, "UIPadding")
	if not pad then return 0, 0, 0, 0 end
	local size = M.absSizeRaw(inst)
	return pad.PaddingLeft.Offset + pad.PaddingLeft.Scale * size.X, pad.PaddingRight.Offset + pad.PaddingRight.Scale * size.X,
		pad.PaddingTop.Offset + pad.PaddingTop.Scale * size.Y, pad.PaddingBottom.Offset + pad.PaddingBottom.Scale * size.Y
end

local function layoutOf(inst)
	return Methods.FindFirstChildOfClass(inst, "UIListLayout") or Methods.FindFirstChildOfClass(inst, "UIGridLayout")
end

local function laidChildren(inst)
	local list = {}
	for _, child in ipairs(rawget(inst, "__children")) do
		if isGui(child) and child.Visible then table.insert(list, child) end
	end
	local layout = layoutOf(inst)
	if layout and enumName(layout.SortOrder) == "LayoutOrder" then
		local indexOf = {}
		for index, child in ipairs(list) do indexOf[child] = index end
		table.sort(list, function(a, b)
			if a.LayoutOrder ~= b.LayoutOrder then return a.LayoutOrder < b.LayoutOrder end
			return indexOf[a] < indexOf[b]
		end)
	elseif layout then
		table.sort(list, function(a, b) return tostring(a.Name) < tostring(b.Name) end)
	end
	return list
end

-- The room a parent gives its children: its size less padding. A ScrollingFrame's canvas is its
-- window width (less the bar when it scrolls vertically) and, vertically, as tall as it needs.
local function innerSize(parent)
	local class = rawget(parent, "__class")
	if class == "ScreenGui" or class == "PlayerGui" then return M.viewport end
	local size = M.absSizeRaw(parent)
	local l, r, t, b = paddingOf(parent)
	local w, h = size.X - l - r, size.Y - t - b
	if class == "ScrollingFrame" then
		local canvas = parent.CanvasSize
		w = math.max(w - parent.ScrollBarThickness, canvas.X.Scale * w + canvas.X.Offset)
		h = math.max(h, canvas.Y.Scale * h + canvas.Y.Offset)
	end
	return Vector2new(w, h)
end

local GLYPH = 0.55
function M.textBounds(inst)
	local text = tostring(inst.Text or "")
	if inst.RichText then text = text:gsub("<[^>]->", "") end
	local size = inst.TextSize or 14
	local width = utf8.len(text) and utf8.len(text) or #text
	return Vector2new(width * size * GLYPH, size)
end

-- Extents of a frame's children, for AutomaticSize.
local function contentExtent(inst, frameSize)
	local layout = layoutOf(inst)
	local children = laidChildren(inst)
	local l, r, t, b = 0, 0, 0, 0
	local pad = Methods.FindFirstChildOfClass(inst, "UIPadding")
	if pad then l, r, t, b = pad.PaddingLeft.Offset, pad.PaddingRight.Offset, pad.PaddingTop.Offset, pad.PaddingBottom.Offset end
	local w, h = 0, 0
	if layout and rawget(layout, "__class") == "UIListLayout" then
		local horizontal = enumName(layout.FillDirection) == "Horizontal"
		local gap = layout.Padding.Offset
		for index, child in ipairs(children) do
			local s = M.absSizeRaw(child)
			if horizontal then
				w = w + s.X + (index > 1 and gap or 0); h = math.max(h, s.Y)
			else
				h = h + s.Y + (index > 1 and gap or 0); w = math.max(w, s.X)
			end
		end
	elseif layout then
		local rects = M.gridRects(inst, children)
		for _, rect in pairs(rects) do
			w = math.max(w, rect.x + rect.w); h = math.max(h, rect.y + rect.h)
		end
	else
		for _, child in ipairs(children) do
			local s = M.absSizeRaw(child)
			local p = child.Position
			w = math.max(w, p.X.Offset + s.X); h = math.max(h, p.Y.Offset + s.Y)
		end
	end
	if rawget(inst, "__class") == "TextLabel" or rawget(inst, "__class") == "TextButton" then
		local bounds = M.textBounds(inst)
		if inst.TextWrapped and frameSize.X > 0 then
			local lines = math.max(1, math.ceil(bounds.X / frameSize.X))
			w = math.max(w, math.min(bounds.X, frameSize.X)); h = math.max(h, lines * bounds.Y * 1.2)
		else
			w = math.max(w, bounds.X); h = math.max(h, bounds.Y)
		end
	end
	return w + l + r, h + t + b
end

function M.absSizeRaw(inst)
	fresh()
	local known = cache.size[inst]
	if known then return known end
	local class = rawget(inst, "__class")
	if class == "ScreenGui" or class == "PlayerGui" then return M.viewport end
	local parent = rawget(inst, "__parent")
	local room = parent and Methods.IsA(parent, "GuiBase2d") and innerSize(parent) or M.viewport
	if parent and rawget(parent, "__class") == "PlayerGui" then room = M.viewport end
	local size = inst.Size
	local w = size.X.Scale * room.X + size.X.Offset
	local h = size.Y.Scale * room.Y + size.Y.Offset
	local auto = enumName(inst.AutomaticSize)
	if auto and auto ~= "None" then
		cache.size[inst] = Vector2new(w, h) -- provisional, for children that read it
		local cw, ch = contentExtent(inst, Vector2new(w, h))
		if auto == "X" or auto == "XY" then w = math.max(w, cw) end
		if auto == "Y" or auto == "XY" then h = math.max(h, ch) end
	end
	local constraint = Methods.FindFirstChildOfClass(inst, "UISizeConstraint")
	if constraint then
		local max, min = rawget(constraint, "__props").MaxSize, rawget(constraint, "__props").MinSize
		if max then w, h = math.min(w, max.X), math.min(h, max.Y) end
		if min then w, h = math.max(w, min.X), math.max(h, min.Y) end
	end
	local result = Vector2new(w, h)
	cache.size[inst] = result
	return result
end
function M.absSize(inst)
	return M.absSizeRaw(inst)
end

function M.gridRects(parent, children)
	local layout = layoutOf(parent)
	local room = innerSize(parent)
	local cell, gap = layout.CellSize, layout.CellPadding
	local cw, ch = cell.X.Scale * room.X + cell.X.Offset, cell.Y.Scale * room.Y + cell.Y.Offset
	local gx, gy = gap.X.Scale * room.X + gap.X.Offset, gap.Y.Scale * room.Y + gap.Y.Offset
	local perRow = math.max(1, math.floor((room.X + gx) / (cw + gx)))
	if layout.FillDirectionMaxCells and layout.FillDirectionMaxCells > 0 then perRow = math.min(perRow, layout.FillDirectionMaxCells) end
	local rows = {}
	for index, child in ipairs(children) do
		local i = index - 1
		rows[child] = { x = (i % perRow) * (cw + gx), y = math.floor(i / perRow) * (ch + gy), w = cw, h = ch }
	end
	return rows
end

-- A child's position inside its parent's inner box, following the parent's layout if it has one.
local function localPos(inst, parent)
	local layout = layoutOf(parent)
	local room = innerSize(parent)
	local size = M.absSizeRaw(inst)
	if layout and rawget(layout, "__class") == "UIGridLayout" then
		local rect = M.gridRects(parent, laidChildren(parent))[inst]
		if rect then
			cache.size[inst] = Vector2new(rect.w, rect.h)
			return rect.x, rect.y
		end
	elseif layout then
		local horizontal = enumName(layout.FillDirection) == "Horizontal"
		local gap = layout.Padding.Scale * (horizontal and room.X or room.Y) + layout.Padding.Offset
		local children = laidChildren(parent)
		local total, cross, at = 0, 0, nil
		for index, child in ipairs(children) do
			local s = M.absSizeRaw(child)
			if child == inst then at = total end
			total = total + (horizontal and s.X or s.Y) + (index < #children and gap or 0)
		end
		if at then
			local h = enumName(layout.HorizontalAlignment)
			local v = enumName(layout.VerticalAlignment)
			local x, y
			if horizontal then
				local start = (h == "Center" and (room.X - total) / 2) or (h == "Right" and room.X - total) or 0
				x = start + at
				y = (v == "Center" and (room.Y - size.Y) / 2) or (v == "Bottom" and room.Y - size.Y) or 0
			else
				local start = (v == "Center" and (room.Y - total) / 2) or (v == "Bottom" and room.Y - total) or 0
				y = start + at
				x = (h == "Center" and (room.X - size.X) / 2) or (h == "Right" and room.X - size.X) or 0
			end
			return x, y
		end
	end
	local p, a = inst.Position, inst.AnchorPoint
	return p.X.Scale * room.X + p.X.Offset - a.X * size.X, p.Y.Scale * room.Y + p.Y.Offset - a.Y * size.Y
end

function M.absPos(inst)
	fresh()
	local known = cache.pos[inst]
	if known then return known end
	local parent = rawget(inst, "__parent")
	local result
	if not parent or not Methods.IsA(parent, "GuiBase2d") or rawget(parent, "__class") == "ScreenGui" then
		if parent and rawget(parent, "__class") == "ScreenGui" and Methods.IsA(inst, "GuiObject") then
			local x, y = localPos(inst, parent)
			result = Vector2new(x, y)
		else
			result = Vector2new(0, 0)
		end
	else
		local base = M.absPos(parent)
		local l, _, t = paddingOf(parent)
		local x, y = localPos(inst, parent)
		result = Vector2new(base.X + l + x, base.Y + t + y)
		if rawget(parent, "__class") == "ScrollingFrame" then
			local canvas = parent.CanvasPosition
			result = result - canvas
		end
	end
	cache.pos[inst] = result
	return result
end

--------------------------------------------------------------------------------
-- Services and the data model
--------------------------------------------------------------------------------

M.viewport = Vector2new(1280, 720)

local game_ = newInstance("DataModel", "game")
local services = {}
local function service(name)
	if services[name] then return services[name] end
	local s = newInstance(name, name)
	s.Parent = game_
	services[name] = s
	return s
end
M.service = service
Methods.GetService = function(self, name) return service(name) end
Methods.IsLoaded = function() return true end
game = game_
rawset(game_, "__index_hook", function(_, key) return service(key) end)

local Workspace = service("Workspace")
workspace = Workspace
local camera = newInstance("Camera", "Camera")
camera.ViewportSize = M.viewport
camera.Parent = Workspace
Workspace.CurrentCamera = camera
Workspace.Gravity = 196.2
M.camera = camera

function M.setViewport(x, y)
	M.viewport = Vector2new(x, y)
	camera.ViewportSize = M.viewport
end

local Players = service("Players")
local player = newInstance("Player", "Oliver")
player.UserId = 1
player.DisplayName = "Oliver"
player.Parent = Players
Players.LocalPlayer = player
local playerGui = newInstance("PlayerGui", "PlayerGui")
playerGui.Parent = player
Methods.GetPlayers = function() return { player } end
Methods.GetMouse = function() return newInstance("Mouse") end
M.player, M.playerGui = player, playerGui

local UIS = service("UserInputService")
UIS.TouchEnabled = false
UIS.KeyboardEnabled = true
UIS.MouseEnabled = true
UIS.GamepadEnabled = false
UIS.MouseIconEnabled = true
UIS.MouseBehavior = Enum.MouseBehavior.Default
Methods.GetLastInputType = function() return Enum.UserInputType.MouseButton1 end
Methods.IsKeyDown = function() return false end
Methods.IsMouseButtonPressed = function() return false end
Methods.GetMouseLocation = function() return Vector2new(0, 0) end
Methods.GetConnectedGamepads = function() return {} end
Methods.GetStringForKeyCode = function(_, key) return key and key.Name or "" end
Methods.GetFocusedTextBox = function() return nil end
Methods.GetGuiObjectsAtPosition = function() return {} end
Methods.GetGuiInset = function() return Vector2new(0, 58), Vector2new(0, 0) end

M.bound = {}
Methods.BindAction = function(_, name, fn) M.bound[name] = fn end
Methods.BindActionAtPriority = function(_, name, fn) M.bound[name] = fn end
Methods.UnbindAction = function(_, name) M.bound[name] = nil end

-- TweenService:Create: a tween whose Play lands the goal at once, so an open or close animation ends
-- where it would, and Completed fires.
Methods.Create = function(_, inst, info, goal)
	local tween = newInstance("Tween")
	rawset(tween, "__goal", { inst = inst, goal = goal })
	return tween
end
Methods.Play = function(self)
	local g = rawget(self, "__goal")
	if g then
		for key, value in pairs(g.goal or {}) do g.inst[key] = value end
		self.Completed:Fire(Enum.PlaybackState.Completed)
	end
end
-- Wraps at the frame's width the same way AutomaticSize does below, so code that measures then sizes
-- is held to its own measurement.
Methods.GetTextSize = function(_, text, size, _, frame)
	size = size or 14
	local w = (utf8.len(tostring(text)) or #tostring(text)) * size * GLYPH
	if frame and frame.X > 0 and w > frame.X then
		return Vector2new(frame.X, math.ceil(w / frame.X) * size * 1.2)
	end
	return Vector2new(w, size)
end
Methods.GetTextBoundsAsync = function(_, params) return Vector2new(#tostring(params.Text or "") * (params.Size or 14) * GLYPH, params.Size or 14) end
Methods.PromptProductPurchase = function(_, _, id) table.insert(M.prompts, { "product", id }) end
Methods.PromptGamePassPurchase = function(_, _, id) table.insert(M.prompts, { "pass", id }) end
Methods.PromptPurchase = function(_, _, id) table.insert(M.prompts, { "asset", id }) end
Methods.UserOwnsGamePassAsync = function() return false end
Methods.GetProductInfo = function() return { PriceInRobux = 0 } end
Methods.IsStudio = function() return false end
Methods.IsClient = function() return true end
Methods.IsServer = function() return false end
M.prompts = {}

local GuiService = service("GuiService")
GuiService.MenuIsOpen = false
GuiService.SelectedObject = nil
GuiService.TopbarInset = Rect.new(0, 0, 0, 58)

local RunService = service("RunService")

M.Instance, M.Methods = Instance, Methods
return M
