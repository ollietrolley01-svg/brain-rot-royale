-- Landmark skyline gallery: builds one whole map, then photographs each of its landmarks the way a
-- player first sees it, from head height across the fields, and again from nearer and higher; then
-- (with ROW = true) every monument close up on a flat pad.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/wilds_landmarks_gallery.lua -OutDir <folder> -TimeoutSeconds 1500
--
-- Edit MAP_ID below; one map per run.

local MAP_ID = "RotRidge"
local SEED = 424242
local ROW = false

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { workspace.Terrain }
local function ground(x, z)
	-- From far above anything the map builds: a ray that starts inside terrain never reports it.
	local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), params)
	return hit and hit.Position.Y or 0
end

-- Where to stand to photograph a landmark: of eight directions round it, the one whose viewpoint is
-- furthest from any town and still on the map. The old view looked in from the map's middle, which
-- put a town between the camera and half the landmarks.
local function viewpoint(centre, distance)
	local best, bestScore = nil, -math.huge
	local radius = state.info and state.info.radius or 1200
	for index = 0, 7 do
		local angle = index / 8 * math.pi * 2
		local at = centre + Vector3.new(math.cos(angle), 0, math.sin(angle)) * distance
		if Vector3.new(at.X, 0, at.Z).Magnitude < radius * 0.95 then
			local clearance = math.huge
			for _, town in ipairs(state.towns or {}) do
				clearance = math.min(clearance, (Vector3.new(town.X, 0, town.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude)
			end
			if clearance > bestScore then
				best, bestScore = at, clearance
			end
		end
	end
	return best or (centre + Vector3.new(distance, 0, 0))
end

local function look(camera, from, to, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, to)
end

-- The landmark's own model and how tall it stands.
local function landmarkInfo(index)
	local entry = state.landmarks and state.landmarks[index]
	if not entry then
		return nil
	end
	local folder = workspace.Map:FindFirstChild("Landmarks")
	local model = folder and folder:FindFirstChild(entry.id)
	local top = entry.Y + 30
	if model then
		local cf, size = model:GetBoundingBox()
		top = cf.Position.Y + size.Y / 2
	end
	return entry, Vector3.new(entry.X, entry.Y, entry.Z), top
end

local views = {
	{
		name = "map_" .. MAP_ID,
		settle = 4,
		setup = function(_, camera)
			math.randomseed(SEED)
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			local info = MapGenerator.Build(MAP_ID)
			state.info = info
			state.landmarks = info.landmarks or {}
			state.towns = {}
			for _, child in ipairs(workspace.Map:GetChildren()) do
				if child.Name == "Town" and child:GetAttribute("TownCenter") then
					table.insert(state.towns, child:GetAttribute("TownCenter"))
				end
			end
			local names = {}
			for _, entry in ipairs(state.landmarks) do
				table.insert(names, entry.name)
			end
			note(string.format("%s landmarks: %s; chests %d", MAP_ID, table.concat(names, ", "), #info.chestSpots))
			look(camera, Vector3.new(0, info.radius * 1.25, info.radius * 0.45), Vector3.new(0, 0, 0), 70)
		end,
	},
}

-- The most terraced site on this map, from the ground: the steps a levelled site cuts and builds to
-- meet a slope are what to judge here (Oliver asked for terraces rather than one flat disc).
local function mostTerraced()
	local folder = workspace.Map:FindFirstChild("Landmarks")
	local best, bestSteps = nil, -1
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		local steps = child:GetAttribute("SiteSteps") or 0
		if steps > bestSteps then
			best, bestSteps = child, steps
		end
	end
	return best, bestSteps
end

for _, spec in ipairs({ { "terrace_near", 62, 10, 0.25 }, { "terrace_low", 96, 4, 0.12 } }) do
	table.insert(views, {
		name = spec[1],
		settle = 3,
		setup = function(_, camera)
			local model, steps = mostTerraced()
			if not model then
				return
			end
			local centre = model:GetAttribute("LandmarkCenter") or model:GetPivot().Position
			note(string.format("%s: %s, %d steps, spread %s", spec[1], model.Name, steps, tostring(model:GetAttribute("SiteSpread"))))
			local from = viewpoint(centre, spec[2])
			from = Vector3.new(from.X, ground(from.X, from.Z) + spec[3], from.Z)
			look(camera, from, Vector3.new(centre.X, centre.Y + 8, centre.Z), 55)
		end,
	})
end

for index = 1, 5 do
	-- From head height a long way off, the way you'd first pick it out on the skyline.
	table.insert(views, {
		name = "far_" .. index,
		settle = 3,
		setup = function(_, camera)
			local entry, centre, top = landmarkInfo(index)
			if not entry then
				return
			end
			-- From the open side, 300 studs off, at head height: how you first pick it out.
			local from = viewpoint(centre, 300)
			from = Vector3.new(from.X, ground(from.X, from.Z) + 6, from.Z)
			note(string.format("far %d: %s, top %.0f above its ground", index, entry.name, top - entry.Y))
			look(camera, from, Vector3.new(centre.X, entry.Y + (top - entry.Y) * 0.45, centre.Z), 55)
		end,
	})
	table.insert(views, {
		name = "near_" .. index,
		settle = 3,
		setup = function(_, camera)
			local entry, centre, top = landmarkInfo(index)
			if not entry then
				return
			end
			local height = top - entry.Y
			local from = viewpoint(centre, height * 1.3 + 50)
			from = Vector3.new(from.X, ground(from.X, from.Z) + 14 + height * 0.25, from.Z)
			look(camera, from, Vector3.new(centre.X, entry.Y + height * 0.4, centre.Z), 60)
		end,
	})
end

if ROW then
	local Landmarks = require(modules:WaitForChild("Landmarks"))
	local MapSpace = require(modules:WaitForChild("MapSpace"))
	local spots = {}
	local row = table.clone(Landmarks.Registry)
	if Landmarks.Beacon then
		table.insert(row, Landmarks.Beacon)
	end
	table.insert(views, {
		name = "row_build",
		settle = 2,
		setup = function(_, camera)
			local stage = Instance.new("Folder")
			stage.Name = "LandmarkRow"
			stage.Parent = workspace
			local origin = Vector3.new(-5200, 0, 5200)
			local index = 0
			for _, landmark in ipairs(row) do
				do
					index += 1
					local spot = origin + Vector3.new((index - 1) * 260, 0, 0)
					local size = landmark.footprint * 2 + 60
					workspace.Terrain:FillBlock(CFrame.new(spot.X, -6, spot.Z), Vector3.new(size, 8, size), Enum.Material.Grass)
					local model = Instance.new("Model")
					model.Name = landmark.id
					model.Parent = stage
					local ctx = { chestSpots = {}, lootSpots = { weapon = {}, heal = {}, item = {} }, space = MapSpace.new(), groundHeightAt = ground }
					local ok, err = pcall(landmark.build, model, CFrame.new(spot), ctx)
					if not ok then
						note(landmark.id .. " failed: " .. tostring(err))
					end
					spots[index] = { spot = spot, model = model, id = landmark.id }
				end
			end
			look(camera, origin + Vector3.new(-80, 60, -120), origin, 60)
		end,
	})
	-- The monuments follow the nine original landmarks in the registry; the lighthouse ends the row.
	for index = 10, #Landmarks.Registry + (Landmarks.Beacon and 1 or 0) do
		table.insert(views, {
			name = "row_" .. index,
			settle = 2,
			setup = function(_, camera)
				local entry = spots[index]
				if not entry then
					return
				end
				local cf, size = entry.model:GetBoundingBox()
				local height = size.Y
				note("row " .. index .. ": " .. entry.id)
				look(camera, entry.spot + Vector3.new(-height * 0.9 - 30, height * 0.45 + 8, -height * 1.1 - 40), entry.spot + Vector3.new(0, height * 0.42, 0), 60)
			end,
		})
	end
end

return views
