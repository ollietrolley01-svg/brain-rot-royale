-- Probe for tools/runtest.ps1 -Probe: Oliver's #65 (tabs not fitting) and #66 (the X button).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe <abs path> -PlaceFile <abs rbxlx>
--
-- WHAT THIS CAN AND CANNOT MEASURE, said up front because the first version of this probe claimed
-- more than the harness allows. Studio's plugin sandbox REFUSES synthetic input --
-- `VirtualInputManager:SendMouseButtonEvent` throws "lacking capability RobloxScript" -- so no probe
-- in this harness can click a button. A real click on the real X is therefore Oliver's playtest, and
-- nothing below pretends otherwise.
--
-- What IS measured, and it is the thing that actually broke: `UiParts.button` connects Activated if
-- and only if the `onClick` it is handed is non-nil, so the VALUE IN THAT SLOT IS THE WIRING. The
-- shipped shell put `options.onClose` there and MenuClient passed no `onClose`, so the slot held nil
-- and the button was built with no connection. This probe reads the slot the shell actually filled,
-- under every combination of options a host might pass, and calls what it finds to check it closes.
--
-- Each section carries a PERMANENT planted fault that rebuilds the bug exactly as it shipped and
-- must be reported, and each runs inside its own pcall, so one section failing can never take the
-- others down with it -- which is precisely what happened on the first run and cost a Studio slot.
-- Geometry runs FIRST for the same reason.

local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(scripts:WaitForChild("UiKit"))
local UiParts = require(scripts:WaitForChild("UiParts"))
local MenuShell = require(scripts:WaitForChild("MenuShell"))

local create = UiKit.create
local Space = UiKit.Space
local GUI_NAME = "BRR_MenuShellProbe"

local failures, passes = 0, 0

local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[PROBE] %s %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

local function report(label, detail)
	print(string.format("[PROBE] ---- %s  (%s)", label, tostring(detail)))
end

local function settle()
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
end

local function freshGui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	return create("ScreenGui", {
		Name = GUI_NAME,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ResetOnSpawn = false,
		Parent = StarterGui,
	})
end

-- The destinations MenuClient hands the shell TODAY, copied from its TABS and DESTINATION_LOOK in
-- the built place. NINE, not eight: `Style` was added after the rail was sized, and it is also the
-- one with no glyph and no subtitle because DESTINATION_LOOK was never given an entry for it. Nine
-- is what makes the rail overflow on a desktop, so a probe using a tidy eight would be measuring a
-- menu nobody has.
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

local SCREENS = {
	{ name = "1920x1080", size = Vector2.new(1920, 1080), touch = false },
	{ name = "1366x768", size = Vector2.new(1366, 768), touch = false },
	{ name = "1280x720", size = Vector2.new(1280, 720), touch = false },
	{ name = "1024x600", size = Vector2.new(1024, 600), touch = false },
	{ name = "tablet_1024x768", size = Vector2.new(1024, 768), touch = true },
	{ name = "phone_844x390", size = Vector2.new(844, 390), touch = true },
	{ name = "portrait_375x667", size = Vector2.new(375, 667), touch = true },
}
-- 1280x720 is the size the shell was FROZEN at in the built place, so it is the state of Oliver's
-- own menu; 844x390 is the tightest. Both get the planted fault.
local PLANT_SCREENS = { 3, 6 }

--------------------------------------------------------------------------------
-- Rects
--------------------------------------------------------------------------------

local function rectOf(object)
	local p, s = object.AbsolutePosition, object.AbsoluteSize
	return { x0 = p.X, y0 = p.Y, x1 = p.X + s.X, y1 = p.Y + s.Y }
end

local function intersect(a, b)
	local r = { x0 = math.max(a.x0, b.x0), y0 = math.max(a.y0, b.y0), x1 = math.min(a.x1, b.x1), y1 = math.min(a.y1, b.y1) }
	if r.x1 <= r.x0 or r.y1 <= r.y0 then
		return nil
	end
	return r
end

local function overshoot(inner, outer)
	return math.max(0, outer.x0 - inner.x0, inner.x1 - outer.x1, outer.y0 - inner.y0, inner.y1 - outer.y1)
end

--------------------------------------------------------------------------------
-- The one measurement, run over the real nav AND over the planted one
--------------------------------------------------------------------------------

-- `clips` says whether the container hides what runs past it: a ScrollingFrame always does, the
-- plain Frame the shipped code used does not. A cell whose VISIBLE part leaves the panel is what
-- Oliver sees. A cell entirely outside the window of something that scrolls is merely below the
-- fold and is still reachable. They are counted separately on purpose: collapsing them would
-- either excuse the bug or condemn the fix.
local function measureNav(container, clips, panel, cells)
	local panelRect, containerRect = rectOf(panel), rectOf(container)
	local drawnOutside, offWindow, partlyHidden, worst = 0, 0, 0, 0
	for _, cell in ipairs(cells) do
		local cellRect = rectOf(cell)
		-- NOT `clips and intersect(...) or cellRect`. That idiom is a trap when the middle value can
		-- be nil: a cell clipped ENTIRELY out of the window makes intersect return nil, `and` yields
		-- nil, and `or` then falls through to the UNCLIPPED rect -- so a cell that is safely hidden
		-- gets measured as if it were drawn, and reported as spilling out of the panel. That is
		-- exactly what this check did on its first run: it failed two screens that were fine.
		local visible
		if clips then
			visible = intersect(cellRect, containerRect)
		else
			visible = cellRect
		end
		if visible == nil then
			-- Clipped away completely: hidden, and reachable only if the container scrolls.
			offWindow += 1
		else
			local out = overshoot(visible, panelRect)
			if out > 0.5 then
				drawnOutside += 1
				worst = math.max(worst, out)
			end
			-- Cut off at the container's edge: partly readable, and a half-height tab is not a tab.
			if overshoot(cellRect, containerRect) > 0.5 then
				partlyHidden += 1
			end
		end
	end
	return {
		drawnOutside = drawnOutside,
		offWindow = offWindow,
		partlyHidden = partlyHidden,
		worst = worst,
		measured = #cells,
		windowHeight = containerRect.y1 - containerRect.y0,
	}
end

local function navCells(container)
	local cells = {}
	for _, child in ipairs(container:GetDescendants()) do
		if child:IsA("TextButton") then
			table.insert(cells, child)
		end
	end
	return cells
end

--------------------------------------------------------------------------------
-- NAV (#65b): the tabs not fitting inside the panel
--------------------------------------------------------------------------------

local function sectionNav()
	print("[PROBE] == NAV (#65b: the tabs not fitting inside the panel) ==")
	local gui = freshGui()
	local totalCells, screensMeasured, scrollNeeded = 0, 0, 0

	for _, spec in ipairs(SCREENS) do
		local shell = MenuShell.new({ parent = gui, title = "BRAIN ROT ROYALE", viewport = spec.size })
		shell:SetViewport(spec.size, spec.touch)
		shell:SetDestinations(DESTINATIONS, "Brainrots")
		shell:Open()
		settle()

		-- The clipping flag is READ OFF THE INSTANCE, never assumed. Passing `true` here would make
		-- this check report "nothing drawn outside the panel" for a nav that had stopped clipping,
		-- which is the exact false pass the whole fix is supposed to make impossible.
		local result = measureNav(shell.nav, shell.nav.ClipsDescendants, shell.panel, navCells(shell.nav))
		expect("the nav clips its contents at " .. spec.name, shell.nav.ClipsDescendants,
			"ClipsDescendants = " .. tostring(shell.nav.ClipsDescendants))
		totalCells += result.measured
		screensMeasured += 1
		local hidden = result.offWindow + result.partlyHidden
		if hidden > 0 then
			scrollNeeded += 1
		end
		report("nav " .. spec.name, string.format(
			"form %s, panel %dx%d, nav window %.0f px, nav content %.0f px, %d cells, %d drawn OUTSIDE the panel, %d below the fold, %d cut off at the edge, scrolls %s",
			shell.Form, shell.panel.Size.X.Offset, shell.panel.Size.Y.Offset,
			result.windowHeight, shell.navLayout.AbsoluteContentSize.Y,
			result.measured, result.drawnOutside, result.offWindow, result.partlyHidden,
			tostring(shell.nav.ScrollingEnabled)
		))
		expect("no destination drawn outside the panel at " .. spec.name, result.drawnOutside == 0,
			string.format("%d outside, worst %.0f px", result.drawnOutside, result.worst))
		expect("every destination built at " .. spec.name, result.measured == #DESTINATIONS,
			string.format("%d of %d", result.measured, #DESTINATIONS))
		-- CONTAINED IS NOT THE SAME AS REACHABLE. A destination clipped away is fine only if the nav
		-- scrolls to it; in a bottom BAR, which does not scroll, every cell has to be whole. Without
		-- this the portrait bar passed while holding two rows of cells in one row's height, with the
		-- second row sliced to 14 px -- contained, and unusable.
		if not shell.nav.ScrollingEnabled then
			expect("a nav that cannot scroll shows every destination whole at " .. spec.name,
				hidden == 0,
				string.format("%d hidden, %d cut off, content %.0f px in a %.0f px window",
					result.offWindow, result.partlyHidden, shell.navLayout.AbsoluteContentSize.Y, result.windowHeight))
		end
		shell.layer:Destroy()
	end
	report("sample", string.format("%d screens, %d destination cells measured, %d screens need a scroll",
		screensMeasured, totalCells, scrollNeeded))

	-- THE PLANTED FAULT: the nav rebuilt exactly as it shipped -- a plain Frame with a UIListLayout
	-- and 56 px cells, in the same place and at the same size the shell gives it -- run through the
	-- SAME measureNav. It must come back with cells drawn outside the panel. If it does not,
	-- measureNav cannot see the bug and every PASS above it is empty.
	for _, index in ipairs(PLANT_SCREENS) do
		local spec = SCREENS[index]
		local shell = MenuShell.new({ parent = gui, title = "PLANT", viewport = spec.size })
		shell:SetViewport(spec.size, spec.touch)
		shell:SetDestinations(DESTINATIONS, "Brainrots")
		shell:Open()
		settle()
		local cellHeight = shell.short and UiKit.Touch or 56
		local legacy = create("Frame", {
			Name = "LegacyNav",
			Position = shell.nav.Position,
			Size = shell.nav.Size,
			BackgroundTransparency = 1,
			Parent = shell.panel,
		}, { create("UIListLayout", { Padding = UDim.new(0, Space.SM), SortOrder = Enum.SortOrder.LayoutOrder }) })
		for cell = 1, #DESTINATIONS do
			create("TextButton", { Size = UDim2.new(1, 0, 0, cellHeight), Text = "", LayoutOrder = cell, Parent = legacy })
		end
		settle()
		local planted = measureNav(legacy, legacy.ClipsDescendants, shell.panel, navCells(legacy))
		expect("PLANTED FAULT: the nav as it shipped is reported as overflowing at " .. spec.name,
			planted.drawnOutside > 0,
			string.format("%d of %d cells drawn outside the panel, worst %.0f px; %d px of rail in a %.0f px nav",
				planted.drawnOutside, planted.measured, planted.worst,
				#DESTINATIONS * cellHeight + (#DESTINATIONS - 1) * Space.SM, planted.windowHeight))
		shell.layer:Destroy()
	end
	gui:Destroy()
end

--------------------------------------------------------------------------------
-- VIEWPORT (#65a): the shell was never told the screen
--------------------------------------------------------------------------------

local function sectionViewport()
	print("[PROBE] == VIEWPORT (#65a: the shell was never told the screen) ==")
	local gui = freshGui()
	local oldSizes, newSizes, forms = {}, {}, {}
	for _, spec in ipairs(SCREENS) do
		-- As MenuClient built it: no viewport passed, no SetViewport afterwards. The constructor's
		-- own fallback is unchanged, so this really is the shipped code path, not a reconstruction.
		local stale = MenuShell.new({ parent = gui, title = "OLD" })
		table.insert(oldSizes, string.format("%dx%d", stale.panel.Size.X.Offset, stale.panel.Size.Y.Offset))
		stale.layer:Destroy()

		local live = MenuShell.new({ parent = gui, title = "NEW", viewport = spec.size })
		live:SetViewport(spec.size, spec.touch)
		table.insert(newSizes, string.format("%dx%d", live.panel.Size.X.Offset, live.panel.Size.Y.Offset))
		forms[live.Form] = (forms[live.Form] or 0) + 1
		report("panel " .. spec.name, string.format("old %s -> new %s, form %s",
			oldSizes[#oldSizes], newSizes[#newSizes], live.Form))
		live.layer:Destroy()
	end

	local sameOld, sameNew = true, true
	for index = 2, #oldSizes do
		sameOld = sameOld and oldSizes[index] == oldSizes[1]
		sameNew = sameNew and newSizes[index] == newSizes[1]
	end
	-- The OUTCOME, not the branch. One panel size for every screen is the bug, and a "fix" that
	-- still produced one size would fail here however many new code paths it ran.
	expect("PLANTED FAULT: the shipped construction is ONE fixed panel on all " .. #SCREENS .. " screens",
		sameOld, "every screen -> " .. oldSizes[1])
	expect("the new construction sizes itself per screen", not sameNew, table.concat(newSizes, " "))
	expect("all three forms are reachable through the game's own code path",
		(forms.large and forms.short and forms.tall) and true or false,
		string.format("large %d, short %d, tall %d", forms.large or 0, forms.short or 0, forms.tall or 0))

	-- THE WIRING THAT WAS ACTUALLY MISSING, tested directly rather than by proxy.
	--
	-- Everything above exercises `SetViewport`, which always worked and was never the bug. The bug
	-- was that nobody CALLED it, and that lived in MenuClient -- a LocalScript, which this harness
	-- cannot run, so it could not be tested at all. It is `MenuShell:BindViewport` now, so it can.
	local camera = workspace.CurrentCamera
	local live = camera and camera.ViewportSize or Vector2.new(0, 0)
	report("studio camera viewport", string.format("%dx%d", live.X, live.Y))

	-- Stores what it is given, at three sizes.
	do
		local shell = MenuShell.new({ parent = gui, title = "SIZES" })
		for _, spec in ipairs({ SCREENS[1], SCREENS[6], SCREENS[7] }) do
			shell:SetViewport(spec.size, spec.touch)
			expect("the shell stores the viewport it was given: " .. spec.name,
				shell.viewport == spec.size,
				string.format("stored %dx%d, form %s", shell.viewport.X, shell.viewport.Y, tostring(shell.Form)))
		end
		shell.layer:Destroy()
	end

	-- Bound: the stored viewport is the camera's.
	do
		local bound = MenuShell.new({ parent = gui, title = "BOUND" })
		bound:BindViewport()
		settle()
		expect("a BOUND shell's stored viewport equals the camera's",
			bound.viewport == live,
			string.format("stored %dx%d vs camera %dx%d", bound.viewport.X, bound.viewport.Y, live.X, live.Y))
		bound:UnbindViewport()
		bound.layer:Destroy()
	end

	-- PLANTED FAULT: skip the setter, which is exactly what MenuClient did. The shell must be left
	-- holding the constructor's 1280x720 rather than the screen it is on.
	do
		local unbound = MenuShell.new({ parent = gui, title = "UNBOUND" })
		local default = Vector2.new(1280, 720)
		if live == default then
			-- Studio happens to be exactly 1280x720, so "kept the default" and "took the camera's"
			-- are the same value and the plant cannot tell them apart. Say so; do not pass.
			failures += 1
			print(string.format("[PROBE] INCONCLUSIVE the skipped-setter plant: the Studio viewport IS %dx%d, the same as the constructor default, so this case cannot distinguish them. Re-run with a different window size.", live.X, live.Y))
		else
			expect("PLANTED FAULT: a shell with the setter SKIPPED keeps 1280x720 instead of the screen",
				unbound.viewport == default and unbound.viewport ~= live,
				string.format("stored %dx%d, camera %dx%d", unbound.viewport.X, unbound.viewport.Y, live.X, live.Y))
		end
		unbound.layer:Destroy()
	end
	gui:Destroy()
end

--------------------------------------------------------------------------------
-- CLOSE (#66): the X button
--------------------------------------------------------------------------------

-- Every combination of handlers a host might pass. The shipped shell put `options.onClose` straight
-- into the button, so the first two rows here held nil and produced a dead X -- which is exactly
-- what MenuClient did.
local CASES = {
	{ name = "no handlers at all (what MenuClient passed)", options = {} },
	{ name = "onBack only (what MenuClient sets later)", back = true },
	{ name = "onClose only", close = true },
	{ name = "onClose and onBack", close = true, back = true },
}

local function sectionClose()
	print("[PROBE] == CLOSE (#66: the X button) ==")
	print("[PROBE] NOTE: Studio's plugin sandbox refuses synthetic input, so this measures the wiring, not a click. A real click is Oliver's playtest.")
	local gui = freshGui()

	for _, case in ipairs(CASES) do
		local ran = 0
		local shell = MenuShell.new({ parent = gui, title = "BRAIN ROT ROYALE", viewport = Vector2.new(1280, 720) })
		shell:SetViewport(Vector2.new(1280, 720), false)
		shell:SetDestinations(DESTINATIONS, "Brainrots")
		if case.close then
			shell.onClose = function()
				ran += 1
				shell:Close()
			end
		end
		if case.back then
			shell.onBack = function()
				ran += 1
				shell:Close()
			end
		end
		shell:Open()
		settle()

		local handler = shell.HeaderHandlers and shell.HeaderHandlers.close
		expect("the X is built WITH a handler: " .. case.name, handler ~= nil, "onClick slot = " .. tostring(handler))
		expect("the X button exists and is labelled X: " .. case.name,
			shell.HeaderActions ~= nil and shell.HeaderActions.close ~= nil and shell.HeaderActions.close.Text == "X",
			shell.HeaderActions and shell.HeaderActions.close and shell.HeaderActions.close.Text or "nil")
		if handler then
			handler()
			task.wait(0.35)
			expect("the X closes the panel: " .. case.name, not shell:IsOpen(),
				string.format("layer visible = %s, host handler ran %d time(s)", tostring(shell.layer.Visible), ran))
		end
		shell.layer:Destroy()
	end

	-- THE REAL PERMANENT FAULT DETECTOR IS THE FOUR CASES ABOVE, not the block below. Put
	-- `onClick = options.onClose` back into MenuShell -- the shipped code -- and the first two cases
	-- go red immediately, because MenuClient passes no onClose and sets onBack only afterwards.
	-- That is the regression this file exists to catch, and it runs every time.
	--
	-- The block below is a weaker, honest extra: it shows that the API still PERMITS a dead button
	-- (a host that omits the option gets a nil slot) and that reading the slot sees the nil. It is
	-- close to asserting a fact about Lua, and it is not doing the heavy lifting; it is here so the
	-- shipped shape is written down next to the fixed one rather than only described in a comment.
	do
		local options = {}
		local shipped = {
			{ glyph = "⚙", onClick = options.onSettings },
			{ glyph = "X", onClick = options.onClose },
		}
		local frame = create("Frame", {
			Position = UDim2.fromOffset(40, 40),
			Size = UDim2.fromOffset(420, 64),
			BackgroundTransparency = 1,
			Parent = gui,
		})
		UiParts.header({ parent = frame, width = 420, title = "PLANT", slot = false, actions = shipped })
		settle()
		expect("PLANTED FAULT: the X as it shipped is reported as having NO handler",
			shipped[2].onClick == nil, "onClick slot = " .. tostring(shipped[2].onClick))
		expect("PLANTED FAULT: the gear as it shipped is reported as having NO handler",
			shipped[1].onClick == nil, "onClick slot = " .. tostring(shipped[1].onClick))
	end

	-- The gear, with no onSettings, selects the Settings destination rather than doing nothing.
	do
		local shell = MenuShell.new({ parent = gui, title = "GEAR", viewport = Vector2.new(1280, 720) })
		shell:SetViewport(Vector2.new(1280, 720), false)
		shell:SetDestinations(DESTINATIONS, "Brainrots")
		shell:Open()
		settle()
		local handler = shell.HeaderHandlers and shell.HeaderHandlers.settings
		expect("the gear is built WITH a handler", handler ~= nil, "onClick slot = " .. tostring(handler))
		if handler then
			handler()
			task.wait(0.1)
			expect("the gear with no onSettings selects Settings", shell.active == "Settings", "active = " .. tostring(shell.active))
		end
		shell.layer:Destroy()
	end
	gui:Destroy()
end

--------------------------------------------------------------------------------
-- Geometry first, and every section in its own pcall: on the first run an error in the input
-- section aborted the whole probe and the #65 numbers were never taken.
--------------------------------------------------------------------------------

print("[PROBE] menu_shell_probe: #65 the tabs, #66 the X button")
for _, section in ipairs({
	{ name = "NAV", run = sectionNav },
	{ name = "VIEWPORT", run = sectionViewport },
	{ name = "CLOSE", run = sectionClose },
}) do
	local ok, err = pcall(section.run)
	if not ok then
		failures += 1
		print(string.format("[PROBE] FAIL section %s threw: %s", section.name, tostring(err)))
	end
end
print(string.format("[PROBE] RESULT %d passed, %d failed", passes, failures))

--------------------------------------------------------------------------------
-- NEGATIVE WIDTHS (the labels that draw nothing on a portrait phone)
--------------------------------------------------------------------------------

-- `UDim2.new(1, -N, ...)` past the parent's width draws NOTHING rather than truncating, so a row
-- goes blank with no sign of what happened. Five labels in MenuClient were sized that way and
-- became reachable the moment the `tall` form started running. The arithmetic now goes through
-- UiKit.textSpan, which is pure and lives in a module precisely so this can test it -- the
-- renderers themselves are in a LocalScript and nothing in this harness can run one.
local function sectionSpans()
	print("[PROBE] == SPANS (labels that drew nothing at portrait widths) ==")
	-- Every content width the shell produces, measured: `tall` gives panel width - 24.
	local WIDTHS = { 296, 311, 326, 350, 603, 645, 728, 780 }
	-- The five reserves that were in the tree, worst case for each.
	local RESERVES = { 340, 220, 420, 310, 310 }
	local checked, worst = 0, math.huge
	for _, width in ipairs(WIDTHS) do
		for _, reserve in ipairs(RESERVES) do
			local span = UiKit.textSpan(width, reserve, 22)
			local drawn = width + span.X.Offset
			checked += 1
			worst = math.min(worst, drawn)
			if drawn <= 0 then
				expect(string.format("span stays positive at content %d with reserve %d", width, reserve),
					false, string.format("%d px", drawn))
			end
		end
	end
	expect("every label keeps a positive width at every content width",
		worst > 0, string.format("%d combinations checked, narrowest %d px", checked, worst))
	-- Where there is room, nothing changes: the reserve is honoured exactly.
	local roomy = UiKit.textSpan(728, 340, 22)
	expect("with room to spare the reserve is unchanged", roomy.X.Offset == -340,
		string.format("offset %d at 728 wide", roomy.X.Offset))

	-- THE PLANTED FAULT: the arithmetic as it was in the tree -- a flat `1, -N`. It must come out
	-- NEGATIVE at a portrait width, or this section is not measuring the thing it claims to.
	local shipped = UDim2.new(1, -340, 0, 22)
	expect("PLANTED FAULT: the shipped flat reserve is reported as negative at 296 px of content",
		296 + shipped.X.Offset < 0, string.format("%d px", 296 + shipped.X.Offset))
end

do
	local ok, err = pcall(sectionSpans)
	if not ok then
		failures += 1
		print("[PROBE] FAIL section SPANS threw: " .. tostring(err))
	end
	print(string.format("[PROBE] RESULT (with spans) %d passed, %d failed", passes, failures))
end
