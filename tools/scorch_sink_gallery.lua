-- A blast's scorch following the ground down into the crater the same blast digs (SCORCH_SINK,
-- tools/scorch_sink_check.py), for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/scorch_sink_gallery.lua -OutDir <folder> -PlaceFile <build> -TimeoutSeconds 1500
--
-- On a flat grass slab far off the origin, the deepest blast that draws a scorch (an explosive
-- barrel: grenade look, radius 15, crater at CRATER_MAX), drawn by the real ExplosiveFx on the
-- ground as it was, then the real DestructibleService.CraterAt under it, then the relays run out
-- (6 s). One spot takes one blast, the other two in a row (the second on the first one's floor).
-- What to look at: the nine dark patches lying on the charred floor of the bowl, none left hanging
-- at the old ground level and none missing. The note line counts the patches drawn and how far the
-- lowest one is under the ground it started on.

local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local modules = ServerScriptService:WaitForChild("Modules")
local ExplosiveFx = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("ExplosiveFx"))

ExplosiveFx.Paused = true
ExplosiveFx.TrustNormal = false

local SLAB_AT = Vector3.new(-2400, 0, 2400)
local SPOTS = { one = Vector3.new(-2440, 0, 2400), two = Vector3.new(-2360, 0, 2400) }
local REACH, WALL = 15, 78 * 1.2 -- HazardService's barrel: its full radius and baseDamage x 1.2

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { workspace.Terrain }

local function groundAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 80, z), Vector3.new(0, -200, 0), params)
	return hit and hit.Position.Y or nil
end

local function advance(seconds)
	local t = 0
	while t < seconds - 1e-6 do
		local dt = math.min(1 / 30, seconds - t)
		ExplosiveFx.Advance(dt)
		t += dt
	end
end

-- Every scorch patch there is now (drawn or not), as a set.
local function patchSet()
	local set = {}
	for _, d in ipairs(ExplosiveFx.Folder():GetChildren()) do
		if d.Name == "Scorch" or d.Name == "ScorchEdge" then
			set[d] = true
		end
	end
	return set
end

-- Of the patches not in `before` (this blast's), how many are still drawn, and the lowest one's height.
local function patches(before)
	local drawn, lowest = 0, math.huge
	for d in pairs(patchSet()) do
		if not before[d] and d.Transparency < 0.99 then
			drawn += 1
			lowest = math.min(lowest, d.Position.Y)
		end
	end
	return drawn, lowest
end

local state = nil
local function build()
	if state then
		return state
	end
	state = {}
	local ds = require(modules:WaitForChild("DestructibleService"))
	local map = workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Model")
		map.Name = "Map"
		map.Parent = workspace
	end
	workspace.Terrain:FillBlock(CFrame.new(SLAB_AT - Vector3.new(0, 36, 0)), Vector3.new(300, 72, 200), Enum.Material.Grass)
	for _ = 1, 50 do
		task.wait(0.1)
		if groundAt(SPOTS.one.X, SPOTS.one.Z) then
			break
		end
	end
	for name, blasts in pairs({ one = 1, two = 2 }) do
		local spot = SPOTS[name]
		local surface = groundAt(spot.X, spot.Z) or 0
		for index = 1, blasts do
			local y = groundAt(spot.X, spot.Z) or surface
			local before = patchSet()
			ExplosiveFx.Explosion(Vector3.new(spot.X, y, spot.Z), Vector3.yAxis, "grenade", REACH)
			advance(0.1)
			local ok, why = ds.CraterAt(Vector3.new(spot.X, y + 0.5, spot.Z), REACH, WALL, map)
			-- Terrain is measured a frame after it is written (COORDINATION: "measure terrain a frame after").
			task.wait(0.2)
			advance(6)
			local drawn, lowest = patches(before)
			note(string.format("%s blast %d: crater %s; %d of 9 patches drawn, lowest %.1f under the ground it hit (floor %.1f under)",
				name, index, ok and string.format("%.1f", why) or tostring(why), drawn, y - lowest, y - (groundAt(spot.X, spot.Z) or y)))
			if index < blasts then
				task.wait(1.2) -- past CraterAt's burst window
			end
		end
		local floor = groundAt(spot.X, spot.Z) or surface
		state[name] = { at = Vector3.new(spot.X, surface, spot.Z), floor = floor, rim = math.max(2.5 + (surface - floor) * ds.WallRun, 6) }
	end
	return state
end

local views = {}
for _, name in ipairs({ "one", "two" }) do
	local label = name == "one" and "1blast" or "2blasts"
	table.insert(views, {
		name = "scorch_" .. label .. "_rim_eye",
		setup = function(_, camera)
			local c = build()[name]
			camera.CFrame = CFrame.lookAt(c.at + Vector3.new(-(c.rim + 4), 5.5, 0), Vector3.new(c.at.X, c.floor, c.at.Z))
		end,
	})
	table.insert(views, {
		name = "scorch_" .. label .. "_45",
		setup = function(_, camera)
			local c = build()[name]
			local d = c.rim * 1.6 + 6
			camera.CFrame = CFrame.lookAt(c.at + Vector3.new(-d * 0.7, d, -d * 0.7), Vector3.new(c.at.X, c.floor, c.at.Z))
		end,
	})
end
return views
