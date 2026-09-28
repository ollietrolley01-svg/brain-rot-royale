-- The merge confirmation card, opened from a brainrot's MERGE button in the Brainrots tab.
--
-- Merging spends copies for good, so nothing is sent until the player has seen exactly what they
-- get: the stars now and after, damage, health and total bonus now and after, how many copies it
-- uses, how many stay, and the sell value those copies would have fetched. The menu makes the
-- server call; this module only draws the card and reports CONFIRM or CANCEL.
--
-- It's a ModuleScript rather than part of MenuClient so tools/merge_gallery.lua can build the
-- real card in edit mode and screenshot it.
--
--   MergeDialog.Open(parent, { def, level, stars, count, onConfirm, instant })
--   MergeDialog.Resolve(ok, message)   the server's answer; success celebrates and closes
--   MergeDialog.Close()
--   MergeDialog.IsOpen()

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded, formatNumber = UiKit.create, UiKit.rounded, UiKit.formatNumber
local C = UiKit.Colors

local MergeDialog = {}

local GOLD = Rarity.Color("Legendary")
local NEW_STAR = Color3.fromRGB(255, 244, 190)
local EMPTY_STAR = Color3.fromRGB(70, 74, 92)

local CARD_WIDTH = 500
local CARD_HEIGHT = 436
-- Stat table columns: label, now, after, change.
local COLUMNS = { { x = 164, w = 70 }, { x = 234, w = 96 }, { x = 330, w = 96 }, { x = 426, w = 54 } }
-- Seconds the "merged" state stays up before the card closes itself. A field so the gallery can
-- hold it open long enough to capture.
MergeDialog.CloseAfterSuccess = 1.1

-- The open card, or nil: { overlay, card, scale, status, confirm, cancel, busy, onConfirm }.
local current = nil
-- Bumped on every open and close, so a delayed close from an older card can't shut a newer one.
local token = 0

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5))
end

-- Five stars as rich text: earned ones gold, the one this merge adds (if any) brighter, the rest dim.
local function starsText(stars, newStar)
	local parts = {}
	for index = 1, BrainrotData.MaxStars do
		local color = index == newStar and NEW_STAR or index <= stars and GOLD or EMPTY_STAR
		table.insert(parts, string.format('<font color="%s">★</font>', hex(color)))
	end
	return table.concat(parts)
end

local function label(parent, props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.GothamBold
	props.TextColor3 = props.TextColor3 or C.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.Parent = parent
	return create("TextLabel", props)
end

-- A live 3D portrait, the same model the companion uses (as the inventory cards draw it).
local function photo(parent, def, size)
	local viewport = create("ViewportFrame", {
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(170, 170, 182),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Parent = parent,
	}, { rounded(12) })
	BrainrotModels.Build(def).Parent = viewport
	BrainrotModels.FrameViewport(viewport, def)
	return viewport
end

local function setButton(button, enabled, color, text)
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.BackgroundColor3 = enabled and color or C.PanelAlt
	button.TextColor3 = enabled and Color3.new(0, 0, 0) or C.Muted
	if text then
		button.Text = text
	end
end

function MergeDialog.IsOpen()
	return current ~= nil
end

function MergeDialog.Close()
	token += 1
	if current then
		local returnTo = current.padReturn
		current.overlay:Destroy()
		current = nil
		-- The pad goes back to the MERGE button it came from, not to nothing inside an open menu.
		if returnTo and returnTo.Parent then
			pcall(function()
				GuiService.SelectedObject = returnTo
			end)
		end
	end
end

-- Returns the overlay, or nil if this brainrot can't be merged any further.
function MergeDialog.Open(parent, info)
	MergeDialog.Close()

	local def = info.def
	local stars = BrainrotData.ClampStars(info.stars)
	local cost = BrainrotData.MergeCost(stars)
	if not def or not cost then
		return nil
	end
	local level = info.level or 1
	local count = info.count or 1
	local now = BrainrotData.Stats(def, level, stars)
	local after = BrainrotData.Stats(def, level, stars + 1)
	local color = Rarity.Color(def.rarity)

	token += 1
	local myToken = token

	-- A full-screen button so clicks can't reach the menu behind the card. It deliberately does
	-- nothing itself: only CANCEL closes the card, so a click that lands on the card can never be
	-- mistaken for a dismissal.
	local overlay = create("TextButton", {
		Name = "MergeDialog",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 70,
		Parent = parent,
	})

	local card = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT),
		BackgroundColor3 = C.Background,
		BorderSizePixel = 0,
		Parent = overlay,
	}, { rounded(16) })
	create("UIStroke", { Color = GOLD, Thickness = 3, Parent = card })
	-- The card is 500x436 and nothing scaled it, so on a 390-tall phone it overflowed the screen and
	-- took CANCEL and MERGE (y 372..416) with it: a player could open a merge and had no way to
	-- confirm it. claude-ee, 2026-09-18, for Oliver's #62.
	--
	-- NOT PhoneLayout.FitPanel, which was the obvious fix and is the wrong one here: FitPanel reuses
	-- the card's existing UIScale, and that scale is the open animation, tweened back to 1 in four
	-- places below. The fit would have been wiped the moment the card animated in and the bug would
	-- have looked fixed in a still render. So the fit is computed once and every one of those four
	-- rest values is expressed in terms of it. `fit` is 1 on any screen with the room.
	local fit = 1
	pcall(function()
		local PhoneLayout = require(script.Parent:WaitForChild("PhoneLayout"))
		local camera = workspace.CurrentCamera
		fit = PhoneLayout.PanelScale(Vector2.new(CARD_WIDTH, CARD_HEIGHT),
			camera and camera.ViewportSize or Vector2.new(1920, 1080), { inset = true })
	end)
	local scale = create("UIScale", { Scale = (info.instant and 1 or 0.85) * fit, Parent = card })

	label(card, { Position = UDim2.fromOffset(20, 16), Size = UDim2.new(1, -40, 0, 16), Text = "MERGE", TextColor3 = GOLD, TextSize = 13 })
	label(card, {
		Position = UDim2.fromOffset(20, 32),
		Size = UDim2.new(1, -40, 0, 34),
		Font = Enum.Font.FredokaOne,
		Text = def.name,
		TextColor3 = color,
		TextSize = 28,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	label(card, {
		Position = UDim2.fromOffset(20, 68),
		Size = UDim2.new(1, -40, 0, 18),
		Text = string.format("%s  •  Lv %d  •  %s  •  you own %d", string.upper(def.rarity), level, now.move, count),
		TextColor3 = C.Muted,
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local portrait = photo(card, def, 124)
	portrait.Position = UDim2.fromOffset(20, 96)
	create("UIStroke", { Color = color, Thickness = 2, Parent = portrait })

	-- The before/after table.
	for index, heading in ipairs({ "", "NOW", "AFTER", "" }) do
		label(card, {
			Position = UDim2.fromOffset(COLUMNS[index].x + 8, 96),
			Size = UDim2.fromOffset(COLUMNS[index].w - 8, 18),
			Text = heading,
			TextColor3 = C.Muted,
			TextSize = 12,
		})
	end

	local function percent(stats)
		return math.floor((BrainrotData.LevelBonus(level) * BrainrotData.StarBonus(stats.stars) - 1) * 100 + 0.5)
	end
	local rows = {
		{ "STARS", starsText(stars), starsText(stars + 1, stars + 1), "", true },
		{ "DAMAGE", tostring(now.damage), tostring(after.damage), string.format("+%d", after.damage - now.damage) },
		{ "HEALTH", tostring(now.health), tostring(after.health), string.format("+%d", after.health - now.health) },
		{ "BONUS", string.format("+%d%%", percent(now)), string.format("+%d%%", percent(after)),
			string.format("+%d%%", percent(after) - percent(now)) },
	}
	for rowIndex, row in ipairs(rows) do
		local y = 118 + (rowIndex - 1) * 30
		create("Frame", {
			Position = UDim2.fromOffset(COLUMNS[1].x, y),
			Size = UDim2.fromOffset(CARD_WIDTH - 20 - COLUMNS[1].x, 26),
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			Parent = card,
		}, { rounded(6) })
		local isStars = row[5] == true
		for column = 1, 4 do
			label(card, {
				Position = UDim2.fromOffset(COLUMNS[column].x + 8, y),
				Size = UDim2.fromOffset(COLUMNS[column].w - 8, 26),
				Text = row[column],
				RichText = isStars and (column == 2 or column == 3),
				TextColor3 = column == 1 and C.Muted or column == 3 and C.Text or column == 4 and C.Green or C.Muted,
				-- ★ draws noticeably smaller than letters at the same size (see the gallery's glyph sheet).
				TextSize = (isStars and column > 1) and 21 or column == 3 and 15 or 13,
			})
		end
	end

	label(card, {
		Position = UDim2.fromOffset(20, 248),
		Size = UDim2.new(1, -40, 0, 34),
		Font = Enum.Font.Gotham,
		Text = "Cooldown, range and move stay the same. Stars belong to you: selling or trading copies later never takes them away.",
		TextColor3 = C.Muted,
		TextSize = 12,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	-- What it costs.
	local costPanel = create("Frame", {
		Position = UDim2.fromOffset(20, 290),
		Size = UDim2.new(1, -40, 0, 48),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Parent = card,
	}, { rounded(10) })
	label(costPanel, {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(0.42, -14, 1, 0),
		Text = string.format("USES %d SPARE COP%s", cost, cost == 1 and "Y" or "IES"),
		TextSize = 15,
	})
	-- Two short right-aligned lines rather than one long one that wraps wherever it likes.
	label(costPanel, {
		Position = UDim2.new(0.42, 0, 0, 7),
		Size = UDim2.new(0.58, -14, 0, 16),
		Text = string.format("you keep %d", count - cost),
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	label(costPanel, {
		Position = UDim2.new(0.42, 0, 0, 25),
		Size = UDim2.new(0.58, -14, 0, 16),
		Text = string.format("gives up %s coins of sell value", formatNumber(cost * def.coinValue)),
		TextColor3 = C.Muted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local status = label(card, {
		Position = UDim2.fromOffset(20, 346),
		Size = UDim2.new(1, -40, 0, 18),
		Text = "",
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local cancel = create("TextButton", {
		Position = UDim2.fromOffset(20, 372),
		Size = UDim2.fromOffset(140, 44),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = "CANCEL",
		TextSize = 15,
		Parent = card,
	}, { rounded(10) })
	setButton(cancel, true, C.PanelAlt)
	cancel.TextColor3 = C.Text

	local confirmText = string.format("MERGE TO %d STAR%s", stars + 1, stars + 1 == 1 and "" or "S")
	local confirm = create("TextButton", {
		Position = UDim2.fromOffset(172, 372),
		Size = UDim2.new(1, -192, 0, 44),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Parent = card,
	}, { rounded(10) })
	setButton(confirm, true, GOLD, confirmText)

	current = {
		overlay = overlay,
		card = card,
		scale = scale,
		fit = fit,
		status = status,
		confirm = confirm,
		cancel = cancel,
		confirmText = confirmText,
		busy = false,
		onConfirm = info.onConfirm,
	}
	local mine = current

	cancel.Activated:Connect(function()
		if current == mine and not mine.busy then
			MergeDialog.Close()
		end
	end)
	confirm.Activated:Connect(MergeDialog.Confirm)

	-- A gamepad has no pointer: its selection starts on CANCEL, so a stray A never spends anything, and
	-- the button it came from is remembered for Close. Nothing changes for a mouse or a finger.
	pcall(function()
		if string.find(UserInputService:GetLastInputType().Name, "Gamepad", 1, true) then
			mine.padReturn = GuiService.SelectedObject
			GuiService.SelectedObject = cancel
		end
	end)

	if not info.instant then
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = fit }):Play()
		-- Guards against a tween that never plays (the card must never be left small).
		task.delay(0.4, function()
			if token == myToken and scale.Parent then
				scale.Scale = fit
			end
		end)
	end

	return overlay
end

-- What CONFIRM does: lock both buttons and hand over to the menu's onConfirm, once. Also callable
-- directly (the gallery uses it to capture the in-progress and result states).
function MergeDialog.Confirm()
	local mine = current
	if not mine or mine.busy then
		return
	end
	mine.busy = true
	setButton(mine.confirm, false, GOLD, "MERGING...")
	setButton(mine.cancel, false, C.PanelAlt)
	mine.status.Text = ""
	if mine.onConfirm then
		mine.onConfirm()
	end
end

-- The server's answer to the confirm. Success pops the card and closes it; a refusal shows why
-- and hands the buttons back, since nothing was spent.
function MergeDialog.Resolve(ok, message)
	local mine = current
	if not mine or not mine.busy then
		return
	end
	mine.busy = false

	if ok then
		mine.status.Text = message or "Merged!"
		mine.status.TextColor3 = GOLD
		setButton(mine.confirm, false, GOLD, "MERGED!")
		mine.confirm.BackgroundColor3 = GOLD
		mine.confirm.TextColor3 = Color3.new(0, 0, 0)
		mine.scale.Scale = 1.06 * (mine.fit or 1)
		TweenService:Create(mine.scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = mine.fit or 1 }):Play()
		local myToken = token
		task.delay(MergeDialog.CloseAfterSuccess, function()
			if token == myToken and current == mine then
				MergeDialog.Close()
			end
		end)
	else
		mine.status.Text = message or "Couldn't merge that."
		mine.status.TextColor3 = C.Red
		setButton(mine.confirm, true, GOLD, mine.confirmText)
		setButton(mine.cancel, true, C.PanelAlt)
		mine.cancel.TextColor3 = C.Text
	end
end

return MergeDialog
