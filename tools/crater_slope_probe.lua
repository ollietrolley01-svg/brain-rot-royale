-- Studio probe (runtest.ps1 -Probe tools/crater_slope_probe.lua -PlaceFile <build>): crater walls against the design (DestructibleService: "a BOWL, NEVER A SHAFT", walls 1 in
-- WALL_RUN, 27 degrees at WALL_RUN 2), for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/crater_slope_gallery.lua -OutDir <folder> -PlaceFile <build>
--
-- A flat grass slab 72 thick (a map's ground) far off the origin, a Map with nothing in it, and
-- DestructibleService.CraterAt at one spot until the bowl bottoms out at DIG_DEPTH. Then the ground
-- is sampled every stud along 16 lines out from the middle, and the wall measured as a vehicle meets
-- it: the slope over each 4-stud run (about a wheelbase) between the floor and the rim.
--
--   [BRR_Gallery] note crater depth=D rim=R design=27deg wall4 p50/p90/max=A/B/C step1 max=E
--
-- Views: the bowl from above its rim, and a side section: a row of green markers on the ground
-- along one line and a red bar on the designed slope, so a wall steeper than the design shows as
-- green climbing above the red.

local ServerScriptService = game:GetService("ServerScriptService")
local modules = ServerScriptService:WaitForChild("Modules")

local ORIGIN = Vector3.new(2400, 0, 2400)
local SLAB = 72

local function note(text)
	print("[CRATER] " .. text)
end

local state = {}

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { workspace.Terrain }
params.IgnoreWater = true

local function groundAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, ORIGIN.Y + 60, z), Vector3.new(0, -200, 0), params)
	return hit and hit.Position.Y or nil
end

-- The ground's height at (x, z) from the voxels (what the terrain draws): the top solid voxel's
-- floor plus its occupancy. Raycasts in edit mode may not see a dig until physics catches up.
local function voxelGround(x, z)
	local base = Vector3.new(math.floor(x / 4) * 4, ORIGIN.Y - 40, math.floor(z / 4) * 4)
	local region = Region3.new(base, base + Vector3.new(4, 64, 4))
	local materials, occupancies = workspace.Terrain:ReadVoxels(region, 4)
	for iy = #occupancies[1], 1, -1 do
		local occ = occupancies[1][iy][1]
		if occ > 0 and materials[1][iy][1] ~= Enum.Material.Air then
			return base.Y + (iy - 1) * 4 + occ * 4
		end
	end
	return nil
end

local function dig()
	if state.dug then
		return state
	end
	local ds = require(modules:WaitForChild("DestructibleService"))
	local map = workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Model")
		map.Name = "Map"
		map.Parent = workspace
	end
	workspace.Terrain:FillBlock(CFrame.new(ORIGIN - Vector3.new(0, SLAB / 2, 0)), Vector3.new(260, SLAB, 260), Enum.Material.Grass)
	local surface
	for _ = 1, 50 do
		task.wait(0.1)
		surface = groundAt(ORIGIN.X, ORIGIN.Z)
		if surface then
			break
		end
	end
	surface = surface or ORIGIN.Y
	local results = {}
	for _ = 1, 8 do
		workspace.CurrentCamera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(50, 40, 50), ORIGIN - Vector3.new(0, 12, 0))
		local ok, why = ds.CraterAt(Vector3.new(ORIGIN.X, (groundAt(ORIGIN.X, ORIGIN.Z) or 0) + 1, ORIGIN.Z), 14, 120, map)
		table.insert(results, ok and string.format("%.1f", why) or tostring(why))
		task.wait(1.5)
	end
	note("crater blasts: " .. table.concat(results, " "))
	note(string.format("middle: ray %.2f voxels %.2f (surface %.2f)", groundAt(ORIGIN.X, ORIGIN.Z) or -999,
		voxelGround(ORIGIN.X + 2, ORIGIN.Z + 2) or -999, surface))
	local floor = groundAt(ORIGIN.X, ORIGIN.Z)
	local run = ds.WallRun
	local design = math.deg(math.atan(1 / run))
	local slopes, steps = {}, 0
	local rimSum, lines = 0, 16
	for line = 1, lines do
		local a = line / lines * math.pi * 2
		local dx, dz = math.cos(a), math.sin(a)
		local heights = {}
		for r = 0, 70 do
			heights[r] = groundAt(ORIGIN.X + dx * r, ORIGIN.Z + dz * r)
		end
		local rim = 70
		for r = 1, 70 do
			if heights[r] and heights[r] >= surface - 0.25 then
				rim = r
				break
			end
		end
		rimSum += rim
		for r = 4, rim - 5 do
			if heights[r] and heights[r + 4] and heights[r] > floor + 0.5 then
				table.insert(slopes, math.deg(math.atan((heights[r + 4] - heights[r]) / 4)))
			end
		end
		for r = 1, rim do
			if heights[r] and heights[r - 1] then
				steps = math.max(steps, math.deg(math.atan(math.abs(heights[r] - heights[r - 1]))))
			end
		end
		if line == 1 then
			state.profile = heights
			state.rim = rim
		end
	end
	table.sort(slopes)
	local function at(p)
		return #slopes > 0 and slopes[math.max(1, math.ceil(#slopes * p))] or 0
	end
	note(string.format("crater depth=%.1f rim=%.1f design=%.0fdeg wall4 p50/p90/max=%.0f/%.0f/%.0fdeg step1 max=%.0fdeg (%d runs)",
		surface - floor, rimSum / lines, design, at(0.5), at(0.9), at(1), steps, #slopes))
	state.dug, state.surface, state.floor, state.run = true, surface, floor, run
	return state
end

local s = dig()
workspace.CurrentCamera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(50, s.surface + 30, 50), Vector3.new(ORIGIN.X, s.floor, ORIGIN.Z))
task.wait(5)
note("done")
