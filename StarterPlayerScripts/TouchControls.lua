-- Every on-screen touch button, in one place. ModuleScript: owners register their actions here instead of
-- asking ContextActionService to draw a button, and this module draws, sizes and places them all.
--
-- Why: ContextActionService draws at most SEVEN touch buttons (the game bound eight, and the last came up
-- blank), sizes them all 45 px whatever the screen, and places them wherever each owner guessed, so they
-- overlapped the minimap, the hotbar and each other. Here the buttons follow one layout, measured against
-- Roblox's own jump button and thumbstick (the phone layout map, 2026-09-17), with no cap.
--
-- FEATURE FLAG: nothing here does anything until `TouchControls.Enabled` is true. With it false, Bind does
-- nothing, no ScreenGui is ever made, and Settings.Bind and CombatClient keep ContextActionService's own
-- buttons exactly as before. It's flipped in one edit once the probe, the renders and a phone playtest pass.
--
--   TouchControls.Bind(name, {
--       slot = "fire",          -- a slot below; nil uses DefaultSlots[name], and failing that extra1/extra2
--       label = "FIRE",         -- text on the button
--       handler = fn,           -- a ContextActionService-style handler: (name, UserInputState, InputObject)
--       hold = true,            -- true: Begin on touch, End when that finger lifts (anywhere);
--                               -- false: Begin then End at once on touch (a press)
--       -- The handler always gets the REAL touch InputObject (UserInputType Touch) for Begin and for End,
--       -- never nil and never Cancel; exactly one End per Begin, and a button that goes away mid-hold
--       -- (unbound, hidden, disabled, a menu opening, death) sends its End first, with the same object.
--       contexts = { "match" }, -- where it shows: match / lobby / range / spectate (nil: the slot's defaults)
--       priority = 0,           -- two binds on one slot: the higher shows, the other waits
--       menuSafe = false,       -- stays up while a menu is open
--       onDrag = fn,            -- optional fn(delta: Vector2) while a finger is held on the button
--   })
--   TouchControls.Unbind(name)
--   TouchControls.SetState(name, { lit = bool, cooldown = 0..1, disabled = bool, label = "..." })
--   TouchControls.SlotRect(slot) -> { x, y, size } in screen pixels, or nil when that slot isn't showing
--   TouchControls.Layout(viewport) -> slot -> { x, y, size } (every slot, shown or not)
--   TouchControls.Changed          -- fires when anything shown or its layout changes
--
-- Where buttons show (contexts): "match" while you're alive in a match, "range" on the firing range,
-- "spectate" while spectating, "lobby" otherwise; and nothing (menuSafe excepted) while a menu is open. If
-- the context can't be worked out (a signal missing, an error), it counts as "match", with one warning:
-- nobody is ever left in a match without a fire button.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local TouchControls = {}

-- THE FLAG. False until the probe, the renders and a phone playtest have passed and the owners agree.
TouchControls.Enabled = false

-- For probes and galleries only: draw as if on a touch screen, into this parent, with this viewport.
TouchControls.ForceTouch = false
TouchControls.TestParent = nil
TouchControls.TestViewport = nil

-- Action name -> slot. Action names don't change when a button's title does.
TouchControls.DefaultSlots = {
	BRR_Fire = "fire",
	BRR_Aim = "aim",
	BRR_Sprint = "run",
	BRR_Slide = "slide",
	BRR_Reload = "reload",
	BRR_Companion = "pet",
	BRR_MovementItem = "move",
	BRR_ToggleCamera = "cam",
	BRR_SpectateNext = "spectate",
}

TouchControls.Slots = { "fire", "aim", "run", "slide", "reload", "pet", "move", "cam", "extra1", "extra2", "spectate" }

local SLOT_DEFAULTS = {
	fire = { contexts = { "match", "range" }, hold = true },
	aim = { contexts = { "match", "range" }, hold = true },
	run = { contexts = { "match", "lobby", "range" }, hold = true },
	slide = { contexts = { "match" }, hold = false },
	reload = { contexts = { "match", "range" }, hold = false },
	pet = { contexts = { "match", "lobby", "range" }, hold = false },
	move = { contexts = { "match" }, hold = false },
	cam = { contexts = { "match", "range" }, hold = false },
	extra1 = { contexts = { "match" }, hold = false },
	extra2 = { contexts = { "match" }, hold = false },
	spectate = { contexts = { "spectate" }, hold = false },
}

local changedEvent = Instance.new("BindableEvent")
TouchControls.Changed = changedEvent.Event

--------------------------------------------------------------------------------
-- Layout (the approved phone layout map; tools/hud_ux_probe.lua checks these numbers)
--------------------------------------------------------------------------------

-- Every slot's square on a viewport, in screen pixels (top-left x, y and the side), built out from where
-- Roblox puts its jump button: 70 px at (W-95, H-90) when the short side is 500 or less, else 120 px at
-- (W-170, H-210) (PlayerModule TouchJump.lua).
function TouchControls.Layout(viewport)
	local W, H = viewport.X, viewport.Y
	local small = math.min(W, H) <= 500
	local k = small and 1 or math.clamp(math.min(W, H) / 512, 1, 1.5)
	local g = 8 * k
	local jx, jy, js
	if small then
		jx, jy, js = W - 95, H - 90, 70
	else
		jx, jy, js = W - 170, H - 210, 120
	end
	local B, F = 48 * k, 72 * k
	local slots = {}
	local fireX, fireY = jx - g - F, jy + js - F
	slots.fire = { x = fireX, y = fireY, size = F }
	local colA = fireX + (F - B) / 2
	local colB = jx + (js - B) / 2
	local colC = colA - g - B
	local row = math.min(fireY, jy)
	local rows = {}
	for index = 1, 3 do
		row = row - g - B
		rows[index] = row
	end
	slots.aim = { x = colA, y = rows[1], size = B }
	slots.run = { x = colA, y = rows[2], size = B }
	slots.slide = { x = colA, y = rows[3], size = B }
	slots.reload = { x = colB, y = rows[1], size = B }
	slots.pet = { x = colB, y = rows[2], size = B }
	slots.move = { x = colB, y = rows[3], size = B }
	slots.extra1 = { x = colC, y = rows[1], size = B }
	slots.extra2 = { x = colC, y = rows[2], size = B }
	-- CAM at the top right, left of the MENU icon and the quest tab (44k each, 6 apart).
	local m = 44 * k
	-- On an upright screen that row drops below Roblox's own top bar, which reaches across 200 px of
	-- the top-left: the same rule PhoneLayout uses for the icons, and the probe checks the two agree.
	local iconsY = H > W and 58 or 6
	slots.cam = { x = W - g - m - 6 - 52 * k - 6 - m, y = iconsY, size = m }
	slots.spectate = { x = W / 2 - 32 * k, y = H - 8 - 44 * k, size = 44 * k, width = 64 * k }
	return slots
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local binds = {}       -- name -> bind
local widgets = {}     -- slot -> widget
local gui = nil
local warnedContext = false
local held = {}        -- InputObject -> { bind, widget }

local state = { known = false, matchState = nil, hasLoadout = false, range = false, spectating = false }

local function isTouchScreen()
	if TouchControls.ForceTouch then
		return true
	end
	local ok, preferred = pcall(function()
		return UserInputService.PreferredInput == Enum.PreferredInput.Touch
	end)
	local touch
	if ok then
		touch = preferred
	else
		touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.GamepadEnabled
	end
	local controls = true
	pcall(function()
		controls = GuiService.TouchControlsEnabled
	end)
	return touch and controls
end

local function viewport()
	if TouchControls.TestViewport then
		return TouchControls.TestViewport
	end
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(844, 390)
end

-- The contexts in force right now, and whether a menu is open. Anything that can't be told counts as a
-- match, so the fire button never goes missing in one.
function TouchControls._Contexts()
	local ok, contexts, menuOpen = pcall(function()
		if TouchControls._ContextOverride then
			return TouchControls._ContextOverride()
		end
		local player = Players.LocalPlayer
		local menu = player ~= nil and player:GetAttribute("MenuOpen") == true
		if not state.known then
			return { match = true }, menu
		end
		if state.spectating then
			return { spectate = true }, menu
		end
		if state.range then
			return { range = true, lobby = true }, menu
		end
		if state.matchState == "InProgress" and state.hasLoadout then
			return { match = true }, menu
		end
		return { lobby = true }, menu
	end)
	if not ok then
		if not warnedContext then
			warnedContext = true
			warn("[TouchControls] couldn't tell where the player is, so the match buttons show: " .. tostring(contexts))
		end
		return { match = true }, false
	end
	return contexts, menuOpen
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function ensureGui()
	if gui and gui.Parent then
		return gui
	end
	local parent = TouchControls.TestParent
	if not parent then
		local player = Players.LocalPlayer
		parent = player and player:FindFirstChildOfClass("PlayerGui")
	end
	if not parent then
		return nil
	end
	if parent:IsA("GuiBase2d") and not parent:IsA("LayerCollector") then
		gui = create("Frame", { Name = "BrrTouchControls", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = parent })
	else
		gui = create("ScreenGui", {
			Name = "BrrTouchControls",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			DisplayOrder = 2,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			Parent = parent,
		})
		-- Laid out against the whole screen, like Roblox's own jump button beside it.
		pcall(function()
			gui.ScreenInsets = Enum.ScreenInsets.None
		end)
	end
	return gui
end

-- Whether an input on a button presses it: a touch, just starting (a finger sliding onto the button
-- mid-drag arrives with another state).
function TouchControls._AcceptsInput(input)
	return input ~= nil and input.UserInputType == Enum.UserInputType.Touch and input.UserInputState == Enum.UserInputState.Begin
end

local function releaseWidget(widget)
	for input, entry in pairs(held) do
		if entry.widget == widget then
			held[input] = nil
			if entry.bind.hold then
				task.spawn(entry.bind.handler, entry.bind.name, Enum.UserInputState.End, input)
			end
		end
	end
	widget.scale.Scale = 1
end

local function press(widget, input)
	local bind = widget.bind
	if not bind or bind.disabled or held[input] then
		return
	end
	held[input] = { bind = bind, widget = widget }
	widget.scale.Scale = 0.9
	TweenService:Create(widget.plate, TweenInfo.new(0.08), { BackgroundTransparency = 0.05 }):Play()
	task.spawn(bind.handler, bind.name, Enum.UserInputState.Begin, input)
	if not bind.hold then
		held[input] = nil
		task.spawn(bind.handler, bind.name, Enum.UserInputState.End, input)
		task.delay(0.1, function()
			widget.scale.Scale = 1
			TweenService:Create(widget.plate, TweenInfo.new(0.15), { BackgroundTransparency = 0.3 }):Play()
		end)
	end
end

local function release(input)
	local entry = held[input]
	if not entry then
		return
	end
	held[input] = nil
	entry.widget.scale.Scale = 1
	TweenService:Create(entry.widget.plate, TweenInfo.new(0.15), { BackgroundTransparency = 0.3 }):Play()
	task.spawn(entry.bind.handler, entry.bind.name, Enum.UserInputState.End, input)
end

local function widgetFor(slot)
	local widget = widgets[slot]
	if widget then
		return widget
	end
	local root = ensureGui()
	if not root then
		return nil
	end
	local button = create("TextButton", {
		Name = "Touch_" .. slot,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Active = true,
		Text = "",
		Visible = false,
		ZIndex = 5,
		Parent = root,
	})
	local scale = create("UIScale", { Parent = button })
	local plate = create("Frame", {
		Name = "Plate",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = button,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local stroke = create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2, Transparency = 0.35, Parent = plate })
	-- The cooldown: a dark fill that drains from the top as the move comes back.
	local cooldown = create("Frame", {
		Name = "Cooldown",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = plate,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local label = create("TextLabel", {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "",
		TextColor3 = C.Text,
		TextScaled = true,
		ZIndex = 7,
		Parent = button,
	}, { create("UITextSizeConstraint", { MaxTextSize = 16, MinTextSize = 8 }), create("UIPadding", {
		PaddingLeft = UDim.new(0.14, 0), PaddingRight = UDim.new(0.14, 0), PaddingTop = UDim.new(0.3, 0), PaddingBottom = UDim.new(0.3, 0),
	}) })
	widget = { slot = slot, button = button, scale = scale, plate = plate, stroke = stroke, cooldown = cooldown, label = label }
	widgets[slot] = widget

	-- Only a finger that STARTS on the button presses it: a camera drag sliding across it doesn't. Only
	-- touches, and the real touch InputObject goes to the handler (owners read its UserInputType).
	button.InputBegan:Connect(function(input)
		if TouchControls._AcceptsInput(input) then
			press(widget, input)
		end
	end)
	return widget
end

-- Which bind holds each slot: the highest priority, then the earliest bound.
local function assign()
	local winners = {}
	local order = {}
	for _, bind in pairs(binds) do
		table.insert(order, bind)
	end
	table.sort(order, function(a, b)
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.serial < b.serial
	end)
	for _, bind in ipairs(order) do
		local slot = bind.slot
		if not slot or not SLOT_DEFAULTS[slot] then
			slot = nil
			for _, extra in ipairs({ "extra1", "extra2" }) do
				if not winners[extra] then
					slot = extra
					break
				end
			end
			if not slot and not bind.warnedFull then
				bind.warnedFull = true
				warn(string.format("[TouchControls] no free slot for %s; its keyboard and gamepad binds still work", bind.name))
			end
		end
		if slot and not winners[slot] then
			winners[slot] = bind
		end
	end
	return winners
end

-- Draws what should be showing now. Cheap; called on every change.
function TouchControls.Refresh()
	if not TouchControls.Enabled or not isTouchScreen() then
		for _, widget in pairs(widgets) do
			if widget.button.Visible then
				releaseWidget(widget)
				widget.button.Visible = false
			end
		end
		return
	end
	local winners = assign()
	local contexts, menuOpen = TouchControls._Contexts()
	local layout = TouchControls.Layout(viewport())
	for _, slot in ipairs(TouchControls.Slots) do
		local bind = winners[slot]
		local show = false
		if bind then
			for _, context in ipairs(bind.contexts) do
				if contexts[context] then
					show = true
				end
			end
			if menuOpen and not bind.menuSafe then
				show = false
			end
		end
		local widget = widgets[slot]
		if show then
			widget = widget or widgetFor(slot)
		end
		if widget then
			-- A held button that's about to go (unbound, hidden, disabled, out of its context, or handed to
			-- another bind) gets its End first, then goes.
			if widget.bind ~= bind or not show or (bind and bind.disabled) then
				releaseWidget(widget)
			end
			widget.bind = show and bind or nil
			widget.button.Visible = show
			if show then
				local rect = layout[slot]
				widget.button.Position = UDim2.fromOffset(rect.x, rect.y)
				widget.button.Size = UDim2.fromOffset(rect.width or rect.size, rect.size)
				widget.label.Text = bind.label or ""
				widget.stroke.Color = bind.lit and C.Accent or Color3.new(1, 1, 1)
				widget.stroke.Transparency = bind.lit and 0 or 0.35
				widget.plate.BackgroundColor3 = slot == "fire" and C.Red:Lerp(C.Background, 0.35) or C.Background
				widget.cooldown.Size = UDim2.fromScale(1, math.clamp(bind.cooldown or 0, 0, 1))
				widget.label.TextTransparency = bind.disabled and 0.6 or 0
			end
		end
	end
	changedEvent:Fire()
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

local serial = 0

local function bindNow(name, spec)
	spec = spec or {}
	serial += 1
	local slot = spec.slot or TouchControls.DefaultSlots[name]
	local defaults = SLOT_DEFAULTS[slot] or SLOT_DEFAULTS.extra1
	local bind = {
		name = name,
		slot = slot,
		label = spec.label,
		handler = spec.handler or function() end,
		hold = spec.hold,
		contexts = spec.contexts or defaults.contexts,
		priority = spec.priority or 0,
		menuSafe = spec.menuSafe == true,
		onDrag = spec.onDrag,
		serial = serial,
	}
	if bind.hold == nil then
		bind.hold = defaults.hold
	end
	local old = binds[name]
	if old then
		-- Rebinding (a key change) keeps its place in line.
		bind.serial = old.serial
		bind.lit, bind.cooldown, bind.disabled = old.lit, old.cooldown, old.disabled
	end
	binds[name] = bind
	TouchControls.Refresh()
end

function TouchControls.Unbind(name)
	if binds[name] then
		binds[name] = nil
		TouchControls.Refresh()
	end
end

function TouchControls.SetState(name, changes)
	local bind = binds[name]
	if not bind or type(changes) ~= "table" then
		return
	end
	for _, key in ipairs({ "lit", "cooldown", "disabled", "label" }) do
		if changes[key] ~= nil then
			bind[key] = changes[key]
		end
	end
	TouchControls.Refresh()
end

function TouchControls.SlotRect(slot)
	local widget = widgets[slot]
	if not widget or not widget.button.Visible then
		return nil
	end
	return TouchControls.Layout(viewport())[slot]
end

-- For probes: what a slot is showing (the bind's name, or nil).
function TouchControls._Showing(slot)
	local widget = widgets[slot]
	return widget and widget.button.Visible and widget.bind and widget.bind.name or nil
end

-- For probes: press and lift a slot's button with a stand-in InputObject, through the same code a finger
-- goes through.
function TouchControls._Press(slot, input)
	local widget = widgets[slot]
	if widget and widget.button.Visible then
		press(widget, input)
	end
end
TouchControls._Release = release

-- For probes: forget everything (binds, widgets, the gui).
function TouchControls._Reset()
	for input in pairs(held) do
		held[input] = nil
	end
	binds = {}
	widgets = {}
	if gui then
		gui:Destroy()
		gui = nil
	end
	warnedContext = false
	TouchControls._ContextOverride = nil
end

--------------------------------------------------------------------------------
-- Wiring (only once there's something to do: nothing runs while the flag is off)
--------------------------------------------------------------------------------

local wired = false

function TouchControls.Wire()
	if wired or not TouchControls.Enabled then
		return
	end
	wired = true
	UserInputService.InputEnded:Connect(function(input)
		release(input)
	end)
	UserInputService.InputChanged:Connect(function(input)
		local entry = held[input]
		if entry and entry.bind.onDrag and input.UserInputType == Enum.UserInputType.Touch then
			entry.bind.onDrag(Vector2.new(input.Delta.X, input.Delta.Y))
		end
	end)
	pcall(function()
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(TouchControls.Refresh)
	end)
	pcall(function()
		GuiService:GetPropertyChangedSignal("TouchControlsEnabled"):Connect(TouchControls.Refresh)
	end)
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(TouchControls.Refresh)
	end
	local player = Players.LocalPlayer
	if player then
		player:GetAttributeChangedSignal("MenuOpen"):Connect(TouchControls.Refresh)
	end
	-- Where the player is, from the same remotes the HUD reads. Looked up in the background: a missing
	-- remote leaves `known` false, which shows the match buttons.
	task.spawn(function()
		local ok, err = pcall(function()
			local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
			Remotes.Event("MatchChanged").OnClientEvent:Connect(function(match)
				state.known = true
				state.matchState = type(match) == "table" and match.state or nil
				TouchControls.Refresh()
			end)
			Remotes.Event("LoadoutChanged").OnClientEvent:Connect(function(loadout)
				state.hasLoadout = loadout ~= nil
				TouchControls.Refresh()
			end)
			Remotes.Event("RangeState").OnClientEvent:Connect(function(on)
				state.range = on == true
				TouchControls.Refresh()
			end)
			Remotes.Event("Spectate").OnClientEvent:Connect(function(on)
				state.spectating = on == true
				TouchControls.Refresh()
			end)
		end)
		if not ok then
			warn("[TouchControls] couldn't listen for the match state; the match buttons stay up: " .. tostring(err))
		end
	end)
end

-- Wires itself on first use, so an owner never has to call Wire. Does nothing at all with the flag off.
function TouchControls.Bind(name, spec)
	if not TouchControls.Enabled then
		return
	end
	TouchControls.Wire()
	bindNow(name, spec)
end

return TouchControls
