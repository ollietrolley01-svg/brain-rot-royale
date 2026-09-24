-- Display podiums round the lobby plaza: one per player in the server (up to MAX_PODIUMS),
-- showing off whichever brainrot they've picked to feature.
--
-- Podiums are derived from the player list rather than claimed, so there is no ownership or
-- conflict logic to get wrong — someone joins, a podium appears; they leave, it goes. Each player
-- keeps their slot while they're in the server, and a podium is only rebuilt when what it shows
-- changes, so nobody else's podium blinks out and back when someone joins, leaves or trades.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local ShowcaseService = {}

-- Where the podiums stand, in the order they fill: { degrees, radius } round the plaza centre, with
-- 0 = +X (the arena) and 90 = +Z (the pier), as in LobbyService. A ring round the whole plaza cannot
-- work: at any radius it crosses the arena's ramps, the pitch or the market, and forty-odd podiums
-- on one ring stood inside each other. So they stand in arcs on the open paving: six on an inner
-- ring (r44) either side of the statue and across the market side of the tree, eight on the r70
-- ring between the arena, the boards and the pitch, and two out by the market at r90. Each halo is
-- at least 2 studs clear of everything the lobby builds, of the walk in from the pier and the
-- run-up to the ramps, and 4 clear of its neighbours: tools/showcase_layout_check.py builds the
-- real lobby and proves it for 1 to 50 players, so move a slot only with that check passing.
local SLOTS = {
	{ 127.3, 44 }, { 48.3, 44 },
	{ 113.9, 70 }, { 64.2, 70 }, { 130.6, 70 }, { 47.6, 70 }, { 147.2, 70 }, { 30.9, 70 },
	{ 257.1, 44 }, { 283.5, 44 }, { 230.6, 44 }, { 310.0, 44 },
	{ 312.6, 70 }, { 329.2, 70 },
	{ 204.0, 90 }, { 249.1, 90 },
}
-- One podium per slot: past this many players, the rest wait for a slot to free up.
ShowcaseService.MAX_PODIUMS = #SLOTS
local PODIUM_HEIGHT = 5

local container = nil
local spinConnection = nil
-- [player] = { slot, base, display, key }: the podium standing for each player who has one.
local podiums = {}

local function ensureContainer()
	if container and container.Parent then
		return container
	end
	container = Instance.new("Folder")
	container.Name = "Showcase"
	container.Parent = workspace
	-- A new folder holds none of the old podiums.
	podiums = {}
	return container
end

-- Where slot `index` stands, or nil past the last slot: the podium's foot, on the plaza's floor. (It
-- used to stand a stud below it, which buried the foot trim and the halo under the paving.)
local function slotPosition(index)
	local slot = SLOTS[index]
	if not slot then
		return nil
	end
	local angle = math.rad(slot[1])
	return MatchConfig.LobbyPosition + Vector3.new(math.cos(angle) * slot[2], 0, math.sin(angle) * slot[2])
end

-- What a player's podium shows. The same key means the podium standing is already right.
local function showcaseOf(player)
	local data = PlayerData.Get(player)
	local def = data and data.Showcase and BrainrotData.Get(data.Showcase) or nil
	if not def then
		return nil, player.DisplayName .. "|"
	end
	local level = BrainrotData.LevelForXp(data.CompanionXp[def.name] or 0)
	local stars = data.Stars[def.name] or 0
	return def, string.format("%s|%s|%d|%d", player.DisplayName, def.name, level, stars)
end

-- Returns the podium and, when it shows a brainrot, the display turning on it (a sibling in the
-- folder, where AmbientClient looks for it).
local function buildPodium(parent, position, player, def)
	local color = def and Rarity.Color(def.rarity) or Color3.fromRGB(70, 74, 92)

	local base = Instance.new("Part")
	base.Name = "Podium_" .. player.UserId
	base.Shape = Enum.PartType.Cylinder
	base.Size = Vector3.new(PODIUM_HEIGHT, 12, 12)
	base.CFrame = CFrame.new(position + Vector3.new(0, PODIUM_HEIGHT / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	base.Anchored = true
	base.Color = Color3.fromRGB(48, 52, 68)
	base.Material = Enum.Material.Marble

	-- A stepped top with a glowing rarity rim, so the podium frames whatever stands on it.
	local function trim(name, height, diameter, y, trimColor, material)
		local part = Instance.new("Part")
		part.Name = name
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(height, diameter, diameter)
		part.CFrame = CFrame.new(position + Vector3.new(0, y, 0)) * CFrame.Angles(0, 0, math.rad(90))
		part.Color = trimColor
		part.Material = material
		part.Anchored = true
		part.CanCollide = false
		part.Parent = base
		return part
	end
	local rim = trim("Rim", 0.5, 12.6, PODIUM_HEIGHT - 0.2, color, Enum.Material.Neon)
	trim("Top", 0.7, 10, PODIUM_HEIGHT + 0.2, Color3.fromRGB(70, 74, 92), Enum.Material.Slate)
	trim("Foot", 0.8, 13.2, 0.4, Color3.fromRGB(36, 38, 50), Enum.Material.Metal)
	-- A halo on the floor round the foot, and light spilling from the rim, so a rare brainrot's
	-- podium glows in its colour from across the plaza. The halo's top clears the plaza's paving
	-- (0.17) so it isn't hidden under it or flush with it.
	local halo = trim("Halo", 0.15, 16, 0.22, color, Enum.Material.Neon)
	halo.Transparency = 0.55
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 18
	light.Brightness = def and 1.4 or 0.4
	light.Parent = rim
	-- A slim pillar of light behind it, taller for rarer brainrots.
	local tier = def and (Rarity.Index[def.rarity] or 1) or 0
	if tier > 0 then
		local outward = (position - MatchConfig.LobbyPosition) * Vector3.new(1, 0, 1)
		outward = outward.Magnitude > 0.1 and outward.Unit or Vector3.new(0, 0, 1)
		local height = 8 + tier * 3
		local pillar = Instance.new("Part")
		pillar.Name = "Pillar"
		pillar.Size = Vector3.new(0.6, height, 0.6)
		pillar.CFrame = CFrame.new(position + outward * 6.2 + Vector3.new(0, height / 2 + 0.2, 0))
		pillar.Color = color
		pillar.Material = Enum.Material.Neon
		pillar.Transparency = 0.25
		pillar.Anchored = true
		pillar.CanCollide = false
		pillar.CanQuery = false
		pillar.CanTouch = false
		pillar.Parent = base
	end

	local nameplate = Instance.new("BillboardGui")
	-- Narrower than the 17-stud spacing of a full podium ring, so neighbours' plates don't touch.
	nameplate.Size = UDim2.fromScale(8, 2.4)
	nameplate.StudsOffsetWorldSpace = Vector3.new(0, 13, 0)
	nameplate.AlwaysOnTop = false
	nameplate.MaxDistance = MatchConfig.LobbyLabelDistance
	nameplate.Parent = base

	local owner = Instance.new("TextLabel")
	owner.Size = UDim2.fromScale(1, 0.38)
	owner.BackgroundTransparency = 1
	owner.Font = Enum.Font.GothamBold
	owner.Text = player.DisplayName
	owner.TextColor3 = Color3.fromRGB(230, 234, 244)
	owner.TextStrokeTransparency = 0.3
	owner.TextScaled = true
	owner.Parent = nameplate

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromScale(0, 0.38)
	title.Size = UDim2.fromScale(1, 0.38)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.Text = def and def.name or "— empty —"
	title.TextColor3 = color
	title.TextStrokeTransparency = 0.3
	title.TextScaled = true
	title.Parent = nameplate

	local subtitle = Instance.new("TextLabel")
	subtitle.Position = UDim2.fromScale(0, 0.76)
	subtitle.Size = UDim2.fromScale(1, 0.24)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	-- What it's worth and how it fights, so a podium doubles as a quick look at its companion stats.
	local ownerData = PlayerData.Get(player)
	local level = def and BrainrotData.LevelForXp(ownerData and ownerData.CompanionXp[def.name] or 0) or 1
	local stars = def and ownerData and ownerData.Stars[def.name] or 0
	local stats = def and BrainrotData.Stats(def, level, stars) or nil
	local starText = BrainrotData.StarText(stars)
	subtitle.Text = def and string.format("%s  •  Lv %d%s  •  %d coins  •  %s %d dmg", def.rarity, level,
		starText ~= "" and ("  " .. starText) or "", def.coinValue, stats.move, stats.damage)
		or "Set one from the menu"
	subtitle.TextColor3 = Color3.fromRGB(160, 166, 184)
	subtitle.TextStrokeTransparency = 0.45
	subtitle.TextScaled = true
	subtitle.Parent = nameplate

	-- Parented once the nameplate subtree is complete, so the podium replicates as one piece.
	-- Must stay above the early return below, or empty podiums would never appear.
	ZFight.Fix({ base })
	base.Parent = parent

	if not def then
		return base, nil
	end

	-- The brainrot itself, built from the same spec as the companion and inventory photo, on an
	-- invisible base named "Display" that AmbientClient turns as one piece.
	local display = Instance.new("Part")
	display.Name = "Display"
	display.Size = Vector3.new(1, 1, 1)
	display.Transparency = 1
	display.Anchored = true
	display.CanCollide = false
	display.CanQuery = false
	display.CFrame = CFrame.new(position + Vector3.new(0, PODIUM_HEIGHT + 3.4, 0))

	local model = BrainrotModels.Build(def, { scale = 1.3, cframe = display.CFrame, glow = color })
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			part.Parent = display
		end
	end
	model:Destroy()

	-- Parented last, with the creature already attached. This also means the client's
	-- ChildAdded hook only ever sees a finished display to spin.
	display.Parent = parent
	return base, display
end

local function clear(entry)
	entry.base:Destroy()
	if entry.display then
		entry.display:Destroy()
	end
end

-- Brings the podiums up to date with the player list and what each player is showcasing. Run on
-- every join, leave, showcase change, trade and match end; it only touches what changed.
function ShowcaseService.Refresh()
	local parent = ensureContainer()
	local players = Players:GetPlayers()

	local present = {}
	for _, player in ipairs(players) do
		present[player] = true
	end
	local taken = {}
	for player, entry in pairs(podiums) do
		if present[player] then
			taken[entry.slot] = true
		else
			clear(entry)
			podiums[player] = nil
		end
	end

	-- Anyone without a podium takes the first free slot, the rarest showcase first (then the lowest
	-- UserId); past the last slot they wait for one to free up. Nobody is moved off a podium for a
	-- rarer one: a podium that jumps about is worse than one that waits.
	local rank = {}
	for _, player in ipairs(players) do
		local def = showcaseOf(player)
		rank[player] = def and (Rarity.Index[def.rarity] or 0) or -1
	end
	table.sort(players, function(a, b)
		if rank[a] ~= rank[b] then
			return rank[a] > rank[b]
		end
		return a.UserId < b.UserId
	end)
	local nextFree = 1
	for _, player in ipairs(players) do
		if not podiums[player] then
			while taken[nextFree] do
				nextFree += 1
			end
			if not slotPosition(nextFree) then
				break
			end
			taken[nextFree] = true
			podiums[player] = { slot = nextFree }
		end
	end

	for player, entry in pairs(podiums) do
		local def, key = showcaseOf(player)
		if entry.key ~= key then
			if entry.base then
				clear(entry)
			end
			entry.base, entry.display = buildPodium(parent, slotPosition(entry.slot), player, def)
			entry.key = key
		end
	end
end

-- Displays are spun client-side in AmbientClient; spinning them here would replicate a
-- CFrame update per display, per frame, to every client.
function ShowcaseService.Start()
	ensureContainer()
end

function ShowcaseService.Stop()
	if spinConnection then
		spinConnection:Disconnect()
		spinConnection = nil
	end
end

return ShowcaseService
