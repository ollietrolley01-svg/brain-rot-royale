-- Town themes gallery: every theme's set piece, props and flag, so each can be judged by eye.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/town_themes_gallery.lua -OutDir <folder> [-PlaceFile <rbxlx>]
--
-- Each view builds ONE theme (TownThemes.BuildAll with just its name) on a plain grass plate high
-- above the empty edit-mode world, then frames it: from across the street at a player's eye height,
-- from the air, and the row of its props with its flag. Set ONLY below to a list of theme names to
-- render a few.

local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local TownThemes = require(modules:WaitForChild("TownThemes"))

local ORIGIN = Vector3.new(0, 300, 0)
local ONLY = nil
-- Which shots to take: any of "street", "aerial", "props"; PROPS_ONLY limits the props shot to those themes.
local SHOTS = { street = true, aerial = true, props = true }
local PROPS_ONLY = nil

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4
Lighting.Ambient = Color3.fromRGB(110, 110, 118)
Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 158)
Lighting.ExposureCompensation = 0.2

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local function build(folder, name)
	local ground = Instance.new("Part")
	ground.Name = "GalleryGround"
	ground.Anchored = true
	ground.Size = Vector3.new(320, 1, 320)
	ground.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
	ground.Color = Color3.fromRGB(96, 130, 78)
	ground.Material = Enum.Material.Grass
	ground.Parent = folder
	-- A strip of street in front, so "from across the street" has a street in it.
	local street = Instance.new("Part")
	street.Name = "GalleryStreet"
	street.Anchored = true
	street.Size = Vector3.new(120, 0.4, 18)
	street.Color = Color3.fromRGB(62, 62, 66)
	street.Material = Enum.Material.Asphalt
	street.Parent = folder
	local entry = TownThemes.BuildAll(folder, ORIGIN, 100, { name })[1]
	street.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 0.2, -entry.depth / 2 - 14.5))
	local parts = 0
	for _, d in ipairs(entry.model:GetDescendants()) do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	note("%s: %d parts (set piece %dx%d, %d prop kinds)", name, parts, entry.width, entry.depth, #entry.props)
	return entry
end

local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 70
	camera.CFrame = CFrame.lookAt(ORIGIN + eye, ORIGIN + target)
end

local views = {}
for _, name in ipairs(ONLY or TownThemes.Order) do
	local id = TownThemes.Themes[name].id
	if SHOTS.street then
		table.insert(views, {
			name = id .. "_street",
			settle = 2,
			setup = function(folder, camera)
				local entry = build(folder, name)
				-- Just past the props row, so the set piece fills the frame the way it does in town.
				look(camera, Vector3.new(-10, 5.5, -entry.depth / 2 - 13), Vector3.new(2, 7, 0), 75)
			end,
		})
	end
	if SHOTS.aerial then
		table.insert(views, {
			name = id .. "_aerial",
			settle = 2,
			setup = function(folder, camera)
				local entry = build(folder, name)
				look(camera, Vector3.new(entry.width * 0.9, 42, -entry.depth * 1.6), Vector3.new(0, 3, 1), 60)
			end,
		})
	end
	if SHOTS.props and (not PROPS_ONLY or table.find(PROPS_ONLY, name)) then
		table.insert(views, {
			name = id .. "_props",
			settle = 2,
			setup = function(folder, camera)
				local entry = build(folder, name)
				local z = -entry.depth / 2 - 16
				look(camera, Vector3.new(-2, 7, z - 26), Vector3.new(-entry.width / 4, 3.5, z + 2), 68)
			end,
		})
	end
end

return views
