-- A mocked Roblox client for running the real HUD scripts outside Studio (#80). Loaded by
-- tools/hud_layout_check.py through lupa. It is NOT Roblox: it knows enough of the GUI object model
-- (properties, children, UIScale, anchors, attributes, property-changed signals) to say where each
-- top-level HUD element would be drawn, and it answers everything else with an inert stand-in, so
-- a script that reaches for something not modelled here carries on rather than stopping.
--
-- What the geometry models: Size and Position as UDim2 against the parent's box, AnchorPoint, and
-- UIScale as Roblox applies it (the element and everything inside it scaled about its anchor). What
-- it does not: UIListLayout / UIGridLayout placing children, text bounds, clipping. Only the direct
-- children of each ScreenGui are compared, and their own boxes are what a layout arranges anyway.

-- Plain Lua 5.x (lupa), not Luau: `load` compiles a script with its own environment.
local compileChunk = rawget(_G, "load")

local W = {}
W.NIL = setmetatable({}, { __tostring = function() return "nil" end })
W.errors = {}
W.warnings = {}
W.sources = {} -- module name -> luau source (filled from Python)
W.plant = {} -- test hooks

local function note(list, message)
	table.insert(list, tostring(message))
end

--------------------------------------------------------------------------------
-- Inert stand-in
--------------------------------------------------------------------------------
local Dummy
local dummyMeta = {}
local function newDummy(name)
	return setmetatable({ __dummy = name, __kids = {} }, dummyMeta)
end
dummyMeta.__index = function(self, key)
	if type(key) == "number" then
		return nil
	end
	if key == "Name" then
		return (rawget(self, "__dummy"):match("([^.]+)$"))
	end
	local kids = rawget(self, "__kids")
	if not kids[key] then
		kids[key] = newDummy(rawget(self, "__dummy") .. "." .. tostring(key))
	end
	return kids[key]
end
dummyMeta.__newindex = function() end
dummyMeta.__call = function(self)
	return newDummy(rawget(self, "__dummy") .. "()")
end
local function zero()
	return 0
end
for _, op in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm", "__idiv" }) do
	dummyMeta[op] = zero
end
dummyMeta.__lt = function()
	return false
end
dummyMeta.__le = function()
	return false
end
dummyMeta.__len = zero
dummyMeta.__concat = function()
	return ""
end
dummyMeta.__tostring = function(self)
	return rawget(self, "__dummy")
end
dummyMeta.__pairs = function()
	return next, {}, nil
end
Dummy = newDummy
W.isDummy = function(v)
	return type(v) == "table" and getmetatable(v) == dummyMeta
end

--------------------------------------------------------------------------------
-- Value types
--------------------------------------------------------------------------------
local Vector2 = {}
local v2meta = {}
v2meta.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y)
	elseif key == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y)
		return Vector2.new(m > 0 and self.X / m or 0, m > 0 and self.Y / m or 0)
	elseif key == "Lerp" then
		return function(a, b, t)
			return Vector2.new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t)
		end
	end
	return nil
end
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0, __type = "Vector2" }, v2meta)
end
v2meta.__add = function(a, b)
	return Vector2.new(a.X + b.X, a.Y + b.Y)
end
v2meta.__sub = function(a, b)
	return Vector2.new(a.X - b.X, a.Y - b.Y)
end
v2meta.__mul = function(a, b)
	if type(a) == "number" then
		return Vector2.new(a * b.X, a * b.Y)
	elseif type(b) == "number" then
		return Vector2.new(a.X * b, a.Y * b)
	end
	return Vector2.new(a.X * b.X, a.Y * b.Y)
end
v2meta.__div = function(a, b)
	if type(b) == "number" then
		return Vector2.new(a.X / b, a.Y / b)
	end
	return Vector2.new(a.X / b.X, a.Y / b.Y)
end
v2meta.__unm = function(a)
	return Vector2.new(-a.X, -a.Y)
end
v2meta.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
Vector2.zero = Vector2.new(0, 0)
Vector2.one = Vector2.new(1, 1)
W.Vector2 = Vector2

local Vector3 = {}
local v3meta = {}
v3meta.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
	elseif key == "Unit" then
		local m = math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
		m = m > 0 and m or 1
		return Vector3.new(self.X / m, self.Y / m, self.Z / m)
	elseif key == "Dot" then
		return function(a, b)
			return a.X * b.X + a.Y * b.Y + a.Z * b.Z
		end
	elseif key == "Cross" or key == "Lerp" then
		return function(a)
			return a
		end
	end
	return nil
end
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __type = "Vector3" }, v3meta)
end
v3meta.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
v3meta.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
v3meta.__mul = function(a, b)
	if type(a) == "number" then
		return Vector3.new(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	end
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
v3meta.__div = function(a, b)
	return Vector3.new(a.X / b, a.Y / b, a.Z / b)
end
v3meta.__unm = function(a)
	return Vector3.new(-a.X, -a.Y, -a.Z)
end
Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.zAxis = Vector3.new(0, 0, 1)

local UDim = {}
function UDim.new(s, o)
	return { Scale = s or 0, Offset = o or 0, __type = "UDim" }
end
local UDim2 = {}
local u2meta = {
	__eq = function(a, b)
		return a.X.Scale == b.X.Scale and a.X.Offset == b.X.Offset and a.Y.Scale == b.Y.Scale and a.Y.Offset == b.Y.Offset
	end,
	__add = function(a, b)
		return UDim2.new(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
	end,
	__sub = function(a, b)
		return UDim2.new(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
	end,
}
u2meta.__index = function(self, key)
	if key == "Width" then
		return self.X
	elseif key == "Height" then
		return self.Y
	elseif key == "Lerp" then
		return function(a, b, t)
			return UDim2.new(a.X.Scale + (b.X.Scale - a.X.Scale) * t, a.X.Offset + (b.X.Offset - a.X.Offset) * t,
				a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t, a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t)
		end
	end
	return nil
end
function UDim2.new(xs, xo, ys, yo)
	if type(xs) == "table" then
		return setmetatable({ X = xs, Y = xo, __type = "UDim2" }, u2meta)
	end
	return setmetatable({ X = UDim.new(xs, xo), Y = UDim.new(ys, yo), __type = "UDim2" }, u2meta)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x or 0, 0, y or 0)
end
function UDim2.fromScale(x, y)
	return UDim2.new(x or 0, 0, y or 0, 0)
end

local Color3 = {}
local c3meta = {}
c3meta.__index = function(self, key)
	if key == "Lerp" then
		return function(a)
			return a
		end
	elseif key == "ToHSV" then
		return function()
			return 0, 0, 1
		end
	elseif key == "ToHex" then
		return function()
			return "ffffff"
		end
	end
	return nil
end
local function color(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0, __type = "Color3" }, c3meta)
end
Color3.new = color
function Color3.fromRGB(r, g, b)
	return color((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
Color3.fromHSV = function()
	return color(1, 1, 1)
end
Color3.fromHex = function()
	return color(1, 1, 1)
end

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
function Signal.new(name)
	return setmetatable({ name = name, handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local entry = { fn = fn, live = true }
	table.insert(self.handlers, entry)
	return {
		Connected = true,
		Disconnect = function()
			entry.live = false
		end,
	}
end
Signal.Once = Signal.Connect
Signal.ConnectParallel = Signal.Connect
function Signal:Wait()
	return nil
end
function Signal:Fire(...)
	for _, entry in ipairs(self.handlers) do
		if entry.live then
			local ok, err = pcall(entry.fn, ...)
			if not ok then
				note(W.errors, (self.name or "signal") .. ": " .. tostring(err))
			end
		end
	end
end
W.Signal = Signal

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------
local GUI_CLASSES = {
	Frame = true, TextLabel = true, TextButton = true, ImageLabel = true, ImageButton = true, TextBox = true,
	ScrollingFrame = true, CanvasGroup = true, ViewportFrame = true, VideoFrame = true,
}
local DEFAULTS = {
	Visible = true, Enabled = true, Text = "", TextSize = 14, Scale = 1, BackgroundTransparency = 0,
	TextTransparency = 0, ImageTransparency = 0, GroupTransparency = 0, Rotation = 0, ZIndex = 1,
	LayoutOrder = 0, Image = "", TextStrokeTransparency = 1, DisplayOrder = 0, IgnoreGuiInset = false,
}
local Instance = {}
local instMeta = {}
local methods = {}
W.created = {}

local function valueDefault(self, key)
	if key == "AnchorPoint" then
		return Vector2.new(0, 0)
	elseif key == "Position" or key == "Size" then
		return UDim2.new(0, 0, 0, 0)
	elseif key == "AbsoluteSize" then
		local r = W.rectOf(self)
		return Vector2.new(r and r.w or 0, r and r.h or 0)
	elseif key == "AbsolutePosition" then
		local r = W.rectOf(self)
		return Vector2.new(r and r.x or 0, r and r.y or 0)
	elseif key == "TextBounds" then
		return Vector2.new(#tostring(rawget(self, "__props").Text or "") * 7, 14)
	end
	return nil
end

instMeta.__index = function(self, key)
	local props = rawget(self, "__props")
	if key == "Parent" then
		return rawget(self, "__parent")
	end
	if methods[key] then
		return methods[key]
	end
	local v = props[key]
	if v ~= nil then
		return v
	end
	local d = valueDefault(self, key)
	if d ~= nil then
		return d
	end
	if DEFAULTS[key] ~= nil then
		return DEFAULTS[key]
	end
	for _, child in ipairs(rawget(self, "__children")) do
		if child.Name == key then
			return child
		end
	end
	local special = rawget(self, "__special")
	if special and special[key] ~= nil then
		if special[key] == W.NIL then
			return nil
		end
		return special[key]
	end
	-- Signals and anything else the model does not know about.
	if type(key) == "string" then
		local lazy = rawget(self, "__lazy")
		if not lazy[key] then
			if key:match("Changed$") or key:match("^Mouse") or key:match("^Input") or key:match("Added$")
				or key:match("Removing$") or key:match("Activated$") or key:match("Removed$") or key:match("^Touch")
				or key:match("Completed$") or key:match("Died$") or key:match("Began$") or key:match("Ended$")
				or key:match("Event$") or key:match("Invoke$") then
				lazy[key] = Signal.new(rawget(self, "__class") .. "." .. key)
			else
				lazy[key] = Dummy(rawget(self, "__class") .. "." .. key)
			end
		end
		return lazy[key]
	end
	return nil
end

instMeta.__newindex = function(self, key, value)
	if key == "Parent" then
		local old = rawget(self, "__parent")
		if old == value then
			return
		end
		if old then
			local kids = rawget(old, "__children")
			for i, c in ipairs(kids) do
				if c == self then
					table.remove(kids, i)
					break
				end
			end
		end
		rawset(self, "__parent", value)
		if value and rawget(value, "__children") then
			table.insert(rawget(value, "__children"), self)
			local added = rawget(value, "__lazy").ChildAdded
			if added then
				added:Fire(self)
			end
		end
		return
	end
	local props = rawget(self, "__props")
	local old = props[key]
	props[key] = value
	if old ~= value then
		local sigs = rawget(self, "__propSignals")
		if sigs[key] then
			sigs[key]:Fire()
		end
	end
end
instMeta.__tostring = function(self)
	return rawget(self, "__props").Name or rawget(self, "__class")
end

local ISA = {
	GuiObject = GUI_CLASSES,
	GuiBase2d = GUI_CLASSES,
	GuiButton = { TextButton = true, ImageButton = true },
	BasePart = { Part = true, MeshPart = true, VehicleSeat = true, Seat = true },
	LayerCollector = { ScreenGui = true, BillboardGui = true, SurfaceGui = true },
	ValueBase = {},
}
function methods.IsA(self, class)
	local mine = rawget(self, "__class")
	if mine == class or class == "Instance" then
		return true
	end
	return ISA[class] ~= nil and ISA[class][mine] == true
end
function methods.FindFirstChild(self, name, recursive)
	for _, child in ipairs(rawget(self, "__children")) do
		if child.Name == name then
			return child
		end
	end
	if recursive then
		for _, child in ipairs(rawget(self, "__children")) do
			local found = methods.FindFirstChild(child, name, true)
			if found then
				return found
			end
		end
	end
	return nil
end
function methods.WaitForChild(self, name)
	local found = methods.FindFirstChild(self, name)
	if found then
		return found
	end
	local factory = rawget(self, "__factory")
	if factory then
		local made = factory(name)
		if made then
			made.Parent = self
			return made
		end
	end
	return nil
end
function methods.FindFirstChildOfClass(self, class)
	for _, child in ipairs(rawget(self, "__children")) do
		if rawget(child, "__class") == class then
			return child
		end
	end
	return nil
end
function methods.FindFirstChildWhichIsA(self, class, recursive)
	for _, child in ipairs(rawget(self, "__children")) do
		if methods.IsA(child, class) then
			return child
		end
	end
	return nil
end
function methods.FindFirstAncestorOfClass(self, class)
	local p = rawget(self, "__parent")
	while p do
		if rawget(p, "__class") == class then
			return p
		end
		p = rawget(p, "__parent")
	end
	return nil
end
methods.FindFirstAncestorWhichIsA = methods.FindFirstAncestorOfClass
function methods.FindFirstAncestor(self, name)
	local p = rawget(self, "__parent")
	while p do
		if p.Name == name then
			return p
		end
		p = rawget(p, "__parent")
	end
	return nil
end
function methods.GetChildren(self)
	local out = {}
	for i, c in ipairs(rawget(self, "__children")) do
		out[i] = c
	end
	return out
end
function methods.GetDescendants(self)
	local out = {}
	local function walk(node)
		for _, c in ipairs(rawget(node, "__children")) do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function methods.IsDescendantOf(self, other)
	local p = rawget(self, "__parent")
	while p do
		if p == other then
			return true
		end
		p = rawget(p, "__parent")
	end
	return false
end
function methods.Destroy(self)
	self.Parent = nil
	rawset(self, "__destroyed", true)
end
function methods.ClearAllChildren(self)
	for _, c in ipairs(methods.GetChildren(self)) do
		c.Parent = nil
	end
end
function methods.Clone(self)
	local copy = Instance.new(rawget(self, "__class"))
	for k, v in pairs(rawget(self, "__props")) do
		rawget(copy, "__props")[k] = v
	end
	for _, c in ipairs(rawget(self, "__children")) do
		methods.Clone(c).Parent = copy
	end
	return copy
end
function methods.GetPropertyChangedSignal(self, prop)
	local sigs = rawget(self, "__propSignals")
	if not sigs[prop] then
		sigs[prop] = Signal.new(rawget(self, "__class") .. ":" .. prop)
	end
	return sigs[prop]
end
function methods.SetAttribute(self, name, value)
	local attrs = rawget(self, "__attrs")
	local old = attrs[name]
	attrs[name] = value
	if old ~= value then
		local sig = rawget(self, "__attrSignals")[name]
		if sig then
			sig:Fire()
		end
		local any = rawget(self, "__lazy").AttributeChanged
		if any then
			any:Fire(name)
		end
	end
end
function methods.GetAttribute(self, name)
	return rawget(self, "__attrs")[name]
end
function methods.GetAttributes(self)
	return rawget(self, "__attrs")
end
function methods.GetAttributeChangedSignal(self, name)
	local sigs = rawget(self, "__attrSignals")
	if not sigs[name] then
		sigs[name] = Signal.new("attr:" .. name)
	end
	return sigs[name]
end
function methods.GetFullName(self)
	return tostring(self)
end
function methods.TweenPosition() end
function methods.TweenSize() end
function methods.TweenSizeAndPosition() end
function methods.GetTags()
	return {}
end
function methods.HasTag()
	return false
end
function methods.GetPivot()
	return Dummy("pivot")
end

function Instance.new(class, parent)
	local self = setmetatable({
		__class = class, __props = { Name = class }, __children = {}, __lazy = {}, __propSignals = {},
		__attrs = {}, __attrSignals = {},
	}, instMeta)
	-- Where the element was made: "HudClient.client.lua:983", the name the report uses.
	local site
	for level = 2, 8 do
		local info = debug.getinfo(level, "Sl")
		if not info then
			break
		end
		local src = info.source or ""
		if src:sub(1, 1) == "=" and not src:find("UiKit", 1, true) and not src:find("mock", 1, true) then
			site = src:sub(2) .. ":" .. tostring(info.currentline)
			break
		end
	end
	rawset(self, "__site", site or "?")
	table.insert(W.created, self)
	if parent then
		self.Parent = parent
	end
	return self
end
W.Instance = Instance
W.instClass = function(i)
	return rawget(i, "__class")
end
W.instSite = function(i)
	return rawget(i, "__site")
end
W.special = function(i)
	local sp = rawget(i, "__special")
	if not sp then
		sp = {}
		rawset(i, "__special", sp)
	end
	return sp
end
W.isInstance = function(v)
	return type(v) == "table" and getmetatable(v) == instMeta
end

--------------------------------------------------------------------------------
-- Geometry: the box Roblox would draw a GuiObject in, in screen pixels.
--------------------------------------------------------------------------------
local function uiScaleOf(inst)
	for _, c in ipairs(rawget(inst, "__children")) do
		if rawget(c, "__class") == "UIScale" then
			return c.Scale
		end
	end
	return 1
end

-- Returns { x, y, w, h, k } where k is the cumulative UIScale applied to things inside it.
function W.rectOf(inst)
	local parent = rawget(inst, "__parent")
	local class = rawget(inst, "__class")
	if class == "ScreenGui" or class == "PlayerGui" or not parent then
		local vp = W.viewport
		local top = 0
		if class == "ScreenGui" and not inst.IgnoreGuiInset then
			top = W.inset
		end
		return { x = 0, y = top, w = vp.X, h = vp.Y - top, k = 1 }
	end
	if not GUI_CLASSES[class] then
		return nil
	end
	local p = W.rectOf(parent)
	if not p then
		return nil
	end
	local pk = p.k
	local size, pos, anchor = inst.Size, inst.Position, inst.AnchorPoint
	local s = uiScaleOf(inst)
	-- A scale component is a fraction of the parent's drawn box; an offset is scaled by every UIScale
	-- above and on this element.
	local w = (size.X.Scale * p.w / pk + size.X.Offset) * pk * s
	local h = (size.Y.Scale * p.h / pk + size.Y.Offset) * pk * s
	-- AutomaticSize Y with a list layout: the content's height (BoonHud's panel is built this way).
	if h == 0 and rawget(inst, "__props").AutomaticSize ~= nil then
		local sum, count, gap, pad = 0, 0, 0, 0
		for _, c in ipairs(rawget(inst, "__children")) do
			local cc = rawget(c, "__class")
			if GUI_CLASSES[cc] and c.Visible then
				sum = sum + c.Size.Y.Offset
				count = count + 1
			elseif cc == "UIListLayout" then
				gap = c.Padding and c.Padding.Offset or 0
			elseif cc == "UIPadding" then
				pad = (c.PaddingTop and c.PaddingTop.Offset or 0) + (c.PaddingBottom and c.PaddingBottom.Offset or 0)
			end
		end
		h = (sum + math.max(count - 1, 0) * gap + pad) * pk * s
	end
	local px = p.x + pos.X.Scale * p.w + pos.X.Offset * pk
	local py = p.y + pos.Y.Scale * p.h + pos.Y.Offset * pk
	return { x = px - anchor.X * w, y = py - anchor.Y * h, w = w, h = h, k = pk * s }
end

-- Is anything of this element actually drawn: its own chain visible and enabled, and some pixel of it
-- or of what it holds not fully transparent.
local function paints(inst)
	local class = rawget(inst, "__class")
	if not GUI_CLASSES[class] or not inst.Visible then
		return false
	end
	if class == "CanvasGroup" and inst.GroupTransparency >= 1 then
		return false
	end
	if inst.BackgroundTransparency < 1 then
		return true
	end
	if (class == "TextLabel" or class == "TextButton" or class == "TextBox") and inst.Text ~= "" and inst.TextTransparency < 1 then
		return true
	end
	if (class == "ImageLabel" or class == "ImageButton") and inst.Image ~= "" and inst.ImageTransparency < 1 then
		return true
	end
	for _, c in ipairs(rawget(inst, "__children")) do
		if paints(c) then
			return true
		end
	end
	return false
end
W.paints = paints

-- Every drawn top-level element of every enabled ScreenGui under PlayerGui (and the children of a
-- transparent full-screen holder, which is a container rather than an element).
function W.drawn()
	local out = {}
	local function consider(inst, gui)
		if not paints(inst) then
			return
		end
		local r = W.rectOf(inst)
		if not r or r.w <= 0 or r.h <= 0 then
			return
		end
		local vp = W.viewport
		-- A transparent box that stacks its children with a list (the kill feed) draws only as far as
		-- its rows reach, not its whole box: measure the rows, from the top.
		if inst.BackgroundTransparency >= 1 and inst:FindFirstChildOfClass("UIListLayout") then
			local list = inst:FindFirstChildOfClass("UIListLayout")
			local gap = list.Padding and list.Padding.Offset or 0
			local used, count = 0, 0
			for _, c in ipairs(rawget(inst, "__children")) do
				if paints(c) then
					used = used + c.Size.Y.Offset
					count = count + 1
				end
			end
			local h = (used + math.max(count - 1, 0) * gap) * r.k
			r = { x = r.x, y = r.y, w = r.w, h = h, k = r.k }
		end
		local fullScreen = r.w >= vp.X * 0.95 and r.h >= vp.Y * 0.95
		if fullScreen and inst.BackgroundTransparency >= 1 then
			for _, c in ipairs(rawget(inst, "__children")) do
				consider(c, gui)
			end
			return
		end
		table.insert(out, { inst = inst, site = rawget(inst, "__site"), name = inst.Name, gui = gui.Name, rect = r, full = fullScreen })
	end
	for _, gui in ipairs(rawget(W.playerGui, "__children")) do
		if rawget(gui, "__class") == "ScreenGui" and gui.Enabled then
			for _, c in ipairs(rawget(gui, "__children")) do
				consider(c, gui)
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- The world
--------------------------------------------------------------------------------
function W.setup(vx, vy, touch, keyboard)
	W.viewport = Vector2.new(vx, vy)
	W.inset = 36
	local services = {}
	local function service(name, special)
		local s = Instance.new(name)
		s.Name = name
		rawset(s, "__special", special or {})
		services[name] = s
		return s
	end

	W.RenderStepped = Signal.new("RenderStepped")
	W.Heartbeat = Signal.new("Heartbeat")
	service("RunService", {
		RenderStepped = W.RenderStepped, Heartbeat = W.Heartbeat, Stepped = Signal.new("Stepped"),
		PreRender = W.RenderStepped,
		IsStudio = function() return false end,
		IsClient = function() return true end,
		IsServer = function() return false end,
		BindToRenderStep = function() end,
		UnbindFromRenderStep = function() end,
	})
	W.UserInputService = service("UserInputService", {
		GetLastInputType = function()
			return touch and _G.Enum.UserInputType.Touch or _G.Enum.UserInputType.Keyboard
		end,
		GetMouseLocation = function() return Vector2.new(0, 0) end,
		IsKeyDown = function() return false end,
		GetConnectedGamepads = function() return {} end,
		GetFocusedTextBox = function() return nil end,
	})
	W.UserInputService.TouchEnabled = touch
	W.UserInputService.KeyboardEnabled = keyboard
	W.UserInputService.GamepadEnabled = false
	W.UserInputService.MouseEnabled = not touch
	service("GuiService", {
		GetGuiInset = function() return Vector2.new(0, W.inset), Vector2.new(0, 0) end,
	})
	service("TweenService", {
		Create = function(_, inst, _, goals)
			local tween = { Completed = Signal.new("tween"), PlaybackState = Dummy("state") }
			function tween.Play()
				for k, v in pairs(goals or {}) do
					inst[k] = v
				end
			end
			function tween.Cancel() end
			function tween.Pause() end
			function tween.Destroy() end
			return tween
		end,
		GetValue = function(_, t) return t end,
	})
	local players = service("Players")
	local player = Instance.new("Player")
	player.Name = "Tester"
	player.DisplayName = "Tester"
	player.UserId = 1
	rawset(player, "__special", {
		Character = W.NIL,
		GetMouse = function() return Dummy("mouse") end,
		Kick = function() end,
	})
	W.playerGui = Instance.new("PlayerGui")
	W.playerGui.Name = "PlayerGui"
	W.playerGui.Parent = player
	player.Parent = players
	rawset(players, "__special", {
		LocalPlayer = player,
		GetPlayers = function() return { player } end,
		GetPlayerFromCharacter = function() return nil end,
		GetPlayerByUserId = function() return nil end,
	})
	W.player = player

	-- A character with a root part, so per-frame code that needs one runs.
	local character = Instance.new("Model")
	character.Name = "Tester"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Position = Vector3.new(0, 5, 0)
	root.Parent = character
	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.Health, humanoid.MaxHealth = 100, 100
	rawset(humanoid, "__special", { SeatPart = W.NIL, RootPart = root })
	humanoid.Parent = character
	W.character = character

	local replicated = service("ReplicatedStorage")
	local shared = Instance.new("Folder")
	shared.Name = "Shared"
	shared.Parent = replicated
	local function moduleFactory(name)
		local m = Instance.new("ModuleScript")
		m.Name = name
		return m
	end
	rawset(shared, "__factory", moduleFactory)
	rawset(replicated, "__factory", moduleFactory)
	W.scriptsFolder = Instance.new("Folder")
	W.scriptsFolder.Name = "StarterPlayerScripts"
	rawset(W.scriptsFolder, "__factory", moduleFactory)
	rawset(W.playerGui, "__factory", function() return nil end)

	local camera = Instance.new("Camera")
	camera.ViewportSize = W.viewport
	camera.FieldOfView = 70
	local cf = Dummy("CFrame")
	camera.CFrame = setmetatable({ LookVector = Vector3.new(0, 0, -1), Position = Vector3.new(0, 10, 10),
		UpVector = Vector3.new(0, 1, 0), RightVector = Vector3.new(1, 0, 0) }, { __index = function() return cf end })
	rawset(camera, "__special", {
		WorldToViewportPoint = function() return Vector3.new(0, 0, -1), false end,
		WorldToScreenPoint = function() return Vector3.new(0, 0, -1), false end,
		ViewportPointToRay = function() return { Origin = Vector3.new(0, 0, 0), Direction = Vector3.new(0, 0, -1) } end,
		ScreenPointToRay = function() return { Origin = Vector3.new(0, 0, 0), Direction = Vector3.new(0, 0, -1) } end,
	})
	W.camera = camera
	local workspaceInst = Instance.new("Workspace")
	workspaceInst.Name = "Workspace"
	rawset(workspaceInst, "__special", {
		CurrentCamera = camera,
		Raycast = function() return nil end,
		GetServerTimeNow = function() return W.now end,
		Blockcast = function() return nil end,
		Spherecast = function() return nil end,
		GetPartBoundsInBox = function() return {} end,
		GetPartBoundsInRadius = function() return {} end,
		GetPartsInPart = function() return {} end,
	})
	W.workspace = workspaceInst
	W.services = services
	W.now = 1000

	local game = Instance.new("DataModel")
	rawset(game, "__special", {
		GetService = function(_, name)
			return services[name] or service(name)
		end,
		PlaceId = 0,
		JobId = "",
	})
	W.game = game
end

-- Remotes: one object per name, so a handler a script connects can be fired by name.
W.remotes = {}
local function remote(name)
	if not W.remotes[name] then
		W.remotes[name] = {
			OnClientEvent = Signal.new("remote:" .. name),
			OnClientInvoke = nil,
			FireServer = function() end,
			InvokeServer = function() return nil end,
			Name = name,
		}
	end
	return W.remotes[name]
end
W.fire = function(name, ...)
	remote(name).OnClientEvent:Fire(...)
end

local settingsValues = { Compass = true, Minimap = true, ThirdPerson = true }
local function settingsMock()
	return setmetatable({
		Get = function(id)
			local v = settingsValues[id]
			if v == nil then
				return true
			end
			return v
		end,
		Set = function() end,
		Changed = Signal.new("Settings.Changed"),
		KeyLabel = function() return "Q" end,
		KeyFor = function() return Dummy("Enum.KeyCode") end,
	}, { __index = function(_, k) return Dummy("Settings." .. k) end })
end

local REAL = {}
W.real = REAL

-- Builds the environment a script or module runs in.
local function envFor(scriptInst)
	local env = setmetatable({}, { __index = _G })
	env.script = scriptInst
	env.game = W.game
	env.workspace = W.workspace
	env.Workspace = W.workspace
	return env
end

local loaded = {}
local function requireModule(target)
	if type(target) ~= "table" then
		return Dummy("require")
	end
	if W.isDummy(target) then
		return Dummy("module")
	end
	if loaded[target] ~= nil then
		return loaded[target]
	end
	local name = target.Name
	local result
	if name == "Remotes" then
		result = setmetatable({ Event = remote, Function = remote, UnreliableEvent = remote }, {
			__index = function(_, k) return Dummy("Remotes." .. k) end,
		})
	elseif name == "Settings" then
		result = settingsMock()
	elseif W.sources[name] then
		local fn, err = compileChunk(W.sources[name], "=" .. name, "t", envFor(target))
		if not fn then
			error("compile " .. name .. ": " .. tostring(err))
		end
		result = fn()
	else
		result = Dummy(name)
	end
	loaded[target] = result
	return result
end

-- Globals every script sees.
local function installGlobals()
	_G.Vector2, _G.Vector3, _G.UDim, _G.UDim2, _G.Color3 = Vector2, Vector3, UDim, UDim2, Color3
	_G.Instance = Instance
	_G.Enum = Dummy("Enum")
	_G.TweenInfo = { new = function() return Dummy("TweenInfo") end }
	_G.NumberSequence = { new = function() return Dummy("NumberSequence") end }
	_G.NumberSequenceKeypoint = { new = function() return Dummy("NumberSequenceKeypoint") end }
	_G.ColorSequence = { new = function() return Dummy("ColorSequence") end }
	_G.ColorSequenceKeypoint = { new = function() return Dummy("ColorSequenceKeypoint") end }
	_G.NumberRange = { new = function() return Dummy("NumberRange") end }
	_G.Rect = { new = function() return Dummy("Rect") end }
	_G.CFrame = setmetatable({ new = function() return Dummy("CFrame") end }, { __index = function() return function() return Dummy("CFrame") end end })
	_G.RaycastParams = { new = function() return Dummy("RaycastParams") end }
	_G.OverlapParams = { new = function() return Dummy("OverlapParams") end }
	_G.PhysicalProperties = { new = function() return Dummy("PhysicalProperties") end }
	_G.Font = { new = function() return Dummy("Font") end, fromEnum = function() return Dummy("Font") end }
	_G.Random = { new = function() return { NextNumber = function() return 0.5 end, NextInteger = function(_, a) return a end } end }
	_G.BrickColor = { new = function() return Dummy("BrickColor") end }
	_G.DateTime = { now = function() return { UnixTimestamp = 0, FormatLocalTime = function() return "" end } end }
	_G.tick = function() return W.now end
	_G.time = function() return W.now end
	_G.typeof = function(v)
		if type(v) == "table" then
			if getmetatable(v) == instMeta then
				return "Instance"
			end
			return rawget(v, "__type") or "table"
		end
		return type(v)
	end
	_G.warn = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring((select(i, ...)))
		end
		note(W.warnings, table.concat(parts, " "))
	end
	_G.print = function() end
	_G.require = requireModule
	_G.task = {
		spawn = function(fn, ...)
			local co = type(fn) == "thread" and fn or coroutine.create(fn)
			local ok, err = coroutine.resume(co, ...)
			if not ok then
				note(W.errors, "task.spawn: " .. tostring(err))
			end
			return co
		end,
		defer = function(fn, ...)
			return _G.task.spawn(fn, ...)
		end,
		delay = function() return nil end,
		wait = function()
			if coroutine.isyieldable() then
				coroutine.yield()
			end
			return 0.03
		end,
		cancel = function() end,
		desynchronize = function() end,
		synchronize = function() end,
	}
	_G.delay = _G.task.delay
	_G.spawn = _G.task.spawn
	_G.wait = _G.task.wait
	math.clamp = function(x, lo, hi)
		return math.max(lo, math.min(hi, x))
	end
	math.sign = function(x)
		return x > 0 and 1 or (x < 0 and -1 or 0)
	end
	math.round = function(x)
		return math.floor(x + 0.5)
	end
	math.atan2 = function(y, x)
		return math.atan(y, x)
	end
	math.noise = function() return 0 end
	math.pow = function(a, b) return a ^ b end
	math.log10 = function(x) return math.log(x, 10) end
	table.clear = function(t)
		for k in pairs(t) do
			t[k] = nil
		end
	end
	table.find = function(t, v)
		for i, x in ipairs(t) do
			if x == v then
				return i
			end
		end
		return nil
	end
	table.create = function(n, v)
		local t = {}
		for i = 1, n do
			t[i] = v
		end
		return t
	end
	table.freeze = function(t) return t end
	table.isfrozen = function() return false end
	table.clone = function(t)
		local c = {}
		for k, v in pairs(t) do
			c[k] = v
		end
		return c
	end
	table.getn = function(t) return #t end
	local format = string.format
	string.format = function(fmt, ...)
		local args = table.pack(...)
		local ok, out = pcall(format, fmt, table.unpack(args, 1, args.n))
		if ok then
			return out
		end
		for i = 1, args.n do
			if type(args[i]) == "number" then
				args[i] = math.floor(args[i])
			elseif type(args[i]) ~= "string" then
				args[i] = tostring(args[i])
			end
		end
		return format(fmt, table.unpack(args, 1, args.n))
	end
	-- Luau's string functions would error on an inert stand-in too, but the scripts only reach one
	-- when the mock has not modelled something; carry on with its name instead.
	for _, name in ipairs({ "upper", "lower", "len", "rep" }) do
		local original = string[name]
		string[name] = function(s, ...)
			if type(s) ~= "string" and type(s) ~= "number" then
				s = tostring(s)
			end
			return original(s, ...)
		end
	end
	string.split = function(s, sep)
		local out = {}
		for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
			table.insert(out, part)
		end
		return out
	end
end

-- Runs one LocalScript by name, with its own `script` object under StarterPlayerScripts.
function W.runScript(name)
	local scriptInst = Instance.new("LocalScript")
	scriptInst.Name = name
	scriptInst.Parent = W.scriptsFolder
	local fn, err = compileChunk(W.sources[name], "=" .. name, "t", envFor(scriptInst))
	if not fn then
		error("compile " .. name .. ": " .. tostring(err))
	end
	local ok, runErr = xpcall(fn, debug.traceback)
	if not ok then
		note(W.errors, name .. " (load): " .. tostring(runErr))
	end
	return ok
end

-- Module scripts the real sources are available for sit in the StarterPlayerScripts folder.
function W.addModule(name)
	local m = Instance.new("ModuleScript")
	m.Name = name
	m.Parent = W.scriptsFolder
end

function W.setViewport(x, y)
	W.viewport = Vector2.new(x, y)
	W.camera.ViewportSize = W.viewport
end

function W.frame(n)
	for _ = 1, n or 1 do
		W.now = W.now + 1 / 60
		W.RenderStepped:Fire(1 / 60)
		W.Heartbeat:Fire(1 / 60)
	end
end

function W.install()
	installGlobals()
end

return W
