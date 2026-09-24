-- Which way the gunfire is coming from (#22, "directional HUD cue for nearby bullet sounds").
--
-- Every shot already reaches every client on the ShotFired remote (CombatService.BroadcastShot,
-- `FireAllClients(shooterPlayer, origin, endPoints, rarity)`), and CombatClient already plays it as a
-- positional sound at `origin`. A sound tells a player a fight is near; it does not reliably tell them
-- WHERE on a laptop speaker or a phone. So this listens to the same remote -- no server change -- and
-- draws a small chevron on a ring round the crosshair, pointing at the shooter, for a second and a half.
--
-- What it leaves out, and why:
--   * your own shots and your teammates' -- you know where those are, and a ring full of friendly
--     chevrons in a team match would hide the one that matters;
--   * anything out of earshot (EARSHOT below, the same 400 studs Sfx uses as its default range), so the
--     cue never tells you about a shot you could not have heard;
--   * everything while a menu is open, while you are dead or spectating, and outside a match.
-- A burst from one gun refreshes the chevron already pointing that way rather than stacking more, and
-- there are never more than MAX_CUES at once: the oldest makes way.
--
-- THE DIRECTION IS YAW ONLY. The source is flattened into the camera's horizontal frame, built from the
-- camera's RightVector (always level: the camera never rolls), so it stays right when you look straight
-- down or up, where a flattened LookVector would collapse to nothing. Angle 0 is straight ahead and it
-- grows clockwise, the way the ring is drawn. tools/gunfire_cue_check.py runs the block marked PURE
-- below and holds it to that on every screen size.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local MovementState = require(script.Parent:WaitForChild("MovementState"))

local create, rounded = UiKit.create, UiKit.rounded
local Role = UiKit.Role

local player = Players.LocalPlayer

local EARSHOT = 400
local LIFETIME = 1.5
local MAX_CUES = 4
-- Two shots this close in angle are one source as far as the player can tell.
local MERGE_DEGREES = 20

-- PURE BEGIN (tools/gunfire_cue_check.py runs this block on its own; plain Lua, no Roblox types)

-- The shot's direction as a screen angle in radians: 0 = straight ahead, positive = clockwise (to the
-- right), in (-pi, pi]. nil when the source is right on top of you and has no direction worth drawing.
-- `right` is the camera's RightVector; `offset` is source minus camera position. Anything with X/Y/Z.
local function cueAngle(right, offset)
	local rx, rz = right.X, right.Z
	local length = math.sqrt(rx * rx + rz * rz)
	if length < 1e-6 then
		return nil
	end
	rx, rz = rx / length, rz / length
	-- Level forward is the right vector turned a quarter to the left: (rz, -rx) in X/Z.
	local fx, fz = rz, -rx
	local across = offset.X * rx + offset.Z * rz
	local ahead = offset.X * fx + offset.Z * fz
	if across * across + ahead * ahead < 9 then
		return nil
	end
	return math.atan2(across, ahead)
end

-- The ring round the crosshair: its radius for a viewport, and where on it an angle lands, in the
-- ScreenGui's pixels (IgnoreGuiInset, so the viewport centre is the crosshair). A fraction of the short
-- side, so it sits the same way on a phone and a monitor, with a floor so it clears the crosshair and a
-- ceiling so it stays near the middle of a big screen.
local function ringRadius(width, height)
	return math.max(80, math.min(240, math.min(width, height) * 0.26))
end

local function ringPoint(width, height, angle)
	local radius = ringRadius(width, height)
	return width / 2 + radius * math.sin(angle), height / 2 - radius * math.cos(angle)
end

-- How strong a cue starts: a shot at arm's length is loud, one at the edge of earshot is faint.
local function cueStrength(distance)
	return 1 - 0.6 * math.min(1, math.max(0, distance / EARSHOT))
end

-- PURE END

local shotFired = Remotes.Event("ShotFired")

local gui = create("ScreenGui", {
	Name = "GunfireCue",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	-- Under the HUD's own layer (8) so a panel always covers it.
	DisplayOrder = 6,
	Parent = player:WaitForChild("PlayerGui"),
})

-- One chevron: a holder turned to the angle, with a "^" of two bars at its top.
local function makeChevron()
	local holder = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(28, 16),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	local bars = {}
	for index, rotation in ipairs({ -35, 35 }) do
		bars[index] = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, (index == 1) and -6 or 6, 0.5, 0),
			Size = UDim2.fromOffset(15, 4),
			Rotation = rotation,
			BackgroundColor3 = Role.Negative,
			BorderSizePixel = 0,
			Parent = holder,
		}, {
			rounded(2),
			create("UIStroke", { Color = Role.Scrim, Thickness = UiKit.Stroke.Hairline, Transparency = 0.4 }),
		})
	end
	return { holder = holder, bars = bars, age = 0, angle = 0, strength = 0, source = nil }
end

local cues = {}
for index = 1, MAX_CUES do
	cues[index] = makeChevron()
end

local function suppressed()
	if player:GetAttribute("MenuOpen") == true or not MovementState.inMatch then
		return true
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return not humanoid or humanoid.Health <= 0
end

-- Who fired: a player comes named; a bot comes as nil, and its shot starts at its head (the lookup
-- CombatClient's shooterGun uses for the same reason).
local headQuery = OverlapParams.new()
headQuery.MaxParts = 12
local function shooterCharacter(shooter, origin)
	if typeof(shooter) == "Instance" and shooter:IsA("Player") then
		return shooter.Character
	end
	for _, part in ipairs(workspace:GetPartBoundsInRadius(origin, 0.75, headQuery)) do
		if part.Name == "Head" and part.Parent then
			return part.Parent
		end
	end
	return nil
end

-- Same test EnemyAura paints by: a teammate shares your Team attribute. No team (battle royale solos)
-- means everyone is an enemy.
local function isFriendly(shooter, origin)
	local mine = player.Character and player.Character:GetAttribute("Team")
	if mine == nil then
		return false
	end
	local character = shooterCharacter(shooter, origin)
	return character ~= nil and character ~= player.Character and character:GetAttribute("Team") == mine
end

local function hide(cue)
	cue.holder.Visible = false
	cue.source = nil
end

local function draw(cue, camera)
	local angle = cueAngle(camera.CFrame.RightVector, cue.source - camera.CFrame.Position)
	if not angle then
		cue.holder.Visible = false
		return
	end
	cue.angle = angle
	local viewport = camera.ViewportSize
	local x, y = ringPoint(viewport.X, viewport.Y, angle)
	cue.holder.Position = UDim2.fromOffset(x, y)
	cue.holder.Rotation = math.deg(angle)
	local fade = 1 - cue.age / LIFETIME
	local transparency = 1 - cue.strength * fade * 0.9
	for _, bar in ipairs(cue.bars) do
		bar.BackgroundTransparency = transparency
	end
	cue.holder.Visible = true
end

shotFired.OnClientEvent:Connect(function(shooter, origin, _endPoints, _rarity)
	if shooter == player or typeof(origin) ~= "Vector3" or suppressed() then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local distance = (origin - camera.CFrame.Position).Magnitude
	if distance > EARSHOT or isFriendly(shooter, origin) then
		return
	end
	local angle = cueAngle(camera.CFrame.RightVector, origin - camera.CFrame.Position)
	if not angle then
		return
	end

	-- Refresh a live cue already pointing this way; else take a free slot; else the oldest.
	local pick, free, oldest = nil, nil, nil
	for _, cue in ipairs(cues) do
		if cue.source then
			local apart = math.abs((angle - cue.angle + math.pi) % (2 * math.pi) - math.pi)
			if not pick and math.deg(apart) <= MERGE_DEGREES then
				pick = cue
			end
			if not oldest or cue.age > oldest.age then
				oldest = cue
			end
		elseif not free then
			free = cue
		end
	end
	local strength = cueStrength(distance)
	if pick then
		-- The louder of the two, so a far shot does not dim a near one already showing that way.
		strength = math.max(strength, pick.strength)
	else
		pick = free or oldest
	end
	pick.source = origin
	pick.angle = angle
	pick.age = 0
	pick.strength = strength
	draw(pick, camera)
end)

-- Frame time from the frame's own dt, not os.clock (CPU time in Roblox, see COORDINATION.md).
RunService.RenderStepped:Connect(function(dt)
	local camera = workspace.CurrentCamera
	local off = suppressed() or not camera
	for _, cue in ipairs(cues) do
		if cue.source then
			cue.age += dt
			if off or cue.age >= LIFETIME then
				hide(cue)
			else
				-- Re-aimed every frame: turn towards the shot and the chevron swings to the top.
				draw(cue, camera)
			end
		end
	end
end)
