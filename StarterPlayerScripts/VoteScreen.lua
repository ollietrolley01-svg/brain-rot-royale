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

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))
-- What is drawn and what holds the mouse, in one place. See VoteCursor for why they are not the same
-- answer, and for why this screen could never free the cursor before (Oliver's #100).
local VoteCursor = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VoteCursor"))

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))

local create = UiKit.create
local Role, Type, Space, Radius, Stroke = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius, UiKit.Stroke

local VoteScreen = {}

-- THE VOTE ON A PAD (Jacob's device-compat question 2, answered by the coordinator 09-28): the vote has
-- buttons of its own and takes NEITHER the left stick NOR A, because the lobby is still walkable while it
-- is up and a player votes on the move. D-pad left / right moves a highlight across the cards, Y votes
-- for the highlighted one. Bound through ContextActionService above the game's own binds (the D-pad is
-- Quests / Inventory and Y the companion elsewhere) only while the interactive vote is up, and unbound
-- the moment it is not. The cards are NOT Selectable: a GuiService selection would take the stick.
VoteScreen.PadMoveAction = "BRR_VotePadMove"
VoteScreen.PadCastAction = "BRR_VotePadCast"
VoteScreen.PadHint = "◀ ▶ pick · Y vote"

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
		return string.format("Two teams, two objectives. Capture and hold them, first to %d. Respawns.", target)
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
-- `onMenuOpen(open)` is called with the INTERACTIVE vote's state, and it is the caller's job to write
-- the player attribute: a module a gallery can render has no player to set attributes on. Same split
-- as DropPicker.
function VoteScreen.new(options)
	local self = setmetatable({}, Screen)
	self.parent = options.parent
	self.onVote = options.onVote
	self.onMenuOpen = options.onMenuOpen
	self.zIndex = options.zIndex or 36
	self.touch = options.touch
	self.forcedInputKind = options.inputKind
	self.menuOpenHeld = false
	self.state = { open = false, candidates = {}, seconds = 0, ready = false }

	-- THE CURSOR FIX FOR #100, half one, and the only half that actually unlocks the mouse. A VISIBLE
	-- GuiButton with Modal = true frees the cursor for as long as it is up, which is the one thing
	-- that beats `CameraMode.LockFirstPerson` — Roblox's own camera relocks the mouse EVERY FRAME, so
	-- no one-shot MouseBehavior write survives it. Transparent, exactly like the inventory's overlay
	-- and MenuCursor's flag: a Modal button has to be Visible, it does not have to be seen, and the
	-- vote screen is not gaining a dim it was never designed with.
	--
	-- It follows the INTERACTIVE vote, not the screen's visibility — see VoteCursor.Screen.
	-- `options.noModal` exists for one reason: the gallery builds a deliberately broken screen with it
	-- to prove the check that reads these properties can actually fail.
	if not options.noModal then
		self.modal = create("TextButton", {
			Name = "VoteOverlay",
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromScale(0, 0),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Modal = true,
			Selectable = false,
			Active = true,
			Text = "",
			Visible = false,
			ZIndex = (options.zIndex or 36) - 1,
			Parent = options.parent,
		})
	end

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

-- Which WORDS to use -- "touch", "gamepad" or "keyboard" -- as distinct from which layout. isTouch
-- decides the shape (safe area, insets, the phone banner) and is rightly about the screen; this is
-- about the hands. The two-device test alone sent a console player down the keyboard branch, "Press
-- 1, 2 or 3" on a machine with no keys, because a console is neither touch nor keyboard (the
-- coordinator's sweep; HudClient's tips use the same three-way test). `options.inputKind` lets a
-- gallery or a probe force one.
function Screen:inputKind()
	if self.forcedInputKind then
		return self.forcedInputKind
	end
	if self:isTouch() then
		return "touch"
	end
	local ok, kind = pcall(function()
		local last = UserInputService:GetLastInputType()
		if string.find(last.Name, "Gamepad", 1, true)
			or (UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled) then
			return "gamepad"
		end
		return "keyboard"
	end)
	return ok and kind or "keyboard"
end

function Screen:Destroy()
	self:setPadBound(false)
	-- Release BEFORE the instances go. A screen torn down while holding the cursor leaves its claim
	-- outstanding with nothing left alive to release it, and the mouse stays free for the session.
	if self.menuOpenHeld then
		self.menuOpenHeld = false
		if self.onMenuOpen then
			self.onMenuOpen(false)
		end
	end
	if self.modal then
		self.modal:Destroy()
	end
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
-- THE ONE EXCEPTION IS THE CLOCK. MatchChanged re-renders this every second of the lobby for the
-- countdown alone, and a rebuild destroys the cards under the pointer: a press that straddles one
-- never fires Activated (the vote is silently not cast), the hover tint blinks off, and a pad's
-- selected card is destroyed. So when only the clock moved, only the timer and the bar move.
--
-- state = { open, candidates = { { id, mode, map, votes, mine } }, decided = id, seconds, ready, readyKey }
function Screen:Render(state)
	if state then
		self.state = state
	end
	state = self.state
	-- One definition of "drawn" and "holds the mouse", shared with VoteDropClient. The reveal is
	-- visible WITHOUT wanting the cursor: its cards are built inert (`Active = enabled and not
	-- decided`), so there is nothing to click, and claiming for it would switch combat off.
	local visible, wantsCursor = VoteCursor.Screen(state.open, state.decided, state.ready)
	self.root.Visible = visible
	if not visible then
		self:dropPadFocus()
	end
	if self.modal then
		self.modal.Visible = wantsCursor
	end
	-- ON A CHANGE ONLY. Render runs on every redraw — a snapshot arrives each time anyone in the
	-- lobby taps a card — and a callback fired per redraw would claim and release the cursor once per
	-- tap. Treating a repeat as a transition is the exact bug class this fix exists for; it is not
	-- being reintroduced two files from where it was found.
	if wantsCursor ~= self.menuOpenHeld then
		self.menuOpenHeld = wantsCursor
		if self.onMenuOpen then
			self.onMenuOpen(wantsCursor)
		end
	end
	-- The pad's own buttons, for exactly as long as a vote can be cast: not for the reveal, and not for a
	-- player who has not readied (their Y and D-pad stay the game's).
	self:setPadBound(visible and wantsCursor and state.decided == nil)
	if not visible then
		-- Hidden: the next showing draws from scratch rather than trusting what was left behind.
		self.layoutKey = nil
		return
	end
	if self.layoutKey ~= nil and self.layoutKey == self:layoutKeyFor() then
		self:updateClock()
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

-- The clock: the timer's number and the bar's fill. One definition for Layout and updateClock.
local function timerText(state)
	return tostring(math.max(0, math.floor(state.seconds or 0)))
end

local function barFill(state)
	return UDim2.fromScale(state.decided and 1 or math.clamp((state.seconds or 0) / math.max(state.total or 15, 1), 0, 1), 1)
end

-- Everything Layout draws EXCEPT the clock. Equal keys mean the cards on screen are already right.
function Screen:layoutKeyFor()
	local state = self.state
	local viewport = viewportOf()
	local parts = {
		tostring(state.open), tostring(state.decided), tostring(state.ready), tostring(state.readyKey),
		tostring(viewport.X), tostring(viewport.Y), tostring(self:isTouch()), tostring(self:inputKind()),
	}
	for _, candidate in ipairs(state.candidates or {}) do
		table.insert(parts, string.format("%s=%s:%s", tostring(candidate.id), tostring(candidate.votes or 0), tostring(candidate.mine)))
	end
	return table.concat(parts, ";")
end

function Screen:updateClock()
	if self.timerLabel then
		self.timerLabel.Text = timerText(self.state)
	end
	if self.timerBar then
		self.timerBar.Size = barFill(self.state)
	end
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
		-- Never a GuiService selection: that would take the left stick from walking. A pad moves the
		-- PadHighlight below with the D-pad instead (see VoteScreen.PadMoveAction).
		Selectable = false,
		ZIndex = self.zIndex + 1,
		Parent = parent,
	}, { create("UICorner", { CornerRadius = UDim.new(0, Radius.Card) }) })
	button:SetAttribute("CandidateId", candidate.id)

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

	-- The pad's highlight: its own frame with its own stroke (the card's one UIStroke says "mine"), inset
	-- so the card's ClipsDescendants cannot cut it. Shown by refreshPad, never by the layout.
	local padHighlight = create("Frame", {
		Name = "PadHighlight",
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = self.zIndex + 4,
		Parent = button,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, math.max(Radius.Card - 3, 0)) }),
		create("UIStroke", { Color = Role.Text, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	self.padFrames[order] = padHighlight

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

-- Binds (or unbinds) the pad's move and vote buttons. On a change only, like the cursor claim above.
function Screen:setPadBound(want)
	want = want == true
	if want == (self.padBound == true) then
		return
	end
	self.padBound = want
	if not want then
		pcall(function()
			ContextActionService:UnbindAction(VoteScreen.PadMoveAction)
			ContextActionService:UnbindAction(VoteScreen.PadCastAction)
		end)
		self:refreshPad()
		return
	end
	-- Start on the card this player voted for, else the first.
	self.padIndex = 1
	for index, candidate in ipairs(self.state.candidates or {}) do
		if candidate.mine then
			self.padIndex = index
		end
	end
	-- Every state is sunk, not just the press, so a D-pad release never reaches Quests or Inventory.
	pcall(function()
		local priority = Enum.ContextActionPriority.High.Value + 100
		ContextActionService:BindActionAtPriority("BRR_VotePadMove", function(_, inputState, input)
			if inputState == Enum.UserInputState.Begin then
				self:PadMove(input.KeyCode == Enum.KeyCode.DPadLeft and -1 or 1)
			end
			return Enum.ContextActionResult.Sink
		end, false, priority, Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight)
		ContextActionService:BindActionAtPriority("BRR_VotePadCast", function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				self:PadCast()
			end
			return Enum.ContextActionResult.Sink
		end, false, priority, Enum.KeyCode.ButtonY)
	end)
	self:refreshPad()
end

-- One step of the D-pad highlight, held at the ends rather than wrapping (three cards; a wrap reads as a
-- skip). Public so a gallery can draw the highlight without a controller.
function Screen:PadMove(step)
	local count = #(self.state.candidates or {})
	if count == 0 then
		return
	end
	self.padIndex = math.clamp((self.padIndex or 1) + step, 1, count)
	self:refreshPad(true)
end

-- Y: the highlighted card's vote, through the same onVote a click or a number key uses.
function Screen:PadCast()
	if not self.padBound then
		return
	end
	local candidate = (self.state.candidates or {})[self.padIndex or 0]
	if candidate and candidate.id ~= nil and self.onVote then
		self.onVote(candidate.id)
	end
end

-- The highlight is drawn only while the pad's buttons are bound AND the hands are on a pad (`pressed`: a
-- D-pad press just now, which is a pad whatever the last-input query says).
function Screen:refreshPad(pressed)
	local show = self.padBound == true and (pressed == true or self:inputKind() == "gamepad")
	for index, frame in pairs(self.padFrames or {}) do
		frame.Visible = show and index == self.padIndex
	end
end

function Screen:dropPadFocus()
	pcall(function()
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(self.root) then
			GuiService.SelectedObject = nil
		end
	end)
end

function Screen:Layout()
	-- No GuiService selection is carried across a rebuild any more: a selected card would take the left
	-- stick from walking. Anything left selected in here (it cannot be a card: they are not Selectable)
	-- is let go before its instance goes. The pad's highlight is an index, so it survives the rebuild.
	self:dropPadFocus()
	for _, child in ipairs(self.root:GetChildren()) do
		child:Destroy()
	end
	self.cards = {}
	self.padFrames = {}
	self.timerLabel, self.timerBar = nil, nil
	self.layoutKey = self:layoutKeyFor()
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
		self.timerLabel = UiParts.text(panel, form == "large" and Type.Display or Type.Title,
			timerText(state), Role.Accent, {
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
	self.timerBar = create("Frame", {
		Size = barFill(state),
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
		local button = self:card(holder, candidate, shape, cardW, cardH, index, decidedId, enabled)
		if candidate.id ~= nil then
			self.cards[candidate.id] = button
		end
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
		-- The vote takes neither the cursor nor the overlay from an unready player (VoteCursor.Screen),
		-- so both ways to ready up work from right here; say which they are, in the hands' own words.
		local kind = self:inputKind()
		if kind == "touch" then
			hint = "Not in the next match yet — tap READY UP at the top to vote."
		elseif kind == "gamepad" then
			hint = "Not in the next match yet — step on the ready pad on the airship, or READY UP at the top, to vote."
		elseif state.readyKey then
			hint = string.format("Not in the next match yet — press [%s] or click READY UP at the top to vote.", state.readyKey)
		else
			hint = "Ready up to vote — only players who are in the next match choose it."
		end
		hintColour = Role.Accent
	else
		-- Worded for the hands, not the screen: a console is neither touch nor keyboard, and the
		-- pad has no 1, 2 or 3.
		local kind = self:inputKind()
		if kind == "touch" then
			hint = "Tap a card to vote. Most votes wins; a tie is drawn at random."
		elseif kind == "gamepad" and self.padBound then
			-- Its own buttons, in their own glyphs: the stick and A stay walking and jumping.
			hint = VoteScreen.PadHint .. "  —  most votes wins; a tie is drawn at random."
		elseif kind == "gamepad" then
			hint = "Pick a card. Most votes wins; a tie is drawn at random."
		else
			hint = "Press 1, 2 or 3, or click a card. Most votes wins; a tie is drawn at random."
		end
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
	self:refreshPad()
end

return VoteScreen
