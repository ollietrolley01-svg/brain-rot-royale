-- Player settings: rebindable keys, audio volumes, camera and a few gameplay toggles. ModuleScript,
-- shared by every client script (a ModuleScript is only run once per client, so they all see the
-- same table).
--
-- Saved on the player's profile through the SaveSettings remote, debounced so dragging a slider
-- doesn't fire a request per frame. Anything that depends on a setting listens to
-- `Settings.Changed`, which passes the id that changed — or "*" after a load or a reset.
--
-- Keyboard actions bound through `Settings.Bind` rebind themselves when their key changes.
-- Mouse buttons and gamepad inputs stay fixed and are passed as extra inputs.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local Settings = {}

Settings.Actions = {
	{ id = "Reload", label = "Reload", default = "R", group = "Combat" },
	{ id = "Sprint", label = "Sprint", default = "LeftShift", group = "Combat" },
	{ id = "Companion", label = "Companion ability", default = "G", group = "Combat" },
	{ id = "Inspect", label = "Inspect weapon", default = "V", group = "Combat" },
	{ id = "ToggleCamera", label = "Toggle first / third person", default = "T", group = "Combat" },
	{ id = "Zoom", label = "Zoom the camera out a step (the wheel switches hotbar items)", default = "Z", group = "Combat" },
	{ id = "MovementItem", label = "Use the first movement item in your bag (keeps your gun out)", default = "X", group = "Combat" },
	{ id = "Crouch", label = "Crouch — slides if you're sprinting (hold, or a toggle in Gameplay)", default = "C", group = "Combat" },
	{ id = "Slot1", label = "Slot 1", default = "One", group = "Loadout" },
	{ id = "Slot2", label = "Slot 2", default = "Two", group = "Loadout" },
	{ id = "Slot3", label = "Slot 3", default = "Three", group = "Loadout" },
	{ id = "Slot4", label = "Slot 4", default = "Four", group = "Loadout" },
	{ id = "Slot5", label = "Slot 5", default = "Five", group = "Loadout" },
	{ id = "Slot6", label = "Slot 6", default = "Six", group = "Loadout" },
	{ id = "Slot7", label = "Slot 7", default = "Seven", group = "Loadout" },
	{ id = "Slot8", label = "Slot 8", default = "Eight", group = "Loadout" },
	{ id = "NextSlot", label = "Next slot", default = "Q", group = "Loadout" },
	{ id = "Inventory", label = "Inventory (rearrange the hotbar)", default = "B", group = "Loadout" },
	{ id = "Menu", label = "Open menu", default = "M", group = "General" },
	{ id = "Quests", label = "Quests and challenges", default = "J", group = "General" },
	{ id = "Ready", label = "Ready up", default = "F", group = "General" },
	{ id = "SpectateNext", label = "Spectate next player", default = "E", group = "General" },
	{ id = "SpectateLeave", label = "Leave spectating (back to the lobby)", default = "L", group = "General" },
}

Settings.Sliders = {
	{ id = "MasterVolume", label = "Master volume", default = 1, min = 0, max = 1, step = 0.05, percent = true, group = "Audio" },
	{ id = "WeaponVolume", label = "Weapons and hits", default = 1, min = 0, max = 1, step = 0.05, percent = true, group = "Audio" },
	{ id = "EffectsVolume", label = "Effects and pickups", default = 1, min = 0, max = 1, step = 0.05, percent = true, group = "Audio" },
	{ id = "InterfaceVolume", label = "Menus and crates", default = 1, min = 0, max = 1, step = 0.05, percent = true, group = "Audio" },
	{ id = "FieldOfView", label = "Field of view", default = 70, min = 60, max = 95, step = 1, group = "Camera" },
	{ id = "LookSensitivity", label = "Look sensitivity", default = 1, min = 0.2, max = 2.5, step = 0.05, group = "Camera" },
	{ id = "AimSensitivity", label = "Aiming sensitivity", default = 0.7, min = 0.2, max = 1.5, step = 0.05, group = "Camera" },
}

Settings.Toggles = {
	{ id = "ThirdPerson", label = "Third-person camera (over the shoulder)", default = false, group = "Gameplay" },
	{ id = "ScreenShake", label = "Screen shake", default = true, group = "Gameplay" },
	{ id = "DamageNumbers", label = "Damage numbers", default = true, group = "Gameplay" },
	{ id = "GunSway", label = "Gun sway and bob", default = true, group = "Gameplay" },
	{ id = "AmbientParticles", label = "Ambient particles (pollen, dust, fireflies)", default = true, group = "Gameplay" },
	{ id = "AutoReload", label = "Auto-reload when the magazine runs dry", default = true, group = "Gameplay" },
	{ id = "Compass", label = "Compass strip under the storm timer", default = true, group = "Gameplay" },
	{ id = "CrouchToggle", label = "Crouch is a toggle instead of hold", default = false, group = "Gameplay" },
	-- The tab beside MENU sets this too (StarterPlayerScripts/MenuStackToggle).
	{ id = "MenuStackCollapsed", label = "Tuck the menu, bundle and quest buttons behind a tab", default = false, group = "Gameplay" },
}

-- Keys that would break the game or Roblox itself if an action took them.
Settings.ReservedKeys = {
	Escape = true, Slash = true, Tab = true, Backquote = true, Unknown = true,
	W = true, A = true, S = true, D = true, Space = true,
	Up = true, Down = true, Left = true, Right = true,
}

local KEY_LABELS = {
	One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9", Zero = "0",
	LeftShift = "L-Shift", RightShift = "R-Shift", LeftControl = "L-Ctrl", RightControl = "R-Ctrl",
	LeftAlt = "L-Alt", RightAlt = "R-Alt", CapsLock = "Caps", Return = "Enter", Backspace = "Backspace",
	KeypadOne = "Num 1", KeypadTwo = "Num 2", KeypadThree = "Num 3", KeypadFour = "Num 4", KeypadFive = "Num 5",
	KeypadSix = "Num 6", KeypadSeven = "Num 7", KeypadEight = "Num 8", KeypadNine = "Num 9", KeypadZero = "Num 0",
	Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", Semicolon = ";", Quote = "'",
	Comma = ",", Period = ".", BackSlash = "\\",
}

local changedEvent = Instance.new("BindableEvent")
Settings.Changed = changedEvent.Event

local byId = {}
for _, list in ipairs({ Settings.Actions, Settings.Sliders, Settings.Toggles }) do
	for _, entry in ipairs(list) do
		byId[entry.id] = entry
	end
end

local values = { keys = {}, numbers = {}, toggles = {} }

local function keyCodeFromName(name)
	if type(name) ~= "string" then
		return nil
	end
	local ok, keyCode = pcall(function()
		return Enum.KeyCode[name]
	end)
	return ok and keyCode or nil
end

function Settings.Key(actionId)
	local entry = byId[actionId]
	local name = values.keys[actionId] or (entry and entry.default)
	return keyCodeFromName(name) or Enum.KeyCode.Unknown
end

function Settings.KeyLabel(actionId)
	local keyCode = Settings.Key(actionId)
	return KEY_LABELS[keyCode.Name] or keyCode.Name
end

function Settings.Get(id)
	local entry = byId[id]
	if not entry then
		return nil
	end
	if type(entry.default) == "boolean" then
		local value = values.toggles[id]
		if value == nil then
			return entry.default
		end
		return value
	end
	local value = values.numbers[id]
	if type(value) ~= "number" then
		return entry.default
	end
	return value
end

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------

local SAVE_DELAY = 1.5
local saveToken = 0

local function scheduleSave()
	saveToken += 1
	local token = saveToken
	task.delay(SAVE_DELAY, function()
		if token ~= saveToken then
			return
		end
		-- Looked up here rather than at require time: on the client that lookup waits for the
		-- server to create the remote, and every script requiring Sfx would wait along with it.
		pcall(function()
			Remotes.Function("SaveSettings"):InvokeServer(values)
		end)
	end)
end

local function fire(id)
	changedEvent:Fire(id)
end

-- Binding a key another action already uses swaps the two, so no action is ever left unbound
-- and no key does two things. Returns false for reserved or unknown keys.
function Settings.SetKey(actionId, keyCode)
	local entry = byId[actionId]
	if not entry or entry.default == nil or type(entry.default) ~= "string" then
		return false
	end
	if typeof(keyCode) ~= "EnumItem" or Settings.ReservedKeys[keyCode.Name] then
		return false
	end

	local previous = Settings.Key(actionId)
	if previous == keyCode then
		return true
	end
	for _, other in ipairs(Settings.Actions) do
		if other.id ~= actionId and Settings.Key(other.id) == keyCode then
			values.keys[other.id] = previous.Name
			fire(other.id)
		end
	end
	values.keys[actionId] = keyCode.Name
	fire(actionId)
	scheduleSave()
	return true
end

function Settings.Set(id, value)
	local entry = byId[id]
	if not entry then
		return
	end
	if type(entry.default) == "boolean" then
		values.toggles[id] = value == true
	elseif type(entry.default) == "number" and type(value) == "number" then
		local stepped = math.floor((value - entry.min) / entry.step + 0.5) * entry.step + entry.min
		values.numbers[id] = math.clamp(stepped, entry.min, entry.max)
	else
		return
	end
	fire(id)
	scheduleSave()
end

function Settings.ResetGroup(group)
	for _, list in ipairs({ Settings.Actions, Settings.Sliders, Settings.Toggles }) do
		for _, entry in ipairs(list) do
			if not group or entry.group == group then
				values.keys[entry.id] = nil
				values.numbers[entry.id] = nil
				values.toggles[entry.id] = nil
			end
		end
	end
	fire("*")
	scheduleSave()
end

--------------------------------------------------------------------------------
-- Binding
--------------------------------------------------------------------------------

local bindings = {}

-- The shared touch buttons (StarterPlayerScripts/TouchControls), looked up the first time a binding
-- with a touch button is made. Only when its flag is on does a touch button go there instead of to
-- ContextActionService; with the flag off everything below behaves exactly as it always has.
local touchControls = nil
local function touchControlsOn()
	if touchControls == nil then
		local ok, module = pcall(function()
			return require(script.Parent:WaitForChild("TouchControls", 5))
		end)
		touchControls = ok and module or false
	end
	return touchControls and touchControls.Enabled == true
end

local function applyBinding(binding)
	ContextActionService:UnbindAction(binding.name)
	local forward = binding.touch ~= nil and touchControlsOn()
	ContextActionService:BindAction(binding.name, binding.handler, binding.touch ~= nil and not forward, Settings.Key(binding.actionId),
		table.unpack(binding.extras))
	if forward then
		-- The slot comes from the action's name inside TouchControls; `touch.slot` overrides it.
		touchControls.Bind(binding.name, { slot = binding.touch.slot, label = binding.touch.title, handler = binding.handler })
	elseif binding.touch then
		ContextActionService:SetTitle(binding.name, binding.touch.title)
		ContextActionService:SetPosition(binding.name, binding.touch.position)
	end
end

-- Binds `handler` to the action's current key plus any fixed `extras` (gamepad buttons, mouse
-- buttons), and keeps it bound to the right key through rebinds. `touch`, when given, is
-- { title, position } for an on-screen mobile button.
function Settings.Bind(name, actionId, handler, touch, ...)
	local binding = { name = name, actionId = actionId, handler = handler, touch = touch, extras = { ... } }
	bindings[name] = binding
	applyBinding(binding)
end

-- Gamepad face names, for a legend on a console. Declared HERE and not beside KeyLabel: `bindings`
-- is a local declared further down the file than KeyLabel is, so a copy of this next to KeyLabel
-- would read a nil upvalue and fail only once somebody plugged a pad in.
--
-- A second hand-written table of "which button is inventory" would drift from the binds the first
-- time anybody moved one, so this reads the ACTUAL extras handed to Settings.Bind, and answers nil
-- when an action has no gamepad button at all -- the honest answer for Zoom and Inspect, and the
-- reason a legend drops those rows on a pad rather than printing a key that does nothing.
local GAMEPAD_LABELS = {
	ButtonA = "A", ButtonB = "B", ButtonX = "X", ButtonY = "Y",
	ButtonL1 = "LB", ButtonR1 = "RB", ButtonL2 = "LT", ButtonR2 = "RT",
	ButtonL3 = "LS", ButtonR3 = "RS", ButtonSelect = "Back", ButtonStart = "Start",
	-- ASCII, not arrow glyphs. An arrow would be shorter and read better, and it assumes
	-- GothamBold renders that codepoint -- if it does not, every d-pad row becomes a tofu box,
	-- which is exactly what the menu's close button did with U+2715. Nothing can be seen on a
	-- screen tonight, so these stay ASCII until a render says the glyph is safe.
	DPadUp = "D-Pad Up", DPadDown = "D-Pad Dn", DPadLeft = "D-Pad L", DPadRight = "D-Pad R",
}

function Settings.GamepadLabel(actionId)
	for _, binding in pairs(bindings) do
		if binding.actionId == actionId then
			for _, extra in ipairs(binding.extras) do
				local label = typeof(extra) == "EnumItem" and GAMEPAD_LABELS[extra.Name]
				if label then
					return label
				end
			end
		end
	end
	return nil
end

Settings.Changed:Connect(function(id)
	for _, binding in pairs(bindings) do
		if id == "*" or binding.actionId == id then
			applyBinding(binding)
		end
	end
end)

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local function adopt(saved)
	if type(saved) ~= "table" then
		return
	end
	for id, name in pairs(type(saved.keys) == "table" and saved.keys or {}) do
		local entry = byId[id]
		local keyCode = keyCodeFromName(name)
		if entry and type(entry.default) == "string" and keyCode and not Settings.ReservedKeys[keyCode.Name] then
			values.keys[id] = keyCode.Name
		end
	end
	for id, value in pairs(type(saved.numbers) == "table" and saved.numbers or {}) do
		local entry = byId[id]
		if entry and type(entry.default) == "number" and type(value) == "number" and value == value then
			values.numbers[id] = math.clamp(value, entry.min, entry.max)
		end
	end
	for id, value in pairs(type(saved.toggles) == "table" and saved.toggles or {}) do
		local entry = byId[id]
		if entry and type(entry.default) == "boolean" and type(value) == "boolean" then
			values.toggles[id] = value
		end
	end
end

task.spawn(function()
	local ok, saved = pcall(function()
		return Remotes.Function("GetSettings"):InvokeServer()
	end)
	if ok then
		adopt(saved)
		fire("*")
	end
end)

return Settings
