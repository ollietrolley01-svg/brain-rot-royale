-- Friend from enemy, at a glance (Oliver's #95; grew out of #27, "enemies get a red aura and it
-- must NOT show through walls").
--
-- Two marks, because one is not enough at a glance: a coloured body, and a coloured name. The body
-- reads at range and in a firefight; the name reads when the body is behind cover or only a shoulder
-- is showing. Both come from the same test, so they can never disagree.
--
-- WHAT DECIDES A SIDE: the `Team` attribute ModeTeams writes on the CHARACTER (ModeTeams.lua:318,
-- :620, :636, :712). That is the server's own answer, it needs no remote, and it covers BOTS for
-- free -- a bot is a combatant with a token like any other, so it gets the attribute on the same
-- lines a player does. This is why the script watches workspace for characters carrying the
-- attribute rather than iterating Players: the previous version iterated `Players:GetPlayers()` and
-- so marked no bot at all, in a game where most of the opposition is bots.
--
-- A character with no `Team` attribute gets nothing, so this is inert in the battle royale and in
-- the lobby without needing to know what mode is running.
--
-- THE ONE LINE THAT MATTERS FOR FAIRNESS: `DepthMode = Occluded`. A Highlight defaults to
-- `AlwaysOnTop`, which draws through every wall in the map -- a wallhack handed to everyone. It is
-- asserted in tools/enemy_aura_gallery.lua against a planted `AlwaysOnTop` control that must glow
-- through the same wall, so the check can fail.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))

local player = Players.LocalPlayer

local ENEMY = Color3.fromRGB(232, 92, 92)
-- Enemies are filled; friends are outlined only. A fill on every teammate is a wash of colour over
-- half the screen in a 6v6, and the question "is that one mine" is answered by an edge just as well.
local ENEMY_FILL, FRIEND_FILL = 0.65, 1
local ENEMY_OUTLINE, FRIEND_OUTLINE = 0.15, 0.25

local marks = {}

local function myTeam()
	local character = player.Character
	return character and character:GetAttribute("Team")
end

local function nameLabel(character)
	local head = character:FindFirstChild("Head")
	local plate = head and head:FindFirstChild("Nameplate")
	return plate and plate:FindFirstChild("PlayerName")
end

local function clear(character)
	local mark = marks[character]
	if not mark then
		return
	end
	if mark.highlight then
		mark.highlight:Destroy()
	end
	-- The nameplate is the server's, and we only ever changed its colour: put the colour back rather
	-- than leaving our own on somebody else's instance.
	local label = nameLabel(character)
	if label and mark.nameWas then
		label.TextColor3 = mark.nameWas
	end
	marks[character] = nil
end

local function paint(character)
	if not character or not character.Parent or character == player.Character then
		return
	end
	local mine, theirs = myTeam(), character:GetAttribute("Team")
	if mine == nil or theirs == nil then
		clear(character)
		return
	end

	local enemy = theirs ~= mine
	local colour = enemy and ENEMY or GameModes.TeamColor(theirs)
	local mark = marks[character]
	if not mark then
		mark = {}
		marks[character] = mark
	end

	if not mark.highlight then
		mark.highlight = Instance.new("Highlight")
		mark.highlight.Name = "TeamMark"
		-- The requirement, in one property: hidden by anything in front of it, so a wall hides a
		-- marked character exactly as it hides the character.
		mark.highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		mark.highlight.Adornee = character
		mark.highlight.Parent = character
	end
	mark.highlight.FillColor = colour
	mark.highlight.OutlineColor = colour
	mark.highlight.FillTransparency = enemy and ENEMY_FILL or FRIEND_FILL
	mark.highlight.OutlineTransparency = enemy and ENEMY_OUTLINE or FRIEND_OUTLINE

	-- The name, in the same colour. The plate is built server-side a moment after the character, so
	-- this runs again when it appears (see `watch`), and the original colour is kept so `clear` can
	-- put it back.
	local label = nameLabel(character)
	if label then
		if mark.nameWas == nil then
			mark.nameWas = label.TextColor3
		end
		label.TextColor3 = colour
	end
end

local function repaintAll()
	for _, model in ipairs(workspace:GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("Team") ~= nil then
			paint(model)
		end
	end
end

local function watch(model)
	if not model:IsA("Model") then
		return
	end
	-- Attributes arrive after the model does -- ModeTeams sets Team when it places the body -- so a
	-- character is watched whether or not it has a side yet, and painted when it gets one.
	model:GetAttributeChangedSignal("Team"):Connect(function()
		paint(model)
	end)
	-- The nameplate is parented into the head after the character is in workspace. Without this the
	-- name keeps its default colour until something else repaints, which in a quiet match is never.
	model.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "PlayerName" and marks[model] then
			paint(model)
		end
	end)
	if model:GetAttribute("Team") ~= nil then
		paint(model)
	end
end

workspace.ChildAdded:Connect(watch)
workspace.ChildRemoved:Connect(clear)
for _, model in ipairs(workspace:GetChildren()) do
	watch(model)
end

-- My own side arriving or changing flips who is an enemy, so everything is re-tested rather than
-- only the character that changed.
player.CharacterAdded:Connect(function(character)
	character:GetAttributeChangedSignal("Team"):Connect(repaintAll)
	repaintAll()
end)
if player.Character then
	player.Character:GetAttributeChangedSignal("Team"):Connect(repaintAll)
	repaintAll()
end
