-- Enemy aura for the team modes (Oliver's list #27): enemies glow red, and the glow does NOT show
-- through walls.
--
-- The "not through walls" half is the whole requirement, and it is the half a Highlight gets wrong
-- by default. `Highlight.DepthMode` defaults to `AlwaysOnTop`, which draws the fill and outline
-- over every piece of geometry between the camera and the character — that is a wallhack, handed to
-- everyone, and in a mode where the enemy is meant to be found it would remove the finding. The
-- only line that matters here is `DepthMode = Occluded`, and it is asserted in
-- tools/enemy_aura_probe.lua rather than trusted.
--
-- Teams come from the character attribute ModeTeams already sets (1 or 2), so this needs no remote
-- of its own and cannot disagree with the server about who is on which side. A character with no
-- Team attribute — the battle royale, the lobby — gets nothing, which is why this is inert outside
-- the team modes.

local Players = game:GetService("Players")

local player = Players.LocalPlayer

local AURA_COLOR = Color3.fromRGB(232, 92, 92)
local FILL_TRANSPARENCY = 0.65
local OUTLINE_TRANSPARENCY = 0.15

local auras = {}

local function myTeam()
	local character = player.Character
	return character and character:GetAttribute("Team")
end

local function clear(character)
	local aura = auras[character]
	if aura then
		aura:Destroy()
		auras[character] = nil
	end
end

local function refresh(character)
	if not character or not character.Parent then
		return
	end
	local mine = myTeam()
	local theirs = character:GetAttribute("Team")
	-- No team attribute anywhere means no team mode is running: nothing glows.
	local enemy = mine ~= nil and theirs ~= nil and theirs ~= mine and character ~= player.Character

	if not enemy then
		clear(character)
		return
	end
	if auras[character] then
		return
	end

	local aura = Instance.new("Highlight")
	aura.Name = "EnemyAura"
	aura.FillColor = AURA_COLOR
	aura.FillTransparency = FILL_TRANSPARENCY
	aura.OutlineColor = AURA_COLOR
	aura.OutlineTransparency = OUTLINE_TRANSPARENCY
	-- The requirement, in one property. Occluded means the highlight is hidden by anything drawn in
	-- front of it, so a wall hides the enemy exactly as it hides the character itself.
	aura.DepthMode = Enum.HighlightDepthMode.Occluded
	aura.Adornee = character
	aura.Parent = character
	auras[character] = aura
end

local function watch(character)
	refresh(character)
	character:GetAttributeChangedSignal("Team"):Connect(function()
		refresh(character)
	end)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			clear(character)
		end
	end)
end

local function follow(other)
	if other.Character then
		watch(other.Character)
	end
	other.CharacterAdded:Connect(watch)
	other.CharacterRemoving:Connect(clear)
end

for _, other in ipairs(Players:GetPlayers()) do
	if other ~= player then
		follow(other)
	end
end
Players.PlayerAdded:Connect(function(other)
	if other ~= player then
		follow(other)
	end
end)
Players.PlayerRemoving:Connect(function(other)
	if other.Character then
		clear(other.Character)
	end
end)

-- My own team arriving or changing flips who counts as an enemy, so every known character is
-- re-tested rather than only the one that changed.
local function reviewAll()
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and other.Character then
			refresh(other.Character)
		end
	end
end

player.CharacterAdded:Connect(function(character)
	character:GetAttributeChangedSignal("Team"):Connect(reviewAll)
	reviewAll()
end)
if player.Character then
	player.Character:GetAttributeChangedSignal("Team"):Connect(reviewAll)
	reviewAll()
end
