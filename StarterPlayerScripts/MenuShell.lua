-- The menu's frame: the panel, its header, its navigation and the area a tab draws into.
--
-- The old panel was a fixed 760x480 in the middle of the screen whatever the screen was: 40% of a
-- 1920x1080 monitor, and 123% of the HEIGHT of an 844x390 phone, where its tabs and buttons fell
-- off the bottom. MenuClient never read ViewportSize at all. This sizes itself from the viewport
-- every time it changes, and lays its navigation out to match:
--
--   desktop / tablet   a rail down the left, each destination with a subtitle
--   phone              a bar across the bottom, inside the thumb's reach
--
-- The shell owns no content. A host (MenuClient) gives it destinations and draws into `Content`,
-- so the tabs keep their own renderers and their own owners.
--
-- A ModuleScript, so tools/menu_hud_gallery.lua can render it without a running client.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))

local create, rounded, padding = UiKit.create, UiKit.rounded, UiKit.padding
local Role, Type, Space, Radius, Stroke = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius, UiKit.Stroke

local MenuShell = {}
MenuShell.__index = MenuShell

local RAIL_WIDE, RAIL_NARROW, RAIL_ICON = 208, 168, 64

-- How the phone's bottom bar is laid out: how many cells fit across the panel at a full 44 px touch
-- target, how many rows that needs, and the room they have. Both the height (measured in
-- SetViewport) and the cells (built in SetDestinations) come from here, so they cannot disagree.
-- `count` may be 0 — the shell is built before it has destinations.
local function barLayout(panelWidth, count)
	local room = panelWidth - Space.MD * 2
	local perRow = math.max(1, math.floor((room + Space.SM) / (UiKit.Touch + Space.SM)))
	count = math.max(count, 1)
	perRow = math.min(perRow, count)
	return perRow, math.ceil(count / perRow), room
end

-- options: parent (a ScreenGui or Frame), title, viewport, onClose, onSettings, onBack
function MenuShell.new(options)
	local self = setmetatable({}, MenuShell)
	self.destinations = {}
	self.active = nil
	self.onSelect = nil
	self.onBack = options.onBack

	self.layer = create("Frame", {
		Name = "MenuShell",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = options.parent,
	})
	-- A dim behind the panel: mid-match the menu used to sit on a live HUD with nothing between.
	self.scrimFrame = create("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Role.Scrim,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = self.layer,
	})
	self.scrimFrame.Activated:Connect(function()
		if self.onBack then
			self.onBack()
		end
	end)

	self.panel = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 480),
		BackgroundColor3 = Role.Base,
		BorderSizePixel = 0,
		Parent = self.layer,
	}, { rounded(Radius.Panel) })
	create("UIStroke", { Color = Role.Line, Thickness = Stroke.Hairline, Parent = self.panel })
	self.scale = create("UIScale", { Parent = self.panel })

	self.onClose = options.onClose
	self.onSettings = options.onSettings

	-- Oliver's #66, "the x button on the menu is broken". It was not a hit-test and not a z-order:
	-- the button had NO Activated connection at all.
	--
	-- These two used to be built as `onClick = options.onClose` / `options.onSettings`. MenuClient
	-- constructs the shell at its line 138, long before `toggleMenu` exists, so it passes neither --
	-- and UiParts.button (UiParts.lua:146) only reaches `Activated:Connect` when `onClick` is
	-- non-nil. So the X was built dead, while UiParts.interactive still gave it hover and press
	-- states: it looked alive, which is why it reads as "broken" rather than as "missing".
	--
	-- The scrim above never had this bug, and the difference is the whole lesson: it
	-- reads `self.onBack` at CLICK time, and MenuClient assigns that field later. So these read
	-- their handler at click time too -- and, more to the point, the closures themselves are never
	-- nil, so the X can no longer be CONSTRUCTED without a connection whatever a host forgets to
	-- pass. The failure mode is removed rather than patched at one call site.
	local actions = {
		{
			glyph = "⚙",
			onClick = function()
				self:Settings()
			end,
		},
		-- The letter, not a multiplication sign: U+2715 isn't in the font Roblox ships and drew a
		-- tofu box in the render. MenuClient's own close button has always used "X".
		{
			glyph = "X",
			onClick = function()
				self:Dismiss()
			end,
		},
	}
	local header, walletSlot = UiParts.header({
		parent = self.panel,
		title = options.title or "BRAINROT BATTLES",
		actions = actions,
	})
	self.header = header
	self.WalletSlot = walletSlot

	-- The header's only TextButtons are its actions: its title and labels are TextLabels and its
	-- wallet slot is a Frame. Held by name so a probe, a gallery or a later tab can reach the REAL
	-- X rather than one it built itself, which would say nothing about what the shell builds.
	self.HeaderActions = {}
	do
		local buttons = {}
		for _, child in ipairs(header:GetDescendants()) do
			if child:IsA("TextButton") then
				table.insert(buttons, child)
			end
		end
		table.sort(buttons, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		self.HeaderActions.settings, self.HeaderActions.close = buttons[1], buttons[2]
	end

	-- What was actually put in each action's `onClick` slot. UiParts.button connects Activated if
	-- and only if that value is non-nil, so this table IS the wiring -- a nil here is precisely the
	-- shipped bug. Exposed because Studio's plugin sandbox refuses synthetic input
	-- ("lacking capability RobloxScript"), so a probe cannot click the button and this is the next
	-- thing down that is still a measurement of the real construction rather than an assumption.
	self.HeaderHandlers = { settings = actions[1].onClick, close = actions[2].onClick }

	-- Oliver's #65, "the tabs in the menu aren't fitting inside the menu hud". This was a plain
	-- Frame, so a destination stack taller than the nav simply drew on past the bottom of the
	-- PANEL: nothing clipped it, nothing scrolled it, nothing shrank it. A ScrollingFrame cannot
	-- draw outside itself, so containment is structural now rather than something the arithmetic
	-- has to keep getting right as the destination list changes.
	self.nav = create("ScrollingFrame", {
		Name = "Nav",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- Explicit, and not because a ScrollingFrame is believed to clip anyway. The WHOLE of the
		-- #65 containment claim rests on this one property, and the probe reads it back off the
		-- instance rather than assuming it -- so if this line is ever removed the probe goes red
		-- instead of quietly reporting that nothing is drawn outside the panel.
		ClipsDescendants = true,
		-- 0, not hidden: on every screen the game is designed for the stack fits, so a visible bar
		-- would appear only on a shape nobody has, and it would eat width the rail needs.
		ScrollBarThickness = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = self.panel,
	})
	self.navLayout = create("UIListLayout", {
		Padding = UDim.new(0, Space.SM),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = self.nav,
	})

	-- What a tab draws into. Scrolls on its own so a tab never has to think about height.
	self.Content = create("ScrollingFrame", {
		Name = "Content",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Role.Line,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = self.panel,
	})

	self:SetViewport(options.viewport or Vector2.new(1280, 720))
	return self
end

-- Lays the panel, the navigation and the content out for a screen. Called on open and whenever the
-- viewport changes, so a window resize or a phone rotation is handled by the same path.
function MenuShell:SetViewport(viewport, touch)
	self.viewport = viewport
	self.touch = touch == nil and self.touch or touch
	-- Three versions, chosen by which dimension has run out. `phone` is kept as the name for the
	-- bottom-bar case so existing reads keep working, but it now means "tall" specifically:
	-- a LANDSCAPE phone is "short" and gets an icon rail, not a bar.
	local mode = UiKit.form(viewport)
	local size = UiKit.panelSize(viewport, self.touch)
	local safe = UiKit.safeArea(viewport, self.touch)
	local phone = mode == "tall"
	self.Form = mode
	self.phone = phone
	self.short = mode == "short"

	self.panel.Size = UDim2.fromOffset(size.X, size.Y)
	self.panelWidth = size.X
	-- The panel is already sized to the screen, so this is a belt-and-braces shrink: PhoneLayout's
	-- own maths, the same call the rest of the phone work uses, so a screen it considers too small
	-- still can't lose the bottom of the menu. PanelScale rather than FitPanel because the shell
	-- already redraws on a viewport change, and FitPanel would add a second connection each time.
	--
	-- This looks redundant, and on every screen the menu is drawn for it IS a no-op, because the
	-- panel sizes itself (measured, panel size -> fit): 1920x1080 1180x760 -> 1.000, 1366x768
	-- 1174x660 -> 1.000, 1280x720 1100x619 -> 1.000, 1024x768 880x612 -> 1.000, 844x390 804x260 ->
	-- 1.000, 640x360 600x260 -> 1.000. It first bites at 600x320 (560x260 -> 0.969), where the
	-- panel's 260-tall minimum beats the room. Don't delete it for looking idle: it is the only
	-- thing holding the sizes below this list.
	local fitter = self.phoneLayout
	if fitter == nil then
		local module = script.Parent:FindFirstChild("PhoneLayout")
		fitter = module and require(module) or false
		self.phoneLayout = fitter
	end
	-- Held, because the open and close animations drive this same UIScale and have to return to the
	-- fitted size rather than to 1.
	self.fitScale = fitter and fitter.PanelScale(size, viewport, { inset = true }) or 1
	self.scale.Scale = self.fitScale
	-- Nudged down by half the difference between the insets, so the panel sits in the space the
	-- player can actually see rather than under the top bar.
	self.panel.Position = UDim2.new(0.5, 0, 0.5, math.floor((safe.Top - safe.Bottom) / 2))

	-- The small version's header is 44, not 64: it is the single cheapest 20 px on a screen with
	-- 260 px of panel, and the title still reads at Heading size.
	-- 44 rather than 40 since #20: the header's buttons are full 44 px touch targets, and at 40 they
	-- hung 2 px over the header's top and bottom (tools/menu_screens_check.py).
	local headerHeight = (mode == "short" and UiKit.Touch) or (phone and 52) or 64
	self.header.Size = UDim2.new(1, 0, 0, headerHeight)
	local headerTitle = self.header:FindFirstChildOfClass("TextLabel")
	if headerTitle then
		headerTitle.TextSize = (phone and Type.Heading or Type.Title).Size
		headerTitle.Font = (phone and Type.Heading or Type.Title).Font
		-- UiParts.header works its title width out from the panel width, but the header is built
		-- before the shell has been given one, so the reserve is redone here on every viewport
		-- change. Without this the title kept the width it was born with and the portrait render
		-- came back with no title at all.
		local actionsWidth = 2 * (UiKit.Touch + Space.SM)
		local slotWidth = 168
		local room = size.X - Space.LG * 2 - actionsWidth - Space.SM
		local showSlot = room - slotWidth >= 150
		self.WalletSlot.Visible = showSlot
		headerTitle.Size = UDim2.new(1, -(actionsWidth + Space.SM + (showSlot and slotWidth + Space.SM or 0)), 1, 0)
	end

	-- #78: a screen with one tab (ROBUX, SETTINGS) is a whole page, not a page beside a one-item rail
	-- that goes nowhere. No navigation at all, and the content has the panel's full width.
	local solo = #self.destinations <= 1
	self.Solo = solo
	self.nav.Visible = not solo
	local railWidth = ((phone or solo) and 0)
		or (mode == "short" and RAIL_ICON)
		or (viewport.X < 1280 and RAIL_NARROW or RAIL_WIDE)

	-- How many bar cells fit across at a full touch target, and therefore how many rows the bar
	-- needs. A narrow screen is the case that forces this: eight destinations across a 320-wide
	-- portrait panel works out at 30 px a cell, and a 30 px target is not a target. The bar wraps
	-- instead, and stays as tall as it has to be.
	local perRow, rows = #self.destinations, 1
	if phone then
		perRow, rows = barLayout(size.X, #self.destinations)
	end
	local barHeight = (phone and not solo) and (rows * UiKit.Touch + (rows - 1) * Space.SM + Space.MD * 2) or 0
	self.railWidth, self.barHeight = railWidth, barHeight
	self.navPerRow, self.navRows = perRow, rows

	if phone then
		self.nav.AnchorPoint = Vector2.new(0.5, 1)
		self.nav.Position = UDim2.new(0.5, 0, 1, 0)
		self.nav.Size = UDim2.new(1, 0, 0, barHeight)
		self.nav.BackgroundColor3 = Role.Surface
		self.nav.BackgroundTransparency = 0
		-- The bar is a column of rows, each row a line of cells, so one row and four behave the same.
		self.navLayout.FillDirection = Enum.FillDirection.Vertical
		self.navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		self.navLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		-- The bar sizes ITSELF to its rows (barHeight above comes from the same wrap), so it never
		-- has more content than window and must not scroll. Left automatic, a centred list inside a
		-- growing canvas fights itself; this keeps the bar exactly what it was.
		self.nav.AutomaticCanvasSize = Enum.AutomaticSize.None
		self.nav.CanvasSize = UDim2.new()
		self.nav.ScrollingEnabled = false
	else
		self.nav.AnchorPoint = Vector2.zero
		self.nav.Position = UDim2.fromOffset(Space.LG, headerHeight)
		self.nav.Size = UDim2.new(0, railWidth - Space.LG, 1, -headerHeight - Space.LG)
		self.nav.BackgroundTransparency = 1
		self.navLayout.FillDirection = Enum.FillDirection.Vertical
		self.navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		self.navLayout.VerticalAlignment = Enum.VerticalAlignment.Top
		-- The rail is the case that overflowed (#65). It scrolls only when the stack is taller than
		-- the room; on the screens the game is designed for it is not, so nothing visible changes
		-- and no destination can be drawn outside the panel at any count.
		self.nav.AutomaticCanvasSize = Enum.AutomaticSize.Y
		self.nav.ScrollingEnabled = true
	end

	-- Without a rail the content still wants a gutter on its left, or it runs into the panel's edge.
	local left = (phone and Space.MD) or (solo and Space.LG) or 0
	self.Content.Position = UDim2.fromOffset(railWidth + left, headerHeight)
	self.Content.Size = UDim2.new(1, -railWidth - left - (phone and Space.MD or Space.LG), 1, -headerHeight - barHeight - Space.MD)
	self.ContentWidth = size.X - railWidth - left - (phone and Space.MD or Space.LG)

	if #self.destinations > 0 then
		self:SetDestinations(self.destinations, self.active)
	end
end

-- destinations: { { key, label, glyph, sub } }. Rebuilt on a viewport change because a rail item
-- and a bar cell are different shapes, not the same shape resized.
function MenuShell:SetDestinations(destinations, active)
	self.destinations = destinations
	self.active = active or self.active or (destinations[1] and destinations[1].key)

	-- A changed count changes how many rows the bar wraps to, and therefore how tall the bar is and
	-- how much height is left for content -- so the panel has to be re-laid BEFORE the cells are
	-- built, not after. SetViewport's own tail calls straight back in here to do the building, and
	-- `laying` stops that becoming a loop: the re-entrant call skips this block and goes to the
	-- build, and this one returns having already had its cells made.
	if self.viewport and not self.laying then
		self.laying = true
		local ok, err = pcall(function()
			self:SetViewport(self.viewport, self.touch)
		end)
		self.laying = false
		if not ok then
			error(err, 0)
		end
		return
	end
	-- Was the pad on one of the cells about to go? Then it goes to the new active cell, below.
	local padFocused = false
	pcall(function()
		local selected = GuiService.SelectedObject
		padFocused = selected ~= nil and selected:IsDescendantOf(self.nav)
	end)
	self.navCells = {}
	for _, child in ipairs(self.nav:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	-- Measured against the PANEL, not the screen. The panel is inset from the screen edges, so
	-- sizing eight cells from the viewport overflowed it: at 844 wide the bar came to 816 px inside
	-- a 780 px panel, and the last destination ran off the end.
	local perRow, _, barRoom = barLayout(self.panelWidth or self.viewport.X, #destinations)
	local width = nil
	local row = nil
	if self.phone then
		width = math.floor((barRoom - Space.SM * (perRow - 1)) / perRow)
	end
	for index, destination in ipairs(destinations) do
		if self.phone and (index - 1) % perRow == 0 then
			-- One frame per line of cells. The rows are what the bar's height was measured from.
			row = create("Frame", {
				Size = UDim2.new(1, 0, 0, UiKit.Touch),
				BackgroundTransparency = 1,
				LayoutOrder = math.floor((index - 1) / perRow) + 1,
				Parent = self.nav,
			}, {
				create("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Space.SM),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			})
		end
		self.navCells[destination.key] = UiParts.navItem({
			parent = self.phone and row or self.nav,
			rail = not self.phone,
			-- The short version's rail is 64 wide: glyph only. Without this the cells drew their
			-- label and subtitle at full rail width and lay across the cards beside them.
			compact = self.short,
			-- A bar cell under 72 px cannot hold "COSMETICS" at any size worth reading, so it shows
			-- the glyph alone rather than a clipped word. Eight destinations at 320 wide is 52 px.
			glyphOnly = self.phone and width and width < 72 or nil,
			width = width,
			glyph = destination.glyph,
			label = destination.label,
			sub = destination.sub,
			selected = destination.key == self.active,
			layoutOrder = index,
			onClick = function()
				self:Select(destination.key)
			end,
		})
	end
	if padFocused then
		self:FocusPad()
	end
end

-- A gamepad has no pointer, so the menu hands it a starting point: the active destination's cell.
-- Asked on Open and after every rebuild of the nav, because choosing a destination rebuilds every
-- cell, and the cell the pad was on is destroyed under it -- which left a pad player with nothing
-- selected after each tab change. Does nothing unless the pad was the last thing used.
function MenuShell:FocusPad()
	-- pcall: a gallery renders this shell from a plugin, where the input services may refuse.
	pcall(function()
		if not string.find(UserInputService:GetLastInputType().Name, "Gamepad", 1, true) then
			return
		end
		local first = self.destinations and self.destinations[1]
		local cell = self.navCells and (self.navCells[self.active] or (first and self.navCells[first.key]))
		if cell and cell.Parent then
			GuiService.SelectedObject = cell
		end
	end)
end

-- The header's title: each HUD button's screen names itself (#78), so SHOP reads SHOP rather than the
-- game's name over every page.
function MenuShell:SetTitle(text)
	local title = self.header:FindFirstChildOfClass("TextLabel")
	if title then
		title.Text = text
	end
	self.Title = text
end

function MenuShell:Select(key)
	if self.active == key then
		return
	end
	self.active = key
	self:SetDestinations(self.destinations, key)
	if self.onSelect then
		self.onSelect(key)
	end
end

-- What the X does, read at CLICK time so a host can assign the field after construction the way
-- MenuClient already does with `onBack`.
--
-- The last branch is deliberate: a close button that does nothing is the bug this replaced, so a
-- shell nobody has given a handler still CLOSES rather than sitting there looking pressable. There
-- is no arrangement of options that produces a dead X.
function MenuShell:Dismiss()
	local handler = self.onClose or self.onBack
	if handler then
		handler()
	else
		self:Close()
	end
end

-- What the gear does. Dead in the built place for exactly the same reason the X was, and fixed the
-- same way even though the revamp moves Settings into the destination list and drops the gear: if
-- anything re-adds it, it has to work by construction rather than by someone remembering to pass a
-- handler. With no handler it selects a "Settings" destination if the host has one.
function MenuShell:Settings()
	if self.onSettings then
		self.onSettings()
		return
	end
	for _, destination in ipairs(self.destinations) do
		if destination.key == "Settings" then
			self:Select(destination.key)
			return
		end
	end
end

-- Closing counts as closed: during the close tween the layer is still visible, and a press then
-- (M, a HUD button) must reopen the menu rather than be swallowed or close it again.
function MenuShell:IsOpen()
	return self.layer.Visible and not self.closing
end

function MenuShell:Open()
	if self.layer.Visible and not self.closing then
		return
	end
	-- Reopened mid-close: the close tween's callback sees `closing` cleared and leaves the layer up.
	self.closing = false
	self.layer.Visible = true
	self.scrimFrame.BackgroundTransparency = 1
	TweenService:Create(self.scrimFrame, TweenInfo.new(UiKit.Motion.Fade), { BackgroundTransparency = 0.45 }):Play()
	UiParts.openPanel(self.panel, self.scale, self.fitScale)
	self:FocusPad()
end

function MenuShell:Close()
	if not self.layer.Visible or self.closing then
		return
	end
	self.closing = true
	-- Hand the pad back to the game: a selection left on a hidden cell keeps eating A (jump) and the d-pad.
	pcall(function()
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(self.layer) then
			GuiService.SelectedObject = nil
		end
	end)
	TweenService:Create(self.scrimFrame, TweenInfo.new(UiKit.Motion.Press), { BackgroundTransparency = 1 }):Play()
	UiParts.closePanel(self.panel, self.scale, function()
		if not self.closing then
			-- Reopened before the tween ended: closePanel has just hidden the panel, so show it again.
			self.panel.Visible = true
			return
		end
		self.closing = false
		self.layer.Visible = false
		self.panel.Visible = true
	end, self.fitScale)
end

function MenuShell:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

-- WHO ASKS "what screen is this?", and why it lives here rather than in the host.
--
-- This wiring used to be MenuClient's, and MenuClient never did it (#65) -- the shell kept the
-- 1280x720 its constructor falls back to, on every screen, so the `short` and `tall` versions never
-- ran in the game at all. The reason that hid for months is worth writing down: MenuClient is a
-- LocalScript, and a LocalScript never runs in the runtest harness, so the missing wiring was also
-- wiring that nothing could test. `SetViewport` itself always worked and was easy to test; its
-- CALLER was neither. Moving the call in here makes it reachable by a probe, so the gap cannot
-- reopen silently.
--
-- Re-laid on three signals, not one: the viewport (a resize or a rotation), the camera being
-- REPLACED (workspace.CurrentCamera is swapped out, and a listener left on the old one feeds
-- nothing), and TouchEnabled, which decides the safe area that keeps the panel clear of Roblox's
-- own controls.
function MenuShell:BindViewport(camera)
	self:UnbindViewport()
	self.viewportBinding = {}
	local function relayout()
		local live = camera or workspace.CurrentCamera
		if live then
			self:SetViewport(live.ViewportSize, UserInputService.TouchEnabled)
		end
	end
	local function watch()
		local live = camera or workspace.CurrentCamera
		if not live then
			return
		end
		if self.viewportWatch then
			self.viewportWatch:Disconnect()
		end
		self.viewportWatch = live:GetPropertyChangedSignal("ViewportSize"):Connect(relayout)
		relayout()
	end
	watch()
	if not camera then
		table.insert(self.viewportBinding, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watch))
	end
	table.insert(self.viewportBinding, UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(relayout))
	return self
end

function MenuShell:UnbindViewport()
	if self.viewportWatch then
		self.viewportWatch:Disconnect()
		self.viewportWatch = nil
	end
	for _, connection in ipairs(self.viewportBinding or {}) do
		connection:Disconnect()
	end
	self.viewportBinding = nil
end

-- Back, on a pad and on a keyboard.
--
-- Not Escape: Roblox keeps that for its own menu and a game can't take it, so a player who presses
-- it gets the Roblox menu, not ours. Backspace is the keyboard stand-in, the gamepad's B button is
-- what a pad player already expects, and the scrim and the X are there for a mouse or a thumb.
-- `handler` is called for each press; it should close the top-most layer and return true if it
-- handled it, so a dialog closes before the menu does.
function MenuShell:BindBack(name, handler)
	self.backName = name or "BrrMenuShellBack"
	ContextActionService:BindAction(self.backName, function(_, state)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if not self:IsOpen() then
			return Enum.ContextActionResult.Pass
		end
		if handler and handler() then
			return Enum.ContextActionResult.Sink
		end
		self:Close()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
end

function MenuShell:UnbindBack()
	if self.backName then
		ContextActionService:UnbindAction(self.backName)
		self.backName = nil
	end
end

-- Clears the content area, keeping its layout, ready for a tab to draw.
function MenuShell:ClearContent()
	UiKit.clearItems(self.Content)
end

return MenuShell
