-- The team-mode scoreline at the top of the screen (Oliver's list #10 and #54).
--
--   Team Deathmatch   each team's progress to 100 eliminations
--   King of the Hill  match time, who has held the hill longest, and by how much
--
-- One readout for both, because they are the same question — who is ahead and by how much — and
-- because two separate HUDs would be two things to keep out of each other's way at the top of the
-- screen. In KOTH the score IS seconds held (GameModes calls it "seconds held", target 250), so
-- "held longest and by how much" is the leading score and the gap, with no extra plumbing.
--
-- It needs no new remote: GameMode already pushes ModeChanged with scores, target, secondsLeft,
-- hillStatus and hillHolder, and the server owns all of it.
--
-- "Sized so it does not get in the way" is the requirement Oliver wrote, so: 420x44 at the top
-- centre, under the match banner, in the slot the storm readout uses in the battle royale — which
-- is inert in a team mode, since there is no storm. It is 4% of a 1080p screen and it is never
-- drawn at all outside the two team modes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local GameModes = require(Shared:WaitForChild("GameModes"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create = UiKit.create
local Role, Type, Space, Radius = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius

local player = Players.LocalPlayer
local modeChanged = Remotes.Event("ModeChanged")
local matchChanged = Remotes.Event("MatchChanged")

local WIDTH, HEIGHT = 420, 44
local BAR_HEIGHT = 8

local gui = create("ScreenGui", {
	Name = "ModeScoreHud",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

local root = create("Frame", {
	Name = "Scoreline",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 72),
	Size = UDim2.fromOffset(WIDTH, HEIGHT),
	BackgroundColor3 = Role.Base,
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	Visible = false,
	Parent = gui,
}, { UiKit.rounded(Radius.Card) })
create("UIStroke", { Color = Role.Line, Thickness = 1, Transparency = 0.4, Parent = root })
local scale = create("UIScale", { Parent = root })

-- Left team, centre caption, right team. The two bars grow toward the middle so the gap between
-- them reads as the lead without anyone having to subtract.
local function side(anchorX, align)
	local holder = create("Frame", {
		AnchorPoint = Vector2.new(anchorX, 0),
		Position = UDim2.new(anchorX, anchorX == 0 and Space.MD or -Space.MD, 0, 6),
		Size = UDim2.fromOffset(150, HEIGHT - 12),
		BackgroundTransparency = 1,
		Parent = root,
	})
	local value = UiKit.create("TextLabel", {
		BackgroundTransparency = 1,
		Font = Type.Heading.Font,
		Text = "0",
		TextColor3 = Role.Text,
		TextSize = Type.Heading.Size,
		TextXAlignment = align,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = holder,
	})
	local track = create("Frame", {
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, BAR_HEIGHT),
		BackgroundColor3 = Role.SurfaceAlt,
		BorderSizePixel = 0,
		Parent = holder,
	}, { UiKit.rounded(Radius.Pill) })
	local fill = create("Frame", {
		AnchorPoint = Vector2.new(anchorX, 0),
		Position = UDim2.fromScale(anchorX, 0),
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Role.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { UiKit.rounded(Radius.Pill) })
	return value, fill
end

local leftValue, leftFill = side(0, Enum.TextXAlignment.Left)
local rightValue, rightFill = side(1, Enum.TextXAlignment.Right)

local caption = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(120, HEIGHT),
	BackgroundTransparency = 1,
	Font = Type.Label.Font,
	Text = "",
	TextColor3 = Role.TextMuted,
	TextSize = Type.Label.Size,
	Parent = root,
})

local function clock(seconds)
	seconds = math.max(math.floor(seconds or 0), 0)
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- A phone gets the same readout a little smaller, and never wider than the screen it is on. The
-- rest of the phone HUD is PhoneLayout's map; this is one element placing itself inside the same
-- top band.
local function fit()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
	local form = UiKit.form(viewport)
	if form == "large" then
		-- Measured against every other HUD cluster at 1920x1080, 1366x768, 1280x720 and 1024x768:
		-- zero overlaps in the storm readout's slot, which no team mode uses.
		scale.Scale = 1
		root.AnchorPoint = Vector2.new(0.5, 0)
		root.Position = UDim2.new(0.5, 0, 0, 72)
	else
		-- On a touch screen the desktop literals are NOT what is drawn — PhoneLayout replaces the
		-- whole HUD with its own map — so measuring this against them was measuring the wrong thing
		-- (it reported clashes with a compass that isn't where the model thought). It asks that map
		-- instead, and takes the storm line's band: the same reasoning as the desktop slot, since a
		-- team mode has no storm and that band is empty for the whole match.
		local layout = script.Parent:FindFirstChild("PhoneLayout")
		local band = layout and require(layout).Rects(viewport).stormLine
		scale.Scale = 0.8
		root.AnchorPoint = Vector2.new(0.5, 0)
		if band then
			root.Position = UDim2.new(0, band.x + band.w / 2, 0, band.y)
		else
			root.Position = UDim2.new(0.5, 0, 0, 72)
		end
	end
end

-- Oliver's #104: "the tdm hud at the top stays after the game". `state.scores ~= nil` below is
-- this HUD's only hide predicate, and nothing on the server ever sends a scores=nil push when a
-- team match ends -- GameMode.stopWorld (ServerScriptService/Modules/GameMode.lua, Match-flow's
-- file) tears down every other piece of server state and fires no client signal at all, so the
-- last real score just sits here forever: through the results screen, into the lobby, and into
-- whatever match comes next if it isn't a team mode (which raises no ModeChanged of its own).
-- Rather than depend on the server remembering to fire a hide event on every teardown path, this
-- also hides itself the moment the match itself isn't InProgress. MatchChanged already fires
-- reliably on every state change -- 27 other sites in HudClient key off the same field the same
-- way -- so this is ONE predicate that covers every path, not one that has to be threaded through
-- each of them.
local inProgress = false
matchChanged.OnClientEvent:Connect(function(state)
	inProgress = state ~= nil and state.state == "InProgress"
	if not inProgress then
		root.Visible = false
	end
end)

local function render(state)
	local teams = inProgress and state and state.scores ~= nil
	if not teams then
		root.Visible = false
		return
	end

	local scores = state.scores or { 0, 0 }
	local target = math.max(state.target or 1, 1)
	local koth = state.hillHolder ~= nil or state.hillStatus ~= nil

	leftValue.Text = tostring(scores[1] or 0)
	rightValue.Text = tostring(scores[2] or 0)
	leftValue.TextColor3 = GameModes.TeamColor(1)
	rightValue.TextColor3 = GameModes.TeamColor(2)
	leftFill.BackgroundColor3 = GameModes.TeamColor(1)
	rightFill.BackgroundColor3 = GameModes.TeamColor(2)
	leftFill.Size = UDim2.fromScale(math.clamp((scores[1] or 0) / target, 0, 1), 1)
	rightFill.Size = UDim2.fromScale(math.clamp((scores[2] or 0) / target, 0, 1), 1)

	if koth then
		-- "Who has held it longest and by how much", said as a gap rather than two numbers to
		-- subtract. The clock is what a player checks first, so it is the biggest thing here.
		local lead = math.abs((scores[1] or 0) - (scores[2] or 0))
		local leader = (scores[1] or 0) == (scores[2] or 0) and nil or ((scores[1] or 0) > (scores[2] or 0) and 1 or 2)
		caption.Text = clock(state.secondsLeft)
		if leader then
			caption.Text = clock(state.secondsLeft) .. "\n" .. GameModes.TeamName(leader) .. " +" .. lead .. "s"
			caption.TextColor3 = GameModes.TeamColor(leader)
		else
			caption.Text = clock(state.secondsLeft) .. "\nlevel"
			caption.TextColor3 = Role.TextMuted
		end
	else
		caption.Text = "FIRST TO " .. target
		caption.TextColor3 = Role.TextMuted
	end
	caption.RichText = false
	caption.TextWrapped = true

	root.Visible = true
	fit()
end

-- Same test the HUD makes, from the same remote: no loadout during a live match means this player
-- is not in it -- they joined late, or were eliminated and are watching. A team scoreline for a
-- match you are not playing is what Oliver saw stay up after the game (#104). This script has no
-- access to HudClient's `loadout`, and it does not need one: LoadoutChanged is a client remote and
-- any client script may listen, so this reads the same authority rather than inventing a signal.
--
-- The last state is cached because the two signals are independent and either can arrive first.
-- Hiding on the nil push alone is not enough: when the non-nil push arrives at spawn there may be
-- no further ModeChanged for a long time -- on TDM the next one is the first KILL, on KOTH the
-- first hill tick -- so the scoreline would stay blank for the opening seconds of the match, and a
-- player spawning into a game already at 3-1 would see nothing until someone scored again.
local inMatch = false
local lastState = nil

Remotes.Event("LoadoutChanged").OnClientEvent:Connect(function(newLoadout)
	local joined = newLoadout ~= nil
	if joined == inMatch then
		return
	end
	inMatch = joined
	if not inMatch then
		root.Visible = false
	elseif lastState then
		render(lastState)
	end
end)

modeChanged.OnClientEvent:Connect(function(state)
	lastState = state
	if not inMatch then
		root.Visible = false
		return
	end
	render(state)
end)

local camera = workspace.CurrentCamera
if camera then
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end
fit()
