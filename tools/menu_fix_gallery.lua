-- Oliver's #65, before and after, plus the two options for the landscape-phone rail.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery <abs path> -OutDir <folder> -Hold 1
--
-- BEFORE is not a reconstruction. `MenuShell.new` still falls back to Vector2.new(1280, 720) when
-- no viewport is passed, so a shell built here WITHOUT calling SetViewport is byte-for-byte the
-- code path MenuClient took in the built place: one fixed 1100x619 panel, on every screen. AFTER
-- passes the viewport, which is the whole of the fix.
--
-- The grey box in each shot is the SCREEN, drawn at its real pixel size and clipped at its edges,
-- so anything hanging off it is something the player cannot reach.
--
-- The last three views are PROPOSALS for a landscape phone and are NOT IN THE BUILT PLACE. The
-- landed fix only stops the rail escaping the panel; which shape it should take belongs to the #78
-- revamp, and Oliver picks it from these pictures.

local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(scripts:WaitForChild("UiKit"))
local UiParts = require(scripts:WaitForChild("UiParts"))
local MenuShell = require(scripts:WaitForChild("MenuShell"))

local create, rounded = UiKit.create, UiKit.rounded
local Role, Type, Space = UiKit.Role, UiKit.Type, UiKit.Space
local GUI_NAME = "BRR_MenuFixGallery"

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

-- The NINE MenuClient hands the shell today, exactly as the built place has them. `Style` really
-- does have no glyph and no subtitle: DESTINATION_LOOK was never given an entry for it when the
-- cosmetic-crates tab was added, so the rail draws it with an empty icon slot. Nine at 56 px is
-- also what overflows the rail on a desktop, so this is the list the before/after has to use.
local DESTINATIONS = {
	{ key = "Brainrots", label = "BRAINROTS", glyph = "★", sub = "Your collection" },
	{ key = "Trade", label = "TRADE", glyph = "⇄", sub = "Swap with players" },
	{ key = "Crates", label = "CRATES", glyph = "▣", sub = "Open and buy" },
	{ key = "Style", label = "STYLE CRATES", glyph = nil, sub = nil },
	{ key = "Cosmetics", label = "COSMETICS", glyph = "◆", sub = "Skins and auras" },
	{ key = "Pass", label = "PASS", glyph = "▲", sub = "Brainrot Pass" },
	{ key = "Quests", label = "QUESTS", glyph = "✓", sub = "Daily and weekly" },
	{ key = "Robux", label = "ROBUX SHOP", glyph = "$", sub = "Robux" },
	{ key = "Settings", label = "SETTINGS", glyph = "⚙", sub = "Keys and audio" },
}

-- The five the `tall` version is specified to carry. Option B asks whether `short` should take the
-- same cut.
local FIVE = {
	{ key = "Collection", label = "COLLECTION", glyph = "★", sub = "Brainrots and codex" },
	{ key = "Crates", label = "CRATES", glyph = "▣", sub = "Open and buy" },
	{ key = "Style", label = "STYLE", glyph = "◆", sub = "Cosmetics and kills" },
	{ key = "Progress", label = "PROGRESS", glyph = "▲", sub = "Pass, quests, streaks" },
	{ key = "Shop", label = "SHOP", glyph = "$", sub = "Coins and Robux" },
}

local SCREENS = {
	{ name = "1920x1080", size = Vector2.new(1920, 1080), touch = false },
	{ name = "1280x720", size = Vector2.new(1280, 720), touch = false },
	{ name = "1024x600", size = Vector2.new(1024, 600), touch = false },
	{ name = "phone_844x390", size = Vector2.new(844, 390), touch = true },
	{ name = "portrait_375x667", size = Vector2.new(375, 667), touch = true },
}

--------------------------------------------------------------------------------
-- The mock screen
--------------------------------------------------------------------------------

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

local function sky(camera)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
end

-- ClipsDescendants is the point: a panel bigger than the screen is CUT at the screen edge here,
-- exactly as it is on the device. A render that let it spill would hide the bug being shown.
local function screenOf(parent, camera, spec, caption, captionColor)
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
	-- Roblox's own top bar, which every layout has to stay clear of.
	create("Frame", {
		Size = UDim2.new(0, 220, 0, 52),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Parent = screen,
	})
	create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.055),
		Size = UDim2.new(0, 1100, 0, 34),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("%s   %s", spec.name, caption or ""),
		TextColor3 = captionColor or Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.25,
		TextSize = 24,
		Parent = parent,
	})
	return screen
end

-- Something for the content area to hold, so a shot shows a menu rather than an empty box.
local function fill(shell)
	local body = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = shell.Content,
	}, { create("UIListLayout", { Padding = UDim.new(0, Space.SM), SortOrder = Enum.SortOrder.LayoutOrder }) })
	local width = math.max(shell.ContentWidth or 300, 120)
	local columns = math.max(1, math.floor((width + Space.SM) / (260 + Space.SM)))
	local cell = math.floor((width - Space.SM * (columns - 1)) / columns) - 8
	local grid = create("Frame", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = body,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.fromOffset(cell, 84),
			CellPadding = UDim2.fromOffset(Space.SM, Space.SM),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index = 1, 6 do
		local card = create("Frame", {
			BackgroundColor3 = Role.Surface,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = grid,
		}, { rounded(12) })
		create("Frame", {
			Position = UDim2.fromOffset(10, 10),
			Size = UDim2.fromOffset(64, 64),
			BackgroundColor3 = Role.SurfaceAlt,
			BorderSizePixel = 0,
			Parent = card,
		}, { rounded(10) })
		UiParts.text(card, Type.Label, "Brainrot " .. index, Role.Text, {
			Position = UDim2.fromOffset(84, 14),
			Size = UDim2.new(1, -94, 0, 20),
		})
		UiParts.text(card, Type.Caption, "Rare", Role.TextMuted, {
			Position = UDim2.fromOffset(84, 38),
			Size = UDim2.new(1, -94, 0, 18),
		})
	end
end

-- The wallet the host drops into the header slot, so the header is shown as a player sees it.
local function wallet(shell)
	if not shell.WalletSlot.Visible then
		return
	end
	local chip = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Role.Surface,
		BorderSizePixel = 0,
		Parent = shell.WalletSlot,
	}, { rounded(999) })
	create("Frame", {
		Position = UDim2.new(0, 6, 0.5, -11),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = Role.Accent,
		BorderSizePixel = 0,
		Parent = chip,
	}, { rounded(999) })
	UiParts.text(chip, Type.Heading, "12.4K", Role.Accent, {
		Position = UDim2.fromOffset(34, 0),
		Size = UDim2.new(1, -40, 1, 0),
	})
end

-- The nav's window height from PROPERTIES, not AbsoluteSize. A view's `setup` runs before the
-- layout pass, so every AbsoluteSize read in here would be 0 and the note would be a row of zeros
-- that looks like a measurement. The probe is where measured numbers come from; this is only the
-- caption for the picture.
local function navWindow(shell)
	return shell.panel.Size.Y.Offset * shell.nav.Size.Y.Scale + shell.nav.Size.Y.Offset
end

local function describe(label, shell, spec)
	local cells = 0
	for _, child in ipairs(shell.nav:GetDescendants()) do
		if child:IsA("TextButton") then
			cells += 1
		end
	end
	note(string.format(
		"%s: screen %dx%d, panel %dx%d, form %s, nav window %d px, %d cells, fit %.3f",
		label,
		spec.size.X,
		spec.size.Y,
		shell.panel.Size.X.Offset,
		shell.panel.Size.Y.Offset,
		tostring(shell.Form),
		navWindow(shell),
		cells,
		shell.fitScale or 1
	))
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local views = {}

for _, spec in ipairs(SCREENS) do
	-- BEFORE: the constructor's own fallback, which is the path MenuClient took.
	table.insert(views, {
		name = "before_" .. spec.name,
		settle = 1.2,
		setup = function(_, camera)
			sky(camera)
			local root = gui()
			local screen = screenOf(root, camera, spec, "BEFORE -- shell never told the screen (as built)", Color3.fromRGB(255, 150, 150))
			local shell = MenuShell.new({ parent = screen, title = "BRAIN ROT ROYALE" })
			shell:SetDestinations(DESTINATIONS, "Brainrots")
			wallet(shell)
			fill(shell)
			shell:Open()
			describe("before_" .. spec.name, shell, spec)
		end,
	})

	table.insert(views, {
		name = "after_" .. spec.name,
		settle = 1.2,
		setup = function(_, camera)
			sky(camera)
			local root = gui()
			local screen = screenOf(root, camera, spec, "AFTER -- viewport passed, nav contained", Color3.fromRGB(160, 255, 180))
			local shell = MenuShell.new({ parent = screen, title = "BRAIN ROT ROYALE", viewport = spec.size })
			shell:SetViewport(spec.size, spec.touch)
			shell:SetDestinations(DESTINATIONS, "Brainrots")
			wallet(shell)
			fill(shell)
			shell:Open()
			describe("after_" .. spec.name, shell, spec)
		end,
	})
end

--------------------------------------------------------------------------------
-- The landscape-phone rail: three proposals, one screen. NOT IN THE BUILT PLACE.
--------------------------------------------------------------------------------

-- Re-lays a shell's rail into `columns` columns of glyph-only cells, using the real navItem, and
-- gives the content area back whatever width is left. A gallery arrangement of real components --
-- MenuShell itself is untouched by this, which is why these are proposals and not a render of the
-- fix.
local function columnRail(shell, destinations, columns)
	for _, child in ipairs(shell.nav:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	local cell = 48
	local navWidth = columns * cell + (columns - 1) * Space.SM
	shell.nav.Size = UDim2.new(0, navWidth, 1, -(shell.header.Size.Y.Offset + Space.LG))
	shell.navLayout.FillDirection = Enum.FillDirection.Horizontal
	shell.navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	shell.navLayout.VerticalAlignment = Enum.VerticalAlignment.Top

	local perColumn = math.ceil(#destinations / columns)
	local column = nil
	for index, destination in ipairs(destinations) do
		if (index - 1) % perColumn == 0 then
			column = create("Frame", {
				Size = UDim2.fromOffset(cell, perColumn * UiKit.Touch + (perColumn - 1) * Space.SM),
				BackgroundTransparency = 1,
				LayoutOrder = math.floor((index - 1) / perColumn) + 1,
				Parent = shell.nav,
			}, {
				create("UIListLayout", {
					FillDirection = Enum.FillDirection.Vertical,
					Padding = UDim.new(0, Space.SM),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			})
		end
		UiParts.navItem({
			parent = column,
			rail = true,
			compact = true,
			glyph = destination.glyph,
			label = destination.label,
			selected = index == 1,
			layoutOrder = index,
		})
	end
	local railWidth = Space.LG + navWidth
	shell.Content.Position = UDim2.fromOffset(railWidth, shell.header.Size.Y.Offset)
	shell.Content.Size = UDim2.new(1, -railWidth - Space.LG, 1, -shell.header.Size.Y.Offset - Space.MD)
	shell.ContentWidth = shell.panel.Size.X.Offset - railWidth - Space.LG
	return perColumn * UiKit.Touch + (perColumn - 1) * Space.SM
end

--------------------------------------------------------------------------------
-- The HUD stack drawn over the panel -- Oliver's screenshot, 2026-09-21
--------------------------------------------------------------------------------

-- His shot has a round dark chevron button sitting on top of the BRAINROTS rail tile. This is why:
-- the stack lives at a FIXED screen position (the group from x = 0, the tab at x = 232) and the
-- panel is CENTRED, so on a window narrower than the two together they occupy the same pixels. The
-- real MenuStackToggle is built here, with stand-ins at the exact coordinates MenuClient gives its
-- three real items, so the overlap in the picture is the overlap in the game rather than a drawing
-- of one.
local MenuStackToggle = require(scripts:WaitForChild("MenuStackToggle"))

local function stackItems(parent)
	local function item(x, y, w, h, text, color)
		local frame = create("TextButton", {
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(w, h),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Font = Enum.Font.GothamBold,
			Text = text,
			TextColor3 = color == Role.Accent and Color3.new(0, 0, 0) or Role.Text,
			TextSize = 15,
			Parent = parent,
		}, { rounded(10) })
		return frame
	end
	-- MenuClient's own numbers: the MENU pill at (16, 130) 210x42, the quest tracker at (16, 224)
	-- 250x40, and the bundle nudge between them.
	return {
		item(16, 130, 210, 42, "MENU  [M]", Role.Accent),
		item(16, 178, 210, 36, "BUNDLE READY", Role.Surface),
		item(16, 224, 250, 40, "QUESTS  2/3", Role.Base),
	}
end

-- Oliver's window, read off his screenshot: the panel's bottom edge at about y = 786 with a
-- 619-tall panel puts its top at 167, which puts the viewport at roughly 909 tall; the stack
-- overlapping the rail puts it near 1600 wide.
local OLIVER = { name = "oliver_1600x909", size = Vector2.new(1600, 909), touch = false }

for _, variant in ipairs({
	{ name = "stack_before_overlaps_rail", hidden = false,
		caption = "BEFORE -- the stack tab's chevron lands on the first rail tile",
		color = Color3.fromRGB(255, 150, 150) },
	{ name = "stack_after_hidden", hidden = true,
		caption = "AFTER -- the stack steps aside while the panel is open",
		color = Color3.fromRGB(160, 255, 180) },
}) do
	table.insert(views, {
		name = variant.name,
		settle = 1.4,
		setup = function(_, camera)
			sky(camera)
			local root = gui()
			local screen = screenOf(root, camera, OLIVER, variant.caption, variant.color)
			local shell = MenuShell.new({ parent = screen, title = "BRAIN ROT ROYALE", viewport = OLIVER.size })
			shell:SetViewport(OLIVER.size, OLIVER.touch)
			shell:SetDestinations(DESTINATIONS, "Brainrots")
			wallet(shell)
			fill(shell)
			shell:Open()
			local toggle = MenuStackToggle.new(screen, { items = stackItems(screen) })
			-- `hidden` is what the fix does when the panel opens; false is what shipped.
			toggle:SetHidden(variant.hidden)
			note(string.format("%s: stack hidden = %s, tab visible = %s, panel %dx%d on a %dx%d screen",
				variant.name, tostring(variant.hidden), tostring(toggle.tab.Visible),
				shell.panel.Size.X.Offset, shell.panel.Size.Y.Offset, OLIVER.size.X, OLIVER.size.Y))
		end,
	})
end

local PHONE = SCREENS[4]

local OPTIONS = {
	{
		name = "shortopt_A_8dest_2col",
		caption = "OPTION A -- all 8, two columns of icons",
		destinations = DESTINATIONS,
		columns = 2,
	},
	{
		name = "shortopt_B_5dest_1col",
		caption = "OPTION B -- the tall set of 5, one column",
		destinations = FIVE,
		columns = 1,
	},
	{
		name = "shortopt_C_5dest_2col",
		caption = "OPTION C -- the tall set of 5, two columns",
		destinations = FIVE,
		columns = 2,
	},
}

for _, option in ipairs(OPTIONS) do
	table.insert(views, {
		name = option.name,
		settle = 1.2,
		setup = function(_, camera)
			sky(camera)
			local root = gui()
			local screen = screenOf(root, camera, PHONE, option.caption .. "   (PROPOSAL, not in the build)", Color3.fromRGB(255, 226, 150))
			local shell = MenuShell.new({ parent = screen, title = "BRAIN ROT ROYALE", viewport = PHONE.size })
			shell:SetViewport(PHONE.size, PHONE.touch)
			shell:SetDestinations(option.destinations, option.destinations[1].key)
			local stack = columnRail(shell, option.destinations, option.columns)
			wallet(shell)
			fill(shell)
			shell:Open()
			local window = navWindow(shell)
			note(string.format(
				"%s: %d destinations in %d column(s), tallest column %d px, nav window %d px, %s",
				option.name,
				#option.destinations,
				option.columns,
				stack,
				window,
				stack <= window and "FITS" or "does not fit, scrolls"
			))
		end,
	})
end

return views
