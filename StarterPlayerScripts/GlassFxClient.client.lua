-- Window glass breaking, drawn locally. DestructibleService removes a pane on the server and sends
-- every pane broken that frame in one GlassShatter event ({ cframe, size, color, from, impact,
-- transparency } each, where `from` is where the shot or blast came from and `impact` the point on
-- the pane it struck, when known). Here the pane stands a moment longer with a spiderweb of cracks
-- running out from the impact (#71: cracks, then it goes, never a fade), then bursts: the shards
-- nearest the impact fly fastest, most blow through away from the shot, a few spall back toward
-- it, and they land on the floor under them, lie there glinting a moment and fade. Nothing
-- replicates, and the pane is already gone for everyone, so a player who joins later just sees an
-- open window.
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
-- How long the cracked pane stands before it bursts, and the web's rays and rings.
local WEB_TIME = 0.09
local WEB_RAYS_MIN, WEB_RAYS_MAX = 7, 9
local WEB_RINGS = { 0.18, 0.4, 0.7 }
local WEB_COLOR = Color3.fromRGB(240, 248, 255)

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

local function localPart(name, size, cframe, color, material, transparency)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Transparency = transparency
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = fxFolder
	return part
end

-- Where on the pane (in its own x/y) the hit landed: the impact the server sent, else the middle.
local function impactOn(cframe, size, impact)
	if typeof(impact) ~= "Vector3" then
		return 0, 0
	end
	local at = cframe:PointToObjectSpace(impact)
	return math.clamp(at.X, -size.X / 2, size.X / 2), math.clamp(at.Y, -size.Y / 2, size.Y / 2)
end

-- The instant of breaking: a stand-in for the pane (it is already gone on the server) with a
-- spiderweb from the impact, straight rays and rings joining them; it stands WEB_TIME and is gone
-- as the shards fly. Returns the pieces, for the caller to remove.
local function web(cframe, size, color, transparency, ix, iy)
	local pieces = {}
	local thin = math.min(size.Z, 0.06)
	table.insert(pieces, localPart("GlassCrackPane", Vector3.new(size.X, size.Y, thin), cframe, color, Enum.Material.Glass,
		type(transparency) == "number" and transparency or 0.45))
	local hx, hy = size.X / 2, size.Y / 2
	local reach = math.max(size.X, size.Y)
	local function line(x1, y1, x2, y2, width)
		-- Kept on the pane: clamp both ends into it.
		x1, x2 = math.clamp(x1, -hx, hx), math.clamp(x2, -hx, hx)
		y1, y2 = math.clamp(y1, -hy, hy), math.clamp(y2, -hy, hy)
		local dx, dy = x2 - x1, y2 - y1
		local length = math.sqrt(dx * dx + dy * dy)
		if length < 0.03 then
			return
		end
		local frame = cframe * CFrame.new((x1 + x2) / 2, (y1 + y2) / 2, 0) * CFrame.Angles(0, 0, math.atan2(dy, dx))
		-- Both faces of the pane: a line a hair proud of each.
		table.insert(pieces, localPart("GlassCrack", Vector3.new(length, width, thin + 0.03), frame, WEB_COLOR, Enum.Material.SmoothPlastic, 0.05))
	end
	local count = math.random(WEB_RAYS_MIN, WEB_RAYS_MAX)
	local angles = {}
	for ray = 1, count do
		angles[ray] = ray / count * math.pi * 2 + (math.random() - 0.5) * 0.5
		line(ix, iy, ix + math.cos(angles[ray]) * reach, iy + math.sin(angles[ray]) * reach, 0.035)
	end
	for _, share in ipairs(WEB_RINGS) do
		local radius = share * reach
		for ray = 1, count do
			local a, b = angles[ray], angles[ray % count + 1]
			line(ix + math.cos(a) * radius, iy + math.sin(a) * radius, ix + math.cos(b) * radius, iy + math.sin(b) * radius, 0.025)
		end
	end
	return pieces
end

local function burst(cframe, size, color, from, ix, iy)
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
		-- Pieces from where the shot went in fly fastest.
		local centre = 1 - math.clamp((offset - Vector3.new(ix, iy, 0)).Magnitude / (size.Magnitude / 2), 0, 1) * 0.5
		shard.AssemblyLinearVelocity = normal * side * speed * centre
			+ cframe.RightVector * offset.X * (0.8 + math.random())
			+ Vector3.new(0, 1 + math.random() * 5 + offset.Y * 0.5, 0)
		local spin = big and 8 or 16
		shard.AssemblyAngularVelocity = Vector3.new(math.random(-spin, spin), math.random(-spin, spin), math.random(-spin, spin))
		active += 1
		flying[shard] = { floor = floors[side], born = time() }
	end
end

glassShatter.OnClientEvent:Connect(function(batch)
	if type(batch) ~= "table" or not camera then
		return
	end
	local sounds, flashes = 0, 0
	for _, entry in ipairs(batch) do
		local cframe, size, color, from, impact, transparency = entry[1], entry[2], entry[3], entry[4], entry[5], entry[6]
		if typeof(cframe) == "CFrame" and typeof(size) == "Vector3" and typeof(color) == "Color3"
			and (cframe.Position - camera.CFrame.Position).Magnitude <= EFFECT_DISTANCE then
			if sounds < SOUNDS_PER_BATCH then
				sounds += 1
				Sfx.PlayAt("Shatter", cframe.Position, 0.25)
			end
			-- Everything below takes local Z as the pane's thin axis; a pane thin along X (bus-shelter
			-- ends) is turned a quarter about Y, same centre, so it is.
			if size.X < size.Z then
				cframe = cframe * CFrame.Angles(0, math.pi / 2, 0)
				size = Vector3.new(size.Z, size.Y, size.X)
			end
			local ix, iy = impactOn(cframe, size, impact)
			local pieces = nil
			if flashes < FLASHES_PER_BATCH then
				flashes += 1
				pieces = web(cframe, size, color, transparency, ix, iy)
			end
			task.delay(pieces and WEB_TIME or 0, function()
				if pieces then
					for _, piece in ipairs(pieces) do
						piece:Destroy()
					end
				end
				if active < MAX_ACTIVE then
					burst(cframe, size, color, from, ix, iy)
				end
			end)
		end
	end
end)

-- Shards that reach their floor stop there, lying flat, then fade. Ones that never find a floor
-- (thrown out of a high window over a long drop) fade in the air instead.
RunService.Heartbeat:Connect(function()
	-- Wall clock, not os.clock (process CPU time in Roblox).
	local now = time()
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
