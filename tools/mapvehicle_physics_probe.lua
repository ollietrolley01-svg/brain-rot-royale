-- Map vehicle physics probe: the questions that edit mode cannot answer, measured in Run mode on
-- an isolated rig rather than on a map.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/mapvehicle_physics_probe.lua -WaitSeconds 900
--
-- Why this is a separate file from tools/mapvehicle_probe.lua: physics does not simulate in edit
-- mode, so a "measurement" of buoyancy or ramming taken there would measure nothing. That is the
-- failure this project keeps finding (a ray started inside terrain, a metric reading MoveDirection
-- under MoveTo, an audit run on unparented models), so the two are kept apart on purpose and this
-- one calls RunService:Run() the way claude-0d's vehicle_api_probe does.
--
-- Everything happens 14,000 studs out, and the rig is built AFTER Run mode has settled, so nothing
-- Bootstrap does to the lobby or the terrain on startup can land on top of it. Its water is cut to
-- the real river's profile: bed surface at -7, water surface at -1, channel 34 wide (RIVER_WIDTH).
--
-- What it answers:
--   FLOAT   dropped on the river, does a vehicle float, settle on the bed, or keep sinking?
--   DRIVE   sat in and driven on water: does it move, how fast, and at what height? With the same
--           run on land beside it as the control, so "it drove" can be told from "it drove badly".
--   RAM     what hitting a player with a vehicle does TODAY, at several speeds including walking
--           pace and standstill. This is the baseline M8 has to beat, and the standstill and
--           walking-pace rows are the false-positive measurement claude-43 asked for before
--           approving a ramming feature.
--
-- Lines start "[MAPVEH]". "PROBLEM" lines are findings; "FAULT" lines are planted faults proving
-- the check above them can fail.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ServerScriptService:WaitForChild("Modules")
local VehicleService = require(modules:WaitForChild("VehicleService"))

-- claude-0d's redesign, used read-only. VehicleService is not wired to it yet, so a new-style
-- vehicle is built and stepped directly here: VehicleModels.Build -> VehicleDynamics.Rig -> Step.
-- Guarded, because on a build made before they landed neither exists and that is not a failure.
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local VehicleModels, VehicleDynamics
do
	local modelsScript = sharedFolder:FindFirstChild("VehicleModels")
	local dynamicsScript = sharedFolder:FindFirstChild("VehicleDynamics")
	if modelsScript and dynamicsScript then
		local okModels, models = pcall(require, modelsScript)
		local okDynamics, dynamics = pcall(require, dynamicsScript)
		VehicleModels = okModels and models or nil
		VehicleDynamics = okDynamics and dynamics or nil
	end
end

local TAG = "[MAPVEH]"

-- The rig, clear of the lobby (0, 500, 0) and of anywhere a map builds (the biggest map's ground
-- slab is radius * 2.3 wide, so about 1,700 studs out at most).
--
-- 6,000 rather than the 14,000 this started at, because claude-0d hit a hard limit past which
-- terrain cannot be written AT ALL: it widened its test lanes, pushed the far ones over that line,
-- and every test out there found no ground, dropped vehicles forever and burned its whole timeout
-- — an hour of Studio for nothing. So the rig sits well inside the range, and RIG CHECKS FAIL THE
-- RUN IMMEDIATELY instead of letting a groundless test wait out the clock.
local CX, CZ = 6000, 6000
-- MapTerrain's own numbers, so the rig is the real river and not an approximation of it.
local RIVER_WIDTH = 34
local WATER_SURFACE = -1
local BED_SURFACE = -7
-- The land control strip sits well clear of the water so neither disturbs the other.
local LAND_OFFSET = 400
local SETTLE = 6
local DRIVE_SECONDS = 5
local SAMPLE_STEP = 0.25
-- Ramming: the speeds to arrive at the dummy at. 0 and 4 are the false-positive rows -- walking
-- into a parked car must not hurt.
local RAM_SPEEDS = { 0, 4, 20, 45, 74 }
local RAM_RUNUP = 150

local function out(format, ...)
	if select("#", ...) > 0 then
		print(TAG .. " " .. string.format(format, ...))
	else
		print(TAG .. " " .. format)
	end
end

--------------------------------------------------------------------------------
-- Rig
--------------------------------------------------------------------------------

local folder = Instance.new("Folder")
folder.Name = "MapVehiclePhysicsProbe"
folder.Parent = workspace

local function buildRig()
	local terrain = workspace.Terrain
	-- Bed: a block whose top is 2 under the surface it should render as (MapTerrain.SurfaceLift).
	terrain:FillBlock(CFrame.new(CX, -30, CZ), Vector3.new(700, 42, 700), Enum.Material.Ground)
	-- The channel, water surface at -1 exactly as MapTerrain.River lays it.
	terrain:FillBlock(CFrame.new(CX, WATER_SURFACE - 3, CZ), Vector3.new(RIVER_WIDTH, 6, 600), Enum.Material.Water)
	-- The land control: plain ground at the same height as the river's banks.
	terrain:FillBlock(CFrame.new(CX + LAND_OFFSET, -21 - 2, CZ), Vector3.new(400, 42, 600), Enum.Material.Ground)
	task.wait(1.5)
end

local function surfaceAt(x, z, ignoreWater)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = ignoreWater
	local hit = workspace:Raycast(Vector3.new(x, 200, z), Vector3.new(0, -400, 0), params)
	return hit and hit.Position.Y or nil, hit and hit.Material or nil
end

-- A physics rig to put in a seat. Retried, because CreateHumanoidModelFromDescription fails
-- intermittently in Studio.
local function makeRig(name, position)
	local template
	for _ = 1, 4 do
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			template = model
			break
		end
		task.wait(0.4)
	end
	if not template then
		return nil
	end
	template.Name = name
	template.Parent = folder
	template:PivotTo(CFrame.new(position))
	return template
end

local function humanoidOf(model)
	return model and model:FindFirstChildOfClass("Humanoid") or nil
end

-- Y of a vehicle's chassis, sampled every SAMPLE_STEP for `seconds`.
local function sampleHeight(chassis, seconds)
	local samples = {}
	local elapsed = 0
	while elapsed < seconds do
		task.wait(SAMPLE_STEP)
		elapsed += SAMPLE_STEP
		if chassis.Parent then
			table.insert(samples, chassis.Position.Y)
		end
	end
	return samples
end

local function last(list, count)
	local total, taken = 0, 0
	for index = #list, math.max(1, #list - count + 1), -1 do
		total += list[index]
		taken += 1
	end
	return taken > 0 and total / taken or 0, taken
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(3)

out("PHYSICS start: Run mode %s, rig at (%d, %d)", tostring(RunService:IsRunning()), CX, CZ)

local built, buildErr = pcall(buildRig)
if not built then
	out("PROBLEM rig build failed: %s", tostring(buildErr))
end

-- Fail fast. A rig with no ground makes every test below meaningless, and the expensive mistake is
-- letting those tests run anyway: each one drops a vehicle into nothing and waits out its own
-- timeout. If the terrain did not write, say so and stop.
local rigOk = true
do
	local water, waterMaterial = surfaceAt(CX, CZ, false)
	local bed = surfaceAt(CX, CZ, true)
	local land = surfaceAt(CX + LAND_OFFSET, CZ, true)
	out("RIG water surface %s (material %s, wanted %.1f), bed %s (wanted %.1f), land control %s",
		water and string.format("%.2f", water) or "none", waterMaterial and waterMaterial.Name or "none", WATER_SURFACE,
		bed and string.format("%.2f", bed) or "none", BED_SURFACE,
		land and string.format("%.2f", land) or "none")
	if not water or waterMaterial ~= Enum.Material.Water or not bed or not land then
		rigOk = false
		out("PROBLEM the rig did not write terrain at (%d, %d) -- no water, no bed or no land control. STOPPING NOW rather than dropping vehicles into nothing and waiting out five timeouts. Move the rig closer to the origin: terrain cannot be written past a certain distance out.",
			CX, CZ)
	end

	-- PLANTED FAULT: the same three lookups somewhere the probe never filled must all come back
	-- empty, so "the rig is fine" is a reading and not a default.
	local emptyWater, emptyMaterial = surfaceAt(CX + 3000, CZ + 3000, false)
	out("FAULT rig: 3,000 studs from the rig the same lookup gives %s (want none), material %s (want none)",
		emptyWater and string.format("%.2f", emptyWater) or "none", emptyMaterial and emptyMaterial.Name or "none")
end

if not rigOk then
	folder:Destroy()
	out("PHYSICS abandoned: the rig could not be built, so nothing below was measured.")
	return
end

-- Start the drive loop on THIS copy of the module. The plugin's require gets its own copy, so the
-- server's VehicleService.Start (Bootstrap) does not drive anything created here.
VehicleService.Start()

--------------------------------------------------------------------------------
-- FLOAT: dropped on the river, what happens?
--------------------------------------------------------------------------------

do
	for _, kind in ipairs({ "car", "bike" }) do
		local ok, err = pcall(function()
			local model = VehicleService.Create(folder, Vector3.new(CX, 6, CZ + (kind == "bike" and 120 or 0)), 0, kind)
			local chassis = model:FindFirstChild("Chassis")
			if not chassis then
				out("PROBLEM float %s: no Chassis", kind)
				return
			end
			local samples = sampleHeight(chassis, SETTLE)
			local settled, taken = last(samples, 4)
			local bed = surfaceAt(chassis.Position.X, chassis.Position.Z, true) or BED_SURFACE
			local water = surfaceAt(chassis.Position.X, chassis.Position.Z, false) or WATER_SURFACE
			local verdict
			if settled < bed - 2 then
				verdict = "STILL SINKING (below the bed)"
			elseif settled < water - 1.5 then
				verdict = "SANK to the bed"
			else
				verdict = "floated near the surface"
			end
			out("FLOAT %s dropped on the river: settled at y=%.2f over the last %d of %d samples -- %s (water %.2f, bed %.2f)",
				kind, settled, taken, #samples, verdict, water, bed)
			if #samples >= 2 then
				out("FLOAT %s track: first %.2f, quarter %.2f, half %.2f, last %.2f (%d samples over %.1f s)",
					kind, samples[1], samples[math.max(1, math.floor(#samples / 4))],
					samples[math.max(1, math.floor(#samples / 2))], samples[#samples], #samples, SETTLE)
			end
			model:Destroy()
		end)
		if not ok then
			out("PROBLEM float %s failed: %s", kind, tostring(err))
		end
	end

	-- PLANTED FAULT: the same measurement on the land control must come back "floated near the
	-- surface" relative to solid ground, so a "sank" verdict above is a real difference and not
	-- the verdict this check always gives.
	local ok, err = pcall(function()
		local model = VehicleService.Create(folder, Vector3.new(CX + LAND_OFFSET, 6, CZ), 0, "car")
		local chassis = model:FindFirstChild("Chassis")
		if chassis then
			local samples = sampleHeight(chassis, SETTLE)
			local settled = last(samples, 4)
			local ground = surfaceAt(chassis.Position.X, chassis.Position.Z, true) or 0
			out("FAULT float: the same car on the LAND control settled at y=%.2f, %.2f above solid ground (want a small positive number, not a sink)",
				settled, settled - ground)
		end
		model:Destroy()
	end)
	if not ok then
		out("PROBLEM float control failed: %s", tostring(err))
	end
end

--------------------------------------------------------------------------------
-- DRIVE: sat in and driven, on water and on land
--------------------------------------------------------------------------------

do
	local function driveRun(label, position)
		local model = VehicleService.Create(folder, position, 0, "car")
		local chassis = model:FindFirstChild("Chassis")
		local seat = model:FindFirstChildOfClass("VehicleSeat")
		if not chassis or not seat then
			out("PROBLEM drive %s: no Chassis or no seat", label)
			return
		end
		local rig = makeRig("Driver_" .. label, position + Vector3.new(0, 8, 0))
		local humanoid = humanoidOf(rig)
		if not humanoid then
			out("PROBLEM drive %s: could not make a rig to sit in it", label)
			model:Destroy()
			return
		end
		task.wait(1)
		seat:Sit(humanoid)
		task.wait(0.5)
		if seat.Occupant ~= humanoid then
			out("PROBLEM drive %s: the rig did not take the seat (occupant %s), so nothing below is a drive test",
				label, tostring(seat.Occupant))
			model:Destroy()
			rig:Destroy()
			return
		end

		local from = chassis.Position
		local heights, speeds = {}, {}
		local elapsed = 0
		while elapsed < DRIVE_SECONDS do
			seat.Throttle = 1
			task.wait(SAMPLE_STEP)
			elapsed += SAMPLE_STEP
			if chassis.Parent then
				table.insert(heights, chassis.Position.Y)
				table.insert(speeds, chassis.AssemblyLinearVelocity.Magnitude)
			end
		end
		local travelled = (chassis.Position - from).Magnitude
		local meanHeight, taken = last(heights, #heights)
		local topSpeed = 0
		for _, speed in ipairs(speeds) do
			topSpeed = math.max(topSpeed, speed)
		end
		out("DRIVE %s: travelled %.1f studs in %.1f s, top speed %.1f, mean height %.2f over %d samples",
			label, travelled, DRIVE_SECONDS, topSpeed, meanHeight, taken)
		model:Destroy()
		rig:Destroy()
		return travelled
	end

	local waterOk, waterTravel = pcall(driveRun, "on water", Vector3.new(CX, 4, CZ - 200))
	task.wait(1)
	local landOk, landTravel = pcall(driveRun, "on land (control)", Vector3.new(CX + LAND_OFFSET, 4, CZ - 200))
	if not waterOk then
		out("PROBLEM drive on water failed: %s", tostring(waterTravel))
	end
	if not landOk then
		out("PROBLEM drive on land failed: %s", tostring(landTravel))
	end
	out("DRIVE comparison: water run %s studs, land run %s studs -- if the water run moved a useful distance, the grounded check is passing over water and a car drives the riverbed today",
		waterOk and string.format("%.1f", waterTravel or 0) or "failed",
		landOk and string.format("%.1f", landTravel or 0) or "failed")
end

--------------------------------------------------------------------------------
-- WADE: a wheeled vehicle driven into the river, under claude-0d's NEW dynamics
--------------------------------------------------------------------------------
--
-- Its wheel rays set IgnoreWater deliberately, so a car cannot find grip on a lake. That is the
-- right call, but it means a wheeled vehicle in water has no support from its side either, and
-- "drives into the river and sinks through the world" is the kind of thing a player finds in the
-- first hour. So: build a CrocodiloRanger (the most off-road of the seven, offroad 0.85,
-- all-wheel drive) the new way, drive it off the bank, and watch where it ends up.

do
	if not (VehicleModels and VehicleDynamics) then
		out("WADE skipped: VehicleModels/VehicleDynamics are not in this build, so the new dynamics could not be tested")
	else
		local ok, err = pcall(function()
			local model = VehicleModels.Build("CrocodiloRanger", Random.new(4242))
			model.Parent = folder
			-- On the bank, pointing at the water, far enough back for a run-up.
			local bankZ = CZ - 260
			local bankGround = surfaceAt(CX + 120, bankZ, true)
			if not bankGround then
				out("PROBLEM wade: no bank to start from")
				model:Destroy()
				return
			end
			model:PivotTo(CFrame.new(Vector3.new(CX + 120, bankGround + 4, bankZ)) * CFrame.Angles(0, math.rad(-90), 0))
			local rig = VehicleDynamics.Rig(model)
			if not rig then
				out("PROBLEM wade: VehicleDynamics.Rig returned nil for a CrocodiloRanger, so nothing was stepped")
				model:Destroy()
				return
			end
			local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
			task.wait(1)

			local input = { throttle = 1, steer = 0, handbrake = false, parked = false }
			local lowest, enteredAt, groundedWhenWet = math.huge, nil, nil
			local samples, wetSamples = 0, 0
			local connection = RunService.Heartbeat:Connect(function(dt)
				local okStep, telemetry = pcall(VehicleDynamics.Step, rig, input, dt)
				if okStep and telemetry and chassis then
					samples += 1
					local y = chassis.Position.Y
					lowest = math.min(lowest, y)
					local overWater = chassis.Position.Z < CZ + 300 and chassis.Position.Z > CZ - 300
						and math.abs(chassis.Position.X - CX) < RIVER_WIDTH / 2
					if overWater then
						wetSamples += 1
						enteredAt = enteredAt or y
						groundedWhenWet = telemetry.grounded
					end
				end
			end)
			task.wait(10)
			connection:Disconnect()
			VehicleDynamics.Idle(rig)

			local restY = chassis and chassis.Position.Y or 0
			local verdict
			if restY < BED_SURFACE - 10 then
				verdict = "FELL THROUGH THE WORLD"
			elseif restY < BED_SURFACE - 1 then
				verdict = "sank below the riverbed"
			elseif restY < WATER_SURFACE - 2 then
				verdict = "settled on the bed, submerged"
			else
				verdict = "stayed at or near the surface"
			end
			out("WADE CrocodiloRanger driven into the river: ended at y=%.2f -- %s (water %.2f, bed %.2f). Lowest point reached %.2f over %d stepped frames, %d of them above the channel",
				restY, verdict, WATER_SURFACE, BED_SURFACE, lowest, samples, wetSamples)
			out("WADE telemetry: grounded reading while over water was %s (its wheel rays ignore water, so a low or zero count here is the expected consequence, not a bug)",
				tostring(groundedWhenWet))
			if wetSamples == 0 then
				out("PROBLEM wade: the vehicle never reached the channel, so the verdict above is about the bank and not about water")
			end
			model:Destroy()
		end)
		if not ok then
			out("PROBLEM wade failed: %s", tostring(err))
		end
	end

	-- PLANTED FAULT: the same verdict ladder against a known-good height must read "stayed at or
	-- near the surface", so a "fell through the world" verdict is a measurement and not the default.
	local probe = WATER_SURFACE
	local verdict = probe < BED_SURFACE - 10 and "FELL THROUGH THE WORLD"
		or probe < BED_SURFACE - 1 and "sank below the riverbed"
		or probe < WATER_SURFACE - 2 and "settled on the bed, submerged"
		or "stayed at or near the surface"
	out("FAULT wade: the verdict ladder fed the water surface itself (%.2f) says \"%s\" (want stayed at or near the surface); fed %.2f it says \"%s\" (want fell through)",
		probe, verdict, BED_SURFACE - 40,
		(BED_SURFACE - 40) < BED_SURFACE - 10 and "FELL THROUGH THE WORLD" or "something else")
end

--------------------------------------------------------------------------------
-- REST: where a parked vehicle actually ends up, on the flat and on a slope
--------------------------------------------------------------------------------
--
-- tools/mapvehicle_probe.lua measures the SPAWN pose, because edit mode has no physics. That is
-- the right measurement for "did placement put this on a bank", but not for "what does a parked
-- vehicle look like", because only the Chassis pan collides -- every wheel is CanCollide = false
-- decoration. Create puts the pan rideHeight above the ground, so the pan has room to fall before
-- it rests, and the wheels go wherever that leaves them. This measures the difference.

do
	local SLOPE_X = CX + LAND_OFFSET + 250

	local slopeBuilt = pcall(function()
		-- A 20 degree ramp: everything claude-0d measured climbs 20, so it is the fair case.
		workspace.Terrain:FillBlock(
			CFrame.new(SLOPE_X, -14, CZ) * CFrame.Angles(math.rad(20), 0, 0),
			Vector3.new(220, 40, 320), Enum.Material.Ground)
		task.wait(1.2)
	end)
	if not slopeBuilt then
		out("PROBLEM rest: could not build the slope rig")
	end

	local function restRun(label, x, z)
		local ground = surfaceAt(x, z, true)
		if not ground then
			out("PROBLEM rest %s: no ground under the drop point", label)
			return
		end
		local model = VehicleService.Create(folder, Vector3.new(x, ground, z), 0, "car")
		local chassis = model:FindFirstChild("Chassis")
		if not chassis then
			out("PROBLEM rest %s: no Chassis", label)
			model:Destroy()
			return
		end
		local spawnY = chassis.Position.Y
		local spawnFrame, spawnSize = model:GetBoundingBox()
		local spawnBottom = spawnFrame.Position.Y - spawnSize.Y / 2
		task.wait(SETTLE)
		local restY = chassis.Position.Y
		local cframe, size = model:GetBoundingBox()
		local restBottom = cframe.Position.Y - size.Y / 2

		-- Daylight or burial at each footprint corner, against solid ground under that corner.
		local worstClear, worstBuried = -math.huge, -math.huge
		local corners = 0
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local point = (cframe * CFrame.new(sx * size.X / 2, 0, sz * size.Z / 2)).Position
				local under = surfaceAt(point.X, point.Z, true)
				if under then
					corners += 1
					worstClear = math.max(worstClear, restBottom - under)
					worstBuried = math.max(worstBuried, under - restBottom)
				end
			end
		end
		out("REST %s: chassis spawned at y=%.2f and settled at y=%.2f (dropped %.2f); underside %.2f -> %.2f; worst corner %.2f clear / %.2f buried over %d corners",
			label, spawnY, restY, spawnY - restY, spawnBottom, restBottom, worstClear, worstBuried, corners)
		model:Destroy()
		return spawnY - restY
	end

	local flatOk, flatDrop = pcall(restRun, "flat ground", CX + LAND_OFFSET, CZ - 400)
	task.wait(0.5)
	local slopeOk, slopeDrop = pcall(restRun, "20 degree slope", SLOPE_X, CZ)
	if not flatOk then
		out("PROBLEM rest flat failed: %s", tostring(flatDrop))
	end
	if not slopeOk then
		out("PROBLEM rest slope failed: %s", tostring(slopeDrop))
	end

	-- PLANTED FAULT: a vehicle spawned 10 studs up must show a drop of about 10 more than the flat
	-- run, or "dropped 0.00" above would be indistinguishable from a measurement that never ran.
	local ok, err = pcall(function()
		local ground = surfaceAt(CX + LAND_OFFSET, CZ - 400, true) or 0
		local model = VehicleService.Create(folder, Vector3.new(CX + LAND_OFFSET, ground + 10, CZ - 400), 0, "car")
		local chassis = model:FindFirstChild("Chassis")
		if chassis then
			local spawnY = chassis.Position.Y
			task.wait(SETTLE)
			out("FAULT rest: a car spawned 10 studs high dropped %.2f (want about %.2f, i.e. 10 more than the flat run)",
				spawnY - chassis.Position.Y, (flatOk and flatDrop or 0) + 10)
		end
		model:Destroy()
	end)
	if not ok then
		out("PROBLEM rest fault check failed: %s", tostring(err))
	end

	workspace.Terrain:FillBlock(CFrame.new(SLOPE_X, -10, CZ), Vector3.new(400, 160, 500), Enum.Material.Air)
end

--------------------------------------------------------------------------------
-- RAM: what hitting someone with a vehicle does today
--------------------------------------------------------------------------------

do
	for _, speed in ipairs(RAM_SPEEDS) do
		local ok, err = pcall(function()
			local start = Vector3.new(CX + LAND_OFFSET, 4, CZ + 200)
			local model = VehicleService.Create(folder, start, 0, "car")
			local chassis = model:FindFirstChild("Chassis")
			local seat = model:FindFirstChildOfClass("VehicleSeat")
			if not chassis or not seat then
				out("PROBLEM ram %.0f: no chassis or seat", speed)
				return
			end
			-- The dummy stands directly in front, along the vehicle's -Z.
			local dummy = makeRig("Dummy_" .. tostring(speed), start + Vector3.new(0, 4, -RAM_RUNUP))
			local humanoid = humanoidOf(dummy)
			if not humanoid then
				out("PROBLEM ram %.0f: no dummy", speed)
				model:Destroy()
				return
			end
			task.wait(1)
			local healthBefore = humanoid.Health
			local dummyFrom = dummy:GetPivot().Position

			if speed > 0 then
				-- Drive it at the dummy by writing the assembly velocity straight, so the arrival
				-- speed is the number in the table rather than whatever the accel curve reached.
				local elapsed = 0
				while elapsed < 6 do
					chassis.AssemblyLinearVelocity = Vector3.new(0, chassis.AssemblyLinearVelocity.Y, -speed)
					task.wait(0.05)
					elapsed += 0.05
					if (chassis.Position - dummyFrom).Magnitude < 8 then
						break
					end
				end
			end
			task.wait(1.5)

			local healthAfter = humanoid.Health
			local moved = (dummy:GetPivot().Position - dummyFrom).Magnitude
			out("RAM at %.0f studs/s: dummy health %.1f -> %.1f (lost %.1f), knocked %.1f studs, alive %s",
				speed, healthBefore, healthAfter, healthBefore - healthAfter, moved, tostring(humanoid.Health > 0))
			model:Destroy()
			dummy:Destroy()
		end)
		if not ok then
			out("PROBLEM ram %.0f failed: %s", speed, tostring(err))
		end
		task.wait(0.5)
	end
	out("RAM note: the 0 and 4 rows are the false-positive measurement -- walking into a parked car must stay at 0 damage under any ramming feature")

	-- PLANTED FAULT: damage the dummy by a known amount through the same reading path, so a row of
	-- zeroes above can be told from a health reading that never changes.
	local ok, err = pcall(function()
		local dummy = makeRig("Dummy_fault", Vector3.new(CX + LAND_OFFSET, 6, CZ + 400))
		local humanoid = humanoidOf(dummy)
		if humanoid then
			local before = humanoid.Health
			humanoid:TakeDamage(17)
			task.wait(0.3)
			out("FAULT ram: a planted 17 damage read back as %.1f -> %.1f (lost %.1f, want 17.0)",
				before, humanoid.Health, before - humanoid.Health)
			dummy:Destroy()
		end
	end)
	if not ok then
		out("PROBLEM ram fault check failed: %s", tostring(err))
	end
end

--------------------------------------------------------------------------------
-- Tidy up
--------------------------------------------------------------------------------

do
	folder:Destroy()
	workspace.Terrain:FillBlock(CFrame.new(CX, -20, CZ), Vector3.new(900, 120, 900), Enum.Material.Air)
	workspace.Terrain:FillBlock(CFrame.new(CX + LAND_OFFSET, -20, CZ), Vector3.new(700, 120, 900), Enum.Material.Air)
	out("PHYSICS done: rig removed, %d vehicles still registered in this copy of VehicleService", VehicleService.Count())
end
