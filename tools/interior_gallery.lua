-- Eye-level interior shots of furnished houses, built through the REAL MapBuildings.BuildBuilding
-- path: a kitchen, a living room, a bedroom and a bathroom, each in a different town palette's
-- interior style, and one from outside looking in through a window.
--
-- A floor's purpose is rolled per floor by buildInterior; this searches math.randomseed until a
-- house rolls the purpose (recognised by a signature piece's Name), then stands the camera across
-- the room from that piece, at eye height, facing it. The houses are 30 wide, so they never get a
-- partition wall between the camera and the room.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local MapBuildings = require(modules:WaitForChild("MapBuildings"))
local TownKinds = require(modules:WaitForChild("TownKinds"))
local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))

local PRESET = MapData.Maps.SahurSprings
local ORIGIN = Vector3.new(0, 300, 0)
local FLOOR = 15
local PLAN = { archetype = "house", width = 30, depth = 30, floors = 3, dock = false }
local EYE_HEIGHT = 5.4

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.2
Lighting.Ambient = Color3.fromRGB(120, 120, 128)
Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 158)
Lighting.ExposureCompensation = 0.25

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local SIGNATURES = {
	kitchen = { Counter = true, Fridge = true },
	living = { Sofa = true },
	bedroom = { Bed = true },
	bathroom = { Vanity = true, Bathtub = true },
}

local function planFor(palette)
	local plan = table.clone(PLAN)
	plan.palette = TownKinds.Palettes[palette]
	return plan
end

-- Builds the plan into `folder` with this seed; returns the house and its first part named in `names`.
local function tryBuild(folder, seed, names, palette)
	folder:ClearAllChildren()
	math.randomseed(seed)
	MapBuildings.BuildBuilding(folder, ORIGIN, PRESET, {}, { weapon = {}, heal = {}, item = {} }, planFor(palette), 0)
	local model = folder:FindFirstChild("house")
	assert(model, "BuildBuilding made no house")
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and names[part.Name] then
			return model, part
		end
	end
	return model, nil
end

local function findSeed(scratch, purpose, palette)
	for seed = 1, 400 do
		local _, part = tryBuild(scratch, seed, SIGNATURES[purpose], palette)
		if part then
			return seed
		end
	end
	return nil
end

-- A soft fill light standing in for the room's own lamps, which a daylight exposure washes out.
local function lamp(folder, at)
	local anchor = Instance.new("Part")
	anchor.Name = "GalleryLamp"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(at)
	anchor.Parent = folder
	local light = Instance.new("PointLight")
	light.Range = 34
	light.Brightness = 1.3
	light.Parent = anchor
end

local views = {}
local scratch

local function build(folder, purpose, palette)
	scratch = scratch or Instance.new("Folder")
	local seed = findSeed(scratch, purpose, palette)
	assert(seed, purpose .. ": no seed rolled it")
	local _, target = tryBuild(folder, seed, SIGNATURES[purpose], palette)
	assert(target, purpose .. ": lost after rebuild")
	local floorBase = ORIGIN.Y + math.floor((target.Position.Y - ORIGIN.Y) / FLOOR) * FLOOR
	note("%s (%s): seed %d, %s at %s", purpose, palette, seed, target.Name, tostring(target.Position))
	return target, floorBase
end

-- Across the room from the signature piece, at eye height, facing it.
local function interiorView(name, purpose, palette)
	table.insert(views, {
		name = name,
		settle = 2,
		setup = function(folder, camera)
			local target, floorBase = build(folder, purpose, palette)
			local reach = PLAN.width / 2 - 1.6
			local flat = Vector3.new(target.Position.X - ORIGIN.X, 0, target.Position.Z - ORIGIN.Z)
			local away = flat.Magnitude > 0.1 and -flat.Unit or Vector3.new(0, 0, -1)
			local eye = Vector3.new(
				ORIGIN.X + math.clamp(away.X * reach, -reach, reach),
				floorBase + 0.5 + EYE_HEIGHT,
				ORIGIN.Z + math.clamp(away.Z * reach, -reach, reach))
			-- Step toward the piece until the eye is out of any furniture or stair it landed in.
			local toward = Vector3.new(target.Position.X, eye.Y, target.Position.Z) - eye
			for _ = 1, 12 do
				if #workspace:GetPartBoundsInBox(CFrame.new(eye), Vector3.new(2, 2, 2)) == 0 then
					break
				end
				eye += toward.Unit * 1.2
			end
			lamp(folder, Vector3.new(ORIGIN.X, floorBase + 10, ORIGIN.Z))
			camera.FieldOfView = 78
			camera.CFrame = CFrame.lookAt(eye, Vector3.new(target.Position.X, floorBase + 3, target.Position.Z))
		end,
	})
end

interiorView("interior_kitchen", "kitchen", "farm")
interiorView("interior_living_room", "living", "pastel")
interiorView("interior_bedroom", "bedroom", "upscale")
interiorView("interior_bathroom", "bathroom", "harbour")

-- From the back garden, looking in through a ground-floor back window at a furnished living room.
table.insert(views, {
	name = "exterior_looking_in",
	settle = 2,
	setup = function(folder, camera)
		local _, floorBase = build(folder, "living", "oldTown")
		lamp(folder, Vector3.new(ORIGIN.X, floorBase + 10, ORIGIN.Z))
		local windowX = ORIGIN.X - PLAN.width / 2 + (PLAN.width - 10) / 3 + 2.5
		local eye = Vector3.new(windowX + 3, floorBase + 6.5, ORIGIN.Z + PLAN.depth / 2 + 9)
		camera.FieldOfView = 60
		camera.CFrame = CFrame.lookAt(eye, Vector3.new(windowX, floorBase + 4, ORIGIN.Z))
	end,
})

return views
