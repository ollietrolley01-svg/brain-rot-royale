-- ADS gallery: what you actually see down each gun's sights.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/ads_gallery.lua -OutDir <folder> -Hold 1
-- (rebuild the place first: the gallery runs against BrainRotRoyale.rbxlx, not the .lua files)
--
-- The camera goes exactly where the viewmodel puts it when you aim: EyeRelief studs behind the gun's
-- KP_Sight, looking down its line, at the ADS field of view (Settings' default 70 x ADS_ZOOM 0.64).
-- A target board stands far down that line with a thin red cross whose centre is ON the line -- the
-- point the crosshair and your shots go to. So in every picture:
--
--   * the red dot / holo dot / front post tip should sit on the red cross's centre;
--   * the world should be clearly visible through any glass;
--   * nothing should hide the cross.
--
-- "ads_" views are the real field of view; "zoom_" views are the same eye at a narrow field of view,
-- which magnifies the sight picture around the centre so a millimetre of error is visible.
-- SHOW narrows it to some weapon ids; nil shows every gun.

local SHOW = nil
local ZOOM_FOV = 9
local ADS_FOV = 70 * 0.64

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local ORIGIN = CFrame.new(0, 600, 0)
local BOARD_DISTANCE = 45

Lighting.ClockTime = 13
Lighting.Brightness = 2.2
Lighting.ExposureCompensation = 0
Lighting.Ambient = Color3.fromRGB(90, 90, 96)
Lighting.OutdoorAmbient = Color3.fromRGB(130, 130, 136)

local function anchoredPart(folder, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	for key, value in pairs(props) do
		part[key] = value
	end
	part.Parent = folder
	return part
end

-- A bright board with rings, square to the line, and a thin red cross centred on the line.
local function board(folder, eye)
	local centre = eye * CFrame.new(0, 0, -BOARD_DISTANCE)
	-- Board faces back toward the eye; everything on it steps toward the eye so nothing is coplanar.
	anchoredPart(folder, { Size = Vector3.new(90, 60, 1), CFrame = centre * CFrame.new(0, 0, -0.5), Color = Color3.fromRGB(214, 218, 222) })
	local rings = {
		{ 18, Color3.fromRGB(60, 120, 200) },
		{ 12, Color3.fromRGB(240, 240, 240) },
		{ 7, Color3.fromRGB(60, 120, 200) },
		{ 3, Color3.fromRGB(240, 240, 240) },
	}
	for index, ring in ipairs(rings) do
		anchoredPart(folder, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.05, ring[1], ring[1]),
			-- A cylinder's axis is its X; turn it to face the eye.
			CFrame = centre * CFrame.new(0, 0, 0.05 * index) * CFrame.Angles(0, math.pi / 2, 0),
			Color = ring[2],
		})
	end
	local red = Color3.fromRGB(230, 30, 30)
	anchoredPart(folder, { Size = Vector3.new(90, 0.07, 0.05), CFrame = centre * CFrame.new(0, 0, 0.3), Color = red, Material = Enum.Material.Neon })
	anchoredPart(folder, { Size = Vector3.new(0.07, 60, 0.05), CFrame = centre * CFrame.new(0, 0, 0.3), Color = red, Material = Enum.Material.Neon })
	-- Grey wings far out to either side so a wide view still has something behind the gun.
	for _, side in ipairs({ -1, 1 }) do
		anchoredPart(folder, { Size = Vector3.new(1, 60, 120), CFrame = centre * CFrame.new(side * 45, 0, 60), Color = Color3.fromRGB(150, 154, 160) })
	end
end

local function light(folder, position)
	local anchor = anchoredPart(folder, { Size = Vector3.new(0.2, 0.2, 0.2), Position = position, Transparency = 1 })
	local point = Instance.new("PointLight")
	point.Brightness = 1.2
	point.Range = 16
	point.Color = Color3.fromRGB(255, 248, 238)
	point.Parent = anchor
end

local function ids()
	local list = {}
	for id in pairs(WeaponData.Weapons) do
		if not SHOW or table.find(SHOW, id) then
			table.insert(list, id)
		end
	end
	table.sort(list, function(a, b)
		local da, db = WeaponData.Get(a), WeaponData.Get(b)
		if da.style ~= db.style then
			return da.style < db.style
		end
		return a < b
	end)
	return list
end

-- Builds the gun, returns the eye frame the viewmodel would use, and dresses the scene around it.
local function stageGun(folder, id)
	local def = WeaponData.Get(id)
	local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	local pivot = model:GetPivot()
	model:PivotTo(ORIGIN)
	model.Parent = folder
	local kp = model:GetAttribute("KP_Sight")
	local relief = model:GetAttribute("EyeRelief")
	if typeof(kp) ~= "CFrame" or type(relief) ~= "number" then
		print(string.format("[BRR_Gallery] note %s: no KP_Sight/EyeRelief, skipped", id))
		return nil
	end
	local eye = ORIGIN * pivot:Inverse() * kp * CFrame.new(0, 0, relief)
	board(folder, eye)
	light(folder, (eye * CFrame.new(0.6, 0.8, 0.4)).Position)
	print(string.format("[BRR_Gallery] note %s: optic %s, relief %.2f", id, tostring(model:GetAttribute("Optic")), relief))
	return eye
end

local views = {}
for _, id in ipairs(ids()) do
	for _, kind in ipairs({ { "ads", ADS_FOV }, { "zoom", ZOOM_FOV } }) do
		table.insert(views, {
			name = kind[1] .. "_" .. id,
			settle = 0.8,
			setup = function(folder, camera)
				local eye = stageGun(folder, id)
				if eye then
					camera.FieldOfView = kind[2]
					camera.CFrame = eye
				end
			end,
		})
	end
end

return views
