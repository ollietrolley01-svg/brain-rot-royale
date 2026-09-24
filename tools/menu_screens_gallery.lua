-- #78 / #20 / #24: every menu screen at every size, for Oliver's machine.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery <abs path to this file> -OutDir <folder> -Hold 1
--
-- One shot per screen (SHOP, BRAINROTS, PROGRESS, ROBUX, SETTINGS) per size: the REAL MenuShell with
-- the REAL MenuScreens destinations and title, so what is judged here is what MenuClient hands the
-- shell. ROBUX and SETTINGS should show no navigation at all and a full-width content area.
--
-- The content of every shot is the Kill Animations tab (#24), drawn by the REAL
-- MenuScreens.RenderKillAnimations over the real CosmeticData entries, with the REAL row previews
-- (Shared/CosmeticPreview where it can build the item, the colour swatch where it can't -- kill
-- animations have no model, so today they are all swatches). The ROW itself is a copy of MenuClient's
-- makeRow/addButton (a LocalScript cannot be required), so it is the previews and the tab's logic
-- being shown, not a new row design. Look for: a preview in every row, wide and stacked; none of
-- them touching a button or a name; the swatch reading as deliberate rather than as a missing image.
--
-- What tools/menu_screens_check.py already proved without Studio (layout, wiring, fit) is not the
-- question here. The question is whether it LOOKS right, which only a render answers.

local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(scripts:WaitForChild("UiKit"))
local MenuShell = require(scripts:WaitForChild("MenuShell"))
local MenuScreens = require(scripts:WaitForChild("MenuScreens"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors
local GUI_NAME = "BRR_MenuScreensGallery"

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local SIZES = {
	{ name = "1920x1080", size = Vector2.new(1920, 1080), touch = false },
	{ name = "1024x768_tablet", size = Vector2.new(1024, 768), touch = true },
	{ name = "844x390_phone_landscape", size = Vector2.new(844, 390), touch = true },
	{ name = "390x844_phone_portrait", size = Vector2.new(390, 844), touch = true },
	{ name = "320x640_phone_small", size = Vector2.new(320, 640), touch = true },
}

local LABELS = {
	Brainrots = "Brainrots", Trade = "Trade", Crates = "Crates", Style = "Style Crates", Cosmetics = "Cosmetics",
	KillAnimations = "Kill Animations", Pass = "Pass", Rank = "Rank", Mastery = "Mastery", Index = "Rot Index",
	CellShop = "Cell Shop", Quests = "Quests", Robux = "Robux Shop", Settings = "Settings",
}

local function gui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	return create("ScreenGui", {
		Name = GUI_NAME,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = 20,
		Parent = StarterGui,
	})
end

-- The screen at its real pixel size, clipped, so anything hanging off it is visibly cut.
local function screenOf(parent, camera, spec, caption)
	local viewport = camera.ViewportSize
	local fit = math.min(viewport.X * 0.92 / spec.size.X, viewport.Y * 0.84 / spec.size.Y)
	local screen = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.54),
		Size = UDim2.fromOffset(spec.size.X, spec.size.Y),
		BackgroundColor3 = Color3.fromRGB(118, 160, 196),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	create("UIScale", { Scale = fit, Parent = screen })
	create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.02),
		Size = UDim2.new(0, 1100, 0, 34),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("%s   %s", spec.name, caption),
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.25,
		TextSize = 24,
		Parent = parent,
	})
	return screen
end

-- A copy of MenuClient's makeRow / addButton (StarterPlayerScripts/MenuClient.client.lua), trimmed to
-- what the kill animations tab uses. If those change there, change them here.
local function host(content, width)
	local narrow = width < 560
	local h = { narrow = narrow, formatNumber = UiKit.formatNumber }
	h.profile = { coins = 5000, cosmetics = { owned = {} } }
	-- The first real entry owned and worn, the second owned, so all three button states are in shot.
	local ids = MenuScreens.KillAnimationRows({ cosmetics = { owned = {} } })
	if ids[1] then h.profile.cosmetics.owned[ids[1].id] = true; h.profile.cosmetics.killAnimation = ids[1].id end
	if ids[2] then h.profile.cosmetics.owned[ids[2].id] = true end
	function h.stockHeader(order, text)
		create("TextLabel", { Size = UDim2.new(1, -8, 0, 26), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
			Text = text, TextColor3 = C.Accent, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 14, LayoutOrder = order, Parent = content })
	end
	function h.emptyMessage(text)
		create("TextLabel", { Size = UDim2.new(1, -8, 0, 90), BackgroundTransparency = 1, Font = Enum.Font.Gotham, Text = text,
			TextColor3 = C.Muted, TextWrapped = true, TextSize = 14, Parent = content })
	end
	function h.makeRow(order, title, titleColor, subtitle)
		local row = create("Frame", { Size = UDim2.new(1, -8, 0, narrow and 112 or 64), BackgroundColor3 = C.Panel,
			BorderSizePixel = 0, LayoutOrder = order, Parent = content }, { rounded(10) })
		create("TextLabel", { Position = UDim2.new(0, 14, 0, 10), Size = UDim2.new(1, narrow and -28 or -320, 0, 22),
			BackgroundTransparency = 1, Font = Enum.Font.GothamBold, Text = title, TextColor3 = titleColor or C.Text,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, TextSize = 16, Parent = row })
		create("TextLabel", { Position = UDim2.new(0, 14, 0, 32), Size = UDim2.new(1, narrow and -28 or -320, 0, 20),
			BackgroundTransparency = 1, Font = Enum.Font.Gotham, Text = subtitle or "", TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, TextSize = 13, Parent = row })
		return create("Frame", {
			AnchorPoint = narrow and Vector2.new(0, 1) or Vector2.new(1, 0.5),
			Position = narrow and UDim2.new(0, 14, 1, -12) or UDim2.new(1, -12, 0.5, 0),
			Size = narrow and UDim2.new(1, -28, 0, 38) or UDim2.new(0, 300, 0, 38),
			BackgroundTransparency = 1, Parent = row,
		}, { create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	end
	function h.addButton(parent, order, text, color, _, enabled)
		return create("TextButton", {
			Size = narrow and UDim2.new(1 / 3, -4, 0, 38) or UDim2.fromOffset(94, 38),
			BackgroundColor3 = enabled == false and C.PanelAlt or color, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
			Text = text, TextColor3 = enabled == false and C.Muted or Color3.new(0, 0, 0), TextSize = 13,
			LayoutOrder = order, Parent = parent,
		}, { rounded(8), narrow and create("UISizeConstraint", { MaxSize = Vector2.new(94, 38) }) or nil })
	end
	h.buy = function() end
	h.equip = function() end
	return h
end

local views = {}
for _, spec in ipairs(SIZES) do
	for _, screen in ipairs(MenuScreens.Screens) do
		local name = string.format("%s_%s", spec.name, screen.key)
		table.insert(views, {
			name = name,
			settle = 1.5,
			setup = function(_, camera)
				camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
				local root = gui()
				local frame = screenOf(root, camera, spec, screen.title .. " screen  (content: Kill Animations tab)")
				local shell = MenuShell.new({ parent = frame, title = "BRAINROT BATTLES", viewport = spec.size })
				shell:SetViewport(spec.size, spec.touch)
				local destinations, found = MenuScreens.Destinations(screen.tabs[1], function(key)
					return LABELS[key]
				end)
				shell:SetTitle(found.title)
				shell:SetDestinations(destinations, screen.tabs[1])
				local content = create("Frame", {
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					Parent = shell.Content,
				}, { create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
				local rows = MenuScreens.RenderKillAnimations(host(content, shell.ContentWidth or 700))
				shell:Open()
				note(string.format("%s: %d tabs, nav %s, content %d px wide, %d kill animation rows, %s rows",
					name, #destinations, shell.nav.Visible and "shown" or "hidden", shell.ContentWidth or -1, rows,
					(shell.ContentWidth or 700) < 560 and "stacked" or "wide"))
			end,
		})
	end
end

return views
