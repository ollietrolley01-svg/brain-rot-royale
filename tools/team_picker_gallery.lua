-- The team picker on every kind of screen, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/team_picker_gallery.lua -OutDir <folder> -PlaceFile <copy of the build>
--
-- Each view is a mock screen of one device's size, shrunk to fit the viewport, with every zone the picker
-- keeps clear of outlined and named (TeamPickerLayout.Zones: the top bar, chat, the lobby HUD, Roblox's
-- touch controls), and the REAL TeamPickerScreen laid out by the REAL TeamPickerLayout on top of it:
--   phone     844x390 on its side and 390x844 upright (touch, compact panel, AUTO selected)
--   tablet    1024x768 (touch, a side picked)
--   desktop   1920x1080 (keyboard: keycaps 1 / 2 / 3, Ember picked, a refused tap on a full Teal)
--   console   1920x1080 (gamepad: the focus ring on Teal, A and B caps)
-- The screen's layout attributes (Scale, Variant, Readable) are noted for each view.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(Scripts:WaitForChild("UiKit"))
local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))
local TeamPickerLayout = require(Scripts:WaitForChild("TeamPickerLayout"))
local TeamPickerScreen = require(Scripts:WaitForChild("TeamPickerScreen"))
local GameModes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameModes"))

local GUI_NAME = "BRR_TeamPickerGallery"
local INSET = 58

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function roster(n, names, meAt)
	local list = {}
	for i = 1, n do
		list[i] = { name = names[(i - 1) % #names + 1], me = i == meAt }
	end
	return list
end

local EMBER = { "SkibidiSam", "TralaleroFan_22", "CappuccinoAssassino", "rizzlord", "BombardiroBob", "NoobMaster" }
local TEAL = { "TungTungTina", "BrrBrrPatapim", "chimpanzini", "LaVacaSaturno" }

local function snapshot(options)
	local picked1, picked2 = options.picked1 or 3, options.picked2 or 2
	return {
		open = true, mode = options.mode or "TeamDeathmatch", secondsLeft = options.seconds or 9, seconds = 12,
		cap = options.cap or 4, humans = options.humans or 8, total = 30, undecided = options.undecided or 3,
		mine = options.mine or 0, autoSide = 2,
		teams = {
			{ picked = picked1, roster = roster(picked1, EMBER, options.meOn == 1 and 1 or nil), more = 0, bots = 11,
				size = 15, projected = 4, full = picked1 >= (options.cap or 4) },
			{ picked = picked2, roster = roster(picked2, TEAL, options.meOn == 2 and 1 or nil), more = 0, bots = 11,
				size = 15, projected = 4, full = picked2 >= (options.cap or 4) },
		},
	}
end

local function gui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local g = Instance.new("ScreenGui")
	g.Name = GUI_NAME
	g.IgnoreGuiInset = true
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.DisplayOrder = 10
	g.Parent = StarterGui
	return g
end

-- A device's screen, sky over grass, shrunk to fit the viewport, with the zones outlined.
local function mockScreen(parent, camera, spec, zones)
	local viewport = camera.ViewportSize
	local fit = math.min(viewport.X * 0.94 / spec.size.X, viewport.Y * 0.9 / spec.size.Y)
	local screen = UiKit.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(spec.size.X, spec.size.Y),
		BackgroundColor3 = Color3.fromRGB(118, 160, 196),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	UiKit.create("UIScale", { Scale = fit, Parent = screen })
	UiKit.create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 196, 236)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(214, 226, 232)),
			ColorSequenceKeypoint.new(0.56, Color3.fromRGB(104, 150, 82)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(78, 118, 60)),
		}),
		Parent = screen,
	})
	for _, z in ipairs(zones) do
		local frame = UiKit.create("Frame", {
			Position = UDim2.fromOffset(z.x, z.y),
			Size = UDim2.fromOffset(z.w, z.h),
			BackgroundColor3 = Color3.fromRGB(20, 22, 30),
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Parent = screen,
		}, { UiKit.rounded(6) })
		UiKit.create("UIStroke", { Color = Color3.fromRGB(200, 204, 220), Thickness = 1, Transparency = 0.3, Parent = frame })
		UiKit.create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = z.name,
			TextColor3 = Color3.fromRGB(230, 232, 240),
			TextSize = 12,
			TextWrapped = true,
			Parent = frame,
		})
	end
	UiKit.create("TextLabel", {
		Position = UDim2.new(0, 12, 1, -34),
		Size = UDim2.fromOffset(500, 24),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = spec.name,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.4,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = screen,
	})
	return screen
end

local VIEWS = {
	{ name = "phone 844x390 (touch, AUTO)", size = Vector2.new(844, 390), touch = true, input = "touch",
		snap = { mine = 0 } },
	{ name = "phone 390x844 upright (touch, Teal picked)", size = Vector2.new(390, 844), touch = true, input = "touch",
		snap = { mine = 2, meOn = 2, picked2 = 3, undecided = 2 } },
	{ name = "tablet 1024x768 (touch, Ember picked)", size = Vector2.new(1024, 768), touch = true, input = "touch",
		snap = { mine = 1, meOn = 1, picked1 = 4, undecided = 1 } },
	{ name = "desktop 1920x1080 (keyboard, Teal full)", size = Vector2.new(1920, 1080), touch = false, input = "keyboard",
		snap = { mine = 1, meOn = 1, picked1 = 3, picked2 = 4, undecided = 1, seconds = 3 }, refuse = 2 },
	{ name = "console 1920x1080 (gamepad, focus on Teal)", size = Vector2.new(1920, 1080), touch = false, input = "gamepad",
		snap = { mine = 0, mode = "KingOfTheHill" }, focus = 2 },
}

TeamPickerScreen.Instant = true

local views = {}
for _, spec in ipairs(VIEWS) do
	table.insert(views, {
		name = "team_picker_" .. spec.name:gsub("[^%w]+", "_"):lower(),
		settle = 1.2,
		hold = 1.8,
		setup = function(_, camera)
			camera.FieldOfView = 70
			camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
			local ctx = {
				inset = INSET,
				touch = spec.touch,
				phone = spec.touch and PhoneLayout.Rects(spec.size) or nil,
				safe = TeamPickerLayout.rect(0, 0, spec.size.X, spec.size.Y),
			}
			local fit = TeamPickerLayout.Compute(spec.size, ctx)
			local screen = mockScreen(gui(), camera, spec, fit.zones)
			local picker = TeamPickerScreen.new(screen)
			picker.input = spec.input
			picker:Layout(fit)
			picker:Render(snapshot(spec.snap))
			picker:SetInput(spec.input)
			if spec.focus then
				picker.focus = spec.focus
				picker:SetInput(spec.input)
			end
			if spec.refuse then
				picker:Refused(spec.refuse, "full")
			end
			picker:Show()
			local panel = picker.panel
			note(string.format("%s: %s x%.2f readable=%s panel %dx%d at (%d,%d), rows %d", spec.name,
				tostring(panel:GetAttribute("Variant")), panel:GetAttribute("Scale") or 0,
				tostring(panel:GetAttribute("Readable")), fit.panel.w, fit.panel.h, fit.panel.x, fit.panel.y, fit.rows))
		end,
	})
end

table.insert(views, {
	name = "team_picker_cleanup",
	settle = 0.2,
	hold = 0.2,
	setup = function()
		local old = StarterGui:FindFirstChild(GUI_NAME)
		if old then
			old:Destroy()
		end
	end,
})

-- Unused, but keeps GameModes loaded before the first view (the screen requires it lazily otherwise).
local _ = GameModes.TeamCount

return views
