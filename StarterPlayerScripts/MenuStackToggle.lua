-- Tucks the left-hand stack (MENU, the bundle nudge, the quest tracker) away behind a small tab, and
-- brings it back. A ModuleScript so MenuClient can mount it and tools/hud_ux_gallery.lua can render it.
--
--   local toggle = MenuStackToggle.new(screenGui, { items = { menuButton, bundleNudge, tracker }, settings = Settings })
--   toggle:SetSummary("2/3")          -- what the collapsed tab shows beside its icon (quests done)
--   toggle:Attention()                -- something new while it's tucked away: the tab lights up and pulses
--   toggle:SetCollapsed(true)         -- by hand (the tab and the setting both come through here)
--
-- The items move into one container that slides and fades; each keeps its own Visible, so whatever
-- MenuClient shows or hides carries on exactly as before. Collapsed, the tab sits where MENU was,
-- showing a menu icon and today's quest count, and it lights up and pulses when a quest or challenge
-- completes, the daily spin comes round, a pass reward is ready or a gift lands; expanding clears
-- that. Nothing is ever out of reach: M and J still open the menu and quests, and the tab is a tap
-- away. The choice is the "MenuStackCollapsed" setting, so it's saved to the profile (and RESET under
-- Gameplay brings the stack back).
--
-- On a touch screen the whole thing moves: MenuClient calls `SetPhone(PhoneLayout.Rects(viewport), inset)`
-- and the tab goes to the top-right corner beside the MENU icon, with the stack hanging underneath it at
-- 0.8 and starting at whatever is actually showing (MENU is its own icon there, not part of the stack).
-- `SetPhone(nil)` puts it all back on the left edge.

local TweenService = game:GetService("TweenService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local MenuStackToggle = {}
MenuStackToggle.__index = MenuStackToggle

MenuStackToggle.SettingId = "MenuStackCollapsed"

-- The stack's pixel layout in MenuClient's ScreenGui: the SHOP button (top of the five) at (16, 130),
-- 104x26 (Oliver 14:41: the minimize tab floated away from the buttons when they shrank).
local STACK_TOP = 124
local STACK_SIZE = Vector2.new(300, 460)
local MENU_X, MENU_Y, MENU_W, MENU_H = 16, 130, 104, 26
local SLIDE = 56

-- 40 wide rather than a sliver: it's a finger's target on a phone.
local EXPANDED_TAB = { x = MENU_X + MENU_W + 3, w = 30 }
local COLLAPSED_TAB = { x = MENU_X, w = 78 }

local DARK = Color3.fromRGB(20, 16, 6)
local ALERT = Color3.fromRGB(255, 84, 84)

local function tween(instance, seconds, goal, style, direction)
	local t = TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

local function bar(parent, x, y, w, h, rotation, color)
	return create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Rotation = rotation or 0,
		Parent = parent,
	}, { rounded(math.ceil(h / 2)) })
end

function MenuStackToggle.new(screenGui, options)
	options = options or {}
	local self = setmetatable({}, MenuStackToggle)
	self.settings = options.settings
	self.collapsed = false
	self.pending = false
	self.token = 0

	-- Everything in the stack moves into one group, at the same place on screen.
	local stack = create("CanvasGroup", {
		Name = "LeftStack",
		Position = UDim2.fromOffset(0, STACK_TOP),
		Size = UDim2.fromOffset(STACK_SIZE.X, STACK_SIZE.Y),
		BackgroundTransparency = 1,
		GroupTransparency = 0,
		Parent = screenGui,
	})
	self.stack = stack
	for _, item in ipairs(options.items or {}) do
		local p = item.Position
		item.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset - STACK_TOP)
		item.Parent = stack
	end

	local tab = create("TextButton", {
		Name = "StackToggle",
		Position = UDim2.fromOffset(EXPANDED_TAB.x, MENU_Y),
		Size = UDim2.fromOffset(EXPANDED_TAB.w, MENU_H),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Parent = screenGui,
	}, { rounded(10) })
	self.tab = tab
	-- ONE UIScale on the tab. Its resting value is self.fit (the stack's own scale, so the tab is the
	-- buttons' size); the open/close and attention bounces go relative to that and settle back on it.
	self.fit = 1
	self.tabScale = create("UIScale", { Parent = tab })
	self.tabStroke = create("UIStroke", {
		Color = C.Panel,
		Thickness = 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = tab,
	})

	-- Expanded: a chevron pointing left, "tuck it away".
	local tuck = create("Frame", { Name = "Tuck", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = tab })
	self.tuckBars = {
		-- Sized for the 30x26 tab beside the 26 px buttons (was drawn for 40x42 and hung out of it).
		bar(tuck, 14, 10, 9, 3, -45, C.Muted),
		bar(tuck, 14, 16, 9, 3, 45, C.Muted),
	}
	self.tuck = tuck

	-- Collapsed: a menu icon, today's quests, a chevron pointing right.
	local open = create("Frame", { Name = "Open", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = tab })
	self.openBars = {
		bar(open, 19, 7, 18, 3, 0, DARK),
		bar(open, 19, 13, 18, 3, 0, DARK),
		bar(open, 19, 19, 18, 3, 0, DARK),
	}
	self.summary = create("TextLabel", {
		Name = "Summary",
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(1, -44, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "",
		TextColor3 = DARK,
		TextSize = 15,
		Parent = open,
	})
	self.openChevron = {
		bar(open, 69, 17, 9, 3, 45, DARK),
		bar(open, 69, 24, 9, 3, -45, DARK),
	}
	self.open = open

	-- The "something new" dot, on the collapsed tab's corner.
	local dot = create("Frame", {
		Name = "Attention",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -3, 0, 3),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = ALERT,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
		Parent = tab,
	}, { rounded(7) })
	create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2, Parent = dot })
	self.dot = dot
	self.ring = create("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = dot,
	}, { rounded(99) })
	self.ringStroke = create("UIStroke", { Color = ALERT, Thickness = 2, Transparency = 1, Parent = self.ring })

	tab.Activated:Connect(function()
		self:SetCollapsed(not self.collapsed, false, true)
	end)
	tab.MouseEnter:Connect(function()
		self.hovered = true
		self:_paintHover()
	end)
	tab.MouseLeave:Connect(function()
		self.hovered = false
		self:_paintHover()
	end)

	self.stackScale = create("UIScale", { Parent = stack })
	-- Oliver 15:24: the column ran into the health / shield / stamina block on a short window, and "make
	-- the hud scale with resolution". On desktop the whole stack (buttons, bundle, quest tracker) shrinks
	-- to whatever height is left above that block, and re-fits when the window or the tracker changes.
	local function refit()
		self:_fitHeight()
	end
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	for _, item in ipairs(options.items or {}) do
		item:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
		item:GetPropertyChangedSignal("Visible"):Connect(refit)
	end
	task.defer(refit)

	if self.settings then
		self.settings.Changed:Connect(function(id)
			if id == "*" or id == MenuStackToggle.SettingId then
				self:SetCollapsed(self.settings.Get(MenuStackToggle.SettingId) == true, false, false)
			end
		end)
		self:SetCollapsed(self.settings.Get(MenuStackToggle.SettingId) == true, true, false)
	end
	return self
end

-- Height the bottom-left health / shield / stamina block takes (HudClient anchors it up to 1, -202, plus
-- its label), kept clear of the stack.
local BOTTOM_RESERVED = 150

function MenuStackToggle:_fitHeight()
	if self.phoneStack then
		return
	end
	local gui = self.stack.Parent
	if not gui then
		return
	end
	local current = math.max(self.stackScale.Scale, 0.01)
	local bottom = 0
	for _, item in ipairs(self.stack:GetChildren()) do
		if item:IsA("GuiObject") and item.Visible then
			bottom = math.max(bottom, item.Position.Y.Offset + item.AbsoluteSize.Y / current)
		end
	end
	if bottom <= 0 then
		return
	end
	-- On a screen too narrow for the stamina bar to sit bottom-centre it moves up above the bottom-left
	-- stack (StaminaBar.Layout), so the column has to stop above IT, not just above the health block --
	-- it used to run into the bar (Oliver 17:10, STARTER BUNDLE under STAMINA).
	local reserved = BOTTOM_RESERVED
	local okStamina, StaminaBar = pcall(require, script.Parent:FindFirstChild("StaminaBar"))
	if okStamina and StaminaBar and StaminaBar.Layout then
		local anchor, position, scale = StaminaBar.Layout(gui.AbsoluteSize)
		if anchor.X == 0 then
			reserved = math.max(reserved, -position.Y.Offset + 50 * scale + 10)
		end
	end
	local room = gui.AbsoluteSize.Y - reserved - STACK_TOP
	-- Never below 0.85 (Oliver 15:37: at 0.55 it was too small to read), and grows up to 1.25x where
	-- there is room (Oliver 16:16: "the quest menu and buttons are still a bit too small").
	local scale = math.clamp(room / bottom, 0.85, 1.25)
	self.stackScale.Scale = scale
	-- The collapse tab sits outside the stack, so it scales and moves with it (Oliver 16:22: "the
	-- minimize button is floating"). It used to bounce back to a scale of 1 after every open/close
	-- while its position still assumed the stack's 1.25, so it hung off the buttons' corner.
	if math.abs(self.fit - scale) > 0.001 then
		self.fit = scale
		self:_placeTab()
	end
end

-- The tab straight to where it belongs at the current fit: position, size and scale, no animation.
function MenuStackToggle:_placeTab()
	local position, size = self:_tabGoal(self.collapsed and COLLAPSED_TAB or EXPANDED_TAB)
	self.tab.Position, self.tab.Size = position, size
	self.tabScale.Scale = self.fit
end

function MenuStackToggle:_paintHover()
	if self.collapsed then
		self.tabStroke.Color = self.hovered and Color3.new(1, 1, 1) or C.Accent
	else
		self.tabStroke.Color = self.hovered and C.Muted or C.Panel
		for _, b in ipairs(self.tuckBars) do
			b.BackgroundColor3 = self.hovered and C.Text or C.Muted
		end
	end
end

-- Where the tab sits and how big it is, and where the stack hangs from it. On a desktop screen that is
-- the left edge beside MENU; on a touch screen it is the top-right corner, where PhoneLayout puts it
-- (the MENU icon is to its right and the camera button to its left), with the stack hanging underneath.
function MenuStackToggle:_tabGoal(target)
	if self.phoneTab then
		local w = target == COLLAPSED_TAB and self.phoneTab.w or math.min(self.phoneTab.w, 40)
		-- Right-aligned in its slot, so the icons beside it never shift when the tab changes width.
		return UDim2.fromOffset(self.phoneTab.x + self.phoneTab.w - w, self.phoneTab.y), UDim2.fromOffset(w, self.phoneTab.h)
	end
	-- Size stays in unscaled units: tabScale grows it with the stack. The position follows the scaled
	-- button column so the tab stays snug beside it.
	local s = self.fit or 1
	local x = target == EXPANDED_TAB and (MENU_X + MENU_W) * s + 3 or MENU_X * s
	return UDim2.fromOffset(x, STACK_TOP + (MENU_Y - STACK_TOP) * s), UDim2.fromOffset(target.w, MENU_H)
end

function MenuStackToggle:_stackHome()
	if self.phoneStack then
		return UDim2.fromOffset(self.phoneStack.X, self.phoneStack.Y)
	end
	return UDim2.fromOffset(0, STACK_TOP)
end

function MenuStackToggle:_stackAway()
	if self.phoneStack then
		-- Up and out of the way, back towards the tab it came from.
		return UDim2.fromOffset(self.phoneStack.X, self.phoneStack.Y - SLIDE)
	end
	return UDim2.fromOffset(-SLIDE, STACK_TOP)
end

-- Called by MenuClient when the screen changes. `spots` is PhoneLayout.Rects for a touch screen, or nil
-- for a desktop one; `inset` is the Roblox top bar, which MenuClient's ScreenGui keeps.
function MenuStackToggle:SetPhone(spots, inset)
	inset = inset or 0
	if spots then
		self.fit = 1
		self.phoneTab = { x = spots.stackTab.x, y = spots.stackTab.y - inset, w = spots.stackTab.w, h = spots.stackTab.h }
		-- Right-aligned under the tab, and pulled up so that whatever is actually showing starts right
		-- under it: MENU is its own icon on a phone and hidden in here, so the stack would otherwise
		-- open with its space empty at the top.
		local first = nil
		for _, item in ipairs(self.stack:GetChildren()) do
			if item:IsA("GuiObject") and item.Visible then
				local top = item.Position.Y.Offset
				first = first and math.min(first, top) or top
			end
		end
		self.phoneStack = Vector2.new(spots.stackTab.x + spots.stackTab.w - STACK_SIZE.X * 0.8,
			spots.stackTab.y1 + 6 - inset - (first or 0) * 0.8)
		self.stackScale.Scale = 0.8
		-- The collapsed tab is 52 wide here rather than 78, so the chevron goes and the count moves in.
		for index, b in ipairs(self.openBars) do
			b.Position = UDim2.fromOffset(13, 8 + index * 7)
			b.Size = UDim2.fromOffset(16, 3)
		end
		for _, b in ipairs(self.openChevron) do
			b.Visible = false
		end
		self.summary.Position = UDim2.fromOffset(24, 0)
		self.summary.Size = UDim2.new(1, -28, 1, 0)
		self.summary.TextSize = 14
	else
		self.phoneTab, self.phoneStack = nil, nil
		self.stackScale.Scale = 1
		self:_fitHeight()
		for index, b in ipairs(self.openBars) do
			b.Position = UDim2.fromOffset(19, 1 + index * 6)
			b.Size = UDim2.fromOffset(18, 3)
		end
		for _, b in ipairs(self.openChevron) do
			b.Visible = true
		end
		self.summary.Position = UDim2.fromOffset(32, 0)
		self.summary.Size = UDim2.new(1, -44, 1, 0)
		self.summary.TextSize = 15
	end
	-- Put the tab and the stack where they now belong, with no animation.
	self:SetCollapsed(self.collapsed, true, false)
end

-- `instant` skips the animation (first load, galleries). `save` writes the setting (a click).
function MenuStackToggle:SetCollapsed(collapsed, instant, save)
	collapsed = collapsed == true
	if save and self.settings then
		-- Settings.Changed comes straight back through here with save = false.
		self.settings.Set(MenuStackToggle.SettingId, collapsed)
		if self.settings.Get(MenuStackToggle.SettingId) == collapsed and self.collapsed == collapsed then
			return
		end
	end
	if collapsed == self.collapsed and not instant then
		return
	end
	self.collapsed = collapsed
	self.token += 1
	local token = self.token
	local tab, stack = self.tab, self.stack
	local target = collapsed and COLLAPSED_TAB or EXPANDED_TAB

	if not collapsed then
		-- Opening it is looking at it.
		self.pending = false
	end
	self:_paintDot()
	self:_paintHover()
	self.tuck.Visible = not collapsed
	self.open.Visible = collapsed
	tab.BackgroundColor3 = collapsed and C.Accent or C.Background
	tab.BackgroundTransparency = collapsed and 0 or 0.25
	self.tabStroke.Thickness = collapsed and 2 or 1.5

	local tabPosition, tabSize = self:_tabGoal(target)
	local home, away = self:_stackHome(), self:_stackAway()

	if instant then
		stack.Visible = (not collapsed) and not self.hidden
		stack.Position = home
		stack.GroupTransparency = 0
		tab.Position = tabPosition
		tab.Size = tabSize
		self.tabScale.Scale = self.fit
		return
	end

	if collapsed then
		tween(stack, 0.22, { Position = away, GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.23, function()
			if token == self.token then
				stack.Visible = false
			end
		end)
		tab.Position = tabPosition + UDim2.fromOffset(self.phoneTab and 0 or -20, self.phoneTab and -10 or 0)
		tween(tab, 0.34, { Position = tabPosition, Size = tabSize }, Enum.EasingStyle.Back)
	else
		-- `and not self.hidden`: expanding the stack while the menu is open must not put it back on
		-- top of the panel.
		stack.Visible = not self.hidden
		stack.Position = away
		stack.GroupTransparency = 1
		tween(stack, 0.3, { Position = home, GroupTransparency = 0 })
		tween(tab, 0.3, { Position = tabPosition, Size = tabSize }, Enum.EasingStyle.Back)
	end
	self.tabScale.Scale = 0.9 * self.fit
	tween(self.tabScale, 0.3, { Scale = self.fit }, Enum.EasingStyle.Back)
end

-- What the collapsed tab shows beside the menu icon: "2/3" for today's quests, or "" for nothing.
-- Out of the way while the full menu is open.
--
-- The stack is drawn at a fixed screen position and the menu panel is centred, so on a window
-- narrower than the two together the stack is drawn ON the panel -- Oliver's screenshot has this
-- tab's chevron sitting on top of the BRAINROTS rail tile. It is also redundant there: it exists to
-- REACH the menu, which is already open. The X, the scrim, Backspace and the menu key all still
-- close, so nothing is lost by taking it away.
--
-- Separate from `collapsed` on purpose. That is the player's own choice and it is remembered in
-- Settings; this is temporary and must not overwrite it, which is why SetCollapsed's writes are
-- gated on this flag rather than this sharing them.
function MenuStackToggle:SetHidden(hidden)
	hidden = hidden == true
	if hidden == self.hidden then
		return
	end
	self.hidden = hidden
	self.tab.Visible = not hidden
	self.stack.Visible = (not hidden) and not self.collapsed
end

function MenuStackToggle:SetSummary(text)
	self.summary.Text = text or ""
end

function MenuStackToggle:_paintDot()
	local show = self.collapsed and self.pending
	self.dot.Visible = show
	self.summary.TextColor3 = DARK
end

-- Something new happened. While tucked away, the tab lights up, bumps, and keeps a pulsing dot until
-- the stack is opened again. While the stack is out, it's already on screen, so nothing extra.
function MenuStackToggle:Attention()
	if not self.collapsed then
		return
	end
	self.pending = true
	self:_paintDot()
	self.tabScale.Scale = 1.18 * self.fit
	tween(self.tabScale, 0.45, { Scale = self.fit }, Enum.EasingStyle.Elastic)
	if not self.pulsing then
		self.pulsing = true
		task.spawn(function()
			while self.pending and self.collapsed do
				self.ring.Size = UDim2.fromScale(1, 1)
				self.ringStroke.Transparency = 0.1
				tween(self.ring, 0.9, { Size = UDim2.fromScale(2.6, 2.6) })
				tween(self.ringStroke, 0.9, { Transparency = 1 })
				tween(self.tabStroke, 0.45, { Thickness = 3.5 }).Completed:Wait()
				tween(self.tabStroke, 0.45, { Thickness = 2 }).Completed:Wait()
				task.wait(0.5)
			end
			self.pulsing = false
			self.ringStroke.Transparency = 1
			-- The last beat may have finished after the stack opened: put the outline back to its state's.
			self.tabStroke.Thickness = self.collapsed and 2 or 1.5
		end)
	end
end

return MenuStackToggle
