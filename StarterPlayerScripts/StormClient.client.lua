-- Draws the storm wall locally, as a hollow ring.
--
-- The server used to build the wall as solid volumes: a giant cylinder you stood inside and a
-- 6-stud neon disc across the whole safe zone. From inside the circle both tinted everything,
-- which read as fog lying on the ground. This builds a ring of thin wall segments instead, so
-- the view inside the zone is completely clear and the storm only shows where its edge is.
--
-- Doing it here also means a shrinking storm costs no replication, and it can smooth between
-- the server's half-second radius updates instead of stepping.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local stormChanged = Remotes.Event("StormChanged")

local SEGMENTS = 96
-- The wall runs well below and above the terrain, so hills never poke out of it.
local WALL_BOTTOM, WALL_TOP = -60, 900
-- A brighter strip low down marks the edge at eye level.
local BAND_BOTTOM, BAND_TOP = -20, 45

local WALL_COLOR = Color3.fromRGB(158, 96, 255)
local BAND_COLOR = Color3.fromRGB(198, 150, 255)
local WALL_TRANSPARENCY = 0.86
local BAND_TRANSPARENCY = 0.55

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

local walls, bands = {}, {}
for index = 1, SEGMENTS do
	walls[index] = segment(WALL_COLOR, WALL_TRANSPARENCY)
	bands[index] = segment(BAND_COLOR, BAND_TRANSPARENCY)
end

local target = nil
local shownCenter, shownRadius = Vector3.zero, 0
local drawnCenter, drawnRadius = nil, nil
local bandTransparency = BAND_TRANSPARENCY

local function layout(center, radius)
	-- A stud of overlap closes the seams between neighbouring segments.
	local length = 2 * math.pi * radius / SEGMENTS + 1
	local flatCenter = Vector3.new(center.X, 0, center.Z)

	for index = 1, SEGMENTS do
		local angle = (index - 0.5) / SEGMENTS * math.pi * 2
		local base = flatCenter + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		-- Facing the centre puts each segment's X axis along the ring.
		local look = CFrame.lookAt(base, flatCenter)

		walls[index].Size = Vector3.new(length, WALL_TOP - WALL_BOTTOM, 1.5)
		walls[index].CFrame = look + Vector3.new(0, (WALL_TOP + WALL_BOTTOM) / 2, 0)

		bands[index].Size = Vector3.new(length, BAND_TOP - BAND_BOTTOM, 2)
		bands[index].CFrame = look + Vector3.new(0, (BAND_TOP + BAND_BOTTOM) / 2, 0)
	end
end

stormChanged.OnClientEvent:Connect(function(info)
	if not info or info.status == "Idle" or not info.radius or info.radius < 2 then
		target = nil
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
