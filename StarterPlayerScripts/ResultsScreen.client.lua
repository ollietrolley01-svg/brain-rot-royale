-- The end-of-match screen (Oliver, 2026-09-22 16:03: "the winning screen huds need serious
-- improvement"). Replaces HudClient's old results card, which was one centred text block: "#1",
-- then a wall of lines. In team modes it read "#2 out of 28" for a lost Team Deathmatch and
-- "+0 SahurCoins", and the win banner said BRAINROT CHAMPION whatever the mode.
--
-- Now: a dimmed backdrop and one card with
--   * a mode chip and a headline that fits the mode: BRAINROT CHAMPION / #N of M in Battle Royale,
--     VICTORY / DEFEAT / DRAW in the team modes
--   * who won (Battle Royale) or the final scoreline in team colours (team modes)
--   * the match in stat tiles that count up: eliminations, damage, accuracy, headshots, longest
--     elimination, damage taken, chests, companion damage (only the ones that happened, after the
--     first two)
--   * rewards as chips: crate in its rarity colour, coins, Pass XP, Rot Rank (nothing that is zero)
--   * in the team modes, every line of the pay above the chips (result, kills, assists, multi-kills,
--     revenge, captures, time on the objective, defends, time played, and the TEAM BONUS lines in gold:
--     MVP, first win of the day, win streak, a team cosmetic unlocked), a TEAM BONUS chip with its total
--     and the first win's crate, each MVP by name, and the match numbers as one line instead of tiles so
--     the card still fits a phone
--   * a countdown back to the lobby and a close button
-- Confetti on a win. Scales down to fit a phone.
--
-- HudClient's MatchResults handler returns early while this ScreenGui ("BrrResults") exists, so
-- the two never draw at once. Delete this file and the old card comes back on its own.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local GameModes = require(Shared:WaitForChild("GameModes"))

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local RunService = game:GetService("RunService")
-- The crate you won, as the real 3D crate (the same model the menu opens). Loaded softly: if the
-- builder fails, the crate still shows as its name and colour.
local okCrates, CrateModels = pcall(require, Shared:WaitForChild("CrateModels"))
local okSfx, Sfx = pcall(require, script.Parent:WaitForChild("Sfx"))

local create, rounded, padding = UiKit.create, UiKit.rounded, UiKit.padding
local formatNumber = UiKit.formatNumber
local C = UiKit.Colors
local R = UiKit.Role

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local matchResults = Remotes.Event("MatchResults")
local matchChanged = Remotes.Event("MatchChanged")

local SHOW_FOR = 12 -- seconds; the server's results phase is 15
local CARD_WIDTH = 580
-- The crate tile, and the team modes' shorter one; the reward breakdown's row height, the most lines it
-- draws (RewardService.TeamBreakdown makes at most 14 with the 2x line), and the width of its right-hand "paid" column.
-- Sized so the tallest team card fits a 640x360 phone at a scale of 0.5 or more, clear of fitScale's 0.45
-- floor where the card would start to leave the screen (tools/team_rewards_layout_check.py).
local CRATE_TILE, CRATE_TILE_TEAM = 92, 64
local BREAKDOWN_ROW, BREAKDOWN_MAX, BREAKDOWN_PAID = 18, 16, 112
local GOLD = C.Accent
local CONFETTI_COLORS = { C.Accent, C.Green, C.Storm, C.Red, R.Info, Color3.fromRGB(255, 255, 255) }

local screenGui = create("ScreenGui", {
	Name = "BrrResults",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 20,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Enabled = false,
	Parent = playerGui,
})

local scrim = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = R.Scrim,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = screenGui,
})

-- A soft glow behind the card, tinted by the outcome.
local glow = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(CARD_WIDTH + 160, 620),
	BackgroundColor3 = GOLD,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = screenGui,
}, {
	rounded(300),
	create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}),
})

local card = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(CARD_WIDTH, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = R.Base,
	BorderSizePixel = 0,
	Parent = screenGui,
}, {
	rounded(18),
	padding(22),
	create("UIStroke", { Color = R.Line, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 12),
	}),
})
local cardStroke = card:FindFirstChildOfClass("UIStroke")
local cardScale = create("UIScale", { Parent = card })

-- Fits the card to the screen: full size on a desktop, smaller on a phone. Also returns the card's
-- height at a scale of 1, read off its last layout: its width there says the scale that layout used,
-- where UIScale.Scale may have moved on since (mid-tween). 0 before its first layout, so floored at 400.
local function fitScale()
	local viewport = camera.ViewportSize
	local size = card.AbsoluteSize
	local height = math.max(size.X > 0 and size.Y * CARD_WIDTH / size.X or 0, 400)
	return math.clamp(math.min((viewport.X - 24) / CARD_WIDTH, (viewport.Y - 24) / height), 0.45, 1), height
end

-- The fit of the card on screen: the show it belongs to, the height it was fitted to, its pop-in.
local fit = { token = 0, height = 0, target = 1 }

local function popIn(target)
	fit.target = target
	cardScale.Scale = target * 0.85
	fit.tween = TweenService:Create(cardScale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target })
	fit.tween:Play()
end

--------------------------------------------------------------------------------
-- Building blocks
--------------------------------------------------------------------------------

local function label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.GothamBold
	props.TextColor3 = props.TextColor3 or R.Text
	return create("TextLabel", props)
end

local function chip(parent, text, color, order)
	return create("Frame", {
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		LayoutOrder = order or 0,
		Parent = parent,
	}, {
		rounded(15),
		create("UIStroke", { Color = color, Thickness = 1.5, Transparency = 0.2 }),
		create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }),
		label({
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = Enum.Font.GothamBlack,
			Text = text,
			TextColor3 = color,
			TextSize = 14,
		}),
	})
end

local function row(order, height, gap)
	return create("Frame", {
		Size = UDim2.new(1, 0, 0, height or 0),
		AutomaticSize = height and Enum.AutomaticSize.None or Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = card,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap or 8),
		}),
	})
end

-- Numbers count up from zero when the card opens.
local counters = {}
local function countUp(textLabel, target, format)
	table.insert(counters, { label = textLabel, target = target, format = format })
	textLabel.Text = format(0)
end

local function runCounters(token, stillShowing)
	local list = counters
	counters = {}
	task.spawn(function()
		-- Wall time, not os.clock (CPU time in Roblox): a busy frame must not slow the count-up.
		local started = tick()
		local duration = 0.9
		while stillShowing(token) do
			local t = math.clamp((tick() - started) / duration, 0, 1)
			local eased = 1 - (1 - t) ^ 3
			for _, entry in ipairs(list) do
				entry.label.Text = entry.format(entry.target * eased)
			end
			if t >= 1 then
				break
			end
			task.wait()
		end
	end)
end

local function statTile(parent, value, caption, format, accent, order)
	local tile = create("Frame", {
		BackgroundColor3 = R.Surface,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
	}, {
		rounded(12),
		create("UIStroke", { Color = R.Line, Thickness = 1 }),
	})
	create("Frame", { -- accent bar on the left edge
		Size = UDim2.new(0, 4, 1, -16),
		Position = UDim2.fromOffset(0, 8),
		BackgroundColor3 = accent or GOLD,
		BorderSizePixel = 0,
		Parent = tile,
	}, { rounded(2) })
	local number = label({
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -20, 0, 30),
		Font = Enum.Font.FredokaOne,
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = tile,
	})
	label({
		Position = UDim2.fromOffset(14, 40),
		Size = UDim2.new(1, -20, 0, 16),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = R.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = string.upper(caption),
		Parent = tile,
	})
	countUp(number, value, format)
	return tile
end

local function whole(n)
	return formatNumber(math.floor(n + 0.5))
end

--------------------------------------------------------------------------------
-- Confetti
--------------------------------------------------------------------------------

local function confetti(count)
	local viewport = camera.ViewportSize
	for _ = 1, count do
		local size = math.random(6, 12)
		local startX = math.random(0, math.floor(viewport.X))
		local piece = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(startX, -20 - math.random(0, 260)),
			Size = UDim2.fromOffset(size, math.floor(size * 1.6)),
			Rotation = math.random(0, 360),
			BackgroundColor3 = CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)],
			BorderSizePixel = 0,
			ZIndex = 30,
			Parent = screenGui,
		})
		local fall = 2.4 + math.random() * 2
		TweenService:Create(piece, TweenInfo.new(fall, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.fromOffset(startX + math.random(-140, 140), viewport.Y + 40),
			Rotation = piece.Rotation + math.random(-600, 600),
		}):Play()
		task.delay(fall + 0.1, function()
			piece:Destroy()
		end)
	end
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------

local showToken = 0

local function isCurrent(token)
	return showToken == token and screenGui.Enabled
end

local function hide()
	showToken += 1
	local token = showToken
	if not screenGui.Enabled then
		return
	end
	TweenService:Create(scrim, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(glow, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(cardScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Scale = cardScale.Scale * 0.9 }):Play()
	task.delay(0.25, function()
		if showToken == token then
			screenGui.Enabled = false
		end
	end)
end

local function clearCard()
	for _, child in ipairs(card:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	counters = {}
end

local function render(result)
	clearCard()

	local modeId = result.mode or "BattleRoyale"
	local modeInfo = GameModes.Get and GameModes.Get(modeId) or nil
	local modeName = modeInfo and modeInfo.name or "Battle Royale"
	local modeColor = modeInfo and modeInfo.color or C.Storm
	local teams = result.modeResults
	local teamMode = modeId ~= "BattleRoyale" and teams ~= nil and teams.scores ~= nil

	-- The outcome.
	local headline, headColor, won
	local sub = nil
	if teamMode then
		if teams.winner == nil then
			headline, headColor, won = "DRAW", R.TextMuted, false
		elseif result.rank == 1 then
			headline, headColor, won = "VICTORY", C.Green, true
		else
			headline, headColor, won = "DEFEAT", C.Red, false
		end
	else
		won = result.rank == 1
		if won then
			headline, headColor = "BRAINROT CHAMPION", GOLD
			sub = string.format("Last one standing out of %d", result.total or 0)
		else
			headline = "#" .. tostring(result.rank)
			headColor = result.rank <= 3 and GOLD or (result.rank <= 10 and R.Text or R.TextMuted)
			sub = string.format("of %d", result.total or 0)
			if result.winnerName then
				sub ..= string.format("   •   won by %s%s", result.winnerName, result.winnerIsBot and " (bot)" or "")
			end
		end
	end

	glow.BackgroundColor3 = headColor
	cardStroke.Color = won and headColor or R.Line

	-- 1. Mode chip (plus a Top 10 tag in Battle Royale).
	local chips = row(1, 30)
	chip(chips, string.upper(modeName), modeColor, 1)
	if not teamMode and not won and result.rank <= 10 then
		chip(chips, result.rank <= 3 and "PODIUM" or "TOP 10", GOLD, 2)
	end

	-- 2. Headline.
	local title = label({
		Size = UDim2.new(1, 0, 0, 72),
		Font = Enum.Font.FredokaOne,
		Text = headline,
		TextColor3 = headColor,
		TextScaled = true,
		LayoutOrder = 2,
		Parent = card,
	}, nil)
	create("UITextSizeConstraint", { MaxTextSize = #headline > 8 and 52 or 72, Parent = title })
	create("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.4, Parent = title })
	local titleScale = create("UIScale", { Scale = 0.4, Parent = title })

	-- 3. Subline: who won, or the final score.
	if teamMode then
		local scoreRow = row(3, 64, 14)
		for index = 1, 2 do
			local color = GameModes.TeamColor(index)
			local block = create("Frame", {
				Size = UDim2.fromOffset(200, 64),
				BackgroundColor3 = color,
				BackgroundTransparency = teams.winner == index and 0.7 or 0.9,
				BorderSizePixel = 0,
				LayoutOrder = index == 1 and 1 or 3,
				Parent = scoreRow,
			}, {
				rounded(12),
				create("UIStroke", { Color = color, Thickness = teams.winner == index and 2 or 1, Transparency = teams.winner == index and 0 or 0.5 }),
			})
			label({
				Position = UDim2.fromOffset(0, 4),
				Size = UDim2.new(1, 0, 0, 36),
				Font = Enum.Font.FredokaOne,
				TextSize = 34,
				TextColor3 = color,
				Text = tostring(teams.scores[index] or 0),
				Parent = block,
			})
			label({
				Position = UDim2.fromOffset(0, 40),
				Size = UDim2.new(1, 0, 0, 16),
				Font = Enum.Font.GothamBlack,
				TextSize = 12,
				TextColor3 = R.Text,
				Text = string.upper((teams.teams and teams.teams[index]) or GameModes.TeamName(index)),
				Parent = block,
			})
		end
		label({
			Size = UDim2.fromOffset(40, 64),
			Font = Enum.Font.GothamBlack,
			TextSize = 16,
			TextColor3 = R.TextMuted,
			Text = "VS",
			LayoutOrder = 2,
			Parent = scoreRow,
		})
		if teams.target then
			sub = string.format("First to %d", teams.target)
		end
		-- Each side's MVP (GameMode.pickMvps), a list of { team, name }.
		local mvpNames = {}
		for _, entry in ipairs(type(teams.mvps) == "table" and teams.mvps or {}) do
			if type(entry) == "table" and entry.name then
				table.insert(mvpNames, tostring(entry.name))
			end
		end
		if #mvpNames > 0 then
			sub = (sub and sub .. "   •   " or "") .. "MVP " .. table.concat(mvpNames, ", ")
		end
	end
	if sub then
		label({
			Size = UDim2.new(1, 0, 0, 20),
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextColor3 = R.TextMuted,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = sub,
			LayoutOrder = 4,
			Parent = card,
		})
	end

	-- 4. The match in numbers.
	local tally = result.tally or {}
	local combat = result.combat or {}
	local stats = {
		{ result.kills or 0, "Eliminations", whole, C.Red },
		{ tally.damage or 0, "Damage dealt", whole, GOLD },
	}
	if (combat.shots or 0) > 0 then
		table.insert(stats, { math.floor((combat.hits or 0) / combat.shots * 100 + 0.5), "Accuracy", function(n)
			return string.format("%d%%", math.floor(n + 0.5))
		end, R.Info })
	end
	if (combat.headshots or 0) > 0 then
		table.insert(stats, { combat.headshots, "Headshots", whole, C.Storm })
	end
	if (combat.longestKill or 0) > 0 then
		table.insert(stats, { combat.longestKill, "Longest elim", function(n)
			return string.format("%d studs", math.floor(n + 0.5))
		end, C.Green })
	end
	if (combat.damageTaken or 0) > 0 then
		table.insert(stats, { combat.damageTaken, "Damage taken", whole, R.TextMuted })
	end
	if (tally.chests or 0) > 0 then
		table.insert(stats, { tally.chests, "Chests opened", whole, GOLD })
	end
	if (result.companionDamage or 0) > 0 then
		table.insert(stats, { result.companionDamage, "Companion dmg", whole, C.Green })
	end
	-- Three to a row; two rows at most. In a team mode the numbers go on one quiet line instead: the reward
	-- breakdown below lists the eliminations and needs the room on a phone (tools/team_rewards_layout_check.py).
	if teamMode then
		local parts = {}
		for index = 1, math.min(#stats, 3) do
			local stat = stats[index]
			table.insert(parts, stat[3](stat[1]) .. " " .. string.lower(stat[2]))
		end
		label({
			Size = UDim2.new(1, 0, 0, 16),
			Font = Enum.Font.GothamMedium,
			TextSize = 13,
			TextColor3 = R.TextMuted,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = table.concat(parts, "   •   "),
			LayoutOrder = 5,
			Parent = card,
		})
	else
		while #stats > 6 do
			table.remove(stats)
		end
		local grid = create("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 5,
			Parent = card,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.new(1 / 3, -6, 0, 64),
				CellPadding = UDim2.fromOffset(9, 9),
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		for index, stat in ipairs(stats) do
			statTile(grid, stat[1], stat[2], stat[3], stat[4], index)
		end
	end

	-- Extras on one quiet line: items, supply drops, bounties, easter eggs.
	local extras = {}
	if (tally.items or 0) > 0 then
		table.insert(extras, string.format("%d item%s used", tally.items, tally.items == 1 and "" or "s"))
	end
	if (tally.supply or 0) > 0 then
		table.insert(extras, string.format("%d supply drop%s", tally.supply, tally.supply == 1 and "" or "s"))
	end
	if (tally.bounties or 0) > 0 then
		table.insert(extras, string.format("%d bount%s", tally.bounties, tally.bounties == 1 and "y" or "ies"))
	end
	if (result.eggsTotal or 0) > 0 then
		table.insert(extras, string.format("Easter eggs %d / %d", result.eggsFound or 0, result.eggsTotal))
	end
	-- Not in a team mode: the breakdown takes its room.
	if #extras > 0 and not teamMode then
		label({
			Size = UDim2.new(1, 0, 0, 16),
			Font = Enum.Font.GothamMedium,
			TextSize = 13,
			TextColor3 = R.TextMuted,
			Text = table.concat(extras, "   •   "),
			TextWrapped = true,
			LayoutOrder = 6,
			Parent = card,
		})
	end

	-- 5. Rewards. The crate first and big (Oliver 16:42: the screen didn't show your reward crate -- it
	-- was one chip of five in a row that ran off both sides of the card), then the rest as chips that wrap.
	local reward = result.reward
	if reward and reward.crate then
		local tint = Rarity.Color(reward.crate)
		-- Shorter in a team mode, for the breakdown's room.
		local tileHeight = teamMode and CRATE_TILE_TEAM or CRATE_TILE
		local tile = create("Frame", {
			Size = UDim2.new(1, 0, 0, tileHeight),
			BackgroundColor3 = tint,
			BackgroundTransparency = 0.86,
			BorderSizePixel = 0,
			LayoutOrder = 7,
			Parent = card,
		}, {
			rounded(14),
			create("UIStroke", { Color = tint, Thickness = 2, Transparency = 0.15 }),
		})
		local viewport = create("ViewportFrame", {
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.fromOffset(96, tileHeight - 12),
			BackgroundTransparency = 1,
			Ambient = Color3.fromRGB(170, 170, 182),
			LightColor = Color3.fromRGB(255, 250, 240),
			LightDirection = Vector3.new(-0.4, -1, 0.6),
			Parent = tile,
		})
		if okCrates and CrateModels and CrateModels.Crate then
			local built, model = pcall(CrateModels.Crate, reward.crate)
			if built and model then
				model.Parent = viewport
				local camera = Instance.new("Camera")
				camera.FieldOfView = 34
				camera.Parent = viewport
				viewport.CurrentCamera = camera
				local _, size = model:GetBoundingBox()
				local focus = Vector3.new(0, size.Y * 0.5, 0)
				local distance = math.max(size.X, size.Y, size.Z) * 2.1
				local spin
				spin = RunService.RenderStepped:Connect(function()
					if not viewport.Parent then
						spin:Disconnect()
						return
					end
					local angle = os.clock() * 0.9
					camera.CFrame = CFrame.lookAt(focus + Vector3.new(math.sin(angle) * distance, size.Y * 0.45, -math.cos(angle) * distance), focus)
				end)
			end
		end
		label({
			Position = UDim2.fromOffset(118, tileHeight / 2 - 28),
			Size = UDim2.new(1, -130, 0, 32),
			Font = Enum.Font.FredokaOne,
			TextSize = 28,
			TextColor3 = tint,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = string.upper(reward.crate) .. " CRATE",
			Parent = tile,
		})
		label({
			Position = UDim2.fromOffset(118, tileHeight / 2 + 6),
			Size = UDim2.new(1, -130, 0, 18),
			Font = Enum.Font.GothamMedium,
			TextSize = 14,
			TextColor3 = R.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "Added to your crates. Open it from the menu.",
			Parent = tile,
		})
	end
	-- The team modes' itemised pay (RewardService.TeamBreakdown): every line the card paid, two to a row,
	-- name on the left and what it paid on the right. The chips below are the totals, which the lines sum
	-- to exactly (a 2x SahurCoins pass is a line of its own).
	local lines = reward and type(reward.lines) == "table" and reward.lines or nil
	if lines and #lines > 0 then
		local breakdown = create("Frame", {
			Name = "Breakdown",
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 8,
			Parent = card,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.new(0.5, -5, 0, BREAKDOWN_ROW),
				CellPadding = UDim2.fromOffset(10, 3),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		for index, line in ipairs(lines) do
			if index > BREAKDOWN_MAX then
				break
			end
			local name = tostring(line.label or "")
			local count = tonumber(line.count)
			if count and line.id == "hold" then
				name ..= string.format(" %ds", count)
			elseif count and line.id == "time" then
				name ..= string.format(" %d min", count)
			elseif count and count > 0 then
				name ..= string.format(" ×%d", count)
			end
			local coins, xp = tonumber(line.coins) or 0, tonumber(line.xp) or 0
			local paid
			if coins > 0 and xp > 0 then
				paid = string.format("+%s  ·  %s XP", formatNumber(coins), formatNumber(xp))
			elseif xp > 0 then
				paid = string.format("+%s XP", formatNumber(xp))
			elseif line.id == "unlock" then
				paid = "NEW COSMETIC"
			elseif line.note then
				-- A line that pays no coins says what it gave instead (the win's Mythic Crate roll).
				paid = tostring(line.note)
			else
				paid = "+" .. formatNumber(coins)
			end
			-- TEAM BONUS lines (what only the team modes pay) are gold-edged, so the extra is seen as extra.
			local cell = create("Frame", {
				BackgroundColor3 = line.bonus and GOLD or R.Surface,
				-- The grid sizes the cell; the same size written here keeps a measuring harness honest.
				Size = UDim2.new(0.5, -5, 0, BREAKDOWN_ROW),
				BackgroundTransparency = line.id == "result" and 0 or (line.bonus and 0.82 or 0.4),
				BorderSizePixel = 0,
				LayoutOrder = index,
				Parent = breakdown,
			}, {
				rounded(6),
				line.bonus and create("UIStroke", { Color = GOLD, Thickness = 1, Transparency = 0.3 }) or nil,
			})
			label({
				Position = UDim2.fromOffset(8, 0),
				Size = UDim2.new(1, -(BREAKDOWN_PAID + 12), 1, 0),
				Font = line.id == "result" and Enum.Font.GothamBlack or Enum.Font.GothamBold,
				TextSize = 13,
				TextColor3 = line.id == "result" and headColor or (line.bonus and GOLD or R.Text),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = name,
				Parent = cell,
			})
			label({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -8, 0, 0),
				Size = UDim2.new(0, BREAKDOWN_PAID, 1, 0),
				Font = Enum.Font.GothamBold,
				TextSize = 12,
				TextColor3 = type(line.crate) == "string" and Rarity.Color(line.crate) or GOLD,
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = paid,
				Parent = cell,
			})
		end
	end

	local rewardRow = row(9, nil)
	rewardRow:FindFirstChildOfClass("UIListLayout").Wraps = true
	local any = false
	if reward then
		-- The team modes' extras, named: TEAM BONUS and its total, and the first win's Epic Crate.
		if (tonumber(reward.bonusCoins) or 0) > 0 then
			chip(rewardRow, "TEAM BONUS +" .. formatNumber(reward.bonusCoins), GOLD, 1)
			any = true
		end
		if type(reward.bonusCrate) == "string" then
			chip(rewardRow, "+1 " .. string.upper(reward.bonusCrate) .. " CRATE", Rarity.Color(reward.bonusCrate), 1)
			any = true
		end
		-- The battle royale win's Mythic Crate roll (RewardService.MythicLine): its odds, and whether it dropped.
		if type(reward.mythic) == "table" then
			chip(rewardRow, tostring(reward.mythic.chip), reward.mythic.crate and Rarity.Color(reward.mythic.crate) or R.TextMuted, 1)
			any = true
		end
		if (reward.coins or 0) > 0 then
			chip(rewardRow, "+" .. formatNumber(reward.coins) .. " COINS", GOLD, 2)
			any = true
		end
		if (reward.xp or 0) > 0 then
			chip(rewardRow, "+" .. formatNumber(reward.xp) .. " PASS XP", C.Storm, 3)
			any = true
		end
	end
	local progression = result.progression
	if progression and (progression.xp or 0) > 0 then
		local rankText
		if progression.prestige ~= progression.prestigeFrom then
			rankText = string.format("PRESTIGE %d", progression.prestige)
		elseif progression.rank ~= progression.rankFrom then
			rankText = string.format("RANK %d → %d", progression.rankFrom, progression.rank)
		else
			rankText = string.format("RANK %d  +%s XP", progression.rank, formatNumber(progression.xp))
		end
		chip(rewardRow, rankText, C.Green, 4)
		if (progression.cells or 0) > 0 then
			chip(rewardRow, "+" .. formatNumber(progression.cells) .. " CELLS", R.Info, 5)
		end
		any = true
	end
	if not any then
		rewardRow:Destroy()
		if not reward then
			label({
				Size = UDim2.new(1, 0, 0, 18),
				Font = Enum.Font.GothamMedium,
				TextSize = 14,
				TextColor3 = R.TextMuted,
				Text = "No placement reward this time",
				LayoutOrder = 7,
				Parent = card,
			})
		end
	end

	-- 6. Footer: countdown and close.
	local footer = create("Frame", {
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		LayoutOrder = 10,
		Parent = card,
	})
	local countdown = label({
		Size = UDim2.new(1, -130, 1, 0),
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = R.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = footer,
	})
	local close = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(120, 36),
		BackgroundColor3 = won and headColor or R.SurfaceAlt,
		AutoButtonColor = true,
		Font = Enum.Font.GothamBlack,
		Text = "CONTINUE",
		TextColor3 = won and R.AccentInk or R.Text,
		TextSize = 14,
		Parent = footer,
	}, { rounded(10) })
	close.Activated:Connect(hide)

	return won, titleScale, countdown
end

matchResults.OnClientEvent:Connect(function(result)
	if type(result) ~= "table" or result.rank == nil then
		return
	end
	showToken += 1
	local token = showToken

	local ok, won, titleScale, countdown = pcall(render, result)
	if not ok then
		warn("[ResultsScreen] couldn't draw the results: " .. tostring(won))
		clearCard()
		label({
			Size = UDim2.new(1, 0, 0, 72),
			Font = Enum.Font.FredokaOne,
			Text = "#" .. tostring(result.rank),
			TextColor3 = GOLD,
			TextSize = 56,
			Parent = card,
		})
		won, titleScale, countdown = false, nil, nil
	end

	screenGui.Enabled = true
	scrim.BackgroundTransparency = 1
	glow.BackgroundTransparency = 1
	TweenService:Create(scrim, TweenInfo.new(0.35), { BackgroundTransparency = 0.35 }):Play()
	TweenService:Create(glow, TweenInfo.new(0.6), { BackgroundTransparency = won and 0.25 or 0.6 }):Play()

	-- Scale to fit and pop in. This still runs before the new card's layout pass, so the AbsoluteSize
	-- watcher at the bottom re-fits once its real height lands.
	task.defer(function()
		if showToken ~= token then
			return
		end
		local target, height = fitScale()
		fit.token, fit.height = token, height
		popIn(target)
		if titleScale then
			TweenService:Create(titleScale, TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		runCounters(token, isCurrent)
	end)

	if won then
		confetti(90)
		if okSfx and Sfx and Sfx.Play then
			pcall(Sfx.Play, "CrateOpen")
		end
	end

	task.spawn(function()
		for left = SHOW_FOR, 1, -1 do
			if not isCurrent(token) then
				return
			end
			if countdown then
				countdown.Text = string.format("Back to the lobby in %d", left)
			end
			task.wait(1)
		end
		if showToken == token then
			hide()
		end
	end)
end)

-- Gone as soon as the server leaves the results phase.
matchChanged.OnClientEvent:Connect(function(state)
	if type(state) == "table" and state.state and state.state ~= "Results" then
		hide()
	end
end)

camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
	if screenGui.Enabled then
		cardScale.Scale = fitScale()
	end
end)

-- The show's fit reads the card before its first layout (a disabled ScreenGui isn't laid out), so it got
-- 0 on the first show and the last card's height after that: on a phone the first card, or the first
-- after a mode change, came out too big and CONTINUE fell off the screen. Re-fit when the real height
-- lands. The height is scale-free (fitScale), so the pop-in and hide tweens don't trip this.
card:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if not isCurrent(fit.token) then
		return
	end
	local target, height = fitScale()
	if math.abs(height - fit.height) < 4 then
		return
	end
	fit.height = height
	if fit.tween and fit.tween.PlaybackState == Enum.PlaybackState.Playing then
		-- Still popping in (the first layout lands a frame in): pop in at the right size instead.
		if math.abs(target - fit.target) > 0.005 then
			popIn(target)
		end
	else
		cardScale.Scale = target
	end
end)
