-- Scope gallery: what you see aiming a scoped gun, rebuilt the way the game shows it.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/scope_gallery.lua -OutDir <folder>
--
-- The viewmodel is posed at several points of the aim (the tube coming up to the eye, then fully
-- scoped with the viewmodel hidden, as CombatClient does at aim > 0.92), the camera zoomed the way
-- CombatClient zooms it, and the full-screen scope overlay built with CombatClient's own code in
-- StarterGui so the viewport draws it. A variant of the overlay pins the stroke's position
-- explicitly, to tell a stroke that covers the screen from one that frames it.

local SHOW = { "DeluluRailgun", "LarilaSniper", "SixSevenMarksman", "GrassToucherDMR", "SigmaScout" }
local SCOPE_ZOOM = { sniper = 0.3, dmr = 0.45, railgun = 0.4 }
local BASE_FOV = 70

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local ORIGIN = Vector3.new(0, 600, 0)
Lighting.ClockTime = 14
Lighting.Brightness = 2.4

local function scene(folder)
	local function block(size, position, color, material)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.Position = position
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		part.Parent = folder
	end
	block(Vector3.new(160, 1, 260), ORIGIN + Vector3.new(0, -5.5, -120), Color3.fromRGB(116, 112, 104), Enum.Material.Concrete)
	block(Vector3.new(120, 60, 1), ORIGIN + Vector3.new(0, 10, -150), Color3.fromRGB(172, 170, 164), Enum.Material.Plaster)
	block(Vector3.new(6, 6, 0.2), ORIGIN + Vector3.new(0, 0, -149.4), Color3.fromRGB(210, 60, 50))
	block(Vector3.new(3, 3, 0.2), ORIGIN + Vector3.new(0, 0, -149.2), Color3.fromRGB(240, 236, 226))
end

-- CombatClient's overlay, line for line; `strokePosition` optionally pins UIStroke.BorderStrokePosition.
local function overlay(strokePosition)
	local scopeGui = Instance.new("ScreenGui")
	scopeGui.Name = "BRR_ScopeGallery"
	scopeGui.IgnoreGuiInset = true
	scopeGui.DisplayOrder = -1
	local scopeLens = Instance.new("Frame")
	scopeLens.AnchorPoint = Vector2.new(0.5, 0.5)
	scopeLens.Position = UDim2.fromScale(0.5, 0.5)
	scopeLens.Size = UDim2.fromScale(0.92, 0.92)
	scopeLens.SizeConstraint = Enum.SizeConstraint.RelativeYY
	scopeLens.BackgroundColor3 = Color3.fromRGB(120, 200, 180)
	scopeLens.BackgroundTransparency = 0.94
	scopeLens.BorderSizePixel = 0
	scopeLens.Parent = scopeGui
	local lensCorner = Instance.new("UICorner")
	lensCorner.CornerRadius = UDim.new(0.5, 0)
	lensCorner.Parent = scopeLens
	local lensStroke = Instance.new("UIStroke")
	lensStroke.Thickness = 4000
	lensStroke.Color = Color3.new(0, 0, 0)
	lensStroke.Parent = scopeLens
	local positionNote = "default"
	local okRead, current = pcall(function()
		return lensStroke.BorderStrokePosition
	end)
	if okRead then
		positionNote = "default=" .. tostring(current)
	end
	if strokePosition then
		local okSet = pcall(function()
			lensStroke.BorderStrokePosition = strokePosition
		end)
		positionNote ..= okSet and (" set " .. tostring(strokePosition)) or " (no BorderStrokePosition property)"
	end
	local function reticle(position, size, color)
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = position
		line.Size = size
		line.BackgroundColor3 = color or Color3.new(0, 0, 0)
		line.BorderSizePixel = 0
		line.Parent = scopeLens
	end
	reticle(UDim2.fromScale(0.5, 0.5), UDim2.new(1, 0, 0, 1))
	reticle(UDim2.fromScale(0.5, 0.5), UDim2.new(0, 1, 1, 0))
	for _, side in ipairs({ -1, 1 }) do
		reticle(UDim2.fromScale(0.5 + side * 0.33, 0.5), UDim2.new(0.34, 0, 0, 4))
		reticle(UDim2.fromScale(0.5, 0.5 + side * 0.33), UDim2.new(0, 4, 0.34, 0))
	end
	reticle(UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(4, 4), Color3.fromRGB(255, 60, 60))
	scopeGui.Parent = StarterGui
	print("[BRR_Gallery] overlay stroke position: " .. positionNote)
	return scopeGui
end

local current = nil
local function clearOverlay()
	if current then
		current:Destroy()
		current = nil
	end
end

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			clearOverlay()
			scene(folder)
			camera.CFrame = CFrame.new(ORIGIN)
		end,
	},
}

for _, id in ipairs(SHOW) do
	local def = WeaponData.Get(id)
	local zoom = SCOPE_ZOOM[def.style] or 0.64
	for _, moment in ipairs({ { "aim60", 0.6 }, { "aim90", 0.9 }, { "scoped", 1, true }, { "scoped_outer", 1, true, "Outer" } }) do
		if moment[4] == nil or id == SHOW[1] then
			table.insert(views, {
				name = id .. "_" .. moment[1],
				setup = function(folder, camera)
					clearOverlay()
					scene(folder)
					local vm = Viewmodel.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
					vm.model.Parent = folder
					local eye = CFrame.new(ORIGIN)
					vm:Pose(eye, { aim = moment[2] })
					if moment[3] then
						vm:SetHidden(true)
						local strokePosition
						if moment[4] then
							local ok, value = pcall(function()
								return Enum.BorderStrokePosition[moment[4]]
							end)
							strokePosition = ok and value or nil
						end
						current = overlay(strokePosition)
					end
					-- CombatClient tweens the FOV toward BASE * zoom while aiming.
					camera.FieldOfView = BASE_FOV + (BASE_FOV * zoom - BASE_FOV) * moment[2]
					camera.CFrame = eye
				end,
			})
		end
	end
end

table.insert(views, {
	name = "cleanup",
	setup = function(folder, camera)
		clearOverlay()
		scene(folder)
		camera.CFrame = CFrame.new(ORIGIN)
	end,
})

return views
