-- Wheel droop gallery: the long-travel cars (TralalaGT, SahurVan, TartarugaScout) with their wheels
-- posed the way VehicleDynamics.AnimateWheels draws them -- at ride height (the springs' rideLift
-- below where the model was built) and at full droop (travelDown, a wheel in the air) on full lock --
-- with a close camera on the front-left wheel. tools/vehicle_models_runtime_check.py poses the same.
-- The body is lifted by the droop, so the tyres stand on the floor (the springs hold it up; at full
-- droop it is in the air). One planted view drops the van's wheels 2 studs, out of their arches:
-- the check's "wheel drooping out of its arch" plant, to show where "in its arch" ends.
--
--   BRR_REPO=$PWD python3 tools/linux/studio.py gallery -Gallery tools/wheel_droop_gallery.lua -OutDir <folder> -PlaceFile $PWD/BrainRotRoyale.rbxlx
--
-- The gallery anchors everything, so a Motor6D.Transform would move nothing: each hub's assembly (the
-- hub and every part welded to it) is moved by hand instead, Part1 = Part0 * C0 * Transform.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local Lighting = game:GetService("Lighting")

local SHOW = { "TralalaGT", "SahurVan", "TartarugaScout" }
local ORIGIN = Vector3.new(0, 420, 0)

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4
Lighting.Ambient = Color3.fromRGB(74, 74, 80)
Lighting.OutdoorAmbient = Color3.fromRGB(124, 124, 132)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function stage(folder)
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(260, 1, 260)
	floor.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(128, 130, 136)
	floor.Material = Enum.Material.Concrete
	floor.Parent = folder
end

-- The part a part is joined to (its WeldConstraint's or Motor6D's Part0), and whether by a motor.
local function jointOf(part)
	for _, k in ipairs(part:GetChildren()) do
		if k:IsA("Motor6D") then
			return k.Part0, true
		elseif k:IsA("WeldConstraint") then
			return k.Part0, false
		end
	end
	return nil, false
end

-- The hub (a part with a Radius attribute, on a Motor6D) a part moves with, if any.
local function hubOf(part)
	local p, hops = part, 0
	while p and hops < 50 do
		if p:GetAttribute("Radius") then
			return p
		end
		local up, motor = jointOf(p)
		if motor and not p:GetAttribute("Radius") then
			return nil -- another pivot (a turret, a steering wheel) before any hub
		end
		p, hops = up, hops + 1
	end
	return nil
end

-- Builds `id` on the stage and poses every wheel `offset` studs along its hub's Y and `steerDeg`
-- round it (steered hubs only), as AnimateWheels' hubTransform does for a car. Returns the model.
local function posed(folder, id, offset, steerDeg)
	local model = VehicleModels.Build(id, Random.new(7), { scheme = 1 })
	model.Parent = folder
	model:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, -offset, 0)))
	local parts = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			table.insert(parts, part)
		end
	end
	local moves = {}
	for _, part in ipairs(parts) do
		local hub = hubOf(part)
		if hub then
			if not moves[hub] then
				local steer = hub:GetAttribute("Steer") == true and -math.rad(steerDeg) or 0
				local rest = hub.CFrame
				moves[hub] = rest * CFrame.new(0, offset, 0) * CFrame.Angles(0, steer, 0) * rest:Inverse()
			end
			part:SetAttribute("DroopMove", true)
		end
	end
	for _, part in ipairs(parts) do
		local hub = part:GetAttribute("DroopMove") and hubOf(part)
		if hub then
			part.CFrame = moves[hub] * part.CFrame
		end
	end
	return model
end

local views = {}
for _, id in ipairs(SHOW) do
	local h = VehicleDynamics.Handling[id]
	local poses = {
		{ "ride", -(h.rideLift or 0), 0 },
		{ "droop_lock", -h.travelDown, h.steerLow },
	}
	if id == "SahurVan" then
		table.insert(poses, { "plant_droop2", -2.0, h.steerLow })
	end
	for _, pose in ipairs(poses) do
		for _, cam in ipairs({ { "quarter", Vector3.new(-6.5, 1.2, -5.5) }, { "side", Vector3.new(-9, 0.4, 0) } }) do
			table.insert(views, {
				name = string.format("%s_%s_%s", pose[1], cam[1], id),
				setup = function(folder, camera)
					stage(folder)
					local model = posed(folder, id, pose[2], pose[3])
					local tyre = model:FindFirstChild("Wheel_FL_Tyre")
					local target = tyre.Position
					camera.FieldOfView = 40
					camera.CFrame = CFrame.lookAt(target + cam[2], target)
					local lip = math.huge
					for _, part in ipairs(model:GetChildren()) do
						if part:IsA("BasePart") and (string.match(part.Name, "^LipFL%d+$") or part.Name == "WellFL") then
							local cf, size = part.CFrame, part.Size
							local half = (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z) / 2
							lip = math.min(lip, part.Position.Y - half)
						end
					end
					note(string.format("%s %s: Wheel_FL offset %.2f steer %d, tyre top %.2f above the floor, arch (lip/well) bottom %.2f",
						id, pose[1], pose[2], pose[3], target.Y + tyre.Size.Y / 2 - ORIGIN.Y, lip - ORIGIN.Y))
				end,
			})
		end
	end
end

return views
