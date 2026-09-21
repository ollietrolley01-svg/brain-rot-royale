-- Vehicle handling probe: drives every vehicle kind through a fixed course and prints what it
-- measured. Run it in the background (it waits on the machine-wide Studio lock):
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vehicle_probe.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Switches the gallery copy into Run mode (physics on). Each test builds its own anchored lane far
-- from where maps generate, spawns a vehicle through VehicleService.Create exactly as the map does,
-- sits an R15 rig in the driver seat and scripts the seat's throttle and steer. Per kind:
--   flat     top speed, time to 60 and to 95% of top, stopping distance coasting and braking
--   lock     full lock at speed: tightest turn radius, peak roll, whether it rolled over
--   turn 40  full lock held at about 40 studs/s: radius, roll, lean
--   slalom   60% steer one way then the other, 0.9s each, at 50: swing, roll, lowest up
--   grade N  whether it gets up an N-degree ramp from a run-up, and how high it got
--   side N   full throttle across an N-degree side slope: peak roll, rolled or not, slide downhill
--   drop     off a 12-stud ledge at speed: lowest uprightness after landing, speed kept
--   kerb N   whether it mounts an N-stud step from a short run-up
--   terrain  the same on Terrain (maps are driven on terrain): a grass climb, a side slope, a
--            field of bumps
--   road     non-colliding asphalt laid over terrain (as the map's roads are), onto a colliding
--            bridge deck and back to bare terrain: ride height on each, worst speed dip
--   wall     flat out into a wall: lowest up and highest bounce after
--   parked   nobody in it, left on a 20-degree terrain slope facing up it and across it: creep
-- Everything runs at once, one lane each, so a whole pass takes about a minute of physics.
--
-- A second view, "vehicle_roads", then builds a real map and drives each kind along its longest road
-- and on through the junction at the end: how much of the route it covers, how far it wanders from
-- the centre line, how much of it is spent airborne, and whether it stops short. It runs last,
-- because building a map clears the terrain the course above was measured on.
-- static-check: globals VEHICLE_PROBE_SPAWN, VEHICLE_PROBE_KINDS, VEHICLE_PROBE_TELEMETRY, VEHICLE_PROBE_TESTS, VEHICLE_PROBE_EXPECT, VEHICLE_PROBE_CONCURRENCY

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local VehicleService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("VehicleService"))

-- A chunk glued in front of this file can set VEHICLE_PROBE_SPAWN(folder, position, kind) and
-- VEHICLE_PROBE_KINDS to measure vehicles built some other way (a draft) on the same course.
local SPAWN = VEHICLE_PROBE_SPAWN or function(folder, position, kind)
	return VehicleService.Create(folder, position, 0, kind)
end

local KINDS = VEHICLE_PROBE_KINDS or { "car", "bike" }
-- A draft spawner may file each chassis's latest step telemetry here (lean, grounded wheels).
local TELEMETRY = VEHICLE_PROBE_TELEMETRY or {}
-- Optional: kind -> list of test-name prefixes to run; label -> function(result) -> ok, why for
-- planted faults; and how many tests may run at once (too many and physics falls behind).
local TESTS = VEHICLE_PROBE_TESTS or {}
local EXPECT = VEHICLE_PROBE_EXPECT or {}
local MAX_CONCURRENT = VEHICLE_PROBE_CONCURRENCY or 12
-- The map the road drive builds and drives (a fixed seed, so the same roads every run).
local ROAD_MAP = "SahurSprings"
local ROAD_SEED = 7
local GRADES = { 10, 20, 30, 40, 50 }
local SIDES = { 15, 25, 35 }
local KERBS = { 0.5, 1, 1.5, 2.5 }

local ORIGIN = Vector3.new(-6000, 600, -6000)
-- The default lane width. A test that builds something wider asks for its own width (the third
-- argument to test()), which is the right lever: widening this instead pushed the far lanes past
-- the limit where terrain can be written at all, and the terrain tests there measured nothing.
local LANE_SPACING = 120
local MAX_SLAB = 2000 -- a part can't be longer than 2048 on any axis
local GREY = Color3.fromRGB(120, 120, 128)
local GREEN = Color3.fromRGB(96, 150, 96)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function slab(folder, size, cframe, color)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color or GREY
	part.Material = Enum.Material.Concrete
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = folder
	return part
end

-- A flat strip with its top surface at `top`, starting at z0 and running toward -Z (a vehicle's
-- front is its own -Z, and yaw 0 points it that way).
local function strip(folder, x, top, z0, length, width, color)
	return slab(folder, Vector3.new(width or 40, 4, length), CFrame.new(x, top - 2, z0 - length / 2), color)
end

-- A strip longer than one part can be, laid as butted slabs.
local function longStrip(folder, x, top, z0, length, width)
	local laid = 0
	while laid < length do
		local piece = math.min(MAX_SLAB, length - laid)
		strip(folder, x, top, z0 - laid, piece, width)
		laid += piece
	end
end

-- Terrain with its top face on `cframe`'s plane (the block hangs below it).
local function terrainSlab(cframe, width, length, material)
	workspace.Terrain:FillBlock(cframe * CFrame.new(0, -4, 0), Vector3.new(width, 8, length), material or Enum.Material.Grass)
end

-- Where the terrain's surface actually is (a filled block's surface doesn't sit exactly on the
-- block's top face).
local function terrainTopAt(x, z, fromY, folder)
	-- Excluding the lane's own parts rather than including Terrain. The Include version missed here
	-- because these lanes sit at -6000, far outside any map's terrain, so the ray found nothing and
	-- fell back to the lane height -- which read 2 studs low, since FillBlock's surface sits about
	-- that far above the block it was given. (Including Terrain does work where terrain exists:
	-- MapGenerator.GroundHeightAt does exactly that, and maps build at the right height.) Excluding
	-- the lane instead measures whatever is actually under the wheels, terrain or slab.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { folder }
	local hit = workspace:Raycast(Vector3.new(x, fromY + 40, z), Vector3.new(0, -120, 0), params)
	if not hit then
		note(string.format("terrain height at %.0f, %.0f: nothing under the ray (falling back to %.0f)", x, z, fromY))
	end
	return hit and hit.Position.Y or fromY
end

local function lean(chassis)
	local telemetry = TELEMETRY[chassis]
	return telemetry and telemetry.lean and math.abs(math.deg(telemetry.lean)) or 0
end

local function horizontalSpeed(part)
	local v = part.AssemblyLinearVelocity
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

local function rollDegrees(part)
	return math.deg(math.asin(math.clamp(part.CFrame.RightVector.Y, -1, 1)))
end

local function drive(seat, throttle, steer)
	seat.ThrottleFloat = throttle
	seat.SteerFloat = steer
	seat.Throttle = throttle > 0.01 and 1 or (throttle < -0.01 and -1 or 0)
	seat.Steer = steer > 0.01 and 1 or (steer < -0.01 and -1 or 0)
end

return {
	{
		name = "vehicle_probe",
		settle = 1,
		hold = 1,
		setup = function(folder, camera)
			if not RunService:IsRunning() then
				RunService:Run()
			end
			task.wait(3)
			note(string.format("gravity %.1f", workspace.Gravity))

			local template
			for attempt = 1, 3 do
				local ok, model = pcall(function()
					return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
				end)
				if ok and model then
					template = model
					break
				end
				note("rig attempt " .. attempt .. " failed: " .. tostring(model))
				task.wait(2)
			end
			if not template then
				note("no rig, giving up")
				return
			end

			if not VEHICLE_PROBE_SPAWN then
				VehicleService.Start()
			end

			local lane = 0
			local laneCursor = ORIGIN.X
			local results = {}
			local labels = {}
			local running = 0
			local currentKind = nil

			-- Physics health. Forces are worked out once a frame, so when the server falls behind
			-- (too many lanes at once) the numbers stop meaning anything. Frame times are recorded
			-- for the whole run and for each test's own window, and a slow window flags its result.
			local frames, slowFrames, worstDt, totalDt = 0, 0, 0, 0
			local healthConnection = RunService.Stepped:Connect(function(_, dt)
				frames += 1
				totalDt += dt
				worstDt = math.max(worstDt, dt)
				if dt > 1 / 40 then
					slowFrames += 1
				end
			end)

			local function spawnDriven(kind, x, top, z, lift, empty)
				local model = SPAWN(folder, Vector3.new(x, top + (lift or 0), z), kind)
				task.wait(1.2)
				local seat = model:FindFirstChildOfClass("VehicleSeat")
				local chassis = model:FindFirstChild("Chassis")
				if empty then
					return model, seat, chassis, false
				end
				local rig = template:Clone()
				rig:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
				rig.Parent = folder
				local humanoid = rig:FindFirstChildOfClass("Humanoid")
				task.wait(0.2)
				seat:Sit(humanoid)
				for _ = 1, 40 do
					if seat.Occupant == humanoid then
						break
					end
					task.wait(0.05)
				end
				task.wait(0.6)
				return model, seat, chassis, seat.Occupant == humanoid
			end

			-- Runs `body` in its own lane (`width` wide, LANE_SPACING by default) and files its
			-- one-line result under `label`. At most MAX_CONCURRENT run at once; a kind listed in
			-- TESTS runs only the tests whose names start with one of its entries.
			local function test(label, body, width)
				local wanted = currentKind and TESTS[currentKind]
				if wanted then
					local testName = string.sub(label, #currentKind + 2)
					local match = false
					for _, prefix in ipairs(wanted) do
						if string.sub(testName, 1, #prefix) == prefix then
							match = true
							break
						end
					end
					if not match then
						return
					end
				end
				while running >= MAX_CONCURRENT do
					task.wait(0.25)
				end
				lane += 1
				local myLane = lane
				labels[myLane] = label
				width = width or LANE_SPACING
				local x = laneCursor + width / 2
				laneCursor += width
				running += 1
				task.spawn(function()
					local framesAt, slowAt = frames, slowFrames
					local ok, text = pcall(body, x)
					local seen = frames - framesAt
					local slowShare = seen > 0 and (slowFrames - slowAt) / seen or 1
					local flag = slowShare > 0.1
						and string.format(" [UNRELIABLE: %d%% of its frames were slower than 40 fps]", math.floor(slowShare * 100 + 0.5)) or ""
					results[myLane] = label .. ": " .. (ok and tostring(text) or ("ERROR " .. tostring(text))) .. flag
					running -= 1
				end)
			end

			for _, kind in ipairs(KINDS) do
				currentKind = kind
				-- Straight line: accelerate to a plateau, coast to a stop, then again braking.
				test(kind .. " flat", function(x)
					longStrip(folder, x, ORIGIN.Y, ORIGIN.Z + 30, 5400, 60)
					local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
					if not seated then
						return "rig never sat"
					end
					local samples = {}
					local t0 = os.clock()
					local best, bestAt = 0, t0
					local nextDebug = 1
					drive(seat, 1, 0)
					while os.clock() - t0 < 25 do
						local speed = horizontalSpeed(chassis)
						local telemetry = TELEMETRY[chassis]
						if telemetry and telemetry.debug and os.clock() - t0 > nextDebug then
							speed = horizontalSpeed(chassis)
							nextDebug += 2
							note(string.format("debug %s t%.0f v%.1f: %s", kind, os.clock() - t0, speed, telemetry.debug))
						end
						table.insert(samples, { os.clock() - t0, speed })
						if speed > best + 0.25 then
							best, bestAt = speed, os.clock()
						end
						if os.clock() - bestAt > 2 and os.clock() - t0 > 4 then
							break
						end
						RunService.Heartbeat:Wait()
					end
					local t60, t95 = nil, nil
					for _, sample in ipairs(samples) do
						if not t60 and sample[2] >= 60 then
							t60 = sample[1]
						end
						if not t95 and sample[2] >= best * 0.95 then
							t95 = sample[1]
						end
					end

					local function stopDistance(throttle)
						local from = chassis.Position
						local began = os.clock()
						drive(seat, throttle, 0)
						while horizontalSpeed(chassis) > 1 and os.clock() - began < 15 do
							RunService.Heartbeat:Wait()
						end
						drive(seat, 0, 0)
						local flat = chassis.Position - from
						return Vector3.new(flat.X, 0, flat.Z).Magnitude, os.clock() - began
					end

					local coast, coastTime = stopDistance(0)
					-- Back up to speed for the braking run.
					drive(seat, 1, 0)
					local regain = os.clock()
					while horizontalSpeed(chassis) < best * 0.9 and os.clock() - regain < 20 do
						RunService.Heartbeat:Wait()
					end
					local startSpeed = horizontalSpeed(chassis)
					local braked, brakeTime = stopDistance(-1)
					return string.format("top %.1f | t60 %s | t95 %s | coast %.0f studs %.1fs | brake from %.0f: %.0f studs %.1fs",
						best, t60 and string.format("%.2fs", t60) or "never", t95 and string.format("%.2fs", t95) or "?",
						coast, coastTime, startSpeed, braked, brakeTime)
				end)

				-- Full lock once up to speed.
				test(kind .. " lock", function(x)
					slab(folder, Vector3.new(480, 4, 900), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 420))
					local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
					if not seated then
						return "rig never sat"
					end
					drive(seat, 1, 0)
					task.wait(3.5)
					local entry = horizontalSpeed(chassis)
					drive(seat, 1, 1)
					local began = os.clock()
					local peakRoll, peakLean, lowestUp, peakSlip = 0, 0, 1, 0
					local radii = {}
					while os.clock() - began < 5 do
						peakRoll = math.max(peakRoll, math.abs(rollDegrees(chassis)))
						peakLean = math.max(peakLean, lean(chassis))
						lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
						local velocity = chassis.AssemblyLinearVelocity
						local flat = Vector3.new(velocity.X, 0, velocity.Z)
						local look = chassis.CFrame.LookVector
						local heading = Vector3.new(look.X, 0, look.Z)
						if flat.Magnitude > 5 and heading.Magnitude > 0.1 then
							-- Slip angle: how far the direction of travel is from where the body points.
							peakSlip = math.max(peakSlip, math.deg(math.acos(math.clamp(flat.Unit:Dot(heading.Unit), -1, 1))))
						end
						local yawRate = math.abs(chassis.AssemblyAngularVelocity.Y)
						if yawRate > 0.05 and os.clock() - began > 0.8 then
							table.insert(radii, flat.Magnitude / yawRate)
						end
						RunService.Heartbeat:Wait()
					end
					local exit = horizontalSpeed(chassis)
					drive(seat, 0, 0)
					-- The median of the turn, not its tightest instant: a spin reads as a tiny radius.
					table.sort(radii)
					local median = #radii > 0 and radii[math.ceil(#radii / 2)] or nil
					local verdict = lowestUp < 0.2 and "ROLLED" or (peakSlip > 45 and "SPUN OUT" or "held the line")
					return string.format("entry %.0f exit %.0f | median radius %s | peak slip %.0f deg | peak roll %.1f deg | lean %.0f | lowest up %.2f | %s",
						entry, exit, median and string.format("%.1f", median) or "no turn", peakSlip, peakRoll, peakLean, lowestUp, verdict)
				end, 760)

				-- Full lock held at a town-corner speed.
				test(kind .. " turn 40", function(x)
					slab(folder, Vector3.new(280, 4, 400), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 170))
					local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
					if not seated then
						return "rig never sat"
					end
					drive(seat, 1, 0)
					local began = os.clock()
					while horizontalSpeed(chassis) < 40 and os.clock() - began < 8 do
						RunService.Heartbeat:Wait()
					end
					began = os.clock()
					local peakRoll, peakLean, lowestUp, radii, speeds = 0, 0, 1, 0, 0
					local samples = 0
					local nextDebug = 1
					local leftPad = false
					while os.clock() - began < 5 do
						local speed = horizontalSpeed(chassis)
						drive(seat, speed < 40 and 0.8 or 0, 1)
						local telemetry = TELEMETRY[chassis]
						if telemetry and telemetry.debug and os.clock() - began > nextDebug then
							nextDebug += 1.5
							note(string.format("debug %s turn t%.0f v%.1f: %s", kind, os.clock() - began, speed, telemetry.debug))
						end
						-- Off the pad, everything after is a measurement of falling. Say so and stop,
						-- rather than average a plummet into a turn radius.
						if chassis.Position.Y < ORIGIN.Y - 6 then
							leftPad = true
							break
						end
						peakRoll = math.max(peakRoll, math.abs(rollDegrees(chassis)))
						peakLean = math.max(peakLean, lean(chassis))
						lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
						local yawRate = math.abs(chassis.AssemblyAngularVelocity.Y)
						if os.clock() - began > 1.5 and yawRate > 0.05 then
							radii += speed / yawRate
							speeds += speed
							samples += 1
						end
						RunService.Heartbeat:Wait()
					end
					drive(seat, 0, 0)
					return string.format("radius %s at %.0f | peak roll %.1f deg | lean %.0f | lowest up %.2f | %s",
						samples > 0 and string.format("%.1f", radii / samples) or "no turn", samples > 0 and speeds / samples or 0,
						peakRoll, peakLean, lowestUp,
						leftPad and "LEFT THE PAD (ran wide; the numbers above are only up to that point)"
							or (lowestUp < 0.2 and "ROLLED" or "stayed up"))
				end, 560)

				-- Slalom: a flick one way and then the other at 50, just under a second each.
				test(kind .. " slalom", function(x)
					longStrip(folder, x, ORIGIN.Y, ORIGIN.Z + 30, 1400, 150)
					local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
					if not seated then
						return "rig never sat"
					end
					drive(seat, 1, 0)
					local began = os.clock()
					while horizontalSpeed(chassis) < 50 and os.clock() - began < 8 do
						RunService.Heartbeat:Wait()
					end
					local entry = horizontalSpeed(chassis)
					local startX = chassis.Position.X
					local peakRoll, peakLean, lowestUp, swingLow, swingHigh = 0, 0, 1, 0, 0
					for flick = 1, 6 do
						local flickStart = os.clock()
						-- The first flick is half as long, so the weave stays centred on the lane.
						while os.clock() - flickStart < (flick == 1 and 0.45 or 0.9) do
							drive(seat, horizontalSpeed(chassis) < 50 and 1 or 0.3, flick % 2 == 1 and 0.6 or -0.6)
							peakRoll = math.max(peakRoll, math.abs(rollDegrees(chassis)))
							peakLean = math.max(peakLean, lean(chassis))
							lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
							local offset = chassis.Position.X - startX
							swingLow, swingHigh = math.min(swingLow, offset), math.max(swingHigh, offset)
							RunService.Heartbeat:Wait()
						end
					end
					drive(seat, 0, 0)
					return string.format("in %.0f out %.0f | swing %.0f studs | peak roll %.1f deg | lean %.0f | lowest up %.2f | %s",
						entry, horizontalSpeed(chassis), swingHigh - swingLow, peakRoll, peakLean, lowestUp,
						lowestUp < 0.2 and "ROLLED" or "stayed up")
				end, 180)

				-- Terrain: a grass climb from a run-up.
				for _, grade in ipairs({ 20, 30, 40 }) do
					test(string.format("%s terrain grade %d", kind, grade), function(x)
						local runUp, length = 200, 150
						terrainSlab(CFrame.new(x, ORIGIN.Y, ORIGIN.Z + 30 - (runUp + 30) / 2), 44, runUp + 30)
						local a = math.rad(grade)
						local bottom = Vector3.new(x, ORIGIN.Y, ORIGIN.Z - runUp)
						local along = Vector3.new(0, math.sin(a), -math.cos(a))
						terrainSlab(CFrame.new(bottom + along * (length / 2)) * CFrame.Angles(a, 0, 0), 44, length + 8)
						local topPoint = bottom + along * length
						terrainSlab(CFrame.new(x, topPoint.Y, topPoint.Z - 40), 44, 80)
						local surface = terrainTopAt(x, ORIGIN.Z, ORIGIN.Y, folder)
						topPoint += Vector3.new(0, surface - ORIGIN.Y, 0)
						local _, seat, chassis, seated = spawnDriven(kind, x, surface, ORIGIN.Z, 0.5)
						if not seated then
							return "rig never sat"
						end
						drive(seat, 1, 0)
						local began = os.clock()
						local highest, lowestUp, made = ORIGIN.Y, 1, false
						while os.clock() - began < 20 do
							highest = math.max(highest, chassis.Position.Y)
							lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
							if chassis.Position.Y >= topPoint.Y and chassis.Position.Z < topPoint.Z + 2 then
								made = true
								break
							end
							RunService.Heartbeat:Wait()
						end
						drive(seat, 0, 0)
						return string.format("%s in %.1fs | reached %.0f of %.0f rise | lowest up %.2f", made and "CLIMBED" or "failed",
							os.clock() - began, highest - ORIGIN.Y, topPoint.Y - ORIGIN.Y, lowestUp)
					end)
				end

				-- Terrain: across a grass side slope.
				test(kind .. " terrain side 25", function(x)
					local b = math.rad(25)
					terrainSlab(CFrame.new(x, ORIGIN.Y, ORIGIN.Z - 320) * CFrame.Angles(0, 0, b), 80, 700)
					local _, seat, chassis, seated = spawnDriven(kind, x, terrainTopAt(x, ORIGIN.Z, ORIGIN.Y, folder), ORIGIN.Z, 2)
					if not seated then
						return "rig never sat"
					end
					local startX = chassis.Position.X
					drive(seat, 1, 0)
					local began = os.clock()
					local peakRoll, lowestUp = 0, 1
					while os.clock() - began < 7 do
						peakRoll = math.max(peakRoll, math.abs(rollDegrees(chassis)))
						lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
						RunService.Heartbeat:Wait()
					end
					drive(seat, 0, 0)
					return string.format("speed %.0f | peak roll %.1f deg | lowest up %.2f | slid %.1f studs sideways | %s",
						horizontalSpeed(chassis), peakRoll, lowestUp, chassis.Position.X - startX, lowestUp < 0.2 and "ROLLED" or "stayed up")
				end)

				-- Terrain: a field of bumps, flat out.
				test(kind .. " terrain bumps", function(x)
					terrainSlab(CFrame.new(x, ORIGIN.Y, ORIGIN.Z - 350), 60, 800)
					for index = 1, 40 do
						local z = ORIGIN.Z - 60 - index * 16
						local offset = ((index * 7) % 5 - 2) * 3
						workspace.Terrain:FillBall(Vector3.new(x + offset, ORIGIN.Y - 2, z), 3.5 + (index % 3) * 0.5, Enum.Material.Ground)
					end
					local _, seat, chassis, seated = spawnDriven(kind, x, terrainTopAt(x, ORIGIN.Z, ORIGIN.Y, folder), ORIGIN.Z, 0.5)
					if not seated then
						return "rig never sat"
					end
					drive(seat, 1, 0)
					local began = os.clock()
					local peakRoll, lowestUp, peakRise, slowest = 0, 1, 0, math.huge
					local entered = false
					while os.clock() - began < 14 and chassis.Position.Z > ORIGIN.Z - 720 do
						if chassis.Position.Z < ORIGIN.Z - 80 then
							entered = true
							slowest = math.min(slowest, horizontalSpeed(chassis))
							peakRoll = math.max(peakRoll, math.abs(rollDegrees(chassis)))
							lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
							peakRise = math.max(peakRise, chassis.AssemblyLinearVelocity.Y)
						end
						RunService.Heartbeat:Wait()
					end
					drive(seat, 0, 0)
					return string.format("%s | slowest %.0f | peak roll %.1f deg | highest hop %.0f studs/s | lowest up %.2f | %s",
						entered and "crossed" or "never reached", entered and slowest or 0, peakRoll, peakRise, lowestUp,
						lowestUp < 0.2 and "ROLLED" or "stayed up")
				end)

				-- Road: asphalt that doesn't collide over terrain, a bridge deck, bare terrain.
				test(kind .. " road", function(x)
					local deckStart, deckEnd = ORIGIN.Z - 300, ORIGIN.Z - 420
					terrainSlab(CFrame.new(x, ORIGIN.Y, (ORIGIN.Z + 30 + deckStart) / 2), 60, ORIGIN.Z + 30 - deckStart)
					terrainSlab(CFrame.new(x, ORIGIN.Y, (deckEnd + ORIGIN.Z - 900) / 2), 60, deckEnd - (ORIGIN.Z - 900))
					-- Laid on the terrain's real surface, as the map lays its roads and decks.
					local ground = terrainTopAt(x, ORIGIN.Z - 100, ORIGIN.Y, folder)
					local deck = slab(folder, Vector3.new(30, 2, deckStart - deckEnd), CFrame.new(x, ground - 1, (deckStart + deckEnd) / 2))
					deck.Name = "BridgeDeck"
					local asphaltLength = ORIGIN.Z + 30 - (deckEnd - 20)
					local asphalt = slab(folder, Vector3.new(24, 0.4, asphaltLength), CFrame.new(x, ground + 0.2, ORIGIN.Z + 30 - asphaltLength / 2))
					asphalt.CanCollide = false
					asphalt.Material = Enum.Material.Asphalt
					for _, side in ipairs({ -1, 1 }) do
						local kerb = slab(folder, Vector3.new(0.8, 0.56, asphaltLength), CFrame.new(x + side * 12.4, ground + 0.22, ORIGIN.Z + 30 - asphaltLength / 2))
						kerb.CanCollide = false
					end
					local _, seat, chassis, seated = spawnDriven(kind, x, ground + 0.4, ORIGIN.Z, 0.5)
					if not seated then
						return "rig never sat"
					end
					drive(seat, 1, 0)
					local began = os.clock()
					local heights = { asphalt = { 0, 0 }, deck = { 0, 0 }, terrain = { 0, 0 } }
					local worstDip, lowestUp, previousSpeed = 0, 1, nil
					while os.clock() - began < 14 and chassis.Position.Z > ORIGIN.Z - 860 do
						local z = chassis.Position.Z
						local bucket = (z < ORIGIN.Z - 120 and z > deckStart + 30) and "asphalt"
							or ((z < deckStart - 20 and z > deckEnd + 20) and "deck")
							or ((z < deckEnd - 60) and "terrain") or nil
						if bucket then
							heights[bucket][1] += chassis.Position.Y - ground
							heights[bucket][2] += 1
						end
						local speed = horizontalSpeed(chassis)
						if previousSpeed and z < deckStart + 40 then
							worstDip = math.max(worstDip, previousSpeed - speed)
						end
						previousSpeed = speed
						lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
						RunService.Heartbeat:Wait()
					end
					drive(seat, 0, 0)
					local function average(bucket)
						local entry = heights[bucket]
						return entry[2] > 0 and string.format("%.2f", entry[1] / entry[2]) or "-"
					end
					return string.format("chassis above the ground: on asphalt %s, deck %s, bare terrain %s | worst frame speed drop %.1f | lowest up %.2f",
						average("asphalt"), average("deck"), average("terrain"), worstDip, lowestUp)
				end)

				-- Flat out into a wall.
				test(kind .. " wall", function(x)
					strip(folder, x, ORIGIN.Y, ORIGIN.Z + 30, 560, 80)
					slab(folder, Vector3.new(80, 24, 4), CFrame.new(x, ORIGIN.Y + 12, ORIGIN.Z - 460))
					local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
					if not seated then
						return "rig never sat"
					end
					drive(seat, 1, 0)
					local began = os.clock()
					local impact = nil
					while os.clock() - began < 12 and chassis.Position.Z > ORIGIN.Z - 440 do
						impact = horizontalSpeed(chassis)
						RunService.Heartbeat:Wait()
					end
					local after = os.clock()
					local lowestUp, highestRise, peakY = 1, 0, chassis.Position.Y
					while os.clock() - after < 3 do
						lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
						highestRise = math.max(highestRise, chassis.AssemblyLinearVelocity.Y)
						peakY = math.max(peakY, chassis.Position.Y)
						RunService.Heartbeat:Wait()
					end
					drive(seat, 0, 0)
					local verdict = chassis.Position.Y < ORIGIN.Y - 5 and "FELL off the lane" or (lowestUp < 0.2 and "FLIPPED" or "upright")
					return string.format("hit at %.0f | bounced up at %.0f studs/s, peak %.1f above the lane | lowest up %.2f | %s",
						impact or 0, highestRise, peakY - ORIGIN.Y, lowestUp, verdict)
				end)

				-- Parked on a slope with nobody in it.
				for _, across in ipairs({ false, true }) do
					test(string.format("%s parked 20 %s", kind, across and "across" or "up"), function(x)
						local a = math.rad(20)
						local centre = Vector3.new(x, ORIGIN.Y, ORIGIN.Z - 60)
						local tilt = across and CFrame.Angles(0, 0, a) or CFrame.Angles(a, 0, 0)
						terrainSlab(CFrame.new(centre) * tilt, 90, 120)
						local model, _, chassis = spawnDriven(kind, x, terrainTopAt(x, ORIGIN.Z - 60, ORIGIN.Y, folder), ORIGIN.Z - 60, 2, true)
						task.wait(2)
						local settled = chassis.Position
						task.wait(6)
						local crept = (chassis.Position - settled).Magnitude
						return string.format("crept %.2f studs in 6s | up %.2f | %s", crept, chassis.CFrame.UpVector.Y,
							model.Parent and (chassis.CFrame.UpVector.Y < 0.2 and "FELL OVER" or "stood") or "gone")
					end)
				end

				-- Climbing: a run-up, a ramp, and a landing at the top.
				for _, grade in ipairs(GRADES) do
					test(string.format("%s grade %d", kind, grade), function(x)
						local runUp, length = 220, 150
						strip(folder, x, ORIGIN.Y, ORIGIN.Z + 30, runUp + 30)
						local a = math.rad(grade)
						local bottom = Vector3.new(x, ORIGIN.Y, ORIGIN.Z - runUp)
						local along = Vector3.new(0, math.sin(a), -math.cos(a))
						local up = Vector3.new(0, math.cos(a), math.sin(a))
						slab(folder, Vector3.new(40, 4, length), CFrame.new(bottom + along * (length / 2) - up * 2) * CFrame.Angles(a, 0, 0), GREEN)
						local topPoint = bottom + along * length
						strip(folder, x, topPoint.Y, topPoint.Z, 80)
						local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
						if not seated then
							return "rig never sat"
						end
						drive(seat, 1, 0)
						local began = os.clock()
						local highest, lowestUp, made = ORIGIN.Y, 1, false
						while os.clock() - began < 20 do
							highest = math.max(highest, chassis.Position.Y)
							lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
							if chassis.Position.Y >= topPoint.Y and chassis.Position.Z < topPoint.Z + 2 then
								made = true
								break
							end
							RunService.Heartbeat:Wait()
						end
						drive(seat, 0, 0)
						return string.format("%s | reached %.0f of %.0f rise | lowest up %.2f", made and "CLIMBED" or "failed",
							highest - ORIGIN.Y, topPoint.Y - ORIGIN.Y, lowestUp)
					end)
				end

				-- Across a side slope.
				for _, side in ipairs(SIDES) do
					test(string.format("%s side %d", kind, side), function(x)
						local b = math.rad(side)
						slab(folder, Vector3.new(70, 4, 700), CFrame.new(x, ORIGIN.Y, ORIGIN.Z - 320) * CFrame.Angles(0, 0, b) * CFrame.new(0, -2, 0), GREEN)
						local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z, 2)
						if not seated then
							return "rig never sat"
						end
						local startX = chassis.Position.X
						drive(seat, 1, 0)
						local began = os.clock()
						local peakRoll, lowestUp = 0, 1
						while os.clock() - began < 7 do
							peakRoll = math.max(peakRoll, math.abs(rollDegrees(chassis)))
							lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
							RunService.Heartbeat:Wait()
						end
						drive(seat, 0, 0)
						return string.format("speed %.0f | peak roll %.1f deg | lowest up %.2f | slid %.1f studs sideways | %s",
							horizontalSpeed(chassis), peakRoll, lowestUp, chassis.Position.X - startX, lowestUp < 0.2 and "ROLLED" or "stayed up")
					end)
				end

				-- Off a ledge.
				test(kind .. " drop", function(x)
					local runUp = 260
					strip(folder, x, ORIGIN.Y, ORIGIN.Z + 30, runUp + 30)
					strip(folder, x, ORIGIN.Y - 12, ORIGIN.Z - runUp, 700)
					local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
					if not seated then
						return "rig never sat"
					end
					drive(seat, 1, 0)
					local began = os.clock()
					while chassis.Position.Z > ORIGIN.Z - runUp and os.clock() - began < 15 do
						RunService.Heartbeat:Wait()
					end
					local offAt = horizontalSpeed(chassis)
					local watch = os.clock()
					local lowestUp = 1
					while os.clock() - watch < 3.5 do
						lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
						RunService.Heartbeat:Wait()
					end
					drive(seat, 0, 0)
					return string.format("off the edge at %.0f | lowest up %.2f after | speed 3.5s later %.0f | %s",
						offAt, lowestUp, horizontalSpeed(chassis), lowestUp < 0.2 and "ROLLED" or "landed")
				end)

				-- Kerbs.
				for _, height in ipairs(KERBS) do
					test(string.format("%s kerb %.1f", kind, height), function(x)
						local runUp = 40
						-- Wide strips on purpose: at 40 a bike balancing its way down the run-up drifted
						-- off the side and "failed" a kerb it had never reached. The lane is widened to
						-- match (see the width passed to test below).
						strip(folder, x, ORIGIN.Y, ORIGIN.Z + 30, runUp + 30, 110)
						strip(folder, x, ORIGIN.Y + height, ORIGIN.Z - runUp, 260, 110, GREEN)
						local _, seat, chassis, seated = spawnDriven(kind, x, ORIGIN.Y, ORIGIN.Z)
						if not seated then
							return "rig never sat"
						end
						drive(seat, 1, 0)
						local began = os.clock()
						local made, speedAtKerb = false, nil
						-- "stuck, never reached the kerb" says nothing about why. Keep how far it got
						-- and how fast it ever went, so a vehicle that never moved can be told from
						-- one that arrived and was stopped by the step.
						local startZ, furthest, fastest, lowestUp = chassis.Position.Z, 0, 0, 1
						while os.clock() - began < 10 do
							furthest = math.max(furthest, startZ - chassis.Position.Z)
							fastest = math.max(fastest, horizontalSpeed(chassis))
							lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
							if not speedAtKerb and chassis.Position.Z < ORIGIN.Z - runUp + 6 then
								speedAtKerb = horizontalSpeed(chassis)
							end
							if chassis.Position.Z < ORIGIN.Z - runUp - 30 and chassis.Position.Y > ORIGIN.Y + height then
								made = true
								break
							end
							RunService.Heartbeat:Wait()
						end
						drive(seat, 0, 0)
						local fell = chassis.Position.Y < ORIGIN.Y - 6
						return string.format("%s | speed at kerb %s | travelled %.0f studs of a %d run-up, fastest %.0f, lowest up %.2f%s",
							made and "MOUNTED" or "stuck",
							speedAtKerb and string.format("%.0f", speedAtKerb) or "never reached",
							furthest, runUp + 30, fastest, lowestUp,
							fell and " | FELL OFF THE STRIP (so this says nothing about the kerb)" or "")
					end, 180)
				end
			end

			while running > 0 do
				task.wait(0.5)
			end
			healthConnection:Disconnect()
			for index = 1, lane do
				note(string.format("%02d %s", index, tostring(results[index])))
			end
			note(string.format("probe health: %d frames, mean %.1f ms, worst %.0f ms, %.1f%% slower than 40 fps", frames,
				totalDt / math.max(1, frames) * 1000, worstDt * 1000, slowFrames / math.max(1, frames) * 100))
			-- A result can read like a measurement and be nothing of the sort: a vehicle that never
			-- moved reports a top speed of 0 and a wall hit at 0, which is a dead run, not a slow car.
			-- Say so here rather than leave it to be read past.
			local dead = {}
			for index = 1, lane do
				local text = tostring(results[index] or "")
				local why = nil
				if EXPECT[labels[index]] then
					-- A planted fault is meant to look broken; its own self-check judges it.
					why = nil
				elseif text:find("ERROR") then
					why = "errored"
				elseif text:find("rig never sat") then
					why = "the rig never sat in it"
				elseif text:find("top 0%.0") or text:find("hit at 0 ") then
					why = "it never moved"
				elseif text:find("UNRELIABLE") then
					why = "its frames were too slow to trust"
				end
				if why then
					table.insert(dead, string.format("%s (%s)", labels[index] or index, why))
				end
			end
			if #dead > 0 then
				note(string.format("PROBE PROBLEM: %d of %d results are not measurements: %s", #dead, lane,
					table.concat(dead, ", ")))
			else
				note(string.format("probe results: all %d are usable measurements", lane))
			end
			-- Planted faults: a spawner can register what a deliberately broken vehicle must report,
			-- so a test that can't fail shows up here instead of passing quietly.
			local checked = 0
			for index = 1, lane do
				local expect = EXPECT[labels[index]]
				if expect then
					checked += 1
					local ok, why = expect(results[index] or "")
					note(string.format("self-check %s: %s (%s)", labels[index], ok and "PASS" or "FAIL", tostring(why)))
				end
			end
			if next(EXPECT) and checked == 0 then
				note("self-check: FAIL (planted faults were registered but none of their tests ran)")
			end
			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-80, 120, 160), ORIGIN + Vector3.new(lane * LANE_SPACING / 2, 0, -200))
		end,
	},
	-- The course above is built here and is the same every run, which is what makes it comparable.
	-- It is not the game: this view drives the real road network a map generates, so a vehicle that
	-- only works on purpose-built lanes is caught. It runs last because building a map clears terrain.
	{
		name = "vehicle_roads",
		settle = 1,
		hold = 1,
		setup = function(folder, camera)
			if not RunService:IsRunning() then
				RunService:Run()
			end
			task.wait(2)
			local modules = ServerScriptService:WaitForChild("Modules")
			math.randomseed(ROAD_SEED)
			local built, info = pcall(require(modules:WaitForChild("MapGenerator")).Build, ROAD_MAP)
			if not built or type(info) ~= "table" or not info.roads then
				note("road drive: no map to drive on (" .. tostring(info) .. ")")
				return
			end
			-- The service is started even when a draft spawner is in charge of the COURSE, because the
			-- map parks its own vehicles through the live service and they have to be stepped to stand
			-- up: their wheels do not collide (only the chassis hull does), so a vehicle nobody steps
			-- settles onto its hull and reads as buried to its axles. That is a measurement of a loop
			-- that was never running, not of where the vehicle was parked.
			VehicleService.Start()
			task.wait(1.5)
			-- A generated map parks its own vehicles along these roads. They are not what is being
			-- measured here, and a vehicle that stops short because it drove into a parked one would
			-- read as a road defect, so the road is cleared first.
			local parked = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Vehicles")
			if parked then
				-- Before clearing them: how many are actually standing on the ground? A quarter of them
				-- were measured hanging off a corner, because they are parked on the graded bank beside
				-- a road and then held level over it. This is the number to beat.
				local vehicles, floating, worst = 0, 0, 0
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { parked }
				params.IgnoreWater = true
				for _, vehicle in ipairs(parked:GetChildren()) do
					local ok, box, size = pcall(function()
						local b, s = vehicle:GetBoundingBox()
						return b, s
					end)
					if ok and box then
						vehicles += 1
						local gap = 0
						for _, corner in ipairs({ Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
							Vector3.new(1, -1, -1), Vector3.new(-1, -1, -1) }) do
							local at = box:PointToWorldSpace(corner * size / 2)
							local hit = workspace:Raycast(at + Vector3.new(0, 1, 0), Vector3.new(0, -40, 0), params)
							gap = math.max(gap, hit and (at.Y - hit.Position.Y) or 0)
						end
						worst = math.max(worst, gap)
						if gap > 1.0 then
							floating += 1
						end
					end
				end
				-- The bounding box includes the tyres, so that number alone cannot tell a car sitting on
				-- its wheels from one hanging in the air. Measure the two separately: the TYRES should
				-- touch (a gap near zero) and the BODY should stand off by the design's ride height.
				local tyreGap, bodyGap, buried, samples = 0, 0, 0, 0
				for _, vehicle in ipairs(parked:GetChildren()) do
					local lowTyre, lowBody = math.huge, math.huge
					for _, part in ipairs(vehicle:GetDescendants()) do
						if part:IsA("BasePart") and part.Transparency < 0.95 then
							local bottom = part.Position.Y - part.Size.Y / 2
							local wheelish = string.find(part.Name, "Tyre", 1, true) or string.find(part.Name, "Wheel", 1, true)
							if wheelish then
								lowTyre = math.min(lowTyre, bottom)
							else
								lowBody = math.min(lowBody, bottom)
							end
						end
					end
					local at = vehicle:GetPivot().Position
					local hit = workspace:Raycast(at + Vector3.new(0, 8, 0), Vector3.new(0, -60, 0), params)
					if hit and lowTyre < math.huge and lowBody < math.huge then
						samples += 1
						tyreGap += lowTyre - hit.Position.Y
						bodyGap += lowBody - hit.Position.Y
						if lowTyre - hit.Position.Y < -0.4 then
							buried += 1
						end
					end
				end
				note(string.format("parked footing: %d of %d vehicles hang more than a stud clear at a corner (%.0f%%), worst %.2f studs | mean tyre gap %.2f (want ~0), mean body gap %.2f (the ride height), %d buried below the ground",
					floating, vehicles, vehicles > 0 and floating / vehicles * 100 or 0, worst,
					samples > 0 and tyreGap / samples or 0, samples > 0 and bodyGap / samples or 0, buried))
				parked:ClearAllChildren()
				note(string.format("road drive: cleared %d vehicles the map parked along these roads", vehicles))
			end
			task.wait(2)

			-- A route: the longest road, then on through the junction at its end into the next one,
			-- so the drive crosses a junction pad rather than stopping short of it.
			-- The longest road that carries a bridge, if the map has one, so a bridge deck is actually
			-- driven over; otherwise simply the longest.
			local longest, longestWithBridge = nil, nil
			for _, edge in ipairs(info.roads.edges) do
				-- Only edges that were given a height profile: topAt is what puts route points on the
				-- road surface, and an edge without one would break this view rather than this test.
				if type(edge.topAt) == "function" and edge.length then
					if not longest or edge.length > longest.length then
						longest = edge
					end
					if #(edge.bridges or {}) > 0 and (not longestWithBridge or edge.length > longestWithBridge.length) then
						longestWithBridge = edge
					end
				end
			end
			longest = longestWithBridge or longest
			if not longest then
				note("road drive: the map has no roads")
				return
			end
			local onward = nil
			for _, edge in ipairs(info.roads.edges) do
				if edge ~= longest and edge.length > 80 and (edge.a == longest.b or edge.b == longest.b) then
					onward = edge
					break
				end
			end
			local function pointsOf(edge, reverse)
				local out = {}
				for step = 0, math.floor(edge.length / 8) do
					local along = math.min(step * 8, edge.length)
					local p = edge.from + edge.dir * (reverse and (edge.length - along) or along)
					table.insert(out, Vector3.new(p.X, edge.topAt(p), p.Z))
				end
				return out
			end
			local route = pointsOf(longest, false)
			local bridges = #(longest.bridges or {})
			if onward and type(onward.topAt) == "function" then
				bridges += #(onward.bridges or {})
				for index, point in ipairs(pointsOf(onward, onward.b == longest.b)) do
					if index > 1 then
						table.insert(route, point)
					end
				end
			end
			local climb, fall = 0, 0
			for index = 2, #route do
				local rise = route[index].Y - route[index - 1].Y
				climb += math.max(rise, 0)
				fall += math.max(-rise, 0)
			end
			note(string.format("road route: %s seed %d, %d points over %.0f studs, %d bridge span(s), climbs %.0f and drops %.0f",
				ROAD_MAP, ROAD_SEED, #route, (#route - 1) * 8, bridges, climb, fall))

			local template
			for _ = 1, 3 do
				local ok, model = pcall(function()
					return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
				end)
				if ok and model then
					template = model
					break
				end
				task.wait(2)
			end
			if not template then
				note("road drive: no rig to sit in it")
				return
			end

			-- Distance from the road's centre line, so wandering off the carriageway is measurable.
			local function offLine(position, a, b)
				local along = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
				local length = along.Magnitude
				if length < 0.01 then
					return 0
				end
				local to = Vector3.new(position.X - a.X, 0, position.Z - a.Z)
				local t = math.clamp(to:Dot(along) / (length * length), 0, 1)
				return (to - along * t).Magnitude
			end

			local last = nil
			local function driveRoute(kind)
				local start = route[1] + Vector3.new(0, 3, 0)
				local heading = route[2] - route[1]
				heading = Vector3.new(heading.X, 0, heading.Z).Unit
				local model = SPAWN(folder, start, kind)
				model:PivotTo(CFrame.lookAt(start, start + heading))
				task.wait(1.5)
				local seat = model:FindFirstChildOfClass("VehicleSeat")
				local chassis = model:FindFirstChild("Chassis")
				if not seat or not chassis then
					return kind .. ": no seat or chassis"
				end
				local rig = template:Clone()
				rig:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
				rig.Parent = folder
				local humanoid = rig:FindFirstChildOfClass("Humanoid")
				task.wait(0.2)
				seat:Sit(humanoid)
				for _ = 1, 40 do
					if seat.Occupant == humanoid then
						break
					end
					RunService.Heartbeat:Wait()
				end
				if seat.Occupant ~= humanoid then
					return kind .. ": the rig never sat in it"
				end

				local cursor, began, movedAt = 2, os.clock(), os.clock()
				local nearest = 1
				local worstOffset, offRoad, airFrames, frames = 0, 0, 0, 0
				local peakRise, lowestUp, speedSum, slowest = 0, 1, 0, math.huge
				local reached = 1
				while os.clock() - began < 120 and cursor < #route do
					local position = chassis.Position
					-- Aim further ahead the faster it goes, as a driver does: a fixed aim point makes a
					-- fast vehicle saw at the wheel, and then the wander measured is mine, not its.
					local lookAhead = 20 + horizontalSpeed(chassis) * 0.35
					while cursor < #route and (Vector3.new(route[cursor].X - position.X, 0, route[cursor].Z - position.Z)).Magnitude < lookAhead do
						cursor += 1
						reached = cursor
						movedAt = os.clock()
					end
					local target = route[cursor]
					local toTarget = Vector3.new(target.X - position.X, 0, target.Z - position.Z)
					local look = chassis.CFrame.LookVector
					local facing = Vector3.new(look.X, 0, look.Z)
					local turn = math.deg(math.atan2(facing:Cross(toTarget).Y, facing:Dot(toTarget)))
					-- Full throttle into a bend would measure my driving, not the road: ease off the
					-- harder it has to turn, which is what a player does.
					drive(seat, math.clamp(1 - math.abs(turn) / 45, 0.15, 1), math.clamp(-turn / 25, -1, 1))

					local speed = horizontalSpeed(chassis)
					-- Measured against the piece of road it is ON, not the point it is aiming at: the
					-- aim point is a lookahead ahead, and measuring to that reported every vehicle as
					-- 50 studs off a road it was driving straight down.
					while nearest < #route - 1 do
						local here = (Vector3.new(route[nearest].X - position.X, 0, route[nearest].Z - position.Z)).Magnitude
						local next_ = (Vector3.new(route[nearest + 1].X - position.X, 0, route[nearest + 1].Z - position.Z)).Magnitude
						if next_ >= here then
							break
						end
						nearest += 1
					end
					local offset = offLine(position, route[math.max(nearest - 1, 1)], route[math.min(nearest + 1, #route)])
					worstOffset = math.max(worstOffset, offset)
					if offset > 14 then
						offRoad += 1
					end
					local telemetry = TELEMETRY[chassis]
					if telemetry and telemetry.grounded == 0 then
						airFrames += 1
					end
					frames += 1
					speedSum += speed
					peakRise = math.max(peakRise, chassis.AssemblyLinearVelocity.Y)
					lowestUp = math.min(lowestUp, chassis.CFrame.UpVector.Y)
					if os.clock() - began > 4 then
						slowest = math.min(slowest, speed)
					end
					if os.clock() - movedAt > 8 then
						break
					end
					RunService.Heartbeat:Wait()
				end
				drive(seat, 0, 0)
				last = { model = model, chassis = chassis }
				local share = frames > 0 and airFrames / frames * 100 or 0
				local made = reached >= #route - 1
				local stopped = chassis.Position
				return string.format(
					"%s: %.0f%% of the route (%d of %d points) at mean %.0f studs/s, slowest after the start %.0f | worst wander from the centre line %.1f studs, %d frames beyond the carriageway | %.0f%% airborne, biggest lift %.0f studs/s | lowest up %.2f | %s",
					kind, reached / #route * 100, reached, #route, frames > 0 and speedSum / frames or 0,
					slowest == math.huge and 0 or slowest, worstOffset, offRoad, share, peakRise, lowestUp,
					made and "made it" or string.format("STOPPED SHORT at %.0f, %.0f, %.0f (route point %d of %d, %.0f studs along)",
						stopped.X, stopped.Y, stopped.Z, reached, #route, (reached - 1) * 8))
			end

			for _, kind in ipairs(KINDS) do
				-- Planted-fault variants ("#nodrive" and friends) have nothing to say about roads.
				if not tostring(kind):find("#") then
					local ok, text = pcall(driveRoute, kind)
					note("road drive " .. (ok and tostring(text) or ("ERROR " .. tostring(text))))
				end
			end

			-- The last vehicle is left where it stopped, with the camera behind it on the road.
			if last and last.chassis.Parent then
				local at = last.chassis.Position
				local back = last.chassis.CFrame.LookVector * -22 + Vector3.new(0, 9, 0)
				camera.CFrame = CFrame.lookAt(at + back, at + last.chassis.CFrame.LookVector * 20)
			else
				camera.CFrame = CFrame.lookAt(route[1] + Vector3.new(0, 40, 40), route[math.min(6, #route)])
			end
		end,
	},
}
