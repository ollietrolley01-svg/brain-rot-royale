-- The lobby menu: brainrot collection, crates, cosmetics, the Brainrot Pass, and the
-- Robux shop. Everything is built in code; there is no GUI to assemble in Studio.

local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BattlePassData = require(Shared:WaitForChild("BattlePassData"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CrateModels = require(Shared:WaitForChild("CrateModels"))
local ParachuteModels = require(Shared:WaitForChild("ParachuteModels"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local ShopRotation = require(Shared:WaitForChild("ShopRotation"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local QuestData = require(Shared:WaitForChild("QuestData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))
local MergeDialog = require(script.Parent:WaitForChild("MergeDialog"))
local ProgressionPanel = require(script.Parent:WaitForChild("ProgressionPanel"))

local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local profileChanged = Remotes.Event("ProfileChanged")
local crateOpened = Remotes.Event("CrateOpened")
local bundleGranted = Remotes.Event("BundleGranted")
local requestProfile = Remotes.Function("RequestProfile")
local buyCrate = Remotes.Function("BuyCrate")
local openCrate = Remotes.Function("OpenCrate")
local sellBrainrot = Remotes.Function("SellBrainrot")
local sellAllOfRarity = Remotes.Function("SellAllOfRarity")
local sellDuplicates = Remotes.Function("SellDuplicates")
local mergeBrainrot = Remotes.Function("MergeBrainrot")
local buyBrainrot = Remotes.Function("BuyBrainrot")
local buyCosmetic = Remotes.Function("BuyCosmetic")
local equipCosmetic = Remotes.Function("EquipCosmetic")
local claimPassTier = Remotes.Function("ClaimPassTier")
local claimPassAll = Remotes.Function("ClaimPassAll")
local claimDaily = Remotes.Function("ClaimDaily")
local setTitle = Remotes.Function("SetTitle")
local setShowcase = Remotes.Function("SetShowcase")
local setCompanion = Remotes.Function("SetCompanion")
local requestTrade = Remotes.Function("RequestTrade")
local respondTrade = Remotes.Function("RespondTrade")
local tradeOffer = Remotes.Function("TradeOffer")
local tradeConfirm = Remotes.Function("TradeConfirm")
local tradeCancel = Remotes.Function("TradeCancel")
local tradeInvite = Remotes.Event("TradeInvite")
local tradeChanged = Remotes.Event("TradeChanged")

local create, rounded, padding = UiKit.create, UiKit.rounded, UiKit.padding
local clearItems, formatNumber = UiKit.clearItems, UiKit.formatNumber
local C = UiKit.Colors

local profile = nil
local activeTab = "Brainrots"
-- Which rarity the Brainrots tab is showing, or "All".
local brainrotFilter = "All"
local trade = { active = false }

local screenGui = create("ScreenGui", {
	Name = "BrrMenu",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

--------------------------------------------------------------------------------
-- Coin counter + menu button
--------------------------------------------------------------------------------

local coinChip = create("Frame", {
	Position = UDim2.new(0, 16, 0, 78),
	Size = UDim2.new(0, 210, 0, 44),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Parent = screenGui,
}, { rounded(10), padding(10) })

local coinIcon = create("Frame", {
	Size = UDim2.fromOffset(24, 24),
	Position = UDim2.new(0, 0, 0.5, -12),
	BackgroundColor3 = C.Accent,
	BorderSizePixel = 0,
	Parent = coinChip,
}, { rounded(12) })

create("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "S",
	TextColor3 = Color3.fromRGB(90, 62, 0),
	TextSize = 15,
	Parent = coinIcon,
})

local coinLabel = create("TextLabel", {
	Position = UDim2.new(0, 32, 0, 0),
	Size = UDim2.new(1, -32, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "0",
	TextColor3 = C.Accent,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextSize = 22,
	Parent = coinChip,
})

--------------------------------------------------------------------------------
-- Panel scaffolding
--------------------------------------------------------------------------------

-- The frame is MenuShell's now (claude-ee, Oliver's #20 and the three-version work). It sizes itself
-- to the screen and picks one of three layouts — rail, icon rail or bottom bar — where this panel
-- used to be a fixed 760x480 whatever the screen was: 40% of a 1080p monitor and 123% of the HEIGHT
-- of a phone, with the bottom of every tab off the edge.
--
-- Nothing below this block changed. `panel` is the shell's full-screen layer, so the fifteen
-- `panel.Visible` reads and its two GetPropertyChangedSignal listeners mean what they always meant
-- ("is the menu open"), and `content` is a list-laid frame inside the shell's scrolling area, so all
-- eight renderers draw into exactly what they drew into before and keep their owners.
local MenuShell = require(script.Parent:WaitForChild("MenuShell"))
local shell = MenuShell.new({ parent = screenGui, title = "BRAIN ROT ROYALE" })
local panel = shell.layer

-- THE SHELL HAS TO BE TOLD WHAT SCREEN IT IS ON, and nothing told it (Oliver's #65).
--
-- `MenuShell.new` falls back to Vector2.new(1280, 720) when no viewport is passed, and this file
-- passed none and never called SetViewport afterwards -- the only caller anywhere in the project
-- was tools/menu_hud_gallery.lua. So the panel was a fixed 1100x619 on every screen in the game,
-- the fit scale was computed for a screen the player does not have, and `UiKit.form` was asked
-- about 1280x720 every single time: THE `short` AND `tall` VERSIONS NEVER RAN IN THE GAME AT ALL.
-- They ran in the gallery, which is why they looked finished.
--
-- The watching itself is the shell's (MenuShell:BindViewport) rather than a block here, because
-- this file is a LocalScript and nothing in the harness can run a LocalScript -- so wiring written
-- here is wiring no probe can check, which is exactly how its absence went unnoticed.
shell:BindViewport()

-- The title, the close button and the tab strip are the shell's header and navigation now. The
-- FitPanel call is gone too: the shell sizes the panel from the viewport and applies PhoneLayout's
-- own PanelScale itself, so fitting a fixed 760x480 would be fitting a size nothing draws.

-- What every renderer draws into. A frame rather than the ScrollingFrame itself, because the
-- renderers rely on the UIListLayout being right here on `content`, and because the shell owns the
-- scrolling. AutomaticSize Y feeds the shell's AutomaticCanvasSize, so tall tabs still scroll.
local content = create("Frame", {
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = shell.Content,
}, {
	create("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

--------------------------------------------------------------------------------
-- Row builder
--------------------------------------------------------------------------------

-- Content narrower than this stacks a row instead of putting its buttons beside the text. It matters
-- because rows size their text as "parent width minus 320": a portrait phone leaves about 296 px of
-- content, where that is a NEGATIVE width and the label draws nothing at all rather than shrinking.
--
-- Other sections key their own layout off this rather than picking a second number: the parachute
-- rows drop their right-hand preview at NARROW_CONTENT - 8, because a stacked row's subtitle runs the
-- full width and would otherwise be drawn across the preview. Move this and they follow; add another
-- threshold nearby and you reintroduce a band where one section stacks and another doesn't.
local NARROW_CONTENT = 560

local function narrowContent()
	local width = content.AbsoluteSize.X
	if width <= 0 then
		-- Before the first layout pass AbsoluteSize is 0; the viewport is the best estimate there.
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
		width = viewport.X - 180
	end
	return width < NARROW_CONTENT, width
end

-- On sizing a label below: `UiKit.textSpan(select(2, narrowContent()), reserve, height)`, rather
-- than a flat `UDim2.new(1, -reserve, ...)`. A fixed reserve becomes a NEGATIVE width once it
-- passes the content width, and a negative width draws nothing rather than truncating. Written out
-- at each site instead of wrapped in a helper because this chunk is at Luau's 200-local ceiling and
-- verify.py warns at 195 -- one more top-level local here costs more than the repetition does.
-- These rows sit inside cards a gutter narrower than the content, and textSpan's floor absorbs that.

-- Returns the row's button container so callers can append their own buttons.
local function makeRow(order, title, titleColor, subtitle)
	local narrow = narrowContent()
	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, narrow and 112 or 64),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = content,
	}, { rounded(10) })

	create("TextLabel", {
		Position = UDim2.new(0, 14, 0, 10),
		Size = UDim2.new(1, narrow and -28 or -320, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = title,
		TextColor3 = titleColor or C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 16,
		Parent = row,
	})

	create("TextLabel", {
		Position = UDim2.new(0, 14, 0, 32),
		Size = UDim2.new(1, narrow and -28 or -320, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = subtitle or "",
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 13,
		Parent = row,
	})

	local buttons = create("Frame", {
		AnchorPoint = narrow and Vector2.new(0, 1) or Vector2.new(1, 0.5),
		Position = narrow and UDim2.new(0, 14, 1, -12) or UDim2.new(1, -12, 0.5, 0),
		Size = narrow and UDim2.new(1, -28, 0, 38) or UDim2.new(0, 300, 0, 38),
		BackgroundTransparency = 1,
		Parent = row,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	return buttons
end

local function addButton(parent, order, text, color, onClick, enabled)
	local button = create("TextButton", {
		Size = UDim2.fromOffset(94, 38),
		BackgroundColor3 = enabled == false and C.PanelAlt or color,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = enabled == false and C.Muted or Color3.new(0, 0, 0),
		TextSize = 13,
		AutoButtonColor = enabled ~= false,
		LayoutOrder = order,
		Parent = parent,
	}, { rounded(8) })

	if enabled ~= false and onClick then
		button.Activated:Connect(function()
			Sfx.Play("UiClick", 0.08)
			onClick()
		end)
	end

	return button
end

local function emptyMessage(text)
	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 90),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = text,
		TextColor3 = C.Muted,
		TextWrapped = true,
		TextSize = 14,
		Parent = content,
	})
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

local renderTab

-- Fire-and-forget: the server toasts its own result, and every successful action pushes the
-- updated profile (ProfileChanged) or trade (TradeChanged), each of which re-renders with fresh
-- data. Re-rendering here as well drew the tab twice per click — the first time from the *old*
-- profile, since this runs before the push lands, so stale coin and crate counts flashed up.
local function invoke(remote, ...)
	pcall(function(...)
		return remote:InvokeServer(...)
	end, ...)
end

-- A live 3D portrait: the same model the companion uses, in a ViewportFrame. No image assets.
-- `silhouette` blacks it out, for brainrots you haven't found yet.
local function brainrotPhoto(parent, def, size, silhouette)
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

local function statLine(parent, y, text, color, font, size)
	return create("TextLabel", {
		Position = UDim2.new(0, 124, 0, y),
		-- 124 of photo on the left and 216 of buttons on the right: -44 px at the 296 a portrait
		-- phone gives, which drew nothing at all.
		Size = UiKit.textSpan(select(2, narrowContent()), 340, size + 6),
		BackgroundTransparency = 1,
		Font = font or Enum.Font.Gotham,
		Text = text,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = size,
		Parent = parent,
	})
end

-- The Codex: every brainrot in the game, found or not, with where the missing ones drop.
local codexMode = false

-- Which crates can roll a given rarity, for "how do I get this".
local function crateSourcesFor(rarity)
	local names = {}
	for _, tier in ipairs(CrateData.Order) do
		local crate = CrateData.Get(tier)
		if (crate.category or "Brainrot") == "Brainrot" and (crate.odds[rarity] or 0) > 0 then
			table.insert(names, tier)
		end
	end
	return #names > 0 and (table.concat(names, " / ") .. " crates") or "trades only"
end

local function codexRow(order, def, count)
	local color = Rarity.Color(def.rarity)
	local owned = count > 0
	-- Every brainrot can be bought outright with Robux (one product per rarity; BrainrotShopService
	-- ties the pick to the purchase). Shown when that rarity's product is set up, or greyed in Studio.
	local product = GamepassConfig.BrainrotProduct(def.rarity)
	local buyable = product ~= nil and product.id > 0
	local showBuy = product ~= nil and (buyable or RunService:IsStudio())
	local rightReserve = (showBuy and 100 or 0) + (owned and 100 or 0)
	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, 60),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = owned and 0 or 0.35,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = content,
	}, { rounded(10) })
	create("UIStroke", { Color = color, Thickness = 1.5, Transparency = owned and 0.3 or 0.75, Parent = row })

	brainrotPhoto(row, def, 48, not owned).Position = UDim2.fromOffset(6, 6)

	create("TextLabel", {
		Position = UDim2.fromOffset(64, 8),
		-- rightReserve is 0, 100 or 200 depending on the BUY and OWNED chips, so this ran from 76 px
		-- down to -124 at 296 of content.
		Size = UiKit.textSpan(select(2, narrowContent()), 220 + rightReserve, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = owned and def.name or "???  " .. def.name,
		TextColor3 = owned and color or C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 15,
		Parent = row,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(64, 32),
		Size = UiKit.textSpan(select(2, narrowContent()), 220 + rightReserve, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = owned and string.format("%s  •  %s coins each", string.upper(def.rarity), formatNumber(def.coinValue))
			or string.format("%s  •  from %s", string.upper(def.rarity), crateSourcesFor(def.rarity)),
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 12,
		Parent = row,
	})
	create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14 - rightReserve, 0.5, 0),
		Size = UDim2.fromOffset(140, 24),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = owned and string.format("OWNED  x%d", count) or "NOT FOUND YET",
		TextColor3 = owned and C.Green or C.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 15,
		Parent = row,
	})
	-- Owned ones can be equipped straight from the Codex too, so the list is never a dead end.
	if owned and profile then
		local following = profile.companion == def.name
		local button = create("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(94, 34),
			BackgroundColor3 = following and C.PanelAlt or C.Green,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			Text = following and "UNEQUIP" or "EQUIP",
			TextColor3 = following and C.Text or Color3.new(0, 0, 0),
			TextSize = 13,
			Parent = row,
		}, { rounded(8) })
		button.Activated:Connect(function()
			Sfx.Play("UiClick", 0.08)
			invoke(setCompanion, following and nil or def.name)
		end)
	end
	if showBuy then
		local buy = create("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, owned and -110 or -10, 0.5, 0),
			Size = UDim2.fromOffset(94, 34),
			BackgroundColor3 = buyable and C.Accent or C.PanelAlt,
			BorderSizePixel = 0,
			AutoButtonColor = buyable,
			Font = Enum.Font.GothamBold,
			Text = string.format("%d R$", product.suggestedPrice),
			TextColor3 = buyable and Color3.new(0, 0, 0) or C.Muted,
			TextSize = 13,
			Parent = row,
		}, { rounded(8) })
		if buyable then
			buy.Activated:Connect(function()
				Sfx.Play("UiClick", 0.08)
				-- The server stores this pick and opens the purchase prompt itself.
				invoke(buyBrainrot, def.name)
			end)
		end
	end
end

-- MERGE opens a confirmation card first (MergeDialog) showing the stat change and the cost; only
-- CONFIRM sends anything. The star count it was opened at goes with the request, so a second
-- confirm for the same merge is refused by the server instead of spending more copies.
local function openMergeDialog(def, entry, level, stars)
	MergeDialog.Open(screenGui, {
		def = def,
		level = level,
		stars = stars,
		count = entry.count,
		onConfirm = function()
			task.spawn(function()
				-- The server's own message is NOT passed on: Bootstrap's `guard` now toasts whatever a
				-- menu remote returns, so repeating it here put the same words on screen twice at the
				-- same moment. The dialog keeps its generic line and the toast carries the reason.
				--
				-- The "couldn't reach the server" line below is different and stays: guard never ran,
				-- so nothing else will say anything at all.
				local reached, success = pcall(function()
					return mergeBrainrot:InvokeServer(entry.name, stars)
				end)
				if not reached then
					MergeDialog.Resolve(false, "Couldn't reach the server. Nothing was spent.")
					return
				end
				if success then
					Sfx.Play("Gold")
				end
				MergeDialog.Resolve(success == true)
			end)
		end,
	})
end

-- The card belongs to the menu: closing the menu closes it too.
panel:GetPropertyChangedSignal("Visible"):Connect(function()
	if not panel.Visible then
		MergeDialog.Close()
	end
end)

local function renderBrainrots()
	if not profile or (#profile.brainrots == 0 and not codexMode) then
		emptyMessage("No brainrots yet.\n\nPlace in a match or open a crate to start collecting.")
		if profile then
			local buttons = makeRow(1, "See everything there is to collect", C.Text, "The Codex lists all " .. #BrainrotData.Types .. " brainrots and where they drop")
			addButton(buttons, 1, "CODEX", C.Storm, function()
				codexMode = true
				renderTab()
			end)
		end
		return
	end

	local order = 0
	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("Collection worth %s SahurCoins   •   discovered %d / %d brainrots   •   equip one to have it fight for you",
			formatNumber(profile.brainrotValue), #profile.brainrots, #BrainrotData.Types),
		TextColor3 = C.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 14,
		LayoutOrder = order,
		Parent = content,
	})

	-- Set progress per rarity. Owning every brainrot of a rarity pays a one-time bonus.
	local ownedNames = {}
	for _, entry in ipairs(profile.brainrots) do
		ownedNames[entry.name] = true
	end
	local bonuses = BrainrotData.CollectionBonus
	local progress = {}
	for _, rarityName in ipairs(Rarity.Order) do
		local set = BrainrotData.OfRarity(rarityName)
		local have = 0
		for _, def in ipairs(set) do
			if ownedNames[def.name] then
				have += 1
			end
		end
		local claimed = profile.collections and profile.collections[rarityName]
		table.insert(progress, string.format("%s %d/%d %s", rarityName, have, #set,
			claimed and "(done)" or ("(+" .. formatNumber(bonuses[rarityName] or 0) .. ")")))
	end
	-- Two rows: seven sets don't fit on one line. The top tiers get their own, in their colours.
	local rows = {
		{ text = "SETS   " .. table.concat(progress, "    ", 1, 4), color = C.Muted },
		{ text = "RARE SETS   " .. table.concat(progress, "    ", 5, #progress), color = Rarity.Color("Mythic") },
	}
	for _, row in ipairs(rows) do
		order += 1
		create("TextLabel", {
			Size = UDim2.new(1, -8, 0, 20),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = row.text,
			TextColor3 = row.color,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 12,
			LayoutOrder = order,
			Parent = content,
		})
	end

	-- Doubles: one button sells every copy beyond the first, leaving the collection intact.
	local duplicates, duplicateValue = 0, 0
	for _, entry in ipairs(profile.brainrots) do
		if entry.count > 1 then
			duplicates += entry.count - 1
			duplicateValue += (entry.count - 1) * entry.coinValue
		end
	end
	if duplicates > 0 then
		order += 1
		local dupButtons = makeRow(order,
			string.format("%d duplicate%s worth %s SahurCoins", duplicates, duplicates == 1 and "" or "s", formatNumber(duplicateValue)),
			C.Text, "Sells every copy beyond the first of each brainrot. Spare copies can be MERGED instead.")
		addButton(dupButtons, 1, "SELL DUPES", C.Red, function()
			invoke(sellDuplicates)
		end)
	end

	-- Merging, in two lines: what a star is worth and what it costs.
	local costs, totalCopies = {}, 0
	for _, copies in ipairs(BrainrotData.MergeCopies) do
		table.insert(costs, tostring(copies))
		totalCopies += copies
	end
	local mergeLines = {
		string.format("MERGE   fuse spare copies of a brainrot into it: +%d%% damage and health per star, up to %s",
			math.floor(BrainrotData.BonusPerStar * 100 + 0.5), string.rep("★", BrainrotData.MaxStars)),
		string.format("Spares per star: %s (%d for all %d)   •   stars stay yours when you sell or trade copies",
			table.concat(costs, ", "), totalCopies, BrainrotData.MaxStars),
	}
	for _, text in ipairs(mergeLines) do
		order += 1
		create("TextLabel", {
			Size = UDim2.new(1, -8, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = text,
			TextColor3 = Rarity.Color("Legendary"),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 12,
			LayoutOrder = order,
			Parent = content,
		})
	end

	-- Rarity filter: with 120-odd brainrots, one long list is a lot to scroll.
	order += 1
	local chips = create("Frame", {
		Size = UDim2.new(1, -8, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = content,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 5),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local filterOptions = { "All" }
	for _, rarityName in ipairs(Rarity.Order) do
		table.insert(filterOptions, rarityName)
	end
	for index, option in ipairs(filterOptions) do
		local selected = brainrotFilter == option
		local chipColor = option == "All" and C.Accent or Rarity.Color(option)
		local chip = create("TextButton", {
			Size = UDim2.fromOffset(option == "All" and 54 or 84, 28),
			BackgroundColor3 = selected and chipColor or C.Panel,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			Font = Enum.Font.GothamBold,
			Text = string.upper(option),
			TextColor3 = selected and Color3.new(0, 0, 0) or chipColor,
			TextSize = 11,
			LayoutOrder = index,
			Parent = chips,
		}, { rounded(7) })
		chip.Activated:Connect(function()
			Sfx.Play("UiClick", 0.08)
			brainrotFilter = option
			renderTab()
		end)
	end

	-- The Codex toggle at the end of the chip row.
	-- Sized to its own label, because it has two of very different lengths: "CODEX" fits the 70 px
	-- this used to be fixed at and "BACK TO MY BRAINROTS" is twenty characters that did not, so the
	-- text ran out of the chip (Oliver's #129). Its siblings above are each sized for their own word
	-- (`option == "All" and 54 or 84`); this was the one that was not. AutomaticSize keeps both
	-- labels exact instead of trading one overflowing chip for one too wide for "CODEX".
	local codexChip = create("TextButton", {
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = codexMode and C.Storm or C.Panel,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Font = Enum.Font.GothamBold,
		Text = codexMode and "BACK TO MY BRAINROTS" or "CODEX",
		TextColor3 = codexMode and Color3.new(0, 0, 0) or C.Storm,
		TextSize = 11,
		LayoutOrder = 99,
		Parent = chips,
	}, {
		rounded(7),
		create("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
	})
	codexChip.Activated:Connect(function()
		Sfx.Play("UiClick", 0.08)
		codexMode = not codexMode
		renderTab()
	end)

	if codexMode then
		-- Everything, rarest last, with what you own counted in.
		local counts = {}
		for _, entry in ipairs(profile.brainrots) do
			counts[entry.name] = entry.count
		end
		for _, rarityName in ipairs(Rarity.Order) do
			if brainrotFilter == "All" or brainrotFilter == rarityName then
				local set = BrainrotData.OfRarity(rarityName)
				local have = 0
				for _, def in ipairs(set) do
					if counts[def.name] then
						have += 1
					end
				end
				order += 1
				create("TextLabel", {
					Size = UDim2.new(1, -8, 0, 26),
					BackgroundTransparency = 1,
					Font = Enum.Font.FredokaOne,
					Text = string.format("%s   %d / %d", string.upper(rarityName), have, #set),
					TextColor3 = Rarity.Color(rarityName),
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Bottom,
					TextSize = 17,
					LayoutOrder = order,
					Parent = content,
				})
				-- THE ONE EDIT, when Oliver answers the sort question. The list is grouped by rarity
				-- (rarest last) and, within a rarity, follows BrainrotData's own order -- which is the
				-- order they were written, not a chosen one. The three candidates and the change each
				-- one costs, so whoever picks it up is not re-deriving this:
				--   * leave it as written      -- nothing to do
				--   * by name, A to Z          -- sort a copy of `set` on def.name
				--   * by coin value, low first -- sort a copy of `set` on def.coinValue
				-- Sort a COPY: BrainrotData.OfRarity returns a fresh table today, but sorting the
				-- module's own data in place would reorder it for the shop, the crate roll and the
				-- codex all at once.
				--
				-- Shared/BrainrotCodex holds a line of flavour text for all 126, keyed by name
				-- (`BrainrotCodex.Get(def.name)`, nil if there is none). It is drawn nowhere yet. The
				-- row is 60 px tall with two lines of text at x 64; a third line at y 46 is where it
				-- goes, and the row grows to about 80. verify.py already checks the file is complete
				-- and inside its own length limit, so the text is ready whenever the panel is.
				for _, def in ipairs(set) do
					order += 1
					codexRow(order, def, counts[def.name] or 0)
				end
			end
		end
		return
	end

	for _, entry in ipairs(profile.brainrots) do
		local def = BrainrotData.Get(entry.name)
		if def and (brainrotFilter == "All" or def.rarity == brainrotFilter) then
			order += 1
			local level = entry.level or 1
			local stars = entry.stars or 0
			local stats = BrainrotData.Stats(def, level, stars)
			local starText = BrainrotData.StarText(stars)
			local color = Rarity.Color(def.rarity)
			local showcased = profile.showcase == entry.name
			local following = profile.companion == entry.name
			local levelText = level >= BrainrotData.MaxLevel and string.format("Lv %d MAX", level)
				or string.format("Lv %d  •  %d / %d XP", level, BrainrotData.XpIntoLevel(entry.xp or 0), BrainrotData.XpPerLevel)

			local card = create("Frame", {
				Size = UDim2.new(1, -8, 0, 144),
				BackgroundColor3 = C.Panel,
				BorderSizePixel = 0,
				LayoutOrder = order,
				Parent = content,
			}, { rounded(10) })
			create("UIStroke", {
				Color = following and C.Green or color,
				Thickness = following and 2 or 1.5,
				Transparency = following and 0 or 0.4,
				Parent = card,
			})

			brainrotPhoto(card, def, 106).Position = UDim2.fromOffset(8, 19)

			statLine(card, 8, string.format("%s  x%d%s", entry.name, entry.count, starText ~= "" and ("   " .. starText) or ""),
				color, Enum.Font.GothamBold, 17)
			statLine(card, 32, string.format("%s  •  %s coins each  •  %s", string.upper(def.rarity), formatNumber(def.coinValue), levelText),
				color, Enum.Font.GothamBold, 12)
			statLine(card, 52, string.format("[%s] %s  (%s)   %d dmg   %.1fs cooldown   %d range   %d HP",
				Settings.KeyLabel("Companion"), stats.move, stats.kind, stats.damage, stats.cooldown, stats.range, stats.health),
				C.Text, Enum.Font.GothamBold, 13)
			statLine(card, 74, stats.description .. (stats.splash > 0 and string.format(" (splash %d)", stats.splash) or ""),
				C.Muted, Enum.Font.Gotham, 12)

			local status = {}
			if following then
				table.insert(status, "FOLLOWING YOU")
			end
			if showcased then
				table.insert(status, "ON YOUR PODIUM")
			end
			if stars > 0 then
				table.insert(status, string.format("MERGED +%d%%", math.floor((BrainrotData.StarBonus(stars) - 1) * 100 + 0.5)))
			end
			statLine(card, 96, table.concat(status, "   •   "), C.Green, Enum.Font.GothamBold, 12)

			-- The usual 2x2 grid, with a full-width MERGE button under it.
			local buttonColumn = create("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(196, 128),
				BackgroundTransparency = 1,
				Parent = card,
			})
			local buttons = create("Frame", {
				Size = UDim2.fromOffset(196, 84),
				BackgroundTransparency = 1,
				Parent = buttonColumn,
			}, {
				create("UIGridLayout", {
					CellSize = UDim2.fromOffset(95, 39),
					CellPadding = UDim2.fromOffset(6, 6),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
			})

			addButton(buttons, 1, following and "UNEQUIP" or "EQUIP", C.Green, function()
				invoke(setCompanion, following and nil or entry.name)
			end)
			-- Not `showcased and nil or entry.name`: nil falls through the `or`, so that
			-- expression always yields entry.name and UNSHOW would never clear anything.
			addButton(buttons, 2, showcased and "UNSHOW" or "SHOW OFF", C.Storm, function()
				if showcased then
					invoke(setShowcase, nil)
				else
					invoke(setShowcase, entry.name)
				end
			end)
			addButton(buttons, 3, "SELL 1", C.Accent, function()
				invoke(sellBrainrot, entry.name)
			end)
			-- Confirmed before it acts, because it is irreversible and it is bigger than it looks.
			-- Drawn on one brainrot's card under "SELL 1", this sells every brainrot of the whole
			-- RARITY (RewardService.SellAllOfRarity :339), keeping one copy of each merged one. MERGE
			-- -- which leaves you better off -- has had a confirm card since it was written; this had
			-- none, and `invoke` discards the server's reply, so the first a player knew was a shorter
			-- list. The body names what is KEPT as well as what goes: "are you sure" helps nobody.
			--
			-- The LABEL still says "SELL ALL" and should say the rarity. That is deliberate and it is
			-- held for a render: a variable-length label in a fixed 95x39 grid cell is exactly the
			-- clipped chip that #129 was, and it is not going in unmeasured. The dialog prevents the
			-- loss; the label prevents the misunderstanding, and only the first is urgent.
			addButton(buttons, 4, "SELL ALL", C.Red, function()
				local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
					or Vector2.new(1280, 720)
				UiParts.dialog({
					parent = screenGui,
					viewport = viewport,
					title = "Sell every " .. entry.rarity .. " brainrot?",
					body = "This sells your whole " .. entry.rarity .. " collection, not just "
						.. entry.name .. ". One copy of each merged brainrot stays. It cannot be undone.",
					actions = {
						{ text = "CANCEL", kind = "secondary" },
						{ text = "SELL THEM", kind = "danger", onClick = function()
							invoke(sellAllOfRarity, entry.rarity)
						end },
					},
				})
			end)

			-- MERGE says what the next star needs: live once there are enough spare copies,
			-- otherwise greyed out with how far along you are.
			local mergeCost = BrainrotData.MergeCost(stars)
			local spare = entry.count - 1
			local canMerge = mergeCost ~= nil and spare >= mergeCost
			local mergeText = not mergeCost and string.format("FULLY MERGED  +%d%%", math.floor((BrainrotData.StarBonus(stars) - 1) * 100 + 0.5))
				or canMerge and string.format("MERGE TO ★%d  (uses %d)", stars + 1, mergeCost)
				or string.format("MERGE  %d / %d SPARES", spare, mergeCost)
			local mergeButton = addButton(buttonColumn, 5, mergeText, Rarity.Color("Legendary"), function()
				openMergeDialog(def, entry, level, stars)
			end, canMerge)
			mergeButton.Position = UDim2.fromOffset(0, 90)
			mergeButton.Size = UDim2.fromOffset(196, 38)
		end
	end

	-- The rest of the collection, as silhouettes with only their rarity showing: something to
	-- chase in crates and placements.
	local owned = {}
	for _, entry in ipairs(profile.brainrots) do
		owned[entry.name] = true
	end
	local missing = {}
	for _, def in ipairs(BrainrotData.Types) do
		if not owned[def.name] and (brainrotFilter == "All" or def.rarity == brainrotFilter) then
			table.insert(missing, def)
		end
	end
	if #missing == 0 then
		return
	end

	order += 1
	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 34),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("UNDISCOVERED  •  %d left to find%s", #missing,
			GamepassConfig.BrainrotProduct("Common") and GamepassConfig.BrainrotProduct("Common").id > 0
				and "  •  open the CODEX to buy any of them with Robux" or ""),
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 15,
		LayoutOrder = order,
		Parent = content,
	})

	local perRow = 7
	order += 1
	local grid = create("Frame", {
		Size = UDim2.new(1, -8, 0, math.ceil(#missing / perRow) * 100),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = content,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.fromOffset(94, 94),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	for index, def in ipairs(missing) do
		local cell = create("Frame", {
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = grid,
		}, { rounded(8) })

		-- Live 3D silhouettes only once filtered to one rarity; the full list of a hundred-plus
		-- would build that many ViewportFrames on every refresh, so it gets plain tiles.
		if brainrotFilter == "All" then
			create("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 8),
				Size = UDim2.fromOffset(62, 62),
				BackgroundColor3 = C.PanelAlt,
				BorderSizePixel = 0,
				Font = Enum.Font.FredokaOne,
				Text = "?",
				TextColor3 = Rarity.Color(def.rarity),
				TextSize = 34,
				Parent = cell,
			}, { rounded(31) })
		else
			local photo = brainrotPhoto(cell, def, 70, true)
			photo.Position = UDim2.new(0.5, -35, 0, 4)
		end

		create("TextLabel", {
			Position = UDim2.new(0, 0, 1, -20),
			Size = UDim2.new(1, 0, 0, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "? " .. string.upper(def.rarity),
			TextColor3 = Rarity.Color(def.rarity),
			TextSize = 11,
			Parent = cell,
		})
	end
end

--------------------------------------------------------------------------------
-- Trading
--------------------------------------------------------------------------------

-- A trade row with a brainrot's photo, so both sides can see exactly what's on offer.
-- `brainrotName` picks the photo (nil for none); returns the button container.
local function tradeRow(order, title, titleColor, subtitle, brainrotName)
	local def = brainrotName and BrainrotData.Get(brainrotName) or nil

	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, 72),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = content,
	}, { rounded(10) })

	local textLeft = 14
	if def then
		brainrotPhoto(row, def, 60).Position = UDim2.fromOffset(6, 6)
		textLeft = 76
	end

	create("TextLabel", {
		Position = UDim2.new(0, textLeft, 0, 12),
		Size = UDim2.new(1, -textLeft - 220, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = title,
		TextColor3 = titleColor,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 16,
		Parent = row,
	})
	create("TextLabel", {
		Position = UDim2.new(0, textLeft, 0, 36),
		Size = UDim2.new(1, -textLeft - 220, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = subtitle,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 13,
		Parent = row,
	})

	return create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0, 200, 0, 38),
		BackgroundTransparency = 1,
		Parent = row,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

local function offerValue(offer)
	local total = 0
	for _, entry in ipairs(offer) do
		total += entry.coinValue or 0
	end
	return total
end

local function renderTradeSession()
	local headerButtons = makeRow(0,
		"Trading with " .. trade.partner,
		C.Accent,
		trade.theyConfirmed and "They have confirmed — waiting on you." or "Neither side has confirmed yet.")

	addButton(headerButtons, 1, trade.youConfirmed and "UNCONFIRM" or "CONFIRM",
		trade.youConfirmed and C.Green or C.Accent, function()
			invoke(tradeConfirm, not trade.youConfirmed)
		end)
	addButton(headerButtons, 2, "CANCEL", C.Red, function()
		invoke(tradeCancel)
	end)

	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("YOUR OFFER  (%d / %d, worth %s)  —  changing it clears both confirmations",
			#trade.yours, trade.maxOffer, formatNumber(offerValue(trade.yours))),
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 13,
		LayoutOrder = 1,
		Parent = content,
	})

	-- Merge stars live on each player's profile, never on a copy, so a trade moves plain copies:
	-- what you give keeps your stars with you, and what you get arrives at your own star count
	-- for that brainrot. Each row says which, so a merged brainrot shown off on a podium can't be
	-- traded as if its stars came with it.
	local function myStars(name)
		return BrainrotData.ClampStars(profile and profile.stars and profile.stars[name])
	end

	local order = 1
	for _, entry in ipairs(trade.yours) do
		order += 1
		local stars = myStars(entry.name)
		local buttons = tradeRow(order, entry.name, Rarity.Color(entry.rarity),
			string.format("%s  •  %s coins%s", entry.rarity, formatNumber(entry.coinValue),
				stars > 0 and ("  •  your " .. BrainrotData.StarText(stars) .. " stay with you") or ""), entry.name)
		addButton(buttons, 1, "REMOVE", C.Red, function()
			invoke(tradeOffer, entry.name, false)
		end)
	end

	order += 1
	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("THEIR OFFER  (%d, worth %s)  —  merge stars stay with their owner%s", #trade.theirs,
			formatNumber(offerValue(trade.theirs)), trade.theyConfirmed and "  ✓ CONFIRMED" or ""),
		TextColor3 = trade.theyConfirmed and C.Green or C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 13,
		LayoutOrder = order,
		Parent = content,
	})

	if #trade.theirs == 0 then
		order += 1
		create("TextLabel", {
			Size = UDim2.new(1, -8, 0, 40),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = "They haven't offered anything yet.",
			TextColor3 = C.Muted,
			TextSize = 13,
			LayoutOrder = order,
			Parent = content,
		})
	end

	for _, entry in ipairs(trade.theirs) do
		order += 1
		local stars = myStars(entry.name)
		tradeRow(order, entry.name, Rarity.Color(entry.rarity),
			string.format("%s  •  %s coins  •  %s", entry.rarity, formatNumber(entry.coinValue),
				stars > 0 and ("arrives at your " .. BrainrotData.StarText(stars)) or "arrives unmerged for you"), entry.name)
	end

	order += 1
	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "ADD FROM YOUR COLLECTION",
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 13,
		LayoutOrder = order,
		Parent = content,
	})

	for _, entry in ipairs(profile.brainrots) do
		order += 1
		local stars = myStars(entry.name)
		local buttons = tradeRow(order, string.format("%s  x%d", entry.name, entry.count),
			Rarity.Color(entry.rarity),
			string.format("%s  •  %s coins each%s", entry.rarity, formatNumber(entry.coinValue),
				stars > 0 and ("  •  your " .. BrainrotData.StarText(stars) .. " stay with you") or ""), entry.name)
		addButton(buttons, 1, "ADD", C.Green, function()
			invoke(tradeOffer, entry.name, true)
		end, #trade.yours < trade.maxOffer)
	end
end

local function renderTrade()
	if not profile then
		return
	end

	if trade.active then
		renderTradeSession()
		return
	end

	if #profile.others == 0 then
		emptyMessage("Nobody else is in the server right now.\n\nTrading is lobby-only — you can't trade mid-match.")
		return
	end

	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = "Send a trade request. Both sides have to confirm before anything moves.",
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 13,
		LayoutOrder = 0,
		Parent = content,
	})

	for index, other in ipairs(profile.others) do
		local buttons = tradeRow(index, other.name, C.Text,
			other.showcase and ("Showing off: " .. other.showcase) or "No brainrot on their podium", other.showcase)

		addButton(buttons, 1, "TRADE", C.Accent, function()
			invoke(requestTrade, other.userId)
		end)
	end
end

-- A small 3D crate in its tier's colour — the same crate the opening animation uses, built
-- from parts in a ViewportFrame.
-- The crate on a card. It draws the SHARED crate (CrateModels), the same model the altar and the
-- reveal use, so claude-4a's per-tier identity — the dome, the peak, the crown, the present's ribbon
-- — reaches the card too. It used to build its own wooden block with two neon bands, which made the
-- card a third crate in the game and would have shown none of it. `tier` is optional: without one
-- (or with an unknown one) it falls back to that block, which is also what keeps this working for
-- callers that have only a colour.
local function crateIcon(parent, color, size, tier)
	local viewport = create("ViewportFrame", {
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(160, 160, 172),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Parent = parent,
	}, { rounded(10) })

	local shared = nil
	if tier and CrateData.Get(tier) then
		local ok, built = pcall(CrateModels.Crate, tier, { color = color })
		shared = ok and built or nil
	end
	if shared then
		shared.Parent = viewport
		local camera = Instance.new("Camera")
		camera.FieldOfView = 40
		camera.CFrame = CFrame.lookAt(Vector3.new(4.5, 4, -9), Vector3.new(0, 0.4, 0))
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		return viewport
	end

	local model = Instance.new("Model")
	local wood = Color3.fromRGB(150, 108, 62)
	local function block(blockSize, cframe, partColor, material)
		local part = Instance.new("Part")
		part.Size = blockSize
		part.CFrame = cframe
		part.Color = partColor
		part.Material = material
		part.Anchored = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
	end
	block(Vector3.new(4, 3, 3), CFrame.new(0, 0, 0), wood, Enum.Material.WoodPlanks)
	block(Vector3.new(4.1, 0.35, 3.1), CFrame.new(0, -0.95, 0), color, Enum.Material.Neon)
	block(Vector3.new(4.1, 0.35, 3.1), CFrame.new(0, 0.95, 0), color, Enum.Material.Neon)
	block(Vector3.new(4.2, 0.6, 3.2), CFrame.new(0, 1.8, 0), wood:Lerp(Color3.new(0, 0, 0), 0.12), Enum.Material.WoodPlanks)
	block(Vector3.new(4.26, 0.25, 3.26), CFrame.new(0, 1.8, 0), color, Enum.Material.Neon)
	block(Vector3.new(0.6, 0.7, 0.2), CFrame.new(0, 1.1, -1.6), Color3.fromRGB(255, 200, 60), Enum.Material.Foil)
	model.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(4.5, 4, -9), Vector3.new(0, 0.4, 0))
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

local BEST_DROPS_SHOWN = 5

-- The restock countdown at the top of the Crates and Cosmetics tabs. The loop at the bottom of
-- this file ticks it in place rather than redrawing the whole tab every second.
local stockTimerLabel = nil

local function stockHeader(order, text)
	stockTimerLabel = create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = text .. "  •  new stock in " .. ShopRotation.FormatTimeLeft(),
		TextColor3 = C.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 14,
		LayoutOrder = order,
		Parent = content,
	})
	stockTimerLabel:SetAttribute("Prefix", text)
end

local function renderCrates()
	-- Portrait phones leave about 300 px of content (claude-ee's shell: panel = clamp(viewportX - 40,
	-- 320, 1180), content = panel - 24). The card's normal layout sizes its text as "parent width
	-- minus 340", which at that width is a NEGATIVE size: the text vanishes rather than shrinking. So
	-- below NARROW_CARD the card stacks instead — text across the full width, the odds line wrapped
	-- onto two lines, and the buttons underneath. Landscape phones (603 px) keep the normal layout.
	local narrow, contentWidth = narrowContent()
	-- Where the text column starts and how much width it gets, in each layout.
	local textX = narrow and 88 or 124
	local textWidth = narrow and -96 or -340
	local TextService = game:GetService("TextService")

	-- Moves a statLine into the narrow layout. `wrap` is for the odds line: a displayed probability
	-- for a crate people BUY must never be cut off, so it wraps rather than truncating.
	-- `wrap`, when given, is the HEIGHT to give a wrapped line -- measured by the caller, not a
	-- guess. It used to be a fixed two lines, which is the same mistake that cut "Myth 0.40%  Secr
	-- 0.10%" off the end of the Style Crate rows: a displayed probability on something people buy
	-- may never be cut off, so the box has to fit the text rather than the text fit the box.
	local function fitLine(label, y, wrap)
		if not narrow then
			return label
		end
		label.Position = UDim2.new(0, textX, 0, y)
		label.Size = UDim2.new(1, textWidth, 0, wrap or label.Size.Y.Offset)
		if wrap then
			label.TextWrapped = true
			label.TextTruncate = Enum.TextTruncate.None
		end
		return label
	end

	local crateLuck = profile and profile.crateLuck or 1
	stockHeader(0, crateLuck > 1
		and string.format("CRATE SHOP  •  %dx CRATE LUCK ACTIVE: every open rolls %d times and keeps the rarest, and the odds below include it", crateLuck, crateLuck)
		or "CRATE SHOP  •  rarer crates are in stock less often")
	for index, tier in ipairs(CrateData.Order) do
		local crate = CrateData.Get(tier)
		local owned = profile and (profile.crates[tier] or 0) or 0
		local inStock = ShopRotation.IsCrateInStock(tier)
		local color = crate.color or Rarity.Color(tier)
		local category = crate.category or "Brainrot"

		-- The odds this player actually rolls with: CrateData.EffectiveOdds at the luck the server
		-- sends (crateLuck), the same function and value CrateService.Open uses. Roblox requires the
		-- odds shown for paid random items to be the real ones, so these must never be the base table
		-- for someone whose luck is boosted.
		-- A crate whose next open rolls at a different luck than the shop's table would print (the
		-- server says which, in crateBoosted) lists the rarities it can drop and no percentages: a
		-- percentage here would be a number the roll doesn't use, and that must never happen.
		local boosted = profile and profile.crateBoosted and profile.crateBoosted[tier] or false
		local luck = profile and profile.crateLuck or 1
		local odds = CrateData.OddsLine(crate, luck, boosted)

		-- How tall the odds line needs to be on THIS screen, and how far that pushes everything under
		-- it. Wide, the line has always fitted on one row (the render shows it); narrow, it is two
		-- rows on a landscape phone and three on a portrait one with 2x luck showing.
		local oddsText = table.concat(odds, "   ")
		local oddsHeight, shift = 18, 0
		if narrow then
			local column = math.max(80, contentWidth - 8 + textWidth)
			local bounds = TextService:GetTextSize(oddsText, 12, Enum.Font.GothamBold, Vector2.new(column, 10000))
			oddsHeight = math.max(32, bounds.Y + 2)
			shift = oddsHeight - 32
		end

		local card = create("Frame", {
			Size = UDim2.new(1, -8, 0, narrow and (200 + shift) or 118),
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = content,
		}, { rounded(10) })
		create("UIStroke", { Color = color, Thickness = 1.5, Transparency = 0.4, Parent = card })

		crateIcon(card, color, narrow and 72 or 102, tier).Position = UDim2.fromOffset(8, 8)

		local stockNote = crate.robuxOnly and "  •  ALWAYS IN STOCK" or (inStock and "" or "  •  SOLD OUT")
		fitLine(statLine(card, 8, string.format("%s  (owned: %d)%s", crate.name, owned, stockNote),
			color, Enum.Font.GothamBold, 17), 8)

		-- No pity counter on the card (Oliver, 2026-09-17: "get rid of the (rank) in 20 opens thing").
		-- The GUARANTEE itself is untouched — CrateService still forces the rarity up after a dry run,
		-- and the open still says "(guaranteed — your luck was due)" when it fires. Only the menu's
		-- running count is gone.
		fitLine(statLine(card, 32, oddsText, C.Text, Enum.Font.GothamBold, 12), 30, oddsHeight)
		if category == "Brainrot" then
			fitLine(statLine(card, 52, (crate.description or "") .. "  Best possible drops:", C.Muted, Enum.Font.Gotham, 12), 86 + shift)

			-- The rarest brainrots this crate can actually roll, shown as photos.
			local best = {}
			for rarityIndex = #Rarity.Order, 1, -1 do
				local rarityName = Rarity.Order[rarityIndex]
				if (crate.odds[rarityName] or 0) > 0 then
					for _, def in ipairs(BrainrotData.OfRarity(rarityName)) do
						if #best < BEST_DROPS_SHOWN then
							table.insert(best, def)
						end
					end
				end
			end
			for position, def in ipairs(best) do
				local photo = brainrotPhoto(card, def, 42)
				photo.Position = UDim2.fromOffset(textX + (position - 1) * 46, narrow and (106 + shift) or 70)
			end
		else
			-- Item crates: what they hold, and how much of that set you already own.
			local total, have = 0, 0
			for _, id in ipairs(CosmeticData.OfKind(category)) do
				total += 1
				if profile and profile.cosmetics.owned[id] then
					have += 1
				end
			end
			fitLine(statLine(card, 52, crate.description or "", C.Muted, Enum.Font.Gotham, 12), 86 + shift)
			fitLine(statLine(card, 76, string.format("You own %d / %d  •  duplicates refund %d%%", have, total,
				math.floor((crate.duplicateRefund or 0.3) * 100)), color, Enum.Font.GothamBold, 13), 106 + shift)
		end

		local buttons = create("Frame", {
			AnchorPoint = narrow and Vector2.new(0, 1) or Vector2.new(1, 0.5),
			Position = narrow and UDim2.new(0, textX, 1, -10) or UDim2.new(1, -10, 0.5, 0),
			Size = narrow and UDim2.new(1, textWidth, 0, 39) or UDim2.fromOffset(196, 39),
			BackgroundTransparency = 1,
			Parent = card,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.fromOffset(95, 39),
				CellPadding = UDim2.fromOffset(6, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})

		if crate.robuxOnly then
			-- Robux crates prompt the developer product; until its ID is set in GamepassConfig the
			-- button shows the price but can't be pressed.
			local product = crate.productKey and GamepassConfig.Products[crate.productKey]
			local price = product and product.suggestedPrice or 0
			local configured = product ~= nil and product.id > 0
			addButton(buttons, 1, price .. " R$", C.Accent, function()
				MarketplaceService:PromptProductPurchase(player, product.id)
			end, configured)
		else
			-- Out of stock only stops buying; crates you already have still open.
			local canAfford = profile and profile.coins >= crate.coinPrice
			addButton(buttons, 1, inStock and (formatNumber(crate.coinPrice) .. " C") or "SOLD OUT", C.Accent, function()
				invoke(buyCrate, tier)
			end, inStock and canAfford)
		end

		addButton(buttons, 2, "OPEN", C.Green, function()
			-- The luck this card's odds were drawn with (captured when it was drawn): the server refuses
			-- the open if the player's luck has changed since. A card drawn without percentages has no
			-- odds to be wrong, so it sends none and the server just rolls.
			invoke(openCrate, tier, not boosted and luck or nil)
		end, owned > 0)
	end
end

-- Skins, then auras, then accessories, then parachutes; within each, by rarity then price. `pairs`
-- order used to shuffle the list on every render.
local KIND_ORDER = { GunSkin = 1, Aura = 2, Accessory = 3, Parachute = 4 }

local function sortedCosmetics()
	local list = {}
	for _, item in pairs(CosmeticData.Items) do
		table.insert(list, item)
	end
	table.sort(list, function(a, b)
		local ka, kb = KIND_ORDER[a.kind] or 9, KIND_ORDER[b.kind] or 9
		if ka ~= kb then
			return ka < kb
		end
		local ra, rb = Rarity.Index[a.rarity] or 0, Rarity.Index[b.rarity] or 0
		if ra ~= rb then
			return ra < rb
		end
		local pa, pb = a.price or math.huge, b.price or math.huge
		if pa ~= pb then
			return pa < pb
		end
		return a.name < b.name
	end)
	return list
end

-- Parachute previews: the canopy itself, small, against the sky, left of the row's buttons, swinging
-- gently side to side. The tab redraws on every profile push, so each design is built once and
-- cloned after, and the swing only moves each preview's camera (one loop for all of them, which
-- drops a preview once its row is gone). In a do-block, since the main chunk is near Luau's limit
-- of 200 locals: only `parachutePreview` itself is a top-level local.
local parachutePreview
do
	-- A preview is decoration: if the designs module or one design fails, the row simply has no
	-- preview (and a warning says why) rather than the error taking the shop tab down with it.
	local loaded, ParachuteModels = pcall(require, Shared:WaitForChild("ParachuteModels"))
	if not loaded then
		warn("[MenuClient] parachute previews are off: " .. tostring(ParachuteModels))
	end
	local templates = {}
	local previews = {}

	function parachutePreview(row, id)
		if not loaded then
			return
		end
		local template = templates[id]
		if template == nil then
			local built, model = pcall(ParachuteModels.Build, id, { scale = ParachuteModels.WornScale })
			if not built or not model then
				warn(string.format("[MenuClient] no preview for parachute %s: %s", tostring(id), tostring(model)))
			end
			template = built and model or false
			templates[id] = template
		end
		if not template then
			return
		end
		local viewport = create("ViewportFrame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -118, 0.5, 0),
			Size = UDim2.fromOffset(96, 56),
			BackgroundColor3 = Color3.fromRGB(126, 182, 232),
			BorderSizePixel = 0,
			Ambient = Color3.fromRGB(170, 170, 182),
			LightColor = Color3.fromRGB(255, 250, 240),
			LightDirection = Vector3.new(-0.4, -1, 0.6),
			Parent = row,
		}, { rounded(8) })
		template:Clone().Parent = viewport
		local camera = Instance.new("Camera")
		camera.FieldOfView = 40
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		ParachuteModels.FrameCamera(camera, template)
		table.insert(previews, { viewport = viewport, camera = camera, base = camera.CFrame, phase = #previews * 0.9 })
	end

	-- A preview is the first thing to go when there's no room: on a phone held upright the row is
	-- barely 300 px wide and the name and price come first. It reappears when there's width again
	-- (a rotation, a wider window), so this is checked as the previews turn rather than once.
	--
	-- The threshold is makeRow's own: under NARROW_CONTENT it stacks the row, and the stacked subtitle
	-- runs the full width (1, -28) straight under where the preview sits. So the preview goes exactly
	-- when the row stacks, not at some width of its own. A row is the content area less 8.
	local PREVIEW_MIN_ROW = NARROW_CONTENT - 8

	RunService.Heartbeat:Connect(function()
		-- Nothing to do with the menu closed: the rows are still there, but nobody can see them swing.
		if #previews == 0 or not panel.Visible then
			return
		end
		local now = os.clock()
		for index = #previews, 1, -1 do
			local preview = previews[index]
			local row = preview.viewport.Parent
			if not row then
				table.remove(previews, index)
			else
				preview.viewport.Visible = row.AbsoluteSize.X >= PREVIEW_MIN_ROW
				if preview.viewport.Visible then
					-- The canopy is centred on the Y axis, so turning the camera about it swings round it.
					preview.camera.CFrame = CFrame.Angles(0, math.sin(now * 0.6 + preview.phase) * 0.55, 0) * preview.base
				end
			end
		end
	end)
end

-- What's on sale this rotation first, then everything you own, then the crate exclusives still to
-- find. Buyable items that aren't in stock right now are left out, with a note that more rotate in.
local function renderCosmetics()
	stockHeader(0, "SHOP  •  a new selection every 5 minutes, rarer items less often")
	-- Loaded here rather than at the top: the main chunk is at Luau's 200-local limit. require caches, and a
	-- module that fails to load just costs the rows their previews.
	local okPreview, cosmeticPreview = pcall(require, Shared:WaitForChild("CosmeticPreview"))
	if not okPreview then
		cosmeticPreview = nil
	end
	local cosmetics = profile and profile.cosmetics
	local sections = {
		{ title = "ON SALE NOW", items = {} },
		{ title = "YOUR COSMETICS", items = {} },
		{ title = "CRATE EXCLUSIVES", items = {} },
		{ title = "BUNDLE EXCLUSIVES", items = {} },
		-- `rankOnly`: earned by prestige, gun mastery or Brain Cells (ProgressionData.RankCosmetics).
		{ title = "RANK REWARDS  •  prestige, mastery and the Cell Shop", items = {} },
	}
	local rotatingOut = 0

	for _, item in ipairs(sortedCosmetics()) do
		if cosmetics and cosmetics.owned[item.id] then
			table.insert(sections[2].items, item)
		elseif item.rankOnly then
			table.insert(sections[5].items, item)
		elseif item.bundleOnly then
			table.insert(sections[4].items, item)
		elseif item.crateOnly or not item.price then
			table.insert(sections[3].items, item)
		elseif ShopRotation.IsCosmeticInStock(item.id) then
			table.insert(sections[1].items, item)
		else
			rotatingOut += 1
		end
	end

	local order = 0
	for sectionIndex, section in ipairs(sections) do
		if #section.items > 0 then
			order += 1
			create("TextLabel", {
				Size = UDim2.new(1, -8, 0, 26),
				BackgroundTransparency = 1,
				Font = Enum.Font.FredokaOne,
				Text = section.title,
				TextColor3 = sectionIndex == 1 and C.Green or C.Muted,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Bottom,
				TextSize = 17,
				LayoutOrder = order,
				Parent = content,
			})
		end

		for _, item in ipairs(section.items) do
			order += 1
			local id = item.id
			local equipped = cosmetics
				and (cosmetics.gunSkin == id or cosmetics.aura == id or cosmetics.accessory == id or cosmetics.parachute == id)

			local subtitle
			if item.kind == "Accessory" then
				subtitle = string.format("%s Accessory  •  %s", item.rarity, item.description)
			else
				subtitle = string.format("%s %s  •  %s", item.rarity or "", item.kind, item.description)
			end

			local buttons = makeRow(order, item.name, item.rarity and Rarity.Color(item.rarity) or item.color, subtitle)
			if item.kind == "Parachute" then
				parachutePreview(buttons.Parent, id)
			elseif cosmeticPreview and buttons.Parent.Size.Y.Offset <= 64 then
				-- Accessories, gun skins and auras get a live preview in the same spot as a parachute's
				-- (Shared/CosmeticPreview, finished and never hooked up). Only on a wide row: a stacked
				-- one on a narrow screen runs its subtitle under that spot. It tears itself down with the row.
				local holder = create("Frame", {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -118, 0.5, 0),
					Size = UDim2.fromOffset(72, 56),
					BackgroundTransparency = 1,
					Parent = buttons.Parent,
				}, { rounded(8) })
				pcall(cosmeticPreview.Fill, holder, id)
			end

			if sectionIndex == 5 then
				-- Where it's earned: the progression hub on the Pass tab. Rank cosmetic ids start with
				-- Prestige, Mastery or Cell (verify.py holds them to it), which picks the page.
				addButton(buttons, 1, "HOW", Color3.fromRGB(255, 150, 176), function()
					activeTab = string.find(id, "^Cell") and "CellShop" or string.find(id, "^Mastery") and "Mastery" or "Rank"
					renderTab()
				end)
			elseif sectionIndex == 4 then
				addButton(buttons, 1, "BUNDLES", C.Accent, function()
					activeTab = "Robux"
					renderTab()
				end)
			elseif sectionIndex == 3 then
				addButton(buttons, 1, "CRATES", C.PanelAlt, nil, false)
			elseif sectionIndex == 1 then
				local canAfford = profile and profile.coins >= item.price
				addButton(buttons, 1, formatNumber(item.price) .. " C", C.Accent, function()
					invoke(buyCosmetic, id)
				end, canAfford)
			elseif equipped then
				-- Toggles off on the server; clicking what's equipped removes it.
				addButton(buttons, 1, "UNEQUIP", C.Storm, function()
					invoke(equipCosmetic, id)
				end)
			else
				addButton(buttons, 1, "EQUIP", C.Green, function()
					invoke(equipCosmetic, id)
				end)
			end
		end
	end

	if rotatingOut > 0 then
		order += 1
		create("TextLabel", {
			Size = UDim2.new(1, -8, 0, 40),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = string.format("%d more items rotate through the shop. Check back when the stock changes.", rotatingOut),
			TextColor3 = C.Muted,
			TextWrapped = true,
			TextSize = 13,
			LayoutOrder = order,
			Parent = content,
		})
	end
end

local function describeReward(reward)
	if reward.kind == "Coins" then
		return string.format("%s SahurCoins", formatNumber(reward.amount))
	elseif reward.kind == "Crate" then
		return reward.crate .. " Crate"
	end
	return "Cosmetic"
end

local function renderPass()
	if not profile then
		return
	end

	-- The progression hub shares this tab: a PASS | RANK | MASTERY | INDEX | CELL SHOP toggle on top,
	-- and every page but PASS is drawn by ProgressionPanel instead of the pass list below.
	if ProgressionPanel.Render(content, profile, { rerender = renderTab, noTabs = true }) then
		return
	end

	local pass = profile.pass

	-- Every unlocked, unclaimed reward, for the CLAIM ALL button.
	local claimable = 0
	for tier = 1, math.min(pass.tier, BattlePassData.MaxTier) do
		if not pass.claimedFree[tostring(tier)] then
			claimable += 1
		end
		if pass.premium and not pass.claimedPremium[tostring(tier)] then
			claimable += 1
		end
	end

	-- Your record at the top: the numbers the leaderboards and titles are built on.
	local stats = profile.stats or {}
	local unlockedTitles = 0
	if profile.achievements and profile.achievements.list then
		for _, achievement in ipairs(profile.achievements.list) do
			if achievement.unlocked then
				unlockedTitles += 1
			end
		end
	end
	local statsCard = create("Frame", {
		Size = UDim2.new(1, -8, 0, 64),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		LayoutOrder = -1,
		Parent = content,
	}, { rounded(10), create("UIStroke", { Color = C.Accent, Thickness = 1.5, Transparency = 0.5 }) })
	local cells = {
		{ "LEVEL", tostring(pass.tier) },
		{ "WINS", formatNumber(stats.wins or 0) },
		{ "KILLS", formatNumber(stats.kills or 0) },
		{ "MATCHES", formatNumber(stats.matches or 0) },
		{ "K / MATCH", string.format("%.1f", (stats.kills or 0) / math.max(1, stats.matches or 0)) },
		{ "TITLES", string.format("%d / %d", unlockedTitles, profile.achievements and #profile.achievements.list or 0) },
		{ "COLLECTION", formatNumber(profile.brainrotValue or 0) .. " C" },
	}
	for index, cell in ipairs(cells) do
		local x = (index - 1) / #cells
		create("TextLabel", {
			Position = UDim2.new(x, 6, 0, 8),
			Size = UDim2.new(1 / #cells, -12, 0, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = cell[1],
			TextColor3 = C.Muted,
			TextSize = 10,
			Parent = statsCard,
		})
		create("TextLabel", {
			Position = UDim2.new(x, 6, 0, 24),
			Size = UDim2.new(1 / #cells, -12, 0, 30),
			BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne,
			Text = cell[2],
			TextColor3 = index == 1 and C.Accent or C.Text,
			TextScaled = true,
			Parent = statsCard,
		}, { create("UITextSizeConstraint", { MaxTextSize = 22 }) })
	end

	local headerButtons = makeRow(0,
		string.format("Tier %d / %d", pass.tier, pass.maxTier),
		C.Accent,
		string.format("%d / %d XP to next tier%s",
			pass.xpIntoTier, pass.xpPerTier, pass.premium and "  •  PREMIUM ACTIVE" or ""))

	-- The Daily Spin, the same one as the booth on the island: coins, crates, an accessory, a
	-- brainrot or a pass for a day, with a streak that multiplies the coins.
	addButton(headerButtons, 1,
		profile.daily.available and "DAILY SPIN" or "SPUN TODAY",
		C.Green,
		function()
			invoke(claimDaily)
		end,
		profile.daily.available)
	makeRow(0.5, string.format("Daily Spin  •  day %d streak", profile.daily.streak or 0), C.Green,
		"Coins, a Rare or Epic Crate, an accessory, a Rare/Epic brainrot, or any pass for 24 hours. Each streak day adds +10% to the coin prizes (up to 2x). The wheel at the Market Row booth is the same spin.")

	if not pass.premium then
		local passDef = GamepassConfig.Passes.BrainrotPassPremium
		if passDef.id > 0 then
			addButton(headerButtons, 2, "GET PREMIUM", C.Accent, function()
				MarketplaceService:PromptGamePassPurchase(player, passDef.id)
			end)
		end
	end

	addButton(headerButtons, 3, claimable > 0 and ("CLAIM ALL " .. claimable) or "CLAIM ALL", C.Green, function()
		invoke(claimPassAll)
	end, claimable > 0)

	for tier = 1, BattlePassData.MaxTier do
		local tierDef = BattlePassData.Tiers[tier]
		local unlocked = pass.tier >= tier
		local freeClaimed = pass.claimedFree[tostring(tier)]
		local premiumClaimed = pass.claimedPremium[tostring(tier)]

		-- Unlocked with something still to collect on either track.
		local ready = unlocked and (not freeClaimed or (pass.premium and not premiumClaimed))
		local buttons = makeRow(tier,
			ready and ("Tier " .. tier .. "  •  READY") or ("Tier " .. tier),
			ready and C.Green or (unlocked and C.Text or C.Muted),
			string.format("Free: %s    Premium: %s",
				describeReward(tierDef.free), describeReward(tierDef.premium)))

		addButton(buttons, 1, freeClaimed and "CLAIMED" or "FREE", C.Green, function()
			invoke(claimPassTier, tier, "free")
		end, unlocked and not freeClaimed)

		addButton(buttons, 2, premiumClaimed and "CLAIMED" or "PREMIUM", C.Accent, function()
			invoke(claimPassTier, tier, "premium")
		end, unlocked and pass.premium and not premiumClaimed)
	end
end

--------------------------------------------------------------------------------
-- Quests tab
--------------------------------------------------------------------------------

-- The reset countdown at the top of the tab; ticked in place by the loop at the bottom of the file.
local questTimerLabel = nil
-- When today's quests roll over, on our clock, from the last profile push.
local questResetAt = 0

local QUEST_TIER_COLOR = { easy = C.Green, medium = C.Accent, hard = Color3.fromRGB(255, 110, 200), weekly = Color3.fromRGB(110, 210, 255) }
local QUEST_TIER_LABEL = { easy = "EASY", medium = "MEDIUM", hard = "HARD", weekly = "WEEKLY" }

local function renderQuests()
	local quests = profile and profile.quests
	if not quests then
		emptyMessage("Loading your quests…")
		return
	end

	questTimerLabel = create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "DAILY QUESTS",
		TextColor3 = C.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 14,
		LayoutOrder = 0,
		Parent = content,
	})

	local function questCard(order, quest)
		-- On a narrow screen the reward moves under the title instead of beside it, and the card
		-- grows by that line. The title was sized `1, -310` to leave room for a 200 px reward on the
		-- right: correct at 728 of content, and MINUS 14 px at the 296 a portrait phone gives, where
		-- a negative width draws nothing at all rather than truncating. Measured by
		-- tools/menu_hud_audit.py's narrow check.
		local narrow = shell.Form ~= "large"
		local rewardDrop = narrow and 22 or 0
		local color = QUEST_TIER_COLOR[quest.tier] or C.Text
		local card = create("Frame", {
			Size = UDim2.new(1, -8, 0, 84 + rewardDrop),
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = content,
		}, { rounded(10) })
		create("UIStroke", { Color = color, Thickness = 1.5, Transparency = quest.done and 0.15 or 0.6, Parent = card })

		create("TextLabel", {
			Position = UDim2.fromOffset(14, 10),
			Size = UDim2.fromOffset(0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBlack,
			Text = quest.done and "DONE" or (QUEST_TIER_LABEL[quest.tier] or "QUEST"),
			TextColor3 = Color3.new(0, 0, 0),
			TextSize = 11,
			Parent = card,
		}, {
			rounded(5),
			create("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7) }),
		})

		create("TextLabel", {
			Position = UDim2.fromOffset(92, 8),
			Size = narrow and UDim2.new(1, -106, 0, 22) or UDim2.new(1, -310, 0, 22),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = quest.title,
			TextColor3 = quest.done and C.Muted or C.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 16,
			Parent = card,
		})

		create("TextLabel", {
			AnchorPoint = narrow and Vector2.new(0, 0) or Vector2.new(1, 0),
			Position = narrow and UDim2.fromOffset(92, 30) or UDim2.new(1, -14, 0, 8),
			Size = narrow and UDim2.new(1, -106, 0, 20) or UDim2.fromOffset(200, 22),
			BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne,
			Text = string.format("+%s C  •  +%d XP%s", formatNumber(quest.coins), quest.xp, quest.crate and ("  •  " .. quest.crate .. " Crate") or ""),
			TextColor3 = color,
			TextXAlignment = narrow and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
			TextSize = quest.crate and 14 or 16,
			Parent = card,
		})

		local track = create("Frame", {
			Position = UDim2.fromOffset(14, 44 + rewardDrop),
			Size = UDim2.new(1, -28, 0, 12),
			BackgroundColor3 = C.PanelAlt,
			BorderSizePixel = 0,
			Parent = card,
		}, { rounded(6) })
		create("Frame", {
			Size = UDim2.fromScale(math.clamp(quest.progress / math.max(1, quest.target), 0, 1), 1),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = track,
		}, { rounded(6) })

		create("TextLabel", {
			Position = UDim2.fromOffset(14, 60 + rewardDrop),
			Size = UDim2.new(1, -28, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = string.format("%s / %s", formatNumber(quest.progress), formatNumber(quest.target)),
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 12,
			Parent = card,
		})
	end

	for index, quest in ipairs(quests.list) do
		questCard(index, quest)
	end

	local order = #quests.list + 1
	local bonusDone = quests.bonusClaimed
	local buttons = makeRow(order,
		bonusDone and "All three done — bonus claimed!" or string.format("Finish all three  •  %d / %d done", quests.doneCount, quests.total),
		bonusDone and C.Green or C.Text,
		string.format("+1 %s Crate on top, paid the moment the last one completes", quests.bonusCrate))
	addButton(buttons, 1, bonusDone and "CLAIMED" or "BONUS", bonusDone and C.Green or C.PanelAlt, nil, false)

	-- Weekly challenges: bigger targets, a crate each.
	if quests.weekly and #quests.weekly > 0 then
		order += 1
		create("TextLabel", {
			Size = UDim2.new(1, -8, 0, 30),
			BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne,
			Text = string.format("WEEKLY CHALLENGES  •  %s left", QuestData.FormatReset(quests.weekResetIn or 0)),
			TextColor3 = QUEST_TIER_COLOR.weekly,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			TextSize = 17,
			LayoutOrder = order,
			Parent = content,
		})
		for _, quest in ipairs(quests.weekly) do
			order += 1
			questCard(order, quest)
		end
	end

	-- Achievements: lifetime milestones, each with a title to wear on your nameplate.
	local achievements = profile.achievements
	if achievements and achievements.list then
		order += 1
		local worn = achievements.title
		create("TextLabel", {
			Size = UDim2.new(1, -8, 0, 30),
			BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne,
			Text = "ACHIEVEMENTS & TITLES" .. (worn and "" or "  •  unlock one to wear a title"),
			TextColor3 = C.Accent,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			TextSize = 17,
			LayoutOrder = order,
			Parent = content,
		})
		for _, achievement in ipairs(achievements.list) do
			order += 1
			local equipped = worn == achievement.id
			local buttons = makeRow(order,
				string.format("%s  —  \"%s\"", achievement.name, achievement.title),
				achievement.unlocked and C.Accent or C.Muted,
				string.format("%s  •  %s / %s  •  +%s C", achievement.description,
					formatNumber(achievement.progress), formatNumber(achievement.target), formatNumber(achievement.coins)))
			if not achievement.unlocked then
				addButton(buttons, 1, "LOCKED", C.PanelAlt, nil, false)
			elseif equipped then
				addButton(buttons, 1, "WEARING", C.Green, function()
					invoke(setTitle, nil)
				end)
			else
				addButton(buttons, 1, "WEAR", C.Accent, function()
					invoke(setTitle, achievement.id)
				end)
			end
		end
		order += 1
	end

	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 40),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = "New quests every day at midnight UTC and new challenges every week — the same for everyone. Rewards land as soon as one completes, in any match on any server. The tracker on the left keeps today's in view wherever you are.",
		TextColor3 = C.Muted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 12,
		LayoutOrder = order + 1,
		Parent = content,
	})
end

local function sortedByOrder(source)
	local entries = {}
	for _, definition in pairs(source) do
		table.insert(entries, definition)
	end
	table.sort(entries, function(a, b)
		return (a.order or 99) < (b.order or 99)
	end)
	return entries
end

-- Products whose ID is still 0 can't be bought, so a live game hides them. Studio shows them with
-- the price greyed out, so the whole shop can be seen before monetization is set up.
local IS_STUDIO = RunService:IsStudio()

local function shopVisible(definition)
	return definition.id > 0 or IS_STUDIO
end

-- A bundle with a `limit` the player has already bought up to.
local function bundleSoldOut(product)
	local bought = profile and profile.bundles and profile.bundles[product.key] or 0
	return product.limit ~= nil and bought >= product.limit
end

local function cosmeticLabel(id)
	local item = CosmeticData.Get(id)
	if not item then
		return id
	end
	return item.kind == "GunSkin" and (item.name .. " Skin") or item.name
end

local function shopSection(order, text, color)
	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = text,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		TextSize = 17,
		LayoutOrder = order,
		Parent = content,
	})
end

local LOOP_PULSE = TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local LOOP_SHINE = TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, false, 1.4)

-- A big card for a featured product: its crate, a badge, everything inside, what it's worth and a
-- price button. Anything still buyable pulses, with a shine sweeping across it.
local function featuredCard(order, product)
	local color = product.color or C.Accent
	local configured = product.id > 0
	local soldOut = bundleSoldOut(product)
	local canBuy = configured and not soldOut
	local lines = product.grant.kind == "Bundle" and GamepassConfig.DescribeContents(product.grant, cosmeticLabel) or nil
	local rows = lines and math.ceil(#lines / 2) or 0

	local card = create("Frame", {
		Size = UDim2.new(1, -8, 0, math.max(128, 70 + rows * 20 + 12)),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = order,
		Parent = content,
	}, {
		rounded(12),
		create("UIGradient", {
			Rotation = 15,
			Color = ColorSequence.new(color:Lerp(C.Panel, 0.68), C.Panel),
		}),
	})
	local stroke = create("UIStroke", { Color = color, Thickness = 2, Transparency = 0.1, Parent = card })

	if not soldOut then
		TweenService:Create(stroke, LOOP_PULSE, { Transparency = 0.75 }):Play()
		local shine = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(-0.15, 0, 0, 0),
			Size = UDim2.new(0, 140, 1, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Parent = card,
		}, {
			create("UIGradient", {
				Rotation = 25,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.5, 0.86),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		})
		TweenService:Create(shine, LOOP_SHINE, { Position = UDim2.new(1.15, 0, 0, 0) }):Play()
	end

	-- A featured CRATE product shows that crate; a bundle keeps the generic one.
	crateIcon(card, color, 104, product.grant.kind == "Crate" and product.grant.crate or nil).Position = UDim2.fromOffset(12, 12)

	create("TextLabel", {
		Position = UDim2.fromOffset(130, 10),
		Size = UDim2.fromOffset(0, 20),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = soldOut and C.PanelAlt or color,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBlack,
		Text = soldOut and "OWNED" or (product.badge or "FEATURED"),
		TextColor3 = soldOut and C.Muted or Color3.new(0, 0, 0),
		TextSize = 12,
		Parent = card,
	}, {
		rounded(6),
		create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	})

	create("TextLabel", {
		Position = UDim2.fromOffset(130, 32),
		Size = UiKit.textSpan(select(2, narrowContent()), 310, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = product.name,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 26,
		Parent = card,
	})

	if lines then
		-- Two columns between the crate and the price.
		for index, text in ipairs(lines) do
			local column = (index - 1) % 2
			local row = (index - 1) // 2
			create("TextLabel", {
				Position = UDim2.new(column * 0.5, column == 0 and 130 or -25, 0, 66 + row * 20),
				Size = UDim2.new(0.5, -159, 0, 18),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = "+ " .. text,
				TextColor3 = C.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextSize = 13,
				Parent = card,
			})
		end
	else
		create("TextLabel", {
			Position = UDim2.fromOffset(130, 66),
			Size = UiKit.textSpan(select(2, narrowContent()), 310, 52),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = product.description,
			TextColor3 = C.Text,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextSize = 13,
			Parent = card,
		})
	end

	local side = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(160, 100),
		BackgroundTransparency = 1,
		Parent = card,
	})
	create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = product.worth or "",
		TextColor3 = color,
		TextWrapped = true,
		TextSize = 13,
		Parent = side,
	})
	local button = create("TextButton", {
		Position = UDim2.fromOffset(0, 36),
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundColor3 = canBuy and color or C.PanelAlt,
		BorderSizePixel = 0,
		AutoButtonColor = canBuy,
		Font = Enum.Font.FredokaOne,
		Text = soldOut and "OWNED" or (product.suggestedPrice .. " R$"),
		TextColor3 = canBuy and Color3.new(0, 0, 0) or C.Muted,
		TextSize = 22,
		Parent = side,
	}, { rounded(10) })

	if canBuy then
		button.Activated:Connect(function()
			Sfx.Play("UiClick", 0.08)
			MarketplaceService:PromptProductPurchase(player, product.id)
		end)
	elseif not configured and not soldOut then
		create("TextLabel", {
			Position = UDim2.fromOffset(0, 84),
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = "Studio: set its ID in GamepassConfig",
			TextColor3 = C.Muted,
			TextSize = 10,
			Parent = side,
		})
	end
end

local function renderRobuxShop()
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	local featured = {}
	for _, product in ipairs(GamepassConfig.Featured()) do
		if shopVisible(product) then
			table.insert(featured, product)
		end
	end
	if #featured > 0 then
		shopSection(nextOrder(), "FEATURED DEALS", C.Accent)
		for _, product in ipairs(featured) do
			featuredCard(nextOrder(), product)
		end
	end

	local passes = {}
	for _, pass in ipairs(sortedByOrder(GamepassConfig.Passes)) do
		if shopVisible(pass) then
			table.insert(passes, pass)
		end
	end
	if #passes > 0 then
		shopSection(nextOrder(), "GAMEPASSES  •  yours forever", C.Storm)
		for _, pass in ipairs(passes) do
			local owned = profile and profile.ownedPasses[pass.key]
			local tempLeft = profile and profile.tempPasses and profile.tempPasses[pass.key]
			local buttons = makeRow(nextOrder(), pass.name, C.Text,
				tempLeft and string.format("%s   •   ACTIVE from the Daily Spin, %dh %02dm left", pass.description, math.floor(tempLeft / 3600), math.floor(tempLeft % 3600 / 60))
					or pass.description)
			if owned and not tempLeft then
				addButton(buttons, 1, "OWNED", C.Green, nil, false)
			else
				addButton(buttons, 1, pass.suggestedPrice .. " R$", C.Accent, function()
					MarketplaceService:PromptGamePassPurchase(player, pass.id)
				end, pass.id > 0)
			end
		end
	end

	-- Brainrots for Robux: one row per rarity. Each product only sells through the brainrot picker
	-- (the Codex's buy buttons), which tells the server exactly which brainrot is being bought, so
	-- these rows open the Codex at that rarity rather than prompting a purchase directly.
	local brainrotRows = {}
	for index = #Rarity.Order, 1, -1 do
		local rarityName = Rarity.Order[index]
		local product = GamepassConfig.BrainrotProduct(rarityName)
		if product and shopVisible(product) then
			table.insert(brainrotRows, { rarity = rarityName, product = product })
		end
	end
	if #brainrotRows > 0 then
		shopSection(nextOrder(), "BRAINROTS  •  pick exactly the one you want", Rarity.Color("Mythic"))
		for _, entry in ipairs(brainrotRows) do
			local buttons = makeRow(nextOrder(), string.format("Any %s brainrot  •  %d R$", entry.rarity, entry.product.suggestedPrice),
				Rarity.Color(entry.rarity), string.format("Choose any of the %d %s brainrots and it goes straight into your collection.",
					#BrainrotData.OfRarity(entry.rarity), entry.rarity))
			addButton(buttons, 1, "CHOOSE", Rarity.Color(entry.rarity), function()
				codexMode = true
				brainrotFilter = entry.rarity
				activeTab = "Brainrots"
				renderTab()
			end, entry.product.id > 0 or IS_STUDIO)
		end
	end

	local products = {}
	for _, product in ipairs(sortedByOrder(GamepassConfig.Products)) do
		if not product.featured and not product.brainrotShop and shopVisible(product) then
			table.insert(products, product)
		end
	end
	if #products > 0 then
		shopSection(nextOrder(), "CRATES, BOOSTS & COINS", C.Green)
		for _, product in ipairs(products) do
			local buttons = makeRow(nextOrder(), product.name, C.Text, product.description)
			addButton(buttons, 1, product.suggestedPrice .. " R$", C.Green, function()
				MarketplaceService:PromptProductPurchase(player, product.id)
			end, product.id > 0)
		end
	end

	if order == 0 then
		emptyMessage("No passes or products set up yet.\n\nCreate them on the Roblox Creator Dashboard, then paste their IDs into ReplicatedStorage.Shared.GamepassConfig.")
	elseif IS_STUDIO then
		create("TextLabel", {
			Size = UDim2.new(1, -8, 0, 40),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = "Studio preview: greyed-out prices have no ID yet and are hidden in a live game. Paste IDs into GamepassConfig.",
			TextColor3 = C.Muted,
			TextWrapped = true,
			TextSize = 12,
			LayoutOrder = nextOrder(),
			Parent = content,
		})
	end
end

--------------------------------------------------------------------------------
-- Settings tab
--------------------------------------------------------------------------------

-- The action waiting for a new key, and when a key was last captured: the press that sets a
-- binding must not also do what that key does (capturing M would otherwise close the menu).
local listeningFor = nil
local listenConnection = nil
local lastKeyCaptureAt = 0
local settingsNotice = nil

local function stopListening()
	listeningFor = nil
	if listenConnection then
		listenConnection:Disconnect()
		listenConnection = nil
	end
end

local function settingsHeader(order, text, onReset)
	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, 32),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = content,
	})
	create("TextLabel", {
		Size = UDim2.new(1, -110, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = text,
		TextColor3 = C.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		TextSize = 19,
		Parent = row,
	})
	local reset = create("TextButton", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(100, 26),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = "RESET",
		TextColor3 = C.Muted,
		TextSize = 12,
		Parent = row,
	}, { rounded(6) })
	reset.Activated:Connect(function()
		Sfx.Play("UiClick", 0.08)
		stopListening()
		settingsNotice = text .. " reset to defaults."
		onReset()
		renderTab()
	end)
end

local function settingsRow(order, label)
	local row = create("Frame", {
		Size = UDim2.new(1, -8, 0, 42),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = content,
	}, { rounded(8) })
	create("TextLabel", {
		Position = UDim2.new(0, 14, 0, 0),
		Size = UDim2.new(0.45, -14, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = label,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 14,
		Parent = row,
	})
	return row
end

local function formatSetting(entry, value)
	if entry.percent then
		return string.format("%d%%", math.floor(value * 100 + 0.5))
	elseif entry.id == "FieldOfView" then
		return string.format("%d°", value)
	end
	return string.format("%.2fx", value)
end

local function keyRow(order, action)
	local row = settingsRow(order, action.label)
	local listening = listeningFor == action.id
	local button = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(150, 30),
		BackgroundColor3 = listening and C.Accent or C.PanelAlt,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = listening and "Press a key…" or Settings.KeyLabel(action.id),
		TextColor3 = listening and Color3.new(0, 0, 0) or C.Text,
		TextSize = 14,
		Parent = row,
	}, { rounded(6) })

	button.Activated:Connect(function()
		Sfx.Play("UiClick", 0.08)
		stopListening()
		listeningFor = action.id
		settingsNotice = "Press the new key for " .. action.label .. " (Escape cancels)."
		listenConnection = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return
			end
			lastKeyCaptureAt = os.clock()
			if input.KeyCode == Enum.KeyCode.Escape then
				settingsNotice = nil
			elseif Settings.SetKey(action.id, input.KeyCode) then
				settingsNotice = action.label .. " is now " .. Settings.KeyLabel(action.id) .. "."
			else
				settingsNotice = input.KeyCode.Name .. " is kept for movement, chat or Roblox itself. Pick another key."
			end
			stopListening()
			renderTab()
		end)
		renderTab()
	end)
end

local function sliderRow(order, entry)
	local row = settingsRow(order, entry.label)
	local valueLabel = create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(60, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = C.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 14,
		Parent = row,
	})
	local track = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -84, 0.5, 0),
		Size = UDim2.fromOffset(240, 10),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Parent = row,
	}, { rounded(5) })
	local fill = create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { rounded(5) })
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = C.Text,
		BorderSizePixel = 0,
		Parent = track,
	}, { rounded(9) })

	local function show(value)
		local alpha = (value - entry.min) / (entry.max - entry.min)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		valueLabel.Text = formatSetting(entry, value)
	end
	show(Settings.Get(entry.id))

	local function setFromX(x)
		local alpha = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		Settings.Set(entry.id, entry.min + alpha * (entry.max - entry.min))
		show(Settings.Get(entry.id))
	end

	-- Drag listeners exist only while the button is held, so re-rendering never leaks them.
	track.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		setFromX(input.Position.X)
		local moved, ended
		moved = UserInputService.InputChanged:Connect(function(change)
			if change.UserInputType == Enum.UserInputType.MouseMovement or change.UserInputType == Enum.UserInputType.Touch then
				setFromX(change.Position.X)
			end
		end)
		ended = UserInputService.InputEnded:Connect(function(finish)
			if finish.UserInputType == input.UserInputType then
				moved:Disconnect()
				ended:Disconnect()
			end
		end)
	end)
end

local function toggleRow(order, entry)
	local row = settingsRow(order, entry.label)
	local on = Settings.Get(entry.id)
	local button = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(90, 30),
		BackgroundColor3 = on and C.Green or C.PanelAlt,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = on and "ON" or "OFF",
		TextColor3 = on and Color3.new(0, 0, 0) or C.Muted,
		TextSize = 14,
		Parent = row,
	}, { rounded(6) })
	button.Activated:Connect(function()
		Sfx.Play("UiClick", 0.08)
		Settings.Set(entry.id, not Settings.Get(entry.id))
		renderTab()
	end)
end

local SETTINGS_SECTIONS = {
	{ title = "CONTROLS", groups = { "Combat", "Loadout", "General" }, list = Settings.Actions, row = keyRow },
	{ title = "AUDIO", groups = { "Audio" }, list = Settings.Sliders, row = sliderRow },
	{ title = "CAMERA", groups = { "Camera" }, list = Settings.Sliders, row = sliderRow },
	{ title = "GAMEPLAY", groups = { "Gameplay" }, list = Settings.Toggles, row = toggleRow },
}

local function renderSettings()
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	create("TextLabel", {
		Size = UDim2.new(1, -8, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = settingsNotice or "Click a key to rebind it. Everything saves to your profile automatically.",
		TextColor3 = settingsNotice and C.Accent or C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 13,
		LayoutOrder = nextOrder(),
		Parent = content,
	})

	for _, section in ipairs(SETTINGS_SECTIONS) do
		settingsHeader(nextOrder(), section.title, function()
			for _, group in ipairs(section.groups) do
				Settings.ResetGroup(group)
			end
		end)
		for _, group in ipairs(section.groups) do
			for _, entry in ipairs(section.list) do
				if entry.group == group then
					section.row(nextOrder(), entry)
				end
			end
		end
	end
end

-- The STYLE CRATES: cosmetic crates in tiers (Oliver, 2026-09-18). One renderer, two placements —
-- its own destination on desktop and landscape phones, and a filter inside CRATES on a portrait
-- phone, where five destinations is the budget. The shell decides which; this draws the same cards.
--
-- Every tier is sold for coins AND Robux, so each card carries two prices and an odds line. That
-- makes it the densest row in the menu, which is why it is built on UiParts.splitRow: the odds line
-- is a `disclosure`, so it wraps and never truncates at any width — a cut-off probability on
-- something people buy is a wrong number, not an untidy one. These crates are never touched by
-- Beginner's Luck (CrateData.BeginnerBoosted is brainrot-only), so their odds are always exact.
local STYLE_TIERS = { "Style", "DeluxeStyle", "PrestigeStyle" }

local function renderStyleCrates()
	local _, width = narrowContent()
	stockHeader(0, "STYLE CRATES  •  accessories, gun skins, auras and parachutes, never one you own")
	for index, tier in ipairs(STYLE_TIERS) do
		local crate = CrateData.Get(tier)
		local owned = profile and (profile.crates[tier] or 0) or 0
		local luck = profile and profile.crateLuck or 1
		local product = crate.productKey and GamepassConfig.Products[crate.productKey]
		local canAfford = profile and crate.coinPrice and profile.coins >= crate.coinPrice
		local actions = {
			{ kind = "primary", text = "OPEN", width = 92, enabled = owned > 0, onClick = function()
				Sfx.Play("UiClick", 0.08)
				invoke(openCrate, tier, luck)
			end },
			{ kind = "secondary", text = formatNumber(crate.coinPrice) .. " C", width = 104, enabled = canAfford == true, onClick = function()
				Sfx.Play("UiClick", 0.08)
				invoke(buyCrate, tier)
			end },
			{ kind = "secondary", text = (product and product.suggestedPrice or 0) .. " R$", width = 96,
				enabled = product ~= nil and product.id > 0, onClick = function()
					MarketplaceService:PromptProductPurchase(player, product.id)
				end },
		}
		-- Room for the heading, the description and THREE lines of odds. A Style tier lists up to
		-- seven rarities, which is about 90 characters: at the row's text width that is two lines at
		-- best and three when the panel is narrow, and the row has to be tall enough for the worst
		-- case before the label is measured.
		local lineHeight = UiKit.Type.Caption.Size + 6
		local row = UiParts.splitRow(content, {
			width = width,
			mediaInstance = crateIcon(nil, crate.color or Rarity.Color(tier), 102, tier),
			textHeight = UiKit.Type.Heading.Size + 6 + lineHeight * 4,
			layoutOrder = index,
			actions = actions,
		})
		row.Line({ text = string.format("%s  (owned: %d)", crate.name, owned), style = UiKit.Type.Heading,
			color = crate.color or Rarity.Color(tier) })
		row.Line({ text = crate.description or "", style = UiKit.Type.Caption, color = UiKit.Role.TextMuted })
		-- The odds are drawn here rather than through row.Line because a Line is a fixed one or two
		-- lines tall and CLIPS what doesn't fit -- which cut "Myth 0.40%  Secr 0.10%" off the end of
		-- the Style Crate's odds, the two rarities somebody spending 8,000 coins is buying for. A
		-- displayed probability on something sold may never be cut off, so this label grows to fit
		-- (AutomaticSize) and truncation is off outright.
		UiParts.text(row.Text, UiKit.Type.Caption, table.concat(CrateData.OddsLine(crate, luck, false), "   "),
			UiKit.Role.Text, {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
				TextYAlignment = Enum.TextYAlignment.Top,
				LayoutOrder = 3,
			})
		-- No guarantee line here either, for the same reason the brainrot cards lost theirs (Oliver,
		-- 2026-09-17: "get rid of the (rank) in 20 opens thing"). The guarantee still fires -- pity
		-- lives in CrateService and the open says "(guaranteed -- your luck was due)" when it does --
		-- and the odds on the row stay the real per-roll odds, which pity only ever improves on.
	end
end

local TABS = {
	{ key = "Brainrots", label = "Brainrots", render = renderBrainrots },
	{ key = "Trade", label = "Trade", render = renderTrade },
	{ key = "Crates", label = "Crates", render = renderCrates },
	{ key = "Style", label = "Style Crates", render = renderStyleCrates },
	{ key = "Cosmetics", label = "Cosmetics", render = renderCosmetics },
	-- Oliver 09-22 14:15: rank, mastery and the cell shop were all under the Pass tab. Each progression
	-- page is its own tab now; they share the Pass renderer, which hands every page but PASS to
	-- ProgressionPanel.
	{ key = "Pass", label = "Pass", render = function() ProgressionPanel.View = "Pass"; renderPass() end },
	{ key = "Rank", label = "Rank", render = function() ProgressionPanel.View = "Rank"; renderPass() end },
	{ key = "Mastery", label = "Mastery", render = function() ProgressionPanel.View = "Mastery"; renderPass() end },
	{ key = "Index", label = "Rot Index", render = function() ProgressionPanel.View = "Index"; renderPass() end },
	{ key = "CellShop", label = "Cell Shop", render = function() ProgressionPanel.View = "Shop"; renderPass() end },
	{ key = "Quests", label = "Quests", render = renderQuests },
	{ key = "Robux", label = "Robux Shop", render = renderRobuxShop },
	{ key = "Settings", label = "Settings", render = renderSettings },
}

-- The eight tabs, handed to the shell as destinations. The old strip was eight 85x34 buttons in a
-- 728 px row -- under the 44 px touch target, with no room for a ninth -- and the shell draws them
-- as a rail, an icon rail or a bottom bar depending on the screen. The glyphs and subtitles are new;
-- everything else, including which renderer each one runs, is unchanged.
--
-- BEFORE YOU ADD A DESTINATION, the arithmetic that decides this list:
--
-- On the `tall` version at 320 px wide the bottom bar fits FIVE cells per row at a full 44 px touch
-- target. Eight entries is already two rows, 112 px of a 412 px panel -- 27% of the screen spent on
-- navigation. Ten would be three rows and 38%, which is not a menu, it is a bar with a view of some
-- content. So `large` and `short` carry every entry flat, and `tall` carries five
-- (COLLECTION, CRATES, STYLE, PROGRESS, SHOP) with everything else living inside one of them:
-- cosmetic crates are a tier filter inside CRATES, kill animations sit inside STYLE.
--
-- Adding a ninth or tenth flat entry is fine for large and short. Adding a SIXTH tall destination
-- costs a whole row of the smallest screen in the game, so do that only with a measurement in hand.
local DESTINATION_LOOK = {
	Brainrots = { glyph = "★", sub = "Your collection" },
	Trade = { glyph = "⇄", sub = "Swap with players" },
	Crates = { glyph = "▣", sub = "Open and buy" },
	-- `Style` had no entry, so the cosmetic-crates tab drew in the rail with an empty icon slot and
	-- no subtitle -- it was added to TABS after DESTINATION_LOOK was written and nobody noticed,
	-- because the rail is the one place the omission shows. One line, and the ninth tab stops
	-- looking like a bug. The #78 revamp replaces this whole list; until then it should be right.
	Style = { glyph = "✦", sub = "Cosmetic crates" },
	Cosmetics = { glyph = "◆", sub = "Skins and auras" },
	Pass = { glyph = "▲", sub = "Brainrot Pass" },
	Rank = { glyph = "★", sub = "Rot Rank" },
	Mastery = { glyph = "◎", sub = "Gun mastery" },
	Index = { glyph = "▦", sub = "Every brainrot" },
	CellShop = { glyph = "✚", sub = "Spend Brain Cells" },
	Quests = { glyph = "✓", sub = "Daily and weekly" },
	Robux = { glyph = "$", sub = "Robux" },
	Settings = { glyph = "⚙", sub = "Keys and audio" },
}

-- Oliver, 2026-09-22 13:59-14:00: no single menu -- separate buttons, each its own page. A button opens
-- its GROUP, and the rail shows only that group's tabs. Quests sit under PROGRESS with the pass.
local TAB_GROUP = {
	Crates = "Shop", Style = "Shop", Cosmetics = "Shop",
	Brainrots = "Brainrots", Trade = "Brainrots",
	Pass = "Progress", Rank = "Progress", Mastery = "Progress", Index = "Progress", CellShop = "Progress", Quests = "Progress",
	Robux = "Robux",
	Settings = "Settings",
}

local function renderTabStrip()
	local destinations = {}
	local group = TAB_GROUP[activeTab]
	for _, tab in ipairs(TABS) do
		if group and TAB_GROUP[tab.key] ~= group then
			continue
		end
		local index = #destinations + 1
		local look = DESTINATION_LOOK[tab.key] or {}
		destinations[index] = { key = tab.key, label = string.upper(tab.label), glyph = look.glyph, sub = look.sub }
	end
	shell:SetDestinations(destinations, activeTab)
end

-- Selecting a destination does exactly what the old tab button's Activated handler did.
shell.onSelect = function(key)
	stopListening()
	settingsNotice = nil
	activeTab = key
	renderTab()
end

renderTab = function()
	if not panel.Visible then
		return
	end

	renderTabStrip()
	clearItems(content)

	for _, tab in ipairs(TABS) do
		if tab.key == activeTab then
			tab.render()
			return
		end
	end
end

--------------------------------------------------------------------------------
-- Crate reveal
--------------------------------------------------------------------------------
-- IN A DO-BLOCK, and it is the whole crate reveal. This file's main chunk reached 200 top-level
-- locals -- Luau's hard limit -- at which point one more anywhere in the file stops it compiling,
-- SILENTLY: no error at build time, and the entire menu simply does not run. Locals declared inside
-- a do-block are released at its end, so the 35 declared below cost the main chunk nothing.
--
-- The reveal was chosen because it is genuinely self-contained: none of its 35 names is referenced
-- anywhere before this block or after it (checked by name across the whole file, both directions),
-- so enclosing it changes no behaviour. It is the same treatment HudClient already gives its drop
-- screen and its inventory, and for the same reason.
--
-- If you add a top-level local to this file, check `verify.py`'s "main-chunk locals" line first.
do

-- Full-screen opening. Everything is built from parts in a ViewportFrame, so there are no image
-- assets. Click to skip to the reveal, click again to close.
--
-- The build-up scales with what's inside: the crate's bands climb the rarity ladder one tier per
-- beat, each beat a notch higher in pitch, and the climb only stops at the prize's tier. A Common
-- pops almost at once; a Secret keeps climbing through every colour while the crate shakes itself
-- apart. Epic and up add light rays behind the prize, Legendary and up a screen shake and confetti,
-- Secret a rainbow finale — and a coin jackpot rains coins on top of whatever came out.

local CLIMB_START = 0.55
local CLIMB_STEP = 0.32
local AUTO_CLOSE_AFTER = 4.5
local MAX_RAYS = 16
local TIER_SHOUT = { Epic = "EPIC!", Legendary = "LEGENDARY!!", Mythic = "MYTHIC!!!", Secret = "S E C R E T" }

local revealOverlay = create("TextButton", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	AutoButtonColor = false,
	Text = "",
	Visible = false,
	ZIndex = 50,
	Parent = screenGui,
})

-- Light rays: bars through the centre of the prize, each fading out towards both ends.
local revealRays = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = revealOverlay,
})

local rayBars = {}
for index = 1, MAX_RAYS / 2 do
	local bar = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(46, 1400),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Visible = false,
		Parent = revealRays,
	}, {
		create("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0.25),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})
	rayBars[index] = bar
end

local revealViewport = create("ViewportFrame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.4),
	Size = UDim2.fromOffset(420, 340),
	BackgroundTransparency = 1,
	Ambient = Color3.fromRGB(150, 150, 162),
	LightColor = Color3.fromRGB(255, 250, 240),
	LightDirection = Vector3.new(-0.3, -1, 0.5),
	Parent = revealOverlay,
})

local revealCamera = Instance.new("Camera")
revealCamera.FieldOfView = 40
revealCamera.CFrame = CFrame.lookAt(Vector3.new(0, 3.2, -13), Vector3.new(0, 1.6, 0))
revealCamera.Parent = revealViewport
revealViewport.CurrentCamera = revealCamera

local revealFlash = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = revealOverlay,
})

-- Confetti and coins live here so closing the reveal can sweep them all at once.
local revealParticles = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = revealOverlay,
})

local function revealText(yOffset, height, font, size, color)
	return create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.4, yOffset),
		Size = UDim2.fromOffset(720, height),
		BackgroundTransparency = 1,
		Font = font,
		Text = "",
		TextColor3 = color,
		TextStrokeTransparency = 0.5,
		TextTransparency = 1,
		TextSize = size,
		Parent = revealOverlay,
	})
end

local revealRarity = revealText(176, 28, Enum.Font.GothamBold, 22, C.Accent)
local revealName = revealText(206, 60, Enum.Font.FredokaOne, 52, C.Text)
local revealValue = revealText(270, 26, Enum.Font.Gotham, 17, C.Muted)
local revealJackpot = revealText(300, 34, Enum.Font.FredokaOne, 30, Color3.fromRGB(255, 214, 64))
local revealHint = revealText(342, 22, Enum.Font.Gotham, 14, C.Muted)

-- The big tier shout above the crate ("LEGENDARY!!"), punched in with a UIScale.
local revealShout = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.13),
	Size = UDim2.fromOffset(900, 90),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = C.Text,
	TextSize = 78,
	TextStrokeTransparency = 0.2,
	TextTransparency = 1,
	Parent = revealOverlay,
})
local revealShoutScale = Instance.new("UIScale")
revealShoutScale.Parent = revealShout

local function revealPart(parent, name, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	part.Name = name
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- The crate is the shared one (CrateModels), which hands back every part that takes the tier
-- colour so the climb can recolour them. The lid's decorations ride on the lid.
local function buildRevealCrate(color, tier)
	local model, lid, lidBand, tinted = CrateModels.Crate(tier, { color = color })
	return model, lid, lidBand, tinted
end

-- A parachute comes out as its real canopy (ParachuteModels, which falls back to the Rot Glider for
-- an unknown id). It's built once at its normal size to measure it, then again at the scale that makes
-- its longest side about as big as the other prizes, so the reveal camera needs no change. Its pivot
-- is moved to its centre, so the rise-and-turn spins it in place rather than swinging it round a corner.
-- An accessory prize is the REAL accessory (claude-df's CosmeticBuild, the same geometry
-- AccessoryService welds to a head), so what the reveal shows can't drift from what the player gets.
-- Built once at scale 1 to measure it, then once more at the scale that makes it sit with the other
-- prizes — not rebuilt per frame, because the z-fight pass can nudge pieces and that would jitter.
-- Anything without buildable geometry still falls back to the coloured orb.
local function buildPrizeAccessory(id, fallbackColor)
	local ACCESSORY_PRIZE_SIZE = 4.5
	local CosmeticBuild = require(Shared:WaitForChild("CosmeticBuild"))
	local item = id and CosmeticData.Get(id)
	if not item or type(item.parts) ~= "table" or #item.parts == 0 then
		return nil
	end
	local ok, measure = pcall(CosmeticBuild.Model, item, CFrame.new(), 1, "PrizeAccessoryMeasure")
	if not ok or not measure then
		return nil
	end
	local _, size = measure:GetBoundingBox()
	measure:Destroy()
	local longest = math.max(size.X, size.Y, size.Z)
	local built, model = pcall(CosmeticBuild.Model, item, CFrame.new(), longest > 0 and ACCESSORY_PRIZE_SIZE / longest or 1,
		"PrizeAccessory")
	if not built or not model then
		return nil
	end
	local body = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if body then
		model.PrimaryPart = body
		local box = model:GetBoundingBox()
		body.PivotOffset = body.CFrame:ToObjectSpace(box)
	end
	return model
end

local function buildPrizeParachute(id)
	local PARACHUTE_PRIZE_SIZE = 5.5
	local measure = ParachuteModels.Build(id, { scale = 1 })
	local _, size = measure:GetBoundingBox()
	measure:Destroy()
	local longest = math.max(size.X, size.Y, size.Z)
	local model = ParachuteModels.Build(id, { scale = longest > 0 and PARACHUTE_PRIZE_SIZE / longest or 1 })
	local body = model.PrimaryPart
	if body then
		-- GetBoundingBox returns the box's CFrame AND its size; only the CFrame may reach ToObjectSpace,
		-- which takes any number of CFrames and errors on the size.
		local box = model:GetBoundingBox()
		body.PivotOffset = body.CFrame:ToObjectSpace(box)
	end
	return model
end

-- Accessories and auras have no creature to show, so they come out as a glowing prize orb.
local function buildPrizeOrb(color)
	local model = Instance.new("Model")
	revealPart(model, "Orb", Vector3.new(2.2, 2.2, 2.2), CFrame.new(), color, Enum.Material.Neon, Enum.PartType.Ball)
	for index = 0, 7 do
		local angle = index / 8 * math.pi * 2
		revealPart(model, "Ring", Vector3.new(0.5, 0.15, 0.2),
			CFrame.Angles(0.4, angle, 0) * CFrame.new(0, 0, 1.8), Color3.fromRGB(255, 220, 110), Enum.Material.Neon)
	end
	return model
end

-- A chunky toy blaster painted in the skin's colour.
local function buildPrizeGun(color)
	local model = Instance.new("Model")
	local dark = Color3.fromRGB(40, 42, 48)
	revealPart(model, "Body", Vector3.new(0.9, 1, 3), CFrame.new(0, 0.2, 0), color, Enum.Material.SmoothPlastic)
	revealPart(model, "Barrel", Vector3.new(2.2, 0.45, 0.45), CFrame.new(0, 0.35, -2.4) * CFrame.Angles(0, math.pi / 2, 0),
		dark, Enum.Material.Metal, Enum.PartType.Cylinder)
	revealPart(model, "Grip", Vector3.new(0.7, 1.4, 0.8), CFrame.new(0, -0.7, 0.8) * CFrame.Angles(-0.3, 0, 0), dark, Enum.Material.SmoothPlastic)
	revealPart(model, "Sight", Vector3.new(0.3, 0.35, 0.6), CFrame.new(0, 0.85, -0.6), color:Lerp(Color3.new(1, 1, 1), 0.4), Enum.Material.Neon)
	revealPart(model, "Mag", Vector3.new(0.5, 1, 0.6), CFrame.new(0, -0.6, -0.6), color:Lerp(Color3.new(0, 0, 0), 0.3), Enum.Material.SmoothPlastic)
	model:PivotTo(CFrame.Angles(0, math.pi / 2, 0))
	return model
end

-- A refund comes out as a little stack of SahurCoins.
local function buildPrizeCoins()
	local model = Instance.new("Model")
	local gold = Color3.fromRGB(255, 200, 60)
	for index = 0, 3 do
		revealPart(model, "Coin", Vector3.new(0.35, 2, 2), CFrame.new(math.sin(index) * 0.15, index * 0.4 - 0.6, 0) * CFrame.Angles(0, 0, math.pi / 2),
			gold, Enum.Material.Foil, Enum.PartType.Cylinder)
	end
	return model
end

local revealToken = 0
local revealConnection = nil
local revealPhase = "closed"
local revealSkip = false

local function clearReveal()
	revealToken += 1
	if revealConnection then
		revealConnection:Disconnect()
		revealConnection = nil
	end
	for _, child in ipairs(revealViewport:GetChildren()) do
		if not child:IsA("Camera") then
			child:Destroy()
		end
	end
	for _, child in ipairs(revealParticles:GetChildren()) do
		child:Destroy()
	end
	for _, bar in ipairs(rayBars) do
		bar.Visible = false
	end
	revealViewport.Position = UDim2.fromScale(0.5, 0.4)
	revealOverlay.Visible = false
	revealPhase = "closed"
end

revealOverlay.Activated:Connect(function()
	if revealPhase == "reveal" then
		clearReveal()
	else
		revealSkip = true
	end
end)

-- Confetti (rarity-coloured squares) or coins (gold circles) bursting up and falling back down.
local function spawnParticles(list, count, colorFor, isCoin)
	for _ = 1, count do
		local size = isCoin and math.random(18, 28) or math.random(8, 14)
		local frame = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.4),
			Size = UDim2.fromOffset(size, isCoin and size or size * 0.6),
			BackgroundColor3 = colorFor(),
			BorderSizePixel = 0,
			Parent = revealParticles,
		}, isCoin and { rounded(size), create("UIStroke", { Color = Color3.fromRGB(180, 120, 20), Thickness = 2 }) } or nil)
		local angle = math.random() * math.pi * 2
		local speed = 0.25 + math.random() * 0.55
		table.insert(list, {
			frame = frame,
			x = 0.5,
			y = 0.4,
			vx = math.cos(angle) * speed * 0.6,
			vy = -math.abs(math.sin(angle)) * speed - 0.25,
			spin = (math.random() - 0.5) * 720,
		})
	end
end

local function stepParticles(list, dt)
	for index = #list, 1, -1 do
		local particle = list[index]
		particle.vy += 1.1 * dt
		particle.vx *= 0.99
		particle.x += particle.vx * dt
		particle.y += particle.vy * dt
		particle.frame.Position = UDim2.fromScale(particle.x, particle.y)
		particle.frame.Rotation += particle.spin * dt
		if particle.y > 1.1 then
			particle.frame:Destroy()
			table.remove(list, index)
		end
	end
end

local CATEGORY_LABEL = { Brainrot = " BRAINROT", Accessory = " ACCESSORY", GunSkin = " GUN SKIN", Aura = " AURA", Parachute = " PARACHUTE", Refund = "" }

crateOpened.OnClientEvent:Connect(function(result)
	clearReveal()
	local token = revealToken
	revealSkip = false
	revealPhase = "crate"

	local tierIndex = Rarity.Index[result.rarity] or 1
	local isSecret = result.rarity == "Secret"
	local popAt = CLIMB_START + tierIndex * CLIMB_STEP
	local crateColor = typeof(result.crateColor) == "Color3" and result.crateColor or Rarity.Color("Common")
	local prizeColor = Rarity.Color(result.rarity)
	local kind = result.kind or "Brainrot"

	local crate, lid, lidBand, tinted = buildRevealCrate(crateColor, result.crateId)
	crate.Parent = revealViewport

	local crateBase = {}
	for _, part in ipairs(crate:GetDescendants()) do
		if part:IsA("BasePart") then
			crateBase[part] = part.CFrame
		end
	end
	-- The lid and everything riding on it (dome, band, padlock) swing together on the lid's hinge.
	-- CrateModels puts that hinge at the middle of the lid's back edge and repeats it as the "Hinge"
	-- attribute for animation by CFrame, which is what this is; PivotOffset is the same value and is
	-- the fallback if a tier is ever built without the attribute.
	local lidStart = lid.CFrame
	-- The swing itself is in Shared/CrateOpen, so the reveal, the world containers and the gallery
	-- that renders it frame by frame all play the same curve. (Required here rather than at the top
	-- of the file: the main chunk is near Luau's limit of 200 locals.)
	local CrateOpen = require(Shared:WaitForChild("CrateOpen"))
	local lidHinge = CrateOpen.Hinge(lid)
	local lidSwing = CrateOpen.Duration(result.crateId)
	local lidParts = { { part = lid, offset = CFrame.identity } }
	for _, part in ipairs(lid:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(lidParts, { part = part, offset = lidStart:ToObjectSpace(part.CFrame) })
		end
	end

	if kind == "Refund" then
		revealRarity.Text = "NOTHING NEW LEFT AT " .. string.upper(result.rarity)
		revealValue.Text = "You own every one of those, so here's a refund instead."
	else
		revealRarity.Text = string.upper(result.rarity) .. (CATEGORY_LABEL[kind] or "")
		if kind == "Brainrot" then
			revealValue.Text = string.format("Worth %s SahurCoins  •  equip it from Brainrots to have it fight for you",
				formatNumber(result.coinValue or 0))
		else
			revealValue.Text = "New! Equip it from the Cosmetics tab."
		end
	end
	revealRarity.TextColor3 = prizeColor
	revealName.Text = result.name or "?"
	revealName.TextColor3 = prizeColor
	revealJackpot.Text = result.jackpot and string.format("+%s SAHURCOIN JACKPOT!", formatNumber(result.jackpot)) or ""
	revealHint.Text = "Click to continue"
	for _, label in ipairs({ revealRarity, revealName, revealValue, revealJackpot, revealHint, revealShout }) do
		label.TextTransparency = 1
		label.TextStrokeTransparency = 1
	end
	revealFlash.BackgroundTransparency = 1

	local rayCount = tierIndex >= 4 and math.min(MAX_RAYS / 2, (tierIndex - 3) * 2) or 0

	revealOverlay.Visible = true
	revealOverlay.BackgroundTransparency = 1
	TweenService:Create(revealOverlay, TweenInfo.new(0.25), { BackgroundTransparency = 0.25 }):Play()

	local start = os.clock()
	local last = start
	local prize = nil
	local climbed = 0
	local shake = 0
	local particles = {}
	local closeAfter = AUTO_CLOSE_AFTER + tierIndex * 0.5

	revealConnection = RunService.RenderStepped:Connect(function()
		if token ~= revealToken then
			return
		end
		local now = os.clock()
		local dt = math.min(now - last, 0.1)
		last = now
		local t = now - start
		if revealSkip and t < popAt then
			start = now - popAt
			t = popAt
			climbed = tierIndex
		end

		stepParticles(particles, dt)

		if not prize then
			-- Drop in with a bounce...
			local drop = math.clamp(t / 0.4, 0, 1)
			local height = (1 - drop) ^ 2 * 8

			-- ...then climb the rarity ladder, one tier per beat, until the prize's tier.
			local step = math.clamp(math.floor((t - CLIMB_START) / CLIMB_STEP) + 1, 0, tierIndex)
			while climbed < step do
				climbed += 1
				local stepColor = Rarity.Color(Rarity.Order[climbed])
				for _, part in ipairs(tinted) do
					part.Color = stepColor
				end
				Sfx.Play("UiClick", nil, 0.8 + climbed * 0.2)
				revealFlash.BackgroundColor3 = stepColor
				revealFlash.BackgroundTransparency = 0.82
				TweenService:Create(revealFlash, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
			end

			-- The rattle grows with every tier climbed.
			local rattle = 0
			if t > CLIMB_START then
				local intensity = math.clamp((t - CLIMB_START) / (popAt - CLIMB_START), 0, 1) * (0.5 + climbed * 0.12)
				rattle = math.sin(t * (30 + intensity * 40)) * intensity * 0.3
			end
			local bump = climbed > 0 and math.max(0, 1 - ((t - CLIMB_START) % CLIMB_STEP) / 0.12) * 0.25 or 0
			local offset = CFrame.new(0, height + bump, 0) * CFrame.Angles(0, 0, rattle)
			for part, base in pairs(crateBase) do
				part.CFrame = offset * base
			end

			if t >= popAt then
				revealPhase = "reveal"
				Sfx.Play("CrateOpen", nil, math.max(0.55, 1 - tierIndex * 0.06))

				revealFlash.BackgroundColor3 = prizeColor:Lerp(Color3.new(1, 1, 1), 0.5)
				revealFlash.BackgroundTransparency = tierIndex >= 5 and 0 or 0.1
				TweenService:Create(revealFlash, TweenInfo.new(0.4 + tierIndex * 0.1), { BackgroundTransparency = 1 }):Play()

				local def = kind == "Brainrot" and BrainrotData.Get(result.name) or nil
				local itemColor = typeof(result.color) == "Color3" and result.color or prizeColor
				if def then
					prize = BrainrotModels.Build(def, { glow = prizeColor })
				elseif kind == "GunSkin" then
					prize = buildPrizeGun(itemColor)
				elseif kind == "Accessory" then
					prize = buildPrizeAccessory(result.id, itemColor) or buildPrizeOrb(itemColor)
				elseif kind == "Parachute" then
					prize = buildPrizeParachute(result.id)
				elseif kind == "Refund" then
					prize = buildPrizeCoins()
				else
					prize = buildPrizeOrb(itemColor)
				end
				prize.Parent = revealViewport

				for index, label in ipairs({ revealRarity, revealName, revealValue, revealJackpot, revealHint }) do
					TweenService:Create(label, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out,
						0, false, 0.15 + index * 0.1), { TextTransparency = 0, TextStrokeTransparency = 0.5 }):Play()
				end

				local shout = TIER_SHOUT[result.rarity]
				if shout and kind ~= "Refund" then
					revealShout.Text = shout
					revealShout.TextColor3 = prizeColor
					revealShout.TextTransparency = 0
					revealShout.TextStrokeTransparency = 0.2
					revealShoutScale.Scale = 2.6
					TweenService:Create(revealShoutScale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
				end

				for index, bar in ipairs(rayBars) do
					bar.Visible = index <= rayCount
					bar.BackgroundColor3 = prizeColor
					bar.BackgroundTransparency = 1
					TweenService:Create(bar, TweenInfo.new(0.5), { BackgroundTransparency = 0.35 }):Play()
				end

				if tierIndex >= 5 then
					shake = Settings.Get("ScreenShake") and 6 + (tierIndex - 5) * 6 or 0
					spawnParticles(particles, (tierIndex - 4) * 30, function()
						return isSecret and Color3.fromHSV(math.random(), 0.7, 1)
							or Rarity.Color(Rarity.Order[math.random(math.max(1, tierIndex - 2), tierIndex)])
					end, false)
				end
				if result.jackpot then
					spawnParticles(particles, 45, function()
						return Color3.fromRGB(255, 206, 64)
					end, true)
				end
			end
			return
		end

		local since = t - popAt

		-- Screen shake that dies away over half a second.
		if shake > 0 then
			shake = math.max(0, shake - dt * 18)
			revealViewport.Position = UDim2.new(0.5, (math.random() - 0.5) * shake * 2, 0.4, (math.random() - 0.5) * shake * 2)
		else
			revealViewport.Position = UDim2.fromScale(0.5, 0.4)
		end

		-- Rays turn slowly; Secret cycles every colour through the rays, name and shout.
		for index = 1, rayCount do
			rayBars[index].Rotation = (index - 1) * (180 / rayCount) + since * (12 + tierIndex * 3)
			if isSecret then
				rayBars[index].BackgroundColor3 = Color3.fromHSV((since * 0.35 + index / rayCount) % 1, 0.55, 1)
			end
		end
		if isSecret then
			local rainbow = Color3.fromHSV((since * 0.5) % 1, 0.6, 1)
			revealName.TextColor3 = rainbow
			revealShout.TextColor3 = rainbow
			revealRarity.TextColor3 = rainbow
		end

		-- The crate OPENS: the lid presses down a moment, gives, and swings up and over on its hinge,
		-- overshooting a little and settling back the way a lid with weight in it does. It used to be
		-- launched into the air on a tumble, which read as the crate coming apart rather than opening
		-- -- and threw away the hinge claude-4a built into every tier's lid.
		local lidNow = CrateOpen.LidCFrame(lidStart, lidHinge, CrateOpen.Angle(since, result.crateId))
		for _, entry in ipairs(lidParts) do
			entry.part.CFrame = lidNow * entry.offset
		end
		-- Then the whole crate, open lid and all, fades away beneath the prize -- starting once this
		-- tier's lid is most of the way up, so a slow Prestige swing isn't fading while it opens.
		local fade = math.clamp((since - lidSwing * 0.75) / 0.5, 0, 1)
		for part in pairs(crateBase) do
			part.Transparency = fade
		end

		-- The prize grows as it rises, then keeps turning. Rarer prizes come out a little bigger.
		local rise = math.clamp(since / 0.55, 0, 1)
		local eased = 1 - (1 - rise) ^ 3
		local finalScale = 1.1 + tierIndex * 0.04
		prize:ScaleTo(math.max(0.05, eased * finalScale))
		local bob = math.sin(since * 2.2) * 0.12 * rise
		prize:PivotTo(CFrame.new(0, 0.8 + eased * 1.2 + bob, 0) * CFrame.Angles(0, since * (1.6 + tierIndex * 0.15), 0))

		if since > closeAfter then
			clearReveal()
		end
	end)
end)
end
-- End of the crate reveal's block; its 35 locals are released here.

--------------------------------------------------------------------------------
-- Trade invite popup
--------------------------------------------------------------------------------

local invitePanel = create("Frame", {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -200),
	Size = UDim2.new(0, 320, 0, 128),
	BackgroundColor3 = C.Background,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}, { rounded(12), padding(14) })

local inviteLabel = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 52),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Text,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextSize = 15,
	Parent = invitePanel,
})

local inviteRow = create("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 1, 0),
	Size = UDim2.new(1, 0, 0, 38),
	BackgroundTransparency = 1,
	Parent = invitePanel,
}, {
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local function respond(accept)
	invitePanel.Visible = false
	local ok, success = pcall(function()
		return respondTrade:InvokeServer(accept)
	end)
	if ok and success and accept then
		activeTab = "Trade"
		if not panel.Visible then
			shell:Open()
		end
		renderTab()
	end
end

create("TextButton", {
	Size = UDim2.fromOffset(140, 38),
	BackgroundColor3 = C.Green,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBold,
	Text = "ACCEPT",
	TextColor3 = Color3.new(0, 0, 0),
	TextSize = 14,
	LayoutOrder = 1,
	Parent = inviteRow,
}, { rounded(8) }).Activated:Connect(function()
	respond(true)
end)

create("TextButton", {
	Size = UDim2.fromOffset(140, 38),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBold,
	Text = "DECLINE",
	TextColor3 = C.Muted,
	TextSize = 14,
	LayoutOrder = 2,
	Parent = inviteRow,
}, { rounded(8) }).Activated:Connect(function()
	respond(false)
end)

local inviteToken = 0

tradeInvite.OnClientEvent:Connect(function(invite)
	inviteToken += 1
	local token = inviteToken

	inviteLabel.Text = invite.fromName .. " wants to trade brainrots with you."
	invitePanel.Visible = true

	task.delay(30, function()
		if token == inviteToken then
			invitePanel.Visible = false
		end
	end)
end)

tradeChanged.OnClientEvent:Connect(function(state)
	trade = state or { active = false }
	if trade.active then
		activeTab = "Trade"
		if not panel.Visible then
			shell:Open()
		end
	end
	renderTab()
end)

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

-- Compact (Oliver 14:01: "small enough to fit on the screen without taking too much space") and
-- stacked top to bottom (14:06): five 100 x 28 buttons, 4 px apart, y 130-286. The bundle nudge and the
-- quest tracker below were moved down by the same 114 px to make room.
local HUD_BUTTON_W = 104
local HUD_BUTTON_H = 26
local HUD_BUTTON_GAP = 3
-- Oliver 14:16/14:21: snug and neat by size and arrangement, same look as the old MENU button.
local function hudButtonLook()
	return { rounded(8) }
end
local menuButton = create("TextButton", {
	Position = UDim2.new(0, 16, 0, 130),
	Size = UDim2.new(0, HUD_BUTTON_W, 0, HUD_BUTTON_H),
	BackgroundColor3 = C.Accent,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBold,
	Text = "SHOP",
	TextColor3 = Color3.new(0, 0, 0),
	TextSize = 13,
	Parent = screenGui,
}, hudButtonLook())

-- CombatClient reads this. While the menu is open mid-match the mouse has to be free — first
-- person otherwise keeps it locked to centre, leaving the panel unclickable — and clicks must
-- not fire the gun. Driven off Visible rather than set in toggleMenu, because the trade
-- invite path opens the panel directly and would otherwise be missed.
panel:GetPropertyChangedSignal("Visible"):Connect(function()
	player:SetAttribute("MenuOpen", panel.Visible)
end)

local function toggleMenu()
	shell:Toggle()
	-- IsOpen, not panel.Visible: closing runs a 0.12 s tween and the layer stays visible until it
	-- finishes, so reading Visible here would re-render the tab on the way out.
	if shell:IsOpen() then
		renderTab()
	else
		stopListening()
		settingsNotice = nil
	end
end

-- Declared here, assigned below once openTab exists.
local hudButtonOpen
menuButton.Activated:Connect(function()
	hudButtonOpen("Crates")
end)
-- The other four buttons ride on the SHOP button as children, so every place that shows, hides or
-- stacks menuButton (phone layout, MenuStackToggle) moves all five together.
for index, spec in ipairs({
	{ "BRAINROTS", "Brainrots" },
	{ "PROGRESS", "Pass" },
	{ "ROBUX", "Robux" },
	{ "SETTINGS", "Settings" },
}) do
	local button = create("TextButton", {
		Position = UDim2.new(0, 0, 0, index * (HUD_BUTTON_H + HUD_BUTTON_GAP)),
		Size = UDim2.new(0, HUD_BUTTON_W, 0, HUD_BUTTON_H),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = spec[1],
		TextColor3 = Color3.new(0, 0, 0),
		TextSize = 13,
		Parent = menuButton,
	}, hudButtonLook())
	button.Activated:Connect(function()
		hudButtonOpen(spec[2])
	end)
end
shell.onBack = toggleMenu
-- Oliver's #66. `onBack` alone was not enough: the scrim and Backspace read that field at click
-- time, but the header's X captured `options.onClose` at CONSTRUCTION -- line 138, before this
-- function exists -- so it was built with no connection at all. The shell reads both at click time
-- now and falls back to closing itself, so this line is belt and braces rather than the only thing
-- holding the X up. It is here so the X does exactly what the scrim, Backspace and the MENU pill
-- do: stop listening, clear the settings notice, close.
shell.onClose = toggleMenu
shell:BindBack("BrrMenuBack")

-- A CONTROLLER COULD NOT OPEN THE MENU AT ALL. This has always been a ContextActionService
-- binding, which takes gamepad KeyCodes perfectly well (Settings.lua:243 forwards `extras` into
-- BindAction); it simply passed none, so the action existed on a keyboard and nowhere else. A whole
-- match with no menu, no settings and no quests, and it is not a crash so nothing reported it.
--
-- ButtonSelect (Back/View), not ButtonStart: Roblox very likely reserves Start for its own console
-- menu the way it reserves Escape on a keyboard, and a binding it swallows would LOOK fixed and do
-- nothing -- the exact failure this fix exists to undo. Somebody with a controller can settle it in
-- one press; until then this takes the button nobody reserves.
--
-- `nil` is the touch argument; extras follow it.
Settings.Bind("BRR_Menu", "Menu", function(_, inputState)
	if inputState == Enum.UserInputState.Begin and not listeningFor and os.clock() - lastKeyCaptureAt > 0.25 then
		toggleMenu()
	end
	return Enum.ContextActionResult.Pass
end, nil, Enum.KeyCode.ButtonSelect)

local function labelMenuButton()
	menuButton.Text = "SHOP"
end
labelMenuButton()
Settings.Changed:Connect(labelMenuButton)

-- Opens the menu straight onto one tab; on that tab already, closes it.
local function openTab(key)
	if panel.Visible and activeTab == key then
		toggleMenu()
		return
	end
	stopListening()
	settingsNotice = nil
	activeTab = key
	shell:Open()
	renderTab()
end

-- A HUD button: open its group, or close it if that group is what is showing.
hudButtonOpen = function(key)
	if panel.Visible and TAB_GROUP[activeTab] == TAB_GROUP[key] then
		toggleMenu()
		return
	end
	openTab(key)
end

--------------------------------------------------------------------------------
-- Quest tracker
--------------------------------------------------------------------------------

-- Today's quests and the weekly count, always on screen (lobby and match), under the menu
-- button. Click it, or press the Quests key, for the full tab with the weeklies and rewards.
local TRACKER_WIDTH = 250

local tracker = create("TextButton", {
	Position = UDim2.new(0, 16, 0, 318),
	Size = UDim2.fromOffset(TRACKER_WIDTH, 40),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Text = "",
	Visible = false,
	Parent = screenGui,
}, {
	rounded(10),
	create("UIStroke", { Color = C.Panel, Thickness = 1.5 }),
	create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
	create("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
	}),
})

local trackerRows = {}

local function renderTracker()
	for _, row in ipairs(trackerRows) do
		row:Destroy()
	end
	trackerRows = {}
	local quests = profile and profile.quests
	if not quests or not quests.list or #quests.list == 0 then
		tracker.Visible = false
		return
	end
	tracker.Visible = true

	local function row(order, height)
		local frame = create("Frame", {
			Size = UDim2.new(1, 0, 0, height),
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Parent = tracker,
		})
		table.insert(trackerRows, frame)
		return frame
	end

	local header = row(0, 18)
	create("TextLabel", {
		Size = UDim2.new(1, -60, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "DAILY QUESTS  [" .. Settings.KeyLabel("Quests") .. "]",
		TextColor3 = C.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 12,
		Parent = header,
	})
	create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(60, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = string.format("%d / %d", quests.doneCount or 0, quests.total or #quests.list),
		TextColor3 = (quests.doneCount or 0) >= (quests.total or #quests.list) and C.Green or C.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 12,
		Parent = header,
	})

	for index, quest in ipairs(quests.list) do
		local color = QUEST_TIER_COLOR[quest.tier] or C.Text
		local line = row(index, 30)
		create("Frame", {
			Position = UDim2.fromOffset(0, 5),
			Size = UDim2.fromOffset(6, 6),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = line,
		}, { rounded(3) })
		create("TextLabel", {
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -70, 0, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = quest.title,
			TextColor3 = quest.done and C.Muted or C.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 12,
			Parent = line,
		})
		create("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.fromOffset(56, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = quest.done and "DONE" or string.format("%s/%s", formatNumber(quest.progress), formatNumber(quest.target)),
			TextColor3 = quest.done and C.Green or C.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 11,
			Parent = line,
		})
		local track = create("Frame", {
			Position = UDim2.fromOffset(12, 20),
			Size = UDim2.new(1, -12, 0, 5),
			BackgroundColor3 = C.PanelAlt,
			BorderSizePixel = 0,
			Parent = line,
		}, { rounded(3) })
		create("Frame", {
			Size = UDim2.fromScale(math.clamp((quest.progress or 0) / math.max(1, quest.target or 1), 0, 1), 1),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = track,
		}, { rounded(3) })
	end

	-- The weeklies in one line: how many are done, and a nudge to open the tab for the rest.
	local weekly = quests.weekly or {}
	if #weekly > 0 then
		local done = 0
		for _, quest in ipairs(weekly) do
			if quest.done then
				done += 1
			end
		end
		local line = row(#quests.list + 1, 16)
		create("TextLabel", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = string.format("WEEKLY CHALLENGES  %d / %d  •  %s left", done, #weekly, QuestData.FormatReset(quests.weekResetIn or 0)),
			TextColor3 = QUEST_TIER_COLOR.weekly,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 11,
			Parent = line,
		})
	end
end

tracker.Activated:Connect(function()
	Sfx.Play("UiClick", 0.08)
	openTab("Quests")
end)

-- DPadLeft, and the walk to it is worth recording. DPadUp is the camera toggle
-- (CombatClient:840), DPadRight is the inventory (HudClient:1659) and DPadDown is the movement item
-- (MovementClient:984) -- so the d-pad is already three-quarters spoken for, and Left is the only
-- face of it free. ButtonL1 looked free and is the vehicle's (VehicleClient:327): a weapon control
-- that also drives is a collision built on purpose.
Settings.Bind("BRR_Quests", "Quests", function(_, inputState)
	if inputState == Enum.UserInputState.Begin and not listeningFor and os.clock() - lastKeyCaptureAt > 0.25 then
		openTab("Quests")
	end
	return Enum.ContextActionResult.Pass
end, nil, Enum.KeyCode.DPadLeft)
Settings.Changed:Connect(renderTracker)

-- The lobby's booths (Trading Hall, Cosmetics, Codex) open straight onto their tab.
Remotes.Event("OpenMenuTab").OnClientEvent:Connect(function(tab)
	if type(tab) == "string" then
		for _, entry in ipairs(TABS) do
			if entry.key == tab then
				if tab == "Brainrots" then
					codexMode = true
				end
				openTab(tab)
				return
			end
		end
	end
end)

-- The tracker is in the way of nothing while the menu is closed, and out of the way while it's open.
panel:GetPropertyChangedSignal("Visible"):Connect(function()
	tracker.Visible = not panel.Visible and profile ~= nil and profile.quests ~= nil and profile.quests.list ~= nil and #profile.quests.list > 0
end)

-- A pulsing shortcut under the menu button to the best deal still open to you: the Starter Bundle
-- until it's been bought, then the Pro Bundle. Only for products whose ID is set (or in Studio).
local bundleNudge = create("TextButton", {
	Position = UDim2.new(0, 16, 0, 278),
	Size = UDim2.new(0, 210, 0, 34),
	BackgroundColor3 = C.Green,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBlack,
	Text = "",
	TextColor3 = Color3.new(0, 0, 0),
	TextSize = 14,
	Visible = false,
	Parent = screenGui,
}, { rounded(10) })

local nudgeStroke = create("UIStroke", {
	Color = Color3.new(1, 1, 1),
	Thickness = 2,
	Transparency = 0.1,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	Parent = bundleNudge,
})
TweenService:Create(nudgeStroke, LOOP_PULSE, { Transparency = 0.9 }):Play()

local function refreshBundleNudge()
	local pick = nil
	for _, key in ipairs({ "StarterBundle", "ProBundle" }) do
		local product = GamepassConfig.Products[key]
		if product and shopVisible(product) and not bundleSoldOut(product) then
			pick = product
			break
		end
	end
	bundleNudge.Visible = pick ~= nil and profile ~= nil
	if pick then
		bundleNudge.Text = string.format("%s  •  %d R$", string.upper(pick.name), pick.suggestedPrice)
		bundleNudge.BackgroundColor3 = pick.color or C.Accent
	end
end

bundleNudge.Activated:Connect(function()
	Sfx.Play("UiClick", 0.08)
	activeTab = "Robux"
	shell:Open()
	renderTab()
end)

-- The left stack (MENU, the bundle nudge, the quest tracker) tucks away behind a tab beside MENU and
-- slides back out (StarterPlayerScripts/MenuStackToggle; saved as the MenuStackCollapsed setting).
-- Tucked away, the tab shows today's quest count and lights up when something new comes in: a quest
-- or weekly challenge done, the daily spin ready, a pass reward to claim, a bundle delivered. M and J
-- work either way. In a do-block: this script's main chunk is close to Luau's 200-local limit.
do
	-- Under pcall: if the module ever fails to load, the stack simply stays as it's built above, rather
	-- than the error stopping the rest of this script (the menu itself, the tracker, trading...).
	local okToggle, stackToggle = pcall(function()
		local MenuStackToggle = require(script.Parent:WaitForChild("MenuStackToggle"))
		return MenuStackToggle.new(screenGui, { items = { menuButton, bundleNudge, tracker }, settings = Settings })
	end)
	if not okToggle then
		warn("[MenuClient] MenuStackToggle didn't load; the menu stack stays as it is: " .. tostring(stackToggle))
		stackToggle = { SetSummary = function() end, Attention = function() end, SetHidden = function() end }
	end

	-- The left stack goes away while the panel is open, and comes back when it closes. Oliver's
	-- screenshot on 2026-09-21 has the stack tab's chevron drawn on top of the first rail tile: the
	-- stack is at a fixed screen position, the panel is centred, and on a window narrower than the
	-- two together they occupy the same pixels. Driven off `panel.Visible` rather than from
	-- toggleMenu, because the trade-invite path and openTab open the panel directly and would
	-- otherwise be missed -- the same reason the MenuOpen attribute is driven off it.
	local function followMenu()
		if stackToggle.SetHidden then
			stackToggle:SetHidden(panel.Visible)
		end
	end
	followMenu()
	panel:GetPropertyChangedSignal("Visible"):Connect(followMenu)

	local seen = nil
	local function watch(state)
		if type(state) ~= "table" then
			return
		end
		local quests = type(state.quests) == "table" and state.quests or {}
		local weekly = 0
		for _, quest in ipairs(quests.weekly or {}) do
			if quest.done then
				weekly += 1
			end
		end
		local rewards = 0
		local pass = state.pass
		if type(pass) == "table" and pass.claimedFree then
			for tier = 1, math.min(pass.tier or 0, BattlePassData.MaxTier) do
				if not pass.claimedFree[tostring(tier)] then
					rewards += 1
				end
				if pass.premium and pass.claimedPremium and not pass.claimedPremium[tostring(tier)] then
					rewards += 1
				end
			end
		end
		local now = {
			done = quests.doneCount or 0,
			weekly = weekly,
			spin = state.daily ~= nil and state.daily.available == true,
			rewards = rewards,
		}
		local total = quests.total or (quests.list and #quests.list) or 0
		stackToggle:SetSummary(total > 0 and string.format("%d/%d", now.done, total) or "")
		if seen and (now.done > seen.done or now.weekly > seen.weekly or (now.spin and not seen.spin) or now.rewards > seen.rewards) then
			stackToggle:Attention()
		end
		seen = now
	end
	profileChanged.OnClientEvent:Connect(watch)
	bundleGranted.OnClientEvent:Connect(function()
		stackToggle:Attention()
	end)
	task.spawn(function()
		local ok, result = pcall(function()
			return requestProfile:InvokeServer()
		end)
		if ok and seen == nil then
			watch(result)
		end
	end)

	-- Phones and small tablets: the wide MENU pill and the coin chip are two of the biggest things on a
	-- 390-tall screen. MENU becomes an icon in the top-right corner (PhoneLayout's slot, beside the
	-- stack tab), the stack itself hangs under that tab, and the coin chip shrinks and steps aside
	-- during a match, where the minimap wants that corner and coins can wait for the lobby.
	local okPhone, phoneErr = pcall(function()
		local PhoneLayout = require(script.Parent:WaitForChild("PhoneLayout"))
		local camera = workspace.CurrentCamera
		local icon = create("TextButton", {
			Name = "PhoneMenu",
			Size = UDim2.fromOffset(44, 44),
			BackgroundColor3 = C.Accent,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Visible = false,
			Parent = screenGui,
		}, { rounded(10) })
		for row = 1, 3 do
			create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0, 8 + row * 7),
				Size = UDim2.fromOffset(20, 3),
				BackgroundColor3 = Color3.fromRGB(20, 16, 6),
				BorderSizePixel = 0,
				Parent = icon,
			}, { rounded(2) })
		end
		icon.Activated:Connect(toggleMenu)

		local coinScale = create("UIScale", { Parent = coinChip })
		local coinHome = coinChip.Position
		local function apply()
			local viewport = camera.ViewportSize
			local spots = PhoneLayout.Active(viewport) and PhoneLayout.Rects(viewport) or nil
			icon.Visible = spots ~= nil
			menuButton.Visible = spots == nil
			if spots then
				local inset = spots.inset or 0
				icon.Position = UDim2.fromOffset(spots.menu.x, spots.menu.y - inset)
				icon.Size = UDim2.fromOffset(spots.menu.w, spots.menu.h)
				-- The coin chip stays on a phone, in a match as well as in the lobby: the owner asked for
				-- it kept and shrunk, not hidden. 210 wide down to the slot's 120 is about 0.57, which
				-- leaves its number at 12 or 13 pixels -- small, still readable.
				coinScale.Scale = spots.coins.w / 210
				coinChip.Position = UDim2.fromOffset(spots.coins.x, spots.coins.y - inset)
				coinChip.Visible = true
			else
				coinScale.Scale = 1
				coinChip.Position = coinHome
				coinChip.Visible = true
			end
			if stackToggle.SetPhone then
				stackToggle:SetPhone(spots, spots and spots.inset or 0)
			end
		end
		apply()
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
		UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(apply)
		PhoneLayout.ReapplyMenu = apply
	end)
	if not okPhone then
		warn("[MenuClient] the phone layout didn't load; the menu stack keeps its desktop sizes: " .. tostring(phoneErr))
	end
end

--------------------------------------------------------------------------------
-- Bundle unlocked
--------------------------------------------------------------------------------

-- A card that pops in and deals out everything a bundle just gave you, one line at a time.
local bundleOverlay = create("TextButton", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.35,
	AutoButtonColor = false,
	Text = "",
	Visible = false,
	ZIndex = 60,
	Parent = screenGui,
})

local bundleCard = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(460, 430),
	BackgroundColor3 = C.Background,
	BorderSizePixel = 0,
	ZIndex = 61,
	Parent = bundleOverlay,
}, { rounded(16) })
local bundleStroke = create("UIStroke", { Thickness = 3, Parent = bundleCard })
local bundleScale = create("UIScale", { Scale = 1, Parent = bundleCard })

local bundleTitle = create("TextLabel", {
	Position = UDim2.fromOffset(20, 18),
	Size = UDim2.new(1, -40, 0, 40),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = C.Text,
	TextSize = 32,
	ZIndex = 62,
	Parent = bundleCard,
})

create("TextLabel", {
	Position = UDim2.fromOffset(20, 58),
	Size = UDim2.new(1, -40, 0, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "UNLOCKED! Everything is already in your inventory.",
	TextColor3 = C.Muted,
	TextSize = 14,
	ZIndex = 62,
	Parent = bundleCard,
})

local bundleList = create("Frame", {
	Position = UDim2.fromOffset(20, 92),
	Size = UDim2.new(1, -40, 1, -136),
	BackgroundTransparency = 1,
	ZIndex = 62,
	Parent = bundleCard,
}, {
	create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
})

create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -12),
	Size = UDim2.new(1, -40, 0, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	Text = "Click anywhere to close",
	TextColor3 = C.Muted,
	TextSize = 13,
	ZIndex = 62,
	Parent = bundleCard,
})

local bundleToken = 0

local function closeBundle()
	bundleToken += 1
	bundleOverlay.Visible = false
end
bundleOverlay.Activated:Connect(closeBundle)

bundleGranted.OnClientEvent:Connect(function(productKey, refunded)
	local product = GamepassConfig.Products[productKey]
	if not product then
		return
	end
	bundleToken += 1
	local token = bundleToken
	local color = product.color or C.Accent

	bundleTitle.Text = string.upper(product.name)
	bundleTitle.TextColor3 = color
	bundleStroke.Color = color
	clearItems(bundleList)

	local lines = GamepassConfig.DescribeContents(product.grant, cosmeticLabel)
	if refunded and refunded > 0 then
		table.insert(lines, formatNumber(refunded) .. " SahurCoins for exclusives you already had")
	end

	bundleOverlay.Visible = true
	bundleScale.Scale = 0.6
	TweenService:Create(bundleScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	Sfx.Play("CrateOpen")

	for index, text in ipairs(lines) do
		task.delay(0.3 + index * 0.18, function()
			if token ~= bundleToken then
				return
			end
			local row = create("TextLabel", {
				Size = UDim2.new(1, 0, 0, 28),
				BackgroundColor3 = C.Panel,
				BorderSizePixel = 0,
				Font = Enum.Font.GothamBold,
				Text = "   +  " .. text,
				TextColor3 = index == #lines and refunded and refunded > 0 and C.Accent or C.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTransparency = 1,
				TextSize = 15,
				LayoutOrder = index,
				ZIndex = 63,
				Parent = bundleList,
			}, { rounded(6) })
			TweenService:Create(row, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
			Sfx.Play("UiClick", nil, 0.9 + index * 0.08)
		end)
	end

	task.delay(12, function()
		if token == bundleToken then
			closeBundle()
		end
	end)
end)

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function applyProfile(newProfile)
	profile = newProfile
	if not profile then
		return
	end
	coinLabel.Text = formatNumber(profile.coins)
	questResetAt = os.clock() + (profile.quests and profile.quests.resetIn or 0)
	refreshBundleNudge()
	renderTracker()
	renderTab()
end

profileChanged.OnClientEvent:Connect(applyProfile)

task.spawn(function()
	local ok, result = pcall(function()
		return requestProfile:InvokeServer()
	end)
	if ok and result then
		applyProfile(result)
	end
end)

-- Keep the restock countdown ticking, and redraw the shop tabs the moment the stock changes.
task.spawn(function()
	local lastWindow = ShopRotation.Window()
	while true do
		task.wait(0.5)
		if stockTimerLabel and stockTimerLabel.Parent then
			stockTimerLabel.Text = (stockTimerLabel:GetAttribute("Prefix") or "") .. "  •  new stock in " .. ShopRotation.FormatTimeLeft()
		end
		if questTimerLabel and questTimerLabel.Parent then
			questTimerLabel.Text = "DAILY QUESTS  •  new quests in " .. QuestData.FormatReset(questResetAt - os.clock())
		end
		-- Once the day rolls over the server has a fresh set; fetch it rather than showing 0:00.
		if questResetAt > 0 and os.clock() > questResetAt + 2 then
			questResetAt = 0
			task.spawn(function()
				local ok, result = pcall(function()
					return requestProfile:InvokeServer()
				end)
				if ok and result then
					applyProfile(result)
				end
			end)
		end
		local window = ShopRotation.Window()
		if window ~= lastWindow then
			lastWindow = window
			if panel.Visible and (activeTab == "Crates" or activeTab == "Cosmetics") then
				renderTab()
			end
		end
	end
end)
