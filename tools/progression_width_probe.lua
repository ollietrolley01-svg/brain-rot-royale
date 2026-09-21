-- Probe for tools/runtest.ps1 -Probe: measures the Pass-tab progression pages at narrow widths.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/progression_width_probe.lua
--
-- Rows on these pages put a portrait or an icon at a fixed x and size the text beside it as
-- `UDim2.new(1, -N, ...)`. That is fine at the 728 px of content a desktop menu gives, and silently
-- fatal when the content area is 296: the width goes NEGATIVE and Roblox draws nothing at all, so the
-- row is blank rather than visibly squeezed. Nothing in the game sets ScreenOrientation, so a player
-- can rotate a phone into portrait today (claude-ee measured the shell: 296-350 px of content there,
-- against 603+ in landscape, which is why testing "on a phone" in landscape passes).
--
-- This renders every view at each width and reports anything that came out too narrow to read. It is a
-- measurement, not a screenshot: the numbers say which rows fail and by how much.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(scripts:WaitForChild("UiKit"))
local ProgressionPanel = require(scripts:WaitForChild("ProgressionPanel"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors
local GUI_NAME = "BRR_ProgressionWidthProbe"

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[PROBE] %s %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

-- Content widths to test: the desktop menu, then the five phone sizes claude-ee measured from the new
-- shell (two landscape, three portrait).
local WIDTHS = { 728, 780, 603, 350, 311, 296 }
-- Under this, a label holding real text is unreadable even when its width is positive.
local TOO_NARROW = 60

local function contentFrame(width, height)
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = create("ScreenGui", { Name = GUI_NAME, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = StarterGui })
	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width + 32, height),
		BackgroundColor3 = C.Background,
		BorderSizePixel = 0,
		Parent = gui,
	}, { rounded(14) })
	return create("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -32, 1, -16),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = panel,
	}, { create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) }), gui
end

-- A profile rich enough that every page has rows to draw: mid-climb rank, mastery on several guns,
-- a part-claimed Index and a companion for the snack row.
local function profile()
	local p = ProgressionData.Default()
	p.v, p.prestige = 1, 2
	p.xp = ProgressionData.RankStart(47) + math.floor(ProgressionData.XpToNext(47) * 0.6)
	p.total, p.cells, p.cellsEarned = ProgressionData.PrestigeXp * 2 + p.xp, 4280, 19650
	local guns = ProgressionData.MasteryWeapons()
	for index = 1, math.min(8, #guns) do
		p.mastery[guns[index]] = index * 37
	end
	local brainrots, first = {}, nil
	for index, def in ipairs(BrainrotData.Types) do
		if index <= 14 then
			p.index[def.name] = index % 3 == 0 and ProgressionData.Claimed or ProgressionData.Recorded
			table.insert(brainrots, def.name)
			first = first or def.name
		end
	end
	local data = { Brainrots = brainrots, Companion = first, CompanionXp = { [first] = 900 }, Progression = p }
	local grouped = {}
	for _, name in ipairs(brainrots) do
		local def = BrainrotData.Get(name)
		table.insert(grouped, { name = name, rarity = def.rarity, count = 1 })
	end
	return {
		brainrots = grouped,
		companion = first,
		cosmetics = { owned = {} },
		progression = ProgressionData.Snapshot(data, os.time()),
	}
end

-- Everything drawn, with the path that leads to it, so a report names the row rather than "a label".
local function pathOf(object, root)
	local parts = {}
	local node = object
	while node and node ~= root do
		table.insert(parts, 1, node.Name ~= "" and node.Name or node.ClassName)
		node = node.Parent
	end
	return table.concat(parts, "/")
end

-- SetView returns false for a name it doesn't know, which would otherwise leave every pass measuring
-- the same page and reporting it as five clean views.
local views = { "Pass", "Rank", "Mastery", "Index", "Shop" }
for _, view in ipairs(views) do
	expect("the panel knows the " .. view .. " view", ProgressionPanel.SetView(view))
end

-- CONTROL: a detector that never fires is worth nothing, so the probe breaks a row on purpose and
-- checks it names it. `1, -900` in a 296 px parent is the exact shape this probe exists to catch.
do
	local content, gui = contentFrame(296, 300)
	local planted = create("TextLabel", {
		Name = "PlantedTooNarrow",
		Position = UDim2.fromOffset(330, 0),
		Size = UDim2.new(1, -900, 0, 20),
		BackgroundTransparency = 1,
		Text = "this row must be reported",
		TextColor3 = C.Text,
		Parent = content,
	})
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	local caught = planted.AbsoluteSize.X <= 0
	expect("CONTROL: a row sized 1,-900 at 296 px really does come out at zero or less, and is caught",
		caught, string.format("%.0f px wide", planted.AbsoluteSize.X))
	gui:Destroy()
end
local worst = {}
for _, width in ipairs(WIDTHS) do
	for _, view in ipairs(views) do
		local content, gui = contentFrame(width, 900)
		-- A frame that has just been made has an AbsoluteSize of 0 until layout runs, and the panel falls
		-- back to the desktop width when it measures 0. Rendering immediately would draw the WIDE page
		-- inside a narrow frame and pass it -- the probe would be testing itself, not the panel.
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		local okRender, err = pcall(function()
			assert(ProgressionPanel.SetView(view), "no such view: " .. view)
			ProgressionPanel.Render(content, profile(), { rerender = function() end })
		end)
		expect(string.format("%s renders at %d px", view, width), okRender, err)
		expect(string.format("%s measured %d px rather than falling back", view, width),
			ProgressionPanel.LastWidth == width, ProgressionPanel.LastWidth)
		-- Which version it drew, not just how wide it was: a page that measured 296 and still drew the
		-- desktop version would pass every width check and be wrong on every phone.
		-- 600 is UiKit.form's boundary (claude-ee owns it). This isn't circular: the panel calls that
		-- function too, so what's being checked is that it hands it the width of the LIST it is drawing
		-- into rather than the viewport -- get that wrong and every page is "large" on a phone.
		local wantMode = width < 600 and "tall" or "large"
		expect(string.format("%s at %d px drew the %s version", view, width, wantMode),
			ProgressionPanel.LastMode == wantMode, ProgressionPanel.LastMode)
		if okRender then
			-- Layout is computed on the next frame, and AutomaticCanvasSize needs one more.
			RunService.Heartbeat:Wait()
			RunService.Heartbeat:Wait()
			local blank, narrow = {}, {}
			for _, object in ipairs(content:GetDescendants()) do
				-- A progress bar's fill at 0% is legitimately zero pixels wide. It is told apart from a
				-- vanished row by its SIZE rather than its name, so the rule holds for any bar in the
				-- project, mine or UiParts': a fill is `fromScale(fraction, 1)`, so at 0% it has no scale
				-- and no offset, while a row that disappeared is `UDim2.new(1, -340, ...)` -- full scale
				-- with an offset big enough to swallow it.
				local sizeX = object:IsA("GuiObject") and object.Size.X or nil
				local zeroByDesign = sizeX ~= nil and sizeX.Scale == 0 and sizeX.Offset == 0
				if object:IsA("GuiObject") and object.Visible and not zeroByDesign then
					local size = object.AbsoluteSize
					local text = object:IsA("TextLabel") or object:IsA("TextButton")
					-- Only sentences count as "too narrow": an icon glyph or a two-digit number in a small
					-- box is meant to be small, and reporting those buries the rows that matter.
					local hasText = text and object.Text ~= nil and #object.Text > 4
					if size.X <= 0 or size.Y <= 0 then
						table.insert(blank, string.format("%s (%.0fx%.0f)", pathOf(object, content), size.X, size.Y))
					elseif hasText and size.X < TOO_NARROW then
						table.insert(narrow, string.format("%s %.0fpx %q", pathOf(object, content), size.X, string.sub(object.Text, 1, 24)))
					end
				end
			end
			if #blank > 0 or #narrow > 0 then
				table.insert(worst, string.format("%s at %d: %d drawn at zero or less, %d under %dpx", view, width, #blank, #narrow, TOO_NARROW))
				for index = 1, math.min(4, #blank) do
					print("[PROBE]   blank: " .. blank[index])
				end
				for index = 1, math.min(3, #narrow) do
					print("[PROBE]   narrow: " .. narrow[index])
				end
			end
			expect(string.format("%s at %d px draws nothing at zero width", view, width), #blank == 0, #blank > 0 and (#blank .. " rows") or nil)
		end
		gui:Destroy()
	end
end

-- The SHORT version: a screen with desktop width and no height (an 844x390 phone in landscape).
-- Width alone can't produce it, so the viewport is overridden for these renders. What's checked is
-- that the pages actually change -- a version that renders identically to `large` is not a version --
-- and that the primary action moves UP the page rather than just being redrawn.
do
	local shortViewport = Vector2.new(844, 390)
	-- Render's job is to draw into a list the menu has already cleared, so two renders into one frame
	-- would stack two pages and make the second look taller, not shorter. Each gets its own frame.
	local function canvasFor(view, viewport)
		local content, gui = contentFrame(780, 900)
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		ProgressionPanel.ViewportForTest = viewport
		ProgressionPanel.SetView(view)
		ProgressionPanel.Render(content, profile(), { rerender = function() end })
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		-- The LIST's content size, not AbsoluteCanvasSize: a scrolling frame's canvas never reports
		-- smaller than the frame itself, so both versions came back as exactly 884 px -- the frame --
		-- and the comparison said nothing. The layout knows what it actually laid out.
		local layout = content:FindFirstChildOfClass("UIListLayout")
		return layout and layout.AbsoluteContentSize.Y or content.AbsoluteCanvasSize.Y, content, gui
	end
	for _, view in ipairs(views) do
		-- PASS draws only the tab strip (the pass itself belongs to MenuClient), so there is no page to
		-- shorten and no claim to make about it.
		if view ~= "Pass" then
		local largeHeight, _, largeGui = canvasFor(view, nil)
		largeGui:Destroy()
		local shortHeight, content, gui = canvasFor(view, shortViewport)
		expect(string.format("%s in an 844x390 viewport draws the short version", view),
			ProgressionPanel.LastMode == "short", ProgressionPanel.LastMode)
		expect(string.format("the short %s page is shorter than the large one", view),
			shortHeight < largeHeight, string.format("%d vs %d px", shortHeight, largeHeight))
		print(string.format("[PROBE] MEASURED: %s page canvas is %d px large, %d px short (%d%% of it)",
			view, largeHeight, shortHeight, math.floor(100 * shortHeight / math.max(largeHeight, 1) + 0.5)))
		local blank = 0
		for _, object in ipairs(content:GetDescendants()) do
			local sizeX = object:IsA("GuiObject") and object.Size.X or nil
			if object:IsA("GuiObject") and object.Visible and not (sizeX.Scale == 0 and sizeX.Offset == 0)
				and (object.AbsoluteSize.X <= 0 or object.AbsoluteSize.Y <= 0) then
				blank += 1
			end
		end
		expect(string.format("the short %s page draws nothing at zero width", view), blank == 0, blank)
		ProgressionPanel.ViewportForTest = nil
		gui:Destroy()
		end
	end
end

-- How tall the LARGE layout has to be before the primary action on each page is reachable without
-- scrolling. claude-43 asked for this number to settle where `short` begins: claude-ee has the
-- threshold at a 500 px viewport and I argued 600, and the way to settle it is to measure rather than
-- to assert. This is content height only -- the shell's header and nav bar sit outside it, so whoever
-- writes the threshold adds their own chrome to these numbers.
do
	local primary = {
		Rank = "PRESTIGE",   -- the button that spends a full rank ladder
		Index = "CLAIM ALL", -- the button that pays out every discovery
		Shop = "RESTOCKS",   -- the clock that says whether it is worth looking
		Mastery = "GUNS USED",
	}
	local function reachAt(view, needle, viewport)
		local content, gui = contentFrame(728, 1400)
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		ProgressionPanel.ViewportForTest = viewport
		ProgressionPanel.SetView(view)
		ProgressionPanel.Render(content, profile(), { rerender = function() end })
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		local bottom, found = 0, false
		for _, object in ipairs(content:GetDescendants()) do
			if (object:IsA("TextLabel") or object:IsA("TextButton")) and string.find(object.Text, needle, 1, true) then
				local edge = object.AbsolutePosition.Y + object.AbsoluteSize.Y - content.AbsolutePosition.Y
				bottom = math.max(bottom, edge)
				found = true
			end
		end
		ProgressionPanel.ViewportForTest = nil
		gui:Destroy()
		return found and math.ceil(bottom) or nil
	end

	for view, needle in pairs(primary) do
		local large = reachAt(view, needle, nil)
		local short = reachAt(view, needle, Vector2.new(844, 390))
		expect(string.format("%s has a primary action to measure (%s)", view, needle), large ~= nil and short ~= nil)
		if large and short then
			print(string.format("[PROBE] MEASURED: %s needs %d px of content height before %q is reachable; the short version needs %d",
				view, large, needle, short))
			expect(string.format("the short %s page puts %s higher up than the large one does", view, needle),
				short <= large, string.format("%d vs %d", short, large))
		end
	end
end

if #worst > 0 then
	print("[PROBE] width summary:")
	for _, line in ipairs(worst) do
		print("[PROBE]   " .. line)
	end
	print("[PROBE] NOTE: failures at 296-350 px are the FINDING this probe was written for, not a")
	print("[PROBE] regression in this run -- the portrait rework onto UiParts.splitRow is what clears them.")
	print("[PROBE] Once that has landed, any failure here IS a regression: read the widths above.")
end
local old = StarterGui:FindFirstChild(GUI_NAME)
if old then
	old:Destroy()
end
print(string.format("[PROBE] progression widths: %d passed, %d failed", passes, failures))
