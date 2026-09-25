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
-- Teammates are green, whichever team you are on (Oliver, 2026-09-22: "change the friendly color for the
-- team gamemodes to green"). It used to be the team's own colour.
local FRIEND = Color3.fromRGB(80, 230, 110)
-- Enemies are filled and outlined. Friends get a light green fill and NO outline (Oliver, 2026-09-23
-- 16:11: "a bunch of the foliage and stuff is outlined the same way a friendly bot is"). With DepthMode
-- Occluded, Roblox traces the outline along the edge of whatever is in front of the character, so a bush,
-- fence or leaf covering a teammate got a green outline of its own. A fill is only drawn on the character's
-- own visible pixels, so it cannot spill onto anything else.
local ENEMY_FILL, FRIEND_FILL = 0.65, 0.72
-- Enemies lost their outline for the same reason (Oliver, 2026-09-25: trees, bushes and houses in battle royale
-- glowing red): the occluded outline was being traced round whatever stood in front of an enemy.
local ENEMY_OUTLINE, FRIEND_OUTLINE = 1, 1

local marks = {}

-- ROBLOX DRAWS AT MOST 31 HIGHLIGHTS AT ONCE, and silently drops the rest. A team match fills to 30
-- combatants, so 29 marks plus a dead body still carrying its mark, or a barricade preview, went over
-- and some players and bots showed no outline at all (Oliver, 2026-09-22: "sometimes the outline ...
-- isnt visible"). So only the nearest MAX_LIT are switched on, re-picked a few times a second, and a
-- dead body's mark is taken off straight away. The coloured name still marks everyone else.
local MAX_LIT = 24
local camera = workspace.CurrentCamera

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
	if mark.pin then
		mark.pin:Destroy()
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
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if mine == nil or theirs == nil or (humanoid and humanoid.Health <= 0) then
		clear(character)
		return
	end

	local enemy = theirs ~= mine
	local colour = enemy and ENEMY or FRIEND
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
		mark.highlight.Enabled = false -- the budget loop below switches it on
		mark.highlight.Parent = character
		if humanoid then
			-- A body is not a target (Oliver, 2026-09-22: "the glow ... disappears when the bot or player
			-- dies so you dont mistake corpses for enemies"). Died, and health reaching 0, both take the
			-- mark off at once -- Died alone can arrive late or not at all for a body another machine owns.
			humanoid.Died:Connect(function()
				clear(character)
			end)
			humanoid.HealthChanged:Connect(function(health)
				if health <= 0 then
					clear(character)
				end
			end)
		end
	end
	mark.highlight.FillColor = colour
	mark.highlight.OutlineColor = colour
	mark.highlight.FillTransparency = enemy and ENEMY_FILL or FRIEND_FILL
	mark.highlight.OutlineTransparency = enemy and ENEMY_OUTLINE or FRIEND_OUTLINE

	-- Teammates also get a small green marker over their heads (Oliver, 2026-09-23: "make it easier to tell
	-- what team youre on"). NOT through walls (Oliver, 14:39: "i dont wanna see the team marker icon through
	-- walls"): AlwaysOnTop is off, so a wall in front hides it like it hides the teammate. It is a
	-- BillboardGui, so it costs none of the 31-highlight budget.
	if enemy then
		if mark.pin then
			mark.pin:Destroy()
			mark.pin = nil
		end
	elseif not mark.pin or not mark.pin.Parent then
		local head = character:FindFirstChild("Head") or character.PrimaryPart
		if head then
			local pin = Instance.new("BillboardGui")
			pin.Name = "TeamPin"
			pin.AlwaysOnTop = false
			pin.LightInfluence = 0
			pin.MaxDistance = 600
			pin.Size = UDim2.fromOffset(22, 18)
			pin.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
			pin.Adornee = head
			local arrow = Instance.new("TextLabel")
			arrow.BackgroundTransparency = 1
			arrow.Size = UDim2.fromScale(1, 1)
			arrow.Font = Enum.Font.GothamBlack
			arrow.Text = "▼"
			arrow.TextScaled = true
			arrow.TextColor3 = FRIEND
			arrow.TextStrokeColor3 = Color3.fromRGB(10, 40, 18)
			arrow.TextStrokeTransparency = 0.2
			arrow.Parent = pin
			pin.Parent = head
			mark.pin = pin
		end
	end

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

-- The budget: nearest first, enemies ahead of friends at the same distance.
task.spawn(function()
	while true do
		task.wait(0.3)
		local eye = camera and camera.CFrame.Position
		local list = {}
		for character, mark in pairs(marks) do
			if mark.highlight then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if not character.Parent or (humanoid and humanoid.Health <= 0)
					or (humanoid and humanoid:GetState() == Enum.HumanoidStateType.Dead) then
					-- Gone, or a body: never outlined (the budget pass is the backstop for a missed Died).
					clear(character)
				else
					local pivot = character:GetPivot().Position
					local distance = eye and (pivot - eye).Magnitude or 0
					if mark.highlight.FillColor == ENEMY then -- enemies
						distance *= 0.8
					end
					table.insert(list, { mark = mark, distance = distance })
				end
			end
		end
		table.sort(list, function(a, b)
			return a.distance < b.distance
		end)
		for index, entry in ipairs(list) do
			local lit = index <= MAX_LIT
			if entry.mark.highlight.Enabled ~= lit then
				entry.mark.highlight.Enabled = lit
			end
		end
	end
end)

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
