-- Oliver's #90 ("add a minimize button to the controls"): the controls legend at all three owner
-- viewports, in BOTH states -- expanded (with the 44x44 minimize button visible, top-right of the
-- panel) and minimized (the pill/icon it collapses to). Desktop keeps the wordy "? CONTROLS" pill;
-- landscape phone gets a compact "?" icon in its own reserved slot (PhoneLayout's controlsHint
-- rect); portrait stays hidden (no slot -- ControlsHint.client.lua's own comment says why).
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/controls_hint_gallery.lua -OutDir <dir> -Hold 1 -PlaceFile <rbxlx>

local StarterPlayer = game:GetService("StarterPlayer")
local ok_ps, PhoneLayout = pcall(require, StarterPlayer.StarterPlayerScripts:WaitForChild("PhoneLayout"))
assert(ok_ps, "PhoneLayout didn't load: " .. tostring(PhoneLayout))
local UiKit = require(StarterPlayer.StarterPlayerScripts:WaitForChild("UiKit"))

local create = UiKit.create
local Role, Type, Space, Radius = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local VIEWPORTS = {
	{ name = "1920x1080", x = 1920, y = 1080, force = nil },
	{ name = "844x390", x = 844, y = 390, force = "handheld" },
	{ name = "375x667", x = 375, y = 667, force = "upright" },
}

local WIDTH, ROW, HEADER_H = 228, 22, 44
local ROWS_DESKTOP, ROWS_TOUCH = 8, 2
local STACK_RIGHT, LEFT_STACK_TOP, HOTBAR_INSET, GAP = 316, 202, 706, 12

local ROW_TEXT = {
	{ "B", "Bag — swap and DROP" }, { "G", "Pet ability" }, { "Q", "Movement item" },
	{ "C", "Crouch" }, { "Z", "Zoom" }, { "F", "Inspect gun" }, { "J", "Quests" }, { "M", "Menu" },
}

-- Builds a real ControlsHint-shaped panel (header + minimize button + rows) or the collapsed
-- pill/icon, at the given screen position, scaled to fit its mockup viewport.
local function buildPanel(parent, x, y, open, phoneIcon, k)
	k = k or 1
	if not open then
		local pill = create("TextButton", {
			Position = UDim2.fromOffset(x, y),
			Size = phoneIcon and UDim2.fromOffset(44 * k, 44 * k) or UDim2.fromOffset(104 * k, 28 * k),
			BackgroundColor3 = Role.Base,
			BackgroundTransparency = 0.1,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Font = Type.Label.Font,
			Text = phoneIcon and "?" or "? CONTROLS",
			TextColor3 = Role.TextMuted,
			TextSize = 12 * k,
			Parent = parent,
		}, { UiKit.rounded(6 * k) })
		create("UIStroke", { Color = Role.Line, Thickness = 1, Parent = pill })
		return pill
	end

	local rows = phoneIcon and ROWS_TOUCH or ROWS_DESKTOP
	local height = HEADER_H + ROW * rows + 8
	local root = create("Frame", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(WIDTH * k, height * k),
		BackgroundColor3 = Role.Base,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Parent = parent,
	}, { UiKit.rounded(10 * k) })
	create("UIStroke", { Color = Role.Line, Thickness = 1, Parent = root })
	create("TextLabel", {
		Position = UDim2.fromOffset(Space.MD * k, 0),
		Size = UDim2.fromOffset((WIDTH - Space.MD - 6 - 44) * k, HEADER_H * k),
		BackgroundTransparency = 1,
		Font = Type.Label.Font,
		Text = "CONTROLS",
		TextColor3 = Role.TextMuted,
		TextSize = 12 * k,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = root,
	})
	-- The 44x44 minimize button, top-right, highlighted so it reads clearly in the render.
	local btn = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(44 * k, 44 * k),
		BackgroundColor3 = Role.Accent,
		BackgroundTransparency = 0.85,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Parent = root,
	}, { UiKit.rounded(6 * k) })
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(16 * k, 3 * k),
		BackgroundColor3 = Role.TextMuted,
		BorderSizePixel = 0,
		Parent = btn,
	}, { UiKit.rounded(2) })
	create("UIStroke", { Color = Role.Accent, Thickness = 1.5 * k, Transparency = 0.3, Parent = btn })
	for index = 1, rows do
		local ry = (HEADER_H + (index - 1) * ROW) * k
		create("TextLabel", {
			Position = UDim2.fromOffset(Space.MD * k, ry),
			Size = UDim2.fromOffset(62 * k, (ROW - 4) * k),
			BackgroundColor3 = Role.SurfaceAlt,
			BackgroundTransparency = 0.25,
			Font = Type.Label.Font,
			Text = ROW_TEXT[index][1],
			TextColor3 = Role.Text,
			TextSize = 11 * k,
			Parent = root,
		}, { UiKit.rounded(4 * k) })
		create("TextLabel", {
			Position = UDim2.fromOffset((Space.MD + 70) * k, ry),
			Size = UDim2.fromOffset((WIDTH - Space.MD * 2 - 70) * k, (ROW - 4) * k),
			BackgroundTransparency = 1,
			Font = Type.Body.Font,
			Text = ROW_TEXT[index][2],
			TextColor3 = Role.TextMuted,
			TextSize = 11 * k,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = root,
		})
	end
	return root
end

local views = {}
table.insert(views, {
	name = "controls_hint_90_all_states",
	settle = 1.2,
	setup = function(_, camera)
		local root = Instance.new("ScreenGui")
		root.IgnoreGuiInset = true
		root.ResetOnSpawn = false
		root.Parent = game:GetService("CoreGui")
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1400, 760),
			BackgroundColor3 = Color3.fromRGB(18, 19, 24),
			BorderSizePixel = 0,
			Parent = root,
		}, { UiKit.rounded(16) })
		create("UIScale", {
			Scale = math.min(camera.ViewportSize.X * 0.96 / 1400, camera.ViewportSize.Y * 0.92 / 760),
			Parent = sheet,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(20, 8),
			Size = UDim2.fromOffset(1360, 26),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "#90 -- controls legend minimize button, real positions, both states, all three viewports",
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = sheet,
		})

		local SCALE = 0.42
		local col = 0
		for _, vw in ipairs(VIEWPORTS) do
			PhoneLayout.Force = vw.force
			local phone = vw.force ~= nil
			local w, h = vw.x * SCALE, vw.y * SCALE
			local x = 20 + col * (w + 40)
			for row, open in ipairs({ true, false }) do
				local y = 46 + (row - 1) * (h + 50)
				local screen = create("Frame", {
					Position = UDim2.fromOffset(x, y),
					Size = UDim2.fromOffset(w, h),
					BackgroundColor3 = Color3.fromRGB(30, 32, 40),
					BorderSizePixel = 0,
					ClipsDescendants = true,
					Parent = sheet,
				})
				create("UIStroke", { Color = Color3.fromRGB(90, 95, 110), Thickness = 1, Parent = screen })
				create("TextLabel", {
					Position = UDim2.fromOffset(0, -20),
					Size = UDim2.fromOffset(w, 18),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					Text = vw.name .. (open and " -- expanded" or " -- minimized"),
					TextColor3 = Color3.new(1, 1, 1),
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = screen,
				})

				if not phone then
					local height = open and (HEADER_H + ROW * ROWS_DESKTOP + 8) or 28
					local gutterX = STACK_RIGHT + GAP
					local fits = (vw.x - HOTBAR_INSET) - gutterX - GAP >= WIDTH
					local px = fits and gutterX or 16
					local py = (vw.y - (fits and GAP or (LEFT_STACK_TOP + GAP)) - height)
					buildPanel(screen, px * SCALE, py * SCALE, open, false, SCALE)
					note(string.format("%s %s: x=%d y=%d (desktop gutter formula)", vw.name, open and "expanded" or "minimized", px, py))
				else
					local spots = PhoneLayout.Rects(Vector2.new(vw.x, vw.y))
					local spot = spots.controlsHint
					if spot then
						if open then
							local height = HEADER_H + ROW * ROWS_TOUCH + 8
							buildPanel(screen, (spot.x1 - WIDTH) * SCALE, (spot.y1 + 6) * SCALE, true, true, SCALE)
							note(string.format("%s expanded: below-left of the icon at x=%d y=%d", vw.name, spot.x1 - WIDTH, spot.y1 + 6))
						else
							buildPanel(screen, spot.x * SCALE, spot.y * SCALE, false, true, SCALE)
							note(string.format("%s minimized: icon at x=%d y=%d (PhoneLayout.controlsHint)", vw.name, spot.x, spot.y))
						end
					else
						create("TextLabel", {
							Position = UDim2.fromOffset(10, 10),
							Size = UDim2.fromOffset(w - 20, 40),
							BackgroundTransparency = 1,
							Font = Type.Body.Font,
							Text = "hidden on portrait -- no reserved slot (measured, see ControlsHint.client.lua)",
							TextColor3 = Color3.fromRGB(180, 100, 100),
							TextSize = 12,
							TextWrapped = true,
							Parent = screen,
						})
						note(vw.name .. " " .. (open and "expanded" or "minimized") .. ": HIDDEN (portrait, no controlsHint slot)")
					end
				end
			end
			col += 1
		end
	end,
})

return views
