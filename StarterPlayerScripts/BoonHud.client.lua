-- The companion buffs you have on right now (Oliver, 2026-09-23 14:49: "a small hud to pop up showing
-- what companion buffs i have activated at the moment").
--
-- The server says what is active through two attributes on the local Player, written by
-- CompanionBoons.Apply / Clear and nothing else:
--   CompanionBoonName   the brainrot giving the buffs
--   CompanionBoons      one buff per line ("+15 max HP", "+5% move speed", ...)
-- So this panel is on exactly while the boon is: a companion that is unequipped, downed or gone takes
-- its buffs off, and the panel goes with them. It pops in (slide and bounce) whenever the set changes,
-- then sits small at the left edge, mid-screen.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local create = UiKit.create
local Role, Type, Space, Radius = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius

local player = Players.LocalPlayer
local BUFF = Color3.fromRGB(120, 235, 140)
local WIDTH = 190

local gui = create("ScreenGui", {
	Name = "BoonHud",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

local panel = create("Frame", {
	Name = "Boons",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, Space.LG, 0.5, 0),
	Size = UDim2.fromOffset(WIDTH, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Role.Base,
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	Visible = false,
	Parent = gui,
}, {
	UiKit.rounded(Radius.Card),
	create("UIPadding", {
		PaddingTop = UDim.new(0, Space.SM),
		PaddingBottom = UDim.new(0, Space.SM),
		PaddingLeft = UDim.new(0, Space.MD),
		PaddingRight = UDim.new(0, Space.MD),
	}),
	create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local stroke = create("UIStroke", { Color = BUFF, Thickness = 1.5, Transparency = 0.35, Parent = panel })
local scale = create("UIScale", { Parent = panel })

local title = create("TextLabel", {
	LayoutOrder = 0,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 16),
	Font = Enum.Font.GothamBlack,
	Text = "COMPANION BUFFS",
	TextColor3 = BUFF,
	TextSize = Type.Caption.Size,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = panel,
})
local source = create("TextLabel", {
	LayoutOrder = 1,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 16),
	Font = Type.Caption.Font,
	Text = "",
	TextColor3 = Role.TextMuted,
	TextSize = Type.Caption.Size,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = panel,
})
local _ = title

local rows = {}

-- Where the panel rests, and its scale. On a desktop screen: the left edge, mid-screen. On a touch
-- screen PhoneLayout owns the HUD and has a slot for it (`Rects().boons`, beside or under the pet
-- tile): the desktop spot sat under the stamina bar on an 844x390 phone and was the same desktop
-- spot on an upright one (#80, tools/hud_layout_check.py). The scale fits the slot's width, and its
-- height too when there are more buffs than it has room for.
local home = { anchor = Vector2.new(0, 0.5), position = UDim2.new(0, Space.LG, 0.5, 0), phone = false }
local function fit()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
	local layout = script.Parent:FindFirstChild("PhoneLayout")
	local ok, PhoneLayout = pcall(require, layout)
	local spot = ok and type(PhoneLayout) == "table" and PhoneLayout.Active(viewport) and PhoneLayout.Rects(viewport).boons or nil
	if spot then
		-- The panel's own height before scaling: the two caption lines, one line per buff, the list's
		-- 2 px gaps and the padding.
		local natural = 16 + 16 + #rows * 18 + (#rows + 1) * 2 + 2 * Space.SM
		scale.Scale = math.min(spot.w / WIDTH, spot.h / natural, 1)
		home = { anchor = Vector2.new(0, 0), position = UDim2.fromOffset(spot.x, spot.y), phone = true }
	else
		scale.Scale = UiKit.form(viewport) == "large" and 1 or 0.8
		home = { anchor = Vector2.new(0, 0.5), position = UDim2.new(0, Space.LG, 0.5, 0), phone = false }
	end
	panel.AnchorPoint = home.anchor
	panel.Position = home.position
end

local shownKey = nil
-- In a vehicle on a touch screen the panel steps aside: PhoneLayout's driving block (VehicleClient's
-- speed panel and the gun panel) takes the same corner of the screen, and nobody reads their buffs while
-- driving. On a desktop screen the two are far apart and the panel stays.
local function drivingOnPhone()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	return home.phone and ((seat ~= nil and seat:IsA("VehicleSeat")) or player:GetAttribute("VehicleGunActive") == true)
end

-- And with no living body on a touch screen (spectating, or between death and the next life): nothing
-- is buffed then, and a spectator's NEXT and LEAVE buttons come up across this corner of a small phone.
local function bodilessOnPhone()
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	return home.phone and not (humanoid and humanoid.Health > 0)
end

local function render()
	local text = player:GetAttribute("CompanionBoons")
	local name = player:GetAttribute("CompanionBoonName")
	fit()
	if type(text) ~= "string" or text == "" or drivingOnPhone() or bodilessOnPhone() then
		panel.Visible = false
		shownKey = nil
		return
	end

	for _, row in ipairs(rows) do
		row:Destroy()
	end
	table.clear(rows)
	source.Text = "from " .. tostring(name or "your companion")
	local index = 1
	for line in string.gmatch(text, "[^\n]+") do
		index += 1
		table.insert(rows, create("TextLabel", {
			LayoutOrder = index,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 18),
			Font = Type.Label.Font,
			Text = "▲ " .. line,
			TextColor3 = Role.Text,
			TextSize = Type.Label.Size,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = panel,
		}))
	end

	fit()
	panel.Visible = true

	-- Pop in when the set of buffs changes: slide from the edge with a bounce and a bright border that
	-- settles. A repeat of the same set (a respawn with the same companion) does it again, briefly.
	local key = tostring(name) .. "|" .. text
	local fresh = key ~= shownKey
	shownKey = key
	panel.Position = UDim2.new(0, -WIDTH, home.position.Y.Scale, home.position.Y.Offset)
	TweenService:Create(panel, TweenInfo.new(fresh and 0.45 or 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = home.position,
	}):Play()
	stroke.Transparency = 0
	stroke.Thickness = 3
	TweenService:Create(stroke, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 0.35,
		Thickness = 1.5,
	}):Play()
end

player:GetAttributeChangedSignal("CompanionBoons"):Connect(render)
player:GetAttributeChangedSignal("VehicleGunActive"):Connect(render)
local function watchSeat(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid then
		humanoid:GetPropertyChangedSignal("SeatPart"):Connect(render)
		humanoid.Died:Connect(render)
	end
	render()
end
player.CharacterAdded:Connect(watchSeat)
player.CharacterRemoving:Connect(function()
	task.defer(render)
end)
if player.Character then
	task.spawn(watchSeat, player.Character)
end
player:GetAttributeChangedSignal("CompanionBoonName"):Connect(render)

local camera = workspace.CurrentCamera
if camera then
	-- The whole render, not just fit: turning the phone can move the panel into (or out of) the corner
	-- the driving block takes.
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(render)
end
render()
