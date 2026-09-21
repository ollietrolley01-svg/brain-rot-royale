-- Every cosmetic in the game, as its shop preview shows it, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/cosmetic_preview_gallery.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- One grid per kind: the model Shared/CosmeticPreview builds for each id, scaled so they share a
-- cell, named underneath. That is the same geometry the shop rows and the crate reveal show, so a
-- sheet here is what a player will see -- not a separate drawing of it.
--
-- Scaling to a common cell is the point of the layout: a canopy is 25 studs across and a pair of
-- shades is one, and the shop shows both in the same square, so any judgement about whether a design
-- reads at thumbnail size has to be made at that size.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CosmeticPreview = require(Shared:WaitForChild("CosmeticPreview"))

local V = Vector3.new

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local HIGH = V(0, 1400, -2600)
local COLUMNS = 5
local CELL = 6

-- Sorted by rarity then name, so a sheet reads from the common ones to the secret ones.
local RARITY_ORDER = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6, Secret = 7 }

local byKind = {}
for id, item in pairs(CosmeticData.Items) do
	byKind[item.kind] = byKind[item.kind] or {}
	table.insert(byKind[item.kind], id)
end
for _, list in pairs(byKind) do
	table.sort(list, function(a, b)
		local ra = RARITY_ORDER[CosmeticData.Items[a].rarity] or 9
		local rb = RARITY_ORDER[CosmeticData.Items[b].rarity] or 9
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
end

-- Places one preview in its cell, scaled to fit, with its name and rarity under it.
local function place(id, at, parent)
	local item = CosmeticData.Get(id)
	local model = CosmeticPreview.Model(id)
	if not model then
		note(string.format("%s: no preview built", id))
		return false
	end

	local _, size = model:GetBoundingBox()
	local reach = math.max(size.Magnitude / 2, 0.001)
	local scale = (CELL * 0.42) / reach
	model:ScaleTo(scale)
	-- Centred on the cell by its bounding box, not its pivot: an accessory's pivot is the head socket
	-- it hangs from, which is nowhere near the middle of the thing you are looking at.
	model:PivotTo(CFrame.new(at))
	local box = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + (at - box.Position))
	model.Parent = parent

	local label = Instance.new("Part")
	label.Name = "Label_" .. id
	label.Size = V(0.2, 0.2, 0.2)
	label.Transparency = 1
	label.Anchored = true
	label.CanCollide = false
	label.CFrame = CFrame.new(at - V(0, CELL * 0.42, 0))
	label.Parent = parent

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(190, 40)
	billboard.AlwaysOnTop = true
	billboard.Parent = label

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = 15
	text.TextColor3 = Color3.fromRGB(245, 245, 250)
	text.TextStrokeTransparency = 0.2
	text.Text = string.format("%s\n%s", item.name or id, item.rarity or "")
	text.Parent = billboard

	return true
end

local views = {}
local function add(name, setup)
	table.insert(views, { name = name, settle = 1.4, hold = 2, setup = setup })
end

-- A grid of up to COLUMNS x 3, centred on the camera.
local function sheet(kind, page, ids)
	add(string.format("%s_%d", kind:lower(), page), function(folder, camera)
		local rows = math.ceil(#ids / COLUMNS)
		local built = 0
		for index, id in ipairs(ids) do
			local column = (index - 1) % COLUMNS
			local row = math.floor((index - 1) / COLUMNS)
			local at = HIGH + V((column - (COLUMNS - 1) / 2) * CELL, -(row - (rows - 1) / 2) * CELL, 0)
			if place(id, at, folder) then
				built += 1
			end
		end
		note(string.format("%s page %d: %d of %d previews built", kind, page, built, #ids))

		local width = COLUMNS * CELL
		local height = rows * CELL
		local distance = math.max(width / 1.1, height / 0.62) * 0.9
		camera.FieldOfView = 48
		camera.CFrame = CFrame.lookAt(HIGH + V(0, 0, -distance), HIGH)
	end)
end

for _, kind in ipairs({ "Accessory", "Parachute", "GunSkin", "Aura" }) do
	local ids = byKind[kind] or {}
	local perPage = COLUMNS * 3
	local page = 0
	for from = 1, #ids, perPage do
		page += 1
		local slice = {}
		for index = from, math.min(from + perPage - 1, #ids) do
			table.insert(slice, ids[index])
		end
		sheet(kind, page, slice)
	end
end

return views
