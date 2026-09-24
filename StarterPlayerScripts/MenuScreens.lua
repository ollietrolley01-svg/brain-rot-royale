-- The menu's screens (#78): which HUD button opens which tabs, how each tab looks in its screen's
-- navigation, and the two pieces more than one tab needs -- a preview beside a listed item and the
-- Death Effects tab (#24; tab key "KillAnimations", after the kind's first name).
--
-- Oliver, 2026-09-22 13:59: "no single menu -- separate buttons, each its own page". MenuClient used
-- to carry this as two loose tables (TAB_GROUP, DESTINATION_LOOK) that had already drifted apart once
-- (`Style` had a group and no look, so it drew in the rail with an empty icon). Here one list says
-- everything about a screen, so a tab cannot be in a screen without a look, or in two screens, and
-- tools/menu_screens_check.py holds the list to that.
--
-- A ModuleScript rather than more of MenuClient because that file's main chunk sits at Luau's
-- 200-local ceiling, and because a LocalScript cannot be required by a probe or a harness.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local ShopRotation = require(Shared:WaitForChild("ShopRotation"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local MenuScreens = {}

-- One entry per HUD button, in the order the buttons stack. `tabs` is the order of the screen's own
-- navigation; the first is where the button lands. A screen with one tab draws no navigation at all
-- (MenuShell gives the content the whole panel), which is what makes ROBUX and SETTINGS whole pages
-- rather than a page with a one-item rail beside it.
--
-- The tall (portrait phone) bar fits five cells a row at a 44 px touch target on the narrowest panel,
-- so a screen with more than five tabs costs a second row of bar there. PROGRESS has six; the harness
-- prints what that costs at every size rather than this comment guessing.
MenuScreens.Screens = {
	{ key = "Shop", button = "SHOP", title = "SHOP", tabs = { "Crates", "Style", "Cosmetics", "KillAnimations" } },
	{ key = "Brainrots", button = "BRAINROTS", title = "BRAINROTS", tabs = { "Brainrots", "Trade" } },
	{ key = "Progress", button = "PROGRESS", title = "PROGRESS", tabs = { "Pass", "Rank", "Mastery", "Index", "CellShop", "Quests" } },
	{ key = "Robux", button = "ROBUX", title = "ROBUX SHOP", tabs = { "Robux" } },
	{ key = "Settings", button = "SETTINGS", title = "SETTINGS", tabs = { "Settings" } },
}

-- How each tab draws in its screen's navigation. Glyphs are ones already drawn by the rail in the
-- built place: U+2715 came out as a tofu box in a render, so a new glyph is a render risk and the
-- death effects tab borrows a star rather than bringing in a skull nobody has seen render.
MenuScreens.Look = {
	Brainrots = { glyph = "★", sub = "Your collection" },
	Trade = { glyph = "⇄", sub = "Swap with players" },
	Crates = { glyph = "▣", sub = "Open and buy" },
	Style = { glyph = "✦", sub = "Cosmetic crates" },
	Cosmetics = { glyph = "◆", sub = "Skins and auras" },
	KillAnimations = { glyph = "★", sub = "On your eliminations" },
	Pass = { glyph = "▲", sub = "Brainrot Pass" },
	Rank = { glyph = "★", sub = "Rot Rank" },
	Mastery = { glyph = "◎", sub = "Gun mastery" },
	Index = { glyph = "▦", sub = "Every brainrot" },
	CellShop = { glyph = "✚", sub = "Spend Brain Cells" },
	Quests = { glyph = "✓", sub = "Daily and weekly" },
	Robux = { glyph = "$", sub = "Robux" },
	Settings = { glyph = "⚙", sub = "Keys and audio" },
}

local screenOf = {}
for _, screen in ipairs(MenuScreens.Screens) do
	for _, key in ipairs(screen.tabs) do
		screenOf[key] = screen
	end
end

-- The screen a tab belongs to. nil for a key no screen lists.
function MenuScreens.ScreenOf(tabKey)
	return screenOf[tabKey]
end

-- The shell's destination list for the screen `tabKey` is on. `labelOf(key)` is the host's own tab
-- label, so the words stay where the renderers are.
-- `otherScreens`: also list every other screen, by its button name, landing on its first tab. A
-- phone hides the HUD's five screen buttons (the menu opens from one icon), so without these a phone
-- player could never leave the screen the menu opened on.
function MenuScreens.Destinations(tabKey, labelOf, otherScreens)
	local screen = screenOf[tabKey]
	local destinations = {}
	if not screen then
		return destinations, nil
	end
	for _, key in ipairs(screen.tabs) do
		local look = MenuScreens.Look[key] or {}
		table.insert(destinations, { key = key, label = string.upper(labelOf(key) or key), glyph = look.glyph, sub = look.sub })
	end
	if otherScreens then
		for _, other in ipairs(MenuScreens.Screens) do
			if other ~= screen then
				local look = MenuScreens.Look[other.tabs[1]] or {}
				table.insert(destinations, { key = other.tabs[1], label = other.button, glyph = look.glyph, sub = other.title })
			end
		end
	end
	return destinations, screen
end

-- Everything wrong between the screens and a host's tab list, as strings: a tab with no screen, a
-- screen tab with no renderer, a tab in two screens, a tab with no look. Empty when right.
function MenuScreens.Problems(tabs)
	local problems, rendered, seen = {}, {}, {}
	for _, tab in ipairs(tabs) do
		rendered[tab.key] = true
		if not screenOf[tab.key] then
			table.insert(problems, "tab " .. tab.key .. " is on no screen")
		end
	end
	for _, screen in ipairs(MenuScreens.Screens) do
		for _, key in ipairs(screen.tabs) do
			if seen[key] then
				table.insert(problems, "tab " .. key .. " is on two screens")
			end
			seen[key] = true
			if not rendered[key] then
				table.insert(problems, "screen " .. screen.key .. " lists " .. key .. ", which has no renderer")
			end
			if not (MenuScreens.Look[key] and MenuScreens.Look[key].glyph) then
				table.insert(problems, "tab " .. key .. " has no look")
			end
		end
	end
	return problems
end

-- Whether `id` is what the player has on in any slot. Read across every slot rather than a list of
-- named ones, so a new kind (kill animations get a slot of their own) is right the day its slot
-- exists, and not after somebody remembers this line.
function MenuScreens.Equipped(cosmetics, id)
	if not cosmetics then
		return false
	end
	for key, value in pairs(cosmetics) do
		if key ~= "owned" and value == id then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Previews
--------------------------------------------------------------------------------

local loadedPreview, CosmeticPreview = pcall(require, Shared:WaitForChild("CosmeticPreview"))
if not loadedPreview then
	warn("[MenuScreens] cosmetic previews are off: " .. tostring(CosmeticPreview))
	CosmeticPreview = nil
end

-- Whether CosmeticPreview can build `id`, asked once per id. Asked of the builder rather than of a
-- list of kinds, so when kill animations get a model the swatch below gives way to it unprompted.
local buildable = {}
local function canPreview(id)
	if not CosmeticPreview then
		return false
	end
	if buildable[id] == nil then
		local ok, model = pcall(CosmeticPreview.Model, id)
		buildable[id] = ok and model ~= nil
		if ok and model then
			model:Destroy()
		end
	end
	return buildable[id]
end
MenuScreens.CanPreview = canPreview

-- Where a row's preview goes, for both of makeRow's shapes:
--
--   wide (64 tall)      right of the text, left of a one- or two-button strip: the spot the
--                       parachute previews have always used, 118 px in from the right
--   stacked (112 tall)  bottom left, under the subtitle and level with the buttons, which are
--                       right-aligned. Two 94 px buttons leave 76 px of a 300 px row, so it is
--                       64 wide; the harness checks it never meets a button at 296 px.
MenuScreens.PreviewWide = { anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -118, 0.5, 0), size = UDim2.fromOffset(72, 56) }
MenuScreens.PreviewStacked = { anchor = Vector2.new(0, 1), position = UDim2.new(0, 14, 1, -9), size = UDim2.fromOffset(64, 44) }
-- A wide row with TWO buttons (the Death Effects rows: PREVIEW and buy/equip) has a 194 px strip, so
-- its preview moves 100 px further in: 218 from the right, ending 12 px short of the strip and 16 px
-- clear of the title's -320 column.
MenuScreens.PreviewWideTwo = { anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -218, 0.5, 0), size = UDim2.fromOffset(72, 56) }

-- A preview of cosmetic `id` on a row from makeRow (`row` is the row frame, not its button strip).
-- The real model through CosmeticPreview where one can be built; otherwise a swatch in the item's
-- colour with its rarity, so a listed item never has an empty hole where every other row has a
-- picture. `spot` overrides where it goes (one of the Preview* above). Returns the holder frame.
function MenuScreens.RowPreview(row, id, stacked, spot)
	local item = CosmeticData.Get(id)
	spot = spot or (stacked and MenuScreens.PreviewStacked or MenuScreens.PreviewWide)
	local holder = create("Frame", {
		Name = "RowPreview",
		AnchorPoint = spot.anchor,
		Position = spot.position,
		Size = spot.size,
		BackgroundColor3 = C.PanelAlt,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = row,
	}, { rounded(8) })
	if item and canPreview(id) and pcall(CosmeticPreview.Fill, holder, id) then
		return holder
	end
	holder.BackgroundTransparency = 0
	local color = (item and (item.color or (item.rarity and Rarity.Color(item.rarity)))) or C.Muted
	create("Frame", {
		Name = "Swatch",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = holder,
	}, { rounded(13) })
	create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -2),
		Size = UDim2.new(1, -4, 0, 12),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = item and string.upper(item.rarity or item.kind or "") or "",
		TextColor3 = color,
		TextScaled = true,
		Parent = holder,
	})
	return holder
end

--------------------------------------------------------------------------------
-- Death Effects (#24)
--------------------------------------------------------------------------------

-- The kind's id is still its first name, so saves and the equip slot never change.
MenuScreens.KillAnimationKind = "KillAnimation"

-- What each death effect's row offers, worked out apart from drawing so the harness can hold it to
-- the server's own rules (RewardService.BuyCosmetic: owned, crate-only, in stock, affordable, in that
-- order; EquipCosmetic: owned). `at` is the stock time, for a test.
--
-- Listed from CosmeticData.OfKind, which leaves out bundle exclusives and rank rewards: one of those
-- is still shown once OWNED, so the player can equip it, and is otherwise somewhere else's to sell.
function MenuScreens.KillAnimationRows(profile, at)
	local cosmetics = profile and profile.cosmetics
	local owned = cosmetics and cosmetics.owned or {}
	local ids, listed = {}, {}
	for _, id in ipairs(CosmeticData.OfKind(MenuScreens.KillAnimationKind)) do
		listed[id] = true
		table.insert(ids, id)
	end
	for id in pairs(owned) do
		local item = CosmeticData.Get(id)
		if not listed[id] and item and item.kind == MenuScreens.KillAnimationKind then
			table.insert(ids, id)
		end
	end
	local rows = {}
	for _, id in ipairs(ids) do
		local item = CosmeticData.Get(id)
		local row = { id = id, item = item }
		if owned[id] then
			row.action = MenuScreens.Equipped(cosmetics, id) and "unequip" or "equip"
			row.enabled = true
		elseif item.crateOnly or not item.price then
			row.action, row.enabled = "crate", false
		elseif not ShopRotation.IsCosmeticInStock(id, at) then
			row.action, row.enabled = "outofstock", false
		else
			row.action = "buy"
			row.enabled = profile ~= nil and (profile.coins or 0) >= item.price
		end
		table.insert(rows, row)
	end
	-- Owned first (equipped at the very top), then what you can buy now, then the rest; rarity, then
	-- price, then name inside each.
	local rank = { unequip = 1, equip = 2, buy = 3, outofstock = 4, crate = 5 }
	table.sort(rows, function(a, b)
		if rank[a.action] ~= rank[b.action] then
			return rank[a.action] < rank[b.action]
		end
		local ra, rb = Rarity.Index[a.item.rarity] or 0, Rarity.Index[b.item.rarity] or 0
		if ra ~= rb then
			return ra < rb
		end
		local pa, pb = a.item.price or math.huge, b.item.price or math.huge
		if pa ~= pb then
			return pa < pb
		end
		return a.item.name < b.item.name
	end)
	return rows
end

-- One line saying where a row stands, for the stage: owned and worn, owned, on sale (and the price),
-- sold out this rotation, or a crate exclusive. `formatNumber` is the host's.
function MenuScreens.KillAnimationState(entry, formatNumber)
	local item = entry.item
	local kind = string.upper((item.rarity or "") .. " death effect")
	if entry.action == "unequip" then
		return kind .. "  •  YOURS, EQUIPPED"
	elseif entry.action == "equip" then
		return kind .. "  •  YOURS"
	elseif entry.action == "buy" then
		return kind .. "  •  " .. formatNumber(item.price) .. " C, IN THE SHOP NOW"
	elseif entry.action == "outofstock" then
		return kind .. "  •  " .. formatNumber(item.price) .. " C WHEN IT ROTATES BACK IN"
	end
	return kind .. "  •  CRATE EXCLUSIVE: DEATH EFFECT CRATE"
end

-- The effect on the stage, remembered across re-renders (a purchase re-renders the tab, and the stage
-- should still be showing what was just bought).
MenuScreens.StageId = nil

-- The stage card: one effect, big, looping on a stand-in body, with its name, where it stands and its
-- description. No buttons on it (each row's PREVIEW puts its effect here), so it is never mistaken for
-- a row. Wide: the picture left, the words right. Narrow: the picture across the top.
local function stageCard(host, layoutOrder)
	local narrow = host.narrow
	local card = create("Frame", {
		Name = "DeathEffectStage",
		Size = UDim2.new(1, -8, 0, narrow and 290 or 190),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder,
		Parent = host.content,
	}, { rounded(10) })
	local view = create("Frame", {
		Name = "Stage",
		Position = UDim2.fromOffset(10, 10),
		Size = narrow and UDim2.new(1, -20, 0, 172) or UDim2.fromOffset(236, 170),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = card,
	}, { rounded(8) })
	local textX = narrow and 10 or 258
	local textTop = narrow and 190 or 14
	local function label(y, height, font, size, color, wrapped)
		return create("TextLabel", {
			Position = UDim2.fromOffset(textX, textTop + y),
			Size = UDim2.new(1, -(textX + 10), 0, height),
			BackgroundTransparency = 1,
			Font = font,
			Text = "",
			TextColor3 = color,
			TextSize = size,
			TextWrapped = wrapped == true,
			TextTruncate = wrapped and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = card,
		})
	end
	local result = {
		view = view,
		name = label(0, 26, Enum.Font.FredokaOne, narrow and 20 or 24, C.Text),
		state = label(narrow and 26 or 32, 18, Enum.Font.GothamBold, 12, C.Accent),
		description = label(narrow and 46 or 56, narrow and 36 or 66, Enum.Font.Gotham, 13, C.Muted, true),
		hint = label(narrow and 84 or 146, 14, Enum.Font.GothamBold, 11, C.Muted),
	}
	result.hint.Text = "PRESS PREVIEW ON ANY EFFECT TO WATCH IT HERE"
	return result
end

local stage

-- Puts `entry` on the stage: the live preview (through CosmeticPreview, looping) and its words.
-- `withSound` plays the effect's sounds on its first loop, for a PREVIEW press, not for the tab opening.
local function showOnStage(entry, host, withSound)
	if not stage or not stage.view.Parent then
		return
	end
	MenuScreens.StageId = entry.id
	local item = entry.item
	stage.name.Text = item.name
	stage.name.TextColor3 = item.rarity and Rarity.Color(item.rarity) or C.Text
	stage.state.Text = MenuScreens.KillAnimationState(entry, host.formatNumber)
	stage.description.Text = item.description or ""
	local options = { stage = true, turn = 0.35, background = C.PanelAlt }
	if withSound then
		options.sound = function(cue, jitter)
			Sfx.Play(cue, jitter)
		end
	end
	if CosmeticPreview then
		pcall(CosmeticPreview.Fill, stage.view, entry.id, options)
	end
	if stage.button and stage.button.Parent then
		stage.button.Text = "PREVIEW"
	end
	stage.button = entry.previewButton
	if stage.button then
		stage.button.Text = "REPLAY"
	end
end

-- Draws the tab through the host's own row pieces, so its rows look exactly like the Cosmetics tab
-- beside it, under a stage that plays the chosen effect live. host = { profile, content, makeRow,
-- addButton, emptyMessage, stockHeader, narrow, buy(id), equip(id), formatNumber }. `buy` and `equip`
-- are the existing BuyCosmetic / EquipCosmetic remotes: a death effect is a cosmetic like any other,
-- so it needs no remote of its own.
function MenuScreens.RenderKillAnimations(host)
	host.stockHeader(0, "DEATH EFFECTS  •  what plays on the players you eliminate")
	local rows = MenuScreens.KillAnimationRows(host.profile)
	if #rows == 0 then
		stage = nil
		host.emptyMessage("No death effects yet. When they arrive they are sold here, and one you own is equipped here too.")
		return 0
	end
	stage = host.content and stageCard(host, 1) or nil

	local chosen
	for order, entry in ipairs(rows) do
		local item, id = entry.item, entry.id
		local buttons = host.makeRow(order + 1, item.name, item.rarity and Rarity.Color(item.rarity) or item.color,
			string.format("%s Death Effect  •  %s", item.rarity or "", item.description or ""))
		MenuScreens.RowPreview(buttons.Parent, id, host.narrow, (not host.narrow) and MenuScreens.PreviewWideTwo or nil)
		entry.previewButton = host.addButton(buttons, 1, "PREVIEW", UiKit.Role.Info, function()
			showOnStage(entry, host, true)
		end)
		if entry.action == "buy" then
			host.addButton(buttons, 2, host.formatNumber(item.price) .. " C", C.Accent, function()
				host.buy(id)
			end, entry.enabled)
		elseif entry.action == "equip" then
			host.addButton(buttons, 2, "EQUIP", C.Green, function()
				host.equip(id)
			end)
		elseif entry.action == "unequip" then
			-- The server toggles it off when what's equipped is equipped again.
			host.addButton(buttons, 2, "UNEQUIP", C.Storm, function()
				host.equip(id)
			end)
		elseif entry.action == "outofstock" then
			host.addButton(buttons, 2, "SOLD OUT", C.PanelAlt, nil, false)
		else
			host.addButton(buttons, 2, "CRATES", C.PanelAlt, nil, false)
		end
		if id == MenuScreens.StageId or (not chosen and entry.action == "unequip") then
			chosen = entry
		end
	end
	showOnStage(chosen or rows[1], host, false)
	return #rows
end

return MenuScreens
