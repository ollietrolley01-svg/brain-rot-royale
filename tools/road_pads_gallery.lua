-- Flat pads, photographed: the same piece of sloping ground before and after MapTerrain.FlattenPad,
-- from the same camera, so the picture is a comparison rather than an illustration. Then a building's
-- footprint standing on one, which is what the API is for -- Oliver: "make sure buildings and
-- structures are built with a flat floor under them so they dont look like theyre floating on ledges".
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/road_pads_gallery.lua -OutDir <folder> -PlaceFile <rbxlx>

local MAP_ID, SEED = "RotRidge", 101 -- the roughest ground of the five

local ServerScriptService = game:GetService("ServerScriptService")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function look(camera, from, at, fov)
	camera.FieldOfView = fov or 55
	camera.CFrame = CFrame.lookAt(from, at)
end

-- A test structure: four corner posts and a floor slab, exactly what a building's base does. Built at
-- the height the pad reports, so a lip under a corner is visible as daylight.
local function standStructure(parent, centre, height, yaw)
	local model = Instance.new("Model")
	model.Name = "PadTestStand"
	model.Parent = parent
	local frame = CFrame.new(centre.X, height, centre.Z) * CFrame.Angles(0, yaw, 0)
	local floor = Instance.new("Part")
	floor.Size = Vector3.new(22, 0.5, 16)
	floor.CFrame = frame * CFrame.new(0, 0.25, 0)
	floor.Anchored = true
	floor.Color = Color3.fromRGB(196, 192, 184)
	floor.Material = Enum.Material.Concrete
	floor.Name = "Floor"
	floor.Parent = model
	for _, corner in ipairs({ Vector3.new(10, 0, 7), Vector3.new(-10, 0, 7), Vector3.new(10, 0, -7), Vector3.new(-10, 0, -7) }) do
		local post = Instance.new("Part")
		post.Size = Vector3.new(1.2, 7, 1.2)
		post.CFrame = frame * CFrame.new(corner.X, 3.5, corner.Z)
		post.Anchored = true
		post.Color = Color3.fromRGB(122, 96, 70)
		post.Material = Enum.Material.WoodPlanks
		post.Name = "Post"
		post.Parent = model
	end
	return model
end

local views = {
	{
		name = "01_slope_before",
		settle = 3,
		setup = function(_, camera)
			math.randomseed(SEED)
			local modules = ServerScriptService:WaitForChild("Modules")
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			local MapTerrain = require(modules:WaitForChild("MapTerrain"))
			state.MapTerrain = MapTerrain
			local ok, info = pcall(MapGenerator.Build, MAP_ID)
			if not ok then
				note("BUILD FAILED: " .. tostring(info))
				error(info)
			end
			state.info = info
			note(string.format("built %s seed %d, radius %d", MAP_ID, SEED, info.radius))

			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = { workspace.Terrain }
			params.IgnoreWater = true
			local function surface(x, z)
				local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), params)
				return hit and hit.Position.Y
			end
			state.surface = surface

			-- The steepest site clear of the roads: the picture is only worth taking where the ground
			-- actually falls away under the footprint.
			local best = nil
			for _ = 1, 600 do
				local angle, distance = math.random() * math.pi * 2, (0.3 + math.random() * 0.5) * info.radius
				local x, z = math.cos(angle) * distance, math.sin(angle) * distance
				if not info.roads:GroundAt(x, z, 0) then
					local low, high = math.huge, -math.huge
					for _, offset in ipairs({ { 0, 0 }, { 11, 8 }, { -11, 8 }, { 11, -8 }, { -11, -8 } }) do
						local h = surface(x + offset[1], z + offset[2])
						if h then
							low, high = math.min(low, h), math.max(high, h)
						end
					end
					if low < math.huge and (not best or high - low > best.fall) then
						best = { x = x, z = z, low = low, high = high, fall = high - low }
					end
				end
			end
			state.site = best
			if not best then
				note("no sloping site found off the roads")
				error("no site")
			end
			note(string.format("site (%.0f, %.0f): ground %.2f..%.2f, a fall of %.2f studs across the footprint",
				best.x, best.z, best.low, best.high, best.fall))
			local mid = (best.low + best.high) / 2
			state.camera = {
				from = Vector3.new(best.x + 34, mid + 9, best.z + 30),
				at = Vector3.new(best.x, mid + 1, best.z),
			}
			look(camera, state.camera.from, state.camera.at)
		end,
	},
	{
		name = "02_stand_on_raw_ground",
		settle = 2,
		setup = function(_, camera)
			-- What a structure looks like WITHOUT a pad: built at the mid height, corners in the air.
			local site = state.site
			local mid = (site.low + site.high) / 2
			state.stand = standStructure(workspace.Map, Vector3.new(site.x, 0, site.z), mid, 0)
			note(string.format("stand built on raw ground at %.2f (ground runs %.2f..%.2f under it)", mid, site.low, site.high))
			look(camera, state.camera.from, state.camera.at)
		end,
	},
	{
		name = "03_pad_made_same_camera",
		settle = 3,
		setup = function(_, camera)
			local site = state.site
			local MapTerrain = state.MapTerrain
			if state.stand then
				state.stand:Destroy()
			end
			local frame = CFrame.new(site.x, 0, site.z)
			local height, why = MapTerrain.FlattenPad(frame, Vector3.new(24, 0, 18), { height = "mid", margin = 3, space = state.info.space })
			if not height then
				note("FlattenPad refused: " .. tostring(why))
				error("refused")
			end
			state.padHeight = height
			-- A fresh terrain write is not raycastable for a frame or so, and measuring it immediately
			-- is how this gallery first reported 38 studs of spread on a pad the very next screenshot
			-- showed dead flat. The picture was right and the number was taken too early.
			task.wait(0.5)
			-- Flatness, measured in the same run that takes the picture.
			local flattest, roughest = math.huge, -math.huge
			for dx = -15, 15, 1.5 do
				for dz = -12, 12, 1.5 do
					local got = state.surface(site.x + dx, site.z + dz)
					if got then
						flattest, roughest = math.min(flattest, got), math.max(roughest, got)
					end
				end
			end
			note(string.format("pad at %.3f; measured across footprint and margin %.3f..%.3f (spread %.3f studs)",
				height, flattest, roughest, roughest - flattest))
			look(camera, state.camera.from, state.camera.at)
		end,
	},
	{
		name = "04_stand_on_pad",
		settle = 2,
		setup = function(_, camera)
			local site = state.site
			state.stand = standStructure(workspace.Map, Vector3.new(site.x, 0, site.z), state.padHeight, 0)
			note("stand rebuilt at the height FlattenPad returned")
			look(camera, state.camera.from, state.camera.at)
		end,
	},
	{
		name = "05_stand_on_pad_ground_level",
		settle = 2,
		setup = function(_, camera)
			local site = state.site
			-- Down at the floor line, where daylight under a corner would show.
			look(camera, Vector3.new(site.x + 21, state.padHeight + 1.6, site.z + 15),
				Vector3.new(site.x - 4, state.padHeight + 0.5, site.z - 3), 50)
		end,
	},
	{
		name = "06_pad_edge_grade",
		settle = 2,
		setup = function(_, camera)
			local site = state.site
			if state.stand then
				state.stand:Destroy()
			end
			-- Along the pad's downhill edge: the graded skirt back into natural ground.
			look(camera, Vector3.new(site.x + 40, state.padHeight + 4, site.z),
				Vector3.new(site.x + 2, state.padHeight - 1, site.z), 45)
		end,
	},
}

for _, view in ipairs(views) do
	view.name = MAP_ID .. "_" .. view.name
end
return views
