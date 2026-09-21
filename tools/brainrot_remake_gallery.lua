-- Review-only gallery for BrainrotModelsRemake.  It never changes the live model module.
--
-- powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 `
--   -Gallery tools/brainrot_remake_gallery.lua -OutDir <folder> -Hold 1

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModelsRemake"))

local ORIGIN = Vector3.new(6000, 400, 6000)
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }
local PER_SHEET = 5
local SPACING = 5.5

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function pad(folder, center, width, depth)
	local floor = Instance.new("Part")
	floor.Name = "Pad"
	floor.Anchored = true
	floor.Size = Vector3.new(width, 1, depth)
	floor.CFrame = CFrame.new(center - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(142, 146, 154)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = folder
	local wall = floor:Clone()
	wall.Name = "Backdrop"
	wall.Size = Vector3.new(width, 36, 1)
	wall.CFrame = CFrame.new(center + Vector3.new(0, 18, depth / 2))
	wall.Color = Color3.fromRGB(204, 208, 216)
	wall.Parent = folder
end

local function stand(folder, def, ground, yaw)
	local size = (def.look and def.look.size) or 1
	local metrics = BrainrotModels.Metrics(def)
	local model = BrainrotModels.Build(def, {
		flair = false,
		cframe = CFrame.new(ground - Vector3.new(0, metrics.bottom * size, 0)) * CFrame.Angles(0, yaw or 0, 0),
	})
	model.Parent = folder
	local count = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then count += 1 end
	end
	return model, count
end

local function frameModel(camera, model, yawBias)
	local box, extent = model:GetBoundingBox()
	local fov = 30
	local half = math.max(extent.X, extent.Y, extent.Z) / 2
	local distance = half / math.tan(math.rad(fov) / 2) * 1.22 + 1
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(box.Position + Vector3.new(distance * (yawBias or 0.22), extent.Y * 0.18, -distance), box.Position)
end

local views = {}

-- These are the names with established meme designs.  Close-ups come first so the most important
-- accuracy decisions are easy to judge without paging through the whole collection.
local CANONICAL = {
	"Tung Tung Tung Sahur", "Bombardiro Crocodilo", "Tralalero Tralala", "Chimpanzini Bananini",
	"Boneca Ambalabu", "Lirili Larila", "Ballerina Cappuccina", "Brr Brr Patapim",
	"Frigo Camelo", "Bombombini Gusini", "La Vacca Saturno Saturnita", "Golden Sahur",
}

for index, name in ipairs(CANONICAL) do
	local def = BrainrotData.Get(name)
	if def then
		table.insert(views, {
			name = string.format("remake_canonical_%02d_%s", index, string.gsub(name, "[^%w]", "")),
			settle = 1.3,
			hold = 3,
			setup = function(folder, camera)
				pad(folder, ORIGIN, 22, 18)
				local model, count = stand(folder, def, ORIGIN, -0.22)
				note(string.format("remake canonical %s [%d parts] concept=%s", name, count, tostring(model:GetAttribute("Concept"))))
				frameModel(camera, model)
			end,
		})
	end
end

-- Every brainrot, grouped exactly like the production collection.  This is also a coverage test:
-- the gallery log names every model and its part count.
for _, rarity in ipairs(RARITIES) do
	local pool = BrainrotData.OfRarity(rarity)
	for sheet = 1, math.ceil(#pool / PER_SHEET) do
		local first = (sheet - 1) * PER_SHEET + 1
		local last = math.min(#pool, sheet * PER_SHEET)
		table.insert(views, {
			name = string.format("remake_sheet_%d_%s_%d", table.find(RARITIES, rarity), rarity, sheet),
			settle = 1.2,
			setup = function(folder, camera)
				pad(folder, ORIGIN, PER_SHEET * SPACING + 20, 28)
				local labels = {}
				local shown = last - first
				for itemIndex = first, last do
					local def = pool[itemIndex]
					local x = (itemIndex - first - shown / 2) * SPACING
					local model, count = stand(folder, def, ORIGIN + Vector3.new(x, 0, 0), 0)
					table.insert(labels, string.format("%s[%d,%s]", def.name, count, tostring(model:GetAttribute("Concept"))))
				end
				note(string.format("remake sheet %s %d: %s", rarity, sheet, table.concat(labels, ", ")))
				local back = 13 + (shown + 1) * 5
				camera.FieldOfView = 31
				camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, back * 0.18, -back), ORIGIN + Vector3.new(0, 1.55, 0))
			end,
		})
	end
end

return views
