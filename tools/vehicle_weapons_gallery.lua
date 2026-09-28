-- Armed vehicles gallery and probe: each armed model (VehicleModels.Mounts) at rest and with its
-- mount swung, plus a sweep that says whether the barrel ever passes through its own bodywork
-- inside the arc VehicleWeaponData gives it.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vehicle_weapons_gallery.lua -OutDir <folder>
--
-- Views per armed model:
--   <Model>_rest     front-left quarter, the mount at its rest pitch
--   <Model>_swung    the same model with the mount turned 60 degrees left and at its top pitch
--   <Model>_low      the mount turned 90 degrees left and at its floor there (its lowest pitch), close
--                    and side-on from in front, so the barrel's angle reads: clear of the roof and rails
--   <Model>_high     the same at its top pitch: the breech and grips clear of the roof and hatch
--   <Model>_mount    close on the mount's foot: what it stands on and how (plate, bolts, column, ring,
--                    yoke), from low at the back-left quarter
--   <Model>_driver   the driver's gun (VehicleModels.DriverMounts), turned to the edge of its arc
--                    and up, close from the front-left
--   <Model>_sweep    no picture worth keeping: the numbers. Each mount is posed at every 15 degrees
--                    of yaw (5 for the driver's gun) and 5 of pitch inside its limits (its front
--                    guard's floor included); at each pose a ray runs from the pitch pivot out through
--                    the muzzle and 4 studs beyond, against every part of the vehicle that is not that
--                    mount. "clear" means the barrel and the first stretch of the shot never meet the
--                    vehicle's own body. Any pose that does is printed by name.
-- The server excludes the vehicle from its own shots whatever this says; the sweep is about what a
-- player SEES (a rocket leaving through the cab roof).
--
-- static-check: globals VIEW_KINDS_OVERRIDE
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

-- Poses a mount (degrees; `mount` "turret" or "driver", VehicleWeaponData.Parts). Returns an undo.
local function pose(model, yaw, pitch, mount)
	local names = VehicleWeaponData.Parts[mount or "turret"]
	local yawPart, pitchPart = model:FindFirstChild(names.yaw), model:FindFirstChild(names.pitch)
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

-- Every pose of `mount` inside its arc (front guard included): the rays from pivot out past the muzzle
-- against the rest of the vehicle. Returns poses, blocked.
local function sweepMount(model, modelId, spec, mount, yawStep)
	local names = VehicleWeaponData.Parts[mount]
	local moving = subtree(model, model:FindFirstChild(names.yaw))
	local body = {}
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and not moving[part] and part.Transparency < 1 then
			part.CanQuery = true
			table.insert(body, part)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = body
	local poses, blocked = 0, 0
	for yaw = -spec.yawLimit, spec.yawLimit, yawStep do
		local floor = math.deg(VehicleWeaponData.PitchFloor(spec, math.rad(yaw)))
		for pitch = floor, spec.pitchMax, 5 do
			local undo = pose(model, yaw, pitch, mount)
			local from = model:FindFirstChild(names.pitch).Position
			local muzzle = model:FindFirstChild(names.muzzle).Position
			local out = (muzzle - from).Unit
			local hit = workspace:Raycast(from, (muzzle - from) + out * 4, params)
			poses += 1
			if hit then
				blocked += 1
				note(string.format("%s %s sweep: yaw %d pitch %d meets its own %s", modelId, mount, yaw, pitch, hit.Instance.Name))
			end
			undo()
		end
	end
	note(string.format("%s %s sweep: %d poses, %d meet the vehicle's own body -- %s", modelId, mount, poses, blocked,
		blocked == 0 and "clear" or "BLOCKED"))
	return poses, blocked
end

for modelId in pairs(VehicleModels.Mounts) do
	local spec = VehicleWeaponData.ForModel(modelId, "turret")
	if not spec then
		note(modelId .. ": has a mount but NO WEAPON in VehicleWeaponData")
	end
	local driverSpec = VehicleModels.DriverMounts[modelId] and VehicleWeaponData.ForModel(modelId, "driver") or nil
	table.insert(views, {
		name = modelId .. "_mount",
		settle = 1,
		setup = function(folder, camera)
			stage(folder)
			local model = place(folder, modelId)
			pose(model, 25, spec and spec.restPitch or 0)
			local foot = model:FindFirstChild("TurretYaw").Position - ORIGIN
			-- From above the back-left quarter, so a mount down in a bed or a hatch is seen over its sides.
			look(camera, foot + Vector3.new(-4.6, 3.6, 4.8), foot + Vector3.new(0, 0.8, 0), 42)
		end,
	})
	if driverSpec then
		table.insert(views, {
			name = modelId .. "_driver",
			settle = 1,
			setup = function(folder, camera)
				stage(folder)
				local model = place(folder, modelId)
				pose(model, driverSpec.yawLimit, driverSpec.pitchMax, "driver")
				local gun = model:FindFirstChild("DriverGunPitch").Position - ORIGIN
				look(camera, gun + Vector3.new(-6.5, 2.5, -7), gun, 40)
			end,
		})
	elseif VehicleModels.DriverMounts[modelId] then
		note(modelId .. ": has a driver's mount but NO driver's WEAPON in VehicleWeaponData")
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
	-- Side-on to a barrel turned 90 degrees left (it points along -X), from in front and a little above.
	for _, limit in ipairs({ "low", "high" }) do
		table.insert(views, {
			name = modelId .. "_" .. limit,
			settle = 1,
			setup = function(folder, camera)
				stage(folder)
				local model = place(folder, modelId)
				local yaw = spec and math.min(90, spec.yawLimit) or 60
				local pitch = 0
				if spec then
					pitch = limit == "low" and math.deg(VehicleWeaponData.PitchFloor(spec, math.rad(yaw))) or spec.pitchMax
				end
				pose(model, yaw, pitch)
				local target = model:FindFirstChild("TurretPitch").Position - ORIGIN
				look(camera, target + Vector3.new(-2.5, 2, -13), target + Vector3.new(-1.5, -0.8, 0), 40)
				checkVisible(camera, model, modelId .. "_" .. limit, folder)
			end,
		})
	end
	table.insert(views, {
		name = modelId .. "_sweep",
		settle = 0.5,
		setup = function(folder, camera)
			stage(folder)
			local model = place(folder, modelId)
			if spec then
				sweepMount(model, modelId, spec, "turret", 15)
			end
			if driverSpec then
				sweepMount(model, modelId, driverSpec, "driver", 5)
			end
			look(camera, Vector3.new(-18, 14, -18), Vector3.new(0, 5, 0), 40)
		end,
	})
end

table.sort(views, function(a, b)
	return a.name < b.name
end)

-- VIEW_KINDS_OVERRIDE = { "mount", "sweep" } in a chunk glued in front renders just those kinds.
if VIEW_KINDS_OVERRIDE then
	local kept = {}
	for _, view in ipairs(views) do
		for _, kind in ipairs(VIEW_KINDS_OVERRIDE) do
			if string.sub(view.name, -#kind - 1) == "_" .. kind then
				table.insert(kept, view)
				break
			end
		end
	end
	views = kept
end

return views
