-- The companion ability tile on the HUD: your brainrot's portrait, the key that uses its move, and
-- a ring that fills clockwise as the move recharges. ModuleScript, used by HudClient (and by
-- tools/companion_icon_gallery.lua, which shows every state).
--
--   local icon = CompanionAbilityIcon.new(screenGui)
--   icon:SetBrainrot(def)           -- nil hides the tile
--   icon:SetKey("G")                -- nil hides the key badge
--   icon:Used()                     -- the move just went off: flash (the ring follows Update)
--   icon:Update(remaining, cooldown, downed, hidden)   -- every frame
--
-- The ring is two clipped halves of a circle whose outline carries a hard-edged UIGradient; turning
-- the gradient sweeps the edge round, the right half for the first 180 degrees and the left half for
-- the rest. No images, so nothing to upload or fail to load.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local CompanionAbilityIcon = {}
CompanionAbilityIcon.__index = CompanionAbilityIcon

CompanionAbilityIcon.Size = 72

-- WHERE IT SITS (Oliver's #14: "looks like it's just in a random location").
--
-- It used to be at x 326, y bottom-166 — which is the GUTTER: just past the health panel's right
-- edge (UiKit.BottomRow.HealthRight is 296) and well short of the hotbar, belonging to neither. That
-- is exactly why it read as random; it was placed in the gap between two things rather than with
-- either of them.
--
-- It belongs with the hotbar. The tile is a thing you TRIGGER with a key and that recharges on a
-- cooldown, which is what a hotbar slot is — so it sits immediately left of the hotbar, bottom
-- aligned, and the bottom-right of the screen reads as one row of everything you can set off.
-- Measured from UiKit.BottomRow.HotbarInset rather than a literal, so it follows the hotbar if the
-- hotbar ever moves.
CompanionAbilityIcon.Position = UDim2.new(1, -(UiKit.BottomRow.HotbarInset + UiKit.BottomRow.Gap), 1, -16)
CompanionAbilityIcon.AnchorPoint = Vector2.new(1, 1)

local RING = 4
local HARD_EDGE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.499, 0),
	NumberSequenceKeypoint.new(0.5, 1),
	NumberSequenceKeypoint.new(1, 1),
})

local function half(parent, size, left)
	local clip = create("Frame", {
		Name = left and "RingLeft" or "RingRight",
		Position = UDim2.fromOffset(left and 0 or size / 2, 0),
		Size = UDim2.fromOffset(size / 2, size),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 4,
		Parent = parent,
	})
	-- Inset by the stroke's width: an outline draws outside its frame, and the clip would cut it.
	local circle = create("Frame", {
		Position = UDim2.fromOffset((left and 0 or -size / 2) + RING, RING),
		Size = UDim2.fromOffset(size - RING * 2, size - RING * 2),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = clip,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local stroke = create("UIStroke", {
		Thickness = RING,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = C.Green,
		Parent = circle,
	})
	local gradient = create("UIGradient", { Transparency = HARD_EDGE, Parent = stroke })
	return stroke, gradient
end

function CompanionAbilityIcon.new(parent)
	local self = setmetatable({}, CompanionAbilityIcon)
	local size = CompanionAbilityIcon.Size

	self.frame = create("Frame", {
		Name = "CompanionAbility",
		Position = CompanionAbilityIcon.Position,
		AnchorPoint = CompanionAbilityIcon.AnchorPoint,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Visible = false,
		Parent = parent,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	self.scale = create("UIScale", { Parent = self.frame })

	-- A faint full ring under the progress, so an empty ring still reads as a ring.
	create("UIStroke", { Thickness = RING, Color = C.PanelAlt, Transparency = 0.2, Parent = self.frame })

	self.portrait = create("ViewportFrame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size - 14, size - 14),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(170, 170, 182),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		ZIndex = 2,
		Parent = self.frame,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })

	-- Darkens the portrait while the move recharges.
	self.shade = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size - 14, size - 14),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = self.frame,
	}, { create("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })

	self.seconds = create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "",
		TextColor3 = C.Text,
		TextStrokeTransparency = 0.4,
		TextSize = 22,
		ZIndex = 5,
		Parent = self.frame,
	})

	self.rightStroke, self.rightGradient = half(self.frame, size, false)
	self.leftStroke, self.leftGradient = half(self.frame, size, true)

	self.badge = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -5, 0, 5),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = self.frame,
	}, { rounded(6) })
	self.key = create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = C.Background,
		TextScaled = true,
		ZIndex = 7,
		Parent = self.badge,
	}, { create("UITextSizeConstraint", { MaxTextSize = 14 }) })

	self.ready = true
	return self
end

-- nil hides the badge (a touch screen, where the on-screen button is the control).
-- What the ability actually does, in numbers (Oliver's #14: "describe the ability's DPS and health").
--
-- DPS rather than raw damage, because damage alone is not comparable between moves: Bonk hits for
-- more than Zap and recharges slower, so the number a player needs to choose between two companions
-- is damage per second, not damage. Both are shown — the hit and the rate it comes at — so the DPS
-- can be checked rather than taken on faith.
--
-- `stats` is whatever BrainrotData.Stats returns: damage, cooldown, health.
function CompanionAbilityIcon:SetStats(stats, moveName)
	if not self.readout then
		-- ABOVE the tile, not below it: the tile is anchored to the bottom of the screen, so anything
		-- under it is off the screen. Right-aligned to the tile's right edge so the line grows
		-- leftward into open space instead of into the hotbar beside it.
		self.readout = create("Frame", {
			Name = "Readout",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 0, 0, -6),
			Size = UDim2.fromOffset(230, 32),
			BackgroundTransparency = 1,
			Parent = self.frame,
		})
		self.readoutMove = create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = UiKit.Type.Label.Font,
			Text = "",
			TextColor3 = C.Text,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = self.readout,
		})
		self.readoutStats = create("TextLabel", {
			Position = UDim2.fromOffset(0, 15),
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = UiKit.Type.Caption.Font,
			Text = "",
			TextColor3 = C.Muted,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = self.readout,
		})
	end

	if not stats then
		self.readout.Visible = false
		return
	end
	local cooldown = math.max(stats.cooldown or 0, 0.01)
	local dps = (stats.damage or 0) / cooldown
	self.readoutMove.Text = moveName or ""
	self.readoutMove.TextColor3 = self.color or C.Text
	-- A decimal below 10, because these abilities are bursts on long cooldowns: 15 damage every
	-- 8.8 s is 1.7 DPS, and rounding that to "2 DPS" is a 18% lie on the number a player is meant
	-- to compare companions with. Above 10 the decimal is noise and is dropped.
	self.readoutStats.Text = string.format(dps < 10 and "%.1f DPS  ·  %d dmg / %.1fs  ·  %d HP"
		or "%.0f DPS  ·  %d dmg / %.1fs  ·  %d HP", dps, stats.damage or 0, cooldown, stats.health or 0)
	self.readout.Visible = true
end

function CompanionAbilityIcon:SetKey(text)
	self.badge.Visible = text ~= nil
	self.key.Text = text or ""
	self.badge.Size = UDim2.fromOffset(math.max(22, 10 + #self.key.Text * 8), 22)
end

function CompanionAbilityIcon:SetBrainrot(def)
	if def == self.def then
		return
	end
	self.def = def
	self.portrait:ClearAllChildren()
	self.frame.Visible = def ~= nil
	if not def then
		return
	end
	self.color = Rarity.Color(def.rarity)
	local model = BrainrotModels.Build(def, { flair = false })
	model.Parent = self.portrait
	BrainrotModels.FrameViewport(self.portrait, def, 5.2)
end

-- `fraction` of the ring drawn, clockwise from the top.
function CompanionAbilityIcon:SetRing(fraction, color)
	local angle = math.clamp(fraction, 0, 1) * 360
	self.rightGradient.Rotation = math.min(angle, 180)
	self.leftGradient.Rotation = math.max(angle, 180)
	self.rightStroke.Color = color
	self.leftStroke.Color = color
end

function CompanionAbilityIcon:Used()
	self.scale.Scale = 0.86
	TweenService:Create(self.scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- remaining: seconds until the move is ready (0 or less = ready); cooldown: its full length.
function CompanionAbilityIcon:Update(remaining, cooldown, downed, hidden)
	if not self.def then
		self.frame.Visible = false
		return
	end
	self.frame.Visible = not hidden
	if hidden then
		return
	end
	if downed then
		self:SetRing(1, C.Red)
		self.shade.BackgroundTransparency = 0.25
		-- FredokaOne has no multiplication sign; GothamBold draws it.
		self.seconds.Font = Enum.Font.GothamBold
		self.seconds.TextSize = 34
		self.seconds.Text = "×"
		self.seconds.TextColor3 = C.Red
		self.ready = false
		return
	end
	if remaining > 0.02 and cooldown > 0 then
		self:SetRing(1 - remaining / cooldown, self.color or C.Accent)
		self.shade.BackgroundTransparency = 0.45
		self.seconds.Font = Enum.Font.FredokaOne
		self.seconds.TextSize = 22
		self.seconds.Text = remaining >= 1 and string.format("%d", math.ceil(remaining)) or string.format("%.1f", remaining)
		self.seconds.TextColor3 = C.Text
		self.ready = false
	else
		self:SetRing(1, C.Green)
		self.shade.BackgroundTransparency = 1
		self.seconds.Text = ""
		if not self.ready then
			-- Just came back: a pop so it's noticed out of the corner of an eye.
			self.ready = true
			self.scale.Scale = 1.18
			TweenService:Create(self.scale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end
end

return CompanionAbilityIcon
