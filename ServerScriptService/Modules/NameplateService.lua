-- Health nameplates above every combatant.
--
-- Built server-side and parented to the character so they replicate once and follow the rig
-- automatically. Roblox's default Humanoid name display is hidden in favour of these,
-- because it carries no health information and can't be styled.
--
-- Occlusion is deliberately NOT handled: a nameplate visible through a wall would be an
-- aimbot. Distance is capped instead, and the BillboardGui hides itself beyond it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))

local NameplateService = {}

local MAX_DISTANCE = 190

-- Plate size in studs. It used to be in pixels, which stays the same size on screen at any
-- distance — so a crowd of players far away became a pile of overlapping name tags. In studs
-- the plate shrinks with distance like the character it belongs to.
local PLATE_WIDTH = 4.4
local PLATE_HEIGHT = 1

-- The READY tag only means something in the lobby, so it only shows within this range of it.
-- The lobby floats far above the map, so nobody mid-match is ever this close.
local LOBBY_TAG_RANGE = 180

local function barColor(ratio)
	if ratio > 0.55 then
		return Color3.fromRGB(94, 214, 122)
	elseif ratio > 0.25 then
		return Color3.fromRGB(236, 196, 72)
	end
	return Color3.fromRGB(232, 92, 92)
end

-- `owner` is the player this character belongs to, if any. Their own plate is hidden from
-- them: in first person the camera sits at the head, so it would float right in their view.
-- `botTitle` gives a bot the title tag a titled player would have, so bots read as players.
function NameplateService.Attach(character, displayName, isBot, owner, botTitle)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	if not humanoid or not head then
		return
	end

	local existing = head:FindFirstChild("Nameplate")
	if existing then
		existing:Destroy()
	end

	-- Our plate replaces the built-in one rather than sitting alongside it.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Nameplate"
	billboard.PlayerToHideFrom = owner
	billboard.Size = UDim2.fromScale(PLATE_WIDTH, PLATE_HEIGHT)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = MAX_DISTANCE
	billboard.LightInfluence = 0

	-- A real player's name carries their level in gold, so a level 40 reads as one. That's their Rot
	-- Rank (ProgressionService), led by a star in their prestige's colour once they have one; the
	-- pass tier stands in until the profile has set a rank.
	local function nameText()
		local rank = owner and owner:GetAttribute("RotRank")
		if type(rank) == "number" then
			local prestige = owner:GetAttribute("Prestige")
			local star = ""
			if type(prestige) == "number" and prestige > 0 then
				local color = ProgressionData.PrestigeInfo(prestige).color
				star = string.format('<font color="#%02X%02X%02X">★%d</font> ', math.floor(color.R * 255 + 0.5),
					math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5), prestige)
			end
			return string.format('%s<font color="#FFC040">%d</font>  %s', star, rank, displayName)
		end
		local tier = owner and owner:GetAttribute("PassTier")
		if tier then
			return string.format('<font color="#FFC040">%d</font>  %s', tier, displayName)
		end
		return displayName
	end

	local label = Instance.new("TextLabel")
	label.Name = "PlayerName"
	label.Size = UDim2.fromScale(1, 0.44)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.RichText = true
	label.Text = nameText()
	label.TextColor3 = isBot and Color3.fromRGB(214, 218, 230) or Color3.fromRGB(255, 226, 150)
	label.TextStrokeTransparency = 0.35
	label.TextScaled = true
	label.Parent = billboard

	local labelCap = Instance.new("UITextSizeConstraint")
	labelCap.MaxTextSize = 24
	labelCap.Parent = label

	local barBack = Instance.new("Frame")
	barBack.Name = "BarBack"
	barBack.Position = UDim2.fromScale(0.12, 0.52)
	barBack.Size = UDim2.fromScale(0.76, 0.14)
	barBack.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
	barBack.BackgroundTransparency = 0.25
	barBack.BorderSizePixel = 0
	barBack.Parent = billboard

	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(1, 0)
	backCorner.Parent = barBack

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.fromScale(1, 1)
	bar.BackgroundColor3 = barColor(1)
	bar.BorderSizePixel = 0
	bar.Parent = barBack

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = bar

	-- Shield: a thin blue bar just above the health bar, from the humanoid's "Shield" attribute
	-- (WeaponService mirrors a player's loadout shield there; bots keep theirs there directly).
	local shieldBar = Instance.new("Frame")
	shieldBar.Name = "ShieldBar"
	shieldBar.Position = UDim2.fromScale(0.12, 0.45)
	shieldBar.Size = UDim2.fromScale(0, 0.06)
	shieldBar.BackgroundColor3 = Color3.fromRGB(80, 170, 255)
	shieldBar.BorderSizePixel = 0
	shieldBar.Visible = false
	shieldBar.Parent = billboard

	local shieldCorner = Instance.new("UICorner")
	shieldCorner.CornerRadius = UDim.new(1, 0)
	shieldCorner.Parent = shieldBar

	-- A bot's title, fixed for its life.
	if botTitle and not owner then
		local titleTag = Instance.new("TextLabel")
		titleTag.Name = "TitleTag"
		titleTag.Position = UDim2.fromScale(0, 0.7)
		titleTag.Size = UDim2.fromScale(1, 0.3)
		titleTag.BackgroundTransparency = 1
		titleTag.Font = Enum.Font.GothamBold
		titleTag.Text = botTitle
		titleTag.TextColor3 = Color3.fromRGB(255, 200, 80)
		titleTag.TextStrokeTransparency = 0.4
		titleTag.TextScaled = true
		titleTag.Parent = billboard
		local titleCap = Instance.new("UITextSizeConstraint")
		titleCap.MaxTextSize = 16
		titleCap.Parent = titleTag
	end

	-- "READY" under a real player's name while they're queued for the next match, so the lobby
	-- can see who's going in and who's staying put.
	local readyTag = nil
	if owner then
		readyTag = Instance.new("TextLabel")
		readyTag.Name = "ReadyTag"
		readyTag.Position = UDim2.fromScale(0, 0.7)
		readyTag.Size = UDim2.fromScale(1, 0.3)
		readyTag.BackgroundTransparency = 1
		readyTag.Font = Enum.Font.GothamBold
		readyTag.Text = "READY"
		readyTag.TextColor3 = Color3.fromRGB(110, 230, 140)
		readyTag.TextStrokeTransparency = 0.4
		readyTag.TextScaled = true
		readyTag.Visible = false
		readyTag.Parent = billboard

		local readyCap = Instance.new("UITextSizeConstraint")
		readyCap.MaxTextSize = 16
		readyCap.Parent = readyTag
	end

	-- Parented once the whole plate is built. The head is already live, so parenting first sent
	-- the label, bar and corners as separate replication steps — for every character, on every
	-- spawn.
	billboard.Parent = head

	local function update()
		local max = humanoid.MaxHealth
		local ratio = max > 0 and math.clamp(humanoid.Health / max, 0, 1) or 0
		bar.Size = UDim2.fromScale(ratio, 1)
		bar.BackgroundColor3 = barColor(ratio)
		billboard.Enabled = humanoid.Health > 0
	end

	humanoid:GetPropertyChangedSignal("Health"):Connect(update)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(update)
	update()

	local function updateShield()
		local shield = humanoid:GetAttribute("Shield") or 0
		shieldBar.Visible = shield > 0
		shieldBar.Size = UDim2.fromScale(0.76 * math.clamp(shield / MatchConfig.MaxShield, 0, 1), 0.06)
	end
	humanoid:GetAttributeChangedSignal("Shield"):Connect(updateShield)
	updateShield()

	if readyTag then
		local function updateReadyTag()
			local nearLobby = (head.Position - MatchConfig.LobbyPosition).Magnitude < LOBBY_TAG_RANGE
			-- READY takes the slot in the lobby; otherwise the title they've earned sits there.
			-- Assigning the same value doesn't replicate, so the poll below costs nothing
			-- unless the tag actually changes.
			local title = owner:GetAttribute("Title")
			if owner:GetAttribute("Ready") == true and nearLobby then
				readyTag.Text = "READY"
				readyTag.TextColor3 = Color3.fromRGB(110, 230, 140)
				readyTag.Visible = true
			elseif type(title) == "string" and title ~= "" then
				readyTag.Text = title
				readyTag.TextColor3 = Color3.fromRGB(255, 200, 80)
				readyTag.Visible = true
			else
				readyTag.Visible = false
			end
			-- A plaza of thirty players shouldn't be thirty nameplates from everywhere; in a
			-- match the full range is back, since knowing who's who matters there.
			billboard.MaxDistance = nearLobby and MatchConfig.LobbyNameplateDistance or MAX_DISTANCE
		end

		-- The attributes live on the Player, which outlives this character, so the connections
		-- have to be dropped with the plate or every respawn would leak them.
		local readyConnection = owner:GetAttributeChangedSignal("Ready"):Connect(updateReadyTag)
		local tierConnection = owner:GetAttributeChangedSignal("PassTier"):Connect(function()
			label.Text = nameText()
		end)
		local titleConnection = owner:GetAttributeChangedSignal("Title"):Connect(updateReadyTag)
		local rankConnection = owner:GetAttributeChangedSignal("RotRank"):Connect(function()
			label.Text = nameText()
		end)
		local prestigeConnection = owner:GetAttributeChangedSignal("Prestige"):Connect(function()
			label.Text = nameText()
		end)
		billboard.Destroying:Connect(function()
			readyConnection:Disconnect()
			tierConnection:Disconnect()
			titleConnection:Disconnect()
			rankConnection:Disconnect()
			prestigeConnection:Disconnect()
		end)

		-- Moving between the lobby and the map has no event of its own; check once a second.
		task.spawn(function()
			while billboard.Parent do
				updateReadyTag()
				task.wait(1)
			end
		end)
	end
end

function NameplateService.AttachPlayer(player, character)
	NameplateService.Attach(character, player.DisplayName, false, player)
end

function NameplateService.Start()
	local function hook(player)
		player.CharacterAdded:Connect(function(character)
			-- Head may not exist the instant the character appears.
			character:WaitForChild("Head", 10)
			NameplateService.AttachPlayer(player, character)
		end)
		if player.Character then
			NameplateService.AttachPlayer(player, player.Character)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)
end

NameplateService.MaxDistance = MAX_DISTANCE
NameplateService.StartHealth = MatchConfig.StartHealth

return NameplateService
