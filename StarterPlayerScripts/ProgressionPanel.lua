-- The progression hub on the menu's Pass tab: a PASS | RANK | MASTERY | INDEX | CELL SHOP toggle,
-- and every page but PASS drawn here. The numbers come from the profile's `progression` snapshot
-- (Shared/ProgressionData.Snapshot) and are worked out with the same ProgressionData functions the
-- server uses.
--
-- A ModuleScript rather than part of MenuClient so tools/progression_gallery.lua can build the real
-- pages in edit mode and screenshot them.
--
--   ProgressionPanel.Render(content, profile, ctx)
--     Draws the toggle row into `content` (the menu's list), then the chosen page. Returns true when
--     it drew a page, meaning the Pass tab should draw nothing else; false on PASS.
--     ctx.rerender()  redraws the tab (after a server answer lands)
--     ctx.now         optional clock override, for the gallery
--   ProgressionPanel.View / SetView(name)   "Pass", "Rank", "Mastery", "Index" or "Shop"
--
-- Every server call shows its own answer on the page: success in green, a refusal in red. (The
-- menu's shared invoke() throws results away, so these calls don't use it.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))

local create, rounded, formatNumber = UiKit.create, UiKit.rounded, UiKit.formatNumber
local C = UiKit.Colors

local ProgressionPanel = {}

-- Style tokens. Everything else comes from UiKit.Colors (C). A menu-wide restyle should only need to
-- change UiKit and this block: these are the panel's only own colours and fonts.
local BRAIN = Color3.fromRGB(255, 150, 176) -- Brain Cells: the currency's colour
local BRAIN_DARK = Color3.fromRGB(120, 44, 70)
local DIM = Color3.fromRGB(70, 74, 92) -- locked / not yet earned outlines
local BLACK = Color3.new(0, 0, 0) -- text on bright buttons
local FONT = {
	Display = Enum.Font.FredokaOne, -- big numbers and headings
	Bold = Enum.Font.GothamBold, -- labels and buttons
	Body = Enum.Font.Gotham, -- descriptions
}

-- `short` is used when five tabs have to share a phone's width in portrait. "CELL SHOP" at 55 px
-- would be clipped to "CELL S", which reads as a different word rather than a shorter one.
local VIEWS = {
	{ key = "Pass", label = "PASS", short = "PASS" },
	{ key = "Rank", label = "RANK", short = "RANK" },
	{ key = "Mastery", label = "MASTERY", short = "GUNS" },
	{ key = "Index", label = "INDEX", short = "INDEX" },
	{ key = "Shop", label = "CELL SHOP", short = "SHOP" },
}

ProgressionPanel.View = "Pass"
-- Mastery list filter ("All" or a rarity) and the Index page on show.
ProgressionPanel.MasteryFilter = "All"
ProgressionPanel.IndexRarity = "Common"

-- The last server answer: { text, ok, at }. Shown for STATUS_SECONDS.
local status = nil
local STATUS_SECONDS = 6
-- PRESTIGE takes two presses: the first arms it for CONFIRM_SECONDS.
local prestigeArmedAt = nil
local CONFIRM_SECONDS = 5
-- One call at a time, so a double-click can't send twice.
local busy = false

-- When the current snapshot arrived, to tick the shop countdown down between pushes.
local snapshotSeen, snapshotAt = nil, 0

function ProgressionPanel.SetView(name)
	for _, view in ipairs(VIEWS) do
		if view.key == name then
			ProgressionPanel.View = name
			return true
		end
	end
	return false
end

local function now(ctx)
	return ctx and ctx.now or os.clock()
end

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5))
end

--------------------------------------------------------------------------------
-- How much room the page has
--------------------------------------------------------------------------------
-- The menu's list is 728 wide on a desktop, 603 on a landscape phone and as little as 296 in
-- portrait. Rows here used to size their text as `UDim2.new(1, -350, ...)`, which is right at 728 and
-- NEGATIVE at 296 -- and a negative width in Roblox doesn't truncate the text, it draws nothing at
-- all, so the row goes blank with no sign of what happened. Everything now measures instead, and
-- below NARROW the pages stop laying out in columns and stack (Oliver: "simplify the hud to make it
-- fit"). tools/progression_width_probe.lua renders every page from 728 down to 296 and fails on
-- anything that comes out at zero.
local page = { width = 728, narrow = false, mode = "large" }

-- Which VERSION of the pages a device gets: `large`, `short` or `tall`. Oliver asked for separate
-- versions rather than one layout shrinking through breakpoints, and the decision has to be one
-- function the menu shell and these pages both call, or the shell places a page one version thinks it
-- is in while the page draws another. `UiKit.form(viewport)` is that function (claude-ee's, ruled by
-- claude-43); this defers to it and falls back to the same rule until it lands.
--
-- The names say WHICH DIMENSION RAN OUT, which is the whole insight: a 768x1024 tablet in portrait
-- has 728 px of panel and is `large`, not small, because nothing has run out. `tall` is a screen
-- whose width ran out (a phone in portrait, 296-350 px of content) and `short` one whose height did
-- (an 844x390 phone in landscape: desktop-wide, almost no rows).
-- Set by tools/progression_width_probe.lua only, to render a version this machine's window can't
-- produce: `short` depends on the viewport's HEIGHT, and a probe frame can only choose a width.
-- Game code never sets it.
ProgressionPanel.ViewportForTest = nil

local function modeFor(width)
	local camera = workspace.CurrentCamera
	local viewport = ProgressionPanel.ViewportForTest or (camera and camera.ViewportSize) or Vector2.new(1920, 1080)
	-- The measured width of the LIST these pages draw into, not the viewport: a row inside a 356 px
	-- card is `tall` on a 1920 monitor, because the row has 356 px whatever the screen has.
	return UiKit.form(viewport, width)
end

local function measure(content)
	-- AbsoluteSize is 0 for a frame that hasn't been laid out yet (the first render of a fresh menu),
	-- and a 0 would make every row take its minimum. The desktop width is the safer guess, and the
	-- watcher below redraws the moment the real size arrives.
	local width = content.AbsoluteSize.X
	page.width = width > 0 and width or 728
	page.mode = modeFor(page.width)
	-- `narrow` is the stacked version, which is what a screen out of WIDTH needs. A `short` screen has
	-- the width for the large layout and wants fewer, flatter rows instead -- a different job, not this
	-- one, so it keeps the large layout until that version is built rather than being handed a stacked
	-- page 780 px wide.
	page.narrow = page.mode == "tall"
	-- What the last render actually measured, so tools/progression_width_probe.lua can prove it drew
	-- the page at the width it meant to rather than at the fallback.
	ProgressionPanel.LastWidth = page.width
	ProgressionPanel.LastMode = page.mode
	return page
end

-- The width of a column starting at `left` that keeps `right` px clear on the other side. Never
-- returns less than `minimum`, so a row can be tight or clipped but never invisible.
--
-- Everything on these pages sits inside a card or a row built as `UDim2.new(1, -CARD_INSET, ...)`,
-- so the room a column really has is the page minus that inset. Measuring against the page itself
-- would make every column 8 px too wide -- invisible at 728, an overlap at 296.
local CARD_INSET = 8
local function span(left, right, minimum)
	return math.max(minimum or 80, page.width - CARD_INSET - left - (right or 14))
end

-- True when a column starting at `left` with `right` px kept clear really has `needed` px, before any
-- minimum is applied. `span` floors its result so nothing can vanish, but a floored width is a column
-- overlapping its neighbour -- fine for a label on its own, wrong for a secondary one that would sit
-- on top of the numbers beside it. Those ask this first and are dropped when the answer is no. It
-- matters at the boundary: `large` starts at 600 px of content, not 728, and a 603 px landscape phone
-- has 133 px less room than the layout was drawn against.
local function roomFor(left, right, needed)
	return page.width - CARD_INSET - left - right >= needed
end

-- Redraw when the menu changes width, once per content frame: the pages pick a different shape either
-- side of NARROW, and a player who rotates their phone would otherwise keep the old one until
-- something else happened to redraw.
local watched = setmetatable({}, { __mode = "k" })
local function watchWidth(content, ctx)
	if watched[content] or not (ctx and ctx.rerender) then
		return
	end
	watched[content] = true
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local width = content.AbsoluteSize.X
		if width > 0 and modeFor(width) ~= page.mode then
			ctx.rerender()
		end
	end)
end

local function label(parent, props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT.Bold
	props.TextColor3 = props.TextColor3 or C.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.Parent = parent
	return create("TextLabel", props)
end

local function card(content, order, height, stroke)
	local frame = create("Frame", {
		Size = UDim2.new(1, -8, 0, height),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = content,
	}, { rounded(10) })
	if stroke then
		create("UIStroke", { Color = stroke, Thickness = 1.5, Transparency = 0.45, Parent = frame })
	end
	return frame
end

local function button(parent, props, enabled, color, onClick)
	props.BackgroundColor3 = enabled and color or C.PanelAlt
	props.BorderSizePixel = 0
	props.Font = props.Font or FONT.Bold
	props.TextColor3 = enabled and BLACK or C.Muted
	props.TextSize = props.TextSize or 13
	props.AutoButtonColor = enabled
	props.Parent = parent
	local instance = create("TextButton", props, { rounded(8) })
	if enabled and onClick then
		instance.Activated:Connect(onClick)
	end
	return instance
end

-- The fill is named so tools/progression_width_probe.lua can tell a bar at 0%% -- which is legitimately
-- zero pixels wide -- from a row that vanished because its width went negative.
local function bar(parent, props, ratio, color)
	local back = create("Frame", {
		Name = "Meter",
		Position = props.Position,
		Size = props.Size,
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Parent = parent,
	}, { rounded(props.radius or 6) })
	create("Frame", {
		Name = "MeterFill",
		Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = back,
	}, { rounded(props.radius or 6) })
	return back
end

-- A little pink brain-cell coin: the currency's icon everywhere on these pages.
-- Upgraded 2026-09-22 (Oliver: "upgrade the icons in the progression menu"): a minted coin rather
-- than a flat disc -- a lit face, a darker rim, a highlight, and a little brain in place of the "b".
local function cellIcon(parent, size, position)
	local icon = create("Frame", {
		Position = position,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = BRAIN,
		BorderSizePixel = 0,
		Parent = parent,
	}, { rounded(size) })
	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 196, 212), Color3.fromRGB(232, 104, 140)),
		Parent = icon,
	})
	create("UIStroke", { Color = BRAIN_DARK, Thickness = math.max(1, size / 10), Parent = icon })
	-- The inner ring of a struck coin.
	local face = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.74, 0.74),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = icon,
	}, { rounded(size) })
	create("UIStroke", { Color = Color3.fromRGB(255, 226, 234), Thickness = math.max(1, size / 20), Transparency = 0.35, Parent = face })
	-- Highlight, top left.
	create("Frame", {
		Position = UDim2.fromScale(0.2, 0.14),
		Size = UDim2.fromScale(0.3, 0.16),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Rotation = -30,
		Parent = icon,
	}, { rounded(size) })
	label(icon, {
		Size = UDim2.fromScale(1, 1),
		Font = FONT.Display,
		Text = "🧠",
		TextColor3 = BRAIN_DARK,
		TextSize = math.floor(size * 0.58),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	return icon
end

local function photo(parent, def, size, silhouette)
	local viewport = create("ViewportFrame", {
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(170, 170, 182),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Parent = parent,
	}, { rounded(10) })
	local model = BrainrotModels.Build(def)
	if silhouette then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Transparency < 1 then
				part.Color = Color3.fromRGB(16, 16, 22)
				part.Material = Enum.Material.SmoothPlastic
			end
		end
	end
	model.Parent = viewport
	BrainrotModels.FrameViewport(viewport, def)
	return viewport
end

-- The prestige emblem: a turned square in the prestige's colour with its number on top.
local function emblem(parent, prestige, size, position)
	local info = ProgressionData.PrestigeInfo(prestige)
	local holder = create("Frame", {
		Position = position,
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	local inner = size * 0.7
	local diamond = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(inner, inner),
		Rotation = 45,
		BackgroundColor3 = prestige > 0 and info.color or C.PanelAlt,
		BorderSizePixel = 0,
		Parent = holder,
	}, { rounded(math.floor(size * 0.12)) })
	create("UIStroke", { Color = prestige > 0 and C.Text or DIM, Thickness = 2, Transparency = prestige > 0 and 0.2 or 0, Parent = diamond })
	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 180)),
		Parent = diamond,
	})
	if prestige > 0 then
		-- An outer frame a step out from the gem, in the prestige colour, and a soft glow behind.
		local glow = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(size * 0.98, size * 0.98),
			BackgroundColor3 = info.color,
			BackgroundTransparency = 0.8,
			BorderSizePixel = 0,
			Parent = holder,
		}, { rounded(size) })
		-- Behind the gem and the number, which are its siblings.
		glow.ZIndex = diamond.ZIndex - 1
		local frame = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(inner * 1.2, inner * 1.2),
			Rotation = 45,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = holder,
		}, { rounded(math.floor(size * 0.14)) })
		create("UIStroke", { Color = info.color, Thickness = math.max(1, size / 28), Transparency = 0.25, Parent = frame })
		-- A light facet across the top half of the gem.
		create("Frame", {
			Position = UDim2.fromScale(0, 0),
			Size = UDim2.fromScale(0.5, 0.5),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.7,
			BorderSizePixel = 0,
			Parent = diamond,
		}, { rounded(math.floor(size * 0.1)) })
		if prestige >= 5 then
			label(holder, {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, -math.floor(size * 0.12)),
				Size = UDim2.fromOffset(size, math.floor(size * 0.3)),
				Font = FONT.Display,
				Text = prestige >= 10 and "★★★" or "★",
				TextColor3 = Color3.fromRGB(255, 220, 90),
				TextSize = math.floor(size * 0.24),
				TextXAlignment = Enum.TextXAlignment.Center,
			})
		end
	end
	label(holder, {
		Size = UDim2.fromScale(1, 1),
		Font = FONT.Display,
		Text = prestige > 0 and tostring(prestige) or "—",
		TextColor3 = prestige > 0 and BLACK or C.Muted,
		TextSize = math.floor(size * 0.36),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	return holder
end

local function cosmeticName(entry)
	local item = entry and CosmeticData.Get(entry.id)
	if not item then
		return "reward"
	end
	local kindWord = item.kind == "GunSkin" and "gun skin" or string.lower(item.kind)
	-- "Silver Rot Aura", not "Silver Rot Aura aura".
	if string.find(string.lower(item.name), string.lower(item.kind == "GunSkin" and "skin" or item.kind), 1, true) then
		return item.name
	end
	return string.format("%s %s", item.name, kindWord)
end

-- A rank cosmetic as a small tile: a gun silhouette in the skin's colour, or a glowing ring for an
-- aura, with a caption on top and the name underneath. Dimmed until owned, unless `forSale` (a shop
-- listing, where it should look its best and needs no tick).
local function cosmeticSwatch(parent, item, isOwned, caption, width, height, forSale)
	local tile = create("Frame", {
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = isOwned and C.PanelAlt or C.Panel,
		BorderSizePixel = 0,
		Parent = parent,
	}, { rounded(10) })
	create("UIStroke", { Color = isOwned and item.color or DIM, Thickness = isOwned and 2 or 1, Transparency = isOwned and 0.1 or 0.3, Parent = tile })
	label(tile, {
		Position = UDim2.fromOffset(0, 5),
		Size = UDim2.new(1, 0, 0, 13),
		Text = caption,
		TextColor3 = isOwned and C.Text or C.Muted,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	local art = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 22),
		Size = UDim2.fromOffset(44, 34),
		BackgroundTransparency = 1,
		Parent = tile,
	})
	local fade = (isOwned or forSale) and 0 or 0.55
	-- The real thing, turning, through Shared/CosmeticPreview (the same builder the shop uses). The flat
	-- drawing below is only the fallback if the preview module can't load.
	local okPreview, preview = pcall(require, Shared:WaitForChild("CosmeticPreview"))
	if okPreview and preview and item.id then
		art.Position = UDim2.new(0.5, 0, 0, 20)
		art.Size = UDim2.fromOffset(math.min(width - 10, 58), math.min(height - 38, 44))
		create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = art })
		local shown = pcall(preview.Fill, art, item.id, { background = C.Panel, backgroundTransparency = 1 })
		if shown then
			local viewport = art:FindFirstChild("CosmeticPreview")
			if viewport and not (isOwned or forSale) then
				-- Not earned yet: the same model, dimmed.
				viewport.ImageTransparency = 0.45
				viewport.ImageColor3 = Color3.fromRGB(150, 150, 165)
			end
		end
		if shown then
			if forSale then
				return tile
			end
			label(tile, {
				Position = UDim2.new(0, 3, 1, -34),
				Size = UDim2.new(1, -6, 0, 28),
				Font = FONT.Bold,
				Text = isOwned and ("✓ " .. item.name) or item.name,
				TextColor3 = isOwned and C.Green or C.Muted,
				TextWrapped = true,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			return tile
		end
	end
	if item.kind == "Aura" then
		local ring = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = item.color,
			BackgroundTransparency = 0.55 + fade * 0.4,
			BorderSizePixel = 0,
			Parent = art,
		}, { rounded(15) })
		create("UIStroke", { Color = item.color, Thickness = 3, Transparency = fade, Parent = ring })
	else
		-- Body, barrel and grip.
		for _, piece in ipairs({ { 4, 10, 30, 10 }, { 32, 12, 12, 5 }, { 8, 19, 8, 12 } }) do
			create("Frame", {
				Position = UDim2.fromOffset(piece[1], piece[2]),
				Size = UDim2.fromOffset(piece[3], piece[4]),
				BackgroundColor3 = item.color,
				BackgroundTransparency = fade,
				BorderSizePixel = 0,
				Parent = art,
			}, { rounded(2) })
		end
	end
	if forSale then
		return tile
	end
	label(tile, {
		Position = UDim2.new(0, 3, 1, -34),
		Size = UDim2.new(1, -6, 0, 28),
		Font = FONT.Bold,
		Text = isOwned and not forSale and ("✓ " .. item.name) or item.name,
		TextColor3 = isOwned and not forSale and C.Green or C.Muted,
		TextWrapped = true,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	return tile
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return string.format("%dh %02dm", seconds // 3600, (seconds % 3600) // 60)
	end
	return string.format("%dm %02ds", seconds // 60, seconds % 60)
end

--------------------------------------------------------------------------------
-- Server calls
--------------------------------------------------------------------------------

-- Invokes a progression remote off the render thread and shows its answer on the page.
local function call(ctx, remoteName, ...)
	if busy then
		return
	end
	busy = true
	local args = table.pack(...)
	task.spawn(function()
		local ok, success, message = pcall(function()
			local Remotes = require(Shared:WaitForChild("Remotes"))
			return Remotes.Function(remoteName):InvokeServer(table.unpack(args, 1, args.n))
		end)
		busy = false
		if not ok then
			status = { text = "Couldn't reach the server. Try again.", ok = false, at = os.clock() }
		else
			status = { text = tostring(message or (success and "Done." or "Couldn't do that.")), ok = success == true, at = os.clock() }
		end
		pcall(function()
			local Sfx = require(script.Parent:WaitForChild("Sfx"))
			Sfx.Play(status.ok and "Gold" or "UiClick", 0.05)
		end)
		if ctx and ctx.rerender then
			ctx.rerender()
		end
	end)
end

local function click()
	pcall(function()
		require(script.Parent:WaitForChild("Sfx")).Play("UiClick", 0.08)
	end)
end

--------------------------------------------------------------------------------
-- Toggle row and status line
--------------------------------------------------------------------------------

local function claimableCount(progression)
	local count = 0
	for _, state in pairs(progression.index) do
		if state == ProgressionData.Recorded then
			count += 1
		end
	end
	return count
end

local function renderToggle(content, progression, ctx)
	-- Wide: five tabs with the Brain Cells chip beside them. Narrow: the chip takes its own line and
	-- the tabs share the full width below it, with short labels, because five tabs and a 172 px chip
	-- on one 296 px line is how you get tabs nobody can read or hit.
	local narrow = page.narrow
	local tabPad = narrow and 4 or 6
	local tabWidth = narrow and math.max(46, math.floor((span(0, 8, 260) - tabPad * 4) / 5)) or nil
	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, narrow and 82 or 40),
		BackgroundTransparency = 1,
		LayoutOrder = -1000,
		Parent = content,
	})
	local strip = create("Frame", {
		Position = narrow and UDim2.fromOffset(0, 42) or UDim2.new(),
		Size = narrow and UDim2.new(1, 0, 0, 36) or UDim2.fromOffset(span(0, 188, 200), 40),
		BackgroundTransparency = 1,
		Parent = row,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, tabPad),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local claimable = progression and claimableCount(progression) or 0
	for index, view in ipairs(VIEWS) do
		-- Each page is its own menu tab now (MenuClient, Oliver 09-22 14:15), so the in-page tabs are
		-- skipped and only the Brain Cells chip is drawn.
		if ctx and ctx.noTabs then
			break
		end
		local selected = ProgressionPanel.View == view.key
		local text = narrow and view.short or view.label
		-- A count fits on a 96 px tab and not on a 54 px one: "INDEX 10" measured 52 px wide in the
		-- probe, which is a tab you can see is there and can't read. Narrow keeps the word and says
		-- "there is something here" with a dot instead, which is the part that has to survive.
		local dot = false
		if view.key == "Index" and claimable > 0 then
			text = narrow and view.short or string.format("INDEX  %d", claimable)
			dot = narrow
		elseif view.key == "Rank" and progression and progression.canPrestige then
			text = narrow and view.short or "RANK  !"
			dot = narrow
		end
		local tab = create("TextButton", {
			Size = UDim2.fromOffset(tabWidth or (view.key == "Shop" and 104 or 96), 36),
			TextSize = narrow and 11 or 13,
			BackgroundColor3 = selected and BRAIN or C.Panel,
			BorderSizePixel = 0,
			Font = FONT.Bold,
			Text = text,
			TextColor3 = selected and BLACK or ((view.key == "Index" and claimable > 0) and C.Green or C.Muted),
			LayoutOrder = index,
			Parent = strip,
		}, { rounded(8) })
		if dot then
			create("Frame", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -6, 0, 6),
				Size = UDim2.fromOffset(8, 8),
				BackgroundColor3 = view.key == "Index" and C.Green or C.Accent,
				BorderSizePixel = 0,
				Parent = tab,
			}, { rounded(4) })
		end
		tab.Activated:Connect(function()
			click()
			ProgressionPanel.View = view.key
			prestigeArmedAt = nil
			if ctx and ctx.rerender then
				ctx.rerender()
			end
		end)
	end

	local chip = create("Frame", {
		AnchorPoint = narrow and Vector2.zero or Vector2.new(1, 0),
		Position = narrow and UDim2.new() or UDim2.new(1, 0, 0, 0),
		Size = narrow and UDim2.fromOffset(span(0, 8, 160), 36) or UDim2.fromOffset(172, 36),
		BackgroundColor3 = C.Background,
		BorderSizePixel = 0,
		Parent = row,
	}, { rounded(8) })
	create("UIStroke", { Color = BRAIN, Thickness = 1.5, Transparency = 0.4, Parent = chip })
	cellIcon(chip, 22, UDim2.fromOffset(9, 7))
	label(chip, {
		Position = UDim2.fromOffset(38, 0),
		Size = UDim2.new(1, -46, 1, 0),
		Font = FONT.Display,
		Text = progression and formatNumber(progression.cells) or "…",
		TextColor3 = BRAIN,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	if status and os.clock() - status.at < STATUS_SECONDS and ProgressionPanel.View ~= "Pass" then
		label(content, {
			Size = UDim2.new(1, -8, 0, 22),
			LayoutOrder = -999,
			Font = FONT.Bold,
			Text = status.text,
			TextColor3 = status.ok and C.Green or C.Red,
			TextSize = 14,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
	end
end

local function sectionHeader(content, order, text, color)
	return label(content, {
		Size = UDim2.new(1, -8, 0, 28),
		LayoutOrder = order,
		Font = FONT.Display,
		Text = text,
		TextColor3 = color or C.Accent,
		TextSize = 17,
		TextYAlignment = Enum.TextYAlignment.Bottom,
	})
end

local function footnote(content, order, text)
	return label(content, {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Font = FONT.Body,
		Text = text,
		TextColor3 = C.Muted,
		TextWrapped = true,
		TextSize = 12,
	})
end

--------------------------------------------------------------------------------
-- RANK
--------------------------------------------------------------------------------

local function renderRank(content, progression, ctx, owned)
	local prestige = progression.prestige
	local info = ProgressionData.PrestigeInfo(prestige)
	local rank = progression.rank
	local atMax = rank >= ProgressionData.MaxRank

	-- Wide: the emblem, the rank beside it, and the lifetime numbers in a right-hand column.
	-- Narrow: a smaller emblem, the rank taking all the room left, and the lifetime numbers as one
	-- row underneath. The column is what gets dropped, because squeezing it costs the rank itself.
	local narrow = page.narrow
	-- A screen that ran out of HEIGHT gets fewer and flatter rows rather than narrower ones: the hero
	-- loses the lifetime numbers (they are a record, not a goal) and the COMING UP track goes below the
	-- fold, so rank, progress and PRESTIGE are all on the first screen. Content height on a 500 px
	-- viewport is about 270 px, against roughly 430 for the large layout.
	local short = page.mode == "short"
	local emblemSize = narrow and 64 or (short and 72 or 104)
	local textLeft = 14 + emblemSize + (narrow and 10 or 14)
	-- Short keeps 178 clear on the right for the PRESTIGE button that moves into the hero.
	local statsColumn = narrow and 0 or (short and 178 or 214)
	-- 116 on short, not 108: the bar sits 32 px off the bottom and the "XP to rank N" line ends at 80,
	-- so 108 had them overlapping -- visible in the gallery render, not in the arithmetic I did first.
	local hero = card(content, 1, narrow and 196 or (short and 116 or 158), prestige > 0 and info.color or C.Accent)
	emblem(hero, prestige, emblemSize, UDim2.fromOffset(14, 12))

	local headWidth = span(textLeft, statsColumn + 14, 90)
	label(hero, {
		Position = UDim2.fromOffset(textLeft, 12),
		Size = UDim2.fromOffset(headWidth, 18),
		Text = prestige > 0 and string.format("PRESTIGE %d  •  %s", prestige, string.upper(info.name)) or "NO PRESTIGE YET",
		TextColor3 = prestige > 0 and info.color or C.Muted,
		TextSize = 13,
	})
	label(hero, {
		Position = UDim2.fromOffset(textLeft - 2, narrow and 28 or 30),
		Size = UDim2.fromOffset(headWidth, narrow and 38 or (short and 34 or 50)),
		Font = FONT.Display,
		RichText = true,
		Text = string.format('ROT RANK <font color="%s">%d</font>', hex(C.Accent), rank),
		TextSize = narrow and 28 or (short and 26 or 40),
	})
	label(hero, {
		Position = UDim2.fromOffset(textLeft, narrow and 68 or (short and 64 or 80)),
		Size = UDim2.fromOffset(headWidth, narrow and 32 or 18),
		Font = FONT.Body,
		Text = atMax and (progression.canPrestige and "Max rank — prestige to climb again with bigger rewards."
			or "Max rank at max prestige. Extra XP keeps paying Brain Cells.")
			or string.format("%s XP to rank %d", ProgressionData.Commas(progression.xpNeed - progression.xpInto), rank + 1),
		TextColor3 = C.Muted,
		TextWrapped = narrow,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 13,
	})

	-- Lifetime numbers: a right-hand column when there's room, a row under the rank when there isn't.
	local stats = {
		{ "LIFETIME XP", formatNumber(progression.total) },
		{ "CELLS EARNED", formatNumber(progression.cellsEarned) },
		{ "RANK CELL BONUS", string.format("+%d%%", math.floor((ProgressionData.PrestigeMultiplier(prestige) - 1) * 100 + 0.5)) },
	}
	local statWidth = narrow and math.max(64, math.floor((span(14, 14, 200) - 16) / 3)) or 200
	for index, stat in ipairs(short and {} or stats) do
		local statX = narrow and (14 + (index - 1) * (statWidth + 8)) or 0
		local statY = narrow and 116 or (12 + (index - 1) * 30)
		label(hero, {
			AnchorPoint = narrow and Vector2.zero or Vector2.new(1, 0),
			Position = narrow and UDim2.fromOffset(statX, statY) or UDim2.new(1, -14, 0, statY),
			Size = UDim2.fromOffset(statWidth, 12),
			Text = stat[1],
			TextColor3 = C.Muted,
			TextSize = 10,
			TextXAlignment = narrow and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		})
		label(hero, {
			AnchorPoint = narrow and Vector2.zero or Vector2.new(1, 0),
			Position = narrow and UDim2.fromOffset(statX, statY + 13) or UDim2.new(1, -14, 0, statY + 11),
			Size = UDim2.fromOffset(statWidth, 18),
			Font = FONT.Display,
			Text = stat[2],
			TextColor3 = index == 2 and BRAIN or C.Text,
			TextSize = narrow and 15 or 17,
			TextXAlignment = narrow and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		})
	end

	-- XP bar: into this rank, or the overflow toward the next Cells payout at max rank.
	local ratio, barText, barColor
	if atMax then
		ratio = progression.over / ProgressionData.OverflowXp
		barText = string.format("OVERFLOW  %s / %s XP  →  +%s", ProgressionData.Commas(progression.over),
			ProgressionData.Commas(ProgressionData.OverflowXp), ProgressionData.Cells(ProgressionData.OverflowReward(prestige)))
		barColor = BRAIN
	else
		ratio = progression.xpInto / progression.xpNeed
		barText = string.format("%s / %s XP", ProgressionData.Commas(progression.xpInto), ProgressionData.Commas(progression.xpNeed))
		barColor = C.Accent
	end
	-- Short keeps the bar clear of the PRESTIGE button that moved into this card; wide it spans the lot.
	local barWidth = short and span(14, statsColumn + 14, 120) or nil
	local barY = short and -32 or -40
	bar(hero, {
		Position = UDim2.new(0, 14, 1, barY),
		Size = barWidth and UDim2.fromOffset(barWidth, 26) or UDim2.new(1, -28, 0, 26),
		radius = 8,
	}, ratio, barColor)
	label(hero, {
		Position = UDim2.new(0, 14, 1, barY),
		Size = barWidth and UDim2.fromOffset(barWidth, 26) or UDim2.new(1, -28, 0, 26),
		Text = barText,
		TextSize = 13,
		TextStrokeTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	-- The next rewards along the track. On a short screen this moves BELOW the prestige card: it is
	-- the thing a player reads once a session, and PRESTIGE is the thing they came to press.
	-- 7 and 8 on a short screen, not 5 and 6: PRESTIGE REWARDS already owns those, and a tie in
	-- LayoutOrder is resolved by name, which is not an order anyone chose.
	sectionHeader(content, short and 7 or 2, "COMING UP")
	local track = create("Frame", {
		LayoutOrder = short and 8 or 3,
		Size = UDim2.new(1, -8, 0, 96),
		BackgroundTransparency = 1,
		Parent = content,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	-- The next four ranks, then the next milestones after them (crates and the big Cell payouts at
	-- every tenth rank), so a goal a few hours away is always on screen.
	local firstRank = atMax and (progression.canPrestige and 2 or nil) or rank + 1
	local nextPrestige = atMax and progression.canPrestige and prestige + 1 or prestige
	local upcoming = {}
	if firstRank then
		for candidate = firstRank, ProgressionData.MaxRank do
			local isMilestone = ProgressionData.RankCrates[candidate] ~= nil or candidate % 10 == 0 or candidate % 25 == 0
			if candidate < firstRank + 4 or isMilestone then
				table.insert(upcoming, candidate)
			end
			-- Seven tiles need 700 px. Narrow, three fill the width instead of seven spilling off it; in
			-- between (a landscape phone's 632 px) as many as fit, which tools/menu_screens_check.py
			-- found running two tiles off the side.
			if #upcoming >= (narrow and 3 or math.clamp(math.floor((page.width - CARD_INSET + 6) / 103), 3, 7)) then
				break
			end
		end
	end
	local shown = 0
	for index, nextRank in ipairs(upcoming) do
		local reward = ProgressionData.RankReward(nextRank, nextPrestige)
		local milestone = reward.crate or nextRank % 25 == 0 or nextRank % 10 == 0
		local skipped = index > 1 and nextRank > upcoming[index - 1] + 1
		local tile = create("Frame", {
			Size = UDim2.fromOffset(narrow and math.max(80, math.floor((span(0, 8, 260) - 12) / 3)) or 97, 96),
			BackgroundColor3 = milestone and C.PanelAlt or C.Panel,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = track,
		}, { rounded(10) })
		if milestone then
			create("UIStroke", { Color = reward.crate and C.Accent or BRAIN, Thickness = 1.5, Transparency = 0.3, Parent = tile })
		end
		label(tile, {
			Position = UDim2.fromOffset(0, 8),
			Size = UDim2.new(1, 0, 0, 14),
			Text = (skipped and "… " or "") .. (atMax and string.format("P%d  RANK %d", nextPrestige, nextRank) or ("RANK " .. nextRank)),
			TextColor3 = milestone and C.Text or C.Muted,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		local amount = create("Frame", {
			Position = UDim2.fromOffset(0, 30),
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			Parent = tile,
		}, {
			create("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 5),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		cellIcon(amount, 18, UDim2.new()).LayoutOrder = 1
		label(amount, {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 24),
			Font = FONT.Display,
			Text = formatNumber(reward.cells),
			TextColor3 = BRAIN,
			TextSize = 20,
			LayoutOrder = 2,
		})
		label(tile, {
			Position = UDim2.fromOffset(4, 60),
			Size = UDim2.new(1, -8, 0, 28),
			Font = FONT.Bold,
			Text = reward.crate and (string.upper(reward.crate) .. " CRATE") or (milestone and "BIG PAYOUT" or ""),
			TextColor3 = reward.crate and Rarity.Color(reward.crate) or BRAIN,
			TextWrapped = true,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		shown += 1
	end
	if shown == 0 then
		label(track, {
			Size = UDim2.new(1, 0, 1, 0),
			Font = FONT.Body,
			Text = string.format("Nothing left to unlock. Every %s XP still pays %s.",
				ProgressionData.Commas(ProgressionData.OverflowXp), ProgressionData.Cells(ProgressionData.OverflowReward(prestige))),
			TextColor3 = C.Muted,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
	end

	-- Prestige. Narrow, the button can't sit beside the text -- it drops to its own full-width row
	-- underneath, which is also a bigger tap target than a 140 px button squeezed against the edge.
	local prestigeEmblem = narrow and 44 or 62
	local prestigeLeft = 12 + prestigeEmblem + 10
	local prestigeText = span(prestigeLeft, narrow and 14 or 166, 90)
	local prestigeCard = card(content, 4, narrow and 164 or 86, progression.canPrestige and info.color or nil)
	local nextInfo = ProgressionData.PrestigeInfo(math.min(prestige + 1, ProgressionData.MaxPrestige))
	emblem(prestigeCard, math.min(prestige + 1, ProgressionData.MaxPrestige), prestigeEmblem, UDim2.fromOffset(12, 12))
	label(prestigeCard, {
		Position = UDim2.fromOffset(prestigeLeft, 12),
		Size = UDim2.fromOffset(prestigeText, 22),
		Font = FONT.Display,
		Text = prestige >= ProgressionData.MaxPrestige and "MAX PRESTIGE" or string.format("PRESTIGE %d  •  %s", prestige + 1, nextInfo.name),
		TextColor3 = prestige >= ProgressionData.MaxPrestige and info.color or nextInfo.color,
		TextSize = 19,
	})
	label(prestigeCard, {
		Position = UDim2.fromOffset(narrow and 14 or prestigeLeft, narrow and 62 or 36),
		Size = UDim2.fromOffset(narrow and span(14, 14, 120) or prestigeText, narrow and 44 or 40),
		Font = FONT.Body,
		Text = prestige >= ProgressionData.MaxPrestige and string.format("You've reached the top. Every %s XP from here still pays Brain Cells.", ProgressionData.Commas(ProgressionData.OverflowXp))
			or string.format("At rank %d: back to rank 1, every rank reward again with +%d%% Cells, plus %s Brain Cells, the %s and a new nameplate star. Cells, mastery and Index are kept.",
				ProgressionData.MaxRank, math.floor(ProgressionData.PrestigeCellBonus * 100 * (prestige + 1) + 0.5),
				ProgressionData.Commas(ProgressionData.PrestigeReward(prestige + 1).cells), cosmeticName(ProgressionData.PrestigeCosmetic(prestige + 1))),
		TextColor3 = C.Muted,
		TextWrapped = true,
		TextSize = 12,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local armed = prestigeArmedAt and os.clock() - prestigeArmedAt < CONFIRM_SECONDS
	-- On a short screen the button goes in the HERO, not in this card. An 844x390 phone gives the list
	-- 208 px: toggle, hero and this card come to about 250, so PRESTIGE would sit just below the fold —
	-- the one thing the short version exists to prevent. In the hero it lands at about 156. The card
	-- below keeps the explanation and loses its own button, because two buttons doing the same thing
	-- is worse than either.
	local prestigeHome = short and hero or prestigeCard
	button(prestigeHome, {
		AnchorPoint = (narrow and not short) and Vector2.zero or Vector2.new(1, 0.5),
		Position = short and UDim2.new(1, -14, 0.5, 0)
			or (narrow and UDim2.fromOffset(12, 108) or UDim2.new(1, -12, 0.5, 0)),
		Size = short and UDim2.fromOffset(150, 44)
			or (narrow and UDim2.fromOffset(span(12, 12, 120), 44) or UDim2.fromOffset(140, 44)),
		Text = not progression.canPrestige and (prestige >= ProgressionData.MaxPrestige and "MAXED" or "RANK " .. ProgressionData.MaxRank)
			or (armed and "CONFIRM?" or "PRESTIGE"),
		TextSize = 15,
	}, progression.canPrestige and not busy, armed and C.Red or info.color, function()
		click()
		if prestigeArmedAt and os.clock() - prestigeArmedAt < CONFIRM_SECONDS then
			prestigeArmedAt = nil
			call(ctx, "Prestige", prestige)
		else
			prestigeArmedAt = os.clock()
			if ctx and ctx.rerender then
				ctx.rerender()
			end
			task.delay(CONFIRM_SECONDS + 0.1, function()
				if prestigeArmedAt and os.clock() - prestigeArmedAt >= CONFIRM_SECONDS and ctx and ctx.rerender then
					prestigeArmedAt = nil
					ctx.rerender()
				end
			end)
		end
	end)

	-- Every prestige's cosmetic, owned or still to earn.
	sectionHeader(content, 5, "PRESTIGE REWARDS")
	-- A grid that wraps, not a row: ten 66 px tiles are 714 px, and in a row they ran off the side of
	-- every phone (tools/menu_screens_check.py, 313 px of content on a 390 px portrait phone).
	local strip = create("Frame", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 6,
		Parent = content,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.fromOffset(66, 92),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for level = 1, ProgressionData.MaxPrestige do
		local entry = ProgressionData.PrestigeCosmetic(level)
		local item = entry and CosmeticData.Get(entry.id)
		if item then
			local tile = cosmeticSwatch(strip, item, owned and owned[entry.id], "P" .. level, 66, 92)
			tile.LayoutOrder = level
		end
	end

	footnote(content, 7, "Rot Rank climbs with every bit of XP you earn: placements, eliminations, quests and challenges, "
		.. "plus a bonus each time a gun reaches a new mastery tier. The Brainrot Pass is unaffected. Brain Cells can't be bought "
		.. "with Robux, and no pass boosts them.")
end

--------------------------------------------------------------------------------
-- MASTERY
--------------------------------------------------------------------------------

local function renderMastery(content, progression, ctx, owned)
	local mastery = progression.mastery
	local tiers = ProgressionData.MasteryTiers
	-- Staged guns (not in loot yet) are left out, unless this player already has points on one.
	local weapons = ProgressionData.MasteryWeapons(mastery)

	local mastered, rotmasters, started = 0, 0, 0
	for _, id in ipairs(weapons) do
		local tier = ProgressionData.MasteryTier(mastery[id])
		if tier >= ProgressionData.MasteredTier then
			mastered += 1
		end
		if tier >= #tiers then
			rotmasters += 1
		end
		if (mastery[id] or 0) > 0 then
			started += 1
		end
	end

	-- Narrow: the three numbers share the width, the six tier pills wrap onto two rows, and the
	-- explainer on the right is dropped -- the pills below it say the same thing in numbers.
	local narrow = page.narrow
	-- Short: the three numbers, no tier ladder. The ladder is reference a player reads once; the
	-- numbers are the progress they came back for.
	local short = page.mode == "short"
	local statWidth = narrow and math.floor((span(14, 14, 120) - 12) / 3) or 124
	local statStep = statWidth + 6
	local pillColumns = narrow and 3 or 6
	-- Six 110 px pills are 690 px; a tablet's content is 683, so wide they shrink to what fits rather
	-- than the last one running off the card.
	local pillWidth = math.min(110, math.floor((span(14, 14, 120) - 6 * (pillColumns - 1)) / pillColumns))
	local pillStep = pillWidth + 6
	local summary = card(content, 1, narrow and 148 or (short and 52 or 92), C.Accent)
	-- "GOLD OR BETTER" is 96 px of text in an 81 px column, so narrow it ran into the heading beside
	-- it. The short forms say the same thing in the room there is.
	local numbers = narrow and {
		{ "GUNS", string.format("%d / %d", started, #weapons) },
		{ "GOLD+", string.format("%d / %d", mastered, #weapons) },
		{ "ROTMASTER", tostring(rotmasters) },
	} or {
		{ "GUNS USED", string.format("%d / %d", started, #weapons) },
		{ "GOLD OR BETTER", string.format("%d / %d", mastered, #weapons) },
		{ "ROTMASTER", tostring(rotmasters) },
	}
	for index, entry in ipairs(numbers) do
		label(summary, {
			Position = UDim2.fromOffset(14 + (index - 1) * statStep, 10),
			Size = UDim2.fromOffset(statWidth, 12),
			Text = entry[1],
			TextColor3 = C.Muted,
			TextSize = 10,
		})
		label(summary, {
			Position = UDim2.fromOffset(14 + (index - 1) * statStep, 22),
			Size = UDim2.fromOffset(statWidth, 26),
			Font = FONT.Display,
			Text = entry[2],
			TextColor3 = index == 3 and tiers[#tiers].color or C.Text,
			TextSize = 22,
		})
	end
	-- The tier ladder.
	for index, tier in ipairs(short and {} or tiers) do
		local column = (index - 1) % pillColumns
		local pillRow = math.floor((index - 1) / pillColumns)
		local pill = create("Frame", {
			Position = UDim2.fromOffset(14 + column * pillStep, 56 + pillRow * 32),
			Size = UDim2.fromOffset(pillWidth, 26),
			BackgroundColor3 = C.PanelAlt,
			BorderSizePixel = 0,
			Parent = summary,
		}, { rounded(13) })
		create("UIStroke", { Color = tier.color, Thickness = 1.5, Transparency = 0.2, Parent = pill })
		label(pill, {
			Size = UDim2.fromScale(1, 1),
			RichText = true,
			Text = string.format('<font color="%s">%s</font>  %d', hex(tier.color), string.upper(tier.name), tier.points),
			TextSize = narrow and 10 or 11,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
	end
	label(summary, {
		-- Sits to the right of the three numbers, which run to about 410 px; dropped rather than
		-- overlapping them on a narrower large screen.
		Visible = not (narrow or short) and roomFor(410, 14, 180),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 12),
		Size = UDim2.fromOffset(math.min(300, span(320, 14, 120)), 36),
		Font = FONT.Body,
		Text = string.format("Eliminations with a gun earn its mastery:\n%d per bot, %d per player.",
			ProgressionData.KillPoints.bot, ProgressionData.KillPoints.player),
		TextColor3 = C.Muted,
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- The mastery skins, with how far along each one is.
	-- Three cards in a row while they fit, wrapping to as many as do otherwise. A grid that shares
	-- the width beats a fixed 236 that spills off the side of a phone with no sign it has.
	local skins = create("Frame", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = content,
	})
	UiParts.grid(skins, span(0, 0, 120), 58, 236)
	local _, bestTier = ProgressionData.MasterySummary(mastery)
	local skinOrder = 0
	for _, entry in ipairs(ProgressionData.RankCosmetics) do
		local item = (entry.mastered or entry.masteryTier) and CosmeticData.Get(entry.id)
		if item then
			skinOrder += 1
			local isOwned = owned and owned[entry.id]
			local skinCard = create("Frame", {
				BackgroundColor3 = C.Panel,
				BorderSizePixel = 0,
				LayoutOrder = skinOrder,
				Parent = skins,
			}, { rounded(10) })
			create("UIStroke", { Color = isOwned and item.color or DIM, Thickness = isOwned and 2 or 1, Transparency = 0.2, Parent = skinCard })
			local swatch = create("Frame", {
				Position = UDim2.fromOffset(10, 12),
				Size = UDim2.fromOffset(34, 34),
				BackgroundColor3 = item.color,
				BackgroundTransparency = isOwned and 0 or 0.55,
				BorderSizePixel = 0,
				Parent = skinCard,
			}, { rounded(8) })
			create("UIStroke", { Color = C.Text, Thickness = 1, Transparency = 0.6, Parent = swatch })
			local progressText
			if isOwned then
				progressText = "✓ UNLOCKED — equip it from Cosmetics"
			elseif entry.mastered then
				progressText = string.format("%d / %d guns at Gold", math.min(mastered, entry.mastered), entry.mastered)
			else
				progressText = string.format("best gun: %s", bestTier > 0 and tiers[bestTier].name or "unranked")
			end
			label(skinCard, {
				Position = UDim2.fromOffset(52, 8),
				Size = UDim2.new(1, -58, 0, 18),
				Text = item.name .. " skin",
				TextColor3 = isOwned and item.color or C.Text,
				TextSize = 14,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			label(skinCard, {
				Position = UDim2.fromOffset(52, 27),
				Size = UDim2.new(1, -58, 0, 24),
				Font = FONT.Body,
				Text = isOwned and progressText or (ProgressionData.CosmeticRequirement(entry) .. "  •  " .. progressText),
				TextColor3 = isOwned and C.Green or C.Muted,
				TextWrapped = true,
				TextSize = 11,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
		end
	end

	-- Rarity filter.
	-- Eight chips need 690 px in a row; at 296 the last four ran off the side. Narrow they wrap, and so
	-- does any width without the 690 -- a landscape phone has 632 and lost SECRET off the end.
	local wrapChips = narrow or not roomFor(0, 0, 690)
	local filterChip = wrapChips and math.max(64, math.floor((span(0, 0, 200) - 18) / 4)) or nil
	local filters = create("Frame", {
		Size = UDim2.new(1, -8, 0, wrapChips and 0 or 30),
		AutomaticSize = wrapChips and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = content,
	}, {
		wrapChips and create("UIGridLayout", {
			CellSize = UDim2.fromOffset(filterChip, 28),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}) or create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local options = { "All" }
	for _, rarity in ipairs(Rarity.Order) do
		for _, id in ipairs(weapons) do
			if WeaponData.Get(id).rarity == rarity then
				table.insert(options, rarity)
				break
			end
		end
	end
	for index, option in ipairs(options) do
		local selected = ProgressionPanel.MasteryFilter == option
		local chip = create("TextButton", {
			-- Up to eight chips (All + seven rarities) have to fit 720: 60 + 7 * 84 + 7 * 6 = 690.
			Size = UDim2.fromOffset(filterChip or (option == "All" and 60 or 84), 28),
			BackgroundColor3 = selected and (option == "All" and C.Accent or Rarity.Color(option)) or C.Panel,
			BorderSizePixel = 0,
			Font = FONT.Bold,
			Text = string.upper(option),
			TextColor3 = selected and BLACK or (option == "All" and C.Muted or Rarity.Color(option)),
			TextSize = 12,
			LayoutOrder = index,
			Parent = filters,
		}, { rounded(14) })
		chip.Activated:Connect(function()
			click()
			ProgressionPanel.MasteryFilter = option
			if ctx and ctx.rerender then
				ctx.rerender()
			end
		end)
	end

	-- Guns you've used first, most points first; then the rest in rarity order.
	local list = {}
	for index, id in ipairs(weapons) do
		local def = WeaponData.Get(id)
		if ProgressionPanel.MasteryFilter == "All" or def.rarity == ProgressionPanel.MasteryFilter then
			table.insert(list, { id = id, def = def, points = mastery[id] or 0, order = index })
		end
	end
	table.sort(list, function(a, b)
		if a.points ~= b.points then
			return a.points > b.points
		end
		return a.order < b.order
	end)

	for index, entry in ipairs(list) do
		local tier = ProgressionData.MasteryTier(entry.points)
		local current = tiers[tier]
		local nextTier = tiers[tier + 1]
		local rarityColor = Rarity.Color(entry.def.rarity)
		-- Wide: name and points, tier badge, then the bar and what the next tier pays, in three
		-- columns. Narrow: the same four things stacked, because the bar column is the one that goes
		-- negative first and the reward line is a promise -- it wraps rather than being cut.
		local narrow = page.narrow
		-- Tall rows are 136 because UiParts.meterLine comes to 76 px with a wrapping caption
		-- (label 20 + bar 12 + caption 36 + spacing) and it starts 48 px down, under the name.
		local row = card(content, 10 + index, narrow and 136 or 52, current and current.color or nil)
		if not current then
			row.BackgroundTransparency = 0.25
		end
		local nameWidth = narrow and span(14, 116, 90) or 230
		local meterLeft = narrow and 14 or 358
		local meterWidth = narrow and span(14, 14, 120) or span(358, 14, 120)

		create("Frame", {
			Position = UDim2.fromOffset(0, 8),
			Size = UDim2.fromOffset(4, 36),
			BackgroundColor3 = rarityColor,
			BorderSizePixel = 0,
			Parent = row,
		}, { rounded(2) })
		label(row, {
			Position = UDim2.fromOffset(14, 7),
			Size = UDim2.fromOffset(nameWidth, 20),
			Text = entry.def.name,
			TextColor3 = entry.points > 0 and C.Text or C.Muted,
			TextSize = 15,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
		label(row, {
			Position = UDim2.fromOffset(14, 27),
			Size = UDim2.fromOffset(narrow and nameWidth or 230, 16),
			Font = FONT.Body,
			Text = string.format("%s  •  %s mastery point%s", entry.def.rarity, ProgressionData.Commas(entry.points), entry.points == 1 and "" or "s"),
			TextColor3 = rarityColor,
			TextSize = 12,
		})

		local badge = create("Frame", {
			AnchorPoint = narrow and Vector2.new(1, 0) or Vector2.zero,
			Position = narrow and UDim2.new(1, -14, 0, 8) or UDim2.fromOffset(250, 13),
			Size = UDim2.fromOffset(96, 26),
			BackgroundColor3 = current and current.color or C.PanelAlt,
			BorderSizePixel = 0,
			Parent = row,
		}, { rounded(13) })
		label(badge, {
			Size = UDim2.fromScale(1, 1),
			Text = current and string.upper(current.name) or "UNRANKED",
			TextColor3 = current and BLACK or C.Muted,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
		})

		if nextTier then
			local base = current and current.points or 0
			local fraction = (entry.points - base) / (nextTier.points - base)
			if narrow then
				-- The tall version uses the menu's shared metered line: label, bar, then what the tier
				-- pays as a caption that WRAPS. The large version keeps the shape it has -- Oliver's
				-- word on the desktop menu was that it looks good, so it isn't being redesigned here.
				local holder = create("Frame", {
					Position = UDim2.fromOffset(meterLeft, 48),
					Size = UDim2.fromOffset(meterWidth, 76),
					BackgroundTransparency = 1,
					Parent = row,
				})
				UiParts.meterLine(holder, {
					label = string.format("%d / %d to %s", entry.points, nextTier.points, string.upper(nextTier.name)),
					fraction = fraction,
					color = nextTier.color,
					caption = string.format("+%d Cells  •  +%s Rank XP at %s", nextTier.cells,
						ProgressionData.Commas(nextTier.xp), string.upper(nextTier.name)),
					narrow = true,
				})
			else
				bar(row, { Position = UDim2.fromOffset(meterLeft, 12), Size = UDim2.fromOffset(meterWidth, 12) },
					fraction, nextTier.color)
				label(row, {
					Position = UDim2.fromOffset(meterLeft, 27),
					Size = UDim2.fromOffset(meterWidth, 16),
					Font = FONT.Body,
					RichText = true,
					Text = string.format('%d / %d to <font color="%s">%s</font>  •  +%d Cells  +%s Rank XP',
						entry.points, nextTier.points, hex(nextTier.color), nextTier.name, nextTier.cells, ProgressionData.Commas(nextTier.xp)),
					TextColor3 = C.Muted,
					TextSize = 12,
				})
			end
		else
			label(row, {
				Position = UDim2.fromOffset(meterLeft, narrow and 52 or 0),
				Size = UDim2.fromOffset(meterWidth, narrow and 40 or 52),
				Font = FONT.Display,
				Text = "FULLY MASTERED",
				TextColor3 = current.color,
				TextSize = 18,
			})
		end
	end
end

--------------------------------------------------------------------------------
-- INDEX
--------------------------------------------------------------------------------

local function renderIndex(content, progression, ctx)
	local index = progression.index
	local counts = ProgressionData.IndexCounts(index)

	local found, total, claimableCells, claimable = 0, 0, 0, 0
	for _, rarity in ipairs(Rarity.Order) do
		found += counts[rarity].found
		total += counts[rarity].total
	end
	for name, state in pairs(index) do
		local def = BrainrotData.Get(name)
		if def and state == ProgressionData.Recorded then
			claimable += 1
			claimableCells += ProgressionData.DiscoverCells[def.rarity] or 0
		end
	end

	-- Wide: the count and its bar on the left, the explainer beside them, CLAIM ALL on the right.
	-- Narrow: count, bar, then CLAIM ALL as its own full-width row, and the explainer is dropped --
	-- the page's own contents say what it is, and a tap target beats a sentence at 296 px.
	local narrow = page.narrow
	-- Short: the same card without the explainer and with the bar tucked under the count, so the
	-- rarity pages and the first row of portraits are on the first screen.
	local short = page.mode == "short"
	local countWidth = narrow and span(14, 14, 120) or 300
	local summary = card(content, 1, narrow and 142 or (short and 64 or 86), claimable > 0 and C.Green or BRAIN)
	label(summary, {
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.fromOffset(countWidth, 14),
		Text = "ROT INDEX",
		TextColor3 = C.Muted,
		TextSize = 11,
	})
	label(summary, {
		Position = UDim2.fromOffset(14, short and 20 or 24),
		Size = UDim2.fromOffset(countWidth, short and 26 or 34),
		Font = FONT.Display,
		RichText = true,
		Text = string.format('%d <font color="%s">/ %d discovered</font>', found, hex(C.Muted), total),
		TextSize = 30,
	})
	bar(summary, { Position = UDim2.fromOffset(14, short and 48 or 62), Size = UDim2.fromOffset(countWidth, short and 8 or 12) },
		total > 0 and found / total or 0, BRAIN)
	label(summary, {
		-- Dropped when it doesn't fit: the pages below say what the Index is anyway.
		Visible = not (narrow or short) and roomFor(330, 196, 150),
		Position = UDim2.fromOffset(330, 14),
		Size = UDim2.fromOffset(span(330, 196, 120), 60),
		Font = FONT.Body,
		Text = "Every brainrot you ever own stays here for good. Claim each one once for Brain Cells; a full page pays a bonus.",
		TextColor3 = C.Muted,
		TextWrapped = true,
		TextSize = 12,
	})
	button(summary, {
		AnchorPoint = narrow and Vector2.zero or Vector2.new(1, 0.5),
		Position = narrow and UDim2.fromOffset(12, 86) or UDim2.new(1, -12, 0.5, 0),
		Size = narrow and UDim2.fromOffset(span(12, 12, 120), 44) or UDim2.fromOffset(170, 48),
		Text = claimable > 0 and string.format("CLAIM ALL %d\n+%s CELLS", claimable, formatNumber(claimableCells)) or "ALL CLAIMED",
		TextSize = 14,
	}, claimable > 0 and not busy, C.Green, function()
		click()
		call(ctx, "ClaimIndex", nil)
	end)

	-- Rarity pages.
	-- Seven rarity chips need 721 px in a row. At 296 only three fitted and the other four ran off the
	-- side with nothing to say they were there, so narrow they wrap onto as many rows as it takes.
	-- Wide without the 721 px (a landscape phone) they wrap too.
	local wrapPages = narrow or not roomFor(0, 0, 721)
	local pageChip = wrapPages and math.max(64, math.floor((span(0, 0, 200) - 15) / 4)) or 98
	local pages = create("Frame", {
		Size = UDim2.new(1, -8, 0, wrapPages and 0 or 40),
		AutomaticSize = wrapPages and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = content,
	}, {
		wrapPages and create("UIGridLayout", {
			CellSize = UDim2.fromOffset(pageChip, 40),
			CellPadding = UDim2.fromOffset(5, 5),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}) or create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for order, rarity in ipairs(Rarity.Order) do
		local count = counts[rarity]
		local selected = ProgressionPanel.IndexRarity == rarity
		local color = Rarity.Color(rarity)
		local waiting = 0
		for name, state in pairs(index) do
			local def = state == ProgressionData.Recorded and BrainrotData.Get(name)
			if def and def.rarity == rarity then
				waiting += 1
			end
		end
		local chip = create("TextButton", {
			Size = UDim2.fromOffset(pageChip, 40),
			BackgroundColor3 = selected and color or C.Panel,
			BorderSizePixel = 0,
			Font = FONT.Bold,
			RichText = true,
			Text = string.format("%s\n%d/%d%s", string.upper(rarity), count.found, count.total, waiting > 0 and "  •" or ""),
			TextColor3 = selected and BLACK or color,
			TextSize = 11,
			LayoutOrder = order,
			Parent = pages,
		}, { rounded(8) })
		if progression.pages[rarity] then
			-- Border mode: on a TextButton a contextual stroke outlines the TEXT, which garbled the label.
			create("UIStroke", { Color = C.Accent, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = chip })
		end
		chip.Activated:Connect(function()
			click()
			ProgressionPanel.IndexRarity = rarity
			if ctx and ctx.rerender then
				ctx.rerender()
			end
		end)
	end

	-- The chosen page.
	local rarity = ProgressionPanel.IndexRarity
	local count = counts[rarity]
	local color = Rarity.Color(rarity)
	local pageDone = progression.pages[rarity] == true
	-- Narrow this used to truncate to "…page bon", which reads as a broken sentence rather than a
	-- shorter one. The short form says the same thing in the room there is.
	sectionHeader(content, 3, narrow
		and string.format("%s  •  %d/%d  •  BONUS %s%s", string.upper(rarity), count.claimed, count.total,
			ProgressionData.Commas(ProgressionData.PageBonus[rarity] or 0), pageDone and " (paid)" or "")
		or string.format("%s PAGE  •  %d / %d claimed  •  page bonus %s Cells%s", string.upper(rarity),
			count.claimed, count.total, ProgressionData.Commas(ProgressionData.PageBonus[rarity] or 0), pageDone and " (paid)" or ""), color)

	local grid = create("Frame", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Parent = content,
	})
	-- As many columns as fit, sharing the width between them, through the menu's own grid helper --
	-- one implementation of this sum in the project rather than one per page. Tiles stay tall enough
	-- for a 32-pixel CLAIM button: a comfortable tap.
	UiParts.grid(grid, span(0, 0, 120), 80, 170)
	for order, def in ipairs(BrainrotData.OfRarity(rarity)) do
		local state = index[def.name]
		local tile = create("Frame", {
			BackgroundColor3 = C.Panel,
			BackgroundTransparency = state and 0 or 0.4,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = grid,
		}, { rounded(10) })
		create("UIStroke", {
			Color = state == ProgressionData.Recorded and C.Green or color,
			Thickness = state == ProgressionData.Recorded and 2 or 1.25,
			Transparency = state and 0.2 or 0.8,
			Parent = tile,
		})
		photo(tile, def, 60, not state).Position = UDim2.fromOffset(7, 10)
		label(tile, {
			Position = UDim2.fromOffset(70, 8),
			Size = UDim2.new(1, -76, 0, 30),
			Text = state and def.name or "???",
			TextColor3 = state and C.Text or C.Muted,
			TextWrapped = true,
			TextSize = 12,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		local reward = ProgressionData.DiscoverCells[rarity] or 0
		if state == ProgressionData.Recorded then
			button(tile, {
				Position = UDim2.new(0, 70, 1, -38),
				Size = UDim2.new(1, -78, 0, 32),
				Text = "CLAIM +" .. formatNumber(reward),
				TextSize = 12,
			}, not busy, C.Green, function()
				click()
				call(ctx, "ClaimIndex", def.name)
			end)
		elseif state == ProgressionData.Purchased then
			-- Bought with Robux: shown, but it pays only once it turns up in a crate or the Cell Shop.
			label(tile, {
				Position = UDim2.new(0, 70, 1, -32),
				Size = UDim2.new(1, -78, 0, 28),
				Font = FONT.Body,
				-- Plain words at the old line lengths (the tile is not re-laid out): "pull it in play" was
				-- jargon, and it must say COIN crate -- a Robux-crate pull is logged as Purchased too (#86).
				Text = "BOUGHT — get one\nfrom a coin crate",
				TextColor3 = C.Muted,
				TextSize = 11,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
		else
			label(tile, {
				Position = UDim2.new(0, 70, 1, -28),
				Size = UDim2.new(1, -78, 0, 20),
				Text = state and "✓ CLAIMED" or string.format("%s Cells", ProgressionData.Commas(reward)),
				TextColor3 = state and color or DIM,
				TextSize = 12,
			})
		end
	end
end

--------------------------------------------------------------------------------
-- CELL SHOP
--------------------------------------------------------------------------------

local function renderShop(content, progression, profile, ctx)
	local shop = progression.shop
	local offers = ProgressionData.ShopOffers(shop.day)
	local resetIn = shop.resetIn - (now(ctx) - snapshotAt)

	-- Narrow: the restock clock takes its own line under the title instead of sitting to the right of
	-- it, and the explainer wraps rather than running past the edge on one line.
	local narrow = page.narrow
	-- Short: title and restock clock only. The sentence explaining the shop is the first thing to go
	-- when rows are the scarce thing.
	local short = page.mode == "short"
	local header = card(content, 1, narrow and 104 or (short and 40 or 58), BRAIN)
	label(header, {
		Position = UDim2.fromOffset(14, short and 6 or 8),
		Size = UDim2.new(1, -28, 0, 26),
		Font = FONT.Display,
		Text = "CELL SHOP",
		TextColor3 = BRAIN,
		TextSize = 22,
	})
	label(header, {
		Visible = not short,
		Position = UDim2.fromOffset(14, narrow and 56 or 32),
		Size = UDim2.new(1, -28, 0, narrow and 40 or 18),
		Font = FONT.Body,
		Text = narrow and "Today's picks, the same for everyone: each brainrot once a day, two snacks."
			or "Today's picks, the same for everyone: each brainrot once a day, two snacks — spend Brain Cells on the exact brainrot you're after.",
		TextColor3 = C.Muted,
		TextWrapped = narrow,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 12,
	})
	label(header, {
		AnchorPoint = narrow and Vector2.zero or Vector2.new(1, 0),
		Position = narrow and UDim2.fromOffset(14, 34) or UDim2.new(1, -14, 0, 10),
		Size = UDim2.fromOffset(narrow and span(14, 14, 120) or 220, 20),
		TextXAlignment = narrow and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		Text = "RESTOCKS IN " .. formatTime(resetIn),
		TextColor3 = C.Text,
		TextSize = 13,
	})

	-- Four offer tiles across a desktop menu; on a phone they wrap instead of running off the page.
	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = content,
	})
	local _, _, offerCell = UiParts.grid(row, span(0, 0, 120), 244, 174)

	local owned = {}
	for _, entry in ipairs(profile.brainrots or {}) do
		owned[entry.name] = entry.count
	end

	local snack = nil
	for order, offer in ipairs(offers) do
		if offer.kind == "Snack" then
			snack = offer
		elseif offer.kind == "Brainrot" then
			local def = offer.brainrot and BrainrotData.Get(offer.brainrot)
			local color = def and Rarity.Color(def.rarity) or C.Muted
			local bought = shop.bought[offer.id] or 0
			local soldOut = bought >= offer.limit
			local tile = create("Frame", {
				BackgroundColor3 = C.Panel,
				BorderSizePixel = 0,
				LayoutOrder = order,
				Parent = row,
			}, { rounded(12) })
			create("UIStroke", { Color = color, Thickness = 2, Transparency = soldOut and 0.7 or 0.2, Parent = tile })
			if def then
				-- Centred in whatever the cell turned out to be, rather than 27 px from the left of a
				-- tile that is no longer always 174 wide.
				photo(tile, def, 120, false).Position = UDim2.fromOffset(math.floor((offerCell - 120) / 2), 10)
			end
			label(tile, {
				Position = UDim2.fromOffset(8, 134),
				Size = UDim2.new(1, -16, 0, 34),
				Text = def and def.name or "—",
				TextWrapped = true,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Center,
			})
			local copies = def and owned[def.name] or 0
			local isNew = def and not progression.index[def.name]
			label(tile, {
				Position = UDim2.fromOffset(8, 168),
				Size = UDim2.new(1, -16, 0, 30),
				Font = FONT.Body,
				RichText = true,
				Text = string.format('<font color="%s"><b>%s</b></font>\n%s', hex(color), def and string.upper(def.rarity) or "",
					isNew and '<font color="#5ED67A">NEW FOR YOUR INDEX</font>' or string.format("you own %d", copies)),
				TextColor3 = C.Muted,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Center,
			})
			local affordable = progression.cells >= offer.price
			local buy = button(tile, {
				Position = UDim2.new(0, 8, 1, -42),
				Size = UDim2.new(1, -16, 0, 34),
				Text = soldOut and "BOUGHT TODAY" or "",
				TextSize = 15,
			}, not soldOut and affordable and not busy and def ~= nil, BRAIN, function()
				click()
				call(ctx, "BuyCellOffer", offer.id, shop.day)
			end)
			if not soldOut then
				cellIcon(buy, 18, UDim2.new(0.5, -34, 0.5, -9))
				label(buy, {
					Position = UDim2.new(0.5, -12, 0, 0),
					Size = UDim2.new(0, 60, 1, 0),
					Font = FONT.Display,
					Text = formatNumber(offer.price),
					TextColor3 = affordable and BLACK or C.Muted,
					TextSize = 17,
				})
			end
		end
	end

	if snack then
		local bought = shop.bought[snack.id] or 0
		local companion = profile.companion
		local def = companion and BrainrotData.Get(companion)
		local xp = progression.companionXp or 0
		local cap = (BrainrotData.MaxLevel - 1) * BrainrotData.XpPerLevel
		local level = BrainrotData.LevelForXp(xp)
		local after = BrainrotData.LevelForXp(math.min(cap, xp + snack.xp))
		-- Taller narrow: the buy button sits under the text instead of beside it.
		local snackCard = card(content, 3, page.narrow and 186 or 84, C.Green)
		if def then
			photo(snackCard, def, 64, false).Position = UDim2.fromOffset(10, 10)
		else
			local empty = create("Frame", {
				Position = UDim2.fromOffset(10, 10),
				Size = UDim2.fromOffset(64, 64),
				BackgroundColor3 = C.PanelAlt,
				BorderSizePixel = 0,
				Parent = snackCard,
			}, { rounded(10) })
			label(empty, {
				Size = UDim2.fromScale(1, 1),
				Font = FONT.Display,
				Text = "?",
				TextColor3 = C.Muted,
				TextSize = 30,
				TextXAlignment = Enum.TextXAlignment.Center,
			})
		end
		local snackNarrow = page.narrow
		local snackText = snackNarrow and span(86, 14, 100) or span(86, 194, 120)
		label(snackCard, {
			Position = UDim2.fromOffset(86, 10),
			Size = UDim2.fromOffset(snackText, 22),
			Font = FONT.Display,
			Text = string.format("COMPANION SNACK  •  %d / %d today", bought, snack.limit),
			TextColor3 = C.Green,
			TextSize = 18,
		})
		label(snackCard, {
			-- Below the companion portrait, not across it.
			Position = UDim2.fromOffset(snackNarrow and 14 or 86, snackNarrow and 84 or 34),
			Size = UDim2.fromOffset(snackNarrow and span(14, 14, 120) or snackText, 44),
			Font = FONT.Body,
			Text = not def and string.format("+%d companion XP for the brainrot following you. Equip a companion on the Brainrots tab first.", snack.xp)
				or xp >= cap and string.format("%s is max level (%d). Nothing left to feed.", companion, BrainrotData.MaxLevel)
				or string.format("+%d XP for %s: level %d → %d. Every level adds %d%% damage and health.", snack.xp, companion, level, after,
					math.floor(BrainrotData.BonusPerLevel * 100 + 0.5)),
			TextColor3 = C.Muted,
			TextWrapped = true,
			TextSize = 12,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
		local affordable = progression.cells >= snack.price
		local enabled = def ~= nil and xp < cap and bought < snack.limit and affordable and not busy
		local buy = button(snackCard, {
			AnchorPoint = snackNarrow and Vector2.zero or Vector2.new(1, 0.5),
			Position = snackNarrow and UDim2.fromOffset(12, 132) or UDim2.new(1, -12, 0.5, 0),
			Size = snackNarrow and UDim2.fromOffset(span(12, 12, 120), 44) or UDim2.fromOffset(170, 44),
			Text = bought >= snack.limit and "FED TODAY" or "",
			TextSize = 15,
		}, enabled, C.Green, function()
			click()
			call(ctx, "BuyCellOffer", snack.id, shop.day, companion)
		end)
		if bought < snack.limit then
			cellIcon(buy, 20, UDim2.new(0.5, -38, 0.5, -10))
			label(buy, {
				Position = UDim2.new(0.5, -12, 0, 0),
				Size = UDim2.new(0, 70, 1, 0),
				Font = FONT.Display,
				Text = formatNumber(snack.price),
				TextColor3 = enabled and BLACK or C.Muted,
				TextSize = 18,
			})
		end
	end

	-- The permanent cosmetic listings: the long-term thing to save Brain Cells for.
	sectionHeader(content, 4, "ALWAYS IN STOCK", BRAIN)
	-- Two cards side by side while they fit; one above the other when they don't. AutomaticSize keeps
	-- the container honest either way, so a third listing later doesn't need this height edited.
	-- Two 356 px cards and their gap are 720 px; a landscape phone has 632, where the second card ran
	-- 88 px off the side. Without the room they stack, drawn the narrow way.
	local stackListings = page.narrow or not roomFor(0, 0, 720)
	local listings = create("Frame", {
		Size = stackListings and UDim2.new(1, -8, 0, 0) or UDim2.new(1, -8, 0, 84),
		AutomaticSize = stackListings and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
		BackgroundTransparency = 1,
		LayoutOrder = 5,
		Parent = content,
	}, {
		create("UIListLayout", {
			FillDirection = stackListings and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local ownedCosmetics = profile.cosmetics and profile.cosmetics.owned or {}
	local listingOrder = 0
	for _, entry in ipairs(ProgressionData.RankCosmetics) do
		local item = entry.offer and CosmeticData.Get(entry.id)
		if item then
			listingOrder += 1
			local isOwned = ownedCosmetics[entry.id] == true
			local listing = create("Frame", {
				-- Narrow, these stop being a two-up grid of 356 px cards and become full-width rows.
				Size = stackListings and UDim2.new(1, -8, 0, 160) or UDim2.fromOffset(356, 84),
				BackgroundColor3 = C.Panel,
				BorderSizePixel = 0,
				LayoutOrder = listingOrder,
				Parent = listings,
			}, { rounded(12) })
			create("UIStroke", { Color = item.color, Thickness = 2, Transparency = isOwned and 0.6 or 0.2, Parent = listing })
			cosmeticSwatch(listing, item, isOwned, item.kind == "GunSkin" and "SKIN" or "AURA", 66, 72, true).Position = UDim2.fromOffset(6, 6)
			local listingNarrow = stackListings
			-- These sit inside a card, not on the page: wide it is a fixed 356 in a two-up row, narrow
			-- it is a full-width row. Sizing against the page would run the text 144 px past the card.
			-- Narrow the card is a full-width row inside the listings frame, which is itself inset from
			-- the page, so it is two insets in, not one.
			local listingCell = listingNarrow and span(0, CARD_INSET, 120) or 356
			local listingText = math.max(90, listingCell - 82 - (listingNarrow and 14 or 138))
			label(listing, {
				Position = UDim2.fromOffset(82, 10),
				Size = UDim2.fromOffset(listingText, 22),
				Font = FONT.Display,
				Text = item.name,
				TextColor3 = Rarity.Color(item.rarity),
				TextSize = 18,
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			label(listing, {
				Position = UDim2.fromOffset(listingNarrow and 14 or 82, listingNarrow and 62 or 34),
				Size = UDim2.fromOffset(listingNarrow and math.max(90, listingCell - 28) or listingText, 40),
				Font = FONT.Body,
				Text = string.format("%s %s. Only here.", item.rarity, item.kind == "GunSkin" and "gun skin" or "aura"),
				TextColor3 = C.Muted,
				TextWrapped = true,
				TextSize = 12,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			local affordable = progression.cells >= entry.cells
			local buy = button(listing, {
				AnchorPoint = listingNarrow and Vector2.zero or Vector2.new(1, 0.5),
				Position = listingNarrow and UDim2.fromOffset(12, 108) or UDim2.new(1, -10, 0.5, 0),
				Size = listingNarrow and UDim2.fromOffset(math.max(90, listingCell - 24), 40) or UDim2.fromOffset(112, 40),
				Text = isOwned and "OWNED" or "",
				TextSize = 15,
			}, not isOwned and affordable and not busy, BRAIN, function()
				click()
				call(ctx, "BuyCellOffer", entry.offer, shop.day)
			end)
			if not isOwned then
				cellIcon(buy, 18, UDim2.new(0.5, -38, 0.5, -9))
				label(buy, {
					Position = UDim2.new(0.5, -14, 0, 0),
					Size = UDim2.new(0, 60, 1, 0),
					Font = FONT.Display,
					Text = formatNumber(entry.cells),
					TextColor3 = affordable and BLACK or C.Muted,
					TextSize = 17,
				})
			end
		end
	end

	footnote(content, 6, "Brain Cells come from Rot Rank, gun mastery and Index discoveries. They can't be bought with Robux, and no pass boosts them. "
		.. "The shop never stocks Legendary or rarer brainrots; those still come from crates and trades.")
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

function ProgressionPanel.Render(content, profile, ctx)
	local progression = profile and profile.progression
	if progression ~= snapshotSeen then
		snapshotSeen, snapshotAt = progression, now(ctx)
	end

	-- Every page below sizes itself from this, so it has to happen before anything is drawn.
	measure(content)
	watchWidth(content, ctx)

	renderToggle(content, progression, ctx)
	if ProgressionPanel.View == "Pass" then
		return false
	end

	if not progression then
		label(content, {
			Size = UDim2.new(1, -8, 0, 90),
			LayoutOrder = 1,
			Font = FONT.Body,
			Text = "Loading your progression…",
			TextColor3 = C.Muted,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		return true
	end

	if ProgressionPanel.View == "Rank" then
		renderRank(content, progression, ctx, profile.cosmetics and profile.cosmetics.owned)
	elseif ProgressionPanel.View == "Mastery" then
		renderMastery(content, progression, ctx, profile.cosmetics and profile.cosmetics.owned)
	elseif ProgressionPanel.View == "Index" then
		renderIndex(content, progression, ctx)
	elseif ProgressionPanel.View == "Shop" then
		renderShop(content, progression, profile, ctx)
	end
	return true
end

return ProgressionPanel
