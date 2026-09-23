-- Kill feedback (Oliver, 2026-09-22: "make it more satisfying to get a kill").
--
-- HudClient already flashes "ELIM" on the hitmarker and plays the elimination thud. This adds the
-- payoff on top, for the shooter only:
--   * a two-note rising chime, higher with every kill in a chain (4 s between kills keeps it going)
--   * a badge that pops in under the crosshair with a bounce: ELIMINATED / HEADSHOT, then x2, x3...
--   * a quick bright flash round the screen edge, gold for a headshot
--   * a skull that rises and fades where the target went down
-- It's its own script because HudClient's main chunk is at Luau's 200-local limit. It listens to the
-- same DamageDealt remote, so it needs no server change.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local player = Players.LocalPlayer
local damageDealt = Remotes.Event("DamageDealt")

local ACCENT = Color3.fromRGB(255, 214, 72)
local HEAD = Color3.fromRGB(255, 170, 40)
local WHITE = Color3.new(1, 1, 1)
local CHAIN_WINDOW = 4

local gui = Instance.new("ScreenGui")
gui.Name = "KillFeedback"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 6
gui.Parent = player:WaitForChild("PlayerGui")

-- The edge flash: four gradients, like the low-health vignette, so the middle stays clear.
local flashEdges = {}
for _, side in ipairs({ "Top", "Bottom", "Left", "Right" }) do
	local vertical = side == "Top" or side == "Bottom"
	local edge = Instance.new("Frame")
	edge.Size = vertical and UDim2.new(1, 0, 0.22, 0) or UDim2.new(0.18, 0, 1, 0)
	edge.Position = (side == "Bottom" and UDim2.fromScale(0, 0.78)) or (side == "Right" and UDim2.fromScale(0.82, 0))
		or UDim2.fromScale(0, 0)
	edge.BackgroundColor3 = ACCENT
	edge.BackgroundTransparency = 1
	edge.BorderSizePixel = 0
	edge.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = (side == "Top" and 90) or (side == "Bottom" and 270) or (side == "Left" and 0) or 180
	gradient.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	gradient.Parent = edge
	table.insert(flashEdges, edge)
end

-- The badge under the crosshair.
local badge = Instance.new("Frame")
badge.AnchorPoint = Vector2.new(0.5, 0)
badge.Position = UDim2.new(0.5, 0, 0.5, 70)
badge.Size = UDim2.fromOffset(260, 74)
badge.BackgroundTransparency = 1
badge.Parent = gui
local badgeScale = Instance.new("UIScale")
badgeScale.Parent = badge

local mark = Instance.new("TextLabel")
mark.AnchorPoint = Vector2.new(0.5, 0)
mark.Position = UDim2.fromScale(0.5, 0)
mark.Size = UDim2.fromOffset(44, 44)
mark.BackgroundColor3 = Color3.fromRGB(30, 22, 40)
mark.BackgroundTransparency = 1
mark.Font = Enum.Font.FredokaOne
mark.Text = "✕"
mark.TextSize = 30
mark.TextColor3 = ACCENT
mark.TextTransparency = 1
mark.Parent = badge
Instance.new("UICorner", mark).CornerRadius = UDim.new(0.5, 0)
local markStroke = Instance.new("UIStroke")
markStroke.Thickness = 3
markStroke.Color = ACCENT
markStroke.Transparency = 1
markStroke.Parent = mark

local words = Instance.new("TextLabel")
words.AnchorPoint = Vector2.new(0.5, 0)
words.Position = UDim2.new(0.5, 0, 0, 48)
words.Size = UDim2.fromOffset(260, 26)
words.BackgroundTransparency = 1
words.Font = Enum.Font.FredokaOne
words.Text = ""
words.TextSize = 22
words.TextColor3 = WHITE
words.TextStrokeColor3 = Color3.fromRGB(20, 12, 30)
words.TextStrokeTransparency = 1
words.TextTransparency = 1
words.Parent = badge

local chain, lastKillAt, token = 0, -math.huge, 0

local function skullAt(position)
	if typeof(position) ~= "Vector3" then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Position = position + Vector3.new(0, 2.5, 0)
	anchor.Parent = workspace.CurrentCamera
	local board = Instance.new("BillboardGui")
	board.Size = UDim2.fromOffset(80, 80)
	board.AlwaysOnTop = true
	board.LightInfluence = 0
	board.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = "☠"
	label.TextScaled = true
	label.TextColor3 = WHITE
	label.TextStrokeTransparency = 0.3
	label.Parent = board
	TweenService:Create(board, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ StudsOffset = Vector3.new(0, 3, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.5),
		{ TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(1.1, function()
		anchor:Destroy()
	end)
end

damageDealt.OnClientEvent:Connect(function(_, wasKill, position, _, headshot, kind)
	if not wasKill or kind == "structure" then
		return
	end
	local now = os.clock()
	chain = (now - lastKillAt <= CHAIN_WINDOW) and chain + 1 or 1
	lastKillAt = now
	token += 1
	local mine = token

	-- Sound: two notes a step apart, the whole thing climbing with the chain.
	local base = 1 + math.min(chain - 1, 5) * 0.09
	Sfx.Play("KillConfirm", 0, base)
	task.delay(0.075, function()
		Sfx.Play("KillConfirm", 0, base * 1.26)
	end)
	if headshot then
		task.delay(0.15, function()
			Sfx.Play("KillConfirm", 0, base * 1.5)
		end)
	end

	-- Badge.
	local colour = headshot and HEAD or ACCENT
	mark.TextColor3 = colour
	markStroke.Color = colour
	-- The server's own streak banner already names DOUBLE KILL and up, so this only counts.
	local word = headshot and "HEADSHOT" or "ELIMINATED"
	if chain >= 2 then
		word ..= "  x" .. chain
	end
	words.Text = word
	words.TextColor3 = chain >= 2 and colour or WHITE
	for _, item in ipairs({ mark, words }) do
		item.TextTransparency = 0
	end
	mark.BackgroundTransparency = 0.15
	markStroke.Transparency = 0
	words.TextStrokeTransparency = 0.35
	badgeScale.Scale = 1.7 + math.min(chain - 1, 3) * 0.15
	TweenService:Create(badgeScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- Edge flash.
	for _, edge in ipairs(flashEdges) do
		edge.BackgroundColor3 = colour
		edge.BackgroundTransparency = 0.55
		TweenService:Create(edge, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }):Play()
	end

	skullAt(position)

	task.delay(0.9, function()
		if mine ~= token then
			return
		end
		local fade = TweenInfo.new(0.35)
		TweenService:Create(mark, fade, { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		TweenService:Create(markStroke, fade, { Transparency = 1 }):Play()
		TweenService:Create(words, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
end)
