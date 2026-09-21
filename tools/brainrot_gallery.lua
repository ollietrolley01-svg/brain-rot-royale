-- Brainrot gallery: every brainrot in the collection, photographed in rarity sheets, plus a front
-- and back close-up per body shape.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/brainrot_gallery.lua -OutDir <folder> -Hold 1
--
-- Uses the place's own BrainrotModels. To judge an unbuilt copy of the builder, paste its source in
-- at MODELS_EMBED (a scratch copy of this file) and the gallery uses that instead. Set ONLY to a
-- list of view-name prefixes ("sheet_Legendary", "body_Cube") to shoot a subset.
--
-- Each sheet stands its creatures on a grey pad facing the camera; each close-up stands two copies
-- of one creature side by side, one facing the camera and one turned away, so the back of the
-- extras shows as well. A note per creature logs its part count.

local ONLY = nil

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))

local EMBEDDED_MODELS = nil --[[MODELS_EMBED]]
local BrainrotModels
if EMBEDDED_MODELS then
	BrainrotModels = loadstring(EMBEDDED_MODELS)()
else
	BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
end

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local ORIGIN = Vector3.new(6000, 400, 6000)
local PER_SHEET = 5
local SPACING = 5.2
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }

local function pad(folder, center, width, depth)
	local part = Instance.new("Part")
	part.Name = "Pad"
	part.Anchored = true
	part.Size = Vector3.new(width, 1, depth)
	part.CFrame = CFrame.new(center - Vector3.new(0, 0.5, 0))
	part.Color = Color3.fromRGB(150, 152, 158)
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.Parent = folder
	-- A backdrop, so every sheet has the same neutral ground behind it rather than sky.
	local wall = part:Clone()
	wall.Name = "Backdrop"
	wall.Size = Vector3.new(width, 40, 1)
	wall.CFrame = CFrame.new(center + Vector3.new(0, 20, depth / 2))
	wall.Color = Color3.fromRGB(196, 200, 208)
	wall.Parent = folder
end

-- Stands a creature with its base on `ground`, turned by `yaw` (0 faces -Z, towards the camera).
local function stand(folder, def, ground, yaw)
	local size = (def.look and def.look.size) or 1
	local metrics = BrainrotModels.Metrics(def)
	local centre = ground - Vector3.new(0, metrics.bottom * size, 0)
	local model = BrainrotModels.Build(def, { flair = false, cframe = CFrame.new(centre) * CFrame.Angles(0, yaw or 0, 0) })
	model.Parent = folder
	local count = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	return model, count
end

local function look(camera, from, to, fov)
	camera.FieldOfView = fov or 30
	camera.CFrame = CFrame.lookAt(from, to)
end

local views = {}

for _, rarity in ipairs(RARITIES) do
	local pool = BrainrotData.OfRarity(rarity)
	local sheets = math.ceil(#pool / PER_SHEET)
	for sheet = 1, sheets do
		local first = (sheet - 1) * PER_SHEET + 1
		local last = math.min(#pool, sheet * PER_SHEET)
		table.insert(views, {
			name = string.format("sheet_%d_%s_%d", table.find(RARITIES, rarity), rarity, sheet),
			settle = 1.2,
			setup = function(folder, camera)
				pad(folder, ORIGIN, PER_SHEET * SPACING + 20, 30)
				local names = {}
				-- Centred on however many this sheet holds: a last sheet with one creature on it was
				-- standing it out at the left-hand slot, alone at the edge of the frame.
				local shown = last - first
				for index = first, last do
					local def = pool[index]
					local x = (index - first - shown / 2) * SPACING
					local _, count = stand(folder, def, ORIGIN + Vector3.new(x, 0, 0), 0)
					table.insert(names, string.format("%s[%d]", def.name, count))
				end
				note(string.format("sheet %s %d: %s", rarity, sheet, table.concat(names, ", ")))
				-- Back far enough for the row it actually has, so a short row isn't a speck.
				local back = 12 + (shown + 1) * 4.8
				look(camera, ORIGIN + Vector3.new(0, back * 0.18, -back), ORIGIN + Vector3.new(0, 1.6, 0), 30)
			end,
		})
	end
end

-- One creature per body shape, preferring the most decorated one wearing that body.
local BODY_ORDER = { "Blob", "Bean", "Cube", "Pear", "Disc", "Stack", "Egg", "Mushroom", "Cloud", "Can", "Cone", "Ghost", "Loaf", "Totem" }
local bestByBody = {}
for _, def in ipairs(BrainrotData.Types) do
	local body = def.look and def.look.body or "Blob"
	local extras = def.look and def.look.extras and #def.look.extras or 0
	local current = bestByBody[body]
	if not current or extras > #(current.look.extras or {}) then
		bestByBody[body] = def
	end
end
for index, body in ipairs(BODY_ORDER) do
	local def = bestByBody[body]
	if def then
		table.insert(views, {
			name = string.format("body_%02d_%s", index, body),
			settle = 1.2,
			hold = 3,
			setup = function(folder, camera)
				pad(folder, ORIGIN, 40, 30)
				stand(folder, def, ORIGIN + Vector3.new(-3.2, 0, 0), 0)
				stand(folder, def, ORIGIN + Vector3.new(3.2, 0, 0), math.pi)
				note(string.format("body %s: %s", body, def.name))
				look(camera, ORIGIN + Vector3.new(-5, 6.5, -17), ORIGIN + Vector3.new(0, 1.9, 0), 36)
			end,
		})
	end
end

-- Portraits: one creature filling the frame, for the signature details.
local PORTRAITS = { "Faro Guardiano", "Oracolo Lavatrice", "Samurai Sushi", "Arcobalenissimo",
	"Imperatrice Farfalla", "Patatina Fritta", "Titano Tostapane", "Cosmo Nonno Stellare",
	"Cavaliere Lattina", "Ragnetto Tessitore", "Formichina Operaia", "Ombrellino Pioggia" }
for index, name in ipairs(PORTRAITS) do
	local def = BrainrotData.Get(name)
	if def then
		table.insert(views, {
			name = string.format("portrait_%02d_%s", index, (string.gsub(name, "[^%w]", ""))),
			settle = 1.4,
			hold = 4,
			setup = function(folder, camera)
				pad(folder, ORIGIN, 24, 18)
				local model, count = stand(folder, def, ORIGIN, -0.35)
				note(string.format("portrait %s [%d parts]", name, count))
				-- Frame what was actually built, hats and wings included, rather than the body
				-- metrics: a plume or a halo sits well above `top` and was being cropped off.
				local box, extent = model:GetBoundingBox()
				local centre = box.Position
				local fov = 28
				local half = math.max(extent.Y, extent.X, extent.Z) / 2
				local back = half / math.tan(math.rad(fov) / 2) * 1.15 + 1.2
				local eye = centre + Vector3.new(back * 0.28, extent.Y * 0.22, -back)
				look(camera, eye, centre, fov)
				return model
			end,
		})
	end
end

-- Backs, for the extras that hang behind: a cape reads only from here.
local REARS = { "Cavaliere Lattina", "Nocciolino Ninja" }
for index, name in ipairs(REARS) do
	local def = BrainrotData.Get(name)
	if def then
		table.insert(views, {
			name = string.format("portrait_back_%02d_%s", index, (string.gsub(name, "[^%w]", ""))),
			settle = 1.4,
			hold = 4,
			setup = function(folder, camera)
				pad(folder, ORIGIN, 24, 18)
				local model, count = stand(folder, def, ORIGIN, math.pi - 0.3)
				note(string.format("portrait back %s [%d parts]", name, count))
				local box, extent = model:GetBoundingBox()
				local fov = 28
				local half = math.max(extent.Y, extent.X, extent.Z) / 2
				local back = half / math.tan(math.rad(fov) / 2) * 1.15 + 1.2
				look(camera, box.Position + Vector3.new(back * 0.28, extent.Y * 0.22, -back), box.Position, fov)
				return model
			end,
		})
	end
end

if ONLY then
	local kept = {}
	for _, view in ipairs(views) do
		for _, prefix in ipairs(ONLY) do
			if string.sub(view.name, 1, #prefix) == prefix then
				table.insert(kept, view)
				break
			end
		end
	end
	views = kept
end

return views
