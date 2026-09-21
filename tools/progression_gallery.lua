-- Progression gallery: the real Pass-tab progression pages (StarterPlayerScripts/ProgressionPanel)
-- drawn into a copy of the menu's panel frame, from made-up profiles, captured from Studio's edit
-- viewport.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/progression_gallery.lua -OutDir <folder>
--
-- The frame copies MenuClient's panel (760 wide, a 728-wide scrolling list at y 98) so wrapping and
-- truncation look as they will in game. Views ending in "_tall" stretch it to show a whole page.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(scripts:WaitForChild("UiKit"))
local ProgressionPanel = require(scripts:WaitForChild("ProgressionPanel"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors
local GUI_NAME = "BRR_ProgressionGallery"

local function aimAtSky(camera)
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(10), 0, 0)
end

-- A stand-in for the menu: title, a dummy tab strip with Pass selected, and the scrolling list.
-- `width` is the whole panel; the list inside it is 32 px narrower, which is what the pages measure.
-- 760 is the desktop menu; 328 is a 320-wide phone in portrait once the shell's padding is taken off.
local function menuFrame(height, width)
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = create("ScreenGui", { Name = GUI_NAME, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = StarterGui })
	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width or 760, height),
		BackgroundColor3 = C.Background,
		BorderSizePixel = 0,
		Parent = gui,
	}, { rounded(14) })
	create("TextLabel", {
		Position = UDim2.fromOffset(20, 14),
		Size = UDim2.fromOffset(300, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "BRAIN ROT ROYALE",
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 22,
		Parent = panel,
	})
	local strip = create("Frame", {
		Position = UDim2.fromOffset(16, 52),
		Size = UDim2.new(1, -32, 0, 38),
		BackgroundTransparency = 1,
		Parent = panel,
	}, { create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	for index, name in ipairs({ "Brainrots", "Trade", "Crates", "Cosmetics", "Pass", "Quests", "Robux Shop", "Settings" }) do
		create("TextLabel", {
			Size = UDim2.fromOffset(85, 34),
			BackgroundColor3 = name == "Pass" and C.Accent or C.Panel,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			Text = name,
			TextColor3 = name == "Pass" and Color3.new(0, 0, 0) or C.Muted,
			TextSize = 14,
			LayoutOrder = index,
			Parent = strip,
		}, { rounded(8) })
	end
	local content = create("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 98),
		Size = UDim2.new(1, -32, 1, -114),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = panel,
	}, { create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
	return content
end

-- A made-up profile around a progression table.
local function profileWith(progression, extra)
	local data = {
		Brainrots = extra and extra.brainrots or {},
		Companion = extra and extra.companion or nil,
		CompanionXp = extra and extra.companionXp or {},
		Progression = progression,
	}
	local grouped, byName = {}, {}
	for _, name in ipairs(data.Brainrots) do
		local def = BrainrotData.Get(name)
		if def and not byName[name] then
			byName[name] = { name = name, rarity = def.rarity, count = 0 }
			table.insert(grouped, byName[name])
		end
		if byName[name] then
			byName[name].count += 1
		end
	end
	return {
		brainrots = grouped,
		companion = data.Companion,
		cosmetics = { owned = extra and extra.owned or {} },
		progression = ProgressionData.Snapshot(data, os.time()),
	}
end

local function baseProgression()
	local progression = ProgressionData.Default()
	progression.v = 1
	return progression
end

local function midClimb()
	local p = baseProgression()
	p.prestige = 2
	-- Three fifths of the way into rank 47, whatever the curve costs: a fixed number of XP here stopped
	-- being mid-rank the moment the curve was re-tuned, which is how this scenario quietly stopped
	-- showing what it was for.
	p.xp = ProgressionData.RankStart(47) + math.floor(ProgressionData.XpToNext(47) * 0.6)
	p.total = ProgressionData.PrestigeXp * 2 + p.xp
	p.cells = 4280
	p.cellsEarned = 19650
	return p
end

local function readyToPrestige()
	local p = baseProgression()
	p.prestige = 4
	p.xp = ProgressionData.PrestigeXp
	p.over = 16400
	p.total = ProgressionData.PrestigeXp * 5 + 16400
	p.cells = 12040
	p.cellsEarned = 51000
	return p
end

local function masteryProgression()
	local p = midClimb()
	local points = { 612, 340, 180, 96, 75, 52, 31, 22, 14, 10, 6, 3, 1 }
	for index, id in ipairs(ProgressionData.MasteryWeapons()) do
		if points[index] then
			p.mastery[ProgressionData.MasteryWeapons()[(index * 7) % #ProgressionData.MasteryWeapons() + 1]] = points[index]
		end
	end
	return p
end

local function indexProgression()
	local p = midClimb()
	for order, def in ipairs(BrainrotData.Types) do
		if def.rarity == "Common" or (def.rarity == "Uncommon" and order % 3 ~= 0) then
			p.index[def.name] = ProgressionData.Claimed
		elseif def.rarity == "Rare" and order % 2 == 0 then
			p.index[def.name] = order % 4 == 0 and ProgressionData.Recorded or order % 6 == 0 and ProgressionData.Purchased or ProgressionData.Claimed
		elseif def.rarity == "Epic" and order % 5 == 0 then
			p.index[def.name] = ProgressionData.Recorded
		end
	end
	p.pages.Common = true
	return p
end

local function pageView(name, view, height, build, setup, width)
	return {
		name = name,
		settle = 2,
		setup = function(_folder, camera)
			aimAtSky(camera)
			-- Cleared for every view: a leftover override from the view before would silently render the
			-- wrong version, and a gallery that lies is worse than no gallery.
			ProgressionPanel.ViewportForTest = nil
			ProgressionPanel.SetView(view)
			if setup then
				setup()
			end
			local content = menuFrame(height, width)
			local progression, extra = build()
			local profile = profileWith(progression, extra)
			-- The pages size themselves from the list's AbsoluteSize, which is 0 until layout has run.
			-- Rendering before that draws the desktop layout at any width.
			game:GetService("RunService").Heartbeat:Wait()
			game:GetService("RunService").Heartbeat:Wait()
			ProgressionPanel.Render(content, profile, { rerender = function() end })
			print(string.format("[BRR_Gallery] note %s: %d items, canvas %s", name, #content:GetChildren(), tostring(content.AbsoluteCanvasSize)))
		end,
	}
end

local rareOffer = ProgressionData.ShopOffers(ProgressionData.Day(os.time()))[3].brainrot

local views = {
	pageView("toggle_on_pass", "Pass", 480, midClimb),
	pageView("rank_mid_climb", "Rank", 480, midClimb),
	pageView("rank_mid_climb_tall", "Rank", 820, midClimb),
	pageView("rank_ready_to_prestige_tall", "Rank", 820, function()
		return readyToPrestige(), { owned = { PrestigeBronzeSkin = true, PrestigeSilverAura = true, PrestigeGoldenSkin = true, PrestigeJadeAura = true } }
	end),
	pageView("rank_fresh_tall", "Rank", 820, function()
		return baseProgression()
	end),
	pageView("mastery", "Mastery", 480, masteryProgression, function()
		ProgressionPanel.MasteryFilter = "All"
	end),
	pageView("mastery_tall", "Mastery", 900, function()
		return masteryProgression(), { owned = { MasteryDiamondCutSkin = true, MasteryRotmasterSkin = true } }
	end),
	pageView("index_rare_tall", "Index", 900, indexProgression, function()
		ProgressionPanel.IndexRarity = "Rare"
	end),
	pageView("index_common_complete", "Index", 480, indexProgression, function()
		ProgressionPanel.IndexRarity = "Common"
	end),
	pageView("shop_tall", "Shop", 820, function()
		local p = midClimb()
		p.shop.day = ProgressionData.Day(os.time())
		p.shop.bought = { rare = 1, snack = 1 }
		return p, { brainrots = { "Trippi Troppi", "Trippi Troppi", rareOffer }, companion = "Trippi Troppi", companionXp = { ["Trippi Troppi"] = 1350 }, owned = { CellBrainAura = true } }
	end),
	pageView("shop_broke_no_companion", "Shop", 820, function()
		local p = baseProgression()
		p.cells = 90
		return p
	end),

	-- Portrait: a 320-wide phone, which is the narrowest the shell reports (296 px of content). These
	-- are the shapes the pages change into rather than shrinking, so they're worth looking at.
	pageView("portrait_rank", "Rank", 700, midClimb, nil, 328),
	pageView("portrait_rank_ready_to_prestige", "Rank", 700, readyToPrestige, nil, 328),
	pageView("portrait_mastery", "Mastery", 700, masteryProgression, function()
		ProgressionPanel.MasteryFilter = "All"
	end, 328),
	pageView("portrait_index", "Index", 700, indexProgression, function()
		ProgressionPanel.IndexRarity = "Rare"
	end, 328),
	pageView("portrait_shop", "Shop", 700, function()
		local p = midClimb()
		p.shop.day = ProgressionData.Day(os.time())
		return p, { brainrots = { "Trippi Troppi" }, companion = "Trippi Troppi", companionXp = { ["Trippi Troppi"] = 1350 } }
	end, nil, 328),
	pageView("portrait_tablet_rank", "Rank", 700, midClimb, nil, 414),

	-- The short version: an 844x390 phone in landscape. Desktop-wide and almost no height, so the
	-- pages drop what is reference and keep what is a goal. The frame is the height such a screen
	-- really gives the list, so what you see here is what fits without scrolling.
	pageView("short_rank", "Rank", 262, midClimb, function()
		ProgressionPanel.ViewportForTest = Vector2.new(844, 390)
	end, 812),
	pageView("short_rank_tall_capture", "Rank", 700, midClimb, function()
		ProgressionPanel.ViewportForTest = Vector2.new(844, 390)
	end, 812),
	pageView("short_mastery", "Mastery", 262, masteryProgression, function()
		ProgressionPanel.MasteryFilter = "All"
		ProgressionPanel.ViewportForTest = Vector2.new(844, 390)
	end, 812),
	pageView("short_shop", "Shop", 262, function()
		local p = midClimb()
		p.shop.day = ProgressionData.Day(os.time())
		return p, { brainrots = { "Trippi Troppi" }, companion = "Trippi Troppi", companionXp = { ["Trippi Troppi"] = 1350 } }
	end, function()
		ProgressionPanel.ViewportForTest = Vector2.new(844, 390)
	end, 812),
	pageView("short_index", "Index", 262, indexProgression, function()
		ProgressionPanel.IndexRarity = "Rare"
		ProgressionPanel.ViewportForTest = Vector2.new(844, 390)
	end, 812),
}

return views
