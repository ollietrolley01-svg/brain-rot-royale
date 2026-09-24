-- Match HUD: health, ammo, weapon slots, storm timer, kill feed, the lobby map vote, and
-- the end-of-match results card. Built in code so there is no GUI to assemble in Studio.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local MapData = require(Shared:WaitForChild("MapData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local matchChanged = Remotes.Event("MatchChanged")
local stormChanged = Remotes.Event("StormChanged")
local loadoutChanged = Remotes.Event("LoadoutChanged")
local killFeed = Remotes.Event("KillFeed")
local matchResults = Remotes.Event("MatchResults")
local damageDealt = Remotes.Event("DamageDealt")
local damageTaken = Remotes.Event("DamageTaken")
local killStreakRemote = Remotes.Event("KillStreak")
local supplyDropRemote = Remotes.Event("SupplyDrop")
local shotFired = Remotes.Event("ShotFired")
local notify = Remotes.Event("Notify")
local voteChanged = Remotes.Event("VoteChanged")
local castVote = Remotes.Function("CastVote")
local equipRemote = Remotes.Event("EquipSlot")
local dropRemote = Remotes.Event("DropSlot")
local ItemModels = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ItemModels"))
local profileChanged = Remotes.Event("ProfileChanged")
local requestProfile = Remotes.Function("RequestProfile")
local companionAttackRemote = Remotes.Event("CompanionAttack")

local create, rounded, padding = UiKit.create, UiKit.rounded, UiKit.padding
local formatNumber = UiKit.formatNumber
local C = UiKit.Colors

-- #80: which pieces the phone layout has no room for right now. An upright phone has no compass, kill
-- feed, bounty or location line or speed pill (PhoneLayout.lua's portraitRects), and the layout hid them
-- once -- but the compass's own per-frame code, the bounty handler and the speed pill's refresh each
-- wrote `Visible = true` again the next time they ran, and the pieces came back at their DESKTOP spots
-- over the portrait HUD. So every piece the layout places says whether it wants to be shown through
-- `hudLayout.show`, which records the wish and draws the piece only if the layout has a place for it;
-- when the phone turns and the layout finds room again, it shows whatever was last wished for.
-- (tools/hud_layout_check.py runs this file and fails on any direct `.Visible =` on one of those pieces.)
-- One table, not three locals: the main chunk is close to Luau's 200-local limit.
local hudLayout = { dropped = {}, wanted = {} }
function hudLayout.show(gui, want)
	hudLayout.wanted[gui] = want == true
	gui.Visible = want == true and not hudLayout.dropped[gui]
end

local screenGui = create("ScreenGui", {
	Name = "BrrHud",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local matchState = { state = "Waiting", countdown = 0, aliveCount = 0, playerCount = 0, minPlayers = 2 }
local loadout = nil

--------------------------------------------------------------------------------
-- Top banner: match state, alive count, storm
--------------------------------------------------------------------------------

local banner = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 10),
	Size = UDim2.new(0, 440, 0, 56),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Parent = screenGui,
}, { rounded(12) })

local bannerTitle = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 28),
	Position = UDim2.new(0, 0, 0, 6),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "WAITING FOR PLAYERS",
	TextColor3 = C.Text,
	TextSize = 20,
	Parent = banner,
})

local bannerSub = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 20),
	Position = UDim2.new(0, 0, 0, 32),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	Text = "",
	TextColor3 = C.Muted,
	-- Shrinks to fit rather than running out of the banner (Oliver 15:37).
	TextScaled = true,
	Parent = banner,
}, { create("UITextSizeConstraint", { MaxTextSize = 14 }), create("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }) })

-- Ready up / stay in the lobby. A big pill beside the banner: amber and gently pulsing while
-- you're not ready, green with a tick once you are, with the live ready count underneath.
-- F toggles it too. Only readied players are pulled into a match, and the choice carries over
-- between matches.
local UserInputService = game:GetService("UserInputService")
local readyRemote = Remotes.Event("SetReady")

local readyButton = create("TextButton", {
	Position = UDim2.new(0.5, 232, 0, 8),
	Size = UDim2.fromOffset(230, 60),
	BackgroundColor3 = C.Accent,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Text = "",
	Visible = false,
	Parent = screenGui,
}, { rounded(14) })

local readyScale = create("UIScale", { Parent = readyButton })
local readyStroke = create("UIStroke", {
	Color = C.Accent,
	Thickness = 3,
	Transparency = 0.2,
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	Parent = readyButton,
})
create("UIGradient", {
	Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 205)),
	Rotation = 90,
	Parent = readyButton,
})

-- The tick is drawn from two bars rather than a glyph the font might not have.
local readyIcon = create("Frame", {
	Position = UDim2.new(0, 14, 0.5, -15),
	Size = UDim2.fromOffset(30, 30),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.78,
	BorderSizePixel = 0,
	Parent = readyButton,
}, { rounded(15) })

local tickShort = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.36, 0, 0.58, 0),
	Size = UDim2.fromOffset(4, 11),
	Rotation = -45,
	BackgroundColor3 = Color3.new(0, 0, 0),
	BorderSizePixel = 0,
	Parent = readyIcon,
})
local tickLong = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.57, 0, 0.47, 0),
	Size = UDim2.fromOffset(4, 18),
	Rotation = 40,
	BackgroundColor3 = Color3.new(0, 0, 0),
	BorderSizePixel = 0,
	Parent = readyIcon,
})
-- Not ready: a play arrow instead of the tick.
local readyArrow = create("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = ">",
	TextColor3 = Color3.new(0, 0, 0),
	TextSize = 20,
	Parent = readyIcon,
})

local readyTitle = create("TextLabel", {
	Position = UDim2.new(0, 54, 0, 6),
	Size = UDim2.new(1, -62, 0, 30),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "READY UP",
	TextColor3 = Color3.new(0, 0, 0),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextSize = 26,
	Parent = readyButton,
})

local readySub = create("TextLabel", {
	Position = UDim2.new(0, 54, 0, 35),
	Size = UDim2.new(1, -62, 0, 18),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = Color3.fromRGB(40, 32, 12),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextSize = 12,
	Parent = readyButton,
})

local function isReady()
	return player:GetAttribute("Ready") == true
end

-- Hidden only while you're actually in a match or it's loading; otherwise you can always
-- choose whether the next one includes you.
local function updateReadyButton()
	local inMatch = matchState.state == "Loading" or (matchState.state == "InProgress" and loadout ~= nil)
	readyButton.Visible = not inMatch

	local ready = isReady()
	readyButton.BackgroundColor3 = ready and C.Green or C.Accent
	readyStroke.Color = ready and C.Green or C.Accent
	readyTitle.Text = ready and "READY!" or "READY UP"
	tickShort.Visible = ready
	tickLong.Visible = ready
	readyArrow.Visible = not ready
	-- A key only means something on a keyboard (#86 M2): on a touch screen or a pad the pill itself is
	-- what you press.
	local lastInput = UserInputService:GetLastInputType()
	if lastInput == Enum.UserInputType.Touch or string.find(lastInput.Name, "Gamepad", 1, true) then
		readySub.Text = string.format("%d of %d ready  •  %s",
			matchState.readyCount or 0, matchState.playerCount or 0,
			ready and "tap to stay in lobby" or "tap to join next match")
	else
		readySub.Text = string.format("%d of %d ready  •  [%s] %s",
			matchState.readyCount or 0, matchState.playerCount or 0, Settings.KeyLabel("Ready"),
			ready and "stay in lobby" or "join next match")
	end
end

local readyHovered = false
local lastReadyToggle = 0

local function toggleReady()
	if not readyButton.Visible then
		return
	end
	local now = os.clock()
	if now - lastReadyToggle < 0.35 then
		return
	end
	lastReadyToggle = now
	Sfx.Play("UiClick", 0.08)
	readyRemote:FireServer(not isReady())
end

readyButton.Activated:Connect(toggleReady)
readyButton.MouseEnter:Connect(function()
	readyHovered = true
end)
readyButton.MouseLeave:Connect(function()
	readyHovered = false
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Settings.Key("Ready") and not player:GetAttribute("MenuOpen") then
		toggleReady()
	end
end)

-- The hint on the pill names whatever key Ready is bound to.
Settings.Changed:Connect(function()
	updateReadyButton()
end)

-- Not ready: the outline breathes and the pill swells slightly, so it's the first thing you
-- notice in the lobby. Ready: it settles down.
RunService.RenderStepped:Connect(function()
	if not readyButton.Visible then
		return
	end
	local t = os.clock()
	local target
	if isReady() then
		readyStroke.Transparency = 0.45
		target = 1
	else
		local wave = math.abs(math.sin(t * 3))
		readyStroke.Transparency = 0.15 + wave * 0.55
		target = 1 + wave * 0.035
	end
	if readyHovered then
		target += 0.05
	end
	readyScale.Scale += (target - readyScale.Scale) * 0.25
end)

--------------------------------------------------------------------------------
-- Crosshair + hitmarker
--------------------------------------------------------------------------------

local crosshair = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(64, 64),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = screenGui,
})

-- Hidden while the sights are up (CombatClient's SightsUp attribute): the red dot, the iron sights or
-- the scope is the aim point then, and ticks round it would only clutter the sight picture. It comes
-- back as soon as the gun drops to the hip.
local crosshairWanted = false
local function showCrosshair(wanted)
	crosshairWanted = wanted
	-- One crosshair at a time: while the player works a vehicle's gun, VehicleWeaponClient draws its own
	-- aim mark and this one stands down (#80: with a gun in hand both were drawn, one over the other).
	crosshair.Visible = wanted and not player:GetAttribute("SightsUp") and not player:GetAttribute("VehicleGunActive")
end
player:GetAttributeChangedSignal("SightsUp"):Connect(function()
	showCrosshair(crosshairWanted)
end)
player:GetAttributeChangedSignal("VehicleGunActive"):Connect(function()
	showCrosshair(crosshairWanted)
end)

-- The ticks and their spread, in a block of their own: nothing past here touches them, and the main
-- chunk is close to Luau's local limit.
do
	local BASE_GAP = 5
	local crosshairGap = BASE_GAP

	-- Four ticks rather than a dot: the gap widens when you fire, which is the only spread
	-- feedback the player gets.
	local crossArms = {}
	for _, dir in ipairs({ "Up", "Down", "Left", "Right" }) do
		local vertical = dir == "Up" or dir == "Down"
		local arm = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = vertical and UDim2.fromOffset(2, 8) or UDim2.fromOffset(8, 2),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Parent = crosshair,
		})
		crossArms[dir] = arm
	end

	local function layoutCrosshair()
		local gap = crosshairGap
		crossArms.Up.Position = UDim2.new(0.5, 0, 0.5, -gap - 4)
		crossArms.Down.Position = UDim2.new(0.5, 0, 0.5, gap + 4)
		crossArms.Left.Position = UDim2.new(0.5, -gap - 4, 0.5, 0)
		crossArms.Right.Position = UDim2.new(0.5, gap + 4, 0.5, 0)
	end

	layoutCrosshair()

	shotFired.OnClientEvent:Connect(function(shooter)
		if shooter == player then
			crosshairGap = math.min(crosshairGap + 5, 22)
		end
	end)

	RunService.RenderStepped:Connect(function(delta)
		if crosshairGap > BASE_GAP then
			crosshairGap = math.max(BASE_GAP, crosshairGap - delta * 34)
			layoutCrosshair()
		end
	end)
end

local hitmarker = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(80, 40),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "X",
	TextColor3 = C.Red,
	TextTransparency = 1,
	TextSize = 30,
	Parent = screenGui,
})

-- Floating damage numbers at the point of impact.
local GOLD = Color3.fromRGB(255, 210, 70)

-- Only hits on a person get a number: cover takes a tick and nothing else.
local function showDamageNumber(amount, position, wasKill, hitShield, headshot)
	if not position or not Settings.Get("DamageNumbers") then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Position = position + Vector3.new(math.random(-15, 15) / 10, 2, math.random(-15, 15) / 10)
	anchor.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(120, 44)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 260
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = tostring(math.floor(amount + 0.5)) .. (headshot and "!" or "")
	-- Blue while the hit is soaking into a shield, so you know the health bar hasn't moved yet;
	-- gold for a headshot.
	label.TextColor3 = wasKill and C.Accent or (headshot and GOLD or (hitShield and Color3.fromRGB(120, 190, 255) or Color3.fromRGB(255, 236, 200)))
	label.TextStrokeTransparency = 0.35
	label.TextSize = wasKill and 34 or (headshot and 31 or 26)
	label.Parent = billboard

	TweenService:Create(anchor, TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = anchor.Position + Vector3.new(0, 7, 0),
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.75), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()

	task.delay(0.85, function()
		anchor:Destroy()
	end)
end

damageDealt.OnClientEvent:Connect(function(amount, wasKill, position, hitShield, headshot, kind)
	-- Cover taking the shot (a map wall, a window, a barricade, a barrel): a small grey tick, and
	-- nothing else — no number and none of the hit cues (Oliver's call). Otherwise chipping a wall in
	-- a building sounded and looked exactly like hitting the player behind it.
	if kind == "structure" then
		hitmarker.Text = "+"
		hitmarker.TextSize = 22
		hitmarker.TextColor3 = Color3.fromRGB(188, 192, 198)
		hitmarker.TextTransparency = 0
		TweenService:Create(hitmarker, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
		return
	end
	hitmarker.Text = wasKill and (headshot and "HEADSHOT" or "ELIM") or "X"
	hitmarker.TextSize = headshot and 36 or 30
	-- Blue while you're still chewing through their shield; gold for a headshot.
	hitmarker.TextColor3 = wasKill and C.Accent or (headshot and GOLD or (hitShield and Color3.fromRGB(80, 170, 255) or C.Red))
	hitmarker.TextTransparency = 0
	TweenService:Create(hitmarker, TweenInfo.new(wasKill and 0.6 or 0.3), { TextTransparency = 1 }):Play()
	if headshot then
		-- A ding over a crack, on top of the elimination cue when it was the killing shot.
		Sfx.Play("Headshot", 0.06)
		Sfx.Play("HeadshotCrack", 0.1)
		if wasKill then
			Sfx.Play("Elimination")
		end
	else
		Sfx.Play(wasKill and "Elimination" or "HitConfirm", wasKill and 0 or 0.14)
	end
	showDamageNumber(amount, position, wasKill, hitShield, headshot)
end)

--------------------------------------------------------------------------------
-- Screen-edge state: low health, and standing in the storm
--------------------------------------------------------------------------------

-- A full-screen tinted frame with a transparent middle would need a 9-slice image, so the
-- vignette is four edge gradients instead. Same read, no assets.
local vignette = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = screenGui,
})

local vignetteEdges = {}
for _, side in ipairs({ "Top", "Bottom", "Left", "Right" }) do
	local vertical = side == "Top" or side == "Bottom"
	local edge = create("Frame", {
		Size = vertical and UDim2.new(1, 0, 0, 140) or UDim2.new(0, 180, 1, 0),
		Position = (side == "Bottom" and UDim2.new(0, 0, 1, -140))
			or (side == "Right" and UDim2.new(1, -180, 0, 0))
			or UDim2.fromScale(0, 0),
		BackgroundColor3 = C.Red,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = vignette,
	})

	local rotation = (side == "Top" and 90) or (side == "Bottom" and 270) or (side == "Left" and 0) or 180
	create("UIGradient", {
		Rotation = rotation,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = edge,
	})

	table.insert(vignetteEdges, edge)
end

local function setVignette(alpha, color)
	if alpha <= 0.01 then
		vignette.Visible = false
		return
	end
	vignette.Visible = true
	for _, edge in ipairs(vignetteEdges) do
		edge.BackgroundTransparency = 1 - alpha
		edge.BackgroundColor3 = color
	end
end

local zoneWarning = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.62, 0),
	Size = UDim2.fromOffset(520, 40),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "YOU'RE IN THE ROT - GET BACK IN",
	TextColor3 = C.Storm,
	TextStrokeTransparency = 0.4,
	TextTransparency = 1,
	TextSize = 28,
	Parent = screenGui,
})

-- The live storm, or nil while it's idle. Declared here, above its first reader, and assigned by the
-- StormChanged handler in "Storm readout" below. It used to be declared only down there, so this
-- loop read a global of the same name that was always nil and the storm vignette and the OUTSIDE
-- THE ZONE warning never showed.
local stormState = nil

RunService.RenderStepped:Connect(function()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")

	-- Not in this match -- joined late, or eliminated and watching -- means none of the storm's
	-- warnings are about this player. A spectator still has a body standing in the lobby, so without
	-- this the vignette pulses purple over someone who is not in the storm, and the readout counts
	-- down a zone they are not in. This is the test renderBanner has made since it was written.
	-- Written out rather than kept in a local: HudClient's main chunk is near Luau's 200-local limit
	-- and overrunning it fails the compile silently.
	if matchState.state == "InProgress" and not loadout then
		setVignette(0)
		zoneWarning.TextTransparency = 1
		return
	end

	if not humanoid or humanoid.Health <= 0 or not root then
		setVignette(0)
		zoneWarning.TextTransparency = 1
		return
	end

	local outside = false
	if stormState and stormState.center then
		local flat = Vector3.new(root.Position.X - stormState.center.X, 0, root.Position.Z - stormState.center.Z)
		outside = flat.Magnitude > stormState.radius
	end

	local ratio = humanoid.MaxHealth > 0 and humanoid.Health / humanoid.MaxHealth or 1

	-- Being in the storm reads purple and always shows; low health reads red and only
	-- below a third, so the two states never fight for the same signal.
	if outside then
		local pulse = 0.3 + math.abs(math.sin(os.clock() * 4)) * 0.22
		setVignette(pulse, C.Storm)
		zoneWarning.TextTransparency = 0.1
	elseif ratio < 0.34 then
		setVignette((0.34 - ratio) / 0.34 * 0.55, C.Red)
		zoneWarning.TextTransparency = 1
	else
		setVignette(0)
		zoneWarning.TextTransparency = 1
	end
end)

--------------------------------------------------------------------------------
-- Supply drops
--------------------------------------------------------------------------------

local activeDrop = nil

local dropBanner = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 128),
	Size = UDim2.fromOffset(480, 30),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Accent,
	TextStrokeTransparency = 0.5,
	TextTransparency = 1,
	TextSize = 18,
	Parent = screenGui,
})

-- The town or landmark nearest a point, from the attributes MapGenerator leaves on them, so a
-- supply drop can be announced as "near ROT DOCKS" rather than as a dot on the minimap.
local function nearestPlaceName(position)
	local map = workspace:FindFirstChild("Map")
	if not map or typeof(position) ~= "Vector3" then
		return nil
	end
	local best, bestDistance = nil, 260
	local function consider(child, centerAttribute, nameAttribute)
		local center = child:GetAttribute(centerAttribute)
		local name = child:GetAttribute(nameAttribute)
		if center and name then
			local distance = Vector2.new(center.X - position.X, center.Z - position.Z).Magnitude
			if distance < bestDistance then
				best, bestDistance = name, distance
			end
		end
	end
	for _, child in ipairs(map:GetChildren()) do
		consider(child, "TownCenter", "TownName")
	end
	local landmarks = map:FindFirstChild("Landmarks")
	if landmarks then
		for _, child in ipairs(landmarks:GetChildren()) do
			consider(child, "LandmarkCenter", "LandmarkName")
		end
	end
	return best
end

supplyDropRemote.OnClientEvent:Connect(function(info)
	if info.cleared or info.claimed then
		-- A claim only removes the marker if it's for the crate being shown; a newer drop
		-- may already have replaced it.
		-- Matched by integer id, not position: comparing float Vector3s that took different
		-- routes to the client is fragile.
		if info.cleared or (activeDrop and activeDrop.dropId == info.dropId) then
			activeDrop = nil
		end
		return
	end

	activeDrop = info

	local place = nearestPlaceName(info.position)
	local where = place and ("  •  near " .. string.upper(place)) or ""
	-- Each piece is guarded: a payload missing rarity or weapon must shorten the banner, not throw
	-- inside the handler and leave the marker stale.
	dropBanner.Text = info.incoming
		and ("SUPPLY DROP INBOUND" .. (info.rarity and ("  •  " .. string.upper(info.rarity)) or "") .. where)
		or ("SUPPLY DROP LANDED" .. (info.weapon and ("  •  " .. info.weapon) or "") .. where)
	dropBanner.TextColor3 = info.rarity and Rarity.Color(info.rarity) or C.Accent
	dropBanner.TextTransparency = 0
	Sfx.Play("CrateOpen")

	task.delay(6, function()
		TweenService:Create(dropBanner, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
	end)
end)

--------------------------------------------------------------------------------
-- Multi-kill callout
--------------------------------------------------------------------------------

local streakLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.34, 0),
	Size = UDim2.fromOffset(520, 60),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = C.Accent,
	TextStrokeTransparency = 1,
	TextTransparency = 1,
	TextSize = 44,
	Parent = screenGui,
})

local streakToken = 0

killStreakRemote.OnClientEvent:Connect(function(label, count)
	streakToken += 1
	local token = streakToken

	streakLabel.Text = label
	streakLabel.TextSize = math.min(44 + count * 4, 68)
	streakLabel.TextTransparency = 0
	streakLabel.TextStrokeTransparency = 0.4
	Sfx.Play("Elimination", 0.1)

	task.delay(1.3, function()
		if token ~= streakToken then
			return
		end
		TweenService:Create(streakLabel, TweenInfo.new(0.45), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
	end)
end)

--------------------------------------------------------------------------------
-- "Now entering" town banner
--------------------------------------------------------------------------------

-- Towns carry TownName / TownCenter / TownRadius attributes (set in MapGenerator), which
-- replicate even while the town's parts are streamed out. Checked twice a second rather
-- than every frame, and announced once on the way in rather than repeatedly while inside.
local townLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 160),
	Size = UDim2.fromOffset(520, 34),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = Color3.fromRGB(255, 244, 214),
	TextStrokeTransparency = 1,
	TextTransparency = 1,
	TextSize = 28,
	Parent = screenGui,
})

local currentTown = nil
local townToken = 0

local function townAt(position)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	for _, child in ipairs(map:GetChildren()) do
		local center = child:GetAttribute("TownCenter")
		local radius = child:GetAttribute("TownRadius")
		if center and radius and Vector2.new(position.X - center.X, position.Z - center.Z).Magnitude < radius then
			return child:GetAttribute("TownName")
		end
	end
	return nil
end

task.spawn(function()
	-- #135 (Oliver 09-22): entering a town showed TWO popups -- this "NOW ENTERING" banner and the
	-- "ENTERING ..." one further down, which already covers towns and landmarks. This one is off.
	do
		return
	end
	while true do
		task.wait(0.5)

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local name = nil
		if matchState.state == "InProgress" and root then
			name = townAt(root.Position)
		end

		if name ~= currentTown then
			currentTown = name
			if name then
				townToken += 1
				local token = townToken
				townLabel.Text = "NOW ENTERING  " .. string.upper(name)
				townLabel.TextTransparency = 0
				townLabel.TextStrokeTransparency = 0.4

				task.delay(2.2, function()
					if token ~= townToken then
						return
					end
					TweenService:Create(townLabel, TweenInfo.new(0.6), {
						TextTransparency = 1,
						TextStrokeTransparency = 1,
					}):Play()
				end)
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Damage direction indicator
--------------------------------------------------------------------------------

damageTaken.OnClientEvent:Connect(function(_amount, attackerPosition, headshot)
	if headshot then
		Sfx.Play("HeadshotTaken", 0.1)
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not attackerPosition then
		return
	end

	-- Angle between where the camera faces and where the shot came from, so the arc sits
	-- on the edge of the screen in that direction.
	local toAttacker = attackerPosition - root.Position
	local flat = Vector3.new(toAttacker.X, 0, toAttacker.Z)
	if flat.Magnitude < 0.1 then
		return
	end

	local look = camera.CFrame.LookVector
	local lookFlat = Vector3.new(look.X, 0, look.Z)
	if lookFlat.Magnitude < 0.1 then
		return
	end

	local angle = math.atan2(
		lookFlat.Unit:Cross(flat.Unit).Y,
		lookFlat.Unit:Dot(flat.Unit)
	)

	local arc = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 150),
		BackgroundColor3 = C.Red,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Rotation = math.deg(-angle),
		Parent = screenGui,
	}, { rounded(2) })

	-- Offset outward along its own rotation so it reads as pointing, not a bar on the face.
	arc.Position = UDim2.new(
		0.5, math.sin(-angle) * 170,
		0.5, -math.cos(-angle) * 170
	)

	TweenService:Create(arc, TweenInfo.new(0.9), { BackgroundTransparency = 1 }):Play()
	task.delay(1, function()
		arc:Destroy()
	end)
end)

--------------------------------------------------------------------------------
-- Bottom-left: health
--------------------------------------------------------------------------------

local healthFrame = create("Frame", {
	Position = UDim2.new(0, 16, 1, -96),
	Size = UDim2.new(0, 280, 0, 80),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}, { rounded(12), padding(12) })

local healthText = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "100",
	TextColor3 = C.Green,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextSize = 24,
	Parent = healthFrame,
})

-- The shield bar sits right above health, blue, and fills from shield potions.
local SHIELD_COLOR = Color3.fromRGB(80, 170, 255)

local shieldBarBg = create("Frame", {
	Position = UDim2.new(0, 0, 0, 28),
	Size = UDim2.new(1, 0, 0, 8),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	Parent = healthFrame,
}, { rounded(4) })

local shieldBar = create("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = SHIELD_COLOR,
	BorderSizePixel = 0,
	Parent = shieldBarBg,
}, { rounded(4) })

local healthBarBg = create("Frame", {
	Position = UDim2.new(0, 0, 0, 40),
	Size = UDim2.new(1, 0, 0, 12),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	Parent = healthFrame,
}, { rounded(6) })

local healthBar = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = C.Green,
	BorderSizePixel = 0,
	Parent = healthBarBg,
}, { rounded(6) })

-- The shield number, on the right of the health number.
local healsText = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = SHIELD_COLOR,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 20,
	Parent = healthFrame,
})

--------------------------------------------------------------------------------
-- Companion panel and speed boost pill (above health, during a match)
--------------------------------------------------------------------------------

local companionDef = nil
local companionLevel = 1
local companionStars = 0
local companionMoveText = ""

-- How many matches this player has played, from the profile; 0 turns on the new-player tips.
local profileMatches = nil
local tipIndex = 0
local NEW_PLAYER_TIPS = {
	-- Keys as {ActionId}, filled in with this player's own binding when shown (#86 M3).
	"Step on the green pad or press {Ready} to ready up for the next match",
	"The buttons on the left: shop, brainrots, progress, Robux and settings",
	"Loot guns, heals, shields and items — eight slots, keys {Slot1} to {Slot8} ({NextSlot} cycles)",
	"Equip a brainrot as your companion and press {Companion} to use its move in a fight",
	"Try the Cloud Climb up the tree, kick a ball into the goal, spin the daily wheel",
	"Stay inside the zone — the purple storm wall hurts. Last one standing wins a Legendary Crate",
	"Press {ToggleCamera} to switch to a third-person camera; every key is rebindable in Settings",
}
-- When the companion's move is ready again, from the cooldown in its last attack broadcast.
local abilityReadyAt = 0

local companionFrame = create("Frame", {
	Position = UDim2.new(0, 16, 1, -166),
	Size = UDim2.fromOffset(300, 62),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}, { rounded(10) })

local companionStroke = create("UIStroke", {
	Color = C.Accent,
	Thickness = 2,
	Transparency = 1,
	Parent = companionFrame,
})

local companionDot = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0, 23, 0.5, 0),
	Size = UDim2.fromOffset(22, 22),
	BackgroundColor3 = C.Accent,
	BorderSizePixel = 0,
	Parent = companionFrame,
}, { rounded(11) })

local companionName = create("TextLabel", {
	Position = UDim2.new(0, 44, 0, 5),
	Size = UDim2.new(1, -150, 0, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Text,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextSize = 14,
	Parent = companionFrame,
})

local companionMove = create("TextLabel", {
	Position = UDim2.new(0, 44, 0, 24),
	Size = UDim2.new(1, -52, 0, 16),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	Text = "",
	TextColor3 = C.Muted,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextSize = 12,
	Parent = companionFrame,
})

-- "READY [G]" or the seconds left on the move's cooldown.
local companionStatus = create("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -10, 0, 5),
	Size = UDim2.fromOffset(100, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Green,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 13,
	Parent = companionFrame,
})

local companionBar = create("Frame", {
	Position = UDim2.new(0, 44, 0, 45),
	Size = UDim2.new(1, -56, 0, 8),
	BackgroundColor3 = C.PanelAlt,
	BorderSizePixel = 0,
	Parent = companionFrame,
}, { rounded(4) })

local companionBarFill = create("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = C.Green,
	BorderSizePixel = 0,
	Parent = companionBar,
}, { rounded(4) })

local speedPill = create("TextLabel", {
	Position = UDim2.new(0, 16, 1, -202),
	Size = UDim2.fromOffset(150, 28),
	BackgroundColor3 = Color3.fromRGB(40, 150, 190),
	BorderSizePixel = 0,
	Font = Enum.Font.FredokaOne,
	Text = "SPEED BOOST",
	TextColor3 = Color3.new(1, 1, 1),
	-- Scaled into the box, up to 16: with two effects on at once the line is longer than the pill.
	TextScaled = true,
	Visible = false,
	Parent = screenGui,
}, { rounded(14), create("UITextSizeConstraint", { MaxTextSize = 16 }), padding(4) })

local function updateCompanionWidget()
	local show = companionDef ~= nil and loadout ~= nil
	hudLayout.show(companionFrame, show)
	if not show then
		return
	end
	local stats = BrainrotData.Stats(companionDef, companionLevel, companionStars)
	local color = Rarity.Color(companionDef.rarity)
	companionDot.BackgroundColor3 = color
	companionStroke.Color = color
	local starText = BrainrotData.StarText(companionStars)
	companionName.Text = string.format("%s  •  Lv %d%s", companionDef.name, companionLevel, starText ~= "" and ("  " .. starText) or "")
	companionName.TextColor3 = color
	companionMoveText = string.format("%s  •  %d dmg  •  %.1fs cooldown", stats.move, stats.damage, stats.cooldown)
	companionMove.Text = companionMoveText
end

-- Your companion's model, found by its owner attribute. Rescanned at most twice a second.
local myCompanionModel = nil
local lastCompanionScan = 0

local function findMyCompanion()
	if myCompanionModel and myCompanionModel.Parent then
		return myCompanionModel
	end
	local now = os.clock()
	if now - lastCompanionScan < 0.5 then
		return nil
	end
	lastCompanionScan = now
	myCompanionModel = nil
	local folder = workspace:FindFirstChild("Companions")
	if folder then
		for _, model in ipairs(folder:GetChildren()) do
			if model:GetAttribute("OwnerUserId") == player.UserId then
				myCompanionModel = model
				break
			end
		end
	end
	return myCompanionModel
end

-- Health, cooldown and the downed state.
RunService.RenderStepped:Connect(function()
	if not companionFrame.Visible or not companionDef then
		return
	end

	if player:GetAttribute("CompanionFallen") then
		companionStatus.Text = "DOWNED"
		companionStatus.TextColor3 = C.Red
		companionMove.Text = "Out for this match — back for the next one"
		companionBarFill.Size = UDim2.fromScale(0, 1)
		return
	end
	companionMove.Text = companionMoveText

	local model = findMyCompanion()
	local health = model and model:GetAttribute("Health")
	local maxHealth = model and model:GetAttribute("MaxHealth")
	if health and maxHealth and maxHealth > 0 then
		local fraction = math.clamp(health / maxHealth, 0, 1)
		companionBarFill.Size = UDim2.fromScale(fraction, 1)
		companionBarFill.BackgroundColor3 = fraction > 0.35 and C.Green or C.Red
	end

	local remaining = abilityReadyAt - os.clock()
	if remaining > 0 then
		companionStatus.Text = string.format("%.1fs", remaining)
		companionStatus.TextColor3 = C.Muted
	else
		companionStatus.Text = "READY  [" .. Settings.KeyLabel("Companion") .. "]"
		companionStatus.TextColor3 = C.Green
	end
end)

--------------------------------------------------------------------------------
-- Stamina bar (movement tab: StarterPlayerScripts/StaminaBar draws it, MovementState feeds it)
--------------------------------------------------------------------------------

-- In a do-block: this script's main chunk is close to Luau's 200-local limit.
do
	local MovementState = require(script.Parent:WaitForChild("MovementState"))
	local StaminaBar = require(script.Parent:WaitForChild("StaminaBar"))

	local staminaBar = StaminaBar.new(screenGui)

	-- Bottom centre between the health panel and the hotbar, or above the bottom-left stack on screens
	-- too narrow for that (StaminaBar.Layout).
	local function rescale()
		staminaBar:Place(camera.ViewportSize)
	end
	rescale()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	-- A tablet gaining or losing a keyboard changes layout (PhoneLayout.Mode), as the phone block does.
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(rescale)

	local staminaView = { value = 100, max = 100 }
	RunService.RenderStepped:Connect(function(dt)
		staminaView.value = MovementState.stamina
		staminaView.max = MovementState.maxStamina
		staminaView.exhausted = MovementState.exhausted
		staminaView.rush = MovementState.rush
		staminaView.draining = MovementState.draining
		staminaView.refusedAt = MovementState.refusedAt
		-- Hidden while driving: nobody sprints in a car, and the bar sat on the car's speedometer (17:10).
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		staminaView.hidden = not MovementState.inMatch or player:GetAttribute("MenuOpen") == true
			or (seat ~= nil and seat:IsA("VehicleSeat")) or player:GetAttribute("VehicleGunActive") == true
		staminaBar:Update(math.min(dt, 0.1), staminaView)
	end)
end

--------------------------------------------------------------------------------
-- Bottom-right: ammo + slots
--------------------------------------------------------------------------------

-- 558 wide: six 84px slot cells, five 6px gaps, 12px padding each side.
local weaponFrame = create("Frame", {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -16),
	Size = UDim2.new(0, 690, 0, 150),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}, { rounded(12), padding(12) })

-- Narrow screens: the hotbar shrinks (a UIScale about its bottom-right corner) until it clears the
-- bottom-left stack, whose widest piece is the companion ability icon's key badge at 404 px across,
-- and never takes more than about a third of the screen's height. Full size from about 1122 px wide;
-- 0.6 on an 844x390 phone. In a do-block: this script's main chunk is close to Luau's 200-local limit.
do
	local LEFT_STACK_RIGHT, GAP, WIDTH, HEIGHT = 404, 12, 690, 150
	local hotbarScale = create("UIScale", { Parent = weaponFrame })
	-- On a touch screen the hotbar is a different shape altogether (four across and two down, in the
	-- band between the thumbstick and the buttons): the phone layout block near the end of this file
	-- owns it there, and this rule steps aside rather than fighting it every time the screen changes.
	local phoneOk, PhoneLayout = pcall(require, script.Parent:WaitForChild("PhoneLayout", 5))
	local function fitHotbar()
		local viewport = camera.ViewportSize
		if phoneOk and PhoneLayout and PhoneLayout.Active(viewport) then
			return
		end
		local room = viewport.X - 16 - (LEFT_STACK_RIGHT + GAP)
		local scale = math.clamp(math.min(1, room / WIDTH, viewport.Y * 0.3 / HEIGHT), 0.5, 1)
		hotbarScale.Scale = scale
		weaponFrame:SetAttribute("HotbarScale", scale)
	end
	fitHotbar()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitHotbar)
end

local ammoText = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "--",
	TextColor3 = C.Text,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 30,
	Parent = weaponFrame,
})

local weaponName = create("TextLabel", {
	Position = UDim2.new(0, 0, 0, 32),
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "Unarmed",
	TextColor3 = C.Muted,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 15,
	Parent = weaponFrame,
})

-- What the held item does (#86 C14), with its standing rule (the structure cap, M13): the left of the
-- ammo row, which is empty while an item is in hand ("x3" or "RAISING" is all the right-hand side says,
-- under 130 px at 30 pt). There is no row under the item line to put it in -- the slots start 6 px
-- below it -- and a taller plate would push the whole hotbar up the screen. Two lines of 12 pt in 516
-- px hold the longest description with its cap rule. Desktop shape only: setHotbarShape hides it on a
-- phone, as it does the ammo and item lines.
do
	local itemDetail = create("TextLabel", {
		Name = "ItemDetail",
		Size = UDim2.new(1, -150, 0, 32),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = C.Muted,
		TextSize = 12,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = false,
		Parent = weaponFrame,
	})
end

local slotRow = create("Frame", {
	Position = UDim2.new(0, 0, 0, 58),
	Size = UDim2.new(1, 0, 0, 64),
	BackgroundTransparency = 1,
	Parent = weaponFrame,
}, {
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

-- Eight slots, each holding a gun or a stack of one item. The cells are built once and updated in
-- place: loadout pushes arrive on every shot, and rebuilding the row each time recreated dozens of
-- GUI instances thirteen times a second on the chaingun.
local SLOT_COUNT = 8
local slotCells = nil

-- The item being used right now, on our clock, from the latest loadout push.
local useEndsAt, useDuration, useIndex = nil, 1, nil

-- A slot's item drawn in 3D, framed to fit. Only rebuilt when the item in the slot changes.
local function setSlotIcon(refs, itemId)
	if refs.iconId == itemId then
		return
	end
	refs.iconId = itemId
	refs.icon:ClearAllChildren()
	local model = itemId and ItemModels.Build(itemId) or nil
	if not model then
		refs.icon.Visible = false
		return
	end
	model:PivotTo(CFrame.Angles(0, math.rad(35), 0))
	model.Parent = refs.icon

	local box, size = model:GetBoundingBox()
	local radius = size.Magnitude / 2
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(box.Position + Vector3.new(0, radius * 0.35, -radius / math.tan(math.rad(20)) * 1.02), box.Position)
	camera.Parent = refs.icon
	refs.icon.CurrentCamera = camera
	refs.icon.Visible = true
end

local function buildSlotCells()
	slotCells = {}
	for index = 1, SLOT_COUNT do
		local cell = create("TextButton", {
			Size = UDim2.fromOffset(78, 64),
			BackgroundColor3 = C.Background,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			ClipsDescendants = true,
			LayoutOrder = index,
			Parent = slotRow,
		}, { rounded(8) })

		local stroke = create("UIStroke", {
			Color = C.Accent,
			Thickness = 2,
			Enabled = false,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = cell,
		})

		-- Rises from the bottom while this slot's item is being used.
		local fill = create("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, 0),
			BackgroundColor3 = C.Green,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			Visible = false,
			Parent = cell,
		})

		local icon = create("ViewportFrame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(44, 44),
			BackgroundTransparency = 1,
			Ambient = Color3.fromRGB(170, 170, 182),
			LightColor = Color3.fromRGB(255, 250, 240),
			LightDirection = Vector3.new(-0.4, -1, 0.6),
			Visible = false,
			Parent = cell,
		})

		local key = create("TextLabel", {
			Position = UDim2.fromOffset(5, 2),
			Size = UDim2.fromOffset(30, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = tostring(index),
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 11,
			Parent = cell,
		})

		local count = create("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -5, 0, 2),
			Size = UDim2.fromOffset(44, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne,
			Text = "",
			TextColor3 = C.Text,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 14,
			Parent = cell,
		})

		-- Guns have no icon; their name sits in the middle of the cell instead.
		local center = create("TextLabel", {
			Position = UDim2.new(0, 4, 0, 16),
			Size = UDim2.new(1, -8, 0, 30),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "",
			TextColor3 = C.Muted,
			TextWrapped = true,
			TextSize = 11,
			Parent = cell,
		})

		-- The tier as a letter in the bottom-right corner (#86 M4): the bar under the cell says it only in
		-- colour. C U R E L M S -- the first letters of Rarity.Order, all different. The item name beside
		-- it stops 14 px short to leave the corner clear.
		local tier = create("TextLabel", {
			Name = "Tier",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -3, 1, -5),
			Size = UDim2.fromOffset(11, 13),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBlack,
			Text = "",
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 10,
			Parent = cell,
		})

		local name = create("TextLabel", {
			Position = UDim2.new(0, 3, 1, -18),
			Size = UDim2.new(1, -17, 0, 13),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "",
			TextColor3 = C.Text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextSize = 10,
			Parent = cell,
		})

		local bar = create("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 3),
			BackgroundColor3 = C.Muted,
			BorderSizePixel = 0,
			Visible = false,
			Parent = cell,
		})

		-- Tapping a cell holds that slot (the server checks it isn't empty); right-clicking drops
		-- what's in it at your feet.
		cell.Activated:Connect(function()
			if loadout and loadout.slots[index] and loadout.equipped ~= index then
				equipRemote:FireServer(index)
				Sfx.Play("UiClick")
			end
		end)
		cell.MouseButton2Click:Connect(function()
			if loadout and loadout.slots[index] then
				dropRemote:FireServer(index)
				Sfx.Play("UiClick", 0.08)
			end
		end)

		slotCells[index] = {
			cell = cell,
			stroke = stroke,
			fill = fill,
			icon = icon,
			key = key,
			count = count,
			center = center,
			name = name,
			bar = bar,
			tier = tier,
		}
	end
end

local function renderSlots()
	if not slotCells then
		buildSlotCells()
	end

	-- The phone hotbar has no ammo line under it (setHotbarShape hides it), so each gun cell says its
	-- reserve too (#86 C12). And the first movement item says the key that uses it without switching
	-- off your gun (#86 C18: MovementClient's quick-use, the first "movement" item in the bag), on a
	-- keyboard, where a key means something.
	local phoneShape = weaponFrame:GetAttribute("PhoneShape") == true
	local quickSlot = nil
	if UserInputService.KeyboardEnabled and loadout and loadout.slots then
		local ItemData = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ItemData"))
		for index = 1, SLOT_COUNT do
			local slot = loadout.slots[index]
			local item = type(slot) == "table" and slot.kind == "item" and ItemData.Get(slot.id)
			if item and item.kind == "movement" then
				quickSlot = index
				break
			end
		end
	end
	for index = 1, SLOT_COUNT do
		local refs = slotCells[index]
		local slot = loadout and loadout.slots[index]
		local held = slot and loadout.equipped == index

		refs.cell.BackgroundColor3 = held and C.Panel or C.Background
		refs.cell.BackgroundTransparency = held and 0 or (slot and 0.35 or 0.6)
		refs.stroke.Enabled = held and true or false
		refs.key.Text = Settings.KeyLabel("Slot" .. index) .. (index == quickSlot and (" · " .. Settings.KeyLabel("MovementItem")) or "")
		refs.tier.Text = (slot and type(slot.rarity) == "string") and string.upper(string.sub(slot.rarity, 1, 1)) or ""
		refs.tier.TextColor3 = slot and Rarity.Color(slot.rarity) or C.Muted

		if not slot then
			setSlotIcon(refs, nil)
			refs.center.Text = ""
			refs.name.Text = ""
			refs.count.Text = ""
			refs.bar.Visible = false
		elseif slot.kind == "item" then
			setSlotIcon(refs, slot.id)
			refs.center.Text = ""
			refs.name.Text = slot.name
			refs.name.TextColor3 = Rarity.Color(slot.rarity)
			refs.count.Text = "x" .. slot.count
			refs.count.TextColor3 = C.Text
			refs.bar.Visible = true
			refs.bar.BackgroundColor3 = Rarity.Color(slot.rarity)
		else
			setSlotIcon(refs, nil)
			local empty = slot.mag == 0 and slot.reserve == 0
			refs.center.Text = (phoneShape and empty) and "NO AMMO" or slot.name
			refs.center.TextColor3 = (phoneShape and empty) and C.Red or Rarity.Color(slot.rarity)
			refs.name.Text = ""
			refs.count.Text = phoneShape and string.format("%d/%d", slot.mag, slot.reserve or 0) or tostring(slot.mag)
			refs.count.TextColor3 = slot.mag == 0 and C.Red or C.Text
			refs.bar.Visible = true
			refs.bar.BackgroundColor3 = Rarity.Color(slot.rarity)
		end
	end
end

-- "USING SHIELD POTION" with a bar and the seconds left, just under the crosshair.
local usePanel = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0.6, 0),
	Size = UDim2.fromOffset(250, 46),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.2,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}, { rounded(10), padding(8) })

local useLabel = create("TextLabel", {
	Size = UDim2.new(1, -50, 0, 18),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Text,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextSize = 14,
	Parent = usePanel,
})

local useTimeLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 0),
	Size = UDim2.fromOffset(50, 18),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = C.Accent,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 15,
	Parent = usePanel,
})

local useTrack = create("Frame", {
	Position = UDim2.new(0, 0, 0, 22),
	Size = UDim2.new(1, 0, 0, 8),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	Parent = usePanel,
}, { rounded(4) })

local useFill = create("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = C.Green,
	BorderSizePixel = 0,
	Parent = useTrack,
}, { rounded(4) })

local function trackUse(newLoadout)
	local using = newLoadout and newLoadout.using
	if using then
		useEndsAt = os.clock() + using.remaining
		useDuration = math.max(using.duration, 0.05)
		useIndex = using.index
		local slot = newLoadout.slots[using.index]
		useLabel.Text = "USING " .. string.upper(slot and slot.name or "")
	else
		useEndsAt, useIndex = nil, nil
	end
end

game:GetService("RunService").RenderStepped:Connect(function()
	local remaining = useEndsAt and useEndsAt - os.clock() or 0
	local active = remaining > 0 and loadout ~= nil
	local progress = active and math.clamp(1 - remaining / useDuration, 0, 1) or 0

	usePanel.Visible = active
	if active then
		useFill.Size = UDim2.fromScale(progress, 1)
		useTimeLabel.Text = string.format("%.1fs", remaining)
	end
	if slotCells then
		for index, refs in ipairs(slotCells) do
			local filling = active and index == useIndex
			refs.fill.Visible = filling
			if filling then
				refs.fill.Size = UDim2.fromScale(1, progress)
			end
		end
	end
end)

local function renderWeapon()
	if not loadout then
		weaponFrame.Visible = false
		hudLayout.show(healthFrame, false)
		showCrosshair(false)
		updateCompanionWidget()
		return
	end

	weaponFrame.Visible = true
	hudLayout.show(healthFrame, true)

	local slot = loadout.equipped and loadout.slots[loadout.equipped]
	-- The words for the slot (#86 C14 description, C39 gun type), from the inventory module, which says
	-- them in its cards too. Required here, not at the top: this chunk is close to Luau's local limit.
	local okPanel, Panel = pcall(require, script.Parent:FindFirstChild("InventoryPanel"))
	if not okPanel or type(Panel) ~= "table" or type(Panel.Describe) ~= "function" then
		Panel = nil
	end
	local itemDetail = weaponFrame:FindFirstChild("ItemDetail")
	if itemDetail then
		itemDetail.Text = (Panel and slot and slot.kind == "item") and Panel.Describe(slot) or ""
		itemDetail.Visible = itemDetail.Text ~= "" and weaponFrame:GetAttribute("PhoneShape") ~= true
	end
	if slot and slot.kind == "item" then
		-- The same "not ready yet" as a gun gets after a swap (#86 M16): a click in it is eaten.
		local raising = (loadout.equipReadyIn or 0) > 0.05
		ammoText.Text = raising and "RAISING" or ("x" .. slot.count)
		ammoText.TextColor3 = raising and C.Muted or C.Text
		-- How to use it on this device (#86 M5), and why nothing happens from a driver's seat, where
		-- the server refuses it (#86 M14: ProjectileService won't let a driver throw).
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		local lastInput = UserInputService:GetLastInputType()
		local how = "click to use"
		if seat ~= nil and seat:IsA("VehicleSeat") then
			how = "hands on the wheel"
		elseif string.find(lastInput.Name, "Gamepad", 1, true) then
			how = "RT to use"
		elseif lastInput == Enum.UserInputType.Touch then
			how = "tap FIRE to use"
		end
		weaponName.Text = slot.name .. "  •  " .. how
		weaponName.TextColor3 = Rarity.Color(slot.rarity)
		showCrosshair(false)
	elseif slot then
		-- The server won't fire for a moment after a swap. Say so, or it reads as dropped input.
		local raising = (loadout.equipReadyIn or 0) > 0.05
		if loadout.reloading then
			ammoText.Text = "RELOADING"
			ammoText.TextColor3 = C.Accent
		elseif raising then
			ammoText.Text = "RAISING"
			ammoText.TextColor3 = C.Muted
		elseif slot.mag == 0 and slot.reserve == 0 then
			-- Out entirely. "0 / 0" in the ordinary colour carries the same weight as "24 / 90", and
			-- a reload at zero reserve is refused SILENTLY (WeaponService.lua:1756) -- so the player
			-- presses reload, nothing happens, and nothing says why.
			ammoText.Text = "NO AMMO"
			ammoText.TextColor3 = C.Red
		elseif slot.mag == 0 then
			-- Empty magazine, ammo to load. The key is read from Settings so a rebind shows.
			ammoText.Text = string.format("0 / %d  •  [%s]", slot.reserve, Settings.KeyLabel("Reload"))
			ammoText.TextColor3 = C.Accent
		else
			ammoText.Text = string.format("%d / %d", slot.mag, slot.reserve)
			ammoText.TextColor3 = C.Text
		end
		-- What the gun's perk does, not its internal id (#86 C45).
		local abilityWords = {
			pierce = "PIERCE: through the first body",
			chain = "CHAIN: arcs to a second enemy",
			lifesteal = "LIFESTEAL: heals on hit",
			explosive = "EXPLOSIVE: splash",
			goldRush = "GOLD RUSH: kills pay coins",
		}
		-- The tier in words as well as colour (#86 M34), as the floor label already says it.
		-- And what KIND of gun it is (#86 C39), unless the name already says so ("Rot SMG").
		local typeWord = Panel and Panel.GunTypeWord(slot.name, slot.style) or nil
		weaponName.Text = (type(slot.rarity) == "string" and (string.upper(slot.rarity) .. "  ") or "") .. slot.name
			.. (typeWord and (" · " .. typeWord) or "")
			.. (slot.ability and ("  •  " .. (abilityWords[slot.ability] or slot.ability)) or "")
		weaponName.TextColor3 = Rarity.Color(slot.rarity)
		showCrosshair(true)
	else
		ammoText.Text = "--"
		ammoText.TextColor3 = C.Muted
		weaponName.Text = "Unarmed"
		weaponName.TextColor3 = C.Muted
		showCrosshair(false)
	end

	local shield = loadout.shield or 0
	shieldBar.Size = UDim2.fromScale(math.clamp(shield / (loadout.maxShield or 100), 0, 1), 1)
	healsText.Text = shield > 0 and string.format("%d SHIELD", math.ceil(shield)) or ""

	renderSlots()
	updateCompanionWidget()
end

--------------------------------------------------------------------------------
-- Inventory: a tab on top of the hotbar and the panel it opens (StarterPlayerScripts/InventoryPanel)
--------------------------------------------------------------------------------

-- Rearrange the hotbar by dragging one slot onto another, or tapping one and then the other. The swap is
-- the server's (the SwapSlots remote, WeaponService.SwapSlots); the panel only shows it early. The tab
-- sits on the hotbar's top-left corner and scales with it (on a phone the layout block below turns it
-- into an icon on the grid's top-right instead); the Inventory key (B) opens it too, where there is one.
-- While it's open the mouse is freed the way the menu frees it (the MenuOpen attribute, which
-- CombatClient reads), without trampling the menu's own use of that attribute.
-- In a do-block: this script's main chunk is close to Luau's 200-local limit. The whole setup runs under
-- pcall, so if the panel module ever fails to load, the hotbar just has no tab and the rest of this
-- script carries on.
do
	local okInventory, inventoryError = pcall(function()
	local InventoryPanel = require(script.Parent:WaitForChild("InventoryPanel"))
	local MenuOpenClaims = require(script.Parent:WaitForChild("MenuOpenClaims"))
	local swapRemote = Remotes.Event("SwapSlots")

	-- Its own ScreenGui, above the HUD and the menu, keeping the top-bar inset (the panel's pointer maths
	-- relies on that).
	local inventoryGui = create("ScreenGui", {
		Name = "BrrInventory",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 8,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})

	local releaseInventory = nil
	local panel

	-- Whether the menu's own big panel is up (a large visible Frame straight under its ScreenGui).
	local function menuPanelShowing()
		local menuGui = playerGui:FindFirstChild("BrrMenu")
		for _, child in ipairs(menuGui and menuGui:GetChildren() or {}) do
			if child:IsA("Frame") and child.Visible and child.AbsoluteSize.X > 500 then
				return true
			end
		end
		return false
	end

	-- The claim's own release. It does NOT decide whether the cursor goes back: MenuOpenClaims counts
	-- every holder, so closing this while a picker still needs the cursor leaves it free, and closing
	-- it last gives it back. Releasing twice is the same as releasing once, which matters because two
	-- different paths close this panel -- closePanel for every external close, and the panel's own
	-- onClose when it closes itself.
	local function releaseMenuOpen()
		if releaseInventory then
			local release = releaseInventory
			releaseInventory = nil
			release()
		end
	end

	panel = InventoryPanel.new(inventoryGui, {
		onSwap = function(a, b)
			swapRemote:FireServer(a, b)
			Sfx.Play("UiClick", 0.08)
		end,
		onClose = function()
			releaseMenuOpen()
			Sfx.Play("UiClick", 0.08, 0.9)
		end,
		-- The same remote the hotbar's right-click has always used, so the server path is unchanged
		-- and already rate-limited; this only gives touch players and undecided desktop players a
		-- way to reach it (Oliver's #36).
		onDrop = function(index)
			dropRemote:FireServer(index)
			Sfx.Play("UiClick", 0.08, 0.8)
		end,
		keyLabel = function(index)
			return Settings.KeyLabel("Slot" .. index)
		end,
		closeKeyLabel = function()
			return Settings.KeyLabel("Inventory")
		end,
	})

	local function rescale()
		panel:SetViewport(camera.ViewportSize)
	end
	rescale()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

	local function closePanel()
		if panel:IsOpen() then
			panel:Close()
			releaseMenuOpen()
		end
	end

	local function openPanel()
		if panel:IsOpen() then
			return
		end
		-- Opens even before the first loadout push (it shows eight empty slots): a key that does nothing
		-- at all reads as a broken key, and the panel is how you find out what the key even is.
		-- Not on top of the menu: that's already a modal of its own.
		if player:GetAttribute("MenuOpen") and menuPanelShowing() then
			return
		end
		-- A CLAIM, not a write. Reading the attribute to decide whether to take it is what broke:
		-- opening this under a picker's claim found it already true, so ownership was refused, and
		-- closing it later released nothing. The attribute then stayed true for the rest of the match
		-- with no owner -- inCombat() dead, cursor on screen (Oliver's #112, half of #100).
		if not releaseInventory then
			releaseInventory = MenuOpenClaims.Claim("Inventory")
		end
		panel:Open(loadout)
		Sfx.Play("UiClick", 0.08, 1.1)
	end

	local function togglePanel()
		if panel:IsOpen() then
			closePanel()
		else
			openPanel()
		end
	end

	-- The Inventory key, bound as early as possible: it is the only way in on a desktop screen (the
	-- mouse is locked to the middle in a match, so an on-screen button cannot be clicked), and binding
	-- it here means nothing built below -- the tab, its scaling, the phone layout -- can take it with
	-- it if it ever throws. Right on a gamepad's d-pad too (up and down are taken by CAM and MOVE).
	Settings.Bind("BRR_Inventory", "Inventory", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			togglePanel()
		end
		return Enum.ContextActionResult.Pass
	end, nil, Enum.KeyCode.DPadRight)

	-- The tab on the hotbar, TOUCH ONLY. On a desktop screen the inventory is a key (Inventory in
	-- Settings, B by default): the mouse is locked to the centre in a match, so an on-screen button you
	-- cannot click is worse than no button -- which is exactly how this was found. A phone has no
	-- keyboard, so there the button stays, and it is a plain HUD button rather than a
	-- ContextActionService one, so it costs nothing from the seven-button touch budget.
	-- Children of weaponFrame sit inside its 12 px padding, hence the -12s.
	local tab = create("TextButton", {
		Name = "InventoryTab",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, -12, 0, -12 - 4),
		Size = UDim2.fromOffset(176, 32),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.15,
		AutoButtonColor = false,
		Text = "",
		Visible = UserInputService.TouchEnabled,
		Parent = weaponFrame,
	}, { rounded(10) })
	-- A tablet that gains or loses a touch screen mid-session is rare, but the property is watchable.
	UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(function()
		tab.Visible = UserInputService.TouchEnabled
	end)
	local tabStroke = create("UIStroke", { Color = C.Panel, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = tab })
	for row = 0, 1 do
		for column = 0, 1 do
			create("Frame", {
				Position = UDim2.fromOffset(11 + column * 8, 8 + row * 8),
				Size = UDim2.fromOffset(6, 6),
				BackgroundColor3 = C.Accent,
				BorderSizePixel = 0,
				Parent = tab,
			}, { rounded(2) })
		end
	end
	local tabLabel = create("TextLabel", {
		Position = UDim2.fromOffset(34, 0),
		Size = UDim2.new(1, -76, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "INVENTORY",
		TextColor3 = C.Text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = tab,
	})
	local tabKey = create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(30, 20),
		BackgroundColor3 = C.PanelAlt,
		Font = Enum.Font.GothamBold,
		Text = Settings.KeyLabel("Inventory"),
		TextColor3 = C.Muted,
		TextSize = 12,
		Parent = tab,
	}, { rounded(6) })
	-- A phone has no B key to press, so the key badge only shows where a keyboard exists (a tablet with
	-- one plugged in later counts, hence the property signal); the label takes the freed room.
	-- THREE devices. `KeyboardEnabled or not TouchEnabled` answers TRUE on a console, where neither
	-- flag is set, so a pad player was shown a KEYBOARD key for a control that is actually D-Pad
	-- Right. That is the worse half of this bug's family: the same two-device assumption spelled the
	-- other way round fails by confidently showing the wrong thing rather than by showing nothing,
	-- and a wrong label looks like a feature where a missing one looks like a bug.
	--
	-- On a pad the badge is HIDDEN rather than relabelled, deliberately and temporarily: `tabKey` is
	-- a fixed 30x20 box sized for "Tab", and "D-Pad R" in it is the clipped chip of #129 again. The
	-- CONTROLS legend names the control in the meantime, so nothing is unreachable — only unlabelled
	-- here. The badge comes back with a measured width in the next render batch.
	local function fitTabKey()
		local onPad = string.find(UserInputService:GetLastInputType().Name, "Gamepad", 1, true) ~= nil
		local hasKeyboard = not onPad and (UserInputService.KeyboardEnabled or not UserInputService.TouchEnabled)
		tabKey.Visible = hasKeyboard
		tabKey.Text = hasKeyboard and Settings.KeyLabel("Inventory") or ""
		tabLabel.Size = UDim2.new(1, hasKeyboard and -76 or -44, 1, 0)
	end
	UserInputService.LastInputTypeChanged:Connect(fitTabKey)
	fitTabKey()
	Settings.Changed:Connect(fitTabKey)
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(fitTabKey)
	tab.MouseEnter:Connect(function()
		tabStroke.Color = C.Accent
	end)
	tab.MouseLeave:Connect(function()
		tabStroke.Color = C.Panel
	end)
	tab.Activated:Connect(togglePanel)

	-- The tab shrinks with the hotbar, but never below 0.8 of its size (1.0 on a touch screen, where it's
	-- a finger's target): its own UIScale makes up the difference, growing it upward off its bottom edge.
	local tabScale = create("UIScale", { Parent = tab })
	local function fitTab()
		local hotbarScale = weaponFrame:GetAttribute("HotbarScale") or 1
		local least = UserInputService.TouchEnabled and 1 or 0.8
		tabScale.Scale = math.max(1, least / math.max(hotbarScale, 0.01))
	end
	fitTab()
	weaponFrame:GetAttributeChangedSignal("HotbarScale"):Connect(fitTab)

	-- The menu and quest keys open the menu: the inventory gets out of its way first.
	UserInputService.InputBegan:Connect(function(input)
		if panel:IsOpen() and (input.KeyCode == Settings.Key("Menu") or input.KeyCode == Settings.Key("Quests")) then
			closePanel()
		end
	end)

	-- Every push is the truth; no loadout (eliminated, match over) closes it.
	loadoutChanged.OnClientEvent:Connect(function(newLoadout)
		panel:SetLoadout(newLoadout)
		if not newLoadout then
			closePanel()
		end
	end)
	end)
	if not okInventory then
		warn("[HudClient] the Inventory panel didn't load; the hotbar has no Inventory tab: " .. tostring(inventoryError))
	end
end

--------------------------------------------------------------------------------
-- Health tracking
--------------------------------------------------------------------------------

local function watchHumanoid(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end

	local function update()
		local ratio = humanoid.MaxHealth > 0 and humanoid.Health / humanoid.MaxHealth or 0
		healthText.Text = string.format("%d", math.ceil(humanoid.Health))
		healthBar.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
		local color = ratio > 0.5 and C.Green or (ratio > 0.25 and C.Accent or C.Red)
		healthText.TextColor3 = color
		healthBar.BackgroundColor3 = color
	end

	humanoid:GetPropertyChangedSignal("Health"):Connect(update)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(update)
	update()
end

if player.Character then
	task.spawn(watchHumanoid, player.Character)
end
player.CharacterAdded:Connect(watchHumanoid)

--------------------------------------------------------------------------------
-- Storm readout
--------------------------------------------------------------------------------

local stormLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 72),
	Size = UDim2.new(0, 440, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Storm,
	TextSize = 15,
	Parent = screenGui,
})

-- `stormState` is declared up in "Screen-edge state", which reads it every frame.
stormState = nil

stormChanged.OnClientEvent:Connect(function(storm)
	stormState = storm.status ~= "Idle" and storm or nil

	if not stormState then
		stormLabel.Text = ""
		return
	end

	-- A STATIC boundary says nothing here. StormService.StartStatic (:140) -- which GameMode:418
	-- calls for every team mode -- sends `label` ("Stay in the arena") precisely because the phase
	-- countdown "means nothing for a circle that never moves" (StormService.lua:90-92). Nothing read
	-- it, so a whole team match showed "Storm moves in 0s   •   Zone 0/5   •   4 dmg/s": a countdown
	-- at zero, a phase that does not exist and a storm that is not coming.
	--
	-- The readout's job is to report what CHANGES -- when the next shrink lands and how much it
	-- hurts. In a team mode nothing changes, so a permanent line reporting a constant is furniture,
	-- not information, and it also sat in ModeScoreHud's slot at y=72. The boundary is still told
	-- twice where it matters: the minimap's zone ring draws it continuously, and the vignette plus
	-- OUTSIDE THE ZONE say "you are outside it, now".
	if storm.label then
		stormLabel.Text = ""
		return
	end

	-- The last circle does not move again, so "Storm moves in 0s" was a countdown to nothing (#86 C22);
	-- and "Zone 2/5" read as jargon: it is which circle of how many.
	if storm.status == "Final" then
		stormLabel.Text = string.format("Final circle   •   outside: %d dmg/s", storm.damagePerSecond)
		return
	end
	local verb = storm.status == "Shrinking" and "Storm closing" or "Storm moves in"
	stormLabel.Text = string.format("%s  %ds   •   Circle %d of %d   •   outside: %d dmg/s",
		verb, storm.secondsLeft, storm.phase, storm.totalPhases, storm.damagePerSecond)
end)

--------------------------------------------------------------------------------
-- Minimap
--------------------------------------------------------------------------------

local MAP_PX = 190

local minimap = create("Frame", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, 108),
	Size = UDim2.fromOffset(MAP_PX, MAP_PX),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Visible = false,
	Parent = screenGui,
}, {
	rounded(math.floor(MAP_PX / 2)),
	create("UIStroke", { Color = C.Panel, Thickness = 2 }),
})

-- Safe zone: a circle sized and positioned in map space.
local zoneRing = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = minimap,
}, {
	create("UICorner", { CornerRadius = UDim.new(1, 0) }),
	create("UIStroke", { Color = C.Storm, Thickness = 2, Transparency = 0.15 }),
})

local targetRing = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = minimap,
}, {
	create("UICorner", { CornerRadius = UDim.new(1, 0) }),
	create("UIStroke", { Color = C.Accent, Thickness = 1, Transparency = 0.45 }),
})

local playerDot = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Size = UDim2.fromOffset(8, 8),
	BackgroundColor3 = C.Green,
	BorderSizePixel = 0,
	Parent = minimap,
}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })

local dropDot = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Size = UDim2.fromOffset(10, 10),
	BackgroundColor3 = C.Accent,
	BorderSizePixel = 0,
	Rotation = 45,
	Visible = false,
	Parent = minimap,
})

--------------------------------------------------------------------------------
-- Drop selection
--
-- Once the map is built, the server holds for MatchConfig.DropSelectSeconds and broadcasts
-- `dropSelect`. Click the map to pick where to land; pick nothing and you keep the spawn the
-- spiral gave you, which is the old random behaviour unchanged. Shown only to people the match is
-- about to place — anyone readied up when loading began — though the server is the real gate and
-- rejects a pick from anyone else regardless.
--------------------------------------------------------------------------------

-- Everything this screen needs lives inside the do-block below, so it costs the main chunk one
-- local instead of ten. Luau allows 200 locals per function, the top level of this file was
-- already at 192, and the first version of this screen took it to 202 -- at which point the whole
-- script silently stopped compiling. Neither verify.py nor balance.py can see that: it isn't a
-- structural imbalance, it's a compiler limit. Locals declared in a do-block are released at its
-- end, so only `Drop` survives into the main chunk. The body is left unindented on purpose;
-- re-indenting two hundred lines to suit the block would bury the actual change.
local Drop = {}
do

local chooseDrop = Remotes.Event("ChooseDrop")
local DROP_PX = 440

local dropScreen = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(DROP_PX + 40, DROP_PX + 96),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.06,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 40,
	Parent = screenGui,
}, {
	rounded(18),
	create("UIStroke", { Color = C.Accent, Thickness = 2 }),
})

-- 480x536 is taller than a phone screen, which would take the map and the CONFIRM row off the bottom:
-- PhoneLayout.FitPanel shrinks it to fit, and leaves it exactly as it is on any screen with the room.
pcall(function()
	require(script.Parent:WaitForChild("PhoneLayout")).FitPanel(dropScreen, Vector2.new(DROP_PX + 40, DROP_PX + 96))
end)

create("TextLabel", {
	Position = UDim2.new(0, 22, 0, 14),
	Size = UDim2.new(1, -44, 0, 24),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "CHOOSE YOUR DROP",
	TextColor3 = C.Accent,
	TextSize = 19,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 41,
	Parent = dropScreen,
})

local dropClock = create("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -22, 0, 12),
	Size = UDim2.fromOffset(60, 28),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "15",
	TextColor3 = C.Text,
	TextSize = 24,
	TextXAlignment = Enum.TextXAlignment.Right,
	ZIndex = 41,
	Parent = dropScreen,
})

local dropHint = create("TextLabel", {
	Position = UDim2.new(0, 22, 0, 38),
	Size = UDim2.new(1, -44, 0, 18),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	Text = "Click the map to pick a landing spot",
	TextColor3 = C.Muted,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 41,
	Parent = dropScreen,
})

local dropMap = create("TextButton", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 62),
	Size = UDim2.fromOffset(DROP_PX, DROP_PX),
	BackgroundColor3 = C.Panel,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Text = "",
	ClipsDescendants = true,
	ZIndex = 41,
	Parent = dropScreen,
}, {
	rounded(math.floor(DROP_PX / 2)),
	create("UIStroke", { Color = C.PanelAlt, Thickness = 2 }),
})

local dropMarker = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Size = UDim2.fromOffset(13, 13),
	BackgroundColor3 = C.Accent,
	BorderSizePixel = 0,
	Rotation = 45,
	Visible = false,
	ZIndex = 44,
	Parent = dropMap,
})

-- Town and landmark markers, rebuilt each time the window opens because the map is new every
-- match. Read off the same attributes the minimap and the compass use.
local dropPins = {}

local function refreshDropMap()
	for _, pin in ipairs(dropPins) do
		pin:Destroy()
	end
	table.clear(dropPins)

	local map = workspace:FindFirstChild("Map")
	local radius = matchState and matchState.mapRadius or 0
	if not map or radius <= 0 then
		return
	end
	local scale = (DROP_PX / 2) / radius

	local function pin(center, name, color, dotSize)
		local dot = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, center.X * scale, 0.5, center.Z * scale),
			Size = UDim2.fromOffset(dotSize, dotSize),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 42,
			Parent = dropMap,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		table.insert(dropPins, dot)
		if name then
			table.insert(dropPins, create("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, center.X * scale, 0.5, center.Z * scale + 6),
				Size = UDim2.fromOffset(130, 13),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = name,
				TextColor3 = color,
				TextStrokeTransparency = 0.5,
				TextSize = 11,
				ZIndex = 43,
				Parent = dropMap,
			}))
		end
	end

	for _, child in ipairs(map:GetChildren()) do
		local center = child:GetAttribute("TownCenter")
		if center then
			pin(center, child:GetAttribute("TownName"), C.Text, 9)
		end
	end
	local landmarks = map:FindFirstChild("Landmarks")
	if landmarks then
		for _, child in ipairs(landmarks:GetChildren()) do
			local center = child:GetAttribute("LandmarkCenter")
			if center then
				pin(center, child:GetAttribute("LandmarkName"), C.Accent, 8)
			end
		end
	end
end

dropMap.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local radius = matchState and matchState.mapRadius or 0
	if not dropScreen.Visible or radius <= 0 then
		return
	end

	local size, origin = dropMap.AbsoluteSize, dropMap.AbsolutePosition
	local px = input.Position.X - origin.X - size.X / 2
	local py = input.Position.Y - origin.Y - size.Y / 2

	-- Pixels back into studs: the disc's half-width is the map's radius.
	local scale = radius / math.max(size.X / 2, 1)
	local worldX, worldZ = px * scale, py * scale

	-- Held inside the playable disc, to the same limit the server uses. The marker follows the
	-- clamped point, so it shows where you will actually land rather than where you clicked.
	local limit = radius * 0.96
	local distance = math.sqrt(worldX * worldX + worldZ * worldZ)
	if distance > limit then
		local pull = limit / math.max(distance, 1)
		worldX, worldZ = worldX * pull, worldZ * pull
		px, py = worldX / scale, worldZ / scale
	end

	chooseDrop:FireServer(worldX, worldZ)
	dropMarker.Position = UDim2.new(0.5, px, 0.5, py)
	dropMarker.Visible = true
	dropHint.Text = "Landing here. Click again to move it."
	dropHint.TextColor3 = C.Green
end)

function Drop.update()
	-- Superseded by StarterPlayerScripts/DropPicker.lua, which draws the real terrain and keeps
	-- this screen's modal-overlay cursor fix. Held at false rather than deleted so the old screen
	-- is one line away if the new one ever has to be pulled.
	local active = false
	if active and not dropScreen.Visible then
		-- A fresh window: drop last match's pick and redraw for the new map.
		dropMarker.Visible = false
		dropHint.Text = "Click the map to pick a landing spot"
		dropHint.TextColor3 = C.Muted
		refreshDropMap()
	end
	dropScreen.Visible = active
	if active then
		dropClock.Text = tostring(matchState.countdown or 0)
	end
end

end
-- End of the drop screen's block; its locals are released here.

-- The bounty on the match's kill leader, under the minimap.

local bountyLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, 108 + MAP_PX + 6),
	Size = UDim2.fromOffset(MAP_PX + 40, 22),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Accent,
	TextTruncate = Enum.TextTruncate.AtEnd,
	TextSize = 12,
	Visible = false,
	Parent = screenGui,
}, { rounded(8) })

-- Town names, so "rotate toward Aura Farms" means something. Towns carry their centre and name
-- as attributes (MapGenerator), which replicate even while the town itself is streamed out.
-- Markers sit beneath the zone rings and dots, and are refreshed every couple of seconds —
-- only rebuilt when the set of towns changes, never per frame.
local townMarkers = {}

-- The river, drawn once per map from the Map folder's RiverPath attribute ("x,z;x,z;…").
local riverLines = {}
local riverKey = nil

local function refreshRiver(map, radius, scale)
	local path = map and radius and map:GetAttribute("RiverPath") or nil
	local key = path and (path .. "@" .. tostring(radius)) or nil
	if key == riverKey then
		return
	end
	riverKey = key
	for _, line in ipairs(riverLines) do
		line:Destroy()
	end
	riverLines = {}
	if not path then
		return
	end
	local points = {}
	for pair in string.gmatch(path, "[^;]+") do
		local x, z = string.match(pair, "(-?%d+),(-?%d+)")
		if x and z then
			table.insert(points, Vector2.new(tonumber(x), tonumber(z)))
		end
	end
	for index = 1, #points - 1 do
		local a, b = points[index] * scale, points[index + 1] * scale
		local delta = b - a
		local mid = (a + b) / 2
		table.insert(riverLines, create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, mid.X, 0.5, mid.Y),
			Size = UDim2.fromOffset(math.ceil(delta.Magnitude) + 2, 3),
			Rotation = math.deg(math.atan2(delta.Y, delta.X)),
			BackgroundColor3 = Color3.fromRGB(80, 150, 230),
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			ZIndex = 0,
			Parent = minimap,
		}, { rounded(2) }))
	end
end

local function refreshTownMarkers()
	local radius = matchState.mapRadius
	local map = workspace:FindFirstChild("Map")
	local seen = {}

	-- Landmarks (MapGenerator's Landmarks folder) are marked the same way, in gold.
	local function consider(child, centerAttribute, nameAttribute, color, scale)
		local center = child:GetAttribute(centerAttribute)
		local name = child:GetAttribute(nameAttribute)
		if not center or not name then
			return
		end
		seen[child] = true
		local marker = townMarkers[child]
		if not marker then
			marker = create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(84, 22),
				BackgroundTransparency = 1,
				ZIndex = 0,
				Parent = minimap,
			})
			create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 0),
				Size = UDim2.fromOffset(5, 5),
				BackgroundColor3 = color,
				BackgroundTransparency = 0.2,
				BorderSizePixel = 0,
				ZIndex = 0,
				Parent = marker,
			}, { rounded(3) })
			create("TextLabel", {
				Position = UDim2.new(0, 0, 0, 6),
				Size = UDim2.new(1, 0, 0, 12),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = name,
				TextColor3 = color,
				TextStrokeTransparency = 0.6,
				TextSize = 9,
				ZIndex = 0,
				Parent = marker,
			})
			townMarkers[child] = marker
		end
		-- The dot is at the top of the marker; shift down so the dot, not the label, sits on
		-- the spot.
		marker.Position = UDim2.new(0.5, center.X * scale, 0.5, center.Z * scale + 8)
	end

	if matchState.state == "InProgress" and radius and radius > 0 and map then
		local scale = (MAP_PX / 2) / radius
		refreshRiver(map, radius, scale)
		for _, child in ipairs(map:GetChildren()) do
			consider(child, "TownCenter", "TownName", C.Muted, scale)
		end
		local landmarks = map:FindFirstChild("Landmarks")
		if landmarks then
			for _, child in ipairs(landmarks:GetChildren()) do
				consider(child, "LandmarkCenter", "LandmarkName", C.Accent, scale)
			end
		end
	else
		refreshRiver(nil)
	end

	for town, marker in pairs(townMarkers) do
		if not seen[town] then
			marker:Destroy()
			townMarkers[town] = nil
		end
	end

	-- No two names printed over each other on the minimap (Oliver's 16:58 screenshot: BONKINGTON
	-- across GRASS TOUCHER'S REST, THE BEACHED GALLEON across a town). Landmarks first, then towns;
	-- a name that would overlap one already shown is hidden and its dot stays.
	local ordered = {}
	for owner, marker in pairs(townMarkers) do
		table.insert(ordered, { marker = marker, landmark = owner:GetAttribute("LandmarkCenter") ~= nil })
	end
	table.sort(ordered, function(a, b)
		if a.landmark ~= b.landmark then
			return a.landmark
		end
		return a.marker.Position.Y.Offset < b.marker.Position.Y.Offset
	end)
	local shown = {}
	for _, entry in ipairs(ordered) do
		local label = entry.marker:FindFirstChildOfClass("TextLabel")
		if label then
			local x, y = entry.marker.Position.X.Offset, entry.marker.Position.Y.Offset - 5
			local half = math.min(label.TextBounds.X, 84) / 2 + 2
			local free = true
			for _, box in ipairs(shown) do
				if math.abs(box.x - x) < box.half + half and math.abs(box.y - y) < 12 then
					free = false
					break
				end
			end
			label.Visible = free
			if free then
				table.insert(shown, { x = x, y = y, half = half })
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Compass
--
-- A strip under the storm readout showing which way you're looking. The cardinal points, the
-- towns (grey) and landmarks (gold) — read off the same attributes the minimap uses — the safe
-- zone's centre and the live supply drop slide along it as you turn; 180 degrees of view fit
-- across the strip. The "Compass" setting turns it off.
--------------------------------------------------------------------------------

local COMPASS_W, COMPASS_H = 440, 24
local COMPASS_SPAN = 180 -- degrees across the strip

local compass = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 104),
	Size = UDim2.fromOffset(COMPASS_W, COMPASS_H),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.35,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Visible = false,
	Parent = screenGui,
}, {
	rounded(8),
	-- The notch: where you're looking.
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(2, 7),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		ZIndex = 2,
	}),
})

-- key -> { frame, label, dot, bearing (cardinals) | position (places) }. Keyed by the town or
-- landmark instance, or a string for the cardinals, the zone and the drop.
local compassMarkers = {}

local function compassMarker(key, text, color, kind)
	local marker = compassMarkers[key]
	if marker then
		if marker.label.Text ~= text then
			marker.label.Text = text
		end
		if marker.label.TextColor3 ~= color then
			marker.label.TextColor3 = color
			if marker.dot then
				marker.dot.BackgroundColor3 = color
			end
		end
		return marker
	end

	local frame = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(96, COMPASS_H),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = compass,
	})
	local label, dot
	if kind == "cardinal" then
		label = create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne,
			Text = text,
			TextColor3 = color,
			TextSize = #text > 1 and 11 or 15,
			Parent = frame,
		})
	else
		dot = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 3),
			Size = UDim2.fromOffset(6, 6),
			BackgroundColor3 = color,
			BackgroundTransparency = kind == "zone" and 1 or 0.15,
			BorderSizePixel = 0,
			Rotation = kind == "drop" and 45 or 0,
			Parent = frame,
		})
		if kind == "zone" then
			create("UIStroke", { Color = color, Thickness = 2, Parent = dot })
			create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dot })
		elseif kind ~= "drop" then
			create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dot })
		end
		label = create("TextLabel", {
			Position = UDim2.new(0, 0, 0, 10),
			Size = UDim2.new(1, 0, 0, 12),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = text,
			TextColor3 = color,
			TextStrokeTransparency = 0.6,
			TextSize = 9,
			Parent = frame,
		})
	end
	marker = { frame = frame, label = label, dot = dot }
	compassMarkers[key] = marker
	return marker
end

for _, cardinal in ipairs({ { "N", 0 }, { "NE", 45 }, { "E", 90 }, { "SE", 135 }, { "S", 180 }, { "SW", 225 }, { "W", 270 }, { "NW", 315 } }) do
	local color = cardinal[1] == "N" and C.Accent or (#cardinal[1] > 1 and C.Muted or C.Text)
	compassMarker("cardinal:" .. cardinal[1], cardinal[1], color, "cardinal").bearing = cardinal[2]
end

-- Towns and landmarks come and go with the map; refreshed alongside the minimap markers.
local function refreshCompassPlaces()
	local map = workspace:FindFirstChild("Map")
	local seen = {}
	local function consider(child, centerAttribute, nameAttribute, color)
		local center = child:GetAttribute(centerAttribute)
		local name = child:GetAttribute(nameAttribute)
		if center and name then
			compassMarker(child, string.upper(name), color, "place").position = center
			seen[child] = true
		end
	end
	if map and matchState.state == "InProgress" then
		for _, child in ipairs(map:GetChildren()) do
			consider(child, "TownCenter", "TownName", C.Muted)
		end
		local landmarks = map:FindFirstChild("Landmarks")
		if landmarks then
			for _, child in ipairs(landmarks:GetChildren()) do
				consider(child, "LandmarkCenter", "LandmarkName", C.Accent)
			end
		end
	end
	for key, marker in pairs(compassMarkers) do
		if typeof(key) == "Instance" and not seen[key] then
			marker.frame:Destroy()
			compassMarkers[key] = nil
		end
	end
end

-- Bearings: 0 is north (−Z, up on the minimap), 90 east (+X).
local function bearingTo(from, to)
	return math.deg(math.atan2(to.X - from.X, -(to.Z - from.Z)))
end

local function placeCompassMarker(marker, bearing, heading)
	local delta = (bearing - heading + 540) % 360 - 180
	if math.abs(delta) > COMPASS_SPAN / 2 + 8 then
		marker.frame.Visible = false
		return
	end
	marker.frame.Visible = true
	marker.x = COMPASS_W / 2 + delta * (COMPASS_W / COMPASS_SPAN)
	marker.delta = delta
	marker.frame.Position = UDim2.fromOffset(marker.x, 0)
	-- Fading out toward the ends of the strip.
	marker.label.TextTransparency = math.clamp((math.abs(delta) - (COMPASS_SPAN / 2 - 28)) / 28, 0, 1) * 0.85
end

local function updateCompass(root)
	if not root or not Settings.Get("Compass") then
		hudLayout.show(compass, false)
		return
	end
	hudLayout.show(compass, true)
	-- Always flush under whatever the top-centre HUD is showing right now (Oliver 17:16): the players-
	-- alive banner, the storm line under it, or a team mode's score bar -- measured off what is actually
	-- on screen, so it follows any of them changing size, hiding or scaling. A phone layout places the
	-- compass itself and is left alone.
	if not compass:GetAttribute("PhonePlaced") then
		local bottom = nil
		local function under(gui)
			if gui and gui.Visible and gui.AbsoluteSize.Y > 0 then
				local edge = gui.AbsolutePosition.Y + gui.AbsoluteSize.Y
				bottom = bottom and math.max(bottom, edge) or edge
			end
		end
		under(banner)
		if stormLabel.Text ~= "" then
			under(stormLabel)
		end
		local scoreGui = playerGui:FindFirstChild("ModeScoreHud")
		if scoreGui and scoreGui.Enabled then
			under(scoreGui:FindFirstChild("Scoreline"))
		end
		local y = math.floor((bottom and (bottom - screenGui.AbsolutePosition.Y) or 6) + 4 + 0.5)
		if compass.Position.Y.Offset ~= y or compass.Position.Y.Scale ~= 0 then
			compass.Position = UDim2.new(0.5, 0, 0, y)
		end
	end
	local look = camera.CFrame.LookVector
	local heading = math.deg(math.atan2(look.X, -look.Z))
	local here = root.Position

	for _, marker in pairs(compassMarkers) do
		if marker.bearing then
			placeCompassMarker(marker, marker.bearing, heading)
		elseif marker.position then
			placeCompassMarker(marker, bearingTo(here, marker.position), heading)
		end
	end

	-- No two labels on top of each other (Oliver's 16:58 screenshot: THE BEACON and BRAINROT CARNIVAL
	-- printed over one another, with the N across LAG LAGOON). The cardinals keep theirs; then each
	-- place, the one nearest the middle of the strip first, shows its name only where it clears every
	-- label already shown. A place whose name doesn't fit still shows its dot.
	local taken = {}
	local function clear(x, width)
		for _, span in ipairs(taken) do
			if x + width / 2 > span[1] and x - width / 2 < span[2] then
				return false
			end
		end
		return true
	end
	local places = {}
	for _, marker in pairs(compassMarkers) do
		if marker.frame.Visible and marker.x then
			if marker.bearing then
				local width = marker.label.TextBounds.X + 6
				table.insert(taken, { marker.x - width / 2, marker.x + width / 2 })
			elseif marker.position then
				table.insert(places, marker)
			end
		end
	end
	table.sort(places, function(a, b)
		return math.abs(a.delta) < math.abs(b.delta)
	end)
	for _, marker in ipairs(places) do
		local width = math.max(marker.label.TextBounds.X, 8) + 6
		local fits = clear(marker.x, width)
		marker.label.Visible = fits
		if fits then
			table.insert(taken, { marker.x - width / 2, marker.x + width / 2 })
		end
	end

	-- The zone (where it's heading, once it's moving) and the live drop are placed every frame,
	-- since they move.
	if stormState and stormState.center then
		local moving = stormState.status == "Shrinking" or stormState.status == "Waiting"
		local target = moving and stormState.targetCenter or stormState.center
		placeCompassMarker(compassMarker("zone", "ZONE", C.Storm, "zone"), bearingTo(here, target), heading)
	elseif compassMarkers.zone then
		compassMarkers.zone.frame.Visible = false
	end
	if activeDrop and activeDrop.position then
		local marker = compassMarker("drop", "DROP", Rarity.Color(activeDrop.rarity), "drop")
		placeCompassMarker(marker, bearingTo(here, activeDrop.position), heading)
	elseif compassMarkers.drop then
		compassMarkers.drop.frame.Visible = false
	end
	-- King of the Hill's objectives by letter (#86 C34): nothing on the HUD pointed at them. The mode
	-- builds each as workspace.Hill.Objective<letter> with its centre as HillX / HillZ
	-- (ModeKingOfTheHill.buildObjective), and takes the model down with the match.
	local hill = workspace:FindFirstChild("Hill")
	for _, letter in ipairs({ "A", "B" }) do
		local key = "objective:" .. letter
		local folder = hill and hill:FindFirstChild("Objective" .. letter)
		local x = folder and folder:GetAttribute("HillX")
		local z = folder and folder:GetAttribute("HillZ")
		if x and z then
			placeCompassMarker(compassMarker(key, letter, C.Accent, "zone"), bearingTo(here, Vector3.new(x, 0, z)), heading)
		elseif compassMarkers[key] then
			compassMarkers[key].frame.Visible = false
		end
	end
end

task.spawn(function()
	while true do
		refreshTownMarkers()
		refreshCompassPlaces()
		task.wait(2)
	end
end)

-- Where you are: the town or landmark you're in, under the minimap, and a big "ENTERING …" that
-- fades in and out when it changes. Read off the same attributes the markers use.
local locationLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, 108 + MAP_PX + 34),
	Size = UDim2.fromOffset(MAP_PX + 40, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Text,
	TextStrokeTransparency = 0.5,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 13,
	Parent = screenGui,
})

local enteringLabel = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.24),
	Size = UDim2.fromOffset(600, 44),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = C.Accent,
	TextStrokeTransparency = 0.3,
	TextTransparency = 1,
	TextSize = 34,
	Parent = screenGui,
})

local currentLocation = nil
local enteringToken = 0

local function locationHere()
	local map = workspace:FindFirstChild("Map")
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not map or not root or matchState.state ~= "InProgress" then
		return nil
	end
	local radius = matchState.mapRadius or 900
	local townReach = math.max(110, radius * 0.17) + 30
	local here = root.Position
	local best, bestDistance = nil, math.huge

	local function consider(child, centerAttribute, nameAttribute, reach, color)
		local center = child:GetAttribute(centerAttribute)
		local name = child:GetAttribute(nameAttribute)
		if center and name then
			local distance = (Vector3.new(center.X, 0, center.Z) - Vector3.new(here.X, 0, here.Z)).Magnitude
			if distance < reach and distance < bestDistance then
				best, bestDistance = { name = name, color = color }, distance
			end
		end
	end

	for _, child in ipairs(map:GetChildren()) do
		consider(child, "TownCenter", "TownName", townReach, C.Text)
	end
	local landmarks = map:FindFirstChild("Landmarks")
	if landmarks then
		for _, child in ipairs(landmarks:GetChildren()) do
			consider(child, "LandmarkCenter", "LandmarkName", 75, C.Accent)
		end
	end
	return best
end

task.spawn(function()
	while true do
		task.wait(1)
		local location = locationHere()
		local name = location and location.name or nil
		if name ~= currentLocation then
			currentLocation = name
			locationLabel.Text = name and string.upper(name) or ""
			locationLabel.TextColor3 = location and location.color or C.Text
			if name then
				enteringToken += 1
				local token = enteringToken
				enteringLabel.Text = "ENTERING " .. string.upper(name)
				enteringLabel.TextColor3 = location.color
				enteringLabel.TextTransparency = 1
				TweenService:Create(enteringLabel, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
				task.delay(2.4, function()
					if token == enteringToken then
						TweenService:Create(enteringLabel, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
					end
				end)
			end
		end
	end
end)

RunService.RenderStepped:Connect(function()
	local radius = matchState.mapRadius
	if matchState.state ~= "InProgress" or not radius or radius <= 0 then
		hudLayout.show(minimap, false)
		hudLayout.show(compass, false)
		return
	end

	hudLayout.show(minimap, true)
	local scale = (MAP_PX / 2) / radius

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		playerDot.Visible = true
		playerDot.Position = UDim2.new(0.5, root.Position.X * scale, 0.5, root.Position.Z * scale)
	else
		playerDot.Visible = false
	end
	updateCompass(root)

	if activeDrop and activeDrop.position then
		dropDot.Visible = true
		dropDot.BackgroundColor3 = Rarity.Color(activeDrop.rarity)
		dropDot.Position = UDim2.new(0.5, activeDrop.position.X * scale, 0.5, activeDrop.position.Z * scale)
	else
		dropDot.Visible = false
	end

	-- The readout is cleared here rather than beside the vignette, because `stormLabel` is declared
	-- below that loop: referencing it there compiles as a nil global and only fails when it runs.
	if matchState.state == "InProgress" and not loadout and stormLabel.Text ~= "" then
		stormLabel.Text = ""
	end

	if stormState and not (matchState.state == "InProgress" and not loadout) then
		local size = math.max(4, stormState.radius * 2 * scale)
		zoneRing.Size = UDim2.fromOffset(size, size)
		zoneRing.Position = UDim2.new(0.5, stormState.center.X * scale, 0.5, stormState.center.Z * scale)
		zoneRing.Visible = true

		-- Where it's heading, so you can rotate before it starts moving.
		local shrinking = stormState.status == "Shrinking" or stormState.status == "Waiting"
		if shrinking and stormState.targetRadius then
			local targetSize = math.max(4, stormState.targetRadius * 2 * scale)
			targetRing.Size = UDim2.fromOffset(targetSize, targetSize)
			targetRing.Position = UDim2.new(0.5, stormState.targetCenter.X * scale, 0.5, stormState.targetCenter.Z * scale)
			targetRing.Visible = true
		else
			targetRing.Visible = false
		end
	else
		zoneRing.Visible = false
		targetRing.Visible = false
	end
end)

--------------------------------------------------------------------------------
-- Kill feed
--------------------------------------------------------------------------------

-- Under the location line, not beside it (#80): at y 312 the first row (312-336) lay across the bounty
-- line (304-326) and the location line (332-352), which sit under the minimap. 108 + MAP_PX + 34 + 20 is
-- the location line's bottom; 6 clear of it.
local feed = create("Frame", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, 108 + MAP_PX + 34 + 20 + 6),
	Size = UDim2.new(0, 300, 0, 200),
	BackgroundTransparency = 1,
	Parent = screenGui,
}, {
	create("UIListLayout", {
		Padding = UDim.new(0, 4),
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local feedOrder = 0

killFeed.OnClientEvent:Connect(function(entry)
	feedOrder += 1

	-- `method` is the gun, or the companion brainrot that landed the last hit, when known.
	local text
	if entry.killer and entry.method then
		text = string.format("%s  ➜  %s   [%s]", entry.killer, entry.victim, entry.method)
	elseif entry.killer then
		text = string.format("%s  ➜  %s", entry.killer, entry.victim)
	else
		text = string.format("%s was eliminated", entry.victim)
	end

	local row = create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		-- Placement is a battle-royale thing; a respawning mode's feed has none, and a nil here
		-- would throw before the row exists. It goes first, and a long row is cut with "…" rather
		-- than running off the screen's edge (#86 M8).
		Text = "  " .. (entry.placement and ("#" .. entry.placement .. "  ") or "") .. text .. "  ",
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Right,
		-- By UserId, not the shown name: a DisplayName is not unique (#86 C7). The server sends the
		-- killer's UserId beside the name (Combatants.GetUserId; nil for a bot).
		TextColor3 = entry.killerUserId ~= nil and entry.killerUserId == player.UserId and C.Accent or C.Text,
		TextSize = 13,
		LayoutOrder = feedOrder,
		Parent = feed,
	}, { rounded(6) })

	-- No more rows than the feed's box holds (#80): the rows stack down from its top and each lasts six
	-- seconds, so a burst of kills ran on past the box into whatever is under it (on a phone the slot is
	-- two rows tall and the bounty line is right under it). The newest rows show; the phone layout sets
	-- MaxRows for its slot, and the desktop box holds seven 24-pixel rows with their 4-pixel gaps.
	local live = {}
	for _, child in ipairs(feed:GetChildren()) do
		if child:IsA("TextLabel") then
			table.insert(live, child)
		end
	end
	table.sort(live, function(a, b)
		return a.LayoutOrder > b.LayoutOrder
	end)
	for index, shown in ipairs(live) do
		shown.Visible = index <= (feed:GetAttribute("MaxRows") or 7)
	end

	task.delay(6, function()
		TweenService:Create(row, TweenInfo.new(0.4), { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
		task.wait(0.4)
		row:Destroy()
	end)
end)

--------------------------------------------------------------------------------
-- Toasts
--------------------------------------------------------------------------------

-- Bottom centre, clear of the bottom row (#80): its bottom edge 8 above the hotbar's top (16 up, 150
-- tall). At -120 it sat inside the hotbar on any window narrower than about 1400 (253x36 px at 1366x768),
-- and across the companion ability tile's readout at 1920x1080.
local toast = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -(16 + 150 + 8)),
	Size = UDim2.new(0, 460, 0, 36),
	BackgroundColor3 = C.Panel,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Text,
	TextTransparency = 1,
	TextSize = 15,
	-- A long message wraps onto a second line inside the box rather than running out of it (#86 C3).
	TextWrapped = true,
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = screenGui,
}, { rounded(8) })

local toastToken = 0

local function showToast(message, isError)
	toastToken += 1
	local token = toastToken

	toast.Text = message
	toast.TextColor3 = isError and C.Red or C.Text
	-- In a vehicle on a desktop screen the driving HUD fills the band the toast normally uses (the speed
	-- panel 178-256 up, its hint to 280, the damage line to 304: VehicleClient), so the toast goes above
	-- it (#80). A phone places the toast itself, top-anchored (the phone layout block), and is left alone.
	if toast.AnchorPoint.Y == 1 then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		-- A gunner's panel sits in the same band as the driver's (VehicleWeaponClient), so a gunner counts.
		local driving = seat ~= nil and (seat:IsA("VehicleSeat") or seat.Name == "GunnerSeat" or seat:GetAttribute("Gunner") == true)
			or player:GetAttribute("VehicleGunActive") == true
		toast.Position = UDim2.new(0.5, 0, 1, driving and -(304 + 8) or -(16 + 150 + 8))
	end
	TweenService:Create(toast, TweenInfo.new(0.15), { BackgroundTransparency = 0.15, TextTransparency = 0 }):Play()

	-- Long enough to read: 2.6 s for a short line, more for a long one (#86 C3).
	task.delay(math.max(2.6, 1.5 + 0.05 * #tostring(message)), function()
		if token ~= toastToken then
			return
		end
		TweenService:Create(toast, TweenInfo.new(0.35), { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	end)
end

notify.OnClientEvent:Connect(showToast)

-- The camera key flips a saved setting, so say which way it went.
Settings.Changed:Connect(function(id)
	if id == "ThirdPerson" then
		showToast(Settings.Get("ThirdPerson") and "Third-person camera" or "First-person camera")
	end
end)

-- Bounties: who's worth extra right now, and who just collected.
-- The remote is named here rather than kept in a local: the main chunk is at Luau's 200-local limit.
Remotes.Event("Bounty").OnClientEvent:Connect(function(info)
	if type(info) ~= "table" then
		hudLayout.show(bountyLabel, false)
		return
	end
	if info.claimed then
		hudLayout.show(bountyLabel, false)
		showToast(string.format("%s collected the %d coin bounty on %s!", info.by or "Someone", info.reward or 0, info.name or "?"))
		return
	end
	bountyLabel.Text = string.format("BOUNTY  •  %s  (%d kills)  •  %d C", info.name or "?", info.kills or 0, info.reward or 0)
	hudLayout.show(bountyLabel, matchState.state == "InProgress")
	-- "Is it me?" by UserId, which the server sends beside the name (Combatants.GetUserId, #86 C7): the
	-- name is a DisplayName and not unique, so comparing names gave a player who shares yours your "YOU"
	-- toast. (Comparing two different kinds of name is how it once went to everyone except its subject.)
	if info.userId == nil or info.userId ~= player.UserId then
		showToast(string.format("BOUNTY: %d SahurCoins on %s (%d kills)", info.reward or 0, info.name or "?", info.kills or 0))
	else
		showToast(string.format("There's a %d coin bounty on YOU — everyone knows.", info.reward or 0), true)
	end
end)

-- Companions downed: tell the owner, and the player who did it.
Remotes.Event("CompanionDown").OnClientEvent:Connect(function(info)
	if type(info) ~= "table" then
		return
	end
	if info.owner == player.UserId then
		showToast(string.format("%s was downed%s — it's back next match",
			info.name or "Your companion", info.killer and (" by " .. info.killer) or ""), true)
	elseif info.killerUserId == player.UserId then
		showToast(string.format("You downed %s!", info.name or "a companion"))
	end
end)

--------------------------------------------------------------------------------
-- Phone and tablet layout (StarterPlayerScripts/PhoneLayout)
--------------------------------------------------------------------------------

-- On a touch screen every piece above is drawn at its desktop size, which on an 844x390 phone covers
-- the middle of the screen and overlaps itself (measured: 27 overlapping pairs). PhoneLayout says where
-- each piece goes and how big it is; this block is what moves them, and puts every one of them back if
-- the device stops being a phone (a tablet with a keyboard plugged in, or the gallery's test hook).
-- Nothing here runs on a desktop screen. In a do-block, and the whole thing under pcall: if PhoneLayout
-- ever fails to load, the HUD stays exactly as it was.
do
	local ok, err = pcall(function()
		local PhoneLayout = require(script.Parent:WaitForChild("PhoneLayout"))
		-- What each piece is drawn at, before any scaling. The health block is the phone arrangement
		-- below (one row), not its desktop shape.
		local PIECES = {
			{ key = "banner", gui = banner, natural = Vector2.new(440, 56) },
			{ key = "stormLine", gui = stormLabel, natural = Vector2.new(440, 24) },
			{ key = "compass", gui = compass, natural = Vector2.new(COMPASS_W, COMPASS_H) },
			{ key = "minimap", gui = minimap, natural = Vector2.new(MAP_PX, MAP_PX) },
			{ key = "bounty", gui = bountyLabel, natural = Vector2.new(MAP_PX + 40, 22) },
			{ key = "location", gui = locationLabel, natural = Vector2.new(MAP_PX + 40, 20) },
			-- The feed's box is 200 tall and holds two 18-pixel lines, so it is scaled on width alone.
			{ key = "killFeed", gui = feed, natural = Vector2.new(300, 200) },
			{ key = "health", gui = healthFrame, natural = Vector2.new(280, 48) },
			{ key = "speedPill", gui = speedPill, natural = Vector2.new(150, 28) },
			-- Kept on a phone, not hidden: shrunk to the strip `setCompanionShape` rearranges it into.
			{ key = "companion", gui = companionFrame, natural = Vector2.new(300, 56) },
		}
		-- Centred strips: they keep their own anchor and only shrink, since they are wider than a phone.
		local CENTRED = {
			{ gui = usePanel, scale = 0.8, key = "useBar" },
			{ gui = toast, scale = 0.62, key = "toast" },
			{ gui = dropBanner, scale = 0.62 },
			{ gui = townLabel, scale = 0.62 },
			{ gui = streakLabel, scale = 0.7 },
			{ gui = enteringLabel, scale = 0.7 },
			{ gui = zoneWarning, scale = 0.7 },
		}

		-- Everything is put back exactly as it was built, so a change of mode is not a one-way trip.
		local saved = {}
		local function remember(gui)
			if gui and not saved[gui] then
				saved[gui] = { anchor = gui.AnchorPoint, position = gui.Position, size = gui.Size }
			end
		end
		local scales = {}
		local function scaleFor(gui)
			if not scales[gui] then
				scales[gui] = gui:FindFirstChildOfClass("UIScale") or create("UIScale", { Parent = gui })
			end
			return scales[gui]
		end

		-- The health block, from two stacked bars under a big number (280x80) to one row (280x48): the
		-- number on the left, both bars in the middle, the shield count on the right.
		local healthShape = {
			[healthText] = { row = UDim2.fromOffset(0, 0), rowSize = UDim2.new(0, 70, 0, 24) },
			[healsText] = { row = UDim2.new(1, -60, 0, 0), rowSize = UDim2.new(0, 60, 0, 24) },
			[shieldBarBg] = { row = UDim2.new(0, 76, 0, 2), rowSize = UDim2.new(1, -142, 0, 8) },
			[healthBarBg] = { row = UDim2.new(0, 76, 0, 12), rowSize = UDim2.new(1, -142, 0, 12) },
		}
		local function setHealthShape(phone)
			for gui, shape in pairs(healthShape) do
				remember(gui)
				gui.Position = phone and shape.row or saved[gui].position
				gui.Size = phone and shape.rowSize or saved[gui].size
			end
			remember(healthFrame)
			healthFrame.Size = phone and UDim2.fromOffset(280, 48) or saved[healthFrame].size
		end

		-- The hotbar: eight cells in a row is far too wide for a phone, so they go four across and two
		-- down, the ammo lines come off (the held cell shows its own count) and the Inventory tab loses
		-- its wording to become an icon at the grid's top-right.
		local rowLayout = slotRow:FindFirstChildOfClass("UIListLayout")
		local grid = create("UIGridLayout", {
			CellSize = UDim2.fromOffset(78, 64),
			CellPadding = UDim2.fromOffset(6, 6),
			FillDirectionMaxCells = 4,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = nil,
		})
		local tab = weaponFrame:FindFirstChild("InventoryTab")
		-- The tab's wording and its key badge: both go on a phone, leaving the four-square icon.
		local tabWords = {}
		for _, child in ipairs(tab and tab:GetChildren() or {}) do
			if child:IsA("TextLabel") then
				table.insert(tabWords, child)
			end
		end
		local function setHotbarShape(phone, spot, slots, invSpot)
			remember(weaponFrame)
			remember(slotRow)
			-- The cells word their ammo differently in the phone shape (renderSlots).
			if weaponFrame:GetAttribute("PhoneShape") ~= (phone == true) then
				weaponFrame:SetAttribute("PhoneShape", phone == true)
				renderSlots()
			end
			ammoText.Visible = not phone
			weaponName.Visible = not phone
			local itemDetail = weaponFrame:FindFirstChild("ItemDetail")
			if itemDetail then
				itemDetail.Visible = not phone and itemDetail.Text ~= ""
			end
			if rowLayout then
				rowLayout.Parent = phone and nil or slotRow
			end
			grid.Parent = phone and slotRow or nil
			slotRow.Position = phone and UDim2.fromOffset(0, 0) or saved[slotRow].position
			slotRow.Size = phone and UDim2.new(1, 0, 0, 134) or saved[slotRow].size
			if phone then
				-- 4 cells of 78 and 3 gaps of 6 across, 2 of 64 and one gap down, plus the plate's
				-- padding, which is halved on a phone so the plate hugs the cells: the frame's own box.
				-- Scaled so the CELLS land exactly on PhoneLayout's rect, with the plate just outside it.
				local pad = 6
				for _, child in ipairs(weaponFrame:GetChildren()) do
					if child:IsA("UIPadding") then
						child.PaddingTop = UDim.new(0, pad)
						child.PaddingBottom = UDim.new(0, pad)
						child.PaddingLeft = UDim.new(0, pad)
						child.PaddingRight = UDim.new(0, pad)
					end
				end
				-- Portrait keeps only the slots that fit -- PhoneLayout says how many, and on the shortest
				-- screens none at all, where the Inventory button stands alone and the panel holds the lot.
				local columns = slots and slots > 0 and math.min(slots, 4) or 4
				local rows = slots and slots > 0 and 1 or 2
				grid.FillDirectionMaxCells = columns
				for index, cell in ipairs(slotCells or {}) do
					cell.cell.Visible = not slots or slots <= 0 or index <= slots
				end
				local none = slots ~= nil and slots <= 0
				-- No slots at all (the shortest vertical screens): the plate keeps nothing but the Inventory
				-- button, which is the way to all eight there. The frame itself stays, so whatever shows and
				-- hides it with the match still works.
				slotRow.Visible = not none
				local naturalW, naturalH = columns * 78 + (columns - 1) * 6 + 2 * pad, rows * 64 + (rows - 1) * 6 + 2 * pad
				if none then
					naturalW, naturalH = 34 + 2 * pad, 25 + 2 * pad
				end
				spot = spot or (none and invSpot or nil)
				if not spot then
					return
				end
				local scale = spot.w / (naturalW - 2 * pad)
				scaleFor(weaponFrame).Scale = scale
				weaponFrame:SetAttribute("HotbarScale", scale)
				weaponFrame.Size = UDim2.fromOffset(naturalW, naturalH)
				weaponFrame.AnchorPoint = Vector2.new(1, 1)
				weaponFrame.Position = UDim2.fromOffset(spot.x1 + pad * scale, spot.y1 + pad * scale)
			else
				for _, child in ipairs(weaponFrame:GetChildren()) do
					if child:IsA("UIPadding") then
						child.PaddingTop = UDim.new(0, 12)
						child.PaddingBottom = UDim.new(0, 12)
						child.PaddingLeft = UDim.new(0, 12)
						child.PaddingRight = UDim.new(0, 12)
					end
				end
				slotRow.Visible = true
				weaponFrame.Size = saved[weaponFrame].size
				weaponFrame.AnchorPoint = saved[weaponFrame].anchor
				weaponFrame.Position = saved[weaponFrame].position
			end
			if tab then
				remember(tab)
				local tabScale = tab:FindFirstChildOfClass("UIScale")
				if phone then
					local hotbar = weaponFrame:GetAttribute("HotbarScale") or 1
					-- Bottom-right corner exactly on PhoneLayout's Inventory slot: the cells' right edge,
					-- 10 px above their top. The offsets are in the frame's own units, so the 10 is
					-- divided by the frame's scale.
					tab.Size = UDim2.fromOffset(34, 25)
					tab.AnchorPoint = Vector2.new(1, 1)
					if slots ~= nil and slots <= 0 then
						-- Nothing but the button on this screen: it fills the plate rather than perching above a
						-- row of cells that is not there.
						tab.Position = UDim2.new(1, 0, 1, 0)
						if tabScale then
							tabScale.Scale = 1
						end
					else
						tab.Position = UDim2.new(1, 0, 0, -10 / math.max(hotbar, 0.01))
						if tabScale then
							tabScale.Scale = math.max(1, 1.3 / math.max(hotbar, 0.01))
						end
					end
					for _, word in ipairs(tabWords) do
						word.Visible = false
					end
				else
					tab.Size = saved[tab].size
					tab.AnchorPoint = saved[tab].anchor
					tab.Position = saved[tab].position
					for _, word in ipairs(tabWords) do
						word.Visible = true
					end
				end
			end
		end

		-- The READY pill sits 232 px right of the middle, which on an 844-wide phone hangs 40 px off the
		-- edge of the screen. It can't take a UIScale of its own -- the one it has is its breathing
		-- animation -- so on a phone it moves inside a holder that carries the scale instead, into the
		-- corner slot the event pill shares with it.
		local readyHolder = create("Frame", {
			Name = "PhoneReadyHolder",
			Size = UDim2.fromOffset(230, 60),
			BackgroundTransparency = 1,
			Visible = false,
			Parent = screenGui,
		})
		local readyHolderScale = create("UIScale", { Parent = readyHolder })
		local function setReadyShape(phone, spot)
			remember(readyButton)
			if phone then
				readyHolderScale.Scale = spot.w / 230
				readyHolder.Position = UDim2.fromOffset(spot.x, spot.y)
				readyHolder.Visible = true
				readyButton.Position = UDim2.fromOffset(0, 0)
				readyButton.Parent = readyHolder
			else
				readyHolder.Visible = false
				readyButton.Position = saved[readyButton].position
				readyButton.Parent = screenGui
			end
		end

		-- The companion panel stays on a phone -- the owner asked for it kept and shrunk rather than
		-- hidden -- but not in its desktop shape: 300x62 of name, move, status and bar squeezed into a
		-- 160-wide strip would be six-pixel text. On a phone it becomes one line: the companion's name on
		-- the left, its state (READY, a countdown, DOWNED) on the right, and the cooldown bar under them,
		-- all drawn big in a 300x56 frame so that scaling it to the strip's width leaves 13-pixel text.
		local companionShape = {
			[companionDot] = { phone = UDim2.new(0, 18, 0.5, -4), phoneSize = UDim2.fromOffset(22, 22) },
			[companionName] = { phone = UDim2.new(0, 40, 0, 2), phoneSize = UDim2.new(1, -150, 0, 26) },
			[companionStatus] = { phone = UDim2.new(1, -10, 0, 2), phoneSize = UDim2.fromOffset(110, 26) },
			[companionMove] = { phone = UDim2.new(0, 40, 0, 30), phoneSize = UDim2.new(1, -52, 0, 0) },
			[companionBar] = { phone = UDim2.new(0, 40, 0, 34), phoneSize = UDim2.new(1, -52, 0, 12) },
		}
		local companionText = { [companionName] = 24, [companionStatus] = 22 }
		local function setCompanionShape(phone)
			remember(companionFrame)
			companionFrame.Size = phone and UDim2.fromOffset(300, 56) or saved[companionFrame].size
			for gui, shape in pairs(companionShape) do
				remember(gui)
				gui.Position = phone and shape.phone or saved[gui].position
				gui.Size = phone and shape.phoneSize or saved[gui].size
			end
			for gui, size in pairs(companionText) do
				remember(gui)
				if not saved[gui].textSize then
					saved[gui].textSize = gui.TextSize
				end
				gui.TextSize = phone and size or saved[gui].textSize
			end
			-- The move's name is what gives way on a phone: the state on the right says the same thing in
			-- fewer words, and the bar under it says how long.
			companionMove.Visible = not phone
		end

		local function apply()
			local viewport = camera.ViewportSize
			local phone = PhoneLayout.Active(viewport)
			compass:SetAttribute("PhonePlaced", phone == true)
			local spots = phone and PhoneLayout.Rects(viewport) or nil
			-- Portrait is the simplified HUD: a piece PhoneLayout has no rect for there (the compass, the
			-- kill feed, the bounty and location lines, the speed pill) is hidden rather than left behind.
			setCompanionShape(phone)
			for _, piece in ipairs(PIECES) do
				if piece.gui then
					remember(piece.gui)
					local spot = phone and spots[piece.key] or nil
					if phone and spot then
						PhoneLayout.Place(piece.gui, spots[piece.key], piece.natural, scaleFor(piece.gui), 0, piece.key ~= "killFeed")
					elseif not phone then
						piece.gui.AnchorPoint = saved[piece.gui].anchor
						piece.gui.Position = saved[piece.gui].position
						scaleFor(piece.gui).Scale = 1
					end
					-- No place for it in this mode: dropped, and hudLayout.show keeps it hidden whatever its
					-- own code asks for. Back in a mode with room: shown as its code last asked (or as it
					-- was, for a piece nothing ever shows or hides, like the kill feed's box).
					local dropped = phone and not spot
					if dropped and not hudLayout.dropped[piece.gui] then
						if hudLayout.wanted[piece.gui] == nil then
							hudLayout.wanted[piece.gui] = piece.gui.Visible
						end
						hudLayout.dropped[piece.gui] = true
						piece.gui.Visible = false
					elseif not dropped and hudLayout.dropped[piece.gui] then
						hudLayout.dropped[piece.gui] = nil
						piece.gui.Visible = hudLayout.wanted[piece.gui] == true
					end
				end
			end
			for _, piece in ipairs(CENTRED) do
				if piece.gui then
					remember(piece.gui)
					scaleFor(piece.gui).Scale = phone and piece.scale or 1
					if piece.key and phone then
						local spot = spots[piece.key]
						piece.gui.AnchorPoint = Vector2.new(0.5, 0)
						piece.gui.Position = UDim2.new(0.5, 0, 0, spot.y)
					elseif piece.key then
						piece.gui.AnchorPoint = saved[piece.gui].anchor
						piece.gui.Position = saved[piece.gui].position
					end
				end
			end
			-- How many kill rows the feed's slot holds at the scale it was given (a row is 24 plus a 4 gap).
			local feedSpot = phone and spots.killFeed or nil
			feed:SetAttribute("MaxRows", feedSpot and math.max(1, math.floor((feedSpot.h / scaleFor(feed).Scale + 4) / 28)) or nil)
			setHealthShape(phone)
			setHotbarShape(phone, phone and spots.hotbar or nil, phone and spots.hotbarSlots or nil, phone and spots.inventory or nil)
			setReadyShape(phone, phone and spots.ready or nil)
		end

		apply()
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
		-- A tablet that gains or loses a keyboard changes which layout it should have.
		UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(apply)
		PhoneLayout.Reapply = apply
	end)
	if not ok then
		warn("[HudClient] the phone layout didn't load; the HUD keeps its desktop sizes: " .. tostring(err))
	end
end

--------------------------------------------------------------------------------
-- Map vote
--------------------------------------------------------------------------------

local votePanel = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.new(0, 620, 0, 260),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.08,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}, { rounded(14), padding(16) })

create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 28),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "VOTE FOR THE MAP",
	TextColor3 = C.Text,
	TextSize = 22,
	Parent = votePanel,
})

local voteRow = create("Frame", {
	Position = UDim2.new(0, 0, 0, 36),
	Size = UDim2.new(1, 0, 1, -36),
	BackgroundTransparency = 1,
	Parent = votePanel,
}, {
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

-- Cards are built once per set of candidates, then updated in place. Rebuilding them all on
-- every broadcast tore down and recreated ~20 instances each time anyone in the server voted.
local voteCards = {}
local voteCardsKey = nil

local function buildVoteCards(candidates)
	for _, entry in ipairs(voteCards) do
		entry.card:Destroy()
	end
	table.clear(voteCards)

	for index, candidate in ipairs(candidates) do
		local card = create("TextButton", {
			Size = UDim2.fromOffset(188, 188),
			BackgroundColor3 = C.Panel,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = index,
		}, { rounded(10), padding(12) })

		-- Border mode is required: on a text button the default Contextual mode strokes the
		-- text, and this button has none, so the highlight used to be invisible.
		local stroke = create("UIStroke", {
			Color = C.Accent,
			Thickness = 2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Enabled = false,
			Parent = card,
		})

		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = candidate.name,
			TextColor3 = C.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 16,
			Parent = card,
		})

		create("TextLabel", {
			Position = UDim2.new(0, 0, 0, 26),
			Size = UDim2.new(1, 0, 0, 74),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = candidate.description,
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			TextSize = 12,
			Parent = card,
		})

		create("TextLabel", {
			Position = UDim2.new(0, 0, 1, -52),
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = string.format("Radius %d studs", candidate.radius),
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 11,
			Parent = card,
		})

		local tally = create("TextLabel", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundColor3 = C.Background,
			BorderSizePixel = 0,
			Font = Enum.Font.FredokaOne,
			Text = "0 votes",
			TextColor3 = C.Text,
			TextSize = 15,
			Parent = card,
		}, { rounded(6) })

		card.Activated:Connect(function()
			castVote:InvokeServer(candidate.id)
		end)

		card.Parent = voteRow
		voteCards[index] = { card = card, stroke = stroke, tally = tally }
	end
end

local function renderVote(voteState)
	-- Superseded by StarterPlayerScripts/VoteScreen.lua, which votes on the MODE as well as the map
	-- (Oliver's #2). Same note as the drop screen: one line back if it is ever needed.
	votePanel.Visible = false
	if not votePanel.Visible then
		return
	end

	local ids = {}
	for index, candidate in ipairs(voteState.candidates) do
		ids[index] = candidate.id
	end
	local key = table.concat(ids, "|")
	if key ~= voteCardsKey then
		voteCardsKey = key
		buildVoteCards(voteState.candidates)
	end

	-- The server keys this by UserId as a string (see VoteService.Broadcast).
	local myVote = voteState.votes[tostring(player.UserId)]

	for index, candidate in ipairs(voteState.candidates) do
		local entry = voteCards[index]
		local picked = myVote == candidate.id
		entry.stroke.Enabled = picked
		entry.tally.Text = string.format("%d vote%s", candidate.votes, candidate.votes == 1 and "" or "s")
		entry.tally.BackgroundColor3 = picked and C.Accent or C.Background
		entry.tally.TextColor3 = picked and Color3.new(0, 0, 0) or C.Text
	end
end

local latestVote = { open = false, candidates = {}, votes = {} }

voteChanged.OnClientEvent:Connect(function(voteState)
	latestVote = voteState
	renderVote(latestVote)
end)

--------------------------------------------------------------------------------
-- Results card
--------------------------------------------------------------------------------

local resultsPanel = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.new(0, 460, 0, 410),
	BackgroundColor3 = C.Background,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}, { rounded(14), padding(20) })

local resultsRank = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 56),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "#1",
	TextColor3 = C.Accent,
	TextSize = 52,
	Parent = resultsPanel,
})

local resultsBody = create("TextLabel", {
	Position = UDim2.new(0, 0, 0, 64),
	Size = UDim2.new(1, 0, 1, -64),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = C.Text,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextSize = 16,
	Parent = resultsPanel,
})

--------------------------------------------------------------------------------
-- Winner celebration
--------------------------------------------------------------------------------

local CONFETTI_COLORS = {
	C.Accent, C.Green, C.Storm, C.Red, Color3.fromRGB(80, 200, 255), Color3.fromRGB(255, 255, 255),
}

local championBanner = create("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.2),
	Size = UDim2.fromOffset(760, 90),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "BRAINROT CHAMPION",
	TextColor3 = C.Accent,
	TextStrokeTransparency = 1,
	TextScaled = true,
	TextTransparency = 1,
	Visible = false,
	ZIndex = 20,
	Parent = screenGui,
})
local championScale = create("UIScale", { Parent = championBanner })

-- Taking #1: the banner pops in and confetti rains down the screen. GUI frames only, so it
-- costs nothing in the world and needs no assets.
local function celebrateWin()
	championBanner.Visible = true
	championBanner.TextTransparency = 0
	championBanner.TextStrokeTransparency = 0.2
	championScale.Scale = 0.3
	TweenService:Create(championScale, TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	Sfx.Play("CrateOpen")

	local viewport = camera.ViewportSize
	for _ = 1, 70 do
		local size = math.random(6, 12)
		local startX = math.random(0, math.floor(viewport.X))
		local piece = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(startX, -20 - math.random(0, 220)),
			Size = UDim2.fromOffset(size, math.floor(size * 1.6)),
			Rotation = math.random(0, 360),
			BackgroundColor3 = CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)],
			BorderSizePixel = 0,
			ZIndex = 19,
			Parent = screenGui,
		})
		local fall = 2.2 + math.random() * 1.8
		TweenService:Create(piece, TweenInfo.new(fall, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.fromOffset(startX + math.random(-120, 120), viewport.Y + 40),
			Rotation = piece.Rotation + math.random(-540, 540),
		}):Play()
		task.delay(fall + 0.1, function()
			piece:Destroy()
		end)
	end

	task.delay(4.5, function()
		TweenService:Create(championBanner, TweenInfo.new(0.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		task.wait(0.6)
		championBanner.Visible = false
	end)
end

--------------------------------------------------------------------------------
-- Death recap
--------------------------------------------------------------------------------

-- Who did it, with what, from how far, what they had left, and where the last twelve seconds
-- of damage came from — shown under the banner while you go down, gone when the results come.
local deathRecap = Remotes.Event("DeathRecap")

local recapPanel = create("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 80),
	Size = UDim2.new(0, 480, 0, 104),
	BackgroundColor3 = C.Background,
	BackgroundTransparency = 0.1,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 12,
	Parent = screenGui,
}, { rounded(12), padding(12) })

-- Scaled down to fit rather than cut off: "DOWNED BY <a long display name> — BACK IN 5" is wider than
-- the panel at 22 pt.
local recapTitle = create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 28),
	BackgroundTransparency = 1,
	Font = Enum.Font.FredokaOne,
	Text = "",
	TextColor3 = C.Red,
	TextSize = 22,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 13,
	Parent = recapPanel,
}, { create("UITextSizeConstraint", { MaxTextSize = 22 }) })

local recapBody = create("TextLabel", {
	Position = UDim2.new(0, 0, 0, 30),
	Size = UDim2.new(1, 0, 1, -30),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	Text = "",
	TextColor3 = C.Text,
	TextSize = 14,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	ZIndex = 13,
	Parent = recapPanel,
})

-- `token` retires an old recap's hide timer; `killer`, `title` and `backAt` feed the respawn countdown.
local recap = { token = 0 }

-- In a respawn mode the recap says when you are back (#86 M32): "DOWNED BY RIVAL — BACK IN 4", counting
-- down. The wait used to be only in a 2.6 s toast. The time comes from the recap's own `respawnDelay`
-- when it carries one, else from the RespawnAt attribute GameMode puts on the player at the moment it
-- schedules the respawn (server time; GetServerTimeNow is the same clock here). The two can arrive in
-- either order, so the title is re-judged every frame while the panel is up, and a stale RespawnAt
-- from an earlier death is already in the past and says nothing.
do
	local function respawnIn()
		local at = recap.backAt or player:GetAttribute("RespawnAt")
		if type(at) ~= "number" then
			return nil
		end
		local left = math.ceil(at - workspace:GetServerTimeNow())
		return left > 0 and left or nil
	end
	function recap.update()
		local left = respawnIn()
		local text = recap.title or ""
		if left then
			text = (recap.killer and ("DOWNED BY " .. string.upper(recap.killer)) or "DOWNED") .. " — BACK IN " .. left
		end
		if recapTitle.Text ~= text then
			recapTitle.Text = text
		end
	end
	RunService.Heartbeat:Connect(function()
		if recapPanel.Visible then
			recap.update()
		end
	end)
end

deathRecap.OnClientEvent:Connect(function(info)
	recap.token += 1
	local token = recap.token
	recap.killer = info.killer
	recap.backAt = type(info.respawnDelay) == "number" and (workspace:GetServerTimeNow() + info.respawnDelay) or nil

	local lines = {}
	if info.killer then
		recapTitle.Text = "ELIMINATED BY " .. string.upper(info.killer)
		local how = {}
		if info.weapon then
			table.insert(how, info.weapon)
		end
		if info.distance then
			table.insert(how, string.format("%d studs", math.floor(info.distance + 0.5)))
		end
		if info.headshot then
			table.insert(how, "headshot")
		end
		if #how > 0 then
			table.insert(lines, table.concat(how, "  •  "))
		end
		if info.killerHealth then
			table.insert(lines, string.format("They had %d HP%s left", info.killerHealth,
				info.killerShield and string.format(" + %d shield", info.killerShield) or ""))
		end
	else
		-- The storm's finishing blow is named as the storm's even after a shooter had hit you (#86 C6).
		recapTitle.Text = (info.finishedBy == "Storm" or (info.taken or 0) == 0) and "THE STORM GOT YOU" or "ELIMINATED"
	end
	if (info.taken or 0) > 0 then
		local sources = {}
		for _, source in ipairs(info.sources or {}) do
			table.insert(sources, string.format("%s %d", source.name, source.amount))
		end
		table.insert(lines, string.format("%d damage in the last 12 s%s", info.taken,
			#sources > 0 and ("  —  " .. table.concat(sources, ", ")) or ""))
	end
	recapBody.Text = table.concat(lines, "\n")
	recap.title = recapTitle.Text
	recap.update()
	recapPanel.Visible = true

	task.delay(10, function()
		if recap.token == token then
			recapPanel.Visible = false
		end
	end)
end)

matchResults.OnClientEvent:Connect(function(result)
	recapPanel.Visible = false
	-- ResultsScreen.client.lua draws the end-of-match screen now (Oliver, 16:03). This card and its
	-- champion banner are the fallback for when that script is missing.
	if playerGui:FindFirstChild("BrrResults") then
		return
	end
	resultsPanel.Visible = true
	resultsRank.Text = "#" .. result.rank
	resultsRank.TextColor3 = result.rank == 1 and C.Accent or C.Text
	if result.rank == 1 then
		celebrateWin()
	end

	local lines = { string.format("out of %d", result.total) }

	if result.rank ~= 1 and result.winnerName then
		table.insert(lines, string.format("Won by %s%s",
			result.winnerName, result.winnerIsBot and " (bot)" or ""))
	end

	if result.kills and result.kills > 0 then
		table.insert(lines, string.format("%d elimination%s", result.kills, result.kills == 1 and "" or "s"))
	end

	if result.eggsTotal and result.eggsTotal > 0 then
		table.insert(lines, string.format("Easter eggs found: %d / %d", result.eggsFound or 0, result.eggsTotal))
	end

	-- The match in numbers.
	local tally = result.tally or {}
	local numbers = {}
	if (tally.damage or 0) > 0 then
		table.insert(numbers, string.format("%s damage", formatNumber(math.floor(tally.damage))))
	end
	if (tally.chests or 0) > 0 then
		table.insert(numbers, string.format("%d chest%s", tally.chests, tally.chests == 1 and "" or "s"))
	end
	if (tally.items or 0) > 0 then
		table.insert(numbers, string.format("%d item%s used", tally.items, tally.items == 1 and "" or "s"))
	end
	if (tally.supply or 0) > 0 then
		table.insert(numbers, string.format("%d supply drop%s", tally.supply, tally.supply == 1 and "" or "s"))
	end
	if (tally.bounties or 0) > 0 then
		table.insert(numbers, string.format("%d bount%s collected", tally.bounties, tally.bounties == 1 and "y" or "ies"))
	end
	if #numbers > 0 then
		table.insert(lines, table.concat(numbers, "  •  "))
	end

	-- How the shooting went.
	local combat = result.combat
	if combat and (combat.shots or 0) > 0 then
		local aim = {}
		table.insert(aim, string.format("Accuracy %d%% (%d / %d)", math.floor(combat.hits / combat.shots * 100 + 0.5), combat.hits, combat.shots))
		if (combat.headshots or 0) > 0 then
			table.insert(aim, string.format("%d headshot%s", combat.headshots, combat.headshots == 1 and "" or "s"))
		end
		table.insert(lines, table.concat(aim, "  •  "))
	end
	if combat and ((combat.longestKill or 0) > 0 or (combat.damageTaken or 0) > 0) then
		local more = {}
		if (combat.longestKill or 0) > 0 then
			table.insert(more, string.format("Longest elimination %d studs", math.floor(combat.longestKill + 0.5)))
		end
		if (combat.damageTaken or 0) > 0 then
			table.insert(more, string.format("%s damage taken", formatNumber(math.floor(combat.damageTaken))))
		end
		table.insert(lines, table.concat(more, "  •  "))
	end

	if result.companionDamage and result.companionDamage > 0 then
		table.insert(lines, string.format("Your companion dealt %d damage", result.companionDamage))
	end

	if result.reward then
		table.insert(lines, "")
		-- Team modes award coins and XP with NO crate (GameMode's AwardResult sends `crate = nil`),
		-- so only the crate LINES are conditional. Coins, XP and the rank line below are not: a team
		-- reward still shows everything it actually contains. string.upper(nil) threw here, after the
		-- panel and rank were already drawn, so the card showed an empty body and never ran its 10 s
		-- hide -- it lingered until the 15 s Intermission broadcast.
		if result.reward.crate then
			table.insert(lines, string.upper(result.reward.crate) .. " CRATE")
			table.insert(lines, "open it from the menu")
			table.insert(lines, "")
		end
		table.insert(lines, string.format("+%d SahurCoins", result.reward.coins))
		table.insert(lines, string.format("+%d Brainrot Pass XP", result.reward.xp))
		-- Rot Rank this match (ProgressionService.MatchSummary). ONE line: the card is nearly full, and
		-- mastery tiers already get their own toasts.
		local progression = result.progression
		if progression and (progression.xp or 0) > 0 then
			local rankText = progression.prestige ~= progression.prestigeFrom
				and string.format("PRESTIGE %d  •  ROT RANK %d", progression.prestige, progression.rank)
				or progression.rank ~= progression.rankFrom and string.format("ROT RANK %d → %d", progression.rankFrom, progression.rank)
				or string.format("ROT RANK %d", progression.rank)
			table.insert(lines, string.format("%s  •  +%s XP%s", rankText, formatNumber(progression.xp),
				(progression.cells or 0) > 0 and string.format("  •  +%s Cells", formatNumber(progression.cells)) or ""))
		end
		-- Rarity.Color(nil) answers Common rather than failing, so without this a team card came out
		-- Common grey -- a wrong colour is harder to notice than a crash and lasts longer.
		resultsBody.TextColor3 = result.reward.crate and Rarity.Color(result.reward.crate) or C.Text
	else
		table.insert(lines, "")
		table.insert(lines, "No placement reward this time.")
		resultsBody.TextColor3 = C.Muted
	end

	resultsBody.Text = table.concat(lines, "\n")

	task.delay(10, function()
		resultsPanel.Visible = false
	end)
end)

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function renderBanner()
	local ready = isReady()
	updateReadyButton()

	-- Oliver: the players-alive bubble is Battle Royale only. In a team mode the score bar takes
	-- this slot (ModeScoreHud moves up to it), so the banner hides while you're playing one.
	hudLayout.show(banner, not (matchState.state == "InProgress" and loadout
		and matchState.mode ~= nil and matchState.mode ~= "BattleRoyale"))

	if matchState.state == "Waiting" then
		bannerTitle.Text = ready and "WAITING FOR PLAYERS" or "READY UP TO PLAY"
		local idle = "Or hang out in the lobby as long as you like"
		-- Someone who hasn't played yet gets the basics, one at a time.
		if profileMatches == 0 then
			local tip = NEW_PLAYER_TIPS[(tipIndex % #NEW_PLAYER_TIPS) + 1]
			-- {ActionId} is that action's key as this player has it bound, read now so a rebind shows.
			-- On a gamepad or touch screen a keyboard key means nothing, so the key is dropped there,
			-- the same way KeyHintClient words world labels.
			local lastInput = UserInputService:GetLastInputType()
			if lastInput == Enum.UserInputType.Touch or string.find(lastInput.Name, "Gamepad", 1, true) or not UserInputService.KeyboardEnabled then
				tip = (string.gsub(tip, "press {%w+} to ", ""))
			end
			tip = (string.gsub(tip, "{(%w+)}", function(actionId)
				return Settings.KeyLabel(actionId)
			end))
			idle = "NEW HERE?  " .. tip
		end
		bannerSub.Text = ready
			and string.format("%d / %d ready  •  %d in server",
				matchState.readyCount or 0, matchState.minPlayers or 1, matchState.playerCount or 0)
			or idle
	elseif matchState.state == "Intermission" then
		local seconds = matchState.countdown or 0
		bannerTitle.Text = string.format("INTERMISSION  %d:%02d", seconds // 60, seconds % 60)
		bannerSub.Text = ready and "You're readied up — the countdown starts after the break"
			or "Ready up to join the next match"
	elseif matchState.state == "Countdown" then
		bannerTitle.Text = "STARTING IN " .. matchState.countdown
		bannerSub.Text = ready and "Vote for the map" or "You're staying in the lobby — ready up to join"
	elseif matchState.state == "Loading" then
		-- The same state covers building the map and the drop window that follows it.
		if matchState.dropSelect then
			bannerTitle.Text = "CHOOSE YOUR DROP  " .. (matchState.countdown or 0)
			bannerSub.Text = "Click the map, or leave it and land somewhere random"
		else
			bannerTitle.Text = "BUILDING MAP…"
			bannerSub.Text = "Generating terrain, towns and loot"
		end
	elseif matchState.state == "InProgress" then
		-- A count of the living means nothing in a respawn mode (#86 C36): there it names the mode.
		local modeDef = matchState.mode and matchState.mode ~= "BattleRoyale"
			and require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GameModes")).Get(matchState.mode)
		bannerTitle.Text = modeDef and string.upper(modeDef.name) or (matchState.aliveCount .. " ALIVE")

		-- No loadout during a live match means this player isn't in it — they joined after
		-- it started, or they've been eliminated and are spectating.
		if not loadout then
			bannerSub.Text = ready and "Not in this match — you'll join the next one"
				or "Not in this match — ready up to join the next one"
		else
			local parts = {}
			if matchState.mapName then
				table.insert(parts, matchState.mapName)
			end
			if matchState.event then
				table.insert(parts, "EVENT: " .. string.upper(matchState.event.name))
			end
			if (matchState.botCount or 0) > 0 then
				table.insert(parts, matchState.botCount .. " bots")
			end
			bannerSub.Text = table.concat(parts, "   •   ")
		end
	else
		bannerTitle.Text = "MATCH OVER"
		bannerSub.Text = ready and "Next match starting soon" or "Ready up to join the next match"
	end
end

-- Your own ready flag comes back as a replicated attribute; redraw when it lands.
player:GetAttributeChangedSignal("Ready"):Connect(renderBanner)

-- Which brainrot is following you, from the profile.
local function applyCompanionProfile(state)
	companionDef = state and state.companion and BrainrotData.Get(state.companion) or nil
	companionLevel = 1
	companionStars = 0
	if companionDef and state.brainrots then
		for _, entry in ipairs(state.brainrots) do
			if entry.name == companionDef.name then
				companionLevel = entry.level or 1
				companionStars = entry.stars or 0
				break
			end
		end
	end
	updateCompanionWidget()
	local matches = state and state.stats and state.stats.matches
	if matches ~= profileMatches then
		profileMatches = matches
		renderBanner()
	end
end

-- The tips rotate while the banner is showing them.
task.spawn(function()
	while true do
		task.wait(7)
		if profileMatches == 0 and matchState.state == "Waiting" then
			tipIndex += 1
			renderBanner()
		end
	end
end)

profileChanged.OnClientEvent:Connect(applyCompanionProfile)
task.spawn(function()
	local ok, result = pcall(function()
		return requestProfile:InvokeServer()
	end)
	if ok and result then
		applyCompanionProfile(result)
	end
end)

-- Your companion just struck: flash the panel in its colour.
companionAttackRemote.OnClientEvent:Connect(function(info)
	if not info or info.owner ~= player.UserId then
		return
	end
	abilityReadyAt = os.clock() + (tonumber(info.cooldown) or 0)
	if not companionFrame.Visible then
		return
	end
	companionStroke.Transparency = 0
	companionDot.Size = UDim2.fromOffset(30, 30)
	TweenService:Create(companionStroke, TweenInfo.new(0.45), { Transparency = 1 }):Play()
	TweenService:Create(companionDot, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(22, 22) }):Play()
end)

-- The pill counts down. It used to read "SPEED BOOST" with no seconds, so a player could not tell
-- whether they had eight seconds of it left or half of one -- and the moment it ends, their speed
-- changes under them with nothing on screen having said it was about to.
--
-- `SpeedBoostUntil` is a SERVER-TIME stamp (MatchService:1040, cleared with the flag at :1052), and
-- `workspace:GetServerTimeNow()` gives the client the same clock, so this needs no remote and cannot
-- drift from the server's own idea of when the boost ends. If the stamp is ever missing the pill
-- falls back to its old wording rather than showing a wrong number.
--
-- Driven off Heartbeat only while the pill is visible: a per-frame connection that exists for the
-- eighteen seconds a boost lasts, not for the whole match.
local speedBoostTick = nil
local function stopSpeedBoostTick()
	if speedBoostTick then
		speedBoostTick:Disconnect()
		speedBoostTick = nil
	end
end

--
-- The same pill carries the other things on you that run out (#86): Bounce Boots, counted down off
-- `BounceBootsUntil` (MovementService, a server-time stamp like the soda's; C17), and spawn protection
-- in a team mode, off the character's `SpawnProtected` (ModeTeams; C32), which ends the moment you
-- shoot. One pill rather than three, so there is still one thing in that spot to keep clear.
local function refreshSpeedPill()
	local function effects()
		local now = workspace:GetServerTimeNow()
		local out = {}
		if player:GetAttribute("SpeedBoosted") == true then
			local endsAt = player:GetAttribute("SpeedBoostUntil")
			local left = endsAt and endsAt - now or 0
			table.insert(out, left > 0 and string.format("SPEED BOOST  %ds", math.ceil(left)) or "SPEED BOOST")
		end
		local boots = player:GetAttribute("BounceBootsUntil")
		if boots and boots - now > 0 then
			table.insert(out, string.format("BOUNCE BOOTS  %ds", math.ceil(boots - now)))
		end
		if player.Character and player.Character:GetAttribute("SpawnProtected") == true then
			table.insert(out, "PROTECTED")
		end
		return out
	end
	local current = effects()
	hudLayout.show(speedPill, #current > 0)
	if #current == 0 then
		stopSpeedBoostTick()
		speedPill.Text = "SPEED BOOST"
		return
	end
	speedPill.Text = table.concat(current, "  •  ")
	if speedBoostTick then
		return
	end
	speedBoostTick = RunService.Heartbeat:Connect(function()
		local live = effects()
		if #live == 0 then
			refreshSpeedPill()
		else
			speedPill.Text = table.concat(live, "  •  ")
		end
	end)
end

player:GetAttributeChangedSignal("SpeedBoosted"):Connect(refreshSpeedPill)
player:GetAttributeChangedSignal("BounceBootsUntil"):Connect(refreshSpeedPill)
player.CharacterAdded:Connect(function(character)
	character:GetAttributeChangedSignal("SpawnProtected"):Connect(refreshSpeedPill)
	refreshSpeedPill()
end)
if player.Character then
	player.Character:GetAttributeChangedSignal("SpawnProtected"):Connect(refreshSpeedPill)
end
refreshSpeedPill()

--------------------------------------------------------------------------------
-- Match event banner (StarterPlayerScripts/EventBanner draws it)
--------------------------------------------------------------------------------

-- A match's event lands as a big card under the compass (icon, name, what it does, a timer), holds for
-- a few seconds and shrinks into a pill beside the top banner for the rest of the match. Tapping the
-- pill brings the card back. It replaces the one-line toast the event used to get.
-- In a do-block: this script's main chunk is close to Luau's 200-local limit.
do
	-- Under pcall: if the module ever fails to load, the event still gets its old one-line toast and the
	-- rest of this script carries on.
	local okBanner, eventBanner = pcall(function()
		local EventBanner = require(script.Parent:WaitForChild("EventBanner"))
		return EventBanner.new(screenGui, {
			onAnnounce = function()
				Sfx.Play("CrateOpen", nil, 1.12)
			end,
		})
	end)
	if not okBanner then
		warn("[HudClient] EventBanner didn't load; events fall back to a toast: " .. tostring(eventBanner))
		local function none() end
		eventBanner = { SetViewport = none, SetDock = none, SetTimer = none, Clear = none, Dock = none }
		function eventBanner.Announce(_, event)
			showToast(string.format("EVENT: %s — %s", string.upper(event.name or ""), event.description or ""))
		end
	end
	local announcedEventId = nil
	local latest = nil
	local liveSince = nil

	local function rescale()
		eventBanner:SetViewport(camera.ViewportSize)
	end
	rescale()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

	-- The pill takes the READY pill's place while that's hidden (you're in the match), and sits just
	-- under it while it shows (spectating, or staying in the lobby).
	local function redock()
		eventBanner:SetDock(readyButton.Visible and "below" or "slot")
	end
	readyButton:GetPropertyChangedSignal("Visible"):Connect(redock)
	redock()

	local function refreshTimer()
		if not latest then
			return
		end
		if latest.state == "Loading" then
			if latest.dropSelect then
				eventBanner:SetTimer("drop", latest.countdown or 0)
			else
				eventBanner:SetTimer("building")
			end
		else
			-- Only a match this client saw start has a clock; someone who joined mid-match gets "LIVE".
			eventBanner:SetTimer("live", liveSince and os.clock() - liveSince or nil)
		end
	end

	matchChanged.OnClientEvent:Connect(function(state)
		local previous = latest and latest.state
		latest = state
		if state.state == "InProgress" and previous ~= "InProgress" then
			liveSince = previous == "Loading" and os.clock() or nil
		elseif state.state ~= "InProgress" then
			liveSince = nil
		end

		-- MatchService keeps sending the last match's event after it ends, so it only counts while
		-- a match is loading or on. Clearing it at the end means the same event rolled twice in a
		-- row is announced both times.
		local event = (state.state == "Loading" or state.state == "InProgress") and state.event or nil
		local eventId = event and event.id or nil
		if eventId ~= announcedEventId then
			announcedEventId = eventId
			if event then
				refreshTimer()
				eventBanner:Announce(event)
			else
				eventBanner:Clear()
			end
		else
			refreshTimer()
		end
		-- The drop screen takes the middle of the screen: the card gets out of its way.
		if state.dropSelect then
			eventBanner:Dock()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(0.25)
			if announcedEventId then
				refreshTimer()
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Defense placement preview (StarterPlayerScripts/DefensePreview draws it)
--------------------------------------------------------------------------------

-- While a Rot Barricade, Pop-up Bunker or Brainrot Fortress is in hand: a see-through ghost of exactly
-- what DefenseService will build, where the throw will put it, green for a good site and red with the
-- reason for a bad one, under the dotted lob and a ring for where the kit comes to rest. A Rot Mine gets
-- the lob and the ring. In a do-block: this script's main chunk is close to Luau's 200-local limit.
do
	-- A module that fails to load, or a preview that errors, switches the preview off with one warning
	-- instead of an error every frame; throwing works exactly the same without it.
	local okModule, DefensePreview = pcall(function()
		return require(script.Parent:WaitForChild("DefensePreview"))
	end)
	if not okModule then
		warn("[HudClient] DefensePreview didn't load; no placement preview: " .. tostring(DefensePreview))
	end
	local preview = nil
	local broken = not okModule
	RunService.RenderStepped:Connect(function()
		if broken then
			return
		end
		local slot = loadout and loadout.equipped and loadout.slots[loadout.equipped]
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local holding = slot and slot.kind == "item" and slot.itemKind == "defense" and matchState.state == "InProgress"
			and humanoid ~= nil and humanoid.Health > 0 and not player:GetAttribute("MenuOpen")
		local ok, err = pcall(function()
			-- Its parts live under the camera; a replaced camera takes them with it, so start afresh.
			if preview and not preview.root.Parent then
				preview = nil
			end
			if holding then
				preview = preview or DefensePreview.new()
				preview:Update(character, slot.id)
			elseif preview then
				preview:Hide()
			end
		end)
		if not ok then
			broken = true
			warn("[HudClient] the defense placement preview stopped: " .. tostring(err))
			pcall(function()
				preview:Destroy()
			end)
		end
	end)
end

-- Ambient particles for the map you're on: an invisible box that rides along ahead of the
-- camera, emitting whatever MapData.Ambient says — pollen, dust, blown sand, mist, fireflies.
local ambientPart = nil
local ambientMap = nil

local function ambientPresetFor(mapName)
	for _, id in ipairs(MapData.Order) do
		local preset = MapData.Maps[id]
		if preset.name == mapName and MapData.Ambient[id] then
			return id, MapData.Ambient[id]
		end
	end
	return nil
end

local function updateAmbient()
	local id, settings = nil, nil
	if matchState.state == "InProgress" and matchState.mapName and Settings.Get("AmbientParticles") then
		id, settings = ambientPresetFor(matchState.mapName)
	end
	if id == ambientMap then
		return
	end
	ambientMap = id
	if ambientPart then
		ambientPart:Destroy()
		ambientPart = nil
	end
	if not settings then
		return
	end

	ambientPart = Instance.new("Part")
	ambientPart.Name = "BRR_Ambient"
	ambientPart.Size = Vector3.new(90, 36, 90)
	ambientPart.Transparency = 1
	ambientPart.Anchored = true
	ambientPart.CanCollide = false
	ambientPart.CanQuery = false
	ambientPart.CanTouch = false
	ambientPart.CastShadow = false

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(settings.color)
	emitter.Size = NumberSequence.new(settings.size)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, settings.transparency),
		NumberSequenceKeypoint.new(0.85, settings.transparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = settings.lightEmission
	emitter.Lifetime = NumberRange.new(settings.lifetime * 0.7, settings.lifetime)
	emitter.Rate = settings.rate
	emitter.Speed = NumberRange.new(settings.speed * 0.5, settings.speed)
	emitter.Acceleration = settings.acceleration
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Parent = ambientPart
	ambientPart.Parent = workspace.CurrentCamera
end

RunService.RenderStepped:Connect(function()
	if ambientPart then
		local view = workspace.CurrentCamera.CFrame
		ambientPart.CFrame = CFrame.new(view.Position + view.LookVector * 24 + Vector3.new(0, 4, 0))
	end
end)

Settings.Changed:Connect(function(id)
	if id == "*" or id == "AmbientParticles" then
		updateAmbient()
	end
end)

local lastMatchState = nil

matchChanged.OnClientEvent:Connect(function(state)
	local previous = lastMatchState
	lastMatchState = state.state
	matchState = state
	updateAmbient()
	Drop.update()

	-- The map's name across the screen as the match begins (the event under it, if there is one).
	if state.state == "InProgress" and previous ~= "InProgress" and state.mapName and loadout then
		enteringToken += 1
		local token = enteringToken
		enteringLabel.Text = string.upper(state.mapName) .. (state.event and ("   •   " .. string.upper(state.event.name)) or "")
		enteringLabel.TextColor3 = state.event and (state.event.color or C.Accent) or C.Text
		enteringLabel.TextTransparency = 1
		TweenService:Create(enteringLabel, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
		task.delay(3.5, function()
			if token == enteringToken then
				TweenService:Create(enteringLabel, TweenInfo.new(0.8), { TextTransparency = 1 }):Play()
			end
		end)
	end
	if state.state ~= "InProgress" then
		activeDrop = nil
		hudLayout.show(bountyLabel, false)
	end
	-- The match's event is announced by the event banner ("Match event banner", above).
	renderBanner()
	renderVote(latestVote)
	if state.state ~= "Results" then
		resultsPanel.Visible = false
	end
end)

loadoutChanged.OnClientEvent:Connect(function(newLoadout)
	loadout = newLoadout
	trackUse(newLoadout)
	renderWeapon()
	-- The banner's subtitle depends on whether we're in the match, which this tells us.
	renderBanner()

	-- "RAISING" only lasts a moment and no push arrives when it ends, so redraw ourselves —
	-- unless a newer push has already replaced this loadout.
	local raiseFor = newLoadout and newLoadout.equipReadyIn or 0
	if raiseFor > 0.05 then
		local snapshot = newLoadout
		task.delay(raiseFor, function()
			if loadout == snapshot then
				loadout = table.clone(snapshot)
				loadout.equipReadyIn = 0
				renderWeapon()
			end
		end)
	end
end)

renderBanner()
renderWeapon()

--------------------------------------------------------------------------------
-- Companion ability tile (bottom-left, beside the companion panel): the brainrot's portrait,
-- the key that uses its move and a ring that refills with the cooldown. Shown in the lobby too,
-- where the move is a practice demo. The tile itself is StarterPlayerScripts/CompanionAbilityIcon.
-- A do-block, so none of it counts toward the main chunk's 200-local limit.
--------------------------------------------------------------------------------

do
	local CompanionAbilityIcon = require(script.Parent:WaitForChild("CompanionAbilityIcon"))
	local abilityIcon = CompanionAbilityIcon.new(screenGui)
	local statsFor, statsKey = nil, nil

	-- On a touch screen the tile goes in PhoneLayout's pet-tile slot (`Rects().petIcon`, above the
	-- thumbstick's rest). Its own spot is worked out from the desktop hotbar, which on an 844x390 phone
	-- put it on the thumbstick and on an upright one 400 px off the left edge (#80). Its UIScale is its
	-- pop animation, so the phone size comes from a holder with a scale of its own (as the READY pill's
	-- does). The holder is a bare box, so everything that shows, hides or animates the tile still works.
	-- In a function of its own under pcall: the main chunk is at Luau's 200-local limit, and if the layout
	-- fails to load the tile keeps its desktop spot.
	xpcall(function()
		local okLayout, PhoneLayout = pcall(require, script.Parent:WaitForChild("PhoneLayout"))
		local tile = abilityIcon.frame
		local home = { anchor = tile.AnchorPoint, position = tile.Position }
		local size = CompanionAbilityIcon.Size
		local holder = create("Frame", {
			Name = "PhoneAbilityHolder",
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 1,
			Parent = screenGui,
		})
		local holderScale = create("UIScale", { Parent = holder })
		local function placeTile()
			local viewport = camera.ViewportSize
			local spot = okLayout and PhoneLayout.Active(viewport) and PhoneLayout.Rects(viewport).petIcon or nil
			if spot then
				holderScale.Scale = math.min(spot.w, spot.h) / size
				holder.Position = UDim2.fromOffset(spot.x, spot.y)
				tile.AnchorPoint = Vector2.new(0, 0)
				tile.Position = UDim2.fromOffset(0, 0)
				tile.Parent = holder
			else
				tile.AnchorPoint = home.anchor
				tile.Position = home.position
				tile.Parent = screenGui
			end
			-- The move-and-stats line above the tile grows leftward from its right edge, which from the
			-- phone slot at the left edge is off the screen and over the companion strip. The tile hides it
			-- there once CompanionAbilityIcon has SetCompact (proposed with #80); until then this is a no-op.
			if abilityIcon.SetCompact then
				abilityIcon:SetCompact(spot ~= nil)
			end
		end
		placeTile()
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(placeTile)
		UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(placeTile)
	end, function(err)
		warn("[HudClient] the ability tile's phone spot didn't load; it keeps its desktop spot: " .. tostring(err))
	end)

	-- The badge names the control this player would actually press: their own keyboard key, the
	-- gamepad's Y button, or nothing on a touch screen, where the on-screen button is the control.
	-- Same device test as KeyHintClient uses for world labels.
	local function refreshKey()
		local last = UserInputService:GetLastInputType()
		if last == Enum.UserInputType.Touch then
			abilityIcon:SetKey(nil)
		elseif string.find(last.Name, "Gamepad", 1, true) then
			abilityIcon:SetKey("Y")
		elseif UserInputService.KeyboardEnabled then
			abilityIcon:SetKey(Settings.KeyLabel("Companion"))
		else
			abilityIcon:SetKey(nil)
		end
	end
	refreshKey()
	Settings.Changed:Connect(refreshKey)
	UserInputService.LastInputTypeChanged:Connect(refreshKey)

	companionAttackRemote.OnClientEvent:Connect(function(info)
		if type(info) == "table" and info.owner == player.UserId then
			abilityIcon:Used()
		end
	end)

	RunService.RenderStepped:Connect(function()
		abilityIcon:SetBrainrot(companionDef)
		if not companionDef then
			return
		end
		local key = companionDef.name .. "|" .. tostring(companionLevel) .. "|" .. tostring(companionStars)
		if key ~= statsKey then
			statsKey, statsFor = key, BrainrotData.Stats(companionDef, companionLevel, companionStars)
			-- The same stats the cooldown already came from, now also said out loud on the tile
			-- (Oliver's #14). Only on a change, so it isn't rebuilt every frame.
			abilityIcon:SetStats(statsFor, companionDef.move)
		end
		abilityIcon:Update(abilityReadyAt - os.clock(), statsFor.cooldown, player:GetAttribute("CompanionFallen") == true,
			player:GetAttribute("MenuOpen") == true)
	end)
end

--------------------------------------------------------------------------------
-- Centred panels on a small screen (StarterPlayerScripts/PhoneLayout)
--------------------------------------------------------------------------------

-- The results card is 460x410 and the map vote 620x260, authored for a desktop screen; on a 390-tall
-- phone the card's last row is off the bottom. FitPanel gives each one a UIScale that keeps it inside
-- the viewport with a 16-pixel margin and never grows it, so on any screen with the room the scale is
-- exactly 1 and nothing changes. The drop screen does the same inside its own block above.
-- In a do-block under pcall: if PhoneLayout ever fails to load, the panels stay as they were.
do
	local ok, err = pcall(function()
		local PhoneLayout = require(script.Parent:WaitForChild("PhoneLayout"))
		PhoneLayout.FitPanel(votePanel, Vector2.new(620, 260))
		PhoneLayout.FitPanel(resultsPanel, Vector2.new(460, 410))
		PhoneLayout.FitPanel(recapPanel, Vector2.new(480, 104))
	end)
	if not ok then
		warn("[HudClient] the panel fitting didn't load; the results card and the map vote keep their size: " .. tostring(err))
	end
end
