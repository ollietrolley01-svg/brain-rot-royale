-- The match event announcement: a ModuleScript so HudClient can mount it and tools/hud_ux_gallery.lua
-- can render every event in every phase without a match running.
--
--   local banner = EventBanner.new(screenGui, { onAnnounce = function() Sfx.Play(...) end })
--   banner:SetViewport(camera.ViewportSize)
--   banner:SetDock("slot")                   -- "slot": beside the top banner, where the READY pill sits
--                                            -- in the lobby; "below": under that pill, while it shows
--   banner:Announce(event)                   -- { id, name, description, color } from MatchEvents.Describe
--   banner:SetTimer("drop", 12)              -- "drop" (seconds to the drop), "building", "live" (seconds
--                                            -- since it started, or nil if not known)
--   banner:Clear()                           -- no event: everything away
--
-- What it does: the event lands as a big card under the compass (icon, name, one line on what it does,
-- and a timer), holds for HOLD seconds, then shrinks into a compact pill beside the top banner that
-- stays for the match. The card sits well above the crosshair and never stays up long. Tapping or
-- clicking the pill brings the card back for another few seconds, so nothing about the event is ever
-- more than a tap away. The icons are drawn from frames, so there are no image assets to load.
--
-- Sized in pixels for a 1080p screen; SetViewport scales it for others.

local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local EventBanner = {}
EventBanner.__index = EventBanner

EventBanner.CardSize = Vector2.new(880, 160)
EventBanner.PillSize = Vector2.new(236, 56)
EventBanner.Hold = 3.2

local CARD_W, CARD_H = EventBanner.CardSize.X, EventBanner.CardSize.Y
local PILL_W, PILL_H = EventBanner.PillSize.X, EventBanner.PillSize.Y
local ICON_BADGE = 116
local TIMER_W = 132
local TEXT_X = 30 + ICON_BADGE + 26
local TEXT_W = CARD_W - TEXT_X - TIMER_W - 44

-- The top banner (HudClient) is 56 tall at y 10; the READY pill beside it is 230x60 at (centre + 232, 8).
local SLOT_X, SLOT_Y = 232, 10
local BELOW_Y = 8 + 60 + 8
local ZINDEX = 30

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

--------------------------------------------------------------------------------
-- Icons, drawn from frames in a square. Positions and sizes are fractions of the square.
--------------------------------------------------------------------------------

local Icon = {}

local function shape(parent, x, y, w, h, color, props)
	props = props or {}
	local frame = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(w, h),
		BackgroundColor3 = color,
		BackgroundTransparency = props.transparency or 0,
		BorderSizePixel = 0,
		Rotation = props.rotation or 0,
		ZIndex = props.z or ZINDEX + 3,
		Parent = parent,
	})
	if props.round then
		create("UICorner", { CornerRadius = UDim.new(props.round, 0), Parent = frame })
	end
	return frame
end

local function circle(parent, x, y, d, color, props)
	props = props or {}
	props.round = 0.5
	return shape(parent, x, y, d, d, color, props)
end

-- An outline only: a transparent circle (or rounded box) with a stroke `t` of the square thick.
local function ring(parent, x, y, w, h, t, color, px, props)
	props = props or {}
	local frame = shape(parent, x, y, w, h, color, { transparency = 1, round = 0.5, rotation = props.rotation, z = props.z })
	create("UIStroke", { Color = color, Thickness = math.max(1, t * px), Transparency = props.transparency or 0, Parent = frame })
	return frame
end

local function diamond(parent, x, y, s, color, props)
	props = props or {}
	props.rotation = 45
	return shape(parent, x, y, s, s, color, props)
end

-- A bar from (x1, y1) to (x2, y2), `t` thick.
local function line(parent, x1, y1, x2, y2, t, color, props)
	props = props or {}
	local dx, dy = x2 - x1, y2 - y1
	props.rotation = math.deg(math.atan2(dy, dx))
	props.round = props.round or 0.5
	return shape(parent, (x1 + x2) / 2, (y1 + y2) / 2, math.sqrt(dx * dx + dy * dy) + t, t, color, props)
end

-- A chevron whose point is at (x, y), pointing along `degrees` (0 right, 90 down), arms `len` long.
local function chevron(parent, x, y, degrees, len, t, color, props)
	for _, spread in ipairs({ 135, -135 }) do
		local a = math.rad(degrees + spread)
		line(parent, x, y, x + math.cos(a) * len, y + math.sin(a) * len, t, color, props)
	end
end

Icon.LootFrenzy = function(box, color, light, dark, px)
	shape(box, 0.5, 0.66, 0.66, 0.34, color, { round = 0.12 })
	shape(box, 0.5, 0.66, 0.66, 0.07, dark)
	shape(box, 0.5, 0.43, 0.74, 0.2, light, { round = 0.3 })
	shape(box, 0.5, 0.53, 0.14, 0.17, WHITE, { round = 0.25, z = ZINDEX + 4 })
	shape(box, 0.5, 0.55, 0.05, 0.07, dark, { z = ZINDEX + 5 })
	diamond(box, 0.2, 0.18, 0.11, WHITE)
	diamond(box, 0.5, 0.12, 0.15, WHITE)
	diamond(box, 0.8, 0.18, 0.11, WHITE)
end

Icon.BountyRush = function(box, color, light, dark, px)
	ring(box, 0.5, 0.5, 0.8, 0.8, 0.075, light, px)
	ring(box, 0.5, 0.5, 0.44, 0.44, 0.075, light, px)
	for _, tick in ipairs({ { 0.5, 0.06, 0.07, 0.22 }, { 0.5, 0.94, 0.07, 0.22 }, { 0.06, 0.5, 0.22, 0.07 }, { 0.94, 0.5, 0.22, 0.07 } }) do
		shape(box, tick[1], tick[2], tick[3], tick[4], WHITE, { round = 0.5 })
	end
	circle(box, 0.5, 0.5, 0.16, WHITE, { z = ZINDEX + 4 })
end

Icon.RotRush = function(box, color, light, dark, px)
	for index, y in ipairs({ 0.3, 0.5, 0.7 }) do
		local length = index == 2 and 0.2 or 0.13
		line(box, 0.08 + (0.2 - length), y, 0.08 + 0.2, y, 0.065, light, { transparency = 0.15 })
	end
	chevron(box, 0.62, 0.5, 0, 0.26, 0.12, light)
	chevron(box, 0.88, 0.5, 0, 0.26, 0.12, WHITE)
end

Icon.ShieldUp = function(box, color, light, dark, px)
	shape(box, 0.5, 0.36, 0.64, 0.42, light, { round = 0.2 })
	diamond(box, 0.5, 0.57, 0.45, light)
	shape(box, 0.5, 0.36, 0.44, 0.28, color, { round = 0.2, z = ZINDEX + 4 })
	diamond(box, 0.5, 0.55, 0.3, color, { z = ZINDEX + 4 })
	shape(box, 0.5, 0.49, 0.08, 0.3, WHITE, { round = 0.5, z = ZINDEX + 5 })
	shape(box, 0.5, 0.49, 0.3, 0.08, WHITE, { round = 0.5, z = ZINDEX + 5 })
end

Icon.HighStakes = function(box, color, light, dark, px)
	for index, y in ipairs({ 0.78, 0.64, 0.5 }) do
		local z = ZINDEX + 2 + index * 2
		shape(box, 0.36, y + 0.05, 0.52, 0.2, dark, { round = 0.5, z = z })
		shape(box, 0.36, y, 0.52, 0.2, index == 3 and light or color, { round = 0.5, z = z + 1 })
	end
	create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.76, 0.28),
		Size = UDim2.fromScale(0.52, 0.34),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "1.5x",
		TextColor3 = WHITE,
		TextScaled = true,
		ZIndex = ZINDEX + 10,
		Parent = box,
	})
end

Icon.NightOps = function(box, color, light, dark, px, backdrop)
	circle(box, 0.44, 0.54, 0.66, light)
	circle(box, 0.62, 0.4, 0.56, backdrop, { z = ZINDEX + 4 })
	diamond(box, 0.8, 0.74, 0.11, WHITE, { z = ZINDEX + 5 })
	diamond(box, 0.72, 0.18, 0.08, WHITE, { z = ZINDEX + 5 })
	diamond(box, 0.9, 0.44, 0.06, WHITE, { z = ZINDEX + 5 })
end

Icon.LowGravity = function(box, color, light, dark, px)
	-- A ball floating high over the ground, its shadow far below, rising.
	shape(box, 0.5, 0.93, 0.78, 0.06, WHITE, { round = 0.5, transparency = 0.2 })
	shape(box, 0.5, 0.86, 0.3, 0.07, dark, { round = 0.5, transparency = 0.1 })
	for index, y in ipairs({ 0.66, 0.74 }) do
		shape(box, 0.5, y, 0.05 + index * 0.06, 0.045, WHITE, { round = 0.5, transparency = 0.25 + index * 0.2 })
	end
	circle(box, 0.5, 0.42, 0.4, light)
	circle(box, 0.43, 0.35, 0.1, WHITE, { transparency = 0.35, z = ZINDEX + 4 })
	chevron(box, 0.5, 0.02, -90, 0.15, 0.07, WHITE)
end

Icon.ZoneRush = function(box, color, light, dark, px)
	ring(box, 0.5, 0.5, 0.9, 0.9, 0.05, light, px, { transparency = 0.35 })
	circle(box, 0.5, 0.5, 0.3, light)
	circle(box, 0.5, 0.5, 0.14, WHITE, { z = ZINDEX + 4 })
	for _, degrees in ipairs({ 90, 180, 270, 0 }) do
		local a = math.rad(degrees + 180)
		chevron(box, 0.5 + math.cos(a) * 0.25, 0.5 + math.sin(a) * 0.25, degrees, 0.12, 0.07, WHITE)
	end
end

Icon.HotDrops = function(box, color, light, dark, px)
	local dome = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.06),
		Size = UDim2.fromScale(0.86, 0.3),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = ZINDEX + 3,
		Parent = box,
	})
	local canopy = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(1, 0.86 / 0.3),
		BackgroundColor3 = light,
		BorderSizePixel = 0,
		ZIndex = ZINDEX + 3,
		Parent = dome,
	})
	create("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = canopy })
	for _, x in ipairs({ 0.36, 0.64 }) do
		shape(dome, x, 0.5, 0.05, 1.2, dark, { z = ZINDEX + 4, transparency = 0.3 })
	end
	line(box, 0.1, 0.36, 0.4, 0.66, 0.04, WHITE)
	line(box, 0.9, 0.36, 0.6, 0.66, 0.04, WHITE)
	line(box, 0.5, 0.36, 0.5, 0.66, 0.04, WHITE)
	shape(box, 0.5, 0.79, 0.34, 0.28, color, { round = 0.12, z = ZINDEX + 5 })
	shape(box, 0.5, 0.79, 0.34, 0.06, dark, { z = ZINDEX + 6 })
	shape(box, 0.5, 0.79, 0.06, 0.28, dark, { z = ZINDEX + 6 })
end

Icon.Headhunter = function(box, color, light, dark, px)
	ring(box, 0.5, 0.5, 0.9, 0.9, 0.045, WHITE, px, { transparency = 0.35 })
	circle(box, 0.5, 0.44, 0.5, light)
	shape(box, 0.5, 0.66, 0.3, 0.18, light, { round = 0.3 })
	circle(box, 0.4, 0.46, 0.12, dark, { z = ZINDEX + 4 })
	circle(box, 0.6, 0.46, 0.12, dark, { z = ZINDEX + 4 })
	for _, tick in ipairs({ { 0.5, 0.04, 0.05, 0.16 }, { 0.5, 0.96, 0.05, 0.16 }, { 0.04, 0.5, 0.16, 0.05 }, { 0.96, 0.5, 0.16, 0.05 } }) do
		shape(box, tick[1], tick[2], tick[3], tick[4], WHITE, { round = 0.5, z = ZINDEX + 5 })
	end
	circle(box, 0.5, 0.44, 0.08, Color3.fromRGB(255, 70, 70), { z = ZINDEX + 6 })
end

Icon.AuraFarm = function(box, color, light, dark, px)
	shape(box, 0.5, 0.38, 0.64, 0.16, light, { round = 0.2 })
	diamond(box, 0.5, 0.52, 0.5, color)
	shape(box, 0.5, 0.35, 0.64, 0.12, light, { z = ZINDEX + 4 })
	diamond(box, 0.42, 0.5, 0.14, WHITE, { transparency = 0.35, z = ZINDEX + 5 })
	diamond(box, 0.16, 0.18, 0.13, WHITE)
	diamond(box, 0.84, 0.24, 0.1, WHITE)
	diamond(box, 0.82, 0.84, 0.08, WHITE)
end

local function fallbackIcon(box)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "!",
		TextColor3 = WHITE,
		TextScaled = true,
		ZIndex = ZINDEX + 4,
		Parent = box,
	})
end

-- The icon for an event id, drawn into a round badge `px` pixels across. Returns the badge.
function EventBanner.Badge(parent, eventId, color, px)
	color = color or C.Accent
	local light = color:Lerp(WHITE, 0.3)
	local dark = color:Lerp(BLACK, 0.55)
	local backdrop = color:Lerp(BLACK, 0.72)
	local badge = create("Frame", {
		Name = "Badge",
		Size = UDim2.fromOffset(px, px),
		BackgroundColor3 = backdrop,
		BorderSizePixel = 0,
		ZIndex = ZINDEX + 1,
		Parent = parent,
	}, { rounded(px / 2) })
	create("UIStroke", { Color = color, Thickness = math.max(1.5, px * 0.035), Parent = badge })
	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(WHITE, Color3.fromRGB(170, 170, 170)),
		Parent = badge,
	})
	local box = create("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		BackgroundTransparency = 1,
		ZIndex = ZINDEX + 2,
		Parent = badge,
	})
	local draw = Icon[eventId]
	if draw then
		draw(box, color, light, dark, px * 0.62, backdrop)
	else
		fallbackIcon(box)
	end
	return badge
end

EventBanner.IconIds = {}
for id in pairs(Icon) do
	table.insert(EventBanner.IconIds, id)
end
table.sort(EventBanner.IconIds)

--------------------------------------------------------------------------------
-- The card and the pill
--------------------------------------------------------------------------------

local function formatClock(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- How big the card is drawn on a viewport: full size at 1080 tall, never wider than the screen, and
-- never so small a phone can't read it.
function EventBanner.CardScaleFor(viewport)
	local scale = math.clamp(viewport.Y / 1080 * 1.12, 0.62, 1)
	scale = math.min(scale, (viewport.X - 32) / CARD_W)
	local phone = EventBanner.PhoneSpot(viewport)
	if phone then
		-- Whatever else, the card's bottom edge stays above the crosshair on a short screen.
		scale = math.min(scale, (viewport.Y / 2 - 14 - phone.eventPill.y) / CARD_H)
	end
	return scale
end

-- The pill keeps the top banner's own pixel size, shrinking only to fit a narrow screen.
function EventBanner.PillScaleFor(viewport)
	local phone = EventBanner.PhoneSpot(viewport)
	if phone then
		return phone.eventPill.w / PILL_W
	end
	local room = viewport.X - 8 - (viewport.X / 2 + SLOT_X)
	return math.clamp(room / PILL_W, 0.6, 1)
end

-- On a touch screen the whole HUD is laid out by PhoneLayout, and the pill has a slot of its own at the
-- top right, under the menu icons. Returns its rects, or nil on a desktop screen (and if that module
-- ever fails to load, which leaves the banner exactly where it was).
local phoneModule = nil
function EventBanner.PhoneSpot(viewport)
	if phoneModule == nil then
		local ok, module = pcall(function()
			return require(script.Parent:WaitForChild("PhoneLayout", 5))
		end)
		phoneModule = ok and module or false
	end
	if not phoneModule or not viewport or not phoneModule.Active(viewport) then
		return nil
	end
	return phoneModule.Rects(viewport)
end

-- Where the card's top edge goes: under the compass, or higher on a short screen so it stays clear
-- of the crosshair. On a phone it starts where the pill it docks into sits.
function EventBanner.CardTopFor(viewport)
	local phone = EventBanner.PhoneSpot(viewport)
	if phone then
		return phone.eventPill.y
	end
	return viewport.Y < 600 and 70 or 136
end

function EventBanner.new(parent, options)
	options = options or {}
	local self = setmetatable({}, EventBanner)
	self.options = options
	self.viewport = Vector2.new(1920, 1080)
	self.dock = "slot"
	self.token = 0
	self.phase = "hidden"

	-- The card.
	local card = create("CanvasGroup", {
		Name = "EventCard",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 136),
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = ZINDEX,
		Parent = parent,
	})
	self.card = card
	self.cardScale = create("UIScale", { Parent = card })

	-- Inset by the stroke's width: a CanvasGroup clips at its own edges, and a stroke drawn outside the
	-- plate would lose its rounded corners there.
	local plate = create("Frame", {
		Name = "Plate",
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -8),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.06,
		BorderSizePixel = 0,
		ZIndex = ZINDEX,
		Parent = card,
	}, { rounded(20) })
	self.cardStroke = create("UIStroke", { Thickness = 3, Transparency = 0.05, Parent = plate })

	-- The event's colour washing in from the left, behind the badge.
	self.wash = create("Frame", {
		Name = "Wash",
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -8),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		ZIndex = ZINDEX,
		Parent = card,
	}, { rounded(20) })
	create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(0.32, 0.8),
			NumberSequenceKeypoint.new(0.7, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = self.wash,
	})

	-- A glint that sweeps across the card as it lands.
	self.glint = create("Frame", {
		Name = "Glint",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, -120, 0.5, 0),
		Size = UDim2.fromOffset(70, CARD_H * 2.2),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Rotation = 18,
		ZIndex = ZINDEX + 9,
		Parent = card,
	})
	create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = self.glint,
	})

	self.badgeHolder = create("Frame", {
		Name = "BadgeHolder",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 30, 0.5, 0),
		Size = UDim2.fromOffset(ICON_BADGE, ICON_BADGE),
		BackgroundTransparency = 1,
		ZIndex = ZINDEX + 1,
		Parent = card,
	})
	self.badgeScale = create("UIScale", { Parent = self.badgeHolder })
	-- A soft halo behind the badge.
	self.halo = create("Frame", {
		Name = "Halo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.36, 1.36),
		BackgroundColor3 = C.Accent,
		BackgroundTransparency = 0.78,
		BorderSizePixel = 0,
		ZIndex = ZINDEX,
		Parent = self.badgeHolder,
	}, { rounded(ICON_BADGE) })

	self.kicker = create("TextLabel", {
		Name = "Kicker",
		Position = UDim2.fromOffset(TEXT_X, 18),
		Size = UDim2.fromOffset(128, 24),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBlack,
		Text = "MATCH EVENT",
		TextColor3 = C.Background,
		TextSize = 13,
		ZIndex = ZINDEX + 2,
		Parent = card,
	}, { rounded(12) })

	self.title = create("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(TEXT_X, 42),
		Size = UDim2.fromOffset(TEXT_W, 58),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "",
		TextColor3 = WHITE,
		TextSize = 54,
		TextStrokeTransparency = 0.35,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = ZINDEX + 2,
		Parent = card,
	})

	self.description = create("TextLabel", {
		Name = "Description",
		Position = UDim2.fromOffset(TEXT_X, 102),
		Size = UDim2.fromOffset(TEXT_W, 44),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = C.Text,
		TextSize = 20,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = ZINDEX + 2,
		Parent = card,
	})

	local timer = create("Frame", {
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -26, 0.5, 0),
		Size = UDim2.fromOffset(TIMER_W, 98),
		BackgroundColor3 = C.PanelAlt,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ZIndex = ZINDEX + 1,
		Parent = card,
	}, { rounded(14) })
	self.timerStroke = create("UIStroke", { Thickness = 1.5, Transparency = 0.55, Parent = timer })
	self.timerLabel = create("TextLabel", {
		Name = "Label",
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "ALL MATCH",
		TextColor3 = C.Muted,
		TextSize = 13,
		ZIndex = ZINDEX + 2,
		Parent = timer,
	})
	self.timerValue = create("TextLabel", {
		Name = "Value",
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "LIVE",
		TextColor3 = C.Accent,
		TextSize = 40,
		ZIndex = ZINDEX + 2,
		Parent = timer,
	})

	-- The pill.
	local pill = create("CanvasGroup", {
		Name = "EventPill",
		Position = UDim2.new(0.5, SLOT_X, 0, SLOT_Y),
		Size = UDim2.fromOffset(PILL_W, PILL_H),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = ZINDEX,
		Parent = parent,
	})
	self.pill = pill
	self.pillScale = create("UIScale", { Parent = pill })
	local pillPlate = create("Frame", {
		Name = "Plate",
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ZIndex = ZINDEX,
		Parent = pill,
	}, { rounded(14) })
	self.pillStroke = create("UIStroke", { Thickness = 2, Transparency = 0.25, Parent = pillPlate })
	self.pillWash = create("Frame", {
		Name = "Wash",
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		ZIndex = ZINDEX,
		Parent = pill,
	}, {
		rounded(14),
		create("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.6),
				NumberSequenceKeypoint.new(0.45, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})
	self.pillBadgeHolder = create("Frame", {
		Name = "BadgeHolder",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 1,
		ZIndex = ZINDEX + 1,
		Parent = pill,
	})
	self.pillTitle = create("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(56, 7),
		Size = UDim2.fromOffset(PILL_W - 56 - 26, 24),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "",
		TextColor3 = C.Accent,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = ZINDEX + 2,
		Parent = pill,
	})
	self.pillSub = create("TextLabel", {
		Name = "Sub",
		Position = UDim2.fromOffset(56, 31),
		Size = UDim2.fromOffset(PILL_W - 56 - 26, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = C.Muted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = ZINDEX + 2,
		Parent = pill,
	})
	-- "i": the pill opens the card again.
	local info = create("TextLabel", {
		Name = "Info",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -9, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBlack,
		Text = "i",
		TextColor3 = C.Muted,
		TextSize = 11,
		ZIndex = ZINDEX + 2,
		Parent = pill,
	}, { rounded(8) })
	self.pillInfo = info
	-- The click target sits over the whole pill (a CanvasGroup can't be a button itself).
	self.pillButton = create("TextButton", {
		Name = "Button",
		Position = UDim2.new(0.5, SLOT_X, 0, SLOT_Y),
		Size = UDim2.fromOffset(PILL_W, PILL_H),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		ZIndex = ZINDEX + 12,
		Parent = parent,
	})
	self.pillButtonScale = create("UIScale", { Parent = self.pillButton })
	self.pillButton.Activated:Connect(function()
		if self.event then
			self:Expand()
		end
	end)
	self.pillButton.MouseEnter:Connect(function()
		self.pillStroke.Transparency = 0
		info.TextColor3 = C.Text
	end)
	self.pillButton.MouseLeave:Connect(function()
		self.pillStroke.Transparency = 0.25
		info.TextColor3 = C.Muted
	end)

	self:SetViewport(self.viewport)
	return self
end

function EventBanner:_pillOrigin()
	local scale = EventBanner.PillScaleFor(self.viewport)
	local phone = EventBanner.PhoneSpot(self.viewport)
	if phone then
		-- Its own slot, and the one under the READY pill while that is out (the lobby).
		local spot = self.dock == "below" and phone.eventPillBelow or phone.eventPill
		return spot.x, spot.y, scale
	end
	local x = math.min(self.viewport.X / 2 + SLOT_X, self.viewport.X - 8 - PILL_W * scale)
	local y = self.dock == "below" and BELOW_Y or SLOT_Y
	return x, y, scale
end

function EventBanner:_layout()
	local x, y, scale = self:_pillOrigin()
	self.pill.Position = UDim2.fromOffset(x, y)
	self.pillScale.Scale = scale
	self.pillButton.Position = UDim2.fromOffset(x, y)
	self.pillButtonScale.Scale = scale
	if self.phase ~= "docking" then
		self.card.Position = UDim2.new(0.5, 0, 0, EventBanner.CardTopFor(self.viewport))
		self.cardScale.Scale = EventBanner.CardScaleFor(self.viewport)
	end
end

function EventBanner:SetViewport(viewport)
	self.viewport = viewport
	self:_layout()
end

function EventBanner:SetDock(dock)
	if dock ~= self.dock then
		self.dock = dock
		self:_layout()
	end
end

-- Fills the card and the pill in for an event, without showing either.
function EventBanner:_fill(event)
	local color = event.color or C.Accent
	local bright = color:Lerp(WHITE, 0.18)
	self.cardStroke.Color = color
	self.wash.BackgroundColor3 = color
	self.halo.BackgroundColor3 = color
	self.kicker.BackgroundColor3 = color
	self.title.Text = string.upper(event.name or "")
	self.title.TextStrokeColor3 = color:Lerp(BLACK, 0.6)
	self.timerStroke.Color = color
	self.timerValue.TextColor3 = bright
	self.pillStroke.Color = color
	self.pillWash.BackgroundColor3 = color
	self.pillTitle.Text = string.upper(event.name or "")
	self.pillTitle.TextColor3 = bright

	-- One line when it fits, otherwise two a little smaller.
	local description = event.description or ""
	local width = TextService:GetTextSize(description, 20, Enum.Font.GothamBold, Vector2.new(10000, 100)).X
	if width <= TEXT_W then
		self.description.TextSize = 20
		self.description.Position = UDim2.fromOffset(TEXT_X, 106)
	else
		self.description.TextSize = 18
		self.description.Position = UDim2.fromOffset(TEXT_X, 102)
	end
	self.description.Text = description

	for _, holder in ipairs({ self.badgeHolder, self.pillBadgeHolder }) do
		local old = holder:FindFirstChild("Badge")
		if old then
			old:Destroy()
		end
	end
	local big = EventBanner.Badge(self.badgeHolder, event.id, color, ICON_BADGE)
	big.ZIndex = ZINDEX + 1
	EventBanner.Badge(self.pillBadgeHolder, event.id, color, 40)
end

-- The timer on both the card and the pill.
function EventBanner:SetTimer(kind, seconds)
	local label, value, sub
	if kind == "drop" then
		label, value = "DROP IN", formatClock(seconds)
		sub = "starts in " .. formatClock(seconds)
	elseif kind == "building" then
		label, value = "THIS MATCH", "SOON"
		sub = "this match  •  starting soon"
	elseif seconds then
		label, value = "LIVE FOR", formatClock(seconds)
		sub = "all match  •  live " .. formatClock(seconds)
	else
		label, value = "ALL MATCH", "LIVE"
		sub = "all match  •  live now"
	end
	self.timerLabel.Text = label
	self.timerValue.Text = value
	self.pillSub.Text = string.upper(sub)
end

local function tween(instance, seconds, goal, style, direction)
	local t = TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

-- The card lands: pops in, glints, holds, then docks into the pill.
function EventBanner:_showCard(hold, flourish)
	self.token += 1
	local token = self.token
	self.phase = "card"
	self:_layout()
	local scale = EventBanner.CardScaleFor(self.viewport)
	local card = self.card
	card.Visible = true
	card.GroupTransparency = 1
	self.cardScale.Scale = scale * (flourish and 0.72 or 0.92)
	tween(card, 0.22, { GroupTransparency = 0 })
	tween(self.cardScale, flourish and 0.5 or 0.25, { Scale = scale }, Enum.EasingStyle.Back)
	self.badgeScale.Scale = flourish and 0.4 or 1
	if flourish then
		task.delay(0.12, function()
			if token == self.token then
				tween(self.badgeScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end)
	end
	self.glint.Position = UDim2.new(0, -120, 0.5, 0)
	task.delay(flourish and 0.35 or 0.1, function()
		if token == self.token then
			tween(self.glint, 0.75, { Position = UDim2.new(0, CARD_W + 120, 0.5, 0) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		end
	end)
	task.delay(hold, function()
		if token == self.token then
			self:Dock()
		end
	end)
end

-- A new event: the full entrance, then the pill.
function EventBanner:Announce(event)
	if not event then
		self:Clear()
		return
	end
	self.event = event
	self:_fill(event)
	self.pill.Visible = false
	self.pillButton.Visible = false
	self:_showCard(EventBanner.Hold, true)
	if self.options.onAnnounce then
		task.spawn(self.options.onAnnounce, event)
	end
end

-- The pill was tapped: the card again, briefly.
function EventBanner:Expand()
	if not self.event or self.phase == "card" then
		return
	end
	self.pill.Visible = false
	self.pillButton.Visible = false
	self:_showCard(EventBanner.Hold * 0.8, false)
end

-- Straight to the pill (the card shrinks away into it). Safe to call at any time.
function EventBanner:Dock()
	if not self.event then
		return
	end
	if self.phase == "pill" or self.phase == "docking" then
		return
	end
	self.token += 1
	local token = self.token
	self.phase = "docking"
	local x, y, scale = self:_pillOrigin()
	-- The card's top centre flies to the pill's top centre while shrinking to the pill's width.
	local target = UDim2.fromOffset(x + PILL_W * scale / 2, y)
	tween(self.card, 0.42, { Position = target, GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(self.cardScale, 0.42, { Scale = PILL_W * scale / CARD_W }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.26, function()
		if token ~= self.token then
			return
		end
		self.pill.Visible = true
		self.pillButton.Visible = true
		self.pill.GroupTransparency = 1
		self.pillScale.Scale = scale * 1.12
		tween(self.pill, 0.2, { GroupTransparency = 0 })
		tween(self.pillScale, 0.35, { Scale = scale }, Enum.EasingStyle.Back)
	end)
	task.delay(0.45, function()
		if token ~= self.token then
			return
		end
		self.card.Visible = false
		self.phase = "pill"
		self:_layout()
	end)
end

function EventBanner:Clear()
	self.token += 1
	self.event = nil
	self.phase = "hidden"
	self.card.Visible = false
	self.pill.Visible = false
	self.pillButton.Visible = false
end

-- For galleries: set a phase instantly, no tweens. `phase` is "card", "docking" (half way) or "pill".
function EventBanner:Snap(event, phase)
	self.token += 1
	self.event = event
	self:_fill(event)
	local x, y, pillScale = self:_pillOrigin()
	local cardScale = EventBanner.CardScaleFor(self.viewport)
	self.phase = phase
	self.card.Visible = phase ~= "pill"
	self.card.GroupTransparency = phase == "docking" and 0.45 or 0
	self.pill.Visible = phase ~= "card"
	self.pillButton.Visible = phase == "pill"
	self.pill.GroupTransparency = phase == "docking" and 0.5 or 0
	self.pillScale.Scale = pillScale
	self.badgeScale.Scale = 1
	self.glint.Position = UDim2.new(0, -120, 0.5, 0)
	if phase == "docking" then
		local top = EventBanner.CardTopFor(self.viewport)
		local fromX = self.viewport.X / 2
		local toX = x + PILL_W * pillScale / 2
		self.card.Position = UDim2.fromOffset(fromX + (toX - fromX) * 0.55, top + (y - top) * 0.55)
		self.cardScale.Scale = cardScale + (PILL_W * pillScale / CARD_W - cardScale) * 0.55
	else
		self.card.Position = UDim2.new(0.5, 0, 0, EventBanner.CardTopFor(self.viewport))
		self.cardScale.Scale = cardScale
	end
end

return EventBanner
