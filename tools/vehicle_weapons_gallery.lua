-- Armed vehicles gallery and probe: each armed model (VehicleModels.Mounts) at rest and with its
-- mount swung, plus a sweep that says whether the barrel ever passes through its own bodywork
-- inside the arc VehicleWeaponData gives it.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vehicle_weapons_gallery.lua -OutDir <folder>
--
-- Views per armed model:
--   <Model>_rest     front-left quarter, the mount at its rest pitch
--   <Model>_swung    the same model with the mount turned 60 degrees left and at its top pitch
--   <Model>_sweep    no picture worth keeping: the numbers. The mount is posed at every 15 degrees of
--                    yaw and 5 of pitch inside its limits; at each pose a ray runs from the pitch
--                    pivot out through the muzzle and 4 studs beyond, against every part of the
--                    vehicle that is not the mount. "clear" means the barrel and the first stretch of
--                    the shot never meet the vehicle's own body. Any pose that does is printed by name.
-- The server excludes the vehicle from its own shots whatever this says; the sweep is about what a
-- player SEES (a rocket leaving through the cab roof).
--
-- The posing moves anchored parts by hand, the same rotation the client lays on the two Motor6Ds
-- (VehicleWeaponClient: CFrame.Angles(0, yaw, 0) on TurretYaw, CFrame.Angles(pitch, 0, 0) on
-- TurretPitch), because an edit-mode gallery has no physics to carry welded parts round.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))

local ORIGIN = Vector3.new(0, 420, 0)

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function stage(folder)
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(200, 1, 200)
	floor.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(128, 130, 136)
	floor.Material = Enum.Material.Concrete
	floor.Parent = folder
end

local function place(folder, modelId)
	local model = VehicleModels.Build(modelId, Random.new(7), { scheme = 1 })
	model.Parent = folder
	model:PivotTo(CFrame.new(ORIGIN))
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	return model
end

-- Parts that move with `pivot`: welded to it, or hung from it by a joint, all the way down.
local function subtree(model, pivot)
	local set = { [pivot] = true }
	local grew = true
	while grew do
		grew = false
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and not set[part] then
				for _, link in ipairs(part:GetChildren()) do
					local parent = (link:IsA("WeldConstraint") or link:IsA("Motor6D")) and link.Part0 or nil
					if parent and set[parent] and link.Part1 == part then
						set[part] = true
						grew = true
						break
					end
				end
			end
		end
	end
	return set
end

local function rotateAbout(set, pivotFrame, rotation)
	local move = pivotFrame * rotation * pivotFrame:Inverse()
	for part in pairs(set) do
		part.CFrame = move * part.CFrame
	end
end

-- Poses the mount (degrees). Returns an undo.
local function pose(model, yaw, pitch)
	local yawPart, pitchPart = model:FindFirstChild("TurretYaw"), model:FindFirstChild("TurretPitch")
	local saved = {}
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			saved[part] = part.CFrame
		end
	end
	rotateAbout(subtree(model, pitchPart), pitchPart.CFrame, CFrame.Angles(math.rad(pitch), 0, 0))
	rotateAbout(subtree(model, yawPart), yawPart.CFrame, CFrame.Angles(0, math.rad(yaw), 0))
	return function()
		for part, frame in pairs(saved) do
			part.CFrame = frame
		end
	end
end

local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 40
	camera.CFrame = CFrame.lookAt(ORIGIN + eye, ORIGIN + target)
end

-- Occlusion ray to the muzzle (the "IN FRAME is not VISIBLE" lesson), naming what's in the way.
local function checkVisible(camera, model, label, folder)
	local muzzle = model:FindFirstChild("TurretMuzzle")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	local origin = camera.CFrame.Position
	local delta = muzzle.Position - origin
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanQuery = true
		end
	end
	local hit = workspace:Raycast(origin, delta, params)
	if hit and (hit.Position - origin).Magnitude < delta.Magnitude - 1.5 then
		note(string.format("%s: muzzle OCCLUDED by %s", label, hit.Instance:GetFullName()))
	else
		note(string.format("%s: muzzle in clear sight, %.1f studs", label, delta.Magnitude))
	end
end

local views = {}

for modelId in pairs(VehicleModels.Mounts) do
	local spec = VehicleWeaponData.ForModel(modelId)
	if not spec then
		note(modelId .. ": has a mount but NO WEAPON in VehicleWeaponData")
	end
	table.insert(views, {
		name = modelId .. "_rest",
		settle = 1,
		setup = function(folder, camera)
			stage(folder)
			local model = place(folder, modelId)
			pose(model, 0, spec and spec.restPitch or 0)
			local target = model:FindFirstChild("TurretPitch").Position - ORIGIN
			look(camera, target + Vector3.new(-14, 5, -16), target - Vector3.new(0, 2, 0), 40)
			checkVisible(camera, model, modelId .. "_rest", folder)
		end,
	})
	table.insert(views, {
		name = modelId .. "_swung",
		settle = 1,
		setup = function(folder, camera)
			stage(folder)
			local model = place(folder, modelId)
			local yaw = spec and math.min(60, spec.yawLimit) or 60
			pose(model, yaw, spec and spec.pitchMax or 20)
			local target = model:FindFirstChild("TurretPitch").Position - ORIGIN
			look(camera, target + Vector3.new(-16, 6, -12), target - Vector3.new(0, 2, 0), 40)
			checkVisible(camera, model, modelId .. "_swung", folder)
		end,
	})
	table.insert(views, {
		name = modelId .. "_sweep",
		settle = 0.5,
		setup = function(folder, camera)
			stage(folder)
			local model = place(folder, modelId)
			if not spec then
				return
			end
			local mount = subtree(model, model:FindFirstChild("TurretYaw"))
			local body = {}
			for _, part in ipairs(model:GetChildren()) do
				if part:IsA("BasePart") and not mount[part] and part.Transparency < 1 then
					part.CanQuery = true
					table.insert(body, part)
				end
			end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = body
			local poses, blocked = 0, 0
			for yaw = -spec.yawLimit, spec.yawLimit, 15 do
				for pitch = spec.pitchMin, spec.pitchMax, 5 do
					local undo = pose(model, yaw, pitch)
					local from = model:FindFirstChild("TurretPitch").Position
					local muzzle = model:FindFirstChild("TurretMuzzle").Position
					local out = (muzzle - from).Unit
					local hit = workspace:Raycast(from, (muzzle - from) + out * 4, params)
					poses += 1
					if hit then
						blocked += 1
						note(string.format("%s sweep: yaw %d pitch %d meets its own %s", modelId, yaw, pitch, hit.Instance.Name))
					end
					undo()
				end
			end
			note(string.format("%s sweep: %d poses, %d meet the vehicle's own body -- %s", modelId, poses, blocked,
				blocked == 0 and "clear" or "BLOCKED"))
			look(camera, Vector3.new(-18, 14, -18), Vector3.new(0, 5, 0), 40)
		end,
	})
end

table.sort(views, function(a, b)
	return a.name < b.name
end)

return views
