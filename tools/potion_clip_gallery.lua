-- Renders the drink item's worst frame against the camera, before and after -- Oliver's #7. Numbers
-- are in tools/potion_clip_probe.lua (baseline) and the fix exploration that picked these constants
-- (DRINK_PIVOT_LIFT = 1.4, translation UNCHANGED -- the arc alone clears all three drinks with
-- 0.6-1.1 studs to spare, so no translation cap was needed). This is the render the harness requires
-- alongside those numbers.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/potion_clip_gallery.lua -OutDir <dir> -Hold 1
--
-- The "worst frame" is progress=1 (fully tipped, held) -- confirmed by the numeric probe: every
-- item's worst corner lands at or past the point tip reaches 1 (33-97% through their own useTime,
-- all AFTER the 0.25-progress tip-up completes), so the held pose IS the worst case, not a
-- transient mid-swing moment.
--
-- Camera sits at the world origin looking down -Z, matching the numeric probe's camera-local-space
-- convention exactly: Z=0 is the eye, negative is in front. A translucent sphere at the origin
-- stands in for the eye/face so the intrusion reads visually, not just in the log.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemModels = require(Shared:WaitForChild("ItemModels"))

Lighting.ClockTime = 14
Lighting.Brightness = 2.2
Lighting.Ambient = Color3.fromRGB(90, 90, 96)
Lighting.OutdoorAmbient = Color3.fromRGB(130, 130, 138)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local ITEM_HIP = Vector3.new(0.8, -0.85, -1.9)
local ORIGIN = Vector3.new(0, 400, 0)

local function smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Held pose: tip=1, useAlpha=1 (the animation has been running well past the 0.25-progress tip-up).
local TIP = 1

local function currentUseTarget()
	return CFrame.new(-0.6 * TIP, 0.62 * TIP, 1.05 * TIP) * CFrame.Angles(1.15 * TIP, 0, 0.35 * TIP)
end

local DRINK_PIVOT_LIFT = 1.4
local function fixedUseTarget()
	local lift = DRINK_PIVOT_LIFT * TIP
	return CFrame.new(-0.6 * TIP, 0.62 * TIP, 1.05 * TIP)
		* CFrame.new(0, lift, 0) * CFrame.Angles(1.15 * TIP, 0, 0.35 * TIP) * CFrame.new(0, -lift, 0)
end

local function buildAt(camera, id, useTarget)
	local model = ItemModels.Build(id, { name = "BRR_PotionClipGallery" })
	local pivot = model:GetPivot()
	local gripPart = model:FindFirstChild("Grip")
	local grip = gripPart and pivot:ToObjectSpace(gripPart.CFrame).Position or Vector3.zero
	local frame = camera.CFrame * CFrame.new(ITEM_HIP) * CFrame.Angles(0, 0.2, 0) * useTarget * CFrame.new(-grip)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CFrame = frame * pivot:ToObjectSpace(part.CFrame)
			part.Anchored = true
		end
	end
	model.Parent = workspace
	return model
end

local function eyeMarker(folder)
	local eye = Instance.new("Part")
	eye.Shape = Enum.PartType.Ball
	eye.Size = Vector3.new(0.4, 0.4, 0.4)
	eye.CFrame = CFrame.new(ORIGIN)
	eye.Color = Color3.fromRGB(255, 90, 90)
	eye.Material = Enum.Material.Neon
	eye.Transparency = 0.35
	eye.CanCollide = false
	eye.Anchored = true
	eye.Parent = folder
end

local function stageCamera(camera)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.new(ORIGIN, ORIGIN + Vector3.new(0, 0, -1))
end

local views = {}

table.insert(views, {
	name = "potion_before_ShieldPotion",
	setup = function(folder, camera)
		stageCamera(camera)
		eyeMarker(folder)
		local model = buildAt(camera, "ShieldPotion", currentUseTarget())
		model.Parent = folder
		note("BEFORE: ShieldPotion held pose, current formula -- measured worst Z +0.636 studs BEHIND the eye (red marker). IN THE BUILT PLACE today.")
	end,
})

table.insert(views, {
	name = "potion_after_ShieldPotion",
	setup = function(folder, camera)
		stageCamera(camera)
		eyeMarker(folder)
		local model = buildAt(camera, "ShieldPotion", fixedUseTarget())
		model.Parent = folder
		note("AFTER: ShieldPotion held pose, tip pivot lifted 1.4 studs toward the neck (translation unchanged) -- measured worst Z -0.636 studs, in front of the eye. NOT IN THE BUILT PLACE, design only -- patch to guns tab.")
	end,
})

table.insert(views, {
	name = "potion_before_MiniShield",
	setup = function(folder, camera)
		stageCamera(camera)
		eyeMarker(folder)
		local model = buildAt(camera, "MiniShield", currentUseTarget())
		model.Parent = folder
		note("BEFORE: MiniShield held pose -- measured worst Z +0.135 studs behind the eye. IN THE BUILT PLACE today.")
	end,
})

table.insert(views, {
	name = "potion_after_MiniShield",
	setup = function(folder, camera)
		stageCamera(camera)
		eyeMarker(folder)
		local model = buildAt(camera, "MiniShield", fixedUseTarget())
		model.Parent = folder
		note("AFTER: MiniShield held pose, same fix -- measured worst Z -1.131 studs. NOT IN THE BUILT PLACE, design only.")
	end,
})

return views
