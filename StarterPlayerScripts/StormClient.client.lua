-- Draws the storm wall locally, as a hollow ring.
--
-- The server used to build the wall as solid volumes: a giant cylinder you stood inside and a
-- 6-stud neon disc across the whole safe zone. From inside the circle both tinted everything,
-- which read as fog lying on the ground. This builds a ring of thin wall segments instead, so
-- the view inside the zone is completely clear and the storm only shows where its edge is.
--
-- Doing it here also means a shrinking storm costs no replication, and it can smooth between
-- the server's half-second radius updates instead of stepping.

-- #45: the storm is brainrot now. The wall is a deep rot purple (the HUD's storm purple, so the
-- vignette and the wall still read as one thing), the eye-level band is brain pink, and slow
-- swirls of pink-to-lime rot drift up off the band. The swirls are deliberately few: an emitter on
-- every fourth band segment, and only the ones near the camera run at all (#131, lag). Nothing
-- here changes where the edge is or how solid it looks from inside; the band is still the
-- brightest thing at eye level, which is what tells you where the storm starts.
--
-- Sound: crossing out into the storm plays the "StormEnter" cue and crossing back plays
-- "StormLeave" (both in SoundConfig).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local stormChanged = Remotes.Event("StormChanged")

local SEGMENTS = 96
-- The wall runs well below and above the terrain, so hills never poke out of it.
local WALL_BOTTOM, WALL_TOP = -60, 900
-- A brighter strip low down marks the edge at eye level.
local BAND_BOTTOM, BAND_TOP = -20, 45

local WALL_COLOR = Color3.fromRGB(140, 74, 236)
local BAND_COLOR = Color3.fromRGB(255, 112, 206)
local WALL_TRANSPARENCY = 0.84
local BAND_TRANSPARENCY = 0.5

-- The rot swirls: one emitter per EMIT_EVERY band segments, running only within EMIT_RANGE of the
-- camera. At the rate and lifetime below one emitter holds at most about 10 particles, so even a
-- final circle small enough to bring all 24 in range stays near 240 in the whole ring.
local EMIT_EVERY = 4
local EMIT_RANGE = 320
local EMIT_RATE = 2
local SWIRL_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local folder = Instance.new("Folder")
folder.Name = "StormWall"

-- Local-only parts. CanQuery is off so they never intercept the crosshair raycast.
local function segment(color, transparency)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Parent = folder
	return part
end

-- Pink curling up into rot green: brain matter going off. Sized in studs, and spun both ways so
-- the wall looks like it is churning rather than steaming.
local function swirl(host)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RotSwirl"
	emitter.Texture = SWIRL_TEXTURE
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 130, 214)),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(196, 110, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 255, 90)),
	})
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9) })
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 0.35
	emitter.Lifetime = NumberRange.new(3.5, 5)
	emitter.Rate = EMIT_RATE
	emitter.Speed = NumberRange.new(1.5, 4)
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.Acceleration = Vector3.new(0, 2.5, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-70, 70)
	emitter.Enabled = false
	emitter.Parent = host
	return emitter
end

local walls, bands, swirls = {}, {}, {}
for index = 1, SEGMENTS do
	walls[index] = segment(WALL_COLOR, WALL_TRANSPARENCY)
	bands[index] = segment(BAND_COLOR, BAND_TRANSPARENCY)
	if index % EMIT_EVERY == 0 then
		swirls[index] = swirl(bands[index])
	end
end

local target = nil
local shownCenter, shownRadius = Vector3.zero, 0
local drawnCenter, drawnRadius = nil, nil
local bandTransparency = BAND_TRANSPARENCY

local function layout(center, radius)
	-- A stud of overlap closes the seams between neighbouring segments.
	local length = 2 * radius * math.tan(math.pi / SEGMENTS) + 0.02
	local flatCenter = Vector3.new(center.X, 0, center.Z)

	for index = 1, SEGMENTS do
		local angle = (index - 0.5) / SEGMENTS * math.pi * 2
		local base = flatCenter + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		-- Facing the centre puts each segment's X axis along the ring.
		local look = CFrame.lookAt(base, flatCenter)

		walls[index].Size = Vector3.new(length, WALL_TOP - WALL_BOTTOM, 1.5)
		walls[index].CFrame = look + Vector3.new(0, (WALL_TOP + WALL_BOTTOM) / 2, 0)

		-- A tenth longer than the wall, so the two never share an end face.
		bands[index].Size = Vector3.new(length + 0.1, BAND_TOP - BAND_BOTTOM, 2)
		bands[index].CFrame = look + Vector3.new(0, (BAND_TOP + BAND_BOTTOM) / 2, 0)
	end
end

-- Swirls near the camera run; the rest of the ring's are switched off. Re-judged a few times a
-- second rather than every frame: the camera cannot cross an emitter's worth of range that fast.
local swirlClock = 0
local function gateSwirls(force)
	local camera = workspace.CurrentCamera
	local eye = camera and camera.CFrame.Position
	for index, emitter in pairs(swirls) do
		local wanted = false
		if eye and target then
			local offset = bands[index].Position - eye
			wanted = Vector3.new(offset.X, 0, offset.Z).Magnitude < EMIT_RANGE
		end
		if force or emitter.Enabled ~= wanted then
			emitter.Enabled = wanted
		end
	end
end

-- Whether the local player's body is out in the storm, for the enter/leave cues. A body at lobby
-- height is not in the match (a spectator stands on the pier at MatchConfig.LobbyPosition), so it
-- counts as not outside whatever the circle does. A dead body (a spectator's corpse is left where it
-- fell) keeps whatever it last was, so neither the death nor a later circle passing over it sounds a cue.
local wasOutside = false
local function outsideNow()
	local player = Players.LocalPlayer
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not target or root.Position.Y > MatchConfig.LobbyPosition.Y - 100 then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return wasOutside
	end
	local flat = Vector3.new(root.Position.X - target.center.X, 0, root.Position.Z - target.center.Z)
	return flat.Magnitude > target.radius
end

-- The storm's bite (#86 M19). StormService hurts everyone outside once a second, silently: the only
-- sound was the groan on the way out, so a player looting outside the wall heard nothing while their
-- health went. Each tick that takes health while you are outside plays a quiet, higher StormEnter --
-- the same voice, so it reads as the storm, at a third of its volume so it nags rather than alarms.
-- Judged on the 0.4 s poll below from the health actually lost, so it only sounds when damage lands.
local TICK_GAIN, TICK_PITCH, TICK_GAP = 0.3, 1.25, 0.8
local lastHealth, lastTickAt = nil, -math.huge
local function stormTickDue(outside, health, before, now, lastAt)
	return outside and before ~= nil and health > 0 and health < before - 0.5 and now - lastAt >= TICK_GAP
end

stormChanged.OnClientEvent:Connect(function(info)
	-- A tiny or zero radius is sudden death closing (MatchConfig.StormSuddenDeath), not "no storm": the
	-- wall is drawn down to layout's 2-stud floor and outsideNow keeps the storm's cues going.
	if not info or info.status == "Idle" or not info.radius then
		target = nil
		wasOutside = false
		gateSwirls(true)
		folder.Parent = nil
		return
	end

	-- First update of a storm: jump straight there rather than sweeping in from wherever the
	-- last match's circle ended.
	if not target then
		shownCenter, shownRadius = info.center, info.radius
		drawnCenter, drawnRadius = nil, nil
	end
	target = info
	folder.Parent = workspace
end)

RunService.RenderStepped:Connect(function(delta)
	if not target then
		return
	end

	local alpha = math.clamp(delta * 3, 0, 1)
	shownRadius += (target.radius - shownRadius) * alpha
	shownCenter = shownCenter:Lerp(target.center, alpha)

	if not drawnRadius or math.abs(drawnRadius - shownRadius) > 0.05 or (drawnCenter - shownCenter).Magnitude > 0.05 then
		drawnCenter, drawnRadius = shownCenter, shownRadius
		layout(shownCenter, math.max(shownRadius, 2))
	end

	swirlClock += delta
	if swirlClock >= 0.4 then
		swirlClock = 0
		gateSwirls(false)
		local outside = outsideNow()
		local crossed = outside ~= wasOutside
		if crossed then
			wasOutside = outside
			Sfx.Play(outside and "StormEnter" or "StormLeave")
		end
		local character = Players.LocalPlayer and Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local health = humanoid and humanoid.Health or nil
		-- `time()` is game time; os.clock is CPU time in Roblox and runs slow under load.
		if health and not crossed and stormTickDue(outside, health, lastHealth, time(), lastTickAt) then
			lastTickAt = time()
			Sfx.Play("StormEnter", 0.05, TICK_PITCH, TICK_GAIN)
		end
		lastHealth = health
	end

	-- The band pulses while the circle is closing.
	local wanted = BAND_TRANSPARENCY
	if target.status == "Shrinking" then
		wanted = 0.3 + math.abs(math.sin(os.clock() * 3)) * 0.25
	end
	if math.abs(wanted - bandTransparency) > 0.01 then
		bandTransparency = wanted
		for index = 1, SEGMENTS do
			bands[index].Transparency = wanted
		end
	end
end)
