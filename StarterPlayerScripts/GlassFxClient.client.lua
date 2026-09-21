-- Window glass breaking, drawn locally. DestructibleService removes a pane on the server and sends
-- every pane broken that frame in one GlassShatter event ({ cframe, size, color, from } each, where
-- `from` is where the shot or blast came from, when known). Here the pane cracks white for an
-- instant and bursts: most shards blow through away from the shot, a few spall back toward it, and
-- they land on the floor under them, lie there glinting a moment and fade. Nothing replicates, and
-- the pane is already gone for everyone, so a player who joins later just sees an open window.
--
-- Shards are capped (per pane and in total) and skipped out of sight range, so a rocket through a
-- row of windows costs a bounded number of tiny local parts rather than a physics storm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local glassShatter = Remotes.Event("GlassShatter")
local camera = workspace.CurrentCamera

local EFFECT_DISTANCE = 260
local MAX_ACTIVE = 150
local PER_PANE_MIN, PER_PANE_MAX = 10, 18
local SOUNDS_PER_BATCH = 3
local FLASHES_PER_BATCH = 6
-- Share of shards thrown back toward the shot rather than through with it.
local SPALL = 0.2
local REST_TIME = 1.6
local FADE_TIME = 0.9
local MAX_FLIGHT = 2.5
-- Resting shards lie this far above the floor: well clear of its face, so they never flicker on it.
local REST_LIFT = 0.1

local fxFolder = Instance.new("Folder")
fxFolder.Name = "GlassFx"
fxFolder.Parent = workspace

-- shard -> { floor = y or nil, born = clock }
local flying = {}
local active = 0

local function floorBelow(point)
	local map = workspace:FindFirstChild("Map")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = map and { map, workspace.Terrain } or { workspace.Terrain }
	local hit = workspace:Raycast(point, Vector3.new(0, -40, 0), params)
	return hit and hit.Position.Y or nil
end

local function retire(shard, delay)
	task.delay(delay, function()
		if shard.Parent then
			TweenService:Create(shard, TweenInfo.new(FADE_TIME), { Transparency = 1 }):Play()
			task.delay(FADE_TIME, function()
				shard:Destroy()
				active -= 1
			end)
		else
			active -= 1
		end
	end)
end

-- The instant of breaking: the pane goes white along its cracks and is gone.
local function flash(cframe, size)
	local sheet = Instance.new("Part")
	sheet.Name = "GlassCrack"
	sheet.Size = Vector3.new(size.X, size.Y, 0.06)
	sheet.CFrame = cframe
	sheet.Color = Color3.fromRGB(235, 248, 255)
	sheet.Material = Enum.Material.Neon
	sheet.Transparency = 0.45
	sheet.Anchored = true
	sheet.CanCollide = false
	sheet.CanQuery = false
	sheet.CanTouch = false
	sheet.CastShadow = false
	sheet.Parent = fxFolder
	TweenService:Create(sheet, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 1 }):Play()
	task.delay(0.16, function()
		sheet:Destroy()
	end)
end

local function burst(cframe, size, color, from)
	local normal = cframe.LookVector
	-- Which way the shot was travelling through the pane: +1 along its normal, -1 against it.
	local through = (math.random() < 0.5) and 1 or -1
	if typeof(from) == "Vector3" then
		through = normal:Dot(cframe.Position - from) >= 0 and 1 or -1
	end
	local bottom = cframe * Vector3.new(0, -size.Y / 2, 0)
	-- The floor on each side of the window, found once for the whole pane.
	local floors = {
		[1] = floorBelow(bottom + normal * 1.5 + Vector3.new(0, 0.5, 0)),
		[-1] = floorBelow(bottom - normal * 1.5 + Vector3.new(0, 0.5, 0)),
	}
	local count = math.clamp(math.floor(size.X * size.Y / 1.6), PER_PANE_MIN, PER_PANE_MAX)
	count = math.min(count, MAX_ACTIVE - active)
	for index = 1, count do
		-- A mix of big triangular pieces and small slivers.
		local big = index <= math.ceil(count * 0.35)
		local shard = Instance.new(big and "WedgePart" or "Part")
		shard.Name = "GlassShard"
		if big then
			shard.Size = Vector3.new(0.05, 0.55 + math.random() * 0.7, 0.45 + math.random() * 0.7)
		else
			shard.Size = Vector3.new(0.05, 0.12 + math.random() * 0.3, 0.1 + math.random() * 0.25)
		end
		local offset = Vector3.new((math.random() - 0.5) * size.X * 0.9, (math.random() - 0.5) * size.Y * 0.9, 0)
		-- A shard's thin side is its X; turned so each one starts in the plane of the pane.
		shard.CFrame = cframe * CFrame.new(offset) * CFrame.Angles(0, math.pi / 2, math.random() * math.pi * 2)
		shard.Color = color:Lerp(Color3.new(1, 1, 1), 0.3 + math.random() * 0.2)
		shard.Material = Enum.Material.Glass
		shard.Transparency = 0.2 + math.random() * 0.2
		shard.Reflectance = 0.25
		shard.CanCollide = false
		shard.CanQuery = false
		shard.CanTouch = false
		shard.CastShadow = false
		shard.Massless = true
		shard.Parent = fxFolder
		local side = math.random() < SPALL and -through or through
		local speed = side == through and (7 + math.random() * 11) or (2 + math.random() * 4)
		-- Pieces from the middle of the pane, where the shot went, fly fastest.
		local centre = 1 - math.clamp(offset.Magnitude / (size.Magnitude / 2), 0, 1) * 0.5
		shard.AssemblyLinearVelocity = normal * side * speed * centre
			+ cframe.RightVector * offset.X * (0.8 + math.random())
			+ Vector3.new(0, 1 + math.random() * 5 + offset.Y * 0.5, 0)
		local spin = big and 8 or 16
		shard.AssemblyAngularVelocity = Vector3.new(math.random(-spin, spin), math.random(-spin, spin), math.random(-spin, spin))
		active += 1
		flying[shard] = { floor = floors[side], born = os.clock() }
	end
end

glassShatter.OnClientEvent:Connect(function(batch)
	if type(batch) ~= "table" or not camera then
		return
	end
	local sounds, flashes = 0, 0
	for _, entry in ipairs(batch) do
		local cframe, size, color, from = entry[1], entry[2], entry[3], entry[4]
		if typeof(cframe) == "CFrame" and typeof(size) == "Vector3" and typeof(color) == "Color3"
			and (cframe.Position - camera.CFrame.Position).Magnitude <= EFFECT_DISTANCE then
			if sounds < SOUNDS_PER_BATCH then
				sounds += 1
				Sfx.PlayAt("Shatter", cframe.Position, 0.25)
			end
			if flashes < FLASHES_PER_BATCH then
				flashes += 1
				flash(cframe, size)
			end
			if active < MAX_ACTIVE then
				burst(cframe, size, color, from)
			end
		end
	end
end)

-- Shards that reach their floor stop there, lying flat, then fade. Ones that never find a floor
-- (thrown out of a high window over a long drop) fade in the air instead.
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for shard, info in pairs(flying) do
		if not shard.Parent then
			flying[shard] = nil
			active -= 1
		elseif info.floor and shard.Position.Y <= info.floor + REST_LIFT and shard.AssemblyLinearVelocity.Y <= 0 then
			flying[shard] = nil
			shard.Anchored = true
			local position = shard.Position
			shard.CFrame = CFrame.new(position.X, info.floor + REST_LIFT, position.Z)
				* CFrame.Angles(0, math.random() * math.pi * 2, math.pi / 2)
			retire(shard, REST_TIME)
		elseif now - info.born > MAX_FLIGHT then
			flying[shard] = nil
			retire(shard, 0)
		end
	end
end)
