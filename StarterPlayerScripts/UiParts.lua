-- The pieces every panel is built from, drawn once here instead of by hand in each tab.
--
-- The menu and the HUD grew a panel at a time and ended up with 7 fonts, 24 text sizes, 20 corner
-- radii and 14 tween durations (tools/menu_hud_audit.py counts them). Everything here takes its
-- numbers from UiKit's tokens, so a change to a token moves every screen at once.
--
-- Three rules hold throughout:
--   * anything tappable is at least UiKit.Touch (44 px) on its shortest side, on every device;
--   * every control answers rest / hover / press / disabled / focus, so a tap or a gamepad always
--     shows it landed;
--   * meaning is never carried by colour alone — a rarity has a label as well as an edge.
--
-- A ModuleScript, so tools/menu_hud_gallery.lua can render these without a running client.

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded, padding = UiKit.create, UiKit.rounded, UiKit.padding
local Role, Type, Space, Radius, Stroke, Motion = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius, UiKit.Stroke, UiKit.Motion

local UiParts = {}

-- The SAME function as UiKit.form, not a copy: claude-a4's width probe renders pages into its own
-- frame with no shell around them and needs it as a pure call, and two implementations of "which
-- version is this screen" is precisely what everyone agreed not to have. Returns "large", "short"
-- or "tall". Pass a content width when you are inside a container rather than a whole panel — and
-- pass the CONTAINER's width, not the page's, or a row nested in a card measures the wrong thing.
UiParts.form = UiKit.form

local PRESS = TweenInfo.new(Motion.Press, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE = TweenInfo.new(Motion.Fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PANEL_IN = TweenInfo.new(Motion.Panel, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Button kinds: the colour and the ink that keeps its contrast.
local KINDS = {
	primary = { fill = Role.Accent, ink = Role.AccentInk },
	positive = { fill = Role.Positive, ink = Role.AccentInk },
	danger = { fill = Role.Negative, ink = Role.Text },
	secondary = { fill = Role.SurfaceAlt, ink = Role.Text },
	ghost = { fill = Role.Surface, ink = Role.TextMuted },
}

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

-- A label at one of the six type steps. `style` is a UiKit.Type entry.
function UiParts.text(parent, style, value, color, props)
	local label = create("TextLabel", {
		BackgroundTransparency = 1,
		Font = style.Font,
		Text = value,
		TextColor3 = color or Role.Text,
		TextSize = style.Size,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	for key, value2 in pairs(props or {}) do
		label[key] = value2
	end
	return label
end

--------------------------------------------------------------------------------
-- Controls
--------------------------------------------------------------------------------

-- Gives any button the four states. Kept separate so a tab, a chip and a card action all feel the
-- same under the finger.
function UiParts.interactive(button, fill, ink, enabled)
	if enabled == false then
		button.AutoButtonColor = false
		button.BackgroundColor3 = Role.SurfaceAlt
		button.TextColor3 = Role.TextMuted
		button.Active = false
		button.Selectable = false
		return button
	end

	-- AutoButtonColor's own shading fights the tweens below, so the states are all done here.
	button.AutoButtonColor = false
	local hover = fill:Lerp(Color3.new(1, 1, 1), 0.12)
	local press = fill:Lerp(Color3.new(0, 0, 0), 0.18)
	local focusStroke = create("UIStroke", {
		Color = Role.Text,
		Thickness = Stroke.Focus,
		Transparency = 1,
		Parent = button,
	})

	local function to(color)
		TweenService:Create(button, PRESS, { BackgroundColor3 = color }):Play()
	end
	button.MouseEnter:Connect(function()
		to(hover)
	end)
	button.MouseLeave:Connect(function()
		to(fill)
	end)
	button.MouseButton1Down:Connect(function()
		to(press)
	end)
	button.MouseButton1Up:Connect(function()
		to(hover)
	end)
	-- A finger has no "leave". Roblox sends a touch tap through the mouse events, so a tapped button
	-- lands on `hover` and stays there — MouseLeave never comes, and the phone ends up with a row of
	-- buttons that all look half-pressed. Touch input gets put back explicitly; a mouse is unaffected
	-- because this only fires for Touch.
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			to(fill)
		end
	end)
	-- Gamepad and keyboard focus: the same ring a mouse user never needs but a pad user lives by.
	button.SelectionGained:Connect(function()
		TweenService:Create(focusStroke, FADE, { Transparency = 0 }):Play()
	end)
	button.SelectionLost:Connect(function()
		TweenService:Create(focusStroke, FADE, { Transparency = 1 }):Play()
	end)
	return button
end

-- options: kind, width, height, text, icon, onClick, enabled, layoutOrder, parent, grow
function UiParts.button(options)
	local kind = KINDS[options.kind or "primary"] or KINDS.primary
	local height = math.max(options.height or UiKit.Touch, UiKit.Touch)
	local button = create("TextButton", {
		Size = options.grow and UDim2.new(1, 0, 0, height) or UDim2.fromOffset(options.width or 120, height),
		BackgroundColor3 = kind.fill,
		BorderSizePixel = 0,
		Font = Type.Label.Font,
		Text = options.icon and (options.icon .. "  " .. (options.text or "")) or (options.text or ""),
		TextColor3 = kind.ink,
		TextSize = Type.Label.Size,
		LayoutOrder = options.layoutOrder or 1,
		Parent = options.parent,
	}, { rounded(Radius.Control) })

	UiParts.interactive(button, kind.fill, kind.ink, options.enabled)
	if options.enabled ~= false and options.onClick then
		button.Activated:Connect(options.onClick)
	end
	return button
end

-- A filter or toggle pill. Selected reads as filled; unselected as an outline, never as grey text
-- alone.
function UiParts.chip(options)
	local selected = options.selected == true
	local fill = selected and Role.Accent or Role.Surface
	local chip = create("TextButton", {
		Size = UDim2.fromOffset(options.width or 96, math.max(options.height or 36, 36)),
		BackgroundColor3 = fill,
		BorderSizePixel = 0,
		Font = Type.Label.Font,
		Text = options.text or "",
		TextColor3 = selected and Role.AccentInk or Role.TextMuted,
		TextSize = Type.Caption.Size + 1,
		LayoutOrder = options.layoutOrder or 1,
		Parent = options.parent,
	}, { rounded(Radius.Pill) })
	if not selected then
		create("UIStroke", { Color = Role.Line, Thickness = Stroke.Hairline, Parent = chip })
	end
	UiParts.interactive(chip, fill, selected and Role.AccentInk or Role.TextMuted, options.enabled)
	if options.onClick then
		chip.Activated:Connect(options.onClick)
	end
	return chip
end

-- A row of media, text and actions that changes shape rather than shrinking: media left, text in
-- the middle and actions on the right while there is room; below `threshold` the media shrinks to
-- the top-left, the text takes the full width and the actions become a full-width row underneath.
--
-- Written to claude-f5's spec after their crate card broke on a narrow screen, and it bakes in the
-- two rules that failure taught, so no caller has to remember them:
--
--   * A text column is sized by SCALE inside its own frame, never `UDim2.new(1, -340, ...)` off the
--     card. A fixed negative offset looks identical to a correct one until the parent is narrow,
--     and then it is a NEGATIVE width: the label doesn't truncate, it disappears. That is how the
--     crate card's odds line vanished at 296 px of content while reading fine at 780.
--   * A line marked `disclosure` (odds, prices, refund percentages) wraps and never truncates, at
--     every width. Cutting "Comm 62.0% Unco 26.0% Rare 9.0%..." in half misstates the odds of a
--     thing bought with real money, which is a different kind of wrong from an ugly layout.
--
-- options: width, threshold (560), media (102), mediaNarrow (72), pad (Space.LG), actions (a list
-- of UiParts.button options), lines (how many text lines under the title, for the height).
-- Returns { Frame, Media, Text, Actions, Narrow, Height, Line }.
function UiParts.splitRow(parent, options)
	local width = options.width or 720
	local pad = options.pad or Space.LG
	local narrow = width < (options.threshold or 560)
	local mediaSize = narrow and (options.mediaNarrow or 72) or (options.media or 102)
	local actions = options.actions or {}
	local textLines = options.lines or 2
	-- `textHeight` overrides the line count, for a column holding something taller than text — a
	-- meterLine, say, which is a label, a bar and a caption rather than one line.
	local textHeight = options.textHeight or (Type.Heading.Size + 6 + textLines * (Type.Body.Size + 6))

	local actionsWidth = 0
	for _, action in ipairs(actions) do
		actionsWidth += (action.width or 120) + Space.SM
	end
	actionsWidth = math.max(actionsWidth - Space.SM, 0)

	-- An extra block under the text at the wide size only — a strip of pictures, say. It is skipped
	-- narrow on purpose: the things that go here restate what the text already said, and on a screen
	-- with 236 px of content a second telling costs a third of a card. Ask for it with a height.
	local belowHeight = 0
	if not narrow and options.belowText then
		belowHeight = tonumber(options.belowText) or 42
	end

	local height
	if narrow then
		height = pad + math.max(mediaSize, textHeight) + Space.MD + (#actions > 0 and UiKit.Touch or 0) + pad
	else
		local stacked = textHeight + (belowHeight > 0 and (Space.SM + belowHeight) or 0)
		height = math.max(mediaSize, stacked, UiKit.Touch) + pad * 2
	end

	local frame = create("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		LayoutOrder = options.layoutOrder or 1,
		Parent = parent,
	})

	local media = create("Frame", {
		Position = UDim2.fromOffset(pad, pad),
		Size = UDim2.fromOffset(mediaSize, mediaSize),
		BackgroundColor3 = Role.SurfaceAlt,
		BorderSizePixel = 0,
		-- So a child takes the rounded corner: this slot is a picture, and a picture with square
		-- corners inside a rounded well is the sort of thing nobody files but everybody sees.
		ClipsDescendants = true,
		Parent = frame,
	}, { rounded(Radius.Control) })
	-- `mediaInstance` takes something the caller already built — a ViewportFrame with a 3D icon in
	-- it, typically — and fits it to the slot, so the caller doesn't repeat the sizing at each
	-- breakpoint. It keeps its own contents; only where it sits and how big it is are set here.
	if options.mediaInstance and options.mediaInstance:IsA("GuiObject") then
		options.mediaInstance.AnchorPoint = Vector2.zero
		options.mediaInstance.Position = UDim2.new()
		options.mediaInstance.Size = UDim2.fromScale(1, 1)
		options.mediaInstance.Parent = media
	end

	-- `rightReserve` keeps the right-hand end of the row clear of stacked text, for a caller that
	-- draws its own thing there — claude-df's 3D parachute preview sits at the row's right edge and
	-- would otherwise have restacked text run underneath it between 420 and 560 px, where the
	-- preview is still shown but the layout has already restacked.
	--
	-- The reserve is measured from the row's right edge to the FAR side of that element, not to its
	-- near edge. I first suggested 118 for a preview positioned `UDim2.new(1, -118, ...)` and 96
	-- wide, which stops the text exactly at the preview's right edge and leaves it lying across all
	-- 96 px of it; df caught it. The number is 118 + 96 + 8 of air = 222. An anchor offset tells you
	-- where an element STARTS, and a reserve has to clear where it ENDS.
	local reserve = options.rightReserve or 0
	local textLeft = pad + mediaSize + Space.MD
	local textWidth = narrow and (width - textLeft - pad - reserve)
		or (width - textLeft - actionsWidth - Space.MD - pad)
	local text = create("Frame", {
		Position = UDim2.fromOffset(textLeft, pad),
		Size = UDim2.fromOffset(math.max(textWidth, 80), narrow and math.max(textHeight, mediaSize) or textHeight),
		BackgroundTransparency = 1,
		Parent = frame,
	}, {
		create("UIListLayout", {
			Padding = UDim.new(0, Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local below = nil
	if belowHeight > 0 then
		below = create("Frame", {
			Position = UDim2.fromOffset(textLeft, pad + textHeight + Space.SM),
			Size = UDim2.fromOffset(math.max(textWidth, 80), belowHeight),
			BackgroundTransparency = 1,
			Parent = frame,
		})
	end

	local actionFrame = create("Frame", {
		AnchorPoint = narrow and Vector2.new(0, 1) or Vector2.new(1, 0.5),
		Position = narrow and UDim2.new(0, pad, 1, -pad) or UDim2.new(1, -pad, 0.5, 0),
		Size = narrow and UDim2.new(1, -pad * 2, 0, UiKit.Touch) or UDim2.fromOffset(actionsWidth, UiKit.Touch),
		BackgroundTransparency = 1,
		Parent = frame,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = narrow and Enum.HorizontalAlignment.Left or Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Space.SM),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	-- Narrow actions share the row equally, so three buttons fill the width instead of huddling.
	local shareWidth = #actions > 0
		and math.floor((width - pad * 2 - Space.SM * (#actions - 1)) / #actions)
		or 0
	for index, action in ipairs(actions) do
		local spec = table.clone(action)
		spec.parent = actionFrame
		spec.layoutOrder = index
		spec.width = narrow and shareWidth or (action.width or 120)
		UiParts.button(spec)
	end

	local lineOrder = 0
	-- spec: text, style (a UiKit.Type entry), color, disclosure
	local function line(spec)
		lineOrder += 1
		local style = spec.style or Type.Body
		-- Said plainly, because the alternative is "attempt to perform arithmetic on nil" from a line
		-- twenty below this one. A caller with its own token table (the gallery has one, in lower
		-- case) hits this, and the message should name the fix rather than the symptom.
		if type(style) ~= "table" or type(style.Size) ~= "number" then
			error("UiParts: `style` must be a UiKit.Type entry with Size and Font, e.g. UiKit.Type.Heading", 2)
		end
		local disclosure = spec.disclosure == true
		local label = UiParts.text(text, style, spec.text or "", spec.color or Role.Text, {
			Size = UDim2.new(1, 0, 0, disclosure and (style.Size + 6) * 2 or style.Size + 6),
			LayoutOrder = lineOrder,
			TextWrapped = disclosure,
			TextTruncate = disclosure and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd,
			TextYAlignment = disclosure and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
		})
		return label
	end

	-- A meter in the text column, stacked with the Lines and told which shape it is in, so a caller
	-- never repeats the breakpoint. Pass `textHeight` to splitRow to make room for it.
	local function meter(spec)
		lineOrder += 1
		local copy = table.clone(spec)
		copy.narrow = narrow
		copy.layoutOrder = lineOrder
		return UiParts.meterLine(text, copy)
	end

	-- `Below` is nil at the narrow size, so `if row.Below then` is the caller's whole breakpoint test.
	return { Frame = frame, Media = media, Text = text, Actions = actionFrame, Below = below,
		Narrow = narrow, Height = height, Line = line, Meter = meter }
end

--------------------------------------------------------------------------------
-- Containers
--------------------------------------------------------------------------------

-- A surface with a hairline, and optionally a coloured edge down its left side for a rarity or a
-- state. The edge is always paired with a label by the caller, never used on its own.
function UiParts.card(options)
	local card = create("Frame", {
		Size = options.size or UDim2.new(1, 0, 0, 116),
		Position = options.position,
		AnchorPoint = options.anchorPoint,
		BackgroundColor3 = options.color or Role.Surface,
		BorderSizePixel = 0,
		LayoutOrder = options.layoutOrder or 1,
		Parent = options.parent,
	}, { rounded(Radius.Card) })
	create("UIStroke", { Color = Role.Line, Thickness = Stroke.Hairline, Parent = card })
	if options.edge then
		create("Frame", {
			Position = UDim2.fromOffset(0, Space.MD),
			Size = UDim2.new(0, 4, 1, -Space.MD * 2),
			BackgroundColor3 = options.edge,
			BorderSizePixel = 0,
			Parent = card,
		}, { rounded(Radius.Pill) })
	end
	return card
end

-- The panel header: title on the left, a slot for the wallet, then icon actions on the right.
-- Returns the header and the frame callers can drop the wallet into.
function UiParts.header(options)
	local height = options.height or 64
	local header = create("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		Parent = options.parent,
	}, { padding(Space.LG) })

	-- The title's width is what is LEFT after the wallet and the buttons, worked out from their real
	-- widths — not a fixed 320, which is what it used to be and which is the same mistake I have
	-- spent today finding in other people's files. At a 320-wide panel, `1, -320` left the title
	-- nothing and the game's name rendered as "BRAI". Caught in a portrait render, not by reading.
	--
	-- Below `SLOT_DROPS` of remaining room the wallet slot is given up rather than the title: the
	-- panel's name is how a player knows what they are looking at, and the coin count is repeated
	-- inside the tabs that spend coins.
	local SLOT_DROPS = 150
	local width = options.width or 0
	local actionsWidth = #(options.actions or {}) * (UiKit.Touch + Space.SM)
	local slotWidth = options.slotWidth or 168
	local room = width - Space.LG * 2 - actionsWidth - Space.SM
	local showSlot = options.slot ~= false and (width == 0 or room - slotWidth >= SLOT_DROPS)
	local reserve = actionsWidth + Space.SM + (showSlot and slotWidth + Space.SM or 0)

	UiParts.text(header, options.compact and Type.Heading or Type.Title, options.title or "", Role.Text, {
		Size = UDim2.new(1, -reserve, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local actions = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(#(options.actions or {}) * (UiKit.Touch + Space.SM), UiKit.Touch),
		BackgroundTransparency = 1,
		Parent = header,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Space.SM),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, action in ipairs(options.actions or {}) do
		local button = UiParts.button({
			kind = "ghost",
			width = UiKit.Touch,
			text = action.glyph,
			onClick = action.onClick,
			layoutOrder = index,
			parent = actions,
		})
		button.TextSize = Type.Heading.Size
	end

	local slot = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(actionsWidth + Space.SM), 0.5, 0),
		Size = UDim2.fromOffset(slotWidth, UiKit.Touch),
		BackgroundTransparency = 1,
		Visible = showSlot,
		Parent = header,
	})
	return header, slot
end

-- Nothing here yet, said properly: what's missing, why, and the one button that fixes it.
function UiParts.emptyState(options)
	local frame = UiParts.card({
		size = UDim2.new(1, 0, 0, options.action and 132 or 96),
		layoutOrder = options.layoutOrder,
		parent = options.parent,
	})
	UiParts.text(frame, Type.Heading, options.title or "Nothing here yet", Role.Text, {
		Position = UDim2.fromOffset(Space.LG, Space.MD),
		Size = UDim2.new(1, -Space.LG * 2, 0, 24),
	})
	UiParts.text(frame, Type.Body, options.body or "", Role.TextMuted, {
		Position = UDim2.fromOffset(Space.LG, Space.MD + 26),
		Size = UDim2.new(1, -Space.LG * 2, 0, 22),
		TextWrapped = true,
	})
	if options.action then
		UiParts.button({
			kind = "primary",
			width = options.action.width or 180,
			text = options.action.text,
			onClick = options.action.onClick,
			parent = frame,
		}).Position = UDim2.fromOffset(Space.LG, 132 - Space.MD - UiKit.Touch)
	end
	return frame
end

-- A bar with a label, for pass tiers, quest progress and anything else counted. The number is
-- always written as well as drawn.
function UiParts.meter(options)
	local frame = create("Frame", {
		Size = options.size or UDim2.new(1, 0, 0, 28),
		Position = options.position,
		BackgroundTransparency = 1,
		LayoutOrder = options.layoutOrder or 1,
		Parent = options.parent,
	})
	local track = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, options.showValue == false and 0 or -72, 0, 12),
		BackgroundColor3 = Role.SurfaceAlt,
		BorderSizePixel = 0,
		Parent = frame,
	}, { rounded(Radius.Pill) })
	local fill = create("Frame", {
		Size = UDim2.fromScale(math.clamp(options.alpha or 0, 0, 1), 1),
		BackgroundColor3 = options.color or Role.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { rounded(Radius.Pill) })
	if options.showValue ~= false then
		UiParts.text(frame, Type.Label, options.value or "", Role.Text, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(64, 20),
			TextXAlignment = Enum.TextXAlignment.Right,
		})
	end
	return frame, fill
end

-- A label, a bar under it, and a value — the shape progression uses for mastery rows, the rank
-- hero bar and the overflow bar. Built for claude-a4 [34c594] to their spec.
--
-- Everything here is sized by SCALE inside whatever column it is dropped into, so it inherits that
-- column's width and there is no offset to go negative. Wide, the value sits at the right-hand end
-- of the label's line; narrow, it moves to its own line under the bar rather than fighting the
-- label for room. `caption` is the trailing detail (what the next tier pays, say) and it wraps
-- rather than truncates, because those figures are a promise to the player, like the crate odds.
--
-- options: label, value, fraction (0..1), color, caption, narrow, height, layoutOrder
function UiParts.meterLine(parent, options)
	local narrow = options.narrow == true
	local labelHeight = Type.Label.Size + 6
	local barHeight = options.height or 12
	local captionHeight = options.caption and (Type.Caption.Size + 6) * 2 or 0
	local valueRow = (narrow and options.value) and labelHeight or 0
	local total = labelHeight + Space.XS + barHeight + valueRow + (captionHeight > 0 and Space.XS + captionHeight or 0)

	local frame = create("Frame", {
		Size = UDim2.new(1, 0, 0, total),
		BackgroundTransparency = 1,
		LayoutOrder = options.layoutOrder or 1,
		Parent = parent,
	})

	-- Wide, the value is right-aligned on the label's line, so the label is given the room the value
	-- doesn't need rather than a guess at it.
	UiParts.text(frame, Type.Label, options.label or "", Role.Text, {
		Size = narrow and UDim2.new(1, 0, 0, labelHeight) or UDim2.new(0.68, 0, 0, labelHeight),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	if options.value and not narrow then
		UiParts.text(frame, Type.Label, options.value, Role.TextMuted, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0.3, 0, 0, labelHeight),
			TextXAlignment = Enum.TextXAlignment.Right,
		})
	end

	local track = create("Frame", {
		Position = UDim2.fromOffset(0, labelHeight + Space.XS),
		Size = UDim2.new(1, 0, 0, barHeight),
		BackgroundColor3 = Role.SurfaceAlt,
		BorderSizePixel = 0,
		Parent = frame,
	}, { rounded(Radius.Pill) })
	local fill = create("Frame", {
		Size = UDim2.fromScale(math.clamp(options.fraction or 0, 0, 1), 1),
		BackgroundColor3 = options.color or Role.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { rounded(Radius.Pill) })

	local below = labelHeight + Space.XS + barHeight
	if options.value and narrow then
		UiParts.text(frame, Type.Label, options.value, Role.TextMuted, {
			Position = UDim2.fromOffset(0, below),
			Size = UDim2.new(1, 0, 0, labelHeight),
		})
		below += labelHeight
	end
	if options.caption then
		UiParts.text(frame, Type.Caption, options.caption, Role.TextMuted, {
			Position = UDim2.fromOffset(0, below + Space.XS),
			Size = UDim2.new(1, 0, 0, captionHeight),
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.None,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
	end
	return frame, fill, total
end

--------------------------------------------------------------------------------
-- Navigation and layers
--------------------------------------------------------------------------------

-- One destination. `rail` draws it wide with a subtitle; otherwise it's a bottom-bar cell.
-- `compact` is the small (landscape phone) rail: a glyph only, in a 44 px square, because that
-- shape has width to spare and no height at all. The label would cost nothing horizontally and
-- everything vertically.
function UiParts.navItem(options)
	local selected = options.selected == true
	local fill = selected and Role.Accent or Role.Surface
	local compact = options.rail and options.compact
	local cell = create("TextButton", {
		Size = compact and UDim2.new(1, 0, 0, UiKit.Touch)
			or (options.rail and UDim2.new(1, 0, 0, 56) or UDim2.fromOffset(options.width or 96, UiKit.Touch)),
		BackgroundColor3 = fill,
		BorderSizePixel = 0,
		Text = "",
		LayoutOrder = options.layoutOrder or 1,
		Parent = options.parent,
	}, { rounded(options.rail and Radius.Card or Radius.Control) })
	UiParts.interactive(cell, fill, selected and Role.AccentInk or Role.Text, options.enabled)

	if compact then
		UiParts.text(cell, Type.Heading, options.glyph or "", selected and Role.AccentInk or Role.Text, {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
		})
	elseif options.rail then
		UiParts.text(cell, Type.Heading, options.glyph or "", selected and Role.AccentInk or Role.TextMuted, {
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.fromOffset(24, 56),
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		UiParts.text(cell, Type.Label, options.label or "", selected and Role.AccentInk or Role.Text, {
			Position = UDim2.fromOffset(44, 8),
			Size = UDim2.new(1, -52, 0, 20),
		})
		if options.sub then
			UiParts.text(cell, Type.Caption, options.sub, selected and Role.AccentInk or Role.TextMuted, {
				Position = UDim2.fromOffset(44, 28),
				Size = UDim2.new(1, -52, 0, 18),
				TextTransparency = selected and 0.25 or 0,
			})
		end
	else
		local label = options.glyphOnly and (options.glyph or "")
			or ((options.glyph and (options.glyph .. "  ") or "") .. (options.label or ""))
		UiParts.text(cell, Type.Label, label, selected and Role.AccentInk or Role.TextMuted, {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextSize = options.glyphOnly and Type.Heading.Size or Type.Caption.Size,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
	end
	if options.onClick then
		cell.Activated:Connect(options.onClick)
	end
	return cell
end

-- A dimming layer under a panel or dialog. Clicking it dismisses, the way a player expects.
function UiParts.scrim(parent, onDismiss)
	local scrim = create("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Role.Scrim,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = parent,
	})
	TweenService:Create(scrim, FADE, { BackgroundTransparency = 0.45 }):Play()
	if onDismiss then
		scrim.Activated:Connect(onDismiss)
	end
	return scrim
end

-- Opens a panel: fades the scrim in and lifts the panel the last few pixels, in Motion.Panel.
--
-- `target` is the scale the panel rests at, 1 unless something is holding it smaller. A panel on a
-- screen too small for it is shrunk to fit by a UIScale, and this animation drives that same object
-- (Roblox honours one UIScale per element), so animating to a flat 1 would quietly undo the fit and
-- push the panel's bottom back off the screen. It animates to a fraction of the target instead.
function UiParts.openPanel(panel, scale, target)
	panel.Visible = true
	target = target or 1
	scale = scale or panel:FindFirstChildOfClass("UIScale") or create("UIScale", { Parent = panel })
	scale.Scale = target * 0.96
	TweenService:Create(scale, PANEL_IN, { Scale = target }):Play()
	return scale
end

function UiParts.closePanel(panel, scale, onClosed, target)
	scale = scale or panel:FindFirstChildOfClass("UIScale")
	target = target or 1
	if not scale then
		panel.Visible = false
		if onClosed then
			onClosed()
		end
		return
	end
	local tween = TweenService:Create(scale, PRESS, { Scale = target * 0.97 })
	tween.Completed:Connect(function()
		panel.Visible = false
		scale.Scale = target
		if onClosed then
			onClosed()
		end
	end)
	tween:Play()
end

-- A modal question. Returns the layer, the dialog and a `dismiss` function. Every action closes it
-- and then runs its own onClick; the scrim (and a caller's Back, through `dismiss`) closes it and
-- calls `onDismiss`, so there is always a way out. There is no X or Escape binding.
function UiParts.dialog(options)
	local viewport = options.viewport or Vector2.new(1280, 720)
	local touch = UserInputService.TouchEnabled
	local width = math.min(options.width or 420, viewport.X - UiKit.safeArea(viewport, touch).Left * 2)
	local layer = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = options.parent,
	})

	-- The layer sits on the caller's ScreenGui, not in a panel a re-render or the menu's Back would
	-- clear, so nothing but this removes it: without it a CANCEL with no onClick was dead and the
	-- scrim ate every click until rejoin. Guarded so a double tap can't run an action twice, and the
	-- layer goes BEFORE the handler so one that yields on the server isn't left under a live dialog.
	local closed = false
	local function close(handler)
		if closed then
			return
		end
		closed = true
		layer:Destroy()
		if handler then
			handler()
		end
	end
	local function dismiss()
		close(options.onDismiss)
	end
	UiParts.scrim(layer, dismiss)

	local dialog = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, options.height or 220),
		BackgroundColor3 = Role.Base,
		BorderSizePixel = 0,
		Parent = layer,
	}, { rounded(Radius.Panel) })
	create("UIStroke", { Color = Role.Line, Thickness = Stroke.Hairline, Parent = dialog })

	UiParts.text(dialog, Type.Heading, options.title or "", Role.Text, {
		Position = UDim2.fromOffset(Space.LG, Space.LG),
		Size = UDim2.new(1, -Space.LG * 2 - UiKit.Touch, 0, 26),
	})
	UiParts.text(dialog, Type.Body, options.body or "", Role.TextMuted, {
		Position = UDim2.fromOffset(Space.LG, Space.LG + 30),
		Size = UDim2.new(1, -Space.LG * 2, 0, 48),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local actions = create("Frame", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -Space.LG, 1, -Space.LG),
		Size = UDim2.new(1, -Space.LG * 2, 0, UiKit.Touch),
		BackgroundTransparency = 1,
		Parent = dialog,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, Space.SM),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, action in ipairs(options.actions or {}) do
		UiParts.button({
			kind = action.kind or (index == #(options.actions or {}) and "primary" or "secondary"),
			width = action.width or 132,
			text = action.text,
			onClick = function()
				close(action.onClick)
			end,
			layoutOrder = index,
			parent = actions,
		})
	end
	UiParts.openPanel(dialog)
	return layer, dialog, dismiss
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

-- How many card columns fit a width, so a grid reflows instead of being fixed per screen.
function UiParts.columns(width, minimum)
	minimum = minimum or 300
	return math.max(1, math.floor((width + Space.MD) / (minimum + Space.MD)))
end

-- A grid that fills its parent, sized from the columns that fit.
function UiParts.grid(parent, width, cardHeight, minimum)
	local columns = UiParts.columns(width, minimum)
	local cardWidth = math.floor((width - Space.MD * (columns - 1)) / columns)
	local layout = create("UIGridLayout", {
		CellSize = UDim2.fromOffset(cardWidth, cardHeight),
		CellPadding = UDim2.fromOffset(Space.MD, Space.MD),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = parent,
	})
	return layout, columns, cardWidth
end

return UiParts
