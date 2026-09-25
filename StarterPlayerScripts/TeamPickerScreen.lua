-- The team picker's drawing: two team cards, AUTO-ASSIGN and the countdown. The wiring (remotes, keys,
-- the gamepad, the cursor) is TeamPickerClient; where the panel goes and how big it is, TeamPickerLayout.
-- A ModuleScript so tools/gallery.ps1 renders exactly what a player sees.
--
--   local screen = TeamPickerScreen.new(screenGui)
--   screen.OnPick = function(team) end      -- 1, 2, or 0 for AUTO
--   screen:Layout(TeamPickerLayout.Compute(viewport, ctx))
--   screen:Render(snapshot)                 -- TeamPicker.Snapshot's shape
--   screen:SetInput("keyboard" | "gamepad" | "touch")
--   screen:Show() / screen:Hide()
--
-- Every size is the layout's natural number times its scale, and every text is at least 12 px.
-- The emblem is GameModes.TeamInsignia(index) when a team-art pass adds one (an image id); until then
-- it is a neutral mark drawn here: a diamond in the team colour carrying the side's initial.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local TeamPickerLayout = require(script.Parent:WaitForChild("TeamPickerLayout"))

local create = UiKit.create
local Role, Type, Motion = UiKit.Role, UiKit.Type, UiKit.Motion

local QUICK = TweenInfo.new(Motion.Press, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE = TweenInfo.new(Motion.Fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP = TweenInfo.new(Motion.Panel, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local INK = Color3.fromRGB(16, 18, 24)

local TeamPickerScreen = {}
TeamPickerScreen.__index = TeamPickerScreen
-- Test seam: every tween lands at once (tools/team_picker_gallery.lua, so a still shows the end state).
TeamPickerScreen.Instant = false

local function tween(inst, info, goals)
	if TeamPickerScreen.Instant then
		for k, v in pairs(goals) do
			inst[k] = v
		end
		return nil
	end
	local ok, t = pcall(function()
		return TweenService:Create(inst, info, goals)
	end)
	if ok and t then
		t:Play()
		return t
	end
	for k, v in pairs(goals) do
		inst[k] = v
	end
	return nil
end

-- The side's emblem image when one exists (a later team-art pass), else nil for the drawn mark.
local function insignia(team)
	local accessor = rawget(GameModes, "TeamInsignia")
	if type(accessor) ~= "function" then
		return nil
	end
	local ok, image = pcall(accessor, team)
	return ok and type(image) == "string" and image ~= "" and image or nil
end

function TeamPickerScreen.new(parent)
	local self = setmetatable({}, TeamPickerScreen)
	self.parent = parent
	self.OnPick = nil
	self.input = "keyboard"
	self.snapshot = nil
	self.pending = nil
	self.shown = false
	return self
end

-- Pixel helpers for the current scale.
function TeamPickerScreen:px(n)
	return math.floor(n * self.scale + 0.5)
end

function TeamPickerScreen:tx(n)
	return math.max(12, math.floor(n * self.scale + 0.5))
end

function TeamPickerScreen:_label(parent, props)
	props.BackgroundTransparency = 1
	props.TextColor3 = props.TextColor3 or Role.Text
	props.Font = props.Font or Type.Body.Font
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.TextTruncate = props.TextTruncate or Enum.TextTruncate.AtEnd
	props.Parent = parent
	return create("TextLabel", props)
end

-- A keycap: "1", "2", "3" on a keyboard, "A"/"B" on a gamepad. Hidden on touch.
function TeamPickerScreen:_keycap(parent, text, x, y, ink)
	local size = self:px(self.N.key)
	local cap = create("Frame", {
		Name = "Keycap",
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Role.Base,
		BackgroundTransparency = 0.35,
		Parent = parent,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, self:px(6)) }),
		create("UIStroke", { Color = ink or Role.Text, Thickness = 1, Transparency = 0.4 }),
	})
	self:_label(cap, {
		Name = "Key",
		Size = UDim2.fromScale(1, 1),
		Text = text,
		Font = Type.Label.Font,
		TextSize = self:tx(self.N.text.key),
		TextColor3 = ink or Role.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	return cap
end

-- The neutral mark: a diamond in the team colour with the side's initial, on a dark disc.
function TeamPickerScreen:_emblem(parent, team, size, x, y)
	local color = GameModes.TeamColor(team)
	local holder = create("Frame", {
		Name = "Emblem",
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.25,
		Parent = parent,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local image = insignia(team)
	if image then
		create("ImageLabel", {
			Name = "Insignia",
			Size = UDim2.fromScale(0.8, 0.8),
			Position = UDim2.fromScale(0.1, 0.1),
			BackgroundTransparency = 1,
			Image = image,
			ScaleType = Enum.ScaleType.Fit,
			Parent = holder,
		})
		return holder
	end
	local d = math.floor(size * 0.62 + 0.5)
	create("Frame", {
		Name = "Diamond",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(d, d),
		Rotation = 45,
		BackgroundColor3 = color,
		Parent = holder,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, self:px(5)) }),
		create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 1.5, Transparency = 0.35 }),
	})
	local team_ = GameModes.Team(team)
	self:_label(holder, {
		Name = "Initial",
		Size = UDim2.fromScale(1, 1),
		Text = team_ and string.sub(team_.short or team_.name, 1, 1) or tostring(team),
		Font = Type.Title.Font,
		TextSize = self:tx(self.N.text.initial),
		TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.None,
	})
	return holder
end

-- A check mark drawn from two bars, so it never depends on a font having the glyph.
function TeamPickerScreen:_check(parent, size, x, y, color)
	local badge = create("Frame", {
		Name = "Check",
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = parent,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local t = math.max(2, math.floor(size * 0.14 + 0.5))
	create("Frame", {
		Name = "Short",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.36, 0.56),
		Size = UDim2.fromOffset(math.floor(size * 0.32 + 0.5), t),
		Rotation = 45,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = badge,
	})
	create("Frame", {
		Name = "Long",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.58, 0.47),
		Size = UDim2.fromOffset(math.floor(size * 0.52 + 0.5), t),
		Rotation = -50,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = badge,
	})
	return badge
end

function TeamPickerScreen:_card(team, x, y, w, h)
	local color = GameModes.TeamColor(team)
	local pad = self:px(self.N.cardPad)
	local band = self:px(self.N.band)
	local card = create("TextButton", {
		Name = "Team" .. team,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = Role.Surface,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		Parent = self.panel,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, self:px(self.N.cardRadius)) }),
	})
	-- Our own focus ring (the default selection image is a box that ignores the rounded corners).
	card.SelectionImageObject = create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0, 0) })
	local stroke = create("UIStroke", { Color = Role.Line, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = card })
	local pop = create("UIScale", { Scale = 1, Parent = card })

	local bandFrame = create("Frame", {
		Name = "Band",
		Size = UDim2.new(1, 0, 0, band),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = card,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, self:px(self.N.cardRadius)) }),
		create("UIGradient", {
			Color = ColorSequence.new(color, color:Lerp(Color3.new(0, 0, 0), 0.38)),
			Rotation = 20,
		}),
	})
	-- Squares the band's lower corners off against the card body.
	create("Frame", {
		Name = "BandFoot",
		Position = UDim2.new(0, 0, 1, -self:px(self.N.cardRadius)),
		Size = UDim2.new(1, 0, 0, self:px(self.N.cardRadius)),
		BackgroundColor3 = color:Lerp(Color3.new(0, 0, 0), 0.2),
		BorderSizePixel = 0,
		Parent = bandFrame,
	})
	local emblemSize = self:px(self.N.emblem)
	local emblem = self:_emblem(bandFrame, team, emblemSize, pad, math.floor((band - emblemSize) / 2))
	local textX = pad + emblemSize + self:px(10)
	local name = self:_label(bandFrame, {
		Name = "TeamName",
		Position = UDim2.fromOffset(textX, math.floor(band * 0.12 + 0.5)),
		Size = UDim2.new(1, -textX - pad, 0, math.floor(band * 0.42 + 0.5)),
		Text = self.compact and ((GameModes.Team(team) or {}).short or GameModes.TeamName(team)) or GameModes.TeamName(team),
		Font = Type.Heading.Font,
		TextSize = self:tx(self.N.text.name),
		TextColor3 = Color3.new(1, 1, 1),
	})
	local count = self:_label(bandFrame, {
		Name = "Count",
		Position = UDim2.fromOffset(textX, math.floor(band * 0.57 + 0.5)),
		Size = UDim2.new(1, -textX - pad, 0, math.floor(band * 0.3 + 0.5)),
		Text = "",
		Font = Type.Label.Font,
		TextSize = self:tx(self.N.text.count),
		TextColor3 = Color3.new(1, 1, 1),
		TextTransparency = 0.1,
	})
	local check = self:_check(bandFrame, self:px(self.N.check), pad + emblemSize - self:px(14), math.floor((band - emblemSize) / 2) + emblemSize - self:px(14), color)
	check.Visible = false

	-- The roster: a dot in the team colour and a name per row.
	local rows = {}
	local rowH = self:px(self.N.row)
	local top = band + pad
	for i = 1, self.rows do
		local row = create("Frame", {
			Name = "Row" .. i,
			Position = UDim2.fromOffset(pad, top + (i - 1) * rowH),
			Size = UDim2.new(1, -2 * pad, 0, rowH),
			BackgroundTransparency = 1,
			Parent = card,
		})
		local dot = self:px(8)
		local dotFrame = create("Frame", {
			Name = "Dot",
			Position = UDim2.fromOffset(0, math.floor((rowH - dot) / 2)),
			Size = UDim2.fromOffset(dot, dot),
			BackgroundColor3 = color,
			Parent = row,
		}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
		local label = self:_label(row, {
			Name = "Name",
			Position = UDim2.fromOffset(dot + self:px(8), 0),
			Size = UDim2.new(1, -(dot + self:px(8)), 1, 0),
			Text = "",
			TextSize = self:tx(self.N.text.row),
		})
		rows[i] = { frame = row, dot = dotFrame, label = label }
	end
	local botsY = top + self.rows * rowH
	-- The compact card carries the bots on its count line instead.
	local bots = self.N.botsLine > 0 and self:_label(card, {
		Name = "Bots",
		Position = UDim2.fromOffset(pad, botsY),
		Size = UDim2.new(1, -2 * pad, 0, self:px(self.N.botsLine)),
		Text = "",
		TextSize = self:tx(self.N.text.bots),
		TextColor3 = Role.TextMuted,
	}) or nil

	local actionH = self:px(self.N.action)
	local action = create("Frame", {
		Name = "Action",
		Position = UDim2.new(0, pad, 1, -pad - actionH),
		Size = UDim2.new(1, -2 * pad, 0, actionH),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.78,
		Parent = card,
	}, { create("UICorner", { CornerRadius = UDim.new(0, self:px(self.N.controlRadius)) }) })
	local actionText = self:_label(action, {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		Text = "JOIN",
		Font = Type.Heading.Font,
		TextSize = self:tx(self.N.text.action),
		TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.35),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	local capInk = color:Lerp(Color3.new(1, 1, 1), 0.35)
	local keycap = self:_keycap(action, tostring(team), self:px(8), math.floor((actionH - self:px(self.N.key)) / 2), capInk)

	card.MouseEnter:Connect(function()
		if self.hover ~= team then
			self.hover = team
			tween(card, QUICK, { BackgroundColor3 = Role.SurfaceAlt })
		end
	end)
	card.MouseLeave:Connect(function()
		self.hover = nil
		tween(card, QUICK, { BackgroundColor3 = Role.Surface })
	end)
	card.SelectionGained:Connect(function()
		self.focus = team
		self:_paint()
	end)
	card.SelectionLost:Connect(function()
		if self.focus == team then
			self.focus = nil
		end
		self:_paint()
	end)
	card.Activated:Connect(function()
		self:Choose(team)
	end)

	return {
		team = team, button = card, stroke = stroke, pop = pop, band = bandFrame, name = name, count = count,
		check = check, rows = rows, bots = bots, action = action, actionText = actionText, keycap = keycap,
		emblem = emblem, color = color, home = card.Position,
	}
end

function TeamPickerScreen:Choose(team)
	local snap = self.snapshot
	if snap and team ~= 0 and snap.teams and snap.teams[team] and snap.teams[team].full and snap.mine ~= team then
		self:Refused(team, "full")
		return
	end
	self.pending = team
	self.lastAsk = team
	self:_paint()
	if self.OnPick then
		self.OnPick(team)
	end
end

-- (Re)builds the panel for a layout (TeamPickerLayout.Compute's result). Keeps the snapshot.
function TeamPickerScreen:Layout(fit)
	self.fit = fit
	self.scale = fit.scale
	self.rows = fit.rows
	self.N = fit.metrics
	self.compact = fit.metrics.autoInHeader == true
	if self.panel then
		self.panel:Destroy()
	end
	local r = fit.panel
	local pad = self:px(self.N.pad)
	local gap = self:px(self.N.gap)
	local panel = create("Frame", {
		Name = "TeamPicker",
		Position = UDim2.fromOffset(r.x, r.y),
		Size = UDim2.fromOffset(r.w, r.h),
		BackgroundColor3 = Role.Base,
		BackgroundTransparency = 0.03,
		SelectionGroup = true,
		Visible = self.shown,
		Parent = self.parent,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, self:px(self.N.panelRadius)) }),
		create("UIStroke", { Color = Role.Line, Thickness = 1.5 }),
	})
	self.panel = panel
	panel:SetAttribute("Scale", fit.scale)
	panel:SetAttribute("Variant", fit.variant)
	panel:SetAttribute("Readable", fit.readable == true)
	self.panelScale = create("UIScale", { Scale = 1, Parent = panel })

	-- A two-colour seam along the top: one side's colour running into the other's.
	create("Frame", {
		Name = "Seam",
		Position = UDim2.fromOffset(self:px(self.N.panelRadius), 0),
		Size = UDim2.new(1, -2 * self:px(self.N.panelRadius), 0, self:px(4)),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = panel,
	}, {
		create("UIGradient", { Color = ColorSequence.new(GameModes.TeamColor(1), GameModes.TeamColor(2)) }),
	})

	-- Header: title and line on the left, the seconds on the right, the draining bar beneath. The compact
	-- header also carries AUTO at its right, with the seconds as a figure between.
	local inHeader = self.N.autoInHeader == true
	local innerW = r.w - 2 * pad
	local autoW = math.min(math.floor(innerW * 0.5), self:px(self.N.autoW))
	local timerW = self:px(self.N.timerW)
	local timerH = self:px(self.N.header - 18)
	local reserve = timerW + gap + (inHeader and (autoW + gap) or 0)
	self.title = self:_label(panel, {
		Name = "Title",
		Position = UDim2.fromOffset(pad, pad),
		Size = UDim2.new(1, -2 * pad - reserve, 0, self:px(self.N.header * 0.48)),
		Text = inHeader and "PICK A SIDE" or "CHOOSE YOUR SIDE",
		Font = Type.Title.Font,
		TextSize = self:tx(self.N.text.title),
	})
	self.sub = self:_label(panel, {
		Name = "Sub",
		Position = UDim2.fromOffset(pad, pad + self:px(self.N.header * 0.52)),
		Size = UDim2.new(1, -2 * pad - reserve, 0, self:px(self.N.header * 0.32)),
		Text = "",
		TextSize = self:tx(self.N.text.sub),
		TextColor3 = Role.TextMuted,
	})
	local timer = create("Frame", {
		Name = "Timer",
		Position = UDim2.new(1, -pad - (inHeader and (autoW + gap) or 0) - timerW, 0, pad),
		Size = UDim2.fromOffset(timerW, timerH),
		BackgroundColor3 = Role.Surface,
		BackgroundTransparency = inHeader and 1 or 0,
		Parent = panel,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, self:px(self.N.controlRadius)) }),
		create("UIStroke", { Color = Role.Line, Thickness = 1, Transparency = inHeader and 1 or 0 }),
	})
	self.timerText = self:_label(timer, {
		Name = "Seconds",
		Size = UDim2.fromScale(1, 1),
		Text = "",
		Font = Type.Title.Font,
		TextSize = self:tx(self.N.text.timer),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	self.timerFrame = timer
	local barY = pad + self:px(self.N.header) - self:px(6)
	local track = create("Frame", {
		Name = "Track",
		Position = UDim2.fromOffset(pad, barY),
		Size = UDim2.new(1, -2 * pad, 0, self:px(4)),
		BackgroundColor3 = Role.SurfaceAlt,
		BorderSizePixel = 0,
		Parent = panel,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	self.bar = create("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Role.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })

	-- The two cards.
	local cardsY = pad + self:px(self.N.header) + gap
	local cardH = self:px(TeamPickerLayout.CardHeight(self.N, fit.rows))
	self.cards = {}
	for team = 1, 2 do
		if fit.stacked then
			self.cards[team] = self:_card(team, pad, cardsY + (team - 1) * (cardH + gap), innerW, cardH)
		else
			local w = math.floor((innerW - gap) / 2)
			self.cards[team] = self:_card(team, pad + (team - 1) * (w + gap), cardsY, w, cardH)
		end
	end

	-- Footer: AUTO-ASSIGN and what it means (in the header on the compact panel, with no note).
	local footH = self:px(self.N.footButton)
	local footY = r.h - pad - footH
	local autoX = pad
	if inHeader then
		footY = pad + math.floor((self:px(self.N.header) - self:px(6) - footH) / 2)
		autoX = r.w - pad - autoW
	end
	local auto = create("TextButton", {
		Name = "Auto",
		Position = UDim2.fromOffset(autoX, footY),
		Size = UDim2.fromOffset(autoW, footH),
		BackgroundColor3 = Role.Surface,
		AutoButtonColor = false,
		Text = "",
		Selectable = true,
		Parent = panel,
	}, { create("UICorner", { CornerRadius = UDim.new(0, self:px(self.N.controlRadius)) }) })
	auto.SelectionImageObject = create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0, 0) })
	self.autoStroke = create("UIStroke", { Color = Role.Accent, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = auto })
	self.autoText = self:_label(auto, {
		Name = "Label",
		Position = UDim2.fromOffset(self:px(self.N.key + 16), 0),
		Size = UDim2.new(1, -self:px(self.N.key + 24), 1, 0),
		Text = "AUTO-ASSIGN",
		Font = Type.Heading.Font,
		TextSize = self:tx(self.N.text.auto),
		TextColor3 = Role.Accent,
	})
	self.autoKey = self:_keycap(auto, "3", self:px(8), math.floor((footH - self:px(self.N.key)) / 2), Role.Accent)
	self.auto = auto
	self.note = self:_label(panel, {
		Name = "Note",
		Visible = not inHeader,
		Position = UDim2.fromOffset(pad + autoW + gap, footY),
		Size = UDim2.new(1, -(2 * pad + autoW + gap), 0, footH),
		Text = "",
		TextSize = self:tx(self.N.text.note),
		TextColor3 = Role.TextMuted,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
	})
	auto.MouseEnter:Connect(function()
		tween(auto, QUICK, { BackgroundColor3 = Role.SurfaceAlt })
	end)
	auto.MouseLeave:Connect(function()
		self:_paint()
	end)
	auto.SelectionGained:Connect(function()
		self.focus = 0
		self:_paint()
	end)
	auto.SelectionLost:Connect(function()
		if self.focus == 0 then
			self.focus = nil
		end
		self:_paint()
	end)
	auto.Activated:Connect(function()
		self:Choose(0)
	end)

	-- Gamepad and arrow-key navigation: across the cards, then down to AUTO.
	local c1, c2 = self.cards[1].button, self.cards[2].button
	if fit.stacked then
		c1.NextSelectionDown, c2.NextSelectionUp = c2, c1
	else
		c1.NextSelectionRight, c2.NextSelectionLeft = c2, c1
	end
	if inHeader then
		-- AUTO is above the cards.
		c1.NextSelectionUp, auto.NextSelectionDown = auto, c1
		if not fit.stacked then
			c2.NextSelectionUp = auto
		end
	elseif fit.stacked then
		c2.NextSelectionDown, auto.NextSelectionUp = auto, c2
	else
		c1.NextSelectionDown, c2.NextSelectionDown, auto.NextSelectionUp = auto, auto, c1
	end

	self:SetInput(self.input)
	if self.snapshot then
		self:Render(self.snapshot)
	end
	return panel
end

-- The keycaps follow the input in use: numbers on a keyboard, A on the focused card and B on AUTO on a
-- gamepad, nothing on a touch screen.
function TeamPickerScreen:SetInput(kind)
	self.input = kind
	if not self.cards then
		return
	end
	for team, card in pairs(self.cards) do
		card.keycap.Visible = kind ~= "touch" and (kind ~= "gamepad" or self.focus == team)
		card.keycap.Key.Text = kind == "gamepad" and "A" or tostring(team)
	end
	self.autoKey.Visible = kind ~= "touch"
	self.autoKey.Key.Text = kind == "gamepad" and "B" or "3"
	self:_paint()
end

-- The side a player is on right now, as they see it: what they just tapped (until the server answers)
-- or what the server says.
function TeamPickerScreen:Mine()
	if self.pending ~= nil then
		return self.pending
	end
	return self.snapshot and self.snapshot.mine or 0
end

function TeamPickerScreen:_paint()
	if not self.cards then
		return
	end
	local snap = self.snapshot or {}
	local mine = self:Mine()
	for team, card in pairs(self.cards) do
		local info = snap.teams and snap.teams[team] or {}
		local selected = mine == team
		local full = info.full and not selected
		local focused = self.focus == team
		tween(card.stroke, FADE, {
			Color = (selected or focused) and (focused and not selected and Role.Text or card.color) or Role.Line,
			Thickness = selected and self:px(3) or (focused and 2 or 1.5),
		})
		tween(card.pop, POP, { Scale = selected and 1.02 or 1 })
		card.check.Visible = selected
		if selected then
			card.actionText.Text = "YOUR SIDE"
			tween(card.action, QUICK, { BackgroundColor3 = card.color, BackgroundTransparency = 0 })
			card.actionText.TextColor3 = INK
		elseif full then
			card.actionText.Text = "FULL"
			tween(card.action, QUICK, { BackgroundColor3 = Role.SurfaceAlt, BackgroundTransparency = 0 })
			card.actionText.TextColor3 = Role.TextMuted
		else
			card.actionText.Text = "JOIN"
			tween(card.action, QUICK, { BackgroundColor3 = card.color, BackgroundTransparency = focused and 0.55 or 0.78 })
			card.actionText.TextColor3 = card.color:Lerp(Color3.new(1, 1, 1), 0.35)
		end
		card.keycap.Visible = self.input ~= "touch" and (self.input ~= "gamepad" or focused) and not selected
		card.button.BackgroundColor3 = (self.hover == team) and Role.SurfaceAlt or Role.Surface
	end
	local onAuto = mine == 0
	local autoFocused = self.focus == 0
	tween(self.auto, QUICK, { BackgroundColor3 = onAuto and Role.Accent or (autoFocused and Role.SurfaceAlt or Role.Surface) })
	self.autoText.TextColor3 = onAuto and Role.AccentInk or Role.Accent
	self.autoStroke.Color = autoFocused and Role.Text or Role.Accent
	self.autoStroke.Thickness = autoFocused and 2 or 1.5
	local side = snap.autoSide and GameModes.Team(snap.autoSide)
	if self.compact then
		self.autoText.Text = "AUTO"
	else
		self.autoText.Text = (onAuto and side) and ("AUTO  ·  " .. (side.short or side.name)) or "AUTO-ASSIGN"
	end
	self.autoKey.Visible = self.input ~= "touch"
end

function TeamPickerScreen:Render(snap)
	self.snapshot = snap
	-- The server has answered what was tapped: its answer is the truth from here.
	if self.pending ~= nil and snap.mine == self.pending then
		self.pending = nil
	elseif self.pending ~= nil and snap.refused then
		self.pending = nil
	end
	if not self.cards then
		return
	end
	local mode = snap.mode and GameModes.Get(snap.mode)
	if not self.flashUntil or tick() > self.flashUntil then
		local sizeText = ""
		if snap.teams and snap.teams[1] and snap.teams[1].bots + snap.teams[2].bots > 0 then
			sizeText = string.format("  ·  bots fill each side to %d", math.max(snap.teams[1].size, snap.teams[2].size))
		end
		if self.compact then
			self.sub.Text = string.format("%s  ·  %d undecided", mode and mode.short or "TEAMS", snap.undecided or 0)
		else
			self.sub.Text = string.format("%s  ·  %d player%s%s", mode and mode.name or "Team match", snap.humans or 0,
				snap.humans == 1 and "" or "s", sizeText)
		end
		self.sub.TextColor3 = Role.TextMuted
	end
	for team, card in pairs(self.cards) do
		local info = snap.teams and snap.teams[team] or {}
		if card.bots then
			card.count.Text = string.format("%d / %d PLAYERS", info.picked or 0, snap.cap or 0)
		else
			card.count.Text = string.format("%d/%d  ·  +%d bots", info.picked or 0, snap.cap or 0, info.bots or 0)
		end
		local roster = info.roster or {}
		local more = (info.more or 0)
		for i, row in ipairs(card.rows) do
			local entry = roster[i]
			local overflow = (i == #card.rows) and (#roster > #card.rows or more > 0)
			if overflow then
				local extra = math.max(#roster - #card.rows + 1, 1) + more
				row.label.Text = string.format("+%d more", extra)
				row.label.Font = Type.Label.Font
				row.label.TextColor3 = Role.TextMuted
				row.dot.Visible = false
			elseif entry then
				row.label.Text = entry.me and (entry.name .. "  (you)") or entry.name
				row.label.Font = entry.me and Type.Label.Font or Type.Body.Font
				row.label.TextColor3 = entry.me and Role.Accent or Role.Text
				row.dot.Visible = true
			elseif i == 1 then
				row.label.Text = "Nobody yet"
				row.label.Font = Type.Body.Font
				row.label.TextColor3 = Role.TextMuted
				row.dot.Visible = false
			else
				row.label.Text = ""
				row.dot.Visible = false
			end
		end
		local bots = info.bots or 0
		if not card.bots then
			card.count.TextTransparency = 0.1
		else
			card.bots.Text = bots > 0 and string.format("+ %d bot%s  ·  side of %d", bots, bots == 1 and "" or "s", info.size or 0)
				or string.format("No bots  ·  side of %d", info.size or 0)
		end
	end
	local undecided = snap.undecided or 0
	if undecided > 0 then
		self.note.Text = string.format("%d undecided. Anyone left is balanced when the timer ends.", undecided)
	else
		self.note.Text = "Everyone has picked. Starting in a moment."
	end
	if snap.refused and self.lastAsk and self.lastAsk ~= 0 then
		self:Refused(self.lastAsk, snap.refused)
	end
	self.lastAsk = nil
	self:Countdown(snap.secondsLeft or 0, snap.seconds or 12)
	self:_paint()
end

-- The seconds, and the bar draining to empty in step with them.
function TeamPickerScreen:Countdown(secondsLeft, total)
	if not self.timerText then
		return
	end
	local shown = math.max(0, math.ceil(secondsLeft))
	self.timerText.Text = tostring(shown)
	local urgent = shown <= 3
	self.timerText.TextColor3 = urgent and Role.Negative or Role.Text
	self.bar.BackgroundColor3 = urgent and Role.Negative or Role.Accent
	local fraction = math.clamp(secondsLeft / math.max(total, 1), 0, 1)
	self.bar.Size = UDim2.fromScale(fraction, 1)
	tween(self.bar, TweenInfo.new(math.max(secondsLeft, 0), Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) })
end

-- A side that could not be joined: the card shakes and the line under the title says why.
function TeamPickerScreen:Refused(team, reason)
	local card = self.cards and self.cards[team]
	if not card then
		return
	end
	local other = GameModes.OtherTeam(team)
	self.sub.Text = reason == "full"
		and string.format("%s is full. Pick %s, or AUTO.", GameModes.TeamName(team), GameModes.TeamName(other))
		or "That pick didn't go through. Try again."
	self.sub.TextColor3 = Role.Negative
	self.flashUntil = tick() + 2.5
	local home = card.home
	local step = self:px(6)
	task.spawn(function()
		for _, dx in ipairs({ step, -step, step * 0.6, -step * 0.6, 0 }) do
			tween(card.button, TweenInfo.new(0.05), { Position = home + UDim2.fromOffset(dx, 0) })
			task.wait(0.05)
		end
		card.button.Position = home
	end)
end

function TeamPickerScreen:Show()
	if not self.panel then
		return
	end
	local already = self.shown
	self.shown = true
	self.panel.Visible = true
	if not already then
		local home = self.panel.Position
		self.panelScale.Scale = 0.96
		self.panel.Position = home + UDim2.fromOffset(0, self:px(10))
		tween(self.panelScale, POP, { Scale = 1 })
		tween(self.panel, FADE, { Position = home })
	end
end

function TeamPickerScreen:Hide()
	self.shown = false
	self.pending = nil
	self.focus = nil
	if self.panel then
		self.panel.Visible = false
	end
end

-- What a gamepad should start on: your side, else AUTO.
function TeamPickerScreen:FocusTarget()
	if not self.cards then
		return nil
	end
	local mine = self:Mine()
	return (mine == 1 or mine == 2) and self.cards[mine].button or self.auto
end

return TeamPickerScreen
