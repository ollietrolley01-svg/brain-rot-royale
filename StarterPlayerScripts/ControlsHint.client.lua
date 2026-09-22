-- The controls that are not obvious, on the HUD (Oliver: "the hud show some of the important and
-- not obvious controls like inventory etc").
--
-- This exists because of a specific discovery: dropping a weapon has worked end to end since it was
-- written -- the server validates it, rate-limits it and puts a real pickup on the ground -- and the
-- only way to ask for it was a RIGHT-CLICK on a hotbar cell. Nothing on screen said so. A feature
-- nobody can find is not a feature, and this is the cheapest fix for the whole class of them.
--
-- What it shows, and what it deliberately does not: moving, looking and shooting are obvious and get
-- no row. Everything here is something a player would otherwise have to be TOLD.
--
-- Every key comes from Settings.KeyLabel, never a hardcoded letter, so a rebound key says what it is
-- rebound to. It re-reads on Settings.Changed for the same reason.
--
-- It opens for a few seconds when you spawn and then collapses to a small pill, because a legend
-- that never goes away is clutter and Oliver's word for the HUD elsewhere was "non-intrusive".

-- Oliver, 2026-09-22 13:59: "the controls hud is inside the daily quest hud ... put the controls in the
-- settings menu". The menu's SETTINGS page already lists every key under CONTROLS (and rebinds them),
-- so the on-screen legend is switched off here rather than moved. Delete this line to bring it back.
do return end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local Settings = require(script.Parent:WaitForChild("Settings"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create = UiKit.create
local Role, Type, Space, Radius = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius

local WIDTH = 228
local ROW = 22
local OPEN_FOR = 12

-- action id -> what it does, in the player's words rather than the code's. Order is what a new
-- player needs soonest.
local ROWS = {
	{ "Inventory", "Bag — swap and DROP" },
	{ "Companion", "Pet ability" },
	{ "MovementItem", "Movement item" },
	{ "Crouch", "Crouch" },
	{ "Zoom", "Zoom" },
	{ "Inspect", "Inspect gun" },
	{ "Quests", "Quests" },
	{ "Menu", "Menu" },
}

-- On a touch screen there are no keys to name. The buttons are already on screen, so the legend
-- would be telling a player about things they can see; the one genuinely hidden route is dropping,
-- which now lives behind a tap in the bag.
local TOUCH_ROWS = {
	{ "Bag", "Tap a slot, then DROP" },
	{ "PET", "Pet ability" },
}

-- Oliver: "the controls hud opens up and is covered by the quest menu". Both are in the left
-- column at x 16 — the quest tracker starts at y 224 and grows DOWNWARD as quests are added, this
-- grows UPWARD from the bottom stack, and on a short screen they meet in the middle. He saw a hint
-- row with its last few letters poking out from under the tracker, which is worse than no hint.
--
-- Two changes, because either alone leaves a case: it draws on its own layer ABOVE the tracker, and
-- it steps out of that column entirely when there is room to the right of the health panel. The
-- DisplayOrder is what guarantees readability; the move is what stops it covering the tracker in
-- return. It is only up for 12 seconds either way.
local gui = create("ScreenGui", {
	Name = "ControlsHint",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 20,
	Parent = player:WaitForChild("PlayerGui"),
})

-- Where it sits. The left column at x 16 belongs to the quest tracker above and the health stack
-- below, so this takes the gutter to the RIGHT of the health panel when that gutter is wide enough
-- for it, and falls back to the old spot when it isn't (a narrow screen, where the hotbar reaches
-- across and PhoneLayout is drawing a different HUD anyway).
local GUTTER_X = UiKit.BottomRow.HealthRight + UiKit.BottomRow.Gap
local function gutterFits()
	local camera = workspace.CurrentCamera
	local width = camera and camera.ViewportSize.X or 1920
	-- The hotbar's left edge, from the shared number, less a gap.
	return (width - UiKit.BottomRow.HotbarInset) - GUTTER_X - UiKit.BottomRow.Gap >= WIDTH
end

local root = create("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 16, 1, -(UiKit.BottomRow.LeftStackTop + UiKit.BottomRow.Gap)),
	Size = UDim2.fromOffset(WIDTH, ROW * #ROWS + 30),
	BackgroundColor3 = Role.Base,
	BackgroundTransparency = 0.35,
	BorderSizePixel = 0,
	Parent = gui,
}, { UiKit.rounded(Radius.Card) })
create("UIStroke", { Color = Role.Line, Thickness = 1, Transparency = 0.5, Parent = root })

local title = create("TextLabel", {
	Position = UDim2.fromOffset(Space.MD, 6),
	Size = UDim2.fromOffset(WIDTH - Space.MD * 2, 18),
	BackgroundTransparency = 1,
	Font = Type.Label.Font,
	Text = "CONTROLS",
	TextColor3 = Role.TextMuted,
	TextSize = Type.Caption.Size,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = root,
})

local rows = {}
local function buildRows(entries, touch)
	for _, item in ipairs(rows) do
		item.key:Destroy()
		item.text:Destroy()
	end
	rows = {}
	for index, entry in ipairs(entries) do
		local y = 26 + (index - 1) * ROW
		local key = create("TextLabel", {
			Position = UDim2.fromOffset(Space.MD, y),
			Size = UDim2.fromOffset(62, ROW - 4),
			BackgroundColor3 = Role.SurfaceAlt,
			BackgroundTransparency = 0.25,
			Font = Type.Label.Font,
			Text = touch and entry[1] or Settings.KeyLabel(entry[1]),
			TextColor3 = Role.Text,
			TextSize = Type.Caption.Size,
			Parent = root,
		}, { UiKit.rounded(Radius.Control) })
		local text = create("TextLabel", {
			Position = UDim2.fromOffset(Space.MD + 70, y),
			Size = UDim2.fromOffset(WIDTH - Space.MD * 2 - 70, ROW - 4),
			BackgroundTransparency = 1,
			Font = Type.Body.Font,
			Text = entry[2],
			TextColor3 = Role.TextMuted,
			TextSize = Type.Caption.Size,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = root,
		})
		rows[#rows + 1] = { key = key, text = text }
	end
	root.Size = UDim2.fromOffset(WIDTH, ROW * #entries + 30)
end

-- The collapsed form: a pill that says how to get the legend back, so it is never gone for good.
local pill = create("TextButton", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 16, 1, -(UiKit.BottomRow.LeftStackTop + UiKit.BottomRow.Gap)),
	Size = UDim2.fromOffset(104, 28),
	BackgroundColor3 = Role.Base,
	BackgroundTransparency = 0.35,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Font = Type.Label.Font,
	Text = "? CONTROLS",
	TextColor3 = Role.TextMuted,
	TextSize = Type.Caption.Size,
	Visible = false,
	Parent = gui,
}, { UiKit.rounded(Radius.Pill) })
create("UIStroke", { Color = Role.Line, Thickness = 1, Transparency = 0.5, Parent = pill })

-- One rule, applied to both shapes, so the pill and the panel never sit in different places.
local function place()
	local gutter = gutterFits()
	local x = gutter and GUTTER_X or 16
	local y = gutter and UiKit.BottomRow.Gap or (UiKit.BottomRow.LeftStackTop + UiKit.BottomRow.Gap)
	root.Position = UDim2.new(0, x, 1, -y)
	pill.Position = UDim2.new(0, x, 1, -y)
end

local function setOpen(open)
	place()
	root.Visible = open
	pill.Visible = not open
end

local openToken = 0
local function openFor(seconds)
	setOpen(true)
	openToken += 1
	local mine = openToken
	task.delay(seconds, function()
		if openToken == mine then
			setOpen(false)
		end
	end)
end

pill.Activated:Connect(function()
	openToken += 1
	setOpen(true)
end)
root.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		openToken += 1
		setOpen(false)
	end
end)

-- THREE devices, not two. A console is neither touch nor keyboard, so `TouchEnabled and not
-- KeyboardEnabled` sent it down the keyboard branch and a pad player read a legend of keys their
-- machine does not have -- a list of controls you cannot reach, from the thing written to stop
-- controls being unreachable.
--
-- Labels come from Settings.GamepadLabel, which reads the buttons actually bound, so this cannot
-- claim a button that is not there. An action with no gamepad button (Zoom, Inspect) is DROPPED
-- rather than shown with a key that does nothing.
--
-- GetLastInputType can answer None before the player has touched anything, so a console player may
-- get the keyboard legend for the first moment; LastInputTypeChanged below corrects it on their
-- very first input. The legend is up for 12 seconds, so it corrects itself well inside its own life.
local function rebuild()
	local last = UserInputService:GetLastInputType()
	if string.find(last.Name, "Gamepad", 1, true) then
		local rows = {}
		for _, entry in ipairs(ROWS) do
			local label = Settings.GamepadLabel(entry[1])
			if label then
				rows[#rows + 1] = { label, entry[2] }
			end
		end
		buildRows(rows, true)
		return
	end
	local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	buildRows(touch and TOUCH_ROWS or ROWS, touch)
end

UserInputService.LastInputTypeChanged:Connect(rebuild)

rebuild()
place()
Settings.Changed:Connect(rebuild)
local camera = workspace.CurrentCamera
if camera then
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(place)
end
openFor(OPEN_FOR)

-- Every spawn is a chance that this is the player's first one.
player.CharacterAdded:Connect(function()
	rebuild()
	openFor(OPEN_FOR)
end)
