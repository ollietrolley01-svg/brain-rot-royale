-- Gun gallery: gun models lit against a plain backdrop.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/gun_gallery.lua -OutDir <folder>
--
-- Returns the list of views gallery.ps1 walks through. Each builds guns into the folder and aims
-- the edit camera at them; the script captures the viewport as each one comes up. SHOW narrows it
-- to some weapon ids while working on them; nil shows every gun.

local SHOW = nil
local CLOSEUPS = true
local DETAIL = "high"

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local GunModels = require(Shared:WaitForChild("GunModels"))

local ORIGIN = Vector3.new(0, 400, 0)

Lighting.ClockTime = 14
Lighting.Brightness = 2.4
Lighting.ExposureCompensation = 0.1
Lighting.Ambient = Color3.fromRGB(70, 70, 76)
Lighting.OutdoorAmbient = Color3.fromRGB(120, 120, 128)

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

local function stage(folder, cameraPosition)
	local back = Instance.new("Part")
	back.Anchored = true
	back.Size = Vector3.new(1, 80, 160)
	back.CFrame = CFrame.new(ORIGIN + Vector3.new(-9, 0, 0))
	back.Color = Color3.fromRGB(150, 153, 160)
	back.Material = Enum.Material.SmoothPlastic
	back.Parent = folder
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(60, 1, 160)
	floor.CFrame = CFrame.new(ORIGIN + Vector3.new(0, -14, 0))
	floor.Color = Color3.fromRGB(120, 122, 128)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = folder
	if cameraPosition then
		light(folder, cameraPosition + Vector3.new(0, 4, 3), 1.6, 40)
		light(folder, ORIGIN + Vector3.new(3, 8, -6), 1.2, 30)
	end
end

local function label(folder, text, position)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = position
	anchor.Parent = folder
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(300, 26)
	gui.AlwaysOnTop = true
	gui.Parent = anchor
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.GothamBold
	textLabel.TextSize = 16
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.TextStrokeTransparency = 0.3
	textLabel.Text = text
	textLabel.Parent = gui
end

-- Builds with the game's own entry point, anchored in place.
local function place(folder, id, cframe)
	local def = WeaponData.Get(id)
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
	-- Scanned before anchoring moves anything: the same check the harness makes.
	local flush = ZFight.Scan({ model }, GunModels.ZFightTolerance)
	local nudged, fought = 0, {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("ZFixed") then
			nudged += 1
			local key = d.Name .. "/" .. tostring(d:GetAttribute("ZFixedWith"))
			fought[key] = (fought[key] or 0) + 1
		end
	end
	local nudgedList = {}
	for key, n in pairs(fought) do
		table.insert(nudgedList, key .. " x" .. n)
	end
	table.sort(nudgedList)
	print(string.format("[BRR_Gallery] %s: %d parts, nudged %d, flush %d %s | nudged: %s", id, count, nudged, #flush,
		#flush > 0 and table.concat(ZFight.Describe(flush, function() return id end, 4), " ; ") or "",
		table.concat(nudgedList, ", ")))
	return model
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

local views = {}
local all = ids()

-- Frames a gun from `direction` (pointing from the gun toward the eye) so its bounding box fills the
-- view whatever its size: a pistol and a chaingun both come out filling the frame.
local function frameGun(folder, camera, id, direction, fov)
	local model = place(folder, id, CFrame.new(ORIGIN))
	local box, size = model:GetBoundingBox()
	local radius = size.Magnitude / 2
	fov = fov or 30
	local distance = radius / math.tan(math.rad(fov) / 2) * 1.02
	local eye = box.Position + direction.Unit * distance
	stage(folder, eye)
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(eye, box.Position)
end

for _, id in ipairs(all) do
	table.insert(views, {
		name = "side_" .. id,
		setup = function(folder, camera)
			frameGun(folder, camera, id, Vector3.new(1, 0.02, 0), 22)
		end,
	})
	if CLOSEUPS then
		table.insert(views, {
			name = "quarter_" .. id,
			setup = function(folder, camera)
				frameGun(folder, camera, id, Vector3.new(0.8, 0.45, -0.55), 26)
			end,
		})
		table.insert(views, {
			name = "rear_" .. id,
			setup = function(folder, camera)
				frameGun(folder, camera, id, Vector3.new(0.45, 0.5, 1), 26)
			end,
		})
	end
end

return views
