-- Building gallery: town buildings from MapBuildings, inside and out, so the stairs, landings,
-- well railings, doorway thresholds, ceiling lights and chimneys can be judged by eye rather than
-- only counted by tools/audit_buildings.lua.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/building_gallery.lua -OutDir <folder>
--
-- Each view builds one building from a fixed plan and seed (gallery.ps1 clears the folder between
-- views), on a plain ground plate high above the empty edit-mode world. Cutaway views hide the
-- building's -X wall (the stair corner is -X/-Z) or everything above a height, so every flight and
-- landing is visible at once. Interior views stand where a player would.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local MapBuildings = require(modules:WaitForChild("MapBuildings"))
local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))

local PRESET = MapData.Maps.SahurSprings
local ORIGIN = Vector3.new(0, 300, 0)
local FLOOR = 15

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.2
Lighting.Ambient = Color3.fromRGB(120, 120, 128)
Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 158)
Lighting.ExposureCompensation = 0.25

local PLANS = {
	house = { archetype = "house", width = 32, depth = 30, floors = 2, dock = false },
	tower = { archetype = "tower", width = 30, depth = 30, floors = 4, dock = false },
	-- 26 deep: the size that used to get no stairs at all.
	narrow = { archetype = "tower", width = 28, depth = 26, floors = 3, dock = false },
}

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

-- Builds one building at ORIGIN (door toward -Z) on a ground plate and returns its model and plan.
local function build(folder, planName, seed)
	local plan = PLANS[planName]
	local ground = Instance.new("Part")
	ground.Name = "GalleryGround"
	ground.Anchored = true
	ground.Size = Vector3.new(260, 1, 260)
	ground.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.52, 0))
	ground.Color = Color3.fromRGB(96, 130, 78)
	ground.Material = Enum.Material.Grass
	ground.Parent = folder

	math.randomseed(seed)
	local chests, loot = {}, { weapon = {}, heal = {}, item = {} }
	MapBuildings.BuildBuilding(folder, ORIGIN, PRESET, chests, loot, table.clone(plan), 0)
	local model = nil
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and child.Name == plan.archetype then
			model = child
		end
	end
	assert(model, "BuildBuilding made no " .. plan.archetype)
	local stairs = 0
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Name == "Stair" then
			stairs += 1
		end
	end
	note("%s %dx%d, %d floors: %d parts, %d stair parts, %d chest spots", planName, plan.width, plan.depth, plan.floors,
		#model:GetDescendants(), stairs, #chests)
	return model, plan
end

-- Hides every part for which `test(localPosition, part)` is true (positions relative to ORIGIN).
local function hide(model, test)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and test(part.Position - ORIGIN, part) then
			part.Transparency = 1
			part.CastShadow = false
			for _, child in ipairs(part:GetChildren()) do
				if child:IsA("SurfaceGui") or child:IsA("Decal") then
					child.Enabled = false
				end
			end
		end
	end
end

local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 70
	camera.CFrame = CFrame.lookAt(ORIGIN + eye, ORIGIN + target)
end

-- A lamp at the camera for interior shots, which edit-mode lighting leaves dim.
local function lamp(folder, at, brightness)
	local anchor = Instance.new("Part")
	anchor.Name = "GalleryLamp"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(ORIGIN + at)
	anchor.Parent = folder
	local light = Instance.new("PointLight")
	light.Range = 40
	light.Brightness = brightness or 1.6
	light.Shadows = true
	light.Parent = anchor
end

local views = {}
local function view(name, fn)
	table.insert(views, { name = name, settle = 2, setup = fn })
end

view("house_front", function(folder, camera)
	build(folder, "house", 11)
	look(camera, Vector3.new(-40, 16, -52), Vector3.new(0, 9, 0))
end)

view("house_back_chimney", function(folder, camera)
	build(folder, "house", 11)
	look(camera, Vector3.new(34, 42, 58), Vector3.new(0, 30, 2))
end)

view("house_doorway_threshold", function(folder, camera)
	local _, plan = build(folder, "house", 11)
	look(camera, Vector3.new(5, 3.2, -plan.depth / 2 - 8), Vector3.new(0, 0.6, -plan.depth / 2), 60)
end)

view("house_cutaway_side", function(folder, camera)
	local _, plan = build(folder, "house", 11)
	local model = folder:FindFirstChild("house")
	hide(model, function(p)
		return p.X < -plan.width / 2 + 0.8
	end)
	look(camera, Vector3.new(-62, 20, -plan.depth / 2 + 12), Vector3.new(-plan.width / 2 + 6, 14, -plan.depth / 2 + 12), 60)
end)

view("house_top_floor_light_and_roof", function(folder, camera)
	local _, plan = build(folder, "house", 11)
	local halfW, halfD = plan.width / 2, plan.depth / 2
	lamp(folder, Vector3.new(0, FLOOR + 6, -halfD + 6), 1.2)
	look(camera, Vector3.new(-halfW + 12, FLOOR + 5, -halfD + 4), Vector3.new(halfW * 0.3, FLOOR * plan.floors + 3, halfD * 0.3), 80)
end)

view("tower_front", function(folder, camera)
	build(folder, "tower", 23)
	look(camera, Vector3.new(-62, 34, -74), Vector3.new(0, 28, 0))
end)

view("tower_cutaway_side", function(folder, camera)
	local _, plan = build(folder, "tower", 23)
	local model = folder:FindFirstChild("tower")
	hide(model, function(p)
		return p.X < -plan.width / 2 + 0.8
	end)
	look(camera, Vector3.new(-92, 31, -plan.depth / 2 + 11), Vector3.new(-plan.width / 2 + 6, 31, -plan.depth / 2 + 11), 60)
end)

view("tower_cutaway_corner", function(folder, camera)
	local _, plan = build(folder, "tower", 23)
	local model = folder:FindFirstChild("tower")
	local halfW, halfD = plan.width / 2, plan.depth / 2
	hide(model, function(p)
		return p.X < -halfW + 0.8 or p.Z < -halfD + 0.8 or p.Y > FLOOR * 2 + 2
	end)
	look(camera, Vector3.new(-38, 36, -42), Vector3.new(-halfW + 7, 14, -halfD + 11), 60)
end)

view("tower_floor1_from_above", function(folder, camera)
	local _, plan = build(folder, "tower", 23)
	local model = folder:FindFirstChild("tower")
	local halfW, halfD = plan.width / 2, plan.depth / 2
	-- Everything from floor 2's slab up is hidden, so floor 1's well, landing and rail show from above.
	hide(model, function(p)
		return p.Y > FLOOR * 2 - 1.2
	end)
	look(camera, Vector3.new(-halfW + 16, FLOOR + 30, -halfD - 8), Vector3.new(-halfW + 7, FLOOR, -halfD + 11), 60)
end)

view("tower_floor1_landing_pov", function(folder, camera)
	local _, plan = build(folder, "tower", 23)
	local halfW, halfD = plan.width / 2, plan.depth / 2
	lamp(folder, Vector3.new(-halfW + 12, FLOOR + 6, -halfD + 3))
	look(camera, Vector3.new(-halfW + 12.5, FLOOR + 5, -halfD + 2.2), Vector3.new(-halfW + 4, FLOOR + 4, -halfD + 10), 75)
end)

view("tower_floor1_arrival_pov", function(folder, camera)
	local _, plan = build(folder, "tower", 23)
	local halfW, halfD = plan.width / 2, plan.depth / 2
	lamp(folder, Vector3.new(-halfW + 8, FLOOR + 7, -halfD + 20))
	look(camera, Vector3.new(-halfW + 5, FLOOR + 5, -halfD + 25), Vector3.new(-halfW + 7, FLOOR + 2, -halfD + 8), 75)
end)

view("tower_ground_flight_pov", function(folder, camera)
	local _, plan = build(folder, "tower", 23)
	local halfW, halfD = plan.width / 2, plan.depth / 2
	lamp(folder, Vector3.new(-halfW + 10, 7, -halfD + 3))
	look(camera, Vector3.new(-halfW + 12, 5, -halfD + 1.5), Vector3.new(-halfW + 5, 6, -halfD + 12), 75)
end)

view("narrow_tower_cutaway_side", function(folder, camera)
	local _, plan = build(folder, "narrow", 31)
	local model = folder:FindFirstChild("tower")
	hide(model, function(p)
		return p.X < -plan.width / 2 + 0.8
	end)
	look(camera, Vector3.new(-80, 24, -plan.depth / 2 + 10), Vector3.new(-plan.width / 2 + 6, 22, -plan.depth / 2 + 10), 60)
end)

return views
