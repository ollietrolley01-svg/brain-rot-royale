-- The crater and its scorch (the charred terrain DestructibleService paints into the bowl), for
-- tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/crater_scorch_gallery.lua -OutDir <folder> -PlaceFile <build> -TimeoutSeconds 1500
--
-- Two craters on a flat grass slab far off the origin, each by the real DestructibleService.CraterAt
-- (a rocket's reach and damage): one after 1 blast, one after 3 in the same spot. Each is shown from
-- eye level at its rim, at 45 degrees and straight down. What to look at: the bowl charred black to
-- a ragged edge at the rim, dark streaks running out past it, nothing floating, and the 3-blast bowl
-- deeper and wider with one char, not stacked marks.

local ServerScriptService = game:GetService("ServerScriptService")
local modules = ServerScriptService:WaitForChild("Modules")

local SLAB_AT = Vector3.new(2400, 0, 2400)
local SPOTS = { one = Vector3.new(2350, 0, 2400), three = Vector3.new(2460, 0, 2400) }

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
	workspace.Terrain:FillBlock(CFrame.new(SLAB_AT - Vector3.new(0, 36, 0)), Vector3.new(400, 72, 300), Enum.Material.Grass)
	for _ = 1, 50 do
		task.wait(0.1)
		if groundAt(SPOTS.one.X, SPOTS.one.Z) then
			break
		end
	end
	for name, blasts in pairs({ one = 1, three = 3 }) do
		local spot = SPOTS[name]
		local surface = groundAt(spot.X, spot.Z) or 0
		local dug = {}
		for _ = 1, blasts do
			local y = groundAt(spot.X, spot.Z) or surface
			local ok, why = ds.CraterAt(Vector3.new(spot.X, y + 1, spot.Z), 14, 120, map)
			table.insert(dug, ok and string.format("%.1f", why) or tostring(why))
			task.wait(1.5)
		end
		local floor = groundAt(spot.X, spot.Z) or surface
		local rim = 2.5 + (surface - floor) * ds.WallRun
		state[name] = { at = Vector3.new(spot.X, surface, spot.Z), floor = floor, rim = math.max(rim, 6) }
		note(string.format("%s: %d blast(s) -> %s; depth %.1f, rim ~%.0f", name, blasts, table.concat(dug, " "), surface - floor, rim))
	end
	return state
end

local views = {}
for _, name in ipairs({ "one", "three" }) do
	local label = name == "one" and "1blast" or "3blasts"
	table.insert(views, {
		name = "crater_" .. label .. "_rim_eye",
		setup = function(_, camera)
			local c = build()[name]
			camera.CFrame = CFrame.lookAt(c.at + Vector3.new(-(c.rim + 6), 5.5, 0), Vector3.new(c.at.X, c.floor + 2, c.at.Z))
		end,
	})
	table.insert(views, {
		name = "crater_" .. label .. "_45",
		setup = function(_, camera)
			local c = build()[name]
			local d = c.rim * 1.9 + 8
			camera.CFrame = CFrame.lookAt(c.at + Vector3.new(-d * 0.7, d, -d * 0.7), Vector3.new(c.at.X, c.floor, c.at.Z))
		end,
	})
	table.insert(views, {
		name = "crater_" .. label .. "_top",
		setup = function(_, camera)
			local c = build()[name]
			camera.CFrame = CFrame.lookAt(c.at + Vector3.new(0, c.rim * 3.2 + 12, 0.01), c.at)
		end,
	})
end
return views
