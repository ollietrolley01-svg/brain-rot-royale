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

local function fit()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
	scale.Scale = UiKit.form(viewport) == "large" and 1 or 0.8
end

local shownKey = nil
local function render()
	local text = player:GetAttribute("CompanionBoons")
	local name = player:GetAttribute("CompanionBoonName")
	if type(text) ~= "string" or text == "" then
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
	panel.Position = UDim2.new(0, -WIDTH, 0.5, 0)
	TweenService:Create(panel, TweenInfo.new(fresh and 0.45 or 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, Space.LG, 0.5, 0),
	}):Play()
	stroke.Transparency = 0
	stroke.Thickness = 3
	TweenService:Create(stroke, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 0.35,
		Thickness = 1.5,
	}):Play()
end

player:GetAttributeChangedSignal("CompanionBoons"):Connect(render)
player:GetAttributeChangedSignal("CompanionBoonName"):Connect(render)

local camera = workspace.CurrentCamera
if camera then
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end
render()
