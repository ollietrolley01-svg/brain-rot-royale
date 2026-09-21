-- Stamina bar gallery: the real bar (StarterPlayerScripts/StaminaBar) in every state, on mock screens
-- at 1920x1080, 1366x768, 1024x768 and a phone in landscape (844x390), with the health panel, companion
-- panel and icon, speed pill, hotbar, Inventory tab and the phone's touch controls outlined where they
-- really sit, placed by StaminaBar.Layout exactly as HudClient places it, so any collision shows up.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/stamina_gallery.lua -OutDir <folder>
--
-- Edit mode doesn't step RenderStepped, so each state is set with StaminaBar:Snap rather than animated.
-- The last view is a close-up sheet of every state at 2x, for judging the details.

local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local StaminaBar = require(scripts:WaitForChild("StaminaBar"))
local UiKit = require(scripts:WaitForChild("UiKit"))

local GUI_NAME = "BRR_StaminaGallery"

local SCREENS = {
	{ name = "1920x1080", size = Vector2.new(1920, 1080), touch = false },
	{ name = "1366x768", size = Vector2.new(1366, 768), touch = false },
	{ name = "1024x768", size = Vector2.new(1024, 768), touch = true },
	{ name = "phone_844x390", size = Vector2.new(844, 390), touch = true },
}

local STATES = {
	{ name = "full_idle", state = { value = 100, idleFor = 3 } },
	{ name = "sprinting", state = { value = 64, draining = true } },
	{ name = "slide_bite", state = { value = 46 }, ghost = 0.64 },
	{ name = "refilling", state = { value = 45, rising = true } },
	{ name = "low", state = { value = 21, draining = true } },
	{ name = "exhausted", state = { value = 9, exhausted = true } },
	{ name = "rush", state = { value = 100, rush = true } },
}

local function freshGui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.Parent = StarterGui
	return gui
end

local function aimAtSky(camera)
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
end

local function outline(parent, position, size, anchor, label, shape)
	local frame = UiKit.create("Frame", {
		AnchorPoint = anchor or Vector2.zero,
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.fromRGB(20, 22, 30),
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Parent = parent,
	}, { UiKit.rounded(shape == "circle" and 999 or 10) })
	UiKit.create("UIStroke", { Color = Color3.fromRGB(120, 124, 140), Thickness = 1, Parent = frame })
	UiKit.create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = label,
		TextColor3 = Color3.fromRGB(150, 154, 170),
		TextSize = 12,
		Parent = frame,
	})
	return frame
end

-- A mock screen of `spec.size` pixels, shrunk by `fit` to sit inside the viewport.
local function mockScreen(gui, camera, spec)
	local viewport = camera.ViewportSize
	local fit = math.min(viewport.X * 0.92 / spec.size.X, viewport.Y * 0.88 / spec.size.Y)
	local screen = UiKit.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(spec.size.X, spec.size.Y),
		BackgroundColor3 = Color3.fromRGB(118, 160, 196),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = gui,
	})
	UiKit.create("UIScale", { Scale = fit, Parent = screen })
	-- Sky over grass, so the bar is judged over the colours it really sits on.
	UiKit.create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 196, 236)),
			ColorSequenceKeypoint.new(0.62, Color3.fromRGB(214, 226, 232)),
			ColorSequenceKeypoint.new(0.63, Color3.fromRGB(104, 150, 82)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(78, 118, 60)),
		}),
		Parent = screen,
	})
	UiKit.create("TextLabel", {
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.fromOffset(400, 24),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = spec.name,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.5,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = screen,
	})
	-- Where HudClient really puts things (pixels, unscaled, as it builds them), shown during a match.
	outline(screen, UDim2.new(0, 16, 1, -96), UDim2.fromOffset(280, 80), nil, "HEALTH")
	outline(screen, UDim2.new(0, 16, 1, -166), UDim2.fromOffset(300, 62), nil, "COMPANION")
	outline(screen, UDim2.new(0, 16, 1, -202), UDim2.fromOffset(150, 28), nil, "SPEED BOOST")
	outline(screen, UDim2.new(0, 326, 1, -172), UDim2.fromOffset(78, 78), nil, "PET")
	outline(screen, UDim2.new(1, -16, 1, -16), UDim2.fromOffset(690, 150), Vector2.new(1, 1), "HOTBAR")
	outline(screen, UDim2.new(1, -706, 1, -166), UDim2.fromOffset(120, 30), Vector2.new(0, 1), "INVENTORY")
	if spec.touch then
		outline(screen, UDim2.new(0, 60, 1, -60), UDim2.fromOffset(140, 140), Vector2.new(0, 1), "STICK", "circle")
		outline(screen, UDim2.new(1, -40, 1, -50), UDim2.fromOffset(110, 110), Vector2.new(1, 1), "JUMP", "circle")
		-- The ContextActionService touch buttons where the binds put them. A CoreScript touch button is
		-- 45 px (35 on very small screens), not the 70 this mock first assumed.
		for _, button in ipairs({
			{ "FIRE", -140, -180 }, { "RELOAD", -140, -280 },
			{ "AIM", -250, -180 }, { "RUN", -250, -280 },
			{ "PET", -360, -180 }, { "CAM", -360, -280 },
			{ "SLIDE", -470, -180 }, { "MOVE", -470, -280 },
		}) do
			outline(screen, UDim2.new(1, button[2], 1, button[3]), UDim2.fromOffset(45, 45), nil, button[1], "circle")
		end
	end
	-- The crosshair, for reference.
	outline(screen, UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(8, 8), Vector2.new(0.5, 0.5), "")
	return screen
end

local views = {}

for _, spec in ipairs(SCREENS) do
	for _, entry in ipairs(STATES) do
		table.insert(views, {
			name = spec.name .. "_" .. entry.name,
			settle = 0.6,
			setup = function(_folder, camera)
				aimAtSky(camera)
				local gui = freshGui()
				local screen = mockScreen(gui, camera, spec)
				local bar = StaminaBar.new(screen)
				bar:Place(spec.size)
				bar:Snap(entry.state, entry.ghost)
			end,
		})
	end
end

table.insert(views, {
	name = "sheet_2x",
	settle = 0.6,
	setup = function(_folder, camera)
		aimAtSky(camera)
		local gui = freshGui()
		local sheet = UiKit.create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(880, 110 * #STATES + 20),
			BackgroundColor3 = Color3.fromRGB(96, 132, 88),
			BorderSizePixel = 0,
			Parent = gui,
		})
		for index, entry in ipairs(STATES) do
			local row = UiKit.create("Frame", {
				Position = UDim2.fromOffset(0, 10 + (index - 1) * 110),
				Size = UDim2.fromOffset(880, 110),
				BackgroundTransparency = 1,
				Parent = sheet,
			})
			UiKit.create("TextLabel", {
				Position = UDim2.fromOffset(10, 0),
				Size = UDim2.fromOffset(110, 106),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = entry.name,
				TextColor3 = Color3.new(1, 1, 1),
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = row,
			})
			local bar = StaminaBar.new(row)
			bar.Frame.AnchorPoint = Vector2.new(0, 0.5)
			bar.Frame.Position = UDim2.new(0, 130, 0.5, 0)
			bar:SetScale(1.95)
			bar:Snap(entry.state, entry.ghost)
		end
		local viewport = camera.ViewportSize
		UiKit.create("UIScale", { Scale = math.min(viewport.X * 0.9 / 880, viewport.Y * 0.9 / (110 * #STATES + 20), 1), Parent = sheet })
	end,
})

table.insert(views, {
	name = "cleanup",
	settle = 0.2,
	setup = function()
		local old = StarterGui:FindFirstChild(GUI_NAME)
		if old then
			old:Destroy()
		end
	end,
})

return views
