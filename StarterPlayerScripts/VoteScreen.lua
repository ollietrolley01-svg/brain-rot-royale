-- The pre-match vote: which MODE, on which MAP (Oliver's #2).
--
-- Three cards, ONE PER MODE — Battle Royale, Team Deathmatch, King of the Hill, in an order the
-- server shuffles — each on a DIFFERENT random map, so one tap picks both at once. That is the
-- whole design decision: a mode vote and a map vote as two screens would be two decisions and twice
-- the countdown, and a mode vote with the map fixed would hand the same map to three different
-- games.
--
-- Most votes wins; a tie among the leaders is drawn at random; a vote nobody cast goes to Battle
-- Royale because that is the main game. Only players who have READIED UP can vote — somebody
-- standing in the lobby with no intention of playing does not choose the match — and an unreadied
-- player sees the cards greyed with "Ready up to vote" rather than a screen that silently ignores
-- them. All of that is decided and enforced in ServerScriptService/Modules/VoteService.lua; this
-- file draws it and nothing more.
--
-- WHAT EACH CARD SAYS IS DERIVED, NEVER TYPED. The pitch line is built from the mode's own
-- scoreTarget and scoreLabel, so a card cannot claim "first to 50" while the server plays to 100 —
-- which is exactly what `GameModes.TeamDeathmatch.description` says today.
--
-- A ModuleScript so tools/gallery.ps1 can render it, and because HudClient's main chunk is three
-- locals from Luau's 200-local limit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))

local create = UiKit.create
local Role, Type, Space, Radius, Stroke = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius, UiKit.Stroke

local VoteScreen = {}

-- TEST SEAM. Never set by game code: a gallery frame can choose a width but not a viewport height,
-- and `short` is decided by height, so without this the short version ships unexercised.
VoteScreen.ViewportForTest = nil

local TERRAIN_SWATCH = {
	[Enum.Material.Grass] = Color3.fromRGB(92, 146, 70),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(84, 142, 60),
	[Enum.Material.Ground] = Color3.fromRGB(150, 124, 92),
	[Enum.Material.Sand] = Color3.fromRGB(214, 190, 140),
	[Enum.Material.Rock] = Color3.fromRGB(132, 126, 118),
}

local function textWidth(text, size, font)
	local ok, measured = pcall(function()
		return TextService:GetTextSize(text, size, font, Vector2.new(4000, 200)).X
	end)
	return ok and measured or #text * size * 0.58
end

-- Built from the mode's own numbers, so it cannot drift from what the server plays.
local function pitchFor(mode)
	if mode.id == "BattleRoyale" then
		return "Fifty in, one out. Storm, loot, and you pick where you drop."
	end
	local target = mode.scoreTarget
	local label = mode.scoreLabel or "points"
	if not target then
		return mode.description or ""
	end
	if label == "seconds held" then
		return string.format("Two teams, one hill. Hold it for %d seconds. Respawns.", target)
	end
	return string.format("Two teams. First to %d %s. Respawns.", target, label)
end

local function sizeTag(radius)
	if radius >= 1250 then
		return "Large map"
	elseif radius >= 1000 then
		return "Medium map"
	end
	return "Small map"
end

local function swatchColour(mapId)
	local preset = MapData.Get(mapId)
	return (preset and TERRAIN_SWATCH[preset.terrainMaterial]) or Color3.fromRGB(92, 146, 70)
end

--------------------------------------------------------------------------------

local Screen = {}
Screen.__index = Screen

-- `onVote(candidateId)` is called on a tap or a number key. `parent` is a ScreenGui.
function VoteScreen.new(options)
	local self = setmetatable({}, Screen)
	self.parent = options.parent
	self.onVote = options.onVote
	self.zIndex = options.zIndex or 36
	self.touch = options.touch
	self.state = { open = false, candidates = {}, seconds = 0, ready = false }
	self.root = create("Frame", {
		Name = "VoteScreen",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = self.zIndex,
		Parent = self.parent,
	})
	return self
end

function Screen:isTouch()
	if self.touch ~= nil then
		return self.touch
	end
	local ok, touch = pcall(function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end)
	return ok and touch or false
end

function Screen:Destroy()
	self.root:Destroy()
end

-- Which candidate a number key picks, so VoteDropClient does not have to know the card order.
function Screen:CandidateAt(index)
	local candidate = self.state.candidates[index]
	return candidate and candidate.id or nil
end

-- The whole screen is re-rendered from `state`; there is no incremental path to get out of step
-- with the server. A vote arrives every time anyone in the lobby taps a card, which on a 50-player
-- server is a handful of redraws of nine text labels — measured against the alternative of an
-- update path that can disagree with the tally it is drawing, that is the right trade.
--
-- state = { open, candidates = { { id, mode, map, votes, mine } }, decided = id, seconds, ready }
function Screen:Render(state)
	if state then
		self.state = state
	end
	state = self.state
	local visible = state.open == true or state.decided ~= nil
	self.root.Visible = visible
	if not visible then
		return
	end
	self:Layout()
end

function Screen:Relayout()
	if self.root.Visible then
		self:Layout()
	end
end

local function viewportOf()
	if VoteScreen.ViewportForTest then
		return VoteScreen.ViewportForTest
	end
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1280, 720)
end

-- One candidate. `shape` is "card" (large), "compact" (short) or "row" (tall).
function Screen:card(parent, candidate, shape, w, h, order, decidedId, enabled)
	local mode = candidate.mode
	local decided = decidedId ~= nil
	local isDecided = decidedId == candidate.id
	local button = create("TextButton", {
		Size = UDim2.fromOffset(w, h),
		BackgroundColor3 = Role.Surface,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ClipsDescendants = true,
		LayoutOrder = order,
		Active = enabled and not decided,
		Selectable = enabled and not decided,
		ZIndex = self.zIndex + 1,
		Parent = parent,
	}, { create("UICorner", { CornerRadius = UDim.new(0, Radius.Card) }) })

	-- EXACTLY ONE UIStroke. Roblox applies one per object, so a card that adds a "highlight" stroke
	-- next to its resting stroke gets whichever the engine picked — which is how a highlight ends up
	-- working on some cards and not others. The state decides the stroke's colour; it does not add
	-- another one. Border mode is required as well: on a TextButton the default Contextual mode
	-- strokes the TEXT, and this button has none.
	local highlighted = candidate.mine or isDecided
	create("UIStroke", {
		Color = isDecided and Role.Positive or (candidate.mine and Role.Accent or Role.Line),
		Thickness = highlighted and Stroke.Focus or Stroke.Hairline,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = button,
	})
	-- Everything the vote did not pick steps back once the vote is decided, so the winner reads at
	-- a glance from across the room.
	if decided and not isDecided then
		button.BackgroundTransparency = 0.55
	end
	-- Greyed, not hidden: an unreadied player can see exactly what they are missing, and the header
	-- says how to join in.
	if not enabled then
		button.BackgroundTransparency = 0.4
	end

	local ink = enabled and Role.Text or Role.TextMuted
	local votes = candidate.votes or 0

	if shape == "row" then
		create("Frame", {
			Size = UDim2.new(0, 6, 1, 0),
			BackgroundColor3 = mode.color,
			BackgroundTransparency = enabled and 0 or 0.4,
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 2,
			Parent = button,
		})
		local x, tallyW = Space.MD + 6, 92
		UiParts.text(button, Type.Heading, mode.name, ink, {
			Position = UDim2.fromOffset(x, Space.SM),
			Size = UDim2.fromOffset(w - x - tallyW - Space.MD, 24),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = self.zIndex + 2,
		})
		create("Frame", {
			Position = UDim2.fromOffset(x, Space.SM + 28),
			Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = swatchColour(candidate.map.id),
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 2,
			Parent = button,
		}, {
			create("UICorner", { CornerRadius = UDim.new(1, 0) }),
			create("UIStroke", { Color = Role.Base, Thickness = 2 }),
		})
		UiParts.text(button, Type.Label, candidate.map.name .. "  ·  " .. sizeTag(candidate.map.radius), Role.TextMuted, {
			Position = UDim2.fromOffset(x + 22, Space.SM + 28),
			Size = UDim2.fromOffset(w - x - 22 - tallyW - Space.MD, 16),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = self.zIndex + 2,
		})
		local tally = create("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -Space.SM, 0.5, 0),
			Size = UDim2.fromOffset(tallyW - Space.SM, 44),
			BackgroundColor3 = candidate.mine and Role.Accent or Role.SurfaceAlt,
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 2,
			Parent = button,
		}, { create("UICorner", { CornerRadius = UDim.new(0, Radius.Control) }) })
		UiParts.text(tally, Type.Heading, tostring(votes), candidate.mine and Role.AccentInk or ink, {
			Position = UDim2.fromOffset(0, 3),
			Size = UDim2.new(1, 0, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = self.zIndex + 3,
		})
		UiParts.text(tally, Type.Caption,
			isDecided and "NEXT" or (candidate.mine and "YOURS" or (votes == 1 and "VOTE" or "VOTES")),
			candidate.mine and Role.AccentInk or Role.TextMuted, {
			Position = UDim2.fromOffset(0, 25),
			Size = UDim2.new(1, 0, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = self.zIndex + 3,
		})
	else
		create("Frame", {
			Size = UDim2.new(1, 0, 0, 6),
			BackgroundColor3 = mode.color,
			BackgroundTransparency = enabled and 0 or 0.4,
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 2,
			Parent = button,
		})
		local inner = w - Space.MD * 2
		local y = Space.MD + 2
		UiParts.text(button, Type.Heading, mode.name, ink, {
			Position = UDim2.fromOffset(Space.MD, y),
			Size = UDim2.fromOffset(inner, 24),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = self.zIndex + 2,
		})
		y += 26
		if shape == "card" then
			UiParts.text(button, Type.Caption, pitchFor(mode), Role.TextMuted, {
				Position = UDim2.fromOffset(Space.MD, y),
				Size = UDim2.fromOffset(inner, 34),
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				ZIndex = self.zIndex + 2,
			})
			y += 40
		end
		local swatch = shape == "card" and 32 or 26
		create("Frame", {
			Position = UDim2.fromOffset(Space.MD, y),
			Size = UDim2.fromOffset(swatch, swatch),
			BackgroundColor3 = swatchColour(candidate.map.id),
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 2,
			Parent = button,
		}, {
			create("UICorner", { CornerRadius = UDim.new(1, 0) }),
			create("UIStroke", { Color = Role.Base, Thickness = 2 }),
		})
		UiParts.text(button, Type.Label, candidate.map.name, ink, {
			Position = UDim2.fromOffset(Space.MD + swatch + Space.SM, y),
			Size = UDim2.fromOffset(inner - swatch - Space.SM, 18),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = self.zIndex + 2,
		})
		UiParts.text(button, Type.Caption, sizeTag(candidate.map.radius), Role.TextMuted, {
			Position = UDim2.fromOffset(Space.MD + swatch + Space.SM, y + 18),
			Size = UDim2.fromOffset(inner - swatch - Space.SM, 14),
			ZIndex = self.zIndex + 2,
		})

		local text = string.format("%d VOTE%s", votes, votes == 1 and "" or "S")
		local pillW = textWidth(text, Type.Label.Size, Type.Label.Font) + Space.LG * 2
		local tally = create("Frame", {
			Position = UDim2.fromOffset(Space.MD, h - Space.MD - 30),
			Size = UDim2.fromOffset(pillW, 30),
			BackgroundColor3 = candidate.mine and Role.Accent or Role.SurfaceAlt,
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 2,
			Parent = button,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		UiParts.text(tally, Type.Label, text, candidate.mine and Role.AccentInk or ink, {
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = self.zIndex + 3,
		})
		if isDecided then
			UiParts.text(button, Type.Label, "PLAYING NEXT", Role.Positive, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromOffset(w - Space.MD, h - Space.MD - 26),
				Size = UDim2.fromOffset(inner - pillW - Space.SM, 20),
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = self.zIndex + 2,
			})
		elseif candidate.mine then
			UiParts.text(button, Type.Caption, "YOUR VOTE", Role.Accent, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromOffset(w - Space.MD, h - Space.MD - 24),
				Size = UDim2.fromOffset(inner - pillW - Space.SM, 18),
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = self.zIndex + 2,
			})
		end
	end

	if enabled and not decided then
		-- Hover and press by hand rather than through UiParts.interactive, for one reason: that
		-- helper parents a focus UIStroke of its own, and this card has already spent its single
		-- stroke on saying whether it is the one you voted for.
		local rest = Role.Surface
		button.MouseEnter:Connect(function()
			button.BackgroundColor3 = rest:Lerp(Color3.new(1, 1, 1), 0.12)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundColor3 = rest
		end)
		button.MouseButton1Down:Connect(function()
			button.BackgroundColor3 = rest:Lerp(Color3.new(0, 0, 0), 0.18)
		end)
		-- A finger has no "leave": a tap lands on the hover colour and stays there without this.
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				button.BackgroundColor3 = rest
			end
		end)
		button.Activated:Connect(function()
			if self.onVote then
				self.onVote(candidate.id)
			end
		end)
	end
	return button
end

function Screen:Layout()
	for _, child in ipairs(self.root:GetChildren()) do
		child:Destroy()
	end
	local state = self.state
	local viewport = viewportOf()
	local form = UiKit.form(viewport)
	local touch = self:isTouch()
	local safe = UiKit.safeArea(viewport, touch)
	local decidedId = state.decided
	local enabled = state.ready ~= false and decidedId == nil

	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = Role.Base,
		BorderSizePixel = 0,
		ZIndex = self.zIndex,
		Parent = self.root,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, Radius.Panel) }),
		create("UIStroke", { Color = Role.Line, Thickness = Stroke.Hairline }),
	})

	local shape, cardW, cardH, gap, width
	if form == "tall" then
		width = math.clamp(viewport.X - safe.Left - safe.Right, 300, 420)
		shape, cardW, cardH, gap = "row", width - Space.MD * 2, 80, Space.SM
	elseif form == "short" then
		shape, cardW, cardH, gap = "compact", 236, 150, Space.MD
		width = 3 * cardW + 2 * gap + Space.MD * 2
	else
		shape, cardW, cardH, gap = "card", 286, 236, Space.MD
		width = 3 * cardW + 2 * gap + Space.MD * 2
	end
	local inner = width - Space.MD * 2

	local title = decidedId and "NEXT MATCH" or "VOTE:  MODE & MAP"
	local headerStyle = form == "large" and Type.Title or Type.Heading
	local y = Space.MD
	UiParts.text(panel, headerStyle, title, Role.Text, {
		Position = UDim2.fromOffset(Space.MD, y),
		Size = UDim2.fromOffset(inner - 76, headerStyle.Size + 8),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = self.zIndex + 1,
	})
	if not decidedId then
		UiParts.text(panel, form == "large" and Type.Display or Type.Title,
			tostring(math.max(0, math.floor(state.seconds or 0))), Role.Accent, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromOffset(width - Space.MD, y - 4),
			Size = UDim2.fromOffset(72, 40),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = self.zIndex + 1,
		})
	end
	y += headerStyle.Size + 12

	local track = create("Frame", {
		Position = UDim2.fromOffset(Space.MD, y),
		Size = UDim2.fromOffset(inner, 4),
		BackgroundColor3 = Role.SurfaceAlt,
		BorderSizePixel = 0,
		ZIndex = self.zIndex + 1,
		Parent = panel,
	}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	create("Frame", {
		Size = UDim2.fromScale(decidedId and 1 or math.clamp((state.seconds or 0) / math.max(state.total or 15, 1), 0, 1), 1),
		BackgroundColor3 = decidedId and Role.Positive or Role.Accent,
		BorderSizePixel = 0,
		ZIndex = self.zIndex + 2,
		Parent = track,
	}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	y += 4 + Space.MD

	local holder = create("Frame", {
		Position = UDim2.fromOffset(Space.MD, y),
		Size = UDim2.fromOffset(inner, shape == "row" and (3 * cardH + 2 * gap) or cardH),
		BackgroundTransparency = 1,
		ZIndex = self.zIndex + 1,
		Parent = panel,
	}, {
		create("UIListLayout", {
			FillDirection = shape == "row" and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, gap),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, candidate in ipairs(state.candidates) do
		self:card(holder, candidate, shape, cardW, cardH, index, decidedId, enabled)
	end
	y += holder.Size.Y.Offset + Space.SM

	-- One line that says what happens next. Which line depends on the three things a player can be:
	-- not readied (so their vote would not count), voting, or watching the result.
	local hint, hintColour
	if decidedId then
		local winner
		for _, candidate in ipairs(state.candidates) do
			if candidate.id == decidedId then
				winner = candidate
			end
		end
		hint = winner and string.format("%s on %s. Building the map…", winner.mode.name, winner.map.name)
			or "Building the map…"
		hintColour = Role.Positive
	elseif not enabled then
		hint = "Ready up to vote — only players who are in the next match choose it."
		hintColour = Role.Accent
	elseif touch then
		hint = "Tap a card to vote. Most votes wins; a tie is drawn at random."
		hintColour = Role.TextMuted
	else
		hint = "Press 1, 2 or 3, or click a card. Most votes wins; a tie is drawn at random."
		hintColour = Role.TextMuted
	end
	UiParts.text(panel, Type.Caption, hint, hintColour, {
		Position = UDim2.fromOffset(Space.MD, y),
		Size = UDim2.fromOffset(inner, 32),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = self.zIndex + 1,
	})
	y += (form == "tall" and 32 or 18) + Space.MD

	panel.Size = UDim2.fromOffset(width, y)
	-- Below Roblox's top bar AND below the HUD's own banner, then centred in what is left. The
	-- banner's rect comes from PhoneLayout rather than a guess: on a portrait phone it sits where
	-- this panel would otherwise start, and the first render had the two overlapping by six pixels.
	local ceiling = safe.Top
	if touch then
		pcall(function()
			local rects = require(script.Parent:WaitForChild("PhoneLayout")).Rects(viewport)
			if rects and rects.banner then
				ceiling = math.max(ceiling, rects.banner.y + rects.banner.h + Space.SM)
			end
		end)
	end
	local bottomInset = touch and Space.LG or safe.Bottom
	-- Held a little high rather than dead centre: the lobby is behind this, and the ready button
	-- and the plaza are what a player looks at next.
	local top = ceiling + math.max(0, (viewport.Y - ceiling - bottomInset - y)) * 0.45
	panel.Position = UDim2.new(0.5, 0, 0, math.max(ceiling, math.floor(top)))
end

return VoteScreen
