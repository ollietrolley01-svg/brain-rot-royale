-- Arsenal pack gallery: the fifteen additive weapons in Shared/ArsenalExpansion.lua, built through the
-- game's own gun builder and lit on the same stage as tools/gun_gallery.lua.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/arsenal_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- One labelled lineup of all fifteen in pack order, then each gun from the side and from a front
-- three-quarter, framed to fill the view whatever its size. Each build prints its part count and
-- the z-fight scan, as the gun gallery does.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArsenalExpansion = require(Shared:WaitForChild("ArsenalExpansion"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local GunModels = require(Shared:WaitForChild("GunModels"))

local ORIGIN = Vector3.new(0, 400, 0)
local DETAIL = "high"
-- true: render only the lineup (a quick re-shoot); false: the lineup and every gun.
local ONLY_LINEUP = false

Lighting.ClockTime = 14
Lighting.Brightness = 2.4
Lighting.ExposureCompensation = 0.1
Lighting.Ambient = Color3.fromRGB(70, 70, 76)
Lighting.OutdoorAmbient = Color3.fromRGB(120, 120, 128)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function light(folder, position, brightness, range)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Position = position
	anchor.Parent = folder
	local point = Instance.new("PointLight")
	point.Brightness = brightness
	point.Range = range
	point.Shadows = true
	point.Color = Color3.fromRGB(255, 248, 238)
	point.Parent = anchor
end

local function stage(folder, eye, wide)
	local back = Instance.new("Part")
	back.Anchored = true
	back.Size = Vector3.new(1, 80, wide and 320 or 160)
	back.CFrame = CFrame.new(ORIGIN + Vector3.new(-9, 0, 0))
	back.Color = Color3.fromRGB(150, 153, 160)
	back.Material = Enum.Material.SmoothPlastic
	back.Parent = folder
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(60, 1, wide and 320 or 160)
	floor.CFrame = CFrame.new(ORIGIN + Vector3.new(0, -14, 0))
	floor.Color = Color3.fromRGB(120, 122, 128)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = folder
	light(folder, eye + Vector3.new(0, 4, 3), 1.6, wide and 120 or 40)
	light(folder, ORIGIN + Vector3.new(3, 8, -6), 1.2, wide and 80 or 30)
end

local function label(folder, text, position, size)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = position
	anchor.Parent = folder
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 40)
	gui.AlwaysOnTop = true
	gui.Parent = anchor
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.GothamBold
	textLabel.TextSize = size or 14
	textLabel.TextWrapped = true
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.TextStrokeTransparency = 0.3
	textLabel.Text = text
	textLabel.Parent = gui
end

-- Builds with the game's own entry point, anchored in place; reports the part count and z-fights.
local function place(folder, id, cframe)
	local def = WeaponData.Get(id)
	if not def then
		note(id .. ": not in WeaponData")
		return nil
	end
	local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = DETAIL })
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	model:PivotTo(cframe)
	model.Parent = folder
	local count = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	local flush = ZFight.Scan({ model }, GunModels.ZFightTolerance)
	note(string.format("%s (%s %s): %d parts, flush pairs %d", id, def.rarity, def.style, count, #flush))
	return model
end

local views = {}
local ids = ArsenalExpansion.Order

-- The lineup: all fifteen side on in a grid of five across and three down, pack order reading
-- left to right, top to bottom, name and rarity under each. The grid is packed to the guns'
-- measured sizes: a fixed 13-stud pitch left each three-stud gun a speck in its cell, and one row
-- of fifteen was worse.
table.insert(views, {
	name = "arsenal_lineup",
	settle = 1.5,
	hold = 2,
	setup = function(folder, camera)
		local columns = 5
		local rows = math.ceil(#ids / columns)
		-- Build everything at the origin first, so the pitch can come from the longest and tallest.
		local models, longest, tallest = {}, 0, 0
		for index, id in ipairs(ids) do
			local model = place(folder, id, CFrame.new(ORIGIN))
			if model then
				local _, size = model:GetBoundingBox()
				longest = math.max(longest, size.Z)
				tallest = math.max(tallest, size.Y)
				models[index] = model
			end
		end
		local across = longest * 1.3 + 0.4
		local down = tallest + 2.2
		for index, id in ipairs(ids) do
			local model = models[index]
			if model then
				local column = (index - 1) % columns
				local row = math.floor((index - 1) / columns)
				-- The eye is on +X looking down -X, so left-to-right on screen is -Z to +Z.
				local at = ORIGIN + Vector3.new(0, (rows - 1) / 2 * down - row * down, (column - (columns - 1) / 2) * across)
				model:PivotTo(CFrame.new(at))
				local def = WeaponData.Get(id)
				local box, size = model:GetBoundingBox()
				label(folder, def.name .. "  |  " .. def.rarity, box.Position - Vector3.new(0, size.Y / 2 + 0.7, 0), 13)
			end
		end
		-- FieldOfView is the vertical angle; the horizontal one follows the viewport's aspect. The
		-- eye sits at whichever distance the grid's width or height needs more.
		local fov = 40
		local viewport = camera.ViewportSize
		local aspect = viewport.Y > 0 and viewport.X / viewport.Y or 16 / 9
		if aspect < 1.2 then
			aspect = 16 / 9
		end
		local halfWidth = columns * across / 2 + 0.5
		local halfHeight = rows * down / 2 + 0.5
		local vertical = math.tan(math.rad(fov / 2))
		local distance = math.max(halfWidth / (vertical * aspect), halfHeight / vertical) * 1.05
		local eye = ORIGIN + Vector3.new(distance, 0.5, 0)
		stage(folder, eye, true)
		camera.FieldOfView = fov
		camera.CFrame = CFrame.lookAt(eye, ORIGIN)
		note(string.format("lineup: longest %.2f, tallest %.2f, pitch %.2f x %.2f, eye at %.1f", longest, tallest, across, down, distance))
	end,
})

if ONLY_LINEUP then
	return views
end

-- Each gun from `direction` (gun toward the eye), filling the frame whatever its size.
local function frameGun(folder, camera, id, direction, fov)
	local model = place(folder, id, CFrame.new(ORIGIN))
	if not model then
		return
	end
	local box, size = model:GetBoundingBox()
	local radius = size.Magnitude / 2
	local distance = radius / math.tan(math.rad(fov) / 2) * 1.02
	local eye = box.Position + direction.Unit * distance
	stage(folder, eye, false)
	local def = WeaponData.Get(id)
	label(folder, def.name .. "  |  " .. def.rarity .. " " .. def.style, box.Position - Vector3.new(0, size.Y / 2 + 0.6, 0), 15)
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(eye, box.Position)
end

for _, id in ipairs(ids) do
	table.insert(views, {
		name = "side_" .. id,
		setup = function(folder, camera)
			frameGun(folder, camera, id, Vector3.new(1, 0.02, 0), 22)
		end,
	})
	table.insert(views, {
		name = "quarter_" .. id,
		setup = function(folder, camera)
			frameGun(folder, camera, id, Vector3.new(0.8, 0.45, -0.55), 26)
		end,
	})
end

return views
