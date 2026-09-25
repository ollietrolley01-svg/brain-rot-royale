-- Renders for task/device-compat (the phone and Xbox pass), for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/device_compat_gallery.lua -OutDir <dir> -Hold 1
--
--   spectate_portrait    the spectate plate on a 375x667 upright phone, the old flat 620 px plate
--                        beside the new one (screen width less 12 px a side, capped at 620)
--   spectate_landscape   the same at 667x375
--   tvsafe_hud           the in-match HUD at 1920x1080 with the 5% TV-safe margin (96 px sides, 54 px
--                        top and bottom) drawn in; red = crosses the margin
--   tvsafe_menu          the real MenuShell at 1920x1080 with the same margin
--
-- The plate is a copy of CombatClient's setSpectating (a LocalScript's local can't be required); keep
-- them in step. The HUD rects are `hud_layout_check --dump` at desktop 1920x1080 (the client scripts
-- run under lupa), every state merged; rerun the dump and update HUD_RECTS if they move. Each view
-- prints measured numbers as `note` lines, so the verdict doesn't rest on eyeballing the capture.

local StarterPlayer = game:GetService("StarterPlayer")
local TextService = game:GetService("TextService")
local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(Scripts:WaitForChild("UiKit"))
local MenuShell = require(Scripts:WaitForChild("MenuShell"))

local create = UiKit.create
local GUI_NAME = "BRR_DeviceCompatGallery"

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function freshGui()
	local core = game:GetService("CoreGui")
	local old = core:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = core
	return gui
end

local function sky(camera)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
end

-- A dark sheet of `w` x `h` design pixels, scaled to fill the capture.
local function sheet(gui, camera, w, h, title)
	local frame = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = Color3.fromRGB(18, 19, 24),
		BorderSizePixel = 0,
		Parent = gui,
	})
	local scale = math.min(camera.ViewportSize.X * 0.97 / w, camera.ViewportSize.Y * 0.95 / h)
	create("UIScale", { Scale = scale, Parent = frame })
	create("TextLabel", {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = title,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	return frame, scale
end

local function screen(parent, x, y, w, h, caption)
	local frame = create("Frame", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = Color3.fromRGB(96, 128, 150),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	create("UIStroke", { Color = Color3.fromRGB(230, 230, 240), Thickness = 2, Parent = frame })
	create("TextLabel", {
		Position = UDim2.fromOffset(x, y - 22),
		Size = UDim2.fromOffset(math.max(w, 300), 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = caption,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = parent,
	})
	return frame
end

--------------------------------------------------------------------------------
-- Spectate plate
--------------------------------------------------------------------------------

-- The longest the plate says on a phone: a 20-character name (Roblox's cap) with the touch hint.
local NAME = "BombardiroCrocodilo1"
local TEXTS = {
	touch = string.format("Spectating %s   •   tap NEXT or LEAVE", NAME),
	keyboard = string.format("Spectating %s   •   [E] next   •   [L] leave", NAME),
	empty = "No one left to watch   •   tap LEAVE for the lobby",
}

-- CombatClient.setSpectating's plate and touch buttons, `fixed` = the old flat 620 px plate.
local function spectatePlate(parent, fixed)
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -24)
	if fixed then
		label.Size = UDim2.fromOffset(620, 48)
	else
		label.Size = UDim2.new(1, -24, 0, 48)
		local width = Instance.new("UISizeConstraint")
		width.MaxSize = Vector2.new(620, 48)
		width.Parent = label
	end
	label.TextWrapped = true
	label.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	label.BackgroundTransparency = 0.2
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(240, 242, 248)
	label.TextSize = 16
	label.Text = TEXTS.touch
	label.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label
	for _, b in ipairs({ { "NEXT", -66 }, { "LEAVE", 66 } }) do
		local button = Instance.new("TextButton")
		button.AnchorPoint = Vector2.new(0.5, 1)
		button.Position = UDim2.new(0.5, b[2], 1, -80)
		button.Size = UDim2.fromOffset(120, 44)
		button.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
		button.BackgroundTransparency = 0.15
		button.BorderSizePixel = 0
		button.Font = Enum.Font.GothamBold
		button.TextColor3 = Color3.fromRGB(240, 242, 248)
		button.TextSize = 16
		button.Text = b[1]
		button.Parent = parent
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 10)
		round.Parent = button
	end
end

-- Plate width, how far it runs off each side, and each text's wrapped height against the 48 px plate.
local function measurePlate(vw, fixed)
	local w = fixed and 620 or math.min(vw - 24, 620)
	local off = math.max(0, (w - vw) / 2)
	local parts = {}
	for _, key in ipairs({ "touch", "keyboard", "empty" }) do
		local size = TextService:GetTextSize(TEXTS[key], 16, Enum.Font.GothamBold, Vector2.new(w, 10000))
		table.insert(parts, string.format("%s %d lines/%dpx %s", key, math.floor(size.Y / 16 + 0.5), size.Y,
			size.Y <= 48 and "fits" or "OVERFLOWS"))
	end
	return string.format("plate %dpx wide, %dpx off each side; %s", w, off, table.concat(parts, ", "))
end

local function spectateView(name, vw, vh)
	return {
		name = name,
		settle = 1.2,
		setup = function(_, camera)
			sky(camera)
			local gui = freshGui()
			local portrait = vh > vw
			local gap = 40
			local w = portrait and (vw * 2 + gap * 3) or (vw + gap * 2)
			local h = portrait and (vh + 90) or (vh * 2 + 140)
			local s = sheet(gui, camera, w, h, string.format("Spectate plate on a %dx%d phone: before (flat 620) / after (width - 24, max 620)", vw, vh))
			for i, fixed in ipairs({ true, false }) do
				local x = portrait and (gap + (i - 1) * (vw + gap)) or gap
				local y = portrait and 60 or (60 + (i - 1) * (vh + 60))
				local phone = screen(s, x, y, vw, vh, fixed and "BEFORE (main d1e4f73)" or "AFTER (this branch)")
				spectatePlate(phone, fixed)
				note(string.format("%dx%d %s: %s", vw, vh, fixed and "before" or "after", measurePlate(vw, fixed)))
			end
		end,
	}
end

--------------------------------------------------------------------------------
-- TV-safe margin
--------------------------------------------------------------------------------

local TV = { w = 1920, h = 1080, side = 96, topBottom = 54 }

-- hud_layout_check --dump, desktop 1920x1080, battle royale + team match + driving + gunner merged.
local HUD_RECTS = {
	{ "banner", 740, 10, 440, 56 },
	{ "mode score (team)", 750, 10, 420, 44 },
	{ "compass", 740, 70, 440, 24 },
	{ "crosshair", 947, 527, 26, 26 },
	{ "health", 16, 984, 280, 80 },
	{ "companion card", 16, 914, 300, 62 },
	{ "speed pill", 16, 878, 150, 28 },
	{ "stamina bar", 750, 1000, 368, 50 },
	{ "hotbar", 1214, 914, 690, 150 },
	{ "minimap", 1714, 108, 190, 190 },
	{ "bounty", 1674, 304, 230, 22 },
	{ "kill feed", 1604, 358, 300, 80 },
	{ "toast", 730, 870, 460, 36 },
	{ "ability icon", 964, 954, 244, 110 },
	{ "boon panel", 16, 495, 190, 90 },
	{ "vehicle gun panel", 1093, 824, 150, 78 },
	{ "vehicle panel", 835, 824, 250, 78 },
	{ "vehicle hint", 825, 802, 270, 14 },
}

-- How far a rect crosses each edge of the safe area, as "left 80, bottom 38", or nil.
local function outside(x, y, w, h)
	local parts = {}
	if x < TV.side then
		table.insert(parts, string.format("left %d", TV.side - x))
	end
	if x + w > TV.w - TV.side then
		table.insert(parts, string.format("right %d", x + w - (TV.w - TV.side)))
	end
	if y < TV.topBottom then
		table.insert(parts, string.format("top %d", TV.topBottom - y))
	end
	if y + h > TV.h - TV.topBottom then
		table.insert(parts, string.format("bottom %d", y + h - (TV.h - TV.topBottom)))
	end
	return #parts > 0 and table.concat(parts, ", ") or nil
end

-- The 5% band, shaded, and the safe rect's edge, on top of everything else in `tv`.
local function drawMargin(tv)
	local band = Color3.fromRGB(255, 60, 60)
	for _, r in ipairs({
		{ 0, 0, TV.w, TV.topBottom },
		{ 0, TV.h - TV.topBottom, TV.w, TV.topBottom },
		{ 0, TV.topBottom, TV.side, TV.h - 2 * TV.topBottom },
		{ TV.w - TV.side, TV.topBottom, TV.side, TV.h - 2 * TV.topBottom },
	}) do
		create("Frame", {
			Position = UDim2.fromOffset(r[1], r[2]),
			Size = UDim2.fromOffset(r[3], r[4]),
			BackgroundColor3 = band,
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
			ZIndex = 50,
			Parent = tv,
		})
	end
	create("Frame", {
		Position = UDim2.fromOffset(TV.side, TV.topBottom),
		Size = UDim2.fromOffset(TV.w - 2 * TV.side, TV.h - 2 * TV.topBottom),
		BackgroundTransparency = 1,
		ZIndex = 51,
		Parent = tv,
	}, { create("UIStroke", { Color = Color3.fromRGB(255, 230, 60), Thickness = 3 }) })
end

local function tvScreen(gui, camera, title)
	local s = sheet(gui, camera, TV.w + 40, TV.h + 70, title)
	return screen(s, 20, 50, TV.w, TV.h, "1920x1080; shaded band = 5% TV overscan (96 px sides, 54 px top/bottom)")
end

local views = {
	spectateView("spectate_portrait", 375, 667),
	spectateView("spectate_landscape", 667, 375),
}

table.insert(views, {
	name = "tvsafe_hud",
	settle = 1.2,
	setup = function(_, camera)
		sky(camera)
		local tv = tvScreen(freshGui(), camera, "In-match HUD (hud_layout_check --dump rects, every state) vs the TV-safe area: red = crosses it")
		local count = 0
		for _, r in ipairs(HUD_RECTS) do
			local name, x, y, w, h = r[1], r[2], r[3], r[4], r[5]
			local off = outside(x, y, w, h)
			local color = off and Color3.fromRGB(240, 70, 70) or Color3.fromRGB(90, 220, 130)
			create("Frame", {
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(w, h),
				BackgroundColor3 = color,
				BackgroundTransparency = 0.6,
				BorderSizePixel = 0,
				ZIndex = 10,
				Parent = tv,
			}, {
				create("UIStroke", { Color = color, Thickness = 2 }),
				create("TextLabel", {
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					Text = name,
					TextColor3 = Color3.new(1, 1, 1),
					TextStrokeTransparency = 0.3,
					TextSize = 22,
					TextWrapped = true,
					ZIndex = 11,
				}),
			})
			if off then
				count += 1
				note(string.format("HUD outside: %s (%d,%d %dx%d) past %s", name, x, y, w, h, off))
			end
		end
		drawMargin(tv)
		note(string.format("HUD: %d of %d elements cross the 5%% margin", count, #HUD_RECTS))
	end,
})

table.insert(views, {
	name = "tvsafe_menu",
	settle = 1.5,
	setup = function(_, camera)
		sky(camera)
		local tv = tvScreen(freshGui(), camera, "MenuShell (the real module) at 1920x1080, not touch, vs the TV-safe area")
		local shell = MenuShell.new({ parent = tv, viewport = Vector2.new(TV.w, TV.h), title = "BRAIN ROT ROYALE" })
		shell:SetViewport(Vector2.new(TV.w, TV.h), false)
		shell:SetDestinations({
			{ key = "Brainrots", label = "BRAINROTS", glyph = "★", sub = "Your collection" },
			{ key = "Trade", label = "TRADE", glyph = "⇄", sub = "Swap with players" },
			{ key = "Crates", label = "CRATES", glyph = "▣", sub = "Open and buy" },
			{ key = "Cosmetics", label = "COSMETICS", glyph = "◆", sub = "Skins and auras" },
			{ key = "Pass", label = "PASS", glyph = "▲", sub = "Brainrot Pass" },
			{ key = "Quests", label = "QUESTS", glyph = "✓", sub = "Daily and weekly" },
			{ key = "Shop", label = "SHOP", glyph = "＄", sub = "Robux" },
			{ key = "Settings", label = "SETTINGS", glyph = "⚙", sub = "Keys and audio" },
		}, "Brainrots")
		shell:Open()
		drawMargin(tv)
		task.wait(0.5)
		-- Measure in design pixels: everything under `tv` shares its UIScale.
		local origin, scale = tv.AbsolutePosition, tv.AbsoluteSize.X / TV.w
		local function rect(g)
			return (g.AbsolutePosition.X - origin.X) / scale, (g.AbsolutePosition.Y - origin.Y) / scale,
				g.AbsoluteSize.X / scale, g.AbsoluteSize.Y / scale
		end
		local px, py, pw, ph = rect(shell.panel)
		note(string.format("menu panel (%d,%d %dx%d): %s", px, py, pw, ph, outside(px, py, pw, ph) or "inside the safe area"))
		local crossing = 0
		for _, g in ipairs(shell.panel:GetDescendants()) do
			if g:IsA("GuiObject") and g.Visible and g.AbsoluteSize.X > 0 then
				local x, y, w, h = rect(g)
				local off = outside(x, y, w, h)
				if off then
					crossing += 1
					note(string.format("menu outside: %s (%d,%d %dx%d) past %s", g:GetFullName():sub(-60), x, y, w, h, off))
				end
			end
		end
		note(string.format("menu: %d visible pieces inside the panel cross the margin", crossing))
	end,
})

return views
