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

-- Nothing is sent until the saved settings have come back (see Loading): a save REPLACES the stored
-- table, so defaults plus one change would wipe every custom bind and volume. Changes made before
-- then are kept here as { op, id, value } and replayed over the saved values once they arrive.
local loaded = false
local pendingEdits = {}

local function remember(op, id, value)
	if loaded then
		return
	end
	-- A slider drag is one Set per frame; only its last value matters.
	local last = pendingEdits[#pendingEdits]
	if op == "Set" and last and last[1] == op and last[2] == id then
		last[3] = value
	else
		table.insert(pendingEdits, { op, id, value })
	end
end

local function scheduleSave()
	if not loaded then
		return
	end
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
	remember("SetKey", actionId, keyCode)
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
	remember("Set", id, value)
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
	remember("ResetGroup", group)
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

-- Where the player is, from the same remotes CombatClient's inCombat() reads, so a button goes exactly
-- when pressing it would do nothing. Until the first MatchChanged arrives the state counts as a match.
local touchWatch = { wired = false, known = false, matchState = nil, hasLoadout = false, range = false,
	spectating = false, leaveBound = false, retry = false, waited = 0 }
local wireTouch

-- PhoneLayout, for the touch buttons' squares and for which of them the player's state has room for
-- (PhoneLayout.TouchSet: the on-foot set drops out of a vehicle's seat, the lobby and spectating, so the
-- seat's own buttons fit under ContextActionService's cap of seven). Looked up only on a touch screen;
-- anywhere else, and if it fails to load, every touch button behaves exactly as it always has.
local phoneLayout = nil
local function touchLayout()
	if phoneLayout == nil then
		phoneLayout = false
		local UserInputService = game:GetService("UserInputService")
		-- A touch screen with a keyboard is a laptop, which PhoneLayout.Mode gives the desktop HUD (Studio's
		-- device emulator excepted, as there): its buttons stay as they always were.
		local handheld = not UserInputService.KeyboardEnabled or game:GetService("RunService"):IsStudio()
		if UserInputService.TouchEnabled and handheld then
			local ok, module = pcall(function()
				return require(script.Parent:WaitForChild("PhoneLayout", 5))
			end)
			phoneLayout = ok and type(module) == "table" and type(module.TouchWanted) == "function" and module or false
		end
	end
	return phoneLayout or nil
end

local function applyBinding(binding)
	ContextActionService:UnbindAction(binding.name)
	local forward = binding.touch ~= nil and touchControlsOn()
	local layout = binding.touch ~= nil and not forward and touchLayout()
	if layout then
		wireTouch()
	end
	-- The button only while the player's state has a square for it (an on-foot action); the key and the
	-- pad stay bound either way.
	local button = binding.touch ~= nil and not forward
	if layout and layout.OnFoot[binding.name] then
		button = layout.TouchWanted(binding.name) == true
	end
	binding.buttonShown = button
	if binding.fixed then
		-- Settings.BindFixed: no rebindable key, only the fixed inputs.
		ContextActionService:BindAction(binding.name, binding.handler, button, table.unpack(binding.extras))
	else
		ContextActionService:BindAction(binding.name, binding.handler, button, Settings.Key(binding.actionId),
			table.unpack(binding.extras))
	end
	if forward then
		-- The slot comes from the action's name inside TouchControls; `touch.slot` overrides it.
		touchControls.Bind(binding.name, { slot = binding.touch.slot, label = binding.touch.title, handler = binding.handler })
	elseif button then
		ContextActionService:SetTitle(binding.name, binding.touch.title)
		if layout then
			layout.PlaceTouchButton(binding.name)
		else
			ContextActionService:SetPosition(binding.name, binding.touch.position)
		end
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

-- The same for an action with no rebindable key (FIRE on the left mouse and RT, AIM on the right mouse
-- and LT): bound to `...` only, but its touch button follows the player's state like the rest.
function Settings.BindFixed(name, handler, touch, ...)
	local binding = { name = name, handler = handler, touch = touch, extras = { ... }, fixed = true }
	bindings[name] = binding
	applyBinding(binding)
end

--------------------------------------------------------------------------------
-- Touch buttons by state (PhoneLayout.TouchSet decides; this applies it)
--------------------------------------------------------------------------------

local function touchContext()
	if touchWatch.spectating then
		return "spectate"
	elseif touchWatch.range then
		return "range"
	elseif not touchWatch.known or (touchWatch.matchState == "InProgress" and touchWatch.hasLoadout) then
		return "match"
	end
	return "lobby"
end

-- Whether a seat's own button (one bound by VehicleClient, VehicleWeaponClient, MountedGunClient or
-- ProjectileClient) that the state no longer has is still up. The on-foot buttons wait for it to go:
-- binding them first would ask ContextActionService for more than its seven, and the one past the cap is
-- drawn blank, or not at all, and stays that way.
local function staleSeatButton(layout)
	local wanted = {}
	local state = layout.TouchState
	for _, entry in ipairs(layout.TouchSet(state.context, state.seat, state.flags)) do
		wanted[entry.action] = true
	end
	for action in pairs(layout.TouchLabels) do
		if not layout.OnFoot[action] and not wanted[action] and action ~= "BRR_SeatLeave" then
			local ok, info = pcall(ContextActionService.GetBoundActionInfo, ContextActionService, action)
			if ok and type(info) == "table" and next(info) ~= nil and info.createTouchButton ~= false then
				return action
			end
		end
	end
	return nil
end

local function seatLeave(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		local Players = game:GetService("Players")
		local character = Players.LocalPlayer and Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.SeatPart then
			humanoid.Jump = true
		end
	end
	return Enum.ContextActionResult.Sink
end

-- Works the state out again and gives each on-foot binding its button, or takes it away, to match:
-- every button that goes, first; then the ones that come (only once nothing a seat bound is left over).
-- The seats' scripts call this just BEFORE they bind their buttons and just AFTER they unbind them, so the
-- count never goes over seven in between; it also runs on its own when the seat or the match changes.
function Settings.RefreshTouch()
	local layout = touchLayout()
	if not layout then
		return
	end
	wireTouch()
	local Players = game:GetService("Players")
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local state = layout.TouchState
	state.context = touchContext()
	state.seat = layout.SeatOf(humanoid)
	local forward = touchControlsOn()
	local gaining = {}
	for name, binding in pairs(bindings) do
		if binding.touch and layout.OnFoot[name] and not forward then
			local want = layout.TouchWanted(name) == true
			if binding.buttonShown and not want then
				applyBinding(binding)
			elseif want and not binding.buttonShown then
				table.insert(gaining, binding)
			end
		end
	end
	local wantLeave = layout.TouchWanted("BRR_SeatLeave") == true
	if touchWatch.leaveBound and not wantLeave then
		touchWatch.leaveBound = false
		ContextActionService:UnbindAction("BRR_SeatLeave")
	end
	local stale = (#gaining > 0 or (wantLeave and not touchWatch.leaveBound)) and staleSeatButton(layout)
	-- Waited on for two seconds at most: a player on foot is never left without FIRE because a seat's
	-- script failed to let go of its button.
	if stale and touchWatch.waited < 8 then
		-- Its owner unbinds it in a moment and calls this again; this looks again in case it does not.
		if not touchWatch.retry then
			touchWatch.waited += 1
			touchWatch.retry = true
			task.delay(0.25, function()
				touchWatch.retry = false
				Settings.RefreshTouch()
			end)
		end
		return
	end
	if stale then
		warn(string.format("[Settings] %s still has a touch button after its seat; the on-foot buttons come back anyway", stale))
	end
	touchWatch.waited = 0
	for _, binding in ipairs(gaining) do
		applyBinding(binding)
	end
	if wantLeave and not touchWatch.leaveBound then
		touchWatch.leaveBound = true
		-- Touch only: bound to a key nobody presses, so only the drawn button fires it (ProjectileClient's
		-- COOK does the same). A keyboard or a pad leaves the way it always has, with jump.
		ContextActionService:BindActionAtPriority("BRR_SeatLeave", seatLeave, true, Enum.ContextActionPriority.High.Value,
			Enum.KeyCode.World94)
		ContextActionService:SetTitle("BRR_SeatLeave", layout.TouchLabels.BRR_SeatLeave)
		layout.PlaceTouchButton("BRR_SeatLeave")
	end
end

-- A seat's own action (VehicleClient's BRAKE, VehicleWeaponClient's FIRE and AIM, MountedGunClient's
-- RELOAD and LEAVE, ProjectileClient's COOK): the on-foot buttons it has no room beside go first, then
-- it is bound with a touch button only if the state has a square for it, on that square. `touch` is
-- { title, position }; the position is only used if PhoneLayout is missing. `priority` nil binds at
-- ContextActionService's default, as BindAction does. The inputs follow.
function Settings.BindSeat(name, handler, touch, priority, ...)
	Settings.RefreshTouch()
	local layout = touchLayout()
	local button = touch ~= nil
	if layout then
		button = button and layout.TouchWanted(name) == true
	end
	if priority then
		ContextActionService:BindActionAtPriority(name, handler, button, priority, ...)
	else
		ContextActionService:BindAction(name, handler, button, ...)
	end
	if button then
		ContextActionService:SetTitle(name, touch.title)
		if layout then
			layout.PlaceTouchButton(name)
		else
			pcall(ContextActionService.SetPosition, ContextActionService, name, touch.position)
		end
	end
end

-- Unbinds a seat's action and gives the on-foot buttons back if the state has room for them again.
function Settings.UnbindSeat(name)
	ContextActionService:UnbindAction(name)
	Settings.RefreshTouch()
end

-- A flag the state carries besides the seat and the match: "cook" while a cookable throwable is in hand
-- (ProjectileClient; COOK takes RELOAD's square). Set BEFORE binding the button it makes room for.
function Settings.SetTouchFlag(flag, on)
	local layout = touchLayout()
	if not layout then
		return
	end
	layout.TouchState.flags[flag] = on == true or nil
	Settings.RefreshTouch()
end

-- Listens for the match and the seat, once, on a touch screen only.
function wireTouch()
	if touchWatch.wired then
		return
	end
	touchWatch.wired = true
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	local function watchCharacter(character)
		task.spawn(function()
			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid then
				humanoid:GetPropertyChangedSignal("SeatPart"):Connect(Settings.RefreshTouch)
			end
			Settings.RefreshTouch()
		end)
	end
	if player then
		player.CharacterAdded:Connect(watchCharacter)
		if player.Character then
			watchCharacter(player.Character)
		end
	end
	-- In the background: Remotes waits for each remote to replicate, and this runs inside the first bind.
	task.spawn(function()
		local ok, err = pcall(function()
			Remotes.Event("MatchChanged").OnClientEvent:Connect(function(match)
				touchWatch.known = true
				touchWatch.matchState = type(match) == "table" and match.state or nil
				Settings.RefreshTouch()
			end)
			Remotes.Event("LoadoutChanged").OnClientEvent:Connect(function(loadout)
				touchWatch.hasLoadout = loadout ~= nil
				Settings.RefreshTouch()
			end)
			Remotes.Event("RangeState").OnClientEvent:Connect(function(on)
				touchWatch.range = on == true
				Settings.RefreshTouch()
			end)
			Remotes.Event("Spectate").OnClientEvent:Connect(function(on)
				touchWatch.spectating = on == true
				Settings.RefreshTouch()
			end)
		end)
		if not ok then
			warn("[Settings] couldn't listen for the match state; the match's touch buttons stay up: " .. tostring(err))
		end
	end)
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

-- Retried until it answers: GetSettings gives up (nil) after 20 s, and a profile load that will still
-- succeed can take longer (a same-server rejoin waits on the old session's lock). Settling on the
-- defaults then would let the first change save them over everything stored.
task.spawn(function()
	local retryDelay = 5
	while true do
		local ok, saved = pcall(function()
			return Remotes.Function("GetSettings"):InvokeServer()
		end)
		if ok and type(saved) == "table" then
			-- Start again from the saved values, then replay what the player changed while waiting
			-- so it lands on top of them; the replay schedules the one save that carries both.
			for _, section in pairs(values) do
				for id in pairs(section) do
					section[id] = nil
				end
			end
			adopt(saved)
			loaded = true
			local edits = pendingEdits
			pendingEdits = {}
			for _, edit in ipairs(edits) do
				Settings[edit[1]](edit[2], edit[3])
			end
			fire("*")
			return
		end
		task.wait(retryDelay)
		retryDelay = math.min(retryDelay * 2, 30)
	end
end)

return Settings
