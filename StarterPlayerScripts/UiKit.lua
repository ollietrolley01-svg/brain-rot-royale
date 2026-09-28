-- Shared UI helpers for the client scripts. ModuleScript, not a LocalScript.

local UiKit = {}

UiKit.Colors = {
	Background = Color3.fromRGB(20, 22, 30),
	Panel = Color3.fromRGB(32, 35, 46),
	PanelAlt = Color3.fromRGB(42, 46, 60),
	Accent = Color3.fromRGB(255, 184, 48),
	Green = Color3.fromRGB(94, 214, 122),
	Red = Color3.fromRGB(232, 92, 92),
	Storm = Color3.fromRGB(158, 132, 255),
	Text = Color3.fromRGB(240, 242, 248),
	Muted = Color3.fromRGB(146, 152, 170),
}

--------------------------------------------------------------------------------
-- Design tokens
--
-- The interface grew one panel at a time and ended up with 7 fonts, 24 text sizes, 20 corner radii
-- and 14 tween durations (counted by tools/menu_hud_audit.py). These are the values everything is
-- being moved onto, one section at a time. Nothing reads them until a section is converted, so
-- adding them changes nothing on screen.
--
-- `Colors` above stays as the old names; `Role` is the same palette said once, plus the roles it
-- was missing. New work uses Role.
--------------------------------------------------------------------------------

UiKit.Role = {
	Scrim = Color3.fromRGB(8, 9, 13),
	Base = UiKit.Colors.Background,
	Surface = UiKit.Colors.Panel,
	SurfaceAlt = UiKit.Colors.PanelAlt,
	Line = Color3.fromRGB(58, 63, 78),
	Text = UiKit.Colors.Text,
	TextMuted = UiKit.Colors.Muted,
	Accent = UiKit.Colors.Accent,
	-- What goes ON accent: near-black, so accent buttons keep their contrast.
	AccentInk = Color3.fromRGB(28, 20, 0),
	Positive = UiKit.Colors.Green,
	Negative = UiKit.Colors.Red,
	Storm = UiKit.Colors.Storm,
	Info = Color3.fromRGB(86, 200, 255),
}

-- Six steps. Nothing below 14 carries meaning on its own; Caption is for a line sitting next to
-- something bigger that already says what it is.
UiKit.Type = {
	Display = { Size = 34, Font = Enum.Font.FredokaOne },
	Title = { Size = 26, Font = Enum.Font.FredokaOne },
	Heading = { Size = 20, Font = Enum.Font.GothamBold },
	Body = { Size = 16, Font = Enum.Font.Gotham },
	Label = { Size = 14, Font = Enum.Font.GothamBold },
	Caption = { Size = 12, Font = Enum.Font.Gotham },
}

UiKit.Space = { XS = 4, SM = 8, MD = 12, LG = 16, XL = 24, XXL = 32 }
UiKit.Radius = { Control = 8, Card = 12, Panel = 16, Pill = 999 }
UiKit.Stroke = { Hairline = 1, Focus = 2 }
-- Quad Out for everything; Back Out only where something is meant to feel like a prize.
UiKit.Motion = { Press = 0.12, Fade = 0.18, Panel = 0.28, Celebrate = 0.45 }
-- The smallest anything tappable may be, on any device.
UiKit.Touch = 44

-- Where the bottom row of the HUD sits, in raw unscaled pixels from the screen edges. StaminaBar
-- worked these out by reading HudClient and kept its own copies; they live here now so the bar,
-- the hotbar and anything else placed along the bottom read one set of numbers. Change these when
-- the revamp moves the health panel or the hotbar, and everything that reads them follows.
UiKit.BottomRow = {
	-- Bottom-left: the health panel's right edge, and the top of the stack above it (companion
	-- panel, then the speed-boost pill).
	HealthRight = 296,
	LeftStackTop = 202,
	-- Bottom-right: how far in from the right edge the hotbar starts.
	HotbarInset = 706,
	-- The clear space to leave between two things along this row.
	Gap = 12,
}

-- WHICH VERSION OF THE INTERFACE A SCREEN GETS. One function; nothing else may decide this.
--
-- Oliver, after seeing the gallery: "the menu and hud in the gallary here looks good but doesnt sem
-- to work for smaller screens and vertical screens, make seperate versions for them."
--
-- The boundary is not how BIG a screen is, it is WHICH DIMENSION HAS RUN OUT, because that is what
-- decides the design:
--
--   large   nothing is scarce                   rail on the left, 2-3 columns
--   short   HEIGHT has run out                  landscape phone: 780 px wide, 208 px tall
--   tall    WIDTH has run out                   portrait phone: 296-350 px of content
--
-- Named for the dimension, not the device. "small" and "vertical" were the other candidates and
-- were rejected for a concrete reason: a portrait TABLET is upright and is `large`, so a name
-- containing "vertical" would be a lie at the one boundary people get wrong.
--
-- Which is why `short` puts navigation in a 64-wide ICON RAIL and `tall` puts it in a bottom
-- bar. On an 844x390 phone a bottom bar costs 68 px out of a 260 px panel; a rail spends width,
-- which that shape has 716 px of, and buys height, which it has none of — content height goes from
-- 128 to 208. A bottom bar is right on a portrait phone and wrong on a landscape one, and no rule
-- based on size alone could say that.
--
-- THE NUMBERS ARE MEASURED. Do not move them on instinct; re-measure and change this comment.
--
--   600 of panel width: below it a two-column grid stops fitting, since a card needs ~260 plus a
--   12 px gutter and the panel spends 24 on its own padding.
--
--   500 of viewport height, and the reason is NOT the one you would guess. Measured after layout by
--   claude-a4's probe, the large Rank page needs 476 px of content before PRESTIGE is reachable
--   without scrolling (Index 115, Shop 78, Mastery 70). Content is roughly viewport.Y − 232 on a
--   touch screen, so the LARGE Rank page does not fit above the fold until about 708 — and the
--   threshold is still 500, deliberately.
--
--   500 works BECAUSE the short version exists: the short Rank page puts PRESTIGE inside the hero
--   card, where the lifetime numbers used to be, at about 156 px — well inside the 208 px of list
--   an 844x390 phone actually has. (An earlier draft put it at ~250, which would have been 42 px
--   below the fold on the very screen the short version exists for.) Raising this number to 708
--   would send most laptops to the
--   short version to fix a page that the short version already fixes. If someone later measures the
--   large Rank page and concludes this boundary is too low, that is the mistake they are making.
--
-- NOT THE SAME QUESTION AS PhoneLayout.Mode, and the names are deliberately different so nobody
-- mistakes them for each other. That one answers "what DEVICE is this" — it requires touch, and it
-- calls any upright touch screen "vertical" because Roblox owns the lower half of one whatever its
-- size. This answers "what SHAPE is this screen": a portrait TABLET is a touch device and an
-- upright one, and it is still `large` here, because 728 px of panel is not a small screen. Both
-- are right for what they decide; they return different words on purpose. The only place they could
-- disagree in a way that matters is how big a tappable thing must be, and that is 44 px everywhere
-- regardless, so it cannot bite. Do NOT unify them: one question would answer neither.
--
-- `contentWidth` is optional, for a caller drawing into a container rather than a whole panel.
function UiKit.form(viewport, contentWidth)
	local width = contentWidth
	if not width then
		local safe = UiKit.safeArea(viewport, true)
		width = math.clamp(viewport.X - safe.Left - safe.Right, 320, 1180)
	end
	if width < 600 then
		return "tall"
	elseif viewport.Y < 500 then
		return "short"
	end
	return "large"
end

-- What to keep clear: Roblox's top bar, and room for thumbs on a touch screen.
function UiKit.safeArea(viewport, touch)
	local safe = {
		Top = 52 + UiKit.Space.SM,
		Bottom = touch and 96 or UiKit.Space.LG,
		Left = touch and 20 or UiKit.Space.LG,
		Right = touch and 20 or UiKit.Space.LG,
	}
	-- A TV crops its edges (overscan) and Roblox leaves that to the game: on a console, nothing of the
	-- menu, the vote or the drop map sits in the outer 5% (Jacob's device-compat question 5). Everywhere
	-- else this table is exactly what it always was.
	if viewport and UiKit.tenFoot() then
		safe.Left = math.max(safe.Left, math.floor(viewport.X * UiKit.TvSafe.Side + 0.5))
		safe.Right = math.max(safe.Right, math.floor(viewport.X * UiKit.TvSafe.Side + 0.5))
		safe.Top = math.max(safe.Top, math.floor(viewport.Y * UiKit.TvSafe.TopBottom + 0.5))
		safe.Bottom = math.max(safe.Bottom, math.floor(viewport.Y * UiKit.TvSafe.TopBottom + 0.5))
	end
	return safe
end

--------------------------------------------------------------------------------
-- THE TV-SAFE AREA (console only)
--
-- Roblox's console guidelines leave overscan to the game, and a TV can crop up to ~5% of each edge. On a
-- console (GuiService:IsTenFootInterface()) the HUD's edge pieces go in a frame inset 5% each side --
-- 96 px left and right, 54 px top and bottom at 1920x1080 -- and the menus' safe area (above) grows to
-- the same margin. Desktop, phone and tablet never see any of it: tvSafeRoot hands back the ScreenGui
-- itself, so their layouts are byte-for-byte what they were (tools/device_compat_check.py measures both).
--------------------------------------------------------------------------------

UiKit.TvSafe = { Side = 0.05, TopBottom = 0.05, FrameName = "TvSafeArea" }

-- TEST SEAM: true / false forces the answer (galleries and checks); nil asks the engine.
UiKit.TenFootForTest = nil

function UiKit.tenFoot()
	if UiKit.TenFootForTest ~= nil then
		return UiKit.TenFootForTest == true
	end
	local ok, tenFoot = pcall(function()
		return game:GetService("GuiService"):IsTenFootInterface()
	end)
	return ok and tenFoot == true
end

-- The room a layout function has inside that frame: the viewport less the margin on a console, the
-- viewport itself (the same value) anywhere else.
function UiKit.tvSafeSize(viewport)
	if not UiKit.tenFoot() then
		return viewport
	end
	return Vector2.new(viewport.X * (1 - 2 * UiKit.TvSafe.Side), viewport.Y * (1 - 2 * UiKit.TvSafe.TopBottom))
end

-- Where a ScreenGui's EDGE pieces are parented: on a console, a transparent frame inset by the TV-safe
-- margin (made once per ScreenGui); anywhere else the ScreenGui itself. Full-screen overlays and the
-- centred pieces stay on the ScreenGui. Anything that turns an absolute position into an offset for a
-- piece in here measures from this frame, not the ScreenGui.
function UiKit.tvSafeRoot(screenGui)
	if not UiKit.tenFoot() then
		return screenGui
	end
	local existing = screenGui:FindFirstChild(UiKit.TvSafe.FrameName)
	if existing then
		return existing
	end
	return UiKit.create("Frame", {
		Name = UiKit.TvSafe.FrameName,
		Position = UDim2.fromScale(UiKit.TvSafe.Side, UiKit.TvSafe.TopBottom),
		Size = UDim2.fromScale(1 - 2 * UiKit.TvSafe.Side, 1 - 2 * UiKit.TvSafe.TopBottom),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = screenGui,
	})
end

-- A panel that fills a phone inside its safe area, and is a share of a bigger screen without ever
-- growing past the width text still reads well at.
function UiKit.panelSize(viewport, touch)
	local safe = UiKit.safeArea(viewport, touch)
	local width = math.clamp(viewport.X - safe.Left - safe.Right, 320, 1180)
	local height = math.clamp(viewport.Y - safe.Top - safe.Bottom, 260, 760)
	if UiKit.form(viewport) ~= "tall" then
		width = math.min(width, math.max(720, viewport.X * 0.86))
		height = math.min(height, math.max(420, viewport.Y * 0.86))
	end
	return Vector2.new(math.floor(width), math.floor(height))
end

-- A TEXT WIDTH THAT CANNOT COME OUT NEGATIVE.
--
-- `UDim2.new(1, -N, ...)` where N exceeds the parent's width does NOT truncate the text. Roblox
-- draws nothing at all, so the row comes up blank with no sign of what happened -- invisible in
-- review, invisible in any landscape test, and only reachable at all once the menu's `tall` form
-- started running. Five labels in MenuClient were one viewport away from going blank on a portrait
-- phone, and the crate odds line and the progression rows had already vanished this way at 296 px.
--
-- Below the width where the reserve stops fitting, THE RESERVE IS GIVEN UP RATHER THAN THE TEXT,
-- because the text is what the player came to read. `MIN` is what a label keeps whatever else has
-- to give; a caller wanting a different floor passes one.
--
-- Pure, and it lives here rather than in MenuClient for the reason the shell's viewport wiring
-- does: MenuClient is a LocalScript and nothing in the harness can run one, so logic written there
-- is logic no probe can ever check. Here it is one require away.
function UiKit.textSpan(width, reservePx, height, minimum)
	local floor = minimum or 64
	local capped = math.min(reservePx, math.max(0, (width or 0) - floor))
	return UDim2.new(1, -capped, 0, height)
end

function UiKit.create(className, props, children)
	local instance = Instance.new(className)
	local parent = props and props.Parent

	for key, value in pairs(props or {}) do
		if key ~= "Parent" then
			instance[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = instance
	end
	if parent then
		instance.Parent = parent
	end

	return instance
end

function UiKit.rounded(radius)
	return UiKit.create("UICorner", { CornerRadius = UDim.new(0, radius or 10) })
end

function UiKit.padding(px)
	return UiKit.create("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	})
end

function UiKit.formatNumber(value)
	value = math.floor(value or 0)
	local suffixes = { "", "K", "M", "B", "T" }
	local index, scaled = 1, value

	while scaled >= 1000 and index < #suffixes do
		scaled /= 1000
		index += 1
	end

	if index == 1 then
		return tostring(value)
	end
	return string.format("%.1f%s", scaled, suffixes[index])
end

-- Clears a layout container but keeps its UIListLayout/UIGridLayout intact.
function UiKit.clearItems(container)
	for _, child in ipairs(container:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIGridLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

return UiKit
