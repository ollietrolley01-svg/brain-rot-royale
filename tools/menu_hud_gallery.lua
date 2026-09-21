-- Menu and HUD revamp gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/menu_hud_gallery.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- Phase 1 evidence for the revamp: what the menu and HUD look like now, and what the proposal
-- would replace them with, at every size the game has to work on.
--
--   current    the menu shell exactly as MenuClient builds it (760x480 fixed panel, 85x34 tabs,
--              64 px rows, 94x38 buttons) drawn on each screen, with the HUD clusters outlined
--              where HudClient puts them
--   proposed   the same screens under the proposed system: responsive panel, rail or bottom bar,
--              44 px targets, the six-step type scale
--   tokens     the design system on one sheet: palette, type scale, spacing, radii, motion
--   parts      current vs proposed side by side for the pieces used everywhere: row, button,
--              tab, header, empty state
--
-- The numbers under `Current` are read out of MenuClient/HudClient by tools/menu_hud_audit.py; if
-- they change there, rerun the audit and update them here.

local ONLY = nil

local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(Scripts:WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local GUI_NAME = "BRR_MenuHudGallery"

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local views = {}
local function add(section, view)
	if ONLY == nil or ONLY == section or (type(ONLY) == "table" and ONLY[section]) then
		table.insert(views, view)
	end
end

-- `mode` is what PhoneLayout.Mode would answer on a real device of that kind. Studio is a desktop with
-- a keyboard, so the modules would call every one of these a desktop; the shell section sets
-- PhoneLayout.Force (that module's own test hook) around each render so the real code takes the real
-- branch for the screen being drawn.
local SCREENS = {
	{ name = "1920x1080", size = Vector2.new(1920, 1080), touch = false, mode = "desktop" },
	{ name = "1366x768", size = Vector2.new(1366, 768), touch = false, mode = "desktop" },
	{ name = "1280x720", size = Vector2.new(1280, 720), touch = false, mode = "desktop" },
	{ name = "tablet_1024x768", size = Vector2.new(1024, 768), touch = true, mode = "tablet" },
	{ name = "phone_844x390", size = Vector2.new(844, 390), touch = true, mode = "phone" },
	-- Portrait. Nothing sets ScreenOrientation, so a player can rotate into these today, and they
	-- are where fixed negative offsets stop working: the content area is 296-311 px, not 780.
	{ name = "portrait_375x667", size = Vector2.new(375, 667), touch = true, mode = "phone" },
	{ name = "portrait_320x568", size = Vector2.new(320, 568), touch = true, mode = "phone" },
}

--------------------------------------------------------------------------------
-- The proposed design system
--------------------------------------------------------------------------------

local T = {}

T.color = {
	scrim = Color3.fromRGB(8, 9, 13),
	base = Color3.fromRGB(20, 22, 30),
	surface = Color3.fromRGB(34, 37, 47),
	surfaceAlt = Color3.fromRGB(44, 48, 61),
	line = Color3.fromRGB(58, 63, 78),
	text = Color3.fromRGB(242, 244, 248),
	textMuted = Color3.fromRGB(153, 160, 178),
	accent = Color3.fromRGB(255, 184, 48),
	accentInk = Color3.fromRGB(28, 20, 0),
	positive = Color3.fromRGB(94, 214, 122),
	negative = Color3.fromRGB(232, 92, 92),
	storm = Color3.fromRGB(158, 132, 255),
	info = Color3.fromRGB(86, 200, 255),
}

-- Six steps, and nothing below 14 that carries meaning on its own.
T.type = {
	display = { size = 34, font = Enum.Font.FredokaOne },
	title = { size = 26, font = Enum.Font.FredokaOne },
	heading = { size = 20, font = Enum.Font.GothamBold },
	body = { size = 16, font = Enum.Font.Gotham },
	label = { size = 14, font = Enum.Font.GothamBold },
	caption = { size = 12, font = Enum.Font.Gotham },
}

T.space = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32 }
T.radius = { control = 8, card = 12, panel = 16, pill = 999 }
T.stroke = { hairline = 1, focus = 2 }
T.motion = { press = 0.12, fade = 0.18, panel = 0.28, celebrate = 0.45 }
T.touch = 44

-- Breakpoints: one rule the whole interface follows.
function T.breakpoint(viewport)
	if viewport.X < 900 or viewport.Y < 460 then
		return "phone"
	elseif viewport.X < 1280 then
		return "tablet"
	end
	return "desktop"
end

function T.safeArea(viewport, touch)
	local top = 52 + T.space.sm
	local bottom = touch and 96 or T.space.lg
	local side = touch and 20 or T.space.lg
	return { top = top, bottom = bottom, left = side, right = side }
end

-- The menu panel: a share of the screen, never bigger than it reads well at, never smaller than
-- its content needs. On a phone it fills the screen inside the safe area.
function T.panelSize(viewport, touch)
	local safe = T.safeArea(viewport, touch)
	local width = math.clamp(viewport.X - safe.left - safe.right, 320, 1180)
	local height = math.clamp(viewport.Y - safe.top - safe.bottom, 260, 760)
	if T.breakpoint(viewport) ~= "phone" then
		width = math.min(width, math.max(720, viewport.X * 0.86))
		height = math.min(height, math.max(420, viewport.Y * 0.86))
	end
	return Vector2.new(math.floor(width), math.floor(height))
end

local function text(parent, style, value, color, props)
	local label = create("TextLabel", {
		BackgroundTransparency = 1,
		Font = style.font,
		Text = value,
		TextColor3 = color or T.color.text,
		TextSize = style.size,
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
-- Screens: a mock device screen, scaled to fit the viewport, over sky and grass
--------------------------------------------------------------------------------

local Mock = {}

function Mock.clear()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
end

function Mock.gui()
	Mock.clear()
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.Parent = StarterGui
	return gui
end

function Mock.sky(camera)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
end

function Mock.screen(gui, camera, spec, caption)
	local viewport = camera.ViewportSize
	local fit = math.min(viewport.X * 0.94 / spec.size.X, viewport.Y * 0.88 / spec.size.Y)
	local screen = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(spec.size.X, spec.size.Y),
		BackgroundColor3 = Color3.fromRGB(118, 160, 196),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = gui,
	})
	create("UIScale", { Scale = fit, Parent = screen })
	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 196, 236)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(214, 226, 232)),
			ColorSequenceKeypoint.new(0.56, Color3.fromRGB(104, 150, 82)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(78, 118, 60)),
		}),
		Parent = screen,
	})
	-- Roblox's own top bar, which every layout has to keep clear of.
	create("Frame", {
		Size = UDim2.new(0, 220, 0, 52),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Parent = screen,
	})
	create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -20, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("%s   %s", spec.name, caption or ""),
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.4,
		TextSize = 16,
		Parent = screen,
	})
	return screen
end

-- A labelled box where a HUD cluster sits, so a menu render still shows what it covers.
function Mock.outline(parent, position, size, anchor, label, color)
	local frame = create("Frame", {
		AnchorPoint = anchor or Vector2.zero,
		Position = position,
		Size = size,
		BackgroundColor3 = T.color.base,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Parent = parent,
	}, { rounded(10) })
	create("UIStroke", { Color = color or Color3.fromRGB(120, 124, 140), Thickness = 1, Parent = frame })
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = label,
		TextColor3 = color or Color3.fromRGB(170, 174, 190),
		TextSize = 12,
		TextWrapped = true,
		Parent = frame,
	})
	return frame
end

--------------------------------------------------------------------------------
-- The menu as it is now (MenuClient's own numbers)
--------------------------------------------------------------------------------

local Current = {
	panel = Vector2.new(760, 480),
	tab = Vector2.new(85, 34),
	tabGap = 6,
	tabs = { "BRAINROTS", "TRADE", "CRATES", "COSMETICS", "PASS", "QUESTS", "SHOP", "SETTINGS" },
	row = 64,
	rowGap = 8,
	button = Vector2.new(94, 38),
	coinChip = Vector2.new(210, 44),
	menuButton = Vector2.new(210, 42),
}

local C = UiKit.Colors

local function currentMenu(screen, spec)
	-- The coin chip and the left stack, at MenuClient's fixed offsets (inside the top-bar inset).
	Mock.outline(screen, UDim2.new(0, 16, 0, 58 + 78), UDim2.fromOffset(Current.coinChip.X, Current.coinChip.Y), nil, "COINS")
	Mock.outline(screen, UDim2.new(0, 16, 0, 58 + 130), UDim2.fromOffset(Current.menuButton.X, Current.menuButton.Y), nil, "MENU [M]")
	Mock.outline(screen, UDim2.new(0, 16, 0, 58 + 180), UDim2.fromOffset(210, 34), nil, "BUNDLE")
	Mock.outline(screen, UDim2.new(0, 16, 0, 58 + 224), UDim2.fromOffset(250, 128), nil, "DAILY QUESTS")

	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(Current.panel.X, Current.panel.Y),
		BackgroundColor3 = C.Background,
		BorderSizePixel = 0,
		Parent = screen,
	}, { rounded(14) })

	create("TextLabel", {
		Position = UDim2.new(0, 20, 0, 14),
		Size = UDim2.fromOffset(300, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "BRAIN ROT ROYALE",
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 22,
		Parent = panel,
	})
	create("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = "X",
		TextColor3 = C.Muted,
		TextSize = 16,
		Parent = panel,
	}, { rounded(8) })

	local strip = create("Frame", {
		Position = UDim2.new(0, 16, 0, 52),
		Size = UDim2.new(1, -32, 0, 38),
		BackgroundTransparency = 1,
		Parent = panel,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Current.tabGap),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, label in ipairs(Current.tabs) do
		local selected = index == 1
		create("TextButton", {
			Size = UDim2.fromOffset(Current.tab.X, Current.tab.Y),
			BackgroundColor3 = selected and C.Accent or C.Panel,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			Text = label,
			TextColor3 = selected and Color3.new(0, 0, 0) or C.Muted,
			TextSize = 14,
			LayoutOrder = index,
			Parent = strip,
		}, { rounded(8) })
	end

	local content = create("Frame", {
		Position = UDim2.new(0, 16, 0, 98),
		Size = UDim2.new(1, -32, 1, -114),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Parent = panel,
	}, { create("UIListLayout", { Padding = UDim.new(0, Current.rowGap), SortOrder = Enum.SortOrder.LayoutOrder }) })

	local rows = {
		{ "Tralalero Tralala", "Legendary  •  x3  •  1,200 coins each", C.Accent },
		{ "Bombardiro Crocodilo", "Epic  •  x1  •  600 coins", Color3.fromRGB(190, 120, 255) },
		{ "Patatina Fritta", "Common  •  x12  •  60 coins", C.Text },
		{ "Cappuccina Ballerina", "Rare  •  x2  •  300 coins", Color3.fromRGB(90, 170, 255) },
		{ "Sahur Bros", "Uncommon  •  x7  •  120 coins", C.Green },
	}
	for index, row in ipairs(rows) do
		local frame = create("Frame", {
			Size = UDim2.new(1, -8, 0, Current.row),
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = content,
		}, { rounded(10) })
		create("TextLabel", {
			Position = UDim2.new(0, 14, 0, 10),
			Size = UDim2.new(1, -320, 0, 22),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = row[1],
			TextColor3 = row[3],
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 16,
			Parent = frame,
		})
		create("TextLabel", {
			Position = UDim2.new(0, 14, 0, 32),
			Size = UDim2.new(1, -320, 0, 20),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = row[2],
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 13,
			Parent = frame,
		})
		local buttons = create("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(300, 38),
			BackgroundTransparency = 1,
			Parent = frame,
		}, {
			create("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		for order, spec2 in ipairs({ { "EQUIP", C.Green }, { "MERGE", C.Accent }, { "SELL", C.Red } }) do
			create("TextButton", {
				Size = UDim2.fromOffset(Current.button.X, Current.button.Y),
				BackgroundColor3 = spec2[2],
				BorderSizePixel = 0,
				Font = Enum.Font.GothamBold,
				Text = spec2[1],
				TextColor3 = Color3.new(0, 0, 0),
				TextSize = 13,
				LayoutOrder = order,
				Parent = buttons,
			}, { rounded(8) })
		end
	end
	return panel
end

--------------------------------------------------------------------------------
-- The menu as proposed
--------------------------------------------------------------------------------

local DESTINATIONS = {
	{ key = "collection", label = "COLLECTION", glyph = "★", sub = "Brainrots · Trading" },
	{ key = "crates", label = "CRATES", glyph = "▣", sub = "Open · Buy" },
	{ key = "style", label = "STYLE", glyph = "◆", sub = "Skins · Auras · Parachutes" },
	{ key = "progress", label = "PROGRESS", glyph = "▲", sub = "Pass · Quests · Ranks" },
	{ key = "shop", label = "SHOP", glyph = "＄", sub = "Robux" },
}

local function pill(parent, label, color, ink, width, height, order)
	local button = create("TextButton", {
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Font = T.type.label.font,
		Text = label,
		TextColor3 = ink,
		TextSize = T.type.label.size,
		LayoutOrder = order or 1,
		AutoButtonColor = true,
		Parent = parent,
	}, { rounded(T.radius.control) })
	return button
end

local function proposedMenu(screen, spec)
	local phone = T.breakpoint(spec.size) == "phone"
	local safe = T.safeArea(spec.size, spec.touch)
	local size = T.panelSize(spec.size, spec.touch)

	create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = T.color.scrim,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = screen,
	})

	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, math.floor((safe.top - safe.bottom) / 2)),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = T.color.base,
		BorderSizePixel = 0,
		Parent = screen,
	}, { rounded(T.radius.panel) })
	create("UIStroke", { Color = T.color.line, Thickness = T.stroke.hairline, Parent = panel })

	local railWidth = phone and 0 or (spec.size.X < 1280 and 168 or 208)
	local headerHeight = phone and 52 or 64

	-- Header: identity, wallet, settings, close. One row, same on every size.
	local header = create("Frame", {
		Size = UDim2.new(1, 0, 0, headerHeight),
		BackgroundTransparency = 1,
		Parent = panel,
	}, { UiKit.padding(T.space.lg) })
	text(header, phone and T.type.heading or T.type.title, "BRAIN ROT ROYALE", T.color.text, {
		Size = UDim2.new(1, -260, 1, 0),
	})
	local wallet = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(T.touch * 2 + T.space.sm * 2), 0.5, 0),
		Size = UDim2.fromOffset(phone and 132 or 168, T.touch),
		BackgroundColor3 = T.color.surface,
		BorderSizePixel = 0,
		Parent = header,
	}, { rounded(T.radius.pill) })
	create("Frame", {
		Position = UDim2.new(0, 6, 0.5, -11),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = T.color.accent,
		BorderSizePixel = 0,
		Parent = wallet,
	}, { rounded(T.radius.pill) })
	text(wallet, T.type.heading, "12.4K", T.color.accent, {
		Position = UDim2.new(0, 34, 0, 0),
		Size = UDim2.new(1, -40, 1, 0),
	})
	for index, glyph in ipairs({ "⚙", "✕" }) do
		local button = pill(header, glyph, T.color.surface, T.color.textMuted, T.touch, T.touch, index)
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -((2 - index) * (T.touch + T.space.sm)), 0.5, 0)
		button.TextSize = T.type.heading.size
	end

	-- Navigation: a rail on desktop and tablet, a bottom bar on a phone.
	local bodyTop = headerHeight
	local bodyBottom = phone and (T.touch + T.space.md * 2) or 0
	if phone then
		local bar = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, bodyBottom),
			BackgroundColor3 = T.color.surface,
			BorderSizePixel = 0,
			Parent = panel,
		}, { rounded(T.radius.panel), UiKit.padding(T.space.md) })
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, T.space.sm),
			Parent = bar,
		})
		for index, destination in ipairs(DESTINATIONS) do
			local selected = index == 1
			local cell = create("TextButton", {
				Size = UDim2.fromOffset(math.floor((size.X - T.space.md * 2 - T.space.sm * 4) / 5), T.touch),
				BackgroundColor3 = selected and T.color.accent or T.color.surfaceAlt,
				BorderSizePixel = 0,
				Text = "",
				LayoutOrder = index,
				Parent = bar,
			}, { rounded(T.radius.control) })
			text(cell, T.type.label, destination.glyph .. "  " .. destination.label, selected and T.color.accentInk or T.color.textMuted, {
				Size = UDim2.fromScale(1, 1),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextSize = 12,
			})
		end
	else
		local rail = create("Frame", {
			Position = UDim2.new(0, 0, 0, bodyTop),
			Size = UDim2.new(0, railWidth, 1, -bodyTop),
			BackgroundTransparency = 1,
			Parent = panel,
		}, { UiKit.padding(T.space.lg) })
		create("UIListLayout", { Padding = UDim.new(0, T.space.sm), SortOrder = Enum.SortOrder.LayoutOrder, Parent = rail })
		for index, destination in ipairs(DESTINATIONS) do
			local selected = index == 1
			local cell = create("TextButton", {
				Size = UDim2.new(1, 0, 0, 56),
				BackgroundColor3 = selected and T.color.accent or T.color.surface,
				BorderSizePixel = 0,
				Text = "",
				LayoutOrder = index,
				Parent = rail,
			}, { rounded(T.radius.card) })
			text(cell, T.type.heading, destination.glyph, selected and T.color.accentInk or T.color.textMuted, {
				Position = UDim2.fromOffset(12, 0),
				Size = UDim2.fromOffset(24, 56),
				TextXAlignment = Enum.TextXAlignment.Center,
			})
			text(cell, T.type.label, destination.label, selected and T.color.accentInk or T.color.text, {
				Position = UDim2.fromOffset(44, 8),
				Size = UDim2.new(1, -52, 0, 20),
			})
			text(cell, T.type.caption, destination.sub, selected and T.color.accentInk or T.color.textMuted, {
				Position = UDim2.fromOffset(44, 28),
				Size = UDim2.new(1, -52, 0, 18),
				TextTransparency = selected and 0.25 or 0,
			})
		end
	end

	-- Content: cards on a grid that reflows by width, not a single fixed-width column.
	local content = create("Frame", {
		Position = UDim2.new(0, railWidth, 0, bodyTop),
		Size = UDim2.new(1, -railWidth, 1, -bodyTop - bodyBottom),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Parent = panel,
	}, { UiKit.padding(T.space.lg) })

	local filterRow = create("Frame", {
		Size = UDim2.new(1, 0, 0, T.touch),
		BackgroundTransparency = 1,
		Parent = content,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, T.space.sm),
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, filter in ipairs({ "ALL", "LEGENDARY", "EPIC", "RARE", "COMMON" }) do
		local selected = index == 1
		local chip = pill(filterRow, filter, selected and T.color.accent or T.color.surface,
			selected and T.color.accentInk or T.color.textMuted, phone and 76 or 104, T.touch - 6, index)
		chip.TextSize = T.type.caption.size + 1
	end

	local columns = phone and 1 or (spec.size.X >= 1600 and 3 or 2)
	local gridTop = T.touch + T.space.md
	local grid = create("Frame", {
		Position = UDim2.fromOffset(0, gridTop),
		Size = UDim2.new(1, 0, 1, -gridTop),
		BackgroundTransparency = 1,
		Parent = content,
	})
	local gridWidth = size.X - railWidth - T.space.lg * 2
	local cardWidth = math.floor((gridWidth - T.space.md * (columns - 1)) / columns)
	local cardHeight = phone and 96 or 116
	create("UIGridLayout", {
		CellSize = UDim2.fromOffset(cardWidth, cardHeight),
		CellPadding = UDim2.fromOffset(T.space.md, T.space.md),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})

	local cards = {
		{ "Tralalero Tralala", "LEGENDARY", "x3", T.color.accent },
		{ "Bombardiro Crocodilo", "EPIC", "x1", Color3.fromRGB(190, 120, 255) },
		{ "Cappuccina Ballerina", "RARE", "x2", Color3.fromRGB(90, 170, 255) },
		{ "Sahur Bros", "UNCOMMON", "x7", T.color.positive },
		{ "Patatina Fritta", "COMMON", "x12", T.color.textMuted },
		{ "Lirili Larila", "MYTHIC", "x1", Color3.fromRGB(255, 120, 190) },
	}
	for index, card in ipairs(cards) do
		local frame = create("Frame", {
			BackgroundColor3 = T.color.surface,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = grid,
		}, { rounded(T.radius.card) })
		create("UIStroke", { Color = T.color.line, Thickness = T.stroke.hairline, Parent = frame })
		-- Rarity is carried by a bar down the left edge, not by the title's colour alone.
		create("Frame", {
			Size = UDim2.new(0, 4, 1, -T.space.md * 2),
			Position = UDim2.fromOffset(0, T.space.md),
			BackgroundColor3 = card[4],
			BorderSizePixel = 0,
			Parent = frame,
		}, { rounded(T.radius.pill) })
		local portrait = create("Frame", {
			Position = UDim2.fromOffset(T.space.md + 4, T.space.md),
			Size = UDim2.fromOffset(cardHeight - T.space.md * 2, cardHeight - T.space.md * 2),
			BackgroundColor3 = T.color.surfaceAlt,
			BorderSizePixel = 0,
			Parent = frame,
		}, { rounded(T.radius.control) })
		text(portrait, T.type.caption, "3D", T.color.textMuted, {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		local left = T.space.md + 4 + (cardHeight - T.space.md * 2) + T.space.md
		text(frame, T.type.heading, card[1], T.color.text, {
			Position = UDim2.fromOffset(left, T.space.md),
			Size = UDim2.new(1, -left - T.space.md, 0, 24),
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		text(frame, T.type.label, card[2] .. "   " .. card[3], card[4], {
			Position = UDim2.fromOffset(left, T.space.md + 26),
			Size = UDim2.new(1, -left - T.space.md, 0, 18),
		})
		local actions = create("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, left, 1, -T.space.md),
			Size = UDim2.new(1, -left - T.space.md, 0, T.touch),
			BackgroundTransparency = 1,
			Parent = frame,
		}, {
			create("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, T.space.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		pill(actions, "EQUIP", T.color.positive, T.color.accentInk, 92, T.touch, 1)
		pill(actions, "MERGE", T.color.accent, T.color.accentInk, 92, T.touch, 2)
		pill(actions, "SELL", T.color.surfaceAlt, T.color.text, 76, T.touch, 3)
	end
	return panel
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

for _, spec in ipairs(SCREENS) do
	add("current", {
		name = "current_menu_" .. spec.name,
		settle = 1.1,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local screen = Mock.screen(gui, camera, spec, "menu as it is now")
			local panel = currentMenu(screen, spec)
			local overflowX = math.max(0, Current.panel.X - spec.size.X)
			local overflowY = math.max(0, Current.panel.Y - spec.size.Y)
			note(string.format("current %s: panel %dx%d on screen %dx%d (%.0f%% of width, %.0f%% of height)%s",
				spec.name, Current.panel.X, Current.panel.Y, spec.size.X, spec.size.Y,
				Current.panel.X / spec.size.X * 100, Current.panel.Y / spec.size.Y * 100,
				(overflowX > 0 or overflowY > 0) and string.format("; OFF SCREEN by %dx%d", overflowX, overflowY) or ""))
			panel.Visible = true
		end,
	})
	add("proposed", {
		name = "proposed_menu_" .. spec.name,
		settle = 1.1,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local screen = Mock.screen(gui, camera, spec, "menu as proposed")
			proposedMenu(screen, spec)
			local size = T.panelSize(spec.size, spec.touch)
			note(string.format("proposed %s: %s panel %dx%d (%.0f%% of width, %.0f%% of height), nav %s",
				spec.name, T.breakpoint(spec.size), size.X, size.Y,
				size.X / spec.size.X * 100, size.Y / spec.size.Y * 100,
				T.breakpoint(spec.size) == "phone" and "bottom bar" or "left rail"))
		end,
	})
end

--------------------------------------------------------------------------------
-- The real modules: MenuShell and UiParts, instantiated, not redrawn
--------------------------------------------------------------------------------

local UiParts = require(Scripts:WaitForChild("UiParts"))
local MenuShell = require(Scripts:WaitForChild("MenuShell"))
local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))

-- The eight entries the menu has today. The shell keeps them until the five-destination proposal
-- is decided, so this renders the shell change on its own.
local CURRENT_DESTINATIONS = {
	{ key = "Brainrots", label = "BRAINROTS", glyph = "★", sub = "Your collection" },
	{ key = "Trade", label = "TRADE", glyph = "⇄", sub = "Swap with players" },
	{ key = "Crates", label = "CRATES", glyph = "▣", sub = "Open and buy" },
	{ key = "Cosmetics", label = "COSMETICS", glyph = "◆", sub = "Skins and auras" },
	{ key = "Pass", label = "PASS", glyph = "▲", sub = "Brainrot Pass" },
	{ key = "Quests", label = "QUESTS", glyph = "✓", sub = "Daily and weekly" },
	{ key = "Shop", label = "SHOP", glyph = "＄", sub = "Robux" },
	{ key = "Settings", label = "SETTINGS", glyph = "⚙", sub = "Keys and audio" },
}

local SAMPLE = {
	{ "Tralalero Tralala", "LEGENDARY", "x3", Color3.fromRGB(255, 184, 48) },
	{ "Bombardiro Crocodilo", "EPIC", "x1", Color3.fromRGB(190, 120, 255) },
	{ "Cappuccina Ballerina", "RARE", "x2", Color3.fromRGB(90, 170, 255) },
	{ "Sahur Bros", "UNCOMMON", "x7", Color3.fromRGB(94, 214, 122) },
	{ "Patatina Fritta", "COMMON", "x12", Color3.fromRGB(153, 160, 178) },
	{ "Lirili Larila", "MYTHIC", "x1", Color3.fromRGB(255, 120, 190) },
}

-- Fills a shell's content with collection cards, the way the Brainrots tab would.
local function fillCollection(shell)
	local grid = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = shell.Content,
	})
	-- The card is a portrait and two lines of text on top, and a full-width row of actions along the
	-- bottom. It got there by measurement, not taste:
	--
	--   * at 96 tall (the old phone size) the bottom-anchored 44-pixel action row started at y=40
	--     while the rarity line sat at 38, so the buttons covered the rarity and the phone lost the
	--     colour-blind-readable label that F7 added;
	--   * with the actions beside the portrait at a fixed 92/92/76, they ran off the end of the
	--     card. A 1920 screen gives 3 columns of 308, and 308 minus a 92 portrait leaves 176 for
	--     three buttons and two gaps: the SELL button was clipped away entirely and nobody would
	--     have known the action was there.
	--
	-- So the portrait is 60, the actions get the full width, and their width comes from the card
	-- (88 at 1920, 120 on a phone) rather than from three numbers written here. 12 + 60 + 8 + 44 +
	-- 12 = 136. The touch target is never what gives way.
	local cardHeight = 136
	local portraitSize, pad = 60, 16
	local _, _, cardWidth = UiParts.grid(grid, shell.ContentWidth - 8, cardHeight, shell.phone and 260 or 300)
	local left = pad + portraitSize + T.space.md
	local actionWidth = math.max(72, math.floor((cardWidth - pad * 2 - T.space.sm * 2) / 3))
	for index, entry in ipairs(SAMPLE) do
		local card = UiParts.card({ parent = grid, edge = entry[4], layoutOrder = index })
		local portrait = create("Frame", {
			Position = UDim2.fromOffset(pad, 12),
			Size = UDim2.fromOffset(portraitSize, portraitSize),
			BackgroundColor3 = T.color.surfaceAlt,
			BorderSizePixel = 0,
			Parent = card,
		}, { rounded(8) })
		UiParts.text(portrait, T.type.caption, "3D", T.color.textMuted,
			{ Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
		UiParts.text(card, T.type.heading, entry[1], T.color.text,
			{ Position = UDim2.fromOffset(left, 12), Size = UDim2.new(1, -left - 12, 0, 24), TextTruncate = Enum.TextTruncate.AtEnd })
		UiParts.text(card, T.type.label, entry[2] .. "   " .. entry[3], entry[4],
			{ Position = UDim2.fromOffset(left, 38), Size = UDim2.new(1, -left - 12, 0, 18) })
		local actions = create("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, pad, 1, -12),
			Size = UDim2.new(1, -pad * 2, 0, 44),
			BackgroundTransparency = 1,
			Parent = card,
		}, {
			create("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		UiParts.button({ parent = actions, kind = "positive", text = "EQUIP", width = actionWidth, layoutOrder = 1 })
		UiParts.button({ parent = actions, kind = "primary", text = "MERGE", width = actionWidth, layoutOrder = 2 })
		UiParts.button({ parent = actions, kind = "secondary", text = "SELL", width = actionWidth, layoutOrder = 3 })
	end
end

for _, spec in ipairs(SCREENS) do
	add("shell", {
		name = "shell_" .. spec.name,
		settle = 1.2,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local screen = Mock.screen(gui, camera, spec, "MenuShell + UiParts (the real modules)")
			-- No PhoneLayout.Force here any more: the shell picks its version with UiKit.form, which
			-- is pure geometry and needs no device hook. PhoneLayout still supplies the panel fit,
			-- and that is size maths that does not consult Mode.
			local shell = MenuShell.new({ parent = screen, viewport = spec.size, title = "BRAIN ROT ROYALE" })
			shell:SetViewport(spec.size, spec.touch)
			shell:SetDestinations(CURRENT_DESTINATIONS, "Brainrots")
			-- The wallet the host drops into the header's slot.
			local wallet = create("Frame", {
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = T.color.surface,
				BorderSizePixel = 0,
				Parent = shell.WalletSlot,
			}, { rounded(999) })
			create("Frame", {
				Position = UDim2.new(0, 6, 0.5, -11),
				Size = UDim2.fromOffset(22, 22),
				BackgroundColor3 = T.color.accent,
				BorderSizePixel = 0,
				Parent = wallet,
			}, { rounded(999) })
			UiParts.text(wallet, T.type.heading, "12.4K", T.color.accent,
				{ Position = UDim2.fromOffset(34, 0), Size = UDim2.new(1, -40, 1, 0) })
			fillCollection(shell)
			shell:Open()
			note(string.format("shell %s: %s, panel %dx%d, nav %s, content width %d, %d columns, fit %.3f",
				spec.name, shell.Form, shell.panel.AbsoluteSize.X > 0 and shell.panel.Size.X.Offset or 0,
				shell.panel.Size.Y.Offset, shell.phone and "bottom bar" or "rail",
				shell.ContentWidth, UiParts.columns(shell.ContentWidth - 8, shell.phone and 260 or 300), shell.fitScale))
		end,
	})
end

add("components", {
	name = "components_uiparts",
	settle = 1.2,
	setup = function(_, camera)
		Mock.sky(camera)
		local gui = Mock.gui()
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1180, 700),
			BackgroundColor3 = T.color.base,
			BorderSizePixel = 0,
			Parent = gui,
		}, { rounded(16), UiKit.padding(24) })
		create("UIScale", { Scale = math.min(camera.ViewportSize.X * 0.92 / 1180, camera.ViewportSize.Y * 0.9 / 700), Parent = sheet })
		UiParts.text(sheet, T.type.display, "UiParts — the real components", T.color.text, { Size = UDim2.new(1, 0, 0, 44) })

		local row = create("Frame", {
			Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = sheet,
		}, { create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }) })
		for index, kind in ipairs({ "primary", "positive", "danger", "secondary", "ghost" }) do
			UiParts.button({ parent = row, kind = kind, text = string.upper(kind), width = 130, layoutOrder = index })
		end
		UiParts.button({ parent = row, kind = "primary", text = "DISABLED", width = 130, enabled = false, layoutOrder = 6 })

		local chips = create("Frame", {
			Position = UDim2.fromOffset(0, 124), Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Parent = sheet,
		}, { create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }) })
		for index, label in ipairs({ "ALL", "LEGENDARY", "EPIC", "RARE", "COMMON" }) do
			UiParts.chip({ parent = chips, text = label, selected = index == 1, width = 110, layoutOrder = index })
		end

		local meters = create("Frame", {
			Position = UDim2.fromOffset(0, 184), Size = UDim2.fromOffset(520, 120), BackgroundTransparency = 1, Parent = sheet,
		}, { create("UIListLayout", { Padding = UDim.new(0, 12) }) })
		UiParts.meter({ parent = meters, alpha = 0.62, value = "620 / 1000", layoutOrder = 1 })
		UiParts.meter({ parent = meters, alpha = 0.25, value = "TIER 4", color = T.color.info, layoutOrder = 2 })
		UiParts.meter({ parent = meters, alpha = 1, value = "DONE", color = T.color.positive, layoutOrder = 3 })

		local emptyCard = UiParts.emptyState({
			parent = sheet, title = "No brainrots yet",
			body = "Open a crate to roll your first one.",
			action = { text = "OPEN CRATES" },
		})
		-- emptyState is a card sized to its parent's width, which is right inside a tab and wrong on
		-- a specimen sheet: placed at x=560 it ran off the right edge of the panel. Pinned here.
		emptyCard.Position = UDim2.fromOffset(560, 184)
		emptyCard.Size = UDim2.fromOffset(572, 132)
		local empty = sheet:GetChildren()
		UiParts.text(sheet, T.type.heading, "Buttons answer hover, press, focus and disabled; every tappable is 44 px", T.color.textMuted,
			{ Position = UDim2.fromOffset(0, 340), Size = UDim2.new(1, 0, 0, 22) })

		-- The dialog is a modal: it draws a scrim over its whole parent and centres itself. Parented
		-- straight to the sheet it did exactly that, and buried every other specimen behind it. It
		-- gets a stage of its own down here instead, which also shows the scrim as part of the piece.
		local stage = create("Frame", {
			Position = UDim2.fromOffset(0, 380),
			Size = UDim2.fromOffset(560, 272),
			BackgroundColor3 = T.color.surfaceAlt,
			BackgroundTransparency = 0.6,
			BorderSizePixel = 0,
			Parent = sheet,
		}, { rounded(12) })
		UiParts.dialog({
			parent = stage, viewport = Vector2.new(560, 272), width = 460, height = 200,
			title = "Merge Tralalero Tralala?",
			body = "Three copies become one two-star, with +10% stats. This can't be undone.",
			actions = { { text = "CANCEL", kind = "secondary" }, { text = "MERGE", kind = "primary" } },
		})

		-- The navigation cells, which are what the shell is made of and appear nowhere else on the
		-- sheet: the rail form on the left, the bottom-bar form under it.
		local rail = create("Frame", {
			Position = UDim2.fromOffset(600, 380), Size = UDim2.fromOffset(208, 180),
			BackgroundTransparency = 1, Parent = sheet,
		}, { create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
		for index, entry in ipairs({ { "BRAINROTS", "Your collection", true }, { "CRATES", "Open and buy", false }, { "SHOP", "Robux", false } }) do
			UiParts.navItem({
				parent = rail, rail = true, glyph = index == 1 and "★" or (index == 2 and "▣" or "$"),
				label = entry[1], sub = entry[2], selected = entry[3], layoutOrder = index,
			})
		end
		local bar = create("Frame", {
			Position = UDim2.fromOffset(830, 380), Size = UDim2.fromOffset(300, 44),
			BackgroundTransparency = 1, Parent = sheet,
		}, { create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
		for index, entry in ipairs({ { "★", "BRAINROTS", true }, { "▣", "CRATES", false } }) do
			UiParts.navItem({ parent = bar, rail = false, width = 140, glyph = entry[1], label = entry[2], selected = entry[3], layoutOrder = index })
		end
		UiParts.text(sheet, T.type.caption, "Rail cells (desktop and tablet) and bar cells (phone) — the same destination, two shapes",
			T.color.textMuted, { Position = UDim2.fromOffset(600, 572), Size = UDim2.fromOffset(560, 18) })
		note(string.format("components: %d children on the sheet, dialog and empty state from the module", #empty))
	end,
})

-- UiParts.splitRow at both shapes, side by side: the same row of media, text and actions at a
-- desktop width and at a portrait content width. Built to claude-f5's spec after their crate card's
-- odds line went to a negative width on a narrow screen; the odds line here is marked `disclosure`,
-- so it wraps in both and is never truncated.
add("splitrow", {
	name = "splitrow_wide_vs_narrow",
	settle = 1.0,
	setup = function(_, camera)
		Mock.sky(camera)
		local gui = Mock.gui()
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1180, 700),
			BackgroundColor3 = T.color.base,
			BorderSizePixel = 0,
			Parent = gui,
		}, { rounded(16), UiKit.padding(24) })
		create("UIScale", { Scale = math.min(camera.ViewportSize.X * 0.92 / 1180, camera.ViewportSize.Y * 0.9 / 700), Parent = sheet })
		UiParts.text(sheet, T.type.display, "One row, two shapes", T.color.text, { Size = UDim2.new(1, 0, 0, 44) })

		local ODDS = "Common 62.0%  ·  Uncommon 26.0%  ·  Rare 9.0%  ·  Epic 2.4%  ·  Legendary 0.5%  ·  Mythic 0.1%"
		local function specimen(x, y, width, caption)
			UiParts.text(sheet, T.type.label, caption, T.color.textMuted,
				{ Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, 20) })
			local holder = UiParts.card({ parent = sheet, size = UDim2.fromOffset(width, 10) })
			holder.Position = UDim2.fromOffset(x, y + 26)
			local row = UiParts.splitRow(holder, {
				width = width,
				actions = {
					{ kind = "primary", text = "OPEN", width = 120 },
					{ kind = "secondary", text = "BUY", width = 120 },
				},
				lines = 3,
				belowText = 42,
			})
			holder.Size = UDim2.fromOffset(width, row.Height)
			-- The best-drops strip: built at the wide size, absent narrow, where the odds line
			-- already names every rarity that can drop and 42 px is a third of a card.
			if row.Below then
				local strip = create("Frame", {
					Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = row.Below,
				}, { create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }) })
				for index = 1, 5 do
					create("Frame", {
						Size = UDim2.fromOffset(42, 42),
						BackgroundColor3 = T.color.surfaceAlt,
						BorderSizePixel = 0,
						LayoutOrder = index,
						Parent = strip,
					}, { rounded(8) })
				end
			end
			UiParts.text(row.Media, T.type.caption, "3D", T.color.textMuted,
				{ Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
			row.Line({ text = "Rare Crate", style = UiKit.Type.Heading })
			row.Line({ text = "1,200 coins  ·  pity in 3", color = T.color.textMuted })
			row.Line({ text = ODDS, color = T.color.textMuted, disclosure = true })
			return row
		end

		local wide = specimen(0, 70, 720, "720 px of content — media left, text middle, actions right")
		local narrow = specimen(760, 70, 296, "296 px (320x568 portrait) — media shrinks, actions go full width")
		UiParts.text(sheet, T.type.body,
			"The odds line is marked disclosure: it wraps at both widths and truncation is off, because a cut-off probability for a paid random item is a wrong number, not a cosmetic problem.",
			T.color.text, { Position = UDim2.fromOffset(0, 560), Size = UDim2.fromOffset(1130, 48), TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top })
		note(string.format("splitrow: wide narrow=%s height=%d, narrow narrow=%s height=%d",
			tostring(wide.Narrow), wide.Height, tostring(narrow.Narrow), narrow.Height))
	end,
})

--------------------------------------------------------------------------------
-- HUD layout maps: where the clusters actually land, and what covers what
--
-- Pasted from `python tools/menu_hud_audit.py . --lua <file>`, which reads HudClient's own
-- Position/Size/AnchorPoint literals, so the pictures and the audit can't drift apart. Regenerate
-- and repaste when HudClient moves.
--------------------------------------------------------------------------------

local HUD_CLUSTERS = {
	{ name = "Top banner", pos = { 0.5, 0, 0, 10 }, size = { 0, 440, 0, 56 }, anchor = { 0.5, 0 }, modal = false },
	{ name = "READY pill", pos = { 0.5, 232, 0, 8 }, size = { 0, 230, 0, 60 }, anchor = { 0, 0 }, modal = false },
	{ name = "Crosshair", pos = { 0.5, 0, 0.5, 0 }, size = { 0, 64, 0, 64 }, anchor = { 0.5, 0.5 }, modal = false, centre = true },
	{ name = "Hitmarker", pos = { 0.5, 0, 0.5, 0 }, size = { 0, 80, 0, 40 }, anchor = { 0.5, 0.5 }, modal = false, centre = true },
	{ name = "Storm warning", pos = { 0.5, 0, 0.62, 0 }, size = { 0, 520, 0, 40 }, anchor = { 0.5, 0.5 }, modal = false },
	{ name = "Supply drop", pos = { 0.5, 0, 0, 128 }, size = { 0, 480, 0, 30 }, anchor = { 0.5, 0 }, modal = false },
	{ name = "Multi-kill", pos = { 0.5, 0, 0.34, 0 }, size = { 0, 520, 0, 60 }, anchor = { 0.5, 0.5 }, modal = false },
	{ name = "Now entering", pos = { 0.5, 0, 0, 160 }, size = { 0, 520, 0, 34 }, anchor = { 0.5, 0 }, modal = false },
	{ name = "Damage arrow", pos = { 0.5, 0, 0.5, 0 }, size = { 0, 4, 0, 150 }, anchor = { 0.5, 0.5 }, modal = false, centre = true },
	{ name = "Health", pos = { 0, 16, 1, -96 }, size = { 0, 280, 0, 80 }, anchor = { 0, 0 }, modal = false },
	{ name = "Companion", pos = { 0, 16, 1, -166 }, size = { 0, 300, 0, 62 }, anchor = { 0, 0 }, modal = false },
	{ name = "Speed pill", pos = { 0, 16, 1, -202 }, size = { 0, 150, 0, 28 }, anchor = { 0, 0 }, modal = false },
	{ name = "Hotbar", pos = { 1, -16, 1, -16 }, size = { 0, 690, 0, 150 }, anchor = { 1, 1 }, modal = false },
	{ name = "Use bar", pos = { 0.5, 0, 0.6, 0 }, size = { 0, 250, 0, 46 }, anchor = { 0.5, 0 }, modal = false },
	{ name = "Storm readout", pos = { 0.5, 0, 0, 72 }, size = { 0, 440, 0, 24 }, anchor = { 0.5, 0 }, modal = false },
	{ name = "Compass", pos = { 0.5, 0, 0.24, 0 }, size = { 0, 600, 0, 44 }, anchor = { 0.5, 0.5 }, modal = false },
	{ name = "Kill feed", pos = { 1, -16, 0, 312 }, size = { 0, 300, 0, 200 }, anchor = { 1, 0 }, modal = false },
	{ name = "Toasts", pos = { 0.5, 0, 1, -120 }, size = { 0, 460, 0, 36 }, anchor = { 0.5, 1 }, modal = false },
	{ name = "Map vote", pos = { 0.5, 0, 0.5, 0 }, size = { 0, 620, 0, 260 }, anchor = { 0.5, 0.5 }, modal = true },
	{ name = "Results card", pos = { 0.5, 0, 0.5, 0 }, size = { 0, 460, 0, 410 }, anchor = { 0.5, 0.5 }, modal = true },
	{ name = "Winner banner", pos = { 0.5, 0, 0.2, 0 }, size = { 0, 760, 0, 90 }, anchor = { 0.5, 0.5 }, modal = true },
	{ name = "Death recap", pos = { 0.5, 0, 0, 80 }, size = { 0, 480, 0, 104 }, anchor = { 0.5, 0.5 }, modal = true },
}

local StaminaBar = require(Scripts:WaitForChild("StaminaBar"))

local function clusterRect(cluster, viewport)
	local x = cluster.pos[1] * viewport.X + cluster.pos[2]
	local y = cluster.pos[3] * viewport.Y + cluster.pos[4]
	local w = cluster.size[1] * viewport.X + cluster.size[2]
	local h = cluster.size[3] * viewport.Y + cluster.size[4]
	return x - cluster.anchor[1] * w, y - cluster.anchor[2] * h, w, h
end

for _, spec in ipairs(SCREENS) do
	add("hudmap", {
		name = "hudmap_" .. spec.name,
		settle = 1.2,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local screen = Mock.screen(gui, camera, spec, "HUD as it is now: clusters and overlaps")

			-- The safe area the revamp works inside.
			local safe = T.safeArea(spec.size, spec.touch)
			create("Frame", {
				Position = UDim2.fromOffset(safe.left, safe.top),
				Size = UDim2.fromOffset(spec.size.X - safe.left - safe.right, spec.size.Y - safe.top - safe.bottom),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Parent = screen,
			}, { create("UIStroke", { Color = Color3.fromRGB(120, 255, 180), Thickness = 1, Transparency = 0.4 }) })

			local boxes = {}
			for _, cluster in ipairs(HUD_CLUSTERS) do
				if not cluster.modal then
					local x, y, w, h = clusterRect(cluster, spec.size)
					if not (w >= spec.size.X * 0.98 and h >= spec.size.Y * 0.98) then
						table.insert(boxes, { cluster = cluster, x = x, y = y, w = w, h = h })
						Mock.outline(screen, UDim2.fromOffset(x, y), UDim2.fromOffset(w, h), nil, cluster.name)
					end
				end
			end

			-- The stamina bar, from its own Layout, not from a copy of its numbers.
			local okStamina, anchor, position, scale = pcall(function()
				return StaminaBar.Layout(spec.size)
			end)
			if okStamina then
				local frame = Mock.outline(screen, position, UDim2.fromOffset(368 * scale, 50 * scale), anchor, "STAMINA",
					Color3.fromRGB(120, 255, 180))
				local sx = position.X.Scale * spec.size.X + position.X.Offset - anchor.X * 368 * scale
				local sy = position.Y.Scale * spec.size.Y + position.Y.Offset - anchor.Y * 50 * scale
				table.insert(boxes, { cluster = { name = "Stamina" }, x = sx, y = sy, w = 368 * scale, h = 50 * scale })
				frame.ZIndex = 2
			end

			local overlaps = 0
			for i = 1, #boxes do
				for j = i + 1, #boxes do
					local a, b = boxes[i], boxes[j]
					-- The crosshair, the hitmarker and the damage arrow all sit at the exact centre
					-- because that is what they are for — the arrow radiates from the aim point.
					-- Drawing them red said the HUD was broken where it was working, and a map that
					-- cries wolf is worth nothing. 1920x1080 goes from "3 overlaps" to none this
					-- way, which is the truth: the HUD was laid out for that screen, and breaks
					-- below it.
					if a.cluster.name ~= b.cluster.name and not (a.cluster.centre and b.cluster.centre) then
						local ox = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
						local oy = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
						if ox > 2 and oy > 2 then
							overlaps += 1
							local patch = create("Frame", {
								Position = UDim2.fromOffset(math.max(a.x, b.x), math.max(a.y, b.y)),
								Size = UDim2.fromOffset(ox, oy),
								BackgroundColor3 = Color3.fromRGB(255, 70, 70),
								BackgroundTransparency = 0.45,
								BorderSizePixel = 0,
								ZIndex = 5,
								Parent = screen,
							})
							create("UIStroke", { Color = Color3.fromRGB(255, 120, 120), Thickness = 1, Parent = patch })
						end
					end
				end
			end
			note(string.format("hudmap %s: %d concurrent clusters, %d overlapping pairs (red), safe area %d,%d %dx%d",
				spec.name, #boxes, overlaps, safe.left, safe.top,
				spec.size.X - safe.left - safe.right, spec.size.Y - safe.top - safe.bottom))
		end,
	})
end

add("tokens", {
	name = "design_tokens",
	settle = 1.2,
	setup = function(_, camera)
		Mock.sky(camera)
		local gui = Mock.gui()
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1180, 760),
			BackgroundColor3 = T.color.base,
			BorderSizePixel = 0,
			Parent = gui,
		}, { rounded(T.radius.panel), UiKit.padding(T.space.xl) })
		create("UIScale", { Scale = math.min(camera.ViewportSize.X * 0.92 / 1180, camera.ViewportSize.Y * 0.9 / 760), Parent = sheet })
		text(sheet, T.type.display, "PROPOSED DESIGN SYSTEM", T.color.text, { Size = UDim2.new(1, 0, 0, 44) })

		local swatches = { { "base", T.color.base }, { "surface", T.color.surface }, { "surfaceAlt", T.color.surfaceAlt },
			{ "line", T.color.line }, { "text", T.color.text }, { "textMuted", T.color.textMuted }, { "accent", T.color.accent },
			{ "positive", T.color.positive }, { "negative", T.color.negative }, { "storm", T.color.storm }, { "info", T.color.info } }
		text(sheet, T.type.heading, "PALETTE  (11 roles, replacing 9 colours + 20 literals)", T.color.textMuted,
			{ Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 24) })
		for index, swatch in ipairs(swatches) do
			local box = create("Frame", {
				Position = UDim2.fromOffset((index - 1) * 104, 92),
				Size = UDim2.fromOffset(96, 64),
				BackgroundColor3 = swatch[2],
				BorderSizePixel = 0,
				Parent = sheet,
			}, { rounded(T.radius.control) })
			create("UIStroke", { Color = T.color.line, Thickness = 1, Parent = box })
			text(sheet, T.type.caption, swatch[1], T.color.textMuted, {
				Position = UDim2.fromOffset((index - 1) * 104, 158),
				Size = UDim2.fromOffset(96, 16),
				TextXAlignment = Enum.TextXAlignment.Center,
			})
		end

		text(sheet, T.type.heading, "TYPE  (6 steps, replacing 24 sizes and 7 fonts)", T.color.textMuted,
			{ Position = UDim2.fromOffset(0, 190), Size = UDim2.new(1, 0, 0, 24) })
		local y = 220
		for _, entry in ipairs({ { "display", T.type.display, "BRAIN ROT ROYALE" }, { "title", T.type.title, "Crates" },
			{ "heading", T.type.heading, "Tralalero Tralala" }, { "body", T.type.body, "Open a crate to roll a new brainrot." },
			{ "label", T.type.label, "EQUIP" }, { "caption", T.type.caption, "Legendary · x3" } }) do
			text(sheet, T.type.caption, entry[1] .. " " .. entry[2].size, T.color.textMuted,
				{ Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(110, entry[2].size + 12) })
			text(sheet, entry[2], entry[3], T.color.text,
				{ Position = UDim2.fromOffset(120, y), Size = UDim2.fromOffset(700, entry[2].size + 12) })
			y += entry[2].size + 16
		end

		text(sheet, T.type.heading, "SPACING, RADII, TARGETS, MOTION", T.color.textMuted,
			{ Position = UDim2.fromOffset(620, 190), Size = UDim2.new(0, 520, 0, 24) })
		local x = 620
		for _, entry in ipairs({ { "xs", T.space.xs }, { "sm", T.space.sm }, { "md", T.space.md }, { "lg", T.space.lg },
			{ "xl", T.space.xl }, { "xxl", T.space.xxl } }) do
			create("Frame", {
				Position = UDim2.fromOffset(x, 224),
				Size = UDim2.fromOffset(entry[2], 40),
				BackgroundColor3 = T.color.accent,
				BorderSizePixel = 0,
				Parent = sheet,
			})
			text(sheet, T.type.caption, entry[1], T.color.textMuted,
				{ Position = UDim2.fromOffset(x, 266), Size = UDim2.fromOffset(40, 16) })
			x += entry[2] + 26
		end
		local rx = 620
		for _, entry in ipairs({ { "control 8", T.radius.control }, { "card 12", T.radius.card }, { "panel 16", T.radius.panel }, { "pill", T.radius.pill } }) do
			local box = create("Frame", {
				Position = UDim2.fromOffset(rx, 300),
				Size = UDim2.fromOffset(110, 56),
				BackgroundColor3 = T.color.surface,
				BorderSizePixel = 0,
				Parent = sheet,
			}, { rounded(entry[2]) })
			create("UIStroke", { Color = T.color.line, Thickness = 1, Parent = box })
			text(box, T.type.caption, entry[1], T.color.textMuted, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
			rx += 122
		end
		local target = create("Frame", {
			Position = UDim2.fromOffset(620, 372),
			Size = UDim2.fromOffset(T.touch, T.touch),
			BackgroundColor3 = T.color.surfaceAlt,
			BorderSizePixel = 0,
			Parent = sheet,
		}, { rounded(T.radius.control) })
		create("UIStroke", { Color = T.color.accent, Thickness = T.stroke.focus, Parent = target })
		text(sheet, T.type.body, "44 px minimum touch target (16 buttons are under it today)", T.color.text,
			{ Position = UDim2.fromOffset(620 + T.touch + 12, 372), Size = UDim2.fromOffset(500, T.touch) })
		text(sheet, T.type.body, string.format("motion: press %.2fs · fade %.2fs · panel %.2fs · celebrate %.2fs (14 durations today)",
			T.motion.press, T.motion.fade, T.motion.panel, T.motion.celebrate), T.color.text,
			-- Wrapped, not clipped: at 16 px this line is wider than the column, and it ran off the
			-- sheet's right edge. A sheet about a design system is a poor place to clip text.
			{ Position = UDim2.fromOffset(620, 424), Size = UDim2.fromOffset(508, 44), TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top })

		text(sheet, T.type.heading, "STATES", T.color.textMuted, { Position = UDim2.fromOffset(0, 470), Size = UDim2.new(0, 560, 0, 24) })
		local states = { { "rest", T.color.accent, T.color.accentInk, 0 }, { "hover", T.color.accent:Lerp(Color3.new(1, 1, 1), 0.12), T.color.accentInk, 0 },
			{ "press", T.color.accent:Lerp(Color3.new(0, 0, 0), 0.18), T.color.accentInk, 0 },
			{ "disabled", T.color.surfaceAlt, T.color.textMuted, 0 }, { "focus", T.color.accent, T.color.accentInk, T.stroke.focus } }
		for index, state in ipairs(states) do
			local button = create("TextButton", {
				Position = UDim2.fromOffset((index - 1) * 116, 502),
				Size = UDim2.fromOffset(104, T.touch),
				BackgroundColor3 = state[2],
				BorderSizePixel = 0,
				Font = T.type.label.font,
				Text = string.upper(state[1]),
				TextColor3 = state[3],
				TextSize = T.type.label.size,
				Parent = sheet,
			}, { rounded(T.radius.control) })
			if state[4] > 0 then
				create("UIStroke", { Color = T.color.text, Thickness = state[4], Parent = button })
			end
		end
		note("tokens: 11 colour roles, 6 type steps, 6 spacing steps, 4 radii, 4 motion durations, 44 px targets")
	end,
})

add("parts", {
	name = "parts_current_vs_proposed",
	settle = 1.2,
	setup = function(_, camera)
		Mock.sky(camera)
		local gui = Mock.gui()
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1180, 700),
			BackgroundColor3 = T.color.base,
			BorderSizePixel = 0,
			Parent = gui,
		}, { rounded(T.radius.panel), UiKit.padding(T.space.xl) })
		create("UIScale", { Scale = math.min(camera.ViewportSize.X * 0.92 / 1180, camera.ViewportSize.Y * 0.9 / 700), Parent = sheet })
		text(sheet, T.type.display, "PARTS: NOW  vs  PROPOSED", T.color.text, { Size = UDim2.new(1, 0, 0, 44) })

		-- Now: the row every tab uses.
		text(sheet, T.type.heading, "NOW — 64 px row, 13 px subtitle, three 94x38 buttons", T.color.textMuted,
			{ Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 22) })
		local row = create("Frame", {
			Position = UDim2.fromOffset(0, 90),
			Size = UDim2.fromOffset(700, 64),
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			Parent = sheet,
		}, { rounded(10) })
		create("TextLabel", {
			Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -320, 0, 22), BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold, Text = "Tralalero Tralala", TextColor3 = C.Accent,
			TextXAlignment = Enum.TextXAlignment.Left, TextSize = 16, Parent = row,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(14, 32), Size = UDim2.new(1, -320, 0, 20), BackgroundTransparency = 1,
			Font = Enum.Font.Gotham, Text = "Legendary  •  x3  •  1,200 coins each", TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left, TextSize = 13, Parent = row,
		})
		for index, spec2 in ipairs({ { "EQUIP", C.Green }, { "MERGE", C.Accent }, { "SELL", C.Red } }) do
			create("TextButton", {
				Position = UDim2.fromOffset(700 - 12 - (4 - index) * 100, 13),
				Size = UDim2.fromOffset(94, 38),
				BackgroundColor3 = spec2[2], BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = spec2[1],
				TextColor3 = Color3.new(0, 0, 0), TextSize = 13, Parent = row,
			}, { rounded(8) })
		end

		-- Proposed: a card with a rarity edge, a portrait, and 44 px actions.
		text(sheet, T.type.heading, "PROPOSED — card, rarity edge, portrait, 44 px actions", T.color.textMuted,
			{ Position = UDim2.fromOffset(0, 180), Size = UDim2.new(1, 0, 0, 22) })
		local card = create("Frame", {
			Position = UDim2.fromOffset(0, 210),
			Size = UDim2.fromOffset(700, 116),
			BackgroundColor3 = T.color.surface,
			BorderSizePixel = 0,
			Parent = sheet,
		}, { rounded(T.radius.card) })
		create("UIStroke", { Color = T.color.line, Thickness = T.stroke.hairline, Parent = card })
		create("Frame", {
			Position = UDim2.fromOffset(0, T.space.md), Size = UDim2.new(0, 4, 1, -T.space.md * 2),
			BackgroundColor3 = T.color.accent, BorderSizePixel = 0, Parent = card,
		}, { rounded(T.radius.pill) })
		local portrait = create("Frame", {
			Position = UDim2.fromOffset(T.space.md + 4, T.space.md), Size = UDim2.fromOffset(92, 92),
			BackgroundColor3 = T.color.surfaceAlt, BorderSizePixel = 0, Parent = card,
		}, { rounded(T.radius.control) })
		text(portrait, T.type.caption, "3D portrait", T.color.textMuted,
			{ Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true })
		text(card, T.type.heading, "Tralalero Tralala", T.color.text,
			{ Position = UDim2.fromOffset(120, T.space.md), Size = UDim2.new(1, -132, 0, 24) })
		text(card, T.type.label, "LEGENDARY   x3", T.color.accent,
			{ Position = UDim2.fromOffset(120, T.space.md + 26), Size = UDim2.new(1, -132, 0, 18) })
		text(card, T.type.caption, "1,200 coins each · equipped as your companion", T.color.textMuted,
			{ Position = UDim2.fromOffset(120, T.space.md + 46), Size = UDim2.new(1, -132, 0, 18) })
		for index, spec2 in ipairs({ { "EQUIP", T.color.positive, T.color.accentInk }, { "MERGE", T.color.accent, T.color.accentInk },
			{ "SELL", T.color.surfaceAlt, T.color.text } }) do
			local button = create("TextButton", {
				Position = UDim2.fromOffset(120 + (index - 1) * 100, 116 - T.space.md - T.touch),
				Size = UDim2.fromOffset(92, T.touch),
				BackgroundColor3 = spec2[2], BorderSizePixel = 0, Font = T.type.label.font, Text = spec2[1],
				TextColor3 = spec2[3], TextSize = T.type.label.size, Parent = card,
			}, { rounded(T.radius.control) })
			if index == 1 then
				create("UIStroke", { Color = T.color.text, Thickness = T.stroke.focus, Transparency = 0.6, Parent = button })
			end
		end

		-- Tabs, now and proposed.
		text(sheet, T.type.heading, "NAVIGATION — 8 tabs of 85x34 (14 px) vs 5 destinations, 44 px, with a subtitle",
			T.color.textMuted, { Position = UDim2.fromOffset(0, 350), Size = UDim2.new(1, 0, 0, 22) })
		for index, label in ipairs(Current.tabs) do
			create("TextButton", {
				Position = UDim2.fromOffset((index - 1) * 91, 380),
				Size = UDim2.fromOffset(85, 34),
				BackgroundColor3 = index == 1 and C.Accent or C.Panel, BorderSizePixel = 0,
				Font = Enum.Font.GothamBold, Text = label, TextColor3 = index == 1 and Color3.new(0, 0, 0) or C.Muted,
				TextSize = 14, Parent = sheet,
			}, { rounded(8) })
		end
		for index, destination in ipairs(DESTINATIONS) do
			local cell = create("Frame", {
				Position = UDim2.fromOffset((index - 1) * 152, 430),
				Size = UDim2.fromOffset(144, 56),
				BackgroundColor3 = index == 1 and T.color.accent or T.color.surface,
				BorderSizePixel = 0, Parent = sheet,
			}, { rounded(T.radius.card) })
			text(cell, T.type.label, destination.glyph .. "  " .. destination.label,
				index == 1 and T.color.accentInk or T.color.text,
				{ Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -16, 0, 20) })
			text(cell, T.type.caption, destination.sub, index == 1 and T.color.accentInk or T.color.textMuted,
				{ Position = UDim2.fromOffset(12, 30), Size = UDim2.new(1, -16, 0, 16) })
		end

		text(sheet, T.type.heading, "EMPTY STATE — a line of grey text vs a titled, actionable panel", T.color.textMuted,
			{ Position = UDim2.fromOffset(0, 510), Size = UDim2.new(1, 0, 0, 22) })
		create("TextLabel", {
			Position = UDim2.fromOffset(0, 540), Size = UDim2.fromOffset(340, 90), BackgroundTransparency = 1,
			Font = Enum.Font.Gotham, Text = "No brainrots yet. Open a crate to get your first.",
			TextColor3 = C.Muted, TextWrapped = true, TextSize = 14, Parent = sheet,
		})
		local empty = create("Frame", {
			Position = UDim2.fromOffset(380, 540), Size = UDim2.fromOffset(420, 120),
			BackgroundColor3 = T.color.surface, BorderSizePixel = 0, Parent = sheet,
		}, { rounded(T.radius.card) })
		create("UIStroke", { Color = T.color.line, Thickness = T.stroke.hairline, Parent = empty })
		text(empty, T.type.heading, "No brainrots yet", T.color.text,
			{ Position = UDim2.fromOffset(T.space.lg, T.space.md), Size = UDim2.new(1, -32, 0, 24) })
		text(empty, T.type.body, "Open a crate to roll your first one.", T.color.textMuted,
			{ Position = UDim2.fromOffset(T.space.lg, T.space.md + 26), Size = UDim2.new(1, -32, 0, 20) })
		local go = create("TextButton", {
			Position = UDim2.fromOffset(T.space.lg, 120 - T.space.md - T.touch), Size = UDim2.fromOffset(160, T.touch),
			BackgroundColor3 = T.color.accent, BorderSizePixel = 0, Font = T.type.label.font, Text = "OPEN CRATES",
			TextColor3 = T.color.accentInk, TextSize = T.type.label.size, Parent = empty,
		}, { rounded(T.radius.control) })
		note("parts: row 64px/3 buttons under 44 -> card 116px with 44 px actions; 8 tabs -> 5 destinations")
	end,
})

return views
