-- #84 / #109 landing and flip probe: the two halves of Oliver's "done" that
-- tools/vehicle_stability_probe.lua does not drive. "It still lands cleanly off a real jump and still
-- rolls if you flip it hard." Written outside Studio and never run (Jacob's branch
-- task/prove-car-bounce); the coordinator queues it, as the stability probe is queued:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vehicle_landing_probe.lua -OutDir <folder> -TimeoutSeconds 600
--
-- The same set-up as the stability probe: each car is built with VehicleModels.Build, rigged with
-- VehicleDynamics.Rig, NOT registered with VehicleService, and stepped from RunService.Stepped, as
-- VehicleClient does for a driver. Cars only (kind "car"); bikes are balanced by an AlignOrientation
-- and have their own sim. The courses copy tools/vehicle_stability_sim.py's:
--   jump   grass run-up, a 20-degree collidable kicker 14 studs long, flat grass beyond. Entered at
--          70 studs/s, half throttle. PASS = in the air at least 0.2 s off the kicker, never back in
--          the air for more than 0.1 s once down, and wheels-down (up > 0.5, four wheels grounded)
--          at the end.
--   flip   flat grass at 30 studs/s, no throttle; at 0.5 s a blast's worth of roll (40 rad/s about
--          the nose) and lift (40 studs/s). PASS = the body goes past 90 degrees (up < 0).
--
-- Airtime is measured twice: by the dynamics' own verdict (telemetry.grounded == 0), and
-- independently of the code under test, by the chassis's height over the flat ground against the ride
-- height it settled at on the run-up. The PASS uses the independent one; both are printed, and a
-- disagreement between them is its own finding.
--
-- Planted faults, always run, each aimed at an invariant:
--   Planted_NegDamp (jump)  a Rotster whose damper feeds energy in. "A car that lands does not
--                           re-launch" must refuse it: expect FAIL.
--   Planted_Upright (flip)  a Rotster held upright by an AlignOrientation of unlimited torque.
--                           "A hard blast rolls a car" must refuse any such hold: expect FAIL.
-- If either plant passes, that check cannot see what it claims to and its PASSes mean nothing.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))

local ORIGIN = Vector3.new(-6000, 400, 6000) -- the stability probe's lanes are at Z = -6000
local LANE_SPACING = 60
local KICKER_AT, KICKER_LENGTH, KICKER_DEG = 30, 14, 20
local AIR_MARGIN = 0.6 -- studs over the settled ride height before the chassis counts as airborne

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local GRASS = Color3.fromRGB(96, 150, 96)

-- A collidable grass slab along the lane (the lane runs toward -Z), top at `top`.
local function ground(folder, x, fromS, toS, top)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = true
	part.Material = Enum.Material.Grass
	part.Color = GRASS
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = Vector3.new(30, 4, toS - fromS)
	part.CFrame = CFrame.new(x, top - 2, -(fromS + toS) / 2)
	part.Parent = folder
	return part
end

local function buildJumpLane(folder, x)
	local base = ORIGIN.Y
	ground(folder, x, -60, KICKER_AT, base)
	ground(folder, x, KICKER_AT + KICKER_LENGTH, 900, base)
	-- The kicker: a slab rising from the ground at KICKER_AT to its lip at KICKER_AT + KICKER_LENGTH.
	-- Rotated about X so its top face is the ramp; its lower end is buried in the run-up.
	local angle = math.rad(KICKER_DEG)
	local length = KICKER_LENGTH / math.cos(angle)
	local rise = KICKER_LENGTH * math.tan(angle)
	local ramp = Instance.new("Part")
	ramp.Anchored = true
	ramp.CanCollide = true
	ramp.Material = Enum.Material.Grass
	ramp.Color = GRASS
	ramp.Size = Vector3.new(30, 4, length)
	local midTop = Vector3.new(x, base + rise / 2, -(KICKER_AT + KICKER_LENGTH / 2))
	-- Nose-up toward -Z: the far (more negative Z) end is the high one.
	local frame = CFrame.new(midTop) * CFrame.Angles(angle, 0, 0)
	ramp.CFrame = frame * CFrame.new(0, -2, 0)
	ramp.Parent = folder
end

local function buildFlatLane(folder, x)
	ground(folder, x, -60, 900, ORIGIN.Y)
end

local function hold(chassis)
	local attachment = Instance.new("Attachment")
	attachment.Parent = chassis
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = true
	align.CFrame = CFrame.new()
	align.Parent = chassis
	return align
end

-- One run. Returns pass (true/false), a line of text.
local function run(folder, modelId, handlingId, course, x, upright)
	local model = VehicleModels.Build(modelId, Random.new(7))
	model:SetAttribute("VehicleModel", handlingId)
	model:PivotTo(CFrame.new(x, ORIGIN.Y + 0.65, 20))
	model.Parent = folder
	local rig = VehicleDynamics.Rig(model)
	if not rig then
		model:Destroy()
		return false, handlingId .. " " .. course .. " FAIL | no rig"
	end
	local chassis = rig.chassis
	if upright then
		hold(chassis)
	end
	local speed = course == "jump" and 70 or 30
	chassis.AssemblyLinearVelocity = Vector3.new(0, 0, -speed)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { model }

	local began = tick()
	local duration = course == "jump" and 4 or 3
	local rideHeight, rideSamples = 0, 0
	local airSelf, airIndependent = 0, 0
	local spells, current, kicked, minUp = {}, 0, false, 1
	local lastGrounded = 0
	local done = Instance.new("BindableEvent")
	local connection
	connection = RunService.Stepped:Connect(function(_, dt)
		local elapsed = tick() - began
		local input = { throttle = course == "jump" and 0.5 or 0, steer = 0 }
		if course == "flip" and not kicked and elapsed > 0.5 then
			kicked = true
			chassis.AssemblyAngularVelocity += chassis.CFrame.LookVector * -40
			chassis.AssemblyLinearVelocity += Vector3.new(0, 40, 0)
		end
		local telemetry = VehicleDynamics.Step(rig, input, dt)
		lastGrounded = telemetry.grounded
		minUp = math.min(minUp, chassis.CFrame.UpVector.Y)
		if telemetry.grounded == 0 then
			airSelf += dt
		end
		if course == "jump" then
			-- Height over whatever is straight below, measured past the model.
			local hit = workspace:Raycast(chassis.Position, Vector3.new(0, -60, 0), rayParams)
			local over = hit and (chassis.Position.Y - hit.Position.Y) or math.huge
			-- On the run-up, past the first moments of settling onto the springs.
			if -chassis.Position.Z < KICKER_AT - 5 and elapsed > 0.4 then
				rideHeight += over
				rideSamples += 1
			end
			local settled = rideSamples > 0 and rideHeight / rideSamples or nil
			if settled and over > settled + AIR_MARGIN then
				airIndependent += dt
				current += dt
			elseif current > 0 then
				table.insert(spells, current)
				current = 0
			end
		end
		if elapsed > duration or not chassis.Parent then
			connection:Disconnect()
			done:Fire()
		end
	end)
	done.Event:Wait()
	if current > 0 then
		table.insert(spells, current)
	end
	local endUp = chassis.CFrame.UpVector.Y
	model:Destroy()

	if course == "jump" then
		local first = spells[1] or 0
		local relaunch = 0
		for i = 2, #spells do
			relaunch = math.max(relaunch, spells[i])
		end
		local pass = rideSamples > 0 and first >= 0.2 and relaunch <= 0.1 and endUp > 0.5 and lastGrounded == 4
		return pass, string.format("%s jump %s | air %.2fs (dynamics' own count %.2fs), relaunch %.2fs, end up %.2f, wheels down %d, ride-height samples %d",
			handlingId, pass and "PASS" or "FAIL", first, airSelf, relaunch, endUp, lastGrounded, rideSamples)
	end
	local pass = minUp < 0
	return pass, string.format("%s flip %s | min up %.2f%s", handlingId, pass and "PASS" or "FAIL", minUp, upright and " (held upright)" or "")
end

return {
	{
		name = "vehicle_landing_probe",
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

			local cars = {}
			for modelId in pairs(VehicleDynamics.Handling) do
				local def = VehicleModels.Models[modelId]
				if def and def.kind == "car" then
					table.insert(cars, modelId)
				end
			end
			table.sort(cars)
			local candidates = 0
			for _ in pairs(VehicleModels.Models) do
				candidates += 1
			end
			note(string.format("%d vehicle models examined, %d cars driven", candidates, #cars))

			local lane, examined, failed = 0, 0, 0
			local function lanes(modelId, handlingId, course, upright)
				local x = ORIGIN.X + lane * LANE_SPACING
				lane += 1
				if course == "jump" then
					buildJumpLane(folder, x)
				else
					buildFlatLane(folder, x)
				end
				local ok, pass, text = pcall(run, folder, modelId, handlingId, course, x, upright)
				if not ok then
					pass, text = nil, string.format("%s %s ERROR %s", handlingId, course, tostring(pass))
				end
				note(text)
				return pass
			end
			for _, modelId in ipairs(cars) do
				for _, course in ipairs({ "jump", "flip" }) do
					examined += 1
					if lanes(modelId, modelId, course, false) ~= true then
						failed += 1
					end
				end
			end
			local negDamp = lanes("Rotster", "Planted_NegDamp", "jump", false)
			local upright = lanes("Rotster", "Rotster", "flip", true)
			VehicleDynamics.Handling.Planted_NegDamp = nil
			note(string.format("self-check planted negative damper on the jump: %s",
				negDamp == false and "PASS (caught)" or "FAIL (not caught: the jump PASSes above prove nothing)"))
			note(string.format("self-check planted upright hold on the flip: %s",
				upright == false and "PASS (caught)" or "FAIL (not caught: the flip PASSes above prove nothing)"))
			note(string.format("vehicle landing: %d runs examined, %d failed", examined, failed))
		end,
	},
}
