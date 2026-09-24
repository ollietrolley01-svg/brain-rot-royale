-- The stamina bar: a ModuleScript so HudClient can mount it and tools/stamina_gallery.lua can render
-- every state of it without a match running.
--
--   local bar = StaminaBar.new(screenGui)
--   bar:Update(dt, { value = 62, max = 100, exhausted = false, rush = false, hidden = false })
--
-- What it shows:
--   * the fill, and a pale "ghost" of what you just spent that hangs for a moment and then drains
--     away behind it, so a slide or a vault reads as a visible bite out of the bar;
--   * a sheen sweeping along the fill while it refills;
--   * low stamina turns the fill amber;
--   * EXHAUSTED: red, pulsing, with a tick at the line where sprinting comes back
--     (MovementConfig.Stamina.ExhaustedUntil);
--   * RUSH (a Speed Soda): gold with a moving shimmer, since nothing drains while it lasts;
--   * full and untouched for a couple of seconds, it dims but never disappears, so it's always
--     findable at a glance.
-- Sized in pixels for a 1080p screen. `StaminaBar.Layout(viewport)` / `bar:Place(viewport)` pick the scale and
-- the spot that clears the rest of the bottom HUD on any screen size.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MovementConfig"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local StaminaBar = {}
StaminaBar.__index = StaminaBar

-- Sized for a 1080p screen; bigger than the first cut, which read as a thin sliver at 1920 wide.
local WIDTH, TRACK_HEIGHT, HEIGHT = 360, 16, 50

local GREEN = Color3.fromRGB(104, 226, 134)
local GREEN_BRIGHT = Color3.fromRGB(176, 248, 170)
local AMBER = Color3.fromRGB(255, 190, 64)
local RED = Color3.fromRGB(255, 88, 64)
local RED_DARK = Color3.fromRGB(150, 40, 34)
local GOLD = Color3.fromRGB(255, 212, 84)
local GHOST = Color3.fromRGB(255, 240, 170)
local LOW = 0.3

-- The UIScale for a viewport: 1 at 1080 tall, never so small the bar stops being readable on a phone.
function StaminaBar.ScaleFor(viewport)
	return math.clamp(viewport.Y / 1080, 0.9, 1.25)
end

-- Where the rest of the bottom HUD sits, in raw unscaled pixels from the screen edges. These were this
-- file's own constants, read out of HudClient; they live in UiKit.BottomRow now (claude-ee's revamp owns
-- that row), so when the health panel or the hotbar moves, the bar follows with no edit here.
--   bottom-left   health panel 16..HealthRight across, 16..96 up; companion panel above it to 166 up;
--                 the SPEED BOOST pill to LeftStackTop; the ability icon 326..404 across, 94..172 up
--   bottom-right  the hotbar, HotbarInset in from the right edge and 16..166 up, its tab to 196 up
local ROW = UiKit.BottomRow
local HEALTH_RIGHT = ROW.HealthRight
local HOTBAR_INSET = ROW.HotbarInset
local LEFT_STACK_TOP = ROW.LeftStackTop
local GAP = ROW.Gap
-- The companion ability tile stands just left of the hotbar (CompanionAbilityIcon.Position: HotbarInset +
-- Gap in from the right edge, CompanionAbilityIcon.Size = 72 wide), so the row's right-hand obstacle is
-- the tile, not the hotbar: measured, the bar ran 14 px into it at 1920x1080 (#80). A literal rather than
-- a require, because that module pulls in the brainrot models.
local ABILITY_TILE = 72

-- AnchorPoint, Position and UIScale for the bar on a viewport. Bottom-centre when it fits between the
-- health panel and the hotbar (slid left of centre if it has to be, never touching either); on screens
-- too narrow for that (phones, small tablets) it sits above the bottom-left stack instead.
function StaminaBar.Layout(viewport)
	local preferred = StaminaBar.ScaleFor(viewport)
	-- The largest scale, down to 0.72, that fits between the two.
	local scale = preferred
	while scale >= 0.72 do
		local width = (WIDTH + 8) * scale
		local minCentre = HEALTH_RIGHT + GAP + width / 2
		local maxCentre = viewport.X - HOTBAR_INSET - GAP - ABILITY_TILE - GAP - width / 2
		if maxCentre >= minCentre then
			return Vector2.new(0.5, 1), UDim2.new(0, math.floor(math.clamp(viewport.X / 2, minCentre, maxCentre)), 1, -30), scale
		end
		scale -= 0.02
	end
	return Vector2.new(0, 1), UDim2.new(0, 16, 1, -(LEFT_STACK_TOP + 10)), preferred
end

-- On a touch screen PhoneLayout owns the HUD, and it has a slot for this bar: `Rects().stamina`, just
-- above the health readout. The rule above is the DESKTOP one, and on a phone it put the bar at 331 px
-- wide over the minimap and the buffs panel (844x390) and across the thumbstick's corner upright (#80,
-- measured by tools/hud_layout_check.py). Nil on a desktop screen, or if PhoneLayout is missing.
local function phoneSpots(viewport)
	local module = script.Parent:FindFirstChild("PhoneLayout")
	local ok, PhoneLayout = pcall(require, module)
	if ok and type(PhoneLayout) == "table" and PhoneLayout.Active(viewport) then
		return PhoneLayout.Rects(viewport)
	end
	return nil
end

function StaminaBar:Place(viewport)
	local spots = phoneSpots(viewport)
	if spots and spots.stamina then
		-- Hanging from the slot's top edge, as wide as the slot, and no taller than the slot plus the 4 px
		-- PhoneLayout leaves between it and the health row. Standing on the slot's bottom edge instead, it
		-- rose 5 px over the slot's top, which is the crosshair's clear line on an 844x390 phone (#80,
		-- tools/hud_layout_check.py: 2x3 px into the crosshair).
		local spot = spots.stamina
		self.Frame.AnchorPoint = Vector2.new(0, 0)
		self.Frame.Position = UDim2.fromOffset(spot.x, spot.y)
		self.scale.Scale = math.min(spot.w / (WIDTH + 8), (spot.h + 4) / HEIGHT)
		return
	end
	local anchor, position, scale = StaminaBar.Layout(viewport)
	self.Frame.AnchorPoint = anchor
	self.Frame.Position = position
	self.scale.Scale = scale
end

function StaminaBar.new(parent)
	local self = setmetatable({}, StaminaBar)

	local frame = create("CanvasGroup", {
		Name = "StaminaBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -30),
		Size = UDim2.fromOffset(WIDTH + 8, HEIGHT),
		BackgroundTransparency = 1,
		GroupTransparency = 0,
		Parent = parent,
	})
	self.Frame = frame
	self.scale = create("UIScale", { Parent = frame })

	-- A soft dark plate behind everything, so the bar reads over bright sky and snow alike.
	create("Frame", {
		Name = "Plate",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = frame,
	}, { rounded(10) })

	self.title = create("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(11, 5),
		Size = UDim2.fromOffset(140, 17),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "STAMINA",
		TextColor3 = C.Muted,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	self.number = create("TextLabel", {
		Name = "Number",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -11, 0, 3),
		Size = UDim2.fromOffset(140, 21),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "100",
		TextColor3 = C.Text,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})

	-- EXHAUSTED / RUSH, centred over the track.
	self.status = create("TextLabel", {
		Name = "Status",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 3),
		Size = UDim2.fromOffset(180, 21),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "",
		TextColor3 = RED,
		TextSize = 19,
		Visible = false,
		Parent = frame,
	})

	local track = create("Frame", {
		Name = "Track",
		Position = UDim2.fromOffset(4, 28),
		Size = UDim2.fromOffset(WIDTH, TRACK_HEIGHT),
		BackgroundColor3 = Color3.fromRGB(12, 13, 18),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = frame,
	}, { rounded(TRACK_HEIGHT // 2) })
	self.track = track
	self.stroke = create("UIStroke", {
		Color = Color3.fromRGB(70, 74, 92),
		Thickness = 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = track,
	})

	self.ghost = create("Frame", {
		Name = "Ghost",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = GHOST,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Parent = track,
	}, { rounded(TRACK_HEIGHT // 2) })

	self.fill = create("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = GREEN,
		BorderSizePixel = 0,
		Parent = track,
	}, { rounded(TRACK_HEIGHT // 2) })
	-- A lighter top half, so the fill reads as a lit tube rather than a flat stripe.
	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.45, Color3.fromRGB(235, 235, 235)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 170, 170)),
		}),
		Parent = self.fill,
	})

	-- The sheen: a bright band that sweeps along the fill while it refills (or all the time on RUSH).
	self.sheen = create("Frame", {
		Name = "Sheen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Visible = false,
		Parent = self.fill,
	})
	self.sheenGradient = create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 1),
			NumberSequenceKeypoint.new(0.5, 0.45),
			NumberSequenceKeypoint.new(0.6, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1, 0),
		Parent = self.sheen,
	})

	-- Where sprinting comes back after exhaustion.
	local restart = MovementConfig.Stamina.ExhaustedUntil / MovementConfig.Stamina.Max
	self.tick = create("Frame", {
		Name = "RestartTick",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0, 4 + WIDTH * restart, 0, 25),
		Size = UDim2.fromOffset(2, TRACK_HEIGHT + 6),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
		Parent = frame,
	})

	self.shown = 1
	self.ghostValue = 1
	self.ghostHold = 0
	self.lastTarget = 1
	self.idle = 0
	self.clock = 0
	self.rising = 0
	return self
end

function StaminaBar:SetScale(scale)
	self.scale.Scale = scale
end

-- Jump straight to a state with no easing (the gallery uses this).
function StaminaBar:Snap(state, ghost)
	local target = math.clamp((state.value or 0) / (state.max or MovementConfig.Stamina.Max), 0, 1)
	self.shown, self.lastTarget = target, target
	self.ghostValue = math.max(target, ghost or target)
	self.ghostHold = ghost and 1 or 0
	self.idle = state.idleFor or 0
	self.rising = state.rising and 1 or 0
	self:Update(0, state)
end

function StaminaBar:Update(dt, state)
	local frame = self.Frame
	if state.hidden then
		frame.Visible = false
		return
	end
	frame.Visible = true
	self.clock += dt

	local target = math.clamp((state.value or 0) / (state.max or MovementConfig.Stamina.Max), 0, 1)
	local blend = math.clamp(dt * 16, 0, 1)
	self.shown += (target - self.shown) * blend

	-- The ghost holds the level from before a drop, then drains toward the fill.
	if target < self.lastTarget - 0.004 then
		if self.ghostValue < self.lastTarget then
			self.ghostValue = self.lastTarget
		end
		-- A big bite (slide, vault, climb) hangs longer than the steady trickle of a sprint.
		self.ghostHold = (self.lastTarget - target) > 0.05 and 0.45 or math.max(self.ghostHold, 0.15)
	end
	if target > self.lastTarget + 0.0005 then
		self.rising = 0.25
	else
		self.rising = math.max(self.rising - dt, 0)
	end
	self.lastTarget = target
	if self.ghostHold > 0 then
		self.ghostHold -= dt
	else
		self.ghostValue = math.max(self.ghostValue - dt * 0.55, self.shown)
	end
	if self.ghostValue < self.shown then
		self.ghostValue = self.shown
	end

	self.fill.Size = UDim2.fromScale(self.shown, 1)
	self.ghost.Size = UDim2.fromScale(self.ghostValue, 1)
	self.ghost.Visible = self.ghostValue > self.shown + 0.002

	-- Colour and status.
	local color, statusText, statusColor = GREEN, nil, nil
	local pulse = (math.sin(self.clock * 9) + 1) / 2
	if state.rush then
		color = GOLD
		statusText, statusColor = "RUSH", GOLD
	elseif state.exhausted then
		color = RED:Lerp(RED_DARK, pulse * 0.6)
		statusText, statusColor = "EXHAUSTED", RED:Lerp(Color3.new(1, 1, 1), pulse * 0.35)
	elseif self.shown < LOW then
		color = AMBER
	elseif state.draining then
		color = GREEN_BRIGHT
	end
	-- A slide or vault refused for want of stamina: two quick red-white blinks of the border.
	local refused = state.refusedAt and (os.clock() - state.refusedAt) or math.huge
	local flashing = refused >= 0 and refused < 0.45
	self.fill.BackgroundColor3 = color
	if flashing then
		local blink = math.floor(refused / 0.11) % 2 == 0
		self.stroke.Color = blink and Color3.new(1, 1, 1) or RED
		self.stroke.Thickness = 2.5
	else
		self.stroke.Color = state.exhausted and RED:Lerp(RED_DARK, pulse) or (state.rush and GOLD or Color3.fromRGB(70, 74, 92))
		self.stroke.Thickness = (state.exhausted or state.rush) and 2 or 1.5
	end

	self.status.Visible = statusText ~= nil
	if statusText then
		self.status.Text = statusText
		self.status.TextColor3 = statusColor
	end
	self.title.Visible = statusText == nil
	self.number.Text = state.rush and "" or tostring(math.floor((state.value or 0) + 0.5))
	self.tick.Visible = state.exhausted == true

	-- The sheen runs while refilling, and constantly on RUSH.
	local sweeping = state.rush or (self.rising > 0 and self.shown < 0.995)
	self.sheen.Visible = sweeping
	if sweeping then
		local period = state.rush and 0.9 or 1.3
		local phase = (self.clock % period) / period
		self.sheenGradient.Offset = Vector2.new(-1 + phase * 2, 0)
	end

	-- Dim when full and untouched for a while; never fully hidden during a match.
	local active = state.exhausted or state.rush or state.draining or target < 0.995 or flashing
	if active then
		self.idle = 0
	else
		self.idle += dt
	end
	local wanted = self.idle > 2 and 0.55 or 0
	if dt <= 0 then
		frame.GroupTransparency = wanted
	else
		frame.GroupTransparency += (wanted - frame.GroupTransparency) * math.clamp(dt * 6, 0, 1)
	end
end

return StaminaBar
