-- #84 / #109 stability probe: does every car and bike stay planted flat out over road seams, stop
-- lines, a bridge deck and off onto grass, in the real engine? Run it in the background (it waits on
-- the machine-wide Studio lock):
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vehicle_stability_probe.lua -OutDir <folder> -TimeoutSeconds 600
--
-- The Studio half of tools/vehicle_stability_sim.py. Each vehicle is built with VehicleModels.Build
-- and rigged with VehicleDynamics.Rig, NOT registered with VehicleService, so this file alone steps
-- it (flat out, wheel straight) from RunService.Stepped, as VehicleClient does for a driver. One
-- anchored lane each, far from where maps generate: a collidable "grass" base, then non-colliding
-- road slabs laid 0.4 proud (MapDecor.RoadLift) in 8-stud pieces with a 0.01 stagger and a hairline
-- gap every third join, two 0.07-proud stop lines, a collidable deck 0.3 above the road, road, grass,
-- and back up onto a road.
--
-- Two modes per vehicle:
--   frame    one Step per Stepped: a client whose frames and physics steps line up
--   split    two Steps per Stepped, each told half the frame. The second sees no physics movement
--            since the first, which is exactly a frame with no physics step under it (a 120/144 Hz
--            screen over a 60 Hz-stepped assembly). Before the #84 fix this is what pogoed the cars.
-- Per run: seconds with every wheel off the ground, the largest change in vertical speed between
-- frames (VehicleClient reports a jolt past 20), the largest vertical speed, and distance covered.
--
-- Planted fault, always run: "Planted_NegDamp", a Rotster whose damping ratio is negated (the damper
-- feeds energy in). It must FAIL; if it passes, the probe cannot see a bouncing car and its PASSes
-- mean nothing.
-- Expect after the fix: every real vehicle PASS in both modes (sim: jolt under 2, never airborne).

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))

local ORIGIN = Vector3.new(-6000, 400, -6000)
local LANE_SPACING = 60
local RUN_SECONDS = 5.5
local SETTLE_SECONDS = 1.0
local MAX_JOLT = 6      -- studs/s change in vertical speed in one frame
local MAX_VY = 7        -- studs/s

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function slab(folder, sizeY, fromZ, toZ, top, x, collide, material, color)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = collide
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = Vector3.new(30, sizeY, math.abs(toZ - fromZ))
	-- The lane runs toward -Z (a model's front), `from` and `to` measured along it.
	part.CFrame = CFrame.new(x, top - sizeY / 2, -(fromZ + toZ) / 2)
	part.Parent = folder
	return part
end

-- The course, in studs along the lane from its start; heights over the base.
local function buildLane(folder, x)
	local base = ORIGIN.Y
	local GRASS = Color3.fromRGB(96, 150, 96)
	local ASPHALT = Color3.fromRGB(62, 62, 66)
	slab(folder, 4, -60, 900, base, x, true, Enum.Material.Grass, GRASS)
	local s, index = 0, 0
	while s < 160 do
		local top = base + 0.4 + (index % 2 == 1 and 0.01 or 0)
		slab(folder, 0.4, s, s + 8, top, x, false, Enum.Material.Asphalt, ASPHALT)
		s += 8
		if index % 3 == 2 then
			s += 0.05
		end
		index += 1
	end
	for _, at in ipairs({ 40, 88 }) do
		slab(folder, 0.07, at, at + 1, base + 0.47, x, false, Enum.Material.SmoothPlastic, Color3.new(1, 1, 1))
	end
	slab(folder, 1.2, s, s + 40, base + 0.7, x, true, Enum.Material.Concrete, Color3.fromRGB(150, 150, 150))
	s += 40
	slab(folder, 0.4, s, s + 60, base + 0.4, x, false, Enum.Material.Asphalt, ASPHALT)
	s += 140 -- 80 studs of bare grass
	slab(folder, 0.4, s, s + 400, base + 0.4, x, false, Enum.Material.Asphalt, ASPHALT)
end

local function drive(folder, modelId, handlingId, mode, x)
	local model = VehicleModels.Build(modelId, Random.new(7))
	model:SetAttribute("VehicleModel", handlingId)
	model:PivotTo(CFrame.new(x, ORIGIN.Y + 0.65, 20))
	model.Parent = folder
	local rig = VehicleDynamics.Rig(model)
	if not rig then
		model:Destroy()
		return nil, "no rig"
	end
	local chassis = rig.chassis
	local top = rig.handling.topSpeed
	chassis.AssemblyLinearVelocity = Vector3.new(0, 0, -top * 0.9)
	local began = tick()
	local lastVy, air, jolt, peakVy, startZ = nil, 0, 0, 0, nil
	local done = Instance.new("BindableEvent")
	local connection
	connection = RunService.Stepped:Connect(function(_, dt)
		local input = { throttle = 1, steer = 0 }
		local telemetry
		if mode == "split" then
			VehicleDynamics.Step(rig, input, dt / 2)
			telemetry = VehicleDynamics.Step(rig, input, dt / 2)
		else
			telemetry = VehicleDynamics.Step(rig, input, dt)
		end
		local elapsed = tick() - began
		local vy = chassis.AssemblyLinearVelocity.Y
		if elapsed > SETTLE_SECONDS then
			startZ = startZ or chassis.Position.Z
			if telemetry.grounded == 0 then
				air += dt
			end
			if lastVy then
				jolt = math.max(jolt, math.abs(vy - lastVy))
			end
			peakVy = math.max(peakVy, math.abs(vy))
		end
		lastVy = vy
		if elapsed > RUN_SECONDS or not chassis.Parent then
			connection:Disconnect()
			done:Fire()
		end
	end)
	done.Event:Wait()
	local distance = startZ and (startZ - chassis.Position.Z) or 0
	model:Destroy()
	local pass = air == 0 and jolt <= MAX_JOLT and peakVy <= MAX_VY and distance > 200
	return pass, string.format("%s %-6s %s | airborne %.2fs, worst jolt %.1f, peak |vy| %.1f, %.0f studs",
		handlingId, mode, pass and "PASS" or "FAIL", air, jolt, peakVy, distance)
end

return {
	{
		name = "vehicle_stability_probe",
		settle = 1,
		hold = 1,
		setup = function(folder, _camera)
			if not RunService:IsRunning() then
				RunService:Run()
			end
			task.wait(2)
			local planted = table.clone(VehicleDynamics.Handling.Rotster)
			planted.dampingRatio = -planted.dampingRatio
			VehicleDynamics.Handling.Planted_NegDamp = planted

			local runs = {}
			for modelId in pairs(VehicleDynamics.Handling) do
				if VehicleModels.Models[modelId] then
					table.insert(runs, { modelId, modelId })
				end
			end
			table.sort(runs, function(a, b)
				return a[1] < b[1]
			end)
			table.insert(runs, { "Rotster", "Planted_NegDamp" })

			local lane, examined, failed, plantCaught = 0, 0, 0, nil
			for _, run in ipairs(runs) do
				for _, mode in ipairs({ "frame", "split" }) do
					local x = ORIGIN.X + lane * LANE_SPACING
					lane += 1
					buildLane(folder, x)
					local ok, pass, text = pcall(drive, folder, run[1], run[2], mode, x)
					if not ok then
						pass, text = nil, "ERROR " .. tostring(pass)
					end
					note(text)
					if run[2] == "Planted_NegDamp" then
						plantCaught = (plantCaught or false) or pass == false
					else
						examined += 1
						if pass ~= true then
							failed += 1
						end
					end
				end
			end
			VehicleDynamics.Handling.Planted_NegDamp = nil
			note(string.format("self-check planted negative damper: %s", plantCaught and "PASS (caught)" or "FAIL (not caught: the numbers above prove nothing)"))
			note(string.format("vehicle stability: %d runs examined, %d failed", examined, failed))
		end,
	},
}
